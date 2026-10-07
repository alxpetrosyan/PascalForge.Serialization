# Zero warnings and zero hints in PascalForge code, on both platforms.
#
#   powershell -File scripts\check-compiler-warnings.ps1
#
# Reads the compiler output the other scripts keep - it builds nothing - so
# run it after a build: build.ps1 (library units with every warning family
# on, demos, benchmarks), test.ps1, run-type-coverage.ps1, run-demos.ps1,
# check-format-isolation.ps1, check-dependencies.ps1 and check-packages.ps1.
# validate-release.ps1 runs it last.
#
# OWNERSHIP IS EXPLICIT. A diagnostic is PascalForge's when the file it names
# is a path inside this repository, or a bare name that matches a source file
# in src, tests, demo, benchmarks or projects, or a probe generated under
# artifacts. Anything else - an RTL, VCL, FireDAC or other vendor unit - is
# reported as VENDOR and does not fail the gate.
#
# A platform with no build log at all is FAIL: no evidence is not zero.

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Artifacts = Join-Path $Repo 'artifacts'

# Every PascalForge-owned Pascal source, by file name.
$owned = @{}
foreach ($dir in 'src', 'tests', 'demo', 'benchmarks', 'projects', 'artifacts\isolation', 'artifacts\dependencies') {
  $root = Join-Path $Repo $dir
  if (-not (Test-Path -LiteralPath $root)) { continue }
  Get-ChildItem -LiteralPath $root -Recurse -File -Include *.pas, *.dpr, *.dpk |
    ForEach-Object { $owned[$_.Name.ToLowerInvariant()] = $true }
}

function Test-Owned([string]$File) {
  $f = $File.Trim()
  if ([System.IO.Path]::IsPathRooted($f)) {
    return $f.StartsWith($Repo, [System.StringComparison]::OrdinalIgnoreCase)
  }
  return $owned.ContainsKey([System.IO.Path]::GetFileName($f).ToLowerInvariant())
}

function Get-Platform([string]$Path) {
  if ($Path -match '[\\.]Win64[\\.]') { return 'Win64' }
  if ($Path -match '[\\.]Win32[\\.]') { return 'Win32' }
  return ''
}

# dcc:     Unit.pas(12) Warning: W1024 Combining signed and unsigned types
# MSBuild: D:\...\Unit.pas(12): warning W1024: Combining ... [project]
#          D:\...\Unit.pas(12): Hint warning H2077: Value assigned ... [project]
$dccPattern = '^\s*(?<file>.+?)\((?<line>\d+)\)\s+(?<kind>Warning|Hint):\s+(?<code>[WH]\d{4})\s+(?<msg>.*)$'
$msbPattern = '^\s*(?<file>.+?)\((?<line>\d+)(,\d+)?\):\s+(?<kind>Hint warning|warning|hint)\s+(?<code>[WH]\d{4}):\s*(?<msg>.*?)(\s+\[[^\]]*\])?$'

$logs = @()
foreach ($dir in 'dcu\library', 'test-logs', 'demo-logs', 'demo', 'benchmarks', 'type-coverage',
                 'isolation', 'dependencies', 'package-logs') {
  $root = Join-Path $Artifacts $dir
  if (-not (Test-Path -LiteralPath $root)) { continue }
  $logs += @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.log)
}

$found = @{}
$evidence = @{ 'Win32' = 0; 'Win64' = 0 }
$vendor = @{ 'Win32' = 0; 'Win64' = 0 }
foreach ($log in $logs) {
  $platform = Get-Platform $log.FullName
  if ($platform -eq '') { continue }
  $evidence[$platform]++
  foreach ($line in Get-Content -LiteralPath $log.FullName) {
    $m = [regex]::Match($line, $dccPattern)
    if (-not $m.Success) { $m = [regex]::Match($line, $msbPattern) }
    if (-not $m.Success) { continue }
    $file = $m.Groups['file'].Value.Trim()
    $code = $m.Groups['code'].Value
    if (-not (Test-Owned $file)) { $vendor[$platform]++; continue }
    $key = '{0}|{1}({2})|{3}' -f $platform, [System.IO.Path]::GetFileName($file), $m.Groups['line'].Value, $code
    if (-not $found.ContainsKey($key)) {
      $found[$key] = [pscustomobject]@{
        Platform = $platform; Code = $code
        Where = '{0}({1})' -f $file, $m.Groups['line'].Value
        Message = $m.Groups['msg'].Value.Trim(); Log = $log.Name
      }
    }
  }
}

$ok = $true
foreach ($p in 'Win32', 'Win64') {
  $items = @($found.Values | Where-Object Platform -eq $p)
  $warnings = @($items | Where-Object { $_.Code.StartsWith('W') }).Count
  $hints = @($items | Where-Object { $_.Code.StartsWith('H') }).Count
  foreach ($i in ($items | Sort-Object Where)) {
    Write-Host ("  [{0}] {1} {2} {3}   ({4})" -f $p, $i.Where, $i.Code, $i.Message, $i.Log)
  }
  Write-Host "COMPILER_LOGS_$($p.ToUpper())=$($evidence[$p])"
  Write-Host "COMPILER_VENDOR_DIAGNOSTICS_$($p.ToUpper())=$($vendor[$p])"
  Write-Host "COMPILER_WARNINGS_PASCALFORGE_$($p.ToUpper()): $warnings"
  Write-Host "COMPILER_HINTS_PASCALFORGE_$($p.ToUpper()): $hints"
  if ($evidence[$p] -eq 0) { Write-Host "  !! no build log for $p - nothing was measured"; $ok = $false }
  if (($warnings + $hints) -gt 0) { $ok = $false }
}

Write-Host ''
if ($ok) { Write-Host 'ZERO_WARNING_BUILD: PASS'; exit 0 }
Write-Host 'ZERO_WARNING_BUILD: FAIL'
exit 1
