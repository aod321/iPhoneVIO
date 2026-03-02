#!/usr/bin/env python3
"""
Offline feasibility computation for MCAP recordings.

Ports the iPhone IKSolver + FeasibilityChecker + SelfCollisionChecker to Python,
then replays each recording's camera trajectory through the teleoperation pipeline
(clutch delta → base-frame target → IK → feasibility check).

Usage:
    python scripts/offline_feasibility.py [--data-dir data/mar3_recordings] [--out-dir analysis_output]
"""

import argparse
import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np
import pandas as pd
from mcap.reader import make_reader


# ═══════════════════════════════════════════════════════════════════════
# Robot Model (RM75 7-DoF, from URDF)
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class JointDef:
    name: str
    parent_link: str
    child_link: str
    origin_xyz: np.ndarray  # (3,)
    origin_rpy: np.ndarray  # (3,)
    axis: np.ndarray        # (3,)
    pos_lower: float
    pos_upper: float
    vel_limit: float


def make_transform(xyz, rpy):
    """ZYX Euler → 4x4 homogeneous transform."""
    cr, sr = np.cos(rpy[0]), np.sin(rpy[0])
    cp, sp = np.cos(rpy[1]), np.sin(rpy[1])
    cy, sy = np.cos(rpy[2]), np.sin(rpy[2])

    R = np.array([
        [cy*cp, cy*sp*sr - sy*cr, cy*sp*cr + sy*sr],
        [sy*cp, sy*sp*sr + cy*cr, sy*sp*cr - cy*sr],
        [-sp,   cp*sr,            cp*cr            ],
    ], dtype=np.float64)

    T = np.eye(4, dtype=np.float64)
    T[:3, :3] = R
    T[:3, 3] = xyz
    return T


def rotation_about_axis(axis, angle):
    """Axis-angle → 4x4 rotation matrix."""
    c, s = np.cos(angle), np.sin(angle)
    t = 1 - c
    x, y, z = axis
    R = np.array([
        [t*x*x + c,   t*x*y - z*s, t*x*z + y*s],
        [t*x*y + z*s, t*y*y + c,   t*y*z - x*s],
        [t*x*z - y*s, t*y*z + x*s, t*z*z + c  ],
    ], dtype=np.float64)
    T = np.eye(4, dtype=np.float64)
    T[:3, :3] = R
    return T


# RM75 joints from URDF
RM75_JOINTS = [
    JointDef("joint1", "base_link", "Link1",
             np.array([0, 0, 0.2405]), np.array([-np.pi/2, 0, 0]),
             np.array([0, -1, 0]), -3.1, 3.1, 3.14),
    JointDef("joint2", "Link1", "Link2",
             np.array([0, 0, 0]), np.array([np.pi/2, 0, 0]),
             np.array([0, 1, 0]), -2.268, 2.268, 3.14),
    JointDef("joint3", "Link2", "Link3",
             np.array([0, 0, 0.256]), np.array([-np.pi/2, 0, 0]),
             np.array([0, -1, 0]), -3.1, 3.1, 3.92),
    JointDef("joint4", "Link3", "Link4",
             np.array([0, 0, 0]), np.array([np.pi/2, 0, 0]),
             np.array([0, 1, 0]), -2.355, 2.355, 3.92),
    JointDef("joint5", "Link4", "Link5",
             np.array([0, 0, 0.21]), np.array([-np.pi/2, 0, 0]),
             np.array([0, -1, 0]), -3.1, 3.1, 3.92),
    JointDef("joint6", "Link5", "Link6",
             np.array([0, 0, 0]), np.array([np.pi/2, 0, 0]),
             np.array([0, 1, 0]), -2.233, 2.233, 3.92),
    JointDef("joint7", "Link6", "Link7",
             np.array([0, 0, 0.144]), np.array([0, 0, 0]),
             np.array([0, 0, 1]), -6.28, 6.28, 3.92),
]

# Link name → index. base_link=0, Link1=1, ..., Link7=7
LINK_NAMES = ["base_link", "Link1", "Link2", "Link3", "Link4", "Link5", "Link6", "Link7"]
LINK_NAME_TO_IDX = {name: i for i, name in enumerate(LINK_NAMES)}
PARENT_INDICES = [LINK_NAME_TO_IDX[j.parent_link] for j in RM75_JOINTS]

DOF = 7


# ═══════════════════════════════════════════════════════════════════════
# Forward Kinematics
# ═══════════════════════════════════════════════════════════════════════

