# SkyDroid Android 8.1 蓝牙修复

原故障中，`IBluetoothHci/default` 已经注册，但打开蓝牙时出现 `dlopen failed: library "libbt-vendor.so" not found`，随后 Android 蓝牙进程退出。实机只安装了 `/vendor/lib/libbt-vendor.so`，原厂镜像也只有 ARM32 版本。移植版 HIDL 服务原先是 ARM64，不能在进程内加载 ARM32 厂商库。原厂启动脚本还依赖 `bt_init`，该程序也没有进入旧移植镜像。

## 1. 验证 ABI 与故障日志

```bash
# 固定 SDK ADB 路径和本机目标序列号。
ADB="$HOME/Android/Sdk/platform-tools/adb"
ADB_SERIAL='e2d72141'

# 检查 HCI 服务是否注册。注册成功只能说明 binder 服务已发布。
"$ADB" -s "$ADB_SERIAL" shell 'lshal | grep -F "IBluetoothHci/default"'

# 查看厂商库实际安装在哪个位数目录。原厂仅提供 /vendor/lib 下的 ARM32 库。
"$ADB" -s "$ADB_SERIAL" shell 'ls -l /vendor/lib/libbt-vendor.so /vendor/lib64/libbt-vendor.so'

# 在电脑端核对编译产物。三项都应显示 ELF 32-bit 和 ARM。
OUT="$HOME/aosp/out/target/product/arowana_rc"
file "$OUT/system/vendor/bin/hw/android.hardware.bluetooth@1.0-service" \
     "$OUT/system/vendor/lib/hw/android.hardware.bluetooth@1.0-impl.so" \
     "$OUT/system/vendor/lib/libbt-vendor.so"

# 尝试打开蓝牙后读取初始化日志。优先看 dlopen、UART、firmware 和 HCI 响应。
"$ADB" -s "$ADB_SERIAL" logcat -b all -d \
  | grep -Ei 'BluetoothHci|libbt-vendor|VendorInterface|bt_init|hci_initialize' \
  | tail -80
```

这里的 ABI 约束发生在 HIDL 服务进程内部。Android 框架和蓝牙应用仍可通过 Binder 与 32 位 HAL 通信，应用进程可以保持其原有位数。

## 2. 源码与打包改动

1. 在 `hardware/interfaces/bluetooth/1.0/default/Android.mk` 中，将 `android.hardware.bluetooth@1.0-service` 的 `LOCAL_MULTILIB` 设置为 `32`，并以 `TARGET_DEVICE=arowana_rc` 限定到这台设备。
2. 保留 `android.hardware.bluetooth@1.0-impl` 的 32 位构建产物在 `/vendor/lib/hw/`，保留原厂 `libbt-vendor.so` 在 `/vendor/lib/`。32 位服务加载这两层，三者 ABI 一致。
3. `device/skydroid/arowana_rc/proprietary.mk` 将原厂 `bt_init` 放回 `/system/bin/`。这个程序自身是 ARM64 的独立进程，原厂 `init.song.rc` 已定义如何启动它。
4. 沿用设备自带的 `legacy-init` 覆盖，蓝牙 HIDL 服务属于 `class core`，可以由当前原厂 init 启动。原厂厂商库使用 `/dev/ttyS2`、rfkill 和 `/vendor/firmware/`，保留这些路径供下一层排查。

```makefile
# 此处仅作用于 SkyDroid 的蓝牙 HIDL 可执行模块。
ifeq ($(TARGET_DEVICE),arowana_rc)
LOCAL_MULTILIB := 32
endif
```

```bash
# 加载实机目标，不影响其他 lunch 目标的蓝牙服务位数。
source "$HOME/aosp/env_aosp8.sh" skydroid_arowana_rc-userdebug

# 重编包含 32 位蓝牙服务和原厂初始化程序的系统镜像。
BUILD_NUMBER=ar01 setarch "$(uname -m)" -R make -j8 systemimage WITH_DEXPREOPT=false
```

