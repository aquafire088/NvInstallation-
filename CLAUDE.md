
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
| 6-Structure | Step6-Structure | functional OUs + role sub-OUs + `ComputerSubOUs` under Postes (`Technicien`), redircmp → Postes | no | yes |
| 7-Groups | Step7-Groups | `GG-<Role>` + `GG-PC-Admins` in OU Groupes; `ExtraGroups[].Members` (GG-PC-Admins = `adcipro`) | no | yes |
| 8-Users | Step8-Users | users from `Directory.Users`, initial pwd + change at logon, or own `Password` + `ChangePasswordAtLogon:false` (RDP/auto-logon accounts) | no | yes |
| 9-Admins | Step9-Admins | `ad-sama` → OU Administrateurs, Domain Admins (RID 512) + `GG-PC-Admins`; **off** (`DomainAdmin.Enabled:false`) | no | yes |
| 10-GPO | Step10-GPO | pwd + lockout → Default Domain Policy GptTmpl.inf + domain object; GPOs Postes-Partages, Postes-AdminsLocaux (Restricted Groups) → OU Postes; Postes-Techniciens (never lock/sleep, screen on) → Postes\Technicien; RDP right on the DC for `ServerRemoteDesktop.Users` (Default Domain Controllers Policy); each part optional | no | yes |
| 11-LAPS | Step11-LAPS | Windows LAPS: schema, self + read/reset perms on OU Postes, GPO Postes-LAPS, adds `admin-sama` to the Exclusive local-admins GPO; **off** by default (`LAPS.Enabled`) | no | yes |
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
- [x] ~~rename + disable built-in Administrator~~ — **dropped 06/10/2026: `adcipro` is the only admin** (see Decisions 06/10/2026)
- [x] password / lockout policy, shared-workstation GPO, restricted-groups GPO (Step10-GPO; config `Policy`, every section optional → Windows standard)
- [x] Windows LAPS (Step11-LAPS; config `LAPS`, optional)
- [ ] DC02 deployer
- [x] Join-Domain: DC02 DNS, OU Postes default, admin-sama, IPv6 off, `-Credential` (gpupdate only on re-run of a joined PC: before the post-join reboot it cannot apply computer policy)
- [x] GUIs: server console + workstation join (FR/EN)
- [ ] delete `serveur/`, `sERVEUR SAMA/`, `*.rar`, `deploy/RUN.md`
- [ ] secrets: `config.json` is plaintext — at minimum restrict its ACL to
      Administrators+SYSTEM in Deploy.ps1; better, DPAPI-protect via `Export-Clixml`

## Decisions 06/10/2026 (user, overrides the deck where they differ)

- **`adcipro` (built-in Administrator) is the only admin** of the domain and of
  the workstations. `ad-sama` not created (Step9 off); `GG-PC-Admins` = adcipro;
  LocalAdmins Exclusive (the Win 11 setup account loses admin). Join with adcipro.
- **`admin-sama` off by default**: server `LAPS.Enabled:false` + PC checkbox
  "create the rescue account" (`Join-Domain.ps1 -CreateLocalAdmin`). Both needed.
- **Technician PCs never lock, never sleep, screen always on**: GPO
  Postes-Techniciens on `OU=Technicien,OU=Postes`. Join-Domain sends `TECH-*`
  there when `-OUPath` is blank (falls back to Postes if the OU is missing).
- **Auto-logon after reboot**, chosen per PC at join (`-AutoLogonUser`/`-AutoLogonPassword`).
  Password in the LSA secret `DefaultPassword`, not the registry. The account must
  have its own `Password`, `ChangePasswordAtLogon:false`, ideally `PasswordNeverExpires:true`.
  Checked by an LDAP bind before the join.
- **`biologiste001`** (Biologiste, own password, no change at logon) may RDP to
  the DC alongside adcipro (2 sessions, no RDS role): BUILTIN\Remote Desktop
  Users + SeRemoteInteractiveLogonRight in the Default Domain Controllers Policy.
  Its `Password` is blank in config → **step 8 fails until the user fills it**.
