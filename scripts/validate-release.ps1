# The public release gate: every check, both platforms, one verdict.
#
#   powershell -File scripts\validate-release.ps1
#   powershell -File scripts\validate-release.ps1 -SkipBuild     # reuse the last build
#
# check-all.ps1 is the working check. This is the release one: it runs
# everything check-all runs, adds the documentation, dependency, package and
# type-coverage gates, and then states the release markers - each one
# derived from what the runs WROTE, never from a list typed in here. A
# marker whose evidence is missing is FAIL, not absent.
#
# Everything it runs is in this repository.

param(
  [switch]$SkipBuild
)
$ErrorActionPreference = 'Continue'
$Here = $PSScriptRoot
$Repo = Split-Path -Parent $Here
$Logs = Join-Path $Repo 'artifacts\release'
if (Test-Path -LiteralPath $Logs) { Remove-Item -LiteralPath $Logs -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Logs | Out-Null

$steps = [System.Collections.Generic.List[object]]::new()

function Step([string]$Key, [string]$Title, [scriptblock]$Body) {
  Write-Host ''
  Write-Host "########## $Title"
  $log = Join-Path $Logs "$Key.log"
  $out = & $Body 2>&1
  $ok = $LASTEXITCODE -eq 0
  $out | Out-File -LiteralPath $log -Encoding utf8
  $out | Select-Object -Last 6 | ForEach-Object { Write-Host "  $_" }
  $steps.Add([pscustomobject]@{ key = $Key; title = $Title; ok = $ok; log = $log })
}

function StepOk([string]$Key) {
  $s = @($steps | Where-Object key -eq $Key)
  return ($s.Count -eq 1) -and $s[0].ok
}

function Invoke-Gate([string]$Script, [string[]]$Arguments = @()) {
  & powershell -NoProfile -File (Join-Path $Here $Script) @Arguments
}

# ------------------------------------------------------------------ static --
Step 'banned'     'banned markers'       { Invoke-Gate 'check-banned-markers.ps1' }
Step 'layout'     'repository layout'    { Invoke-Gate 'check-repository-layout.ps1' }
Step 'docs'       'documentation'        { Invoke-Gate 'check-docs.ps1' }

# ------------------------------------------------------------------- build --
if (-not $SkipBuild) {
  Step 'build' 'build (library, demos, benchmarks, both platforms)' {
    Invoke-Gate 'build.ps1' @('-What', 'all')
  }
}
Step 'isolation'    'format isolation'     { Invoke-Gate 'check-format-isolation.ps1' }
Step 'dependencies' 'dependency audit'     { Invoke-Gate 'check-dependencies.ps1' }
Step 'packages'     'package build'        { Invoke-Gate 'check-packages.ps1' }

# ------------------------------------------------------------- per platform --
foreach ($p in 'Win32', 'Win64') {
  Step "tests-$p"    "public tests ($p)"   { Invoke-Gate 'test.ps1' @('-Platform', $p) }
  Step "coverage-$p" "type coverage ($p)"  { Invoke-Gate 'run-type-coverage.ps1' @('-Platform', $p) }
  Step "demos-$p"    "demos ($p)"          { Invoke-Gate 'run-demos.ps1' @('-Platform', $p) }
}

# ---------------------------------------------------------- after building --
# Last, so they judge what the runs above left: every compiler log they
# wrote, and a tree that has just been built from.
Step 'warnings' 'zero-warning build'      { Invoke-Gate 'check-compiler-warnings.ps1' }
Step 'audit'    'source audit'            { Invoke-Gate 'check-source-audit.ps1' }

# ----------------------------------------------------------------- markers --
# A project is PASS on a platform when test.ps1 recorded it so: the per-test
# output file exists, holds the project's own marker, and the run's summary
# lists no failure for it.
function ProjectPass([string]$Platform, [string]$Dir, [string]$Marker) {
  $out = Join-Path $Repo "artifacts\test-logs\$Platform\$Dir.out.txt"
  if (-not (Test-Path -LiteralPath $out)) { return $false }
  $text = Get-Content -LiteralPath $out -Raw
  if (-not $text.Contains($Marker)) { return $false }
  if ($text.Contains('An unexpected memory leak has occurred')) { return $false }
  return StepOk "tests-$Platform"
}

$projectMarkers = [ordered]@{
  'CORE_FOUNDATION'              = @(,@('CoreFoundation', 'CORE_FOUNDATION: PASS'))
  'JSON'                         = @(,@('JsonCore', 'JSON_CORE: PASS'))
  'XML'                          = @(@('XmlCore', 'XML_CORE: PASS'), @('XmlNative', 'XML_NATIVE: PASS'))
  'BSON'                         = @(@('BsonCore', 'BSON_CORE: PASS'), @('BsonNative', 'BSON_NATIVE: PASS'),
                                     @('BsonJson', 'BSON_JSON: PASS'))
  'PROTOBUF'                     = @(@('ProtobufNative', 'PROTOBUF_NATIVE: PASS'),
                                     @('ProtobufSchema', 'PROTOBUF_SCHEMA: PASS'),
                                     @('ProtobufReference', 'PROTOBUF_REFERENCE: PASS'))
  'CBOR'                         = @(,@('CborNative', 'CBOR_NATIVE: PASS'))
  'MESSAGEPACK'                  = @(,@('MessagePackNative', 'MESSAGEPACK_NATIVE: PASS'))
  'YAML'                         = @(,@('YamlNative', 'YAML_NATIVE: PASS'))
  'CSV'                          = @(,@('CsvNative', 'CSV_NATIVE: PASS'))
  'AVRO'                         = @(,@('AvroNative', 'AVRO_NATIVE: PASS'))
  'ASN1_BER'                     = @(,@('Asn1Native', 'ASN1_BER_COMPLETE: PASS'))
  'ASN1_DER'                     = @(,@('Asn1Native', 'ASN1_DER_CANONICAL: PASS'))
  'ASN1_CER'                     = @(,@('Asn1Native', 'ASN1_CER_SEPARATE: PASS'))
  'CONTRACT_CONVERSION_MATRIX'   = @(@('ContractMatrix', 'CONTRACT_MATRIX: PASS'),
                                     @('ReaderContracts', 'READER_CONTRACTS: PASS'))
  'STRUCTURAL_CONVERSION_MATRIX' = @(@('ConversionMatrix', 'CONVERSION_MATRIX: PASS'),
                                     @('Conversion', 'CONVERSION: PASS'),
                                     @('StructuralFidelity', 'STRUCTURAL_FIDELITY: PASS'),
                                     @('FormatChain', 'FORMAT_CHAIN: PASS'),
                                     @('LosslessRouting', 'LOSSLESS_ROUTING: PASS'))
  'DATASET_FORMAT_MATRIX'        = @(@('DataSetFormats', 'DATASET_FORMATS: PASS'),
                                     @('DataSetParity', 'DATASET_PARITY: PASS'),
                                     @('DataSetJson', 'DATASET_JSON: PASS'),
                                     @('DataSetSources', 'DATASET_SOURCES: PASS'))
  'UNICODE_UTF8'                 = @(,@('UnicodeUtf8', 'UNICODE_UTF8: PASS'))
  'OWNERSHIP'                    = @(,@('ReaderContracts', 'OWNERSHIP: PASS'))
  'CACHE'                        = @(,@('Robustness', 'CACHE: PASS'))
  'THREADING'                    = @(,@('Robustness', 'THREADING: PASS'))
  'MALFORMED_INPUT'              = @(,@('Robustness', 'MALFORMED_INPUT: PASS'))
  'SECURITY_LIMITS'              = @(,@('Robustness', 'SECURITY_LIMITS: PASS'))
}

$markers = [ordered]@{}
foreach ($name in $projectMarkers.Keys) {
  $ok = $true
  foreach ($p in 'Win32', 'Win64') {
    foreach ($pair in $projectMarkers[$name]) {
      if (-not (ProjectPass $p $pair[0] $pair[1])) { $ok = $false }
    }
  }
  $markers[$name] = $ok
}
$markers['DELPHI_TYPE_COVERAGE'] = (StepOk 'coverage-Win32') -and (StepOk 'coverage-Win64')
$markers['SOURCE_ISOLATION'] = (StepOk 'isolation') -and (StepOk 'dependencies')
$markers['BANNED_MARKERS']   = StepOk 'banned'
$markers['REPOSITORY_LAYOUT'] = StepOk 'layout'
$markers['DOCS_CONSISTENCY'] = StepOk 'docs'
$markers['DEMO_BUILD']       = (StepOk 'demos-Win32') -and (StepOk 'demos-Win64')
$markers['PACKAGE_BUILD']    = (StepOk 'packages') -and ($SkipBuild -or (StepOk 'build'))
$markers['ZERO_WARNING_BUILD'] = StepOk 'warnings'
$markers['SOURCE_AUDIT']     = StepOk 'audit'
foreach ($p in 'Win32', 'Win64') {
  $markers[$p.ToUpper()] = (StepOk "tests-$p") -and (StepOk "coverage-$p") -and
    (StepOk "demos-$p")
}

Write-Host ''
Write-Host '########## steps'
$steps | ForEach-Object { '{0,-52} {1}' -f $_.title, $(if ($_.ok) { 'PASS' } else { 'FAIL' }) }

Write-Host ''
Write-Host '########## release markers'
$lines = foreach ($name in $markers.Keys) {
  '{0}: {1}' -f $name, $(if ($markers[$name]) { 'PASS' } else { 'FAIL' })
}
$lines | ForEach-Object { Write-Host $_ }

$failedSteps = @($steps | Where-Object { -not $_.ok }).Count
$failedMarkers = @($markers.Values | Where-Object { -not $_ }).Count
$verdict = if (($failedSteps -eq 0) -and ($failedMarkers -eq 0)) { 'PASS' } else { 'FAIL' }
$summary = @($lines) + @(
  ''
  "RELEASE_STEPS=$($steps.Count)"
  "RELEASE_STEPS_FAILED=$failedSteps"
  "RELEASE_MARKERS_FAILED=$failedMarkers"
  "PUBLIC_RELEASE_GATE: $verdict"
)
[System.IO.File]::WriteAllLines((Join-Path $Logs 'SUMMARY.txt'), $summary,
  [System.Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host "RELEASE_STEPS=$($steps.Count)"
Write-Host "RELEASE_STEPS_FAILED=$failedSteps"
Write-Host "RELEASE_MARKERS_FAILED=$failedMarkers"
Write-Host "PUBLIC_RELEASE_GATE: $verdict"
if ($verdict -eq 'PASS') { exit 0 }
exit 1
