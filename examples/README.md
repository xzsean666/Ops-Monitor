# Ops-Monitor 常用操作与使用场景示例

本文档用通俗易懂的命令和场景，介绍在日常服务器运维中如何使用 Ops-Monitor。

---

## 🚀 快速安装（本地源码热开发模式）

如果你想在当前仓库下开发、测试，并让每次代码修改**立即生效**：

```bash
# 方式 A：免 root 用户级安装（推荐，软链至 ~/.local/bin/ops）
./link.sh

# 方式 B：系统级全局安装（需 sudo，软链至 /usr/local/bin/ops）
sudo ./link.sh

# 如需移除软链接：
./link.sh --unlink
```
> **优势**：软链接创建后，直接在任何终端敲 `ops`、`ops switch`、`ops status` 即可。修改仓库任何文件，终端下一秒直接生效！

---

## 场景 1：日常查看服务器状态

### 1.1 打开全屏实时动态仪表盘
平时 SSH 登录服务器后，想实时看看机器卡不卡、网络跑了多少：
```bash
ops
```
*(或者 `ops dashboard`)*
- **效果**：打开一个类似 `htop` 的全屏动态看板，实时刷新 CPU、内存、磁盘、上下行网速和火花线趋势。
- **操作**：按 `q` 退出，按 `r` 强制刷新，按 `h` 查看帮助。

---

### 1.2 快速打卡 / 单次体检（适合放到登录欢迎信息 MOTD）
只想快速看一眼当前机器健康状态，不需要常驻全屏：
```bash
ops status
```
- **效果**：输出一张带颜色的紧凑卡片，显示当前 CPU、内存、磁盘使用率、网速以及整体状态徽标（`NORMAL` / `WARNING` / `CRITICAL`）。

---

### 1.3 查看过去 24 小时的历史负载大图
排查昨晚半夜机器有没有被突发流量打满，或者内存有没有泄漏：
```bash
# 查看过去 24 小时 CPU 负载趋势图
ops history cpu

# 查看过去 24 小时 内存 使用趋势图
ops history mem

# 查看过去 24 小时 根分区磁盘 使用趋势图
ops history disk

# 查看过去 24 小时 网络吞吐 趋势图
ops history net
```
- **效果**：直接在 SSH 字符终端绘制完整的 24 小时 ASCII 曲线坐标图，并画出红色告警阈值参考线。

---

## 场景 2：告警配置（钉钉 / 企业微信 / 飞书 / Slack）

### 2.1 交互式向导配置（小白最推荐）
直接运行配置向导，根据命令行提示输入：
```bash
ops config
```
终端会逐项提示输入：
- CPU / 内存 / 磁盘告警阈值（比如 80%）
- 告警防抖与冷却时间（默认 30 分钟）
- Webhook 地址与加签 Secret（钉钉、企业微信、飞书、Slack 任意填）

---

### 2.2 命令行单项快速修改
如果只想临时改一个参数：
```bash
# 把 CPU 报警阈值改成 80%
ops config set ALERT_CPU_THRESHOLD 80

# 把内存报警阈值改成 90%
ops config set ALERT_MEM_THRESHOLD 90

# 设置钉钉机器人 Webhook 地址
ops config set WEBHOOK_DINGTALK_URL "https://oapi.dingtalk.com/robot/send?access_token=xxxx"

# 设置钉钉加签密钥
ops config set WEBHOOK_DINGTALK_SECRET "SECxxxx"
```

---

### 2.3 查看当前所有配置项
```bash
ops config list
```
*(默认会自动将 Token 和 Secret 脱敏掩码，避免截图或录屏泄密)*

---

### 2.4 测试告警通知是否能正常收到
配置好 Webhook 后，验证机器人能不能发通：
```bash
ops config test-alert
```
- **效果**：向群里发送一条模拟的告警卡片，确认网络连通与机器人权限无误。

---

