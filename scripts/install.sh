#!/usr/bin/env bash
#
# 一键安装 base 知识库定时同步任务（macOS + Linux 通用）
#
# 用法: ./install.sh [间隔分钟，默认 15]
#       间隔需为 1-59 的分钟数，或 60 的整数倍（60/120/240...）
#
set -u

INTERVAL_MIN="${1:-15}"
case "$INTERVAL_MIN" in
  ''|*[!0-9]*) echo "用法: $0 [间隔分钟(正整数)]"; exit 1 ;;
esac
if [ "$INTERVAL_MIN" -ge 60 ] && [ $((INTERVAL_MIN % 60)) -ne 0 ]; then
  echo "错误: 大于 60 分钟的间隔需为 60 的整数倍（如 60/120/240），或改用 1-59 分钟"; exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$REPO_DIR/scripts/sync.sh"
chmod +x "$SYNC"

OS="$(uname -s)"
echo "==> 仓库: $REPO_DIR"
echo "==> 平台: $OS | 间隔: 每 $INTERVAL_MIN 分钟"

if [ "$OS" = "Darwin" ]; then
  # ---------------- macOS: launchd ----------------
  PLIST="$HOME/Library/LaunchAgents/com.mypotota.base.sync.plist"
  mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs/base-sync"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.mypotota.base.sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SYNC</string>
    </array>
    <key>StartInterval</key><integer>$((INTERVAL_MIN * 60))</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/base-sync/launchd.out</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/base-sync/launchd.err</string>
</dict>
</plist>
EOF
  launchctl unload "$PLIST" >/dev/null 2>&1   # 重复安装时先卸载旧任务
  if launchctl load "$PLIST"; then
    echo "==> 已安装并启动 launchd 任务: $PLIST"
  else
    echo "==> launchctl load 失败，请检查 $PLIST"; exit 1
  fi

elif [ "$OS" = "Linux" ]; then
  # ---------------- Linux: 优先 systemd timer，回退 crontab ----------------
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/base-sync.service" <<EOF
[Unit]
Description=base 知识库自动同步

[Service]
Type=oneshot
ExecStart=$SYNC
EOF
    cat > "$UNIT_DIR/base-sync.timer" <<EOF
[Unit]
Description=base 知识库定时同步（每 $INTERVAL_MIN 分钟）

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL_MIN}min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload
    if systemctl --user enable --now base-sync.timer; then
      echo "==> 已安装并启动 systemd 用户定时器: base-sync.timer"
    else
      echo "==> systemd 安装失败，请手动检查: systemctl --user status base-sync.timer"; exit 1
    fi
  else
    # 无 systemd 用户会话（容器/WSL/精简系统等），回退 crontab
    if [ "$INTERVAL_MIN" -lt 60 ]; then
      CRON_SCHEDULE="*/$INTERVAL_MIN * * * *"
    else
      CRON_SCHEDULE="0 */$((INTERVAL_MIN / 60)) * * *"
    fi
    ( crontab -l 2>/dev/null | sed '/# BEGIN base-sync/,/# END base-sync/d'
      echo "# BEGIN base-sync (auto generated)"
      echo "$CRON_SCHEDULE $SYNC >/dev/null 2>&1"
      echo "# END base-sync"
    ) | crontab -
    echo "==> 已安装 crontab 定时任务: $CRON_SCHEDULE"
  fi

else
  echo "错误: 不支持的平台 $OS"; exit 1
fi

echo
if [ "$OS" = "Darwin" ]; then
  echo "日志: ~/Library/Logs/base-sync/sync.log"
else
  echo "日志: ~/.local/state/base-sync/sync.log"
fi
echo "可先演练一次: $SYNC --dry-run"
