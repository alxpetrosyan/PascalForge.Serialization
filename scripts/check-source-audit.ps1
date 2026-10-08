# Static audits of the source tree: nothing dead, nothing deprecated, every
# project reference real, no registration from initialization, no package
# named like a unit it contains, and no build output beside source.
#
#   powershell -File scripts\check-source-audit.ps1
#
# Each audit prints what it found and a marker; the script fails when any
# marker fails. It reads files only - it builds and runs nothing.

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Src = Join-Path $Repo 'src'
$failed = 0

function Strip-Comments([string]$Text) {
  # Pascal comments - { }, (* *) and // - and string literals, so that a word
  # in prose or in a message is never taken for code.
  # One left-to-right pass, as the compiler reads it: whichever opens first
  # wins, so an apostrophe inside a comment is not a string and a brace
  # inside a string is not a comment.
  $pattern = "'(?:[^'\r\n]|'')*'|\{[^}]*\}|\(\*(?s:.*?)\*\)|//[^\r\n]*"
  return [regex]::Replace($Text, $pattern, {
    param($m) if ($m.Value.StartsWith("'")) { "''" } else { ' ' } })
}

function Report([string]$Marker, [string[]]$Findings) {
  foreach ($f in $Findings) { Write-Host "  $f" }
  if ($Findings.Count -eq 0) { Write-Host "$($Marker): PASS" }
  else { Write-Host "$($Marker): FAIL ($($Findings.Count))"; $script:failed++ }
}

$units = @(Get-ChildItem -LiteralPath $Src -Filter *.pas -File)
$code = @{}
foreach ($u in $units) { $code[$u.Name] = Strip-Comments (Get-Content -LiteralPath $u.FullName -Raw) }
$allCode = ($code.Values -join "`n")

# -------------------------------------------------------- dead source --
# A routine declared in an implementation section is visible to its unit
# only, so a name that appears nowhere else in src is dead. Plus the no-op
# statements that exist only to quiet the compiler about a variable.
$dead = @()
foreach ($u in $units) {
  $text = $code[$u.Name]
  $impl = $text.IndexOf("`nimplementation")
  if ($impl -lt 0) { continue }
  $body = $text.Substring($impl)
  $names = [regex]::Matches($body, '(?m)^(?:function|procedure)\s+([A-Za-z_]\w*)\s*[(:;]') |
    ForEach-Object { $_.Groups[1].Value } | Group-Object
  foreach ($g in $names) {
    $refs = [regex]::Matches($allCode, "\b$([regex]::Escape($g.Name))\b").Count
    if ($refs -le $g.Count) { $dead += "$($u.Name): $($g.Name) is never called" }
  }
  foreach ($m in [regex]::Matches($text, '(?im)^\s*(if\s+(True|False)\b.*|.*\bthen\s*;|for\s+\w+\s+in\s+\w+\s+do\s*;)\s*$')) {
    $dead += "$($u.Name): no-op statement '$($m.Value.Trim())'"
  }
}
Report 'DEAD_SOURCE_AUDIT' $dead

# --------------------------------------------------- deprecated API --
$deprecated = @()
foreach ($u in $units) {
  foreach ($m in [regex]::Matches($code[$u.Name], '(?i)\bdeprecated\b')) {
    $deprecated += "$($u.Name): a declaration is marked deprecated"
  }
}
Write-Host "PUBLIC_DEPRECATED_API=$($deprecated.Count)"
Report 'DEPRECATED_API_AUDIT' $deprecated

# --------------------------------------------- project references --
$refs = @()
$projectFiles = @(Get-ChildItem -LiteralPath $Repo -Recurse -File |
  Where-Object { $_.Extension -in '.dpr', '.dpk', '.dproj', '.groupproj' -and
                 $_.FullName -notlike "$Repo\artifacts\*" })
