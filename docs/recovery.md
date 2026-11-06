# v1.0.0 恢复与开发约定

`v1.0.0` 是首个正式发布版本（build 7）。
发布后冻结源码和签名二进制，不移动标签、不覆盖同名 Release 附件。
后续功能使用新分支和新版本号。日常安装位置固定为 `/Applications/TouchChord.app`。
构建和测试本身不安装应用；只有进行明确的应用调试时才替换日常版本。

## 恢复原版

无需克隆仓库或安装开发工具。可从 Release 页面下载，也可用 macOS 自带的 `curl` 下载：

```sh
mkdir -p "$HOME/Downloads/touch-chord-v1.0.0"
cd "$HOME/Downloads/touch-chord-v1.0.0"
for asset in touch-chord-1.0.0-arm64.dmg touch-chord-1.0.0-arm64.zip restore-release.sh sha256sums.txt; do
  curl -fL --retry 2 -o "$asset" "https://github.com/yy003x/touch-chord/releases/download/v1.0.0/$asset" || break
done
shasum -a 256 -c sha256sums.txt && bash restore-release.sh .
```

首次下载若被系统安全检查拦截，按照“隐私与安全性”的提示由本人确认，不关闭系统安全机制。

从 [v1.0.0 Release](https://github.com/yy003x/touch-chord/releases/tag/v1.0.0) 下载到同一目录：

- `touch-chord-1.0.0-arm64.zip`
- `sha256sums.txt`
- `restore-release.sh`

先抬起触控板手指，在终端执行（目录替换为实际下载位置）：

```sh
bash /path/to/v1.0.0/restore-release.sh /path/to/v1.0.0 --verify-only
bash /path/to/v1.0.0/restore-release.sh /path/to/v1.0.0
```

脚本校验 ZIP、版本和原签名身份，正常退出当前应用，保存替换前 ZIP，再恢复并打开 v1.0.0。
替换前备份在 `~/Library/Application Support/TouchChord/Backups/`。
如进程无法正常退出则停止，不强制杀死进程。不会构建、重新签名、清除权限或重置用户设置。
校验清单用于检测下载损坏；签名身份另由脚本固定校验。

也可直接使用原版 DMG：退出当前应用，将 DMG 中的 TouchChord 拖入 Applications 并替换。
恢复代码不会恢复被用户修改的设置；已有 Bundle ID、偏好键和 Command 恢复标记继续保留。
系统升级、权限撤销或证书变更后仍可能需要本人重新授权。

## 后续调试

- 保留签名证书、`local.trikey.app` 和固定安装路径，不用临时签名覆盖日常应用。
- 调试前保留 Release 安装包；调试失败直接运行恢复命令，不依赖工作区当前源码。
- 不同时运行稳定版和开发版，避免两个进程竞争全局输入；单实例检查以 Bundle ID 为准。
- 新功能仍需真实触控板验证，单元测试成功不等于稳定性验收。

## 已知边界

v1.0.0 保留现有输入逻辑，更新名称、图标、发布恢复工具及设置窗口的应用切换策略。
关闭系统设置后设置页被其它应用遮挡的问题已定位并通过真实桌面回归，见 [根因记录](settings-window-fix.md)。
此前出现过菜单栏图标缺失，正常重启可恢复，根因未确定。
睡眠、Secure Input、长时间运行和其它机型仍未完成完整验收。
此版本作为可恢复的使用基线，不代表已经证明所有异常下都不会卡键。
