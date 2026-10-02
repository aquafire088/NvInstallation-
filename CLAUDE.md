# NvInstallation — Prolab lab server automation

Unattended PowerShell deployment of a medical-lab Windows Server domain
(AD DS, DNS, file shares, SQL Server) plus a workstation join script.
Client: **Prolab**. Integrator: **Sama Consulting**. Target design is
`docs/solution AD.pdf` (validation deck, 14/09/2026) — that deck is the
spec; the scripts are catching up to it (see *Target pipeline v2*).

## Layout

| Path | What | Status |
|---|---|---|
| `deploy/` | The deployer: `Deploy.ps1` + `lib/Common.ps1` + `steps/Step0..9` | **current** |
| `deploy/config.json` | All values (IPs, domain, passwords). Git-ignored. | edit this |
| `deploy/config.sample.json` | Template with `_comment` fields | keep in sync |
| `poste/Join-Domain.ps1` | Workstation: static IP, DNS 1+2, IPv6 off, `admin-sama`, rename + join into OU Postes | current |
| `deploy/Console.ps1` + `Console-Serveur.cmd` | WPF GUI (FR/EN): config editor generated from config.json, deploy start/status/log, AD admin (LAPS, users) | current |
| `poste/Join-Domain-GUI.ps1` + `Poste-Jonction.cmd` | WPF GUI (FR/EN) running Join-Domain.ps1 as a background job | current |
| `docs/presentation.html` | French speaking notes for presenting all this | published artifact |
| `docs/solution AD.pdf` | Target architecture (images; text only in titles) | **the spec** |
| `serveur/` | Original interactive scripts, fully superseded | delete |
| `sERVEUR SAMA/`, `*.rar` | Byte-identical snapshot of this repo | git-ignored, delete |

Read `deploy/README.md` for operator docs. This file is for working on the code.

## How the deployer works

- `Deploy.ps1` reads `config.json`, builds a `$plan` array, runs each step
  script with splatted args, and records completion in `state.json`.
- **Step contract:** exit `0` = done, `3010` = done but reboot first,
  anything else = failed, deployment halts. `$LASTEXITCODE` is seeded to 1
  before each step so a script that dies before `exit` is not read as success.
- **Reboot survival:** a Scheduled Task running as `SYSTEM` at startup
  relaunches `Deploy.ps1 -Resume`. No stored credentials. Removed at the end.
- Every step dot-sources `lib/Common.ps1` (`Write-Log`, `Assert-Administrator`,
  `Invoke-Dism`, `Get-ServerNetworkInfo`, `Wait-ForADReady`, state helpers).
- Step Ids are `state.json` keys. **Renaming/renumbering a step invalidates
  state → run `.\Deploy.ps1 -Reset`.** We hit this three times.
- Steps are idempotent by design: check before create, skip if present.
- `deploy/Test-Common.ps1` is the one self-check (state round-trip). Run it.

## Current pipeline (v1 → v2 in progress; what is in `deploy/steps/` now)

