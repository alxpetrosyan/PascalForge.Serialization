# Build the library, and optionally everything around it.
#
#   powershell -File scripts\build.ps1                      # library, Win32 + Win64
#   powershell -File scripts\build.ps1 -Platform Win64
#   powershell -File scripts\build.ps1 -What demos
#   powershell -File scripts\build.ps1 -What all
#
# The library build is the packaging check: it compiles the units in src\ with
# src\ as the ONLY search path, so anything the library needs that is not in
# src\ shows up here as a compile error rather than as a broken download.

param(
  [ValidateSet('Win32', 'Win64', 'Both')] [string]$Platform = 'Both',
  [ValidateSet('library', 'demos', 'benchmarks', 'all')] [string]$What = 'library'
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Src  = Join-Path $Repo 'src'
$Ide  = 'C:\Program Files (x86)\Embarcadero\Studio\23.0\bin'
$Dcc  = Join-Path $PSScriptRoot 'dcc.cmd'

$platforms = if ($Platform -eq 'Both') { @('Win32', 'Win64') } else { @($Platform) }
$compilers = @{ 'Win32' = 'dcc32.exe'; 'Win64' = 'dcc64.exe' }

# The roots of the dependency graph. Compiling these pulls in every other
# production unit transitively.
# Every format stem, in the order it joined the library. A stem whose unit is
# not in src yet is skipped rather than failing, so this list can be written
# once and left alone while formats arrive.
$formatStems = @('Json', 'Xml', 'Bson', 'Protobuf', 'Cbor', 'MessagePack',
                 'Yaml', 'Csv', 'Avro', 'Asn1')

$targets = @()
foreach ($s in $formatStems) {
  if (Test-Path -LiteralPath (Join-Path $Src "PascalForge.$s.pas")) {
    $targets += @{ Unit = "PascalForge.$s.pas"; Note = "$s core, alone" }
  }
}
$targets += @{ Unit = 'PascalForge.Serialization.pas'; Note = 'the format-neutral facade alone' }
foreach ($s in $formatStems) {
  if (Test-Path -LiteralPath (Join-Path $Src "PascalForge.$s.Registration.pas")) {
    $targets += @{ Unit = "PascalForge.$s.Registration.pas"; Note = "$s only, registered" }
  }
}
$targets += @{ Unit = 'PascalForge.DataSet.Json.pas'; Note = 'DataSet projection + the JSON integration' }

$rows = [System.Collections.Generic.List[object]]::new()

foreach ($p in $platforms) {
  $exe = Join-Path $Ide $compilers[$p]
  if (-not (Test-Path -LiteralPath $exe)) {
    $rows.Add([pscustomobject]@{ platform = $p; item = '-'; status = 'NO_COMPILER'; detail = $exe })
    continue
  }
  $dcu = Join-Path $Repo "artifacts\dcu\library\$p"
  if (Test-Path -LiteralPath $dcu) { Remove-Item -LiteralPath $dcu -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $dcu | Out-Null

  foreach ($t in $targets) {
    $log = Join-Path $dcu ($t.Unit + '.log')
    $args = @(
      '-B', '-W', '-H'
      '-NSSystem;System.Win;Winapi;Data;Datasnap;Vcl;Xml'
      "-U$Src"      # src only: no test, demo or benchmark unit is reachable
      "-NU$dcu"
      "-N0$dcu"
      $t.Unit
    )
    Push-Location $Src
    try { & $exe @args *> $log; $code = $LASTEXITCODE } finally { Pop-Location }
    $text = Get-Content -LiteralPath $log -Raw
    $warnings = ([regex]::Matches($text, 'Warning:')).Count
    $hints = ([regex]::Matches($text, 'Hint:')).Count
    $rows.Add([pscustomobject]@{
      platform = $p; item = $t.Unit
      status = if ($code -eq 0) { 'OK' } else { 'FAIL' }
      detail = if ($code -eq 0) { "warnings=$warnings hints=$hints" } else { $log }
    })
  }
}

function Build-Folder([string]$Folder, [string]$Bucket) {
  foreach ($p in $platforms) {
    $compiler = if ($p -eq 'Win64') { 'dcc64' } else { 'dcc32' }
    foreach ($dpr in Get-ChildItem -LiteralPath (Join-Path $Repo $Folder) -Recurse -Filter *.dpr -File) {
      $log = Join-Path $Repo "artifacts\$Bucket\$p\$($dpr.BaseName).build.log"
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
      & cmd.exe /d /s /c "`"$Dcc`" `"$($dpr.FullName)`" $compiler $Bucket" *> $log
      $rows.Add([pscustomobject]@{
        platform = $p; item = "$Bucket/$($dpr.BaseName)"
        status = if ($LASTEXITCODE -eq 0) { 'OK' } else { 'FAIL' }
        detail = if ($LASTEXITCODE -eq 0) { '' } else { $log }
      })
    }
  }
}

if ($What -in @('demos', 'all'))      { Build-Folder 'demo' 'demo' }
if ($What -in @('benchmarks', 'all')) { Build-Folder 'benchmarks' 'benchmarks' }

Write-Host ''
$rows | ForEach-Object { '{0,-7} {1,-34} {2,-6} {3}' -f $_.platform, $_.item, $_.status, $_.detail }
$failed = @($rows | Where-Object status -notin @('OK')).Count
Write-Host ''
Write-Host "BUILD_PLATFORMS=$($platforms -join ',')"
Write-Host "BUILD_ITEMS=$($rows.Count)"
Write-Host "BUILD_FAILED=$failed"
if ($failed -eq 0) { Write-Host 'BUILD: PASS'; exit 0 }
Write-Host 'BUILD: FAIL'
exit 1
