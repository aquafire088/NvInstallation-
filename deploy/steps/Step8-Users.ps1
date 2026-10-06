# ----------------------
# Step 8: Lab user accounts (spec: named domain account per person).
# Each user gets the shared initial password and MUST change it at first
# logon, lives in its role sub-OU (OU=<Role>,OU=Utilisateurs) and is a
# member of its role group. Never PasswordNotRequired.
# Existing accounts are moved/added as needed; their password is left alone,
# EXCEPT v1 accounts created with no password, which get the initial one.
# A user may instead have its own Password with ChangePasswordAtLogon=false
# (needed for Remote Desktop and auto-logon accounts) and PasswordNeverExpires.
# Exit: 0 = ok, 1 = error
# ----------------------
param(
    [Parameter(Mandatory)] [string]$DirectoryJson
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 8: Create lab users" "STEP"

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $dir     = ConvertFrom-DirectoryJson -Json $DirectoryJson
    $upnSuffix = (Get-ADDomain).DNSRoot

    if ([string]::IsNullOrWhiteSpace($dir.InitialPassword)) {
        Write-Log "Directory.InitialPassword is empty in config.json - users would have no password." "ERROR"
        exit 1
    }
    $initialPwd = ConvertTo-SecureString $dir.InitialPassword -AsPlainText -Force

    $roles = @{}
    foreach ($r in @($dir.Roles)) { $roles[$r.Name] = $r }

    $hadError = $false
    foreach ($u in @($dir.Users)) {
        try {
            $role = $roles[$u.Role]
            if (-not $role) { throw "role '$($u.Role)' is not in Directory.Roles" }

            $ouDN        = Get-LabOUDN -Name $role.Name -Parent $dir.OUs.Users
            $displayName = "$($u.FirstName) $($u.LastName)".Trim()
            $user = Get-ADUser -Filter "SamAccountName -eq '$($u.Username)'" -Properties PasswordNotRequired -ErrorAction SilentlyContinue

            # Optional per user: own Password, ChangePasswordAtLogon=false, PasswordNeverExpires.
            # Remote Desktop (NLA) and auto-logon both fail on a "must change password" account.
            $mustChange = if ($null -ne $u.ChangePasswordAtLogon) { [bool]$u.ChangePasswordAtLogon } else { $true }
            if (-not $mustChange -and [string]::IsNullOrWhiteSpace($u.Password)) {
                throw "ChangePasswordAtLogon is false but Password is empty - set its own Password in config (the shared initial one is not allowed here)"
            }
            $userPwd = if ([string]::IsNullOrWhiteSpace($u.Password)) { $initialPwd } else { ConvertTo-SecureString $u.Password -AsPlainText -Force }

            if (-not $user) {
                New-ADUser `
                    -SamAccountName        $u.Username `
                    -UserPrincipalName     "$($u.Username)@$upnSuffix" `
                    -Name                  $displayName `
                    -GivenName             $u.FirstName `
                    -Surname               $u.LastName `
                    -DisplayName           $displayName `
                    -Department            $role.Name `
                    -Title                 $u.Title `
                    -AccountPassword       $userPwd `
                    -ChangePasswordAtLogon $mustChange `
                    -PasswordNeverExpires  ($u.PasswordNeverExpires -eq $true) `
                    -Enabled               $true `
                    -Path                  $ouDN `
                    -ErrorAction Stop
                Write-Log "User created: $($u.Username) ($($role.Name))$(if ($mustChange) { ' - must change password at logon' } else { ' - own password, no change at logon' })." "OK"
            }
            else {
                if ($user.DistinguishedName -notlike "*,$ouDN") {
                    Move-ADObject -Identity $user.DistinguishedName -TargetPath $ouDN -ErrorAction Stop
                    Write-Log "User moved to $($role.Name): $($u.Username)" "OK"
                }
                if ($user.PasswordNotRequired) {
                    # v1 created these with no password at all - close that hole.
                    Set-ADAccountPassword -Identity $u.Username -Reset -NewPassword $initialPwd -ErrorAction Stop
                    Set-ADUser -Identity $u.Username -PasswordNotRequired $false -ChangePasswordAtLogon $true -ErrorAction Stop
                    Write-Log "User $($u.Username) had no password (v1); initial password set, change required." "OK"
                }
                else {
                    Write-Log "User already exists: $($u.Username) (password untouched)" "INFO"
                }
            }

            $inGroup = Get-ADGroupMember -Identity $role.Group -ErrorAction Stop |
                       Where-Object { $_.SamAccountName -ieq $u.Username }
            if (-not $inGroup) {
                Add-ADGroupMember -Identity $role.Group -Members $u.Username -ErrorAction Stop
                Write-Log "'$($u.Username)' added to $($role.Group)." "OK"
            }
        }
        catch {
            Write-Log "User '$($u.Username)': $($_.Exception.Message)" "ERROR"
            $hadError = $true
        }
    }

    if ($hadError) {
        Write-Log "Step 8 finished with one or more errors (see above). A rejected password usually means InitialPassword fails the domain complexity policy." "ERROR"
        exit 1
    }
    Write-Log "Lab users ready." "OK"
    exit 0
}
catch {
    Write-Log "Step 8 failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
