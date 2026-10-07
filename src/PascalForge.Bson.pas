{*******************************************************************************
  PascalForge.Bson

  Public BSON serialization facade for PascalForge.Serialization.

  Responsibilities
    - Typed BSON serialization/deserialization (TBytes).
    - Population of existing values.
    - BSON-specific attributes, options, JSON conversion helpers and
      customization API.

  Registration
    Direct TBsonSerializer use does not require format registration.
    Generic TSerialization operations require explicit registration:
    TBsonSerializationRegistration.RegisterFormat (PascalForge.Bson.Registration).

  Configuration
    Global serializer configuration becomes immutable after first use.

  Threading
    Serialization is safe for concurrent use after configuration is frozen.

  Documentation
    docs/formats/bson.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Bson;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  BSON serialization.

      Data    := TBsonSerializer.Serialize<TShipment>(Shipment);   // TBytes
      Shipment := TBsonSerializer.Deserialize<TShipment>(Data);
      TBsonSerializer.Populate<TShipment>(Existing, Data);

  BSON is binary, so its natural Delphi type is TBytes and that is what this
  unit returns. There is no base64 API pretending otherwise: a caller who
  wants base64 can encode the bytes, and a caller who does not should never
  have to pay for it.

  This is a real BSON engine. A Delphi value is written straight to BSON and
  read straight back; nothing routes through JSON text, through XML, or
  through the dynamic tree. The only thing shared with the other formats is
  the Delphi type foundation in PascalForge.Serialization.Core: what a
  nullable is, what a collection is, how a type is named.

  Everything else is BSON's own. BSON reads only BSON attributes - [BsonName]
  never sees [JsonName] - and it keeps BSON's native type distinctions:
  int32 stays int32, int64 stays int64, a GUID is a binary subtype, a
  timestamp is a BSON datetime rather than a string.

  The default contract is documented in docs\bson-behavior.md.

  Using this unit needs no registration. PascalForge.Bson.Registration exists
  only for code that picks a format at run time.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections,
  PascalForge.Serialization.Core, PascalForge.Dynamic;

type
  EBsonError = class(Exception);
  { The document is at fault: malformed bytes, or a type the contract cannot
    accept. }
  EBsonInputError = class(EBsonError);
  { The model or the configuration is at fault. }
  EBsonInternalError = class(EBsonError);
  { A BSON element type this version does not implement. It is detected and
    named rather than coerced into something that looks plausible. }
  EBsonUnsupportedType = class(EBsonInputError)
  public
    constructor CreateFor(AElementType: Byte; const AName: string);
  end;

{ ===========================================================================
  THE DOCUMENT MODEL

  BSON's own element types, as a small tree. It exists because a custom BSON
  serializer needs somewhere to write, and because reading needs somewhere to
  put what it found before the contract is applied.

  EVERY BSON ELEMENT TYPE IS READ AND WRITTEN. TBsonKind below has one value
  for each byte the specification defines, including the three the
  specification marks deprecated - Undefined, DBPointer and Symbol - because
  a reader that refuses a deprecated type cannot read a document somebody
  wrote in 2009, and that document still exists.

  Several of them have no natural Delphi type: an ObjectId does, and it is
  TBsonObjectId below, but a Decimal128 has no Delphi counterpart at all.
  Those are carried EXACTLY, as the bytes the document holds, and reached
  through TBsonValue - directly, or through a typed custom serializer. See
  docs\bson-compatibility.md for the ledger.
  =========================================================================== }

type
  TBsonKind = (
    { The everyday ones. }
    Null, Bool, Int32, Int64, Double, Str, Binary, DateTime, Doc, Arr,
    { The rest of the specification. }
    ObjectId,          { $07  12 bytes }
    Timestamp,         { $11  uint64, a MongoDB internal timestamp }
    Decimal128,        { $13  16 bytes, IEEE 754-2008 decimal128 }
    Regex,             { $0B  pattern + options }
    JavaScript,        { $0D  code }
    JavaScriptScope,   { $0F  code + a scope document }
    Symbol,            { $0E  deprecated; a string }
    Undefined,         { $06  deprecated }
    DbPointer,         { $0C  deprecated; a namespace + 12 bytes }
    MinKey,            { $FF }
    MaxKey             { $7F }
  );

  { BSON binary carries a subtype byte, and the byte is kept exactly as the
    document wrote it - including the user-defined range 0x80..0xFF. These
    two are named because the library itself uses them. }
  TBsonBinarySubtype = (Generic, Uuid);

  { A 12-byte MongoDB ObjectId, as a Delphi type, so a DTO can have one:

        [BsonName('_id')]
        Id: TBsonObjectId;

    No timestamp is decoded out of it and no generator is offered. An
    ObjectId is an identifier that a database assigns; inventing one here
    would be inventing a value that has to be unique across machines. }
  TBsonObjectId = record
  public
    Bytes: array[0..11] of Byte;
    class function FromHex(const AHex: string): TBsonObjectId; static;
    class function FromBytes(const ABytes: TBytes): TBsonObjectId; static;
    class function TryFromHex(const AHex: string;
      out AValue: TBsonObjectId): Boolean; static;
    class function Empty: TBsonObjectId; static;
    function ToHex: string;
    function ToBytes: TBytes;
    function IsEmpty: Boolean;
    function Equals(const AOther: TBsonObjectId): Boolean;
  end;

  TBsonValue = class
  strict private
    FKind: TBsonKind;
    FBool: Boolean;
    FInt: System.Int64;
    FFloat: System.Double;
    FStr: string;
    FStr2: string;
    FBytes: TBytes;
    FSubtypeByte: Byte;
    FDateTime: TDateTime;
    FItems: TObjectList<TBsonValue>;
    FNames: TStringList;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TBsonValue;
    function GetName(AIndex: Integer): string;
    function GetSubtype: TBsonBinarySubtype;
  public
    constructor Create(AKind: TBsonKind);
    destructor Destroy; override;

    class function NewNull: TBsonValue; static;
    class function NewBool(AValue: Boolean): TBsonValue; static;
    class function NewInt32(AValue: Integer): TBsonValue; static;
    class function NewInt64(AValue: System.Int64): TBsonValue; static;
    class function NewDouble(AValue: System.Double): TBsonValue; static;
    class function NewString(const AValue: string): TBsonValue; static;
    class function NewBinary(const AValue: TBytes;
      ASubtype: TBsonBinarySubtype = TBsonBinarySubtype.Generic): TBsonValue; overload; static;
    { The subtype byte verbatim, for the ones with no name here. }
    class function NewBinary(const AValue: TBytes;
      ASubtypeByte: Byte): TBsonValue; overload; static;
    class function NewDateTime(AValue: TDateTime): TBsonValue; static;
    class function NewDocument: TBsonValue; static;
    class function NewArray: TBsonValue; static;

    class function NewObjectId(const AValue: TBsonObjectId): TBsonValue; static;
    { The raw 64 bits. BSON's timestamp is a MongoDB internal type - seconds
      in the high word, an increment in the low word - and it is NOT a
      datetime. Converting one into a TDateTime would be a lie. }
    class function NewTimestamp(AValue: UInt64): TBsonValue; static;
    { Sixteen bytes, little-endian, exactly as the document holds them.
      Delphi has no decimal128, so no arithmetic is offered and none is
      attempted: the value round trips byte for byte and that is the whole
      promise. }
    class function NewDecimal128(const AValue: TBytes): TBsonValue; static;
    class function NewRegex(const APattern, AOptions: string): TBsonValue; static;
    class function NewJavaScript(const ACode: string): TBsonValue; static;
    { Adopts AScope, which must be a document. }
    class function NewJavaScriptScope(const ACode: string;
      AScope: TBsonValue): TBsonValue; static;
    class function NewSymbol(const AValue: string): TBsonValue; static;
    class function NewUndefined: TBsonValue; static;
    class function NewDbPointer(const ANamespace: string;
      const AId: TBsonObjectId): TBsonValue; static;
    class function NewMinKey: TBsonValue; static;
    class function NewMaxKey: TBsonValue; static;

    { Adopts AValue. }
    procedure Add(const AName: string; AValue: TBsonValue); overload;
    procedure Add(AValue: TBsonValue); overload;
    function Find(const AName: string): TBsonValue;

    function AsBool: Boolean;
    function AsInt64: System.Int64;
    function AsDouble: System.Double;
    function AsString: string;
    function AsBytes: TBytes;
    function AsDateTime: TDateTime;
    function AsObjectId: TBsonObjectId;
    function AsTimestamp: UInt64;
    { Regex pattern / options, JavaScript code, DBPointer namespace. }
    function AsPattern: string;
    function AsOptions: string;
    function AsCode: string;
    { The scope document of a JavaScriptScope value. Borrowed. }
    function Scope: TBsonValue;
    { What this value is, in words, for an error message. }
    function Describe: string;

    property Kind: TBsonKind read FKind;
    { $04 reads back as Uuid and everything else as Generic. When the exact
      byte matters - and for anything outside 0x00 and 0x04 it does - use
      SubtypeByte. }
    property Subtype: TBsonBinarySubtype read GetSubtype;
    property SubtypeByte: Byte read FSubtypeByte;
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TBsonValue read GetItem; default;
    property Names[AIndex: Integer]: string read GetName;
  end;

{ ===========================================================================
  ATTRIBUTES - BSON's own, and only BSON's.
  =========================================================================== }

type
  BsonNameAttribute = class(TCustomAttribute)
  strict private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

  BsonIgnoreAttribute = class(TCustomAttribute)
  end;

  { How a TDate, TTime or TDateTime member is represented. BSON's setting; it
    has no effect on JSON or XML. }
  TBsonDateTimeRepresentation = (
    { BSON's own datetime element: milliseconds since the Unix epoch, as a
      64-bit integer. The default for TDateTime. }
    Native,
    { An ISO 8601 string. The default for TDate and TTime, which are not
      instants and would be a lie as one. }
    StringIso8601,
    UnixSeconds,
    UnixMilliseconds,
    { A Delphi FormatDateTime pattern, written as a string. }
    CustomString);

  BsonDateTimeRepresentationAttribute = class(TCustomAttribute)
  strict private
    FRepresentation: TBsonDateTimeRepresentation;
    FPattern: string;
  public
    constructor Create(ARepresentation: TBsonDateTimeRepresentation); overload;
    constructor Create(const APattern: string); overload;
    property Representation: TBsonDateTimeRepresentation read FRepresentation;
    property Pattern: string read FPattern;
  end;

  { How a TGUID is represented. BSON has a binary subtype for it, which is
    what a BSON consumer expects; JSON's lowercase-string rule is not
    inherited. }
  TBsonGuidRepresentation = (
    { Binary, subtype 4 - the standard UUID subtype - in RFC 4122 byte
      order, the order the text reads. }
    BinaryUuid,
    { The same 36 characters JSON uses, when a consumer insists on text. }
    LowercaseString);

  BsonGuidRepresentationAttribute = class(TCustomAttribute)
  strict private
    FRepresentation: TBsonGuidRepresentation;
  public
    constructor Create(ARepresentation: TBsonGuidRepresentation);
    property Representation: TBsonGuidRepresentation read FRepresentation;
  end;

  { How a Currency is represented. BSON has no fixed-point type, so this is a
    decision rather than a translation - see docs\bson-behavior.md. }
  TBsonCurrencyRepresentation = (
    { The scaled integer Delphi actually stores: value * 10000, as int64.
      Exact in both directions, and the default for that reason. }
    ScaledInt64,
    { A BSON double. Convenient for consumers that expect a number, and lossy
      beyond 15 significant digits. }
    Double,
    { A decimal string. Exact, and readable by anything. }
    DecimalString);

  BsonCurrencyRepresentationAttribute = class(TCustomAttribute)
  strict private
    FRepresentation: TBsonCurrencyRepresentation;
  public
    constructor Create(ARepresentation: TBsonCurrencyRepresentation);
    property Representation: TBsonCurrencyRepresentation read FRepresentation;
  end;

{ ===========================================================================
  CUSTOM SERIALIZERS - BSON's, not JSON's.
  =========================================================================== }

type
  TCustomBsonValueSerializer = class
  public
    { Returns the BSON value for AValue. The caller adopts it. }
    function Serialize(const AValue: TValue): TBsonValue; virtual; abstract;
    { AExisting is what the member already held; reuse it when it is an
      instance you can populate, and say so by returning it. }
    function Deserialize(AValue: TBsonValue; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; virtual; abstract;
  end;

  TBsonValueSerializerClass = class of TCustomBsonValueSerializer;

  { The typed base, and the one to use: it names the Delphi type, so an
    implementation never touches TValue or PTypeInfo. }
  TCustomBsonValueSerializer<T> = class(TCustomBsonValueSerializer)
  public
    function SerializeValue(const AValue: T): TBsonValue; virtual; abstract;
    function DeserializeValue(AValue: TBsonValue;
      const AExisting: T): T; virtual; abstract;

    function Serialize(const AValue: TValue): TBsonValue; override; final;
    function Deserialize(AValue: TBsonValue; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; override; final;
  end;

  BsonSerializerAttribute = class(TCustomAttribute)
  strict private
    FSerializerClass: TBsonValueSerializerClass;
  public
    constructor Create(ASerializerClass: TBsonValueSerializerClass);
    property SerializerClass: TBsonValueSerializerClass read FSerializerClass;
  end;

{ =========================================================================== }

type
  TBsonSerializer = class
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
      const ASource: TSerializationPayload; AFrom: TSerializationFormat): TBytes; static;
    class procedure DoSetDateTimePolicy(ATypeInfo: PTypeInfo;
      const AFieldName: string; ARepresentation: TBsonDateTimeRepresentation;
      const APattern: string); static;
    class procedure DoRegisterEnumMapping(ATypeInfo: PTypeInfo;
      const AValues: array of string); static;
    class procedure DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TBsonValueSerializerClass); static;
  public
    { --- the normal API ---------------------------------------------------- }
    class function Serialize<T>(const AValue: T): TBytes; static;
    class function Deserialize<T>(const AData: TBytes): T; static;
    class procedure Populate<T>(const AInstance: T; const AData: TBytes); static;

    { --- destination-oriented conversion -----------------------------------

      BSON is the destination and is known at compile time, so only the
      SOURCE format is looked up. This unit has no compile-time dependency on
      any other format: the source is reached through the registry.

          Data := TBsonSerializer.From(Json, TSerializationFormat.Json);
          Data := TBsonSerializer.From<TShipment>(Json, TSerializationFormat.Json);

      The generic form is CONTRACT-AWARE: the source deserializes into T by
      its own rules and BSON writes T by its own. The non-generic form is
      STRUCTURAL and carries only what every format shares. }
    class function From(const ASource: string;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From(const ASource: TBytes;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; overload; static;

    { Accepted for symmetry with the other formats, and it changes nothing.
      BSON's own types cover every dynamic kind and a BSON member name is an
      arbitrary string, so there is no name to encode, no value to adapt and
      no metadata to write - "$type" arrives as "$type" under every
      profile. }
    class function From(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat;
      AProfile: TStructuralConversionProfile): TBytes; overload; static;

    class function From<T>(const ASource: string;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From<T>(const ASource: TBytes;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From<T>(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; overload; static;

    { ----------------------------------------------------------------------
      BSON AND JSON, THREE WAYS

      BSON has twenty-two element types and JSON has six. There is no single
      right answer to that, so there are three, each named for what it is
      good at, and none of them invents a private convention.

      1  PLAIN. ToJson writes ordinary, idiomatic JSON: an ObjectId becomes
         its hex string, a UTC datetime an ISO-8601 string, a binary base64,
         a decimal128 its digits. Anything reads it, nothing needs to be
         taught anything - and the type information is gone, so FromJson
         without a schema cannot get it back.

      2  PLAIN PLUS A SCHEMA. ToJsonWithSchema writes the same plain JSON
         AND, separately, a small JSON object mapping each value's path to
         its BSON type name. FromJson(Json, Schema) puts them back together
         exactly. The data document stays clean - a consumer that does not
         care about the schema simply ignores it - and nothing is smuggled
         into it.

      3  MONGODB EXTENDED JSON. ToExtendedJson writes the canonical form
         defined by the MongoDB Extended JSON specification, in which an
         ObjectId becomes an object whose one member is "$oid" and a
         decimal128 an object whose one member is "$numberDecimal". One
         document, exactly reversible, and readable by mongosh and by every
         MongoDB driver - because the representation is theirs.

      WHAT PLAIN JSON PROVES, GOING THE OTHER WAY. FromJson with no schema
      infers only what JSON itself states: an integral number becomes int32
      or int64 by magnitude, a fractional one a double, and a string stays a
      string. A twenty-four character hex string is NOT an ObjectId, an
      ISO-8601-looking string is NOT a date, and base64-looking text is NOT
      binary, because JSON did not say so and the difference between "could
      have been" and "was" is the difference between a converter and a
      guess. Callers who know pass the schema or use Extended JSON.

      All six of these reach JSON through the format registry, like every
      other cross-format call in this unit, so JSON has to be registered
      explicitly (TJsonSerializationRegistration.RegisterFormat). If it is not,
      ESerializationFormatNotRegistered says exactly that. }
    class function ToJson(const AData: TBytes): string; static;
    class function ToJsonWithSchema(const AData: TBytes;
      out ASchema: string): string; static;
    class function ToExtendedJson(const AData: TBytes): string; static;

    class function FromJson(const AJson: string): TBytes; overload; static;
    class function FromJson(const AJson, ASchema: string): TBytes; overload; static;
    class function FromExtendedJson(const AJson: string): TBytes; static;

    { --- the document, for a caller working below the contract -------------

      BSON bytes as the TBsonValue tree, and back, with every element type
      the specification defines: what a document says, before any Delphi
      type is involved. A BSON root is always a document, so ParseDocument
      always returns one. The caller owns the tree it returns; WriteDocument
      borrows the one it is given. Malformed bytes raise EBsonInputError.
      WriteDocument raises EBsonInternalError for nil, for a nil element and
      for a tree nesting more than 512 documents and arrays - the depth
      ParseDocument accepts - so it never writes what ParseDocument
      refuses. }
    class function ParseDocument(const AData: TBytes): TBsonValue; static;
    class function WriteDocument(ADocument: TBsonValue): TBytes; static;

    { --- date and time ----------------------------------------------------

      BSON's settings, independent of JSON's and XML's. Resolution is a
      member attribute, then a field registration, then a type registration,
      then this global default, then the built-in representation - and it
      happens once, while a plan is built. }
    class procedure SetDateTimeRepresentation(
      ARepresentation: TBsonDateTimeRepresentation); overload; static;
    class procedure SetDateTimeRepresentation(
      const APattern: string); overload; static;
    class procedure RegisterDateTimeRepresentation<T>(
      ARepresentation: TBsonDateTimeRepresentation); overload; static;
    class procedure RegisterDateTimeRepresentation<T>(
      const APattern: string); overload; static;
    class procedure RegisterFieldDateTimeRepresentation<T>(
      const AFieldName: string;
      ARepresentation: TBsonDateTimeRepresentation); overload; static;
    class procedure RegisterFieldDateTimeRepresentation<T>(
      const AFieldName, APattern: string); overload; static;

    { --- registrations ----------------------------------------------------- }

    class procedure RegisterEnumMapping<T>(
      const AValues: array of string); static;
    class procedure RegisterTypeSerializer<T>(
      ASerializerClass: TBsonValueSerializerClass); static;

    { --- configuration lifecycle ------------------------------------------- }
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;

    { --- dynamic ---------------------------------------------------------

      A BSON document as a dynamic value, and back. BSON's own types -
      ObjectId, decimal128, timestamps and the rest - are Extended values,
      kept exactly. A root that is not an object travels under the name
      "value", as on the typed path. The tree is the caller's. }
    class function ToDynamic(const ABson: TBytes): TDynamicValue; static;
    class function FromDynamic(AValue: TDynamicValue): TBytes; static;
    class procedure ResetConfiguration; static;
  end;

implementation

uses
  PascalForge.Bson.Internal;

{ ------------------------------------------------------------ exceptions --- }

constructor EBsonUnsupportedType.CreateFor(AElementType: Byte;
  const AName: string);
begin
  { Every element type the BSON specification defines is implemented, so
    reaching here means the byte is not one of them: a corrupt document, a
    document from a future revision of the format, or bytes that were never
    BSON. Guessing at it is how a reader silently corrupts data. }
  inherited CreateFmt(
    'The BSON element "%s" has type byte 0x%.2x, which the BSON ' +
    'specification does not define. Every defined element type is ' +
    'implemented here, so this is a document that is corrupt, is not BSON, ' +
    'or uses something newer than this library knows about. It is reported ' +
    'rather than skipped: a value that arrives as the wrong type is worse ' +
    'than one that does not arrive.', [AName, AElementType]);
end;

{ ------------------------------------------------------------ TBsonValue --- }

{ ---------------------------------------------------------- TBsonObjectId --- }

class function TBsonObjectId.Empty: TBsonObjectId;
begin
  FillChar(Result.Bytes, SizeOf(Result.Bytes), 0);
end;

class function TBsonObjectId.TryFromHex(const AHex: string;
  out AValue: TBsonObjectId): Boolean;
var
  I, Hi, Lo: Integer;

  function Digit(C: Char): Integer;
  begin
    case C of
      '0'..'9': Result := Ord(C) - Ord('0');
      'a'..'f': Result := Ord(C) - Ord('a') + 10;
      'A'..'F': Result := Ord(C) - Ord('A') + 10;
    else
      Result := -1;
    end;
  end;

begin
  AValue := Empty;
  if Length(AHex) <> 24 then Exit(False);
  for I := 0 to 11 do
  begin
    Hi := Digit(AHex[I * 2 + 1]);
    Lo := Digit(AHex[I * 2 + 2]);
    if (Hi < 0) or (Lo < 0) then Exit(False);
    AValue.Bytes[I] := Byte((Hi shl 4) or Lo);
  end;
  Result := True;
end;

class function TBsonObjectId.FromHex(const AHex: string): TBsonObjectId;
begin
  if not TryFromHex(AHex, Result) then
    raise EBsonInputError.CreateFmt(
      '"%s" is not an ObjectId. One is exactly 24 hexadecimal digits.',
      [AHex]);
end;

class function TBsonObjectId.FromBytes(const ABytes: TBytes): TBsonObjectId;
begin
  if Length(ABytes) <> 12 then
    raise EBsonInputError.CreateFmt(
      'An ObjectId is exactly 12 bytes; this is %d.', [Length(ABytes)]);
  Move(ABytes[0], Result.Bytes[0], 12);
end;

function TBsonObjectId.ToHex: string;
const
  DIGITS: array[0..15] of Char = ('0', '1', '2', '3', '4', '5', '6', '7',
    '8', '9', 'a', 'b', 'c', 'd', 'e', 'f');
var
  I: Integer;
begin
  SetLength(Result, 24);
  for I := 0 to 11 do
  begin
    Result[I * 2 + 1] := DIGITS[Bytes[I] shr 4];
    Result[I * 2 + 2] := DIGITS[Bytes[I] and $0F];
  end;
end;

function TBsonObjectId.ToBytes: TBytes;
begin
  SetLength(Result, 12);
  Move(Bytes[0], Result[0], 12);
end;

function TBsonObjectId.IsEmpty: Boolean;
var
  I: Integer;
begin
  for I := 0 to 11 do
    if Bytes[I] <> 0 then Exit(False);
  Result := True;
end;

function TBsonObjectId.Equals(const AOther: TBsonObjectId): Boolean;
begin
  Result := CompareMem(@Bytes[0], @AOther.Bytes[0], 12);
end;

{ ------------------------------------------------------------- TBsonValue --- }

constructor TBsonValue.Create(AKind: TBsonKind);
begin
  inherited Create;
  FKind := AKind;
  if AKind in [TBsonKind.Doc, TBsonKind.Arr, TBsonKind.JavaScriptScope] then
  begin
    FItems := TObjectList<TBsonValue>.Create(True);
    FNames := TStringList.Create;
  end;
end;

destructor TBsonValue.Destroy;
begin
  FNames.Free;
  FItems.Free;
  inherited Destroy;
end;

class function TBsonValue.NewNull: TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.Null);
end;

class function TBsonValue.NewBool(AValue: Boolean): TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.Bool);
  Result.FBool := AValue;
end;

class function TBsonValue.NewInt32(AValue: Integer): TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.Int32);
  Result.FInt := AValue;
end;

class function TBsonValue.NewInt64(AValue: System.Int64): TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.Int64);
  Result.FInt := AValue;
end;

class function TBsonValue.NewDouble(AValue: System.Double): TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.Double);
  Result.FFloat := AValue;
end;

class function TBsonValue.NewString(const AValue: string): TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.Str);
  Result.FStr := AValue;
end;

class function TBsonValue.NewBinary(const AValue: TBytes;
  ASubtype: TBsonBinarySubtype): TBsonValue;
begin
  if ASubtype = TBsonBinarySubtype.Uuid then Result := NewBinary(AValue, Byte($04))
  else Result := NewBinary(AValue, Byte($00));
end;

class function TBsonValue.NewBinary(const AValue: TBytes;
  ASubtypeByte: Byte): TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.Binary);
  Result.FBytes := AValue;
  Result.FSubtypeByte := ASubtypeByte;
