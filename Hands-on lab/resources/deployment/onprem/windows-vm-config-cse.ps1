<#
    Arc-enables a virtual machine using Custom Script Extension.
    Performs environment setup, disables Guest Agent, applies OS tweaks,
    installs Az.ConnectedMachine, and connects to Azure Arc.
#>

param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$MachineName,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter(Mandatory)]
    [string]$SubscriptionId
)

$logPath = "C:\deployment-logs"

if (-not (Test-Path $logPath)) {
    New-Item -ItemType Directory -Path $logPath -Force | Out-Null
}

Start-Transcript -Path "$logPath\sql-vm-config.log"

Write-Verbose "Starting ArcConnect script..."

# 1. Set environment variable to override ARC on Azure VM installation
Write-Verbose "Setting MSFT_ARC_TEST environment variable..."
[System.Environment]::SetEnvironmentVariable("MSFT_ARC_TEST",'true',[System.EnvironmentVariableTarget]::Machine)

# 2. Disable Windows Azure Guest Agent
Write-Verbose "Stopping and disabling WindowsAzureGuestAgent..."
try {
    Stop-Service WindowsAzureGuestAgent -Force -ErrorAction SilentlyContinue
    Set-Service WindowsAzureGuestAgent -StartupType Disabled
} catch {
    Write-Warning "Failed to disable Guest Agent: $($_.Exception.Message)"
}

# 3. Disable Server Manager auto-start
Write-Verbose "Disabling Server Manager scheduled task..."
try {
    $task = Get-ScheduledTask -TaskName 'ServerManager' -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Disable-ScheduledTask -TaskName 'ServerManager' -ErrorAction SilentlyContinue
    }
} catch {
    Write-Warning "Failed to disable Server Manager task: $($_.Exception.Message)"
}

# 4. Disable Microsoft Edge features
Write-Verbose "Applying Edge policy registry settings..."
$EdgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
if (-not (Test-Path $EdgePolicyPath)) {
    New-Item -Path $EdgePolicyPath -Force | Out-Null
}
Set-ItemProperty -Path $EdgePolicyPath -Name "HideFirstRunExperience" -Type DWord -Value 1 -ErrorAction SilentlyContinue
Set-ItemProperty -Path $EdgePolicyPath -Name "DefaultBrowserSettingEnabled" -Type DWord -Value 0 -ErrorAction SilentlyContinue
Set-ItemProperty -Path $EdgePolicyPath -Name "HubsSidebarEnabled" -Type DWord -Value 0 -ErrorAction SilentlyContinue

# 5. Install Az.ConnectedMachine module
Write-Verbose "Installing Az.ConnectedMachine module..."
try {
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    Install-Module -Name Az.ConnectedMachine -Force -AllowClobber -ErrorAction Stop
} catch {
    Write-Error "Failed to install Az.ConnectedMachine: $($_.Exception.Message)"
    throw
}

# 6. Connect the machine to Azure Arc
Write-Verbose "Connecting machine to Azure Arc..."
try {
    $result = Connect-AzConnectedMachine `
        -SubscriptionId $SubscriptionId `
        -ResourceGroupName $ResourceGroupName `
        -Name $MachineName `
        -Location $Location `
        -ErrorAction Stop

    if ($null -eq $result) {
        throw "Connect-AzConnectedMachine returned null — connection failed."
    } else {
        Write-Verbose "Successfully connected to Arc: $MachineName"
    }
} catch {
    Write-Error "Arc connect failed: $($_.Exception.Message)"
    throw
}

Write-Verbose "ArcConnect script completed."

Stop-Transcript
