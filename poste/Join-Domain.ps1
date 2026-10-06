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

  Order: static IP + DNS (DC01, DC02) -> IPv6 off -> [local rescue
  account admin-sama, only with -CreateLocalAdmin: random password that
  Windows LAPS then takes over; LAPS must be enabled on the server]
  -> rename + join into OU Postes (GPOs + LAPS are linked there)
  -> [auto-logon, only with -AutoLogonUser].
  Group policies apply at the reboot that follows the join.

  OU: blank -OUPath = OU Postes, except TECH-* computers which go to
  OU Postes\Technicien (always-on GPO: no lock, no sleep) when it exists.

  Auto-logon: the PC signs in by itself after every restart as
  -AutoLogonUser (a domain account with its own password, no "change at
  next logon" - see config Directory.Users). The password is kept in
  the LSA secret store, not in plain text in the registry.

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
    [string]$OUPath       = "",                # blank = OU=Postes,<domain DN> (TECH-* -> OU=Technicien,OU=Postes)
    [string]$AdapterName  = "",
    [bool]$DisableIPv6    = $true,
    [switch]$CreateLocalAdmin,                 # off by default: create the LAPS rescue account
    [string]$LocalAdminName = "admin-sama",
    [string]$AutoLogonUser  = "",              # blank = no auto-logon
    [securestring]$AutoLogonPassword,
    [pscredential]$Credential,                 # blank = prompt
    [switch]$NoReboot
)
# The DN is derived from the FQDN (always valid); it is the NetBIOS name that must never be.
$DomainDN = ($DomainName -split '\.' | ForEach-Object { "DC=$_" }) -join ','
$PostesDN = "OU=Postes,$DomainDN"
$AutoOU   = [string]::IsNullOrWhiteSpace($OUPath)
if ($AutoOU) {
    # Hostname prefix -> sub-OU of Postes (must match config Directory.ComputerSubOUs).
    $SubOUByPrefix = @{ 'TECH-' = 'Technicien' }
    $OUPath = $PostesDN
    foreach ($pfx in $SubOUByPrefix.Keys) {
        if ($Hostname -like "$pfx*") { $OUPath = "OU=$($SubOUByPrefix[$pfx]),$PostesDN" }
    }
}
if (-not $CreateLocalAdmin) { $LocalAdminName = "" }

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
            -Description "Secours local - mot de passe gere par LAPS" -ErrorAction Stop | Out-Null   # max 48 chars
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

# LDAP bind to the DC with the given account. Throws on a wrong password,
# an account that must change its password, or a missing object.
function Get-LdapEntry {
    param([string]$Server, [string]$Path, [pscredential]$Cred)
    $e = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$Server/$Path", $Cred.UserName, $Cred.GetNetworkCredential().Password)
    $null = $e.NativeObject
    return $e
}

# The real NetBIOS name, asked from AD (never guessed from the FQDN).
function Get-DomainNetbiosName {
    param([string]$Server, [pscredential]$Cred)
    $rootDse = Get-LdapEntry -Server $Server -Path "RootDSE" -Cred $Cred
    $config  = "$($rootDse.Properties['configurationNamingContext'][0])"
    $parts   = Get-LdapEntry -Server $Server -Path "CN=Partitions,$config" -Cred $Cred
    $search  = New-Object System.DirectoryServices.DirectorySearcher($parts, "(&(objectClass=crossRef)(nETBIOSName=*))", [string[]]@('nETBIOSName', 'dnsRoot'))
    foreach ($r in $search.FindAll()) {
        if ("$($r.Properties['dnsroot'][0])" -ieq $DomainName) { return "$($r.Properties['netbiosname'][0])" }
    }
    throw "NetBIOS name of $DomainName not found in AD"
}

# "tech01" / "DOMLABO\tech01" / "tech01@DOMLABO.LOCAL" -> bare account name.
function Get-BareUserName {
    param([string]$Name)
    return (($Name -split '\\')[-1] -split '@')[0]
}

# Auto-logon after every restart. Password goes to the LSA secret
# "DefaultPassword" (what Sysinternals Autologon does), never to the registry.
function Set-AutoLogon {
    param([string]$User, [string]$NetbiosDomain, [securestring]$Password)
    if (-not ('NvInst.LsaSecret' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace NvInst {
public static class LsaSecret {
    [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr SystemName, ref LSA_OBJECT_ATTRIBUTES Attributes, uint Access, out IntPtr Handle);
    [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr Handle, ref LSA_UNICODE_STRING KeyName, ref LSA_UNICODE_STRING PrivateData);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr Handle);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint Status);
    static LSA_UNICODE_STRING Make(string s) {
        var u = new LSA_UNICODE_STRING();
        u.Buffer = Marshal.StringToHGlobalUni(s);
        u.Length = (ushort)(s.Length * 2);
        u.MaximumLength = (ushort)(s.Length * 2 + 2);
        return u;
    }
    public static void Store(string key, string value) {
        var attr = new LSA_OBJECT_ATTRIBUTES();
        attr.Length = Marshal.SizeOf(attr);
        IntPtr h;
        uint st = LsaOpenPolicy(IntPtr.Zero, ref attr, 0x00000020, out h);  // POLICY_CREATE_SECRET
        if (st != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(st));
        var k = Make(key); var v = Make(value);
        try {
            st = LsaStorePrivateData(h, ref k, ref v);
            if (st != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(st));
        }
        finally { Marshal.ZeroFreeGlobalAllocUnicode(v.Buffer); Marshal.FreeHGlobal(k.Buffer); LsaClose(h); }
    }
}
}
'@
    }
    $plain = [System.Net.NetworkCredential]::new('', $Password).Password
    [NvInst.LsaSecret]::Store('DefaultPassword', $plain)
    $plain = $null

    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $wl -Name AutoAdminLogon    -Value '1' -Type String
    Set-ItemProperty -Path $wl -Name DefaultUserName   -Value $User -Type String
    Set-ItemProperty -Path $wl -Name DefaultDomainName -Value $NetbiosDomain -Type String
    # A plain-text DefaultPassword would win over the LSA secret; AutoLogonCount would stop it after N logons.
    Remove-ItemProperty -Path $wl -Name DefaultPassword, AutoLogonCount -ErrorAction SilentlyContinue
    # Windows 11 "passwordless" mode hides and blocks auto-logon.
    $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'
    if (-not (Test-Path $pl)) { New-Item -Path $pl -Force | Out-Null }
    Set-ItemProperty -Path $pl -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord
    Write-Step "Auto-logon set: this PC signs in as $NetbiosDomain\$User after every restart." "OK"
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

