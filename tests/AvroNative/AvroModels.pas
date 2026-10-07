unit AvroModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{$SCOPEDENUMS ON}

{ The contracts the Avro tests serialize.

  Ordinary Delphi declarations: the point of the contract path is that a
  type written without Avro in mind still generates a schema and still
  round-trips. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  PascalForge.Nullable,
  PascalForge.Avro;

type
  TDelivery = (Immediate, NextDay, Deferred);

  TAddress = record
    Street: string;
    City: string;
  end;

  TShipment = class
  public
    Reference: string;
    Count: Integer;
    Ticks: Int64;
    Rate: Double;
    Ratio: Single;
    Paid: Boolean;
    Amount: Currency;
    Raised: TDateTime;
    Id: TGUID;
    Receipt: TBytes;
    Delivery: TDelivery;
    Tags: TArray<string>;
    Shipper: TAddress;
    [AvroIgnore] Scratch: string;
    [AvroName('note')] Remark: string;
    Approved: TNullable<Boolean>;
  end;

  { The two-field record the specification's own worked example uses. }
  TSpecExample = record
    a: Int64;
    b: string;
  end;

  TScripts = class
  public
    Georgian: string;
    Cyrillic: string;
    Cjk: string;
    Emoji: string;
    Combining: string;
  end;

  { The release-review regressions. TLiveItem counts its live instances and
    can be told to refuse its Nth construction, so that a read which fails
    part way can be asked what it left alive. }
  EItemRefused = class(Exception);

  TLiveItem = class
  private
    FCounted: Boolean;
  public
    X: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  TItemPair = record
    A: TLiveItem;
    B: TLiveItem;
    N: Integer;
  end;

  TPairHolder = class
  public
    R: TItemPair;
    destructor Destroy; override;
  end;

  TNullablePairHolder = class
  public
    R: TNullable<TItemPair>;
    destructor Destroy; override;
  end;

  TPairListHolder = class
  public
    L: TList<TItemPair>;
    destructor Destroy; override;
  end;

  { A record whose objects the constructor makes: a read merges into it. }
  TPairOwner = class
  public
    R: TItemPair;
    constructor Create;
    destructor Destroy; override;
  end;

  TItemArrayHolder = class
  public
    A: TArray<TLiveItem>;
    destructor Destroy; override;
  end;

  TItemTriple = array[0..2] of TLiveItem;

  TItemTripleHolder = class
  public
    A: TItemTriple;
    destructor Destroy; override;
  end;

  TItemListHolder = class
  public
    L: TList<TLiveItem>;
    destructor Destroy; override;
  end;

  TItemDictHolder = class
  public
    D: TDictionary<string, TLiveItem>;
    destructor Destroy; override;
  end;

  TLinesSource = class
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  { Sorted, with Duplicates = dupError: the list itself refuses a repeat. }
  TSortedLines = class
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  TMomentHolder = class
  public
    At: TDateTime;
  end;

  TDayHolder = class
  public
    D: TDate;
  end;

  TWideCount = class
  public
    Z: Int64;
  end;

  TNarrowCount = class
  public
    Z: Integer;
  end;

  TTextHolder = class
  public
    S: string;
  end;

  { Nests through records and arrays alone, with no object in it. }
  TRecChain = record
    Tag: Integer;
    Kids: TArray<TRecChain>;
  end;

  TRecChainHolder = class
  public
    R: TRecChain;
  end;

  TChainNode = class
  public
    V: Integer;
    Child: TChainNode;
    destructor Destroy; override;
  end;

  TListNode = class
  public
    V: Integer;
    Kids: TObjectList<TListNode>;
    destructor Destroy; override;
  end;

  TDictNode = class
  public
    V: Integer;
    Kids: TDictionary<string, TDictNode>;
    destructor Destroy; override;
  end;

var
  GLiveItems: Integer = 0;
  GItemConstructions: Integer = 0;
  GItemFailAt: Integer = 0;

implementation

constructor TLiveItem.Create;
begin
  inherited Create;
  Inc(GItemConstructions);
  if (GItemFailAt > 0) and (GItemConstructions = GItemFailAt) then
    raise EItemRefused.CreateFmt('TLiveItem construction #%d refused by the test',
      [GItemConstructions]);
  FCounted := True;
  Inc(GLiveItems);
end;

destructor TLiveItem.Destroy;
begin
  if FCounted then Dec(GLiveItems);
  inherited;
end;

destructor TPairHolder.Destroy;
begin
  R.A.Free;
  R.B.Free;
  inherited;
end;

destructor TNullablePairHolder.Destroy;
begin
  if R.HasValue then
  begin
    R.Value.A.Free;
    R.Value.B.Free;
  end;
  inherited;
end;

destructor TPairListHolder.Destroy;
var
  P: TItemPair;
begin
  if L <> nil then
    for P in L do
    begin
      P.A.Free;
      P.B.Free;
    end;
  L.Free;
  inherited;
end;

constructor TPairOwner.Create;
begin
  inherited Create;
  R.A := TLiveItem.Create;
  R.B := TLiveItem.Create;
end;

destructor TPairOwner.Destroy;
begin
  R.A.Free;
  R.B.Free;
  inherited;
end;

destructor TItemArrayHolder.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(A) do A[I].Free;
  inherited;
end;

destructor TItemTripleHolder.Destroy;
var
  I: Integer;
begin
  for I := 0 to 2 do A[I].Free;
  inherited;
end;

destructor TItemListHolder.Destroy;
var
  I: Integer;
begin
  if L <> nil then
    for I := 0 to L.Count - 1 do L[I].Free;
  L.Free;
  inherited;
end;

destructor TItemDictHolder.Destroy;
var
  V: TLiveItem;
begin
  if D <> nil then
    for V in D.Values do V.Free;
  D.Free;
  inherited;
end;

constructor TLinesSource.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
end;

destructor TLinesSource.Destroy;
begin
  Lines.Free;
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

destructor TChainNode.Destroy;
begin
  Child.Free;
  inherited;
end;

destructor TListNode.Destroy;
begin
  Kids.Free;
  inherited;
end;

destructor TDictNode.Destroy;
var
  K: TDictNode;
begin
  if Kids <> nil then
    for K in Kids.Values do K.Free;
  Kids.Free;
  inherited;
end;

end.
