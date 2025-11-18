<# 
 What does this script do?
	- Creates Backup, Data and Logs directories
	- Sets SQL Configs: Directories made as defaults, Enables TCP, Eables Mixed Authentication SA Account
	- Downloads the Customer360 Database as a Backup Device, then Restores the Database
	- Adds the Domain Built-In Administrators to the SYSADMIN group
	- Changes to Recovery type of the DB to "Full Recovery" and then performs a Backup to meet the requirements of AOG
	- Opens three Firewall ports in support of the AOG:  1433 (default SQL), 5022 (HADR Listener), 59999 (Internal Loadbalacer Probe)
#>

Configuration Main {
    Param(
        [Parameter(Mandatory)]
        [String]$DbBackupFileUrl
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
            DependsOn = '[Script]SetArcTestEnvVar'
            Name  = 'WindowsAzureGuestAgent'
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

        # Ensure directories exist
        foreach ($dirName in @('Logs','Data','Backup')) {
            File ("${dirName}_Directory") {
                Ensure          = 'Present'
                Type            = 'Directory'
                DestinationPath = "C:\Database\$dirName"
            }
        }

        # Load SQL modules
        Script LoadSqlModules {
            GetScript = {
                # Report whether the module is loaded
                $loaded = Get-Module -Name sqlps -ListAvailable
                @{ Result = if ($loaded) { "sqlps available" } else { "sqlps missing" } }
            }
            TestScript = {
                # Return $true if both module and assembly are available
                $moduleOk = (Get-Module -Name sqlps -ListAvailable) -ne $null
                $assemblyOk = [AppDomain]::CurrentDomain.GetAssemblies().FullName -match "Microsoft.SqlServer.Smo"
                $moduleOk -and $assemblyOk
            }
            SetScript = {
                Write-Verbose "Loading SQLPS module and SMO assemblies..."
                Import-Module "sqlps" -DisableNameChecking -ErrorAction Stop
                [System.Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.Smo") | Out-Null
            }
        }

        # Configure SQL defaults and Mixed Auth
        Script ConfigureSqlDefaults {
            DependsOn = '[Script]LoadSqlModules'
            GetScript = { @{ Result = "SQLDefaults" } }
            TestScript = {
                $sqlesq = New-Object ('Microsoft.SqlServer.Management.Smo.Server') Localhost
                ($sqlesq.Settings.LoginMode -eq [Microsoft.SqlServer.Management.Smo.ServerLoginMode]::Mixed)
            }
            SetScript = {
                Write-Verbose "Configuring SQL defaults and enabling Mixed Authentication..."
                $sqlesq = New-Object ('Microsoft.SqlServer.Management.Smo.Server') Localhost
                $sqlesq.Settings.LoginMode = [Microsoft.SqlServer.Management.Smo.ServerLoginMode]::Mixed
                $sqlesq.Settings.DefaultFile = "C:\Database\Data"
                $sqlesq.Settings.DefaultLog = "C:\Database\Logs"
                $sqlesq.Settings.BackupDirectory = "C:\Database\Backup"
                $sqlesq.Alter()
            }
        }

        # Enable TCP protocol
        Script EnableSqlTcp {
            DependsOn = '[Script]LoadSqlModules'
            GetScript = { @{ Result = "SqlTcp" } }
            TestScript = {
                $smo = 'Microsoft.SqlServer.Management.Smo.'
                $wmi = New-Object ($smo + 'Wmi.ManagedComputer')
                $uri = "ManagedComputer[@Name='" + (Get-Item env:\computername).Value + "']/ServerInstance[@Name='MSSQLSERVER']/ServerProtocol[@Name='Tcp']"
                $Tcp = $wmi.GetSmoObject($uri)
                $Tcp.IsEnabled
            }
            SetScript = {
                Write-Verbose "Enabling TCP protocol for SQL Server..."
                $smo = 'Microsoft.SqlServer.Management.Smo.'
                $wmi = New-Object ($smo + 'Wmi.ManagedComputer')
                $uri = "ManagedComputer[@Name='" + (Get-Item env:\computername).Value + "']/ServerInstance[@Name='MSSQLSERVER']/ServerProtocol[@Name='Tcp']"
                $Tcp = $wmi.GetSmoObject($uri)
                $Tcp.IsEnabled = $true
                $Tcp.Alter()
            }
        }

        # Ensure SQL service is running
        Service SqlService {
            Name        = 'MSSQLSERVER'
            StartupType = 'Automatic'
            State       = 'Running'
        }

        # Restart SQL Server service
        Script RestartSqlAfterConfig {
            DependsOn = '[Script]ConfigureSqlDefaults','[Script]EnableSqlTcp'
            GetScript  = { @{ Result = "RestartNeeded" } }
            TestScript = { $false }  # Always run
            SetScript  = {
                Write-Verbose "Restarting SQL Server service to apply configuration changes..."
                Restart-Service -Name 'MSSQLSERVER' -Force
            }
        }

        # Configure SA account
        Script ConfigureSqlSaAccount {
            DependsOn = '[Service]SqlService','[Script]RestartSqlAfterConfig'
            GetScript = {
                $result = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -Query "SELECT name, is_disabled FROM sys.sql_logins WHERE name = 'sa'"
                @{ Result = $result }
            }
            TestScript = {
                $login = Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -Query "SELECT is_disabled FROM sys.sql_logins WHERE name = 'sa'"
                ($login.is_disabled -eq 0)
            }
            SetScript = {
                Write-Verbose "Enabling SA account and setting password..."
                Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -Query "ALTER LOGIN sa ENABLE"
                Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -Query "ALTER LOGIN sa WITH PASSWORD = 'demo!pass123'"
            }
        }

        # Download database backup
        Script DownloadDbBackup {
            GetScript = {
                $backupFileName = Split-Path $using:DbBackupFileUrl -Leaf
                $dbDestination = "C:\$backupFileName"
                @{ Result = (Test-Path $dbDestination) }
            }
            TestScript = {
                $backupFileName = Split-Path $using:DbBackupFileUrl -Leaf
                $dbDestination = "C:\$backupFileName"
                Test-Path $dbDestination
            }
            SetScript = {
                $backupFileName = Split-Path $using:DbBackupFileUrl -Leaf
                $dbDestination = "C:\$backupFileName"
                Write-Verbose "Downloading database backup from $using:DbBackupFileUrl..."
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $using:DbBackupFileUrl -OutFile $dbDestination -ErrorAction Stop
            }
        }

        # Restore ToyStore database
        Script RestoreToyStore {
            DependsOn = '[Script]DownloadDbBackup'
            GetScript = {
                $dbExists = Invoke-Sqlcmd -ServerInstance Localhost -Database master -Query "
                    SELECT name FROM sys.databases WHERE name = 'ToyStore'"
                @{ Result = $dbExists }
            }
            TestScript = {
                $dbExists = Invoke-Sqlcmd -ServerInstance Localhost -Database master -Query "
                    SELECT name FROM sys.databases WHERE name = 'ToyStore'"
                $dbExists.Count -gt 0
            }
            SetScript = {
                $backupFileName = Split-Path $using:DbBackupFileUrl -Leaf
                $dbDestination = "C:\$backupFileName"
                Write-Verbose "Restoring ToyStore database..."
                $files = Invoke-Sqlcmd -ServerInstance Localhost -Database master -Query "
                    RESTORE FILELISTONLY FROM DISK = '$dbDestination'"
                $relocateFiles = @()
                foreach ($file in $files) {
                    if ($file.Type -eq 'D') {
                        $relocateFiles += New-Object Microsoft.SqlServer.Management.Smo.RelocateFile(
                            $file.LogicalName, "C:\Database\Data\ToyStore.mdf")
                    }
                    elseif ($file.Type -eq 'L') {
                        $relocateFiles += New-Object Microsoft.SqlServer.Management.Smo.RelocateFile(
                            $file.LogicalName, "C:\Database\Logs\ToyStore.ldf")
                    }
                }
                Restore-SqlDatabase -ServerInstance Localhost `
                    -Database ToyStore `
                    -BackupFile $dbDestination `
                    -RelocateFile $relocateFiles `
                    -ReplaceDatabase -Verbose
            }
        }

        # Restore Customer360 database
        Script RestoreCustomer360 {
            DependsOn = '[Script]DownloadDbBackup'
            GetScript = {
                $dbExists = Invoke-Sqlcmd -ServerInstance Localhost -Database master -Query "
                    SELECT name FROM sys.databases WHERE name = 'Customer360'"
                @{ Result = $dbExists }
            }
            TestScript = {
                $dbExists = Invoke-Sqlcmd -ServerInstance Localhost -Database master -Query "
                    SELECT name FROM sys.databases WHERE name = 'Customer360'"
                $dbExists.Count -gt 0
            }
            SetScript = {
                $backupFileName = Split-Path $using:DbBackupFileUrl -Leaf
                $dbDestination = "C:\$backupFileName"
                Write-Verbose "Restoring Customer360 database..."
                $files = Invoke-Sqlcmd -ServerInstance Localhost -Database master -Query "
                    RESTORE FILELISTONLY FROM DISK = '$dbDestination'"
                $relocateFiles = @()
                foreach ($file in $files) {
                    if ($file.Type -eq 'D') {
                        $relocateFiles += New-Object Microsoft.SqlServer.Management.Smo.RelocateFile(
                            $file.LogicalName, "C:\Database\Data\Customer360.mdf")
                    }
                    elseif ($file.Type -eq 'L') {
                        $relocateFiles += New-Object Microsoft.SqlServer.Management.Smo.RelocateFile(
                            $file.LogicalName, "C:\Database\Logs\Customer360.ldf")
                    }
                }
                Restore-SqlDatabase -ServerInstance Localhost `
                    -Database Customer360 `
                    -BackupFile $dbDestination `
                    -RelocateFile $relocateFiles `
                    -ReplaceDatabase -Verbose
            }
        }

        # Add built-in admins to SQL databases
        Script AddBuiltinAdmins {
            DependsOn = '[Script]RestoreCustomer360','[Script]RestoreToyStore'
            GetScript = {
                $loginExists = Invoke-Sqlcmd -ServerInstance Localhost -Database master -Query "
                    SELECT name FROM sys.server_principals WHERE name = 'BUILTIN\Administrators'"
                @{ Result = $loginExists }
            }
            TestScript = {
                $loginExists = Invoke-Sqlcmd -ServerInstance Localhost -Database master -Query "
                    SELECT name FROM sys.server_principals WHERE name = 'BUILTIN\Administrators'"
                $loginExists.Count -gt 0
            }
            SetScript = {
                Write-Verbose "Adding BUILTIN\Administrators to sysadmin role..."
                $loginExists = Invoke-Sqlcmd -ServerInstance Localhost -Database master -Query "
                    SELECT name FROM sys.server_principals WHERE name = 'BUILTIN\Administrators'"
                if (-not $loginExists) {
                    Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -Query "
                        CREATE LOGIN [BUILTIN\Administrators] FROM WINDOWS"
                }
                Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -Query "
                    ALTER SERVER ROLE sysadmin ADD MEMBER [BUILTIN\Administrators]"
            }
        }

        # Set FULL recovery mode on ToyStore database
        Script ConfigureRecoveryModel {
            DependsOn = '[Script]RestoreToyStore'
            GetScript = {
                $model = Invoke-Sqlcmd -ServerInstance Localhost -Database master -Query "
                    SELECT recovery_model_desc FROM sys.databases WHERE name = 'ToyStore'"
                @{ Result = $model }
            }
            TestScript = {
                $model = Invoke-Sqlcmd -ServerInstance Localhost -Database master -Query "
                    SELECT recovery_model_desc FROM sys.databases WHERE name = 'ToyStore'"
                $model.recovery_model_desc -eq 'FULL'
            }
            SetScript = {
                Write-Verbose "Setting ToyStore recovery model to FULL and running backup..."
                Invoke-Sqlcmd -ServerInstance Localhost -Database "master" -Query "
                    ALTER DATABASE ToyStore SET RECOVERY FULL"
                Backup-SqlDatabase -ServerInstance Localhost -Database ToyStore
            }
        }

        # AddFirewallRules
        Script AddFirewallRules {
            GetScript = { @{ Result = "FirewallRulesAdded" } }
            TestScript = { return $false}
            SetScript = {
                # Firewall rules
                Write-Host "Configuring firewall rules for Arc, SQL, and AOG..."
                $fwRules = Get-NetFirewallRule | Select-Object -ExpandProperty DisplayName
                if (-not ($fwRules -contains "Block Azure IMDS")) {
                    New-NetFirewallRule -Name BlockAzureIMDS -DisplayName "Block Azure IMDS" -Enabled True -Profile Any -Direction Outbound -Action Block -RemoteAddress 169.254.169.254
                    Write-Verbose "Firewall rule added: Block Azure IMDS"
                }
                if (-not ($fwRules -contains "SQL Server")) {
                    New-NetFirewallRule -DisplayName "SQL Server" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow
                    Write-Host "Firewall rule added: SQL Server (1433)"
                }
                if (-not ($fwRules -contains "SQL AG Endpoint Inbound")) {
                    New-NetFirewallRule -DisplayName "SQL AG Endpoint Inbound" -Direction Inbound -Profile Any -Action Allow -LocalPort 5022 -Protocol TCP
                    Write-Host "Firewall rule added: SQL AG Endpoint Inbound (5022)"
                }
                if (-not ($fwRules -contains "SQL AG Endpoint Outbound")) {
                    New-NetFirewallRule -DisplayName "SQL AG Endpoint Outbound" -Direction Outbound -Profile Any -Action Allow -LocalPort 5022 -Protocol TCP
                    Write-Host "Firewall rule added: SQL AG Endpoint Outbound (5022)"
                }
                if (-not ($fwRules -contains "SQL AG Load Balancer Probe Port")) {
                    New-NetFirewallRule -DisplayName "SQL AG Load Balancer Probe Port" -Direction Inbound -Protocol TCP -LocalPort 59999 -Action Allow
                    Write-Host "Firewall rule added: SQL AG Load Balancer Probe Port (59999)"
                }
            }
        }
    }
}
