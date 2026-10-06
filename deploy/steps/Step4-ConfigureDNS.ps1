# ----------------------
# Step 4: Configure DNS (non-interactive, idempotent)
# Zones (forward + IPv4 reverse, both AD-integrated so they replicate to DC02),
# forwarders, recursion, scavenging, routing, and the server's own DNS client
# (preferred = 127.0.0.1, per the spec). Exit: 0 = ok, 1 = error
# ----------------------
param(
    [string]$DomainName   = "DOMLABO.LOCAL",
    [string[]]$Forwarders = @("8.8.8.8", "8.8.4.4", "1.1.1.1"),
    [string]$ServerIP     = "",            # from config; blank = auto-detect
    [string]$PreferredDNS = "127.0.0.1",   # the DC resolves through itself
    [string]$SecondaryDNS = ""             # e.g. DC02 once it exists; blank = none
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 4: Configure DNS server" "STEP"

$dns = Get-WindowsFeature -Name "DNS" -ErrorAction SilentlyContinue
if (-not $dns.Installed) { Write-Log "DNS Server is not installed." "ERROR"; exit 1 }

$Forwarders = @($Forwarders | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
foreach ($f in $Forwarders) {
    try { [ipaddress]$f | Out-Null } catch { Write-Log "Invalid forwarder address: $f" "ERROR"; exit 1 }
}

try {
    $net = Get-ServerNetworkInfo -PreferredIP $ServerIP
    if (-not $net) { Write-Log "Could not determine the server's IPv4 address." "ERROR"; exit 1 }
    $netAdapter     = $net.Adapter
    $serverIP       = $net.IPAddress
    $defaultGateway = $net.Gateway

    # Reverse zone from the real prefix, on an octet boundary (/24 -> 1.168.192).
    $prefix = (Get-NetIPAddress -InterfaceIndex $netAdapter.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -eq $serverIP } | Select-Object -First 1).PrefixLength
    if (-not $prefix) { $prefix = 24 }
    $octets          = [Math]::Max(1, [Math]::Min(3, [int][Math]::Floor($prefix / 8)))
    $ipParts         = $serverIP -split '\.'
    $netParts        = @($ipParts[0..($octets - 1)]) + @('0') * (4 - $octets)
    $networkId       = "{0}/{1}" -f ($netParts -join '.'), ($octets * 8)
    $reverseZoneName = ((@($ipParts[0..($octets - 1)]))[($octets - 1)..0] -join '.') + ".in-addr.arpa"

    Write-Log "Server IP $serverIP/$prefix | Reverse $networkId | Gateway $defaultGateway" "INFO"

    # --- Zones: AD-integrated (replication scope Domain) ------------------
    # Install-ADDSForest already creates the forward zone AD-integrated; this
    # only fills a gap. A file-backed zone would NOT replicate to DC02.
    function Confirm-AdZone {
        param([string]$Name, [hashtable]$CreateArgs)
        $zone = Get-DnsServerZone -Name $Name -ErrorAction SilentlyContinue
        if (-not $zone) {
            Add-DnsServerPrimaryZone @CreateArgs -ReplicationScope Domain -DynamicUpdate Secure -ErrorAction Stop
            Write-Log "Zone created (AD-integrated): $Name" "OK"
        }
        elseif (-not $zone.IsDsIntegrated) {
            ConvertTo-DnsServerPrimaryZone -Name $Name -ReplicationScope Domain -Force -ErrorAction Stop
            Set-DnsServerPrimaryZone -Name $Name -DynamicUpdate Secure -ErrorAction SilentlyContinue
            Write-Log "Zone converted to AD-integrated: $Name" "OK"
        }
        else {
            Write-Log "Zone already AD-integrated: $Name" "OK"
        }
    }
    Confirm-AdZone -Name $DomainName      -CreateArgs @{ Name = $DomainName }
    Confirm-AdZone -Name $reverseZoneName -CreateArgs @{ NetworkId = $networkId }

    # --- Forwarders -------------------------------------------------------
    if ($Forwarders.Count -gt 0) {
        Write-Log "Configuring DNS forwarders: $($Forwarders -join ', ')" "INFO"
        Set-DnsServerForwarder -IPAddress $Forwarders -ErrorAction Stop
    }
    else {
        Write-Log "No forwarders configured; external names resolve via root hints." "WARN"
    }

    Set-DnsServerRecursion -Enable $true -ErrorAction SilentlyContinue
    Set-DnsServerZoneAging -Name $DomainName -Aging $true -ErrorAction SilentlyContinue
    Write-Log "Recursion + zone scavenging enabled." "OK"

    # --- The server's own resolver: 127.0.0.1 first -----------------------
    $clientDns = @($PreferredDNS)
    if (-not [string]::IsNullOrWhiteSpace($SecondaryDNS)) { $clientDns += $SecondaryDNS }
    Set-DnsClientServerAddress -InterfaceIndex $netAdapter.IfIndex -ServerAddresses $clientDns -ErrorAction Stop
    Write-Log "Server DNS client set: $($clientDns -join ', ')" "OK"

    # Routing: the default gateway is already set in Step 1 and the local subnet
    # is on-link automatically, so we only ensure the default route exists.
    # (Cmdlet is New-NetRoute; there is no Add-NetRoute. Best-effort - never fatal.)
    if ($defaultGateway) {
        $defRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $defaultGateway }
        if ($defRoute) {
            Write-Log "Default route present: 0.0.0.0/0 via $defaultGateway" "OK"
        }
        else {
            try {
                New-NetRoute -DestinationPrefix "0.0.0.0/0" -NextHop $defaultGateway -InterfaceAlias $netAdapter.Name -ErrorAction Stop | Out-Null
                Write-Log "Default route added: 0.0.0.0/0 via $defaultGateway" "OK"
            }
            catch {
                Write-Log "Could not add default route (non-fatal): $($_.Exception.Message)" "WARN"
            }
        }
    }
    else {
        Write-Log "No default gateway detected; skipping routing." "WARN"
    }

    Restart-Service -Name DNS -Force -ErrorAction Stop
    Start-Sleep -Seconds 2

    # Publish the DC's own A + PTR now that the reverse zone exists.
    Register-DnsClient -ErrorAction SilentlyContinue
    Clear-DnsClientCache -ErrorAction SilentlyContinue

    Write-Log "DNS configuration completed." "OK"
    exit 0
}
catch {
    Write-Log "Step 4 failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
