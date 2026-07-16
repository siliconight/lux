# ============================================================
#  visual_pass.ps1 - screenshot pass for the verified fixture
#  stage. Runs Godot WINDOWED (a window flashes ~15-30s while
#  it shoots), saves 1920x1080 PNGs, zips them to share.
#
#  Requires: visual_pass.gd next to this script, and the staged
#  inputs from the headless run still in lux\walk\headless\
#  (re-stages them if missing).
#  Run:
#  powershell -ExecutionPolicy Bypass -File C:\Projects\gabagool_studios\gabagool_factory\lux\tools\visual_pass.ps1
# ============================================================

$ErrorActionPreference = "Continue"
$LuxProj  = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Factory  = (Resolve-Path (Join-Path $LuxProj "..")).Path
$GodotGui = "C:\Godot\4.7\Godot_v4.7-stable_win64.exe"
$GodotCon = "C:\Godot\4.7\Godot_v4.7-stable_win64_console.exe"
$Stage    = Join-Path $LuxProj "walk\headless"
$Stamp    = Get-Date -Format "yyyyMMdd_HHmmss"
$Runs     = Join-Path $Factory "_runs"
New-Item -ItemType Directory -Path $Runs -Force | Out-Null
$Res      = Join-Path $Runs ("shots_" + $Stamp)
New-Item -ItemType Directory -Path $Res -Force | Out-Null
$Log      = Join-Path $Res "visual_pass.log"

function W([string]$m) { Write-Host $m; Add-Content -Path $Log -Value $m }

$Godot = $GodotGui
if (Test-Path $GodotCon) { $Godot = $GodotCon }
if (-not (Test-Path $Godot)) { W "FATAL: Godot not found"; exit 1 }
$Runner = Join-Path $LuxProj "tools\visual_pass.gd"
if (-not (Test-Path $Runner)) { W ("FATAL: visual_pass.gd not found at " + $Runner); exit 1 }

# Ensure staged inputs exist (headless run normally left them there)
if (-not (Test-Path $Stage)) { New-Item -ItemType Directory -Path $Stage -Force | Out-Null }
if (-not (Get-ChildItem $Stage -Filter "*_fixtures.glb" -ErrorAction SilentlyContinue)) {
    W "Staging inputs (were missing)..."
    $manifest = Get-ChildItem -Path (Join-Path $Factory "deli_counter\build") -Filter "*.lights.json" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $manifest) { W "FATAL: no *.lights.json under deli_counter\build"; exit 1 }
    $stem = $manifest.Name -replace "\.lights\.json$",""
    $fixglb = Get-ChildItem -Path $Factory -Recurse -Filter ($stem + "_fixtures.glb") -File | Where-Object { $_.FullName -notmatch "\\lux\\walk\\headless\\" } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $fixglb) { W "FATAL: no fixtures glb - run the zoo build first"; exit 1 }
    Copy-Item $manifest.FullName -Destination $Stage
    Copy-Item $fixglb.FullName -Destination $Stage
    $shell = Get-ChildItem -Path $manifest.DirectoryName -Recurse -Filter "*.glb" -File | Where-Object { $_.Name -notmatch "_fixtures" -and $_.Name -match [regex]::Escape($stem) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($shell) { Copy-Item $shell.FullName -Destination $Stage }
}
W "Staged. Launching Godot WINDOWED - a window will appear while it shoots."

# Import pass first in case anything new was staged
$so = Join-Path $Res "import_out.tmp"; $se = Join-Path $Res "import_err.tmp"
$p = Start-Process -FilePath $Godot -ArgumentList @("--headless","--path",$LuxProj,"--import") -NoNewWindow -PassThru -RedirectStandardOutput $so -RedirectStandardError $se
$null = $p.Handle
if (-not $p.WaitForExit(900000)) { W "import TIMEOUT - killing"; try { $p.Kill() } catch {} }
W ("import exit=" + $p.ExitCode)

# The visual pass - WINDOWED (no --headless), rendering required
$so2 = Join-Path $Res "vp_out.tmp"; $se2 = Join-Path $Res "vp_err.tmp"
$p2 = Start-Process -FilePath $Godot -ArgumentList @("--path",$LuxProj,"--resolution","1920x1080","--script","res://tools/visual_pass.gd") -PassThru -RedirectStandardOutput $so2 -RedirectStandardError $se2
$null = $p2.Handle
if (-not $p2.WaitForExit(300000)) { W "visual pass TIMEOUT - killing"; try { $p2.Kill() } catch {} }
$vpOut = @()
if (Test-Path $so2) { $vpOut += @(Get-Content $so2) }
if (Test-Path $se2) { $vpOut += @(Get-Content $se2) }
$vpOut | Out-File (Join-Path $Res "runner.log") -Encoding utf8
$vpOut | Where-Object { $_ -match "\[VP\]" -or $_ -match "ERROR" } | ForEach-Object { W ("  " + $_) }
W ("visual pass exit=" + $p2.ExitCode)
Remove-Item $so, $se, $so2, $se2 -Force -ErrorAction SilentlyContinue

# Collect shots
$ShotsDir = Join-Path $Stage "shots"
if (Test-Path $ShotsDir) {
    Get-ChildItem $ShotsDir -Filter "*.png" | ForEach-Object { Copy-Item $_.FullName -Destination $Res; W ("  " + $_.Name + "  " + ("{0:n0}" -f $_.Length) + " bytes") }
} else {
    W "NO SHOTS PRODUCED - see runner.log"
}
$Zip = Join-Path $Runs ("shots_" + $Stamp + ".zip")
try { Compress-Archive -Path (Join-Path $Res "*") -DestinationPath $Zip -Force; W ("SHOTS ZIP -> " + $Zip) } catch { W ("zip failed - folder: " + $Res) }
W ""
W ("Share the PNGs in " + $Res + " (or the zip). Reframe by editing SHOT_LIST in visual_pass.gd and re-running.")