end;

function TBsonValue.GetSubtype: TBsonBinarySubtype;
begin
  if FSubtypeByte = $04 then Result := TBsonBinarySubtype.Uuid
  else Result := TBsonBinarySubtype.Generic;
end;

class function TBsonValue.NewObjectId(const AValue: TBsonObjectId): TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.ObjectId);
  Result.FBytes := AValue.ToBytes;
end;

class function TBsonValue.NewTimestamp(AValue: UInt64): TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.Timestamp);
  Result.FInt := System.Int64(AValue);
end;

class function TBsonValue.NewDecimal128(const AValue: TBytes): TBsonValue;
begin
  if Length(AValue) <> 16 then
    raise EBsonInternalError.CreateFmt(
      'A decimal128 is exactly 16 bytes; this is %d.', [Length(AValue)]);
  Result := TBsonValue.Create(TBsonKind.Decimal128);
  Result.FBytes := AValue;
end;

class function TBsonValue.NewRegex(const APattern, AOptions: string): TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.Regex);
  Result.FStr := APattern;
  Result.FStr2 := AOptions;
end;

class function TBsonValue.NewJavaScript(const ACode: string): TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.JavaScript);
  Result.FStr := ACode;
end;

class function TBsonValue.NewJavaScriptScope(const ACode: string;
  AScope: TBsonValue): TBsonValue;
