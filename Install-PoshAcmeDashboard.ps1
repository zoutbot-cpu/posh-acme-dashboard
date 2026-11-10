#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the Posh-ACME Dashboard so it starts at boot, or removes it again.

.DESCRIPTION
    Copies the dashboard to -InstallPath, installs the Posh-ACME module for all users if
    needed, and registers a scheduled task that starts the dashboard at boot under one
    Windows account. Everyone then uses that single instance from a browser, so they all
    share the same certificates, settings and deployment list.

    Run from an elevated PowerShell prompt, in the PowerShell edition the dashboard should
    use (pwsh for PowerShell 7, powershell for 5.1). Running it again upgrades an existing
    install and keeps its data. Use -WhatIf to see every step without changing anything.

    Posh-ACME keeps its config and encrypted credentials per Windows account. Install under
    the account that already owns your certificates, or they won't appear in the dashboard.

.PARAMETER ServiceAccount
    Account the dashboard runs as (DOMAIN\Name). Defaults to the current user. A group
    Managed Service Account (name ending in $) needs no password.

.PARAMETER Credential
    Password for -ServiceAccount. You are prompted if it's left out and the account isn't a gMSA.

.PARAMETER ListenAddress
    'localhost' (default) for this machine only, or '+' to share it on the network.

.PARAMETER AllowedPrincipals
    Users or groups (DOMAIN\Name) with full access. Required unless listening on localhost.

.PARAMETER ReadOnlyPrincipals
    Users or groups that can view but not change anything.

.PARAMETER CertThumbprint
    Certificate in LocalMachine\My to serve HTTPS with. Turns on HTTPS for the dashboard.

.PARAMETER ReadOnly
    Install in read-only mode (see README.md).

.PARAMETER AllowAnyUser
    Share on the network without an access list. Only when a firewall or authenticating
    reverse proxy already limits who can reach it.

.PARAMETER PoshAcmeHome
    Shared Posh-ACME config folder, instead of the run account's own profile.

.PARAMETER CreateRenewalTask
    Also register a daily "Submit-Renewal -AllAccounts" task under the same account.

.PARAMETER RunElevated
    Run with administrator rights. Only needed for orders that install into the Windows
    certificate store.

.PARAMETER Uninstall
    Remove the task, firewall rule, URL reservation and program files. Data is kept.

.PARAMETER RemoveData
    With -Uninstall, also delete settings, the deployment list and logs.

.EXAMPLE
    .\Install-PoshAcmeDashboard.ps1 -ServiceAccount 'CONTOSO\svc-acme$' -ListenAddress + -AllowedPrincipals 'CONTOSO\PKI Admins' -CertThumbprint 1234...

.EXAMPLE
    .\Install-PoshAcmeDashboard.ps1 -Uninstall
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallPath = (Join-Path $env:ProgramFiles 'PoshAcmeDashboard'),
    [string]$DataPath = (Join-Path $env:ProgramData 'PoshAcmeDashboard'),
    [string]$ServiceAccount = "$env:USERDOMAIN\$env:USERNAME",
    [pscredential]$Credential,
    [ValidateRange(1, 65535)]
    [int]$Port = 8580,
    [string]$ListenAddress = 'localhost',
    [string[]]$AllowedPrincipals,
    [string[]]$ReadOnlyPrincipals,
    [string]$CertThumbprint,
    [switch]$ReadOnly,
    [switch]$AllowAnyUser,
    [string]$PoshAcmeHome,
    [switch]$CreateRenewalTask,
    [switch]$RunElevated,
    [switch]$Uninstall,
    [switch]$RemoveData
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$TaskName = 'Posh-ACME Dashboard'
$RenewalTaskName = 'Posh-ACME Renewal'
$FirewallRuleName = 'Posh-ACME Dashboard'
$SslAppId = '{6b7d3c1e-2f1a-4f7e-9a51-0c6a3e7d9b21}'
$Engine = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
$script:Cmd = $PSCmdlet

function Invoke-Step {
    # Every change goes through here, so -WhatIf covers all of them.
    param([string]$What, [scriptblock]$Do)
    if ($script:Cmd.ShouldProcess($What, 'Install step')) {
        Write-Host "  - $What"
        & $Do
    }
}

function Test-LocalOnly { param([string]$Address) $Address -in 'localhost', '127.0.0.1', '[::1]' }

