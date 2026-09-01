'''
Author: 刘佳丽 1552860603@qq.com
Date: 2025-08-11
Description: Burst IO Size变化时不同调度器的latency和throughput图绘制脚本
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
# Burst块大小,Background数量,块大小,调度器模式,具体配置,运行次数,Sustained吞吐量,Burst延迟(μs),突发轮次,完成时间
df = pd.read_csv('burstiosize.csv')
df['调度器模式'] = df['调度器模式'].astype(str).str.lower().str.strip()

# 只保留Background数量=8，块大小=1M，调度器模式为none、bfq、duet_same（4MB）
select_modes = ['none', 'bfq', 'duet_same']
df = df[(df['Background数量'] == 8) & (df['块大小'].astype(str).str.upper() == '1M') & (df['调度器模式'].isin(select_modes))]

burst_sizes = ['4K', '16K', '64K', '256K', '1M', '4M']
modes = ['none', 'bfq', 'duet_same']
mode_labels = {'none': 'NONE', 'bfq': 'BFQ', 'duet_same': 'DUET'}

data_table = []
for mode in modes:
    for burst in burst_sizes:
        if mode == 'duet_same':
            sub = df[(df['调度器模式'] == mode) & (df['Burst块大小'].astype(str).str.upper() == burst.upper()) & (df['具体配置'] == 'duet_same(4194304)')]
        else:
            sub = df[(df['调度器模式'] == mode) & (df['Burst块大小'].astype(str).str.upper() == burst.upper())]
        if len(sub) == 3:
            throughput_vals = sub['Sustained吞吐量'].apply(lambda x: float(str(x).replace('GB/s', ''))).values
            latency_vals = sub['Burst延迟(μs)'].astype(float).values
            data_table.append({
                '调度器模式': mode_labels[mode],
                'Burst块大小': burst,
                '吞吐量均值': np.mean(throughput_vals),
                '吞吐量标准差': np.std(throughput_vals, ddof=0),
                '延迟均值': np.mean(latency_vals),
                '延迟标准差': np.std(latency_vals, ddof=0)
            })

# 保存数据表格
os.makedirs('figures-main', exist_ok=True)
data_df = pd.DataFrame(data_table, columns=[
    '调度器模式', 'Burst块大小', '吞吐量均值', '吞吐量标准差', '延迟均值', '延迟标准差'
])
data_df.to_excel('figures-main/burst_block_size_figures_data.xlsx', index=False)

# 检查数据是否为空
if data_df.empty:
    print("数据表为空，请检查数据源或筛选条件。")
    exit(1)

# 绘制吞吐量柱状图（彩色+不同填充，图例在上方）
plt.figure()
bar_width = 0.22
x = np.arange(len(burst_sizes))
colors = ['tab:blue', 'tab:orange', 'tab:green']
hatches = ['/', '\\', '']
for i, mode in enumerate(mode_labels.values()):
    means = []
    stds = []
    for j, burst in enumerate(burst_sizes):
        row = data_df[(data_df['调度器模式'] == mode) & (data_df['Burst块大小'] == burst)]
        val = row['吞吐量均值'].values[0] if not row.empty else 0
        means.append(val)
        stds.append(row['吞吐量标准差'].values[0] if not row.empty else 0)
    bars = plt.bar(x + i*bar_width, means, bar_width, yerr=stds, label=mode, capsize=4, color=colors[i], edgecolor='black', hatch=hatches[i])
    # # 添加数值标签
    # for bar in bars:
    #     height = bar.get_height()
    #     plt.text(bar.get_x() + bar.get_width()/2, height + 0.05, f'{height:.1f}', ha='center', va='bottom', fontsize=18)
plt.grid(True, axis='y', linestyle='--', linewidth=1, alpha=0.5)
plt.xticks(x + bar_width, burst_sizes)
plt.xlabel('Burst Workload IO Size (Byte)')
plt.ylabel('Sustained Throughput (GB/s)')
plt.legend(loc='upper center', bbox_to_anchor=(0.5, 1.12), ncol=3, frameon=False)
plt.tight_layout(rect=[0,0,1,0.95])
plt.savefig('figures-main/burst_block_size_figures_throughput.pdf')
plt.close()

# 绘制延迟折线图（彩色+不同点型，图例在上方）
plt.figure()
markers = ['o', 's', 'D']
colors = ['tab:blue', 'tab:orange', 'tab:green']
x_latency = np.arange(len(burst_sizes))
for i, mode in enumerate(mode_labels.values()):
    means = []
    stds = []
    for j, burst in enumerate(burst_sizes):
        row = data_df[(data_df['调度器模式'] == mode) & (data_df['Burst块大小'] == burst)]
        val = row['延迟均值'].values[0] if not row.empty else 0
        means.append(val)
        stds.append(row['延迟标准差'].values[0] if not row.empty else 0)
    plt.errorbar(x_latency, means, yerr=stds, marker=markers[i], label=mode, capsize=4, color=colors[i], linestyle='-', markersize=8)
    # # 添加数值标签
    # for j, y in enumerate(means):
    #     plt.text(x_latency[j], y + 30, f'{y:.1f}', ha='center', va='bottom', fontsize=18)
plt.grid(True, linestyle='--', linewidth=1, alpha=0.5)
plt.xticks(x_latency, burst_sizes)
plt.xlabel('Burst Workload IO Size (Byte)')
plt.ylabel('Burst Workload Mean Latency (μs)')
plt.legend(loc='upper center', bbox_to_anchor=(0.5, 1.12), ncol=3, frameon=False)
plt.tight_layout(rect=[0,0,1,0.95])
plt.savefig('figures-main/burst_block_size_figures_latency.pdf')
plt.close()