## 场景 3：多远程服务器 (SSH 节点) 管理与一键秒切

你可以把本地当作一个**统一运维控制台**，无需每次手敲长长的主机名，随时一键切换与管理所有服务器：

### 3.1 极速切换中心 (推荐：`ops switch` 或 `ops s`)
想要切换查看哪台机器，敲：
```bash
ops switch
# 或者直接敲单字母：
ops s
```
**界面演示：**
```text
================================================================================
                 Ops-Monitor 服务器集群一键切换中心                             
================================================================================
  当前默认活动服务器: local (本机)

  [0]  local (本机)        127.0.0.1 (本机)               ★ 当前活跃
  [1]  sean-hk             root@46.8.101.219             
  [2]  aws-prod            root@35.78.207.248            

  [+]  添加注册新服务器
  [i]  从 ~/.ssh/config 自动发现并批量导入
  [q]  退出
================================================================================
👉 请输入序号选择服务器 (0-2) 或功能键: 1

已选中服务器: sean-hk (root@46.8.101.219)
  [1] 打开实时性能动态看板 (Dashboard) [回车默认]
  [2] 查看单次健康体检卡片 (Status)
  [3] SSH 终端直连登录 (Connect)
  [4] 设为默认工作服务器 (Use/Switch Context)
  [5] 一键部署/升级套件 (Deploy)
```
> 💡 **在看实时看板时**：随时按下字母 **`s`** 键，也能立刻弹出换机菜单，秒切到另一台机器！

---

### 3.2 自动发现：一键导入 `~/.ssh/config` 中的所有服务器
如果你本地已经在 `~/.ssh/config` 里配置过了多台服务器别名，**一行命令全自动导入**，不用手动重新注册：
```bash
ops node import-ssh
```

---

### 3.3 免起名添加服务器（自动推导别名）
如果手动添加，甚至不需要想服务器名字，直接贴连接串即可：
```bash
# 不需要传别名参数，会自动生成如 node-46-8-101-219 或询问默认值
ops node add "ssh -i ~/ssh/sean -p 22 root@46.8.101.219"
```

---

### 3.4 全局工作上下文切换 (`ops use`)
类似 `kubectl config use-context`：
```bash
# 将当前默认服务器切为香港机器
ops use sean-hk

# 此时直接运行 ops 或 ops status，默认直接看香港这台机器！
ops
ops status

# 随时切回本机
ops use local
```

---

### 3.5 一键批量升级集群所有服务器 (`ops update --all`) 🚀
当你本地修改了监控代码或发布了新版本后，**不需要一台台去登录升级**：
```bash
# 一键批量热升级所有已注册的远程服务器
ops update --all
# 或者
ops update
```
- **效果**：本地会自动打包最新代码，通过 SSH 数据流依次为所有注册的远程服务器进行热更新并平滑重启服务，打印出清晰的升级进度与汇总报告（`✔ [PASS] 成功 5 台，失败 0 台`）。
- **保留数据**：无损升级，保留各机器原有的配置文件与历史日志。
- **单独升级某一台**：`ops update sean-hk`

---

### 3.6 常用直接命令
```bash
ops switch              # 交互式切换面板 (按 u 键也可一键批量升级)
ops update --all        # 一键批量热升级所有已注册服务器
ops node list           # 查看所有服务器列表
ops sean-hk             # 直接直达打开 sean-hk 的实时动态看板
ops ssh sean-hk         # 一键 SSH 登录切换到 sean-hk
ops node deploy sean-hk # 为该远程机器安装部署套件
ops node uninstall sean-hk # 远程卸载该机器上的套件
```

### 4.1 检查后台自动采集服务状态
```bash
ops daemon status
# 或者
systemctl status ops-daemon
```

### 4.2 手动触发一次历史数据压缩归档
```bash
ops archive --run
```
*(将超过保留期限的旧指标打包压缩为 `.tar.gz` 移入归档目录，释放磁盘空间)*
