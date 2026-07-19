# ----------------------
# Script: Complete DHCP Server Configuration
# Purpose: Configure DHCP scope, options, policies, and automatic department IP assignment
# ----------------------

# Check if running as Administrator
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "❌ ERROR: This script must be run as Administrator!" -ForegroundColor Red
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Complete DHCP Server Configuration" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Check if DHCP is installed
$dhcpStatus = Get-WindowsFeature -Name "DHCP" -ErrorAction SilentlyContinue
if (-not $dhcpStatus.Installed) {
    Write-Host "❌ ERROR: DHCP Server is not installed!" -ForegroundColor Red
    exit 1
}

Write-Host "`nDetecting server network configuration..." -ForegroundColor Yellow

# Get server IP and network info
$serverIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" }).IPAddress | Select-Object -First 1
$netAdapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
$defaultGateway = (Get-NetIPConfiguration -InterfaceAlias $netAdapter.Name).IPv4DefaultGateway.NextHop

# Parse network information
$ipParts = $serverIP -split '\.'
$network = "$($ipParts[0]).$($ipParts[1]).$($ipParts[2])"
$subnetMask = "255.255.255.0"
$scopeId = "$network.0"

# Define department DHCP pools
$departments = @(
    @{
        Name = "Accueil"
        Prefix = "ACC-*"
        Start = "$network.50"
        End = "$network.74"
        Description = "Reception / Accueil"
    },
    @{
        Name = "Prelevement"
        Prefix = "PREV-*"
        Start = "$network.75"
        End = "$network.99"
        Description = "Sample Collection / Prelevement"
    },
    @{
        Name = "Technicien"
        Prefix = "TECH-*"
        Start = "$network.100"
        End = "$network.124"
        Description = "Laboratory Technician / Technicien"
    },
    @{
        Name = "Biologiste"
        Prefix = "BIO-*"
        Start = "$network.125"
        End = "$network.149"
        Description = "Biologist / Biologiste"
    }
)

$domainName = "DOMLABO.LOCAL"

Write-Host "`nDetected DHCP Configuration:" -ForegroundColor Yellow
Write-Host "Server IP:                 $serverIP" -ForegroundColor Cyan
Write-Host "Network:                   $network.0/24" -ForegroundColor Cyan
Write-Host "Subnet Mask:               $subnetMask" -ForegroundColor Cyan
Write-Host "Gateway (Option 3):        $defaultGateway" -ForegroundColor Cyan
Write-Host "DNS Server (Option 6):     $serverIP" -ForegroundColor Cyan
Write-Host "Domain Name (Option 15):   $domainName" -ForegroundColor Cyan

Write-Host "`nDepartment DHCP Pools & Policies:" -ForegroundColor Yellow
foreach ($dept in $departments) {
    Write-Host "  $($dept.Name):`t$($dept.Prefix) → $($dept.Start) - $($dept.End)" -ForegroundColor Cyan
}

# Allow user to override if different
$override = Read-Host "`nAre these settings correct? (Y/N)"
if ($override -ne "Y" -and $override -ne "y") {
    Write-Host "`n✏️  Enter custom settings:" -ForegroundColor Yellow

    $customGateway = Read-Host "Enter Gateway IP (current: $defaultGateway)"
    if (-not [string]::IsNullOrWhiteSpace($customGateway)) {
        $defaultGateway = $customGateway
    }

    $customDomain = Read-Host "Enter Domain Name (current: $domainName)"
    if (-not [string]::IsNullOrWhiteSpace($customDomain)) {
        $domainName = $customDomain
    }

    Write-Host "`n✏️  Department pools are fixed to ensure each department has its own range" -ForegroundColor Cyan
}

# Final confirmation
$confirm = Read-Host "`nProceed with DHCP configuration? (Y/N)"
if ($confirm -ne "Y" -and $confirm -ne "y") {
    Write-Host "❌ Configuration cancelled." -ForegroundColor Yellow
    exit 0
}

Write-Host "`n⏳ Starting DHCP configuration..." -ForegroundColor Yellow

