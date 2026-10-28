# fshare-autoreconnect - installer
# Runs once on each client, NO admin rights required.
#
# Usage (scripted, for admins/automation):
#   .\installer.ps1 -HostName HOST -Ip 10.0.0.5 -ShareName FShare `
#                   -Username alice -Password 'P@ss' -DriveLetter Z
# Usage (interactive): just run it, it asks each question.
#
# It then writes sharecred.ini, stores cmdkey credentials, tests the connect,
# installs a startup-folder VBS fallback (no permission needed), and a
# scheduled task on top (auto-degrades if the logon trigger is denied).
[CmdletBinding()]
param(
    [string]$HostName,
    [string]$Ip,
    [string]$ShareName,
    [string]$Username,
    [string]$Password,
    [string]$DriveLetter
)
$ErrorActionPreference = 'Continue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rc = Join-Path $dir 'reconnect.ps1'
$credFile = Join-Path $dir 'sharecred.ini'
$taskName = 'FShareAutoReconnect'
$launcher = Join-Path $dir 'launcher.py'

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  fshare-autoreconnect installer' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

if (-not (Test-Path $rc)) { Write-Host 'reconnect.ps1 not found - copy the whole folder first.' -ForegroundColor Red; Read-Host 'Press Enter to exit'; exit 1 }

function Ask([string]$prompt, [string]$default) {
    if ($default) { $prompt = $prompt + ' [' + $default + ']' }
    $v = (Read-Host $prompt).Trim()
    if ($v.Length -eq 0 -and $default) { $v = $default }
    return $v
}

