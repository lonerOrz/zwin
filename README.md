# zwin

A lightweight Windows utility to move, resize, snap, and manage windows from anywhere by holding `Alt`. Written in Zig using the native Win32 API.

## Keybindings

| Shortcut                             | Action                                         |
| :----------------------------------- | :--------------------------------------------- |
| **`Alt` + Left Click Drag**          | Move window (with magnetic screen/window snap) |
| **`Alt` + Right Click Drag**         | Resize window (from 9 screen sectors)          |
| **`Alt` + Middle Click**             | Minimize window                                |
| **`Alt` + Mouse Wheel**              | Change window opacity                          |
| **`Alt` + Click** _(without moving)_ | Normal click passed through to underlying app  |
| **`Alt + Ctrl + H / J / K / L`**     | Move window step-by-step (or Arrow Keys)       |
| **`Alt + H / J / K / L`**            | Directional focus navigation (or Arrow Keys)   |
| **`Alt + C`**                        | Center window on current monitor               |
| **`Alt + T`**                        | Toggle always-on-top                           |
| **`Alt + M`**                        | Toggle maximize / restore                      |
| **`Alt + N`**                        | Restore most recently minimized window         |
| **`Alt + Q`**                        | Close window                                   |
| **`ESC`** _(while dragging)_         | Cancel movement and restore window position    |

## Download & Usage

1. Download the latest portable zip from [Releases](../../releases).
2. Extract and run `zwin.exe`. It runs in the system tray.

- **Double-click tray icon**: Pause / resume.
- **Right-click tray icon**: Toggle autostart, run as administrator, reload config, or open logs.

## Configuration

Settings are saved in `%APPDATA%\zwin\config.json`. The file is automatically reloaded when saved, and automatically migrated with default values when new settings are added in newer releases:

```json
{
  "language": "auto",
  "move_step": 20,
  "key_center": "C",
  "key_topmost": "T",
  "key_close": "Q",
  "key_maximize": "M",
  "key_restore_min": "N",
  "key_focus_left": "H",
  "key_focus_down": "J",
  "key_focus_up": "K",
  "key_focus_right": "L",
  "key_move_left": "H",
  "key_move_down": "J",
  "key_move_up": "K",
  "key_move_right": "L",
  "enable_border": true,
  "enable_wheel_opacity": true,
  "enable_autostart": false,
  "enable_elevated": false,
  "enable_window_snap": true,
  "snap_threshold": 18,
  "opacity_step": 15,
  "active_border_hex": "#FF8800",
  "min_window_width": 120,
  "min_window_height": 100,
  "log_max_days": 7,
  "ignore_processes": ["Photoshop.exe", "*blender*.exe", "mstsc.exe"],
  "ignore_classes": ["UnityWndClass", "UnrealWindow"]
}
```

### Settings Reference

- **`move_step`**: Distance in pixels moved per keypress when using `Alt + Ctrl` window movement (default `20`). Holding the key combination smoothly repeats movement.
- **Key Names**: All keybinding fields accept single alphanumeric letters (`"A"`-`"Z"`, `"0"`-`"9"`) as well as named direction keys (`"Left"`, `"Right"`, `"Up"`, `"Down"`, `"ArrowLeft"`, etc.).
- **`enable_window_snap` / `snap_threshold`**: Enables magnetic edge snapping between moving/resizing windows and other visible windows, in addition to monitor work areas. `snap_threshold` specifies the distance in pixels within which edges snap magnetically during mouse dragging.
- **`ignore_processes` / `ignore_classes`**: Blacklist filtering. Windows matching these process or class name patterns bypass all interception, letting native `Alt` clicks and shortcuts pass directly to the target application. Supports `*` and `?` wildcard patterns.
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
