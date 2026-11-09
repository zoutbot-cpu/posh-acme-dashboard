# Where certificates are installed ("deployments") and a live TLS check of what each server serves.
#
# Dot-sourced by Start-PoshAcmeDashboard.ps1. Relies on its Get-Prop, ConvertTo-IsoDate,
# $DashboardRoot and $SafeSegment.
#
# deployments.json holds the targets and the raw result of their last check. Whether a target is
# up to date is worked out when it is read, by comparing the served certificate with the order's
# current certificate, so a renewal immediately shows every server still serving the old one.

$DeploymentsFile = Join-Path $DashboardRoot 'deployments.json'
$DeployTypes = [ordered]@{
    iis       = 'IIS / Windows'
    proxy     = 'Load balancer / reverse proxy'
    exchange  = 'Exchange / mail'
    firewall  = 'Firewall / VPN'
    appliance = 'Appliance'
    other     = 'Other'
}
$DeployCheckModes = 'tls', 'smtp', 'none'
$DeployProbeTimeoutMs = 6000

#region Storage

function Get-DeploymentStore {
    $store = [ordered]@{ lastFullCheck = $null; targets = @() }
    if (Test-Path -LiteralPath $DeploymentsFile -PathType Leaf) {
        $raw = Get-Content -LiteralPath $DeploymentsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $store.lastFullCheck = Get-Prop $raw 'lastFullCheck'
        $store.targets = @(Get-Prop $raw 'targets' | Where-Object { $_ })
    }
    return $store
}

