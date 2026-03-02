#!/usr/bin/env python3
"""
Analyze Mar 3 MCAP recordings: pose trajectories, frame rates, durations.
Produces per-session stats CSV and trajectory plots.

Usage:
    python scripts/analyze_recordings.py [--data-dir data/mar3_recordings] [--out-dir analysis_output]
"""

import argparse
import json
import os
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from mcap.reader import make_reader


# ─── helpers ───────────────────────────────────────────────────────────

def quat_to_euler(w, x, y, z):
    """Quaternion (w,x,y,z) → Euler (roll, pitch, yaw) in radians (ZYX convention)."""
    sinr_cosp = 2.0 * (w * x + y * z)
    cosr_cosp = 1.0 - 2.0 * (x * x + y * y)
    roll = np.arctan2(sinr_cosp, cosr_cosp)

    sinp = 2.0 * (w * y - z * x)
    sinp = np.clip(sinp, -1.0, 1.0)
    pitch = np.arcsin(sinp)

    siny_cosp = 2.0 * (w * z + x * y)
    cosy_cosp = 1.0 - 2.0 * (y * y + z * z)
    yaw = np.arctan2(siny_cosp, cosy_cosp)

    return roll, pitch, yaw


def read_mcap_poses(mcap_path: str) -> pd.DataFrame:
    """Read all pose messages from an MCAP file into a DataFrame."""
    rows = []
    with open(mcap_path, "rb") as f:
        reader = make_reader(f)
        for schema, channel, msg in reader.iter_messages():
            if channel.topic.endswith("/pose"):
                data = json.loads(msg.data)
                pos = data["pose"]["position"]
                ori = data["pose"]["orientation"]
                ts = data.get("ts", msg.log_time / 1e9)
                roll, pitch, yaw = quat_to_euler(ori["w"], ori["x"], ori["y"], ori["z"])
                rows.append({
                    "ts": ts,
                    "log_time_ns": msg.log_time,
                    "x": pos["x"],
                    "y": pos["y"],
                    "z": pos["z"],
                    "qw": ori["w"],
                    "qx": ori["x"],
                    "qy": ori["y"],
                    "qz": ori["z"],
                    "roll": roll,
                    "pitch": pitch,
                    "yaw": yaw,
                })
    df = pd.DataFrame(rows)
    if len(df) > 0:
        df = df.sort_values("ts").reset_index(drop=True)
        df["t"] = df["ts"] - df["ts"].iloc[0]  # relative time from start
    return df


def read_mcap_image_stats(mcap_path: str) -> dict:
    """Read image message timestamps and sizes (without decoding full JPEG)."""
    timestamps = []
    sizes = []
    with open(mcap_path, "rb") as f:
        reader = make_reader(f)
        for schema, channel, msg in reader.iter_messages():
            if channel.topic.endswith("/image"):
                ts_ns = msg.log_time
                timestamps.append(ts_ns / 1e9)
                sizes.append(len(msg.data))
    return {"timestamps": np.array(timestamps), "sizes": np.array(sizes)}


