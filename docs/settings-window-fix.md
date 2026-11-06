# 授权跳转后设置窗口消失：根因与修复

2026-11-06；当前 Apple Silicon / macOS 27.0.1；对照版本 1.0.1 build 5 → build 6。

**当前结论更新：**v1.0.0 / build 7 正式发布后重新下载重装，冷启动首次授权跳转仍出现设置被其它应用遮挡。
失败时策略已经是 regular；重新激活窗口后两条路径各三轮通过。因此下文解释并改善了一个复现路径，
尚未覆盖首次激活的完整行为，不能视为根治。详见 [正式版复验](verification.md)。

## 已确认原因

`SettingsPresenter.show` 创建普通 `NSWindow`，但应用始终处于 `.accessory` 激活策略。
本机关闭系统设置最后一个窗口时，系统没有返回这个菜单栏应用，而是激活此前的普通应用 iTerm2。
其大窗口盖住 TouchChord 设置，视觉上像两个设置窗口同时关闭。

这条复现路径不是应用崩溃、窗口释放或 `hidesOnDeactivate` 引起的隐藏：同一 PID、同一窗口 ID、
`hidden=false`、`onscreen=true` 始终保持，变化发生在前台应用和窗口层叠顺序。
因此此前仅增加窗口强引用、`hidesOnDeactivate=false` 和重新显示设置，没有处理返回顺序。

## 对照证据

| 检查 | build 5 | build 6 |
| --- | --- | --- |
| 设置打开时的激活策略 | accessory | regular |
| 授权辅助功能 → 系统红色关闭按钮 | 返回 iTerm2，原窗口被盖住 | 返回同一个 TouchChord 设置 |
| 授权输入监控 → 系统红色关闭按钮 | 返回 iTerm2，原窗口被盖住 | 返回同一个 TouchChord 设置 |
| PID / 设置窗口 | 72470 / 19284，全程存活 | 87170 / 19335，全程存活 |
| 重复检查 | 两个入口均复现 | 每个入口连续 3 次通过 |
| 用户按原操作复测 | 报告反复出现 | 明确确认两个入口都能返回设置 |

本机原始记录（含桌面应用元数据，不进入 Git）：
`artifacts/settings-baseline-01.jsonl`、`settings-baseline-02.jsonl`、
`settings-fixed-01.jsonl`、`settings-regression-build6.txt`、`settings-user-build6.jsonl`。

## 实现

- `sources/ui/settings-view.swift`：设置窗口打开前切换为 `.regular`，让它参与正常应用切换。
  `SettingsPresenter` 持有窗口并充当 delegate；用户关闭设置时切回 `.accessory`。
- `sources/app/touch-chord-app.swift`：明确最后一个窗口关闭后继续运行。
- 设置打开时 Dock 显示 TouchChord，关闭后退出 Dock；菜单栏和输入功能继续运行。
- 不添加定时抢焦点、不监听其它应用的关闭事件、不重置权限，不修改触摸或按键注入逻辑。

Apple 对 [accessory](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory)
和 [regular](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/regular)
的定义用于解释两种模式。具体返回顺序来自本机对照实验，不把它扩大成所有 macOS 的保证。

## 回归方法

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/verify-settings.swift
```

脚本对两个入口各执行三轮，确认系统设置实际在前台，再按其红色关闭按钮。
必须返回原 PID、原窗口 ID，且设置成为前台最上层普通窗口；不是只检查窗口对象是否存在。
还检查主动关闭设置后进程继续、窗口不可见、策略为 accessory，重新打开后恢复 regular。
这是真实桌面测试，不使用 mock，也不会代用户开启或关闭任何权限。

11 项现有 XCTest 同时通过，但它们只覆盖输入状态逻辑，不能替代桌面回归。
当前未重置权限来复测首次系统授权或系统要求退出的场景；系统要求退出时整个应用仍必须退出。
菜单栏图标偶发缺失属于另一个尚未定位的问题，本次不宣称一并修复。
