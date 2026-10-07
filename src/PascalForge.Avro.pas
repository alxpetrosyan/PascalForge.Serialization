{*******************************************************************************
  PascalForge.Avro

  Public Apache Avro serialization facade for PascalForge.Serialization.

  Responsibilities
    - Typed Avro serialization/deserialization (TBytes) with schema
      generation from Delphi types.
    - Writer/reader schema resolution and object container files.
    - Avro-specific options and customization API.

  Registration
    Direct TAvroSerializer use does not require format registration.
    Generic TSerialization operations require explicit registration:
    TAvroSerializationRegistration.RegisterFormat (PascalForge.Avro.Registration).

  Configuration
    Global serializer configuration becomes immutable after first use.

  Threading
    Serialization is safe for concurrent use after configuration is frozen.

  Documentation
    docs/formats/avro.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Avro;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  APACHE AVRO serialization.

  Target: Apache Avro specification 1.12.0.

      Schema := TAvroSerializer.SchemaFor<TShipment>;   // caller owns it
      Data   := TAvroSerializer.Serialize<TShipment>(Shipment);   // TBytes
      Shipment := TAvroSerializer.Deserialize<TShipment>(Data);

  Avro is binary, so its natural Delphi type is TBytes and that is what this
  unit returns.

  AVRO IS SCHEMA-DRIVEN, AND THAT IS NOT A DETAIL. An Avro datum carries no
  type information at all - no tags, no field names, no lengths except the
  ones the types themselves imply - so the same five bytes are a record, a
  pair of longs or a string depending entirely on the schema you read them
  with. Everything in this unit therefore takes a schema, and the two places
  where one might be missing say so rather than improvising:

    * structural conversion without a schema in the options raises
      ESerializationSchemaRequired;
    * contract-aware serialization GENERATES the schema from the Delphi type
      and hands it back, so the caller can publish it beside the bytes.

  WRITER AND READER SCHEMAS ARE BOTH FIRST CLASS. Data written with one
  schema is read with another - that is the whole point of Avro's schema
  evolution - so Decode takes both and applies the specification's Schema
  Resolution rules: numeric promotion, defaults for fields the writer did not
  have, skipping fields the reader does not want, aliases for renamed records
  and fields, branch-wise union resolution and the enum default.

  PROFILE, stated plainly rather than implied.

    IN     the datum (single-datum) binary encoding, in both directions;
           object container files, in both directions, with the "null" and
           "deflate" codecs;
           the schema language, including named-type references, aliases,
           field defaults and logical types;
           the Parsing Canonical Form and the 64-bit Rabin fingerprint.

    OUT    the "snappy", "bzip2", "xz" and "zstandard" container codecs, each
           of which needs a compressor this library will not take a
           dependency on. A container file using one is detected and named,
           never silently mis-read.
           The JSON encoding of data (as distinct from the JSON schema
           language, which is fully implemented): it is a diagnostic
           representation, and nothing here produces or consumes it.
           RPC - protocols, messages, handshakes - which is a separate
           specification layered on this one.
           Single-object encoding and the schema-registry framings;
           the fingerprint they are built from is here, the framing is not.

  Using this unit needs no registration. PascalForge.Avro.Registration exists
  only for code that picks a format at run time.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Avro.Schema;

type
  EAvroError = class(Exception);
  { The bytes, or the datum, are at fault. }
  EAvroInputError = class(EAvroError);
  { The Delphi model or the configuration is at fault. }
  EAvroInternalError = class(EAvroError);
  { The writer's schema and the reader's cannot be reconciled by the
    specification's resolution rules. This is its own class because it is the
    one failure a caller can usually fix by changing a schema rather than by
    changing data. }
  EAvroResolutionError = class(EAvroInputError);

{ ===========================================================================
  THE DATUM MODEL

  A decoded Avro value. It exists for the same reason TBsonValue does: a
  custom serializer needs somewhere to write, and decoding needs somewhere to
  put what it found before a Delphi contract is applied.

  It is NOT self-describing in the way a BSON document is, and it does not
  pretend to be: an Int and a Long here are two kinds because the schema that
  produced them said so, not because the bytes did.

  Three kinds are not Avro types but Avro LOGICAL types, and they are here
  because the alternative is worse. A decimal held as a Double is destroyed
  silently, which is the failure this library exists to prevent; a timestamp
  held as a bare Int64 is unreadable; a duration is three unsigned numbers
  that are not a count of anything on their own.
  =========================================================================== }

type
  TAvroKind = (
    Null, Bool, Int, Long, Float, Double, Bytes, Str,
    Rec, Enum, Arr, Map, Fixed,
    { bytes or fixed with logicalType "decimal", as exact decimal text }
    Decimal,
    { int or long with one of the date/time/timestamp logical types }
    DateTime,
    { fixed of size 12 with logicalType "duration" }
    Duration);

  TAvroValue = class
  strict private
    FKind: TAvroKind;
    FBool: Boolean;
    FInt: Int64;
    FFloat: System.Double;
    FStr: string;
    FBytes: TBytes;
    FDateTime: TDateTime;
    FLogical: TAvroLogicalType;
    FMonths: Cardinal;
    FDays: Cardinal;
    FMillis: Cardinal;
    FItems: TObjectList<TAvroValue>;
    FNames: TStringList;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TAvroValue;
    function GetName(AIndex: Integer): string;
  public
    constructor Create(AKind: TAvroKind);
    destructor Destroy; override;

    class function NewNull: TAvroValue; static;
    class function NewBool(AValue: Boolean): TAvroValue; static;
    { int and long are distinct types with distinct encodings, so they are
      distinct here. Handing a Long to an "int" schema is an error rather
      than a silent narrowing. }
    class function NewInt(AValue: Integer): TAvroValue; static;
    class function NewLong(AValue: Int64): TAvroValue; static;
    class function NewFloat(AValue: Single): TAvroValue; static;
    class function NewDouble(AValue: System.Double): TAvroValue; static;
    class function NewBytes(const AValue: TBytes): TAvroValue; static;
    class function NewStr(const AValue: string): TAvroValue; static;
    class function NewEnum(const ASymbol: string): TAvroValue; static;
    class function NewFixed(const AValue: TBytes): TAvroValue; static;
    class function NewRecord: TAvroValue; static;
    class function NewArray: TAvroValue; static;
    class function NewMap: TAvroValue; static;
    { The canonical decimal text - an optional sign, digits, an optional
      point. Exact at any precision, which a Double is not. }
    class function NewDecimal(const ADigits: string): TAvroValue; static;
    { A logical date, time or timestamp. The logical type is taken from the
      schema when this is encoded. }
    class function NewDateTime(AValue: TDateTime): TAvroValue; static;
    { The same, carrying the EXACT underlying integer as the writer wrote it.
      This is what the decoder produces, and it is why a timestamp-micros
      value re-encodes to the same bytes it came from even though a TDateTime
      resolves to the millisecond. }
    class function NewExactDateTime(AValue: TDateTime;
      ALogical: TAvroLogicalType; ARaw: Int64): TAvroValue; static;
    class function NewDuration(AMonths, ADays, AMillis: Cardinal): TAvroValue; static;

    { Adopts AValue. }
    procedure Add(AValue: TAvroValue); overload;
    procedure Add(const AName: string; AValue: TAvroValue); overload;
    function Find(const AName: string): TAvroValue;

    function AsBool: Boolean;
    { int, long, and a date/time whose raw units are wanted rather than its
      TDateTime. }
    function AsInt: Int64;
    function AsFloat: System.Double;
    function AsStr: string;
    function AsBytes: TBytes;
    function AsDateTime: TDateTime;
    function AsDecimal: string;
    function Describe: string;
    function Clone: TAvroValue;

    property Kind: TAvroKind read FKind;
    { For DateTime: which logical type the value came from, or None when it
      was built from a bare TDateTime and the schema will decide. }
    property LogicalType: TAvroLogicalType read FLogical;
    { For DateTime: the underlying int or long, in the logical type's own
      units. Meaningless when LogicalType is None. }
    property RawValue: Int64 read FInt;
    property DurationMonths: Cardinal read FMonths;
    property DurationDays: Cardinal read FDays;
    property DurationMillis: Cardinal read FMillis;
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TAvroValue read GetItem; default;
    { Record field names and map keys, in order. }
    property Names[AIndex: Integer]: string read GetName;
  end;

{ ===========================================================================
  OBJECT CONTAINER FILES
  =========================================================================== }

  { Per-call limits for reading an object container file.

    MaxInflatedBlockBytes bounds what ONE compressed data block may inflate
    to. It is enforced WHILE inflating, a 64 KB chunk at a time, so a small
    hostile block stops at the budget instead of making the reader allocate
    whatever its compressed form claims. Exceeding it raises EAvroInputError.
    The default, 64 MiB, is far above any real block (writers flush blocks
    of tens of kilobytes to a few megabytes) and far below what an
    in-memory reader should be made to allocate by a few kilobytes of input.
    Raise it for a known producer that writes larger blocks. It must be
    positive: WithMaxInflatedBlockBytes and every read refuse zero or a
    negative value with EAvroError - so must a TAvroReadOptions declared
    without Default, whose field is not initialized. A default write never
    makes a block past the default (see TAvroSerializer.WriteContainer). }
  TAvroReadOptions = record
  public const
    DefaultMaxInflatedBlockBytes = 64 * 1024 * 1024;
  public
    MaxInflatedBlockBytes: Integer;
    class function Default: TAvroReadOptions; static;
    function WithMaxInflatedBlockBytes(ABytes: Integer): TAvroReadOptions;
    { Raises EAvroError unless MaxInflatedBlockBytes is positive. Every read
      that takes options calls it. }
    procedure Validate;
  end;

  { The codecs this implementation writes and reads. Every other codec the
    specification names is refused BY NAME on reading rather than
    mis-decoded - see the profile at the top of this unit. }
  TAvroCodec = (
    { The specification's required codec, and the only one every reader has. }
    Null,
    { RFC 1951 raw deflate, through System.ZLib. }
    Deflate);

{ ===========================================================================
  ATTRIBUTES - Avro's own, and only Avro's.
  =========================================================================== }

type
  AvroNameAttribute = class(TCustomAttribute)
  strict private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

  AvroIgnoreAttribute = class(TCustomAttribute)
  end;

  { Aliases, for reading data written before a rename.

    One comma-separated string rather than an open array, because a Delphi
    attribute argument must be a constant expression and an open array of
    strings is not reliably one across the compilers this library targets.

        [AvroAliases('emailAddress, email_address')]
        Email: string;

    On a class or record the aliases are the RECORD's, and they are
    namespace-qualified against the record's own namespace when written
    unqualified. On a member they are the FIELD's, and field aliases are
    plain names - the specification does not namespace them. }
  AvroAliasesAttribute = class(TCustomAttribute)
  strict private
    FAliases: string;
  public
    constructor Create(const AAliases: string);
    function Names: TArray<string>;
    property Aliases: string read FAliases;
  end;

{ ===========================================================================
  CUSTOM SERIALIZERS - Avro's, not JSON's.

  An Avro custom serializer has to supply a SCHEMA as well as a value, because
  without one the bytes it produces cannot be read by anybody, including this
  library. SchemaJson returns the schema of whatever SerializeValue writes.
  =========================================================================== }

type
  TCustomAvroValueSerializer = class
  public
    { The Avro schema, as JSON, of the datum this serializer produces. It is
      parsed once and spliced into the schema generated for the owning
      type. }
    class function SchemaJson: string; virtual; abstract;
    { Returns the datum for AValue. The caller adopts it. }
    function Serialize(const AValue: TValue): TAvroValue; virtual; abstract;
    function Deserialize(AValue: TAvroValue; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; virtual; abstract;
  end;

  TAvroValueSerializerClass = class of TCustomAvroValueSerializer;

  { The typed base, and the one to use: it names the Delphi type, so an
    implementation never touches TValue or PTypeInfo. }
  TCustomAvroValueSerializer<T> = class(TCustomAvroValueSerializer)
  public
    function SerializeValue(const AValue: T): TAvroValue; virtual; abstract;
    function DeserializeValue(AValue: TAvroValue; const AExisting: T): T; virtual; abstract;

    function Serialize(const AValue: TValue): TAvroValue; override; final;
    function Deserialize(AValue: TAvroValue; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; override; final;
  end;

  AvroSerializerAttribute = class(TCustomAttribute)
  strict private
    FSerializerClass: TAvroValueSerializerClass;
  public
    constructor Create(ASerializerClass: TAvroValueSerializerClass);
    property SerializerClass: TAvroValueSerializerClass read FSerializerClass;
  end;

{ =========================================================================== }

type
  TAvroSerializer = class
  strict private
    { A generic method body declared in an interface section may reference
      only interface-declared symbols, so every generic entry point below is
      a thin shell over one of these. }
    class function DoSchemaJson(ATypeInfo: PTypeInfo): string; static;
    class function DoSerialize(ATypeInfo: PTypeInfo;
      const AValue: TValue): TBytes; static;
    class function DoDeserialize(ATypeInfo: PTypeInfo; const AData: TBytes;
      const AExisting: TValue): TValue; static;
    class function DoFrom(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; static;
    class procedure DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TAvroValueSerializerClass); static;
    class procedure DoRegisterEnumMapping(ATypeInfo: PTypeInfo;
      const ASymbols: array of string); static;
  public
    { --- the schema -------------------------------------------------------

      The Avro schema of T, derived from its RTTI and from Avro's own
      attributes. The caller OWNS the returned schema and frees it; it is a
      fresh tree each time, because a schema is a mutable object and handing
      out a shared one would let any caller's edit reach every other. }
    class function SchemaFor<T>: TAvroSchema; static;
    class function SchemaJsonFor<T>: string; static;

    { --- contract-aware ---------------------------------------------------

      Both directions use the schema generated for T, as writer and as
      reader. To read bytes written with a DIFFERENT schema, decode them with
      Decode and the two schemas, or use DeserializeWith below. }
    class function Serialize<T>(const AValue: T): TBytes; static;
    class function Deserialize<T>(const AData: TBytes): T; static;
    class procedure Populate<T>(const AInstance: T; const AData: TBytes); static;
    { Reads AData, which was written with AWriter, into T - resolving the
      writer's schema against the one generated for T. }
    class function DeserializeWith<T>(const AData: TBytes;
      AWriter: TAvroSchema): T; static;

    { --- the datum level --------------------------------------------------

      No Delphi type involved: a schema and a datum, which is what an Avro
      implementation fundamentally is. }
    class function Encode(ASchema: TAvroSchema; AValue: TAvroValue): TBytes; static;
    { Reads with one schema, which is the case where writer and reader are
      the same. The caller owns the result. }
    class function Decode(const ABytes: TBytes;
      AWriter: TAvroSchema): TAvroValue; overload; static;
    { Reads bytes written with AWriter as if they had been written with
      AReader, applying the specification's Schema Resolution rules. }
    class function Decode(const ABytes: TBytes;
      AWriter, AReader: TAvroSchema): TAvroValue; overload; static;

    { --- object container files -------------------------------------------

      A whole file in memory: the magic, the metadata map carrying
      avro.schema and avro.codec, a sync marker derived from the schema fingerprint, and the data as
      blocks of (count, size, data, sync). A block is flushed at about
      1 MiB, or holds one larger datum alone, so a default read opens every
      default write. Under TAvroCodec.Deflate a datum that encodes past
      TAvroReadOptions.DefaultMaxInflatedBlockBytes raises EAvroError. }
    class function WriteContainer(ASchema: TAvroSchema;
      const AValues: array of TAvroValue;
      ACodec: TAvroCodec = TAvroCodec.Null): TBytes; overload; static;
    { The datums of a container file. AWriterSchemaJson receives the schema
      the file itself carries, which is the only schema that can read it. The
      caller owns the list and everything in it. }
    class function ReadContainer(const AData: TBytes;
      out AWriterSchemaJson: string): TObjectList<TAvroValue>; overload; static;
    { The same, resolved against AReader. }
    class function ReadContainer(const AData: TBytes; AReader: TAvroSchema;
      out AWriterSchemaJson: string): TObjectList<TAvroValue>; overload; static;
    { The same, with explicit read limits (see TAvroReadOptions). The
      overloads without options use TAvroReadOptions.Default. }
    class function ReadContainer(const AData: TBytes; AReader: TAvroSchema;
      const AOptions: TAvroReadOptions;
      out AWriterSchemaJson: string): TObjectList<TAvroValue>; overload; static;
    { Every datum of a container file, as instances of T. }
    class function ReadContainer<T>(const AData: TBytes): TArray<T>; overload; static;
    class function ReadContainer<T>(const AData: TBytes;
      const AOptions: TAvroReadOptions): TArray<T>; overload; static;
    class function WriteContainer<T>(const AValues: array of T;
      ACodec: TAvroCodec = TAvroCodec.Null): TBytes; overload; static;

    { --- destination-oriented conversion -----------------------------------

      Avro is the destination and is known at compile time, so only the
      SOURCE format is looked up, through the registry. This unit has no
      compile-time dependency on any other format.

      The generic form is CONTRACT-AWARE: the source deserializes into T by
      its own rules and Avro writes T by its own. There is no non-generic
      structural form, because a structural Avro payload needs a schema and
      this signature has nowhere to put one - use the registry handler and
      TStructuralConversionOptions for that. }
    class function From<T>(const ASource: string;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From<T>(const ASource: TBytes;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From<T>(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; overload; static;

    { --- registrations ----------------------------------------------------- }

    class procedure RegisterTypeSerializer<T>(
      ASerializerClass: TAvroValueSerializerClass); static;
    { The Avro enum symbols for a Delphi enumeration whose identifiers are
      not the names the schema should carry. Avro symbols must be legal Avro
      names, which is stricter than Delphi: this is how a Delphi enumeration
      with an unrepresentable spelling gets one that works. }
    class procedure RegisterEnumMapping<T>(const ASymbols: array of string); static;

    { --- configuration lifecycle ------------------------------------------- }
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;

    { --- dynamic ---------------------------------------------------------

      A bare datum as a dynamic value, and back. Avro bytes are meaningless
      without the schema they were written with, so it is required: AWriter
      is that schema, and AReader, when given, the one the datum is
      resolved into on the way. The tree is the caller's. }
    class function ToDynamic(const AData: TBytes; AWriter: TAvroSchema;
      AReader: TAvroSchema = nil): TDynamicValue; static;
    class function FromDynamic(AValue: TDynamicValue;
      ASchema: TAvroSchema): TBytes; overload; static;
    class function FromDynamic(AValue: TDynamicValue; ASchema: TAvroSchema;
      const AOptions: TStructuralConversionOptions): TBytes; overload; static;
    class procedure ResetConfiguration; static;
  end;

implementation

uses
  PascalForge.Avro.Internal;

{ ------------------------------------------------------------- TAvroValue --- }

constructor TAvroValue.Create(AKind: TAvroKind);
begin
  inherited Create;
  FKind := AKind;
  FLogical := TAvroLogicalType.None;
  if AKind in [TAvroKind.Rec, TAvroKind.Arr, TAvroKind.Map] then
  begin
    FItems := TObjectList<TAvroValue>.Create(True);
    FNames := TStringList.Create;
    FNames.CaseSensitive := True;
  end;
end;

destructor TAvroValue.Destroy;
begin
  FNames.Free;
  FItems.Free;
  inherited Destroy;
end;

class function TAvroValue.NewNull: TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Null);
end;

class function TAvroValue.NewBool(AValue: Boolean): TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Bool);
  Result.FBool := AValue;
end;

class function TAvroValue.NewInt(AValue: Integer): TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Int);
  Result.FInt := AValue;
end;

class function TAvroValue.NewLong(AValue: Int64): TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Long);
  Result.FInt := AValue;
end;

class function TAvroValue.NewFloat(AValue: Single): TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Float);
  Result.FFloat := AValue;
end;

class function TAvroValue.NewDouble(AValue: System.Double): TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Double);
  Result.FFloat := AValue;
end;

class function TAvroValue.NewBytes(const AValue: TBytes): TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Bytes);
  Result.FBytes := AValue;
end;

class function TAvroValue.NewStr(const AValue: string): TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Str);
  Result.FStr := AValue;
end;

class function TAvroValue.NewEnum(const ASymbol: string): TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Enum);
  Result.FStr := ASymbol;
end;

class function TAvroValue.NewFixed(const AValue: TBytes): TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Fixed);
  Result.FBytes := AValue;
end;

class function TAvroValue.NewRecord: TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Rec);
end;

