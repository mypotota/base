# AOSP 8.1.0_r1 在 Ubuntu 26.04 上的完整编译记录

> 日期：2026-11-17
> 机器：Lenovo Legion R7000 2020（Ryzen 7 4800H，16 逻辑核 / 22GB RAM / 23GB Swap / NVMe 468GB）
> 系统：Ubuntu 26.04.1 LTS，内核 7.0.0-43-generic，glibc 2.43
> 目标：`aosp_x86_64-eng`，编译通过并启动模拟器

## 一、迁移背景

原环境为 AOSP 10（QP1A，`~/aosp`，共 211GB：out 99G + .repo 64G + prebuilts 30G）。
本次按要求**完全删除、不复用任何旧产物**，全新同步 `android-8.1.0_r1`。

### 磁盘与内存盘点（清理前）

- 磁盘：468G，已用 354G，剩 90G（80%）
- 内存：22Gi（常用应用后台占 ~7-11Gi），Swap 23Gi
- 磁盘剩余 90G 不足以同时容纳新源码树（~60G）+ 编译输出（~45G），必须清理

## 二、清理记录

| 项目 | 大小 | 处理 |
|---|---|---|
| AOSP10 源码树 `~/aosp`（含 .repo/out/prebuilts） | 211GB | 整树删除，不复用 |
| rust 工具链 `~/.rustup` + `~/.cargo` | 866MB | 删除 |
| miniconda3 | 1.45GB | 删除 |
| ~/.dotnet | 1MB | 删除 |
| ccache `~/.ccache` | （AOSP10 缓存） | 删除（编译器版本不同命中率为 0） |
| gradle 缓存 `~/.gradle` | 746MB | 删除（App 开发用，可再生成） |
| tracker3 / chrome / nvidia / pip / go-build / tealdeer 缓存 | ~5.3GB | 清除 |
| 系统回收站 | 455MB | 清空 |
| 保留：Android SDK (`~/Android/Sdk`)、Android Studio 3.5.2、git/python3/gcc 15、openjdk-17 | — | 与 AOSP 开发相关或系统必需 |
| 保留：node (`~/tools/node`) | ~100MB | 暂留（桌面工具链依赖，任务收尾时再移除） |

清理后磁盘可用：**约 296G**（待 AOSP10 删除完成）。

## 三、下载源码（android-8.1.0_r1）

googlesource 在本网络不可达，使用清华 TUNA 镜像；`repo init` 时用 `--repo-url` 把 repo 启动器仓库也指向 TUNA。

```bash
mkdir ~/aosp && cd ~/aosp
export REPO_URL="https://mirrors.tuna.tsinghua.edu.cn/git/git-repo"
repo init \
  -u https://mirrors.tuna.tsinghua.edu.cn/git/AOSP/platform/manifest \
  -b android-8.1.0_r1 --depth=1 --repo-url=$REPO_URL --no-repo-verify
repo sync -c -j8   # 失败重跑即可，增量续传
```

**网络实测**：单连接 ~0.5MB/s（阿里云/清华均如此），16 并发聚合 ~4MB/s——瓶颈是本机宽带带宽上限（~32Mbps），换镜像无意义；600 个项目、浅克隆全量约 50GB，预计 3~4 小时。同步脚本 `~/aosp-scripts/sync_aosp8.sh`（8 轮自动重试，-j16）。

manifest 已确认包含（免去在 26.04 上自装旧环境的麻烦）：

- `prebuilts/jdk/jdk8` —— JDK 8 用源码树内置的，不需要系统 openjdk-8
- `prebuilts/python/linux-x86/2.7.5` —— python2 用内置的，规避 26.04 无 python2 包的问题
- `prebuilts/android-emulator` —— 8.1 时代的模拟器二进制，`clone-depth="1"`
- `prebuilts/build-tools`（ckati/ninja/bison/flex）

## 四、编译线程数评估（防 OOM）

**结论：`-j10`，如后台大应用关闭可提到 `-j12`。**

依据：

- AOSP 8.1 单个编译任务（clang 5.0 / gcc 4.9）峰值内存约 1~1.5GB，soong+kati 常驻约 2~3GB
- 22G 内存减去常驻桌面应用（Chrome、微信、网盘、AndroidStudio 等约 7G）≈ 15G 可用
- `-j10` 峰值 ≈ 10×1.2 + 3 ≈ **15G**，与可用内存持平，23G Swap 作为兜底，OOM killer 不会触发
- `-j16` 需要关闭 Chrome/网盘等后台应用才安全；8.1 构建瓶颈也常在磁盘 IO，核数打满收益有限
- 建议：构建期间关闭百度网盘等后台程序；不要手动跑 jack server（见下）

