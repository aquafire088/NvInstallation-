# ----------------------
# Step 12: Stage data folders from removable media, then share them on the network.
#
# Part A - robocopy each folder from the USB key onto the server disk.
#   Not Copy-Item: these are multi-GB copies off removable media, where
#   retry/resume and unbuffered I/O decide whether the copy finishes at all.
# Part B - create the SMB shares over those same folders.
#
# Runs BEFORE the SQL install (step 13) so the ISO and initial databases are on
# local disk by the time setup needs them. Needs AD to be up: share ACLs are
# granted to domain groups, which must resolve to SIDs.
# Exit: 0 = ok, 1 = error
# ----------------------
param(
    [bool]$StageEnabled       = $true,
    [string]$SourceRoot       = "",     # e.g. "E:\"  (USB key)
    [string]$DestinationRoot  = "",     # e.g. "D:\"  (server disk)
    [string]$FoldersJson      = "[]",   # [] = every top-level folder
    [string]$ExcludeFilesJson = "[]",   # e.g. ["*.iso"]
    [string]$ItemsJson        = "[]",   # FileShares.Items
    [bool]$ApplyNtfs          = $true   # also set NTFS rights, not just share rights
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 12: Stage data from removable media and share it" "STEP"

$hadError = $false

# ============================================================
# PART A - robocopy the folders onto the server disk
# ============================================================
if ($StageEnabled) {
    try { $folders  = @($FoldersJson      | ConvertFrom-Json) } catch { $folders  = @() }
    try { $excludes = @($ExcludeFilesJson | ConvertFrom-Json) } catch { $excludes = @() }

    $src = $SourceRoot.TrimEnd('\', '/')
    $dst = $DestinationRoot.TrimEnd('\', '/')

    # The USB key is the whole point of this half - if it isn't mounted, stop
    # rather than letting step 13 fail later with a confusing "no ISO found".
    if (-not (Test-Path $SourceRoot)) {
        Write-Log "Source '$SourceRoot' is not available. Is the USB key plugged in and mounted on that letter?" "ERROR"
        Write-Log "Check with: Get-Volume | Select-Object DriveLetter, FileSystemLabel" "ERROR"
        Write-Log "Step 13 (SQL) will not find its ISO without this staging step." "ERROR"
        exit 1
    }

    # No explicit list -> take every top-level folder on the media.
    if ($folders.Count -eq 0) {
        $folders = @(Get-ChildItem -Path $SourceRoot -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -notin @('System Volume Information', '$RECYCLE.BIN') } |
                     Select-Object -ExpandProperty Name)
        Write-Log "No folder list configured; staging every top-level folder: $($folders -join ', ')" "INFO"
    }

    if ($folders.Count -eq 0) {
        Write-Log "Nothing to stage - '$SourceRoot' has no folders." "WARN"
    }

    foreach ($folder in $folders) {
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }

        $from = "$src\$folder"
        $to   = "$dst\$folder"

        if (-not (Test-Path $from)) {
            Write-Log "Source folder not found (skipping): $from" "WARN"
            continue
        }

        Write-Log "--- Staging '$from' -> '$to' ---" "INFO"

        # /E   all subfolders incl. empty      /J  unbuffered I/O (fast for big files)
        # /R:2 /W:5  fail fast on a bad sector instead of retrying ~1e6 times
        # /NP /NDL   keep the log readable
        $rcArgs = @($from, $to, '/E', '/J', '/R:2', '/W:5', '/NP', '/NDL')
        foreach ($x in $excludes) {
            if (-not [string]::IsNullOrWhiteSpace($x)) { $rcArgs += @('/XF', $x) }
        }

        & robocopy.exe @rcArgs | Out-Null
        $code = $LASTEXITCODE

        # robocopy exit codes are a bitmask, NOT a plain status: 0-7 are success
        # (1 = files copied, 2 = extras, 4 = mismatches), 8+ means real failures.
        if ($code -lt 8) {
            Write-Log "Staged '$folder' (robocopy code $code)." "OK"
        }
        else {
            Write-Log "robocopy FAILED for '$folder' with code $code (8+ = copy errors)." "ERROR"
            $hadError = $true
        }
    }

    Write-Log "Staging finished." "OK"
}
else {
    Write-Log "Staging disabled in config; skipping the copy." "INFO"
}

# ============================================================
# PART B - create the directories and share them on the network
# ============================================================
try { $items = @($ItemsJson | ConvertFrom-Json) }
catch {
    Write-Log "Could not parse FileShares items JSON: $($_.Exception.Message)" "ERROR"
    exit 1
}

if ($items.Count -eq 0) {
    Write-Log "No file-share items defined; nothing to share." "OK"
    if ($hadError) { exit 1 }
    exit 0
}

# Helper: normalize $null / string / array into a string[].
function Get-AccountList {
    param($v)
    if ($null -eq $v) { return @() }
    return @($v | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

# ------------------------------------------------------------
# Discover the real domain NetBIOS name and the ACTUAL (possibly
# localized) names of the well-known groups, so we can auto-correct
# common config mistakes (wrong prefix, English vs French names).
# ------------------------------------------------------------
$script:WellKnownMap  = @{}   # lowercased leaf name -> correct account string
$script:DomainNetbios = $null
try {
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
    $dom = Get-ADDomain -ErrorAction Stop
    $sid = $dom.DomainSID.Value
    $script:DomainNetbios = $dom.NetBIOSName
    Write-Log "Domain NetBIOS name: $($dom.NetBIOSName)" "INFO"

    # RID 512 = Domain Admins, 513 = Domain Users (SID is language-independent).
    foreach ($pair in @(@{rid=512; keys=@('domain admins','admins du domaine')},
                        @{rid=513; keys=@('domain users','utilisateurs du domaine','utilisa. du domaine')})) {
        try {
            $realName = ([System.Security.Principal.SecurityIdentifier]"$sid-$($pair.rid)").Translate([System.Security.Principal.NTAccount]).Value
            foreach ($k in $pair.keys) { $script:WellKnownMap[$k] = $realName }
            $script:WellKnownMap[($realName -split '\\')[-1].ToLower()] = $realName
            Write-Log "  Group RID $($pair.rid) resolves to: '$realName'" "INFO"
        } catch {}
    }
}
catch {
    Write-Log "Could not query AD for group names (auto-correct disabled): $($_.Exception.Message)" "WARN"
}

# Validate each account name; auto-correct the well-known groups when possible;
# drop (with a warning) anything that still cannot be resolved to a SID.
function Resolve-Accounts {
    param([string[]]$Names)
    $ok = @()
    foreach ($n in $Names) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        try {
            $null = ([System.Security.Principal.NTAccount]$n).Translate([System.Security.Principal.SecurityIdentifier])
            $ok += $n
            continue
        }
        catch { }
        # A bare name ("GG-Techniciens") - qualify it with the REAL NetBIOS name
        # from AD. This is what makes config files survive a domain whose NetBIOS
        # name is not simply the first label of the FQDN.
        if ($n -notmatch '\\' -and $script:DomainNetbios) {
            $qualified = "$script:DomainNetbios\$n"
            try {
                $null = ([System.Security.Principal.NTAccount]$qualified).Translate([System.Security.Principal.SecurityIdentifier])
                Write-Log "  Resolved '$n' -> '$qualified'" "INFO"
                $ok += $qualified
                continue
            }
            catch { }
        }
        # Didn't resolve - try to auto-correct a well-known group by its leaf name.
        $leaf = ($n -split '\\')[-1].ToLower()
        if ($script:WellKnownMap.ContainsKey($leaf)) {
            $fixed = $script:WellKnownMap[$leaf]
            Write-Log "  Auto-corrected '$n' -> '$fixed'" "WARN"
            $ok += $fixed
        }
        else {
            Write-Log "  Cannot resolve account '$n' to a SID - skipping it." "WARN"
        }
    }
    return $ok
}

# ------------------------------------------------------------
# Apply NTFS permissions on the folder itself.
#
# Share permissions alone are not access control: effective access is the MORE
# RESTRICTIVE of share and NTFS, and NTFS here is whatever was inherited from
# the root of the disk - usually far too permissive. The share ACL also does
# nothing at all to someone logged on to the server locally or by RDP.
#
# Inheritance is broken and the ACL rebuilt from scratch, so the result matches
# the config exactly instead of layering on top of whatever was there.
# SYSTEM and Administrators are always kept - without them the folder becomes
# unmanageable and backups fail.
# ------------------------------------------------------------
function Set-NtfsRights {
    param(
        [string]$Path,
        [string[]]$Full   = @(),
        [string[]]$Change = @(),
        [string[]]$Read   = @()
    )

    $acl = Get-Acl -Path $Path

    # $true = protect from inheritance, $false = do NOT copy the inherited ACEs.
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }

    $inherit = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit, ObjectInherit"
    $noProp  = [System.Security.AccessControl.PropagationFlags]::None
    $allow   = [System.Security.AccessControl.AccessControlType]::Allow

    $granted = @()
    $add = {
        param([string]$Account, [string]$Rights)
        try {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $Account,
                [System.Security.AccessControl.FileSystemRights]$Rights,
                $inherit, $noProp, $allow)
            $acl.AddAccessRule($rule)
            $script:ntfsGranted += "$Account=$Rights"
        }
        catch {
            Write-Log "  NTFS: could not grant $Rights to '$Account': $($_.Exception.Message)" "WARN"
        }
    }

    $script:ntfsGranted = @()
    & $add "NT AUTHORITY\SYSTEM"     "FullControl"
    & $add "BUILTIN\Administrators"  "FullControl"
    foreach ($a in $Full)   { & $add $a "FullControl" }
    foreach ($a in $Change) { & $add $a "Modify" }
    foreach ($a in $Read)   { & $add $a "ReadAndExecute" }

    Set-Acl -Path $Path -AclObject $acl -ErrorAction Stop
    Write-Log "  NTFS set: $($script:ntfsGranted -join ' | ')" "OK"
}

