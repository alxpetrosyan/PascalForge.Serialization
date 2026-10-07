unit ConvertModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ One model, decorated for three formats. Each engine reads only its own
  attributes, which is why the same member can be called three things. }

interface

uses
  System.Generics.Collections,
  PascalForge.Json,
  PascalForge.Xml,
  PascalForge.Bson;

type
  TLine = class
  public
    [JsonName('sku')] [XmlName('SKU')] [BsonName('sku')]
    Code: string;
    [JsonName('qty')] [XmlName('Qty')] [BsonName('qty')]
    Quantity: Integer;
  end;

  TLines = class(TObjectList<TLine>)
  end;

  [XmlName('Order')]
  TOrder = class
  public
    [JsonName('orderId')] [XmlName('OrderID')] [XmlAttribute] [BsonName('_id')]
    Id: Int64;

    [JsonName('customer')] [XmlName('Customer')] [BsonName('cust')]
    Customer: string;

    [JsonName('createdAt')] [XmlName('CreatedAt')] [BsonName('created_at')]
    Created: TDateTime;

    [JsonName('lines')] [XmlName('Lines')] [XmlItemName('Line')]
    [BsonName('lines')]
    Lines: TLines;

    constructor Create;
    destructor Destroy; override;
  end;

function SampleOrder: TOrder;

implementation

uses
  System.DateUtils;

constructor TOrder.Create;
begin
  inherited Create;
  Lines := TLines.Create;
end;

destructor TOrder.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

function SampleOrder: TOrder;
begin
  Result := TOrder.Create;
  Result.Id := 4611686018427387904;
  Result.Customer := 'Alice Sample';
  Result.Created := EncodeDateTime(2026, 3, 14, 9, 26, 53, 0);
  Result.Lines.Add(TLine.Create);
  Result.Lines[0].Code := 'A-1';
  Result.Lines[0].Quantity := 2;
end;

end.
