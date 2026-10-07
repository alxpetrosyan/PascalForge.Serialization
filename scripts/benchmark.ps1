# Build and run the reference benchmarks.
#
#   powershell -File scripts\benchmark.ps1
#   powershell -File scripts\benchmark.ps1 -Platform Win64
#
# These print numbers; they do not assert. A benchmark that failed a build
# would be reported, but a slower result is information, not a test failure.
# Use them to notice a change against the previous run on the same machine.

param(
  [ValidateSet('Win32', 'Win64')] [string]$Platform = 'Win32'
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Dcc = Join-Path $PSScriptRoot 'dcc.cmd'
$Compiler = if ($Platform -eq 'Win64') { 'dcc64' } else { 'dcc32' }

$failed = 0
foreach ($dpr in Get-ChildItem -LiteralPath (Join-Path $Repo 'benchmarks') -Recurse -Filter *.dpr -File) {
  $log = Join-Path $Repo "artifacts\benchmarks\$Platform\$($dpr.BaseName).build.log"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $log) | Out-Null
  & cmd.exe /d /s /c "`"$Dcc`" `"$($dpr.FullName)`" $Compiler benchmarks" *> $log
  if ($LASTEXITCODE -ne 0) {
    Write-Host "BUILD FAILED: $($dpr.BaseName) - see $log"
    $failed++
    continue
  }
  Write-Host ''
  & (Join-Path $Repo "artifacts\benchmarks\$Platform\$($dpr.BaseName).exe")
}

Write-Host ''
if ($failed -eq 0) { Write-Host 'BENCHMARKS: PASS'; exit 0 }
Write-Host "BENCHMARKS: FAIL ($failed did not build)"
exit 1
