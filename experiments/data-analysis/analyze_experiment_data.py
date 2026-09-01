'''
Author: Jiali Liu 1552860603@qq.com
Date: 2025-08-09 15:24:31
LastEditors: Jiali Liu 1552860603@qq.com
LastEditTime: 2026-05-16 20:32:44
FilePath: /DUET/实验数据处理/阈值实验数据处理/analyze_experiment_data.py
Description: 

Copyright (c) 2026 by ${git_name_email}, All Rights Reserved. 
'''
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
实验数据分析脚本 - duet_same调度器burst latency分析
"""

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
import seaborn as sns
from pathlib import Path

# 设置图表风格
plt.style.use('seaborn-v0_8-whitegrid')
sns.set_palette("husl")

def load_experiment_data(file_path):
    """
    加载实验数据
    """
    try:
        # 读取Excel文件的所有sheet
        excel_file = pd.ExcelFile(file_path)
        print(f"发现的工作表: {excel_file.sheet_names}")
        
        # 读取数据
        data_dict = {}
        for sheet_name in excel_file.sheet_names:
            data_dict[sheet_name] = pd.read_excel(file_path, sheet_name=sheet_name)
            print(f"\n工作表 '{sheet_name}' 的结构:")
            print(f"形状: {data_dict[sheet_name].shape}")
            print(f"列名: {list(data_dict[sheet_name].columns)}")
            print(f"前几行数据:")
            print(data_dict[sheet_name].head())
        
        return data_dict
    except Exception as e:
        print(f"读取文件时出错: {e}")
        return None

def analyze_duet_same_data(data_dict):
    """
    分析duet_same调度器的数据
    """
    # 首先查看数据结构，然后根据实际情况调整
    for sheet_name, df in data_dict.items():
        print(f"\n=== 分析工作表: {sheet_name} ===")
        print(f"数据形状: {df.shape}")
        print("列名:")
        for i, col in enumerate(df.columns):
            print(f"  {i}: {col}")
        
        # 显示一些示例数据
        print("\n示例数据:")
        print(df.head(10))
        
        # 查找可能的duet_same相关数据
        duet_same_cols = [col for col in df.columns if 'duet_same' in str(col).lower()]
        if duet_same_cols:
            print(f"\n找到duet_same相关列: {duet_same_cols}")

def main():
    """
    主函数
    """
    # 数据文件路径
    data_file = Path("高低阈值综合实验.xlsx")
    
    if not data_file.exists():
        print(f"错误: 找不到数据文件 {data_file}")
        return
    
    print("正在加载实验数据...")
    data_dict = load_experiment_data(data_file)
    
    if data_dict is None:
        print("加载数据失败")
        return
    
    print("\n正在分析duet_same数据...")
    analyze_duet_same_data(data_dict)

if __name__ == "__main__":
    main()
