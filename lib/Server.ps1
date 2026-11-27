# The localhost page server, shared by Hopover.ps1 and Show-RestorePlan.ps1: served on
# http://localhost only, every API request carrying a token that changes each run (so other sites
# open in the browser can't use it), and the page under a Content-Security-Policy that lets it talk
# to nothing but this server.

$PageCsp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:; base-uri 'none'; form-action 'none'"

function Send-Text($Ctx, [int]$Code, [string]$Type, [string]$Body) {
    $bytes = $Utf8.GetBytes($Body)
    $res = $Ctx.Response
    $res.StatusCode = $Code
    $res.ContentType = $Type
    $res.AddHeader('Cache-Control', 'no-store')
    $res.AddHeader('X-Content-Type-Options', 'nosniff')
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}
function Send-Json($Ctx, $Obj, [int]$Code = 200) { Send-Text $Ctx $Code 'application/json; charset=utf-8' (ConvertTo-Json -InputObject $Obj -Depth 12 -Compress) }

# An API refusal: a message code for the page's string table, and the details that fill it in.
function Send-Error($Ctx, [int]$Status, [string]$Code, $Details) {
    $body = [ordered]@{ error = $Code }
    if ($null -ne $Details) { $body.details = $Details }
    Send-Json $Ctx $body $Status
}

function Read-Body($Ctx) {
    $reader = New-Object System.IO.StreamReader($Ctx.Request.InputStream, $Utf8)
    try { return $reader.ReadToEnd() } finally { $reader.Close() }
}

# The page, with the view it starts on (home, or the restore plan) and, when $Token is given, this
# run's token. Without it the page takes the token from its address (#token=...), which only the
# browser this server opened knows: then a page fetched by anyone else on the PC can't use the API.
function Send-Page($Ctx, [string]$PagePath, [string]$Token, [string]$Start) {
    $html = [IO.File]::ReadAllText($PagePath).Replace('__TOKEN__', $Token).Replace('__START__', $Start)
    $Ctx.Response.AddHeader('Content-Security-Policy', $PageCsp)
    Send-Text $Ctx 200 'text/html; charset=utf-8' $html
}

function Test-RequestToken($Ctx, [string]$Token) { $Ctx.Request.Headers['X-Token'] -eq $Token }

# A listener on the first free port from $Port up.
function Start-LocalListener([int]$Port) {
    foreach ($p in $Port..($Port + 10)) {
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add("http://localhost:$p/")
        try { $l.Start(); return [pscustomobject]@{ Listener = $l; Port = $p } } catch { $l.Close() }
    }
    throw "Couldn't listen on ports $Port-$($Port + 10). Pass -Port with a free port."
}

# Serves requests one at a time until $KeepRunning says stop. $OnRequest gets each context.
function Invoke-LocalServer($Listener, [scriptblock]$OnRequest, [scriptblock]$KeepRunning) {
    try {
        while ((& $KeepRunning) -and $Listener.IsListening) {
            $task = $Listener.GetContextAsync()
            # Short waits keep Ctrl+C working; a blocking GetContext() ignores it.
            while (-not $task.AsyncWaitHandle.WaitOne(300)) { }
            $ctx = $task.GetAwaiter().GetResult()
            try { & $OnRequest $ctx | Out-Null }
            catch {
                # The browser dropped the connection (tab reloaded or closed mid-request): nothing to report.
                $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
                if ($inner -is [System.Net.HttpListenerException] -or $inner -is [System.IO.IOException]) { continue }
                Write-Host "Request failed: $($_.Exception.Message)" -ForegroundColor Yellow
                try { Send-Error $ctx 500 'server-error' @{ reason = $_.Exception.Message } } catch { }
            }
        }
    } finally {
        $Listener.Stop()
        $Listener.Close()
        Write-Host 'Stopped.'
    }
}