function Get-UrlPrefix {
    param([string]$Address, [int]$PortNumber, [bool]$Https)
    '{0}://{1}:{2}/' -f $(if ($Https) { 'https' } else { 'http' }), $Address, $PortNumber
}

function Resolve-AccountSid {
    # Catches typos now: a misspelled group would otherwise lock everyone out at runtime.
    param([string]$Name)
    try {
        ([Security.Principal.NTAccount]$Name).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch {
        throw "Windows can't find the account or group '$Name'. Use the form DOMAIN\Name."
    }
}

function ConvertTo-PsLiteral { param([string]$Text) "'" + ($Text -replace "'", "''") + "'" }

function New-DashboardCommand {
    # A -Command string, because -File can't pass a [string[]] value such as several principals.
    param([hashtable]$C)
    $script = Join-Path $C.InstallPath 'Start-PoshAcmeDashboard.ps1'
    $parts = @('&', (ConvertTo-PsLiteral $script), '-Port', $C.Port, '-ListenAddress', (ConvertTo-PsLiteral $C.ListenAddress),
        '-DataPath', (ConvertTo-PsLiteral $C.DataPath))
    if ($C.PoshAcmeHome) { $parts += '-PoshAcmeHome', (ConvertTo-PsLiteral $C.PoshAcmeHome) }
    if ($C.AllowedPrincipals) { $parts += '-AllowedPrincipals', ((@($C.AllowedPrincipals) | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ',') }
    if ($C.ReadOnlyPrincipals) { $parts += '-ReadOnlyPrincipals', ((@($C.ReadOnlyPrincipals) | ForEach-Object { ConvertTo-PsLiteral $_ }) -join ',') }
    if ($C.UseHttps) { $parts += '-UseHttps' }
    if ($C.ReadOnly) { $parts += '-ReadOnly' }
    if ($C.AllowAnyUser) { $parts += '-AllowAnyUser' }
    '{0} *>> {1}; exit $LASTEXITCODE' -f ($parts -join ' '), (ConvertTo-PsLiteral (Join-Path $C.DataPath 'logs\dashboard.log'))
}

function New-RenewalCommand {
    param([string]$ConfigHome)
    $prefix = if ($ConfigHome) { '$env:POSHACME_HOME = ' + (ConvertTo-PsLiteral $ConfigHome) + '; ' } else { '' }
    $prefix + 'Submit-Renewal -AllAccounts'
}

function Copy-DashboardFiles {
    # An explicit list, so test data or settings beside the source are never installed.
    param([string]$Source, [string]$Destination)
    $from = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $to = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    if ($from -eq $to) { return }
    $null = New-Item -ItemType Directory -Path $to -Force
    foreach ($f in 'Start-PoshAcmeDashboard.ps1', 'Install-PoshAcmeDashboard.ps1', 'README.md') {
        Copy-Item -LiteralPath (Join-Path $from $f) -Destination $to -Force
    }
    # templates.json is meant to be edited; keep it on upgrades
    if (-not (Test-Path -LiteralPath (Join-Path $to 'templates.json'))) {
        Copy-Item -LiteralPath (Join-Path $from 'templates.json') -Destination $to
    }
    foreach ($d in 'lib', 'www') {
        $target = Join-Path $to $d
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Copy-Item -LiteralPath (Join-Path $from $d) -Destination $target -Recurse
    }
    Get-ChildItem -LiteralPath $to -Recurse -File | Unblock-File
}

function Set-RestrictedAcl {
    # Only SYSTEM, Administrators and the run account. SIDs, so this works on any Windows language.
    param([string]$Path, [string]$AccountSid)
    $out = & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*${AccountSid}:(OI)(CI)M" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on ${Path}: $out" }
}

function Remove-UrlBindings {
    # Removes any URL reservation and HTTPS binding from an earlier install. Missing ones are fine.
    param($Previous)
    if (-not $Previous -or (Test-LocalOnly $Previous.ListenAddress)) { return }
    $prefix = Get-UrlPrefix $Previous.ListenAddress $Previous.Port ([bool]$Previous.UseHttps)
    $null = & netsh.exe http delete urlacl "url=$prefix" 2>&1
    if ($Previous.UseHttps) { $null = & netsh.exe http delete sslcert "ipport=0.0.0.0:$($Previous.Port)" 2>&1 }
}

function Stop-DashboardTask {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') { Stop-ScheduledTask -TaskName $TaskName; Start-Sleep -Seconds 2 }
}

function Wait-ForPort {
    param([int]$PortNumber, [int]$TimeoutSeconds = 45)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $tcp = New-Object Net.Sockets.TcpClient
        try {
            $tcp.Connect('127.0.0.1', $PortNumber)
            return $true
        } catch {
            Start-Sleep -Seconds 1
        } finally {
            $tcp.Close()
        }
    }
    return $false
}

