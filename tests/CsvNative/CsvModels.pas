unit CsvModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{$SCOPEDENUMS ON}

{ The contracts the CSV tests project onto tables.

  A table is rows of named columns and a Delphi value is a tree, so these
  are chosen to exercise every point where the two disagree: a nested
  object, a collection of scalars, a collection of records, and the ordinary
  scalars that have to survive whatever happens around them. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  PascalForge.Nullable,
  PascalForge.Csv;

type
  TDelivery = (Immediate, NextDay, Deferred);

  TAddress = class
  public
    Street: string;
    City: string;
    { A postcode with a leading zero is the reason schema inference is
      conservative by default. }
    Postcode: string;
  end;

  TLine = class
  public
    Description: string;
    Quantity: Integer;
    UnitPrice: Currency;
  end;

  { The flat case: every member is a column, which is what CSV is for. }
  TCustomer = class
  public
    [CsvKey] Id: Integer;
    Name: string;
    Score: Currency;
    Rate: Double;
    Active: Boolean;
    Joined: TDateTime;
    Reference: TGUID;
    Delivery: TDelivery;
    [CsvIgnore] Scratch: string;
    [CsvName('note')] Remark: string;
    Retired: TNullable<Boolean>;
  end;

  { One nested object, for Flatten and JsonCell. }
  TInvoice = class
  public
    [CsvKey] Number: string;
    Total: Currency;
    Shipper: TAddress;
    constructor Create;
    destructor Destroy; override;
  end;

  { A collection of scalars, for every collection mode. }
  TOrder = class
  public
    [CsvKey] Id: Integer;
    Customer: string;
    Tags: TArray<string>;
  end;

  { A collection of records, which only SeparateTable and JsonCell can
    carry. }
  TBasket = class
  public
    [CsvKey] Id: Integer;
    Customer: string;
    Lines: TObjectList<TLine>;
    constructor Create;
    destructor Destroy; override;
  end;

  { Two collections on one row: the case where a flattening has to invent
    pairings, and the default refuses. }
  TDouble = class
  public
    Id: Integer;
    First: TArray<string>;
    Second: TArray<string>;
  end;

  TScripts = class
  public
    Georgian: string;
    Cyrillic: string;
    Cjk: string;
    Emoji: string;
    Combining: string;
  end;

  { --- reader and writer repairs: ownership, levels, nullables, dates ----- }

  { Counts its live instances, so a check can say "nothing was left alive"
    instead of hoping. }
  TTrackedItem = class
  public
    X: Integer;
    { After the instance fields: a class var section runs on to the next
      method or visibility. }
    class var Live: Integer;
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;
  end;

  { An owning list the constructor makes, for RepeatedRows. }
  TTrackedOrder = class
  public
    Id: Integer;
    Lines: TObjectList<TTrackedItem>;
    constructor Create;
    destructor Destroy; override;
  end;

  { A non-owning list the reader has to build: the owner frees the items. }
  TTrackedRefs = class
  public
    Id: Integer;
    L: TList<TTrackedItem>;
    destructor Destroy; override;
  end;

  TPairRec = record
    A: Integer;
    B: string;
  end;

  TNullPairHolder = class
  public
    Id: Integer;
    R: TNullable<TPairRec>;
  end;

  TNullTagsHolder = class
  public
    Id: Integer;
    Tags: TNullable<TArray<string>>;
  end;

  { A record whose every cell can be empty: present with an empty string is
    indistinguishable from absent. }
  TTextRec = record
    S: string;
  end;

  TNullTextHolder = class
  public
    Id: Integer;
    R: TNullable<TTextRec>;
  end;

  TChainNode = class
  public
    Id: Integer;
    Next: TChainNode;
    destructor Destroy; override;
  end;

  { A record holding an object, read into a class that frees it. }
  TObjRec = record
    O: TTrackedItem;
    N: Integer;
  end;

  TObjRecHolder = class
  public
    R: TObjRec;
    destructor Destroy; override;
  end;

  { A record whose objects the constructor made. }
  TCtorRec = record
    A: TTrackedItem;
    B: TTrackedItem;
    N: Integer;
  end;

  TCtorRecHolder = class
  public
    R: TCtorRec;
    constructor Create;
    destructor Destroy; override;
  end;

  { A container that refuses content: sorted, duplicates an error. }
  TSortedLines = class
  public
    Id: Integer;
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  TMoment = class
  public
    At: TDateTime;
    [CsvDateTimeFormat('yyyy-mm-dd hh:nn:ss')] Local: TDateTime;
    Day: TDate;
  end;

  TRate = class
  public
    D: Double;
  end;

  { A record that recurses through a dynamic array: no object anywhere, so
    only a level count stops it. }
  TKidRec = record
    Tag: Integer;
    Kids: array of TKidRec;
  end;

  TKidHolder = class
  public
    Id: Integer;
    Root: TKidRec;
  end;

implementation

procedure TTrackedItem.AfterConstruction;
begin
  inherited;
  AtomicIncrement(Live);
end;

procedure TTrackedItem.BeforeDestruction;
begin
  AtomicDecrement(Live);
  inherited;
end;

constructor TTrackedOrder.Create;
begin
  inherited Create;
  Lines := TObjectList<TTrackedItem>.Create(True);
end;

destructor TTrackedOrder.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

destructor TTrackedRefs.Destroy;
var
  I: Integer;
begin
  if L <> nil then
    for I := 0 to L.Count - 1 do L[I].Free;
  L.Free;
  inherited Destroy;
end;

destructor TChainNode.Destroy;
begin
  Next.Free;
  inherited Destroy;
end;

destructor TObjRecHolder.Destroy;
begin
  R.O.Free;
  inherited Destroy;
end;

constructor TCtorRecHolder.Create;
begin
  inherited Create;
  R.A := TTrackedItem.Create;
  R.B := TTrackedItem.Create;
end;

destructor TCtorRecHolder.Destroy;
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

constructor TInvoice.Create;
begin
  inherited Create;
  Shipper := TAddress.Create;
end;

destructor TInvoice.Destroy;
begin
  Shipper.Free;
  inherited Destroy;
end;

constructor TBasket.Create;
begin
  inherited Create;
  Lines := TObjectList<TLine>.Create(True);
end;

destructor TBasket.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

end.