def forward_kinematics(q):
    """Compute FK for RM75. Returns (link_transforms[8], ee_pose)."""
    link_transforms = [np.eye(4, dtype=np.float64) for _ in range(len(LINK_NAMES))]

    for i, joint in enumerate(RM75_JOINTS):
        parent_idx = PARENT_INDICES[i]
        parent_T = link_transforms[parent_idx]
        joint_T = make_transform(joint.origin_xyz, joint.origin_rpy)
        rot = rotation_about_axis(joint.axis, q[i])

        child_idx = LINK_NAME_TO_IDX[joint.child_link]
        link_transforms[child_idx] = parent_T @ joint_T @ rot

    ee_pose = link_transforms[-1]  # Link7
    return link_transforms, ee_pose


# ═══════════════════════════════════════════════════════════════════════
# Jacobian (6×7)
# ═══════════════════════════════════════════════════════════════════════

def compute_jacobian(q, link_transforms, ee_pose):
    """Compute 6×7 geometric Jacobian."""
    ee_pos = ee_pose[:3, 3]
    J = np.zeros((6, DOF), dtype=np.float64)

    for i, joint in enumerate(RM75_JOINTS):
        parent_idx = PARENT_INDICES[i]
        parent_T = link_transforms[parent_idx]
        joint_frame_T = parent_T @ make_transform(joint.origin_xyz, joint.origin_rpy)

        # World-frame rotation axis
        z_axis = joint_frame_T[:3, :3] @ joint.axis
        # Joint position in world
        p_joint = joint_frame_T[:3, 3]
        # Linear: z × (p_ee - p_joint)
        dp = ee_pos - p_joint
        linear = np.cross(z_axis, dp)

        J[:3, i] = linear
        J[3:, i] = z_axis

    return J


# ═══════════════════════════════════════════════════════════════════════
# IK Solver (DLS)
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class IKResult:
    joint_angles: np.ndarray
    link_transforms: list
    ee_pose: np.ndarray
    converged: bool
    position_error: float
    orientation_error: float
    manipulability: float


def axis_angle_from_rotation(R):
    """Extract axis-angle vector from 3×3 rotation matrix."""
    # Skew-symmetric part
    v = np.array([
        R[2, 1] - R[1, 2],
        R[0, 2] - R[2, 0],
        R[1, 0] - R[0, 1],
    ]) * 0.5

    sin_theta = np.linalg.norm(v)
    cos_theta = np.clip((np.trace(R) - 1) * 0.5, -1, 1)

    if sin_theta < 1e-3:
        if cos_theta > 0:
            return np.zeros(3)
        else:
            # theta ≈ π
            diag = np.diag(R)
            max_idx = np.argmax(diag)
            axis = np.zeros(3)
            axis[max_idx] = np.sqrt(max(0, (diag[max_idx] + 1) * 0.5))
            denom = 4 * axis[max_idx]
            if denom > 1e-6:
                for j in range(3):
                    if j != max_idx:
                        axis[j] = (R[max_idx, j] + R[j, max_idx]) / denom
            norm = np.linalg.norm(axis)
            if norm > 1e-6:
                axis /= norm
            else:
                axis = np.array([1, 0, 0])
            return axis * np.pi

    theta = np.arctan2(sin_theta, cos_theta)
    return v * (theta / sin_theta)


def compute_ik_error(current, target):
    """Compute 6-vector error (position + orientation)."""
    pos_err = target[:3, 3] - current[:3, 3]
    R_err = target[:3, :3] @ current[:3, :3].T
    ori_err = axis_angle_from_rotation(R_err)
    return np.concatenate([pos_err, ori_err])


def compute_manipulability(J):
    """Compute manipulability index w = sqrt(det(J * J^T))."""
    A = J @ J.T
    det = np.linalg.det(A)
    return np.sqrt(max(0, det))


def ik_solve(target, warm_start, max_iterations=30,
             pos_tol=0.005, ori_tol=0.05,
             lambda_sq=0.01, max_step=0.15):
    """DLS IK solver for RM75."""
    q = warm_start.copy()

    for _ in range(max_iterations):
        link_transforms, ee_pose = forward_kinematics(q)
        error = compute_ik_error(ee_pose, target)
        pos_err = np.linalg.norm(error[:3])
        ori_err = np.linalg.norm(error[3:])

        if pos_err < pos_tol and ori_err < ori_tol:
            J = compute_jacobian(q, link_transforms, ee_pose)
            w = compute_manipulability(J)
            return IKResult(q, link_transforms, ee_pose, True, pos_err, ori_err, w)

        J = compute_jacobian(q, link_transforms, ee_pose)

        # DLS: dq = J^T (J J^T + λ²I)^{-1} e
        A = J @ J.T + lambda_sq * np.eye(6)
        x = np.linalg.solve(A, error)
        dq = J.T @ x

        # Clamp and update
        dq = np.clip(dq, -max_step, max_step)
        q += dq
        for j in range(DOF):
            q[j] = np.clip(q[j], RM75_JOINTS[j].pos_lower, RM75_JOINTS[j].pos_upper)

    # Final evaluation
    link_transforms, ee_pose = forward_kinematics(q)
    final_error = compute_ik_error(ee_pose, target)
    pos_err = np.linalg.norm(final_error[:3])
    ori_err = np.linalg.norm(final_error[3:])
    J = compute_jacobian(q, link_transforms, ee_pose)
    w = compute_manipulability(J)

    return IKResult(q, link_transforms, ee_pose,
                    pos_err < pos_tol and ori_err < ori_tol,
                    pos_err, ori_err, w)


