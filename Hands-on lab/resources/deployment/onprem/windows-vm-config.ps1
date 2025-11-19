<#
    Arc-enables a virtual machine.
#>
Configuration ArcConnect {
    Param(
        [Parameter(Mandatory)]
        [String]$ResourceGroupName,

        [Parameter(Mandatory)]
        [String]$MachineName,

        [Parameter(Mandatory)]
        [String]$Location,

        [Parameter(Mandatory)]
        [String]$SubscriptionId
    )
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'

    Node "localhost" {
        # Disable the Server Manager from starting on login
        Script DisableServerManager {
            GetScript = {
                # Return current state for reporting
                $task = Get-ScheduledTask -TaskName 'ServerManager'
                @{ Result = $task.State }
            }
            TestScript = {
                # Check if the task is already disabled
                $task = Get-ScheduledTask -TaskName 'ServerManager'
                return ($task.State -eq 'Disabled')
            }
            SetScript = {
                # Disable the Server Manager scheduled task
                Get-ScheduledTask -TaskName 'ServerManager' | Disable-ScheduledTask -ErrorAction SilentlyContinue
            }
        }

        # Disable Microsoft Edge features
        Script DisableEdgeFeatures {
            GetScript = {
                $EdgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"

                if (Test-Path $EdgePolicyPath) {
                    $props = Get-ItemProperty -Path $EdgePolicyPath -ErrorAction SilentlyContinue
                    @{
                        HideFirstRunExperience       = $props.HideFirstRunExperience
                        DefaultBrowserSettingEnabled = $props.DefaultBrowserSettingEnabled
                        HubsSidebarEnabled           = $props.HubsSidebarEnabled
                    }
                }
                else {
                    @{ Result = "Edge policy key not present" }
                }
            }
            TestScript = {
                $EdgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"

                # If the key doesn't exist, we need to run SetScript
                if (-not (Test-Path $EdgePolicyPath)) {
                    return $false
                }

                $props = Get-ItemProperty -Path $EdgePolicyPath -ErrorAction SilentlyContinue

                # Check if all desired values are already set
                return (
                    ($props.HideFirstRunExperience -eq 1) -and
                    ($props.DefaultBrowserSettingEnabled -eq 0) -and
                    ($props.HubsSidebarEnabled -eq 0)
                )
            }
            SetScript = {
                # Registry path for Edge policy
                $EdgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"

                # Create the key if it doesn't exist
                if (-not (Test-Path $EdgePolicyPath)) {
                    New-Item -Path $EdgePolicyPath -Force | Out-Null
                }

                Set-ItemProperty -Path $EdgePolicyPath -Name "HideFirstRunExperience" -Type DWord -Value 1 -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $EdgePolicyPath -Name "DefaultBrowserSettingEnabled" -Type DWord -Value 0 -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $EdgePolicyPath -Name "HubsSidebarEnabled" -Type DWord -Value 0 -ErrorAction SilentlyContinue

                Write-Verbose "Microsoft Edge First Run Experience disabled successfully."
            }
        }

        # Set environment variable to override the ARC on an Azure VM installation
        Script SetArcTestEnvVar {
            GetScript = {
                $val = [System.Environment]::GetEnvironmentVariable("MSFT_ARC_TEST",'Machine')
                @{ Result = $val }
            }
            TestScript = {
                [System.Environment]::GetEnvironmentVariable("MSFT_ARC_TEST",'Machine') -eq 'true'
            }
            SetScript = {
                Write-Verbose "Setting MSFT_ARC_TEST environment variable..."
                [System.Environment]::SetEnvironmentVariable("MSFT_ARC_TEST",'true',[System.EnvironmentVariableTarget]::Machine)
            }
        }

        Script ScheduleArcOnboarding {
            DependsOn = '[Script]SetArcTestEnvVar'
            GetScript = {
                $task = Get-ScheduledTask -TaskName 'ArcOnboardAfterDSC' -ErrorAction SilentlyContinue
                if ($null -ne $task) { @{ Result = "Scheduled" } } else { @{ Result = "NotScheduled" } }
            }
            TestScript = {
                $task = Get-ScheduledTask -TaskName 'ArcOnboardAfterDSC' -ErrorAction SilentlyContinue
                return ($null -ne $task)
            }
            SetScript = {
                try {
                    Write-Verbose "Preparing path for Arc onboarding payload..."
                    $prepDir    = 'C:\ArcPrep'
                    $scriptPath = Join-Path $prepDir 'ArcOnboard.ps1'

                    if (-not (Test-Path -LiteralPath $prepDir)) {
                        New-Item -Path $prepDir -ItemType Directory -Force | Out-Null
                    }

                    # Write payload script with Guest Agent disable + module install + Arc connect
                    @"
Start-Transcript -Path 'C:\ArcPrep\ArcOnboard.log' -Append

try {
    Write-Output 'Disabling WindowsAzureGuestAgent...'
    Stop-Service WindowsAzureGuestAgent -Force -ErrorAction SilentlyContinue
    Set-Service WindowsAzureGuestAgent -StartupType Disabled
} catch {
    Write-Warning "Failed to disable Guest Agent: `$($_.Exception.Message)"
}

try {
    Write-Output 'Installing Az.ConnectedMachine module...'
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    Install-Module -Name Az.ConnectedMachine -Force -AllowClobber -ErrorAction Stop
} catch {
    Write-Error "Failed to install Az.ConnectedMachine: `$($_.Exception.Message)"
    Stop-Transcript
    exit 1
}

try {
    Write-Output 'Connecting machine to Azure Arc...'
    `$result = Connect-AzConnectedMachine `
        -SubscriptionId '$using:SubscriptionId' `
        -ResourceGroupName '$using:ResourceGroupName' `
        -Name '$using:MachineName' `
        -Location '$using:Location' `
        -ErrorAction Stop

    if (`$null -eq `$result) { throw 'Connect-AzConnectedMachine returned null.' }
    Write-Output 'Arc connect succeeded.'
} catch {
    Write-Error "Arc connect failed: `$($_.Exception.Message)"
    Stop-Transcript
    exit 1
}

try {
    Write-Output 'Self-deleting scheduled task...'
    schtasks /Delete /TN 'ArcOnboardAfterDSC' /F | Out-Null
} catch {
    Write-Warning "Task self-delete failed: `$($_.Exception.Message)"
}

Stop-Transcript
"@ | Set-Content -Path $scriptPath -Encoding UTF8 -Force

                    Write-Verbose "Creating scheduled task to run Arc onboarding payload..."
                    $taskAction    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
                    $taskTrigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2)
                    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
                    $taskSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

                    Register-ScheduledTask -TaskName 'ArcOnboardAfterDSC' `
                        -Action $taskAction `
                        -Trigger $taskTrigger `
                        -Principal $taskPrincipal `
                        -Settings $taskSettings -Force | Out-Null

                    Write-Verbose "Scheduled task created. It will disable Guest Agent, install module, connect to Arc, and then delete itself."
                } catch {
                    Write-Error "Failed to schedule Arc onboarding task: $($_.Exception.Message)"
                    throw
                }
            }
        }
    }
}
