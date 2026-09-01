多规模 CS 开销扫描

PROC_SWEEP=10000,20000,40000,60000,80000,100000
RUNS=20 LOOPS=20  SWEEP_INTERLEAVE=1

交错模式: 每周期 2000→10000→50000→100000 各 1 次 off/on，共 RUNS 周期
execution_order.log 记录实际顺序

每档: by_target/target_<N>/{summary.tsv,delta.txt,...}
汇总: sweep_summary.tsv, plot_sweep.csv

运行: sudo ./exp_cs_monitor_overhead_manyproc.sh
（脚本内 RUN_MODE=sweep）
