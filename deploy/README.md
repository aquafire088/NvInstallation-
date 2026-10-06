# NvInstallation Deployer

One-command, **unattended** build of the medical lab server: network → roles →
domain → DNS → DHCP → users → staged data → SQL → databases. The deployer
survives the reboots the early steps require and **resumes automatically** until
everything is finished.

## Quick start

> **Prefer a window?** Double-click **`Console-Serveur.cmd`**. It edits
> `config.json` (fields, checkboxes, tables, FR/EN), starts or resumes the
> deployment with a live step list and log, and after deployment gives an
> *Administration* tab: read a workstation's LAPS password, add / disable /
> unlock users, reset passwords. Everything below is what it does for you.


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
| 1-Network | Static IP, IPv6 off, rename PC + admin, RDP | yes | Renames the account last, then reboots |
| 2-Services | .NET 3.5, AD DS, DNS, DHCP role | yes | DHCP role only when `DHCP.InstallRole` (or `Configure`) is true |
| 3-Domain | Promote to Domain Controller | yes | New forest, functional level 2016 |
| 4-DNS | AD-integrated forward + reverse zones, forwarders, server DNS → `127.0.0.1` | no | Waits for AD |
| 5-DHCP | Scope, exclusions, department policies | no | Optional (`DHCP.Configure`, **off** by default) |
| 6-Structure | OUs `Utilisateurs` (+ one sub-OU per role), `Groupes`, `Administrateurs`, `Postes` (+ `ComputerSubOUs`, e.g. `Technicien`); new computers default to `Postes` | no | Waits for AD |
| 7-Groups | `GG-<Role>` + `GG-PC-Admins` security groups in `OU Groupes`; `ExtraGroups[].Members` added (`GG-PC-Admins` = `adcipro`) | no | |
| 8-Users | Users in their role OU + role group; initial password, change at logon (or own `Password`, no change) | no | `Directory.InitialPassword` |
| 9-Admins | `ad-sama` in `OU Administrateurs` → Domain Admins + `GG-PC-Admins`; built-in Administrator untouched | no | Optional (`Directory.DomainAdmin.Enabled`, **off**: `adcipro` is the only domain admin) |
| 10-GPO | Password + lockout policy (Default Domain Policy); GPOs *Postes-Partages* and *Postes-AdminsLocaux* on `OU Postes`, *Postes-Techniciens* (never lock/sleep) on `Postes\Technicien`; Remote Desktop to the DC for named users | no | Each part optional (`Policy.*.Enabled`) |
| 11-LAPS | Windows LAPS: schema, OU Postes permissions, GPO *Postes-LAPS* managing `admin-sama`; keeps `admin-sama` in the local-admins GPO | no | Optional (`LAPS.Enabled`, **off**) |
| 12-Staging | robocopy USB → server disk, then SMB-share the folders | no | Copy: `Staging.Enabled`; shares: `FileShares.Enabled` |
| 13-SQL | Install SQL Server (+ optional SSMS) | no | Optional (`SQL.Install`) |
| 14-Database | Restore `.bak` files, run custom SQL, grant db_owner | no | Optional (`Database.Enabled`) |

Read a workstation's rescue password: `Get-LapsADPassword -Identity TECH-01 -AsPlainText`.

Steps 12–14 are a chain: **12 stages the ISO and the `.bak` files onto local disk,
13 installs SQL from that staged ISO, 14 restores the databases.** Breaking step 12
breaks the two after it.

## Configuration reference (`config.json`)

