<#
============================================================
  Workstation setup - static IP, rename, join the domain
============================================================
  Run on each lab desktop, elevated. Self-contained: copy just
  this file to the machine, nothing else is needed.

  USAGE (prompts for anything you leave out):
    Set-ExecutionPolicy Bypass -Scope Process -Force
    .\Join-Domain.ps1 -Hostname TECH-01 -IPAddress 192.168.1.101
  Or double-click Poste-Jonction.cmd for the graphical version.

  Order: static IP + DNS (DC01, DC02) -> IPv6 off -> local rescue
  account (admin-sama, random password that Windows LAPS then takes
  over) -> rename + join into OU Postes (GPOs + LAPS are linked there).
  Group policies apply at the reboot that follows the join.

  The hostname prefix matters when DHCP is in use: the server's
  DHCP policies route ACC-* / PREV-* / TECH-* / BIO-* into their
  department IP ranges.
============================================================
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Hostname,
    [Parameter(Mandatory)] [string]$IPAddress,
    [string]$SubnetMask   = "255.255.255.0",
    [string]$Gateway      = "192.168.1.1",
    [string]$DNSServer    = "192.168.1.250",   # DC01
    [string]$DNSServer2   = "",                # DC02 - clients survive a DC01 outage
    [string]$DomainName   = "DOMLABO.LOCAL",
    [string]$OUPath       = "",                # blank = OU=Postes,<domain DN>
    [string]$AdapterName  = "",
    [bool]$DisableIPv6    = $true,
    [string]$LocalAdminName = "admin-sama",    # blank = do not create the rescue account
    [pscredential]$Credential,                 # blank = prompt
    [switch]$NoReboot
)
if ([string]::IsNullOrWhiteSpace($OUPath)) {
    # The DN is derived from the FQDN (always valid); it is the NetBIOS name that must never be.
    $OUPath = "OU=Postes," + (($DomainName -split '\.' | ForEach-Object { "DC=$_" }) -join ',')
}

# ---------- helpers ----------
function Write-Step {
    param([string]$Message, [ValidateSet("INFO","OK","WARN","ERROR")][string]$Level = "INFO")
    $color = switch ($Level) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Test-IPAddress {
    param([string]$IP)
    try { [ipaddress]$IP | Out-Null; return $true } catch { return $false }
}

function Convert-SubnetToPrefix {
    param([string]$mask)
    $bits = ($mask.Split('.') | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8, '0') }) -join ''
    $prefix = ($bits.ToCharArray() | Where-Object { $_ -eq '1' }).Count
    if ($prefix -lt 1 -or $prefix -gt 32) { throw "Invalid subnet mask: $mask" }
    return $prefix
}

function Get-TargetAdapter {
    param([string]$Name)
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $a = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue
        if ($a) { return $a }
        Write-Step "Adapter '$Name' not found; auto-detecting instead." "WARN"
    }
    $a = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if ($a) { return $a }
    return Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Not Present' } | Select-Object -First 1
}

# Local rescue account. The password is random and never shown: Windows LAPS
# (GPO Postes-LAPS) replaces it after the join and stores it in AD.
function Confirm-LocalAdmin {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    if (-not (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)) {
        $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%+=?@'
        $plain = -join (1..24 | ForEach-Object { $chars | Get-Random })
        New-LocalUser -Name $Name -Password (ConvertTo-SecureString $plain -AsPlainText -Force) `
            -PasswordNeverExpires -AccountNeverExpires `
            -Description "Compte de secours local - mot de passe gere par LAPS" -ErrorAction Stop | Out-Null
        Write-Step "Local account '$Name' created (random password, LAPS takes over)." "OK"
    }
    else {
        Write-Step "Local account '$Name' already exists." "OK"
    }
    # Administrators by SID: the group is "Administrateurs" on a French Windows.
    $isAdmin = Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like "*\$Name" }
    if (-not $isAdmin) {
        Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $Name -ErrorAction Stop
        Write-Step "'$Name' added to the local Administrators group." "OK"
    }
}

