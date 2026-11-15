#!/usr/bin/env bash
#
# 卸载 base 知识库定时同步任务（macOS + Linux 通用）
# 只移除定时任务，不动仓库和脚本本身
#
set -u
OS="$(uname -s)"
removed=0

if [ "$OS" = "Darwin" ]; then
  PLIST="$HOME/Library/LaunchAgents/com.mypotota.base.sync.plist"
  if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" >/dev/null 2>&1
    rm -f "$PLIST"
    echo "==> 已移除 launchd 任务: $PLIST"
    removed=1
  fi
else
  # systemd timer
  UNIT_DIR="$HOME/.config/systemd/user"
  if [ -f "$UNIT_DIR/base-sync.timer" ]; then
    systemctl --user disable --now base-sync.timer >/dev/null 2>&1
    rm -f "$UNIT_DIR/base-sync.timer" "$UNIT_DIR/base-sync.service"
    systemctl --user daemon-reload >/dev/null 2>&1
    echo "==> 已移除 systemd 定时器: base-sync.timer"
    removed=1
  fi
  # crontab
  if crontab -l 2>/dev/null | grep -q '# BEGIN base-sync'; then
    crontab -l 2>/dev/null | sed '/# BEGIN base-sync/,/# END base-sync/d' | crontab -
    echo "==> 已移除 crontab 定时任务"
    removed=1
  fi
fi

if [ "$removed" -eq 0 ]; then
  echo "未发现已安装的定时任务"
else
  echo "卸载完成（仓库与脚本文件未改动）"
fi
