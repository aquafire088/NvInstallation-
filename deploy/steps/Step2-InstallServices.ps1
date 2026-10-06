# ----------------------
# Step 2: Install base server roles (non-interactive)
# .NET 3.5, AD DS, DNS, and the DHCP role only when config DHCP.InstallRole
# (or DHCP.Configure) is true. Configuring the scope is step 5.
# Exit codes: 0 = done (no reboot), 3010 = done (reboot required), 1 = error
# ----------------------
param(
    [bool]$InstallDHCP = $false
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 2: Install base services (AD DS, DNS$(if ($InstallDHCP) { ', DHCP' }), .NET 3.5)" "STEP"

try {
    Write-Log "Installing .NET Framework 3.5..." "INFO"
    $dotnet = Get-WindowsFeature -Name "NET-Framework-Core" -ErrorAction SilentlyContinue
    if ($dotnet.Installed) {
        Write-Log ".NET Framework 3.5 already installed." "OK"
    }
    else {
        try {
            Install-WindowsFeature -Name "NET-Framework-Core" -ErrorAction Stop | Out-Null
            Write-Log ".NET Framework 3.5 installed." "OK"
        }
        catch {
            Write-Log "Server Manager method failed, using DISM..." "WARN"
            if (-not (Invoke-Dism @('/online', '/enable-feature', '/featurename:NetFx3', '/All'))) {
                Write-Log ".NET Framework 3.5 could not be installed by either method." "ERROR"
                exit 1
            }
            Write-Log ".NET Framework 3.5 installed via DISM." "OK"
        }
    }

    Write-Log "Installing .NET Framework features..." "INFO"
    Install-WindowsFeature -Name "NET-Framework-Features" -ErrorAction SilentlyContinue | Out-Null

    Write-Log "Installing Active Directory Domain Services..." "INFO"
    Install-WindowsFeature -Name "AD-Domain-Services" -IncludeManagementTools -ErrorAction Stop | Out-Null
    Write-Log "AD DS installed." "OK"

    Write-Log "Installing DNS Server..." "INFO"
    Install-WindowsFeature -Name "DNS" -IncludeManagementTools -ErrorAction Stop | Out-Null
    Write-Log "DNS Server installed." "OK"

    if ($InstallDHCP) {
        Write-Log "Installing DHCP Server..." "INFO"
        Install-WindowsFeature -Name "DHCP" -IncludeManagementTools -ErrorAction Stop | Out-Null
        Write-Log "DHCP Server role installed (no scope yet: it hands out nothing until step 5 runs with DHCP.Configure=true)." "OK"
    }
    else {
        Write-Log "DHCP disabled in config; skipping the DHCP role." "INFO"
    }

    Write-Log "Base services installed successfully." "OK"
    exit 3010   # reboot to finalize role installation
}
catch {
    Write-Log "Step 2 failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
