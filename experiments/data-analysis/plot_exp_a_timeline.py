#!/usr/bin/env python3
"""
绘制实验 A 的时间序列图：fio + malicious 瞬时吞吐随时间变化，G2 vs G3 对比，
并以垂直虚线标出 G3 的 revoke 与 ionice 时点（"机制起作用的瞬间"）。

数据源（同一 results_exp_a_<TS> 目录）：
  rep_NN/<phase>/
    phase_t0.tsv                          # 单行: t_boot_s\\tt_wall_s
    fio_bw_bw.log                         # fio (--write_bw_log + log_avg_msec + log_unix_epoch=1)
                                          # 行格式: time_ms,KiB/s,direction,bs[,offset[,prio]]
                                          # 时戳为 unix epoch (ms)
    malicious_bw.tsv                      # malicious_sustained 周期采样:
                                          # t_boot_s  cum_ios  cum_bytes  cum_lat_ns
    revoke_events.tsv                     # dmesg 抽取: kind,t_boot_s,pid,comm,detail
    malicious_ionice_after_revoke.log     # 含 EVENT 行: EVENT\\t<name>\\t<t_boot_s>

时间对齐：所有时间序列统一换算到「相对 phase_t0 的秒」。
  fio.log_unix_epoch=1 -> t_rel = (line_ms/1000) - phase_t0_wall_s
  多 job 时各线程写入 epoch 毫秒略有偏移；须按 log_avg_msec（默认 200ms）
  对齐后再对同一 bin 内各行求和，否则只合并到部分 job，吞吐会被低估约 N 倍。
  malicious 直接是 boot 域 -> t_rel = t_boot_s - phase_t0_boot_s
  revoke/ionice 直接是 boot 域 -> 同上

输出：
  fig_timeline_combined.pdf/.png        # 2x2: 行=组(G2,G3) 列=曲线(fio,malicious)
  fig_timeline_overlay.pdf/.png         # 1x3: 列=组(G1,G2,G3)，子图标 (a)(b)(c)
  timeline_aggregated.tsv               # 每个 phase 的逐时刻 mean 表
  events_aggregated.tsv                 # 每个 rep 的 revoke/ionice 相对秒
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import textwrap
import warnings
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

# 时间栅格在采样窗口外会产生 All-NaN 切片，nan{median,percentile} 会刷 warning。
# 这是预期行为（窗外置 NaN，绘图自动断线），抑制即可。
warnings.filterwarnings("ignore", category=RuntimeWarning, message="All-NaN slice encountered")

PHASE_BASELINE = "G1_no_mechanism"
PHASE_BASELINE_LEGACY = "G4_no_mechanism"  # 旧结果目录名

PHASES_WITH_MAL = (
    "G2_malicious_monitor_off",
    "G3_malicious_monitor_on",
    PHASE_BASELINE,
)
PHASE_LABEL = {
    "G1_no_mechanism": "G1: baseline (no burst attribute)",
    "G2_malicious_monitor_off": "G2: attack, monitor OFF",
    "G3_malicious_monitor_on": "G3: defense, monitor ON",
    PHASE_BASELINE_LEGACY: "G4: baseline (legacy dir name)",
}
# overlay 子图 (a)(b)(c) 小标题（细节放整图 caption；不用内部名 ioprio_override）
PANEL_CAPTION = {
    "G1_no_mechanism": "Baseline: malicious no burst attribute",
    "G2_malicious_monitor_off": "Attack: malicious burst attribute, monitor off",
    "G3_malicious_monitor_on": "Defense: malicious burst attribute, monitor on",
    PHASE_BASELINE_LEGACY: "Baseline: malicious no burst attribute",
}
_PANEL_LETTERS = "abcdefghijklmnopqrstuvwxyz"
# 子图下方 (a)(b)(c) 说明：与 burst 图一致放在 x 轴标签之下（axes 坐标）
_PANEL_TAG_Y = -0.34
_PANEL_CAPTION_WIDTH = 34
COLOR_FIO = "#2563eb"
COLOR_MAL = "#dc2626"
COLOR_REVOKE = "#16a34a"
COLOR_IONICE = "#9333ea"

XLABEL = "Elapsed Time (s)"
YLABEL = "Throughput (MB/s)"
# 图例：不依赖 G1/G2/G3 编号，读者仅看图即可理解
LEGEND_FIO = "legitimate fio"
LEGEND_MAL = "malicious"
LEGEND_REVOKE = "burst attribute revoked"
# 内部速率由 KiB/s / 字节计数得到 MiB/s，绘图与轴标签统一为十进制 MB/s
MIB_S_TO_MB_S = (1024.0**2) / 1e6
LINE_WIDTH_MAIN = 2.0

# 与 plot_burst_block_size_figures.py 相同字号比例 (24:28:22:24)，整体按 timeline 用小号缩放
_BURST_FONT = {"base": 24, "label": 28, "tick": 22, "legend": 24}
_TIMELINE_LEGEND_PT = 14
_FONT_SCALE = _TIMELINE_LEGEND_PT / _BURST_FONT["legend"]
LEGEND_FONTSIZE = 14


def apply_timeline_plot_style() -> None:
    """版式与 burst 图一致（网格线型）；轴标题与图例同号，刻度略小。"""
    tick_pt = _BURST_FONT["tick"] * _FONT_SCALE
    plt.rcParams.update(
        {
            "font.size": tick_pt,
            "axes.labelsize": LEGEND_FONTSIZE,
            "xtick.labelsize": tick_pt,
            "ytick.labelsize": tick_pt,
        }
    )


def add_overlay_panel_tag(ax: plt.Axes, letter: str, phase_id: str) -> None:
    """在子图下方居中标 (a)(b)(c) 及说明（位于 x 轴标题之下，版式对齐 burst 图）。"""
    caption = PANEL_CAPTION.get(phase_id, PHASE_LABEL.get(phase_id, phase_id))
    if "\n" in caption:
        body = caption
    else:
        body = textwrap.fill(caption, width=_PANEL_CAPTION_WIDTH)
    ax.text(
        0.5,
        _PANEL_TAG_Y,
        f"({letter}) {body}",
        transform=ax.transAxes,
        fontsize=LEGEND_FONTSIZE,
        va="top",
        ha="center",
        clip_on=False,
    )


def style_axes(
    ax: plt.Axes, *, xlabel: bool = True, ylabel: bool = True
) -> None:
    if xlabel:
        ax.set_xlabel(XLABEL, fontsize=LEGEND_FONTSIZE)
    if ylabel:
        ax.set_ylabel(YLABEL, fontsize=LEGEND_FONTSIZE)
    ax.grid(True, which="both", linestyle="--", linewidth=1, alpha=0.5)
    ax.set_axisbelow(True)


def figure_legend_above(
    fig: plt.Figure, ncol: int | None = None, pad: float = 0.0
) -> None:
    """整图上方居中图例：底边与子图顶缘对齐（须先 subplots_adjust / tight_layout）。"""
    handles: list = []
    labels: list[str] = []
    seen: set[str] = set()
    plot_axes = [ax for ax in fig.axes if ax.has_data() or ax.lines or ax.collections]
    if not plot_axes:
        plot_axes = list(fig.axes)
    for ax in plot_axes:
        h, lab = ax.get_legend_handles_labels()
        for hi, li in zip(h, lab):
            if li and li not in seen:
                seen.add(li)
                handles.append(hi)
                labels.append(li)
    if not handles:
        return
    if ncol is None:
        ncol = min(len(handles), 5)
    top = max(ax.get_position().y1 for ax in plot_axes)
    leg = fig.legend(
        handles,
        labels,
        loc="lower center",
        bbox_to_anchor=(0.5, top + pad),
        bbox_transform=fig.transFigure,
        ncol=ncol,
        fontsize=LEGEND_FONTSIZE,
        frameon=False,
        borderpad=0.15,
        labelspacing=0.25,
        handletextpad=0.35,
        columnspacing=0.6,
    )
    fig.canvas.draw()
    renderer = fig.canvas.get_renderer()
    leg_bb = leg.get_window_extent(renderer).transformed(fig.transFigure.inverted())
    # 图例底边高于子图顶缘时，下移锚点直至贴齐（消除 matplotlib 默认留白）
    gap = leg_bb.y0 - top
    if gap > 1e-4:
        leg.set_bbox_to_anchor((0.5, top + pad - gap), transform=fig.transFigure)


def find_latest_results(root: Path) -> Path | None:
    cands = sorted(
        root.glob("results_exp_a_*"), key=lambda p: p.stat().st_mtime, reverse=True
    )
    return cands[0] if cands else None


def read_phase_t0(phase_dir: Path) -> tuple[float, float] | None:
    p = phase_dir / "phase_t0.tsv"
    if not p.is_file():
        return None
    try:
        parts = p.read_text().strip().split()
        return float(parts[0]), float(parts[1])
    except (OSError, ValueError, IndexError):
        return None


def read_log_avg_msec(phase_dir: Path, default: float = 200.0) -> float:
    """Read fio --log_avg_msec from fio.json or sustained.fio (ms)."""
    fj = phase_dir / "fio.json"
    if fj.is_file():
        try:
            opts = json.loads(fj.read_text(encoding="utf-8")).get("global options", {})
            raw = opts.get("log_avg_msec")
            if raw is not None:
                return float(str(raw).rstrip("s"))
        except (OSError, ValueError, json.JSONDecodeError):
            pass
    sf = phase_dir / "sustained.fio"
    if sf.is_file():
        try:
            m = re.search(r"log_avg_msec=(\d+)", sf.read_text(encoding="utf-8"))
            if m:
                return float(m.group(1))
        except OSError:
            pass
    return default


def read_fio_bw(
    phase_dir: Path, phase_t0_wall: float, log_avg_msec: float | None = None
) -> pd.DataFrame:
    """fio _bw.log: time_ms,value(KiB/s),direction,bs[,offset[,prio]]; log_unix_epoch=1."""
    if log_avg_msec is None:
        log_avg_msec = read_log_avg_msec(phase_dir)
    bin_ms = max(int(log_avg_msec), 1)

    rows: list[tuple[float, float]] = []
    cands = list(phase_dir.glob("fio_bw_bw*.log"))
    for fp in cands:
        try:
            with open(fp, encoding="utf-8", errors="replace") as f:
                for ln in f:
                    parts = [p.strip() for p in ln.strip().split(",")]
                    if len(parts) < 2:
                        continue
                    try:
                        t_ms = float(parts[0])
                        kib_s = float(parts[1])
                    except ValueError:
                        continue
                    # 多 job 时各行 epoch ms 不完全相同；按 log_avg_msec 对齐后再求和。
                    t_bin_ms = round(t_ms / bin_ms) * bin_ms
                    t_rel = t_bin_ms / 1000.0 - phase_t0_wall
                    rows.append((t_rel, kib_s / 1024.0 * MIB_S_TO_MB_S))  # KiB/s -> MB/s
        except OSError:
            continue
    if not rows:
        return pd.DataFrame(columns=["t_rel_s", "mib_s"])
    df = pd.DataFrame(rows, columns=["t_rel_s", "mib_s"]).sort_values("t_rel_s")
    df = df.groupby("t_rel_s", as_index=False)["mib_s"].sum()
    return df


def read_malicious_bw(phase_dir: Path, phase_t0_boot: float) -> pd.DataFrame:
    """malicious_bw.tsv -> 逐区间 piecewise-constant 速率（MB/s），含起止边界。

    返回 DataFrame 列: t_start_s, t_end_s, mib_s
    每行代表一个时间段 [t_start_s, t_end_s) 内的平均吞吐 = Δbytes / Δt。
    plotter 用 piecewise-constant 阶梯方式渲染，避免跨大间距线性插值产生的"假斜线"。
    """
    fp = phase_dir / "malicious_bw.tsv"
    cols = ["t_start_s", "t_end_s", "mib_s"]
    if not fp.is_file():
        return pd.DataFrame(columns=cols)
    try:
        df = pd.read_csv(fp, sep="\t")
    except (OSError, pd.errors.ParserError, pd.errors.EmptyDataError):
        return pd.DataFrame(columns=cols)
    needed = {"t_boot_s", "cum_bytes"}
    if not needed.issubset(df.columns) or len(df) < 2:
        return pd.DataFrame(columns=cols)
    df = df.sort_values("t_boot_s").reset_index(drop=True)
    t = df["t_boot_s"].to_numpy() - phase_t0_boot
    cb = df["cum_bytes"].to_numpy()
    dt = np.diff(t)
    db = np.diff(cb)
    valid = dt > 0
    rates = np.zeros_like(dt)
    rates[valid] = db[valid] / dt[valid] / (1024.0 * 1024.0) * MIB_S_TO_MB_S
    return pd.DataFrame(
        {"t_start_s": t[:-1], "t_end_s": t[1:], "mib_s": rates}
    )


def read_revoke_events(phase_dir: Path, phase_t0_boot: float) -> list[float]:
    fp = phase_dir / "revoke_events.tsv"
    if not fp.is_file():
        return []
    out: list[float] = []
    try:
        with open(fp, encoding="utf-8", errors="replace") as f:
            r = csv.DictReader(f, delimiter="\t")
            for row in r:
                if row.get("kind") != "revoke":
                    continue
                try:
                    t = float(row.get("t_boot_s", "nan"))
                except ValueError:
                    continue
                if not np.isfinite(t):
                    continue
                t_rel = t - phase_t0_boot
                # 过滤窗外（< -2s 或 > FIO_RUNTIME+ramp+5s）的噪声项
                if -2.0 <= t_rel <= 120.0:
                    out.append(t_rel)
    except OSError:
        pass
    out.sort()
    return out


def read_ionice_events(phase_dir: Path, phase_t0_boot: float) -> dict[str, float]:
    fp = phase_dir / "malicious_ionice_after_revoke.log"
    res: dict[str, float] = {}
    if not fp.is_file():
        return res
    try:
        with open(fp, encoding="utf-8", errors="replace") as f:
            for ln in f:
                parts = ln.rstrip("\n").split("\t")
                if len(parts) >= 3 and parts[0] == "EVENT":
                    name = parts[1]
                    try:
                        t = float(parts[2])
                    except ValueError:
                        continue
                    res[name] = t - phase_t0_boot
    except OSError:
        pass
    return res


def resample_to_grid(
    series: list[pd.DataFrame], grid: np.ndarray
) -> np.ndarray | None:
    """对多 rep 的 fio bw 时间序列 (t_rel_s, mib_s) 做线性插值；返回 shape (n_rep, len(grid))."""
    if not series:
        return None
    out = []
    for df in series:
        if df.empty:
            continue
        x = df["t_rel_s"].to_numpy()
        y = df["mib_s"].to_numpy()
        order = np.argsort(x)
        x = x[order]
        y = y[order]
        keep = np.concatenate(([True], np.diff(x) > 0))
        x = x[keep]
        y = y[keep]
        if len(x) < 2:
            continue
        yi = np.interp(grid, x, y, left=np.nan, right=np.nan)
        out.append(yi)
    if not out:
        return None
    return np.vstack(out)


def resample_piecewise_to_grid(
    series: list[pd.DataFrame],
    grid: np.ndarray,
    max_gap_s: float,
) -> tuple[np.ndarray | None, np.ndarray | None]:
    """对 malicious 的 (t_start_s, t_end_s, mib_s) 区间序列在栅格上做 piecewise-constant 估计。

    返回 (rates, gap_mask)：rates shape (n_rep, len(grid))；gap_mask 同形状，True=该格落在>max_gap 的区间内。
    grid[i] 所在的区间 (start <= grid[i] < end) 的速率即视为 grid[i] 处的值；窗外为 NaN。
    """
    if not series:
        return None, None
    out_rates = []
    out_gaps = []
    for df in series:
        if df.empty:
            continue
        s = df["t_start_s"].to_numpy()
        e = df["t_end_s"].to_numpy()
        r = df["mib_s"].to_numpy()
        if len(s) == 0:
            continue
        idx = np.searchsorted(s, grid, side="right") - 1
        in_range = (idx >= 0) & (idx < len(s)) & (grid <= e[np.clip(idx, 0, len(s) - 1)])
        rates_arr = np.full_like(grid, np.nan, dtype=float)
        rates_arr[in_range] = r[idx[in_range]]
        gap_arr = np.zeros_like(grid, dtype=bool)
        # 区间宽度 > max_gap_s 说明该段是无样本时段的回填均值；标记出来供绘图样式
        widths = e - s
        wide = widths > max_gap_s
        gap_arr[in_range] = wide[idx[in_range]]
        out_rates.append(rates_arr)
        out_gaps.append(gap_arr)
    if not out_rates:
        return None, None
    return np.vstack(out_rates), np.vstack(out_gaps)


def mean_agg(mat: np.ndarray | None) -> np.ndarray | None:
    """跨 rep 聚合：取 nanmean，无误差带。"""
    if mat is None or mat.size == 0:
        return None
    with np.errstate(all="ignore"):
        return np.nanmean(mat, axis=0)


def collect_phase(
    outdir: Path, phase_id: str
) -> dict:
    """遍历所有 rep 收集某 phase 的所有时间序列与事件."""
    fios: list[pd.DataFrame] = []
    mals: list[pd.DataFrame] = []
    revokes: list[list[float]] = []
    iceonices: list[dict[str, float]] = []
    for rep_dir in sorted(outdir.glob("rep_*")):
        pdir = rep_dir / phase_id
        if not pdir.is_dir():
            continue
        t0 = read_phase_t0(pdir)
        if t0 is None:
            continue
        t_boot, t_wall = t0
        fios.append(read_fio_bw(pdir, t_wall))
        mals.append(read_malicious_bw(pdir, t_boot))
        revokes.append(read_revoke_events(pdir, t_boot))
        iceonices.append(read_ionice_events(pdir, t_boot))
    return {
        "fio": fios,
        "mal": mals,
        "revokes": revokes,
        "ionices": iceonices,
        "n_reps": len(fios),
    }


def x_range_from_runtime(ramp_s: float, runtime_s: float) -> tuple[float, float]:
    # 横轴从 0 起，与纵轴 0 共原点；右端含 ramp+runtime 后少量余量
    return (0.0, ramp_s + runtime_s + 2.0)


def _plot_mal_piecewise(
    ax: plt.Axes,
    series: list[pd.DataFrame],
    grid: np.ndarray,
    grid_step: float,
    label: str = LEGEND_MAL,
) -> None:
    """malicious 瞬时带宽（piecewise 区间速率 → 栅格 mean，单条实线）。"""
    max_gap_s = max(grid_step * 4, 1.0)
    rates, _gaps = resample_piecewise_to_grid(series, grid, max_gap_s=max_gap_s)
    if rates is None:
        return
    avg = mean_agg(rates)
    if avg is None:
        return
    ax.plot(grid, avg, color=COLOR_MAL, linewidth=LINE_WIDTH_MAIN, label=label)


def plot_single_phase(
    ax: plt.Axes,
    fio_data: dict,
    show_mal: bool,
    xlim: tuple[float, float],
    ylim_top: float,
    grid_step: float = 0.2,
    revoke_xs: list[float] | None = None,
    ionice_x: float | None = None,
    yscale: str = "linear",
    symlog_linthresh: float = 10.0,
    *,
    xlabel: bool = True,
    ylabel: bool = True,
) -> None:
    grid = np.arange(xlim[0], xlim[1] + grid_step / 2, grid_step)

    fio_mat = resample_to_grid(fio_data["fio"], grid)
    fio_avg = mean_agg(fio_mat)
    if fio_avg is not None:
        ax.plot(
            grid, fio_avg, color=COLOR_FIO, linewidth=LINE_WIDTH_MAIN, label=LEGEND_FIO
        )

    if show_mal:
        _plot_mal_piecewise(ax, fio_data["mal"], grid, grid_step)

    if revoke_xs:
        for i, x in enumerate(revoke_xs):
            ax.axvline(
                x,
                color=COLOR_REVOKE,
                linestyle="--",
                linewidth=1.2,
                alpha=0.85,
                label=LEGEND_REVOKE if i == 0 else None,
            )
    if ionice_x is not None and np.isfinite(ionice_x):
        ax.axvline(
            ionice_x,
            color=COLOR_IONICE,
            linestyle=":",
            linewidth=1.5,
            alpha=0.95,
            label="userspace ionice→BE",
        )

    ax.set_xlim(xlim)
    if yscale == "symlog":
        # Linear in [-linthresh, +linthresh], log outside. linthresh ~10 MiB/s
        # lets sub-100 MiB/s suppressed activity be visible while 10000+ MiB/s
        # baseline still fits the same canvas.
        ax.set_yscale("symlog", linthresh=symlog_linthresh, linscale=0.5)
        ax.set_ylim(0, ylim_top)
    elif yscale == "log":
        ax.set_yscale("log")
        # 对数轴无法显示 y=0；仅 log 模式保留正数下界
        ax.set_ylim(max(1.0, symlog_linthresh / 10), ylim_top)
    else:
        ax.set_ylim(0, ylim_top)
    style_axes(ax, xlabel=xlabel, ylabel=ylabel)


def aggregate_events_for_plot(phase_data: dict) -> tuple[list[float], float | None]:
    """跨 rep 聚合：revoke 取每 rep 的最早一次 (median)，ionice 取 median."""
    first_revokes = [r[0] for r in phase_data["revokes"] if r]
    revoke_xs = [float(np.median(first_revokes))] if first_revokes else []
    iceonice_vals = [
        d["ionice_done_boot_s"]
        for d in phase_data["ionices"]
        if d.get("ionice_done_boot_s") is not None
    ]
    ionice_x = float(np.median(iceonice_vals)) if iceonice_vals else None
    return revoke_xs, ionice_x


def detect_ramp_runtime(outdir: Path, default_ramp=3.0, default_rt=30.0) -> tuple[float, float]:
    rdme = outdir / "README.txt"
    ramp, rt = default_ramp, default_rt
    if not rdme.is_file():
        return ramp, rt
    text = rdme.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"ramp\s+(\d+(?:\.\d+)?)s", text)
    if m:
        ramp = float(m.group(1))
    m = re.search(r"runtime\s+(\d+(?:\.\d+)?)s", text)
    if m:
        rt = float(m.group(1))
    return ramp, rt


def write_timeline_table(
    out_path: Path, per_phase: dict[str, dict], grid: np.ndarray, grid_step: float
) -> None:
    rows = []
    max_gap_s = max(grid_step * 4, 1.0)
    for phase_id, data in per_phase.items():
        fio_mat = resample_to_grid(data["fio"], grid)
        fio_avg = mean_agg(fio_mat)
        mal_mat, mal_gap = resample_piecewise_to_grid(data["mal"], grid, max_gap_s)
        mal_avg = mean_agg(mal_mat)
        mal_gap_frac = (
            np.nanmean(mal_gap.astype(float), axis=0) if mal_gap is not None else None
        )
        for i, t in enumerate(grid):
            r = {"phase": phase_id, "t_rel_s": round(float(t), 3), "n_reps": data["n_reps"]}
            if fio_avg is not None:
                r["fio_mean_MB_s"] = float(fio_avg[i])
            if mal_avg is not None:
                r["mal_mean_MB_s"] = float(mal_avg[i])
                r["mal_is_sparse_avg"] = (
                    bool(mal_gap_frac[i] >= 0.5) if mal_gap_frac is not None else False
                )
            rows.append(r)
    pd.DataFrame(rows).to_csv(out_path, sep="\t", index=False, na_rep="nan")


def write_events_table(out_path: Path, per_phase: dict[str, dict]) -> None:
    rows = []
    for phase_id, data in per_phase.items():
        for i, revs in enumerate(data["revokes"]):
            ic = data["ionices"][i] if i < len(data["ionices"]) else {}
            rows.append(
                {
                    "phase": phase_id,
                    "rep_index": i + 1,
                    "n_revokes": len(revs),
                    "t_first_revoke_s": float(revs[0]) if revs else float("nan"),
                    "t_revoke_seen_s": float(ic.get("revoke_seen_boot_s", float("nan"))),
                    "t_ionice_done_s": float(ic.get("ionice_done_boot_s", float("nan"))),
                }
            )
    pd.DataFrame(rows).to_csv(out_path, sep="\t", index=False, na_rep="nan")


def main() -> None:
    parser = argparse.ArgumentParser(description="实验 A 时间序列图")
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="test-1 目录（含 results_exp_a_* 子目录）",
    )
    parser.add_argument(
        "--results", type=Path, default=None, help="results_exp_a_<TS> 目录；缺省取最新"
    )
    parser.add_argument(
        "--out", type=Path, default=None, help="输出目录（默认 <results>/figures_timeline）"
    )
    parser.add_argument("--grid-step", type=float, default=0.2, help="时间栅格步长 (s)")
    parser.add_argument("--ymax", type=float, default=0.0, help=">0 时强制纵轴上限")
    parser.add_argument(
        "--no-symlog",
        action="store_true",
        help="不额外输出 symlog 变体（默认 linear + symlog 都出）",
    )
    parser.add_argument(
        "--symlog-linthresh",
        type=float,
        default=10.0,
        help="symlog 轴的线性段半宽 (MB/s)，默认 10：sub-10 MB/s 线性、以上对数",
    )
    args = parser.parse_args()
    apply_timeline_plot_style()

    results = args.results or find_latest_results(args.root)
    if results is None:
        sys.exit("未找到 results_exp_a_* 目录，请用 --results 指定")
    out_dir = args.out or (results / "figures_timeline")
    out_dir.mkdir(parents=True, exist_ok=True)

    ramp, runtime = detect_ramp_runtime(results)
    xlim = x_range_from_runtime(ramp, runtime)

    # 候选 phases：按希望的展示顺序排，自动跳过没有数据的（向后兼容旧 3-phase 结果）
    candidate_phases = (
        PHASE_BASELINE,
        PHASE_BASELINE_LEGACY,
        "G2_malicious_monitor_off",
        "G3_malicious_monitor_on",
    )
    all_collected = {p: collect_phase(results, p) for p in candidate_phases}
    # 展示顺序 G1→G2→G3；旧结果仅有 G4_no_mechanism 时映射为 baseline 面板
    display_order = (PHASE_BASELINE, "G2_malicious_monitor_off", "G3_malicious_monitor_on")
    phases_list: list[str] = []
    for p in display_order:
        if p == PHASE_BASELINE and all_collected[PHASE_BASELINE]["n_reps"] == 0:
            if all_collected[PHASE_BASELINE_LEGACY]["n_reps"] > 0:
                phases_list.append(PHASE_BASELINE_LEGACY)
            continue
        if all_collected[p]["n_reps"] > 0:
            phases_list.append(p)
    phases = tuple(phases_list)
    per_phase = {p: all_collected[p] for p in phases}

    n_reps_total = max((d["n_reps"] for d in per_phase.values()), default=0)
    if n_reps_total == 0:
        sys.exit(f"在 {results} 下没有任何 rep_*/<phase>/phase_t0.tsv，无法绘图")

    # 估计 y 轴上限：fio + malicious 各取 99 分位的最大
    ymax_candidates = []
    grid = np.arange(xlim[0], xlim[1] + args.grid_step / 2, args.grid_step)
    for data in per_phase.values():
        fio_arr = resample_to_grid(data["fio"], grid)
        mal_arr, _mal_gap = resample_piecewise_to_grid(
            data["mal"], grid, max_gap_s=max(args.grid_step * 4, 1.0)
        )
        for arr in (fio_arr, mal_arr):
            if arr is None:
                continue
            with np.errstate(all="ignore"):
                v = np.nanpercentile(arr, 99)
            if np.isfinite(v):
                ymax_candidates.append(float(v))
    if args.ymax > 0:
        ymax = args.ymax
    else:
        ymax = max(ymax_candidates) * 1.15 if ymax_candidates else 100.0

    # 默认输出 linear + symlog 两套。symlog 让 0–100 MiB/s 区间也清晰可见
    # （fio G2 残值 + malicious G3 revoke 后残值），避免「假零」错觉。
    yscale_variants: list[tuple[str, str]] = [("linear", "")]
    if not args.no_symlog:
        yscale_variants.append(("symlog", "_symlog"))

    # 图1：N 面板叠加（默认 G1/G2/G3），fio + malicious 同图，竖线标 revoke
    n_panels = len(phases)
    overlay_width = max(6.5, 4.5 * n_panels)
    for scale, sfx in yscale_variants:
        fig, axes = plt.subplots(
            1, n_panels, figsize=(overlay_width, 4.4), sharey=True, squeeze=False
        )
        axes_flat = axes[0]
        for pi, (ax, phase_id) in enumerate(zip(axes_flat, phases)):
            data = per_phase[phase_id]
            revoke_xs, ionice_x = aggregate_events_for_plot(data)
            plot_single_phase(
                ax,
                fio_data=data,
                show_mal=True,
                xlim=xlim,
                ylim_top=ymax,
                grid_step=args.grid_step,
                revoke_xs=revoke_xs if phase_id == "G3_malicious_monitor_on" else None,
                ionice_x=ionice_x if phase_id == "G3_malicious_monitor_on" else None,
                yscale=scale,
                symlog_linthresh=args.symlog_linthresh,
                xlabel=True,
                ylabel=(pi == 0),
            )
            add_overlay_panel_tag(ax, _PANEL_LETTERS[pi], phase_id)
        fig.subplots_adjust(bottom=0.30, left=0.07, right=0.99, wspace=0.12)
        figure_legend_above(fig)
        fig.savefig(
            out_dir / f"fig_timeline_overlay{sfx}.pdf",
            bbox_inches="tight",
            pad_inches=0.02,
        )
        fig.savefig(
            out_dir / f"fig_timeline_overlay{sfx}.png",
            dpi=200,
            bbox_inches="tight",
            pad_inches=0.02,
        )
        plt.close(fig)

    # 图2：Nx2 分面，行=组 列=曲线，便于细看 fio 单独 / malicious 单独
    combined_height = max(4.0, 3.8 * n_panels)
    for scale, sfx in yscale_variants:
        fig, axes = plt.subplots(
            n_panels,
            2,
            figsize=(13.0, combined_height),
            sharex=True,
            sharey=True,
            squeeze=False,
        )
        for row, phase_id in enumerate(phases):
            data = per_phase[phase_id]
            revoke_xs, ionice_x = aggregate_events_for_plot(data)
            for col, kind in enumerate(("fio", "mal")):
                ax = axes[row, col]
                if kind == "fio":
                    mat = resample_to_grid(data["fio"], grid)
                    avg = mean_agg(mat)
                    if avg is not None:
                        ax.plot(
                            grid,
                            avg,
                            color=COLOR_FIO,
                            linewidth=LINE_WIDTH_MAIN,
                            label=LEGEND_FIO,
                        )
                else:
                    _plot_mal_piecewise(ax, data["mal"], grid, args.grid_step)
                if phase_id == "G3_malicious_monitor_on":
                    for i, x in enumerate(revoke_xs):
                        ax.axvline(
                            x,
                            color=COLOR_REVOKE,
                            linestyle="--",
                            linewidth=1.2,
                            alpha=0.85,
                            label=LEGEND_REVOKE if i == 0 else None,
                        )
                    if ionice_x is not None and np.isfinite(ionice_x):
                        ax.axvline(
                            ionice_x,
                            color=COLOR_IONICE,
                            linestyle=":",
                            linewidth=1.5,
                            alpha=0.95,
                            label="userspace ionice→BE",
                        )
                ax.set_xlim(xlim)
                if scale == "symlog":
                    ax.set_yscale(
                        "symlog", linthresh=args.symlog_linthresh, linscale=0.5
                    )
                    ax.set_ylim(0, ymax)
                elif scale == "log":
                    ax.set_yscale("log")
                    ax.set_ylim(max(1.0, args.symlog_linthresh / 10), ymax)
                else:
                    ax.set_ylim(0, ymax)
                style_axes(
                    ax,
                    xlabel=(row == n_panels - 1),
                    ylabel=(col == 0),
                )
                if col == 0:
                    ax.set_ylabel(
                        f"{PHASE_LABEL[phase_id]}\n{YLABEL}",
                        fontsize=LEGEND_FONTSIZE,
                    )
        fig.tight_layout()
        figure_legend_above(fig, pad=0.0)
        fig.savefig(
            out_dir / f"fig_timeline_combined{sfx}.pdf",
            bbox_inches="tight",
            pad_inches=0.02,
        )
        fig.savefig(
            out_dir / f"fig_timeline_combined{sfx}.png",
            dpi=200,
            bbox_inches="tight",
            pad_inches=0.02,
        )
        plt.close(fig)

    write_timeline_table(
        out_dir / "timeline_aggregated.tsv", per_phase, grid, args.grid_step
    )
    write_events_table(out_dir / "events_aggregated.tsv", per_phase)

    (out_dir / "README.txt").write_text(
        f"""实验 A 时间序列图
