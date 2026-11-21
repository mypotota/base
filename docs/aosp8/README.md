# AOSP 8.1 学习路线 · App 开发者的底层进阶（aosp8 系列）

> 环境：AOSP 8.1.0_r1（OPM1.171019.011）· `aosp_x86_64-eng`（已全量编译通过）
> 源码：`~/aosp` · 一键环境脚本：`~/aosp/env_aosp8.sh` · 机器：16 核 / 22G / Ubuntu 26.04
> 创建：2026-11-17
>
> 环境搭建/源码下载/整编踩坑的完整过程不在本系列展开，见笔记
> [AOSP-8.1.0_r1-Ubuntu26.04-编译记录](../../notes/aosp/AOSP-8.1.0_r1-Ubuntu26.04-编译记录.md)。

## 与 docs/aosp（AOSP 10 系列）的关系

`docs/aosp` 是 2026-11 早期基于 AOSP 10 源码树的学习系列（ch00~ch04）；那棵源码树已于
2026-11-17 删除并重建为 AOSP 8.1（迁移记录见上面链接的笔记第六~七节）。旧系列的
**方法论完全适用于 aosp8**（进程地图、日志探针、调用栈调试），但版本相关细节（如
Android 10 的 ATMS 分家）需注意差异。新改动记录从本目录开始。

## 章节进度

| 章节 | 状态 | 完成日期 | 笔记 |
|---|---|---|---|
| ch00 起始篇：Settings 崩溃修复 → 整编 → 启动模拟器 | ✅ | 2026-11-17 | [ch00-起始篇-崩溃修复与整编启动模拟器.md](ch00-起始篇-崩溃修复与整编启动模拟器.md) |
| ch01 起：沿用 docs/aosp 系列的路线（进程地图 → 改动闭环 → 日志 → 调用栈 → Binder） | ⬜ | | |

每章结构：**目标 → 步骤 → 验收标准 → 常见坑**。学完一章：新建 `chNN-标题.md` 沉淀笔记，并在进度表打勾。

## 本系列铁律（每条都踩过坑）

1. **新终端第一句永远是** `source ~/aosp/env_aosp8.sh aosp_x86_64-eng`。直接
   `source build/envsetup.sh && lunch` 会因缺 python2 shim / Jack 变量在编译期必挂。
2. **整编/增量编译都是 `make`（或 `m`）**，目标名不跟源码目录名（`make packages` ❌）。
3. **模拟器带窗口启动**，headless（`-no-window`）会卡死在开机（guest 熵池问题，见 ch00）。

## SkyDroid 实机专题

- [Android 8.1 移植记录](skydroid-android-8.1-port.md)
- [历史故障与实机反馈](skydroid-android-8.1-issues.md)
