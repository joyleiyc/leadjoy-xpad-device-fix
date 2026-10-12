# Tianjian Plus Xpad Fix for Linux

让天剑 Plus（LiteEMF，常见 USB ID `4131:3519`）在 Linux 上通过内核自带的 `xpad` 驱动创建手柄设备。它不编译内核、不安装第三方驱动，只把控制器的 USB ID 注册到 `xpad` 的运行时 `new_id` 接口。

项目名采用 **Tianjian Plus Xpad Fix for Linux**，同时包含品牌、目标驱动和使用平台，便于用户搜索和识别。

## 一键安装

将 `joyleiyc/tianjian-plus-xpad-fix` 换成实际 GitHub 仓库后：

```bash
curl -fsSL https://raw.githubusercontent.com/joyleiyc/tianjian-plus-xpad-fix/main/install.sh | bash
```

脚本会在需要时调用 `sudo`，安装并启用：

- `/usr/local/libexec/tianjian-plus-xpad-fix`：加载 `xpad` 并注册 `4131:3519`；
- `tianjian-plus-xpad.service`：开机处理已经插入的接收器；
- `99-tianjian-plus-xpad.rules`：插入或重新插拔时自动处理。

如果你的硬件批次使用不同的 USB ID，可覆盖默认值：

```bash
curl -fsSL https://raw.githubusercontent.com/joyleiyc/tianjian-plus-xpad-fix/main/install.sh \
  | bash -s -- install --vid 4131 --pid 3519
```

先用 `lsusb` 查看实际值，格式应为 `ID xxxx:yyyy`。

## 管理命令

```bash
# 查看服务和 /dev/input/js*
curl -fsSL https://raw.githubusercontent.com/joyleiyc/tianjian-plus-xpad-fix/main/install.sh | bash -s -- status

# 手动立即注册一次（不改安装内容）
curl -fsSL https://raw.githubusercontent.com/joyleiyc/tianjian-plus-xpad-fix/main/install.sh | bash -s -- run

# 卸载服务、udev 规则和辅助程序
curl -fsSL https://raw.githubusercontent.com/joyleiyc/tianjian-plus-xpad-fix/main/install.sh | bash -s -- uninstall
```

卸载不会强制卸载 `xpad` 内核模块，因为系统中可能还有其他手柄正在使用它。

## 本地验证

```bash
systemctl status tianjian-plus-xpad.service
lsusb -d 4131:3519
ls -l /dev/input/js*
cat /proc/bus/input/devices | grep -A12 -i -E 'liteemf|tianjian|xbox|xpad'
```

如果手柄已经插着，安装后拔插一次最容易确认 udev 规则是否生效。某些发行版没有 `js*` 兼容节点时，可改用 `evtest` 或 Steam 的手柄设置检查输入事件。

## 工作原理与限制

`xpad` 默认只识别它内置的 USB ID。脚本执行：

```bash
modprobe xpad
echo '4131 3519' > /sys/bus/usb/drivers/xpad/new_id
```

`new_id` 是运行时注册，重启后会丢失，因此需要 systemd；udev 规则则负责之后的热插拔。这个方案只适用于该控制器确实提供 Xbox/XInput 接口的固件模式，不会把蓝牙 HID 或其他模式强行转换成 XInput。

## 相关项目和实现参考

- [WWWWYYYYAAAA/flydigi-vader5pro-xpad](https://github.com/WWWWYYYYAAAA/flydigi-vader5pro-xpad)：同样使用 `xpad/new_id` 和 systemd 持久化 USB ID，目标是飞智 Vader 5 Pro。
- [paroj/xpad](https://github.com/paroj/xpad)：独立维护的 xpad 驱动源码；本项目不替换发行版内核驱动。
- [ArchWiki Gamepad](https://wiki.archlinux.org/title/Gamepad)：记录通过 udev 规则执行 `modprobe xpad` 与 `new_id` 的通用方式。

这些项目解决的是同一类“USB 设备能看到，但 xpad 没有绑定”的问题；目前没有检索到专门针对“天剑 Plus / LiteEMF `4131:3519`”的成熟一键安装仓库，因此本项目将该设备 ID 与完整生命周期管理集中起来。

## 安全提示

`curl | bash` 会直接执行远程脚本。正式发布后建议使用固定版本或先下载审阅：

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/joyleiyc/tianjian-plus-xpad-fix/main/install.sh
less install.sh
bash install.sh
```
