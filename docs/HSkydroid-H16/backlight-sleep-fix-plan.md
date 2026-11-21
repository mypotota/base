# 熄屏后背光仍亮的修复计划

对象是运行移植版 AOSP 8.1 的 SkyDroid `song / arowana-rc`。实测亮屏、熄屏和唤醒时，`actual_brightness` 都是 `500`。熄屏时 Android 报 `Display Power: state=OFF`，硬件合成器也报告显示已关闭。当前镜像有能访问背光节点的原厂 `lights.song.so`，但 `lshal` 里没有 Oreo LightsService 所需的 `android.hardware.light@2.0::ILight/default`。第一轮修复聚焦在接通这条调用链，实机结果以复测为准。

## 1. 复现并建立基线

在同一终端执行以下命令。ADB 和 Fastboot 可能显示不同序列号，分别以各自的设备列表为准。如果电脑连接了多台设备，始终带 `-s`。

```bash
# 列出 ADB 设备及其状态，找到目标机器的序列号。
adb devices -l

# 把目标设备的序列号保存到当前终端的变量中。这台设备实测为 e2d72141。
# 如果 adb devices -l 显示的序列号不同，以实际输出的第一列为准。
ADB_SERIAL='e2d72141'

# 打印当前变量值，确认输出为 e2d72141 或你实际查到的序列号。
echo "$ADB_SERIAL"

# "$ADB_SERIAL" 会展开为序列号。用这个序列号指定设备并发送唤醒事件。
adb -s "$ADB_SERIAL" shell input keyevent KEYCODE_WAKEUP

# 输出 Android 显示电源状态以及内核报告的请求亮度和实际亮度。
adb -s "$ADB_SERIAL" shell 'dumpsys power | grep "Display Power"; cat /sys/class/backlight/lcd-backlight/brightness /sys/class/backlight/lcd-backlight/actual_brightness'

# 主动触发一次熄屏，不必等待无操作超时。
adb -s "$ADB_SERIAL" shell input keyevent KEYCODE_SLEEP

# 留出背光过渡时间，避免恰好采到熄屏动画中的中间值。
sleep 2

# 熄屏后再读取同样的状态。故障表现为显示已 OFF，而 actual_brightness 仍大于 0。
adb -s "$ADB_SERIAL" shell 'dumpsys power | grep "Display Power"; cat /sys/class/backlight/lcd-backlight/brightness /sys/class/backlight/lcd-backlight/actual_brightness'

# 查询已注册的 Light 2.0 服务。当前故障版本预期没有匹配行。
adb -s "$ADB_SERIAL" shell 'lshal | grep -F "android.hardware.light@2.0::ILight"'

# 检查背光节点的属主、写权限和 SELinux 标签。实机当前 brightness 为 system:system、0644。
adb -s "$ADB_SERIAL" shell 'ls -lZ /sys/class/backlight/lcd-backlight/brightness'

# 结束诊断后唤醒设备，让屏幕回到可操作状态。
adb -s "$ADB_SERIAL" shell input keyevent KEYCODE_WAKEUP
```

如果看到 `adb: device 'ADB_SERIAL' not found`，检查 `-s` 后的参数是否漏了 `$`。`"ADB_SERIAL"` 会把变量名原样传给 ADB，`"$ADB_SERIAL"` 才会传入变量值。打开新终端后，需要重新执行变量赋值。

## 2. 接上 Oreo 的 Light 2.0 服务

在 `~/aosp/device/skydroid/arowana_rc/skydroid_arowana_rc.mk` 加入两个模块。第一个把旧 lights HAL 包装成 Oreo 接口，第二个启动进程并向 `hwservicemanager` 注册接口。

```makefile
# 编译旧版 lights HAL 适配器和负责注册 ILight 的服务进程。
PRODUCT_PACKAGES += \
    android.hardware.light@2.0-impl \
    android.hardware.light@2.0-service
```

沿用这个设备其他 HAL 的做法，将原版 service rc 复制到设备专用目录，把服务归入原厂 `init` 会启动的 `core` class。服务仍以 `system` 身份运行，与实机背光节点的属主一致。

