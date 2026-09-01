'''
Author: 刘佳丽 1552860603@qq.com
Date: 2025-08-11
Description: 背景流块大小为1MB时，横坐标为bg_count（背景流数量）的throughput和latency绘制脚本
数据来源于realtime_data.csv
绘制两个子图，分别绘制throughput和latency
子图1：绘制throughput，横坐标为bg_count，纵坐标为throughput，颜色为调度器模式，点型为背景流数量，误差条为标准差
子图2：绘制latency，横坐标为bg_count，纵坐标为latency，颜色为调度器模式，点型为背景流数量，误差条为标准差
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
df = pd.read_csv('realtime_data.csv')
# 取出名为'调度器模式'的列，并将其转换为小写并去除空格
df['调度器模式'] = df['调度器模式'].astype(str).str.lower().str.strip()

# 调度器模式列表初始化为要保留的调度器模式
select_modes = ['none', 'bfq', 'duet_same']
# 过滤出块大小为1M，调度器模式为 select_modes中的模式的数据
df = df[(df['块大小'].astype(str).str.upper() == '1M') & (df['调度器模式'].isin(select_modes))]

# 背景流数量列表初始化为要保留的背景流数量
bg_counts = [2, 4, 8, 16]
# 调度器模式标签列表初始化为要保留的调度器模式标签
modes = ['none', 'bfq', 'duet_same']
# 调度器模式标签字典初始化为要保留的调度器模式标签
mode_labels = {'none': 'NONE', 'bfq': 'BFQ', 'duet_same': 'DUET'}

# 生成用于绘图的数据表格，每个模式每个bg_count选出3次实验的吞吐量和延迟，并计算均值和标准差
# duet_same只选具体配置为4MB的，其他模式只选具体配置为1MB的
data_table = []
for mode in modes:
    for bg in bg_counts:
        if mode == 'duet_same':
            sub = df[(df['调度器模式'] == mode) & (df['Background数量'] == bg) & (df['具体配置'] == 'duet_same(4194304)')]
        else:
            sub = df[(df['调度器模式'] == mode) & (df['Background数量'] == bg)]
        if len(sub) == 3:
            # 取出3次实验的吞吐量和延迟，并计算均值和标准差
            throughput_vals = sub['Sustained吞吐量'].apply(lambda x: float(str(x).replace('GB/s', ''))).values
            latency_vals = sub['Burst延迟(μs)'].astype(float).values
            data_table.append({
                '调度器模式': mode_labels[mode],
                '背景流数量': bg,
                '吞吐量均值': np.mean(throughput_vals),
                '吞吐量标准差': np.std(throughput_vals, ddof=0),
                '延迟均值': np.mean(latency_vals),
                '延迟标准差': np.std(latency_vals, ddof=0)
            })

# 创建figures-main文件夹，如果不存在则创建
os.makedirs('figures-main', exist_ok=True)
# 将data_table转换为DataFrame，并保存为Excel文件
data_df = pd.DataFrame(data_table, columns=[
    '调度器模式', '背景流数量', '吞吐量均值', '吞吐量标准差', '延迟均值', '延迟标准差'
])
data_df.to_excel('figures-main/sustained_bgcount_figures_data.xlsx', index=False)

# 检查数据是否为空
if data_df.empty:
    print("数据表为空，请检查数据源或筛选条件。")
    exit(1)

# 绘制吞吐量柱状图（彩色+不同填充，图例在上方）
plt.figure()
# 柱状图宽度初始化为0.22
bar_width = 0.22
# 等间距横坐标
x = np.arange(len(bg_counts))
# 颜色列表初始化为要保留的颜色
colors = ['tab:blue', 'tab:orange', 'tab:green']
# 填充图案列表初始化为要保留的填充图案
hatches = ['/', '\\', '']
# 遍历每个调度器模式
for i, mode in enumerate(mode_labels.values()):
    # 吞吐量均值列表初始化为要保留的吞吐量均值
    means = []
    # 吞吐量标准差列表初始化为要保留的吞吐量标准差
    stds = []
    for bg in bg_counts:
        row = data_df[(data_df['调度器模式'] == mode) & (data_df['背景流数量'] == bg)]
        means.append(row['吞吐量均值'].values[0] if not row.empty else 0)
        stds.append(row['吞吐量标准差'].values[0] if not row.empty else 0)
    # 绘制柱状图
    plt.bar(x + i*bar_width, means, bar_width, yerr=stds, label=mode, capsize=4, color=colors[i], edgecolor='black', hatch=hatches[i])
# 绘制网格线
plt.grid(True, axis='y', linestyle='--', linewidth=1, alpha=0.5)
# 设置横坐标刻度
plt.xticks(x + bar_width, bg_counts)
# 设置横坐标标签
plt.xlabel('Number of Sustained Workloads')
# 设置纵坐标标签
plt.ylabel('Sustained Throughput (GB/s)')
# 设置图例
plt.legend(loc='upper center', bbox_to_anchor=(0.5, 1.12), ncol=3, frameon=False)
# 设置布局
plt.tight_layout(rect=[0,0,1,0.95])
# 保存为figures-main文件
plt.savefig('figures-main/sustained_bgcount_throughput.pdf')
plt.close()


# 绘制延迟折线图（彩色+不同点型，图例在上方）
# 创建图表
plt.figure()
# 点型列表初始化为要保留的点型
markers = ['o', 's', '^']
# 颜色列表初始化为要保留的颜色
colors = ['tab:blue', 'tab:orange', 'tab:green']
# 延迟横坐标列表初始化为要保留的延迟横坐标
latency_x = [2, 4, 8, 16]
x_latency = np.arange(len(latency_x))  # 等间距横坐标
for i, mode in enumerate(mode_labels.values()):
    # 延迟均值列表初始化为要保留的延迟均值
    means = []
    # 延迟标准差列表初始化为要保留的延迟标准差
    stds = []
    for bg in latency_x:
        # 取出每个调度器模式每个背景流数量对应的延迟均值和延迟标准差
        row = data_df[(data_df['调度器模式'] == mode) & (data_df['背景流数量'] == bg)]
        # 将延迟均值添加到延迟均值列表中
        means.append(row['延迟均值'].values[0] if not row.empty else 0)
        # 将延迟标准差添加到延迟标准差列表中
        stds.append(row['延迟标准差'].values[0] if not row.empty else 0)
    # 绘制误差条
    plt.errorbar(x_latency, means, yerr=stds, marker=markers[i], label=mode, capsize=4, color=colors[i], linestyle='-', markersize=8)
# 绘制网格线
plt.grid(True, linestyle='--', linewidth=1, alpha=0.5)
# 设置横坐标刻度
plt.xticks(x_latency, latency_x)
# 设置横坐标标签
plt.xlabel('Number of Sustained Workloads')
# 设置纵坐标标签
plt.ylabel('Burst Latency (μs)')
# 设置图例
plt.legend(loc='upper center', bbox_to_anchor=(0.5, 1.12), ncol=3, frameon=False)
# 设置布局
plt.tight_layout(rect=[0,0,1,0.95])
# 保存为figures-main文件
plt.savefig('figures-main/sustained_bgcount_latency.pdf')
plt.close()