def compute_session_stats(session_id: str, poses: pd.DataFrame, img_stats: dict) -> dict:
    """Compute per-session statistics."""
    if len(poses) < 2:
        return {"session_id": session_id, "valid": False}

    duration = poses["t"].iloc[-1]
    n_poses = len(poses)
    dt = np.diff(poses["ts"].values)
    fps_mean = 1.0 / np.mean(dt) if np.mean(dt) > 0 else 0
    fps_std = np.std(1.0 / dt[dt > 0]) if np.any(dt > 0) else 0

    # Position trajectory stats
    dx = np.diff(poses["x"].values)
    dy = np.diff(poses["y"].values)
    dz = np.diff(poses["z"].values)
    step_dist = np.sqrt(dx**2 + dy**2 + dz**2)
    total_path_len = np.sum(step_dist)

    # Velocity
    vel = step_dist / dt
    vel = vel[np.isfinite(vel)]

    # Position range (workspace)
    pos_range_x = poses["x"].max() - poses["x"].min()
    pos_range_y = poses["y"].max() - poses["y"].min()
    pos_range_z = poses["z"].max() - poses["z"].min()

    # Orientation range
    ori_range_roll = np.degrees(poses["roll"].max() - poses["roll"].min())
    ori_range_pitch = np.degrees(poses["pitch"].max() - poses["pitch"].min())
    ori_range_yaw = np.degrees(poses["yaw"].max() - poses["yaw"].min())

    # Start-to-end displacement
    displacement = np.sqrt(
        (poses["x"].iloc[-1] - poses["x"].iloc[0])**2 +
        (poses["y"].iloc[-1] - poses["y"].iloc[0])**2 +
        (poses["z"].iloc[-1] - poses["z"].iloc[0])**2
    )

    # Image stats
    n_images = len(img_stats["timestamps"])
    img_size_mean = np.mean(img_stats["sizes"]) / 1024 if n_images > 0 else 0  # KB

    return {
        "session_id": session_id,
        "valid": True,
        "duration_s": round(duration, 2),
        "n_poses": n_poses,
        "n_images": n_images,
        "fps_mean": round(fps_mean, 1),
        "fps_std": round(fps_std, 1),
        "total_path_m": round(total_path_len, 4),
        "displacement_m": round(displacement, 4),
        "vel_mean_m_s": round(np.mean(vel), 4) if len(vel) > 0 else 0,
        "vel_max_m_s": round(np.max(vel), 4) if len(vel) > 0 else 0,
        "pos_range_x_m": round(pos_range_x, 4),
        "pos_range_y_m": round(pos_range_y, 4),
        "pos_range_z_m": round(pos_range_z, 4),
        "ori_range_roll_deg": round(ori_range_roll, 1),
        "ori_range_pitch_deg": round(ori_range_pitch, 1),
        "ori_range_yaw_deg": round(ori_range_yaw, 1),
        "img_size_mean_kb": round(img_size_mean, 1),
    }


# ─── plotting ──────────────────────────────────────────────────────────

def plot_trajectory_3d(poses: pd.DataFrame, session_id: str, out_path: str):
    """Plot 3D trajectory colored by time."""
    fig = plt.figure(figsize=(8, 6))
    ax = fig.add_subplot(111, projection="3d")
    sc = ax.scatter(
        poses["x"], poses["z"], poses["y"],  # ARKit: Y-up → plot Y as vertical
        c=poses["t"], cmap="viridis", s=3, alpha=0.8,
    )
    ax.set_xlabel("X (m)")
    ax.set_ylabel("Z (m)")
    ax.set_zlabel("Y (m)")
    ax.set_title(f"Trajectory: {session_id[:12]}...")
    plt.colorbar(sc, ax=ax, label="Time (s)", shrink=0.6)
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()


def plot_position_time(poses: pd.DataFrame, session_id: str, out_path: str):
    """Plot position components over time."""
    fig, axes = plt.subplots(3, 1, figsize=(10, 6), sharex=True)
    for ax, col, label in zip(axes, ["x", "y", "z"], ["X", "Y", "Z"]):
        ax.plot(poses["t"], poses[col], linewidth=0.8)
        ax.set_ylabel(f"{label} (m)")
        ax.grid(True, alpha=0.3)
    axes[-1].set_xlabel("Time (s)")
    axes[0].set_title(f"Position: {session_id[:12]}...")
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()


def plot_velocity_profile(poses: pd.DataFrame, session_id: str, out_path: str):
    """Plot velocity magnitude over time."""
    if len(poses) < 2:
        return
    dt = np.diff(poses["ts"].values)
    dx = np.diff(poses["x"].values)
    dy = np.diff(poses["y"].values)
    dz = np.diff(poses["z"].values)
    vel = np.sqrt(dx**2 + dy**2 + dz**2) / dt
    t_mid = poses["t"].values[:-1] + np.diff(poses["t"].values) / 2

    fig, ax = plt.subplots(figsize=(10, 3))
    ax.plot(t_mid, vel, linewidth=0.8)
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Velocity (m/s)")
    ax.set_title(f"Velocity: {session_id[:12]}...")
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()


def plot_orientation_time(poses: pd.DataFrame, session_id: str, out_path: str):
    """Plot Euler angles over time."""
    fig, axes = plt.subplots(3, 1, figsize=(10, 6), sharex=True)
    for ax, col, label in zip(axes, ["roll", "pitch", "yaw"], ["Roll", "Pitch", "Yaw"]):
        ax.plot(poses["t"], np.degrees(poses[col]), linewidth=0.8)
        ax.set_ylabel(f"{label} (deg)")
        ax.grid(True, alpha=0.3)
    axes[-1].set_xlabel("Time (s)")
    axes[0].set_title(f"Orientation: {session_id[:12]}...")
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()


