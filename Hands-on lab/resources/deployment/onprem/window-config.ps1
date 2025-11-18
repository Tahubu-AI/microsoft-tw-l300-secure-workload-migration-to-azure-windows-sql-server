<#
    Arc-enables a virtual machine.
#>
Configuration ArcConnect {
    Param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$MachineName,

        [Parameter(Mandatory)]
        [string]$Location
    )
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'

    Node "localhost" {
        # 1. Set environment variable to override the ARC on an Azure VM installation
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

        # 2. Disable Windows Azure guest agent to allow Azure Arc Service connection installation
        Service DisableGuestAgent {
            DependsOn  = '[Script]SetArcTestEnvVar'
            Name = 'WindowsAzureGuestAgent'
            StartupType = 'Disabled'
            State = 'Stopped'
        }

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
