#!/usr/bin/env python3
"""
绘制 CPU 监控开销实验图（hotpath + manyproc sweep）

用法:
  python3 plot_monitor_overhead_figures.py
  python3 plot_monitor_overhead_figures.py \\
    --hotpath results_ioprio_hotpath_sweep_20260528_130145 \\
    --cs results_cs_manyproc_sweep_20260528_154326 \\
    --out monitor-overhead-figures

产物:
  fig1_work_cost_vs_procs.pdf/.png    — 单次监控热路径耗时（均值 ± 95% CI）
  fig2_delta_avg_cs_pct.pdf/.png      — manyproc Δavg_cs_ns（均值 ± 95% bootstrap CI）
  summary_for_paper.tsv               — 论文用汇总表
  figures_readme.txt                  — 统计量说明（含 CI 含义）

版式与 plot_burst_block_size_figures.py 一致：画布 (12, 8)、字号 24/28/22/24、虚线网格。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

TARGET_DIR_RE = re.compile(r"^target_(\d+)$")

# 论文图：轴标签（纵轴宜短；技术细节放 figure caption / figures_readme.txt）
LABEL_PROCS = "Number of benchmark processes"
LABEL_WORK_MS = "Monitor list time per round (ms)"
LABEL_DELTA_PCT = "Context-switch time change (%)"
# 子图标题留空；统计细节见 figures_readme.txt / 整图 caption
TITLE_WORK = ""
TITLE_CS = ""

# 与 plot_burst_block_size_figures.py 相同
FIGSIZE = (12.0, 8.0)
FONT_BASE = 24
FONT_LABEL = 28
FONT_TICK = 22
FONT_LEGEND = 24
LINE_WIDTH = 2.0
MARKER_SIZE = 8
def apply_burst_plot_style() -> None:
    plt.rcParams.update(
        {
            "font.size": FONT_BASE,
            "axes.labelsize": FONT_LABEL,
            "xtick.labelsize": FONT_TICK,
            "ytick.labelsize": FONT_TICK,
            "legend.fontsize": FONT_LEGEND,
            "figure.figsize": FIGSIZE,
        }
    )


def style_axes(ax: plt.Axes) -> None:
    ax.grid(True, linestyle="--", linewidth=1, alpha=0.5)
    ax.set_axisbelow(True)


# 旧版 plot_sweep.csv 列名 → 新版
HOTPATH_COLUMN_ALIASES: dict[str, list[str]] = {
    "work_ms_mean": ["work_ms_mean_median"],
    "work_ms_mean_ci95_low": ["work_ms_mean_ci_low"],
    "work_ms_mean_ci95_high": ["work_ms_mean_ci_high"],
    "work_total_ms_mean": ["work_total_ms_median"],
    "work_total_ms_mean_ci95_low": ["work_total_ms_ci_low"],
    "work_total_ms_mean_ci95_high": ["work_total_ms_ci_high"],
    "override_peak_mean": ["override_peak_median"],
    "fn_calls_mean": ["fn_calls_median"],
}


def find_latest(root: Path, pattern: str) -> Path | None:
    dirs = sorted(root.glob(pattern), key=lambda p: p.stat().st_mtime, reverse=True)
    return dirs[0] if dirs else None


def normalize_hotpath_columns(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    for canonical, aliases in HOTPATH_COLUMN_ALIASES.items():
        if canonical in out.columns:
            continue
        for old in aliases:
            if old in out.columns:
                out[canonical] = out[old]
                break
    missing = [c for c in ("work_ms_mean", "work_ms_mean_ci95_low", "work_ms_mean_ci95_high") if c not in out.columns]
    if missing:
        raise KeyError(f"plot_sweep.csv 缺少列: {missing}（期望 work_ms_mean 及 95% CI 列）")
    return out


def parse_proc_sweep_from_readme(sweep_dir: Path) -> list[int] | None:
    readme = sweep_dir / "README.txt"
    if not readme.is_file():
        return None
    for line in readme.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if line.startswith("PROC_SWEEP="):
            vals = []
            for part in line.split("=", 1)[1].split(","):
                part = part.strip()
                if part:
                    vals.append(int(part))
            return vals if vals else None
    return None


def discover_target_procs(sweep_dir: Path) -> list[int]:
    """从 README / 汇总表 / by_target 发现全部横坐标采样点（保持 PROC_SWEEP 顺序）。"""
    ordered: list[int] = []
    seen: set[int] = set()

    def add(tp: int) -> None:
        if tp not in seen:
            seen.add(tp)
            ordered.append(tp)

    for tp in parse_proc_sweep_from_readme(sweep_dir) or []:
        add(tp)

    for name, sep in (("plot_sweep.csv", ","), ("sweep_summary.tsv", "\t")):
        path = sweep_dir / name
        if not path.is_file():
            continue
        df = pd.read_csv(path, sep=sep)
        if "target_procs" not in df.columns:
            continue
        for tp in sorted({int(x) for x in df["target_procs"]}):
            add(tp)

    by_target = sweep_dir / "by_target"
    if by_target.is_dir():
        for child in sorted(by_target.iterdir()):
            m = TARGET_DIR_RE.match(child.name)
            if m:
                add(int(m.group(1)))
                continue
            tp_file = child / "target_procs.txt"
            if tp_file.is_file():
                add(int(tp_file.read_text(encoding="utf-8").strip()))

    return ordered


def order_by_targets(df: pd.DataFrame, targets: list[int]) -> pd.DataFrame:
    if df.empty or not targets:
        return df.sort_values("target_procs")
    rank = {tp: i for i, tp in enumerate(targets)}
    out = df.copy()
    out["_rank"] = out["target_procs"].astype(int).map(lambda x: rank.get(x, len(rank)))
    return out.sort_values(["_rank", "target_procs"]).drop(columns="_rank")


def warn_missing_points(sweep_dir: Path, df: pd.DataFrame, label: str) -> None:
    expected = discover_target_procs(sweep_dir)
    if not expected:
        return
    have = {int(x) for x in df["target_procs"]} if not df.empty else set()
    missing = [tp for tp in expected if tp not in have]
    if missing:
        print(
            f"警告 [{label}]: 目录 {sweep_dir.name} 声明/存在采样点 {expected}，"
            f"但汇总表缺少: {missing}",
            file=sys.stderr,
        )


def load_hotpath(hotpath_dir: Path) -> pd.DataFrame:
    path = hotpath_dir / "plot_sweep.csv"
    if not path.is_file():
        raise FileNotFoundError(f"缺少 {path}")
    targets = discover_target_procs(hotpath_dir)
    df = normalize_hotpath_columns(order_by_targets(pd.read_csv(path), targets))
    warn_missing_points(hotpath_dir, df, "hotpath")
    return df


def load_cs(cs_dir: Path) -> pd.DataFrame:
    path = cs_dir / "sweep_summary.tsv"
    if not path.is_file():
        raise FileNotFoundError(f"缺少 {path}")
    targets = discover_target_procs(cs_dir)
    df = order_by_targets(pd.read_csv(path, sep="\t"), targets)
    warn_missing_points(cs_dir, df, "manyproc")
    return df


def bootstrap_delta_pct_ci(
    target_dir: Path, avg_cs_off: float, n_boot: int = 2000, seed: int = 0
) -> tuple[float, float] | None:
    """从 perf_runs.tsv 配对 off/on，bootstrap 95% CI for mean relative Δ%."""
    off_p = target_dir / "monitor_off" / "perf_runs.tsv"
    on_p = target_dir / "monitor_on" / "perf_runs.tsv"
    if not off_p.is_file() or not on_p.is_file() or avg_cs_off <= 0:
        return None

    def read_avg(path: Path) -> pd.Series:
        df = pd.read_csv(path, sep="\t")
        return df.set_index("run")["avg_cs_ns"].astype(float)

    try:
        off_s, on_s = read_avg(off_p), read_avg(on_p)
        common = off_s.index.intersection(on_s.index)
        if len(common) < 2:
            return None
        pct = ((on_s.loc[common] - off_s.loc[common]) / off_s.loc[common] * 100.0).to_numpy()
    except (KeyError, ValueError, pd.errors.EmptyDataError):
        return None

    rng = np.random.default_rng(seed)
    boots = []
    for _ in range(n_boot):
        sample = rng.choice(pct, size=len(pct), replace=True)
        boots.append(sample.mean())
    boots = np.array(boots)
    return float(np.percentile(boots, 2.5)), float(np.percentile(boots, 97.5))


def enrich_cs_with_bootstrap(cs_df: pd.DataFrame, cs_dir: Path) -> pd.DataFrame:
    rows = []
    for _, row in cs_df.iterrows():
        tp = int(row["target_procs"])
        tdir = cs_dir / "by_target" / f"target_{tp}"
        boot = bootstrap_delta_pct_ci(tdir, float(row["avg_cs_ns_off"]))
        r = row.to_dict()
        if boot:
            r["delta_pct_mean_ci95_low"], r["delta_pct_mean_ci95_high"] = boot
        rows.append(r)
    return pd.DataFrame(rows)


def plot_fig1_work(ax: plt.Axes, hp: pd.DataFrame) -> None:
    procs = hp["target_procs"].to_numpy(dtype=int)
    labels = [str(p) for p in procs]
    xpos = np.arange(len(labels))
    y = hp["work_ms_mean"].to_numpy()
    yerr = np.vstack(
        [
            y - hp["work_ms_mean_ci95_low"].to_numpy(),
            hp["work_ms_mean_ci95_high"].to_numpy() - y,
        ]
    )

    ax.errorbar(
        xpos,
        y,
        yerr=yerr,
        fmt="o-",
        capsize=4,
        color="#2563eb",
        linewidth=LINE_WIDTH,
        markersize=MARKER_SIZE,
    )
    ax.set_xticks(xpos, labels)
    ax.set_xlabel(LABEL_PROCS)
    ax.set_ylabel(LABEL_WORK_MS)
    if TITLE_WORK:
        ax.set_title(TITLE_WORK)
    style_axes(ax)


def plot_fig2_cs(ax: plt.Axes, cs: pd.DataFrame, use_bootstrap_ci: bool) -> None:
    labels = [str(x) for x in cs["target_procs"].astype(int)]
    pct = cs["overhead_pct_avg_cs_ns"].to_numpy()
    colors = ["#64748b" if v < 0 else "#d97706" for v in pct]

    xpos = np.arange(len(labels))
    bars = ax.bar(xpos, pct, color=colors, edgecolor="black", linewidth=0.5, alpha=0.85)
    ax.axhline(0, color="black", linewidth=0.8, linestyle="--")

    if use_bootstrap_ci and "delta_pct_mean_ci95_low" in cs.columns:
        has = cs["delta_pct_mean_ci95_low"].notna().to_numpy()
        if has.any():
            ci_lo = cs["delta_pct_mean_ci95_low"].to_numpy()
            ci_hi = cs["delta_pct_mean_ci95_high"].to_numpy()
            yerr_lo = np.where(has, pct - ci_lo, 0.0)
            yerr_hi = np.where(has, ci_hi - pct, 0.0)
            ax.errorbar(
                xpos[has],
                pct[has],
                yerr=[yerr_lo[has], yerr_hi[has]],
                fmt="none",
                ecolor="black",
                capsize=4,
                linewidth=1.2,
            )
    # 兼容旧 enrich 列名
    elif use_bootstrap_ci and "delta_pct_boot_ci_low" in cs.columns:
        has = cs["delta_pct_boot_ci_low"].notna().to_numpy()
        if has.any():
            ci_lo = cs["delta_pct_boot_ci_low"].to_numpy()
            ci_hi = cs["delta_pct_boot_ci_high"].to_numpy()
            yerr_lo = np.where(has, pct - ci_lo, 0.0)
            yerr_hi = np.where(has, ci_hi - pct, 0.0)
            ax.errorbar(
                xpos[has],
                pct[has],
                yerr=[yerr_lo[has], yerr_hi[has]],
                fmt="none",
                ecolor="black",
                capsize=4,
                linewidth=1.2,
            )

    ax.set_xticks(xpos, labels)
    ax.set_xlabel(LABEL_PROCS)
    ax.set_ylabel(LABEL_DELTA_PCT)
    if TITLE_CS:
        ax.set_title(TITLE_CS)
    ax.grid(True, axis="y", linestyle="--", linewidth=1, alpha=0.5)
    ax.set_axisbelow(True)


def build_summary_table(hp: pd.DataFrame, cs: pd.DataFrame) -> pd.DataFrame:
    rows = []
    for tp in sorted(set(hp["target_procs"].tolist()) | set(cs["target_procs"].tolist())):
        r: dict = {"target_procs": int(tp)}
        h = hp[hp["target_procs"] == tp]
        c = cs[cs["target_procs"] == tp]
        if not h.empty:
            r["work_ms_mean"] = float(h["work_ms_mean"].iloc[0])
            r["work_ms_mean_ci95_low"] = float(h["work_ms_mean_ci95_low"].iloc[0])
            r["work_ms_mean_ci95_high"] = float(h["work_ms_mean_ci95_high"].iloc[0])
            if "fn_calls_mean" in h.columns:
                r["fn_calls_mean"] = float(h["fn_calls_mean"].iloc[0])
            if "override_peak_mean" in h.columns:
                r["override_peak_mean"] = float(h["override_peak_mean"].iloc[0])
        if not c.empty:
            r["delta_avg_cs_ns_pct_mean"] = float(c["overhead_pct_avg_cs_ns"].iloc[0])
            r["delta_cs_count_pct_mean"] = float(c["delta_cs_pct"].iloc[0])
            if "delta_pct_mean_ci95_low" in c.columns and pd.notna(c["delta_pct_mean_ci95_low"].iloc[0]):
                r["delta_avg_cs_ns_pct_ci95_low"] = float(c["delta_pct_mean_ci95_low"].iloc[0])
                r["delta_avg_cs_ns_pct_ci95_high"] = float(c["delta_pct_mean_ci95_high"].iloc[0])
        rows.append(r)
    return pd.DataFrame(rows).sort_values("target_procs")


def write_figures_readme(out_dir: Path, hotpath_dir: Path, cs_dir: Path, hp: pd.DataFrame, cs: pd.DataFrame) -> None:
    reps_hp = int(hp["reps"].iloc[0]) if "reps" in hp.columns and not hp.empty else "?"
    runs_cs = int(cs["runs"].iloc[0]) if "runs" in cs.columns and not cs.empty else "?"
    text = f"""Monitor overhead figures — statistics notes
