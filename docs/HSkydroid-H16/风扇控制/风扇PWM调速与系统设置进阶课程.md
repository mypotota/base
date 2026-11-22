# H16 风扇 PWM 调速与系统设置进阶课程

本课从[风扇控制系统服务实作教程](风扇控制系统服务实作教程.md)开始。先把原生服务的 GPIO 开关后端换成 PWM1，再给 Binder 增加手动档位，最后在 Android 8.1 的「设置 → 显示 → 风扇控制」加入页面。每一节都有独立验收点。

## 第 1 节　理解已验证的硬件能力

实机是 `arowana-rc`，board ID 为 42。常规启动时 GPIO174 是普通输出。临时启动镜像把它复用为 PWM1 后，内核显示 `fa898000.pwm` 接管 pin 174，功能号为 1。

| 测试 | 实机结果 |
| --- | --- |
| PWM 周期 | 7,876,497 ns，约 127 Hz |
| 100% | 占空时间 7,876,497 ns |
| 75% | 占空时间 5,907,372 ns，内核接受设置 |
| 50% | 占空时间 3,938,248 ns |
| 100% → 50% → 100% | 每档约 8 秒，现场确认中间明显变弱，最后恢复 |
| 恢复 | 正常重启后 GPIO174 回到普通输出，PWM1 停用 |

