program PackageProbe;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Loading the packages registers nothing - checked with real packages.

  Built by scripts\check-packages.ps1 WITH RUNTIME PACKAGES, against the
  packages that script has just built: rtl and
  PascalForge.Serialization.Runtime - the core and every format - are loaded
  when the program starts, so the registry and every format live in one
  package, as they do in an application that ships the BPLs.

  STATIC   The Runtime package is loaded at start-up. No format is
           registered until the program asks: JSON alone with
           TJsonSerializationRegistration.RegisterFormat, every format with
           TSerializationFormatsRegistration.RegisterAll. The direct
           serializers need no registration at all.
  DYNAMIC  The DataSet package is loaded with LoadPackage, the way a plug-in
           host loads one. It registers no format and does not switch on the
           JSON integration for TDataSet members, and it unloads cleanly.
  EXIT     The program ends with every format still registered; the
           registration units' finalization removes them, and the script
           fails the probe unless the process exits with code 0. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Rtti,
  PascalForge.Serialization.Core,
  PascalForge.Serialization,
  PascalForge.Json,
  PascalForge.Json.Registration,
  PascalForge.Serialization.AllFormats;

const
  { The packages are built with LIBSUFFIX AUTO, so the BPL file name carries
    the compiler's package version: 280 for Delphi 11, 290 for Delphi 12. }
  {$IF CompilerVersion >= 36.0}
  PACKAGE_SUFFIX = '290';
  {$ELSE}
  PACKAGE_SUFFIX = '280';
  {$IFEND}

var
  GFailures: Integer = 0;

procedure Check(ACondition: Boolean; const AName: string);
begin
  if ACondition then Writeln(AName, ': PASS')
  else
  begin
    Writeln(AName, ': FAIL');
    Inc(GFailures);
  end;
end;

function RegisteredCount: Integer;
var
  F: TSerializationFormat;
begin
  Result := 0;
  for F := Low(TSerializationFormat) to High(TSerializationFormat) do
    if TSerialization.IsRegistered(F) then Inc(Result);
end;

function FormatCount: Integer;
begin
  Result := Ord(High(TSerializationFormat)) - Ord(Low(TSerializationFormat)) + 1;
end;

function OnlyJsonRegistered: Boolean;
var
  F: TSerializationFormat;
begin
  for F := Low(TSerializationFormat) to High(TSerializationFormat) do
    if TSerialization.IsRegistered(F) <> (F = TSerializationFormat.Json) then
      Exit(False);
  Result := True;
end;

function XmlLookupRefused: Boolean;
begin
  Result := False;
  try
    TSerialization.Serialize<Integer>(42, TSerializationFormat.Xml);
  except
    on E: ESerializationFormatNotRegistered do Result := True;
  end;
end;

{ A class method of a type in a package the program was not compiled
  against, found through RTTI. }
function CallClassFunction(const ATypeName, AMethod: string): TValue;
var
  Ctx: TRttiContext;
  T: TRttiType;
begin
  Ctx := TRttiContext.Create;
  try
    T := Ctx.FindType(ATypeName);
    if T = nil then
      raise Exception.CreateFmt('%s is not in any loaded package', [ATypeName]);
    Result := T.GetMethod(AMethod).Invoke(TRttiInstanceType(T).MetaclassType, []);
  finally
    Ctx.Free;
  end;
end;

var
  DataSetPackage: HMODULE;
begin
  try
    Writeln('-- the Runtime package, loaded at start-up --');
    Check(RegisteredCount = 0, 'RUNTIME_LOAD_REGISTERS_NO_FORMAT');
    Check((TJsonSerializer.Serialize<Integer>(42) = '42') and (RegisteredCount = 0),
      'DIRECT_SERIALIZER_NEEDS_NO_REGISTRATION');
    Check(XmlLookupRefused, 'RUNTIME_LOOKUP_SEES_ONLY_REGISTERED_FORMATS');

    TJsonSerializationRegistration.RegisterFormat;
    Check(OnlyJsonRegistered and
      (TSerialization.Serialize<Integer>(42, TSerializationFormat.Json).AsText = '42'),
      'EXPLICIT_JSON_REGISTERS_JSON_ONLY');
    TJsonSerializationRegistration.RegisterFormat;
    Check(OnlyJsonRegistered, 'REGISTER_JSON_TWICE_IS_HARMLESS');
    TJsonSerializationRegistration.UnregisterFormat;
    Check(RegisteredCount = 0, 'UNREGISTER_JSON_LEAVES_NONE');

    TSerializationFormatsRegistration.RegisterAll;
    Check(RegisteredCount = FormatCount, Format('REGISTER_ALL_REGISTERS_EVERY_FORMAT (%d of %d)',
      [RegisteredCount, FormatCount]));
    TSerializationFormatsRegistration.RegisterAll;
    Check(RegisteredCount = FormatCount, 'REGISTER_ALL_TWICE_IS_HARMLESS');
    TSerializationFormatsRegistration.UnregisterAll;
    Check(RegisteredCount = 0, 'UNREGISTER_ALL_LEAVES_NONE');

    Writeln('-- the DataSet package, loaded with LoadPackage --');
    DataSetPackage := LoadPackage('PascalForge.Serialization.DataSet' + PACKAGE_SUFFIX + '.bpl');
    try
      Check(RegisteredCount = 0, 'DATASET_BPL_LOAD_REGISTERS_NO_FORMAT');
      Check(not CallClassFunction('PascalForge.DataSet.Json.TDataSetJsonIntegration',
        'IsRegistered').AsBoolean, 'DATASET_BPL_LOAD_DOES_NOT_REGISTER_JSON_INTEGRATION');
    finally
      UnloadPackage(DataSetPackage);
    end;
    Check(RegisteredCount = 0, 'DATASET_BPL_UNLOAD_LEAVES_THE_REGISTRY_EMPTY');

    { Left registered on purpose: the shutdown path is part of the probe. }
    TSerializationFormatsRegistration.RegisterAll;
    Check(RegisteredCount = FormatCount, 'EXIT_WITH_EVERY_FORMAT_REGISTERED');
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then Writeln('PACKAGE_PROBE: PASS')
  else
  begin
    Writeln('PACKAGE_PROBE: FAIL');
    ExitCode := 1;
  end;
end.
