# NvInstallation - Automated Medical Lab Server Deployment

Complete automated deployment solution for setting up a Windows Server domain controller with Active Directory, DNS, DHCP, and SQL Server for a medical laboratory environment.

## 📋 Overview

This project contains a comprehensive set of PowerShell scripts to automate the complete infrastructure setup for a medical laboratory environment on Windows Server.

**Target Environment:**
- Windows Server 2019/2022
- Domain: DOMLABO.LOCAL
- Network: 192.168.1.0/24
- Departments: Accueil, Prelevement, Technicien, Biologiste

## 🚀 Deployment Scripts

### Script 1: Network & Hostname Configuration
**File:** `1-fixation d'address + change hostname.ps1`

Configures basic server settings:
- ✅ Rename computer (hostname)
- ✅ Rename user account (administrateur → adcipro)
- ✅ Configure static IP address
- ✅ Configure gateway and DNS
- ✅ Enable Remote Desktop Protocol (RDP)

**Requires:** Server restart

---

### Script 2: Install Base Services
**File:** `2-Install_Services_Base.ps1`

Installs required Windows Server roles:
- ✅ .NET Framework 3.5
- ✅ Active Directory Domain Services (AD DS)
- ✅ DNS Server
- ✅ DHCP Server

**Requires:** Server restart

---

### Script 3: Configure Domain
**File:** `3-Configure_Domain_AD.ps1`

Promotes server to Domain Controller:
- ✅ Create new forest (DOMLABO.LOCAL)
- ✅ Configure Active Directory
- ✅ Setup DNS zones
- ✅ Configure Directory Services Restore Mode (DSRM)

**Default Configuration:**
- Domain: DOMLABO.LOCAL
- NetBIOS: DOMLABO
- DSRM Password: Open@{CurrentYear}* (e.g., Open@2026*)

**Requires:** Server restart

---

### Script 4: Configure DNS & Routing
**File:** `4-Configure_DNS.ps1`

Configures DNS server and network routing:
- ✅ Create DNS zones (forward + reverse)
- ✅ Configure DNS forwarders (8.8.8.8, 8.8.4.4)
- ✅ Enable DNS scavenging
- ✅ Configure default routes via gateway
- ✅ Add local network routes

**Auto-Detects:**
- Server IP address
- Network subnet
- Default gateway
- Reverse DNS zone

---

### Script 5: Configure DHCP (Complete)
**File:** `5-Configure_DHCP_Complete.ps1`

Configures DHCP server with department-based IP allocation:

#### DHCP Scope Configuration:
- IP Pool: 192.168.1.50 - 192.168.1.149
- Permanent leases (never expire)
- Auto-DNS, gateway, domain configuration

#### Department IP Pools:
| Department | Prefix | IP Range | Count |
|-----------|--------|----------|-------|
| Accueil | ACC-* | 50-74 | 25 IPs |
| Prelevement | PREV-* | 75-99 | 25 IPs |
| Technicien | TECH-* | 100-124 | 25 IPs |
| Biologiste | BIO-* | 125-149 | 25 IPs |

#### DHCP Policies:
- Automatic IP assignment based on computer name prefix
- Computers are assigned IPs from their department pool
- Windows domain-joined computers get configured automatically

---

### Script 6: Create Lab Users & OUs
**File:** `setup-lab-users.ps1`

Creates Active Directory structure for medical lab:

#### Organizational Units (OUs):
- Accueil (Reception)
- Prelevement (Sample Collection)
- Technicien (Laboratory Technician)
- Biologiste (Biologist)

#### Lab Users:
- sec01, sec02 (Secretaries)
- prev01, prev02 (Prelevement staff)
- tech01, tech02 (Technicians)
- biologiste01 (Biologist)

---

### Script 7: Install SQL Server
**File:** `7-Install_SQL_Server.ps1`

Automated SQL Server installation from ISO:

#### Features:
- ✅ Auto-download SQL Server 2019 French edition
- ✅ Create installation folder: D:\Utilitaire\software\sql
- ✅ Mount ISO automatically
- ✅ Run unattended installation
- ✅ Configure mixed authentication (Windows + SQL)

#### Admin Account:
- Windows: DOMLABO.LOCAL\Adcipro (System Admin)
- SQL: sa (optional)

---

## 📊 Deployment Workflow

```
┌─────────────────────────────────────────────────────────────┐
│ Script 1: Network + Hostname + RDP (restart)               │
│ - Configure static IP: 192.168.1.250                        │
│ - Rename user: administrateur → adcipro                     │
│ - Enable RDP for remote management                          │
└─────────────────────────┬───────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Script 2: Install Services (restart)                        │
│ - Install .NET Framework 3.5                                │
│ - Install AD DS, DNS, DHCP roles                            │
└─────────────────────────┬───────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Script 3: Configure Domain (restart)                        │
│ - Promote to Domain Controller                              │
│ - Create DOMLABO.LOCAL forest                               │
│ - DSRM password: Open@{CurrentYear}*                        │
└─────────────────────────┬───────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Script 4: Configure DNS + Routing                           │
│ - Create DNS zones (forward & reverse)                      │
│ - Configure forwarders & scavenging                         │
│ - Setup network routing via gateway                         │
└─────────────────────────┬───────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Script 5: Configure DHCP (Complete)                         │
│ - Create DHCP scope (50-149)                                │
│ - Setup 4 department pools                                  │
│ - Configure DHCP policies for auto-assignment               │
│ - Permanent IP leases                                       │
└─────────────────────────┬───────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Script 6: Create Lab Users & OUs                            │
│ - Create 4 OUs (Accueil, Prelevement, etc.)                │
│ - Create 7 lab users                                        │
│ - Configure group memberships                               │
└─────────────────────────┬───────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────────┐
│ Script 7: Install SQL Server                                │
│ - Download SQL Server 2019 French edition                   │
│ - Automatic installation                                    │
│ - Configure admin accounts                                  │
└─────────────────────────┬───────────────────────────────────┘
                          ↓
                  ✅ Infrastructure Ready
```

