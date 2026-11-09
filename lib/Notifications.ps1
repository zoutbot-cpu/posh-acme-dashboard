# Email notifications through Microsoft Graph (Microsoft 365), using an Entra ID app
# registration with the client credentials flow (client secret or certificate).
#
# Dot-sourced by Start-PoshAcmeDashboard.ps1. Relies on its Get-Overview, Get-Prop,
# ConvertTo-IsoDate, $WellKnownServers, $DashboardVersion and $DashboardRoot.
#
# settings.json      - configuration; the client secret is DPAPI-encrypted for the current user
# notify-state.json  - what was sent when, so alerts aren't repeated every check

$SettingsFile = Join-Path $DashboardRoot 'settings.json'
$NotifyStateFile = Join-Path $DashboardRoot 'notify-state.json'
$AlertCheckMinutes = 15

#region Settings

function Get-DefaultSettings {
    [ordered]@{
        email  = [ordered]@{
            enabled         = $false
            tenantId        = ''
            clientId        = ''
            authType        = 'secret'        # 'secret' or 'certificate'
            clientSecretEnc = ''
            certThumbprint  = ''
            certStore       = 'CurrentUser'   # 'CurrentUser' or 'LocalMachine'
            sender          = ''
            recipients      = @()
            dashboardUrl    = ''
        }
        alerts = [ordered]@{
            enabled       = $true
            expiringDays  = 14
            overdueDays   = 3
            reminderHours = 24
            includeFailed = $true
            skipStaging   = $true
            includeDeployments   = $true
            deploymentGraceHours = 24
        }
        digest = [ordered]@{
            enabled     = $false
            frequency   = 'weekly'            # 'daily' or 'weekly'
            dayOfWeek   = 'Monday'
            time        = '08:00'
            skipStaging = $true
        }
        deployments = [ordered]@{
            autoCheckHours = 6               # 0 = only check on demand
        }
        savedAt = $null
        savedBy = $null
    }
}

function Get-DashboardSettings {
    $settings = Get-DefaultSettings
    if (-not (Test-Path -LiteralPath $SettingsFile -PathType Leaf)) { return $settings }
    $loaded = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($section in 'email', 'alerts', 'digest', 'deployments') {
        $src = Get-Prop $loaded $section
        if (-not $src) { continue }
        foreach ($k in @($settings[$section].Keys)) {
            $p = $src.PSObject.Properties[$k]
            if ($p) { $settings[$section][$k] = $p.Value }
        }
    }
    $settings.email.recipients = @($settings.email.recipients | Where-Object { $_ })
    $settings.savedAt = Get-Prop $loaded 'savedAt'
    $settings.savedBy = Get-Prop $loaded 'savedBy'
    return $settings
}

function Save-DashboardSettings {
    param($Settings)
    $json = $Settings | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($SettingsFile, $json, (New-Object Text.UTF8Encoding $false))
}

function ConvertTo-PublicSettings {
    # Never send the (encrypted) secret to the browser.
    param($Settings)
    $email = [ordered]@{}
    foreach ($k in $Settings.email.Keys) { if ($k -ne 'clientSecretEnc') { $email[$k] = $Settings.email[$k] } }
    $email.clientSecretSet = [bool]$Settings.email.clientSecretEnc
    [pscustomobject]@{
        email   = [pscustomobject]$email
        alerts  = [pscustomobject]$Settings.alerts
        deployments = [pscustomobject]$Settings.deployments
        digest  = [pscustomobject]$Settings.digest
        savedAt = $Settings.savedAt
        savedBy = $Settings.savedBy
    }
}

function Protect-Secret {
    param([string]$Plain)
    ConvertTo-SecureString $Plain -AsPlainText -Force | ConvertFrom-SecureString
}

function Unprotect-Secret {
    param([string]$Encrypted)
    try {
        (New-Object PSCredential -ArgumentList 'x', (ConvertTo-SecureString $Encrypted)).GetNetworkCredential().Password
    } catch {
        throw "The saved client secret can't be decrypted. It was saved by a different Windows user or machine; enter it again."
    }
}

function Test-Email { param([string]$Value) $Value -match '^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$' }

<#
 Merge a settings object posted by the browser into $Base and validate it.
 email.clientSecret (plain) replaces the saved secret when non-empty; email.clearSecret removes it.
