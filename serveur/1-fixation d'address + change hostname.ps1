# ----------------------
# Script: Configure Server Hostname and Network Settings
# Purpose: Change hostname and configure static IP, subnet, gateway, and DNS
# ----------------------

# ----------------------
# Function to convert subnet mask to prefix length
# ----------------------
function Convert-SubnetToPrefix {
    param([string]$mask)
    
    try {
        $bits = ($mask.Split('.') | ForEach-Object { [Convert]::ToString([int]$_,2).PadLeft(8,'0') }) -join ''
        $prefixLength = ($bits.ToCharArray() | Where-Object { $_ -eq '1' }).Count
        
        if ($prefixLength -lt 1 -or $prefixLength -gt 32) {
            throw "Invalid subnet mask"
        }
        
        return $prefixLength
    }
    catch {
        Write-Error "Invalid subnet mask format: $_"
        exit 1
    }
}

# ----------------------
# Function to validate IP address
# ----------------------
function Test-IPAddress {
    param([string]$IPAddress)
    
    try {
        [ipaddress]$IPAddress | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

# ----------------------
# Main Script
# ----------------------

# Check if running as Administrator
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "❌ ERROR: This script must be run as Administrator!" -ForegroundColor Red
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Server Configuration Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Get new hostname
Write-Host "`nEnter New Server Settings:" -ForegroundColor Yellow
$newName = Read-Host "Enter new hostname (max 15 characters)"

# Get new username
$newUsername = Read-Host "Enter new username for administrateur account (default: adcipro)"
if ([string]::IsNullOrWhiteSpace($newUsername)) {
    $newUsername = "adcipro"
}

if ([string]::IsNullOrWhiteSpace($newName)) {
    Write-Host "❌ Hostname cannot be empty!" -ForegroundColor Red
    exit 1
}

if ($newName.Length -gt 15) {
    Write-Host "❌ Hostname cannot exceed 15 characters!" -ForegroundColor Red
    exit 1
}

if ($newUsername.Length -gt 20) {
    Write-Host "❌ Username cannot exceed 20 characters!" -ForegroundColor Red
    exit 1
}

# Get IP configuration
$ip = Read-Host "Enter static IP address"
if (-not (Test-IPAddress $ip)) {
    Write-Host "❌ Invalid IP address format!" -ForegroundColor Red
    exit 1
}

$subnet = Read-Host "Enter subnet mask (default 255.255.255.0)"
if ([string]::IsNullOrWhiteSpace($subnet)) { 
    $subnet = "255.255.255.0" 
}

$gateway = Read-Host "Enter default gateway"
if (-not (Test-IPAddress $gateway)) {
    Write-Host "❌ Invalid gateway address format!" -ForegroundColor Red
    exit 1
}

$dns1 = Read-Host "Enter primary DNS server"
if (-not (Test-IPAddress $dns1)) {
    Write-Host "❌ Invalid primary DNS address format!" -ForegroundColor Red
    exit 1
}

$dns2 = Read-Host "Enter secondary DNS server (optional, press Enter to skip)"

# Validate secondary DNS if provided
if (-not [string]::IsNullOrWhiteSpace($dns2)) {
    if (-not (Test-IPAddress $dns2)) {
        Write-Host "❌ Invalid secondary DNS address format!" -ForegroundColor Red
        exit 1
    }
}

# Get network adapter
Write-Host "`nDetecting network adapter..." -ForegroundColor Yellow
$adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1

if (-not $adapter) {
    Write-Host "❌ No active network adapter found!" -ForegroundColor Red
    exit 1
}

Write-Host "✅ Using adapter: $($adapter.Name) (MAC: $($adapter.MacAddress))" -ForegroundColor Green

# Convert subnet to prefix
Write-Host "`nProcessing subnet mask..." -ForegroundColor Yellow
$prefixLength = Convert-SubnetToPrefix $subnet
Write-Host "✅ Subnet mask converted to /$prefixLength" -ForegroundColor Green

# Display summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Configuration Summary:" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Hostname:          $newName" -ForegroundColor White
Write-Host "New Username:      administrateur → $newUsername" -ForegroundColor White
Write-Host "IP Address:        $ip/$prefixLength" -ForegroundColor White
Write-Host "Subnet Mask:       $subnet" -ForegroundColor White
Write-Host "Default Gateway:   $gateway" -ForegroundColor White
Write-Host "Primary DNS:       $dns1" -ForegroundColor White
if (-not [string]::IsNullOrWhiteSpace($dns2)) {
    Write-Host "Secondary DNS:     $dns2" -ForegroundColor White
}
Write-Host "Network Adapter:   $($adapter.Name)" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan

# Confirmation
$confirm = Read-Host "`nApply these settings and restart? (Y/N)"
if ($confirm -ne "Y" -and $confirm -ne "y") {
    Write-Host "❌ Configuration cancelled." -ForegroundColor Yellow
    exit 0
}

Write-Host "`n⏳ Applying configuration..." -ForegroundColor Yellow

try {
    # Rename computer
    Write-Host "Step 1: Renaming server..." -ForegroundColor Cyan
    Rename-Computer -NewName $newName -Force -ErrorAction Stop
    Write-Host "✅ Server renamed to: $newName" -ForegroundColor Green

    # Rename user account
    Write-Host "Step 2: Renaming user account..." -ForegroundColor Cyan
    try {
        $adminUser = Get-LocalUser -Name "administrateur" -ErrorAction Stop
        Rename-LocalUser -Name "administrateur" -NewName $newUsername -ErrorAction Stop
        Write-Host "✅ User account renamed to: $newUsername" -ForegroundColor Green
    }
    catch {
        Write-Host "⚠️  Warning: Could not rename user account - $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Remove existing IP addresses
    Write-Host "Step 3: Removing existing IP configuration..." -ForegroundColor Cyan
    Get-NetIPAddress -InterfaceIndex $adapter.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "✅ Old IP configuration removed" -ForegroundColor Green

    # Remove existing default gateway
    Write-Host "Step 4: Removing existing gateway..." -ForegroundColor Cyan
    Get-NetIPConfiguration -InterfaceIndex $adapter.IfIndex -ErrorAction SilentlyContinue | 
        ForEach-Object {
            if ($_.IPv4DefaultGateway) {
                $_.IPv4DefaultGateway | 
                    ForEach-Object {
                        Remove-NetRoute -InterfaceIndex $adapter.IfIndex -DestinationPrefix "0.0.0.0/0" -NextHop $_.NextHop -Confirm:$false -ErrorAction SilentlyContinue
                    }
            }
        }
    Write-Host "✅ Old gateway removed" -ForegroundColor Green

    # Add new IP address with gateway
    Write-Host "Step 5: Configuring new IP address..." -ForegroundColor Cyan
    New-NetIPAddress -InterfaceIndex $adapter.IfIndex -IPAddress $ip -PrefixLength $prefixLength -DefaultGateway $gateway -ErrorAction Stop
    Write-Host "✅ New IP address configured: $ip/$prefixLength" -ForegroundColor Green

    # Configure DNS
    Write-Host "Step 6: Configuring DNS servers..." -ForegroundColor Cyan
    $dnsServers = @($dns1)
    if (-not [string]::IsNullOrWhiteSpace($dns2)) {
        $dnsServers += $dns2
    }
    Set-DnsClientServerAddress -InterfaceIndex $adapter.IfIndex -ServerAddresses $dnsServers -ErrorAction Stop
    Write-Host "✅ DNS configured: $($dnsServers -join ', ')" -ForegroundColor Green

    # Enable RDP
    Write-Host "Step 7: Enabling Remote Desktop Protocol (RDP)..." -ForegroundColor Cyan
    try {
        # Enable RDP via registry
        $RDPPath = "HKLM:\System\CurrentControlSet\Control\Terminal Server"
        Set-ItemProperty -Path $RDPPath -Name "fDenyTSConnections" -Value 0 -ErrorAction Stop
        Write-Host "✅ RDP enabled in registry" -ForegroundColor Green

        # Enable RDP firewall rule
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
        Write-Host "✅ RDP firewall rule enabled" -ForegroundColor Green
    }
    catch {
        Write-Host "⚠️  Warning: Could not fully enable RDP - $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "✅ Configuration applied successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "`n⏳ Restarting server in 10 seconds..." -ForegroundColor Yellow
    Write-Host "   Press Ctrl+C to cancel restart" -ForegroundColor Yellow
    
    Start-Sleep -Seconds 10
    Restart-Computer -Force

}
catch {
    Write-Host "`n❌ ERROR: An error occurred during configuration:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