第一版只开放 50% 和 100%。50% 是从已转动状态降下来的实测档位，冷启动和最低稳定档位还要另测。当前无已确认的 RPM 反馈，界面用「占空比」标注。PWM0 由 `sy7203` 使用，始终保留它的配置。 [Linux PWM 接口](https://www.kernel.org/doc/html/v6.9/driver-api/pwm.html)

## 第 2 节　先让板级配置接管 PWM1

请在现有 boot 重打包流程中保留这项修改。实机验证过的修改只针对 DT 段中 `board-ids = <0x2a>` 那棵设备树。

| 位置 | 改动 |
| --- | --- |
| `/soc/pinctrl@f9009000/gpio_pin/gpio174` | 去掉对 GPIO174 的默认 GPIO 复用 |
| `/soc/pinctrl@f9009000/arowana_p0_pwm_pin` | 保留 `pwm0`，增加下方 `pwm1` 子节点 |
| `/soc/pwm@fa898000` | 保留现有 `pinctrl-0`，它已指向 `arowana_p0_pwm_pin` |
| boot ramdisk 的 `init.arowana-rc.rc` | 去掉 GPIO174 的 export、direction、value、chown 和 chmod；保留同文件里的 RC 服务修复 |

```dts
pwm1 {
    pins = "174";
    function = "1";
    bias-disable;
};
```

启动后只检查复用，先确认没有应用或 daemon 抢写 PWM1。

```bash
ADB_BIN="$HOME/Android/Sdk/platform-tools/adb"
ADB_SERIAL=e2d72141

# 预期 174 归 fa898000.pwm，function 1。另一条 PWM 列表用于核对 PWM0 归属。
"$ADB_BIN" -s "$ADB_SERIAL" shell 'su 0 sh -c "grep \"pin 174 \" /sys/kernel/debug/pinctrl/f9009000.pinctrl/pinmux-pins; cat /sys/kernel/debug/pwm"'
```

先保留可启动的 boot/system 备份。当前 boot 的 DT 段包含多个连续 DTB，重打包时只替换 board ID 42 的 DTB，其余 DTB 保持原样，更新 DT 段长度和 boot 头的组件摘要。先用 `fastboot boot` 验证引脚复用。实验完成后可正常重启恢复原 boot。正式部署时将 PWM 版 boot 和 PWM 版 system 配对，同一次刷写两者。

## 第 3 节　把基础服务切换到 PWM 后端

### 3.1 让 init 准备通道

修改 `device/skydroid/arowana_rc/legacy-init/h16_fand.rc`。保留原来的 `service h16_fand`、用户、组和私有 socket。把原来的开机触发段换成这一段。PWM1 由 init 导出一次，daemon 只操作已导出的 PWM1。

```text
on property:sys.boot_completed=1
    write /sys/class/pwm/pwmchip0/export 1
    wait /sys/class/pwm/pwmchip0/pwm1/enable
    chown system system /sys/class/pwm/pwmchip0/pwm1/enable
    chown system system /sys/class/pwm/pwmchip0/pwm1/period
    chown system system /sys/class/pwm/pwmchip0/pwm1/duty_cycle
    chmod 0660 /sys/class/pwm/pwmchip0/pwm1/enable
    chmod 0660 /sys/class/pwm/pwmchip0/pwm1/period
    chmod 0660 /sys/class/pwm/pwmchip0/pwm1/duty_cycle
    start h16_fand
```

核对三个文件的真实路径和标签，给 `enable`、`period`、`duty_cycle` 单独的 sysfs 类型。保留基础版的 daemon 执行标签及私有 socket 规则。用实际路径填入 `genfs_contexts`，去掉开头的 `/sys`。策略层允许 daemon 读写这三项，允许 init 设置它们的文件属性。export 权限只给 init。

```bash
# 在已导出 PWM1 后运行，输出用于编写和验证 genfscon。
"$ADB_BIN" -s "$ADB_SERIAL" shell 'su 0 sh -c "for n in enable period duty_cycle; do readlink -f /sys/class/pwm/pwmchip0/pwm1/\$n; ls -lZ /sys/class/pwm/pwmchip0/pwm1/\$n; done"'
```

可把如下规则追加到基础教程的 `system/sepolicy/private/h16_fand.te`，并在 `genfs_contexts` 中添加三条相应映射。

```text
type sysfs_h16_pwm1, fs_type, sysfs_type;
allow h16_fand sysfs_h16_pwm1:file rw_file_perms;
allow init sysfs_h16_pwm1:file { getattr open setattr };
```

若 export 的现有标签拦住 init，使用该节点的实测路径和独立标签补充 `open/write`。PWM0 和共享 PWM 控制器的其他属性无需给 daemon 写权限。

### 3.2 修改 h16_fand.cpp

保留基础版的 socket、超时、温度读取和单线程循环。把 GPIO 辅助函数换成下面这些 PWM 辅助函数，继续复用 `readNumber()`。

```cpp
constexpr char kEnable[] = "/sys/class/pwm/pwmchip0/pwm1/enable";
constexpr char kPeriod[] = "/sys/class/pwm/pwmchip0/pwm1/period";
constexpr char kDuty[] = "/sys/class/pwm/pwmchip0/pwm1/duty_cycle";
constexpr int kPeriodNs = 7876497;

bool writeNumber(const char* path, int value) {
    const int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return false;
    char buf[32];
    const int length = std::snprintf(buf, sizeof(buf), "%d\n", value);
    const bool ok = length > 0 && length < static_cast<int>(sizeof(buf)) &&
            write(fd, buf, static_cast<size_t>(length)) == length;
    close(fd);
    return ok;
}

int readPwmPercent() {
    const int enabled = readNumber(kEnable);
    if (enabled == 0) return 0;
    const int period = readNumber(kPeriod);
    const int duty = readNumber(kDuty);
    if (enabled != 1 || period <= 0 || duty < 0 || duty > period) return -1;
    return static_cast<int>((100LL * duty + period / 2) / period);
}

bool writePwmPercent(int percent) {
    if (percent != 0 && percent != 50 && percent != 100) return false;
    const int enabled = readNumber(kEnable);
    if (enabled != 0 && enabled != 1) return false;
    if (percent == 0) {
        // 先把有效输出降为零，再禁用通道。
        return writeNumber(kDuty, 0) &&
                (enabled == 0 || writeNumber(kEnable, 0)) &&
                readPwmPercent() == 0;
    }
    if (readNumber(kPeriod) != kPeriodNs) {
        if (enabled != 0 || !writeNumber(kDuty, 0) ||
                !writeNumber(kPeriod, kPeriodNs)) return false;
    }
    const int duty = static_cast<int>(1LL * kPeriodNs * percent / 100);
    return writeNumber(kDuty, duty) &&
            (enabled == 1 || writeNumber(kEnable, 1)) &&
            readPwmPercent() == percent;
}
```

`readPwmPercent()` 只回读控制器状态。首次验证时同时看实际风扇表现，尤其确认 `0%` 加禁用之后确实停止。GPIO/风扇服务的旧写入逻辑在 PWM 版本中应一并退役。

在 `FanControl` 中增加如下字段。基础版的 `setTimedMode()` 延用 10 秒到期逻辑。

```cpp
int manualPercent_ = 100;
Clock::time_point boostUntil_{};
```

把基础版 `FanControl::update()` 换成下面的实现。启动升速是 2 秒起步值，后续按实际冷启动测试调整。

```cpp
Result update(char command) {
    temperature_ = readMaxTemperature();
    const auto now = Clock::now();
    const int current = readPwmPercent();
    const bool cancelOff = mode_ == kOff &&
            (temperature_ < 0 || temperature_ >= kLow);
    if (mode_ != kAuto && (now >= deadline_ || cancelOff)) mode_ = kAuto;

    Result result = kOk;
    switch (command) {
        case 'A': mode_ = kAuto; break;
        case '1':
        case '5':
            if (current <= 0) {
                boostUntil_ = now + std::chrono::seconds(2);
            }
            manualPercent_ = command == '5' ? 50 : 100;
            setTimedMode(kOn, now);
            break;
        case '0':
            if (temperature_ < 0 || temperature_ >= kLow) {
                result = kRejected;
            } else {
                setTimedMode(kOff, now);
            }
            break;
        case '?': break;
        default: return kRejected;
    }

    // 自动档沿用基础版温度回差，安全兜底优先级最高。
    int target = current == 0 ? 0 : 100;
    if (temperature_ < 0 || temperature_ >= kHigh || cancelOff) {
        target = 100;
    } else if (mode_ == kOff) {
        target = 0;
    } else if (mode_ == kOn) {
        target = now < boostUntil_ ? 100 : manualPercent_;
    } else if (temperature_ <= kLow) {
        target = 0;
    }
    // 零占空比也可能对应仍使能的输出，关机路径要确保它被禁用。
    if ((target != current || (target == 0 && readNumber(kEnable) != 0))
            && !writePwmPercent(target)) {
        return kIoError;
    }
    return result;
}
```

让 `reply()` 输出五列，前四列的含义和顺序沿用基础版。第一列是使能状态，第五列是实际回读占空比。没有反馈的字段用 `-1`。

```cpp
const int percent = readPwmPercent();
const int active = percent < 0 ? -1 : (percent > 0 ? 1 : 0);
const int size = std::snprintf(line, sizeof(line), "%d %d %d %d %d\n",
        active, static_cast<int>(mode_), static_cast<int>(result),
        temperature_, percent);
```

自动温控先维持 `0/100` 和原有回差。等测出最低稳定占空比及温控效果后，再增加一个中温档，另外为中温档设置进入和退出阈值。手动 50% 遇到高温时已经能升到 100%。

## 第 4 节　给 Binder 增加调速接口

在 `frameworks/base/core/java/android/os/IH16FanService.aidl` 的原有两个方法之后增加 `int[] setDutyPercent(int percent);`。保持既有方法位置，按同次构建一起部署 daemon、Framework 与 Settings。

在 `H16FanService.java` 的 `BinderService` 中加入以下方法。同步把 `request()` 的字段数量和结果数组长度改成 5，所有通信失败分支返回 `new int[] {-1, -1, 2, -1, -1}`。更新 `dump()` 和 shell 帮助输出的列说明。若要从 ADB 测低档，可以给基础版 shell 命令增加 `case "low": command = '5'; break;`，沿用原有 debug root 权限检查。

```java
@Override
public int[] setDutyPercent(int percent) {
    getContext().enforceCallingPermission(CONTROL, "Changing H16 fan duty");
    if (percent != 50 && percent != 100) {
        throw new IllegalArgumentException("Supported H16 fan duty is 50 or 100");
    }
    return request(percent == 50 ? '5' : '1');
}
```

先用 `dumpsys h16_fan` 看五列，再用 `su 0 cmd h16_fan on` 和 `su 0 cmd h16_fan low` 比较。低档若从停机请求，先读到 100%，约 2 秒后才降到 50%。10 秒到期后回到 AUTO。

## 第 5 节　在 Android 设置中加入风扇页面

### 5.1 建入口和权限

改动都在当前 Oreo 的 `packages/apps/Settings` 树。Settings 已使用平台签名，实际客户端域仍需用 `ps -AZ` 核对。 [AOSP 8.1 DisplaySettings 源码](https://android.googlesource.com/platform/packages/apps/Settings/+/android-8.1.0_r1/src/com/android/settings/DisplaySettings.java)

1. 在 `AndroidManifest.xml` 加入 `android.permission.READ_H16_FAN` 与 `android.permission.CONTROL_H16_FAN` 两个 `uses-permission`，与基础项目声明一致。
2. 在 `src/com/android/settings/core/gateway/SettingsGateway.java` 的 `ENTRY_FRAGMENTS` 加入 `H16FanSettings.class.getName()`，并导入 `com.android.settings.display.H16FanSettings`。
3. 在 `res/xml/display_settings.xml` 的 `PreferenceScreen` 中加入：
   
   ```xml
   <Preference
       android:key="h16_fan"
       android:title="@string/h16_fan_title"
       android:fragment="com.android.settings.display.H16FanSettings" />
   ```

4. 在 `DisplaySettings.java` 的 `buildPreferenceControllers()` 注册一个设备限定的 `AbstractPreferenceController`。下方是它的源码。在现有列表返回前加入 `controllers.add(new H16FanPreferenceController(context));`，列表变量名以本地文件为准，并导入对应类。
5. 在基础策略 `h16_fand.te` 为实测的 Settings 域添加 `service_manager find`。这棵树的系统 UID 平台应用通常是 `system_app`，对应规则为 `allow system_app h16_fan_service:service_manager find;`。Binder 写操作继续由签名权限限制。Settings 无需访问 sysfs。

新建 `src/com/android/settings/display/H16FanPreferenceController.java`。

```java
package com.android.settings.display;

import android.content.Context;
import android.os.SystemProperties;

import com.android.settingslib.core.AbstractPreferenceController;

public final class H16FanPreferenceController extends AbstractPreferenceController {
    public H16FanPreferenceController(Context context) {
        super(context);
    }

    @Override
    public boolean isAvailable() {
        return "arowana-rc".equals(SystemProperties.get("ro.product.device"));
    }

    @Override
    public String getPreferenceKey() {
        return "h16_fan";
    }
}
```

### 5.2 定义页面和文本

新建 `res/xml/h16_fan_settings.xml`。

```xml
<?xml version="1.0" encoding="utf-8"?>
<PreferenceScreen xmlns:android="http://schemas.android.com/apk/res/android"
    android:title="@string/h16_fan_title">
    <Preference android:key="h16_fan_status"
        android:title="@string/h16_fan_status" android:selectable="false" />
    <Preference android:key="h16_fan_auto" android:title="@string/h16_fan_auto" />
    <Preference android:key="h16_fan_on" android:title="@string/h16_fan_on" />
    <Preference android:key="h16_fan_off" android:title="@string/h16_fan_off" />
    <Preference android:key="h16_fan_low" android:title="@string/h16_fan_low" />
</PreferenceScreen>
```

添加 `res/values/h16_fan_strings.xml`。这是课程用中文文本。若产品支持多语言，将中文放到 `values-zh-rCN` 并在默认资源提供对应翻译。

```xml
<resources>
    <string name="h16_fan_title">风扇控制</string>
    <string name="h16_fan_status">当前状态</string>
    <string name="h16_fan_auto">自动温控</string>
    <string name="h16_fan_on" formatted="false">短时打开 · 100%</string>
    <string name="h16_fan_off">短时关闭</string>
    <string name="h16_fan_low" formatted="false">短时低速 · 50%</string>
    <string name="h16_fan_unavailable">风扇服务暂不可用</string>
    <string name="h16_fan_rejected">温度偏高或未知，关闭请求已拒绝</string>
    <string name="h16_fan_running">已使能</string>
    <string name="h16_fan_stopped">已关闭</string>
    <string name="h16_fan_mode_manual">短时手动</string>
    <string name="h16_fan_status_summary">%1$s · %2$s · 占空比 %3$d%%</string>
</resources>
```

### 5.3 实现 Fragment

新建 `src/com/android/settings/display/H16FanSettings.java`。页面上的按钮发一次请求，状态以 Binder 回读为准。每轮刷新完成后才调度下一轮。离开页面时丢弃过期结果。关闭请求被温控拒绝时在页面上提示，手动档到期后下一次刷新显示自动模式。

```java
package com.android.settings.display;

import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.IH16FanService;
import android.os.RemoteException;
import android.os.ServiceManager;
import android.support.v7.preference.Preference;
import android.widget.Toast;

import com.android.internal.logging.nano.MetricsProto.MetricsEvent;
import com.android.settings.R;
import com.android.settings.SettingsPreferenceFragment;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class H16FanSettings extends SettingsPreferenceFragment {
    private static final int QUERY = -1;
    private static final int LOW = 3;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Runnable refresh = () -> submit(QUERY);

    private Preference status;
    private Preference[] controls;
    private boolean visible;
    private int ticket;

    @Override
    public int getMetricsCategory() {
        return MetricsEvent.VIEW_UNKNOWN;
    }

    @Override
    public void onCreatePreferences(Bundle savedState, String rootKey) {
        super.onCreatePreferences(savedState, rootKey);
        addPreferencesFromResource(R.xml.h16_fan_settings);
        status = findPreference("h16_fan_status");
        controls = new Preference[] {
            findPreference("h16_fan_auto"),
            findPreference("h16_fan_on"),
            findPreference("h16_fan_off"),
            findPreference("h16_fan_low")
        };
        for (int i = 0; i < controls.length; ++i) {
            final int command = i;
            controls[i].setOnPreferenceClickListener(preference -> {
                submit(command);
                return true;
            });
        }
    }

    @Override
    public void onStart() {
        super.onStart();
        visible = true;
        setControlsEnabled(false);
        submit(QUERY);
    }

    @Override
    public void onStop() {
        visible = false;
        ++ticket;
        main.removeCallbacks(refresh);
        super.onStop();
    }

    @Override
    public void onDestroy() {
        worker.shutdownNow();
        super.onDestroy();
    }

    private void submit(int command) {
        if (!visible) return;
        main.removeCallbacks(refresh);
        final int request = ++ticket;
        if (command != QUERY) setControlsEnabled(false);
        worker.execute(() -> {
            final int[] snapshot = callService(command);
            main.post(() -> {
                if (!visible || request != ticket) return;
                final boolean available = snapshot != null && snapshot.length == 5
                        && snapshot[0] >= 0 && snapshot[2] != 2 && snapshot[4] >= 0;
                if (available) {
                    final int state = snapshot[0] == 1
                            ? R.string.h16_fan_running : R.string.h16_fan_stopped;
                    final int mode = snapshot[1] == 0
                            ? R.string.h16_fan_auto : R.string.h16_fan_mode_manual;
                    status.setSummary(getString(R.string.h16_fan_status_summary,
                            getString(state), getString(mode), snapshot[4]));
                    if (command != QUERY && snapshot[2] == 1) {
                        Toast.makeText(getContext(), R.string.h16_fan_rejected,
                                Toast.LENGTH_SHORT).show();
                    }
                } else {
                    status.setSummary(R.string.h16_fan_unavailable);
                }
                setControlsEnabled(available);
                main.postDelayed(refresh, 1000);
            });
        });
    }

    private static int[] callService(int command) {
        try {
            final IH16FanService service = IH16FanService.Stub.asInterface(
                    ServiceManager.getService("h16_fan"));
            if (service == null) return null;
            if (command == QUERY) return service.getState();
            if (command == LOW) return service.setDutyPercent(50);
            return service.setMode(command);
        } catch (RemoteException | SecurityException error) {
            return null;
        }
    }

    private void setControlsEnabled(boolean enabled) {
        for (Preference control : controls) control.setEnabled(enabled);
    }
}
```

该页面提供明确的「打开」「关闭」「自动」操作。关闭是短时请求，受温控保护。50% 入口同样会自动退出，适合先验收硬件和软件链路。界面把占空比与使能状态分开显示。

## 第 6 节　构建和验收作业

```bash
# 在 H16 产品上先编译各模块，确保 AIDL、Settings 资源与策略都能生成。
source "$HOME/aosp/env_aosp8.sh" skydroid_arowana_rc-userdebug
make -j8 h16_fand framework services Settings sepolicy file_contexts.bin \
    plat_file_contexts nonplat_file_contexts plat_service_contexts

# 再构建完整 system.img，由产品打包规则安装新版模块和 init 配置。
make -j8 systemimage
```

重打 PWM 版 boot 时，保持设备树的已验证修改，合入本次 SELinux 和 ramdisk 配置。刷写和回退步骤参见[安卓8.1移植记录](../移植与故障/安卓8.1移植记录.md)。正常启动后按顺序验收：

| 步骤 | 通过条件 |
| --- | --- |
| 验证 pinmux | pin 174 归 PWM 控制器，功能 1；PWM0 保留原归属 |
| 验证 daemon | `getprop init.svc.h16_fand` 为 `running`，`dumpsys h16_fan` 返回五列 |
| 核对读回 | 查询 `cat /sys/class/pwm/pwmchip0/pwm1/enable` 和 `duty_cycle`，与界面一致 |
| 验证 100% 和 50% | 先观察全档，再选低档，气流或声音变弱；从停机选低档时先全档启动 |
| 验证关闭和自动 | 低温可短暂关闭，到期回 AUTO。用模拟高温和测温失败覆盖拒绝及全档保护 |
| 验证设置页面 | 从「显示」进入，四项操作可用；切出再返回能从系统服务重新读回 |
| 验证错误 | 暂停后端时页面显示服务不可用；通过 AVC 排查 Settings 的 Binder 查找权限或 daemon 的 sysfs 权限 |

可从电脑直接打开系统显示设置，随后点进「风扇控制」。入口未显示时核对产品别名、控制器是否已加入列表，以及「高级」折叠区。

```bash
# 读取风扇的五列状态。第四列是温度，第五列才是占空比。
"$ADB_BIN" -s "$ADB_SERIAL" shell dumpsys h16_fan

# 打开 Android 设置中的显示页面，从这里进入风扇控制子页。
"$ADB_BIN" -s "$ADB_SERIAL" shell am start -a android.settings.DISPLAY_SETTINGS
```

调速量化实验可以用外部转速计记录 100%、75%、50% 的稳态 RPM，分别验证冷启动和由高档降速。这样可以给下一版温控分档选定可靠的档位及启动助推时间。
