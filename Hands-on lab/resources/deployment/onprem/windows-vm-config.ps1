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

        # Disable Windows Azure guest agent to allow Azure Arc Service connection installation
        Service DisableGuestAgent {
            DependsOn  = '[Script]SetArcTestEnvVar'
            Name = 'WindowsAzureGuestAgent'
            StartupType = 'Disabled'
            State = 'Stopped'
        }

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

        # Install Arc Connected Machine Module
        Script InstallConnectedMachineModule {
            DependsOn = '[Service]DisableGuestAgent'
            GetScript = {
                $module = Get-InstalledModule -Name Az.ConnectedMachine -ErrorAction SilentlyContinue
                if ($null -ne $module) {
                    @{ Result = "Installed version $($module.Version)" }
                } else {
                    @{ Result = "Not installed" }
                }
            }
            TestScript = {
                $module = Get-InstalledModule -Name Az.ConnectedMachine -ErrorAction SilentlyContinue
                $null -ne $module
            }
            SetScript = {
                Write-Verbose "Installing Az.ConnectedMachine module..."
                Install-Module -Name Az.ConnectedMachine -Force -AllowClobber -ErrorAction Stop
            }
        }

        # Connect the machine to Azure Arc
        Script ConnectArcMachine {
            DependsOn = '[Script]InstallConnectedMachineModule'
            GetScript = {
                # Check if the machine is already connected
                try {
                    $connected = Get-AzConnectedMachine -ResourceGroupName $using:ResourceGroupName -Name $using:MachineName -ErrorAction SilentlyContinue
                    if ($null -ne $connected) {
                        @{ Result = "Connected to Arc: $($connected.Name)" }
                    } else {
                        @{ Result = "Not connected" }
                    }
                } catch {
                    @{ Result = "Not connected" }
                }
            }
            TestScript = {
                # Return $true if the machine is already connected
                $connected = Get-AzConnectedMachine -ResourceGroupName $using:ResourceGroupName -Name $using:MachineName -ErrorAction SilentlyContinue
                $null -ne $connected
            }
            SetScript = {
                Write-Verbose "Connecting machine to Azure Arc..."
                Connect-AzConnectedMachine -SubscriptionId $using:SubscriptionId -ResourceGroupName $using:ResourceGroupName -Name $using:MachineName -Location $using:Location -ErrorAction Stop
            }
        }
    }
}
