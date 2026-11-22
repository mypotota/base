# 修复设置铃声无声与 Vorbis 播放卡在 0 ms

这台 SkyDroid 的 PCM 测试音能从实体扬声器听到，RT5665 的播放通道同时处于 `RUNNING`。Ogg 铃声无声先后有两个原因。最初缺少 `media_codecs*.xml`，导致创建 Vorbis 解码器失败。用户补装 XML 后，设备已能创建 `OMX.google.vorbis.decoder`，但播放进度仍停在 0 ms。第二轮实测确认，原厂 `init` 没有启动 Oreo 的 `hidl_memory` 服务，`ACodec` 无法取得分配编解码缓冲区所需的 `IAllocator/ashmem`。

## 1. 复现并定位故障

在电脑上执行。统一使用 SDK 版 ADB，避免和 AOSP 构建出的旧版客户端互相重启服务。

```bash
# 设置工具路径和目标设备序列号。换设备时，以 adb devices -l 的第一列为准。
ADB="$HOME/Android/Sdk/platform-tools/adb"
FASTBOOT="$HOME/Android/Sdk/platform-tools/fastboot"
ADB_SERIAL='e2d72141'

# 检查目标设备是否在线，应看到 device 状态。
"$ADB" devices -l

# 保持监听，在设置的声音页面试听原来失败的铃声。按 Ctrl+C 结束监听。
# 关注 Unable to instantiate a decoder 或 Failed to create audio/vorbis decoder。
"$ADB" -s "$ADB_SERIAL" logcat -v time \
  GenericSource:D ACodec:D NuPlayerDecoder:D MediaPlayer:E '*:S'

# 查看 OMX 是否注册。本机故障版本已经能看到 IOmx/default。
"$ADB" -s "$ADB_SERIAL" shell 'lshal | grep -F "IOmx/default"'

# 检查 Oreo 的配置搜索目录。已合入第一阶段修复的设备应在 vendor 中找到两份 XML。
"$ADB" -s "$ADB_SERIAL" shell \
  'ls /odm/etc/media_codecs*.xml /vendor/etc/media_codecs*.xml /system/etc/media_codecs*.xml 2>/dev/null'

# 确认已安装的 32 位 Vorbis 软件解码库。
"$ADB" -s "$ADB_SERIAL" shell 'ls -l /system/lib/libstagefright_soft_vorbisdec.so'
```

OMX 已注册时，单条 `Cannot open /vendor/manifest.xml` 警告不足以认定服务没有起来。应先检查解码器能否被发现和创建。

如果日志已经有 `makeComponentInstance(OMX.google.vorbis.decoder)`，但播放器一直停在 0 ms，跳到第 2.2 节检查 `IAllocator/ashmem`。测试中出现的 `ConfigPriority` 和 `ConfigAndroidVendorExtension` 警告与这种卡住现象不能画等号，临时启动共享内存服务后，播放进度实际恢复。

### media_codecs*.xml 是什么

`media_codecs*.xml` 是一组媒体编解码器配置文件的通配写法。星号 `*` 由 Shell 展开，可以匹配空字符串或一段文件名。因此它既能匹配 `media_codecs.xml`，也能匹配 `media_codecs_google_audio.xml`。它没有一个实际文件叫作 `media_codecs*.xml`。

- `media_codecs.xml` 是入口。Android 8.1 的媒体框架读取它，并按其中的 `<Include>` 加载其他配置文件。文件名符合通配模式，并不代表它会自动被加载。
- `media_codecs_google_audio.xml` 是 AOSP 提供的一份音频编解码器声明。例如，它用 `<MediaCodec name="OMX.google.vorbis.decoder" type="audio/vorbis">` 声明哪个组件可以解码 Vorbis，并在条目中描述支持的采样率和声道数。
- `libstagefright_soft_vorbisdec.so` 是实际执行 Vorbis 解码的动态库。配置让媒体框架发现和选择解码器，动态库把压缩音频解码成 PCM。当前设备有这个库，但缺少相应的 XML 配置，所以排查时先补齐入口和组件声明。

