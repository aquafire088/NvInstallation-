# NvInstallation Deployer

One-command, **unattended** build of the medical lab server: network → roles →
domain → DNS → DHCP → users → staged data → SQL → databases. The deployer
survives the reboots the early steps require and **resumes automatically** until
everything is finished.

## Quick start

1. **Copy and edit the config** — it holds every answer, so nothing prompts mid-run:

   ```powershell
   Copy-Item .\config.sample.json .\config.json
   notepad .\config.json
   ```

2. **Plug in the USB key** with the data folders (`Backup`, `Docs`, `SQL_DATA`,
   `Utilitaire`, …) and note its drive letter — it must match `Staging.SourceRoot`:

   ```powershell
   Get-Volume | Select-Object DriveLetter, FileSystemLabel, SizeRemaining
   ```

3. **Run once, elevated** (right-click PowerShell → *Run as Administrator*):

   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process -Force
   .\Deploy.ps1
   ```

4. **Walk away.** The server reboots as needed and continues on its own. When
   it's done, the log ends with `DEPLOYMENT COMPLETE`.

## How it works

- **`config.json`** — every value the steps need (IP, hostname, domain, passwords…).
  Read as UTF-8, so accented values (`[Français]`, French group names) survive.
- **`Deploy.ps1`** — the orchestrator. Reads the config, runs each step in order,
  records progress in **`state.json`**.
- **Reboot survival** — before running, it registers a Windows **Scheduled Task**
  running as `SYSTEM` at startup. After a step that needs a reboot, the machine
  restarts and the task relaunches `Deploy.ps1 -Resume`, which skips completed
  steps and continues. `SYSTEM` means **no auto-login or stored password** is
  needed — even after the admin account is renamed and the box becomes a DC.
  When all steps finish, the task removes itself.
- **Step contract** — each step exits `0` (done), `3010` (done, reboot first), or
  anything else (failed, deployment halts).
- **`deploy.log`** — full timestamped log of every step.

## The steps

| Id | Step | Reboots | Notes |
|----|------|---------|-------|
| 0-Update | Windows Update repair, DISM, .NET 3.5 | yes | Optional (`Options.RunTroubleshootUpdate`) |
| 1-Network | Static IP, rename PC + admin, RDP | yes | Renames the account last, then reboots |
| 2-Services | .NET 3.5, AD DS, DNS, DHCP roles | yes | DHCP role skipped when `DHCP.Enabled` is false |
| 3-Domain | Promote to Domain Controller | yes | New forest |
| 4-DNS | Forward + reverse zones, forwarders, routing | no | Waits for AD |
| 5-DHCP | Scope, exclusions, department policies | no | Optional (`DHCP.Enabled`) |
| 6-Users | Create OUs + lab users | no | Waits for AD |
| 7-Staging | robocopy USB → server disk, then SMB-share the folders | no | Copy: `Staging.Enabled`; shares: `FileShares.Enabled` |
| 8-SQL | Install SQL Server (+ optional SSMS) | no | Optional (`SQL.Install`) |
| 9-Database | Restore `.bak` files, run custom SQL, grant db_owner | no | Optional (`Database.Enabled`) |

Steps 7–9 are a chain: **7 stages the ISO and the `.bak` files onto local disk,
8 installs SQL from that staged ISO, 9 restores the databases.** Breaking step 7
breaks the two after it.

## Configuration reference (`config.json`)

| Section | Key | Meaning |
|---------|-----|---------|
| Network | Hostname | New computer name (≤15 chars) |
| Network | NewAdminUsername | Renames `administrateur` → this |
| Network | IPAddress / SubnetMask / Gateway | Static network config |
| Network | PrimaryDNS / SecondaryDNS | Leave PrimaryDNS blank to point the DC at itself |
| Domain | DomainName / NetbiosName | e.g. `DOMLABO.LOCAL` / `DOMLABO` |
| Domain | DSRMPassword | Blank → auto `Open@<year>*` |
| DNS | Forwarder1 / Forwarder2 | Upstream DNS (default Google) |
| DHCP | Enabled | `false` skips step 5 **and** the DHCP role in step 2 |
| Staging | Enabled | `false` skips the robocopy half of step 7 |
| Staging | SourceRoot / DestinationRoot | USB root → server disk root (e.g. `E:\` → `D:\`) |
| Staging | Folders | Copied `Source\<name>` → `Dest\<name>`; empty = every top-level folder |
| Staging | ExcludeFiles | robocopy `/XF` patterns, e.g. `["*.iso"]` |
| FileShares | Enabled / Items | Folders to create and SMB-share in step 7 |
| FileShares | Items[].FullAccess / ChangeAccess / ReadAccess | Domain groups; well-known ones are auto-corrected |
| SQL | Install | `true`/`false` to include step 8 |
| SQL | InstallFolder | Where the ISO lives **and** where SQL installs |
| SQL | DownloadUrl | Blank = install only from a staged ISO (no download) |
| SQL | InstanceName / DataFolder | e.g. `SQLEXPRESS`, `D:\SQL_DATA` |
| SQL | SAPassword | Blank → Windows-only auth |
| SQL | InstallSSMS / SSMSUrl | Management Studio, installed after the engine |
| Database | BackupFolder / DataFolder | Where `.bak` files are read / databases land |
| Database | Restores[] | `BakFile` → `DatabaseName`, one per database |
| Database | EnableMixedMode | Needed before any password-based SQL login works |
| Database | CustomSqlScript | Inline T-SQL or a `.sql` path; `GO` supported; run **verbatim** |
| Database | SqlLogin.Create | `false` when `CustomSqlScript` already creates the login |
| Database | SqlLogin.Name / DbOwnerOf | Login made `db_owner` of these databases |
| Options | RunTroubleshootUpdate | `true` to run step 0 first |
| Options | RebootDelaySeconds | Countdown before each planned reboot |

## How SQL gets its ISO (step 8)

In order:

1. `InstallFolder\SQL_Server_Install.iso`
2. **any** `.iso` over 300 MB in `InstallFolder` — so an ISO copied off the USB
   key works whatever it's named
3. download from `DownloadUrl` — and if that's blank, the step stops immediately
   with a clear message instead of a parameter error

Before the long operations it pre-flights the sysadmin account (must resolve to a
SID) and free disk space, so a bad domain or path fails in seconds rather than
20 minutes in.

> If `Staging.ExcludeFiles` contains `"*.iso"`, the ISO never reaches the server
> and step 8 stops with *No SQL ISO found*. Either drop the exclusion or put the
> ISO in `SQL.InstallFolder` by hand.

## Database restore order (step 9)

1. Restore each `Restores[]` entry, relocating data/log files to `DataFolder`
   (existing databases are left alone)
2. Set Mixed-Mode, **restart SQL**, and wait until it really accepts connections
3. Run `CustomSqlScript` verbatim — nothing is appended to it
4. Create `SqlLogin` only if `Create` is `true`
5. Grant `db_owner` on `DbOwnerOf` — independent of step 4, so a login created by
   your own script still gets ownership

`CustomSqlScript` is not automatically re-runnable: a bare `CREATE LOGIN` fails
on a second run. Guard it with `IF NOT EXISTS` if you expect to re-run step 9.

## Commands

```powershell
.\Deploy.ps1                 # start (or resume) the deployment
.\Deploy.ps1 -Config x.json  # use an alternate config file
.\Deploy.ps1 -Reset          # clear saved state + resume task (start over)

