{*******************************************************************************
  PascalForge.Csv.Registration

  Explicit registration of CSV with the format registry.

  Responsibilities
    - TCsvSerializationRegistration: RegisterFormat, UnregisterFormat, IsRegistered.
    - The registry handler that forwards TSerialization calls to the engine.

  Registration
    NO AUTOMATIC REGISTRATION OCCURS FROM UNIT INITIALIZATION. Linking this
    unit, or loading the package that contains it, registers nothing. An
    application registers CSV at startup:

      TCsvSerializationRegistration.RegisterFormat;

    Direct TCsvSerializer use never needs this. Finalization only removes
    a handler this unit registered, so an unloaded package leaves no handler
    whose code is gone.

  Documentation
    docs/formats/csv.md, docs/configuration-lifecycle.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Csv.Registration;

interface

type
  { CSV in the TSerialization registry.
    RegisterFormat is idempotent; it raises ESerializationFormatConflict when
    a different handler already holds the format. UnregisterFormat is a no-op
    when this unit's handler is not registered, and never removes another. }
  TCsvSerializationRegistration = class sealed
  public
    class procedure RegisterFormat; static;
    class procedure UnregisterFormat; static;
    class function IsRegistered: Boolean; static;
  end;

implementation

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Csv,
  PascalForge.Csv.Internal;

type
  TCsvFormatHandler = class(TSerializationFormatHandler)
  public
    function PayloadKind: TSerializationPayloadKind; override;
    function Capabilities(const AOptions: TStructuralConversionOptions):
      TSerializationFormatCapabilities; override;
    procedure RaiseUnsupported(ACapability: TSerializationFormatCapability;
      AFormat: TSerializationFormat;
      const AOptions: TStructuralConversionOptions); override;
    function ToDynamic(const APayload: TSerializationPayload;
      const AOptions: TStructuralConversionOptions): TDynamicValue; override;
    function FromDynamic(const AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions): TSerializationPayload; override;
    function DeserializeTyped(ATypeInfo: PTypeInfo;
      const APayload: TSerializationPayload): TValue; override;
    function SerializeTyped(ATypeInfo: PTypeInfo;
      const AValue: TValue): TSerializationPayload; override;
  end;

function TCsvFormatHandler.PayloadKind: TSerializationPayloadKind;
begin
  Result := TSerializationPayloadKind.Text;
end;

{ The options a registry caller gets.

  The defaults, unless the caller put a TCsvSchema in the conversion options
  for the role CSV is playing - a destination schema to write, a source
  schema to read - in which case its Options. The defaults are the ones that
  refuse rather than guess - Error for a collection, Error for a second
  collection, Flatten for a nested object because that is what a table can
  actually express and it reverses exactly - so another projection is the
  caller's stated choice, carried by the one record field that belongs to
  this format. Core never learns what a CSV option is.

  The contract path has no conversion options and always gets the defaults;
  a caller who wants another mode there uses TCsvSerializer directly. }
function RegistryOptions: TCsvOptions; overload;
begin
  Result := TCsvOptions.Default;
end;

function RegistryOptions(AContext: TSerializationContext): TCsvOptions; overload;
begin
  if AContext is TCsvSchema then
    Result := TCsvSchema(AContext).Options
  else
    Result := TCsvOptions.Default;
end;

{ SeparateTable produces several documents and a structural conversion
  returns one payload, so a destination schema asking for it takes
  StructuralWrite away - and the conversion is refused before the source is
  even parsed, with the sentence that names the API that does return them. }
function TCsvFormatHandler.Capabilities(
  const AOptions: TStructuralConversionOptions):
  TSerializationFormatCapabilities;
begin
  Result := inherited Capabilities(AOptions);
  if RegistryOptions(AOptions.DestinationContextFor(
       TSerializationFormat.Csv)).RequiresSeparateTables then
    Exclude(Result, TSerializationFormatCapability.StructuralWrite);
end;

procedure TCsvFormatHandler.RaiseUnsupported(
  ACapability: TSerializationFormatCapability; AFormat: TSerializationFormat;
  const AOptions: TStructuralConversionOptions);
var
  E: ESerializationFormatCapability;
begin
  if (ACapability = TSerializationFormatCapability.StructuralWrite) and
     RegistryOptions(AOptions.DestinationContextFor(
       TSerializationFormat.Csv)).RequiresSeparateTables then
  begin
    E := ESerializationFormatCapability.CreateFor(AFormat, ACapability);
    E.Message := 'The CSV options ask for SeparateTable. ' +
      CSV_SEPARATE_TABLE_GUIDANCE;
    raise E;
  end;
  inherited RaiseUnsupported(ACapability, AFormat, AOptions);
end;

function TCsvFormatHandler.SerializeTyped(ATypeInfo: PTypeInfo;
  const AValue: TValue): TSerializationPayload;
begin
  Result := TSerializationPayload.FromText(
    TCsvEngine.SerializeRoot(ATypeInfo, AValue, RegistryOptions));
end;

function TCsvFormatHandler.DeserializeTyped(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload): TValue;
begin
  Result := TCsvEngine.DeserializeRoot(ATypeInfo, APayload.AsTextDocument,
    RegistryOptions);
end;

{ A REFUSAL ON THE STRUCTURAL PATH IS A STRUCTURAL ERROR.

  ECsvProjectionError is the right exception for the contract path: it says a
  Delphi MEMBER cannot become columns, and it carries the member's path. On
  the structural path the caller asked the library for a structural
  conversion, and the library's answer to "the destination cannot represent
  this" is EStructuralConversionError, with a path and an issue a caller can
  branch on. Raising the format's own exception there would make CSV the one
  destination whose refusals a generic caller has to special-case.

  The path and the sentence are carried across unchanged; only the class and
  the issue are added. }
procedure RaiseAsStructural(E: ECsvProjectionError;
  const AOptions: TStructuralConversionOptions);
begin
  raise EStructuralConversionError.CreateFor(
    TStructuralIssue.UnsupportedValueKind, AOptions,
    TSerializationFormat.Csv, E.Path, TDynamicKind.Obj, E.Message);
end;

function TCsvFormatHandler.ToDynamic(const APayload: TSerializationPayload;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
begin
  { A table is a SEQUENCE OF ROWS, so it always becomes an array of objects
    - even for one row. A single object for a one-row file would make the
    output shape depend on the data, and nothing can be written against a
    converter whose shape moves. }
  Result := nil;   { RaiseAsStructural always raises; the compiler cannot know }
  try
    Result := TCsvEngine.TextToDynamic(APayload.AsTextDocument,
      RegistryOptions(AOptions.SourceContextFor(TSerializationFormat.Csv)),
      AOptions);
  except
    on E: ECsvProjectionError do RaiseAsStructural(E, AOptions);
  end;
end;

function TCsvFormatHandler.FromDynamic(const AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
begin
  try
    Result := TSerializationPayload.FromText(
      TCsvEngine.DynamicToText(AValue,
        RegistryOptions(AOptions.DestinationContextFor(
          TSerializationFormat.Csv)), AOptions));
  except
    on E: ECsvProjectionError do RaiseAsStructural(E, AOptions);
  end;
end;

{ ------------------------------------------------------------------------ }

class procedure TCsvSerializationRegistration.RegisterFormat;
begin
  TSerializationFormats.Register(TSerializationFormat.Csv, TCsvFormatHandler);
end;

class procedure TCsvSerializationRegistration.UnregisterFormat;
begin
  TSerializationFormats.Unregister(TSerializationFormat.Csv, TCsvFormatHandler);
end;

class function TCsvSerializationRegistration.IsRegistered: Boolean;
begin
  Result :=
    TSerializationFormats.IsRegistered(TSerializationFormat.Csv, TCsvFormatHandler);
end;

initialization
  { Nothing: registering is the application's call, never a side effect
    of linking this unit or loading its package. }

finalization
  { Cleanup only: removes this unit's handler if the application left it
    registered. }
  TCsvSerializationRegistration.UnregisterFormat;

end.
