# 通知渠道配置

所有渠道都由两个配置项控制：

```bash
NOTIFY_TYPE="bark"
NOTIFY_URL="..."
```

配置完先发一条测试：

```bash
sudo cf-failover --test-notify
```

---

## Bark（iOS，推荐）

App Store 安装 [Bark](https://apps.apple.com/app/bark-customed-notifications/id1403753865)，打开后首页有一串 device key。

```bash
NOTIFY_TYPE="bark"
NOTIFY_URL="你的device_key"
```

自建服务器的话填完整地址，脚本会自动识别（以 `http` 开头的视为 base URL）：

```bash
NOTIFY_URL="https://bark.example.com/你的device_key"
```

脚本调用的格式：

```
GET {base}/{urlencoded_title}/{urlencoded_body}?group=cf-failover&ttl=600
```

标题和正文都做了 URL 编码，中文不会乱码。`ttl=600` 表示通知在服务器保留 10 分钟，手机当时离线也能稍后收到。

---

## 企业微信（最稳，适合国内）

在企业微信任意群里 → 右上角 `...` → 群机器人 → 添加机器人 → 复制 Webhook。

```bash
NOTIFY_TYPE="wecom"
NOTIFY_URL="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxxxxxx"
```

没有企业可以用个人身份注册一个，一人企业免费。限制 20 条/分钟，够用。

---

## 钉钉

群设置 → 智能群助手 → 添加机器人 → 自定义。

**安全设置必须选「自定义关键词」，关键词填 `DNS`。** 不配安全设置钉钉会直接拒绝请求。脚本发送的消息以 `[DNS Failover]` 开头，正好命中关键词。

```bash
NOTIFY_TYPE="dingtalk"
NOTIFY_URL="https://oapi.dingtalk.com/robot/send?access_token=xxxxxxxx"
```

如果你改了 `NOTIFY_TITLE`，关键词要跟着改，或者改成「加签」方式。

---

## 飞书

群设置 → 群机器人 → 添加 → 复制 Webhook。

```bash
NOTIFY_TYPE="feishu"
NOTIFY_URL="https://open.feishu.cn/open-apis/bot/v2/hook/xxxxxxxx"
```

飞书的 JSON 结构和钉钉不同，脚本里已分别处理。

---

## PushPlus（只要有微信）

[pushplus.plus](https://www.pushplus.plus) 微信扫码登录 → 一对一推送 → 复制 token。

```bash
NOTIFY_TYPE="pushplus"
NOTIFY_URL="你的32位token"
```

免费版每天 200 条。

---

## Telegram

需要能访问 Telegram API。

1. 找 [@BotFather](https://t.me/BotFather) 建 bot，拿到 token
2. 把你的 bot 拉进一个会话，发一条消息
3. 取 chat_id：`curl "https://api.telegram.org/bot<token>/getUpdates"`

```bash
NOTIFY_TYPE="telegram"
NOTIFY_URL="123456:ABC-DEF...|你的chat_id"
```

中间用 `|` 分隔。chat_id 可以是数字，也可以是 `@channel_name`。

---

## ntfy

[ntfy.sh](https://ntfy.sh) 无需注册，直接用 topic 名。也可以自建。

```bash
NOTIFY_TYPE="ntfy"
NOTIFY_URL="https://ntfy.sh/my-secret-topic"
```

手机装 ntfy App 订阅同一个 topic。**公开实例上 topic 名就是密码**，起个猜不到的。

---

## 通用 Webhook

任何接受 JSON POST 的地址。脚本发送：

```json
{
  "title": "DNS Failover",
  "body": "切换：gw.example.com: 1.2.3.4 -> 5.6.7.8",
  "host": "monitor-01",
  "time": "2026-11-13T11:42:31+08:00"
}
```

```bash
NOTIFY_TYPE="webhook"
NOTIFY_URL="https://your-endpoint.example.com/hook"
```

可以接到自建的 n8n、Node-RED、Gotify，或者自己的服务里。

---

## 关闭通知

```bash
NOTIFY_TYPE="none"
```

---

## 消息内容

| 场景 | 示例 |
|---|---|
| 切换 | `切换：gw.example.com: 1.2.3.4 -> 5.6.7.8（frp2.example.com）` |
| 回切 | `回切：gw.example.com: 5.6.7.8 -> 1.2.3.4（frp1.example.com）` |
| 全挂 | `所有节点不可用，DNS 保持原值。请检查节点与网络。` |
| 失败 | `切换失败，目标 5.6.7.8（frp2.example.com），请查看日志。` |

「全挂」类告警受 `ALERT_INTERVAL` 限流（默认 1800 秒），不会每分钟刷一条。

回切通知可以用 `NOTIFY_ON_FAILBACK=0` 关掉。
