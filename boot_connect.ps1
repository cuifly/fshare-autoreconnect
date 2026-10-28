# fshare-autoreconnect - boot persist reconnect
# At boot the network/host is often not ready, so a plain 60s loop would just
# idle. This script persists: every 30s it tries to connect, and once up it
# exits and hands off to reconnect.ps1 for routine watching. Max 2 hours (40
# tries). Uses the same named mutex so it never fights a running watcher.
#
# Reads everything from sharecred.ini - no hardcoding.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Continue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$credFile = Join-Path $dir 'sharecred.ini'
$log = Join-Path $dir 'reconnect.log'
$driveFile = Join-Path $dir 'drive.txt'

function Log([string]$msg) {
    try {
        ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  [boot] ' + $msg) | Add-Content -Path $log -Encoding utf8
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 262144) { (Get-Content $log -Tail 300) | Set-Content $log -Encoding utf8 }
    } catch { }
}

# mutex: a watcher is already running -> hand off, exit
$lock = New-Object System.Threading.Mutex($false, 'Global\FShareAutoReconnectLock')
$acquired = $false
try { $acquired = $lock.WaitOne(200) } catch { }
if (-not $acquired) { exit 0 }

try {
    $cfg = @{}
    if (Test-Path $credFile) {
        foreach ($line in (Get-Content $credFile)) {
            $line = $line.Trim()
            if ($line -and $line -notmatch '^#' -and $line -match '^([A-Za-z]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2] }
        }
    }
    $hostName = $cfg['host']; $ip = $cfg['ip']; $share = $cfg['share']
    $usr = $cfg['user']; $pwd = $cfg['pass']; $dom = $cfg['domain']
    if (-not $hostName -or -not $share -or -not $usr) { exit 1 }
    $shareName = '\\' + $hostName + '\' + $share
    $shareIp = if ($ip) { '\\' + $ip + '\' + $share } else { $shareName }
    $userRef = if ($dom) { $dom + '\' + $usr } else { $hostName + '\' + $usr }
    $userFlag = '/user:' + $userRef + ' ' + $pwd
    if (-not $pwd) { $userFlag = ('/user:' + $userRef).Trim() }

    # already up -> exit, watcher takes over
    if (Test-Path $shareIp -ErrorAction SilentlyContinue) { exit 0 }
    if (Test-Path $shareName -ErrorAction SilentlyContinue) { exit 0 }

    # persist: 40 tries x 30s ~ 2h
    for ($i = 1; $i -le 40; $i++) {
        $null = cmd /c ('net use "' + $shareIp + '" /delete /y 2>nul')
        $out = ((cmd /c ('net use "' + $shareIp + '" ' + $userFlag + ' /persistent:yes 2>&1')) | Out-String).Trim()
        if (Test-Path $shareIp -ErrorAction SilentlyContinue) {
            Log ('boot reconnect ok (attempt ' + $i + ')')
            if (Test-Path $driveFile) {
                $letter = (Get-Content $driveFile -Raw).Trim().TrimEnd(':')
                if ($letter.Length -eq 1 -and -not (Test-Path ($letter + ':\'))) {
                    $credPart = ''
                    if ($pwd) { $credPart = ' /user:' + $userRef + ' ' + $pwd }
                    $null = cmd /c ('net use ' + $letter + ': "' + $shareIp + '"' + $credPart + ' /persistent:yes 2>&1')
                }
            }
            exit 0
        }
        if ($i -le 5) { Log ('boot reconnect attempt ' + $i + ' failed, retrying in 30s... ' + ($out -replace "`r?`n", ' | ')) }
        Start-Sleep -Seconds 30
    }
    Log 'boot reconnect still not up after 2h, handing to the 60s watcher'
    exit 1
}
finally {
    try { $lock.ReleaseMutex() } catch { }
}
