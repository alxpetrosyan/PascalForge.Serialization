unit ContractMatrixModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ THE MODEL THE CONTRACT-AWARE MATRIX IS BUILT ON.

  It is deliberately the hardest case for a cross-format contract hand-off,
  which is to say: every format is told to spell it differently.

    a member renamed by EVERY format, to a different name each time
    a list, which XML wraps and JSON does not
    a Currency, which BSON and MessagePack write as a scaled integer
    typed scalars, which CSV writes as text
    a nested object, an enum, a date and a GUID

  If a contract-aware conversion is really Deserialize<T> followed by
  Serialize<T>, then none of that can matter: the Delphi type supplies every
  name and every type on both sides, and the wire spelling in between is the
  destination format's business. A member that arrives back wrong is a defect
  in the library, not a property of the formats.

  The Protobuf field numbers and the ASN.1 ordering are here for the same
  reason - so that the schema-driven formats can take part in the matrix on
  the contract path, where the Delphi type IS the schema. }

interface

uses
  System.SysUtils, System.Generics.Collections,
  PascalForge.Json, PascalForge.Xml, PascalForge.Bson, PascalForge.Cbor,
  PascalForge.MessagePack, PascalForge.Yaml, PascalForge.Csv,
  PascalForge.Avro, PascalForge.Asn1, PascalForge.Protobuf;

