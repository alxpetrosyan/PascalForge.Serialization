program BsonCore;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The BSON engine, against its documented default contract.

  Everything here goes through TBsonSerializer, which goes straight to the
  BSON engine. No format is registered in this program at all: using BSON
  directly never needs the registry.

  The checks that matter most are the ones about NATIVE types. A BSON
  implementation that quietly writes every number as a double, or a timestamp
  as a string, compiles and round-trips and is still wrong - so the tests
  read the bytes back as BSON and ask what element type they actually are. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.DateUtils, System.StrUtils, System.TypInfo,
  System.Generics.Collections,
  BsonModels in 'BsonModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Bson in '..\..\src\PascalForge.Bson.pas',
  PascalForge.Bson.Internal in '..\..\src\PascalForge.Bson.Internal.pas';

var
  GFailures: Integer = 0;

procedure Check(ACondition: Boolean; const AName: string);
begin
  if ACondition then
    Writeln(AName, ': PASS')
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

{ What element type did the bytes actually get? }
function KindOf(const AData: TBytes; const AName: string): TBsonKind;
var
  Doc, Element: TBsonValue;
begin
  Doc := TBsonEngine.ParseDocument(AData);
  try
    Element := Doc.Find(AName);
    if Element = nil then
      raise Exception.CreateFmt('No element named "%s".', [AName]);
    Result := Element.Kind;
  finally
    Doc.Free;
  end;
end;

function ElementOf(ADoc: TBsonValue; const AName: string): TBsonValue;
begin
  Result := ADoc.Find(AName);
  if Result = nil then
    raise Exception.CreateFmt('No element named "%s".', [AName]);
end;

procedure ConfigureContract;
begin
  TBsonSerializer.RegisterTypeSerializer<TCoordinate>(TCoordinateSerializer);
  TBsonSerializer.RegisterEnumMapping<TChannel>(['R', 'C', 'G']);
end;

procedure ConfigureDates;
begin
  { Weakest to strongest: global, then a type, then one field of that type.
    A member attribute beats all three. }
  TBsonSerializer.SetDateTimeRepresentation(
    TBsonDateTimeRepresentation.UnixSeconds);
  TBsonSerializer.RegisterDateTimeRepresentation<TClassDates>(
    TBsonDateTimeRepresentation.UnixMilliseconds);
  TBsonSerializer.RegisterDateTimeRepresentation<TFieldDates>(
    TBsonDateTimeRepresentation.UnixMilliseconds);
  TBsonSerializer.RegisterFieldDateTimeRepresentation<TFieldDates>('Stamp',
    TBsonDateTimeRepresentation.Native);
  TBsonSerializer.RegisterDateTimeRepresentation<TAttrDates>(
    TBsonDateTimeRepresentation.UnixMilliseconds);
end;

{ -------------------------------------------------------------- scalars --- }

procedure TestScalarRoot;
var
  Data: TBytes;
begin
  Writeln('-- a scalar at the root --');
  { A BSON document is the only thing that can be a root, so a bare scalar
    travels under the name "value" and comes back the same way. }
  Data := TBsonSerializer.Serialize<Integer>(42);
  Check((KindOf(Data, 'value') = TBsonKind.Int32) and
        (TBsonSerializer.Deserialize<Integer>(Data) = 42),
    'BSON_SCALAR_ROOT');
  Note(Format('%d bytes', [Length(Data)]));

  Data := TBsonSerializer.Serialize<Int64>(9007199254740993);
  Check((KindOf(Data, 'value') = TBsonKind.Int64) and
        (TBsonSerializer.Deserialize<Int64>(Data) = 9007199254740993),
    'BSON_INT64_ROOT_EXACT');
end;

{ ---------------------------------------------------------------- class --- }

