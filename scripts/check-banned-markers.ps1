# Fail if a retired name or a removed design comes back.
#
# Each marker below is something this library deliberately got rid of - a
# unit, a type, a piece of vocabulary, a wrapper format. They are scanned for
# in file NAMES and file CONTENT across the tree, so a reappearance in code,
# a test, a demo or a sentence of documentation fails the build.
#
#   powershell -File scripts\check-banned-markers.ps1
#
# Exits non-zero when any marker is found.

param(
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'

# Markers that must never appear. Each is a regex, matched case-insensitively.
$banned = @(
  # The VCL integration unit was removed: a serialization framework has no
  # business special-casing one framework's classes. Any reappearance is a
  # regression, not a feature.
  @{ Name = 'JSON_VCL_UNIT'; Pattern = 'PascalForge\.Json\.Vcl|PascalForge\.Serialization\.Vcl|PascalForge\.Vcl\b' }
  # The format enumeration was renamed TSerializationFormat, with no
  # deprecated alias: one public name, and a stale one fails here.
  @{ Name = 'OLD_TFORMAT';   Pattern = '\bTFormat\b' }
  # 'transport format' and 'wire format' were the wrong top-level CATEGORY:
  # JSON, XML and BSON are ENCODED REPRESENTATIONS, used for persistence,
  # storage, interchange, caching and transport alike.
  #
  # 'wire format' as a PROPER NOUN is a different thing and is allowed. "The
  # Protocol Buffers wire format" is what that specification calls itself,
  # and refusing a standard its own name would be a worse problem than the
  # one this rule exists to prevent. The exemption is by FILE, and only for
  # files that are about protobuf - so calling JSON a wire format anywhere
  # still fails.
  @{ Name = 'TRANSPORT_FORMAT_SECTION';
     Pattern = 'TRANSPORT FORMATS|transport format|wire format|wire serializer'
     ExemptPath = 'protobuf' }
  # PRIVATE STRUCTURAL METADATA.
  #
  # Lossless conversion used to write a wrapper of this library's own into
  # other people's documents - a "$pf:kind" member, a "pf:kind" attribute in
  # a namespace nobody else had heard of. It was reversible and it was
  # worthless to every tool that was not this one.
  #
  # It is gone. Lossless now rests on published standards - the W3C
  # JSON/XML mapping, MongoDB Extended JSON - or refuses. This rule is what
  # stops it coming back, in code, in a test, in a demo or in a sentence of
  # documentation.
  @{ Name = 'STRUCTURAL_METADATA';
     Pattern = '\$pf:|\bpf:kind\b|urn:pascalforge:serialization:structural|TStructuralMetadata|reserved metadata prefix|structural metadata wrapper|PascalForge metadata' }
  # ONE DATASET FACADE.
  #
  # A DataSet is written into a FORMAT, and which format is an argument
  # rather than a class name. TJsonDataSetSerializer was the JSON-shaped
  # half of that idea and is gone; TDataSetSerializer.Serialize takes the
  # format, and TDataSetSerializationPolicy says what goes in.
  @{ Name = 'JSON_DATASET_SERIALIZER';
     Pattern = '\bTJsonDataSetSerializer\b|\bTDataSetJsonPolicy\b|\bTJsonDataSetSchemaInference\b|\bTDataSetJsonDataMode\b' }
)

# Generated output is not source; it is also gitignored.
$skipDirs = @('artifacts', '__history', '.git')

# This script has to spell the markers it forbids, so it is exempt from
# them - the one exemption, and it is short enough to read.
$selfName = Split-Path -Leaf $PSCommandPath

function Get-ScannableFiles {
  Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
    $rel = $_.FullName.Substring($Root.Length).TrimStart('\')
    $first = ($rel -split '\\')[0]
    ($skipDirs -notcontains $first) -and
    ($_.Extension -notin @('.exe', '.dcu', '.bpl', '.dcp', '.res', '.map', '.drc'))
  }
}

$files = @(Get-ScannableFiles)
$violations = [System.Collections.Generic.List[object]]::new()
$counts = @{}
foreach ($b in $banned) { $counts[$b.Name] = 0 }

foreach ($file in $files) {
  $rel = $file.FullName.Substring($Root.Length).TrimStart('\')

  if ($file.Name -eq $selfName) { continue }
  foreach ($b in $banned) {
    # A rule may exempt files whose path says the rule does not apply to
    # them - see TRANSPORT_FORMAT_SECTION.
    if ($b.ContainsKey('ExemptPath') -and ($rel -imatch $b.ExemptPath)) { continue }

    # the path itself
    if ($rel -imatch $b.Pattern) {
      $counts[$b.Name]++
      $violations.Add([pscustomobject]@{ Marker = $b.Name; Where = $rel; Line = 0; Text = '<filename>' })
    }
    # and the content
    $n = 0
    foreach ($hit in (Select-String -LiteralPath $file.FullName -Pattern $b.Pattern -AllMatches -ErrorAction SilentlyContinue)) {
      $counts[$b.Name]++
      if ($n -lt 3) {
        $violations.Add([pscustomobject]@{
          Marker = $b.Name; Where = $rel; Line = $hit.LineNumber
          Text = $hit.Line.Trim()
        })
      }
      $n++
    }
  }
}

if ($violations.Count -gt 0) {
  Write-Host "Banned markers found:`n"
  $violations | Select-Object -First 40 | Format-Table -AutoSize Marker, Where, Line, Text | Out-Host
  if ($violations.Count -gt 40) { Write-Host "... and $($violations.Count - 40) more`n" }
}

Write-Host "FILES_SCANNED=$($files.Count)"
Write-Host "PUBLIC_JSON_VCL_UNIT_REFERENCES=$($counts['JSON_VCL_UNIT'])"
Write-Host "OLD_TFORMAT_PUBLIC_REFERENCES=$($counts['OLD_TFORMAT'])"
Write-Host "TRANSPORT_FORMAT_SECTION_REFERENCES=$($counts['TRANSPORT_FORMAT_SECTION'])"
Write-Host "PASCALFORGE_STRUCTURAL_METADATA_REFERENCES: $($counts['STRUCTURAL_METADATA'])"
Write-Host "TJSONDATASETSERIALIZER_PUBLIC_REFERENCES: $($counts['JSON_DATASET_SERIALIZER'])"

$total = ($counts.Values | Measure-Object -Sum).Sum
if ($total -eq 0) {
  Write-Host "`nBANNED_MARKERS: PASS"
  exit 0
}
Write-Host "`nBANNED_MARKERS: FAIL ($total)"
exit 1
