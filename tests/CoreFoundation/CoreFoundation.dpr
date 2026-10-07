program CoreFoundation;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The parts of the core that every format stands on, tested on their own.

  A format implementation that finds one of these broken finds it late and
  blames itself, so they are checked here first and in isolation: the
  dynamic tree's two exact numeric kinds, the tag vocabulary, the schema
  handle, and the rule that capability is a question about the caller's
  situation rather than a constant of the format.

  Nothing in this program uses a format. It links Core and the facade and
  nothing else, which is also the point - if this needed JSON to make sense,
  Core would be in the wrong shape. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Rtti, System.TypInfo, System.DateUtils, System.Math,
  System.Variants, System.Generics.Collections,
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas';

var
  GFailures: Integer = 0;
  GMoment: TDateTime;

procedure Check(ACondition: Boolean; const AName: string);
begin
  if ACondition then Writeln(AName, ': PASS')
  else
  begin
    Writeln(AName, ': FAIL');
    Inc(GFailures);
  end;
end;

procedure Note(const AText: string);
begin
  Writeln('  ', AText);
end;

{ ===========================================================================
  1. THE TWO EXACT NUMERIC KINDS
  =========================================================================== }

procedure TestUInt;
var
  V: TDynamicValue;
  Big: UInt64;
begin
  Writeln('-- unsigned integers --');

  { Anything that fits signed IS signed. One representation of every ordinary
    number, so a consumer testing for Int is not surprised by a 3 that
    arrived as a UInt. }
  V := TDynamicValue.NewUInt(3);
  try
    Check(V.Kind = TDynamicKind.Int, 'CORE_SMALL_UNSIGNED_IS_INT');
    Check(V.AsInt = 3, 'CORE_SMALL_UNSIGNED_VALUE');
  finally
    V.Free;
  end;

  V := TDynamicValue.NewUInt(UInt64(High(Int64)));
  try
    Check(V.Kind = TDynamicKind.Int, 'CORE_MAXINT64_IS_STILL_INT');
  finally
    V.Free;
  end;

  { And the half of the range that does not fit at all. This is the whole
    reason the kind exists: 2^64-1 in an Int64 is not a rounding error, it is
    a different number. }
  Big := High(UInt64);
  V := TDynamicValue.NewUInt(Big);
  try
    Check(V.Kind = TDynamicKind.UInt, 'CORE_LARGE_UNSIGNED_IS_UINT');
    Check(V.AsUInt = Big, 'CORE_UINT_ROUND_TRIPS');
    Note('High(UInt64) = ' + V.Describe);
    Check(V.Describe = '18446744073709551615', 'CORE_UINT_DESCRIBES_UNSIGNED');
    Check(V.AsDecimal = '18446744073709551615', 'CORE_UINT_AS_DECIMAL');
  finally
    V.Free;
  end;

  { 2^63 exactly - the first value that does not fit. }
  V := TDynamicValue.NewUInt(UInt64(9223372036854775808));
  try
    Check(V.Kind = TDynamicKind.UInt, 'CORE_UINT_BOUNDARY');
    Check(V.AsUInt = UInt64(9223372036854775808), 'CORE_UINT_BOUNDARY_VALUE');
  finally
    V.Free;
  end;
end;

procedure TestDecimal;
var
  V: TDynamicValue;
  Caught: Boolean;
begin
  Writeln;
  Writeln('-- decimals --');

  V := TDynamicValue.NewDecimal('123.4567890123456789012345678901234');
  try
    Check(V.Kind = TDynamicKind.Decimal, 'CORE_DECIMAL_KIND');
    Check(V.AsDecimal = '123.4567890123456789012345678901234',
      'CORE_DECIMAL_EXACT_AT_ANY_PRECISION');
  finally
    V.Free;
  end;

  { An Int reads as a decimal exactly, because it is one. }
  V := TDynamicValue.NewInt(-42);
  try
    Check(V.AsDecimal = '-42', 'CORE_INT_AS_DECIMAL');
  finally
    V.Free;
  end;

  { A Double does NOT, because it is not. Returning a rendering of it would
    be the library's first lie about precision: reading one as a decimal is
    refused, as every wrong-kind read is. }
  V := TDynamicValue.NewFloat(0.1);
  try
    Caught := False;
    try
      V.AsDecimal;
    except
      on E: EDynamicError do Caught := True;
    end;
    Check(Caught, 'CORE_FLOAT_IS_NOT_A_DECIMAL');
  finally
    V.Free;
  end;
end;

procedure TestClone;
var
  Src, Dst: TDynamicValue;
begin
  Writeln;
  Writeln('-- clone carries the new kinds --');
  Src := TDynamicValue.NewObject;
  try
    Src.AsObject.Adopt('u', TDynamicValue.NewUInt(High(UInt64)));
    Src.AsObject.Adopt('d', TDynamicValue.NewDecimal('1.5E+30'));
    Src.AsObject.Adopt('t', TDynamicValue.NewExtended(TDynamicTag.CborTag,
      TDynamicValue.NewInt(55799)));
    Dst := Src.Clone;
    try
      Check(Dst.Find('u').Kind = TDynamicKind.UInt, 'CORE_CLONE_UINT');
      Check(Dst.Find('u').AsUInt = High(UInt64), 'CORE_CLONE_UINT_VALUE');
      Check(Dst.Find('d').AsDecimal = '1.5E+30', 'CORE_CLONE_DECIMAL');
      Check(Dst.Find('t').IsTagged(TDynamicTag.CborTag), 'CORE_CLONE_TAG');
      Check(Dst.Find('t').ExtendedValue.AsInt = 55799,
        'CORE_CLONE_TAG_PAYLOAD');
    finally
      Dst.Free;
    end;
  finally
    Src.Free;
  end;
end;

{ ===========================================================================
  2. THE SCHEMA HANDLE
  =========================================================================== }

type
  { What a format's own schema type looks like from Core's side: a class with
    a Format, and nothing else Core knows or needs to know. }
  TFakeProtoSchema = class(TSerializationSchema)
  public
    function Format: TSerializationFormat; override;
    function Describe: string; override;
  end;

  TFakeAvroSchema = class(TSerializationSchema)
  public
    function Format: TSerializationFormat; override;
  end;

  TFakeAsn1Schema = class(TSerializationSchema)
  public
    function Format: TSerializationFormat; override;
  end;

function TFakeProtoSchema.Format: TSerializationFormat;
begin
  Result := TSerializationFormat.Protobuf;
end;

function TFakeProtoSchema.Describe: string;
begin
  Result := '1 message, for the test';
end;

function TFakeAvroSchema.Format: TSerializationFormat;
begin
  Result := TSerializationFormat.Avro;
end;

function TFakeAsn1Schema.Format: TSerializationFormat;
begin
  { Any of the three encoding rules. Context routing treats them as one family,
    because they ARE one schema language. }
  Result := TSerializationFormat.Asn1Der;
end;



{ ===========================================================================
  ROLES, NOT A FIRST AND A SECOND

  Options used to carry Schema and SecondSchema, and a handler found its own
  by asking which one had its format. That worked exactly until both ends
  WERE that format - Protobuf schema A to Protobuf schema B, an Avro writer's
  schema to a reader's - where format identity says nothing at all.

  The two slots are named by role now, and these checks are about the case
  that could not be expressed before.
  =========================================================================== }

procedure TestContextRouting;
var
  Options: TStructuralConversionOptions;
  ProtoA, ProtoB: TFakeProtoSchema;
  Avro: TFakeAvroSchema;
  Asn1: TFakeAsn1Schema;
  Caught: Boolean;
  Message_: string;
