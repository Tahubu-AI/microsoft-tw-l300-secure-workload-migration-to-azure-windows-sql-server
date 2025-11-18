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
        Param (
                [String]$DbBackupFileUrl,
                [String]$SqlConfigFileUrl,
                [String]$SqlVmImageUrl,
                [String]$WindowsVmImageUrl
        )
        Import-DscResource -ModuleName 'PSDesiredStateConfiguration'

	Node "localhost" {
                # 1. Install DHCP role
                Script InstallDHCP {
                        GetScript  = { @{ Result = (Get-WindowsFeature -Name DHCP).Installed } }
                        TestScript = { (Get-WindowsFeature -Name DHCP).Installed }
                        SetScript = {
                                Write-Verbose "Installing DHCP role"
                                Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction Stop
                        }
                }

                # 2. Configure DHCP scope and options
                Script ConfigureDHCP {
                        GetScript  = { @{ Result = (Get-DhcpServerv4Scope | Where-Object { $_.Name -eq "TechWorkshop" }) } }
                        TestScript = { (Get-DhcpServerv4Scope | Where-Object { $_.Name -eq "TechWorkshop" }) -ne $null }
                        SetScript  = {
                                Write-Verbose "Configuring DHCP scope 'TechWorkshop'..."
                                if (-not (Get-DhcpServerv4Scope | Where-Object { $_.Name -eq "TechWorkshop" })) {
                                Add-DhcpServerv4Scope -Name "TechWorkshop" `
                                        -StartRange 192.168.0.100 -EndRange 192.168.0.200 `
                                        -SubnetMask 255.255.255.0 -LeaseDuration 1.00:00:00 -State Active -ErrorAction Stop
                                }

                                Write-Verbose "Configuring DHCP options..."
                                $dnsClient = Get-DnsClient | Where-Object { $_.InterfaceAlias -eq "Ethernet" }
                                $currentOptions = Get-DhcpServerv4OptionValue -ComputerName localhost
                                if (-not $currentOptions.Router -or -not $currentOptions.DnsServer) {
                                        Set-DhcpServerv4OptionValue -ComputerName localhost `
                                                -DnsDomain $dnsClient.ConnectionSpecificSuffix `
                                                -DnsServer 8.8.8.8 `
                                                -Router 192.168.0.1 -ErrorAction Stop
                                        Restart-Service dhcpserver
                                }
                        }
                }

                # 3. Configure NAT Network
                Script ConfigureNAT {
                        GetScript  = { @{ Result = (Get-NetNat -Name 'NestedVMNATnetwork' -ErrorAction SilentlyContinue) } }
                        TestScript = { (Get-NetNat -Name 'NestedVMNATnetwork' -ErrorAction SilentlyContinue) -ne $null }
                        SetScript  = {
                                Write-Verbose "Configuring NAT network 'NestedVMNATnetwork'..."
                                if (-not (Get-NetNat -Name 'NestedVMNATnetwork' -ErrorAction SilentlyContinue)) {
                                        New-NetNat -Name 'NestedVMNATnetwork' -InternalIPInterfaceAddressPrefix '192.168.0.0/24' -ErrorAction Stop
                                }
                        }
                }

                # 4. Configure Internal Switch
                Script ConfigureSwitch {
                        GetScript  = { @{ Result = (Get-VMSwitch -Name 'NAT Switch' -ErrorAction SilentlyContinue) } }
                        TestScript = { (Get-VMSwitch -Name 'NAT Switch' -ErrorAction SilentlyContinue) -ne $null }
                        SetScript  = {
                                Write-Verbose "Configuring internal VMSwitch 'NAT Switch'..."
                                if (-not (Get-VMSwitch -Name 'NAT Switch' -ErrorAction SilentlyContinue)) {
                                        New-VMSwitch -Name 'NAT Switch' -SwitchType Internal -ErrorAction Stop
                                }
                        }
                }

                # 5. Assign Gateway IP
                Script AssignGatewayIP {
                        GetScript  = { @{ Result = (Get-NetIPAddress -IPAddress 192.168.0.1 -ErrorAction SilentlyContinue) } }
                        TestScript = { (Get-NetIPAddress -IPAddress 192.168.0.1 -ErrorAction SilentlyContinue) -ne $null }
                        SetScript  = {
                                Write-Verbose "Assigning gateway IP 192.168.0.1 to NAT Switch..."
                                $NatSwitch = Get-NetAdapter -Name "vEthernet (NAT Switch)" -ErrorAction Stop
                                New-NetIPAddress -IPAddress 192.168.0.1 -PrefixLength 24 -InterfaceIndex $NatSwitch.ifIndex -ErrorAction Stop
                        }
                }

                # 6. Enable Enhanced Session Mode
                Script EnableEnhancedSessionMode {
                        GetScript  = { @{ Result = (Get-VMHost).EnableEnhancedSessionMode } }
                        TestScript = { (Get-VMHost).EnableEnhancedSessionMode }
                        SetScript  = {
                                Write-Verbose "Enabling Enhanced Session Mode on VMHost..."
                                Set-VMHost -EnableEnhancedSessionMode $true -ErrorAction Stop
                        }
                }

                # 7. Create OnPrem Windows Server VM
                Script CreateOnPremVm {
                        GetScript  = { @{ Result = (Get-VM -Name "OnPremVM" -ErrorAction SilentlyContinue) } }
                        TestScript = { (Get-VM -Name "OnPremVM" -ErrorAction SilentlyContinue) -ne $null }
                        SetScript  = {
                                Write-Verbose "Creating OnPrem Windows Server VM..."
                                $vmFolder = "C:\VM"
                                if (-not (Test-Path $vmFolder)) { New-Item -ItemType Directory -Path $vmFolder -Force }

                                $vmImageArchiveName = Split-Path $using:WindowsVmImageUrl -Leaf
                                $vmImageArchivePath = "$vmFolder\$vmImageArchiveName"

                                Write-Verbose "Downloading VM image from $using:WindowsVmImageUrl..."
                                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                                if (-not (Test-Path "$vmImageArchivePath")) {
                                        try {
                                                Invoke-WebRequest -Uri $using:WindowsVmImageUrl -OutFile $vmImageArchivePath -ErrorAction Stop
                                                Write-Verbose "VM image archive downloaded to $vmImageArchivePath"
                                        } catch {
                                                Write-Error "Failed to download VM image archive from $using:WindowsVmImageUrl"
                                                exit 1
                                        }
                                } else {
                                        Write-Verbose "Image archive already exists at $vmImageArchivePath"
                                }

                                Write-Verbose "Extracting VM image from $vmImageArchivePath to $vmFolder..."
                                Add-Type -AssemblyName "System.IO.Compression.FileSystem"
                                if (-not (Test-Path "$vmFolder\WinServer")) {
                                        [IO.Compression.ZipFile]::ExtractToDirectory($vmImageArchivePath, $vmFolder)
                                }

                                Write-Verbose "Creating Windows VM..."
                                New-VM -Name OnPremVM -MemoryStartupBytes 2GB -BootDevice VHD `
                                        -VHDPath "$vmFolder\WinServer\Virtual Hard Disks\WinServer.vhdx" `
                                        -Path "$vmFolder\WinServer\Virtual Hard Disks" -Generation 1 -Switch "NAT Switch"

                                Start-VM -Name OnPremVM
                        }
                }

                # 9. Create SQL Server VM
                Script CreateSqlVm {
                        GetScript  = { @{ Result = (Get-VM -Name "OnPremSQLVM" -ErrorAction SilentlyContinue) } }
                        TestScript = { (Get-VM -Name "OnPremSQLVM" -ErrorAction SilentlyContinue) -ne $null }
                        SetScript  = {
                                Write-Verbose "Creating SQL Server VM..."
                                $sqlVMName = "OnPremSQLVM"
                                $sqlVmVhdPath = "C:\VM\SQLServer"
                                if (-not (Test-Path $sqlVmVhdPath)) { New-Item -ItemType Directory -Path $sqlVmVhdPath -Force }
                                $sqlImage = Split-Path $using:SqlVmImageUrl -Leaf                                
                                $sqlVmImagePath = "$sqlVmVhdPath\$sqlImage"

                                Write-Verbose "Downloading SQL VM image from $using:SqlVmImageUrl"
                                if (-not (Test-Path $sqlVmImagePath)) {
                                        Invoke-WebRequest -Uri $using:SqlVmImageUrl -OutFile $sqlVmImagePath -ErrorAction Stop
                                        Write-Verbose "SQL VM image downloaded to $sqlVmImagePath"
                                }
                                New-VM -Name $sqlVMName -MemoryStartupBytes 2GB -BootDevice VHD `
                                        -VHDPath $sqlVmImagePath -Path $sqlVmVhdPath -Generation 2 -Switch "NAT Switch"
                                Start-VM -Name $sqlVMName
                        }
                }

                # 10. Configure SQL VM
		Script ConfigureSqlVm {
                        GetScript  = { @{ Result = "SQLVMConfigured" } }
                        TestScript = { return $false }
                        SetScript  = {
                                Write-Verbose "Configuring SQL VM..."
                                $vmUsername = "Administrator"
                                $vmPassword = "JS123!!"
                                $secPass = ConvertTo-SecureString $vmPassword -AsPlainText -Force
                                $winCreds = New-Object System.Management.Automation.PSCredential ($vmUsername, $secPass)

                                $scriptPath = "C:\scripts"
                                if (-not (Test-Path $scriptPath)) { New-Item -ItemType Directory -Path $scriptPath -Force }

                                $sqlVMName = "OnPremSQLVM"
                                $sqlConfigFileName = Split-Path $using:SqlConfigFileUrl -Leaf
                                $sqlConfigFilePath = "$scriptPath\$sqlConfigFileName"

                                # Wait for SQL VM to reach Running state
                                Start-Sleep -Seconds 180

                                # Download the config file
                                Write-Verbose "Downloading SQL config file from $using:SqlConfigFileUrl"
                                if (-not (Test-Path $sqlConfigFilePath)) {
                                        Invoke-WebRequest -Uri $using:SqlConfigFileUrl -OutFile $sqlConfigFilePath -ErrorAction Stop
                                        Write-Verbose "SQL config file downloaded to $sqlConfigFilePath"
                                }

                                Write-Verbose "Executing SQL config script on SQL Server VM..."
                                $session = New-PSSession -VMName $sqlVMName -Credential $winCreds -ErrorAction Stop

                                Invoke-Command -Session $session -ScriptBlock {
                                        New-Item -ItemType Directory -Path $using:scriptPath -Force | Out-Null
                                }
                                # Copy the SQL config script to the SQL VM
                                Copy-Item -Path $sqlConfigFilePath -Destination "$sqlConfigFilePath" -ToSession $session

                                $dbExists = Invoke-Command -Session $session -ScriptBlock {
                                        try {
                                                $sql = "SELECT name FROM sys.databases WHERE name = 'WideWorldImporters'"
                                                $result = Invoke-Sqlcmd -Query $sql -ServerInstance "localhost" -ErrorAction SilentlyContinue
                                                $result -ne $null
                                        } catch { $false }
                                }

                                if (-not $dbExists) {
                                        Write-Verbose "Database not found, running SQL config script..."
                                        Invoke-Command -Session $session -ScriptBlock {
                                                powershell -ExecutionPolicy Bypass -File "$using:sqlConfigFilePath" `
                                                        -DbBackupFileUrl $using:DbBackupFileUrl
                                        }
                                } else {
                                        Write-Verbose "Database already exists, skipping install."
                                }
                                
                                Remove-PSSession $session

                                Write-Verbose "Successfully executed SQL config script on SQL Server VM."
                        }
                }
  	}
}
