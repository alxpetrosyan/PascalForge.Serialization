# Build and run every public test, and report one line per project.
#
#   powershell -File scripts\test.ps1
#   powershell -File scripts\test.ps1 -Platform Win64
#   powershell -File scripts\test.ps1 -Only JsonCore
#
# A project counts as passing only if it exits zero AND its output ends with
# its marker. The marker is a second, independent signal: a program that dies
# early exits non-zero, but one that silently skips its checks would not.

param(
  [ValidateSet('Win32', 'Win64')] [string]$Platform = 'Win32',
  [string[]]$Only = @()
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Dcc = Join-Path $PSScriptRoot 'dcc.cmd'
$Compiler = if ($Platform -eq 'Win64') { 'dcc64' } else { 'dcc32' }
$OutDir = Join-Path $Repo "artifacts\test-logs\$Platform"

$Tests = @(
  @{ Dir = 'CoreFoundation'; Marker = 'CORE_FOUNDATION: PASS' }
  @{ Dir = 'JsonCore';      Marker = 'JSON_CORE: PASS' }
  @{ Dir = 'DataSetParity'; Marker = 'DATASET_PARITY: PASS' }
  @{ Dir = 'DataSetJson';   Marker = 'DATASET_JSON: PASS' }
  @{ Dir = 'FormatRegistry'; Marker = 'FORMAT_REGISTRY: PASS' }
  @{ Dir = 'FormatBoundary'; Marker = 'FORMAT_BOUNDARY: PASS' }
  @{ Dir = 'NullableFamilies'; Marker = 'NULLABLE_FAMILIES: PASS' }
  @{ Dir = 'XmlCore';        Marker = 'XML_CORE: PASS' }
  @{ Dir = 'XmlNative';      Marker = 'XML_NATIVE: PASS' }
  @{ Dir = 'BsonCore';       Marker = 'BSON_CORE: PASS' }
  @{ Dir = 'BsonNative';     Marker = 'BSON_NATIVE: PASS' }
  @{ Dir = 'BsonJson';       Marker = 'BSON_JSON: PASS' }
  @{ Dir = 'ProtobufNative'; Marker = 'PROTOBUF_NATIVE: PASS' }
  @{ Dir = 'ProtobufSchema'; Marker = 'PROTOBUF_SCHEMA: PASS' }
  @{ Dir = 'ProtobufReference'; Marker = 'PROTOBUF_REFERENCE: PASS' }
  @{ Dir = 'CborNative';     Marker = 'CBOR_NATIVE: PASS' }
  @{ Dir = 'MessagePackNative'; Marker = 'MESSAGEPACK_NATIVE: PASS' }
  @{ Dir = 'YamlNative';     Marker = 'YAML_NATIVE: PASS' }
  @{ Dir = 'CsvNative';      Marker = 'CSV_NATIVE: PASS' }
  @{ Dir = 'AvroNative';     Marker = 'AVRO_NATIVE: PASS' }
  @{ Dir = 'Asn1Native';     Marker = 'ASN1_NATIVE: PASS' }
  @{ Dir = 'Conversion';     Marker = 'CONVERSION: PASS' }
  @{ Dir = 'ConversionMatrix'; Marker = 'CONVERSION_MATRIX: PASS' }
  @{ Dir = 'ContractMatrix';   Marker = 'CONTRACT_MATRIX: PASS' }
  @{ Dir = 'FormatChain';      Marker = 'FORMAT_CHAIN: PASS' }
  @{ Dir = 'LosslessRouting'; Marker = 'LOSSLESS_ROUTING: PASS' }
  @{ Dir = 'DataSetSources'; Marker = 'DATASET_SOURCES: PASS' }
  @{ Dir = 'DataSetFormats'; Marker = 'DATASET_FORMATS: PASS' }
  @{ Dir = 'StructuralFidelity'; Marker = 'STRUCTURAL_FIDELITY: PASS' }
  @{ Dir = 'UnicodeUtf8';    Marker = 'UNICODE_UTF8: PASS' }
  @{ Dir = 'ReaderContracts'; Marker = 'READER_CONTRACTS: PASS' }
  @{ Dir = 'Robustness';      Marker = 'ROBUSTNESS: PASS' }
  @{ Dir = 'Lifecycle';       Marker = 'LIFECYCLE: PASS' }
  @{ Dir = 'Dynamic';         Marker = 'DYNAMIC: PASS' }
  @{ Dir = 'GeneralAttributes'; Marker = 'GENERAL_ATTRIBUTES: PASS' }
)
if ($Only.Count -gt 0) {
  $Tests = @($Tests | Where-Object { $Only -contains $_.Dir })
  if ($Tests.Count -eq 0) { throw "No test matched -Only $($Only -join ',')" }
}

if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($t in $Tests) {
  $dir = $t.Dir
  $dpr = Join-Path $Repo "tests\$dir\$dir.dpr"
  if (-not (Test-Path -LiteralPath $dpr)) {
    $rows.Add([pscustomobject]@{ test = $dir; status = 'MISSING'; detail = $dpr })
    continue
  }

  $buildLog = Join-Path $OutDir "$dir.build.log"
  & cmd.exe /d /s /c "`"$Dcc`" `"$dpr`" $Compiler tests" *> $buildLog
  if ($LASTEXITCODE -ne 0) {
    $rows.Add([pscustomobject]@{ test = $dir; status = 'BUILD_FAIL'; detail = $buildLog })
    continue
  }

  $exe = Join-Path $Repo "artifacts\tests\$Platform\$dir.exe"
  $outFile = Join-Path $OutDir "$dir.out.txt"
  # Run from the repository root: some tests read their own source by path.
  Push-Location $Repo
  try { & $exe *> $outFile; $code = $LASTEXITCODE } finally { Pop-Location }

  $text = if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile -Raw } else { '' }
  $hasMarker = $text -and $text.Contains($t.Marker)
  # A project that turns on ReportMemoryLeaksOnShutdown reports a leak AFTER
  # its marker and still exits zero, so the report itself is the signal.
  $leaked = $text -and $text.Contains('An unexpected memory leak has occurred')
  $status = if ($code -eq 0 -and $hasMarker -and -not $leaked) { 'PASS' }
            elseif ($code -ne 0) { 'FAIL' }
            elseif ($leaked) { 'LEAKED' }
            else { 'NO_MARKER' }
  $detail = if ($status -eq 'PASS') { '' } else { $outFile }
  $rows.Add([pscustomobject]@{ test = $dir; status = $status; detail = $detail })
}