foreach ($item in $items) {
    $path      = $item.Path
    $shareName = $item.ShareName

    if ([string]::IsNullOrWhiteSpace($path)) {
        Write-Log "Skipping item with empty Path." "WARN"
        continue
    }

    Write-Log "--- Sharing '$path' ---" "INFO"

    # 1) Make sure the directory exists (staging created most of them already;
    #    this covers items that weren't on the USB key).
    try {
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
            Write-Log "Directory created: $path" "OK"
        }
    }
    catch {
        Write-Log "Failed to create '$path': $($_.Exception.Message)" "ERROR"
        $hadError = $true
        continue
    }

    $full   = Resolve-Accounts (Get-AccountList $item.FullAccess)
    $change = Resolve-Accounts (Get-AccountList $item.ChangeAccess)
    $read   = Resolve-Accounts (Get-AccountList $item.ReadAccess)

    # 2) NTFS permissions on the folder - applied whether or not it is shared,
    #    because they are what actually governs access (share ACL is only the
    #    ceiling, and does nothing for a local or RDP session).
    if ($ApplyNtfs) {
        if (-not ($full.Count -or $change.Count -or $read.Count)) {
            Write-Log "No access lists for '$path'; leaving NTFS permissions untouched." "WARN"
        }
        else {
            try { Set-NtfsRights -Path $path -Full $full -Change $change -Read $read }
            catch {
                Write-Log "Failed to set NTFS permissions on '$path': $($_.Exception.Message)" "ERROR"
                $hadError = $true
            }
        }
    }

    # 3) Create the SMB share (optional - skip if ShareName empty)
    if ([string]::IsNullOrWhiteSpace($shareName)) {
        Write-Log "No ShareName for '$path'; directory only, not shared." "INFO"
        continue
    }

    try {
        $existing = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.Path -ieq $path) {
                Write-Log "Share '$shareName' already exists -> $path" "OK"
            }
            else {
                Write-Log "Share '$shareName' exists but points to '$($existing.Path)' (expected '$path'). Leaving as-is." "WARN"
            }
        }
        else {
            $smbArgs = @{ Name = $shareName; Path = $path; ErrorAction = 'Stop' }
            if (-not [string]::IsNullOrWhiteSpace($item.Description)) { $smbArgs.Description = $item.Description }
            if ($full.Count)   { $smbArgs.FullAccess   = $full }
            if ($change.Count) { $smbArgs.ChangeAccess = $change }
            if ($read.Count)   { $smbArgs.ReadAccess   = $read }
            # Safe default if no access was specified: local Administrators only.
            if (-not ($full.Count -or $change.Count -or $read.Count)) {
                $smbArgs.FullAccess = @("BUILTIN\Administrators")
                Write-Log "No access lists given for '$shareName'; defaulting to Administrators full control." "WARN"
            }
            New-SmbShare @smbArgs | Out-Null
            Write-Log "Share created: \\$env:COMPUTERNAME\$shareName -> $path" "OK"
            if ($full.Count)   { Write-Log "  Full  : $($full -join ', ')" "INFO" }
            if ($change.Count) { Write-Log "  Change: $($change -join ', ')" "INFO" }
            if ($read.Count)   { Write-Log "  Read  : $($read -join ', ')" "INFO" }
        }
    }
    catch {
        Write-Log "Failed to create share '$shareName': $($_.Exception.Message)" "ERROR"
        $hadError = $true
    }
}

if ($hadError) {
    Write-Log "Step 12 finished with one or more errors (see above)." "ERROR"
    exit 1
}
Write-Log "All folders staged and shared on the network." "OK"
exit 0
