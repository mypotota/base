# SkyDroid Android 8.1 历史故障与实机反馈

本文记录移植操作中已经复现的历史故障，以及接下来接收实机反馈的入口。新反馈到达前，以下待验证项只表示验证范围。构建、刷写和回退步骤见[移植记录](skydroid-android-8.1-port.md)。

## 已复现的启动故障

| 现象与证据 | 原因与处理 | 验证结果 |
|---|---|---|
| Fastboot 写入成功，ADB 报 8.1.0，但没有 `sys.boot_completed`。内核日志报 `class requires 1 argument`，`logd` 反复退出 | 原厂 7.1.2 的 `init` 不接受 Oreo 的多 class 声明和部分 socket、file 语法。设备目标通过 `legacy-init.mk` 改写核心服务配置 | `logd` 正常运行，能够读取应用层启动日志 |
| `servicemanager` 报找不到服务上下文并退出，`hwservicemanager` 无法取得 SELinux 类型 | 混合 ramdisk 加入 Oreo 的 SELinux 策略及 platform/non-platform 上下文，并保留原厂 `init` | 两个服务均运行。当前是 `Permissive` 开发配置 |
| `SurfaceFlinger` 报 `libion.so` 缺失，随后报 `gralloc-mapper must be in passthrough mode` | 从原厂镜像导入 32 位和 64 位 `libion.so`，加入 Oreo graphics mapper 和 allocator，适配 allocator 服务的 class | `SurfaceFlinger` 稳定运行，窗口服务成功注册 |
| `system_server` 报 `PMS compiler filter settings are bad`，`inactive` 和 `shared` 值为空 | 原厂 ramdisk 的默认属性缺少 Oreo 的 dexopt 配置。在混合 ramdisk 合并 AOSP 8.1 的 `pm.dexopt.*` | 包管理扫描完成，窗口和输入服务启动 |
| `AudioPolicyService not published`，`audioserver` 找不到 `IDevicesFactory` | 加入 audio 和 audio effect 的 HIDL 适配器及服务，按原厂 init 的 class 启动 | `media.audio_flinger` 注册 |
| KeyStore 未注册。随后能到达首次配置，但 Gatekeeper 装载失败，框架在 `reportDeviceSetupComplete()` 触发空指针 | 加入 Keymaster 与 Gatekeeper 的实现和服务，并导入原厂 `libteec` 及 `gatekeeper.banks.so`。通过 `ro.hardware.gatekeeper=banks` 选择设备模块 | Keystore 和 Gatekeeper 注册，首次配置完成，实机普通重启报告 `sys.boot_completed=1` |

## 已复现的黑屏与掉帧

曾观察到三种现象。第一种是系统进入正常休眠，`dumpsys power` 明确显示 `Display Power: state=OFF`。设备的息屏设置从 60 秒调整为 10 分钟，并启用了 USB 供电时保持亮屏。

第二种是在亮屏期间，SurfaceFlinger 日志反复出现 `Timed out waiting for hw vsync`。初版尝试强制软件 VSync，但启用线程后仍有超时。最终保留硬件事件路径，在 `frameworks/native/services/surfaceflinger/EventThread.cpp` 给这个设备目标启用 `debug.sf.short_vsync_fallback=1`，令回退等待从约 1 秒缩短到约 16 毫秒。该改动改善的是缺失硬件事件时的调度，尚未定位硬件 VSync 本身为什么丢失。

第三种是锁屏切换时 SystemUI 反复崩溃。`PanelView.notifyBarPanelExpansionChanged()` 在 `mBar` 还未绑定时调用了 `panelExpansionChanged()`。在 `frameworks/base/packages/SystemUI` 增加空引用检查，并重编、部署 SystemUI 和 SurfaceFlinger 后重新开机验证。

| 设置应用滑动实测 | 修复前 | 修复后 |
|---|---:|---:|
| 样本帧数 | 15 | 290 |
| 卡顿帧 | 14（93.3%） | 7（2.4%） |
| 帧耗时中位数 | 25 ms | 5 ms |

这两组数据来自同一套滑动操作，设置页画面与样本量存在差异，适合判断本轮卡顿是否改善。连续三次熄屏和唤醒均恢复到亮屏，ADB 截图存在正常画面，复测日志未再出现原 VSync 超时和同一条 SystemUI 空指针。物理屏幕的长期表现仍待实测。

## 当前开放项

- **蓝牙**。HAL 服务已加入，但 HCI 初始化曾失败。为避免蓝牙进程反复崩溃，当前关闭蓝牙。
- **原厂遥控服务**。最近的 ADB 复查中 `rc_service` 仍在重启。按键、旋钮、遥控输出和接收端链路需分别验证。
- **显示长期稳定性**。继续验证实体屏幕、断开 USB 后的休眠与唤醒、锁屏多次切换和长时间运行。
- **SELinux 策略**。当前使用 `Permissive` 验证移植。后续需要补齐设备策略，再验证 enforcing 下各服务能否启动和工作。

## 新反馈登记

后续每个问题单独记录 **现象、复现步骤、预期结果、实际结果、发生时的设备状态、对应日志、处理结果与复测范围**。偶发黑屏时尤其要区分实物面板是否熄灭、ADB 截图是否同时黑屏，以及黑屏前有没有锁屏、旋钮操作或拔掉 USB。

### 熄屏后背光仍亮

[查看分步修复计划](backlight-sleep-fix-plan.md)。

ADB 发送 `KEYCODE_SLEEP` 后，`dumpsys power` 显示 `Display Power: state=OFF`，HWC 也报告显示已关闭。与此同时，`/sys/class/backlight/lcd-backlight/actual_brightness` 在唤醒、熄屏和再次唤醒时均为 `500`。

Oreo 的 LightsService 查找 `android.hardware.light@2.0::ILight`。系统中有原厂 `lights.song.so`，该模块包含访问 LCD 背光 sysfs 的代码，但当前镜像没有对应的 HIDL 服务，`lshal` 中也没有 ILight。优先验证 AOSP light 2.0 适配器能否加载原厂模块，并检查服务运行账户的 sysfs 写权限。修复后的验收条件是熄屏时实际亮度归零、唤醒后恢复亮度，以及设置中的亮度滑块能够调节背光。

```bash
adb shell getprop sys.boot_completed
adb shell dumpsys power
adb shell dumpsys display
adb shell dumpsys SurfaceFlinger
adb logcat -b crash -d
```

原始日志和镜像留在本机设备工作目录。文档记录可复现的结论和必要的日志片段。

### 设置铃声无声

实机可听到直接生成的 PCM 测试音，RT5665 播放通道同时处于 `RUNNING`。试听 Ogg 铃声时，播放器打不开 Vorbis 解码器。已核实 OMX 服务和软件解码库存在，镜像缺少媒体编解码配置。复现、配置与回退见[设置铃声无声修复指南](audio-vorbis-fix-guide.md)。
