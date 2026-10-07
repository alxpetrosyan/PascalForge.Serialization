unit MsgPackModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{$SCOPEDENUMS ON}

{ The contracts the MessagePack tests serialize.

  Ordinary Delphi declarations, deliberately: the point of the contract path
  is that a type written without MessagePack in mind still works. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.Generics.Defaults,
  PascalForge.Nullable,
  PascalForge.MessagePack;

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
    [MessagePackIgnore] Scratch: string;
    [MessagePackName('note')] Remark: string;
    Approved: TNullable<Boolean>;
    Cancelled: TNullable<Boolean>;
    constructor Create;
    destructor Destroy; override;
  end;

  TRepresentations = class
  public
    [MessagePackDateTimeRepresentation(
      TMessagePackDateTimeRepresentation.Timestamp)]
    Stamped: TDateTime;
    [MessagePackDateTimeRepresentation(
      TMessagePackDateTimeRepresentation.StringIso8601)]
    Spelled: TDateTime;
    [MessagePackGuidRepresentation(TMessagePackGuidRepresentation.Bin)]
    RawId: TGUID;
    [MessagePackGuidRepresentation(TMessagePackGuidRepresentation.LowercaseString)]
    TextId: TGUID;
    [MessagePackCurrencyRepresentation(
      TMessagePackCurrencyRepresentation.DecimalString)]
    Spoken: Currency;
    [MessagePackCurrencyRepresentation(TMessagePackCurrencyRepresentation.Float64)]
    Approximate: Currency;
    [MessagePackEnumRepresentation(TMessagePackEnumRepresentation.Name)]
    ByName: TDelivery;
    [MessagePackEnumRepresentation(TMessagePackEnumRepresentation.Ordinal)]
    ByValue: TDelivery;
  end;

  TScripts = class
  public
    Georgian: string;
    Cyrillic: string;
    Cjk: string;
    Emoji: string;
    Combining: string;
  end;

  { --- dates on either side of 1899-12-30 --------------------------------- }

  TMoment = class
  public
    At: TDateTime;
  end;

  TMomentMilliseconds = class
  public
    [MessagePackDateTimeRepresentation(
      TMessagePackDateTimeRepresentation.UnixMilliseconds)]
    At: TDateTime;
  end;

  TMomentSeconds = class
  public
    [MessagePackDateTimeRepresentation(
      TMessagePackDateTimeRepresentation.UnixSeconds)]
    At: TDateTime;
  end;

  TMomentIso = class
  public
    [MessagePackDateTimeRepresentation(
      TMessagePackDateTimeRepresentation.StringIso8601)]
    At: TDateTime;
  end;

  TMomentPattern = class
  public
    [MessagePackDateTimeRepresentation('mm"/"dd"/"yyyy hh":"nn":"ss')]
    At: TDateTime;
  end;

  { --- what a failed read leaves alive ------------------------------------ }

  { Counts its live instances, so a check can see what a read that failed
    part way left behind. }
  TTracked = class
  public
    class var Live: Integer;
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;
  end;

  TTrackedItem = class(TTracked)
  public
    X: Integer;
    Y: Integer;
  end;

  TItemArrayHolder = class(TTracked)
  public
    A: TArray<TTrackedItem>;
    destructor Destroy; override;
  end;

  TItemTriple = array[0..2] of TTrackedItem;

  TItemTripleHolder = class(TTracked)
  public
    A: TItemTriple;
    destructor Destroy; override;
  end;

  { Nil until the read builds it: a TList<T> owns nothing. }
  TItemListHolder = class(TTracked)
  public
    L: TList<TTrackedItem>;
    destructor Destroy; override;
  end;

  TItemDictionaryHolder = class(TTracked)
  public
    D: TDictionary<string, TTrackedItem>;
    destructor Destroy; override;
  end;

  TOwningItemDictionaryHolder = class(TTracked)
  public
    D: TObjectDictionary<string, TTrackedItem>;
    constructor Create;
    destructor Destroy; override;
  end;

  TItemRecord = record
    O: TTrackedItem;
    N: Integer;
  end;

  TItemRecordHolder = class(TTracked)
  public
    R: TItemRecord;
    destructor Destroy; override;
  end;

  { R.O is the constructor's, filled in place by a read. }
  TPrefilledRecordHolder = class(TTracked)
  public
    R: TItemRecord;
    constructor Create;
    destructor Destroy; override;
  end;

  TNullableRecordHolder = class(TTracked)
  public
    R: TNullable<TItemRecord>;
    destructor Destroy; override;
  end;

  TItemPair = record
    A: TTrackedItem;
    B: TTrackedItem;
  end;

  TPairListHolder = class(TTracked)
  public
    L: TList<TItemPair>;
    destructor Destroy; override;
  end;

  TSortedLines = class
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  { Refuses its second element from Notify, which runs after the element
    is stored: the element is then the list's, not the read's to free. }
  TRefusingItemList = class(TList<TTrackedItem>)
  protected
    procedure Notify(const Item: TTrackedItem;
      Action: TCollectionNotification); override;
  end;

  TRefusingListHolder = class(TTracked)
  public
    L: TRefusingItemList;
    destructor Destroy; override;
  end;

  { Its comparer refuses the key "bad" before anything is stored: the value
    read for it is then nobody's but the read's. }
  TRefusingDictionaryHolder = class(TTracked)
  public
    D: TDictionary<string, TTrackedItem>;
    constructor Create;
    destructor Destroy; override;
  end;

  { --- nesting the writer counts ------------------------------------------ }

  TChainNode = class
  public
    Tag: Integer;
    Child: TChainNode;
    destructor Destroy; override;
  end;

  TTreeNode = class
  public
    Tag: Integer;
    Children: TObjectList<TTreeNode>;
    constructor Create;
    destructor Destroy; override;
  end;

  TRecordNode = record
    Tag: Integer;
    Kids: array of TRecordNode;
  end;

  TRecordChainHolder = class
  public
    R: TRecordNode;
  end;

  TDictionaryNode = class
  public
    Tag: Integer;
    Kids: TObjectDictionary<string, TDictionaryNode>;
    constructor Create;
    destructor Destroy; override;
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

destructor TItemArrayHolder.Destroy;
var
  O: TTrackedItem;
begin
  for O in A do O.Free;
  inherited Destroy;
end;

destructor TItemTripleHolder.Destroy;
var
  I: Integer;
begin
  for I := Low(A) to High(A) do A[I].Free;
  inherited Destroy;
end;

destructor TItemListHolder.Destroy;
var
  O: TTrackedItem;
begin
  if L <> nil then
    for O in L do O.Free;
  L.Free;
  inherited Destroy;
end;

destructor TItemDictionaryHolder.Destroy;
var
  O: TTrackedItem;
begin
  if D <> nil then
    for O in D.Values do O.Free;
  D.Free;
  inherited Destroy;
end;

constructor TOwningItemDictionaryHolder.Create;
begin
  inherited Create;
  D := TObjectDictionary<string, TTrackedItem>.Create([doOwnsValues]);
end;

destructor TOwningItemDictionaryHolder.Destroy;
begin
  D.Free;
  inherited Destroy;
end;

destructor TItemRecordHolder.Destroy;
begin
  R.O.Free;
  inherited Destroy;
end;

constructor TPrefilledRecordHolder.Create;
begin
  inherited Create;
  R.O := TTrackedItem.Create;
end;

destructor TPrefilledRecordHolder.Destroy;
begin
  R.O.Free;
  inherited Destroy;
end;

destructor TNullableRecordHolder.Destroy;
begin
  if R.HasValue then R.Value.O.Free;
  inherited Destroy;
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

procedure TRefusingItemList.Notify(const Item: TTrackedItem;
  Action: TCollectionNotification);
begin
  inherited Notify(Item, Action);
  if (Action = cnAdded) and (Count = 2) then
    raise EListError.Create('This list takes one element and no more.');
end;

destructor TRefusingListHolder.Destroy;
var
  O: TTrackedItem;
begin
  if L <> nil then
    for O in L do O.Free;
  L.Free;
  inherited Destroy;
end;

constructor TRefusingDictionaryHolder.Create;
begin
  inherited Create;
  D := TDictionary<string, TTrackedItem>.Create(
    TEqualityComparer<string>.Construct(
      function(const ALeft, ARight: string): Boolean
      begin
        Result := ALeft = ARight;
      end,
      function(const AValue: string): Integer
      begin
        if AValue = 'bad' then
          raise EArgumentException.Create('This dictionary refuses "bad".');
        Result := Length(AValue);
      end));
end;

destructor TRefusingDictionaryHolder.Destroy;
var
  O: TTrackedItem;
begin
  if D <> nil then
    for O in D.Values do O.Free;
  D.Free;
  inherited Destroy;
end;

destructor TChainNode.Destroy;
begin
  Child.Free;
  inherited Destroy;
end;

constructor TTreeNode.Create;
begin
  inherited Create;
  Children := TObjectList<TTreeNode>.Create(True);
end;

destructor TTreeNode.Destroy;
begin
  Children.Free;
  inherited Destroy;
end;

constructor TDictionaryNode.Create;
begin
  inherited Create;
  Kids := TObjectDictionary<string, TDictionaryNode>.Create([doOwnsValues]);
end;

destructor TDictionaryNode.Destroy;
begin
  Kids.Free;
  inherited Destroy;
end;

end.