$pass = @($rows | Where-Object status -eq 'PASS').Count
$fail = $rows.Count - $pass

Write-Host ''
Write-Host "PLATFORM=$Platform"
Write-Host "TESTS_RUN=$($rows.Count)"
Write-Host "TESTS_PASS=$pass"
Write-Host "TESTS_FAIL=$fail"
Write-Host ''
$rows | ForEach-Object { '{0,-18} {1,-12} {2}' -f $_.test, $_.status, $_.detail }

# Two roll-ups, so "the pre-existing suites still pass" is a line you can grep
# for rather than a table you have to read. They are reported only when every
# project they cover was actually run.
function Rollup([string]$name, [string[]]$projects) {
  $covered = @($rows | Where-Object { $projects -contains $_.test })
  if ($covered.Count -ne $projects.Count) { return }
  $bad = @($covered | Where-Object status -ne 'PASS').Count
  Write-Host ''
  Write-Host "$name`: $(if ($bad -eq 0) { 'PASS' } else { 'FAIL' })"
}
Rollup 'JSON_REGRESSION'    @('JsonCore')
Rollup 'DATASET_REGRESSION' @('DataSetParity', 'DataSetJson', 'DataSetSources',
                              'DataSetFormats')
Rollup 'STRUCTURAL_REGRESSION' @('Conversion', 'ConversionMatrix',
                                 'StructuralFidelity', 'BsonJson',
                                 'UnicodeUtf8')

Write-Host ''

# The same four lines, in a file beside the per-test logs.  A completion
# gate reads what a run WROTE, and Write-Host output is not something
# another script can capture - so the summary is written down as well as
# printed.
$summary = @(
  "PLATFORM=$Platform"
  "TESTS_RUN=$($rows.Count)"
  "TESTS_PASS=$pass"
  "TESTS_FAIL=$fail"
  "PUBLIC_TESTS: $(if ($fail -eq 0) { 'PASS' } else { 'FAIL' })"
)
[System.IO.File]::WriteAllLines((Join-Path $OutDir 'SUMMARY.txt'),
  $summary, [System.Text.UTF8Encoding]::new($false))

if ($fail -eq 0) { Write-Host 'PUBLIC_TESTS: PASS'; exit 0 }
Write-Host 'PUBLIC_TESTS: FAIL'
exit 1

