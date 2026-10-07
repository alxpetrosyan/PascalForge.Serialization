{*******************************************************************************
  PascalForge.Dynamic

  The dynamic structural model of PascalForge.Serialization.

  Responsibilities
    - TDynamicValue, TDynamicObject, TDynamicArray: a document as values,
      with exact member names, insertion order and explicit ownership.
    - Building one fluently, importing and merging, cloning and comparing.
    - TDynamicSerializer: a Delphi value projected onto a dynamic value
      through RTTI, and read back.

  Registration
    None. Dynamic is not a TSerializationFormat: it is the value every
    format reads into and writes from (T<Format>Serializer.ToDynamic and
    FromDynamic, TSerialization.ToDynamic and FromDynamic), and needs no
    registration of its own.

  Threading
    A dynamic value is an ordinary object: one thread builds or changes it
    at a time. Reading one tree from several threads at once is safe while
    nobody changes it.

  Documentation
    docs/dynamic.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Dynamic;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  ONE STRUCTURAL MODEL

  A document read without a Delphi type - JSON with no DTO, a BSON
  document from a database, a CBOR message from a device - is a tree of
  values. Every format here reads into this tree and writes from it, so
  that a value built once can be written as JSON, BSON, CBOR or YAML, and a
  document read in one format can be written in another.

      Obj := TDynamicObject.Create;
      try
        Obj
          .Append('name', 'Erin')
          .Append('age', 35);
        Obj.AddObject('address')
          .Append('city', 'Uptown');
        Json := TJsonSerializer.FromDynamic(Obj);
        Bson := TBsonSerializer.FromDynamic(Obj);
      finally
        Obj.Free;
      end;

  It is deliberately NOT a JSON value model. Unsigned integers past
  High(Int64), exact decimals, bytes, dates, times and instants are their
  own kinds, because a format carrying them natively must not lose them in
  the middle of a conversion; and a value a source format has that none of
  those names - a BSON ObjectId, a CBOR semantic tag, a YAML alias - is
  carried as Extended, its source type's own name and its parts, never
  flattened to text.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections;

type
  { A broken rule of the model itself: a duplicate member name, a value
    that already belongs to another container, a cycle, an index out of
    range, a member asked for that is not there, a kind asked for that the
    value is not. }
  EDynamicError = class(Exception);

  { ------------------------------------------------------------------------
    THE KINDS

    UInt   for a value ABOVE High(Int64) only: CBOR major type 0 and
           MessagePack uint64 reach 2^64-1, and half of that range is not an
           Int64 at all. Anything that fits signed is Int, so every ordinary
           number has one representation.
    Decimal  exact, at any precision, held as its canonical text: Avro's
           decimal and CBOR tag 4 are not Doubles.
    Date, Time, DateTime  three semantic claims sharing TDateTime storage. A
           Date has no time half and a Time no date half; neither is ever
           inferred from text - "2026-09-22" in a JSON string is Str.
    Extended  a source-native value the other kinds do not name: a tag from
           TDynamicTag and a payload, documented per tag.
    ------------------------------------------------------------------------ }
  TDynamicKind = (Null, Bool, Int, UInt, Float, Decimal, Str, Bytes,
    Date, Time, DateTime,
    Arr, Obj, Extended);

  { The tags an Extended value may carry. Each is the name the SOURCE
    format's own specification uses, so it can be looked up there. They are
    identifiers inside this process only: no destination writes a tag into a
    document unless a published standard for that destination says to. }
  TDynamicTag = record
  public const
    ObjectId    = 'objectid';
    Decimal128  = 'decimal128';
    Regex       = 'regex';
    JavaScript  = 'javascript';
    JavaScriptScope = 'javascriptscope';
    Symbol      = 'symbol';
    Undefined   = 'undefined';
    DbPointer   = 'dbpointer';
    MinKey      = 'minkey';
    MaxKey      = 'maxkey';
    { A 64-bit BSON timestamp: increment in the low 32 bits, seconds in the
      high 32. Not a date - BSON has a separate type for that. }
    Timestamp   = 'timestamp';
    { Binary with a subtype byte other than the generic 0. Plain binary is
      TDynamicKind.Bytes and needs no tag. }
    BinarySubtype = 'binarysubtype';
    { A CBOR semantic tag and a MessagePack extension a reader did not
      recognise, kept so that the document can be written out unchanged.
      Payload: an object - "number" (Int) and "value" for a CBOR tag, "type"
      (Int) and "data" (Bytes) for a MessagePack extension. }
    CborTag = 'cbortag';
    MsgPackExtension = 'msgpackextension';
    { An integer too large for Int64 or UInt64 - CBOR tags 2 and 3, ASN.1
      INTEGER. Payload: Bytes, the big-endian magnitude; the sign is in the
      tag's name, and a negative one's magnitude is the value's own (n for
      -n), not CBOR's n-1. }
    BigIntPositive = 'bigint';
    BigIntNegative = 'bigintnegative';
    { YAML says two members of a document are THE SAME NODE. Payload: Str,
      the anchor name. }
    YamlAlias = 'yamlalias';
    { A tag the format's own vocabulary defines and this library has no
      better mapping for - a YAML "!!" tag, an ASN.1 application tag.
      Payload: an object, "tag" (Str) and "value". }
    FormatTag = 'formattag';
  end;

  { What happens when an imported member's name is already taken. }
  TDynamicCollision = (
    { Refused before anything changes: EDynamicError names the member. }
    Error,
    { The member already there stays; the incoming one is dropped. }
    KeepExisting,
    { The incoming member replaces the one there, in its position. }
    Overwrite,
    { Two objects merge, member by member, with the same rule all the way
      down. Any other pair - two arrays included - is an Overwrite: arrays
      are never concatenated or merged index by index. }
    DeepMerge
  );

  TDynamicObject = class;
  TDynamicArray = class;

  { ------------------------------------------------------------------------
    A VALUE

    Scalars are made with the New* functions and never change. An object
    and an array are TDynamicObject and TDynamicArray, made with Create (or
    NewObject, NewArray) and built through their own methods.

    OWNERSHIP. A value belongs to at most one container, which frees it.
    A value that already has a Parent is refused by every container - take
    it out with Extract first, or Clone it - and so is the container itself
    or one of its ancestors, so a tree can never hold a cycle. The root of
    a tree belongs to whoever made it.

    The generic read surface - Count, Items, Names, Find - works on any
    value: a scalar has no children, an array has unnamed ones and an object
    named ones. It is what a consumer walking an arbitrary tree uses; one
    that knows it has an object uses AsObject.
    ------------------------------------------------------------------------ }
  TDynamicValue = class
  private
    FKind: TDynamicKind;
    FBool: Boolean;
    FInt: Int64;
    FFloat: Double;
    FStr: string;
    FBytes: TBytes;
    FDateTime: TDateTime;
    FTag: string;
    FPayload: TDynamicValue;
    FParent: TDynamicValue;
    function IsSelfOrAncestorOf(AValue: TDynamicValue): Boolean;
    procedure CheckAttachable(AValue: TDynamicValue);
    procedure WrongKind(const AAccessor, AExpected: string);
  protected
    constructor CreateKind(AKind: TDynamicKind);
    function GetCount: Integer; virtual;
    function GetItem(AIndex: Integer): TDynamicValue; virtual;
    function GetName(AIndex: Integer): string; virtual;
    function SameMembers(AOther: TDynamicValue): Boolean; virtual;
  public
    destructor Destroy; override;

    class function NewNull: TDynamicValue; static;
    class function NewBool(AValue: Boolean): TDynamicValue; static;
    class function NewInt(AValue: Int64): TDynamicValue; static;
    { Any UInt64. One that fits signed comes back as Int: there is one
      representation of every ordinary number. }
    class function NewUInt(AValue: UInt64): TDynamicValue; static;
    class function NewFloat(AValue: Double): TDynamicValue; static;
    { ADigits is canonical decimal text - an optional sign, digits, an
      optional point, an optional exponent - exact at any precision. }
    class function NewDecimal(const ADigits: string): TDynamicValue; static;
    class function NewStr(const AValue: string): TDynamicValue; static;
    class function NewBytes(const AValue: TBytes): TDynamicValue; static;
    { The bytes are copied: the value keeps its own. }
    { The time half of a date and the date half of a time are dropped, not
      carried invisibly. }
    class function NewDate(AValue: TDateTime): TDynamicValue; static;
    class function NewTime(AValue: TDateTime): TDynamicValue; static;
    class function NewDateTime(AValue: TDateTime): TDynamicValue; static;
    class function NewArray: TDynamicArray; static;
    class function NewObject: TDynamicObject; static;
    { A source-native value. ATag is one of TDynamicTag; APayload is
      ADOPTED - freed with this value, and freed here if ATag is empty. A nil
      payload is a Null one. }
    class function NewExtended(const ATag: string;
      APayload: TDynamicValue): TDynamicValue; static;

    { The name of a kind, for messages. }
    class function KindName(AKind: TDynamicKind): string; static;

    property Kind: TDynamicKind read FKind;
    function IsNull: Boolean;
    function IsObject: Boolean;
    function IsArray: Boolean;

    { THE SCALAR PARTS. Each reads its own kind and refuses every other
      with EDynamicError - a wrong-kind read never returns a zero, an empty
      value or another kind's storage reinterpreted. The compatible readings
      are exactly these, all exact:

        AsUInt      a UInt, or an Int that is not negative;
        AsDecimal   a Decimal, or an Int or UInt as its decimal digits;
        AsDateTime  a Date, a Time or a DateTime (one storage, three
                    claims - Kind says which).

      An Int is never read as a UInt's bits, a UInt never as an Int, a
      number never as text and text never as a number. }
    function AsBool: Boolean;
    function AsInt: Int64;
    function AsUInt: UInt64;
    function AsFloat: Double;
    function AsDecimal: string;
    function AsStr: string;
    { A copy: a value never changes, and its bytes are not shared with the
      caller. }
    function AsBytes: TBytes;
    function AsDateTime: TDateTime;

    { This value as an object or an array; EDynamicError if it is not one. }
    function AsObject: TDynamicObject;
    function AsArray: TDynamicArray;

    { THE GENERIC READ SURFACE. Count is 0 for a scalar - an Extended
      value's payload is ExtendedValue, not a child - and Items raises for
      one. Names[I] is '' outside an object. Find is the member spelled
      EXACTLY AName, or nil; 'name' and 'Name' are different members. }
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TDynamicValue read GetItem; default;
    property Names[AIndex: Integer]: string read GetName;
    function Find(const AName: string): TDynamicValue; virtual;

    { For Extended: the tag and the payload (still owned by this value).
      '' and nil for every other kind. }
    property ExtendedTag: string read FTag;
    function ExtendedValue: TDynamicValue;
    function IsTagged(const ATag: string): Boolean;

    { The container this value belongs to, or nil for a root. }
    property Parent: TDynamicValue read FParent;

    { A deep copy, a new root the caller owns. }
    function Clone: TDynamicValue; virtual;
    { Deep equality: same kind and same value, all the way down. Arrays
      compare in order; objects compare member by member, by exact name,
      whatever order the members were added in. Floats compare by value, so
      0.0 equals -0.0 and NaN equals NaN. Decimals compare as their text. }
    function Equals(Obj: TObject): Boolean; override;
    function GetHashCode: Integer; override;
    { A one-line rendering, for diagnostics and test failures. }
    function Describe: string;
  end;

  { ------------------------------------------------------------------------
    AN OBJECT

    Members keep their insertion order and their exact names. A name is
    there at most once: Append refuses a name already taken, and replacing
    a member is the explicit AppendOrReplace.

    Append and InsertAt return the object itself, for chaining; AddObject
    and AddArray return the new child. A value passed in moves into the
    object only when the call succeeds - on a refusal the caller still owns
    it. Adopt is the form for a value built inline: it owns it in every
    case and frees it on refusal.

    A Delphi value - an object, a record, a list, a scalar - is projected
    through RTTI (see TDynamicSerializer):

        Obj.Append('person', Person);   the projection, as one member
        Obj.Append(Person);             the projection's members, imported
    ------------------------------------------------------------------------ }
  TDynamicObject = class(TDynamicValue)
  strict private
    FItems: TObjectList<TDynamicValue>;
    FNames: TList<string>;
    { Built once the object is big enough for a scan to matter. }
    FIndex: TDictionary<string, TDynamicValue>;
    procedure Attach(AIndex: Integer; const AName: string;
      AValue: TDynamicValue);
    procedure Detach(AIndex: Integer);
    procedure ReplaceAt(AIndex: Integer; AValue: TDynamicValue);
    procedure CheckInsertIndex(AIndex: Integer);
    procedure AdoptAt(AIndex: Integer; const AName: string;
      AValue: TDynamicValue);
    function Projected(const AValue: TValue): TDynamicValue;
    procedure MergeMembers(ASource: TDynamicObject;
      ACollision: TDynamicCollision; AMove: Boolean);
  protected
    function GetCount: Integer; override;
    function GetItem(AIndex: Integer): TDynamicValue; override;
    function GetName(AIndex: Integer): string; override;
    function SameMembers(AOther: TDynamicValue): Boolean; override;
  public
    constructor Create;
    destructor Destroy; override;

    { --- building --- }
    function Append(const AName: string;
      AValue: TDynamicValue): TDynamicObject; overload;
    function Append(const AName, AValue: string): TDynamicObject; overload;
    function Append(const AName: string; AValue: Int64): TDynamicObject; overload;
    function Append(const AName: string; AValue: Boolean): TDynamicObject; overload;
    { Any Delphi value, projected; a TDynamicValue moves in as itself. }
    function Append<T>(const AName: string;
      const AValue: T): TDynamicObject; overload;
    { The members of a Delphi value's projection, which must be an object -
      a class or a record, say - imported under TDynamicCollision.Error. A
      TDynamicObject's members are imported as copies; the caller keeps it. }
    function Append<T>(const AValue: T): TDynamicObject; overload;
    function AppendNull(const AName: string): TDynamicObject;
    { The untyped forms of the two generic Appends. }
    function AppendValue(const AName: string;
      const AValue: TValue): TDynamicObject; overload;
    function AppendValue(const AValue: TValue): TDynamicObject; overload;

    { At AIndex, 0 to Count; InsertAt(Count, ...) is Append. }
    function InsertAt(AIndex: Integer; const AName: string;
      AValue: TDynamicValue): TDynamicObject; overload;
    function InsertAt(AIndex: Integer;
      const AName, AValue: string): TDynamicObject; overload;
    function InsertAt(AIndex: Integer; const AName: string;
      AValue: Int64): TDynamicObject; overload;
    function InsertAt(AIndex: Integer; const AName: string;
      AValue: Boolean): TDynamicObject; overload;
    function InsertAt<T>(AIndex: Integer; const AName: string;
      const AValue: T): TDynamicObject; overload;
    function InsertValueAt(AIndex: Integer; const AName: string;
      const AValue: TValue): TDynamicObject;

    { A new, empty child, returned for building. }
    function AddObject(const AName: string): TDynamicObject;
    function AddArray(const AName: string): TDynamicArray;

    { Appends AValue and owns it whatever happens: on a refusal it is freed
      - unless it belongs to another container, or is this object's own
      ancestor, which are never freed here. }
    function Adopt(const AName: string; AValue: TDynamicValue): TDynamicObject;

    { The member called AName is replaced, in its position, and the old one
      freed; or, if there is none, AValue is appended. }
    function AppendOrReplace(const AName: string;
      AValue: TDynamicValue): TDynamicObject;

    { --- reading --- }
    function Find(const AName: string): TDynamicValue; override;
    function Contains(const AName: string): Boolean;
    function IndexOf(const AName: string): Integer;
    { The member called AName; EDynamicError when there is none. }
    function Get(const AName: string): TDynamicValue;

    { --- taking apart --- }
    { Takes the member out and returns it: the caller owns it, and it is a
      root again. nil when there is no such member. }
    function Extract(const AName: string): TDynamicValue;
    function ExtractAt(AIndex: Integer): TDynamicValue;
    { Takes the member out and frees it. False when there is none. }
    function Remove(const AName: string): Boolean;
    procedure Delete(AIndex: Integer);
    procedure Clear;

    { --- combining --- }
    { ASource's members, deep-copied: ASource is not changed. }
    function Import(ASource: TDynamicObject;
      ACollision: TDynamicCollision = TDynamicCollision.Error): TDynamicObject;
    { ASource's members MOVED here: ASource is left empty and still belongs
      to its owner. A member that loses a collision is freed. }
    function MoveFrom(ASource: TDynamicObject;
      ACollision: TDynamicCollision = TDynamicCollision.Error): TDynamicObject;

    function Clone: TDynamicValue; override;
  end;

  { ------------------------------------------------------------------------
    AN ARRAY

    Order is the value. Appending an array appends it as ONE nested value;
    AppendRange is the explicit way to add another array's items.
    Ownership works as it does for an object.
    ------------------------------------------------------------------------ }
  TDynamicArray = class(TDynamicValue)
  strict private
    FItems: TObjectList<TDynamicValue>;
    procedure Attach(AIndex: Integer; AValue: TDynamicValue);
    procedure CheckInsertIndex(AIndex: Integer);
    procedure AdoptAt(AIndex: Integer; AValue: TDynamicValue);
  protected
    function GetCount: Integer; override;
    function GetItem(AIndex: Integer): TDynamicValue; override;
    function SameMembers(AOther: TDynamicValue): Boolean; override;
  public
    constructor Create;
    destructor Destroy; override;

    function Append(AValue: TDynamicValue): TDynamicArray; overload;
    function Append(const AValue: string): TDynamicArray; overload;
    function Append(AValue: Int64): TDynamicArray; overload;
    function Append(AValue: Boolean): TDynamicArray; overload;
    { Any Delphi value, projected, as one item; a TDynamicValue moves in as
      itself. }
    function Append<T>(const AValue: T): TDynamicArray; overload;
    function AppendNull: TDynamicArray;
    function AppendValue(const AValue: TValue): TDynamicArray;

    function InsertAt(AIndex: Integer; AValue: TDynamicValue): TDynamicArray; overload;
    function InsertAt(AIndex: Integer; const AValue: string): TDynamicArray; overload;
    function InsertAt(AIndex: Integer; AValue: Int64): TDynamicArray; overload;
    function InsertAt(AIndex: Integer; AValue: Boolean): TDynamicArray; overload;
    function InsertAt<T>(AIndex: Integer; const AValue: T): TDynamicArray; overload;
    function InsertValueAt(AIndex: Integer; const AValue: TValue): TDynamicArray;

    function AddObject: TDynamicObject;
    function AddArray: TDynamicArray;

    { Appends AValue and owns it whatever happens, as TDynamicObject.Adopt. }
    function Adopt(AValue: TDynamicValue): TDynamicArray;

    { Copies of ASource's items, appended one by one: the explicit flatten. }
    function AppendRange(ASource: TDynamicArray): TDynamicArray;

    { The item at AIndex replaced, the old one freed. }
    function ReplaceAt(AIndex: Integer; AValue: TDynamicValue): TDynamicArray;
    function ExtractAt(AIndex: Integer): TDynamicValue;
    procedure Delete(AIndex: Integer);
    procedure Clear;

    function Clone: TDynamicValue; override;
  end;

  { ------------------------------------------------------------------------
    DELPHI VALUES <-> DYNAMIC

    The same Delphi surface every serializer here sees: public and
    published fields and readable properties, the general attributes
    [SerializationName], [SerializationIgnore] and [SerializationEnum],
    TNullable<T>, lists, dictionaries, sets, enumerations, static and
    dynamic arrays, Variants. A class or a record becomes an object, a list
    or an array an array, a dictionary with string keys an object.

    Serialize returns a new root the caller owns. Deserialize<T> returns a
    new value - for a class, a new instance the caller owns. Populate fills
    an existing instance. Dynamic needs no registration.
    ------------------------------------------------------------------------ }
  TDynamicSerializer = class
  public
    class function Serialize<T>(const AValue: T): TDynamicValue; overload; static;
    class function Serialize(const AValue: TValue): TDynamicValue; overload; static;
    class function Deserialize<T>(AValue: TDynamicValue): T; overload; static;
    class function Deserialize(AValue: TDynamicValue;
      ATypeInfo: PTypeInfo): TValue; overload; static;
    class procedure Populate(AInstance: TObject; AValue: TDynamicValue); static;
  end;

implementation

uses
  System.Math, System.Hash,
  PascalForge.Serialization.Core,
  PascalForge.Dynamic.Internal;

{ =========================================================================
  TDynamicValue
  ========================================================================= }

constructor TDynamicValue.CreateKind(AKind: TDynamicKind);
begin
  inherited Create;
  FKind := AKind;
end;

destructor TDynamicValue.Destroy;
begin
  FPayload.Free;
  inherited Destroy;
end;

class function TDynamicValue.NewNull: TDynamicValue;
begin
  Result := TDynamicValue.CreateKind(TDynamicKind.Null);
end;

class function TDynamicValue.NewBool(AValue: Boolean): TDynamicValue;
begin
  Result := TDynamicValue.CreateKind(TDynamicKind.Bool);
  Result.FBool := AValue;
end;

class function TDynamicValue.NewInt(AValue: Int64): TDynamicValue;
begin
  Result := TDynamicValue.CreateKind(TDynamicKind.Int);
  Result.FInt := AValue;
end;

class function TDynamicValue.NewUInt(AValue: UInt64): TDynamicValue;
begin
  if AValue <= UInt64(High(Int64)) then Exit(NewInt(Int64(AValue)));
  Result := TDynamicValue.CreateKind(TDynamicKind.UInt);
  Result.FInt := Int64(AValue);
end;

class function TDynamicValue.NewFloat(AValue: Double): TDynamicValue;
begin
  Result := TDynamicValue.CreateKind(TDynamicKind.Float);
  Result.FFloat := AValue;
end;

class function TDynamicValue.NewDecimal(const ADigits: string): TDynamicValue;
begin
  Result := TDynamicValue.CreateKind(TDynamicKind.Decimal);
  Result.FStr := ADigits;
end;

class function TDynamicValue.NewStr(const AValue: string): TDynamicValue;
begin
  Result := TDynamicValue.CreateKind(TDynamicKind.Str);
  Result.FStr := AValue;
end;

class function TDynamicValue.NewBytes(const AValue: TBytes): TDynamicValue;
begin
  Result := TDynamicValue.CreateKind(TDynamicKind.Bytes);
  { A copy, so that nothing the caller does to its array afterwards changes
    a value that is documented never to change. }
  Result.FBytes := Copy(AValue);
end;

class function TDynamicValue.NewDate(AValue: TDateTime): TDynamicValue;
begin
  Result := TDynamicValue.CreateKind(TDynamicKind.Date);
  Result.FDateTime := System.Int(AValue);
end;

class function TDynamicValue.NewTime(AValue: TDateTime): TDynamicValue;
begin
  { Frac is negative for a negative TDateTime, and a time of day has no
    sign. }
  Result := TDynamicValue.CreateKind(TDynamicKind.Time);
  Result.FDateTime := System.Frac(System.Abs(AValue));
end;

class function TDynamicValue.NewDateTime(AValue: TDateTime): TDynamicValue;
begin
  Result := TDynamicValue.CreateKind(TDynamicKind.DateTime);
  Result.FDateTime := AValue;
end;

class function TDynamicValue.NewArray: TDynamicArray;
begin
  Result := TDynamicArray.Create;
end;

class function TDynamicValue.NewObject: TDynamicObject;
begin
  Result := TDynamicObject.Create;
end;

class function TDynamicValue.NewExtended(const ATag: string;
  APayload: TDynamicValue): TDynamicValue;
begin
  if ATag = '' then
  begin
    APayload.Free;
    raise EDynamicError.Create(
      'An extended value has to say which source type it came from.');
  end;
  if (APayload <> nil) and (APayload.FParent <> nil) then
    raise EDynamicError.Create('The payload of an extended value already ' +
      'belongs to a container. Extract it, or pass a Clone.');
  Result := TDynamicValue.CreateKind(TDynamicKind.Extended);
  Result.FTag := ATag;
  if APayload = nil then
  try
    APayload := TDynamicValue.NewNull;
  except
    Result.Free;
    raise;
  end;
  Result.FPayload := APayload;
  APayload.FParent := Result;
end;

class function TDynamicValue.KindName(AKind: TDynamicKind): string;
begin
  case AKind of
    TDynamicKind.Null:     Result := 'null';
    TDynamicKind.Bool:     Result := 'boolean';
    TDynamicKind.Int:      Result := 'integer';
    TDynamicKind.UInt:     Result := 'unsigned integer';
    TDynamicKind.Float:    Result := 'float';
    TDynamicKind.Decimal:  Result := 'decimal';
    TDynamicKind.Str:      Result := 'string';
    TDynamicKind.Bytes:    Result := 'binary';
    TDynamicKind.Date:     Result := 'date';
    TDynamicKind.Time:     Result := 'time';
    TDynamicKind.DateTime: Result := 'datetime';
    TDynamicKind.Arr:      Result := 'array';
    TDynamicKind.Obj:      Result := 'object';
  else
    Result := 'extended';
  end;
end;

function TDynamicValue.IsNull: Boolean;
begin
  Result := FKind = TDynamicKind.Null;
end;

function TDynamicValue.IsObject: Boolean;
begin
  Result := FKind = TDynamicKind.Obj;
end;

function TDynamicValue.IsArray: Boolean;
begin
  Result := FKind = TDynamicKind.Arr;
end;

procedure TDynamicValue.WrongKind(const AAccessor, AExpected: string);
begin
  if FKind in [TDynamicKind.Arr, TDynamicKind.Obj] then
    raise EDynamicError.CreateFmt('%s reads %s; this value is %s.',
      [AAccessor, AExpected, KindName(FKind)]);
  raise EDynamicError.CreateFmt('%s reads %s; this value is %s (%s).',
    [AAccessor, AExpected, KindName(FKind), Describe]);
end;

function TDynamicValue.AsBool: Boolean;
begin
  if FKind <> TDynamicKind.Bool then WrongKind('AsBool', 'a boolean');
  Result := FBool;
end;

function TDynamicValue.AsInt: Int64;
begin
  { Signed only: a UInt is above High(Int64) by construction, so reading
    its bits as an Int64 would be a different, negative number. }
  if FKind <> TDynamicKind.Int then WrongKind('AsInt', 'an integer');
  Result := FInt;
end;

function TDynamicValue.AsUInt: UInt64;
begin
  case FKind of
    TDynamicKind.UInt: Result := UInt64(FInt);
    TDynamicKind.Int:
      begin
        { The same number, read unsigned - never a negative one's two's
          complement. }
        if FInt < 0 then
          raise EDynamicError.CreateFmt('AsUInt reads an unsigned number; ' +
            'this value is the negative integer %d.', [FInt]);
        Result := UInt64(FInt);
      end;
  else
    WrongKind('AsUInt', 'an unsigned integer');
    Result := 0;
  end;
end;

function TDynamicValue.AsFloat: Double;
begin
  if FKind <> TDynamicKind.Float then WrongKind('AsFloat', 'a float');
  Result := FFloat;
end;

function TDynamicValue.AsDecimal: string;
begin
  case FKind of
    TDynamicKind.Decimal: Result := FStr;
    TDynamicKind.Int:     Result := IntToStr(FInt);
    TDynamicKind.UInt:    Result := UIntToStr(UInt64(FInt));
  else
    { A Double is not exactly a decimal: rendering one as though it were is
      how a converter starts lying. }
    WrongKind('AsDecimal', 'an exact number');
    Result := '';
  end;
end;

function TDynamicValue.AsStr: string;
begin
  if FKind <> TDynamicKind.Str then WrongKind('AsStr', 'a string');
  Result := FStr;
end;

function TDynamicValue.AsBytes: TBytes;
begin
  if FKind <> TDynamicKind.Bytes then WrongKind('AsBytes', 'binary');
  Result := Copy(FBytes);
end;

function TDynamicValue.AsDateTime: TDateTime;
begin
  if not (FKind in [TDynamicKind.Date, TDynamicKind.Time,
     TDynamicKind.DateTime]) then
    WrongKind('AsDateTime', 'a date, a time or a date-time');
  Result := FDateTime;
end;

function TDynamicValue.AsObject: TDynamicObject;
begin
  if FKind <> TDynamicKind.Obj then WrongKind('AsObject', 'an object');
  Result := TDynamicObject(Self);
end;

function TDynamicValue.AsArray: TDynamicArray;
begin
  if FKind <> TDynamicKind.Arr then WrongKind('AsArray', 'an array');
  Result := TDynamicArray(Self);
end;

function TDynamicValue.GetCount: Integer;
begin
  Result := 0;
end;

function TDynamicValue.GetItem(AIndex: Integer): TDynamicValue;
begin
  raise EDynamicError.CreateFmt('A %s value has no children.',
    [KindName(FKind)]);
end;

function TDynamicValue.GetName(AIndex: Integer): string;
begin
  Result := '';
end;

function TDynamicValue.Find(const AName: string): TDynamicValue;
begin
  Result := nil;
end;

function TDynamicValue.ExtendedValue: TDynamicValue;
begin
  if FKind <> TDynamicKind.Extended then Exit(nil);
  Result := FPayload;
end;

function TDynamicValue.IsTagged(const ATag: string): Boolean;
begin
  Result := (FKind = TDynamicKind.Extended) and (FTag = ATag);
end;

function TDynamicValue.IsSelfOrAncestorOf(AValue: TDynamicValue): Boolean;
var
  Walk: TDynamicValue;
begin
  Walk := AValue;
  while Walk <> nil do
  begin
    if Walk = Self then Exit(True);
    Walk := Walk.FParent;
  end;
  Result := False;
end;

procedure TDynamicValue.CheckAttachable(AValue: TDynamicValue);
begin
  if AValue = nil then
    raise EDynamicError.Create('A container holds values, not nil. Use ' +
      'TDynamicValue.NewNull, or AppendNull, for a null.');
  if AValue.FParent <> nil then
    raise EDynamicError.CreateFmt('This %s value already belongs to a ' +
      'container, which owns it. Extract it from there first, or add a Clone.',
      [KindName(AValue.FKind)]);
  { A container cannot hold itself or anything above it: that would be a
    cycle, and nothing could ever free it. }
  if AValue.IsSelfOrAncestorOf(Self) then
    raise EDynamicError.Create('A container cannot hold itself or one of ' +
      'its own ancestors: the tree would become a cycle.');
end;

function TDynamicValue.SameMembers(AOther: TDynamicValue): Boolean;
begin
  Result := True;
end;

function TDynamicValue.Clone: TDynamicValue;
begin
  case FKind of
    TDynamicKind.Null:     Result := NewNull;
    TDynamicKind.Bool:     Result := NewBool(FBool);
    TDynamicKind.Int:      Result := NewInt(FInt);
    TDynamicKind.UInt:     Result := NewUInt(UInt64(FInt));
    TDynamicKind.Float:    Result := NewFloat(FFloat);
    TDynamicKind.Decimal:  Result := NewDecimal(FStr);
    TDynamicKind.Str:      Result := NewStr(FStr);
    TDynamicKind.Bytes:    Result := NewBytes(Copy(FBytes));
    TDynamicKind.Date:     Result := NewDate(FDateTime);
    TDynamicKind.Time:     Result := NewTime(FDateTime);
    TDynamicKind.DateTime: Result := NewDateTime(FDateTime);
    TDynamicKind.Extended:
      if FPayload = nil then Result := NewExtended(FTag, nil)
      else Result := NewExtended(FTag, FPayload.Clone);
  else
    { Containers override Clone. }
    raise EDynamicError.Create('Cannot clone this value.');
  end;
end;

function TDynamicValue.Equals(Obj: TObject): Boolean;
var
  Other: TDynamicValue;
begin
  if Obj = Self then Exit(True);
  if not (Obj is TDynamicValue) then Exit(False);
  Other := TDynamicValue(Obj);
  if Other.FKind <> FKind then Exit(False);
  case FKind of
    TDynamicKind.Null:     Result := True;
    TDynamicKind.Bool:     Result := FBool = Other.FBool;
    TDynamicKind.Int,
    TDynamicKind.UInt:     Result := FInt = Other.FInt;
    TDynamicKind.Float:
      Result := (FFloat = Other.FFloat) or
        (FFloat.IsNan and Other.FFloat.IsNan);
    TDynamicKind.Decimal,
    TDynamicKind.Str:      Result := FStr = Other.FStr;
    TDynamicKind.Bytes:
      Result := (Length(FBytes) = Length(Other.FBytes)) and
        ((Length(FBytes) = 0) or
         CompareMem(@FBytes[0], @Other.FBytes[0], Integer(Length(FBytes))));
    TDynamicKind.Date, TDynamicKind.Time,
    TDynamicKind.DateTime: Result := FDateTime = Other.FDateTime;
    TDynamicKind.Extended:
      Result := (FTag = Other.FTag) and
        (((FPayload = nil) and (Other.FPayload = nil)) or
         ((FPayload <> nil) and FPayload.Equals(Other.FPayload)));
  else
    Result := SameMembers(Other);
  end;
end;

function TDynamicValue.GetHashCode: Integer;
var
  I: Integer;
  H: Cardinal;
  D: Double;
begin
  H := Cardinal(Ord(FKind)) * 16777619;
  case FKind of
    TDynamicKind.Bool: H := H xor Cardinal(Ord(FBool));
    TDynamicKind.Int, TDynamicKind.UInt:
      H := H xor Cardinal(FInt) xor Cardinal(FInt shr 32);
    TDynamicKind.Float:
      begin
        { Equal floats hash alike: every NaN one way, both zeros the
          other. }
        D := FFloat;
        if D.IsNan then H := H xor $7FF80000
        else if D <> 0 then
          H := H xor Cardinal(THashBobJenkins.GetHashValue(D, SizeOf(D), 0));
      end;
    TDynamicKind.Decimal, TDynamicKind.Str:
      H := H xor Cardinal(FStr.GetHashCode);
    TDynamicKind.Bytes:
      if Length(FBytes) > 0 then
        H := H xor Cardinal(THashBobJenkins.GetHashValue(FBytes[0],
          Integer(Min(Length(FBytes), 4096)), 0));
    TDynamicKind.Date, TDynamicKind.Time, TDynamicKind.DateTime:
      begin
        D := FDateTime;
        if D <> 0 then
          H := H xor Cardinal(THashBobJenkins.GetHashValue(D, SizeOf(D), 0));
      end;
    TDynamicKind.Extended:
      begin
        H := H xor Cardinal(FTag.GetHashCode);
        if FPayload <> nil then H := H xor Cardinal(FPayload.GetHashCode);
      end;
    TDynamicKind.Arr:
      for I := 0 to Count - 1 do
        H := (H * 31) + Cardinal(Items[I].GetHashCode);
    TDynamicKind.Obj:
      { Order-insensitive, as equality is. }
      for I := 0 to Count - 1 do
        H := H xor (Cardinal(Names[I].GetHashCode) * 31 +
          Cardinal(Items[I].GetHashCode));
  end;
  Result := Integer(H);
end;

function TDynamicValue.Describe: string;
var
  I: Integer;
  SB: TStringBuilder;
begin
  case FKind of
    TDynamicKind.Null:     Exit('null');
    TDynamicKind.Bool:     Exit(BoolToStr(FBool, True).ToLower);
    TDynamicKind.Int:      Exit(FInt.ToString);
    TDynamicKind.UInt:     Exit(UIntToStr(UInt64(FInt)));
    TDynamicKind.Float:    Exit(TStructuralText.EncodeFloat(FFloat));
    TDynamicKind.Decimal:  Exit(FStr + 'm');
    TDynamicKind.Str:      Exit('"' + FStr + '"');
    TDynamicKind.Bytes:    Exit(Format('bytes(%d)', [Length(FBytes)]));
    TDynamicKind.Date:     Exit(FormatDateTime('yyyy-mm-dd', FDateTime,
                             TFormatSettings.Invariant));
    TDynamicKind.Time:     Exit(FormatDateTime('hh:nn:ss.zzz', FDateTime,
                             TFormatSettings.Invariant));
    TDynamicKind.DateTime: Exit(TStructuralText.EncodeDateTime(FDateTime));
    TDynamicKind.Extended:
      if FPayload = nil then Exit(FTag + '()')
      else Exit(FTag + '(' + FPayload.Describe + ')');
  end;
  SB := TStringBuilder.Create;
  try
    if FKind = TDynamicKind.Arr then SB.Append('[') else SB.Append('{');
    for I := 0 to Count - 1 do
    begin
      if I > 0 then SB.Append(',');
      if FKind = TDynamicKind.Obj then SB.Append(Names[I]).Append(':');
      SB.Append(Items[I].Describe);
    end;
    if FKind = TDynamicKind.Arr then SB.Append(']') else SB.Append('}');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ =========================================================================
  TDynamicObject
  ========================================================================= }

const
  { Below this, a scan of the names is as fast as a hash and costs nothing
    to keep. }
  DYNAMIC_INDEX_THRESHOLD = 8;

constructor TDynamicObject.Create;
begin
  inherited CreateKind(TDynamicKind.Obj);
  FItems := TObjectList<TDynamicValue>.Create(True);
  FNames := TList<string>.Create;
end;

destructor TDynamicObject.Destroy;
begin
  FIndex.Free;
  FNames.Free;
  FItems.Free;
  inherited Destroy;
end;

function TDynamicObject.GetCount: Integer;
begin
  Result := Integer(FItems.Count);
end;

function TDynamicObject.GetItem(AIndex: Integer): TDynamicValue;
begin
  if (AIndex < 0) or (AIndex >= FItems.Count) then
    raise EDynamicError.CreateFmt('Member index %d is outside 0..%d.',
      [AIndex, FItems.Count - 1]);
  Result := FItems[AIndex];
end;

function TDynamicObject.GetName(AIndex: Integer): string;
begin
  if (AIndex < 0) or (AIndex >= FNames.Count) then
    raise EDynamicError.CreateFmt('Member index %d is outside 0..%d.',
      [AIndex, FNames.Count - 1]);
  Result := FNames[AIndex];
end;

function TDynamicObject.Find(const AName: string): TDynamicValue;
var
  I: Integer;
begin
  if FIndex <> nil then
  begin
    if not FIndex.TryGetValue(AName, Result) then Result := nil;
    Exit;
  end;
  { Exact: 'Name' never answers for 'name'. }
  for I := 0 to Integer(FNames.Count) - 1 do
    if FNames[I] = AName then Exit(FItems[I]);
  Result := nil;
end;

function TDynamicObject.Contains(const AName: string): Boolean;
begin
  Result := Find(AName) <> nil;
end;

function TDynamicObject.IndexOf(const AName: string): Integer;
var
  V: TDynamicValue;
begin
  V := Find(AName);
  if V = nil then Exit(-1);
  Result := Integer(FItems.IndexOf(V));
end;

function TDynamicObject.Get(const AName: string): TDynamicValue;
begin
  Result := Find(AName);
  if Result = nil then
    raise EDynamicError.CreateFmt('The object has no member "%s".', [AName]);
end;

procedure TDynamicObject.CheckInsertIndex(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex > FItems.Count) then
    raise EDynamicError.CreateFmt('Insert position %d is outside 0..%d.',
      [AIndex, FItems.Count]);
end;

procedure TDynamicObject.Attach(AIndex: Integer; const AName: string;
  AValue: TDynamicValue);
var
  I: Integer;
begin
  CheckInsertIndex(AIndex);
  CheckAttachable(AValue);
  if Find(AName) <> nil then
    raise EDynamicError.CreateFmt('The object already has a member "%s". ' +
      'Names are unique and exact; replace one explicitly with ' +
      'AppendOrReplace.', [AName]);
  FItems.Insert(AIndex, AValue);
  try
    FNames.Insert(AIndex, AName);
  except
    FItems.Extract(AValue);
    raise;
  end;
  AValue.FParent := Self;
  if FIndex <> nil then
    FIndex.Add(AName, AValue)
  else if FItems.Count > DYNAMIC_INDEX_THRESHOLD then
  begin
    FIndex := TDictionary<string, TDynamicValue>.Create(FItems.Count * 2);
    for I := 0 to GetCount - 1 do FIndex.Add(FNames[I], FItems[I]);
  end;
end;

procedure TDynamicObject.Detach(AIndex: Integer);
var
  V: TDynamicValue;
begin
  V := FItems[AIndex];
  if FIndex <> nil then FIndex.Remove(FNames[AIndex]);
  FNames.Delete(AIndex);
  FItems.Extract(V);
  V.FParent := nil;
end;

procedure TDynamicObject.ReplaceAt(AIndex: Integer; AValue: TDynamicValue);
var
  Old: TDynamicValue;
begin
  CheckAttachable(AValue);
  Old := FItems[AIndex];
  { Extract keeps the list from freeing it; the slot is then reused. }
  FItems.Extract(Old);
  FItems.Insert(AIndex, AValue);
  AValue.FParent := Self;
  if FIndex <> nil then FIndex[FNames[AIndex]] := AValue;
  Old.FParent := nil;
  Old.Free;
end;

function TDynamicObject.Projected(const AValue: TValue): TDynamicValue;
begin
  Result := TDynamicEngine.FromDelphi(AValue);
end;

function TDynamicObject.Append(const AName: string;
  AValue: TDynamicValue): TDynamicObject;
begin
  Attach(GetCount, AName, AValue);
  Result := Self;
end;

function TDynamicObject.Append(const AName, AValue: string): TDynamicObject;
begin
  Result := Adopt(AName, TDynamicValue.NewStr(AValue));
end;

function TDynamicObject.Append(const AName: string;
  AValue: Int64): TDynamicObject;
begin
  Result := Adopt(AName, TDynamicValue.NewInt(AValue));
end;

function TDynamicObject.Append(const AName: string;
  AValue: Boolean): TDynamicObject;
begin
  Result := Adopt(AName, TDynamicValue.NewBool(AValue));
end;

function TDynamicObject.Append<T>(const AName: string;
  const AValue: T): TDynamicObject;
begin
  Result := AppendValue(AName, TValue.From<T>(AValue));
end;

function TDynamicObject.Append<T>(const AValue: T): TDynamicObject;
begin
  Result := AppendValue(TValue.From<T>(AValue));
end;

function TDynamicObject.AppendNull(const AName: string): TDynamicObject;
begin
  Result := Adopt(AName, TDynamicValue.NewNull);
end;

function TDynamicObject.AppendValue(const AName: string;
  const AValue: TValue): TDynamicObject;
begin
  Result := InsertValueAt(GetCount, AName, AValue);
end;

function TDynamicObject.AppendValue(const AValue: TValue): TDynamicObject;
var
  Projection: TDynamicValue;
begin
  { A dynamic object is imported as it is: copies of its members, and the
    caller keeps it. }
  if AValue.IsObject and (AValue.AsObject is TDynamicObject) then
    Exit(Import(TDynamicObject(AValue.AsObject)));
  if AValue.IsObject and (AValue.AsObject is TDynamicValue) then
    raise EDynamicError.CreateFmt('Only an object''s members can be ' +
      'imported without names; %s is not an object. Give it a name.',
      [TDynamicValue(AValue.AsObject).Describe]);
  Projection := Projected(AValue);
  try
    if Projection.Kind <> TDynamicKind.Obj then
      raise EDynamicError.CreateFmt('A %s projects to %s, which has no ' +
        'members to import. Append it under a name instead.',
        [UTF8ToString(AValue.TypeInfo.Name),
         TDynamicValue.KindName(Projection.Kind)]);
    MoveFrom(TDynamicObject(Projection));
  finally
    Projection.Free;
  end;
  Result := Self;
end;

function TDynamicObject.InsertAt(AIndex: Integer; const AName: string;
  AValue: TDynamicValue): TDynamicObject;
begin
  Attach(AIndex, AName, AValue);
  Result := Self;
end;

function TDynamicObject.InsertAt(AIndex: Integer;
  const AName, AValue: string): TDynamicObject;
begin
  AdoptAt(AIndex, AName, TDynamicValue.NewStr(AValue));
  Result := Self;
end;

function TDynamicObject.InsertAt(AIndex: Integer; const AName: string;
  AValue: Int64): TDynamicObject;
begin
  AdoptAt(AIndex, AName, TDynamicValue.NewInt(AValue));
  Result := Self;
end;

function TDynamicObject.InsertAt(AIndex: Integer; const AName: string;
  AValue: Boolean): TDynamicObject;
begin
  AdoptAt(AIndex, AName, TDynamicValue.NewBool(AValue));
  Result := Self;
end;

function TDynamicObject.InsertAt<T>(AIndex: Integer; const AName: string;
  const AValue: T): TDynamicObject;
begin
  Result := InsertValueAt(AIndex, AName, TValue.From<T>(AValue));
end;

function TDynamicObject.InsertValueAt(AIndex: Integer; const AName: string;
  const AValue: TValue): TDynamicObject;
var
  V: TDynamicValue;
begin
  { A dynamic value moves in as itself, with the ownership rules of the
    TDynamicValue overload. }
  if AValue.IsObject and (AValue.AsObject is TDynamicValue) then
    Exit(InsertAt(AIndex, AName, TDynamicValue(AValue.AsObject)));
  CheckInsertIndex(AIndex);
  if Find(AName) <> nil then
    raise EDynamicError.CreateFmt('The object already has a member "%s". ' +
      'Names are unique and exact; replace one explicitly with ' +
      'AppendOrReplace.', [AName]);
  V := Projected(AValue);
  try
    Attach(AIndex, AName, V);
  except
    V.Free;
    raise;
  end;
  Result := Self;
end;

function TDynamicObject.AddObject(const AName: string): TDynamicObject;
begin
  Result := TDynamicObject.Create;
  Adopt(AName, Result);
end;

function TDynamicObject.AddArray(const AName: string): TDynamicArray;
begin
  Result := TDynamicArray.Create;
  Adopt(AName, Result);
end;

procedure TDynamicObject.AdoptAt(AIndex: Integer; const AName: string;
  AValue: TDynamicValue);
begin
  try
    Attach(AIndex, AName, AValue);
  except
    if (AValue <> nil) and (AValue.FParent = nil) and
       not AValue.IsSelfOrAncestorOf(Self) then
      AValue.Free;
    raise;
  end;
end;

function TDynamicObject.Adopt(const AName: string;
  AValue: TDynamicValue): TDynamicObject;
begin
  AdoptAt(GetCount, AName, AValue);
  Result := Self;
end;

function TDynamicObject.AppendOrReplace(const AName: string;
  AValue: TDynamicValue): TDynamicObject;
var
  I: Integer;
begin
  I := IndexOf(AName);
  if I < 0 then Exit(Append(AName, AValue));
  if FItems[I] = AValue then Exit(Self);
  ReplaceAt(I, AValue);
  Result := Self;
end;

function TDynamicObject.Extract(const AName: string): TDynamicValue;
var
  I: Integer;
begin
  I := IndexOf(AName);
  if I < 0 then Exit(nil);
  Result := FItems[I];
  Detach(I);
end;

function TDynamicObject.ExtractAt(AIndex: Integer): TDynamicValue;
begin
  Result := GetItem(AIndex);
  Detach(AIndex);
end;

function TDynamicObject.Remove(const AName: string): Boolean;
var
  V: TDynamicValue;
begin
  V := Extract(AName);
  Result := V <> nil;
  V.Free;
end;

procedure TDynamicObject.Delete(AIndex: Integer);
begin
  ExtractAt(AIndex).Free;
end;

procedure TDynamicObject.Clear;
begin
  FreeAndNil(FIndex);
  FNames.Clear;
  FItems.Clear;
end;

procedure TDynamicObject.MergeMembers(ASource: TDynamicObject;
  ACollision: TDynamicCollision; AMove: Boolean);
var
  I, At: Integer;
  Incoming, Existing: TDynamicValue;
  Name: string;
begin
  if (ASource = nil) or (ASource = Self) then
    raise EDynamicError.Create('An object cannot import its own members.');
  if ASource.IsSelfOrAncestorOf(Self) then
    raise EDynamicError.Create('An object cannot take the members of one of ' +
      'its own ancestors: the tree would become a cycle.');
  { A refusal is decided before anything moves. }
  if ACollision = TDynamicCollision.Error then
    for I := 0 to ASource.Count - 1 do
      if Contains(ASource.Names[I]) then
        raise EDynamicError.CreateFmt('The object already has a member ' +
          '"%s". Choose a TDynamicCollision other than Error to combine ' +
          'them.', [ASource.Names[I]]);
  I := 0;
  while I < ASource.Count do
  begin
    Name := ASource.Names[I];
    if AMove then
      Incoming := ASource.ExtractAt(I)
    else
    begin
      Incoming := ASource.Items[I].Clone;
      Inc(I);
    end;
    try
      At := IndexOf(Name);
      if At < 0 then
      begin
        Attach(GetCount, Name, Incoming);
        Incoming := nil;
      end
      else
        case ACollision of
          TDynamicCollision.KeepExisting: ;
          TDynamicCollision.Overwrite:
            begin
              ReplaceAt(At, Incoming);
              Incoming := nil;
            end;
          TDynamicCollision.DeepMerge:
            begin
              Existing := FItems[At];
              if (Existing.Kind = TDynamicKind.Obj) and
                 (Incoming.Kind = TDynamicKind.Obj) then
                TDynamicObject(Existing).MergeMembers(
                  TDynamicObject(Incoming), TDynamicCollision.DeepMerge, True)
              else
              begin
                ReplaceAt(At, Incoming);
                Incoming := nil;
              end;
            end;
        end;
    finally
      Incoming.Free;
    end;
  end;
end;

function TDynamicObject.Import(ASource: TDynamicObject;
  ACollision: TDynamicCollision): TDynamicObject;
begin
  MergeMembers(ASource, ACollision, False);
  Result := Self;
end;

function TDynamicObject.MoveFrom(ASource: TDynamicObject;
  ACollision: TDynamicCollision): TDynamicObject;
begin
  MergeMembers(ASource, ACollision, True);
  Result := Self;
end;

function TDynamicObject.SameMembers(AOther: TDynamicValue): Boolean;
var
  I: Integer;
  Theirs: TDynamicValue;
begin
  if AOther.Count <> Count then Exit(False);
  for I := 0 to Count - 1 do
  begin
    Theirs := AOther.Find(FNames[I]);
    if (Theirs = nil) or not FItems[I].Equals(Theirs) then Exit(False);
  end;
  Result := True;
end;

function TDynamicObject.Clone: TDynamicValue;
var
  I: Integer;
  Copy_: TDynamicObject;
begin
  Copy_ := TDynamicObject.Create;
  try
    for I := 0 to GetCount - 1 do
      Copy_.Adopt(FNames[I], FItems[I].Clone);
  except
    Copy_.Free;
    raise;
  end;
  Result := Copy_;
end;

{ =========================================================================
  TDynamicArray
  ========================================================================= }

constructor TDynamicArray.Create;
begin
  inherited CreateKind(TDynamicKind.Arr);
  FItems := TObjectList<TDynamicValue>.Create(True);
end;

destructor TDynamicArray.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

function TDynamicArray.GetCount: Integer;
begin
  Result := Integer(FItems.Count);
end;

function TDynamicArray.GetItem(AIndex: Integer): TDynamicValue;
begin
  if (AIndex < 0) or (AIndex >= FItems.Count) then
    raise EDynamicError.CreateFmt('Item index %d is outside 0..%d.',
      [AIndex, FItems.Count - 1]);
  Result := FItems[AIndex];
end;

procedure TDynamicArray.CheckInsertIndex(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex > FItems.Count) then
    raise EDynamicError.CreateFmt('Insert position %d is outside 0..%d.',
      [AIndex, FItems.Count]);
end;

procedure TDynamicArray.Attach(AIndex: Integer; AValue: TDynamicValue);
begin
  CheckInsertIndex(AIndex);
  CheckAttachable(AValue);
  FItems.Insert(AIndex, AValue);
  AValue.FParent := Self;
end;

function TDynamicArray.Append(AValue: TDynamicValue): TDynamicArray;
begin
  Attach(GetCount, AValue);
  Result := Self;
end;

function TDynamicArray.Append(const AValue: string): TDynamicArray;
begin
  Result := Adopt(TDynamicValue.NewStr(AValue));
end;

function TDynamicArray.Append(AValue: Int64): TDynamicArray;
begin
  Result := Adopt(TDynamicValue.NewInt(AValue));
end;

function TDynamicArray.Append(AValue: Boolean): TDynamicArray;
begin
  Result := Adopt(TDynamicValue.NewBool(AValue));
end;

function TDynamicArray.Append<T>(const AValue: T): TDynamicArray;
begin
  Result := AppendValue(TValue.From<T>(AValue));
end;

function TDynamicArray.AppendNull: TDynamicArray;
begin
  Result := Adopt(TDynamicValue.NewNull);
end;

function TDynamicArray.AppendValue(const AValue: TValue): TDynamicArray;
begin
  Result := InsertValueAt(GetCount, AValue);
end;

function TDynamicArray.InsertAt(AIndex: Integer;
  AValue: TDynamicValue): TDynamicArray;
begin
  Attach(AIndex, AValue);
  Result := Self;
end;

function TDynamicArray.InsertAt(AIndex: Integer;
  const AValue: string): TDynamicArray;
begin
  AdoptAt(AIndex, TDynamicValue.NewStr(AValue));
  Result := Self;
end;

function TDynamicArray.InsertAt(AIndex: Integer; AValue: Int64): TDynamicArray;
begin
  AdoptAt(AIndex, TDynamicValue.NewInt(AValue));
  Result := Self;
end;

function TDynamicArray.InsertAt(AIndex: Integer;
  AValue: Boolean): TDynamicArray;
begin
  AdoptAt(AIndex, TDynamicValue.NewBool(AValue));
  Result := Self;
end;

function TDynamicArray.InsertAt<T>(AIndex: Integer;
  const AValue: T): TDynamicArray;
begin
  Result := InsertValueAt(AIndex, TValue.From<T>(AValue));
end;

function TDynamicArray.InsertValueAt(AIndex: Integer;
  const AValue: TValue): TDynamicArray;
var
  V: TDynamicValue;
begin
  if AValue.IsObject and (AValue.AsObject is TDynamicValue) then
    Exit(InsertAt(AIndex, TDynamicValue(AValue.AsObject)));
  CheckInsertIndex(AIndex);
  V := TDynamicEngine.FromDelphi(AValue);
  try
    Attach(AIndex, V);
  except
    V.Free;
    raise;
  end;
  Result := Self;
end;

function TDynamicArray.AddObject: TDynamicObject;
begin
  Result := TDynamicObject.Create;
  Adopt(Result);
end;

function TDynamicArray.AddArray: TDynamicArray;
begin
  Result := TDynamicArray.Create;
  Adopt(Result);
end;

procedure TDynamicArray.AdoptAt(AIndex: Integer; AValue: TDynamicValue);
begin
  try
    Attach(AIndex, AValue);
  except
    if (AValue <> nil) and (AValue.FParent = nil) and
       not AValue.IsSelfOrAncestorOf(Self) then
      AValue.Free;
    raise;
  end;
end;

function TDynamicArray.Adopt(AValue: TDynamicValue): TDynamicArray;
begin
  AdoptAt(GetCount, AValue);
  Result := Self;
end;

function TDynamicArray.AppendRange(ASource: TDynamicArray): TDynamicArray;
var
  Copies: TArray<TDynamicValue>;
  I, Done: Integer;
begin
  if ASource = nil then Exit(Self);
  { Copied first, so that appending an array's items to itself sees the
    items it started with. }
  SetLength(Copies, ASource.Count);
  Done := 0;
  try
    for I := 0 to ASource.Count - 1 do
    begin
      Copies[I] := ASource.Items[I].Clone;
      Inc(Done);
    end;
  except
    for I := 0 to Done - 1 do Copies[I].Free;
    raise;
  end;
  for I := 0 to Integer(High(Copies)) do Adopt(Copies[I]);
  Result := Self;
end;

function TDynamicArray.ReplaceAt(AIndex: Integer;
  AValue: TDynamicValue): TDynamicArray;
var
  Old: TDynamicValue;
begin
  Old := GetItem(AIndex);
  if Old = AValue then Exit(Self);
  CheckAttachable(AValue);
  FItems.Extract(Old);
  FItems.Insert(AIndex, AValue);
  AValue.FParent := Self;
  Old.FParent := nil;
  Old.Free;
  Result := Self;
end;

function TDynamicArray.ExtractAt(AIndex: Integer): TDynamicValue;
begin
  Result := GetItem(AIndex);
  FItems.Extract(Result);
  Result.FParent := nil;
end;

procedure TDynamicArray.Delete(AIndex: Integer);
begin
  ExtractAt(AIndex).Free;
end;

procedure TDynamicArray.Clear;
begin
  FItems.Clear;
end;

function TDynamicArray.SameMembers(AOther: TDynamicValue): Boolean;
var
  I: Integer;
begin
  if AOther.Count <> Count then Exit(False);
  for I := 0 to Count - 1 do
    if not FItems[I].Equals(AOther.Items[I]) then Exit(False);
  Result := True;
end;

function TDynamicArray.Clone: TDynamicValue;
var
  I: Integer;
  Copy_: TDynamicArray;
begin
  Copy_ := TDynamicArray.Create;
  try
    for I := 0 to GetCount - 1 do Copy_.Adopt(FItems[I].Clone);
  except
    Copy_.Free;
    raise;
  end;
  Result := Copy_;
end;

{ =========================================================================
  TDynamicSerializer
  ========================================================================= }

class function TDynamicSerializer.Serialize<T>(const AValue: T): TDynamicValue;
begin
  Result := Serialize(TValue.From<T>(AValue));
end;

class function TDynamicSerializer.Serialize(const AValue: TValue): TDynamicValue;
begin
  Result := TDynamicEngine.FromDelphi(AValue);
end;

class function TDynamicSerializer.Deserialize<T>(AValue: TDynamicValue): T;
begin
  Result := Deserialize(AValue, System.TypeInfo(T)).AsType<T>;
end;

class function TDynamicSerializer.Deserialize(AValue: TDynamicValue;
  ATypeInfo: PTypeInfo): TValue;
begin
  Result := TDynamicEngine.ToDelphi(AValue, ATypeInfo);
end;

class procedure TDynamicSerializer.Populate(AInstance: TObject;
  AValue: TDynamicValue);
begin
  TDynamicEngine.Populate(AInstance, AValue);
end;

end.
