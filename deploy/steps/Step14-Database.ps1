# ----------------------
# Step 14: Restore databases and create SQL login(s)
# Driven by the Database section of config.json (passed as JSON).
#   - Restores each .bak (relocating data/log files to DataFolder)
#   - Optionally creates a SQL login and makes it db_owner of given DBs
#   - Optionally runs a custom T-SQL script (inline or a .sql file path)
# Uses .NET SqlClient (no extra modules needed). Idempotent.
# Exit: 0 = ok, 1 = error
# ----------------------
param(
    [Parameter(Mandatory)] [string]$ConfigJson
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 14: Restore databases & create SQL users" "STEP"

try { $db = $ConfigJson | ConvertFrom-Json }
catch { Write-Log "Could not parse Database config JSON: $($_.Exception.Message)" "ERROR"; exit 1 }

$server       = if ($db.Server) { $db.Server } else { ".\SQLEXPRESS" }
$instanceName = if ($db.InstanceName) { $db.InstanceName } else { "SQLEXPRESS" }
$backupFolder = $db.BackupFolder
$dataFolder   = if ($db.DataFolder) { $db.DataFolder } else { "D:\SQL_DATA" }

# ============================================================
# SQL helpers (System.Data.SqlClient - always available)
# ============================================================
$script:ConnString = "Server=$server;Database=master;Integrated Security=True;TrustServerCertificate=True;Connect Timeout=30"

function Invoke-SqlNonQuery {
    param([string]$Query, [int]$Timeout = 0)
    $conn = New-Object System.Data.SqlClient.SqlConnection $script:ConnString
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = $Timeout
        [void]$cmd.ExecuteNonQuery()
    }
    finally { $conn.Close() }
}

function Invoke-SqlQuery {
    param([string]$Query)
    $conn = New-Object System.Data.SqlClient.SqlConnection $script:ConnString
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $dt = New-Object System.Data.DataTable
        [void]$da.Fill($dt)
        return $dt
    }
    finally { $conn.Close() }
}

# Enable Mixed-Mode (SQL) authentication if the instance is Windows-only.
# Writes the registry value only - the restart that makes it take effect is done
# once, by Restart-SqlInstance below, so we never bounce the service twice.
function Enable-MixedMode {
    $mode = Invoke-SqlQuery "SELECT CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int) AS OnlyWin"
    if ([int]$mode.Rows[0].OnlyWin -eq 1) {
        Write-Log "Enabling Mixed-Mode authentication (required for SQL logins)..." "INFO"
        Invoke-SqlNonQuery "EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'LoginMode', REG_DWORD, 2"
        Write-Log "Mixed-Mode set; takes effect on the restart below." "OK"
    }
    else {
        Write-Log "Mixed-Mode authentication already enabled." "OK"
    }
}

# Restart the instance and wait until it actually accepts connections again.
# A bare Restart-Service returns as soon as the service reports Running, which is
# before SQL finishes recovering the databases - the next query would fail.
function Restart-SqlInstance {
    param([string]$InstanceName, [int]$TimeoutSeconds = 180)
    $svcName = if ($InstanceName -ieq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$InstanceName" }

    Write-Log "Restarting SQL Server service '$svcName'..." "INFO"
    Restart-Service -Name $svcName -Force -ErrorAction Stop

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $null = Invoke-SqlQuery "SELECT 1"
            Write-Log "SQL Server is back up and accepting connections." "OK"
            return $true
        }
        catch { Start-Sleep -Seconds 5 }
    }
    Write-Log "SQL Server did not accept connections within $TimeoutSeconds seconds after the restart." "ERROR"
    return $false
}

# Verify SQL is reachable before doing anything.
try {
    $null = Invoke-SqlQuery "SELECT 1"
    Write-Log "Connected to SQL Server: $server" "OK"
}
catch {
    Write-Log "Cannot connect to SQL Server '$server': $($_.Exception.Message)" "ERROR"
    exit 1
}

if (-not (Test-Path $dataFolder)) {
    New-Item -ItemType Directory -Path $dataFolder -Force -ErrorAction SilentlyContinue | Out-Null
}

$hadError = $false

# ============================================================
# 1) Restore databases
# ============================================================
foreach ($r in @($db.Restores)) {
    if (-not $r.BakFile -or -not $r.DatabaseName) { continue }
    $dbName = $r.DatabaseName
    $bak    = "$($backupFolder.TrimEnd('\','/'))\$($r.BakFile)"

    Write-Log "--- Restore '$dbName' from '$bak' ---" "INFO"

    if (-not (Test-Path $bak)) {
        Write-Log "Backup file not found (skipping): $bak" "WARN"
        $hadError = $true
        continue
    }

    # Skip if the database already exists.
    $exists = Invoke-SqlQuery "SELECT database_id FROM sys.databases WHERE name = N'$dbName'"
    if ($exists.Rows.Count -gt 0) {
        Write-Log "Database '$dbName' already exists. Skipping restore." "OK"
        continue
    }

    try {
        # Read the logical file names inside the backup, then relocate them.
        $fileList = Invoke-SqlQuery "RESTORE FILELISTONLY FROM DISK = N'$bak'"
        $moves = @()
        $dataIdx = 0; $logIdx = 0
        foreach ($row in $fileList.Rows) {
            $logical = $row.LogicalName
            $type    = "$($row.Type)".ToUpper()   # D = data, L = log, F = fulltext
            if ($type -eq 'L') {
                $name = if ($logIdx -eq 0) { "$dbName`_log" } else { "$dbName`_log$logIdx" }
                $target = "$dataFolder\$name.ldf"; $logIdx++
            }
            else {
                $name = if ($dataIdx -eq 0) { "$dbName" } else { "$dbName`_$dataIdx" }
                $target = "$dataFolder\$name.mdf"; $dataIdx++
            }
            $moves += "MOVE N'$logical' TO N'$target'"
        }

        $restoreSql = "RESTORE DATABASE [$dbName] FROM DISK = N'$bak' WITH REPLACE, RECOVERY, $($moves -join ', ')"
        Write-Log "Restoring (this can take a while)..." "INFO"
        Invoke-SqlNonQuery -Query $restoreSql -Timeout 0
        Write-Log "Database '$dbName' restored to $dataFolder." "OK"
    }
    catch {
        Write-Log "Restore of '$dbName' failed: $($_.Exception.Message)" "ERROR"
        $hadError = $true
    }
}

