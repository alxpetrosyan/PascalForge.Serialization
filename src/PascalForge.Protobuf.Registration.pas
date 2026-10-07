{*******************************************************************************
  PascalForge.Protobuf.Registration

  Explicit registration of Protocol Buffers with the format registry.

  Responsibilities
    - TProtobufSerializationRegistration: RegisterFormat, UnregisterFormat, IsRegistered.
    - The registry handler that forwards TSerialization calls to the engine.

  Registration
    NO AUTOMATIC REGISTRATION OCCURS FROM UNIT INITIALIZATION. Linking this
    unit, or loading the package that contains it, registers nothing. An
    application registers Protocol Buffers at startup:

      TProtobufSerializationRegistration.RegisterFormat;

    Direct TProtobufSerializer use never needs this. Finalization only removes
    a handler this unit registered, so an unloaded package leaves no handler
    whose code is gone.

  Documentation
    docs/formats/protobuf.md, docs/configuration-lifecycle.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Protobuf.Registration;

interface

type
  { Protocol Buffers in the TSerialization registry.
    RegisterFormat is idempotent; it raises ESerializationFormatConflict when
    a different handler already holds the format. UnregisterFormat is a no-op
    when this unit's handler is not registered, and never removes another. }
  TProtobufSerializationRegistration = class sealed
  public
    class procedure RegisterFormat; static;
    class procedure UnregisterFormat; static;
    class function IsRegistered: Boolean; static;
  end;

implementation

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Protobuf,
  PascalForge.Protobuf.Internal,
  PascalForge.Protobuf.Schema;

type
  TProtobufFormatHandler = class(TSerializationFormatHandler)
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

{ The descriptor the caller supplied, or nil. }
{ THE DESCRIPTOR AND THE MESSAGE THIS END IS ABOUT.

  A bare TProtobufSchema is accepted - the common case, where the schema's
  own MessageName or its sole message answers it. A
  TProtobufSerializationContext names the message per conversion, which is
  what makes Protobuf-to-Protobuf expressible: descriptor A in, descriptor B
  out, or one descriptor with two different messages. }
procedure ResolveMessage(AContext: TSerializationContext;
  out ASchema: TProtobufSchema; out AMessage: TProtoMessageDescriptor);
begin
  ASchema := nil;
  AMessage := nil;
  if AContext is TProtobufSerializationContext then
  begin
    ASchema := TProtobufSerializationContext(AContext).Schema;
    AMessage := TProtobufSerializationContext(AContext).Message;
  end
  else if AContext is TProtobufSchema then
  begin
    ASchema := TProtobufSchema(AContext);
    AMessage := ASchema.RootMessage;
  end;
end;

{ Either role, for Capabilities - which is asked about the handler and not
  about a direction. }
function HasAnyContext(
  const AOptions: TStructuralConversionOptions): Boolean;
var
  Context: TSerializationContext;
begin
  Context := AOptions.AnyContextFor(TSerializationFormat.Protobuf);
  Result := (Context is TProtobufSchema) or
            (Context is TProtobufSerializationContext);
end;


function TProtobufFormatHandler.Capabilities(
  const AOptions: TStructuralConversionOptions):
  TSerializationFormatCapabilities;
begin
  { THIS IS A PROPERTY OF THIS HANDLER AND OF WHAT THE CALLER BROUGHT, NOT
    OF PROTOBUF.

    A protobuf message is (field number, wire type, payload) with no names,
    so a handler that has nothing but the bytes cannot honestly turn one
    into a named structural tree. A handler holding the message's descriptor
    can, and the two structural capabilities are then true - which is why
    this question takes the options at all: they are where a schema travels.

    Every caller changes answer with it, with no edit to any of them: the
    matrix in tests\ConversionMatrix, the dropdowns in
    demo\Conversion\06-LiveFormatConverter, and
    TSerialization.StructuralFormats. See docs\conversion.md. }
  Result := [TSerializationFormatCapability.ContractSerialize,
             TSerializationFormatCapability.ContractDeserialize];
  if HasAnyContext(AOptions) then
    Result := Result + [TSerializationFormatCapability.StructuralParse,
                        TSerializationFormatCapability.StructuralWrite];
end;

procedure TProtobufFormatHandler.RaiseUnsupported(
  ACapability: TSerializationFormatCapability;
  AFormat: TSerializationFormat;
  const AOptions: TStructuralConversionOptions);
begin
  { The capability error would say "structural parsing is not available for
    PROTOBUF", which is true of this caller and false of the format, and
    would send them looking for a different format instead of for the
    descriptor that would have worked. }
  if ACapability in [TSerializationFormatCapability.StructuralParse,
                     TSerializationFormatCapability.StructuralWrite] then
    raise ESerializationSchemaRequired.CreateFor(AFormat,
      'converting structurally. Protobuf carries field numbers and no ' +
      'names, so a tree needs the .proto those numbers came from. Load ' +
      'the file protoc emits for --descriptor_set_out with ' +
      'TProtobufSchema.LoadDescriptorSet, name the message with ' +
      'MessageName, and pass it in the conversion options');
  inherited;
end;

function TProtobufFormatHandler.PayloadKind: TSerializationPayloadKind;
begin
  Result := TSerializationPayloadKind.Binary;
end;

{ --- contract-aware: straight to the engine, so every protobuf attribute
      and registration applies exactly as it does through
      TProtobufSerializer ---------------------------------------------- }

procedure RequireBinary(const APayload: TSerializationPayload);
begin
  if APayload.Kind <> TSerializationPayloadKind.Binary then
    raise EProtobufInputError.Create(
      'Protobuf is a binary format and this source is text.' + sLineBreak +
      sLineBreak +
      'Text is not re-encoded into protobuf: the bytes of a string are not ' +
      'a protobuf message, and treating them as one reads the first byte as ' +
      'a field tag. Pass the message''s bytes - TBytes, or ' +
      'TSerializationPayload.FromBytes.');
end;

function TProtobufFormatHandler.SerializeTyped(ATypeInfo: PTypeInfo;
  const AValue: TValue): TSerializationPayload;
begin
  Result := TSerializationPayload.FromBytes(
    TProtoEngine.SerializeRoot(ATypeInfo, AValue,
      TProtobufSerializationOptions.Default));
end;

function TProtobufFormatHandler.DeserializeTyped(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload): TValue;
begin
  RequireBinary(APayload);
  Result := TProtoEngine.DeserializeRoot(ATypeInfo, APayload.AsBytes,
    TValue.Empty);
end;

{ --- structural: the descriptor does it, or nothing does ----------------- }

function TProtobufFormatHandler.ToDynamic(
  const APayload: TSerializationPayload;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
var
  Schema: TProtobufSchema;
  Message_: TProtoMessageDescriptor;
begin
  RequireBinary(APayload);
  { Reading, so this handler is the SOURCE. Which matters: a descriptor set
    at each end - or one set with two different messages - is an ordinary
    conversion, and format identity cannot say which is which. }
  ResolveMessage(AOptions.SourceContextFor(TSerializationFormat.Protobuf),
    Schema, Message_);
  if Schema = nil then
    raise ESerializationSchemaRequired.CreateFor(
      TSerializationFormat.Protobuf,
      'reading a message structurally. Load the descriptor protoc emits ' +
      'for --descriptor_set_out with TProtobufSchema.LoadDescriptorSet and ' +
      'pass it in the conversion options');
  Result := Schema.ToDynamic(APayload.AsBytes, Message_.FullName);
end;

function TProtobufFormatHandler.FromDynamic(const AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
var
  Schema: TProtobufSchema;
  Message_: TProtoMessageDescriptor;
begin
  { Writing, so this handler is the DESTINATION. }
  ResolveMessage(
    AOptions.DestinationContextFor(TSerializationFormat.Protobuf),
    Schema, Message_);
  if Schema = nil then
    raise ESerializationSchemaRequired.CreateFor(
      TSerializationFormat.Protobuf,
      'writing a message structurally. Without a descriptor there are no ' +
      'field numbers, and inventing them is how two programs end up ' +
      'disagreeing about what field 3 means');
  Result := TSerializationPayload.FromBytes(
    Schema.FromDynamic(AValue, Message_.FullName));
end;


{ ------------------------------------------------------------------------ }

class procedure TProtobufSerializationRegistration.RegisterFormat;
begin
  TSerializationFormats.Register(TSerializationFormat.Protobuf, TProtobufFormatHandler);
end;

class procedure TProtobufSerializationRegistration.UnregisterFormat;
begin
  TSerializationFormats.Unregister(TSerializationFormat.Protobuf, TProtobufFormatHandler);
end;

class function TProtobufSerializationRegistration.IsRegistered: Boolean;
begin
  Result :=
    TSerializationFormats.IsRegistered(TSerializationFormat.Protobuf, TProtobufFormatHandler);
end;

initialization
  { Nothing: registering is the application's call, never a side effect
    of linking this unit or loading its package. }

finalization
  { Cleanup only: removes this unit's handler if the application left it
    registered. }
  TProtobufSerializationRegistration.UnregisterFormat;

end.