function Get-TaskFailureHint {
    # Turns the scheduled task's last result into the likely cause, so the message points at the real problem.
    param([string]$Hex, [string]$Account, [bool]$HasLog)
    $seeLog = if ($HasLog) { 'The log lines below show why.' } else { "No log was written, so it failed before the dashboard's own logging started." }
    switch ($Hex) {
        '41301' { "The task is running, so the logon worked, but the dashboard did not open the port within 45 seconds. $seeLog If it is only slow, wait a minute and browse to it." }
        '41303' { "The task never started, which usually means Windows refused the logon. Check the Security log for event 4625: Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625} -MaxEvents 5 | Format-List TimeCreated, Message" }
        '80070569' { "$Account is not allowed to 'Log on as a batch job'. On a domain computer a GPO that sets this right replaces the local list, and 'Deny log on as a batch job' overrides a grant. Grant it in that GPO, run gpupdate /force, then run this installer again." }
        '8007052E' { "Wrong password for $Account. Run the installer again and retype it." }
        '80070532' { "The password of $Account has expired. Reset it, then run the installer again." }
        '80070533' { "$Account is disabled. Enable it, then run the installer again." }
        '80070534' { "$Account is locked out. Unlock it, then run the installer again." }
        '8007052F' { "$Account has a logon restriction, such as allowed logon hours or 'Log On To' computers. Check the account in Active Directory." }
        '800710E0' { "Windows refused to run the task. On a domain this is often the policy 'Network access: Do not allow storage of passwords and credentials', which blocks tasks with a saved password; a gMSA avoids it. It can also be a missing 'Log on as a batch job' right." }
        '0' { "The dashboard exited without an error but is not running. $seeLog" }
        default { "The dashboard stopped with an error. $seeLog" }
    }
}

function Read-InstallRecord {
    param([string]$Folder)
    $file = Join-Path $Folder 'install.json'
    if (Test-Path -LiteralPath $file -PathType Leaf) { Get-Content -LiteralPath $file -Raw | ConvertFrom-Json }
}

