{*******************************************************************************
  PascalForge.Bson.Internal

  INTERNAL IMPLEMENTATION UNIT - applications should not use this unit directly.

  Implements the BSON engine: reader, writer and the plan-based contract engine.
  Exposed through the public facade PascalForge.Bson (TBsonSerializer).

  Registration
    Format registration lives in PascalForge.Bson.Registration and is explicit.

  Documentation
    docs/formats/bson.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Bson.Internal;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  The BSON engine.

  Not public API. Use TBsonSerializer.

  Three parts, in the order they appear below:

    1. a reader   - BSON bytes -> TBsonValue tree
    2. a writer   - TBsonValue tree -> BSON bytes
    3. the engine - Delphi value <-> TBsonValue tree, through cached plans

  The engine talks to BSON and to Delphi and to nothing else. It has no
  reference to PascalForge.Json, to PascalForge.Xml, or to any other format:
  the only way another format enters this unit is through the registry in
  PascalForge.Serialization.Core, by TSerializationFormat, at run time.

  Nothing here goes through JSON text. An int32 is written as an int32 and
  read back as one; a timestamp is a BSON datetime; a GUID is binary subtype
  4. Routing through another format's text would lose every one of those
  distinctions, which is the whole reason BSON exists.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.SyncObjs, System.DateUtils, System.Math, System.Variants,
  System.Generics.Collections,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Serialization.Internal,
  PascalForge.Bson;

const
  { Every element type the BSON specification defines. All of them are read
    and all of them are written; see docs\bson-compatibility.md. }
  BSON_DOUBLE     = $01;
  BSON_STRING     = $02;
  BSON_DOCUMENT   = $03;
  BSON_ARRAY      = $04;
  BSON_BINARY     = $05;
  BSON_UNDEFINED  = $06;   { deprecated by the specification, still read }
  BSON_OBJECTID   = $07;
  BSON_BOOL       = $08;
  BSON_DATETIME   = $09;
  BSON_NULL       = $0A;
  BSON_REGEX      = $0B;
  BSON_DBPOINTER  = $0C;   { deprecated }
  BSON_CODE       = $0D;
  BSON_SYMBOL     = $0E;   { deprecated }
  BSON_CODE_SCOPE = $0F;
  BSON_INT32      = $10;
  BSON_TIMESTAMP  = $11;
  BSON_INT64      = $12;
  BSON_DECIMAL128 = $13;
  BSON_MINKEY     = $FF;
  BSON_MAXKEY     = $7F;

  { How deep documents may nest before the reader refuses: each level is a
    recursive call, and a small document nesting a hundred thousand deep
    overflowed the stack. MongoDB itself stops at 100; this is generous
    beyond anything a real document does. }
  BSON_MAX_DEPTH  = 512;

  { Binary subtypes the library names. The byte itself is always preserved,
    including the user-defined range $80..$FF. }
  BSON_SUBTYPE_GENERIC = $00;
  BSON_SUBTYPE_UUID    = $04;

{ True when ADouble is a finite value -2^63 <= ADouble < 2^63, so Trunc of it
  is an Int64. Integrality is the caller's own rule. }
function BsonDoubleInInt64Range(ADouble: Double): Boolean;

type
  TBsonMemberKind = (
    Unsupported,
    BoolValue, IntValue, Int64Value, FloatValue, CurrencyValue, StrValue,
    DateValue, TimeValue, DateTimeValue, GuidValue, BytesValue, ObjectIdValue,
    EnumValue, SetValue, NullableValue,
    ObjectValue, RecordValue,
    ListValue, DictionaryValue, ArrayValue,
    CustomSerializer, VariantValue);

  TBsonTypePlan = class;

  TBsonMemberPlan = class
  public
    TypeInfo: PTypeInfo;
    Kind: TBsonMemberKind;

    NullableAccess: TNullableAccess;
    Inner: TBsonMemberPlan;          { owned }

    EnumMapping: TArray<string>;
    SetElemTypeInfo: PTypeInfo;
    SetElemMapping: TArray<string>;

    BoundPlan: TBsonTypePlan;        { BORROWED - it lives in the plan cache }

    Item: TBsonMemberPlan;           { owned }
    Key: TBsonMemberPlan;            { owned }
    Value: TBsonMemberPlan;          { owned }
    { Inner, Item or Value is the plan of an enclosing container of the same
      type, BORROWED from it: a TNodes = class(TList<TNodes>) has elements of
      its own type, and building a fresh plan for them never ended. }
    ElementBorrowed: Boolean;
    ContainerAdd: TRttiMethod;
    ContainerClear: TRttiMethod;
    ContainerToArray: TRttiMethod;
    ContainerCreate: TRttiMethod;
    PairKeyField: TRttiField;
    PairValueField: TRttiField;
    { Core's view of a dictionary, for TSerializationOwnership.AddOrSetBuilt.
      Not valid for a list. }
    DictAccess: TDictionaryAccess;

    Serializer: TCustomBsonValueSerializer;  { BORROWED singleton }

    { Representations, resolved once while the plan is built. }
    DateRepresentation: TBsonDateTimeRepresentation;
    DatePattern: string;
    GuidRepresentation: TBsonGuidRepresentation;
    CurrencyRepresentation: TBsonCurrencyRepresentation;

    destructor Destroy; override;
    function IsContainer: Boolean;
  end;

  TBsonFieldPlan = class
  public
    Member: TBsonMemberPlan;         { owned }
    Field: TRttiField;               { exactly one of these two is set }
    Prop: TRttiProperty;
    DelphiName: string;
    DeclaringTypeName: string;
    Name: string;
    Writable: Boolean;
    destructor Destroy; override;
  end;

  TBsonTypePlan = class
  public
    TypeInfo: PTypeInfo;
    RttiType: TRttiType;
    ClassType: TClass;
    IsRecord: Boolean;
    TypeKey: string;
    UnitName: string;
    Fields: TObjectList<TBsonFieldPlan>;
    ZeroConstructor: TRttiMethod;
    constructor Create;
    destructor Destroy; override;
  end;

  TBsonEngine = class
  strict private
    class var FCtx: TRttiContext;
    class var FLock: TCriticalSection;
    class var FPlans: TDictionary<PTypeInfo, TBsonTypePlan>;
    class var FRootPlans: TObjectDictionary<PTypeInfo, TBsonMemberPlan>;
    class var FEnumMappings: TDictionary<PTypeInfo, TArray<string>>;
    class var FTypeSerializers: TDictionary<PTypeInfo, TBsonValueSerializerClass>;
    class var FSerializerSingletons: TObjectDictionary<TClass, TCustomBsonValueSerializer>;
    class var FDatePolicies: TDateTimePolicies;
    class var FTimePolicies: TDateTimePolicies;
    class var FTimestampPolicies: TDateTimePolicies;
    class var FFrozen: Boolean;
    class var FBuildTrail: TList<PTypeInfo>;
    class var FBuildDepth: Integer;
    { The list and dictionary plans being built, outermost first; see
      ElementPlan. }
    class var FContainersBuilding: TList<TBsonMemberPlan>;

    class procedure CheckNotFrozen; static;
    class procedure RollbackBuildTrail; static;
    class function PoliciesFor(AKind: TBsonMemberKind): TDateTimePolicies; static;
    class function ResolveSerializer(
      AClass: TBsonValueSerializerClass): TCustomBsonValueSerializer; static;
    class function EnumMappingFor(ATypeInfo: PTypeInfo): TArray<string>; static;

    class function ClassifyType(ATypeInfo: PTypeInfo): TBsonMemberKind; static;
    class function GetPlan(ATypeInfo: PTypeInfo;
      const AUnitHint: string): TBsonTypePlan; static;
    class function BuildPlan(ATypeInfo: PTypeInfo;
      const AUnitHint: string): TBsonTypePlan; static;
    class procedure BuildMemberOfType(APlan: TBsonTypePlan;
      AMember: TSerializationMember); static;
    class function BuildMemberPlan(ATypeInfo: PTypeInfo;
      const AOwnerKey, AMemberName: string): TBsonMemberPlan; static;
    class function ElementPlan(AOwner: TBsonMemberPlan; ATypeInfo: PTypeInfo;
      const AOwnerKey, AMemberName: string): TBsonMemberPlan; static;
    class function GetRootPlan(ATypeInfo: PTypeInfo): TBsonMemberPlan; static;

    class function NewInstanceOf(APlan: TBsonTypePlan): TObject; static;
    class function NewContainer(APlan: TBsonMemberPlan): TObject; static;
    class function ReadMember(AFP: TBsonFieldPlan;
      AInstance: Pointer): TValue; static;
    class procedure StoreMember(AFP: TBsonFieldPlan; AInstance: Pointer;
      const AValue: TValue); static;

    class function EnumToText(ATypeInfo: PTypeInfo; AOrdinal: Integer;
      const AMapping: TArray<string>): string; static;
    class function TextToEnumOrdinal(ATypeInfo: PTypeInfo; const AText: string;
      const AMapping: TArray<string>): Integer; static;
    class function SetToText(APlan: TBsonMemberPlan;
      const AValue: TValue): string; static;
    class function TextToSet(APlan: TBsonMemberPlan;
      const AText: string): TValue; static;

    class function WriteValue(APlan: TBsonMemberPlan;
      const AValue: TValue): TBsonValue; static;
    class function WriteObjectBody(APlan: TBsonTypePlan;
      AInstance: Pointer): TBsonValue; static;
    class function ReadValue(APlan: TBsonMemberPlan; AValue: TBsonValue;
      const AExisting: TValue): TValue; static;
    class procedure ReadObjectBody(APlan: TBsonTypePlan; AInstance: Pointer;
      AValue: TBsonValue); static;

    class function DateToBson(APlan: TBsonMemberPlan;
      AValue: TDateTime): TBsonValue; static;
    class function BsonToDate(APlan: TBsonMemberPlan;
      AValue: TBsonValue): TDateTime; static;
  public
    class constructor Create;
    class destructor Destroy;

    { --- the document --- }
    class function ParseDocument(const AData: TBytes): TBsonValue; static;
    class function WriteDocument(AValue: TBsonValue): TBytes; static;

    { --- contract-aware --- }
    class function SerializeRoot(ATypeInfo: PTypeInfo;
      const AValue: TValue): TBytes; static;
    class function DeserializeRoot(ATypeInfo: PTypeInfo; const AData: TBytes;
      const AExisting: TValue): TValue; static;
    class function SerializeRootToBson(ATypeInfo: PTypeInfo;
      const AValue: TValue): TBsonValue; static;
    class function DeserializeRootFromBson(ATypeInfo: PTypeInfo;
      AValue: TBsonValue; const AExisting: TValue): TValue; static;

    { --- cross-format, reached only through the registry --- }
    class function FromPayload(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload; AFrom: TSerializationFormat): TBytes; static;
    class function FromPayloadStructural(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat;
      AProfile: TStructuralConversionProfile): TBytes; static;

    { --- the dynamic tree (structural conversion only) --- }
    class function BsonToDynamic(AValue: TBsonValue): TDynamicValue; static;
    class function DynamicToBson(AValue: TDynamicValue): TBsonValue; static;

    { --- BSON and JSON, the three modes --- }
    class function DocumentToJson(const AData: TBytes;
      AProfile: TStructuralConversionProfile): string; static;
    class function DocumentToJsonWithSchema(const AData: TBytes;
      out ASchema: string): string; static;
    class function JsonToDocument(const AJson: string;
      AProfile: TStructuralConversionProfile): TBytes; static;
    class function JsonToDocumentWithSchema(const AJson,
      ASchema: string): TBytes; static;

    { --- configuration --- }
    class procedure SetDateTimePolicy(ATypeInfo: PTypeInfo;
      const AFieldName: string; AKind: Integer;
      const APattern: string); static;
    class procedure RegisterEnumMapping(ATypeInfo: PTypeInfo;
      const AValues: array of string); static;
    class procedure RegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TBsonValueSerializerClass); static;
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;
    class procedure ResetConfiguration; static;
    class function PlanCount: Integer; static;
  end;

implementation

const
  { -2^63 and 2^63, both exactly a Double. Typed as Double so that Win32,
    which compares at Extended precision, compares the very values Win64
    does: High(Int64) is not a Double at all, and the decimal literal that
    spelled it was 2^63 - 8 on Win32 and 2^63 on Win64, so Low(Int64) was
    refused on one platform only. }
  BSON_INT64_LOW_AS_DOUBLE: Double = -9223372036854775808.0;
  BSON_INT64_END_AS_DOUBLE: Double = 9223372036854775808.0;

function BsonDoubleInInt64Range(ADouble: Double): Boolean;
begin
  Result := not ADouble.IsNan and (ADouble >= BSON_INT64_LOW_AS_DOUBLE) and
    (ADouble < BSON_INT64_END_AS_DOUBLE);
end;

{ A length the writer indexes with as an Integer. Length is NativeInt on
  Win64, so 2 GiB or more wrapped to a negative count and a wrong length
  prefix; no BSON document can be that large, so it is refused. }
function BsonWriterCount(ALength: NativeInt; AExtra: Integer): Integer;
begin
  if Int64(ALength) > Int64(MaxInt) - AExtra then
    raise EBsonInternalError.CreateFmt(
      'A value of %d bytes does not fit in a BSON document, which is at ' +
      'most 2 GiB.', [Int64(ALength)]);
  Result := Integer(ALength) + AExtra;
end;

{ ===========================================================================
  1. THE READER

  BSON is length-prefixed, so every read is bounds-checked against the length
  the document itself declared as well as against the buffer. A truncated or
  lying document fails with a message rather than reading past its end.

  An element type this version does not implement is REFUSED by name. None is
  coerced into a string or a number: a value that arrives as the wrong type is
  worse than one that does not arrive.
  =========================================================================== }

type
  TBsonReader = record
  public
    FData: TBytes;
    FPos: Integer;
    FLen: Integer;
    FDepth: Integer;
    procedure Fail(const AMessage: string);
    procedure Need(ACount: Integer);
    function DecodeUtf8(AStart, ACount: Integer): string;
    function ReadByte: Byte;
    function ReadInt32: Integer;
    function ReadInt64: Int64;
    function ReadDouble: Double;
    function ReadCString: string;
    function ReadString: string;
    function ReadRaw(ACount: Integer): TBytes;
    function ReadObjectId: TBsonObjectId;
    function ReadBinary(out ASubtype: Byte): TBytes;
    function ReadDocument(AIsArray: Boolean): TBsonValue;
    class function Parse(const AData: TBytes): TBsonValue; static;
  end;

procedure TBsonReader.Fail(const AMessage: string);
begin
  raise EBsonInputError.CreateFmt('%s (at byte %d of %d)',
    [AMessage, FPos, FLen]);
end;

procedure TBsonReader.Need(ACount: Integer);
begin
  { Against what remains, never FPos + ACount: a declared length near
    High(Integer) overflowed the sum to a negative number, the check passed,
    and the read went gigabytes past the buffer. }
  if (ACount < 0) or (ACount > FLen - FPos) then
    Fail('The document ends before it says it does');
end;

function TBsonReader.ReadByte: Byte;
begin
  Need(1);
  Result := FData[FPos];
  Inc(FPos);
end;

function TBsonReader.ReadInt32: Integer;
begin
  Need(4);
  Move(FData[FPos], Result, 4);
  Inc(FPos, 4);
end;

function TBsonReader.ReadInt64: Int64;
begin
  Need(8);
  Move(FData[FPos], Result, 8);
  Inc(FPos, 8);
end;

function TBsonReader.ReadDouble: Double;
begin
  Need(8);
  Move(FData[FPos], Result, 8);
  Inc(FPos, 8);
end;

{ BSON text is UTF-8 by specification, so bytes that are not are a malformed
  document - reported as one, not as the RTL's EEncodingError. }
function TBsonReader.DecodeUtf8(AStart, ACount: Integer): string;
begin
  try
    Result := TEncoding.UTF8.GetString(FData, AStart, ACount);
  except
    on E: EEncodingError do
    begin
      FPos := AStart;
      Fail('Text that is not UTF-8');
    end;
  end;
end;

function TBsonReader.ReadCString: string;
var
  Start, Stop: Integer;
begin
  Start := FPos;
  Stop := Start;
  while (Stop < FLen) and (FData[Stop] <> 0) do Inc(Stop);
  if Stop >= FLen then Fail('An unterminated element name');
  Result := DecodeUtf8(Start, Stop - Start);
  FPos := Stop + 1;
end;

function TBsonReader.ReadString: string;
var
  Size: Integer;
begin
  Size := ReadInt32;
  if Size < 1 then Fail('A string with a non-positive length');
  Need(Size);
  { The declared length includes the terminating zero, which must be
    there. }
  if FData[FPos + Size - 1] <> 0 then Fail('A string not terminated by a zero');
  Result := DecodeUtf8(FPos, Size - 1);
  Inc(FPos, Size);
end;

function TBsonReader.ReadRaw(ACount: Integer): TBytes;
begin
  Need(ACount);
  SetLength(Result, ACount);
  if ACount > 0 then Move(FData[FPos], Result[0], ACount);
  Inc(FPos, ACount);
end;

function TBsonReader.ReadObjectId: TBsonObjectId;
begin
  Result := TBsonObjectId.FromBytes(ReadRaw(12));
end;

function TBsonReader.ReadBinary(out ASubtype: Byte): TBytes;
var
  Size: Integer;
begin
  Size := ReadInt32;
  if Size < 0 then Fail('A binary element with a negative length');
  ASubtype := ReadByte;
  Need(Size);
  SetLength(Result, Size);
  if Size > 0 then Move(FData[FPos], Result[0], Size);
  Inc(FPos, Size);
end;

function TBsonReader.ReadDocument(AIsArray: Boolean): TBsonValue;
var
  DocSize, DocEnd: Integer;
  ElemType, Subtype: Byte;
  Name: string;
  Child: TBsonValue;
  I64: Int64;
begin
  DocSize := ReadInt32;
  if DocSize < 5 then Fail('A document shorter than an empty document');
  { The same subtraction as Need, so a huge DocSize cannot wrap. }
  if DocSize - 4 > FLen - FPos then
    Fail('A document longer than the data it is in');
  DocEnd := FPos + DocSize - 4;
  if FDepth >= BSON_MAX_DEPTH then
    Fail(Format('Documents nested more than %d deep', [BSON_MAX_DEPTH]));

  Inc(FDepth);
  if AIsArray then Result := TBsonValue.NewArray
  else Result := TBsonValue.NewDocument;
  try
    while FPos < DocEnd - 1 do
    begin
      ElemType := ReadByte;
      Name := ReadCString;
      case ElemType of
        BSON_DOUBLE:   Child := TBsonValue.NewDouble(ReadDouble);
        BSON_STRING:   Child := TBsonValue.NewString(ReadString);
        BSON_DOCUMENT: Child := ReadDocument(False);
        BSON_ARRAY:    Child := ReadDocument(True);
        BSON_BINARY:
          begin
            { The subtype byte verbatim. Folding everything that is not $04
              into "generic" would lose the difference between an MD5, a
              compressed blob and an application's own subtype. }
            var Data := ReadBinary(Subtype);
            Child := TBsonValue.NewBinary(Data, Subtype);
          end;
        BSON_BOOL:     Child := TBsonValue.NewBool(ReadByte <> 0);
        BSON_DATETIME:
          begin
            I64 := ReadInt64;
            { BSON datetime is milliseconds since the Unix epoch, UTC. It is
              kept as the instant it states; nothing is shifted, because a
              TDateTime carries no zone and inventing one would make the
              value depend on where the process runs. A count past the years
              a TDateTime holds is refused, not overflowed. }
            var At: TDateTime;
            if not TStructuralText.TryUnixMillisToDateTime(I64, At) then
              Fail(Format('The datetime %d ms is outside the years 1 to 9999',
                [I64]));
            Child := TBsonValue.NewDateTime(At);
          end;
        BSON_NULL:     Child := TBsonValue.NewNull;
        BSON_INT32:    Child := TBsonValue.NewInt32(ReadInt32);
        BSON_INT64:    Child := TBsonValue.NewInt64(ReadInt64);
        BSON_OBJECTID: Child := TBsonValue.NewObjectId(ReadObjectId);
        BSON_TIMESTAMP: Child := TBsonValue.NewTimestamp(UInt64(ReadInt64));
        BSON_DECIMAL128: Child := TBsonValue.NewDecimal128(ReadRaw(16));
        BSON_UNDEFINED: Child := TBsonValue.NewUndefined;
        BSON_MINKEY:   Child := TBsonValue.NewMinKey;
        BSON_MAXKEY:   Child := TBsonValue.NewMaxKey;
        BSON_SYMBOL:   Child := TBsonValue.NewSymbol(ReadString);
        BSON_CODE:     Child := TBsonValue.NewJavaScript(ReadString);
        BSON_REGEX:
          begin
            { Two cstrings, not a length-prefixed string: a regex is the one
              place BSON puts user text in a zero-terminated field. }
            var Pattern := ReadCString;
            Child := TBsonValue.NewRegex(Pattern, ReadCString);
          end;
        BSON_DBPOINTER:
          begin
            var Namespace := ReadString;
            Child := TBsonValue.NewDbPointer(Namespace, ReadObjectId);
          end;
        BSON_CODE_SCOPE:
          begin
            { int32 total length, then the code, then the scope document.
              The total is checked rather than trusted. }
            var Total := ReadInt32;
            var Before := FPos;
            if Total < 4 then Fail('A code-with-scope shorter than its length');
            var Code := ReadString;
            Child := TBsonValue.NewJavaScriptScope(Code, ReadDocument(False));
            if FPos - Before <> Total - 4 then
            begin
              Child.Free;
              Fail('A code-with-scope whose declared length does not match ' +
                   'its contents');
            end;
          end;
      else
        raise EBsonUnsupportedType.CreateFor(ElemType, Name);
      end;
      if AIsArray then Result.Add(Child) else Result.Add(Name, Child);
    end;
    if FPos <> DocEnd - 1 then Fail('A document whose elements overrun it');
    if ReadByte <> 0 then Fail('A document not terminated by a zero byte');
    Dec(FDepth);
  except
    Dec(FDepth);
    Result.Free;
    raise;
  end;
end;

class function TBsonReader.Parse(const AData: TBytes): TBsonValue;
var
  R: TBsonReader;
begin
  if Length(AData) < 5 then
    raise EBsonInputError.Create(
      'A BSON document is at least five bytes; this one is shorter.');
  if Int64(Length(AData)) > MaxInt then
    raise EBsonInputError.CreateFmt(
      'A buffer of %d bytes is not a BSON document, which is at most 2 GiB.',
      [Int64(Length(AData))]);
  R.FData := AData;
  R.FLen := Integer(Length(AData));
  R.FPos := 0;
  R.FDepth := 0;
  Result := R.ReadDocument(False);
  try
    if R.FPos <> R.FLen then
      R.Fail('Bytes after the end of the root document');
  except
    Result.Free;
    raise;
  end;
end;

{ ===========================================================================
  2. THE WRITER
  =========================================================================== }

type
  TBsonWriter = record
  public
    FData: TBytes;
    FPos: Integer;
    FDepth: Integer;
    procedure Ensure(ACount: Integer);
    procedure PutByte(AValue: Byte);
    procedure PutInt32(AValue: Integer);
    procedure PutInt64(AValue: Int64);
    procedure PutDouble(AValue: Double);
    procedure PutCString(const AValue: string);
    procedure PutString(const AValue: string);
    procedure PutBinary(const AValue: TBytes; ASubtype: Byte);
    procedure PutRaw(const AValue: TBytes);
    procedure PutCodeWithScope(AValue: TBsonValue);
    procedure PutElement(const AName: string; AValue: TBsonValue);
    procedure PutDocument(AValue: TBsonValue);
    function Done: TBytes;
  end;

{ A TDateTime as milliseconds since the Unix epoch, the way Delphi encodes
  it: before 1899-12-30 a TDateTime is a negative day with a POSITIVE time of
  day, and (AValue - UnixDateDelta) * MSecsPerDay put every such instant a
  day early. A value past the years 1 to 9999 is refused rather than written,
  because the reader refuses it. }
function UnixMillisOf(AValue: TDateTime): Int64;
begin
  TStructuralText.CheckDateTime(AValue);
  if not TStructuralText.TryDateTimeToUnixMillis(AValue, Result) then
    raise ESerializationUnsupported.CreateFmt(
      'The TDateTime %s rounds to a millisecond after 9999-12-31, which no ' +
      'reader here accepts.', [FloatToStr(AValue, TFormatSettings.Invariant)]);
end;

procedure TBsonWriter.Ensure(ACount: Integer);
begin
  { Against what is left below MaxInt: FPos + ACount wrapped negative. }
  if ACount > MaxInt - FPos then
    raise EBsonInternalError.CreateFmt(
      'A document of %d bytes does not fit in BSON, which is at most 2 GiB.',
      [Int64(FPos) + ACount]);
  if FPos + ACount > Length(FData) then
    SetLength(FData, Max(FPos + ACount, Length(FData) * 2 + 64));
end;

procedure TBsonWriter.PutByte(AValue: Byte);
begin
  Ensure(1);
  FData[FPos] := AValue;
  Inc(FPos);
end;

procedure TBsonWriter.PutInt32(AValue: Integer);
begin
  Ensure(4);
  Move(AValue, FData[FPos], 4);
  Inc(FPos, 4);
end;

procedure TBsonWriter.PutInt64(AValue: Int64);
begin
  Ensure(8);
  Move(AValue, FData[FPos], 8);
  Inc(FPos, 8);
end;

procedure TBsonWriter.PutDouble(AValue: Double);
begin
  Ensure(8);
  Move(AValue, FData[FPos], 8);
  Inc(FPos, 8);
end;

{ Both text writers go through StringToUtf8Bytes, which refuses an unpaired
  surrogate: TEncoding wrote U+FFFD in its place, so the text read back was
  not the text written. }
procedure TBsonWriter.PutCString(const AValue: string);
var
  Utf8: TBytes;
begin
  Utf8 := StringToUtf8Bytes(AValue);
  { A BSON element name is zero-terminated, so it cannot contain a zero. }
  for var B in Utf8 do
    if B = 0 then
      raise EBsonInternalError.CreateFmt(
        'The name "%s" contains a zero byte, which a BSON element name ' +
        'cannot carry.', [AValue]);
  Ensure(BsonWriterCount(Length(Utf8), 1));
  if Length(Utf8) > 0 then Move(Utf8[0], FData[FPos], Length(Utf8));
  Inc(FPos, Length(Utf8));
  PutByte(0);
end;

procedure TBsonWriter.PutString(const AValue: string);
var
  Utf8: TBytes;
begin
  Utf8 := StringToUtf8Bytes(AValue);
  PutInt32(BsonWriterCount(Length(Utf8), 1));
  Ensure(BsonWriterCount(Length(Utf8), 1));
  if Length(Utf8) > 0 then Move(Utf8[0], FData[FPos], Length(Utf8));
  Inc(FPos, Length(Utf8));
  PutByte(0);
end;

procedure TBsonWriter.PutBinary(const AValue: TBytes; ASubtype: Byte);
begin
  PutInt32(BsonWriterCount(Length(AValue), 0));
  PutByte(ASubtype);
  Ensure(BsonWriterCount(Length(AValue), 0));
  if Length(AValue) > 0 then Move(AValue[0], FData[FPos], Length(AValue));
  Inc(FPos, Length(AValue));
end;

procedure TBsonWriter.PutElement(const AName: string; AValue: TBsonValue);
begin
  case AValue.Kind of
    TBsonKind.Double:
      begin PutByte(BSON_DOUBLE); PutCString(AName); PutDouble(AValue.AsDouble); end;
    TBsonKind.Str:
      begin PutByte(BSON_STRING); PutCString(AName); PutString(AValue.AsString); end;
    TBsonKind.Doc:
      begin PutByte(BSON_DOCUMENT); PutCString(AName); PutDocument(AValue); end;
    TBsonKind.Arr:
      begin PutByte(BSON_ARRAY); PutCString(AName); PutDocument(AValue); end;
    TBsonKind.Binary:
      begin
        PutByte(BSON_BINARY);
        PutCString(AName);
        { The subtype byte the value arrived with, whatever it was - the
          user-defined range included. Normalising it to 0 would quietly
          turn somebody's MD5 into "some bytes". }
        PutBinary(AValue.AsBytes, AValue.SubtypeByte);
      end;
    TBsonKind.Bool:
      begin
        PutByte(BSON_BOOL);
        PutCString(AName);
        if AValue.AsBool then PutByte(1) else PutByte(0);
      end;
    TBsonKind.DateTime:
      begin
        PutByte(BSON_DATETIME);
        PutCString(AName);
        PutInt64(UnixMillisOf(AValue.AsDateTime));
      end;
    TBsonKind.Null:
      begin PutByte(BSON_NULL); PutCString(AName); end;
    TBsonKind.Int32:
      begin
        PutByte(BSON_INT32);
        PutCString(AName);
        { The value reached here as an int32; the cast says so rather than
          leaving a truncation warning to hide a real one later. }
        PutInt32(Integer(AValue.AsInt64));
      end;
    TBsonKind.Int64:
      begin PutByte(BSON_INT64); PutCString(AName); PutInt64(AValue.AsInt64); end;
    TBsonKind.ObjectId:
      begin
        PutByte(BSON_OBJECTID);
        PutCString(AName);
        PutRaw(AValue.AsBytes);
      end;
    TBsonKind.Timestamp:
      begin
        PutByte(BSON_TIMESTAMP);
        PutCString(AName);
        PutInt64(System.Int64(AValue.AsTimestamp));
      end;
    TBsonKind.Decimal128:
      begin
        PutByte(BSON_DECIMAL128);
        PutCString(AName);
        PutRaw(AValue.AsBytes);
      end;
    TBsonKind.Regex:
      begin
        PutByte(BSON_REGEX);
        PutCString(AName);
        PutCString(AValue.AsPattern);
        PutCString(AValue.AsOptions);
      end;
    TBsonKind.JavaScript:
      begin
        PutByte(BSON_CODE);
        PutCString(AName);
        PutString(AValue.AsCode);
      end;
    TBsonKind.JavaScriptScope:
      begin
        PutByte(BSON_CODE_SCOPE);
        PutCString(AName);
        PutCodeWithScope(AValue);
      end;
    TBsonKind.Symbol:
      begin PutByte(BSON_SYMBOL); PutCString(AName); PutString(AValue.AsString); end;
    TBsonKind.Undefined:
      begin PutByte(BSON_UNDEFINED); PutCString(AName); end;
    TBsonKind.DbPointer:
      begin
        PutByte(BSON_DBPOINTER);
        PutCString(AName);
        PutString(AValue.AsPattern);
        PutRaw(AValue.AsBytes);
      end;
    TBsonKind.MinKey:
      begin PutByte(BSON_MINKEY); PutCString(AName); end;
    TBsonKind.MaxKey:
      begin PutByte(BSON_MAXKEY); PutCString(AName); end;
  else
    raise EBsonInternalError.CreateFmt('Cannot write %s.', [AValue.Describe]);
  end;
end;

procedure TBsonWriter.PutRaw(const AValue: TBytes);
begin
  Ensure(BsonWriterCount(Length(AValue), 0));
  if Length(AValue) > 0 then Move(AValue[0], FData[FPos], Length(AValue));
  Inc(FPos, Length(AValue));
end;

{ int32 total length, then the code, then the scope document - and the total
  counts itself, so it can only be written once the rest is measured. }
procedure TBsonWriter.PutCodeWithScope(AValue: TBsonValue);
var
  LengthAt, Total: Integer;
begin
  LengthAt := FPos;
  PutInt32(0);
  PutString(AValue.AsCode);
  PutDocument(AValue.Scope);
  Total := FPos - LengthAt;
  Move(Total, FData[LengthAt], 4);
end;

procedure TBsonWriter.PutDocument(AValue: TBsonValue);
var
  Start, Size, I: Integer;
begin
  { The reader's limit, counted the way the reader counts it - every
    document and array, a code-with-scope's scope among them. A tree built
    by hand deeper than that wrote a document ParseDocument then refused,
    and one far deeper recursed until the stack ran out. }
  if FDepth >= BSON_MAX_DEPTH then
    raise EBsonInternalError.CreateFmt(
      'The document nests more than %d documents and arrays deep, which ' +
      'the BSON reader here refuses, so it is not written.', [BSON_MAX_DEPTH]);
  Inc(FDepth);
  Start := FPos;
  PutInt32(0);                       { the length, filled in below }
  for I := 0 to AValue.Count - 1 do
  begin
    { Add adopts whatever it is given, nil included. }
    if AValue[I] = nil then
      raise EBsonInternalError.CreateFmt(
        'The element "%s" is nil; a document holds values, and BSON null ' +
        'is TBsonValue.NewNull.', [AValue.Names[I]]);
    PutElement(AValue.Names[I], AValue[I]);
  end;
  PutByte(0);
  Size := FPos - Start;
  Move(Size, FData[Start], 4);
  Dec(FDepth);
end;

function TBsonWriter.Done: TBytes;
begin
  SetLength(FData, FPos);
  Result := FData;
end;

{ ===========================================================================
  3. PLANS
  =========================================================================== }

destructor TBsonMemberPlan.Destroy;
begin
  if not ElementBorrowed then
  begin
    Inner.Free;
    Item.Free;
    Value.Free;
  end;
  Key.Free;
  inherited Destroy;
end;

function TBsonMemberPlan.IsContainer: Boolean;
begin
  Result := Kind in [TBsonMemberKind.ListValue, TBsonMemberKind.ArrayValue,
    TBsonMemberKind.DictionaryValue];
end;

destructor TBsonFieldPlan.Destroy;
begin
  Member.Free;
  inherited Destroy;
end;

constructor TBsonTypePlan.Create;
begin
  inherited Create;
  Fields := TObjectList<TBsonFieldPlan>.Create(True);
end;

destructor TBsonTypePlan.Destroy;
begin
  Fields.Free;
  inherited Destroy;
end;

{ ===========================================================================
  THE ENGINE
  =========================================================================== }

class constructor TBsonEngine.Create;
begin
  FCtx := TRttiContext.Create;
  FLock := TCriticalSection.Create;
  FPlans := TDictionary<PTypeInfo, TBsonTypePlan>.Create;
  FRootPlans := TObjectDictionary<PTypeInfo, TBsonMemberPlan>.Create([doOwnsValues]);
  FEnumMappings := TDictionary<PTypeInfo, TArray<string>>.Create;
  FTypeSerializers := TDictionary<PTypeInfo, TBsonValueSerializerClass>.Create;
  FSerializerSingletons :=
    TObjectDictionary<TClass, TCustomBsonValueSerializer>.Create([doOwnsValues]);
  FBuildTrail := TList<PTypeInfo>.Create;
  FContainersBuilding := TList<TBsonMemberPlan>.Create;
  { TDate and TTime are not instants. Writing them as a BSON datetime would
    claim a point in time that a date-without-a-day-part or a
    time-without-a-date does not have, so they default to ISO 8601 strings
    and only TDateTime gets the native element. }
  FDatePolicies := TDateTimePolicies.Create(
    TDateTimePolicy.Make(Ord(TBsonDateTimeRepresentation.StringIso8601)));
  FTimePolicies := TDateTimePolicies.Create(
    TDateTimePolicy.Make(Ord(TBsonDateTimeRepresentation.StringIso8601)));
  FTimestampPolicies := TDateTimePolicies.Create(
    TDateTimePolicy.Make(Ord(TBsonDateTimeRepresentation.Native)));
end;

class destructor TBsonEngine.Destroy;
var
  P: TBsonTypePlan;
begin
  for P in FPlans.Values do P.Free;
  FPlans.Free;
  FRootPlans.Free;
  FTimestampPolicies.Free;
  FTimePolicies.Free;
  FDatePolicies.Free;
  FBuildTrail.Free;
  FContainersBuilding.Free;
  FSerializerSingletons.Free;
  FTypeSerializers.Free;
  FEnumMappings.Free;
  FLock.Free;
  FCtx.Free;
end;

class procedure TBsonEngine.CheckNotFrozen;
begin
  if FFrozen then
    raise EBsonInternalError.Create(
      'BSON configuration is frozen. A registration has to happen before the ' +
      'type it affects is first used, because a plan is cached at that ' +
      'moment; afterwards it would be a silent no-op.');
end;

class procedure TBsonEngine.RollbackBuildTrail;
var
  TI: PTypeInfo;
  P: TBsonTypePlan;
begin
  for TI in FBuildTrail do
    if FPlans.TryGetValue(TI, P) then
    begin
      FPlans.Remove(TI);
      P.Free;
    end;
  FBuildTrail.Clear;
end;

class function TBsonEngine.PoliciesFor(
  AKind: TBsonMemberKind): TDateTimePolicies;
begin
  case AKind of
    TBsonMemberKind.DateValue: Result := FDatePolicies;
    TBsonMemberKind.TimeValue: Result := FTimePolicies;
  else
    Result := FTimestampPolicies;
  end;
end;

class function TBsonEngine.ResolveSerializer(
  AClass: TBsonValueSerializerClass): TCustomBsonValueSerializer;
begin
  if AClass = nil then Exit(nil);
  if not FSerializerSingletons.TryGetValue(AClass, Result) then
  begin
    Result := AClass.Create;
    FSerializerSingletons.Add(AClass, Result);
  end;
end;

class function TBsonEngine.EnumMappingFor(ATypeInfo: PTypeInfo): TArray<string>;
begin
  { BSON's own registration first; then [SerializationEnum] on the type. }
  if (ATypeInfo = nil) or not FEnumMappings.TryGetValue(ATypeInfo, Result) then
    Result := TSerializationMetadata.EnumValuesOf(ATypeInfo);
end;

class function TBsonEngine.ClassifyType(ATypeInfo: PTypeInfo): TBsonMemberKind;
var
  Access: TNullableAccess;
begin
  if ATypeInfo = nil then Exit(TBsonMemberKind.Unsupported);
  if FTypeSerializers.ContainsKey(ATypeInfo) then
    Exit(TBsonMemberKind.CustomSerializer);
  if ATypeInfo = System.TypeInfo(TGUID) then Exit(TBsonMemberKind.GuidValue);
  { BSON has its own identifier type, so a member declared as one is written
    as one - not as twelve loose bytes that come back as bytes. }
  if ATypeInfo = System.TypeInfo(TBsonObjectId) then
    Exit(TBsonMemberKind.ObjectIdValue);
  if ATypeInfo = System.TypeInfo(TDate) then Exit(TBsonMemberKind.DateValue);
  if ATypeInfo = System.TypeInfo(TTime) then Exit(TBsonMemberKind.TimeValue);
  if ATypeInfo = System.TypeInfo(TDateTime) then
    Exit(TBsonMemberKind.DateTimeValue);
  if ATypeInfo = System.TypeInfo(TBytes) then Exit(TBsonMemberKind.BytesValue);
  if TSerializationTypes.TryGetNullableAccess(ATypeInfo, Access) then
    Exit(TBsonMemberKind.NullableValue);

  case ATypeInfo.Kind of
    tkInteger: Result := TBsonMemberKind.IntValue;
    tkInt64: Result := TBsonMemberKind.Int64Value;
    tkFloat:
      { Comp is a 64-bit integer RTTI files under tkFloat. }
      if GetTypeData(ATypeInfo).FloatType = ftCurr then
        Result := TBsonMemberKind.CurrencyValue
      else if GetTypeData(ATypeInfo).FloatType = ftComp then
        Result := TBsonMemberKind.Int64Value
      else
        Result := TBsonMemberKind.FloatValue;
    tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
      Result := TBsonMemberKind.StrValue;
    tkEnumeration:
      if (ATypeInfo = System.TypeInfo(Boolean)) or
         (ATypeInfo = System.TypeInfo(ByteBool)) or
         (ATypeInfo = System.TypeInfo(WordBool)) or
         (ATypeInfo = System.TypeInfo(LongBool)) then
        Result := TBsonMemberKind.BoolValue
      else
        Result := TBsonMemberKind.EnumValue;
    tkSet: Result := TBsonMemberKind.SetValue;
    tkRecord, tkMRecord: Result := TBsonMemberKind.RecordValue;
    tkDynArray, tkArray: Result := TBsonMemberKind.ArrayValue;
    tkVariant: Result := TBsonMemberKind.VariantValue;
    tkClass:
      { THE ONE QUESTION, ASKED IN ONE PLACE. TSerializationTypes matches by
        ancestry, so TOrders = class(TObjectList<TOrder>) is a list and a
        class that merely has an Add and a ToArray is not. Six engines used
        to answer this for themselves and three of them got it wrong. }
      case TSerializationTypes.ContainerKindOf(ATypeInfo) of
        TContainerKind.Dictionary: Result := TBsonMemberKind.DictionaryValue;
        TContainerKind.List:       Result := TBsonMemberKind.ListValue;
      else
        Result := TBsonMemberKind.ObjectValue;
      end;
  else
    Result := TBsonMemberKind.Unsupported;
  end;
end;

{ --------------------------------------------------------------- plans --- }

class function TBsonEngine.BuildMemberPlan(ATypeInfo: PTypeInfo;
  const AOwnerKey, AMemberName: string): TBsonMemberPlan;
var
  Why: string;
  ListAccess: TListAccess;
  StaticCount, StaticSize: Integer;
  SerCls: TBsonValueSerializerClass;
  T, PairType: TRttiType;
  M: TRttiMethod;
  Params: TArray<TRttiParameter>;
  Policy: TDateTimePolicy;
  Access: TNullableAccess;
  ElemType: PTypeInfo;
begin
  Result := TBsonMemberPlan.Create;
  try
    Result.TypeInfo := ATypeInfo;
    Result.Kind := ClassifyType(ATypeInfo);
    Result.GuidRepresentation := TBsonGuidRepresentation.BinaryUuid;
    Result.CurrencyRepresentation := TBsonCurrencyRepresentation.ScaledInt64;

    if Result.Kind = TBsonMemberKind.CustomSerializer then
    begin
      FTypeSerializers.TryGetValue(ATypeInfo, SerCls);
      Result.Serializer := ResolveSerializer(SerCls);
      Exit;
    end;

    { A type that cannot be serialized at all is refused here, by name and
      with the remedy - after a registered serializer has had its chance,
      because a caller who registered one has said how. It must not reach
      the scalar writer: a pointer's value written as an integer would be
      read back into a new object's field, and freeing that object would
      free whatever it pointed at. The decision is shared by every format:
      see TSerializationTypes.UnsupportedReason. }
    { A type BSON carries natively is not asked: TBsonObjectId is twelve
      bytes behind an inline array that has no RTTI, which is exactly what
      the shared rule refuses in a record it knows nothing about - and BSON
      knows this one, and writes it as the ObjectId element it is. }
    if Result.Kind = TBsonMemberKind.ObjectIdValue then Why := ''
    else Why := TSerializationTypes.UnsupportedReason(ATypeInfo);
    if Why <> '' then
      raise EBsonError.CreateFmt(
        '%s %s. Leave it out with [BsonIgnore], or register a BSON ' +
        'type serializer for its type.',
        [MemberDisplayName(AOwnerKey, AMemberName), Why]);

    case Result.Kind of
      TBsonMemberKind.DateValue, TBsonMemberKind.TimeValue,
      TBsonMemberKind.DateTimeValue:
        begin
          Policy := PoliciesFor(Result.Kind).Resolve(AOwnerKey, AMemberName);
          Result.DateRepresentation := TBsonDateTimeRepresentation(Policy.Kind);
          Result.DatePattern := Policy.Pattern;
        end;

      TBsonMemberKind.EnumValue:
        Result.EnumMapping := EnumMappingFor(ATypeInfo);

      TBsonMemberKind.SetValue:
        begin
          Result.SetElemTypeInfo := ATypeInfo.TypeData.CompType^;
          Result.SetElemMapping := EnumMappingFor(Result.SetElemTypeInfo);
        end;

      TBsonMemberKind.NullableValue:
        begin
          if not TSerializationTypes.TryGetNullableAccess(ATypeInfo, Access) then
            raise EBsonInternalError.CreateFmt(
              'Internal: %s was classified as a nullable but its layout ' +
              'cannot be resolved.', [UTF8ToString(ATypeInfo.Name)]);
          Result.NullableAccess := Access;
          Result.Inner := ElementPlan(Result, Access.ValueType, AOwnerKey,
            AMemberName);
        end;

      { The type plan is cached and outlives this member plan, so the
        containers enclosing it are closed off from what it borrows. }
      TBsonMemberKind.ObjectValue, TBsonMemberKind.RecordValue:
        begin
          FContainersBuilding.Add(nil);
          try
            Result.BoundPlan := GetPlan(ATypeInfo, '');
          finally
            FContainersBuilding.Delete(FContainersBuilding.Count - 1);
          end;
        end;

      TBsonMemberKind.ArrayValue:
        begin
          ElemType := nil;
          if ATypeInfo.Kind = tkArray then
            TSerializationTypes.TryGetStaticArrayShape(ATypeInfo, ElemType,
              StaticCount, StaticSize)
          else if GetTypeData(ATypeInfo).DynArrElType <> nil then
            ElemType := GetTypeData(ATypeInfo).DynArrElType^;
          if ElemType = nil then
            raise EBsonInternalError.CreateFmt(
              'Cannot serialize %s: its element type has no RTTI.',
              [UTF8ToString(ATypeInfo.Name)]);
          Result.Item := ElementPlan(Result, ElemType, AOwnerKey, AMemberName);
        end;

      TBsonMemberKind.ListValue, TBsonMemberKind.DictionaryValue:
        begin
          T := FCtx.GetType(ATypeInfo);
          if T = nil then
            raise EBsonInternalError.CreateFmt(
              'Cannot serialize %s: it exposes no usable RTTI.',
              [UTF8ToString(ATypeInfo.Name)]);
          for M in T.GetMethods do
          begin
            Params := M.GetParameters;
            if M.IsConstructor and (Length(Params) = 0) then
            begin
              if (Result.ContainerCreate = nil) or
                 SameText(Result.ContainerCreate.Parent.Name, 'TObject') then
                Result.ContainerCreate := M;
            end
            else if SameText(M.Name, 'Clear') and (Length(Params) = 0) then
              Result.ContainerClear := M
            else if SameText(M.Name, 'ToArray') and (Length(Params) = 0) then
              Result.ContainerToArray := M
            else if (Result.Kind = TBsonMemberKind.ListValue) and
                    SameText(M.Name, 'Add') and (Length(Params) = 1) then
              Result.ContainerAdd := M
            else if (Result.Kind = TBsonMemberKind.DictionaryValue) and
                    SameText(M.Name, 'AddOrSetValue') and (Length(Params) = 2) then
              Result.ContainerAdd := M;
          end;
          { A list's methods are the ones Core names for its family: a
            TQueue<T> enqueues, a TStack<T> pushes and a TStrings adds a
            line. Looking for a method called Add found nothing for the
            first two, and the members of the container were walked
            instead - its OnNotify event among them. }
          if (Result.Kind = TBsonMemberKind.ListValue) and
             TSerializationTypes.TryGetListAccess(ATypeInfo, ListAccess) then
          begin
            Result.ContainerAdd := ListAccess.AddMethod;
            Result.ContainerToArray := ListAccess.ToArrayMethod;
            if ListAccess.ClearMethod <> nil then
              Result.ContainerClear := ListAccess.ClearMethod;
            if ListAccess.CreateMethod <> nil then
              Result.ContainerCreate := ListAccess.CreateMethod;
          end;
          if (Result.ContainerAdd = nil) or (Result.ContainerToArray = nil) then
            raise EBsonInternalError.CreateFmt(
              'Cannot serialize %s: it looks like a collection but has no ' +
              'usable Add/ToArray pair.', [UTF8ToString(ATypeInfo.Name)]);
          Params := Result.ContainerAdd.GetParameters;
          FContainersBuilding.Add(Result);
          try
            if Result.Kind = TBsonMemberKind.ListValue then
              Result.Item := ElementPlan(Result, Params[0].ParamType.Handle,
                AOwnerKey, AMemberName)
            else
            begin
              Result.Key := BuildMemberPlan(Params[0].ParamType.Handle,
                AOwnerKey, AMemberName);
              Result.Value := ElementPlan(Result, Params[1].ParamType.Handle,
                AOwnerKey, AMemberName);
            end;
          finally
            FContainersBuilding.Delete(FContainersBuilding.Count - 1);
          end;
          if Result.Kind = TBsonMemberKind.DictionaryValue then
          begin
            { A BSON document's keys are strings, so a dictionary key has to
              have a text form. }
            if not (Result.Key.Kind in [TBsonMemberKind.StrValue,
              TBsonMemberKind.IntValue, TBsonMemberKind.Int64Value,
              TBsonMemberKind.EnumValue, TBsonMemberKind.GuidValue]) then
              raise EBsonInternalError.CreateFmt(
                'Cannot serialize %s: a BSON document key is a string, and %s ' +
                'has no text form.', [UTF8ToString(ATypeInfo.Name),
                 UTF8ToString(Params[0].ParamType.Handle.Name)]);
            PairType := nil;
            if (Result.ContainerToArray.ReturnType <> nil) and
               (GetTypeData(Result.ContainerToArray.ReturnType.Handle).DynArrElType <> nil) then
              PairType := FCtx.GetType(
                GetTypeData(Result.ContainerToArray.ReturnType.Handle).DynArrElType^);
            if PairType <> nil then
            begin
              Result.PairKeyField := PairType.GetField('Key');
              Result.PairValueField := PairType.GetField('Value');
            end;
            if (Result.PairKeyField = nil) or (Result.PairValueField = nil) then
              raise EBsonInternalError.CreateFmt(
                'Cannot serialize %s: its ToArray does not yield key/value ' +
                'pairs.', [UTF8ToString(ATypeInfo.Name)]);
            TSerializationTypes.TryGetDictionaryAccess(ATypeInfo,
              Result.DictAccess);
          end;
        end;

      TBsonMemberKind.Unsupported:
        raise EBsonInternalError.CreateFmt(
          'BSON cannot represent %s (type kind %d). Register a custom BSON ' +
          'serializer for it, or mark the member [BsonIgnore].',
          [UTF8ToString(ATypeInfo.Name), Ord(ATypeInfo.Kind)]);
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ The plan for an element of AOwner. A list or dictionary whose elements are
  of its own type, directly or through an array - TNodes = class(TList<TNodes>)
  - gets the enclosing plan itself, borrowed: a class plan is cached before
  its members are built, but a container's element plan was built afresh
  inside it, for ever, and the stack ran out before anything was written. A
  list that then holds itself is the cycle the writer refuses. Only plans of
  the same member are borrowed - nil marks where a class or record plan
  began - so a borrowed plan is always an ancestor of the one borrowing it,
  and lives exactly as long. }
class function TBsonEngine.ElementPlan(AOwner: TBsonMemberPlan;
  ATypeInfo: PTypeInfo; const AOwnerKey, AMemberName: string): TBsonMemberPlan;
var
  I: Integer;
  Enclosing: TBsonMemberPlan;
begin
  for I := Integer(FContainersBuilding.Count) - 1 downto 0 do
  begin
    Enclosing := FContainersBuilding[I];
    if Enclosing = nil then Break;
    if Enclosing.TypeInfo = ATypeInfo then
    begin
      AOwner.ElementBorrowed := True;
      Exit(Enclosing);
    end;
  end;
  Result := BuildMemberPlan(ATypeInfo, AOwnerKey, AMemberName);
end;

class procedure TBsonEngine.BuildMemberOfType(APlan: TBsonTypePlan;
  AMember: TSerializationMember);
var
  AField: TRttiField;
  AProp: TRttiProperty;
  FP: TBsonFieldPlan;
  Attr: TCustomAttribute;
  Attrs: TArray<TCustomAttribute>;
  MemberType: PTypeInfo;
  MemberName: string;
  SerCls: TBsonValueSerializerClass;
  DateAttr: BsonDateTimeRepresentationAttribute;
  GuidAttr: BsonGuidRepresentationAttribute;
  CurrAttr: BsonCurrencyRepresentationAttribute;
  Target: TBsonMemberPlan;
begin
  AField := AMember.Field;
  AProp := AMember.Prop;
  if AField <> nil then
  begin
    if AField.FieldType = nil then
    begin
      { Ignored deliberately, or refused - never skipped silently. }
      for Attr in AField.GetAttributes do
        if Attr is BsonIgnoreAttribute then Exit;
      raise EBsonError.CreateFmt(
        '%s %s. Leave it out with [BsonIgnore], or register a BSON ' +
        'type serializer for the type that holds it.',
        [AField.Name, TSerializationTypes.UnsupportedReason(nil)]);
    end;
    MemberType := AField.FieldType.Handle;
    MemberName := AField.Name;
    Attrs := AField.GetAttributes;
  end
  else
  begin
    if AProp.PropertyType = nil then Exit;
    MemberType := AProp.PropertyType.Handle;
    MemberName := AProp.Name;
    Attrs := AProp.GetAttributes;
  end;

  for Attr in Attrs do
    if Attr is BsonIgnoreAttribute then Exit;

  FP := TBsonFieldPlan.Create;
  try
    FP.Field := AField;
    FP.Prop := AProp;
    FP.DelphiName := MemberName;
    FP.Name := MemberName;
    { [SerializationName] names it, and [BsonName] below beats it. }
    if AMember.HasGeneralName then FP.Name := AMember.GeneralName;
    FP.Writable := (AField <> nil) or AProp.IsWritable;
    if AField <> nil then FP.DeclaringTypeName := AField.Parent.Name
    else FP.DeclaringTypeName := AProp.Parent.Name;

    SerCls := nil;
    DateAttr := nil;
    GuidAttr := nil;
    CurrAttr := nil;
    for Attr in Attrs do
      if Attr is BsonNameAttribute then FP.Name := BsonNameAttribute(Attr).Name
      else if Attr is BsonSerializerAttribute then
        SerCls := BsonSerializerAttribute(Attr).SerializerClass
      else if Attr is BsonDateTimeRepresentationAttribute then
        DateAttr := BsonDateTimeRepresentationAttribute(Attr)
      else if Attr is BsonGuidRepresentationAttribute then
        GuidAttr := BsonGuidRepresentationAttribute(Attr)
      else if Attr is BsonCurrencyRepresentationAttribute then
        CurrAttr := BsonCurrencyRepresentationAttribute(Attr);

    if FP.Name = '' then
      raise EBsonInternalError.CreateFmt(
        '%s.%s has an empty BSON name.', [APlan.RttiType.Name, MemberName]);

    if SerCls <> nil then
    begin
      FP.Member := TBsonMemberPlan.Create;
      FP.Member.TypeInfo := MemberType;
      FP.Member.Kind := TBsonMemberKind.CustomSerializer;
      FP.Member.Serializer := ResolveSerializer(SerCls);
    end
    else
      FP.Member := BuildMemberPlan(MemberType, APlan.TypeKey, MemberName);

    { A member attribute beats every registration. On a nullable it applies
      to the inner value, which is the one that actually has a
      representation. }
    Target := FP.Member;
    if (Target.Kind = TBsonMemberKind.NullableValue) and (Target.Inner <> nil) then
      Target := Target.Inner;
    if DateAttr <> nil then
    begin
      Target.DateRepresentation := DateAttr.Representation;
      Target.DatePattern := DateAttr.Pattern;
    end;
    { [SerializationEnum] on the member, unless BSON has its own mapping
      registered for the enumeration. }
    if AMember.HasEnumValues and (Target.Kind = TBsonMemberKind.EnumValue) and
       not FEnumMappings.ContainsKey(Target.TypeInfo) then
      Target.EnumMapping := AMember.EnumValues;
    if GuidAttr <> nil then Target.GuidRepresentation := GuidAttr.Representation;
    if CurrAttr <> nil then
      Target.CurrencyRepresentation := CurrAttr.Representation;

    APlan.Fields.Add(FP);
    FP := nil;
  finally
    FP.Free;
  end;
end;

class function TBsonEngine.BuildPlan(ATypeInfo: PTypeInfo;
  const AUnitHint: string): TBsonTypePlan;
var
  Registered: Boolean;
  T: TRttiType;
  Meta: TSerializationTypeMetadata;
  Member: TSerializationMember;
  Names: TDictionary<string, string>;
  FP: TBsonFieldPlan;
  Existing: string;
begin
  Result := TBsonTypePlan.Create;
  Inc(FBuildDepth);
  try
    Result.TypeInfo := ATypeInfo;
    T := FCtx.GetType(ATypeInfo);
    if T = nil then
      raise EBsonInternalError.CreateFmt(
        'Cannot build a BSON plan for %s: the type exposes no usable RTTI. ' +
        'A type declared inside a routine body has none; declare it at unit ' +
        'scope, or register a custom BSON serializer for it.',
        [UTF8ToString(ATypeInfo.Name)]);
    Result.RttiType := T;
    Result.IsRecord := ATypeInfo.Kind in [tkRecord, tkMRecord];
    Result.UnitName := TypeUnitOf(ATypeInfo, AUnitHint);
    Result.TypeKey := TypeKeyOf(ATypeInfo, Result.UnitName);
    { The Delphi facts - constructors, the member surface, the general
      attributes - come from the shared metadata. }
    Meta := TSerializationMetadata.Get(ATypeInfo);
    if not Result.IsRecord then
    begin
      Result.ClassType := ATypeInfo.TypeData.ClassType;
      Result.ZeroConstructor := Meta.DeclaredConstructor;
      if Result.ZeroConstructor = nil then
        Result.ZeroConstructor := Meta.TObjectConstructor;
    end;

    FPlans.Add(ATypeInfo, Result);
    FBuildTrail.Add(ATypeInfo);

    for Member in Meta.Members do
      if not Member.Ignored then BuildMemberOfType(Result, Member);

    Names := TDictionary<string, string>.Create;
    try
      for FP in Result.Fields do
        if Names.TryGetValue(LowerCase(FP.Name), Existing) then
          raise EBsonInternalError.CreateFmt(
            'Duplicate BSON name "%s" in %s: Delphi members %s and %s',
            [FP.Name, UTF8ToString(ATypeInfo.Name), Existing,
             FP.DeclaringTypeName + '.' + FP.DelphiName])
        else
          Names.Add(LowerCase(FP.Name),
            FP.DeclaringTypeName + '.' + FP.DelphiName);
    finally
      Names.Free;
    end;

    Dec(FBuildDepth);
    if FBuildDepth = 0 then FBuildTrail.Clear;
  except
    { WHO OWNS THE HALF-BUILT PLAN is decided BEFORE the rollback runs.
      A plan already registered in FPlans belongs to the build trail, and
      the rollback frees it - at the outermost level now, or later, at the
      level that started the build. A plan that never got that far is
      freed here.

      FPlans is asked BEFORE the rollback: afterwards the rollback has
      removed the plan and freed it, the answer would always be "not
      there", and the plan would be freed a second time - surfacing the
      refusal that caused it as EInvalidPointer instead of as itself. }
    Registered := FPlans.ContainsValue(Result);
    Dec(FBuildDepth);
    if FBuildDepth = 0 then RollbackBuildTrail;
    if not Registered then Result.Free;
    raise;
  end;
end;

class function TBsonEngine.GetPlan(ATypeInfo: PTypeInfo;
  const AUnitHint: string): TBsonTypePlan;
begin
  if FPlans.TryGetValue(ATypeInfo, Result) then Exit;
  Result := BuildPlan(ATypeInfo, AUnitHint);
end;

class function TBsonEngine.GetRootPlan(ATypeInfo: PTypeInfo): TBsonMemberPlan;
begin
  if FRootPlans.TryGetValue(ATypeInfo, Result) then Exit;
  Result := BuildMemberPlan(ATypeInfo, TypeKeyOf(ATypeInfo), '');
  FRootPlans.Add(ATypeInfo, Result);
end;

{ ------------------------------------------------------------ instances --- }

class function TBsonEngine.NewInstanceOf(APlan: TBsonTypePlan): TObject;
begin
  if APlan.ZeroConstructor <> nil then
    Result := APlan.ZeroConstructor.Invoke(APlan.ClassType, []).AsObject
  else
    Result := APlan.ClassType.Create;
end;

class function TBsonEngine.NewContainer(APlan: TBsonMemberPlan): TObject;
begin
  if APlan.ContainerCreate = nil then
    raise EBsonInternalError.CreateFmt(
      'Cannot construct %s: it has no parameterless constructor. Create the ' +
      'container in its owner''s constructor; BSON will fill the one that is ' +
      'already there.', [UTF8ToString(APlan.TypeInfo.Name)]);
  Result := APlan.ContainerCreate.Invoke(
    GetTypeData(APlan.TypeInfo).ClassType, []).AsObject;
end;

class function TBsonEngine.ReadMember(AFP: TBsonFieldPlan;
  AInstance: Pointer): TValue;
begin
  if AFP.Field <> nil then Result := AFP.Field.GetValue(AInstance)
  else Result := AFP.Prop.GetValue(AInstance);
end;

class procedure TBsonEngine.StoreMember(AFP: TBsonFieldPlan;
  AInstance: Pointer; const AValue: TValue);
begin
  if AFP.Field <> nil then AFP.Field.SetValue(AInstance, AValue)
  else if AFP.Prop.IsWritable then AFP.Prop.SetValue(AInstance, AValue);
end;

{ --------------------------------------------------------- enums and sets --- }

class function TBsonEngine.EnumToText(ATypeInfo: PTypeInfo; AOrdinal: Integer;
  const AMapping: TArray<string>): string;
begin
  { A set of an integer subrange or of characters has no names: its
    members are their ordinals. See TSerializationTypes.SetElementText. }
  if ATypeInfo.Kind <> tkEnumeration then
    Exit(TSerializationTypes.SetElementText(ATypeInfo, AOrdinal));
  if AMapping <> nil then
  begin
    if (AOrdinal < 0) or (AOrdinal > High(AMapping)) then
      raise EBsonInternalError.CreateFmt(
        'Mapped enumeration %s ordinal %d is outside the registered mapping ' +
        '0..%d', [UTF8ToString(ATypeInfo.Name), AOrdinal, High(AMapping)]);
    Exit(AMapping[AOrdinal]);
  end;
  Result := GetEnumName(ATypeInfo, AOrdinal);
end;

class function TBsonEngine.TextToEnumOrdinal(ATypeInfo: PTypeInfo;
  const AText: string; const AMapping: TArray<string>): Integer;
var
  I: Integer;
  S: string;
begin
  if ATypeInfo.Kind <> tkEnumeration then
  begin
    if not TSerializationTypes.TrySetElementOrdinal(ATypeInfo, Trim(AText),
         Result) then
      raise EBsonInputError.CreateFmt('"%s" is not a member of %s.',
        [Trim(AText), UTF8ToString(ATypeInfo.Name)]);
    Exit;
  end;
  S := Trim(AText);
  if AMapping <> nil then
  begin
    for I := 0 to Integer(High(AMapping)) do
      if SameText(AMapping[I], S) then Exit(I);
    raise EBsonInputError.CreateFmt('"%s" is not a registered value of %s.',
      [S, UTF8ToString(ATypeInfo.Name)]);
  end;
  Result := GetEnumValue(ATypeInfo, S);
  if Result < 0 then
    raise EBsonInputError.CreateFmt('"%s" is not a value of %s.',
      [S, UTF8ToString(ATypeInfo.Name)]);
end;

{ Through TSerializationTypes, which knows that a set's bit 0 is the byte
  holding its lowest member: counting from ordinal 0 wrote 10 as 12. }
class function TBsonEngine.SetToText(APlan: TBsonMemberPlan;
  const AValue: TValue): string;
var
  Ords: TArray<Integer>;
  Parts: TArray<string>;
  I: Integer;
begin
  Ords := TSerializationTypes.SetOrdinals(APlan.TypeInfo, AValue);
  SetLength(Parts, Length(Ords));
  for I := 0 to Integer(High(Ords)) do
    Parts[I] := EnumToText(APlan.SetElemTypeInfo, Ords[I], APlan.SetElemMapping);
  Result := string.Join(',', Parts);
end;

class function TBsonEngine.TextToSet(APlan: TBsonMemberPlan;
  const AText: string): TValue;
var
  Names: TArray<string>;
  Name, Why: string;
  Ords: TArray<Integer>;
begin
  Ords := nil;
  Names := Trim(AText).Split([','], TStringSplitOptions.ExcludeEmpty);
  for Name in Names do
    Ords := Ords + [TextToEnumOrdinal(APlan.SetElemTypeInfo, Name,
      APlan.SetElemMapping)];
  if not TSerializationTypes.TryMakeSet(APlan.TypeInfo, Ords, Result, Why) then
    raise EBsonInputError.CreateFmt('"%s" is not a %s: %s.',
      [Trim(AText), UTF8ToString(APlan.TypeInfo.Name), Why]);
end;

{ ---------------------------------------------------------- dates --- }

class function TBsonEngine.DateToBson(APlan: TBsonMemberPlan;
  AValue: TDateTime): TBsonValue;
var
  Ms: Word;
  H, N, S: Word;
  Millis, Seconds: Int64;
begin
  case APlan.DateRepresentation of
    TBsonDateTimeRepresentation.Native:
      Exit(TBsonValue.NewDateTime(AValue));
    { Whole seconds from the milliseconds, rounded down: DateTimeToUnix
      truncated toward zero, which put a fractional second before 1970 one
      second late. }
    TBsonDateTimeRepresentation.UnixSeconds:
      begin
        Millis := UnixMillisOf(AValue);
        Seconds := Millis div MSecsPerSec;
        if Millis mod MSecsPerSec < 0 then Dec(Seconds);
        Exit(TBsonValue.NewInt64(Seconds));
      end;
    TBsonDateTimeRepresentation.UnixMilliseconds:
      Exit(TBsonValue.NewInt64(UnixMillisOf(AValue)));
  end;

  { A day before year 1 formats as 0000-00-00, which states no value at all,
    and the reader refuses a year past 9999. A TTime is a time of day and has
    no year to be out of. }
  if APlan.Kind <> TBsonMemberKind.TimeValue then
    TStructuralText.CheckDateTime(AValue);
  if APlan.DateRepresentation = TBsonDateTimeRepresentation.CustomString then
    Exit(TBsonValue.NewString(
      FormatDateTime(APlan.DatePattern, AValue, TFormatSettings.Invariant)));

  DecodeTime(AValue, H, N, S, Ms);
  case APlan.Kind of
    TBsonMemberKind.DateValue:
      Result := TBsonValue.NewString(
        FormatDateTime('yyyy"-"mm"-"dd', AValue, TFormatSettings.Invariant));
    TBsonMemberKind.TimeValue:
      if Ms = 0 then
        Result := TBsonValue.NewString(
          FormatDateTime('hh":"nn":"ss', AValue, TFormatSettings.Invariant))
      else
        Result := TBsonValue.NewString(
          FormatDateTime('hh":"nn":"ss"."zzz', AValue, TFormatSettings.Invariant));
  else
    if Ms = 0 then
      Result := TBsonValue.NewString(FormatDateTime(
        'yyyy"-"mm"-"dd"T"hh":"nn":"ss', AValue, TFormatSettings.Invariant))
    else
      Result := TBsonValue.NewString(FormatDateTime(
        'yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz', AValue,
        TFormatSettings.Invariant));
  end;
end;

class function TBsonEngine.BsonToDate(APlan: TBsonMemberPlan;
  AValue: TBsonValue): TDateTime;
var
  S: string;
  Y, M, D, H, N, Sec, Ms: Word;
begin
  case APlan.DateRepresentation of
    TBsonDateTimeRepresentation.Native:
      Exit(AValue.AsDateTime);
    TBsonDateTimeRepresentation.UnixSeconds:
      begin
        if not TStructuralText.TryUnixSecondsToDateTime(AValue.AsInt64, Result) then
          raise EBsonInputError.CreateFmt(
            '%d seconds is outside the years a TDateTime holds.', [AValue.AsInt64]);
        Exit;
      end;
    TBsonDateTimeRepresentation.UnixMilliseconds:
      begin
        if not TStructuralText.TryUnixMillisToDateTime(AValue.AsInt64, Result) then
          raise EBsonInputError.CreateFmt(
            '%d ms is outside the years a TDateTime holds.', [AValue.AsInt64]);
        Exit;
      end;
    TBsonDateTimeRepresentation.CustomString:
      begin
        { The pattern the writer wrote with, then the RTL's invariant
          reading, which is what 0.9 used and still reads what it read. }
        if not TStructuralText.TryDecodePattern(AValue.AsString,
             APlan.DatePattern, Result) and
           not TryStrToDateTime(AValue.AsString, Result,
             TFormatSettings.Invariant) then
          raise EBsonInputError.CreateFmt(
            '"%s" does not match the configured pattern "%s".',
            [AValue.AsString, APlan.DatePattern]);
        Exit;
      end;
  end;

  S := Trim(AValue.AsString);
  H := 0; N := 0; Sec := 0; Ms := 0;
  try
    if APlan.Kind = TBsonMemberKind.TimeValue then
    begin
      H := Word(StrToInt(Copy(S, 1, 2)));
      N := Word(StrToInt(Copy(S, 4, 2)));
      Sec := Word(StrToInt(Copy(S, 7, 2)));
      if (Length(S) > 9) and (S[9] = '.') then Ms := Word(StrToIntDef(Copy(S, 10, 3), 0));
      Exit(EncodeTime(H, N, Sec, Ms));
    end;
    Y := Word(StrToInt(Copy(S, 1, 4)));
    M := Word(StrToInt(Copy(S, 6, 2)));
    D := Word(StrToInt(Copy(S, 9, 2)));
    if (Length(S) > 10) and CharInSet(S[11], ['T', ' ']) then
    begin
      H := Word(StrToInt(Copy(S, 12, 2)));
      N := Word(StrToInt(Copy(S, 15, 2)));
      Sec := Word(StrToInt(Copy(S, 18, 2)));
      if (Length(S) > 20) and (S[20] = '.') then
        Ms := Word(StrToIntDef(Copy(S, 21, 3), 0));
    end;
    { Before 1899-12-30 a TDateTime is a negative day with a POSITIVE time of
      day, so the time is subtracted there: adding it read 1850-06-15T12:00
      as the 16th. }
    Result := TStructuralText.ComposeDateTime(EncodeDate(Y, M, D),
      EncodeTime(H, N, Sec, Ms));
  except
    on E: EConvertError do
      raise EBsonInputError.CreateFmt('"%s" is not an ISO 8601 value.', [S]);
  end;
end;

{ ------------------------------------------------------------- GUIDs --- }

{ Binary subtype 4 is RFC 4122 byte order - the order the text reads, which
  is what a driver, mongosh and the BSON corpus mean by it. A TGUID keeps
  D1, D2 and D3 little-endian in memory, and copying that memory wrote the
  UUID 73ffd264-44b3-... as the bytes 64 D2 FF 73 B3 44 ... }
function GuidToUuidBytes(const AValue: TGUID): TBytes;
begin
  SetLength(Result, 16);
  Result[0] := Byte(AValue.D1 shr 24);
  Result[1] := Byte(AValue.D1 shr 16);
  Result[2] := Byte(AValue.D1 shr 8);
  Result[3] := Byte(AValue.D1);
  Result[4] := Byte(AValue.D2 shr 8);
  Result[5] := Byte(AValue.D2);
  Result[6] := Byte(AValue.D3 shr 8);
  Result[7] := Byte(AValue.D3);
  Move(AValue.D4[0], Result[8], 8);
end;

function UuidBytesToGuid(const AValue: TBytes): TGUID;
begin
  Result.D1 := (UInt32(AValue[0]) shl 24) or (UInt32(AValue[1]) shl 16) or
               (UInt32(AValue[2]) shl 8) or AValue[3];
  Result.D2 := Word((Word(AValue[4]) shl 8) or AValue[5]);
  Result.D3 := Word((Word(AValue[6]) shl 8) or AValue[7]);
  Move(AValue[8], Result.D4[0], 8);
end;

{ ------------------------------------------------------------- writing --- }

procedure RefuseCycle(AObject: TObject);
begin
  raise EBsonError.CreateFmt(
    '%s is already being written further up the graph: it is a ' +
    'cycle, and BSON has no back-reference. Break the cycle, or ' +
    'register a BSON type serializer that writes a key instead.',
    [AObject.ClassName]);
end;

{ A Variant through the dynamic tree, which is the one bridge every format
  shares: see TSerializationVariants. }
function VariantToBson(const AValue: Variant): TBsonValue;
var
  N: TDynamicValue;
  Why: string;
begin
  if not TSerializationVariants.TryToDynamic(AValue, N, Why) then
    raise EBsonError.Create('The value ' + Why + '.');
  try
    Result := TBsonEngine.DynamicToBson(N);
  finally
    N.Free;
  end;
end;

function BsonToVariant(ATypeInfo: PTypeInfo; AValue: TBsonValue): TValue;
var
  N: TDynamicValue;
  V: Variant;
  OV: OleVariant;
  Why: string;
begin
  N := TBsonEngine.BsonToDynamic(AValue);
  try
    if not TSerializationVariants.TryFromDynamic(N, V, Why) then
      raise EBsonInputError.Create('The BSON value ' + Why + '.');
  finally
    N.Free;
  end;
  if ATypeInfo = System.TypeInfo(OleVariant) then
  begin
    OV := V;
    TValue.Make(@OV, ATypeInfo, Result);
  end
  else
    TValue.Make(@V, ATypeInfo, Result);
end;

class function TBsonEngine.WriteValue(APlan: TBsonMemberPlan;
  const AValue: TValue): TBsonValue;
var
  Obj: TObject;
  Raw: Pointer;
  Items, Pair, K, V: TValue;
  I: Integer;
  G: TGUID;
  Doc: TBsonValue;
begin
  case APlan.Kind of
    TBsonMemberKind.CustomSerializer:
      Exit(APlan.Serializer.Serialize(AValue));

    TBsonMemberKind.BoolValue:
      Exit(TBsonValue.NewBool(AValue.AsOrdinal <> 0));

    { An integer that fits in 32 bits is written as int32 and a wider one as
      int64. Nothing goes through Double: that is the distinction BSON exists
      to keep. }
    { A Cardinal above High(Integer) has no int32; int64 holds it exactly,
      where int32 wrote 4294967295 as -1. }
    TBsonMemberKind.IntValue:
      if AValue.AsOrdinal > High(Integer) then
        Exit(TBsonValue.NewInt64(AValue.AsOrdinal))
      else
        Exit(TBsonValue.NewInt32(Integer(AValue.AsOrdinal)));
    { A declared Int64 stays an int64 even when its current value would fit
      in 32 bits: the CONTRACT is 64-bit, and narrowing on the strength of
      one small value would make the wire type depend on the data. }
    { BSON has no unsigned 64-bit integer. A UInt64 that int64 holds is
      written as one; above High(Int64) it is refused, as the MongoDB
      drivers refuse it, rather than written as the negative number its
      bits spell. }
    TBsonMemberKind.Int64Value:
      begin
        if TSerializationTypes.IsUnsignedInteger(APlan.TypeInfo) and
           (TSerializationTypes.Int64Bits(AValue) < 0) then
          raise EBsonError.CreateFmt(
            '%s does not fit in a BSON int64, and BSON has no unsigned ' +
            'integer to hold it. Keep %s at or below %d, or register a BSON ' +
            'type serializer that writes it as decimal128 or text.',
            [TSerializationTypes.IntegerText(AValue),
             UTF8ToString(APlan.TypeInfo.Name), High(Int64)]);
        Exit(TBsonValue.NewInt64(TSerializationTypes.Int64Bits(AValue)));
      end;

    TBsonMemberKind.FloatValue:
      Exit(TBsonValue.NewDouble(AValue.AsExtended));

    TBsonMemberKind.CurrencyValue:
      case APlan.CurrencyRepresentation of
        TBsonCurrencyRepresentation.Double:
          Exit(TBsonValue.NewDouble(AValue.AsCurrency));
        TBsonCurrencyRepresentation.DecimalString:
          Exit(TBsonValue.NewString(
            CurrToStr(AValue.AsCurrency, TFormatSettings.Invariant)));
      else
        { Currency IS a scaled Int64 - four implied decimals - so writing that
          integer is exact in both directions. A double would be lossy past
          15 significant digits, and BSON has no fixed-point type to use
          instead. }
        Exit(TBsonValue.NewInt64(PInt64(AValue.GetReferenceToRawData)^));
      end;

    TBsonMemberKind.StrValue:
      Exit(TBsonValue.NewString(AValue.AsString));

    TBsonMemberKind.DateValue, TBsonMemberKind.TimeValue,
    TBsonMemberKind.DateTimeValue:
      Exit(DateToBson(APlan, AValue.AsType<TDateTime>));

    TBsonMemberKind.GuidValue:
      begin
        G := AValue.AsType<TGUID>;
        if APlan.GuidRepresentation = TBsonGuidRepresentation.LowercaseString then
          Exit(TBsonValue.NewString(LowerCase(Copy(GUIDToString(G), 2, 36))));
        Exit(TBsonValue.NewBinary(GuidToUuidBytes(G), TBsonBinarySubtype.Uuid));
      end;

    TBsonMemberKind.ObjectIdValue:
      Exit(TBsonValue.NewObjectId(AValue.AsType<TBsonObjectId>));

    TBsonMemberKind.BytesValue:
      Exit(TBsonValue.NewBinary(AValue.AsType<TBytes>,
        TBsonBinarySubtype.Generic));

    TBsonMemberKind.EnumValue:
      Exit(TBsonValue.NewString(
        EnumToText(APlan.TypeInfo, Integer(AValue.AsOrdinal), APlan.EnumMapping)));

    TBsonMemberKind.SetValue:
      Exit(TBsonValue.NewString(SetToText(APlan, AValue)));

    TBsonMemberKind.VariantValue:
      Exit(VariantToBson(AValue.AsVariant));

    TBsonMemberKind.NullableValue:
      begin
        Raw := AValue.GetReferenceToRawData;
        if not APlan.NullableAccess.HasValue(Raw) then Exit(TBsonValue.NewNull);
        Exit(WriteValue(APlan.Inner, APlan.NullableAccess.GetValue(Raw)));
      end;

    TBsonMemberKind.ObjectValue:
      begin
        Obj := AValue.AsObject;
        if Obj = nil then Exit(TBsonValue.NewNull);
        if not TSerializationGraphGuard.Enter(Obj) then RefuseCycle(Obj);
        try
          { The object body addresses its instance as an untyped pointer. }
          {$WARN UNSAFE_CAST OFF}
          Exit(WriteObjectBody(APlan.BoundPlan, Pointer(Obj)));
          {$WARN UNSAFE_CAST ON}
        finally
          TSerializationGraphGuard.Leave(Obj);
        end;
      end;

    { A record and an array count one level each, as an object does: a
      record holding a dynamic array of itself nests with no object in it,
      and it wrote what the reader refuses and then ran out of stack. }
    TBsonMemberKind.RecordValue:
      begin
        TSerializationGraphGuard.EnterLevel;
        try
          Exit(WriteObjectBody(APlan.BoundPlan, AValue.GetReferenceToRawData));
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
      end;

    TBsonMemberKind.ArrayValue:
      begin
        TSerializationGraphGuard.EnterLevel;
        try
          Doc := TBsonValue.NewArray;
          try
            for I := 0 to Integer(AValue.GetArrayLength) - 1 do
              Doc.Add(WriteValue(APlan.Item, AValue.GetArrayElement(I)));
          except
            Doc.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
        Exit(Doc);
      end;

    { A list or dictionary is an object: Enter counts its level and makes one
      that holds itself a cycle, not a stack overflow. }
    TBsonMemberKind.ListValue:
      begin
        Obj := AValue.AsObject;
        if Obj = nil then Exit(TBsonValue.NewNull);
        if not TSerializationGraphGuard.Enter(Obj) then RefuseCycle(Obj);
        try
          Doc := TBsonValue.NewArray;
          try
            Items := TSerializationTypes.ListElements(Obj, APlan.ContainerToArray);
            for I := 0 to Integer(Items.GetArrayLength) - 1 do
              Doc.Add(WriteValue(APlan.Item, Items.GetArrayElement(I)));
          except
            Doc.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.Leave(Obj);
        end;
        Exit(Doc);
      end;

    TBsonMemberKind.DictionaryValue:
      begin
        Obj := AValue.AsObject;
        if Obj = nil then Exit(TBsonValue.NewNull);
        if not TSerializationGraphGuard.Enter(Obj) then RefuseCycle(Obj);
        try
          Doc := TBsonValue.NewDocument;
          try
            Items := APlan.ContainerToArray.Invoke(Obj, []);
            for I := 0 to Integer(Items.GetArrayLength) - 1 do
            begin
              Pair := Items.GetArrayElement(I);
              K := APlan.PairKeyField.GetValue(Pair.GetReferenceToRawData);
              V := APlan.PairValueField.GetValue(Pair.GetReferenceToRawData);
              case APlan.Key.Kind of
                TBsonMemberKind.StrValue: Doc.Add(K.AsString, WriteValue(APlan.Value, V));
                TBsonMemberKind.EnumValue:
                  Doc.Add(EnumToText(APlan.Key.TypeInfo, Integer(K.AsOrdinal),
                    APlan.Key.EnumMapping), WriteValue(APlan.Value, V));
                TBsonMemberKind.GuidValue:
                  Doc.Add(LowerCase(Copy(GUIDToString(K.AsType<TGUID>), 2, 36)),
                    WriteValue(APlan.Value, V));
              else
                { Digits with the type's sign: AsOrdinal raised on a Comp and
                  wrote a UInt64 key as a negative number. }
                Doc.Add(TSerializationTypes.IntegerText(K), WriteValue(APlan.Value, V));
              end;
            end;
          except
            Doc.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.Leave(Obj);
        end;
        Exit(Doc);
      end;
  end;
  raise EBsonInternalError.CreateFmt('Cannot serialize %s.',
    [UTF8ToString(APlan.TypeInfo.Name)]);
end;

class function TBsonEngine.WriteObjectBody(APlan: TBsonTypePlan;
  AInstance: Pointer): TBsonValue;
var
  FP: TBsonFieldPlan;
  V: TValue;
  Raw: Pointer;
begin
  Result := TBsonValue.NewDocument;
  try
    for FP in APlan.Fields do
    begin
      V := ReadMember(FP, AInstance);
      { An empty nullable is omitted rather than written as BSON null, which
        matches every other format here. }
      if FP.Member.Kind = TBsonMemberKind.NullableValue then
      begin
        Raw := V.GetReferenceToRawData;
        if not FP.Member.NullableAccess.HasValue(Raw) then Continue;
      end;
      case FP.Member.Kind of
        TBsonMemberKind.ObjectValue, TBsonMemberKind.ListValue,
        TBsonMemberKind.DictionaryValue:
          if V.AsObject = nil then Continue;
        { Unassigned is no value at all, so the member is left out - which
          is how reading it back leaves the Variant Unassigned. }
        TBsonMemberKind.VariantValue:
          if VarIsEmpty(V.AsVariant) then Continue;
      end;
      Result.Add(FP.Name, WriteValue(FP.Member, V));
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ ------------------------------------------------------------- reading --- }

{ One element into a list or dictionary the read is filling.

  A repeated key goes through AddOrSetBuilt, which releases what the read
  built for the earlier occurrence: AddOrSetValue dropped it, and in a
  TDictionary<K, TObject> that was an orphan.

  What the container itself raises - a sorted TStringList with dupError
  refusing a duplicate line - is the document's fault, and reaches the
  caller as BSON input rather than as the RTL's exception. Either way the
  element that did not go in was this read's, and is released first. }
procedure AddElement(APlan: TBsonMemberPlan; AContainer: TObject;
  const AKey, AItem: TValue);
var
  ItemType: PTypeInfo;
begin
  try
    if APlan.Kind = TBsonMemberKind.ListValue then
      APlan.ContainerAdd.Invoke(AContainer, [AItem])
    else if APlan.DictAccess.IsValid then
      TSerializationOwnership.AddOrSetBuilt(APlan.DictAccess, AContainer,
        AKey, AItem)
    else
      APlan.ContainerAdd.Invoke(AContainer, [AKey, AItem]);
  except
    on E: Exception do
    begin
      if APlan.Kind = TBsonMemberKind.ListValue then ItemType := APlan.Item.TypeInfo
      else ItemType := APlan.Value.TypeInfo;
      TSerializationOwnership.ReleaseBuilt(ItemType, AItem, TValue.Empty);
      if string(E.UnitName).StartsWith('PascalForge.') then raise;
      raise EBsonInputError.CreateFmt(
        'The %s refused an element the document holds: %s',
        [AContainer.ClassName, E.Message]);
    end;
  end;
end;

class function TBsonEngine.ReadValue(APlan: TBsonMemberPlan;
  AValue: TBsonValue; const AExisting: TValue): TValue;
var
  Obj, Existing, Container: TObject;
  Built: Boolean;
  Inner, ItemValue, KeyValue: TValue;
  I: Integer;
  Arr: array of TValue;
  G: TGUID;
  Bytes: TBytes;
  S: string;
  D: Double;
  C: Currency;
  I64: Int64;
  Why: string;
begin
  case APlan.Kind of
    TBsonMemberKind.CustomSerializer:
      Exit(APlan.Serializer.Deserialize(AValue, APlan.TypeInfo, AExisting));

    TBsonMemberKind.BoolValue:
      Exit(TValue.FromOrdinal(APlan.TypeInfo, Ord(AValue.AsBool)));

    { Range-checked against the member's own type: FromOrdinal made a Byte
      out of 300 and a Cardinal out of -1. }
    TBsonMemberKind.IntValue, TBsonMemberKind.Int64Value:
      begin
        { An int32, an int64, or a double that is exactly integral - which
          is what the mongo shell and the JavaScript drivers write for 5, and
          what docs\bson-behavior.md promises is accepted. }
        if AValue.Kind = TBsonKind.Double then
        begin
          D := AValue.AsDouble;
          { The range first: Frac of an infinity is not a number. }
          if not BsonDoubleInInt64Range(D) or (Frac(D) <> 0) then
            raise EBsonInputError.CreateFmt(
              'Expected an integer for %s, found the double %s.',
              [UTF8ToString(APlan.TypeInfo.Name), AValue.Describe]);
          I64 := Trunc(D);
        end
        else if AValue.Kind in [TBsonKind.Int32, TBsonKind.Int64] then
          I64 := AValue.AsInt64
        else
          raise EBsonInputError.CreateFmt('Expected an integer for %s, found %s.',
            [UTF8ToString(APlan.TypeInfo.Name), AValue.Describe]);
        if not TSerializationTypes.TryIntegerFromInt64(APlan.TypeInfo,
             I64, Result) then
          raise EBsonInputError.CreateFmt('%d does not fit in %s.',
            [I64, UTF8ToString(APlan.TypeInfo.Name)]);
        Exit;
      end;

    { Into the member's own width, checked: a Single does not become
      infinity for a value it cannot hold. }
    TBsonMemberKind.FloatValue:
      begin
        if not TSerializationTypes.TryFloatFromDouble(APlan.TypeInfo,
             AValue.AsDouble, Result, S) then
          raise EBsonInputError.CreateFmt('%s: %s.',
            [UTF8ToString(APlan.TypeInfo.Name), S]);
        Exit;
      end;

    TBsonMemberKind.CurrencyValue:
      begin
        case AValue.Kind of
          TBsonKind.Int32, TBsonKind.Int64:
            begin
              { The scaled integer, read back exactly. }
              I64 := AValue.AsInt64;
              PInt64(@C)^ := I64;
            end;
          { Checked: NaN or 1e300 must not become -922337203685477.5808. }
          TBsonKind.Double:
            begin
              if not TSerializationTypes.TryFloatFromDouble(
                   System.TypeInfo(Currency), AValue.AsDouble, Inner, S) then
                raise EBsonInputError.CreateFmt('%s.', [S]);
              C := Inner.AsCurrency;
            end;
          TBsonKind.Str:
            if not TryStrToCurr(AValue.AsString, C, TFormatSettings.Invariant) then
              raise EBsonInputError.CreateFmt('"%s" is not a currency value.',
                [AValue.AsString]);
        else
          raise EBsonInputError.CreateFmt('Expected a currency, found %s.',
            [AValue.Describe]);
        end;
        Exit(TValue.From<Currency>(C));
      end;

    { Into the member's own code page, refusing text it cannot hold. }
    TBsonMemberKind.StrValue:
      begin
        S := AValue.AsString;
        if not TSerializationTypes.TryStringFromText(APlan.TypeInfo, S,
             Result, Why) then
          raise EBsonInputError.Create(Why + '.');
        Exit;
      end;

    TBsonMemberKind.VariantValue:
      Exit(BsonToVariant(APlan.TypeInfo, AValue));

    TBsonMemberKind.DateValue, TBsonMemberKind.TimeValue,
    TBsonMemberKind.DateTimeValue:
      begin
        D := BsonToDate(APlan, AValue);
        TValue.Make(@D, APlan.TypeInfo, Result);
        Exit;
      end;

    TBsonMemberKind.GuidValue:
      begin
        if AValue.Kind = TBsonKind.Str then
        begin
          S := Trim(AValue.AsString);
          if (S <> '') and (S[1] <> '{') then S := '{' + S + '}';
          try
            G := StringToGUID(S);
          except
            raise EBsonInputError.CreateFmt('"%s" is not a GUID.',
              [AValue.AsString]);
          end;
          Exit(TValue.From<TGUID>(G));
        end;
        Bytes := AValue.AsBytes;
        if Length(Bytes) <> 16 then
          raise EBsonInputError.CreateFmt(
            'A UUID is 16 bytes; this one is %d.', [Length(Bytes)]);
        { Subtype 4 in RFC 4122 order, as it is written. Sixteen bytes under
          any other subtype - the legacy subtype 3, whose order each driver
          chose for itself - are read as they always were, in TGUID's own
          layout. }
        if (AValue.Kind = TBsonKind.Binary) and
           (AValue.SubtypeByte = BSON_SUBTYPE_UUID) then
          G := UuidBytesToGuid(Bytes)
        else
          Move(Bytes[0], G, 16);
        Exit(TValue.From<TGUID>(G));
      end;

    TBsonMemberKind.ObjectIdValue:
      begin
        { An ObjectId element, or the 24-digit hexadecimal spelling a
          document written by hand is likely to carry. }
        if AValue.Kind = TBsonKind.Str then
          Exit(TValue.From<TBsonObjectId>(
            TBsonObjectId.FromHex(Trim(AValue.AsString))));
        Exit(TValue.From<TBsonObjectId>(AValue.AsObjectId));
      end;

    TBsonMemberKind.BytesValue:
      Exit(TValue.From<TBytes>(AValue.AsBytes));

    TBsonMemberKind.EnumValue:
      Exit(TValue.FromOrdinal(APlan.TypeInfo,
        TextToEnumOrdinal(APlan.TypeInfo, AValue.AsString, APlan.EnumMapping)));

    TBsonMemberKind.SetValue:
      Exit(TextToSet(APlan, AValue.AsString));

    TBsonMemberKind.NullableValue:
      begin
        TValue.Make(nil, APlan.TypeInfo, Result);
        if AValue.Kind = TBsonKind.Null then Exit;
        Inner := ReadValue(APlan.Inner, AValue, TValue.Empty);
        APlan.NullableAccess.SetValue(Result.GetReferenceToRawData, Inner);
        Exit;
      end;

    TBsonMemberKind.ObjectValue:
      begin
        if AValue.Kind = TBsonKind.Null then
        begin
          TValue.Make(nil, APlan.TypeInfo, Result);
          Exit;
        end;
        Existing := nil;
        if not AExisting.IsEmpty then Existing := AExisting.AsObject;
        Built := False;
        if (Existing = nil) or
           not Existing.InheritsFrom(APlan.BoundPlan.ClassType) then
        begin
          Obj := NewInstanceOf(APlan.BoundPlan);
          Built := True;
        end
        else
          Obj := Existing;
        try
          { The object body addresses its instance as an untyped pointer. }
          {$WARN UNSAFE_CAST OFF}
          ReadObjectBody(APlan.BoundPlan, Pointer(Obj), AValue);
          {$WARN UNSAFE_CAST ON}
        except
          if Built then Obj.Free;
          raise;
        end;
        TValue.Make(@Obj, APlan.TypeInfo, Result);
        Exit;
      end;

    TBsonMemberKind.RecordValue:
      begin
        { Into a COPY of the current value. Assigning the TValue shared its
          data, so the read changed AExisting too, and a failure could not
          tell the objects it had built from the ones that were there. }
        if AExisting.IsEmpty then TValue.Make(nil, APlan.TypeInfo, Result)
        else TValue.Make(AExisting.GetReferenceToRawData, APlan.TypeInfo, Result);
        try
          ReadObjectBody(APlan.BoundPlan, Result.GetReferenceToRawData, AValue);
        except
          { The record is stored only on success, so an object this read
            put in it before a later member failed went with the temporary. }
          TSerializationOwnership.ReleaseBuilt(APlan.TypeInfo, Result, AExisting);
          raise;
        end;
        Exit;
      end;

    TBsonMemberKind.ArrayValue:
      begin
        { A scalar where an array belongs is not an empty array: it is a
          document that does not match the contract. }
        if AValue.Kind <> TBsonKind.Arr then
          raise EBsonInputError.CreateFmt('Expected an array for %s, found %s.',
            [UTF8ToString(APlan.TypeInfo.Name), AValue.Describe]);
        { A static array has exactly as many elements as its type says. }
        if APlan.TypeInfo.Kind = tkArray then
        begin
          TValue.Make(nil, APlan.TypeInfo, Result);
          if AValue.Count <> Result.GetArrayLength then
            raise EBsonInputError.CreateFmt(
              '%s holds exactly %d elements, and the document has %d.',
              [UTF8ToString(APlan.TypeInfo.Name), Result.GetArrayLength, AValue.Count]);
          try
            for I := 0 to AValue.Count - 1 do
              Result.SetArrayElement(I, ReadValue(APlan.Item, AValue[I], TValue.Empty));
          except
            { Every element in the fresh array is this read's. }
            TSerializationOwnership.ReleaseBuilt(APlan.TypeInfo, Result,
              TValue.Empty);
            raise;
          end;
          Exit;
        end;
        SetLength(Arr, AValue.Count);
        try
          for I := 0 to AValue.Count - 1 do
            Arr[I] := ReadValue(APlan.Item, AValue[I], TValue.Empty);
        except
          { The elements read before the failure; the rest are still empty. }
          TSerializationOwnership.ReleaseBuiltElements(APlan.Item.TypeInfo, Arr);
          raise;
        end;
        Exit(TValue.FromArray(APlan.TypeInfo, Arr));
      end;

    TBsonMemberKind.ListValue, TBsonMemberKind.DictionaryValue:
      begin
        if AValue.Kind = TBsonKind.Null then
        begin
          TValue.Make(nil, APlan.TypeInfo, Result);
          Exit;
        end;
        { Checked BEFORE an existing container is cleared, so a document
          with a scalar here does not erase the caller's list and add
          nothing. }
        if (APlan.Kind = TBsonMemberKind.ListValue) and
           (AValue.Kind <> TBsonKind.Arr) then
          raise EBsonInputError.CreateFmt('Expected an array for %s, found %s.',
            [UTF8ToString(APlan.TypeInfo.Name), AValue.Describe]);
        if (APlan.Kind = TBsonMemberKind.DictionaryValue) and
           (AValue.Kind <> TBsonKind.Doc) then
          raise EBsonInputError.CreateFmt('Expected a document for %s, found %s.',
            [UTF8ToString(APlan.TypeInfo.Name), AValue.Describe]);
        Container := nil;
        if not AExisting.IsEmpty then Container := AExisting.AsObject;
        Built := Container = nil;
        if Built then Container := NewContainer(APlan)
        else if APlan.ContainerClear <> nil then
          APlan.ContainerClear.Invoke(Container, []);
        try
          for I := 0 to AValue.Count - 1 do
            if APlan.Kind = TBsonMemberKind.ListValue then
            begin
              ItemValue := ReadValue(APlan.Item, AValue[I], TValue.Empty);
              AddElement(APlan, Container, TValue.Empty, ItemValue);
            end
            else
            begin
              case APlan.Key.Kind of
                TBsonMemberKind.StrValue:
                  if not TSerializationTypes.TryStringFromText(
                       APlan.Key.TypeInfo, AValue.Names[I], KeyValue, S) then
                    raise EBsonInputError.CreateFmt('Key: %s.', [S]);
                TBsonMemberKind.EnumValue:
                  KeyValue := TValue.FromOrdinal(APlan.Key.TypeInfo,
                    TextToEnumOrdinal(APlan.Key.TypeInfo, AValue.Names[I],
                      APlan.Key.EnumMapping));
                TBsonMemberKind.GuidValue:
                  try
                    KeyValue := TValue.From<TGUID>(
                      StringToGUID('{' + AValue.Names[I] + '}'));
                  except
                    on E: EConvertError do
                      raise EBsonInputError.CreateFmt('The key "%s" is not a GUID.',
                        [AValue.Names[I]]);
                  end;
              else
                { Range-checked: FromOrdinal made the Byte key 300 into 44. }
                if not TSerializationTypes.TryIntegerFromText(
                     APlan.Key.TypeInfo, AValue.Names[I], KeyValue) then
                  raise EBsonInputError.CreateFmt('The key "%s" is not a %s.',
                    [AValue.Names[I], UTF8ToString(APlan.Key.TypeInfo.Name)]);
              end;
              ItemValue := ReadValue(APlan.Value, AValue[I], TValue.Empty);
              AddElement(APlan, Container, KeyValue, ItemValue);
            end;
        except
          { With the elements this read put in it, unless the container owns
            them: a TList<TObject> freed alone orphaned every one. }
          if Built then TSerializationOwnership.ReleaseBuiltContainer(Container);
          raise;
        end;
        TValue.Make(@Container, APlan.TypeInfo, Result);
        Exit;
      end;
  end;
  raise EBsonInternalError.CreateFmt('Cannot deserialize %s.',
    [UTF8ToString(APlan.TypeInfo.Name)]);
end;

class procedure TBsonEngine.ReadObjectBody(APlan: TBsonTypePlan;
  AInstance: Pointer; AValue: TBsonValue);
var
  FP: TBsonFieldPlan;
  Element: TBsonValue;
  Existing, NewValue: TValue;
begin
  if AValue.Kind <> TBsonKind.Doc then
    raise EBsonInputError.CreateFmt('Expected a document, found %s.',
      [AValue.Describe]);
  for FP in APlan.Fields do
  begin
    Element := AValue.Find(FP.Name);
    { An absent element leaves the member as it was - a document from a newer
      or older producer still deserializes. }
    if Element = nil then Continue;
    if not FP.Writable then Continue;

    if Element.Kind = TBsonKind.Null then
    begin
      { Null DETACHES; it never destroys. The serializer cannot prove it owns
        what a member points at, so it does not dispose of it. }
      case FP.Member.Kind of
        TBsonMemberKind.ObjectValue, TBsonMemberKind.ListValue,
        TBsonMemberKind.DictionaryValue, TBsonMemberKind.NullableValue:
          begin
            TValue.Make(nil, FP.Member.TypeInfo, NewValue);
            StoreMember(FP, AInstance, NewValue);
            Continue;
          end;
      end;
    end;

    Existing := ReadMember(FP, AInstance);
    NewValue := ReadValue(FP.Member, Element, Existing);
    StoreMember(FP, AInstance, NewValue);
  end;
end;

{ -------------------------------------------------------------- document --- }

class function TBsonEngine.ParseDocument(const AData: TBytes): TBsonValue;
begin
  Result := TBsonReader.Parse(AData);
end;

class function TBsonEngine.WriteDocument(AValue: TBsonValue): TBytes;
var
  W: TBsonWriter;
begin
  if AValue = nil then
    raise EBsonInternalError.Create(
      'WriteDocument needs a document; nil was given.');
  if AValue.Kind <> TBsonKind.Doc then
    raise EBsonInternalError.CreateFmt(
      'A BSON document is the only thing that can be a root; this is %s. ' +
      'Wrap the value in a type, or serialize a class or record.',
      [AValue.Describe]);
  W.FData := nil;
  W.FPos := 0;
  W.FDepth := 0;
  W.PutDocument(AValue);
  Result := W.Done;
end;

{ ------------------------------------------------------------------ root --- }

class function TBsonEngine.SerializeRootToBson(ATypeInfo: PTypeInfo;
  const AValue: TValue): TBsonValue;
var
  Plan: TBsonMemberPlan;
  Wrapped: TBsonValue;
  Mark: Integer;
begin
  FLock.Enter;
  try
    Plan := GetRootPlan(ATypeInfo);
    FFrozen := True;
  finally
    FLock.Leave;
  end;

  { The root counts as a level like any other. A failure deep in one write
    must not leave the next write on this thread starting part way down. }
  Mark := TSerializationGraphGuard.Level;
  try
    Result := WriteValue(Plan, AValue);
  finally
    TSerializationGraphGuard.RestoreLevel(Mark);
  end;
  if Result.Kind = TBsonKind.Doc then Exit;
  { BSON's root is always a document, so a root that is not one is wrapped
    under the name "value". Reading applies the same rule, so it round-trips
    - see docs\bson-behavior.md. }
  Wrapped := TBsonValue.NewDocument;
  try
    Wrapped.Add('value', Result);
  except
    Wrapped.Free;
    Result.Free;
    raise;
  end;
  Result := Wrapped;
end;

class function TBsonEngine.SerializeRoot(ATypeInfo: PTypeInfo;
  const AValue: TValue): TBytes;
var
  Doc: TBsonValue;
begin
  Doc := SerializeRootToBson(ATypeInfo, AValue);
  try
    Result := WriteDocument(Doc);
  finally
    Doc.Free;
  end;
end;

class function TBsonEngine.DeserializeRootFromBson(ATypeInfo: PTypeInfo;
  AValue: TBsonValue; const AExisting: TValue): TValue;
var
  Plan: TBsonMemberPlan;
  Inner: TBsonValue;
begin
  FLock.Enter;
  try
    Plan := GetRootPlan(ATypeInfo);
    FFrozen := True;
  finally
    FLock.Leave;
  end;
  if not (Plan.Kind in [TBsonMemberKind.ObjectValue,
    TBsonMemberKind.RecordValue, TBsonMemberKind.DictionaryValue]) then
  begin
    Inner := AValue.Find('value');
    if Inner = nil then
      raise EBsonInputError.CreateFmt(
        'A %s at the root is carried in a document under the name "value", ' +
        'and this document has no such element.',
        [UTF8ToString(ATypeInfo.Name)]);
    Exit(ReadValue(Plan, Inner, AExisting));
  end;
  Result := ReadValue(Plan, AValue, AExisting);
end;

class function TBsonEngine.DeserializeRoot(ATypeInfo: PTypeInfo;
  const AData: TBytes; const AExisting: TValue): TValue;
var
  Doc: TBsonValue;
begin
  Doc := ParseDocument(AData);
  try
    Result := DeserializeRootFromBson(ATypeInfo, Doc, AExisting);
  finally
    Doc.Free;
  end;
end;

{ ------------------------------------------------------- cross-format --- }

class function TBsonEngine.FromPayload(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload; AFrom: TSerializationFormat): TBytes;
var
  V: TValue;
begin
  V := TSerializationFormats.Get(AFrom).DeserializeTyped(ATypeInfo, ASource);
  try
    Result := SerializeRoot(ATypeInfo, V);
  finally
    TSerializationOwnership.Release(ATypeInfo, V);
  end;
end;

class function TBsonEngine.FromPayloadStructural(
  const ASource: TSerializationPayload; AFrom: TSerializationFormat;
  AProfile: TStructuralConversionProfile): TBytes;
var
  Tree: TDynamicValue;
  Doc, Wrapped: TBsonValue;
  Options: TStructuralConversionOptions;
begin
  { BSON's own type system covers every dynamic kind - integers, doubles,
    binary, timestamps, booleans, null - and BSON member names are arbitrary
    strings, so neither policy has anything to decide on the way OUT. BSON
    is the destination that never has to adapt anything, which is why
    "$type" stays "$type" on the way into BSON: name adaptation belongs to
    the destination that cannot spell the name, and BSON can.

    The profile still travels, because it decides what the SOURCE is allowed
    to recognize - Extended JSON is only read as Extended JSON under
    Lossless. }
  Options := TStructuralConversionOptions.FromProfile(AProfile).WithSource(AFrom)
    .WithDestination(TSerializationFormat.Bson);
  Tree := TSerializationFormats.Require(AFrom,
    TSerializationFormatCapability.StructuralParse).ToDynamic(ASource, Options);
  try
    Doc := DynamicToBson(Tree);
    try
      if Doc.Kind <> TBsonKind.Doc then
      begin
        Wrapped := TBsonValue.NewDocument;
        Wrapped.Add('value', Doc);
        Doc := Wrapped;
      end;
      Result := WriteDocument(Doc);
    finally
      Doc.Free;
    end;
  finally
    Tree.Free;
  end;
end;

{ ------------------------------------------------------ the dynamic tree --- }

{ ---------------------------------------------------------------------------
  BSON TYPES THE DYNAMIC TREE HAS NO BASIC KIND FOR

  The tree's basic kinds are null, bool, int, float, string, binary,
  datetime, array and object. BSON has eleven more, and an ObjectId is not
  any of those nine.

  They are NOT flattened to strings on the way in. Doing that would decide,
  here, that nobody downstream could have done better - and the downstream
  might be another BSON document, or a MongoDB Extended JSON writer that has
  an exact representation for every one of them. So each arrives as an
  Extended node: a tag naming the BSON type, and a payload carrying its
  parts.

  Nothing about this appears in any document. What a destination writes for
  an Extended node is that destination's decision, made under the profile
  the caller asked for, and it is either the destination's own idiomatic
  form or a published standard's - never an invention of this library's.

  The payload shape per tag, fixed here and relied on by every destination:

    ObjectId          Str, twenty-four lower-case hex characters
    Timestamp         Obj  t:Int seconds, i:Int increment
    Decimal128        Bytes, sixteen, little-endian BID
    Symbol            Str
    JavaScript        Str
    JavaScriptScope   Obj  code:Str, scope:Obj
    Undefined         Null
    MinKey, MaxKey    Null
    Regex             Obj  pattern:Str, options:Str
    DbPointer         Obj  namespace:Str, id:Str twenty-four hex
    BinarySubtype     Obj  subtype:Int, data:Bytes
  --------------------------------------------------------------------------- }

function NamedObject2(const AName1: string; AValue1: TDynamicValue;
  const AName2: string; AValue2: TDynamicValue): TDynamicValue;
begin
  Result := TDynamicValue.NewObject;
  try
    Result.AsObject.Adopt(AName1, AValue1);
    AValue1 := nil;
    Result.AsObject.Adopt(AName2, AValue2);
  except
    AValue1.Free;
    AValue2.Free;
    Result.Free;
    raise;
  end;
end;

class function TBsonEngine.BsonToDynamic(AValue: TBsonValue): TDynamicValue;
var
  I: Integer;
begin
  case AValue.Kind of
    TBsonKind.Null: Exit(TDynamicValue.NewNull);
    TBsonKind.Bool: Exit(TDynamicValue.NewBool(AValue.AsBool));
    TBsonKind.Int32, TBsonKind.Int64: Exit(TDynamicValue.NewInt(AValue.AsInt64));
    TBsonKind.Double: Exit(TDynamicValue.NewFloat(AValue.AsDouble));
    TBsonKind.Str: Exit(TDynamicValue.NewStr(AValue.AsString));
    TBsonKind.Binary:
      begin
        { Subtype 0 is exactly what the tree's Bytes means - "some bytes".
          Any other subtype, UUID included, is information Bytes cannot
          hold, so it keeps its byte. }
        if AValue.SubtypeByte = BSON_SUBTYPE_GENERIC then
          Exit(TDynamicValue.NewBytes(AValue.AsBytes));
        Exit(TDynamicValue.NewExtended(TDynamicTag.BinarySubtype,
          NamedObject2('subtype', TDynamicValue.NewInt(AValue.SubtypeByte),
                       'data', TDynamicValue.NewBytes(AValue.AsBytes))));
      end;
    { BSON states that this is a timestamp, so the dynamic tree can carry it
      as one. A JSON string that merely looks like a date cannot. }
    TBsonKind.DateTime: Exit(TDynamicValue.NewDateTime(AValue.AsDateTime));

    TBsonKind.ObjectId:
      Exit(TDynamicValue.NewExtended(TDynamicTag.ObjectId,
        TDynamicValue.NewStr(AValue.AsObjectId.ToHex)));
    TBsonKind.Timestamp:
      Exit(TDynamicValue.NewExtended(TDynamicTag.Timestamp,
        NamedObject2('t', TDynamicValue.NewInt(Int64(AValue.AsTimestamp shr 32)),
                     'i', TDynamicValue.NewInt(
                            Int64(AValue.AsTimestamp and $FFFFFFFF)))));
    TBsonKind.Decimal128:
      Exit(TDynamicValue.NewExtended(TDynamicTag.Decimal128,
        TDynamicValue.NewBytes(AValue.AsBytes)));
    TBsonKind.Symbol:
      Exit(TDynamicValue.NewExtended(TDynamicTag.Symbol,
        TDynamicValue.NewStr(AValue.AsString)));
    TBsonKind.JavaScript:
      Exit(TDynamicValue.NewExtended(TDynamicTag.JavaScript,
        TDynamicValue.NewStr(AValue.AsCode)));
    TBsonKind.Undefined:
      Exit(TDynamicValue.NewExtended(TDynamicTag.Undefined, nil));
    TBsonKind.MinKey:
      Exit(TDynamicValue.NewExtended(TDynamicTag.MinKey, nil));
    TBsonKind.MaxKey:
      Exit(TDynamicValue.NewExtended(TDynamicTag.MaxKey, nil));
    TBsonKind.Regex:
      Exit(TDynamicValue.NewExtended(TDynamicTag.Regex,
        NamedObject2('pattern', TDynamicValue.NewStr(AValue.AsPattern),
                     'options', TDynamicValue.NewStr(AValue.AsOptions))));
    TBsonKind.DbPointer:
      Exit(TDynamicValue.NewExtended(TDynamicTag.DbPointer,
        NamedObject2('namespace', TDynamicValue.NewStr(AValue.AsPattern),
                     'id', TDynamicValue.NewStr(AValue.AsObjectId.ToHex))));
    TBsonKind.JavaScriptScope:
      Exit(TDynamicValue.NewExtended(TDynamicTag.JavaScriptScope,
        NamedObject2('code', TDynamicValue.NewStr(AValue.AsCode),
                     'scope', BsonToDynamic(AValue.Scope))));

    TBsonKind.Arr:
      begin
        Result := TDynamicValue.NewArray;
        try
          for I := 0 to AValue.Count - 1 do Result.AsArray.Adopt(BsonToDynamic(AValue[I]));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
  end;
  Result := TDynamicValue.NewObject;
  try
    { Member names go through untouched. BSON member names are arbitrary
      strings and so are the tree's, so there is nothing to encode and
      nothing to escape - including a member a document chose to call
      "$oid", which stays a member called "$oid". }
    for I := 0 to AValue.Count - 1 do
      Result.AsObject.Adopt(AValue.Names[I], BsonToDynamic(AValue[I]));
  except
    Result.Free;
    raise;
  end;
end;

{ An Extended node becomes the BSON element it names. A tag this version
  does not know, or a payload that does not match the shape the tag
  promises, is a defect rather than input - the tags are produced inside
  this process - so it raises rather than guessing. }
function ExtendedToBson(AValue: TDynamicValue): TBsonValue;
var
  Payload: TDynamicValue;
  Tag: string;
  Id: TBsonObjectId;

  procedure Malformed;
  begin
    raise EBsonError.CreateFmt(
      'A %s value did not carry the parts that tag promises.', [Tag]);
  end;

  function Part(const AName: string; AKind: TDynamicKind): TDynamicValue;
  begin
    { Malformed raises, so nothing after a call to it runs - but the
      compiler cannot see that through a nested procedure, hence the
      explicit Exit. }
    if (Payload = nil) or (Payload.Kind <> TDynamicKind.Obj) then
    begin
      Malformed;
      Exit(nil);
    end;
    Result := Payload.Find(AName);
    if (Result = nil) or (Result.Kind <> AKind) then Malformed;
  end;

  function Str(const AName: string): string;
  begin
    Result := Part(AName, TDynamicKind.Str).AsStr;
  end;

  function Num(const AName: string): Int64;
  begin
    Result := Part(AName, TDynamicKind.Int).AsInt;
  end;

begin
  Tag := AValue.ExtendedTag;
  Payload := AValue.ExtendedValue;

  if Tag = TDynamicTag.Undefined then Exit(TBsonValue.NewUndefined);
  if Tag = TDynamicTag.MinKey then Exit(TBsonValue.NewMinKey);
  if Tag = TDynamicTag.MaxKey then Exit(TBsonValue.NewMaxKey);

  if Tag = TDynamicTag.ObjectId then
  begin
    if (Payload = nil) or (Payload.Kind <> TDynamicKind.Str) or
       not TBsonObjectId.TryFromHex(Payload.AsStr, Id) then Malformed;
    Exit(TBsonValue.NewObjectId(Id));
  end;
  if Tag = TDynamicTag.Symbol then
  begin
    if (Payload = nil) or (Payload.Kind <> TDynamicKind.Str) then Malformed;
    Exit(TBsonValue.NewSymbol(Payload.AsStr));
  end;
  if Tag = TDynamicTag.JavaScript then
  begin
    if (Payload = nil) or (Payload.Kind <> TDynamicKind.Str) then Malformed;
    Exit(TBsonValue.NewJavaScript(Payload.AsStr));
  end;
  if Tag = TDynamicTag.Decimal128 then
  begin
    if (Payload = nil) or (Payload.Kind <> TDynamicKind.Bytes) or
       (Length(Payload.AsBytes) <> TDecimal128.ByteLength) then Malformed;
    Exit(TBsonValue.NewDecimal128(Payload.AsBytes));
  end;
  if Tag = TDynamicTag.Timestamp then
    Exit(TBsonValue.NewTimestamp(
      (UInt64(Num('t')) shl 32) or (UInt64(Num('i')) and $FFFFFFFF)));
  if Tag = TDynamicTag.Regex then
    Exit(TBsonValue.NewRegex(Str('pattern'), Str('options')));
  if Tag = TDynamicTag.DbPointer then
  begin
    if not TBsonObjectId.TryFromHex(Str('id'), Id) then Malformed;
    Exit(TBsonValue.NewDbPointer(Str('namespace'), Id));
  end;
  if Tag = TDynamicTag.JavaScriptScope then
    Exit(TBsonValue.NewJavaScriptScope(Str('code'),
      TBsonEngine.DynamicToBson(Part('scope', TDynamicKind.Obj))));
  if Tag = TDynamicTag.BinarySubtype then
    Exit(TBsonValue.NewBinary(Part('data', TDynamicKind.Bytes).AsBytes,
      Byte(Num('subtype'))));

  raise EBsonError.CreateFmt(
    'BSON has no element type for the extended value "%s".', [Tag]);
end;

{ ---------------------------------------------------------------------------
  WHAT A PLAIN JSON DOCUMENT PROVES

  Going the other way, from a tree that came out of JSON, the rule is that
  the tree is taken at its word and nothing is inferred from spelling. A
  string of twenty-four hex characters is a string. "2026-03-14T09:26:53Z"
  is a string. A twelve-byte base64 blob is a string.

  BSON has an ObjectId, a UTC datetime, a binary and a decimal128, and any
  of the above COULD have been one - but plain JSON did not say so, and the
  difference between "could have been" and "was" is the difference between
  a converter and a guess. Callers who do know pass a schema
  (TBsonSerializer.FromJson with one) or use Extended JSON, both of which
  say it explicitly.
  --------------------------------------------------------------------------- }
class function TBsonEngine.DynamicToBson(AValue: TDynamicValue): TBsonValue;
var
  I: Integer;
  DecBytes: TBytes;
begin
  case AValue.Kind of
    TDynamicKind.Null: Exit(TBsonValue.NewNull);
    TDynamicKind.Bool: Exit(TBsonValue.NewBool(AValue.AsBool));
    TDynamicKind.Int:
      begin
        if (AValue.AsInt >= Low(Integer)) and (AValue.AsInt <= High(Integer)) then
          Exit(TBsonValue.NewInt32(Integer(AValue.AsInt)));
        Exit(TBsonValue.NewInt64(AValue.AsInt));
      end;
    { BSON has no unsigned sixty-four bit type and no arbitrary-precision
      decimal that is not decimal128. An unsigned value above High(Int64) is
      written as its two's-complement Int64 bits, which is what every MongoDB
      driver does and is reversible; a decimal becomes a decimal128 when it
      fits and a string when it does not, rather than a Double that quietly
      rounds it. }
    TDynamicKind.UInt:
      begin
        if AValue.AsUInt <= UInt64(High(Int64)) then
          Exit(TBsonValue.NewInt64(AValue.AsInt));
        { Past High(Int64) there is no BSON integer, and the two's-complement
          bits are a negative number to every reader. decimal128 holds the
          value exactly. }
        if TDecimal128.TryFromText(UIntToStr(AValue.AsUInt), DecBytes) then
          Exit(TBsonValue.NewDecimal128(DecBytes));
        Exit(TBsonValue.NewString(UIntToStr(AValue.AsUInt)));
      end;
    TDynamicKind.Decimal:
      begin
        if TDecimal128.TryFromText(AValue.AsDecimal, DecBytes) then
          Exit(TBsonValue.NewDecimal128(DecBytes));
        Exit(TBsonValue.NewString(AValue.AsDecimal));
      end;
    TDynamicKind.Float: Exit(TBsonValue.NewDouble(AValue.AsFloat));
    TDynamicKind.Str: Exit(TBsonValue.NewString(AValue.AsStr));
    TDynamicKind.Bytes: Exit(TBsonValue.NewBinary(AValue.AsBytes));
    { BSON has ONE temporal type and it is a UTC instant. A calendar day is
      not an instant, so writing one as 0x09 would claim a midnight nobody
      supplied; both reduced kinds go out as their ISO text instead. }
    TDynamicKind.Date:
      Exit(TBsonValue.NewString(TStructuralText.EncodeDate(AValue.AsDateTime)));
    TDynamicKind.Time:
      Exit(TBsonValue.NewString(TStructuralText.EncodeTime(AValue.AsDateTime)));
    TDynamicKind.DateTime: Exit(TBsonValue.NewDateTime(AValue.AsDateTime));
    TDynamicKind.Extended: Exit(ExtendedToBson(AValue));
    TDynamicKind.Arr:
      begin
        Result := TBsonValue.NewArray;
        try
          for I := 0 to AValue.Count - 1 do Result.Add(DynamicToBson(AValue[I]));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
  end;
  Result := TBsonValue.NewDocument;
  try
    { BSON member names are arbitrary strings, so every name goes through
      exactly as the tree spelled it. }
    for I := 0 to AValue.Count - 1 do
      Result.Add(AValue.Names[I], DynamicToBson(AValue[I]));
  except
    Result.Free;
    raise;
  end;
end;


{ ===========================================================================
  BSON AND JSON, AND THE SCHEMA THAT SITS BESIDE THEM

  The type names below are MongoDB's own $type aliases, so every one of them
  can be looked up in the BSON specification. A binary with a subtype other
  than the generic zero carries the byte after a colon - "binData:04" - which
  is the only spelling here that is not lifted straight from the standard,
  and it is one the standard leaves no room for.

  Nothing in this section reaches PascalForge.Json. JSON is produced and
  consumed through the format registry, exactly as every other cross-format
  operation in this unit is, so BSON keeps no compile-time knowledge that
  JSON exists.
  =========================================================================== }

const
  SCHEMA_VERSION_MEMBER = 'version';
  SCHEMA_TYPES_MEMBER   = 'types';
  SCHEMA_VERSION        = 1;

function BsonTypeName(AValue: TBsonValue): string;
begin
  case AValue.Kind of
    TBsonKind.Double:     Result := 'double';
    TBsonKind.Str:        Result := 'string';
    TBsonKind.Doc:        Result := 'object';
    TBsonKind.Arr:        Result := 'array';
    TBsonKind.Binary:
      if AValue.SubtypeByte = BSON_SUBTYPE_GENERIC then Result := 'binData'
      else Result := 'binData:' +
        TStructuralText.EncodeHex(TBytes.Create(AValue.SubtypeByte));
    TBsonKind.Undefined:  Result := 'undefined';
    TBsonKind.ObjectId:   Result := 'objectId';
    TBsonKind.Bool:       Result := 'bool';
    TBsonKind.DateTime:   Result := 'date';
    TBsonKind.Null:       Result := 'null';
    TBsonKind.Regex:      Result := 'regex';
    TBsonKind.DbPointer:  Result := 'dbPointer';
    TBsonKind.JavaScript: Result := 'javascript';
    TBsonKind.Symbol:     Result := 'symbol';
    TBsonKind.JavaScriptScope: Result := 'javascriptWithScope';
    TBsonKind.Int32:      Result := 'int';
    TBsonKind.Timestamp:  Result := 'timestamp';
    TBsonKind.Int64:      Result := 'long';
    TBsonKind.Decimal128: Result := 'decimal';
    TBsonKind.MinKey:     Result := 'minKey';
  else
    Result := 'maxKey';
  end;
end;

{ Every value's path and type, recorded whether or not plain JSON would have
  guessed it right. An exhaustive schema costs a few hundred bytes and
  removes every question about what was and was not recorded. }
procedure CollectSchema(AValue: TBsonValue; const APath: string;
  ATypes: TDynamicValue);
var
  I: Integer;
begin
  ATypes.AsObject.Adopt(APath, TDynamicValue.NewStr(BsonTypeName(AValue)));
  case AValue.Kind of
    TBsonKind.Doc:
      for I := 0 to AValue.Count - 1 do
        CollectSchema(AValue[I], TStructuralPath.Member(APath, AValue.Names[I]),
          ATypes);
    TBsonKind.Arr:
      for I := 0 to AValue.Count - 1 do
        CollectSchema(AValue[I], TStructuralPath.Index(APath, I), ATypes);
    TBsonKind.JavaScriptScope:
      CollectSchema(AValue.Scope, TStructuralPath.Member(APath, 'scope'),
        ATypes);
  end;
end;

function SchemaTreeOf(ADoc: TBsonValue): TDynamicValue;
var
  Types: TDynamicValue;
begin
  Result := TDynamicValue.NewObject;
  try
    Result.AsObject.Adopt(SCHEMA_VERSION_MEMBER, TDynamicValue.NewInt(SCHEMA_VERSION));
    Types := TDynamicValue.NewObject;
    Result.AsObject.Adopt(SCHEMA_TYPES_MEMBER, Types);
    CollectSchema(ADoc, TStructuralPath.Root, Types);
  except
    Result.Free;
    raise;
  end;
end;

{ One plain-JSON value, read back as the BSON type the schema names for it.
  A path the schema does not mention falls through to the conservative
  inference in DynamicToBson - which is the same answer a caller with no
  schema at all would have got. }
function CoerceToBson(AValue: TDynamicValue; const APath: string;
  ATypes: TDynamicValue): TBsonValue; forward;

function CoerceScalar(AValue: TDynamicValue; const AType: string;
  const APath: string; ATypes: TDynamicValue): TBsonValue;
var
  Bytes: TBytes;
  Id: TBsonObjectId;
  U64: UInt64;
  DT: TDateTime;
  Part: TDynamicValue;
  SubHex: string;

  procedure Reject(const AWhy: string);
  begin
    raise EBsonError.CreateFmt(
      'The schema says %s is a %s, and %s.', [APath, AType, AWhy]);
  end;

  function Text: string;
  begin
    if AValue.Kind <> TDynamicKind.Str then
      Reject('the document has something other than a string there');
    Result := AValue.AsStr;
  end;

  function Member(const AName: string): TDynamicValue;
  begin
    if AValue.Kind <> TDynamicKind.Obj then
      Reject('the document has something other than an object there');
    Result := AValue.Find(AName);
    if Result = nil then
      Reject(Format('the object there has no "%s" member', [AName]));
  end;

begin
  if AType = 'null' then Exit(TBsonValue.NewNull);
  if AType = 'undefined' then Exit(TBsonValue.NewUndefined);
  if AType = 'minKey' then Exit(TBsonValue.NewMinKey);
  if AType = 'maxKey' then Exit(TBsonValue.NewMaxKey);

  if AType = 'bool' then
  begin
    if AValue.Kind <> TDynamicKind.Bool then
      Reject('the document has something other than a boolean there');
    Exit(TBsonValue.NewBool(AValue.AsBool));
  end;
  if AType = 'string' then Exit(TBsonValue.NewString(Text));
  if AType = 'symbol' then Exit(TBsonValue.NewSymbol(Text));
  if AType = 'javascript' then Exit(TBsonValue.NewJavaScript(Text));

  if (AType = 'int') or (AType = 'long') then
  begin
    if AValue.Kind <> TDynamicKind.Int then
      Reject('the document has something other than a whole number there');
    if AType = 'int' then
    begin
      if (AValue.AsInt < Low(Integer)) or (AValue.AsInt > High(Integer)) then
        Reject('the number there does not fit in thirty-two bits');
      Exit(TBsonValue.NewInt32(Integer(AValue.AsInt)));
    end;
    Exit(TBsonValue.NewInt64(AValue.AsInt));
  end;
  if AType = 'double' then
  begin
    if AValue.Kind = TDynamicKind.Int then
      Exit(TBsonValue.NewDouble(AValue.AsInt));
    if AValue.Kind <> TDynamicKind.Float then
      Reject('the document has something other than a number there');
    Exit(TBsonValue.NewDouble(AValue.AsFloat));
  end;

  if AType = 'objectId' then
  begin
    if not TBsonObjectId.TryFromHex(Text, Id) then
      Reject('the text there is not twenty-four hex characters');
    Exit(TBsonValue.NewObjectId(Id));
  end;
  if AType = 'date' then
  begin
    if not TStructuralText.TryDecodeDateTime(Text, DT) then
      Reject('the text there is not a timestamp this library wrote');
    Exit(TBsonValue.NewDateTime(DT));
  end;
  if AType = 'timestamp' then
  begin
    if not TryStrToUInt64(Text, U64) then
      Reject('the text there is not a sixty-four bit unsigned number');
    Exit(TBsonValue.NewTimestamp(U64));
  end;
  if AType = 'decimal' then
  begin
    if not TDecimal128.TryFromText(Text, Bytes) then
      Reject('the text there is not a decimal this library can encode');
    Exit(TBsonValue.NewDecimal128(Bytes));
  end;
  if AType.StartsWith('binData') then
  begin
    if not TStructuralText.TryDecodeBinary(Text, Bytes) then
      Reject('the text there is not base64');
    SubHex := '';
    if AType.Length > Length('binData') then
      SubHex := AType.Substring(Length('binData') + 1);
    if SubHex = '' then Exit(TBsonValue.NewBinary(Bytes));
    Exit(TBsonValue.NewBinary(Bytes, Byte(StrToInt('$' + SubHex))));
  end;

  if AType = 'regex' then
    Exit(TBsonValue.NewRegex(Member('pattern').AsStr,
      Member('options').AsStr));
  if AType = 'dbPointer' then
  begin
    if not TBsonObjectId.TryFromHex(Member('id').AsStr, Id) then
      Reject('the id there is not twenty-four hex characters');
    Exit(TBsonValue.NewDbPointer(Member('namespace').AsStr, Id));
  end;
  if AType = 'javascriptWithScope' then
  begin
    Part := Member('scope');
    Exit(TBsonValue.NewJavaScriptScope(Member('code').AsStr,
      CoerceToBson(Part, TStructuralPath.Member(APath, 'scope'), ATypes)));
  end;

  raise EBsonError.CreateFmt(
    'The schema names a type, "%s", that this version does not know.',
    [AType]);
end;

function CoerceToBson(AValue: TDynamicValue; const APath: string;
  ATypes: TDynamicValue): TBsonValue;
var
  I: Integer;
  Named: TDynamicValue;
  TypeName: string;
begin
  Named := ATypes.Find(APath);
  TypeName := '';
  if (Named <> nil) and (Named.Kind = TDynamicKind.Str) then
    TypeName := Named.AsStr;

  if (TypeName = 'object') or
     ((TypeName = '') and (AValue.Kind = TDynamicKind.Obj)) then
  begin
    if AValue.Kind <> TDynamicKind.Obj then
      raise EBsonError.CreateFmt(
        'The schema says %s is an object and the document has something ' +
        'else there.', [APath]);
    Result := TBsonValue.NewDocument;
    try
      for I := 0 to AValue.Count - 1 do
        Result.Add(AValue.Names[I], CoerceToBson(AValue[I],
          TStructuralPath.Member(APath, AValue.Names[I]), ATypes));
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  if (TypeName = 'array') or
     ((TypeName = '') and (AValue.Kind = TDynamicKind.Arr)) then
  begin
    if AValue.Kind <> TDynamicKind.Arr then
      raise EBsonError.CreateFmt(
        'The schema says %s is an array and the document has something ' +
        'else there.', [APath]);
    Result := TBsonValue.NewArray;
    try
      for I := 0 to AValue.Count - 1 do
        Result.Add(CoerceToBson(AValue[I], TStructuralPath.Index(APath, I),
          ATypes));
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  { No entry for this path: the caller gets what a caller with no schema at
    all would have got, which is what plain JSON proves and nothing more. }
  if TypeName = '' then Exit(TBsonEngine.DynamicToBson(AValue));

  Result := CoerceScalar(AValue, TypeName, APath, ATypes);
end;

{ Reading a document into the tree, through the registry, with the profile
  the caller's mode implies. }
function JsonTextToTree(const AJson: string;
  AProfile: TStructuralConversionProfile): TDynamicValue;
var
  Options: TStructuralConversionOptions;
begin
  Options := TStructuralConversionOptions.FromProfile(AProfile)
    .WithSource(TSerializationFormat.Json)
    .WithDestination(TSerializationFormat.Bson);
  Result := TSerializationFormats.Require(TSerializationFormat.Json,
    TSerializationFormatCapability.StructuralParse).ToDynamic(
      TSerializationPayload.FromText(AJson), Options);
end;

function TreeToJsonText(ATree: TDynamicValue;
  AProfile: TStructuralConversionProfile): string;
var
  Options: TStructuralConversionOptions;
begin
  Options := TStructuralConversionOptions.FromProfile(AProfile)
    .WithSource(TSerializationFormat.Bson)
    .WithDestination(TSerializationFormat.Json);
  Result := TSerializationFormats.Require(TSerializationFormat.Json,
    TSerializationFormatCapability.StructuralWrite)
      .FromDynamic(ATree, Options).AsText;
end;

class function TBsonEngine.DocumentToJson(const AData: TBytes;
  AProfile: TStructuralConversionProfile): string;
var
  Doc: TBsonValue;
  Tree: TDynamicValue;
begin
  Doc := ParseDocument(AData);
  try
    Tree := BsonToDynamic(Doc);
    try
      Result := TreeToJsonText(Tree, AProfile);
    finally
      Tree.Free;
    end;
  finally
    Doc.Free;
  end;
end;

class function TBsonEngine.DocumentToJsonWithSchema(const AData: TBytes;
  out ASchema: string): string;
var
  Doc: TBsonValue;
  Tree, Schema: TDynamicValue;
begin
  Doc := ParseDocument(AData);
  try
    Schema := SchemaTreeOf(Doc);
    try
      ASchema := TreeToJsonText(Schema, TStructuralConversionProfile.Natural);
    finally
      Schema.Free;
    end;
    Tree := BsonToDynamic(Doc);
    try
      Result := TreeToJsonText(Tree, TStructuralConversionProfile.Natural);
    finally
      Tree.Free;
    end;
  finally
    Doc.Free;
  end;
end;

class function TBsonEngine.JsonToDocument(const AJson: string;
  AProfile: TStructuralConversionProfile): TBytes;
var
  Tree: TDynamicValue;
  Doc: TBsonValue;
begin
  Tree := JsonTextToTree(AJson, AProfile);
  try
    Doc := DynamicToBson(Tree);
    try
      if Doc.Kind <> TBsonKind.Doc then
        raise EBsonError.Create(
          'A BSON document has to be a document at the top level, and this ' +
          'JSON is not an object.');
      Result := WriteDocument(Doc);
    finally
      Doc.Free;
    end;
  finally
    Tree.Free;
  end;
end;

class function TBsonEngine.JsonToDocumentWithSchema(const AJson,
  ASchema: string): TBytes;
var
  Tree, Schema, Types: TDynamicValue;
  Doc: TBsonValue;
begin
  Schema := JsonTextToTree(ASchema, TStructuralConversionProfile.Natural);
  try
    if Schema.Kind <> TDynamicKind.Obj then
      raise EBsonError.Create('A BSON type schema has to be an object.');
    Types := Schema.Find(SCHEMA_TYPES_MEMBER);
    if (Types = nil) or (Types.Kind <> TDynamicKind.Obj) then
      raise EBsonError.Create(
        'A BSON type schema has to carry a "types" object mapping each ' +
        'value path to its BSON type name.');

    Tree := JsonTextToTree(AJson, TStructuralConversionProfile.Natural);
    try
      Doc := CoerceToBson(Tree, TStructuralPath.Root, Types);
      try
        if Doc.Kind <> TBsonKind.Doc then
          raise EBsonError.Create(
            'A BSON document has to be a document at the top level, and ' +
            'this JSON is not an object.');
        Result := WriteDocument(Doc);
      finally
        Doc.Free;
      end;
    finally
      Tree.Free;
    end;
  finally
    Schema.Free;
  end;
end;
{ --------------------------------------------------------- configuration --- }

class procedure TBsonEngine.SetDateTimePolicy(ATypeInfo: PTypeInfo;
  const AFieldName: string; AKind: Integer; const APattern: string);
var
  Policy: TDateTimePolicy;
  TypeKey: string;
begin
  CheckNotFrozen;
  Policy := TDateTimePolicy.Make(AKind, APattern);
  TypeKey := '';
  if ATypeInfo <> nil then TypeKey := TypeKeyOf(ATypeInfo);
  FLock.Enter;
  try
    if ATypeInfo = nil then
    begin
      FDatePolicies.SetGlobal(Policy);
      FTimePolicies.SetGlobal(Policy);
      FTimestampPolicies.SetGlobal(Policy);
    end
    else if AFieldName = '' then
    begin
      FDatePolicies.SetForType(TypeKey, Policy);
      FTimePolicies.SetForType(TypeKey, Policy);
      FTimestampPolicies.SetForType(TypeKey, Policy);
    end
    else
    begin
      FDatePolicies.SetForField(TypeKey, AFieldName, Policy);
      FTimePolicies.SetForField(TypeKey, AFieldName, Policy);
      FTimestampPolicies.SetForField(TypeKey, AFieldName, Policy);
    end;
  finally
    FLock.Leave;
  end;
end;

class procedure TBsonEngine.RegisterEnumMapping(ATypeInfo: PTypeInfo;
  const AValues: array of string);
var
  Values: TArray<string>;
  I: Integer;
begin
  CheckNotFrozen;
  if (ATypeInfo = nil) or (ATypeInfo.Kind <> tkEnumeration) then
    raise EBsonInternalError.Create(
      'RegisterEnumMapping needs an enumeration type.');
  SetLength(Values, Length(AValues));
  for I := 0 to Integer(High(AValues)) do Values[I] := AValues[I];
  FLock.Enter;
  try
    FEnumMappings.AddOrSetValue(ATypeInfo, Values);
  finally
    FLock.Leave;
  end;
end;

class procedure TBsonEngine.RegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TBsonValueSerializerClass);
begin
  CheckNotFrozen;
  if (ATypeInfo = nil) or (ASerializerClass = nil) then
    raise EBsonInternalError.Create(
      'RegisterTypeSerializer needs a type and a serializer class.');
  FLock.Enter;
  try
    FTypeSerializers.AddOrSetValue(ATypeInfo, ASerializerClass);
  finally
    FLock.Leave;
  end;
end;

class procedure TBsonEngine.FreezeConfiguration;
begin
  FFrozen := True;
end;

class function TBsonEngine.IsFrozen: Boolean;
begin
  Result := FFrozen;
end;

class procedure TBsonEngine.ResetConfiguration;
var
  P: TBsonTypePlan;
begin
  FLock.Enter;
  try
    for P in FPlans.Values do P.Free;
    FPlans.Clear;
    FRootPlans.Clear;
    FEnumMappings.Clear;
    FTypeSerializers.Clear;
    FSerializerSingletons.Clear;
    FDatePolicies.Reset;
    FTimePolicies.Reset;
    FTimestampPolicies.Reset;
    FBuildTrail.Clear;
    FFrozen := False;
  finally
    FLock.Leave;
  end;
end;

class function TBsonEngine.PlanCount: Integer;
begin
  Result := Integer(FPlans.Count);
end;

end.
