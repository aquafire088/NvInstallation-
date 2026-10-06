<#
============================================================
  NvInstallation - Server console (graphical)
============================================================
  Double-click Console-Serveur.cmd (next to this file). Three tabs:
    Configuration  - edit config.json: fields, checkboxes, tables
    Deploiement    - start / resume / reset, step status, live log
    Administration - LAPS password of a workstation, lab users
  French / English switch at the top.

  The form is generated from config.json itself, so new config
  sections appear without touching this file. Value types are
  remembered from the file when it is loaded (a number left empty
  stays a number field - empty = "keep the Windows standard").
  Save keeps a copy of the previous file as config.json.bak.
  This file contains accented text: keep it saved as UTF-8 WITH BOM,
  or Windows PowerShell 5.1 reads it as ANSI.
============================================================
#>
[CmdletBinding()]
param()

# ============================================================
# Diagnostic log: deploy\gui.log (or %TEMP% if the folder is read-only).
# Startup environment, every action, every error with its script line.
# Never contains passwords. The "Journal" button opens it.
# ============================================================
$script:GuiLog = Join-Path $PSScriptRoot 'gui.log'
try {
    if ((Test-Path $script:GuiLog) -and (Get-Item $script:GuiLog).Length -gt 1MB) { Move-Item $script:GuiLog "$script:GuiLog.old" -Force }
    Add-Content -Path $script:GuiLog -Value '' -ErrorAction Stop
}
catch { $script:GuiLog = Join-Path $env:TEMP 'NvInstallation-gui.log' }

