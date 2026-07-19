# ----------------------
# Script: Configure Active Directory Domain
# Purpose: Promote server to Domain Controller and configure domain
# ----------------------

# Check if running as Administrator
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] ERROR: This script must be run as Administrator!" -ForegroundColor Red
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Active Directory Domain Configuration" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Check if AD DS is installed
$addsStatus = Get-WindowsFeature -Name "AD-Domain-Services" -ErrorAction SilentlyContinue
if (-not $addsStatus.Installed) {
    Write-Host "[ERROR] ERROR: AD DS is not installed!" -ForegroundColor Red
    Write-Host "   Please run Script 2 first to install services." -ForegroundColor Red
    exit 1
}

# Set default parameters
$domainName = "DOMLABO.LOCAL"
$netbiosName = "DOMLABO"
$currentYear = (Get-Date).Year
$dsrmPasswordPlain = "Open@$currentYear*"
$dsrmPassword = ConvertTo-SecureString $dsrmPasswordPlain -AsPlainText -Force
$forestLevel = "Win2012R2"
$domainLevel = "Win2012R2"

Write-Host "`nDomain Configuration:" -ForegroundColor Yellow
Write-Host "Domain Name:               $domainName" -ForegroundColor Cyan
Write-Host "NetBIOS Name:              $netbiosName" -ForegroundColor Cyan
Write-Host "DSRM Password:             Open@{CurrentYear}* (Open@$currentYear*)" -ForegroundColor Cyan
Write-Host "Forest Functional Level:   2012 R2 (compatible)" -ForegroundColor Cyan
Write-Host "Domain Functional Level:   2012 R2 (compatible)" -ForegroundColor Cyan

# Display summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Summary - Ready to Configure Domain" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Domain Name:               $domainName" -ForegroundColor White
Write-Host "NetBIOS Name:              $netbiosName" -ForegroundColor White
Write-Host "Server Name:               $env:COMPUTERNAME" -ForegroundColor White
Write-Host "Forest Type:               New Forest (will be created)" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan

# Confirmation
$confirm = Read-Host "`nProceed with domain creation? This will restart the server. (Y/N)"
if ($confirm -ne "Y" -and $confirm -ne "y") {
    Write-Host "[ERROR] Configuration cancelled." -ForegroundColor Yellow
    exit 0
}

Write-Host "`n[WAIT] Starting domain configuration..." -ForegroundColor Yellow

try {
    # Step 1: Install AD DS Deployment Module
    Write-Host "`nStep 1: Loading AD Deployment Module..." -ForegroundColor Cyan
    Import-Module ADDSDeployment -ErrorAction Stop
    Write-Host "[OK] AD Deployment Module loaded" -ForegroundColor Green

    # Step 2: Promote to Domain Controller
    Write-Host "`nStep 2: Promoting server to Domain Controller..." -ForegroundColor Cyan
    Write-Host "   This may take several minutes..." -ForegroundColor Gray

    Install-ADDSForest `
        -DomainName $domainName `
        -SafeModeAdministratorPassword $dsrmPassword `
        -DomainNetbiosName $netbiosName `
        -ForestMode $forestLevel `
        -DomainMode $domainLevel `
        -InstallDns:$true `
        -CreateDnsDelegation:$false `
        -NoRebootOnCompletion:$false `
        -Force `
        -ErrorAction Stop

    Write-Host "[OK] Domain Controller promotion initiated" -ForegroundColor Green

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "[OK] Domain configuration completed!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    Write-Host "`nDomain Information:" -ForegroundColor Cyan
    Write-Host "  Domain:      $domainName" -ForegroundColor Green
    Write-Host "  NetBIOS:     $netbiosName" -ForegroundColor Green
    Write-Host "  DC Name:     $env:COMPUTERNAME" -ForegroundColor Green
    Write-Host "  DNS:         Installed and Configured" -ForegroundColor Green

    Write-Host "`nIMPORTANT: Server is restarting..." -ForegroundColor Yellow
    Write-Host "  After restart, log in with: $netbiosName\Adcipro" -ForegroundColor Yellow
    Write-Host "  Password: Open@$currentYear*" -ForegroundColor Yellow

}
catch {
    Write-Host "`n ERROR: An error occurred during domain configuration:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "`nPlease review the error and try again." -ForegroundColor Yellow
    exit 1
}
