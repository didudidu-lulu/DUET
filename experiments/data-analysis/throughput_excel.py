'''
Author: Jiali Liu 1552860603@qq.com
Date: 2025-08-10 20:00:52
LastEditors: Jiali Liu 1552860603@qq.com
LastEditTime: 2026-05-17 18:06:15
FilePath: /DUET/实验数据处理/阈值实验数据处理/throughput_excel.py
Description: 将高低阈值综合实验.xlsx中的数据转换为Excel文件，文件名为duet_same_throughput_table.xlsx
'''
import pandas as pd

# 读取文件名为duet_same_throughput_table.xlsx
df = pd.read_csv('duet_same_throughput_table.xlsx', header=None,
                 names=['col1','col2','块大小','调度器模式','具体配置','col6','Sustained吞吐量','col8','col9','col10'])
# 阈值列表
thresholds = ['1MB', '2MB', '4MB', '8MB', '16MB', '32MB']
# 块大小列表
blocksizes = ['4K', '16K', '64K', '256K', '1M', '4M']
# 创建DataFrame，索引为块大小，列名为阈值
result = pd.DataFrame(index=blocksizes, columns=thresholds)
# 遍历阈值列表
for t in thresholds:
    # 将阈值转换为字节
    threshold_bytes = int(t.replace("MB", "")) * 1024 * 1024
    for b in blocksizes:
        if t == '32MB':
            # 32MB取bfq模式
            sub = df[(df['调度器模式'] == 'bfq') &
                     (df['块大小'].astype(str).str.upper() == b.upper())]
        else:
            sub = df[(df['调度器模式'] == 'duet_same') &
                     (df['块大小'].astype(str).str.upper() == b.upper()) &
                     (df['具体配置'] == f'duet_same({threshold_bytes})')]
        if len(sub) > 0:
            # 计算Sustained吞吐量的平均值 并保留3位小数
            mean_val = sub['Sustained吞吐量'].apply(lambda x: float(str(x).replace('GB/s', ''))).mean()
            # 将平均值添加到DataFrame中
            result.loc[b, t] = round(mean_val, 3)
        else:
            # 如果数据不存在，则添加空值
            result.loc[b, t] = ''

# 将DataFrame保存为Excel文件
result.to_excel('duet_same_throughput_table.xlsx')
print(result)