```bash
# 切到 AOSP 根目录，让下方路径都相对于同一棵源代码树。
cd "$HOME/aosp"

# 定义文件名，便于复用同一个源路径和设备目标路径。
LIGHT_RC='android.hardware.light@2.0-service.rc'

# 复制原版服务定义，只把 class hal 改为 class core。
# sed 的输出写入设备专用目录，AOSP 公共定义本身保持原样。
sed 's/^[[:space:]]*class hal[[:space:]]*$/    class core/' \
    "hardware/interfaces/light/2.0/default/$LIGHT_RC" \
    > "device/skydroid/arowana_rc/legacy-init/$LIGHT_RC"
```

在 `device/skydroid/arowana_rc/legacy-init.mk` 加入下列条目，使镜像内的服务配置使用设备版本。

```makefile
# 将设备专用 Light 服务配置安装到 vendor 的 init 扫描目录。
PRODUCT_COPY_FILES += device/skydroid/arowana_rc/legacy-init/android.hardware.light@2.0-service.rc:system/vendor/etc/init/android.hardware.light@2.0-service.rc
```

原厂模块已经在 `proprietary.mk` 中。适配器通过 `hw_get_module("lights")` 加载它，当前设备的 `ro.arch=song`。只有日志显示加载到了错误的模块时，再检查 `hardware/libhardware/hardware.c` 的查找顺序，必要时通过产品属性 `ro.hardware.lights=song` 指定变体。

## 3. 编译并审核镜像

刷写前保留已验证的 8.1 `oreo-port/images/system.img` 和它的校验清单。构建输出以下方 `out/` 路径为准，验收完成前保留旧镜像供回退。

```bash
# 加载本机的 AOSP 8.1 环境，并选中 SkyDroid 实机目标。
source "$HOME/aosp/env_aosp8.sh" skydroid_arowana_rc-userdebug

# 使用已验证的短构建号和宿主参数。setarch -R 关闭此次构建进程的 ASLR，
# -j8 使用八个并行任务，systemimage 增量构建系统分区镜像。
BUILD_NUMBER=ar01 setarch "$(uname -m)" -R make -j8 systemimage WITH_DEXPREOPT=false

# 记录产品输出路径，并检查候选镜像的精确字节数。目标 system 分区为 1395654656 字节。
PRODUCT_OUT="$HOME/aosp/out/target/product/arowana_rc"
stat -c '%s %n' "$PRODUCT_OUT/system.img"

# 只读检查 ext4 文件系统。-f 强制检查，-n 禁止修改镜像。
e2fsck -fn "$PRODUCT_OUT/system.img"

# 确认最终镜像里实际装入的服务 rc 使用 class core，避免误用了原版 class hal。
debugfs -R 'cat /vendor/etc/init/android.hardware.light@2.0-service.rc' "$PRODUCT_OUT/system.img"

# 确认镜像内有服务可执行文件和 64 位适配库。两个 stat 都应输出 inode 信息。
debugfs -R 'stat /vendor/bin/hw/android.hardware.light@2.0-service' "$PRODUCT_OUT/system.img"
debugfs -R 'stat /vendor/lib64/hw/android.hardware.light@2.0-impl.so' "$PRODUCT_OUT/system.img"

# 记录候选 system.img 的 SHA-256，供实机测试和后续归档比对。
sha256sum "$PRODUCT_OUT/system.img"
```

## 4. 刷写 system 并验证

这版改动在 `system` 中，当前已验证的 8.1 `boot` 与其配套。先确认旧镜像和回退命令可用。每一步检查通过后再执行下一步，尤其是产品代号和刷写结果。