begin
  if (AScope = nil) or (AScope.Kind <> TBsonKind.Doc) then
  begin
    AScope.Free;
    raise EBsonInternalError.Create(
      'The scope of a JavaScript-with-scope value is a document.');
  end;
  Result := TBsonValue.Create(TBsonKind.JavaScriptScope);
  Result.FStr := ACode;
  Result.Add('$scope', AScope);
end;

class function TBsonValue.NewSymbol(const AValue: string): TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.Symbol);
  Result.FStr := AValue;
end;

class function TBsonValue.NewUndefined: TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.Undefined);
end;

class function TBsonValue.NewDbPointer(const ANamespace: string;
  const AId: TBsonObjectId): TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.DbPointer);
  Result.FStr := ANamespace;
  Result.FBytes := AId.ToBytes;
end;

class function TBsonValue.NewMinKey: TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.MinKey);
end;

class function TBsonValue.NewMaxKey: TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.MaxKey);
end;

function TBsonValue.AsObjectId: TBsonObjectId;
begin
  if not (FKind in [TBsonKind.ObjectId, TBsonKind.DbPointer]) then
    raise EBsonInputError.CreateFmt('Expected an ObjectId, found %s.',
      [Describe]);
  Result := TBsonObjectId.FromBytes(FBytes);
