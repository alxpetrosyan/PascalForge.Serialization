unit MatrixModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{$SCOPEDENUMS ON}

{ The rich contract the conversion matrix is built on.

  Deliberately not a simple DTO: it carries a different member name per
  format, a nested class, a nested record, a nullable, a list, a dictionary,
  an enumeration, a set, a GUID, a date, a time, a timestamp, binary, an
  Int64 too large for a Double to hold exactly, and one member with a custom
  serializer. If a pair of formats can carry this, it can carry anything this
  library claims to support. }

interface

uses
  System.SysUtils, System.JSON, System.Generics.Collections,
  PascalForge.Serialization.Core,
  PascalForge.Nullable,
  PascalForge.Json, PascalForge.Xml, PascalForge.Bson, PascalForge.Protobuf,
  PascalForge.Asn1;

type
  TPriority = (Low, Normal, High);
  TFlag = (Urgent, Internal, Archived);
  TFlags = set of TFlag;

  { A value object that every format writes as ONE scalar rather than as an
    object, each in its own way. }
  TCoordinate = record
    Lat: Double;
    Lon: Double;
    class function Make(ALat, ALon: Double): TCoordinate; static;
    function Equals(const AOther: TCoordinate): Boolean;
  end;

  TAddress = class
  public
    [JsonName('city')]
    [XmlName('City')]
    [BsonName('c')] [ProtoField(1)]
    City: string;

    [JsonName('zip')]
    [XmlName('Zip')] [XmlAttribute]
    [BsonName('z')] [ProtoField(2)]
    Zip: string;
  end;

  TLine = class
  public
    [JsonName('sku')] [XmlName('SKU')] [BsonName('s')] [ProtoField(1)]
    Sku: string;
    [JsonName('qty')] [XmlName('Qty')] [BsonName('q')] [ProtoField(2)]
    Qty: Integer;
  end;

  TLines = class(TObjectList<TLine>);

  TOrder = class
  public
    { One member, three names, one value. }
    [JsonName('orderId')]
    [XmlName('OrderID')] [XmlAttribute]
    [BsonName('_id')] [ProtoField(1)]
    Id: Int64;

    [JsonName('ref')] [XmlName('Ref')] [BsonName('r')] [ProtoField(2)]
    Reference: string;

    [JsonName('priority')] [XmlName('Priority')] [BsonName('p')] [ProtoField(3)]
    Priority: TPriority;

    [JsonName('flags')] [XmlName('Flags')] [BsonName('f')] [ProtoField(4)]
    Flags: TFlags;

    [JsonName('uid')] [XmlName('Uid')] [BsonName('u')] [ProtoField(5)]
    Uid: TGUID;

    [JsonName('booked')] [XmlName('Booked')] [BsonName('b')] [ProtoField(6)]
    Booked: TDate;

    [JsonName('cutoff')] [XmlName('Cutoff')] [BsonName('co')] [ProtoField(7)]
    Cutoff: TTime;

    [JsonName('created')] [XmlName('Created')] [BsonName('cr')] [ProtoField(8)]
    Created: TDateTime;

    [JsonName('amount')] [XmlName('Amount')] [BsonName('a')] [ProtoField(9)]
    Amount: Currency;

    [JsonName('discount')] [XmlName('Discount')] [BsonName('d')] [ProtoField(10)]
    Discount: TNullable<Integer>;

    [JsonName('note')] [XmlName('Note')] [BsonName('n')] [ProtoField(11)]
    Note: TNullable<string>;

    [JsonName('where')] [XmlName('Where')] [BsonName('w')] [ProtoField(12)]
    Where: TCoordinate;

    [JsonName('address')] [XmlName('Address')] [BsonName('ad')] [ProtoField(13)]
    Address: TAddress;

    [JsonName('lines')] [XmlName('Lines')] [XmlItemName('Line')] [BsonName('l')] [ProtoField(14)]
    Lines: TLines;

    [JsonName('tags')] [XmlName('Tags')] [XmlItemName('Tag')] [BsonName('t')] [ProtoField(15)]
    Tags: TDictionary<string, string>;

    destructor Destroy; override;
  end;

{ The same order every time, so two conversions can be compared. }
function SampleOrder: TOrder;
{ A stable one-line rendering of everything the contract carries, for
  comparing an order that went one way against one that went another. }
function Describe(AOrder: TOrder): string;