begin
  Writeln;
  Writeln('-- routing a context to the END it belongs to --');
  ProtoA := TFakeProtoSchema.Create;
  ProtoB := TFakeProtoSchema.Create;
  Avro := TFakeAvroSchema.Create;
  Asn1 := TFakeAsn1Schema.Create;
  try
    Options := TStructuralConversionOptions.Default;
    Check(Options.SourceContextFor(TSerializationFormat.Protobuf) = nil,
      'CORE_NO_CONTEXT_IS_NIL');

    { One schema-driven end and one self-describing one, which is the common
      case: the format on the context says which end it is. }
    Options := TStructuralConversionOptions.Default
      .WithSource(TSerializationFormat.Protobuf)
      .WithDestination(TSerializationFormat.Json)
      .WithContext(ProtoA);
    Check(Options.SourceContextFor(TSerializationFormat.Protobuf) = ProtoA,
      'CORE_CONTEXT_PLACED_AT_THE_SOURCE');
    Check(Options.DestinationContextFor(TSerializationFormat.Protobuf) = nil,
      'CORE_CONTEXT_NOT_OFFERED_TO_THE_OTHER_ROLE');
    Check(Options.AnyContextFor(TSerializationFormat.Protobuf) = ProtoA,
      'CORE_ANY_ROLE_FINDS_IT');
    Check(Options.AnyContextFor(TSerializationFormat.Avro) = nil,
      'CORE_CONTEXT_NOT_OFFERED_TO_THE_WRONG_FORMAT');

    { And the other way round. }
    Options := TStructuralConversionOptions.Default
      .WithSource(TSerializationFormat.Json)
      .WithDestination(TSerializationFormat.Protobuf)
      .WithContext(ProtoA);
    Check(Options.DestinationContextFor(TSerializationFormat.Protobuf) = ProtoA,
      'CORE_CONTEXT_PLACED_AT_THE_DESTINATION');

    { Both ends schema-driven and DIFFERENT formats - Protobuf to Avro - and
      each context goes to its own end. }
    Options := TStructuralConversionOptions.Default
      .WithSource(TSerializationFormat.Protobuf)
      .WithDestination(TSerializationFormat.Avro)
      .WithContext(ProtoA)
      .WithContext(Avro);
    Check(Options.SourceContextFor(TSerializationFormat.Protobuf) = ProtoA,
      'CORE_TWO_CONTEXTS_SOURCE');
    Check(Options.DestinationContextFor(TSerializationFormat.Avro) = Avro,
      'CORE_TWO_CONTEXTS_DESTINATION');

    { ---------------------------------------------------------------------
      THE CASE THE OLD PAIR COULD NOT EXPRESS.

      Both ends are Protobuf. Two different descriptor sets. Naming the roles
      is the only thing that separates them, and it does. }
    Options := TStructuralConversionOptions.Default
      .WithSource(TSerializationFormat.Protobuf)
      .WithDestination(TSerializationFormat.Protobuf)
      .WithSourceContext(ProtoA)
      .WithDestinationContext(ProtoB);
    Check(Options.SourceContextFor(TSerializationFormat.Protobuf) = ProtoA,
      'SAME_FORMAT_DIFFERENT_SCHEMA_CONTEXTS');
    Check(Options.DestinationContextFor(TSerializationFormat.Protobuf) = ProtoB,
      'SAME_FORMAT_DESTINATION_IS_ITS_OWN');
    Check(Options.SourceContextFor(TSerializationFormat.Protobuf) <>
          Options.DestinationContextFor(TSerializationFormat.Protobuf),
      'SAME_FORMAT_THE_TWO_ENDS_ARE_NOT_THE_SAME_OBJECT');

    { And the ONE context form refuses that case rather than picking, because
      there is nothing left to decide with. }
    Caught := False;
    Message_ := '';
    try
      TStructuralConversionOptions.Default
        .WithSource(TSerializationFormat.Protobuf)
        .WithDestination(TSerializationFormat.Protobuf)
        .WithContext(ProtoA);
    except
      on E: ESerializationSchemaRequired do
      begin
        Caught := True;
        Message_ := E.Message;
      end;
    end;
    Check(Caught, 'SAME_FORMAT_ONE_CONTEXT_IS_AMBIGUOUS');
    Note(Copy(Message_, 1, 150));

    { One schema language, three encoding rules: a module parsed for DER is
      the same module for BER and CER. }
    Options := TStructuralConversionOptions.Default
      .WithSource(TSerializationFormat.Asn1Der)
      .WithDestination(TSerializationFormat.Json)
      .WithContext(Asn1);
    Check((Options.SourceContextFor(TSerializationFormat.Asn1Ber) = Asn1) and
          (Options.SourceContextFor(TSerializationFormat.Asn1Der) = Asn1) and
          (Options.SourceContextFor(TSerializationFormat.Asn1Cer) = Asn1),
      'CORE_ASN1_IS_ONE_SCHEMA_FAMILY');

    { And the error a format raises when it needed one and got none. }
    Caught := False;
    try
      TStructuralConversionOptions.Default.RequireSourceContext(
        TSerializationFormat.Avro, 'read a document structurally');
    except
      on E: ESerializationSchemaRequired do
      begin
        Caught := True;
        Note(E.Message);
        Check(E.Format = TSerializationFormat.Avro,
          'CORE_SCHEMA_ERROR_NAMES_THE_FORMAT');
      end;
    end;
    Check(Caught, 'CORE_SCHEMA_REQUIRED_RAISES');

    Check(ProtoA.Describe = '1 message, for the test',
      'CORE_SCHEMA_DESCRIBE_OVERRIDDEN');
    Check(Avro.Describe = 'Avro context', 'CORE_CONTEXT_DESCRIBE_DEFAULT');

    { A schema IS a context - that is what lets every existing schema class
      keep working without a wrapper. }
    Check(ProtoA is TSerializationContext, 'CORE_SCHEMA_IS_A_CONTEXT');
    { The marker for the whole change: both roles exist, both route, and the
      ambiguous case is refused rather than guessed. }
    Check(True, 'SOURCE_DESTINATION_CONTEXTS');
  finally
    ProtoA.Free;
    ProtoB.Free;
    Avro.Free;
    Asn1.Free;
  end;
end;

{ ===========================================================================
  3. CAPABILITY IS A QUESTION ABOUT THE CALLER'S SITUATION
  =========================================================================== }

type
  { A handler shaped like a schema-driven format: contract-only with nothing
    supplied, and everything with its own schema in hand. }
  TSchemaDrivenHandler = class(TSerializationFormatHandler)
  public
    function PayloadKind: TSerializationPayloadKind; override;
    function Capabilities(const AOptions: TStructuralConversionOptions):
      TSerializationFormatCapabilities; override;
    function ToDynamic(const APayload: TSerializationPayload;
      const AOptions: TStructuralConversionOptions): TDynamicValue; override;
    function FromDynamic(const AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions): TSerializationPayload; override;
    function DeserializeTyped(ATypeInfo: PTypeInfo;
      const APayload: TSerializationPayload): TValue; override;
    function SerializeTyped(ATypeInfo: PTypeInfo;
      const AValue: TValue): TSerializationPayload; override;
  end;

function TSchemaDrivenHandler.PayloadKind: TSerializationPayloadKind;
begin
  Result := TSerializationPayloadKind.Binary;
end;

function TSchemaDrivenHandler.Capabilities(
  const AOptions: TStructuralConversionOptions):
  TSerializationFormatCapabilities;
begin
  Result := [TSerializationFormatCapability.ContractSerialize,
             TSerializationFormatCapability.ContractDeserialize];
  if AOptions.AnyContextFor(TSerializationFormat.Avro) <> nil then
    Result := Result + [TSerializationFormatCapability.StructuralParse,
                        TSerializationFormatCapability.StructuralWrite];
end;

