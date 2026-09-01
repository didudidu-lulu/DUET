'''
Author: 刘佳丽 1552860603@qq.com
Date: 2026-05-16
Description: RocksDB 场景下，横坐标为 bg_count（背景流数量）的 fio 吞吐量与 Get 延迟绘制脚本
数据来源于 RocksDB_data.csv
筛选 NONE、BFQ、DUET(bfq_limit_same)，各配置 3 次重复实验取均值与标准差
'''

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
import os

# 全局字体和画布设置（与 plot_sustained_bgcount_fig.py 一致）
plt.rcParams['font.size'] = 24
plt.rcParams['axes.labelsize'] = 28
plt.rcParams['xtick.labelsize'] = 22
plt.rcParams['ytick.labelsize'] = 22
plt.rcParams['legend.fontsize'] = 24
plt.rcParams['figure.figsize'] = (12, 8)

# 读取数据表
df = pd.read_csv('RocksDB_data.csv')
df['调度器模式'] = df['调度器模式'].astype(str).str.lower().str.strip()

select_modes = ['none', 'bfq', 'bfq_limit_same']
df = df[(df['块大小'].astype(str).str.upper() == '1M') & (df['调度器模式'].isin(select_modes))]

bg_counts = [2, 4, 8, 16]
modes = ['none', 'bfq', 'bfq_limit_same']
mode_labels = {'none': 'NONE', 'bfq': 'BFQ', 'bfq_limit_same': 'DUET'}

# 每个模式每个 bg_count 选出 3 次实验，计算均值和标准差
data_table = []
for mode in modes:
    for bg in bg_counts:
        sub = df[(df['调度器模式'] == mode) & (df['Background数量'] == bg)]
        if len(sub) == 3:
            throughput_vals = sub['fio吞吐量(MB/s)'].astype(float).values / 1024.0  # MB/s -> GB/s
            latency_vals = sub['RocksDB真实Get平均延迟(μs)'].astype(float).values
            data_table.append({
                '调度器模式': mode_labels[mode],
                '背景流数量': bg,
                '吞吐量均值': np.mean(throughput_vals),
                '吞吐量标准差': np.std(throughput_vals, ddof=0),
                '延迟均值': np.mean(latency_vals),
                '延迟标准差': np.std(latency_vals, ddof=0),
            })

os.makedirs('figures-main', exist_ok=True)
data_df = pd.DataFrame(data_table, columns=[
    '调度器模式', '背景流数量', '吞吐量均值', '吞吐量标准差', '延迟均值', '延迟标准差'
])
data_df.to_excel('figures-main/rocksdb_figures_data.xlsx', index=False)

if data_df.empty:
    print("数据表为空，请检查 RocksDB_data.csv 或筛选条件。")
    exit(1)

colors = ['tab:blue', 'tab:orange', 'tab:green']
hatches = ['/', '\\', '']
markers = ['o', 's', '^']

# 绘制 fio 吞吐量柱状图
plt.figure()
bar_width = 0.22
x = np.arange(len(bg_counts))
for i, mode in enumerate(mode_labels.values()):
    means = []
    stds = []
    for bg in bg_counts:
        row = data_df[(data_df['调度器模式'] == mode) & (data_df['背景流数量'] == bg)]
        means.append(row['吞吐量均值'].values[0] if not row.empty else 0)
        stds.append(row['吞吐量标准差'].values[0] if not row.empty else 0)
    plt.bar(
        x + i * bar_width, means, bar_width, yerr=stds, label=mode,
        capsize=4, color=colors[i], edgecolor='black', hatch=hatches[i],
    )
plt.grid(True, axis='y', linestyle='--', linewidth=1, alpha=0.5)
plt.xticks(x + bar_width, bg_counts)
plt.xlabel('Number of Sustained Workloads')
plt.ylabel('Sustained Throughput (GB/s)')
plt.legend(loc='upper center', bbox_to_anchor=(0.5, 1.12), ncol=3, frameon=False)
plt.tight_layout(rect=[0, 0, 1, 0.95])
plt.savefig('figures-main/rocksdb_fio_throughput.pdf')
plt.close()

# 绘制 RocksDB 真实 Get 平均延迟折线图
plt.figure()
x_latency = np.arange(len(bg_counts))
for i, mode in enumerate(mode_labels.values()):
    means = []
    stds = []
    for bg in bg_counts:
        row = data_df[(data_df['调度器模式'] == mode) & (data_df['背景流数量'] == bg)]
        means.append(row['延迟均值'].values[0] if not row.empty else 0)
        stds.append(row['延迟标准差'].values[0] if not row.empty else 0)
    plt.errorbar(
        x_latency, means, yerr=stds, marker=markers[i], label=mode,
        capsize=4, color=colors[i], linestyle='-', markersize=8,
    )
plt.grid(True, linestyle='--', linewidth=1, alpha=0.5)
plt.xticks(x_latency, bg_counts)
plt.xlabel('Number of Sustained Workloads')
plt.ylabel('Mean Burst Latency (μs)')
plt.legend(loc='upper center', bbox_to_anchor=(0.5, 1.12), ncol=3, frameon=False)
plt.tight_layout(rect=[0, 0, 1, 0.95])
plt.savefig('figures-main/rocksdb_get_latency.pdf')
plt.close()

print("已生成 figures-main/rocksdb_fio_throughput.pdf 与 figures-main/rocksdb_get_latency.pdf")