function Invoke-Uninstall {
    $record = Read-InstallRecord $DataPath
    $programFolder = if ($record) { $record.InstallPath } else { $InstallPath }
    Write-Host 'Removing Posh-ACME Dashboard'
    Invoke-Step "Stop and remove scheduled task '$TaskName'" {
        Stop-DashboardTask
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($record -and $record.RenewalTaskCreated) {
        Invoke-Step "Remove scheduled task '$RenewalTaskName'" { Unregister-ScheduledTask -TaskName $RenewalTaskName -Confirm:$false -ErrorAction SilentlyContinue }
    }
    Invoke-Step "Remove firewall rule '$FirewallRuleName'" { Remove-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue }
    Invoke-Step 'Remove URL reservation and HTTPS binding' { Remove-UrlBindings $record }
    Invoke-Step "Delete program files in $programFolder" {
        if (Test-Path -LiteralPath $programFolder) { Remove-Item -LiteralPath $programFolder -Recurse -Force }
    }
    if ($RemoveData) {
        Invoke-Step "Delete settings, deployment list and logs in $DataPath" {
            if (Test-Path -LiteralPath $DataPath) { Remove-Item -LiteralPath $DataPath -Recurse -Force }
        }
    } else {
        if ($record) {
            Invoke-Step 'Forget the install details' { Remove-Item -LiteralPath (Join-Path $DataPath 'install.json') -Force }
        }
        Write-Host "Kept settings and the deployment list in $DataPath (add -RemoveData to delete them)."
    }
    Write-Host 'Posh-ACME itself, its config and your certificates were not touched.'
}

function Invoke-Install {
    $isGmsa = $ServiceAccount.EndsWith('$')
    $useHttps = [bool]$CertThumbprint
    $localOnly = Test-LocalOnly $ListenAddress

    # --- everything that can be wrong is checked before the first change ---
    if (-not $localOnly -and -not $AllowedPrincipals -and -not $AllowAnyUser) {
        throw "Sharing on the network needs -AllowedPrincipals with the users or groups allowed in. Without it the dashboard refuses to start."
    }
    $accountSid = Resolve-AccountSid $ServiceAccount
    foreach ($p in @($AllowedPrincipals) + @($ReadOnlyPrincipals) | Where-Object { $_ }) { $null = Resolve-AccountSid $p }
    if ($PoshAcmeHome -and -not (Test-Path -LiteralPath $PoshAcmeHome -PathType Container) -and -not $WhatIfPreference) {
        throw "Posh-ACME config folder '$PoshAcmeHome' does not exist."
    }
    if ($useHttps) {
        $CertThumbprint = ($CertThumbprint -replace '[^0-9a-fA-F]', '').ToUpperInvariant()
        if ($CertThumbprint.Length -ne 40) { throw "-CertThumbprint must be the certificate's 40-character thumbprint. List them with: Get-ChildItem Cert:\LocalMachine\My | Format-List Subject, NotAfter, Thumbprint" }
        $cert = Get-Item -LiteralPath "Cert:\LocalMachine\My\$CertThumbprint" -ErrorAction SilentlyContinue
        if (-not $cert) { throw "Certificate $CertThumbprint is not in the computer's Personal store (Cert:\LocalMachine\My). A certificate in your own user store doesn't count. See the Install section of the website for how to get one, or leave -CertThumbprint out to use HTTP." }
        if (-not $cert.HasPrivateKey) { throw "Certificate $CertThumbprint has no private key on this computer, so it can't serve HTTPS. Import it from a PFX that includes the key." }
    }
    if (-not $localOnly -and -not $useHttps) {
        Write-Warning 'Sharing without HTTPS: GoDaddy and email secrets typed into the page cross the network unencrypted. Use -CertThumbprint.'
    }
    if ($isGmsa) {
        if ($Credential) { Write-Warning 'A gMSA has no password; ignoring -Credential.' }
    } elseif (-not $Credential -and -not $WhatIfPreference) {
        $Credential = Get-Credential -UserName $ServiceAccount -Message "Password for $ServiceAccount, which the dashboard will run as"
    }

    $config = @{
        InstallPath = $InstallPath; DataPath = $DataPath; Port = $Port; ListenAddress = $ListenAddress
        AllowedPrincipals = $AllowedPrincipals; ReadOnlyPrincipals = $ReadOnlyPrincipals; UseHttps = $useHttps
        ReadOnly = [bool]$ReadOnly; AllowAnyUser = [bool]$AllowAnyUser; PoshAcmeHome = $PoshAcmeHome
    }
    $taskArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + (New-DashboardCommand $config) + '"'
    $runLevel = if ($RunElevated) { 'Highest' } else { 'Limited' }
    $previous = Read-InstallRecord $DataPath

    function Register-AccountTask {
        param([string]$Name, $Action, $Trigger, $Settings, [string]$Description)
        $params = @{ TaskName = $Name; Action = $Action; Trigger = $Trigger; Settings = $Settings; Description = $Description; Force = $true }
        if ($isGmsa) {
            $params.Principal = New-ScheduledTaskPrincipal -UserId $ServiceAccount -LogonType Password -RunLevel $runLevel
        } else {
            $params.User = $ServiceAccount
            $params.Password = $Credential.GetNetworkCredential().Password
            $params.RunLevel = $runLevel
        }
        $null = Register-ScheduledTask @params
    }

    Write-Host "Installing Posh-ACME Dashboard for $ServiceAccount"

    $module = @(Get-Module -ListAvailable Posh-ACME | Where-Object { $_.ModuleBase -like "$env:ProgramFiles*" })
    if (-not $module) {
        Invoke-Step 'Install the Posh-ACME module for all users from the PowerShell Gallery' {
            Install-Module Posh-ACME -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        }
    }

    Invoke-Step 'Stop any running copy' { Stop-DashboardTask }
    Invoke-Step 'Remove URL reservation from any earlier install' { Remove-UrlBindings $previous }
    Invoke-Step "Copy program files to $InstallPath" { Copy-DashboardFiles $PSScriptRoot $InstallPath }
    Invoke-Step "Create data folder $DataPath, writable only by $ServiceAccount and administrators" {
        $null = New-Item -ItemType Directory -Path (Join-Path $DataPath 'logs') -Force
        Set-RestrictedAcl $DataPath $accountSid
    }
    if ($PoshAcmeHome) {
        # This folder may already be in use, so only add to its permissions.
        Invoke-Step "Allow $ServiceAccount to use $PoshAcmeHome" {
            $out = & icacls.exe $PoshAcmeHome /grant "*${accountSid}:(OI)(CI)M" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "icacls failed on ${PoshAcmeHome}: $out" }
        }
    }

    if (-not $localOnly) {
        $prefix = Get-UrlPrefix $ListenAddress $Port $useHttps
        Invoke-Step "Reserve $prefix for $ServiceAccount" {
            $out = & netsh.exe http add urlacl "url=$prefix" "sddl=D:(A;;GX;;;$accountSid)" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "netsh urlacl failed: $out" }
        }
        if ($useHttps) {
            Invoke-Step "Bind certificate $CertThumbprint to port $Port" {
                $out = & netsh.exe http add sslcert "ipport=0.0.0.0:$Port" "certhash=$CertThumbprint" "appid=$SslAppId" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "netsh sslcert failed: $out" }
            }
        }
        Invoke-Step "Open TCP port $Port in Windows Firewall (domain and private networks)" {
            Remove-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
            $null = New-NetFirewallRule -DisplayName $FirewallRuleName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Domain, Private
        }
    }

    Invoke-Step "Register scheduled task '$TaskName' to start at boot" {
        $action = New-ScheduledTaskAction -Execute $Engine -Argument $taskArgs -WorkingDirectory $InstallPath
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
            -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
        Register-AccountTask $TaskName $action $trigger $settings 'Web dashboard for Posh-ACME certificates.'
    }

    if ($CreateRenewalTask) {
        Invoke-Step "Register daily scheduled task '$RenewalTaskName'" {
            $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + (New-RenewalCommand $PoshAcmeHome) + '"'
            $action = New-ScheduledTaskAction -Execute $Engine -Argument $arg
            $trigger = New-ScheduledTaskTrigger -Daily -At '03:00' -RandomDelay (New-TimeSpan -Hours 1)
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-AccountTask $RenewalTaskName $action $trigger $settings 'Renews Posh-ACME certificates that are due.'
        }
    }

    Invoke-Step 'Record install details (no secrets)' {
        [pscustomobject]@{
            InstallPath = $InstallPath; Port = $Port; ListenAddress = $ListenAddress; UseHttps = $useHttps
            ServiceAccount = $ServiceAccount
            RenewalTaskCreated = [bool]$CreateRenewalTask -or [bool]($previous -and $previous.RenewalTaskCreated)
            InstalledAt = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $DataPath 'install.json') -Encoding UTF8
    }

    $url = (Get-UrlPrefix $(if ($localOnly) { 'localhost' } else { [Environment]::MachineName }) $Port $useHttps)
    if ($WhatIfPreference) { return }

    Write-Host '  - Start the dashboard'
    Start-ScheduledTask -TaskName $TaskName
    if (-not (Wait-ForPort $Port)) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        $hex = '{0:X}' -f $info.LastTaskResult
        $log = Join-Path $DataPath 'logs\dashboard.log'
        $hasLog = Test-Path -LiteralPath $log
        Write-Host "The dashboard did not start listening on port $Port. Task result: 0x$hex" -ForegroundColor Red
        Write-Host "  $(Get-TaskFailureHint $hex $ServiceAccount $hasLog)" -ForegroundColor Red
        if ($hasLog) { Get-Content -LiteralPath $log -Tail 15 | ForEach-Object { "  $_" } }
        exit 1
    }

    Write-Host ''
    Write-Host 'Installed and running.' -ForegroundColor Green
    Write-Host "  Open        $url"
    Write-Host "  Runs as     $ServiceAccount"
    Write-Host "  Data, logs  $DataPath"
    if (-not $CreateRenewalTask) { Write-Host '  Renewal     not set up here; add -CreateRenewalTask or use the Auto-renewal tab.' }
    if ($ServiceAccount -ne "$env:USERDOMAIN\$env:USERNAME" -and -not $PoshAcmeHome) {
        Write-Host "  Note        Certificates created under another account won't appear: Posh-ACME config is per account." -ForegroundColor Yellow
    }
}

if (-not $WhatIfPreference) {
    $identity = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this from an elevated PowerShell prompt (Run as administrator), or add -WhatIf to preview the steps.'
    }
}

if ($Uninstall) { Invoke-Uninstall } else { Invoke-Install }
