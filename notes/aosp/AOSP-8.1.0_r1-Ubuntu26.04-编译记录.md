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
5. **错误①：Jack 服务器通信失败（2026-11-17 12:21，编译 1 分钟即失败）**
   - 报错：`Communication error with Jack server (2)`、`curl: The file '/home/zhao/.jack-server/server.pem' provided to --cacert does not exist`
   - 根因：8.1 默认启用 Jack 编译器（`ANDROID_COMPILE_WITH_JACK ?= true`；只读 config.mk 后半段分支逻辑会误判为默认关闭），Jack server 首次启动需生成证书，在新系统/新 curl 上初始化失败；Jack 已被 Google 弃用
   - 修复：构建前 `export ANDROID_COMPILE_WITH_JACK=false`，走 javac + proguard 传统路径（aosp_x86_64-eng 产物无差别，社区标准做法）
6. **错误②：python2 脚本撞上系统 python3.14（2026-11-17 12:23）**
   - 报错：`build/tools/merge-event-log-tags.py` 的 `print str(err)` → `SyntaxError: Missing parentheses in call to 'print'`
   - 根因：Ubuntu 26.04 无 python2，`python` 符号链接指向 python 3.14；8.1 的构建脚本（merge-event-log-tags.py 等）全是 py2 语法
   - 修复：用源码树内置的 `prebuilts/python/linux-x86/2.7.5` 做 shim——写 `~/aosp-scripts/shims/{python,python2,python2.7}` 三个小脚本（内设 `PYTHONHOME` 后 exec 内置 python），并 `export PATH=~/aosp-scripts/shims:$PATH`
   - 细节：内置 python2.7.5 跑脚本必须设 `PYTHONHOME` 指向其 prefix，否则 import 全挂；实测其不含 zlib/ssl 模块，但排查后确认 8.1 构建脚本均不 import zlib/ssl，可放心使用（若后续有需要再源码编 python2.7.18）
7. **错误③：预编译 flex-2.5.39 在新 glibc 下崩溃（2026-11-17 12:32）**
   - 报错：编 `libedify`（bootable/recovery）时 `flex-2.5.39: loadlocale.c:130: _nl_intern_locale_data: Assertion 'cnt < (sizeof (_nl_value_type_LC_TIME)…' failed, Aborted (core dumped)`
   - 根因：glibc 2.26 改了 locale 内部数据结构（`_nl_value_type_LC_TIME` 数组变长），旧二进制编译期写入的数组长度检查对新 locale 数据断言失败。所有 glibc≤2.25 时代的 prebuilt 都可能中招
   - 修复：构建环境 `export LC_ALL=C`（C locale 不加载 locale 表，绕开断言）；备选方案是把 prebuilts/misc/linux-x86/flex/flex-2.5.39 换成包装脚本 exec 系统 flex 2.6
8. **错误④：sepolicy_tests 用 ctypes 加载 64 位 so 失败（2026-11-17 13:29，编译 52 分钟后）**
   - 报错：`libsepolwrap.so: wrong ELF class: ELFCLASS64`（OSError from ctypes.CDLL）
   - 根因：`prebuilts/python/linux-x86/2.7.5` 名字里的 `linux-x86` 是 **32 位**（AOSP 命名传统），sepolicy_tests.py（build/make/target/board/Android.mk 的 sepolicy 一致性测试）需要 dlopen 64 位 `libsepolwrap.so`，32 位 python 无法加载
   - 修复：树里 `prebuilts/gdb/linux-x86/bin/python2.7` 是 64 位 python2.7.5（自带 zlib/hashlib/ctypes，实测 dlopen OK），shim 改指向它（`PYTHONHOME=prebuilts/gdb/linux-x86`）
   - 经验：AOSP prebuilts 目录名 `linux-x86` ≠ 64 位；需要 64 位宿主工具时先 `file` 确认
9. **错误⑤：gdb 版 python 的 hashlib 是空壳（2026-11-17 13:36）**
   - 报错：打包 cache.img 时 `build_image.py` → `ERROR:root:code for hash md5 was not found` / `ValueError: unsupported hash type md5`
   - 根因：`prebuilts/gdb/linux-x86/bin/python2.7`（64 位）虽能 `import hashlib`，但编译时裁掉了内置 md5/sha 模块，真正计算哈希时才炸——之前只验证了 import 是不够的
   - 修复：源码自建 python2.7.18 → `~/.local/py27`：
     - zlib 用树内 `external/zlib/src`（TUNA 无 zlib 镜像），`./configure --prefix=~/.local/pyzlib` 后供 python 链接
     - Python-2.7.18.tgz 从 TUNA `mirrors.tuna.tsinghua.edu.cn/python/2.7.18/` 下载
     - **gcc 15 默认 `-std=c23`，撞上 python2 的 `typedef enum {false,true} bool`**（`cannot use keyword 'false' as enumeration constant`）→ configure 时加 `CFLAGS="-O2 -std=gnu89"` 解决
     - 校验必须做真实运算：`hashlib.md5(b'x').hexdigest()` == `9dd4e461268c8034f5c8564e155c67a6`
10. **错误⑥：dex2oatd 缺 ANDROID_DATA（2026-11-17 13:57）**
   - 报错：生成 odex 时 `dex2oatd F ... utils.cc:762] ANDROID_DATA not set and /data does not exist` → Runtime aborting
   - 根因：ART 宿主工具启动时要求 `ANDROID_DATA` 环境变量或宿主机存在 `/data` 目录；Google 内部构建机有 `/data`，普通 Linux 桌面机没有
   - 修复：`mkdir -p ~/aosp-scripts/and-data/data/dalvik-cache && export ANDROID_DATA=~/aosp-scripts/and-data`
11. **错误⑦：host dex2oat 无法按固定基址映射 boot.art（2026-11-17 14:00）**
   - 报错：`image_space.cc Could not create image space ... Failed to mmap at expected address, mapped at 0x7xxx... instead of 0x703e5000` → `Dex file fallback disabled, cannot continue without image` → 所有 odex 任务失败
   - 根因：8.1 的 boot.art 内嵌固定基址约 0x703e5000（老地址布局），新内核/glibc 的 mmap 布局下该区域被占用，MAP_FIXED 失败；dex2oat 不接受 imageless 回退。AOSP 8.x 在新宿主上的著名问题
   - 修复（尝试顺序）：①`setarch -R make -j10`（仅构建进程关 ASLR，恢复老式地址布局）；②若无效则 `export NO_DEXPREOPT=true` 完全跳过 host 端 dex 预优化（eng 版本可接受，首次开机稍慢）

## 七、模拟器运行

（编译完成后记录）

## 八、复用说明

- 一键构建脚本：`~/aosp/env_aosp8.sh`（编译完成后生成）
- 知识库由 `scripts/sync.sh` 自动提交推送，无需手动 git 操作
