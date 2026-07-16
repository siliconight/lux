# ============================================================
#  headless_walk.ps1  (v4 - runner homed in lux repo: lux\tools\)
#  Fix vs v1: Godot's win64 exe is GUI-subsystem - PowerShell
#  neither waits for it nor captures stdout. v2 prefers the
#  *_console.exe if present and always runs Godot via
#  Start-Process with redirected streams + hard wait + timeout.
#
#  Requires: walk_harness.gd next to this script.
#  Run:
#  powershell -ExecutionPolicy Bypass -File C:\Projects\gabagool_studios\gabagool_factory\lux\tools\headless_walk.ps1
# ============================================================

$ErrorActionPreference = "Continue"
$LuxProj  = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Factory  = (Resolve-Path (Join-Path $LuxProj "..")).Path
$GodotGui = "C:\Godot\4.7\Godot_v4.7-stable_win64.exe"
$GodotCon = "C:\Godot\4.7\Godot_v4.7-stable_win64_console.exe"
$Stamp    = Get-Date -Format "yyyyMMdd_HHmmss"
$Res      = Join-Path $Factory ("headless_" + $Stamp)
New-Item -ItemType Directory -Path $Res -Force | Out-Null
$Log      = Join-Path $Res "headless.log"

function W([string]$m) { Write-Host $m; Add-Content -Path $Log -Value $m }
function Section([string]$n) { W ""; W ("=" * 62); W ("== " + $n); W ("=" * 62) }

function Run-Godot([string]$label, [string[]]$gargs, [string]$outfile, [int]$timeoutSec) {
    $so = Join-Path $Res ($label + "_out.tmp")
    $se = Join-Path $Res ($label + "_err.tmp")
    W ("  launch: " + $script:Godot + " " + ($gargs -join " "))
    $p = Start-Process -FilePath $script:Godot -ArgumentList $gargs -NoNewWindow -PassThru -RedirectStandardOutput $so -RedirectStandardError $se
    $null = $p.Handle   # cache handle so ExitCode is readable (PS 5.1 quirk)
    if (-not $p.WaitForExit($timeoutSec * 1000)) {
        W ("  TIMEOUT after " + $timeoutSec + "s - killing process")
        try { $p.Kill() } catch { }
        Start-Sleep -Seconds 2
    }
    $script:GodotExit = $p.ExitCode
    $txt = @()
    if (Test-Path $so) { $txt += @(Get-Content $so) }
    if (Test-Path $se) { $txt += @(Get-Content $se) }
    $txt | Out-File $outfile -Encoding utf8
    Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
    W ("  exit=" + $script:GodotExit + "  lines=" + $txt.Count + "  (full output: " + (Split-Path $outfile -Leaf) + ")")
    return ,$txt
}

Section "0. PRE-FLIGHT"
$Godot = $GodotGui
if (Test-Path $GodotCon) { $Godot = $GodotCon; W ("godot   : " + $GodotCon + "  (console build - good)") }
elseif (Test-Path $GodotGui) { W ("godot   : " + $GodotGui + "  (GUI build - using Start-Process capture)") }
else { W ("FATAL: no Godot at " + $GodotGui); exit 1 }
if (-not (Test-Path (Join-Path $LuxProj "project.godot"))) { W ("FATAL: no project.godot at " + $LuxProj); exit 1 }
$Harness = Join-Path $LuxProj "tools\walk_harness.gd"
if (-not (Test-Path $Harness)) { W "FATAL: tools\walk_harness.gd missing from this lux repo"; exit 1 }
W ("harness : " + $Harness)
$running = @(Get-Process | Where-Object { $_.Name -like "Godot*" })
if ($running.Count -gt 0) { W ("WARNING: " + $running.Count + " Godot process(es) already running - a stuck previous run can hold file locks. Close them if this run misbehaves.") }
W ("project : " + $LuxProj)

Section "1. LOCATE INPUTS"
$manifest = Get-ChildItem -Path (Join-Path $Factory "deli_counter\build") -Filter "*.lights.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $manifest) { W "FATAL: no *.lights.json under deli_counter\build"; exit 1 }
$stem = $manifest.Name -replace "\.lights\.json$",""
W ("manifest : " + $manifest.FullName + "  (stem=" + $stem + ")")

$fixglb = Get-ChildItem -Path $Factory -Recurse -Filter ($stem + "_fixtures.glb") -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch "\\lux\\walk\\headless\\" } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $fixglb) { W ("FATAL: no " + $stem + "_fixtures.glb found - run the zoo fixture build first"); exit 1 }
W ("fixtures : " + $fixglb.FullName)

$shell = Get-ChildItem -Path $manifest.DirectoryName -Recurse -Filter "*.glb" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch "_fixtures" -and $_.Name -match [regex]::Escape($stem) } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($shell) { W ("shell    : " + $shell.FullName) } else { W ("shell    : NONE matching '" + $stem + "*.glb' - harness runs fixtures-only") }

Section "2. STAGE INTO LUX PROJECT (lux\walk\headless - untracked, delete when done)"
$Stage = Join-Path $LuxProj "walk\headless"
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Path $Stage -Force | Out-Null
Copy-Item $manifest.FullName -Destination $Stage
Copy-Item $fixglb.FullName   -Destination $Stage
if ($shell) { Copy-Item $shell.FullName -Destination $Stage }
Get-ChildItem $Stage | ForEach-Object { W ("  staged " + $_.Name) }

Section "3. GODOT IMPORT PASS (headless, timeout 15 min)"
$impOut = Run-Godot "import" @("--headless","--path",$LuxProj,"--import") (Join-Path $Res "import.log") 900
$impOut | Select-Object -Last 20 | ForEach-Object { W ("  " + $_) }

Section "4. RUN HARNESS (timeout 5 min)"
$hwOut = Run-Godot "harness" @("--headless","--path",$LuxProj,"--script","res://tools/walk_harness.gd") (Join-Path $Res "harness.log") 300
$hwOut | Where-Object { $_ -match "\[HW" -or $_ -match "ERROR" } | ForEach-Object { W ("  " + $_) }

Section "5. COLLECT + PACKAGE"
foreach ($f in @("headless_report.json","headless_walk.tscn")) {
    $p = Join-Path $Stage $f
    if (Test-Path $p) { Copy-Item $p -Destination $Res; W ("  collected " + $f) } else { W ("  MISSING " + $f) }
}
$Zip = Join-Path $Factory ("headless_" + $Stamp + ".zip")
try {
    Compress-Archive -Path (Join-Path $Res "*") -DestinationPath $Zip -Force
    W ("RESULTS ZIP -> " + $Zip)
} catch {
    W ("Compress-Archive failed - zip manually: " + $Res)
}
W ""
W "Upload the results zip back to Claude."
W "Visual pass afterward: open lux\walk\headless\headless_walk.tscn in the"
W "editor, apply gas_station_fluorescent, judge from a framed camera."
