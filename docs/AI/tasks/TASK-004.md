# TASK-004: TSV 存储与生命周期归档 (lib/storage.sh)

## Objective
实现 Ops-Monitor 的本地指标存储、滚动写入、文件锁并发保护、以及旧指标数据的生命周期管理（保留天数清理与 `tar.gz` 压缩归档）。

## Scope
- 实现按日期滚动的 TSV 存储管理器（写入目标：`$DATA_DIR/current/metrics_YYYYMMDD.tsv`）
- 自动写入 TSV 表头（若文件新建）
- 实现原子追加与 `flock` 文件互斥保护
- 实现历史数据生命周期检查：
  - 检查 `$RETENTION_DAYS`
  - 若配置了 `ARCHIVE_DIR`，将超过 24h 的 `.tsv` 打包压缩为 `metrics_YYYYMMDD.tar.gz` 并移动至归档目录
  - 若未配置 `ARCHIVE_DIR`，自动清理过期 `.tsv` 释放磁盘空间
- 提供一键手动触发归档命令接口（`ops_storage_archive`）

## Allowed Files
- `lib/storage.sh`
- `tests/test_storage.sh`

## Dependencies
- TASK-001: 项目骨架与公共基础库
- TASK-003: 指标采集引擎

## Inputs and Outputs
- **Inputs**: 采集器生成的单行指标数据、归档与保留配置参数
- **Outputs**: `$DATA_DIR/current/metrics_YYYYMMDD.tsv` 结构化文件、`$ARCHIVE_DIR/metrics_YYYYMMDD.tar.gz` 归档包

## Acceptance Criteria
1. 在并发多个写进程同时调用时，TSV 文件不会出现数据穿插或损坏（通过 `flock` 保证）。
2. 新建 TSV 文件时包含标准表头：`#timestamp\tcpu_usage_pct\tmem_usage_pct\tdisk_usage_pct\tnet_rx_kbps\tnet_tx_kbps`。
3. 模拟跨天时，能够正确识别 $mtime > 24h$ 的旧指标文件，并成功打包为 gzip 压缩包或删除。
4. 归档目录不存在时能够安全自动创建（`mkdir -p`）。

## Verification Commands
```bash
bash -n lib/storage.sh
bash tests/test_storage.sh
```

## Risks and Assumptions
- 假定运行环境具备 `tar` 和 `gzip` 工具。

## Status
DONE