{ The three per-format custom serializers for TCoordinate, registered once. }
type
  TJsonCoordinate = class(TCustomJsonValueSerializer<TCoordinate>)
  public
    function SerializeValue(const AValue: TCoordinate): TJSONValue; override;
    function DeserializeValue(const AJson: TJSONValue): TCoordinate; override;
  end;

  TXmlCoordinate = class(TXmlTextValueSerializer<TCoordinate>)
  public
    function ToText(const AValue: TCoordinate): string; override;
    function FromText(const AText: string): TCoordinate; override;
  end;

  TProtoCoordinate = class(TCustomProtoValueSerializer<TCoordinate>)
  public
    function SerializeValue(const AValue: TCoordinate;
      out AWireType: TProtoWireType): TBytes; override;
    function DeserializeValue(const AData: TBytes;
      AWireType: TProtoWireType;
      const AExisting: TCoordinate): TCoordinate; override;
  end;

  TBsonCoordinate = class(TCustomBsonValueSerializer<TCoordinate>)
  public
    function SerializeValue(const AValue: TCoordinate): TBsonValue; override;
    function DeserializeValue(AValue: TBsonValue;
      const AExisting: TCoordinate): TCoordinate; override;
  end;

  { ASN.1 has no REAL, and this is the thing its refusal message points at:
    the caller knows what the two doubles mean and says so. A coordinate to
    seven decimal places is a centimetre, and an INTEGER of ten-millionths
    is exact. }
  TAsn1Coordinate = class(TCustomAsn1ValueSerializer<TCoordinate>)
  public
    function SerializeValue(const AValue: TCoordinate): TAsn1Value; override;
    function DeserializeValue(AValue: TAsn1Value;
      const AExisting: TCoordinate): TCoordinate; override;
  end;

procedure ConfigureFormats;

implementation

uses
  System.DateUtils;

class function TCoordinate.Make(ALat, ALon: Double): TCoordinate;
begin
  Result.Lat := ALat;
  Result.Lon := ALon;
end;

function TCoordinate.Equals(const AOther: TCoordinate): Boolean;
begin
  Result := (Abs(Lat - AOther.Lat) < 1e-9) and (Abs(Lon - AOther.Lon) < 1e-9);
end;

destructor TOrder.Destroy;
begin
  Address.Free;
  Lines.Free;
  Tags.Free;
  inherited Destroy;
end;

function SampleOrder: TOrder;
var
  L: TLine;
begin
  Result := TOrder.Create;
  Result.Id := 4611686018427387903;      { too large for a Double to hold }
  Result.Reference := 'ORD-2026-0007';
  Result.Priority := TPriority.High;
  Result.Flags := [TFlag.Urgent, TFlag.Archived];
  Result.Uid := StringToGUID('{3F2504E0-4F89-11D3-9A0C-0305E82C3301}');
  Result.Booked := EncodeDate(2026, 3, 14);
  Result.Cutoff := EncodeTime(17, 45, 30, 0);
  Result.Created := EncodeDateTime(2026, 3, 14, 9, 26, 53, 0);
  Result.Amount := 1234.5678;
  Result.Discount := 15;
  Result.Note := nil;                    { present but empty }
  Result.Where := TCoordinate.Make(51.4779, -0.0015);

  Result.Address := TAddress.Create;
  Result.Address.City := 'Midtown';
  Result.Address.Zip := '0100';

  Result.Lines := TLines.Create(True);
  L := TLine.Create; L.Sku := 'A-1'; L.Qty := 2; Result.Lines.Add(L);
  L := TLine.Create; L.Sku := 'B-2'; L.Qty := 5; Result.Lines.Add(L);

  Result.Tags := TDictionary<string, string>.Create;
  Result.Tags.Add('channel', 'web');
end;

function Describe(AOrder: TOrder): string;
var
  I: Integer;
  Tag: string;
begin
  if AOrder = nil then Exit('(nil)');
  Result := Format(
    'id=%d ref=%s pri=%d flags=%d uid=%s booked=%s cutoff=%s created=%s ' +
    'amount=%s discount=%s note=%s where=%.4f/%.4f',
    [AOrder.Id, AOrder.Reference, Ord(AOrder.Priority),
     Byte(AOrder.Flags), GUIDToString(AOrder.Uid),
     FormatDateTime('yyyy-mm-dd', AOrder.Booked, TFormatSettings.Invariant),
     FormatDateTime('hh:nn:ss', AOrder.Cutoff, TFormatSettings.Invariant),
     FormatDateTime('yyyy-mm-dd hh:nn:ss', AOrder.Created,
       TFormatSettings.Invariant),
     CurrToStr(AOrder.Amount, TFormatSettings.Invariant),
     BoolToStr(AOrder.Discount.HasValue, True) + ':' +
       IntToStr(AOrder.Discount.Value),
     BoolToStr(AOrder.Note.HasValue, True),
     AOrder.Where.Lat, AOrder.Where.Lon]);

  if AOrder.Address <> nil then
    Result := Result + Format(' addr=%s/%s',
      [AOrder.Address.City, AOrder.Address.Zip])
  else
    Result := Result + ' addr=(nil)';

  if AOrder.Lines <> nil then
  begin
    Result := Result + ' lines=';
    for I := 0 to AOrder.Lines.Count - 1 do
      Result := Result + Format('[%s:%d]',
        [AOrder.Lines[I].Sku, AOrder.Lines[I].Qty]);
  end
  else
    Result := Result + ' lines=(nil)';

  if (AOrder.Tags <> nil) and AOrder.Tags.TryGetValue('channel', Tag) then
    Result := Result + ' tag=' + Tag
  else
    Result := Result + ' tag=(none)';
end;

