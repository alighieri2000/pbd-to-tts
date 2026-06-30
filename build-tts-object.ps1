#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the TTS saved object JSON from asyncti4_loader_offline.lua.
.DESCRIPTION
    Embeds the Lua script into a minimal TTS saved object and writes it to the
    TTS Saved Objects folder so you can drag it straight onto the table.
.EXAMPLE
    .\build-tts-object.ps1
    .\build-tts-object.ps1 -GameName pbd99999
#>
param(
    [string]$GameName  = 'pbd24975',
    [string]$LuaSource = "$PSScriptRoot\ti4bridge\asyncti4_loader_offline.lua",
    [string]$OutDir    = "$env:USERPROFILE\Documents\My Games\Tabletop Simulator\Saves\Saved Objects"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Read source ──────────────────────────────────────────────────────────────
if (-not (Test-Path $LuaSource)) { throw "Lua source not found: $LuaSource" }
$lua = [System.IO.File]::ReadAllText($LuaSource, [System.Text.Encoding]::UTF8)

# ── JSON-encode the Lua string ────────────────────────────────────────────────
# ConvertTo-Json handles all escaping correctly (quotes, backslashes, newlines, unicode).
$escapedLua = ($lua | ConvertTo-Json -Compress)
$escapedLua = $escapedLua.Substring(1, $escapedLua.Length - 2)   # strip outer quotes

# ── TTS saved-object skeleton ────────────────────────────────────────────────
# Minimal valid structure — TTS copies LuaScript to both the top-level and the object.
$objectGuid = 'a51t14'   # stable GUID so the object doesn't change identity on rebuild
$outName    = "AsyncTI4 Loader ($GameName)"

$json = @"
{
  "SaveName": "$outName",
  "GameMode": "",
  "Gravity": 0.5,
  "PlayArea": 0.5,
  "Date": "",
  "Table": "",
  "Sky": "",
  "Note": "",
  "Rules": "",
  "XmlUI": "",
  "LuaScript": "$escapedLua",
  "LuaScriptState": "",
  "ObjectStates": [
    {
      "GUID": "$objectGuid",
      "Name": "BlockSquare",
      "Transform": {
        "posX": 0.0, "posY": 1.0, "posZ": 0.0,
        "rotX": 0.0, "rotY": 0.0, "rotZ": 0.0,
        "scaleX": 3.5, "scaleY": 0.1, "scaleZ": 3.5
      },
      "Nickname": "AsyncTI4 Loader",
      "Description": "Loads AsyncTI4 game state into TF mod. Right-click -> Description for diag output.",
      "GMNotes": "",
      "ColorDiffuse": { "r": 0.05, "g": 0.1, "b": 0.2 },
      "Locked": false,
      "Grid": false,
      "Snap": false,
      "Autoraise": true,
      "Sticky": true,
      "Tooltip": true,
      "GridProjection": false,
      "HideWhenFaceDown": false,
      "Hands": false,
      "LuaScript": "$escapedLua",
      "LuaScriptState": "",
      "XmlUI": ""
    }
  ],
  "TabStates": {},
  "VersionNumber": ""
}
"@

# ── Validate ─────────────────────────────────────────────────────────────────
Add-Type -AssemblyName System.Web.Extensions
$js = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
$js.MaxJsonLength = 200MB
try   { $null = $js.DeserializeObject($json) }
catch { throw "Generated JSON is invalid: $_" }

# ── Write ─────────────────────────────────────────────────────────────────────
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$outPath = Join-Path $OutDir "$outName.json"
[System.IO.File]::WriteAllText($outPath, $json, [System.Text.Encoding]::UTF8)

$kb = [Math]::Round((Get-Item $outPath).Length / 1024)
Write-Host "Built: $outPath ($kb KB)" -ForegroundColor Green
Write-Host "Drag '$outName' from TTS Saved Objects onto the table." -ForegroundColor Cyan