function Write-GuiLog {
    param([string]$Message, [string]$Level = 'INFO')
    try { Add-Content -Path $script:GuiLog -Encoding UTF8 -Value ('[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message) } catch {}
}
function Format-Err {
    param($Err)
    $where = "$($Err.InvocationInfo.PositionMessage)".Trim() -replace '\r?\n', ' | '
    $stack = "$($Err.ScriptStackTrace)" -replace '\r?\n', ' <- '
    return "$($Err.Exception.GetType().FullName): $($Err.Exception.Message)`n        at: $where`n        stack: $stack"
}
function Show-FatalError {
    param($Err)
    Write-GuiLog ("FATAL " + (Format-Err $Err)) 'ERROR'
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show("Erreur / Error :`n`n$($Err.Exception.Message)`n`n$($Err.InvocationInfo.PositionMessage)`n`nJournal / log : $script:GuiLog", 'Console Prolab', 'OK', 'Error')
    } catch {}
}
trap { Show-FatalError $_; exit 1 }

# ---------- relaunch in the right host: Windows PowerShell 5.1, STA, elevated ----------
# Double-click (.cmd) already gives all three; VS Code, pwsh 7 or "Run with PowerShell" may not.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta   = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
if (-not $isAdmin -or -not $isSta -or $PSVersionTable.PSEdition -ne 'Desktop') {
    Write-GuiLog "Relaunch needed (admin=$isAdmin, STA=$isSta, edition=$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)) -> powershell.exe 5.1 -STA, elevated"
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        Start-Process $exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`"" -ErrorAction Stop
    }
    catch { Write-GuiLog ("Relaunch failed (UAC refused?) - " + (Format-Err $_)) 'ERROR' }
    exit
}

# ---------- startup environment ----------
function Write-StartupInfo {
    Write-GuiLog '==================== Console.ps1 START ===================='
    Write-GuiLog "Script   : $PSCommandPath"
    Write-GuiLog "User     : $env:USERDOMAIN\$env:USERNAME | admin=$isAdmin | computer=$env:COMPUTERNAME"
    Write-GuiLog "PS       : $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition) | apartment=$([Threading.Thread]::CurrentThread.GetApartmentState()) | culture=$((Get-Culture).Name) | uiculture=$((Get-UICulture).Name)"
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $kind = switch ([int]$os.ProductType) { 1 { 'workstation' } 2 { 'DOMAIN CONTROLLER' } 3 { 'server' } default { '?' } }
        Write-GuiLog "OS       : $($os.Caption) $($os.Version) (build $($os.BuildNumber)) | $kind | domain=$((Get-CimInstance Win32_ComputerSystem).Domain)"
    } catch { Write-GuiLog ("OS info failed - " + (Format-Err $_)) 'WARN' }
    $net = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
    Write-GuiLog ".NET     : release $net"
    foreach ($m in 'ActiveDirectory', 'GroupPolicy', 'LAPS', 'ADDSDeployment', 'DnsServer') {
        $mod = Get-Module -ListAvailable $m | Select-Object -First 1
        Write-GuiLog ("Module   : {0,-15} {1}" -f $m, $(if ($mod) { "available $($mod.Version)" } else { 'NOT available' }))
    }
    foreach ($f in 'config.json', 'config.sample.json', 'Deploy.ps1', 'state.json', 'deploy.log') {
        $p = Join-Path $PSScriptRoot $f
        if (Test-Path $p) { Write-GuiLog ("File     : {0,-18} {1} bytes, modified {2}" -f $f, (Get-Item $p).Length, (Get-Item $p).LastWriteTime) }
        else { Write-GuiLog ("File     : {0,-18} missing" -f $f) }
    }
    $cfgFile = Join-Path $PSScriptRoot 'config.json'
    if (Test-Path $cfgFile) {
        try { $null = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json; Write-GuiLog 'Config   : config.json is valid JSON' }
        catch { Write-GuiLog ("Config   : config.json is NOT valid JSON - $($_.Exception.Message)") 'ERROR' }
    }
    $dep = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*Deploy.ps1*' }
    Write-GuiLog "Deploy   : $(if ($dep) { "running (PID $(@($dep.ProcessId) -join ','))" } else { 'not running' }) | resume task: $(if (Get-ScheduledTask -TaskName 'NvInstallation-Resume' -ErrorAction SilentlyContinue) { 'registered' } else { 'none' })"
}
Write-StartupInfo

# Every button goes through this: logged, errors caught with their script line,
# and non-fatal errors raised inside the action recorded too.
function Invoke-Logged {
    param([string]$Name, [scriptblock]$Action, [switch]$Quiet)
    if (-not $Quiet) { Write-GuiLog "ACTION   : $Name" }
    $global:Error.Clear()   # $Error is capped at 256: counting from a full list misses everything
    try { & $Action }
    catch {
        Write-GuiLog ("FAILED   : $Name - " + (Format-Err $_)) 'ERROR'
        if ($global:Error.Count) { $global:Error.RemoveAt(0) }
        Show-Message ("$Name :`n$($_.Exception.Message)`n`n$(T 'log.see')`n$script:GuiLog") 'Error' | Out-Null
    }
    $new = [Math]::Min($global:Error.Count, 20)
    for ($i = $new - 1; $i -ge 0; $i--) {
        $e = $global:Error[$i]
        if ($e -is [System.Management.Automation.ErrorRecord]) { Write-GuiLog ("detail   : during '$Name' (handled by the script) - " + (Format-Err $e)) 'DETAIL' }
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Data

$Root         = $PSScriptRoot
$ConfigPath   = Join-Path $Root "config.json"
$SamplePath   = Join-Path $Root "config.sample.json"
$StatePath    = Join-Path $Root "state.json"
$LogPath      = Join-Path $Root "deploy.log"
$DeployScript = Join-Path $Root "Deploy.ps1"

# ============================================================
# Strings (index 0 = francais, 1 = english)
# ============================================================
$script:Lang = 0
$Strings = @{
    'app.title'      = @('Console Prolab - Serveur', 'Prolab console - Server')
    'lang'           = @('Langue', 'Language')
    'tab.config'     = @('Configuration', 'Configuration')
    'tab.deploy'     = @('Déploiement', 'Deployment')
    'tab.admin'      = @('Administration', 'Administration')
    'cfg.reload'     = @('Recharger', 'Reload')
    'cfg.save'       = @('Enregistrer', 'Save')
    'cfg.sections'   = @('Sections', 'Sections')
    'cfg.missing'    = @("config.json est introuvable.`nLe créer à partir de config.sample.json ?", "config.json was not found.`nCreate it from config.sample.json?")
    'cfg.loaded'     = @('Fichier chargé : ', 'Loaded: ')
    'cfg.saved'      = @('Configuration enregistrée (ancienne version : même nom + .bak).', 'Configuration saved (previous version: same name + .bak).')
    'cfg.errors'     = @('Problèmes trouvés :', 'Problems found:')
    'cfg.saveAnyway' = @('Enregistrer quand même ?', 'Save anyway?')
    'cfg.listHelp'   = @('Une valeur par ligne.', 'One value per line.')
    'cfg.gridHelp'   = @('Ajoutez une ligne dans la dernière ligne vide ; Suppr efface la ligne sélectionnée. Plusieurs valeurs dans une case : séparez-les par « ; ».', 'Add a row in the last empty row; Del removes the selected row. Several values in one cell: separate them with ";".')
    'cfg.parseError' = @('Fichier de configuration illisible : ', 'Configuration file cannot be read: ')
    'cfg.file'       = @('Fichier :', 'File:')
    'cfg.needOwnPwd' = @('« Changer le mdp » décoché : un mot de passe propre est obligatoire', '"Change pwd" unticked: its own password is required')
    'cfg.notInUsers' = @("n'est pas dans Annuaire > Utilisateurs", 'is not in Directory > Users')
    'cfg.notInSubOUs'= @("n'est pas dans Annuaire > Sous-OU de Postes", 'is not in Directory > Postes sub-OUs')
    'cfg.dhcpConfigure' = @("l'étape 5 a des défauts connus (elle bloque sur « Condition: »), à réécrire avant de l'activer", 'step 5 has known bugs (it stops at "Condition:"), rewrite it before enabling')
    'dep.file'       = @('Fichier de configuration : ', 'Configuration file: ')
    'dep.start'      = @('Démarrer / Reprendre', 'Start / Resume')
    'dep.reset'      = @("Réinitialiser l'état", 'Reset state')
    'dep.folder'     = @('Ouvrir le dossier', 'Open folder')
    'dep.steps'      = @('Étapes', 'Steps')
    'dep.log'        = @('Journal (deploy.log)', 'Log (deploy.log)')
    'dep.running'    = @('Déploiement en cours...', 'Deployment running...')
    'dep.idle'       = @('Aucun déploiement en cours.', 'No deployment running.')
    'dep.noConfig'   = @("Créez d'abord config.json (onglet Configuration).", 'Create config.json first (Configuration tab).')
    'dep.confirm'    = @("Le serveur va redémarrer plusieurs fois et reprendre seul jusqu'à la fin.`nVous pouvez fermer cette fenêtre : la progression reste visible en la rouvrant.`n`nDémarrer ?", "The server will restart several times and continue on its own until done.`nYou can close this window: reopen it to see progress.`n`nStart?")
    'dep.confirmReset' = @("Efface la progression enregistrée : toutes les étapes seront rejouées.`nNE PAS faire sur un contrôleur de domaine déjà en service (l'étape 3 recréerait la forêt).`n`nRéinitialiser ?", "Clears saved progress: every step will run again.`nDo NOT do this on a domain controller already in service (step 3 would re-create the forest).`n`nReset?")
    'col.id'         = @('Étape', 'Step')
    'col.name'       = @('Description', 'Description')
    'col.status'     = @('État', 'Status')
    'st.done'        = @('✔ Terminé', '✔ Done')
    'st.running'     = @('▶ En cours', '▶ Running')
    'st.failed'      = @('✖ Échec', '✖ Failed')
    'st.skipped'     = @('– Désactivé', '– Disabled')
    'st.pending'     = @('· En attente', '· Pending')
    'adm.noAD'       = @("Le module ActiveDirectory est introuvable.`nCet onglet fonctionne sur le contrôleur de domaine, après le déploiement.", "The ActiveDirectory module was not found.`nThis tab works on the domain controller, after deployment.")
    'adm.laps'       = @("Mot de passe de secours d'un poste (LAPS)", 'Workstation rescue password (LAPS)')
    'adm.pc'         = @('Nom du poste :', 'Computer name:')
    'adm.show'       = @('Afficher', 'Show')
    'adm.copy'       = @('Copier', 'Copy')
    'adm.expire'     = @('Forcer un nouveau mot de passe', 'Force a new password')
    'adm.expireOk'   = @('Le poste changera son mot de passe à la prochaine application des stratégies (redémarrage, gpupdate ou ~1 h).', 'The computer will change its password at the next policy refresh (restart, gpupdate or ~1 h).')
    'adm.lapsNone'   = @("Aucun mot de passe LAPS pour ce poste (pas encore joint, pas redémarré, ou LAPS désactivé).", 'No LAPS password for this computer (not joined yet, not restarted, or LAPS disabled).')
    'adm.noLaps'     = @("Le module LAPS est introuvable (mise à jour d'avril 2023 ou plus récente requise).", 'The LAPS module was not found (April 2023 update or later required).')
    'adm.users'      = @('Utilisateurs du laboratoire', 'Lab users')
    'adm.refresh'    = @('Actualiser', 'Refresh')
    'adm.add'        = @('Ajouter...', 'Add...')
    'adm.toggle'     = @('Activer / Désactiver', 'Enable / Disable')
    'adm.resetPwd'   = @('Nouveau mot de passe...', 'New password...')
    'adm.unlock'     = @('Déverrouiller', 'Unlock')
    'adm.select'     = @("Sélectionnez d'abord un utilisateur.", 'Select a user first.')
    'adm.done'       = @('Fait.', 'Done.')
    'adm.noRoles'    = @('Aucun rôle dans config.json (Directory.Roles).', 'No roles in config.json (Directory.Roles).')
    'u.username'     = @('Identifiant', 'Username')
    'u.name'         = @('Nom complet', 'Full name')
    'u.first'        = @('Prénom', 'First name')
    'u.last'         = @('Nom', 'Last name')
    'u.role'         = @('Rôle', 'Role')
    'u.title'        = @('Fonction', 'Job title')
    'u.enabled'      = @('Actif', 'Enabled')
    'u.locked'       = @('Verrouillé', 'Locked')
    'u.lastLogon'    = @('Dernière connexion', 'Last logon')
    'u.password'     = @('Mot de passe', 'Password')
    'u.mustChange'   = @('Changer le mot de passe à la prochaine connexion', 'Change password at next logon')
    'u.newUser'      = @('Nouvel utilisateur', 'New user')
    'log.see'        = @('Détails dans le journal :', 'Details in the log:')
    'log.open'       = @('Journal', 'Log')
    'ok'             = @('OK', 'OK')
    'cancel'         = @('Annuler', 'Cancel')
}
function T([string]$Key) { if ($Strings.ContainsKey($Key)) { return $Strings[$Key][$script:Lang] } return $Key }

# Friendly names for config keys; unknown keys show as-is.
$KeyLabels = @{
    'Network' = @('Réseau', 'Network'); 'Domain' = @('Domaine', 'Domain'); 'DNS' = @('DNS', 'DNS'); 'DHCP' = @('DHCP', 'DHCP')
    'Directory' = @('Annuaire (OU, groupes, utilisateurs)', 'Directory (OUs, groups, users)')
    'Policy' = @('Stratégies de sécurité', 'Security policy'); 'LAPS' = @('LAPS', 'LAPS'); 'SQL' = @('SQL Server', 'SQL Server')
    'Staging' = @('Copie depuis la clé USB', 'Copy from USB key'); 'FileShares' = @('Partages de fichiers', 'File shares')
    'Database' = @('Bases de données', 'Databases'); 'Options' = @('Options', 'Options')
    'Hostname' = @('Nom du serveur', 'Server name'); 'NewAdminUsername' = @("Nouveau nom du compte admin", 'New admin account name')
    'IPAddress' = @('Adresse IP', 'IP address'); 'SubnetMask' = @('Masque', 'Subnet mask'); 'Gateway' = @('Passerelle', 'Gateway')
    'PrimaryDNS' = @('DNS préféré (étapes 1-3)', 'Preferred DNS (steps 1-3)'); 'SecondaryDNS' = @('DNS secondaire', 'Secondary DNS')
    'AdapterName' = @('Carte réseau (vide = auto)', 'Network adapter (blank = auto)'); 'DisableIPv6' = @('Désactiver IPv6', 'Disable IPv6')
    'DomainName' = @('Nom du domaine', 'Domain name'); 'NetbiosName' = @('Nom NetBIOS', 'NetBIOS name'); 'DSRMPassword' = @('Mot de passe DSRM', 'DSRM password')
    'Forwarders' = @('Redirecteurs DNS', 'DNS forwarders'); 'Enabled' = @('Activé', 'Enabled')
    'OUs' = @('Unités d''organisation', 'Organizational units'); 'Users' = @('Utilisateurs', 'Users'); 'Groups' = @('Groupes', 'Groups')
    'Admins' = @('Administrateurs', 'Administrators'); 'Computers' = @('Postes', 'Computers'); 'Roles' = @('Rôles', 'Roles')
    'ExtraGroups' = @('Groupes supplémentaires', 'Extra groups'); 'InitialPassword' = @('Mot de passe initial', 'Initial password')
    'DomainAdmin' = @('Administrateur du domaine supplémentaire (ad-sama, facultatif)', 'Extra domain admin (ad-sama, optional)'); 'Username' = @('Identifiant', 'Username')
    'DisplayName' = @('Nom affiché', 'Display name'); 'Password' = @('Mot de passe', 'Password'); 'MemberOf' = @('Membre de', 'Member of')
    'PasswordPolicy' = @('Mots de passe', 'Passwords'); 'MinLength' = @('Longueur minimale', 'Minimum length')
    'Complexity' = @('Complexité', 'Complexity'); 'HistoryCount' = @('Historique', 'History'); 'MinAgeDays' = @('Durée minimale (jours)', 'Minimum age (days)')
    'MaxAgeDays' = @('Durée maximale (jours)', 'Maximum age (days)'); 'Lockout' = @('Verrouillage des comptes', 'Account lockout')
    'Threshold' = @("Seuil d'échecs", 'Failed attempts'); 'DurationMinutes' = @('Durée (minutes)', 'Duration (minutes)')
    'ResetAfterMinutes' = @('Remise à zéro du compteur (min)', 'Reset counter after (min)')
    'SharedWorkstations' = @('Postes partagés', 'Shared workstations'); 'GpoName' = @('Nom de la GPO', 'GPO name')
    'LockAfterMinutes' = @('Verrouiller après (min)', 'Lock after (min)'); 'SleepAfterMinutes' = @('Mise en veille après (min)', 'Sleep after (min)')
    'PasswordOnWake' = @('Mot de passe au réveil', 'Password on wake'); 'LocalAdmins' = @('Administrateurs locaux des postes', 'Workstation local admins')
    'Group' = @('Groupe', 'Group'); 'Mode' = @('Mode (Exclusive / Add)', 'Mode (Exclusive / Add)'); 'ExtraMembers' = @('Membres supplémentaires', 'Extra members')
    'AccountName' = @('Compte local géré', 'Managed local account'); 'ReadersGroup' = @('Groupe autorisé à lire', 'Readers group')
    'PasswordLength' = @('Longueur du mot de passe', 'Password length'); 'PasswordComplexity' = @('Complexité (1-4)', 'Complexity (1-4)')
    'PasswordAgeDays' = @('Changement tous les (jours)', 'Rotate every (days)'); 'EncryptPasswords' = @('Chiffrer dans AD', 'Encrypt in AD')
    'PostAuthenticationActions' = @('Action après usage (1/3/5)', 'Action after use (1/3/5)')
    'PostAuthenticationResetDelayHours' = @('Délai avant action (heures)', 'Delay before action (hours)')
    'InstallRole' = @('Installer le rôle DHCP (sans le configurer)', 'Install the DHCP role (not configured)')
    'Configure' = @('Configurer DHCP (étape 5 - à réécrire avant usage)', 'Configure DHCP (step 5 - to be rewritten first)')
    'ComputerSubOUs' = @('Sous-OU de Postes', 'Postes sub-OUs'); 'Members' = @('Membres', 'Members')
    'ChangePasswordAtLogon' = @('Changer le mdp à la 1re connexion', 'Change pwd at first logon')
    'PasswordNeverExpires' = @("Mot de passe n'expire jamais", 'Password never expires')
    'AlwaysOn' = @('Postes toujours actifs (ni verrouillage, ni veille)', 'Always-on workstations (no lock, no sleep)')
    'SubOU' = @('Sous-OU de Postes concernée', 'Postes sub-OU')
    'ServerRemoteDesktop' = @('Bureau à distance vers le serveur', 'Remote Desktop to the server')
    'Install' = @('Installer', 'Install'); 'DownloadUrl' = @('URL de téléchargement', 'Download URL'); 'InstallFolder' = @("Dossier de l'ISO / installation", 'ISO / install folder')
    'InstanceName' = @("Nom d'instance", 'Instance name'); 'SAPassword' = @('Mot de passe sa', 'sa password'); 'DataFolder' = @('Dossier des données', 'Data folder')
    'InstallSSMS' = @('Installer SSMS', 'Install SSMS'); 'SSMSUrl' = @('URL SSMS', 'SSMS URL')
    'SourceRoot' = @('Source (clé USB)', 'Source (USB key)'); 'DestinationRoot' = @('Destination (disque)', 'Destination (disk)')
    'Folders' = @('Dossiers à copier', 'Folders to copy'); 'ExcludeFiles' = @('Fichiers exclus', 'Excluded files')
    'ApplyNtfs' = @('Appliquer les droits NTFS', 'Apply NTFS rights'); 'Items' = @('Partages', 'Shares')
    'Server' = @('Serveur SQL', 'SQL server'); 'BackupFolder' = @('Dossier des .bak', '.bak folder'); 'Restores' = @('Restaurations', 'Restores')
    'SqlLogin' = @('Connexion SQL', 'SQL login'); 'Create' = @('Créer', 'Create'); 'Name' = @('Nom', 'Name'); 'DbOwnerOf' = @('db_owner de', 'db_owner of')
    'CustomSqlScript' = @('Script SQL personnalisé', 'Custom SQL script'); 'RunTroubleshootUpdate' = @('Réparer Windows Update (étape 0)', 'Repair Windows Update (step 0)')
    'RebootDelaySeconds' = @('Délai avant redémarrage (s)', 'Delay before restart (s)')
}
function L([string]$Key) { if ($KeyLabels.ContainsKey($Key)) { return $KeyLabels[$Key][$script:Lang] } return $Key }

# ============================================================
# Main window
# ============================================================
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1100" Height="760" MinWidth="900" MinHeight="600" WindowStartupLocation="CenterScreen" FontSize="13" Background="#F4F6FA">
  <DockPanel Margin="12">
    <DockPanel DockPanel.Dock="Top" Margin="0,0,0,10">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <Button x:Name="OpenLog" Tag="L:log.open" Padding="12,3" Margin="0,0,16,0"/>
        <TextBlock Tag="L:lang" Margin="0,0,6,0" VerticalAlignment="Center"/>
        <ComboBox x:Name="LangBox" Width="100" SelectedIndex="0"><ComboBoxItem>Français</ComboBoxItem><ComboBoxItem>English</ComboBoxItem></ComboBox>
      </StackPanel>
      <TextBlock Tag="L:app.title" FontSize="20" FontWeight="SemiBold" Foreground="#2B2D6E"/>
    </DockPanel>
    <TabControl x:Name="Tabs">
      <!-- ================= Configuration ================= -->
      <TabItem x:Name="TabConfig" Tag="L:tab.config">
        <DockPanel Margin="8">
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <Button x:Name="CfgReload" Tag="L:cfg.reload" Padding="14,5" Margin="0,0,8,0"/>
              <Button x:Name="CfgSave" Tag="L:cfg.save" Padding="14,5" Background="#4B3FD1" Foreground="White" FontWeight="SemiBold"/>
            </StackPanel>
            <TextBlock Tag="L:cfg.file" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <ComboBox x:Name="CfgFile" Width="190" Margin="0,0,12,0" VerticalAlignment="Center"/>
            <TextBlock x:Name="CfgStatus" VerticalAlignment="Center" Foreground="#555"/>
          </DockPanel>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="270"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <GroupBox Tag="L:cfg.sections" Margin="0,0,8,0">
              <ListBox x:Name="SectionList" BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
            </GroupBox>
            <ScrollViewer Grid.Column="1" VerticalScrollBarVisibility="Auto" Background="White">
              <StackPanel x:Name="CfgPanel" Margin="14"/>
            </ScrollViewer>
          </Grid>
        </DockPanel>
      </TabItem>
      <!-- ================= Deploiement ================= -->
      <TabItem x:Name="TabDeploy" Tag="L:tab.deploy">
        <DockPanel Margin="8">
          <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              <Button x:Name="DepFolder" Tag="L:dep.folder" Padding="14,5" Margin="0,0,8,0"/>
              <Button x:Name="DepReset" Tag="L:dep.reset" Padding="14,5" Margin="0,0,8,0"/>
              <Button x:Name="DepStart" Tag="L:dep.start" Padding="14,5" Background="#4B3FD1" Foreground="White" FontWeight="SemiBold"/>
            </StackPanel>
            <TextBlock x:Name="DepStatus" VerticalAlignment="Center" FontWeight="SemiBold"/>
          </DockPanel>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="430"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <GroupBox Tag="L:dep.steps" Margin="0,0,8,0">
              <DataGrid x:Name="StepGrid" IsReadOnly="True" AutoGenerateColumns="False" HeadersVisibility="Column"
                        CanUserAddRows="False" GridLinesVisibility="Horizontal" BorderThickness="0" Background="White">
                <DataGrid.Columns>
                  <DataGridTextColumn x:Name="ColId" Binding="{Binding Id}" Width="100"/>
                  <DataGridTextColumn x:Name="ColName" Binding="{Binding Name}" Width="*"/>
                  <DataGridTextColumn x:Name="ColStatus" Binding="{Binding Status}" Width="110"/>
                </DataGrid.Columns>
              </DataGrid>
            </GroupBox>
            <GroupBox Grid.Column="1" Tag="L:dep.log">
              <TextBox x:Name="LogBox" IsReadOnly="True" FontFamily="Consolas" FontSize="12" TextWrapping="NoWrap"
                       HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto"
                       Background="#1E1F2B" Foreground="#E6E6F0" BorderThickness="0"/>
            </GroupBox>
          </Grid>
        </DockPanel>
      </TabItem>
      <!-- ================= Administration ================= -->
      <TabItem x:Name="TabAdmin" Tag="L:tab.admin">
        <DockPanel Margin="8">
          <TextBlock x:Name="AdmMessage" DockPanel.Dock="Top" Foreground="#B00020" TextWrapping="Wrap" Margin="0,0,0,8" Visibility="Collapsed"/>
          <GroupBox DockPanel.Dock="Top" Tag="L:adm.laps" Margin="0,0,0,10" x:Name="LapsBox">
            <StackPanel Margin="8">
              <StackPanel Orientation="Horizontal">
                <TextBlock Tag="L:adm.pc" VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBox x:Name="LapsPc" Width="180" CharacterCasing="Upper"/>
                <Button x:Name="LapsShow" Tag="L:adm.show" Padding="12,4" Margin="8,0,0,0"/>
                <Button x:Name="LapsCopy" Tag="L:adm.copy" Padding="12,4" Margin="8,0,0,0"/>
                <Button x:Name="LapsExpire" Tag="L:adm.expire" Padding="12,4" Margin="8,0,0,0"/>
              </StackPanel>
              <TextBox x:Name="LapsResult" IsReadOnly="True" FontFamily="Consolas" FontSize="14" Margin="0,8,0,0" BorderThickness="0" Background="#F4F6FA"/>
            </StackPanel>
          </GroupBox>
          <GroupBox Tag="L:adm.users" x:Name="UsersBox">
            <DockPanel Margin="8">
              <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
                <Button x:Name="UsrRefresh" Tag="L:adm.refresh" Padding="12,4" Margin="0,0,8,0"/>
                <Button x:Name="UsrAdd" Tag="L:adm.add" Padding="12,4" Margin="0,0,8,0"/>
                <Button x:Name="UsrToggle" Tag="L:adm.toggle" Padding="12,4" Margin="0,0,8,0"/>
                <Button x:Name="UsrReset" Tag="L:adm.resetPwd" Padding="12,4" Margin="0,0,8,0"/>
                <Button x:Name="UsrUnlock" Tag="L:adm.unlock" Padding="12,4"/>
              </StackPanel>
              <DataGrid x:Name="UserGrid" IsReadOnly="True" AutoGenerateColumns="False" SelectionMode="Single"
                        CanUserAddRows="False" HeadersVisibility="Column" GridLinesVisibility="Horizontal" Background="White">
                <DataGrid.Columns>
                  <DataGridTextColumn x:Name="UColUser" Binding="{Binding Username}" Width="130"/>
                  <DataGridTextColumn x:Name="UColName" Binding="{Binding Name}" Width="*"/>
                  <DataGridTextColumn x:Name="UColRole" Binding="{Binding Role}" Width="130"/>
                  <DataGridCheckBoxColumn x:Name="UColEnabled" Binding="{Binding Enabled}" Width="70"/>
                  <DataGridCheckBoxColumn x:Name="UColLocked" Binding="{Binding Locked}" Width="90"/>
                  <DataGridTextColumn x:Name="UColLogon" Binding="{Binding LastLogon}" Width="150"/>
                </DataGrid.Columns>
              </DataGrid>
            </DockPanel>
          </GroupBox>
        </DockPanel>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
    $n = $_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
    $ui[$n.Value] = $win.FindName($n.Value)
}
Write-GuiLog "Window   : built, controls found: $($ui.Count), missing: $(@($ui.Keys | Where-Object { -not $ui[$_] }) -join ',')"
# Exceptions WPF itself raises (bindings, layout) would otherwise close the app silently.
$win.Dispatcher.add_UnhandledException({
    Write-GuiLog ("UI exception: " + $_.Exception.ToString()) 'ERROR'
    $_.Handled = $true
})
$win.add_Closed({ Write-GuiLog '==================== Console.ps1 CLOSED ===================' })
$ui.OpenLog.add_Click({ Start-Process notepad.exe $script:GuiLog })

# ============================================================
# Language
# ============================================================
function Update-Texts {
    param($Node)
    if ($Node -is [System.Windows.FrameworkElement] -and $Node.Tag -is [string] -and $Node.Tag.StartsWith('L:')) {
        $t = T $Node.Tag.Substring(2)
        if ($Node -is [System.Windows.Controls.HeaderedContentControl]) { $Node.Header = $t }
        elseif ($Node -is [System.Windows.Controls.ContentControl]) { $Node.Content = $t }
        elseif ($Node -is [System.Windows.Controls.TextBlock]) { $Node.Text = $t }
    }
    foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($Node)) {
        if ($c -is [System.Windows.DependencyObject]) { Update-Texts $c }
    }
}
function Set-Language {
    param([int]$Index)
    Save-Grids
    $script:Lang = $Index
    Update-Texts $win
    $win.Title = T 'app.title'
    $ui.ColId.Header = T 'col.id'; $ui.ColName.Header = T 'col.name'; $ui.ColStatus.Header = T 'col.status'
    $ui.UColUser.Header = T 'u.username'; $ui.UColName.Header = T 'u.name'; $ui.UColRole.Header = T 'u.role'
    $ui.UColEnabled.Header = T 'u.enabled'; $ui.UColLocked.Header = T 'u.locked'; $ui.UColLogon.Header = T 'u.lastLogon'
    Show-SectionList
    $script:LastLogLength = -1   # re-render step status words
    Update-Deploy
}