| Id | Script | Does | Reboot | AD needed |
|---|---|---|---|---|
| 0-Update | Step0-TroubleshootUpdate | DISM restorehealth, NetFx3, WU cache | yes | no |
| 1-Network | Step1-Network | static IP, DNS, **IPv6 off**, RDP, rename PC, rename admin (**last**) | yes | no |
| 2-Services | Step2-InstallServices | NetFx3, AD DS, DNS, DHCP (if `DHCP.Enabled`) | yes | no |
| 3-Domain | Step3-ConfigureDomain | `Install-ADDSForest`, new forest, level 2016 (WinThreshold) | yes | no |
| 4-DNS | Step4-ConfigureDNS | AD-integrated fwd + reverse zone, forwarders list, server DNS 127.0.0.1 | no | yes |
| 5-DHCP | Step5-ConfigureDHCP | scope, exclusions, per-dept policies | no | yes |
| 6-Structure | Step6-Structure | functional OUs + role sub-OUs, redircmp → Postes | no | yes |
| 7-Groups | Step7-Groups | `GG-<Role>` + `GG-PC-Admins` in OU Groupes | no | yes |
| 8-Users | Step8-Users | users from `Directory.Users`, initial pwd + change at logon | no | yes |
| 9-Admins | Step9-Admins | `ad-sama` → OU Administrateurs, Domain Admins (RID 512) + `GG-PC-Admins` | no | yes |
| 10-GPO | Step10-GPO | pwd + lockout → Default Domain Policy GptTmpl.inf + domain object; GPOs Postes-Partages, Postes-AdminsLocaux (Restricted Groups) → OU Postes; each part optional | no | yes |
| 11-LAPS | Step11-LAPS | Windows LAPS: schema, self + read/reset perms on OU Postes, GPO Postes-LAPS; optional (`LAPS.Enabled`) | no | yes |
| 12-Staging | Step12-StageAndShare | robocopy USB→disk, NTFS ACL, SMB shares | no | yes |
| 13-SQL | Step13-InstallSQL | ISO lookup → pre-flight → silent setup → SSMS | no | yes |
| 14-Database | Step14-Database | restore .bak, mixed-mode, restart, custom SQL, db_owner | no | no |

Current config: domain `DOMLABO.LOCAL`, host `SRV-LABO`, `192.168.1.250/24`,
DHCP **disabled**, SQL instance `SQLEXPRESS` from a USB-staged ISO.

## Target architecture (from `docs/solution AD.pdf`)

Four lab roles: **Accueil, Technicien, Biologiste, Préleveur**. Shared
workstations. Four axes: centralisation, sécurisation, résilience,
standardisation.

- **DC01** — Windows Server 2019/2022, static IP, AD DS, DNS, SQL Server 2019.
  DNS preferred = `127.0.0.1`. Forwarders `8.8.8.8`, `8.8.4.4`, `1.1.1.1`.
  Reverse zone IPv4 only. **IPv6 disabled on every machine.**
- **DC02** — same domain, AD DS + DNS replica, secondary DNS for clients.
  Dual-boot with an Ubuntu partition doing rsync backups (SHA256, rotation).
  Failover: FSMO transfer (or seize via `ntdsutil`), clients repoint DNS.
- **Domain** — the deck says `lab.local`; **decision (15/09/2026): keep
  `DOMLABO.LOCAL` / NetBIOS `DOMLABO`.** Functional OUs, not departmental ones:
  `OU Utilisateurs`, `OU Groupes`, `OU Administrateurs`, `OU Postes`.
  Rights by **security group per role**, never per user.
  Named groups: `GG-Techniciens`, `GG-PC-Admins`.
- **Security (GPO):** password policy (complexity, min length, history, max
  age); lockout (threshold, duration, counter reset); built-in Administrator
  **renamed and disabled**; `ad-sama` = domain admin for occasional use;
  `GG-PC-Admins` = the only local-admin group on workstations (via GPO).
- **LAPS:** AD schema extended; GPO defines the managed local account
  `admin-sama` per workstation; password auto-rotated, readable only by
  authorised accounts; computers in `OU Postes` may update their own attribute.
- **Workstations (Win 11):** cleanup + static IP → DNS = DC01 → join with
  domain admin → move to `OU Postes` → GPOs apply. Users log in with their
  named domain account; `admin-sama` is the local rescue account.
- **Shared-workstation GPO:** lock instead of log off (fast user switching),
  sleep after inactivity instead of shutdown, password required on wake.

## Target pipeline v2 — the clean, centralised, secure install

Same orchestrator, same step contract. Ids are new so v1 state does not
collide. Values in `config.json`; nothing hard-coded in steps.

### DC01 (`deploy/Deploy.ps1`)

