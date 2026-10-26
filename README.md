# No Test Mode Watermark

Hide (or restore) the **"Test Mode"** watermark that Windows shows in the bottom-right corner of the
desktop while Windows **test signing** (test mode) is on.

It is a small Windows tool: a self-elevating app with two buttons - **Remove test mode watermark**
and **Restore test mode watermark** - plus the hook DLL it uses.

## Use

1. Double-click **`No Test Mode Watermark.cmd`** (or run `NoTestModeWM.ps1`).
2. Approve the administrator (UAC) prompt.
3. Click **Remove test mode watermark** to hide it, or **Restore test mode watermark** to put it back.

Windows Explorer is restarted each time (your taskbar will blink for a moment).

## What it does

While test signing is on, Windows draws three lines in the corner of the desktop: "Test Mode", the
Windows edition, and the build string. This tool loads a small component (`ntmwm.dll`) into Windows
Explorer that stops **only those lines** from being drawn and forwards everything else to Windows
unchanged. To do that it takes ownership of a protected system registry key
(`HKLM\...\CLSID\{ab0b37ec-...}\InProcServer32`), backs up the original value and its security
descriptor to `HKLM\SOFTWARE\NoTestModeWM`, and restores all of it when you restore the watermark.

It does **not** turn test mode on or off, and it changes nothing else.

## Warnings - please read

- Needs administrator rights (the tool self-elevates).
- Restarts Windows Explorer each time you remove or restore.
- May be unreliable or stop working after a Windows update.
- In rare cases Explorer or File Explorer can fail to open (an error such as **"Server execution
  failed"**) until you **restart Windows**. Restarting Windows fixes it, and it causes **no lasting
  damage**.
- Only relevant while Windows is in test mode.
- Use at your own risk.

## How it is scoped

A line is hidden only when all three are true: the process is `explorer.exe`, the draw call comes
from `uxtheme.dll` (the watermark's renderer), and the text matches one of the three exact watermark
strings. Those strings are read from the running system, so it follows the Windows display language
and build. File names, menus, other apps and every other process are left untouched.

## Build the DLL from source

The repo ships a prebuilt `ntmwm.dll`. To rebuild it you need Visual Studio 2022 with the "Desktop
development with C++" workload (MSVC x64 and a Windows SDK), then run:

```
powershell -ExecutionPolicy Bypass -File build.ps1
```

It produces `ntmwm.dll` in the repo root.

## License

MIT. See [LICENSE](LICENSE). Provided as-is, with no warranty.
