unit BsonModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Models for the BSON tests. They live in a unit because the date and
  representation registrations are keyed by type, and a type declared in a
  program file has no recoverable declaring unit. }

interface

uses
  System.SysUtils, System.Generics.Collections,
  PascalForge.Nullable,
  PascalForge.Bson;

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

  TShipment = class
  public
    [BsonName('_id')]
    Id: Int64;
    Small: Integer;
    Rate: Double;
    Amount: Currency;
    Consignee: string;
    Kind: TContractKind;
    Channels: TChannels;
    Reference: TGUID;
    Blob: TBytes;
    Booked: TDate;
    Cutoff: TTime;
    Created: TDateTime;
    Note: TNullable<string>;
    Rebate: TNullable<Currency>;
    [BsonIgnore]
    Secret: string;
    Address: TAddress;
    Lines: TOrderLines;
    Rates: TDictionary<string, Currency>;
    Codes: TArray<Integer>;
    constructor Create;
    destructor Destroy; override;
  end;

  TMoney = record
    Amount: Currency;
    Code: string;
  end;

  TQuote = class
  public
    Symbol: string;
    Bid: TMoney;
  end;

  TReusable = class
  public
    Address: TAddress;
    Lines: TOrderLines;
    constructor Create;
    destructor Destroy; override;
  end;

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
    [BsonDateTimeRepresentation(TBsonDateTimeRepresentation.UnixSeconds)]
    Stamp: TDateTime;
    Other: TDateTime;
  end;

  { Representation attributes that are BSON's alone. }
  TRepresentations = class
  public
    [BsonGuidRepresentation(TBsonGuidRepresentation.LowercaseString)]
    TextGuid: TGUID;
    NativeGuid: TGUID;
    [BsonCurrencyRepresentation(TBsonCurrencyRepresentation.Double)]
    LossyAmount: Currency;
    [BsonCurrencyRepresentation(TBsonCurrencyRepresentation.DecimalString)]
    TextAmount: Currency;
    ExactAmount: Currency;
  end;

  { A custom BSON serializer's subject: a coordinate is naturally a
    two-element BSON array, which is not what XML or JSON would choose. }
  TCoordinate = record
    Latitude: Double;
    Longitude: Double;
  end;

  TCoordinateSerializer = class(TCustomBsonValueSerializer<TCoordinate>)
  public
    function SerializeValue(const AValue: TCoordinate): TBsonValue; override;
    function DeserializeValue(AValue: TBsonValue;
      const AExisting: TCoordinate): TCoordinate; override;
  end;

  TPlace = class
  public
    Name: string;
    Where: TCoordinate;
  end;

implementation

constructor TShipment.Create;
begin
  inherited Create;
  Rates := TDictionary<string, Currency>.Create;
end;

destructor TShipment.Destroy;
begin
  Rates.Free;
  Address.Free;
  Lines.Free;
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

function TCoordinateSerializer.SerializeValue(
  const AValue: TCoordinate): TBsonValue;
begin
  Result := TBsonValue.NewArray;
  try
    Result.Add(TBsonValue.NewDouble(AValue.Longitude));
    Result.Add(TBsonValue.NewDouble(AValue.Latitude));
  except
    Result.Free;
    raise;
  end;
end;

function TCoordinateSerializer.DeserializeValue(AValue: TBsonValue;
  const AExisting: TCoordinate): TCoordinate;
begin
  if (AValue.Kind <> TBsonKind.Arr) or (AValue.Count <> 2) then
    raise EBsonInputError.Create(
      'A coordinate is a two-element array of [longitude, latitude].');
  Result.Longitude := AValue[0].AsDouble;
  Result.Latitude := AValue[1].AsDouble;
end;

end.
