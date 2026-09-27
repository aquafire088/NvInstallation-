# ----------------------
# Step 8: Install SQL Server (non-interactive, idempotent)
# Downloads ISO, mounts it, runs unattended setup. Exit: 0 = ok, 1 = error
# ----------------------
param(
    # Optional: leave blank to install strictly from an ISO already staged in
    # InstallFolder (USB key, share). Only used when no local ISO is found.
    [string]$DownloadUrl   = "",
    [string]$InstallFolder = "D:\Utilitaire\software\sql",
    [string]$InstanceName  = "SQLEXPRESS",
    [string]$DomainName    = "DOMLABO.LOCAL",
    [string]$AdminAccount  = "Adcipro",
    [string]$SAPassword    = "",
    [string]$DataFolder    = "",
    [bool]$InstallSSMS     = $true,
    [string]$SSMSUrl       = "https://aka.ms/ssmsfullsetup"
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 8: Install SQL Server" "STEP"

# ============================================================
# Install SQL Server Management Studio (SSMS) from the web.
# SSMS cannot be installed from the SQL ISO; it is a separate
# download that runs a silent setup. Idempotent.
# ============================================================
# Detect an existing SSMS install across all versions/locations.
# (SSMS <=20 -> Program Files (x86); SSMS 21+ -> Program Files, 64-bit.)
function Test-SsmsInstalled {
    # 1) Registry uninstall entries - most reliable, covers every version.
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $uninstallKeys) {
        $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -like '*SQL Server Management Studio*' } |
               Select-Object -First 1
        if ($hit) { return $hit.DisplayName }
    }
    # 2) Fallback: the install folder on disk (either Program Files location).
    $dir = Get-ChildItem "C:\Program Files\Microsoft SQL Server Management Studio*",
                         "C:\Program Files (x86)\Microsoft SQL Server Management Studio*" `
                         -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dir) { return $dir.Name }
    return $null
}

function Install-SSMS {
    param([string]$Url, [string]$Folder)

    # Skip if SSMS is already installed (don't reinstall).
    $ssms = Test-SsmsInstalled
    if ($ssms) {
        Write-Log "SSMS already installed ($ssms). Skipping install." "OK"
        return
    }

    if (-not (Test-Path $Folder)) { New-Item -ItemType Directory -Path $Folder -Force -ErrorAction SilentlyContinue | Out-Null }
    $ssmsExe = Join-Path $Folder "SSMS-Setup.exe"
    try {
        if (-not (Test-Path $ssmsExe)) {
            Write-Log "Downloading SSMS from $Url ..." "INFO"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $Url -OutFile $ssmsExe -UseBasicParsing -ErrorAction Stop
            Write-Log "SSMS installer downloaded: $ssmsExe" "OK"
        }
        else {
            Write-Log "SSMS installer already present, reusing: $ssmsExe" "OK"
        }

        Write-Log "Running silent SSMS install (a few minutes)..." "INFO"
        $p = Start-Process -FilePath $ssmsExe -ArgumentList "/Install", "/Quiet", "/Norestart" -Wait -PassThru
        if ($p.ExitCode -eq 0)      { Write-Log "SSMS installed successfully." "OK" }
        elseif ($p.ExitCode -eq 3010) { Write-Log "SSMS installed (reboot pending)." "OK" }
        else { Write-Log "SSMS setup returned exit code $($p.ExitCode)." "WARN" }
    }
    catch {
        Write-Log "SSMS install failed: $($_.Exception.Message)" "WARN"
    }
}

# --- Idempotency + auto-repair -------------------------------
# The Windows service name for this instance (named vs. default).
$svcName = if ($InstanceName -ieq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$InstanceName" }

$instKey = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"
$instanceRegistered = $false
if (Test-Path $instKey) {
    $existing = (Get-ItemProperty $instKey).PSObject.Properties |
                Where-Object { $_.Name -notlike 'PS*' -and $_.Name -eq $InstanceName }
    if ($existing) { $instanceRegistered = $true }
}

$needUninstall = $false
if ($instanceRegistered) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    $healthy = $false
    if ($svc) {
        if ($svc.Status -ne 'Running') {
            Write-Log "Instance '$InstanceName' service '$svcName' is $($svc.Status); trying to start it..." "INFO"
            try { Start-Service -Name $svcName -ErrorAction Stop; $svc.Refresh() }
            catch { Write-Log "  Could not start service: $($_.Exception.Message)" "WARN" }
        }
        if ($svc.Status -eq 'Running') { $healthy = $true }
    }
    if ($healthy) {
        Write-Log "SQL instance '$InstanceName' already installed and running. Skipping engine install." "OK"
        if ($InstallSSMS) { Install-SSMS -Url $SSMSUrl -Folder $InstallFolder }
        exit 0
    }
    else {
        Write-Log "Instance '$InstanceName' is registered but NOT healthy (broken/partial install)." "WARN"
        Write-Log "Auto-repair: it will be uninstalled, then reinstalled cleanly." "WARN"
        $needUninstall = $true
    }
}

# --- Validate SA password (only if mixed-mode requested) -----
$useMixedMode = $false
if (-not [string]::IsNullOrWhiteSpace($SAPassword)) {
    $strong = ($SAPassword.Length -ge 8) -and
              ($SAPassword -match '[A-Z]') -and ($SAPassword -match '[a-z]') -and
              ($SAPassword -match '[0-9]') -and ($SAPassword -match '[^A-Za-z0-9]')
    if ($strong) {
        $useMixedMode = $true
        Write-Log "Authentication mode: Mixed (Windows + SQL)" "INFO"
    }
    else {
        Write-Log "SAPassword is too weak (need 8+ chars incl. upper, lower, digit, symbol)." "WARN"
        Write-Log "Falling back to Windows-only authentication." "WARN"
    }
}
else {
    Write-Log "No SA password set -> Windows-only authentication." "INFO"
}

$isoPath = Join-Path $InstallFolder "SQL_Server_Install.iso"

# SQL wants the NetBIOS domain (DOMLABO1\adcipro), not the FQDN.
# Deriving it from the FQDN is wrong whenever the NetBIOS name isn't just the
# first label (DOMLABO.LOCAL vs. a domain actually named DOMLABO1), and setup
# only reports it after ~20 minutes. Ask AD for the real name instead.
$netbios = $null
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $netbios = (Get-ADDomain -ErrorAction Stop).NetBIOSName
    Write-Log "Domain NetBIOS name from AD: $netbios" "INFO"
}
catch {
    $netbios = ($DomainName -split '\.')[0]
    Write-Log "Could not query AD; falling back to derived NetBIOS name '$netbios'." "WARN"
}
$sqlSysAdmin = "$netbios\$AdminAccount"

# --- Fail fast, before a multi-GB download and a 20-minute setup ----
# Every one of these makes setup fail late and cryptically.
$preflightError = $null

try { $null = ([System.Security.Principal.NTAccount]$sqlSysAdmin).Translate([System.Security.Principal.SecurityIdentifier]) }
catch { $preflightError = "SQL sysadmin account '$sqlSysAdmin' does not resolve to a SID. Check Network.NewAdminUsername and Domain.NetbiosName in config.json." }

if (-not $preflightError) {
    # Setup needs room for the ISO (~1.5 GB) plus the installed instance (~2 GB).
    $drive = (Split-Path -Qualifier $InstallFolder).TrimEnd(':')
    $free  = (Get-PSDrive -Name $drive -ErrorAction SilentlyContinue).Free
    if ($null -eq $free) { $preflightError = "Install drive '$drive`:' does not exist (InstallFolder = $InstallFolder)." }
    elseif ($free -lt 10GB -and -not (Test-Path $isoPath)) {
        $preflightError = "Only $([math]::Round($free/1GB,1)) GB free on '$drive`:'; SQL needs ~10 GB for the ISO plus the instance."
    }
}