class function TAvroValue.NewArray: TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Arr);
end;

class function TAvroValue.NewMap: TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Map);
end;

class function TAvroValue.NewDecimal(const ADigits: string): TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Decimal);
  Result.FStr := ADigits;
end;

class function TAvroValue.NewDateTime(AValue: TDateTime): TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.DateTime);
  Result.FDateTime := AValue;
end;

class function TAvroValue.NewExactDateTime(AValue: TDateTime;
  ALogical: TAvroLogicalType; ARaw: Int64): TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.DateTime);
  Result.FDateTime := AValue;
  Result.FLogical := ALogical;
  Result.FInt := ARaw;
end;

class function TAvroValue.NewDuration(AMonths, ADays,
  AMillis: Cardinal): TAvroValue;
begin
  Result := TAvroValue.Create(TAvroKind.Duration);
  Result.FMonths := AMonths;
  Result.FDays := ADays;
  Result.FMillis := AMillis;
end;

function TAvroValue.GetCount: Integer;
begin
  if FItems = nil then Result := 0 else Result := Integer(FItems.Count);
end;

function TAvroValue.GetItem(AIndex: Integer): TAvroValue;
begin
  if FItems = nil then
    raise EAvroInternalError.CreateFmt('%s has no elements.', [Describe]);
  Result := FItems[AIndex];
