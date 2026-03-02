#!/usr/bin/env python3
"""
Generate publication-quality figures for FeasibleCap IROS 2026 paper.

Figures:
  - Fig. 5: Per-frame feasibility timeline (representative sessions)
  - Fig. 6: Aggregate feasibility statistics across all sessions
  - Table 2 data: Infeasible frame ratios summary

IEEE double-column: single-col = 3.5in, double-col = 7.25in
"""

import os
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.gridspec as gridspec
from matplotlib.collections import LineCollection
import numpy as np
import pandas as pd

# ═══════════════════════════════════════════════════════════════════════
# Global style for IEEE/IROS
# ═══════════════════════════════════════════════════════════════════════

plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "Times", "DejaVu Serif"],
    "font.size": 8,
    "axes.titlesize": 9,
    "axes.labelsize": 8,
    "xtick.labelsize": 7,
    "ytick.labelsize": 7,
    "legend.fontsize": 7,
    "figure.dpi": 300,
    "savefig.dpi": 300,
    "savefig.bbox": "tight",
    "savefig.pad_inches": 0.02,
    "axes.linewidth": 0.5,
    "xtick.major.width": 0.5,
    "ytick.major.width": 0.5,
    "lines.linewidth": 0.8,
    "pdf.fonttype": 42,      # TrueType fonts in PDF (required by IEEE)
    "ps.fonttype": 42,
})

# Color scheme (color-blind friendly)
C_FEASIBLE   = "#2ca02c"   # green
C_WARNING    = "#ff7f0e"   # orange
C_INFEASIBLE = "#d62728"   # red
C_BLUE       = "#1f77b4"
C_PURPLE     = "#9467bd"
C_TEAL       = "#17becf"
C_GRAY       = "#7f7f7f"

STATE_CMAP = {"feasible": C_FEASIBLE, "warning": C_WARNING, "infeasible": C_INFEASIBLE}

OUT_DIR = Path("paper_figures")
DATA_DIR = Path("analysis_output")


def load_feasibility_data(session_id):
    """Load per-frame feasibility CSV for a session."""
    path = DATA_DIR / "feasibility" / f"{session_id}_feasibility.csv"
    return pd.read_csv(path)


def load_all_stats():
    """Load summary stats for all sessions."""
    return pd.read_csv(DATA_DIR / "feasibility_stats.csv")


def state_color_array(states):
    """Map state strings to color values."""
    return [STATE_CMAP[s] for s in states]


# ═══════════════════════════════════════════════════════════════════════
# Fig. 5: Per-Frame Feasibility Timeline
# ═══════════════════════════════════════════════════════════════════════

def draw_state_bar(ax, t, states, label=""):
    """Draw a horizontal color bar showing state over time."""
    if len(t) < 2:
        return
    dt = np.median(np.diff(t))
    for ti, s in zip(t, states):
        ax.axvspan(ti - dt/2, ti + dt/2, color=STATE_CMAP[s], alpha=0.9, linewidth=0)
    ax.set_xlim(t[0] - dt, t[-1] + dt)
    ax.set_yticks([])
    if label:
        ax.set_ylabel(label, rotation=0, ha="right", va="center", fontsize=7)


