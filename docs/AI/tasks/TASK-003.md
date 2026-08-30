# TASK-003: 指标采集引擎 (lib/collector.sh)

## Objective
实现轻量级指标采集引擎 `lib/collector.sh`，直接通过 procfs 虚拟文件系统（`/proc/stat`, `/proc/meminfo`, `/proc/net/dev`）和 `df` 指令计算 CPU、内存、磁盘和网络吞吐量，保证单次采集耗时 $< 50\text{ms}$，资源开销极小。

## Scope
- 实现 CPU 使用率计算（两次采样 $\Delta t = 1\text{s}$ 或读取缓存时间片差分）
- 实现内存使用率计算（通过 `/proc/meminfo` 提取 `MemTotal` 与 `MemAvailable`）
- 实现磁盘根目录使用率提取（通过 `df -P /`）
- 实现网络接口吞吐量计算（过滤 `lo` 接口，聚合计算所有物理/虚拟网卡的 RX/TX KB/s）
- 支持单次输出 TSV 格式行与 JSON/Key-Value 格式
- 提供守护进程采集循环模式（`--daemon` / `--cron` / `--once`）

## Allowed Files
- `lib/collector.sh`
- `tests/test_collector.sh`

## Dependencies
- TASK-001: 项目骨架与公共基础库
- TASK-002: 配置管理引擎

## Inputs and Outputs
- **Inputs**: `/proc/stat`, `/proc/meminfo`, `/proc/net/dev`, `df` 输出
- **Outputs**: 标准化指标数据行：
  `timestamp\tcpu_pct\tmem_pct\tdisk_pct\tnet_rx_kbps\tnet_tx_kbps`

## Acceptance Criteria
1. 在真实 Linux procfs 下单次执行无任何错误，且能够在终端打印正确的指标行。
2. 支持 Mock procfs 路径，以便在测试环境中模拟 100% CPU、90% 内存等极端场景。
3. 单次指标计算在基准机器上执行时间 $< 50\text{ms}$（除 CPU 采样等待时间外）。
4. 正确处理多网卡、虚拟网卡以及网络计数器可能出现的重置或回绕情况。

## Verification Commands
```bash
bash -n lib/collector.sh
bash tests/test_collector.sh
bash lib/collector.sh --once
```

## Risks and Assumptions
- 容器或精简 Linux 环境中需确保 `/proc` 已挂载。

## Status
DONE
