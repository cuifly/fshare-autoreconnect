# fshare-autoreconnect

Windows 局域网共享文件夹的断线自动重连。共享一断（主机重启、网线松、WiFi 掉、共享服务短暂中断），**最多 1 分钟内自动连回**，无需管理员、不弹窗、不占托盘。

Windows auto-reconnect for LAN shared folders. When the share drops (host reboot, cable loose, WiFi down, brief service hiccup), it **reconnects within a minute** — no admin rights, no popup, no tray icon.

---

## Why it exists / 它为什么存在

A plain `net use` reconnect is deceptively easy, and every tutorial gets it wrong in at least one way. This project started from two real client machines that kept failing for six different reasons. Each one is documented below because each one bites people who copy a one-liner from a forum.

Plain `net use` 自动重连看着简单，但每个教程都至少错一处。本项目源自两台真实客户端反复踩坑的排查——这六个坑每一个都会咬到照抄论坛一行命令的人。

## The six pitfalls (and how this fixes them) / 六个坑与修法

| # | Pitfall | Symptom | Fix here |
|---|---------|---------|----------|
| 1 | **Installer lies on success** — `Register-ScheduledTask` CIM failure is a *non-terminating* error, so `try/catch` never fires and the installer prints "installed" while nothing was installed, then skips the fallback. | "✓ Installed" but the share never reconnects. | Registration runs under `-ErrorAction Stop`; a failure always surfaces and the fallback still gets installed. |
| 2 | **Non-admin can't register a logon trigger** — double-clicking a `.bat` is non-admin; a task with `-AtLogOn` is denied (`0x80070005`). | Task "installed" silently fails; after reboot nothing reconnects for a while. | A **startup-folder VBS loop is always installed first** (zero permission). The scheduled task is only a redundancy; if the logon trigger is denied it **auto-degrades** to a repeat-only trigger, and a further failure still doesn't touch the fallback. |
| 3 | **Identity drift** — the share allows anonymous access, so Windows falls to the anonymous session (`1219`); giving `/user` without a password forces an interactive prompt (`1326`). | Reconnect silently lands on the wrong identity; Explorer shows the share but it's locked. | `sharecred.ini` stores `user` **and** `pass`; every reconnect passes them explicitly, so the identity never drifts. |
| 4 | **Win11 pops a console** — the default terminal swallows `-WindowStyle Hidden`, so the background loop flashes a window. | A black box keeps appearing. | `launcher.py` uses `pythonw` (a GUI process with **no console**) plus `CREATE_NO_WINDOW` to launch powershell — no console means no window to hand off. Machines without Python fall back to hidden powershell (same behavior, may flash). |
| 5 | **Boot gap** — a minute-based loop idles after a reboot while the host/network is still coming up. | After a restart the share sits disconnected until the host is back. | `boot_connect.ps1` **persists at boot**: tries every 30 s for up to 2 h, reconnects the moment the host answers, then hands off to the watcher. |
| 6 | **Concurrent fights** — the startup-folder loop and the scheduled task can both launch a reconnect at the same time; two instances delete each other's connections. | Sporadic "can't reconnect", log full of 1219/53. | A **named mutex** (`Global\FShareAutoReconnectLock`) means only one instance ever runs; the loser exits in 200 ms. |

## How it works / 工作原理

Three cooperating pieces, all reading a single `sharecred.ini`:

- **reconnect.ps1** — the watcher. Runs every minute. Already connected → exits silently in <0.5 s. Dropped → deletes stale connections + the `LanmanCached` credential cache (prevents `1219`), reconnects with explicit `user`+`password`, re-maps the drive letter, and if all three rounds fail it clears the cache again so *manual* reconnect still works.
- **boot_connect.ps1** — the boot persister. Runs once at startup, tries every 30 s for up to 2 h, then exits and lets the watcher take over.
- **launcher.py** — the windowless starter. pythonw + `CREATE_NO_WINDOW` so nothing ever flashes.

Plus two install-time artifacts: a **startup-folder VBS** (the guaranteed fallback, no permission needed) and a **scheduled task** (redundancy, auto-degrading).

## Install / 安装

On each client, run the installer once (no admin needed):

```powershell
# scripted (for admins / automation)
.\installer.ps1 -HostName SERVER -Ip 10.0.0.5 -ShareName FShare `
                -Username alice -Password 'P@ss' -DriveLetter Z

# or just double-click / run it and answer the prompts
```

The installer: cleans old credentials → stores `cmdkey` for both host and IP targets → writes `sharecred.ini` → tests the connection (IP first, computer name fallback) → installs the startup-folder fallback → installs the scheduled task (auto-degrading) → runs one reconnect immediately.

The shared-folder account and its password live only in `sharecred.ini` next to the scripts — never in the scripts themselves. That file is git-ignored.

## Uninstall / 卸载

```powershell
# remove the scheduled task
Unregister-ScheduledTask -TaskName FShareAutoReconnect -Confirm:$false
# remove the startup-folder fallback
del "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\FShareAutoReconnect.vbs"
# drop the stored credentials
cmdkey /delete:SERVERNAME
cmdkey /delete:10.0.0.5   # the IP you used
# optionally remove the mapped drive
net use Z: /delete /y
```

## Requirements / 要求

- Windows (works on 10 and 11). PowerShell 5.1 compatible.
- The client and host must be on the same network and the shared-folder account must be able to access the share.
- Python is **optional** — only needed for the windowless launcher; without it the scripts fall back to hidden PowerShell.

## File layout / 文件结构

```
installer.ps1         # one-time, no-admin install
reconnect.ps1         # the watcher (runs every minute)
boot_connect.ps1      # boot persister (30 s x 2 h)
launcher.py           # windowless starter (pythonw + CREATE_NO_WINDOW)
sharecred.example.ini # config template (copy to sharecred.ini)
LICENSE               # MIT
```

## Notes / 注意

- The host's IP is in `sharecred.ini`. If the host moves to a different network and its IP changes, edit that file.
- The reconnect watcher never blocks a *manual* reconnect: after three failed rounds it clears the credential cache so a hand-typed `net use` still works.
- Loopback self-tests (`\\<own-ip>\\share` from the host) are unreliable — Windows bypasses SMB auth for loopback, so a success there proves nothing about real clients.

## License / 许可

MIT. See [LICENSE](LICENSE).
