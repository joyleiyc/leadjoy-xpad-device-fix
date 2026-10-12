# LeadJoy Xpad Device Fix for Linux（中文说明）

这是一个面向 Linux 的交互式安装器，用于处理“USB 手柄已经能被系统看到，但发行版自带的 `xpad` 驱动尚未识别”的情况。

项目名称使用厂商的英文品牌 **LeadJoy**，仓库名和命令名不使用拼音。

## 功能

安装器会：

- 扫描当前连接的 USB 设备，并与可审阅的候选清单匹配；
- 不再静默假设示例 ID `4131:3519` 一定适用；
- 找不到已知设备时，引导用户断开再重连，以发现真实的 USB ID；
- 允许用户选择已连接但未列入清单的 ID、选择清单项，或手动输入 `VID:PID`；
- 支持 `--dry-run`，在修改系统前展示将创建的文件和将执行的命令；
- 安装 systemd 开机服务和 udev 热插拔规则，通过 `xpad/new_id` 注册用户选择的 ID。

清单中的条目来自专门项目或社区方案。“匹配到”只代表值得尝试，不代表所有固件或连接模式都一定兼容。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh | bash
```

脚本从 `/dev/tty` 读取交互输入，所以即使脚本本身通过 `curl` 管道传入，仍然可以正常询问用户；需要权限时会调用 `sudo`。

先查看将要选择的设备、文件和命令，不进行任何修改：

```bash
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh \
  | bash -s -- install --dry-run
```

自动化环境中请显式提供 ID，避免等待交互输入：

```bash
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh \
  | bash -s -- install --device 4131:3519 --non-interactive
```

## 检测流程

1. 如果当前连接的 USB ID 在内置清单中，安装器会自动选中，并显示证据等级。
2. 如果有 USB 设备但没有清单匹配项，会显示这些设备的 ID，让用户选择一个尝试，或输入自定义 ID。
3. 如果没有可查询到的 USB 设备，会要求用户拔出手柄接收器或数据线，按回车，再插入并按回车；安装器会选择新出现的 ID。
4. 如果用户不想连接手柄，可以从清单选择，或使用 `--device VID:PID`。
5. 如果生成了输入设备但实际不能工作，可以运行 `status`，卸载后把观察到的 ID 和 Linux 发行版反馈出来，以便补充清单。

非交互环境中，安装器不会猜测未知 ID，而是要求使用 `--device VID:PID`。

## 命令

```bash
# 安装，默认进行交互式检测
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh | bash

# 预览，不修改文件、服务、udev 规则或内核
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh \
  | bash -s -- install --dry-run

# 查看服务、已连接 USB ID 和摇杆节点
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh \
  | bash -s -- status

# 使用已安装的 ID 手动注册一次
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh \
  | bash -s -- run

# 删除服务、辅助程序和 udev 规则
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh \
  | bash -s -- uninstall
```

`uninstall` 不会强制卸载 `xpad`，因为系统中可能还有其他手柄正在使用它。

## 内置候选清单

同一份清单保存在 [`known-devices.tsv`](known-devices.tsv)。安装器内部也嵌入了它，因此一条 `curl | bash` 命令不需要额外下载第二个文件。

| USB ID | 设备 | 证据 | 注意 |
| --- | --- | --- | --- |
| `4131:3519` | LeadJoy 天剑 Plus 2.4G 接收器 | 本项目收到的社区观测 | 请在目标机器验证；并非厂商公布的 Linux 固定 ID |
| `37d7:2401` | 飞智 Vader 5 Pro 2.4G 接收器 | 专门的 xpad 项目 | 固件和连接模式仍会影响结果 |
| `3537:100f`、`3537:1098` | GameSir Nova 2 Lite 接收器 | 社区方案 | 请确认固件和模式 |
| `2dc8:310a`、`2dc8:3106` | 8BitDo Ultimate 2C / Ultimate 接收器 | 社区 udev/xpad 方案 | 请确认固件和模式 |

只有在实际观察到 VID/PID 和 xpad 行为后，才应把设备加入清单；不确定的条目应继续标注为社区证据。

## 安装的文件

- `/usr/local/libexec/leadjoy-xpad-device-fix`
- `/etc/systemd/system/leadjoy-xpad-device-fix.service`
- `/etc/udev/rules.d/99-leadjoy-xpad-device-fix.rules`

辅助程序会加载 `xpad`，并把所选 ID 写入 `/sys/bus/usb/drivers/xpad/new_id`。systemd 服务处理开机时已经插入的接收器，udev 规则处理之后的插入。运行时 ID 在模块卸载或重启后不会保留，所以两种机制都会安装。

## 产品信息

动感指尖官方网站将 **天剑Plus** 列为天剑系列产品，并分别提供 2.4G 连接 PC、蓝牙和有线连接教程。官网没有公开 Linux USB ID 兼容清单，因此这里把 `4131:3519` 明确标记为社区观测值，而不是官方固定值。

官方页面：

- [动感指尖官网](https://www.leadjoy.top/)
- [天剑Plus 产品页](https://www.leadjoy.top/product/game-controller/xeno-plus/)
- [天剑Plus 教程与说明书](https://www.leadjoy.top/xenoplus/)

## 相关参考

- [Flydigi Vader 5 Pro xpad](https://github.com/WWWWYYYYAAAA/flydigi-vader5pro-xpad)
- [paroj/xpad](https://github.com/paroj/xpad)
- [ArchWiki：Gamepad](https://wiki.archlinux.org/title/Gamepad)

## 安全提示

`curl | bash` 会执行远程脚本。需要审阅时，可以先下载：

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh
less install.sh
bash install.sh --dry-run
```

脚本会校验自定义 ID，VID 和 PID 都必须是四位十六进制字符。

## 许可证

MIT