end;

function TBsonValue.AsTimestamp: UInt64;
begin
  if FKind <> TBsonKind.Timestamp then
    raise EBsonInputError.CreateFmt('Expected a timestamp, found %s.',
      [Describe]);
  Result := UInt64(FInt);
end;

function TBsonValue.AsPattern: string;
begin
  if not (FKind in [TBsonKind.Regex, TBsonKind.DbPointer]) then
    raise EBsonInputError.CreateFmt('Expected a regular expression, found %s.',
      [Describe]);
  Result := FStr;
end;

function TBsonValue.AsOptions: string;
begin
  if FKind <> TBsonKind.Regex then
    raise EBsonInputError.CreateFmt('Expected a regular expression, found %s.',
      [Describe]);
  Result := FStr2;
end;

function TBsonValue.AsCode: string;
begin
  if not (FKind in [TBsonKind.JavaScript, TBsonKind.JavaScriptScope]) then
    raise EBsonInputError.CreateFmt('Expected JavaScript code, found %s.',
      [Describe]);
  Result := FStr;
end;

function TBsonValue.Scope: TBsonValue;
begin
  if (FKind <> TBsonKind.JavaScriptScope) or (Count = 0) then
    raise EBsonInputError.CreateFmt(
      'Expected JavaScript with a scope, found %s.', [Describe]);
  Result := FItems[0];
