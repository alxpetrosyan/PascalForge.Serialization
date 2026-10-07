# Build every design/runtime package, on both platforms, from the command line.
#
#   powershell -File scripts\check-packages.ps1
#   powershell -File scripts\check-packages.ps1 -Platform Win32
#
# A library that ships as packages has a second way to be broken that the unit
# build does not catch: a .dpk whose Contains list has drifted from src\, a
# Requires that pulls in a framework the package has no business needing, or a
# project configured to emit an .exe. None of those show up when the units are
# compiled directly, and all of them show up the first time somebody installs
# the package in the IDE.
#
# So each package is built with MSBuild, exactly as the IDE would, and then
# what it produced is checked: a .bpl and a .dcp, and NOT an .exe.
#
# There are two packages: PascalForge.Serialization.Runtime (the core and
# every format) and PascalForge.Serialization.DataSet (the DataSet
# projection, which adds Data.DB, FireDAC and DataSnap). Then, against the
# packages just built:
#   PACKAGE_ISOLATION   the Runtime package requires the RTL only - no
#                       database, VCL or DataSnap package - and its build
#                       implicitly imports no unit from another package;
#                       the DataSet package requires Runtime and only the
#                       database packages.
#   PACKAGE_PROBE       tests\PackageProbe, built WITH runtime packages, shows
#                       that loading Runtime registers no format, that JSON
#                       alone and RegisterAll register what they say, that
#                       loading and unloading the DataSet package with
#                       LoadPackage registers nothing, and that the process
#                       exits cleanly with every format still registered.

param(
  [ValidateSet('Win32', 'Win64', 'Both')] [string]$Platform = 'Both',
  [ValidateSet('Debug', 'Release')] [string]$Config = 'Release'
)
$ErrorActionPreference = 'Continue'
$Repo = Split-Path -Parent $PSScriptRoot
$Projects = Join-Path $Repo 'projects'
$OutDir = Join-Path $Repo 'artifacts\package-logs'
$RsVars = 'C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat'

if (-not (Test-Path -LiteralPath $RsVars)) {
  Write-Host "rsvars.bat not found at $RsVars"
  Write-Host 'PACKAGE_BUILD: FAIL'
  exit 1
}

$platforms = if ($Platform -eq 'Both') { @('Win32', 'Win64') } else { @($Platform) }
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
# Start from empty package output, so a .bpl left by an earlier layout can
# never be what the probe loads.
foreach ($p in $platforms) {
  foreach ($dir in @("artifacts\packages\$p\$Config", "artifacts\dcu\packages\$p\$Config")) {
    $full = Join-Path $Repo $dir
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
  }
}

# Dependency order: Runtime, then DataSet, which requires it.
function Get-BuildRank([string]$Name) {
  switch -Regex ($Name) {
    '\.Runtime$'                             { return 0 }
    default                                   { return 1 }
  }
}
$packages = @(Get-ChildItem -LiteralPath $Projects -Filter *.dproj -File |
  Sort-Object @{ Expression = { Get-BuildRank $_.BaseName } }, Name)
if ($packages.Count -eq 0) {
  Write-Host "No .dproj found under $Projects"
  Write-Host 'PACKAGE_BUILD: FAIL'
  exit 1
}

$rows = [System.Collections.Generic.List[object]]::new()

foreach ($p in $platforms) {
  foreach ($proj in $packages) {
    $log = Join-Path $OutDir "$($proj.BaseName).$p.log"
    $cmd = Join-Path $env:TEMP "pf_pkg_$($proj.BaseName)_$p.cmd"
    # rsvars sets the whole Delphi MSBuild environment; calling MSBuild
    # without it finds the wrong toolchain or none at all.
    @"
@echo off
call "$RsVars" >nul
msbuild "$($proj.FullName)" /t:Build /p:Config=$Config /p:Platform=$p /v:minimal
exit /b %ERRORLEVEL%
"@ | Set-Content -LiteralPath $cmd -Encoding ascii

    $out = & cmd.exe /d /s /c $cmd 2>&1
    $code = $LASTEXITCODE
    $out | Set-Content -LiteralPath $log -Encoding utf8

    # What did it actually produce? A package project that emits an .exe is
    # misconfigured even when the build succeeds.
    $emitted = @()
    foreach ($ext in @('bpl', 'dcp', 'exe')) {
      $hit = Get-ChildItem -LiteralPath $Repo -Recurse -Filter "$($proj.BaseName).$ext" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Item -LiteralPath $cmd).LastWriteTime.AddMinutes(-5) }
      if ($hit) { $emitted += $ext }
    }

    $rows.Add([pscustomobject]@{
      package  = $proj.BaseName
      platform = $p
      built    = ($code -eq 0)
      emitsExe = ($emitted -contains 'exe')
      emitted  = ($emitted -join ',')
      log      = $log
    })
  }
}

$rows | Format-Table package, platform, built, emitted -AutoSize | Out-String -Width 160 |
  ForEach-Object { Write-Host $_ }

$failed = @($rows | Where-Object { -not $_.built }).Count
$exes   = @($rows | Where-Object { $_.emitsExe }).Count

