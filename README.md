# zwin

A minimalist, ultra-lightweight window manipulation extension for Windows written in Zig using the native Win32 API. It brings X11-style `Alt`-key window management to Windows with near-zero resource usage.

## Features

- X11-style `Alt` + mouse window moving / resizing / minimizing
- DWM-accelerated border highlight for the active window (requires Windows 11)
- Hotkeys: center, always-on-top toggle, close
- Config file with automatic hot-reload (no restart needed)
- Tray icon with context menu (pause, toggles, open config/log folders)
- Optional registry-based autostart (`HKCU\...\Run`)
- Auto / English / Simplified Chinese UI strings
- Single-instance guard, per-monitor-DPI aware, daily-rotated logs

## Keybindings

| Shortcut / Action            | Description                                    |
| :--------------------------- | :--------------------------------------------- |
| **`Alt` + Left Click Drag**  | Move window from anywhere within its bounds    |
| **`Alt` + Right Click Drag** | Resize window based on the clicked 3x3 sector  |
| **`Alt` + Middle Click**     | Minimize window                                |
| **`Alt` + Mouse Wheel**      | Adjust window opacity                          |
| **`Alt + C`**                | Center window in the current monitor work area |
| **`Alt + T`**                | Toggle window topmost state (Always on Top)    |
| **`Alt + Q`**                | Close window                                   |

## Installation

1. Download the portable zip from [GitHub Releases](../../releases).
2. Extract and run `zwin.exe`.
3. Enable _Autostart_ from the tray menu to launch it on login.

## Usage

zwin runs silently in the system tray.

- **Double-click** the tray icon to pause/resume all hooks.
- **Right-click** the tray icon for the menu: pause, border/autostart toggles, config reload, open config/log folders, exit.
- Editing `%APPDATA%\zwin\config.json` triggers an automatic reload.

## Configuration

Configuration file is located at `%APPDATA%\zwin\config.json`:

```json
{
  "language": "auto",
  "key_center": "C",
  "key_topmost": "T",
  "key_close": "Q",
  "enable_border": true,
  "enable_wheel_opacity": true,
  "enable_autostart": false,
  "opacity_step": 15,
  "active_border_hex": "#FF8800",
  "min_window_width": 120,
  "min_window_height": 100,
  "log_max_days": 7
}
```

Logs are written daily to `%LOCALAPPDATA%\zwin\logs\` and retained for `log_max_days`.

## Build

Requirements: [Zig](https://ziglang.org/download/) 0.16

```sh
zig build -Doptimize=ReleaseFast -Dstrip=true
```

Output executable: `zig-out/bin/zwin.exe`

Run tests:

```sh
zig build test -Dtarget=x86_64-windows-gnu
```

## License

GNU General Public License v3.0 (GPL-3.0)
