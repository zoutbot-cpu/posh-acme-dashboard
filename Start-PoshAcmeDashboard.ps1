#Requires -Version 5.1
<#
.SYNOPSIS
    Web dashboard for viewing and managing Posh-ACME certificates.

.DESCRIPTION
    Starts a small web server (System.Net.HttpListener, no extra modules required)
    that serves a browser dashboard for the Posh-ACME configuration of the user
    running this script.

    The dashboard reads Posh-ACME's config folder directly, so viewing never changes
    the "current" server/account/order that scheduled renewals depend on. Actions
    (renew, revoke, new certificate, ...) run as background jobs in a separate
    PowerShell process. Those jobs switch server/account as needed and restore the
    previous selection when they finish.

.PARAMETER Port
    TCP port to listen on. Default 8580.

.PARAMETER ListenAddress
    Host name to bind. 'localhost' (default) only accepts local connections.
    Use '+' to listen on all addresses (needs an elevated prompt or a URL ACL,
    see README.md).

.PARAMETER Authentication
    'None' or 'Windows' (Kerberos/NTLM via the browser). Defaults to 'None' when
    bound to localhost, otherwise 'Windows'.

.PARAMETER AllowedPrincipals
    Windows users or groups (DOMAIN\Name) that may use the dashboard when
    Windows authentication is enabled. Required when listening on anything other
    than localhost, unless -AllowAnyUser is given.

.PARAMETER ReadOnlyPrincipals
    Windows users or groups that may view but not run actions. Checked after
    AllowedPrincipals; members of both get read-only access.

.PARAMETER UseHttps
    Listen on https://. A certificate must be bound to the port with
    'netsh http add sslcert' first (see README.md).

.PARAMETER ReadOnly
    Safe mode for looking and testing. Nothing can be renewed, revoked, requested or
    changed, no email is sent, no server checks run, and no file is written. Posh-ACME
    only ever sees an empty temporary folder, so your config isn't touched. The one
    action left is a read-only test of GoDaddy credentials typed into the page.

.PARAMETER NotifyOnce
    Don't start the web server: send any due expiry alerts / digest email and exit.
    For a scheduled task, so emails go out even when the dashboard isn't running.

.PARAMETER DataPath
    Folder for settings.json, notify-state.json and deployments.json. Defaults to the
    script's own folder. The installer points this at a folder only the run account can write.

.PARAMETER PoshAcmeHome
    Posh-ACME config folder to use instead of the run account's default. Must already exist.

.PARAMETER AllowAnyUser
    Allow listening on the network without -AllowedPrincipals (or without
    authentication). Only for when access is controlled elsewhere, such as a
    firewall or an authenticating reverse proxy.

.PARAMETER OpenBrowser
    Open the dashboard in the default browser after starting.

.EXAMPLE
    .\Start-PoshAcmeDashboard.ps1 -OpenBrowser

.EXAMPLE
    .\Start-PoshAcmeDashboard.ps1 -ListenAddress + -Port 8580 -AllowedPrincipals 'CONTOSO\PKI Admins'
#>
[CmdletBinding()]
param(
    [ValidateRange(1,65535)]
    [int]$Port = 8580,
    [string]$ListenAddress = 'localhost',
    [ValidateSet('None','Windows')]
    [string]$Authentication,
    [string[]]$AllowedPrincipals,
    [string[]]$ReadOnlyPrincipals,
    [switch]$UseHttps,
    [switch]$ReadOnly,
    [switch]$OpenBrowser,
    [switch]$NotifyOnce,
    [switch]$AllowAnyUser,
    [string]$DataPath,
    [string]$PoshAcmeHome,
    [ValidateRange(5,1000)]
    [int]$MaxJobHistory = 50
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$DashboardVersion = '1.0.0'
$WebRoot = Join-Path $PSScriptRoot 'www'
$TemplatesFile = Join-Path $PSScriptRoot 'templates.json'
$DashboardRoot = $PSScriptRoot
if ($DataPath) {
    if (-not (Test-Path -LiteralPath $DataPath -PathType Container)) { $null = New-Item -ItemType Directory -Path $DataPath -Force }
    $DashboardRoot = (Resolve-Path -LiteralPath $DataPath).Path
}
if ($PoshAcmeHome) {
    # Posh-ACME silently falls back to its default folder if this one doesn't exist.
    if (-not (Test-Path -LiteralPath $PoshAcmeHome -PathType Container)) { throw "Posh-ACME config folder '$PoshAcmeHome' does not exist." }
    $env:POSHACME_HOME = $PoshAcmeHome
}
$IsLocalOnly = $ListenAddress -in 'localhost','127.0.0.1','[::1]'
if (-not $Authentication) {
    $Authentication = if ($IsLocalOnly) { 'None' } else { 'Windows' }
}
# Shared on the network: refuse to start unless access is limited to named users or groups.
if (-not $IsLocalOnly -and -not $NotifyOnce -and -not $AllowAnyUser) {
    $problem = if ($Authentication -eq 'None') {
        "without authentication, so anyone who can reach port $Port could manage your certificates."
    } elseif (-not $AllowedPrincipals) {
        "with Windows sign-in but no -AllowedPrincipals, so every signed-in domain user would get full access."
    }
    if ($problem) {
        Write-Host "Refusing to listen on '$ListenAddress' $problem" -ForegroundColor Red
        Write-Host "Limit access to specific users or groups, for example:" -ForegroundColor Red
        Write-Host "  -AllowedPrincipals 'CONTOSO\PKI Admins' [-ReadOnlyPrincipals 'CONTOSO\Helpdesk']" -ForegroundColor Red
        Write-Host "If access is already controlled elsewhere (firewall, reverse proxy), add -AllowAnyUser." -ForegroundColor Red
        exit 1
    }
}
if (-not $IsLocalOnly -and $AllowAnyUser) {
    Write-Warning "-AllowAnyUser: $(if ($Authentication -eq 'None') { 'anyone who can reach this port' } else { 'every signed-in domain user' }) can use the dashboard$(if (-not $ReadOnlyPrincipals -and -not $ReadOnly) { ' with full access' })."
}

if ($ReadOnly -and $NotifyOnce) {
    Write-Host '-ReadOnly and -NotifyOnce cannot be combined: read-only mode never sends email.' -ForegroundColor Red
    exit 1
}

# Loading Posh-ACME refreshes the current ACME server and rewrites files in its config folder.
# In read-only mode the module only gets an empty throwaway folder; the dashboard reads the real
# config directly with plain file reads.
$ReadOnlySandbox = $null
if ($ReadOnly) {
    $RealConfigRoot = Join-Path $env:LOCALAPPDATA 'Posh-ACME'
    if (-not [string]::IsNullOrWhiteSpace($env:POSHACME_HOME)) {
        $customHome = [Environment]::ExpandEnvironmentVariables($env:POSHACME_HOME)
        if (Test-Path -LiteralPath $customHome -PathType Container) { $RealConfigRoot = $customHome }
    }
    $ReadOnlySandbox = Join-Path ([IO.Path]::GetTempPath()) ('PoshAcmeDashboard-ReadOnly-' + [guid]::NewGuid().ToString('n'))
    $null = New-Item -ItemType Directory -Path $ReadOnlySandbox -Force
    $env:POSHACME_HOME = $ReadOnlySandbox
}

Import-Module Posh-ACME -ErrorAction Stop
$PoshAcmeModule = Get-Module Posh-ACME
$ConfigRoot = if ($ReadOnly) { $RealConfigRoot } else { & $PoshAcmeModule { Get-ConfigRoot } }
$JobConfigRoot = if ($ReadOnly) { $ReadOnlySandbox } else { $ConfigRoot }
$WellKnownServers = & $PoshAcmeModule { $script:WellKnownDirs }

#region Helpers: reading the Posh-ACME config folder

$SafeSegment = '^(?!\.{1,2}$)[^\\/:*?"<>|]+$'

function Read-JsonFile {
    param([string]$Path)
    Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
}

function Read-TextFile {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $text = [IO.File]::ReadAllText($Path).Trim()
        if ($text) { return $text }
    }
    return $null
}