# ═══════════════════════════════════════════════════════════════════════
# Self-Collision Checker (sphere-based)
# ═══════════════════════════════════════════════════════════════════════

COLLISION_SPHERES = [
    (0, np.array([0, 0, 0.05]), 0.06),   # base_link
    (1, np.array([0, 0, 0]),    0.05),    # Link1
    (2, np.array([0, 0, 0.05]), 0.045),   # Link2 lower
    (2, np.array([0, 0, 0.18]), 0.045),   # Link2 upper
    (3, np.array([0, 0, 0]),    0.045),   # Link3
    (4, np.array([0, 0, 0.04]), 0.04),    # Link4 lower
    (4, np.array([0, 0, 0.14]), 0.04),    # Link4 upper
    (5, np.array([0, 0, 0]),    0.04),    # Link5
    (6, np.array([0, 0, 0.04]), 0.035),   # Link6
    (7, np.array([0, 0, 0]),    0.03),    # Link7
]

# Build collision pairs: non-adjacent links (gap >= 3)
COLLISION_PAIRS = []
for i in range(len(COLLISION_SPHERES)):
    for j in range(i + 1, len(COLLISION_SPHERES)):
        if abs(COLLISION_SPHERES[i][0] - COLLISION_SPHERES[j][0]) >= 3:
            COLLISION_PAIRS.append((i, j))

SAFETY_MARGIN = 0.01  # 10mm


def check_self_collision(link_transforms):
    """Check self-collision using sphere approximation. Returns (colliding, min_gap)."""
    # Compute world positions
    world_pos = []
    for link_idx, local_pos, radius in COLLISION_SPHERES:
        T = link_transforms[link_idx]
        wp = (T @ np.append(local_pos, 1))[:3]
        world_pos.append(wp)

    min_gap = float("inf")
    for i, j in COLLISION_PAIRS:
        dist = np.linalg.norm(world_pos[i] - world_pos[j])
        gap = dist - COLLISION_SPHERES[i][2] - COLLISION_SPHERES[j][2] - SAFETY_MARGIN
        min_gap = min(min_gap, gap)

    return min_gap < 0, min_gap


# ═══════════════════════════════════════════════════════════════════════
# Feasibility Checker
# ═══════════════════════════════════════════════════════════════════════

@dataclass
class FeasibilityResult:
    state: str           # "feasible", "warning", "infeasible"
    raw_state: str       # pre-debounce
    ik_converged: bool
    position_error: float
    orientation_error: float
    within_joint_limits: bool
    within_velocity_limits: bool
    near_singularity: bool
    manipulability: float
    self_collision: bool
    max_joint_rate_ratio: float