这些文件配置的是媒体格式与编解码组件。扬声器、听筒和音量属于音频策略的排查范围。

## 2. 修正编解码配置和服务启动

### 2.1 把音频配置装进 system.img

在 `~/aosp/device/skydroid/arowana_rc/` 新建 `media_codecs.xml`。Oreo 优先搜索 `/odm/etc` 和 `/vendor/etc`。该设备的 `/vendor` 指向 `/system/vendor`，因此把入口和被引用的文件放在同一 vendor 配置目录。

```xml
<?xml version="1.0" encoding="utf-8"?>
<MediaCodecs>
    <!-- 引入 AOSP 8.1 的软件音频组件声明，其中包含 OMX.google.vorbis.decoder。 -->
    <Include href="media_codecs_google_audio.xml" />
</MediaCodecs>
```

在 `device/skydroid/arowana_rc/skydroid_arowana_rc.mk` 追加复制规则：

```makefile
# 第一行安装解码器配置入口，第二行安装它引用的 AOSP 音频配置。
PRODUCT_COPY_FILES += \
    device/skydroid/arowana_rc/media_codecs.xml:system/vendor/etc/media_codecs.xml \
    frameworks/av/media/libstagefright/data/media_codecs_google_audio.xml:system/vendor/etc/media_codecs_google_audio.xml
```

### 2.2 让 hidl_memory 随系统启动

Oreo 的 `ACodec` 在分配编解码缓冲区时查找 `IAllocator/ashmem`。当前的 `/system/etc/init/android.hidl.allocator@1.0-service.rc` 将 `hidl_memory` 放在 `class hal`，而这台设备沿用的原厂 `init.rc` 没有 `class_start hal`。所以服务程序虽然装在镜像里，开机时没有启动。

#### 先做可逆的实机验证

以下命令适用于确认开机后没有 `IAllocator/ashmem` 的移植版。若服务本来就在运行，保留现场，直接排查其它环节。

```bash
# 读取服务状态和 HIDL 注册情况，记录临时测试前的基线。
"$ADB" -s "$ADB_SERIAL" shell getprop init.svc.hidl_memory
"$ADB" -s "$ADB_SERIAL" shell 'lshal | grep -F "IAllocator/ashmem"'

# 临时通知 init 启动已有服务。su 0 以 root 发送控制属性，操作不写入 system.img。
"$ADB" -s "$ADB_SERIAL" shell su 0 setprop ctl.start hidl_memory

# 确认 init 报告 running，且 hwservicemanager 已注册 IAllocator/ashmem。
"$ADB" -s "$ADB_SERIAL" shell getprop init.svc.hidl_memory
"$ADB" -s "$ADB_SERIAL" shell 'lshal | grep -F "IAllocator/ashmem"'

# 此时去设置试听同一个铃声。播放期间读取 ALSA 状态，观察 RUNNING 和 hw_ptr。
"$ADB" -s "$ADB_SERIAL" shell 'cat /proc/asound/card0/pcm0p/sub0/status'

# 播放停止后，关闭这次临时启动的服务，恢复测试前的未运行状态。
"$ADB" -s "$ADB_SERIAL" shell su 0 setprop ctl.stop hidl_memory

# 确认服务回到 stopped，注册表中也不再有 IAllocator/ashmem。
"$ADB" -s "$ADB_SERIAL" shell getprop init.svc.hidl_memory
"$ADB" -s "$ADB_SERIAL" shell 'lshal | grep -F "IAllocator/ashmem"'
```

用同一个 `Ring_Synth_04.ogg` 做对照时，启动服务前，媒体流与铃声流均停在 0 ms，PCM 关闭。启动服务后，两种流的进度都推进到约 2690 ms，PCM 处于 `RUNNING` 且硬件指针持续增加，内核显示外置功放 `AW8738 PA` 为 `On`。实验结束后服务已停，临时应用已卸载。永久修复仍需手动构建、刷写并确认实际听感。

