实验 A 时间序列图
================

数据目录: /Users/kiko/Downloads/DUET/实验数据处理/阈值实验数据处理/results_exp_a_20260602_170518
重复次数 (G2/G3 reps): 3
fio ramp_time = 3.0s, runtime = 30.0s, 显示窗口 [0.0, 35.0]s
时间栅格步长 = 0.2s, y 轴上限 = 16154.15 MB/s

文件:
  fig_timeline_overlay.{pdf,png}          - 1x3 linear (G1/G2/G3)，子图 (a)(b)(c)，fio+malicious 同图
  fig_timeline_overlay_symlog.{pdf,png}   - 同上 symlog y 轴：sub-10 MB/s 线性、其上对数，
                                              便于看清被压制后的残余带宽（在线性图上几乎不可见）
  fig_timeline_combined.{pdf,png}         - 2x2 linear，行=组 列=workload
  fig_timeline_combined_symlog.{pdf,png}  - 同上 symlog
  timeline_aggregated.tsv                   - 每 phase 每时刻的 mean
  events_aggregated.tsv                     - 每 rep 的 revoke / ionice 相对秒

为何要同时给 linear 与 symlog 两套：
  实验动态范围很大。线性轴下看不出被压制 workload 究竟剩多少；symlog 让 sub-10 MB/s
  区段保持线性、上方对数压缩，
  既能保留"差别有多大"的视觉冲击，又能让 reviewer 读到被压制的真实数值。

时间对齐：
  - phase_t0.tsv 记录 phase 开始的 CLOCK_BOOTTIME 与 wall time
  - fio 用 log_unix_epoch=1，按 wall time 折算
  - malicious_bw.tsv 与 dmesg revoke 时戳同源 (CLOCK_BOOTTIME / printk_time)
  - 所有 t_rel_s 均以 phase_t0 为 0 点

读图：
  - G2 (monitor OFF): malicious (红) 占走带宽, fio (蓝) 长期低位
  - G3 (monitor ON): 在 revoke 竖线后, fio 蓝线回升；ionice 竖线后 malicious 红线进一步下降
  - G2/G3 不再叠加 G1 baseline 参考线；曲线为各 rep 的 mean
