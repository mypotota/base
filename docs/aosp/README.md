# AOSP 学习路线 · App 开发者的底层进阶

> ⚠️ **系列状态（2026-11-17）**：AOSP 10 源码树已删除，本机现用 AOSP 8.1（见
> [docs/aosp8](../aosp8/README.md) 与笔记《AOSP-8.1.0_r1-Ubuntu26.04-编译记录》）。
> 本系列方法论（进程地图 / 日志探针 / 调用栈调试）仍然有效，版本相关细节注意差异；
> 其中 `env_aosp.sh` 等环境脚本已随旧源码树移除。

> 原（历史）环境：AOSP 10（android-10.0.0_r47）· 目标机型 `aosp_x86_64-eng`（已全量编译通过）
> 源码：`~/aosp` · 机器：16 核 / 22G 内存 / Ubuntu 26.04 · 一键环境脚本：`~/aosp/env_aosp.sh`
> 创建：2026-11-15

## 0. 核心理念（先读这个）

1. **不通读源码。** framework 有上百万行，Google 内部也没人全懂。永远带着一个具体问题进去，用工具定位到相关的那几十行，看完就走。
2. **一切以实验为准。** 改代码 → 增量编译 → 跑起来 → 亲眼看到，比看十篇博客都可靠。
3. **优先复用 App 开发技能。** logcat、断点调试、dumpsys——这些你早就会了，只是换了调试对象。

技能迁移对照表：

| 已经会的（App 侧） | 直接迁移到（Framework 侧） |
|---|---|
| Android Studio 断点调试 | attach 到 `system_process`，断点 AMS |
| `adb logcat` | 源码里的 `Slog.d` 全靠它看 |
| Layout Inspector | `dumpsys activity` / `dumpsys window` |
| AIDL 写跨进程接口 | Binder——framework 一切跨进程的底层 |
| `getSystemService()` | system_server 里成百上千个系统服务 |

唯一需要新补的一块前置知识：**你的 app 和 system_server 是两个进程，`getSystemService()` 返回的是"遥控器"（Binder 代理对象），每次调用都是一次跨进程通信。** 理解这一句，framework 一半的设计就说得通了。

## 1. 总路线

| 阶段 | 目标 | 状态 |
|---|---|---|
| 阶段零 | 环境：repo sync + 全量编译 aosp_x86_64-eng | ✅ 2026-11-12 |
| **阶段一** | **破冰：把 framework 变成"可实验的普通项目"** | 🔄 进行中 |
| 阶段二 | 经典实战：添加自己的系统服务（AIDL → SystemService → @SystemApi → app 调用） | ⬜ |
| 阶段三 | 选方向深入：SystemUI/WMS · native（art/bionic）· kernel | ⬜ |

## 2. 阶段一章节（当前）

每章结构：**目标 → 步骤 → 验收标准 → 常见坑**。
学完一章：在本目录新建 `chNN-标题.md` 沉淀笔记，并在下方进度表打勾。

### 第 0 章 · 跑起来：模拟器与开发闭环（约 30 分钟）

- **目标**：用自己编译的镜像启动模拟器，掌握"重启 framework 不重启模拟器"的快捷技巧。
- **步骤**：
  1. `source ~/aosp/env_aosp.sh` —— 内部做了：设置 ccache → `source build/envsetup.sh` → `lunch aosp_x86_64-eng`
  2. `emulator -writable-system -no-snapshot -gpu swiftshader_indirect` 启动（首次约 2~5 分钟）。**`-writable-system` 必加**：默认 system 分区只读，不加它后面 `adb remount` 必失败
  3. 验证：`adb devices` 看到 device；`adb root` 返回 `adbd restarted as root`（eng 版特权）
  4. 快捷键（本章最重要的技巧）：
     - 重启整个 framework（不用重启模拟器，约 30 秒）：`adb shell stop && adb shell start`
     - 重启单个 app：`adb shell am force-stop com.android.settings`
- **验收**：模拟器开机、`adb root` 成功、体验一次 `stop && start`。
- **常见坑**：新开终端必须重新 `source ~/aosp/env_aosp.sh`，否则 `m`/`emulator`/`lunch` 都找不到。

### 第 1 章 · 观察系统：建立进程地图（约 1 小时）

