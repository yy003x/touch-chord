# TriKey Phase 1 技术验证

日期：2026-11-06。状态：**核心可行性验证完成，允许进入 Phase 2**。
范围仅为当前开发设备，不表示最终产品、跨版本兼容和全部异常场景已验收。

## 目标和判定

产品只提供一个通用 Command（⌘），无左右 Command 配置。
采用需求第 4.1 节的明确阈值：触摸数达到三指时激活，减少到两指或以下时释放，四指仍保持。
区分物理输入来源只是为了避免释放用户实际仍按着的 Command。

待办：

- [x] 核对设备、开发环境、公开及私有 API。
- [x] 阅读 Touchy 的相关源码并评估可复用内容。
- [x] 实测内置触控板原始回调、0–4 指和静止三指。
- [x] 实测物理 Command 与 CGEvent 状态表的区别。
- [x] 实测成对的 Command 发送与释放回读。
- [x] 触摸驱动的组合键、物理 Command 共存和释放实验。
- [x] 汇总 Phase 1 判定。
- [ ] 进行中：正式 MVP、菜单栏和交付验证。

## 当前开发设备

| 项目 | 现场结果 |
|---|---|
| CPU 架构 / 机型 | arm64 / Mac16,7 |
| 系统 | macOS 27.0.1，26A434 |
| 工具链 | Swift 6.4；完整 Xcode 27.0，27A266a |
| 触控设备 | Apple Internal Keyboard / Trackpad；`MT Built-In = Yes`；`ForceSupported = Yes` |
| 动态枚举 | 1 个设备，`MTDeviceIsBuiltIn` 返回 true，启动后 `MTDeviceIsRunning` 为 true |
| 当前宿主权限 | AX、ListenEvent、PostEvent 预检查均为 true |

最初系统选中的 Command Line Tools 缺少 XCTest；指定已安装 Xcode 的 `DEVELOPER_DIR` 后，
2 项 XCTest 通过。没有变更系统开发工具选择。测试仅验证本地 ABI 布局假设及接触状态分类，
不替代真实硬件、按键投递或稳定性验收。

## Touchy 参考结论