#### 在设备目标中永久启用

```bash
# 进入源代码根目录，以下源文件和设备文件路径都以这里为起点。
cd "$HOME/aosp"

# 保存 service rc 文件名，供复制规则复用。
ALLOCATOR_RC='android.hidl.allocator@1.0-service.rc'

# 复制 AOSP 原版 rc 到设备配置目录，只把 class hal 改成 class core。
# 原厂 init 会启动 core。保留原版服务名、程序路径、用户和组。
sed 's/^[[:space:]]*class hal[[:space:]]*$/    class core/' \
    "system/libhidl/transport/allocator/1.0/default/$ALLOCATOR_RC" \
    > "device/skydroid/arowana_rc/legacy-init/$ALLOCATOR_RC"
```

在 `device/skydroid/arowana_rc/legacy-init.mk` 加入以下复制规则。这个服务从 `/system/etc/init/` 加载，安装路径与显示用的图形 allocator 不同。

```makefile
# 用设备专用配置覆盖系统镜像里原有的 hidl_memory 启动配置。
PRODUCT_COPY_FILES += \
    device/skydroid/arowana_rc/legacy-init/android.hidl.allocator@1.0-service.rc:system/etc/init/android.hidl.allocator@1.0-service.rc
```

## 3. 构建并检查最终镜像

先保留当前已验证能启动的 8.1 `system.img` 和校验清单。如果你已经合入背光等改动，确认回退镜像包含你要保留的变更。

```bash
# 加载本机 AOSP 8.1 构建环境，选中 SkyDroid ARM64 实机目标。
source "$HOME/aosp/env_aosp8.sh" skydroid_arowana_rc-userdebug

# 增量重编 system.img。短构建号避免指纹超长，-R 仅关闭这次构建进程的 ASLR。
BUILD_NUMBER=ar01 setarch "$(uname -m)" -R make -j8 systemimage WITH_DEXPREOPT=false

# 定义产品输出目录并查询镜像大小，实机 system 分区容量为 1395654656 字节。
PRODUCT_OUT="$HOME/aosp/out/target/product/arowana_rc"
stat -c '%s %n' "$PRODUCT_OUT/system.img"

# 以只读方式检查 ext4。-f 强制执行检查，-n 禁止修改镜像。
e2fsck -fn "$PRODUCT_OUT/system.img"

# 从最终产物检查入口 XML，确认它引用了同目录的音频配置。
debugfs -R 'cat /vendor/etc/media_codecs.xml' "$PRODUCT_OUT/system.img"

# 确认最终产物的音频配置中存在 Vorbis 解码器声明。
debugfs -R 'cat /vendor/etc/media_codecs_google_audio.xml' "$PRODUCT_OUT/system.img" \
  | grep -F 'OMX.google.vorbis.decoder'

# 确认待刷镜像内仍有软件解码库。预期输出 inode 信息。
debugfs -R 'stat /lib/libstagefright_soft_vorbisdec.so' "$PRODUCT_OUT/system.img"

# 检查实际打包的 hidl_memory 配置，应该显示 class core。
debugfs -R 'cat /etc/init/android.hidl.allocator@1.0-service.rc' "$PRODUCT_OUT/system.img"

# 确认镜像中仍有对应的共享内存服务程序。预期输出 inode 信息。
debugfs -R 'stat /bin/hw/android.hidl.allocator@1.0-service' "$PRODUCT_OUT/system.img"

# 计算候选镜像的 SHA-256，记录所测试的版本。
sha256sum "$PRODUCT_OUT/system.img"
```

## 4. 刷写与实机验收

改动都在 `system` 中，继续使用设备上已验证的 8.1 `boot`。按顺序执行，检查失败时停在当前步骤。