# ---- gather connection settings (param wins, else ask) ----
if (-not $HostName)    { $HostName    = Ask 'SMB host (computer name)' '' }
if (-not $Ip)          { $Ip          = Ask 'SMB host IPv4 (preferred)' '' }
if (-not $ShareName)   { $ShareName   = Ask 'Share name' 'FShare' }
if (-not $Username)    { $Username    = Ask 'Shared-folder account (domain\user or bare name)' '' }
if (-not $Password)    {
    $sec = Read-Host 'Password for that account' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
if ($null -eq $DriveLetter -or $DriveLetter -eq '__ask__') { $DriveLetter = '' }
if (-not $DriveLetter) { $DriveLetter = Ask 'Map to a drive letter (leave blank = none)' '' }

if (-not $HostName) { Write-Host 'Host is required.' -ForegroundColor Red; Read-Host 'Press Enter to exit'; exit 1 }

$shareName = '\\' + $HostName + '\' + $ShareName
$shareIp   = if ($Ip) { '\\' + $Ip + '\' + $ShareName } else { $shareName }

# account: allow "user" (use host as domain) or "domain\user"
if ($Username -match '^([^\\]+)\\(.+)$') { $dom = $Matches[1]; $usr = $Matches[2] }
else { $dom = $HostName; $usr = $Username }
$userRef = $dom + '\' + $usr

Write-Host ''
Write-Host ('  host : ' + $HostName) -ForegroundColor DarkGray
Write-Host ('  ip   : ' + $(if ($Ip) { $Ip } else { '(computer name only)' })) -ForegroundColor DarkGray
Write-Host ('  share: ' + $ShareName) -ForegroundColor DarkGray
Write-Host ('  user : ' + $userRef) -ForegroundColor DarkGray
Write-Host ('  drive: ' + $(if ($DriveLetter) { $DriveLetter } else { '(none)' })) -ForegroundColor DarkGray
Write-Host ''

# ---- 0) clean old credentials + old connections ----
Write-Host 'Cleaning old credentials and connections...' -ForegroundColor Yellow
foreach ($ct in @($HostName, $Ip, '\\' + $HostName + '\' + $ShareName, ('LanmanCached:' + $HostName), ('LanmanCached:' + $Ip))) {
    if ($ct) { $null = cmdkey /delete:$ct 2>&1 }
}
$null = cmd /c ("net use `"$shareName`" /delete /y 2>nul")
if ($Ip) { $null = cmd /c ("net use `"$shareIp`" /delete /y 2>nul") }
Write-Host 'done' -ForegroundColor Green

# ---- 1) store credentials (cmdkey for both targets + sharecred.ini) ----
$c1 = cmdkey /add:$HostName /user:$userRef /pass:$Password 2>&1
if ($LASTEXITCODE -eq 0) { Write-Host ('  credentials stored (host target): ' + $userRef) -ForegroundColor Green }
else { Write-Host ('  cmdkey host failed: ' + ($c1 | Out-String).Trim()) -ForegroundColor Yellow }
if ($Ip) {
    $c2 = cmdkey /add:$Ip /user:$userRef /pass:$Password 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Host ('  credentials stored (ip target): ' + $Ip) -ForegroundColor Green }
}

$ini = @"
host=$HostName
ip=$Ip
share=$ShareName
user=$usr
pass=$Password
drive=$DriveLetter
domain=$dom
"@
Set-Content -Path $credFile -Value $ini -Encoding utf8
Write-Host ('  wrote ' + $credFile) -ForegroundColor Green

# ---- 2) map drive letter (optional) ----
if ($DriveLetter -and $DriveLetter.Length -eq 1) {
    Set-Content -Path (Join-Path $dir 'drive.txt') -Value $DriveLetter -Encoding utf8
    Write-Host ('  will keep ' + $DriveLetter.ToUpper() + ': mapped') -ForegroundColor Green
} else {
    Remove-Item (Join-Path $dir 'drive.txt') -ErrorAction SilentlyContinue
}

# ---- 3) explicit-credential test: IP first, computer name fallback ----
Write-Host ''
Write-Host 'Testing connection with explicit credentials...'
$targets = @($shareName); if ($Ip) { $targets = @($shareIp, $shareName) }
$okTarget = ''
foreach ($t in $targets) {
    $null = cmd /c ("net use `"$t`" /delete /y 2>nul")
    Start-Sleep -Milliseconds 400
    $r = (cmd /c ("net use `"$t`" /user:$userRef $Password /persistent:yes 2>&1") | Out-String).Trim()
    if (Test-Path $t) { $okTarget = $t; break }
    Write-Host ('  ' + $t + ' failed: ' + ($r -replace "`r?`n", ' | ')) -ForegroundColor DarkGray
    Start-Sleep -Seconds 1
}
if ($okTarget) { Write-Host ('  connected: ' + $okTarget) -ForegroundColor Green }
else {
    $null = cmdkey /delete:('LanmanCached:' + $HostName) 2>&1
    if ($Ip) { $null = cmdkey /delete:('LanmanCached:' + $Ip) 2>&1 }
    Write-Host '  still cannot connect. Check host is on, same network, account/password correct.' -ForegroundColor Red
    Read-Host 'Press Enter to exit'; exit 1
}

# ---- 4) fallback: startup-folder VBS loop (no permission needed) ----
Write-Host ''
Write-Host 'Installing fallback (startup-folder loop, no admin needed)...' -ForegroundColor Yellow
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$pythonw = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
if (-not $pythonw) {
    foreach ($pat in @("$env:LocalAppData\Programs\Python\Python*\pythonw.exe", "$env:ProgramFiles\Python*\pythonw.exe", "$env:ProgramFiles(x86)\Python*\pythonw.exe")) {
        $hit = Get-Item $pat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $pythonw = $hit.FullName; break }
    }
}
$hasPythonw = (Test-Path $launcher) -and $pythonw
$startup = [Environment]::GetFolderPath('Startup')
$vbs = Join-Path $startup 'FShareAutoReconnect.vbs'
if ($hasPythonw) { $inspectCmd = '"' + $pythonw + '" "' + $launcher + '" reconnect.ps1' }
else { $inspectCmd = '"' + $psExe + '" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $rc + '"' }
$bootPs = Join-Path $dir 'boot_connect.ps1'
$bootCmd = '"' + $psExe + '" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $bootPs + '"'
$body = 'Set sh = CreateObject("WScript.Shell")' + "`r`n" +
        'sh.Run "' + $bootCmd + '", 0, True' + "`r`n" +
        'Do' + "`r`n" +
        '  sh.Run "' + $inspectCmd + '", 0, True' + "`r`n" +
        '  WScript.Sleep 60000' + "`r`n" +
        'Loop' + "`r`n"
Set-Content -Path $vbs -Value $body -Encoding Default
Write-Host ('  installed: ' + $vbs + ' (boot persist + 60s loop)') -ForegroundColor Green

# ---- 5) redundancy: scheduled task (-ErrorAction Stop, auto-degrade, never fake) ----
Write-Host 'Installing scheduled task (redundant, failure does not affect fallback)...' -ForegroundColor Yellow
if ($hasPythonw) { $taskExec = $pythonw; $taskArg = '"' + $launcher + '" reconnect.ps1' }
else { $taskExec = $psExe; $taskArg = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $rc + '"' }
$created = $false; $degraded = $false
try {
    $act = New-ScheduledTaskAction -Execute $taskExec -Argument $taskArg -ErrorAction Stop
    $t1 = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME -ErrorAction Stop
    $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -ErrorAction Stop
    $set = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $taskName -Action $act -Trigger @($t1, $t2) -Settings $set -Description 'fshare-autoreconnect: reconnect on logon + every minute' -Force -ErrorAction Stop | Out-Null
    $created = $true
    Write-Host ('  installed: ' + $taskName + ' (logon trigger + every minute)') -ForegroundColor Green
} catch {
    Write-Host ('  full version denied (' + $_.Exception.Message + '), trying repeat-only...') -ForegroundColor DarkYellow
    try {
        $act = New-ScheduledTaskAction -Execute $taskExec -Argument $taskArg -ErrorAction Stop
        $t2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -ErrorAction Stop
        $set = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $taskName -Action $act -Trigger @($t2) -Settings $set -Description 'fshare-autoreconnect: reconnect every minute' -Force -ErrorAction Stop | Out-Null
        $created = $true; $degraded = $true
        Write-Host ('  installed (degraded, repeat-only, no logon trigger): ' + $taskName) -ForegroundColor Green
    } catch {
        Write-Host ('  scheduled task failed (' + $_.Exception.Message + '). Fallback still works.') -ForegroundColor Yellow
    }
}

# ---- 6) run once now ----
Write-Host ''
& $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $rc
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  Done. Shared folders will reconnect within a minute of dropping.' -ForegroundColor Cyan
Write-Host ('  log: ' + (Join-Path $dir 'reconnect.log')) -ForegroundColor Cyan
if (-not $created) { Write-Host '  note: scheduled task not installed; startup-folder fallback covers it.' -ForegroundColor DarkYellow }
Write-Host '============================================================' -ForegroundColor Cyan
Read-Host 'Press Enter to exit'