end;

function TAvroValue.GetName(AIndex: Integer): string;
begin
  if FNames = nil then
    raise EAvroInternalError.CreateFmt('%s has no names.', [Describe]);
  Result := FNames[AIndex];
end;

procedure TAvroValue.Add(AValue: TAvroValue);
begin
  if FKind <> TAvroKind.Arr then
  begin
    AValue.Free;
    raise EAvroInternalError.Create('Only an array takes an unnamed element.');
  end;
  FNames.Add(IntToStr(FItems.Count));
  FItems.Add(AValue);
end;

procedure TAvroValue.Add(const AName: string; AValue: TAvroValue);
begin
  if not (FKind in [TAvroKind.Rec, TAvroKind.Map]) then
  begin
    AValue.Free;
    raise EAvroInternalError.Create(
      'Only a record or a map takes a named element.');
  end;
  FItems.Add(AValue);
  FNames.Add(AName);
end;

function TAvroValue.Find(const AName: string): TAvroValue;
var
  I: Integer;
begin
  if FNames <> nil then
    for I := 0 to FNames.Count - 1 do
      if FNames[I] = AName then Exit(FItems[I]);
  Result := nil;
end;

function TAvroValue.AsBool: Boolean;
begin
  if FKind <> TAvroKind.Bool then
    raise EAvroInputError.CreateFmt('Expected a boolean, found %s.', [Describe]);
  Result := FBool;
