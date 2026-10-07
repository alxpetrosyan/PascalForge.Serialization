{*******************************************************************************
  PascalForge.MessagePack.Internal

  INTERNAL IMPLEMENTATION UNIT - applications should not use this unit directly.

  Implements the MessagePack engine: reader, writer and the plan-based
  contract engine.
  Exposed through the public facade PascalForge.MessagePack
  (TMessagePackSerializer).

  Registration
    Format registration lives in PascalForge.MessagePack.Registration and is
    explicit.

  Documentation
    docs/formats/messagepack.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.MessagePack.Internal;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  The MessagePack engine.

  Not public API. Use TMessagePackSerializer.

  Three parts, in the order they appear below:

    1. a reader   - MessagePack bytes -> TMessagePackValue tree
    2. a writer   - TMessagePackValue tree -> MessagePack bytes
    3. the engine - Delphi value <-> TMessagePackValue tree, through cached
                    plans

  The engine talks to MessagePack and to Delphi and to nothing else. It has no
  reference to PascalForge.Json, to PascalForge.Bson, or to any other format:
  the only way another format enters this unit is through the registry in
  PascalForge.Serialization.Core, by TSerializationFormat, at run time.

  Nothing here goes through JSON text. An integer is written as an integer and
  read back as one; a TDateTime is extension type -1; TBytes is bin and a
  string is str. Routing through another format's text would lose every one of
  those distinctions, which is the whole reason MessagePack exists.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.SyncObjs, System.DateUtils, System.Math, System.Variants,
  System.Generics.Collections,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Serialization.Internal,
  PascalForge.MessagePack;

const
  { Every format family the specification defines. The fixed-prefix families -
    positive fixint, negative fixint, fixmap, fixarray, fixstr - are ranges
    rather than single bytes and are spelled as their bounds. }
  MSGPACK_POSITIVE_FIXINT_MAX = $7F;
  MSGPACK_FIXMAP_MIN          = $80;
  MSGPACK_FIXMAP_MAX          = $8F;
  MSGPACK_FIXARRAY_MIN        = $90;
  MSGPACK_FIXARRAY_MAX        = $9F;
  MSGPACK_FIXSTR_MIN          = $A0;
  MSGPACK_FIXSTR_MAX          = $BF;
  MSGPACK_NIL                 = $C0;
  { The specification's own words for this byte are "never used". }
  MSGPACK_NEVER_USED          = $C1;
  MSGPACK_FALSE               = $C2;
  MSGPACK_TRUE                = $C3;
  MSGPACK_BIN8                = $C4;
  MSGPACK_BIN16               = $C5;
  MSGPACK_BIN32               = $C6;
  MSGPACK_EXT8                = $C7;
  MSGPACK_EXT16               = $C8;
  MSGPACK_EXT32               = $C9;
  MSGPACK_FLOAT32             = $CA;
  MSGPACK_FLOAT64             = $CB;
  MSGPACK_UINT8               = $CC;
  MSGPACK_UINT16              = $CD;
  MSGPACK_UINT32              = $CE;
  MSGPACK_UINT64              = $CF;
  MSGPACK_INT8                = $D0;
  MSGPACK_INT16               = $D1;
  MSGPACK_INT32               = $D2;
  MSGPACK_INT64               = $D3;
  MSGPACK_FIXEXT1             = $D4;
  MSGPACK_FIXEXT2             = $D5;
  MSGPACK_FIXEXT4             = $D6;
  MSGPACK_FIXEXT8             = $D7;
  MSGPACK_FIXEXT16            = $D8;
  MSGPACK_STR8                = $D9;
  MSGPACK_STR16               = $DA;
  MSGPACK_STR32               = $DB;
  MSGPACK_ARRAY16             = $DC;
  MSGPACK_ARRAY32             = $DD;
  MSGPACK_MAP16               = $DE;
  MSGPACK_MAP32               = $DF;
  MSGPACK_NEGATIVE_FIXINT_MIN = $E0;

{ ---------------------------------------------------------------------------
  TDateTime AND THE TIMESTAMP EXTENSION

  A TDateTime is a count of days as a floating-point number; the timestamp
  extension carries seconds and nanoseconds since the Unix epoch. The
  conversion goes through whole milliseconds because that is the finest unit a
  TDateTime actually resolves, and because an inline division would be
  evaluated as Extended on Win32 and as Double on Win64 - the same expression
  producing two different instants depending on the build.
  --------------------------------------------------------------------------- }

procedure MessagePackDateTimeToUnix(AValue: TDateTime; out ASeconds: Int64;
  out ANanoseconds: Cardinal);
function MessagePackUnixToDateTime(ASeconds: Int64;
  ANanoseconds: Cardinal): TDateTime;
{ False for an instant outside the year 1 to year 9999 range a TDateTime can
  hold. A 96-bit timestamp reaches far outside it, and such a value stays an
  extension rather than being folded into a date it cannot be. }
function MessagePackSecondsFitDateTime(ASeconds: Int64): Boolean;

{ True when ADouble is a finite value -2^63 <= ADouble < 2^63, so Trunc of it
  is an Int64. Integrality is the caller's own rule. }
function MessagePackDoubleInInt64Range(ADouble: Double): Boolean;

type
  TMessagePackMemberKind = (
    Unsupported,
    BoolValue,
    { Signed and unsigned are separate kinds all the way down, because the
      top half of the unsigned 64-bit range has no signed equivalent. }
    IntValue, UIntValue, Int64Value, UInt64Value,
    SingleValue, FloatValue, CurrencyValue, StrValue,
    DateValue, TimeValue, DateTimeValue, GuidValue, BytesValue,
    EnumValue, SetValue, NullableValue,
    ObjectValue, RecordValue,
    ListValue, DictionaryValue, ArrayValue,
    CustomSerializer, VariantValue);

  TMessagePackTypePlan = class;

  TMessagePackMemberPlan = class
  public
    TypeInfo: PTypeInfo;
    Kind: TMessagePackMemberKind;

    NullableAccess: TNullableAccess;
    Inner: TMessagePackMemberPlan;      { owned }

    EnumMapping: TArray<string>;
    SetElemTypeInfo: PTypeInfo;
    SetElemMapping: TArray<string>;

    BoundPlan: TMessagePackTypePlan;    { BORROWED - it lives in the plan cache }

    Item: TMessagePackMemberPlan;       { owned }
    Key: TMessagePackMemberPlan;        { owned }
    Value: TMessagePackMemberPlan;      { owned }
    ContainerAdd: TRttiMethod;
    ContainerClear: TRttiMethod;
    ContainerToArray: TRttiMethod;
    ContainerCreate: TRttiMethod;
    PairKeyField: TRttiField;
    PairValueField: TRttiField;
    { A dictionary's, for TSerializationOwnership.AddOrSetBuilt: a key the
      document repeats must not orphan the value read for it first. }
    DictionaryAccess: TDictionaryAccess;

    Serializer: TCustomMessagePackValueSerializer;   { BORROWED singleton }

    { Representations, resolved once while the plan is built. }
    DateRepresentation: TMessagePackDateTimeRepresentation;
    DatePattern: string;
    GuidRepresentation: TMessagePackGuidRepresentation;
    CurrencyRepresentation: TMessagePackCurrencyRepresentation;
    EnumRepresentation: TMessagePackEnumRepresentation;

    destructor Destroy; override;
    function IsContainer: Boolean;
  end;

  TMessagePackFieldPlan = class
  public
    Member: TMessagePackMemberPlan;     { owned }
    Field: TRttiField;                  { exactly one of these two is set }
    Prop: TRttiProperty;
    DelphiName: string;
    DeclaringTypeName: string;
    Name: string;
    Writable: Boolean;
    destructor Destroy; override;
  end;

  TMessagePackTypePlan = class
  public
    TypeInfo: PTypeInfo;
    RttiType: TRttiType;
    ClassType: TClass;
    IsRecord: Boolean;
    TypeKey: string;
    UnitName: string;
    Fields: TObjectList<TMessagePackFieldPlan>;
    ZeroConstructor: TRttiMethod;
    constructor Create;
    destructor Destroy; override;
  end;

  TMessagePackEngine = class
  strict private
    class var FCtx: TRttiContext;
    class var FLock: TCriticalSection;
    class var FPlans: TDictionary<PTypeInfo, TMessagePackTypePlan>;
    class var FRootPlans: TObjectDictionary<PTypeInfo, TMessagePackMemberPlan>;
    class var FEnumMappings: TDictionary<PTypeInfo, TArray<string>>;
    class var FTypeSerializers:
      TDictionary<PTypeInfo, TMessagePackValueSerializerClass>;
    class var FSerializerSingletons:
      TObjectDictionary<TClass, TCustomMessagePackValueSerializer>;
    class var FDatePolicies: TDateTimePolicies;
    class var FTimePolicies: TDateTimePolicies;
    class var FTimestampPolicies: TDateTimePolicies;
    class var FFrozen: Boolean;
    class var FBuildTrail: TList<PTypeInfo>;
    class var FBuildDepth: Integer;

    class procedure CheckNotFrozen; static;
    class procedure RollbackBuildTrail; static;
    class function PoliciesFor(AKind: TMessagePackMemberKind): TDateTimePolicies; static;
    class function ResolveSerializer(
      AClass: TMessagePackValueSerializerClass): TCustomMessagePackValueSerializer; static;
    class function EnumMappingFor(ATypeInfo: PTypeInfo): TArray<string>; static;
    class procedure ApplyGeneralEnum(APlan: TMessagePackMemberPlan;
      const AValues: TArray<string>); static;

    class function ClassifyType(ATypeInfo: PTypeInfo): TMessagePackMemberKind; static;
    class function GetPlan(ATypeInfo: PTypeInfo;
      const AUnitHint: string): TMessagePackTypePlan; static;
    class function BuildPlan(ATypeInfo: PTypeInfo;
      const AUnitHint: string): TMessagePackTypePlan; static;
    class procedure BuildMemberOfType(APlan: TMessagePackTypePlan;
      AMember: TSerializationMember); static;
    class function BuildMemberPlan(ATypeInfo: PTypeInfo;
      const AOwnerKey, AMemberName: string): TMessagePackMemberPlan; static;
    class function GetRootPlan(ATypeInfo: PTypeInfo): TMessagePackMemberPlan; static;

    class function NewInstanceOf(APlan: TMessagePackTypePlan): TObject; static;
    class function NewContainer(APlan: TMessagePackMemberPlan): TObject; static;
    class function ReadMember(AFP: TMessagePackFieldPlan;
      AInstance: Pointer): TValue; static;
    class procedure StoreMember(AFP: TMessagePackFieldPlan; AInstance: Pointer;
      const AValue: TValue); static;

    class function EnumToText(ATypeInfo: PTypeInfo; AOrdinal: Integer;
      const AMapping: TArray<string>): string; static;
    class function TextToEnumOrdinal(ATypeInfo: PTypeInfo; const AText: string;
      const AMapping: TArray<string>): Integer; static;
    class function EnumToValue(APlan: TMessagePackMemberPlan;
      AOrdinal: Integer): TMessagePackValue; static;
    class function ValueToEnumOrdinal(APlan: TMessagePackMemberPlan;
      AValue: TMessagePackValue): Integer; static;
    class function SetToValue(APlan: TMessagePackMemberPlan;
      const AValue: TValue): TMessagePackValue; static;
    class function ValueToSet(APlan: TMessagePackMemberPlan;
      AValue: TMessagePackValue): TValue; static;

    class function WriteValue(APlan: TMessagePackMemberPlan;
      const AValue: TValue): TMessagePackValue; static;
    class function WriteObjectBody(APlan: TMessagePackTypePlan;
      AInstance: Pointer): TMessagePackValue; static;
    class function ReadValue(APlan: TMessagePackMemberPlan;
      AValue: TMessagePackValue; const AExisting: TValue): TValue; static;
    class function ContainerHolds(APlan: TMessagePackMemberPlan;
      AContainer: TObject; const AItem: TValue): Boolean; static;
    class procedure AddElement(APlan: TMessagePackMemberPlan;
      AContainer: TObject; const AKey, AItem: TValue); static;
    class procedure ReadObjectBody(APlan: TMessagePackTypePlan;
      AInstance: Pointer; AValue: TMessagePackValue); static;

    class function DateToValue(APlan: TMessagePackMemberPlan;
      AValue: TDateTime): TMessagePackValue; static;
    class function ValueToDate(APlan: TMessagePackMemberPlan;
      AValue: TMessagePackValue): TDateTime; static;
  public
    class constructor Create;
    class destructor Destroy;

    { --- the document --- }
    class function ParseDocument(const AData: TBytes): TMessagePackValue; static;
    class function WriteDocument(AValue: TMessagePackValue): TBytes; static;

    { --- contract-aware --- }
    class function SerializeRoot(ATypeInfo: PTypeInfo;
      const AValue: TValue): TBytes; static;
    class function DeserializeRoot(ATypeInfo: PTypeInfo; const AData: TBytes;
      const AExisting: TValue): TValue; static;
    class function SerializeRootToValue(ATypeInfo: PTypeInfo;
      const AValue: TValue): TMessagePackValue; static;
    class function DeserializeRootFromValue(ATypeInfo: PTypeInfo;
      AValue: TMessagePackValue; const AExisting: TValue): TValue; static;

    { --- cross-format, reached only through the registry --- }
    class function FromPayload(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; static;
    class function FromPayloadStructural(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat;
      AProfile: TStructuralConversionProfile): TBytes; static;

    { --- the dynamic tree (structural conversion only) --- }
    class function MessagePackToDynamic(AValue: TMessagePackValue;
      const AOptions: TStructuralConversionOptions;
      const APath: string): TDynamicValue; static;
    class function DynamicToMessagePack(AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions;
      const APath: string): TMessagePackValue; static;

    { --- configuration --- }
    class procedure SetDateTimePolicy(ATypeInfo: PTypeInfo;
      const AFieldName: string; AKind: Integer;
      const APattern: string); static;
    class procedure RegisterEnumMapping(ATypeInfo: PTypeInfo;
      const AValues: array of string); static;
    class procedure RegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TMessagePackValueSerializerClass); static;
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;
    class procedure ResetConfiguration; static;
    class function PlanCount: Integer; static;
  end;

implementation

const
  { The instants at the two ends of what a TDateTime holds - 0001-01-01
    00:00:00 and 9999-12-31 23:59:59 - as seconds since the Unix epoch. }
  MIN_DATETIME_SECONDS = Int64(-62135596800);
  MAX_DATETIME_SECONDS = Int64(253402300799);

  NANOSECONDS_PER_SECOND = 1000000000;
  NANOSECONDS_PER_MILLISECOND = 1000000;

  { -2^63 and 2^63, both exactly a Double, typed as Double so Win32 (which
    compares at Extended precision) compares the very values Win64 does.
    High(Int64) is not a Double. }
  MSGPACK_INT64_LOW_AS_DOUBLE: Double = -9223372036854775808.0;
  MSGPACK_INT64_END_AS_DOUBLE: Double = 9223372036854775808.0;

function MessagePackDoubleInInt64Range(ADouble: Double): Boolean;
begin
  Result := not ADouble.IsNan and (ADouble >= MSGPACK_INT64_LOW_AS_DOUBLE) and
    (ADouble < MSGPACK_INT64_END_AS_DOUBLE);
end;

{ A length the writer indexes with as an Integer. Length is NativeInt on
  Win64, so 2 GiB or more wrapped to a negative size and a wrong header (a
  fixstr for a 4 GiB string); it is refused instead. }
function MessagePackWriterCount(ALength: NativeInt): Integer;
begin
  if Int64(ALength) > MaxInt then
    raise EMessagePackInternalError.CreateFmt(
      'A value of %d bytes is too large to write; the limit here is 2 GiB.',
      [Int64(ALength)]);
  Result := Integer(ALength);
end;

{ Whole milliseconds since the epoch, for every epoch writer here. A TDateTime
  before 1899-12-30 is a negative day with a POSITIVE time of day, so the
  linear (AValue - UnixDateDelta) * MSecsPerDay put every such instant a day
  early; Core follows the encoding. An instant outside the years 1 to 9999 is
  refused before anything is written, because every reader refuses it back. }
function DateTimeToUnixMillis(AValue: TDateTime): Int64;
begin
  TStructuralText.CheckDateTime(AValue);
  if not TStructuralText.TryDateTimeToUnixMillis(AValue, Result) then
    raise ESerializationUnsupported.CreateFmt(
      'The TDateTime %s rounds to an instant after 9999-12-31T23:59:59.999, ' +
      'which no reader here accepts back.',
      [FloatToStr(AValue, TFormatSettings.Invariant)]);
end;

procedure MessagePackDateTimeToUnix(AValue: TDateTime; out ASeconds: Int64;
  out ANanoseconds: Cardinal);
var
  Milliseconds, Whole, Remainder: Int64;
begin
  Milliseconds := DateTimeToUnixMillis(AValue);
  Whole := Milliseconds div 1000;
  Remainder := Milliseconds mod 1000;
  { Delphi's mod takes the sign of the dividend, so an instant before the
    epoch yields a negative remainder. The timestamp extension's nanosecond
    field is unsigned, so the borrow happens here rather than being written
    as a negative fraction that no other implementation would read back. }
  if Remainder < 0 then
  begin
    Dec(Whole);
    Inc(Remainder, 1000);
  end;
  ASeconds := Whole;
  ANanoseconds := Cardinal(Remainder * NANOSECONDS_PER_MILLISECOND);
end;

function MessagePackUnixToDateTime(ASeconds: Int64;
  ANanoseconds: Cardinal): TDateTime;
begin
  { The seconds are checked first: a timestamp built by hand can carry any
    Int64, and multiplying one near its end by a thousand wraps. }
  if not MessagePackSecondsFitDateTime(ASeconds) or
     not TStructuralText.TryUnixMillisToDateTime(ASeconds * Int64(1000) +
       Int64(ANanoseconds) div NANOSECONDS_PER_MILLISECOND, Result) then
    raise EMessagePackInputError.CreateFmt(
      'The timestamp %d s is outside the years a TDateTime holds.',
      [ASeconds]);
end;

function MessagePackSecondsFitDateTime(ASeconds: Int64): Boolean;
begin
  Result := (ASeconds >= MIN_DATETIME_SECONDS) and
            (ASeconds <= MAX_DATETIME_SECONDS);
end;

{ Big-endian, because MessagePack is. These four exist so that no part of the
  codec has to remember which way round the bytes go. }

procedure PutBE32(var ABytes: TBytes; AOffset: Integer; AValue: Cardinal);
begin
  ABytes[AOffset] := Byte(AValue shr 24);
  ABytes[AOffset + 1] := Byte(AValue shr 16);
  ABytes[AOffset + 2] := Byte(AValue shr 8);
  ABytes[AOffset + 3] := Byte(AValue);
end;

procedure PutBE64(var ABytes: TBytes; AOffset: Integer; AValue: UInt64);
begin
  PutBE32(ABytes, AOffset, Cardinal(AValue shr 32));
  PutBE32(ABytes, AOffset + 4, Cardinal(AValue and $FFFFFFFF));
end;

function GetBE32(const ABytes: TBytes; AOffset: Integer): Cardinal;
begin
  Result := (Cardinal(ABytes[AOffset]) shl 24) or
            (Cardinal(ABytes[AOffset + 1]) shl 16) or
            (Cardinal(ABytes[AOffset + 2]) shl 8) or
            Cardinal(ABytes[AOffset + 3]);
end;

function GetBE64(const ABytes: TBytes; AOffset: Integer): UInt64;
begin
  Result := (UInt64(GetBE32(ABytes, AOffset)) shl 32) or
            UInt64(GetBE32(ABytes, AOffset + 4));
end;

{ ===========================================================================
  1. THE READER

  Every read is bounds-checked against the buffer before it happens, so a
  declared length larger than the data left fails on the bound rather than on
  an allocation. A container's element count is checked the same way: an array
  claiming four billion elements cannot be satisfied by ten bytes, and saying
  so immediately is the difference between an error message and an
  out-of-memory.

  0xC1 is refused by name. It is not an unknown type byte - the specification
  states that it is never used - so a document containing one is not a
  MessagePack document at all.
  =========================================================================== }

type
  TMessagePackReader = record
  public
    FData: TBytes;
    FPos: Integer;
    FLen: Integer;
    FDepth: Integer;
    procedure Fail(const AMessage: string);
    procedure Need(ACount: Int64);
    procedure NeedElements(ACount, ABytesPerElement: Int64);
    function ReadByte: Byte;
    function ReadBE16: Word;
    function ReadBE32: Cardinal;
    function ReadBE64: UInt64;
    function ReadBytes(ACount: Int64): TBytes;
    function ReadText(ACount: Int64; AStart: Integer): string;
    function ReadValue: TMessagePackValue;
    function ReadArray(ACount: Int64): TMessagePackValue;
    function ReadMap(ACount: Int64): TMessagePackValue;
    function MakeExtension(AType: Shortint; const AData: TBytes;
      AStart: Integer): TMessagePackValue;
    class function Parse(const AData: TBytes): TMessagePackValue; static;
  end;

procedure TMessagePackReader.Fail(const AMessage: string);
begin
  raise EMessagePackInputError.CreateFmt('%s (at byte %d of %d)',
    [AMessage, FPos, FLen]);
end;

procedure TMessagePackReader.Need(ACount: Int64);
begin
  if (ACount < 0) or (Int64(FPos) + ACount > FLen) then
    Fail(Format('A value that declares %d bytes with only %d left',
      [ACount, FLen - FPos]));
end;

procedure TMessagePackReader.NeedElements(ACount, ABytesPerElement: Int64);
begin
  { The shortest possible element is one byte, and the shortest map entry is
    two, so a count larger than the remaining bytes divided by that is
    impossible however the elements are encoded. }
  if (ACount < 0) or
     (ACount > (Int64(FLen) - FPos) div ABytesPerElement) then
    Fail(Format('A container of %d elements, which the %d bytes remaining ' +
      'cannot hold', [ACount, FLen - FPos]));
end;

function TMessagePackReader.ReadByte: Byte;
begin
  Need(1);
  Result := FData[FPos];
  Inc(FPos);
end;

function TMessagePackReader.ReadBE16: Word;
begin
  Need(2);
  Result := Word((Word(FData[FPos]) shl 8) or Word(FData[FPos + 1]));
  Inc(FPos, 2);
end;

function TMessagePackReader.ReadBE32: Cardinal;
begin
  Need(4);
  Result := GetBE32(FData, FPos);
  Inc(FPos, 4);
end;

function TMessagePackReader.ReadBE64: UInt64;
begin
  Need(8);
  Result := GetBE64(FData, FPos);
  Inc(FPos, 8);
end;

function TMessagePackReader.ReadBytes(ACount: Int64): TBytes;
begin
  Need(ACount);
  SetLength(Result, Integer(ACount));
  if ACount > 0 then Move(FData[FPos], Result[0], Integer(ACount));
  Inc(FPos, Integer(ACount));
end;

function TMessagePackReader.ReadText(ACount: Int64; AStart: Integer): string;
var
  Raw: TBytes;
begin
  Raw := ReadBytes(ACount);
  if not IsValidUtf8(Raw) then
    raise EMessagePackInvalidUtf8.CreateAt(AStart,
      'the bytes are not a well-formed UTF-8 sequence');
  { IsValidUtf8 has already refused overlong forms, lone surrogates,
    truncated sequences and anything above U+10FFFF, so the decode below
    cannot silently substitute anything. Utf8BytesToString would also refuse
    them, but it additionally skips a LEADING byte order mark - and a
    U+FEFF at the start of a MessagePack str is a character the document
    chose to put there, not a mark about the document's encoding. }
  Result := TEncoding.UTF8.GetString(Raw);
end;

function TMessagePackReader.MakeExtension(AType: Shortint;
  const AData: TBytes; AStart: Integer): TMessagePackValue;
var
  Seconds: Int64;
  Nanoseconds: Cardinal;
  Combined: UInt64;
begin
  if AType <> MessagePackTimestampExtensionType then
    Exit(TMessagePackValue.NewExtension(AType, AData));

  case Integer(Length(AData)) of
    { timestamp 32: a four-byte unsigned count of seconds, no fraction. }
    4:
      begin
        Seconds := Int64(GetBE32(AData, 0));
        Nanoseconds := 0;
      end;
    { timestamp 64: thirty bits of nanoseconds above thirty-four bits of
      seconds, in one eight-byte unsigned value. }
    8:
      begin
        Combined := GetBE64(AData, 0);
        Nanoseconds := Cardinal(Combined shr 34);
        Seconds := Int64(Combined and UInt64($00000003FFFFFFFF));
      end;
    { timestamp 96: four bytes of nanoseconds then a signed eight-byte count
      of seconds, which is the only one of the three that reaches before the
      epoch. }
    12:
      begin
        Nanoseconds := GetBE32(AData, 0);
        Seconds := Int64(GetBE64(AData, 4));
      end;
  else
    raise EMessagePackInputError.CreateFmt(
      'A timestamp extension at offset %d is %d bytes. The specification ' +
      'defines exactly three encodings for type -1, of 4, 8 and 12 bytes; ' +
      'anything else is not one of them.', [AStart, Length(AData)]);
  end;

  if Nanoseconds >= NANOSECONDS_PER_SECOND then
    raise EMessagePackInputError.CreateFmt(
      'A timestamp extension at offset %d carries %s nanoseconds. The ' +
      'specification requires that field to be below one second; the rest ' +
      'belongs in the seconds field.', [AStart, UIntToStr(Nanoseconds)]);

  { An instant a TDateTime cannot hold stays an extension, with its bytes
    exactly as they arrived. Clamping it to the end of the range, or raising,
    would both be worse than carrying a value this library simply has no
    Delphi type for. }
  if not MessagePackSecondsFitDateTime(Seconds) then
    Exit(TMessagePackValue.NewExtension(AType, AData));

  Result := TMessagePackValue.NewTimestamp(Seconds, Nanoseconds);
end;

function TMessagePackReader.ReadArray(ACount: Int64): TMessagePackValue;
var
  I: Integer;
begin
  NeedElements(ACount, 1);
  Inc(FDepth);
  try
    if FDepth > MessagePackMaxDepth then
      raise EMessagePackDepthExceeded.CreateFor(MessagePackMaxDepth);
    Result := TMessagePackValue.NewArray;
    try
      for I := 0 to Integer(ACount) - 1 do Result.Add(ReadValue);
    except
      Result.Free;
      raise;
    end;
  finally
    Dec(FDepth);
  end;
end;

function TMessagePackReader.ReadMap(ACount: Int64): TMessagePackValue;
var
  I: Integer;
  Key, Value: TMessagePackValue;
begin
  NeedElements(ACount, 2);
  Inc(FDepth);
  try
    if FDepth > MessagePackMaxDepth then
      raise EMessagePackDepthExceeded.CreateFor(MessagePackMaxDepth);
    Result := TMessagePackValue.NewMap;
    try
      for I := 0 to Integer(ACount) - 1 do
      begin
        { A MessagePack map key is a value of any type, so it is read the
          same way anything else is. Nothing here assumes it is a str. }
        Key := ReadValue;
        try
          Value := ReadValue;
        except
          Key.Free;
          raise;
        end;
        Result.Add(Key, Value);
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    Dec(FDepth);
  end;
end;

function TMessagePackReader.ReadValue: TMessagePackValue;
var
  B: Byte;
  Start: Integer;
  ExtType: Shortint;
  Data: TBytes;
  Length32: Cardinal;
  Bits32: Cardinal;
  Bits64: UInt64;
  AsSingle: Single;
  AsDouble: Double;
begin
  Start := FPos;
  B := ReadByte;
  case B of
    $00..MSGPACK_POSITIVE_FIXINT_MAX:
      Exit(TMessagePackValue.NewInt(B));
    MSGPACK_NEGATIVE_FIXINT_MIN..$FF:
      Exit(TMessagePackValue.NewInt(Shortint(B)));
    MSGPACK_FIXMAP_MIN..MSGPACK_FIXMAP_MAX:
      Exit(ReadMap(B and $0F));
    MSGPACK_FIXARRAY_MIN..MSGPACK_FIXARRAY_MAX:
      Exit(ReadArray(B and $0F));
    MSGPACK_FIXSTR_MIN..MSGPACK_FIXSTR_MAX:
      Exit(TMessagePackValue.NewStr(ReadText(B and $1F, Start)));

    MSGPACK_NIL: Exit(TMessagePackValue.NewNil);
    MSGPACK_NEVER_USED: raise EMessagePackReservedByte.CreateAt(Start);
    MSGPACK_FALSE: Exit(TMessagePackValue.NewBool(False));
    MSGPACK_TRUE: Exit(TMessagePackValue.NewBool(True));

    MSGPACK_BIN8: Exit(TMessagePackValue.NewBin(ReadBytes(ReadByte)));
    MSGPACK_BIN16: Exit(TMessagePackValue.NewBin(ReadBytes(ReadBE16)));
    MSGPACK_BIN32: Exit(TMessagePackValue.NewBin(ReadBytes(ReadBE32)));

    MSGPACK_STR8: Exit(TMessagePackValue.NewStr(ReadText(ReadByte, Start)));
    MSGPACK_STR16: Exit(TMessagePackValue.NewStr(ReadText(ReadBE16, Start)));
    MSGPACK_STR32: Exit(TMessagePackValue.NewStr(ReadText(ReadBE32, Start)));

    MSGPACK_FLOAT32:
      begin
        Bits32 := ReadBE32;
        Move(Bits32, AsSingle, 4);
        Exit(TMessagePackValue.NewFloat32(AsSingle));
      end;
    MSGPACK_FLOAT64:
      begin
        Bits64 := ReadBE64;
        Move(Bits64, AsDouble, 8);
        Exit(TMessagePackValue.NewFloat64(AsDouble));
      end;

    MSGPACK_UINT8: Exit(TMessagePackValue.NewUInt(ReadByte));
    MSGPACK_UINT16: Exit(TMessagePackValue.NewUInt(ReadBE16));
    MSGPACK_UINT32: Exit(TMessagePackValue.NewUInt(ReadBE32));
    MSGPACK_UINT64: Exit(TMessagePackValue.NewUInt(ReadBE64));

    MSGPACK_INT8: Exit(TMessagePackValue.NewInt(Shortint(ReadByte)));
    MSGPACK_INT16: Exit(TMessagePackValue.NewInt(Smallint(ReadBE16)));
    MSGPACK_INT32: Exit(TMessagePackValue.NewInt(Integer(ReadBE32)));
    MSGPACK_INT64: Exit(TMessagePackValue.NewInt(Int64(ReadBE64)));

    { The fixed-width extensions carry the type byte first and then exactly
      as many payload bytes as the family name says. }
    MSGPACK_FIXEXT1, MSGPACK_FIXEXT2, MSGPACK_FIXEXT4, MSGPACK_FIXEXT8,
    MSGPACK_FIXEXT16:
      begin
        ExtType := Shortint(ReadByte);
        case B of
          MSGPACK_FIXEXT1: Data := ReadBytes(1);
          MSGPACK_FIXEXT2: Data := ReadBytes(2);
          MSGPACK_FIXEXT4: Data := ReadBytes(4);
          MSGPACK_FIXEXT8: Data := ReadBytes(8);
        else
          Data := ReadBytes(16);
        end;
        Exit(MakeExtension(ExtType, Data, Start));
      end;

    { The variable-width ones put the LENGTH before the type byte, which is
      the one place the two orders differ. }
    MSGPACK_EXT8, MSGPACK_EXT16, MSGPACK_EXT32:
      begin
        case B of
          MSGPACK_EXT8: Length32 := ReadByte;
          MSGPACK_EXT16: Length32 := ReadBE16;
        else
          Length32 := ReadBE32;
        end;
        ExtType := Shortint(ReadByte);
        Data := ReadBytes(Length32);
        Exit(MakeExtension(ExtType, Data, Start));
      end;

    MSGPACK_ARRAY16: Exit(ReadArray(ReadBE16));
    MSGPACK_ARRAY32: Exit(ReadArray(ReadBE32));
    MSGPACK_MAP16: Exit(ReadMap(ReadBE16));
    MSGPACK_MAP32: Exit(ReadMap(ReadBE32));
  end;
  { Every byte from $00 to $FF is covered by the ranges above, so reaching
    here would mean the case statement and the format table had drifted
    apart. }
  raise EMessagePackInternalError.CreateFmt(
    'Internal: the format byte 0x%.2x at offset %d fell through every ' +
    'family.', [B, Start]);
end;

class function TMessagePackReader.Parse(const AData: TBytes): TMessagePackValue;
var
  R: TMessagePackReader;
begin
  if Length(AData) = 0 then
    raise EMessagePackInputError.Create(
      'An empty buffer is not a MessagePack value. Every value begins with a ' +
      'format byte, and the shortest of them - a fixint, nil, false - is one ' +
      'byte long.');
  if Int64(Length(AData)) > MaxInt then
    raise EMessagePackInputError.CreateFmt(
      'A buffer of %d bytes is larger than the 2 GiB this reader accepts.',
      [Int64(Length(AData))]);
  R.FData := AData;
  R.FLen := Integer(Length(AData));
  R.FPos := 0;
  R.FDepth := 0;
  Result := R.ReadValue;
  try
    { One buffer is one value. A caller holding a stream of concatenated
      values wants a reader that reports where it stopped, and silently
      ignoring the rest here would hide a truncation bug rather than a
      streaming one. }
    if R.FPos <> R.FLen then R.Fail('Bytes after the end of the value');
  except
    Result.Free;
    raise;
  end;
end;

{ ===========================================================================
  2. THE WRITER

  Every family is written in its SHORTEST form. That is not an optimization:
  it is what every other implementation does, so it is what an
  interoperability comparison is against, and a codec that wrote uint64 for
  the number 1 would agree with nobody.
  =========================================================================== }

type
  TMessagePackWriter = record
  public
    FData: TBytes;
    FPos: Integer;
    procedure Ensure(ACount: Integer);
    procedure PutByte(AValue: Byte);
    procedure PutBE16(AValue: Word);
    procedure PutBE32(AValue: Cardinal);
    procedure PutBE64(AValue: UInt64);
    procedure PutRaw(const AValue: TBytes);
    procedure PutInt(AValue: Int64);
    procedure PutUInt(AValue: UInt64);
    procedure PutStr(const AValue: string);
    procedure PutBin(const AValue: TBytes);
    procedure PutExtension(AType: Shortint; const AData: TBytes);
    procedure PutTimestamp(ASeconds: Int64; ANanoseconds: Cardinal);
    procedure PutValue(AValue: TMessagePackValue);
    function Done: TBytes;
  end;

procedure TMessagePackWriter.Ensure(ACount: Integer);
begin
  { Against what is left below MaxInt: FPos + ACount wrapped negative. }
  if ACount > MaxInt - FPos then
    raise EMessagePackInternalError.CreateFmt(
      'A document of %d bytes is too large to write; the limit here is ' +
      '2 GiB.', [Int64(FPos) + ACount]);
  if FPos + ACount > Length(FData) then
    SetLength(FData, Max(FPos + ACount, Length(FData) * 2 + 64));
end;

procedure TMessagePackWriter.PutByte(AValue: Byte);
begin
  Ensure(1);
  FData[FPos] := AValue;
  Inc(FPos);
end;

procedure TMessagePackWriter.PutBE16(AValue: Word);
begin
  Ensure(2);
  FData[FPos] := Byte(AValue shr 8);
  FData[FPos + 1] := Byte(AValue);
  Inc(FPos, 2);
end;

procedure TMessagePackWriter.PutBE32(AValue: Cardinal);
begin
  Ensure(4);
  PascalForge.MessagePack.Internal.PutBE32(FData, FPos, AValue);
  Inc(FPos, 4);
end;

procedure TMessagePackWriter.PutBE64(AValue: UInt64);
begin
  Ensure(8);
  PascalForge.MessagePack.Internal.PutBE64(FData, FPos, AValue);
  Inc(FPos, 8);
end;

procedure TMessagePackWriter.PutRaw(const AValue: TBytes);
begin
  Ensure(MessagePackWriterCount(Length(AValue)));
  if Length(AValue) > 0 then Move(AValue[0], FData[FPos], Length(AValue));
  Inc(FPos, Length(AValue));
end;

procedure TMessagePackWriter.PutUInt(AValue: UInt64);
begin
  if AValue <= MSGPACK_POSITIVE_FIXINT_MAX then PutByte(Byte(AValue))
  else if AValue <= $FF then
  begin
    PutByte(MSGPACK_UINT8);
    PutByte(Byte(AValue));
  end
  else if AValue <= $FFFF then
  begin
    PutByte(MSGPACK_UINT16);
    PutBE16(Word(AValue));
  end
  else if AValue <= $FFFFFFFF then
  begin
    PutByte(MSGPACK_UINT32);
    PutBE32(Cardinal(AValue));
  end
  else
  begin
    PutByte(MSGPACK_UINT64);
    PutBE64(AValue);
  end;
end;

procedure TMessagePackWriter.PutInt(AValue: Int64);
begin
  { A non-negative value goes through the unsigned families, which are the
    shorter ones: 200 is two bytes as uint8 and three as int16. }
  if AValue >= 0 then
  begin
    PutUInt(UInt64(AValue));
    Exit;
  end;
  if AValue >= -32 then PutByte(Byte(Shortint(AValue)))
  else if AValue >= Low(Shortint) then
  begin
    PutByte(MSGPACK_INT8);
    PutByte(Byte(Shortint(AValue)));
  end
  else if AValue >= Low(Smallint) then
  begin
    PutByte(MSGPACK_INT16);
    PutBE16(Word(Smallint(AValue)));
  end
  else if AValue >= Low(Integer) then
  begin
    PutByte(MSGPACK_INT32);
    PutBE32(Cardinal(Integer(AValue)));
  end
  else
  begin
    PutByte(MSGPACK_INT64);
    PutBE64(UInt64(AValue));
  end;
end;

procedure TMessagePackWriter.PutStr(const AValue: string);
var
  Utf8: TBytes;
  Size: Integer;
begin
  Utf8 := StringToUtf8Bytes(AValue);
  Size := MessagePackWriterCount(Length(Utf8));
  if Size <= 31 then PutByte(Byte(MSGPACK_FIXSTR_MIN or Size))
  else if Size <= $FF then
  begin
    PutByte(MSGPACK_STR8);
    PutByte(Byte(Size));
  end
  else if Size <= $FFFF then
  begin
    PutByte(MSGPACK_STR16);
    PutBE16(Word(Size));
  end
  else
  begin
    PutByte(MSGPACK_STR32);
    PutBE32(Cardinal(Size));
  end;
  PutRaw(Utf8);
end;

procedure TMessagePackWriter.PutBin(const AValue: TBytes);
var
  Size: Integer;
begin
  { There is no fixbin: the bin family was added in 2013 and starts at
    bin8. }
  Size := MessagePackWriterCount(Length(AValue));
  if Size <= $FF then
  begin
    PutByte(MSGPACK_BIN8);
    PutByte(Byte(Size));
  end
  else if Size <= $FFFF then
  begin
    PutByte(MSGPACK_BIN16);
    PutBE16(Word(Size));
  end
  else
  begin
    PutByte(MSGPACK_BIN32);
    PutBE32(Cardinal(Size));
  end;
  PutRaw(AValue);
end;

procedure TMessagePackWriter.PutExtension(AType: Shortint;
  const AData: TBytes);
var
  Size: Integer;
begin
  Size := MessagePackWriterCount(Length(AData));
  case Size of
    1: PutByte(MSGPACK_FIXEXT1);
    2: PutByte(MSGPACK_FIXEXT2);
    4: PutByte(MSGPACK_FIXEXT4);
    8: PutByte(MSGPACK_FIXEXT8);
    16: PutByte(MSGPACK_FIXEXT16);
  else
    if Size <= $FF then
    begin
      PutByte(MSGPACK_EXT8);
      PutByte(Byte(Size));
    end
    else if Size <= $FFFF then
    begin
      PutByte(MSGPACK_EXT16);
      PutBE16(Word(Size));
    end
    else
    begin
      PutByte(MSGPACK_EXT32);
      PutBE32(Cardinal(Size));
    end;
  end;
  PutByte(Byte(AType));
  PutRaw(AData);
end;

procedure TMessagePackWriter.PutTimestamp(ASeconds: Int64;
  ANanoseconds: Cardinal);
var
  Data: TBytes;
  Combined: UInt64;
begin
  { The smallest of the three encodings that is EXACT for this instant. A
    whole second inside the unsigned 32-bit range needs four bytes; anything
    with a fraction, up to the year 2514, fits the packed 64-bit form; and
    only an instant before the epoch or beyond that needs the 96-bit one. }
  if (ANanoseconds = 0) and (ASeconds >= 0) and (ASeconds <= $FFFFFFFF) then
  begin
    SetLength(Data, 4);
    PascalForge.MessagePack.Internal.PutBE32(Data, 0, Cardinal(ASeconds));
  end
  else if (ASeconds >= 0) and (ASeconds < (Int64(1) shl 34)) then
  begin
    SetLength(Data, 8);
    Combined := (UInt64(ANanoseconds) shl 34) or UInt64(ASeconds);
    PascalForge.MessagePack.Internal.PutBE64(Data, 0, Combined);
  end
  else
  begin
    SetLength(Data, 12);
    PascalForge.MessagePack.Internal.PutBE32(Data, 0, ANanoseconds);
    PascalForge.MessagePack.Internal.PutBE64(Data, 4, UInt64(ASeconds));
  end;
  PutExtension(MessagePackTimestampExtensionType, Data);
end;

procedure TMessagePackWriter.PutValue(AValue: TMessagePackValue);
var
  I, Size: Integer;
begin
  case AValue.Kind of
    TMessagePackKind.Null: PutByte(MSGPACK_NIL);
    TMessagePackKind.Bool:
      if AValue.AsBool then PutByte(MSGPACK_TRUE) else PutByte(MSGPACK_FALSE);
    TMessagePackKind.Int: PutInt(AValue.AsInt);
    TMessagePackKind.UInt: PutUInt(AValue.AsUInt);
    TMessagePackKind.Float32:
      begin
        PutByte(MSGPACK_FLOAT32);
        var AsSingle: Single := AValue.AsFloat;
        var Bits32: Cardinal;
        Move(AsSingle, Bits32, 4);
        PutBE32(Bits32);
      end;
    TMessagePackKind.Float64:
      begin
        PutByte(MSGPACK_FLOAT64);
        var AsDouble: Double := AValue.AsFloat;
        var Bits64: UInt64;
        Move(AsDouble, Bits64, 8);
        PutBE64(Bits64);
      end;
    TMessagePackKind.Str: PutStr(AValue.AsStr);
    TMessagePackKind.Bin: PutBin(AValue.AsBytes);
    TMessagePackKind.Extension:
      PutExtension(AValue.ExtensionType, AValue.AsBytes);
    TMessagePackKind.Timestamp:
      PutTimestamp(AValue.Seconds, AValue.Nanoseconds);
    TMessagePackKind.Arr:
      begin
        Size := AValue.Count;
        if Size <= 15 then PutByte(Byte(MSGPACK_FIXARRAY_MIN or Size))
        else if Size <= $FFFF then
        begin
          PutByte(MSGPACK_ARRAY16);
          PutBE16(Word(Size));
        end
        else
        begin
          PutByte(MSGPACK_ARRAY32);
          PutBE32(Cardinal(Size));
        end;
        for I := 0 to Size - 1 do PutValue(AValue[I]);
      end;
    TMessagePackKind.Map:
      begin
        Size := AValue.Count;
        if Size <= 15 then PutByte(Byte(MSGPACK_FIXMAP_MIN or Size))
        else if Size <= $FFFF then
        begin
          PutByte(MSGPACK_MAP16);
          PutBE16(Word(Size));
        end
        else
        begin
          PutByte(MSGPACK_MAP32);
          PutBE32(Cardinal(Size));
        end;
        for I := 0 to Size - 1 do
        begin
          PutValue(AValue.Keys[I]);
          PutValue(AValue[I]);
        end;
      end;
  else
    raise EMessagePackInternalError.CreateFmt('Cannot write %s.',
      [AValue.Describe]);
  end;
end;

function TMessagePackWriter.Done: TBytes;
begin
  SetLength(FData, FPos);
  Result := FData;
end;

{ ===========================================================================
  3. PLANS
  =========================================================================== }

destructor TMessagePackMemberPlan.Destroy;
begin
  Inner.Free;
  Item.Free;
  Key.Free;
  Value.Free;
  inherited Destroy;
end;

function TMessagePackMemberPlan.IsContainer: Boolean;
begin
  Result := Kind in [TMessagePackMemberKind.ListValue,
    TMessagePackMemberKind.ArrayValue,
    TMessagePackMemberKind.DictionaryValue];
end;

destructor TMessagePackFieldPlan.Destroy;
begin
  Member.Free;
  inherited Destroy;
end;

constructor TMessagePackTypePlan.Create;
begin
  inherited Create;
  Fields := TObjectList<TMessagePackFieldPlan>.Create(True);
end;

destructor TMessagePackTypePlan.Destroy;
begin
  Fields.Free;
  inherited Destroy;
end;

{ Delphi's unsigned integer types share tkInteger and tkInt64 with the signed
  ones, so the distinction has to come out of the type data: an ordinal type's
  OrdType names the width AND the signedness, and UInt64 is the Int64-kind
  type whose declared range runs from zero to all ones. }
function IsUnsignedOrdinal(ATypeInfo: PTypeInfo): Boolean;
begin
  case ATypeInfo.Kind of
    tkInteger: Result := GetTypeData(ATypeInfo).OrdType in [otUByte, otUWord,
      otULong];
    tkInt64: Result := (GetTypeData(ATypeInfo).MinInt64Value = 0) and
                       (GetTypeData(ATypeInfo).MaxInt64Value = -1);
  else
    Result := False;
  end;
end;

{ The raw ordinal bits of a TValue, read with the signedness the declared type
  actually has. TValue.AsOrdinal answers for the common cases; these two are
  explicit because the whole point of this codec is that a Cardinal holding
  4294967295 must not arrive as -1. }
function RawSigned(const AValue: TValue): Int64;
var
  P: Pointer;
begin
  P := AValue.GetReferenceToRawData;
  case AValue.DataSize of
    1: Result := PShortInt(P)^;
    2: Result := PSmallInt(P)^;
    4: Result := PInteger(P)^;
  else
    Result := PInt64(P)^;
  end;
end;

function RawUnsigned(const AValue: TValue): UInt64;
var
  P: Pointer;
begin
  P := AValue.GetReferenceToRawData;
  case AValue.DataSize of
    1: Result := PByte(P)^;
    2: Result := PWord(P)^;
    4: Result := PCardinal(P)^;
  else
    Result := PUInt64(P)^;
  end;
end;

{ ===========================================================================
  THE ENGINE
  =========================================================================== }

class constructor TMessagePackEngine.Create;
begin
  FCtx := TRttiContext.Create;
  FLock := TCriticalSection.Create;
  FPlans := TDictionary<PTypeInfo, TMessagePackTypePlan>.Create;
  FRootPlans :=
    TObjectDictionary<PTypeInfo, TMessagePackMemberPlan>.Create([doOwnsValues]);
  FEnumMappings := TDictionary<PTypeInfo, TArray<string>>.Create;
  FTypeSerializers :=
    TDictionary<PTypeInfo, TMessagePackValueSerializerClass>.Create;
  FSerializerSingletons :=
    TObjectDictionary<TClass, TCustomMessagePackValueSerializer>.Create(
      [doOwnsValues]);
  FBuildTrail := TList<PTypeInfo>.Create;
  { TDate and TTime are not instants. Writing them as a timestamp would claim
    a point in time that a date without a time of day, or a time of day
    without a date, does not have - so they default to ISO 8601 strings and
    only TDateTime gets the extension. }
  FDatePolicies := TDateTimePolicies.Create(
    TDateTimePolicy.Make(Ord(TMessagePackDateTimeRepresentation.StringIso8601)));
  FTimePolicies := TDateTimePolicies.Create(
    TDateTimePolicy.Make(Ord(TMessagePackDateTimeRepresentation.StringIso8601)));
  FTimestampPolicies := TDateTimePolicies.Create(
    TDateTimePolicy.Make(Ord(TMessagePackDateTimeRepresentation.Timestamp)));
end;

class destructor TMessagePackEngine.Destroy;
var
  P: TMessagePackTypePlan;
begin
  for P in FPlans.Values do P.Free;
  FPlans.Free;
  FRootPlans.Free;
  FTimestampPolicies.Free;
  FTimePolicies.Free;
  FDatePolicies.Free;
  FBuildTrail.Free;
  FSerializerSingletons.Free;
  FTypeSerializers.Free;
  FEnumMappings.Free;
  FLock.Free;
  FCtx.Free;
end;

class procedure TMessagePackEngine.CheckNotFrozen;
begin
  if FFrozen then
    raise EMessagePackInternalError.Create(
      'MessagePack configuration is frozen. A registration has to happen ' +
      'before the type it affects is first used, because a plan is cached at ' +
      'that moment; afterwards it would be a silent no-op.');
end;

class procedure TMessagePackEngine.RollbackBuildTrail;
var
  TI: PTypeInfo;
  P: TMessagePackTypePlan;
begin
  for TI in FBuildTrail do
    if FPlans.TryGetValue(TI, P) then
    begin
      FPlans.Remove(TI);
      P.Free;
    end;
  FBuildTrail.Clear;
end;

class function TMessagePackEngine.PoliciesFor(
  AKind: TMessagePackMemberKind): TDateTimePolicies;
begin
  case AKind of
    TMessagePackMemberKind.DateValue: Result := FDatePolicies;
    TMessagePackMemberKind.TimeValue: Result := FTimePolicies;
  else
    Result := FTimestampPolicies;
  end;
end;

class function TMessagePackEngine.ResolveSerializer(
  AClass: TMessagePackValueSerializerClass): TCustomMessagePackValueSerializer;
begin
  if AClass = nil then Exit(nil);
  if not FSerializerSingletons.TryGetValue(AClass, Result) then
  begin
    Result := AClass.Create;
    FSerializerSingletons.Add(AClass, Result);
  end;
end;

class function TMessagePackEngine.EnumMappingFor(
  ATypeInfo: PTypeInfo): TArray<string>;
begin
  { This format's own registration first; then [SerializationEnum] on the
    type. }
  if (ATypeInfo = nil) or not FEnumMappings.TryGetValue(ATypeInfo, Result) then
    Result := TSerializationMetadata.EnumValuesOf(ATypeInfo);
end;

{ A member's [SerializationEnum]: on the enumeration, or a nullable's
  inner one, unless this format registered a mapping for that type. }
class procedure TMessagePackEngine.ApplyGeneralEnum(APlan: TMessagePackMemberPlan;
  const AValues: TArray<string>);
begin
  if (APlan.Kind = TMessagePackMemberKind.NullableValue) and (APlan.Inner <> nil) then
    APlan := APlan.Inner;
  if (APlan.Kind = TMessagePackMemberKind.EnumValue) and (APlan.TypeInfo <> nil) and
     not FEnumMappings.ContainsKey(APlan.TypeInfo) then
    APlan.EnumMapping := AValues;
end;

class function TMessagePackEngine.ClassifyType(
  ATypeInfo: PTypeInfo): TMessagePackMemberKind;
var
  Access: TNullableAccess;
begin
  if ATypeInfo = nil then Exit(TMessagePackMemberKind.Unsupported);
  if FTypeSerializers.ContainsKey(ATypeInfo) then
    Exit(TMessagePackMemberKind.CustomSerializer);
  if ATypeInfo = System.TypeInfo(TGUID) then
    Exit(TMessagePackMemberKind.GuidValue);
  if ATypeInfo = System.TypeInfo(TDate) then
    Exit(TMessagePackMemberKind.DateValue);
  if ATypeInfo = System.TypeInfo(TTime) then
    Exit(TMessagePackMemberKind.TimeValue);
  if ATypeInfo = System.TypeInfo(TDateTime) then
    Exit(TMessagePackMemberKind.DateTimeValue);
  { TBytes is bin. This test comes before the dynamic-array test below,
    because an array of Byte written element by element would be an array of
    numbers and not a byte string. }
  if ATypeInfo = System.TypeInfo(TBytes) then
    Exit(TMessagePackMemberKind.BytesValue);
  if TSerializationTypes.TryGetNullableAccess(ATypeInfo, Access) then
    Exit(TMessagePackMemberKind.NullableValue);

  case ATypeInfo.Kind of
    tkInteger:
      if IsUnsignedOrdinal(ATypeInfo) then Result := TMessagePackMemberKind.UIntValue
      else Result := TMessagePackMemberKind.IntValue;
    tkInt64:
      if IsUnsignedOrdinal(ATypeInfo) then Result := TMessagePackMemberKind.UInt64Value
      else Result := TMessagePackMemberKind.Int64Value;
    tkFloat:
      case GetTypeData(ATypeInfo).FloatType of
        ftCurr: Result := TMessagePackMemberKind.CurrencyValue;
        ftSingle: Result := TMessagePackMemberKind.SingleValue;
        { Comp is a 64-bit integer RTTI files under tkFloat. }
        ftComp: Result := TMessagePackMemberKind.Int64Value;
      else
        Result := TMessagePackMemberKind.FloatValue;
      end;
    tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
      Result := TMessagePackMemberKind.StrValue;
    tkEnumeration:
      if (ATypeInfo = System.TypeInfo(Boolean)) or
         (ATypeInfo = System.TypeInfo(ByteBool)) or
         (ATypeInfo = System.TypeInfo(WordBool)) or
         (ATypeInfo = System.TypeInfo(LongBool)) then
        Result := TMessagePackMemberKind.BoolValue
      else
        Result := TMessagePackMemberKind.EnumValue;
    tkSet: Result := TMessagePackMemberKind.SetValue;
    tkRecord, tkMRecord: Result := TMessagePackMemberKind.RecordValue;
    tkDynArray, tkArray: Result := TMessagePackMemberKind.ArrayValue;
    tkVariant: Result := TMessagePackMemberKind.VariantValue;
    tkClass:
      { THE ONE QUESTION, ASKED IN ONE PLACE. TSerializationTypes matches by
        ancestry, so TOrders = class(TObjectList<TOrder>) is a list and a
        class that merely has an Add and a ToArray is not. Six engines used
        to answer this for themselves and three of them got it wrong. }
      case TSerializationTypes.ContainerKindOf(ATypeInfo) of
        TContainerKind.Dictionary: Result := TMessagePackMemberKind.DictionaryValue;
        TContainerKind.List:       Result := TMessagePackMemberKind.ListValue;
      else
        Result := TMessagePackMemberKind.ObjectValue;
      end;
  else
    Result := TMessagePackMemberKind.Unsupported;
  end;
end;

{ --------------------------------------------------------------- plans --- }

class function TMessagePackEngine.BuildMemberPlan(ATypeInfo: PTypeInfo;
  const AOwnerKey, AMemberName: string): TMessagePackMemberPlan;
var
  Why: string;
  ListAccess: TListAccess;
  StaticCount, StaticSize: Integer;
  SerCls: TMessagePackValueSerializerClass;
  T, PairType: TRttiType;
  M: TRttiMethod;
  Params: TArray<TRttiParameter>;
  Policy: TDateTimePolicy;
  Access: TNullableAccess;
  ElemType: PTypeInfo;
begin
  Result := TMessagePackMemberPlan.Create;
  try
    Result.TypeInfo := ATypeInfo;
    Result.Kind := ClassifyType(ATypeInfo);
    Result.GuidRepresentation := TMessagePackGuidRepresentation.LowercaseString;
    Result.CurrencyRepresentation :=
      TMessagePackCurrencyRepresentation.ScaledInt64;
    Result.EnumRepresentation := TMessagePackEnumRepresentation.Name;

    if Result.Kind = TMessagePackMemberKind.CustomSerializer then
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
    Why := TSerializationTypes.UnsupportedReason(ATypeInfo);
    if Why <> '' then
      raise EMessagePackError.CreateFmt(
        '%s %s. Leave it out with [MessagePackIgnore], or register a MessagePack ' +
        'type serializer for its type.',
        [MemberDisplayName(AOwnerKey, AMemberName), Why]);

    case Result.Kind of
      TMessagePackMemberKind.DateValue, TMessagePackMemberKind.TimeValue,
      TMessagePackMemberKind.DateTimeValue:
        begin
          Policy := PoliciesFor(Result.Kind).Resolve(AOwnerKey, AMemberName);
          Result.DateRepresentation :=
            TMessagePackDateTimeRepresentation(Policy.Kind);
          Result.DatePattern := Policy.Pattern;
        end;

      TMessagePackMemberKind.EnumValue:
        Result.EnumMapping := EnumMappingFor(ATypeInfo);

      TMessagePackMemberKind.SetValue:
        begin
          Result.SetElemTypeInfo := ATypeInfo.TypeData.CompType^;
          Result.SetElemMapping := EnumMappingFor(Result.SetElemTypeInfo);
        end;

      TMessagePackMemberKind.NullableValue:
        begin
          if not TSerializationTypes.TryGetNullableAccess(ATypeInfo, Access) then
            raise EMessagePackInternalError.CreateFmt(
              'Internal: %s was classified as a nullable but its layout ' +
              'cannot be resolved.', [UTF8ToString(ATypeInfo.Name)]);
          Result.NullableAccess := Access;
          Result.Inner := BuildMemberPlan(Access.ValueType, AOwnerKey,
            AMemberName);
        end;

      TMessagePackMemberKind.ObjectValue, TMessagePackMemberKind.RecordValue:
        Result.BoundPlan := GetPlan(ATypeInfo, '');

      TMessagePackMemberKind.ArrayValue:
        begin
          ElemType := nil;
          if ATypeInfo.Kind = tkArray then
            TSerializationTypes.TryGetStaticArrayShape(ATypeInfo, ElemType,
              StaticCount, StaticSize)
          else if GetTypeData(ATypeInfo).DynArrElType <> nil then
            ElemType := GetTypeData(ATypeInfo).DynArrElType^;
          if ElemType = nil then
            raise EMessagePackInternalError.CreateFmt(
              'Cannot serialize %s: its element type has no RTTI.',
              [UTF8ToString(ATypeInfo.Name)]);
          Result.Item := BuildMemberPlan(ElemType, AOwnerKey, AMemberName);
        end;

      TMessagePackMemberKind.ListValue, TMessagePackMemberKind.DictionaryValue:
        begin
          T := FCtx.GetType(ATypeInfo);
          if T = nil then
            raise EMessagePackInternalError.CreateFmt(
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
            else if (Result.Kind = TMessagePackMemberKind.ListValue) and
                    SameText(M.Name, 'Add') and (Length(Params) = 1) then
              Result.ContainerAdd := M
            else if (Result.Kind = TMessagePackMemberKind.DictionaryValue) and
                    SameText(M.Name, 'AddOrSetValue') and (Length(Params) = 2) then
              Result.ContainerAdd := M;
          end;
          { A list's methods are the ones Core names for its family: a
            TQueue<T> enqueues, a TStack<T> pushes and a TStrings adds a
            line. Looking for a method called Add found nothing for the
            first two, and the members of the container were walked
            instead - its OnNotify event among them. }
          if (Result.Kind = TMessagePackMemberKind.ListValue) and
             TSerializationTypes.TryGetListAccess(ATypeInfo, ListAccess) then
          begin
            Result.ContainerAdd := ListAccess.AddMethod;
            Result.ContainerToArray := ListAccess.ToArrayMethod;
            if ListAccess.ClearMethod <> nil then
              Result.ContainerClear := ListAccess.ClearMethod;
            if ListAccess.CreateMethod <> nil then
              Result.ContainerCreate := ListAccess.CreateMethod;
          end;
          { The reader adds to a dictionary through Core, which has to
            recognise it too. }
          if (Result.Kind = TMessagePackMemberKind.DictionaryValue) and
             not TSerializationTypes.TryGetDictionaryAccess(ATypeInfo,
               Result.DictionaryAccess) then
            Result.ContainerAdd := nil;
          if (Result.ContainerAdd = nil) or (Result.ContainerToArray = nil) then
            raise EMessagePackInternalError.CreateFmt(
              'Cannot serialize %s: it looks like a collection but has no ' +
              'usable Add/ToArray pair.', [UTF8ToString(ATypeInfo.Name)]);
          Params := Result.ContainerAdd.GetParameters;
          if Result.Kind = TMessagePackMemberKind.ListValue then
            Result.Item := BuildMemberPlan(Params[0].ParamType.Handle,
              AOwnerKey, AMemberName)
          else
          begin
            Result.Key := BuildMemberPlan(Params[0].ParamType.Handle,
              AOwnerKey, AMemberName);
            Result.Value := BuildMemberPlan(Params[1].ParamType.Handle,
              AOwnerKey, AMemberName);
            { A MessagePack map key is a value of any type, so a dictionary
              key does NOT have to become a string the way it does in a
              format whose keys are names. It is still restricted to the
              scalars, because a map keyed by a whole object is legal
              MessagePack that nothing else in this library can express. }
            if not (Result.Key.Kind in [TMessagePackMemberKind.StrValue,
              TMessagePackMemberKind.IntValue, TMessagePackMemberKind.UIntValue,
              TMessagePackMemberKind.Int64Value,
              TMessagePackMemberKind.UInt64Value,
              TMessagePackMemberKind.BoolValue,
              TMessagePackMemberKind.EnumValue,
              TMessagePackMemberKind.GuidValue]) then
              raise EMessagePackInternalError.CreateFmt(
                'Cannot serialize %s: %s is not one of the scalar types this ' +
                'engine uses as a map key.', [UTF8ToString(ATypeInfo.Name),
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
              raise EMessagePackInternalError.CreateFmt(
                'Cannot serialize %s: its ToArray does not yield key/value ' +
                'pairs.', [UTF8ToString(ATypeInfo.Name)]);
          end;
        end;

      TMessagePackMemberKind.Unsupported:
        raise EMessagePackInternalError.CreateFmt(
          'MessagePack cannot represent %s (type kind %d). Register a custom ' +
          'MessagePack serializer for it, or mark the member ' +
          '[MessagePackIgnore].',
          [UTF8ToString(ATypeInfo.Name), Ord(ATypeInfo.Kind)]);
    end;
  except
    Result.Free;
    raise;
  end;
end;

class procedure TMessagePackEngine.BuildMemberOfType(
  APlan: TMessagePackTypePlan;
  AMember: TSerializationMember);
var
  AField: TRttiField;
  AProp: TRttiProperty;
  FP: TMessagePackFieldPlan;
  Attr: TCustomAttribute;
  Attrs: TArray<TCustomAttribute>;
  MemberType: PTypeInfo;
  MemberName: string;
  SerCls: TMessagePackValueSerializerClass;
  DateAttr: MessagePackDateTimeRepresentationAttribute;
  GuidAttr: MessagePackGuidRepresentationAttribute;
  CurrAttr: MessagePackCurrencyRepresentationAttribute;
  EnumAttr: MessagePackEnumRepresentationAttribute;
  Target: TMessagePackMemberPlan;
begin
  AField := AMember.Field;
  AProp := AMember.Prop;
  if AField <> nil then
  begin
    if AField.FieldType = nil then
    begin
      { Ignored deliberately, or refused - never skipped silently. }
      for Attr in AField.GetAttributes do
        if Attr is MessagePackIgnoreAttribute then Exit;
      raise EMessagePackError.CreateFmt(
        '%s %s. Leave it out with [MessagePackIgnore], or register a MessagePack ' +
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
    if Attr is MessagePackIgnoreAttribute then Exit;

  FP := TMessagePackFieldPlan.Create;
  try
    FP.Field := AField;
    FP.Prop := AProp;
    FP.DelphiName := MemberName;
    FP.Name := MemberName;
    { [SerializationName] names it; the format's own name attribute, read
      below, beats it. }
    if AMember.HasGeneralName then FP.Name := AMember.GeneralName;
    FP.Writable := (AField <> nil) or AProp.IsWritable;
    if AField <> nil then FP.DeclaringTypeName := AField.Parent.Name
    else FP.DeclaringTypeName := AProp.Parent.Name;

    SerCls := nil;
    DateAttr := nil;
    GuidAttr := nil;
    CurrAttr := nil;
    EnumAttr := nil;
    { Only MessagePack's own attributes are read. A member may carry six
      formats' worth at once and each format sees exactly its own. }
    for Attr in Attrs do
      if Attr is MessagePackNameAttribute then
        FP.Name := MessagePackNameAttribute(Attr).Name
      else if Attr is MessagePackSerializerAttribute then
        SerCls := MessagePackSerializerAttribute(Attr).SerializerClass
      else if Attr is MessagePackDateTimeRepresentationAttribute then
        DateAttr := MessagePackDateTimeRepresentationAttribute(Attr)
      else if Attr is MessagePackGuidRepresentationAttribute then
        GuidAttr := MessagePackGuidRepresentationAttribute(Attr)
      else if Attr is MessagePackCurrencyRepresentationAttribute then
        CurrAttr := MessagePackCurrencyRepresentationAttribute(Attr)
      else if Attr is MessagePackEnumRepresentationAttribute then
        EnumAttr := MessagePackEnumRepresentationAttribute(Attr);

    if FP.Name = '' then
      raise EMessagePackInternalError.CreateFmt(
        '%s.%s has an empty MessagePack name.',
        [APlan.RttiType.Name, MemberName]);

    if SerCls <> nil then
    begin
      FP.Member := TMessagePackMemberPlan.Create;
      FP.Member.TypeInfo := MemberType;
      FP.Member.Kind := TMessagePackMemberKind.CustomSerializer;
      FP.Member.Serializer := ResolveSerializer(SerCls);
    end
    else
      FP.Member := BuildMemberPlan(MemberType, APlan.TypeKey, MemberName);

    { [SerializationEnum] on the member, unless this format has its own
      mapping registered for the enumeration. }
    if AMember.HasEnumValues then
      ApplyGeneralEnum(FP.Member, AMember.EnumValues);

    { A member attribute beats every registration. On a nullable it applies
      to the inner value, which is the one that actually has a
      representation. }
    Target := FP.Member;
    if (Target.Kind = TMessagePackMemberKind.NullableValue) and
       (Target.Inner <> nil) then
      Target := Target.Inner;
    if DateAttr <> nil then
    begin
      Target.DateRepresentation := DateAttr.Representation;
      Target.DatePattern := DateAttr.Pattern;
    end;
    if GuidAttr <> nil then
      Target.GuidRepresentation := GuidAttr.Representation;
    if CurrAttr <> nil then
      Target.CurrencyRepresentation := CurrAttr.Representation;
    if EnumAttr <> nil then
      Target.EnumRepresentation := EnumAttr.Representation;

    APlan.Fields.Add(FP);
    FP := nil;
  finally
    FP.Free;
  end;
end;

class function TMessagePackEngine.BuildPlan(ATypeInfo: PTypeInfo;
  const AUnitHint: string): TMessagePackTypePlan;
var
  Registered: Boolean;
  T: TRttiType;
  Names: TDictionary<string, string>;
  Member: TSerializationMember;
  FP: TMessagePackFieldPlan;
  Existing: string;
begin
  Result := TMessagePackTypePlan.Create;
  Inc(FBuildDepth);
  try
    Result.TypeInfo := ATypeInfo;
    T := FCtx.GetType(ATypeInfo);
    if T = nil then
      raise EMessagePackInternalError.CreateFmt(
        'Cannot build a MessagePack plan for %s: the type exposes no usable ' +
        'RTTI. A type declared inside a routine body has none; declare it at ' +
        'unit scope, or register a custom MessagePack serializer for it.',
        [UTF8ToString(ATypeInfo.Name)]);
    Result.RttiType := T;
    Result.IsRecord := ATypeInfo.Kind in [tkRecord, tkMRecord];
    Result.UnitName := TypeUnitOf(ATypeInfo, AUnitHint);
    Result.TypeKey := TypeKeyOf(ATypeInfo, Result.UnitName);
    if not Result.IsRecord then
    begin
      Result.ClassType := ATypeInfo.TypeData.ClassType;
      Result.ZeroConstructor := TSerializationMetadata.Get(ATypeInfo).DeclaredConstructor;
      if Result.ZeroConstructor = nil then
        Result.ZeroConstructor := TSerializationMetadata.Get(ATypeInfo).TObjectConstructor;
    end;

    FPlans.Add(ATypeInfo, Result);
    FBuildTrail.Add(ATypeInfo);

    { The member surface and the general attributes come from the shared
      metadata. }
    for Member in TSerializationMetadata.Get(ATypeInfo).Members do
      if not Member.Ignored then BuildMemberOfType(Result, Member);

    Names := TDictionary<string, string>.Create;
    try
      for FP in Result.Fields do
        if Names.TryGetValue(LowerCase(FP.Name), Existing) then
          raise EMessagePackInternalError.CreateFmt(
            'Duplicate MessagePack name "%s" in %s: Delphi members %s and %s',
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

class function TMessagePackEngine.GetPlan(ATypeInfo: PTypeInfo;
  const AUnitHint: string): TMessagePackTypePlan;
begin
  if FPlans.TryGetValue(ATypeInfo, Result) then Exit;
  Result := BuildPlan(ATypeInfo, AUnitHint);
end;

class function TMessagePackEngine.GetRootPlan(
  ATypeInfo: PTypeInfo): TMessagePackMemberPlan;
begin
  if FRootPlans.TryGetValue(ATypeInfo, Result) then Exit;
  Result := BuildMemberPlan(ATypeInfo, TypeKeyOf(ATypeInfo), '');
  FRootPlans.Add(ATypeInfo, Result);
end;

{ ------------------------------------------------------------ instances --- }

class function TMessagePackEngine.NewInstanceOf(
  APlan: TMessagePackTypePlan): TObject;
begin
  if APlan.ZeroConstructor <> nil then
    Result := APlan.ZeroConstructor.Invoke(APlan.ClassType, []).AsObject
  else
    Result := APlan.ClassType.Create;
end;

class function TMessagePackEngine.NewContainer(
  APlan: TMessagePackMemberPlan): TObject;
begin
  if APlan.ContainerCreate = nil then
    raise EMessagePackInternalError.CreateFmt(
      'Cannot construct %s: it has no parameterless constructor. Create the ' +
      'container in its owner''s constructor; MessagePack will fill the one ' +
      'that is already there.', [UTF8ToString(APlan.TypeInfo.Name)]);
  Result := APlan.ContainerCreate.Invoke(
    GetTypeData(APlan.TypeInfo).ClassType, []).AsObject;
end;

class function TMessagePackEngine.ReadMember(AFP: TMessagePackFieldPlan;
  AInstance: Pointer): TValue;
begin
  if AFP.Field <> nil then Result := AFP.Field.GetValue(AInstance)
  else Result := AFP.Prop.GetValue(AInstance);
end;

class procedure TMessagePackEngine.StoreMember(AFP: TMessagePackFieldPlan;
  AInstance: Pointer; const AValue: TValue);
begin
  if AFP.Field <> nil then AFP.Field.SetValue(AInstance, AValue)
  else if AFP.Prop.IsWritable then AFP.Prop.SetValue(AInstance, AValue);
end;

{ --------------------------------------------------------- enums and sets --- }

class function TMessagePackEngine.EnumToText(ATypeInfo: PTypeInfo;
  AOrdinal: Integer; const AMapping: TArray<string>): string;
begin
  { A set of an integer subrange or of characters has no names: its
    members are their ordinals. See TSerializationTypes.SetElementText. }
  if ATypeInfo.Kind <> tkEnumeration then
    Exit(TSerializationTypes.SetElementText(ATypeInfo, AOrdinal));
  if AMapping <> nil then
  begin
    if (AOrdinal < 0) or (AOrdinal > High(AMapping)) then
      raise EMessagePackInternalError.CreateFmt(
        'Mapped enumeration %s ordinal %d is outside the registered mapping ' +
        '0..%d', [UTF8ToString(ATypeInfo.Name), AOrdinal, High(AMapping)]);
    Exit(AMapping[AOrdinal]);
  end;
  Result := GetEnumName(ATypeInfo, AOrdinal);
end;

class function TMessagePackEngine.TextToEnumOrdinal(ATypeInfo: PTypeInfo;
  const AText: string; const AMapping: TArray<string>): Integer;
var
  I: Integer;
  S: string;
begin
  if ATypeInfo.Kind <> tkEnumeration then
  begin
    if not TSerializationTypes.TrySetElementOrdinal(ATypeInfo, Trim(AText),
         Result) then
      raise EMessagePackInputError.CreateFmt('"%s" is not a member of %s.',
        [Trim(AText), UTF8ToString(ATypeInfo.Name)]);
    Exit;
  end;
  S := Trim(AText);
  if AMapping <> nil then
  begin
    for I := 0 to Integer(High(AMapping)) do
      if SameText(AMapping[I], S) then Exit(I);
    raise EMessagePackInputError.CreateFmt(
      '"%s" is not a registered value of %s.', [S, UTF8ToString(ATypeInfo.Name)]);
  end;
  Result := GetEnumValue(ATypeInfo, S);
  if Result < 0 then
    raise EMessagePackInputError.CreateFmt('"%s" is not a value of %s.',
      [S, UTF8ToString(ATypeInfo.Name)]);
end;

class function TMessagePackEngine.EnumToValue(APlan: TMessagePackMemberPlan;
  AOrdinal: Integer): TMessagePackValue;
begin
  if APlan.EnumRepresentation = TMessagePackEnumRepresentation.Ordinal then
    Exit(TMessagePackValue.NewInt(AOrdinal));
  Result := TMessagePackValue.NewStr(
    EnumToText(APlan.TypeInfo, AOrdinal, APlan.EnumMapping));
end;

class function TMessagePackEngine.ValueToEnumOrdinal(
  APlan: TMessagePackMemberPlan; AValue: TMessagePackValue): Integer;
var
  TD: PTypeData;
  Ordinal: Int64;
begin
  { Whichever representation is configured, both spellings are ACCEPTED on
    the way in: a document written by an older build of the same application
    still reads. }
  if AValue.Kind = TMessagePackKind.Str then
    Exit(TextToEnumOrdinal(APlan.TypeInfo, AValue.AsStr, APlan.EnumMapping));
  Ordinal := AValue.AsInt;
  TD := GetTypeData(APlan.TypeInfo);
  if (Ordinal < TD.MinValue) or (Ordinal > TD.MaxValue) then
    raise EMessagePackInputError.CreateFmt(
      'The ordinal %d is outside the range %d..%d of %s.',
      [Ordinal, TD.MinValue, TD.MaxValue, UTF8ToString(APlan.TypeInfo.Name)]);
  Result := Integer(Ordinal);
end;

class function TMessagePackEngine.SetToValue(APlan: TMessagePackMemberPlan;
  const AValue: TValue): TMessagePackValue;
var
  O: Integer;
  Element: TMessagePackMemberPlan;
begin
  { A set is written as an ARRAY of its members. A comma-joined string would
    also work and is what a format with no array type has to do; MessagePack
    has one, so the members stay separate values. }
  Element := TMessagePackMemberPlan.Create;
  try
    Element.TypeInfo := APlan.SetElemTypeInfo;
    Element.EnumMapping := APlan.SetElemMapping;
    Element.EnumRepresentation := APlan.EnumRepresentation;
    Result := TMessagePackValue.NewArray;
    try
      { Through TSerializationTypes, which knows that a set's bit 0 is the
        byte holding its lowest member: counting from ordinal 0 wrote 10 as
        12. }
      for O in TSerializationTypes.SetOrdinals(APlan.TypeInfo, AValue) do
        Result.Add(EnumToValue(Element, O));
    except
      Result.Free;
      raise;
    end;
  finally
    Element.Free;
  end;
end;

class function TMessagePackEngine.ValueToSet(APlan: TMessagePackMemberPlan;
  AValue: TMessagePackValue): TValue;
var
  I: Integer;
  Ords: TArray<Integer>;
  Element: TMessagePackMemberPlan;
  Names: TArray<string>;
  Name, Why: string;
begin
  Ords := nil;
  Element := TMessagePackMemberPlan.Create;
  try
    Element.TypeInfo := APlan.SetElemTypeInfo;
    Element.EnumMapping := APlan.SetElemMapping;
    Element.EnumRepresentation := APlan.EnumRepresentation;

    if AValue.Kind = TMessagePackKind.Str then
    begin
      { A comma-joined str is accepted because that is how the other formats
        in this library spell a set, and a document converted from one of
        them should still deserialize. }
      Names := Trim(AValue.AsStr).Split([','],
        TStringSplitOptions.ExcludeEmpty);
      for Name in Names do
      begin
        Ords := Ords + [TextToEnumOrdinal(APlan.SetElemTypeInfo, Name,
          APlan.SetElemMapping)];
      end;
    end
    else
    begin
      if AValue.Kind <> TMessagePackKind.Arr then
        raise EMessagePackInputError.CreateFmt(
          'Expected an array of set members, found %s.', [AValue.Describe]);
      for I := 0 to AValue.Count - 1 do
      begin
        Ords := Ords + [ValueToEnumOrdinal(Element, AValue[I])];
      end;
    end;
  finally
    Element.Free;
  end;
  if not TSerializationTypes.TryMakeSet(APlan.TypeInfo, Ords, Result, Why) then
    raise EMessagePackInputError.CreateFmt('%s is not a %s: %s.',
      [AValue.Describe, UTF8ToString(APlan.TypeInfo.Name), Why]);
end;

{ ---------------------------------------------------------- dates --- }

class function TMessagePackEngine.DateToValue(APlan: TMessagePackMemberPlan;
  AValue: TDateTime): TMessagePackValue;
var
  Milliseconds: Word;
  H, N, S: Word;
  Epoch: Int64;
begin
  { A date past the years 1 to 9999 is refused before anything is written:
    FormatDateTime spells one as 0000-00-00, and every reader here refuses
    it back. A TTime is a time of day and has no year to check. }
  if APlan.Kind <> TMessagePackMemberKind.TimeValue then
    TStructuralText.CheckDateTime(AValue);
  case APlan.DateRepresentation of
    TMessagePackDateTimeRepresentation.Timestamp:
      Exit(TMessagePackValue.NewTimestamp(AValue));
    TMessagePackDateTimeRepresentation.UnixSeconds:
      begin
        { Floor division, so an instant before the epoch with a fraction of
          a second is the second it falls in, the same one the timestamp's
          seconds field names. }
        Epoch := DateTimeToUnixMillis(AValue);
        if Epoch < 0 then Epoch := -((-Epoch + 999) div 1000)
        else Epoch := Epoch div 1000;
        Exit(TMessagePackValue.NewInt(Epoch));
      end;
    TMessagePackDateTimeRepresentation.UnixMilliseconds:
      Exit(TMessagePackValue.NewInt(DateTimeToUnixMillis(AValue)));
    TMessagePackDateTimeRepresentation.CustomString:
      Exit(TMessagePackValue.NewStr(
        FormatDateTime(APlan.DatePattern, AValue, TFormatSettings.Invariant)));
  end;

  DecodeTime(AValue, H, N, S, Milliseconds);
  case APlan.Kind of
    TMessagePackMemberKind.DateValue:
      Result := TMessagePackValue.NewStr(
        FormatDateTime('yyyy"-"mm"-"dd', AValue, TFormatSettings.Invariant));
    TMessagePackMemberKind.TimeValue:
      if Milliseconds = 0 then
        Result := TMessagePackValue.NewStr(
          FormatDateTime('hh":"nn":"ss', AValue, TFormatSettings.Invariant))
      else
        Result := TMessagePackValue.NewStr(FormatDateTime(
          'hh":"nn":"ss"."zzz', AValue, TFormatSettings.Invariant));
  else
    if Milliseconds = 0 then
      Result := TMessagePackValue.NewStr(FormatDateTime(
        'yyyy"-"mm"-"dd"T"hh":"nn":"ss', AValue, TFormatSettings.Invariant))
    else
      Result := TMessagePackValue.NewStr(FormatDateTime(
        'yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz', AValue,
        TFormatSettings.Invariant));
  end;
end;

class function TMessagePackEngine.ValueToDate(APlan: TMessagePackMemberPlan;
  AValue: TMessagePackValue): TDateTime;
var
  S: string;
  Y, M, D, H, N, Sec, Milliseconds: Word;
begin
  case APlan.DateRepresentation of
    TMessagePackDateTimeRepresentation.Timestamp:
      begin
        { A document may carry the instant as the extension OR as one of the
          numeric forms - a producer that predates the extension is common -
          so both are read where a timestamp was configured. }
        case AValue.Kind of
          TMessagePackKind.Timestamp: Exit(AValue.AsDateTime);
          TMessagePackKind.Int, TMessagePackKind.UInt:
            begin
              if not TStructuralText.TryUnixSecondsToDateTime(AValue.AsInt,
                   Result) then
                raise EMessagePackInputError.CreateFmt(
                  '%s seconds is outside the years a TDateTime holds.',
                  [AValue.Describe]);
              Exit;
            end;
          TMessagePackKind.Float32, TMessagePackKind.Float64:
            begin
              if not TStructuralText.TryUnixFloatSecondsToDateTime(
                   AValue.AsFloat, Result) then
                raise EMessagePackInputError.CreateFmt(
                  '%s seconds is outside the years a TDateTime holds.',
                  [AValue.Describe]);
              Exit;
            end;
        else
          raise EMessagePackInputError.CreateFmt(
            'Expected a timestamp, found %s.', [AValue.Describe]);
        end;
      end;
    TMessagePackDateTimeRepresentation.UnixSeconds:
      begin
        if not TStructuralText.TryUnixSecondsToDateTime(AValue.AsInt, Result) then
          raise EMessagePackInputError.CreateFmt(
            '%s seconds is outside the years a TDateTime holds.',
            [AValue.Describe]);
        Exit;
      end;
    TMessagePackDateTimeRepresentation.UnixMilliseconds:
      begin
        if not TStructuralText.TryUnixMillisToDateTime(AValue.AsInt, Result) then
          raise EMessagePackInputError.CreateFmt(
            '%s ms is outside the years a TDateTime holds.', [AValue.Describe]);
        Exit;
      end;
    TMessagePackDateTimeRepresentation.CustomString:
      begin
        { The pattern the writer wrote with, then the RTL's invariant
          reading, which is what 0.9 used and still reads what it read. }
        if not TStructuralText.TryDecodePattern(AValue.AsStr,
             APlan.DatePattern, Result) and
           not TryStrToDateTime(AValue.AsStr, Result,
             TFormatSettings.Invariant) then
          raise EMessagePackInputError.CreateFmt(
            '"%s" does not match the configured pattern "%s".',
            [AValue.AsStr, APlan.DatePattern]);
        Exit;
      end;
  end;

  S := Trim(AValue.AsStr);
  H := 0; N := 0; Sec := 0; Milliseconds := 0;
  try
    if APlan.Kind = TMessagePackMemberKind.TimeValue then
    begin
      H := Word(StrToInt(Copy(S, 1, 2)));
      N := Word(StrToInt(Copy(S, 4, 2)));
      Sec := Word(StrToInt(Copy(S, 7, 2)));
      if (Length(S) > 9) and (S[9] = '.') then
        Milliseconds := Word(StrToIntDef(Copy(S, 10, 3), 0));
      Exit(EncodeTime(H, N, Sec, Milliseconds));
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
        Milliseconds := Word(StrToIntDef(Copy(S, 21, 3), 0));
    end;
    { Composed the way Delphi encodes it: a date before 1899-12-30 is
      negative and SUBTRACTS its time of day, so adding one put the instant
      on the next day. }
    Result := TStructuralText.ComposeDateTime(EncodeDate(Y, M, D),
      EncodeTime(H, N, Sec, Milliseconds));
  except
    on E: EConvertError do
      raise EMessagePackInputError.CreateFmt('"%s" is not an ISO 8601 value.',
        [S]);
  end;
end;

{ ------------------------------------------------------------- writing --- }

{ A Variant through the dynamic tree, which is the one bridge every format
  shares: see TSerializationVariants. }
function VariantToMessagePack(const AValue: Variant): TMessagePackValue;
var
  N: TDynamicValue;
  Why: string;
begin
  if not TSerializationVariants.TryToDynamic(AValue, N, Why, False) then
    raise EMessagePackError.Create('The value ' + Why + '.');
  try
    Result := TMessagePackEngine.DynamicToMessagePack(N,
      TStructuralConversionOptions.Default, '$');
  finally
    N.Free;
  end;
end;

function MessagePackToVariant(ATypeInfo: PTypeInfo;
  AValue: TMessagePackValue): TValue;
var
  N: TDynamicValue;
  V: Variant;
  OV: OleVariant;
  Why: string;
begin
  N := TMessagePackEngine.MessagePackToDynamic(AValue,
    TStructuralConversionOptions.Default, '$');
  try
    if not TSerializationVariants.TryFromDynamic(N, V, Why) then
      raise EMessagePackInputError.Create('The MessagePack value ' + Why + '.');
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

class function TMessagePackEngine.WriteValue(APlan: TMessagePackMemberPlan;
  const AValue: TValue): TMessagePackValue;
var
  Obj: TObject;
  Raw: Pointer;
  Items, Pair, K, V: TValue;
  I: Integer;
  G: TGUID;
  Bytes: TBytes;
  Node: TMessagePackValue;
  KeyNode: TMessagePackValue;
begin
  case APlan.Kind of
    TMessagePackMemberKind.CustomSerializer:
      Exit(APlan.Serializer.Serialize(AValue));

    TMessagePackMemberKind.BoolValue:
      Exit(TMessagePackValue.NewBool(AValue.AsOrdinal <> 0));

    { Every integer goes out in the shortest family that holds it, so the
      declared Delphi width does not leak into the bytes. That is the
      opposite of BSON's rule and it is right here: MessagePack has one
      integer type with many encodings, so the encoding is free to shrink. }
    TMessagePackMemberKind.IntValue, TMessagePackMemberKind.Int64Value:
      Exit(TMessagePackValue.NewInt(RawSigned(AValue)));
    TMessagePackMemberKind.UIntValue, TMessagePackMemberKind.UInt64Value:
      Exit(TMessagePackValue.NewUInt(RawUnsigned(AValue)));

    TMessagePackMemberKind.SingleValue:
      Exit(TMessagePackValue.NewFloat32(AValue.AsExtended));
    TMessagePackMemberKind.FloatValue:
      Exit(TMessagePackValue.NewFloat64(AValue.AsExtended));

    TMessagePackMemberKind.CurrencyValue:
      case APlan.CurrencyRepresentation of
        TMessagePackCurrencyRepresentation.Float64:
          Exit(TMessagePackValue.NewFloat64(AValue.AsCurrency));
        TMessagePackCurrencyRepresentation.DecimalString:
          Exit(TMessagePackValue.NewStr(
            CurrToStr(AValue.AsCurrency, TFormatSettings.Invariant)));
      else
        { Currency IS a scaled integer - four implied decimals - so writing
          that integer is exact in both directions. A float64 would be lossy
          past fifteen significant digits, and MessagePack has no
          fixed-point family to use instead. }
        Exit(TMessagePackValue.NewInt(PInt64(AValue.GetReferenceToRawData)^));
      end;

    TMessagePackMemberKind.StrValue:
      Exit(TMessagePackValue.NewStr(AValue.AsString));

    TMessagePackMemberKind.DateValue, TMessagePackMemberKind.TimeValue,
    TMessagePackMemberKind.DateTimeValue:
      Exit(DateToValue(APlan, AValue.AsType<TDateTime>));

    TMessagePackMemberKind.GuidValue:
      begin
        G := AValue.AsType<TGUID>;
        if APlan.GuidRepresentation = TMessagePackGuidRepresentation.Bin then
        begin
          SetLength(Bytes, 16);
          Move(G, Bytes[0], 16);
          Exit(TMessagePackValue.NewBin(Bytes));
        end;
        Exit(TMessagePackValue.NewStr(
          LowerCase(Copy(GUIDToString(G), 2, 36))));
      end;

    TMessagePackMemberKind.BytesValue:
      Exit(TMessagePackValue.NewBin(AValue.AsType<TBytes>));

    TMessagePackMemberKind.EnumValue:
      Exit(EnumToValue(APlan, Integer(AValue.AsOrdinal)));

    TMessagePackMemberKind.SetValue:
      Exit(SetToValue(APlan, AValue));

    TMessagePackMemberKind.VariantValue:
      Exit(VariantToMessagePack(AValue.AsVariant));

    TMessagePackMemberKind.NullableValue:
      begin
        Raw := AValue.GetReferenceToRawData;
        if not APlan.NullableAccess.HasValue(Raw) then
          Exit(TMessagePackValue.NewNil);
        Exit(WriteValue(APlan.Inner, APlan.NullableAccess.GetValue(Raw)));
      end;

    TMessagePackMemberKind.ObjectValue:
      begin
        Obj := AValue.AsObject;
        if Obj = nil then Exit(TMessagePackValue.NewNil);
        if not TSerializationGraphGuard.Enter(Obj) then
          raise EMessagePackError.CreateFmt(
            '%s is already being written further up the graph: it is a ' +
            'cycle, and MessagePack has no back-reference. Break the cycle, ' +
            'or register a MessagePack type serializer that writes a key ' +
            'instead.', [Obj.ClassName]);
        try
          { The object body addresses its instance as an untyped pointer. }
          {$WARN UNSAFE_CAST OFF}
          Exit(WriteObjectBody(APlan.BoundPlan, Pointer(Obj)));
          {$WARN UNSAFE_CAST ON}
        finally
          TSerializationGraphGuard.Leave(Obj);
        end;
      end;

    { A record, and an array, count one level each: a record type holding
      a dynamic array of itself nests without any object in it, and used to
      run the writer out of stack. }
    TMessagePackMemberKind.RecordValue:
      begin
        TSerializationGraphGuard.EnterLevel;
        try
          Exit(WriteObjectBody(APlan.BoundPlan, AValue.GetReferenceToRawData));
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
      end;

    TMessagePackMemberKind.ArrayValue:
      begin
        TSerializationGraphGuard.EnterLevel;
        try
          Node := TMessagePackValue.NewArray;
          try
            for I := 0 to Integer(AValue.GetArrayLength) - 1 do
              Node.Add(WriteValue(APlan.Item, AValue.GetArrayElement(I)));
          except
            Node.Free;
            raise;
          end;
          Exit(Node);
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
      end;

    { A list or a dictionary is an object, and is entered as one: that
      counts its level and makes a container that holds itself a cycle. }
    TMessagePackMemberKind.ListValue:
      begin
        Obj := AValue.AsObject;
        if Obj = nil then Exit(TMessagePackValue.NewNil);
        if not TSerializationGraphGuard.Enter(Obj) then
          raise EMessagePackError.CreateFmt(
            '%s is already being written further up the graph: it is a ' +
            'cycle, and MessagePack has no back-reference.', [Obj.ClassName]);
        try
          Node := TMessagePackValue.NewArray;
          try
            Items := TSerializationTypes.ListElements(Obj,
              APlan.ContainerToArray);
            for I := 0 to Integer(Items.GetArrayLength) - 1 do
              Node.Add(WriteValue(APlan.Item, Items.GetArrayElement(I)));
          except
            Node.Free;
            raise;
          end;
          Exit(Node);
        finally
          TSerializationGraphGuard.Leave(Obj);
        end;
      end;

    TMessagePackMemberKind.DictionaryValue:
      begin
        Obj := AValue.AsObject;
        if Obj = nil then Exit(TMessagePackValue.NewNil);
        if not TSerializationGraphGuard.Enter(Obj) then
          raise EMessagePackError.CreateFmt(
            '%s is already being written further up the graph: it is a ' +
            'cycle, and MessagePack has no back-reference.', [Obj.ClassName]);
        try
          Node := TMessagePackValue.NewMap;
          try
            Items := APlan.ContainerToArray.Invoke(Obj, []);
            for I := 0 to Integer(Items.GetArrayLength) - 1 do
            begin
              Pair := Items.GetArrayElement(I);
              K := APlan.PairKeyField.GetValue(Pair.GetReferenceToRawData);
              V := APlan.PairValueField.GetValue(Pair.GetReferenceToRawData);
              { The key keeps its own type. A dictionary keyed by Integer
                becomes a map keyed by integers, not by decimal strings,
                which is what any other MessagePack consumer expects. }
              KeyNode := WriteValue(APlan.Key, K);
              try
                Node.Add(KeyNode, WriteValue(APlan.Value, V));
              except
                KeyNode.Free;
                raise;
              end;
            end;
          except
            Node.Free;
            raise;
          end;
          Exit(Node);
        finally
          TSerializationGraphGuard.Leave(Obj);
        end;
      end;
  end;
  raise EMessagePackInternalError.CreateFmt('Cannot serialize %s.',
    [UTF8ToString(APlan.TypeInfo.Name)]);
end;

class function TMessagePackEngine.WriteObjectBody(
  APlan: TMessagePackTypePlan; AInstance: Pointer): TMessagePackValue;
var
  FP: TMessagePackFieldPlan;
  V: TValue;
  Raw: Pointer;
begin
  Result := TMessagePackValue.NewMap;
  try
    for FP in APlan.Fields do
    begin
      V := ReadMember(FP, AInstance);
      { An empty nullable is omitted rather than written as nil, which
        matches every other format here. }
      if FP.Member.Kind = TMessagePackMemberKind.NullableValue then
      begin
        Raw := V.GetReferenceToRawData;
        if not FP.Member.NullableAccess.HasValue(Raw) then Continue;
      end;
      case FP.Member.Kind of
        TMessagePackMemberKind.ObjectValue, TMessagePackMemberKind.ListValue,
        TMessagePackMemberKind.DictionaryValue:
          if V.AsObject = nil then Continue;
        { Unassigned is no value at all, so the member is left out. }
        TMessagePackMemberKind.VariantValue:
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

class function TMessagePackEngine.ReadValue(APlan: TMessagePackMemberPlan;
  AValue: TMessagePackValue; const AExisting: TValue): TValue;
var
  Obj, Existing, Container: TObject;
  Built: Boolean;
  Inner, ItemValue, KeyValue, Rec: TValue;
  I: Integer;
  Arr: array of TValue;
  G: TGUID;
  Bytes: TBytes;
  S, Why: string;
  D: Double;
  C: Currency;
  Ok: Boolean;
begin
  case APlan.Kind of
    TMessagePackMemberKind.CustomSerializer:
      Exit(APlan.Serializer.Deserialize(AValue, APlan.TypeInfo, AExisting));

    TMessagePackMemberKind.BoolValue:
      Exit(TValue.FromOrdinal(APlan.TypeInfo, Ord(AValue.AsBool)));

    { Every integer member, range-checked against its own type from the
      signedness the document wrote: a subrange's lower bound, a negative
      number into a Cardinal and a UInt64 past High(Int64) into an Int64 are
      each an error, never a wrapped value. }
    TMessagePackMemberKind.IntValue, TMessagePackMemberKind.UIntValue,
    TMessagePackMemberKind.Int64Value, TMessagePackMemberKind.UInt64Value:
      begin
        case AValue.Kind of
          TMessagePackKind.Int:
            Ok := TSerializationTypes.TryIntegerFromInt64(APlan.TypeInfo,
              AValue.AsInt, Result);
          TMessagePackKind.UInt:
            Ok := TSerializationTypes.TryIntegerFromUInt64(APlan.TypeInfo,
              AValue.AsUInt, Result);
        else
          raise EMessagePackInputError.CreateFmt(
            'Expected an integer for %s, found %s.',
            [UTF8ToString(APlan.TypeInfo.Name), AValue.Describe]);
        end;
        if not Ok then
          raise EMessagePackInputError.CreateFmt('%s does not fit in %s.',
            [AValue.Describe, UTF8ToString(APlan.TypeInfo.Name)]);
        Exit;
      end;

    { Into the member's own width, checked: a Single does not become
      infinity for a value it cannot hold. }
    TMessagePackMemberKind.SingleValue, TMessagePackMemberKind.FloatValue:
      begin
        if not TSerializationTypes.TryFloatFromDouble(APlan.TypeInfo,
             AValue.AsFloat, Result, Why) then
          raise EMessagePackInputError.CreateFmt('%s: %s.',
            [UTF8ToString(APlan.TypeInfo.Name), Why]);
        Exit;
      end;

    TMessagePackMemberKind.CurrencyValue:
      begin
        case AValue.Kind of
          TMessagePackKind.Int:
            { The scaled integer, read back exactly. }
            PInt64(@C)^ := AValue.AsInt;
          TMessagePackKind.UInt:
            begin
              if AValue.AsUInt > UInt64(High(Int64)) then
                raise EMessagePackInputError.CreateFmt(
                  '%s is not a scaled currency value.', [AValue.Describe]);
              PInt64(@C)^ := Int64(AValue.AsUInt);
            end;
          { Checked: NaN or 1e300 must not become -922337203685477.5808. }
          TMessagePackKind.Float32, TMessagePackKind.Float64:
            begin
              if not TSerializationTypes.TryFloatFromDouble(
                   System.TypeInfo(Currency), AValue.AsFloat, Inner, Why) then
                raise EMessagePackInputError.Create(Why + '.');
              C := Inner.AsCurrency;
            end;
          TMessagePackKind.Str:
            if not TryStrToCurr(AValue.AsStr, C, TFormatSettings.Invariant) then
              raise EMessagePackInputError.CreateFmt(
                '"%s" is not a currency value.', [AValue.AsStr]);
        else
          raise EMessagePackInputError.CreateFmt(
            'Expected a currency, found %s.', [AValue.Describe]);
        end;
        Exit(TValue.From<Currency>(C));
      end;

    { Into the member's own code page, refusing text it cannot hold. }
    TMessagePackMemberKind.StrValue:
      begin
        S := AValue.AsStr;
        if not TSerializationTypes.TryStringFromText(APlan.TypeInfo, S,
             Result, Why) then
          raise EMessagePackInputError.Create(Why + '.');
        Exit;
      end;

    TMessagePackMemberKind.VariantValue:
      Exit(MessagePackToVariant(APlan.TypeInfo, AValue));

    TMessagePackMemberKind.DateValue, TMessagePackMemberKind.TimeValue,
    TMessagePackMemberKind.DateTimeValue:
      begin
        D := ValueToDate(APlan, AValue);
        TValue.Make(@D, APlan.TypeInfo, Result);
        Exit;
      end;

    TMessagePackMemberKind.GuidValue:
      begin
        if AValue.Kind = TMessagePackKind.Str then
        begin
          S := Trim(AValue.AsStr);
          if (S <> '') and (S[1] <> '{') then S := '{' + S + '}';
          try
            G := StringToGUID(S);
          except
            raise EMessagePackInputError.CreateFmt('"%s" is not a GUID.',
              [AValue.AsStr]);
          end;
          Exit(TValue.From<TGUID>(G));
        end;
        Bytes := AValue.AsBytes;
        if Length(Bytes) <> 16 then
          raise EMessagePackInputError.CreateFmt(
            'A UUID is 16 bytes; this one is %d.', [Length(Bytes)]);
        Move(Bytes[0], G, 16);
        Exit(TValue.From<TGUID>(G));
      end;

    TMessagePackMemberKind.BytesValue:
      Exit(TValue.From<TBytes>(AValue.AsBytes));

    TMessagePackMemberKind.EnumValue:
      Exit(TValue.FromOrdinal(APlan.TypeInfo,
        ValueToEnumOrdinal(APlan, AValue)));

    TMessagePackMemberKind.SetValue:
      Exit(ValueToSet(APlan, AValue));

    TMessagePackMemberKind.NullableValue:
      begin
        TValue.Make(nil, APlan.TypeInfo, Result);
        if AValue.Kind = TMessagePackKind.Null then Exit;
        Inner := ReadValue(APlan.Inner, AValue, TValue.Empty);
        APlan.NullableAccess.SetValue(Result.GetReferenceToRawData, Inner);
        Exit;
      end;

    TMessagePackMemberKind.ObjectValue:
      begin
        if AValue.Kind = TMessagePackKind.Null then
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

    TMessagePackMemberKind.RecordValue:
      begin
        { Read into a COPY of the member's current value, which is stored
          only once the whole record has read. A failure part way drops the
          copy, and with it every object this read had put in it, so those
          are freed here - and only those: an object that was already in the
          record, filled in place, is the one in the same place of
          AExisting. The copy is a separate one because TValue shares a
          record's data between assignments, and AExisting has to stay what
          the record held before. }
        if AExisting.IsEmpty then TValue.Make(nil, APlan.TypeInfo, Rec)
        else TValue.Make(AExisting.GetReferenceToRawData, APlan.TypeInfo, Rec);
        try
          ReadObjectBody(APlan.BoundPlan, Rec.GetReferenceToRawData, AValue);
        except
          TSerializationOwnership.ReleaseBuilt(APlan.TypeInfo, Rec, AExisting);
          raise;
        end;
        Exit(Rec);
      end;

    TMessagePackMemberKind.ArrayValue:
      begin
        if AValue.Kind <> TMessagePackKind.Arr then
          raise EMessagePackInputError.CreateFmt(
            'Expected an array, found %s.', [AValue.Describe]);
        { A static array has exactly as many elements as its type says. Each
          element is read into it in turn, so on a failure it holds exactly
          the elements this read built before the one that failed. }
        if APlan.TypeInfo.Kind = tkArray then
        begin
          TValue.Make(nil, APlan.TypeInfo, Result);
          if AValue.Count <> Result.GetArrayLength then
            raise EMessagePackInputError.CreateFmt(
              '%s holds exactly %d elements, and the document has %d.',
              [UTF8ToString(APlan.TypeInfo.Name), Result.GetArrayLength, AValue.Count]);
          try
            for I := 0 to AValue.Count - 1 do
              Result.SetArrayElement(I,
                ReadValue(APlan.Item, AValue[I], TValue.Empty));
          except
            TSerializationOwnership.ReleaseBuilt(APlan.TypeInfo, Result,
              TValue.Empty);
            raise;
          end;
          Exit;
        end;
        { The elements read so far are in Arr and nowhere else until the
          array is assembled; the slots after the one that failed are still
          empty. }
        SetLength(Arr, AValue.Count);
        try
          for I := 0 to AValue.Count - 1 do
            Arr[I] := ReadValue(APlan.Item, AValue[I], TValue.Empty);
        except
          TSerializationOwnership.ReleaseBuiltElements(APlan.Item.TypeInfo, Arr);
          raise;
        end;
        Exit(TValue.FromArray(APlan.TypeInfo, Arr));
      end;

    TMessagePackMemberKind.ListValue, TMessagePackMemberKind.DictionaryValue:
      begin
        if AValue.Kind = TMessagePackKind.Null then
        begin
          TValue.Make(nil, APlan.TypeInfo, Result);
          Exit;
        end;
        { Checked BEFORE an existing container is cleared: a scalar here is a
          document that does not match the contract, not an empty list, and
          it must not erase the caller's items on its way to failing. }
        if (APlan.Kind = TMessagePackMemberKind.ListValue) and
           (AValue.Kind <> TMessagePackKind.Arr) then
          raise EMessagePackInputError.CreateFmt(
            'Expected an array for %s, found %s.',
            [UTF8ToString(APlan.TypeInfo.Name), AValue.Describe]);
        if (APlan.Kind = TMessagePackMemberKind.DictionaryValue) and
           (AValue.Kind <> TMessagePackKind.Map) then
          raise EMessagePackInputError.CreateFmt(
            'Expected a map for %s, found %s.',
            [UTF8ToString(APlan.TypeInfo.Name), AValue.Describe]);
        Container := nil;
        if not AExisting.IsEmpty then Container := AExisting.AsObject;
        Built := Container = nil;
        if Built then Container := NewContainer(APlan)
        else if APlan.ContainerClear <> nil then
          APlan.ContainerClear.Invoke(Container, []);
        try
          for I := 0 to AValue.Count - 1 do
            if APlan.Kind = TMessagePackMemberKind.ListValue then
            begin
              ItemValue := ReadValue(APlan.Item, AValue[I], TValue.Empty);
              AddElement(APlan, Container, TValue.Empty, ItemValue);
            end
            else
            begin
              KeyValue := ReadValue(APlan.Key, AValue.Keys[I], TValue.Empty);
              ItemValue := ReadValue(APlan.Value, AValue[I], TValue.Empty);
              AddElement(APlan, Container, KeyValue, ItemValue);
            end;
        except
          { A container this read made goes with the elements it added: a
            TList<TObject> or a TDictionary<K, TObject> owns none of them,
            and freeing it alone orphaned every one. }
          if Built then TSerializationOwnership.ReleaseBuiltContainer(Container);
          raise;
        end;
        TValue.Make(@Container, APlan.TypeInfo, Result);
        Exit;
      end;
  end;
  raise EMessagePackInternalError.CreateFmt('Cannot deserialize %s.',
    [UTF8ToString(APlan.TypeInfo.Name)]);
end;

{ True when the container holds AItem itself: the same object, or a record
  holding the same objects. A container that refuses an element from its
  notification has already stored it, and then the element is the
  container's to free, not the read's. }
class function TMessagePackEngine.ContainerHolds(
  APlan: TMessagePackMemberPlan; AContainer: TObject;
  const AItem: TValue): Boolean;
var
  Items, Element, Pair: TValue;
  I: Integer;
begin
  if APlan.Kind = TMessagePackMemberKind.ListValue then
    Items := TSerializationTypes.ListElements(AContainer,
      APlan.ContainerToArray)
  else
    Items := APlan.ContainerToArray.Invoke(AContainer, []);
  for I := 0 to Integer(Items.GetArrayLength) - 1 do
  begin
    if APlan.Kind = TMessagePackMemberKind.ListValue then
      Element := Items.GetArrayElement(I)
    else
    begin
      Pair := Items.GetArrayElement(I);
      Element := APlan.PairValueField.GetValue(Pair.GetReferenceToRawData);
    end;
    if (Element.DataSize = AItem.DataSize) and
       CompareMem(Element.GetReferenceToRawData, AItem.GetReferenceToRawData,
         AItem.DataSize) then
      Exit(True);
  end;
  Result := False;
end;

{ One element into a list, or one entry into a dictionary. A key the
  document repeats replaces the entry for it, releasing the value read for
  the first occurrence rather than orphaning it.

  A container can refuse an element - a sorted TStringList with Duplicates
  = dupError raises EStringListError - and that is the document not fitting
  the container the caller configured, so it reaches the caller as
  MessagePack's input error naming the container, never as the RTL's
  exception. The element this read built for the add that failed is
  released first, unless the container took it before refusing. }
class procedure TMessagePackEngine.AddElement(APlan: TMessagePackMemberPlan;
  AContainer: TObject; const AKey, AItem: TValue);
var
  ItemType: PTypeInfo;
begin
  try
    if APlan.Kind = TMessagePackMemberKind.ListValue then
      APlan.ContainerAdd.Invoke(AContainer, [AItem])
    else
      TSerializationOwnership.AddOrSetBuilt(APlan.DictionaryAccess,
        AContainer, AKey, AItem);
  except
    on E: Exception do
    begin
      if APlan.Kind = TMessagePackMemberKind.ListValue then
        ItemType := APlan.Item.TypeInfo
      else
        ItemType := APlan.Value.TypeInfo;
      if TSerializationOwnership.IsOwningType(ItemType) and
         not ContainerHolds(APlan, AContainer, AItem) then
        TSerializationOwnership.ReleaseBuiltElements(ItemType, [AItem]);
      if string(E.UnitName).StartsWith('PascalForge.') then raise;
      raise EMessagePackInputError.CreateFmt(
        'The %s refused an element the document holds: %s',
        [AContainer.ClassName, E.Message]);
    end;
  end;
end;

class procedure TMessagePackEngine.ReadObjectBody(
  APlan: TMessagePackTypePlan; AInstance: Pointer; AValue: TMessagePackValue);
var
  FP: TMessagePackFieldPlan;
  Element: TMessagePackValue;
  Existing, NewValue: TValue;
begin
  if AValue.Kind <> TMessagePackKind.Map then
    raise EMessagePackInputError.CreateFmt('Expected a map, found %s.',
      [AValue.Describe]);
  for FP in APlan.Fields do
  begin
    Element := AValue.Find(FP.Name);
    { An absent entry leaves the member as it was - a document from a newer
      or older producer still deserializes. }
    if Element = nil then Continue;
    if not FP.Writable then Continue;

    if Element.Kind = TMessagePackKind.Null then
    begin
      { nil DETACHES; it never destroys. The serializer cannot prove it owns
        what a member points at, so it does not dispose of it. }
      case FP.Member.Kind of
        TMessagePackMemberKind.ObjectValue, TMessagePackMemberKind.ListValue,
        TMessagePackMemberKind.DictionaryValue,
        TMessagePackMemberKind.NullableValue:
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

class function TMessagePackEngine.ParseDocument(
  const AData: TBytes): TMessagePackValue;
begin
  Result := TMessagePackReader.Parse(AData);
end;

class function TMessagePackEngine.WriteDocument(
  AValue: TMessagePackValue): TBytes;
var
  W: TMessagePackWriter;
begin
  if AValue = nil then
    raise EMessagePackInternalError.Create('There is no value to write.');
  W.FData := nil;
  W.FPos := 0;
  W.PutValue(AValue);
  Result := W.Done;
end;

{ ------------------------------------------------------------------ root --- }

class function TMessagePackEngine.SerializeRootToValue(ATypeInfo: PTypeInfo;
  const AValue: TValue): TMessagePackValue;
var
  Plan: TMessagePackMemberPlan;
  Mark: Integer;
begin
  FLock.Enter;
  try
    Plan := GetRootPlan(ATypeInfo);
    FFrozen := True;
  finally
    FLock.Leave;
  end;
  { MessagePack's root is any value, so an Integer serializes to one byte and
    nothing is wrapped in a map under an invented member name to make it fit
    a document-shaped root. The root counts as a level like any other, and
    the level this write started from is restored whatever happens below,
    so a failed write cannot leave the next one on this thread part way
    down. }
  Mark := TSerializationGraphGuard.Level;
  try
    Result := WriteValue(Plan, AValue);
  finally
    TSerializationGraphGuard.RestoreLevel(Mark);
  end;
end;

class function TMessagePackEngine.SerializeRoot(ATypeInfo: PTypeInfo;
  const AValue: TValue): TBytes;
var
  Node: TMessagePackValue;
begin
  Node := SerializeRootToValue(ATypeInfo, AValue);
  try
    Result := WriteDocument(Node);
  finally
    Node.Free;
  end;
end;

class function TMessagePackEngine.DeserializeRootFromValue(
  ATypeInfo: PTypeInfo; AValue: TMessagePackValue;
  const AExisting: TValue): TValue;
var
  Plan: TMessagePackMemberPlan;
begin
  FLock.Enter;
  try
    Plan := GetRootPlan(ATypeInfo);
    FFrozen := True;
  finally
    FLock.Leave;
  end;
  Result := ReadValue(Plan, AValue, AExisting);
end;

class function TMessagePackEngine.DeserializeRoot(ATypeInfo: PTypeInfo;
  const AData: TBytes; const AExisting: TValue): TValue;
var
  Node: TMessagePackValue;
begin
  Node := ParseDocument(AData);
  try
    Result := DeserializeRootFromValue(ATypeInfo, Node, AExisting);
  finally
    Node.Free;
  end;
end;

{ ------------------------------------------------------- cross-format --- }

class function TMessagePackEngine.FromPayload(ATypeInfo: PTypeInfo;
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

class function TMessagePackEngine.FromPayloadStructural(
  const ASource: TSerializationPayload; AFrom: TSerializationFormat;
  AProfile: TStructuralConversionProfile): TBytes;
var
  Tree: TDynamicValue;
  Node: TMessagePackValue;
  Options: TStructuralConversionOptions;
begin
  Options := TStructuralConversionOptions.FromProfile(AProfile)
    .WithSource(AFrom).WithDestination(TSerializationFormat.MessagePack);
  Tree := TSerializationFormats.Require(AFrom,
    TSerializationFormatCapability.StructuralParse).ToDynamic(ASource, Options);
  try
    Node := DynamicToMessagePack(Tree, Options, TStructuralPath.Root);
    try
      Result := WriteDocument(Node);
    finally
      Node.Free;
    end;
  finally
    Tree.Free;
  end;
end;

{ ------------------------------------------------------ the dynamic tree ---

  MessagePack's own types line up with the tree's basic kinds almost exactly:
  nil, booleans, integers signed and unsigned, floats, text, bytes, arrays and
  maps are all both. Three places need a decision, and each is made here
  rather than being left to chance.

  A TIMESTAMP is a DateTime. MessagePack states that extension -1 is an
  instant, so the tree may carry it as one - a string that merely looks like a
  date could not be.

  AN EXTENSION this library has no meaning for arrives as Extended, tagged
  TDynamicTag.MsgPackExtension, carrying its type number and its bytes. That
  is what lets a document with an unknown extension be read and written back
  unchanged.

  A MAP KEY THAT IS NOT TEXT has no name in the tree, whose object members are
  named by strings. That is a NAME problem, so the name policy decides it:
  Encode renders an integer, boolean or nil key as text, and Error refuses and
  names the path. A key that is itself an array, a map, a float or bytes has
  no reasonable text form and is refused under either policy.
  --------------------------------------------------------------------------- }

function NamedPair(const AName1: string; AValue1: TDynamicValue;
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

class function TMessagePackEngine.MessagePackToDynamic(
  AValue: TMessagePackValue; const AOptions: TStructuralConversionOptions;
  const APath: string): TDynamicValue;
var
  I: Integer;
  Name: string;
  Key: TMessagePackValue;
begin
  case AValue.Kind of
    TMessagePackKind.Null: Exit(TDynamicValue.NewNull);
    TMessagePackKind.Bool: Exit(TDynamicValue.NewBool(AValue.AsBool));
    TMessagePackKind.Int: Exit(TDynamicValue.NewInt(AValue.AsInt));
    TMessagePackKind.UInt: Exit(TDynamicValue.NewUInt(AValue.AsUInt));
    TMessagePackKind.Float32, TMessagePackKind.Float64:
      Exit(TDynamicValue.NewFloat(AValue.AsFloat));
    TMessagePackKind.Str: Exit(TDynamicValue.NewStr(AValue.AsStr));
    TMessagePackKind.Bin: Exit(TDynamicValue.NewBytes(AValue.AsBytes));

    TMessagePackKind.Timestamp:
      begin
        { A TDateTime resolves to the millisecond. Under Lossless that is not
          good enough for an instant carrying a finer fraction, and saying so
          is better than rounding it and calling the result lossless. }
        if (AOptions.ValuePolicy = TStructuralValuePolicy.Lossless) and
           (AValue.Nanoseconds mod NANOSECONDS_PER_MILLISECOND <> 0) then
          raise EStructuralConversionError.CreateFor(
            TStructuralIssue.LossyConversion, AOptions,
            TSerializationFormat.MessagePack, APath, TDynamicKind.DateTime,
            'the timestamp carries a fraction finer than a millisecond, and ' +
            'the dynamic tree holds a TDateTime, which does not');
        Exit(TDynamicValue.NewDateTime(AValue.AsDateTime));
      end;

    TMessagePackKind.Extension:
      Exit(TDynamicValue.NewExtended(TDynamicTag.MsgPackExtension,
        NamedPair('type', TDynamicValue.NewInt(AValue.ExtensionType),
                  'data', TDynamicValue.NewBytes(AValue.AsBytes))));

    TMessagePackKind.Arr:
      begin
        Result := TDynamicValue.NewArray;
        try
          for I := 0 to AValue.Count - 1 do
            Result.AsArray.Adopt(MessagePackToDynamic(AValue[I], AOptions,
              TStructuralPath.Index(APath, I)));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
  end;

  if AValue.Kind <> TMessagePackKind.Map then
    raise EMessagePackInternalError.CreateFmt('Cannot convert %s.',
      [AValue.Describe]);

  Result := TDynamicValue.NewObject;
  try
    for I := 0 to AValue.Count - 1 do
    begin
      Key := AValue.Keys[I];
      case Key.Kind of
        TMessagePackKind.Str: Name := Key.AsStr;
        TMessagePackKind.Int, TMessagePackKind.UInt, TMessagePackKind.Bool,
        TMessagePackKind.Null:
          begin
            if AOptions.NamePolicy = TStructuralNamePolicy.Error then
              raise EStructuralConversionError.CreateFor(
                TStructuralIssue.InvalidDestinationName, AOptions,
                TSerializationFormat.MessagePack,
                TStructuralPath.Index(APath, I), TDynamicKind.Obj,
                'the map key is ' + Key.Describe + ' and an object member in ' +
                'the dynamic tree is named by a string');
            case Key.Kind of
              TMessagePackKind.Int: Name := IntToStr(Key.AsInt);
              TMessagePackKind.UInt: Name := UIntToStr(Key.AsUInt);
              TMessagePackKind.Bool:
                if Key.AsBool then Name := 'true' else Name := 'false';
            else
              Name := '';
            end;
          end;
      else
        raise EStructuralConversionError.CreateFor(
          TStructuralIssue.InvalidDestinationName, AOptions,
          TSerializationFormat.MessagePack, TStructuralPath.Index(APath, I),
          TDynamicKind.Obj,
          'the map key is ' + Key.Describe + ', which has no text form that ' +
          'could name an object member');
      end;
      Result.AsObject.Adopt(Name, MessagePackToDynamic(AValue[I], AOptions,
        TStructuralPath.Member(APath, Name)));
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ An Extended node this codec did not produce. MessagePack has no semantic tag
  system of its own - an extension number is opaque - so there is no honest
  place to put a CBOR tag or a BSON ObjectId except the representation the
  destination would have used anyway, and only where the caller asked for
  Natural. }
function ForeignExtendedToMessagePack(AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions;
  const APath: string): TMessagePackValue;
var
  Payload: TDynamicValue;
begin
  if AOptions.ValuePolicy <> TStructuralValuePolicy.Natural then
    raise EStructuralConversionError.CreateFor(
      TStructuralIssue.UnsupportedLosslessConversion, AOptions,
      TSerializationFormat.MessagePack, APath, TDynamicKind.Extended,
      Format('no published standard carries a "%s" value in MessagePack. ' +
        'The extension family is the only tagged type MessagePack has, and ' +
        'its numbers are assigned by the application rather than by a ' +
        'registry, so choosing one here would produce a document only this ' +
        'library could read', [AValue.ExtendedTag]));

  Payload := AValue.ExtendedValue;
  if Payload = nil then Exit(TMessagePackValue.NewNil);
  case Payload.Kind of
    TDynamicKind.Null: Exit(TMessagePackValue.NewNil);
    TDynamicKind.Str: Exit(TMessagePackValue.NewStr(Payload.AsStr));
    TDynamicKind.Bytes: Exit(TMessagePackValue.NewBin(Payload.AsBytes));
  end;
  raise EStructuralConversionError.CreateFor(
    TStructuralIssue.UnsupportedValueKind, AOptions,
    TSerializationFormat.MessagePack, APath, TDynamicKind.Extended,
    Format('a "%s" value carries %s, and MessagePack has no type that would ' +
      'be an honest stand-in for it', [AValue.ExtendedTag,
      Payload.Describe]));
end;

class function TMessagePackEngine.DynamicToMessagePack(AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions;
  const APath: string): TMessagePackValue;
var
  I: Integer;
  Payload, TypeNode, DataNode: TDynamicValue;
begin
  case AValue.Kind of
    TDynamicKind.Null: Exit(TMessagePackValue.NewNil);
    TDynamicKind.Bool: Exit(TMessagePackValue.NewBool(AValue.AsBool));
    TDynamicKind.Int: Exit(TMessagePackValue.NewInt(AValue.AsInt));
    TDynamicKind.UInt: Exit(TMessagePackValue.NewUInt(AValue.AsUInt));
    TDynamicKind.Float: Exit(TMessagePackValue.NewFloat64(AValue.AsFloat));
    TDynamicKind.Str: Exit(TMessagePackValue.NewStr(AValue.AsStr));
    TDynamicKind.Bytes: Exit(TMessagePackValue.NewBin(AValue.AsBytes));
    { The tree says this is an instant and MessagePack has a type for one, so
      no policy is involved and nothing is lost. }
    TDynamicKind.DateTime:
      Exit(TMessagePackValue.NewTimestamp(AValue.AsDateTime));

    { The timestamp extension is an instant. A day and a time of day are
      not, so they travel as str rather than claiming to be one. }
    TDynamicKind.Date:
      Exit(TMessagePackValue.NewStr(
        TStructuralText.EncodeDate(AValue.AsDateTime)));
    TDynamicKind.Time:
      Exit(TMessagePackValue.NewStr(
        TStructuralText.EncodeTime(AValue.AsDateTime)));

    TDynamicKind.Decimal:
      begin
        { MessagePack has integers and IEEE floats and nothing between them.
          A float64 would silently round an arbitrary-precision decimal,
          which is the failure this library exists to prevent, so Natural
          writes the digits as a str and the stricter profiles refuse. }
        if AOptions.ValuePolicy = TStructuralValuePolicy.Natural then
          Exit(TMessagePackValue.NewStr(AValue.AsDecimal));
        if AOptions.ValuePolicy = TStructuralValuePolicy.Lossless then
          raise EStructuralConversionError.CreateFor(
            TStructuralIssue.UnsupportedLosslessConversion, AOptions,
            TSerializationFormat.MessagePack, APath, TDynamicKind.Decimal,
            'MessagePack has no arbitrary-precision decimal and no published ' +
            'standard defines one over its extension family; a float64 would ' +
            'round the value away');
        raise EStructuralConversionError.CreateFor(
          TStructuralIssue.UnsupportedValueKind, AOptions,
          TSerializationFormat.MessagePack, APath, TDynamicKind.Decimal,
          'MessagePack has no decimal type');
      end;

    TDynamicKind.Extended:
      begin
        if not AValue.IsTagged(TDynamicTag.MsgPackExtension) then
          Exit(ForeignExtendedToMessagePack(AValue, AOptions, APath));
        Payload := AValue.ExtendedValue;
        TypeNode := nil;
        DataNode := nil;
        if (Payload <> nil) and (Payload.Kind = TDynamicKind.Obj) then
        begin
          TypeNode := Payload.Find('type');
          DataNode := Payload.Find('data');
        end;
        if (TypeNode = nil) or (TypeNode.Kind <> TDynamicKind.Int) or
           (DataNode = nil) or (DataNode.Kind <> TDynamicKind.Bytes) then
          raise EStructuralConversionError.CreateFor(
            TStructuralIssue.UnsupportedValueKind, AOptions,
            TSerializationFormat.MessagePack, APath, TDynamicKind.Extended,
            'a MessagePack extension carries a type number and a byte ' +
            'string, and this value carries something else');
        if (TypeNode.AsInt < Low(Shortint)) or
           (TypeNode.AsInt > High(Shortint)) then
          raise EStructuralConversionError.CreateFor(
            TStructuralIssue.UnsupportedValueKind, AOptions,
            TSerializationFormat.MessagePack, APath, TDynamicKind.Extended,
            Format('the extension type %d is outside the signed byte the ' +
              'format allows', [TypeNode.AsInt]));
        Exit(TMessagePackValue.NewExtension(Shortint(TypeNode.AsInt),
          DataNode.AsBytes));
      end;

    TDynamicKind.Arr:
      begin
        Result := TMessagePackValue.NewArray;
        try
          for I := 0 to AValue.Count - 1 do
            Result.Add(DynamicToMessagePack(AValue[I], AOptions,
              TStructuralPath.Index(APath, I)));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;

    TDynamicKind.Obj:
      begin
        { Every member name is a str key. There is nothing for a name policy
          to decide going this way: a MessagePack map key is an arbitrary
          value, so any string at all is spellable. }
        Result := TMessagePackValue.NewMap;
        try
          for I := 0 to AValue.Count - 1 do
            Result.Add(AValue.Names[I],
              DynamicToMessagePack(AValue[I], AOptions,
                TStructuralPath.Member(APath, AValue.Names[I])));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
  end;
  raise EStructuralConversionError.CreateFor(
    TStructuralIssue.UnsupportedValueKind, AOptions,
    TSerializationFormat.MessagePack, APath, AValue.Kind,
    'the dynamic kind has no MessagePack representation');
end;

{ ---------------------------------------------------------- configuration --- }

class procedure TMessagePackEngine.SetDateTimePolicy(ATypeInfo: PTypeInfo;
  const AFieldName: string; AKind: Integer; const APattern: string);
var
  Policy: TDateTimePolicy;
  Key: string;
begin
  FLock.Enter;
  try
    CheckNotFrozen;
    Policy := TDateTimePolicy.Make(AKind, APattern);
    if ATypeInfo = nil then
    begin
      { The global default moves every kind of date member at once, which is
        what a caller setting one without naming a type means. }
      FDatePolicies.SetGlobal(Policy);
      FTimePolicies.SetGlobal(Policy);
      FTimestampPolicies.SetGlobal(Policy);
      Exit;
    end;
    Key := TypeKeyOf(ATypeInfo);
    if AFieldName = '' then
    begin
      FDatePolicies.SetForType(Key, Policy);
      FTimePolicies.SetForType(Key, Policy);
      FTimestampPolicies.SetForType(Key, Policy);
    end
    else
    begin
      FDatePolicies.SetForField(Key, AFieldName, Policy);
      FTimePolicies.SetForField(Key, AFieldName, Policy);
      FTimestampPolicies.SetForField(Key, AFieldName, Policy);
    end;
  finally
    FLock.Leave;
  end;
end;

class procedure TMessagePackEngine.RegisterEnumMapping(ATypeInfo: PTypeInfo;
  const AValues: array of string);
var
  Mapping: TArray<string>;
  I: Integer;
begin
  FLock.Enter;
  try
    CheckNotFrozen;
    if (ATypeInfo = nil) or (ATypeInfo.Kind <> tkEnumeration) then
      raise EMessagePackInternalError.Create(
        'An enumeration mapping needs an enumeration type.');
    SetLength(Mapping, Length(AValues));
    for I := 0 to Integer(High(AValues)) do Mapping[I] := AValues[I];
    FEnumMappings.AddOrSetValue(ATypeInfo, Mapping);
  finally
    FLock.Leave;
  end;
end;

class procedure TMessagePackEngine.RegisterTypeSerializer(
  ATypeInfo: PTypeInfo; ASerializerClass: TMessagePackValueSerializerClass);
begin
  FLock.Enter;
  try
    CheckNotFrozen;
    if ATypeInfo = nil then
      raise EMessagePackInternalError.Create(
        'A custom serializer registration needs a type.');
    FTypeSerializers.AddOrSetValue(ATypeInfo, ASerializerClass);
  finally
    FLock.Leave;
  end;
end;

class procedure TMessagePackEngine.FreezeConfiguration;
begin
  FLock.Enter;
  try
    FFrozen := True;
  finally
    FLock.Leave;
  end;
end;

class function TMessagePackEngine.IsFrozen: Boolean;
begin
  Result := FFrozen;
end;

class procedure TMessagePackEngine.ResetConfiguration;
var
  P: TMessagePackTypePlan;
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
    FBuildDepth := 0;
    FFrozen := False;
  finally
    FLock.Leave;
  end;
end;

class function TMessagePackEngine.PlanCount: Integer;
begin
  FLock.Enter;
  try
    Result := Integer(FPlans.Count);
  finally
    FLock.Leave;
  end;
end;

end.
