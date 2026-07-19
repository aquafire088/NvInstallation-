# ----------------------
# Script: Troubleshoot Windows Update Issues (Built-in Tools Only)
# Purpose: Fix error 0x8024402c and prepare for role installation
# ----------------------

# Check if running as Administrator
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)

if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERROR] ERROR: This script must be run as Administrator!" -ForegroundColor Red
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Windows Update Troubleshooting" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`n[WARNING]  This will fix Windows Update and DISM issues" -ForegroundColor Yellow
Write-Host "   Estimated time: 20-30 minutes" -ForegroundColor Yellow

$confirm = Read-Host "`nContinue? (Y/N)"
if ($confirm -ne "Y" -and $confirm -ne "y") {
    Write-Host "[ERROR] Cancelled." -ForegroundColor Yellow
    exit 0
}

try {
    # Step 1: Stop Windows Update services
    Write-Host "`nStep 1: Stopping Windows Update services..." -ForegroundColor Cyan
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "bits" -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "msiserver" -Force -ErrorAction SilentlyContinue
    Write-Host "[OK] Services stopped" -ForegroundColor Green

    # Step 2: Clear Windows Update cache
    Write-Host "`nStep 2: Clearing Windows Update cache..." -ForegroundColor Cyan
    $updatePath = "C:\Windows\SoftwareDistribution\Download"

    if (Test-Path $updatePath) {
        Remove-Item -Path $updatePath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] Cache cleared" -ForegroundColor Green
    }

    # Step 3: Restart services
    Write-Host "`nStep 3: Restarting Windows Update services..." -ForegroundColor Cyan
    Start-Service -Name wuauserv -ErrorAction SilentlyContinue
    Start-Service -Name "bits" -ErrorAction SilentlyContinue
    Start-Service -Name "msiserver" -ErrorAction SilentlyContinue
    Write-Host "[OK] Services restarted" -ForegroundColor Green

    # Step 4: Run DISM repair
    Write-Host "`nStep 4: Running DISM repair (this takes 10-15 minutes)..." -ForegroundColor Cyan
    Write-Host "[WAIT] Please wait..." -ForegroundColor Yellow

    $dismOutput = dism.exe /online /cleanup-image /restorehealth
    Write-Host "[OK] DISM repair completed" -ForegroundColor Green

    # Step 5: Enable .NET Framework 3.5
    Write-Host "`nStep 5: Enabling .NET Framework 3.5 with DISM..." -ForegroundColor Cyan
    Write-Host "[WAIT] Please wait..." -ForegroundColor Yellow

    $dismNetOutput = dism.exe /online /enable-feature /featurename:NetFx3 /All
    Write-Host "[OK] .NET Framework 3.5 enabled" -ForegroundColor Green

    # Step 6: Enable Update Orchestrator
    Write-Host "`nStep 6: Enabling Update Orchestrator Service..." -ForegroundColor Cyan
    $updateService = Get-Service -Name "usosvc" -ErrorAction SilentlyContinue
    if ($updateService) {
        Start-Service -Name "usosvc" -ErrorAction SilentlyContinue
        Set-Service -Name "usosvc" -StartupType Automatic -ErrorAction SilentlyContinue
        Write-Host "[OK] Update Orchestrator service configured" -ForegroundColor Green
    }

    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "[OK] Troubleshooting completed successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    Write-Host "`n[NOTE] Next Steps:" -ForegroundColor Yellow
    Write-Host "  1. Restart the server to apply changes:" -ForegroundColor Yellow
    Write-Host "     Restart-Computer -Force" -ForegroundColor Cyan
    Write-Host "`n  2. After restart, run Script 2 again:" -ForegroundColor Yellow
    Write-Host "     .\serveur\2-Install_Services_Base.ps1" -ForegroundColor Cyan

    Write-Host "`n[QUESTION] Ready to restart now? (Y/N)"
    $restartNow = Read-Host
    if ($restartNow -eq "Y" -or $restartNow -eq "y") {
        Write-Host "`n[WAIT] Restarting in 30 seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
        Restart-Computer -Force
    }
    else {
        Write-Host "`n[WARNING]  Remember to restart the server manually before running Script 2" -ForegroundColor Yellow
    }

}
catch {
    Write-Host "`n[ERROR] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