# Auto-logon account: checked against the DC (password right, no "must change")
# before anything is joined; written only after the join succeeded.
$autoLogon = $null
if (-not [string]::IsNullOrWhiteSpace($AutoLogonUser)) {
    if (-not $AutoLogonPassword -or $AutoLogonPassword.Length -eq 0) {
        Write-Step "Auto-logon: -AutoLogonPassword is required with -AutoLogonUser." "ERROR"; exit 1
    }
    $autoLogon = @{ User = (Get-BareUserName $AutoLogonUser) }
    $autoLogon.Cred = New-Object pscredential("$($autoLogon.User)@$DomainName", $AutoLogonPassword)
}
function Test-AutoLogonAccount {
    try { $autoLogon.Netbios = Get-DomainNetbiosName -Server $DNSServer -Cred $autoLogon.Cred }
    catch {
        Write-Step "Auto-logon account '$($autoLogon.User)' rejected by the domain: $($_.Exception.Message)" "ERROR"
        Write-Step "Check its password, and that it does not have 'must change password at next logon' (config: ChangePasswordAtLogon false)." "ERROR"
        exit 1
    }
    Write-Step "Auto-logon account $($autoLogon.Netbios)\$($autoLogon.User) checked." "OK"
}

# Already joined? Nothing to do - re-joining a domain member is not idempotent.
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain -and $cs.Domain -ieq $DomainName) {
    Write-Step "This computer is already a member of $($cs.Domain) as '$env:COMPUTERNAME'." "OK"
    # Re-run on a joined machine: rescue account / auto-logon if asked, then refresh policy.
    try { Confirm-LocalAdmin -Name $LocalAdminName } catch { Write-Step "Rescue account: $($_.Exception.Message)" "WARN" }
    if ($autoLogon) {
        Test-AutoLogonAccount
        Set-AutoLogon -User $autoLogon.User -NetbiosDomain $autoLogon.Netbios -Password $AutoLogonPassword
    }
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
Write-Host "  Rescue acct : $(if ($LocalAdminName) { $LocalAdminName } else { 'no (-CreateLocalAdmin to create admin-sama)' })" -ForegroundColor White
Write-Host "  Auto-logon  : $(if ($autoLogon) { $autoLogon.User } else { 'no' })" -ForegroundColor White
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

    # ---------- 2c) local rescue account for LAPS (only with -CreateLocalAdmin) ----------
    if ($LocalAdminName) { Confirm-LocalAdmin -Name $LocalAdminName }
    else { Write-Step "Local rescue account not created (off by default; -CreateLocalAdmin)." "INFO" }

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
    if ($autoLogon) { Test-AutoLogonAccount }

    # ---------- 4) rename + join in ONE operation ----------
    # Add-Computer -NewName renames and joins together, so the machine reboots
    # once. Renaming separately first would join under the old name.
    $cred = $Credential
    if (-not $cred) {
        Write-Step "Enter DOMAIN credentials allowed to join computers (e.g. adcipro@$DomainName)"
        $cred = Get-Credential -UserName "adcipro@$DomainName" -Message "Domain account to join $DomainName"
    }
    if (-not $cred) { Write-Step "No credentials supplied; aborting." "ERROR"; exit 1 }

    # A sub-OU picked from the hostname (TECH-*) may not exist yet: fall back to OU Postes.
    if ($AutoOU -and $OUPath -ne $PostesDN) {
        try { $null = Get-LdapEntry -Server $DNSServer -Path $OUPath -Cred $cred }
        catch {
            Write-Step "$OUPath not found on the DC - joining into OU Postes instead (move the PC later in dsa.msc)." "WARN"
            $OUPath = $PostesDN
        }
    }

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
    Write-Step "GPOs (Postes-Partages, Postes-AdminsLocaux, Postes-Techniciens, Postes-LAPS) apply at the restart." "INFO"

    # ---------- 4b) auto-logon (only with -AutoLogonUser) ----------
    if ($autoLogon) { Set-AutoLogon -User $autoLogon.User -NetbiosDomain $autoLogon.Netbios -Password $AutoLogonPassword }
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