# ============================================================
# 2) Enable Mixed-Mode, then restart SQL once
# ============================================================
# Mixed-Mode must be on before any password-based login can connect, and the
# setting only takes effect after a restart - so do both here, between the
# restores and the login creation.
if ($db.EnableMixedMode -or ($db.SqlLogin -and $db.SqlLogin.Create)) {
    try { Enable-MixedMode }
    catch { Write-Log "Could not enable Mixed-Mode: $($_.Exception.Message)" "ERROR"; $hadError = $true }
}

if (-not (Restart-SqlInstance -InstanceName $instanceName)) {
    Write-Log "Aborting: SQL Server is not reachable after the restart." "ERROR"
    exit 1
}

# ============================================================
# 3) Custom T-SQL (inline text or a .sql file path)
# ============================================================
# Runs BEFORE the ownership grant below, because this is where the login is
# normally created. The script is executed verbatim - nothing is appended to it.
if (-not [string]::IsNullOrWhiteSpace($db.CustomSqlScript)) {
    try {
        $sqlText = if (Test-Path $db.CustomSqlScript) {
            Write-Log "Running custom SQL file: $($db.CustomSqlScript)" "INFO"
            # -Encoding UTF8: without it PS 5.1 reads as ANSI and mangles
            # accented text (DEFAULT_LANGUAGE=[Francais] and friends).
            Get-Content $db.CustomSqlScript -Raw -Encoding UTF8
        }
        else {
            Write-Log "Running inline custom SQL." "INFO"
            $db.CustomSqlScript
        }
        # Split on GO batch separators (sqlcmd style) - SqlClient can't run GO.
        $batches = [System.Text.RegularExpressions.Regex]::Split($sqlText, '(?im)^\s*GO\s*$')
        foreach ($b in $batches) {
            if (-not [string]::IsNullOrWhiteSpace($b)) { Invoke-SqlNonQuery $b }
        }
        Write-Log "Custom SQL executed." "OK"
    }
    catch {
        Write-Log "Custom SQL failed: $($_.Exception.Message)" "ERROR"
        $hadError = $true
    }
}

# ============================================================
# 4) Optionally create the built-in SQL login
# ============================================================
# Only when SqlLogin.Create is true. Leave it false when CustomSqlScript already
# creates the login, so that script stays the single definition of it.
$login = $db.SqlLogin
if ($login -and $login.Create) {
    $loginName = $login.Name
    $loginPwd  = "$($login.Password)"

    if ([string]::IsNullOrWhiteSpace($loginName)) {
        Write-Log "SqlLogin.Create is true but Name is empty; skipping login." "WARN"
    }
    elseif ([string]::IsNullOrWhiteSpace($loginPwd)) {
        Write-Log "SqlLogin.Password is empty; cannot create SQL login '$loginName'. Skipping." "WARN"
    }
    else {
        try {
            $pwdEsc = $loginPwd -replace "'", "''"
            Invoke-SqlNonQuery @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$loginName')
    CREATE LOGIN [$loginName] WITH PASSWORD = N'$pwdEsc', CHECK_POLICY = OFF;
"@
            Write-Log "SQL login '$loginName' ready." "OK"
        }
        catch {
            Write-Log "Creating SQL login '$loginName' failed: $($_.Exception.Message)" "ERROR"
            $hadError = $true
        }
    }
}

# ============================================================
# 5) Make the login db_owner of the listed databases
# ============================================================
# Independent of SqlLogin.Create: the login may have been created by
# CustomSqlScript above, and the ownership grant still has to happen.
if ($login -and -not [string]::IsNullOrWhiteSpace($login.Name)) {
    $owners = @($login.DbOwnerOf | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($owners.Count -gt 0) {
        $loginName = $login.Name
        $exists = Invoke-SqlQuery "SELECT 1 AS Found FROM sys.server_principals WHERE name = N'$($loginName -replace "'","''")'"
        if ($exists.Rows.Count -eq 0) {
            Write-Log "Login '$loginName' does not exist; cannot grant db_owner. Check CustomSqlScript or set SqlLogin.Create." "ERROR"
            $hadError = $true
        }
        else {
            foreach ($dbn in $owners) {
                try {
                    Invoke-SqlNonQuery @"
IF DB_ID(N'$dbn') IS NOT NULL
BEGIN
    USE [$dbn];
    IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$loginName')
        CREATE USER [$loginName] FOR LOGIN [$loginName];
    ALTER ROLE db_owner ADD MEMBER [$loginName];
END
"@
                    Write-Log "'$loginName' set as db_owner of '$dbn'." "OK"
                }
                catch {
                    Write-Log "Granting db_owner on '$dbn' failed: $($_.Exception.Message)" "ERROR"
                    $hadError = $true
                }
            }
        }
    }
}

if ($hadError) {
    Write-Log "Step 14 finished with one or more errors (see above)." "ERROR"
    exit 1
}
Write-Log "Databases restored and SQL users configured." "OK"
exit 0