end;

function TAvroValue.AsInt: Int64;
begin
  case FKind of
    TAvroKind.Int, TAvroKind.Long, TAvroKind.DateTime: Result := FInt;
  else
    raise EAvroInputError.CreateFmt('Expected an integer, found %s.', [Describe]);
  end;
end;

function TAvroValue.AsFloat: System.Double;
begin
  case FKind of
    TAvroKind.Float, TAvroKind.Double: Result := FFloat;
    TAvroKind.Int, TAvroKind.Long: Result := FInt;
  else
    raise EAvroInputError.CreateFmt('Expected a number, found %s.', [Describe]);
  end;
end;

function TAvroValue.AsStr: string;
begin
  if not (FKind in [TAvroKind.Str, TAvroKind.Enum, TAvroKind.Decimal]) then
    raise EAvroInputError.CreateFmt('Expected a string, found %s.', [Describe]);
  Result := FStr;
end;

function TAvroValue.AsBytes: TBytes;
begin
  if not (FKind in [TAvroKind.Bytes, TAvroKind.Fixed]) then
    raise EAvroInputError.CreateFmt('Expected bytes, found %s.', [Describe]);
  Result := FBytes;
end;

function TAvroValue.AsDateTime: TDateTime;
begin
  if FKind <> TAvroKind.DateTime then
    raise EAvroInputError.CreateFmt('Expected a date or time, found %s.',
      [Describe]);
  Result := FDateTime;
