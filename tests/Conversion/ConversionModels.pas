unit ConversionModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ One model, decorated for three formats at once.

  This is the point of the whole design: a member may be called one thing in
  JSON, another in XML and a third in BSON, and each engine reads only its
  own attributes. A shared [SerializationName] would have made that
  impossible and is deliberately absent. }

interface

uses
  System.SysUtils, System.JSON, System.TypInfo, System.Generics.Collections,
  PascalForge.Nullable,
  PascalForge.Json,
  PascalForge.Xml,
  PascalForge.Bson;

type
  TFlavour = (Mild, Spicy, Hot);

  TLine = class
  public
    [JsonName('sku')]
    [XmlName('SKU')]
    [BsonName('sku_code')]
    Code: string;

    [JsonName('qty')]
    [XmlName('Qty')]
    [BsonName('quantity')]
    Quantity: Integer;
  end;

  TLines = class(TObjectList<TLine>)
  end;

  [XmlName('Order')]
  TOrder = class
  public
    [JsonName('orderId')]
    [XmlName('OrderID')]
    [XmlAttribute]
    [BsonName('_id')]
    Id: Int64;

    [JsonName('customer')]
    [XmlName('Customer')]
    [BsonName('cust')]
    Customer: string;

    { Ignored by ONE format each, so a missing member proves which engine
      read which attribute. }
    [JsonIgnore]
    HiddenFromJson: string;
    [XmlIgnore]
    HiddenFromXml: string;
    [BsonIgnore]
    HiddenFromBson: string;

    [JsonName('flavour')]
    [XmlName('Flavour')]
    [BsonName('flav')]
    Flavour: TFlavour;

    [JsonName('note')]
    [XmlName('Note')]
    [BsonName('note')]
    Note: TNullable<string>;

    [JsonName('rebate')]
    [XmlName('Rebate')]
    [BsonName('rebate')]
    Rebate: TNullable<Currency>;

    { One timestamp, three configurations - see ConfigureFormats. }
    [JsonName('createdAt')]
    [XmlName('CreatedAt')]
    [BsonName('created_at')]
    Created: TDateTime;

    [JsonName('booked')]
    [XmlName('Booked')]
    [BsonName('booked')]
    Booked: TDate;

    [JsonName('ref')]
    [XmlName('Ref')]
    [BsonName('ref')]
    Reference: TGUID;

    [JsonName('lines')]
    [XmlName('Lines')]
    [XmlItemName('Line')]
    [BsonName('lines')]
    Lines: TLines;

    [JsonName('rates')]
    [XmlName('Rates')]
    [BsonName('rates')]
    Rates: TDictionary<string, Currency>;

    constructor Create;
    destructor Destroy; override;
  end;

  { A value each format represents its own way, to show that a custom
    serializer registered for one format is not a serializer for another. }
  TCoordinate = record
    Latitude: Double;
    Longitude: Double;
  end;

  TPlace = class
  public
    [JsonName('name')]
    [BsonName('name')]
    Name: string;
    [JsonName('where')]
    [BsonName('where')]
    Where: TCoordinate;
  end;

  { JSON writes a coordinate as "lat,lon". }
  TJsonCoordinateSerializer = class(TCustomJsonValueSerializer<TCoordinate>)
  public
    function SerializeValue(const AValue: TCoordinate): TJSONValue; override;
    function DeserializeValue(const AJson: TJSONValue): TCoordinate; override;
  end;

  { XML writes it as two attributes. }
  TXmlCoordinateSerializer = class(TCustomXmlValueSerializer<TCoordinate>)
  public
    procedure SerializeValue(const AValue: TCoordinate;
      AElement: TXmlElement); override;
    function DeserializeValue(AElement: TXmlElement;
      const AExisting: TCoordinate): TCoordinate; override;
  end;

  { BSON writes it as a two-element array of doubles. }
  TBsonCoordinateSerializer = class(TCustomBsonValueSerializer<TCoordinate>)
  public
    function SerializeValue(const AValue: TCoordinate): TBsonValue; override;
    function DeserializeValue(AValue: TBsonValue;
      const AExisting: TCoordinate): TCoordinate; override;
  end;

implementation

constructor TOrder.Create;
begin
  inherited Create;
  Lines := TLines.Create;
  Rates := TDictionary<string, Currency>.Create;
end;

destructor TOrder.Destroy;
begin
  Rates.Free;
  Lines.Free;
  inherited Destroy;
end;

function TJsonCoordinateSerializer.SerializeValue(
  const AValue: TCoordinate): TJSONValue;
begin
  Result := TJSONString.Create(
    FloatToStr(AValue.Latitude, TFormatSettings.Invariant) + ',' +
    FloatToStr(AValue.Longitude, TFormatSettings.Invariant));
end;

function TJsonCoordinateSerializer.DeserializeValue(
  const AJson: TJSONValue): TCoordinate;
var
  Parts: TArray<string>;
begin
  Parts := AJson.Value.Split([',']);
  if Length(Parts) <> 2 then
    raise EJsonInputError.Create('A coordinate is "latitude,longitude".');
  Result.Latitude := StrToFloat(Parts[0], TFormatSettings.Invariant);
  Result.Longitude := StrToFloat(Parts[1], TFormatSettings.Invariant);
end;

procedure TXmlCoordinateSerializer.SerializeValue(const AValue: TCoordinate;
  AElement: TXmlElement);
begin
  AElement.SetAttribute('lat',
    FloatToStr(AValue.Latitude, TFormatSettings.Invariant));
  AElement.SetAttribute('lon',
    FloatToStr(AValue.Longitude, TFormatSettings.Invariant));
end;

function TXmlCoordinateSerializer.DeserializeValue(AElement: TXmlElement;
  const AExisting: TCoordinate): TCoordinate;
begin
  Result.Latitude := StrToFloat(AElement.AttributeValue('lat', '0'),
    TFormatSettings.Invariant);
  Result.Longitude := StrToFloat(AElement.AttributeValue('lon', '0'),
    TFormatSettings.Invariant);
end;

function TBsonCoordinateSerializer.SerializeValue(
  const AValue: TCoordinate): TBsonValue;
begin
  Result := TBsonValue.NewArray;
  try
    Result.Add(TBsonValue.NewDouble(AValue.Latitude));
    Result.Add(TBsonValue.NewDouble(AValue.Longitude));
  except
    Result.Free;
    raise;
  end;
end;

function TBsonCoordinateSerializer.DeserializeValue(AValue: TBsonValue;
  const AExisting: TCoordinate): TCoordinate;
begin
  if (AValue.Kind <> TBsonKind.Arr) or (AValue.Count <> 2) then
    raise EBsonInputError.Create(
      'A coordinate is a two-element array of [latitude, longitude].');
  Result.Latitude := AValue[0].AsDouble;
  Result.Longitude := AValue[1].AsDouble;
end;

end.
