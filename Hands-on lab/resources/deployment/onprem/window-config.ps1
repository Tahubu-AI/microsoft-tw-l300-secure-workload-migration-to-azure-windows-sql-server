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
        [String]$Location
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
            SetScript = {
                # Disable the Server Manager scheduled task
                Get-ScheduledTask -TaskName 'ServerManager' | Disable-ScheduledTask
            }
            TestScript = {
                # Check if the task is already disabled
                $task = Get-ScheduledTask -TaskName 'ServerManager'
                return ($task.State -eq 'Disabled')
            }
            GetScript = {
                # Return current state for reporting
                $task = Get-ScheduledTask -TaskName 'ServerManager'
                @{ Result = $task.State }
            }
        }

        # Disable Microsoft Edge sidebar
        Registry DisableEdgeSidebar {
            Key       = 'HKLM\SOFTWARE\Policies\Microsoft\Edge'
            ValueName = 'HubsSidebarEnabled'
            ValueData = 0
            ValueType = 'Dword'
            Ensure    = 'Present'
        }

        # Disable Microsoft Edge first-run Welcome screen
        Registry DisableEdgeFirstRun {
            Key       = 'HKLM\SOFTWARE\Policies\Microsoft\Edge'
            ValueName = 'HideFirstRunExperience'
            ValueData = 1
            ValueType = 'Dword'
            Ensure    = 'Present'
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
                Install-Module -Name Az.ConnectedMachine -Force -AllowClobber
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
                Connect-AzConnectedMachine -ResourceGroupName $using:ResourceGroupName -Name $using:MachineName -Location $using:Location
            }
        }
    }
}