function SampleShipment: TShipment;
begin
  Result := TShipment.Create;
  Result.Id := 4611686018427387904;      { far beyond a double's 53 bits }
  Result.Small := 4711;
  Result.Rate := 1.0845;
  Result.Amount := 128.55;
  Result.Consignee := 'Alice Sample';
  Result.Kind := TContractKind.Forward;
  Result.Channels := [TChannel.Retail, TChannel.Government];
  Result.Reference := StringToGUID('{3F2504E0-4F89-11D3-9A0C-0305E82C3301}');
  Result.Blob := TBytes.Create(1, 2, 3, 250, 251, 252);
  Result.Booked := EncodeDate(2026, 3, 14);
  Result.Cutoff := EncodeTime(17, 30, 0, 0);
  Result.Created := EncodeDateTime(2026, 3, 14, 9, 26, 53, 0);
  Result.Note := 'urgent';
  Result.Rebate := nil;
  Result.Secret := 'do not write me';
  Result.Address := TAddress.Create;
  Result.Address.Street := 'One Example Loop';
  Result.Address.City := 'Cupertino';
  Result.Lines := TOrderLines.Create;
  Result.Lines.Add(TOrderLine.Create);
  Result.Lines[0].Sku := 'A-1';
  Result.Lines[0].Quantity := 2;
  Result.Lines.Add(TOrderLine.Create);
  Result.Lines[1].Sku := 'B-2';
  Result.Lines[1].Quantity := 5;
  Result.Rates.Add('USD', 1.0);
  Result.Rates.Add('GBP', 0.79);
  Result.Codes := [10, 20, 30];
end;

procedure TestClassRoundtrip;
var
  P, Back: TShipment;
  Data: TBytes;
  Doc: TBsonValue;
  V: Currency;
begin
  Writeln('-- a class --');
  P := SampleShipment;
  try
    Data := TBsonSerializer.Serialize<TShipment>(P);
  finally
    P.Free;
  end;
  Note(Format('%d bytes', [Length(Data)]));

  Doc := TBsonEngine.ParseDocument(Data);
  try
    { Native types, checked as types rather than as values. }
    Check(ElementOf(Doc, 'Small').Kind = TBsonKind.Int32, 'BSON_INT32_NATIVE');
    Check(ElementOf(Doc, '_id').Kind = TBsonKind.Int64, 'BSON_INT64_NATIVE');
    Check(ElementOf(Doc, 'Rate').Kind = TBsonKind.Double, 'BSON_DOUBLE_NATIVE');
    Check((ElementOf(Doc, 'Blob').Kind = TBsonKind.Binary) and
          (ElementOf(Doc, 'Blob').Subtype = TBsonBinarySubtype.Generic),
      'BSON_BINARY_NATIVE');
    Check(ElementOf(Doc, 'Created').Kind = TBsonKind.DateTime,
      'BSON_DATETIME_NATIVE');
    { The standard UUID subtype, not a lowercase string inherited from JSON. }
    Check((ElementOf(Doc, 'Reference').Kind = TBsonKind.Binary) and
          (ElementOf(Doc, 'Reference').Subtype = TBsonBinarySubtype.Uuid),
      'BSON_GUID_POLICY');
    { Currency is a scaled Int64 in Delphi, and writing that integer is exact
      in both directions. }
    Check(ElementOf(Doc, 'Amount').Kind = TBsonKind.Int64,
      'BSON_CURRENCY_EXACT');
    { TDate and TTime are not instants, so they are not BSON datetimes. }
    Check((ElementOf(Doc, 'Booked').Kind = TBsonKind.Str) and
          (ElementOf(Doc, 'Booked').AsString = '2026-03-14') and
          (ElementOf(Doc, 'Cutoff').Kind = TBsonKind.Str),
      'BSON_DATE_AND_TIME_ARE_NOT_INSTANTS');
    Check(ElementOf(Doc, 'Kind').AsString = 'Forward', 'BSON_ENUM');
    Check(ElementOf(Doc, 'Channels').AsString = 'R,G', 'BSON_SET');
    Check(ElementOf(Doc, 'Note').AsString = 'urgent', 'BSON_NULLABLE');
    Check(Doc.Find('Rebate') = nil, 'BSON_EMPTY_NULLABLE_IS_OMITTED');
    Check(Doc.Find('Secret') = nil, 'BSON_IGNORE');
    Check(Doc.Find('Id') = nil, 'BSON_RENAME');
    Check(ElementOf(Doc, 'Address').Kind = TBsonKind.Doc, 'BSON_NESTED_OBJECT');
    Check((ElementOf(Doc, 'Lines').Kind = TBsonKind.Arr) and
          (ElementOf(Doc, 'Lines').Count = 2), 'BSON_LIST');
    Check(ElementOf(Doc, 'Rates').Kind = TBsonKind.Doc, 'BSON_DICTIONARY');
    Check((ElementOf(Doc, 'Codes').Kind = TBsonKind.Arr) and
          (ElementOf(Doc, 'Codes')[1].Kind = TBsonKind.Int32), 'BSON_ARRAY');
  finally
    Doc.Free;
  end;

  Back := TBsonSerializer.Deserialize<TShipment>(Data);
  try
    Check((Back.Id = 4611686018427387904) and (Back.Small = 4711) and
          (Abs(Back.Rate - 1.0845) < 1E-12) and (Back.Amount = 128.55) and
          (Back.Consignee = 'Alice Sample') and
          (Back.Kind = TContractKind.Forward) and
          (Back.Channels = [TChannel.Retail, TChannel.Government]) and
          (Back.Reference = StringToGUID('{3F2504E0-4F89-11D3-9A0C-0305E82C3301}')) and
          (Length(Back.Blob) = 6) and (Back.Blob[5] = 252) and
          (Back.Booked = EncodeDate(2026, 3, 14)) and
          SameDateTime(Back.Created, EncodeDateTime(2026, 3, 14, 9, 26, 53, 0)) and
          Back.Note.HasValue and (not Back.Rebate.HasValue) and
          (Back.Secret = '') and
          (Back.Address <> nil) and (Back.Address.City = 'Cupertino') and
          (Back.Lines <> nil) and (Back.Lines.Count = 2) and
          (Back.Lines[1].Sku = 'B-2') and
          Back.Rates.TryGetValue('GBP', V) and (V = 0.79) and
          (Length(Back.Codes) = 3) and (Back.Codes[2] = 30),
      'BSON_CLASS_ROUNDTRIP');
  finally
    Back.Free;
  end;
end;

{ --------------------------------------------------------------- record --- }

procedure TestRecordRoundtrip;
var
  Q, Back: TQuote;
  Data: TBytes;
begin
  Writeln('-- a record member --');
  Q := TQuote.Create;
  try
    Q.Symbol := 'EURUSD';
    Q.Bid.Amount := 1.0845;
    Q.Bid.Code := 'USD';
    Data := TBsonSerializer.Serialize<TQuote>(Q);
  finally
    Q.Free;
  end;
  Back := TBsonSerializer.Deserialize<TQuote>(Data);
  try
    Check((Back.Symbol = 'EURUSD') and (Back.Bid.Amount = 1.0845) and
          (Back.Bid.Code = 'USD'), 'BSON_RECORD_ROUNDTRIP');
  finally
    Back.Free;
  end;
end;

{ --------------------------------------------------- representations --- }

procedure TestRepresentations;
var
  R, Back: TRepresentations;
  Data: TBytes;
  Doc: TBsonValue;
  G: TGUID;
begin
  Writeln('-- BSON-specific representations --');
  G := StringToGUID('{3F2504E0-4F89-11D3-9A0C-0305E82C3301}');
  R := TRepresentations.Create;
  try
    R.TextGuid := G;
    R.NativeGuid := G;
    R.LossyAmount := 12.34;
    R.TextAmount := 12.34;
    R.ExactAmount := 922337203685.4775;
    Data := TBsonSerializer.Serialize<TRepresentations>(R);
  finally
    R.Free;
  end;

  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check(ElementOf(Doc, 'TextGuid').Kind = TBsonKind.Str,
      'BSON_GUID_STRING_REPRESENTATION');
    Check(ElementOf(Doc, 'NativeGuid').Subtype = TBsonBinarySubtype.Uuid,
      'BSON_GUID_BINARY_REPRESENTATION');
    Check(ElementOf(Doc, 'LossyAmount').Kind = TBsonKind.Double,
      'BSON_CURRENCY_DOUBLE_REPRESENTATION');
    Check(ElementOf(Doc, 'TextAmount').Kind = TBsonKind.Str,
      'BSON_CURRENCY_STRING_REPRESENTATION');
    Check(ElementOf(Doc, 'ExactAmount').Kind = TBsonKind.Int64,
      'BSON_CURRENCY_SCALED_INT64_DEFAULT');
  finally
    Doc.Free;
  end;

  Back := TBsonSerializer.Deserialize<TRepresentations>(Data);
  try
    { The scaled-integer default survives a value a double could not hold. }
    Check((Back.TextGuid = G) and (Back.NativeGuid = G) and
          (Back.TextAmount = 12.34) and
          (Back.ExactAmount = 922337203685.4775),
      'BSON_REPRESENTATION_ROUNDTRIP');
  finally
    Back.Free;
  end;
end;

{ ------------------------------------------------------------- reuse --- }

{ A document that mentions Address and nothing else, so "populated in place"
  and "left alone" can be told apart. Hand-built rather than serialized,
  because serializing a TReusable would write every member. }
function PartialDocument: TBytes;
var
  Doc, Address: TBsonValue;
begin
  Doc := TBsonValue.NewDocument;
  try
    Address := TBsonValue.NewDocument;
    Address.Add('Street', TBsonValue.NewString('Example Lane'));
    Doc.Add('Address', Address);
    Result := TBsonEngine.WriteDocument(Doc);
  finally
    Doc.Free;
  end;
end;

{ The same shape with an explicit null. A nil member is OMITTED on write - as
  it is in every format here - so an explicit null only ever arrives from
  somebody else's producer, and this is what it does when it does. }
function NullAddressDocument: TBytes;
var
  Doc: TBsonValue;
begin
  Doc := TBsonValue.NewDocument;
  try
    Doc.Add('Address', TBsonValue.NewNull);
    Result := TBsonEngine.WriteDocument(Doc);
  finally
    Doc.Free;
  end;
end;

procedure TestReuse;
var
  R: TReusable;
  Address: TAddress;
  Lines: TOrderLines;
  Seed: TReusable;
  Data: TBytes;
begin
  Writeln('-- reuse and detach --');
  R := TReusable.Create;
  try
    R.Address.City := 'Meadow';
    Address := R.Address;
    TBsonSerializer.Populate<TReusable>(R, PartialDocument);
    { The same instance, populated in place - and City, which the document
      never mentions, keeps what it had. }
    Check((R.Address = Address) and (R.Address.Street = 'Example Lane') and
          (R.Address.City = 'Meadow') and (R.Lines.Count = 0),
      'BSON_EXISTING_INSTANCE_REUSE');
  finally
    R.Free;
  end;

  Seed := TReusable.Create;
  try
    Seed.Address.Street := 'Example Lane';
    Seed.Lines.Add(TOrderLine.Create);
    Seed.Lines[0].Sku := 'NEW';
    Seed.Lines[0].Quantity := 1;
    Data := TBsonSerializer.Serialize<TReusable>(Seed);
  finally
    Seed.Free;
  end;

  R := TReusable.Create;
  try
    R.Lines.Add(TOrderLine.Create);
    R.Lines[0].Sku := 'OLD';
    Lines := R.Lines;
    TBsonSerializer.Populate<TReusable>(R, Data);
    { The container instance is kept and refilled; Clear on an owning list is
      what disposed of the old element. }
    Check((R.Lines = Lines) and (R.Lines.Count = 1) and
          (R.Lines[0].Sku = 'NEW'), 'BSON_CONTAINER_REUSE');
  finally
    R.Free;
  end;

  { Explicit null DETACHES without destroying. }
  R := TReusable.Create;
  Address := R.Address;
  try
    TBsonSerializer.Populate<TReusable>(R, NullAddressDocument);
    Check(R.Address = nil, 'BSON_NULL_DETACHES');
    { Still alive, because nothing here was entitled to free it. }
    Address.City := 'still here';
    Check(Address.City = 'still here', 'BSON_NULL_DOES_NOT_DESTROY');
  finally
    Address.Free;
    R.Free;
  end;
end;

{ ------------------------------------------------------------- dates --- }

procedure TestDatePolicies;
var
  G: TGlobalDates;
  C: TClassDates;
  F: TFieldDates;
  A: TAttrDates;
  Data: TBytes;
  Doc: TBsonValue;
  Stamp: TDateTime;
  BackG: TGlobalDates;
begin
  Writeln('-- date policies --');
  Stamp := EncodeDateTime(2026, 3, 14, 9, 26, 53, 0);

  G := TGlobalDates.Create;
  try
    G.Stamp := Stamp;
    Data := TBsonSerializer.Serialize<TGlobalDates>(G);
  finally
    G.Free;
  end;
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check((ElementOf(Doc, 'Stamp').Kind = TBsonKind.Int64) and
          (ElementOf(Doc, 'Stamp').AsInt64 = DateTimeToUnix(Stamp, True)),
      'BSON_DATE_GLOBAL_POLICY');
  finally
    Doc.Free;
  end;
  BackG := TBsonSerializer.Deserialize<TGlobalDates>(Data);
  try
    Check(SameDateTime(BackG.Stamp, Stamp), 'BSON_DATE_ROUNDTRIP');
  finally
    BackG.Free;
  end;

  C := TClassDates.Create;
  try
    C.Stamp := Stamp;
    C.Other := Stamp;
    Data := TBsonSerializer.Serialize<TClassDates>(C);
  finally
    C.Free;
  end;
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check(ElementOf(Doc, 'Stamp').AsInt64 = DateTimeToUnix(Stamp, True) * 1000,
      'BSON_DATE_CLASS_POLICY');
  finally
    Doc.Free;
  end;

  F := TFieldDates.Create;
  try
    F.Stamp := Stamp;
    F.Other := Stamp;
    Data := TBsonSerializer.Serialize<TFieldDates>(F);
  finally
    F.Free;
  end;
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check(ElementOf(Doc, 'Stamp').Kind = TBsonKind.DateTime,
      'BSON_DATE_FIELD_POLICY');
    { The same class, the other member: the class registration still applies. }
    Check((ElementOf(Doc, 'Other').Kind = TBsonKind.Int64) and
          (ElementOf(Doc, 'Other').AsInt64 = DateTimeToUnix(Stamp, True) * 1000),
      'BSON_DATE_POLICY_PRECEDENCE');
  finally
    Doc.Free;
  end;

  A := TAttrDates.Create;
  try
    A.Stamp := Stamp;
    A.Other := Stamp;
    Data := TBsonSerializer.Serialize<TAttrDates>(A);
  finally
    A.Free;
  end;
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check((ElementOf(Doc, 'Stamp').AsInt64 = DateTimeToUnix(Stamp, True)) and
          (ElementOf(Doc, 'Other').AsInt64 = DateTimeToUnix(Stamp, True) * 1000),
      'BSON_DATE_ATTRIBUTE_BEATS_REGISTRATION');
  finally
    Doc.Free;
  end;
end;

{ -------------------------------------------------- custom serializer --- }

procedure TestCustomSerializer;
var
  P, Back: TPlace;
  Data: TBytes;
  Doc: TBsonValue;
begin
  Writeln('-- a custom BSON serializer --');
  P := TPlace.Create;
  try
    P.Name := 'Greenwich';
    P.Where.Latitude := 51.4779;
    P.Where.Longitude := -0.0015;
    Data := TBsonSerializer.Serialize<TPlace>(P);
  finally
    P.Free;
  end;
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check((ElementOf(Doc, 'Where').Kind = TBsonKind.Arr) and
          (ElementOf(Doc, 'Where').Count = 2), 'BSON_CUSTOM_SERIALIZER');
  finally
    Doc.Free;
  end;
  Back := TBsonSerializer.Deserialize<TPlace>(Data);
  try
    Check((Back.Name = 'Greenwich') and
          (Abs(Back.Where.Latitude - 51.4779) < 1E-9),
      'BSON_CUSTOM_SERIALIZER_ROUNDTRIP');
  finally
    Back.Free;
  end;
end;

{ --------------------------------------------------------- plan cache --- }

procedure TestPlanCacheStable;
var
  Before, After, I: Integer;
  P: TShipment;
begin
  Writeln('-- the plan cache --');
  Before := TBsonEngine.PlanCount;
  for I := 1 to 50 do
  begin
    P := SampleShipment;
    try
      TBsonSerializer.Serialize<TShipment>(P);
    finally
      P.Free;
    end;
  end;
  After := TBsonEngine.PlanCount;
  Check(Before = After, 'BSON_PLAN_CACHE_STABLE');
  Note(Format('plans before %d, after %d', [Before, After]));
end;

{ ---------------------------------------------------------- bad input --- }

procedure TestBadInput;

  function RaisesWith(const AData: TBytes; out AMessage: string): Boolean;
  var
    Doc: TBsonValue;
  begin
    Result := False;
    AMessage := '';
    Doc := nil;
    try
      Doc := TBsonEngine.ParseDocument(AData);
    except
      on E: EBsonError do
      begin
        Result := True;
        AMessage := E.Message;
      end;
    end;
    Doc.Free;
  end;

var
  Msg: string;
  Data: TBytes;
begin
  Writeln('-- bytes that are not a document --');
  Check(RaisesWith(TBytes.Create(1, 2, 3), Msg), 'BSON_TOO_SHORT_RAISES');

  { A document claiming to be longer than it is. }
  Data := TBytes.Create($20, 0, 0, 0, 0);
  Check(RaisesWith(Data, Msg), 'BSON_TRUNCATED_RAISES');
  Note(Msg);

  { An element type byte the specification does not define. It must be named
    rather than skipped or coerced - a reader that guesses at an unknown
    type is a reader that silently corrupts. }
  Data := TBytes.Create(
    $08, 0, 0, 0,                              { document length = 8 }
    $63, Ord('x'), 0,                          { element type 0x63: not BSON }
    0);
  Check(RaisesWith(Data, Msg) and ContainsText(Msg, '0x63'),
    'BSON_UNSUPPORTED_TYPE_IS_NAMED');
  Note(Msg);
  Note(Msg);
end;

{ ------------------------------------------- a failed read's ownership --- }

type
  { Counts its live instances, so a check can see what a failed read left
    behind. }
  TTracked = class
  public
    class var Live: Integer;
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;
  end;

  TCSrc = class(TTracked)
  public
    X: Integer;
    Y: Int64;
  end;

  { Y is an Integer here: 5000000000 in the document is a failure part way. }
  TCDst = class(TTracked)
  public
    X: Integer;
    Y: Integer;
  end;

  TRecSrc = record
    O: TCSrc;
    N: Int64;
  end;

  TRecDst = record
    O: TCDst;
    N: Integer;
  end;

  TRecMemberSrc = class
  public
    R: TRecSrc;
    destructor Destroy; override;
  end;

  TRecMemberDst = class
  public
    R: TRecDst;
    destructor Destroy; override;
  end;

  { The constructor puts an object in the record: a failed read leaves it
    alone, and the destructor frees it exactly once. }
  TRecMemberPrefilled = class(TRecMemberDst)
  public
    constructor Create;
  end;

  TNullableRecSrc = class
  public
    R: TNullable<TRecSrc>;
    destructor Destroy; override;
  end;

  TNullableRecDst = class
  public
    R: TNullable<TRecDst>;
    destructor Destroy; override;
  end;

  TRecListSrc = class
  public
    L: TList<TRecSrc>;
    destructor Destroy; override;
  end;

  TRecListDst = class
  public
    L: TList<TRecDst>;
    destructor Destroy; override;
  end;

  TDynArraySrc = class
  public
    A: TArray<TCSrc>;
    destructor Destroy; override;
  end;

  TDynArrayDst = class
  public
    A: TArray<TCDst>;
    destructor Destroy; override;
  end;

  TCSrc3 = array[0..2] of TCSrc;
  TCDst3 = array[0..2] of TCDst;

  TStaticArraySrc = class
  public
    A: TCSrc3;
    destructor Destroy; override;
  end;

  TStaticArrayDst = class
  public
    A: TCDst3;
    destructor Destroy; override;
  end;

  TPlainListSrc = class
  public
    L: TList<TCSrc>;
    destructor Destroy; override;
  end;

  TPlainListDst = class
  public
    L: TList<TCDst>;
    destructor Destroy; override;
  end;

  TPlainDictDst = class
  public
    D: TDictionary<string, TCDst>;
    destructor Destroy; override;
  end;

  TSortedLines = class
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

procedure TTracked.AfterConstruction;
begin
  inherited;
  Inc(Live);
end;

procedure TTracked.BeforeDestruction;
begin
  Dec(Live);
  inherited;
end;

destructor TRecMemberSrc.Destroy;
begin
  R.O.Free;
  inherited;
end;

destructor TRecMemberDst.Destroy;
begin
  R.O.Free;
  inherited;
end;

constructor TRecMemberPrefilled.Create;
begin
  inherited Create;
  R.O := TCDst.Create;
end;

destructor TNullableRecSrc.Destroy;
begin
  if R.HasValue then R.Value.O.Free;
  inherited;
end;

destructor TNullableRecDst.Destroy;
begin
  if R.HasValue then R.Value.O.Free;
  inherited;
end;

destructor TRecListSrc.Destroy;
var
  I: Integer;
begin
  if L <> nil then
    for I := 0 to L.Count - 1 do L[I].O.Free;
  L.Free;
  inherited;
end;

destructor TRecListDst.Destroy;
var
  I: Integer;
begin
  if L <> nil then
    for I := 0 to L.Count - 1 do L[I].O.Free;
  L.Free;
  inherited;
end;

destructor TDynArraySrc.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(A) do A[I].Free;
  inherited;
end;

destructor TDynArrayDst.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(A) do A[I].Free;
  inherited;
end;

destructor TStaticArraySrc.Destroy;
var
  I: Integer;
begin
  for I := 0 to 2 do A[I].Free;
  inherited;
end;

destructor TStaticArrayDst.Destroy;
var
  I: Integer;
begin
  for I := 0 to 2 do A[I].Free;
  inherited;
end;

destructor TPlainListSrc.Destroy;
var
  I: Integer;
begin
  if L <> nil then
    for I := 0 to L.Count - 1 do L[I].Free;
  L.Free;
  inherited;
end;

destructor TPlainListDst.Destroy;
var
  I: Integer;
begin
  if L <> nil then
    for I := 0 to L.Count - 1 do L[I].Free;
  L.Free;
  inherited;
end;

destructor TPlainDictDst.Destroy;
var
  V: TCDst;
begin
  if D <> nil then
    for V in D.Values do V.Free;
  D.Free;
  inherited;
end;

constructor TSortedLines.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
  Lines.Sorted := True;
  Lines.Duplicates := dupError;
end;

destructor TSortedLines.Destroy;
begin
  Lines.Free;
  inherited;
end;

function NewC(AX: Integer; AY: Int64): TBsonValue;
begin
  Result := TBsonValue.NewDocument;
  Result.Add('X', TBsonValue.NewInt32(AX));
  if (AY >= Low(Integer)) and (AY <= High(Integer)) then
    Result.Add('Y', TBsonValue.NewInt32(AY))
  else
    Result.Add('Y', TBsonValue.NewInt64(AY));
end;

{ A document holding AInner under AName. }
function Wrap(const AName: string; AInner: TBsonValue): TBytes;
var
  Doc: TBsonValue;
begin
  Doc := TBsonValue.NewDocument;
  try
    Doc.Add(AName, AInner);
    Result := TBsonSerializer.WriteDocument(Doc);
  finally
    Doc.Free;
  end;
end;

{ The read raises EBsonInputError and leaves no instance it built alive. }
procedure CheckFailedReadFrees(const AData: TBytes; AReader: TProc<TBytes>;
  const AName: string);
var
  Before: Integer;
  Raised: Boolean;
begin
  Before := TTracked.Live;
  Raised := False;
  try
    AReader(AData);
  except
    on E: EBsonInputError do Raised := True;
    on E: Exception do Note(E.ClassName + ': ' + E.Message);
  end;
  if TTracked.Live <> Before then
    Note(Format('%d instances left alive', [TTracked.Live - Before]));
  Check(Raised and (TTracked.Live = Before), AName);
end;

procedure TestFailedReadOwnership;
var
  RS: TRecMemberSrc;
  NS: TNullableRecSrc;
  LS: TRecListSrc;
  AS1: TDynArraySrc;
  SS: TStaticArraySrc;
  PS: TPlainListSrc;
  Rec: TRecSrc;
  Data: TBytes;
  I, Before: Integer;
  Dict: TBsonValue;
  Back: TPlainDictDst;
begin
  Writeln('-- a read that fails part way frees what it built --');

  { A record member holding an object, and a later member of the record out
    of range: the record was read into a temporary and stored only on
    success, so the object went with it. }
  RS := TRecMemberSrc.Create;
  try
    RS.R.O := TCSrc.Create;
    RS.R.N := 5000000000;
    Data := TBsonSerializer.Serialize<TRecMemberSrc>(RS);
  finally
    RS.Free;
  end;
  CheckFailedReadFrees(Data,
    procedure(D: TBytes)
    begin
      TBsonSerializer.Deserialize<TRecMemberDst>(D).Free;
    end, 'BSON_FAILED_READ_RECORD_FREES_ITS_OBJECT');
  CheckFailedReadFrees(Data,
    procedure(D: TBytes)
    begin
      TBsonSerializer.Deserialize<TRecMemberPrefilled>(D).Free;
    end, 'BSON_FAILED_READ_RECORD_KEEPS_CONSTRUCTOR_OBJECT');

  NS := TNullableRecSrc.Create;
  try
    Rec.O := TCSrc.Create;
    Rec.N := 5000000000;
    NS.R := Rec;
    Data := TBsonSerializer.Serialize<TNullableRecSrc>(NS);
  finally
    NS.Free;
  end;
  CheckFailedReadFrees(Data,
    procedure(D: TBytes)
    begin
      TBsonSerializer.Deserialize<TNullableRecDst>(D).Free;
    end, 'BSON_FAILED_READ_NULLABLE_RECORD_FREES_ITS_OBJECT');

  LS := TRecListSrc.Create;
  try
    LS.L := TList<TRecSrc>.Create;
    for I := 1 to 3 do
    begin
      Rec.O := TCSrc.Create;
      if I = 3 then Rec.N := 5000000000 else Rec.N := I;
      LS.L.Add(Rec);
    end;
    Data := TBsonSerializer.Serialize<TRecListSrc>(LS);
  finally
    LS.Free;
  end;
  CheckFailedReadFrees(Data,
    procedure(D: TBytes)
    begin
      TBsonSerializer.Deserialize<TRecListDst>(D).Free;
    end, 'BSON_FAILED_READ_LIST_OF_RECORDS_FREES_THEIR_OBJECTS');

  { Arrays: the elements were collected and assembled only at the end. }
  AS1 := TDynArraySrc.Create;
  try
    SetLength(AS1.A, 3);
    for I := 0 to 2 do
    begin
      AS1.A[I] := TCSrc.Create;
      if I = 2 then AS1.A[I].Y := 5000000000;
    end;
    Data := TBsonSerializer.Serialize<TDynArraySrc>(AS1);
  finally
    AS1.Free;
  end;
  CheckFailedReadFrees(Data,
    procedure(D: TBytes)
    begin
      TBsonSerializer.Deserialize<TDynArrayDst>(D).Free;
    end, 'BSON_FAILED_READ_DYNAMIC_ARRAY_FREES_ELEMENTS');

  SS := TStaticArraySrc.Create;
  try
    for I := 0 to 2 do
    begin
      SS.A[I] := TCSrc.Create;
      if I = 2 then SS.A[I].Y := 5000000000;
    end;
    Data := TBsonSerializer.Serialize<TStaticArraySrc>(SS);
  finally
    SS.Free;
  end;
  CheckFailedReadFrees(Data,
    procedure(D: TBytes)
    begin
      TBsonSerializer.Deserialize<TStaticArrayDst>(D).Free;
    end, 'BSON_FAILED_READ_STATIC_ARRAY_FREES_ELEMENTS');

  { A non-owning container the read constructed: freeing it alone orphaned
    every element already added. }
  PS := TPlainListSrc.Create;
  try
    PS.L := TList<TCSrc>.Create;
    for I := 0 to 2 do
    begin
      PS.L.Add(TCSrc.Create);
      if I = 2 then PS.L[I].Y := 5000000000;
    end;
    Data := TBsonSerializer.Serialize<TPlainListSrc>(PS);
  finally
    PS.Free;
  end;
  CheckFailedReadFrees(Data,
    procedure(D: TBytes)
    begin
      TBsonSerializer.Deserialize<TPlainListDst>(D).Free;
    end, 'BSON_FAILED_READ_PLAIN_LIST_FREES_ELEMENTS');

  Dict := TBsonValue.NewDocument;
  for I := 1 to 5 do
    if I = 5 then Dict.Add('k' + IntToStr(I), NewC(I, 5000000000))
    else Dict.Add('k' + IntToStr(I), NewC(I, I));
  CheckFailedReadFrees(Wrap('D', Dict),
    procedure(D: TBytes)
    begin
      TBsonSerializer.Deserialize<TPlainDictDst>(D).Free;
    end, 'BSON_FAILED_READ_PLAIN_DICTIONARY_FREES_VALUES');

  { A key twice into a non-owning dictionary: the later value wins, as it
    always did, and the one built for the earlier occurrence is freed rather
    than dropped. }
  Dict := TBsonValue.NewDocument;
  Dict.Add('qa', NewC(1, 1));
  Dict.Add('qa', NewC(2, 2));
  Data := Wrap('D', Dict);
  Before := TTracked.Live;
  Back := TBsonSerializer.Deserialize<TPlainDictDst>(Data);
  try
    Check((Back.D.Count = 1) and (Back.D['qa'].X = 2),
      'BSON_DUPLICATE_KEY_LAST_WINS');
  finally
    Back.Free;
  end;
  Check(TTracked.Live = Before, 'BSON_DUPLICATE_KEY_EARLIER_VALUE_FREED');
end;

procedure TestContainerRefusal;
var
  Arr: TBsonValue;
  Raised: Boolean;
  Msg: string;
begin
  Writeln('-- what a container refuses is BSON input --');
  { A sorted TStringList with dupError, made by the constructor, and a
    document with a line twice. The container's EStringListError reached
    the caller as it was. }
  Arr := TBsonValue.NewArray;
  Arr.Add(TBsonValue.NewString('b'));
  Arr.Add(TBsonValue.NewString('a'));
  Arr.Add(TBsonValue.NewString('b'));
  Raised := False;
  try
    TBsonSerializer.Deserialize<TSortedLines>(Wrap('Lines', Arr)).Free;
  except
    on E: EBsonInputError do
    begin
      Raised := True;
      Msg := E.Message;
    end;
    on E: Exception do Note(E.ClassName + ': ' + E.Message);
  end;
  Note(Msg);
  Check(Raised and ContainsText(Msg, 'TStringList'),
    'BSON_CONTAINER_REFUSAL_IS_INPUT_ERROR');
end;

{ ---------------------------------------------- dates Delphi encodes oddly --- }

type
  TWhen = class
  public
    At: TDateTime;
  end;

  TWhenMs = class
  public
    [BsonDateTimeRepresentation(TBsonDateTimeRepresentation.UnixMilliseconds)]
    At: TDateTime;
  end;

  TWhenSec = class
  public
    [BsonDateTimeRepresentation(TBsonDateTimeRepresentation.UnixSeconds)]
    At: TDateTime;
  end;

  TWhenIso = class
  public
    [BsonDateTimeRepresentation(TBsonDateTimeRepresentation.StringIso8601)]
    At: TDateTime;
  end;

  TWhenCustom = class
  public
    [BsonDateTimeRepresentation('yyyy"-"mm"-"dd hh":"nn":"ss')]
    At: TDateTime;
  end;

function WriteRefused(AProc: TProc): Boolean;
begin
  try
    AProc;
    Result := False;
  except
    on E: ESerializationUnsupported do Result := True;
    on E: Exception do
    begin
      Note(E.ClassName + ': ' + E.Message);
      Result := False;
    end;
  end;
end;

procedure TestDatesBeforeDelphiEpoch;
const
  { 1800-01-01T12:00Z and 1899-12-29T06:00Z, counted by hand from the
    calendar. }
  AT_1800 = -5364619200000;
  AT_1899 = -2209226400000;
var
  V1800, V1899, VHalf: TDateTime;
  W: TWhen;
  WM: TWhenMs;
  WS: TWhenSec;
  WI: TWhenIso;
  BackW: TWhen;
  BackM: TWhenMs;
  BackS: TWhenSec;
  BackI: TWhenIso;
  Data: TBytes;
  Doc: TBsonValue;
begin
  Writeln('-- a TDateTime before 1899-12-30 with a time of day --');
  { Such a TDateTime is a negative day with a POSITIVE time of day: -1.25 is
    29 December 06:00. The writers computed the instant linearly and put it
    a day early. }
  V1800 := EncodeDateTime(1800, 1, 1, 12, 0, 0, 0);
  V1899 := EncodeDateTime(1899, 12, 29, 6, 0, 0, 0);
  VHalf := EncodeDateTime(1899, 12, 29, 6, 0, 0, 500);

  W := TWhen.Create;
  try
    W.At := V1800;
    Data := TBsonSerializer.Serialize<TWhen>(W);
  finally
    W.Free;
  end;
  Doc := TBsonEngine.ParseDocument(Data);
  try
    { Parsed back through the reader, which was always right: the instant
      the bytes state is the one written. }
    Check(SameDateTime(ElementOf(Doc, 'At').AsDateTime, V1800),
      'BSON_DATETIME_BEFORE_1899_NATIVE_INSTANT');
  finally
    Doc.Free;
  end;
  BackW := TBsonSerializer.Deserialize<TWhen>(Data);
  try
    Check(SameDateTime(BackW.At, V1800), 'BSON_DATETIME_BEFORE_1899_NATIVE_ROUNDTRIP');
  finally
    BackW.Free;
  end;

  WM := TWhenMs.Create;
  try
    WM.At := V1899;
    Data := TBsonSerializer.Serialize<TWhenMs>(WM);
  finally
    WM.Free;
  end;
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check(ElementOf(Doc, 'At').AsInt64 = AT_1899,
      'BSON_DATETIME_BEFORE_1899_UNIX_MILLISECONDS');
  finally
    Doc.Free;
  end;
  BackM := TBsonSerializer.Deserialize<TWhenMs>(Data);
  try
    Check(SameDateTime(BackM.At, V1899),
      'BSON_DATETIME_BEFORE_1899_UNIX_MILLISECONDS_ROUNDTRIP');
  finally
    BackM.Free;
  end;

  { Whole seconds round down: 06:00:00.500 before 1970 is second ...400,
    not ...399. }
  WS := TWhenSec.Create;
  try
    WS.At := VHalf;
    Data := TBsonSerializer.Serialize<TWhenSec>(WS);
    WS.At := V1800;
    Doc := TBsonEngine.ParseDocument(TBsonSerializer.Serialize<TWhenSec>(WS));
    try
      Check(ElementOf(Doc, 'At').AsInt64 = AT_1800 div 1000,
        'BSON_DATETIME_BEFORE_1899_UNIX_SECONDS');
    finally
      Doc.Free;
    end;
  finally
    WS.Free;
  end;
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check(ElementOf(Doc, 'At').AsInt64 = AT_1899 div 1000,
      'BSON_UNIX_SECONDS_ROUND_DOWN_BEFORE_1970');
  finally
    Doc.Free;
  end;
  BackS := TBsonSerializer.Deserialize<TWhenSec>(Data);
  try
    Check(SameDateTime(BackS.At, V1899), 'BSON_UNIX_SECONDS_ROUNDTRIP_BEFORE_1970');
  finally
    BackS.Free;
  end;

  { ISO text: the writer was right, the reader added the time to a negative
    day and read 1850-06-15T12:00 as the 16th. }
  BackI := TBsonSerializer.Deserialize<TWhenIso>(
    Wrap('At', TBsonValue.NewString('1850-06-15T12:00:00')));
  try
    Check(SameDateTime(BackI.At, EncodeDateTime(1850, 6, 15, 12, 0, 0, 0)),
      'BSON_ISO_BEFORE_1899_READ');
  finally
    BackI.Free;
  end;
  WI := TWhenIso.Create;
  try
    WI.At := V1899;
    Data := TBsonSerializer.Serialize<TWhenIso>(WI);
  finally
    WI.Free;
  end;
  BackI := TBsonSerializer.Deserialize<TWhenIso>(Data);
  try
    Check(SameDateTime(BackI.At, V1899), 'BSON_ISO_BEFORE_1899_ROUNDTRIP');
  finally
    BackI.Free;
  end;
end;

procedure TestDatesOutsideTheCalendar;
var
  Before1, After9999: TDateTime;
begin
  Writeln('-- a TDateTime outside the years 1 to 9999 is not written --');
  { Every reader refuses one, so writing it produced what the reader then
    refused - and text wrote a day before year 1 as 0000-00-00. }
  Before1 := EncodeDate(1, 1, 1) - 1;
  After9999 := EncodeDate(9999, 12, 31) + 1;
  Check(WriteRefused(
    procedure
    var
      W: TWhen;
    begin
      W := TWhen.Create;
      try
        W.At := Before1;
        TBsonSerializer.Serialize<TWhen>(W);
      finally
        W.Free;
      end;
    end), 'BSON_DATETIME_BEFORE_YEAR_1_REFUSED');
  Check(WriteRefused(
    procedure
    var
      W: TWhen;
    begin
      W := TWhen.Create;
      try
        W.At := After9999;
        TBsonSerializer.Serialize<TWhen>(W);
      finally
        W.Free;
      end;
    end), 'BSON_DATETIME_AFTER_9999_REFUSED');
  Check(WriteRefused(
    procedure
    var
      W: TWhenMs;
    begin
      W := TWhenMs.Create;
      try
        W.At := After9999;
        TBsonSerializer.Serialize<TWhenMs>(W);
      finally
        W.Free;
      end;
    end), 'BSON_UNIX_MILLISECONDS_AFTER_9999_REFUSED');
  Check(WriteRefused(
    procedure
    var
      W: TWhenIso;
    begin
      W := TWhenIso.Create;
      try
        W.At := Before1;
        TBsonSerializer.Serialize<TWhenIso>(W);
      finally
        W.Free;
      end;
    end), 'BSON_ISO_BEFORE_YEAR_1_REFUSED');
  Check(WriteRefused(
    procedure
    var
      W: TWhenCustom;
    begin
      W := TWhenCustom.Create;
      try
        W.At := Before1;
        TBsonSerializer.Serialize<TWhenCustom>(W);
      finally
        W.Free;
      end;
    end), 'BSON_CUSTOM_PATTERN_BEFORE_YEAR_1_REFUSED');
end;

{ ------------------------------------------------------------ nesting --- }

type
  TNode = class
  public
    Tag: Integer;
    Child: TNode;
    destructor Destroy; override;
  end;

  TRecNode = record
    Tag: Integer;
    Kids: array of TRecNode;
  end;

  TRecHolder = class
  public
    Root: TRecNode;
  end;

  { A list whose elements are its own type. }
  TNodeList = class;
  TNodeList = class(TList<TNodeList>)
  end;

  TTextProbe = class
  public
    S: string;
  end;

destructor TNode.Destroy;
begin
  Child.Free;
  inherited;
end;

function NodeChain(ACount: Integer): TNode;
var
  I: Integer;
  Cur: TNode;
begin
  Result := TNode.Create;
  Cur := Result;
  for I := 2 to ACount do
  begin
    Cur.Child := TNode.Create;
    Cur.Child.Tag := I;
    Cur := Cur.Child;
  end;
end;

{ Built from the leaf up, since a record is a value. }
function RecordChain(ADepth: Integer): TRecNode;
var
  I: Integer;
  Parent: TRecNode;
begin
  Result.Tag := ADepth;
  Result.Kids := nil;
  for I := ADepth - 1 downto 1 do
  begin
    Parent.Tag := I;
    Parent.Kids := nil;
    SetLength(Parent.Kids, 1);
    Parent.Kids[0] := Result;
    Result := Parent;
  end;
end;

function LimitRefused(AProc: TProc): Boolean;
begin
  try
    AProc;
    Result := False;
  except
    on E: ESerializationLimitExceeded do Result := True;
    on E: Exception do
    begin
      Note(E.ClassName + ': ' + E.Message);
      Result := False;
    end;
  end;
end;

procedure TestNesting;
var
  N, Back: TNode;
  Data: TBytes;
  Depth: Integer;
  L, Inner, BackL: TNodeList;
  Raised: Boolean;
  H: TRecHolder;
  Rec: TRecNode;
begin
  Writeln('-- nesting: every object, record, array and list counts one --');
  N := NodeChain(60);
  try
    Data := TBsonSerializer.Serialize<TNode>(N);
  finally
    N.Free;
  end;
  Back := TBsonSerializer.Deserialize<TNode>(Data);
  try
    Depth := 0;
    N := Back;
    while N <> nil do
    begin
      Inc(Depth);
      N := N.Child;
    end;
  finally
    Back.Free;
  end;
  Check(Depth = 60, 'BSON_CHAIN_OF_60_WRITTEN_AND_READ');

  Check(LimitRefused(
    procedure
    var
      C: TNode;
    begin
      C := NodeChain(65);
      try
        TBsonSerializer.Serialize<TNode>(C);
      finally
        C.Free;
      end;
    end), 'BSON_CHAIN_OF_65_REFUSED');

  { A record holding a dynamic array of itself nests with no object in it:
    at 300 it wrote what the reader refuses, and at 1000 the writer ran out
    of stack. The holder, then a record and an array per step: 31 records
    are 62 levels, 33 are 66. }
  H := TRecHolder.Create;
  try
    H.Root := RecordChain(31);
    Data := TBsonSerializer.Serialize<TRecHolder>(H);
  finally
    H.Free;
  end;
  H := TBsonSerializer.Deserialize<TRecHolder>(Data);
  try
    Depth := 1;
    Rec := H.Root;
    while Length(Rec.Kids) = 1 do
    begin
      Inc(Depth);
      Rec := Rec.Kids[0];
    end;
  finally
    H.Free;
  end;
  Check(Depth = 31, 'BSON_RECURSIVE_RECORD_31_WRITTEN_AND_READ');
  Check(LimitRefused(
    procedure
    var
      H: TRecHolder;
    begin
      H := TRecHolder.Create;
      try
        H.Root := RecordChain(33);
        TBsonSerializer.Serialize<TRecHolder>(H);
      finally
        H.Free;
      end;
    end), 'BSON_RECURSIVE_RECORD_33_REFUSED');
  Check(LimitRefused(
    procedure
    var
      H: TRecHolder;
    begin
      H := TRecHolder.Create;
      try
        H.Root := RecordChain(1000);
        TBsonSerializer.Serialize<TRecHolder>(H);
      finally
        H.Free;
      end;
    end), 'BSON_RECURSIVE_RECORD_1000_REFUSED');
  Check(TSerializationGraphGuard.Level = 0, 'BSON_LEVEL_RESTORED_AFTER_REFUSAL');

  { The plan of a list of its own type was built inside itself for ever;
    now a list holding another is written, and one holding itself is the
    cycle it is. }
  L := TNodeList.Create;
  Inner := TNodeList.Create;
  try
    L.Add(Inner);
    Data := TBsonSerializer.Serialize<TNodeList>(L);
  finally
    Inner.Free;
    L.Free;
  end;
  BackL := TBsonSerializer.Deserialize<TNodeList>(Data);
  try
    Check((BackL.Count = 1) and (BackL[0] <> nil) and (BackL[0].Count = 0),
      'BSON_SELF_TYPED_LIST_ROUNDTRIP');
  finally
    for Inner in BackL do Inner.Free;
    BackL.Free;
  end;
  L := TNodeList.Create;
  try
    L.Add(L);
    Raised := False;
    try
      TBsonSerializer.Serialize<TNodeList>(L);
    except
      on E: EBsonError do Raised := ContainsText(E.Message, 'cycle');
    end;
    Check(Raised, 'BSON_LIST_HOLDING_ITSELF_IS_A_CYCLE');
  finally
    L.Free;
  end;
end;

procedure TestUnpairedSurrogate;
var
  P, Back: TTextProbe;
  Data: TBytes;
begin
  Writeln('-- text UTF-8 cannot encode --');
  Check(WriteRefused(
    procedure
    var
      T: TTextProbe;
    begin
      T := TTextProbe.Create;
      try
        T.S := 'a' + Char($D800) + 'b';
        TBsonSerializer.Serialize<TTextProbe>(T);
      finally
        T.Free;
      end;
    end), 'BSON_UNPAIRED_SURROGATE_REFUSED');
  P := TTextProbe.Create;
  try
    P.S := 'a' + Char($D83D) + Char($DE00);
    Data := TBsonSerializer.Serialize<TTextProbe>(P);
  finally
    P.Free;
  end;
  Back := TBsonSerializer.Deserialize<TTextProbe>(Data);
  try
    Check(Back.S = 'a' + Char($D83D) + Char($DE00), 'BSON_SURROGATE_PAIR_ROUNDTRIP');
  finally
    Back.Free;
  end;
end;

begin
  try
    ConfigureContract;
    TestScalarRoot;
    Writeln;
    TestClassRoundtrip;
    Writeln;
    TestRecordRoundtrip;
    Writeln;
    TestRepresentations;
    Writeln;
    TestReuse;
    Writeln;
    TestCustomSerializer;
    Writeln;
    TestPlanCacheStable;
    Writeln;
    TestBadInput;
    Writeln;
    TestFailedReadOwnership;
    Writeln;
    TestContainerRefusal;
    Writeln;
    TestDatesBeforeDelphiEpoch;
    Writeln;
    TestDatesOutsideTheCalendar;
    Writeln;
    TestNesting;
    Writeln;
    TestUnpairedSurrogate;
    Writeln;
    { Everything above ran with no date configuration, which is what the
      default-contract checks needed: SetDateTimeRepresentation is global and
      would otherwise have moved every timestamp in the program. }
    TBsonSerializer.ResetConfiguration;
    ConfigureDates;
    TestDatePolicies;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then
    Writeln('BSON_CORE: PASS')
  else
  begin
    Writeln('BSON_CORE: FAIL');
    ExitCode := 1;
  end;
end.