function Show-Message {
    param([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK')
    # An owner that is not shown yet (startup prompts) makes MessageBox fail.
    if ($win.IsLoaded) { return [System.Windows.MessageBox]::Show($win, $Text, (T 'app.title'), $Buttons, $Icon) }
    return [System.Windows.MessageBox]::Show($Text, (T 'app.title'), $Buttons, $Icon)
}

# ============================================================
# CONFIGURATION TAB
# ============================================================
$script:Cfg   = $null
$script:Kinds = @{}          # "Section.Key" -> bool | num | str | list | obj | objlist
$script:Grids = @()          # open table editors, flushed back into $Cfg before save

function Get-Kind {
    param($Value)
    if ($null -eq $Value) { return 'str' }
    if ($Value -is [bool]) { return 'bool' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return 'num' }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return 'obj' }
    if ($Value -is [array]) {
        if (@($Value | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] }).Count) { return 'objlist' }
        return 'list'
    }
    return 'str'
}

# Remember every value's type once, at load time.
function Register-Kinds {
    param($Obj, [string]$Path)
    foreach ($p in $Obj.PSObject.Properties) {
        $full = if ($Path) { "$Path.$($p.Name)" } else { $p.Name }
        $kind = Get-Kind $p.Value
        $script:Kinds[$full] = $kind
        if ($kind -eq 'obj') { Register-Kinds -Obj $p.Value -Path $full }
        if ($kind -eq 'objlist') {
            foreach ($row in @($p.Value)) {
                foreach ($c in $row.PSObject.Properties) {
                    $k = "$full[].$($c.Name)"
                    if (-not $script:Kinds.ContainsKey($k) -or $script:Kinds[$k] -eq 'str' -and $null -ne $c.Value) { $script:Kinds[$k] = Get-Kind $c.Value }
                }
            }
        }
    }
}

