# 故障排查

先看日志，九成问题都在里面：

```bash
sudo tail -50 /var/log/cf-failover.log
```

加 `--debug` 重新跑一次能拿到更多信息：

```bash
sudo cf-failover --dry-run --debug --color
```

---

## 配置阶段

### `config not found: /etc/cf-failover/config`

配置文件没装或路径不对。

```bash
sudo install -d -m 700 /etc/cf-failover
sudo install -m 600 config.example /etc/cf-failover/config
```

或者用 `--config` 指定别的路径。

### 退出码 2，但没有明显报错

退出码 2 表示配置校验失败。具体原因在输出里，但如果不是在终端里跑（比如 cron），输出会被吞掉。手动跑一次就能看到：

```bash
sudo cf-failover --check
```

### `配置缺失：DNS_RECORDS`

`DNS_RECORDS` 必须是非空数组，每项三个字段用 `|` 分隔：

```bash
DNS_RECORDS=(
  "zone_id|record_id|*.gw.example.com"
)
```

常见错误是只写了名字，忘了 ID；或者用了单引号导致变量没展开（这个场景不需要变量，单双引号都行）。

### `DNS_RECORDS[0] 格式错误`

分隔符数量不对。格式固定为 `ZONE_ID|RECORD_ID|RECORD_NAME`，两个 `|`，一个不能少。

---

## 探测阶段

### 日志里的节点 IP 不是最新的，脚本准备切到旧地址

典型症状：域名在 Cloudflare 后台已经改成新 IP，脚本却一直按旧 IP 探测，判定节点故障，然后准备把旧 IP 写回记录。

先确认权威值：

```bash
dig +short NS example.com
# 拿到 NS 后直接问它
dig +short +norecurse A frp1.example.com @ariella.ns.cloudflare.com
```

再逐层对比，看出旧值是卡在哪一层：

```bash
dig +short A frp1.example.com            # 本机解析器
dig +short A frp1.example.com @223.5.5.5 # 公共递归
```

**如果只有权威层是新值**，说明旧答案在递归解析器缓存里。清本机没用，`FLUSH_DNS_CACHE` 也清不掉上游。打开权威解析：

```bash
NODE_LOOKUP="authoritative"
```

**如果权威层也是旧值**，那不是缓存问题，是记录没改成功，回 Cloudflare 后台确认，注意别改错子域或改到通配符之外的副本。

**`FLUSH_DNS_CACHE` 什么时候有用**：只在旧值确实存在于本机缓存时。它需要 root 且本机有 `resolvectl`、`systemd-resolve` 或 `nscd`；群晖这类没有 systemd 的系统三者都没有，日志会明确告警。

**`/etc/hosts` 是个例外**：那里写死的条目永远不会过期，任何 flush 都无效，`system` 模式下 `getent` 会一直优先用它。检查：

```bash
grep -i example.com /etc/hosts
```

### 日志里一直是「所有节点均不可用」，但服务明明是好的

按顺序排查：

**① 端口填错了**

```bash
# 手动测一下
timeout 5 bash -c 'echo > /dev/tcp/1.2.3.4/1210' && echo open || echo closed
```

**② `http` 模式下 `PROBE_HOST` 有问题**

这是最常见的。`PROBE_HOST` 必须是一个**真的有隧道**的域名。填一个不存在的子域，所有节点都会返回 502。

```bash
curl -o /dev/null -w "%{http_code}\n" --max-time 6 \
  --resolve app.gw.example.com:1210:1.2.3.4 \
  http://app.gw.example.com:1210/
```

返回 200/302 才算探针有效。

> 注意：很多 frps 对任何未匹配的 vhost 都返回 502，包括随机编造的子域。所以必须用一个确认能打开的业务域名，不能靠"猜"。

**③ 节点 IP 解析失败**

`NODE_HOSTS` 里写的是域名，但机器解析不了。

```bash
getent ahostsv4 frp1.example.com
```

解析不出来就改用 IP 直填。

### `tcp` 模式显示全部可用，但实际打不开

这是 `tcp` 模式的固有盲区，不是 bug。

frps 的 vhost 端口是常驻监听的。`frpc` 掉线后端口照样 `listen`，TCP 握手成功，脚本认为节点健康。