| Section | Key | Meaning |
|---------|-----|---------|
| Network | Hostname | New computer name (≤15 chars) |
| Network | NewAdminUsername | Renames `administrateur` → this |
| Network | IPAddress / SubnetMask / Gateway | Static network config |
| Network | PrimaryDNS / SecondaryDNS | DNS used during steps 1–3; leave PrimaryDNS blank to point at the server's own IP |
| Network | DisableIPv6 | Default `true`: unbind IPv6 + `DisabledComponents=0xFF` |
| Domain | DomainName / NetbiosName | e.g. `DOMLABO.LOCAL` / `DOMLABO` |
| Domain | DSRMPassword | Blank → auto `Open@<year>*` |
| DNS | Forwarders | Upstream DNS list, e.g. `["8.8.8.8","8.8.4.4","1.1.1.1"]` (old `Forwarder1/2` still read) |
| DNS | SecondaryDNS | Second resolver for the server after step 4 (DC02's IP); preferred is always `127.0.0.1` |
| Directory | OUs | Names of the four functional OUs (keep the defaults) |
| Directory | Roles[] | `Name` (sub-OU under Utilisateurs) + `Group` (e.g. `GG-Techniciens`) |
| Directory | ExtraGroups[] | Other groups in `OU Groupes`, e.g. `GG-PC-Admins`; optional `Members[]` (added, never removed) |
| Directory | ComputerSubOUs[] | Sub-OUs under `Postes` (`Technicien`: always-on GPO; `Join-Domain.ps1` puts `TECH-*` PCs there) |
| Directory | InitialPassword | Given to new users, who must change it at first logon; must meet complexity |
| Directory | Users[] | `Username`, `FirstName`, `LastName`, `Role`, `Title`; optional `Password`, `ChangePasswordAtLogon` (default true; false needs `Password` — required for RDP and auto-logon accounts), `PasswordNeverExpires` |
| Directory | DomainAdmin | `Enabled` (false = skip step 9), `Username`, `DisplayName`, `Password` (used only at creation), `MemberOf[]`; always added to Domain Admins |
| Policy | PasswordPolicy | `Enabled`, `MinLength`, `Complexity`, `HistoryCount`, `MinAgeDays`, `MaxAgeDays` |
| Policy | Lockout | `Enabled`, `Threshold`, `DurationMinutes`, `ResetAfterMinutes` (≤ duration) |
| Policy | SharedWorkstations | `Enabled`, `GpoName`, `LockAfterMinutes`, `SleepAfterMinutes`, `PasswordOnWake` |
| Policy | LocalAdmins | `Enabled`, `GpoName`, `Group`, `Mode` (`Exclusive`/`Add`), `ExtraMembers[]` (`admin-sama` is added by step 11) |
| Policy | AlwaysOn | `Enabled`, `GpoName`, `SubOU` (listed in `Directory.ComputerSubOUs`): never lock, never sleep, screen always on |
| Policy | ServerRemoteDesktop | `Enabled`, `Users[]`: non-admin users allowed to RDP to the DC (2 sessions at once without the RDS role) |
| Policy | *(any)* | `Enabled: false` or an empty value = **Windows standard kept**; turning off later does not undo a previous run |
| LAPS | Enabled | Default `false`. `true` + "create the rescue account" ticked at join (`-CreateLocalAdmin`) = `admin-sama` managed by LAPS |
| LAPS | AccountName / ReadersGroup | Managed local account (`admin-sama`) / who can read + reset (`GG-PC-Admins`) |
| LAPS | PasswordLength / PasswordComplexity / PasswordAgeDays | Empty = Windows LAPS default (14 / 4 / 30) |
| LAPS | EncryptPasswords | Needs domain level 2016+ (default since this version); only ReadersGroup can decrypt |
| LAPS | PostAuthenticationActions / ...ResetDelayHours | After the password is used: 1 new pwd, 3 + log off, 5 + reboot; after N hours |
| DHCP | InstallRole | Step 2 installs the DHCP role only (no scope, hands out nothing). Default `false` |
| DHCP | Configure | Step 5 creates the scope + authorises the server (implies InstallRole). Default `false`; only if no other DHCP server is on the network. Old `Enabled: true` = both |
| Staging | Enabled | `false` skips the robocopy half of step 12 |
| Staging | SourceRoot / DestinationRoot | USB root → server disk root (e.g. `E:\` → `D:\`) |
| Staging | Folders | Copied `Source\<name>` → `Dest\<name>`; empty = every top-level folder |
| Staging | ExcludeFiles | robocopy `/XF` patterns, e.g. `["*.iso"]` |
| FileShares | Enabled / Items | Folders to create and SMB-share in step 12 |
| FileShares | Items[].FullAccess / ChangeAccess / ReadAccess | Domain groups; well-known ones are auto-corrected |
| SQL | Install | `true`/`false` to include step 13 |
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

## How SQL gets its ISO (step 13)

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
> and step 13 stops with *No SQL ISO found*. Either drop the exclusion or put the
> ISO in `SQL.InstallFolder` by hand.

## Database restore order (step 14)

1. Restore each `Restores[]` entry, relocating data/log files to `DataFolder`
   (existing databases are left alone)
2. Set Mixed-Mode, **restart SQL**, and wait until it really accepts connections
3. Run `CustomSqlScript` verbatim — nothing is appended to it
4. Create `SqlLogin` only if `Create` is `true`
5. Grant `db_owner` on `DbOwnerOf` — independent of step 4, so a login created by
   your own script still gets ownership

`CustomSqlScript` is not automatically re-runnable: a bare `CREATE LOGIN` fails
on a second run. Guard it with `IF NOT EXISTS` if you expect to re-run step 14.

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

.\steps\Step13-InstallSQL.ps1 `
  -InstallFolder "D:\Utilitaire\software\sql" -InstanceName "SQLEXPRESS" `
  -DomainName "DOMLABO.LOCAL" -AdminAccount "adcipro" -InstallSSMS $true
```

(Engine already installed and healthy? Step 13 skips it and just installs SSMS.
A registered but broken instance is uninstalled and reinstalled cleanly.)

## Resuming after a failure

The deployer stops and logs the reason. Fix the cause, then run `.\Deploy.ps1`
again — it skips completed steps and retries the failed one.

**Changing step Ids invalidates `state.json`.** If steps are renamed or
renumbered, run `.\Deploy.ps1 -Reset` before the next run, or completed steps
will run again.

## Notes / safety

- `config.json`, `state.json`, and `deploy.log` are git-ignored (the config holds passwords).
- Step 8 gives every new user `Directory.InitialPassword` and forces a change at
  first logon. Accounts left by v1 with no password get the initial one too.
- **Upgrading a server already deployed with v1:** step Ids changed (`6-Users` →
  `6/7/8`, `7/8/9` → `12/13/14`), so steps 12–14 run again. They are idempotent,
  except a bare `CREATE LOGIN` in `CustomSqlScript`. Do **not** `-Reset` an
  existing DC — that would re-run the forest promotion.
- Test on a VM snapshot first: steps 1–3 are irreversible (rename, DC promotion).
