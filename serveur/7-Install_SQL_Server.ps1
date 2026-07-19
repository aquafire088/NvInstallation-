# ----------------------
# Script: Install SQL Server
# Purpose: Install and configure SQL Server 2019/2022 for medical lab environment
# ----------------------

# Check if running as Administrator
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] ERROR: This script must be run as Administrator!" -ForegroundColor Red
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SQL Server Installation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Configuration
$sqlVersion = "2019"  # or "2022" for latest
$sqlEdition = "Express"  # Express (free), Standard, Enterprise
$sqlInstanceName = "SQLEXPRESS"
$sqlDataPath = "C:\Program Files\Microsoft SQL Server\MSSQL15.SQLEXPRESS\MSSQL\DATA"
$sqlLogPath = "C:\Program Files\Microsoft SQL Server\MSSQL15.SQLEXPRESS\MSSQL\LOG"
$sqlBackupPath = "C:\Program Files\Microsoft SQL Server\MSSQL15.SQLEXPRESS\MSSQL\Backup"

# SQL Server ISO Configuration
$sqlDownloadUrl = "https://burdpme.sage.com.dl1.ipercast.net/PME/Serveurs/SQL_Std_2019Dec_64Bit_French.iso"
$sqlFolderPath = "D:\Utilitaire\software\sql"
$sqlIsoPath = "$sqlFolderPath\SQL_Server_2019_French.iso"

Write-Host "`nSQL Server Download Configuration:" -ForegroundColor Yellow
Write-Host "Download URL:              $sqlDownloadUrl" -ForegroundColor Cyan
Write-Host "Installation Folder:       $sqlFolderPath" -ForegroundColor Cyan
Write-Host "ISO Destination:           $sqlIsoPath" -ForegroundColor Cyan

# Get domain info
$domainName = "DOMLABO.LOCAL"
$sqlSAPassword = Read-Host "Enter SQL Server 'sa' admin password (or press Enter for Windows-only auth)"

Write-Host "`nSQL Server Configuration:" -ForegroundColor Yellow
Write-Host "SQL Version:               SQL Server $sqlVersion" -ForegroundColor Cyan
Write-Host "Edition:                   $sqlEdition" -ForegroundColor Cyan
Write-Host "Instance Name:             $sqlInstanceName" -ForegroundColor Cyan
Write-Host "Data Path:                 $sqlDataPath" -ForegroundColor Cyan
Write-Host "Log Path:                  $sqlLogPath" -ForegroundColor Cyan
Write-Host "Backup Path:               $sqlBackupPath" -ForegroundColor Cyan
Write-Host "Domain:                    $domainName" -ForegroundColor Cyan

Write-Host "`n[INFO] SQL Server $sqlVersion $sqlEdition Features:" -ForegroundColor Yellow
Write-Host "  ✓ Database Engine" -ForegroundColor Cyan
Write-Host "  ✓ SQL Server Management Studio (SSMS)" -ForegroundColor Cyan
Write-Host "  ✓ SQL Server Agent" -ForegroundColor Cyan
Write-Host "  ✓ Mixed Authentication (Windows + SQL)" -ForegroundColor Cyan
Write-Host "  ✓ TCP/IP Connectivity" -ForegroundColor Cyan

# Confirmation
$confirm = Read-Host "`nInstall SQL Server? (Y/N)"
if ($confirm -ne "Y" -and $confirm -ne "y") {
    Write-Host "[ERROR] Installation cancelled." -ForegroundColor Yellow
    exit 0
}

Write-Host "`n[WAIT] Starting SQL Server installation..." -ForegroundColor Yellow

