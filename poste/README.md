# Workstation setup (`poste`)

Sets up a lab desktop: **static IP + DNS (DC01, DC02) → IPv6 off → local rescue
account `admin-sama` → rename + join into `OU Postes`**, in one run and one reboot.
The GPOs and Windows LAPS linked to `OU Postes` apply at that reboot; LAPS then
takes over the `admin-sama` password (it starts random and is never shown).

Copy the whole `poste\` folder to the machine (USB, share). Nothing from
`deploy\` is needed.

## Easiest: the window

Double-click **`Poste-Jonction.cmd`**. Windows asks for administrator rights, then
a form opens (French / English) with the lab defaults filled in. Enter the computer
name and IP, click **Joindre au domaine**, give a domain account (`ad-sama`), and
answer *Yes* to restart. The log shows every step.

## Before you start

The server must already be a working domain controller (`deploy\` finished
through step 8 — OUs, groups and users exist), and the workstation must be on the same network as it.

## Run it

Elevated PowerShell on the workstation:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Join-Domain.ps1 -Hostname TECH-01 -IPAddress 192.168.1.101
```

It prompts for domain credentials, then offers to restart.

Anything not passed uses the lab defaults: mask `255.255.255.0`, gateway
`192.168.1.1`, DNS/DC `192.168.1.250`, no DNS 2, domain `DOMLABO.LOCAL`,
OU `OU=Postes,<domain>`, IPv6 off, rescue account `admin-sama`. Pass
`-LocalAdminName ""` to skip the rescue account, `-Credential` to skip the prompt.

Full form:

```powershell
.\Join-Domain.ps1 `
  -Hostname   TECH-01 `
  -IPAddress  192.168.1.101 `
  -SubnetMask 255.255.255.0 `
  -Gateway    192.168.1.1 `
  -DNSServer  192.168.1.250 `
  -DNSServer2 192.168.1.251 `
  -DomainName DOMLABO.LOCAL `
  -OUPath     "OU=Postes,DC=DOMLABO,DC=LOCAL" `
  -LocalAdminName admin-sama `
  -DisableIPv6 $true
```

`-OUPath` drops the computer account straight into the department OU.
`-NoReboot` skips the restart prompt.

## Naming

| Department | Prefix | Suggested IPs |
|------------|--------|---------------|
| Accueil | `ACC-` | .50 – .74 |
| Prelevement | `PREV-` | .75 – .99 |
| Technicien | `TECH-` | .100 – .124 |
| Biologiste | `BIO-` | .125 – .149 |

Those ranges mirror the server's DHCP department policies, which match on exactly
these hostname prefixes. DHCP is currently **disabled** (`DHCP.Enabled: false`),
so addresses are assigned statically here — but keeping the prefixes means
turning DHCP back on later needs no renaming.

Names are capped at 15 characters (NetBIOS) and may use only letters, digits and
hyphens. Both are checked before anything is changed.

## What it does, in order

1. Validates the addresses and hostname
2. Exits early if the machine is already in the domain
3. Sets the static IP, mask and gateway
4. Points DNS at the domain controller
5. **Verifies the DC is reachable and resolvable** — pings it, then looks up the
   `_ldap._tcp.dc._msdcs` SRV record
6. Renames and joins in a single `Add-Computer` call
7. Offers to restart

Step 5 is the one that saves time: a workstation still pointed at a public DNS
resolver cannot find the domain's SRV records, and the join fails with a message
that doesn't say so. The check fails in seconds with the real reason.

Step 6 is one operation on purpose. Renaming first and joining afterwards would
register the machine under its old name and need two reboots.

## If the join fails

```powershell
# Is the DC reachable?
Test-Connection 192.168.1.250

# Can this machine find a domain controller?
Resolve-DnsName -Name _ldap._tcp.dc._msdcs.DOMLABO.LOCAL -Type SRV -Server 192.168.1.250

# What DNS is this adapter actually using?
Get-DnsClientServerAddress -AddressFamily IPv4
```

Wrong credentials, a duplicate computer account in AD, or a clock skew greater
than five minutes between workstation and DC will each reject the join.

## Already joined?

The script exits without changes. To rename a machine that is already a member:

```powershell
Rename-Computer -NewName TECH-02 -DomainCredential (Get-Credential) -Restart
```
