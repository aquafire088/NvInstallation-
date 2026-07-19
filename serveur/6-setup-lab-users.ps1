#Requires -RunAsAdministrator
<#
    DomainForge - Laboratoire d'Analyse Medicale
    Creates OUs and users for the medical lab environment.
    Run ON the Domain Controller (DOMLABO.LOCAL)
#>

Import-Module ActiveDirectory -ErrorAction SilentlyContinue

$Domain   = "DOMLABO.LOCAL"
$DomainDN = "DC=DOMLABO,DC=LOCAL"
$LogFile  = "C:\DomainForge-LabUsers.log"

# ============================================================
# CONFIGURATION
# ============================================================

$OUs = @("Accueil", "Prelevement", "Technicien", "Biologiste")

$Users = @(
    @{
        FirstName  = "Secretaire"
        LastName   = "01"
        Username   = "sec01"
        Department = "Accueil"
        JobTitle   = "Secretaire Medicale"
        Group      = "Domain Users"
    },
    @{
        FirstName  = "Secretaire"
        LastName   = "02"
        Username   = "sec02"
        Department = "Accueil"
        JobTitle   = "Secretaire Medicale"
        Group      = "Domain Users"
    },
    @{
        FirstName  = "Prelevement"
        LastName   = "01"
        Username   = "prev01"
        Department = "Prelevement"
        JobTitle   = "Prelevement Medicale"
        Group      = "Domain Users"
    },
    @{
        FirstName  = "Prelevement"
        LastName   = "02"
        Username   = "prev02"
        Department = "Prelevement"
        JobTitle   = "Prelevement Medicale"
        Group      = "Domain Users"
    },
    @{
        FirstName  = "Technicien"
        LastName   = "01"
        Username   = "tech01"
        Department = "Technicien"
        JobTitle   = "Technicien de Laboratoire"
        Group      = "Domain Users"
    },
    @{
        FirstName  = "Technicien"
        LastName   = "02"
        Username   = "tech02"
        Department = "Technicien"
        JobTitle   = "Technicien de Laboratoire"
        Group      = "Domain Users"
    },
    @{
        FirstName  = "Biologiste"
        LastName   = "01"
        Username   = "biologiste01"
        Department = "Biologiste"
        JobTitle   = "Biologiste"
        Group      = "Domain Users"
    }
)

# ============================================================
# HELPERS
# ============================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    switch ($Level) {
        "INFO"    { Write-Host $line -ForegroundColor Cyan }
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
        "WARNING" { Write-Host $line -ForegroundColor Yellow }
        "ERROR"   { Write-Host $line -ForegroundColor Red }
    }
}

# ============================================================
# STEP 1 - CREATE OUs
# ============================================================

Write-Host ""
Write-Host "=== Creating OUs ===" -ForegroundColor Cyan

foreach ($ou in $OUs) {
    $ouDN = "OU=$ou,$DomainDN"
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'" -ErrorAction SilentlyContinue) {
        Write-Log "OU already exists: $ou" "INFO"
    } else {
        New-ADOrganizationalUnit -Name $ou -Path $DomainDN -ProtectedFromAccidentalDeletion $false
        Write-Log "OU created: $ou" "SUCCESS"
    }
}

# ============================================================
# STEP 2 - CREATE USERS
# ============================================================

Write-Host ""
Write-Host "=== Creating Lab Users ===" -ForegroundColor Cyan

foreach ($u in $Users) {
    $displayName = "$($u.FirstName) $($u.LastName)"
    $upn         = "$($u.Username)@$Domain"
    $ouPath      = "OU=$($u.Department),$DomainDN"

    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouPath'" -ErrorAction SilentlyContinue)) {
        $ouPath = "CN=Users,$DomainDN"
    }

    if (Get-ADUser -Filter "SamAccountName -eq '$($u.Username)'" -ErrorAction SilentlyContinue) {
        Write-Log "User already exists: $($u.Username)" "WARNING"
    } else {
        New-ADUser `
            -SamAccountName        $u.Username `
            -UserPrincipalName     $upn `
            -Name                  $displayName `
            -GivenName             $u.FirstName `
            -Surname               $u.LastName `
            -DisplayName           $displayName `
            -Department            $u.Department `
            -Title                 $u.JobTitle `
            -AccountPassword       $null `
            -PasswordNotRequired   $true `
            -ChangePasswordAtLogon $false `
            -Enabled               $true `
            -Path                  $ouPath

        Write-Log "Created (DISABLED): $($u.Username) - $($u.JobTitle)" "SUCCESS"
        Write-Log "  Activate: Set-ADAccountPassword $($u.Username) ; Enable-ADAccount $($u.Username)" "INFO"
    }

    if ($u.Group -and $u.Group -ne "Domain Users") {
        try {
            Add-ADGroupMember -Identity $u.Group -Members $u.Username
            Write-Log "  Added $($u.Username) to: $($u.Group)" "SUCCESS"
        } catch {
            Write-Log "  Group add failed for $($u.Username): $_" "WARNING"
        }
    }
}

# ============================================================
# STEP 3 - REPORT
# ============================================================

Write-Host ""
Write-Host "=== Lab User Report ===" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  {0,-15} {1,-20} {2,-20} {3,-10}" -f "Username", "Display Name", "Department", "Enabled") -ForegroundColor Yellow
Write-Host ("  " + ("-" * 70)) -ForegroundColor DarkGray

$labDepts = @("Accueil", "Technicien", "Biologiste")
$allUsers = Get-ADUser -Filter * -Properties Department, Title, Enabled |
            Where-Object { $labDepts -contains $_.Department }

foreach ($u in $allUsers) {
    Write-Host ("  {0,-15} {1,-20} {2,-20} {3,-10}" -f $u.SamAccountName, $u.Name, $u.Department, $u.Enabled)
}

Write-Host ""
Write-Host "=== Lab setup complete. Log: $LogFile ===" -ForegroundColor Green
