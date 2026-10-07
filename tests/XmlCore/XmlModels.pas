unit XmlModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Models for the XML tests.

  They live in a unit rather than in the .dpr because a type declared in a
  program file has no recoverable declaring unit, and the date/time policy
  registrations are keyed by type. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  PascalForge.Nullable,
  PascalForge.Xml;

type
  TContractKind = (Spot, Forward, Swap);
  TChannel = (Retail, Corporate, Government);
  TChannels = set of TChannel;

  TAddress = class
  public
    Street: string;
    City: string;
  end;

  TOrderLine = class
  public
    Sku: string;
    Quantity: Integer;
  end;

  TOrderLines = class(TObjectList<TOrderLine>)
  end;

  { The default contract, with nothing configured. }
  TShipment = class
  public
    Id: Int64;
    Amount: Currency;
    Consignee: string;
    Kind: TContractKind;
    Channels: TChannels;
    Reference: TGUID;
    Booked: TDate;
    Cutoff: TTime;
    Created: TDateTime;
    Note: TNullable<string>;
    Rebate: TNullable<Currency>;
    Address: TAddress;
    Lines: TOrderLines;
    destructor Destroy; override;
  end;

  { Placement: attributes, text content, renaming, ignoring. }
  [XmlName('Ticket')]
  TTicket = class
  public
    [XmlAttribute]
    [XmlName('id')]
    Id: Integer;
    [XmlAttribute]
    Priority: TContractKind;
    [XmlName('Subject')]
    Title: string;
    [XmlIgnore]
    InternalScore: Integer;
    [XmlText]
    Body: string;
  end;

  { Namespaces. }
  [XmlName('Envelope')]
  [XmlNamespace('urn:pascalforge:demo:envelope', 'env')]
  TEnvelope = class
  public
    Subject: string;
    [XmlNamespace('urn:pascalforge:demo:payload')]
    Payload: string;
  end;

  { Collection customization. }
  TBasket = class
  public
    [XmlArray('Items')]
    [XmlItemName('Line')]
    Lines: TOrderLines;
    [XmlArray('')]
    [XmlItemName('Tag')]
    Tags: TArray<string>;
    constructor Create;
    destructor Destroy; override;
  end;

  { Dictionaries and arrays. }
  TRates = class
  public
    Rates: TDictionary<string, Currency>;
    Codes: TArray<Integer>;
    constructor Create;
    destructor Destroy; override;
  end;

  { Records. }
  TMoney = record
    Amount: Currency;
    Currency: string;
  end;

  TQuote = class
  public
    Symbol: string;
    Bid: TMoney;
  end;

  { Reuse: the nested instance and the container both already exist. }
  TReusable = class
  public
    Address: TAddress;
    Lines: TOrderLines;
    constructor Create;
    destructor Destroy; override;
  end;

  { Date policy scopes. }
  TGlobalDates = class
  public
    Stamp: TDateTime;
  end;

  TClassDates = class
  public
    Stamp: TDateTime;
    Other: TDateTime;
  end;

  TFieldDates = class
  public
    Stamp: TDateTime;
    Other: TDateTime;
  end;

  TAttrDates = class
  public
    [XmlDateTimeFormat(TXmlDateTimeFormat.UnixSeconds)]
    Stamp: TDateTime;
    Other: TDateTime;
  end;

  { A custom XML serializer's subject. }
  TCoordinate = record
    Latitude: Double;
    Longitude: Double;
  end;

  TCoordinateSerializer = class(TCustomXmlValueSerializer<TCoordinate>)
  public
    procedure SerializeValue(const AValue: TCoordinate;
      AElement: TXmlElement); override;
    function DeserializeValue(AElement: TXmlElement;
      const AExisting: TCoordinate): TCoordinate; override;
  end;

  TPlace = class
  public
    Name: string;
    Where: TCoordinate;
  end;

  { ------------------------------------------------------------------------
    Regressions from the release review. TCounted counts its live
    instances, so a check can see exactly what a failed read left behind;
    every holder frees what it holds, the way an application class would.
    ------------------------------------------------------------------------ }
  TCounted = class
  public
    class var Live: Integer;
  public
    X: Integer;
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;
  end;

  TCountedPair = record
    O: TCounted;
    N: Integer;
  end;

  TPairHolder = class
  public
    R: TCountedPair;
    destructor Destroy; override;
  end;

  TNullablePairHolder = class
  public
    R: TNullable<TCountedPair>;
    destructor Destroy; override;
  end;

  TPairListHolder = class
  public
    L: TList<TCountedPair>;
    destructor Destroy; override;
  end;

  TCountedTriple = array[0..2] of TCounted;

  TCountedArrays = class
  public
    A: TArray<TCounted>;
    S: TCountedTriple;
    destructor Destroy; override;
  end;

  { Non-owning containers: what the read puts in them is the read's to free
    when it fails. }
  TCountedContainers = class
  public
    L: TList<TCounted>;
    D: TDictionary<string, TCounted>;
    destructor Destroy; override;
  end;

  { Owning containers the caller made, for the wrong-shape checks. }
  TOwningContainers = class
  public
    Items: TObjectList<TCounted>;
    Map: TObjectDictionary<string, TCounted>;
    constructor Create;
    destructor Destroy; override;
  end;

  TSortedLines = class
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  TReadOnlyMember = class
  strict private
    FObj: TCounted;
  public
    property Obj: TCounted read FObj;
    destructor Destroy; override;
  end;

  TMoment = class
  public
    At: TDateTime;
  end;

  TMomentMs = class
  public
    [XmlDateTimeFormat(TXmlDateTimeFormat.UnixMilliseconds)]
    At: TDateTime;
  end;

  TMomentSec = class
  public
    [XmlDateTimeFormat(TXmlDateTimeFormat.UnixSeconds)]
    At: TDateTime;
  end;

  TDay = class
  public
    D: TDate;
  end;

  TDoubleHolder = class
  public
    D: Double;
  end;

  TTextHolder = class
  public
    S: string;
    [XmlAttribute] A: string;
    C: Char;
  end;

  TChainNode = class
  public
    Tag: Integer;
    Child: TChainNode;
    destructor Destroy; override;
  end;

  { A record that nests through a dynamic array of itself: no object in the
    chain, so only the level count stops it. }
  TRecLink = record
    Tag: Integer;
    Kids: array of TRecLink;
  end;

  TRecLinkHolder = class
  public
    R: TRecLink;
  end;

implementation

procedure TCounted.AfterConstruction;
begin
  inherited AfterConstruction;
  Inc(Live);
end;

procedure TCounted.BeforeDestruction;
begin
  Dec(Live);
  inherited BeforeDestruction;
end;

destructor TPairHolder.Destroy;
begin
  R.O.Free;
  inherited Destroy;
end;

destructor TNullablePairHolder.Destroy;
begin
  if R.HasValue then R.Value.O.Free;
  inherited Destroy;
end;

destructor TPairListHolder.Destroy;
var
  I: Integer;
begin
  if L <> nil then
    for I := 0 to L.Count - 1 do L[I].O.Free;
  L.Free;
  inherited Destroy;
end;

destructor TCountedArrays.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(A) do A[I].Free;
  for I := 0 to High(S) do S[I].Free;
  inherited Destroy;
end;

destructor TCountedContainers.Destroy;
var
  I: Integer;
  O: TCounted;
begin
  if L <> nil then
    for I := 0 to L.Count - 1 do L[I].Free;
  L.Free;
  if D <> nil then
    for O in D.Values do O.Free;
  D.Free;
  inherited Destroy;
end;

constructor TOwningContainers.Create;
begin
  inherited Create;
  Items := TObjectList<TCounted>.Create(True);
  Map := TObjectDictionary<string, TCounted>.Create([doOwnsValues]);
end;

destructor TOwningContainers.Destroy;
begin
  Items.Free;
  Map.Free;
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

destructor TReadOnlyMember.Destroy;
begin
  FObj.Free;
  inherited Destroy;
end;

destructor TChainNode.Destroy;
begin
  Child.Free;
  inherited Destroy;
end;

destructor TShipment.Destroy;
begin
  Address.Free;
  Lines.Free;
  inherited Destroy;
end;

constructor TBasket.Create;
begin
  inherited Create;
  Lines := TOrderLines.Create;
end;

destructor TBasket.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

constructor TRates.Create;
begin
  inherited Create;
  Rates := TDictionary<string, Currency>.Create;
end;

destructor TRates.Destroy;
begin
  Rates.Free;
  inherited Destroy;
end;

constructor TReusable.Create;
begin
  inherited Create;
  Address := TAddress.Create;
  Lines := TOrderLines.Create;
end;

destructor TReusable.Destroy;
begin
  Address.Free;
  Lines.Free;
  inherited Destroy;
end;

{ A coordinate is two numbers, and XML's natural shape for that is two
  attributes on one element. A JSON serializer for the same record would
  produce something else entirely - which is the point of format-specific
  custom serializers. }

procedure TCoordinateSerializer.SerializeValue(const AValue: TCoordinate;
  AElement: TXmlElement);
begin
  AElement.SetAttribute('lat',
    FloatToStr(AValue.Latitude, TFormatSettings.Invariant));
  AElement.SetAttribute('lon',
    FloatToStr(AValue.Longitude, TFormatSettings.Invariant));
end;

function TCoordinateSerializer.DeserializeValue(AElement: TXmlElement;
  const AExisting: TCoordinate): TCoordinate;
begin
  Result.Latitude := StrToFloat(AElement.AttributeValue('lat', '0'),
    TFormatSettings.Invariant);
  Result.Longitude := StrToFloat(AElement.AttributeValue('lon', '0'),
    TFormatSettings.Invariant);
end;

end.