class FeasibilityChecker:
    def __init__(self):
        self.previous_angles = None
        self.previous_timestamp = 0.0
        self.pause_threshold = 0.5
        self.velocity_safety_factor = 0.5

        # Singularity thresholds
        self.manip_critical = 1e-5
        self.manip_warn = 5e-4
        self.singularity_angle_threshold = 0.087  # ~5°

        # Debounce
        self.infeasible_debounce = 5
        self.feasible_debounce = 5
        self.consec_infeasible = 0
        self.consec_feasible = 0
        self.consec_warning = 0
        self.current_state = "feasible"

        # Velocity sliding window
        self.vel_window_size = 5
        self.vel_violation_history = []
        self.vel_violation_threshold = 4

    def evaluate(self, ik_result: IKResult, timestamp: float) -> FeasibilityResult:
        q = ik_result.joint_angles
        ik_ok = ik_result.converged

        # 1. Joint position limits
        limits_ok = True
        for i in range(DOF):
            if q[i] < RM75_JOINTS[i].pos_lower - 0.01 or q[i] > RM75_JOINTS[i].pos_upper + 0.01:
                limits_ok = False
                break

        # 2. Joint velocity limits
        velocity_ok = True
        max_rate_ratio = 0.0
        if ik_ok and self.previous_angles is not None and self.previous_timestamp > 0:
            dt = timestamp - self.previous_timestamp
            if 0.001 < dt < self.pause_threshold:
                frame_violation = False
                for i in range(DOF):
                    rate = abs(q[i] - self.previous_angles[i]) / dt
                    limit = RM75_JOINTS[i].vel_limit * self.velocity_safety_factor
                    if limit > 0:
                        ratio = rate / limit
                        max_rate_ratio = max(max_rate_ratio, ratio)
                    if rate > limit:
                        frame_violation = True

                self.vel_violation_history.append(frame_violation)
                if len(self.vel_violation_history) > self.vel_window_size:
                    self.vel_violation_history.pop(0)
                violation_count = sum(self.vel_violation_history)
                velocity_ok = violation_count < self.vel_violation_threshold

        # 3. Singularity detection
        w = ik_result.manipulability
        at_singularity = w < self.manip_critical
        near_singularity = w < self.manip_warn
        elbow_singular = abs(q[3]) < self.singularity_angle_threshold
        wrist_singular = abs(q[5]) < self.singularity_angle_threshold
        known_singular = elbow_singular or wrist_singular

        # 4. Self-collision
        colliding, _ = check_self_collision(ik_result.link_transforms)

        # Update previous
        self.previous_angles = q.copy()
        self.previous_timestamp = timestamp

        # Raw state
        if not ik_ok or not limits_ok or not velocity_ok or at_singularity or colliding:
            raw_state = "infeasible"
        elif near_singularity or known_singular:
            raw_state = "warning"
        else:
            raw_state = "feasible"

        # Debounce
        if raw_state == "infeasible":
            self.consec_feasible = 0
            self.consec_warning = 0
            self.consec_infeasible += 1
            if self.current_state != "infeasible" and self.consec_infeasible >= self.infeasible_debounce:
                self.current_state = "infeasible"
        elif raw_state == "warning":
            self.consec_feasible = 0
            self.consec_infeasible = 0
            self.consec_warning += 1
            if self.current_state == "feasible" and self.consec_warning >= self.infeasible_debounce:
                self.current_state = "warning"
            elif self.current_state == "infeasible" and self.consec_warning >= self.feasible_debounce:
                self.current_state = "warning"
        else:  # feasible
            self.consec_infeasible = 0
            self.consec_warning = 0
            self.consec_feasible += 1
            if self.current_state != "feasible" and self.consec_feasible >= self.feasible_debounce:
                self.current_state = "feasible"

        return FeasibilityResult(
            state=self.current_state,
            raw_state=raw_state,
            ik_converged=ik_ok,
            position_error=ik_result.position_error,
            orientation_error=ik_result.orientation_error,
            within_joint_limits=limits_ok,
            within_velocity_limits=velocity_ok,
            near_singularity=near_singularity or known_singular,
            manipulability=w,
            self_collision=colliding,
            max_joint_rate_ratio=max_rate_ratio,
        )

    def reset(self):
        self.previous_angles = None
        self.previous_timestamp = 0.0
        self.consec_infeasible = 0
        self.consec_feasible = 0
        self.consec_warning = 0
        self.current_state = "feasible"
        self.vel_violation_history.clear()


# ═══════════════════════════════════════════════════════════════════════
# Teleoperation Simulation
# ═══════════════════════════════════════════════════════════════════════

def quat_to_rotation_matrix(w, x, y, z):
    """Quaternion (w,x,y,z) → 3×3 rotation matrix."""
    R = np.array([
        [1 - 2*(y*y + z*z), 2*(x*y - w*z),     2*(x*z + w*y)],
        [2*(x*y + w*z),     1 - 2*(x*x + z*z), 2*(y*z - w*x)],
        [2*(x*z - w*y),     2*(y*z + w*x),     1 - 2*(x*x + y*y)],
    ], dtype=np.float64)
    return R


def pose_msg_to_4x4(pose):
    """Convert MCAP pose message dict to 4×4 transform."""
    pos = pose["position"]
    ori = pose["orientation"]
    R = quat_to_rotation_matrix(ori["w"], ori["x"], ori["y"], ori["z"])
    T = np.eye(4, dtype=np.float64)
    T[:3, :3] = R
    T[:3, 3] = [pos["x"], pos["y"], pos["z"]]
    return T


def build_base_transform(hit_position, yaw, height_offset=0.0):
    """Replicate iPhone's buildBaseTransform: position + yaw + Z-up-to-Y-up rotation."""
    translation = np.eye(4, dtype=np.float64)
    translation[:3, 3] = [hit_position[0], hit_position[1] + height_offset, hit_position[2]]

    yaw_rot = make_transform(np.zeros(3), np.array([0, yaw, 0]))
    z_up_to_y_up = make_transform(np.zeros(3), np.array([-np.pi/2, 0, 0]))

    return translation @ yaw_rot @ z_up_to_y_up


