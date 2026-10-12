# LeadJoy Xpad Device Fix for Linux

A safe, interactive installer for USB gamepads that expose an Xbox/XInput interface but are not yet listed by Linux's built-in `xpad` driver.

The project is named **LeadJoy Xpad Device Fix**. The repository name and command names use the manufacturer's English brand, **LeadJoy**, rather than pinyin.

## What it does

The installer:

- scans connected USB devices and matches them against a small, reviewable candidate list;
- never silently assumes the example ID `4131:3519`;
- guides you through disconnect/reconnect discovery when no known device is connected;
- lets you choose a connected unknown ID, choose an entry from the list, or enter a custom `VID:PID`;
- supports `--dry-run` so you can inspect every file and command before changing the system;
- installs a systemd boot service and a udev hot-plug rule that register the selected ID through `xpad/new_id`.

The list contains candidates reported by dedicated projects or community recipes. A match means “safe to try”, not “guaranteed to work with every firmware or connection mode”.

## One-command install

```bash
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh | bash
```

The script reads prompts from `/dev/tty`, so it can remain interactive even when the script itself is piped from `curl`. It uses `sudo` when needed.

Before changing anything, preview the selected device and generated files:

```bash
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh \
  | bash -s -- install --dry-run
```

For automation, explicitly supply the ID and avoid prompts:

```bash
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh \
  | bash -s -- install --device 4131:3519 --non-interactive
```

## Detection flow

1. If a connected USB ID matches the built-in list, the installer selects it and shows the evidence level.
2. If connected USB devices exist but none match, it displays their IDs and asks you to choose one to try, or to enter a custom ID.
3. If no USB device is available, it asks you to disconnect the controller, press Enter, reconnect it, and press Enter again. The newly appearing ID is selected.
4. If you do not want to connect the controller, select a candidate from the list or use `--device VID:PID`.
5. If the resulting input device does not work, run `status`, remove the installation, and report the observed ID and Linux distribution so the list can be improved.

In non-interactive environments, the installer refuses to guess and asks for `--device VID:PID`.

## Commands

```bash
# Install (interactive detection is the default)
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh | bash

# Preview without changing files, services, udev rules, or the kernel
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh \
  | bash -s -- install --dry-run

# Inspect service, connected USB IDs, and joystick nodes
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh \
  | bash -s -- status

# Register the ID already saved by the installation once
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh \
  | bash -s -- run

# Remove the service, helper, and udev rule
curl -fsSL https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh \
  | bash -s -- uninstall
```

`uninstall` does not forcibly unload `xpad`, because another controller may be using it.

## Built-in candidate list

The same list is kept in [`known-devices.tsv`](known-devices.tsv). The installer embeds it so the one-line `curl | bash` workflow does not need a second download.

| USB ID | Device | Evidence | Caveat |
| --- | --- | --- | --- |
| `4131:3519` | LeadJoy 天剑 Plus 2.4G receiver | Community observation supplied with this project | Verify on the target machine; not an official Linux ID declaration |
| `37d7:2401` | Flydigi Vader 5 Pro 2.4G receiver | Dedicated xpad project | Firmware and mode still matter |
| `3537:100f`, `3537:1098` | GameSir Nova 2 Lite receiver | Community recipe | Verify firmware and mode |
| `2dc8:310a`, `2dc8:3106` | 8BitDo Ultimate 2C / Ultimate receiver | Community udev/xpad recipes | Verify firmware and mode |

Add a device only when its VID/PID and xpad behavior have been observed. Keep uncertain entries marked as community evidence.

## Files installed

- `/usr/local/libexec/leadjoy-xpad-device-fix`
- `/etc/systemd/system/leadjoy-xpad-device-fix.service`
- `/etc/udev/rules.d/99-leadjoy-xpad-device-fix.rules`

The helper loads `xpad` and writes the selected ID to `/sys/bus/usb/drivers/xpad/new_id`. The service handles a receiver already connected at boot; the udev rule handles later insertion. The runtime ID is not persistent across a module unload or reboot, which is why both mechanisms are installed.

## Product information

LeadJoy's official site lists **天剑Plus** as a product in the 天剑 series and provides separate tutorials for 2.4G PC, Bluetooth, and wired connections. The site does not publish a Linux USB-ID compatibility table, so `4131:3519` is intentionally documented here as a community observation rather than an official constant.

Official pages:

- [LeadJoy official site](https://www.leadjoy.top/)
- [天剑Plus product page](https://www.leadjoy.top/product/game-controller/xeno-plus/)
- [天剑Plus tutorials and manual](https://www.leadjoy.top/xenoplus/)

## Related references

- [Flydigi Vader 5 Pro xpad](https://github.com/WWWWYYYYAAAA/flydigi-vader5pro-xpad)
- [paroj/xpad](https://github.com/paroj/xpad)
- [ArchWiki: Gamepad](https://wiki.archlinux.org/title/Gamepad)

## Security

`curl | bash` executes a remote script. For a reviewable installation, download and inspect it first:

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/joyleiyc/leadjoy-xpad-device-fix/main/install.sh
less install.sh
bash install.sh --dry-run
```

The script validates all custom IDs as exactly four hexadecimal digits for both vendor and product fields.

## License

MIT
