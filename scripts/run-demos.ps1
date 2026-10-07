# Build every demo and RUN it, one line per demo.
#
#   powershell -File scripts\run-demos.ps1
#   powershell -File scripts\run-demos.ps1 -Platform Win64
#
# A demo that compiles and is never run is documentation that has not been
# checked. Every demo here is a console program that exits zero when it is
# happy, so running them is the check.
#
# The GUI demos are the exception, and they carry their own answer: a demo
# with a window takes --selftest, presses every control from code and exits.
# The list below says which ones, so a GUI demo cannot quietly stop being
# tested by losing its switch.

param(
  [ValidateSet('Win32', 'Win64')] [string]$Platform = 'Win32'
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Dcc = Join-Path $PSScriptRoot 'dcc.cmd'
$Compiler = if ($Platform -eq 'Win64') { 'dcc64' } else { 'dcc32' }
$OutDir = Join-Path $Repo "artifacts\demo-logs\$Platform"

# Demos that open a window, and the marker their self-test prints.
$SelfTests = @{
  'LiveFormatConverter' = 'LIVE_FORMAT_CONVERTER: PASS'
}

if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($dpr in Get-ChildItem -LiteralPath (Join-Path $Repo 'demo') -Recurse -Filter *.dpr -File | Sort-Object FullName) {
  $name = $dpr.BaseName
  $buildLog = Join-Path $OutDir "$name.build.log"
  & cmd.exe /d /s /c "`"$Dcc`" `"$($dpr.FullName)`" $Compiler demo" *> $buildLog
  if ($LASTEXITCODE -ne 0) {
    $rows.Add([pscustomobject]@{ demo = $name; status = 'BUILD_FAIL'; detail = $buildLog })
    continue
  }

  $exe = Join-Path $Repo "artifacts\demo\$Platform\$name.exe"
  if (-not (Test-Path -LiteralPath $exe)) {
    $rows.Add([pscustomobject]@{ demo = $name; status = 'NO_EXE'; detail = $exe })
    continue
  }

  $outLog = Join-Path $OutDir "$name.out.txt"
  $args = @()
  if ($SelfTests.ContainsKey($name)) { $args = @('--selftest') }
  & $exe @args *> $outLog
  $code = $LASTEXITCODE
  $text = Get-Content -LiteralPath $outLog -Raw
  if ($null -eq $text) { $text = '' }

  if ($code -ne 0) {
    $rows.Add([pscustomobject]@{ demo = $name; status = 'RUN_FAIL'; detail = $outLog })
    continue
  }
  if ($SelfTests.ContainsKey($name) -and ($text -notmatch [regex]::Escape($SelfTests[$name]))) {
    $rows.Add([pscustomobject]@{ demo = $name; status = 'NO_MARKER'; detail = $outLog })
    continue
  }
  $rows.Add([pscustomobject]@{ demo = $name; status = 'OK'; detail = '' })
}

Write-Host ''
$rows | ForEach-Object { '{0,-34} {1,-11} {2}' -f $_.demo, $_.status, $_.detail }
$failed = @($rows | Where-Object status -ne 'OK').Count
Write-Host ''
Write-Host "DEMO_PLATFORM=$Platform"
Write-Host "DEMOS_RUN=$($rows.Count)"
Write-Host "DEMOS_FAILED=$failed"
if ($failed -eq 0) { Write-Host 'DEMOS: PASS'; exit 0 }
Write-Host 'DEMOS: FAIL'
exit 1
