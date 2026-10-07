# Everything, in order, with one summary at the end.
#
#   powershell -File scripts\check-all.ps1
#   powershell -File scripts\check-all.ps1 -Platform Win32     # skip the second
#
# The individual scripts are the ones to run while working - they are
# seconds each. This is the one to run before saying something is finished,
# because "it passes" is a claim about all of them at once and about both
# platforms, and a claim nobody ran is not evidence.

param(
  [ValidateSet('Win32', 'Win64', 'Both')] [string]$Platform = 'Both'
)
$ErrorActionPreference = 'Continue'
$Here = $PSScriptRoot
$platforms = if ($Platform -eq 'Both') { @('Win32', 'Win64') } else { @($Platform) }

$steps = [System.Collections.Generic.List[object]]::new()

function Step([string]$name, [scriptblock]$body) {
  Write-Host ''
  Write-Host "########## $name"
  $out = & $body 2>&1
  $ok = $LASTEXITCODE -eq 0
  $out | ForEach-Object { Write-Host $_ }
  $steps.Add([pscustomobject]@{ step = $name; ok = $ok })
  return $out
}

Step 'build (library, demos, benchmarks, both platforms)' {
  powershell -File (Join-Path $Here 'build.ps1') -What all
} | Out-Null

foreach ($p in $platforms) {
  Step "tests ($p)" { powershell -File (Join-Path $Here 'test.ps1') -Platform $p } | Out-Null
  Step "demos ($p)" { powershell -File (Join-Path $Here 'run-demos.ps1') -Platform $p } | Out-Null
}

$boundary = Step 'banned markers' {
  powershell -File (Join-Path $Here 'check-banned-markers.ps1')
}
Step 'format isolation' {
  powershell -File (Join-Path $Here 'check-format-isolation.ps1')
} | Out-Null
Step 'repository layout' {
  powershell -File (Join-Path $Here 'check-repository-layout.ps1')
} | Out-Null

Write-Host ''
Write-Host '########## summary'
$steps | ForEach-Object { '{0,-52} {1}' -f $_.step, $(if ($_.ok) { 'PASS' } else { 'FAIL' }) }

# The two markers the structural-metadata removal is judged by, repeated here
# so that one run of one script answers the question.
Write-Host ''
($boundary | Select-String 'PASCALFORGE_STRUCTURAL_METADATA_REFERENCES|TJSONDATASETSERIALIZER_PUBLIC_REFERENCES') |
  ForEach-Object { Write-Host $_ }

$failed = @($steps | Where-Object { -not $_.ok }).Count
Write-Host ''
Write-Host "CHECK_STEPS=$($steps.Count)"
Write-Host "CHECK_FAILED=$failed"
if ($failed -eq 0) { Write-Host 'ALL_CHECKS: PASS'; exit 0 }
Write-Host 'ALL_CHECKS: FAIL'
exit 1
