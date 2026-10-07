{*******************************************************************************
  PascalForge.Protobuf.Internal

  INTERNAL IMPLEMENTATION UNIT - applications should not use this unit directly.

  Implements the Protocol Buffers engine: wire codec, field plans and the
  direct value/bytes engine.
  Exposed through the public facade PascalForge.Protobuf (TProtobufSerializer).

  Registration
    Format registration lives in PascalForge.Protobuf.Registration and is
    explicit.

  Documentation
    docs/formats/protobuf.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Protobuf.Internal;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  The Protocol Buffers engine.

  Not public API. Use TProtobufSerializer.

  Three parts, in the order they appear below:

    1. the wire codec   - varints, tags, lengths, the six wire types
    2. the plans        - a Delphi type -> a field table, built once
    3. the engine       - a Delphi value <-> bytes, straight through

  THERE IS NO INTERMEDIATE TREE. A value is written directly into the byte
  buffer and read directly into the instance. Protobuf has no names to look
  up and no document structure to walk, so a DOM would be pure overhead;
  the reader sees a field number, finds its plan in an array indexed by
  number, and reads into the member.

  The engine talks to protobuf and to Delphi and to nothing else. It has no
  reference to PascalForge.Json, .Xml or .Bson: the only way another format
  enters this unit is through the registry in
  PascalForge.Serialization.Core, by TSerializationFormat, at run time.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.SyncObjs, System.DateUtils, System.Math,
  System.Generics.Collections,
  PascalForge.Serialization.Core,
  PascalForge.Serialization.Internal,
  PascalForge.Protobuf;

const
  { The specification's limits on a field number. 19000..19999 are reserved
    for the implementation's own use and a .proto file may not use them. }
  PROTO_MIN_FIELD = 1;
  PROTO_MAX_FIELD = 536870911;      { 2^29 - 1 }
  PROTO_RESERVED_LO = 19000;
  PROTO_RESERVED_HI = 19999;

  { A varint is at most ten bytes: 64 bits at seven bits each. }
  PROTO_MAX_VARINT_BYTES = 10;

  { Messages nest, and the reader is recursive. Deeper than this is not a
    message anyone generated. }
  PROTO_MAX_DEPTH = 100;

type
  { ------------------------------------------------------------------------
    1. THE WIRE CODEC
    ------------------------------------------------------------------------ }

  TProtoReader = record
  public
    FData: TBytes;
    FPos: Integer;
    FEnd: Integer;
    procedure Init(const AData: TBytes; AStart, AEnd: Integer);
    { Init over the whole of AData, refusing a buffer past 2 GiB, which the
      Integer positions here cannot address. }
    procedure InitWhole(const AData: TBytes);
    procedure Fail(const AMessage: string);
    function AtEnd: Boolean; inline;
    procedure Need(ACount: Integer);
    function ReadByte: Byte;
    function ReadVarint: UInt64;
    function ReadInt32: Integer;
    function ReadFixed32: UInt32;
    function ReadFixed64: UInt64;
    function ReadLengthDelimited: TBytes;
    { The bounds of the next length-delimited payload, without copying it. }
    procedure ReadLengthBounds(out AStart, AStop: Integer);
    { Reads a tag. False at the end of the current region. }
    function ReadTag(out AFieldNumber: Integer;
      out AWireType: TProtoWireType): Boolean;
    { Skips the payload of a field whose number the schema does not know,
      and returns the bytes of the whole field - tag included - so that a
      message with somewhere to keep them can. }
    function SkipField(ATagStart: Integer; AFieldNumber: Integer;
      AWireType: TProtoWireType; ADepth: Integer): TBytes;
  end;

  TProtoWriter = record
  public
    FData: TBytes;
    FPos: Integer;
    procedure Init;
    procedure Ensure(ACount: Integer);
    procedure PutByte(AValue: Byte);
    procedure PutRaw(const AValue: TBytes);
    procedure PutVarint(AValue: UInt64);
    procedure PutFixed32(AValue: UInt32);
    procedure PutFixed64(AValue: UInt64);
    procedure PutTag(AFieldNumber: Integer; AWireType: TProtoWireType);
    procedure PutLengthDelimited(const AValue: TBytes);
    { Reserves room for a length that is only known once the body is
      written, and patches it afterwards. }
    function BeginSubMessage: Integer;
    procedure EndSubMessage(AMark: Integer);
    function Done: TBytes;
  end;

{ Zig-zag, the reason sint32 and sint64 exist: it maps small negative
  numbers to small unsigned ones, so -1 costs one byte instead of ten. }
function ZigZagEncode32(AValue: Integer): UInt32; inline;
function ZigZagDecode32(AValue: UInt32): Integer; inline;
function ZigZagEncode64(AValue: Int64): UInt64; inline;
function ZigZagDecode64(AValue: UInt64): Int64; inline;

{ True when ADouble is a finite value -2^63 <= ADouble < 2^63, so Trunc of it
  is an Int64. Integrality is the caller's own rule. }
function ProtoDoubleInInt64Range(ADouble: Double): Boolean;

type
  { ------------------------------------------------------------------------
    2. THE PLANS
    ------------------------------------------------------------------------ }

  TProtoMemberKind = (
    Unsupported,
    BoolValue, IntValue, Int64Value, FloatValue, CurrencyValue, StrValue,
    DateValue, TimeValue, DateTimeValue, GuidValue, BytesValue,
    EnumValue, SetValue, NullableValue,
    MessageValue, RecordValue,
    ListValue, DictionaryValue, ArrayValue,
    CustomSerializer);

  TProtoTypePlan = class;

  TProtoMemberPlan = class
  public
    TypeInfo: PTypeInfo;
    Kind: TProtoMemberKind;
    { The .proto scalar this member is written as, after [ProtoType] and the
      Auto rules. }
    Scalar: TProtoScalar;

    NullableAccess: TNullableAccess;
    Inner: TProtoMemberPlan;         { owned }

    EnumNumbers: TArray<Integer>;
    SetElemTypeInfo: PTypeInfo;
    SetElemNumbers: TArray<Integer>;

    BoundPlan: TProtoTypePlan;       { BORROWED - it lives in the plan cache }

    Item: TProtoMemberPlan;          { owned }
    Key: TProtoMemberPlan;           { owned }
    Value: TProtoMemberPlan;         { owned }
    ContainerAdd: TRttiMethod;
    ContainerClear: TRttiMethod;
    ContainerToArray: TRttiMethod;
    ContainerCreate: TRttiMethod;
    PairKeyField: TRttiField;
    PairValueField: TRttiField;
    { Core's description of a dictionary, for the reader's adds: a repeated
      key must release what the read built for the earlier one. }
    DictAccess: TDictionaryAccess;
    HasDictAccess: Boolean;

    Serializer: TCustomProtoValueSerializerBase;   { BORROWED singleton }

    destructor Destroy; override;
    function IsContainer: Boolean;
    { True when this member's values are numeric and may therefore be
      written packed. }
    function IsPackable: Boolean;
  end;

  TProtoFieldPlan = class
  public
    Member: TProtoMemberPlan;        { owned }
    Field: TRttiField;               { exactly one of these two is set }
    Prop: TRttiProperty;
    DelphiName: string;
    Number: Integer;
    Packed_: Boolean;
    OneOf: string;
    Writable: Boolean;
    IsUnknownStore: Boolean;
    destructor Destroy; override;
  end;

  TProtoTypePlan = class
  public
    TypeInfo: PTypeInfo;
    RttiType: TRttiType;
    ClassType: TClass;
    IsRecord: Boolean;
    TypeKey: string;
    UnitName: string;
    Fields: TObjectList<TProtoFieldPlan>;
    { Field number -> index into Fields. A dictionary rather than an array
      because field numbers are sparse and may reach 2^29. }
    ByNumber: TDictionary<Integer, Integer>;
    { oneof name -> the field numbers in it. }
    OneOfs: TObjectDictionary<string, TList<Integer>>;
    UnknownStore: TProtoFieldPlan;   { BORROWED from Fields, or nil }
    ZeroConstructor: TRttiMethod;
    constructor Create;
    destructor Destroy; override;
  end;

  { ------------------------------------------------------------------------
    3. THE ENGINE
    ------------------------------------------------------------------------ }

  TProtoEngine = class
  strict private
    class var FCtx: TRttiContext;
    class var FLock: TCriticalSection;
    class var FPlans: TObjectDictionary<PTypeInfo, TProtoTypePlan>;
    class var FRootPlans: TObjectDictionary<PTypeInfo, TProtoMemberPlan>;
    class var FEnumNumbers: TDictionary<PTypeInfo, TArray<Integer>>;
    class var FTypeSerializers: TDictionary<PTypeInfo, TProtoValueSerializerClass>;
    class var FSerializerSingletons: TObjectDictionary<TClass, TCustomProtoValueSerializerBase>;
    class var FFrozen: Boolean;
    class var FBuildTrail: TList<PTypeInfo>;
    class var FBuildDepth: Integer;

    class procedure CheckNotFrozen; static;
    class procedure RollbackBuildTrail; static;
    class function ResolveSerializer(
      AClass: TProtoValueSerializerClass): TCustomProtoValueSerializerBase; static;
    class function EnumNumbersFor(ATypeInfo: PTypeInfo): TArray<Integer>; static;

    class function ClassifyType(ATypeInfo: PTypeInfo): TProtoMemberKind; static;
    class function DefaultScalar(AKind: TProtoMemberKind;
      ATypeInfo: PTypeInfo): TProtoScalar; static;
    class function GetPlan(ATypeInfo: PTypeInfo): TProtoTypePlan; static;
    class function BuildPlan(ATypeInfo: PTypeInfo): TProtoTypePlan; static;
    class procedure BuildMemberOfType(APlan: TProtoTypePlan;
      AField: TRttiField; AProp: TRttiProperty); static;
    class function BuildMemberPlan(ATypeInfo: PTypeInfo;
      const AOwnerKey, AMemberName: string): TProtoMemberPlan; static;
    class function GetRootPlan(ATypeInfo: PTypeInfo): TProtoMemberPlan; static;

    class function NewInstanceOf(APlan: TProtoTypePlan): TObject; static;
    class function NewContainer(APlan: TProtoMemberPlan): TObject; static;
    class function ReadMember(AFP: TProtoFieldPlan;
      AInstance: Pointer): TValue; static;
    class procedure StoreMember(AFP: TProtoFieldPlan; AInstance: Pointer;
      const AValue: TValue); static;

    { The member plan a field is written or read with, after an external
      descriptor has had its say. Usually AFP.Member itself, in which case
      AOwned comes back nil and there is nothing to free; when the
      descriptor disagrees about the wire form, a throwaway plan carrying
      the descriptor's scalar, which the caller frees. }
    class function SchemaMember(AFP: TProtoFieldPlan; AIsRoot: Boolean;
      ASchema: TProtobufDescriptorSchema;
      out AOwned: TProtoMemberPlan): TProtoMemberPlan; static;
    class function CollectRootUnknown(APlan: TProtoTypePlan;
      const AData: TBytes): TBytes; static;

    { --- writing ---------------------------------------------------------- }
    class procedure WriteMessageBody(APlan: TProtoTypePlan; AInstance: Pointer;
      var AWriter: TProtoWriter;
      const AOptions: TProtobufSerializationOptions;
      AIsRoot: Boolean); static;
    class procedure WriteField(AFP: TProtoFieldPlan; const AValue: TValue;
      var AWriter: TProtoWriter;
      const AOptions: TProtobufSerializationOptions;
      AIsRoot: Boolean); static;
    class procedure WriteSingle(APlan: TProtoMemberPlan; ANumber: Integer;
      const AValue: TValue; var AWriter: TProtoWriter;
      const AOptions: TProtobufSerializationOptions); static;
    class procedure WriteScalarPayload(APlan: TProtoMemberPlan;
      const AValue: TValue; var AWriter: TProtoWriter); static;
    class function WireTypeOf(APlan: TProtoMemberPlan): TProtoWireType; static;
    class procedure RequireWireType(APlan: TProtoMemberPlan;
      AWireType: TProtoWireType; AFieldNumber: Integer); static;
    class function IsDefaultValue(APlan: TProtoMemberPlan;
      const AValue: TValue): Boolean; static;

    { --- reading ---------------------------------------------------------- }
    class procedure ReadMessageBody(APlan: TProtoTypePlan; AInstance: Pointer;
      var AReader: TProtoReader; ADepth: Integer); static;
    class function ReadScalar(APlan: TProtoMemberPlan;
      AWireType: TProtoWireType; var AReader: TProtoReader;
      const AExisting: TValue; ADepth: Integer): TValue; static;
    class procedure CollectStatic(AFP: TProtoFieldPlan; AIndex: Integer;
      AWireType: TProtoWireType; var AReader: TProtoReader; ADepth: Integer;
      AStatics: TObjectDictionary<Integer, TList<TValue>>); static;
    class procedure ReadRepeated(AFP: TProtoFieldPlan; AInstance: Pointer;
      AWireType: TProtoWireType; var AReader: TProtoReader;
      ADepth: Integer); static;
    class procedure ReadMapEntry(AFP: TProtoFieldPlan; AInstance: Pointer;
      var AReader: TProtoReader; ADepth: Integer); static;
    class procedure ClearOneOfSiblings(APlan: TProtoTypePlan;
      AInstance: Pointer; ANumber: Integer); static;
  public
    class constructor Create;
    class destructor Destroy;

    class function SerializeRoot(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AOptions: TProtobufSerializationOptions): TBytes; static;
    class function DeserializeRoot(ATypeInfo: PTypeInfo; const AData: TBytes;
      const AExisting: TValue): TValue; overload; static;
    class function DeserializeRoot(ATypeInfo: PTypeInfo; const AData: TBytes;
      const AExisting: TValue;
      const AOptions: TProtobufSerializationOptions): TValue; overload; static;

    { --- the unknown-field envelope --- }
    class function DeserializeRootKeepingUnknown(ATypeInfo: PTypeInfo;
      const AData: TBytes; const AOptions: TProtobufSerializationOptions;
      out AUnknown: TBytes): TValue; static;
    class function SerializeRootWithUnknown(ATypeInfo: PTypeInfo;
      const AValue: TValue; const AUnknown: TBytes;
      const AOptions: TProtobufSerializationOptions): TBytes; static;

    { --- cross-format, reached only through the registry --- }
    class function FromPayload(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; static;

    { --- configuration --- }
    class procedure RegisterEnumNumbers(ATypeInfo: PTypeInfo;
      const ANumbers: array of Integer); static;
    class procedure RegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TProtoValueSerializerClass); static;
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;
    class procedure ResetConfiguration; static;
    class function PlanCount: Integer; static;
  end;

implementation

uses
  PascalForge.Nullable;

{ The descriptor in force for the root message of the read now running, or
  nil.

  Writing carries its options down the call chain already, so it needs no
  such thing; reading does not, and threading an options record through
  ReadMessageBody, ReadScalar, ReadRepeated and ReadMapEntry to reach one
  decision taken at depth zero would be a wide change for a narrow need. A
  threadvar rather than a class var because two threads may deserialize two
  different messages at once, and the engine is otherwise reentrant. }
threadvar
  GReadSchema: TProtobufDescriptorSchema;

{ ===========================================================================
  1. THE WIRE CODEC
  =========================================================================== }

{ THE TEXTBOOK FORM OF ZIG-ZAG IS (n shl 1) xor (n shr 31), and it is wrong
  in Delphi: shr on a signed integer is a LOGICAL shift here, not an
  arithmetic one, so -1 shr 31 is 1 rather than -1 and the whole encoding
  comes out wrong for every negative number.

  So it is written out. Negating through (AValue + 1) rather than directly
  keeps Low(Integer) and Low(Int64) in range - -Low(Int64) does not exist. }

function ZigZagEncode32(AValue: Integer): UInt32;
begin
  if AValue < 0 then Result := (UInt32(-(AValue + 1)) shl 1) or 1
  else Result := UInt32(AValue) shl 1;
end;

function ZigZagDecode32(AValue: UInt32): Integer;
begin
  if (AValue and 1) <> 0 then Result := -Integer(AValue shr 1) - 1
  else Result := Integer(AValue shr 1);
end;

function ZigZagEncode64(AValue: Int64): UInt64;
begin
  if AValue < 0 then Result := (UInt64(-(AValue + 1)) shl 1) or 1
  else Result := UInt64(AValue) shl 1;
end;

function ZigZagDecode64(AValue: UInt64): Int64;
begin
  if (AValue and 1) <> 0 then Result := -Int64(AValue shr 1) - 1
  else Result := Int64(AValue shr 1);
end;

const
  { -2^63 and 2^63, both exactly a Double, typed as Double so Win32 (which
    compares at Extended precision) compares the very values Win64 does.
    High(Int64) is not a Double. }
  PROTO_INT64_LOW_AS_DOUBLE: Double = -9223372036854775808.0;
  PROTO_INT64_END_AS_DOUBLE: Double = 9223372036854775808.0;

function ProtoDoubleInInt64Range(ADouble: Double): Boolean;
begin
  Result := not ADouble.IsNan and (ADouble >= PROTO_INT64_LOW_AS_DOUBLE) and
    (ADouble < PROTO_INT64_END_AS_DOUBLE);
end;

{ A length the writer indexes with as an Integer. Length is NativeInt on
  Win64, so 2 GiB or more wrapped to a negative count; it is refused. }
function ProtoWriterCount(ALength: NativeInt): Integer;
begin
  if Int64(ALength) > MaxInt then
    raise EProtobufInternalError.CreateFmt(
      'A value of %d bytes is too large to write; protobuf messages are at ' +
      'most 2 GiB.', [Int64(ALength)]);
  Result := Integer(ALength);
end;

{ ISO 8601 by position rather than by locale. StrToDate would read
  "2026-03-14" through whatever the machine's short date format happens to
  be, which is how the same document parses differently in two countries. }

{ protobuf says a string field is UTF-8, so bytes that are not are a
  malformed document rather than something to guess at - and a caller who
  asked protobuf to read something should not have to catch somebody else's
  exception class to find out it could not. }
function ProtoUtf8Text(const ARaw: TBytes): string;
begin
  try
    Result := Utf8BytesToString(ARaw);
  except
    on E: EInvalidUtf8 do
      raise EProtobufInputError.CreateFmt(
        'A protobuf string field is UTF-8 by specification, and these ' +
        'bytes are not. %s', [E.Message]);
  end;
end;

{ The .proto spelling of a scalar, for messages. }
function ProtoScalarName(AScalar: TProtoScalar): string;
begin
  case AScalar of
    TProtoScalar.Int32: Result := 'int32';
    TProtoScalar.Int64: Result := 'int64';
    TProtoScalar.UInt32: Result := 'uint32';
    TProtoScalar.UInt64: Result := 'uint64';
    TProtoScalar.SInt32: Result := 'sint32';
    TProtoScalar.SInt64: Result := 'sint64';
    TProtoScalar.Fixed32: Result := 'fixed32';
    TProtoScalar.Fixed64: Result := 'fixed64';
    TProtoScalar.SFixed32: Result := 'sfixed32';
    TProtoScalar.SFixed64: Result := 'sfixed64';
    TProtoScalar.Float: Result := 'float';
    TProtoScalar.Double: Result := 'double';
    TProtoScalar.Bool: Result := 'bool';
    TProtoScalar.Text: Result := 'string';
    TProtoScalar.Bytes: Result := 'bytes';
    TProtoScalar.EnumValue: Result := 'enum';
  else
    Result := 'its default';
  end;
end;

{ Whether a member of this kind can be WRITTEN as this scalar: the wire type
  in the tag and the payload after it both come from the answer, and an
  override the payload writer does not honour - a Double spelled int32, an
  Integer spelled string - put one wire type in the tag and another's bytes
  after it. That is refused while the plan is built, by name. }
function ProtoScalarFits(AKind: TProtoMemberKind; AScalar: TProtoScalar): Boolean;
begin
  case AKind of
    TProtoMemberKind.IntValue, TProtoMemberKind.Int64Value:
      Result := AScalar in [TProtoScalar.Int32, TProtoScalar.Int64,
        TProtoScalar.UInt32, TProtoScalar.UInt64, TProtoScalar.SInt32,
        TProtoScalar.SInt64, TProtoScalar.Fixed32, TProtoScalar.Fixed64,
        TProtoScalar.SFixed32, TProtoScalar.SFixed64, TProtoScalar.EnumValue];
    TProtoMemberKind.FloatValue:
      Result := AScalar in [TProtoScalar.Float, TProtoScalar.Double];
    TProtoMemberKind.CurrencyValue:
      Result := AScalar in [TProtoScalar.Double, TProtoScalar.Float,
        TProtoScalar.Int64, TProtoScalar.UInt64, TProtoScalar.SInt64,
        TProtoScalar.Fixed64, TProtoScalar.SFixed64];
    TProtoMemberKind.BoolValue: Result := AScalar = TProtoScalar.Bool;
    TProtoMemberKind.EnumValue:
      Result := AScalar in [TProtoScalar.EnumValue, TProtoScalar.Int32];
    TProtoMemberKind.StrValue, TProtoMemberKind.DateValue,
    TProtoMemberKind.TimeValue:
      Result := AScalar = TProtoScalar.Text;
    TProtoMemberKind.BytesValue, TProtoMemberKind.GuidValue:
      Result := AScalar = TProtoScalar.Bytes;
    TProtoMemberKind.CustomSerializer: Result := True;
  else
    Result := AScalar = TProtoScalar.Auto;
  end;
end;

{ Whether an integer - signed or unsigned as its Delphi type says - is a
  value of this protobuf scalar. The payload writer narrows to 32 bits, and
  narrowing 5000000000 into an int32 wrote 705032704. }
function ProtoIntegerFits(ABits: Int64; AUnsigned: Boolean;
  AScalar: TProtoScalar): Boolean;
begin
  case AScalar of
    TProtoScalar.Int32, TProtoScalar.SInt32, TProtoScalar.SFixed32,
    TProtoScalar.EnumValue:
      if AUnsigned then Result := UInt64(ABits) <= UInt64(High(Integer))
      else Result := (ABits >= Low(Integer)) and (ABits <= High(Integer));
    TProtoScalar.UInt32, TProtoScalar.Fixed32:
      if AUnsigned then Result := UInt64(ABits) <= High(Cardinal)
      else Result := (ABits >= 0) and (ABits <= High(Cardinal));
    TProtoScalar.Int64, TProtoScalar.SInt64, TProtoScalar.SFixed64:
      Result := (not AUnsigned) or (ABits >= 0);
    TProtoScalar.UInt64, TProtoScalar.Fixed64:
      Result := AUnsigned or (ABits >= 0);
  else
    Result := True;
  end;
end;

{ The ordinal a wire number stands for, through a registered numbering if
  the type has one, and range-checked against the type if it has none. }
function ProtoEnumOrdinal(ATypeInfo: PTypeInfo; const ANumbers: TArray<Integer>;
  ANumber: Integer; out AOrdinal: Integer): Boolean;
var
  I: Integer;
  TD: PTypeData;
begin
  AOrdinal := -1;
  if Length(ANumbers) > 0 then
  begin
    for I := 0 to Integer(High(ANumbers)) do
      if ANumbers[I] = ANumber then
      begin
        AOrdinal := I;
        Exit(True);
      end;
    Exit(False);
  end;
  TD := GetTypeData(ATypeInfo);
  if (ANumber < TD.MinValue) or (ANumber > TD.MaxValue) then Exit(False);
  AOrdinal := ANumber;
  Result := True;
end;

function ParseIsoDate(const AText: string): TDate;
var
  Y, M, D: Integer;
  V: TDateTime;
begin
  if (Length(AText) <> 10) or (AText[5] <> '-') or (AText[8] <> '-') or
     not (TryStrToInt(Copy(AText, 1, 4), Y) and
          TryStrToInt(Copy(AText, 6, 2), M) and
          TryStrToInt(Copy(AText, 9, 2), D)) or
     not TryEncodeDate(Word(Y), Word(M), Word(D), V) then
    raise EProtobufInputError.CreateFmt(
      '"%s" is not a date. A TDate field travels as yyyy-mm-dd.', [AText]);
  Result := V;
end;

function ParseIsoTime(const AText: string): TTime;
var
  H, N, S, Z: Integer;
  V: TDateTime;
begin
  Z := 0;
  if (Length(AText) < 8) or (AText[3] <> ':') or (AText[6] <> ':') or
     not (TryStrToInt(Copy(AText, 1, 2), H) and
          TryStrToInt(Copy(AText, 4, 2), N) and
          TryStrToInt(Copy(AText, 7, 2), S)) or
     ((Length(AText) >= 12) and
      not TryStrToInt(Copy(AText, 10, 3), Z)) or
     not TryEncodeTime(Word(H), Word(N), Word(S), Word(Z), V) then
    raise EProtobufInputError.CreateFmt(
      '"%s" is not a time. A TTime field travels as hh:nn:ss.zzz.', [AText]);
  Result := V;
end;

{ ------------------------------------------------------------- the reader -- }

procedure TProtoReader.Init(const AData: TBytes; AStart, AEnd: Integer);
begin
  FData := AData;
  FPos := AStart;
  FEnd := AEnd;
end;

procedure TProtoReader.InitWhole(const AData: TBytes);
begin
  if Int64(Length(AData)) > MaxInt then
    raise EProtobufInputError.CreateFmt(
      'A buffer of %d bytes is not a protobuf message, which is at most ' +
      '2 GiB.', [Int64(Length(AData))]);
  Init(AData, 0, Integer(Length(AData)));
end;

procedure TProtoReader.Fail(const AMessage: string);
begin
  raise EProtobufInputError.CreateFmt('%s (at byte %d of %d)',
    [AMessage, FPos, Length(FData)]);
end;

function TProtoReader.AtEnd: Boolean;
begin
  Result := FPos >= FEnd;
end;

procedure TProtoReader.Need(ACount: Integer);
begin
  { Written as a subtraction rather than FPos + ACount > FEnd, because a
    document is allowed to claim two gigabytes and that addition would
    overflow before the comparison ever ran. }
  if (ACount < 0) or (ACount > FEnd - FPos) then
    Fail(Format('A field of %d bytes runs past the end of its message, which ' +
      'has %d left', [ACount, FEnd - FPos]));
end;

function TProtoReader.ReadByte: Byte;
begin
  Need(1);
  Result := FData[FPos];
  Inc(FPos);
end;

function TProtoReader.ReadVarint: UInt64;
var
  Shift, Count: Integer;
  B: Byte;
begin
  Result := 0;
  Shift := 0;
  Count := 0;
  repeat
    if FPos >= FEnd then Fail('A varint cut off by the end of the message');
    B := FData[FPos];
    Inc(FPos);
    Inc(Count);
    { Ten bytes is 70 bits, and only 64 of them can survive. An eleventh
      byte is not a large number, it is a malformed one. }
    if Count > PROTO_MAX_VARINT_BYTES then
      Fail('A varint longer than ten bytes');
    if Shift < 64 then
      Result := Result or (UInt64(B and $7F) shl Shift);
    Inc(Shift, 7);
  until (B and $80) = 0;
end;

function TProtoReader.ReadInt32: Integer;
begin
  { An int32 on the wire is a 64-bit varint, sign-extended when negative -
    which is why a negative int32 costs ten bytes and an sint32 costs two. }
  Result := Integer(UInt32(ReadVarint));
end;

function TProtoReader.ReadFixed32: UInt32;
begin
  Need(4);
  Move(FData[FPos], Result, 4);
  Inc(FPos, 4);
end;

function TProtoReader.ReadFixed64: UInt64;
begin
  Need(8);
  Move(FData[FPos], Result, 8);
  Inc(FPos, 8);
end;

procedure TProtoReader.ReadLengthBounds(out AStart, AStop: Integer);
var
  Len: UInt64;
begin
  Len := ReadVarint;
  if Len > UInt64(MaxInt) then
    Fail('A length-delimited field claiming more than two gigabytes');
  Need(Integer(Len));
  AStart := FPos;
  AStop := FPos + Integer(Len);
  FPos := AStop;
end;

function TProtoReader.ReadLengthDelimited: TBytes;
var
  Start, Stop: Integer;
begin
  ReadLengthBounds(Start, Stop);
  SetLength(Result, Stop - Start);
  if Stop > Start then Move(FData[Start], Result[0], Stop - Start);
end;

function TProtoReader.ReadTag(out AFieldNumber: Integer;
  out AWireType: TProtoWireType): Boolean;
var
  Tag: UInt64;
  W: Integer;
begin
  AFieldNumber := 0;
  AWireType := TProtoWireType.Varint;
  if AtEnd then Exit(False);
  Tag := ReadVarint;
  W := Integer(Tag and 7);
  if W > Ord(High(TProtoWireType)) then
    Fail(Format('Wire type %d, which the specification does not define', [W]));
  AWireType := TProtoWireType(W);
  Tag := Tag shr 3;
  if (Tag < PROTO_MIN_FIELD) or (Tag > PROTO_MAX_FIELD) then
    Fail(Format('Field number %d, which is outside 1..%d',
      [Tag, PROTO_MAX_FIELD]));
  AFieldNumber := Integer(Tag);
  Result := True;
end;

function TProtoReader.SkipField(ATagStart: Integer; AFieldNumber: Integer;
  AWireType: TProtoWireType; ADepth: Integer): TBytes;
var
  Start, Stop, InnerNumber: Integer;
  InnerType: TProtoWireType;
  InnerTagStart: Integer;
begin
  if ADepth > PROTO_MAX_DEPTH then
    Fail(Format('Groups nested more than %d deep', [PROTO_MAX_DEPTH]));
  case AWireType of
    TProtoWireType.Varint: ReadVarint;
    TProtoWireType.Fixed64: ReadFixed64;
    TProtoWireType.LengthDelimited: ReadLengthBounds(Start, Stop);
    TProtoWireType.Fixed32: ReadFixed32;
    TProtoWireType.StartGroup:
      { A group runs until its matching end tag, and groups nest. }
      while True do
      begin
        InnerTagStart := FPos;
        if not ReadTag(InnerNumber, InnerType) then
          Fail(Format('A group (field %d) with no end tag', [AFieldNumber]));
        if InnerType = TProtoWireType.EndGroup then
        begin
          if InnerNumber <> AFieldNumber then
            Fail(Format('A group end tag for field %d inside field %d',
              [InnerNumber, AFieldNumber]));
          Break;
        end;
        SkipField(InnerTagStart, InnerNumber, InnerType, ADepth + 1);
      end;
    TProtoWireType.EndGroup:
      Fail(Format('A group end tag for field %d with no start', [AFieldNumber]));
  end;
  { Everything from the tag to here, so a caller that keeps unknown fields
    keeps them exactly as they arrived. }
  SetLength(Result, FPos - ATagStart);
  if Length(Result) > 0 then Move(FData[ATagStart], Result[0], Length(Result));
end;

{ ------------------------------------------------------------- the writer -- }

procedure TProtoWriter.Init;
begin
  FData := nil;
  FPos := 0;
  SetLength(FData, 256);
end;

procedure TProtoWriter.Ensure(ACount: Integer);
begin
  { Against what is left below MaxInt: FPos + ACount wrapped negative. }
  if ACount > MaxInt - FPos then
    raise EProtobufInternalError.CreateFmt(
      'A message of %d bytes is too large to write; protobuf messages are ' +
      'at most 2 GiB.', [Int64(FPos) + ACount]);
  if FPos + ACount > Length(FData) then
    SetLength(FData, Max(FPos + ACount, Length(FData) * 2 + 64));
end;

procedure TProtoWriter.PutByte(AValue: Byte);
begin
  Ensure(1);
  FData[FPos] := AValue;
  Inc(FPos);
end;

procedure TProtoWriter.PutRaw(const AValue: TBytes);
begin
  if Length(AValue) = 0 then Exit;
  Ensure(ProtoWriterCount(Length(AValue)));
  Move(AValue[0], FData[FPos], Length(AValue));
  Inc(FPos, Length(AValue));
end;

procedure TProtoWriter.PutVarint(AValue: UInt64);
begin
  Ensure(PROTO_MAX_VARINT_BYTES);
  while AValue >= $80 do
  begin
    FData[FPos] := Byte(AValue) or $80;
    Inc(FPos);
    AValue := AValue shr 7;
  end;
  FData[FPos] := Byte(AValue);
  Inc(FPos);
end;

procedure TProtoWriter.PutFixed32(AValue: UInt32);
begin
  Ensure(4);
  Move(AValue, FData[FPos], 4);
  Inc(FPos, 4);
end;

procedure TProtoWriter.PutFixed64(AValue: UInt64);
begin
  Ensure(8);
  Move(AValue, FData[FPos], 8);
  Inc(FPos, 8);
end;

procedure TProtoWriter.PutTag(AFieldNumber: Integer;
  AWireType: TProtoWireType);
begin
  PutVarint((UInt64(AFieldNumber) shl 3) or UInt64(Ord(AWireType)));
end;

procedure TProtoWriter.PutLengthDelimited(const AValue: TBytes);
begin
  PutVarint(UInt64(Length(AValue)));
  PutRaw(AValue);
end;

function TProtoWriter.BeginSubMessage: Integer;
begin
  { The body goes in first and the length is inserted in front of it
    afterwards, once it is known.

    The length could be reserved as a padded five-byte varint instead, which
    saves a memory move - but a padded varint is not the bytes the
    specification's own examples show, and matching those byte for byte is
    worth more than one memmove of a sub-message. }
  Result := FPos;
end;

procedure TProtoWriter.EndSubMessage(AMark: Integer);
var
  Len, Size, I: Integer;
  V: UInt64;
begin
  Len := FPos - AMark;

  Size := 1;
  V := UInt64(Len);
  while V >= $80 do
  begin
    Inc(Size);
    V := V shr 7;
  end;

  Ensure(Size);
  if Len > 0 then Move(FData[AMark], FData[AMark + Size], Len);

  V := UInt64(Len);
  for I := 0 to Size - 1 do
  begin
    if I = Size - 1 then FData[AMark + I] := Byte(V and $7F)
    else FData[AMark + I] := Byte(V and $7F) or $80;
    V := V shr 7;
  end;
  Inc(FPos, Size);
end;

function TProtoWriter.Done: TBytes;
begin
  SetLength(FData, FPos);
  Result := FData;
end;

{ ===========================================================================
  2. THE PLANS
  =========================================================================== }

destructor TProtoMemberPlan.Destroy;
begin
  Inner.Free;
  Item.Free;
  Key.Free;
  Value.Free;
  inherited Destroy;
end;

function TProtoMemberPlan.IsContainer: Boolean;
begin
  Result := Kind in [TProtoMemberKind.ListValue,
    TProtoMemberKind.DictionaryValue, TProtoMemberKind.ArrayValue];
end;

function TProtoMemberPlan.IsPackable: Boolean;
begin
  Result := Kind in [TProtoMemberKind.BoolValue, TProtoMemberKind.IntValue,
    TProtoMemberKind.Int64Value, TProtoMemberKind.FloatValue,
    TProtoMemberKind.CurrencyValue, TProtoMemberKind.EnumValue];
end;

destructor TProtoFieldPlan.Destroy;
begin
  Member.Free;
  inherited Destroy;
end;

constructor TProtoTypePlan.Create;
begin
  inherited Create;
  Fields := TObjectList<TProtoFieldPlan>.Create(True);
  ByNumber := TDictionary<Integer, Integer>.Create;
  OneOfs := TObjectDictionary<string, TList<Integer>>.Create([doOwnsValues]);
end;

destructor TProtoTypePlan.Destroy;
begin
  OneOfs.Free;
  ByNumber.Free;
  Fields.Free;
  inherited Destroy;
end;

{ ===========================================================================
  3. THE ENGINE
  =========================================================================== }

class constructor TProtoEngine.Create;
begin
  FCtx := TRttiContext.Create;
  FLock := TCriticalSection.Create;
  FPlans := TObjectDictionary<PTypeInfo, TProtoTypePlan>.Create([doOwnsValues]);
  FRootPlans := TObjectDictionary<PTypeInfo, TProtoMemberPlan>.Create([doOwnsValues]);
  FEnumNumbers := TDictionary<PTypeInfo, TArray<Integer>>.Create;
  FTypeSerializers := TDictionary<PTypeInfo, TProtoValueSerializerClass>.Create;
  FSerializerSingletons :=
    TObjectDictionary<TClass, TCustomProtoValueSerializerBase>.Create([doOwnsValues]);
  FBuildTrail := TList<PTypeInfo>.Create;
end;

class destructor TProtoEngine.Destroy;
begin
  FBuildTrail.Free;
  FSerializerSingletons.Free;
  FTypeSerializers.Free;
  FEnumNumbers.Free;
  FRootPlans.Free;
  FPlans.Free;
  FLock.Free;
  FCtx.Free;
end;

class procedure TProtoEngine.CheckNotFrozen;
begin
  if FFrozen then
    raise EProtobufInternalError.Create(
      'The protobuf configuration is frozen. A registration made after the ' +
      'first use of a type would be a silent no-op, because that type''s ' +
      'plan is already cached - so it raises instead.');
end;

class procedure TProtoEngine.FreezeConfiguration;
begin
  FLock.Enter;
  try
    FFrozen := True;
  finally
    FLock.Leave;
  end;
end;

class function TProtoEngine.IsFrozen: Boolean;
begin
  Result := FFrozen;
end;

class procedure TProtoEngine.ResetConfiguration;
begin
  FLock.Enter;
  try
    FFrozen := False;
    FPlans.Clear;
    FRootPlans.Clear;
    FEnumNumbers.Clear;
    FTypeSerializers.Clear;
    FSerializerSingletons.Clear;
  finally
    FLock.Leave;
  end;
end;

class function TProtoEngine.PlanCount: Integer;
begin
  FLock.Enter;
  try
    Result := Integer(FPlans.Count);
  finally
    FLock.Leave;
  end;
end;

class procedure TProtoEngine.RegisterEnumNumbers(ATypeInfo: PTypeInfo;
  const ANumbers: array of Integer);
var
  Copy: TArray<Integer>;
  I: Integer;
begin
  FLock.Enter;
  try
    CheckNotFrozen;
    SetLength(Copy, Length(ANumbers));
    for I := 0 to Integer(High(ANumbers)) do Copy[I] := ANumbers[I];
    FEnumNumbers.AddOrSetValue(ATypeInfo, Copy);
  finally
    FLock.Leave;
  end;
end;

class procedure TProtoEngine.RegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TProtoValueSerializerClass);
begin
  FLock.Enter;
  try
    CheckNotFrozen;
    FTypeSerializers.AddOrSetValue(ATypeInfo, ASerializerClass);
  finally
    FLock.Leave;
  end;
end;

class function TProtoEngine.ResolveSerializer(
  AClass: TProtoValueSerializerClass): TCustomProtoValueSerializerBase;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  if not FSerializerSingletons.TryGetValue(AClass, Result) then
  begin
    Result := AClass.Create;
    FSerializerSingletons.Add(AClass, Result);
  end;
end;

class function TProtoEngine.EnumNumbersFor(
  ATypeInfo: PTypeInfo): TArray<Integer>;
begin
  if not FEnumNumbers.TryGetValue(ATypeInfo, Result) then Result := nil;
end;

{ ------------------------------------------------------------ classifying -- }

class function TProtoEngine.ClassifyType(
  ATypeInfo: PTypeInfo): TProtoMemberKind;
var
  Access: TNullableAccess;
begin
  if ATypeInfo = nil then Exit(TProtoMemberKind.Unsupported);

  if ATypeInfo = System.TypeInfo(TDateTime) then
    Exit(TProtoMemberKind.DateTimeValue);
  if ATypeInfo = System.TypeInfo(TDate) then Exit(TProtoMemberKind.DateValue);
  if ATypeInfo = System.TypeInfo(TTime) then Exit(TProtoMemberKind.TimeValue);
  if ATypeInfo = System.TypeInfo(TGUID) then Exit(TProtoMemberKind.GuidValue);
  if ATypeInfo = System.TypeInfo(TBytes) then Exit(TProtoMemberKind.BytesValue);

  if TSerializationTypes.TryGetNullableAccess(ATypeInfo, Access) then
    Exit(TProtoMemberKind.NullableValue);

  case ATypeInfo.Kind of
    tkInteger: Exit(TProtoMemberKind.IntValue);
    tkInt64: Exit(TProtoMemberKind.Int64Value);
    tkEnumeration:
      begin
        if (ATypeInfo = System.TypeInfo(Boolean)) or
           (ATypeInfo = System.TypeInfo(ByteBool)) or
           (ATypeInfo = System.TypeInfo(WordBool)) or
           (ATypeInfo = System.TypeInfo(LongBool)) then
          Exit(TProtoMemberKind.BoolValue);
        Exit(TProtoMemberKind.EnumValue);
      end;
    tkFloat:
      begin
        if GetTypeData(ATypeInfo).FloatType = ftCurr then
          Exit(TProtoMemberKind.CurrencyValue);
        { Comp is a 64-bit integer RTTI files under tkFloat: an int64. }
        if GetTypeData(ATypeInfo).FloatType = ftComp then
          Exit(TProtoMemberKind.Int64Value);
        Exit(TProtoMemberKind.FloatValue);
      end;
    tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
      Exit(TProtoMemberKind.StrValue);
    tkSet: Exit(TProtoMemberKind.SetValue);
    tkDynArray, tkArray: Exit(TProtoMemberKind.ArrayValue);
    tkRecord, tkMRecord: Exit(TProtoMemberKind.RecordValue);
    tkClass:
      begin
        { Ancestry, not a class-name prefix: TOrders = class(TObjectList<T>)
          is a list too, and the whole library agrees about that because it
          asks the same shared question. }
        { The one question, asked in one place - see the note in the JSON
          engine. Ancestry, never a method shape and never a name prefix. }
        case TSerializationTypes.ContainerKindOf(ATypeInfo) of
          TContainerKind.Dictionary: Exit(TProtoMemberKind.DictionaryValue);
          TContainerKind.List:       Exit(TProtoMemberKind.ListValue);
        end;
        Exit(TProtoMemberKind.MessageValue);
      end;
  end;
  Result := TProtoMemberKind.Unsupported;
end;

class function TProtoEngine.DefaultScalar(AKind: TProtoMemberKind;
  ATypeInfo: PTypeInfo): TProtoScalar;
begin
  case AKind of
    TProtoMemberKind.BoolValue: Result := TProtoScalar.Bool;
    TProtoMemberKind.IntValue:
      begin
        { An unsigned Delphi type maps to uint32, which costs nothing extra
          and refuses to be read back as a negative number. Asked of Core
          as well as of MinValue: a subrange such as 3000000000..4000000000
          is unsigned, and its MinValue - a signed Longint - is negative. }
        if (ATypeInfo <> nil) and (ATypeInfo.Kind = tkInteger) and
           (TSerializationTypes.IsUnsignedInteger(ATypeInfo) or
            (GetTypeData(ATypeInfo).MinValue >= 0)) then
          Result := TProtoScalar.UInt32
        else
          Result := TProtoScalar.Int32;
      end;
    TProtoMemberKind.Int64Value:
      begin
        if (ATypeInfo <> nil) and (ATypeInfo.Kind = tkInt64) and
           (TSerializationTypes.IsUnsignedInteger(ATypeInfo) or
            (GetTypeData(ATypeInfo).MinInt64Value >= 0)) then
          Result := TProtoScalar.UInt64
        else
          Result := TProtoScalar.Int64;
      end;
    TProtoMemberKind.FloatValue:
      begin
        if ATypeInfo = System.TypeInfo(Single) then Result := TProtoScalar.Float
        else Result := TProtoScalar.Double;
      end;
    { A Currency is a scaled Int64 in Delphi and is written as one, exactly.
      Routing it through a double would lose the fifteenth digit, which is
      the digit money is about.

      sint64 rather than int64 because a negative amount is ordinary - a
      return, a correction - and an int64 sign-extends it to ten bytes. The
      scale is the one Delphi's own Currency uses, ten thousand, so the
      value on the wire is the amount times 10000 with no rounding anywhere.

      THIS IS THE DEFAULT AND NOT THE LAW. [ProtoType] overrides it for one
      member, and an external descriptor in
      TProtobufSerializationOptions.Schema overrides it for every root
      field at once - if the .proto says double, the wire carries a double,
      because the .proto is what the other end reads. }
    TProtoMemberKind.CurrencyValue: Result := TProtoScalar.SInt64;
    TProtoMemberKind.StrValue: Result := TProtoScalar.Text;
    TProtoMemberKind.BytesValue, TProtoMemberKind.GuidValue:
      Result := TProtoScalar.Bytes;
    { An instant becomes google.protobuf.Timestamp - a nested message of
      seconds and nanos - which is the well-known type for exactly this. A
      TDate and a TTime are NOT instants, so they travel as text. }
    TProtoMemberKind.DateTimeValue: Result := TProtoScalar.Auto;
    TProtoMemberKind.DateValue, TProtoMemberKind.TimeValue:
      Result := TProtoScalar.Text;
    TProtoMemberKind.EnumValue: Result := TProtoScalar.EnumValue;
  else
    Result := TProtoScalar.Auto;
  end;
end;

{ ------------------------------------------------------------ plan building - }

class procedure TProtoEngine.RollbackBuildTrail;
var
  I: Integer;
begin
  for I := Integer(FBuildTrail.Count - 1) downto 0 do FPlans.Remove(FBuildTrail[I]);
  FBuildTrail.Clear;
end;

class function TProtoEngine.GetPlan(ATypeInfo: PTypeInfo): TProtoTypePlan;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  FLock.Enter;
  try
    if FPlans.TryGetValue(ATypeInfo, Result) then Exit;
    Inc(FBuildDepth);
    try
      Result := BuildPlan(ATypeInfo);
    except
      { THE DEPTH COMES BACK DOWN ON THE WAY OUT TOO.

        Decremented on failure as well as success: a counter left raised
        would make the next top-level build look nested and skip the
        rollback, leaving a half-built plan in the cache that a second
        attempt would find and use to write nothing - a refusal turned into
        silence by being asked twice. }
      Dec(FBuildDepth);
      if FBuildDepth = 0 then RollbackBuildTrail;
      raise;
    end;
    Dec(FBuildDepth);
    if FBuildDepth = 0 then FBuildTrail.Clear;
  finally
    FLock.Leave;
  end;
end;

{ Whether a member is on the wire at all. }
function HasProtoField(const AAttrs: TArray<TCustomAttribute>): Boolean;
var
  A: TCustomAttribute;
begin
  for A in AAttrs do
    if A is ProtoFieldAttribute then Exit(True);
  Result := False;
end;

{ Does this type declare anything that COULD have been numbered? Public and
  published members only, because those are the ones the plan looks at, and
  a member that is explicitly [ProtoIgnore]d is a decision rather than an
  omission. }
function HasUnnumberedMembers(ART: TRttiType): Boolean;

  function Eligible(const AAttrs: TArray<TCustomAttribute>;
    AVisibility: TMemberVisibility): Boolean;
  var
    A: TCustomAttribute;
  begin
    Result := False;
    if not (AVisibility in [mvPublic, mvPublished]) then Exit;
    for A in AAttrs do
      if (A is ProtoIgnoreAttribute) or (A is ProtoFieldAttribute) or
         (A is ProtoUnknownAttribute) then Exit;
    Result := True;
  end;

var
  M: TSerializationMember;
begin
  for M in TSerializationMetadata.Get(ART.Handle).Members do
    if not M.Ignored and Eligible(M.Member.GetAttributes, M.Visibility) then
      Exit(True);
  Result := False;
end;

class function TProtoEngine.BuildPlan(ATypeInfo: PTypeInfo): TProtoTypePlan;
var
  RT: TRttiType;
  Meta: TSerializationTypeMetadata;
  Member: TSerializationMember;
begin
  RT := FCtx.GetType(ATypeInfo);
  if RT = nil then
    raise EProtobufInternalError.CreateFmt(
      'No RTTI for %s.', [UTF8ToString(ATypeInfo.Name)]);

  Result := TProtoTypePlan.Create;
  { Registered BEFORE the members are built, so a type that contains itself
    finds its own plan rather than recursing forever. }
  FPlans.Add(ATypeInfo, Result);
  FBuildTrail.Add(ATypeInfo);

  Result.TypeInfo := ATypeInfo;
  Result.RttiType := RT;
  Result.IsRecord := ATypeInfo.Kind in [tkRecord, tkMRecord];
  Result.TypeKey := TypeKeyOf(ATypeInfo);
  Result.UnitName := TypeUnitOf(ATypeInfo);
  { The Delphi facts - the constructor, the member surface, the general
    [SerializationIgnore] - come from the shared metadata. Protobuf names
    nothing on the wire, so [SerializationName] has nothing to name, and
    its enumerations are numbers, which [SerializationEnum] does not
    change. }
  Meta := TSerializationMetadata.Get(ATypeInfo);
  if ATypeInfo.Kind = tkClass then
  begin
    Result.ClassType := TRttiInstanceType(RT).MetaclassType;
    Result.ZeroConstructor := Meta.DeclaredConstructor;
    if Result.ZeroConstructor = nil then
      Result.ZeroConstructor := Meta.TObjectConstructor;
  end;

  for Member in Meta.Members do
    if not Member.Ignored then
      BuildMemberOfType(Result, Member.Field, Member.Prop);

  { A CONTRACT WITH NO FIELD NUMBERS IS NOT AN EMPTY MESSAGE.

    Protobuf bytes carry field numbers and nothing else, so a member with no
    [ProtoField] cannot be written - that is documented and deliberate, and
    it is how a caller leaves a member out.

    But a class whose members ALL lack one is a different thing. Writing it
    produces zero bytes, reading those bytes back produces a default-
    constructed object, and the round trip loses the entire document while
    reporting success. That is the worst failure a serializer has: silent
    and total.

    A caller who genuinely wants an empty message writes a class with no
    members, or marks them [ProtoIgnore], and both of those still work. What
    is refused is the case that can only be a mistake, and it is refused
    where the mistake was made - at the type - rather than as a mystery
    later. }
  if (Result.Fields.Count = 0) and HasUnnumberedMembers(RT) then
    raise EProtobufError.CreateFmt(
      '%s has members but not one of them carries [ProtoField], so a ' +
      'Protobuf message built from it would be empty and the round trip ' +
      'would lose everything. Number the members that belong on the wire, ' +
      'or mark them [ProtoIgnore] to say the emptiness is intended.',
      [UTF8ToString(ATypeInfo.Name)]);
end;

class procedure TProtoEngine.BuildMemberOfType(APlan: TProtoTypePlan;
  AField: TRttiField; AProp: TRttiProperty);
var
  Attrs: TArray<TCustomAttribute>;
  A: TCustomAttribute;
  FP: TProtoFieldPlan;
  Number: Integer;
  Scalar: TProtoScalar;
  HasNumber, HasScalar, IsUnknown, HasPacked, PackedValue: Boolean;
  OneOf, MemberName: string;
  MemberType: PTypeInfo;
  Visibility: TMemberVisibility;
  SerializerClass: TProtoValueSerializerClass;
  Existing: Integer;
  List: TList<Integer>;
  Target: TProtoMemberPlan;
begin
  if AField <> nil then
  begin
    Attrs := AField.GetAttributes;
    MemberName := AField.Name;
    Visibility := AField.Visibility;
    { A field with no RTTI type is not dereferenced before its visibility
      and attributes are looked at: a member that is not on the wire costs
      nothing, and one that is gets refused by name. }
    if AField.FieldType = nil then
    begin
      if not (Visibility in [mvPublic, mvPublished]) then Exit;
      for A in Attrs do
        if A is ProtoIgnoreAttribute then Exit;
      if not HasProtoField(Attrs) then Exit;
      raise EProtobufError.CreateFmt(
        '%s %s. Leave it out with [ProtoIgnore], or register a Protobuf ' +
        'type serializer for the type that holds it.',
        [MemberName, TSerializationTypes.UnsupportedReason(nil)]);
    end;
    MemberType := AField.FieldType.Handle;
  end
  else
  begin
    Attrs := AProp.GetAttributes;
    MemberName := AProp.Name;
    if AProp.PropertyType = nil then Exit;
    MemberType := AProp.PropertyType.Handle;
    Visibility := AProp.Visibility;
    if not AProp.IsReadable then Exit;
  end;

  if not (Visibility in [mvPublic, mvPublished]) then Exit;

  HasNumber := False;
  HasScalar := False;
  HasPacked := False;
  PackedValue := True;
  IsUnknown := False;
  Number := 0;
  Scalar := TProtoScalar.Auto;
  OneOf := '';
  SerializerClass := nil;

  for A in Attrs do
  begin
    if A is ProtoIgnoreAttribute then Exit;
    if A is ProtoFieldAttribute then
    begin
      Number := ProtoFieldAttribute(A).Number;
      HasNumber := True;
    end
    else if A is ProtoTypeAttribute then
    begin
      Scalar := ProtoTypeAttribute(A).Scalar;
      HasScalar := True;
    end
    else if A is ProtoPackedAttribute then
    begin
      PackedValue := ProtoPackedAttribute(A).IsPacked;
      HasPacked := True;
    end
    else if A is ProtoOneOfAttribute then
      OneOf := ProtoOneOfAttribute(A).Name
    else if A is ProtoUnknownAttribute then
      IsUnknown := True
    else if A is ProtoSerializerAttribute then
      SerializerClass := ProtoSerializerAttribute(A).SerializerClass;
  end;

  if IsUnknown then
  begin
    if MemberType <> System.TypeInfo(TBytes) then
      raise EProtobufInternalError.CreateFmt(
        '%s.%s is marked [ProtoUnknown] but is not TBytes. Unknown fields ' +
        'are kept as the bytes they arrived as, so the store has to be ' +
        'TBytes.', [APlan.TypeKey, MemberName]);
    if APlan.UnknownStore <> nil then
      raise EProtobufInternalError.CreateFmt(
        '%s has two [ProtoUnknown] members. There can be only one place to ' +
        'keep them.', [APlan.TypeKey]);
  end
  else
  begin
    { NO NUMBER, NO FIELD. Protobuf has no names on the wire, so there is
      nothing to fall back on and nothing to guess. }
    if not HasNumber then Exit;
    if (Number < PROTO_MIN_FIELD) or (Number > PROTO_MAX_FIELD) then
      raise EProtobufInternalError.CreateFmt(
        '%s.%s has field number %d. A field number is between %d and %d.',
        [APlan.TypeKey, MemberName, Number, PROTO_MIN_FIELD, PROTO_MAX_FIELD]);
    if (Number >= PROTO_RESERVED_LO) and (Number <= PROTO_RESERVED_HI) then
      raise EProtobufInternalError.CreateFmt(
        '%s.%s has field number %d. The range %d..%d is reserved by the ' +
        'protobuf specification for its own use.',
        [APlan.TypeKey, MemberName, Number, PROTO_RESERVED_LO,
         PROTO_RESERVED_HI]);
    if APlan.ByNumber.TryGetValue(Number, Existing) then
      raise EProtobufInternalError.CreateFmt(
        '%s.%s and %s.%s both claim field number %d. On the wire they would ' +
        'be the same field, and the second would silently overwrite the ' +
        'first.', [APlan.TypeKey, MemberName, APlan.TypeKey,
         APlan.Fields[Existing].DelphiName, Number]);
  end;

  FP := TProtoFieldPlan.Create;
  try
    FP.Field := AField;
    FP.Prop := AProp;
    FP.DelphiName := MemberName;
    FP.Number := Number;
    FP.OneOf := OneOf;
    FP.IsUnknownStore := IsUnknown;
    FP.Writable := (AField <> nil) or ((AProp <> nil) and AProp.IsWritable);

    if IsUnknown then
      FP.Member := nil
    else if SerializerClass <> nil then
    begin
      { The member's own serializer decides everything about it, so the
        type is never classified - which is what lets [ProtoSerializer]
        rescue a member whose type the engine would refuse by itself. }
      FP.Member := TProtoMemberPlan.Create;
      FP.Member.TypeInfo := MemberType;
      FP.Member.Kind := TProtoMemberKind.CustomSerializer;
      FP.Member.Serializer := ResolveSerializer(SerializerClass);
    end
    else
    begin
      FP.Member := BuildMemberPlan(MemberType, APlan.TypeKey, MemberName);
      if HasScalar then
      begin
        { A scalar override applies to the element of a repeated field, not
          to the field itself - "repeated sint32" overrides the sint32. }
        if FP.Member.IsContainer and (FP.Member.Item <> nil) then
          Target := FP.Member.Item
        else if FP.Member.Kind = TProtoMemberKind.NullableValue then
          Target := FP.Member.Inner
        else
          Target := FP.Member;
        if not ProtoScalarFits(Target.Kind, Scalar) then
          raise EProtobufError.CreateFmt(
            '%s is marked [ProtoType(%s)], and a %s is not written as a ' +
            'protobuf %s. Choose a scalar of the same family, or register a ' +
            'Protobuf type serializer for it.',
            [MemberDisplayName(APlan.TypeKey, MemberName),
             GetEnumName(System.TypeInfo(TProtoScalar), Ord(Scalar)),
             UTF8ToString(Target.TypeInfo.Name), ProtoScalarName(Scalar)]);
        Target.Scalar := Scalar;
      end;
      { A oneof is a choice between SINGULAR fields: protobuf has no
        repeated or map member of one, and a reader of the .proto would not
        accept the message. }
      if (OneOf <> '') and FP.Member.IsContainer then
        raise EProtobufError.CreateFmt(
          '%s is in the oneof "%s" and is a repeated field or a map, and a ' +
          'protobuf oneof holds singular fields only. Take it out of the ' +
          'oneof, or wrap it in a message type of its own.',
          [MemberDisplayName(APlan.TypeKey, MemberName), OneOf]);
      if HasPacked then FP.Packed_ := PackedValue
      else FP.Packed_ := True;
    end;
  except
    FP.Free;
    raise;
  end;

  APlan.Fields.Add(FP);
  if IsUnknown then
    APlan.UnknownStore := FP
  else
  begin
    APlan.ByNumber.Add(Number, Integer(APlan.Fields.Count - 1));
    if OneOf <> '' then
    begin
      if not APlan.OneOfs.TryGetValue(OneOf, List) then
      begin
        List := TList<Integer>.Create;
        APlan.OneOfs.Add(OneOf, List);
      end;
      List.Add(Number);
    end;
  end;
end;

{ A repeated field of repeated fields, or a map whose value is one, is not
  protobuf: an element of a repeated field is a scalar or a message, and
  so is a map value. The inner sequence needs a message of its own. This is
  refused while the plan is built, by name, rather than reaching the writer
  and failing there as "cannot write an ArrayValue as a scalar". }
procedure RefuseNestedRepeat(AItem: TProtoMemberPlan;
  const AOwnerKey, AMemberName: string);
begin
  if AItem = nil then Exit;
  if AItem.Kind in [TProtoMemberKind.ArrayValue, TProtoMemberKind.ListValue,
       TProtoMemberKind.DictionaryValue] then
    raise EProtobufError.CreateFmt(
      '%s holds %s, a sequence or map inside a repeated field or a map, and ' +
      'protobuf has no field of that shape: an element or a map value is a ' +
      'scalar or a message. Wrap the inner %s in a message type of its own, ' +
      'or register a Protobuf type serializer for it.',
      [MemberDisplayName(AOwnerKey, AMemberName), UTF8ToString(AItem.TypeInfo.Name),
       UTF8ToString(AItem.TypeInfo.Name)]);
end;

class function TProtoEngine.BuildMemberPlan(ATypeInfo: PTypeInfo;
  const AOwnerKey, AMemberName: string): TProtoMemberPlan;
var
  RT, ItemType: TRttiType;
  Cls: TClass;
  Params: TArray<TRttiParameter>;
  PairType: TRttiType;
  SerClass: TProtoValueSerializerClass;
  Access: TNullableAccess;
  M: TRttiMethod;
  Why: string;
  ListAccess: TListAccess;
begin
  Result := TProtoMemberPlan.Create;
  try
    Result.TypeInfo := ATypeInfo;
    Result.Kind := ClassifyType(ATypeInfo);
    Result.Scalar := DefaultScalar(Result.Kind, ATypeInfo);

    if FTypeSerializers.TryGetValue(ATypeInfo, SerClass) then
    begin
      Result.Kind := TProtoMemberKind.CustomSerializer;
      Result.Serializer := ResolveSerializer(SerClass);
      Exit;
    end;

    { The decision every format shares - see
      TSerializationTypes.UnsupportedReason. }
    Why := TSerializationTypes.UnsupportedReason(ATypeInfo);
    if Why <> '' then
      raise EProtobufError.CreateFmt(
        '%s %s. Leave it out with [ProtoIgnore], or register a Protobuf ' +
        'type serializer for its type.',
        [MemberDisplayName(AOwnerKey, AMemberName), Why]);
    { A Variant has no fixed type, and a message declares one for every
      field; there is nothing to write it as. Refused by design. }
    if ATypeInfo.Kind = tkVariant then
      raise EProtobufError.CreateFmt(
        '%s is a Variant, and a Protobuf field has one declared type. ' +
        'Register a Protobuf type serializer for it, or give the member a ' +
        'declared type.', [MemberDisplayName(AOwnerKey, AMemberName)]);

    case Result.Kind of
      TProtoMemberKind.Unsupported:
        raise EProtobufInternalError.CreateFmt(
          'Cannot serialize %s.%s: protobuf has no representation for %s.',
          [AOwnerKey, AMemberName, UTF8ToString(ATypeInfo.Name)]);

      TProtoMemberKind.EnumValue:
        Result.EnumNumbers := EnumNumbersFor(ATypeInfo);

      TProtoMemberKind.SetValue:
        begin
          Result.SetElemTypeInfo := GetTypeData(ATypeInfo).CompType^;
          Result.SetElemNumbers := EnumNumbersFor(Result.SetElemTypeInfo);
        end;

      TProtoMemberKind.NullableValue:
        begin
          TSerializationTypes.TryGetNullableAccess(ATypeInfo, Access);
          Result.NullableAccess := Access;
          Result.Inner := BuildMemberPlan(Access.ValueType, AOwnerKey,
            AMemberName);
          { A repeated field or a map has no presence: an absent one and an
            empty one are the same bytes, so a nullable one has nothing to
            say that the container alone does not. Refused here, by name,
            rather than in the scalar writer. }
          if Result.Inner.IsContainer then
            raise EProtobufError.CreateFmt(
              '%s is a nullable %s, and a protobuf repeated field or map has ' +
              'no presence to carry the null: absent and empty are the same ' +
              'bytes. Declare the %s itself, or register a Protobuf type ' +
              'serializer for it.',
              [MemberDisplayName(AOwnerKey, AMemberName),
               UTF8ToString(Access.ValueType.Name), UTF8ToString(Access.ValueType.Name)]);
        end;

      TProtoMemberKind.MessageValue, TProtoMemberKind.RecordValue:
        Result.BoundPlan := GetPlan(ATypeInfo);

      TProtoMemberKind.ArrayValue:
        begin
          { A static array is a repeated field of exactly its length, written
            flat in the order Delphi stores it. }
          ItemType := FCtx.GetType(ATypeInfo);
          if ItemType is TRttiArrayType then
            Result.Item := BuildMemberPlan(
              TRttiArrayType(ItemType).ElementType.Handle, AOwnerKey,
              AMemberName)
          else
            Result.Item := BuildMemberPlan(
              TRttiDynamicArrayType(ItemType).ElementType.Handle,
              AOwnerKey, AMemberName);
          RefuseNestedRepeat(Result.Item, AOwnerKey, AMemberName);
        end;

      TProtoMemberKind.ListValue:
        begin
          RT := FCtx.GetType(ATypeInfo);
          Cls := TRttiInstanceType(RT).MetaclassType;
          { The methods Core names for this list's family: a TQueue<T>
            enqueues, a TStack<T> pushes, and neither has an Add. }
          if not TSerializationTypes.TryGetListAccess(ATypeInfo, ListAccess) then
            raise EProtobufInternalError.CreateFmt(
              'Cannot serialize %s.%s: %s is a list with no usable methods ' +
              'to add to it and read it.', [AOwnerKey, AMemberName, Cls.ClassName]);
          Result.ContainerAdd := ListAccess.AddMethod;
          Result.ContainerClear := ListAccess.ClearMethod;
          Result.ContainerToArray := ListAccess.ToArrayMethod;
          Params := Result.ContainerAdd.GetParameters;
          if Length(Params) <> 1 then
            raise EProtobufInternalError.CreateFmt(
              'Cannot serialize %s.%s: Add takes %d parameters.',
              [AOwnerKey, AMemberName, Length(Params)]);
          Result.Item := BuildMemberPlan(Params[0].ParamType.Handle,
            AOwnerKey, AMemberName);
          RefuseNestedRepeat(Result.Item, AOwnerKey, AMemberName);
          Result.ContainerCreate := ListAccess.CreateMethod;
        end;

      TProtoMemberKind.DictionaryValue:
        begin
          RT := FCtx.GetType(ATypeInfo);
          Cls := TRttiInstanceType(RT).MetaclassType;
          Result.ContainerAdd := RT.GetMethod('AddOrSetValue');
          if Result.ContainerAdd = nil then
            Result.ContainerAdd := RT.GetMethod('Add');
          Result.ContainerClear := RT.GetMethod('Clear');
          Result.ContainerToArray := RT.GetMethod('ToArray');
          if (Result.ContainerAdd = nil) or (Result.ContainerToArray = nil) then
            raise EProtobufInternalError.CreateFmt(
              'Cannot serialize %s.%s: %s looks like a dictionary but has ' +
              'no Add and ToArray.', [AOwnerKey, AMemberName, Cls.ClassName]);
          Params := Result.ContainerAdd.GetParameters;
          if Length(Params) <> 2 then
            raise EProtobufInternalError.CreateFmt(
              'Cannot serialize %s.%s: Add takes %d parameters.',
              [AOwnerKey, AMemberName, Length(Params)]);
          Result.Key := BuildMemberPlan(Params[0].ParamType.Handle,
            AOwnerKey, AMemberName);
          Result.Value := BuildMemberPlan(Params[1].ParamType.Handle,
            AOwnerKey, AMemberName);
          RefuseNestedRepeat(Result.Value, AOwnerKey, AMemberName);
          PairType := Result.ContainerToArray.ReturnType;
          if PairType <> nil then
          begin
            PairType := TRttiDynamicArrayType(PairType).ElementType;
            Result.PairKeyField := PairType.GetField('Key');
            Result.PairValueField := PairType.GetField('Value');
          end;
          if (Result.PairKeyField = nil) or (Result.PairValueField = nil) then
            raise EProtobufInternalError.CreateFmt(
              'Cannot serialize %s.%s: ToArray does not yield key/value ' +
              'pairs.', [AOwnerKey, AMemberName]);
          for M in RT.GetMethods do
            if M.IsConstructor and (Length(M.GetParameters) = 0) then
            begin
              Result.ContainerCreate := M;
              Break;
            end;
          Result.HasDictAccess := TSerializationTypes.TryGetDictionaryAccess(
            ATypeInfo, Result.DictAccess);
        end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TProtoEngine.GetRootPlan(ATypeInfo: PTypeInfo): TProtoMemberPlan;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  FLock.Enter;
  try
    if FRootPlans.TryGetValue(ATypeInfo, Result) then Exit;
    Result := BuildMemberPlan(ATypeInfo, 'root', '<root>');
    FRootPlans.Add(ATypeInfo, Result);
  finally
    FLock.Leave;
  end;
end;

{ -------------------------------------------------------- member access ---- }

class function TProtoEngine.ReadMember(AFP: TProtoFieldPlan;
  AInstance: Pointer): TValue;
begin
  if AFP.Field <> nil then
    Result := AFP.Field.GetValue(AInstance)
  else
    Result := AFP.Prop.GetValue(AInstance);
end;

class procedure TProtoEngine.StoreMember(AFP: TProtoFieldPlan;
  AInstance: Pointer; const AValue: TValue);
begin
  if not AFP.Writable then Exit;
  if AFP.Field <> nil then AFP.Field.SetValue(AInstance, AValue)
  else AFP.Prop.SetValue(AInstance, AValue);
end;

class function TProtoEngine.NewInstanceOf(APlan: TProtoTypePlan): TObject;
begin
  if APlan.ZeroConstructor <> nil then
    Result := APlan.ZeroConstructor.Invoke(APlan.ClassType, []).AsObject
  else
    Result := APlan.ClassType.Create;
end;

class function TProtoEngine.NewContainer(APlan: TProtoMemberPlan): TObject;
var
  RT: TRttiType;
begin
  RT := FCtx.GetType(APlan.TypeInfo);
  if APlan.ContainerCreate <> nil then
    Result := APlan.ContainerCreate.Invoke(
      TRttiInstanceType(RT).MetaclassType, []).AsObject
  else
    Result := TRttiInstanceType(RT).MetaclassType.Create;
end;

{ ===========================================================================
  WRITING
  =========================================================================== }

{ What TSerializationGraphGuard.Enter returning False means for protobuf. }
procedure RefuseCycle(AObject: TObject);
begin
  raise EProtobufError.CreateFmt(
    '%s is already being written further up the graph: it is a ' +
    'cycle, and protobuf has no back-reference. Break the cycle, or ' +
    'register a Protobuf type serializer that writes a key instead.',
    [AObject.ClassName]);
end;

class function TProtoEngine.WireTypeOf(APlan: TProtoMemberPlan): TProtoWireType;
begin
  case APlan.Kind of
    TProtoMemberKind.MessageValue, TProtoMemberKind.RecordValue,
    TProtoMemberKind.StrValue, TProtoMemberKind.BytesValue,
    TProtoMemberKind.GuidValue, TProtoMemberKind.DateTimeValue,
    TProtoMemberKind.SetValue, TProtoMemberKind.DateValue,
    TProtoMemberKind.TimeValue:
      Exit(TProtoWireType.LengthDelimited);
  end;
  case APlan.Scalar of
    TProtoScalar.Fixed32, TProtoScalar.SFixed32, TProtoScalar.Float:
      Result := TProtoWireType.Fixed32;
    TProtoScalar.Fixed64, TProtoScalar.SFixed64, TProtoScalar.Double:
      Result := TProtoWireType.Fixed64;
    TProtoScalar.Text, TProtoScalar.Bytes:
      Result := TProtoWireType.LengthDelimited;
  else
    Result := TProtoWireType.Varint;
  end;
end;

{ The wire type a field arrived with must be one its member can be read
  from. A reader that took the bytes anyway read a length as a number, or a
  number as a length, and went on reading garbage. A set is a repeated enum,
  so it arrives either way; a nullable is its inner value's wire type; and
  a custom serializer is given whatever came. }
class procedure TProtoEngine.RequireWireType(APlan: TProtoMemberPlan;
  AWireType: TProtoWireType; AFieldNumber: Integer);
var
  P: TProtoMemberPlan;
begin
  P := APlan;
  while (P.Kind = TProtoMemberKind.NullableValue) and (P.Inner <> nil) do
    P := P.Inner;
  case P.Kind of
    TProtoMemberKind.CustomSerializer: Exit;
    TProtoMemberKind.SetValue:
      if AWireType in [TProtoWireType.Varint, TProtoWireType.LengthDelimited] then
        Exit;
  else
    if AWireType = WireTypeOf(P) then Exit;
  end;
  raise EProtobufInputError.CreateFmt(
    'Field %d arrives with wire type %s, and it is declared as a %s, which is ' +
    'written with wire type %s.',
    [AFieldNumber, GetEnumName(System.TypeInfo(TProtoWireType), Ord(AWireType)),
     UTF8ToString(P.TypeInfo.Name),
     GetEnumName(System.TypeInfo(TProtoWireType), Ord(WireTypeOf(P)))]);
end;

{ proto3's implicit presence: a scalar equal to its type's default is not on
  the wire at all, and a reader that does not find it uses the default. A
  member with EXPLICIT presence - a TNullable<T>, a class reference - does
  not go through here; it is written whenever it has a value, default or
  not, which is what explicit presence means. }
function IsPositiveZero(AValue: Double): Boolean;
begin
  Result := PUInt64(@AValue)^ = 0;
end;

class function TProtoEngine.IsDefaultValue(APlan: TProtoMemberPlan;
  const AValue: TValue): Boolean;
begin
  case APlan.Kind of
    TProtoMemberKind.BoolValue: Result := not AValue.AsBoolean;
    TProtoMemberKind.IntValue, TProtoMemberKind.Int64Value:
      Result := TSerializationTypes.Int64Bits(AValue) = 0;
    { Left out only when BOTH defaults agree: this library's reader leaves
      an absent member at ordinal 0, and every other reader takes an absent
      enum to be the value numbered 0. With a registered numbering the two
      can differ, and then the value is written, which is always legal. }
    TProtoMemberKind.EnumValue:
      Result := (AValue.AsOrdinal = 0) and
        ((Length(APlan.EnumNumbers) = 0) or (APlan.EnumNumbers[0] = 0));
    { Only +0.0 is the default. Minus zero compares equal to it and is a
      different value, and the reference implementation writes it: it tests
      the bits. }
    TProtoMemberKind.FloatValue: Result := IsPositiveZero(AValue.AsExtended);
    TProtoMemberKind.CurrencyValue: Result := AValue.AsCurrency = 0;
    TProtoMemberKind.StrValue: Result := AValue.AsString = '';
    TProtoMemberKind.BytesValue: Result := Length(AValue.AsType<TBytes>) = 0;
  else
    Result := False;
  end;
end;

class procedure TProtoEngine.WriteScalarPayload(APlan: TProtoMemberPlan;
  const AValue: TValue; var AWriter: TProtoWriter);
var
  I64: Int64;
  D: Double;
  S: Single;
  Utf8: TBytes;
  G: TGUID;
  Ordinal, Number: Integer;
begin
  case APlan.Kind of
    TProtoMemberKind.BoolValue:
      if AValue.AsBoolean then AWriter.PutVarint(1) else AWriter.PutVarint(0);

    TProtoMemberKind.IntValue, TProtoMemberKind.Int64Value:
      begin
        I64 := TSerializationTypes.Int64Bits(AValue);
        if not ProtoIntegerFits(I64,
             TSerializationTypes.IsUnsignedInteger(APlan.TypeInfo), APlan.Scalar) then
          raise EProtobufError.CreateFmt(
            '%s is not a protobuf %s: the field would carry a different ' +
            'number. Declare the field with a wider scalar.',
            [TSerializationTypes.IntegerText(AValue),
             ProtoScalarName(APlan.Scalar)]);
        case APlan.Scalar of
          TProtoScalar.SInt32: AWriter.PutVarint(ZigZagEncode32(Integer(I64)));
          TProtoScalar.SInt64: AWriter.PutVarint(ZigZagEncode64(I64));
          TProtoScalar.Fixed32, TProtoScalar.SFixed32:
            AWriter.PutFixed32(UInt32(I64));
          TProtoScalar.Fixed64, TProtoScalar.SFixed64:
            AWriter.PutFixed64(UInt64(I64));
          TProtoScalar.UInt32: AWriter.PutVarint(UInt32(I64));
          TProtoScalar.UInt64: AWriter.PutVarint(UInt64(I64));
          TProtoScalar.Int32:
            { An int32 is sign-extended to 64 bits before being written,
              which is why a negative one costs ten bytes. sint32 exists
              precisely to avoid that. }
            AWriter.PutVarint(UInt64(Int64(Integer(I64))));
        else
          AWriter.PutVarint(UInt64(I64));
        end;
      end;

    TProtoMemberKind.EnumValue:
      begin
        Ordinal := Integer(AValue.AsOrdinal);
        Number := Ordinal;
        if (Ordinal >= 0) and (Ordinal <= High(APlan.EnumNumbers)) then
          Number := APlan.EnumNumbers[Ordinal];
        AWriter.PutVarint(UInt64(Int64(Number)));
      end;

    TProtoMemberKind.FloatValue:
      begin
        if APlan.Scalar = TProtoScalar.Float then
        begin
          D := AValue.AsExtended;
          { A Double spelled float that a Single cannot hold is not written
            as infinity. }
          if not (D.IsNan or D.IsInfinity) and (Abs(D) > Single.MaxValue) then
            raise EProtobufError.CreateFmt(
              '%s is beyond what a protobuf float holds. Declare the field ' +
              'double.', [TStructuralText.EncodeFloat(D)]);
          S := D;
          AWriter.PutFixed32(PUInt32(@S)^);
        end
        else
        begin
          D := AValue.AsExtended;
          AWriter.PutFixed64(PUInt64(@D)^);
        end;
      end;

    TProtoMemberKind.CurrencyValue:
      begin
        { The scaled Int64 Delphi actually stores is exact to four decimal
          places with no floating point anywhere near it, so every integral
          spelling carries it unchanged. A floating one is asked for, and is
          then the caller's - or the descriptor's - decision to make. }
        I64 := PInt64(AValue.GetReferenceToRawData)^;
        case APlan.Scalar of
          TProtoScalar.Double:
            begin
              D := AValue.AsCurrency;
              AWriter.PutFixed64(PUInt64(@D)^);
            end;
          TProtoScalar.Float:
            begin
              S := AValue.AsCurrency;
              AWriter.PutFixed32(PUInt32(@S)^);
            end;
          TProtoScalar.Fixed64, TProtoScalar.SFixed64, TProtoScalar.Int64,
          TProtoScalar.UInt64:
            begin
              { An unsigned spelling has no negative amount. }
              if (I64 < 0) and (APlan.Scalar in [TProtoScalar.Fixed64,
                   TProtoScalar.UInt64]) then
                raise EProtobufError.CreateFmt(
                  'The negative amount %s is not a protobuf %s. Declare the ' +
                  'field sint64 or sfixed64.',
                  [CurrToStr(AValue.AsCurrency, TFormatSettings.Invariant),
                   ProtoScalarName(APlan.Scalar)]);
              if APlan.Scalar in [TProtoScalar.Fixed64, TProtoScalar.SFixed64] then
                AWriter.PutFixed64(UInt64(I64))
              else
                AWriter.PutVarint(UInt64(I64));
            end;
        else
          AWriter.PutVarint(ZigZagEncode64(I64));
        end;
      end;

    TProtoMemberKind.StrValue:
      begin
        Utf8 := StringToUtf8Bytes(AValue.AsString);
        AWriter.PutLengthDelimited(Utf8);
      end;

    TProtoMemberKind.BytesValue:
      AWriter.PutLengthDelimited(AValue.AsType<TBytes>);

    TProtoMemberKind.GuidValue:
      begin
        G := AValue.AsType<TGUID>;
        SetLength(Utf8, 16);
        Move(G, Utf8[0], 16);
        AWriter.PutLengthDelimited(Utf8);
      end;

    TProtoMemberKind.DateValue:
      begin
        { Outside the years 1 to 9999 FormatDateTime writes 0000-00-00 or a
          five-digit year, and the reader refuses both. }
        TStructuralText.CheckDateTime(AValue.AsType<TDate>);
        AWriter.PutLengthDelimited(StringToUtf8Bytes(
          FormatDateTime('yyyy"-"mm"-"dd', AValue.AsType<TDate>,
            TFormatSettings.Invariant)));
      end;

    TProtoMemberKind.TimeValue:
      AWriter.PutLengthDelimited(StringToUtf8Bytes(
        FormatDateTime('hh":"nn":"ss"."zzz', AValue.AsType<TTime>,
          TFormatSettings.Invariant)));
  else
    raise EProtobufInternalError.CreateFmt(
      'Cannot write a %s as a protobuf scalar.',
      [GetEnumName(System.TypeInfo(TProtoMemberKind), Ord(APlan.Kind))]);
  end;
end;

class procedure TProtoEngine.WriteSingle(APlan: TProtoMemberPlan;
  ANumber: Integer; const AValue: TValue; var AWriter: TProtoWriter;
  const AOptions: TProtobufSerializationOptions);
var
  Mark: Integer;
  Obj: TObject;
  Raw: Pointer;
  Seconds: Int64;
  Nanos: Integer;
  DT: TDateTime;
  Ms: Int64;
  Custom: TBytes;
  CustomWire: TProtoWireType;
  Elem: TValue;
  I, Ordinal: Integer;
begin
  case APlan.Kind of
    TProtoMemberKind.CustomSerializer:
      begin
        Custom := APlan.Serializer.Serialize(AValue, CustomWire);
        AWriter.PutTag(ANumber, CustomWire);
        if CustomWire = TProtoWireType.LengthDelimited then
          AWriter.PutLengthDelimited(Custom)
        else
          AWriter.PutRaw(Custom);
      end;

    TProtoMemberKind.MessageValue:
      begin
        Obj := AValue.AsObject;
        if Obj = nil then Exit;
        if not TSerializationGraphGuard.Enter(Obj) then RefuseCycle(Obj);
        try
          AWriter.PutTag(ANumber, TProtoWireType.LengthDelimited);
          Mark := AWriter.BeginSubMessage;
          { The message body addresses its instance as an untyped pointer. }
          {$WARN UNSAFE_CAST OFF}
          WriteMessageBody(APlan.BoundPlan, Pointer(Obj), AWriter, AOptions,
            False);
          {$WARN UNSAFE_CAST ON}
          AWriter.EndSubMessage(Mark);
        finally
          TSerializationGraphGuard.Leave(Obj);
        end;
      end;

    { A record counts one level, as an object does. It is a nested message
      on the wire, and the reader counts it as one: uncounted here, a graph
      of objects with records between them was written past what the
      reader takes back, and a record holding an array of itself ran the
      writer out of stack. }
    TProtoMemberKind.RecordValue:
      begin
        TSerializationGraphGuard.EnterLevel;
        try
          AWriter.PutTag(ANumber, TProtoWireType.LengthDelimited);
          Mark := AWriter.BeginSubMessage;
          Raw := AValue.GetReferenceToRawData;
          WriteMessageBody(APlan.BoundPlan, Raw, AWriter, AOptions, False);
          AWriter.EndSubMessage(Mark);
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
      end;

    TProtoMemberKind.DateTimeValue:
      begin
        { google.protobuf.Timestamp: seconds since the Unix epoch in field 1,
          nanoseconds in field 2. The well-known type for an instant, and
          what any other protobuf implementation will expect.

          Through Core, which follows Delphi's encoding: a TDateTime before
          1899-12-30 is a negative day plus a POSITIVE time of day, and the
          linear (DT - UnixDateDelta) * MSecsPerDay put every such instant a
          day early. Outside the years 1 to 9999 it is refused, because no
          reader here takes it back. }
        DT := AValue.AsType<TDateTime>;
        TStructuralText.CheckDateTime(DT);
        if not TStructuralText.TryDateTimeToUnixMillis(DT, Ms) then
          raise ESerializationUnsupported.CreateFmt(
            'The TDateTime %s rounds to an instant after ' +
            '9999-12-31T23:59:59.999, which no reader here accepts back.',
            [FloatToStr(DT, TFormatSettings.Invariant)]);
        Seconds := Ms div MSecsPerSec;
        Nanos := Integer(Ms mod MSecsPerSec) * 1000000;
        if Nanos < 0 then
        begin
          Dec(Seconds);
          Inc(Nanos, 1000000000);
        end;
        AWriter.PutTag(ANumber, TProtoWireType.LengthDelimited);
        Mark := AWriter.BeginSubMessage;
        if Seconds <> 0 then
        begin
          AWriter.PutTag(1, TProtoWireType.Varint);
          AWriter.PutVarint(UInt64(Seconds));
        end;
        if Nanos <> 0 then
        begin
          AWriter.PutTag(2, TProtoWireType.Varint);
          AWriter.PutVarint(UInt64(Int64(Nanos)));
        end;
        AWriter.EndSubMessage(Mark);
      end;

    TProtoMemberKind.SetValue:
      begin
        { A set has no protobuf counterpart, so it takes the idiomatic shape
          for one: a packed repeated enum of the members that are present. }
        AWriter.PutTag(ANumber, TProtoWireType.LengthDelimited);
        Mark := AWriter.BeginSubMessage;
        { Through TSerializationTypes: bit 0 is the byte holding the lowest
          member, not ordinal 0. }
        for I in TSerializationTypes.SetOrdinals(APlan.TypeInfo, AValue) do
          begin
            Ordinal := I;
            if (Ordinal >= 0) and (Ordinal <= High(APlan.SetElemNumbers)) then
              Ordinal := APlan.SetElemNumbers[Ordinal];
            AWriter.PutVarint(UInt64(Int64(Ordinal)));
          end;
        AWriter.EndSubMessage(Mark);
      end;

    TProtoMemberKind.NullableValue:
      begin
        Raw := AValue.GetReferenceToRawData;
        if not APlan.NullableAccess.HasValue(Raw) then Exit;
        Elem := APlan.NullableAccess.GetValue(Raw);
        WriteSingle(APlan.Inner, ANumber, Elem, AWriter, AOptions);
      end;
  else
    AWriter.PutTag(ANumber, WireTypeOf(APlan));
    WriteScalarPayload(APlan, AValue, AWriter);
  end;
end;

{ An external descriptor beats the Delphi type, but only about the root
  message: field numbers are scoped to a message, so the root's field 1 and
  a nested message's field 1 are different fields that happen to share a
  number.

  Only a scalar can be respelled this way. A descriptor that called a nested
  message a string would not be describing this data at all, and quietly
  writing one as the other would be worse than saying nothing. }
class function TProtoEngine.SchemaMember(AFP: TProtoFieldPlan;
  AIsRoot: Boolean; ASchema: TProtobufDescriptorSchema;
  out AOwned: TProtoMemberPlan): TProtoMemberPlan;
var
  Scalar: TProtoScalar;
begin
  AOwned := nil;
  Result := AFP.Member;
  if (not AIsRoot) or (ASchema = nil) then Exit;
  if not (Result.Kind in [TProtoMemberKind.IntValue,
                          TProtoMemberKind.Int64Value,
                          TProtoMemberKind.FloatValue,
                          TProtoMemberKind.CurrencyValue]) then Exit;
  if not ASchema.TryFieldScalar(AFP.Number, Scalar) then Exit;
  if Scalar = Result.Scalar then Exit;
  if not ProtoScalarFits(Result.Kind, Scalar) then
    raise EProtobufError.CreateFmt(
      'The descriptor declares field %d as %s, and %s is a %s, which is not ' +
      'written as one. Correct the descriptor or the member''s type.',
      [AFP.Number, ProtoScalarName(Scalar), AFP.DelphiName,
       UTF8ToString(Result.TypeInfo.Name)]);

  { A plan with nothing owned in it, so freeing it frees nothing else. The
    cached plan is shared between threads and must not be edited in place. }
  AOwned := TProtoMemberPlan.Create;
  AOwned.TypeInfo := Result.TypeInfo;
  AOwned.Kind := Result.Kind;
  AOwned.Scalar := Scalar;
  Result := AOwned;
end;

class procedure TProtoEngine.WriteField(AFP: TProtoFieldPlan;
  const AValue: TValue; var AWriter: TProtoWriter;
  const AOptions: TProtobufSerializationOptions; AIsRoot: Boolean);
var
  Plan, Owned: TProtoMemberPlan;
  Items: TValue;
  Obj: TObject;
  I, Mark: Integer;
  KeyV, ValV, Pair: TValue;
  Pairs: TValue;
begin
  Plan := SchemaMember(AFP, AIsRoot, AOptions.Schema, Owned);
  try
  case Plan.Kind of
    TProtoMemberKind.ArrayValue, TProtoMemberKind.ListValue:
      begin
        { One level for the sequence, whether it has elements or not. A list
          is an object, and is entered as one: that counts its level and
          makes a list that holds itself a cycle. An array is not, and
          counts a level only. }
        Obj := nil;
        if Plan.Kind = TProtoMemberKind.ListValue then
        begin
          Obj := AValue.AsObject;
          if Obj = nil then Exit;
          if not TSerializationGraphGuard.Enter(Obj) then RefuseCycle(Obj);
        end
        else
          TSerializationGraphGuard.EnterLevel;
        try
          if Obj <> nil then
            Items := TSerializationTypes.ListElements(Obj, Plan.ContainerToArray)
          else
            Items := AValue;

          if Items.GetArrayLength = 0 then Exit;

          { A repeated field has no null element. Writing nothing for one made
            the list shorter and moved every element after it. }
          if Plan.Item.Kind = TProtoMemberKind.NullableValue then
            for I := 0 to Integer(Items.GetArrayLength - 1) do
              if not Plan.Item.NullableAccess.HasValue(
                   Items.GetArrayElement(I).GetReferenceToRawData) then
                raise EProtobufError.CreateFmt(
                  'Element %d of %s has no value, and a protobuf repeated ' +
                  'field has no null element. Remove it, or make the ' +
                  'elements a message with an optional field.',
                  [I, AFP.DelphiName]);
          { Nor a nil message: writing nothing for it did the same. }
          if Plan.Item.Kind = TProtoMemberKind.MessageValue then
            for I := 0 to Integer(Items.GetArrayLength - 1) do
              if Items.GetArrayElement(I).AsObject = nil then
                raise EProtobufError.CreateFmt(
                  'Element %d of %s is nil, and a protobuf repeated field has ' +
                  'no null element. Remove it, or make the elements a message ' +
                  'with an optional field.', [I, AFP.DelphiName]);

          { A repeated numeric field goes into one length-delimited run when
            packing is on - proto3's default, and much smaller. A repeated
            message or string cannot be packed and never is. }
          if AOptions.PackRepeated and AFP.Packed_ and Plan.Item.IsPackable and
             (Plan.Item.Kind <> TProtoMemberKind.DateTimeValue) then
          begin
            AWriter.PutTag(AFP.Number, TProtoWireType.LengthDelimited);
            Mark := AWriter.BeginSubMessage;
            for I := 0 to Integer(Items.GetArrayLength - 1) do
              WriteScalarPayload(Plan.Item, Items.GetArrayElement(I), AWriter);
            AWriter.EndSubMessage(Mark);
          end
          else
            for I := 0 to Integer(Items.GetArrayLength - 1) do
              WriteSingle(Plan.Item, AFP.Number, Items.GetArrayElement(I),
                AWriter, AOptions);
        finally
          if Obj <> nil then TSerializationGraphGuard.Leave(Obj)
          else TSerializationGraphGuard.LeaveLevel;
        end;
      end;

    TProtoMemberKind.DictionaryValue:
      begin
        { A protobuf map is a repeated message with key in field 1 and value
          in field 2, and nothing else - the "map" keyword is sugar over
          exactly that.

          The dictionary counts one level, entered as the object it is; the
          entry messages add none, and the reader does not count them. }
        Obj := AValue.AsObject;
        if Obj = nil then Exit;
        if not TSerializationGraphGuard.Enter(Obj) then RefuseCycle(Obj);
        try
          Pairs := Plan.ContainerToArray.Invoke(Obj, []);
          for I := 0 to Integer(Pairs.GetArrayLength - 1) do
          begin
            Pair := Pairs.GetArrayElement(I);
            KeyV := Plan.PairKeyField.GetValue(Pair.GetReferenceToRawData);
            ValV := Plan.PairValueField.GetValue(Pair.GetReferenceToRawData);
            AWriter.PutTag(AFP.Number, TProtoWireType.LengthDelimited);
            Mark := AWriter.BeginSubMessage;
            WriteSingle(Plan.Key, 1, KeyV, AWriter, AOptions);
            WriteSingle(Plan.Value, 2, ValV, AWriter, AOptions);
            AWriter.EndSubMessage(Mark);
          end;
        finally
          TSerializationGraphGuard.Leave(Obj);
        end;
      end;

    TProtoMemberKind.NullableValue, TProtoMemberKind.MessageValue:
      { Explicit presence: written whenever it is there, default or not. }
      WriteSingle(Plan, AFP.Number, AValue, AWriter, AOptions);
  else
    { Implicit presence: a scalar equal to the default is not written, which
      is what proto3 says and what every other implementation expects. }
    if not IsDefaultValue(Plan, AValue) then
      WriteSingle(Plan, AFP.Number, AValue, AWriter, AOptions);
  end;
  finally
    Owned.Free;
  end;
end;

class procedure TProtoEngine.WriteMessageBody(APlan: TProtoTypePlan;
  AInstance: Pointer; var AWriter: TProtoWriter;
  const AOptions: TProtobufSerializationOptions; AIsRoot: Boolean);
var
  FP: TProtoFieldPlan;
  V: TValue;
begin
  for FP in APlan.Fields do
  begin
    if FP.IsUnknownStore then Continue;
    V := ReadMember(FP, AInstance);
    WriteField(FP, V, AWriter, AOptions, AIsRoot);
  end;
  { Fields the schema did not know, put back exactly as they arrived - at
    the end, because protobuf does not care about order and putting them
    back in place would mean remembering where they were. }
  if APlan.UnknownStore <> nil then
    AWriter.PutRaw(ReadMember(APlan.UnknownStore, AInstance).AsType<TBytes>);
end;

{ ===========================================================================
  READING
  =========================================================================== }

class function TProtoEngine.ReadScalar(APlan: TProtoMemberPlan;
  AWireType: TProtoWireType; var AReader: TProtoReader;
  const AExisting: TValue; ADepth: Integer): TValue;
var
  U64: UInt64;
  I64: Int64;
  D: Double;
  S: Single;
  Raw: TBytes;
  G: TGUID;
  Start, Stop: Integer;
  Sub: TProtoReader;
  Obj: TObject;
  Rec: TValue;
  Number, Ordinal: Integer;
  Seconds: Int64;
  Nanos: Integer;
  Instant: TDateTime;
  FieldNo: Integer;
  WT: TProtoWireType;
  Text, Why: string;
  Elem: TValue;
  Ords: TArray<Integer>;
  Unsigned: Boolean;
begin
  case APlan.Kind of
    TProtoMemberKind.CustomSerializer:
      begin
        if AWireType = TProtoWireType.LengthDelimited then
          Raw := AReader.ReadLengthDelimited
        else
        begin
          Start := AReader.FPos;
          AReader.SkipField(Start, 0, AWireType, ADepth);
          SetLength(Raw, AReader.FPos - Start);
          if Length(Raw) > 0 then
            Move(AReader.FData[Start], Raw[0], Length(Raw));
        end;
        Exit(APlan.Serializer.Deserialize(Raw, AWireType, APlan.TypeInfo,
          AExisting));
      end;

    TProtoMemberKind.BoolValue:
      Exit(TValue.From<Boolean>(AReader.ReadVarint <> 0));

    TProtoMemberKind.IntValue, TProtoMemberKind.Int64Value:
      begin
        { The number the SCALAR says the bits are - signed or unsigned -
          and then range-checked against the member's own type. A fixed64
          of 2^63 is not Low(Int64), and FromOrdinal made a Byte out of 300
          and raised on a Comp, which is no ordinal. }
        Unsigned := APlan.Scalar in [TProtoScalar.UInt32, TProtoScalar.UInt64,
          TProtoScalar.Fixed32, TProtoScalar.Fixed64];
        I64 := 0;
        U64 := 0;
        case APlan.Scalar of
          TProtoScalar.SInt32: I64 := ZigZagDecode32(UInt32(AReader.ReadVarint));
          TProtoScalar.SInt64: I64 := ZigZagDecode64(AReader.ReadVarint);
          TProtoScalar.Fixed32: U64 := AReader.ReadFixed32;
          TProtoScalar.SFixed32: I64 := Integer(AReader.ReadFixed32);
          TProtoScalar.Fixed64: U64 := AReader.ReadFixed64;
          TProtoScalar.SFixed64: I64 := Int64(AReader.ReadFixed64);
          TProtoScalar.Int32: I64 := Integer(UInt32(AReader.ReadVarint));
          TProtoScalar.UInt32: U64 := UInt32(AReader.ReadVarint);
          TProtoScalar.UInt64: U64 := AReader.ReadVarint;
        else
          I64 := Int64(AReader.ReadVarint);
        end;
        if Unsigned then
        begin
          if not TSerializationTypes.TryIntegerFromUInt64(APlan.TypeInfo,
               U64, Result) then
            raise EProtobufInputError.CreateFmt('%s does not fit in %s.',
              [UIntToStr(U64), UTF8ToString(APlan.TypeInfo.Name)]);
        end
        else if not TSerializationTypes.TryIntegerFromInt64(APlan.TypeInfo,
                  I64, Result) then
          raise EProtobufInputError.CreateFmt('%d does not fit in %s.',
            [I64, UTF8ToString(APlan.TypeInfo.Name)]);
        Exit;
      end;

    { Range-checked whether or not the type has a registered numbering: an
      unnumbered enum's ordinal IS its number, and one it does not have is
      no value of the type. }
    TProtoMemberKind.EnumValue:
      begin
        Number := Integer(Int64(AReader.ReadVarint));
        if not ProtoEnumOrdinal(APlan.TypeInfo, APlan.EnumNumbers, Number,
             Ordinal) then
          raise EProtobufInputError.CreateFmt(
            'Enumeration value %d is not one %s declares.',
            [Number, UTF8ToString(APlan.TypeInfo.Name)]);
        Exit(TValue.FromOrdinal(APlan.TypeInfo, Ordinal));
      end;

    { Into the member's own width, checked: a Single does not become
      infinity for a double it cannot hold. }
    TProtoMemberKind.FloatValue:
      begin
        if APlan.Scalar = TProtoScalar.Float then
        begin
          U64 := AReader.ReadFixed32;
          S := PSingle(@U64)^;
          D := S;
        end
        else
        begin
          U64 := AReader.ReadFixed64;
          D := PDouble(@U64)^;
        end;
        if not TSerializationTypes.TryFloatFromDouble(APlan.TypeInfo, D,
             Result, Why) then
          raise EProtobufInputError.CreateFmt('%s: %s.',
            [UTF8ToString(APlan.TypeInfo.Name), Why]);
        Exit;
      end;

    TProtoMemberKind.CurrencyValue:
      begin
        case APlan.Scalar of
          { Checked: NaN or 1e300 must not become -922337203685477.5808. }
          TProtoScalar.Double, TProtoScalar.Float:
            begin
              if APlan.Scalar = TProtoScalar.Float then
              begin
                U64 := AReader.ReadFixed32;
                S := PSingle(@U64)^;
                D := S;
              end
              else
              begin
                U64 := AReader.ReadFixed64;
                D := PDouble(@U64)^;
              end;
              if not TSerializationTypes.TryFloatFromDouble(APlan.TypeInfo,
                   D, Result, Why) then
                raise EProtobufInputError.Create(Why + '.');
              Exit;
            end;
          TProtoScalar.Fixed64, TProtoScalar.SFixed64:
            I64 := Int64(AReader.ReadFixed64);
          TProtoScalar.Int64, TProtoScalar.UInt64:
            I64 := Int64(AReader.ReadVarint);
        else
          I64 := ZigZagDecode64(AReader.ReadVarint);
        end;
        { The bits back into the scaled Int64 they came out of, rather than
          through a floating assignment that would round them. }
        Exit(TValue.From<Currency>(PCurrency(@I64)^));
      end;

    TProtoMemberKind.StrValue:
      begin
        Text := ProtoUtf8Text(AReader.ReadLengthDelimited);
        if not TSerializationTypes.TryStringFromText(APlan.TypeInfo, Text,
             Result, Why) then
          raise EProtobufInputError.Create(Why + '.');
        Exit;
      end;

    TProtoMemberKind.BytesValue:
      Exit(TValue.From<TBytes>(AReader.ReadLengthDelimited));

    TProtoMemberKind.GuidValue:
      begin
        Raw := AReader.ReadLengthDelimited;
        if Length(Raw) <> 16 then
          raise EProtobufInputError.CreateFmt(
            'A GUID is 16 bytes; this one is %d.', [Length(Raw)]);
        Move(Raw[0], G, 16);
        Exit(TValue.From<TGUID>(G));
      end;

    TProtoMemberKind.DateValue:
      begin
        Text := ProtoUtf8Text(AReader.ReadLengthDelimited);
        Exit(TValue.From<TDate>(ParseIsoDate(Text)));
      end;

    TProtoMemberKind.TimeValue:
      begin
        Text := ProtoUtf8Text(AReader.ReadLengthDelimited);
        Exit(TValue.From<TTime>(ParseIsoTime(Text)));
      end;

    TProtoMemberKind.DateTimeValue:
      begin
        AReader.ReadLengthBounds(Start, Stop);
        Sub.Init(AReader.FData, Start, Stop);
        Seconds := 0;
        Nanos := 0;
        while Sub.ReadTag(FieldNo, WT) do
          case FieldNo of
            1: Seconds := Int64(Sub.ReadVarint);
            2: Nanos := Integer(Int64(Sub.ReadVarint));
          else
            Sub.SkipField(Sub.FPos, FieldNo, WT, ADepth + 1);
          end;
        { Through Core, range-checked and right before 1899-12-30: the linear
          UnixDateDelta + Ms / MSecsPerDay read a correct instant there a day
          late, and took a count past year 9999 as some other date. The
          seconds are checked first, so the milliseconds cannot overflow. }
        if not TStructuralText.TryUnixSecondsToDateTime(Seconds, Instant) or
           not TStructuralText.TryUnixMillisToDateTime(
             Seconds * MSecsPerSec + Nanos div 1000000, Instant) then
          raise EProtobufInputError.CreateFmt(
            'A google.protobuf.Timestamp of %d seconds and %d nanoseconds is ' +
            'outside the years 1 to 9999, which a TDateTime holds.',
            [Seconds, Nanos]);
        Exit(TValue.From<TDateTime>(Instant));
      end;

    TProtoMemberKind.SetValue:
      begin
        { A set is a repeated enum, and a repeated field arrives in either
          spelling - one packed run, or one element per field - and in as
          many pieces as the writer liked. What an earlier piece of THIS
          message delivered comes in as AExisting (ReadMessageBody passes it
          only then), and the set is the union of the pieces. }
        Ords := nil;
        if not AExisting.IsEmpty then
          Ords := TSerializationTypes.SetOrdinals(APlan.TypeInfo, AExisting);
        if AWireType = TProtoWireType.Varint then
        begin
          Number := Integer(Int64(AReader.ReadVarint));
          if not ProtoEnumOrdinal(APlan.SetElemTypeInfo, APlan.SetElemNumbers,
               Number, Ordinal) then
            raise EProtobufInputError.CreateFmt(
              'Set element %d is not one this type declares.', [Number]);
          Ords := Ords + [Ordinal];
        end
        else
        begin
          AReader.ReadLengthBounds(Start, Stop);
          Sub.Init(AReader.FData, Start, Stop);
          while not Sub.AtEnd do
          begin
            Number := Integer(Int64(Sub.ReadVarint));
            if not ProtoEnumOrdinal(APlan.SetElemTypeInfo, APlan.SetElemNumbers,
                 Number, Ordinal) then
              raise EProtobufInputError.CreateFmt(
                'Set element %d is not one this type declares.', [Number]);
            Ords := Ords + [Ordinal];
          end;
        end;
        if not TSerializationTypes.TryMakeSet(APlan.TypeInfo, Ords, Result,
             Why) then
          raise EProtobufInputError.CreateFmt('Not a %s: %s.',
            [UTF8ToString(APlan.TypeInfo.Name), Why]);
        Exit;
      end;

    TProtoMemberKind.MessageValue:
      begin
        AReader.ReadLengthBounds(Start, Stop);
        Sub.Init(AReader.FData, Start, Stop);
        { An instance that is already there is filled in place - the same
          reuse rule the rest of the library follows - and only a nil one is
          constructed. }
        if (not AExisting.IsEmpty) and (AExisting.AsObject <> nil) then
          Obj := AExisting.AsObject
        else
          Obj := NewInstanceOf(APlan.BoundPlan);
        try
          { The message body addresses its instance as an untyped pointer. }
          {$WARN UNSAFE_CAST OFF}
          ReadMessageBody(APlan.BoundPlan, Pointer(Obj), Sub, ADepth + 1);
          {$WARN UNSAFE_CAST ON}
        except
          if (AExisting.IsEmpty) or (AExisting.AsObject = nil) then Obj.Free;
          raise;
        end;
        Exit(TValue.From<TObject>(Obj).Cast(APlan.TypeInfo));
      end;

    TProtoMemberKind.RecordValue:
      begin
        AReader.ReadLengthBounds(Start, Stop);
        Sub.Init(AReader.FData, Start, Stop);
        { Filled from the member's current value, in a COPY of it: a TValue
          copied by assignment shares its buffer, and filling that would
          leave nothing to tell what this read built from what was there.
          On failure the objects the read built into the record are freed -
          a record has no destructor to do it - and the ones it found there,
          filled in place, are not. }
        if AExisting.IsEmpty then TValue.Make(nil, APlan.TypeInfo, Rec)
        else TValue.Make(AExisting.GetReferenceToRawData, APlan.TypeInfo, Rec);
        try
          ReadMessageBody(APlan.BoundPlan, Rec.GetReferenceToRawData, Sub,
            ADepth + 1);
        except
          TSerializationOwnership.ReleaseBuilt(APlan.TypeInfo, Rec, AExisting);
          raise;
        end;
        Exit(Rec);
      end;

    TProtoMemberKind.NullableValue:
      begin
        Elem := ReadScalar(APlan.Inner, AWireType, AReader, TValue.Empty,
          ADepth);
        Result := AExisting;
        if Result.IsEmpty then TValue.Make(nil, APlan.TypeInfo, Result);
        APlan.NullableAccess.SetValue(Result.GetReferenceToRawData, Elem);
        Exit;
      end;
  end;

  raise EProtobufInternalError.CreateFmt('Cannot read a %s.',
    [GetEnumName(System.TypeInfo(TProtoMemberKind), Ord(APlan.Kind))]);
end;

{ What a container raises while the reader adds to it is refused with this
  format's input error, naming the container - a sorted TStringList with
  Duplicates = dupError refuses a repeated line with EStringListError, and a
  caller who asked protobuf to read should not have to catch the RTL's
  exception. What the read built for the add that failed is freed first. }
procedure AddListElement(APlan: TProtoMemberPlan; AContainer: TObject;
  const AElement: TValue);
begin
  try
    APlan.ContainerAdd.Invoke(AContainer, [AElement]);
  except
    on E: Exception do
    begin
      TSerializationOwnership.ReleaseBuilt(APlan.Item.TypeInfo, AElement,
        TValue.Empty);
      if string(E.UnitName).StartsWith('PascalForge.') then raise;
      raise EProtobufInputError.CreateFmt(
        'The %s refused an element the document holds: %s',
        [AContainer.ClassName, E.Message]);
    end;
  end;
end;

{ A map entry into the dictionary this read is filling. A key the document
  repeats replaces the earlier entry, as the specification says, and the
  key and value the read built for that one are released rather than
  orphaned - a TDictionary<K,TObj> owns nothing. }
procedure AddMapEntry(APlan: TProtoMemberPlan; AContainer: TObject;
  const AKey, AValue: TValue);
begin
  try
    if APlan.HasDictAccess then
      TSerializationOwnership.AddOrSetBuilt(APlan.DictAccess, AContainer,
        AKey, AValue)
    else
      APlan.ContainerAdd.Invoke(AContainer, [AKey, AValue]);
  except
    on E: Exception do
    begin
      TSerializationOwnership.ReleaseBuilt(APlan.Key.TypeInfo, AKey,
        TValue.Empty);
      TSerializationOwnership.ReleaseBuilt(APlan.Value.TypeInfo, AValue,
        TValue.Empty);
      if string(E.UnitName).StartsWith('PascalForge.') then raise;
      raise EProtobufInputError.CreateFmt(
        'The %s refused an element the document holds: %s',
        [AContainer.ClassName, E.Message]);
    end;
  end;
end;

class procedure TProtoEngine.ReadRepeated(AFP: TProtoFieldPlan;
  AInstance: Pointer; AWireType: TProtoWireType; var AReader: TProtoReader;
  ADepth: Integer);
var
  Plan: TProtoMemberPlan;
  Existing: TValue;
  Obj: TObject;
  Start, Stop: Integer;
  Sub: TProtoReader;
  Elem: TValue;
  Arr: TValue;
  Len, Index: Integer;
  Grown: array of TValue;
begin
  Plan := AFP.Member;

  if Plan.Kind = TProtoMemberKind.ListValue then
  begin
    Existing := ReadMember(AFP, AInstance);
    Obj := nil;
    if not Existing.IsEmpty then Obj := Existing.AsObject;
    if Obj = nil then
    begin
      Obj := NewContainer(Plan);
      StoreMember(AFP, AInstance, TValue.From<TObject>(Obj).Cast(Plan.TypeInfo));
    end;

    { A reader must accept BOTH spellings of a repeated field whatever the
      schema says, because the specification requires it: packed and
      unpacked are the same field. }
    if (AWireType = TProtoWireType.LengthDelimited) and Plan.Item.IsPackable then
    begin
      AReader.ReadLengthBounds(Start, Stop);
      Sub.Init(AReader.FData, Start, Stop);
      while not Sub.AtEnd do
      begin
        Elem := ReadScalar(Plan.Item, WireTypeOf(Plan.Item), Sub,
          TValue.Empty, ADepth);
        AddListElement(Plan, Obj, Elem);
      end;
    end
    else
    begin
      RequireWireType(Plan.Item, AWireType, AFP.Number);
      Elem := ReadScalar(Plan.Item, AWireType, AReader, TValue.Empty, ADepth);
      AddListElement(Plan, Obj, Elem);
    end;
    Exit;
  end;

  { A DYNAMIC ARRAY grows by whatever this field contributed. A packed run
    contributes all of its elements at once; an unpacked field contributes
    one, and a message with many of them rebuilds the array each time. That
    is quadratic in the element count, and it is the price of a Delphi
    dynamic array being immutable in a TValue - a TList<T> member has no
    such cost and is the better choice for a large repeated field. }
  Arr := ReadMember(AFP, AInstance);
  Len := 0;
  if not Arr.IsEmpty then Len := Integer(Arr.GetArrayLength);
  SetLength(Grown, Len);
  for Index := 0 to Len - 1 do Grown[Index] := Arr.GetArrayElement(Index);

  if (AWireType = TProtoWireType.LengthDelimited) and Plan.Item.IsPackable then
  begin
    AReader.ReadLengthBounds(Start, Stop);
    Sub.Init(AReader.FData, Start, Stop);
    while not Sub.AtEnd do
    begin
      Elem := ReadScalar(Plan.Item, WireTypeOf(Plan.Item), Sub, TValue.Empty,
        ADepth);
      SetLength(Grown, Length(Grown) + 1);
      Grown[High(Grown)] := Elem;
    end;
  end
  else
  begin
    RequireWireType(Plan.Item, AWireType, AFP.Number);
    Elem := ReadScalar(Plan.Item, AWireType, AReader, TValue.Empty, ADepth);
    SetLength(Grown, Length(Grown) + 1);
    Grown[High(Grown)] := Elem;
  end;
  StoreMember(AFP, AInstance, TValue.FromArray(Plan.TypeInfo, Grown));
end;

class procedure TProtoEngine.ReadMapEntry(AFP: TProtoFieldPlan;
  AInstance: Pointer; var AReader: TProtoReader; ADepth: Integer);
var
  Plan: TProtoMemberPlan;
  Existing: TValue;
  Obj: TObject;
  Start, Stop, FieldNo: Integer;
  Sub: TProtoReader;
  WT: TProtoWireType;
  KeyV, ValV, Elem: TValue;
begin
  Plan := AFP.Member;
  Existing := ReadMember(AFP, AInstance);
  Obj := nil;
  if not Existing.IsEmpty then Obj := Existing.AsObject;
  if Obj = nil then
  begin
    Obj := NewContainer(Plan);
    StoreMember(AFP, AInstance, TValue.From<TObject>(Obj).Cast(Plan.TypeInfo));
  end;

  AReader.ReadLengthBounds(Start, Stop);
  Sub.Init(AReader.FData, Start, Stop);
  { A map entry whose key or value is absent uses that type's default, which
    is what the specification says rather than an error. }
  TValue.Make(nil, Plan.Key.TypeInfo, KeyV);
  TValue.Make(nil, Plan.Value.TypeInfo, ValV);
  { What the entry built is this read's until the dictionary holds it: a key
    or value that comes twice in one entry - the last one wins - frees the
    earlier one, and a failure part way through frees both. }
  try
    while Sub.ReadTag(FieldNo, WT) do
      case FieldNo of
        1:
          begin
            RequireWireType(Plan.Key, WT, 1);
            Elem := ReadScalar(Plan.Key, WT, Sub, TValue.Empty, ADepth);
            TSerializationOwnership.ReleaseBuilt(Plan.Key.TypeInfo, KeyV,
              TValue.Empty);
            KeyV := Elem;
          end;
        2:
          begin
            RequireWireType(Plan.Value, WT, 2);
            Elem := ReadScalar(Plan.Value, WT, Sub, TValue.Empty, ADepth);
            TSerializationOwnership.ReleaseBuilt(Plan.Value.TypeInfo, ValV,
              TValue.Empty);
            ValV := Elem;
          end;
      else
        Sub.SkipField(Sub.FPos, FieldNo, WT, ADepth + 1);
      end;
  except
    TSerializationOwnership.ReleaseBuilt(Plan.Key.TypeInfo, KeyV, TValue.Empty);
    TSerializationOwnership.ReleaseBuilt(Plan.Value.TypeInfo, ValV,
      TValue.Empty);
    raise;
  end;
  AddMapEntry(Plan, Obj, KeyV, ValV);
end;

class procedure TProtoEngine.ClearOneOfSiblings(APlan: TProtoTypePlan;
  AInstance: Pointer; ANumber: Integer);
var
  Pair: TPair<string, TList<Integer>>;
  Other, Index: Integer;
  FP: TProtoFieldPlan;
  Empty: TValue;
begin
  for Pair in APlan.OneOfs do
  begin
    if Pair.Value.IndexOf(ANumber) < 0 then Continue;
    for Other in Pair.Value do
    begin
      if Other = ANumber then Continue;
      if not APlan.ByNumber.TryGetValue(Other, Index) then Continue;
      FP := APlan.Fields[Index];
      { Exactly one member of a oneof is set at a time, so the arrival of
        one clears the rest. }
      TValue.Make(nil, FP.Member.TypeInfo, Empty);
      StoreMember(FP, AInstance, Empty);
    end;
  end;
end;

{ One occurrence of a static array's repeated field - a packed run of many
  elements or one unpacked element - added to what this message has
  delivered for it so far. }
class procedure TProtoEngine.CollectStatic(AFP: TProtoFieldPlan;
  AIndex: Integer; AWireType: TProtoWireType; var AReader: TProtoReader;
  ADepth: Integer; AStatics: TObjectDictionary<Integer, TList<TValue>>);
var
  Plan: TProtoMemberPlan;
  List: TList<TValue>;
  Start, Stop: Integer;
  Sub: TProtoReader;
begin
  Plan := AFP.Member;
  if not AStatics.TryGetValue(AIndex, List) then
  begin
    List := TList<TValue>.Create;
    AStatics.Add(AIndex, List);
  end;
  if (AWireType = TProtoWireType.LengthDelimited) and Plan.Item.IsPackable then
  begin
    AReader.ReadLengthBounds(Start, Stop);
    Sub.Init(AReader.FData, Start, Stop);
    while not Sub.AtEnd do
      List.Add(ReadScalar(Plan.Item, WireTypeOf(Plan.Item), Sub, TValue.Empty,
        ADepth));
  end
  else
  begin
    RequireWireType(Plan.Item, AWireType, AFP.Number);
    List.Add(ReadScalar(Plan.Item, AWireType, AReader, TValue.Empty, ADepth));
  end;
end;

{ What a failed read leaves behind in the collected static-array elements:
  the messages it constructed for them, and the objects inside the records
  it read for them, which nothing else refers to yet. }
procedure FreeCollectedStatics(APlan: TProtoTypePlan;
  AStatics: TObjectDictionary<Integer, TList<TValue>>);
var
  Collected: TPair<Integer, TList<TValue>>;
begin
  if AStatics = nil then Exit;
  for Collected in AStatics do
  begin
    TSerializationOwnership.ReleaseBuiltElements(
      APlan.Fields[Collected.Key].Member.Item.TypeInfo,
      Collected.Value.ToArray);
    Collected.Value.Clear;
  end;
end;

class procedure TProtoEngine.ReadMessageBody(APlan: TProtoTypePlan;
  AInstance: Pointer; var AReader: TProtoReader; ADepth: Integer);
var
  FieldNo, Index, TagStart: Integer;
  WT: TProtoWireType;
  FP: TProtoFieldPlan;
  Member, Owned: TProtoMemberPlan;
  Existing, V: TValue;
  Unknown, Store: TBytes;
  Statics: TObjectDictionary<Integer, TList<TValue>>;
  Collected: TPair<Integer, TList<TValue>>;
  Why: string;
  SetSeen: TArray<Boolean>;
begin
  Statics := nil;
  if ADepth > PROTO_MAX_DEPTH then
    AReader.Fail(Format('Messages nested more than %d deep', [PROTO_MAX_DEPTH]));

  Unknown := nil;
  try
  while True do
  begin
    TagStart := AReader.FPos;
    if not AReader.ReadTag(FieldNo, WT) then Break;
    if WT = TProtoWireType.EndGroup then
      AReader.Fail(Format('A group end tag for field %d with no start',
        [FieldNo]));

    if not APlan.ByNumber.TryGetValue(FieldNo, Index) then
    begin
      { proto3 says a reader keeps what it does not understand. It can only
        do that if the message says where to put it. }
      Store := AReader.SkipField(TagStart, FieldNo, WT, ADepth);
      if APlan.UnknownStore <> nil then
        Unknown := Concat(Unknown, Store);
      Continue;
    end;

    FP := APlan.Fields[Index];
    if FP.OneOf <> '' then ClearOneOfSiblings(APlan, AInstance, FieldNo);

    case FP.Member.Kind of
      TProtoMemberKind.ArrayValue:
        if FP.Member.TypeInfo.Kind = tkArray then
        begin
          if Statics = nil then
            Statics := TObjectDictionary<Integer, TList<TValue>>.Create([doOwnsValues]);
          CollectStatic(FP, Index, WT, AReader, ADepth, Statics);
        end
        else
          ReadRepeated(FP, AInstance, WT, AReader, ADepth);
      TProtoMemberKind.ListValue:
        ReadRepeated(FP, AInstance, WT, AReader, ADepth);
      TProtoMemberKind.DictionaryValue:
        ReadMapEntry(FP, AInstance, AReader, ADepth);
    else
      Existing := ReadMember(FP, AInstance);
      { A set's first piece in this message replaces what the member held;
        each later piece adds to it. See ReadScalar. }
      if FP.Member.Kind = TProtoMemberKind.SetValue then
      begin
        if Length(SetSeen) = 0 then SetLength(SetSeen, APlan.Fields.Count);
        if not SetSeen[Index] then Existing := TValue.Empty;
        SetSeen[Index] := True;
      end;
      Member := SchemaMember(FP, ADepth = 0, GReadSchema, Owned);
      try
        RequireWireType(Member, WT, FieldNo);
        V := ReadScalar(Member, WT, AReader, Existing, ADepth);
      finally
        Owned.Free;
      end;
      StoreMember(FP, AInstance, V);
    end;
  end;

  if (APlan.UnknownStore <> nil) and (Length(Unknown) > 0) then
    StoreMember(APlan.UnknownStore, AInstance, TValue.From<TBytes>(Unknown));

  { A static array is stored once, whole, and only with exactly as many
    elements as its type has. Once stored, its elements belong to the
    instance, and a later failure must not free them. }
  if Statics <> nil then
    for Collected in Statics do
    begin
      FP := APlan.Fields[Collected.Key];
      if not TSerializationTypes.TryMakeArray(FP.Member.TypeInfo,
           Collected.Value.ToArray, V, Why) then
        raise EProtobufInputError.CreateFmt('%s: %s.', [FP.DelphiName, Why]);
      StoreMember(FP, AInstance, V);
      Collected.Value.Clear;
    end;
  except
    { The dictionary is freed either way; the messages collected for a
      static array that was never stored are this read's to free. }
    FreeCollectedStatics(APlan, Statics);
    Statics.Free;
    raise;
  end;
  Statics.Free;
end;

{ ===========================================================================
  THE ROOTS
  =========================================================================== }

class function TProtoEngine.SerializeRoot(ATypeInfo: PTypeInfo;
  const AValue: TValue;
  const AOptions: TProtobufSerializationOptions): TBytes;
var
  Plan: TProtoMemberPlan;
  Writer: TProtoWriter;
  Obj: TObject;
  Mark: Integer;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  Plan := GetRootPlan(ATypeInfo);
  if not (Plan.Kind in [TProtoMemberKind.MessageValue,
                        TProtoMemberKind.RecordValue]) then
    raise EProtobufInternalError.CreateFmt(
      'A protobuf document is a message. %s is not one - protobuf has no ' +
      'top-level scalars and no top-level arrays, so there is nothing for ' +
      'this to be. Wrap it in a class or a record with field numbers.',
      [UTF8ToString(ATypeInfo.Name)]);

  Writer.Init;
  { THE ROOT COUNTS ONE LEVEL TOO, object or record, exactly as it would one
    level down; not entering it let a 65-object chain through. And the level
    this write started from comes back however it ends, so a failure deep in
    one write cannot leave the next on this thread starting part way down. }
  Mark := TSerializationGraphGuard.Level;
  try
    if Plan.Kind = TProtoMemberKind.MessageValue then
    begin
      Obj := AValue.AsObject;
      if Obj = nil then Exit(nil);
      if not TSerializationGraphGuard.Enter(Obj) then RefuseCycle(Obj);
      try
        { The message body addresses its instance as an untyped pointer. }
        {$WARN UNSAFE_CAST OFF}
        WriteMessageBody(Plan.BoundPlan, Pointer(Obj), Writer, AOptions, True);
        {$WARN UNSAFE_CAST ON}
      finally
        TSerializationGraphGuard.Leave(Obj);
      end;
    end
    else
    begin
      TSerializationGraphGuard.EnterLevel;
      try
        WriteMessageBody(Plan.BoundPlan, AValue.GetReferenceToRawData, Writer,
          AOptions, True);
      finally
        TSerializationGraphGuard.LeaveLevel;
      end;
    end;
  finally
    TSerializationGraphGuard.RestoreLevel(Mark);
  end;
  Result := Writer.Done;
end;

class function TProtoEngine.DeserializeRoot(ATypeInfo: PTypeInfo;
  const AData: TBytes; const AExisting: TValue): TValue;
var
  Plan: TProtoMemberPlan;
  Reader: TProtoReader;
  Obj: TObject;
  Rec: TValue;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  Plan := GetRootPlan(ATypeInfo);
  if not (Plan.Kind in [TProtoMemberKind.MessageValue,
                        TProtoMemberKind.RecordValue]) then
    raise EProtobufInternalError.CreateFmt(
      'A protobuf document is a message. %s is not one.',
      [UTF8ToString(ATypeInfo.Name)]);

  Reader.InitWhole(AData);

  if Plan.Kind = TProtoMemberKind.MessageValue then
  begin
    if (not AExisting.IsEmpty) and (AExisting.AsObject <> nil) then
      Obj := AExisting.AsObject
    else
      Obj := NewInstanceOf(Plan.BoundPlan);
    try
      { The message body addresses its instance as an untyped pointer. }
      {$WARN UNSAFE_CAST OFF}
      ReadMessageBody(Plan.BoundPlan, Pointer(Obj), Reader, 0);
      {$WARN UNSAFE_CAST ON}
    except
      if AExisting.IsEmpty or (AExisting.AsObject = nil) then Obj.Free;
      raise;
    end;
    Exit(TValue.From<TObject>(Obj).Cast(ATypeInfo));
  end;

  { A copy, and released on failure, for the reason given in ReadScalar. }
  if AExisting.IsEmpty then TValue.Make(nil, ATypeInfo, Rec)
  else TValue.Make(AExisting.GetReferenceToRawData, ATypeInfo, Rec);
  try
    ReadMessageBody(Plan.BoundPlan, Rec.GetReferenceToRawData, Reader, 0);
  except
    TSerializationOwnership.ReleaseBuilt(ATypeInfo, Rec, AExisting);
    raise;
  end;
  Result := Rec;
end;

class function TProtoEngine.DeserializeRoot(ATypeInfo: PTypeInfo;
  const AData: TBytes; const AExisting: TValue;
  const AOptions: TProtobufSerializationOptions): TValue;
var
  Saved: TProtobufDescriptorSchema;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  { Saved and restored rather than simply cleared, so that a custom value
    serializer which itself deserializes a message leaves this thread's
    outer read exactly as it found it. }
  Saved := GReadSchema;
  GReadSchema := AOptions.Schema;
  try
    Result := DeserializeRoot(ATypeInfo, AData, AExisting);
  finally
    GReadSchema := Saved;
  end;
end;

{ The unrecognized fields of the OUTERMOST message, tags included.

  A second pass over the same bytes rather than a hook inside
  ReadMessageBody: the first pass has already proved the message well
  formed, so this one cannot fail on input the first accepted, and the
  reader stays a plain reader with no collecting apparatus threaded through
  it for a case most callers do not use. }
class function TProtoEngine.CollectRootUnknown(APlan: TProtoTypePlan;
  const AData: TBytes): TBytes;
var
  Reader: TProtoReader;
  FieldNo, TagStart: Integer;
  WT: TProtoWireType;
  Field: TBytes;
begin
  Result := nil;
  Reader.InitWhole(AData);
  while True do
  begin
    TagStart := Reader.FPos;
    if not Reader.ReadTag(FieldNo, WT) then Break;
    Field := Reader.SkipField(TagStart, FieldNo, WT, 0);
    if not APlan.ByNumber.ContainsKey(FieldNo) then
      Result := Concat(Result, Field);
  end;
end;

class function TProtoEngine.DeserializeRootKeepingUnknown(ATypeInfo: PTypeInfo;
  const AData: TBytes; const AOptions: TProtobufSerializationOptions;
  out AUnknown: TBytes): TValue;
var
  Plan: TProtoMemberPlan;
begin
  AUnknown := nil;
  Result := DeserializeRoot(ATypeInfo, AData, TValue.Empty, AOptions);
  Plan := GetRootPlan(ATypeInfo);
  { A type with a [ProtoUnknown] member already holds them, and handing the
    caller a second copy would put them on the wire twice. }
  if (Plan.BoundPlan <> nil) and (Plan.BoundPlan.UnknownStore = nil) then
    AUnknown := CollectRootUnknown(Plan.BoundPlan, AData);
end;

class function TProtoEngine.SerializeRootWithUnknown(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AUnknown: TBytes;
  const AOptions: TProtobufSerializationOptions): TBytes;
begin
  { After the known fields, because protobuf defines no order among fields
    and remembering where each unknown one had been would mean carrying a
    position the envelope does not have. }
  Result := Concat(SerializeRoot(ATypeInfo, AValue, AOptions), AUnknown);
end;

class function TProtoEngine.FromPayload(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): TBytes;
var
  V: TValue;
begin
  V := TSerializationFormats.Require(AFrom,
    TSerializationFormatCapability.ContractDeserialize).DeserializeTyped(
    ATypeInfo, ASource);
  try
    Result := SerializeRoot(ATypeInfo, V,
      TProtobufSerializationOptions.Default);
  finally
    { The intermediate belongs to this call. }
    TSerializationOwnership.Release(ATypeInfo, V);
  end;
end;

end.
