#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
动机实验：4KB 块大小、count=1 下，不同 IO depth 的吞吐量。
数据源：5.0bandwidth_summary.csv (PCIe 5.0)、4.0bandwidth_summary.csv (PCIe 4.0)
"""

import os
import re

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

plt.rcParams['font.sans-serif'] = ['PingFang SC', 'Heiti TC', 'Arial Unicode MS', 'sans-serif']
plt.rcParams['axes.unicode_minus'] = False
plt.rcParams['font.size'] = 24
plt.rcParams['axes.labelsize'] = 28
plt.rcParams['xtick.labelsize'] = 22
plt.rcParams['ytick.labelsize'] = 22
plt.rcParams['legend.fontsize'] = 24
plt.rcParams['figure.figsize'] = (12, 8)

BLOCKSIZE = '4k'
BACKGROUND_COUNT = 8
IODEPTH_ORDER = [1, 4, 16, 64, 256, 1024]

DATA_SOURCES = [
    ('5.0bandwidth_summary.csv', '5.0'),
    ('4.0bandwidth_summary.csv', '4.0'),
]

OUTPUT_PNG = 'motivation_exp_bs_4k_count1_throughput.png'
OUTPUT_PDF = 'figures-main/motivation_exp_bs_4k_count1_throughput.pdf'


def extract_blocksize(test_name):
    match = re.search(r'bs-(\w+)_iodepth', str(test_name))
    return match.group(1).lower() if match else None


def extract_count(test_name):
    match = re.search(r'count-(\d+)', str(test_name))
    return int(match.group(1)) if match else None


def extract_iodepth(test_name):
    match = re.search(r'iodepth-(\d+)', str(test_name))
    return int(match.group(1)) if match else None


def load_bandwidth_table(csv_path):
    df = pd.read_csv(csv_path)
    bandwidth_col = '值' if '值' in df.columns else df.columns[2]
    rows = []
    for _, row in df.iterrows():
        test_name = row['测试名称']
        if pd.isna(test_name):
            continue
        blocksize = extract_blocksize(test_name)
        count = extract_count(test_name)
        iodepth = extract_iodepth(test_name)
        bandwidth_kb = row[bandwidth_col]
        if blocksize is None or count is None or iodepth is None:
            continue
        if pd.isna(bandwidth_kb):
            continue
        try:
            bandwidth_kb = float(bandwidth_kb)
        except (TypeError, ValueError):
            continue
        rows.append({
            'blocksize': blocksize,
            'count': count,
            'iodepth': iodepth,
            'bandwidth_kb': bandwidth_kb,
        })
    return pd.DataFrame(rows)


def aggregate_4k_count1(df, pcie_label):
    if df.empty:
        return pd.DataFrame(columns=['iodepth', 'bandwidth_gb', 'PCIe'])
    sub = df[(df['blocksize'] == BLOCKSIZE) & (df['count'] == BACKGROUND_COUNT)]
    if sub.empty:
        return pd.DataFrame(columns=['iodepth', 'bandwidth_gb', 'PCIe'])
    grouped = (
        sub.groupby('iodepth')['bandwidth_kb']
        .mean()
        .reset_index()
    )
    grouped['bandwidth_gb'] = grouped['bandwidth_kb'] / (1024 * 1024)
    grouped['PCIe'] = pcie_label
    grouped = grouped[grouped['iodepth'].isin(IODEPTH_ORDER)]
    grouped['iodepth'] = pd.Categorical(
        grouped['iodepth'], categories=IODEPTH_ORDER, ordered=True
    )
    return grouped.sort_values('iodepth')


def series_throughputs(grouped):
    iodepths = []
    throughputs = []
    for iod in IODEPTH_ORDER:
        row = grouped[grouped['iodepth'] == iod]
        if not row.empty:
            iodepths.append(iod)
            throughputs.append(row['bandwidth_gb'].iloc[0])
    return iodepths, throughputs


def main():
    all_grouped = []
    for csv_path, pcie_label in DATA_SOURCES:
        if not os.path.isfile(csv_path):
            print(f'警告: 找不到数据文件 {csv_path}')
            continue
        raw = load_bandwidth_table(csv_path)
        grouped = aggregate_4k_count1(raw, pcie_label)
        if grouped.empty:
            print(
                f'警告: {csv_path} 中无 bs={BLOCKSIZE}、count={BACKGROUND_COUNT} 的数据'
            )
        else:
            print(f'{pcie_label}: {len(grouped)} 个 IO depth 数据点')
            print(grouped[['iodepth', 'bandwidth_gb']])
        all_grouped.append((pcie_label, grouped))

    series = [(label, *series_throughputs(g)) for label, g in all_grouped if not g.empty]
    if not series:
        print('没有可绘制的数据，退出。')
        return

    fig, ax = plt.subplots()
    colors = {'5.0': 'tab:blue', '4.0': 'tab:orange'}
    hatches = {'5.0': '/', '4.0': 'x'}  # 与 plot_motivation_figures 一致，黑白打印可区分
    bar_width = 0.35 if len(series) == 2 else 0.4

    ref_iodepths = series[0][1]
    if len(series) == 2:
        ref_iodepths = sorted(set(series[0][1]) | set(series[1][1]), key=IODEPTH_ORDER.index)

    x = np.arange(len(ref_iodepths))
    for i, (label, iodepths, throughputs) in enumerate(series):
        means = []
        for iod in ref_iodepths:
            if iod in iodepths:
                idx = iodepths.index(iod)
                means.append(throughputs[idx])
            else:
                means.append(np.nan)
        offset = (i - (len(series) - 1) / 2) * bar_width
        ax.bar(
            x + offset,
            means,
            bar_width,
            label=f'PCIe {label}',
            color=colors.get(label, 'tab:blue'),
            hatch=hatches.get(label, '/'),
            edgecolor='black',
            linewidth=1.0,
        )

    ax.set_xticks(x)
    ax.set_xticklabels([str(d) for d in ref_iodepths])
    ax.set_xlabel('IO Depth')
    ax.set_ylabel('Throughput (GB/s)')
    ax.grid(True, axis='y', linestyle='--', linewidth=1, alpha=0.5)
    ax.legend(
        loc='lower center',
        bbox_to_anchor=(0.5, 1.0),
        ncol=len(series),
        frameon=False,
        borderaxespad=0,
        columnspacing=1.2,
        handletextpad=0.4,
        fontsize=24,
    )
    fig.tight_layout()
    fig.subplots_adjust(top=0.90)
    os.makedirs('figures-main', exist_ok=True)
    fig.savefig(OUTPUT_PNG, dpi=300, bbox_inches='tight')
    fig.savefig(OUTPUT_PDF, bbox_inches='tight')
    plt.close(fig)
    print(f'已保存: {OUTPUT_PNG}')
    print(f'已保存: {OUTPUT_PDF}')


if __name__ == '__main__':
    main()
