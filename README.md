# OrbUSB (English)

A native macOS menu bar utility for managing USB passthrough through OrbStack. Click the cable icon in the menu bar, choose a USB device, and click **Attach**. When finished, click **Detach** to return the device to macOS.

OrbUSB calls OrbStack's public CLI directly. Before attaching a storage device, it resolves the corresponding disk through IOKit, unmounts its volumes with macOS `diskutil unmountDisk`, re-checks the device identity, and then performs the attach operation. It requires no root access, privileged helper, or third-party dependency.

[中文版](#orbusb-chinese)

## Features

- View USB devices and their states in the menu bar: Available, Connected to Linux, Forwarded, and Unknown.
- Attach or detach devices independently, with per-device progress and inline errors.
- Resolve physical disks and unmount their volumes before attaching storage devices.
- Match re-enumerated devices using VID/PID, serial numbers, and enumeration details before operating on them.
- Expand a device to view details; use the context menu to copy its Device ID or VID:PID, or add it to Favorites.
- Keep Favorites at the top of the list using UserDefaults persistence.
- Optionally show forwarded devices, device IDs, and serial numbers.
- Refresh automatically while the menu is open, with 1, 2, 5, and 10 second intervals, plus optional IOKit hot-plug monitoring.
- Hold Option while opening the menu to view the OrbStack CLI path, version, and most recent refresh duration.
- Provide an optional Machine for network devices, passed to OrbStack through the `-m` argument.
- Support Launch at Login, including a shortcut to Login Items settings when macOS requires approval.

## Requirements

- macOS 15 or later (Apple Silicon recommended).
- Xcode 26 or later with Swift 6.2 or later.
- OrbStack 2.2.3 or later with JSON output support for the USB CLI.

## Build and Run

1. Open `OrbUSB.xcodeproj`.
2. Select the `OrbUSB → My Mac` scheme.
3. Choose Build & Run.

Use the `OrbUSB Release` scheme for Release builds.

The app sets `LSUIElement = true`, so it does not show a Dock icon by default. After launching it, look for the cable icon in the menu bar. App Sandbox is disabled so the app can invoke the `orb` executable outside its bundle and communicate with OrbStack.

## Usage

- Click **Attach** in the **Available** group; click **Detach** in the **Connected to Linux** group.
- Storage operations proceed through: Resolving disk → Unmounting volumes → Re-resolving OrbStack USB ID → Attaching.
- OrbUSB uses the regular `unmountDisk` operation. It does not force-unmount or eject disks. macOS handles multi-volume and APFS devices; close files using the disk before retrying if unmounting fails.
- If some volumes were unmounted before a later step failed, OrbUSB does not remount them automatically.
- Forwarded devices are labeled **Shared with macOS**. Complete passthrough actions that require OrbStack-specific confirmation in OrbStack itself.
- The menu refreshes while open and stops timer-based polling when closed. IOKit hot-plug notifications trigger an immediate refresh followed by a short delayed coalesced refresh.
- Device states reflect OrbStack CLI reports and do not guarantee that a Linux driver or filesystem is ready.

## Limitations

- Older `orb` versions without JSON output are unsupported. CLI output errors are shown as lightweight errors or Unknown states to avoid acting on unconfirmed devices.
- Attach stops when storage unmounting fails; OrbUSB never force-unmounts or automatically restores mounts.
- Devices without serial numbers may not be distinguishable when identical models are connected. Operations stop when device identity cannot be established.
- OrbUSB does not stop the OrbStack daemon or automatically attach a device after it reconnects.

---

<a id="orbusb-chinese"></a>

# OrbUSB（中文）

原生 macOS 菜单栏工具，用于通过 OrbStack 管理 USB passthrough：点击菜单栏中的连接线图标，选择 USB 设备并点击 **Attach**；使用完成后点击 **Detach** 将设备返回 macOS。

OrbUSB 直接调用 OrbStack 公开 CLI。对于存储设备，应用会先通过 IOKit 解析对应磁盘，再使用 macOS `diskutil unmountDisk` 卸载卷，随后重新确认设备身份并执行 Attach。应用不需要 root、privileged helper 或第三方依赖。

## 功能

- 在菜单栏中查看 USB 设备及其状态：Available、Connected to Linux、Forwarded 和 Unknown。
- Attach、Detach 分别作用于对应设备；每台设备独立显示操作进度和错误。
- 存储设备 Attach 前自动解析物理磁盘并卸载卷，完成重新枚举后再执行 Attach。
- 通过 VID/PID、序列号和枚举信息识别重新枚举的设备，避免对错误设备执行操作。
- 点击设备名称查看详情；右键菜单可复制 Device ID、VID:PID，或将设备加入 Favorites。
- Favorites 保存在 UserDefaults 中，并固定显示在列表顶部。
- 可选显示 Forwarded devices、Device ID 和序列号。
- 菜单打开时自动刷新，可设置 1、2、5 或 10 秒刷新间隔；也支持 IOKit USB 热插拔监听。
- 按住 Option 打开菜单可查看 OrbStack CLI 路径、版本和最近一次刷新耗时。
- 网络设备支持填写可选 Machine，Attach 时传递给 OrbStack 的 `-m` 参数。
- 支持 Launch at Login；如 macOS 要求批准，可从 Settings 打开 Login Items 设置。

## 要求

- macOS 15 或更高版本（Apple Silicon 优先）。
- Xcode 26 或更高版本，Swift 6.2 或更高版本。
- OrbStack 2.2.3 或更高版本，并支持 USB CLI 的 JSON 输出。

## 构建与运行

1. 打开 `OrbUSB.xcodeproj`。
2. 选择 `OrbUSB → My Mac` scheme。
3. 执行 Build & Run。

`OrbUSB Release` scheme 可用于 Release 构建。

应用使用 `LSUIElement = true`，默认不显示 Dock 图标。首次运行后请在菜单栏寻找连接线图标。App Sandbox 已关闭，以便调用应用包外的 `orb` 可执行文件并访问 OrbStack 服务。

## 使用说明

- 在 **Available** 分组中点击 **Attach**；在 **Connected to Linux** 分组中点击 **Detach**。
- 存储设备的操作阶段依次为：Resolving disk → Unmounting volumes → Re-resolving OrbStack USB ID → Attaching。
- 使用普通的 `unmountDisk`，不会强制卸载或 eject。多卷和 APFS 设备由 macOS 处理；如果应用或其他程序正在使用磁盘，请关闭相关文件后重试。
- 如果部分卷已经卸载但后续步骤失败，OrbUSB 不会自动重新挂载这些卷。
- Forwarded 设备会显示为 **Shared with macOS**。需要 OrbStack 专用确认的 passthrough 操作，请在 OrbStack 中完成。
- 菜单打开时进行刷新，菜单关闭后停止定时轮询；IOKit 热插拔通知会触发即时刷新，并在短暂延迟后进行一次合并刷新。
- 设备状态以 OrbStack CLI 的报告为准，不代表 Linux 驱动或文件系统挂载已经就绪。

## 限制

- 不支持不提供 JSON 输出的旧版 `orb`；CLI 输出异常时会显示轻量错误或 Unknown 状态，避免未经确认执行设备操作。
- 存储设备卸载失败时不会继续 Attach，也不会强制卸载或自动恢复挂载。
- 无序列号的同型号设备可能无法可靠区分；无法确定设备身份时，操作会停止。
- OrbUSB 不会停止 OrbStack daemon，也不会自动 Attach 重新连接的设备。
