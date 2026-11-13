# Changelog

所有重要变更记录在此文件。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

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