| Id | Script | Does | Notes |
|---|---|---|---|
| 0-Update | *(keep)* | | optional |
| 1-Network | Step1-Network | + **disable IPv6** on the adapter | reboot |
| 2-Services | Step2-InstallServices | drop DHCP unless enabled | reboot |
| 3-Domain | Step3-ConfigureDomain | forest `DOMLABO.LOCAL`, NetBIOS `DOMLABO` (unchanged) | reboot |
| 4-DNS | Step4-ConfigureDNS | preferred `127.0.0.1`; forwarders incl. `1.1.1.1` | |
| 5-DHCP | *(keep)* | | disabled |
| 6-Structure | **Step6-Structure** (new) | OUs `Utilisateurs`, `Groupes`, `Administrateurs`, `Postes`; sub-OUs per role under `Utilisateurs` | replaces dept OUs |
| 7-Groups | **Step7-Groups** (new) | `GG-Accueil`, `GG-Techniciens`, `GG-Biologistes`, `GG-Preleveurs`, `GG-PC-Admins` in `OU Groupes` | hyphen, plural |
| 8-Users | **Step8-Users** (rewrite of Step6-LabUsers) | users **with initial password** + change-at-logon, placed in role sub-OU, added to role group | password from config |
| 9-Admins | **Step9-Admins** (done) | create `ad-sama` (Domain Admins) in `OU Administrateurs`; put `ad-sama` in `GG-PC-Admins` | built-in Administrator rename/disable deferred (keep `adcipro`) |
| 10-GPO | **Step10-GPO** (new) | `Set-ADDefaultDomainPasswordPolicy` + lockout; GPO *Postes-Partages* (lock, sleep, password on wake) linked to `OU Postes`; GPO *Restricted-Groups* making `GG-PC-Admins` the local Administrators member | GroupPolicy module |
| 11-LAPS | **Step11-LAPS** (new) | `Update-LapsADSchema`; `Set-LapsADComputerSelfPermission -Identity "OU=Postes,…"`; `Set-LapsADReadPasswordPermission` for `GG-PC-Admins`; GPO *LAPS* (managed account `admin-sama`, rotation) linked to `OU Postes` | **Windows LAPS** (built-in, Server 2019 Apr-2023+ / 2022), not legacy LAPS |
| 12-Staging | Step12-StageAndShare | unchanged; ACLs now name `GG-*` groups | |
| 13-SQL | Step13-InstallSQL | unchanged | |
| 14-Database | Step14-Database | unchanged | |

### DC02 (`deploy/Deploy-DC02.ps1`, new — separate config `config.dc02.json`)

| Id | Does | Reboot |
|---|---|---|
| 1-Network | static IP, DNS → DC01, disable IPv6, rename | reboot |
| 2-Services | AD DS + DNS roles | reboot |
| 3-Promote | `Install-ADDSDomainController -DomainName DOMLABO.LOCAL -InstallDns` with `ad-sama` creds | reboot |
| 4-DNS | confirm zone replication; forwarders | no |
| 5-Verify | `repadmin /replsummary`, `dcdiag`, log FSMO holders | no |

Not scripted here: the Ubuntu partition and rsync backups (out of PowerShell scope).

### Workstation (`poste/Join-Domain.ps1`)

Already does: static IP → DNS = DC01 → SRV lookup → `Add-Computer -NewName`
→ reboot. Add:
- `-DNSServer2` (DC02) so clients survive a DC01 outage
- disable IPv6 on the adapter
- default `-OUPath "OU=Postes,DC=DOMLABO,DC=LOCAL"` — required, LAPS and GPOs are linked there
- create local `admin-sama` (LAPS then owns its password; no password in the script)
- `gpupdate /force` after join, before the reboot prompt

## Gaps v1 → v2 (checklist)

- [x] domain name: **keep `DOMLABO.LOCAL`** (decided 15/09/2026). Deck says
      `lab.local` — say so if asked; do not rename. Stray `DOMLABO1` removed from config.