type
  {$SCOPEDENUMS ON}
  TProbeFlavour = (Plain, Rich, Special);
  {$SCOPEDENUMS OFF}

  { One line of the order. Renamed by every format, so a hand-off that leaned
    on the wire name instead of the contract would lose both members. }
  TProbeLine = class
  public
    [JsonName('sku')]
    [XmlName('SKU')]
    [BsonName('sku_code')]
    [CborName('s')]
    [MessagePackName('sk')]
    [YamlName('sku_name')]
    [CsvName('SkuCode')]
    [AvroName('sku')]
    [ProtoField(1)]
    Sku: string;

    [JsonName('qty')]
    [XmlName('Qty')]
    [BsonName('quantity')]
    [CborName('q')]
    [MessagePackName('qt')]
    [YamlName('quantity')]
    [CsvName('Quantity')]
    [AvroName('qty')]
    [ProtoField(2)]
    Quantity: Integer;

    [JsonName('unit')]
    [XmlName('UnitPrice')]
    [BsonName('unit_price')]
    [CborName('u')]
    [MessagePackName('up')]
    [YamlName('unit_price')]
    [CsvName('UnitPrice')]
    [AvroName('unitPrice')]
    [ProtoField(3)]
    UnitPrice: Currency;
  end;

  { The nested object, so the hand-off has to carry a graph rather than a row. }
  TProbeParty = class
  public
    [JsonName('name')]
    [XmlName('Name')]
    [BsonName('nm')]
    [CborName('n')]
    [MessagePackName('nm')]
    [YamlName('name')]
    [CsvName('Name')]
    [AvroName('name')]
    [ProtoField(1)]
    Name: string;

    [JsonName('city')]
    [XmlName('City')]
    [BsonName('cty')]
    [CborName('c')]
    [MessagePackName('ct')]
    [YamlName('city')]
    [CsvName('City')]
    [AvroName('city')]
    [ProtoField(2)]
    City: string;
  end;

  { The root. Scalars of every family the formats disagree about, plus the
    list and the nested object. }
  [XmlName('Order')]
  TProbeOrder = class
  public
    [JsonName('orderId')]
    [XmlName('OrderID')]
    [BsonName('_id')]
    [CborName('id')]
    [MessagePackName('oid')]
    [YamlName('order_id')]
    [CsvName('OrderId')]
    [AvroName('orderId')]
    [ProtoField(1)]
    OrderId: Int64;

    [JsonName('reference')]
    [XmlName('Reference')]
    [BsonName('ref')]
    [CborName('r')]
    [MessagePackName('rf')]
    [YamlName('reference')]
    [CsvName('Reference')]
    [AvroName('reference')]
    [ProtoField(2)]
    Reference: string;

    { The one every format spells its own way on the wire: BSON and
      MessagePack default to the scaled Int64 Delphi actually stores. }
    [JsonName('total')]
    [XmlName('Total')]
    [BsonName('tot')]
    [CborName('t')]
    [MessagePackName('tt')]
    [YamlName('total')]
    [CsvName('Total')]
    [AvroName('total')]
    [ProtoField(3)]
    Total: Currency;

    [JsonName('rate')]
    [XmlName('Rate')]
    [BsonName('rt')]
    [CborName('ra')]
    [MessagePackName('rat')]
    [YamlName('rate')]
    [CsvName('Rate')]
    [AvroName('rate')]
    [ProtoField(4)]
    Rate: Double;

    [JsonName('active')]
    [XmlName('Active')]
    [BsonName('act')]
    [CborName('a')]
    [MessagePackName('ac')]
    [YamlName('active')]
    [CsvName('Active')]
    [AvroName('active')]
    [ProtoField(5)]
    Active: Boolean;

    [JsonName('flavour')]
    [XmlName('Flavour')]
    [BsonName('flav')]
    [CborName('f')]
    [MessagePackName('fl')]
    [YamlName('flavour')]
    [CsvName('Flavour')]
    [AvroName('flavour')]
    [ProtoField(6)]
    Flavour: TProbeFlavour;

    [JsonName('placed')]
    [XmlName('Placed')]
    [BsonName('plc')]
    [CborName('p')]
    [MessagePackName('pl')]
    [YamlName('placed')]
    [CsvName('Placed')]
    [AvroName('placed')]
    [ProtoField(7)]
    Placed: TDateTime;

    { XML wraps a list by default; JSON writes an array; CSV cannot hold one
      at all under its conservative default. All three are the destination's
      business and none of them may change what comes back. }
    [JsonName('lines')]
    [XmlName('Lines')]
    [BsonName('ln')]
    [CborName('l')]
    [MessagePackName('li')]
    [YamlName('lines')]
    [AvroName('lines')]
    [ProtoField(8)]
    Lines: TObjectList<TProbeLine>;

    [JsonName('shipper')]
    [XmlName('Shipper')]
    [BsonName('pyr')]
    [CborName('py')]
    [MessagePackName('pa')]
    [YamlName('shipper')]
    [AvroName('shipper')]
    [ProtoField(9)]
    Shipper: TProbeParty;

    constructor Create;
    destructor Destroy; override;
  end;

  { A root with no list and no nested object, so that the table formats can
    take part in the matrix on their own terms. Every member is a typed
    scalar, which is the point: CSV writes them all as text and the
    destination's contract has to type them again. }
  [XmlName('Row')]
  TProbeRow = class
  public
    [JsonName('id')]
    [XmlName('Id')]
    [BsonName('_id')]
    [CborName('i')]
    [MessagePackName('id')]
    [YamlName('id')]
    [CsvName('Id')]
    [AvroName('id')]
    [ProtoField(1)]
    Id: Int64;

    [JsonName('label')]
    [XmlName('Label')]
    [BsonName('lbl')]
    [CborName('l')]
    [MessagePackName('lb')]
    [YamlName('label')]
    [CsvName('Label')]
    [AvroName('label')]
    [ProtoField(2)]
    Label_: string;

    [JsonName('amount')]
    [XmlName('Amount')]
    [BsonName('amt')]
    [CborName('a')]
    [MessagePackName('am')]
    [YamlName('amount')]
    [CsvName('Amount')]
    [AvroName('amount')]
    [ProtoField(3)]
    Amount: Currency;

    [JsonName('ratio')]
    [XmlName('Ratio')]
    [BsonName('rto')]
    [CborName('r')]
    [MessagePackName('rt')]
    [YamlName('ratio')]
    [CsvName('Ratio')]
    [AvroName('ratio')]
    [ProtoField(4)]
    Ratio: Double;

    [JsonName('ok')]
    [XmlName('Ok')]
    [BsonName('ok')]
    [CborName('o')]
    [MessagePackName('ok')]
    [YamlName('ok')]
    [CsvName('Ok')]
    [AvroName('ok')]
    [ProtoField(5)]
    Ok: Boolean;

    [JsonName('when')]
    [XmlName('When')]
    [BsonName('whn')]
    [CborName('w')]
    [MessagePackName('wh')]
    [YamlName('when')]
    [CsvName('When')]
    [AvroName('when')]
    [ProtoField(6)]
    When: TDateTime;
  end;

implementation

constructor TProbeOrder.Create;
begin
  inherited Create;
  Lines := TObjectList<TProbeLine>.Create(True);
  Shipper := TProbeParty.Create;
end;

destructor TProbeOrder.Destroy;
begin
  Shipper.Free;
  Lines.Free;
  inherited;
end;

end.
