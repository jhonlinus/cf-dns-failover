#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cfdash — cf-failover 的监控面板（零依赖，单文件）

只做三件事：读、看、触发。
  * 读：解析 cf-failover 的配置、状态文件与日志，还原每一轮探测
  * 看：网页上展示当前生效 IP、各节点健康、切换时间线
  * 触发：手动跑一轮检测（可 dry-run），把输出回显到页面

不做的事：不自己写 Cloudflare、不改你的配置、不在后台跑任何循环。

同时兼容两种安装形态：
  A. 仓库版 cf-failover.sh —— /etc/cf-failover/config + /usr/local/bin/cf-failover
  B. 早期 1Panel 计划任务版 —— 配置内联在 *.sh 里（/opt/1panel/task/shell/...）

用法：
    python3 cfdash.py                        # 监听 127.0.0.1:8077
    python3 cfdash.py --port 8077 --bind 0.0.0.0
    python3 cfdash.py --sock /run/cfdash.sock     # 走 fnOS 统一网关
    python3 cfdash.py --auth admin:secret          # 需要时开 Basic 认证
    python3 cfdash.py --no-run                     # 禁止页面上点「立即检测」
"""

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import socketserver
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
VERSION = "1.0.0"

# ============================================================================
# 路径探测
# ============================================================================

DEFAULT_CONFIG = "/etc/cf-failover/config"
DEFAULT_BIN = "/usr/local/bin/cf-failover"
DEFAULT_LOG = "/var/log/cf-failover.log"
DEFAULT_STATE_DIR = "/var/tmp/cf-failover"

# 内联配置的脚本（旧形态），按顺序找第一个存在的
INLINE_CANDIDATES = (
    "/opt/1panel/task/shell/frp-dns-callback/frp-dns-callback.sh",
    "/root/frp-dns-callback.sh",
    "/usr/local/bin/frp-dns-callback.sh",
)

# 状态文件的两种摆放方式
STATE_FILES = ("pending_ip", "pending_cnt", "alert_ts")


def _first_existing(paths, kind="file"):
    for p in paths:
        try:
            if (Path(p).is_file() if kind == "file" else Path(p).is_dir()):
                return p
        except OSError:
            continue
    return ""


class Paths:
    """一次解析出所有要读的路径，运行期可刷新。"""

    def __init__(self):
        self.reload()

    def reload(self):
        self.config = os.environ.get("CFDNS_CONFIG") or (
            DEFAULT_CONFIG if Path(DEFAULT_CONFIG).is_file() else ""
        )
        self.script = os.environ.get("CFDNS_SCRIPT") or _first_existing(INLINE_CANDIDATES)
        self.bin = (
            DEFAULT_BIN
            if Path(DEFAULT_BIN).is_file()
            else (str(HERE / "cf-failover.sh") if (HERE / "cf-failover.sh").is_file() else "")
        )
        # 有 config 走仓库版，否则退到内联脚本
        self.mode = "config" if self.config else ("inline" if self.script else "none")
        self.script_path = self.config if self.mode == "config" else self.script

        base = os.environ.get("CFDNS_BASE") or ""
        base_dir = Path(base) if base else HERE

        env_log = os.environ.get("CFDNS_LOG")
        if env_log:
            self.log = env_log
        elif Path(DEFAULT_LOG).is_file():
            self.log = DEFAULT_LOG
        else:
            self.log = str(base_dir / "cf-failover.log")

        st = os.environ.get("CFDNS_STATE") or DEFAULT_STATE_DIR
        # 目录形态 /var/tmp/cf-failover/{pending_ip,...}
        self.state_dir = st if Path(st).is_dir() else (st if os.environ.get("CFDNS_STATE") else "")
        # 扁平形态 /var/tmp/cf-failover.pending_ip
        self.state_flat = False
        if self.state_dir and not Path(self.state_dir).is_dir():
            self.state_flat = True
        if not self.state_dir:
            probe = os.environ.get("CFDNS_STATE_DIR_PROBE") or DEFAULT_STATE_DIR
            if Path(probe).is_dir():
                self.state_dir = probe
            else:
                self.state_flat = True
                self.state_dir = probe

        self.data = Path(os.environ.get("CFDNS_DATA") or (HERE / "data"))
        try:
            self.data.mkdir(parents=True, exist_ok=True)
        except OSError:
            pass  # 安装目录只读时静默跳过，面板本身不落盘


PATHS = Paths()


# ============================================================================
# shell 配置解析（只读取，绝不 source —— 里面有 token）
# ============================================================================

MASK_KEYS = ("DNS_TOKEN", "CF_TOKEN", "TOKEN", "NOTIFY_URL", "SECRET", "PASSWORD", "KEY")
SECRET_RE = re.compile(r"^[A-Za-z0-9_\-]{24,}$")


def _strip_comment(line):
    """去掉行尾 # 注释，但保留引号内的 #。"""
    out, quote = [], ""
    for ch in line:
        if quote:
            if ch == quote:
                quote = ""
            out.append(ch)
            continue
        if ch in "\"'":
            quote = ch
            out.append(ch)
            continue
        if ch == "#":
            break
        out.append(ch)
    return "".join(out).rstrip()