function Get-Prop {
    # StrictMode-safe property access for objects loaded from JSON
    param($Object, [string]$Name)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $null
}

function ConvertTo-IsoDate {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq 'Unspecified') { $Value = [datetime]::SpecifyKind($Value, 'Utc') }
        return $Value.ToUniversalTime().ToString('o')
    }
    try {
        return [DateTimeOffset]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture).UtcDateTime.ToString('o')
    } catch {
        return "$Value"
    }
}

function Get-CertInfo {
    param([string]$OrderFolder)
    $certFile = Join-Path $OrderFolder 'cert.cer'
    if (-not (Test-Path -LiteralPath $certFile -PathType Leaf)) { return $null }
    try {
        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $certFile
        $sans = @()
        $sanExt = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }
        if ($sanExt) {
            $sans = @($sanExt.Format($false) -split ',\s*' | ForEach-Object { ($_ -replace '^[^=:]+[=:]\s*', '').Trim() } | Where-Object { $_ })
        }
        $files = @{}
        foreach ($f in 'cert.cer','chain.cer','fullchain.cer','cert.key','cert.pfx','fullchain.pfx') {
            $files[$f] = Test-Path -LiteralPath (Join-Path $OrderFolder $f) -PathType Leaf
        }
        [pscustomobject]@{
            subject    = $cert.Subject
            issuer     = $cert.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $true)
            issuerFull = $cert.Issuer
            notBefore  = ConvertTo-IsoDate $cert.NotBefore
            notAfter   = ConvertTo-IsoDate $cert.NotAfter
            thumbprint = $cert.Thumbprint
            serial     = $cert.SerialNumber
            sigAlg     = $cert.SignatureAlgorithm.FriendlyName
            keyAlg     = $cert.PublicKey.Oid.FriendlyName
            sans       = $sans
            files      = $files
        }
    } catch {
        [pscustomobject]@{ error = "Unable to read cert.cer: $($_.Exception.Message)" }
    }
}

function Get-OrderHealth {
    param($OrderStatus, $CertInfo, $RenewAfter, [datetime]$Now)
    if ($CertInfo -and (Get-Prop $CertInfo 'notAfter')) {
        $notAfter = [datetime]::Parse($CertInfo.notAfter, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind')
        $daysLeft = ($notAfter - $Now).TotalDays
        if ($daysLeft -lt 0) { return 'expired' }
        if ($daysLeft -le 7) { return 'expiring' }
        if ($RenewAfter -and $Now -ge [datetime]::Parse($RenewAfter, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind')) {
            return 'renewal-due'
        }
        return 'valid'
    }
    if ($OrderStatus -eq 'invalid') { return 'invalid' }
    return 'pending'
}

function Get-Overview {
    $now = [datetime]::UtcNow
    $currentServerUrl = Read-TextFile (Join-Path $ConfigRoot 'current-server.txt')
    $servers = @()

    foreach ($dirFile in @(Get-ChildItem (Join-Path $ConfigRoot '*\dir.json') -ErrorAction SilentlyContinue | Sort-Object { $_.Directory.Name })) {
        $serverFolder = $dirFile.Directory.FullName
        $dir = try { Read-JsonFile $dirFile.FullName } catch { $null }
        $location = Get-Prop $dir 'location'
        $currentAcct = Read-TextFile (Join-Path $serverFolder 'current-account.txt')
        $accounts = @()

        foreach ($acctFile in @(Get-ChildItem (Join-Path $serverFolder '*\acct.json') -ErrorAction SilentlyContinue | Sort-Object { $_.Directory.Name })) {
            $acctFolder = $acctFile.Directory.FullName
            $acctId = $acctFile.Directory.Name
            # acct.json contains the private key; only copy safe fields
            $acct = try { Read-JsonFile $acctFile.FullName } catch { $null }
            $currentOrder = Read-TextFile (Join-Path $acctFolder 'current-order.txt')
            $orders = @()

            foreach ($orderFile in @(Get-ChildItem (Join-Path $acctFolder '*\order.json') -ErrorAction SilentlyContinue)) {
                $orderFolder = $orderFile.Directory.FullName
                $orderName = $orderFile.Directory.Name
                try {
                    $o = Read-JsonFile $orderFile.FullName
                } catch {
                    $orders += [pscustomobject]@{ name = $orderName; mainDomain = $orderName; health = 'invalid'; error = "Unreadable order.json: $($_.Exception.Message)" }
                    continue
                }
                $plugin = Get-Prop $o 'Plugin'
                if (-not $plugin) { $plugin = Get-Prop $o 'DnsPlugin' }
                $certInfo = Get-CertInfo $orderFolder
                $renewAfter = ConvertTo-IsoDate (Get-Prop $o 'RenewAfter')
                $status = Get-Prop $o 'status'
                $orders += [pscustomobject]@{
                    name              = $orderName
                    mainDomain        = Get-Prop $o 'MainDomain'
                    sans              = @(Get-Prop $o 'SANs' | Where-Object { $_ })
                    status            = $status
                    orderExpires      = ConvertTo-IsoDate (Get-Prop $o 'expires')
                    certExpires       = ConvertTo-IsoDate (Get-Prop $o 'CertExpires')
                    renewAfter        = $renewAfter
                    plugin            = @($plugin | Where-Object { $_ })
                    keyLength         = Get-Prop $o 'KeyLength'
                    friendlyName      = Get-Prop $o 'FriendlyName'
                    install           = [bool](Get-Prop $o 'Install')
                    alwaysNewKey      = [bool](Get-Prop $o 'AlwaysNewKey')
                    dnsSleep          = Get-Prop $o 'DnsSleep'
                    validationTimeout = Get-Prop $o 'ValidationTimeout'
                    dnsAlias          = @(Get-Prop $o 'DnsAlias' | Where-Object { $_ })
                    lifetimeDays      = Get-Prop $o 'LifetimeDays'
                    preferredChain    = Get-Prop $o 'PreferredChain'
                    profile           = Get-Prop $o 'Profile'
                    fromCsr           = [bool](Get-Prop $o 'CSRBase64Url')
                    isCurrent         = ($orderName -eq "$currentOrder".Replace('*','!'))
                    cert              = $certInfo
                    health            = Get-OrderHealth $status $certInfo $renewAfter $now
                    folder            = $orderFolder
                }
            }

            $accounts += [pscustomobject]@{
                id        = $acctId
                status    = Get-Prop $acct 'status'
                contact   = @(Get-Prop $acct 'contact' | Where-Object { $_ } | ForEach-Object { "$_" -replace '^mailto:', '' })
                keyLength = Get-Prop $acct 'KeyLength'
                location  = Get-Prop $acct 'location'
                isCurrent = ($acctId -eq $currentAcct)
                orders    = @($orders | Sort-Object mainDomain, name)
            }
        }

        $servers += [pscustomobject]@{
            name      = $dirFile.Directory.Name
            location  = $location
            isCurrent = ($null -ne $location -and $location -eq $currentServerUrl)
            tosUrl    = Get-Prop (Get-Prop $dir 'meta') 'termsOfService'
            accounts  = $accounts
        }
    }

    $overview = [pscustomobject]@{
        generatedAt   = $now.ToString('o')
        configRoot    = $ConfigRoot
        currentServer = $currentServerUrl
        servers       = $servers
    }

    # where each certificate is installed and whether those servers are up to date
    $deploySummary = Get-DeploymentSummary $overview
    foreach ($s in $servers) {
        foreach ($a in $s.accounts) {
            foreach ($o in $a.orders) {
                $k = "$($s.name)|$($a.id)|$($o.name)"
                $o | Add-Member -NotePropertyName deployments -NotePropertyValue $(if ($deploySummary.ContainsKey($k)) { [pscustomobject]$deploySummary[$k] } else { $null }) -Force
            }
        }
    }
    return $overview
}

function Resolve-OrderFolder {
    param([string]$Server, [string]$Account, [string]$Order)
    foreach ($seg in $Server, $Account, $Order) {
        if ($seg -notmatch $SafeSegment) { throw [ArgumentException]"Invalid identifier '$seg'" }
    }
    $folder = Join-Path (Join-Path (Join-Path $ConfigRoot $Server) $Account) $Order
    if (-not (Test-Path -LiteralPath (Join-Path $folder 'order.json') -PathType Leaf)) {
        throw [Management.Automation.ItemNotFoundException]"Order not found"
    }
    return $folder
}

$script:TaskCache = $null
$script:TaskCacheTime = [datetime]::MinValue
function Get-RenewalTasks {
    if (([datetime]::UtcNow - $script:TaskCacheTime).TotalSeconds -lt 60 -and $null -ne $script:TaskCache) {
        return $script:TaskCache
    }
    $result = [pscustomobject]@{ supported = $true; tasks = @(); error = $null }
    try {
        if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            $result.supported = $false
        } else {
            $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
                $_.Actions | Where-Object {
                    $cmd = "$(Get-Prop $_ 'Execute') $(Get-Prop $_ 'Arguments')"
                    $cmd -match 'Submit-Renewal|Posh-ACME|PoshACME' -and $cmd -notmatch 'Start-PoshAcmeDashboard'
                }
            })
            $result.tasks = @(foreach ($t in $tasks) {
                $info = try { $t | Get-ScheduledTaskInfo -ErrorAction Stop } catch { $null }
                [pscustomobject]@{
                    name           = $t.TaskName
                    path           = $t.TaskPath
                    state          = "$($t.State)"
                    runAs          = $t.Principal.UserId
                    command        = (@($t.Actions | ForEach-Object { "$(Get-Prop $_ 'Execute') $(Get-Prop $_ 'Arguments')".Trim() }) -join ' ; ')
                    lastRunTime    = if ($info -and $info.LastRunTime.Year -gt 2000) { ConvertTo-IsoDate $info.LastRunTime.ToUniversalTime() } else { $null }
                    lastTaskResult = if ($info) { $info.LastTaskResult } else { $null }
                    nextRunTime    = if ($info -and $info.NextRunTime) { ConvertTo-IsoDate $info.NextRunTime.ToUniversalTime() } else { $null }
                }
            })
        }
    } catch {
        $result.error = $_.Exception.Message
    }
    $script:TaskCache = $result
    $script:TaskCacheTime = [datetime]::UtcNow
    return $result
}

