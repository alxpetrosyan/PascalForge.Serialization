{*******************************************************************************
  PascalForge.Bson.Registration

  Explicit registration of BSON with the format registry.

  Responsibilities
    - TBsonSerializationRegistration: RegisterFormat, UnregisterFormat, IsRegistered.
    - The registry handler that forwards TSerialization calls to the engine.

  Registration
    NO AUTOMATIC REGISTRATION OCCURS FROM UNIT INITIALIZATION. Linking this
    unit, or loading the package that contains it, registers nothing. An
    application registers BSON at startup:

      TBsonSerializationRegistration.RegisterFormat;

    Direct TBsonSerializer use never needs this. Finalization only removes
    a handler this unit registered, so an unloaded package leaves no handler
    whose code is gone.

  Documentation
    docs/formats/bson.md, docs/configuration-lifecycle.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Bson.Registration;

interface

type
  { BSON in the TSerialization registry.
    RegisterFormat is idempotent; it raises ESerializationFormatConflict when
    a different handler already holds the format. UnregisterFormat is a no-op
    when this unit's handler is not registered, and never removes another. }
  TBsonSerializationRegistration = class sealed
  public
    class procedure RegisterFormat; static;
    class procedure UnregisterFormat; static;
    class function IsRegistered: Boolean; static;
  end;

implementation

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Bson,
  PascalForge.Bson.Internal;

type
  TBsonFormatHandler = class(TSerializationFormatHandler)
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

function TBsonFormatHandler.PayloadKind: TSerializationPayloadKind;
begin
  Result := TSerializationPayloadKind.Binary;
end;

{ --- contract-aware: straight to the engine, so every BSON attribute and
      registration applies exactly as it does through TBsonSerializer ----- }

function TBsonFormatHandler.SerializeTyped(ATypeInfo: PTypeInfo;
  const AValue: TValue): TSerializationPayload;
begin
  Result := TSerializationPayload.FromBytes(
    TBsonEngine.SerializeRoot(ATypeInfo, AValue));
end;

{ BSON is bytes. A string handed to it is a caller error, and it is named as
  one here rather than being silently encoded to UTF-8 and parsed - which
  would read the first four characters of somebody's sentence as a document
  length and go looking for a terminator. }
procedure RequireBinary(const APayload: TSerializationPayload);
begin
  if APayload.Kind <> TSerializationPayloadKind.Binary then
    raise EBsonInputError.Create(
      'BSON is a binary format and this source is text.' + sLineBreak +
      sLineBreak +
      'Text is not re-encoded into BSON: the bytes of a string are not a ' +
      'BSON document, and treating them as one reads the first four ' +
      'characters as a length. Pass the document''s bytes - TBytes, or ' +
      'TSerializationPayload.FromBytes.');
end;

function TBsonFormatHandler.DeserializeTyped(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload): TValue;
begin
  RequireBinary(APayload);
  Result := TBsonEngine.DeserializeRoot(ATypeInfo, APayload.AsBytes,
    TValue.Empty);
end;

{ --- structural: the dynamic tree, for a document with no contract ------- }

function TBsonFormatHandler.ToDynamic(
  const APayload: TSerializationPayload;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
begin
  RequireBinary(APayload);
  Result := TBsonSerializer.ToDynamic(APayload.AsBytes);
end;

function TBsonFormatHandler.FromDynamic(const AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
begin
  { No policy applies: BSON's types cover every dynamic kind and a BSON
    member name is an arbitrary string. }
  Result := TSerializationPayload.FromBytes(TBsonSerializer.FromDynamic(AValue));
end;

{ ------------------------------------------------------------------------ }

class procedure TBsonSerializationRegistration.RegisterFormat;
begin
  TSerializationFormats.Register(TSerializationFormat.Bson, TBsonFormatHandler);
end;

class procedure TBsonSerializationRegistration.UnregisterFormat;
begin
  TSerializationFormats.Unregister(TSerializationFormat.Bson, TBsonFormatHandler);
end;

class function TBsonSerializationRegistration.IsRegistered: Boolean;
begin
  Result :=
    TSerializationFormats.IsRegistered(TSerializationFormat.Bson, TBsonFormatHandler);
end;

initialization
  { Nothing: registering is the application's call, never a side effect
    of linking this unit or loading its package. }

finalization
  { Cleanup only: removes this unit's handler if the application left it
    registered. }
  TBsonSerializationRegistration.UnregisterFormat;

end.