function Import-Config {
    if (-not (Test-Path $ConfigPath)) {
        if ((Show-Message (T 'cfg.missing') 'Question' 'YesNo') -ne 'Yes') { return }
        Copy-Item $SamplePath $ConfigPath
    }
    try {
        $script:Cfg = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $script:Cfg = $null
        Write-GuiLog ("Config load failed - " + (Format-Err $_)) 'ERROR'
        Show-Message ((T 'cfg.parseError') + $_.Exception.Message) 'Error' | Out-Null
        return
    }
    $script:Kinds = @{}
    Register-Kinds -Obj $script:Cfg -Path ''
    $ui.CfgStatus.Text = (T 'cfg.loaded') + $ConfigPath
    Write-GuiLog "Config   : loaded $ConfigPath, $(@($script:Cfg.PSObject.Properties).Count) sections, $($script:Kinds.Count) fields"
    Show-SectionList
}

function Show-SectionList {
    $sel = $ui.SectionList.SelectedIndex
    $ui.SectionList.Items.Clear()
    if (-not $script:Cfg) { $ui.CfgPanel.Children.Clear(); return }
    foreach ($p in $script:Cfg.PSObject.Properties) {
        if ($p.Name -like '_comment*') { continue }
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = L $p.Name
        $item.Tag = $p.Name
        $item.Padding = '6,4'
        [void]$ui.SectionList.Items.Add($item)
    }
    $ui.SectionList.SelectedIndex = [Math]::Max(0, $sel)
}