def plot_summary_dashboard(stats_df: pd.DataFrame, out_path: str):
    """Plot summary dashboard across all sessions."""
    fig, axes = plt.subplots(2, 3, figsize=(15, 8))

    valid = stats_df[stats_df["valid"]]

    # Duration distribution
    ax = axes[0, 0]
    ax.hist(valid["duration_s"], bins=15, edgecolor="black", alpha=0.7)
    ax.set_xlabel("Duration (s)")
    ax.set_ylabel("Count")
    ax.set_title("Duration Distribution")
    ax.axvline(valid["duration_s"].median(), color="red", linestyle="--", label=f'median={valid["duration_s"].median():.1f}s')
    ax.legend()

    # FPS distribution
    ax = axes[0, 1]
    ax.hist(valid["fps_mean"], bins=15, edgecolor="black", alpha=0.7)
    ax.set_xlabel("Mean FPS")
    ax.set_ylabel("Count")
    ax.set_title("Frame Rate Distribution")

    # Path length distribution
    ax = axes[0, 2]
    ax.hist(valid["total_path_m"], bins=15, edgecolor="black", alpha=0.7)
    ax.set_xlabel("Total Path Length (m)")
    ax.set_ylabel("Count")
    ax.set_title("Path Length Distribution")

    # Velocity distribution
    ax = axes[1, 0]
    ax.hist(valid["vel_mean_m_s"], bins=15, edgecolor="black", alpha=0.7)
    ax.set_xlabel("Mean Velocity (m/s)")
    ax.set_ylabel("Count")
    ax.set_title("Mean Velocity Distribution")

    # Position range (scatter: X range vs Z range)
    ax = axes[1, 1]
    ax.scatter(valid["pos_range_x_m"], valid["pos_range_z_m"], alpha=0.7, s=30)
    ax.set_xlabel("X Range (m)")
    ax.set_ylabel("Z Range (m)")
    ax.set_title("Workspace Coverage")
    ax.set_aspect("equal")

    # Duration vs path length
    ax = axes[1, 2]
    ax.scatter(valid["duration_s"], valid["total_path_m"], alpha=0.7, s=30)
    ax.set_xlabel("Duration (s)")
    ax.set_ylabel("Path Length (m)")
    ax.set_title("Duration vs Path Length")

    plt.suptitle(f"Recording Summary (N={len(valid)})", fontsize=14, fontweight="bold")
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()


def plot_all_trajectories_2d(all_poses: dict, out_path: str):
    """Overlay all trajectories in 2D (XZ plane, top-down view)."""
    fig, ax = plt.subplots(figsize=(10, 10))
    cmap = plt.cm.tab20
    sessions = sorted(all_poses.keys())
    for i, sid in enumerate(sessions):
        poses = all_poses[sid]
        if len(poses) < 2:
            continue
        # Normalize: start at origin
        x = poses["x"].values - poses["x"].iloc[0]
        z = poses["z"].values - poses["z"].iloc[0]
        color = cmap(i % 20)
        ax.plot(x, z, linewidth=0.8, alpha=0.6, color=color)
        ax.plot(x[0], z[0], "o", color=color, markersize=4)
        ax.plot(x[-1], z[-1], "s", color=color, markersize=4)

    ax.set_xlabel("X (m)")
    ax.set_ylabel("Z (m)")
    ax.set_title(f"All Trajectories (N={len(sessions)}, origin-aligned)")
    ax.set_aspect("equal")
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()


# ─── frame extraction (sample frames for visual inspection) ────────────

def extract_sample_frames(mcap_path: str, out_dir: str, n_frames: int = 5):
    """Extract evenly-spaced sample frames from a recording."""
    import base64

    timestamps = []
    images = []
    with open(mcap_path, "rb") as f:
        reader = make_reader(f)
        for schema, channel, msg in reader.iter_messages():
            if channel.topic.endswith("/image"):
                data = json.loads(msg.data)
                timestamps.append(data.get("ts", msg.log_time / 1e9))
                images.append(data["data"])

    if not images:
        return

    os.makedirs(out_dir, exist_ok=True)
    indices = np.linspace(0, len(images) - 1, n_frames, dtype=int)
    for i, idx in enumerate(indices):
        jpg_data = base64.b64decode(images[idx])
        frame_path = os.path.join(out_dir, f"frame_{i:02d}_t{timestamps[idx]:.3f}.jpg")
        with open(frame_path, "wb") as f:
            f.write(jpg_data)


