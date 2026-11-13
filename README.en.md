# cf-dns-failover

[![CI](https://github.com/jhonlinus/cf-dns-failover/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/jhonlinus/cf-dns-failover/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A minimal Cloudflare DNS failover script. It probes a prioritised list of
nodes and points a DNS record at the first one that answers.

> [中文文档](README.md)

```
node A healthy  ->  DNS = A   (nothing to do, exit)
node A down     ->  DNS = B   (write record + notify)
node A back     ->  DNS = A   (automatic failback)
```

## Why

Cloudflare's free plan has no health checks. Multiple A records only move the
choice to the client: no probing, sticky per-resolver caching, and most
non-browser clients never try the second address.

The real options are Load Balancing ($5/mo) or doing it yourself. This is the
latter — no proxy, DNS records only, so **zero added latency** on the normal path.

## Features

- Priority selection, not round-robin. Re-evaluated every run, so failback
  needs no extra logic.
- Two probe modes: `tcp` (port only) and `http` (status code + optional keyword).
- Debounce: require N consecutive agreeing rounds before rewriting DNS.
- Refuses to act when the current record cannot be read.
- Multiple records per run.
- Nine notification backends: Bark, WeCom, DingTalk, Feishu, PushPlus,
  Telegram, ntfy, generic webhook, or none.
- `--dry-run` to see decisions without touching anything.
- Built-in `flock` so overlapping cron runs are harmless.
- No dependencies beyond `bash` and `curl`.

## Quick start

```bash
git clone https://github.com/jhonlinus/cf-dns-failover.git
cd cf-dns-failover
sudo ./install.sh

sudo vi /etc/cf-failover/config    # fill in DNS_TOKEN, DNS_RECORDS, NODE_HOSTS
sudo cf-failover --check
sudo cf-failover --dry-run
sudo cf-failover
```

## Configuration

See [`config.example`](config.example) for the annotated template.

| Key | Description |
|---|---|
| `DNS_TOKEN` | Cloudflare API token, `Zone / DNS / Edit`, scoped to one zone |
| `DNS_RECORDS` | `"ZONE_ID\|RECORD_ID\|NAME"` per entry |
| `NODE_HOSTS` | Nodes in priority order; hostnames or IPv4 |
| `PROBE_MODE` | `tcp` or `http` |
| `PROBE_PORT` | Port to probe (FRP: usually `vhostHTTPPort`) |
| `PROBE_HOST` | Required for `http` mode; must have a live tunnel |
| `CONFIRM_TIMES` | Rounds that must agree before switching |
| `DNS_TTL` | TTL written with the record |
| `NOTIFY_TYPE` | `bark`, `wecom`, `dingtalk`, `feishu`, `pushplus`, `telegram`, `ntfy`, `webhook`, `none` |

### Choosing a probe mode

`tcp` detects a dead host. It **cannot** detect a dead tunnel: frps keeps
`vhostHTTPPort` listening after frpc disconnects, so the handshake still
succeeds while every request returns 502.

`http` sends a real request through the candidate IP with `curl --resolve`,
catching both cases. It requires `PROBE_HOST` to point at a hostname that
actually has a working tunnel.

Note that many frps instances return 502 for any unmatched vhost, including
made-up subdomains. A 502 therefore proves the request reached frps, not that
the tunnel is alive — which is exactly why status-code allowlisting beats
port checking.

## Scheduling

```cron
*/5 * * * * /usr/local/bin/cf-failover --quiet
```

`install.sh --systemd` sets up a timer instead.

Pick `CONFIRM_TIMES` to match the interval: `2` at one minute, `1` at five.
Two probes sixty seconds apart can be fooled by a blip; two probes five
minutes apart cannot.

## Security

Use a scoped `Zone / DNS / Edit` token, never the Global API Key. The config
lives in `/etc/cf-failover/config` with mode 600 and is not part of the repo.

## Compatibility

Linux with bash 4.3+. Requires `curl` and `timeout`. Not supported on native
Windows; works under WSL.

## License

[MIT](LICENSE) © 2026 JhonLinus