检查对象：[gugahoi/touchy，598abee713cb0396f9ec951a85fbcc8c316a9729](https://github.com/gugahoi/touchy/tree/598abee713cb0396f9ec951a85fbcc8c316a9729)。

| 部分 | 对 TriKey 的价值与边界 |
|---|---|
| `CMultitouch` 私有 ABI 声明 | 可研究触点布局和回调接入；不构成官方兼容保证 |
| `MultitouchReader` | 可借鉴注册、注销、休眠后重新枚举和有限重试；TriKey 需筛选内置设备、核对真实启动结果 |
| `Finger.isTouching` | 仅统计 state 3/4；本机真实数据已证明不能直接使用 rawCount |
| `GestureRecognizer` | 面向滑动/轻点及峰值手指数，不能直接用于持续修饰键的实时阈值 |
| `KeyEmitter` | 发送一次完整快捷键或点击，没有持续修饰键及物理来源状态管理 |
| `Permissions`、`LoginItem`、`MenuBarExtra` | 可借鉴原生 API 选择；正式应用还需授权失败反馈和状态回读 |
| 打包脚本 | 可借鉴 SwiftPM → app bundle → codesign 的流程；不执行其签名配置脚本 |

当前树中未发现 LICENSE，GitHub 元数据 `license = null`。本项目只研究设计与 API 用法，
未复制 Touchy 的实现或素材，也未增加该项目为依赖。其 Package 使用 Swift 5 语言模式；
TriKey 探针启用了 Swift 6。线程安全不能直接继承其实现假设。

## 触摸实测

证据：`Artifacts/touch-01.jsonl`、`Artifacts/touch-02.jsonl`；用户完成了指定手指数操作并回复“做完了”。
第二段监听覆盖第一段时限之后的操作；两段有约 4 秒重叠，不能累加为独立样本量。

- 第一段：4,551 帧，异常帧 0；实际接触数 0、1、2、3、4 均出现。
- 16:29:36 至 16:29:44，三指接触约 8.1 秒；另一段三指接触约 7.2 秒。
- 单指、双指、四指的稳定保持也被观察到。
- `[1,4,4]` 的原始数量为 3，但实际接触数为 2；`[4,4,5,5]` 的原始数量为 4，实际为 2。
- 全部抬起后，接触状态先进入 5/6/7，再出现空帧。因此只统计 3/4，不能把 `numFingers` 直接当作真实手指数。
- 这轮各档之间存在全部抬起，尚不能据此认定连续 `4 → 3 → 2` 转换已验收。

空闲时可长期没有回调，日志 `maxFrameGapSeconds` 包括空闲，不能作为触摸期间丢帧结论。
静止三指时确实持续有帧，后续可在有效保持期间检测数据中断；正式阈值还需长期实测。
当前 Swift 布局检查为 96 字节 stride，state 偏移 20；这是本地布局假设，真实帧合理性验证
仍不等于跨版本 ABI 保证。

## Command 实测

### 物理来源

证据：`Artifacts/keyboard-01.jsonl`，用户完成物理按键操作并回复“按键做完了”。
IOHID 的键盘 usage page 7、usage E3/E7 分别给出 Command 按下和释放，双键交错也可观察。
本机右 Command 按下时，`CGEventSource.keyState(.hidSystemState, key: 55)` 仍可为 true，
key 54 为 false；因此不能用这两个 CG 状态值准确区分物理来源。

IOHID 回调早于相应 CG 事件数毫秒；在 HID 回调内部读取 CG 状态表仍可能读到上一次状态。
后续来源管理须消费 HID 值本身，并处理初始状态、设备移除、权限变化与监听失效。

### 成对事件

| 实验 | 按下后 200 ms | 释放后 | 判定 |
|---|---|---|---|
| private source + session 入口 | 在监听中见到按下，但 session Command flag/keyState 已为 false | false | 不足以持续保持；本轮未追踪所有系统事件，不能断言具体清除原因 |
| combinedSession source + HID 入口 | HID/session Command flag 和 session keyState 均为 true | 均为 false | 短脉冲发送和释放回读通过 |

证据：`Artifacts/pulse-01.jsonl`、`Artifacts/pulse-hid-01.jsonl`。
两次实验 IOHID 物理 Command 均为 false，没有将模拟按键误报为真实按键。
HID 入口会改变 `hidSystemState`，所以它不能作为纯硬件来源。这是选择 IOHID 独立来源记录的现场依据。

短脉冲通过不代表长时间保持、真实组合键或物理按键共存已通过。
当前 `hold` 实验为全局修饰键补充事件过滤，并设置 30 秒上限和 500 ms 数据中断释放；
它只是 Phase 1 可行性实验，不是正式 `ModifierKeyController`。

### 交互实验的当前证据

`Artifacts/hold-01.jsonl`：用户明确反馈“还没完成测试”，不计为组合键验收通过。
该轮确实触发当时设置的 10 秒自动释放与 Escape 停止。旧探针摘要仅统计 pulse 事件，
因此其中 `globalKeyInjectionAttempted=false` 不准确；具体 `virtual_command` 和 `command_event`
记录证明有注入。后续版本已修正摘要统计，不改写历史日志。

实验文本区加入原生 Edit 菜单后，以定向到本进程的真实 CGEvent Command+A 验证：
`Artifacts/target-01.jsonl` 中选中 31/31 个字符。它验证测试文本区，不能替代触摸驱动实验。

`Artifacts/hold-02.jsonl` 当前观察：

- 三指保持期间，输入事件包含 Command，原生 NSTextView 实际全选，出现 `text_selection length=31/textLength=31`。
- 16:46:51 触摸触发，16:46:52 物理 Command 按下，16:46:56 触摸结束；
  程序没有发送 Command Up（`physical=true, postedUp=false`）。
- 16:46:57 的按键仍带 Command；16:46:59 物理 Command 释放后，
  flagsChanged 为 false；16:47:05 的按键也为 false。
- 用户确认本轮三指全选、触摸释放和物理键仍按下的行为“两项都符合”。

`Artifacts/hold-04.jsonl` 补充反向交错：16:51:36 物理 Command 按下，
16:51:40 三指激活，16:51:41 物理键释放；随后的实际输入仍包含 Command，
16:51:45 抬起三指后释放。用户确认“仍能全选，释放也正常”。
这覆盖了物理键先按、模拟先按及两种释放顺序，且输入事件和 UI 效果相互印证。

因此，当前设备上的核心技术路线可行：内置触控板私有回调 + IOHID 物理来源记录 +
带来源标记的 CGEvent + 保持期间的事件修饰标志补充。进入 MVP 时需要补齐正式状态机、
生命周期、权限反馈、输入监听失效处理及下述未验证场景。

此处只记录已发生的证据，不等于全部功能与稳定性通过。

## 公共 API、私有 API 与兼容边界

AppKit 的 `NSTouch` 面向应用的视图事件，并不是菜单栏后台工具的稳定全局原始触摸入口。
`CGEventTap` 可观察或修改键鼠事件，不提供所需的原始多点接触阵列。
IOHID 的公开接口适合独立读取键盘；内置触控板原始报告格式仍需设备适配，当前未验证这条替代路径。

`MultitouchSupport.framework` 为私有框架。使用 `dlopen` 和逐符号检查有助于在符号缺失时明确失败，
但不能防止私有函数签名或数据布局变化导致的崩溃。只确认当前机型和系统，未验证其它 macOS 或 Intel。
不能将 App Store 分发作为这条私有 API 路径的目标；本地构建不等于已签名公证或可公开分发。

公共 API 参考：

- [Apple：Trackpad 事件与视图路由](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html)
- [Apple：CGEventSource 状态表](https://developer.apple.com/documentation/coregraphics/cgeventsourcestateid)
- [Apple：IOHIDManager 输入值回调](https://developer.apple.com/documentation/iokit/1438367-iohidmanagerregisterinputvalueca)
- [Apple：App Review Guidelines 2.5.1](https://developer.apple.com/app-store/review/guidelines/#software-requirements)
- [Apple：SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [社区私有 ABI 参考：OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport/blob/15c6bb0c6a2d2858559493a28ab23f7ac58648a3/Framework/OpenMultitouchSupportXCF/OpenMTInternal.h)

## 必须保留的限制与未验证项

- `CGEvent.post` 无投递确认返回值；需要下游监听、应用实际效果和释放后状态共同验证。
- 单个用户态进程无法保证在 SIGKILL、崩溃、系统冻结或权限撤销时执行退出清理。
  不能承诺任意异常下绝不卡键；当前实验尚不适合常驻使用。
- 手势监听不会阻止 macOS 系统手势。三指静止加第四指可能成为四指手势而非普通单指移动，
  Command+Click 需实测，不能仅凭键盘组合键成功推断。
- Secure Input、睡眠唤醒、注销切换、设备断开、事件过滤器超时、长时间性能和内存均未验收。
- 菜单栏应用、设置、登录启动、正式状态机和 `.app` 的后续实施及未完成验收见 [当前验证记录](verification.md)。
