# ----------------------
# Step 6: Functional OU structure (spec: "OU Utilisateurs / Groupes /
# Administrateurs / Postes"), with one sub-OU per lab role under Utilisateurs.
# Also makes OU Postes the default home for newly joined computers (redircmp),
# so a workstation joined without -OUPath still gets the Postes GPOs and LAPS.
# Runs on the Domain Controller. Idempotent. Exit: 0 = ok, 1 = error
# ----------------------
param(
    [Parameter(Mandatory)] [string]$DirectoryJson
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 6: Create functional OU structure" "STEP"

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $dir      = ConvertFrom-DirectoryJson -Json $DirectoryJson
    $domainDN = (Get-ADDomain).DistinguishedName

    function Confirm-OU {
        param([string]$Name, [string]$Path, [string]$Description)
        $dn = "OU=$Name,$Path"
        if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue) {
            Write-Log "OU already exists: $dn" "INFO"
        }
        else {
            New-ADOrganizationalUnit -Name $Name -Path $Path -Description $Description `
                -ProtectedFromAccidentalDeletion $true -ErrorAction Stop
            Write-Log "OU created: $dn" "OK"
        }
    }

    # --- Top-level functional OUs -------------------------------------
    Confirm-OU -Name $dir.OUs.Users     -Path $domainDN -Description "Comptes du personnel"
    Confirm-OU -Name $dir.OUs.Groups    -Path $domainDN -Description "Groupes de securite par role"
    Confirm-OU -Name $dir.OUs.Admins    -Path $domainDN -Description "Comptes administrateurs"
    Confirm-OU -Name $dir.OUs.Computers -Path $domainDN -Description "Postes clients du domaine"

    # --- One sub-OU per role under Utilisateurs -------------------------
    $usersDN = Get-LabOUDN -Name $dir.OUs.Users
    foreach ($role in @($dir.Roles)) {
        Confirm-OU -Name $role.Name -Path $usersDN -Description "Utilisateurs - $($role.Name)"
    }

    # --- New computers land in OU Postes, not CN=Computers ---------------
    $postesDN = Get-LabOUDN -Name $dir.OUs.Computers
    if ((Get-ADDomain).ComputersContainer -ieq $postesDN) {
        Write-Log "Default computer container already $postesDN." "OK"
    }
    else {
        $out = & redircmp.exe $postesDN 2>&1
        if ($LASTEXITCODE -ne 0) { throw "redircmp failed: $out" }
        Write-Log "Default computer container redirected to $postesDN." "OK"
    }

    # --- Report leftovers (v1 departmental OUs) - never deleted here ---
    $expected = @($dir.OUs.Users, $dir.OUs.Groups, $dir.OUs.Admins, $dir.OUs.Computers, "Domain Controllers")
    Get-ADOrganizationalUnit -SearchBase $domainDN -SearchScope OneLevel -Filter * |
        Where-Object { $expected -notcontains $_.Name } |
        ForEach-Object { Write-Log "Other top-level OU left in place: $($_.Name) (v1 leftover? move its objects, then delete by hand)" "WARN" }

    Write-Log "OU structure ready." "OK"
    exit 0
}
catch {
    Write-Log "Step 6 failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
