# 2／3／4 指触摸按键配置

当前发布版本为 1.0.1（build 14）。v1.0.0 的标签、附件和恢复脚本保持冻结。

| 精确手指数 | 默认键位 | 下拉候选 |
| --- | --- | --- |
| 2 | Control ⌃ | Command ⌘、Option ⌥、Control ⌃、Shift ⇧、Return ↩、Esc ⎋、不触发 |
| 3 | Command ⌘ | 同上 |
| 4 | Option ⌥ | 同上 |

0、1、5 指及以上不触发，并释放当前模拟键。没有一指映射、五指映射、组合修饰键或 Fn 支持。
修饰键保持到换档或抬起；回车、Esc 稳定触摸后发送一对 Down/Up，持续触摸不会重复触发。
同名物理键按住时跳过本次动作，避免合成 Up 打断物理按键。模拟 Esc 不被当作物理 Escape 紧急释放。
各档独立保存，可选择相同键位。任何手指数变化都立即释放旧键，再对新档位进行激活防抖；
即使新旧映射相同，也遵循该规则。启动、修改映射、重新连接或紧急释放后，必须先全部抬起才重新启用。
选择“不触发”只关闭该档，全部关闭则整体停用。

## 系统设置前提

先关闭“系统设置 → 触控板 → 光标与点按 → 轻点来点按”，然后重新检查并连接。
应用只读取设置，不替用户修改系统偏好。启动、准备按下时及保持期间每 500 ms 重新检查；
不在闲置时轮询。开启或无法确认时暂停，活动中的虚拟修饰键会请求释放。

读取使用 CFPreferences 和当前机器核实的 `com.apple.AppleMultitouchTrackpad` / `Clicking`。
CFPreferences 是公开 API，但该系统偏好键不是 Apple 承诺稳定的接口；其它系统版本必须核实。
不存在或无法解析时不推定“已关闭”。[Apple 偏好读取说明](https://developer-rno.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/AccessingPreferenceValues/AccessingPreferenceValues.html)。

关闭轻点来点按不会关闭两指滚动、缩放或系统多指手势。两指映射会影响这些操作；
需要保留日常双指手势时可将 2 指设为“不触发”。精确匹配意味着 3→4 指会换键，4→5 指会释放。

## 按键来源和恢复

IOHID 单独读取每台物理键盘的左右 Command、Option、Control、Shift（usage 0xe0–0xe7），以及回车、Esc（0x28/0x29）。
释放前刷新物理状态：同一种物理键仍按住时，仅清理虚拟来源，不发送该键的 Up。
物理键先释放而触摸仍保持时，输入过滤器继续合并虚拟来源。
CGEvent 使用对应修饰键事件和标志，保留无关修饰键与 Caps Lock；快速切换及恢复时不重新带入旧虚拟键。
Return、Esc 的 Down/Up 保留投递时的修饰键标志，后续换档不会改写已排队的单次输入。
参见 [Apple CGEventFlags](https://developer.apple.com/documentation/coregraphics/cgeventflags)。

恢复记录覆盖六种键，并保留旧版 Command 标记。权限可用且会话未暂停时，先处理遗留按键释放，
待事件过滤器确认后再检查触摸激活条件；轻点来点按、停用或全部档位关闭不会阻断这一步恢复。
释放确认超时会暂停并保留记录。正常退出后才能用 v1.0.0 恢复脚本回退；
旧版只理解 Command 标记，不能清理新版崩溃遗留的其它修饰键。
若进程被强制结束，先抬起触控板并按下、松开受影响的物理键，再恢复原版。
固定签名证书、Bundle ID `local.trikey.app`、安装路径均沿用，未重置权限。

## 开发阶段验证记录

2026-11-06：20 项 XCTest 通过，覆盖精确档位、候选键位、不触发、抖动、相同映射换档、
零防抖、紧急释放重新激活、数据中断、幂等、物理来源共存、排队事件恢复、单次触发和修饰键切换到单次按键。
Release 构建和固定签名校验通过。测试使用纯状态逻辑，没有新增 mock 或 stub。
真实设置界面的 3 档 × 7 候选共 21 项选择与偏好保存检查通过，日志：
`artifacts/modifier-settings-build-9.log`。后续仅调整回车的显示名称，最终为 `Return ↩`。
重启回读确认 Control／Command／Option 配置保留、两项权限仍已授权、轻点来点按已关闭、
恢复标记为空；没有重置 TCC 或更换签名证书。安装路径为 `/Applications/TouchChord.app`。
本轮用户已确认 Shift、Command、Option 及抬起后的普通输入正常；只读文本探针记录到对应事件标志、
选区变化和释放，日志位于本机 `artifacts/modifier-surface-20261106-2036.jsonl`，不包含输入文本。
用户暂时不方便继续人工测试，Control、回车、Esc 及新增物理键共存测试待完成；
临时测试映射已恢复为 Control／Command／Option。单元测试不等于真实设备的完整稳定性验收。
v1.0.0 已有冷启动授权窗口被遮挡的已知问题，本次未修改窗口生命周期，也未宣称解决。

菜单栏图标使用原生矢量触控板底图：空闲显示三个触点，生效时叠加当前按键符号。
七种状态均为固定 18×18 的模板图像，明暗外观预览见本机 `artifacts/menu-icons-preview.png`。
Return、Esc 标识表示已触发一次，持续到换档或抬起；不改变单次输入行为。
实现依据：[Apple NSImage 模板图像说明](https://developer.apple.com/documentation/appkit/nsimage/istemplate)。

此前验证使用本地开发包 `build/touch-chord-1.1.0-arm64.dmg`（build 13），并非 v1.0.1 发布包。
镜像校验通过，SHA-256：`e6a6dbc860dea3868b3ad0fbd3e6e9efa62c5589382ef317114a087acbb47ec8`。
本机菜单栏已回读到新底图，系统条目宽度为 36 pt（内部图像 18 pt）；
截图为 `artifacts/menu-icon-installed.png`。七种状态的渲染检查通过，未为图标测试注入全局按键。
安装后的应用与构建包逐文件一致；验收后移除 build 目录中的重复 `.app`，保留 DMG 和正式安装位置。
v1.0.0 ZIP、版本和签名已通过现有恢复脚本的 `--verify-only` 检查，本次未修改该脚本或已发布附件。

v1.0.1 的发布验证与未验证边界见 [发布说明](releases/v1-0-1.md)。
设置回归脚本在测试前保存全部原始映射和持久值，选择或保存验证失败时仍恢复已触及档位，
并分别核对界面和持久配置；无法完整恢复时以失败退出并报告原始快照。
`--set` 是显式设置命令，保持写入；`--restore-defaults` 仅在完整回归成功时应用默认映射，失败则恢复运行前配置。