- **目标**：不碰源码，只用命令回答：手机里有哪些关键进程？系统服务长什么样？
- **步骤**：
  1. `adb shell ps -A | grep -E "zygote|system|servicemanager"` —— 认识 zygote（所有 app 的母体）、system_server（几乎所有系统服务所在进程）、servicemanager（服务目录簿）
  2. `adb shell service list` —— app 里 `getSystemService()` 能拿到的服务全在这张表里
  3. `adb shell dumpsys activity activities` —— AMS 眼中的 Activity 任务栈
  4. `adb shell dumpsys activity top` —— 当前界面 Activity 的内部结构
  5. 随手玩：`dumpsys window windows | grep -E "mFocus|mCurrentFocus"`
- **验收**：能手画一张进程地图（zygote / system_server / servicemanager / 若干 app 进程），并说出打开一个 app 时哪些进程参与。
- **常见坑**：dumpsys 输出很长，配合 `| grep` 或重定向到文件慢慢看；这不是背参数，是找"地感"。

### 第 2 章 · 第一个改动：让 Settings 变成"我改的"（约 1 小时）

- **目标**：打通"改源码 → 单模块增量编译 → 部署到模拟器"完整闭环。
- **步骤**：
  1. 先查主页布局 `~/aosp/packages/apps/Settings/res/xml/top_level_settings.xml`，确认"显示"条目引用的是 `@string/display_settings`（注意：Settings 在 `packages/apps/`，不在 frameworks 里！）
  2. 编辑 `~/aosp/packages/apps/Settings/res/values-zh-rCN/strings.xml` 和 `res/values/strings.xml`，把 `display_settings` 改成"显示 · 我改的"
  3. 编译：`m Settings`（单模块增量，几分钟）
  4. 部署：`adb remount && adb sync system`（Settings 是 priv-app，用 sync 而不是 install；需模拟器以 `-writable-system` 启动）
  5. `am force-stop com.android.settings` 后重开设置看效果
- **验收**：模拟器设置界面里亲眼看到自己改的文字。
- **常见坑**：① 改错 key（`display_settings_title` 是二级页标题，主页条目用的是 `display_settings`——先查布局引用再动手）；② remount 失败=模拟器没带 `-writable-system` 启动；③ `adb sync` 报缺 `ANDROID_PRODUCT_OUT` = 忘了 lunch。

### 第 3 章 · 日志实验：看见 ATMS 跳动（约 1~2 小时）

- **目标**：在 ActivityTaskManagerService 里加一行 Slog 探针，亲眼看到"点一下"背后的跨进程调用。
- **步骤**：
  1. 编辑 `~/aosp/frameworks/base/services/core/java/com/android/server/wm/ActivityTaskManagerService.java`（注意是 **wm 包的 ATMS**，Android 10 已把启动链路从 AMS 分家到这里），在 `startActivity` 开头加：`Slog.d("MYTAG", "ATMS.startActivity: from uid=" + Binder.getCallingUid() + " pid=" + Binder.getCallingPid() + " intent=" + intent);`
  2. 编译：`m services`（实测约 2 分钟）
  3. 生效：`adb remount && adb sync system && adb shell stop && adb shell start`
  4. 观察：`adb logcat -c && adb logcat -s MYTAG`，然后**用 `input tap` 真实点击**界面条目
- **验收**：logcat 里出现自己的 tag，且日志里 `getCallingPid` ≠ system_server 的 pid（跨进程铁证）。
- **学到**：Android 10 AMS/ATMS 分家；`am start` 与真实点击走不同入口；Slog vs Log。
- **常见坑**：① `am start` 触发不了这个探针（它直调 startActivityAsUser，见 ActivityManagerShellCommand.java:518），必须真实点击；② 忘 source 环境脚本导致 sync 报错。

### 第 4 章 · 断点调试：让调用栈说话（约 2 小时）

- **目标**：把最熟悉的技能迁移过来——断点 framework 代码，拿一张免费的完整调用栈。
- **步骤（先做安全版）**：
  1. Android Studio 随便建一个空 app 工程，装进模拟器
  2. `Run → View Breakpoints → + → Java Method Breakpoint`，类 `android.app.ActivityThread`，方法 `handleLaunchActivity`
  3. 正常点 Run 调试启动 app → 断点命中 → **看调用栈面板**：这就是"点击图标之后发生了什么"的官方答案
  4. Step Over/Into 随意走走看
- **进阶（勇者版）**：`Attach Debugger to Android Process` 勾选显示所有进程 → 选 `system_process` → 给 `ActivityManagerService.startActivity` 打方法断点。⚠️ 断点会冻结整个系统（连 home 键都没反应），看完立刻 Resume，别停太久（system_server 有 Watchdog，冻结过久会自杀重启）。
- **验收**：保存一张完整的调用栈截图/文本（放进 ch04 笔记）。
- **常见坑**：AS 的 SDK 要下到 API 29 才能优雅显示源码；方法断点比行断点慢，耐心点。

