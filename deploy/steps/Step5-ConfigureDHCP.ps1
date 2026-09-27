# ----------------------
# Step 5: Configure DHCP (non-interactive)
# Scope, exclusions, options, department policies, AD authorization.
# Auto-detects server IP/network/gateway. Exit: 0 = ok, 1 = error
# ----------------------
param(
    [string]$DomainName = "DOMLABO.LOCAL",
    [string]$ServerIP   = ""   # from config; blank = auto-detect
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 5: Configure DHCP server" "STEP"

$dhcp = Get-WindowsFeature -Name "DHCP" -ErrorAction SilentlyContinue
if (-not $dhcp.Installed) { Write-Log "DHCP Server is not installed." "ERROR"; exit 1 }

try {
    $net = Get-ServerNetworkInfo -PreferredIP $ServerIP
    if (-not $net) { Write-Log "Could not determine the server's IPv4 address." "ERROR"; exit 1 }
    $serverIP       = $net.IPAddress
    $defaultGateway = $net.Gateway

    $ipParts    = $serverIP -split '\.'
    $network    = "$($ipParts[0]).$($ipParts[1]).$($ipParts[2])"
    $subnetMask = "255.255.255.0"
    $scopeId    = "$network.0"

    $departments = @(
        @{ Name = "Accueil";     Prefix = "ACC-*";  Start = "$network.50";  End = "$network.74";  Description = "Reception / Accueil" },
        @{ Name = "Prelevement"; Prefix = "PREV-*"; Start = "$network.75";  End = "$network.99";  Description = "Sample Collection / Prelevement" },
        @{ Name = "Technicien";  Prefix = "TECH-*"; Start = "$network.100"; End = "$network.124"; Description = "Laboratory Technician / Technicien" },
        @{ Name = "Biologiste";  Prefix = "BIO-*";  Start = "$network.125"; End = "$network.149"; Description = "Biologist / Biologiste" }
    )

    Write-Log "Server IP $serverIP | Network $network.0/24 | Gateway $defaultGateway" "INFO"

    # Scope
    if (Get-DhcpServerv4Scope -ScopeId $scopeId -ErrorAction SilentlyContinue) {
        Write-Log "DHCP scope already exists: $scopeId" "OK"
    }
    else {
        Add-DhcpServerv4Scope -Name "$DomainName DHCP Scope" -StartRange "$network.50" -EndRange "$network.149" -SubnetMask $subnetMask -State Active -ErrorAction Stop
        Write-Log "DHCP scope created: $scopeId ($network.50 - $network.149)" "OK"
    }

    # Exclusions
    $exclusions = @(
        @{ Start = "$network.1";   End = "$network.49" },
        @{ Start = "$network.150"; End = "$network.249" },
        @{ Start = "$network.250"; End = "$network.254" }
    )
    foreach ($ex in $exclusions) {
        $existing = Get-DhcpServerv4ExclusionRange -ScopeId $scopeId -ErrorAction SilentlyContinue | Where-Object { $_.StartRange -eq $ex.Start }
        if (-not $existing) {
            Add-DhcpServerv4ExclusionRange -ScopeId $scopeId -StartRange $ex.Start -EndRange $ex.End -ErrorAction SilentlyContinue
        }
    }
    Write-Log "Exclusions configured (gateway, server, reserved ranges)." "OK"

    # Options
    Set-DhcpServerv4OptionValue -ScopeId $scopeId -OptionId 3  -Value $defaultGateway -ErrorAction Stop
    Set-DhcpServerv4OptionValue -ScopeId $scopeId -OptionId 6  -Value $serverIP       -ErrorAction Stop
    Set-DhcpServerv4OptionValue -ScopeId $scopeId -OptionId 15 -Value $DomainName      -ErrorAction Stop
    Write-Log "Options set - Gateway:$defaultGateway DNS:$serverIP Domain:$DomainName" "OK"

    # Lease duration (effectively permanent)
    Set-DhcpServerv4Scope -ScopeId $scopeId -LeaseDuration ([TimeSpan]'36500.00:00:00') -ErrorAction Stop
    Write-Log "Lease duration set to permanent." "OK"

    # Department policies
    $policyIndex = 1
    foreach ($dept in $departments) {
        if (Get-DhcpServerv4Policy -ScopeId $scopeId -Name "$($dept.Name) Policy" -ErrorAction SilentlyContinue) {
            Write-Log "Policy already exists: $($dept.Name)" "WARN"
        }
        else {
            try {
                Add-DhcpServerv4Policy -ScopeId $scopeId -Name "$($dept.Name) Policy" -Description $dept.Description -ProcessingOrder $policyIndex -Enabled $true -ErrorAction Stop
                Add-DhcpServerv4PolicyCondition -ScopeId $scopeId -PolicyName "$($dept.Name) Policy" -ConditionType HostName -Value $dept.Prefix -Operator Equal -ErrorAction Stop
                Set-DhcpServerv4PolicyIPRange -ScopeId $scopeId -PolicyName "$($dept.Name) Policy" -StartRange $dept.Start -EndRange $dept.End -ErrorAction Stop
                Write-Log "Policy created: $($dept.Name) ($($dept.Prefix) -> $($dept.Start)-$($dept.End))" "OK"
            }
            catch {
                Write-Log "Error creating policy $($dept.Name): $($_.Exception.Message)" "WARN"
            }
        }
        $policyIndex++
    }

    # Authorize in AD
    try {
        Add-DhcpServerInDC -DnsName "$env:COMPUTERNAME.$DomainName" -IPAddress $serverIP -ErrorAction SilentlyContinue
        Write-Log "DHCP server authorized in AD: $env:COMPUTERNAME.$DomainName ($serverIP)" "OK"
    }
    catch {
        Write-Log "Could not authorize DHCP server: $($_.Exception.Message)" "WARN"
    }

    Restart-Service -Name DHCPServer -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    Write-Log "DHCP configuration completed." "OK"
    exit 0
}
catch {
    Write-Log "Step 5 failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
