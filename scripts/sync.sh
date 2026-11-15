#!/usr/bin/env bash
#
# base 知识库自动同步脚本（macOS + Linux 通用，兼容 bash 3.2）
#
# 每次执行完成一个完整周期：
#   fetch 远端 → 提交本地改动 → rebase 到远端最新 → push
#
# 用法:
#   ./sync.sh             正常执行一次同步
#   ./sync.sh --dry-run   演练模式：只打印将要执行的动作，不修改任何东西
#
set -u
# 在终端手动运行时允许 git 弹出登录提示（首次认证用）；
# 定时任务中无终端，则快速失败避免挂起
if [ -t 0 ]; then export GIT_TERMINAL_PROMPT=1; else export GIT_TERMINAL_PROMPT=0; fi

DRY_RUN=0
case "${1:-}" in
  --dry-run|-n) DRY_RUN=1 ;;
esac

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ---------------------------------------------------------------- 日志 --
case "$(uname -s)" in
  Darwin) LOG_DIR="$HOME/Library/Logs/base-sync" ;;
  *)      LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/base-sync" ;;
esac
mkdir -p "$LOG_DIR" 2>/dev/null
LOG_FILE="$LOG_DIR/sync.log"

log() { # log <级别> <内容>
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
  echo "$line"
  [ -w "$LOG_DIR" ] && echo "$line" >> "$LOG_FILE"
}

run() { # run <描述> <命令...> —— 演练模式只打印，不执行
  local desc="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then
    log DRY  "[演练] $desc —— 跳过: $*"
    return 0
  fi
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  [ -n "$out" ] && echo "$out" >> "$LOG_FILE"
  if [ "$rc" -eq 0 ]; then log OK "$desc"
  else log FAIL "$desc 失败（详情见 $LOG_FILE）"; fi
  return $rc
}

# ---------------------------------------------------------------- 文件锁 --
# mkdir 是原子操作，macOS / Linux 通用；超过 1 小时视为残留并自动清理
LOCK_DIR="$REPO_DIR/.sync-lock"
acquire_lock() {
  while :; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
      date +%s > "$LOCK_DIR/ts"
      return 0
    fi
    local created now
    created="$(cat "$LOCK_DIR/ts" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if [ $((now - created)) -gt 3600 ]; then
      log WARN "发现超过 1 小时的残留锁，自动清理"
      rm -rf "$LOCK_DIR"
      continue
    fi
    return 1
  done
}

# ---------------------------------------------------------------- 主流程 --
main() {
  cd "$REPO_DIR" || exit 1

  # --- 环境检查（只读操作，演练模式同样执行） ---
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log FAIL "$REPO_DIR 不是 git 仓库"; exit 1
  fi
  if ! git remote get-url origin >/dev/null 2>&1; then
    log FAIL "未配置 origin 远程仓库"; exit 1
  fi
  local BRANCH
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$BRANCH" = "HEAD" ]; then
    log FAIL "当前处于分离 HEAD 状态，请先切回分支"; exit 1
  fi

  # 自动提交需要身份；缺失时只给本仓库设置兜底身份，不动全局配置
  if [ -z "$(git config user.email)" ]; then
    log WARN "未配置 git user.email，为本仓库设置自动同步专用身份"
    if [ "$DRY_RUN" -eq 0 ]; then
      git config user.name  "base-sync"
      git config user.email "base-sync@localhost"
    fi
  fi

  local changed
  changed="$(git status --porcelain | wc -l | tr -d ' ')"
  log INFO "开始同步: 分支=$BRANCH 本地改动=$changed 个文件$([ "$DRY_RUN" -eq 1 ] && echo '（演练模式）')"

  # 1. 拉取远端
  run "拉取远端 (fetch origin)" git fetch origin || exit 1

  # 2. 提交本地改动
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$changed" -gt 0 ]; then
      log DRY  "[演练] 将提交 $changed 个本地改动"
    else
      log INFO "本地无改动，跳过提交"
    fi
  else
    git add -A
    if ! git diff --cached --quiet; then
      run "提交本地改动" git commit -m "auto-sync: $(date '+%Y-%m-%d %H:%M') ($changed files)" || exit 1
    else
      log INFO "本地无改动，跳过提交"
    fi
  fi

  # 3. rebase 到远端最新（失败则安全中止，绝不丢数据）
  if ! run "变基到 origin/$BRANCH" git rebase --autostash "origin/$BRANCH"; then
    git rebase --abort >/dev/null 2>&1
    log FAIL "与远端冲突，已安全中止。请手动执行 git pull --rebase 解决，之后自动同步即恢复"
    exit 1
  fi

  # 4. 推送
  run "推送到 origin/$BRANCH" git push origin "HEAD:$BRANCH" || exit 1

  log INFO "同步完成"
}

if ! acquire_lock; then
  log WARN "已有同步任务在运行，本次跳过"
  exit 0
fi
main