function New-HelpText {
    param([string]$Text)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text; $tb.TextWrapping = 'Wrap'; $tb.FontStyle = 'Italic'
    $tb.Foreground = '#6A6F85'; $tb.Margin = '0,2,0,8'; $tb.FontSize = 12
    return $tb
}

function New-FieldRow {
    param([string]$Label, $Control)
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = '0,3'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = '250'
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    $lb = New-Object System.Windows.Controls.TextBlock
    $lb.Text = $Label; $lb.VerticalAlignment = 'Center'; $lb.TextWrapping = 'Wrap'
    [System.Windows.Controls.Grid]::SetColumn($Control, 1)
    [void]$g.Children.Add($lb); [void]$g.Children.Add($Control)
    return $g
}

# A text field's value back into the config object, typed by its remembered kind.
function Set-FieldValue {
    param($Obj, [string]$Key, [string]$Kind, [string]$Text)
    switch ($Kind) {
        'num' {
            $n = 0; $d = 0.0
            if ($Text.Trim() -eq '') { $Obj.$Key = '' }
            elseif ([int]::TryParse($Text.Trim(), [ref]$n)) { $Obj.$Key = $n }
            elseif ([double]::TryParse($Text.Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { $Obj.$Key = $d }
            else { $Obj.$Key = $Text }   # flagged by Test-Config
        }
        'list' {
            $items = @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            $Obj.$Key = [object[]]$items
        }
        default { $Obj.$Key = $Text }
    }
}

function Add-Fields {
    param($Panel, $Obj, [string]$Path)
    foreach ($p in $Obj.PSObject.Properties) {
        $key  = $p.Name
        $full = "$Path.$key"   # not $path: PowerShell names are case-insensitive, it would overwrite $Path
        if ($key -like '_comment*') { [void]$Panel.Children.Add((New-HelpText "$($p.Value)")); continue }
        $kind = if ($script:Kinds.ContainsKey($full)) { $script:Kinds[$full] } else { Get-Kind $p.Value }
        $ctx  = @{ Obj = $Obj; Key = $key; Kind = $kind; Path = $full }

        switch ($kind) {
            'obj' {
                $gb = New-Object System.Windows.Controls.GroupBox
                $gb.Header = L $key; $gb.Margin = '0,8,0,4'; $gb.Padding = '8'
                $sp = New-Object System.Windows.Controls.StackPanel
                Add-Fields -Panel $sp -Obj $p.Value -Path $full
                $gb.Content = $sp
                [void]$Panel.Children.Add($gb)
            }
            'objlist' {
                $gb = New-Object System.Windows.Controls.GroupBox
                $gb.Header = L $key; $gb.Margin = '0,8,0,4'; $gb.Padding = '6'
                $sp = New-Object System.Windows.Controls.StackPanel
                [void]$sp.Children.Add((New-HelpText (T 'cfg.gridHelp')))
                $sp.Children.Add((New-TableEditor -Ctx $ctx -Rows @($p.Value))) | Out-Null
                $gb.Content = $sp
                [void]$Panel.Children.Add($gb)
            }
            'bool' {
                $cb = New-Object System.Windows.Controls.CheckBox
                $cb.IsChecked = [bool]$p.Value; $cb.Tag = $ctx; $cb.VerticalAlignment = 'Center'
                $cb.add_Click({ $this.Tag.Obj.($this.Tag.Key) = [bool]$this.IsChecked })
                [void]$Panel.Children.Add((New-FieldRow (L $key) $cb))
            }
            'list' {
                $tb = New-Object System.Windows.Controls.TextBox
                $tb.AcceptsReturn = $true; $tb.MinHeight = 54; $tb.TextWrapping = 'NoWrap'
                $tb.Text = (@($p.Value) -join "`r`n"); $tb.Tag = $ctx; $tb.ToolTip = T 'cfg.listHelp'
                $tb.add_TextChanged({ Set-FieldValue -Obj $this.Tag.Obj -Key $this.Tag.Key -Kind 'list' -Text $this.Text })
                [void]$Panel.Children.Add((New-FieldRow (L $key) $tb))
            }
            default {
                if ($key -match 'Password$') {
                    $pb = New-Object System.Windows.Controls.PasswordBox
                    $pb.Password = "$($p.Value)"; $pb.Tag = $ctx; $pb.Padding = '2'
                    $pb.add_PasswordChanged({ $this.Tag.Obj.($this.Tag.Key) = $this.Password })
                    [void]$Panel.Children.Add((New-FieldRow (L $key) $pb))
                }
                else {
                    $tb = New-Object System.Windows.Controls.TextBox
                    $tb.Text = "$($p.Value)"; $tb.Tag = $ctx; $tb.Padding = '2'
                    if ($kind -eq 'num') { $tb.Width = 120; $tb.HorizontalAlignment = 'Left' }
                    $tb.add_TextChanged({ Set-FieldValue -Obj $this.Tag.Obj -Key $this.Tag.Key -Kind $this.Tag.Kind -Text $this.Text })
                    [void]$Panel.Children.Add((New-FieldRow (L $key) $tb))
                }
            }
        }
    }
}

# Array of objects -> editable DataTable (one column per property).
function New-TableEditor {
    param($Ctx, $Rows)
    $table = New-Object System.Data.DataTable
    $cols  = New-Object System.Collections.Generic.List[string]
    foreach ($r in $Rows) { foreach ($c in $r.PSObject.Properties) { if (-not $cols.Contains($c.Name)) { $cols.Add($c.Name) } } }
    foreach ($c in $script:Kinds.Keys) {
        if ($c.StartsWith("$($Ctx.Path)[].")) { $n = $c.Substring($Ctx.Path.Length + 3); if (-not $cols.Contains($n)) { $cols.Add($n) } }
    }
    $colKinds = @{}
    foreach ($c in $cols) {
        $k = $script:Kinds["$($Ctx.Path)[].$c"]; if (-not $k) { $k = 'str' }
        $colKinds[$c] = $k
        [void]$table.Columns.Add($c, $(if ($k -eq 'bool') { [bool] } else { [string] }))
    }
    foreach ($r in $Rows) {
        $dr = $table.NewRow()
        foreach ($c in $cols) {
            $v = $r.$c
            if ($null -eq $v) { continue }
            if ($colKinds[$c] -eq 'bool') { $dr[$c] = [bool]$v }
            elseif ($v -is [array]) { $dr[$c] = (@($v) -join '; ') }
            else { $dr[$c] = "$v" }
        }
        $table.Rows.Add($dr)
    }
    $table.AcceptChanges()

    $grid = New-Object System.Windows.Controls.DataGrid
    $grid.AutoGenerateColumns = $true; $grid.CanUserAddRows = $true; $grid.CanUserDeleteRows = $true
    $grid.HeadersVisibility = 'Column'; $grid.MinHeight = 80; $grid.MaxHeight = 360
    $grid.ItemsSource = $table.DefaultView
    $grid.add_AutoGeneratingColumn({ $_.Column.Header = L "$($_.PropertyName)" })
    $script:Grids += @{ Ctx = $Ctx; Table = $table; Kinds = $colKinds; Grid = $grid }
    return $grid
}

# Write every open table back into $Cfg (called before save / section switch / language).
function Save-Grids {
    foreach ($g in $script:Grids) {
        try { [void]$g.Grid.CommitEdit('Row', $true) } catch {}
        $list = @()
        foreach ($dr in $g.Table.Rows) {
            if ($dr.RowState -eq 'Deleted' -or $dr.RowState -eq 'Detached') { continue }
            $o = [ordered]@{}
            $empty = $true
            foreach ($col in $g.Table.Columns) {
                $name = $col.ColumnName; $raw = $dr[$name]
                $kind = $g.Kinds[$name]
                if ($raw -is [DBNull]) { $raw = $null }
                # A checkbox never set in this row stays absent, so the step's default applies
                # (ChangePasswordAtLogon missing = true; writing false would break step 8).
                if ($kind -eq 'bool' -and $null -eq $raw) { continue }
                if ($null -ne $raw -and "$raw" -ne '' -and -not ($kind -eq 'bool' -and -not $raw)) { $empty = $false }
                switch ($kind) {
                    'bool' { $o[$name] = [bool]$raw }
                    'num'  { $n = 0; $o[$name] = $(if ([int]::TryParse("$raw", [ref]$n)) { $n } else { "$raw" }) }
                    'list' { $o[$name] = [object[]]@("$raw" -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) }
                    default { $o[$name] = "$raw" }
                }
            }
            if (-not $empty) { $list += [pscustomobject]$o }
        }
        $g.Ctx.Obj.($g.Ctx.Key) = [object[]]$list
    }
}

function Show-Section {
    param([string]$Name)
    Save-Grids
    $script:Grids = @()
    $ui.CfgPanel.Children.Clear()
    if (-not $script:Cfg -or -not $Name) { return }
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = L $Name; $title.FontSize = 18; $title.FontWeight = 'SemiBold'; $title.Margin = '0,0,0,8'; $title.Foreground = '#2B2D6E'
    [void]$ui.CfgPanel.Children.Add($title)
    Add-Fields -Panel $ui.CfgPanel -Obj $script:Cfg.$Name -Path $Name
}

function Test-IPv4 { param([string]$V) return ($V -match '^(\d{1,3}\.){3}\d{1,3}$' -and ($V -split '\.' | Where-Object { [int]$_ -gt 255 }).Count -eq 0) }

function Test-Config {
    $errors = New-Object System.Collections.Generic.List[string]
    $c = $script:Cfg
    $seen = @{}   # usernames, also used by the Remote Desktop check
    foreach ($k in 'IPAddress', 'SubnetMask', 'Gateway') {
        if (-not (Test-IPv4 "$($c.Network.$k)")) { $errors.Add("Network.$($k) : '$($c.Network.$k)'") }
    }
    foreach ($k in 'PrimaryDNS', 'SecondaryDNS') {
        $v = "$($c.Network.$k)"; if ($v -and -not (Test-IPv4 $v)) { $errors.Add("Network.$($k) : '$v'") }
    }
    if ("$($c.Network.Hostname)" -notmatch '^[A-Za-z0-9-]{1,15}$') { $errors.Add("Network.Hostname : '$($c.Network.Hostname)' (1-15 A-Z 0-9 -)") }
    foreach ($f in @($c.DNS.Forwarders)) { if ($f -and -not (Test-IPv4 "$f")) { $errors.Add("DNS.Forwarders : '$f'") } }
    if ($c.DNS.SecondaryDNS -and -not (Test-IPv4 "$($c.DNS.SecondaryDNS)")) { $errors.Add("DNS.SecondaryDNS : '$($c.DNS.SecondaryDNS)'") }
    if ($c.Directory) {
        $roles = @($c.Directory.Roles | ForEach-Object { $_.Name })
        foreach ($u in @($c.Directory.Users)) {
            if (-not $u.Username) { $errors.Add("Directory.Users : $(T 'u.username') ?"); continue }
            if ($seen.ContainsKey($u.Username)) { $errors.Add("Directory.Users : '$($u.Username)' x2") }
            $seen[$u.Username] = 1
            if ($roles -notcontains $u.Role) { $errors.Add("Directory.Users : '$($u.Username)' -> $(T 'u.role') '$($u.Role)' ?") }
            # Same rule as step 8: no shared initial password on an account that never changes it.
            if ($u.ChangePasswordAtLogon -eq $false -and -not $u.Password) { $errors.Add("Directory.Users : '$($u.Username)' -> $(T 'cfg.needOwnPwd')") }
        }
        if (-not $c.Directory.InitialPassword) { $errors.Add("Directory.InitialPassword : (vide / empty)") }
    }
    if ($c.Policy.ServerRemoteDesktop.Enabled -eq $true) {
        foreach ($n in @($c.Policy.ServerRemoteDesktop.Users)) {
            if ($n -and -not $seen.ContainsKey($n)) { $errors.Add("Policy.ServerRemoteDesktop.Users : '$n' $(T 'cfg.notInUsers')") }
        }
    }
    if ($c.Policy.AlwaysOn.Enabled -eq $true -and @($c.Directory.ComputerSubOUs) -notcontains $c.Policy.AlwaysOn.SubOU) {
        $errors.Add("Policy.AlwaysOn.SubOU : '$($c.Policy.AlwaysOn.SubOU)' $(T 'cfg.notInSubOUs')")
    }
    if ($c.DHCP.Configure -eq $true -or $c.DHCP.Enabled -eq $true) { $errors.Add("DHCP.Configure : $(T 'cfg.dhcpConfigure')") }
    # Numbers typed as text.
    foreach ($path in $script:Kinds.Keys) {
        if ($script:Kinds[$path] -ne 'num' -or $path -like '*`[`]*') { continue }
        $o = $c; $parts = $path -split '\.'
        foreach ($p in $parts[0..($parts.Count - 2)]) { $o = $o.$p }
        $v = $o.($parts[-1])
        if ($v -is [string] -and $v -ne '') { $errors.Add("$path : '$v'") }
    }
    return ,$errors
}

function Save-Config {
    if (-not $script:Cfg) { return }
    Save-Grids
    $errors = Test-Config
    if ($errors.Count -gt 0) {
        Write-GuiLog "Config   : validation found $($errors.Count) problem(s): $($errors -join ' ; ')" 'WARN'
        $msg = (T 'cfg.errors') + "`n`n- " + ($errors -join "`n- ") + "`n`n" + (T 'cfg.saveAnyway')
        if ((Show-Message $msg 'Warning' 'YesNo') -ne 'Yes') { return }
    }
    if (Test-Path $ConfigPath) { Copy-Item $ConfigPath "$ConfigPath.bak" -Force }
    $json = $script:Cfg | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding $true))
    $ui.CfgStatus.Text = T 'cfg.saved'
    Write-GuiLog "Config   : saved $ConfigPath ($($json.Length) chars)"
}