```bash
# 将当前在线的目标设备重启到 Bootloader。
adb -s "$ADB_SERIAL" reboot bootloader

# 等 Fastboot 列出设备，取得该模式下实际识别到的序列号。
fastboot devices -l

# 把占位文字换为 Fastboot 设备列表里的序列号。
FASTBOOT_SERIAL='替换为实机Fastboot序列号'

# 再核对产品代号。应显示 arowana-rc，否则停止操作。
fastboot -s "$FASTBOOT_SERIAL" getvar product

# 以已验证的 48 MiB 分段方式刷入候选 system。各段均返回 OKAY 后再重启。
fastboot -s "$FASTBOOT_SERIAL" -S 48M flash system "$PRODUCT_OUT/system.img"

# 从设备现有 boot 分区正常启动，加载刚刷入的 system。
fastboot -s "$FASTBOOT_SERIAL" reboot

# 最多等待 90 秒让 ADB 重新出现，超时后检查设备和 USB 状态。
timeout 90 adb -s "$ADB_SERIAL" wait-for-device

# 确认系统启动完成。返回 1 才进入背光验收。
adb -s "$ADB_SERIAL" shell getprop sys.boot_completed

# 检查 init 服务状态，应返回 running。
adb -s "$ADB_SERIAL" shell getprop init.svc.light-hal-2-0

# 检查 HIDL 服务实际注册情况，应出现 ILight/default。
adb -s "$ADB_SERIAL" shell 'lshal | grep -F "android.hardware.light@2.0::ILight/default"'
```

重复第 1 节的熄屏和唤醒动作三次，每次记录 Android 状态、实际亮度和实物屏幕现象。验收时，亮屏亮度大于零，熄屏后 `actual_brightness=0`，唤醒后恢复到熄屏前亮度。再手动滑动设置中的亮度条到两个不同位置，并读取 `actual_brightness`，确认它跟着变化。最后用实体按键试一次，并在拔掉 USB 后试一次自动熄屏。

## 5. 根据失败位置继续查

| 观察 | 下一步 |
|---|---|
| init 服务没运行 | 检查镜像内 rc、`class core` 和可执行文件路径，再看 init 启动日志 |
| 服务运行但 `lshal` 没有 ILight | 检查 HIDL 实现库架构、注册失败日志，以及是否出现 `hw_get_module` 或 `light_open` 错误 |
| ILight 已注册但亮度保持不变 | 核对框架是否发出 BACKLIGHT 请求、加载的是否为 `lights.song.so`，并检查 sysfs 写入错误和 SELinux 日志 |
| 亮度已经归零但实物仍发光 | 核对实际控制的是哪个背光节点，并继续检查驱动、电源和面板状态 |

```bash
# 过滤应用层日志，定位加载原厂 HAL、注册 ILight 和设置背光时的错误。
adb -s "$ADB_SERIAL" logcat -b all -d | grep -Ei 'ILight|LightHal|LightsService|hw_get_module|light_open|backlight'

# 用 root 读取内核日志，筛出可能相关的 SELinux 和背光记录。
adb -s "$ADB_SERIAL" shell 'su 0 dmesg | grep -Ei "avc: denied|backlight|sy7203"'
```

节点已由 `system` 所有，先保留其权限。若日志显示 SELinux 拒绝，结合 `permissive=0/1` 判断是否真实阻断，并核对进程域和节点标签。需要调整策略时，针对真实 sysfs 路径与 Light HAL 域写最小规则，并单独验证 enforcing。当前开发版为 permissive，单条审计日志不能证明写入被阻止。

## 6. 回退到已验证的 8.1

如果候选镜像无法启动或显示恶化，用机身按键进入 Fastboot。以下命令在此前保存的稳定版 `oreo-port/images/` 中执行。这个回退与恢复原厂 7.1.2 的流程不同，此处只需还原 8.1 的 `system`。

```bash
# 核对当前目录下此前已验证的 8.1 镜像和配套清单。
sha256sum -c SHA256SUMS

# 确认连接的仍是 arowana-rc，避免把备份写到其他设备。
fastboot -s "$FASTBOOT_SERIAL" getvar product

# 按 48 MiB 分段回刷稳定版 system.img，等待 Fastboot 报告完成。
fastboot -s "$FASTBOOT_SERIAL" -S 48M flash system system.img

# 让设备带着原有的 8.1 boot 和刚回退的 system 正常重启。
fastboot -s "$FASTBOOT_SERIAL" reboot
```
