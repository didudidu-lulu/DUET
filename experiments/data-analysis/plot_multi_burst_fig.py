'''
Author: 刘佳丽 1552860603@qq.com
Date: 2026-05-19
Description: burst 进程并行度敏感性实验绘图脚本
数据来源于 multi_burst.csv
绘制两张图：Sustained 吞吐量（柱状图）与 Burst 平均延迟（折线图）
横坐标为 Burst 进程数量，风格与 plot_sustained_bgcount_fig.py 一致
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

# 读取数据表
df = pd.read_csv('multi_burst.csv')
df['调度器模式'] = df['调度器模式'].astype(str).str.lower().str.strip()

# 调度器模式列表
select_modes = ['none', 'bfq', 'duet_same']
# 固定 Background=8、块大小 1M，仅保留目标调度器
df = df[
    (df['Background数量'] == 8)
    & (df['块大小'].astype(str).str.upper() == '1M')
    & (df['调度器模式'].isin(select_modes))
]

# Burst 进程数量（横坐标）
burst_counts = [2, 4, 8, 16]
modes = ['none', 'bfq', 'duet_same']
mode_labels = {'none': 'NONE', 'bfq': 'BFQ', 'duet_same': 'DUET'}

# 生成用于绘图的数据表格：每个模式、每个 burst 进程数取 3 次重复，计算均值与标准差
data_table = []
for mode in modes:
    for burst in burst_counts:
        if mode == 'duet_same':
            sub = df[
                (df['调度器模式'] == mode)
                & (df['Burst进程数'] == burst)
                & (df['具体配置'] == 'duet_same(4194304)')
            ]
        else:
            sub = df[(df['调度器模式'] == mode) & (df['Burst进程数'] == burst)]
        if len(sub) == 3:
            throughput_vals = sub['Sustained吞吐量'].apply(
                lambda x: float(str(x).replace('GB/s', ''))
            ).values
            latency_vals = sub['Burst延迟(μs)'].astype(float).values
            data_table.append({
                '调度器模式': mode_labels[mode],
                'Burst进程数': burst,
                '吞吐量均值': np.mean(throughput_vals),
                '吞吐量标准差': np.std(throughput_vals, ddof=0),
                '延迟均值': np.mean(latency_vals),
                '延迟标准差': np.std(latency_vals, ddof=0),
            })

os.makedirs('figures-main', exist_ok=True)
data_df = pd.DataFrame(data_table, columns=[
    '调度器模式', 'Burst进程数', '吞吐量均值', '吞吐量标准差', '延迟均值', '延迟标准差'
])
data_df.to_excel('figures-main/multi_burst_figures_data.xlsx', index=False)

if data_df.empty:
    print("数据表为空，请检查数据源或筛选条件。")
    exit(1)

# 绘制吞吐量柱状图（彩色+不同填充，图例在上方）
plt.figure()
bar_width = 0.22
x = np.arange(len(burst_counts))
colors = ['tab:blue', 'tab:orange', 'tab:green']
hatches = ['/', '\\', '']
for i, mode in enumerate(mode_labels.values()):
    means = []
    stds = []
    for burst in burst_counts:
        row = data_df[(data_df['调度器模式'] == mode) & (data_df['Burst进程数'] == burst)]
        means.append(row['吞吐量均值'].values[0] if not row.empty else 0)
        stds.append(row['吞吐量标准差'].values[0] if not row.empty else 0)
    plt.bar(
        x + i * bar_width, means, bar_width, yerr=stds, label=mode,
        capsize=4, color=colors[i], edgecolor='black', hatch=hatches[i],
    )
plt.grid(True, axis='y', linestyle='--', linewidth=1, alpha=0.5)
plt.xticks(x + bar_width, burst_counts)
plt.xlabel('Number of Burst Workloads')
plt.ylabel('Sustained Throughput (GB/s)')
plt.legend(loc='upper center', bbox_to_anchor=(0.5, 1.12), ncol=3, frameon=False)
plt.tight_layout(rect=[0, 0, 1, 0.95])
plt.savefig('figures-main/multi_burst_throughput.pdf')
plt.close()

# 绘制延迟折线图（彩色+不同点型，图例在上方）
plt.figure()
markers = ['o', 's', '^']
colors = ['tab:blue', 'tab:orange', 'tab:green']
latency_x = burst_counts
x_latency = np.arange(len(latency_x))
for i, mode in enumerate(mode_labels.values()):
    means = []
    stds = []
    for burst in latency_x:
        row = data_df[(data_df['调度器模式'] == mode) & (data_df['Burst进程数'] == burst)]
        means.append(row['延迟均值'].values[0] if not row.empty else 0)
        stds.append(row['延迟标准差'].values[0] if not row.empty else 0)
    plt.errorbar(
        x_latency, means, yerr=stds, marker=markers[i], label=mode,
        capsize=4, color=colors[i], linestyle='-', markersize=8,
    )
plt.grid(True, linestyle='--', linewidth=1, alpha=0.5)
plt.xticks(x_latency, latency_x)
plt.xlabel('Number of Burst Workloads')
plt.ylabel('Burst Latency (μs)')
plt.legend(loc='upper center', bbox_to_anchor=(0.5, 1.12), ncol=3, frameon=False)
plt.tight_layout(rect=[0, 0, 1, 0.95])
plt.savefig('figures-main/multi_burst_latency.pdf')
plt.close()

print("绘图完成：")
print("  - figures-main/multi_burst_throughput.pdf")
print("  - figures-main/multi_burst_latency.pdf")
print("  - figures-main/multi_burst_figures_data.xlsx")
