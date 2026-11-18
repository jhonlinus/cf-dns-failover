# Changelog

所有重要变更记录在此文件。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.2] - 2026-11-18

脚本逻辑未变，本次发布加入图形界面与飞牛应用包。

### 新增

- **`dashboard/` 网页面板 `cfdash`**：零依赖单文件服务端（Python 3.8+ 标准库）+ 单文件前端。
  解析 `cf-failover` 的配置、状态文件与日志，还原每一轮探测与切换事件；实时调 Cloudflare API
  校验线上记录值，与日志观测值不一致会标红；节点泳道时间轴、事件列表、日志过滤、脱敏配置面板。
  兼容仓库版 `/etc/cf-failover/config` 与早期 1Panel 内联脚本两种安装形态。
  面板只读，支持 `--no-run` 关闭触发按钮、`--auth` 开 Basic 认证、`--sock` 走 Unix socket。
- **`fnos/` 飞牛 fnOS 应用包**：`dist/cfdns-1.0.0.fpk`（34 KB），走统一网关 `/app/cfdns/`，
  不占端口，桌面点开即用。

### 变更

- `VERSION` 与项目版本对齐为 1.0.2（探测、切换逻辑与 1.0.1 完全一致）

## [1.0.1] - 2026-11-17

解决节点用域名时可能读到过期地址的问题。旧版本只按系统解析器取 IP，一旦解析链路上任何一层缓存返回旧值，脚本会去探测一个已经失效的地址，进而误判节点故障、把旧 IP 写回 DNS。

### 新增

- `NODE_LOOKUP`：`system`（默认，走本机解析器）或 `authoritative`（直连片区权威 NS，`+norecurse`，绕开所有缓存）。权威解析失败时自动回落并告警
- `FLUSH_DNS_CACHE`：`auto`（默认）/ `always` / `never`，解析前清本机缓存（`resolvectl`、`systemd-resolve`、`nscd`、macOS `mDNSResponder`）。仅在节点列表含域名时触发
- `NODE_RESOLVER`：指定解析器地址，跳过 `getent`，从而绕开 NSS、`systemd-resolved` 和 `/etc/hosts`

### 修复

- **解析失败时把解析器 IP 当成节点 IP**：`dig` 无结果回落到 `nslookup` 时，输出里第一段就是解析器自身地址，被当作解析结果返回，随后被探测甚至写入 DNS。现在按行提取 IPv4、过滤 `#53` 端口后缀，并排除本机已知解析器
- **日志混入返回值**：`get_record_ip` 以 stdout 返回数据，内部错误日志在 `--color` 下会写进同一路 stdout，被调用方当成记录值捕获。错误改为写 stderr
- `nslookup` 输出解析：改为正则提取地址，兼容本地化输出（`服务器` / `地址`）


## [1.0.0] - 2026-11-13

首个开源版本。从个人自用脚本重写而来，配置完全外置。

### 新增

- 优先级选优模型：每轮重新探测，第一个可用节点获胜，主节点恢复自动回切
- 两种探测模式：`tcp`（端口连通）与 `http`（业务状态码 + 可选关键字）
- 多记录支持，一次运行更新多条 Cloudflare 记录
- 九种通知渠道：Bark、企业微信、钉钉、飞书、PushPlus、Telegram、ntfy、通用 webhook、关闭
- 命令行接口：`--config` `--dry-run` `--debug` `--quiet` `--check` `--test-notify` `--color` `--version` `--help`
- 规范化退出码：`0` 成功，`1` 运行失败，`2` 配置错误
- 配置校验，启动前检查必填项、格式和互斥关系
- 内置 `flock` 并发锁，防止 cron 重叠执行
- 内置日志大小轮转，同时提供 logrotate 配置
- `install.sh` / `uninstall.sh`，支持 cron 与 systemd timer 两种调度
- GitHub Actions CI，运行 shellcheck

### 修复

- 读取记录失败时不再"按未知处理"并盲写 DNS，改为直接退出本轮
  （旧行为会产生「从未知切换到 xxx」的错误告警）
- 日志同时输出到终端和文件，文件内始终为纯文本，不写颜色转义符
- 终端输出受 `--quiet` / `--color` 控制，cron 下自动静默

### 变更

- 配置从脚本内硬编码改为外部文件 `/etc/cf-failover/config`
- 通知消息中的中文统一做 URL 编码 / JSON 转义，避免乱码

[1.0.0]: https://github.com/jhonlinus/cf-dns-failover/releases/tag/v1.0.0
