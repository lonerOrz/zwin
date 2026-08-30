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

Settings are saved in `%APPDATA%\zwin\config.toml`. The file is automatically reloaded when saved, and automatically migrated with default values when new settings are added in newer releases:

```toml
language = "auto"
move_step = 20
snap_threshold = 18
opacity_step = 15
enable_border = true
enable_wheel_opacity = true
enable_autostart = false
enable_elevated = false
enable_window_snap = true
active_border_hex = "#FF8800"
min_window_width = 120
min_window_height = 100
log_max_days = 7
ignore_processes = ["Photoshop.exe", "*blender*.exe", "mstsc.exe"]
ignore_classes = ["UnityWndClass", "UnrealWindow"]

[[bind]]
keys = ["alt", "h"]
action = "focus_left"

[[bind]]
keys = ["alt", "j"]
action = "focus_down"

[[bind]]
keys = ["alt", "k"]
action = "focus_up"

[[bind]]
keys = ["alt", "l"]
action = "focus_right"

[[bind]]
keys = ["alt", "ctrl", "h"]
action = "move_left"

[[bind]]
keys = ["alt", "ctrl", "j"]
action = "move_down"

[[bind]]
keys = ["alt", "ctrl", "k"]
action = "move_up"

[[bind]]
keys = ["alt", "ctrl", "l"]
action = "move_right"

[[bind]]
keys = ["alt", "c"]
action = "center"

[[bind]]
keys = ["alt", "t"]
action = "toggle_topmost"

[[bind]]
keys = ["alt", "q"]
action = "close"

[[bind]]
keys = ["alt", "m"]
action = "toggle_maximize"

[[bind]]
keys = ["alt", "n"]
action = "restore_last_minimized"

[[bind]]
keys = ["alt", "mouse_left"]
action = "drag_move"

[[bind]]
keys = ["alt", "mouse_right"]
action = "drag_resize"

[[bind]]
keys = ["alt", "mouse_middle"]
action = "minimize"

[[bind]]
keys = ["alt", "mouse_wheel"]
action = "adjust_opacity"
```

### Settings Reference

- **`[[bind]]`**: Custom shortcut and gesture mappings. Supports modifier keys (`alt`, `ctrl`, `shift`, `win`), keyboard keys (`a`-`z`, `0`-`9`, `left`, `right`, `up`, `down`, etc.), and mouse inputs (`mouse_left`, `mouse_right`, `mouse_middle`, `mouse_wheel`).
- **`move_step`**: Distance in pixels moved per keypress when using `Alt + Ctrl` window movement (default `20`). Holding the key combination smoothly repeats movement.
- **`enable_window_snap` / `snap_threshold`**: Enables magnetic edge snapping between moving/resizing windows and other visible windows, in addition to monitor work areas. `snap_threshold` specifies the distance in pixels within which edges snap magnetically during mouse dragging.
- **`ignore_processes` / `ignore_classes`**: Blacklist filtering. Windows matching these process or class name patterns bypass all interception, letting native `Alt` clicks and shortcuts pass directly to the target application. Supports `*` and `?` wildcard patterns.
- **`enable_elevated`**: Allows managing elevated windows like Task Manager. Toggling from the tray menu restarts immediately; editing the file applies on next start. When enabled together with `enable_autostart`, a Windows scheduled task is used for silent startup.
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
