# H16 AUX1 与 AUX2 旋钮接口

手册中的面板编号 13 为 AUX1，编号 12 为 AUX2。编号用来识别面板上的旋钮。它们在 SDK 数组中的下标、方向和范围仍需实机测量。

## 应用层入口

官方 RCSDK 示例提交 `d9c6bca` 使用 `rcsdk-v1.9.2.aar` 和 `h16_airlink.aar`。示例先调用 `RCSDKManager.initSDK(...)` 和 `RCSDKManager.connectToRC()`，再用 `KeyManager.listen(RemoteControllerKey.KeyH16Channels, listener)` 持续接收 `IntArray`。可用官方 `ReadRCButtonHelper.java` 对照 Java 接法，退出时用 `KeyManager.cancelListen(listener)` 注销。

静态检查 SDK 字节码发现，H16 实现创建了本地套接字通道，涉及 `uart3app`、`uart3endpoint` 和 `uart0app`。原厂 `rc_service` 二进制含 `uart0app`。这些线索说明应优先检查原厂服务和本地套接字。具体哪个套接字承载旋钮数据，以及 `rc_service` 和 SDK 回调之间的完整路径，仍需验证。

## 当前 ROM 检查

```bash
ADB_BIN="$HOME/Android/Sdk/platform-tools/adb"
ADB_SERIAL='e2d72141'

# 查询 init 中原厂遥控器服务的当前状态。
"$ADB_BIN" -s "$ADB_SERIAL" shell getprop init.svc.rc_service

# 核对启动时使用的 RC 配置是否实际存在。
"$ADB_BIN" -s "$ADB_SERIAL" shell ls -l /tmp/rc_service_config.ini

# 读取设备的 Unix 套接字表，再在电脑端筛选 SDK 涉及的名称。
"$ADB_BIN" -s "$ADB_SERIAL" shell 'su 0 cat /proc/net/unix' |
  rg 'uart0app|uart3app|uart3endpoint'
```

实测服务为 `restarting`，配置文件缺失，套接字筛选无匹配。前次启动日志还记录了 `rc_service` 的 SELinux 域问题。此前转动两个旋钮时，`getevent` 未采到可用于旋钮标定的事件，IIO 采样也未得到可区分的变化。

## 通道标定

用只记录通道的 SDK 测试程序，记录设备型号、连接结果、回调时间及完整数组。保持其他控件静止，依次单独把 AUX1、AUX2 从一个端点缓慢转到另一个端点，再转回。对比变化的数组下标，重复一次确认，并记录零基下标、两个端点的数值、机械中位数值和转动方向。如果多个下标随同一旋钮变化，保留全部结果并记录原厂通道设置。如果没有任何回调，先检查服务和套接字，再进行标定。

- [H16 官方手册](https://yunzhuo.skydroid.xin/media/20241106185215rG.pdf)
- [官方 SDK 通道采集示例](https://gitee.com/skydroid/rcsdk-demo/blob/master/app/src/main/java/com/skydroid/rcsdkdemo/ReadRCButtonHelper.java)
