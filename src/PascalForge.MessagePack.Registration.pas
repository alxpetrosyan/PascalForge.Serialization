{*******************************************************************************
  PascalForge.MessagePack.Registration

  Explicit registration of MessagePack with the format registry.

  Responsibilities
    - TMessagePackSerializationRegistration: RegisterFormat, UnregisterFormat, IsRegistered.
    - The registry handler that forwards TSerialization calls to the engine.

  Registration
    NO AUTOMATIC REGISTRATION OCCURS FROM UNIT INITIALIZATION. Linking this
    unit, or loading the package that contains it, registers nothing. An
    application registers MessagePack at startup:

      TMessagePackSerializationRegistration.RegisterFormat;

    Direct TMessagePackSerializer use never needs this. Finalization only removes
    a handler this unit registered, so an unloaded package leaves no handler
    whose code is gone.

  Documentation
    docs/formats/messagepack.md, docs/configuration-lifecycle.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.MessagePack.Registration;

interface

type
  { MessagePack in the TSerialization registry.
    RegisterFormat is idempotent; it raises ESerializationFormatConflict when
    a different handler already holds the format. UnregisterFormat is a no-op
    when this unit's handler is not registered, and never removes another. }
  TMessagePackSerializationRegistration = class sealed
  public
    class procedure RegisterFormat; static;
    class procedure UnregisterFormat; static;
    class function IsRegistered: Boolean; static;
  end;

implementation

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.MessagePack,
  PascalForge.MessagePack.Internal;

type
  TMessagePackFormatHandler = class(TSerializationFormatHandler)
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

function TMessagePackFormatHandler.PayloadKind: TSerializationPayloadKind;
begin
  Result := TSerializationPayloadKind.Binary;
end;

{ MessagePack is bytes. A string handed to it is a caller error and is named
  as one rather than being silently encoded to UTF-8 and parsed - which
  would read the first character as a format byte and produce a confident
  wrong answer. }
procedure RequireBinary(const APayload: TSerializationPayload);
begin
  if APayload.IsText then
    raise EMessagePackInputError.Create(
      'MessagePack reads bytes, and this payload is text. If those ' +
      'characters really are a MessagePack document, decode them to TBytes ' +
      'first and say so explicitly - guessing here is how a filename ' +
      'becomes a document.');
end;

function TMessagePackFormatHandler.SerializeTyped(ATypeInfo: PTypeInfo;
  const AValue: TValue): TSerializationPayload;
begin
  Result := TSerializationPayload.FromBytes(
    TMessagePackEngine.SerializeRoot(ATypeInfo, AValue));
end;

function TMessagePackFormatHandler.DeserializeTyped(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload): TValue;
begin
  RequireBinary(APayload);
  Result := TMessagePackEngine.DeserializeRoot(ATypeInfo, APayload.AsBytes,
    TValue.Empty);
end;

function TMessagePackFormatHandler.ToDynamic(
  const APayload: TSerializationPayload;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
begin
  RequireBinary(APayload);
  Result := TMessagePackSerializer.ToDynamic(APayload.AsBytes, AOptions);
end;

function TMessagePackFormatHandler.FromDynamic(const AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
begin
  Result := TSerializationPayload.FromBytes(
    TMessagePackSerializer.FromDynamic(AValue, AOptions));
end;

{ ------------------------------------------------------------------------ }

class procedure TMessagePackSerializationRegistration.RegisterFormat;
begin
  TSerializationFormats.Register(TSerializationFormat.MessagePack, TMessagePackFormatHandler);
end;

class procedure TMessagePackSerializationRegistration.UnregisterFormat;
begin
  TSerializationFormats.Unregister(TSerializationFormat.MessagePack, TMessagePackFormatHandler);
end;

class function TMessagePackSerializationRegistration.IsRegistered: Boolean;
begin
  Result :=
    TSerializationFormats.IsRegistered(TSerializationFormat.MessagePack, TMessagePackFormatHandler);
end;

initialization
  { Nothing: registering is the application's call, never a side effect
    of linking this unit or loading its package. }

finalization
  { Cleanup only: removes this unit's handler if the application left it
    registered. }
  TMessagePackSerializationRegistration.UnregisterFormat;

end.
