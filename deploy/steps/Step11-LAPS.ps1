# ----------------------
# Step 11: Windows LAPS (spec: "admin-sama + LAPS" - one random, rotating
# password per workstation, stored in AD, readable only by authorised accounts).
# OPTIONAL: config LAPS.Enabled=false skips it; any value left empty is not
# written and Windows LAPS keeps its own default.
#
#   1) Extend the AD schema for Windows LAPS (idempotent).
#   2) Computers in OU Postes may write their OWN password attribute.
#   3) ReadersGroup (GG-PC-Admins) may read / reset those passwords.
#   4) GPO "Postes-LAPS" on OU Postes: which local account to manage
#      (admin-sama), backup to AD, length, complexity, age, encryption.
#
# Windows LAPS = the built-in one (Server 2022 / Win 11 with April 2023+
# updates), NOT the legacy "Microsoft LAPS" MSI. The account itself is
# created on each workstation by poste\Join-Domain.ps1.
# Exit: 0 = ok, 1 = error
# ----------------------
param(
    [Parameter(Mandatory)] [string]$DirectoryJson,
    [string]$LapsJson = "{}"
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 11: Windows LAPS" "STEP"

function Test-Set { param($Value) return ($null -ne $Value -and "$Value" -ne "") }

try {
    $laps = $LapsJson | ConvertFrom-Json
    if (-not ($laps -and $laps.Enabled -eq $true)) {
        Write-Log "LAPS disabled in config - local admin passwords are not managed." "INFO"
        exit 0
    }

    Import-Module ActiveDirectory -ErrorAction Stop
    Import-Module GroupPolicy -ErrorAction Stop
    if (-not (Get-Module -ListAvailable LAPS)) {
        Write-Log "Windows LAPS module not found. Install the April 2023 (or later) cumulative update on this server." "ERROR"
        exit 1
    }
    Import-Module LAPS -ErrorAction Stop

    $dir      = ConvertFrom-DirectoryJson -Json $DirectoryJson
    $domain   = Get-ADDomain
    $postesDN = Get-LabOUDN -Name $dir.OUs.Computers
    $account  = if ($laps.AccountName) { $laps.AccountName } else { "admin-sama" }
    $readers  = if ($laps.ReadersGroup) { $laps.ReadersGroup } else { "GG-PC-Admins" }
    $gpoName  = if ($laps.GpoName) { $laps.GpoName } else { "Postes-LAPS" }

    $readerGroup = Get-ADGroup -Filter "SamAccountName -eq '$readers'" -ErrorAction SilentlyContinue
    if (-not $readerGroup) { Write-Log "Group '$readers' not found (run step 7 first)." "ERROR"; exit 1 }
    $readerName = "$($domain.NetBIOSName)\$readers"

    # --- 1) Schema --------------------------------------------------------
    # Needs schema-write rights. SYSTEM on the DC normally has them; if this
    # fails with access denied, re-run this step as a Schema Admins member
    # (the built-in Administrator is one).
    try {
        Update-LapsADSchema -Confirm:$false -ErrorAction Stop
        Write-Log "AD schema ready for Windows LAPS." "OK"
    }
    catch {
        Write-Log "Update-LapsADSchema failed: $($_.Exception.Message)" "ERROR"
        Write-Log "Run once as a Schema Admins member: .\steps\Step11-LAPS.ps1 (see README), then resume." "ERROR"
        exit 1
    }

    # --- 2) + 3) Permissions on OU Postes -------------------------------
    Set-LapsADComputerSelfPermission -Identity $postesDN -ErrorAction Stop | Out-Null
    Write-Log "Computers in $postesDN may update their own LAPS password." "OK"
    Set-LapsADReadPasswordPermission -Identity $postesDN -AllowedPrincipals $readerName -ErrorAction Stop | Out-Null
    Set-LapsADResetPasswordPermission -Identity $postesDN -AllowedPrincipals $readerName -ErrorAction Stop | Out-Null
    Write-Log "$readerName may read and reset LAPS passwords in $postesDN." "OK"

    # --- 4) GPO -----------------------------------------------------------
    $gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $gpoName -Comment "NvInstallation - Windows LAPS ($account)" -ErrorAction Stop
        Write-Log "GPO created: $gpoName" "OK"
    }
    if (-not ((Get-GPInheritance -Target $postesDN).GpoLinks | Where-Object { $_.DisplayName -eq $gpoName })) {
        New-GPLink -Guid $gpo.Id -Target $postesDN -LinkEnabled Yes -ErrorAction Stop | Out-Null
        Write-Log "GPO '$gpoName' linked to $postesDN" "OK"
    }

    $key = "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS"
    function Set-Laps {
        param([string]$Name, $Value, [string]$Type = "DWord")
        Set-GPRegistryValue -Name $gpoName -Key $key -ValueName $Name -Type $Type -Value $Value -ErrorAction Stop | Out-Null
        Write-Log "$($gpoName): $Name = $Value" "OK"
    }

    Set-Laps -Name "BackupDirectory" -Value 2                       # 2 = Active Directory
    Set-Laps -Name "AdministratorAccountName" -Value $account -Type String
    if (Test-Set $laps.PasswordLength)     { Set-Laps -Name "PasswordLength"     -Value ([int]$laps.PasswordLength) }
    if (Test-Set $laps.PasswordComplexity) { Set-Laps -Name "PasswordComplexity" -Value ([int]$laps.PasswordComplexity) }
    if (Test-Set $laps.PasswordAgeDays)    { Set-Laps -Name "PasswordAgeDays"    -Value ([int]$laps.PasswordAgeDays) }
    if (Test-Set $laps.PostAuthenticationActions) {
        Set-Laps -Name "PostAuthenticationActions" -Value ([int]$laps.PostAuthenticationActions)
    }
    if (Test-Set $laps.PostAuthenticationResetDelayHours) {
        Set-Laps -Name "PostAuthenticationResetDelay" -Value ([int]$laps.PostAuthenticationResetDelayHours)
    }

    # Encryption needs domain functional level 2016+. Only ONE principal can
    # decrypt: the readers group (members of Domain Admins who are not in it
    # cannot read encrypted passwords).
    if ($laps.EncryptPasswords -eq $true) {
        $levels = @('Windows2016Domain', 'Windows2025Domain')
        if ($levels -contains "$($domain.DomainMode)") {
            Set-Laps -Name "ADPasswordEncryptionEnabled" -Value 1
            Set-Laps -Name "ADPasswordEncryptionPrincipal" -Value $readerGroup.SID.Value -Type String
        }
        else {
            Write-Log "Domain level is $($domain.DomainMode); encryption needs 2016+. Passwords stored unencrypted (still readable only by $readerName and Domain Admins)." "WARN"
            Set-Laps -Name "ADPasswordEncryptionEnabled" -Value 0
        }
    }
    elseif ($laps.EncryptPasswords -eq $false) {
        Set-Laps -Name "ADPasswordEncryptionEnabled" -Value 0
    }

    Write-Log "Windows LAPS ready. Read a password with: Get-LapsADPassword -Identity <PC> -AsPlainText" "OK"
    exit 0
}
catch {
    Write-Log "Step 11 failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