$ui.SectionList.add_SelectionChanged({ Invoke-Logged 'SectionList.SelectionChanged' {
    $item = $ui.SectionList.SelectedItem
    if ($item) { Show-Section $item.Tag }
} })
# Config file picker: config.json (production) or another config*.json next to it
# (e.g. config.lab.json). Edit, save and deploy all use the selected file.
function Update-ConfigFiles {
    $names = @(Get-ChildItem $Root -Filter 'config*.json' -File | Where-Object { $_.Extension -eq '.json' -and $_.Name -ne 'config.sample.json' } | ForEach-Object { $_.Name })
    if ($names -notcontains 'config.json') { $names = @('config.json') + $names }
    $script:FillingFiles = $true
    try {
        $ui.CfgFile.Items.Clear()
        foreach ($n in $names) { [void]$ui.CfgFile.Items.Add($n) }
        $ui.CfgFile.SelectedItem = Split-Path $script:ConfigPath -Leaf
    }
    finally { $script:FillingFiles = $false }
}
$ui.CfgFile.add_SelectionChanged({
    if ($script:FillingFiles -or -not $ui.CfgFile.SelectedItem) { return }
    Invoke-Logged "CfgFile $($ui.CfgFile.SelectedItem)" {
        Save-Grids
        $script:ConfigPath = Join-Path $Root $ui.CfgFile.SelectedItem
        $script:Grids = @()
        Import-Config
    }
})
$ui.CfgReload.add_Click({ Invoke-Logged 'CfgReload.Click' { $script:Grids = @(); Update-ConfigFiles; Import-Config } })
$ui.CfgSave.add_Click({ Invoke-Logged 'CfgSave.Click' { Save-Config } })

