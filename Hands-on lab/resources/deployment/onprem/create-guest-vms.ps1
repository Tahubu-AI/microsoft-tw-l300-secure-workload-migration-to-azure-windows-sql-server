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

param (
        [string]$repoOwner,
        [string]$repoName
)

Write-Host "Provisioning guest VMs from repo $repoOwner/$repoName..."

# Ensure DHCP role is installed
if (-not (Get-WindowsFeature -Name DHCP).Installed) {
        Write-Host "Installing DHCP role..."
        Install-WindowsFeature -Name DHCP -IncludeManagementTools
}

# Configure DHCP scope if missing
Write-Host "Configuring DHCP scope and options..."
if (-not (Get-DhcpServerv4Scope | Where-Object { $_.Name -eq "TechWorkshop" })) {
        Add-DhcpServerv4Scope -Name "TechWorkshop" `
                -StartRange 192.168.0.100 `
                -EndRange 192.168.0.200 `
                -SubnetMask 255.255.255.0 `
                -LeaseDuration 1.00:00:00 `
                -State Active
}

# Configure DHCP options if minimal
if ((Get-DhcpServerv4OptionValue).Count -lt 3) {
        $dnsClient = Get-DnsClient | Where-Object { $_.InterfaceAlias -eq "Ethernet" }
        Set-DhcpServerv4OptionValue -ComputerName localhost `
                -DnsDomain $dnsClient.ConnectionSpecificSuffix `
                -DnsServer 8.8.8.8 `
                -Router 192.168.0.1
        Restart-Service dhcpserver
}

# Create the NAT network, if missing
Write-Host "Creating NAT network and internal switch..."
if (-not (Get-NetNat -Name 'NestedVMNATnetwork' -ErrorAction SilentlyContinue)) {
        New-NetNat -Name NestedVMNATnetwork -InternalIPInterfaceAddressPrefix 192.168.0.0/24
}

# Create the Internal Switch with NAT, if missing
if (-not (Get-VMSwitch -Name 'NAT Switch' -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name 'NAT Switch' -SwitchType Internal
}

# Assign gateway IP
$NatSwitch = Get-NetAdapter -Name "vEthernet (NAT Switch)"
New-NetIPAddress -IPAddress 192.168.0.1 -PrefixLength 24 -InterfaceIndex $NatSwitch.ifIndex

# Enable Enhanced Session Mode
Set-VMHost -EnableEnhancedSessionMode $true

# Clone repo for VM artifacts
Write-Host "Cloning $repoOwner/$repoName GitHub repository..."
$cloneDir = "C:\git"
if (-not (Test-Path $cloneDir)) { mkdir $cloneDir }
Set-Location $cloneDir

if (-not (Test-Path "$cloneDir\$repoName")) {
        git lfs install --skip-smudge
        git clone --quiet --single-branch "https://github.com/$repoOwner/$repoName.git"
}
Set-Location "$cloneDir\$repoName"
git pull
git lfs pull
git lfs install --force

# Extract OnPrem Windows Server VM
$downloadedFile = "$cloneDir\$repoName\Hands-on lab\resources\deployment\onprem\OnPremWinServerVM.zip"
$vmFolder = "C:\VM"
if (-not (Test-Path $vmFolder)) { mkdir $vmFolder }

Add-Type -assembly "system.io.compression.filesystem"
[io.compression.zipfile]::ExtractToDirectory($downloadedFile, $vmFolder)

# Create the Windows Server Guest VM
if (-not (Get-VM -Name "OnPremVM" -ErrorAction SilentlyContinue)) {
        Write-Host "Creating Windows Server Guest VM"
        New-VM -Name OnPremVM `
                -MemoryStartupBytes 2GB `
                -BootDevice VHD `
                -VHDPath "$vmFolder\WinServer\Virtual Hard Disks\WinServer.vhdx" `
                -Path "$vmFolder\WinServer\Virtual Hard Disks" `
                -Generation 1 `
                -Switch "NAT Switch"
}
Start-VM -Name OnPremVM

# Create the SQL Server VM
$nestedWindowsUsername = "Administrator"
$nestedWindowsPassword = "JS123!!"
$secWindowsPassword = ConvertTo-SecureString $nestedWindowsPassword -AsPlainText -Force
$winCreds = New-Object System.Management.Automation.PSCredential ($nestedWindowsUsername, $secWindowsPassword)

$sqlVMName = "OnPremSQLVM"
$sqlVmVhdPath = "C:\VM\SQLServer"
if (-not (Test-Path $sqlVmVhdPath)) { mkdir $sqlVmVhdPath }

$vhdImageToDownload = "JSSQLStd19Base.vhdx"
$sourceUrl = "https://jumpstartprodsg.blob.core.windows.net/scenarios/prod/$vhdImageToDownload"
$destinationPath = "$sqlVmVhdPath\$vhdImageToDownload"

# Download the SQL Server VHD image
if (-not (Test-Path $destinationPath)) {
        try {
                Write-Host "Download SQL Server VHD image..."
                Invoke-WebRequest -Uri $sourceUrl -OutFile $destinationPath -ErrorAction Stop
        } catch {
                Write-Error "Failed to download SQL Server VHD image from $sourceUrl"
                exit 1
        }
}

# Create the SQL Server Guest VM
if (-not (Get-VM -Name $sqlVMName -ErrorAction SilentlyContinue)) {
        Write-Host "Creating SQL Server Guest VM"
        New-VM -Name $sqlVMName `
                -MemoryStartupBytes 2GB `
                -BootDevice VHD `
                -VHDPath $destinationPath `
                -Path $sqlVmVhdPath `
                -Generation 2 `
                -Switch "NAT Switch"
}

$timeout = 600
Start-VM -Name $sqlVMName
Wait-VM -Name $sqlVMName -For Running -Timeout $timeout

if ((Get-VM -Name $sqlVMName).State -ne 'Running') {
        Write-Error "VM $sqlVMName did not reach 'Running' state within $timeout seconds."
        exit 1
}

# Copy and run SQL config script
$sqlConfigFileName = "sql-vm-config.ps1"
$sqlConfigFile = "$cloneDir\$repoName\Hands-on lab\resources\deployment\onprem\$sqlConfigFileName"

# Create a PowerShell Direct session into the SQL VM
$session = New-PSSession -VMName $sqlVMName -Credential $winCreds

# Ensure destination folder exists inside the VM
Invoke-Command -Session $session -ScriptBlock {
        New-Item -ItemType Directory -Path "C:\scripts" -Force | Out-Null
}

# Copy the config script from host into the guest VM
Copy-Item -Path $sqlConfigFile -Destination "C:\scripts\sql-vm-config.ps1" -ToSession $session

# Run the config script inside the SQL VM
Write-Host "Running $sqlConfigFileName script on $sqlVMName..."
Invoke-Command -Session $session -ScriptBlock {
        powershell -ExecutionPolicy Bypass -File "C:\scripts\sql-vm-config.ps1" `
                -repoOwner $using:repoOwner `
                -repoName $using:repoName
}

# Clean up session
Remove-PSSession $session

Unregister-ScheduledTask -TaskName "CreateGuestVMs" -Confirm:$false

Write-Host "=== Giest VM configuration complete ==="