```bash
# 重启到 Bootloader，再列出 Fastboot 设备。
"$ADB" -s "$ADB_SERIAL" reboot bootloader
"$FASTBOOT" devices -l

# 把占位文字替换成 Fastboot 列表里目标设备的序列号。
FASTBOOT_SERIAL='替换为实机Fastboot序列号'

# 核对产品代号。必须返回 arowana-rc 后才继续刷写。
"$FASTBOOT" -s "$FASTBOOT_SERIAL" getvar product

# 以 48 MiB 分段写入候选系统镜像。确认全部写入返回 OKAY。
"$FASTBOOT" -s "$FASTBOOT_SERIAL" -S 48M flash system "$PRODUCT_OUT/system.img"

# 正常重启，最多等待 90 秒获取 ADB 连接。
"$FASTBOOT" -s "$FASTBOOT_SERIAL" reboot
timeout 90 "$ADB" -s "$ADB_SERIAL" wait-for-device

# 确认 Android 启动完成。返回 1 后再试听。
"$ADB" -s "$ADB_SERIAL" shell getprop sys.boot_completed

# 确认 hidl_memory 正常随开机启动，无需再手动发送 ctl.start。
"$ADB" -s "$ADB_SERIAL" shell getprop init.svc.hidl_memory
"$ADB" -s "$ADB_SERIAL" shell 'lshal | grep -F "IAllocator/ashmem"'

# 重新监听解码日志，同时在设置里试听同一个 Ogg 铃声。
"$ADB" -s "$ADB_SERIAL" logcat -v time ACodec:D NuPlayerDecoder:D MediaPlayer:E '*:S'

# 在另一个已设置变量的终端，于播放期间查询 PCM 状态。
# 预期为 RUNNING，多次读取时 hw_ptr 应继续推进。短铃声结束后可能显示 closed。
"$ADB" -s "$ADB_SERIAL" shell 'cat /proc/asound/card0/pcm0p/sub0/status'
```

通过条件是同一个铃声能创建 Vorbis 解码器、PCM 指针推进、实体扬声器能听到声音。再选一个不同的 Ogg 铃声复测。

## 5. 仍然无声时怎么查

- **仍无法创建 Vorbis 解码器**。检查更高优先级的配置入口、XML 和 Include 路径，再查 OMX 进程是否因架构或依赖错误而打不开动态库。
- **解码器已创建，播放停在 0 ms，PCM 关闭**。优先确认 `hidl_memory` 是 `running`，并确认注册的是 `IAllocator/ashmem`。
- **解码器已创建，但播放途中报错**。换一个已知可用的 Ogg 文件，并观察解码错误是否能复现。
- **PCM 已运行但扬声器仍安静**。查看铃声流 `STREAM_RING` 的静音、音量和播放时的输出设备。媒体流的测试不能代替铃声流路由检查。

```bash
# 查 XML 解析、动态库加载或符号解析错误。
"$ADB" -s "$ADB_SERIAL" logcat -b all -d \
  | grep -Ei 'MediaCodecsXmlParser|SoftOMX|vorbis|dlopen failed|cannot locate symbol'

# 查看铃声流的静音、音量和输出设备。
"$ADB" -s "$ADB_SERIAL" shell 'dumpsys audio | grep -A 10 STREAM_RING | head -12'

# 在试听期间检查音频策略的实际输出，区分 SPEAKER 和 EARPIECE。
"$ADB" -s "$ADB_SERIAL" shell 'dumpsys media.audio_policy'
```

## 6. 回退到上一版 8.1

如果新镜像启动异常，用机身按键进入 Fastboot。在此前保存的稳定版镜像目录执行以下命令：

```bash
# 用备份清单验证当前目录的稳定版 system.img。
sha256sum -c SHA256SUMS

# 核实 FASTBOOT_SERIAL 对应的设备仍报告 arowana-rc。
"$FASTBOOT" -s "$FASTBOOT_SERIAL" getvar product

# 将稳定版 system.img 分段刷回，boot 分区继续使用当前 8.1 启动镜像。
"$FASTBOOT" -s "$FASTBOOT_SERIAL" -S 48M flash system system.img

# 确认刷回成功后，重启设备。
"$FASTBOOT" -s "$FASTBOOT_SERIAL" reboot
```
