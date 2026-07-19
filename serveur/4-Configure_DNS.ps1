# ----------------------
# Script: Configure DNS Server
# Purpose: Configure DNS forwarders, zones, and settings
# ----------------------

# Check if running as Administrator
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] ERROR: This script must be run as Administrator!" -ForegroundColor Red
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "DNS Server Configuration" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Check if DNS is installed
$dnsStatus = Get-WindowsFeature -Name "DNS" -ErrorAction SilentlyContinue
if (-not $dnsStatus.Installed) {
    Write-Host "[ERROR] ERROR: DNS Server is not installed!" -ForegroundColor Red
    exit 1
}

Write-Host "`nDetecting server network configuration..." -ForegroundColor Yellow

# Get server IP and network info
$serverIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" }).IPAddress | Select-Object -First 1
$netAdapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
$defaultGateway = (Get-NetIPConfiguration -InterfaceAlias $netAdapter.Name).IPv4DefaultGateway.NextHop

# Parse network information
$ipParts = $serverIP -split '\.'
$network = "$($ipParts[0]).$($ipParts[1]).$($ipParts[2]).0"
$reverseZoneName = "$($ipParts[2]).$($ipParts[1]).$($ipParts[0]).in-addr.arpa"

# Default values
$domainName = "DOMLABO.LOCAL"
$dnsForwarder1 = "8.8.8.8"
$dnsForwarder2 = "8.8.4.4"

Write-Host "`nDetected DNS Configuration Settings:" -ForegroundColor Yellow
Write-Host "Domain Name:               $domainName" -ForegroundColor Cyan
Write-Host "Server IP Address:         $serverIP" -ForegroundColor Cyan
Write-Host "Network:                   $network/24" -ForegroundColor Cyan
Write-Host "Reverse Zone:              $reverseZoneName" -ForegroundColor Cyan
Write-Host "Router/Gateway:            $defaultGateway" -ForegroundColor Cyan
Write-Host "Primary DNS Forwarder:     $dnsForwarder1" -ForegroundColor Cyan
Write-Host "Secondary DNS Forwarder:   $dnsForwarder2" -ForegroundColor Cyan

# Allow user to override if different
$override = Read-Host "`nAre these settings correct? (Y/N)"
if ($override -ne "Y" -and $override -ne "y") {
    Write-Host "`n[EDIT]  Enter custom settings:" -ForegroundColor Yellow

    $customIP = Read-Host "Enter Server IP (current: $serverIP)"
    if (-not [string]::IsNullOrWhiteSpace($customIP)) {
        $serverIP = $customIP
        $ipParts = $serverIP -split '\.'
        $network = "$($ipParts[0]).$($ipParts[1]).$($ipParts[2]).0"
        $reverseZoneName = "$($ipParts[2]).$($ipParts[1]).$($ipParts[0]).in-addr.arpa"
    }

    $customGateway = Read-Host "Enter Gateway IP (current: $defaultGateway)"
    if (-not [string]::IsNullOrWhiteSpace($customGateway)) {
        $defaultGateway = $customGateway
    }

    $customForwarder1 = Read-Host "Enter Primary DNS Forwarder (current: $dnsForwarder1)"
    if (-not [string]::IsNullOrWhiteSpace($customForwarder1)) {
        $dnsForwarder1 = $customForwarder1
    }

    $customForwarder2 = Read-Host "Enter Secondary DNS Forwarder (current: $dnsForwarder2)"
    if (-not [string]::IsNullOrWhiteSpace($customForwarder2)) {
        $dnsForwarder2 = $customForwarder2
    }

    Write-Host "`n[EDIT]  Updated Settings:" -ForegroundColor Yellow
    Write-Host "Server IP Address:         $serverIP" -ForegroundColor Cyan
    Write-Host "Network:                   $network/24" -ForegroundColor Cyan
    Write-Host "Reverse Zone:              $reverseZoneName" -ForegroundColor Cyan
    Write-Host "Router/Gateway:            $defaultGateway" -ForegroundColor Cyan
    Write-Host "Primary DNS Forwarder:     $dnsForwarder1" -ForegroundColor Cyan
    Write-Host "Secondary DNS Forwarder:   $dnsForwarder2" -ForegroundColor Cyan
}

# Final confirmation
$confirm = Read-Host "`nProceed with DNS configuration? (Y/N)"
if ($confirm -ne "Y" -and $confirm -ne "y") {
    Write-Host "[ERROR] Configuration cancelled." -ForegroundColor Yellow
    exit 0
}

Write-Host "`n[WAIT] Starting DNS configuration..." -ForegroundColor Yellow