## 五、Ubuntu 26.04 (glibc 2.43) 适配要点

1. python2：26.04 已无 python2 包。方案：将源码树内 `prebuilts/python/linux-x86/2.7.5/bin` 加入 PATH（构建 shell 内局部生效）
2. JDK8：构建系统自动使用 `prebuilts/jdk/jdk8`
3. Jack 编译器：8.1 默认用 Jack，在新内核/新 JVM 环境易出问题且吃内存 → 视编译情况用 `ANDROID_COMPILE_WITH_JACK=false` 走 javac 老路径
4. 旧 prebuilt 二进制对 `libncurses5/libtinfo5` 的依赖：同步后用 `ldd` 审计，缺则本地源码编译 ncurses5 到 ~/.local 免 sudo 解决
5. 官方依赖包（bison/flex/gperf/multilib 等）此前编 AOSP10 时已装齐

## 六、编译错误与修复（持续追加）

1. **ZCode shell 假死：`spawn /bin/bash ENOENT`（2026-11-17）**
   - 现象：删除 `~/aosp`（当时 shell 的 cwd）之后，所有 Bash 调用立刻报 `spawn /bin/bash ENOENT`，子代理同样失败，`/bin/bash` 实际存在
   - 原因：shell 的当前工作目录被删除，exec 前的 chdir 失败，报错文案误导性地指向 bash 本身
   - 修复：用文件工具在 `/home/zhao/aosp` 里写一个占位文件重建目录，shell 立即恢复
   - 教训：不要在 shell 停留在某目录时整树删除它；或者先 `cd ~` 再删
2. **pkill 模式自匹配自杀（2026-11-17）**
   - 现象：后台任务里执行 `pkill -f 'repo sync'` 清理旧进程，整个任务瞬间失败且日志为空
   - 原因：`pkill -f` 匹配的是完整命令行，包裹命令的 `bash -c "… pkill -f 'repo sync' …"` 自身的命令行里就含有该字符串，把自己也杀了
   - 修复：用字符类破坏自匹配，例如 `pkill -f 'repo sy[n]c'`
3. **repo 对 tag 版本 manifest 的 `--tags` 全量抓取灾难（2026-11-17）**
   - 现象：`android-8.1.0_r1` 是 tag 版 manifest，repo 对每个项目执行 `fetch --tags tag android-8.1.0_r1 +refs/tags/*:refs/tags/*`。对 `prebuilts/tools` 这种「每个 tag 都是一个数 GB 快照」的仓库，等于要下几十个 tag 的快照，累计 36GB+ 还远未结束
   - 雪上加霜：TUNA 镜像对大仓库有排队限流（`remote: Waiting in queue... (Position: 74~81)`），且排队期间 0 字节流动，若设了 `GIT_HTTP_LOW_SPEED_TIME` 会把还在排队的会话误杀；被 SIGKILL 的 fetch 每次留下一个 `tmp_pack_*`，我们清理了 9 个残包共 37GB 垃圾
   - 修复方案（绕过）：
     1. 清理 `objects/pack/tmp_pack_*`
     2. 手动单 tag 精准抓取：`cd .repo/projects/prebuilts/tools.git && git fetch --depth=1 aosp 'refs/tags/android-8.1.0_r1:refs/tags/android-8.1.0_r1'`（只下 4~5GB 一个快照，且不设低速断开，耐心排队）
     3. 之后 `repo sync` 检查到 HEAD 已在目标 revision 会跳过该项目
   - 教训：浅克隆 tag 版 AOSP 遇到巨型 prebuilts 仓库时，手动单 ref 抓取是正解；镜像排队期不要设激进的低速断开
4. **TUNA 镜像早高峰节流（2026-11-17 实测）**
   - 02:00~08:00：单连接 0.5~6MB/s；09:00 后大仓库排队 Position 74+，单连接几十 KB/s
   - 应对：大文件抓取尽量安排在中国时区深夜；repo sync 用 `-j8` 平衡排队与吞吐

## 七、模拟器运行

（编译完成后记录）

## 八、复用说明

- 一键构建脚本：`~/aosp/env_aosp8.sh`（编译完成后生成）
- 知识库由 `scripts/sync.sh` 自动提交推送，无需手动 git 操作
