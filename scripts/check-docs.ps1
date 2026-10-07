# Documentation consistency, checked rather than hoped for.
#
#   powershell -File scripts\check-docs.ps1
#
# Three things go stale between a library and its documents, and all three are
# mechanical to catch:
#
#   a document nobody links to, which nobody will ever read;
#   a link to a file that is not there;
#   a document naming a test project, a script or a source unit that has since
#   been renamed or removed - the kind of sentence that reads perfectly and
#   sends somebody to a path that does not exist.
#
# None of this judges whether a document is TRUE. It checks that everything it
# points at is real, which is the part a person cannot do reliably by eye.

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Docs = Join-Path $Repo 'docs'

$problems = [System.Collections.Generic.List[object]]::new()
function Problem([string]$kind, [string]$where, [string]$what) {
  $problems.Add([pscustomobject]@{ kind = $kind; where = $where; what = $what })
}

$docFiles = @(Get-ChildItem -LiteralPath $Docs -Filter *.md -File -Recurse)
$markdown = @($docFiles) + @(Get-ChildItem -LiteralPath $Repo -Filter *.md -File)

# --- 1. every doc is reachable from README or from another doc --------------
$linked = @{}
foreach ($md in $markdown) {
  $text = Get-Content -LiteralPath $md.FullName -Raw
  foreach ($m in [regex]::Matches($text, '\]\(([^)#]+?\.md)(#[^)]*)?\)')) {
    $target = $m.Groups[1].Value
    # A link to somebody else's site is not this repository's problem.
    if ($target -match '^[a-z]+://') { continue }
    $target = $target -replace '/', '\'
    $full = [System.IO.Path]::GetFullPath(
      (Join-Path (Split-Path -Parent $md.FullName) $target))
    $linked[$full.ToLowerInvariant()] = $true
    if (-not (Test-Path -LiteralPath $full)) {
      Problem 'dead-link' $md.Name $target
    }
  }
}
foreach ($d in $docFiles) {
  if (-not $linked.ContainsKey($d.FullName.ToLowerInvariant())) {
    Problem 'orphan' $d.Name 'no document links to it'
  }
}

# --- 2. every tests\X, demo\X, scripts\X and src unit a doc names exists ----
$testDirs = @(Get-ChildItem -LiteralPath (Join-Path $Repo 'tests') -Directory |
  ForEach-Object Name)
$scripts = @(Get-ChildItem -LiteralPath (Join-Path $Repo 'scripts') -File |
  ForEach-Object Name)
$units = @(Get-ChildItem -LiteralPath (Join-Path $Repo 'src') -Filter *.pas -File |
  ForEach-Object BaseName)

foreach ($md in $markdown) {
  $text = Get-Content -LiteralPath $md.FullName -Raw
  foreach ($m in [regex]::Matches($text, 'tests[\\/]([A-Za-z0-9_.]+)')) {
    $name = $m.Groups[1].Value.TrimEnd('.')
    if ($name -eq 'fixtures') { continue }
    if ($testDirs -notcontains $name) { Problem 'missing-test' $md.Name "tests\$name" }
  }
  foreach ($m in [regex]::Matches($text, 'scripts[\\/]([A-Za-z0-9_.-]+\.(?:ps1|cmd))')) {
    $name = $m.Groups[1].Value
    if ($scripts -notcontains $name) { Problem 'missing-script' $md.Name "scripts\$name" }
  }
  foreach ($m in [regex]::Matches($text, '(PascalForge\.[A-Za-z0-9_.]+?)\.pas')) {
    $name = $m.Groups[1].Value
    if ($units -notcontains $name) { Problem 'missing-unit' $md.Name "$name.pas" }
  }
}

# --- 3. the format list is the same everywhere ------------------------------
# Twelve registry entries, ten families. A document that says a different
# number has been left behind by a format.
foreach ($md in $markdown) {
  $text = Get-Content -LiteralPath $md.FullName -Raw
  # Only a PRESENT-TENSE claim about what the library covers. "The six
  # formats that arrived after Protobuf" is history and stays true; "links
  # four formats" is a status line that a later format made false.
  $claim = '(?i)\b(supports?|links?|covers?|handles?|for)\s+(four|five|six|seven|eight|nine|eleven)\s+formats\b'
  foreach ($m in [regex]::Matches($text, $claim)) {
    Problem 'stale-count' $md.Name $m.Value
  }
}

if ($problems.Count -gt 0) {
  $problems | Format-Table kind, where, what -AutoSize | Out-String -Width 140 |
    ForEach-Object { Write-Host $_ }
}

$byKind = $problems | Group-Object kind
Write-Host ''
Write-Host "DOCS_FILES=$($markdown.Count)"
foreach ($k in @('dead-link', 'orphan', 'missing-test', 'missing-script', 'missing-unit', 'stale-count')) {
  $n = @($problems | Where-Object kind -eq $k).Count
  Write-Host ("DOCS_{0}={1}" -f ($k.ToUpperInvariant() -replace '-', '_'), $n)
}
Write-Host ''
if ($problems.Count -eq 0) { Write-Host 'DOCS_CONSISTENCY: PASS'; exit 0 }
Write-Host 'DOCS_CONSISTENCY: FAIL'
exit 1
