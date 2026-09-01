#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Cross-SSD validation (Section 4.7): NONE vs BFQ vs DUET under varying sustained block sizes.
Data: realtime_data4.0.csv (validation SSD, 8 sustained workers).
Style follows plot_sustained_block_size_figures.py / Figure exp1 (latency line + throughput bars).

Outputs:
  figures-main/cross_ssd/cross_ssd_latency.pdf
  figures-main/cross_ssd/cross_ssd_throughput.pdf
  figures-main/cross_ssd/cross_ssd_sched_data.xlsx
Optional copy to figures/experiment/cross_ssd/ when --install-figures is passed.

Copyright (c) 2025 by ${git_name_email}, All Rights Reserved.
"""

from __future__ import annotations

import argparse
import os
import shutil
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

# ---------------------------------------------------------------------------
# Configuration (align with DUET.tex §4.7 / §sec:sensitivity-io-sizes)
# ---------------------------------------------------------------------------
DATA_FILE = Path('realtime_data4.0.csv')
OUTPUT_DIR = Path('figures-main/cross_ssd')
FIGURES_INSTALL_DIR = Path('../../figures/experiment/cross_ssd')

BACKGROUND_COUNT = 8
BLOCKSIZES = ['4K', '16K', '64K', '256K', '1M', '4M']
SCHEDULER_ORDER = ['none', 'bfq', 'duet']
MODE_LABELS = {'none': 'NONE', 'bfq': 'BFQ', 'duet': 'DUET'}

# Prefer dual-threshold DUET if present; current realtime_data4.0.csv uses same-threshold 2MB.
DUET_DUAL_CONFIG = 'duet_dual(2097152/524288)'
DUET_SAME_CONFIG = 'duet_same(2097152)'

plt.rcParams['font.size'] = 24
plt.rcParams['axes.labelsize'] = 28
plt.rcParams['xtick.labelsize'] = 22
plt.rcParams['ytick.labelsize'] = 22
plt.rcParams['legend.fontsize'] = 24
plt.rcParams['figure.figsize'] = (12, 8)


def normalize_block_size(series: pd.Series) -> pd.Series:
    mapping = {
        '4K': '4K', '4': '4K',
        '16K': '16K', '16': '16K',
        '64K': '64K', '64': '64K',
        '256K': '256K', '256': '256K',
        '1M': '1M', '1024K': '1M', '1024': '1M',
        '4M': '4M', '4096K': '4M', '4096': '4M',
    }
    return series.astype(str).str.strip().str.upper().map(lambda x: mapping.get(x, x))


def parse_throughput_gb(value) -> float:
    if pd.isna(value):
        return float('nan')
    s = str(value).strip()
    if s in ('', '解析失败', 'nan', 'N/A'):
        return float('nan')
    return float(s.replace('GB/s', '').replace('gb/s', ''))


def resolve_duet_mode(df: pd.DataFrame) -> tuple[str, str]:
    """Return (scheduler_mode_key, config_filter) for DUET rows."""
    dual = df[(df['调度器模式'] == 'duet_dual') & (df['具体配置'] == DUET_DUAL_CONFIG)]
    if len(dual) > 0:
        return 'duet_dual', DUET_DUAL_CONFIG
    same = df[(df['调度器模式'] == 'duet_same') & (df['具体配置'] == DUET_SAME_CONFIG)]
    if len(same) > 0:
        return 'duet_same', DUET_SAME_CONFIG
    raise ValueError(
        f'No DUET rows found for {DUET_DUAL_CONFIG} or {DUET_SAME_CONFIG} in {DATA_FILE}'
    )


def load_and_filter(data_path: Path) -> tuple[pd.DataFrame, str, str]:
    df = pd.read_csv(data_path)
    df['调度器模式'] = df['调度器模式'].astype(str).str.lower().str.strip()
    df['块大小'] = normalize_block_size(df['块大小'])

    duet_mode, duet_config = resolve_duet_mode(df)
    print(f'DUET source: {duet_mode} / {duet_config}')

    mask = df['Background数量'] == BACKGROUND_COUNT
    rows = []
    for mode in ['none', 'bfq']:
        rows.append(mask & (df['调度器模式'] == mode))
    rows.append(mask & (df['调度器模式'] == duet_mode) & (df['具体配置'] == duet_config))
    df = df[np.logical_or.reduce(rows)].copy()
    return df, duet_mode, duet_config


def select_runs(df: pd.DataFrame, mode: str, block: str, duet_mode: str, duet_config: str) -> pd.DataFrame:
    if mode == 'duet':
        return df[
            (df['调度器模式'] == duet_mode)
            & (df['具体配置'] == duet_config)
            & (df['块大小'] == block)
        ]
    return df[(df['调度器模式'] == mode) & (df['块大小'] == block)]


def build_summary_table(df: pd.DataFrame, duet_mode: str, duet_config: str) -> pd.DataFrame:
    records = []
    for plot_mode in SCHEDULER_ORDER:
        for block in BLOCKSIZES:
            sub = select_runs(df, plot_mode, block, duet_mode, duet_config)
            if len(sub) == 0:
                print(f'Warning: no data for {plot_mode} block={block}')
                continue
            tp = sub['Sustained吞吐量'].map(parse_throughput_gb).astype(float)
            lat = sub['Burst延迟(μs)'].astype(float)
            records.append({
                '调度器': MODE_LABELS[plot_mode],
                '块大小': block,
                '吞吐量均值': round(tp.mean(), 3),
                '吞吐量标准差': round(tp.std(ddof=0), 3),
                '延迟均值': round(lat.mean(), 1),
                '延迟标准差': round(lat.std(ddof=0), 1),
                '运行次数': len(sub),
            })
    return pd.DataFrame(records)


def print_speedup_summary(summary: pd.DataFrame) -> None:
    """Print burst-latency speedup vs BFQ/NONE at 1M (Config.~A in §4.7)."""
    block = '1M'
    duet_lat = summary[(summary['块大小'] == block) & (summary['调度器'] == 'DUET')]['延迟均值']
    if duet_lat.empty:
        return
    duet_val = duet_lat.iloc[0]
    print(f'\n=== Burst latency at sustained block {block}, bg={BACKGROUND_COUNT} ===')
    for baseline in ('BFQ', 'NONE'):
        base_lat = summary[(summary['块大小'] == block) & (summary['调度器'] == baseline)]['延迟均值']
        if not base_lat.empty and base_lat.iloc[0] > 0:
            ratio = base_lat.iloc[0] / duet_val
            print(f'  DUET vs {baseline}: {ratio:.2f}x lower latency '
                  f'({duet_val:.1f} vs {base_lat.iloc[0]:.1f} μs)')


def plot_throughput_bar(summary: pd.DataFrame, output_path: Path) -> None:
    plt.figure()
    bar_width = 0.22
    x = np.arange(len(BLOCKSIZES))
    colors = ['tab:blue', 'tab:orange', 'tab:green']
    hatches = ['/', '\\', '']

    for i, mode_label in enumerate(MODE_LABELS.values()):
        means, stds = [], []
        for block in BLOCKSIZES:
            row = summary[(summary['调度器'] == mode_label) & (summary['块大小'] == block)]
            means.append(row['吞吐量均值'].iloc[0] if len(row) else 0)
            stds.append(row['吞吐量标准差'].iloc[0] if len(row) else 0)
        plt.bar(
            x + i * bar_width, means, bar_width, yerr=stds,
            label=mode_label, capsize=4, color=colors[i],
            edgecolor='black', hatch=hatches[i],
        )

    plt.grid(True, axis='y', linestyle='--', linewidth=1, alpha=0.5)
    plt.xticks(x + bar_width, BLOCKSIZES)
    plt.xlabel('Sustained blocksize (Byte)')
    plt.ylabel('Sustained throughput (GB/s)')
    plt.legend(loc='upper center', bbox_to_anchor=(0.5, 1.12), ncol=3, frameon=False)
    plt.tight_layout(rect=[0, 0, 1, 0.95])
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    plt.close()


def plot_latency_line(summary: pd.DataFrame, output_path: Path) -> None:
    plt.figure()
    markers = ['o', 's', '^']
    colors = ['tab:blue', 'tab:orange', 'tab:green']

    for i, mode_label in enumerate(MODE_LABELS.values()):
        means, stds = [], []
        for block in BLOCKSIZES:
            row = summary[(summary['调度器'] == mode_label) & (summary['块大小'] == block)]
            means.append(row['延迟均值'].iloc[0] if len(row) else 0)
            stds.append(row['延迟标准差'].iloc[0] if len(row) else 0)
        plt.errorbar(
            BLOCKSIZES, means, yerr=stds,
            marker=markers[i], label=mode_label, capsize=4,
            color=colors[i], linestyle='-', markersize=8, linewidth=2,
        )

    plt.grid(True, linestyle='--', linewidth=1, alpha=0.5)
    plt.xlabel('Sustained blocksize (Byte)')
    plt.ylabel('Burst latency (μs)')
    plt.legend(loc='upper center', bbox_to_anchor=(0.5, 1.12), ncol=3, frameon=False)
    plt.tight_layout(rect=[0, 0, 1, 0.95])
    plt.savefig(output_path, dpi=300, bbox_inches='tight')
    plt.close()


def install_figures(output_dir: Path, install_dir: Path) -> None:
    install_dir.mkdir(parents=True, exist_ok=True)
    for name in (
        'cross_ssd_latency.pdf',
        'cross_ssd_throughput.pdf',
    ):
        src = output_dir / name
        if src.exists():
            shutil.copy2(src, install_dir / name)
            print(f'Copied {src} -> {install_dir / name}')


def main() -> None:
    parser = argparse.ArgumentParser(description='Plot Cross-SSD scheduler comparison (§4.7)')
    parser.add_argument(
        '--data', type=Path, default=DATA_FILE,
        help='Input CSV (default: realtime_data4.0.csv)',
    )
    parser.add_argument(
        '--output-dir', type=Path, default=OUTPUT_DIR,
        help='Directory for figures-main/PNG outputs',
    )
    parser.add_argument(
        '--install-figures', action='store_true',
        help='Copy PDFs to figures/experiment/cross_ssd/ for DUET.tex',
    )
    args = parser.parse_args()

    if not args.data.exists():
        raise FileNotFoundError(f'Data file not found: {args.data}')

    args.output_dir.mkdir(parents=True, exist_ok=True)

    df, duet_mode, duet_config = load_and_filter(args.data)
    summary = build_summary_table(df, duet_mode, duet_config)
    if summary.empty:
        raise RuntimeError('Summary table is empty; check filters and CSV content.')

    xlsx_path = args.output_dir / 'cross_ssd_sched_data.xlsx'
    summary.to_excel(xlsx_path, index=False)
    print(f'Saved summary: {xlsx_path}')
    print(summary.to_string(index=False))
    print_speedup_summary(summary)

    plot_latency_line(summary, args.output_dir / 'cross_ssd_latency.pdf')
    plot_throughput_bar(summary, args.output_dir / 'cross_ssd_throughput.pdf')

    print(f'\nFigures saved under {args.output_dir.resolve()}/')

    if args.install_figures:
        install_figures(args.output_dir, FIGURES_INSTALL_DIR)


if __name__ == '__main__':
    main()