- [~] IPv6 disabled — Step1 done (binding + DisabledComponents=0xFF); Join-Domain pending
- [x] DNS preferred `127.0.0.1`, forwarder `1.1.1.1` (Step4; zones now AD-integrated for DC02; config `DNS.Forwarders[]`, `DNS.SecondaryDNS`)
- [x] functional OUs (Step6-Structure) replacing departmental OUs; v1 OUs are reported, not deleted
- [x] group naming `GG-<Role>` plural, `GG-PC-Admins`; `FileShares` ACL names updated in the sample
- [x] users with initial password + change at logon (Step8-Users; config `Directory` section)
- [x] `ad-sama` (Step9-Admins; config `Directory.DomainAdmin`)
- [ ] rename + disable built-in Administrator — **deferred: keep `adcipro` for now** (decided 02/10/2026). Do it in a final step after 14-Database; `adcipro` is SQL sysadmin
- [x] password / lockout policy, shared-workstation GPO, restricted-groups GPO (Step10-GPO; config `Policy`, every section optional → Windows standard)
- [x] Windows LAPS (Step11-LAPS; config `LAPS`, optional)
- [ ] DC02 deployer
- [x] Join-Domain: DC02 DNS, OU Postes default, admin-sama, IPv6 off, `-Credential` (gpupdate only on re-run of a joined PC: before the post-join reboot it cannot apply computer policy)
- [x] GUIs: server console + workstation join (FR/EN)
- [ ] delete `serveur/`, `sERVEUR SAMA/`, `*.rar`, `deploy/RUN.md`
- [ ] secrets: `config.json` is plaintext — at minimum restrict its ACL to
      Administrators+SYSTEM in Deploy.ps1; better, DPAPI-protect via `Export-Clixml`

## Decisions needed before implementing v2

0. ~~Domain name~~ — **decided: `DOMLABO.LOCAL`**
1. ~~Initial password~~ — **decided: one shared `Directory.InitialPassword`, change at first logon**
2. `ad-sama` password (config, blank in sample); built-in Administrator rename — deferred, `adcipro` kept
3. DC02 hostname and IP
4. ~~Password policy numbers~~ — **decided: 12 / complexity / 24 / 1–90 days; lockout 5 / 15 min / 15 min; all optional in config**
5. ~~Sleep timeout~~ — **decided: lock 5 min, sleep 15 min, password on wake; optional**
6. ~~LAPS variant~~ — **decided: Windows LAPS, all DCs are Server 2022; optional in config**

## Conventions and hard-won gotchas

- **Order in Step1:** network first, computer rename, **account rename last**.
  Renaming the logged-on admin before a CIM call breaks name→SID (error 1332).
- **Step3 uses `-NoRebootOnCompletion`** so the orchestrator owns the reboot.
- **NetBIOS name:** never derive it from the FQDN. Ask AD (`(Get-ADDomain).NetBIOSName`).
  Step7 and Step8 both do this; config group names may be bare (`GG-Techniciens`).
- **robocopy exit codes are a bitmask:** 0–7 success (1 = files copied), 8+ failure.
- **DISM only signals failure via exit code:** use `Invoke-Dism`, never `| Out-Null` alone.
- **`ConvertTo-Json` collapses a 1-element array to a scalar.** State code wraps
  with `@()` on read and append. Keep it that way.
- **Config is read with `-Encoding UTF8`** (PS 5.1 defaults to ANSI). Accented
  values like `DEFAULT_LANGUAGE=[Français]` depend on it.
- **SQL on a DC:** service accounts must be `NT AUTHORITY\NETWORK SERVICE`
  (virtual accounts cannot be created on a DC). FullText dropped for the same reason.
- **SQL ISO lookup order:** fixed name → any `.iso` > 300 MB in `InstallFolder`
  → `DownloadUrl` (BITS, IWR fallback). Blank URL = fail fast, no download.
- **Step9 order matters:** restores → mixed-mode → one restart with a real
  connection poll → custom SQL verbatim → optional built-in login → db_owner
  (independent of `SqlLogin.Create`). Custom SQL is not re-runnable (bare `CREATE LOGIN`).
- **NTFS beats share permissions.** Step7 breaks inheritance and rebuilds the
  ACL; SYSTEM + Administrators always kept. Share ACL is only the ceiling.
