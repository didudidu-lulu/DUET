#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
以块大小为横坐标，不同duet_dual阈值配置为折线的latency分析
数据来源于高低阈值综合实验.xlsx
绘制四个子图，分别绘制2、4、8、16个Background数量的latency
子图1：绘制2个Background数量的latency，横坐标为块大小，纵坐标为latency，颜色为阈值标签，点型为块大小
子图2：绘制4个Background数量的latency，横坐标为块大小，纵坐标为latency，颜色为阈值标签，点型为块大小
子图3：绘制8个Background数量的latency，横坐标为块大小，纵坐标为latency，颜色为阈值标签，点型为块大小
子图4：绘制16个Background数量的latency，横坐标为块大小，纵坐标为latency，颜色为阈值标签，点型为块大小

Copyright (c) 2025 by ${git_name_email}, All Rights Reserved. 
"""

import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
import numpy as np
import seaborn as sns
from pathlib import Path
import os

# 设置字体大小
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


# 分析duet_dual数据以进行阈值比较
def analyze_duet_dual_data(file_path):
    df = load_experiment_data(file_path)
    df['块大小'] = normalize_block_size(df['块大小'])
    
    # 筛选duet_dual数据
    duet_dual_data = df[df['调度器模式'] == 'duet_dual']
    print(f"\nduet_dual数据量: {len(duet_dual_data)}")
    
    print("\n=== duet_dual的具体配置 ===")
    configs = duet_dual_data['具体配置'].unique()
    dual_threshold_mapping = {}
    
    for config in sorted(configs):
        config_data = duet_dual_data[duet_dual_data['具体配置'] == config]
        print(f"\n{config}:")
        print(f"  数据量: {len(config_data)}")
        print(f"  Background数量: {sorted(config_data['Background数量'].unique())}")
        print(f"  块大小: {sorted(config_data['块大小'].unique())}")
        
        # 提取高低阈值
        if 'duet_dual(' in config:
            threshold_str = config.split('(')[1].split(')')[0]
            high_threshold, low_threshold = threshold_str.split('/')
            high_threshold_mb = int(high_threshold) / (1024 * 1024)
            low_threshold_mb = int(low_threshold) / (1024 * 1024)
            dual_threshold_mapping[config] = (high_threshold_mb, low_threshold_mb)
            print(f"  高阈值: {high_threshold_mb:.0f}MB, 低阈值: {low_threshold_mb:.0f}MB")
    
    print(f"\n=== duet_dual阈值映射总览 ===")
    for config, (high, low) in sorted(dual_threshold_mapping.items(), key=lambda x: x[1][1]):
        print(f"{config} -> {high:.0f}MB/{low:.0f}MB")
    
    # 筛选duet_same数据作为4MB/4MB对比
    duet_same_data = df[df['调度器模式'] == 'duet_same']
    duet_same_4mb = duet_same_data[duet_same_data['具体配置'] == 'duet_same(4194304)']
    print(f"\n=== duet_same(4MB)数据作为4MB/4MB对比 ===")
    print(f"duet_same(4MB)数据量: {len(duet_same_4mb)}")
    if len(duet_same_4mb) > 0:
        print(f"Background数量: {sorted(duet_same_4mb['Background数量'].unique())}")
        print(f"块大小: {sorted(duet_same_4mb['块大小'].unique())}")
    
    return df, dual_threshold_mapping

# 准备duet_dual以块大小为横坐标的绘图数据
def prepare_duet_dual_plot_data(df, dual_threshold_mapping):
    # 复制duet_dual数据
    duet_dual_data = df[df['调度器模式'] == 'duet_dual'].copy()
    
    # 创建阈值标签映射字典
    threshold_label_mapping = {}
    for config, (high, low) in dual_threshold_mapping.items():
        threshold_label_mapping[config] = f'{low:.0f}MB'
    # 添加阈值标签
    duet_dual_data['阈值标签'] = duet_dual_data['具体配置'].map(threshold_label_mapping)

    # 筛选有效数据，即有阈值标签的数据
    valid_data = duet_dual_data[duet_dual_data['阈值标签'].notna()].copy()
    # 创建阈值标签映射字典
    threshold_label_mapping = {}
    for config, (high, low) in dual_threshold_mapping.items():
        threshold_label_mapping[config] = f'{low:.0f}MB'
    # 添加阈值标签
    duet_dual_data['阈值标签'] = duet_dual_data['具体配置'].map(threshold_label_mapping)
    # 筛选duet_same(4MB)数据作为4MB对比
    duet_same_4mb = df[df['具体配置'] == 'duet_same(4194304)'].copy()
    if len(duet_same_4mb) > 0:
        duet_same_4mb['阈值标签'] = '4MB'

        # 合并数据，即duet_dual数据和duet_same(4MB)数据
        combined_data = pd.concat([valid_data, duet_same_4mb], ignore_index=True)
        return combined_data
    else:
        return valid_data

# 将块大小字符串转换为数值（以KB为单位）
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

# 计算以块大小为基准的latency统计数据
def calculate_dual_latency_statistics(data):
    stats = data.groupby(['Background数量', '块大小', '阈值标签'])['Burst延迟(μs)'].agg([
        'mean', 'std', 'count'
    ]).reset_index()
    
    # 计算标准误差
    stats['stderr'] = stats['std'] / np.sqrt(stats['count'])
    
    # 添加块大小的数值版本用于排序
    stats['块大小数值'] = stats['块大小'].apply(convert_block_size_to_numeric)
    
    return stats

# 绘制单个Background数量的duet_dual latency图
def plot_single_dual_latency_chart(plot_data, count, output_dir):
    # 创建单个图，figsize为12x8
    fig, ax = plt.subplots(1, 1, figsize=(12, 8))
    
    # 筛选当前Background数量的数据，即plot_data中Background数量为count的数据
    count_data = plot_data[plot_data['Background数量'] == count]
    
    if len(count_data) == 0:
        ax.text(0.5, 0.5, f'No data for Background数量={count}', 
               ha='center', va='center', transform=ax.transAxes)
        ax.set_title(f'Background数量: {count}')
        return
    
    # 计算统计数据，即count_data中每个块大小、阈值标签的latency均值、标准差、数量
    stats = calculate_dual_latency_statistics(count_data)
    stats_for_count = stats[stats['Background数量'] == count]
    
    print(f"\n=== Background数量: {count} ===")
    print(stats_for_count[['块大小', '阈值标签', 'mean', 'stderr', 'count']])
    
    if len(stats_for_count) == 0:
        ax.text(0.5, 0.5, f'No statistics for Background数量={count}', 
               ha='center', va='center', transform=ax.transAxes)
        ax.set_title(f'Background数量: {count}')
        return
    
    # 获取所有阈值标签并按数值从大到小排序
    threshold_labels = sorted(
        stats_for_count['阈值标签'].unique(),
        key=lambda x: -float(x.replace('MB', ''))
    )
    
    # 设置颜色方案和标记形状
    colors = plt.cm.tab10(np.linspace(0, 1, len(threshold_labels)))
    markers = ['o', 's', '^', 'D', 'v', '<', '>', 'p', '*', 'h']
    
    # 为每个阈值绘制一条线
    for j, threshold_label in enumerate(threshold_labels):
        threshold_stats = stats_for_count[stats_for_count['阈值标签'] == threshold_label]
        
        if len(threshold_stats) == 0:
            continue
        
        # 按块大小数值排序
        threshold_stats = threshold_stats.sort_values('块大小数值')
        
        block_sizes = threshold_stats['块大小'].values
        means = threshold_stats['mean'].values
        errors = threshold_stats['stderr'].values
        
        # 创建x轴位置
        x_positions = range(len(block_sizes))
        
        # 绘制折线图
        line_style = '--'  # 改为虚线
        marker_style = markers[j % len(markers)]
        
        ax.errorbar(x_positions, means, yerr=errors, 
                   marker=marker_style, linewidth=3.0, markersize=10,
                   capsize=4, capthick=2, elinewidth=2,
                   linestyle=line_style, color=colors[j], 
                   label=threshold_label, markerfacecolor='white', 
                   markeredgewidth=2.2, markeredgecolor=colors[j])
    
    # 设置x轴标签
    if len(stats_for_count) > 0:
        # 获取所有块大小并排序
        all_block_sizes = sorted(stats_for_count['块大小'].unique(), 
                               key=convert_block_size_to_numeric)
        x_positions = range(len(all_block_sizes))
        ax.set_xticks(x_positions)
        ax.set_xticklabels(all_block_sizes)
    
    # 设置标题和标签
    # ax.set_title(f'Background任务数量: {count}', fontsize=24, fontweight='bold')  # 取消标题
    ax.set_xlabel('Sustained blocksize (Byte)')
    ax.set_ylabel('Burst latency (us)')
    ax.grid(True, alpha=0.3)
    
    # 图例设置，完全统一为experiment_throughput风格
    # 图例不换行，ncol设为图例项总数
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
    # 统一布局调整方式
    plt.tight_layout(rect=[0,0,1,0.95])
    
    # 确保输出目录存在
    os.makedirs(output_dir, exist_ok=True)
    
    # 保存图片
    plt.savefig(f'{output_dir}/duet_dual_latency_background_{count}.png', dpi=300, bbox_inches='tight')
    plt.savefig(f'{output_dir}/duet_dual_latency_background_{count}.pdf')
    
    plt.close()  # 关闭图形以释放内存

def main():
    """
    主函数
    """
    # 数据文件路径
    data_file = Path("高低阈值综合实验.xlsx")
    
    if not data_file.exists():
        print(f"错误: 找不到数据文件 {data_file}")
        return
    
    # 输出目录
    output_dir = "figures-main"
    
    print("正在分析duet_dual数据...")
    df, dual_threshold_mapping = analyze_duet_dual_data(data_file)
    
    print("\n正在准备duet_dual绘图数据...")
    plot_data = prepare_duet_dual_plot_data(df, dual_threshold_mapping)
    
    print(f"\n绘图数据形状: {plot_data.shape}")
    print(f"Background数量分布: {plot_data['Background数量'].value_counts().sort_index()}")
    print(f"阈值标签分布: {plot_data['阈值标签'].value_counts()}")
    print(f"块大小分布: {plot_data['块大小'].value_counts()}")
    
    # 根据count数为2、4、8、16生成四张独立图片
    count_list = [2, 4, 8, 16]
    
    print(f"\n正在生成四张独立的duet_dual latency图片到 {output_dir} 文件夹...")
    for count in count_list:
        print(f"正在生成 Background数量={count} 的图片...")
        plot_single_dual_latency_chart(plot_data, count, output_dir)
    
    print(f"\n所有图片已保存到 '{output_dir}' 文件夹")

if __name__ == "__main__":
    main()
