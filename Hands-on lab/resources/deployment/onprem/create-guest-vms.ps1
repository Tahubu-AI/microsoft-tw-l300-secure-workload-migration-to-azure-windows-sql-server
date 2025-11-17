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

# Define LCM settings
[DSCLocalConfigurationManager()]
Configuration LCMConfig {
    Node "localhost" {
        Settings {
            RefreshMode = 'Push'                  # Configs are pushed via extension
            ConfigurationMode = 'ApplyOnly'       # Apply once, don’t monitor continuously
            RebootNodeIfNeeded = $true            # Allow DSC to reboot automatically
            ActionAfterReboot = 'ContinueConfiguration' # Resume after reboot
        }
    }
}

# Compile and apply LCM settings
LCMConfig
Set-DscLocalConfigurationManager -Path .\LCMConfig

Configuration Main {
        param (
                [string]$repoOwner,
                [string]$repoName
        )

        Import-DscResource -ModuleName 'PSDesiredStateConfiguration'

	node "localhost" {
                Script EchoParams {
                        GetScript  = { @{ Result = "ParamsEchoed" } }
                        TestScript = { Test-Path "C:\logs\params.txt" }
                        SetScript  = {
                                $logPath = "C:\logs"
                                if (-not (Test-Path $logPath)) {
                                New-Item -ItemType Directory -Path $logPath -Force | Out-Null
                                }
                                "repoOwner=$repoOwner; repoName=$repoName" | Out-File "$logPath\params.txt"
                        }
                }

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

                # 7. Clone Repo for VM Artifacts
                Script CloneRepo {
                        GetScript  = { @{ Result = (Test-Path "C:\git\$repoName") } }
                        TestScript = { Test-Path "C:\git\$repoName" }
                        SetScript  = {
                                if (-not $repoName) { throw "Parameter repoName is null or empty." }
                                Write-Verbose "Cloning repo $repoOwner/$repoName..."
                                $cloneDir = "C:\git"
                                if (-not (Test-Path $cloneDir)) { New-Item -ItemType Directory -Path $cloneDir -Force }
                                Set-Location $cloneDir
                                if (-not (Test-Path "$cloneDir\$repoName")) {
                                        git lfs install --skip-smudge
                                        git clone --quiet --single-branch "https://github.com/$repoOwner/$repoName.git"
                                }
                                if (Test-Path "$cloneDir\$repoName\.git") {
                                        Push-Location "$cloneDir\$repoName"
                                        git pull
                                        git lfs pull
                                        Pop-Location
                                }
                                else {
                                        throw "Expected repo at $cloneDir\$repoName but .git folder not found."
                                }

                        }
                }

                # 8. Create OnPrem Windows Server VM
                Script CreateOnPremVm {
                        GetScript  = { @{ Result = (Get-VM -Name "OnPremVM" -ErrorAction SilentlyContinue) } }
                        TestScript = { (Get-VM -Name "OnPremVM" -ErrorAction SilentlyContinue) -ne $null }
                        SetScript  = {
                                Write-Verbose "Creating OnPrem Windows Server VM..."
                                $vmFolder = "C:\VM"
                                if (-not (Test-Path $vmFolder)) { New-Item -ItemType Directory -Path $vmFolder -Force }
                                $downloadedFile = "C:\git\$repoName\Hands-on lab\resources\deployment\onprem\OnPremWinServerVM.zip"
                                Add-Type -AssemblyName "System.IO.Compression.FileSystem"
                                if (-not (Test-Path "$vmFolder\WinServer")) {
                                        [IO.Compression.ZipFile]::ExtractToDirectory($downloadedFile, $vmFolder)
                                }
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
                                $vhdImageToDownload = "JSSQLStd19Base.vhdx"
                                $sourceUrl = "https://jumpstartprodsg.blob.core.windows.net/scenarios/prod/$vhdImageToDownload"
                                $destinationPath = "$sqlVmVhdPath\$vhdImageToDownload"
                                if (-not (Test-Path $destinationPath)) {
                                        Invoke-WebRequest -Uri $sourceUrl -OutFile $destinationPath -ErrorAction Stop
                                }
                                New-VM -Name $sqlVMName -MemoryStartupBytes 2GB -BootDevice VHD `
                                        -VHDPath $destinationPath -Path $sqlVmVhdPath -Generation 2 -Switch "NAT Switch"
                                Start-VM -Name $sqlVMName
                                # Optional: Wait for VM to reach Running state
                                Wait-VM -Name $sqlVMName -For Running -Timeout 300
                        }
                }

                # 10. Configure SQL VM
		Script ConfigureSqlVm {
                        GetScript  = { @{ Result = "SQLVMConfigured" } }
                        TestScript = { (Get-VM -Name "OnPremSQLVM" -ErrorAction SilentlyContinue).State -eq 'Running' }
                        SetScript  = {
                                Write-Verbose "Configuring SQL VM..."
                                $nestedWindowsUsername = "Administrator"
                                $nestedWindowsPassword = "JS123!!"
                                $secWindowsPassword = ConvertTo-SecureString $nestedWindowsPassword -AsPlainText -Force
                                $winCreds = New-Object System.Management.Automation.PSCredential ($nestedWindowsUsername, $secWindowsPassword)

                                $sqlVMName = "OnPremSQLVM"
                                $sqlConfigFileName = "sql-vm-config.ps1"
                                $sqlConfigFile = "C:\git\$repoName\Hands-on lab\resources\deployment\onprem\$sqlConfigFileName"
                                $scriptPath = "C:\scripts"

                                $session = New-PSSession -VMName $sqlVMName -Credential $winCreds -ErrorAction Stop
                                Invoke-Command -Session $session -ScriptBlock {
                                        New-Item -ItemType Directory -Path $using:scriptPath -Force | Out-Null
                                }
                                Copy-Item -Path $sqlConfigFile -Destination "$scriptPath\$sqlConfigFileName" -ToSession $session
                                Invoke-Command -Session $session -ScriptBlock {
                                        powershell -ExecutionPolicy Bypass -File "$using:scriptPath\$using:sqlConfigFileName" `
                                                -repoOwner $using:repoOwner -repoName $using:repoName
                                }
                                Remove-PSSession $session
                        }
                }
  	}
}