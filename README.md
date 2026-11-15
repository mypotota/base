# base · 个人知识库

> mypotota 的个人知识库。笔记、文档、资料统一存放在这里，后台由自动同步脚本定时 **拉取更新 / 提交修改 / 推送到 GitHub**，macOS 与 Linux 通用。

## 目录结构

```
base/
├── notes/          # 日常笔记、随手记、碎片想法
├── docs/           # 整理成文的知识文档（技术总结、学习笔记）
├── resources/      # 收藏的参考资料、代码片段、外部资源
├── scripts/        # 自动同步脚本（配套工具，见下文）
└── README.md       # 本文件
```

目录可按需增删、重命名，同步脚本会自动提交仓库内的所有改动。

## 日常使用

平时只管往 `notes/`、`docs/` 里写东西、存文件，保存即可，无需任何 git 操作——本地改动会被定时自动提交并推送到 GitHub。

不想等定时、想立即同步时：

```bash
./scripts/sync.sh             # 立即执行一次：拉取 → 提交 → 推送
./scripts/sync.sh --dry-run   # 演练模式：只打印动作，不修改任何东西
```

## 自动同步（配套工具，每台机器装一次即可）

### 安装定时任务

```bash
./scripts/install.sh          # 默认每 15 分钟同步一次
./scripts/install.sh 30       # 自定义间隔（分钟）
./scripts/uninstall.sh        # 卸载
```

安装时按平台自动选择定时机制：

| 平台 | 方式 | 产物 |
|------|------|------|
| macOS | launchd | `~/Library/LaunchAgents/com.mypotota.base.sync.plist` |
| Linux（有 systemd） | 用户级 timer | `~/.config/systemd/user/base-sync.{service,timer}` |
| Linux（无 systemd） | crontab | 以 `# BEGIN base-sync` 标记的定时块 |

### 每次同步做什么

1. `fetch` 远端更新
2. 本地如有改动 → 自动全部提交，提交信息形如 `auto-sync: 2026-11-15 17:00 (3 files)`
3. `rebase` 到远端最新（`--autostash` 保护现场，保持历史线性）
4. `push` 到 GitHub

安全特性：

- 全程不使用 `--force`，任何一步失败立即停止，绝不丢数据
- 与远端冲突时自动 `rebase --abort` 并保留本地提交，人工解决后下次自动恢复
- 文件锁防止多实例并发；超过 1 小时的残留锁自动清理
- 凭证缺失时快速失败（`GIT_TERMINAL_PROMPT=0`），定时任务不会挂起等待输入

### 日志

- macOS：`~/Library/Logs/base-sync/sync.log`
- Linux：`~/.local/state/base-sync/sync.log`

## 认证（HTTPS 推送需一次性配置）

```bash
# 方式一：Personal Access Token + 凭证助手（推荐）
git config --global credential.helper store   # macOS 默认 osxkeychain，无需再设
# 下次手动 push 时输入 GitHub 用户名 + PAT，之后自动记住

# 方式二：改用 SSH
git remote set-url origin git@github.com:mypotota/base.git
```

建议把提交邮箱换成 GitHub 账号邮箱（否则提交不计入贡献图）：

```bash
git config user.email "你的GitHub邮箱"
```

## 多设备使用

每台电脑各自 `git clone` 本仓库 + 执行一次 `./scripts/install.sh` 即可。请尽量避开两台设备同时编辑同一文件；若真的冲突，脚本会安全停下，在其中一台手动执行：

```bash
git pull --rebase   # 解决冲突后 git rebase --continue
```

之后自动同步即恢复正常。
