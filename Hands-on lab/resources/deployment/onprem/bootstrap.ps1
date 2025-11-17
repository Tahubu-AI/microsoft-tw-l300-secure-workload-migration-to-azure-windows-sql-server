param(
    [string]$repoOwner,
    [string]$repoName
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path "C:\logs")) { New-Item -ItemType Directory -Path "C:\logs" }

Start-Transcript -Path "C:\logs\bootstrap.log" -Append

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

Write-Host "Registering scheduled task for guest VM creation..."
Write-Host "Using repo $repoOwner/$repoName..."

$persistentDir = "C:\startup-scripts"
if (-not (Test-Path $persistentDir)) { New-Item -ItemType Directory -Path $persistentDir }
Copy-Item "$scriptDir\create-guest-vms.ps1" $persistentDir -Force

# Build scheduled task to run create-guest-vms.ps1 at startup
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File C:\startup-scripts\create-guest-vms.ps1 -repoOwner $repoOwner -repoName $repoName"
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

Register-ScheduledTask -TaskName "CreateGuestVMs" -Action $action -Trigger $trigger -Principal $principal -Force

Write-Host "Scheduled task registered. Now starting Hyper-V installation..."

# Run install-hyper-v.ps1
Write-Host "Installing Hyper-V..."
& "$scriptDir\install-hyper-v.ps1"

if ($LASTEXITCODE -ne 0) {
    Write-Error "install-hyper-v.ps1 failed with exit code $LASTEXITCODE"
    Stop-Transcript
    exit $LASTEXITCODE
}

Stop-Transcript

exit 0