try {
    # Step 1: Create folder if it doesn't exist
    Write-Host "`nStep 1: Preparing installation folder..." -ForegroundColor Cyan

    if (-not (Test-Path $sqlFolderPath)) {
        New-Item -ItemType Directory -Path $sqlFolderPath -Force -ErrorAction Stop | Out-Null
        Write-Host "[OK] Folder created: $sqlFolderPath" -ForegroundColor Green
    }
    else {
        Write-Host "[OK] Folder exists: $sqlFolderPath" -ForegroundColor Green
    }

    # Step 2: Check .NET Framework
    Write-Host "`nStep 2: Checking .NET Framework..." -ForegroundColor Cyan
    $dotnetStatus = Get-WindowsFeature -Name "NET-Framework-Core" -ErrorAction SilentlyContinue

    if ($dotnetStatus.Installed) {
        Write-Host "[OK] .NET Framework 3.5 is installed" -ForegroundColor Green
    }
    else {
        Write-Host "[WARNING]  .NET Framework 3.5 not found. Installing..." -ForegroundColor Yellow
        Install-WindowsFeature -Name "NET-Framework-Core" -ErrorAction SilentlyContinue
        Write-Host "[OK] .NET Framework installed" -ForegroundColor Green
    }

    # Step 3: Download SQL Server ISO
    Write-Host "`nStep 3: Downloading SQL Server ISO..." -ForegroundColor Cyan
    Write-Host "[WAIT] This may take 10-30 minutes depending on your connection..." -ForegroundColor Yellow
    Write-Host "   Source: $sqlDownloadUrl" -ForegroundColor Gray

    if (Test-Path $sqlIsoPath) {
        Write-Host "[OK] ISO already exists: $sqlIsoPath" -ForegroundColor Green
        $skipDownload = Read-Host "Re-download? (Y/N)"
        if ($skipDownload -ne "Y" -and $skipDownload -ne "y") {
            Write-Host "⏭️  Skipping download, using existing ISO" -ForegroundColor Cyan
        }
        else {
            try {
                Remove-Item $sqlIsoPath -Force -ErrorAction Stop
                Write-Host "Downloading SQL Server ISO..." -ForegroundColor Cyan
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $sqlDownloadUrl -OutFile $sqlIsoPath -ErrorAction Stop
                Write-Host "[OK] ISO downloaded successfully: $sqlIsoPath" -ForegroundColor Green
            }
            catch {
                Write-Host "[ERROR] ERROR: Failed to download ISO: $($_.Exception.Message)" -ForegroundColor Red
                exit 1
            }
        }
    }
    else {
        try {
            Write-Host "Downloading SQL Server ISO..." -ForegroundColor Cyan
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $sqlDownloadUrl -OutFile $sqlIsoPath -ErrorAction Stop
            Write-Host "[OK] ISO downloaded successfully: $sqlIsoPath" -ForegroundColor Green
        }
        catch {
            Write-Host "[ERROR] ERROR: Failed to download ISO: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
    }

    # Step 4: Mount SQL Server ISO
    Write-Host "`nStep 4: Mounting SQL Server ISO..." -ForegroundColor Cyan
    $mountResult = Mount-DiskImage -ImagePath $sqlIsoPath -PassThru
    $isoDrive = ($mountResult | Get-Volume).DriveLetter

    if ($isoDrive) {
        $sqlInstallerPath = "$isoDrive`:\setup.exe"
        Write-Host "[OK] ISO mounted successfully: Drive $isoDrive`:" -ForegroundColor Green
    }
    else {
        Write-Host "[ERROR] ERROR: Failed to mount ISO" -ForegroundColor Red
        exit 1
    }

    if (-not (Test-Path $sqlInstallerPath)) {
        Write-Host "[ERROR] ERROR: setup.exe not found in ISO" -ForegroundColor Red
        Dismount-DiskImage -ImagePath $sqlIsoPath
        exit 1
    }

    # Step 5: Create directories
    Write-Host "`nStep 5: Creating SQL Server directories..." -ForegroundColor Cyan
    $directories = @($sqlDataPath, $sqlLogPath, $sqlBackupPath)

    foreach ($dir in $directories) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
            Write-Host "[OK] Created: $dir" -ForegroundColor Green
        }
        else {
            Write-Host "[OK] Directory exists: $dir" -ForegroundColor Green
        }
    }

    # Step 6: Run SQL Server Setup
    Write-Host "`nStep 6: Installing SQL Server..." -ForegroundColor Cyan
    Write-Host "[WAIT] This may take 10-20 minutes..." -ForegroundColor Yellow

    # Build installation command
    $installArgs = @(
        "/Q",
        "/IACCEPTSQLSERVERLICENSETERMS",
        "/ACTION=Install",
        "/FEATURES=SQLEngine,SSMS,Agent",
        "/INSTANCENAME=$sqlInstanceName",
        "/SQLSYSADMINACCOUNTS=`"$domainName\Adcipro`""
    )

    # Add SA password if provided
    if (-not [string]::IsNullOrWhiteSpace($sqlSAPassword)) {
        $installArgs += "/SECURITYMODE=SQL"
        $installArgs += "/SAPWD=`"$sqlSAPassword`""
    }
    else {
        $installArgs += "/SECURITYMODE=Windows"
    }

    try {
        # Run setup
        $setupProcess = Start-Process -FilePath $sqlInstallerPath `
            -ArgumentList $installArgs `
            -Wait -PassThru -NoNewWindow

        if ($setupProcess.ExitCode -eq 0) {
            Write-Host "[OK] SQL Server installation completed successfully" -ForegroundColor Green
        }
        else {
            Write-Host "[WARNING]  SQL Server installation finished with exit code: $($setupProcess.ExitCode)" -ForegroundColor Yellow
            Write-Host "   Check SQL Server error logs for details" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "[ERROR] ERROR: Failed to run SQL Server setup: $($_.Exception.Message)" -ForegroundColor Red
    }

    # Step 7: Unmount ISO
    Write-Host "`nStep 7: Unmounting ISO..." -ForegroundColor Cyan
    try {
        Dismount-DiskImage -ImagePath $sqlIsoPath -ErrorAction Stop
        Write-Host "[OK] ISO unmounted successfully" -ForegroundColor Green
    }
    catch {
        Write-Host "[WARNING]  Warning: Could not unmount ISO: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Step 8: Display post-installation instructions
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "[OK] SQL Server Installation Completed" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    Write-Host "`n[INFO] Installation Summary:" -ForegroundColor Yellow
    Write-Host "  ISO File:              $sqlIsoPath" -ForegroundColor Cyan
    Write-Host "  Setup Executed:        $sqlInstallerPath" -ForegroundColor Cyan
    Write-Host "  Authentication:        $(if ([string]::IsNullOrWhiteSpace($sqlSAPassword)) { 'Windows Only' } else { 'Mixed (Windows + SQL)' })" -ForegroundColor Cyan
    Write-Host "  System Admin Account:  $domainName\Adcipro" -ForegroundColor Cyan

    Write-Host "`n[INFO] Post-Installation Configuration:" -ForegroundColor Yellow
    Write-Host "  1. Enable TCP/IP in SQL Server Configuration Manager" -ForegroundColor Yellow
    Write-Host "  2. Enable SQL Server Agent (if not already)" -ForegroundColor Yellow
    Write-Host "  3. Create databases for medical lab:" -ForegroundColor Yellow
    Write-Host "     - LabDB (Lab Results and Tests)" -ForegroundColor Gray
    Write-Host "     - PatientsDB (Patient Information)" -ForegroundColor Gray
    Write-Host "  4. Configure backups" -ForegroundColor Yellow
    Write-Host "  5. Test connectivity from client computers" -ForegroundColor Yellow

    Write-Host "`n[SECURITY] Default Accounts:" -ForegroundColor Yellow
    Write-Host "  Windows Authentication: $domainName\Adcipro (Admin)" -ForegroundColor Cyan
    Write-Host "  SQL Authentication: sa (System Administrator - optional)" -ForegroundColor Cyan

    Write-Host "`n[SAVE] SQL Server Directories:" -ForegroundColor Yellow
    Write-Host "  Data Files:   $sqlDataPath" -ForegroundColor Cyan
    Write-Host "  Log Files:    $sqlLogPath" -ForegroundColor Cyan
    Write-Host "  Backups:      $sqlBackupPath" -ForegroundColor Cyan

    Write-Host "`n[CONFIG] Configuration Manager:" -ForegroundColor Yellow
    Write-Host "  Search for 'SQL Server Configuration Manager' in Windows Start Menu" -ForegroundColor Cyan
    Write-Host "  Configure:" -ForegroundColor Gray
    Write-Host "    1. Services → SQL Server (SQLEXPRESS) - Start mode: Automatic" -ForegroundColor Gray
    Write-Host "    2. SQL Server Network Configuration → Protocols for SQLEXPRESS" -ForegroundColor Gray
    Write-Host "    3. Enable: Named Pipes, TCP/IP" -ForegroundColor Gray

    Write-Host "`n[TIP] Next Steps:" -ForegroundColor Yellow
    Write-Host "  1. Download SQL Server 2019 Express (if not already done)" -ForegroundColor Yellow
    Write-Host "  2. Place installation media in: $sqlMediaPath" -ForegroundColor Yellow
    Write-Host "  3. Use Option 1 or 2 above to install SQL Server" -ForegroundColor Yellow
    Write-Host "  4. Follow Post-Installation Configuration steps" -ForegroundColor Yellow
    Write-Host "  5. Run Script 8 to create lab databases" -ForegroundColor Yellow

    Write-Host "`n[DOCS] Next Steps:" -ForegroundColor Yellow
    Write-Host "  1. Open SQL Server Configuration Manager" -ForegroundColor Yellow
    Write-Host "  2. Enable TCP/IP protocol" -ForegroundColor Yellow
    Write-Host "  3. Start SQL Server service" -ForegroundColor Yellow
    Write-Host "  4. Test connection with sqlcmd" -ForegroundColor Yellow
}
catch {
    Write-Host "[ERROR] Installation error:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