# ─── main ──────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Analyze MCAP recordings")
    parser.add_argument("--data-dir", default="data/mar3_recordings", help="Input directory")
    parser.add_argument("--out-dir", default="analysis_output", help="Output directory")
    parser.add_argument("--no-plots", action="store_true", help="Skip per-session plots")
    parser.add_argument("--extract-frames", action="store_true", help="Extract sample JPEG frames")
    args = parser.parse_args()

    data_dir = Path(args.data_dir)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "plots").mkdir(exist_ok=True)
    (out_dir / "trajectories").mkdir(exist_ok=True)

    sessions = sorted([
        d for d in os.listdir(data_dir)
        if os.path.isdir(data_dir / d) and (data_dir / d / f"{d}.mcap").exists()
    ])
    print(f"Found {len(sessions)} sessions in {data_dir}")

    all_stats = []
    all_poses = {}

    for i, sid in enumerate(sessions):
        mcap_path = str(data_dir / sid / f"{sid}.mcap")
        print(f"[{i+1}/{len(sessions)}] Processing {sid[:12]}...", end="", flush=True)

        # Read data
        poses = read_mcap_poses(mcap_path)
        img_stats = read_mcap_image_stats(mcap_path)

        # Compute stats
        stats = compute_session_stats(sid, poses, img_stats)
        all_stats.append(stats)
        all_poses[sid] = poses

        if not stats["valid"]:
            print(" SKIP (insufficient data)")
            continue

        print(f" {stats['duration_s']}s, {stats['n_poses']} poses, {stats['fps_mean']} fps")

        # Per-session plots
        if not args.no_plots:
            plot_trajectory_3d(poses, sid, str(out_dir / "plots" / f"{sid}_traj3d.png"))
            plot_position_time(poses, sid, str(out_dir / "plots" / f"{sid}_pos.png"))
            plot_velocity_profile(poses, sid, str(out_dir / "plots" / f"{sid}_vel.png"))
            plot_orientation_time(poses, sid, str(out_dir / "plots" / f"{sid}_ori.png"))

        # Export trajectory CSV
        poses.to_csv(out_dir / "trajectories" / f"{sid}_poses.csv", index=False)

        # Extract sample frames
        if args.extract_frames:
            extract_sample_frames(mcap_path, str(out_dir / "frames" / sid), n_frames=5)

    # Summary stats
    stats_df = pd.DataFrame(all_stats)
    stats_csv = out_dir / "session_stats.csv"
    stats_df.to_csv(stats_csv, index=False)
    print(f"\nSession stats saved to {stats_csv}")

    # Print summary table
    valid = stats_df[stats_df["valid"]]
    print(f"\n{'='*70}")
    print(f"SUMMARY ({len(valid)} valid sessions)")
    print(f"{'='*70}")
    summary_cols = [
        ("duration_s", "Duration (s)"),
        ("n_poses", "Poses"),
        ("fps_mean", "FPS"),
        ("total_path_m", "Path Length (m)"),
        ("vel_mean_m_s", "Mean Vel (m/s)"),
        ("vel_max_m_s", "Max Vel (m/s)"),
        ("displacement_m", "Displacement (m)"),
    ]
    for col, label in summary_cols:
        vals = valid[col]
        print(f"  {label:>20s}:  mean={vals.mean():.3f}  std={vals.std():.3f}  "
              f"min={vals.min():.3f}  max={vals.max():.3f}")

    print(f"\n  Total recording time: {valid['duration_s'].sum():.1f}s ({valid['duration_s'].sum()/60:.1f}min)")
    print(f"  Total frames: {valid['n_poses'].sum()}")
    print(f"  Total images: {valid['n_images'].sum()}")

    # Summary plots
    plot_summary_dashboard(stats_df, str(out_dir / "summary_dashboard.png"))
    plot_all_trajectories_2d(all_poses, str(out_dir / "all_trajectories_2d.png"))
    print(f"\nPlots saved to {out_dir}/")


if __name__ == "__main__":
    main()