#>
function Merge-SettingsInput {
    param($Base, $Data)
    $s = $Base
    $e = Get-Prop $Data 'email'
    if ($e) {
        foreach ($k in 'enabled', 'tenantId', 'clientId', 'authType', 'certThumbprint', 'certStore', 'sender', 'recipients', 'dashboardUrl') {
            $p = $e.PSObject.Properties[$k]
            if ($p) { $s.email[$k] = $p.Value }
        }
        $s.email.enabled = [bool]$s.email.enabled
        foreach ($k in 'tenantId', 'clientId', 'certThumbprint', 'sender', 'dashboardUrl') { $s.email[$k] = "$($s.email[$k])".Trim() }
        $s.email.certThumbprint = ($s.email.certThumbprint -replace '[^0-9a-fA-F]', '').ToUpperInvariant()
        $s.email.recipients = @(@($s.email.recipients) | ForEach-Object { "$_" -split '[,;\s]+' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        if ((Get-Prop $e 'clearSecret')) { $s.email.clientSecretEnc = '' }
        $newSecret = Get-Prop $e 'clientSecret'
        if ($newSecret) { $s.email.clientSecretEnc = Protect-Secret $newSecret }
    }
    $a = Get-Prop $Data 'alerts'
    if ($a) {
        foreach ($k in @($s.alerts.Keys)) { $p = $a.PSObject.Properties[$k]; if ($p) { $s.alerts[$k] = $p.Value } }
    }
    $dp = Get-Prop $Data 'deployments'
    if ($dp) {
        foreach ($k in @($s.deployments.Keys)) { $p = $dp.PSObject.Properties[$k]; if ($p) { $s.deployments[$k] = $p.Value } }
    }
    $d = Get-Prop $Data 'digest'
    if ($d) {
        foreach ($k in @($s.digest.Keys)) { $p = $d.PSObject.Properties[$k]; if ($p) { $s.digest[$k] = $p.Value } }
    }

    # validation
    $em = $s.email
    if ($em.authType -notin 'secret', 'certificate') { throw [ArgumentException]"authType must be 'secret' or 'certificate'" }
    if ($em.certStore -notin 'CurrentUser', 'LocalMachine') { throw [ArgumentException]"certStore must be CurrentUser or LocalMachine" }
    if ($em.tenantId -and $em.tenantId -notmatch '^[\w.-]+$') { throw [ArgumentException]"Tenant ID must be a GUID or a domain like contoso.onmicrosoft.com" }
    if ($em.clientId -and $em.clientId -notmatch '^[0-9a-fA-F-]{36}$') { throw [ArgumentException]"Client ID must be the application (client) ID GUID" }
    if ($em.certThumbprint -and $em.certThumbprint.Length -ne 40) { throw [ArgumentException]"Certificate thumbprint must be 40 hex characters" }
    if ($em.sender -and -not (Test-Email $em.sender)) { throw [ArgumentException]"Sender must be a mailbox address" }
    foreach ($r in $em.recipients) { if (-not (Test-Email $r)) { throw [ArgumentException]"'$r' is not a valid email address" } }
    if ($em.dashboardUrl -and $em.dashboardUrl -notmatch '^https?://\S+$') { throw [ArgumentException]"Dashboard URL must start with http:// or https://" }
    if ($em.enabled) {
        $missing = @()
        if (-not $em.tenantId) { $missing += 'tenant ID' }
        if (-not $em.clientId) { $missing += 'client ID' }
        if ($em.authType -eq 'secret' -and -not $em.clientSecretEnc) { $missing += 'client secret' }
        if ($em.authType -eq 'certificate' -and -not $em.certThumbprint) { $missing += 'certificate thumbprint' }
        if (-not $em.sender) { $missing += 'sender mailbox' }
        if (-not $em.recipients) { $missing += 'recipients' }
        if ($missing) { throw [ArgumentException]"To enable email, fill in: $($missing -join ', ')" }
    }

    $al = $s.alerts
    $al.enabled = [bool]$al.enabled; $al.includeFailed = [bool]$al.includeFailed; $al.skipStaging = [bool]$al.skipStaging
    $al.includeDeployments = [bool]$al.includeDeployments
    foreach ($k in 'expiringDays', 'overdueDays', 'reminderHours', 'deploymentGraceHours') {
        $n = 0
        if (-not [int]::TryParse("$($al[$k])", [ref]$n) -or $n -lt 0 -or $n -gt 365 * 24) { throw [ArgumentException]"$k must be a whole number" }
        $al[$k] = $n
    }
    if ($al.reminderHours -lt 1) { throw [ArgumentException]"reminderHours must be at least 1" }

    $n = 0
    if (-not [int]::TryParse("$($s.deployments.autoCheckHours)", [ref]$n) -or $n -lt 0 -or $n -gt 168) { throw [ArgumentException]"Automatic server checks must be every 0-168 hours" }
    $s.deployments.autoCheckHours = $n

    $dg = $s.digest
    $dg.enabled = [bool]$dg.enabled; $dg.skipStaging = [bool]$dg.skipStaging
    if ($dg.frequency -notin 'daily', 'weekly') { throw [ArgumentException]"Digest frequency must be daily or weekly" }
    if ($dg.dayOfWeek -notin [enum]::GetNames([DayOfWeek])) { throw [ArgumentException]"Invalid day of week" }
    if ($dg.time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw [ArgumentException]"Digest time must be HH:mm (24-hour)" }
    return $s
}

function Update-DashboardSettings {
    param($Data, [string]$User)
    $s = Merge-SettingsInput (Get-DashboardSettings) $Data
    $s.savedAt = [datetime]::UtcNow.ToString('o')
    $s.savedBy = $User
    Save-DashboardSettings $s
    $script:GraphToken = $null
    return $s
}

#endregion

#region Microsoft Graph

$script:GraphToken = $null

function ConvertTo-B64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-RestErrorText {
    # Turns OAuth / Graph error responses into an actionable message.
    param($ErrorRecord, [string]$Stage)
    $status = 0
    try { $status = [int]$ErrorRecord.Exception.Response.StatusCode } catch { }
    $body = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        try { $body = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json } catch { }
    }
    if ($Stage -eq 'token') {
        $desc = Get-Prop $body 'error_description'
        $msg = if ($desc) { (($desc -split "`r?`n")[0] -replace '\s*Trace ID:.*$', '').Trim() } else { $ErrorRecord.Exception.Message }
        $hint = switch -Regex ($msg) {
            'AADSTS90002|AADSTS900023' { 'The tenant ID is wrong.' }
            'AADSTS700016'             { 'No app with this client ID exists in the tenant.' }
            'AADSTS7000215|AADSTS7000222' { 'The client secret is wrong or has expired. Create a new secret in the app registration.' }
            'AADSTS700027|AADSTS700024|AADSTS50173' { 'The certificate is not uploaded to the app registration, or the server clock is off.' }
            'AADSTS7000112'            { 'The app registration is disabled.' }
            default { $null }
        }
        return (@("Sign-in to Microsoft Entra ID failed: $msg", $hint) | Where-Object { $_ }) -join ' '
    }
    $err = Get-Prop $body 'error'
    $code = Get-Prop $err 'code'
    $msg = if (Get-Prop $err 'message') { $err.message } else { $ErrorRecord.Exception.Message }
    $hint = switch -Regex ("$status $code") {
        'ErrorAccessDenied|AccessDenied|^403' { 'The app needs the Microsoft Graph application permission Mail.Send with admin consent, and must be allowed to send as this mailbox if it is restricted with RBAC for Applications or an application access policy.' }
        'ErrorInvalidUser|ResourceNotFound|^404' { 'The sender mailbox does not exist in this tenant.' }
        'MailboxNotEnabledForRESTAPI' { 'The sender must be an Exchange Online mailbox (user or shared mailbox).' }
        'ErrorInvalidRecipients' { 'One of the recipient addresses is invalid.' }
        default { $null }
    }
    return (@("Sending through Microsoft Graph failed ($status $code): $msg", $hint) | Where-Object { $_ }) -join ' '
}

function Get-GraphToken {
    param($Email)
    $cacheKey = '{0}|{1}|{2}|{3}|{4}' -f $Email.tenantId, $Email.clientId, $Email.authType, $Email.certThumbprint, $Email.clientSecretEnc.GetHashCode()
    if ($script:GraphToken -and $script:GraphToken.key -eq $cacheKey -and $script:GraphToken.expires -gt [datetime]::UtcNow.AddMinutes(5)) {
        return $script:GraphToken.token
    }

    $tokenUrl = "https://login.microsoftonline.com/$($Email.tenantId)/oauth2/v2.0/token"
    $body = @{
        client_id  = $Email.clientId
        scope      = 'https://graph.microsoft.com/.default'
        grant_type = 'client_credentials'
    }
    if ($Email.authType -eq 'certificate') {
        $body.client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        $body.client_assertion = New-ClientAssertion -Cert (Get-AuthCertificate $Email) -ClientId $Email.clientId -Audience $tokenUrl
    } else {
        if (-not $Email.clientSecretEnc) { throw 'No client secret is saved.' }
        $body.client_secret = Unprotect-Secret $Email.clientSecretEnc
    }

    try {
        $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop -UseBasicParsing
    } catch {
        throw (Get-RestErrorText $_ 'token')
    }
    $script:GraphToken = @{ key = $cacheKey; token = $resp.access_token; expires = [datetime]::UtcNow.AddSeconds([int]$resp.expires_in) }
    return $resp.access_token
}

function Get-AuthCertificate {
    param($Email)
    $path = "Cert:\$($Email.certStore)\My\$($Email.certThumbprint)"
    $cert = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if (-not $cert) { throw "Certificate $($Email.certThumbprint) was not found in $($Email.certStore)\My." }
    if (-not $cert.HasPrivateKey) { throw "Certificate $($Email.certThumbprint) has no private key that this user can access." }
    if ($cert.NotAfter -lt (Get-Date)) { throw "Certificate $($Email.certThumbprint) expired on $($cert.NotAfter)." }
    return $cert
}

function New-ClientAssertion {
    # Signed JWT for the OAuth client credentials flow with a certificate (RFC 7523).
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Cert, [string]$ClientId, [string]$Audience)
    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Cert)
    if (-not $rsa) { throw 'The certificate must have an RSA private key.' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = [ordered]@{ alg = 'RS256'; typ = 'JWT'; x5t = (ConvertTo-B64Url $Cert.GetCertHash()) } | ConvertTo-Json -Compress
    $payload = [ordered]@{ aud = $Audience; iss = $ClientId; sub = $ClientId; jti = [guid]::NewGuid().ToString(); nbf = $now - 60; exp = $now + 600 } | ConvertTo-Json -Compress
    $unsigned = (ConvertTo-B64Url ([Text.Encoding]::UTF8.GetBytes($header))) + '.' + (ConvertTo-B64Url ([Text.Encoding]::UTF8.GetBytes($payload)))
    $sig = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($unsigned), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    return $unsigned + '.' + (ConvertTo-B64Url $sig)
}

