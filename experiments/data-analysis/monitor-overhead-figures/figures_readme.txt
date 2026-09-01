Monitor overhead figures — statistics notes
============================================

CI = Confidence Interval (置信区间)
  A range that, under repeated experiments, would contain the true mean
  about 95% of the time (here: 95% CI).

Axis labels (as in the figures-main):
  X: Number of benchmark processes
  fig1 Y: Monitor list time per round (ms)
  fig2 Y: Context-switch time change (%)

fig1 — hotpath (results_ioprio_hotpath_sweep_20260528_211159)
  Metric: mean per-rep latency of ioprio_ov_cpu_work_fn (function_graph), in ms.
  Error bars: 95% CI of the mean across repetitions (mean ± 1.96·σ/√n).
  n ≈ 3.

fig2 — manyproc (results_cs_manyproc_sweep_20260529_090313)
  Metric: (avg_cs_ns_on − avg_cs_ns_off) / avg_cs_ns_off × 100%,
  where avg_cs_ns = task_clock / context_switches from perf stat.
  Error bars: 95% bootstrap CI of the mean paired-run Δ%.
  n ≈ 20.

Data dirs:
  hotpath: /Users/kiko/Downloads/DUET/实验数据处理/阈值实验数据处理/results_ioprio_hotpath_sweep_20260528_211159
  manyproc: /Users/kiko/Downloads/DUET/实验数据处理/阈值实验数据处理/results_cs_manyproc_sweep_20260529_090313