- **Join-Domain:** `Add-Computer -NewName` renames and joins in one operation.
  It verifies `_ldap._tcp.dc._msdcs.<domain>` SRV before joining — that is the
  usual silent failure (client still on a public resolver).
- PSScriptAnalyzer is not installed; the parse check is
  `[System.Management.Automation.Language.Parser]::ParseFile(...)` over `deploy/**/*.ps1`.
- Lint noise to ignore: `MD031/MD060` in README tables, `$SAPassword` plaintext warning.

## Verify after a run

```powershell
Get-Content .\deploy.log -Tail 40
Get-Content .\state.json
(Get-ADDomain).NetBIOSName
Get-ADOrganizationalUnit -Filter * | Select-Object Name
Get-ADGroupMember GG-Techniciens
(Get-Acl D:\Reports).Access | Select-Object IdentityReference, FileSystemRights
Get-SmbShare
sqlcmd -S ".\SQLEXPRESS" -E -Q "SELECT name FROM sys.databases"
```

## When editing

- Change a step → keep its header comment, `STEP n:` log line, and the plan
  entry in `Deploy.ps1` consistent; grep for stale Ids after renumbering.
- Change config shape → update `config.sample.json` `_comment`, `deploy/README.md`
  config table, and the presentation if it names the thing.
- Run `deploy/Test-Common.ps1` and the parse check before saying "done".
- Do not commit `config.json`, `state.json`, `deploy.log`, ISOs, or the `sERVEUR SAMA` copy.
- **Password policy lives in the Default Domain Policy GPO**, not just the domain
  object: `Set-ADDefaultDomainPasswordPolicy` alone is overwritten at the next
  refresh. Step10 merges `[System Access]` in its GptTmpl.inf (UTF-16) and bumps
  the GPO version in AD + GPT.INI. Any GPO edited outside GPMC needs that bump.
- **Step10 policy sections are opt-in:** `Enabled:false` or an empty value means
  "don't write" (Windows standard), not "reset to standard".
- **Forest/domain level is 2016 (WinThreshold)** since Step11: Windows LAPS
  encryption needs it. A forest built earlier at 2012R2 gets unencrypted LAPS
  passwords (Step11 warns) until raised with `Set-ADForestMode`/`Set-ADDomainMode`.
- **Disabled optional steps are not recorded in state.json** (`Enabled=$false` →
  SKIP), so enabling one later runs it on the next deploy.
- **GUI .ps1 files must be UTF-8 *with BOM*** (accented FR strings). Without it
  Windows PowerShell 5.1 reads them as ANSI. Re-save with BOM after editing.
- **PowerShell variable names are case-insensitive.** `$s` clobbers `$S`, and a
  local `$path` overwrites a `[string]$Path` parameter. Both bit the GUI (string
  table renamed `$Strings`; path locals are `$full`). Never reuse a name in a
  different case.
- **GUIs are WPF in Windows PowerShell 5.1, STA** (`-STA` in the .cmd launchers),
  self-elevating. The step list in the console is parsed from `Deploy.ps1`
  (`Id = "..."; Name = "..."` on one line) — keep that shape. The config form
  is generated from config.json; value types are remembered at load so an
  emptied number stays a number field ("" = Windows standard).
- **GUI test hook:** `$env:NVINST_GUI_NOSHOW=1` then dot-source the GUI script:
  the window is built, `$win`/`$ui`/functions are available, nothing is shown.
  Test under `powershell.exe -STA` (5.1), not pwsh.
- **GUI diagnostic log:** `deploy\gui.log` / `poste\gui.log` (fallback `%TEMP%`),
  rotated at 1 MB. Startup environment (OS, PS, admin, STA, modules, config
  validity; adapters on the workstation), every action via `Invoke-Logged`,
  errors with script line + stack, non-fatal `$Error` entries as `DETAIL`, the
  full Join-Domain output as `JOB`. Never log passwords. New buttons must go
  through `Invoke-Logged` (handlers that read `$_` check it *before* the call).
