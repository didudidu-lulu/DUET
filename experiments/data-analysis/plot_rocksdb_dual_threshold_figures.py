#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RocksDB 场景下低阈值效果对比图
数据来源于 RocksDB_data.csv
- bfq_limit_same：高/低阈值均为 4MB（图例 4MB）
- bfq_limit_dual(4MB/*MB)：低阈值为 3MB / 2MB / 1MB
横坐标为 bg_count，纵坐标分别为 RocksDB 真实 Get 延迟与 fio 吞吐量
样式参照 plot_duet_dual_latency_separate.py / plot_duet_dual_throughput_separate.py
"""

import os

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

# 全局字体和画布设置
plt.rcParams['font.size'] = 24
plt.rcParams['axes.labelsize'] = 28
plt.rcParams['xtick.labelsize'] = 22
plt.rcParams['ytick.labelsize'] = 22
plt.rcParams['legend.fontsize'] = 24
plt.rcParams['figure.figsize'] = (12, 8)

BG_COUNTS = [2, 4, 8, 16]
EXPECTED_RUNS = 3


def parse_low_threshold_mb(row):
    """从调度器模式与阈值列解析低阈值标签（MB）。"""
    mode = str(row['调度器模式']).lower().strip()
    if mode == 'bfq_limit_same':
        return 4
    if mode == 'bfq_limit_dual':
        low = row['low_threshold']
        if pd.isna(low) or str(low).upper() == 'N/A':
            desc = str(row['配置描述'])
            if 'dual:' in desc:
                low_str = desc.split('dual:')[1].split(')')[0].split('/')[1]
                return int(low_str) / (1024 * 1024)
            return None
        return int(float(low)) / (1024 * 1024)
    return None


def load_plot_data(csv_path='RocksDB_data.csv'):
    df = pd.read_csv(csv_path)
    df['调度器模式'] = df['调度器模式'].astype(str).str.lower().str.strip()
    df = df[
        (df['块大小'].astype(str).str.upper() == '1M')
        & (df['调度器模式'].isin(['bfq_limit_same', 'bfq_limit_dual']))
    ].copy()
    df['阈值标签'] = df.apply(
        lambda r: f'{parse_low_threshold_mb(r):.0f}MB'
        if parse_low_threshold_mb(r) is not None else None,
        axis=1,
    )
    return df[df['阈值标签'].notna()].copy()


def sort_threshold_labels(labels):
    return sorted(labels, key=lambda x: -float(x.replace('MB', '')))


def compute_statistics(df):
    """按阈值标签与 bg_count 聚合，返回 mean/std/count/stderr。"""
    records = []
    for label in sort_threshold_labels(df['阈值标签'].unique()):
        for bg in BG_COUNTS:
            sub = df[(df['阈值标签'] == label) & (df['Background数量'] == bg)]
            if len(sub) != EXPECTED_RUNS:
                continue
            tp_vals = sub['fio吞吐量(MB/s)'].astype(float).values / 1024.0
            lat_vals = sub['RocksDB真实Get平均延迟(μs)'].astype(float).values
            count = len(sub)
            tp_std = np.std(tp_vals, ddof=0)
            lat_std = np.std(lat_vals, ddof=0)
            records.append({
                '阈值标签': label,
                '背景流数量': bg,
                '吞吐量均值': np.mean(tp_vals),
                '吞吐量标准差': tp_std,
                '吞吐量标准误': tp_std / np.sqrt(count),
                '延迟均值': np.mean(lat_vals),
                '延迟标准差': lat_std,
                '延迟标准误': lat_std / np.sqrt(count),
                '样本数': count,
            })
    return pd.DataFrame(records)


def plot_latency(stats_df, output_dir='figures-main'):
    fig, ax = plt.subplots(1, 1, figsize=(12, 8))
    threshold_labels = sort_threshold_labels(stats_df['阈值标签'].unique())
    colors = plt.cm.tab10(np.linspace(0, 1, len(threshold_labels)))
    markers = ['o', 's', '^', 'D', 'v', '<', '>', 'p', '*', 'h']
    x_positions = np.arange(len(BG_COUNTS))

    for j, label in enumerate(threshold_labels):
        means, errors = [], []
        for bg in BG_COUNTS:
            row = stats_df[(stats_df['阈值标签'] == label) & (stats_df['背景流数量'] == bg)]
            if row.empty:
                means.append(np.nan)
                errors.append(0)
            else:
                means.append(row['延迟均值'].values[0])
                errors.append(row['延迟标准误'].values[0])

        ax.errorbar(
            x_positions, means, yerr=errors,
            marker=markers[j % len(markers)], linewidth=2.5, markersize=8,
            capsize=4, capthick=2, elinewidth=2,
            linestyle='--', color=colors[j], label=label,
            markerfacecolor='white', markeredgewidth=2, markeredgecolor=colors[j],
        )

    ax.set_xticks(x_positions)
    ax.set_xticklabels(BG_COUNTS)
    ax.set_xlabel('Number of Sustained Workloads')
    ax.set_ylabel('Mean Burst Latency (μs)')
    ax.grid(True, alpha=0.3)
    plt.legend(
        loc='upper center',
        bbox_to_anchor=(0.5, 1.12),
        ncol=len(threshold_labels),
        frameon=False,
    )
    plt.tight_layout(rect=[0, 0, 1, 0.95])
    os.makedirs(output_dir, exist_ok=True)
    plt.savefig(f'{output_dir}/rocksdb_dual_get_latency.pdf')
    plt.savefig(f'{output_dir}/rocksdb_dual_get_latency.png', dpi=300, bbox_inches='tight')
    plt.close()


def plot_throughput(stats_df, output_dir='figures-main'):
    fig, ax = plt.subplots(1, 1, figsize=(12, 8))
    threshold_labels = sort_threshold_labels(stats_df['阈值标签'].unique())
    academic_colors = ['#1f77b4', '#ff7f0e', '#2ca02c', '#d62728']
    colors = academic_colors[:len(threshold_labels)]
    patterns = ['', '///', '...', '\\\\\\', '|||', '---', '+++', 'xxx', 'ooo', '***']

    n_thresholds = len(threshold_labels)
    n_bg = len(BG_COUNTS)
    bar_width = 0.18
    group_spacing = 1.2
    x_groups = np.arange(n_bg) * group_spacing

    for j, label in enumerate(threshold_labels):
        means, errors = [], []
        for bg in BG_COUNTS:
            row = stats_df[(stats_df['阈值标签'] == label) & (stats_df['背景流数量'] == bg)]
            if row.empty:
                means.append(0)
                errors.append(0)
            else:
                means.append(row['吞吐量均值'].values[0])
                errors.append(row['吞吐量标准误'].values[0])

        bar_positions = x_groups + (j - n_thresholds / 2 + 0.5) * bar_width
        ax.bar(
            bar_positions, means, bar_width,
            yerr=errors, capsize=4,
            color=colors[j], alpha=0.8,
            hatch=patterns[j % len(patterns)],
            label=label,
            edgecolor='black', linewidth=1,
        )

    ax.set_xticks(x_groups)
    ax.set_xticklabels(BG_COUNTS)
    ax.set_xlabel('Number of Sustained Workloads')
    ax.set_ylabel('Sustained Throughput (GB/s)')
    ax.grid(True, alpha=0.3, axis='y')
    max_val = stats_df['吞吐量均值'].max() if len(stats_df) > 0 else 15
    ax.set_ylim(0, max_val * 1.1)
    plt.legend(
        loc='upper center',
        bbox_to_anchor=(0.5, 1.12),
        ncol=len(threshold_labels),
        frameon=False,
    )
    plt.tight_layout(rect=[0, 0, 1, 0.95])
    os.makedirs(output_dir, exist_ok=True)
    plt.savefig(f'{output_dir}/rocksdb_dual_fio_throughput.pdf')
    plt.savefig(f'{output_dir}/rocksdb_dual_fio_throughput.png', dpi=300, bbox_inches='tight')
    plt.close()


def main():
    plot_df = load_plot_data()
    stats_df = compute_statistics(plot_df)

    os.makedirs('figures-main', exist_ok=True)
    stats_df.to_excel('figures-main/rocksdb_dual_threshold_figures_data.xlsx', index=False)

    if stats_df.empty:
        print('数据表为空，请检查 RocksDB_data.csv 或筛选条件。')
        return

    print('阈值标签分布:')
    print(stats_df.groupby('阈值标签').size())
    print('\n统计数据预览:')
    print(stats_df)

    plot_latency(stats_df)
    plot_throughput(stats_df)
    print('\n已生成:')
    print('  figures-main/rocksdb_dual_get_latency.pdf')
    print('  figures-main/rocksdb_dual_fio_throughput.pdf')
    print('  figures-main/rocksdb_dual_threshold_figures_data.xlsx')


if __name__ == '__main__':
    main()
