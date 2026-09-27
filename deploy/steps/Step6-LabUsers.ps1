# ----------------------
# Step 6: Create lab OUs, users and department security groups
# Runs on the Domain Controller. Exit: 0 = ok, 1 = error
# ----------------------
param(
    [string]$DomainName  = "DOMLABO.LOCAL",
    [string]$GroupPrefix = "GG_"      # GG_Accueil, GG_Technicien, ...
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 6: Create lab OUs, users and department groups" "STEP"

Import-Module ActiveDirectory -ErrorAction SilentlyContinue

# Build DN from the domain name (e.g. DOMLABO.LOCAL -> DC=DOMLABO,DC=LOCAL)
$DomainDN = ($DomainName -split '\.' | ForEach-Object { "DC=$_" }) -join ','

$OUs = @("Accueil", "Prelevement", "Technicien", "Biologiste")

$Users = @(
    @{ FirstName="Secretaire"; LastName="01"; Username="sec01";        Department="Accueil";     JobTitle="Secretaire Medicale" },
    @{ FirstName="Secretaire"; LastName="02"; Username="sec02";        Department="Accueil";     JobTitle="Secretaire Medicale" },
    @{ FirstName="Prelevement";LastName="01"; Username="prev01";       Department="Prelevement"; JobTitle="Prelevement Medicale" },
    @{ FirstName="Prelevement";LastName="02"; Username="prev02";       Department="Prelevement"; JobTitle="Prelevement Medicale" },
    @{ FirstName="Technicien"; LastName="01"; Username="tech01";       Department="Technicien";  JobTitle="Technicien de Laboratoire" },
    @{ FirstName="Technicien"; LastName="02"; Username="tech02";       Department="Technicien";  JobTitle="Technicien de Laboratoire" },
    @{ FirstName="Biologiste"; LastName="01"; Username="biologiste01"; Department="Biologiste";  JobTitle="Biologiste" }
)

try {
    Write-Log "Creating organizational units..." "INFO"
    foreach ($ou in $OUs) {
        $ouDN = "OU=$ou,$DomainDN"
        if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouDN'" -ErrorAction SilentlyContinue) {
            Write-Log "OU already exists: $ou" "INFO"
        }
        else {
            New-ADOrganizationalUnit -Name $ou -Path $DomainDN -ProtectedFromAccidentalDeletion $false
            Write-Log "OU created: $ou" "OK"
        }
    }

    Write-Log "Creating lab users..." "INFO"
    foreach ($u in $Users) {
        $displayName = "$($u.FirstName) $($u.LastName)"
        $upn         = "$($u.Username)@$DomainName"
        $ouPath      = "OU=$($u.Department),$DomainDN"
        if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouPath'" -ErrorAction SilentlyContinue)) {
            $ouPath = "CN=Users,$DomainDN"
        }

        if (Get-ADUser -Filter "SamAccountName -eq '$($u.Username)'" -ErrorAction SilentlyContinue) {
            Write-Log "User already exists: $($u.Username)" "WARN"
        }
        else {
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
            Write-Log "Created user: $($u.Username) - $($u.JobTitle)" "OK"
        }
    }

    # --------------------------------------------------------
    # Department security groups
    # --------------------------------------------------------
    # File permissions are granted to GROUPS, never to individual users:
    # adding a new technician then means one group membership, not an ACL
    # edit on every folder. One global security group per department.
    Write-Log "Creating department security groups..." "INFO"
    foreach ($ou in $OUs) {
        $groupName = "$GroupPrefix$ou"
        $groupPath = "OU=$ou,$DomainDN"
        if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$groupPath'" -ErrorAction SilentlyContinue)) {
            $groupPath = "CN=Users,$DomainDN"
        }

        if (Get-ADGroup -Filter "SamAccountName -eq '$groupName'" -ErrorAction SilentlyContinue) {
            Write-Log "Group already exists: $groupName" "INFO"
        }
        else {
            New-ADGroup -Name $groupName -SamAccountName $groupName `
                -GroupCategory Security -GroupScope Global `
                -Path $groupPath -Description "Service $ou - acces aux dossiers partages" `
                -ErrorAction Stop
            Write-Log "Group created: $groupName" "OK"
        }
    }

    Write-Log "Adding users to their department group..." "INFO"
    foreach ($u in $Users) {
        $groupName = "$GroupPrefix$($u.Department)"
        try {
            $already = Get-ADGroupMember -Identity $groupName -ErrorAction Stop |
                       Where-Object { $_.SamAccountName -ieq $u.Username }
            if ($already) {
                Write-Log "'$($u.Username)' is already in $groupName." "INFO"
            }
            else {
                Add-ADGroupMember -Identity $groupName -Members $u.Username -ErrorAction Stop
                Write-Log "'$($u.Username)' added to $groupName." "OK"
            }
        }
        catch {
            Write-Log "Could not add '$($u.Username)' to '$groupName': $($_.Exception.Message)" "WARN"
        }
    }

    Write-Log "Lab OUs, users and department groups created." "OK"
    exit 0
}
catch {
    Write-Log "Step 6 failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