if ($preflightError) {
    Write-Log "Pre-flight check failed: $preflightError" "ERROR"
    exit 1
}
Write-Log "Pre-flight OK - sysadmin '$sqlSysAdmin' resolves, install drive has room." "OK"

try {
    if (-not (Test-Path $InstallFolder)) {
        New-Item -ItemType Directory -Path $InstallFolder -Force -ErrorAction Stop | Out-Null
        Write-Log "Created install folder: $InstallFolder" "OK"
    }

    # Reuse the ISO if a COMPLETE copy is already downloaded (avoids re-download).
    # A real SQL ISO is >1 GB; anything under 300 MB is treated as a truncated
    # download and fetched again.
    if (Test-Path $isoPath) {
        $isoMB = [math]::Round((Get-Item $isoPath).Length / 1MB)
        if ($isoMB -lt 300) {
            Write-Log "Cached ISO looks incomplete ($isoMB MB); deleting and re-downloading." "WARN"
            Remove-Item $isoPath -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Log "ISO already downloaded ($isoMB MB); reusing - no re-download: $isoPath" "OK"
        }
    }
    # An ISO copied in by hand (USB key, share) won't be named
    # SQL_Server_Install.iso. Any complete .iso already sitting in the install
    # folder is what the operator meant to install - use it instead of
    # downloading a second copy.
    if (-not (Test-Path $isoPath)) {
        $localIso = Get-ChildItem -Path $InstallFolder -Filter *.iso -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Length -gt 300MB } |
                    Sort-Object Length -Descending | Select-Object -First 1
        if ($localIso) {
            $isoPath = $localIso.FullName
            Write-Log "Using ISO found in $InstallFolder ($([math]::Round($localIso.Length/1MB)) MB): $($localIso.Name)" "OK"
        }
    }
    if (-not (Test-Path $isoPath) -and [string]::IsNullOrWhiteSpace($DownloadUrl)) {
        Write-Log "No SQL ISO found in '$InstallFolder' and no SQL.DownloadUrl is set." "ERROR"
        Write-Log "Copy the SQL Server ISO into that folder, or set SQL.DownloadUrl in config.json." "ERROR"
        exit 1
    }
    if (-not (Test-Path $isoPath)) {
        Write-Log "Downloading SQL Server ISO (may take 10-30 min)..." "INFO"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        # BITS streams to disk and resumes; Invoke-WebRequest buffers the whole
        # multi-GB ISO in memory on PS 5.1. Fall back to it only if BITS is off.
        try {
            Start-BitsTransfer -Source $DownloadUrl -Destination $isoPath -Description "SQL Server ISO" -ErrorAction Stop
        }
        catch {
            Write-Log "BITS transfer unavailable ($($_.Exception.Message)); falling back to Invoke-WebRequest." "WARN"
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $isoPath -ErrorAction Stop
        }
        Write-Log "ISO downloaded: $isoPath" "OK"
    }

    # Mount
    Write-Log "Mounting ISO..." "INFO"
    $mount    = Mount-DiskImage -ImagePath $isoPath -PassThru
    $isoDrive = ($mount | Get-Volume).DriveLetter
    if (-not $isoDrive) { Write-Log "Failed to mount ISO." "ERROR"; exit 1 }
    $setupExe = "$isoDrive`:\setup.exe"
    if (-not (Test-Path $setupExe)) {
        Write-Log "setup.exe not found in ISO." "ERROR"
        Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Log "ISO mounted on drive $isoDrive`:" "OK"

    # Auto-repair: remove the broken/partial instance before reinstalling.
    if ($needUninstall) {
        Write-Log "Uninstalling broken instance '$InstanceName'..." "INFO"
        $uninstallArgs = @("/Q", "/ACTION=Uninstall", "/FEATURES=SQLEngine", "/INSTANCENAME=$InstanceName")
        $u = Start-Process -FilePath $setupExe -ArgumentList $uninstallArgs -Wait -PassThru -NoNewWindow
        if ($u.ExitCode -eq 0) { Write-Log "Old instance uninstalled." "OK" }
        else { Write-Log "Uninstall returned exit code $($u.ExitCode); continuing to reinstall anyway." "WARN" }
    }

    # Build unattended install args.
    # NOTE 1: SSMS and "Agent" are NOT valid /FEATURES tokens. SSMS is a separate
    #   download; SQL Server Agent installs with the engine (/AGTSVC*).
    # NOTE 2: This server is a DOMAIN CONTROLLER. SQL's default per-service
    #   "virtual accounts" (NT SERVICE\MSSQLSERVER) cannot be created on a DC, so
    #   the service fails to start. Run the services under a built-in account
    #   (NETWORK SERVICE) that exists on a DC. FullText is dropped because its
    #   daemon hits the same virtual-account limitation.
    $installArgs = @(
        "/Q",
        "/IACCEPTSQLSERVERLICENSETERMS",
        "/ACTION=Install",
        "/FEATURES=SQLEngine",
        "/INSTANCENAME=$InstanceName",
        "/SQLSVCACCOUNT=`"NT AUTHORITY\NETWORK SERVICE`"",
        "/SQLSVCSTARTUPTYPE=Automatic",
        "/AGTSVCACCOUNT=`"NT AUTHORITY\NETWORK SERVICE`"",
        "/AGTSVCSTARTUPTYPE=Automatic",
        "/SQLSYSADMINACCOUNTS=`"$sqlSysAdmin`"", "`"BUILTIN\Administrators`"",
        "/TCPENABLED=1",
        "/UPDATEENABLED=False"
    )
    if ($useMixedMode) {
        $installArgs += "/SECURITYMODE=SQL"
        $installArgs += "/SAPWD=`"$SAPassword`""
    }

    # Relocate the instance data directory (system + default user DBs, logs,
    # backups all live under here) when a DataFolder is configured.
    if (-not [string]::IsNullOrWhiteSpace($DataFolder)) {
        if (-not (Test-Path $DataFolder)) {
            New-Item -ItemType Directory -Path $DataFolder -Force -ErrorAction Stop | Out-Null
            Write-Log "Created SQL data folder: $DataFolder" "OK"
        }
        $installArgs += "/INSTALLSQLDATADIR=`"$DataFolder`""
        $installArgs += "/SQLBACKUPDIR=`"$DataFolder\Backup`""
        Write-Log "SQL data directory set to: $DataFolder" "INFO"
    }

    Write-Log "Running SQL Server setup (10-20 min)..." "INFO"
    $proc = Start-Process -FilePath $setupExe -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
    Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue

    if ($proc.ExitCode -eq 0) {
        Write-Log "SQL Server installed successfully. SQL sysadmin: $sqlSysAdmin" "OK"
        if ($InstallSSMS) { Install-SSMS -Url $SSMSUrl -Folder $InstallFolder }
        exit 0
    }

    # --- Failure: surface setup's own Summary.txt for diagnosis --
    Write-Log "SQL setup failed with exit code $($proc.ExitCode) (hex 0x$('{0:X}' -f $proc.ExitCode))." "ERROR"
    $summary = Get-ChildItem "C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log\Summary.txt" -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($summary) {
        Write-Log "Setup summary ($($summary.FullName)):" "WARN"
        $content = Get-Content $summary.FullName
        $content | Select-Object -First 10 | ForEach-Object { Write-Log "  $_" "WARN" }
        # Surface the component-specific failure reason (English + French keywords).
        $detail = $content | Where-Object {
            $_ -match 'SQLEngine|Feature\b|Status|Statut|Error|Erreur|reason|raison|Composant|Component'
        } | Select-Object -First 25
        if ($detail) {
            Write-Log "Key detail lines:" "WARN"
            $detail | ForEach-Object { Write-Log "  $_" "WARN" }
        }
    }
    exit 1
}
catch {
    Write-Log "Step 8 failed: $($_.Exception.Message)" "ERROR"
    Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
    exit 1
}