{ ------------------------------------------------------ the three codecs --- }

function TJsonCoordinate.SerializeValue(const AValue: TCoordinate): TJSONValue;
begin
  Result := TJSONString.Create(
    FloatToStr(AValue.Lat, TFormatSettings.Invariant) + ',' +
    FloatToStr(AValue.Lon, TFormatSettings.Invariant));
end;

function TJsonCoordinate.DeserializeValue(const AJson: TJSONValue): TCoordinate;
var
  Parts: TArray<string>;
begin
  Parts := AJson.Value.Split([',']);
  Result.Lat := StrToFloat(Parts[0], TFormatSettings.Invariant);
  Result.Lon := StrToFloat(Parts[1], TFormatSettings.Invariant);
end;

function TXmlCoordinate.ToText(const AValue: TCoordinate): string;
begin
  Result := FloatToStr(AValue.Lat, TFormatSettings.Invariant) + ' ' +
            FloatToStr(AValue.Lon, TFormatSettings.Invariant);
end;

function TXmlCoordinate.FromText(const AText: string): TCoordinate;
var
  Parts: TArray<string>;
begin
  Parts := AText.Split([' ']);
  Result.Lat := StrToFloat(Parts[0], TFormatSettings.Invariant);
  Result.Lon := StrToFloat(Parts[1], TFormatSettings.Invariant);
end;

{ Protobuf has no record-without-field-numbers, so a value object either
  declares them or brings its own codec. This one is a length-delimited
  string, which is what the other three do too. }
function TProtoCoordinate.SerializeValue(const AValue: TCoordinate;
  out AWireType: TProtoWireType): TBytes;
begin
  AWireType := TProtoWireType.LengthDelimited;
  Result := StringToUtf8Bytes(
    FloatToStr(AValue.Lat, TFormatSettings.Invariant) + ';' +
    FloatToStr(AValue.Lon, TFormatSettings.Invariant));
end;

function TProtoCoordinate.DeserializeValue(const AData: TBytes;
  AWireType: TProtoWireType; const AExisting: TCoordinate): TCoordinate;
var
  Parts: TArray<string>;
begin
  Parts := Utf8BytesToString(AData).Split([';']);
  Result.Lat := StrToFloat(Parts[0], TFormatSettings.Invariant);
  Result.Lon := StrToFloat(Parts[1], TFormatSettings.Invariant);
end;

function TBsonCoordinate.SerializeValue(const AValue: TCoordinate): TBsonValue;
var
  Doc: TBsonValue;
begin
  Doc := TBsonValue.NewDocument;
  try
    Doc.Add('lat', TBsonValue.NewDouble(AValue.Lat));
    Doc.Add('lon', TBsonValue.NewDouble(AValue.Lon));
  except
    Doc.Free;
    raise;
  end;
  Result := Doc;
end;

function TBsonCoordinate.DeserializeValue(AValue: TBsonValue;
  const AExisting: TCoordinate): TCoordinate;
begin
  Result.Lat := AValue.Find('lat').AsDouble;
  Result.Lon := AValue.Find('lon').AsDouble;
end;

const
  { Ten-millionths of a degree: about a centimetre, and an exact integer. }
  COORD_SCALE = 10000000;

function TAsn1Coordinate.SerializeValue(
  const AValue: TCoordinate): TAsn1Value;
var
  Seq: TAsn1Value;
begin
  Seq := TAsn1Value.NewSequence;
  try
    Seq.Add(TAsn1Value.NewInteger(Round(AValue.Lat * COORD_SCALE)));
    Seq.Add(TAsn1Value.NewInteger(Round(AValue.Lon * COORD_SCALE)));
  except
    Seq.Free;
    raise;
  end;
  Result := Seq;
end;

function TAsn1Coordinate.DeserializeValue(AValue: TAsn1Value;
  const AExisting: TCoordinate): TCoordinate;
begin
  Result.Lat := AValue.Items[0].AsInt64 / COORD_SCALE;
  Result.Lon := AValue.Items[1].AsInt64 / COORD_SCALE;
end;

procedure ConfigureFormats;
begin
  TJsonSerializer.RegisterTypeSerializer<TCoordinate, TJsonCoordinate>;
  TXmlSerializer.RegisterTypeSerializer<TCoordinate>(TXmlCoordinate);
  TBsonSerializer.RegisterTypeSerializer<TCoordinate>(TBsonCoordinate);
  TProtobufSerializer.RegisterTypeSerializer<TCoordinate>(TProtoCoordinate);
  TAsn1Serializer.RegisterTypeSerializer<TCoordinate>(TAsn1Coordinate);

  TJsonSerializer.RegisterEnumMapping<TPriority>(['low', 'normal', 'high']);
  TXmlSerializer.RegisterEnumMapping<TPriority>(['LOW', 'NORMAL', 'HIGH']);
  { A protobuf enum is a NUMBER, and the numbers a .proto assigns need not
    be 0, 1, 2 in order. }
  TProtobufSerializer.RegisterEnumNumbers<TPriority>([0, 5, 10]);
end;

end.
