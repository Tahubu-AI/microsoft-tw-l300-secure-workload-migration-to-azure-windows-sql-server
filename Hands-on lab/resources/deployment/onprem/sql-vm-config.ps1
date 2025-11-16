<# 
 What does this script do?
	- Creates Backup, Data and Logs directories
	- Sets SQL Configs: Directories made as defaults, Enables TCP, Eables Mixed Authentication SA Account
	- Downloads the WideWorldImporters Database as a Backup Device, then Restores the Database
	- Adds the Domain Built-In Administrators to the SYSADMIN group
	- Changes to Recovery type of the DB to "Full Recovery" and then performs a Backup to meet the requirements of AOG
	- Opens three Firewall ports in support of the AOG:  1433 (default SQL), 5022 (HADR Listener), 59999 (Internal Loadbalacer Probe)
#>

param(
    [string] $repoOwner,
    [string] $repoName
)

Write-Host "Configuring SQL VM from repo $repoOwner/$repoName"

# Ensure directories exist
$logs = "C:\Logs"
$data = "C:\Data"
$backups = "C:\Backup"

foreach ($dir in @($logs,$data,$backups)) {
    if (-not (Test-Path $dir)) {
        Write-Host "Creating directory $dir"
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    } else {
        Write-Host "Directory $dir already exists"
    }
}

# Load SQL modules
Write-Host "Loading SQLPS module and SMO assemblies..."
Import-Module "sqlps" -DisableNameChecking
[System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.Smo")

# Configure SQL defaults and Mixed Auth
Write-Host "Configuring SQL defaults and enabling Mixed Authentication..."
$sqlesq = new-object ('Microsoft.SqlServer.Management.Smo.Server') Localhost
$sqlesq.Settings.LoginMode = [Microsoft.SqlServer.Management.Smo.ServerLoginMode]::Mixed
$sqlesq.Settings.DefaultFile = $data
$sqlesq.Settings.DefaultLog = $logs
$sqlesq.Settings.BackupDirectory = $backups
$sqlesq.Alter() 

# Enable TCP protocol
Write-Host "Enabling TCP protocol for SQL Server..."
$smo = 'Microsoft.SqlServer.Management.Smo.'
$wmi = new-object ($smo + 'Wmi.ManagedComputer').
$uri = "ManagedComputer[@Name='" + (get-item env:\computername).Value + "']/ServerInstance[@Name='MSSQLSERVER']/ServerProtocol[@Name='Tcp']"
$Tcp = $wmi.GetSmoObject($uri)
if (-not $Tcp.IsEnabled) {
    $Tcp.IsEnabled = $true
    $Tcp.Alter()
    Write-Host "TCP protocol enabled"
} else {
    Write-Host "TCP protocol already enabled"
}

# Restart the SQL Server service
Write-Host "Restarting SQL Server service..."
Restart-Service -Name "MSSQLSERVER" -Force

# Enable sa account and set password
Write-Host "Enabling SA account and setting password..."
Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -Query "ALTER LOGIN sa ENABLE"
Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -Query "ALTER LOGIN sa WITH PASSWORD = 'demo!pass123'"

# Download database backup 
$dbSource = "https://github.com/$repoOwner/$repoName/raw/main/Hands-on%20lab/resources/deployment/onprem/database.bak"
$dbDestination = "C:\database.bak"

Write-Host "Downloading WideWorldImporters backup from $dbSource..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Test-Path $dbDestination)) {
    try {
        Invoke-WebRequest -Uri $dbSource -OutFile $dbDestination -ErrorAction Stop
        Write-Host "Database backup downloaded to $dbDestination"
    } catch {
        Write-Error "Failed to download WideWorldImporters backup from $dbSource"
        exit 1
    }
} else {
    Write-Host "Database backup already exists at $dbDestination"
}

# Query the backup for logical file names
Write-Host "Querying backup file for logical names..."
$files = Invoke-Sqlcmd -ServerInstance Localhost -Database master -Query "
	RESTORE FILELISTONLY FROM DISK = '$dbDestination'
"

# Build relocate objects dynamically
Write-Host "Building relocation file mappings..."
$relocateFiles = @()
foreach ($file in $files) {
	if ($file.Type -eq 'D') {
		$relocateFiles += New-Object Microsoft.SqlServer.Management.Smo.RelocateFile(
			$file.LogicalName, "C:\Data\WideWorldImporters.mdf"
		)
	}
	elseif ($file.Type -eq 'L') {
		$relocateFiles += New-Object Microsoft.SqlServer.Management.Smo.RelocateFile(
			$file.LogicalName, "C:\Logs\WideWorldImporters.ldf"
		)
	}
}

# Restore database if not already present
Write-Host "Checking if WideWorldImporters database exists..."
$dbExists = Invoke-Sqlcmd -ServerInstance Localhost -Database master -Query "
    SELECT name FROM sys.databases WHERE name = 'WideWorldImporters'
"
if (-not $dbExists) {
    Write-Host "Restoring WideWorldImporters database..."
    Restore-SqlDatabase -ServerInstance Localhost `
        -Database WideWorldImporters `
        -BackupFile $dbDestination `
        -RelocateFile $relocateFiles `
        -ReplaceDatabase -Verbose
} else {
    Write-Host "WideWorldImporters database already exists"
}

# Add BUILTIN\Administrators as sysadmin
Write-Host "Adding BUILTIN\Administrators to sysadmin role..."
$loginExists = Invoke-Sqlcmd -ServerInstance Localhost -Database master -Query "
    SELECT name FROM sys.server_principals WHERE name = 'BUILTIN\Administrators'
"
if (-not $loginExists) {
    Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -Query "CREATE LOGIN [BUILTIN\Administrators] FROM WINDOWS"
}
Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -Query "ALTER SERVER ROLE sysadmin ADD MEMBER [BUILTIN\Administrators]"

# Set recovery model to FULL and run backup
Write-Host "Setting WideWorldImporters recovery model to FULL and running backup..."
Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -Query "ALTER DATABASE WideWorldImporters SET RECOVERY FULL"
Backup-SqlDatabase -ServerInstance Localhost -Database WideWorldImporters

# Firewall rules
Write-Host "Configuring firewall rules for SQL and AOG..."
$fwRules = Get-NetFirewallRule | Select-Object -ExpandProperty DisplayName
if (-not ($fwRules -contains "SQL Server")) {
    New-NetFirewallRule -DisplayName "SQL Server" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow
    Write-Host "Firewall rule added: SQL Server (1433)"
}
if (-not ($fwRules -contains "SQL AG Endpoint")) {
    New-NetFirewallRule -DisplayName "SQL AG Endpoint" -Direction Inbound -Protocol TCP -LocalPort 5022 -Action Allow
    Write-Host "Firewall rule added: SQL AG Endpoint (5022)"
}
if (-not ($fwRules -contains "SQL AG Load Balancer Probe Port")) {
    New-NetFirewallRule -DisplayName "SQL AG Load Balancer Probe Port" -Direction Inbound -Protocol TCP -LocalPort 59999 -Action Allow
    Write-Host "Firewall rule added: SQL AG Load Balancer Probe Port (59999)"
}

Write-Host "=== SQL VM configuration complete ==="
