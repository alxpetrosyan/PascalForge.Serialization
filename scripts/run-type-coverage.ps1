# The Delphi type-coverage suite, one probe per process.
#
#   powershell -File scripts\run-type-coverage.ps1
#   powershell -File scripts\run-type-coverage.ps1 -Only 'TBcd'
#   powershell -File scripts\run-type-coverage.ps1 -Platform Win64
#
# ONE PROCESS PER PROBE, deliberately. A type that corrupts the heap in one
# format takes the whole process with it, and a single-process run then
# reports the families after it as missing rather than as whatever they
# really are. Isolating them means every family gets an answer, and a probe
# that kills its process is reported as exactly that.

param(
  [ValidateSet('Win32', 'Win64')] [string]$Platform = 'Win32',
  [string]$Only = '',
  [int]$TimeoutSeconds = 60,
  [switch]$NoBuild
)
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Dir = Join-Path $Repo 'tests\TypeCoverage'
$Exe = Join-Path $Repo "artifacts\tests\$Platform\TypeCoverage.exe"
$Out = Join-Path $Repo "artifacts\type-coverage\$Platform"
$Compiler = if ($Platform -eq 'Win64') { 'dcc64' } else { 'dcc32' }

if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Out | Out-Null

if (-not $NoBuild) {
  # The compiler's output is kept: scripts\check-compiler-warnings.ps1 reads it.
  & cmd.exe /d /s /c "`"$(Join-Path $PSScriptRoot 'dcc.cmd')`" `"$(Join-Path $Dir 'TypeCoverage.dpr')`" $Compiler" *> (Join-Path $Out 'TypeCoverage.build.log')
  if ($LASTEXITCODE -ne 0) { Write-Host 'TypeCoverage did not compile'; Write-Host 'DELPHI_TYPE_COVERAGE: FAIL'; exit 1 }
}

$names = Select-String -Path (Join-Path $Dir 'TypeCoverage.dpr') -Pattern "^\s+Add\('[^']+',\s*'([^']+)'" |
  ForEach-Object { $_.Matches[0].Groups[1].Value }
if ($Only) { $names = @($names | Where-Object { $_ -like "*$Only*" }) }

$cells = [System.Collections.Generic.List[object]]::new()
$died = [System.Collections.Generic.List[string]]::new()

foreach ($n in $names) {
  $env:TC_ONLY = $n
  $log = Join-Path $Out ("probe-{0:D3}.txt" -f $cells.Count)
  $p = Start-Process -FilePath $Exe -WorkingDirectory $Dir -NoNewWindow -PassThru -RedirectStandardOutput $log
  $null = $p.Handle
  if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
    $p.Kill()
    $died.Add("$n (timed out)")
  }
  $count = 0
  foreach ($line in Get-Content -LiteralPath $log) {
    if ($line -match '^\s{2}(.{45})\s(\S+)\s+(\S+)\s+(.*)$') {
      $cells.Add([pscustomobject]@{
        probe = $matches[1].Trim(); format = $matches[2]; outcome = $matches[3]; detail = $matches[4]
      })
      $count++
    }
  }
  if ($p.ExitCode -ne 0 -and -not ($died -like "$n*")) {
    $died.Add("$n (process died, exit $($p.ExitCode), after $count cells)")
  }
}
$env:TC_ONLY = ''

$cells | Export-Csv -LiteralPath (Join-Path $Out 'cells.csv') -NoTypeInformation -Encoding UTF8

$byOutcome = $cells | Group-Object outcome
Write-Host ''
Write-Host "PROBES=$($names.Count)"
Write-Host "CELLS=$($cells.Count)"
foreach ($o in 'ok', 'refused', 'RTL', 'DIFF', 'UNSAFE', 'READBACK', 'UNEXPECTED') {
  $k = @($cells | Where-Object outcome -eq $o).Count
  Write-Host ("CELLS_{0}={1}" -f $o.ToUpperInvariant(), $k)
}
Write-Host "PROCESSES_DIED=$($died.Count)"
foreach ($d in $died) { Write-Host "  !! $d" }

$defects = @($cells | Where-Object { $_.outcome -in 'RTL', 'DIFF', 'UNSAFE', 'READBACK', 'UNEXPECTED' })
if ($defects.Count -gt 0) {
  Write-Host ''
  Write-Host '-- cells that are defects --'
  foreach ($c in $defects) {
    Write-Host ('  {0,-9} {1,-12} {2,-44} {3}' -f $c.outcome, $c.format, $c.probe,
      $c.detail.Substring(0, [Math]::Min(150, $c.detail.Length)))
  }
}
Write-Host ''
if ($defects.Count -eq 0 -and $died.Count -eq 0 -and $cells.Count -gt 0) {
  Write-Host 'DELPHI_TYPE_COVERAGE: PASS'; exit 0
}
Write-Host 'DELPHI_TYPE_COVERAGE: FAIL'
exit 1