function Send-GraphMail {
    param($Email, [string[]]$To, [string]$Subject, [string]$Html)
    $token = Get-GraphToken $Email
    $message = @{
        message = @{
            subject      = $Subject
            body         = @{ contentType = 'HTML'; content = $Html }
            toRecipients = @($To | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
        }
        saveToSentItems = $false
    }
    $json = $message | ConvertTo-Json -Depth 8 -Compress
    $uri = "https://graph.microsoft.com/v1.0/users/$([Uri]::EscapeDataString($Email.sender))/sendMail"
    try {
        Invoke-RestMethod -Method Post -Uri $uri -Headers @{ Authorization = "Bearer $token" } -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop -UseBasicParsing | Out-Null
    } catch {
        throw (Get-RestErrorText $_ 'send')
    }
}

#endregion

#region Email content

function ConvertTo-Html { param($Text) [Net.WebUtility]::HtmlEncode("$Text") }

function Format-LocalDate {
    param($Iso)
    if (-not $Iso) { return '-' }
    ([datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind')).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
}

function Get-ServerLabel {
    param([string]$Url)
    $names = @{ LE_PROD = "Let's Encrypt"; LE_STAGE = "Let's Encrypt (staging)"; ZEROSSL_PROD = 'ZeroSSL'; GOOGLE_PROD = 'Google'; GOOGLE_STAGE = 'Google (staging)' }
    foreach ($k in $WellKnownServers.Keys) {
        if ($WellKnownServers[$k] -eq $Url) { if ($names.ContainsKey($k)) { return $names[$k] } else { return $k } }
    }
    try { return ([Uri]$Url).Host } catch { return $Url }
}

function Test-StagingServer { param([string]$Url) $Url -match 'stag|test' }

function Get-FlatOrders {
    param($Overview, [bool]$SkipStaging)
    $now = [datetime]::UtcNow
    foreach ($s in $Overview.servers) {
        if ($SkipStaging -and (Test-StagingServer $s.location)) { continue }
        foreach ($a in $s.accounts) {
            foreach ($o in $a.orders) {
                $notAfter = $null
                if ((Get-Prop $o 'cert') -and (Get-Prop $o.cert 'notAfter')) { $notAfter = $o.cert.notAfter }
                $days = if ($notAfter) { [math]::Floor(([datetime]::Parse($notAfter, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind') - $now).TotalDays) } else { $null }
                [pscustomobject]@{
                    key        = "$($s.name)|$($a.id)|$($o.name)"
                    name       = $o.name
                    mainDomain = if (Get-Prop $o 'mainDomain') { $o.mainDomain } else { $o.name }
                    sans       = @(Get-Prop $o 'sans')
                    health     = $o.health
                    status     = Get-Prop $o 'status'
                    notAfter   = $notAfter
                    renewAfter = Get-Prop $o 'renewAfter'
                    daysLeft   = $days
                    plugin     = @(Get-Prop $o 'plugin') -join ', '
                    server     = Get-ServerLabel $s.location
                    account    = $a.id
                }
            }
        }
    }
}

$HealthStyle = @{
    'valid'       = @('Valid', '#16794c', '#dcf3e7')
    'renewal-due' = @('Renewal due', '#9a5b00', '#fdf0d5')
    'expiring'    = @('Expiring', '#b42318', '#fde4e1')
    'expired'     = @('Expired', '#b42318', '#fde4e1')
    'pending'     = @('Not issued', '#5d6b7c', '#f0f3f7')
    'invalid'     = @('Failed', '#b42318', '#fde4e1')
    'overdue'     = @('Renewal overdue', '#b42318', '#fde4e1')
}

$DeployStyle = @{
    'outdated'    = @('Old certificate', '#b42318', '#fde4e1')
    'mismatch'    = @('Wrong certificate', '#b42318', '#fde4e1')
    'unreachable' = @('Unreachable', '#9a5b00', '#fdf0d5')
}

function New-EmailHtml {
    param([string]$Title, [string]$IntroHtml, $Rows, [string]$DashboardUrl, [switch]$WithReason, $DeployRows)
    $cell = 'padding:8px 10px;border-bottom:1px solid #dde3ea;text-align:left;vertical-align:top;'
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append("<div style=`"font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#17202b;`">")
    [void]$sb.Append("<h2 style=`"margin:0 0 8px;font-size:18px;`">$(ConvertTo-Html $Title)</h2>")
    [void]$sb.Append("<p style=`"margin:0 0 14px;`">$IntroHtml</p>")
    if (@($Rows).Count) {
        [void]$sb.Append("<table style=`"border-collapse:collapse;width:100%;max-width:900px;`"><tr style=`"background:#f0f3f7;`">")
        foreach ($h in 'Status', 'Certificate', 'Expires', 'Renews after', 'Validation', 'Account') {
            [void]$sb.Append("<th style=`"$cell font-size:12px;color:#5d6b7c;text-transform:uppercase;`">$h</th>")
        }
        [void]$sb.Append('</tr>')
        foreach ($r in $Rows) {
            $styleKey = if ($WithReason -and $r.PSObject.Properties['issue']) { $r.issue } else { $r.health }
            $st = $HealthStyle[$styleKey]; if (-not $st) { $st = @($styleKey, '#5d6b7c', '#f0f3f7') }
            $expires = if ($r.notAfter) {
                $d = if ($r.daysLeft -lt 0) { "expired $(-$r.daysLeft) days ago" } else { "$($r.daysLeft) days" }
                "$(Format-LocalDate $r.notAfter)<br><span style=`"color:#5d6b7c;font-size:12px;`">$d</span>"
            } else { '-' }
            $sanText = if ($r.sans.Count) { "<br><span style=`"color:#5d6b7c;font-size:12px;`">+$($r.sans.Count) SAN: $(ConvertTo-Html ($r.sans -join ', '))</span>" } else { '' }
            [void]$sb.Append('<tr>')
            [void]$sb.Append("<td style=`"$cell`"><span style=`"display:inline-block;padding:2px 8px;border-radius:10px;font-size:12px;font-weight:600;color:$($st[1]);background:$($st[2]);white-space:nowrap;`">$(ConvertTo-Html $st[0])</span></td>")
            [void]$sb.Append("<td style=`"$cell`"><strong>$(ConvertTo-Html $r.mainDomain)</strong>$sanText</td>")
            [void]$sb.Append("<td style=`"$cell white-space:nowrap;`">$expires</td>")
            [void]$sb.Append("<td style=`"$cell white-space:nowrap;`">$(Format-LocalDate $r.renewAfter)</td>")
            [void]$sb.Append("<td style=`"$cell`">$(ConvertTo-Html $r.plugin)</td>")
            [void]$sb.Append("<td style=`"$cell font-size:12px;`">$(ConvertTo-Html $r.server)<br>$(ConvertTo-Html $r.account)</td>")
            [void]$sb.Append('</tr>')
        }
        [void]$sb.Append('</table>')
    }
    if (@($DeployRows).Count) {
        [void]$sb.Append("<h3 style=`"margin:20px 0 6px;font-size:15px;`">Servers that need the current certificate</h3>")
        [void]$sb.Append("<p style=`"margin:0 0 10px;`">The certificate on these servers no longer matches the one Posh-ACME manages. Install the current certificate on them.</p>")
        [void]$sb.Append("<table style=`"border-collapse:collapse;width:100%;max-width:900px;`"><tr style=`"background:#f0f3f7;`">")
        foreach ($h in 'Status', 'Server', 'Certificate', 'Serving', 'Type / owner') {
            [void]$sb.Append("<th style=`"$cell font-size:12px;color:#5d6b7c;text-transform:uppercase;`">$h</th>")
        }
        [void]$sb.Append('</tr>')
        foreach ($r in $DeployRows) {
            $st = $DeployStyle[$r.issue]; if (-not $st) { $st = @($r.issue, '#5d6b7c', '#f0f3f7') }
            $endpoint = "$($r.host):$($r.port)" + $(if ($r.sni -and $r.sni -ne $r.host) { " (SNI $($r.sni))" } else { '' })
            $serving = if ($r.servedNotAfter) {
                "expires $(Format-LocalDate $r.servedNotAfter)<br><span style=`"color:#5d6b7c;font-size:12px;`">$(ConvertTo-Html $r.servedThumbprint)</span>"
            } elseif ($r.error) { ConvertTo-Html $r.error } else { '-' }
            [void]$sb.Append('<tr>')
            [void]$sb.Append("<td style=`"$cell`"><span style=`"display:inline-block;padding:2px 8px;border-radius:10px;font-size:12px;font-weight:600;color:$($st[1]);background:$($st[2]);white-space:nowrap;`">$(ConvertTo-Html $st[0])</span></td>")
            [void]$sb.Append("<td style=`"$cell`"><strong>$(ConvertTo-Html $endpoint)</strong></td>")
            [void]$sb.Append("<td style=`"$cell`">$(ConvertTo-Html $r.mainDomain)</td>")
            [void]$sb.Append("<td style=`"$cell`">$serving</td>")
            [void]$sb.Append("<td style=`"$cell font-size:12px;`">$(ConvertTo-Html $r.typeLabel)$(if ($r.owner) { '<br>' + (ConvertTo-Html $r.owner) })</td>")
            [void]$sb.Append('</tr>')
        }
        [void]$sb.Append('</table>')
    }
    if ($DashboardUrl) {
        [void]$sb.Append("<p style=`"margin:16px 0 0;`"><a href=`"$(ConvertTo-Html $DashboardUrl)`" style=`"color:#2563eb;`">Open the Posh-ACME dashboard</a></p>")
    }
    [void]$sb.Append("<p style=`"margin:16px 0 0;color:#5d6b7c;font-size:12px;`">Sent by Posh-ACME Dashboard $DashboardVersion on $(ConvertTo-Html ([Environment]::MachineName)) for $(ConvertTo-Html ([Environment]::UserDomainName + '\' + [Environment]::UserName)).</p></div>")
    return $sb.ToString()
}

#endregion

#region State, alerts, digest

function Get-NotifyState {
    $state = [ordered]@{ lastAlertCheck = $null; lastAlertSent = $null; lastDigestSent = $null; lastError = $null; lastErrorAt = $null; alerts = @{} }
    if (Test-Path -LiteralPath $NotifyStateFile -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $NotifyStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in 'lastAlertCheck', 'lastAlertSent', 'lastDigestSent', 'lastError', 'lastErrorAt') { $state[$k] = Get-Prop $raw $k }
            $al = Get-Prop $raw 'alerts'
            if ($al) { foreach ($p in $al.PSObject.Properties) { $state.alerts[$p.Name] = @{ issue = $p.Value.issue; lastSent = $p.Value.lastSent } } }
        } catch { }
    }
    return $state
}

function Save-NotifyState {
    param($State)
    [IO.File]::WriteAllText($NotifyStateFile, ($State | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
}

function Get-AlertCandidates {
    # Certificates that need attention according to the alert settings, with the reason.
    param($Settings, $Overview)
    $al = $Settings.alerts
    $now = [datetime]::UtcNow
    foreach ($r in @(Get-FlatOrders $Overview $al.skipStaging)) {
        $issue = $null
        if ($r.health -eq 'expired') { $issue = 'expired' }
        elseif ($null -ne $r.daysLeft -and $r.daysLeft -le $al.expiringDays) { $issue = 'expiring' }
        elseif ($r.renewAfter -and $now -gt [datetime]::Parse($r.renewAfter, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind').AddDays($al.overdueDays)) { $issue = 'overdue' }
        elseif ($al.includeFailed -and $r.health -eq 'invalid') { $issue = 'invalid' }
        if ($issue) {
            $r | Add-Member -NotePropertyName issue -NotePropertyValue $issue -PassThru
        }
    }
}

function Get-DeploymentAlertCandidates {
    # Servers still serving an old certificate (after the grace period) or a different certificate.
    param($Settings, $Overview, [string[]]$Statuses = @('outdated', 'mismatch'), [switch]$IgnoreGrace)
    $al = $Settings.alerts
    $now = [datetime]::UtcNow
    foreach ($t in (Get-DeploymentView $Overview).targets) {
        if ($t.status -notin $Statuses) { continue }
        if ($al.skipStaging -and $t.serverUrl -and (Test-StagingServer $t.serverUrl)) { continue }
        if ($t.status -eq 'outdated' -and -not $IgnoreGrace -and $t.renewedAt -and
            [datetime]::Parse($t.renewedAt, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind').ToUniversalTime() -gt $now.AddHours(-$al.deploymentGraceHours)) { continue }
        $served = if ($t.lastCheck) { Get-Prop $t.lastCheck 'served' } else { $null }
        [pscustomobject]@{
            key = "deploy|$($t.id)"; issue = $t.status; host = $t.host; port = $t.port; sni = $t.sni
            mainDomain = $t.mainDomain; typeLabel = $t.typeLabel; owner = $t.owner
            servedNotAfter = if ($served) { $served.notAfter } else { $null }
            servedThumbprint = if ($served) { $served.thumbprint } else { $null }
            error = if ($t.lastCheck) { Get-Prop $t.lastCheck 'error' } else { $null }
        }
    }
}

function Invoke-AlertCheck {
    # Sends one email for certificates that newly need attention or whose reminder is due.
    # -Force sends every current issue regardless of when it was last reported.
    param($Settings, [switch]$Force)
    $state = Get-NotifyState
    $now = [datetime]::UtcNow
    $overview = Get-Overview
    $candidates = @(Get-AlertCandidates $Settings $overview)
    if ($Settings.alerts.includeDeployments) { $candidates += @(Get-DeploymentAlertCandidates $Settings $overview) }
    $toSend = @($candidates | Where-Object {
        $prev = $state.alerts[$_.key]
        $Force -or -not $prev -or $prev.issue -ne $_.issue -or
            ([datetime]::Parse($prev.lastSent, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind') -lt $now.AddHours(-$Settings.alerts.reminderHours))
    })

    # forget certificates that recovered, so a new problem alerts immediately
    foreach ($k in @($state.alerts.Keys)) { if ($k -notin $candidates.key) { $state.alerts.Remove($k) } }
    $state.lastAlertCheck = $now.ToString('o')

    $sent = 0
    if ($toSend.Count) {
        $order = @{ expired = 0; expiring = 1; overdue = 2; invalid = 3 }
        $rows = @($toSend | Where-Object { $_.key -notlike 'deploy|*' } | Sort-Object { $order[$_.issue] }, daysLeft, mainDomain)
        $deployRows = @($toSend | Where-Object { $_.key -like 'deploy|*' } | Sort-Object issue, mainDomain, host)
        $labels = @{ expired = 'expired'; expiring = 'expiring soon'; overdue = 'overdue for renewal'; invalid = 'failed' }
        $parts = @($rows | Group-Object issue | ForEach-Object { "$($_.Count) $($labels[$_.Name])" })
        if ($deployRows.Count) { $parts += "$($deployRows.Count) server$(if ($deployRows.Count -ne 1) { 's' }) with an old or wrong certificate" }
        $subject = "[Posh-ACME] Certificates need attention: $($parts -join ', ')"
        $intro = if ($rows.Count) {
            "These certificates are expired, expire within $($Settings.alerts.expiringDays) days, or are more than $($Settings.alerts.overdueDays) days past their renew-after date. " +
            "A renewal that is overdue usually means the scheduled <code>Submit-Renewal</code> task is failing."
        } else { 'Some servers are not serving the current certificate.' }
        $html = New-EmailHtml -Title 'Certificates need attention' -IntroHtml $intro -Rows $rows -DeployRows $deployRows -DashboardUrl $Settings.email.dashboardUrl -WithReason
        Send-GraphMail $Settings.email $Settings.email.recipients $subject $html
        foreach ($r in @($rows) + @($deployRows)) { $state.alerts[$r.key] = @{ issue = $r.issue; lastSent = $now.ToString('o') } }
        $state.lastAlertSent = $now.ToString('o')
        $sent = $rows.Count + $deployRows.Count
    }
    Save-NotifyState $state
    return [pscustomobject]@{ checked = $candidates.Count; sent = $sent }
}

function Get-LastDigestOccurrence {
    # Most recent scheduled digest time (local) at or before now.
    param($Digest, [datetime]$Now = (Get-Date))
    $parts = $Digest.time.Split(':')
    $at = $Now.Date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
    if ($Digest.frequency -eq 'daily') {
        if ($at -gt $Now) { $at = $at.AddDays(-1) }
        return $at
    }
    $target = [DayOfWeek]$Digest.dayOfWeek
    $back = ([int]$Now.DayOfWeek - [int]$target + 7) % 7
    $at = $at.AddDays(-$back)
    if ($at -gt $Now) { $at = $at.AddDays(-7) }
    return $at
}

function Get-NextDigest {
    param($Digest)
    $last = Get-LastDigestOccurrence $Digest
    if ($Digest.frequency -eq 'daily') { $last.AddDays(1) } else { $last.AddDays(7) }
}

function Send-Digest {
    param($Settings)
    $overview = Get-Overview
    $rows = @(Get-FlatOrders $overview $Settings.digest.skipStaging)
    $digestAlerts = [pscustomobject]@{ alerts = [pscustomobject]@{ skipStaging = $Settings.digest.skipStaging; deploymentGraceHours = 0 } }
    $deployRows = @(Get-DeploymentAlertCandidates $digestAlerts $overview -Statuses 'outdated', 'mismatch', 'unreachable' -IgnoreGrace)
    $rank = @{ expired = 0; expiring = 1; invalid = 2; 'renewal-due' = 3; pending = 4; valid = 5 }
    $rows = @($rows | Sort-Object { $rank[$_.health] }, daysLeft, mainDomain)
    $bad = @($rows | Where-Object { $_.health -in 'expired', 'expiring', 'invalid' }).Count
    $due = @($rows | Where-Object { $_.health -eq 'renewal-due' }).Count
    $ok = @($rows | Where-Object { $_.health -eq 'valid' }).Count
    $period = if ($Settings.digest.frequency -eq 'daily') { 'Daily' } else { 'Weekly' }
    $subject = "[Posh-ACME] $period certificate summary: $($rows.Count) total" + $(if ($bad) { ", $bad need attention" } else { ', all OK' })
    $intro = "<strong>$($rows.Count)</strong> certificates: <strong>$ok</strong> valid, <strong>$due</strong> due for renewal, <strong>$bad</strong> expired, expiring within 7 days, or failed."
    if (-not $rows.Count) { $intro = 'No certificates are managed by Posh-ACME yet.' }
    if ($deployRows.Count) { $intro += " <strong>$($deployRows.Count)</strong> server$(if ($deployRows.Count -ne 1) { 's are' } else { ' is' }) not serving the current certificate." }
    $html = New-EmailHtml -Title "$period certificate summary" -IntroHtml $intro -Rows $rows -DeployRows $deployRows -DashboardUrl $Settings.email.dashboardUrl
    Send-GraphMail $Settings.email $Settings.email.recipients $subject $html
    $state = Get-NotifyState
    $state.lastDigestSent = [datetime]::UtcNow.ToString('o')
    Save-NotifyState $state
    return $rows.Count
}

function Send-TestEmail {
    param($Settings, [string[]]$To)
    if (-not $To) { $To = $Settings.email.recipients }
    if (-not $To) { throw [ArgumentException]'Enter at least one recipient.' }
    foreach ($k in 'tenantId', 'clientId', 'sender') { if (-not $Settings.email[$k]) { throw [ArgumentException]"Fill in the $k first." } }
    $intro = 'This is a test message from the Posh-ACME dashboard. If you can read this, Microsoft 365 email notifications are configured correctly.'
    $html = New-EmailHtml -Title 'Test email' -IntroHtml $intro -Rows @() -DashboardUrl $Settings.email.dashboardUrl
    Send-GraphMail $Settings.email $To '[Posh-ACME] Test email' $html
}

function Set-NotifyError {
    param([string]$Message)
    $state = Get-NotifyState
    $state.lastError = $Message
    $state.lastErrorAt = if ($Message) { [datetime]::UtcNow.ToString('o') } else { $null }
    Save-NotifyState $state
}

function Get-NotificationStatus {
    $s = Get-DashboardSettings
    $state = Get-NotifyState
    $overview = Get-Overview
    $preview = @(Get-AlertCandidates $s $overview | Select-Object key, mainDomain, issue, daysLeft, notAfter, server)
    if ($s.alerts.includeDeployments) {
        $preview += @(Get-DeploymentAlertCandidates $s $overview | ForEach-Object {
            [pscustomobject]@{ key = $_.key; mainDomain = "$($_.host):$($_.port) ($($_.mainDomain))"; issue = $_.issue; daysLeft = $null; notAfter = $_.servedNotAfter; server = $null }
        })
    }
    [pscustomobject]@{
        emailEnabled   = [bool]$s.email.enabled
        lastAlertCheck = $state.lastAlertCheck
        lastAlertSent  = $state.lastAlertSent
        lastDigestSent = $state.lastDigestSent
        nextDigest     = if ($s.digest.enabled) { ConvertTo-IsoDate (Get-NextDigest $s.digest).ToUniversalTime() } else { $null }
        lastError      = $state.lastError
        lastErrorAt    = $state.lastErrorAt
        alertsPending  = $preview
        timeZone       = [TimeZoneInfo]::Local.DisplayName
    }
}

<#
 Called periodically by the server loop, or once with -NotifyOnce. Sends due alerts and digests.
 A named mutex keeps a running dashboard and a -NotifyOnce scheduled task from double-sending.
#>
function Invoke-NotificationTick {
    # -IgnoreBackoff is for one-off runs (-NotifyOnce); the server loop backs off after a failure.
    param([switch]$IgnoreBackoff)
    $s = Get-DashboardSettings
    if (-not $s.email.enabled) { return }
    if (-not $IgnoreBackoff) {
        $errAt = (Get-NotifyState).lastErrorAt
        if ($errAt -and [datetime]::Parse($errAt, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind') -gt [datetime]::UtcNow.AddMinutes(-$AlertCheckMinutes)) { return }
    }
    $mutex = New-Object Threading.Mutex -ArgumentList $false, 'Local\PoshAcmeDashboardNotify'
    $have = $false
    try {
        try { $have = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $have = $true }
        if (-not $have) { return }
        $state = Get-NotifyState
        $hadError = [bool]$state.lastError
        try {
            if ($s.alerts.enabled) {
                $last = if ($state.lastAlertCheck) { [datetime]::Parse($state.lastAlertCheck, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind') } else { [datetime]::MinValue }
                if ($last -lt [datetime]::UtcNow.AddMinutes(-$AlertCheckMinutes)) {
                    $r = Invoke-AlertCheck $s
                    if ($r.sent) { Write-Host ("[{0:HH:mm:ss}] Sent expiry alert for {1} certificate(s)" -f (Get-Date), $r.sent) }
                }
            }
            if ($s.digest.enabled) {
                $occurrence = Get-LastDigestOccurrence $s.digest
                # Only digests scheduled after the settings were saved, so enabling it doesn't send immediately.
                $since = @($state.lastDigestSent, $s.savedAt) | Where-Object { $_ } | ForEach-Object { [datetime]::Parse($_, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind').ToLocalTime() } | Sort-Object -Descending | Select-Object -First 1
                if (-not $since -or $occurrence -gt $since) {
                    $n = Send-Digest $s
                    Write-Host ("[{0:HH:mm:ss}] Sent {1} digest ({2} certificates)" -f (Get-Date), $s.digest.frequency, $n)
                }
            }
            if ($hadError) { Set-NotifyError $null }
        } catch {
            Write-Warning "Email notification failed: $($_.Exception.Message)"
            Set-NotifyError $_.Exception.Message
        }
    } finally {
        if ($have) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

#endregion
