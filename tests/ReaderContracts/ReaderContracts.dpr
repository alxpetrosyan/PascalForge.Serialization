program ReaderContracts;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ What a contract reader does with a document that does not match the type
  it is reading into.

  A round trip never asks this: the writer only ever produces documents that
  match. So every case here writes one shape and reads it back as ANOTHER,
  through every format that does contract work, and asks the only question
  that matters for input nobody controls:

      does the reader either carry the value faithfully, or refuse it with
      an exception of this library's own - never a bare RTL exception, and
      never a silent answer that is not the document's value?

  The silent answers are the ones these cases were written against: a scalar
  where a list belongs read as an EMPTY list (and the list the constructor
  made erased on the way), 1e300 read into a Single as infinity, 1e300 into
  a Currency as -922337203685477.5808, 99 into a three-member enumeration as
  an ordinal the type does not have, 300 into a Byte as 44.

  The second half is protobuf's own: a field that arrives with the wrong
  wire type, a scalar override the value does not fit, a set that arrives in
  pieces or unpacked, and the member shapes protobuf has no field for. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Math, System.StrUtils, System.TypInfo,
  System.Generics.Collections,
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Bson in '..\..\src\PascalForge.Bson.pas',
  PascalForge.MessagePack in '..\..\src\PascalForge.MessagePack.pas',
  PascalForge.Protobuf in '..\..\src\PascalForge.Protobuf.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  PascalForge.Xml in '..\..\src\PascalForge.Xml.pas',
  PascalForge.Cbor in '..\..\src\PascalForge.Cbor.pas',
  PascalForge.Yaml in '..\..\src\PascalForge.Yaml.pas',
  PascalForge.Csv in '..\..\src\PascalForge.Csv.pas',
  AllFormatsRegistered in '..\Shared\AllFormatsRegistered.pas';

