#!/usr/bin/env bash
#
# cf-failover uninstaller
#
# Removes the binary, cron/timer and logrotate rule. The config file and the
# log are kept unless --purge is given, so an accidental run is harmless.
#
# Copyright (c) 2026 JhonLinus
# SPDX-License-Identifier: MIT
#
set -uo pipefail

readonly PROG="cf-failover"
readonly BIN="/usr/local/bin/${PROG}"
readonly CONF_DIR="/etc/cf-failover"
readonly LOGROTATE_FILE="/etc/logrotate.d/cf-failover"

PURGE=0

c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_rst=$'\033[0m'
[[ -t 1 ]] || { c_grn=""; c_yel=""; c_rst=""; }

info() { printf '%s==>%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s!!%s  %s\n' "$c_yel" "$c_rst" "$*"; }

while (( $# )); do
  case "$1" in
    --purge) PURGE=1; shift ;;
    -h|--help)
      cat <<EOF
${PROG} uninstaller

Usage: sudo ./uninstall.sh [--purge]

  --purge   Also delete ${CONF_DIR} and /var/log/cf-failover.log
EOF
      exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  printf '请用 root 运行：sudo ./uninstall.sh\n' >&2
  exit 1
fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files 2>/dev/null | grep -q '^cf-failover.timer'; then
    info "停止并禁用 systemd timer"
    systemctl disable --now cf-failover.timer 2>/dev/null || true
    rm -f /etc/systemd/system/cf-failover.timer \
          /etc/systemd/system/cf-failover.service
    systemctl daemon-reload 2>/dev/null || true
  fi
fi

if command -v crontab >/dev/null 2>&1; then
  if crontab -l 2>/dev/null | grep -q "$PROG"; then
    info "移除 cron 任务"
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "$PROG" > "$tmp" || true
    crontab "$tmp"
    rm -f "$tmp"
  fi
fi

if [[ -f "$LOGROTATE_FILE" ]]; then
  info "移除 logrotate 规则"
  rm -f "$LOGROTATE_FILE"
fi

if [[ -f "$BIN" ]]; then
  info "移除可执行文件"
  rm -f "$BIN"
fi

if (( PURGE )); then
  info "清除配置与日志"
  rm -rf "$CONF_DIR"
  rm -f /var/log/cf-failover.log /var/log/cf-failover.log.1
  rm -rf /var/tmp/cf-failover
else
  warn "配置与日志已保留"
  printf '    配置：%s\n' "$CONF_DIR"
  printf '    日志：/var/log/cf-failover.log\n'
  printf '    完全清除：sudo ./uninstall.sh --purge\n'
fi

printf '完成\n'