end;

class function TBsonValue.NewDateTime(AValue: TDateTime): TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.DateTime);
  Result.FDateTime := AValue;
end;

class function TBsonValue.NewDocument: TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.Doc);
end;

class function TBsonValue.NewArray: TBsonValue;
begin
  Result := TBsonValue.Create(TBsonKind.Arr);
end;

function TBsonValue.GetCount: Integer;
begin
  if FItems = nil then Exit(0);
  Result := Integer(FItems.Count);
end;

function TBsonValue.GetItem(AIndex: Integer): TBsonValue;
begin
  Result := FItems[AIndex];
end;

function TBsonValue.GetName(AIndex: Integer): string;
begin
  Result := FNames[AIndex];
end;

procedure TBsonValue.Add(const AName: string; AValue: TBsonValue);
begin
  if FItems = nil then
  begin
    AValue.Free;
    raise EBsonInternalError.Create(
      'Only a document or an array can hold elements.');
  end;
  FItems.Add(AValue);
  FNames.Add(AName);
end;

procedure TBsonValue.Add(AValue: TBsonValue);
begin
  if FItems = nil then
  begin
    AValue.Free;
    raise EBsonInternalError.Create(
      'Only a document or an array can hold elements.');
  end;
  FNames.Add(IntToStr(FItems.Count));
  FItems.Add(AValue);
