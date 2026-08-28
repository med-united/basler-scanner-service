<#
.SYNOPSIS
    Installs the Basler scanner service on Windows.

.DESCRIPTION
    Installs uv, downloads scanner.py, creates its Python environment and
    registers a scheduled task that starts the service at logon without a
    console window.

    Prerequisite: the Basler pylon Software Suite (the USB camera driver) has to
    be installed once by hand — Basler gates that download behind an account, so
    no script can fetch it. See https://www.baslerweb.com/pylon.

.EXAMPLE
    irm https://raw.githubusercontent.com/med-united/basler-scanner-service/main/install.ps1 | iex
#>
[CmdletBinding()]
param(
    # Below Windows' ephemeral port range (49152+), so it cannot collide with an
    # outbound socket, and clear of the usual development ports.
    [int]$Port = 41234,
    [string]$InstallDir = "$env:LOCALAPPDATA\basler-scanner-service",
    [string]$TaskName = "Basler Scanner"
)

$ErrorActionPreference = "Stop"
$source = "https://raw.githubusercontent.com/med-united/basler-scanner-service/main/scanner.py"

# 1. uv runs the service and fetches the Python version pinned in scanner.py.
#    Its installer ends in "catch { exit 1 }", which would terminate this whole
#    session if we ran it inline, so give it a process of its own.
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Host "Installing uv..."
    powershell -NoProfile -ExecutionPolicy Bypass `
               -Command "irm https://astral.sh/uv/install.ps1 | iex"
    if ($LASTEXITCODE -ne 0) {
        throw "uv installation failed with exit code $LASTEXITCODE."
    }
    # The installer only updates PATH for new shells; make uv usable right now.
    $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
}
$uvCommand = Get-Command uv -ErrorAction SilentlyContinue
if (-not $uvCommand) {
    throw "uv is still not on PATH after installing. Open a new PowerShell window and run this script again."
}
$uv = $uvCommand.Source
Write-Host "uv: $uv" -ForegroundColor Green

# uvw.exe is uv's windowless variant. The task runs it so that the service
# starts without a console window.
$uvwCommand = Get-Command uvw -ErrorAction SilentlyContinue
if (-not $uvwCommand) {
    throw "uvw is not on PATH. Open a new PowerShell window and run this script again."
}
$uvw = $uvwCommand.Source
Write-Host "uvw: $uvw" -ForegroundColor Green

# 2. The service is a single file, so there is nothing else to fetch.
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$script = Join-Path $InstallDir "scanner.py"
Write-Host "Downloading scanner.py to $script..."
Invoke-WebRequest $source -OutFile $script

# 3. Build the environment now, so the first start is not also a download.
Write-Host "Creating the Python environment (downloads CPython 3.13 once)..."
& $uv sync --script $script

# 4. Register the task that starts the service at logon.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}
$action = New-ScheduledTaskAction -Execute $uvw `
                                  -Argument "run `"$script`" $Port" `
                                  -WorkingDirectory $InstallDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
# Give the USB camera time to enumerate before the first start attempt.
$trigger.Delay = "PT10S"
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
                                        -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                                         -DontStopIfGoingOnBatteries `
                                         -ExecutionTimeLimit ([TimeSpan]::Zero) `
                                         -RestartInterval (New-TimeSpan -Minutes 1) `
                                         -RestartCount 999 `
                                         -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                       -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

# 5. Confirm the camera answers, since the task itself is silent.
$url = "http://127.0.0.1:$Port/preview.jpg"
Write-Host "Waiting for $url ..."
$ok = $false
foreach ($attempt in 1..20) {
    Start-Sleep -Seconds 1
    try {
        if ((Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) {
            $ok = $true
            break
        }
    } catch { }
}

if ($ok) {
    Write-Host "`nScanner service running on $url" -ForegroundColor Green
    Write-Host "It starts automatically at logon."
    Write-Host "`nOnly one process can open the camera, so release it before"
    Write-Host "configuring the camera in pylon Viewer (User Set Control):"
    Write-Host "  Stop-ScheduledTask  -TaskName `"$TaskName`""
    Write-Host "  Start-ScheduledTask -TaskName `"$TaskName`""
} else {
    throw "Service did not answer on $url. The usual causes are a missing pylon " +
          "Software Suite, a camera that is not plugged in, or pylon Viewer still " +
          "holding the camera. Stop the task and run this to see the error: " +
          "uv run `"$script`" $Port"
}