- The built-in Administrator rename/disable item below is therefore dropped.
- **DHCP = two switches, both off when missing**: `DHCP.InstallRole` (step 2, role
  only, no scope) and `DHCP.Configure` (step 5, implies the role). Old `Enabled:true`
  = both. Current config: InstallRole true, Configure false. Step5 still has the known
  bugs (policies, exclusions, permanent lease) — rewrite it before `Configure:true`.

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
- **`New-LocalUser -Description` is max 48 characters.** A longer one made
  every first join fail before `Add-Computer` (found in the lab 04/10/2026;
  only hit when `admin-sama` does not exist yet, i.e. every new PC).
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

## Hyper-V test lab (on the dev laptop GHOSTSHELL, started 03/10/2026)

Goal: a disposable lab where `deploy/` runs from a clean Windows Server VM,
three Win 11 clients join `DOMLABO.LOCAL`, and the user's existing tests run
against real machines. **Rules the user set:** do not rewrite the scripts;
do not "fix" a VM to make a script pass; when a script is wrong, say
"the script has a problem", point to the line, and change it only when asked.
Classify every failure (SCRIPT / CONFIG / ENVIRONMENT / WINDOWS / HYPER-V /
NETWORK / DEPENDENCY / PERMISSION / DOCUMENTATION). Final report: PASS / PASS
WITH ISSUES / FAIL, never "production-ready". The user is not a networking
expert: explain in plain words, say *which machine* a command runs on.

**Host:** HP EliteBook, i7-10810U 6c/12t, **15.8 GB RAM (~4 GB free with apps
open — the real limit)**, C: ~140 GB free (VMs live in `C:\Lab\NvInstallation`).
Wi-Fi changes networks (seen 192.168.1.x and 192.168.11.x) — so the lab must
never touch the Wi-Fi adapter.

**Network (built and working):**

```text
Internet ─ Wi-Fi ─ host ─ "Default Switch" (Hyper-V NAT, 172.17.x, changes on reboot)
                                │ eth1 = WAN (DHCP)
                             LAB-GW  OpenWrt 25.12.5, Gen1, 256 MB
                                │ eth0 = LAN 192.168.1.1/24
                     "LAB-Private" (Private switch: host has NO adapter on it)
                                │
                     SRVLABO (server) … later 3 clients
```

- Why: an External switch would bridge onto the real LAN (same /24, rogue
  DHCP); Internal+NetNat needs a host IP in 192.168.1.0/24. A router VM keeps
  every address the scripts expect (.1 gateway, .250 server, pool .50–.149).
- LAB-GW: **DHCP, RA and DHCPv6 are OFF on the LAN** (the DC's DHCP must be
  the only one). Static MACs LAN `00:15:5D:0A:00:01`, WAN `…:02`. COM1 =
  `\\.\pipe\LAB-GW-console` (serial console; scripted with a NamedPipe client).
- Host → router: `ssh -i $HOME\.ssh\lab_gw root@LAB-GW.mshome.net` (key only,
  password auth off; firewall rule `Allow-SSH-from-Hyper-V-host`, wan, src
  172.16.0.0/12). `ssh 192.168.1.1` from the host times out **by design**.
- Start LAB-GW before the other VMs. Checkpoints: `GW-01 …`, `GW-02 + SSH`.
- One `hv_storvsc … cmd 0x2a` write error was logged once; none after reboot. Watch for it.

**Server VM:** the user created it as **`SRVLABO`** (Gen2, matches
`config.json` Hostname). It was first on Default Switch (got 172.17.x) →
moved to `LAB-Private`. Guest Service Interface was disabled by default →
enabled (needed for `Copy-VMFile`). `deploy/` copied to `C:\deploy` (without
gui.log/state.json/deploy.log). Checkpoint `CLEAN SERVER - BEFORE NvInstallation …`.
Before Step 1 the server has 169.254.x (no DHCP on the lab — expected). For
Internet before deploying, a **temporary 192.168.1.200** + DNS 1.1.1.1 is
used; Step1 removes any IP that is not `IPAddress` and sets .250.

