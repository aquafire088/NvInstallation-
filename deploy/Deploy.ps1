<#
============================================================
  NvInstallation - Unattended Medical Lab Server Deployer
============================================================
  Runs the full server build (network -> roles -> domain ->
  DNS -> DHCP -> users -> SQL) from config.json, surviving the
  reboots that steps 0-3 require.

  USAGE:
    1. Edit config.json (copy from config.sample.json).
    2. Open an elevated PowerShell in this folder and run:
         Set-ExecutionPolicy Bypass -Scope Process -Force
         .\Deploy.ps1
    3. Walk away. The server reboots as needed and resumes
       automatically until deployment completes.

  -Resume  : internal; used by the auto-resume scheduled task.
  -Config  : path to the config file (default: .\config.json).
  -Reset   : clears saved state and the resume task, then exits.
============================================================
#>
[CmdletBinding()]
param(
    [switch]$Resume,
    [switch]$Reset,
    [string]$Config = (Join-Path $PSScriptRoot "config.json")
)

. (Join-Path $PSScriptRoot "lib\Common.ps1")

$ThisScript = $MyInvocation.MyCommand.Path
$StepsDir   = Join-Path $PSScriptRoot "steps"

# --- Reset mode ---------------------------------------------
if ($Reset) {
    Unregister-ResumeTask
    if (Test-Path $script:StateFile) { Remove-Item $script:StateFile -Force }
    Write-Log "State and resume task cleared." "OK"
    exit 0
}

Assert-Administrator
$cfg   = Import-DeployConfig -Path $Config
$state = Get-DeployState

Write-Log "==================================================" "STEP"
Write-Log ("Deployment {0} (host: {1})" -f $(if ($Resume) { "RESUME" } else { "START" }), $env:COMPUTERNAME) "STEP"
Write-Log "==================================================" "STEP"

# ============================================================
# Step plan. Each entry: Id, friendly name, script, arg builder,
# and whether AD must be ready before it runs.
# ============================================================

# FileShares (step 8) config may be absent in older configs - guard it.
$fileSharesEnabled  = [bool]($cfg.FileShares -and $cfg.FileShares.Enabled)
$fileShareItemsJson = if ($cfg.FileShares -and $cfg.FileShares.Items) {
    @($cfg.FileShares.Items) | ConvertTo-Json -Depth 8
} else { "[]" }

# DHCP (steps 2 + 5) is optional; absent config means enabled (old behaviour).
$dhcpEnabled = if ($null -ne $cfg.DHCP -and $null -ne $cfg.DHCP.Enabled) { [bool]$cfg.DHCP.Enabled } else { $true }

# Staging (step 7) copies the USB key onto the server disk before SQL needs it.
$stagingEnabled = [bool]($cfg.Staging -and $cfg.Staging.Enabled)
$stagingFoldersJson = if ($cfg.Staging -and $cfg.Staging.Folders) {
    @($cfg.Staging.Folders) | ConvertTo-Json -Depth 4
} else { "[]" }
$stagingExcludesJson = if ($cfg.Staging -and $cfg.Staging.ExcludeFiles) {
    @($cfg.Staging.ExcludeFiles) | ConvertTo-Json -Depth 4
} else { "[]" }

# Database (step 9) config may be absent in older configs - guard it.
$databaseEnabled = [bool]($cfg.Database -and $cfg.Database.Enabled)
$databaseJson    = if ($cfg.Database) { $cfg.Database | ConvertTo-Json -Depth 8 } else { "{}" }