function Save-DeploymentStore {
    param($Store)
    [IO.File]::WriteAllText($DeploymentsFile, ($Store | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
}

function Set-DeploymentTarget {
    # Create (no Id) or update a target from browser input. Returns the saved target.
    param($Data, [string]$Id, [string]$User)
    $certKey = "$(Get-Prop $Data 'certKey')"
    $parts = $certKey.Split('|')
    if ($parts.Count -ne 3 -or ($parts | Where-Object { $_ -notmatch $SafeSegment })) { throw [ArgumentException]'Choose a certificate' }
    if (-not (Test-Path -LiteralPath (Join-Path $ConfigRoot ($parts -join '\') | Join-Path -ChildPath 'order.json'))) {
        throw [ArgumentException]'That certificate no longer exists'
    }

    $hostName = "$(Get-Prop $Data 'host')".Trim().ToLowerInvariant()
    if ($hostName -notmatch '^(\[[0-9a-f:]+\]|[0-9a-z]([0-9a-z.-]*[0-9a-z])?|[0-9a-f:]+)$') { throw [ArgumentException]'Host must be a DNS name or IP address' }
    $port = 0
    if (-not [int]::TryParse("$(Get-Prop $Data 'port')", [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw [ArgumentException]'Port must be 1-65535' }
    $sni = "$(Get-Prop $Data 'sni')".Trim().ToLowerInvariant()
    if ($sni -and $sni -notmatch '^[0-9a-z]([0-9a-z.-]*[0-9a-z])?$') { throw [ArgumentException]'Server name (SNI) must be a DNS name' }
    $mode = "$(Get-Prop $Data 'checkMode')"
    if ($mode -notin $DeployCheckModes) { throw [ArgumentException]"Check method must be one of: $($DeployCheckModes -join ', ')" }
    $type = "$(Get-Prop $Data 'type')"
    if (-not $DeployTypes.Contains($type)) { $type = 'other' }
    $owner = "$(Get-Prop $Data 'owner')".Trim()
    $notes = "$(Get-Prop $Data 'notes')".Trim()
    if ($owner.Length -gt 200 -or $notes.Length -gt 1000) { throw [ArgumentException]'Owner or notes are too long' }

    $store = Get-DeploymentStore
    $now = [datetime]::UtcNow.ToString('o')
    if ($Id) {
        $t = $store.targets | Where-Object { $_.id -eq $Id }
        if (-not $t) { throw [Management.Automation.ItemNotFoundException]'Server entry not found' }
        $endpointChanged = $t.host -ne $hostName -or [int]$t.port -ne $port -or "$($t.sni)" -ne $sni -or $t.checkMode -ne $mode
    } else {
        $t = [pscustomobject]@{ id = [guid]::NewGuid().ToString('n').Substring(0, 12); createdAt = $now; createdBy = $User; lastCheck = $null }
        $store.targets = @($store.targets) + $t
        $endpointChanged = $true
    }
    foreach ($kv in @{ certKey = $certKey; host = $hostName; port = $port; sni = $sni; checkMode = $mode; type = $type; owner = $owner; notes = $notes; updatedAt = $now; updatedBy = $User }.GetEnumerator()) {
        $t | Add-Member -NotePropertyName $kv.Key -NotePropertyValue $kv.Value -Force
    }
    # an old result for a different endpoint would be misleading
    if ($endpointChanged) { $t | Add-Member -NotePropertyName lastCheck -NotePropertyValue $null -Force }
    Save-DeploymentStore $store
    return $t
}

function Remove-DeploymentTarget {
    param([string]$Id)
    $store = Get-DeploymentStore
    $before = @($store.targets).Count
    $store.targets = @($store.targets | Where-Object { $_.id -ne $Id })
    if (@($store.targets).Count -eq $before) { throw [Management.Automation.ItemNotFoundException]'Server entry not found' }
    Save-DeploymentStore $store
}

#endregion

#region Status

function Get-ManagedCertIndex {
    # certKey -> current certificate info, from an overview
    param($Overview)
    $index = @{}
    foreach ($s in $Overview.servers) {
        foreach ($a in $s.accounts) {
            foreach ($o in $a.orders) {
                $index["$($s.name)|$($a.id)|$($o.name)"] = [pscustomobject]@{
                    mainDomain = if (Get-Prop $o 'mainDomain') { $o.mainDomain } else { $o.name }
                    serverUrl  = $s.location
                    account    = $a.id
                    order      = $o.name
                    cert       = Get-Prop $o 'cert'
                }
            }
        }
    }
    return $index
}

function Get-DeployStatus {
    # current | outdated | mismatch | unreachable | never | unchecked | no-cert
    param($Target, $Managed)
    if ($Target.checkMode -eq 'none') { return 'unchecked' }
    $lc = $Target.lastCheck
    if (-not $lc) { return 'never' }
    if (Get-Prop $lc 'error') { return 'unreachable' }
    $mc = if ($Managed) { $Managed.cert } else { $null }
    if (-not $mc -or -not (Get-Prop $mc 'thumbprint')) { return 'no-cert' }
    $served = $lc.served
    if ($served.thumbprint -eq $mc.thumbprint) { return 'current' }
    # Same names but an older certificate: the server wasn't updated after a renewal.
    $shared = @($served.sans | Where-Object { $_ -in @($mc.sans) })
    $older = [datetime]::Parse($served.notAfter, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind') -lt
        [datetime]::Parse($mc.notAfter, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind')
    if ($shared.Count -and $older) { return 'outdated' }
    return 'mismatch'
}

function Get-DeploymentView {
    # All targets with their certificate and computed status, for the browser and for alerts.
    param($Overview)
    $index = Get-ManagedCertIndex $Overview
    $store = Get-DeploymentStore
    $now = [datetime]::UtcNow
    $targets = @(foreach ($t in $store.targets) {
        $m = $index[$t.certKey]
        $status = Get-DeployStatus $t $m
        $servedDays = $null
        if ($t.lastCheck -and (Get-Prop $t.lastCheck 'served')) {
            $servedDays = [math]::Floor(([datetime]::Parse($t.lastCheck.served.notAfter, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind') - $now).TotalDays)
        }
        [pscustomobject]@{
            id = $t.id; certKey = $t.certKey; host = $t.host; port = $t.port; sni = $t.sni; checkMode = $t.checkMode
            type = $t.type; typeLabel = $DeployTypes[$t.type]; owner = $t.owner; notes = $t.notes
            createdAt = $t.createdAt; createdBy = $t.createdBy; updatedAt = Get-Prop $t 'updatedAt'; updatedBy = Get-Prop $t 'updatedBy'
            mainDomain = if ($m) { $m.mainDomain } else { $null }
            serverUrl = if ($m) { $m.serverUrl } else { $null }
            certMissing = -not $m
            currentThumbprint = if ($m -and $m.cert) { Get-Prop $m.cert 'thumbprint' } else { $null }
            renewedAt = if ($m -and $m.cert) { Get-Prop $m.cert 'notBefore' } else { $null }
            status = $status
            servedDaysLeft = $servedDays
            lastCheck = $t.lastCheck
        }
    })
    [pscustomobject]@{
        targets       = $targets
        lastFullCheck = $store.lastFullCheck
        checkRunning  = [bool]$script:DeployCheck
        checkStarted  = if ($script:DeployCheck) { $script:DeployCheck.started } else { $null }
        types         = $DeployTypes
    }
}

function Get-DeploymentSummary {
    # certKey -> counts, for the certificate table
    param($Overview)
    $summary = @{}
    foreach ($t in (Get-DeploymentView $Overview).targets) {
        if (-not $summary.ContainsKey($t.certKey)) { $summary[$t.certKey] = [ordered]@{ total = 0; current = 0; outdated = 0; problem = 0; unknown = 0 } }
        $c = $summary[$t.certKey]
        $c.total++
        switch ($t.status) {
            'current' { $c.current++ }
            'outdated' { $c.outdated++ }
            { $_ -in 'mismatch', 'unreachable' } { $c.problem++ }
            default { $c.unknown++ }
        }
    }
    return $summary
}

#endregion

#region Checks (background job)

# Runs in a separate PowerShell process. Probes targets in parallel and returns JSON.
$DeployProbeScript = {
    param([string]$TargetsJson, [int]$TimeoutMs)

    $probe = {
        param($t, [int]$TimeoutMs)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $tcp = New-Object Net.Sockets.TcpClient
        $ssl = $null
        try {
            $connectHost = $t.host.Trim('[', ']')
            $ar = $tcp.BeginConnect($connectHost, [int]$t.port, $null, $null)
            if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { throw "Connection to $($t.host):$($t.port) timed out after $([int]($TimeoutMs / 1000))s" }
            $tcp.EndConnect($ar)
            $stream = $tcp.GetStream()
            $stream.ReadTimeout = $TimeoutMs
            $stream.WriteTimeout = $TimeoutMs

            if ($t.checkMode -eq 'smtp') {
                # Read replies byte by byte so nothing of the TLS handshake ends up in a buffer.
                $readLine = {
                    $sb = New-Object Text.StringBuilder
                    while ($true) {
                        $b = $stream.ReadByte()
                        if ($b -lt 0) { throw 'The SMTP server closed the connection' }
                        if ($b -eq 10) { break }
                        if ($b -ne 13) { [void]$sb.Append([char]$b) }
                    }
                    $sb.ToString()
                }
                $readReply = {
                    $lines = @()
                    do { $l = & $readLine; $lines += $l } while ($l.Length -ge 4 -and $l[3] -eq '-')
                    , $lines
                }
                $send = { param($text) $bytes = [Text.Encoding]::ASCII.GetBytes("$text`r`n"); $stream.Write($bytes, 0, $bytes.Length) }
                $r = & $readReply; if ($r[-1] -notmatch '^220') { throw "Unexpected SMTP greeting: $($r[-1])" }
                & $send 'EHLO posh-acme-dashboard'
                $r = & $readReply; if ($r[-1] -notmatch '^250') { throw "EHLO was rejected: $($r[-1])" }
                if (-not ($r -match '^250[ -]STARTTLS')) { throw 'The SMTP server does not offer STARTTLS' }
                & $send 'STARTTLS'
                $r = & $readReply; if ($r[-1] -notmatch '^220') { throw "STARTTLS was rejected: $($r[-1])" }
            }

            # We only read the certificate, so accept whatever the server presents.
            $accept = [Net.Security.RemoteCertificateValidationCallback] { $true }
            $ssl = New-Object Net.Security.SslStream -ArgumentList $stream, $false, $accept
            $sni = if ($t.sni) { $t.sni } else { $connectHost }
            $protocols = if ($PSVersionTable.PSEdition -eq 'Core') { [Security.Authentication.SslProtocols]::None }
                         else { [Security.Authentication.SslProtocols]'Tls12, Tls11, Tls' }
            $ssl.AuthenticateAsClient($sni, $null, $protocols, $false)

            $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $ssl.RemoteCertificate
            $sans = @()
            $ext = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }
            if ($ext) { $sans = @($ext.Format($false) -split ',\s*' | ForEach-Object { ($_ -replace '^[^=:]+[=:]\s*', '').Trim().ToLowerInvariant() } | Where-Object { $_ }) }
            [pscustomobject]@{
                id = $t.id; checkedAt = [datetime]::UtcNow.ToString('o'); durationMs = $sw.ElapsedMilliseconds; error = $null
                served = [pscustomobject]@{
                    thumbprint = $cert.Thumbprint
                    subject    = $cert.Subject
                    issuer     = $cert.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $true)
                    serial     = $cert.SerialNumber
                    notBefore  = $cert.NotBefore.ToUniversalTime().ToString('o')
                    notAfter   = $cert.NotAfter.ToUniversalTime().ToString('o')
                    sans       = $sans
                    protocol   = "$($ssl.SslProtocol)"
                }
            }
        } catch {
            # Report the innermost useful message ("No such host is known", "actively refused", ...).
            $ex = $_.Exception
            while ($ex.InnerException) { $ex = $ex.InnerException }
            $msg = $ex.Message -replace '^Exception calling "\w+" with "\d+" argument\(s\): ', '' -replace '"$', ''
            [pscustomobject]@{ id = $t.id; checkedAt = [datetime]::UtcNow.ToString('o'); durationMs = $sw.ElapsedMilliseconds; error = $msg; served = $null }
        } finally {
            if ($ssl) { $ssl.Dispose() }
            $tcp.Close()
        }
    }

    # ForEach-Object unrolls the array (Windows PowerShell 5.1 returns it as a single object)
    $targets = @($TargetsJson | ConvertFrom-Json | ForEach-Object { $_ })
    $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Min(16, [Math]::Max(1, $targets.Count)))
    $pool.Open()
    $running = foreach ($t in $targets) {
        $ps = [powershell]::Create().AddScript($probe).AddArgument($t).AddArgument($TimeoutMs)
        $ps.RunspacePool = $pool
        [pscustomobject]@{ ps = $ps; handle = $ps.BeginInvoke() }
    }
    $results = foreach ($r in @($running)) {
        $r.ps.EndInvoke($r.handle)
        $r.ps.Dispose()
    }
    $pool.Close()
    ConvertTo-Json -InputObject @($results) -Depth 6 -Compress
}

$script:DeployCheck = $null
# Requests made while a check runs: target ids, or $true for "everything"
$script:DeployCheckQueue = $null

function Start-DeploymentCheck {
    # Probe the given targets (or all checkable ones). While a check runs, the request is queued.
    param([string[]]$Ids)
    if ($script:DeployCheck) {
        if (-not $Ids -or $script:DeployCheckQueue -eq $true) { $script:DeployCheckQueue = $true }
        else { $script:DeployCheckQueue = @(@($script:DeployCheckQueue) + $Ids | Where-Object { $_ } | Select-Object -Unique) }
        return $true
    }
    $store = Get-DeploymentStore
    $targets = @($store.targets | Where-Object { $_.checkMode -ne 'none' -and (-not $Ids -or $_.id -in $Ids) } |
        Select-Object id, host, port, sni, checkMode)
    if (-not $targets.Count) { return $true }
    $job = Start-Job -ScriptBlock $DeployProbeScript -ArgumentList (ConvertTo-Json -InputObject $targets -Compress), $DeployProbeTimeoutMs
    $script:DeployCheck = [pscustomobject]@{ job = $job; full = -not $Ids; started = [datetime]::UtcNow.ToString('o') }
    return $true
}

function Complete-DeploymentCheck {
    # Called from the server loop: store results of a finished check. Returns $true when results were stored.
    if (-not $script:DeployCheck) { return $false }
    $job = $script:DeployCheck.job
    if ($job.State -eq 'Running' -or $job.State -eq 'NotStarted') { return $false }
    $full = $script:DeployCheck.full
    $script:DeployCheck = $null
    try {
        $out = @(Receive-Job -Job $job -ErrorAction Stop)
        $results = @(($out -join '') | ConvertFrom-Json | ForEach-Object { $_ })
    } catch {
        Write-Warning "Server certificate check failed: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    $store = Get-DeploymentStore
    foreach ($r in $results) {
        $t = $store.targets | Where-Object { $_.id -eq $r.id }
        if ($t) { $t | Add-Member -NotePropertyName lastCheck -NotePropertyValue $r -Force }
    }
    if ($full) { $store.lastFullCheck = [datetime]::UtcNow.ToString('o') }
    Save-DeploymentStore $store

    $queued = $script:DeployCheckQueue
    $script:DeployCheckQueue = $null
    if ($queued -eq $true) { [void](Start-DeploymentCheck) }
    elseif ($queued) { [void](Start-DeploymentCheck -Ids $queued) }
    return $true
}

#endregion