end;

function TAvroValue.AsDecimal: string;
begin
  if FKind <> TAvroKind.Decimal then
    raise EAvroInputError.CreateFmt('Expected a decimal, found %s.', [Describe]);
  Result := FStr;
end;

function TAvroValue.Describe: string;
begin
  case FKind of
    TAvroKind.Null: Result := 'null';
    TAvroKind.Bool: Result := 'a boolean';
    TAvroKind.Int: Result := 'an int';
    TAvroKind.Long: Result := 'a long';
    TAvroKind.Float: Result := 'a float';
    TAvroKind.Double: Result := 'a double';
    TAvroKind.Bytes: Result := 'bytes';
    TAvroKind.Str: Result := 'a string';
    TAvroKind.Rec: Result := System.SysUtils.Format('a record of %d fields', [Count]);
    TAvroKind.Enum: Result := 'an enum symbol';
    TAvroKind.Arr: Result := System.SysUtils.Format('an array of %d items', [Count]);
    TAvroKind.Map: Result := System.SysUtils.Format('a map of %d entries', [Count]);
    TAvroKind.Fixed: Result := System.SysUtils.Format('a fixed of %d bytes',
      [Length(FBytes)]);
    TAvroKind.Decimal: Result := 'a decimal';
    TAvroKind.DateTime: Result := 'a date or time';
    TAvroKind.Duration: Result := 'a duration';
  else
    Result := 'an unknown value';
  end;
