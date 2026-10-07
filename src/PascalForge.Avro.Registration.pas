{*******************************************************************************
  PascalForge.Avro.Registration

  Explicit registration of Avro with the format registry.

  Responsibilities
    - TAvroSerializationRegistration: RegisterFormat, UnregisterFormat, IsRegistered.
    - The registry handler that forwards TSerialization calls to the engine.

  Registration
    NO AUTOMATIC REGISTRATION OCCURS FROM UNIT INITIALIZATION. Linking this
    unit, or loading the package that contains it, registers nothing. An
    application registers Avro at startup:

      TAvroSerializationRegistration.RegisterFormat;

    Direct TAvroSerializer use never needs this. Finalization only removes
    a handler this unit registered, so an unloaded package leaves no handler
    whose code is gone.

  Documentation
    docs/formats/avro.md, docs/configuration-lifecycle.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Avro.Registration;

interface

type
  { Avro in the TSerialization registry.
    RegisterFormat is idempotent; it raises ESerializationFormatConflict when
    a different handler already holds the format. UnregisterFormat is a no-op
    when this unit's handler is not registered, and never removes another. }
  TAvroSerializationRegistration = class sealed
  public
    class procedure RegisterFormat; static;
    class procedure UnregisterFormat; static;
    class function IsRegistered: Boolean; static;
  end;

implementation

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Avro.Schema,
  PascalForge.Avro,
  PascalForge.Avro.Internal;

type
  TAvroFormatHandler = class(TSerializationFormatHandler)
  public
    function Capabilities(
      const AOptions: TStructuralConversionOptions):
      TSerializationFormatCapabilities; override;
    procedure RaiseUnsupported(ACapability: TSerializationFormatCapability;
      AFormat: TSerializationFormat;
      const AOptions: TStructuralConversionOptions); override;
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

function TAvroFormatHandler.PayloadKind: TSerializationPayloadKind;
begin
  Result := TSerializationPayloadKind.Binary;
end;

procedure TAvroFormatHandler.RaiseUnsupported(
  ACapability: TSerializationFormatCapability;
  AFormat: TSerializationFormat;
  const AOptions: TStructuralConversionOptions);
begin
  { The capability error would name the wrong problem. Avro CAN do this; a
    reader simply cannot know what the bytes mean without the schema they
    were written against, which is the whole design of the format. }
  if ACapability in [TSerializationFormatCapability.StructuralParse,
                     TSerializationFormatCapability.StructuralWrite] then
    raise ESerializationSchemaRequired.CreateFor(AFormat,
      'converting structurally. Avro data carries no type information at ' +
      'all - the writer''s schema is what makes the bytes readable. Pass a ' +
      'TAvroSchema in the conversion options');
  inherited;
end;

{ THE SCHEMA THIS END ACTS WITH.

  A bare TAvroSchema is accepted as a context - the common case, where the
  schema is the whole answer. A TAvroSerializationContext adds the reader's
  schema, which is what makes Avro-to-Avro resolution expressible: the source
  role says what the bytes were written with, the destination role says what
  to write. }
function ContextSchema(AContext: TSerializationContext): TAvroSchema;
begin
  Result := nil;
  if AContext is TAvroSerializationContext then
    Result := TAvroSerializationContext(AContext).Schema
  else if AContext is TAvroSchema then
    Result := TAvroSchema(AContext);
end;

function SourceSchemaOf(
  const AOptions: TStructuralConversionOptions): TAvroSchema;
begin
  Result := ContextSchema(
    AOptions.SourceContextFor(TSerializationFormat.Avro));
end;

function DestinationSchemaOf(
  const AOptions: TStructuralConversionOptions): TAvroSchema;
begin
  Result := ContextSchema(
    AOptions.DestinationContextFor(TSerializationFormat.Avro));
end;

{ The schema a READER should resolve into, when the source context named
  one. nil means "as written". }
function SourceReaderSchemaOf(
  const AOptions: TStructuralConversionOptions): TAvroSchema;
var
  Context: TSerializationContext;
begin
  Result := nil;
  Context := AOptions.SourceContextFor(TSerializationFormat.Avro);
  if Context is TAvroSerializationContext then
    Result := TAvroSerializationContext(Context).ReaderSchema;
end;

{ Either role, for Capabilities - which is asked about the handler and not
  about a direction. }
function AnySchemaOf(
  const AOptions: TStructuralConversionOptions): TAvroSchema;
begin
  Result := ContextSchema(AOptions.AnyContextFor(TSerializationFormat.Avro));
end;


function TAvroFormatHandler.Capabilities(
  const AOptions: TStructuralConversionOptions):
  TSerializationFormatCapabilities;
begin
  { The contract half always; the structural half exactly when a schema
    arrived with the question. This is the whole reason Capabilities takes
    the options: the answer is a property of the format AND of what the
    caller brought. }
  Result := [TSerializationFormatCapability.ContractSerialize,
             TSerializationFormatCapability.ContractDeserialize];
  if AnySchemaOf(AOptions) <> nil then
    Result := Result + [TSerializationFormatCapability.StructuralParse,
                        TSerializationFormatCapability.StructuralWrite];
end;

procedure RequireBinary(const APayload: TSerializationPayload);
begin
  if APayload.IsText then
    raise EAvroInputError.Create(
      'Avro reads bytes, and this payload is text. If those characters ' +
      'really are an Avro datum, decode them to TBytes first and say so ' +
      'explicitly.');
end;

function TAvroFormatHandler.SerializeTyped(ATypeInfo: PTypeInfo;
  const AValue: TValue): TSerializationPayload;
begin
  Result := TSerializationPayload.FromBytes(
    TAvroEngine.SerializeRoot(ATypeInfo, AValue));
end;

function TAvroFormatHandler.DeserializeTyped(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload): TValue;
begin
  RequireBinary(APayload);
  Result := TAvroEngine.DeserializeRoot(ATypeInfo, APayload.AsBytes,
    TValue.Empty);
end;

function TAvroFormatHandler.ToDynamic(const APayload: TSerializationPayload;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
var
  Writer: TAvroSchema;
begin
  RequireBinary(APayload);
  { READING, so this handler is the SOURCE: the source context says what
    these bytes were WRITTEN with, and may name a reader's schema to
    resolve them into. }
  Writer := SourceSchemaOf(AOptions);
  if Writer = nil then
    raise ESerializationSchemaRequired.CreateFor(TSerializationFormat.Avro,
      'reading a datum structurally');
  Result := TAvroSerializer.ToDynamic(APayload.AsBytes, Writer,
    SourceReaderSchemaOf(AOptions));
end;

function TAvroFormatHandler.FromDynamic(const AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
var
  Schema: TAvroSchema;
begin
  { Writing, so this handler is the DESTINATION. }
  Schema := DestinationSchemaOf(AOptions);
  if Schema = nil then
    raise ESerializationSchemaRequired.CreateFor(TSerializationFormat.Avro,
      'writing a datum structurally');
  Result := TSerializationPayload.FromBytes(
    TAvroSerializer.FromDynamic(AValue, Schema, AOptions));
end;

{ ------------------------------------------------------------------------ }

class procedure TAvroSerializationRegistration.RegisterFormat;
begin
  TSerializationFormats.Register(TSerializationFormat.Avro, TAvroFormatHandler);
end;

class procedure TAvroSerializationRegistration.UnregisterFormat;
begin
  TSerializationFormats.Unregister(TSerializationFormat.Avro, TAvroFormatHandler);
end;

class function TAvroSerializationRegistration.IsRegistered: Boolean;
begin
  Result :=
    TSerializationFormats.IsRegistered(TSerializationFormat.Avro, TAvroFormatHandler);
end;

initialization
  { Nothing: registering is the application's call, never a side effect
    of linking this unit or loading its package. }

finalization
  { Cleanup only: removes this unit's handler if the application left it
    registered. }
  TAvroSerializationRegistration.UnregisterFormat;

end.