与 Wi-Fi 修复使用同一版 `system.img`。刷写与回退见 [Wi-Fi 修复指南](Wi-Fi修复与连接验证.md#3-编译并验证实际镜像)及[实机移植记录](../移植与故障/安卓8.1移植记录.md)。保留先前的 8.1 boot 和原厂备份。

## 3. 启用和复测

```bash
# 打开蓝牙设置页，在界面打开蓝牙开关。让系统走正常的初始化流程。
"$ADB" -s "$ADB_SERIAL" shell am start -a android.settings.BLUETOOTH_SETTINGS

# 读取框架适配器状态。预期为 ON，而不是短暂进入 TURNING_ON 后退出。
"$ADB" -s "$ADB_SERIAL" shell 'dumpsys bluetooth_manager | grep -Ei "enabled:|state:|Bluetooth Status"'

# 检查 HCI 服务仍在运行，并核对异常终止或初始化失败是否再次发生。
"$ADB" -s "$ADB_SERIAL" shell getprop init.svc.bluetooth-1-0
"$ADB" -s "$ADB_SERIAL" logcat -b all -d \
  | grep -Ei 'BluetoothHci|libbt-vendor|VendorInterface|hci_initialize|firmware|initializationComplete' \
  | tail -80
```

蓝牙适配器稳定为 ON 后，在设置页用手边已获授权的配件测试设备发现、配对和连接。若动态库已成功打开但状态仍回落，按 UART 权限、rfkill、电源初始化和 HCI 命令响应的顺序检查。确认当前尝试的日志时间，避免把旧版本的 `dlopen` 报错当成新结果。

## 4. 目前剩余的启动故障

32 位 HAL 已通过实机测试确认能加载厂商库，也成功打开 `/dev/ttyS2`。实际失败已推进到更低一层：**控制器没有回复 HCI Reset（opcode `0x0c03`）**。适配器从 `BLE_TURNING_ON` 回落到 `OFF`，最后的 `SIGABRT` 由上层蓝牙栈的 `command_timed_out()` 触发。崩溃记录里的 `ABI: arm64` 属于 `com.android.bluetooth`，32 位 HAL 在另一个进程中。

实机用三种方式交叉确认：

1. 启动期间蓝牙 rfkill 变为 `1`，`bt-reg-on` 被拉高。UART 发送计数增加，接收计数一直为 0。
2. 跟踪 HAL 的串口调用发现，它在 115200 波特率下向 `/dev/ttyS2` 提交了 4 字节的 H4 HCI Reset 包，系统调用成功，但未收到控制器回包。
3. 单独停掉 HAL，用同一 UART 和 rfkill 做短时独立测试，115200 和 3000000 波特率均未收到 RX 字节。测试后恢复蓝牙供电关闭和 HAL 待命，并删除测试程序。Wi-Fi 仍能保持连接。

另外补回了原厂 `/system/etc/bluetooth/bt_vendor.conf`，显式指定 UART 为 `/dev/ttyS2`，固件目录为 `/vendor/firmware/`。配置恢复后仍无 HCI 回复。原厂 `bt_init -l` 在现有策略下自动启动时缺 SELinux 域，但手动执行可成功载入板级蓝牙地址，重复测试仍失败。

```bash
# 在设置中打开蓝牙后，查询供电开关和 ttyS2 的 UART 统计。
# 该设备的 rfkill0 对应蓝牙，串口统计第二号条目对应 ttyS2。
"$ADB" -s "$ADB_SERIAL" shell 'su 0 cat /sys/class/rfkill/rfkill0/type /sys/class/rfkill/rfkill0/state; su 0 grep "^2:" /proc/tty/driver/serial'

# 从内核记录确认板级电源与串口驱动是否报告异常。
"$ADB" -s "$ADB_SERIAL" shell 'su 0 dmesg | grep -Ei "bluepower|bluesleep|ttyS2|bt_init" | tail -30'

# 查找此次开启的第一处 HCI 超时。0x0c03 是 HCI Reset 的 opcode。
"$ADB" -s "$ADB_SERIAL" logcat -b all -d \
  | grep -Ei 'startup_timer_expired|command_timed_out|enable timeout|BluetoothHci::initialize' \
  | tail -35
```

追加对照中，先关闭 Wi-Fi 并确认 `wpa_supplicant=stopped`，再单独开启蓝牙。结果仍从 `BLE_TURNING_ON` 回落到 `OFF`，UART 接收计数为 0。测试后重新启用 Wi-Fi，确认连接状态回到 `COMPLETED`。这个结果排除了此次故障必须由 Wi-Fi 正在运行才能触发。

日志中的 `Firmware configured in …` 由计时对象析构时打印，失败清理也会触发。应以固件成功回调、UART RX 和蓝牙状态为准。现有证据能定位到控制器通信，尚无法区分板级电源和唤醒时序、UART 针脚或控制器本身。后续在原厂 7.1.2 上完成了对照，结果见下文。


## 5. 原厂系统对照

用原厂 Android 7.1.2 的 `system.img` 和从内存启动的原厂诊断 ramdisk 做对照。实机检查确认 `/data` 和 `/cache` 都挂载在 tmpfs，`/persist` 以只读方式挂载。原厂系统报告 `sys.boot_completed=1`。Wi-Fi 关闭时发起蓝牙开启，UART 发送计数从 0 增加到 12，接收计数始终为 0。原厂蓝牙栈也报等待 HCI Reset（opcode `0x0c03`）超时并重启蓝牙进程。

因此这个故障可在原厂系统和 Oreo 移植版中复现。两套系统都能打开同一个 UART，但都没有收到控制器回复。进一步定位需要在开启蓝牙的瞬间测量控制器供电和复位、唤醒信号，并检查 UART TX、RX 与 CTS/RTS。当前测试只能确认串口驱动的发送计数和接收计数，无法确认数据实际到达控制器引脚，也无法确定具体坏在哪个元件。
