# ----------------------
# Step 4: Configure DNS (non-interactive)
# Zones (forward + reverse), forwarders, recursion, scavenging, routing.
# Auto-detects server IP/network/gateway. Exit: 0 = ok, 1 = error
# ----------------------
param(
    [string]$DomainName = "DOMLABO.LOCAL",
    [string]$Forwarder1 = "8.8.8.8",
    [string]$Forwarder2 = "8.8.4.4",
    [string]$ServerIP   = ""   # from config; blank = auto-detect
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 4: Configure DNS server" "STEP"

$dns = Get-WindowsFeature -Name "DNS" -ErrorAction SilentlyContinue
if (-not $dns.Installed) { Write-Log "DNS Server is not installed." "ERROR"; exit 1 }

try {
    $net = Get-ServerNetworkInfo -PreferredIP $ServerIP
    if (-not $net) { Write-Log "Could not determine the server's IPv4 address." "ERROR"; exit 1 }
    $netAdapter     = $net.Adapter
    $serverIP       = $net.IPAddress
    $defaultGateway = $net.Gateway

    $ipParts         = $serverIP -split '\.'
    $network         = "$($ipParts[0]).$($ipParts[1]).$($ipParts[2]).0"
    $reverseZoneName = "$($ipParts[2]).$($ipParts[1]).$($ipParts[0]).in-addr.arpa"

    Write-Log "Server IP $serverIP | Network $network/24 | Gateway $defaultGateway" "INFO"

    # Forward zone
    if (Get-DnsServerZone -Name $DomainName -ErrorAction SilentlyContinue) {
        Write-Log "Domain zone already exists: $DomainName" "OK"
    }
    else {
        Add-DnsServerPrimaryZone -Name $DomainName -ZoneFile "$DomainName.dns" -ErrorAction Stop
        Write-Log "Domain zone created: $DomainName" "OK"
    }

    # Reverse zone
    if (Get-DnsServerZone -Name $reverseZoneName -ErrorAction SilentlyContinue) {
        Write-Log "Reverse zone already exists: $reverseZoneName" "OK"
    }
    else {
        Add-DnsServerPrimaryZone -Name $reverseZoneName -ZoneFile "$reverseZoneName.dns" -ErrorAction Stop
        Write-Log "Reverse zone created: $reverseZoneName" "OK"
    }

    Write-Log "Configuring DNS forwarders: $Forwarder1, $Forwarder2" "INFO"
    Set-DnsServerForwarder -IPAddress $Forwarder1, $Forwarder2 -PassThru -ErrorAction Stop | Out-Null

    Set-DnsServerRecursion -Enable $true -ErrorAction SilentlyContinue
    Set-DnsServerZoneAging -Name $DomainName -Aging $true -ErrorAction SilentlyContinue
    Write-Log "Recursion + zone scavenging enabled." "OK"

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
    Write-Log "DNS configuration completed." "OK"
    exit 0
}
catch {
    Write-Log "Step 4 failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