try {
    # ==================================================
    # PART 1: DHCP SCOPE CONFIGURATION
    # ==================================================

    # Step 1: Create main DHCP scope
    Write-Host "`nStep 1: Checking DHCP scope..." -ForegroundColor Cyan
    $scopeExists = Get-DhcpServerv4Scope -ScopeId $scopeId -ErrorAction SilentlyContinue

    if ($scopeExists) {
        Write-Host "✅ DHCP scope already exists: $scopeId" -ForegroundColor Green
    }
    else {
        Write-Host "⚠️  DHCP scope not found. Creating..." -ForegroundColor Yellow
        Add-DhcpServerv4Scope `
            -Name "$domainName DHCP Scope" `
            -StartRange "$network.50" `
            -EndRange "$network.149" `
            -SubnetMask $subnetMask `
            -State Active `
            -ErrorAction Stop

        Write-Host "✅ DHCP scope created: $scopeId ($network.50 - $network.149)" -ForegroundColor Green
    }

    # Step 2: Create exclusions for reserved addresses
    Write-Host "`nStep 2: Creating IP exclusions..." -ForegroundColor Cyan
    $exclusions = @(
        @{ Start = "$network.1"; End = "$network.49" },
        @{ Start = "$network.150"; End = "$network.249" },
        @{ Start = "$network.250"; End = "$network.254" }
    )

    foreach ($exclusion in $exclusions) {
        $existingExclusion = Get-DhcpServerv4ExclusionRange -ScopeId $scopeId -ErrorAction SilentlyContinue |
                             Where-Object { $_.StartRange -eq $exclusion.Start }

        if (-not $existingExclusion) {
            Add-DhcpServerv4ExclusionRange -ScopeId $scopeId -StartRange $exclusion.Start -EndRange $exclusion.End -ErrorAction SilentlyContinue
        }
    }
    Write-Host "✅ Exclusions configured (gateway, server, reserved IPs)" -ForegroundColor Green

    # Step 3: Configure DHCP Options
    Write-Host "`nStep 3: Configuring DHCP options..." -ForegroundColor Cyan

    # Option 3: Router (Gateway)
    Set-DhcpServerv4OptionValue `
        -ScopeId $scopeId `
        -OptionId 3 `
        -Value $defaultGateway `
        -ErrorAction Stop

    Write-Host "✅ Option 3 (Gateway): $defaultGateway" -ForegroundColor Green

    # Option 6: DNS Servers
    Set-DhcpServerv4OptionValue `
        -ScopeId $scopeId `
        -OptionId 6 `
        -Value $serverIP `
        -ErrorAction Stop

    Write-Host "✅ Option 6 (DNS Server): $serverIP" -ForegroundColor Green

    # Option 15: Domain Name
    Set-DhcpServerv4OptionValue `
        -ScopeId $scopeId `
        -OptionId 15 `
        -Value $domainName `
        -ErrorAction Stop

    Write-Host "✅ Option 15 (Domain Name): $domainName" -ForegroundColor Green

    # Step 4: Set Lease Duration (Infinite)
    Write-Host "`nStep 4: Configuring lease duration..." -ForegroundColor Cyan
    Set-DhcpServerv4Scope `
        -ScopeId $scopeId `
        -LeaseDuration ([TimeSpan]'36500.00:00:00') `
        -ErrorAction Stop

    Write-Host "✅ Lease duration: Permanent (100 years - effectively infinite)" -ForegroundColor Green

    # ==================================================
    # PART 2: DHCP POLICIES CONFIGURATION
    # ==================================================

    Write-Host "`nStep 5: Creating DHCP policies for automatic department assignment..." -ForegroundColor Cyan

    $policyIndex = 1
    foreach ($dept in $departments) {
        Write-Host "`n  Creating policy for $($dept.Name)..." -ForegroundColor Cyan

        # Check if policy already exists
        $policyExists = Get-DhcpServerv4Policy -ScopeId $scopeId -Name "$($dept.Name) Policy" -ErrorAction SilentlyContinue

        if ($policyExists) {
            Write-Host "  ⚠️  Policy already exists: $($dept.Name)" -ForegroundColor Yellow
        }
        else {
            try {
                # Create the policy
                Add-DhcpServerv4Policy `
                    -ScopeId $scopeId `
                    -Name "$($dept.Name) Policy" `
                    -Description $dept.Description `
                    -ProcessingOrder $policyIndex `
                    -Enabled $true `
                    -ErrorAction Stop

                # Add condition: Hostname pattern
                Add-DhcpServerv4PolicyCondition `
                    -ScopeId $scopeId `
                    -PolicyName "$($dept.Name) Policy" `
                    -ConditionType HostName `
                    -Value $dept.Prefix `
                    -Operator Equal `
                    -ErrorAction Stop

                # Add IP range to policy
                Set-DhcpServerv4PolicyIPRange `
                    -ScopeId $scopeId `
                    -PolicyName "$($dept.Name) Policy" `
                    -StartRange $dept.Start `
                    -EndRange $dept.End `
                    -ErrorAction Stop

                Write-Host "  ✅ Policy created: $($dept.Name) ($($dept.Prefix) → $($dept.Start)-$($dept.End))" -ForegroundColor Green
            }
            catch {
                Write-Host "  ⚠️  Error creating policy: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        $policyIndex++
    }

    # Step 6: Authorize DHCP Server in AD
    Write-Host "`nStep 6: Authorizing DHCP server in Active Directory..." -ForegroundColor Cyan

    try {
        $computerName = $env:COMPUTERNAME
        $fqdn = "$computerName.$domainName"
        $ipAddress = $serverIP

        Add-DhcpServerInDC `
            -DnsName $fqdn `
            -IPAddress $ipAddress `
            -ErrorAction SilentlyContinue

        Write-Host "✅ DHCP server authorized: $fqdn ($ipAddress)" -ForegroundColor Green
    }
    catch {
        Write-Host "⚠️  Could not authorize DHCP server: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Step 7: Restart DHCP Service
    Write-Host "`nStep 7: Restarting DHCP Service..." -ForegroundColor Cyan
    Restart-Service -Name DHCPServer -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    Write-Host "✅ DHCP Service restarted" -ForegroundColor Green

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "✅ Complete DHCP configuration finished!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    Write-Host "`n📋 DHCP Scope Configuration:" -ForegroundColor Cyan
    Write-Host "  Scope ID:            $scopeId" -ForegroundColor Green
    Write-Host "  Scope Name:          $domainName DHCP Scope" -ForegroundColor Green
    Write-Host "  Total IP Pool:       $network.50 - $network.149" -ForegroundColor Green
    Write-Host "  Subnet Mask:         $subnetMask" -ForegroundColor Green
    Write-Host "  Gateway (Opt 3):     $defaultGateway" -ForegroundColor Green
    Write-Host "  DNS Server (Opt 6):  $serverIP" -ForegroundColor Green
    Write-Host "  Domain (Opt 15):     $domainName" -ForegroundColor Green
    Write-Host "  Lease Duration:      Permanent (Never expires)" -ForegroundColor Green
    Write-Host "  Server Status:       Authorized in AD" -ForegroundColor Green

    Write-Host "`n📋 Department DHCP Policies & Pool Allocation:" -ForegroundColor Cyan
    foreach ($dept in $departments) {
        Write-Host "  $($dept.Name):" -ForegroundColor Green
        Write-Host "    Condition: Hostname = $($dept.Prefix)" -ForegroundColor Green
        Write-Host "    IP Pool: $($dept.Start) - $($dept.End)" -ForegroundColor Green
    }

    Write-Host "`n💡 Automatic IP Assignment How-To:" -ForegroundColor Yellow
    Write-Host "  1. Create computer in AD: 'ACC-RECEPTION01'" -ForegroundColor Yellow
    Write-Host "  2. Computer joins domain" -ForegroundColor Yellow
    Write-Host "  3. DHCP policy detects 'ACC-*' prefix" -ForegroundColor Yellow
    Write-Host "  4. Automatically assigns IP from Accueil pool (50-74)" -ForegroundColor Yellow

    Write-Host "`n📝 Computer Naming Convention (IMPORTANT):" -ForegroundColor Yellow
    Write-Host "  ACC-RECEPTION01   → Gets IP from Accueil pool (50-74)" -ForegroundColor Yellow
    Write-Host "  PREV-SAMPLE01     → Gets IP from Prelevement pool (75-99)" -ForegroundColor Yellow
    Write-Host "  TECH-LAB01        → Gets IP from Technicien pool (100-124)" -ForegroundColor Yellow
    Write-Host "  BIO-ANALYSIS01    → Gets IP from Biologiste pool (125-149)" -ForegroundColor Yellow

    Write-Host "`n💡 Next Steps:" -ForegroundColor Yellow
    Write-Host "  1. Create computer accounts in Active Directory with proper prefixes" -ForegroundColor Yellow
    Write-Host "  2. Join computers to domain (DOMLABO.LOCAL)" -ForegroundColor Yellow
    Write-Host "  3. Computers automatically receive IPs from their department pool" -ForegroundColor Yellow
    Write-Host "  4. Run Script 6 to create lab users & OUs" -ForegroundColor Yellow

}
catch {
    Write-Host "`n❌ ERROR: An error occurred during DHCP configuration:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