def simulate_teleop_session(camera_poses, timestamps, base_transform):
    """
    Simulate teleoperation for a recording session.

    camera_poses: list of 4×4 transforms (ARKit world frame)
    timestamps: list of float timestamps
    base_transform: 4×4 robot base transform in ARKit world frame

    Returns: list of FeasibilityResult, list of IKResult, list of per-frame dicts
    """
    if len(camera_poses) < 2:
        return [], [], []

    checker = FeasibilityChecker()
    base_inv = np.linalg.inv(base_transform)
    base_rot3 = base_inv[:3, :3]

    # Home position → EE reference
    home_q = np.zeros(DOF)
    _, ee_home = forward_kinematics(home_q)
    ee_ref = ee_home  # in base frame
    ee_ref_pos = ee_ref[:3, 3]
    ee_ref_rot = ee_ref[:3, :3]

    # Camera reference = first frame
    camera_ref = camera_poses[0]
    camera_ref_rot = camera_ref[:3, :3]

    # Velocity clamping parameters (match iPhone)
    max_linear_speed = 0.5   # m/s
    max_angular_speed = 2.0  # rad/s

    prev_q = home_q.copy()
    prev_clamped_pos = ee_ref_pos.copy()
    prev_clamped_rot = ee_ref_rot.copy()
    prev_target_ts = timestamps[0]

    results = []
    ik_results = []
    frame_data = []

    for i, (cam_T, ts) in enumerate(zip(camera_poses, timestamps)):
        # Camera displacement delta (world frame)
        dp_world = cam_T[:3, 3] - camera_ref[:3, 3]

        # Transform to base frame
        dp_base = base_rot3 @ dp_world

        # Rotation delta
        cur_rot3 = cam_T[:3, :3]
        dR_world = cur_rot3 @ camera_ref_rot.T
        dR_base = base_rot3 @ dR_world @ base_rot3.T

        # Target = EE ref + deltas
        raw_target_pos = ee_ref_pos + dp_base
        raw_target_rot = dR_base @ ee_ref_rot

        # Velocity clamping
        dt = ts - prev_target_ts
        clamped_pos = raw_target_pos.copy()
        clamped_rot = raw_target_rot.copy()

        if dt > 0.001 and dt < 0.5 and i > 0:
            # Clamp linear
            dp = raw_target_pos - prev_clamped_pos
            linear_speed = np.linalg.norm(dp)
            max_linear_step = max_linear_speed * dt
            if linear_speed > max_linear_step:
                clamped_pos = prev_clamped_pos + dp * (max_linear_step / linear_speed)

            # Clamp angular
            dR = raw_target_rot @ prev_clamped_rot.T
            trace = np.trace(dR)
            cos_theta = np.clip((trace - 1) * 0.5, -1, 1)
            theta = np.arccos(cos_theta)
            max_angular_step = max_angular_speed * dt
            if theta > max_angular_step and theta > 1e-6:
                ax = np.array([
                    dR[2, 1] - dR[1, 2],
                    dR[0, 2] - dR[2, 0],
                    dR[1, 0] - dR[0, 1],
                ]) * 0.5
                sin_t = np.linalg.norm(ax)
                if sin_t > 1e-6:
                    axis = ax / sin_t
                    clamped_dR = rotation_about_axis(axis, max_angular_step)[:3, :3]
                    clamped_rot = clamped_dR @ prev_clamped_rot
                else:
                    clamped_rot = prev_clamped_rot

        prev_clamped_pos = clamped_pos
        prev_clamped_rot = clamped_rot
        prev_target_ts = ts

        # Build target pose
        target = np.eye(4, dtype=np.float64)
        target[:3, :3] = clamped_rot
        target[:3, 3] = clamped_pos

        # IK solve
        ik = ik_solve(target, prev_q)
        prev_q = ik.joint_angles.copy()

        # Feasibility check
        feas = checker.evaluate(ik, ts)

        results.append(feas)
        ik_results.append(ik)
        frame_data.append({
            "frame": i,
            "ts": ts,
            "t": ts - timestamps[0],
            "state": feas.state,
            "raw_state": feas.raw_state,
            "ik_converged": feas.ik_converged,
            "pos_error": feas.position_error,
            "ori_error": feas.orientation_error,
            "within_joint_limits": feas.within_joint_limits,
            "within_velocity_limits": feas.within_velocity_limits,
            "near_singularity": feas.near_singularity,
            "manipulability": feas.manipulability,
            "self_collision": feas.self_collision,
            "max_joint_rate_ratio": feas.max_joint_rate_ratio,
            "target_x": clamped_pos[0],
            "target_y": clamped_pos[1],
            "target_z": clamped_pos[2],
            "ee_x": ik.ee_pose[0, 3],
            "ee_y": ik.ee_pose[1, 3],
            "ee_z": ik.ee_pose[2, 3],
            **{f"q{j}": ik.joint_angles[j] for j in range(DOF)},
        })

    return results, ik_results, frame_data


