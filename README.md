# zwin

A lightweight Windows utility to move and resize windows from anywhere by holding `Alt`. Written in Zig using the native Win32 API.

## Keybindings

| Shortcut                             | Action                                      |
| :----------------------------------- | :------------------------------------------ |
| **`Alt` + Left Click Drag**          | Move window                                 |
| **`Alt` + Right Click Drag**         | Resize window (from 9 screen sectors)       |
| **`Alt` + Middle Click**             | Minimize window                             |
| **`Alt` + Mouse Wheel**              | Change window opacity                       |
| **`Alt` + Click** _(without moving)_ | Normal click passed to the underlying app   |
| **`Alt + C`**                        | Center window on current monitor            |
| **`Alt + T`**                        | Toggle always-on-top                        |
| **`Alt + Q`**                        | Close window                                |
| **`ESC`** _(while dragging)_         | Cancel movement and restore window position |

## Download & Usage

1. Download the latest portable zip from [Releases](../../releases).
2. Extract and run `zwin.exe`. It runs in the system tray.

- **Double-click tray icon**: Pause / resume.
- **Right-click tray icon**: Toggle autostart, run as administrator, reload config, or open logs.

## Configuration

Settings are saved in `%APPDATA%\zwin\config.json`. The file is automatically reloaded when saved:

```json
{
  "language": "auto",
  "key_center": "C",
  "key_topmost": "T",
  "key_close": "Q",
  "enable_border": true,
  "enable_wheel_opacity": true,
  "enable_autostart": false,
  "enable_elevated": false,
  "opacity_step": 15,
  "active_border_hex": "#FF8800",
  "min_window_width": 120,
  "min_window_height": 100,
  "log_max_days": 7
}
```

- **`enable_elevated`**: Allows managing elevated windows like Task Manager. Toggling from the tray menu restarts immediately; editing the JSON applies on next start. When enabled together with `enable_autostart`, a Windows scheduled task is used for silent startup.
- **`enable_border`**: Draws an accent border on the active window (Windows 11 only).

Logs are stored in `%LOCALAPPDATA%\zwin\logs\`.

## Building from Source

Requires [Zig](https://ziglang.org/download/) 0.16.

```sh
# Build release binary (output at zig-out/bin/zwin.exe)
zig build -Doptimize=ReleaseFast -Dstrip=true

# Run tests
zig build test -Dtarget=x86_64-windows-gnu
```

## License

GPL-3.0