end;

function TBsonValue.Find(const AName: string): TBsonValue;
var
  I: Integer;
begin
  if FNames = nil then Exit(nil);
  for I := 0 to FNames.Count - 1 do
    if FNames[I] = AName then Exit(FItems[I]);
  Result := nil;
end;

function TBsonValue.AsBool: Boolean;
begin
  case FKind of
    TBsonKind.Bool: Result := FBool;
    TBsonKind.Int32, TBsonKind.Int64: Result := FInt <> 0;
  else
    raise EBsonInputError.CreateFmt('Expected a boolean, found %s.',
      [Describe]);
  end;
end;

function TBsonValue.AsInt64: System.Int64;
begin
  case FKind of
    TBsonKind.Int32, TBsonKind.Int64: Result := FInt;
    { A double is accepted only when it is exactly an integer, so nothing is
      rounded away without saying so. }
    TBsonKind.Double:
      begin
        { Out of range first: Trunc of 1e19, an infinity or a NaN raised the
          RTL's EInvalidOp rather than a BSON error. }
        if not BsonDoubleInInt64Range(FFloat) then
          raise EBsonInputError.CreateFmt(
            'Expected an integer, found the double %g, which is outside the ' +
            'Int64 range.', [FFloat]);
        Result := Trunc(FFloat);
        if Result <> FFloat then
          raise EBsonInputError.CreateFmt(
            'Expected an integer, found the non-integral double %g.', [FFloat]);
      end;
  else
    raise EBsonInputError.CreateFmt('Expected an integer, found %s.',
      [Describe]);
  end;
end;

function TBsonValue.AsDouble: System.Double;
begin
  case FKind of
    TBsonKind.Double: Result := FFloat;
    TBsonKind.Int32, TBsonKind.Int64: Result := FInt;
  else
    raise EBsonInputError.CreateFmt('Expected a number, found %s.', [Describe]);
  end;
end;

function TBsonValue.AsString: string;
begin
  { A symbol IS a string - the specification's own words are that it is
    deprecated in favour of one - so reading it as text is right. Everything
    else raises rather than stringifying itself. }
  if not (FKind in [TBsonKind.Str, TBsonKind.Symbol]) then
    raise EBsonInputError.CreateFmt('Expected a string, found %s.', [Describe]);
  Result := FStr;
end;

function TBsonValue.AsBytes: TBytes;
begin
  { Binary is the obvious one. The other three are the element types whose
    payload IS a fixed run of bytes - twelve for an ObjectId and a
    DBPointer's id, sixteen for a decimal128 - and a caller that wants those
    bytes should not have to go through a typed accessor that re-packs
    them. }
  if not (FKind in [TBsonKind.Binary, TBsonKind.ObjectId,
                    TBsonKind.Decimal128, TBsonKind.DbPointer]) then
    raise EBsonInputError.CreateFmt('Expected binary, found %s.', [Describe]);
  Result := FBytes;
end;

function TBsonValue.AsDateTime: TDateTime;
begin
  if FKind <> TBsonKind.DateTime then
    raise EBsonInputError.CreateFmt('Expected a datetime, found %s.',
      [Describe]);
  Result := FDateTime;
end;

function TBsonValue.Describe: string;
begin
  case FKind of
    TBsonKind.Null: Result := 'null';
    TBsonKind.Bool: Result := 'a boolean';
    TBsonKind.Int32: Result := 'an int32';
    TBsonKind.Int64: Result := 'an int64';
    TBsonKind.Double: Result := 'a double';
    TBsonKind.Str: Result := 'a string';
    TBsonKind.Binary: Result := 'binary';
    TBsonKind.DateTime: Result := 'a datetime';
    TBsonKind.Doc: Result := Format('a document of %d elements', [Count]);
    TBsonKind.Arr: Result := Format('an array of %d elements', [Count]);
    TBsonKind.ObjectId: Result := 'an ObjectId';
    TBsonKind.Timestamp: Result := 'a BSON timestamp';
    TBsonKind.Decimal128: Result := 'a decimal128';
    TBsonKind.Regex: Result := 'a regular expression';
    TBsonKind.JavaScript: Result := 'JavaScript code';
    TBsonKind.JavaScriptScope: Result := 'JavaScript code with scope';
    TBsonKind.Symbol: Result := 'a symbol';
    TBsonKind.Undefined: Result := 'undefined';
    TBsonKind.DbPointer: Result := 'a DBPointer';
    TBsonKind.MinKey: Result := 'MinKey';
    TBsonKind.MaxKey: Result := 'MaxKey';
  else
    Result := 'an unknown value';
  end;
end;

{ ------------------------------------------------------------- attributes --- }

constructor BsonNameAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

constructor BsonDateTimeRepresentationAttribute.Create(
  ARepresentation: TBsonDateTimeRepresentation);
begin
  inherited Create;
  FRepresentation := ARepresentation;
  FPattern := '';
end;

constructor BsonDateTimeRepresentationAttribute.Create(const APattern: string);
begin
  inherited Create;
  FRepresentation := TBsonDateTimeRepresentation.CustomString;
  FPattern := APattern;
end;

constructor BsonGuidRepresentationAttribute.Create(
  ARepresentation: TBsonGuidRepresentation);
begin
  inherited Create;
  FRepresentation := ARepresentation;
end;

constructor BsonCurrencyRepresentationAttribute.Create(
  ARepresentation: TBsonCurrencyRepresentation);
begin
  inherited Create;
  FRepresentation := ARepresentation;
end;

constructor BsonSerializerAttribute.Create(
  ASerializerClass: TBsonValueSerializerClass);
begin
  inherited Create;
  FSerializerClass := ASerializerClass;
end;

{ ------------------------------------------------- typed custom serializer --- }

function TCustomBsonValueSerializer<T>.Serialize(
  const AValue: TValue): TBsonValue;
begin
  Result := SerializeValue(AValue.AsType<T>);
end;

function TCustomBsonValueSerializer<T>.Deserialize(AValue: TBsonValue;
  ATypeInfo: PTypeInfo; const AExisting: TValue): TValue;
var
  Existing: T;
begin
  if AExisting.IsEmpty then Existing := Default(T)
  else Existing := AExisting.AsType<T>;
  Result := TValue.From<T>(DeserializeValue(AValue, Existing));
end;

{ ------------------------------------------------------------- bridges --- }

class function TBsonSerializer.DoSerialize(ATypeInfo: PTypeInfo;
  const AValue: TValue): TBytes;
begin
  Result := TBsonEngine.SerializeRoot(ATypeInfo, AValue);
end;

class function TBsonSerializer.DoDeserialize(ATypeInfo: PTypeInfo;
  const AData: TBytes): TValue;
begin
  Result := TBsonEngine.DeserializeRoot(ATypeInfo, AData, TValue.Empty);
end;

class procedure TBsonSerializer.DoPopulate(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AData: TBytes);
begin
  TBsonEngine.DeserializeRoot(ATypeInfo, AData, AValue);
end;

class function TBsonSerializer.DoFrom(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload; AFrom: TSerializationFormat): TBytes;
begin
  Result := TBsonEngine.FromPayload(ATypeInfo, ASource, AFrom);
end;

class procedure TBsonSerializer.DoSetDateTimePolicy(ATypeInfo: PTypeInfo;
  const AFieldName: string; ARepresentation: TBsonDateTimeRepresentation;
  const APattern: string);
begin
  TBsonEngine.SetDateTimePolicy(ATypeInfo, AFieldName, Ord(ARepresentation),
    APattern);
end;

class procedure TBsonSerializer.DoRegisterEnumMapping(ATypeInfo: PTypeInfo;
  const AValues: array of string);
begin
  TBsonEngine.RegisterEnumMapping(ATypeInfo, AValues);
end;

class procedure TBsonSerializer.DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TBsonValueSerializerClass);
begin
  TBsonEngine.RegisterTypeSerializer(ATypeInfo, ASerializerClass);
