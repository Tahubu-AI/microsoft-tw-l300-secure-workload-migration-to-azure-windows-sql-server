<#
.File Name
 - create-guest-vms.ps1

.What does this script do?
 - Creates an Internal Switch in Hyper-V called "NAT Switch"
 - Downloads an Image of Windows Server 2022 Datacenter to the local drive
 - Add a new IP address to the Internal Network for Hyper-V attached to the NAT Switch
 - Creates a NAT Network on 192.168.0.0/24
 - Creates the Virtual Machine in Hyper-V
 - Issues a Start Command for the new "OnPremVM"
#>

Configuration Main {
        param (
                [string]$repoOwner,
                [string]$repoName
        )

        Import-DscResource -ModuleName 'PSDesiredStateConfiguration'

	node "localhost" {
		Script ConfigureHyperVGuestVMs
    	        {
			TestScript =  { return $false }
                        GetScript =  { @{Result = "ConfigureHyperVGuestVMs"} }
			SetScript = {
                                Write-Host "Repository Owner: $using:repoOwner"
                                Write-Host "Repository Name: $using:repoName"
                                # Install and configure DHCP service (used by Hyper-V nested VMs)
                                $dnsClient = Get-DnsClient | Where-Object {$_.InterfaceAlias -eq "Ethernet" }
                                $dhcpScope = Get-DhcpServerv4Scope
                                if ($dhcpScope.Name -ne "TechWorkshop") {
                                Add-DhcpServerv4Scope -Name "TechWorkshop" `
                                        -StartRange 192.168.0.100 `
                                        -EndRange 192.168.0.200 `
                                        -SubnetMask 255.255.255.0 `
                                        -LeaseDuration 1.00:00:00 `
                                        -State Active
                                }

                                $dhcpOptions = Get-DhcpServerv4OptionValue                      
                                if ($dhcpOptions.Count -lt 3) {
                                        # Set DHCP options to match NAT gateway
                                        Set-DhcpServerv4OptionValue -ComputerName localhost `
                                                -DnsDomain $dnsClient.ConnectionSpecificSuffix `
                                                -DnsServer 8.8.8.8 `
                                                -Router 192.168.0.1
                                        Restart-Service dhcpserver
                                }

                                # Create the NAT network
                                New-NetNat -Name NestedVMNATnetwork -InternalIPInterfaceAddressPrefix 192.168.0.0/24 -Verbose

                                # Create the Internal Switch with NAT
                                New-VMSwitch -Name 'NAT Switch' -SwitchType Internal

                                $NatSwitch = Get-NetAdapter -Name "vEthernet (NAT Switch)"
                                # Create an internal network (gateway first)
                                New-NetIPAddress -IPAddress 192.168.0.1 -PrefixLength 24 -InterfaceIndex $NatSwitch.ifIndex

                                # Enable Enhanced Session Mode on Host
                                Set-VMHost -EnableEnhancedSessionMode $true

                                # Download and create the Windows Server Guest VM
                                $cloneDir = "C:\git"
                                mkdir $cloneDir
                                Set-Location $cloneDir

                                git lfs install --skip-smudge
                                git clone --quiet --single-branch "https://github.com/$using:repoOwner/$using:repoName.git"
                                Set-Location "$cloneDir\$using:repoName\"
                                git pull
                                git lfs pull
                                git lfs install --force

                                $downloadedFile = "$cloneDir\$using:repoName\Hands-on lab\resources\deployment\onprem\OnPremWinServerVM.zip"
                                
                                $vmFolder = "C:\VM"

                                Add-Type -assembly "system.io.compression.filesystem"
                                [io.compression.zipfile]::ExtractToDirectory($downloadedFile, $vmFolder)
                                # The following command was used to Zip up the VM files originally
                                # [io.compression.zipfile]::CreateFromDirectory("C:\OnPremWinServerVM", "C:\OnPremWinServerVM.zip")

                                # Create the Windows Server Guest VM
                                New-VM -Name OnPremVM `
                                        -MemoryStartupBytes 2GB `
                                        -BootDevice VHD `
                                        -VHDPath "$vmFolder\WinServer\Virtual Hard Disks\WinServer.vhdx" `
                                        -Path "$vmFolder\WinServer\Virtual Hard Disks" `
                                        -Generation 1 `
                                        -Switch "NAT Switch"

                                Start-VM -Name OnPremVM

                                # Create the SQL Server VM
                                # Hard-coded username and password for the nested SQL VM
                                $nestedWindowsUsername = "Administrator"
                                $nestedWindowsPassword = "JS123!!"

                                # Create Windows credential object
                                $secWindowsPassword = ConvertTo-SecureString $nestedWindowsPassword -AsPlainText -Force
                                $winCreds = New-Object System.Management.Automation.PSCredential ($nestedWindowsUsername, $secWindowsPassword)

                                $sqlVmVhdPath = "C:\VM\SQLServer"
                                mkdir $sqlVmVhdPath
                                $sqlVMName = "OnPremSQLVM"

                                $vhdImageToDownload = "JSSQLStd19Base.vhdx"
                                $sourceUrl = "https://jumpstartprodsg.blob.core.windows.net/scenarios/prod/$vhdImageToDownload"
                                $destinationPath = "$sqlVmVhdPath\$vhdImageToDownload"

                                # Download the SQL Server VHD image
                                Invoke-WebRequest -Uri $sourceUrl -OutFile $destinationPath

                                # Create the SQL Server Guest VM
                                New-VM -Name $sqlVMName `
                                        -MemoryStartupBytes 2GB `
                                        -BootDevice VHD `
                                        -VHDPath "$sqlVmVhdPath\$vhdImageToDownload" `
                                        -Path "$sqlVmVhdPath" `
                                        -Generation 2 `
                                        -Switch "NAT Switch"

                                $timeout = 600 # seconds

                                Start-VM -Name $sqlVMName
                                Wait-VM -Name $sqlVMName -For Running -Timeout $timeout

                                # Wait until the VM is running
                                if ((Get-VM -Name $sqlVMName).State -ne 'Running') {
                                        Write-Error "VM $sqlVMName did not reach 'Running' state within $timeout seconds."
                                }

                                $sqlConfigFileName = "sql-vm-config.ps1"
                                $sqlConfigFile = "$cloneDir\$using:repoName\Hands-on lab\resources\deployment\onprem\$sqlConfigFileName"

                                # Create a PowerShell Direct session into the SQL VM
                                $session = New-PSSession -VMName $sqlVMName -Credential $winCreds

                                # Ensure destination folder exists inside the VM
                                Invoke-Command -Session $session -ScriptBlock {
                                New-Item -ItemType Directory -Path "C:\scripts" -Force | Out-Null
                                }

                                # Copy the config script from host into the guest VM
                                Copy-Item -Path $sqlConfigFile -Destination "C:\scripts\sql-vm-config.ps1" -ToSession $session

                                # Run the config script inside the SQL VM
                                Invoke-Command -Session $session -ScriptBlock {
                                        powershell -ExecutionPolicy Bypass -File "C:\scripts\sql-vm-config.ps1" `
                                                -repoOwner $using:repoOwner `
                                                -repoName $using:repoName
                                }

                                # Clean up session
                                Remove-PSSession $session
			}
		}	
  	}
}
