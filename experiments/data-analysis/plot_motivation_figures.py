'''
Author: 刘佳丽 1552860603@qq.com
Date: 2025-08-11 16:49:05
LastEditors: Jiali Liu 1552860603@qq.com
LastEditTime: 2026-05-16 18:45:26
FilePath: /DUET/实验数据处理/阈值实验数据处理/plot_motivation_figures.py
Description: 动机实验数据绘制脚本
数据来源于realtime_data.csv
绘制两个子图，分别绘制throughput和latency
子图1：绘制throughput，横坐标为块大小，纵坐标为throughput，颜色为调度器模式，点型为块大小
子图2：绘制latency，横坐标为块大小，纵坐标为latency，颜色为调度器模式，点型为块大小

Copyright (c) 2025 by ${git_name_email}, All Rights Reserved. 
'''

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
import os

# 全局字体和画布设置
plt.rcParams['font.size'] = 24
plt.rcParams['axes.labelsize'] = 28
plt.rcParams['xtick.labelsize'] = 22
plt.rcParams['ytick.labelsize'] = 22
plt.rcParams['legend.fontsize'] = 24
plt.rcParams['figure.figsize'] = (12, 8)

# 读取数据
df = pd.read_csv('realtime_data.csv')

# 只保留 Background数量=8 且调度器模式为 none 或 bfq 的数据
df['调度器模式'] = df['调度器模式'].astype(str).str.lower().str.strip()
df = df[(df['Background数量'] == 8) & (df['调度器模式'].isin(['none', 'bfq']))]

blocksizes = ['4K', '16K', '64K', '256K', '1M', '4M']
modes = ['none', 'bfq']

# 生成用于绘图的数据表格
data_table = []
for mode in modes:
    for b in blocksizes:
        sub = df[(df['调度器模式'] == mode) & (df['块大小'].astype(str).str.upper() == b.upper())]
        if len(sub) == 3:
            throughput_vals = sub['Sustained吞吐量'].apply(lambda x: float(str(x).replace('GB/s', ''))).values
            latency_vals = sub['Burst延迟(μs)'].astype(float).values
            data_table.append({
                '调度器模式': mode,
                '块大小': b,
                '吞吐量均值': np.mean(throughput_vals),
                '吞吐量标准差': np.std(throughput_vals, ddof=0),
                '延迟均值': np.mean(latency_vals),
                '延迟标准差': np.std(latency_vals, ddof=0)
            })

data_df = pd.DataFrame(data_table, columns=[
    '调度器模式', '块大小', '吞吐量均值', '吞吐量标准差', '延迟均值', '延迟标准差'
])
data_df.to_excel('figures-main/motivation_figures_data_bg8.xlsx', index=False)

# 检查数据是否为空
if data_df.empty:
    print("数据表为空，请检查数据源或筛选条件。")
    exit(1)

# 绘制throughput图
plt.figure()
# 设置bar宽度
bar_width = 0.35
# 创建x轴位置
x = np.arange(len(blocksizes))
# 设置颜色和填充图案
colors = ['tab:blue', 'tab:orange']
hatches = ['/', '\\']

# 遍历调度器模式
for i, mode in enumerate(modes):
    # 创建空列表，用于存储每个块大小的吞吐量均值和标准差
    means = []
    stds = []
    # 遍历块大小
    for b in blocksizes:
        # 筛选数据
        row = data_df[(data_df['调度器模式'] == mode) & (data_df['块大小'] == b)]
        # 将吞吐量均值和标准差添加到列表中
        means.append(row['吞吐量均值'].values[0] if not row.empty else 0)
        stds.append(row['吞吐量标准差'].values[0] if not row.empty else 0)
    bars = plt.bar(x + i*bar_width, means, bar_width, yerr=stds, label=mode.upper(), capsize=4, color=colors[i], edgecolor='black', hatch=hatches[i])
# 设置网格
plt.grid(True, axis='y', linestyle='--', linewidth=1, alpha=0.5)
# 设置x轴刻度
plt.xticks(x + bar_width/2, blocksizes)
# 设置x轴标签
plt.xlabel('Sustained Block Size (Byte)')
# 设置y轴标签
plt.ylabel('Sustained Throughput (GB/s)')
# 设置图例
plt.legend(loc='upper center', bbox_to_anchor=(0.5, 1.12), ncol=2, frameon=False)
# 设置布局
plt.tight_layout(rect=[0,0,1,0.95])
# 创建figures-main目录
os.makedirs('figures-main', exist_ok=True)
# 保存为figures-main文件
plt.savefig('figures-main/motivation_throughput.pdf')
plt.close()

# 绘制latency图
plt.figure()
# 设置点型
markers = ['o', 's']
colors = ['tab:blue', 'tab:orange']
# 遍历调度器模式
for i, mode in enumerate(modes):
    # 创建空列表，用于存储每个块大小的延迟均值和标准差
    means = []
    # 创建空列表，用于存储每个块大小的延迟标准差
    stds = []
    for b in blocksizes:
        # 筛选数据
        row = data_df[(data_df['调度器模式'] == mode) & (data_df['块大小'] == b)]
        # 将延迟均值和标准差添加到列表中
        means.append(row['延迟均值'].values[0] if not row.empty else 0)
        stds.append(row['延迟标准差'].values[0] if not row.empty else 0)
    plt.errorbar(blocksizes, means, yerr=stds, marker=markers[i], label=mode.upper(), capsize=4, color=colors[i], linestyle='-', markersize=6)
# 设置网格
plt.grid(True, linestyle='--', linewidth=1, alpha=0.5)
# 设置x轴标签
plt.xlabel('Sustained Block Size (Byte)')
# 设置y轴标签
plt.ylabel('Burst Mean Latency (μs)')
# 设置图例
plt.legend(loc='upper center', bbox_to_anchor=(0.5, 1.12), ncol=2, frameon=False)
# 设置布局
plt.tight_layout(rect=[0,0,1,0.95])
# 保存为figures-main文件
plt.savefig('figures-main/motivation_latency.pdf')
plt.close()