<#
.File Name
 - install-hyper-v.ps1

.What does this script do?
 - Downloads and installs Git for Windows
 - Enables Internet Connection Sharing
 - Configures TLS 1.2 strong cryptography
 - Installs NuGet package provider
 - Installs DHCP service
 - Installs Hyper-V with all features and management tools, then restarts the machine
#>

Write-Host "=== Starting Hyper-V installation script ==="

# Set PowerShell Execution Policy
Write-Host "Setting PowerShell execution policy to Unrestricted..."
Set-ExecutionPolicy Unrestricted -Force

# ###########################
# Install Git
# ###########################
Write-Host "Downloading latest Git for Windows 64-bit installer..."
$git_url = "https://api.github.com/repos/git-for-windows/git/releases/latest"
$asset = Invoke-RestMethod -Method Get -Uri $git_url | ForEach-Object assets | Where-Object name -like "*64-bit.exe"
$installer = "$env:temp\$($asset.name)"

if (-not (Test-Path $installer)) {
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installer
    Write-Host "Git installer downloaded to $installer"
} else {
    Write-Host "Git installer already exists at $installer"
}

Write-Host "Running Git installer silently..."
$install_args = "/SP- /VERYSILENT /SUPPRESSMSGBOXES /NOCANCEL /NORESTART /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS"
Start-Process -FilePath $installer -ArgumentList $install_args -Wait
Write-Host "Git installation complete."

# ###########################
# Enable Internet Sharing
# ###########################
Write-Host "Enabling Internet Connection Sharing service..."
Set-Service -Name SharedAccess -StartupType Automatic
Start-Service -Name SharedAccess

Write-Host "Registering HNetCfg library..."
regsvr32 /s hnetcfg.dll

Write-Host "Configuring Internet Connection Sharing for Ethernet..."
$m = New-Object -ComObject HNetCfg.HNetShare
$m.EnumEveryConnection | ForEach-Object { $m.NetConnectionProps.Invoke($_) }
$c = $m.EnumEveryConnection | Where-Object { $m.NetConnectionProps.Invoke($_).Name -eq "Ethernet" }
$config = $m.INetSharingConfigurationForINetConnection.Invoke($c)
$config.EnableSharing(0) # public sharing
Write-Host "Internet Connection Sharing enabled on Ethernet."

# ###########################
# Enable TLS 1.2 Strong Cryptography
# ###########################
Write-Host "Configuring .NET Framework for strong TLS 1.2 cryptography..."
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NetFramework\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -Type DWord
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NetFramework\v4.0.30319' -Name 'SchUseStrongCrypto' -Value '1' -Type DWord
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "TLS 1.2 strong cryptography enabled."

# ###########################
# Install NuGet provider
# ###########################
Write-Host "Installing NuGet package provider..."
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Write-Host "NuGet package provider installed."

# ###########################
# Install DHCP service
# ###########################
Write-Host "Installing DHCP service..."
Install-WindowsFeature -Name "DHCP" -IncludeManagementTools
Write-Host "DHCP service installed."

# ###########################
# Install Hyper-V
# ###########################
Write-Host "Installing Hyper-V with all features and management tools..."
Install-WindowsFeature -Name Hyper-V `
    -IncludeAllSubFeature `
    -IncludeManagementTools `
    -Verbose `
    -Restart

Write-Host "=== Hyper-V installation script complete (system will restart) ==="
