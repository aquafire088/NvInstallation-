<#
============================================================
  Workstation join - graphical front-end for Join-Domain.ps1
============================================================
  Double-click Poste-Jonction.cmd (next to this file). Asks for
  elevation, shows a form, runs Join-Domain.ps1 in the background
  and streams its output. Copy the whole poste\ folder to the PC.
  Default values come from Join-Domain.ps1's own parameters, so
  they are only ever edited there.
============================================================
#>
[CmdletBinding()]
param()

# ============================================================
# Diagnostic log: poste\gui.log (or %TEMP% if the folder is read-only).
# Startup environment + network adapters, every action, the full output
# of Join-Domain.ps1, every error with its script line. No passwords.
# ============================================================
$script:GuiLog = Join-Path $PSScriptRoot 'gui.log'
try {
    if ((Test-Path $script:GuiLog) -and (Get-Item $script:GuiLog).Length -gt 1MB) { Move-Item $script:GuiLog "$script:GuiLog.old" -Force }
    Add-Content -Path $script:GuiLog -Value '' -ErrorAction Stop
}
catch { $script:GuiLog = Join-Path $env:TEMP 'NvInstallation-poste-gui.log' }

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
        [void][System.Windows.MessageBox]::Show("Erreur / Error :`n`n$($Err.Exception.Message)`n`n$($Err.InvocationInfo.PositionMessage)`n`nJournal / log : $script:GuiLog", 'Jonction du poste', 'OK', 'Error')
    } catch {}
}
trap { Show-FatalError $_; exit 1 }

# ---------- relaunch in the right host: Windows PowerShell 5.1, STA, elevated ----------
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

