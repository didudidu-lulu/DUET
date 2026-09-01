#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PCIe 4.0 设备：以块大小为横坐标，不同 duet_dual 阈值配置为柱状图的 sustained throughput 分析。
数据来源于高低阈值综合实验4.0.csv。
图例：2MB、1MB、512KB、256KB。
分别绘制 Background 数量为 2、4、8、16 的四张独立图。

Copyright (c) 2025 by ${git_name_email}, All Rights Reserved.
"""

import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
import numpy as np
from pathlib import Path
import os

DATA_FILE = Path("高低阈值综合实验4.0.csv")
OUTPUT_DIR = "figures-pcie4"
DUET_SAME_BASELINE_CONFIG = "duet_same(2097152)"
DUET_SAME_BASELINE_LABEL = "2MB"
LEGEND_ORDER = ["2MB", "1MB", "512KB", "256KB"]

plt.rcParams['font.size'] = 24
plt.rcParams['axes.labelsize'] = 28
plt.rcParams['xtick.labelsize'] = 22
plt.rcParams['ytick.labelsize'] = 22
plt.rcParams['legend.fontsize'] = 24
plt.rcParams['figure.figsize'] = (12, 8)


def load_experiment_data(file_path):
    """读取 .csv 或 .xlsx（含 realtime_data 工作表）。"""
    path = Path(file_path)
    if path.suffix.lower() == '.csv':
        return pd.read_csv(path)
    return pd.read_excel(path, sheet_name='realtime_data')


def normalize_block_size(series):
    mapping = {
        '4K': '4K', '4': '4K',
        '16K': '16K', '16': '16K',
        '64K': '64K', '64': '64K',
        '256K': '256K', '256': '256K',
        '1M': '1M', '1024K': '1M', '1024': '1M',
        '4M': '4M', '4096K': '4M', '4096': '4M',
    }
    return series.astype(str).str.strip().str.upper().map(
        lambda x: mapping.get(x, x)
    )


def bytes_to_threshold_label(n_bytes):
    """将阈值字节数格式化为图例标签（如 2MB、512KB）。"""
    n = int(n_bytes)
    if n >= 1024 * 1024 and n % (1024 * 1024) == 0:
        return f'{n // (1024 * 1024)}MB'
    if n >= 1024 and n % 1024 == 0:
        return f'{n // 1024}KB'
    return f'{n}B'


def threshold_label_sort_key(label):
    """按阈值从大到小排序图例。"""
    if label in LEGEND_ORDER:
        return LEGEND_ORDER.index(label)
    if label.endswith('MB'):
        return -float(label.replace('MB', ''))
    if label.endswith('KB'):
        return -float(label.replace('KB', '')) / 1024
    return 0


def analyze_duet_dual_throughput_data(file_path):
    df = load_experiment_data(file_path)
    df['块大小'] = normalize_block_size(df['块大小'])

    duet_dual_data = df[df['调度器模式'] == 'duet_dual']
    print(f"\nduet_dual数据量: {len(duet_dual_data)}")

    configs = duet_dual_data['具体配置'].unique()
    dual_threshold_mapping = {}

    for config in sorted(configs):
        config_data = duet_dual_data[duet_dual_data['具体配置'] == config]
        print(f"\n{config}:")
        print(f"  数据量: {len(config_data)}")
        print(f"  Background数量: {sorted(config_data['Background数量'].unique())}")
        print(f"  块大小: {sorted(config_data['块大小'].unique())}")

        if 'duet_dual(' in config:
            threshold_str = config.split('(')[1].split(')')[0]
            high_threshold, low_threshold = threshold_str.split('/')
            high_bytes = int(high_threshold)
            low_bytes = int(low_threshold)
            dual_threshold_mapping[config] = (high_bytes, low_bytes)
            print(
                f"  高阈值: {bytes_to_threshold_label(high_bytes)}, "
                f"低阈值: {bytes_to_threshold_label(low_bytes)}"
            )

    for config, (high, low) in sorted(dual_threshold_mapping.items(), key=lambda x: x[1][1]):
        print(
            f"{config} -> "
            f"{bytes_to_threshold_label(high)}/{bytes_to_threshold_label(low)}"
        )

    duet_same_baseline = df[df['具体配置'] == DUET_SAME_BASELINE_CONFIG]
    print(f"\n=== {DUET_SAME_BASELINE_CONFIG} 作为 {DUET_SAME_BASELINE_LABEL} 对比 ===")
    print(f"数据量: {len(duet_same_baseline)}")
    if len(duet_same_baseline) > 0:
        print(f"Background数量: {sorted(duet_same_baseline['Background数量'].unique())}")
        print(f"块大小: {sorted(duet_same_baseline['块大小'].unique())}")

    return df, dual_threshold_mapping


def prepare_duet_dual_throughput_data(df, dual_threshold_mapping):
    duet_dual_data = df[df['调度器模式'] == 'duet_dual'].copy()

    threshold_label_mapping = {
        config: bytes_to_threshold_label(low)
        for config, (_, low) in dual_threshold_mapping.items()
    }
    duet_dual_data['阈值标签'] = duet_dual_data['具体配置'].map(threshold_label_mapping)
    valid_data = duet_dual_data[duet_dual_data['阈值标签'].notna()].copy()

    duet_same_baseline = df[df['具体配置'] == DUET_SAME_BASELINE_CONFIG].copy()
    if len(duet_same_baseline) > 0:
        duet_same_baseline['阈值标签'] = DUET_SAME_BASELINE_LABEL
        return pd.concat([valid_data, duet_same_baseline], ignore_index=True)
    return valid_data


def convert_throughput_to_numeric(throughput_str):
    if pd.isna(throughput_str):
        return 0
    if isinstance(throughput_str, str):
        if throughput_str == '解析失败' or 'GB/s' not in throughput_str:
            return 0
        return float(throughput_str.replace('GB/s', ''))
    return float(throughput_str)


def convert_block_size_to_numeric(block_size_str):
    size_mapping = {
        '4K': 4,
        '16K': 16,
        '64K': 64,
        '256K': 256,
        '1M': 1024,
        '4M': 4096
    }
    return size_mapping.get(block_size_str, 0)


def calculate_dual_throughput_statistics(data):
    data = data.copy()
    data['Sustained吞吐量_数值'] = data['Sustained吞吐量'].apply(convert_throughput_to_numeric)

    stats = data.groupby(['Background数量', '块大小', '阈值标签'])['Sustained吞吐量_数值'].agg([
        'mean', 'std', 'count'
    ]).reset_index()

    stats['stderr'] = stats['std'] / np.sqrt(stats['count'])
    stats['块大小数值'] = stats['块大小'].apply(convert_block_size_to_numeric)
    return stats


def sort_threshold_labels(labels):
    return sorted(labels, key=threshold_label_sort_key)


def plot_single_dual_throughput_chart(plot_data, count, output_dir):
    fig, ax = plt.subplots(1, 1, figsize=(12, 8))

    count_data = plot_data[plot_data['Background数量'] == count]

    if len(count_data) == 0:
        ax.text(0.5, 0.5, f'No data for Background数量={count}',
                ha='center', va='center', transform=ax.transAxes)
        return

    stats = calculate_dual_throughput_statistics(count_data)
    stats_for_count = stats[stats['Background数量'] == count]

    print(f"\n=== Background数量: {count} (PCIe 4.0) ===")
    print(stats_for_count[['块大小', '阈值标签', 'mean', 'stderr', 'count']])

    if len(stats_for_count) == 0:
        ax.text(0.5, 0.5, f'No statistics for Background数量={count}',
                ha='center', va='center', transform=ax.transAxes)
        return

    threshold_labels = sort_threshold_labels(stats_for_count['阈值标签'].unique())

    academic_colors = ['#1f77b4', '#ff7f0e', '#2ca02c', '#d62728']
    colors = academic_colors[:len(threshold_labels)]
    patterns = ['', '///', '...', '\\\\\\', '|||', '---', '+++', 'xxx', 'ooo', '***']

    all_block_sizes = sorted(
        stats_for_count['块大小'].unique(),
        key=convert_block_size_to_numeric
    )

    n_thresholds = len(threshold_labels)
    n_block_sizes = len(all_block_sizes)
    bar_width = 0.25
    group_spacing = 1.2

    for j, threshold_label in enumerate(threshold_labels):
        threshold_stats = stats_for_count[stats_for_count['阈值标签'] == threshold_label]
        if len(threshold_stats) == 0:
            continue

        threshold_stats = threshold_stats.sort_values('块大小数值')

        means = []
        errors = []
        for block_size in all_block_sizes:
            block_stat = threshold_stats[threshold_stats['块大小'] == block_size]
            if len(block_stat) > 0:
                means.append(block_stat['mean'].iloc[0])
                errors.append(block_stat['stderr'].iloc[0])
            else:
                means.append(0)
                errors.append(0)

        x_positions = np.arange(n_block_sizes) * group_spacing
        bar_positions = x_positions + (j - n_thresholds / 2 + 0.5) * bar_width

        ax.bar(
            bar_positions, means, bar_width,
            yerr=errors, capsize=5,
            error_kw={'elinewidth': 2.0, 'capthick': 2.0},
            color=colors[j], alpha=0.8,
            hatch=patterns[j % len(patterns)],
            label=threshold_label,
            edgecolor='black', linewidth=1.5
        )

    ax.set_xticks(np.arange(n_block_sizes) * group_spacing)
    ax.set_xticklabels(all_block_sizes)

    ax.set_xlabel('Sustained blocksize (Byte)')
    ax.set_ylabel('Sustained throughput (GB/s)')
    ax.grid(True, alpha=0.3, axis='y')

    legend_handles, legend_labels = ax.get_legend_handles_labels()
    legend_handles.insert(0, Line2D([], [], linestyle='None'))
    legend_labels.insert(0, r'Low Threshold ($T_{low}$)')
    plt.legend(
        legend_handles,
        legend_labels,
        loc='lower left',
        bbox_to_anchor=(0, 1.02, 1, 0.1),
        mode='expand',
        ncol=len(legend_labels),
        fontsize=20,
        handlelength=1.2,
        columnspacing=0.35,
        handletextpad=0.2,
        labelspacing=0.2,
        borderaxespad=0.0,
        frameon=False
    )
    plt.tight_layout(rect=[0, 0, 1, 0.95])

    max_val = stats_for_count['mean'].max() if len(stats_for_count) > 0 else 15
    ax.set_ylim(0, max_val * 1.1)

    os.makedirs(output_dir, exist_ok=True)
    prefix = f'{output_dir}/duet_dual_throughput_pcie4.0_background_{count}'
    plt.savefig(f'{prefix}.png', dpi=300)
    plt.savefig(f'{prefix}.pdf')
    plt.close()


def main():
    if not DATA_FILE.exists():
        print(f"错误: 找不到数据文件 {DATA_FILE}")
        return

    print("正在分析 PCIe 4.0 duet_dual throughput 数据...")
    df, dual_threshold_mapping = analyze_duet_dual_throughput_data(DATA_FILE)

    print("\n正在准备 PCIe 4.0 duet_dual throughput 绘图数据...")
    plot_data = prepare_duet_dual_throughput_data(df, dual_threshold_mapping)

    print(f"\n绘图数据形状: {plot_data.shape}")
    print(f"Background数量分布: {plot_data['Background数量'].value_counts().sort_index()}")
    print(f"阈值标签分布: {plot_data['阈值标签'].value_counts()}")
    print(f"块大小分布: {plot_data['块大小'].value_counts()}")

    count_list = [2, 4, 8, 16]
    print(f"\n正在生成 PCIe 4.0 throughput 图片到 {OUTPUT_DIR} 文件夹...")
    for count in count_list:
        print(f"正在生成 Background数量={count} 的图片...")
        plot_single_dual_throughput_chart(plot_data, count, OUTPUT_DIR)

    print(f"\n所有图片已保存到 '{OUTPUT_DIR}' 文件夹")


if __name__ == "__main__":
    main()
