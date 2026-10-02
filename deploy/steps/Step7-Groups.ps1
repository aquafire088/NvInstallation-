# ----------------------
# Step 7: Security groups in OU Groupes (spec: rights by group per role,
# never per user). One global security group per role (GG-Accueil, ...),
# plus the extra groups from config (GG-PC-Admins = workstation local admins,
# wired up by the GPO and LAPS steps).
# A group that exists elsewhere is moved into OU Groupes. Exit: 0 = ok, 1 = error
# ----------------------
param(
    [Parameter(Mandatory)] [string]$DirectoryJson
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 7: Create role security groups" "STEP"

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $dir      = ConvertFrom-DirectoryJson -Json $DirectoryJson
    $groupsDN = Get-LabOUDN -Name $dir.OUs.Groups

    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$groupsDN'" -ErrorAction SilentlyContinue)) {
        Write-Log "$groupsDN does not exist. Run step 6 first." "ERROR"
        exit 1
    }

    $wanted = @()
    foreach ($role in @($dir.Roles)) {
        $wanted += @{ Name = $role.Group; Description = "Role $($role.Name) - acces aux ressources du role" }
    }
    foreach ($g in @($dir.ExtraGroups)) {
        if ($g) { $wanted += @{ Name = $g.Name; Description = $g.Description } }
    }

    foreach ($g in $wanted) {
        if ([string]::IsNullOrWhiteSpace($g.Name)) { continue }
        $existing = Get-ADGroup -Filter "SamAccountName -eq '$($g.Name)'" -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-ADGroup -Name $g.Name -SamAccountName $g.Name `
                -GroupCategory Security -GroupScope Global `
                -Path $groupsDN -Description $g.Description -ErrorAction Stop
            Write-Log "Group created: $($g.Name)" "OK"
        }
        elseif ($existing.DistinguishedName -notlike "*,$groupsDN") {
            Move-ADObject -Identity $existing.DistinguishedName -TargetPath $groupsDN -ErrorAction Stop
            Write-Log "Group moved into $($dir.OUs.Groups): $($g.Name)" "OK"
        }
        else {
            Write-Log "Group already in place: $($g.Name)" "INFO"
        }
    }

    Write-Log "Role groups ready." "OK"
    exit 0
}
catch {
    Write-Log "Step 7 failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
