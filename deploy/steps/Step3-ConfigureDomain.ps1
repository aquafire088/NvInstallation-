# ----------------------
# Step 3: Promote server to Domain Controller (non-interactive)
# Creates a new forest. Uses -NoRebootOnCompletion so the ORCHESTRATOR
# controls the reboot (keeps state consistent).
# Exit codes: 0 = done (no reboot), 3010 = done (reboot required), 1 = error
# ----------------------
param(
    [Parameter(Mandatory)] [string]$DomainName,
    [Parameter(Mandatory)] [string]$NetbiosName,
    [Parameter(Mandatory)] [string]$DSRMPassword,
    [string]$ForestLevel = "Win2012R2",
    [string]$DomainLevel = "Win2012R2"
)
. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\Common.ps1")

Assert-Administrator
Write-Log "STEP 3: Promote to Domain Controller ($DomainName)" "STEP"

$adds = Get-WindowsFeature -Name "AD-Domain-Services" -ErrorAction SilentlyContinue
if (-not $adds.Installed) {
    Write-Log "AD DS is not installed. Run Step 2 first." "ERROR"
    exit 1
}

try {
    Import-Module ADDSDeployment -ErrorAction Stop
    $securePwd = ConvertTo-SecureString $DSRMPassword -AsPlainText -Force

    Write-Log "Promoting to Domain Controller (this may take several minutes)..." "INFO"
    Install-ADDSForest `
        -DomainName $DomainName `
        -SafeModeAdministratorPassword $securePwd `
        -DomainNetbiosName $NetbiosName `
        -ForestMode $ForestLevel `
        -DomainMode $DomainLevel `
        -InstallDns:$true `
        -CreateDnsDelegation:$false `
        -NoRebootOnCompletion:$true `
        -Force `
        -ErrorAction Stop | Out-Null

    Write-Log "Domain Controller promotion completed. NetBIOS: $NetbiosName" "OK"
    exit 3010   # reboot required to bring the DC online
}
catch {
    Write-Log "Step 3 failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
