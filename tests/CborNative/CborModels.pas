unit CborModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{$SCOPEDENUMS ON}

{ The contracts the CBOR tests serialize.

  These are deliberately ordinary Delphi declarations. The point of the CBOR
  contract path is that a type which was never written with CBOR in mind
  still works, so nothing here is shaped to suit the encoder. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  PascalForge.Nullable,
  PascalForge.Cbor;

type
  TDelivery = (Immediate, NextDay, Deferred);

  TAddress = class
  public
    Street: string;
    City: string;
    Postcode: string;
  end;

  TLine = class
  public
    Description: string;
    Quantity: Integer;
    UnitPrice: Currency;
  end;

  { Every native Delphi shape CBOR has a counterpart for, in one place. }
  TShipment = class
  public
    Reference: string;
    Amount: Currency;
    Rate: Double;
    Count: Integer;
    Ticks: Int64;
    Huge: UInt64;
    Paid: Boolean;
    Raised: TDateTime;
    Id: TGUID;
    Receipt: TBytes;
    Delivery: TDelivery;
    Tags: TArray<string>;
    Shipper: TAddress;
    Lines: TObjectList<TLine>;
    [CborIgnore] Scratch: string;
    [CborName('note')] Remark: string;
    Approved: TNullable<Boolean>;
    Cancelled: TNullable<Boolean>;
    constructor Create;
    destructor Destroy; override;
  end;

  { The representation attributes, each on its own member so that a failure
    names exactly one decision. }
  TRepresentations = class
  public
    [CborDateTimeRepresentation(TCborDateTimeRepresentation.EpochTagged)]
    Epoch: TDateTime;
    [CborDateTimeRepresentation(TCborDateTimeRepresentation.Rfc3339Tagged)]
    Text: TDateTime;
    [CborDateTimeRepresentation(TCborDateTimeRepresentation.UnixMilliseconds)]
    Millis: TDateTime;
    [CborGuidRepresentation(TCborGuidRepresentation.TaggedUuid)]
    Tagged: TGUID;
    [CborGuidRepresentation(TCborGuidRepresentation.LowercaseString)]
    Spelled: TGUID;
    [CborGuidRepresentation(TCborGuidRepresentation.RawBytes)]
    Raw: TGUID;
    [CborCurrencyRepresentation(TCborCurrencyRepresentation.DecimalFraction)]
    Exact: Currency;
    [CborCurrencyRepresentation(TCborCurrencyRepresentation.Double)]
    Approximate: Currency;
    [CborCurrencyRepresentation(TCborCurrencyRepresentation.DecimalString)]
    Spoken: Currency;
    [CborEnumRepresentation(TCborEnumRepresentation.Name)]
    ByName: TDelivery;
    [CborEnumRepresentation(TCborEnumRepresentation.Value)]
    ByValue: TDelivery;
  end;

  { Scripts that must survive unchanged: the UTF-8 contract is the same one
    every other format in this library is held to. }
  TScripts = class
  public
    Georgian: string;
    Cyrillic: string;
    Cjk: string;
    Emoji: string;
    Combining: string;
  end;

  { ---- The release hardening contracts ----

    What a failed read frees, what the writer refuses, and the dates at the
    edges. Each is the smallest shape that showed a defect. }

  { Counts its live instances, so a check can tell a read that freed what it
    built from one that leaked it. }
  TTracked = class
  public
    class var Live: Integer;
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;
  end;

  { Written with an Int64 Y and read with an Integer one: 5000000000 fails the
    read at exactly the element chosen. }
  TCSrc = class(TTracked)
  public
    X: Integer;
    Y: Int64;
  end;

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

  TCSrc3 = array[0..2] of TCSrc;
  TCDst3 = array[0..2] of TCDst;

  { Every shape a failed read has to clean up after. A check fills ONE of
    them, with a value that fails part way; each class frees all it holds. }
  TShapesSrc = class(TTracked)
  public
    R: TRecSrc;
    NR: TNullable<TRecSrc>;
    LR: TList<TRecSrc>;
    A: TArray<TCSrc>;
    S: TCSrc3;
    L: TList<TCSrc>;
    D: TDictionary<string, TCSrc>;
    destructor Destroy; override;
  end;

  TShapesDst = class(TTracked)
  public
    R: TRecDst;
    NR: TNullable<TRecDst>;
    LR: TList<TRecDst>;
    A: TArray<TCDst>;
    S: TCDst3;
    L: TList<TCDst>;
    D: TDictionary<string, TCDst>;
    destructor Destroy; override;
  end;

  TItem = class(TTracked)
  public
    X: Integer;
  end;

  TRecPair = record
    A: TItem;
    B: TItem;
    N: Integer;
  end;

  { A record whose objects the constructor makes: a read fills them in
    place. }
  TRootRecCtor = class(TTracked)
  public
    R: TRecPair;
    constructor Create;
    destructor Destroy; override;
  end;

  { The same record with only A in it, so that B and N are members the
    document leaves out. }
  TRecPartial = record
    A: TItem;
  end;

  TRootRecPartial = class(TTracked)
  public
    R: TRecPartial;
    destructor Destroy; override;
  end;

  { A dictionary that does not own its values, which the reader builds. }
  TRootDict = class(TTracked)
  public
    D: TDictionary<string, TItem>;
    destructor Destroy; override;
  end;

  { One that does, which the constructor builds. }
  TRootOwnedDict = class(TTracked)
  public
    D: TObjectDictionary<string, TItem>;
    constructor Create;
    destructor Destroy; override;
  end;

  TStringsSource = class
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  { A sorted list that refuses duplicates, as its constructor configured it. }
  TSortedStrings = class
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  { Containers declared to hold TObject, which a list or dictionary is. }
  TSelfList = class
  public
    Items: TList<TObject>;
    constructor Create;
    destructor Destroy; override;
  end;

  TSelfDict = class
  public
    Map: TDictionary<string, TObject>;
    constructor Create;
    destructor Destroy; override;
  end;

  { A record that nests through a dynamic array of itself, with no object
    anywhere in the chain. }
  TRecNode = record
    Tag: Integer;
    Kids: array of TRecNode;
  end;

  TRecHolder = class
  public
    Root: TRecNode;
  end;

  TNode = class
  public
    Id: Integer;
    Child: TNode;
    destructor Destroy; override;
  end;

  TMapNode = class
  public
    Id: Integer;
    Kids: TObjectDictionary<string, TMapNode>;
    constructor Create;
    destructor Destroy; override;
  end;

  { A pointer member is refused by the writer, so a TBad key or value makes
    the dictionary writer fail on one side of a pair. }
  TBad = class
  public
    P: Pointer;
  end;

  TGood = class
  public
    S: string;
  end;

  TValueRaises = class
  public
    Map: TObjectDictionary<string, TBad>;
    constructor Create;
    destructor Destroy; override;
  end;

  TKeyRaises = class
  public
    Map: TObjectDictionary<TBad, TGood>;
    constructor Create;
    destructor Destroy; override;
  end;

  TCurrencyRec = record
    C: Currency;
  end;

  TVariantRec = record
    C: Variant;
  end;

  TDateProbe = class
  public
    D: TDateTime;
  end;

  TEpochCounts = class
  public
    [CborDateTimeRepresentation(TCborDateTimeRepresentation.UnixSeconds)]
    Secs: TDateTime;
    [CborDateTimeRepresentation(TCborDateTimeRepresentation.UnixMilliseconds)]
    Millis: TDateTime;
  end;

  TDayPattern = class
  public
    [CborDateTimeRepresentation('yyyy-mm-dd')]
    Day: TDate;
  end;

implementation

constructor TShipment.Create;
begin
  inherited Create;
  Shipper := TAddress.Create;
  Lines := TObjectList<TLine>.Create(True);
end;

destructor TShipment.Destroy;
begin
  Lines.Free;
  Shipper.Free;
  inherited Destroy;
end;

procedure TTracked.AfterConstruction;
begin
  inherited AfterConstruction;
  AtomicIncrement(Live);
end;

procedure TTracked.BeforeDestruction;
begin
  AtomicDecrement(Live);
  inherited BeforeDestruction;
end;

destructor TShapesSrc.Destroy;
var
  I: Integer;
  O: TCSrc;
begin
  R.O.Free;
  if NR.HasValue then NR.Value.O.Free;
  if LR <> nil then
    for I := 0 to LR.Count - 1 do LR[I].O.Free;
  LR.Free;
  for O in A do O.Free;
  for O in S do O.Free;
  if L <> nil then
    for O in L do O.Free;
  L.Free;
  if D <> nil then
    for O in D.Values do O.Free;
  D.Free;
  inherited Destroy;
end;

destructor TShapesDst.Destroy;
var
  I: Integer;
  O: TCDst;
begin
  R.O.Free;
  if NR.HasValue then NR.Value.O.Free;
  if LR <> nil then
    for I := 0 to LR.Count - 1 do LR[I].O.Free;
  LR.Free;
  for O in A do O.Free;
  for O in S do O.Free;
  if L <> nil then
    for O in L do O.Free;
  L.Free;
  if D <> nil then
    for O in D.Values do O.Free;
  D.Free;
  inherited Destroy;
end;

constructor TRootRecCtor.Create;
begin
  inherited Create;
  R.A := TItem.Create;
  R.B := TItem.Create;
end;

destructor TRootRecCtor.Destroy;
begin
  R.A.Free;
  R.B.Free;
  inherited Destroy;
end;

destructor TRootRecPartial.Destroy;
begin
  R.A.Free;
  inherited Destroy;
end;

destructor TRootDict.Destroy;
var
  O: TItem;
begin
  if D <> nil then
    for O in D.Values do O.Free;
  D.Free;
  inherited Destroy;
end;

constructor TRootOwnedDict.Create;
begin
  inherited Create;
  D := TObjectDictionary<string, TItem>.Create([doOwnsValues]);
end;

destructor TRootOwnedDict.Destroy;
begin
  D.Free;
  inherited Destroy;
end;

constructor TStringsSource.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
end;

destructor TStringsSource.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

constructor TSortedStrings.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
  Lines.Sorted := True;
  Lines.Duplicates := dupError;
end;

destructor TSortedStrings.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

constructor TSelfList.Create;
begin
  inherited Create;
  Items := TList<TObject>.Create;
end;

destructor TSelfList.Destroy;
begin
  Items.Free;
  inherited Destroy;
end;

constructor TSelfDict.Create;
begin
  inherited Create;
  Map := TDictionary<string, TObject>.Create;
end;

destructor TSelfDict.Destroy;
begin
  Map.Free;
  inherited Destroy;
end;

destructor TNode.Destroy;
begin
  Child.Free;
  inherited Destroy;
end;

constructor TMapNode.Create;
begin
  inherited Create;
  Kids := TObjectDictionary<string, TMapNode>.Create([doOwnsValues]);
end;

destructor TMapNode.Destroy;
begin
  Kids.Free;
  inherited Destroy;
end;

constructor TValueRaises.Create;
begin
  inherited Create;
  Map := TObjectDictionary<string, TBad>.Create([doOwnsValues]);
  Map.Add('key-string', TBad.Create);
end;

destructor TValueRaises.Destroy;
begin
  Map.Free;
  inherited Destroy;
end;

constructor TKeyRaises.Create;
var
  G: TGood;
begin
  inherited Create;
  Map := TObjectDictionary<TBad, TGood>.Create([doOwnsKeys, doOwnsValues]);
  G := TGood.Create;
  G.S := 'value-string';
  Map.Add(TBad.Create, G);
end;

destructor TKeyRaises.Destroy;
begin
  Map.Free;
  inherited Destroy;
end;

end.
