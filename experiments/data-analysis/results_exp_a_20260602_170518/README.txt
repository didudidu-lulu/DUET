实验 A（三组 × REPS=3）— 统一优先级版；G1 为公平基线

负载（fio 与 malicious 对齐：1 MiB O_DIRECT read、libaio、iodepth=4）：
- fio: 8 个 background job，bs=1M，iodepth=4，prioclass=1 prio=7，ramp 3s，runtime 30s
- malicious_sustained（G1/G2/G3）：sudo ionice -c1 -n7 ./malicious_sustained ...
  bs=1 MiB，libaio pipeline iodepth=4（与 fio 相同）
  **所有 phase 中 malicious 与 fio 的 base ionice 都是 RT-7**——攻击者的不当优势
  只能来自 ioprio_override 的 burst 豁免，与 base 优先级无关。

三组矩阵（每 rep 顺序：G1 → G2 → G3；**三组限流参数相同**）：
+----+----------------------------+----------------+-----------+-------+--------+
| 组 | 设计角色                    | bdev_set_bytes  | override  | mon   | 防御后续 |
+----+----------------------------+----------------+-----------+-------+--------+
| G1 | **公平基线（baseline）**   | enable=1 4M/4M | **no**     | off   | —        |
| G2 | 攻击 + 无防御                | enable=1 4M/4M  | yes        | off   | —        |
| G3 | 攻击 + 内核 revoke 防御      | enable=1 4M/4M  | yes        | on    | **无**   |
+----+----------------------------+----------------+-----------+-------+--------+
G1 与 G2/G3 的唯一差别：**不调用 ioprio_override**（限流门限一致）。

预期数值（以 G1 为「同限流、无 override」参照）：
  G1：fio 与 malicious 在字节门限下由 BFQ 分配（实测比例以跑数为准）
  G2：相对 G1，fio 极低、malicious 极高（burst 豁免）
  G3：revoke 后 fio 恢复，应趋近 G1；30s 聚合含 ~3s 攻击段

对比意义：
  - G2 vs G1：isolate ioprio_override 攻击效果（限流相同）
  - G2 vs G3：内核 revoke 是否能把系统从攻击态拉回
  - G3 vs G1：revoke 后是否回到「同限流、无 override」基线

目录布局：
  results_exp_a_<TS>/
    summary.tsv                # 聚合表（rep × phase）
    rep_NN/
      G1_no_mechanism/ G2_*/ G3_*/
        phase_config.tsv       # 实际生效参数
        phase_t0.tsv           # 时间序列对齐基准（boot + wall）
        fio_bw_bw.log          # fio 瞬时带宽
        malicious_bw.tsv       # malicious 瞬时带宽（pthread 采样线程）
        revoke_events.tsv      # G3 才有：dmesg 抽取的 revoked burst 时戳
        sustained_bw_MiB_s.txt malicious_*.txt
        fio.json fio.stdout sustained.fio dmesg_tail.txt

环境变量：
- REPS（默认 1）：重复次数；REPS≥3 才能在时间序列图上画 IQR 带、聚合柱状图上画 CI。
- BW_LOG_INTERVAL_MS（默认 200）：fio + malicious 的瞬时带宽采样周期。
- QUEUE_WATCH_INTERVAL_SEC（默认 1）：每 N 秒在 stderr 打印 bdev_get_bytes 读到的 io_bytes；
  设 0 禁用。仅供人工观察，不进 summary.tsv 也不进任何图。