$script:PluginCache = $null
function Get-PluginList {
    if (-not $script:PluginCache) {
        $script:PluginCache = @(Get-PAPlugin | ForEach-Object {
            [pscustomobject]@{ name = $_.Name; challengeType = $_.ChallengeType }
        })
    }
    return $script:PluginCache
}

function Get-Templates {
    # Read on every request so edits to templates.json apply without a restart.
    if (-not (Test-Path -LiteralPath $TemplatesFile -PathType Leaf)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $TemplatesFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "templates.json is not valid JSON: $($_.Exception.Message)"
    }
    @(Get-Prop $raw 'templates' | ForEach-Object {
        $t = $_
        $server = Get-Prop $t 'serverUrl'
        if ($server -and $WellKnownServers.ContainsKey($server)) { $server = $WellKnownServers[$server] }
        $t | Add-Member -NotePropertyName serverUrl -NotePropertyValue $server -Force
        $t
    })
}

function Get-ParamKind {
    param([type]$Type)
    switch ($Type.FullName) {
        'System.Security.SecureString'                   { 'secure' }
        'System.Management.Automation.PSCredential'      { 'credential' }
        'System.Management.Automation.SwitchParameter'   { 'switch' }
        'System.Boolean'                                 { 'bool' }
        'System.Int32'                                   { 'int' }
        'System.String[]'                                { 'list' }
        'System.Collections.Hashtable'                   { 'hashtable' }
        default                                          { 'string' }
    }
}

function Get-PluginDetail {
    param([string]$Name)
    $plugin = Get-PluginList | Where-Object { $_.name -eq $Name }
    if (-not $plugin) { throw [Management.Automation.ItemNotFoundException]"Plugin not found" }
    $params = @(Get-PAPlugin -Plugin $plugin.name -Params)
    $sets = @($params | Group-Object ParameterSet | ForEach-Object {
        [pscustomobject]@{
            name      = $_.Name
            isDefault = [bool]($_.Group | Where-Object IsDefault)
            params    = @($_.Group | ForEach-Object {
                [pscustomobject]@{
                    name      = $_.Parameter
                    kind      = Get-ParamKind $_.ParameterType
                    type      = $_.ParameterType.Name
                    mandatory = [bool]$_.IsMandatory
                }
            })
        }
    } | Sort-Object @{ Expression = 'isDefault'; Descending = $true }, name)
    [pscustomobject]@{
        name          = $plugin.name
        challengeType = $plugin.challengeType
        docsUrl       = "https://poshac.me/docs/v4/Plugins/$($plugin.name)/"
        parameterSets = $sets
    }
}

#endregion

#region Background actions