### 第 5 章 · Binder 初体验：遥控器哲学（约 2 小时）

- **目标**：亲眼验证"跨进程"：app 进程发起调用，system_server 进程里命中。
- **步骤**：
  1. 在第 4 章那个空 app 里加个按钮：`getSystemService(AlarmManager::class.java).set(...)`
  2. system_process 侧给 `AlarmManagerService.set` 打方法断点
  3. 点按钮 → 断点命中 → 在调试器里求值 `Binder.getCallingUid()` / `getCallingPid()`：**和 system_server 自己的 uid/pid 不一样，正是你的 app**
  4. 对照 `adb shell dumpsys alarm`，找到自己的包名
- **验收**：能用自己的话回答："为什么说 `getSystemService()` 返回的是遥控器？一次调用中两个进程各自做了什么？"
- **学到**：Binder 代理、`Binder.getCallingPid/Uid`——framework 权限检查的地基。

### 第 6 章 · 链路走读：点击图标之后发生了什么（约 1 周，反复消化）

- **目标**：带着第 4/5 章拿到的调用栈，正式精读一次 startActivity 链路。此时源码对你已不是天书。
- **文件清单（Android 10 路径，按调用顺序）**：
  1. `frameworks/base/core/java/android/app/Instrumentation.java` → `execStartActivity`（app 进程侧的出口）
  2. `ActivityManager.getService().startActivity(...)`（Binder 代理，跨进程的分界线）
  3. `frameworks/base/services/core/java/com/android/server/am/ActivityStarter.java`（system_server 侧入口，权限/Intent 解析）
  4. `.../am/ActivityStackSupervisor.java` + `ActivityStack.java`（暂停上一个 app、找目标栈）
  5. `frameworks/base/core/java/android/app/ActivityThread.java` → `scheduleTransaction`（又跨回 app 进程，创建 Activity）
- **方法**：每读一个文件，先回头看调试器调用栈里它的位置；只追主干，忽略错误处理分支。
- **验收**：合上资料，自己画出一张简化时序图（app 进程 / system_server 两条竖线，箭头表示 Binder 调用），存进 ch06 笔记。
- **参考**：《Android 进阶解密》第 10 章（基于 Android 9/10，与手头版本对得上）。

## 3. 进度跟踪

| 章节 | 状态 | 完成日期 | 笔记 |
|---|---|---|---|
| ch00 跑起来：模拟器与开发闭环 | ✅ | 2026-11-15 | [ch00-跑起来.md](ch00-跑起来.md) |
| ch01 观察系统：进程地图 | ✅ | 2026-11-15 | [ch01-进程地图.md](ch01-进程地图.md) |
| ch02 第一个改动：Settings | ✅ | 2026-11-15 | [ch02-第一个改动.md](ch02-第一个改动.md) |
| ch03 日志实验：ATMS 跳动 | ✅ | 2026-11-15 | [ch03-日志实验.md](ch03-日志实验.md) |
| ch04 断点调试：调用栈 | ✅ | 2026-11-16 | [ch04-调用栈.md](ch04-调用栈.md)（日志栈版；jdb 断点在本环境不可用，排查记录在笔记） |
| ch05 Binder 初体验 | ⬜ | | |
| ch06 startActivity 链路走读 | ⬜ | | |

## 4. 常用命令速查

```bash
source ~/aosp/env_aosp.sh              # 每个新终端第一句
emulator -writable-system -no-snapshot -gpu swiftshader_indirect  # 用 out/ 镜像启动（-writable-system 必加，否则不能改 system 分区）
adb root && adb remount && adb sync    # 部署 system 分区改动
adb shell stop && adb shell start      # 重启 framework（约 30 秒）
m Settings                             # 单模块增量编译
m services                             # 编译 AMS 所在的 services.jar
adb logcat -s MYTAG                    # 只看自己的日志
adb shell ps -A | grep system          # 看关键进程
adb shell service list                 # 所有 Binder 服务
dumpsys activity activities            # AMS 的 Activity 栈
```

## 5. 参考资料

- 《Android 进阶解密》刘望舒 —— 基于 Android 9/10，与手头源码版本匹配，首选
- Gityuan 博客（gityuan.com）—— 基于 Android 6/7，原理相通，图极佳
- 官方 source.android.com —— Building / AIDL / System API 文档
- cs.android.com —— 在线浏览最新版代码，用于对比
