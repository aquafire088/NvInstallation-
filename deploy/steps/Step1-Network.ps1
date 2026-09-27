# ----------------------
# Step 1: Network + Hostname + RDP (non-interactive, idempotent)
# Order matters: configure the network FIRST, then rename the account and
# computer LAST. Renaming the logged-in admin account before a CIM call
# (New-NetIPAddress) corrupts name->SID resolution and fails with error 1332.
# Exit codes: 0 = done (no reboot), 3010 = done (reboot required), 1 = error
# ----------------------
param(
    [Parameter(Mandatory)] [string]$Hostname,
    [Parameter(Mandatory)] [string]$NewAdminUsername,
    [Parameter(Mandatory)] [string]$IPAddress,
    [string]$SubnetMask = "255.255.255.0",
    [Parameter(Mandatory)] [string]$Gateway,
    [Parameter(Mandatory)] [string]$PrimaryDNS,
    [string]$SecondaryDNS = "",
    [string]$AdapterName  = ""
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

function Convert-SubnetToPrefix {
    param([string]$mask)
    $bits = ($mask.Split('.') | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8, '0') }) -join ''
    $prefixLength = ($bits.ToCharArray() | Where-Object { $_ -eq '1' }).Count
    if ($prefixLength -lt 1 -or $prefixLength -gt 32) { throw "Invalid subnet mask: $mask" }
    return $prefixLength
}
function Test-IPAddress {
    param([string]$IP)
    try { [ipaddress]$IP | Out-Null; return $true } catch { return $false }
}
function Get-TargetAdapter {
    param([string]$Name)
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $a = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue
        if ($a) { return $a }
        Write-Log "Adapter '$Name' not found; falling back to auto-detect." "WARN"
    }
    # Prefer a connected physical adapter...
    $a = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if ($a) { return $a }
    # ...otherwise any physical adapter that is present (may be temporarily down after IP removal).
    return Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Not Present' } | Select-Object -First 1
}

Assert-Administrator
Write-Log "STEP 1: Network / Hostname / RDP" "STEP"

# --- Validate inputs -----------------------------------------
foreach ($pair in @(@{n="IP";v=$IPAddress}, @{n="Gateway";v=$Gateway}, @{n="Primary DNS";v=$PrimaryDNS})) {
    if (-not (Test-IPAddress $pair.v)) { Write-Log "Invalid $($pair.n) address: $($pair.v)" "ERROR"; exit 1 }
}
if (-not [string]::IsNullOrWhiteSpace($SecondaryDNS) -and -not (Test-IPAddress $SecondaryDNS)) {
    Write-Log "Invalid Secondary DNS address: $SecondaryDNS" "ERROR"; exit 1
}
if ($Hostname.Length -gt 15) { Write-Log "Hostname exceeds 15 characters." "ERROR"; exit 1 }

$rebootNeeded = $false

try {
    $prefixLength = Convert-SubnetToPrefix $SubnetMask

    $adapter = Get-TargetAdapter -Name $AdapterName
    if (-not $adapter) { Write-Log "No usable network adapter found." "ERROR"; exit 1 }
    Write-Log "Using adapter: $($adapter.Name) (MAC: $($adapter.MacAddress), Status: $($adapter.Status))" "INFO"

    # ---------- 1) NETWORK FIRST (before any rename) ----------
    $alreadySet = Get-NetIPAddress -InterfaceIndex $adapter.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                  Where-Object { $_.IPAddress -eq $IPAddress }
    if ($alreadySet) {
        Write-Log "Static IP $IPAddress already configured on adapter." "OK"
    }
    else {
        Write-Log "Removing existing IPv4 configuration..." "INFO"
        Get-NetIPAddress -InterfaceIndex $adapter.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetIPConfiguration -InterfaceIndex $adapter.IfIndex -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.IPv4DefaultGateway) {
                $_.IPv4DefaultGateway | ForEach-Object {
                    Remove-NetRoute -InterfaceIndex $adapter.IfIndex -DestinationPrefix "0.0.0.0/0" -NextHop $_.NextHop -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
        }

        Write-Log "Configuring static IP $IPAddress/$prefixLength (gw $Gateway)..." "INFO"
        New-NetIPAddress -InterfaceIndex $adapter.IfIndex -IPAddress $IPAddress -PrefixLength $prefixLength -DefaultGateway $Gateway -ErrorAction Stop | Out-Null
        Write-Log "Static IP configured." "OK"
    }

    $dnsServers = @($PrimaryDNS)
    if (-not [string]::IsNullOrWhiteSpace($SecondaryDNS)) { $dnsServers += $SecondaryDNS }
    Set-DnsClientServerAddress -InterfaceIndex $adapter.IfIndex -ServerAddresses $dnsServers -ErrorAction Stop
    Write-Log "DNS set: $($dnsServers -join ', ')" "OK"

    # ---------- 2) RDP ----------
    Write-Log "Enabling Remote Desktop (RDP)..." "INFO"
    try {
        Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -ErrorAction Stop
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
        Write-Log "RDP enabled." "OK"
    }
    catch {
        Write-Log "Could not fully enable RDP: $($_.Exception.Message)" "WARN"
    }

    # ---------- 3) RENAME COMPUTER (CIM call - do before the account rename) ----------
    $pendingName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
    if ($env:COMPUTERNAME -ieq $Hostname -or $pendingName -ieq $Hostname) {
        Write-Log "Computer already named (or pending) '$Hostname'." "OK"
        if ($pendingName -ieq $Hostname -and $env:COMPUTERNAME -ine $Hostname) { $rebootNeeded = $true }
    }
    else {
        Rename-Computer -NewName $Hostname -Force -ErrorAction Stop
        Write-Log "Computer renamed to '$Hostname'." "OK"
        $rebootNeeded = $true
    }

    # ---------- 4) RENAME ADMIN ACCOUNT (VERY LAST) ----------
    # This corrupts name->SID resolution for the CURRENT session, so nothing
    # else (CIM/WMI) may run after it - we reboot to get a clean session.
    if (Get-LocalUser -Name $NewAdminUsername -ErrorAction SilentlyContinue) {
        Write-Log "Admin account already named '$NewAdminUsername'." "OK"
    }
    elseif (Get-LocalUser -Name "administrateur" -ErrorAction SilentlyContinue) {
        Rename-LocalUser -Name "administrateur" -NewName $NewAdminUsername -ErrorAction Stop
        Write-Log "Admin account renamed to '$NewAdminUsername' (reboot to apply)." "OK"
        $rebootNeeded = $true
    }
    else {
        Write-Log "Neither 'administrateur' nor '$NewAdminUsername' found; skipping account rename." "WARN"
    }

    if ($rebootNeeded) {
        Write-Log "Network + identity configured; rebooting to apply." "OK"
        exit 3010
    }
    else {
        Write-Log "Network configured; nothing changed that needs a reboot." "OK"
        exit 0
    }
}
catch {
    Write-Log "Step 1 failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
