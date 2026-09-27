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
| `poste/Join-Domain.ps1` | Workstation: static IP → rename → join, one reboot | current |
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

## Current pipeline (v1, what is in `deploy/steps/` now)

| Id | Script | Does | Reboot | AD needed |
|---|---|---|---|---|
| 0-Update | Step0-TroubleshootUpdate | DISM restorehealth, NetFx3, WU cache | yes | no |
| 1-Network | Step1-Network | static IP, DNS, RDP, rename PC, rename admin (**last**) | yes | no |
| 2-Services | Step2-InstallServices | NetFx3, AD DS, DNS, DHCP (if `DHCP.Enabled`) | yes | no |
| 3-Domain | Step3-ConfigureDomain | `Install-ADDSForest`, new forest | yes | no |
| 4-DNS | Step4-ConfigureDNS | fwd + reverse zone, forwarders, default route | no | yes |
| 5-DHCP | Step5-ConfigureDHCP | scope, exclusions, per-dept policies | no | yes |
| 6-Users | Step6-LabUsers | dept OUs, 7 users, `GG_<dept>` groups + membership | no | yes |
| 7-Staging | Step7-StageAndShare | robocopy USB→disk, NTFS ACL, SMB shares | no | yes |
| 8-SQL | Step8-InstallSQL | ISO lookup → pre-flight → silent setup → SSMS | no | yes |
| 9-Database | Step9-Database | restore .bak, mixed-mode, restart, custom SQL, db_owner | no | no |

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
| 9-Admins | **Step9-Admins** (new) | create `ad-sama` (Domain Admins) in `OU Administrateurs`; **rename + disable** built-in Administrator; put `ad-sama` in `GG-PC-Admins` | do LAST in the AD block — needs another admin to exist first |
| 10-GPO | **Step10-GPO** (new) | `Set-ADDefaultDomainPasswordPolicy` + lockout; GPO *Postes-Partages* (lock, sleep, password on wake) linked to `OU Postes`; GPO *Restricted-Groups* making `GG-PC-Admins` the local Administrators member | GroupPolicy module |
| 11-LAPS | **Step11-LAPS** (new) | `Update-LapsADSchema`; `Set-LapsADComputerSelfPermission -Identity "OU=Postes,…"`; `Set-LapsADReadPasswordPermission` for `GG-PC-Admins`; GPO *LAPS* (managed account `admin-sama`, rotation) linked to `OU Postes` | **Windows LAPS** (built-in, Server 2019 Apr-2023+ / 2022), not legacy LAPS |
| 12-Staging | Step7-StageAndShare | unchanged; ACLs now name `GG-*` groups | |
| 13-SQL | Step8-InstallSQL | unchanged | |
| 14-Database | Step9-Database | unchanged | |

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
- default `-OUPath "OU=Postes,DC=lab,DC=local"` — required, LAPS and GPOs are linked there
- create local `admin-sama` (LAPS then owns its password; no password in the script)
- `gpupdate /force` after join, before the reboot prompt

## Gaps v1 → v2 (checklist)

- [x] domain name: **keep `DOMLABO.LOCAL`** (decided 15/09/2026). Deck says
      `lab.local` — say so if asked; do not rename. Stray `DOMLABO1` removed from config.
- [ ] IPv6 disabled (Step1, Join-Domain)
- [ ] DNS preferred `127.0.0.1`, forwarder `1.1.1.1`
- [ ] functional OUs (Step6-Structure) replacing departmental OUs
- [ ] group naming `GG-<Role>` plural, `GG-PC-Admins`; update `FileShares` ACL names
- [ ] users with initial password + change at logon (Step8-Users)
- [ ] `ad-sama` + rename/disable built-in Administrator (Step9-Admins)
- [ ] password / lockout policy, shared-workstation GPO, restricted-groups GPO (Step10-GPO)
- [ ] Windows LAPS (Step11-LAPS)
- [ ] DC02 deployer
- [ ] Join-Domain: DC02 DNS, OU Postes default, admin-sama, gpupdate
- [ ] delete `serveur/`, `sERVEUR SAMA/`, `*.rar`, `deploy/RUN.md`
- [ ] secrets: `config.json` is plaintext — at minimum restrict its ACL to
      Administrators+SYSTEM in Deploy.ps1; better, DPAPI-protect via `Export-Clixml`

## Decisions needed before implementing v2

0. ~~Domain name~~ — **decided: `DOMLABO.LOCAL`**
1. Initial password for lab users (one shared initial value, changed at logon?)
2. `ad-sama` password; new name for the disabled built-in Administrator
3. DC02 hostname and IP
4. Password policy numbers: min length, history, max age, lockout threshold/duration
5. Sleep timeout (minutes) for the shared-workstation GPO
6. Confirm Windows LAPS (needs Server 2019 with April 2023 CU, or 2022) vs legacy LAPS

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