# Runs in a separate PowerShell process via Start-Job.
$JobScript = {
    param([string]$ModulePath, [string]$ConfigRoot, [string]$Action, [string]$RequestJson, [bool]$ReadOnlyMode)

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $VerbosePreference = 'Continue'
    $req = $RequestJson | ConvertFrom-Json

    # Independent of the web server's own check.
    if ($ReadOnlyMode -and ($Action -ne 'TestPlugin' -or $req.copyFrom)) { throw "Read-only mode: '$Action' is not allowed." }

    function Write-Log {
        param([string]$Level, $Message)
        '[{0:HH:mm:ss}] {1,-7} {2}' -f (Get-Date), $Level, "$Message".TrimEnd()
    }

    function Format-Record {
        process {
            if ($_ -is [Management.Automation.VerboseRecord])     { Write-Log 'VERBOSE' $_.Message }
            elseif ($_ -is [Management.Automation.WarningRecord]) { Write-Log 'WARNING' $_.Message }
            elseif ($_ -is [Management.Automation.ErrorRecord])   { Write-Log 'ERROR' $_.Exception.Message }
            elseif ($_ -is [Management.Automation.InformationRecord]) { Write-Log 'INFO' $_.MessageData }
            elseif ($_ -is [Management.Automation.DebugRecord])   { }
            elseif ($_ -is [string] -and $_ -match '^\[\d\d:\d\d:\d\d\] ') { $_ }  # already formatted by Write-Log
            elseif ($_ -is [string])                              { Write-Log 'OUTPUT' $_ }
            elseif ($null -ne $_) {
                $_ | Select-Object * -ExcludeProperty PfxPass, PSComputerName, PSShowComputerName, RunspaceId |
                    Format-List | Out-String -Width 160 | ForEach-Object { $_.Trim() } |
                    Where-Object { $_ } | ForEach-Object { Write-Log 'RESULT' "`n$_" }
            }
        }
    }

    function ConvertTo-PluginArgs {
        # $Base holds args copied from another order; values typed in the form override them.
        param([string[]]$Plugin, $Values, [hashtable]$Base)
        $types = @{}
        foreach ($p in $Plugin) {
            Get-PAPlugin -Plugin $p -Params | ForEach-Object { $types[$_.Parameter] = $_.ParameterType }
        }
        $result = @{}
        if ($Base) {
            foreach ($k in $Base.Keys) { if ($types.ContainsKey($k)) { $result[$k] = $Base[$k] } }
        }
        if (-not $Values) { return $result }
        foreach ($prop in $Values.PSObject.Properties) {
            $v = $prop.Value
            if ($null -eq $v -or "$v" -eq '') { continue }
            $t = $types[$prop.Name]
            if (-not $t) { throw "Unknown plugin parameter '$($prop.Name)'" }
            switch ($t.FullName) {
                'System.Security.SecureString' { $result[$prop.Name] = ConvertTo-SecureString "$v" -AsPlainText -Force }
                'System.Management.Automation.PSCredential' {
                    $result[$prop.Name] = New-Object PSCredential -ArgumentList $v.username, (ConvertTo-SecureString "$($v.password)" -AsPlainText -Force)
                }
                'System.Management.Automation.SwitchParameter' { $result[$prop.Name] = [bool]$v }
                'System.Boolean' { $result[$prop.Name] = [bool]$v }
                'System.Int32'   { $result[$prop.Name] = [int]$v }
                'System.String[]' { $result[$prop.Name] = @("$v" -split '[,\r\n]+' | ForEach-Object Trim | Where-Object { $_ }) }
                'System.Collections.Hashtable' {
                    $ht = @{}
                    ("$v" | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
                    $result[$prop.Name] = $ht
                }
                default { $result[$prop.Name] = "$v" }
            }
        }
        return $result
    }

    function Test-GoDaddyAccess {
        # Read-only check that mirrors the GoDaddy plugin: find each domain's zone, then read its TXT records.
        param([hashtable]$PluginArgs, [string[]]$Domains)
        if (-not $PluginArgs.GDKey) { throw 'GDKey is missing.' }
        $secret = if ($PluginArgs.GDSecretSecure) {
            (New-Object PSCredential -ArgumentList 'gd', $PluginArgs.GDSecretSecure).GetNetworkCredential().Password
        } else { $PluginArgs.GDSecret }
        if (-not $secret) { throw 'GDSecretSecure is missing.' }

        $apiHost = if ($PluginArgs.GDUseOTE) { 'https://api.ote-godaddy.com' } else { 'https://api.godaddy.com' }
        $apiRoot = if ($PluginArgs.GDCustomerId) { "$apiHost/v2/customers/$($PluginArgs.GDCustomerId)/domains" } else { "$apiHost/v1/domains" }
        $common = @{ Headers = @{ Authorization = "sso-key $($PluginArgs.GDKey):$secret" }; ErrorAction = 'Stop'; Verbose = $false }
        if ('UseBasicParsing' -in (Get-Command Invoke-RestMethod).Parameters.Keys) { $common.UseBasicParsing = $true }

        $keyHint = $PluginArgs.GDKey.Substring(0, [Math]::Min(4, $PluginArgs.GDKey.Length))
        Write-Log 'INFO' "Testing GoDaddy API $apiRoot with key $keyHint... (read-only, no DNS records are changed)"

        $call = {
            param([string]$Uri)
            try {
                $null = Invoke-RestMethod -Method Get -Uri $Uri @common
                [pscustomobject]@{ status = 200; code = $null; message = $null }
            } catch {
                $status = 0
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }
                $code = $null; $msg = $_.Exception.Message
                if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                    try { $body = $_.ErrorDetails.Message | ConvertFrom-Json; $code = $body.code; if ($body.message) { $msg = $body.message } } catch { }
                }
                [pscustomobject]@{ status = $status; code = $code; message = $msg }
            }
        }
        $explain = {
            param($r)
            switch ($r.status) {
                401 { "GoDaddy rejected the key/secret (401$code). Check that GDKey and GDSecret belong together, and that it's a Production key$(if (-not $PluginArgs.GDUseOTE) { ' (or tick GDUseOTE for an OTE test key)' })." }
                403 { "GoDaddy denied API access (403$code): $($r.message) This usually means the GoDaddy account isn't allowed to use the DNS API$(if ($PluginArgs.GDCustomerId) { ', or GDCustomerId is wrong' })." }
                429 { "GoDaddy rate limit reached (429). Wait a minute and try again." }
                0   { "Could not reach GoDaddy: $($r.message)" }
                default { "GoDaddy returned $($r.status)$($code): $($r.message)" }
            }
        }

        $names = @($Domains | ForEach-Object { $_.Trim().TrimStart('*').TrimStart('.').ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
        $failed = 0
        foreach ($d in $names) {
            $recordName = "_acme-challenge.$d"
            $pieces = $recordName.Split('.')
            $zone = $null; $fatal = $null
            # skip the _acme-challenge label itself and the bare TLD
            for ($i = 1; $i -lt $pieces.Count - 1; $i++) {
                $zoneTest = $pieces[$i..($pieces.Count - 1)] -join '.'
                $r = & $call "$apiRoot/$zoneTest/records/NS"
                if ($r.status -eq 200) { $zone = $zoneTest; break }
                if ($r.status -notin 404, 422) { $fatal = $r; break }
            }
            if ($fatal) {
                Write-Log 'FAIL' "${d}: $(& $explain $fatal)"
                $failed++
                # bad credentials or no API access fail every domain the same way
                if ($fatal.status -in 0, 401, 403) { $failed = $names.Count; break }
                continue
            }
            if (-not $zone) {
                Write-Log 'FAIL' "${d}: no DNS zone for this name in the GoDaddy account. Is the domain registered there and using GoDaddy DNS?"
                $failed++
                continue
            }
            $short = $recordName -ireplace "\.?$([regex]::Escape($zone))$", ''
            $r = & $call "$apiRoot/$zone/records/TXT/$short"
            if ($r.status -eq 200) {
                Write-Log 'PASS' "${d}: zone $zone found and its DNS records are readable."
            } else {
                Write-Log 'FAIL' "${d}: zone $zone found, but reading its TXT records failed. $(& $explain $r)"
                $failed++
            }
        }
        if ($failed) { throw "GoDaddy check failed for $failed of $($names.Count) domain(s)." }
        Write-Log 'PASS' "GoDaddy credentials work for all $($names.Count) domain(s)."
    }

    $env:POSHACME_HOME = $ConfigRoot
    Import-Module $ModulePath -ErrorAction Stop -Verbose:$false

    # Only one dashboard action at a time; they all share Posh-ACME's "current" pointers.
    $mutex = New-Object Threading.Mutex -ArgumentList $false, 'Local\PoshAcmeDashboardAction'
    $haveMutex = $false
    try {
        try { $haveMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $haveMutex = $true }
        if (-not $haveMutex) {
            Write-Log 'INFO' 'Waiting for another dashboard action to finish...'
            try { $null = $mutex.WaitOne(); } catch [Threading.AbandonedMutexException] { }
            $haveMutex = $true
        }

        # Remember the current pointers so scheduled renewals keep using the same server/account.
        $pointers = @{}
        $remember = {
            param($path)
            if ($path -and -not $pointers.ContainsKey($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                $pointers[$path] = [IO.File]::ReadAllText($path)
            }
        }
        & $remember (Join-Path $ConfigRoot 'current-server.txt')

        & {
            # A credentials test only needs Posh-ACME state when it reuses saved credentials.
            $needsServer = $Action -ne 'TestPlugin' -or $req.copyFrom
            if ($needsServer) {
                $serverUrl = $req.serverUrl
                $existing = Get-PAServer -List | Where-Object { $_.location -eq $serverUrl -or $_.Name -eq $serverUrl }
                if ($existing) {
                    & $remember (Join-Path $existing.Folder 'current-account.txt')
                    if ($req.account) { & $remember (Join-Path (Join-Path $existing.Folder $req.account) 'current-order.txt') }
                    $serverUrl = $existing.location
                }

                Write-Log 'INFO' "Selecting ACME server $serverUrl"
                Set-PAServer -DirectoryUrl $serverUrl -Verbose:$false
                $server = Get-PAServer
                & $remember (Join-Path $server.Folder 'current-account.txt')
            }

            # Reuse saved (encrypted) plugin credentials from another order on this server.
            $copiedArgs = $null
            if ($req.copyFrom -and $req.copyFrom.order) {
                Write-Log 'INFO' "Reusing saved plugin credentials from order '$($req.copyFrom.order)' (account $($req.copyFrom.account))"
                Set-PAAccount -ID $req.copyFrom.account -Verbose:$false
                if (-not (Get-PAOrder -Name $req.copyFrom.order)) { throw "Order '$($req.copyFrom.order)' to copy credentials from was not found." }
                $copiedArgs = Get-PAPluginArgs -Name $req.copyFrom.order
                if (-not $copiedArgs -or -not $copiedArgs.Count) { throw "Order '$($req.copyFrom.order)' has no saved plugin credentials." }
            }

            if ($req.account -and $Action -notin 'NewAccount','TestPlugin') {
                Write-Log 'INFO' "Selecting account $($req.account)"
                Set-PAAccount -ID $req.account -Verbose:$false
                & $remember (Join-Path (Get-PAAccount).Folder 'current-order.txt')
            }

            switch ($Action) {
                'Renew' {
                    Submit-Renewal -Name $req.order -Force:([bool]$req.force)
                }
                'RenewAccount' {
                    Submit-Renewal -AllOrders -Force:([bool]$req.force)
                }
                'Revoke' {
                    $o = Get-PAOrder -Name $req.order
                    $revokeArgs = @{ MainDomain = $o.MainDomain; Name = $o.Name; Force = $true }
                    if ($req.reason) { $revokeArgs.Reason = $req.reason }
                    Revoke-PACertificate @revokeArgs
                    Write-Log 'INFO' "Certificate for '$($o.Name)' revoked."
                }
                'Remove' {
                    $o = Get-PAOrder -Name $req.order
                    Remove-PAOrder -MainDomain $o.MainDomain -Name $o.Name -RevokeCert:([bool]$req.revoke) -Force
                    Write-Log 'INFO' "Order '$($o.Name)' removed."
                }
                'NewAccount' {
                    $acctArgs = @{ AcceptTOS = $true; Force = $true }
                    if ($req.contact)   { $acctArgs.Contact = @($req.contact) }
                    if ($req.keyLength) { $acctArgs.KeyLength = $req.keyLength }
                    if ($req.accountId) { $acctArgs.ID = $req.accountId }
                    New-PAAccount @acctArgs
                }
                'NewCertificate' {
                    if (-not $req.account) {
                        Write-Log 'INFO' 'Creating a new ACME account'
                        $acctArgs = @{ AcceptTOS = $true; Force = $true }
                        if ($req.contact) { $acctArgs.Contact = @($req.contact) }
                        New-PAAccount @acctArgs
                    }
                    $certArgs = @{
                        Domain     = @($req.domains)
                        Plugin     = @($req.plugin)
                        PluginArgs = ConvertTo-PluginArgs @($req.plugin) $req.pluginArgs $copiedArgs
                        Force      = $true
                    }
                    if ($req.name)              { $certArgs.Name = $req.name }
                    if ($req.certKeyLength)     { $certArgs.CertKeyLength = $req.certKeyLength }
                    if ($req.friendlyName)      { $certArgs.FriendlyName = $req.friendlyName }
                    if ($req.pfxPass)           { $certArgs.PfxPass = $req.pfxPass }
                    if ($req.install)           { $certArgs.Install = $true }
                    if ($req.alwaysNewKey)      { $certArgs.AlwaysNewKey = $true }
                    if ($null -ne $req.dnsSleep -and "$($req.dnsSleep)" -ne '') { $certArgs.DnsSleep = [int]$req.dnsSleep }
                    if ($req.validationTimeout) { $certArgs.ValidationTimeout = [int]$req.validationTimeout }
                    if ($req.lifetimeDays)      { $certArgs.LifetimeDays = [int]$req.lifetimeDays }
                    if ($req.dnsAlias)          { $certArgs.DnsAlias = @($req.dnsAlias) }
                    if ($req.preferredChain)    { $certArgs.PreferredChain = $req.preferredChain }
                    New-PACertificate @certArgs
                }
                'UpdatePlugin' {
                    $o = Get-PAOrder -Name $req.order
                    Set-PAOrder -MainDomain $o.MainDomain -Name $o.Name -Plugin @($req.plugin) -PluginArgs (ConvertTo-PluginArgs @($req.plugin) $req.pluginArgs $copiedArgs) -NoSwitch
                    Write-Log 'INFO' "Plugin settings for '$($o.Name)' saved. They will be used on the next renewal."
                }
                'TestPlugin' {
                    Test-GoDaddyAccess -PluginArgs (ConvertTo-PluginArgs @($req.plugin) $req.pluginArgs $copiedArgs) -Domains @($req.domains)
                }
                default { throw "Unknown action '$Action'" }
            }
        } *>&1 | Format-Record
    }
    catch {
        Write-Log 'ERROR' $_.Exception.Message
        throw
    }
    finally {
        foreach ($p in $pointers.Keys) {
            $value = $pointers[$p]
            # Don't point back at an order that no longer exists.
            if ($p -like '*current-order.txt' -and $value -and -not (Test-Path -LiteralPath (Join-Path (Split-Path $p) $value.Trim().Replace('*','!')))) { continue }
            try { [IO.File]::WriteAllText($p, $value) } catch { Write-Log 'WARNING' "Unable to restore $p : $($_.Exception.Message)" }
        }
        if ($haveMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
        Write-Log 'INFO' 'Done.'
    }
}

$script:JobSeq = 0
$script:Jobs = New-Object Collections.Generic.List[object]

$ActionDefs = @{
    Renew          = @{ needsOrder = $true;  label = 'Renew' }
    RenewAccount   = @{ needsOrder = $false; label = 'Renew all orders' }
    Revoke         = @{ needsOrder = $true;  label = 'Revoke' }
    Remove         = @{ needsOrder = $true;  label = 'Delete order' }
    NewAccount     = @{ needsOrder = $false; label = 'New account' }
    NewCertificate = @{ needsOrder = $false; label = 'New certificate' }
    UpdatePlugin   = @{ needsOrder = $true;  label = 'Update plugin' }
    TestPlugin     = @{ needsOrder = $false; label = 'Test credentials' }
}

function Start-DashboardJob {
    param($Request, [string]$User)

    $action = Get-Prop $Request 'action'
    if (-not $action -or -not $ActionDefs.ContainsKey($action)) { throw [ArgumentException]"Unknown action" }
    if ($ReadOnly -and ($action -ne 'TestPlugin' -or (Get-Prop $Request 'copyFrom'))) {
        throw [ArgumentException]"Read-only mode only allows testing GoDaddy credentials typed into the form."
    }
    $def = $ActionDefs[$action]

    $serverUrl = Get-Prop $Request 'serverUrl'
    if (-not $serverUrl) { throw [ArgumentException]"serverUrl is required" }
    if ($WellKnownServers.ContainsKey($serverUrl)) { $serverUrl = $WellKnownServers[$serverUrl] }
    if ($serverUrl -notmatch '^https://[^\s]+$') { throw [ArgumentException]"serverUrl must be an https:// ACME directory URL" }
    $Request.serverUrl = $serverUrl

    $account = Get-Prop $Request 'account'
    if ($account -and $account -notmatch $SafeSegment) { throw [ArgumentException]"Invalid account" }
    if (-not $account -and $action -notin 'NewCertificate','NewAccount','TestPlugin') { throw [ArgumentException]"account is required" }

    $order = Get-Prop $Request 'order'
    if ($def.needsOrder -and (-not $order -or $order -notmatch $SafeSegment)) { throw [ArgumentException]"order is required" }

    switch ($action) {
        'Revoke' {
            $reasons = [enum]::GetNames((Get-Command Revoke-PACertificate).Parameters['Reason'].ParameterType)
            $reason = Get-Prop $Request 'reason'
            if ($reason -and $reason -notin $reasons) { throw [ArgumentException]"reason must be one of: $($reasons -join ', ')" }
        }
        'NewCertificate' {
            $domains = @(Get-Prop $Request 'domains' | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            if (-not $domains) { throw [ArgumentException]"At least one domain is required" }
            if (-not (Get-Prop $Request 'plugin')) { throw [ArgumentException]"plugin is required" }
            if (-not $account -and -not (Get-Prop $Request 'acceptTos')) { throw [ArgumentException]"You must accept the CA's terms of service to create an account" }
            $Request.domains = $domains
        }
        'NewAccount' {
            if (-not (Get-Prop $Request 'acceptTos')) { throw [ArgumentException]"You must accept the CA's terms of service" }
        }
        'UpdatePlugin' {
            if (-not (Get-Prop $Request 'plugin')) { throw [ArgumentException]"plugin is required" }
        }
        'TestPlugin' {
            if ((Get-Prop $Request 'plugin') -ne 'GoDaddy') { throw [ArgumentException]"Credential tests are only available for the GoDaddy plugin" }
            $domains = @(Get-Prop $Request 'domains' | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            if (-not $domains) { throw [ArgumentException]"Enter at least one domain to test against" }
            $Request.domains = $domains
        }
    }
    foreach ($p in @(Get-Prop $Request 'plugin')) {
        if ($p -and -not (Get-PluginList | Where-Object { $_.name -eq $p })) { throw [ArgumentException]"Unknown plugin '$p'" }
    }
    $copyFrom = Get-Prop $Request 'copyFrom'
    if ($copyFrom) {
        if ($action -notin 'NewCertificate','UpdatePlugin','TestPlugin') { throw [ArgumentException]"copyFrom is only valid for new certificates and plugin updates" }
        if ((Get-Prop $copyFrom 'account') -notmatch $SafeSegment -or (Get-Prop $copyFrom 'order') -notmatch $SafeSegment) {
            throw [ArgumentException]"copyFrom needs a valid account and order"
        }
    }

    $target = if ($order) { $order } elseif ($action -in 'NewCertificate','TestPlugin') { ($Request.domains -join ', ') } elseif ($account) { "account $account" } else { $serverUrl }
    $requestJson = $Request | ConvertTo-Json -Depth 6 -Compress

    $job = Start-Job -ScriptBlock $JobScript -ArgumentList (Join-Path $PoshAcmeModule.ModuleBase 'Posh-ACME.psd1'), $JobConfigRoot, $action, $requestJson, ([bool]$ReadOnly)
    $script:JobSeq++
    $entry = [pscustomobject]@{
        id      = $script:JobSeq
        action  = $action
        label   = $def.label
        target  = $target
        server  = $serverUrl
        account = $account
        order   = $order
        user    = $User
        started = [datetime]::UtcNow.ToString('o')
        Job     = $job
    }
    $script:Jobs.Add($entry)

    # trim history, never dropping running jobs
    while ($script:Jobs.Count -gt $MaxJobHistory) {
        $old = $script:Jobs | Where-Object { $_.Job.State -ne 'Running' } | Select-Object -First 1
        if (-not $old) { break }
        Remove-Job -Job $old.Job -Force -ErrorAction SilentlyContinue
        [void]$script:Jobs.Remove($old)
    }
    Write-Host ("[{0:HH:mm:ss}] {1} started {2} on {3} (job {4})" -f (Get-Date), $User, $action, $target, $entry.id)
    return $entry
}

function ConvertTo-JobView {
    param($Entry, [switch]$WithLog)
    $j = $Entry.Job
    $state = "$($j.State)"
    $view = [ordered]@{
        id       = $Entry.id
        action   = $Entry.action
        label    = $Entry.label
        target   = $Entry.target
        server   = $Entry.server
        account  = $Entry.account
        order    = $Entry.order
        user     = $Entry.user
        state    = $state
        started  = $Entry.started
        finished = if ($state -ne 'Running' -and $state -ne 'NotStarted' -and $j.PSEndTime) { ConvertTo-IsoDate $j.PSEndTime.ToUniversalTime() } else { $null }
    }
    if ($WithLog) {
        $errs = $null
        $lines = @(Receive-Job -Job $j -Keep -ErrorAction SilentlyContinue -ErrorVariable errs | ForEach-Object { "$_" })
        if ($state -eq 'Failed' -and $j.ChildJobs.Count -and $j.ChildJobs[0].JobStateInfo.Reason -and -not $lines) {
            $lines += "ERROR   $($j.ChildJobs[0].JobStateInfo.Reason.Message)"
        }
        $view.log = $lines
        # A completed job can still have hit errors that were only logged (e.g. renewal skipped).
        $view.hasWarnings = [bool]($lines | Where-Object { $_ -match '^\[[\d:]+\] (WARNING|ERROR)' })
    }
    [pscustomobject]$view
}

#endregion

#region HTTP

$MimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.ico'  = 'image/x-icon'
}

function Send-Response {
    param($Context, [int]$Status = 200, $Body, [string]$ContentType = 'application/json; charset=utf-8', [hashtable]$Headers)
    $resp = $Context.Response
    $resp.StatusCode = $Status
    $resp.ContentType = $ContentType
    $resp.Headers['X-Content-Type-Options'] = 'nosniff'
    $resp.Headers['X-Frame-Options'] = 'DENY'
    $resp.Headers['Referrer-Policy'] = 'no-referrer'
    $resp.Headers['Cache-Control'] = 'no-store'
    if ($ContentType -like 'text/html*') {
        $resp.Headers['Content-Security-Policy'] = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'"
    }
    if ($Headers) { foreach ($k in $Headers.Keys) { $resp.Headers[$k] = $Headers[$k] } }
    if ($null -eq $Body) { $Body = '' }
    $bytes = if ($Body -is [byte[]]) { $Body } else { [Text.Encoding]::UTF8.GetBytes([string]$Body) }
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Send-Json {
    param($Context, $Object, [int]$Status = 200)
    Send-Response -Context $Context -Status $Status -Body (ConvertTo-Json -InputObject $Object -Depth 10 -Compress)
}

function Send-Error {
    param($Context, [int]$Status, [string]$Message)
    Send-Json $Context ([pscustomobject]@{ error = $Message }) $Status
}

function Read-RequestBody {
    param($Request)
    if ($Request.ContentLength64 -gt 1MB) { throw [ArgumentException]"Request body too large" }
    $reader = New-Object IO.StreamReader -ArgumentList $Request.InputStream, $Request.ContentEncoding
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if (-not $text) { throw [ArgumentException]"Request body is required" }
    return $text | ConvertFrom-Json
}

function Test-Principal {
    param($User, [string[]]$Principals)
    if (-not $Principals) { return $false }
    foreach ($p in $Principals) {
        if ($User.Identity.Name -eq $p) { return $true }
        try { if ($User.IsInRole($p)) { return $true } } catch { }
    }
    return $false
}

function Get-Access {
    # returns 'none', 'read', 'write'
    param($Context)
    if ($Authentication -eq 'None') {
        if ($ReadOnly) { return 'read' } else { return 'write' }
    }
    $user = $Context.User
    if (-not $user -or -not $user.Identity.IsAuthenticated) { return 'none' }
    if ($AllowedPrincipals -and -not (Test-Principal $user $AllowedPrincipals)) {
        if (-not (Test-Principal $user $ReadOnlyPrincipals)) { return 'none' }
    }
    if ($ReadOnly -or (Test-Principal $user $ReadOnlyPrincipals)) { return 'read' }
    return 'write'
}

function Test-CanTestCredentials {
    # Read-only mode keeps the GoDaddy test available, but not for people listed as view-only.
    param($Context)
    return [bool]($ReadOnly -and ($Authentication -eq 'None' -or -not (Test-Principal $Context.User $ReadOnlyPrincipals)))
}

function Invoke-Route {
    param($Context)
    $req = $Context.Request
    $method = $req.HttpMethod
    $segments = @($req.Url.AbsolutePath.Trim('/').Split('/') | Where-Object { $_ } | ForEach-Object { [Uri]::UnescapeDataString($_) })

    $access = Get-Access $Context
    if ($access -eq 'none') { return Send-Error $Context 403 'You are not allowed to use this dashboard.' }
    $userName = if ($Context.User -and $Context.User.Identity.IsAuthenticated) { $Context.User.Identity.Name } else { [Environment]::UserDomainName + '\' + [Environment]::UserName }

    # Static files
    if ($segments.Count -eq 0 -or $segments[0] -ne 'api') {
        if ($method -ne 'GET' -and $method -ne 'HEAD') { return Send-Error $Context 405 'Method not allowed' }
        $rel = if ($segments.Count -eq 0) { 'index.html' } else { $segments -join '\' }
        $full = [IO.Path]::GetFullPath((Join-Path $WebRoot $rel))
        if (-not $full.StartsWith($WebRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
            return Send-Error $Context 404 'Not found'
        }
        $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
        $mime = if ($MimeTypes.ContainsKey($ext)) { $MimeTypes[$ext] } else { 'application/octet-stream' }
        return Send-Response -Context $Context -Body ([IO.File]::ReadAllBytes($full)) -ContentType $mime
    }

    # All state-changing API calls must come from our own page (CSRF protection).
    if ($method -ne 'GET' -and $req.Headers['X-Requested-With'] -ne 'PoshAcmeDashboard') {
        return Send-Error $Context 403 'Missing X-Requested-With header'
    }

    $route = "$method " + (($segments | Select-Object -Skip 1) -join '/')

    # Read-only mode: one allow-list in front of every route. Start-DashboardJob narrows POST jobs further.
    if ($ReadOnly -and $method -notin 'GET', 'HEAD' -and $route -ne 'POST jobs') {
        return Send-Error $Context 403 'The dashboard is in read-only mode.'
    }

    switch -Regex ($route) {
        '^GET info$' {
            return Send-Json $Context ([pscustomobject]@{
                version          = $DashboardVersion
                poshAcmeVersion  = "$($PoshAcmeModule.Version)"
                psVersion        = "$($PSVersionTable.PSVersion)"
                host             = [Environment]::MachineName
                runAs            = [Environment]::UserDomainName + '\' + [Environment]::UserName
                user             = $userName
                canWrite         = ($access -eq 'write')
                readOnlyMode     = [bool]$ReadOnly
                canTestCredentials = Test-CanTestCredentials $Context
                configRoot       = $ConfigRoot
                wellKnownServers = $WellKnownServers
                revokeReasons    = [enum]::GetNames((Get-Command Revoke-PACertificate).Parameters['Reason'].ParameterType)
            })
        }
        '^GET overview$' { return Send-Json $Context (Get-Overview) }
        '^GET tasks$'    { return Send-Json $Context (Get-RenewalTasks) }
        '^GET plugins$'  { return Send-Json $Context @(Get-PluginList) }
        '^GET templates$' { return Send-Json $Context @(Get-Templates) }
        '^GET settings$' {
            if ($access -ne 'write') { return Send-Error $Context 403 'You have read-only access.' }
            return Send-Json $Context (ConvertTo-PublicSettings (Get-DashboardSettings))
        }
        '^POST settings$' {
            if ($access -ne 'write') { return Send-Error $Context 403 'You have read-only access.' }
            $saved = Update-DashboardSettings (Read-RequestBody $req) $userName
            Write-Host ("[{0:HH:mm:ss}] {1} saved settings" -f (Get-Date), $userName)
            return Send-Json $Context (ConvertTo-PublicSettings $saved)
        }
        '^POST settings/email/test$' {
            if ($access -ne 'write') { return Send-Error $Context 403 'You have read-only access.' }
            # Test the values in the form without saving them; a blank secret falls back to the saved one.
            $body = Read-RequestBody $req
            $draft = Merge-SettingsInput (Get-DashboardSettings) ([pscustomobject]@{ email = (Get-Prop $body 'email') })
            $to = @(Get-Prop $body 'to' | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            foreach ($t in $to) { if (-not (Test-Email $t)) { throw [ArgumentException]"'$t' is not a valid email address" } }
            if (-not $to) { $to = @($draft.email.recipients) }
            try { Send-TestEmail $draft $to } catch [ArgumentException] { throw } catch { return Send-Error $Context 502 $_.Exception.Message }
            return Send-Json $Context ([pscustomobject]@{ sentTo = $to })
        }
        '^GET notifications$' { return Send-Json $Context (Get-NotificationStatus) }
        '^GET deployments$' { return Send-Json $Context (Get-DeploymentView (Get-Overview)) }
        '^POST deployments$' {
            if ($access -ne 'write') { return Send-Error $Context 403 'You have read-only access.' }
            $t = Set-DeploymentTarget (Read-RequestBody $req) $null $userName
            [void](Start-DeploymentCheck -Ids $t.id)
            return Send-Json $Context $t 201
        }
        '^PUT deployments/[0-9a-f]+$' {
            if ($access -ne 'write') { return Send-Error $Context 403 'You have read-only access.' }
            $t = Set-DeploymentTarget (Read-RequestBody $req) $segments[2] $userName
            if (-not $t.lastCheck) { [void](Start-DeploymentCheck -Ids $t.id) }
            return Send-Json $Context $t
        }
        '^DELETE deployments/[0-9a-f]+$' {
            if ($access -ne 'write') { return Send-Error $Context 403 'You have read-only access.' }
            Remove-DeploymentTarget $segments[2]
            return Send-Json $Context ([pscustomobject]@{ deleted = $segments[2] })
        }
        '^POST deployments/check$' {
            # Reading what servers present is harmless, so read-only users may trigger it too.
            $body = try { Read-RequestBody $req } catch { $null }
            $ids = @(Get-Prop $body 'ids' | Where-Object { "$_" -match '^[0-9a-f]+$' })
            [void](Start-DeploymentCheck -Ids $ids)   # queued if a check is already running
            return Send-Json $Context ([pscustomobject]@{ running = [bool]$script:DeployCheck }) 202
        }
        '^POST notifications/(digest|alerts)$' {
            if ($access -ne 'write') { return Send-Error $Context 403 'You have read-only access.' }
            $settings = Get-DashboardSettings
            if (-not $settings.email.enabled) { return Send-Error $Context 400 'Enable and save the email settings first.' }
            try {
                if ($segments[2] -eq 'digest') { $result = [pscustomobject]@{ certificates = (Send-Digest $settings) } }
                else { $result = Invoke-AlertCheck $settings -Force }
                Set-NotifyError $null
            } catch {
                Set-NotifyError $_.Exception.Message
                return Send-Error $Context 502 $_.Exception.Message
            }
            return Send-Json $Context $result
        }
        '^GET plugins/[^/]+$' { return Send-Json $Context (Get-PluginDetail $segments[2]) }
        '^GET jobs$' {
            return Send-Json $Context @($script:Jobs | Sort-Object id -Descending | ForEach-Object { ConvertTo-JobView $_ })
        }
        '^GET jobs/\d+$' {
            $entry = $script:Jobs | Where-Object { $_.id -eq [int]$segments[2] }
            if (-not $entry) { return Send-Error $Context 404 'Job not found' }
            return Send-Json $Context (ConvertTo-JobView $entry -WithLog)
        }
        '^POST jobs$' {
            if ($access -ne 'write' -and -not (Test-CanTestCredentials $Context)) { return Send-Error $Context 403 'You have read-only access.' }
            $body = Read-RequestBody $req
            $entry = Start-DashboardJob -Request $body -User $userName
            return Send-Json $Context (ConvertTo-JobView $entry) 202
        }
        '^GET servers/[^/]+/accounts/[^/]+/orders/[^/]+/files/(cert|chain|fullchain)$' {
            $folder = Resolve-OrderFolder $segments[2] $segments[4] $segments[6]
            $kind = $segments[8]
            $file = Join-Path $folder "$kind.cer"
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return Send-Error $Context 404 'File not found' }
            $downloadName = ($segments[6].Replace('!', 'wildcard') -replace '[^\w.-]', '_') + "-$kind.pem"
            return Send-Response -Context $Context -Body ([IO.File]::ReadAllBytes($file)) -ContentType 'application/x-pem-file' -Headers @{ 'Content-Disposition' = "attachment; filename=`"$downloadName`"" }
        }
        default { return Send-Error $Context 404 'Not found' }
    }
}

#endregion

. (Join-Path $PSScriptRoot 'lib\Deployments.ps1')
. (Join-Path $PSScriptRoot 'lib\Notifications.ps1')

function Test-DeploymentCheckDue {
    $hours = (Get-DashboardSettings).deployments.autoCheckHours
    if ($hours -le 0) { return $false }
    $last = (Get-DeploymentStore).lastFullCheck
    return -not $last -or [datetime]::Parse($last, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind') -lt [datetime]::UtcNow.AddHours(-$hours)
}

if ($NotifyOnce) {
    $settings = Get-DashboardSettings
    if (-not $settings.email.enabled) { Write-Host 'Email notifications are disabled in the dashboard settings.'; return }
    # refresh server checks first so alerts reflect what servers serve now
    if ((Test-DeploymentCheckDue) -and (Start-DeploymentCheck) -and $script:DeployCheck) {
        Write-Host 'Checking which certificate each server presents...'
        $script:DeployCheck.job | Wait-Job -Timeout 300 | Out-Null
        [void](Complete-DeploymentCheck)
    }
    Invoke-NotificationTick -IgnoreBackoff
    $status = Get-NotificationStatus
    if ($status.lastError) { Write-Error "Email notification failed: $($status.lastError)"; exit 1 }
    $never = { param($v) if ($v) { $v } else { 'never' } }
    Write-Host "Notifications checked. Last alert sent: $(& $never $status.lastAlertSent); last digest sent: $(& $never $status.lastDigestSent)."
    return
}

$scheme = if ($UseHttps) { 'https' } else { 'http' }
$prefix = "${scheme}://${ListenAddress}:$Port/"
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add($prefix)
if ($Authentication -eq 'Windows') {
    $listener.AuthenticationSchemes = [Net.AuthenticationSchemes]::IntegratedWindowsAuthentication
}

try {
    $listener.Start()
} catch {
    Write-Error ("Unable to listen on $prefix : $($_.Exception.Message)`n" +
        "Binding to anything other than localhost needs an elevated prompt or a URL reservation:`n" +
        "  netsh http add urlacl url=$prefix user=`"$([Environment]::UserDomainName)\$([Environment]::UserName)`"")
    if ($ReadOnlySandbox) { Remove-Item -LiteralPath $ReadOnlySandbox -Recurse -Force -ErrorAction SilentlyContinue }
    return
}

$browseUrl = $prefix.Replace('://+:', '://localhost:').Replace('://*:', '://localhost:')
Write-Host ''
Write-Host "  Posh-ACME Dashboard $DashboardVersion" -ForegroundColor Cyan
Write-Host "  Listening on   $prefix"
Write-Host "  Open           $browseUrl"
Write-Host "  Config folder  $ConfigRoot"
Write-Host "  Authentication $Authentication$(if ($ReadOnly) { ' (read-only)' })"
if ($ReadOnly) {
    Write-Host '  READ-ONLY MODE: no renewals or changes, no email, no server checks, no files written.' -ForegroundColor Yellow
    Write-Host '                  Only outbound call possible: read-only GoDaddy credential test (GET).' -ForegroundColor Yellow
}
Write-Host '  Press Ctrl+C to stop.'
Write-Host ''
if ($OpenBrowser) { Start-Process $browseUrl }

$script:NextNotifyTick = (Get-Date).AddSeconds(10)
function Invoke-ScheduledWork {
    if ($ReadOnly) { return }   # both jobs below write files, and alerts send email
    try {
        if (Complete-DeploymentCheck) { Write-Host ("[{0:HH:mm:ss}] Server certificate check finished" -f (Get-Date)) }
    } catch { Write-Warning "Server certificate check failed: $($_.Exception.Message)" }
    if ((Get-Date) -lt $script:NextNotifyTick) { return }
    $script:NextNotifyTick = (Get-Date).AddSeconds(60)
    try {
        if (Test-DeploymentCheckDue) { [void](Start-DeploymentCheck) }
    } catch { Write-Warning "Could not start server certificate check: $($_.Exception.Message)" }
    try { Invoke-NotificationTick } catch { Write-Warning "Notification check failed: $($_.Exception.Message)" }
}

try {
    while ($listener.IsListening) {
        $pending = $listener.GetContextAsync()
        # Poll so Ctrl+C is handled between waits.
        while (-not $pending.AsyncWaitHandle.WaitOne(250)) { Invoke-ScheduledWork }
        $context = $pending.GetAwaiter().GetResult()
        try {
            Invoke-Route $context
        } catch [ArgumentException] {
            try { Send-Error $context 400 $_.Exception.Message } catch { }
        } catch [Management.Automation.ItemNotFoundException] {
            try { Send-Error $context 404 $_.Exception.Message } catch { }
        } catch {
            Write-Warning "$($context.Request.HttpMethod) $($context.Request.Url.AbsolutePath): $($_.Exception.Message)"
            try { Send-Error $context 500 $_.Exception.Message } catch { }
        } finally {
            try { $context.Response.Close() } catch { }
        }
        Invoke-ScheduledWork
    }
} finally {
    $listener.Stop()
    $listener.Close()
    $running = @($script:Jobs | Where-Object { $_.Job.State -eq 'Running' })
    if ($running) {
        Write-Warning "$($running.Count) action(s) still running; waiting for them to finish so Posh-ACME state is restored..."
        $running.Job | Wait-Job | Out-Null
    }
    $script:Jobs | ForEach-Object { Remove-Job -Job $_.Job -Force -ErrorAction SilentlyContinue }
    if ($script:DeployCheck) { Remove-Job -Job $script:DeployCheck.job -Force -ErrorAction SilentlyContinue }
    if ($ReadOnlySandbox) { Remove-Item -LiteralPath $ReadOnlySandbox -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host 'Dashboard stopped.'
}
