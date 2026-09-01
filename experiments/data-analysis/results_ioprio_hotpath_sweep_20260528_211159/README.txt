ioprio CPU 监控热路径 — 多规模扫描

PROC_SWEEP=10000,20000,40000,60000,80000,100000
SWEEP_REPS=3
LOOPS=20  CPU_SET=none
FTRACE_GRAPH=1

目录:
  by_target/target_<N>/rep_<RR>/  — 每次重复的 monitor_off/on
  sweep_points.tsv               — 各次原始点（作图/复查）
  sweep_summary.tsv              — 按规模聚合（中位、95% CI）
  plot_sweep.csv                 — 可直接 import 到 matplotlib

复现:
  sudo -v && sudo ./exp_ioprio_monitor_hotpath.sh
  （参数见脚本顶部「实验配置」）

作图示例 (Python):
  import pandas as pd, matplotlib.pyplot as plt
  df = pd.read_csv("plot_sweep.csv")
  plt.errorbar(df.target_procs, df.work_ms_mean_median,
               yerr=[df.work_ms_mean_median-df.work_ms_mean_ci_low,
                     df.work_ms_mean_ci_high-df.work_ms_mean_median],
               fmt="o-")
  plt.xscale("log"); plt.xlabel("Target processes"); plt.ylabel("One work round (ms)")
  plt.savefig("work_cost_vs_procs.pdf")
