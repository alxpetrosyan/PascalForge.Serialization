{*******************************************************************************
  PascalForge.Avro.Schema

  Public Avro schema model and parser for PascalForge.Serialization.

  Responsibilities
    - Parsing Avro JSON schemas (.avsc text, registry or container metadata)
      into a TAvroSchema tree.
    - Schema inspection, Parsing Canonical Form and fingerprints.
    - The common model for external and generated schemas.

  Registration
    Parsing a schema requires no format registration. Generic TSerialization
    operations require TAvroSerializationRegistration.RegisterFormat
    (PascalForge.Avro.Registration).

  Documentation
    docs/formats/avro.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Avro.Schema;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  THE AVRO SCHEMA MODEL AND ITS PARSER.

  Target: Apache Avro specification 1.12.0.

  An Avro schema is a JSON document, and it is not optional: the datum
  encoding carries no type information whatsoever, so the schema is what
  makes a sequence of Avro bytes mean anything. This unit is therefore the
  foundation the rest of the Avro implementation stands on, and it is a
  separate unit for exactly that reason - a caller may parse, inspect,
  fingerprint and print a schema without ever encoding a byte.

  EXTERNAL SCHEMAS ARE FIRST CLASS. Nothing here knows about Delphi RTTI.
  A schema arrives as JSON text somebody else wrote - from a schema
  registry, from a .avsc file, from the metadata of a container file - and
  is modelled exactly as written, including the parts this library makes no
  further use of (doc strings, field order, unrecognised logical types).
  PascalForge.Avro.Internal also GENERATES schema JSON from a Delphi type
  and hands it to the parser here, so a generated schema and an external one
  are the same kind of object and travel the same code paths.

  WHY System.JSON AND NOT PascalForge.Json. A format implementation in this
  library may not reference a sibling format, and PascalForge.Json is a
  sibling. System.JSON is Delphi's own RTL unit and is not a sibling of
  anything - it is as much part of the platform as SysUtils. The alternative
  considered was a small hand-written JSON reader, which would have been a
  hundred lines of avoidable parser and a second place for JSON bugs to
  live.

  OWNERSHIP. Parse returns a tree the caller owns, and the tree owns
  everything reachable from it. Nodes are NOT owned by their parents,
  because Avro schemas share and recurse - a named type used a second time
  is the same node, and a record may contain itself - so every node created
  by one Parse call is owned by an arena held on the root. Freeing the root
  frees the lot, once each. A TAvroSchema handed to the library through
  TStructuralConversionOptions is BORROWED and never freed here.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  PascalForge.Serialization.Core;

type
  { Everything this unit raises. The schema - or the JSON claiming to be one
    - is at fault. }
  EAvroSchemaError = class(Exception);

  { The fourteen types the specification defines: eight primitives and six
    complex ones. There is no "reference" member: a named type used a second
    time resolves to the SAME node, so a reference is invisible by the time
    parsing has finished, which is the point. }
  TAvroType = (
    Null, Bool, Int, Long, Float, Double, Bytes, Str,
    Rec, Enum, Arr, Map, Union, Fixed);

  { A logical type annotates an underlying Avro type with a meaning. The
    specification is explicit that an implementation which does not
    recognise one must fall back to the underlying type rather than fail,
    so an unrecognised annotation is Unknown and its text is kept. }
  TAvroLogicalType = (
    None,
    Decimal,                 { bytes or fixed, plus precision and scale }
    Uuid,                    { string, or fixed of size 16 }
    Date,                    { int, days since 1970-01-01 }
    TimeMillis,              { int, milliseconds after midnight }
    TimeMicros,              { long, microseconds after midnight }
    TimestampMillis,         { long, milliseconds since the Unix epoch, UTC }
    TimestampMicros,         { long, microseconds since the Unix epoch, UTC }
    LocalTimestampMillis,    { long, milliseconds, no time zone }
    LocalTimestampMicros,    { long, microseconds, no time zone }
    Duration,                { fixed of size 12: months, days, milliseconds }
    Unknown);

  { A field's sort order. Kept because a schema says it, not because
    anything here sorts: dropping an attribute the author wrote would make
    ToJson print a different schema from the one that was parsed. }
  TAvroFieldOrder = (Ascending, Descending, Ignore);

  { A field default, exactly as the JSON gave it.

    A default cannot be modelled as "a value of the field's type" while the
    schema is still being parsed, because the field's type may be a named
    reference that is not resolved yet. So it is held as the JSON shape it
    had, and turned into bytes of the field's type later, once - see
    PascalForge.Avro.Internal, which is the only consumer. }
  TAvroDefaultKind = (Null, Bool, Num, Str, Arr, Obj);

  TAvroDefault = class
  strict private
    FKind: TAvroDefaultKind;
    FBool: Boolean;
    FInt: Int64;
    FFloat: System.Double;
    FIsIntegral: Boolean;
    FStr: string;
    FItems: TObjectList<TAvroDefault>;
    FNames: TStringList;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TAvroDefault;
    function GetName(AIndex: Integer): string;
  public
    constructor Create(AKind: TAvroDefaultKind);
    destructor Destroy; override;

    class function NewNull: TAvroDefault; static;
    class function NewBool(AValue: Boolean): TAvroDefault; static;
    class function NewInt(AValue: Int64): TAvroDefault; static;
    class function NewFloat(AValue: System.Double): TAvroDefault; static;
    class function NewStr(const AValue: string): TAvroDefault; static;
    class function NewArray: TAvroDefault; static;
    class function NewObject: TAvroDefault; static;

    { Both adopt AValue. }
    procedure Add(AValue: TAvroDefault); overload;
    procedure Add(const AName: string; AValue: TAvroDefault); overload;
    function Find(const AName: string): TAvroDefault;

    property Kind: TAvroDefaultKind read FKind;
    property AsBool: Boolean read FBool;
    property AsInt: Int64 read FInt;
    property AsFloat: System.Double read FFloat;
    { True when the JSON number had no fractional part or exponent, so a
      default of 1 for a long is an integer and not 1.0. }
    property IsIntegral: Boolean read FIsIntegral;
    property AsStr: string read FStr;
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TAvroDefault read GetItem; default;
    property Names[AIndex: Integer]: string read GetName;
  end;

  TAvroSchema = class;

  TAvroField = class
  strict private
    FName: string;
    FDoc: string;
    FAliases: TArray<string>;
    FFieldType: TAvroSchema;
    FDefault: TAvroDefault;
    FOrder: TAvroFieldOrder;
  public
    destructor Destroy; override;
    { True when AName is this field's name or one of its aliases. Field
      aliases are plain names - unlike a named type's, they are not
      namespaced. }
    function Matches(const AName: string): Boolean;

    property Name: string read FName write FName;
    property Doc: string read FDoc write FDoc;
    property Aliases: TArray<string> read FAliases write FAliases;
    { Borrowed: it belongs to the schema tree's arena. }
    property FieldType: TAvroSchema read FFieldType write FFieldType;
    { nil when the field has no default. Owned. }
    property Default: TAvroDefault read FDefault write FDefault;
    property Order: TAvroFieldOrder read FOrder write FOrder;
  end;

  { ------------------------------------------------------------------------
    A SCHEMA NODE.

    One class for all fourteen types rather than a hierarchy, because a
    consumer switches on the type constantly and would otherwise spend its
    life casting. The attributes that do not apply to a given type are
    simply unset, and asking for one of them raises rather than returning a
    plausible zero.
    ------------------------------------------------------------------------ }

  TAvroSchema = class(TSerializationSchema)
  { Private rather than strict private, and deliberately: the parser below is
    declared in this unit's implementation section and has to fill in the
    fields it builds. Widening them to public would put "add a branch to this
    union after it has been validated" into the API, which is exactly the
    thing the parser exists to prevent anyone else doing. }
  private
    FArena: TObjectList<TAvroSchema>;
    FType: TAvroType;
    FName: string;
    FNamespace: string;
    FFullName: string;
    FDoc: string;
    FAliases: TArray<string>;
    FFields: TObjectList<TAvroField>;
    FSymbols: TArray<string>;
    FEnumDefault: string;
    FHasEnumDefault: Boolean;
    FItemType: TAvroSchema;
    FValueType: TAvroSchema;
    FBranches: TList<TAvroSchema>;
    FSize: Integer;
    FLogical: TAvroLogicalType;
    FLogicalName: string;
    FPrecision: Integer;
    FScale: Integer;
    function GetFieldCount: Integer;
    function GetField(AIndex: Integer): TAvroField;
    function GetBranchCount: Integer;
    function GetBranch(AIndex: Integer): TAvroSchema;
  public
    constructor Create(AType: TAvroType);
    destructor Destroy; override;

    { ----------------------------------------------------------------------
      Parses a schema document. AJson is the whole schema - a JSON string
      naming a primitive, a JSON array which is a union, or a JSON object.

      The result is the root, and it owns every node underneath it. }
    class function Parse(const AJson: string): TAvroSchema; static;

    function Format: TSerializationFormat; override;
    function Describe: string; override;

    { The schema as JSON. Named types are written out in full the first time
      they appear and by name afterwards, which is what the specification
      requires and what every other Avro tool produces. Names are always
      written as fullnames, so the output never depends on an enclosing
      namespace that is no longer there. }
    function ToJson: string;

    { The specification's Parsing Canonical Form: primitives reduced to
      their bare name, fullnames substituted, every attribute that does not
      affect parsing stripped, the rest ordered, no whitespace. Two schemas
      with the same canonical form read each other's data. }
    function CanonicalForm: string;

    { The 64-bit Rabin fingerprint of the canonical form, as the
      specification's own "Schema Fingerprints" section defines it -
      including its published initial constant. This is the fingerprint the
      single-object encoding and most schema registries use. }
    function Fingerprint: UInt64;

    { True for record, enum and fixed - the three types that have a name. }
    function IsNamed: Boolean;
    { True when AFullName is this schema's full name or one of its aliases.
      Resolution matches renamed types through this. }
    function Matches(const AFullName: string): Boolean;
    function IndexOfField(const AName: string): Integer;
    function FindField(const AName: string): TAvroField;
    { The branch of a union whose type is AType, or -1. Used when writing a
      value into a union without being told which branch. }
    function IndexOfBranchType(AType: TAvroType): Integer;
    function IndexOfSymbol(const ASymbol: string): Integer;
    { The name Avro itself uses for this type in a message. }
    function TypeName: string;

    property SchemaType: TAvroType read FType;
    property Name: string read FName write FName;
    property Namespace: string read FNamespace write FNamespace;
    property FullName: string read FFullName write FFullName;
    property Doc: string read FDoc write FDoc;
    property Aliases: TArray<string> read FAliases write FAliases;

    property FieldCount: Integer read GetFieldCount;
    property Fields[AIndex: Integer]: TAvroField read GetField;
    property Symbols: TArray<string> read FSymbols write FSymbols;
    property EnumDefault: string read FEnumDefault write FEnumDefault;
    property HasEnumDefault: Boolean read FHasEnumDefault write FHasEnumDefault;
    { Array element type. Borrowed. }
    property ItemType: TAvroSchema read FItemType write FItemType;
    { Map value type; map keys are always strings. Borrowed. }
    property ValueType: TAvroSchema read FValueType write FValueType;
    property BranchCount: Integer read GetBranchCount;
    property Branches[AIndex: Integer]: TAvroSchema read GetBranch;
    { Byte count of a fixed. }
    property Size: Integer read FSize write FSize;

    property LogicalType: TAvroLogicalType read FLogical write FLogical;
    { The annotation exactly as written, including one this version does not
      implement. }
    property LogicalName: string read FLogicalName write FLogicalName;
    property Precision: Integer read FPrecision write FPrecision;
    property Scale: Integer read FScale write FScale;
  end;

{ The specification's published initial value for the 64-bit Rabin
  fingerprint, and therefore the fingerprint of an empty byte sequence. }
const
  AVRO_EMPTY_FINGERPRINT64 = UInt64($c15d213aa4d7a795);

{ The Rabin fingerprint of arbitrary bytes, exactly as the "Schema
  Fingerprints" section of the specification writes it. Exposed because a
  caller who has canonical-form text from elsewhere - a registry, a header -
  needs to fingerprint it without building a schema. }
function AvroFingerprint64(const ABytes: TBytes): UInt64;

{ True when AName is a legal Avro name: a letter or underscore, then letters,
  digits and underscores. A fullname is one or more of those separated by
  dots. }
function IsValidAvroName(const AName: string): Boolean;
function IsValidAvroFullName(const AName: string): Boolean;

{ Quotes a string as a JSON string literal, with the minimal escaping the
  canonical form requires. Public because the schema JSON generated from a
  Delphi type is built in PascalForge.Avro.Internal and must escape exactly
  the same way. }
function AvroJsonQuote(const AText: string): string;

type
  { ---------------------------------------------------------------------
    A WRITER'S SCHEMA AND A READER'S SCHEMA ARE TWO DIFFERENT THINGS

    Schema resolution is the whole point of Avro: the schema a datum was
    WRITTEN with need not be the one a reader wants it as. Both are Avro
    schemas, so format identity cannot tell them apart, and that is exactly
    what the source and destination roles are for.

    A context in the SOURCE role says what the incoming bytes were written
    with. One in the DESTINATION role says what to write. A conversion from
    Avro schema A to Avro schema B has one of each, and neither end has to
    guess which is which.

    LIFETIME: the schemas are BORROWED. Freeing a context frees neither, so
    one parsed schema serves every conversion that uses it. }
  TAvroSerializationContext = class(TSerializationContext)
  strict private
    FSchema: TAvroSchema;
    FReaderSchema: TAvroSchema;
  public
    { AReaderSchema is optional and means "resolve the datum into this
      instead"; nil reads it as it was written. }
    constructor Create(ASchema: TAvroSchema;
      AReaderSchema: TAvroSchema = nil);

    function Format: TSerializationFormat; override;
    function Describe: string; override;

    { The schema this end acts with. }
    property Schema: TAvroSchema read FSchema;
    { The schema to resolve INTO, for a reader that wants a different shape.
      nil when there is none. }
    property ReaderSchema: TAvroSchema read FReaderSchema;
  end;


implementation

uses
  System.JSON, System.Character, System.Math;

{ ============================================================================
  NAMES
  ============================================================================ }

function IsValidAvroName(const AName: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  if AName = '' then Exit(False);
  C := AName[1];
  if not (CharInSet(C, ['A'..'Z', 'a'..'z', '_'])) then Exit(False);
  for I := 2 to Length(AName) do
    if not CharInSet(AName[I], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Exit(False);
  Result := True;
end;

function IsValidAvroFullName(const AName: string): Boolean;
var
  Part: string;
begin
  if AName = '' then Exit(False);
  for Part in AName.Split(['.']) do
    if not IsValidAvroName(Part) then Exit(False);
  Result := True;
end;

function NamespaceOf(const AFullName: string): string;
var
  P: Integer;
begin
  P := AFullName.LastDelimiter('.');
  if P < 0 then Result := '' else Result := Copy(AFullName, 1, P);
end;

function JoinName(const ANamespace, AName: string): string;
begin
  if ANamespace = '' then Result := AName
  else Result := ANamespace + '.' + AName;
end;

{ ============================================================================
  JSON STRING OUTPUT

  The canonical form's [STRINGS] rule asks for the minimal escaping JSON
  allows, so only what must be escaped is escaped. Characters above the BMP
  arrive here as a surrogate pair and are written straight through as UTF-16
  code units, which is what the Delphi string holds and what the UTF-8
  conversion in Core will turn into a four-byte sequence.
  ============================================================================ }

function AvroJsonQuote(const AText: string): string;
var
  SB: TStringBuilder;
  I: Integer;
  C: Char;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('"');
    for I := 1 to Length(AText) do
    begin
      C := AText[I];
      case C of
        '"': SB.Append('\"');
        '\': SB.Append('\\');
        #8: SB.Append('\b');
        #9: SB.Append('\t');
        #10: SB.Append('\n');
        #12: SB.Append('\f');
        #13: SB.Append('\r');
      else
        if C < #32 then SB.Append('\u').Append(IntToHex(Ord(C), 4).ToLower)
        else SB.Append(C);
      end;
    end;
    SB.Append('"');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ ============================================================================
  THE RABIN FINGERPRINT

  Transcribed from the pseudocode the specification publishes. Java's >>> is
  Delphi's shr on an unsigned type, and Java's "EMPTY & -(fp & 1)" is a
  branchless way of saying "xor in EMPTY when the low bit is set", which is
  what the branch below says instead.
  ============================================================================ }

var
  GFingerprintTable: array[0..255] of UInt64;
  GFingerprintTableReady: Boolean = False;

procedure InitFingerprintTable;
var
  I, J: Integer;
  Fp: UInt64;
begin
  for I := 0 to 255 do
  begin
    Fp := UInt64(I);
    for J := 0 to 7 do
      if (Fp and 1) <> 0 then Fp := (Fp shr 1) xor AVRO_EMPTY_FINGERPRINT64
      else Fp := Fp shr 1;
    GFingerprintTable[I] := Fp;
  end;
  GFingerprintTableReady := True;
end;

function AvroFingerprint64(const ABytes: TBytes): UInt64;
var
  I: Integer;
begin
  if not GFingerprintTableReady then InitFingerprintTable;
  Result := AVRO_EMPTY_FINGERPRINT64;
  for I := 0 to Integer(High(ABytes)) do
    Result := (Result shr 8) xor
      GFingerprintTable[(Result xor UInt64(ABytes[I])) and $FF];
end;

{ ============================================================================
  TAvroDefault
  ============================================================================ }

constructor TAvroDefault.Create(AKind: TAvroDefaultKind);
begin
  inherited Create;
  FKind := AKind;
  if AKind in [TAvroDefaultKind.Arr, TAvroDefaultKind.Obj] then
    FItems := TObjectList<TAvroDefault>.Create(True);
  if AKind = TAvroDefaultKind.Obj then
  begin
    FNames := TStringList.Create;
    FNames.CaseSensitive := True;
  end;
end;

destructor TAvroDefault.Destroy;
begin
  FItems.Free;
  FNames.Free;
  inherited;
end;

class function TAvroDefault.NewNull: TAvroDefault;
begin
  Result := TAvroDefault.Create(TAvroDefaultKind.Null);
end;

class function TAvroDefault.NewBool(AValue: Boolean): TAvroDefault;
begin
  Result := TAvroDefault.Create(TAvroDefaultKind.Bool);
  Result.FBool := AValue;
end;

class function TAvroDefault.NewInt(AValue: Int64): TAvroDefault;
begin
  Result := TAvroDefault.Create(TAvroDefaultKind.Num);
  Result.FInt := AValue;
  Result.FFloat := AValue;
  Result.FIsIntegral := True;
end;

class function TAvroDefault.NewFloat(AValue: System.Double): TAvroDefault;
begin
  Result := TAvroDefault.Create(TAvroDefaultKind.Num);
  Result.FFloat := AValue;
  if (AValue >= -9.2e18) and (AValue <= 9.2e18) then Result.FInt := Round(AValue);
  Result.FIsIntegral := False;
end;

class function TAvroDefault.NewStr(const AValue: string): TAvroDefault;
begin
  Result := TAvroDefault.Create(TAvroDefaultKind.Str);
  Result.FStr := AValue;
end;

class function TAvroDefault.NewArray: TAvroDefault;
begin
  Result := TAvroDefault.Create(TAvroDefaultKind.Arr);
end;

class function TAvroDefault.NewObject: TAvroDefault;
begin
  Result := TAvroDefault.Create(TAvroDefaultKind.Obj);
end;

procedure TAvroDefault.Add(AValue: TAvroDefault);
begin
  if FKind <> TAvroDefaultKind.Arr then
  begin
    AValue.Free;
    raise EAvroSchemaError.Create('Only an array default takes a bare item.');
  end;
  FItems.Add(AValue);
end;

procedure TAvroDefault.Add(const AName: string; AValue: TAvroDefault);
begin
  if FKind <> TAvroDefaultKind.Obj then
  begin
    AValue.Free;
    raise EAvroSchemaError.Create('Only an object default takes a named item.');
  end;
  FItems.Add(AValue);
  FNames.Add(AName);
end;

function TAvroDefault.GetCount: Integer;
begin
  if FItems = nil then Result := 0 else Result := Integer(FItems.Count);
end;

function TAvroDefault.GetItem(AIndex: Integer): TAvroDefault;
begin
  Result := FItems[AIndex];
end;

function TAvroDefault.GetName(AIndex: Integer): string;
begin
  Result := FNames[AIndex];
end;

function TAvroDefault.Find(const AName: string): TAvroDefault;
var
  I: Integer;
begin
  if FNames <> nil then
    for I := 0 to FNames.Count - 1 do
      if FNames[I] = AName then Exit(FItems[I]);
  Result := nil;
end;

{ ============================================================================
  TAvroField
  ============================================================================ }

destructor TAvroField.Destroy;
begin
  FDefault.Free;
  inherited;
end;

function TAvroField.Matches(const AName: string): Boolean;
var
  A: string;
begin
  if FName = AName then Exit(True);
  for A in FAliases do
    if A = AName then Exit(True);
  Result := False;
end;

{ ============================================================================
  TAvroSchema
  ============================================================================ }

constructor TAvroSchema.Create(AType: TAvroType);
begin
  inherited Create;
  FType := AType;
  FLogical := TAvroLogicalType.None;
  if AType = TAvroType.Rec then FFields := TObjectList<TAvroField>.Create(True);
  if AType = TAvroType.Union then FBranches := TList<TAvroSchema>.Create;
end;

destructor TAvroSchema.Destroy;
begin
  FFields.Free;
  FBranches.Free;
  { Only a root has one. Freeing it frees every other node of this schema,
    each exactly once, whatever the sharing and recursion above. }
  FArena.Free;
  inherited;
end;

function TAvroSchema.Format: TSerializationFormat;
begin
  Result := TSerializationFormat.Avro;
end;

function TAvroSchema.TypeName: string;
const
  NAMES: array[TAvroType] of string = (
    'null', 'boolean', 'int', 'long', 'float', 'double', 'bytes', 'string',
    'record', 'enum', 'array', 'map', 'union', 'fixed');
begin
  Result := NAMES[FType];
end;

function TAvroSchema.Describe: string;
begin
  case FType of
    TAvroType.Rec: Result := System.SysUtils.Format('record %s, %d fields',
      [FFullName, FieldCount]);
    TAvroType.Enum: Result := System.SysUtils.Format('enum %s, %d symbols',
      [FFullName, Length(FSymbols)]);
    TAvroType.Fixed: Result := System.SysUtils.Format('fixed %s, %d bytes',
      [FFullName, FSize]);
    TAvroType.Union: Result := System.SysUtils.Format('union of %d',
      [BranchCount]);
    TAvroType.Arr: Result := 'array';
    TAvroType.Map: Result := 'map';
  else
    Result := TypeName;
  end;
  if FLogical <> TAvroLogicalType.None then
    Result := Result + ' (' + FLogicalName + ')';
end;

function TAvroSchema.IsNamed: Boolean;
begin
  Result := FType in [TAvroType.Rec, TAvroType.Enum, TAvroType.Fixed];
end;

function TAvroSchema.Matches(const AFullName: string): Boolean;
var
  A: string;
begin
  if FFullName = AFullName then Exit(True);
  for A in FAliases do
    if A = AFullName then Exit(True);
  Result := False;
end;

function TAvroSchema.GetFieldCount: Integer;
begin
  if FFields = nil then Result := 0 else Result := Integer(FFields.Count);
end;

function TAvroSchema.GetField(AIndex: Integer): TAvroField;
begin
  if FFields = nil then
    raise EAvroSchemaError.CreateFmt('%s has no fields; it is not a record.',
      [TypeName]);
  Result := FFields[AIndex];
end;

function TAvroSchema.GetBranchCount: Integer;
begin
  if FBranches = nil then Result := 0 else Result := Integer(FBranches.Count);
end;

function TAvroSchema.GetBranch(AIndex: Integer): TAvroSchema;
begin
  if FBranches = nil then
    raise EAvroSchemaError.CreateFmt('%s has no branches; it is not a union.',
      [TypeName]);
  Result := FBranches[AIndex];
end;

function TAvroSchema.IndexOfField(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FieldCount - 1 do
    if FFields[I].Name = AName then Exit(I);
  Result := -1;
end;

function TAvroSchema.FindField(const AName: string): TAvroField;
var
  I: Integer;
begin
  I := IndexOfField(AName);
  if I < 0 then Result := nil else Result := FFields[I];
end;

function TAvroSchema.IndexOfBranchType(AType: TAvroType): Integer;
var
  I: Integer;
begin
  for I := 0 to BranchCount - 1 do
    if FBranches[I].SchemaType = AType then Exit(I);
  Result := -1;
end;

function TAvroSchema.IndexOfSymbol(const ASymbol: string): Integer;
var
  I: Integer;
begin
  for I := 0 to Integer(High(FSymbols)) do
    if FSymbols[I] = ASymbol then Exit(I);
  Result := -1;
end;

{ ---------------------------------------------------------------------------
  THE PARSER

  A schema document is one of three JSON shapes, and the recursion below
  handles all three at every level, because a field's type is itself a whole
  schema document.

    a string      a primitive name, or the fullname of a type defined earlier
    an array      a union
    an object     everything else, with "type" saying which

  Two pieces of state travel down the recursion: the arena that owns every
  node, and the enclosing namespace, which is what an unqualified name is
  relative to.
  --------------------------------------------------------------------------- }

type
  TAvroParser = class
  strict private
    FArena: TObjectList<TAvroSchema>;
    FNamed: TDictionary<string, TAvroSchema>;
    FRoot: TAvroSchema;
    function Own(ASchema: TAvroSchema): TAvroSchema;
    function PrimitiveOf(const AName: string): TAvroType;
    function LogicalOf(const AName: string): TAvroLogicalType;
    function AsObject(AValue: TJSONValue; const AWhat: string): TJSONObject;
    function StrAttr(AObj: TJSONObject; const AName: string;
      out AValue: string): Boolean;
    function IntAttr(AObj: TJSONObject; const AName: string;
      out AValue: Integer): Boolean;
    function StrArrayAttr(AObj: TJSONObject; const AName: string): TArray<string>;
    function ConvertDefault(AValue: TJSONValue): TAvroDefault;
    procedure ApplyLogical(ASchema: TAvroSchema; AObj: TJSONObject);
    procedure RegisterNamed(ASchema: TAvroSchema);
    function ParseValue(AValue: TJSONValue;
      const AEnclosing: string): TAvroSchema;
    function ParseObject(AObj: TJSONObject;
      const AEnclosing: string): TAvroSchema;
    function ParseUnion(AArr: TJSONArray;
      const AEnclosing: string): TAvroSchema;
  public
    constructor Create;
    destructor Destroy; override;
    function Run(const AJson: string): TAvroSchema;
  end;

constructor TAvroParser.Create;
begin
  inherited Create;
  FArena := TObjectList<TAvroSchema>.Create(True);
  FNamed := TDictionary<string, TAvroSchema>.Create;
end;

destructor TAvroParser.Destroy;
begin
  { FArena is handed to the root on success and is nil by then. }
  FArena.Free;
  FNamed.Free;
  inherited;
end;

function TAvroParser.Own(ASchema: TAvroSchema): TAvroSchema;
begin
  FArena.Add(ASchema);
  Result := ASchema;
end;

function TAvroParser.PrimitiveOf(const AName: string): TAvroType;
begin
  if AName = 'null' then Result := TAvroType.Null
  else if AName = 'boolean' then Result := TAvroType.Bool
  else if AName = 'int' then Result := TAvroType.Int
  else if AName = 'long' then Result := TAvroType.Long
  else if AName = 'float' then Result := TAvroType.Float
  else if AName = 'double' then Result := TAvroType.Double
  else if AName = 'bytes' then Result := TAvroType.Bytes
  else if AName = 'string' then Result := TAvroType.Str
  else if AName = 'record' then Result := TAvroType.Rec
  else if AName = 'error' then Result := TAvroType.Rec
  else if AName = 'enum' then Result := TAvroType.Enum
  else if AName = 'array' then Result := TAvroType.Arr
  else if AName = 'map' then Result := TAvroType.Map
  else if AName = 'fixed' then Result := TAvroType.Fixed
  else raise EAvroSchemaError.CreateFmt(
    '"%s" is not an Avro type and no schema with that name has been ' +
    'defined yet. A name used as a type must be a primitive, one of the ' +
    'six complex types, or the full name of a record, enum or fixed ' +
    'defined earlier in the same schema.', [AName]);
end;

function TAvroParser.LogicalOf(const AName: string): TAvroLogicalType;
begin
  if AName = 'decimal' then Result := TAvroLogicalType.Decimal
  else if AName = 'uuid' then Result := TAvroLogicalType.Uuid
  else if AName = 'date' then Result := TAvroLogicalType.Date
  else if AName = 'time-millis' then Result := TAvroLogicalType.TimeMillis
  else if AName = 'time-micros' then Result := TAvroLogicalType.TimeMicros
  else if AName = 'timestamp-millis' then Result := TAvroLogicalType.TimestampMillis
  else if AName = 'timestamp-micros' then Result := TAvroLogicalType.TimestampMicros
  else if AName = 'local-timestamp-millis' then
    Result := TAvroLogicalType.LocalTimestampMillis
  else if AName = 'local-timestamp-micros' then
    Result := TAvroLogicalType.LocalTimestampMicros
  else if AName = 'duration' then Result := TAvroLogicalType.Duration
  else Result := TAvroLogicalType.Unknown;
end;

function TAvroParser.AsObject(AValue: TJSONValue;
  const AWhat: string): TJSONObject;
begin
  if not (AValue is TJSONObject) then
    raise EAvroSchemaError.CreateFmt('%s must be a JSON object.', [AWhat]);
  Result := TJSONObject(AValue);
end;

function TAvroParser.StrAttr(AObj: TJSONObject; const AName: string;
  out AValue: string): Boolean;
var
  V: TJSONValue;
begin
  AValue := '';
  V := AObj.Values[AName];
  if V = nil then Exit(False);
  { TJSONNumber descends from TJSONString in this RTL, so the number test
    has to come first or every number would read as a string. }
  if V is TJSONNumber then Exit(False);
  if not (V is TJSONString) then Exit(False);
  AValue := TJSONString(V).Value;
  Result := True;
end;

function TAvroParser.IntAttr(AObj: TJSONObject; const AName: string;
  out AValue: Integer): Boolean;
var
  V: TJSONValue;
begin
  AValue := 0;
  V := AObj.Values[AName];
  if not (V is TJSONNumber) then Exit(False);
  { Checked here: AsInt let the RTL's EConvertError escape for a number
    past an Integer or with a fraction, which is a schema error. }
  if not TryStrToInt(TJSONNumber(V).Value, AValue) then
    raise EAvroSchemaError.CreateFmt(
      '"%s" is %s, which is not a whole number an Integer can hold.',
      [AName, TJSONNumber(V).Value]);
  Result := True;
end;

function TAvroParser.StrArrayAttr(AObj: TJSONObject;
  const AName: string): TArray<string>;
var
  V: TJSONValue;
  Arr: TJSONArray;
  I: Integer;
begin
  Result := nil;
  V := AObj.Values[AName];
  if not (V is TJSONArray) then Exit;
  Arr := TJSONArray(V);
  SetLength(Result, Arr.Count);
  for I := 0 to Arr.Count - 1 do
  begin
    if not (Arr.Items[I] is TJSONString) or (Arr.Items[I] is TJSONNumber) then
      raise EAvroSchemaError.CreateFmt(
        'Every entry of "%s" must be a string.', [AName]);
    Result[I] := TJSONString(Arr.Items[I]).Value;
  end;
end;

function TAvroParser.ConvertDefault(AValue: TJSONValue): TAvroDefault;
var
  Arr: TJSONArray;
  Obj: TJSONObject;
  I: Integer;
  Text: string;
  Number: System.Double;
begin
  if (AValue = nil) or (AValue is TJSONNull) then Exit(TAvroDefault.NewNull);
  if AValue is TJSONBool then Exit(TAvroDefault.NewBool(TJSONBool(AValue).AsBoolean));
  if AValue is TJSONNumber then
  begin
    Text := TJSONNumber(AValue).Value;
    if (Pos('.', Text) = 0) and (Pos('e', LowerCase(Text)) = 0) then
      Result := TAvroDefault.NewInt(TJSONNumber(AValue).AsInt64)
    else
    begin
      { Through Core, correctly rounded: TJSONNumber.AsDouble is the RTL's
        conversion, which on Win64 misreads 17-digit text by an ulp. }
      if not TStructuralText.TryParseFloat(Text, Number) then
        raise EAvroSchemaError.CreateFmt('The default %s is not a number.',
          [Text]);
      Result := TAvroDefault.NewFloat(Number);
    end;
    Exit;
  end;
  if AValue is TJSONString then Exit(TAvroDefault.NewStr(TJSONString(AValue).Value));
  if AValue is TJSONArray then
  begin
    Arr := TJSONArray(AValue);
    Result := TAvroDefault.NewArray;
    try
      for I := 0 to Arr.Count - 1 do Result.Add(ConvertDefault(Arr.Items[I]));
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;
  if AValue is TJSONObject then
  begin
    Obj := TJSONObject(AValue);
    Result := TAvroDefault.NewObject;
    try
      for I := 0 to Obj.Count - 1 do
        Result.Add(Obj.Pairs[I].JsonString.Value,
          ConvertDefault(Obj.Pairs[I].JsonValue));
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;
  raise EAvroSchemaError.Create('A default value must be a JSON value.');
end;

procedure TAvroParser.ApplyLogical(ASchema: TAvroSchema; AObj: TJSONObject);
var
  Text: string;
  N: Integer;
begin
  if not StrAttr(AObj, 'logicalType', Text) then Exit;
  ASchema.LogicalName := Text;
  ASchema.LogicalType := LogicalOf(Text);

  { The specification says an implementation that cannot make sense of a
    logical type must ignore the annotation and use the underlying type,
    which is why every check below degrades to Unknown rather than raising. }
  case ASchema.LogicalType of
    TAvroLogicalType.Decimal:
      begin
        if not (ASchema.SchemaType in [TAvroType.Bytes, TAvroType.Fixed]) then
          ASchema.LogicalType := TAvroLogicalType.Unknown
        else
        begin
          if not IntAttr(AObj, 'precision', N) then N := 0;
          ASchema.Precision := N;
          if not IntAttr(AObj, 'scale', N) then N := 0;
          ASchema.Scale := N;
          if (ASchema.Precision < 1) or (ASchema.Scale < 0) or
             (ASchema.Scale > ASchema.Precision) then
            ASchema.LogicalType := TAvroLogicalType.Unknown;
        end;
      end;
    TAvroLogicalType.Uuid:
      if not ((ASchema.SchemaType = TAvroType.Str) or
              ((ASchema.SchemaType = TAvroType.Fixed) and (ASchema.Size = 16))) then
        ASchema.LogicalType := TAvroLogicalType.Unknown;
    TAvroLogicalType.Date, TAvroLogicalType.TimeMillis:
      if ASchema.SchemaType <> TAvroType.Int then
        ASchema.LogicalType := TAvroLogicalType.Unknown;
    TAvroLogicalType.TimeMicros, TAvroLogicalType.TimestampMillis,
    TAvroLogicalType.TimestampMicros, TAvroLogicalType.LocalTimestampMillis,
    TAvroLogicalType.LocalTimestampMicros:
      if ASchema.SchemaType <> TAvroType.Long then
        ASchema.LogicalType := TAvroLogicalType.Unknown;
    TAvroLogicalType.Duration:
      if (ASchema.SchemaType <> TAvroType.Fixed) or (ASchema.Size <> 12) then
        ASchema.LogicalType := TAvroLogicalType.Unknown;
  end;
end;

procedure TAvroParser.RegisterNamed(ASchema: TAvroSchema);
begin
  if FNamed.ContainsKey(ASchema.FullName) then
    raise EAvroSchemaError.CreateFmt(
      'The name "%s" is defined twice in this schema. A full name ' +
      'identifies exactly one record, enum or fixed.', [ASchema.FullName]);
  FNamed.Add(ASchema.FullName, ASchema);
end;

function TAvroParser.ParseUnion(AArr: TJSONArray;
  const AEnclosing: string): TAvroSchema;
var
  I, J: Integer;
  Branch: TAvroSchema;
begin
  Result := Own(TAvroSchema.Create(TAvroType.Union));
  for I := 0 to AArr.Count - 1 do
  begin
    Branch := ParseValue(AArr.Items[I], AEnclosing);
    if Branch.SchemaType = TAvroType.Union then
      raise EAvroSchemaError.Create(
        'A union may not immediately contain another union.');
    for J := 0 to Result.BranchCount - 1 do
      if Result.Branches[J].SchemaType = Branch.SchemaType then
      begin
        if not Branch.IsNamed then
          raise EAvroSchemaError.CreateFmt(
            'This union has two "%s" branches. Only the named types - ' +
            'record, enum and fixed - may appear more than once, and then ' +
            'only under different names.', [Branch.TypeName]);
        if Result.Branches[J].FullName = Branch.FullName then
          raise EAvroSchemaError.CreateFmt(
            'This union has two branches named "%s".', [Branch.FullName]);
      end;
    Result.FBranches.Add(Branch);
  end;
  if Result.BranchCount = 0 then
    raise EAvroSchemaError.Create('A union must have at least one branch.');
end;

function TAvroParser.ParseValue(AValue: TJSONValue;
  const AEnclosing: string): TAvroSchema;
var
  Text, Full: string;
  Existing: TAvroSchema;
begin
  if AValue = nil then
    raise EAvroSchemaError.Create('A schema may not be empty.');

  if (AValue is TJSONString) and not (AValue is TJSONNumber) then
  begin
    Text := TJSONString(AValue).Value;
    { A bare name is a primitive, or a reference to something already
      defined. Reference resolution is why this returns an EXISTING node
      rather than a copy: a record that contains itself has to be the same
      object, or the tree would not terminate. }
    Full := Text;
    if Pos('.', Text) = 0 then Full := JoinName(AEnclosing, Text);
    if FNamed.TryGetValue(Full, Existing) then Exit(Existing);
    if FNamed.TryGetValue(Text, Existing) then Exit(Existing);
    Result := Own(TAvroSchema.Create(PrimitiveOf(Text)));
    if Result.SchemaType in [TAvroType.Rec, TAvroType.Enum, TAvroType.Fixed,
                             TAvroType.Arr, TAvroType.Map] then
      raise EAvroSchemaError.CreateFmt(
        '"%s" names a complex type, which cannot be written as a bare ' +
        'string - it needs an object with its own attributes.', [Text]);
    Exit;
  end;

  if AValue is TJSONArray then Exit(ParseUnion(TJSONArray(AValue), AEnclosing));

  Exit(ParseObject(AsObject(AValue, 'A schema'), AEnclosing));
end;

function TAvroParser.ParseObject(AObj: TJSONObject;
  const AEnclosing: string): TAvroSchema;
var
  TypeText, NameText, NsText, DocText, Text: string;
  Aliases: TArray<string>;
  I, N: Integer;
  Inner: TJSONValue;
  FieldsArr: TJSONArray;
  FieldObj: TJSONObject;
  Field: TAvroField;
  Kind: TAvroType;
  Enclosing: string;
  Existing: TAvroSchema;
begin
  { "type" may itself be a whole schema - that is how a logical type is
    layered on a fixed, and how some generators write a nested definition. }
  Inner := AObj.Values['type'];
  if Inner = nil then
    raise EAvroSchemaError.Create('A schema object must have a "type".');
  if not (Inner is TJSONString) or (Inner is TJSONNumber) then
  begin
    Result := ParseValue(Inner, AEnclosing);
    ApplyLogical(Result, AObj);
    Exit;
  end;
  TypeText := TJSONString(Inner).Value;

  { A bare reference written in object form. }
  if Pos('.', TypeText) > 0 then
  begin
    if FNamed.TryGetValue(TypeText, Existing) then Exit(Existing);
  end
  else if FNamed.TryGetValue(JoinName(AEnclosing, TypeText), Existing) then
    Exit(Existing);

  Kind := PrimitiveOf(TypeText);
  Result := Own(TAvroSchema.Create(Kind));

  if Kind in [TAvroType.Rec, TAvroType.Enum, TAvroType.Fixed] then
  begin
    if not StrAttr(AObj, 'name', NameText) then
      raise EAvroSchemaError.CreateFmt('A %s must have a "name".', [TypeText]);
    if Pos('.', NameText) > 0 then
    begin
      Result.FullName := NameText;
      Result.Namespace := NamespaceOf(NameText);
      Result.Name := Copy(NameText, Result.Namespace.Length + 2, MaxInt);
    end
    else
    begin
      if StrAttr(AObj, 'namespace', NsText) then Result.Namespace := NsText
      else Result.Namespace := AEnclosing;
      Result.Name := NameText;
      Result.FullName := JoinName(Result.Namespace, NameText);
    end;
    if not IsValidAvroFullName(Result.FullName) then
      raise EAvroSchemaError.CreateFmt(
        '"%s" is not a legal Avro name. A name starts with a letter or an ' +
        'underscore and continues with letters, digits and underscores; a ' +
        'full name is such names joined by dots.', [Result.FullName]);
    if StrAttr(AObj, 'doc', DocText) then Result.Doc := DocText;

    Aliases := StrArrayAttr(AObj, 'aliases');
    for I := 0 to Integer(High(Aliases)) do
      if Pos('.', Aliases[I]) = 0 then
        Aliases[I] := JoinName(Result.Namespace, Aliases[I]);
    Result.Aliases := Aliases;

    { Registered BEFORE the fields are parsed, so a record may refer to
      itself. }
    RegisterNamed(Result);
  end;

  Enclosing := AEnclosing;
  if Result.IsNamed then Enclosing := Result.Namespace;

  case Kind of
    TAvroType.Rec:
      begin
        Inner := AObj.Values['fields'];
        if not (Inner is TJSONArray) then
          raise EAvroSchemaError.CreateFmt(
            'record %s must have a "fields" array.', [Result.FullName]);
        FieldsArr := TJSONArray(Inner);
        for I := 0 to FieldsArr.Count - 1 do
        begin
          FieldObj := AsObject(FieldsArr.Items[I],
            'Every entry of "fields"');
          { The name is validated BEFORE the field joins the list, so that
            IndexOfField is asking about the fields already accepted rather
            than about a half-built one whose name is still empty. }
          if not StrAttr(FieldObj, 'name', Text) then
            raise EAvroSchemaError.CreateFmt(
              'Field %d of record %s has no "name".', [I, Result.FullName]);
          if not IsValidAvroName(Text) then
            raise EAvroSchemaError.CreateFmt(
              '"%s" is not a legal Avro field name.', [Text]);
          if Result.IndexOfField(Text) >= 0 then
            raise EAvroSchemaError.CreateFmt(
              'record %s has two fields named "%s".',
              [Result.FullName, Text]);
          Field := TAvroField.Create;
          Result.FFields.Add(Field);
          Field.Name := Text;
          if StrAttr(FieldObj, 'doc', Text) then Field.Doc := Text;
          Field.Aliases := StrArrayAttr(FieldObj, 'aliases');
          if StrAttr(FieldObj, 'order', Text) then
          begin
            if Text = 'descending' then Field.Order := TAvroFieldOrder.Descending
            else if Text = 'ignore' then Field.Order := TAvroFieldOrder.Ignore
            else Field.Order := TAvroFieldOrder.Ascending;
          end;
          if FieldObj.Values['type'] = nil then
            raise EAvroSchemaError.CreateFmt(
              'Field "%s" of record %s has no "type".',
              [Field.Name, Result.FullName]);
          Field.FieldType := ParseValue(FieldObj.Values['type'], Enclosing);
          if FieldObj.Values['default'] <> nil then
            Field.Default := ConvertDefault(FieldObj.Values['default']);
        end;
      end;
    TAvroType.Enum:
      begin
        Result.Symbols := StrArrayAttr(AObj, 'symbols');
        if Length(Result.Symbols) = 0 then
          raise EAvroSchemaError.CreateFmt(
            'enum %s must have a non-empty "symbols" array.',
            [Result.FullName]);
        for I := 0 to Integer(High(Result.Symbols)) do
        begin
          if not IsValidAvroName(Result.Symbols[I]) then
            raise EAvroSchemaError.CreateFmt(
              '"%s" is not a legal enum symbol in %s.',
              [Result.Symbols[I], Result.FullName]);
          if Result.IndexOfSymbol(Result.Symbols[I]) <> I then
            raise EAvroSchemaError.CreateFmt(
              'enum %s lists the symbol "%s" twice.',
              [Result.FullName, Result.Symbols[I]]);
        end;
        if StrAttr(AObj, 'default', Text) then
        begin
          if Result.IndexOfSymbol(Text) < 0 then
            raise EAvroSchemaError.CreateFmt(
              'enum %s has default "%s", which is not one of its symbols.',
              [Result.FullName, Text]);
          Result.EnumDefault := Text;
          Result.HasEnumDefault := True;
        end;
      end;
    TAvroType.Fixed:
      begin
        if not IntAttr(AObj, 'size', N) then
          raise EAvroSchemaError.CreateFmt(
            'fixed %s must have a "size".', [Result.FullName]);
        if N < 0 then
          raise EAvroSchemaError.CreateFmt(
            'fixed %s has a negative size.', [Result.FullName]);
        Result.Size := N;
      end;
    TAvroType.Arr:
      begin
        if AObj.Values['items'] = nil then
          raise EAvroSchemaError.Create('An array must have "items".');
        Result.ItemType := ParseValue(AObj.Values['items'], Enclosing);
      end;
    TAvroType.Map:
      begin
        if AObj.Values['values'] = nil then
          raise EAvroSchemaError.Create('A map must have "values".');
        Result.ValueType := ParseValue(AObj.Values['values'], Enclosing);
      end;
  end;

  ApplyLogical(Result, AObj);
end;

function TAvroParser.Run(const AJson: string): TAvroSchema;
var
  Doc: TJSONValue;
begin
  Doc := TJSONObject.ParseJSONValue(AJson);
  if Doc = nil then
    raise EAvroSchemaError.Create(
      'This is not JSON, so it is not an Avro schema. An Avro schema is a ' +
      'JSON document: a string naming a primitive, an array which is a ' +
      'union, or an object with a "type".');
  try
    FRoot := ParseValue(Doc, '');
  finally
    Doc.Free;
  end;

  { The root takes the arena, and therefore the ownership of every other
    node. It is removed from the arena first so that freeing the arena from
    inside the root's own destructor cannot reach the root. }
  FArena.Extract(FRoot);
  FRoot.FArena := FArena;
  FArena := nil;
  Result := FRoot;
end;

class function TAvroSchema.Parse(const AJson: string): TAvroSchema;
var
  P: TAvroParser;
begin
  P := TAvroParser.Create;
  try
    Result := P.Run(AJson);
  finally
    P.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  WRITING THE SCHEMA BACK OUT
  --------------------------------------------------------------------------- }

type
  TAvroWriterState = class
  public
    Seen: TStringList;
    constructor Create;
    destructor Destroy; override;
    function FirstTime(const AFullName: string): Boolean;
  end;

constructor TAvroWriterState.Create;
begin
  inherited Create;
  Seen := TStringList.Create;
  Seen.Sorted := True;
  Seen.Duplicates := dupIgnore;
  Seen.CaseSensitive := True;
end;

destructor TAvroWriterState.Destroy;
begin
  Seen.Free;
  inherited;
end;

function TAvroWriterState.FirstTime(const AFullName: string): Boolean;
begin
  Result := Seen.IndexOf(AFullName) < 0;
  if Result then Seen.Add(AFullName);
end;

function LogicalNameOf(ASchema: TAvroSchema): string;
begin
  if ASchema.LogicalType = TAvroLogicalType.None then Result := ''
  else Result := ASchema.LogicalName;
end;

function DefaultToJson(ADefault: TAvroDefault): string;
var
  I: Integer;
  S: string;
begin
  case ADefault.Kind of
    TAvroDefaultKind.Null: Result := 'null';
    TAvroDefaultKind.Bool:
      if ADefault.AsBool then Result := 'true' else Result := 'false';
    TAvroDefaultKind.Num:
      if ADefault.IsIntegral then Result := IntToStr(ADefault.AsInt)
      else Result := FloatToStr(ADefault.AsFloat, TFormatSettings.Invariant);
    TAvroDefaultKind.Str: Result := AvroJsonQuote(ADefault.AsStr);
    TAvroDefaultKind.Arr:
      begin
        Result := '[';
        for I := 0 to ADefault.Count - 1 do
        begin
          if I > 0 then Result := Result + ',';
          Result := Result + DefaultToJson(ADefault[I]);
        end;
        Result := Result + ']';
      end;
    TAvroDefaultKind.Obj:
      begin
        Result := '{';
        for I := 0 to ADefault.Count - 1 do
        begin
          if I > 0 then Result := Result + ',';
          S := AvroJsonQuote(ADefault.Names[I]);
          Result := Result + S + ':' + DefaultToJson(ADefault[I]);
        end;
        Result := Result + '}';
      end;
  else
    Result := 'null';
  end;
end;

function SchemaToJson(ASchema: TAvroSchema; AState: TAvroWriterState): string;
var
  I: Integer;
  Parts: TStringList;
  Field: TAvroField;
  Sub: string;
  Logical: string;

  function StrArrayJson(const AValues: TArray<string>): string;
  var
    K: Integer;
  begin
    Result := '[';
    for K := 0 to Integer(High(AValues)) do
    begin
      if K > 0 then Result := Result + ',';
      Result := Result + AvroJsonQuote(AValues[K]);
    end;
    Result := Result + ']';
  end;

begin
  if ASchema.IsNamed and not AState.FirstTime(ASchema.FullName) then
    Exit(AvroJsonQuote(ASchema.FullName));

  Logical := LogicalNameOf(ASchema);

  if ASchema.SchemaType = TAvroType.Union then
  begin
    Result := '[';
    for I := 0 to ASchema.BranchCount - 1 do
    begin
      if I > 0 then Result := Result + ',';
      Result := Result + SchemaToJson(ASchema.Branches[I], AState);
    end;
    Result := Result + ']';
    Exit;
  end;

  if not ASchema.IsNamed and (ASchema.SchemaType in [TAvroType.Null,
      TAvroType.Bool, TAvroType.Int, TAvroType.Long, TAvroType.Float,
      TAvroType.Double, TAvroType.Bytes, TAvroType.Str]) and (Logical = '') then
    Exit(AvroJsonQuote(ASchema.TypeName));

  Parts := TStringList.Create;
  try
    Parts.Add('"type":' + AvroJsonQuote(ASchema.TypeName));
    if ASchema.IsNamed then
      Parts.Add('"name":' + AvroJsonQuote(ASchema.FullName));
    if ASchema.Doc <> '' then Parts.Add('"doc":' + AvroJsonQuote(ASchema.Doc));
    if Length(ASchema.Aliases) > 0 then
      Parts.Add('"aliases":' + StrArrayJson(ASchema.Aliases));

    case ASchema.SchemaType of
      TAvroType.Rec:
        begin
          Sub := '';
          for I := 0 to ASchema.FieldCount - 1 do
          begin
            Field := ASchema.Fields[I];
            if I > 0 then Sub := Sub + ',';
            Sub := Sub + '{"name":' + AvroJsonQuote(Field.Name);
            Sub := Sub + ',"type":' + SchemaToJson(Field.FieldType, AState);
            if Field.Doc <> '' then
              Sub := Sub + ',"doc":' + AvroJsonQuote(Field.Doc);
            if Length(Field.Aliases) > 0 then
              Sub := Sub + ',"aliases":' + StrArrayJson(Field.Aliases);
            if Field.Default <> nil then
              Sub := Sub + ',"default":' + DefaultToJson(Field.Default);
            if Field.Order = TAvroFieldOrder.Descending then
              Sub := Sub + ',"order":"descending"'
            else if Field.Order = TAvroFieldOrder.Ignore then
              Sub := Sub + ',"order":"ignore"';
            Sub := Sub + '}';
          end;
          Parts.Add('"fields":[' + Sub + ']');
        end;
      TAvroType.Enum:
        begin
          Parts.Add('"symbols":' + StrArrayJson(ASchema.Symbols));
          if ASchema.HasEnumDefault then
            Parts.Add('"default":' + AvroJsonQuote(ASchema.EnumDefault));
        end;
      TAvroType.Arr:
        Parts.Add('"items":' + SchemaToJson(ASchema.ItemType, AState));
      TAvroType.Map:
        Parts.Add('"values":' + SchemaToJson(ASchema.ValueType, AState));
      TAvroType.Fixed:
        Parts.Add('"size":' + IntToStr(ASchema.Size));
    end;

    if Logical <> '' then
    begin
      Parts.Add('"logicalType":' + AvroJsonQuote(Logical));
      if ASchema.LogicalType = TAvroLogicalType.Decimal then
      begin
        Parts.Add('"precision":' + IntToStr(ASchema.Precision));
        Parts.Add('"scale":' + IntToStr(ASchema.Scale));
      end;
    end;

    Result := '{';
    for I := 0 to Parts.Count - 1 do
    begin
      if I > 0 then Result := Result + ',';
      Result := Result + Parts[I];
    end;
    Result := Result + '}';
  finally
    Parts.Free;
  end;
end;

function TAvroSchema.ToJson: string;
var
  State: TAvroWriterState;
begin
  State := TAvroWriterState.Create;
  try
    Result := SchemaToJson(Self, State);
  finally
    State.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  PARSING CANONICAL FORM

  The specification's transformation, rule by rule: primitives collapse to a
  bare string, names become fullnames, every attribute that does not affect
  how data is parsed is stripped - doc, aliases, field defaults, order, and
  the logical-type annotations - and what is left is written in a fixed
  attribute order with no whitespace.

  Stripping the logical types is the surprising one and it is deliberate:
  the canonical form exists to answer "do these two schemas read the same
  bytes", and a decimal annotation does not change a single byte of the
  bytes a decimal occupies.
  --------------------------------------------------------------------------- }

function SchemaToCanonical(ASchema: TAvroSchema;
  AState: TAvroWriterState): string;
var
  I: Integer;
  Field: TAvroField;
  Sub: string;
begin
  if ASchema.IsNamed and not AState.FirstTime(ASchema.FullName) then
    Exit(AvroJsonQuote(ASchema.FullName));

  case ASchema.SchemaType of
    TAvroType.Union:
      begin
        Result := '[';
        for I := 0 to ASchema.BranchCount - 1 do
        begin
          if I > 0 then Result := Result + ',';
          Result := Result + SchemaToCanonical(ASchema.Branches[I], AState);
        end;
        Result := Result + ']';
      end;
    TAvroType.Rec:
      begin
        Result := '{"name":' + AvroJsonQuote(ASchema.FullName) +
          ',"type":"record","fields":[';
        for I := 0 to ASchema.FieldCount - 1 do
        begin
          Field := ASchema.Fields[I];
          if I > 0 then Result := Result + ',';
          Result := Result + '{"name":' + AvroJsonQuote(Field.Name) +
            ',"type":' + SchemaToCanonical(Field.FieldType, AState) + '}';
        end;
        Result := Result + ']}';
      end;
    TAvroType.Enum:
      begin
        Sub := '';
        for I := 0 to Integer(High(ASchema.Symbols)) do
        begin
          if I > 0 then Sub := Sub + ',';
          Sub := Sub + AvroJsonQuote(ASchema.Symbols[I]);
        end;
        Result := '{"name":' + AvroJsonQuote(ASchema.FullName) +
          ',"type":"enum","symbols":[' + Sub + ']}';
      end;
    TAvroType.Fixed:
      Result := '{"name":' + AvroJsonQuote(ASchema.FullName) +
        ',"type":"fixed","size":' + IntToStr(ASchema.Size) + '}';
    TAvroType.Arr:
      Result := '{"type":"array","items":' +
        SchemaToCanonical(ASchema.ItemType, AState) + '}';
    TAvroType.Map:
      Result := '{"type":"map","values":' +
        SchemaToCanonical(ASchema.ValueType, AState) + '}';
  else
    Result := AvroJsonQuote(ASchema.TypeName);
  end;
end;

function TAvroSchema.CanonicalForm: string;
var
  State: TAvroWriterState;
begin
  State := TAvroWriterState.Create;
  try
    Result := SchemaToCanonical(Self, State);
  finally
    State.Free;
  end;
end;

function TAvroSchema.Fingerprint: UInt64;
begin
  Result := AvroFingerprint64(StringToUtf8Bytes(CanonicalForm));
end;


{ --- TAvroSerializationContext -------------------------------------------- }

constructor TAvroSerializationContext.Create(ASchema: TAvroSchema;
  AReaderSchema: TAvroSchema);
begin
  inherited Create;
  if ASchema = nil then
    raise EAvroSchemaError.Create(
      'An Avro context needs a schema. Avro bytes are meaningless without ' +
      'one, which is the whole reason the context exists.');
  FSchema := ASchema;
  FReaderSchema := AReaderSchema;
end;

function TAvroSerializationContext.Format: TSerializationFormat;
begin
  Result := TSerializationFormat.Avro;
end;

function TAvroSerializationContext.Describe: string;
begin
  Result := FSchema.Describe;
  if FReaderSchema <> nil then
    Result := Result + ' resolved into ' + FReaderSchema.Describe;
end;

end.