# ═══════════════════════════════════════════════════════════════════════
# MCAP Reading
# ═══════════════════════════════════════════════════════════════════════

def read_camera_poses(mcap_path):
    """Read pose messages → list of (4x4 transform, timestamp)."""
    poses = []
    with open(mcap_path, "rb") as f:
        reader = make_reader(f)
        for schema, channel, msg in reader.iter_messages():
            if channel.topic.endswith("/pose"):
                data = json.loads(msg.data)
                T = pose_msg_to_4x4(data["pose"])
                ts = data.get("ts", msg.log_time / 1e9)
                poses.append((T, ts))
    poses.sort(key=lambda x: x[1])
    return [p[0] for p in poses], [p[1] for p in poses]


# ═══════════════════════════════════════════════════════════════════════
# Plotting
# ═══════════════════════════════════════════════════════════════════════

STATE_COLORS = {"feasible": "#22c55e", "warning": "#eab308", "infeasible": "#ef4444"}


def plot_feasibility_timeline(df, session_id, out_path):
    """Plot per-frame feasibility timeline (Fig. 5 style)."""
    fig, axes = plt.subplots(6, 1, figsize=(14, 10), sharex=True,
                             gridspec_kw={"height_ratios": [1, 1, 2, 2, 2, 2]})

    t = df["t"].values

    # 1. Debounced state bar
    ax = axes[0]
    for _, row in df.iterrows():
        ax.axvspan(row["t"] - 0.02, row["t"] + 0.02,
                   color=STATE_COLORS[row["state"]], alpha=0.8)
    ax.set_ylabel("State")
    ax.set_yticks([])
    ax.set_title(f"Feasibility Timeline: {session_id[:12]}...")

    # 2. Raw state bar
    ax = axes[1]
    for _, row in df.iterrows():
        ax.axvspan(row["t"] - 0.02, row["t"] + 0.02,
                   color=STATE_COLORS[row["raw_state"]], alpha=0.8)
    ax.set_ylabel("Raw")
    ax.set_yticks([])

    # Legend
    patches = [mpatches.Patch(color=c, label=l) for l, c in STATE_COLORS.items()]
    axes[0].legend(handles=patches, loc="upper right", ncol=3, fontsize=8)

    # 3. Position error
    ax = axes[2]
    ax.plot(t, df["pos_error"].values * 1000, linewidth=0.8, color="steelblue")
    ax.axhline(5, color="red", linestyle="--", linewidth=0.5, alpha=0.5, label="5mm tol")
    ax.set_ylabel("Pos Err (mm)")
    ax.legend(fontsize=7)
    ax.grid(True, alpha=0.2)

    # 4. Orientation error
    ax = axes[3]
    ax.plot(t, np.degrees(df["ori_error"].values), linewidth=0.8, color="darkorange")
    ax.axhline(np.degrees(0.05), color="red", linestyle="--", linewidth=0.5, alpha=0.5, label="2.9° tol")
    ax.set_ylabel("Ori Err (deg)")
    ax.legend(fontsize=7)
    ax.grid(True, alpha=0.2)

    # 5. Manipulability
    ax = axes[4]
    ax.semilogy(t, np.clip(df["manipulability"].values, 1e-8, None), linewidth=0.8, color="purple")
    ax.axhline(5e-4, color="orange", linestyle="--", linewidth=0.5, label="warn")
    ax.axhline(1e-5, color="red", linestyle="--", linewidth=0.5, label="critical")
    ax.set_ylabel("Manipulability")
    ax.legend(fontsize=7)
    ax.grid(True, alpha=0.2)

    # 6. Max joint rate ratio
    ax = axes[5]
    ax.plot(t, df["max_joint_rate_ratio"].values, linewidth=0.8, color="teal")
    ax.axhline(1.0, color="red", linestyle="--", linewidth=0.5, label="limit")
    ax.set_ylabel("Rate Ratio")
    ax.set_xlabel("Time (s)")
    ax.legend(fontsize=7)
    ax.grid(True, alpha=0.2)

    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()