# What each package requires, and nothing more.
function Get-Requires([string]$Name) {
  $text = Get-Content -LiteralPath (Join-Path $Projects "$Name.dpk") -Raw
  $req = if ($text -match '(?s)\brequires\b(.*?);') { $Matches[1] } else { '' }
  $req = [regex]::Replace($req, '(?s)\{.*?\}', '')
  return @($req -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$isolation = $true
$runtimeReq = Get-Requires 'PascalForge.Serialization.Runtime'
if (($runtimeReq -join ',') -ne 'rtl') {
  Write-Host "  !! Runtime requires $($runtimeReq -join ', '); it must require rtl only"
  $isolation = $false
}
$dataSetAllowed = @('rtl', 'dbrtl', 'dsnap', 'FireDAC', 'FireDACCommonDriver', 'PascalForge.Serialization.Runtime')
$dataSetReq = Get-Requires 'PascalForge.Serialization.DataSet'
foreach ($r in $dataSetReq) {
  if ($dataSetAllowed -notcontains $r) {
    Write-Host "  !! DataSet requires $r"
    $isolation = $false
  }
}
if ($dataSetReq -notcontains 'PascalForge.Serialization.Runtime') {
  Write-Host '  !! DataSet does not require Runtime'
  $isolation = $false
}
# A package built with IMPLICITBUILD silently absorbs a unit it does not
# list; for Runtime that would be how Data.DB or a VCL unit gets in.
foreach ($r in ($rows | Where-Object { $_.built })) {
  $logText = Get-Content -LiteralPath $r.log -Raw
  if ($logText -match 'implicitly imported|W1033') {
    Write-Host "  !! $($r.package) $($r.platform) implicitly imports a unit - see $($r.log)"
    $isolation = $false
  }
}

# No package shares its name with a unit it contains. On Win64 an application
# that links such a package and uses that unit dies at startup with runtime
# error 217; Win32 does not show it, so only this check catches it early.
$clashes = @()
foreach ($dpk in Get-ChildItem -LiteralPath $Projects -Filter *.dpk -File) {
  $text = Get-Content -LiteralPath $dpk.FullName -Raw
  if ($text -match ('(?m)^\s*' + [regex]::Escape($dpk.BaseName) + '\s+in\s')) { $clashes += $dpk.BaseName }
}
$nameClash = ($clashes.Count -eq 0)

# The probe, per platform, against the packages just built.
$probeOk = $true
if ($failed -eq 0) {
  foreach ($p in $platforms) {
    $pkgDir = Join-Path $Repo "artifacts\packages\$p\$Config"
    $probeOut = Join-Path $Repo "artifacts\package-probe\$p"
    $probeDcu = Join-Path $Repo "artifacts\dcu\package-probe\$p"
    New-Item -ItemType Directory -Force -Path $probeOut, $probeDcu | Out-Null
    $compiler = if ($p -eq 'Win64') { 'dcc64' } else { 'dcc32' }
    $bin = if ($p -eq 'Win64') { 'bin64' } else { 'bin' }
    $cmd = Join-Path $env:TEMP "pf_pkg_probe_$p.cmd"
    @"
@echo off
call "$RsVars" >nul
cd /d "$(Join-Path $Repo 'tests\PackageProbe')"
$compiler -B -NSSystem;System.Win;Winapi -LUrtl;PascalForge.Serialization.Runtime -U"$pkgDir" -NU"$probeDcu" -E"$probeOut" PackageProbe.dpr || exit /b 1
set PATH=$pkgDir;%BDS%\$bin;%PATH%
"$probeOut\PackageProbe.exe"
exit /b %ERRORLEVEL%
"@ | Set-Content -LiteralPath $cmd -Encoding ascii
    $out = & cmd.exe /d /s /c $cmd 2>&1
    $code = $LASTEXITCODE
    $out | Set-Content -LiteralPath (Join-Path $OutDir "PackageProbe.$p.log") -Encoding utf8
    $out | Where-Object { $_ -match ': (PASS|FAIL)$|UNEXPECTED|Error' } | ForEach-Object { Write-Host "  [$p] $_" }
    if ($code -ne 0 -or -not ($out -match 'PACKAGE_PROBE: PASS')) { $probeOk = $false }
  }
} else { $probeOk = $false }

Write-Host ''
Write-Host "PACKAGE_PROJECTS=$($packages.Count)"
Write-Host "PACKAGE_BUILDS=$($rows.Count)"
Write-Host "PACKAGE_BUILD_FAILED=$failed"
Write-Host "PACKAGE_EMITS_EXE=$exes"
foreach ($r in ($rows | Where-Object { -not $_.built })) {
  Write-Host "  !! $($r.package) $($r.platform) - see $($r.log)"
}
Write-Host ''
foreach ($c in $clashes) { Write-Host "  !! package $c contains a unit of the same name" }
Write-Host ('PACKAGE_NAME_UNIT_CLASH: ' + $(if ($nameClash) { 'PASS' } else { 'FAIL' }))
Write-Host ('PACKAGE_ISOLATION: ' + $(if ($isolation) { 'PASS' } else { 'FAIL' }))
Write-Host ('PACKAGE_PROBE: ' + $(if ($probeOk) { 'PASS' } else { 'FAIL' }))
if ($failed -eq 0 -and $exes -eq 0 -and $isolation -and $nameClash -and $probeOk) { Write-Host 'PACKAGE_BUILD: PASS'; exit 0 }
Write-Host 'PACKAGE_BUILD: FAIL'
exit 1