type
  TSmallEnum = (seA, seB, seC);

  { Every shape counts its live instances, so a read that fails and leaves
    behind what it built is caught per format, not only as one anonymous
    leak report at shutdown. }
  TTracked = class
  public
    class var Live: Integer;
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;
  end;

  { One custom date pattern, spelled in every format that has one: each
    engine reads only its own attribute. }
  TPatternShape = class(TTracked)
  public
    [JsonDateTimeFormat('dd.mm.yyyy hh:nn:ss')]
    [XmlDateTimeFormat('dd.mm.yyyy hh:nn:ss')]
    [BsonDateTimeRepresentation('dd.mm.yyyy hh:nn:ss')]
    [MessagePackDateTimeRepresentation('dd.mm.yyyy hh:nn:ss')]
    [CborDateTimeRepresentation('dd.mm.yyyy hh:nn:ss')]
    [YamlDateTimeRepresentation('dd.mm.yyyy hh:nn:ss')]
    [CsvDateTimeFormat('dd.mm.yyyy hh:nn:ss')]
    At: TDateTime;
    [JsonDateTimeFormat('yyyymmdd')]
    [XmlDateTimeFormat('yyyymmdd')]
    [BsonDateTimeRepresentation('yyyymmdd')]
    [MessagePackDateTimeRepresentation('yyyymmdd')]
    [CborDateTimeRepresentation('yyyymmdd')]
    [YamlDateTimeRepresentation('yyyymmdd')]
    [CsvDateTimeFormat('yyyymmdd')]
    Day: TDateTime;
  end;

  TMomentShape = class(TTracked)
  public
    At: TDateTime;
  end;

  TRawShape = class(TTracked)
  public
    [ProtoField(1)] R: RawByteString;
  end;

  { The shapes. Each pair shares a member name and a field number, so what
    one writes the other reads as the same member with a different type. }
  TScalarShape = class(TTracked)
  public
    [ProtoField(1)] Items: Integer;
  end;

  TListShape = class(TTracked)
  public
    [ProtoField(1)] Items: TList<Integer>;
    constructor Create;
    destructor Destroy; override;
  end;

  TDoubleShape = class(TTracked)
  public
    [ProtoField(1)] V: Double;
  end;

  TSingleShape = class(TTracked)
  public
    [ProtoField(1)] V: Single;
  end;

  TCurrencyShape = class(TTracked)
  public
    [ProtoField(1)] V: Currency;
  end;

  TIntShape = class(TTracked)
  public
    [ProtoField(1)] V: Integer;
  end;

  TByteShape = class(TTracked)
  public
    [ProtoField(1)] V: Byte;
  end;

  TEnumShape = class(TTracked)
  public
    [ProtoField(1)] V: TSmallEnum;
  end;

  TInt64Shape = class(TTracked)
  public
    [ProtoField(1)] V: Int64;
  end;

  { protobuf's own }
  TNarrowOverride = class
  public
    [ProtoField(1), ProtoType(TProtoScalar.Int32)] V: Int64;
  end;

  TMismatchedOverride = class
  public
    [ProtoField(1), ProtoType(TProtoScalar.Text)] V: Integer;
  end;

  TColor3 = (cRed, cGreen, cBlue);
  TColors = set of TColor3;
  TSetShape = class
  public
    [ProtoField(1)] S: TColors;
  end;

  TNullableList = class
  public
    [ProtoField(1)] L: TNullable<TArray<Integer>>;
  end;

  TOneOfList = class
  public
    [ProtoField(1), ProtoOneOf('choice')] A: Integer;
    [ProtoField(2), ProtoOneOf('choice')] B: TArray<Integer>;
  end;

  TItem = class
  public
    [ProtoField(1)] N: Integer;
  end;

  TItemList = class
  public
    [ProtoField(1)] Items: TObjectList<TItem>;
    constructor Create;
    destructor Destroy; override;
  end;

  { OWNERSHIP: the everyday Delphi DTO, whose constructor makes its child
    list and child object. A reader that builds a second of each and stores
    it over the first leaks the first; so does one that fails half way and
    forgets what it built. }
  TTrackedList = class(TList<Integer>)
  public
    class var Live: Integer;
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;
  end;

  TChild = class(TTracked)
  public
    [ProtoField(1)] N: Integer;
  end;

  TOwnerShape = class(TTracked)
  public
    [ProtoField(1)] Items: TTrackedList;
    [ProtoField(2)] Child: TChild;
    constructor Create;
    destructor Destroy; override;
  end;

  TNumbered = (nZero, nOne, nTwo);
  TNumberedShape = class
  public
    [ProtoField(1)] E: TNumbered;
  end;

var
  GFailures: Integer = 0;
  GChecks: Integer = 0;

procedure TTracked.AfterConstruction;
begin
  inherited;
  AtomicIncrement(Live);
end;

procedure TTracked.BeforeDestruction;
begin
  AtomicDecrement(Live);
  inherited;
end;

procedure TTrackedList.AfterConstruction;
begin
  inherited;
  AtomicIncrement(Live);
end;

procedure TTrackedList.BeforeDestruction;
begin
  AtomicDecrement(Live);
  inherited;
end;

constructor TOwnerShape.Create;
begin
  inherited Create;
  Items := TTrackedList.Create;
  Child := TChild.Create;
end;

destructor TOwnerShape.Destroy;
begin
  Child.Free;
  Items.Free;
  inherited Destroy;
end;

constructor TListShape.Create;
begin
  inherited Create;
  Items := TList<Integer>.Create;
  Items.Add(7);
end;

destructor TListShape.Destroy;
begin
  Items.Free;
  inherited Destroy;
end;

constructor TItemList.Create;
begin
  inherited Create;
  Items := TObjectList<TItem>.Create(True);
end;

destructor TItemList.Destroy;
begin
  Items.Free;
  inherited Destroy;
end;

procedure Check(ACondition: Boolean; const AName: string);
begin
  Inc(GChecks);
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

{ An exception raised by this library: its class is declared in one of the
  library's own units. EConvertError, EInvalidCast, ERangeError and the rest
  are the RTL's, and reaching the caller as one is a defect. }
function IsOwn(E: Exception): Boolean;
begin
  Result := string(E.UnitName).StartsWith('PascalForge.');
end;

function FmtName(AFormat: TSerializationFormat): string;
begin
  Result := TSerialization.FormatName(AFormat);
end;

type
  { What happened when shape A's document was read as shape B. }
  TReadOutcome = (roCarried, roRefused, roSilent, roRtl, roSourceRefused,
    roLeaked);

const
  OUTCOME_NAMES: array[TReadOutcome] of string =
    ('carried', 'refused', 'SILENT', 'RTL', 'source refused',
     'LEAKED what it built');

{ ===========================================================================
  CROSS-SHAPE READS, every contract format
  =========================================================================== }

procedure RunCase(const AName: string;
  AWrite: TFunc<TSerializationFormat, TSerializationPayload>;
  ARead: TFunc<TSerializationFormat, TSerializationPayload, Boolean>);
var
  F: TSerializationFormat;
  Payload: TSerializationPayload;
  Outcome: TReadOutcome;
  Detail: string;
  LiveBefore: Integer;
begin
  Outcome := roCarried;
  Writeln;
  Writeln('-- ', AName, ' --');
  for F in TSerialization.ContractFormats do
  begin
    Detail := '';
    LiveBefore := TTracked.Live;
    try
      Payload := AWrite(F);
    except
      on E: Exception do
      begin
        { A writer that will not produce the source document leaves nothing
          to read; it is reported, and the case is not this format's to
          answer. It is still a defect if the refusal is not the library's. }
        Outcome := roSourceRefused;
        if not IsOwn(E) then Outcome := roRtl;
        Detail := E.ClassName + ': ' + E.Message;
        Check(Outcome <> roRtl, Format('%s_%s', [AName, UpperCase(FmtName(F))]));
        Note(FmtName(F) + ': ' + OUTCOME_NAMES[Outcome] + ' - ' + Detail);
        Continue;
      end;
    end;
    try
      if ARead(F, Payload) then Outcome := roCarried
      else Outcome := roSilent;
    except
      on E: Exception do
      begin
        if IsOwn(E) then Outcome := roRefused else Outcome := roRtl;
        Detail := E.ClassName + ': ' + E.Message;
      end;
    end;
    { A reader that fails frees what it built: the caller never saw it and
      cannot. }
    if TTracked.Live <> LiveBefore then
    begin
      Detail := Format('%d instance(s) left alive; %s', [TTracked.Live -
        LiveBefore, Detail]);
      Outcome := roLeaked;
      TTracked.Live := LiveBefore;
    end;
    Check(Outcome in [roCarried, roRefused],
      Format('%s_%s', [AName, UpperCase(FmtName(F))]));
    if Outcome <> roCarried then
      Note(FmtName(F) + ': ' + OUTCOME_NAMES[Outcome] +
        IfThen(Detail <> '', ' - ' + Detail, ''));
  end;
end;

procedure TestCrossShapeReads;
begin
  { A scalar where a list belongs. The only faithful reading is a list that
    now holds the 5 - protobuf's, where one element and a repeated field of
    one are the same bytes. An empty list, or the constructor's 7 alone, is
    the silent answer. }
  RunCase('SCALAR_WHERE_LIST',
    function(F: TSerializationFormat): TSerializationPayload
    var S: TScalarShape;
    begin
      S := TScalarShape.Create;
      try
        S.Items := 5;
        Result := TSerialization.Serialize<TScalarShape>(S, F);
      finally
        S.Free;
      end;
    end,
    function(F: TSerializationFormat; P: TSerializationPayload): Boolean
    var L: TListShape;
    begin
      L := TSerialization.Deserialize<TListShape>(P, F);
      try
        Result := (L <> nil) and (L.Items <> nil) and L.Items.Contains(5);
      finally
        L.Free;
      end;
    end);

  { 1e300 into a Single: it is not a Single, and infinity is not it. }
  RunCase('DOUBLE_INTO_SINGLE_RANGE',
    function(F: TSerializationFormat): TSerializationPayload
    var S: TDoubleShape;
    begin
      S := TDoubleShape.Create;
      try
        S.V := 1e300;
        Result := TSerialization.Serialize<TDoubleShape>(S, F);
      finally
        S.Free;
      end;
    end,
    function(F: TSerializationFormat; P: TSerializationPayload): Boolean
    var D: TSingleShape;
    begin
      D := TSerialization.Deserialize<TSingleShape>(P, F);
      try
        Result := False;   { no Single is 1e300, so only a refusal is right }
      finally
        D.Free;
      end;
    end);

  { 1e300 into a Currency. }
  RunCase('DOUBLE_INTO_CURRENCY_RANGE',
    function(F: TSerializationFormat): TSerializationPayload
    var S: TDoubleShape;
    begin
      S := TDoubleShape.Create;
      try
        S.V := 1e300;
        Result := TSerialization.Serialize<TDoubleShape>(S, F);
      finally
        S.Free;
      end;
    end,
    function(F: TSerializationFormat; P: TSerializationPayload): Boolean
    var D: TCurrencyShape;
    begin
      D := TSerialization.Deserialize<TCurrencyShape>(P, F);
      try
        Result := False;
      finally
        D.Free;
      end;
    end);

  { 1.5 into a Single, which holds it exactly: a narrowing that loses
    nothing is carried. }
  RunCase('DOUBLE_INTO_SINGLE_EXACT',
    function(F: TSerializationFormat): TSerializationPayload
    var S: TDoubleShape;
    begin
      S := TDoubleShape.Create;
      try
        S.V := 1.5;
        Result := TSerialization.Serialize<TDoubleShape>(S, F);
      finally
        S.Free;
      end;
    end,
    function(F: TSerializationFormat; P: TSerializationPayload): Boolean
    var D: TSingleShape;
    begin
      D := TSerialization.Deserialize<TSingleShape>(P, F);
      try
        Result := D.V = 1.5;
      finally
        D.Free;
      end;
    end);

  { 300 into a Byte. }
  RunCase('INTEGER_INTO_BYTE_RANGE',
    function(F: TSerializationFormat): TSerializationPayload
    var S: TIntShape;
    begin
      S := TIntShape.Create;
      try
        S.V := 300;
        Result := TSerialization.Serialize<TIntShape>(S, F);
      finally
        S.Free;
      end;
    end,
    function(F: TSerializationFormat; P: TSerializationPayload): Boolean
    var D: TByteShape;
    begin
      D := TSerialization.Deserialize<TByteShape>(P, F);
      try
        Result := False;
      finally
        D.Free;
      end;
    end);

  { 99 into a three-member enumeration. }
  RunCase('INTEGER_INTO_ENUM_RANGE',
    function(F: TSerializationFormat): TSerializationPayload
    var S: TIntShape;
    begin
      S := TIntShape.Create;
      try
        S.V := 99;
        Result := TSerialization.Serialize<TIntShape>(S, F);
      finally
        S.Free;
      end;
    end,
    function(F: TSerializationFormat; P: TSerializationPayload): Boolean
    var D: TEnumShape;
    begin
      D := TSerialization.Deserialize<TEnumShape>(P, F);
      try
        Result := False;
      finally
        D.Free;
      end;
    end);

  { -1 into a Byte: the lower bound, which one reader did not check. }
  RunCase('NEGATIVE_INTO_BYTE',
    function(F: TSerializationFormat): TSerializationPayload
    var S: TIntShape;
    begin
      S := TIntShape.Create;
      try
        S.V := -1;
        Result := TSerialization.Serialize<TIntShape>(S, F);
      finally
        S.Free;
      end;
    end,
    function(F: TSerializationFormat; P: TSerializationPayload): Boolean
    var D: TByteShape;
    begin
      D := TSerialization.Deserialize<TByteShape>(P, F);
      try
        Result := False;
      finally
        D.Free;
      end;
    end);
end;

{ ===========================================================================
  OWNERSHIP: a round trip leaves nothing alive
  =========================================================================== }

procedure TestOwnership;
var
  F: TSerializationFormat;
  Source, Back: TOwnerShape;
  Payload: TSerializationPayload;
  Objects, Lists: Integer;
  Carried: Boolean;
  Detail: string;
begin
  Writeln;
  Writeln('-- OWNERSHIP: a constructor''s child list and object, round-tripped --');
  for F in TSerialization.ContractFormats do
  begin
    Objects := TTracked.Live;
    Lists := TTrackedList.Live;
    Detail := '';
    Carried := True;
    Source := TOwnerShape.Create;
    try
      Source.Items.AddRange([1, 2, 3]);
      Source.Child.N := 9;
      try
        Payload := TSerialization.Serialize<TOwnerShape>(Source, F);
        Back := TSerialization.Deserialize<TOwnerShape>(Payload, F);
        try
          if not ((Back.Items <> nil) and (Back.Items.Count = 3) and
            (Back.Items[2] = 3) and (Back.Child <> nil) and
            (Back.Child.N = 9)) then
          begin
            Carried := False;
            Detail := 'the values did not come back';
          end;
        finally
          Back.Free;
        end;
      except
        on E: Exception do
        begin
          { A format that cannot carry the shape refuses it; that is not
            this check's question, but the refusal must be the library's. }
          Carried := IsOwn(E);
          Detail := 'refused - ' + E.ClassName + ': ' + E.Message;
        end;
      end;
    finally
      Source.Free;
    end;
    if (TTracked.Live <> Objects) or (TTrackedList.Live <> Lists) then
    begin
      Detail := Format('LEAKED %d object(s) and %d list(s); %s',
        [TTracked.Live - Objects, TTrackedList.Live - Lists, Detail]);
      Carried := False;
      TTracked.Live := Objects;
      TTrackedList.Live := Lists;
    end;
    Check(Carried, 'OWNERSHIP_ROUND_TRIP_' + UpperCase(FmtName(F)));
    if Detail <> '' then Note(FmtName(F) + ': ' + Detail);
  end;
end;

{ ===========================================================================
  BSON: an exactly integral double is an integer
  =========================================================================== }

procedure TestBsonIntegralDouble;
var
  S: TDoubleShape;
  Data: TBytes;
  I: TInt64Shape;
  Raised: Boolean;
begin
  Writeln;
  Writeln('-- BSON: a double that is exactly integral reads into an integer --');
  S := TDoubleShape.Create;
  try
    S.V := 5;
    Data := TBsonSerializer.Serialize<TDoubleShape>(S);
    I := TBsonSerializer.Deserialize<TInt64Shape>(Data);
    try
      Check(I.V = 5, 'BSON_INTEGRAL_DOUBLE_INTO_INT64');
    finally
      I.Free;
    end;
    S.V := 5.5;
    Data := TBsonSerializer.Serialize<TDoubleShape>(S);
    Raised := False;
    try
      TBsonSerializer.Deserialize<TInt64Shape>(Data).Free;
    except
      on E: EBsonInputError do Raised := True;
    end;
    Check(Raised, 'BSON_FRACTIONAL_DOUBLE_INTO_INT64_REFUSED');
  finally
    S.Free;
  end;
end;

{ ===========================================================================
  PROTOBUF
  =========================================================================== }

function RaisesProto(AProc: TProc; AClass: ExceptClass): Boolean;
begin
  Result := False;
  try
    AProc;
  except
    on E: Exception do
    begin
      Result := E is AClass;
      if not Result then Note('raised ' + E.ClassName + ': ' + E.Message);
    end;
  end;
end;

procedure TestProtobuf;
var
  Data: TBytes;
  SetBack: TSetShape;
  Numbered: TNumberedShape;
begin
  Writeln;
  Writeln('-- protobuf --');

  { 5000000000 as int32 would be 705032704 on the wire. }
  Check(RaisesProto(
    procedure
    var N: TNarrowOverride;
    begin
      N := TNarrowOverride.Create;
      try
        N.V := 5000000000;
        TProtobufSerializer.Serialize<TNarrowOverride>(N);
      finally
        N.Free;
      end;
    end, EProtobufError), 'PROTO_INT32_OVERRIDE_OUT_OF_RANGE_REFUSED');

  { An Integer spelled string put a length-delimited tag before a varint. }
  Check(RaisesProto(
    procedure
    var N: TMismatchedOverride;
    begin
      N := TMismatchedOverride.Create;
      try
        N.V := 1;
        TProtobufSerializer.Serialize<TMismatchedOverride>(N);
      finally
        N.Free;
      end;
    end, EProtobufError), 'PROTO_OVERRIDE_OF_ANOTHER_FAMILY_REFUSED');

  { Field 1 as a varint, where TDoubleShape.V is a fixed64 double. }
  Check(RaisesProto(
    procedure
    begin
      TProtobufSerializer.Deserialize<TDoubleShape>(TBytes.Create($08, $05)).Free;
    end, EProtobufInputError), 'PROTO_WIRE_TYPE_MISMATCH_REFUSED');

  { A set is a repeated enum: one element per field (unpacked), and packed
    runs in several pieces, are all the same field, and the set is the
    union. field 1 varint 0 (red); field 1 packed [2] (blue). }
  Data := TBytes.Create($08, $00, $0A, $01, $02);
  SetBack := TProtobufSerializer.Deserialize<TSetShape>(Data);
  try
    Check(SetBack.S = [cRed, cBlue], 'PROTO_SET_UNPACKED_AND_CHUNKED_IS_THE_UNION');
  finally
    SetBack.Free;
  end;

  Check(RaisesProto(
    procedure
    var N: TNullableList;
    begin
      N := TNullableList.Create;
      try
        TProtobufSerializer.Serialize<TNullableList>(N);
      finally
        N.Free;
      end;
    end, EProtobufError), 'PROTO_NULLABLE_OF_REPEATED_REFUSED');

  Check(RaisesProto(
    procedure
    var N: TOneOfList;
    begin
      N := TOneOfList.Create;
      try
        TProtobufSerializer.Serialize<TOneOfList>(N);
      finally
        N.Free;
      end;
    end, EProtobufError), 'PROTO_REPEATED_IN_ONEOF_REFUSED');

  { A nil element used to be written as nothing, which made the list one
    shorter and moved every element after it. }
  Check(RaisesProto(
    procedure
    var N: TItemList;
    begin
      N := TItemList.Create;
      try
        N.Items.Add(TItem.Create);
        N.Items.Add(nil);
        TProtobufSerializer.Serialize<TItemList>(N);
      finally
        N.Free;
      end;
    end, EProtobufError), 'PROTO_NIL_MESSAGE_ELEMENT_REFUSED');

  { An unnumbered enum's number is its ordinal, and a number past the last
    one is no value of the type. field 1 varint 9. (TEnumShape, not
    TNumberedShape: a type's numbering is registered before its first use,
    and TNumberedShape is registered below.) }
  Check(RaisesProto(
    procedure
    begin
      TProtobufSerializer.Deserialize<TEnumShape>(TBytes.Create($08, $09)).Free;
    end, EProtobufInputError), 'PROTO_ENUM_NUMBER_OUT_OF_RANGE_REFUSED');

  { With a numbering in which ordinal 0 is NOT number 0, ordinal 0 is
    written - other readers take an absent enum to be number 0, which here
    is nOne. }
  { TNumbered's numbers are registered at startup, in the main block:
    configuration is closed once the first document has been written. }
  Numbered := TNumberedShape.Create;
  try
    Numbered.E := nZero;
    Data := TProtobufSerializer.Serialize<TNumberedShape>(Numbered);
    Check((Length(Data) = 2) and (Data[0] = $08) and (Data[1] = 5),
      'PROTO_ENUM_ORDINAL_ZERO_WITH_NONZERO_NUMBER_IS_WRITTEN');
    Numbered.E := nOne;
    Data := TProtobufSerializer.Serialize<TNumberedShape>(Numbered);
    Check((Length(Data) = 2) and (Data[1] = 0),
      'PROTO_ENUM_NUMBER_ZERO_NOT_ORDINAL_ZERO_IS_WRITTEN');
  finally
    Numbered.Free;
  end;
  Numbered := TProtobufSerializer.Deserialize<TNumberedShape>(Data);
  try
    Check(Numbered.E = nOne, 'PROTO_ENUM_NUMBER_ZERO_READS_BACK');
  finally
    Numbered.Free;
  end;
end;

{ ===========================================================================
  A scalar where a list belongs does not erase a list the caller owns
  =========================================================================== }

procedure TestPopulateKeepsList;
var
  Data: TBytes;
  L: TListShape;
  S: TScalarShape;
  Raised: Boolean;
begin
  Writeln;
  Writeln('-- MessagePack Populate: a scalar where a list belongs --');
  S := TScalarShape.Create;
  try
    S.Items := 5;
    Data := TMessagePackSerializer.Serialize<TScalarShape>(S);
  finally
    S.Free;
  end;
  L := TListShape.Create;
  try
    Raised := False;
    try
      TMessagePackSerializer.Populate<TListShape>(L, Data);
    except
      on E: EMessagePackInputError do Raised := True;
    end;
    Check(Raised, 'MSGPACK_SCALAR_WHERE_LIST_REFUSED');
    Check((L.Items.Count = 1) and (L.Items[0] = 7),
      'MSGPACK_SCALAR_WHERE_LIST_KEEPS_CALLERS_ITEMS');
  finally
    L.Free;
  end;
end;

{ ===========================================================================
  Dates: a custom pattern is read back with itself, and an offset is applied
  as an instant, before 1899-12-30 as after it
  =========================================================================== }

procedure TestDates;
const
  PATTERN_FORMATS: array[0..6] of TSerializationFormat = (
    TSerializationFormat.Json, TSerializationFormat.Xml,
    TSerializationFormat.Bson, TSerializationFormat.MessagePack,
    TSerializationFormat.Cbor, TSerializationFormat.Yaml,
    TSerializationFormat.Csv);
  MOMENTS: array[0..1] of Double = (46295.5213, -36522.5);
var
  F: TSerializationFormat;
  I: Integer;
  X, Back: TPatternShape;
  M: TMomentShape;
  Same: Boolean;
begin
  Writeln;
  Writeln('-- a custom date pattern, read back with itself --');
  for F in PATTERN_FORMATS do
  begin
    Same := True;
    for I := Low(MOMENTS) to High(MOMENTS) do
    begin
      X := TPatternShape.Create;
      try
        X.At := MOMENTS[I];
        X.Day := Trunc(MOMENTS[I]);
        try
          Back := TSerialization.Deserialize<TPatternShape>(
            TSerialization.Serialize<TPatternShape>(X, F), F);
          try
            Same := Same and (Abs(Back.At - X.At) < 1 / SecsPerDay) and
              (Back.Day = X.Day);
          finally
            Back.Free;
          end;
        except
          on E: Exception do
          begin
            Note(FmtName(F) + ': ' + E.ClassName + ': ' + E.Message);
            Same := False;
          end;
        end;
      finally
        X.Free;
      end;
    end;
    Check(Same, 'CUSTOM_DATE_PATTERN_ROUND_TRIP_' + UpperCase(FmtName(F)));
  end;

  Writeln;
  Writeln('-- an offset before 1899-12-30 --');
  { 07:00 at +01:00 is 06:00 UTC. The RTL applied the offset to the
    TDateTime linearly, which before 1899-12-30 moves it the wrong way. }
  M := TSerialization.Deserialize<TMomentShape>(TSerializationPayload.FromText(
    '{"At":"1800-01-01T07:00:00+01:00"}'), TSerializationFormat.Json);
  try
    Check(Abs(M.At - (-36522.25)) < 1 / SecsPerDay,
      'JSON_OFFSET_BEFORE_1899_IS_THE_INSTANT');
  finally
    M.Free;
  end;
  M := TSerialization.Deserialize<TMomentShape>(TSerializationPayload.FromText(
    'At: 1800-01-01T07:00:00+01:00' + #10), TSerializationFormat.Yaml);
  try
    Check(Abs(M.At - (-36522.25)) < 1 / SecsPerDay,
      'YAML_OFFSET_BEFORE_1899_IS_THE_INSTANT');
  finally
    M.Free;
  end;
end;

{ ===========================================================================
  RawByteString is TEXT in the code page it carries at run time: written as
  that text, read back as the same text, UTF-8 encoded. Arbitrary bytes
  belong in TBytes - no text type promises to carry them unchanged.
  =========================================================================== }

procedure TestRawByteString;

  function CarriedEverywhere(const AName: string;
    const AValue: RawByteString): Boolean;
  var
    F: TSerializationFormat;
    X, Back: TRawShape;
  begin
    Result := True;
    X := TRawShape.Create;
    try
      X.R := AValue;
      for F in TSerialization.ContractFormats do
        try
          Back := TSerialization.Deserialize<TRawShape>(
            TSerialization.Serialize<TRawShape>(X, F), F);
          try
            if (string(Back.R) <> string(AValue)) or
               (StringCodePage(Back.R) <> CP_UTF8) then
            begin
              Note(Format('%s %s: came back in code page %d',
                [AName, FmtName(F), StringCodePage(Back.R)]));
              Result := False;
            end;
          finally
            Back.Free;
          end;
        except
          on E: Exception do
          begin
            Note(AName + ' ' + FmtName(F) + ': ' + E.ClassName + ': ' + E.Message);
            Result := False;
          end;
        end;
    finally
      X.Free;
    end;
  end;

var
  Cyrillic: RawByteString;
  Georgian: UTF8String;
begin
  Writeln;
  Writeln('-- RawByteString is text in its runtime code page --');
  Check(CarriedEverywhere('ascii', RawByteString('plain text')),
    'RAWBYTESTRING_ASCII');
  { "Privet", as Windows-1251 bytes, marked as such. }
  Cyrillic := RawByteString(#$CF#$F0#$E8#$E2#$E5#$F2);
  SetCodePage(Cyrillic, 1251, False);
  Check(CarriedEverywhere('cp1251', Cyrillic), 'RAWBYTESTRING_CODEPAGE_TEXT');
  Georgian := UTF8String(#$10DA#$10DD#$10D3#$10D8' '#$0441#$0442);
  Check(CarriedEverywhere('utf8', RawByteString(Georgian)),
    'RAWBYTESTRING_UTF8_TEXT');
end;

var
  OwnershipBefore: Integer;
  OwnershipOk: Boolean = False;

begin
  ReportMemoryLeaksOnShutdown := True;
  { Configuration first: the first document freezes it. }
  TProtobufSerializer.RegisterEnumNumbers<TNumbered>([5, 0, 7]);
  try
    TestCrossShapeReads;
    OwnershipBefore := GFailures;
    TestOwnership;
    OwnershipOk := GFailures = OwnershipBefore;
    TestBsonIntegralDouble;
    TestProtobuf;
    TestPopulateKeepsList;
    TestDates;
    TestRawByteString;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  { A release gate of its own: nothing a read builds outlives the read. }
  Writeln('OWNERSHIP: ', IfThen(OwnershipOk, 'PASS', 'FAIL'));
  Writeln('CHECKS=', GChecks);
  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then
    Writeln('READER_CONTRACTS: PASS')
  else
  begin
    Writeln('READER_CONTRACTS: FAIL');
    ExitCode := 1;
  end;
end.
