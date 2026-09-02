# TASK-013: Docker 容器资源实时监控与展示 (ops docker)

## 1. 任务背景与目标
用户需要在 Ops-Monitor 中简单易用、实时查看当前所有 Docker 容器的资源占用情况（CPU、内存、网络 I/O、磁盘 I/O、线程数、状态等）。
该功能定位为**实时展示**（不引入 TSV 历史数据持久化），如果系统未安装 Docker，则友好提示未安装 Docker；如果 Docker 守护进程未启动或权限不足，输出清晰诊断提示。同时支持快照卡片与动态实时刷新（Live TUI）模式，并支持多服务器集群远程代理。

## 2. 交付与功能清单
1. **核心模块 `lib/docker.sh`**：
   - Docker 环境嗅探与权限自适应探测（`docker` / `sudo -n docker` / 未安装 / 守护进程未运行）。
   - 容器实时资源指标解析（CPU %、内存使用率与限额、网络 I/O、磁盘 I/O、PIDs、状态、镜像）。
   - 格式化终端卡片与表格渲染（包含 Docker 总资源汇总、单容器彩色进度条）。
   - 动态实时看盘模式 `ops docker --live`（平滑原位刷新，按 `q` 退出）。
2. **主入口与路由集成 (`ops.sh`)**：
   - 注册 `ops docker` / `ops ps` / `ops containers` 顶层路由与帮助文档。
3. **多节点代理集成 (`lib/node_mgr.sh`)**：
   - 实现 `ops_node_docker`，支持在切换工作上下文（`ops use <node>`）时无缝查询远程服务器的 Docker 容器资源。
4. **自动化测试套件 (`tests/test_docker.sh`)**：
   - 覆盖语法检查、未安装 Docker 场景 Mock、权限异常 Mock、正常容器数据解析与渲染测试。
   - 接入 `tests/run_tests.sh` 统一测试集。
5. **系统架构文档更新 (`docs/AI/ARCHITECTURE.md`)**：
   - 补充 Docker 实时监控子系统章节与 CLI 规范。

## 3. 验收标准
- [x] 未安装 Docker 环境下执行 `ops docker` 输出友好提示："未检测到 Docker 环境 (未安装 Docker)"。
- [x] 安装 Docker 环境下执行 `ops docker` 输出美观清晰的容器资源占用表格与统计卡片。
- [x] 支持 `ops docker -w` / `ops docker --live` 实时看盘刷新。
- [x] 全量测试套件 100% PASS。
- [x] 架构文档与任务索引同步更新。