def fig5_feasibility_timeline(session_ids, labels=None):
    """
    Fig. 5: Multi-panel feasibility timeline for 3 representative sessions.
    Each session shows: state bar, position error, manipulability, joint rate ratio.
    """
    n_sessions = len(session_ids)
    if labels is None:
        labels = [f"Trial {chr(65+i)}" for i in range(n_sessions)]

    fig = plt.figure(figsize=(7.25, 5.5))

    # 4 rows per session: state_bar, pos_err, manipulability, rate_ratio
    rows_per = 4
    total_rows = n_sessions * rows_per + (n_sessions - 1)  # gaps between sessions
    gs = gridspec.GridSpec(total_rows, 1, hspace=0.15,
                           height_ratios=[0.4, 1, 1, 1] * n_sessions
                           if n_sessions == 1
                           else sum([[0.4, 1, 1, 1, 0.3] for _ in range(n_sessions)], [])[:-1])

    legend_patches = [
        mpatches.Patch(color=C_FEASIBLE, label="Feasible"),
        mpatches.Patch(color=C_WARNING, label="Warning"),
        mpatches.Patch(color=C_INFEASIBLE, label="Infeasible"),
    ]

    row = 0
    for si, (sid, label) in enumerate(zip(session_ids, labels)):
        df = load_feasibility_data(sid)
        t = df["t"].values
        n = len(df)
        infeas_pct = (df["raw_state"] == "infeasible").mean() * 100

        # State bar
        ax_state = fig.add_subplot(gs[row])
        draw_state_bar(ax_state, t, df["raw_state"].values)
        ax_state.set_title(f"{label}  ({n} frames, {t[-1]:.1f}s, "
                           f"infeasible: {infeas_pct:.0f}%)",
                           fontsize=8, fontweight="bold", loc="left")
        if si == 0:
            ax_state.legend(handles=legend_patches, loc="upper right", ncol=3,
                            fontsize=6, framealpha=0.8, edgecolor="none")
        ax_state.set_xticklabels([])
        row += 1

        # Position error
        ax_pos = fig.add_subplot(gs[row])
        ax_pos.plot(t, df["pos_error"].values * 1000, color=C_BLUE, linewidth=0.6)
        ax_pos.axhline(5, color=C_INFEASIBLE, linestyle="--", linewidth=0.4, alpha=0.6)
        ax_pos.set_ylabel("Pos. err.\n(mm)", fontsize=7)
        ax_pos.set_ylim(bottom=0)
        ax_pos.grid(True, alpha=0.15, linewidth=0.3)
        ax_pos.set_xticklabels([])
        row += 1

        # Manipulability (log scale)
        ax_manip = fig.add_subplot(gs[row])
        manip = np.clip(df["manipulability"].values, 1e-8, None)
        ax_manip.semilogy(t, manip, color=C_PURPLE, linewidth=0.6)
        ax_manip.axhline(5e-4, color=C_WARNING, linestyle="--", linewidth=0.4, alpha=0.6)
        ax_manip.axhline(1e-5, color=C_INFEASIBLE, linestyle="--", linewidth=0.4, alpha=0.6)
        ax_manip.set_ylabel("Manip.\nindex", fontsize=7)
        ax_manip.set_ylim(1e-8, 1e-1)
        ax_manip.grid(True, alpha=0.15, linewidth=0.3)
        ax_manip.set_xticklabels([])
        row += 1

        # Joint rate ratio
        ax_rate = fig.add_subplot(gs[row])
        ax_rate.plot(t, df["max_joint_rate_ratio"].values, color=C_TEAL, linewidth=0.6)
        ax_rate.axhline(1.0, color=C_INFEASIBLE, linestyle="--", linewidth=0.4, alpha=0.6)
        ax_rate.set_ylabel("Rate\nratio", fontsize=7)
        ax_rate.set_ylim(bottom=0)
        ax_rate.grid(True, alpha=0.15, linewidth=0.3)
        if si == n_sessions - 1:
            ax_rate.set_xlabel("Time (s)")
        else:
            ax_rate.set_xticklabels([])
        row += 1

        # Gap between sessions
        if si < n_sessions - 1:
            row += 1  # skip gap row

    fig.savefig(OUT_DIR / "fig5_feasibility_timeline.pdf")
    fig.savefig(OUT_DIR / "fig5_feasibility_timeline.png")
    plt.close()
    print(f"  Fig. 5 saved ({n_sessions} sessions)")


# ═══════════════════════════════════════════════════════════════════════
# Fig. 6: Aggregate Statistics
# ═══════════════════════════════════════════════════════════════════════