end;

{ ------------------------------------------------------------ operations --- }

class function TBsonSerializer.Serialize<T>(const AValue: T): TBytes;
var
  V: TValue;
begin
  TValue.Make(@AValue, System.TypeInfo(T), V);
  Result := DoSerialize(System.TypeInfo(T), V);
end;

class function TBsonSerializer.Deserialize<T>(const AData: TBytes): T;
begin
  Result := DoDeserialize(System.TypeInfo(T), AData).AsType<T>;
end;

class procedure TBsonSerializer.Populate<T>(const AInstance: T;
  const AData: TBytes);
var
  V: TValue;
begin
  TValue.Make(@AInstance, System.TypeInfo(T), V);
  DoPopulate(System.TypeInfo(T), V, AData);
end;

class function TBsonSerializer.From(const ASource: string;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From(TSerializationPayload.FromText(ASource), AFrom);
end;

class function TBsonSerializer.From(const ASource: TBytes;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From(TSerializationPayload.FromBytes(ASource), AFrom);
end;

class function TBsonSerializer.From(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From(ASource, AFrom, TStructuralConversionProfile.Natural);
end;

class function TBsonSerializer.From(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat;
  AProfile: TStructuralConversionProfile): TBytes;
begin
  Result := TBsonEngine.FromPayloadStructural(ASource, AFrom, AProfile);
end;

class function TBsonSerializer.From<T>(const ASource: string;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From<T>(TSerializationPayload.FromText(ASource), AFrom);
end;

class function TBsonSerializer.From<T>(const ASource: TBytes;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From<T>(TSerializationPayload.FromBytes(ASource), AFrom);
end;

class function TBsonSerializer.From<T>(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := DoFrom(System.TypeInfo(T), ASource, AFrom);
end;

{ ---------------------------------------------------------- date and time --- }

class procedure TBsonSerializer.SetDateTimeRepresentation(
  ARepresentation: TBsonDateTimeRepresentation);
begin
  TBsonEngine.SetDateTimePolicy(nil, '', Ord(ARepresentation), '');
end;

class procedure TBsonSerializer.SetDateTimeRepresentation(
  const APattern: string);
begin
  TBsonEngine.SetDateTimePolicy(nil, '',
    Ord(TBsonDateTimeRepresentation.CustomString), APattern);
end;

class procedure TBsonSerializer.RegisterDateTimeRepresentation<T>(
  ARepresentation: TBsonDateTimeRepresentation);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), '', ARepresentation, '');
end;

class procedure TBsonSerializer.RegisterDateTimeRepresentation<T>(
  const APattern: string);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), '',
    TBsonDateTimeRepresentation.CustomString, APattern);
end;

class procedure TBsonSerializer.RegisterFieldDateTimeRepresentation<T>(
  const AFieldName: string; ARepresentation: TBsonDateTimeRepresentation);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), AFieldName, ARepresentation, '');