Get-Content .\deploy.log -Tail 40   # recent log
Get-Content .\deploy.log -Wait      # live-follow the log
Get-Content .\state.json            # which steps are done
Get-ScheduledTask -TaskName "NvInstallation-Resume"   # is auto-resume armed?
.\Test-Common.ps1                   # self-check: state survives reboots
```

Verify afterwards:

```powershell
Get-Service 'MSSQL$SQLEXPRESS'
sqlcmd -S ".\SQLEXPRESS" -E -Q "SELECT name FROM sys.databases"
Get-SmbShare
(Get-ADDomain).NetBIOSName
```

## Running one step on its own

Step scripts take plain parameters, so you can re-run just one for testing:

```powershell
.\steps\Step4-ConfigureDNS.ps1 -DomainName "DOMLABO.LOCAL" -ServerIP "192.168.1.250"

.\steps\Step8-InstallSQL.ps1 `
  -InstallFolder "D:\Utilitaire\software\sql" -InstanceName "SQLEXPRESS" `
  -DomainName "DOMLABO.LOCAL" -AdminAccount "adcipro" -InstallSSMS $true
```

(Engine already installed and healthy? Step 8 skips it and just installs SSMS.
A registered but broken instance is uninstalled and reinstalled cleanly.)

## Resuming after a failure

The deployer stops and logs the reason. Fix the cause, then run `.\Deploy.ps1`
again — it skips completed steps and retries the failed one.

**Changing step Ids invalidates `state.json`.** If steps are renamed or
renumbered, run `.\Deploy.ps1 -Reset` before the next run, or completed steps
will run again.

## Notes / safety

- `config.json`, `state.json`, and `deploy.log` are git-ignored (the config holds passwords).
- Step 6 creates lab users **with no password** (`PasswordNotRequired`). Fine for
  an isolated lab, not acceptable on a routable network.
- Test on a VM snapshot first: steps 1–3 are irreversible (rename, DC promotion).