# ============================================================
# DEPLOYMENT TAB
# ============================================================
$script:Steps = New-Object System.Data.DataTable
foreach ($c in 'Id', 'Name', 'Status') { [void]$script:Steps.Columns.Add($c, [string]) }
# Step list comes from Deploy.ps1 itself, so it never drifts from the real plan.
foreach ($m in [regex]::Matches((Get-Content $DeployScript -Raw), 'Id = "([^"]+)"; Name = "([^"]+)"')) {
    $r = $script:Steps.NewRow(); $r.Id = $m.Groups[1].Value; $r.Name = $m.Groups[2].Value; $script:Steps.Rows.Add($r)
}
$ui.StepGrid.ItemsSource = $script:Steps.DefaultView
$script:LastLogLength = -1
$script:DeployProc = $null

function Read-TextShared {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return '' }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try { $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::Default); return $sr.ReadToEnd() }
    finally { $fs.Dispose() }
}

function Test-DeployRunning {
    if ($script:DeployProc -and -not $script:DeployProc.HasExited) { return $true }
    $p = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
         Where-Object { $_.CommandLine -like '*Deploy.ps1*' -and $_.CommandLine -notlike '*-Reset*' }
    return [bool]$p
}

function Update-Deploy {
    $running = Test-DeployRunning
    $ui.DepStatus.Text = $(if ($running) { T 'dep.running' } else { T 'dep.idle' })
    $ui.DepStatus.Foreground = $(if ($running) { '#1B7F3B' } else { '#555' })
    $ui.DepStart.IsEnabled = -not $running
    $ui.DepReset.IsEnabled = -not $running

    $len = if (Test-Path $LogPath) { (Get-Item $LogPath).Length } else { 0 }
    if ($len -eq $script:LastLogLength) { return }
    $script:LastLogLength = $len

    $log = Read-TextShared $LogPath
    $cut = $log.LastIndexOf('State and resume task cleared')
    $recent = if ($cut -ge 0) { $log.Substring($cut) } else { $log }

    $status = @{}
    foreach ($line in $recent -split "`r?`n") {
        if ($line -match '>>> Running (\S+):') { $status[$Matches[1]] = 'running' }
        elseif ($line -match '<<< (\S+) completed') { $status[$Matches[1]] = 'done' }
        elseif ($line -match '<<< (\S+) FAILED') { $status[$Matches[1]] = 'failed' }
        elseif ($line -match 'SKIP (\S+) \(.*disabled in config') { $status[$Matches[1]] = 'skipped' }
    }
    $done = @()
    if (Test-Path $StatePath) {
        try { $done = @((Get-Content $StatePath -Raw | ConvertFrom-Json).CompletedSteps) } catch {}
    }
    foreach ($r in $script:Steps.Rows) {
        $s = if ($done -contains $r.Id) { 'done' } elseif ($status.ContainsKey($r.Id)) { $status[$r.Id] } else { 'pending' }
        if ($s -eq 'running' -and -not $running) { $s = 'failed' }
        $r.Status = T "st.$s"
    }

    $lines = $log -split "`r?`n"
    $ui.LogBox.Text = ($lines | Select-Object -Last 400) -join "`r`n"
    $ui.LogBox.ScrollToEnd()
}