================

数据目录: {results}
重复次数 (G2/G3 reps): {n_reps_total}
fio ramp_time = {ramp}s, runtime = {runtime}s, 显示窗口 [{xlim[0]}, {xlim[1]}]s
时间栅格步长 = {args.grid_step}s, y 轴上限 = {ymax:.2f} MB/s

文件:
  fig_timeline_overlay.{{pdf,png}}          - 1x3 linear (G1/G2/G3)，子图 (a)(b)(c)，fio+malicious 同图
  fig_timeline_overlay_symlog.{{pdf,png}}   - 同上 symlog y 轴：sub-{args.symlog_linthresh:g} MB/s 线性、其上对数，
                                              便于看清被压制后的残余带宽（在线性图上几乎不可见）
  fig_timeline_combined.{{pdf,png}}         - 2x2 linear，行=组 列=workload
  fig_timeline_combined_symlog.{{pdf,png}}  - 同上 symlog
  timeline_aggregated.tsv                   - 每 phase 每时刻的 mean
  events_aggregated.tsv                     - 每 rep 的 revoke / ionice 相对秒

为何要同时给 linear 与 symlog 两套：
  实验动态范围很大。线性轴下看不出被压制 workload 究竟剩多少；symlog 让 sub-{args.symlog_linthresh:g} MB/s
  区段保持线性、上方对数压缩，
  既能保留"差别有多大"的视觉冲击，又能让 reviewer 读到被压制的真实数值。