end;

function TAvroValue.Clone: TAvroValue;
var
  I: Integer;
begin
  Result := TAvroValue.Create(FKind);
  try
    Result.FBool := FBool;
    Result.FInt := FInt;
    Result.FFloat := FFloat;
    Result.FStr := FStr;
    Result.FBytes := Copy(FBytes);
    Result.FDateTime := FDateTime;
    Result.FLogical := FLogical;
    Result.FMonths := FMonths;
    Result.FDays := FDays;
    Result.FMillis := FMillis;
    for I := 0 to Count - 1 do
    begin
      Result.FItems.Add(FItems[I].Clone);
      Result.FNames.Add(FNames[I]);
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ ------------------------------------------------------------- attributes --- }

constructor AvroNameAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

constructor AvroAliasesAttribute.Create(const AAliases: string);
begin
  inherited Create;
  FAliases := AAliases;
end;

function AvroAliasesAttribute.Names: TArray<string>;
var
  Parts: TArray<string>;
  I, N: Integer;
begin
  Parts := FAliases.Split([',']);
  SetLength(Result, Length(Parts));
  N := 0;
  for I := 0 to Integer(High(Parts)) do
    if Trim(Parts[I]) <> '' then
    begin
      Result[N] := Trim(Parts[I]);
      Inc(N);
    end;
  SetLength(Result, N);
end;

constructor AvroSerializerAttribute.Create(
  ASerializerClass: TAvroValueSerializerClass);
begin
  inherited Create;
  FSerializerClass := ASerializerClass;
end;

{ ------------------------------------------------- typed custom serializer --- }

function TCustomAvroValueSerializer<T>.Serialize(
  const AValue: TValue): TAvroValue;
begin
  Result := SerializeValue(AValue.AsType<T>);
end;

function TCustomAvroValueSerializer<T>.Deserialize(AValue: TAvroValue;
  ATypeInfo: PTypeInfo; const AExisting: TValue): TValue;
var
  Existing: T;
begin
  if AExisting.IsEmpty then Existing := Default(T)
  else Existing := AExisting.AsType<T>;
  Result := TValue.From<T>(DeserializeValue(AValue, Existing));
end;

{ ---------------------------------------------------------------- bridges --- }

class function TAvroSerializer.DoSchemaJson(ATypeInfo: PTypeInfo): string;
begin
  Result := TAvroEngine.SchemaJsonFor(ATypeInfo);
