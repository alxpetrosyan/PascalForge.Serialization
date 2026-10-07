# Structural checks that are cheap to run and expensive to discover late.
#
#   powershell -File scripts\check-repository-layout.ps1
#
# Three questions:
#   1. Is there exactly one file declaring each Pascal unit?
#   2. Are any two committed files byte-identical? (a copied unit, usually)
#   3. Does any unit use an attribute whose declaring unit it never imported?
#
# The third is the subtle one. Delphi silently ignores an attribute it cannot
# resolve, so a DTO that says [JsonName('x')] without importing the unit that
# declares it compiles cleanly and serializes with the wrong member name. That
# failure is invisible until someone reads the output.

param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'

$skipDirs = @('artifacts', '__history', '.git')
$files = Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
  $first = ($_.FullName.Substring($Root.Length).TrimStart('\') -split '\\')[0]
  $skipDirs -notcontains $first
}

# --- 1. one file per unit -----------------------------------------------------
$units = @{}
foreach ($f in ($files | Where-Object Extension -eq '.pas')) {
  $text = [System.IO.File]::ReadAllText($f.FullName)
  $m = [regex]::Match($text, '(?im)^\s*unit\s+([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\s*;')
  if (-not $m.Success) { continue }
  $name = $m.Groups[1].Value
  if (-not $units.ContainsKey($name)) { $units[$name] = @() }
  $units[$name] += $f.FullName.Substring($Root.Length).TrimStart('\')
}
$dupUnits = @($units.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })

# --- 2. byte-identical files --------------------------------------------------
# Compiled resources are excluded: a package's .res is a generated stub,
# and two empty stubs are identical by construction rather than by
# anyone having copied a unit.
$byHash = $files | Where-Object { $_.Length -gt 0 -and $_.Extension -ne '.res' } |
  Group-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } |
  Where-Object Count -gt 1
$dupFiles = @($byHash)

# --- 3. attributes used without importing what declares them ------------------
# Delphi silently ignores an attribute whose declaring unit is not in scope:
# the DTO compiles, it serializes, and it is wrong. This catches that.
#
# Comments are stripped first. Documentation legitimately mentions another
# format's attributes - PascalForge.Xml explains that it never reads
# [JsonName], which is exactly the sentence a naive scan would flag.
$attrOwners = @{
  'Json'    = @{ Unit = 'PascalForge.Json';    Pattern = '\[\s*Json(Name|Ignore|Serializer|DateTimeFormat)\b' }
  'Xml'     = @{ Unit = 'PascalForge.Xml';     Pattern = '\[\s*Xml(Name|Ignore|Attribute|Text|Namespace|Array|ItemName|Serializer|DateTimeFormat)\b' }
  'Bson'    = @{ Unit = 'PascalForge.Bson';    Pattern = '\[\s*Bson(Name|Ignore|Serializer|DateTimeRepresentation|GuidRepresentation|CurrencyRepresentation)\b' }
  'DataSet' = @{ Unit = 'PascalForge.DataSet'; Pattern = '\[\s*DataSet(Name|Field|Handler|Ignore)\b' }
}

function Remove-PascalComments {
  param([string]$Text)
  $sb = [System.Text.StringBuilder]::new()
  $i = 0
  $n = $Text.Length
  while ($i -lt $n) {
    $c = $Text[$i]
    if ($c -eq '{') {
      while ($i -lt $n -and $Text[$i] -ne '}') { $i++ }
      $i++
    }
    elseif ($c -eq '(' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '*') {
      $i += 2
      while ($i + 1 -lt $n -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq ')')) { $i++ }
      $i += 2
    }
    elseif ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '/') {
      while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
    }
    else {
      [void]$sb.Append($c)
      $i++
    }
  }
  $sb.ToString()
}

$unresolved = [System.Collections.Generic.List[string]]::new()
foreach ($f in ($files | Where-Object { $_.Extension -in @('.pas', '.dpr') })) {
  $code = Remove-PascalComments ([System.IO.File]::ReadAllText($f.FullName))
  foreach ($a in $attrOwners.GetEnumerator()) {
    if ($code -match $a.Value.Pattern -and $code -notmatch [regex]::Escape($a.Value.Unit)) {
      $unresolved.Add("$($f.FullName.Substring($Root.Length).TrimStart('\\')) uses $($a.Key) attributes without importing $($a.Value.Unit)")
    }
  }
}

# --- report -------------------------------------------------------------------
if ($dupUnits.Count -gt 0) {
  Write-Host "`nSame unit declared in more than one file:"
  foreach ($d in $dupUnits) { Write-Host "  $($d.Key)"; $d.Value | ForEach-Object { Write-Host "    $_" } }
}
if ($dupFiles.Count -gt 0) {
  Write-Host "`nByte-identical files:"
  foreach ($g in $dupFiles) {
    $g.Group | ForEach-Object { Write-Host "    $($_.FullName.Substring($Root.Length).TrimStart('\'))" }
    Write-Host ''
  }
}
if ($unresolved.Count -gt 0) {
  Write-Host "`nAttributes that will be silently ignored:"
  $unresolved | ForEach-Object { Write-Host "  $_" }
}

Write-Host ''
Write-Host "PRODUCTION_UNIT_COUNT=$(@(Get-ChildItem -LiteralPath (Join-Path $Root 'src') -Filter *.pas -File).Count)"
Write-Host "TEST_PROJECT_COUNT=$(@(Get-ChildItem -LiteralPath (Join-Path $Root 'tests') -Recurse -Filter *.dpr -File -ErrorAction SilentlyContinue).Count)"
Write-Host "DEMO_PROJECT_COUNT=$(@(Get-ChildItem -LiteralPath (Join-Path $Root 'demo') -Recurse -Filter *.dpr -File -ErrorAction SilentlyContinue).Count)"
Write-Host "BENCHMARK_PROJECT_COUNT=$(@(Get-ChildItem -LiteralPath (Join-Path $Root 'benchmarks') -Recurse -Filter *.dpr -File -ErrorAction SilentlyContinue).Count)"
Write-Host "DUPLICATE_PASCAL_UNIT_NAMES=$($dupUnits.Count)"
Write-Host "BYTE_IDENTICAL_DUPLICATE_FILES=$($dupFiles.Count)"
Write-Host "UNRESOLVED_ATTRIBUTE_IMPORTS=$($unresolved.Count)"

$total = $dupUnits.Count + $dupFiles.Count + $unresolved.Count
if ($total -eq 0) { Write-Host "`nREPOSITORY_LAYOUT: PASS"; exit 0 }
Write-Host "`nREPOSITORY_LAYOUT: FAIL ($total)"
exit 1