**Not done yet:** run `Deploy.ps1`; add a D: disk and an "E: USB" VHDX
(Staging/SQL/Database need `E:\{Backup,Docs,LastBuild,Reports,SQL_DATA,Utilitaire}`,
`D:\InitialBase\*.bak`, SQL ISO staged in `D:\Utilitaire\software\sql`);
three Win 11 clients (VM LAB-PC01..03, hostnames `ACC-PC01`, `TECH-PC01`,
`BIO-PC01`, 2 GB dynamic, differencing disks); turn off Hyper-V time sync on
the DC; ProLab application (installer + `ProLab.ini` not found yet).
Use **anonymised** databases in the lab, never real patient data. Revert all
lab VMs together (a DC reverted alone breaks the clients' secure channel).

**Verification suite:** `..\Server Maintenance Automation Tool\ServerMaintenanceToolkit`
(`Tests\Invoke-AcceptanceTest.ps1`, client config like `LabTools\LAB-Test.psd1`)
covers network, DNS resolution, DC discovery/ports, domain membership/secure
channel, shares, firewall, SQL, services. It does **not** cover AD content,
DNS zones/forwarders, DHCP policies, GPO/LAPS — a lab-only gap test was
proposed, not written (needs the user's OK).

**Problems found by reading (predicted, not yet confirmed in the lab):**

- `Step5-ConfigureDHCP.ps1:78-79` (and `serveur/5`): `Add-DhcpServerv4PolicyCondition
  -ConditionType HostName` and `Set-DhcpServerv4PolicyIPRange` do not exist
  (real API: `Add-DhcpServerv4Policy -Fqdn "EQ,ACC-*"` + `Add-DhcpServerv4PolicyIPRange`);
  the catch logs WARN and the step still exits 0 → department policies silently missing.
- Step5 exclusions (.1–.49, .150–.254) are outside the scope range → silently fail.
- `Step1-Network.ps1:154` renames only `administrateur` (French OS); on an
  English image the rename is skipped. Use a French Server ISO.
- `config.json`: `SQL.InstanceName = MSSQLSERVER` vs `Database.Server = .\SQLEXPRESS`.
- `Join-Domain.ps1` requires `-IPAddress` (static), so the shipped client flow
  never exercises DHCP; DHCP department tests need hostnames `ACC-/PREV-/TECH-/BIO-`.
- Root `README.md` documents the obsolete `serveur/` scripts.
- `Deploy.ps1` has no "stop after step N", so per-step checkpoints need a
  `-StopAfter` option (script change → ask first).

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
- **Server console config picker:** any `config*.json` next to Deploy.ps1 (not the
  sample); edit, save and *Start* use the selected file (`-Config`). Deploys started
  from the console and the resume task run `-NonInteractive` (a prompt fails the step
  instead of hanging a hidden window — Step5's `Condition:` prompt did that).
- **Table editor + optional bool columns:** a checkbox never set in a row is NOT
  written (absent = the step's default). Writing `false` for every row made
  `ChangePasswordAtLogon=false` on all users → step 8 failed. Keep it that way.
- **GUI test hook:** `$env:NVINST_GUI_NOSHOW=1` then dot-source the GUI script:
  the window is built, `$win`/`$ui`/functions are available, nothing is shown.
  Test under `powershell.exe -STA` (5.1), not pwsh.
- **GUI diagnostic log:** `deploy\gui.log` / `poste\gui.log` (fallback `%TEMP%`),
  rotated at 1 MB. Startup environment (OS, PS, admin, STA, modules, config
  validity; adapters on the workstation), every action via `Invoke-Logged`,
  errors with script line + stack, non-fatal `$Error` entries as `DETAIL`, the
  full Join-Domain output as `JOB`. Never log passwords. New buttons must go
  through `Invoke-Logged` (handlers that read `$_` check it *before* the call).
