'''
Author: Jiali Liu 1552860603@qq.com
Date: 2025-08-10 20:00:52
LastEditors: Jiali Liu 1552860603@qq.com
LastEditTime: 2026-05-20 09:29:11
FilePath: /DUET/实验数据处理/阈值实验数据处理/datatiqu.py
Description: 将高低阈值综合实验数据处理为每个count一个sheet，三次实验、均值和标准差各为一列。

Copyright (c) 2026 by ${git_name_email}, All Rights Reserved.
'''
import numpy as np
import pandas as pd

DATA_FILE = '高低阈值综合实验4.0.csv'

def load_data(path):
    """支持 .csv 或 .xlsx（含 realtime_data 工作表）。"""
    if str(path).lower().endswith('.csv'):
        return pd.read_csv(path), '(csv)'
    xl = pd.ExcelFile(path)
    sheet = 'realtime_data' if 'realtime_data' in xl.sheet_names else xl.sheet_names[0]
    return pd.read_excel(path, sheet_name=sheet), sheet


df, sheet_name = load_data(DATA_FILE)
df['调度器模式'] = df['调度器模式'].astype(str).str.lower().str.strip()
df['块大小_标准'] = df['块大小'].apply(
    lambda x: {
        '4K': '4K', '4': '4K',
        '16K': '16K', '16': '16K',
        '64K': '64K', '64': '64K',
        '256K': '256K', '256': '256K',
        '1M': '1M', '1024K': '1M', '1024': '1M',
        '4M': '4M', '4096K': '4M', '4096': '4M',
    }.get(str(x).strip().upper(), str(x).strip().upper())
)
print(f'读取 {DATA_FILE}，工作表: {sheet_name}，共 {len(df)} 行')
print(f'块大小(原始): {sorted(df["块大小"].astype(str).unique())}')
print(f'块大小(标准): {sorted(df["块大小_标准"].unique())}')

thresholds = ['1MB', '2MB', '4MB', '8MB', '16MB', '32MB']
blocksizes = ['4K', '16K', '64K', '256K', '1M', '4M']
counts = [2, 4, 8, 16]
has_bfq = (df['调度器模式'] == 'bfq').any()


def parse_throughput_gb(x):
    if pd.isna(x):
        return None
    s = str(x).strip()
    if s in ('', '解析失败', 'nan'):
        return None
    return float(s.replace('GB/s', '').replace('gb/s', ''))


def select_subset(data, block, threshold_label, count):
    """按块大小、阈值、bg_count 筛选子集。"""
    mask = (data['块大小_标准'] == block) & (data['Background数量'] == count)
    threshold_bytes = int(threshold_label.replace('MB', '')) * 1024 * 1024

    if threshold_label == '32MB' and has_bfq:
        # 旧版数据：32MB 用 BFQ 作为无限制对照
        return data[mask & (data['调度器模式'] == 'bfq')]
    # 4.0 及一般情况：duet_same(阈值字节)
    config = f'duet_same({threshold_bytes})'
    return data[
        mask
        & (data['调度器模式'] == 'duet_same')
        & (data['具体配置'] == config)
    ]


def compute_aggregation(all_detail_rows):
    """
    对每个阈值，在全部 (块大小 × Background数量) 组合上计算算术平均与几何平均。
    默认每个阈值 24 个点：6 种块大小 × 4 种 bg_count。
    """
    agg_rows = []
    for t in thresholds:
        vals = [
            r['Mean'] for r in all_detail_rows
            if r['Threshold'] == t and r['Mean'] is not None
        ]
        if not vals:
            agg_rows.append({
                'Threshold': t, 'N': 0,
                'AMEAN': None, 'GEOMEAN': None,
                'Std_AcrossCells': None,
            })
            continue
        arr = np.array(vals, dtype=float)
        agg_rows.append({
            'Threshold': t,
            'N': len(arr),
            'AMEAN': round(float(np.mean(arr)), 6),
            'GEOMEAN': round(float(np.exp(np.mean(np.log(arr)))), 6),
            'Std_AcrossCells': round(float(np.std(arr, ddof=0)), 6),
        })
    return pd.DataFrame(agg_rows)


writer = pd.ExcelWriter('duet_same_throughput_detail.xlsx')
missing_total = 0
all_detail_rows = []

for count in counts:
    rows = []
    for b in blocksizes:
        for t in thresholds:
            sub = select_subset(df, b, t, count)
            vals = [parse_throughput_gb(x) for x in sub['Sustained吞吐量']]
            vals = (vals + [None] * 3)[:3]
            valid = [v for v in vals if v is not None]
            if valid:
                mean_val = round(float(np.mean(valid)), 3)
                std_val = round(float(np.std(valid, ddof=0)), 3)
            else:
                mean_val = None
                std_val = None
            if len(valid) < 3:
                missing_total += 1
            row = {
                'Background数量': count,
                'Blocksize': b,
                'Threshold': t,
                'Exp1': vals[0],
                'Exp2': vals[1],
                'Exp3': vals[2],
                'Mean': mean_val,
                'Std': std_val,
                'N': len(valid),
            }
            rows.append(row)
            all_detail_rows.append(row)
    result = pd.DataFrame(rows)
    result.to_excel(writer, sheet_name=f'count={count}', index=False)

agg_df = compute_aggregation(all_detail_rows)
agg_df.to_excel(writer, sheet_name='threshold_aggregation', index=False)

writer.close()
print('已生成 duet_same_throughput_detail.xlsx（含 Exp1–3、Mean、Std、N）')
print(f'缺数据单元格组数: {missing_total}')
print('\n=== 各阈值带宽聚合（24 个单元格 Mean 的算术/几何平均，GB/s）===')
print(agg_df.to_string(index=False))
if missing_total:
    print('若仍有缺失，请检查源表中 块大小 / 具体配置 / Background数量 是否与脚本一致。')
