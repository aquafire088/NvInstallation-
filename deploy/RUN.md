# RUN — command cheat sheet

Do these on the server, in an **elevated PowerShell** (right-click → *Run as Administrator*).

---

## 0. Get the files onto the server
Copy the whole `deploy\` folder to the server, e.g. `C:\deploy\`.

---

## 1. Open elevated PowerShell in the deploy folder
```powershell
cd C:\deploy
Set-ExecutionPolicy Bypass -Scope Process -Force
```

---

## 2. Edit your settings (once)
```powershell
notepad .\config.json
```
Fill in: hostname, IP, gateway, domain, `DSRMPassword`, and (optional) `SAPassword`.
- Leave `SAPassword` empty for Windows-only auth. If you set it, it must be strong
  (8+ chars, upper + lower + digit + symbol) or it's ignored.
- `InstallSSMS: true` also installs Management Studio from the web after SQL.

---

## 3a. FULL unattended deployment (fresh server)
Runs everything, reboots as needed, and resumes on its own until done.
```powershell
.\Deploy.ps1
```
When finished, the log ends with `DEPLOYMENT COMPLETE`.

---

## 3b. Run ONE step only (for testing on this machine)
The step scripts take parameters directly. Examples:

**SQL + SSMS only:**
```powershell
.\steps\Step8-InstallSQL.ps1 `
  -DownloadUrl "https://burdpme.sage.com.dl1.ipercast.net/PME/Serveurs/SQL_Std_2019Dec_64Bit_French.iso" `
  -InstallFolder "C:\Utilitaire\software\sql" `
  -InstanceName "SQLEXPRESS" `
  -DomainName "DOMLABO.LOCAL" `
  -AdminAccount "Adcipro" `
  -InstallSSMS $true
```
(Engine already installed? It skips the engine and just installs SSMS.)

**DNS only:**
```powershell
.\steps\Step4-ConfigureDNS.ps1 -DomainName "DOMLABO.LOCAL"
```

---

## Handy commands
```powershell
.\Deploy.ps1                 # start or resume
.\Deploy.ps1 -Reset          # clear saved progress + auto-resume task (start over)
Get-Content .\deploy.log -Tail 40      # watch the log
Get-Content .\deploy.log -Wait         # live-follow the log
```

---

## Check what's happening
```powershell
# Is the auto-resume task registered?
Get-ScheduledTask -TaskName "NvInstallation-Resume"

# Which steps are done?
Get-Content .\state.json

# Is SQL running?
Get-Service 'MSSQL$SQLEXPRESS'
sqlcmd -S ".\SQLEXPRESS" -E -Q "SELECT @@VERSION"
```

---

## If a step fails
The run stops and writes the reason to `deploy.log`. Fix the cause, then just run
`.\Deploy.ps1` again — it skips completed steps and retries the failed one.