foreach ($p in $projectFiles) {
  $text = Get-Content -LiteralPath $p.FullName -Raw
  $dir = $p.DirectoryName
  if ($text -match '(?i)\b[A-Z]:\\') { $refs += "$($p.Name): an absolute, machine-specific path" }
  switch ($p.Extension.ToLowerInvariant()) {
    { $_ -in '.dpr', '.dpk' } {
      foreach ($m in [regex]::Matches($text, "(?m)^\s*[\w.]+\s+in\s+'([^']+)'\s*[,;]")) {
        $target = Join-Path $dir $m.Groups[1].Value
        if (-not (Test-Path -LiteralPath $target)) { $refs += "$($p.Name): '$($m.Groups[1].Value)' does not exist" }
      }
    }
    '.dproj' {
      # The DelphiCompile item carries a literal <MainSource>MainSource</MainSource>
      # metadata tag; only the property names a file.
      foreach ($m in [regex]::Matches($text, '<MainSource>([^<]+\.(dpr|dpk))</MainSource>')) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir $m.Groups[1].Value))) {
          $refs += "$($p.Name): MainSource '$($m.Groups[1].Value)' does not exist"
        }
      }
      foreach ($tag in 'DCC_DcuOutput', 'DCC_ExeOutput') {
        $m = [regex]::Match($text, "<$tag>([^<]+)</$tag>")
        if (-not $m.Success) { $refs += "$($p.Name): no $tag, so an IDE build writes beside source" }
        elseif ($m.Groups[1].Value -notmatch 'artifacts') { $refs += "$($p.Name): $tag is outside artifacts" }
      }
    }
    '.groupproj' {
      foreach ($m in [regex]::Matches($text, '<Projects Include="([^"]+)"')) {
        if (-not (Test-Path -LiteralPath (Join-Path $dir $m.Groups[1].Value))) {
          $refs += "$($p.Name): project '$($m.Groups[1].Value)' does not exist"
        }
      }
    }
  }
}
Write-Host "PROJECT_FILES=$($projectFiles.Count)"
Report 'PROJECT_REFERENCE_AUDIT' $refs

# ------------------------------- registration from initialization --
$sideEffects = @()
foreach ($u in $units) {
  $m = [regex]::Match($code[$u.Name], '(?is)\ninitialization\b(.*?)(\nfinalization\b|\nend\.)')
  if ($m.Success -and $m.Groups[1].Value -match '(?i)\b(RegisterFormat|RegisterAll|TSerializationFormats\s*\.\s*Register)\b') {
    $sideEffects += "$($u.Name): its initialization registers a format"
  }
}
Report 'NO_REGISTRATION_INITIALIZATION_SIDE_EFFECTS' $sideEffects

# --------------------------------------- package / unit name clashes --
$clashes = @()
foreach ($dpk in Get-ChildItem -LiteralPath (Join-Path $Repo 'projects') -Recurse -Filter *.dpk -File) {
  $text = Get-Content -LiteralPath $dpk.FullName -Raw
  if ($text -match ('(?m)^\s*' + [regex]::Escape($dpk.BaseName) + '\s+in\s')) { $clashes += "$($dpk.Name) contains a unit of its own name" }
}
foreach ($c in $clashes) { Write-Host "  $c" }
Write-Host "PACKAGE_UNIT_NAME_CLASHES: $($clashes.Count)"
if ($clashes.Count -gt 0) { $failed++ }

# ------------------------------------------- build output beside source --
$generated = '(?i)\.(dcu|exe|dll|bpl|dcp|map|drc|local|identcache|stat|tmp|bak|orig|rsm|tds)$|\.~[^.\\]*$'
$pollution = @(Get-ChildItem -LiteralPath $Repo -Recurse -File -Force |
  Where-Object { $_.FullName -notlike "$Repo\artifacts\*" -and $_.Name -match $generated } |
  ForEach-Object { $_.FullName.Substring($Repo.Length + 1) })
# ...and no generated folder below the root one: an IDE's history, or a
# program run from its own source folder writing an artifacts\ of its own.
$pollution += @(Get-ChildItem -LiteralPath $Repo -Recurse -Directory -Force |
  Where-Object { $_.Name -in '__history', '__recovery', 'artifacts', 'Win32', 'Win64' -and
                 $_.FullName -notlike "$Repo\artifacts*" } |
  ForEach-Object { $_.FullName.Substring($Repo.Length + 1) + '\' })
Report 'SOURCE_POLLUTION_AUDIT' $pollution

Write-Host ''
if ($failed -eq 0) { Write-Host 'SOURCE_AUDIT: PASS'; exit 0 }
Write-Host 'SOURCE_AUDIT: FAIL'
exit 1
