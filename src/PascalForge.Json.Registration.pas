{*******************************************************************************
  PascalForge.Json.Registration

  Explicit registration of JSON with the format registry.

  Responsibilities
    - TJsonSerializationRegistration: RegisterFormat, UnregisterFormat, IsRegistered.
    - The registry handler that forwards TSerialization calls to the engine.

  Registration
    NO AUTOMATIC REGISTRATION OCCURS FROM UNIT INITIALIZATION. Linking this
    unit, or loading the package that contains it, registers nothing. An
    application registers JSON at startup:

      TJsonSerializationRegistration.RegisterFormat;

    Direct TJsonSerializer use never needs this. Finalization only removes
    a handler this unit registered, so an unloaded package leaves no handler
    whose code is gone.

  Documentation
    docs/formats/json.md, docs/configuration-lifecycle.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Json.Registration;

interface

type
  { JSON in the TSerialization registry.
    RegisterFormat is idempotent; it raises ESerializationFormatConflict when
    a different handler already holds the format. UnregisterFormat is a no-op
    when this unit's handler is not registered, and never removes another. }
  TJsonSerializationRegistration = class sealed
  public
    class procedure RegisterFormat; static;
    class procedure UnregisterFormat; static;
    class function IsRegistered: Boolean; static;
  end;

implementation

uses
  System.SysUtils, System.Rtti, System.TypInfo, System.JSON,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Json,
  PascalForge.Json.Internal;

type
  TJsonFormatHandler = class(TSerializationFormatHandler)
  public
    function PayloadKind: TSerializationPayloadKind; override;
    function ToDynamic(const APayload: TSerializationPayload;
      const AOptions: TStructuralConversionOptions): TDynamicValue; override;
    function FromDynamic(const AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions): TSerializationPayload; override;
    function DeserializeTyped(ATypeInfo: PTypeInfo;
      const APayload: TSerializationPayload): TValue; override;
    function SerializeTyped(ATypeInfo: PTypeInfo;
      const AValue: TValue): TSerializationPayload; override;
  end;

function TJsonFormatHandler.PayloadKind: TSerializationPayloadKind;
begin
  Result := TSerializationPayloadKind.Text;
end;

{ --- contract-aware: straight to the engine, so every JSON attribute and
      registration applies exactly as it does through TJsonSerializer ----- }

function TJsonFormatHandler.SerializeTyped(ATypeInfo: PTypeInfo;
  const AValue: TValue): TSerializationPayload;
begin
  Result := TSerializationPayload.FromText(
    TJsonEngine.SerializeRoot(ATypeInfo, AValue,
      TJsonSerializationOptions.Default));
end;

function TJsonFormatHandler.DeserializeTyped(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload): TValue;
var
  Parsed: TJSONValue;
begin
  Parsed := TJSONObject.ParseJSONValue(APayload.AsTextDocument);
  if Parsed = nil then
    raise EJsonInputError.Create('Invalid JSON text');
  try
    Result := TJsonEngine.DeserializeRoot(ATypeInfo, Parsed);
  finally
    Parsed.Free;
  end;
end;

{ --- structural: the dynamic tree, for a document with no contract ------- }

function TJsonFormatHandler.ToDynamic(
  const APayload: TSerializationPayload;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
begin
  Result := TJsonSerializer.ToDynamic(APayload.AsTextDocument, AOptions);
end;

function TJsonFormatHandler.FromDynamic(const AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
begin
  Result := TSerializationPayload.FromText(
    TJsonSerializer.FromDynamic(AValue, AOptions));
end;

{ ------------------------------------------------------------------------ }

class procedure TJsonSerializationRegistration.RegisterFormat;
begin
  TSerializationFormats.Register(TSerializationFormat.Json, TJsonFormatHandler);
end;

class procedure TJsonSerializationRegistration.UnregisterFormat;
begin
  TSerializationFormats.Unregister(TSerializationFormat.Json, TJsonFormatHandler);
end;

class function TJsonSerializationRegistration.IsRegistered: Boolean;
begin
  Result :=
    TSerializationFormats.IsRegistered(TSerializationFormat.Json, TJsonFormatHandler);
end;

initialization
  { Nothing: registering is the application's call, never a side effect
    of linking this unit or loading its package. }

finalization
  { Cleanup only: removes this unit's handler if the application left it
    registered. }
  TJsonSerializationRegistration.UnregisterFormat;

end.
