{*******************************************************************************
  PascalForge.Cbor.Registration

  Explicit registration of CBOR with the format registry.

  Responsibilities
    - TCborSerializationRegistration: RegisterFormat, UnregisterFormat, IsRegistered.
    - The registry handler that forwards TSerialization calls to the engine.

  Registration
    NO AUTOMATIC REGISTRATION OCCURS FROM UNIT INITIALIZATION. Linking this
    unit, or loading the package that contains it, registers nothing. An
    application registers CBOR at startup:

      TCborSerializationRegistration.RegisterFormat;

    Direct TCborSerializer use never needs this. Finalization only removes
    a handler this unit registered, so an unloaded package leaves no handler
    whose code is gone.

  Documentation
    docs/formats/cbor.md, docs/configuration-lifecycle.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Cbor.Registration;

interface

type
  { CBOR in the TSerialization registry.
    RegisterFormat is idempotent; it raises ESerializationFormatConflict when
    a different handler already holds the format. UnregisterFormat is a no-op
    when this unit's handler is not registered, and never removes another. }
  TCborSerializationRegistration = class sealed
  public
    class procedure RegisterFormat; static;
    class procedure UnregisterFormat; static;
    class function IsRegistered: Boolean; static;
  end;

implementation

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Cbor,
  PascalForge.Cbor.Internal;

type
  TCborFormatHandler = class(TSerializationFormatHandler)
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

function TCborFormatHandler.PayloadKind: TSerializationPayloadKind;
begin
  Result := TSerializationPayloadKind.Binary;
end;

{ CBOR is bytes. A string handed to it is a caller error and is named as one
  rather than being silently encoded to UTF-8 and parsed - which would read
  the first character as a major type and produce a confident wrong answer. }
procedure RequireBinary(const APayload: TSerializationPayload);
begin
  if APayload.IsText then
    raise ECborInputError.Create(
      'CBOR reads bytes, and this payload is text. If those characters ' +
      'really are a CBOR document, decode them to TBytes first and say so ' +
      'explicitly - guessing here is how a filename becomes a document.');
end;

function TCborFormatHandler.SerializeTyped(ATypeInfo: PTypeInfo;
  const AValue: TValue): TSerializationPayload;
begin
  Result := TSerializationPayload.FromBytes(
    TCborEngine.SerializeRoot(ATypeInfo, AValue,
      TCborEngine.DefaultEncodeOptions));
end;

function TCborFormatHandler.DeserializeTyped(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload): TValue;
begin
  RequireBinary(APayload);
  Result := TCborEngine.DeserializeRoot(ATypeInfo, APayload.AsBytes,
    TValue.Empty);
end;

function TCborFormatHandler.ToDynamic(const APayload: TSerializationPayload;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
begin
  RequireBinary(APayload);
  Result := TCborSerializer.ToDynamic(APayload.AsBytes, AOptions);
end;

function TCborFormatHandler.FromDynamic(const AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
begin
  { CBOR covers every dynamic kind, so the three profiles produce the same
    bytes. }
  Result := TSerializationPayload.FromBytes(TCborSerializer.FromDynamic(AValue));
end;

{ ------------------------------------------------------------------------ }

class procedure TCborSerializationRegistration.RegisterFormat;
begin
  TSerializationFormats.Register(TSerializationFormat.Cbor, TCborFormatHandler);
end;

class procedure TCborSerializationRegistration.UnregisterFormat;
begin
  TSerializationFormats.Unregister(TSerializationFormat.Cbor, TCborFormatHandler);
end;

class function TCborSerializationRegistration.IsRegistered: Boolean;
begin
  Result :=
    TSerializationFormats.IsRegistered(TSerializationFormat.Cbor, TCborFormatHandler);
end;

initialization
  { Nothing: registering is the application's call, never a side effect
    of linking this unit or loading its package. }

finalization
  { Cleanup only: removes this unit's handler if the application left it
    registered. }
  TCborSerializationRegistration.UnregisterFormat;

end.
