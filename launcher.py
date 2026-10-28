# fshare-autoreconnect - windowless launcher
# Win11's default terminal swallows powershell's -WindowStyle Hidden, so a
# background loop pops a console. pythonw.exe is a GUI child process with no
# console at all; launching powershell from it with CREATE_NO_WINDOW means the
# powershell inherits "no console" and the hand-off is permanently silent.
#
# Usage: pythonw.exe launcher.py [script]   (default: reconnect.ps1)
import os
import subprocess
import sys

d = os.path.dirname(os.path.abspath(__file__))
ps = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"),
                  "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
script = sys.argv[1] if len(sys.argv) > 1 and os.path.basename(sys.argv[1]) else "reconnect.ps1"
target = os.path.join(d, script)
subprocess.Popen(
    [ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
     "-File", target],
    creationflags=0x08000000,  # CREATE_NO_WINDOW
    close_fds=True,
)
