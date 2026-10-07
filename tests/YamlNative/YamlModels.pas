unit YamlModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{$SCOPEDENUMS ON}

{ The contracts the YAML tests serialize.

  Ordinary Delphi declarations, deliberately: the point of the contract path
  is that a type written without YAML in mind still works. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  PascalForge.Nullable,
  PascalForge.Yaml;

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
    [YamlIgnore] Scratch: string;
    [YamlName('note')] Remark: string;
    Approved: TNullable<Boolean>;
    Cancelled: TNullable<Boolean>;
    constructor Create;
    destructor Destroy; override;
  end;

  TRepresentations = class
  public
    [YamlDateTimeRepresentation(TYamlDateTimeRepresentation.Iso8601)]
    Plainly: TDateTime;
    [YamlDateTimeRepresentation(TYamlDateTimeRepresentation.Timestamp)]
    Tagged: TDateTime;
    [YamlDateTimeRepresentation(TYamlDateTimeRepresentation.UnixSeconds)]
    Seconds: TDateTime;
  end;

  TScripts = class
  public
    Georgian: string;
    Cyrillic: string;
    Cjk: string;
    Emoji: string;
    Combining: string;
  end;

  { The strings a 1.1 parser would turn into something else. Every one of
    these has to survive as text. }
  TLookalikes = class
  public
    Yes: string;
    No: string;
    On_: string;
    Off_: string;
    Y: string;
    N: string;
    Sexagesimal: string;
    Binary: string;
    LeadingZero: string;
    Version: string;
  end;

  { ---- release hardening ---- }

  { Counts live instances, so a test can say that a failed read left behind
    nothing it built. }
  TTracked = class
  public
    class var Live: Integer;
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;
  end;

  TItem = class(TTracked)
  public
    X: Integer;
  end;

  TItemRec = record
    O: TItem;
    N: Integer;
  end;

  TItemPair = record
    A: TItem;
    B: TItem;
    N: Integer;
  end;

  TItemTriple = array[0..2] of TItem;

  { One member for every shape a read builds objects into; each test
    document fills one of them. }
  TShapes = class(TTracked)
  public
    R: TItemRec;
    NR: TNullable<TItemRec>;
    LR: TList<TItemRec>;
    A: TArray<TItem>;
    S: TItemTriple;
    L: TList<TItem>;
    D: TDictionary<string, TItem>;
    DI: TDictionary<Integer, TItem>;
    destructor Destroy; override;
  end;

  { A record whose objects the constructor makes. }
  TPairHolder = class(TTracked)
  public
    R: TItemPair;
    constructor Create;
    destructor Destroy; override;
  end;

  { A container the caller configured to refuse a duplicate. }
  TSortedLines = class
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  TNamed = record
    Name: string;
    Age: Integer;
  end;

  TNamedObject = class
  public
    Name: string;
  end;

  TCharAndText = record
    C: Char;
    Items: TArray<string>;
  end;

  { Mapped to names the core schema resolves as an int, and as null. }
  TLevel = (Low, Medium, High);
  TNullish = (First, Second, Third);
  TLevels = record
    Level: TLevel;
    Nullish: TNullish;
  end;

  TWideCardinal = 0..4000000000;
  TWideCardinals = record
    H: TWideCardinal;
  end;

  THexTargets = record
    V: Int64;
    I: Integer;
    D: Double;
    C: Comp;
  end;

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

  { A class the writer refuses: a pointer means nothing in a document. }
  TUnwritable = class
  public
    P: Pointer;
  end;
  TUnwritableKeys = TDictionary<TUnwritable, Integer>;
  TUnwritableValues = TDictionary<string, TUnwritable>;

  TMapNode = class
  public
    Tag: Integer;
    Kids: TObjectDictionary<string, TMapNode>;
    constructor Create;
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

  TChainNode = class
  public
    Tag: Integer;
    Child: TChainNode;
    destructor Destroy; override;
  end;

  TEpochs = record
    [YamlDateTimeRepresentation(TYamlDateTimeRepresentation.UnixSeconds)]
    Secs: TDateTime;
    [YamlDateTimeRepresentation(TYamlDateTimeRepresentation.UnixMilliseconds)]
    Millis: TDateTime;
  end;

  TPatternDate = record
    [YamlDateTimeRepresentation('yyyy-mm-dd hh:nn:ss')]
    D: TDateTime;
  end;

  TPlainDate = record
    D: TDateTime;
  end;

  TText = record
    S: string;
  end;

  TKeyedInts = TDictionary<string, TArray<Integer>>;

implementation

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

destructor TShapes.Destroy;
var
  Rec: TItemRec;
  Item: TItem;
  I: Integer;
begin
  R.O.Free;
  if NR.HasValue then NR.Value.O.Free;
  if LR <> nil then
    for Rec in LR do Rec.O.Free;
  LR.Free;
  for Item in A do Item.Free;
  for I := Low(S) to High(S) do S[I].Free;
  if L <> nil then
    for Item in L do Item.Free;
  L.Free;
  if D <> nil then
    for Item in D.Values do Item.Free;
  D.Free;
  if DI <> nil then
    for Item in DI.Values do Item.Free;
  DI.Free;
  inherited Destroy;
end;

constructor TPairHolder.Create;
begin
  inherited Create;
  R.A := TItem.Create;
  R.B := TItem.Create;
end;

destructor TPairHolder.Destroy;
begin
  R.A.Free;
  R.B.Free;
  inherited Destroy;
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

destructor TChainNode.Destroy;
begin
  Child.Free;
  inherited Destroy;
end;

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

end.