def fig6_aggregate_statistics():
    """
    Fig. 6: Aggregate feasibility statistics across all sessions.
    3-panel figure: (a) state breakdown per session, (b) infeasible ratio CDF,
    (c) infeasibility cause breakdown.
    """
    stats = load_all_stats()
    n = len(stats)

    fig, axes = plt.subplots(1, 3, figsize=(7.25, 2.2))

    # (a) Stacked bar: state breakdown per session (sorted by infeasible ratio)
    ax = axes[0]
    stats_sorted = stats.sort_values("infeasible_ratio_raw").reset_index(drop=True)
    x = np.arange(n)
    feas = stats_sorted["feasible_ratio_raw"].values * 100
    warn = stats_sorted["warning_ratio_raw"].values * 100
    infeas = stats_sorted["infeasible_ratio_raw"].values * 100

    ax.bar(x, feas, color=C_FEASIBLE, width=0.9, label="Feasible")
    ax.bar(x, warn, bottom=feas, color=C_WARNING, width=0.9, label="Warning")
    ax.bar(x, infeas, bottom=feas+warn, color=C_INFEASIBLE, width=0.9, label="Infeasible")
    ax.set_xlabel("Trial (sorted)")
    ax.set_ylabel("Frame ratio (%)")
    ax.set_title("(a) State breakdown", fontsize=8)
    ax.set_ylim(0, 100)
    ax.set_xticks([0, n//4, n//2, 3*n//4, n-1])
    ax.set_xticklabels([1, n//4+1, n//2+1, 3*n//4+1, n])
    ax.legend(fontsize=6, loc="upper left", framealpha=0.8, edgecolor="none")

    # (b) CDF of infeasible ratio
    ax = axes[1]
    sorted_ratios = np.sort(stats["infeasible_ratio_raw"].values) * 100
    cdf = np.arange(1, n+1) / n
    ax.step(sorted_ratios, cdf, color=C_INFEASIBLE, linewidth=1.2, where="post")
    ax.fill_between(sorted_ratios, cdf, step="post", alpha=0.15, color=C_INFEASIBLE)
    ax.axvline(np.median(sorted_ratios), color=C_GRAY, linestyle="--", linewidth=0.6,
               label=f"Median: {np.median(sorted_ratios):.0f}%")
    ax.axvline(np.mean(sorted_ratios), color="black", linestyle=":", linewidth=0.6,
               label=f"Mean: {np.mean(sorted_ratios):.0f}%")
    ax.set_xlabel("Infeasible frame ratio (%)")
    ax.set_ylabel("CDF")
    ax.set_title("(b) Infeasibility distribution", fontsize=8)
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 1)
    ax.legend(fontsize=6, loc="lower right", framealpha=0.8, edgecolor="none")
    ax.grid(True, alpha=0.15, linewidth=0.3)

    # (c) Infeasibility cause breakdown (aggregate across all frames)
    ax = axes[2]
    # Load all frame data to get cause breakdown
    all_frames = []
    for _, row in stats.iterrows():
        sid = row["session_id"]
        df = load_feasibility_data(sid)
        all_frames.append(df)
    all_df = pd.concat(all_frames, ignore_index=True)

    total = len(all_df)
    infeas_mask = all_df["raw_state"] == "infeasible"
    n_infeasible = infeas_mask.sum()

    # Cause flags (from infeasible frames only)
    infeas_df = all_df[infeas_mask]
    ik_fail = (~infeas_df["ik_converged"]).sum()
    vel_viol = (~infeas_df["within_velocity_limits"]).sum()
    jlim_viol = (~infeas_df["within_joint_limits"]).sum()
    sing = (infeas_df["near_singularity"]).sum()
    coll = (infeas_df["self_collision"]).sum()

    causes = {
        "IK non-\nconvergence": ik_fail,
        "Velocity\nlimit": vel_viol,
        "Joint\nlimit": jlim_viol,
        "Near\nsingularity": sing,
        "Self-\ncollision": coll,
    }

    bars = ax.bar(range(len(causes)), list(causes.values()),
                  color=[C_INFEASIBLE, C_TEAL, C_WARNING, C_PURPLE, C_GRAY],
                  width=0.65, edgecolor="white", linewidth=0.3)
    ax.set_xticks(range(len(causes)))
    ax.set_xticklabels(causes.keys(), fontsize=6)
    ax.set_ylabel("Frame count")
    ax.set_title("(c) Infeasibility causes", fontsize=8)

    # Add percentage labels on bars
    for bar, val in zip(bars, causes.values()):
        if val > 0:
            pct = val / n_infeasible * 100
            ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + total*0.005,
                    f"{pct:.0f}%", ha="center", va="bottom", fontsize=6)

    plt.tight_layout()
    fig.savefig(OUT_DIR / "fig6_aggregate_stats.pdf")
    fig.savefig(OUT_DIR / "fig6_aggregate_stats.png")
    plt.close()
    print("  Fig. 6 saved")


# ═══════════════════════════════════════════════════════════════════════
# Fig. 7: EE Tracking & Workspace Visualization
# ═══════════════════════════════════════════════════════════════════════

def fig7_workspace_and_tracking():
    """
    Fig. 7: (a) EE target vs actual tracking, (b) all trajectories colored by feasibility.
    """
    stats = load_all_stats()

    # Pick a long, interesting session
    long_sessions = stats[stats["duration_s"] > 8].sort_values("infeasible_ratio_raw")
    mid_session = long_sessions.iloc[len(long_sessions)//2]["session_id"]
    df = load_feasibility_data(mid_session)

    fig, axes = plt.subplots(1, 2, figsize=(7.25, 2.8))

    # (a) EE target vs actual (3 components)
    ax = axes[0]
    t = df["t"].values
    for comp, label, color in [("x", "X", C_BLUE), ("y", "Y", C_WARNING), ("z", "Z", C_FEASIBLE)]:
        ax.plot(t, df[f"target_{comp}"].values, color=color, linewidth=0.6, alpha=0.5)
        ax.plot(t, df[f"ee_{comp}"].values, color=color, linewidth=0.8, linestyle="--")
    # Custom legend
    from matplotlib.lines import Line2D
    handles = [
        Line2D([0], [0], color=C_GRAY, linewidth=0.6, label="Target"),
        Line2D([0], [0], color=C_GRAY, linewidth=0.8, linestyle="--", label="IK result"),
        Line2D([0], [0], color=C_BLUE, linewidth=1, label="X"),
        Line2D([0], [0], color=C_WARNING, linewidth=1, label="Y"),
        Line2D([0], [0], color=C_FEASIBLE, linewidth=1, label="Z"),
    ]
    ax.legend(handles=handles, fontsize=5.5, ncol=5, loc="upper right",
              framealpha=0.8, edgecolor="none", columnspacing=0.8)
    ax.set_xlabel("Time (s)")
    ax.set_ylabel("Position (m)")
    ax.set_title(f"(a) EE tracking ({mid_session[:8]}...)", fontsize=8)
    ax.grid(True, alpha=0.15, linewidth=0.3)

    # (b) All trajectories in EE space, colored by feasibility
    ax = axes[1]
    for _, row in stats.iterrows():
        sid = row["session_id"]
        sdf = load_feasibility_data(sid)
        if len(sdf) < 5:
            continue
        # Plot EE trajectory, colored by raw state
        x = sdf["ee_x"].values - sdf["ee_x"].iloc[0]
        z = sdf["ee_z"].values - sdf["ee_z"].iloc[0]
        colors = state_color_array(sdf["raw_state"].values)
        for i in range(len(x) - 1):
            ax.plot([x[i], x[i+1]], [z[i], z[i+1]],
                    color=colors[i], linewidth=0.3, alpha=0.6)

    ax.set_xlabel("$\\Delta X_{EE}$ (m)")
    ax.set_ylabel("$\\Delta Z_{EE}$ (m)")
    ax.set_title("(b) All EE trajectories (N=36)", fontsize=8)
    ax.set_aspect("equal")
    ax.grid(True, alpha=0.15, linewidth=0.3)
    legend_patches = [
        mpatches.Patch(color=C_FEASIBLE, alpha=0.7, label="Feasible"),
        mpatches.Patch(color=C_WARNING, alpha=0.7, label="Warning"),
        mpatches.Patch(color=C_INFEASIBLE, alpha=0.7, label="Infeasible"),
    ]
    ax.legend(handles=legend_patches, fontsize=6, loc="upper right",
              framealpha=0.8, edgecolor="none")

    plt.tight_layout()
    fig.savefig(OUT_DIR / "fig7_workspace_tracking.pdf")
    fig.savefig(OUT_DIR / "fig7_workspace_tracking.png")
    plt.close()
    print("  Fig. 7 saved")


# ═══════════════════════════════════════════════════════════════════════
# Fig. 8: Joint-level Analysis
# ═══════════════════════════════════════════════════════════════════════

def fig8_joint_analysis():
    """
    Fig. 8: Joint angles and utilization for a representative session.
    """
    stats = load_all_stats()
    # Pick a session with moderate infeasible ratio and long duration
    candidates = stats[(stats["duration_s"] > 8) &
                       (stats["infeasible_ratio_raw"] > 0.3) &
                       (stats["infeasible_ratio_raw"] < 0.7)]
    if len(candidates) == 0:
        candidates = stats[stats["duration_s"] > 5]
    sid = candidates.iloc[len(candidates)//2]["session_id"]
    df = load_feasibility_data(sid)

    # Joint limits from RM75 URDF
    joint_limits = [
        (-3.1, 3.1), (-2.268, 2.268), (-3.1, 3.1), (-2.355, 2.355),
        (-3.1, 3.1), (-2.233, 2.233), (-6.28, 6.28),
    ]

    fig, axes = plt.subplots(2, 1, figsize=(7.25, 3.0), sharex=True)

    # (a) Joint angles over time
    ax = axes[0]
    colors_j = plt.cm.tab10(np.linspace(0, 1, 7))
    t = df["t"].values
    for j in range(7):
        q = df[f"q{j}"].values
        lo, hi = joint_limits[j]
        ax.plot(t, np.degrees(q), color=colors_j[j], linewidth=0.5,
                label=f"$q_{j+1}$", alpha=0.8)
    ax.set_ylabel("Joint angle (deg)")
    ax.set_title(f"(a) Joint trajectories ({sid[:8]}...)", fontsize=8, loc="left")
    ax.legend(fontsize=5, ncol=7, loc="upper right", framealpha=0.7,
              edgecolor="none", columnspacing=0.5)
    ax.grid(True, alpha=0.15, linewidth=0.3)

    # (b) Joint utilization (distance to nearest limit, normalized)
    ax = axes[1]
    for j in range(7):
        q = df[f"q{j}"].values
        lo, hi = joint_limits[j]
        range_j = hi - lo
        # Utilization: how close to limits (0 = center, 1 = at limit)
        center = (lo + hi) / 2
        util = np.abs(q - center) / (range_j / 2)
        ax.plot(t, util, color=colors_j[j], linewidth=0.5, alpha=0.8)
    ax.axhline(1.0, color=C_INFEASIBLE, linestyle="--", linewidth=0.4, alpha=0.5)
    ax.axhline(0.9, color=C_WARNING, linestyle="--", linewidth=0.4, alpha=0.5)
    ax.set_ylabel("Limit utilization")
    ax.set_xlabel("Time (s)")
    ax.set_title("(b) Joint limit utilization (0=center, 1=limit)", fontsize=8, loc="left")
    ax.set_ylim(0, 1.3)
    ax.grid(True, alpha=0.15, linewidth=0.3)

    plt.tight_layout()
    fig.savefig(OUT_DIR / "fig8_joint_analysis.pdf")
    fig.savefig(OUT_DIR / "fig8_joint_analysis.png")
    plt.close()
    print("  Fig. 8 saved")


# ═══════════════════════════════════════════════════════════════════════
# Table 2: Summary Statistics (LaTeX)
# ═══════════════════════════════════════════════════════════════════════

def table2_latex():
    """Generate LaTeX table for paper Table 2."""
    stats = load_all_stats()
    n = len(stats)

    # Compute aggregate metrics
    total_frames = stats["n_frames"].sum()
    total_time = stats["duration_s"].sum()

    metrics = {
        "Num. trials": (n, ""),
        "Total frames": (total_frames, ""),
        "Total duration (s)": (f"{total_time:.1f}", ""),
        "Mean trial duration (s)": (f"{stats['duration_s'].mean():.1f}",
                                     f"$\\pm${stats['duration_s'].std():.1f}"),
        "IK convergence (\\%)": (f"{stats['ik_convergence_rate'].mean()*100:.1f}",
                                  f"$\\pm${stats['ik_convergence_rate'].std()*100:.1f}"),
        "Infeasible ratio (\\%)": (f"{stats['infeasible_ratio_raw'].mean()*100:.1f}",
                                    f"$\\pm${stats['infeasible_ratio_raw'].std()*100:.1f}"),
        "Warning ratio (\\%)": (f"{stats['warning_ratio_raw'].mean()*100:.1f}",
                                 f"$\\pm${stats['warning_ratio_raw'].std()*100:.1f}"),
        "Feasible ratio (\\%)": (f"{stats['feasible_ratio_raw'].mean()*100:.1f}",
                                  f"$\\pm${stats['feasible_ratio_raw'].std()*100:.1f}"),
        "Mean pos. error (mm)": (f"{stats['mean_pos_error_mm'].mean():.1f}",
                                  f"$\\pm${stats['mean_pos_error_mm'].std():.1f}"),
        "Vel. violation ratio (\\%)": (f"{stats['velocity_violation_ratio'].mean()*100:.1f}",
                                        f"$\\pm${stats['velocity_violation_ratio'].std()*100:.1f}"),
        "Manipulability ($\\times 10^{-3}$)": (
            f"{stats['mean_manipulability'].mean()*1000:.2f}",
            f"$\\pm${stats['mean_manipulability'].std()*1000:.2f}"),
    }

    lines = [
        "\\begin{table}[t]",
        "\\centering",
        "\\caption{Offline feasibility analysis of 36 teleoperation trials.}",
        "\\label{tab:feasibility_stats}",
        "\\begin{tabular}{lc}",
        "\\toprule",
        "\\textbf{Metric} & \\textbf{Value} \\\\",
        "\\midrule",
    ]
    for name, (val, std) in metrics.items():
        if std:
            lines.append(f"{name} & {val} {std} \\\\")
        else:
            lines.append(f"{name} & {val} \\\\")
    lines += [
        "\\bottomrule",
        "\\end{tabular}",
        "\\end{table}",
    ]

    latex = "\n".join(lines)

    with open(OUT_DIR / "table2_feasibility_stats.tex", "w") as f:
        f.write(latex)

    print("  Table 2 LaTeX saved")
    print(latex)


# ═══════════════════════════════════════════════════════════════════════
# Fig. 9: Manipulability vs Infeasibility Scatter
# ═══════════════════════════════════════════════════════════════════════

def fig9_correlations():
    """
    Fig. 9: Correlation plots: (a) manipulability vs infeasible ratio,
    (b) mean velocity vs infeasible ratio, (c) duration vs infeasible ratio.
    """
    stats = load_all_stats()

    fig, axes = plt.subplots(1, 3, figsize=(7.25, 2.0))

    # (a) Manipulability vs infeasible
    ax = axes[0]
    ax.scatter(stats["mean_manipulability"] * 1000,
               stats["infeasible_ratio_raw"] * 100,
               s=15, alpha=0.7, color=C_BLUE, edgecolors="none")
    ax.set_xlabel("Mean manipulability ($\\times 10^{-3}$)")
    ax.set_ylabel("Infeasible ratio (%)")
    ax.set_title("(a)", fontsize=8)
    ax.grid(True, alpha=0.15, linewidth=0.3)

    # (b) Velocity violations vs infeasible
    ax = axes[1]
    ax.scatter(stats["velocity_violation_ratio"] * 100,
               stats["infeasible_ratio_raw"] * 100,
               s=15, alpha=0.7, color=C_TEAL, edgecolors="none")
    ax.set_xlabel("Velocity violation ratio (%)")
    ax.set_ylabel("Infeasible ratio (%)")
    ax.set_title("(b)", fontsize=8)
    ax.grid(True, alpha=0.15, linewidth=0.3)

    # (c) IK convergence vs infeasible
    ax = axes[2]
    ax.scatter(stats["ik_convergence_rate"] * 100,
               stats["infeasible_ratio_raw"] * 100,
               s=15, alpha=0.7, color=C_PURPLE, edgecolors="none")
    ax.set_xlabel("IK convergence rate (%)")
    ax.set_ylabel("Infeasible ratio (%)")
    ax.set_title("(c)", fontsize=8)
    ax.grid(True, alpha=0.15, linewidth=0.3)

    plt.tight_layout()
    fig.savefig(OUT_DIR / "fig9_correlations.pdf")
    fig.savefig(OUT_DIR / "fig9_correlations.png")
    plt.close()
    print("  Fig. 9 saved")


# ═══════════════════════════════════════════════════════════════════════
# Fig. Supp: Per-Session Summary Grid
# ═══════════════════════════════════════════════════════════════════════

def fig_supp_session_grid():
    """
    Supplementary: Small-multiples grid showing feasibility timeline for all sessions.
    """
    stats = load_all_stats()
    stats_sorted = stats.sort_values("infeasible_ratio_raw").reset_index(drop=True)
    n = len(stats_sorted)

    cols = 6
    rows = int(np.ceil(n / cols))
    fig, axes = plt.subplots(rows, cols, figsize=(7.25, rows * 0.55))
    axes = axes.flatten()

    for i, (_, row) in enumerate(stats_sorted.iterrows()):
        ax = axes[i]
        sid = row["session_id"]
        df = load_feasibility_data(sid)
        t = df["t"].values
        dt = np.median(np.diff(t)) if len(t) > 1 else 0.033
        for ti, s in zip(t, df["raw_state"].values):
            ax.axvspan(ti - dt/2, ti + dt/2, color=STATE_CMAP[s], alpha=0.9, linewidth=0)
        infeas_pct = row["infeasible_ratio_raw"] * 100
        ax.set_title(f"{infeas_pct:.0f}%", fontsize=5, pad=1)
        ax.set_xlim(t[0] - dt, t[-1] + dt)
        ax.set_xticks([])
        ax.set_yticks([])
        for spine in ax.spines.values():
            spine.set_linewidth(0.3)

    # Hide unused axes
    for j in range(n, len(axes)):
        axes[j].set_visible(False)

    fig.suptitle("All trials sorted by infeasible ratio (lowest → highest)",
                 fontsize=8, y=1.02)
    plt.tight_layout()
    fig.savefig(OUT_DIR / "fig_supp_session_grid.pdf")
    fig.savefig(OUT_DIR / "fig_supp_session_grid.png")
    plt.close()
    print("  Supplementary grid saved")


# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

def select_representative_sessions():
    """Select 3 representative sessions: low/medium/high infeasibility."""
    stats = load_all_stats()
    # Filter for longer sessions (>5s) for better visualization
    long = stats[stats["duration_s"] > 5].sort_values("infeasible_ratio_raw").reset_index(drop=True)

    if len(long) < 3:
        long = stats.sort_values("infeasible_ratio_raw").reset_index(drop=True)

    n = len(long)
    # Pick low (25th percentile), medium (50th), high (75th)
    low_idx = max(0, n // 4 - 1)
    mid_idx = n // 2
    high_idx = min(n - 1, 3 * n // 4)

    sessions = [
        long.iloc[low_idx]["session_id"],
        long.iloc[mid_idx]["session_id"],
        long.iloc[high_idx]["session_id"],
    ]
    labels = [
        f"Low infeasibility ({long.iloc[low_idx]['infeasible_ratio_raw']*100:.0f}%)",
        f"Medium infeasibility ({long.iloc[mid_idx]['infeasible_ratio_raw']*100:.0f}%)",
        f"High infeasibility ({long.iloc[high_idx]['infeasible_ratio_raw']*100:.0f}%)",
    ]
    return sessions, labels


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print("Generating paper figures...")
    print(f"Output: {OUT_DIR}/\n")

    # Select representative sessions for Fig. 5
    sessions, labels = select_representative_sessions()
    print(f"Representative sessions:")
    for s, l in zip(sessions, labels):
        print(f"  {s[:12]}... → {l}")
    print()

    # Generate all figures
    print("Figures:")
    fig5_feasibility_timeline(sessions, labels)
    fig6_aggregate_statistics()
    fig7_workspace_and_tracking()
    fig8_joint_analysis()
    fig9_correlations()
    fig_supp_session_grid()

    print("\nTable:")
    table2_latex()

    print(f"\nDone. All outputs in {OUT_DIR}/")


if __name__ == "__main__":
    main()