时间对齐：
  - phase_t0.tsv 记录 phase 开始的 CLOCK_BOOTTIME 与 wall time
  - fio 用 log_unix_epoch=1，按 wall time 折算
  - malicious_bw.tsv 与 dmesg revoke 时戳同源 (CLOCK_BOOTTIME / printk_time)
  - 所有 t_rel_s 均以 phase_t0 为 0 点

读图：
  - G2 (monitor OFF): malicious (红) 占走带宽, fio (蓝) 长期低位
  - G3 (monitor ON): 在 revoke 竖线后, fio 蓝线回升；ionice 竖线后 malicious 红线进一步下降
  - G2/G3 不再叠加 G1 baseline 参考线；曲线为各 rep 的 mean
""",
        encoding="utf-8",
    )

    print(f"数据目录: {results}")
    print(f"输出目录: {out_dir}")
    print(f"  fig_timeline_overlay.pdf/.png")
    print(f"  fig_timeline_combined.pdf/.png")
    print(f"  timeline_aggregated.tsv  events_aggregated.tsv")
    for ph in phases:
        d = per_phase[ph]
        print(
            f"  {ph}: n_reps={d['n_reps']}, "
            f"revokes/rep={[len(r) for r in d['revokes']]}, "
            f"ionice_done={[f for f in (x.get('ionice_done_boot_s') for x in d['ionices']) if f is not None]}"
        )


if __name__ == "__main__":
    main()
