# ----------------------
# Step 9: Named domain admin account (spec: "ad-sama : compte admin domaine,
# usage ponctuel"). Created in OU Administrateurs, member of Domain Admins
# and of the extra groups from config (GG-PC-Admins -> local admin on every
# workstation once the GPO step lands).
# Domain Admins is found by its RID (512), not its name: on a French server
# it is "Admins du domaine".
# The built-in Administrator (adcipro) is deliberately NOT touched here.
# Password is set only at creation; an existing account keeps its own.
# Exit: 0 = ok, 1 = error
# ----------------------
param(
    [Parameter(Mandatory)] [string]$DirectoryJson
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 9: Create domain admin account" "STEP"

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $dir    = ConvertFrom-DirectoryJson -Json $DirectoryJson
    $admin  = $dir.DomainAdmin
    $domain = Get-ADDomain

    if (-not $admin -or [string]::IsNullOrWhiteSpace($admin.Username)) {
        Write-Log "Directory.DomainAdmin.Username is missing in config.json." "ERROR"
        exit 1
    }

    $adminsDN = Get-LabOUDN -Name $dir.OUs.Admins
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$adminsDN'" -ErrorAction SilentlyContinue)) {
        Write-Log "$adminsDN does not exist. Run step 6 first." "ERROR"
        exit 1
    }

    $user = Get-ADUser -Filter "SamAccountName -eq '$($admin.Username)'" -ErrorAction SilentlyContinue
    if (-not $user) {
        if ([string]::IsNullOrWhiteSpace($admin.Password)) {
            Write-Log "Directory.DomainAdmin.Password is empty - cannot create '$($admin.Username)'." "ERROR"
            exit 1
        }
        $displayName = if ($admin.DisplayName) { $admin.DisplayName } else { $admin.Username }
        New-ADUser `
            -SamAccountName        $admin.Username `
            -UserPrincipalName     "$($admin.Username)@$($domain.DNSRoot)" `
            -Name                  $admin.Username `
            -DisplayName           $displayName `
            -Description           "Administrateur du domaine - usage ponctuel" `
            -AccountPassword       (ConvertTo-SecureString $admin.Password -AsPlainText -Force) `
            -ChangePasswordAtLogon $false `
            -AccountNotDelegated   $true `
            -Enabled               $true `
            -Path                  $adminsDN `
            -ErrorAction Stop
        Write-Log "Admin account created: $($admin.Username) in $adminsDN" "OK"
    }
    else {
        if ($user.DistinguishedName -notlike "*,$adminsDN") {
            Move-ADObject -Identity $user.DistinguishedName -TargetPath $adminsDN -ErrorAction Stop
            Write-Log "Admin account moved to $($dir.OUs.Admins): $($admin.Username)" "OK"
        }
        else {
            Write-Log "Admin account already exists: $($admin.Username) (password untouched)" "INFO"
        }
    }

    # Domain Admins by RID, then the configured extra groups.
    $groups = @(Get-ADGroup -Identity "$($domain.DomainSID)-512" -ErrorAction Stop)
    foreach ($g in @($admin.MemberOf)) {
        if ([string]::IsNullOrWhiteSpace($g)) { continue }
        $grp = Get-ADGroup -Filter "SamAccountName -eq '$g'" -ErrorAction SilentlyContinue
        if (-not $grp) { Write-Log "Group '$g' not found (run step 7 first?)" "ERROR"; exit 1 }
        $groups += $grp
    }

    foreach ($grp in $groups) {
        $isMember = Get-ADGroupMember -Identity $grp -ErrorAction Stop |
                    Where-Object { $_.SamAccountName -ieq $admin.Username }
        if ($isMember) {
            Write-Log "'$($admin.Username)' already in $($grp.Name)." "INFO"
        }
        else {
            Add-ADGroupMember -Identity $grp -Members $admin.Username -ErrorAction Stop
            Write-Log "'$($admin.Username)' added to $($grp.Name)." "OK"
        }
    }

    Write-Log "Domain admin account ready. Built-in Administrator left as is." "OK"
    exit 0
}
catch {
    Write-Log "Step 9 failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