end;

class procedure TBsonSerializer.RegisterFieldDateTimeRepresentation<T>(
  const AFieldName, APattern: string);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), AFieldName,
    TBsonDateTimeRepresentation.CustomString, APattern);
end;

{ -------------------------------------------------------- registrations --- }

class procedure TBsonSerializer.RegisterEnumMapping<T>(
  const AValues: array of string);
begin
  DoRegisterEnumMapping(System.TypeInfo(T), AValues);
end;

class procedure TBsonSerializer.RegisterTypeSerializer<T>(
  ASerializerClass: TBsonValueSerializerClass);
begin
  DoRegisterTypeSerializer(System.TypeInfo(T), ASerializerClass);
end;

class procedure TBsonSerializer.FreezeConfiguration;
begin
  TBsonEngine.FreezeConfiguration;
end;

class function TBsonSerializer.IsFrozen: Boolean;
begin
  Result := TBsonEngine.IsFrozen;
end;

class procedure TBsonSerializer.ResetConfiguration;
begin
  TBsonEngine.ResetConfiguration;
end;


{ ------------------------------------------------ BSON and JSON, three ways }

class function TBsonSerializer.ParseDocument(const AData: TBytes): TBsonValue;
begin
  Result := TBsonEngine.ParseDocument(AData);
end;

class function TBsonSerializer.WriteDocument(ADocument: TBsonValue): TBytes;
begin
  Result := TBsonEngine.WriteDocument(ADocument);
end;

class function TBsonSerializer.ToJson(const AData: TBytes): string;
begin
  Result := TBsonEngine.DocumentToJson(AData,
    TStructuralConversionProfile.Natural);
end;

class function TBsonSerializer.ToJsonWithSchema(const AData: TBytes;
  out ASchema: string): string;
begin
  Result := TBsonEngine.DocumentToJsonWithSchema(AData, ASchema);
end;

class function TBsonSerializer.ToExtendedJson(const AData: TBytes): string;
begin
  Result := TBsonEngine.DocumentToJson(AData,
    TStructuralConversionProfile.Lossless);
end;

class function TBsonSerializer.FromJson(const AJson: string): TBytes;
begin
  Result := TBsonEngine.JsonToDocument(AJson,
    TStructuralConversionProfile.Natural);
end;

class function TBsonSerializer.FromJson(const AJson, ASchema: string): TBytes;
begin
  Result := TBsonEngine.JsonToDocumentWithSchema(AJson, ASchema);
end;

class function TBsonSerializer.FromExtendedJson(const AJson: string): TBytes;
begin
  Result := TBsonEngine.JsonToDocument(AJson,
    TStructuralConversionProfile.Lossless);
end;


{ ---------------------------------------------------------------- dynamic --- }

class function TBsonSerializer.ToDynamic(const ABson: TBytes): TDynamicValue;
var
  Doc: TBsonValue;
begin
  Doc := TBsonEngine.ParseDocument(ABson);
  try
    Result := TBsonEngine.BsonToDynamic(Doc);
  finally
    Doc.Free;
  end;
end;

class function TBsonSerializer.FromDynamic(AValue: TDynamicValue): TBytes;
var
  Doc, Wrapped: TBsonValue;
begin
  { No policy applies: BSON's types cover every dynamic kind and a BSON
    member name is an arbitrary string. }
  Doc := TBsonEngine.DynamicToBson(AValue);
  try
    if Doc.Kind <> TBsonKind.Doc then
    begin
      Wrapped := TBsonValue.NewDocument;
      Wrapped.Add('value', Doc);
      Doc := Wrapped;
    end;
    Result := TBsonEngine.WriteDocument(Doc);
  finally
    Doc.Free;
  end;
end;

end.