## 🔧 Usage Instructions

### Prerequisites
- Windows Server 2019 or 2022
- Administrator access
- Network connectivity (for script downloads)
- Static IP planned: 192.168.1.250
- Gateway: 192.168.1.1

### Running the Deployment

1. **Script 1 - Network Configuration:**
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
   .\serveur\1-fixation d'address + change hostname.ps1
   # Restart server when prompted
   ```

2. **Script 2 - Install Services:**
   ```powershell
   .\serveur\2-Install_Services_Base.ps1
   # Restart server when prompted
   ```

3. **Script 3 - Configure Domain:**
   ```powershell
   .\serveur\3-Configure_Domain_AD.ps1
   # Restart server - log in as DOMLABO\Adcipro
   ```

4. **Script 4 - DNS Configuration:**
   ```powershell
   .\serveur\4-Configure_DNS.ps1
   ```

5. **Script 5 - DHCP Configuration:**
   ```powershell
   .\serveur\5-Configure_DHCP_Complete.ps1
   ```

6. **Script 6 - Create Lab Users:**
   ```powershell
   .\serveur\setup-lab-users.ps1
   ```

7. **Script 7 - Install SQL Server:**
   ```powershell
   .\serveur\7-Install_SQL_Server.ps1
   # Will auto-download SQL Server ISO
   # Provide SA password when prompted (optional)
   ```

## 🔐 Security Defaults

### Domain Admin Account
- Username: DOMLABO\Adcipro
- Password: (Set during Script 1 - user creation)

### DSRM Password
- Default: Open@{CurrentYear}* (e.g., Open@2026*)
- Used for: Directory Services Restore Mode recovery

### SQL Server Accounts
- Windows Auth: DOMLABO\Adcipro (System Admin)
- SQL Auth: sa (password optional)

## 📝 Network Configuration

### Static IP Addressing
- Server IP: 192.168.1.250
- Gateway: 192.168.1.1
- DNS: 192.168.1.250 (local)
- Subnet: 255.255.255.0 (/24)

### DHCP IP Allocation by Department
- **Accueil**: 192.168.1.50 - 74
- **Prelevement**: 192.168.1.75 - 99
- **Technicien**: 192.168.1.100 - 124
- **Biologiste**: 192.168.1.125 - 149

### Reserved IPs
- 192.168.1.1 - Gateway/Router
- 192.168.1.2-49 - Infrastructure
- 192.168.1.150-249 - Reserved
- 192.168.1.250 - Server/DC
- 192.168.1.251-254 - Reserved

## 💾 Directory Structure

```
c:\DEV\NvInstallation\
├── serveur/
│   ├── 1-fixation d'address + change hostname.ps1
│   ├── 2-Install_Services_Base.ps1
│   ├── 3-Configure_Domain_AD.ps1
│   ├── 4-Configure_DNS.ps1
│   ├── 5-Configure_DHCP_Complete.ps1
│   ├── 6-setup-lab-users.ps1
│   ├── 7-Install_SQL_Server.ps1
│   └── Modèle de configuration du déploiement - Copie.xml
├── .gitignore
└── README.md
```

## ⚠️ Important Notes

1. **Execution Policy:** Scripts require PowerShell execution policy to be set
2. **Administrator Privileges:** All scripts must run as Administrator
3. **Network Planning:** Ensure IP addresses match your network topology
4. **Backups:** Create VM snapshots before each major step
5. **DNS Forwarders:** Default uses Google DNS (8.8.8.8, 8.8.4.4) - customize if needed
6. **SQL Server:** Automatically downloads ~5GB ISO file

## 🐛 Troubleshooting

### Script fails to run
```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
```

### Domain join issues
- Verify network connectivity
- Check DNS resolution: `nslookup domlabo.local`
- Ensure DHCP is configured before domain join

### SQL Server installation hangs
- Check disk space (requires 10GB+)
- Verify .NET Framework installation
- Check SQL Server error logs in:
  `C:\Program Files\Microsoft SQL Server\MSSQL15.SQLEXPRESS\MSSQL\Log\`

## 📚 Additional Resources

- [SQL Server 2019 Documentation](https://docs.microsoft.com/en-us/sql/sql-server/)
- [Active Directory Best Practices](https://docs.microsoft.com/en-us/windows-server/identity/ad-ds/manage/ad-forest-recovery-guide)
- [DHCP Server Configuration](https://docs.microsoft.com/en-us/windows-server/networking/technologies/dhcp/dhcp-top)

## 📄 License

This project is provided as-is for medical laboratory infrastructure deployment.

## 👥 Author

Lab Infrastructure - Automated Deployment System

**Created:** 2026
**Environment:** Windows Server, PowerShell
**Target:** Medical Laboratory (DOMLABO)

---

**Last Updated:** 2026-07-19