function Disable-IPv6OnAdapter {
    param($Adapter)
    $binding = Get-NetAdapterBinding -Name $Adapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
    if ($binding -and $binding.Enabled) {
        Disable-NetAdapterBinding -Name $Adapter.Name -ComponentID ms_tcpip6 -ErrorAction Stop
        Write-Step "IPv6 unbound from $($Adapter.Name)." "OK"
    }
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters"
    if ((Get-ItemProperty -Path $key -Name DisabledComponents -ErrorAction SilentlyContinue).DisabledComponents -ne 0xFF) {
        New-ItemProperty -Path $key -Name DisabledComponents -PropertyType DWord -Value 0xFF -Force | Out-Null
        Write-Step "IPv6 stack disabled (applies after the restart)." "OK"
    }
}

# ---------- preconditions ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Step "This script must be run as Administrator." "ERROR"
    exit 1
}

foreach ($pair in @(@{n="IP";v=$IPAddress}, @{n="Gateway";v=$Gateway}, @{n="DNS";v=$DNSServer})) {
    if (-not (Test-IPAddress $pair.v)) { Write-Step "Invalid $($pair.n) address: $($pair.v)" "ERROR"; exit 1 }
}
if (-not [string]::IsNullOrWhiteSpace($DNSServer2) -and -not (Test-IPAddress $DNSServer2)) { Write-Step "Invalid DNS 2 address: $DNSServer2" "ERROR"; exit 1 }
if ($Hostname.Length -gt 15) { Write-Step "Hostname '$Hostname' exceeds 15 characters (NetBIOS limit)." "ERROR"; exit 1 }
if ($Hostname -notmatch '^[A-Za-z0-9-]+$') { Write-Step "Hostname '$Hostname' may only contain letters, digits and hyphens." "ERROR"; exit 1 }

# Already joined? Nothing to do - re-joining a domain member is not idempotent.
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain -and $cs.Domain -ieq $DomainName) {
    Write-Step "This computer is already a member of $($cs.Domain) as '$env:COMPUTERNAME'." "OK"
    # Re-run on a joined machine: only make sure the rescue account exists and refresh policy.
    try { Confirm-LocalAdmin -Name $LocalAdminName } catch { Write-Step "Rescue account: $($_.Exception.Message)" "WARN" }
    $null = gpupdate.exe /target:computer /force
    Write-Step "Computer policy refreshed (gpupdate)." "OK"
    if ($env:COMPUTERNAME -ine $Hostname) {
        Write-Step "Its name is '$env:COMPUTERNAME', not '$Hostname'. Rename a joined machine with:" "WARN"
        Write-Step "  Rename-Computer -NewName $Hostname -DomainCredential (Get-Credential) -Restart" "WARN"
    }
    exit 0
}

Write-Host ""
Write-Host "  Workstation : $Hostname" -ForegroundColor White
Write-Host "  Address     : $IPAddress/$SubnetMask  gw $Gateway" -ForegroundColor White
Write-Host "  DNS / DC    : $DNSServer $(if ($DNSServer2) { "+ $DNSServer2" })" -ForegroundColor White
Write-Host "  OU          : $OUPath" -ForegroundColor White
Write-Host "  Domain      : $DomainName" -ForegroundColor White
Write-Host ""