try {
    # Step 1: Check if domain zone exists
    Write-Host "`nStep 1: Verifying domain zone..." -ForegroundColor Cyan
    $zone = Get-DnsServerZone -Name $domainName -ErrorAction SilentlyContinue

    if ($zone) {
        Write-Host "[OK] Domain zone already exists: $domainName" -ForegroundColor Green
    }
    else {
        Write-Host "[WARNING]  Domain zone not found. Creating..." -ForegroundColor Yellow
        Add-DnsServerPrimaryZone -Name $domainName -ZoneFile "$domainName.dns" -ErrorAction Stop
        Write-Host "[OK] Domain zone created: $domainName" -ForegroundColor Green
    }

    # Step 1.5: Create Reverse DNS Zone
    Write-Host "`nStep 1.5: Creating reverse DNS zone..." -ForegroundColor Cyan
    $reverseZone = Get-DnsServerZone -Name $reverseZoneName -ErrorAction SilentlyContinue

    if ($reverseZone) {
        Write-Host "[OK] Reverse zone already exists: $reverseZoneName" -ForegroundColor Green
    }
    else {
        Write-Host "[WARNING]  Reverse zone not found. Creating..." -ForegroundColor Yellow
        Add-DnsServerPrimaryZone -Name $reverseZoneName -ZoneFile "$reverseZoneName.dns" -ErrorAction Stop
        Write-Host "[OK] Reverse zone created: $reverseZoneName" -ForegroundColor Green
    }

    # Step 2: Configure DNS Forwarders
    Write-Host "`nStep 2: Configuring DNS Forwarders..." -ForegroundColor Cyan
    Set-DnsServerForwarder -IPAddress $dnsForwarder1, $dnsForwarder2 -PassThru -ErrorAction Stop | Out-Null
    Write-Host "[OK] DNS Forwarders configured: $dnsForwarder1, $dnsForwarder2" -ForegroundColor Green

    # Step 3: Configure Recursion
    Write-Host "`nStep 3: Enabling recursion..." -ForegroundColor Cyan
    Set-DnsServerRecursion -Enable $true -ErrorAction SilentlyContinue
    Write-Host "[OK] Recursion enabled" -ForegroundColor Green

    # Step 4: Configure Zone Properties
    Write-Host "`nStep 4: Configuring zone properties..." -ForegroundColor Cyan
    Set-DnsServerZoneAging -Name $domainName -Aging $true -ErrorAction SilentlyContinue
    Write-Host "[OK] Zone aging enabled (scavenging)" -ForegroundColor Green

    # Step 5: Configure Routing
    Write-Host "`nStep 5: Configuring routing..." -ForegroundColor Cyan

    if ($defaultGateway) {
        Write-Host "   Default Gateway: $defaultGateway" -ForegroundColor Gray

        # Add static route for local network
        try {
            $routeExists = Get-NetRoute -DestinationPrefix "$network/24" -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $defaultGateway }

            if (-not $routeExists) {
                Add-NetRoute -DestinationPrefix "$network/24" -NextHop $defaultGateway -InterfaceAlias $netAdapter.Name -ErrorAction SilentlyContinue
                Write-Host "[OK] Local network route added: $network/24 via $defaultGateway" -ForegroundColor Green
            }
            else {
                Write-Host "[OK] Local network route already exists: $network/24" -ForegroundColor Green
            }

            # Add default gateway route
            $defaultRouteExists = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $defaultGateway }

            if (-not $defaultRouteExists) {
                Add-NetRoute -DestinationPrefix "0.0.0.0/0" -NextHop $defaultGateway -InterfaceAlias $netAdapter.Name -ErrorAction SilentlyContinue
                Write-Host "[OK] Default route added: 0.0.0.0/0 via $defaultGateway" -ForegroundColor Green
            }
            else {
                Write-Host "[OK] Default route already exists" -ForegroundColor Green
            }
        }
        catch {
            Write-Host "[WARNING]  Could not add routes: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "[WARNING]  No default gateway found" -ForegroundColor Yellow
    }

    # Step 6: Verify DNS records
    Write-Host "`nStep 6: Verifying DNS records..." -ForegroundColor Cyan

    if ($serverIP) {
        Write-Host "[OK] Server IP: $serverIP" -ForegroundColor Green
    }

    # Step 7: Restart DNS Service
    Write-Host "`nStep 7: Restarting DNS Service..." -ForegroundColor Cyan
    Restart-Service -Name DNS -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    Write-Host "[OK] DNS Service restarted" -ForegroundColor Green

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "[OK] DNS configuration completed!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    Write-Host "`n[INFO] DNS & Routing Configuration Summary:" -ForegroundColor Cyan
    Write-Host "  Domain Zone:         $domainName" -ForegroundColor Green
    Write-Host "  Reverse Zone:        $reverseZoneName" -ForegroundColor Green
    Write-Host "  Server IP:           $serverIP" -ForegroundColor Green
    Write-Host "  Network:             $network/24" -ForegroundColor Green
    Write-Host "  Default Gateway:     $defaultGateway" -ForegroundColor Green
    Write-Host "  Primary Forwarder:   $dnsForwarder1" -ForegroundColor Green
    Write-Host "  Secondary Forwarder: $dnsForwarder2" -ForegroundColor Green
    Write-Host "  DNS Recursion:       Enabled" -ForegroundColor Green
    Write-Host "  Zone Scavenging:     Enabled" -ForegroundColor Green
    Write-Host "  Local Route:         $network/24 via $defaultGateway" -ForegroundColor Green
    Write-Host "  Default Route:       0.0.0.0/0 via $defaultGateway" -ForegroundColor Green

    Write-Host "`n[TIP] Next Steps:" -ForegroundColor Yellow
    Write-Host "  1. Test DNS resolution (nslookup $domainName)" -ForegroundColor Yellow
    Write-Host "  2. Configure DHCP if needed (Script 5)" -ForegroundColor Yellow
    Write-Host "  3. Add additional DNS records as needed" -ForegroundColor Yellow

}
catch {
    Write-Host "`n[ERROR] ERROR: An error occurred during DNS configuration:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
