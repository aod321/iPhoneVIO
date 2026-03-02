#!/usr/bin/env python3
"""
node_iphone.py — TCP→ZMQ relay for iPhone VIO data.

Receives iPhone binary protocol (msg_type 0x00/0x01/0x02) via TCP,
decodes frames, and publishes via ZMQ PUB socket.

ZMQ multipart message format: [topic_bytes, json_bytes]
  - b"frame"  : {"pose": [16 floats row-major], "device_ts": float, "wall_clock": float}
  - b"teleop" : raw iPhone JSON, e.g. {"cmd": "clutch_engage", "ts": ...}
  - b"meta"   : raw iPhone session metadata JSON

Usage:
    python node_iphone.py [--tcp-port 5555] [--zmq-port 5556] [--no-mdns]
"""

import argparse
import json
import socket
import struct
import threading
import time

import numpy as np
import zmq


def decode_tcp_frame(payload: bytes):
    """Decode a frameData payload from the TCP binary protocol.

    Returns (transform_4x4_rowmajor, device_ts, wall_clock, jpeg_size).
    """
    jpeg_size = struct.unpack_from('<I', payload, 0)[0]
    # 16 floats column-major (col0_row0, col0_row1, ..., col3_row3)
    floats = struct.unpack_from('<16f', payload, 4)
    mat = np.zeros((4, 4), dtype=np.float64)
    for col in range(4):
        for row in range(4):
            mat[col, row] = floats[col * 4 + row]
    mat = mat.T  # column-major → row-major

    device_ts = struct.unpack_from('<d', payload, 68)[0]
    wall_clock = struct.unpack_from('<d', payload, 76)[0]
    return mat, device_ts, wall_clock, jpeg_size