def plot_summary_table(all_stats, out_path):
    """Plot summary statistics across all sessions."""
    fig, axes = plt.subplots(2, 3, figsize=(15, 8))

    # Infeasible ratio distribution
    ax = axes[0, 0]
    ratios = [s["infeasible_ratio_raw"] * 100 for s in all_stats]
    ax.hist(ratios, bins=15, edgecolor="black", alpha=0.7, color="#ef4444")
    ax.set_xlabel("Infeasible Frame Ratio (%)")
    ax.set_ylabel("Count")
    ax.set_title("Infeasible Ratio (raw)")
    ax.axvline(np.mean(ratios), color="black", linestyle="--",
               label=f"mean={np.mean(ratios):.1f}%")
    ax.legend()

    # Debounced infeasible ratio
    ax = axes[0, 1]
    ratios_d = [s["infeasible_ratio_debounced"] * 100 for s in all_stats]
    ax.hist(ratios_d, bins=15, edgecolor="black", alpha=0.7, color="#f87171")
    ax.set_xlabel("Infeasible Frame Ratio (%)")
    ax.set_ylabel("Count")
    ax.set_title("Infeasible Ratio (debounced)")
    ax.axvline(np.mean(ratios_d), color="black", linestyle="--",
               label=f"mean={np.mean(ratios_d):.1f}%")
    ax.legend()

    # IK convergence rate
    ax = axes[0, 2]
    conv = [s["ik_convergence_rate"] * 100 for s in all_stats]
    ax.hist(conv, bins=15, edgecolor="black", alpha=0.7, color="#22c55e")
    ax.set_xlabel("IK Convergence Rate (%)")
    ax.set_ylabel("Count")
    ax.set_title("IK Convergence")

    # Mean manipulability
    ax = axes[1, 0]
    manip = [s["mean_manipulability"] for s in all_stats]
    ax.hist(manip, bins=15, edgecolor="black", alpha=0.7, color="purple")
    ax.set_xlabel("Mean Manipulability")
    ax.set_ylabel("Count")
    ax.set_title("Manipulability Distribution")

    # Velocity violation ratio
    ax = axes[1, 1]
    vel_viol = [s["velocity_violation_ratio"] * 100 for s in all_stats]
    ax.hist(vel_viol, bins=15, edgecolor="black", alpha=0.7, color="teal")
    ax.set_xlabel("Velocity Violation Ratio (%)")
    ax.set_ylabel("Count")
    ax.set_title("Velocity Violations")

    # State breakdown (stacked bar)
    ax = axes[1, 2]
    sessions = list(range(len(all_stats)))
    feas = [s["feasible_ratio_raw"] * 100 for s in all_stats]
    warn = [s["warning_ratio_raw"] * 100 for s in all_stats]
    infeas = [s["infeasible_ratio_raw"] * 100 for s in all_stats]
    ax.bar(sessions, feas, color="#22c55e", label="feasible")
    ax.bar(sessions, warn, bottom=feas, color="#eab308", label="warning")
    bottoms = [f + w for f, w in zip(feas, warn)]
    ax.bar(sessions, infeas, bottom=bottoms, color="#ef4444", label="infeasible")
    ax.set_xlabel("Session #")
    ax.set_ylabel("Frame %")
    ax.set_title("State Breakdown per Session")
    ax.legend(fontsize=7)

    plt.suptitle(f"Offline Feasibility Summary (N={len(all_stats)})", fontsize=14, fontweight="bold")
    plt.tight_layout()
    plt.savefig(out_path, dpi=150)
    plt.close()


# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

def estimate_base_placement(first_camera_pose):
    """
    Estimate a reasonable robot base placement from the first camera pose.

    Strategy: place base 0.5m in front of camera on a table (~0.7m below),
    facing toward the camera.
    """
    cam_pos = first_camera_pose[:3, 3]
    cam_forward = -first_camera_pose[:3, 2]  # camera looks along -Z in ARKit

    # Project forward direction onto XZ ground plane
    forward_xz = np.array([cam_forward[0], 0, cam_forward[2]])
    fwd_norm = np.linalg.norm(forward_xz)
    if fwd_norm > 1e-6:
        forward_xz /= fwd_norm
    else:
        forward_xz = np.array([0, 0, -1])

    # Base position: 0.5m forward, 0.7m below camera
    base_pos = cam_pos + forward_xz * 0.5
    base_pos[1] = cam_pos[1] - 0.7  # table surface

    # Yaw: robot faces toward camera (opposite of forward)
    yaw = np.arctan2(-forward_xz[0], -forward_xz[2])

    return build_base_transform(base_pos, yaw)