$plan = @(
    @{
        Id = "0-Update"; Name = "Windows Update troubleshooting"
        Enabled = [bool]$cfg.Options.RunTroubleshootUpdate
        Script = "Step0-TroubleshootUpdate.ps1"; RequiresAD = $false
        Args = @{}
    },
    @{
        Id = "1-Network"; Name = "Network / Hostname / RDP"; Enabled = $true
        Script = "Step1-Network.ps1"; RequiresAD = $false
        Args = @{
            Hostname         = $cfg.Network.Hostname
            NewAdminUsername = $cfg.Network.NewAdminUsername
            IPAddress        = $cfg.Network.IPAddress
            SubnetMask       = $cfg.Network.SubnetMask
            Gateway          = $cfg.Network.Gateway
            PrimaryDNS       = $cfg.Network.PrimaryDNS
            SecondaryDNS     = $cfg.Network.SecondaryDNS
            AdapterName      = $cfg.Network.AdapterName
        }
    },
    @{
        Id = "2-Services"; Name = "Install base roles"; Enabled = $true
        Script = "Step2-InstallServices.ps1"; RequiresAD = $false
        Args = @{ InstallDHCP = $dhcpEnabled }
    },
    @{
        Id = "3-Domain"; Name = "Promote to Domain Controller"; Enabled = $true
        Script = "Step3-ConfigureDomain.ps1"; RequiresAD = $false
        Args = @{
            DomainName   = $cfg.Domain.DomainName
            NetbiosName  = $cfg.Domain.NetbiosName
            DSRMPassword = $cfg.Domain.DSRMPassword
        }
    },
    @{
        Id = "4-DNS"; Name = "Configure DNS"; Enabled = $true
        Script = "Step4-ConfigureDNS.ps1"; RequiresAD = $true
        Args = @{
            DomainName = $cfg.Domain.DomainName
            Forwarder1 = $cfg.DNS.Forwarder1
            Forwarder2 = $cfg.DNS.Forwarder2
            ServerIP   = $cfg.Network.IPAddress
        }
    },
    @{
        Id = "5-DHCP"; Name = "Configure DHCP"; Enabled = $dhcpEnabled
        Script = "Step5-ConfigureDHCP.ps1"; RequiresAD = $true
        Args = @{ DomainName = $cfg.Domain.DomainName; ServerIP = $cfg.Network.IPAddress }
    },
    @{
        Id = "6-Users"; Name = "Create lab OUs & users"; Enabled = $true
        Script = "Step6-LabUsers.ps1"; RequiresAD = $true
        Args = @{ DomainName = $cfg.Domain.DomainName }
    },
    @{
        Id = "7-Staging"; Name = "Stage data from USB, then share it"
        # Runs if either half is wanted; RequiresAD because share ACLs name domain groups.
        Enabled = ($stagingEnabled -or $fileSharesEnabled)
        Script = "Step7-StageAndShare.ps1"; RequiresAD = $true
        Args = @{
            StageEnabled     = $stagingEnabled
            SourceRoot       = $(if ($cfg.Staging) { $cfg.Staging.SourceRoot } else { "" })
            DestinationRoot  = $(if ($cfg.Staging) { $cfg.Staging.DestinationRoot } else { "" })
            FoldersJson      = $stagingFoldersJson
            ExcludeFilesJson = $stagingExcludesJson
            ItemsJson        = $(if ($fileSharesEnabled) { $fileShareItemsJson } else { "[]" })
            ApplyNtfs        = $(if ($null -ne $cfg.FileShares -and $null -ne $cfg.FileShares.ApplyNtfs) { [bool]$cfg.FileShares.ApplyNtfs } else { $true })
        }
    },
    @{
        Id = "8-SQL"; Name = "Install SQL Server"
        Enabled = [bool]$cfg.SQL.Install
        Script = "Step8-InstallSQL.ps1"; RequiresAD = $true
        Args = @{
            DownloadUrl   = $cfg.SQL.DownloadUrl
            InstallFolder = $cfg.SQL.InstallFolder
            InstanceName  = $cfg.SQL.InstanceName
            DomainName    = $cfg.Domain.DomainName
            AdminAccount  = $cfg.Network.NewAdminUsername
            SAPassword    = $cfg.SQL.SAPassword
            DataFolder    = $cfg.SQL.DataFolder
            InstallSSMS   = [bool]$cfg.SQL.InstallSSMS
            SSMSUrl       = $cfg.SQL.SSMSUrl
        }
    },
    @{
        Id = "9-Database"; Name = "Restore databases & SQL users"
        Enabled = $databaseEnabled
        Script = "Step9-Database.ps1"; RequiresAD = $false
        Args = @{ ConfigJson = $databaseJson }
    }
)

# Make sure we come back after any reboot.
Register-ResumeTask -DeployScript $ThisScript -ConfigPath $Config

# ============================================================
# Run the plan
# ============================================================
foreach ($step in $plan) {

    if (-not $step.Enabled) {
        Write-Log "SKIP $($step.Id) ($($step.Name)) - disabled in config." "INFO"
        continue
    }
    if (Test-StepDone -State $state -StepId $step.Id) {
        Write-Log "SKIP $($step.Id) ($($step.Name)) - already completed." "INFO"
        continue
    }

    if ($step.RequiresAD) {
        if (-not (Wait-ForADReady)) {
            Write-Log "Aborting: Active Directory not available for $($step.Id)." "ERROR"
            exit 1
        }
    }

    $scriptPath = Join-Path $StepsDir $step.Script
    if (-not (Test-Path $scriptPath)) {
        Write-Log "Step script missing: $scriptPath" "ERROR"
        exit 1
    }

    Write-Log ">>> Running $($step.Id): $($step.Name)" "STEP"
    # Splat the step's parameters. The child dot-sources Common.ps1 and
    # writes to the same log file, so its output is captured there too.
    $stepArgs = @{}
    foreach ($k in $step.Args.Keys) { $stepArgs[$k] = $step.Args[$k] }
    # Seed the exit code: if the child dies before reaching an `exit` (bad
    # parameter, parse error), $LASTEXITCODE keeps the PREVIOUS step's 0 and
    # the failure is recorded as success.
    $global:LASTEXITCODE = 1
    & $scriptPath @stepArgs
    $code = $LASTEXITCODE

    switch ($code) {
        0 {
            Set-StepDone -State $state -StepId $step.Id
            Write-Log "<<< $($step.Id) completed." "OK"
        }
        3010 {
            Set-StepDone -State $state -StepId $step.Id
            Write-Log "<<< $($step.Id) completed; reboot required." "OK"
            Invoke-PlannedReboot -DelaySeconds ([int]$cfg.Options.RebootDelaySeconds)
            # (process ends here; resume task continues after boot)
        }
        default {
            Write-Log "<<< $($step.Id) FAILED (exit $code). Deployment halted." "ERROR"
            Write-Log "Fix the issue and re-run .\Deploy.ps1 to resume from this step." "WARN"
            exit $code
        }
    }
}

# ============================================================
# Done
# ============================================================
Unregister-ResumeTask
Write-Log "==================================================" "OK"
Write-Log "DEPLOYMENT COMPLETE - all steps finished." "OK"
Write-Log "Domain: $($cfg.Domain.DomainName) | Login: $($cfg.Domain.NetbiosName)\$($cfg.Network.NewAdminUsername)" "OK"
Write-Log "==================================================" "OK"
exit 0
