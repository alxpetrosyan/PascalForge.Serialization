# Which Delphi the scripts build with. Dot-source it:  . (Join-Path $PSScriptRoot 'delphi.ps1')
#
#   Delphi 12 Athens (Studio 23.0) is the default.
#   $env:PASCALFORGE_DELPHI = '11'   builds with Delphi 11 Alexandria (Studio 22.0)
#
# scripts\dcc.cmd reads the same variable, so every build, test, demo and
# package script follows it.

$DelphiVersion = if ($env:PASCALFORGE_DELPHI) { $env:PASCALFORGE_DELPHI } else { '12' }
$DelphiStudios = @{ '11' = '22.0'; '12' = '23.0' }
if (-not $DelphiStudios.ContainsKey($DelphiVersion)) {
  throw "PASCALFORGE_DELPHI must be 11 or 12, not '$DelphiVersion'."
}
$DelphiStudio = $DelphiStudios[$DelphiVersion]
$DelphiBin = "C:\Program Files (x86)\Embarcadero\Studio\$DelphiStudio\bin"
$DelphiRsVars = Join-Path $DelphiBin 'rsvars.bat'