end;

class function TAvroSerializer.DoSerialize(ATypeInfo: PTypeInfo;
  const AValue: TValue): TBytes;
begin
  Result := TAvroEngine.SerializeRoot(ATypeInfo, AValue);
end;

class function TAvroSerializer.DoDeserialize(ATypeInfo: PTypeInfo;
  const AData: TBytes; const AExisting: TValue): TValue;
begin
  Result := TAvroEngine.DeserializeRoot(ATypeInfo, AData, AExisting);
end;

class function TAvroSerializer.DoFrom(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload; AFrom: TSerializationFormat): TBytes;
begin
  Result := TAvroEngine.FromPayload(ATypeInfo, ASource, AFrom);
end;

class procedure TAvroSerializer.DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TAvroValueSerializerClass);
begin
  TAvroEngine.RegisterTypeSerializer(ATypeInfo, ASerializerClass);
end;

class procedure TAvroSerializer.DoRegisterEnumMapping(ATypeInfo: PTypeInfo;
  const ASymbols: array of string);
begin
  TAvroEngine.RegisterEnumMapping(ATypeInfo, ASymbols);
end;

{ -------------------------------------------------------------- the schema --- }

class function TAvroSerializer.SchemaJsonFor<T>: string;
begin
  Result := DoSchemaJson(System.TypeInfo(T));
end;

class function TAvroSerializer.SchemaFor<T>: TAvroSchema;
begin
  Result := TAvroSchema.Parse(DoSchemaJson(System.TypeInfo(T)));
end;

{ ------------------------------------------------------------ operations --- }

class function TAvroSerializer.Serialize<T>(const AValue: T): TBytes;
var
  V: TValue;
begin
  TValue.Make(@AValue, System.TypeInfo(T), V);
  Result := DoSerialize(System.TypeInfo(T), V);
end;

class function TAvroSerializer.Deserialize<T>(const AData: TBytes): T;
begin
  Result := DoDeserialize(System.TypeInfo(T), AData, TValue.Empty).AsType<T>;
end;

class procedure TAvroSerializer.Populate<T>(const AInstance: T;
  const AData: TBytes);
var
  V: TValue;
begin
  TValue.Make(@AInstance, System.TypeInfo(T), V);
  DoDeserialize(System.TypeInfo(T), AData, V);
end;

class function TAvroSerializer.DeserializeWith<T>(const AData: TBytes;
  AWriter: TAvroSchema): T;
begin
  Result := TAvroEngine.DeserializeRootWith(System.TypeInfo(T), AData, AWriter,
    TValue.Empty).AsType<T>;
end;

{ ------------------------------------------------------------ datum level --- }

class function TAvroSerializer.Encode(ASchema: TAvroSchema;
  AValue: TAvroValue): TBytes;
begin
  Result := TAvroEngine.EncodeDatum(ASchema, AValue);
end;

class function TAvroSerializer.Decode(const ABytes: TBytes;
  AWriter: TAvroSchema): TAvroValue;
begin
  Result := TAvroEngine.DecodeDatum(ABytes, AWriter, AWriter);
end;

class function TAvroSerializer.Decode(const ABytes: TBytes;
  AWriter, AReader: TAvroSchema): TAvroValue;
begin
  Result := TAvroEngine.DecodeDatum(ABytes, AWriter, AReader);
end;

{ -------------------------------------------------------- container files --- }

class function TAvroSerializer.WriteContainer(ASchema: TAvroSchema;
  const AValues: array of TAvroValue; ACodec: TAvroCodec): TBytes;
begin
  Result := TAvroEngine.WriteContainer(ASchema, AValues, ACodec);
end;

class function TAvroReadOptions.Default: TAvroReadOptions;
begin
  Result.MaxInflatedBlockBytes := DefaultMaxInflatedBlockBytes;
end;

procedure TAvroReadOptions.Validate;
begin
  if MaxInflatedBlockBytes <= 0 then
    raise EAvroError.CreateFmt('TAvroReadOptions.MaxInflatedBlockBytes is ' +
      '%d. It must be positive: it is the most one deflate block may ' +
      'inflate to. Start from TAvroReadOptions.Default.',
      [MaxInflatedBlockBytes]);
end;

function TAvroReadOptions.WithMaxInflatedBlockBytes(
  ABytes: Integer): TAvroReadOptions;
begin
  Result := Self;
  Result.MaxInflatedBlockBytes := ABytes;
  Result.Validate;
end;

class function TAvroSerializer.ReadContainer(const AData: TBytes;
  out AWriterSchemaJson: string): TObjectList<TAvroValue>;
begin
  Result := TAvroEngine.ReadContainer(AData, nil,
    TAvroReadOptions.DefaultMaxInflatedBlockBytes, AWriterSchemaJson);
end;