def main():
    parser = argparse.ArgumentParser(description="Offline feasibility computation")
    parser.add_argument("--data-dir", default="data/mar3_recordings")
    parser.add_argument("--out-dir", default="analysis_output")
    parser.add_argument("--no-plots", action="store_true")
    args = parser.parse_args()

    data_dir = Path(args.data_dir)
    out_dir = Path(args.out_dir)
    (out_dir / "feasibility").mkdir(parents=True, exist_ok=True)
    (out_dir / "feasibility_plots").mkdir(parents=True, exist_ok=True)

    sessions = sorted([
        d for d in os.listdir(data_dir)
        if os.path.isdir(data_dir / d) and (data_dir / d / f"{d}.mcap").exists()
    ])
    print(f"Found {len(sessions)} sessions")

    # Validate FK at home position
    _, ee_home = forward_kinematics(np.zeros(DOF))
    print(f"Home EE position: {ee_home[:3, 3]}")

    all_stats = []

    for idx, sid in enumerate(sessions):
        mcap_path = str(data_dir / sid / f"{sid}.mcap")
        print(f"[{idx+1}/{len(sessions)}] {sid[:12]}...", end="", flush=True)

        # Read camera poses
        cam_poses, timestamps = read_camera_poses(mcap_path)
        if len(cam_poses) < 5:
            print(" SKIP (too few frames)")
            continue

        # Estimate base placement from first frame
        base_T = estimate_base_placement(cam_poses[0])

        # Simulate teleoperation
        feas_results, ik_results, frame_data = simulate_teleop_session(
            cam_poses, timestamps, base_T
        )

        if not frame_data:
            print(" SKIP (no results)")
            continue

        df = pd.DataFrame(frame_data)

        # Compute session statistics
        n = len(df)
        raw_states = df["raw_state"].value_counts()
        deb_states = df["state"].value_counts()

        stats = {
            "session_id": sid,
            "n_frames": n,
            "duration_s": df["t"].iloc[-1],
            "ik_convergence_rate": df["ik_converged"].mean(),
            "feasible_ratio_raw": raw_states.get("feasible", 0) / n,
            "warning_ratio_raw": raw_states.get("warning", 0) / n,
            "infeasible_ratio_raw": raw_states.get("infeasible", 0) / n,
            "feasible_ratio_debounced": deb_states.get("feasible", 0) / n,
            "warning_ratio_debounced": deb_states.get("warning", 0) / n,
            "infeasible_ratio_debounced": deb_states.get("infeasible", 0) / n,
            "mean_manipulability": df["manipulability"].mean(),
            "mean_pos_error_mm": df["pos_error"].mean() * 1000,
            "mean_ori_error_deg": np.degrees(df["ori_error"].mean()),
            "velocity_violation_ratio": 1.0 - df["within_velocity_limits"].mean(),
            "self_collision_ratio": df["self_collision"].mean(),
            "mean_joint_rate_ratio": df["max_joint_rate_ratio"].mean(),
        }
        all_stats.append(stats)

        infeas_pct = stats["infeasible_ratio_raw"] * 100
        conv_pct = stats["ik_convergence_rate"] * 100
        print(f"  {n} frames, {stats['duration_s']:.1f}s, "
              f"infeas={infeas_pct:.1f}%, IK_conv={conv_pct:.1f}%")

        # Save per-session CSV
        df.to_csv(out_dir / "feasibility" / f"{sid}_feasibility.csv", index=False)

        # Per-session timeline plot
        if not args.no_plots:
            plot_feasibility_timeline(df, sid,
                                     str(out_dir / "feasibility_plots" / f"{sid}_timeline.png"))

    # Summary
    stats_df = pd.DataFrame(all_stats)
    stats_csv = out_dir / "feasibility_stats.csv"
    stats_df.to_csv(stats_csv, index=False)
    print(f"\nFeasibility stats saved to {stats_csv}")

    # Print summary
    print(f"\n{'='*70}")
    print(f"FEASIBILITY SUMMARY ({len(all_stats)} sessions)")
    print(f"{'='*70}")
    cols = [
        ("ik_convergence_rate", "IK Convergence", "%"),
        ("infeasible_ratio_raw", "Infeasible (raw)", "%"),
        ("infeasible_ratio_debounced", "Infeasible (debounced)", "%"),
        ("warning_ratio_raw", "Warning (raw)", "%"),
        ("mean_manipulability", "Mean Manipulability", ""),
        ("mean_pos_error_mm", "Mean Pos Error", "mm"),
        ("mean_ori_error_deg", "Mean Ori Error", "deg"),
        ("velocity_violation_ratio", "Velocity Violations", "%"),
        ("self_collision_ratio", "Self-Collision", "%"),
    ]
    for col, label, unit in cols:
        vals = stats_df[col]
        scale = 100 if unit == "%" else 1
        fmt = f"{vals.mean()*scale:.1f}" if unit == "%" else f"{vals.mean():.4f}"
        fmt_std = f"{vals.std()*scale:.1f}" if unit == "%" else f"{vals.std():.4f}"
        print(f"  {label:>25s}:  mean={fmt}{unit}  std={fmt_std}{unit}")

    total_frames = stats_df["n_frames"].sum()
    total_infeas_raw = (stats_df["infeasible_ratio_raw"] * stats_df["n_frames"]).sum()
    print(f"\n  Total frames: {total_frames}")
    print(f"  Overall infeasible ratio (raw): {total_infeas_raw/total_frames*100:.1f}%")

    # Summary plots
    if not args.no_plots:
        plot_summary_table(all_stats, str(out_dir / "feasibility_summary.png"))
        print(f"  Summary plot saved to {out_dir}/feasibility_summary.png")


if __name__ == "__main__":
    main()