换成 `http` 模式，或者接受这个盲区（它只用于防机器故障）。

### 切换反复横跳

日志里出现 A → B → A → B 的循环。

原因通常是链路在抖动，不是真故障。两个办法：

1. 把 `CONFIRM_TIMES` 提到 `2`（切换会多等一个周期）
2. 提高探测频率反而会让问题更明显，可以降低到 10 分钟

如果 `B` 节点本身不稳定，那问题在节点上，脚本只是在忠实反映。

---

## 写入阶段

### `更新 xxx 失败：... Authentication error`

Token 无效或权限不够。

```bash
curl -s -H "Authorization: Bearer $DNS_TOKEN" \
  "https://api.cloudflare.com/client/v4/user/tokens/verify"
```

应该返回 `"status":"active"`。

权限要求：`Zone / DNS / Edit`，并且 Zone Resources 必须包含目标域名。

### `更新 xxx 失败：... Record does not exist`

`RECORD_ID` 错了，或者记录已被删除。

重新查：

```bash
curl -s -H "Authorization: Bearer $DNS_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records?type=A&name=gw.example.com"
```

### `读取记录失败：响应中没有 IPv4`

这条记录可能不是 A 记录（比如是 CNAME 或 AAAA）。脚本只处理 A 记录。

### 切换成功了，但用户还是访问旧 IP

DNS 生效有延迟，取决于 TTL。

```bash
dig gw.example.com +short
```

如果返回的还是旧 IP，说明缓存没过期：

- Cloudflare 上的 TTL 还是「自动」（300 秒）→ 改成 60
- 本地浏览器有自己的缓存 → `chrome://net-internals/#dns` 清一下
- 运营商 DNS 缓存 → 只能等

---

## 定时任务

### cron 跑了但没反应

**① 确认任务在里面**

```bash
sudo crontab -l
```

**② 手动跑一次，看是否正常**

```bash
sudo /usr/local/bin/cf-failover --color
```

**③ 检查 cron 服务**

```bash
systemctl status cron      # Debian/Ubuntu
systemctl status crond     # CentOS/RHEL
```

**④ 看 cron 自己的日志**

```bash
journalctl -u cron -n 50
# 或
grep CRON /var/log/syslog
```

### 收到 cron 发来的邮件

说明脚本往 stdout 输出了内容。检查 crontab 里有没有加 `--quiet`。

### 脚本在机器重启后失效

如果用的是 `/var/tmp` 存状态，重启后被清空 —— 这没关系，状态只用于防抖计数。但如果 `STATE_DIR` 指到了不存在的地方：

```bash
sudo mkdir -p /var/tmp/cf-failover
```

---

## 通知

### 收不到通知

```bash
sudo cf-failover --test-notify
```

`--test-notify` 不会报具体错误（避免泄露 token）。手动验证：

```bash
# 企业微信 / 钉钉
curl -s -X POST "$NOTIFY_URL" -H 'Content-Type: application/json' \
  -d '{"msgtype":"text","text":{"content":"test"}}'

# Bark
curl -s "https://api.day.app/$NOTIFY_URL/test/hello"
```

### 中文乱码

脚本文件编码不是 UTF-8。

```bash
file -i cf-failover.sh
```

应该是 `charset=utf-8`。如果是 `iso-8859-1` 或 `unknown-8bit`：

```bash
iconv -f GBK -t UTF-8 cf-failover.sh -o cf-failover.utf8.sh
mv cf-failover.utf8.sh cf-failover.sh
```

用 Windows 记事本或网页编辑器保存容易出这个问题。在服务器上用 `vi`/`nano`，本地用 VS Code 并确认右下角编码是 UTF-8。

### 通知发不出去但 DNS 切了

这是设计如此。通知失败不影响切换，先写 DNS 再发消息。日志里会有记录，但不阻断主流程。

---

## 完全没头绪时

把这个输出贴到 issue 里（**记得先删掉 token**）：

```bash
# 版本与环境
cf-failover --version
bash --version | head -1
curl --version | head -1

# 配置（脱敏）
sudo sed -e 's/\(DNS_TOKEN="\)[^"]*/\1***/' /etc/cf-failover/config

# 日志
sudo tail -80 /var/log/cf-failover.log

# 空跑
sudo cf-failover --dry-run --debug --color
```