# ---------- startup environment (network included: most join failures are there) ----------
function Write-StartupInfo {
    Write-GuiLog '==================== Join-Domain-GUI.ps1 START ===================='
    Write-GuiLog "Script   : $PSCommandPath"
    Write-GuiLog "User     : $env:USERDOMAIN\$env:USERNAME | admin=$isAdmin | computer=$env:COMPUTERNAME"
    Write-GuiLog "PS       : $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition) | apartment=$([Threading.Thread]::CurrentThread.GetApartmentState()) | culture=$((Get-Culture).Name)"
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        Write-GuiLog "OS       : $($os.Caption) $($os.Version) (build $($os.BuildNumber)) | domain member=$($cs.PartOfDomain) domain=$($cs.Domain)"
    } catch { Write-GuiLog ("OS info failed - " + (Format-Err $_)) 'WARN' }
    Write-GuiLog "Files    : Join-Domain.ps1 $(if (Test-Path (Join-Path $PSScriptRoot 'Join-Domain.ps1')) { 'present' } else { 'MISSING' })"
    try {
        foreach ($a in Get-NetAdapter -ErrorAction Stop) {
            $ip  = (Get-NetIPAddress -InterfaceIndex $a.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ','
            $gw  = (Get-NetIPConfiguration -InterfaceIndex $a.IfIndex -ErrorAction SilentlyContinue).IPv4DefaultGateway.NextHop -join ','
            $dns = (Get-DnsClientServerAddress -InterfaceIndex $a.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses -join ','
            $v6  = (Get-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue).Enabled
            Write-GuiLog ("Adapter  : {0} [{1}] physical={2} ip={3} gw={4} dns={5} ipv6={6}" -f $a.Name, $a.Status, (-not $a.Virtual), $ip, $gw, $dns, $v6)
        }
    } catch { Write-GuiLog ("Adapter list failed - " + (Format-Err $_)) 'WARN' }
}
Write-StartupInfo

function Invoke-Logged {
    param([string]$Name, [scriptblock]$Action)
    Write-GuiLog "ACTION   : $Name"
    $global:Error.Clear()
    try { & $Action }
    catch {
        Write-GuiLog ("FAILED   : $Name - " + (Format-Err $_)) 'ERROR'
        if ($global:Error.Count) { $global:Error.RemoveAt(0) }
        [void][System.Windows.MessageBox]::Show("$Name :`n$($_.Exception.Message)`n`n$(T 'logSee')`n$script:GuiLog", (T 'title'), 'OK', 'Error')
    }
    for ($i = [Math]::Min($global:Error.Count, 20) - 1; $i -ge 0; $i--) {
        $e = $global:Error[$i]
        if ($e -is [System.Management.Automation.ErrorRecord]) { Write-GuiLog ("detail   : during '$Name' (handled by the script) - " + (Format-Err $e)) 'DETAIL' }
    }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$JoinScript = Join-Path $PSScriptRoot "Join-Domain.ps1"

# ---------- strings (0 = francais, 1 = english) ----------
$script:Lang = 0
$Strings = @{
    'title'      = @('Jonction du poste au domaine', 'Join this workstation to the domain')
    'lang'       = @('Langue', 'Language')
    'hostname'   = @('Nom du poste', 'Computer name')
    'ip'         = @('Adresse IP', 'IP address')
    'mask'       = @('Masque', 'Subnet mask')
    'gateway'    = @('Passerelle', 'Gateway')
    'dns1'       = @('DNS 1 (DC01)', 'DNS 1 (DC01)')
    'dns2'       = @('DNS 2 (DC02, facultatif)', 'DNS 2 (DC02, optional)')
    'domain'     = @('Domaine', 'Domain')
    'ou'         = @('OU (vide = OU Postes)', 'OU (blank = OU Postes)')
    'localadmin' = @('Compte de secours local', 'Local rescue account')
    'ipv6'       = @('Désactiver IPv6', 'Disable IPv6')
    'join'       = @('Joindre au domaine', 'Join the domain')
    'close'      = @('Fermer', 'Close')
    'log'        = @('Journal', 'Log')
    'needName'   = @('Indiquez le nom du poste et son adresse IP.', 'Enter the computer name and its IP address.')
    'credMsg'    = @('Compte du domaine autorisé à joindre des postes (ex. ad-sama)', 'Domain account allowed to join computers (e.g. ad-sama)')
    'noCred'     = @('Aucun identifiant fourni.', 'No credentials supplied.')
    'running'    = @('Jonction en cours...', 'Joining...')
    'okRestart'  = @("Le poste a rejoint le domaine.`nRedémarrer maintenant ? Les stratégies (GPO, LAPS) s'appliquent au redémarrage.", "The computer joined the domain.`nRestart now? Policies (GPO, LAPS) apply at restart.")
    'failed'     = @('La jonction a échoué. Voir le journal.', 'The join failed. See the log.')
    'logSee'     = @('Détails dans le journal :', 'Details in the log:')
    'logOpen'    = @('Journal complet', 'Full log')
}
function T([string]$Key) { if ($Strings.ContainsKey($Key)) { return $Strings[$Key][$script:Lang] } return $Key }

# ---------- defaults from Join-Domain.ps1 param block ----------
$Defaults = @{}
$ast = [System.Management.Automation.Language.Parser]::ParseFile($JoinScript, [ref]$null, [ref]$null)
foreach ($p in $ast.ParamBlock.Parameters) {
    if ($p.DefaultValue -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        $Defaults[$p.Name.VariablePath.UserPath] = $p.DefaultValue.Value
    }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="620" Height="700" WindowStartupLocation="CenterScreen" FontSize="13" Background="#F4F6FA">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <DockPanel Grid.Row="0" Margin="0,0,0,12">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock Tag="L:lang" Margin="0,0,6,0" VerticalAlignment="Center"/>
        <ComboBox x:Name="LangBox" Width="100" SelectedIndex="0"><ComboBoxItem>Français</ComboBoxItem><ComboBoxItem>English</ComboBoxItem></ComboBox>
      </StackPanel>
      <TextBlock x:Name="TitleText" Tag="L:title" FontSize="20" FontWeight="SemiBold" Foreground="#2B2D6E"/>
    </DockPanel>
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="210"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Grid.RowDefinitions>
        <RowDefinition Height="32"/><RowDefinition Height="32"/><RowDefinition Height="32"/><RowDefinition Height="32"/>
        <RowDefinition Height="32"/><RowDefinition Height="32"/><RowDefinition Height="32"/><RowDefinition Height="32"/><RowDefinition Height="32"/>
      </Grid.RowDefinitions>
      <TextBlock Grid.Row="0" Tag="L:hostname"   VerticalAlignment="Center"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="Hostname" Margin="0,3" CharacterCasing="Upper" MaxLength="15"/>
      <TextBlock Grid.Row="1" Tag="L:ip"         VerticalAlignment="Center"/><TextBox Grid.Row="1" Grid.Column="1" x:Name="IPAddress" Margin="0,3"/>
      <TextBlock Grid.Row="2" Tag="L:mask"       VerticalAlignment="Center"/><TextBox Grid.Row="2" Grid.Column="1" x:Name="SubnetMask" Margin="0,3"/>
      <TextBlock Grid.Row="3" Tag="L:gateway"    VerticalAlignment="Center"/><TextBox Grid.Row="3" Grid.Column="1" x:Name="Gateway" Margin="0,3"/>
      <TextBlock Grid.Row="4" Tag="L:dns1"       VerticalAlignment="Center"/><TextBox Grid.Row="4" Grid.Column="1" x:Name="DNSServer" Margin="0,3"/>
      <TextBlock Grid.Row="5" Tag="L:dns2"       VerticalAlignment="Center"/><TextBox Grid.Row="5" Grid.Column="1" x:Name="DNSServer2" Margin="0,3"/>
      <TextBlock Grid.Row="6" Tag="L:domain"     VerticalAlignment="Center"/><TextBox Grid.Row="6" Grid.Column="1" x:Name="DomainName" Margin="0,3"/>
      <TextBlock Grid.Row="7" Tag="L:ou"         VerticalAlignment="Center"/><TextBox Grid.Row="7" Grid.Column="1" x:Name="OUPath" Margin="0,3"/>
      <TextBlock Grid.Row="8" Tag="L:localadmin" VerticalAlignment="Center"/><TextBox Grid.Row="8" Grid.Column="1" x:Name="LocalAdminName" Margin="0,3"/>
    </Grid>
    <CheckBox Grid.Row="2" x:Name="DisableIPv6" Tag="L:ipv6" IsChecked="True" Margin="0,10,0,6"/>
    <GroupBox Grid.Row="3" Tag="L:log" Margin="0,6,0,10">
      <TextBox x:Name="LogBox" IsReadOnly="True" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap"
               VerticalScrollBarVisibility="Auto" Background="#1E1F2B" Foreground="#E6E6F0" BorderThickness="0"/>
    </GroupBox>
    <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="OpenLog" Tag="L:logOpen" Padding="18,6" Margin="0,0,8,0"/>
      <Button x:Name="JoinBtn" Tag="L:join" Padding="18,6" Margin="0,0,8,0" Background="#4B3FD1" Foreground="White" FontWeight="SemiBold"/>
      <Button x:Name="CloseBtn" Tag="L:close" Padding="18,6"/>
    </StackPanel>
  </Grid>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'LangBox','TitleText','Hostname','IPAddress','SubnetMask','Gateway','DNSServer','DNSServer2','DomainName','OUPath','LocalAdminName','DisableIPv6','LogBox','OpenLog','JoinBtn','CloseBtn') {
    $ui[$n] = $win.FindName($n)
}
Write-GuiLog "Window   : built, missing controls: $(@($ui.Keys | Where-Object { -not $ui[$_] }) -join ',')"
$win.Dispatcher.add_UnhandledException({
    Write-GuiLog ("UI exception: " + $_.Exception.ToString()) 'ERROR'
    $_.Handled = $true
})
$win.add_Closed({ Write-GuiLog '==================== Join-Domain-GUI.ps1 CLOSED ====================' })

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
    $script:Lang = $Index
    Update-Texts $win
    $win.Title = T 'title'
}

foreach ($k in 'SubnetMask','Gateway','DNSServer','DNSServer2','DomainName','OUPath','LocalAdminName') {
    if ($Defaults.ContainsKey($k)) { $ui[$k].Text = $Defaults[$k] }
}
$ui.Hostname.Text = $env:COMPUTERNAME

function Add-Log {
    param([string]$Line)
    $ui.LogBox.AppendText($Line + [Environment]::NewLine)
    $ui.LogBox.ScrollToEnd()
}

# ---------- run Join-Domain.ps1 as a background job ----------
$script:Job = $null
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(500)
$timer.add_Tick({
    if (-not $script:Job) { return }
    try {
        foreach ($line in @(Receive-Job -Job $script:Job -ErrorAction Stop)) {
            if ("$line" -match '^##EXIT=(-?\d+)$') { $script:ExitCode = [int]$Matches[1] }
            else { Add-Log "$line"; Write-GuiLog "join     > $line" 'JOB' }
        }
    }
    catch { Write-GuiLog ("join job error - " + (Format-Err $_)) 'ERROR'; Add-Log "[ERROR] $($_.Exception.Message)" }
    if ($script:Job.State -in 'Completed', 'Failed', 'Stopped') {
        $timer.Stop()
        Write-GuiLog "Join     : job $($script:Job.State), exit code $script:ExitCode" $(if ($script:ExitCode -eq 0) { 'INFO' } else { 'ERROR' })
        if ($script:Job.State -eq 'Failed') { Write-GuiLog "Join     : job failure reason - $($script:Job.ChildJobs[0].JobStateInfo.Reason)" 'ERROR' }
        Remove-Job -Job $script:Job -Force -ErrorAction SilentlyContinue
        $script:Job = $null
        $ui.JoinBtn.IsEnabled = $true
        $win.Cursor = $null
        if ($script:ExitCode -eq 0) {
            $r = [System.Windows.MessageBox]::Show((T 'okRestart'), (T 'title'), 'YesNo', 'Question')
            Write-GuiLog "Join     : restart now? $r"
            if ($r -eq 'Yes') { Restart-Computer -Force }
        }
        else {
            [void][System.Windows.MessageBox]::Show("$(T 'failed')`n`n$script:GuiLog", (T 'title'), 'OK', 'Error')
        }
    }
})

$ui.OpenLog.add_Click({ Start-Process notepad.exe $script:GuiLog })

$ui.JoinBtn.add_Click({ Invoke-Logged 'Join' {
    if ([string]::IsNullOrWhiteSpace($ui.Hostname.Text) -or [string]::IsNullOrWhiteSpace($ui.IPAddress.Text)) {
        Write-GuiLog 'Join     : computer name or IP missing' 'WARN'
        [void][System.Windows.MessageBox]::Show((T 'needName'), (T 'title'), 'OK', 'Warning'); return
    }
    # UPN form is always valid, unlike a NetBIOS name guessed from the FQDN.
    $cred = Get-Credential -UserName "ad-sama@$($ui.DomainName.Text.Trim())" -Message (T 'credMsg')
    if (-not $cred) { Write-GuiLog 'Join     : credential prompt cancelled' 'WARN'; Add-Log (T 'noCred'); return }

    $params = @{
        Hostname       = $ui.Hostname.Text.Trim()
        IPAddress      = $ui.IPAddress.Text.Trim()
        SubnetMask     = $ui.SubnetMask.Text.Trim()
        Gateway        = $ui.Gateway.Text.Trim()
        DNSServer      = $ui.DNSServer.Text.Trim()
        DNSServer2     = $ui.DNSServer2.Text.Trim()
        DomainName     = $ui.DomainName.Text.Trim()
        OUPath         = $ui.OUPath.Text.Trim()
        LocalAdminName = $ui.LocalAdminName.Text.Trim()
        DisableIPv6    = [bool]$ui.DisableIPv6.IsChecked
        Credential     = $cred
        NoReboot       = $true
    }
    $shown = ($params.GetEnumerator() | Where-Object { $_.Key -ne 'Credential' } | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
    Write-GuiLog "Join     : start as $($cred.UserName) | $shown"
    $ui.LogBox.Clear()
    Add-Log (T 'running')
    $ui.JoinBtn.IsEnabled = $false
    $win.Cursor = [System.Windows.Input.Cursors]::Wait
    $script:ExitCode = 1
    $script:Job = Start-Job -ArgumentList $JoinScript, $params -ScriptBlock {
        param($Path, $P)
        & $Path @P *>&1 | ForEach-Object { "$_" }
        "##EXIT=$LASTEXITCODE"
    }
    $timer.Start()
} })

$ui.CloseBtn.add_Click({ $win.Close() })
$ui.LangBox.add_SelectionChanged({ Invoke-Logged "Language $($ui.LangBox.SelectedIndex)" { Set-Language $ui.LangBox.SelectedIndex } })

Set-Language 0
Write-GuiLog "Defaults : $(($Defaults.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')"
if ($env:NVINST_GUI_NOSHOW) { return }   # test hook: build the window without showing it
Write-GuiLog 'Window   : shown'
[void]$win.ShowDialog()
