# ----------------------
# Step 0: Troubleshoot Windows Update (non-interactive)
# Fixes error 0x8024402c, repairs image, enables .NET 3.5.
# Exit codes: 0 = done (no reboot), 3010 = done (reboot required), 1 = error
# ----------------------
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 0: Windows Update troubleshooting" "STEP"

try {
    Write-Log "Stopping Windows Update services..." "INFO"
    Stop-Service -Name wuauserv   -Force -ErrorAction SilentlyContinue
    Stop-Service -Name bits       -Force -ErrorAction SilentlyContinue
    Stop-Service -Name msiserver  -Force -ErrorAction SilentlyContinue

    Write-Log "Clearing Windows Update cache..." "INFO"
    $updatePath = "C:\Windows\SoftwareDistribution\Download"
    if (Test-Path $updatePath) {
        Remove-Item -Path $updatePath -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Restarting Windows Update services..." "INFO"
    Start-Service -Name wuauserv  -ErrorAction SilentlyContinue
    Start-Service -Name bits      -ErrorAction SilentlyContinue
    Start-Service -Name msiserver -ErrorAction SilentlyContinue

    Write-Log "Running DISM /RestoreHealth (10-15 min)..." "INFO"
    if (-not (Invoke-Dism @('/online', '/cleanup-image', '/restorehealth'))) { exit 1 }

    Write-Log "Enabling .NET Framework 3.5 (NetFx3)..." "INFO"
    if (-not (Invoke-Dism @('/online', '/enable-feature', '/featurename:NetFx3', '/All'))) { exit 1 }

    Write-Log "Configuring Update Orchestrator service..." "INFO"
    if (Get-Service -Name usosvc -ErrorAction SilentlyContinue) {
        Start-Service -Name usosvc -ErrorAction SilentlyContinue
        Set-Service   -Name usosvc -StartupType Automatic -ErrorAction SilentlyContinue
    }

    Write-Log "Windows Update troubleshooting completed." "OK"
    exit 3010   # reboot recommended after DISM / NetFx3
}
catch {
    Write-Log "Step 0 failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