try {
    $prefix  = Convert-SubnetToPrefix $SubnetMask
    $adapter = Get-TargetAdapter -Name $AdapterName
    if (-not $adapter) { Write-Step "No usable network adapter found." "ERROR"; exit 1 }
    Write-Step "Using adapter: $($adapter.Name) (status $($adapter.Status))"

    # ---------- 1) static IP ----------
    $already = Get-NetIPAddress -InterfaceIndex $adapter.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -eq $IPAddress }
    if ($already) {
        Write-Step "Static IP $IPAddress already configured." "OK"
    }
    else {
        Write-Step "Clearing existing IPv4 configuration..."
        Get-NetIPAddress -InterfaceIndex $adapter.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $adapter.IfIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

        New-NetIPAddress -InterfaceIndex $adapter.IfIndex -IPAddress $IPAddress `
            -PrefixLength $prefix -DefaultGateway $Gateway -ErrorAction Stop | Out-Null
        Write-Step "Static IP set: $IPAddress/$prefix via $Gateway" "OK"
    }

    # ---------- 2) DNS must point at the DC ----------
    # This is the usual cause of a failed join: a workstation pointed at a public
    # resolver cannot find the domain's SRV records, whatever else is correct.
    $dnsList = @($DNSServer)
    if (-not [string]::IsNullOrWhiteSpace($DNSServer2)) { $dnsList += $DNSServer2 }
    Set-DnsClientServerAddress -InterfaceIndex $adapter.IfIndex -ServerAddresses $dnsList -ErrorAction Stop
    Write-Step "DNS servers set to $($dnsList -join ', ')" "OK"

    # ---------- 2b) IPv6 off (spec: on every machine) ----------
    if ($DisableIPv6) { Disable-IPv6OnAdapter -Adapter $adapter }

    # ---------- 2c) local rescue account for LAPS ----------
    Confirm-LocalAdmin -Name $LocalAdminName

    Start-Sleep -Seconds 2
    Clear-DnsClientCache -ErrorAction SilentlyContinue

    # ---------- 3) prove the domain is reachable BEFORE joining ----------
    Write-Step "Checking that '$DomainName' resolves and answers..."
    if (-not (Test-Connection -ComputerName $DNSServer -Count 2 -Quiet)) {
        Write-Step "Cannot ping the domain controller at $DNSServer." "ERROR"
        Write-Step "Check cabling, the switch, and that the server is up." "ERROR"
        exit 1
    }
    try {
        $null = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$DomainName" -Type SRV -Server $DNSServer -ErrorAction Stop
        Write-Step "Domain controller located for $DomainName" "OK"
    }
    catch {
        Write-Step "DNS cannot find a domain controller for '$DomainName'." "ERROR"
        Write-Step "Is $DNSServer really the DC, and is its DNS service running?" "ERROR"
        exit 1
    }

    # ---------- 4) rename + join in ONE operation ----------
    # Add-Computer -NewName renames and joins together, so the machine reboots
    # once. Renaming separately first would join under the old name.
    $cred = $Credential
    if (-not $cred) {
        Write-Step "Enter DOMAIN credentials allowed to join computers (e.g. $(($DomainName -split '\.')[0])\ad-sama)"
        $cred = Get-Credential -Message "Domain account to join $DomainName"
    }
    if (-not $cred) { Write-Step "No credentials supplied; aborting." "ERROR"; exit 1 }

    $joinArgs = @{
        DomainName  = $DomainName
        Credential  = $cred
        NewName     = $Hostname
        Force       = $true
        ErrorAction = 'Stop'
    }
    $joinArgs.OUPath = $OUPath

    Write-Step "Joining $DomainName as '$Hostname'..."
    Add-Computer @joinArgs
    Write-Step "Joined $DomainName as '$Hostname' in $OUPath." "OK"
    Write-Step "GPOs (Postes-Partages, Postes-AdminsLocaux, Postes-LAPS) apply at the restart." "INFO"
}
catch {
    Write-Step "Failed: $($_.Exception.Message)" "ERROR"
    exit 1
}

# ---------- 5) reboot ----------
Write-Host ""
Write-Step "Both the rename and the domain join need a restart to take effect." "WARN"
if ($NoReboot) {
    Write-Step "-NoReboot given; restart this machine manually." "WARN"
    exit 0
}

$answer = Read-Host "Restart now? (Y/N)"
if ($answer -eq 'Y' -or $answer -eq 'y') {
    Write-Step "Restarting in 10 seconds..." "WARN"
    Start-Sleep -Seconds 10
    Restart-Computer -Force
}
else {
    Write-Step "Remember to restart before logging in with a domain account." "WARN"
}
exit 0
