{*******************************************************************************
  PascalForge.Asn1.Registration

  Explicit registration of ASN.1 (BER, DER and CER) with the format registry.

  Responsibilities
    - TAsn1SerializationRegistration: RegisterFormat, UnregisterFormat, IsRegistered.
    - The registry handler that forwards TSerialization calls to the engine.

  Registration
    NO AUTOMATIC REGISTRATION OCCURS FROM UNIT INITIALIZATION. Linking this
    unit, or loading the package that contains it, registers nothing. An
    application registers ASN.1 (BER, DER and CER) at startup:

      TAsn1SerializationRegistration.RegisterFormat;

    Direct TAsn1Serializer use never needs this. Finalization only removes
    a handler this unit registered, so an unloaded package leaves no handler
    whose code is gone.

  Documentation
    docs/formats/asn1.md, docs/configuration-lifecycle.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Asn1.Registration;

interface

type
  { ASN.1 (BER, DER and CER) in the TSerialization registry - all three
    encodings, as one operation.
    RegisterFormat is idempotent; it raises ESerializationFormatConflict when
    a different handler already holds the format. UnregisterFormat is a no-op
    when this unit's handler is not registered, and never removes another. }
  TAsn1SerializationRegistration = class sealed
  public
    class procedure RegisterFormat; static;
    class procedure UnregisterFormat; static;
    class function IsRegistered: Boolean; static;
  end;

implementation

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Asn1.Schema,
  PascalForge.Asn1,
  PascalForge.Asn1.Internal;

type
  TAsn1FormatHandler = class(TSerializationFormatHandler)
  strict private
    FRule: TAsn1EncodingRule;
    FFormat: TSerializationFormat;
  public
    constructor CreateWith(ARule: TAsn1EncodingRule;
      AFormat: TSerializationFormat);
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

  { The three registrations, which differ only in the rule they carry. }
  TAsn1BerHandler = class(TAsn1FormatHandler)
  public
    constructor Create; override;
  end;

  TAsn1DerHandler = class(TAsn1FormatHandler)
  public
    constructor Create; override;
  end;

  TAsn1CerHandler = class(TAsn1FormatHandler)
  public
    constructor Create; override;
  end;

constructor TAsn1FormatHandler.CreateWith(ARule: TAsn1EncodingRule;
  AFormat: TSerializationFormat);
begin
  inherited Create;
  FRule := ARule;
  FFormat := AFormat;
end;

constructor TAsn1BerHandler.Create;
begin
  CreateWith(TAsn1EncodingRule.Ber, TSerializationFormat.Asn1Ber);
end;

constructor TAsn1DerHandler.Create;
begin
  CreateWith(TAsn1EncodingRule.Der, TSerializationFormat.Asn1Der);
end;

constructor TAsn1CerHandler.Create;
begin
  CreateWith(TAsn1EncodingRule.Cer, TSerializationFormat.Asn1Cer);
end;

function TAsn1FormatHandler.PayloadKind: TSerializationPayloadKind;
begin
  Result := TSerializationPayloadKind.Binary;
end;

procedure TAsn1FormatHandler.RaiseUnsupported(
  ACapability: TSerializationFormatCapability;
  AFormat: TSerializationFormat;
  const AOptions: TStructuralConversionOptions);
begin
  { The capability error would name the wrong problem. ASN.1 CAN do this;
    what it cannot do is invent the names X.690 leaves out. }
  if ACapability in [TSerializationFormatCapability.StructuralParse,
                     TSerializationFormatCapability.StructuralWrite] then
    raise ESerializationSchemaRequired.CreateFor(AFormat,
      'converting structurally. ASN.1 octets are anonymous - a SEQUENCE is ' +
      'its components with nothing between them - so a named tree needs ' +
      'the module. Declare one with TAsn1Schema and pass it in the ' +
      'conversion options');
  inherited;
end;

{ THE MODULE AND THE TYPE, TOGETHER.

  A context carries both; a bare schema carries only the module, and then the
  type has to be inferred. A module with exactly one assignment can be, and
  that is the convenience kept below - anything else needs the caller to say,
  which is what TAsn1Schema.ForType is for.

  The three encoding rules share one schema language, so a module parsed for
  DER is the same module for BER, and the context routing in Core already
  knows that. }
function ContextOf(const AOptions: TStructuralConversionOptions;
  AFormat: TSerializationFormat; ASource: Boolean): TSerializationContext;
begin
  if ASource then Result := AOptions.SourceContextFor(AFormat)
  else Result := AOptions.DestinationContextFor(AFormat);
end;

{ The module and the type a conversion in this role is about. }
procedure ResolveTarget(const AOptions: TStructuralConversionOptions;
  AFormat: TSerializationFormat; ASource: Boolean;
  out ASchema: TAsn1Schema; out ATypeName: string);
var
  Context: TSerializationContext;
begin
  ASchema := nil;
  ATypeName := '';
  Context := ContextOf(AOptions, AFormat, ASource);
  if Context = nil then Exit;

  if Context is TAsn1SerializationContext then
  begin
    ASchema := TAsn1SerializationContext(Context).Schema;
    ATypeName := TAsn1SerializationContext(Context).RootTypeName;
    Exit;
  end;

  if Context is TAsn1Schema then
  begin
    ASchema := TAsn1Schema(Context);
    { RootType on the schema, when the caller set it, then the module's one
      assignment when it has exactly one. }
    ATypeName := ASchema.RootType;
    if ATypeName <> '' then Exit;
    if ASchema.TypeCount = 1 then
    begin
      ATypeName := ASchema.Types[0].Name;
      Exit;
    end;
    raise EAsn1SchemaError.CreateFmt(
      'This module declares %d type assignments and these octets do not say ' +
      'which one they are. Name it: pass Schema.ForType(''SomeType'') as the ' +
      'context instead of the schema, or set Schema.RootType.',
      [ASchema.TypeCount]);
  end;
end;

{ Whether a context for this format is present in either role - which is the
  question Capabilities asks, because it is about the handler and not about a
  direction. }
function HasAnyContext(const AOptions: TStructuralConversionOptions;
  AFormat: TSerializationFormat): Boolean;
var
  Context: TSerializationContext;
begin
  Context := AOptions.AnyContextFor(AFormat);
  Result := (Context is TAsn1Schema) or (Context is TAsn1SerializationContext);
end;

function TAsn1FormatHandler.Capabilities(
  const AOptions: TStructuralConversionOptions):
  TSerializationFormatCapabilities;
begin
  { The contract half always; the structural half exactly when a schema
    arrived with the question.

    ASN.1 octets are anonymous: a SEQUENCE is its components with nothing
    between them and no names anywhere, and a SEQUENCE and a SEQUENCE OF
    share one tag. A structural tree needs names, so it needs the schema -
    and saying so beats inventing item1, item2, item3. }
  Result := [TSerializationFormatCapability.ContractSerialize,
             TSerializationFormatCapability.ContractDeserialize];
  if HasAnyContext(AOptions, FFormat) then
    Result := Result + [TSerializationFormatCapability.StructuralParse,
                        TSerializationFormatCapability.StructuralWrite];
end;

procedure RequireBinary(const APayload: TSerializationPayload);
begin
  if APayload.IsText then
    raise EAsn1InputError.Create(
      'ASN.1 reads octets, and this payload is text. If those characters ' +
      'are base64 or hex, decode them to TBytes first and say so ' +
      'explicitly - a PEM body is not a DER document until somebody ' +
      'decodes it.');
end;

function TAsn1FormatHandler.SerializeTyped(ATypeInfo: PTypeInfo;
  const AValue: TValue): TSerializationPayload;
begin
  Result := TSerializationPayload.FromBytes(
    TAsn1Engine.SerializeRoot(ATypeInfo, AValue, FRule));
end;

function TAsn1FormatHandler.DeserializeTyped(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload): TValue;
begin
  RequireBinary(APayload);
  Result := TAsn1Engine.DeserializeRoot(ATypeInfo, APayload.AsBytes, FRule);
end;

function TAsn1FormatHandler.ToDynamic(const APayload: TSerializationPayload;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
var
  Schema: TAsn1Schema;
  TypeName: string;
begin
  RequireBinary(APayload);
  { READING, so this handler is the SOURCE. Which matters: converting one
    ASN.1 type to another has a context at each end, and format identity
    cannot tell them apart. }
  ResolveTarget(AOptions, FFormat, True, Schema, TypeName);
  if Schema = nil then
    raise ESerializationSchemaRequired.CreateFor(FFormat,
      'reading octets structurally');
  Result := TAsn1SchemaCodec.ToDynamic(APayload.AsBytes, Schema,
    TypeName, FRule);
end;

function TAsn1FormatHandler.FromDynamic(const AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
var
  Schema: TAsn1Schema;
  TypeName: string;
begin
  { Writing, so this handler is the DESTINATION. }
  ResolveTarget(AOptions, FFormat, False, Schema, TypeName);
  if Schema = nil then
    raise ESerializationSchemaRequired.CreateFor(FFormat,
      'writing octets structurally');
  Result := TSerializationPayload.FromBytes(
    TAsn1SchemaCodec.FromDynamic(AValue, Schema, TypeName, FRule, AOptions));
end;

{ ------------------------------------------------------------------------ }

class procedure TAsn1SerializationRegistration.RegisterFormat;
begin
  TSerializationFormats.Register(TSerializationFormat.Asn1Ber, TAsn1BerHandler);
  TSerializationFormats.Register(TSerializationFormat.Asn1Der, TAsn1DerHandler);
  TSerializationFormats.Register(TSerializationFormat.Asn1Cer, TAsn1CerHandler);
end;

class procedure TAsn1SerializationRegistration.UnregisterFormat;
begin
  TSerializationFormats.Unregister(TSerializationFormat.Asn1Cer, TAsn1CerHandler);
  TSerializationFormats.Unregister(TSerializationFormat.Asn1Der, TAsn1DerHandler);
  TSerializationFormats.Unregister(TSerializationFormat.Asn1Ber, TAsn1BerHandler);
end;

class function TAsn1SerializationRegistration.IsRegistered: Boolean;
begin
  Result :=
    TSerializationFormats.IsRegistered(TSerializationFormat.Asn1Ber, TAsn1BerHandler) and
    TSerializationFormats.IsRegistered(TSerializationFormat.Asn1Der, TAsn1DerHandler) and
    TSerializationFormats.IsRegistered(TSerializationFormat.Asn1Cer, TAsn1CerHandler);
end;

initialization
  { Nothing: registering is the application's call, never a side effect
    of linking this unit or loading its package. }

finalization
  { Cleanup only: removes this unit's handler if the application left it
    registered. }
  TAsn1SerializationRegistration.UnregisterFormat;

end.
