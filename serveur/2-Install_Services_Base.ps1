# ----------------------
# Script: Install Base Services (AD DS, DNS, DHCP, .NET Framework)
# Purpose: Install required server roles without configuration
# ----------------------

# Check if running as Administrator
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "❌ ERROR: This script must be run as Administrator!" -ForegroundColor Red
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Installing Base Server Services" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$confirm = Read-Host "`nInstall base services? (Y/N)"
if ($confirm -ne "Y" -and $confirm -ne "y") {
    Write-Host "❌ Installation cancelled." -ForegroundColor Yellow
    exit 0
}

Write-Host "`n⏳ Starting installation..." -ForegroundColor Yellow

try {
    # Step 1: Install .NET Framework 3.5
    Write-Host "`nStep 1: Installing .NET Framework 3.5..." -ForegroundColor Cyan
    $dotnetStatus = Get-WindowsFeature -Name "NET-Framework-Core" -ErrorAction SilentlyContinue

    if ($dotnetStatus.Installed) {
        Write-Host "✅ .NET Framework 3.5 already installed" -ForegroundColor Green
    }
    else {
        Install-WindowsFeature -Name "NET-Framework-Core" -ErrorAction Stop
        Write-Host "✅ .NET Framework 3.5 installed" -ForegroundColor Green
    }

    # Step 2: Install NET Framework Features
    Write-Host "`nStep 2: Installing .NET Framework Features..." -ForegroundColor Cyan
    Install-WindowsFeature -Name "NET-Framework-Features" -ErrorAction SilentlyContinue
    Write-Host "✅ .NET Framework Features installed" -ForegroundColor Green

    # Step 3: Install AD DS
    Write-Host "`nStep 3: Installing Active Directory Domain Services..." -ForegroundColor Cyan
    Install-WindowsFeature -Name "AD-Domain-Services" -IncludeManagementTools -ErrorAction Stop
    Write-Host "✅ AD DS installed" -ForegroundColor Green

    # Step 4: Install DNS
    Write-Host "`nStep 4: Installing DNS Server..." -ForegroundColor Cyan
    Install-WindowsFeature -Name "DNS" -IncludeManagementTools -ErrorAction Stop
    Write-Host "✅ DNS Server installed" -ForegroundColor Green

    # Step 5: Install DHCP
    Write-Host "`nStep 5: Installing DHCP Server..." -ForegroundColor Cyan
    Install-WindowsFeature -Name "DHCP" -IncludeManagementTools -ErrorAction Stop
    Write-Host "✅ DHCP Server installed" -ForegroundColor Green

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "✅ Base services installed successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    Write-Host "`n📋 Installed Components:" -ForegroundColor Cyan
    Write-Host "  ✓ .NET Framework 3.5" -ForegroundColor Green
    Write-Host "  ✓ .NET Framework Features" -ForegroundColor Green
    Write-Host "  ✓ Active Directory Domain Services" -ForegroundColor Green
    Write-Host "  ✓ DNS Server" -ForegroundColor Green
    Write-Host "  ✓ DHCP Server" -ForegroundColor Green

    Write-Host "`n💡 Next Steps:" -ForegroundColor Yellow
    Write-Host "  1. Configure AD DS (Domain promotion)" -ForegroundColor Yellow
    Write-Host "  2. Configure DNS zones" -ForegroundColor Yellow
    Write-Host "  3. Configure DHCP scopes" -ForegroundColor Yellow

    Write-Host "`n⏳ Restarting server in 30 seconds... (Press Ctrl+C to cancel)" -ForegroundColor Yellow

    Start-Sleep -Seconds 30
    Restart-Computer -Force

}
catch {
    Write-Host "`n❌ ERROR: An error occurred during installation:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
