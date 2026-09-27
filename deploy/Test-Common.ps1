# ----------------------
# Self-check for the state round-trip in lib\Common.ps1.
# Runs anywhere (no server needed):  .\Test-Common.ps1
# Guards the bug where ConvertTo-Json collapsed a 1-element CompletedSteps
# array to a string, so += concatenated and every step re-ran (reboot loop).
# ----------------------
. (Join-Path $PSScriptRoot "lib\Common.ps1")

# Redirect state + log at temp files so the real deployment state is untouched.
$script:StateFile = Join-Path $env:TEMP "nvinst-test-state.json"
$script:LogFile   = Join-Path $env:TEMP "nvinst-test.log"
Remove-Item $script:StateFile, $script:LogFile -ErrorAction SilentlyContinue

$s = Get-DeployState
Set-StepDone -State $s -StepId "0-Update"

# Reload from disk - this is where the single-element array used to collapse.
$s2 = Get-DeployState
if (-not (Test-StepDone -State $s2 -StepId "0-Update")) { throw "FAIL: step lost after one-element round-trip" }

Set-StepDone -State $s2 -StepId "1-Network"
$s3 = Get-DeployState
foreach ($id in "0-Update", "1-Network") {
    if (-not (Test-StepDone -State $s3 -StepId $id)) { throw "FAIL: '$id' missing after second round-trip" }
}
if (@($s3.CompletedSteps).Count -ne 2) { throw "FAIL: expected 2 completed steps, got $(@($s3.CompletedSteps).Count)" }

Remove-Item $script:StateFile, $script:LogFile -ErrorAction SilentlyContinue
Write-Host "PASS: state round-trip is stable across reboots." -ForegroundColor Green