class function TAvroSerializer.ReadContainer(const AData: TBytes;
  AReader: TAvroSchema; out AWriterSchemaJson: string): TObjectList<TAvroValue>;
begin
  Result := TAvroEngine.ReadContainer(AData, AReader,
    TAvroReadOptions.DefaultMaxInflatedBlockBytes, AWriterSchemaJson);
end;

class function TAvroSerializer.ReadContainer(const AData: TBytes;
  AReader: TAvroSchema; const AOptions: TAvroReadOptions;
  out AWriterSchemaJson: string): TObjectList<TAvroValue>;
begin
  AOptions.Validate;
  Result := TAvroEngine.ReadContainer(AData, AReader,
    AOptions.MaxInflatedBlockBytes, AWriterSchemaJson);
end;

class function TAvroSerializer.ReadContainer<T>(const AData: TBytes): TArray<T>;
begin
  Result := ReadContainer<T>(AData, TAvroReadOptions.Default);
end;

class function TAvroSerializer.ReadContainer<T>(const AData: TBytes;
  const AOptions: TAvroReadOptions): TArray<T>;
var
  Values: TArray<TValue>;
  I: Integer;
begin
  AOptions.Validate;
  Values := TAvroEngine.ReadContainerTyped(System.TypeInfo(T), AData,
    AOptions.MaxInflatedBlockBytes);
  SetLength(Result, Length(Values));
  for I := 0 to Integer(High(Values)) do Result[I] := Values[I].AsType<T>;
end;

class function TAvroSerializer.WriteContainer<T>(const AValues: array of T;
  ACodec: TAvroCodec): TBytes;
var
  Boxed: TArray<TValue>;
  I: Integer;
begin
  SetLength(Boxed, Length(AValues));
  for I := 0 to Integer(High(AValues)) do
    TValue.Make(@AValues[I], System.TypeInfo(T), Boxed[I]);
  Result := TAvroEngine.WriteContainerTyped(System.TypeInfo(T), Boxed, ACodec);
end;

{ ------------------------------------------------------------- conversion --- }

class function TAvroSerializer.From<T>(const ASource: string;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From<T>(TSerializationPayload.FromText(ASource), AFrom);
end;

class function TAvroSerializer.From<T>(const ASource: TBytes;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From<T>(TSerializationPayload.FromBytes(ASource), AFrom);
end;

class function TAvroSerializer.From<T>(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := DoFrom(System.TypeInfo(T), ASource, AFrom);
end;

{ ---------------------------------------------------------- registrations --- }

class procedure TAvroSerializer.RegisterTypeSerializer<T>(
  ASerializerClass: TAvroValueSerializerClass);
begin
  DoRegisterTypeSerializer(System.TypeInfo(T), ASerializerClass);
end;

class procedure TAvroSerializer.RegisterEnumMapping<T>(
  const ASymbols: array of string);
begin
  DoRegisterEnumMapping(System.TypeInfo(T), ASymbols);
end;

class procedure TAvroSerializer.FreezeConfiguration;
begin
  TAvroEngine.FreezeConfiguration;
end;

class function TAvroSerializer.IsFrozen: Boolean;
begin
  Result := TAvroEngine.IsFrozen;
end;

class procedure TAvroSerializer.ResetConfiguration;
begin
  TAvroEngine.ResetConfiguration;
end;


{ ---------------------------------------------------------------- dynamic --- }

class function TAvroSerializer.ToDynamic(const AData: TBytes;
  AWriter, AReader: TAvroSchema): TDynamicValue;
var
  Datum: TAvroValue;
begin
  if AWriter = nil then
    raise ESerializationSchemaRequired.CreateFor(TSerializationFormat.Avro,
      'reading a datum as a dynamic value');
  if AReader = nil then AReader := AWriter;
  Datum := TAvroEngine.DecodeDatum(AData, AWriter, AReader);
  try
    Result := TAvroEngine.AvroToDynamic(Datum);
  finally
    Datum.Free;
  end;
end;

class function TAvroSerializer.FromDynamic(AValue: TDynamicValue;
  ASchema: TAvroSchema): TBytes;
begin
  Result := FromDynamic(AValue, ASchema, TStructuralConversionOptions.Default);
end;

class function TAvroSerializer.FromDynamic(AValue: TDynamicValue;
  ASchema: TAvroSchema; const AOptions: TStructuralConversionOptions): TBytes;
var
  Datum: TAvroValue;
begin
  if ASchema = nil then
    raise ESerializationSchemaRequired.CreateFor(TSerializationFormat.Avro,
      'writing a dynamic value as a datum');
  Datum := TAvroEngine.DynamicToAvro(AValue, ASchema, AOptions, '$');
  try
    Result := TAvroEngine.EncodeDatum(ASchema, Datum);
  finally
    Datum.Free;
  end;
end;

end.
