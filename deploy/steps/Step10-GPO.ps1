# ----------------------
# Step 10: Security policy + workstation GPOs (spec: "Politique de securite,
# GPO et comptes admin" and "Plusieurs utilisateurs, un seul poste").
# Every part is OPTIONAL: a section with Enabled=false, or a value left
# empty/null, is not written - Windows keeps its standard setting.
#
#  A) Password policy  -> Default Domain Policy (GptTmpl.inf) + domain object.
#     Writing only Set-ADDefaultDomainPasswordPolicy is NOT enough: the Default
#     Domain Policy GPO re-applies its own values on the next refresh.
#  B) Account lockout  -> same place as A.
#  C) Shared workstations GPO (linked to OU Postes): lock after inactivity,
#     sleep instead of staying on, password on wake, fast user switching on.
#  D) Local admins GPO (linked to OU Postes): GG-PC-Admins becomes a member of
#     the local Administrators group (Restricted Groups).
#     Mode "Exclusive" = Administrators contains ONLY GG-PC-Admins + ExtraMembers
#     (spec); Mode "Add" = GG-PC-Admins is added, existing members stay.
#  E) Always-on GPO (linked to a sub-OU of Postes, e.g. Postes\Technicien):
#     never lock, never sleep, screen always on. A GPO linked closer to the
#     computer wins, so it overrides C for the PCs in that sub-OU.
#  F) Remote Desktop to the domain controllers for named non-admin users:
#     they join BUILTIN\Remote Desktop Users, and that group gets "Allow log
#     on through Remote Desktop Services" in the Default Domain Controllers
#     Policy (by default only Administrators have it on a DC). Without the
#     RDS role, Windows Server allows 2 simultaneous sessions.
# Turning a section off later does NOT revert what an earlier run applied.
# Exit: 0 = ok, 1 = error
# ----------------------
param(
    [Parameter(Mandatory)] [string]$DirectoryJson,
    [string]$PolicyJson = "{}"
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 10: Security policy and workstation GPOs" "STEP"

$DefaultDomainPolicyId = "31B2F340-016D-11D2-945F-00C04FB984F9"
$DefaultDCPolicyId     = "6AC1786C-016F-11D2-945F-00C04FB984F9"
$InfHeader = @('[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1')

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
function Test-On { param($Section) return ($Section -and $Section.Enabled -eq $true) }
function Test-Set { param($Value) return ($null -ne $Value -and "$Value" -ne "") }

# Merge key = value pairs into one [Section] of a GptTmpl.inf (UTF-16).
# Returns $true when the file changed.
function Set-InfValues {
    param([string]$Path, [string]$Section, [System.Collections.Specialized.OrderedDictionary]$Values)
    $lines = if (Test-Path $Path) { @(Get-Content $Path -Encoding Unicode) } else { @($InfHeader) }
    $before = $lines -join "`n"

    $start = [array]::IndexOf(($lines | ForEach-Object { $_.Trim() }), "[$Section]")
    if ($start -lt 0) { $lines += "[$Section]"; $start = $lines.Count - 1 }
    $end = $start + 1
    while ($end -lt $lines.Count -and $lines[$end] -notmatch '^\s*\[') { $end++ }

    $body = [System.Collections.Generic.List[string]]::new()
    if ($end -gt $start + 1) { $lines[($start + 1)..($end - 1)] | ForEach-Object { $body.Add($_) } }
    foreach ($k in $Values.Keys) {
        $line = "$k = $($Values[$k])"
        $i = -1
        for ($j = 0; $j -lt $body.Count; $j++) { if ($body[$j] -match "^\s*$([regex]::Escape($k))\s*=") { $i = $j; break } }
        if ($i -ge 0) { $body[$i] = $line } else { $body.Add($line) }
    }

    $out = @($lines[0..$start]) + @($body)
    if ($end -lt $lines.Count) { $out += $lines[$end..($lines.Count - 1)] }
    if (($out -join "`n") -eq $before) { return $false }

    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    Set-Content -Path $Path -Value $out -Encoding Unicode
    return $true
}

function Confirm-GpoLinked {
    param([string]$Name, [string]$TargetDN)
    $gpo = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if (-not $gpo) {
        $gpo = New-GPO -Name $Name -Comment "NvInstallation - Prolab" -ErrorAction Stop
        Write-Log "GPO created: $Name" "OK"
    }
    $linked = (Get-GPInheritance -Target $TargetDN).GpoLinks | Where-Object { $_.DisplayName -eq $Name }
    if (-not $linked) {
        New-GPLink -Guid $gpo.Id -Target $TargetDN -LinkEnabled Yes -ErrorAction Stop | Out-Null
        Write-Log "GPO '$Name' linked to $TargetDN" "OK"
    }
    return $gpo
}

function Set-GpoDword {
    param([string]$Name, [string]$Key, [string]$ValueName, [int]$Value)
    Set-GPRegistryValue -Name $Name -Key $Key -ValueName $ValueName -Type DWord -Value $Value -ErrorAction Stop | Out-Null
}

# ------------------------------------------------------------
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    if (-not (Get-Module -ListAvailable GroupPolicy)) {
        Write-Log "GroupPolicy module missing; installing GPMC..." "INFO"
        Install-WindowsFeature -Name GPMC -ErrorAction Stop | Out-Null
    }
    Import-Module GroupPolicy -ErrorAction Stop

    $dir    = ConvertFrom-DirectoryJson -Json $DirectoryJson
    $policy = $PolicyJson | ConvertFrom-Json
    $domain = Get-ADDomain
    $postesDN = Get-LabOUDN -Name $dir.OUs.Computers

    # ========================================================
    # A + B) Password and lockout policy (domain-wide)
    # ========================================================
    $pw = $policy.PasswordPolicy
    $lk = $policy.Lockout
    $access = [ordered]@{}
    $adArgs = @{}

    if (Test-On $pw) {
        if (Test-Set $pw.MinLength)    { $access.MinimumPasswordLength = [int]$pw.MinLength;    $adArgs.MinPasswordLength = [int]$pw.MinLength }
        if (Test-Set $pw.Complexity)   { $access.PasswordComplexity = [int][bool]$pw.Complexity; $adArgs.ComplexityEnabled = [bool]$pw.Complexity }
        if (Test-Set $pw.HistoryCount) { $access.PasswordHistorySize = [int]$pw.HistoryCount;   $adArgs.PasswordHistoryCount = [int]$pw.HistoryCount }
        if (Test-Set $pw.MinAgeDays)   { $access.MinimumPasswordAge = [int]$pw.MinAgeDays;      $adArgs.MinPasswordAge = [timespan]::FromDays([int]$pw.MinAgeDays) }
        if (Test-Set $pw.MaxAgeDays)   { $access.MaximumPasswordAge = [int]$pw.MaxAgeDays;      $adArgs.MaxPasswordAge = [timespan]::FromDays([int]$pw.MaxAgeDays) }
    }
    else { Write-Log "Password policy: disabled in config - Windows standard kept." "INFO" }

    if (Test-On $lk) {
        if (Test-Set $lk.Threshold) {
            $access.LockoutBadCount = [int]$lk.Threshold
            $adArgs.LockoutThreshold = [int]$lk.Threshold
        }
        if ([int]$lk.Threshold -gt 0) {
            if ((Test-Set $lk.DurationMinutes) -and (Test-Set $lk.ResetAfterMinutes) -and ([int]$lk.ResetAfterMinutes -gt [int]$lk.DurationMinutes)) {
                Write-Log "Lockout.ResetAfterMinutes ($($lk.ResetAfterMinutes)) must not exceed DurationMinutes ($($lk.DurationMinutes))." "ERROR"
                exit 1
            }
            if (Test-Set $lk.DurationMinutes)   { $access.LockoutDuration   = [int]$lk.DurationMinutes;   $adArgs.LockoutDuration = [timespan]::FromMinutes([int]$lk.DurationMinutes) }
            if (Test-Set $lk.ResetAfterMinutes) { $access.ResetLockoutCount = [int]$lk.ResetAfterMinutes; $adArgs.LockoutObservationWindow = [timespan]::FromMinutes([int]$lk.ResetAfterMinutes) }
        }
    }
    else { Write-Log "Account lockout: disabled in config - Windows standard kept." "INFO" }

    if ($access.Count -gt 0) {
        $inf = Get-GpoInfPath -Id $DefaultDomainPolicyId
        if (Set-InfValues -Path $inf -Section "System Access" -Values $access) {
            Update-GpoMachineVersion -Id $DefaultDomainPolicyId
            Write-Log "Default Domain Policy updated: $(($access.Keys | ForEach-Object { "$_=$($access[$_])" }) -join ', ')" "OK"
        }
        else {
            Write-Log "Default Domain Policy already has these values." "OK"
        }
        # Same values on the domain object so they apply now, not at the next refresh.
        # Order matters for validation: lockout window before duration can fail, so set together.
        Set-ADDefaultDomainPasswordPolicy -Identity $domain.DNSRoot @adArgs -ErrorAction Stop
        Write-Log "Domain password/lockout policy applied." "OK"
    }

    # ========================================================
    # C) Shared workstations GPO -> OU Postes
    # ========================================================
    $sw = $policy.SharedWorkstations
    if (Test-On $sw) {
        $name = if ($sw.GpoName) { $sw.GpoName } else { "Postes-Partages" }
        $null = Confirm-GpoLinked -Name $name -TargetDN $postesDN
        $sys  = "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System"
        $pwr  = "HKLM\Software\Policies\Microsoft\Power\PowerSettings"

        # Fast user switching stays available: users lock instead of logging off.
        Set-GpoDword -Name $name -Key $sys -ValueName "HideFastUserSwitching" -Value 0

        if (Test-Set $sw.LockAfterMinutes) {
            # "Interactive logon: Machine inactivity limit" - locks the session.
            Set-GpoDword -Name $name -Key $sys -ValueName "InactivityTimeoutSecs" -Value ([int]$sw.LockAfterMinutes * 60)
            Write-Log "$($name): lock after $($sw.LockAfterMinutes) min idle." "OK"
        }
        if (Test-Set $sw.SleepAfterMinutes) {
            # Sleep timeout (plugged in + on battery).
            $k = "$pwr\29F6C1DB-86DA-48C5-9FDB-F2B67B1F44DA"
            Set-GpoDword -Name $name -Key $k -ValueName "ACSettingIndex" -Value ([int]$sw.SleepAfterMinutes * 60)
            Set-GpoDword -Name $name -Key $k -ValueName "DCSettingIndex" -Value ([int]$sw.SleepAfterMinutes * 60)
            Write-Log "$($name): sleep after $($sw.SleepAfterMinutes) min idle." "OK"
        }
        if ($sw.PasswordOnWake -eq $true) {
            # "Require a password when a computer wakes".
            $k = "$pwr\0e796bdb-100d-47d6-a2d5-f7d2daa51f51"
            Set-GpoDword -Name $name -Key $k -ValueName "ACSettingIndex" -Value 1
            Set-GpoDword -Name $name -Key $k -ValueName "DCSettingIndex" -Value 1
            Write-Log "$($name): password required on wake." "OK"
        }
    }
    else { Write-Log "Shared-workstation GPO: disabled in config - not created." "INFO" }

    # ========================================================
    # D) Local admins GPO -> OU Postes (Restricted Groups)
    # ========================================================
    $la = $policy.LocalAdmins
    if (Test-On $la) {
        $name      = if ($la.GpoName) { $la.GpoName } else { "Postes-AdminsLocaux" }
        $groupName = if ($la.Group) { $la.Group } else { "GG-PC-Admins" }
        $grp = Get-ADGroup -Filter "SamAccountName -eq '$groupName'" -ErrorAction SilentlyContinue
        if (-not $grp) { Write-Log "Group '$groupName' not found (run step 7 first)." "ERROR"; exit 1 }
        $gpo = Confirm-GpoLinked -Name $name -TargetDN $postesDN

        # Members: "*SID" for anything resolvable in AD, plain name otherwise
        # (local accounts such as admin-sama are resolved on the workstation).
        $members = @("*$($grp.SID.Value)")
        foreach ($m in @($la.ExtraMembers)) {
            if ([string]::IsNullOrWhiteSpace($m)) { continue }
            if ($m.StartsWith('*')) { $members += $m; continue }
            $adObj = Get-ADObject -Filter "SamAccountName -eq '$m'" -Properties objectSid -ErrorAction SilentlyContinue
            $members += $(if ($adObj) { "*$($adObj.objectSid.Value)" } else { $m })
        }

        $mode = if ($la.Mode) { "$($la.Mode)" } else { "Exclusive" }
        $gm = [ordered]@{}
        if ($mode -ieq "Exclusive") {
            # Administrators (S-1-5-32-544) is rebuilt to exactly this list on every refresh.
            # The machine's built-in Administrator (RID 500) cannot be removed and stays.
            $gm['*S-1-5-32-544__Memberof'] = ''
            $gm['*S-1-5-32-544__Members']  = ($members -join ',')
        }
        else {
            # Each member joins Administrators; nothing is removed.
            foreach ($m in $members) {
                $gm["$($m)__Memberof"] = '*S-1-5-32-544'
                $gm["$($m)__Members"]  = ''
            }
        }

        # This GPO is ours: write its template whole so a mode change leaves no stale keys.
        $inf = Get-GpoInfPath -Id $gpo.Id.ToString()
        $content = @($InfHeader) + '[Group Membership]' + @($gm.Keys | ForEach-Object { "$_ = $($gm[$_])".TrimEnd() })
        $current = if (Test-Path $inf) { (Get-Content $inf -Encoding Unicode) -join "`n" } else { "" }
        if ($current -ne ($content -join "`n")) {
            New-Item -ItemType Directory -Force -Path (Split-Path $inf) | Out-Null
            Set-Content -Path $inf -Value $content -Encoding Unicode
            Update-GpoMachineVersion -Id $gpo.Id.ToString()
            Write-Log "$($name): local Administrators = $mode ($($members -join ', '))." "OK"
        }
        else {
            Write-Log "$($name): already configured ($mode)." "OK"
        }
    }
    else { Write-Log "Local-admins GPO: disabled in config - workstations keep their standard Administrators group." "INFO" }

    # ========================================================
    # E) Always-on GPO -> sub-OU of Postes (e.g. Technicien)
    # ========================================================
    $ao = $policy.AlwaysOn
    if (Test-On $ao) {
        $name  = if ($ao.GpoName) { $ao.GpoName } else { "Postes-Techniciens" }
        $subOU = if ($ao.SubOU) { $ao.SubOU } else { "Technicien" }
        $target = "OU=$subOU,$postesDN"
        if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$target'" -ErrorAction SilentlyContinue)) {
            Write-Log "$target does not exist - add '$subOU' to Directory.ComputerSubOUs and run step 6." "ERROR"
            exit 1
        }
        $null = Confirm-GpoLinked -Name $name -TargetDN $target
        $sys = "HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System"
        $pwr = "HKLM\Software\Policies\Microsoft\Power\PowerSettings"

        # 0 = no inactivity lock (overrides LockAfterMinutes from C).
        Set-GpoDword -Name $name -Key $sys -ValueName "InactivityTimeoutSecs" -Value 0
        # 0 = never: sleep, hibernate, turn off the display. No sleep -> no password on wake.
        foreach ($guid in '29F6C1DB-86DA-48C5-9FDB-F2B67B1F44DA',   # sleep
                          '9D7815A6-7EE4-497E-8888-515A05F02364',   # hibernate
                          '3C0BC021-C8A8-4E07-A973-6B14CBCB2B7E',   # display off
                          '0e796bdb-100d-47d6-a2d5-f7d2daa51f51') { # password on wake
            Set-GpoDword -Name $name -Key "$pwr\$guid" -ValueName "ACSettingIndex" -Value 0
            Set-GpoDword -Name $name -Key "$pwr\$guid" -ValueName "DCSettingIndex" -Value 0
        }
        Write-Log "$($name) on $($target): never lock, never sleep, screen always on." "OK"
    }
    else { Write-Log "Always-on GPO: disabled in config - not created." "INFO" }

    # ========================================================
    # F) Remote Desktop to the domain controllers
    # ========================================================
    $rdp = $policy.ServerRemoteDesktop
    if (Test-On $rdp) {
        $rdu = Get-ADGroup -Identity "S-1-5-32-555" -ErrorAction Stop   # BUILTIN\Remote Desktop Users, any language
        foreach ($u in @($rdp.Users)) {
            if ([string]::IsNullOrWhiteSpace($u)) { continue }
            if (-not (Get-ADUser -Filter "SamAccountName -eq '$u'" -ErrorAction SilentlyContinue)) {
                Write-Log "ServerRemoteDesktop: user '$u' not found (add it to Directory.Users, step 8)." "ERROR"
                exit 1
            }
            if (Get-ADGroupMember -Identity $rdu -ErrorAction Stop | Where-Object { $_.SamAccountName -ieq $u }) {
                Write-Log "'$u' already in $($rdu.Name)." "INFO"
            }
            else {
                Add-ADGroupMember -Identity $rdu -Members $u -ErrorAction Stop
                Write-Log "'$u' added to $($rdu.Name)." "OK"
            }
        }

        # Keep whatever the policy already grants, add Administrators + Remote Desktop Users.
        $inf  = Get-GpoInfPath -Id $DefaultDCPolicyId
        $have = @()
        if (Test-Path $inf) {
            $line = Get-Content $inf -Encoding Unicode | Where-Object { $_ -match '^\s*SeRemoteInteractiveLogonRight\s*=' } | Select-Object -First 1
            if ($line) { $have = @(($line -split '=', 2)[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        }
        $want = @($have)
        foreach ($sid in '*S-1-5-32-544', '*S-1-5-32-555') { if ($want -notcontains $sid) { $want += $sid } }
        $rights = [ordered]@{ SeRemoteInteractiveLogonRight = ($want -join ',') }
        if (Set-InfValues -Path $inf -Section "Privilege Rights" -Values $rights) {
            Update-GpoMachineVersion -Id $DefaultDCPolicyId
            $null = gpupdate.exe /target:computer /force
            Write-Log "Default Domain Controllers Policy: Remote Desktop logon = $($want -join ',') (applied now)." "OK"
        }
        else {
            Write-Log "Default Domain Controllers Policy already allows Remote Desktop Users." "OK"
        }
    }
    else { Write-Log "Server Remote Desktop for users: disabled in config - only administrators can RDP to the DC." "INFO" }

    Write-Log "Security policy and GPOs done. Workstations pick them up at the next gpupdate / reboot." "OK"
    exit 0
}
catch {
    Write-Log "Step 10 failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