def _unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def parse_shell_config(text):
    """把一个 shell 配置文件读成 dict；数组读成 list。"""
    cfg, buf, in_array, array_key = {}, "", False, None
    for raw in text.splitlines():
        line = raw.strip()
        if in_array:
            buf += " " + line
            if ")" in line:
                in_array = False
                items = re.findall(r'"([^"]*)"|\'([^\']*)\'|([^\s()]+)', buf)
                cfg[array_key] = [next(x for x in it if x != "") for it in items if any(it)]
                buf = ""
            continue
        if not line or line.startswith("#"):
            continue
        line = _strip_comment(line)
        if not line:
            continue
        m = re.match(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if val.startswith("("):
            if val.rstrip().endswith(")"):
                items = re.findall(r'"([^"]*)"|\'([^\']*)\'|([^\s()]+)', val)
                cfg[key] = [next(x for x in it if x != "") for it in items if any(it)]
            else:
                in_array, array_key, buf = True, key, val
            continue
        cfg[key] = _unquote(val)
    return cfg


def mask_value(key, value):
    """敏感值打码：保留前 4 位与后 4 位。"""
    if isinstance(value, list):
        return [mask_value(key, v) for v in value]
    if not isinstance(value, str):
        return value
    k = key.upper()
    if not any(s in k for s in MASK_KEYS):
        return value
    if not value:
        return ""
    if len(value) <= 8:
        return "*" * len(value)
    # 通知 URL 只露出域名/类型
    if "NOTIFY_URL" in k and value.startswith("http"):
        m = re.match(r"^(https?://[^/]+)(.*)$", value)
        return (m.group(1) + "/***") if m else "***"
    return value[:4] + "*" * max(4, len(value) - 8) + value[-4:]


def load_config():
    p = PATHS
    if not p.script_path or not Path(p.script_path).is_file():
        return {"found": False, "mode": p.mode, "path": "", "vars": {}, "records": [], "nodes": []}
    try:
        text = Path(p.script_path).read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        return {"found": False, "mode": p.mode, "path": p.script_path, "error": str(e),
                "vars": {}, "records": [], "nodes": []}

    raw = parse_shell_config(text)

    nodes = raw.get("NODE_HOSTS") or []
    if isinstance(nodes, str):
        nodes = [x for x in re.split(r"[\s,]+", nodes) if x]

    records = []
    if raw.get("DNS_RECORDS"):
        for entry in raw["DNS_RECORDS"]:
            parts = str(entry).split("|")
            if len(parts) >= 3:
                records.append({"zone": parts[0].strip(), "record": parts[1].strip(), "name": parts[2].strip()})
    if raw.get("DNS_RECORD_ID") or raw.get("DNS_ZONE_ID"):
        records.append({
            "zone": raw.get("DNS_ZONE_ID", ""),
            "record": raw.get("DNS_RECORD_ID", ""),
            "name": raw.get("DNS_NAME", ""),
        })

    token = raw.get("DNS_TOKEN") or raw.get("CF_TOKEN") or ""
    safe = {k: mask_value(k, v) for k, v in raw.items()}

    return {
        "found": True,
        "mode": p.mode,
        "path": p.script_path,
        "vars": safe,
        "records": records,
        "nodes": [str(n) for n in nodes],
        "has_token": bool(token),
        "_token": token,
        "probe": {
            "mode": raw.get("PROBE_MODE", "tcp"),
            "port": raw.get("PROBE_PORT", ""),
            "host": raw.get("PROBE_HOST", ""),
            "path": raw.get("PROBE_PATH", "/"),
            "proto": raw.get("PROBE_PROTO", "http"),
            "timeout": raw.get("TIMEOUT", ""),
            "ok_codes": raw.get("OK_CODES", ""),
            "lookup": raw.get("NODE_LOOKUP", "system"),
        },
        "behaviour": {
            "ttl": raw.get("DNS_TTL", ""),
            "proxied": raw.get("DNS_PROXIED", ""),
            "confirm": raw.get("CONFIRM_TIMES", "1"),
            "alert_interval": raw.get("ALERT_INTERVAL", ""),
        },
        "notify": {
            "type": raw.get("NOTIFY_TYPE", "none"),
            "title": raw.get("NOTIFY_TITLE", ""),
            "on_switch": raw.get("NOTIFY_ON_SWITCH", ""),
            "on_failback": raw.get("NOTIFY_ON_FAILBACK", ""),
        },
        "paths": {
            "log": raw.get("LOG_FILE", "") or PATHS.log,
            "state": raw.get("STATE_DIR", "") or PATHS.state_dir,
        },
    }


def read_state(cfg):
    """pending_ip / pending_cnt / alert_ts，目录与扁平两种形态都试。"""
    st = {}
    bases = []
    sd = (cfg.get("paths", {}) or {}).get("state") if cfg else ""
    for d in [PATHS.state_dir, sd, DEFAULT_STATE_DIR]:
        if d:
            bases.append((d, os.path.join(d, "%s")))
            bases.append((d, d + ".%s"))
    for _, pattern in bases:
        for name in STATE_FILES:
            path = pattern % name
            if name in st:
                continue
            try:
                v = Path(path).read_text(encoding="utf-8", errors="replace").strip()
                if v:
                    st[name] = v
                    st.setdefault("_src", path)
            except OSError:
                continue
    if "pending_cnt" in st:
        try:
            st["pending_cnt"] = int(st["pending_cnt"])
        except ValueError:
            pass
    if "alert_ts" in st:
        try:
            st["alert_ts"] = int(float(st["alert_ts"]))
        except ValueError:
            pass
    return st


# ============================================================================
# 日志解析
# ============================================================================

LINE_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+(?:\[([A-Za-z]+)\]\s+)?(.*)$")
TS_FMT = "%Y-%m-%d %H:%M:%S"

RE_START = re.compile(r"开始检测")
RE_MODE = re.compile(r"模式=([a-z]+)")
RE_PORT = re.compile(r"端口=(\d+)")
RE_NODES = re.compile(r"节点=(\d+)")
RE_CUR = re.compile(r"当前=([0-9.]+|未知|-|空)?")
RE_OK = re.compile(r"(?<!不)可用[：:]\s*(\S+)\s*->\s*([0-9.]+)\s*[（(]([^）)]*)[）)]")
RE_FAIL = re.compile(r"不可用[：:]\s*(\S+)\s*->\s*([0-9.]+)\s*[（(]([^）)]*)[）)]")
RE_RESOLVE_FAIL = re.compile(r"解析失败[：:]\s*(\S+)")
RE_NOCHANGE = re.compile(r"无需变更[：:]")
RE_NOCHANGE_IP = re.compile(r"无需变更[：:].*?(?:已经是|所有记录已是)\s*([0-9.]+)")
RE_PENDING = re.compile(r"候选\s*(\S+?)\s*[（(]([0-9.]+)[）)]\s*确认\s*(\d+)\s*/\s*(\d+)")
RE_SKIP = re.compile(r"本轮不切换")
# 三种结束行：
#   ===== 本轮结束：8.138.226.33 -> 8.163.29.60
#   本轮结束：切换完成 -> 8.163.29.60
#   本轮结束：[dry-run] 将回切到 8.163.29.60（未实际写入）
RE_END = re.compile(r"本轮结束[：:]?(.*)$")
RE_END_ARROW = re.compile(r"([0-9.]+)\s*->\s*([0-9.]+)")
RE_END_TARGET = re.compile(r"(?:切换|回切)(?:完成)?\s*(?:->|到)?\s*([0-9.]+)")
RE_END_KIND = re.compile(r"回切")
RE_ALLFAIL = re.compile(r"所有节点(?:均)?不可用")
RE_READERR = re.compile(r"读取记录\s*\S*\s*失败|无法读取\s*\S*\s*当前值|API 无响应")
RE_WRITE = re.compile(r"(?:DNS\s*已更新[：:]|^)(\S+)\s*->\s*([0-9.]+)\s*[（(]TTL")
RE_CONFIG_ERR = re.compile(r"配置缺失[：:]|格式错误")
RE_DRYRUN = re.compile(r"\[dry-run\]")
RE_NOTIFY = re.compile(r"已推送通知|跳过通知")


def _level_from(level, msg):
    if level:
        level = level.lower()
        if level in ("ok", "info", "warn", "error", "debug"):
            return level
    if "ERROR" in msg:
        return "error"
    if "WARN" in msg:
        return "warn"
    if RE_ALLFAIL.search(msg) or RE_READERR.search(msg) or "失败" in msg:
        return "error"
    if RE_FAIL.search(msg) or "不可用" in msg:
        return "warn"
    if RE_OK.search(msg) or "切换完成" in msg or "回切完成" in msg:
        return "ok"
    if RE_PENDING.search(msg):
        return "warn"
    return "info"


def _ts(s):
    try:
        return int(time.mktime(time.strptime(s, TS_FMT)))
    except Exception:
        return 0


def parse_log(path, max_bytes=4 * 1024 * 1024, max_rounds=4000):
    """把日志还原成 rounds（每轮探测）+ events（切换/异常）+ tail（原始行）。"""
    rounds, events, tail = [], [], []
    try:
        size = os.path.getsize(path)
    except OSError:
        return rounds, events, tail, 0

    with open(path, "rb") as f:
        if size > max_bytes:
            f.seek(size - max_bytes)
            f.readline()  # 丢掉半行
        data = f.read().decode("utf-8", errors="replace")

    cur = None
    for raw in data.splitlines():
        if not raw.strip():
            continue
        m = LINE_RE.match(raw)
        if m:
            tss, lvl, msg = m.group(1), m.group(2), m.group(3)
            ts = _ts(tss)
        else:
            lvl, msg, ts = None, raw.strip(), 0
        level = _level_from(lvl, msg)

        tail.append({"ts": ts, "level": level, "msg": msg})
        if len(tail) > 800:
            tail = tail[-800:]

        if RE_START.search(msg):
            cur = {
                "ts": ts,
                "mode": (RE_MODE.search(msg).group(1) if RE_MODE.search(msg) else ""),
                "port": (RE_PORT.search(msg).group(1) if RE_PORT.search(msg) else ""),
                "nodes_declared": int(RE_NODES.search(msg).group(1)) if RE_NODES.search(msg) else 0,
                "current": (RE_CUR.search(msg).group(1) or "") if RE_CUR.search(msg) else "",
                "probes": [],
                "result": "unknown",
                "ip": "",
                "target": "",
                "kind": "",
                "confirm": "",
                "dry": False,
                "notified": False,
                "lines": [],
            }
            rounds.append(cur)
            if len(rounds) > max_rounds:
                rounds.pop(0)
            continue

        if cur is None:
            # 没有「开始检测」开头的报错行（配置校验失败、手工执行失败）单独成轮
            if RE_CONFIG_ERR.search(msg) or level == "error":
                cur = {
                    "ts": ts, "mode": "", "port": "", "nodes_declared": 0, "current": "",
                    "probes": [], "result": ("config" if RE_CONFIG_ERR.search(msg) else "error"),
                    "ip": "", "target": "", "kind": "", "confirm": "", "dry": False,
                    "notified": False, "lines": [],
                }
                rounds.append(cur)
                if len(rounds) > max_rounds:
                    rounds.pop(0)
                events.append({"ts": ts, "type": cur["result"], "ip": "", "text": msg, "from": ""})
            else:
                continue

        cur["lines"].append(msg)

        # 顺序要紧：「不可用」里含「可用」，失败必须排在成功前面判
        mf = RE_FAIL.search(msg)
        if mf:
            cur["probes"].append({"host": mf.group(1), "ip": mf.group(2),
                                  "result": mf.group(3), "ok": False})
            if cur["result"] == "unknown":
                cur["result"] = "probe"
            continue

        mo = RE_OK.search(msg)
        if mo:
            cur["probes"].append({"host": mo.group(1), "ip": mo.group(2),
                                  "result": mo.group(3), "ok": True})
            cur["target"] = mo.group(2)
            if cur["result"] == "unknown":
                cur["result"] = "probe"
            continue

        mr = RE_RESOLVE_FAIL.search(msg)
        if mr:
            cur["probes"].append({"host": mr.group(1), "ip": "", "result": "dns-fail", "ok": False})
            continue

        # 真正写进 Cloudflare 的那一行
        mw = RE_WRITE.search(msg)
        if mw:
            cur["ip"] = mw.group(2)
            cur["wrote"] = True
            if cur["result"] in ("unknown", "probe", "pending"):
                cur["result"] = "switch"
            continue

        me = RE_END.search(msg)
        if me:
            tail_txt = me.group(1) or ""
            arrow = RE_END_ARROW.search(tail_txt)
            target = RE_END_TARGET.search(tail_txt)
            if target:
                cur["ip"] = target.group(1)
            elif arrow:
                cur["ip"] = arrow.group(2)
            if arrow and not cur.get("current"):
                cur["current"] = arrow.group(1)
            if cur["ip"]:
                cur["dry"] = bool(RE_DRYRUN.search(tail_txt))
                if cur["dry"]:
                    cur["result"] = "dryrun"
                else:
                    cur["result"] = "failback" if RE_END_KIND.search(tail_txt) else "switch"
                cur["kind"] = "回切" if cur["result"] == "failback" else "切换"
                events.append({"ts": ts, "type": cur["result"], "ip": cur["ip"],
                               "text": msg, "from": cur.get("current", "")})
            continue

        mp = RE_PENDING.search(msg)
        if mp:
            cur["confirm"] = "%s/%s" % (mp.group(3), mp.group(4))
            cur["target"] = mp.group(2)
            if cur["result"] in ("unknown", "probe"):
                cur["result"] = "pending"
            continue

        if RE_ALLFAIL.search(msg):
            cur["result"] = "allfail"
            if not any(e["ts"] == ts and e["type"] == "allfail" for e in events[-4:]):
                events.append({"ts": ts, "type": "allfail", "ip": "", "text": msg,
                               "from": cur.get("current", "")})
            continue

        if RE_READERR.search(msg):
            if cur["result"] in ("unknown", "probe"):
                cur["result"] = "readerr"
            if not any(e["ts"] == ts and e["type"] == "readerr" for e in events[-4:]):
                events.append({"ts": ts, "type": "readerr", "ip": "", "text": msg, "from": ""})
            continue

        if RE_NOCHANGE.search(msg):
            if cur["result"] in ("unknown", "probe"):
                cur["result"] = "nochange"
            mi = RE_NOCHANGE_IP.search(msg)
            if mi:
                cur["ip"] = mi.group(1)
                if not cur["current"]:
                    cur["current"] = mi.group(1)
            continue

        if RE_SKIP.search(msg):
            if cur["result"] in ("unknown", "probe"):
                cur["result"] = "pending"
            continue

        if RE_NOTIFY.search(msg):
            cur["notified"] = True
            continue

    # 收尾：把「有 current 但没结果」的轮次补成 nochange
    for r in rounds:
        if r["result"] in ("unknown", "probe") and r["probes"]:
            r["result"] = "nochange"

    # 只保留最近一段事件，避免序列化过大
    events = [e for e in events if e["type"] != "write"][-200:]
    return rounds, events, tail, size


def classify_rounds(rounds, primary_host):
    """日志里不一定写明「回切」，用目标 IP 是否等于第一优先节点的 IP 来判断。"""
    if not primary_host:
        return
    for r in rounds:
        if r["result"] not in ("switch", "dryrun"):
            continue
        ip = r.get("ip") or ""
        if not ip:
            continue
        prim = [p for p in r["probes"] if p["host"] == primary_host]
        # 配置可能已经改过、和日志里的主机名对不上；脚本是按优先级顺序探测的，
        # 第一个就成功的节点即第一优先节点，等价于「回切」。
        back_to_primary = (prim and prim[0]["ip"] == ip) or (
            not prim and r["probes"] and r["probes"][0]["ok"] and r["probes"][0]["ip"] == ip
        )
        if back_to_primary:
            r["result"] = "dryrun" if r["dry"] else "failback"
            r["kind"] = "回切"
        elif not r["dry"]:
            r["result"] = "switch"
            r["kind"] = "切换"


def summarise(rounds):
    """运行状态统计 + 节点健康。"""
    now = int(time.time())
    day_ago, week_ago = now - 86400, now - 7 * 86400

    total = len(rounds)
    r24 = [r for r in rounds if r["ts"] >= day_ago]
    fails24 = [r for r in r24 if r["result"] in ("allfail", "readerr")]
    switches = [r for r in rounds if r["result"] in ("switch", "failback") and not r["dry"]]
    switches7 = [r for r in switches if r["ts"] >= week_ago]

    # 轮次间隔中位数，用于估算下一次检测
    gaps = []
    for a, b in zip(rounds[-40:], rounds[-39:]):
        d = b["ts"] - a["ts"]
        if 10 < d < 7200:
            gaps.append(d)
    gaps.sort()
    interval = gaps[len(gaps) // 2] if gaps else 0

    last = rounds[-1] if rounds else None
    streak_primary = 0
    if rounds:
        for r in reversed(rounds):
            ok = [p for p in r["probes"] if p["ok"]]
            if ok and r["result"] in ("nochange", "probe"):
                streak_primary += 1
            else:
                break

    per_node = {}
    for r in rounds[-576:]:  # 约 2 天（5 分钟一轮）
        for p in r["probes"]:
            key = p["host"]
            d = per_node.setdefault(key, {"ok": 0, "fail": 0, "last_ok": 0, "last_fail": 0,
                                          "last_result": "", "last_ip": ""})
            d["last_result"] = p["result"]
            d["last_ip"] = p["ip"]
            if p["ok"]:
                d["ok"] += 1
                d["last_ok"] = r["ts"]
            else:
                d["fail"] += 1
                d["last_fail"] = r["ts"]

    # 每轮选中的节点（供时间条与散点用）
    for r in rounds:
        ok = [p for p in r["probes"] if p["ok"]]
        r["selected"] = ok[0]["host"] if ok else ""

    return {
        "rounds_total": total,
        "rounds_24h": len(r24),
        "fails_24h": len(fails24),
        "switches_total": len(switches),
        "switches_7d": len(switches7),
        "interval": interval,
        "last_ts": last["ts"] if last else 0,
        "last_result": last["result"] if last else "",
        "last_ip": (last.get("ip") or last.get("current") or "") if last else "",
        "streak_primary_up": streak_primary,
        "per_node": per_node,
        "health_24h": (0 if not r24 else round(100.0 * (len(r24) - len(fails24)) / len(r24), 1)),
    }


def compact_rounds(rounds, limit=288):
    """压缩成前端画时间条用的数组。"""
    out = []
    for r in rounds[-limit:]:
        out.append({
            "t": r["ts"],
            "r": r["result"],
            "ip": r.get("ip") or r.get("current") or "",
            "n": r.get("selected", ""),
            "p": [(p["host"], 1 if p["ok"] else 0, p["result"]) for p in r["probes"]],
            "c": r.get("confirm", ""),
        })
    return out


# ============================================================================
# Cloudflare 实时校验（只读，只在服务端做，token 不出机器）
# ============================================================================

_cf_cache = {"ts": 0, "key": "", "data": None}
_cf_lock = threading.Lock()


def cf_record(zone, rec, token, ttl=45):
    if not token or not zone or not rec:
        return {"ok": False, "error": "未配置 token / zone / record"}
    key = zone + "|" + rec
    with _cf_lock:
        if _cf_cache["data"] and _cf_cache["key"] == key and time.time() - _cf_cache["ts"] < ttl:
            return _cf_cache["data"]

    url = "https://api.cloudflare.com/client/v4/zones/%s/dns_records/%s" % (zone, rec)
    req = urllib.request.Request(url, headers={
        "Authorization": "Bearer " + token,
        "Content-Type": "application/json",
        "User-Agent": "cfdash/" + VERSION,
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            payload = json.loads(r.read())
        res = payload.get("result") or {}
        data = {
            "ok": bool(payload.get("success")),
            "content": res.get("content", ""),
            "ttl": res.get("ttl", ""),
            "proxied": res.get("proxied", None),
            "type": res.get("type", ""),
            "name": res.get("name", ""),
            "modified_on": res.get("modified_on", ""),
            "checked_at": int(time.time()),
        }
    except urllib.error.HTTPError as e:
        data = {"ok": False, "error": "HTTP %s" % e.code, "checked_at": int(time.time())}
    except Exception as e:  # noqa: BLE001
        data = {"ok": False, "error": type(e).__name__ + ": " + str(e)[:120], "checked_at": int(time.time())}

    with _cf_lock:
        _cf_cache.update({"ts": time.time(), "key": key, "data": data})
    return data


# ============================================================================
# 触发一轮检测
# ============================================================================

_run_lock = threading.Lock()
_run_state = {"running": False, "started": 0, "last": None}


def build_command(dry):
    p = PATHS
    if p.mode == "config":
        if not p.bin:
            return None, "找不到 cf-failover 可执行文件（/usr/local/bin/cf-failover）"
        cmd = [p.bin, "--config", p.config]
        if dry:
            cmd.append("--dry-run")
        return cmd, ""
    if p.mode == "inline":
        if not p.script:
            return None, "找不到脚本"
        if dry:
            return None, "内联配置的老脚本不支持 dry-run，请直接跑一轮（不改 IP 时会自动跳过写入）"
        return ["/bin/bash", p.script], ""
    return None, "未检测到已安装的 cf-failover"


def run_once(dry=False):
    if not _run_lock.acquire(blocking=False):
        return {"ok": False, "error": "已有一轮检测在跑，请稍候"}
    try:
        cmd, err = build_command(dry)
        if not cmd:
            return {"ok": False, "error": err}
        _run_state.update({"running": True, "started": int(time.time())})
        t0 = time.time()
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=120)
            out = (r.stdout or "") + (("\n" + r.stderr) if (r.stderr or "").strip() else "")
            rc = r.returncode
        except subprocess.TimeoutExpired:
            out, rc = "执行超时（120 秒）", 124
        except FileNotFoundError:
            out, rc = "找不到可执行文件：" + cmd[0], 127
        except Exception as e:  # noqa: BLE001
            out, rc = type(e).__name__ + ": " + str(e), 1
        dur = round(time.time() - t0, 2)
        lines = [ln for ln in out.splitlines() if ln.strip()][-80:]
        res = {"ok": rc == 0, "rc": rc, "dur": dur, "cmd": " ".join(cmd), "output": lines,
               "at": int(time.time())}
        _run_state["last"] = res
        return res
    finally:
        _run_state["running"] = False
        _run_lock.release()


# ============================================================================
# 快照
# ============================================================================

_snap_cache = {"key": "", "ts": 0, "data": None}
_snap_lock = threading.Lock()


def snapshot(force=False):
    cfg = load_config()
    log_path = os.environ.get("CFDNS_LOG") or (cfg.get("paths", {}) or {}).get("log") or PATHS.log
    try:
        st = os.stat(log_path)
        sig = (log_path, st.st_mtime, st.st_size, cfg.get("path", ""))
    except OSError:
        sig = (log_path, 0, 0, cfg.get("path", ""))
    key = hashlib.md5(repr(sig).encode()).hexdigest()

    with _snap_lock:
        if not force and _snap_cache["data"] and _snap_cache["key"] == key and _snap_cache["ts"] > time.time() - 3:
            return _snap_cache["data"]

    t0 = time.time()
    rounds, events, tail, log_size = parse_log(log_path)
    nodes_cfg = cfg.get("nodes") or []
    classify_rounds(rounds, nodes_cfg[0] if nodes_cfg else "")
    stats = summarise(rounds)
    state = read_state(cfg)

    live = {"ok": False, "error": "未配置", "checked_at": int(time.time())}
    stub = os.environ.get("CFDNS_LIVE_STUB")
    if stub:
        try:
            live = dict(json.loads(stub), checked_at=int(time.time()))
        except ValueError:
            pass
    elif cfg.get("found") and cfg.get("records"):
        rec = cfg["records"][0]
        live = cf_record(rec.get("zone", ""), rec.get("record", ""), cfg.get("_token", ""))

    # 日志里的「观测值」与线上值对比
    observed = stats.get("last_ip", "")
    drift = bool(live.get("ok") and observed and live.get("content") and live["content"] != observed)

    nodes = []
    for i, h in enumerate(cfg.get("nodes", [])):
        info = stats["per_node"].get(h, {})
        nodes.append({
            "host": h,
            "primary": i == 0,
            "priority": i + 1,
            "ip": info.get("last_ip", ""),
            "last_result": info.get("last_result", ""),
            "last_ok": info.get("last_ok", 0),
            "last_fail": info.get("last_fail", 0),
            "ok": info.get("ok", 0),
            "fail": info.get("fail", 0),
            "rate": (0 if not (info.get("ok", 0) + info.get("fail", 0))
                     else round(100.0 * info["ok"] / (info["ok"] + info["fail"]), 1)),
        })
    # 日志里出现过但配置里没有的节点也列出来
    for h, info in stats["per_node"].items():
        if h not in [n["host"] for n in nodes]:
            nodes.append({"host": h, "primary": False, "priority": len(nodes) + 1,
                          "ip": info.get("last_ip", ""), "last_result": info.get("last_result", ""),
                          "last_ok": info.get("last_ok", 0), "last_fail": info.get("last_fail", 0),
                          "ok": info.get("ok", 0), "fail": info.get("fail", 0),
                          "rate": (0 if not (info["ok"] + info["fail"]) else
                                   round(100.0 * info["ok"] / (info["ok"] + info["fail"]), 1))})

    data = {
        "version": VERSION,
        "now": int(time.time()),
        "elapsed_ms": 0,
        "install": {
            "mode": cfg.get("mode", "none"),
            "config_path": cfg.get("path", ""),
            "log_path": log_path,
            "log_size": log_size,
            "state": state,
            "found": cfg.get("found", False),
            "run_enabled": RUN_ALLOWED,
        },
        "config": {k: v for k, v in cfg.items() if not k.startswith("_")},
        "nodes": nodes,
        "live": live,
        "observed_ip": observed,
        "drift": drift,
        "stats": stats,
        "rounds": compact_rounds(rounds),
        "events": events[-40:],
        "log": tail[-200:],
        "last_run": _run_state.get("last"),
        "running": _run_state.get("running", False),
    }
    data["elapsed_ms"] = int((time.time() - t0) * 1000)

    with _snap_lock:
        _snap_cache.update({"key": key, "ts": time.time(), "data": data})
    return data


# ============================================================================
# HTTP
# ============================================================================

RUN_ALLOWED = True
AUTH = ("", "")


class Handler(BaseHTTPRequestHandler):
    server_version = "cfdash/" + VERSION
    protocol_version = "HTTP/1.1"

    # ---------- 工具 ----------

    def log_message(self, fmt, *args):  # 静音：不要每个请求刷屏
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Frame-Options", "SAMEORIGIN")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, obj, code=200, etag=None):
        raw = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        tag = '"%s"' % hashlib.md5(raw).hexdigest()[:16]
        if etag and self.headers.get("If-None-Match") == tag:
            self.send_response(304)
            self.send_header("ETag", tag)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        self._send(code, raw, extra={"ETag": tag})

    def _authorized(self):
        if not AUTH[0]:
            # fnOS 网关已登录会注入 X-Trim-Userid，且来源是本机回环
            if self.headers.get("X-Trim-Userid"):
                return True
            return True
        hdr = self.headers.get("Authorization", "")
        if not hdr.startswith("Basic "):
            return False
        try:
            user, _, pwd = base64.b64decode(hdr[6:]).decode("utf-8").partition(":")
        except Exception:  # noqa: BLE001
            return False
        return user == AUTH[0] and pwd == AUTH[1]

    def _strip_prefix(self, path):
        m = re.match(r"^/app/[^/]+(/.*)?$", path)
        if m:
            return m.group(1) or "/"
        return path

    def _same_origin(self):
        origin = self.headers.get("Origin")
        if not origin:
            return True  # curl / 同源表单都不带
        host = self.headers.get("Host", "")
        return origin.split("://")[-1] == host

    # ---------- 路由 ----------

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self._strip_prefix(self.path.split("?")[0])
        if not self._authorized():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="cfdash"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if path in ("/", "/index.html"):
            try:
                html = (HERE / "index.html").read_bytes()
            except OSError:
                self._send(500, "index.html 缺失", "text/plain; charset=utf-8")
                return
            self._send(200, html, "text/html; charset=utf-8")
            return

        if path == "/api/state":
            try:
                snap = snapshot(force=self.headers.get("X-Force") == "1")
            except Exception as e:  # noqa: BLE001
                self._json({"error": type(e).__name__, "message": str(e)}, 500)
                return
            self._json(snap, etag=True)
            return

        if path == "/api/ping":
            self._json({"ok": True, "version": VERSION, "now": int(time.time())})
            return

        self._send(404, "not found", "text/plain; charset=utf-8")

    def do_POST(self):
        path = self._strip_prefix(self.path.split("?")[0])
        if not self._authorized():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="cfdash"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not self._same_origin():
            self._json({"ok": False, "error": "跨站请求被拒绝"}, 403)
            return

        length = int(self.headers.get("Content-Length") or 0)
        body = {}
        if length:
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except Exception:  # noqa: BLE001
                body = {}

        if path == "/api/run":
            if not RUN_ALLOWED:
                self._json({"ok": False, "error": "面板以 --no-run 启动，禁止触发检测"}, 403)
                return
            res = run_once(dry=bool(body.get("dry")))
            self._json(res, 200 if res.get("ok") else 200)
            return

        if path == "/api/refresh":
            snapshot(force=True)
            self._json({"ok": True})
            return

        self._send(404, "not found", "text/plain; charset=utf-8")


class UnixHTTPServer_:
    pass


_UnixBase = getattr(socketserver, "ThreadingUnixStreamServer", None)

if _UnixBase is not None:
    class UnixHTTPServer(_UnixBase):
        """Unix Domain Socket 上的 HTTP（fnOS 统一网关用）。"""

        daemon_threads = True

        def __init__(self, sock_path, handler):
            self.sock_path = sock_path
            parent = os.path.dirname(os.path.abspath(sock_path))
            if parent:
                os.makedirs(parent, exist_ok=True)
            try:
                if os.path.exists(sock_path):
                    os.unlink(sock_path)
            except OSError:
                pass
            super().__init__(sock_path, handler)
            try:
                os.chmod(sock_path, 0o660)
            except OSError:
                pass

        def get_request(self):
            req, _ = super().get_request()
            return req, ("127.0.0.1", 0)
else:  # Windows 上跑 --mode 远端不适用，但要能 import
    UnixHTTPServer = None


def main(argv=None):
    global RUN_ALLOWED, AUTH
    ap = argparse.ArgumentParser(description="cf-failover 监控面板")
    ap.add_argument("--port", type=int, default=8077)
    ap.add_argument("--bind", default="127.0.0.1", help="监听地址，默认只本机")
    ap.add_argument("--sock", default="", help="改成监听 Unix socket（fnOS 网关）")
    ap.add_argument("--auth", default="", help="user:pass，开启 Basic 认证")
    ap.add_argument("--no-run", action="store_true", help="禁止页面触发检测")
    ap.add_argument("--config", default="", help="指定 cf-failover 配置文件")
    ap.add_argument("--log", default="", help="指定日志文件")
    ap.add_argument("--version", action="version", version="cfdash " + VERSION)
    args = ap.parse_args(argv)

    RUN_ALLOWED = not args.no_run
    if args.auth:
        if ":" not in args.auth:
            ap.error("--auth 需要 user:pass 形式")
        AUTH = tuple(args.auth.split(":", 1))
    if args.config:
        os.environ["CFDNS_CONFIG"] = args.config
    if args.log:
        os.environ["CFDNS_LOG"] = args.log
    PATHS.reload()

    listeners = []
    if args.sock:
        if UnixHTTPServer is None:
            sys.exit("当前平台不支持 Unix socket")
        usrv = UnixHTTPServer(args.sock, Handler)
        listeners.append(usrv)
        sys.stderr.write("cfdash %s listening on unix:%s\n" % (VERSION, args.sock))
    else:
        srv = ThreadingHTTPServer((args.bind, args.port), Handler)
        srv.daemon_threads = True
        listeners.append(srv)
        sys.stderr.write("cfdash %s listening on http://%s:%d\n" % (VERSION, args.bind, args.port))

    threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in listeners]
    for t in threads:
        t.start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
