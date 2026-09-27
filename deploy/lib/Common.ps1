# ============================================================
# Common.ps1 - Shared helpers for the NvInstallation deployer
# Dot-sourced by Deploy.ps1 and the step scripts.
# ============================================================

# --- Paths (resolved relative to the deploy/ root) ----------
$script:DeployRoot = Split-Path -Parent $PSScriptRoot          # ...\deploy
$script:StateFile  = Join-Path $script:DeployRoot "state.json"
$script:LogFile    = Join-Path $script:DeployRoot "deploy.log"
$script:TaskName   = "NvInstallation-Resume"

# ============================================================
# Logging
# ============================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "OK", "WARN", "ERROR", "STEP")]
        [string]$Level = "INFO"
    )
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    try { Add-Content -Path $script:LogFile -Value $line -ErrorAction SilentlyContinue } catch {}

    $color = switch ($Level) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "STEP"  { "Cyan" }
        default { "White" }
    }
    Write-Host $line -ForegroundColor $color
}

# ============================================================
# Administrator check
# ============================================================
function Assert-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "This must be run as Administrator!" "ERROR"
        exit 1
    }
}

# ============================================================
# DISM wrapper - dism.exe reports failure only via its exit code,
# so a bare call silently "succeeds" on a broken image.
# 0 = ok, 3010 = ok but reboot required. Returns $true on success.
# ============================================================
function Invoke-Dism {
    param([string[]]$Arguments)
    & dism.exe @Arguments | Out-Null
    $code = $LASTEXITCODE
    if ($code -eq 0 -or $code -eq 3010) { return $true }
    Write-Log "dism.exe $($Arguments -join ' ') failed with exit code $code." "ERROR"
    return $false
}

# ============================================================
# Configuration loading
# ============================================================
function Import-DeployConfig {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Log "Config file not found: $Path" "ERROR"
        exit 1
    }
    try {
        # -Encoding UTF8 is required: PS 5.1 otherwise reads the file in the
        # system ANSI codepage and mangles accented values (French group names,
        # DEFAULT_LANGUAGE=[Francais], passwords with non-ASCII characters).
        $cfg = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Log "Failed to parse config JSON: $($_.Exception.Message)" "ERROR"
        exit 1
    }
    # Fill computed defaults
    if ([string]::IsNullOrWhiteSpace($cfg.Domain.DSRMPassword)) {
        $cfg.Domain.DSRMPassword = "Open@$((Get-Date).Year)*"
    }
    if ([string]::IsNullOrWhiteSpace($cfg.Network.PrimaryDNS)) {
        # A DC should point DNS at itself
        $cfg.Network.PrimaryDNS = $cfg.Network.IPAddress
    }
    return $cfg
}

# ============================================================
# State management (which steps are done)
# ============================================================
function Get-DeployState {
    if (Test-Path $script:StateFile) {
        try {
            $s = Get-Content -Path $script:StateFile -Raw | ConvertFrom-Json
            # ConvertTo-Json collapses a 1-element array to a scalar, so a state
            # file written after the first step round-trips CompletedSteps as a
            # String. Without this, += concatenates instead of appending and
            # every step re-runs (reboot loop).
            $s.CompletedSteps = @($s.CompletedSteps)
            return $s
        } catch {}
    }
    # Fresh state
    return [pscustomobject]@{
        CompletedSteps = @()
        StartedUtc     = (Get-Date).ToUniversalTime().ToString("o")
        LastStep       = ""
    }
}

function Save-DeployState {
    param([object]$State)
    $State | ConvertTo-Json -Depth 6 | Set-Content -Path $script:StateFile -Encoding UTF8
}

function Test-StepDone {
    param([object]$State, [string]$StepId)
    return ($State.CompletedSteps -contains $StepId)
}

function Set-StepDone {
    param([object]$State, [string]$StepId)
    if ($State.CompletedSteps -notcontains $StepId) {
        $State.CompletedSteps = @($State.CompletedSteps) + $StepId
    }
    $State.LastStep = $StepId
    Save-DeployState -State $State
}

# ============================================================
# Reboot / resume via Scheduled Task (runs as SYSTEM at boot)
# ============================================================
function Register-ResumeTask {
    param([string]$DeployScript, [string]$ConfigPath)

    $psExe  = (Get-Command powershell.exe).Source
    $arg    = "-NoProfile -ExecutionPolicy Bypass -File `"$DeployScript`" -Resume -Config `"$ConfigPath`""
    $action = New-ScheduledTaskAction -Execute $psExe -Argument $arg
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Resume task registered (runs as SYSTEM at startup)." "OK"
}

function Unregister-ResumeTask {
    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "Resume task removed." "OK"
    }
}

function Invoke-PlannedReboot {
    param([int]$DelaySeconds = 10)
    Write-Log "Rebooting in $DelaySeconds seconds to continue deployment..." "WARN"
    Start-Sleep -Seconds $DelaySeconds
    Restart-Computer -Force
    # Execution ends here; resume task takes over after boot.
    exit 0
}

# ============================================================
# Resolve the server's own IPv4 / gateway / adapter.
# Prefers the address configured in config.json: picking "the first
# non-loopback IPv4" gets the wrong NIC on a multi-homed box, and DNS
# and DHCP then publish an address clients cannot reach.
# Returns @{ IPAddress; Gateway; Adapter } or $null.
# ============================================================
function Get-ServerNetworkInfo {
    param([string]$PreferredIP)

    $adapter = $null
    if (-not [string]::IsNullOrWhiteSpace($PreferredIP)) {
        $bound = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.IPAddress -eq $PreferredIP } | Select-Object -First 1
        if ($bound) {
            $adapter = Get-NetAdapter -InterfaceIndex $bound.InterfaceIndex -ErrorAction SilentlyContinue
        }
        else {
            Write-Log "Configured IP $PreferredIP is not bound to any adapter; auto-detecting." "WARN"
        }
    }
    if (-not $adapter) {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
                   Where-Object { $_.Status -eq 'Up' -and -not $_.Virtual } | Select-Object -First 1
    }
    if (-not $adapter) {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
                   Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    }
    if (-not $adapter) { return $null }

    $cfgIp = Get-NetIPAddress -InterfaceIndex $adapter.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    if (-not $cfgIp) { return $null }

    return @{
        IPAddress = $cfgIp.IPAddress
        Gateway   = (Get-NetIPConfiguration -InterfaceIndex $adapter.IfIndex -ErrorAction SilentlyContinue).IPv4DefaultGateway.NextHop | Select-Object -First 1
        Adapter   = $adapter
    }
}

# ============================================================
# Wait for Active Directory to be ready (after DC promotion)
# ============================================================
function Wait-ForADReady {
    param([int]$TimeoutSeconds = 600)
    Write-Log "Waiting for Active Directory Domain Services to be ready..." "INFO"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            $null = Get-ADDomain -ErrorAction Stop
            Write-Log "Active Directory is ready." "OK"
            return $true
        }
        catch {
            Start-Sleep -Seconds 15
        }
    }
    Write-Log "Timed out waiting for Active Directory." "ERROR"
    return $false
}
