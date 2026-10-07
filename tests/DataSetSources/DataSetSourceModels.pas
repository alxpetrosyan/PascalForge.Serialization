unit DataSetSourceModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ A DTO decorated for three formats, used to show what a CONTRACT adds that
  schema inference cannot have. }

interface

uses
  System.SysUtils, System.Generics.Collections,
  PascalForge.Json,
  PascalForge.Xml,
  PascalForge.Bson;

type
  TLine = class
  public
    [JsonName('sku')]
    [XmlName('SKU')]
    [BsonName('sku')]
    Code: string;
    [JsonName('qty')]
    [XmlName('Qty')]
    [BsonName('qty')]
    Quantity: Integer;
  end;

  TLines = class(TObjectList<TLine>)
  end;

  [XmlName('Shipment')]
  TShipment = class
  public
    [JsonName('id')]
    [XmlName('Id')]
    [BsonName('id')]
    Id: Int64;

    [JsonName('consignee')]
    [XmlName('Consignee')]
    [BsonName('consignee')]
    Consignee: string;

    [JsonName('amount')]
    [XmlName('Amount')]
    [BsonName('amount')]
    Amount: Currency;

    { The member that makes the point. In every encoded form this is text
      that looks like a date; only the Delphi contract says it IS one. }
    [JsonName('date')]
    [XmlName('Date')]
    [BsonName('date')]
    Booked: TDate;

    [JsonName('lines')]
    [XmlName('Lines')]
    [XmlItemName('Line')]
    [BsonName('lines')]
    Lines: TLines;

    constructor Create;
    destructor Destroy; override;
  end;

implementation

constructor TShipment.Create;
begin
  inherited Create;
  Lines := TLines.Create;
end;

destructor TShipment.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

end.
