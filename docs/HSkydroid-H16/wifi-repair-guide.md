# SkyDroid Android 8.1 Wi-Fi 修复

实机内核已识别 Broadcom BCM4345 系列控制器并注册 `wlan0`，`wificond` 也在运行。故障发生在用户空间：开启 Wi-Fi 时，`wificond` 找不到两处 `wpa_supplicant.conf`，镜像内也没有 supplicant 程序。原厂 `init.song.rc` 已定义 `wifi_init`，但移植镜像缺少相应的程序。仅看到 `wlan0` 只能说明驱动绑定并注册接口，扫描和连接还需要上层服务。

## 1. 确认故障停在哪一层

```bash
# 固定使用 SDK ADB，并指定目标设备，避免旧版 AOSP ADB 互相重启后台服务。
ADB="$HOME/Android/Sdk/platform-tools/adb"
ADB_SERIAL='e2d72141'

# 查看 wlan0 是否由内核注册以及当前链路状态。未连接时 DOWN 不等同于驱动丢失。
"$ADB" -s "$ADB_SERIAL" shell 'ip link show wlan0'

# 查看框架使用的网络守护进程和 supplicant 的 init 服务状态。
"$ADB" -s "$ADB_SERIAL" shell 'getprop init.svc.wificond; getprop init.svc.wpa_supplicant'

# 检查 supplicant 的二进制、启动配置和无凭据的配置模板是否已安装。
"$ADB" -s "$ADB_SERIAL" shell 'ls -l /vendor/bin/hw/wpa_supplicant /vendor/etc/init/wpa_supplicant.rc /vendor/etc/wifi/wpa_supplicant.conf'

# 开启 Wi-Fi 后复现，再筛选当前日志中的启动、扫描和配置错误。
"$ADB" -s "$ADB_SERIAL" logcat -b all -d \
  | grep -Ei 'wificond|wpa_supplicant|WifiStateMachine|CTRL-EVENT-SCAN|wifi_init' \
  | tail -80
```

优先读同一次开启操作的前几条失败。原故障明确出现了 `Cannot open "/vendor/etc/wifi/wpa_supplicant.conf"`。`No Offload Service available` 只表示扫描卸载 HAL 不可用，不足以解释普通扫描失败。

## 2. 设备目标里有哪些改动

源码目录为 `~/aosp/device/skydroid/arowana_rc/`。

- `BoardConfig.mk` 选用 AOSP Oreo 的 `VER_0_8_X` supplicant 源码、`NL80211` 驱动接口和 Broadcom 的 `lib_driver_cmd_bcmdhd` 私有命令库。
- `skydroid_arowana_rc.mk` 将 `wpa_supplicant` 加入 `PRODUCT_PACKAGES`，并安装 `wpa_supplicant.conf` 到 `/vendor/etc/wifi/`。配置模板取自原厂的默认配置形式，仅含 `update_config`、`eapol_version`、`ap_scan`、`fast_reauth` 和 `pmf` 等全局设置。
- `legacy-init/wpa_supplicant.rc` 注册名为 `wpa_supplicant` 的服务，`legacy-init.mk` 将它安装到 `/vendor/etc/init/`。`disabled` 允许 `wificond` 按需启动，`oneshot` 避免 init 在主动停止后立刻拉起。
- `proprietary.mk` 安装从本机原厂 `system.img` 取出的 `wifi_init`。原厂 init 已有启动规则，这个程序读取板级 MAC 分区并向 Broadcom 驱动提供设置。

启动行中 `-iwlan0` 选择接口，`-Dnl80211` 指定内核通信接口，`-c` 指向框架生成在 `/data/misc/wifi/` 的运行配置，`-m` 指定 P2P 配置，`-e` 指定熵文件，`-g@android:wpa_wlan0` 使用 init 创建的 Android 控制 socket。系统模板和用户保存的网络配置是两份文件。

## 3. 编译并验证实际镜像