$ui.DepStart.add_Click({ Invoke-Logged 'DepStart.Click' {
    if (-not (Test-Path $ConfigPath)) { Show-Message (T 'dep.noConfig') 'Warning' | Out-Null; return }
    if ((Show-Message ((T 'dep.file') + (Split-Path $ConfigPath -Leaf) + "`n`n" + (T 'dep.confirm')) 'Question' 'YesNo') -ne 'Yes') { return }
    # -NonInteractive: the window is hidden, so a command asking a question must fail, not wait forever.
    $script:DeployProc = Start-Process powershell.exe -WindowStyle Hidden -WorkingDirectory $Root -PassThru `
        -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$DeployScript`" -Config `"$ConfigPath`""
    Write-GuiLog "Deploy   : started Deploy.ps1 -Config $ConfigPath, PID $($script:DeployProc.Id)"
    Update-Deploy
} })
$ui.DepReset.add_Click({ Invoke-Logged 'DepReset.Click' {
    if ((Show-Message (T 'dep.confirmReset') 'Warning' 'YesNo') -ne 'Yes') { return }
    Start-Process powershell.exe -WindowStyle Hidden -Wait -WorkingDirectory $Root `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$DeployScript`" -Reset"
    $script:LastLogLength = -1
    Update-Deploy
} })
$ui.DepFolder.add_Click({ Invoke-Logged 'DepFolder.Click' { Start-Process explorer.exe $Root } })

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(3)
$timer.add_Tick({ Invoke-Logged 'Timer.Tick' -Quiet { if ($ui.Tabs.SelectedItem -eq $ui.TabDeploy) { Update-Deploy } } })
$timer.Start()

# ============================================================
# ADMINISTRATION TAB (needs the ActiveDirectory module: the DC)
# ============================================================
$script:AdReady = $null
function Initialize-Admin {
    if ($null -ne $script:AdReady) { return $script:AdReady }
    try { Import-Module ActiveDirectory -ErrorAction Stop; $script:AdReady = $true }
    catch {
        Write-GuiLog ("Admin    : ActiveDirectory module not loaded - " + (Format-Err $_)) 'WARN'
        $script:AdReady = $false
        $ui.AdmMessage.Text = T 'adm.noAD'; $ui.AdmMessage.Visibility = 'Visible'
        $ui.LapsBox.IsEnabled = $false; $ui.UsersBox.IsEnabled = $false
    }
    if ($script:AdReady) { Update-Users }
    return $script:AdReady
}

function Get-UsersOuDN {
    $ouName = if ($script:Cfg -and $script:Cfg.Directory -and $script:Cfg.Directory.OUs.Users) { $script:Cfg.Directory.OUs.Users } else { 'Utilisateurs' }
    return "OU=$ouName,$((Get-ADDomain).DistinguishedName)"
}

function Update-Users {
    try {
        $t = New-Object System.Data.DataTable
        foreach ($c in 'Username', 'Name', 'Role', 'LastLogon') { [void]$t.Columns.Add($c, [string]) }
        foreach ($c in 'Enabled', 'Locked') { [void]$t.Columns.Add($c, [bool]) }
        Get-ADUser -SearchBase (Get-UsersOuDN) -Filter * -Properties Department, LockedOut, LastLogonDate -ErrorAction Stop |
            Sort-Object SamAccountName | ForEach-Object {
                $r = $t.NewRow()
                $r.Username = $_.SamAccountName; $r.Name = $_.Name; $r.Role = $_.Department
                $r.LastLogon = $(if ($_.LastLogonDate) { $_.LastLogonDate.ToString('g') } else { '' })
                $r.Enabled = [bool]$_.Enabled; $r.Locked = [bool]$_.LockedOut
                $t.Rows.Add($r)
            }
        $ui.UserGrid.ItemsSource = $t.DefaultView
        Write-GuiLog "Admin    : $($t.Rows.Count) users listed from $(Get-UsersOuDN)"
    }
    catch { Write-GuiLog (Format-Err $_) 'ERROR'; Show-Message $_.Exception.Message 'Error' | Out-Null }
}

function Get-SelectedUser {
    $row = $ui.UserGrid.SelectedItem
    if (-not $row) { Show-Message (T 'adm.select') 'Information' | Out-Null; return $null }
    return $row['Username']
}

# Small modal form built from field specs: @{ Key; Label; Type = text|password|combo|check; Value; Items }
function Show-Form {
    param([string]$Title, [array]$Fields)
    $w = New-Object System.Windows.Window
    $w.Title = $Title; $w.Owner = $win; $w.Width = 460; $w.SizeToContent = 'Height'
    $w.WindowStartupLocation = 'CenterOwner'; $w.ResizeMode = 'NoResize'; $w.FontSize = 13
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Margin = '16'
    $controls = @{}
    foreach ($f in $Fields) {
        switch ($f.Type) {
            'password' { $c = New-Object System.Windows.Controls.PasswordBox; $c.Password = "$($f.Value)" }
            'combo'    { $c = New-Object System.Windows.Controls.ComboBox; foreach ($i in $f.Items) { [void]$c.Items.Add($i) }; $c.SelectedIndex = 0 }
            'check'    { $c = New-Object System.Windows.Controls.CheckBox; $c.IsChecked = [bool]$f.Value; $c.Content = $f.Label }
            default    { $c = New-Object System.Windows.Controls.TextBox; $c.Text = "$($f.Value)" }
        }
        $controls[$f.Key] = $c
        if ($f.Type -eq 'check') { $c.Margin = '0,8,0,0'; [void]$sp.Children.Add($c) }
        else {
            $c.Margin = '0,2,0,6'; $c.Padding = '2'
            $lb = New-Object System.Windows.Controls.TextBlock; $lb.Text = $f.Label
            [void]$sp.Children.Add($lb); [void]$sp.Children.Add($c)
        }
    }
    $btns = New-Object System.Windows.Controls.StackPanel; $btns.Orientation = 'Horizontal'; $btns.HorizontalAlignment = 'Right'; $btns.Margin = '0,14,0,0'
    $ok = New-Object System.Windows.Controls.Button; $ok.Content = T 'ok'; $ok.Padding = '18,5'; $ok.Margin = '0,0,8,0'; $ok.IsDefault = $true
    $cancel = New-Object System.Windows.Controls.Button; $cancel.Content = T 'cancel'; $cancel.Padding = '18,5'; $cancel.IsCancel = $true
    $ok.add_Click({ $w.DialogResult = $true })
    [void]$btns.Children.Add($ok); [void]$btns.Children.Add($cancel); [void]$sp.Children.Add($btns)
    $w.Content = $sp
    if (-not $w.ShowDialog()) { return $null }
    $result = @{}
    foreach ($f in $Fields) {
        $c = $controls[$f.Key]
        $result[$f.Key] = switch ($f.Type) { 'password' { $c.Password } 'combo' { $c.SelectedItem } 'check' { [bool]$c.IsChecked } default { $c.Text.Trim() } }
    }
    return $result
}

$ui.LapsShow.add_Click({ Invoke-Logged 'LapsShow.Click' {
    $pc = $ui.LapsPc.Text.Trim(); if (-not $pc) { return }
    if (-not (Get-Command Get-LapsADPassword -ErrorAction SilentlyContinue)) { $ui.LapsResult.Text = T 'adm.noLaps'; return }
    try {
        $r = Get-LapsADPassword -Identity $pc -AsPlainText -ErrorAction Stop
        if (-not $r -or -not $r.Password) { Write-GuiLog "LAPS     : no password stored for $pc" 'WARN'; $ui.LapsResult.Text = T 'adm.lapsNone'; return }
        Write-GuiLog "LAPS     : password read for $pc (account $($r.Account), expires $($r.ExpirationTimestamp))"
        $ui.LapsResult.Text = "$($r.Account)   $($r.Password)   (expire : $($r.ExpirationTimestamp))"
        $script:LapsPassword = $r.Password
    }
    catch { Write-GuiLog (Format-Err $_) 'ERROR'; $ui.LapsResult.Text = $_.Exception.Message }
} })
$ui.LapsCopy.add_Click({ Invoke-Logged 'LapsCopy.Click' { if ($script:LapsPassword) { [System.Windows.Clipboard]::SetText($script:LapsPassword) } } })
$ui.LapsExpire.add_Click({ Invoke-Logged 'LapsExpire.Click' {
    $pc = $ui.LapsPc.Text.Trim(); if (-not $pc) { return }
    try { Set-LapsADPasswordExpirationTime -Identity $pc -ErrorAction Stop; $ui.LapsResult.Text = T 'adm.expireOk' }
    catch { Write-GuiLog (Format-Err $_) 'ERROR'; $ui.LapsResult.Text = $_.Exception.Message }
} })

$ui.UsrRefresh.add_Click({ Invoke-Logged 'UsrRefresh.Click' { Update-Users } })
$ui.UsrAdd.add_Click({ Invoke-Logged 'UsrAdd.Click' {
    if (-not $script:Cfg -or -not $script:Cfg.Directory -or -not @($script:Cfg.Directory.Roles).Count) { Show-Message (T 'adm.noRoles') 'Warning' | Out-Null; return }
    $dir = $script:Cfg.Directory
    $f = Show-Form -Title (T 'u.newUser') -Fields @(
        @{ Key = 'Username'; Label = T 'u.username'; Type = 'text' }
        @{ Key = 'First'; Label = T 'u.first'; Type = 'text' }
        @{ Key = 'Last'; Label = T 'u.last'; Type = 'text' }
        @{ Key = 'Role'; Label = T 'u.role'; Type = 'combo'; Items = @($dir.Roles | ForEach-Object { $_.Name }) }
        @{ Key = 'Title'; Label = T 'u.title'; Type = 'text' }
        @{ Key = 'Password'; Label = T 'u.password'; Type = 'password'; Value = $dir.InitialPassword }
        @{ Key = 'MustChange'; Label = T 'u.mustChange'; Type = 'check'; Value = $true }
    )
    if (-not $f -or -not $f.Username) { return }
    try {
        # Same placement as deploy step 8: OU=<Role>,OU=Utilisateurs + role group.
        $role = @($dir.Roles | Where-Object { $_.Name -eq $f.Role })[0]
        $ou   = "OU=$($role.Name),$(Get-UsersOuDN)"
        $name = "$($f.First) $($f.Last)".Trim(); if (-not $name) { $name = $f.Username }
        New-ADUser -SamAccountName $f.Username -UserPrincipalName "$($f.Username)@$((Get-ADDomain).DNSRoot)" `
            -Name $name -DisplayName $name -GivenName $f.First -Surname $f.Last `
            -Department $role.Name -Title $f.Title -Path $ou -Enabled $true `
            -AccountPassword (ConvertTo-SecureString $f.Password -AsPlainText -Force) `
            -ChangePasswordAtLogon $f.MustChange -ErrorAction Stop
        Add-ADGroupMember -Identity $role.Group -Members $f.Username -ErrorAction Stop
        Update-Users
        Show-Message (T 'adm.done') | Out-Null
    }
    catch { Write-GuiLog (Format-Err $_) 'ERROR'; Show-Message $_.Exception.Message 'Error' | Out-Null }
} })
$ui.UsrToggle.add_Click({ Invoke-Logged 'UsrToggle.Click' {
    $u = Get-SelectedUser; if (-not $u) { return }
    try {
        $obj = Get-ADUser $u -ErrorAction Stop
        if ($obj.Enabled) { Disable-ADAccount $u -ErrorAction Stop } else { Enable-ADAccount $u -ErrorAction Stop }
        Update-Users
    }
    catch { Write-GuiLog (Format-Err $_) 'ERROR'; Show-Message $_.Exception.Message 'Error' | Out-Null }
} })
$ui.UsrReset.add_Click({ Invoke-Logged 'UsrReset.Click' {
    $u = Get-SelectedUser; if (-not $u) { return }
    $f = Show-Form -Title "$(T 'adm.resetPwd') $u" -Fields @(
        @{ Key = 'Password'; Label = T 'u.password'; Type = 'password' }
        @{ Key = 'MustChange'; Label = T 'u.mustChange'; Type = 'check'; Value = $true }
    )
    if (-not $f -or -not $f.Password) { return }
    try {
        Set-ADAccountPassword $u -Reset -NewPassword (ConvertTo-SecureString $f.Password -AsPlainText -Force) -ErrorAction Stop
        Set-ADUser $u -ChangePasswordAtLogon $f.MustChange -ErrorAction Stop
        Unlock-ADAccount $u -ErrorAction SilentlyContinue
        Show-Message (T 'adm.done') | Out-Null
    }
    catch { Write-GuiLog (Format-Err $_) 'ERROR'; Show-Message $_.Exception.Message 'Error' | Out-Null }
} })
$ui.UsrUnlock.add_Click({ Invoke-Logged 'UsrUnlock.Click' {
    $u = Get-SelectedUser; if (-not $u) { return }
    try { Unlock-ADAccount $u -ErrorAction Stop; Update-Users } catch { Write-GuiLog (Format-Err $_) 'ERROR'; Show-Message $_.Exception.Message 'Error' | Out-Null }
} })

# ============================================================
# Wire-up and start
# ============================================================
$ui.Tabs.add_SelectionChanged({
    # Selection changes of inner lists/grids bubble up here: only real tab switches count.
    if ($_.OriginalSource -ne $ui.Tabs) { return }
    Invoke-Logged "Tab $($ui.Tabs.SelectedItem.Name)" {
        if ($ui.Tabs.SelectedItem -eq $ui.TabAdmin) { [void](Initialize-Admin) }
        if ($ui.Tabs.SelectedItem -eq $ui.TabDeploy) { Update-Deploy }
    }
})
$ui.LangBox.add_SelectionChanged({ Invoke-Logged 'LangBox.SelectionChanged' { Set-Language $ui.LangBox.SelectedIndex } })

Invoke-Logged 'Startup: load config' { Update-ConfigFiles; Import-Config }
Invoke-Logged 'Startup: language' -Quiet { Set-Language 0 }
if ($env:NVINST_GUI_NOSHOW) { return }   # test hook: build the window without showing it
Write-GuiLog 'Window   : shown'
[void]$win.ShowDialog()
