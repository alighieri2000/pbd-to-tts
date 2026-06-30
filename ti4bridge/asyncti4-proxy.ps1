# AsyncTI4 Local Proxy
# -------------------------------------------------------------------
# Why this exists: TTS can't reach bot.asyncti4.com directly because
# the game server uses a newer encryption standard (TLS 1.3) that the
# TTS networking stack doesn't support.  This script runs a tiny HTTP
# server on YOUR PC.  TTS talks to it (plain HTTP, no encryption
# needed because it never leaves your computer), and it fetches the
# live game data and hands it back.
#
# HOW TO USE:
#   1. Right-click this file → "Run with PowerShell"
#      (or open PowerShell and run:  .\asyncti4-proxy.ps1)
#   2. You'll see "Proxy is running" — leave that window open.
#   3. Start Tabletop Simulator and load your game normally.
#   4. The loader will now get live data every time you click a button.
#   5. When you're done playing, close the PowerShell window.
# -------------------------------------------------------------------

$PORT     = 7331
$API_BASE = 'https://bot.asyncti4.com/api/public'

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$PORT/")
$listener.Start()

Write-Host ""
Write-Host "  AsyncTI4 proxy is running on http://localhost:$PORT/" -ForegroundColor Green
Write-Host "  Forwarding requests to $API_BASE" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Leave this window open while you play." -ForegroundColor Yellow
Write-Host "  Close it (or press Ctrl+C) when you're done." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Waiting for TTS requests..." -ForegroundColor Gray
Write-Host ""

try {
    while ($listener.IsListening) {
        # Wait for TTS to make a request (blocks here until one arrives)
        $ctx  = $listener.GetContext()
        $req  = $ctx.Request
        $resp = $ctx.Response

        $path   = $req.Url.PathAndQuery   # e.g. /game/pbd24975/web-data
        $target = "$API_BASE$path"

        Write-Host "  $(Get-Date -Format 'HH:mm:ss')  $path" -ForegroundColor Gray -NoNewline

        try {
            $apiResp = Invoke-WebRequest -Uri $target -UseBasicParsing -TimeoutSec 15
            $bytes   = [System.Text.Encoding]::UTF8.GetBytes($apiResp.Content)

            $resp.StatusCode      = 200
            $resp.ContentType     = 'application/json; charset=utf-8'
            $resp.ContentLength64 = $bytes.Length
            $resp.OutputStream.Write($bytes, 0, $bytes.Length)

            Write-Host "  OK ($($bytes.Length) bytes)" -ForegroundColor Green
        }
        catch {
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes($_.ToString())
            $resp.StatusCode      = 502
            $resp.ContentLength64 = $errBytes.Length
            $resp.OutputStream.Write($errBytes, 0, $errBytes.Length)

            Write-Host "  ERROR: $_" -ForegroundColor Red
        }

        $resp.OutputStream.Close()
    }
}
finally {
    $listener.Stop()
    Write-Host ""
    Write-Host "  Proxy stopped." -ForegroundColor Yellow
}