class NodeIPhone:
    def __init__(self, tcp_port: int = 5555, zmq_port: int = 5556, advertise_mdns: bool = True):
        self.tcp_port = tcp_port
        self.zmq_port = zmq_port
        self.advertise_mdns = advertise_mdns

        self._stop_event = threading.Event()
        self._zmq_ctx = zmq.Context()
        self._zmq_pub = self._zmq_ctx.socket(zmq.PUB)
        self._zmq_pub.bind(f"tcp://*:{zmq_port}")
        self._zmq_lock = threading.Lock()

        self._zeroconf = None
        self._service_info = None

    def start(self):
        if self.advertise_mdns:
            self._start_mdns()
        print(f"[node_iphone] ZMQ PUB on tcp://*:{self.zmq_port}")
        self._run_tcp_server()

    def stop(self):
        self._stop_event.set()
        if self.advertise_mdns:
            self._stop_mdns()
        self._zmq_pub.close()
        self._zmq_ctx.term()

    # ---- mDNS ----

    def _start_mdns(self):
        try:
            from zeroconf import Zeroconf, ServiceInfo
            hostname = socket.gethostname()
            local_ip = self._get_local_ip()
            self._zeroconf = Zeroconf()
            self._service_info = ServiceInfo(
                "_vioserver._tcp.local.",
                f"{hostname}-NodeIPhone._vioserver._tcp.local.",
                addresses=[socket.inet_aton(local_ip)],
                port=self.tcp_port,
                properties={'version': '2.0', 'protocol': 'tcp-binary', 'relay': 'node_iphone'},
            )
            self._zeroconf.register_service(self._service_info)
            print(f"[node_iphone] mDNS: advertising _vioserver._tcp on {local_ip}:{self.tcp_port}")
        except ImportError:
            print("[node_iphone] zeroconf not installed, skipping mDNS (pip install zeroconf)")
        except Exception as e:
            print(f"[node_iphone] mDNS failed: {e}")

    def _stop_mdns(self):
        try:
            if self._service_info and self._zeroconf:
                self._zeroconf.unregister_service(self._service_info)
            if self._zeroconf:
                self._zeroconf.close()
        except Exception:
            pass
        self._zeroconf = None
        self._service_info = None

    @staticmethod
    def _get_local_ip():
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(('8.8.8.8', 80))
            return s.getsockname()[0]
        except Exception:
            return '127.0.0.1'
        finally:
            s.close()

    # ---- TCP server ----

    def _run_tcp_server(self):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.settimeout(1.0)
        server.bind(('', self.tcp_port))
        server.listen(1)
        print(f"[node_iphone] TCP listening on 0.0.0.0:{self.tcp_port}")

        while not self._stop_event.is_set():
            try:
                conn, addr = server.accept()
            except socket.timeout:
                continue
            except OSError:
                break

            print(f"[node_iphone] Client connected: {addr}")
            t = threading.Thread(target=self._handle_client, args=(conn, addr), daemon=True)
            t.start()

        server.close()

    def _handle_client(self, conn: socket.socket, addr):
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        buf = b''
        frame_count = 0

        try:
            while not self._stop_event.is_set():
                # Read header (8 bytes)
                while len(buf) < 8:
                    chunk = conn.recv(65536)
                    if not chunk:
                        raise ConnectionError("Client disconnected")
                    buf += chunk

                payload_len = struct.unpack_from('<I', buf, 0)[0]
                msg_type = buf[4]
                total_len = 8 + payload_len

                # Read full payload
                while len(buf) < total_len:
                    chunk = conn.recv(65536)
                    if not chunk:
                        raise ConnectionError("Client disconnected")
                    buf += chunk

                payload = buf[8:total_len]
                buf = buf[total_len:]

                if msg_type == 0x00:
                    # Session metadata — forward as-is
                    self._zmq_send(b"meta", payload)
                    try:
                        meta = json.loads(payload)
                        print(f"[node_iphone] Session metadata: {meta.get('deviceModel', '?')} session={meta.get('sessionId', '?')[:8]}...")
                    except Exception:
                        pass

                elif msg_type == 0x01:
                    # Frame data
                    if payload_len < 84:
                        continue
                    mat, device_ts, wall_clock, jpeg_size = decode_tcp_frame(payload)
                    frame_msg = json.dumps({
                        "pose": mat.flatten().tolist(),
                        "device_ts": device_ts,
                        "wall_clock": wall_clock,
                    }).encode()
                    self._zmq_send(b"frame", frame_msg)
                    frame_count += 1
                    if frame_count % 300 == 0:
                        print(f"[node_iphone] Relayed {frame_count} frames from {addr}")

                elif msg_type == 0x02:
                    # Teleop command — forward JSON as-is
                    self._zmq_send(b"teleop", payload)
                    try:
                        cmd = json.loads(payload)
                        print(f"[node_iphone] Teleop: {cmd.get('cmd', '?')}")
                    except Exception:
                        pass

        except (ConnectionError, OSError) as e:
            print(f"[node_iphone] Client {addr} disconnected: {e}")
        finally:
            conn.close()
            print(f"[node_iphone] Connection closed: {addr}")

    def _zmq_send(self, topic: bytes, data: bytes):
        with self._zmq_lock:
            self._zmq_pub.send_multipart([topic, data])


def main():
    parser = argparse.ArgumentParser(description="node_iphone: iPhone TCP → ZMQ relay")
    parser.add_argument('--tcp-port', type=int, default=5555, help="TCP listen port (default 5555)")
    parser.add_argument('--zmq-port', type=int, default=5556, help="ZMQ PUB port (default 5556)")
    parser.add_argument('--no-mdns', action='store_true', help="Disable mDNS advertising")
    args = parser.parse_args()

    node = NodeIPhone(
        tcp_port=args.tcp_port,
        zmq_port=args.zmq_port,
        advertise_mdns=not args.no_mdns,
    )
    try:
        node.start()
    except KeyboardInterrupt:
        print("\n[node_iphone] Shutting down...")
    finally:
        node.stop()


if __name__ == "__main__":
    main()
