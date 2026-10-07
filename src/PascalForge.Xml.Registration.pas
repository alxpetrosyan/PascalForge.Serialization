{*******************************************************************************
  PascalForge.Xml.Registration

  Explicit registration of XML with the format registry.

  Responsibilities
    - TXmlSerializationRegistration: RegisterFormat, UnregisterFormat, IsRegistered.
    - The registry handler that forwards TSerialization calls to the engine.

  Registration
    NO AUTOMATIC REGISTRATION OCCURS FROM UNIT INITIALIZATION. Linking this
    unit, or loading the package that contains it, registers nothing. An
    application registers XML at startup:

      TXmlSerializationRegistration.RegisterFormat;

    Direct TXmlSerializer use never needs this. Finalization only removes
    a handler this unit registered, so an unloaded package leaves no handler
    whose code is gone.

  Documentation
    docs/formats/xml.md, docs/configuration-lifecycle.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Xml.Registration;

interface

type
  { XML in the TSerialization registry.
    RegisterFormat is idempotent; it raises ESerializationFormatConflict when
    a different handler already holds the format. UnregisterFormat is a no-op
    when this unit's handler is not registered, and never removes another. }
  TXmlSerializationRegistration = class sealed
  public
    class procedure RegisterFormat; static;
    class procedure UnregisterFormat; static;
    class function IsRegistered: Boolean; static;
  end;

implementation

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Xml,
  PascalForge.Xml.Internal;

type
  TXmlFormatHandler = class(TSerializationFormatHandler)
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

function TXmlFormatHandler.PayloadKind: TSerializationPayloadKind;
begin
  Result := TSerializationPayloadKind.Text;
end;

{ --- contract-aware: straight to the engine, so every XML attribute and
      registration applies exactly as it does through TXmlSerializer ------ }

function TXmlFormatHandler.SerializeTyped(ATypeInfo: PTypeInfo;
  const AValue: TValue): TSerializationPayload;
begin
  Result := TSerializationPayload.FromText(
    TXmlEngine.SerializeRoot(ATypeInfo, AValue, '', False, False));
end;

function TXmlFormatHandler.DeserializeTyped(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload): TValue;
begin
  Result := TXmlEngine.DeserializeRoot(ATypeInfo, APayload.AsTextDocument,
    TValue.Empty);
end;

{ --- structural: the dynamic tree, for a document with no contract ------- }

function TXmlFormatHandler.ToDynamic(
  const APayload: TSerializationPayload;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
begin
  Result := TXmlSerializer.ToDynamic(APayload.AsTextDocument, AOptions);
end;

function TXmlFormatHandler.FromDynamic(const AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
begin
  Result := TSerializationPayload.FromText(
    TXmlSerializer.FromDynamic(AValue, AOptions, 'Value'));
end;

{ ------------------------------------------------------------------------ }

class procedure TXmlSerializationRegistration.RegisterFormat;
begin
  TSerializationFormats.Register(TSerializationFormat.Xml, TXmlFormatHandler);
end;

class procedure TXmlSerializationRegistration.UnregisterFormat;
begin
  TSerializationFormats.Unregister(TSerializationFormat.Xml, TXmlFormatHandler);
end;

class function TXmlSerializationRegistration.IsRegistered: Boolean;
begin
  Result :=
    TSerializationFormats.IsRegistered(TSerializationFormat.Xml, TXmlFormatHandler);
end;

initialization
  { Nothing: registering is the application's call, never a side effect
    of linking this unit or loading its package. }

finalization
  { Cleanup only: removes this unit's handler if the application left it
    registered. }
  TXmlSerializationRegistration.UnregisterFormat;

end.