```bash
# 进入这台设备的 AOSP 8.1 构建环境。
source "$HOME/aosp/env_aosp8.sh" skydroid_arowana_rc-userdebug

# 增量编译 system.img。ar01 避免构建指纹过长，-R 关闭本次构建进程的 ASLR。
BUILD_NUMBER=ar01 setarch "$(uname -m)" -R make -j8 systemimage WITH_DEXPREOPT=false

# 设置输出路径并检查镜像。system 分区容量为 1395654656 字节。
OUT="$HOME/aosp/out/target/product/arowana_rc"
stat -c '%s %n' "$OUT/system.img"
e2fsck -fn "$OUT/system.img"

# 从最终 ext4 镜像读取启动配置，确认 rc 真的被装进产物。
debugfs -R 'cat /vendor/etc/init/wpa_supplicant.rc' "$OUT/system.img"

# 检查 daemon、配置模板和板级初始化程序都存在，预期输出各自的 inode。
debugfs -R 'stat /vendor/bin/hw/wpa_supplicant' "$OUT/system.img"
debugfs -R 'stat /vendor/etc/wifi/wpa_supplicant.conf' "$OUT/system.img"
debugfs -R 'stat /bin/wifi_init' "$OUT/system.img"
```

本次 Wi-Fi 和蓝牙共用同一版 `system.img`，配对保留现有 8.1 `boot`。刷写与回退沿用[实机移植记录](skydroid-android-8.1-port.md)中的方法。回退时优先选用设备工作目录下的 `radio-fix/before/system.img` 及其校验清单，那里保存了本次修改前构建出的版本。回退这次无线改动只需刷该版 `system`。

## 4. 实机验收

```bash
# 开启 Wi-Fi。该命令切换用户设置，之后由框架按需启动 supplicant。
"$ADB" -s "$ADB_SERIAL" shell svc wifi enable

# 查看设备网卡和 supplicant，预期 wlan0 已启用、服务状态为 running。
"$ADB" -s "$ADB_SERIAL" shell 'ip link show wlan0; getprop init.svc.wpa_supplicant'

# 在 Wi-Fi 设置页触发扫描后查看结果。连接自己有权限使用的网络再测试 IP 和联网。
"$ADB" -s "$ADB_SERIAL" shell dumpsys wifi
```

扫描能发现附近网络说明已通过发现阶段。还需要使用一个已授权接入点验证关联、IP 分配和访问网络。若只能扫描，转而检查认证、DHCP 和连接日志，避免把问题退回到已经通过的驱动注册阶段。

### 本次验证结果

新镜像通过普通重启。实机的 `wpa_supplicant` 为 `running`，连接已有授权的 5 GHz 接入点时，supplicant 状态为 `COMPLETED`。设备获得了 IPv4 地址和默认路由，绑定 `wlan0` 向局域网网关发送两个探测包，两个均成功返回。本次验证覆盖 Wi-Fi 关联、地址分配和局域网访问。

```bash
# 单独显示 Wi-Fi 状态，避免把 SSID 或 BSSID 复制进日志文档。
"$ADB" -s "$ADB_SERIAL" shell 'dumpsys wifi | grep -o "Supplicant state: [A-Z_]*" | head -1'

# 查询 wlan0 的 IPv4 地址及其路由。不需要公开实际 IP。
"$ADB" -s "$ADB_SERIAL" shell 'ip -4 -o addr show dev wlan0; ip route show table all dev wlan0'

# 将占位值替换为上一步显示的局域网默认网关，绑定 wlan0 发两个探测包。
# 这个旧系统要求以 root 使用 ping -I，普通 shell 会报 SO_BINDTODEVICE 权限错误。
GATEWAY='替换为无线网关IP'
"$ADB" -s "$ADB_SERIAL" shell su 0 ping -I wlan0 -c 2 -W 2 "$GATEWAY"
```

仍出现过 Broadcom 私有命令 `COUNTRY CN` 返回失败的日志，但本次 5 GHz 关联成功。应另测不同频段和监管域场景。原厂 `wifi_init` 已恢复到镜像，现有 SELinux 策略仍缺它的专用域，原厂 init 在开机日志中报告无法启动该辅助程序。本次连接成功不依赖它已运行。
