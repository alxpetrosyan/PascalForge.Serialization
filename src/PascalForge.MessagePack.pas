{*******************************************************************************
  PascalForge.MessagePack

  Public MessagePack serialization facade for PascalForge.Serialization.

  Responsibilities
    - Typed MessagePack serialization/deserialization (TBytes).
    - Population of existing values.
    - MessagePack data model, options and customization API.

  Registration
    Direct TMessagePackSerializer use does not require format registration.
    Generic TSerialization operations require explicit registration:
    TMessagePackSerializationRegistration.RegisterFormat
    (PascalForge.MessagePack.Registration).

  Configuration
    Global serializer configuration becomes immutable after first use.

  Threading
    Serialization is safe for concurrent use after configuration is frozen.

  Documentation
    docs/formats/messagepack.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.MessagePack;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  MessagePack serialization.

      Data    := TMessagePackSerializer.Serialize<TShipment>(Shipment);   // TBytes
      Shipment := TMessagePackSerializer.Deserialize<TShipment>(Data);
      TMessagePackSerializer.Populate<TShipment>(Existing, Data);

  MessagePack is binary, so its natural Delphi type is TBytes and that is what
  this unit returns. There is no base64 API pretending otherwise: a caller who
  wants base64 can encode the bytes, and a caller who does not should never
  have to pay for it.

  This is a real MessagePack codec. A Delphi value is written straight to
  MessagePack bytes and read straight back; nothing routes through JSON text,
  through XML, or through the dynamic tree. The only thing shared with the
  other formats is the Delphi type foundation in
  PascalForge.Serialization.Core: what a nullable is, what a collection is,
  how a type is named.

  THE THREE DISTINCTIONS MESSAGEPACK MAKES AND THIS UNIT KEEPS

  1  str IS NOT bin. A Delphi string is text and is written as str, encoded
     UTF-8. TBytes is bytes and is written as bin. The two families were
     separated in 2013 precisely because conflating them made it impossible
     to tell a sentence from a JPEG, and nothing here re-conflates them.

  2  SIGNED IS NOT UNSIGNED. MessagePack's integer range runs from
     -(2^63) to (2^64)-1, which is wider than Int64. A uint64 above
     High(Int64) is carried as an unsigned value - never rounded into a
     Double, never wrapped into a negative Int64.

  3  A TIMESTAMP IS A TYPE, not a string. Extension type -1 is the
     specification's own timestamp, in three encodings, and a TDateTime is
     written as one.

  Writing always chooses the SHORTEST encoding a value fits in, because that
  is what every other implementation produces and therefore what an
  interoperability comparison is against.

  Using this unit needs no registration. PascalForge.MessagePack.Registration
  exists only for code that picks a format at run time.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections,
  PascalForge.Serialization.Core, PascalForge.Dynamic;

type
  EMessagePackError = class(Exception);
  { The document is at fault: malformed bytes, or a type the contract cannot
    accept. }
  EMessagePackInputError = class(EMessagePackError);
  { The model or the configuration is at fault. }
  EMessagePackInternalError = class(EMessagePackError);

  { 0xC1 is the one byte the specification marks "never used". It is not a
    reserved-for-later byte and it is not an unknown type: a document
    containing it is not a MessagePack document, and saying so by name is
    more useful than any guess. }
  EMessagePackReservedByte = class(EMessagePackInputError)
  public
    constructor CreateAt(AOffset: Integer);
  end;

  { A str whose bytes are not valid UTF-8. The specification says a str is
    UTF-8, so this is the document lying about itself rather than something
    to paper over with replacement characters. }
  EMessagePackInvalidUtf8 = class(EMessagePackInputError)
  public
    constructor CreateAt(AOffset: Integer; const AReason: string);
  end;

  { Arrays and maps nest, so a handful of bytes can describe a structure deep
    enough to exhaust the stack. The depth limit turns that into an error with
    a number in it. }
  EMessagePackDepthExceeded = class(EMessagePackInputError)
  public
    constructor CreateFor(ALimit: Integer);
  end;

{ ===========================================================================
  THE DOCUMENT MODEL

  MessagePack's own types, as a small tree. It exists because a custom
  MessagePack serializer needs somewhere to write, and because reading needs
  somewhere to put what it found before the contract is applied.

  EVERY FORMAT FAMILY THE SPECIFICATION DEFINES IS READ AND WRITTEN: positive
  and negative fixint, uint8 through uint64, int8 through int64, float32 and
  float64, nil, false, true, fixstr and str8/16/32, bin8/16/32, fixarray and
  array16/32, fixmap and map16/32, fixext1/2/4/8/16 and ext8/16/32.

  The kinds below are fewer than the format families because several families
  are just different widths of one type - uint8 and uint32 are both integers.
  The two places where a width IS the type are float32 against float64, which
  are genuinely different precisions, and the signed/unsigned split at
  High(Int64), which is genuinely different numbers.
  =========================================================================== }

type
  TMessagePackKind = (
    { The specification spells this one "nil"; that is a reserved word in
      Delphi, so the kind is Null and the byte is still 0xC0. }
    Null,
    Bool,
    { -(2^63) .. High(Int64). }
    Int,
    { High(Int64)+1 .. (2^64)-1, and only that range: everything an Int64 can
      hold is Int, so a consumer testing for Int is not surprised by a small
      number that happened to arrive in a uint32. }
    UInt,
    Float32,
    Float64,
    { Text, carried as UTF-8. }
    Str,
    { Bytes, carried as themselves. }
    Bin,
    Arr,
    Map,
    { A signed type code and a byte payload. }
    Extension,
    { Extension type -1, decoded: the specification's own timestamp. It is a
      separate kind rather than an Extension with a flag because a consumer
      asking "is this a point in time" should not have to know the number. }
    Timestamp);

const
  { The one extension type the specification itself defines. Application
    extension types are 0..127; -1..-128 are reserved for the specification,
    and -1 is the only one it has spent. }
  MessagePackTimestampExtensionType = -1;

  { How deep arrays and maps may nest before reading refuses. Deliberately
    generous for real documents and far below what would exhaust a stack. }
  MessagePackMaxDepth = 512;

type
  TMessagePackValue = class
  strict private
    FKind: TMessagePackKind;
    FBool: Boolean;
    { Int holds the value; UInt holds the same sixty-four bits read
      unsigned. }
    FInt: Int64;
    FFloat: Double;
    FStr: string;
    FBytes: TBytes;
    FExtensionType: Shortint;
    FSeconds: Int64;
    FNanoseconds: Cardinal;
    FItems: TObjectList<TMessagePackValue>;
    FKeys: TObjectList<TMessagePackValue>;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TMessagePackValue;
    function GetKey(AIndex: Integer): TMessagePackValue;
  public
    constructor Create(AKind: TMessagePackKind);
    destructor Destroy; override;

    class function NewNil: TMessagePackValue; static;
    class function NewBool(AValue: Boolean): TMessagePackValue; static;
    class function NewInt(AValue: Int64): TMessagePackValue; static;
    { Anything at or below High(Int64) becomes an Int, because it IS one.
      Only the top half of the unsigned range needs its own kind. }
    class function NewUInt(AValue: UInt64): TMessagePackValue; static;
    class function NewFloat32(AValue: Single): TMessagePackValue; static;
    class function NewFloat64(AValue: Double): TMessagePackValue; static;
    class function NewStr(const AValue: string): TMessagePackValue; static;
    class function NewBin(const AValue: TBytes): TMessagePackValue; static;
    class function NewArray: TMessagePackValue; static;
    class function NewMap: TMessagePackValue; static;
    { A type code and its bytes, exactly as they travel. An extension this
      library knows nothing about survives a read and a write unchanged,
      which is the whole point of the family. }
    class function NewExtension(AType: Shortint;
      const AData: TBytes): TMessagePackValue; static;
    { Seconds and nanoseconds since the Unix epoch, which is what the
      timestamp extension actually carries. }
    class function NewTimestamp(ASeconds: Int64;
      ANanoseconds: Cardinal): TMessagePackValue; overload; static;
    { A TDateTime, converted. Delphi's resolution is milliseconds, so the
      nanosecond field lands on a multiple of one million - said here rather
      than discovered later. }
    class function NewTimestamp(AValue: TDateTime): TMessagePackValue; overload; static;

    { Adds to an array. Adopts AValue. }
    procedure Add(AValue: TMessagePackValue); overload;
    { Adds to a map. Adopts BOTH, because a MessagePack map key is a value of
      any type and not merely a name - integer keys and boolean keys are
      ordinary and are kept as what they are. }
    procedure Add(AKey, AValue: TMessagePackValue); overload;
    { The common case: a map entry under a text key. }
    procedure Add(const AName: string; AValue: TMessagePackValue); overload;
    { The value under the str key AName, or nil. }
    function Find(const AName: string): TMessagePackValue;

    function AsBool: Boolean;
    function AsInt: Int64;
    function AsUInt: UInt64;
    function AsFloat: Double;
    function AsStr: string;
    function AsBytes: TBytes;
    function AsDateTime: TDateTime;
    { True when the key at AIndex is a str, which is what an object-shaped
      map has. }
    function IsStringKey(AIndex: Integer): Boolean;
    { The key at AIndex as text. Raises for a key that is not a str. }
    function KeyAsString(AIndex: Integer): string;
    { What this value is, in words, for an error message. }
    function Describe: string;

    property Kind: TMessagePackKind read FKind;
    property ExtensionType: Shortint read FExtensionType;
    { Timestamp only. }
    property Seconds: Int64 read FSeconds;
    property Nanoseconds: Cardinal read FNanoseconds;
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TMessagePackValue read GetItem; default;
    property Keys[AIndex: Integer]: TMessagePackValue read GetKey;
  end;

{ ===========================================================================
  ATTRIBUTES - MessagePack's own, and only MessagePack's.
  =========================================================================== }

type
  MessagePackNameAttribute = class(TCustomAttribute)
  strict private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

  MessagePackIgnoreAttribute = class(TCustomAttribute)
  end;

  { How a TDate, TTime or TDateTime member is represented. MessagePack's
    setting; it has no effect on JSON, XML or BSON. }
  TMessagePackDateTimeRepresentation = (
    { Extension type -1, in the smallest of its three encodings that is
      exact. The default for TDateTime, and the only representation another
      MessagePack implementation will recognize as an instant. }
    Timestamp,
    { An ISO 8601 str. The default for TDate and TTime, which are not
      instants and would be a lie as one. }
    StringIso8601,
    UnixSeconds,
    UnixMilliseconds,
    { A Delphi FormatDateTime pattern, written as a str. }
    CustomString);

  MessagePackDateTimeRepresentationAttribute = class(TCustomAttribute)
  strict private
    FRepresentation: TMessagePackDateTimeRepresentation;
    FPattern: string;
  public
    constructor Create(
      ARepresentation: TMessagePackDateTimeRepresentation); overload;
    constructor Create(const APattern: string); overload;
    property Representation: TMessagePackDateTimeRepresentation
      read FRepresentation;
    property Pattern: string read FPattern;
  end;

  { How a TGUID is represented. MessagePack has no UUID type and no extension
    type is defined for one, so this is a choice between two ordinary
    representations rather than a translation. Inventing an application
    extension number would make the document readable only by this library,
    which is the opposite of why anyone picks MessagePack. }
  TMessagePackGuidRepresentation = (
    { The thirty-six character canonical spelling, lower case, as a str.
      Anything reads it. }
    LowercaseString,
    { Sixteen bytes as bin. Compact, and it needs the reader to know. }
    Bin);

  MessagePackGuidRepresentationAttribute = class(TCustomAttribute)
  strict private
    FRepresentation: TMessagePackGuidRepresentation;
  public
    constructor Create(ARepresentation: TMessagePackGuidRepresentation);
    property Representation: TMessagePackGuidRepresentation read FRepresentation;
  end;

  { How a Currency is represented. MessagePack has no fixed-point type, so
    this is a decision rather than a translation. }
  TMessagePackCurrencyRepresentation = (
    { The scaled integer Delphi actually stores: value * 10000, as an
      integer. Exact in both directions, and the default for that reason. }
    ScaledInt64,
    { A float64. Convenient for consumers that expect a number, and lossy
      beyond fifteen significant digits. }
    Float64,
    { A decimal str. Exact, and readable by anything. }
    DecimalString);

  MessagePackCurrencyRepresentationAttribute = class(TCustomAttribute)
  strict private
    FRepresentation: TMessagePackCurrencyRepresentation;
  public
    constructor Create(ARepresentation: TMessagePackCurrencyRepresentation);
    property Representation: TMessagePackCurrencyRepresentation
      read FRepresentation;
  end;

  { How an enumeration is represented. }
  TMessagePackEnumRepresentation = (
    { The Delphi name, or the registered mapping, as a str. Survives a
      renumbering of the enumeration and is readable. }
    Name,
    { The ordinal, as an integer. Compact, and it breaks the moment somebody
      inserts a value in the middle. }
    Ordinal);

  MessagePackEnumRepresentationAttribute = class(TCustomAttribute)
  strict private
    FRepresentation: TMessagePackEnumRepresentation;
  public
    constructor Create(ARepresentation: TMessagePackEnumRepresentation);
    property Representation: TMessagePackEnumRepresentation read FRepresentation;
  end;

{ ===========================================================================
  CUSTOM SERIALIZERS - MessagePack's, not JSON's.
  =========================================================================== }

type
  TCustomMessagePackValueSerializer = class
  public
    { Returns the MessagePack value for AValue. The caller adopts it. }
    function Serialize(const AValue: TValue): TMessagePackValue; virtual; abstract;
    { AExisting is what the member already held; reuse it when it is an
      instance you can populate, and say so by returning it. }
    function Deserialize(AValue: TMessagePackValue; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; virtual; abstract;
  end;

  TMessagePackValueSerializerClass = class of TCustomMessagePackValueSerializer;

  { The typed base, and the one to use: it names the Delphi type, so an
    implementation never touches TValue or PTypeInfo. }
  TCustomMessagePackValueSerializer<T> = class(TCustomMessagePackValueSerializer)
  public
    function SerializeValue(const AValue: T): TMessagePackValue; virtual; abstract;
    function DeserializeValue(AValue: TMessagePackValue;
      const AExisting: T): T; virtual; abstract;

    function Serialize(const AValue: TValue): TMessagePackValue; override; final;
    function Deserialize(AValue: TMessagePackValue; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; override; final;
  end;

  MessagePackSerializerAttribute = class(TCustomAttribute)
  strict private
    FSerializerClass: TMessagePackValueSerializerClass;
  public
    constructor Create(ASerializerClass: TMessagePackValueSerializerClass);
    property SerializerClass: TMessagePackValueSerializerClass
      read FSerializerClass;
  end;

{ =========================================================================== }

type
  TMessagePackSerializer = class
  strict private
    { A generic method body declared in an interface section may reference
      only interface-declared symbols, so every generic entry point below is
      a thin shell over one of these. }
    class function DoSerialize(ATypeInfo: PTypeInfo;
      const AValue: TValue): TBytes; static;
    class function DoDeserialize(ATypeInfo: PTypeInfo;
      const AData: TBytes): TValue; static;
    class procedure DoPopulate(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AData: TBytes); static;
    class function DoFrom(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; static;
    class procedure DoSetDateTimePolicy(ATypeInfo: PTypeInfo;
      const AFieldName: string;
      ARepresentation: TMessagePackDateTimeRepresentation;
      const APattern: string); static;
    class procedure DoRegisterEnumMapping(ATypeInfo: PTypeInfo;
      const AValues: array of string); static;
    class procedure DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TMessagePackValueSerializerClass); static;
  public
    { --- the normal API ---------------------------------------------------- }
    class function Serialize<T>(const AValue: T): TBytes; static;
    class function Deserialize<T>(const AData: TBytes): T; static;
    class procedure Populate<T>(const AInstance: T; const AData: TBytes); static;

    { --- the document, for a caller working below the contract -------------

      MessagePack's root is ANY value, not a map - unlike BSON, whose root is
      always a document. So Parse returns whatever the bytes are and Write
      accepts whatever it is given, and no value is ever wrapped under an
      invented member name to make it fit. }
    class function Parse(const AData: TBytes): TMessagePackValue; static;
    class function Write(AValue: TMessagePackValue): TBytes; static;

    { --- destination-oriented conversion -----------------------------------

      MessagePack is the destination and is known at compile time, so only
      the SOURCE format is looked up. This unit has no compile-time
      dependency on any other format: the source is reached through the
      registry.

      The generic form is CONTRACT-AWARE: the source deserializes into T by
      its own rules and MessagePack writes T by its own. The non-generic form
      is STRUCTURAL and carries only what every format shares. }
    class function From(const ASource: string;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From(const ASource: TBytes;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat;
      AProfile: TStructuralConversionProfile): TBytes; overload; static;

    class function From<T>(const ASource: string;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From<T>(const ASource: TBytes;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From<T>(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; overload; static;

    { --- date and time ----------------------------------------------------

      MessagePack's settings, independent of every other format's. Resolution
      is a member attribute, then a field registration, then a type
      registration, then this global default, then the built-in
      representation - and it happens once, while a plan is built. }
    class procedure SetDateTimeRepresentation(
      ARepresentation: TMessagePackDateTimeRepresentation); overload; static;
    class procedure SetDateTimeRepresentation(
      const APattern: string); overload; static;
    class procedure RegisterDateTimeRepresentation<T>(
      ARepresentation: TMessagePackDateTimeRepresentation); overload; static;
    class procedure RegisterDateTimeRepresentation<T>(
      const APattern: string); overload; static;
    class procedure RegisterFieldDateTimeRepresentation<T>(
      const AFieldName: string;
      ARepresentation: TMessagePackDateTimeRepresentation); overload; static;
    class procedure RegisterFieldDateTimeRepresentation<T>(
      const AFieldName, APattern: string); overload; static;

    { --- registrations ----------------------------------------------------- }

    class procedure RegisterEnumMapping<T>(
      const AValues: array of string); static;
    class procedure RegisterTypeSerializer<T>(
      ASerializerClass: TMessagePackValueSerializerClass); static;

    { --- configuration lifecycle ------------------------------------------- }
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;

    { --- dynamic ---------------------------------------------------------

      A MessagePack value as a dynamic value, and back. An extension type
      this library does not interpret is an Extended value kept exactly. The
      tree is the caller's. }
    class function ToDynamic(const AData: TBytes): TDynamicValue; overload; static;
    class function ToDynamic(const AData: TBytes;
      const AOptions: TStructuralConversionOptions): TDynamicValue; overload; static;
    class function FromDynamic(AValue: TDynamicValue): TBytes; overload; static;
    class function FromDynamic(AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions): TBytes; overload; static;
    class procedure ResetConfiguration; static;
  end;

implementation

uses
  System.DateUtils,
  PascalForge.MessagePack.Internal;

{ ------------------------------------------------------------ exceptions --- }

constructor EMessagePackReservedByte.CreateAt(AOffset: Integer);
begin
  inherited CreateFmt(
    'The byte 0xC1 appears at offset %d. The MessagePack specification lists ' +
    '0xC1 as never used: it is not reserved for a future type and it is not ' +
    'an unknown one, so these bytes are not a MessagePack document. It is ' +
    'reported rather than skipped, because everything after it would be ' +
    'read at the wrong offset.', [AOffset]);
end;

constructor EMessagePackInvalidUtf8.CreateAt(AOffset: Integer;
  const AReason: string);
begin
  inherited CreateFmt(
    'The str beginning at offset %d is not valid UTF-8 (%s). The ' +
    'specification defines str as UTF-8 text, so this is the document ' +
    'contradicting itself; substituting replacement characters would turn ' +
    'that into silent corruption further downstream.', [AOffset, AReason]);
end;

constructor EMessagePackDepthExceeded.CreateFor(ALimit: Integer);
begin
  inherited CreateFmt(
    'The document nests arrays and maps more than %d deep. A few bytes can ' +
    'describe an arbitrarily deep structure - a thousand 0x91 bytes is a ' +
    'thousand nested one-element arrays - so the depth is bounded and the ' +
    'bound is reported rather than becoming a stack overflow.', [ALimit]);
end;

{ ------------------------------------------------------ TMessagePackValue --- }

constructor TMessagePackValue.Create(AKind: TMessagePackKind);
begin
  inherited Create;
  FKind := AKind;
  if AKind in [TMessagePackKind.Arr, TMessagePackKind.Map] then
    FItems := TObjectList<TMessagePackValue>.Create(True);
  if AKind = TMessagePackKind.Map then
    FKeys := TObjectList<TMessagePackValue>.Create(True);
end;

destructor TMessagePackValue.Destroy;
begin
  FKeys.Free;
  FItems.Free;
  inherited Destroy;
end;

class function TMessagePackValue.NewNil: TMessagePackValue;
begin
  Result := TMessagePackValue.Create(TMessagePackKind.Null);
end;

class function TMessagePackValue.NewBool(AValue: Boolean): TMessagePackValue;
begin
  Result := TMessagePackValue.Create(TMessagePackKind.Bool);
  Result.FBool := AValue;
end;

class function TMessagePackValue.NewInt(AValue: Int64): TMessagePackValue;
begin
  Result := TMessagePackValue.Create(TMessagePackKind.Int);
  Result.FInt := AValue;
end;

class function TMessagePackValue.NewUInt(AValue: UInt64): TMessagePackValue;
begin
  if AValue <= UInt64(High(Int64)) then Exit(NewInt(Int64(AValue)));
  Result := TMessagePackValue.Create(TMessagePackKind.UInt);
  Result.FInt := Int64(AValue);
end;

class function TMessagePackValue.NewFloat32(AValue: Single): TMessagePackValue;
begin
  Result := TMessagePackValue.Create(TMessagePackKind.Float32);
  Result.FFloat := AValue;
end;

class function TMessagePackValue.NewFloat64(AValue: Double): TMessagePackValue;
begin
  Result := TMessagePackValue.Create(TMessagePackKind.Float64);
  Result.FFloat := AValue;
end;

class function TMessagePackValue.NewStr(const AValue: string): TMessagePackValue;
begin
  Result := TMessagePackValue.Create(TMessagePackKind.Str);
  Result.FStr := AValue;
end;

class function TMessagePackValue.NewBin(const AValue: TBytes): TMessagePackValue;
begin
  Result := TMessagePackValue.Create(TMessagePackKind.Bin);
  Result.FBytes := AValue;
end;

class function TMessagePackValue.NewArray: TMessagePackValue;
begin
  Result := TMessagePackValue.Create(TMessagePackKind.Arr);
end;

class function TMessagePackValue.NewMap: TMessagePackValue;
begin
  Result := TMessagePackValue.Create(TMessagePackKind.Map);
end;

class function TMessagePackValue.NewExtension(AType: Shortint;
  const AData: TBytes): TMessagePackValue;
begin
  Result := TMessagePackValue.Create(TMessagePackKind.Extension);
  Result.FExtensionType := AType;
  Result.FBytes := AData;
end;

class function TMessagePackValue.NewTimestamp(ASeconds: Int64;
  ANanoseconds: Cardinal): TMessagePackValue;
begin
  if ANanoseconds > 999999999 then
    raise EMessagePackInternalError.CreateFmt(
      'A timestamp carries %s nanoseconds; the specification allows at most ' +
      '999999999, the rest belonging to the seconds field.',
      [UIntToStr(ANanoseconds)]);
  Result := TMessagePackValue.Create(TMessagePackKind.Timestamp);
  Result.FSeconds := ASeconds;
  Result.FNanoseconds := ANanoseconds;
end;

class function TMessagePackValue.NewTimestamp(
  AValue: TDateTime): TMessagePackValue;
var
  Seconds: Int64;
  Nanoseconds: Cardinal;
begin
  MessagePackDateTimeToUnix(AValue, Seconds, Nanoseconds);
  Result := NewTimestamp(Seconds, Nanoseconds);
end;

function TMessagePackValue.GetCount: Integer;
begin
  if FItems = nil then Exit(0);
  Result := Integer(FItems.Count);
end;

function TMessagePackValue.GetItem(AIndex: Integer): TMessagePackValue;
begin
  Result := FItems[AIndex];
end;

function TMessagePackValue.GetKey(AIndex: Integer): TMessagePackValue;
begin
  if FKeys = nil then
    raise EMessagePackInternalError.CreateFmt(
      'Only a map has keys; this is %s.', [Describe]);
  Result := FKeys[AIndex];
end;

procedure TMessagePackValue.Add(AValue: TMessagePackValue);
begin
  if FKind <> TMessagePackKind.Arr then
  begin
    AValue.Free;
    raise EMessagePackInternalError.Create(
      'Only an array takes a value with no key. A map entry needs both.');
  end;
  FItems.Add(AValue);
end;

procedure TMessagePackValue.Add(AKey, AValue: TMessagePackValue);
begin
  if FKind <> TMessagePackKind.Map then
  begin
    AKey.Free;
    AValue.Free;
    raise EMessagePackInternalError.Create(
      'Only a map takes a key and a value.');
  end;
  FKeys.Add(AKey);
  try
    FItems.Add(AValue);
  except
    { The key is already owned by FKeys, so only the value is loose. }
    AValue.Free;
    FKeys.Delete(FKeys.Count - 1);
    raise;
  end;
end;

procedure TMessagePackValue.Add(const AName: string; AValue: TMessagePackValue);
begin
  Add(NewStr(AName), AValue);
end;

function TMessagePackValue.Find(const AName: string): TMessagePackValue;
var
  I: Integer;
begin
  if FKeys = nil then Exit(nil);
  for I := 0 to Integer(FKeys.Count) - 1 do
    if (FKeys[I].Kind = TMessagePackKind.Str) and (FKeys[I].AsStr = AName) then
      Exit(FItems[I]);
  Result := nil;
end;

function TMessagePackValue.IsStringKey(AIndex: Integer): Boolean;
begin
  Result := (FKeys <> nil) and (FKeys[AIndex].Kind = TMessagePackKind.Str);
end;

function TMessagePackValue.KeyAsString(AIndex: Integer): string;
begin
  Result := GetKey(AIndex).AsStr;
end;

function TMessagePackValue.AsBool: Boolean;
begin
  if FKind <> TMessagePackKind.Bool then
    raise EMessagePackInputError.CreateFmt('Expected a boolean, found %s.',
      [Describe]);
  Result := FBool;
end;

function TMessagePackValue.AsInt: Int64;
begin
  case FKind of
    TMessagePackKind.Int: Result := FInt;
    { The caller asked for a signed integer and this value is above
      High(Int64). Handing back the two's complement bits would turn a very
      large positive number into a negative one silently, which is exactly
      the failure the UInt kind exists to prevent. }
    TMessagePackKind.UInt:
      raise EMessagePackInputError.CreateFmt(
        'The value %s does not fit in a signed 64-bit integer. Read it with ' +
        'AsUInt.', [UIntToStr(UInt64(FInt))]);
    { A float is accepted only when it is exactly an integer, so nothing is
      rounded away without saying so. }
    TMessagePackKind.Float32, TMessagePackKind.Float64:
      begin
        { Out of range first: Trunc of 1e19, an infinity or a NaN raised the
          RTL's EInvalidOp rather than a MessagePack error. }
        if not MessagePackDoubleInInt64Range(FFloat) then
          raise EMessagePackInputError.CreateFmt(
            'Expected an integer, found the float %g, which is outside the ' +
            'Int64 range.', [FFloat]);
        Result := Trunc(FFloat);
        if Result <> FFloat then
          raise EMessagePackInputError.CreateFmt(
            'Expected an integer, found the non-integral float %g.', [FFloat]);
      end;
  else
    raise EMessagePackInputError.CreateFmt('Expected an integer, found %s.',
      [Describe]);
  end;
end;

function TMessagePackValue.AsUInt: UInt64;
begin
  case FKind of
    TMessagePackKind.UInt: Result := UInt64(FInt);
    TMessagePackKind.Int:
      begin
        if FInt < 0 then
          raise EMessagePackInputError.CreateFmt(
            'The value %d is negative and cannot be read as unsigned.', [FInt]);
        Result := UInt64(FInt);
      end;
  else
    raise EMessagePackInputError.CreateFmt('Expected an integer, found %s.',
      [Describe]);
  end;
end;

function TMessagePackValue.AsFloat: Double;
begin
  case FKind of
    TMessagePackKind.Float32, TMessagePackKind.Float64: Result := FFloat;
    TMessagePackKind.Int: Result := FInt;
    TMessagePackKind.UInt: Result := UInt64(FInt);
  else
    raise EMessagePackInputError.CreateFmt('Expected a number, found %s.',
      [Describe]);
  end;
end;

function TMessagePackValue.AsStr: string;
begin
  if FKind <> TMessagePackKind.Str then
    raise EMessagePackInputError.CreateFmt('Expected a str, found %s.',
      [Describe]);
  Result := FStr;
end;

function TMessagePackValue.AsBytes: TBytes;
begin
  { bin is the obvious one; an extension's payload is also a run of bytes and
    a caller that wants it should not have to go the long way round. A str is
    deliberately NOT here: its bytes are an encoding of text, and handing
    them out as binary is how the two families get conflated again. }
  if not (FKind in [TMessagePackKind.Bin, TMessagePackKind.Extension]) then
    raise EMessagePackInputError.CreateFmt('Expected bin, found %s.',
      [Describe]);
  Result := FBytes;
end;

function TMessagePackValue.AsDateTime: TDateTime;
begin
  if FKind <> TMessagePackKind.Timestamp then
    raise EMessagePackInputError.CreateFmt('Expected a timestamp, found %s.',
      [Describe]);
  Result := MessagePackUnixToDateTime(FSeconds, FNanoseconds);
end;

function TMessagePackValue.Describe: string;
begin
  case FKind of
    TMessagePackKind.Null: Result := 'nil';
    TMessagePackKind.Bool: Result := 'a boolean';
    TMessagePackKind.Int: Result := Format('the integer %d', [FInt]);
    TMessagePackKind.UInt: Result := 'the unsigned integer ' +
      UIntToStr(UInt64(FInt));
    TMessagePackKind.Float32: Result := 'a float32';
    TMessagePackKind.Float64: Result := 'a float64';
    TMessagePackKind.Str: Result := Format('a str of %d characters',
      [Length(FStr)]);
    TMessagePackKind.Bin: Result := Format('bin of %d bytes', [Length(FBytes)]);
    TMessagePackKind.Arr: Result := Format('an array of %d elements', [Count]);
    TMessagePackKind.Map: Result := Format('a map of %d entries', [Count]);
    TMessagePackKind.Extension: Result := Format(
      'extension type %d of %d bytes', [FExtensionType, Length(FBytes)]);
    TMessagePackKind.Timestamp: Result := 'a timestamp';
  else
    Result := 'an unknown value';
  end;
end;

{ ------------------------------------------------------------- attributes --- }

constructor MessagePackNameAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

constructor MessagePackDateTimeRepresentationAttribute.Create(
  ARepresentation: TMessagePackDateTimeRepresentation);
begin
  inherited Create;
  FRepresentation := ARepresentation;
  FPattern := '';
end;

constructor MessagePackDateTimeRepresentationAttribute.Create(
  const APattern: string);
begin
  inherited Create;
  FRepresentation := TMessagePackDateTimeRepresentation.CustomString;
  FPattern := APattern;
end;

constructor MessagePackGuidRepresentationAttribute.Create(
  ARepresentation: TMessagePackGuidRepresentation);
begin
  inherited Create;
  FRepresentation := ARepresentation;
end;

constructor MessagePackCurrencyRepresentationAttribute.Create(
  ARepresentation: TMessagePackCurrencyRepresentation);
begin
  inherited Create;
  FRepresentation := ARepresentation;
end;

constructor MessagePackEnumRepresentationAttribute.Create(
  ARepresentation: TMessagePackEnumRepresentation);
begin
  inherited Create;
  FRepresentation := ARepresentation;
end;

constructor MessagePackSerializerAttribute.Create(
  ASerializerClass: TMessagePackValueSerializerClass);
begin
  inherited Create;
  FSerializerClass := ASerializerClass;
end;

{ ------------------------------------------------- typed custom serializer --- }

function TCustomMessagePackValueSerializer<T>.Serialize(
  const AValue: TValue): TMessagePackValue;
begin
  Result := SerializeValue(AValue.AsType<T>);
end;

function TCustomMessagePackValueSerializer<T>.Deserialize(
  AValue: TMessagePackValue; ATypeInfo: PTypeInfo;
  const AExisting: TValue): TValue;
var
  Existing: T;
begin
  if AExisting.IsEmpty then Existing := Default(T)
  else Existing := AExisting.AsType<T>;
  Result := TValue.From<T>(DeserializeValue(AValue, Existing));
end;

{ --------------------------------------------------------------- bridges --- }

class function TMessagePackSerializer.DoSerialize(ATypeInfo: PTypeInfo;
  const AValue: TValue): TBytes;
begin
  Result := TMessagePackEngine.SerializeRoot(ATypeInfo, AValue);
end;

class function TMessagePackSerializer.DoDeserialize(ATypeInfo: PTypeInfo;
  const AData: TBytes): TValue;
begin
  Result := TMessagePackEngine.DeserializeRoot(ATypeInfo, AData, TValue.Empty);
end;

class procedure TMessagePackSerializer.DoPopulate(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AData: TBytes);
begin
  TMessagePackEngine.DeserializeRoot(ATypeInfo, AData, AValue);
end;

class function TMessagePackSerializer.DoFrom(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload; AFrom: TSerializationFormat): TBytes;
begin
  Result := TMessagePackEngine.FromPayload(ATypeInfo, ASource, AFrom);
end;

class procedure TMessagePackSerializer.DoSetDateTimePolicy(
  ATypeInfo: PTypeInfo; const AFieldName: string;
  ARepresentation: TMessagePackDateTimeRepresentation; const APattern: string);
begin
  TMessagePackEngine.SetDateTimePolicy(ATypeInfo, AFieldName,
    Ord(ARepresentation), APattern);
end;

class procedure TMessagePackSerializer.DoRegisterEnumMapping(
  ATypeInfo: PTypeInfo; const AValues: array of string);
begin
  TMessagePackEngine.RegisterEnumMapping(ATypeInfo, AValues);
end;

class procedure TMessagePackSerializer.DoRegisterTypeSerializer(
  ATypeInfo: PTypeInfo; ASerializerClass: TMessagePackValueSerializerClass);
begin
  TMessagePackEngine.RegisterTypeSerializer(ATypeInfo, ASerializerClass);
end;

{ ------------------------------------------------------------- operations --- }

class function TMessagePackSerializer.Serialize<T>(const AValue: T): TBytes;
var
  V: TValue;
begin
  TValue.Make(@AValue, System.TypeInfo(T), V);
  Result := DoSerialize(System.TypeInfo(T), V);
end;

class function TMessagePackSerializer.Deserialize<T>(const AData: TBytes): T;
begin
  Result := DoDeserialize(System.TypeInfo(T), AData).AsType<T>;
end;

class procedure TMessagePackSerializer.Populate<T>(const AInstance: T;
  const AData: TBytes);
var
  V: TValue;
begin
  TValue.Make(@AInstance, System.TypeInfo(T), V);
  DoPopulate(System.TypeInfo(T), V, AData);
end;

class function TMessagePackSerializer.Parse(
  const AData: TBytes): TMessagePackValue;
begin
  Result := TMessagePackEngine.ParseDocument(AData);
end;

class function TMessagePackSerializer.Write(AValue: TMessagePackValue): TBytes;
begin
  Result := TMessagePackEngine.WriteDocument(AValue);
end;

class function TMessagePackSerializer.From(const ASource: string;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From(TSerializationPayload.FromText(ASource), AFrom);
end;

class function TMessagePackSerializer.From(const ASource: TBytes;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From(TSerializationPayload.FromBytes(ASource), AFrom);
end;

class function TMessagePackSerializer.From(
  const ASource: TSerializationPayload; AFrom: TSerializationFormat): TBytes;
begin
  Result := From(ASource, AFrom, TStructuralConversionProfile.Natural);
end;

class function TMessagePackSerializer.From(
  const ASource: TSerializationPayload; AFrom: TSerializationFormat;
  AProfile: TStructuralConversionProfile): TBytes;
begin
  Result := TMessagePackEngine.FromPayloadStructural(ASource, AFrom, AProfile);
end;

class function TMessagePackSerializer.From<T>(const ASource: string;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From<T>(TSerializationPayload.FromText(ASource), AFrom);
end;

class function TMessagePackSerializer.From<T>(const ASource: TBytes;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From<T>(TSerializationPayload.FromBytes(ASource), AFrom);
end;

class function TMessagePackSerializer.From<T>(
  const ASource: TSerializationPayload; AFrom: TSerializationFormat): TBytes;
begin
  Result := DoFrom(System.TypeInfo(T), ASource, AFrom);
end;

{ ------------------------------------------------------------ date and time --- }

class procedure TMessagePackSerializer.SetDateTimeRepresentation(
  ARepresentation: TMessagePackDateTimeRepresentation);
begin
  TMessagePackEngine.SetDateTimePolicy(nil, '', Ord(ARepresentation), '');
end;

class procedure TMessagePackSerializer.SetDateTimeRepresentation(
  const APattern: string);
begin
  TMessagePackEngine.SetDateTimePolicy(nil, '',
    Ord(TMessagePackDateTimeRepresentation.CustomString), APattern);
end;

class procedure TMessagePackSerializer.RegisterDateTimeRepresentation<T>(
  ARepresentation: TMessagePackDateTimeRepresentation);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), '', ARepresentation, '');
end;

class procedure TMessagePackSerializer.RegisterDateTimeRepresentation<T>(
  const APattern: string);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), '',
    TMessagePackDateTimeRepresentation.CustomString, APattern);
end;

class procedure TMessagePackSerializer.RegisterFieldDateTimeRepresentation<T>(
  const AFieldName: string;
  ARepresentation: TMessagePackDateTimeRepresentation);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), AFieldName, ARepresentation, '');
end;

class procedure TMessagePackSerializer.RegisterFieldDateTimeRepresentation<T>(
  const AFieldName, APattern: string);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), AFieldName,
    TMessagePackDateTimeRepresentation.CustomString, APattern);
end;

{ ---------------------------------------------------------- registrations --- }

class procedure TMessagePackSerializer.RegisterEnumMapping<T>(
  const AValues: array of string);
begin
  DoRegisterEnumMapping(System.TypeInfo(T), AValues);
end;

class procedure TMessagePackSerializer.RegisterTypeSerializer<T>(
  ASerializerClass: TMessagePackValueSerializerClass);
begin
  DoRegisterTypeSerializer(System.TypeInfo(T), ASerializerClass);
end;

class procedure TMessagePackSerializer.FreezeConfiguration;
begin
  TMessagePackEngine.FreezeConfiguration;
end;

class function TMessagePackSerializer.IsFrozen: Boolean;
begin
  Result := TMessagePackEngine.IsFrozen;
end;

class procedure TMessagePackSerializer.ResetConfiguration;
begin
  TMessagePackEngine.ResetConfiguration;
end;


{ ---------------------------------------------------------------- dynamic --- }

class function TMessagePackSerializer.ToDynamic(const AData: TBytes): TDynamicValue;
begin
  Result := ToDynamic(AData, TStructuralConversionOptions.Default);
end;

class function TMessagePackSerializer.ToDynamic(const AData: TBytes;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
var
  Value: TMessagePackValue;
begin
  Value := TMessagePackEngine.ParseDocument(AData);
  try
    Result := TMessagePackEngine.MessagePackToDynamic(Value, AOptions, '$');
  finally
    Value.Free;
  end;
end;

class function TMessagePackSerializer.FromDynamic(AValue: TDynamicValue): TBytes;
begin
  Result := FromDynamic(AValue, TStructuralConversionOptions.Default);
end;

class function TMessagePackSerializer.FromDynamic(AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TBytes;
var
  Value: TMessagePackValue;
begin
  Value := TMessagePackEngine.DynamicToMessagePack(AValue, AOptions, '$');
  try
    Result := TMessagePackEngine.WriteDocument(Value);
  finally
    Value.Free;
  end;
end;

end.