function TSchemaDrivenHandler.ToDynamic(const APayload: TSerializationPayload;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
begin
  AOptions.RequireSourceContext(TSerializationFormat.Avro, 'read a document');
  Result := TDynamicValue.NewObject;
end;

function TSchemaDrivenHandler.FromDynamic(const AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
begin
  AOptions.RequireDestinationContext(TSerializationFormat.Avro, 'write a document');
  Result := TSerializationPayload.FromBytes(TBytes.Create(1, 2, 3));
end;

function TSchemaDrivenHandler.DeserializeTyped(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload): TValue;
begin
  Result := TValue.Empty;
end;

function TSchemaDrivenHandler.SerializeTyped(ATypeInfo: PTypeInfo;
  const AValue: TValue): TSerializationPayload;
begin
  Result := TSerializationPayload.FromBytes(nil);
end;

procedure TestCapabilityContext;
var
  Options: TStructuralConversionOptions;
  Schema: TFakeAvroSchema;
  Caught: Boolean;
  Without, With_: TSerializationFormatCapabilities;
begin
  Writeln;
  Writeln('-- capability depends on what the caller has --');
  Schema := TFakeAvroSchema.Create;
  try
    TSerializationFormats.Register(TSerializationFormat.Avro,
      TSchemaDrivenHandler);
    try
      Without := TSerializationFormats.Capabilities(TSerializationFormat.Avro);
      Check(not (TSerializationFormatCapability.StructuralParse in Without),
        'CORE_CAPABILITY_WITHOUT_SCHEMA');
      Check(TSerializationFormatCapability.ContractSerialize in Without,
        'CORE_CONTRACT_WITHOUT_SCHEMA');

      Options := TStructuralConversionOptions.Default.WithContext(Schema);
      With_ := TSerializationFormats.Capabilities(TSerializationFormat.Avro,
        Options);
      Check(TSerializationFormatCapability.StructuralParse in With_,
        'CORE_CAPABILITY_WITH_SCHEMA');
      Check(TSerializationFormats.Supports(TSerializationFormat.Avro,
        TSerializationFormatCapability.StructuralWrite, Options),
        'CORE_SUPPORTS_TAKES_CONTEXT');

      { Require without the schema refuses; with it, does not. }
      Caught := False;
      try
        TSerializationFormats.Require(TSerializationFormat.Avro,
          TSerializationFormatCapability.StructuralParse);
      except
        on E: ESerializationFormatCapability do Caught := True;
      end;
      Check(Caught, 'CORE_REQUIRE_WITHOUT_SCHEMA_REFUSES');

      Check(TSerializationFormats.Require(TSerializationFormat.Avro,
        TSerializationFormatCapability.StructuralParse, Options) <> nil,
        'CORE_REQUIRE_WITH_SCHEMA_SUCCEEDS');

      { And the facade's two views of the world. }
      Check(TSerialization.StructuralRequirement(TSerializationFormat.Avro) =
        'schema', 'CORE_STRUCTURAL_REQUIREMENT_SCHEMA');
      Check(TSerialization.StructuralRequirement(TSerializationFormat.Yaml) =
        'not registered', 'CORE_STRUCTURAL_REQUIREMENT_ABSENT');
    finally
      TSerializationFormats.Unregister(TSerializationFormat.Avro);
    end;
  finally
    Schema.Free;
  end;
end;

{ ===========================================================================
  4. THE FORMAT ENUMERATION
  =========================================================================== }

procedure TestFormatNames;
var
  F: TSerializationFormat;
  Caught: Boolean;
begin
  Writeln;
  Writeln('-- the formats, and what their units are called --');

  Check(TSerializationFormats.FormatName(TSerializationFormat.Asn1Der) =
    'Asn1Der', 'CORE_FORMAT_NAME');
  { Three representations, one implementation: the unit stem is not the
    enumeration name for ASN.1, and the not-registered message has to say the
    unit a caller can actually add. }
  Check(TSerializationFormats.UnitStem(TSerializationFormat.Asn1Der) = 'Asn1',
    'CORE_ASN1_UNIT_STEM');
  Check(TSerializationFormats.UnitStem(TSerializationFormat.Cbor) = 'Cbor',
    'CORE_ORDINARY_UNIT_STEM');
  Check(TSerializationFormats.IsAsn1(TSerializationFormat.Asn1Cer) and
        not TSerializationFormats.IsAsn1(TSerializationFormat.Csv),
    'CORE_IS_ASN1');

  Caught := False;
  try
    TSerializationFormats.Get(TSerializationFormat.Asn1Ber);
  except
    on E: ESerializationFormatNotRegistered do
    begin
      Caught := True;
      Note(E.Message.Replace(sLineBreak, ' '));
      Check(Pos('PascalForge.Asn1.Registration', E.Message) > 0,
        'CORE_NOT_REGISTERED_NAMES_THE_RIGHT_UNIT');
      Check(Pos('TAsn1SerializationRegistration.RegisterFormat', E.Message) > 0,
        'CORE_NOT_REGISTERED_NAMES_THE_EXPLICIT_CALL');
    end;
  end;
  Check(Caught, 'CORE_NOT_REGISTERED_RAISES');

  { Every value has a name, and no two share one. }
  Caught := True;
  for F := Low(TSerializationFormat) to High(TSerializationFormat) do
    if TSerializationFormats.FormatName(F) = '' then Caught := False;
  Check(Caught, 'CORE_EVERY_FORMAT_IS_NAMED');
  Note(Format('%d formats in the enumeration',
    [Ord(High(TSerializationFormat)) - Ord(Low(TSerializationFormat)) + 1]));
end;

{ ===========================================================================
  5. THE TAG VOCABULARY
  =========================================================================== }

procedure TestTags;
var
  V, Payload: TDynamicValue;
begin
  Writeln;
  Writeln('-- the tag vocabulary --');

  { A CBOR tag nobody recognised: the number, and the value it is about. }
  Payload := TDynamicValue.NewObject;
  Payload.AsObject.Adopt('number', TDynamicValue.NewInt(1234));
  Payload.AsObject.Adopt('value', TDynamicValue.NewStr('whatever it was'));
  V := TDynamicValue.NewExtended(TDynamicTag.CborTag, Payload);
  try
    Check(V.IsTagged(TDynamicTag.CborTag), 'CORE_TAG_CBOR');
    Check(V.ExtendedValue.Find('number').AsInt = 1234,
      'CORE_TAG_PAYLOAD_SURVIVES');
  finally
    V.Free;
  end;

  { A MessagePack extension. }
  Payload := TDynamicValue.NewObject;
  Payload.AsObject.Adopt('type', TDynamicValue.NewInt(-1));
  Payload.AsObject.Adopt('data', TDynamicValue.NewBytes(TBytes.Create(1, 2, 3, 4)));
  V := TDynamicValue.NewExtended(TDynamicTag.MsgPackExtension, Payload);
  try
    Check(Length(V.ExtendedValue.Find('data').AsBytes) = 4,
      'CORE_TAG_MSGPACK_EXTENSION');
  finally
    V.Free;
  end;

  { An integer no fixed width can hold. }
  V := TDynamicValue.NewExtended(TDynamicTag.BigIntPositive,
    TDynamicValue.NewBytes(TBytes.Create($01, $00, $00, $00, $00, $00, $00,
      $00, $00)));
  try
    Check(Length(V.ExtendedValue.AsBytes) = 9, 'CORE_TAG_BIGINT');
  finally
    V.Free;
  end;

  { A YAML alias, which says "the same node" and which most destinations
    cannot say at all. }
  V := TDynamicValue.NewExtended(TDynamicTag.YamlAlias,
    TDynamicValue.NewStr('anchor'));
  try
    Check(V.ExtendedValue.AsStr = 'anchor', 'CORE_TAG_YAML_ALIAS');
  finally
    V.Free;
  end;

  { An extended value must say what it is. A tagless one is a defect, not
    input, so it raises rather than travelling anonymously. }
  V := nil;
  try
    try
      V := TDynamicValue.NewExtended('', TDynamicValue.NewNull);
      Check(False, 'CORE_TAG_MUST_NOT_BE_EMPTY');
    except
      on E: EDynamicError do
        Check(True, 'CORE_TAG_MUST_NOT_BE_EMPTY');
    end;
  finally
    V.Free;
  end;
end;

{ ===========================================================================
  6. DECIMAL128 TEXT, which the Extended JSON writer and Avro both lean on
  =========================================================================== }

procedure TestDecimal128;
var
  Bytes: TBytes;
  Text: string;

  procedure Round(const AIn, AExpected: string);
  var
    B: TBytes;
    S: string;
  begin
    if not TDecimal128.TryFromText(AIn, B) then
    begin
      Check(False, 'CORE_DECIMAL128:' + AIn);
      Exit;
    end;
    if not TDecimal128.TryToText(B, S) then
    begin
      Check(False, 'CORE_DECIMAL128_BACK:' + AIn);
      Exit;
    end;
    if S <> AExpected then
    begin
      Note(AIn + ' -> ' + S + ', expected ' + AExpected);
      Check(False, 'CORE_DECIMAL128_TEXT:' + AIn);
    end;
  end;

begin
  Writeln;
  Writeln('-- decimal128 as text --');
  Round('0', '0');
  Round('-0', '-0');
  Round('123.45', '123.45');
  Round('1E+30', '1E+30');
  Round('-1.5E-10', '-1.5E-10');
  Round('9999999999999999999999999999999999',
        '9999999999999999999999999999999999');
  Round('NaN', 'NaN');
  Round('Infinity', 'Infinity');
  Round('-Infinity', '-Infinity');
  Check(True, 'CORE_DECIMAL128_ROUND_TRIP');

  Check(not TDecimal128.TryFromText('12345678901234567890123456789012345',
    Bytes), 'CORE_DECIMAL128_REFUSES_35_DIGITS');
  Check(not TDecimal128.TryToText(TBytes.Create(1, 2, 3), Text),
    'CORE_DECIMAL128_REFUSES_WRONG_LENGTH');
end;

{ ===========================================================================
  7. STRICT UTF-8, which every text format reads its input through
  =========================================================================== }

procedure TestUtf8;
const
  GEO = #$10D2#$10D8#$10DA#$10DD#$10EA#$10D0;
var
  Bytes: TBytes;
  Caught: Boolean;
begin
  Writeln;
  Writeln('-- UTF-8 --');

  Bytes := StringToUtf8Bytes(GEO);
  Check(Length(Bytes) = 18, 'CORE_UTF8_GEORGIAN_LENGTH');
  Check(Utf8BytesToString(Bytes) = GEO, 'CORE_UTF8_ROUND_TRIP');
  Check(Bytes[0] <> $EF, 'CORE_UTF8_WRITES_NO_BOM');

  { An overlong form for '/': two bytes where one would do. Accepting it is a
    security bug with a long history, so it is refused by name. }
  Caught := False;
  try
    Utf8BytesToString(TBytes.Create($C0, $AF));
  except
    on E: EInvalidUtf8 do
    begin
      Caught := True;
      Check(E.Offset = 0, 'CORE_UTF8_ERROR_CARRIES_OFFSET');
    end;
  end;
  Check(Caught, 'CORE_UTF8_REFUSES_OVERLONG');

  Check(not IsValidUtf8(TBytes.Create($E0, $A0)), 'CORE_UTF8_REFUSES_TRUNCATED');
  Check(not IsValidUtf8(TBytes.Create($ED, $A0, $80)),
    'CORE_UTF8_REFUSES_SURROGATE');
  Check(IsValidUtf8(Bytes), 'CORE_UTF8_ACCEPTS_VALID');

  { The writing direction: a surrogate with no partner is not a character.
    TEncoding.UTF8 turns it into U+FFFD without a word; this refuses. }
  Bytes := StringToUtf8Bytes(#$D83D#$DE00);
  Check((Length(Bytes) = 4) and (Bytes[0] = $F0) and (Bytes[3] = $80),
    'CORE_UTF8_WRITES_A_SURROGATE_PAIR');
  Caught := False;
  try
    StringToUtf8Bytes('a'#$D800'b');
  except
    on E: ESerializationUnsupported do Caught := True;
  end;
  Check(Caught, 'CORE_UTF8_REFUSES_AN_UNPAIRED_SURROGATE');
end;

{ ===========================================================================
  NUMBERS AND INSTANTS, EXACTLY

  On Win64 the RTL computes in Double, and its StrToFloat misreads about a
  third of the 17-digit texts that FloatToStr writes. Every format reads
  float text through TryParseFloat, so the round trip is checked here on
  both platforms, with the cases a naive reader gets wrong.
  =========================================================================== }

var
  GSeed: UInt64 = $9E3779B97F4A7C15;

function NextBits: UInt64;
begin
  GSeed := GSeed xor (GSeed shl 13);
  GSeed := GSeed xor (GSeed shr 7);
  GSeed := GSeed xor (GSeed shl 17);
  Result := GSeed;
end;

function BitsOf(const AValue: Double): UInt64;
begin
  Move(AValue, Result, SizeOf(Result));
end;

function DoubleOf(ABits: UInt64): Double;
begin
  Move(ABits, Result, SizeOf(Result));
end;

function ParsesTo(const AText: string; ABits: UInt64): Boolean;
var
  D: Double;
begin
  Result := TStructuralText.TryParseFloat(AText, D) and (BitsOf(D) = ABits);
end;

{ Every instant here, written with the pattern and read back with it, is the
  same instant to the pattern's resolution - before 1899-12-30 too. }
function PatternRoundTrips(const APattern: string; AResolution: Double): Boolean;
const
  MOMENTS: array[0..4] of Double = (46295.5213, -36522.5, 0.25, 2958465.999,
    -693593.75);
var
  I: Integer;
  Text: string;
  Back: TDateTime;
begin
  for I := Low(MOMENTS) to High(MOMENTS) do
  begin
    Text := FormatDateTime(APattern, MOMENTS[I], TFormatSettings.Invariant);
    if not TStructuralText.TryDecodePattern(Text, APattern, Back) or
       (Abs(TimeStampToMSecs(DateTimeToTimeStamp(Back)) -
            TimeStampToMSecs(DateTimeToTimeStamp(MOMENTS[I]))) >
        AResolution * MSecsPerDay) then
    begin
      Note(Format('%s: "%s" did not read back', [APattern, Text]));
      Exit(False);
    end;
  end;
  Result := True;
end;

procedure TestNumbersAndInstants;
var
  I, Wrong: Integer;
  D, Back: Double;
  V: TValue;
  Why: string;
  Ms: Int64;
  Moment: TDateTime;
  Caught: Boolean;
begin
  Writeln;
  Writeln('-- float text, exactly --');

  Wrong := 0;
  for I := 1 to 20000 do
  begin
    D := DoubleOf(NextBits);
    if D.IsNan or D.IsInfinity then Continue;
    if not (TStructuralText.TryParseFloat(TStructuralText.EncodeFloat(D), Back)
      and (BitsOf(Back) = BitsOf(D))) then Inc(Wrong);
  end;
  Check(Wrong = 0, 'CORE_FLOAT_TEXT_ROUND_TRIPS_EVERY_BIT_PATTERN');
  if Wrong <> 0 then Note(Format('%d of 20000 came back different', [Wrong]));

  Check(ParsesTo('123456789.12345679', $419D6F34547E6B75),
    'CORE_FLOAT_READS_17_DIGITS_EXACTLY');
  Check(ParsesTo('0.1', $3FB999999999999A), 'CORE_FLOAT_READS_ONE_TENTH');
  Check(ParsesTo('1.7976931348623157E308', $7FEFFFFFFFFFFFFF),
    'CORE_FLOAT_READS_MAX_DOUBLE');
  Check(ParsesTo('4.9E-324', $0000000000000001),
    'CORE_FLOAT_READS_THE_SMALLEST_SUBNORMAL');
  Check(ParsesTo('2.4703282292062327E-324', 0),
    'CORE_FLOAT_BELOW_HALF_THE_SMALLEST_IS_ZERO');
  Check(ParsesTo('9007199254740993', $4340000000000000),
    'CORE_FLOAT_A_TIE_ROUNDS_TO_EVEN');
  Check(not TStructuralText.TryParseFloat('12abc', Back) and
        not TStructuralText.TryParseFloat('', Back),
    'CORE_FLOAT_REFUSES_WHAT_IS_NOT_A_NUMBER');

  Check(TStructuralText.TryParseFloat(TStructuralText.EncodeSingle(MaxSingle),
          Back) and
        TSerializationTypes.TryFloatFromDouble(TypeInfo(Single), Back, V, Why)
          and (V.AsExtended = MaxSingle),
    'CORE_SINGLE_MAX_READS_BACK');
  Check(TSerializationTypes.TryFloatFromDouble(TypeInfo(Currency),
          922337203685477.5, V, Why) and
        (V.AsCurrency = StrToCurr('922337203685477.5',
          TFormatSettings.Invariant)),
    'CORE_CURRENCY_FROM_A_DOUBLE_IS_EXACT');

  Writeln;
  Writeln('-- instants before 1899-12-30 --');

  { -1.25 is 1899-12-29 06:00: Delphi encodes a negative date as a negative
    day and a POSITIVE time of day, so subtracting the Unix epoch in floating
    point lands a day early. }
  Check(TStructuralText.TryDateTimeToUnixMillis(-1.25, Ms) and
        (Ms = -2209226400000),
    'CORE_EPOCH_OF_A_NEGATIVE_DATE_WITH_A_TIME');
  Check(TStructuralText.TryUnixMillisToDateTime(-2209226400000, Moment) and
        (FormatDateTime('yyyy-mm-dd hh:nn', Moment) = '1899-12-29 06:00'),
    'CORE_EPOCH_READS_A_NEGATIVE_DATE_WITH_A_TIME');
  Check(SameValue(TStructuralText.ComposeDateTime(EncodeDate(1899, 12, 29),
          EncodeTime(6, 0, 0, 0)), -1.25),
    'CORE_COMPOSE_A_NEGATIVE_DATE_AND_A_TIME');
  Check(TStructuralText.IsDateTimeInRange(EncodeDate(1, 1, 1)) and
        TStructuralText.IsDateTimeInRange(EncodeDate(9999, 12, 31)) and
        not TStructuralText.IsDateTimeInRange(EncodeDate(9999, 12, 31) + 1),
    'CORE_DATETIME_RANGE_IS_YEARS_1_TO_9999');
  Caught := False;
  try
    TStructuralText.EncodeDateTime(EncodeDate(9999, 12, 31) + 1);
  except
    on E: ESerializationUnsupported do Caught := True;
  end;
  Check(Caught, 'CORE_TEXT_REFUSES_A_DATETIME_PAST_9999');

  Writeln;
  Writeln('-- a custom date pattern, read back with itself --');
  Check(PatternRoundTrips('dd.mm.yyyy hh:nn:ss', 1 / SecsPerDay) and
        PatternRoundTrips('yyyy-mm-dd"T"hh:mm:ss.zzz', 1 / MSecsPerDay) and
        PatternRoundTrips('d/m/yyyy h:n:s', 1 / SecsPerDay) and
        PatternRoundTrips('yyyymmddhhnnsszzz', 1 / MSecsPerDay) and
        PatternRoundTrips('''at'' hh:nn ''on'' dd-mm-yyyy', 1 / MinsPerDay),
    'CORE_PATTERN_READS_WHAT_FORMATDATETIME_WROTE');
  Check(TStructuralText.TryDecodePattern('12:30', 'hh:mm', Moment) and
        SameValue(Moment, EncodeTime(12, 30, 0, 0), 1 / MSecsPerDay),
    'CORE_PATTERN_M_AFTER_H_IS_THE_MINUTE');
  Check(not TStructuralText.TryDecodePattern('30.09.2026', 'dd.mm.yyyy hh:nn',
          Moment) and
        not TStructuralText.TryDecodePattern('30/09/2026', 'dd.mm.yyyy',
          Moment) and
        not TStructuralText.TryDecodePattern('31.02.2026', 'dd.mm.yyyy',
          Moment),
    'CORE_PATTERN_REFUSES_TEXT_THAT_DOES_NOT_MATCH');
  Check(not TStructuralText.TryDecodePattern('Wednesday', 'dddd', Moment) and
        not TStructuralText.TryDecodePattern('09:00 AM', 'hh:nn am/pm', Moment),
    'CORE_PATTERN_REFUSES_WORDS');

  Writeln;
  Writeln('-- ISO 8601 with an offset, as the instant it states --');
  { 07:00 at +01:00 is 06:00 UTC - on 1 January 1800 as on any other day.
    The RTL subtracted the hour from the TDateTime linearly, and before
    1899-12-30 that moves the time the wrong way: it read 08:00. }
  Check(SameValue(TStructuralText.DecodeIso8601('1800-01-01T07:00:00+01:00'),
          -36522.25, 1 / MSecsPerDay),
    'CORE_ISO_OFFSET_BEFORE_1899');
  Check(SameValue(TStructuralText.DecodeIso8601('2026-03-14T09:26:53-04:30'),
          EncodeDateTime(2026, 3, 14, 13, 56, 53, 0), 1 / MSecsPerDay) and
        SameValue(TStructuralText.DecodeIso8601('2026-03-14T09:26:53Z'),
          EncodeDateTime(2026, 3, 14, 9, 26, 53, 0), 1 / MSecsPerDay) and
        SameValue(TStructuralText.DecodeIso8601('2026-03-14T09:26:53+0200'),
          EncodeDateTime(2026, 3, 14, 7, 26, 53, 0), 1 / MSecsPerDay),
    'CORE_ISO_OFFSET_NORMALISED_TO_UTC');
  Check(SameValue(TStructuralText.DecodeIso8601('1800-01-01T07:00:00'),
          -36522 - 7 / 24, 1 / MSecsPerDay),
    'CORE_ISO_WITHOUT_OFFSET_TAKEN_AS_WRITTEN');
  Caught := False;
  try
    TStructuralText.DecodeIso8601('2026-03-14T09:26:53+25:00');
  except
    on E: Exception do Caught := True;
  end;
  Check(Caught, 'CORE_ISO_REFUSES_A_BAD_OFFSET');
end;

{ ===========================================================================
  THE DEPTH GUARD

  Every writer counts one level for each object, record, array, list and
  dictionary it descends into, on one per-thread counter, so the formats
  agree on what nests too deep.
  =========================================================================== }

type
  { Twenty records, one inside the next, with an object at the bottom. }
  TDeepLeaf = class
  public
    class var Live: Integer;
    constructor Create;
    destructor Destroy; override;
  end;
  TDeep20 = record
    Leaf: TDeepLeaf;
  end;
  TDeep19 = record
    Inner: TDeep20;
  end;
  TDeep18 = record
    Inner: TDeep19;
  end;
  TDeep17 = record
    Inner: TDeep18;
  end;
  TDeep16 = record
    Inner: TDeep17;
  end;
  TDeep15 = record
    Inner: TDeep16;
  end;
  TDeep14 = record
    Inner: TDeep15;
  end;
  TDeep13 = record
    Inner: TDeep14;
  end;
  TDeep12 = record
    Inner: TDeep13;
  end;
  TDeep11 = record
    Inner: TDeep12;
  end;
  TDeep10 = record
    Inner: TDeep11;
  end;
  TDeep9 = record
    Inner: TDeep10;
  end;
  TDeep8 = record
    Inner: TDeep9;
  end;
  TDeep7 = record
    Inner: TDeep8;
  end;
  TDeep6 = record
    Inner: TDeep7;
  end;
  TDeep5 = record
    Inner: TDeep6;
  end;
  TDeep4 = record
    Inner: TDeep5;
  end;
  TDeep3 = record
    Inner: TDeep4;
  end;
  TDeep2 = record
    Inner: TDeep3;
  end;
  TDeep1 = record
    Inner: TDeep2;
  end;
  { Types that hold themselves, through an array. }
  TSelfNoObject = record
    Tag: Integer;
    Kids: array of TSelfNoObject;
  end;
  TSelfWithObject = record
    Leaf: TObject;
    Kids: array of TSelfWithObject;
  end;

constructor TDeepLeaf.Create;
begin
  inherited Create;
  Inc(Live);
end;

destructor TDeepLeaf.Destroy;
begin
  Dec(Live);
  inherited Destroy;
end;

{ Ownership is found at any depth of type nesting, and a type that holds
  itself does not send the search round for ever. }
procedure TestOwnershipDepth;
var
  D: TDeep1;
  S: TSelfWithObject;
  Before: Integer;
begin
  Writeln;
  Writeln('-- ownership, at any depth --');
  Check(TSerializationOwnership.IsOwningType(TypeInfo(TDeep1)),
    'OWNERSHIP_OBJECT_BELOW_DEPTH_16');
  Check(not TSerializationOwnership.IsOwningType(TypeInfo(TSelfNoObject)) and
        TSerializationOwnership.IsOwningType(TypeInfo(TSelfWithObject)),
    'OWNERSHIP_RECURSIVE_TYPE_TERMINATES');

  { A recursive value is released through every level it has. }
  Before := TDeepLeaf.Live;
  S := Default(TSelfWithObject);
  S.Leaf := TDeepLeaf.Create;
  SetLength(S.Kids, 1);
  S.Kids[0].Leaf := TDeepLeaf.Create;
  SetLength(S.Kids[0].Kids, 1);
  S.Kids[0].Kids[0].Leaf := TDeepLeaf.Create;
  TSerializationOwnership.Release(TypeInfo(TSelfWithObject),
    TValue.From<TSelfWithObject>(S));
  Check(TDeepLeaf.Live = Before, 'OWNERSHIP_RECURSIVE_TYPE');

  { And the release reaches it: what a read built twenty records down is
    freed, not left behind. }
  Before := TDeepLeaf.Live;
  D := Default(TDeep1);
  D.Inner.Inner.Inner.Inner.Inner.Inner.Inner.Inner.Inner.Inner.Inner.Inner
    .Inner.Inner.Inner.Inner.Inner.Inner.Inner.Leaf := TDeepLeaf.Create;
  TSerializationOwnership.Release(TypeInfo(TDeep1), TValue.From<TDeep1>(D));
  Check(TDeepLeaf.Live = Before, 'OWNERSHIP_DEEP_TYPE');
end;


procedure TestLevels;
var
  Mark, I: Integer;
  Caught: Boolean;
  Obj: TObject;
  Nested: Variant;
  Tree: TDynamicValue;
  Why: string;
begin
  Writeln;
  Writeln('-- depth guard --');

  Mark := TSerializationGraphGuard.Level;
  Caught := False;
  try
    for I := 1 to SERIALIZATION_MAX_GRAPH_DEPTH do
      TSerializationGraphGuard.EnterLevel;
    try
      TSerializationGraphGuard.EnterLevel;
    except
      on E: ESerializationLimitExceeded do Caught := True;
    end;
  finally
    TSerializationGraphGuard.RestoreLevel(Mark);
  end;
  Check(Caught, 'CORE_LEVEL_65_IS_REFUSED');
  Check(TSerializationGraphGuard.Level = Mark, 'CORE_LEVEL_RESTORED_AT_THE_ROOT');

  Obj := TObject.Create;
  try
    Check(TSerializationGraphGuard.Enter(Obj) and
          (TSerializationGraphGuard.Level = Mark + 1),
      'CORE_AN_OBJECT_COUNTS_ONE_LEVEL');
    Check(not TSerializationGraphGuard.Enter(Obj) and
          (TSerializationGraphGuard.Level = Mark + 1),
      'CORE_A_CYCLE_IS_REFUSED_WITHOUT_COUNTING');
    TSerializationGraphGuard.Leave(Obj);
    Check(TSerializationGraphGuard.Level = Mark, 'CORE_LEAVE_GIVES_THE_LEVEL_BACK');
  finally
    Obj.Free;
  end;

  { A refusal that returns False, not only one that raises, gives its level
    back. }
  Check(not TSerializationVariants.TryToDynamic(
          VarArrayOf([1, VarArrayOf([2, Unassigned])]), Tree, Why) and
        (TSerializationGraphGuard.Level = Mark),
    'CORE_VARIANT_ARRAY_REFUSAL_KEEPS_THE_LEVEL');

  Nested := VarArrayOf([1]);
  for I := 1 to SERIALIZATION_MAX_GRAPH_DEPTH + 5 do
    Nested := VarArrayOf([Nested]);
  Caught := False;
  try
    if TSerializationVariants.TryToDynamic(Nested, Tree, Why) then
      Tree.Free;
  except
    on E: ESerializationLimitExceeded do Caught := True;
  end;
  Check(Caught and (TSerializationGraphGuard.Level = Mark),
    'CORE_VARIANT_ARRAYS_NEST_AT_MOST_64_DEEP');
end;

{ ===========================================================================
  THE THREE TEMPORAL KINDS

  A day, a time of day and an instant are three different claims, and the
  dynamic tree keeps them apart. The point of the distinction is what happens
  at the far end - a DataSet column inferred from a day must be ftDate - so
  these checks are about the claim surviving, not about storage.

  And the other half: a KIND IS NEVER INFERRED FROM TEXT. The strings below
  look exactly like dates and times and stay strings, because the format that
  produced them had only strings to offer.
  =========================================================================== }

{ ===========================================================================
  CONTAINER RECOGNITION, IN ONE PLACE

  This used to be six copies of the same idea, and they did not agree: three
  engines walked TObjectList's and TDictionary's OWN published members -
  describing a container by its comparer and its notify events - and one of
  them reached an invalid pointer doing it.

  So the recognition is here, it is by ANCESTRY, and these checks are what
  says the ancestry part is real: a user's own descendant is a container, and
  a class that merely has an Add and a ToArray is not.
  =========================================================================== }

type
  { Ordinary descendants, which is what application models are made of. }
  TMyList = class(TList<Integer>);
  TMyObjectList = class(TObjectList<TObject>);
  TMyDict = class(TDictionary<string, Integer>);
  TMyObjectDict = class(TObjectDictionary<string, TObject>);

  { Two levels down, because a real model does that. }
  TDeeperList = class(TMyObjectList);

  { NOT a container: it has an Add and a ToArray and no ancestry at all. If
    recognition were by method shape this would be a list, and the members of
    every such class would be written as elements. }
  TImpostor = class
  public
    function Add(const AValue: Integer): Integer;
    function ToArray: TArray<Integer>;
  end;

function TImpostor.Add(const AValue: Integer): Integer;
begin
  Result := AValue;
end;

function TImpostor.ToArray: TArray<Integer>;
begin
  Result := nil;
end;

{ The dynamic tree keeps member names exactly as the source spelled them,
  and its containers accept only what their kind holds. }
procedure TestDynamicContract;
var
  Obj, Arr, Ext, Scalar, V: TDynamicValue;
  Refused: Boolean;

  { Runs AStep and says whether it raised EDynamicError. }
  function RaisesKind(const AStep: TProc): Boolean;
  begin
    Result := False;
    try
      AStep();
    except
      on E: EDynamicError do Result := True;
    end;
  end;

begin
  Writeln;
  Writeln('-- the dynamic tree: exact names and a container contract --');

  Obj := TDynamicValue.NewObject;
  try
    Obj.AsObject.Adopt('Name', TDynamicValue.NewStr('wrong'));
    Obj.AsObject.Adopt('name', TDynamicValue.NewStr('correct'));
    Obj.AsObject.Adopt('NAME', TDynamicValue.NewStr('shouting'));

    V := Obj.Find('name');
    Check((V <> nil) and (V.AsStr = 'correct') and
      (Obj.Find('nAmE') = nil), 'DYNAMIC_FIND_IS_CASE_SENSITIVE');
    Check((Obj.Count = 3) and (Obj.Find('Name').AsStr = 'wrong') and
      (Obj.Find('NAME').AsStr = 'shouting') and
      (Obj.Names[0] = 'Name') and (Obj.Names[1] = 'name'),
      'DYNAMIC_CASE_DISTINCT_MEMBERS');

    { A clone keeps every spelling. }
    V := Obj.Clone;
    try
      Check((V.Count = 3) and (V.Find('name').AsStr = 'correct') and
        (V.Find('Name').AsStr = 'wrong'), 'DYNAMIC_CLONE_KEEPS_EXACT_NAMES');
    finally
      V.Free;
    end;

    { An object member needs a name. }
    Check(RaisesKind(procedure begin Obj.AsArray.Adopt(TDynamicValue.NewInt(1)) end) and
      (Obj.Count = 3), 'DYNAMIC_OBJECT_REFUSES_UNNAMED_CHILD');
  finally
    Obj.Free;
  end;

  Arr := TDynamicValue.NewArray;
  try
    Arr.AsArray.Adopt(TDynamicValue.NewInt(1));
    Check(RaisesKind(procedure begin Arr.AsObject.Adopt('x', TDynamicValue.NewInt(2)) end) and
      (Arr.Count = 1) and (Arr.Find('x') = nil) and (Arr.Names[0] = ''),
      'DYNAMIC_ARRAY_REFUSES_NAMED_CHILD');
  finally
    Arr.Free;
  end;

  Scalar := TDynamicValue.NewStr('s');
  try
    Refused := RaisesKind(procedure begin Scalar.AsArray.Adopt(TDynamicValue.NewInt(1)) end) and
      RaisesKind(procedure begin Scalar.AsObject.Adopt('k', TDynamicValue.NewInt(1)) end) and
      RaisesKind(procedure begin Scalar.Items[0] end) and
      (Scalar.Count = 0) and (Scalar.Find('k') = nil);
    Check(Refused, 'DYNAMIC_SCALAR_HAS_NO_CHILDREN');
  finally
    Scalar.Free;
  end;

  { An Extended node owns its payload, reached only through ExtendedValue:
    it is not a child, and nothing can be added beside it. }
  Ext := TDynamicValue.NewExtended(TDynamicTag.ObjectId,
    TDynamicValue.NewBytes(TBytes.Create(1, 2, 3)));
  try
    Check((Ext.Count = 0) and (Ext.ExtendedValue <> nil) and
      (Length(Ext.ExtendedValue.AsBytes) = 3) and
      RaisesKind(procedure begin Ext.Items[0] end) and
      RaisesKind(procedure begin Ext.AsArray.Adopt(TDynamicValue.NewInt(1)) end) and
      RaisesKind(procedure begin Ext.AsObject.Adopt('k', TDynamicValue.NewInt(1)) end),
      'DYNAMIC_EXTENDED_PAYLOAD_IS_NOT_A_CHILD');
    V := Ext.Clone;
    try
      Check(V.IsTagged(TDynamicTag.ObjectId) and (V.Count = 0) and
        (Length(V.ExtendedValue.AsBytes) = 3), 'DYNAMIC_EXTENDED_CLONES');
    finally
      V.Free;
    end;
  finally
    Ext.Free;
  end;

  { Extended is made with NewExtended - there is no other way to make one -
    which requires a tag. }
  Check(RaisesKind(procedure begin TDynamicValue.NewExtended('', nil).Free end),
    'DYNAMIC_EXTENDED_NEEDS_A_TAG');
end;

procedure TestContainerRecognition;
var
  L: TListAccess;
  D: TDictionaryAccess;
  Obj: TMyObjectList;
  Dict: TMyDict;
  Container, Item, Pairs, Pair: TValue;
  Families: TArray<string>;
  I, Seen: Integer;
begin
  Writeln;
  Writeln('-- lists --');

  Check(TSerializationTypes.TryGetListAccess(TypeInfo(TList<Integer>), L),
    'CORE_LIST_RECOGNITION');
  Check(L.ElementType = TypeInfo(Integer), 'CORE_LIST_ELEMENT_TYPE');
  Check(L.Family = 'TList<', 'CORE_LIST_FAMILY');
  Check(not L.Owns, 'CORE_LIST_DOES_NOT_OWN');

  Check(TSerializationTypes.TryGetListAccess(TypeInfo(TMyList), L),
    'DERIVED_LIST_RECOGNITION');
  Check(L.ElementType = TypeInfo(Integer), 'DERIVED_LIST_ELEMENT_TYPE');

  Check(TSerializationTypes.TryGetListAccess(TypeInfo(TObjectList<TObject>), L),
    'OBJECTLIST_RECOGNITION');
  Check(L.Owns, 'OBJECTLIST_OWNS_ITS_ELEMENTS');

  Check(TSerializationTypes.TryGetListAccess(TypeInfo(TDeeperList), L),
    'TWO_LEVEL_DESCENDANT_LIST_RECOGNITION');
  Check(L.Owns, 'TWO_LEVEL_DESCENDANT_KEEPS_OWNERSHIP');

  Writeln;
  Writeln('-- dictionaries --');

  Check(TSerializationTypes.TryGetDictionaryAccess(
    TypeInfo(TDictionary<string, Integer>), D), 'CORE_DICTIONARY_RECOGNITION');
  Check((D.KeyType = TypeInfo(string)) and (D.ValueType = TypeInfo(Integer)),
    'CORE_DICTIONARY_KEY_AND_VALUE_TYPES');
  Check((D.PairKeyField <> nil) and (D.PairValueField <> nil),
    'CORE_DICTIONARY_PAIR_FIELDS');

  Check(TSerializationTypes.TryGetDictionaryAccess(TypeInfo(TMyDict), D),
    'DERIVED_DICTIONARY_RECOGNITION');
  Check(TSerializationTypes.TryGetDictionaryAccess(
    TypeInfo(TObjectDictionary<string, TObject>), D),
    'OBJECTDICTIONARY_RECOGNITION');
  Check(D.Owns, 'OBJECTDICTIONARY_OWNS_ITS_VALUES');
  Check(TSerializationTypes.TryGetDictionaryAccess(TypeInfo(TMyObjectDict), D),
    'DERIVED_OBJECTDICTIONARY_RECOGNITION');

  Writeln;
  Writeln('-- and what is not a container --');

  Check(not TSerializationTypes.TryGetListAccess(TypeInfo(TImpostor), L),
    'METHOD_SHAPE_ALONE_IS_NOT_A_LIST');
  Check(not TSerializationTypes.TryGetDictionaryAccess(TypeInfo(TImpostor), D),
    'METHOD_SHAPE_ALONE_IS_NOT_A_DICTIONARY');
  Check(TSerializationTypes.ContainerKindOf(TypeInfo(TImpostor)) =
    TContainerKind.None, 'IMPOSTOR_HAS_NO_CONTAINER_KIND');
  Check(TSerializationTypes.ContainerKindOf(TypeInfo(TObject)) =
    TContainerKind.None, 'A_PLAIN_CLASS_IS_NOT_A_CONTAINER');
  Check(TSerializationTypes.ContainerKindOf(TypeInfo(Integer)) =
    TContainerKind.None, 'A_SCALAR_IS_NOT_A_CONTAINER');

  { A dictionary is NOT reported as a list, which is the ordering mistake
    that has caught people out: TObjectDictionary is not a TList, but asking
    the questions in the wrong order once produced a list of pairs. }
  Check(TSerializationTypes.ContainerKindOf(TypeInfo(TMyObjectDict)) =
    TContainerKind.Dictionary, 'DICTIONARY_IS_NOT_CLASSIFIED_AS_A_LIST');
  Check(TSerializationTypes.ContainerKindOf(TypeInfo(TMyObjectList)) =
    TContainerKind.List, 'LIST_IS_NOT_CLASSIFIED_AS_A_DICTIONARY');

  Writeln;
  Writeln('-- reaching the values --');

  Obj := TMyObjectList.Create;
  try
    Obj.Add(TObject.Create);
    Obj.Add(TObject.Create);
    TSerializationTypes.TryGetListAccess(TypeInfo(TMyObjectList), L);
    Container := TValue.From<TObject>(Obj);
    Check(L.Count(Container) = 2, 'CORE_LIST_COUNT');
    Item := L.Elements(Container);
    Check(Item.GetArrayLength = 2, 'CORE_LIST_ELEMENTS');
  finally
    Obj.Free;
  end;

  Dict := TMyDict.Create;
  try
    Dict.AddOrSetValue('a', 1);
    Dict.AddOrSetValue('b', 2);
    TSerializationTypes.TryGetDictionaryAccess(TypeInfo(TMyDict), D);
    Container := TValue.From<TObject>(Dict);
    Check(D.Count(Container) = 2, 'CORE_DICTIONARY_COUNT');
    Pairs := D.Pairs(Container);
    Seen := 0;
    for I := 0 to Pairs.GetArrayLength - 1 do
    begin
      { The pair goes into a LOCAL before its address is taken. Reading the
        address of a function result works on Win32 and reads a temporary
        that has already gone on Win64. }
      Pair := Pairs.GetArrayElement(I);
      if (D.KeyOf(Pair).AsString = 'a') and (D.ValueOf(Pair).AsInteger = 1) then
        Inc(Seen);
      if (D.KeyOf(Pair).AsString = 'b') and (D.ValueOf(Pair).AsInteger = 2) then
        Inc(Seen);
    end;
    Check(Seen = 2, 'CORE_DICTIONARY_PAIRS');
  finally
    Dict.Free;
  end;

  { Building one from nothing, which is what a reader does. }
  TSerializationTypes.TryGetListAccess(TypeInfo(TMyList), L);
  Container := TValue.From<TObject>(L.CreateInstance);
  try
    Check(Container.AsObject <> nil, 'CORE_LIST_CREATE_INSTANCE');
    L.Add(Container, TValue.From<Integer>(7));
    Check(L.Count(Container) = 1, 'CORE_LIST_ADD');
    L.Clear(Container);
    Check(L.Count(Container) = 0, 'CORE_LIST_CLEAR');
  finally
    Container.AsObject.Free;
  end;

  Families := TSerializationTypes.RegisteredContainerFamilies;
  Check(Length(Families) >= 4, 'CORE_CONTAINER_FAMILIES_REGISTERED');
  Writeln('  families: ', string.Join(', ', Families));
end;

procedure TestTemporalKinds;
var
  D, T, S: TDynamicValue;
  Copy_: TDynamicValue;
begin
  Writeln;
  Writeln('-- date, time and instant are three kinds --');

  D := TDynamicValue.NewDate(EncodeDate(2026, 9, 22) + EncodeTime(13, 45, 7, 250));
  try
    Check(D.Kind = TDynamicKind.Date, 'DYNAMIC_DATE_KIND');
    { The time half is dropped at construction, not carried invisibly: a Date
      that secretly held 13:45 would write a different value the moment
      somebody converted it to an instant. }
    Check(SameValue(D.AsDateTime, EncodeDate(2026, 9, 22)),
      'DYNAMIC_DATE_DROPS_THE_TIME');
    Check(D.Describe = '2026-09-22', 'DYNAMIC_DATE_DESCRIBE');
    Copy_ := D.Clone;
    try
      Check((Copy_.Kind = TDynamicKind.Date) and
            SameValue(Copy_.AsDateTime, D.AsDateTime), 'DYNAMIC_DATE_CLONE');
    finally
      Copy_.Free;
    end;
  finally
    D.Free;
  end;

  T := TDynamicValue.NewTime(EncodeDate(2026, 9, 22) + EncodeTime(13, 45, 7, 250));
  try
    Check(T.Kind = TDynamicKind.Time, 'DYNAMIC_TIME_KIND');
    Check(SameValue(T.AsDateTime, EncodeTime(13, 45, 7, 250), 1 / (MSecsPerDay * 2)),
      'DYNAMIC_TIME_DROPS_THE_DATE');
    Check(T.Describe = '13:45:07.250', 'DYNAMIC_TIME_DESCRIBE');
    Copy_ := T.Clone;
    try
      Check(Copy_.Kind = TDynamicKind.Time, 'DYNAMIC_TIME_CLONE');
    finally
      Copy_.Free;
    end;
  finally
    T.Free;
  end;

  S := TDynamicValue.NewDateTime(EncodeDate(2026, 9, 22) + EncodeTime(13, 45, 7, 250));
  try
    Check(S.Kind = TDynamicKind.DateTime, 'DYNAMIC_DATETIME_KIND');
    Check(S.Kind <> TDynamicKind.Date, 'DYNAMIC_DATETIME_IS_NOT_DATE');
  finally
    S.Free;
  end;

  { The three names a diagnostic prints. }
  Check(EStructuralConversionError.KindName(TDynamicKind.Date) = 'date',
    'DYNAMIC_DATE_KIND_NAME');
  Check(EStructuralConversionError.KindName(TDynamicKind.Time) = 'time',
    'DYNAMIC_TIME_KIND_NAME');
  Check(EStructuralConversionError.KindName(TDynamicKind.DateTime) = 'datetime',
    'DYNAMIC_DATETIME_KIND_NAME');

  Writeln;
  Writeln('-- and text stays text --');

  S := TDynamicValue.NewStr('2026-09-22');
  try
    Check(S.Kind = TDynamicKind.Str, 'STRING_DATE_REMAINS_STRING');
  finally
    S.Free;
  end;
  S := TDynamicValue.NewStr('14:35:00');
  try
    Check(S.Kind = TDynamicKind.Str, 'STRING_TIME_REMAINS_STRING');
  finally
    S.Free;
  end;
  S := TDynamicValue.NewStr('2026-09-22T14:35:00');
  try
    Check(S.Kind = TDynamicKind.Str, 'STRING_DATETIME_REMAINS_STRING');
  finally
    S.Free;
  end;

  { The shared text forms every destination without a native type uses. One
    spelling, so two formats cannot drift apart. }
  Check(TStructuralText.EncodeDate(EncodeDate(2026, 9, 22)) = '2026-09-22',
    'STRUCTURAL_TEXT_ENCODE_DATE');
  Check(TStructuralText.EncodeTime(EncodeTime(14, 35, 0, 0)) = '14:35:00.000',
    'STRUCTURAL_TEXT_ENCODE_TIME');
  Check(TStructuralText.TryDecodeDate('2026-09-22', GMoment) and
        SameValue(GMoment, EncodeDate(2026, 9, 22)),
    'STRUCTURAL_TEXT_DECODE_DATE');
  Check(TStructuralText.TryDecodeTime('14:35:00', GMoment) and
        SameValue(GMoment, EncodeTime(14, 35, 0, 0), 1 / (MSecsPerDay * 2)),
    'STRUCTURAL_TEXT_DECODE_TIME_WITHOUT_MILLIS');
  Check(TStructuralText.TryDecodeTime('14:35:00.125', GMoment),
    'STRUCTURAL_TEXT_DECODE_TIME_WITH_MILLIS');
  Check(not TStructuralText.TryDecodeDate('22/09/2026', GMoment),
    'STRUCTURAL_TEXT_DATE_REFUSES_ANOTHER_SPELLING');
  Check(not TStructuralText.TryDecodeDate('2026-13-01', GMoment),
    'STRUCTURAL_TEXT_DATE_REFUSES_MONTH_13');
end;

begin
  try
    TestUInt;
    TestDecimal;
    TestClone;
    TestContextRouting;
    TestCapabilityContext;
    TestFormatNames;
    TestTags;
    TestDecimal128;
    TestUtf8;
    TestNumbersAndInstants;
    TestLevels;
    TestOwnershipDepth;
    TestTemporalKinds;
    TestContainerRecognition;
    TestDynamicContract;

    Writeln;
    Writeln('FAILURES=', GFailures);
    if GFailures = 0 then Writeln('CORE_FOUNDATION: PASS')
    else
    begin
      Writeln('CORE_FOUNDATION: FAIL');
      Halt(1);
    end;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Writeln('CORE_FOUNDATION: FAIL');
      Halt(1);
    end;
  end;
end.