============================================

CI = Confidence Interval (置信区间)
  A range that, under repeated experiments, would contain the true mean
  about 95% of the time (here: 95% CI).

Axis labels (as in the figures-main):
  X: {LABEL_PROCS}
  fig1 Y: {LABEL_WORK_MS}
  fig2 Y: {LABEL_DELTA_PCT}

fig1 — hotpath ({hotpath_dir.name})
  Metric: mean per-rep latency of ioprio_ov_cpu_work_fn (function_graph), in ms.
  Error bars: 95% CI of the mean across repetitions (mean ± 1.96·σ/√n).
  n ≈ {reps_hp}.

fig2 — manyproc ({cs_dir.name})
  Metric: (avg_cs_ns_on − avg_cs_ns_off) / avg_cs_ns_off × 100%,
  where avg_cs_ns = task_clock / context_switches from perf stat.
  Error bars: 95% bootstrap CI of the mean paired-run Δ%.
  n ≈ {runs_cs}.

Data dirs:
  hotpath: {hotpath_dir}
  manyproc: {cs_dir}
"""
    (out_dir / "figures_readme.txt").write_text(text, encoding="utf-8")


def save_figure(fig: plt.Figure, out_base: Path) -> None:
    """保存 figures-main/PNG；布局与 burst 脚本相同（tight_layout 顶部留白给图例）。"""
    out_base.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout(rect=[0, 0, 1, 0.95])
    fig.savefig(out_base.with_suffix(".pdf"), bbox_inches="tight")
    fig.savefig(out_base.with_suffix(".png"), dpi=200, bbox_inches="tight")


def main() -> None:
    parser = argparse.ArgumentParser(description="绘制监控开销实验图（均值 ± 95% CI）")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent, help="test-1 目录")
    parser.add_argument("--hotpath", type=Path, default=None, help="results_ioprio_hotpath_sweep_* 目录")
    parser.add_argument("--cs", type=Path, default=None, help="results_cs_manyproc_sweep_* 目录")
    parser.add_argument("--out", type=Path, default=None, help="输出目录")
    parser.add_argument("--no-bootstrap-ci", action="store_true", help="fig2 不画 bootstrap 误差棒")
    args = parser.parse_args()

    root = args.root
    hotpath_dir = args.hotpath or find_latest(root, "results_ioprio_hotpath_sweep_*")
    cs_dir = args.cs or find_latest(root, "results_cs_manyproc_sweep_*")
    if hotpath_dir is None or cs_dir is None:
        raise SystemExit("未找到 sweep 结果目录，请用 --hotpath / --cs 指定")

    out_dir = args.out or root / "monitor-overhead-figures"
    out_dir.mkdir(parents=True, exist_ok=True)
    apply_burst_plot_style()

    hp = load_hotpath(hotpath_dir)
    cs = load_cs(cs_dir)
    if not args.no_bootstrap_ci:
        cs = enrich_cs_with_bootstrap(cs, cs_dir)

    hp_targets = [int(x) for x in hp["target_procs"]]
    cs_targets = [int(x) for x in cs["target_procs"]]
    print(f"hotpath 采样点 ({len(hp_targets)}): {hp_targets}")
    print(f"manyproc 采样点 ({len(cs_targets)}): {cs_targets}")

    summary = build_summary_table(hp, cs)
    summary.to_csv(out_dir / "summary_for_paper.tsv", sep="\t", index=False)
    write_figures_readme(out_dir, hotpath_dir, cs_dir, hp, cs)

    fig1, ax1 = plt.subplots(figsize=FIGSIZE)
    plot_fig1_work(ax1, hp)
    save_figure(fig1, out_dir / "fig1_work_cost_vs_procs")
    plt.close(fig1)

    fig2, ax2 = plt.subplots(figsize=FIGSIZE)
    plot_fig2_cs(ax2, cs, use_bootstrap_ci=not args.no_bootstrap_ci)
    save_figure(fig2, out_dir / "fig2_delta_avg_cs_pct")
    plt.close(fig2)

    print(f"hotpath 数据: {hotpath_dir}")
    print(f"manyproc 数据: {cs_dir}")
    print(f"输出目录: {out_dir}")
    print("  fig1_work_cost_vs_procs.pdf/.png")
    print("  fig2_delta_avg_cs_pct.pdf/.png")
    print("  summary_for_paper.tsv")
    print("  figures_readme.txt")


if __name__ == "__main__":
    main()
