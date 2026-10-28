# fshare-autoreconnect - reconnect watcher
# Runs every minute (startup-folder VBS loop + scheduled task). Safe to run
# concurrently: a named mutex guarantees only one instance at a time.
#
# Reads everything from sharecred.ini next to this script - no hardcoding.
# Already connected -> silently exits in <0.5s.
# Dropped -> deletes stale connections + cached creds, reconnects with the
# explicit user+password, then re-maps the drive letter.
#
# sharecred.ini keys: host, ip, share, user, pass, drive, domain
[CmdletBinding()]
param()
$ErrorActionPreference = 'Continue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$credFile = Join-Path $dir 'sharecred.ini'
$log = Join-Path $dir 'reconnect.log'
$driveFile = Join-Path $dir 'drive.txt'

function Log([string]$msg) {
    try {
        ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $msg) | Add-Content -Path $log -Encoding utf8
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 262144) { (Get-Content $log -Tail 300) | Set-Content $log -Encoding utf8 }
    } catch { }
}

# ---- named mutex: another instance is running -> exit quietly ----
$lock = New-Object System.Threading.Mutex($false, 'Global\FShareAutoReconnectLock')
$acquired = $false
try { $acquired = $lock.WaitOne(200) } catch { }
if (-not $acquired) { exit 0 }

try {
    # ---- load sharecred.ini (key=value lines) ----
    $cfg = @{}
    if (Test-Path $credFile) {
        foreach ($line in (Get-Content $credFile)) {
            $line = $line.Trim()
            if ($line -and $line -notmatch '^#' -and $line -match '^([A-Za-z]+)=(.*)$') {
                $cfg[$Matches[1]] = $Matches[2]
            }
        }
    }
    $hostName = $cfg['host']; $ip = $cfg['ip']; $share = $cfg['share']
    $usr = $cfg['user']; $pwd = $cfg['pass']; $dom = $cfg['domain']
    if (-not $hostName -or -not $share -or -not $usr) {
        Log 'sharecred.ini missing or incomplete - run installer.ps1 first'; exit 1
    }
    $shareName = '\\' + $hostName + '\' + $share
    $shareIp = if ($ip) { '\\' + $ip + '\' + $share } else { $shareName }
    $userRef = if ($dom) { $dom + '\' + $usr } else { $hostName + '\' + $usr }
    $userFlag = '/user:' + $userRef + ' ' + $pwd
    if (-not $pwd) { $userFlag = ('/user:' + $userRef).Trim() }

    function RemapDrive([string]$target) {
        try {
            $letter = $driveLetter
            if (-not $letter -and (Test-Path $driveFile)) {
                $letter = (Get-Content $driveFile -Raw).Trim().TrimEnd(':')
            }
            if ($letter -and $letter.Length -eq 1) {
                if (-not (Test-Path ($letter + '\'))) {
                    $credPart = ''
                    if ($pwd) { $credPart = ' /user:' + $userRef + ' ' + $pwd }
                    $null = cmd /c ('net use ' + $letter + ': "' + $target + '"' + $credPart + ' /persistent:yes 2>&1')
                }
            }
        } catch { }
    }

    $driveLetter = if ($cfg['drive']) { $cfg['drive'] } else { '' }

    # 1) already connected -> fix drive map, exit quietly (the common path)
    if (Test-Path $shareIp -ErrorAction SilentlyContinue) { RemapDrive $shareIp; exit 0 }
    if (Test-Path $shareName -ErrorAction SilentlyContinue) { RemapDrive $shareName; exit 0 }

    # 2) dropped -> delete stale connections + cached creds (avoids 1219), reconnect
    Log 'share unreachable, reconnecting...'
    $null = cmd /c ('net use "' + $shareName + '" /delete /y 2>nul')
    if ($ip) { $null = cmd /c ('net use "' + $shareIp + '" /delete /y 2>nul') }
    $null = cmdkey /delete:('LanmanCached:' + $hostName) 2>&1
    if ($ip) { $null = cmdkey /delete:('LanmanCached:' + $ip) 2>&1 }
    Start-Sleep -Seconds 1

    $targets = @($shareName); if ($ip) { $targets = @($shareIp, $shareName) }
    $out = ''; $done = $false; $doneTarget = ''
    for ($i = 1; $i -le 3; $i++) {
        foreach ($t in $targets) {
            $out = ((cmd /c ('net use "' + $t + '" ' + $userFlag + ' /persistent:yes 2>&1')) | Out-String).Trim()
            if (Test-Path $t -ErrorAction SilentlyContinue) { $done = $true; $doneTarget = $t; break }
        }
        if ($done) { break }
        Start-Sleep -Seconds 3
    }

    if ($done) {
        Log ('reconnected: ' + $doneTarget + ' (explicit creds ' + $usr + ')')
        RemapDrive $doneTarget
        exit 0
    }

    # all 3 rounds failed -> clear the cache this attempt left, keep manual connect alive
    $null = cmdkey /delete:('LanmanCached:' + $hostName) 2>&1
    if ($ip) { $null = cmdkey /delete:('LanmanCached:' + $ip) 2>&1 }
    Log ('reconnect failed (3 rounds): ' + ($out -replace "`r?`n", ' | '))
    exit 1
}
finally {
    try { $lock.ReleaseMutex() } catch { }
}
