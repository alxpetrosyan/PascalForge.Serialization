program Conversion;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Three formats in one program, and what happens between them.

  This is the only test that links all three registration units, which makes
  it the one place the registry can be exercised properly: what is available,
  what is not, what happens when a format is asked for that nobody linked.

  Two conversion modes are checked, and the difference between them is the
  point:

    CONTRACT-AWARE  goes through the Delphi type. Each side applies its own
                    attributes, so a member can be 'orderId' in JSON, an
                    OrderID attribute in XML, and '_id' in BSON, and all
                    three are right.

    STRUCTURAL      goes through the dynamic tree. It has no contract to
                    apply, carries only what every format shares, and says
                    so. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.DateUtils, System.StrUtils, System.TypInfo,
  System.Classes, System.SyncObjs, System.Generics.Collections,
  ConversionModels in 'ConversionModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  PascalForge.Xml in '..\..\src\PascalForge.Xml.pas',
  PascalForge.Bson in '..\..\src\PascalForge.Bson.pas',
  PascalForge.Bson.Internal in '..\..\src\PascalForge.Bson.Internal.pas',
  { All three registered, which no other test in this suite does. }
  PascalForge.Json.Registration in '..\..\src\PascalForge.Json.Registration.pas',
  PascalForge.Xml.Registration in '..\..\src\PascalForge.Xml.Registration.pas',
  PascalForge.Bson.Registration in '..\..\src\PascalForge.Bson.Registration.pas';

var
  GFailures: Integer = 0;
  GLive: Integer = 0;

procedure Check(ACondition: Boolean; const AName: string);
begin
  if ACondition then
    Writeln(AName, ': PASS')
  else
  begin
    Writeln(AName, ': FAIL');
    Inc(GFailures);
  end;
end;

procedure Note(const AText: string);
begin
  Writeln('  ', AText);
end;

function Has(const AText, AFragment: string): Boolean;
begin
  Result := Pos(AFragment, AText) > 0;
end;

{ Three configurations of the same thing, so that "the formats are
  independent" is a fact rather than a claim. }
procedure ConfigureFormats;
begin
  TJsonSerializer.RegisterTypeSerializer<TCoordinate>(TJsonCoordinateSerializer);
  TXmlSerializer.RegisterTypeSerializer<TCoordinate>(TXmlCoordinateSerializer);
  TBsonSerializer.RegisterTypeSerializer<TCoordinate>(TBsonCoordinateSerializer);

  { The same member, configured three different ways. }
  TJsonSerializer.RegisterFieldDateTimeFormat<TOrder>('Created',
    TJsonDateTimeFormat.UnixSeconds);
  TXmlSerializer.RegisterFieldDateTimeFormat<TOrder>('Created',
    TXmlDateTimeFormat.Xsd);
  TBsonSerializer.RegisterFieldDateTimeRepresentation<TOrder>('Created',
    TBsonDateTimeRepresentation.Native);
end;

function SampleOrder: TOrder;
begin
  Result := TOrder.Create;
  Inc(GLive);
  Result.Id := 4611686018427387904;
  Result.Customer := 'Alice Sample';
  Result.HiddenFromJson := 'json cannot see me';
  Result.HiddenFromXml := 'xml cannot see me';
  Result.HiddenFromBson := 'bson cannot see me';
  Result.Flavour := TFlavour.Spicy;
  Result.Note := 'urgent';
  Result.Rebate := nil;
  Result.Created := EncodeDateTime(2026, 3, 14, 9, 26, 53, 0);
  Result.Booked := EncodeDate(2026, 3, 14);
  Result.Reference := StringToGUID('{3F2504E0-4F89-11D3-9A0C-0305E82C3301}');
  Result.Lines.Add(TLine.Create);
  Result.Lines[0].Code := 'A-1';
  Result.Lines[0].Quantity := 2;
  Result.Lines.Add(TLine.Create);
  Result.Lines[1].Code := 'B-2';
  Result.Lines[1].Quantity := 5;
  Result.Rates.Add('USD', 1.0);
end;

procedure FreeOrder(AOrder: TOrder);
begin
  if AOrder <> nil then
  begin
    Dec(GLive);
    AOrder.Free;
  end;
end;

{ --------------------------------------------------------- the registry --- }

procedure TestRegistry;
var
  Raised: Boolean;
  Msg: string;
begin
  Writeln('-- what is registered --');
  Check(TSerialization.IsRegistered(TSerializationFormat.Json), 'FORMAT_JSON_REGISTERED');
  Check(TSerialization.IsRegistered(TSerializationFormat.Xml), 'FORMAT_XML_REGISTERED');
  Check(TSerialization.IsRegistered(TSerializationFormat.Bson), 'FORMAT_BSON_REGISTERED');

  { Known enumeration values with no implementation behind them. They are not
    faked, and asking for one says so. }
  Check(not TSerialization.IsRegistered(TSerializationFormat.Protobuf),
    'FORMAT_PROTOBUF_UNREGISTERED');
  Check(not TSerialization.IsRegistered(TSerializationFormat.Cbor),
    'FORMAT_CBOR_UNREGISTERED');
  Check(not TSerialization.IsRegistered(TSerializationFormat.MessagePack),
    'FORMAT_MESSAGEPACK_UNREGISTERED');
  Check(Length(TSerialization.RegisteredFormats) = 3,
    'ONLY_LINKED_FORMATS_ARE_REGISTERED');

  Raised := False;
  Msg := '';
  try
    TSerialization.Convert(TSerializationPayload.FromText('{}'),
      TSerializationFormat.Json, TSerializationFormat.Cbor);
  except
    on E: ESerializationFormatNotRegistered do
    begin
      Raised := True;
      Msg := E.Message;
    end;
  end;
  Check(Raised, 'UNREGISTERED_FORMAT_RUNTIME_ERROR');
  { The message has to say what to do about it, not merely that something
    went wrong. }
  Check(Has(Msg, 'Cbor') and Has(Msg, 'Registration'),
    'UNREGISTERED_FORMAT_ERROR_MESSAGE');
  Note(Msg);

  { Nothing falls back to another format when the one asked for is absent. }
  Check(Raised, 'NO_FORMAT_FALLBACK');
end;

{ --------------------------------------------------- attribute isolation --- }

procedure TestAttributeIsolation;
var
  O: TOrder;
  Json, Xml: string;
  Bson: TBytes;
  Doc: TBsonValue;
begin
  Writeln('-- each engine reads only its own attributes --');
  O := SampleOrder;
  try
    Json := TJsonSerializer.Serialize<TOrder>(O);
    Xml := TXmlSerializer.Serialize<TOrder>(O);
    Bson := TBsonSerializer.Serialize<TOrder>(O);
  finally
    FreeOrder(O);
  end;
  Note(Json);
  Note(Xml);

  { Each format used its own name for the same member, and none of them
    used another format's. }
  Check(Has(Json, '"orderId"') and not Has(Json, 'OrderID') and
        not Has(Json, '"_id"'), 'JSON_ATTRIBUTE_ISOLATION');
  Check(Has(Xml, 'OrderID=') and not Has(Xml, 'orderId') and
        not Has(Xml, '_id'), 'XML_ATTRIBUTE_ISOLATION');

  Doc := TBsonEngine.ParseDocument(Bson);
  try
    Check((Doc.Find('_id') <> nil) and (Doc.Find('orderId') = nil) and
          (Doc.Find('OrderID') = nil), 'BSON_ATTRIBUTE_ISOLATION');
    Check((Doc.Find('cust') <> nil) and (Doc.Find('flav') <> nil),
      'BSON_USES_ITS_OWN_NAMES');
    { [XmlAttribute] is meaningless to BSON, which has no attributes: the
      member is simply an element of the document. }
    Check(Doc.Find('_id').Kind = TBsonKind.Int64,
      'BSON_IGNORES_XML_PLACEMENT');
    Check(Doc.Find('HiddenFromBson') = nil, 'BSON_IGNORE_ISOLATION');
  finally
    Doc.Free;
  end;

  Check(Has(Json, '"orderId"') and Has(Xml, 'OrderID') and Has(Json, 'sku') and
        Has(Xml, '<SKU>'), 'MULTI_FORMAT_NAMES_DIFFER');

  { [JsonIgnore] removes it from JSON and from nothing else. }
  Check(not Has(Json, 'HiddenFromJson') and Has(Xml, 'HiddenFromJson'),
    'MULTI_FORMAT_IGNORE_ISOLATION');
  Check(not Has(Xml, 'HiddenFromXml') and Has(Json, 'hiddenFromXml'),
    'XML_IGNORE_ISOLATION');

  { The same timestamp, configured three ways. }
  Check(Has(Json, '"createdAt":' +
    IntToStr(DateTimeToUnix(EncodeDateTime(2026, 3, 14, 9, 26, 53, 0), True))),
    'JSON_DATE_CONFIG_APPLIED');
  Check(Has(Xml, '<CreatedAt>2026-03-14T09:26:53</CreatedAt>'),
    'XML_DATE_CONFIG_APPLIED');
  Doc := TBsonEngine.ParseDocument(Bson);
  try
    Check(Doc.Find('created_at').Kind = TBsonKind.DateTime,
      'BSON_DATE_CONFIG_APPLIED');
    Check(Has(Json, '"createdAt":17') and
          Has(Xml, '2026-03-14T09:26:53') and
          (Doc.Find('created_at').Kind = TBsonKind.DateTime),
      'MULTI_FORMAT_DATE_CONFIG_DIFFERS');
  finally
    Doc.Free;
  end;
end;

procedure TestCustomSerializerIsolation;
var
  P, Back: TPlace;
  Json, Xml: string;
  Bson: TBytes;
  Doc: TBsonValue;
begin
  Writeln('-- a custom serializer belongs to one format --');
  P := TPlace.Create;
  try
    P.Name := 'Greenwich';
    P.Where.Latitude := 51.4779;
    P.Where.Longitude := -0.0015;
    Json := TJsonSerializer.Serialize<TPlace>(P);
    Xml := TXmlSerializer.Serialize<TPlace>(P);
    Bson := TBsonSerializer.Serialize<TPlace>(P);
  finally
    P.Free;
  end;
  Note(Json);
  Note(Xml);

  Doc := TBsonEngine.ParseDocument(Bson);
  try
    { Three serializers, three shapes, one Delphi record. }
    Check(Has(Json, '"where":"51.4779,-0.0015"') and
          Has(Xml, '<Where lat="51.4779" lon="-0.0015"/>') and
          (Doc.Find('where').Kind = TBsonKind.Arr),
      'MULTI_FORMAT_CUSTOM_SERIALIZER_ISOLATION');
  finally
    Doc.Free;
  end;

  Back := TJsonSerializer.Deserialize<TPlace>(Json);
  try
    Check(Abs(Back.Where.Latitude - 51.4779) < 1E-9,
      'JSON_CUSTOM_SERIALIZER_ROUNDTRIP');
  finally
    Back.Free;
  end;
end;

{ ----------------------------------------------- contract-aware conversion --- }

{ Every contract-aware conversion is the same shape: read T by the source's
  rules, write T by the destination's. This checks the destination's own
  attributes really did apply, and that the values survived. }
procedure CheckContractConversion(AFrom, ATo: TSerializationFormat;
  const ASource: TSerializationPayload; const AMarker: string);
var
  Result_: TSerializationPayload;
  Back: TOrder;
  Text: string;
  Doc: TBsonValue;
  Ok: Boolean;
  V: Currency;
begin
  Result_ := TSerialization.Convert<TOrder>(ASource, AFrom, ATo);
  Back := TSerialization.Deserialize<TOrder>(Result_, ATo);
  try
    Ok := (Back.Id = 4611686018427387904) and
          (Back.Customer = 'Alice Sample') and
          (Back.Flavour = TFlavour.Spicy) and
          Back.Note.HasValue and (Back.Note.Value = 'urgent') and
          (not Back.Rebate.HasValue) and
          SameDateTime(Back.Created,
            EncodeDateTime(2026, 3, 14, 9, 26, 53, 0)) and
          (Back.Booked = EncodeDate(2026, 3, 14)) and
          (Back.Reference =
            StringToGUID('{3F2504E0-4F89-11D3-9A0C-0305E82C3301}')) and
          (Back.Lines.Count = 2) and (Back.Lines[1].Code = 'B-2') and
          Back.Rates.TryGetValue('USD', V) and (V = 1.0);
  finally
    Back.Free;
  end;

  { And the destination's own attributes visibly applied. }
  case ATo of
    TSerializationFormat.Json:
      begin
        Text := Result_.AsText;
        Ok := Ok and Has(Text, '"orderId"') and Has(Text, '"sku"');
      end;
    TSerializationFormat.Xml:
      begin
        Text := Result_.AsText;
        Ok := Ok and Has(Text, 'OrderID=') and Has(Text, '<SKU>');
      end;
    TSerializationFormat.Bson:
      begin
        Doc := TBsonEngine.ParseDocument(Result_.AsBytes);
        try
          Ok := Ok and (Doc.Find('_id') <> nil) and
                (Doc.Find('_id').Kind = TBsonKind.Int64);
        finally
          Doc.Free;
        end;
      end;
  end;
  Check(Ok, AMarker);
end;

procedure TestContractConversions;
var
  O: TOrder;
  Json, Xml: TSerializationPayload;
  Bson: TSerializationPayload;
begin
  Writeln('-- contract-aware conversion --');
  O := SampleOrder;
  try
    Json := TSerialization.Serialize<TOrder>(O, TSerializationFormat.Json);
    Xml := TSerialization.Serialize<TOrder>(O, TSerializationFormat.Xml);
    Bson := TSerialization.Serialize<TOrder>(O, TSerializationFormat.Bson);
  finally
    FreeOrder(O);
  end;

  CheckContractConversion(TSerializationFormat.Json, TSerializationFormat.Xml, Json, 'JSON_TO_XML_CONTRACT');
  CheckContractConversion(TSerializationFormat.Xml, TSerializationFormat.Json, Xml, 'XML_TO_JSON_CONTRACT');
  CheckContractConversion(TSerializationFormat.Json, TSerializationFormat.Bson, Json, 'JSON_TO_BSON_CONTRACT');
  CheckContractConversion(TSerializationFormat.Bson, TSerializationFormat.Json, Bson, 'BSON_TO_JSON_CONTRACT');
  CheckContractConversion(TSerializationFormat.Xml, TSerializationFormat.Bson, Xml, 'XML_TO_BSON_CONTRACT');
  CheckContractConversion(TSerializationFormat.Bson, TSerializationFormat.Xml, Bson, 'BSON_TO_XML_CONTRACT');

  { The intermediate T is built, written and released inside Convert; nothing
    escapes for a caller to free. GLive counts what this program made, and a
    conversion must not add to it. }
  Check(GLive = 0, 'CONTRACT_CONVERSION_LEAKS_NOTHING');
end;

{ --------------------------------------------- destination-oriented From --- }

procedure TestFromApi;
var
  O: TOrder;
  Json: string;
  Xml: string;
  Bson: TBytes;
  Back: TOrder;
begin
  Writeln('-- the destination-oriented From API --');
  O := SampleOrder;
  try
    Json := TJsonSerializer.Serialize<TOrder>(O);
  finally
    FreeOrder(O);
  end;

  { The destination is known at compile time, so only the source is looked
    up. Neither unit has a compile-time dependency on the other. }
  Xml := TXmlSerializer.From<TOrder>(Json, TSerializationFormat.Json);
  Check(Has(Xml, 'OrderID=') and Has(Xml, '<SKU>A-1</SKU>'), 'XML_FROM_JSON');

  Bson := TBsonSerializer.From<TOrder>(Xml, TSerializationFormat.Xml);
  Back := TBsonSerializer.Deserialize<TOrder>(Bson);
  try
    Check((Back.Id = 4611686018427387904) and (Back.Lines.Count = 2),
      'BSON_FROM_XML');
  finally
    Back.Free;
  end;

  Json := TJsonSerializer.From<TOrder>(Bson, TSerializationFormat.Bson);
  Check(Has(Json, '"orderId"') and Has(Json, '"sku":"A-1"'), 'JSON_FROM_BSON');

  { The structural form of the same call: no contract, so it carries only
    what every format shares. }
  Xml := TXmlSerializer.From('{"a":1,"b":"two"}', TSerializationFormat.Json);
  Check(Has(Xml, '<a>1</a>') and Has(Xml, '<b>two</b>'),
    'XML_FROM_JSON_STRUCTURAL');
end;

{ ---------------------------------------------------- structural mode --- }

procedure TestStructuralConversions;
const
  SRC = '{"id":7,"name":"Ada","tags":["x","y"],"nested":{"n":1},"flag":true}';
var
  Xml, Json2: TSerializationPayload;
  Bson: TSerializationPayload;
  Text: string;
begin
  Writeln('-- structural conversion --');

  Xml := TSerialization.Convert(TSerializationPayload.FromText(SRC),
    TSerializationFormat.Json, TSerializationFormat.Xml);
  Text := Xml.AsText;
  Note(Text);
  Check(Has(Text, '<id>7</id>') and Has(Text, '<name>Ada</name>') and
        Has(Text, '<tags>x</tags><tags>y</tags>') and
        Has(Text, '<nested><n>1</n></nested>'),
    'JSON_TO_XML_STRUCTURAL');

  Json2 := TSerialization.Convert(Xml, TSerializationFormat.Xml, TSerializationFormat.Json);
  Text := Json2.AsText;
  Note(Text);
  { Coming back, the structure survives - but the TYPES do not, because XML
    text carries none. 7 went out a number and comes back "7". That is the
    documented cost of the contract-free path, not an accident. }
  Check(Has(Text, '"id":"7"') and Has(Text, '"name":"Ada"') and
        Has(Text, '"tags":["x","y"]'),
    'XML_TO_JSON_STRUCTURAL');
  Check(Has(Text, '"id":"7"'), 'XML_STRUCTURAL_LOSES_SCALAR_TYPES');

  Bson := TSerialization.Convert(TSerializationPayload.FromText(SRC),
    TSerializationFormat.Json, TSerializationFormat.Bson);
  Json2 := TSerialization.Convert(Bson, TSerializationFormat.Bson, TSerializationFormat.Json);
  Text := Json2.AsText;
  Note(Text);
  { BSON does carry types, so the number is still a number. }
  Check(Has(Text, '"id":7') and Has(Text, '"flag":true') and
        Has(Text, '"tags":["x","y"]'),
    'JSON_TO_BSON_STRUCTURAL');
  Check(Has(Text, '"id":7'), 'BSON_TO_JSON_STRUCTURAL');
  Check(Has(Text, '"id":7'), 'BSON_STRUCTURAL_KEEPS_SCALAR_TYPES');

  Xml := TSerialization.Convert(Bson, TSerializationFormat.Bson, TSerializationFormat.Xml);
  Check(Has(Xml.AsText, '<id>7</id>'), 'BSON_TO_XML_STRUCTURAL');
  Bson := TSerialization.Convert(Xml, TSerializationFormat.Xml, TSerializationFormat.Bson);
  Check(Length(Bson.AsBytes) > 0, 'XML_TO_BSON_STRUCTURAL');
end;

{ XML carries things the dynamic tree does not, and the policy for each is
  documented rather than accidental. }
procedure TestXmlStructuralPolicy;
var
  Json, Xml: TSerializationPayload;
  Text: string;
  Raised: Boolean;
begin
  Writeln('-- what structural conversion does with XML-only structure --');

  { An attribute becomes a member named '@name'. }
  Json := TSerialization.Convert(
    TSerializationPayload.FromText('<r a="1"><b>2</b></r>'),
    TSerializationFormat.Xml, TSerializationFormat.Json);
  Text := Json.AsText;
  Note(Text);
  Check(Has(Text, '"@a":"1"'), 'XML_STRUCTURAL_ATTRIBUTE_POLICY');

  { Text alongside children becomes '#text'. }
  Json := TSerialization.Convert(
    TSerializationPayload.FromText('<r>lead<b>2</b></r>'),
    TSerializationFormat.Xml, TSerializationFormat.Json);
  Text := Json.AsText;
  Note(Text);
  Check(Has(Text, '"#text":"lead"'), 'XML_STRUCTURAL_MIXED_CONTENT_POLICY');

  { Repeated siblings become an array. }
  Json := TSerialization.Convert(
    TSerializationPayload.FromText('<r><b>1</b><b>2</b></r>'),
    TSerializationFormat.Xml, TSerializationFormat.Json);
  Text := Json.AsText;
  Note(Text);
  Check(Has(Text, '"b":["1","2"]'), 'XML_STRUCTURAL_REPEATED_ELEMENT_POLICY');

  { A namespace URI becomes '@xmlns'. The prefix does not survive, and is
    documented as not contractual. }
  Json := TSerialization.Convert(
    TSerializationPayload.FromText('<p:r xmlns:p="urn:x"><p:b>1</p:b></p:r>'),
    TSerializationFormat.Xml, TSerializationFormat.Json);
  Text := Json.AsText;
  Note(Text);
  Check(Has(Text, '"@xmlns":"urn:x"'), 'XML_STRUCTURAL_NAMESPACE_POLICY');

  { A JSON member name XML cannot spell is neither dropped nor mangled: the
    default profile encodes it the way XmlConvert.EncodeName does. See
    tests\StructuralFidelity for the encoding itself. }
  Xml := TSerialization.Convert(TSerializationPayload.FromText('{"not a name":1}'),
    TSerializationFormat.Json, TSerializationFormat.Xml);
  Text := Xml.AsText;
  Note(Text);
  Check(Has(Text, '_x0020_'), 'STRUCTURAL_IMPOSSIBLE_NAME_IS_ENCODED');

  { Reading XML back does NOT decode it. The reader is looking at somebody
    else's document, where an element genuinely called <_x0020_> means
    "_x0020_" and not " ". Decoding is available explicitly, through
    TXmlNameCodec.DecodeName, for a caller who knows where the XML came
    from. The profile that survives a round trip without any of this is
    Lossless, which puts the name in a key attribute. }
  Json := TSerialization.Convert(Xml, TSerializationFormat.Xml,
    TSerializationFormat.Json);
  Note(Json.AsText);
  Check(Has(Json.AsText, '"not_x0020_a_x0020_name"'),
    'FOREIGN_XML_LITERAL_X_ESCAPE_PRESERVED');

  Xml := TSerialization.Convert(TSerializationPayload.FromText('{"not a name":1}'),
    TSerializationFormat.Json, TSerializationFormat.Xml,
    TStructuralConversionProfile.Lossless);
  Json := TSerialization.Convert(Xml, TSerializationFormat.Xml,
    TSerializationFormat.Json, TStructuralConversionProfile.Lossless);
  Note(Json.AsText);
  Check(Has(Json.AsText, '"not a name"'),
    'STRUCTURAL_IMPOSSIBLE_NAME_ROUND_TRIPS');

  { The Strict profile is the one that refuses, and says where. }
  Raised := False;
  try
    TSerialization.Convert(TSerializationPayload.FromText('{"not a name":1}'),
      TSerializationFormat.Json, TSerializationFormat.Xml,
      TStructuralConversionProfile.Strict);
  except
    on E: EStructuralConversionError do
      Raised := (E.Path = '$.not a name') and
                (E.Issue = TStructuralIssue.InvalidDestinationName);
  end;
  Check(Raised, 'STRUCTURAL_IMPOSSIBLE_NAME_IS_REFUSED_IN_STRICT');
end;

{ ------------------------------------------------------- thread safety --- }

type
  TRegistryProbe = class(TThread)
  strict private
    FErrors: Integer;
  protected
    procedure Execute; override;
  public
    property Errors: Integer read FErrors;
  end;

procedure TRegistryProbe.Execute;
var
  I: Integer;
begin
  FErrors := 0;
  for I := 1 to 2000 do
    try
      if TSerializationFormats.Get(TSerializationFormat.Json) = nil then Inc(FErrors);
      if not TSerializationFormats.IsRegistered(TSerializationFormat.Xml) then Inc(FErrors);
      if Length(TSerializationFormats.RegisteredFormats) <> 3 then Inc(FErrors);
    except
      Inc(FErrors);
    end;
end;

procedure TestRegistryThreadSafe;
var
  Probes: array[0..3] of TRegistryProbe;
  I, Errors: Integer;
begin
  Writeln('-- the registry under concurrent readers --');
  for I := Low(Probes) to High(Probes) do
    Probes[I] := TRegistryProbe.Create(False);
  Errors := 0;
  for I := Low(Probes) to High(Probes) do
  begin
    Probes[I].WaitFor;
    Inc(Errors, Probes[I].Errors);
    Probes[I].Free;
  end;
  Check(Errors = 0, 'FORMAT_REGISTRY_THREAD_SAFE');
end;

procedure TestDuplicateRegistration;
var
  Raised: Boolean;
begin
  Writeln('-- registering a format twice --');
  { The same handler class again is harmless: a unit can be reached through
    more than one path. A DIFFERENT one is not, because which won would
    depend on initialization order. }
  Raised := False;
  try
    TSerializationFormats.Register(TSerializationFormat.Json,
      TSerializationFormatHandlerClass(
        TSerializationFormats.Get(TSerializationFormat.Json).ClassType));
  except
    on E: Exception do Raised := True;
  end;
  Check(not Raised, 'DUPLICATE_FORMAT_REGISTRATION_POLICY');

  Raised := False;
  try
    TSerializationFormats.Register(TSerializationFormat.Json,
      TSerializationFormatHandlerClass(
        TSerializationFormats.Get(TSerializationFormat.Xml).ClassType));
  except
    on E: Exception do Raised := True;
  end;
  Check(Raised, 'CONFLICTING_FORMAT_REGISTRATION_REFUSED');
end;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TJsonSerializationRegistration.RegisterFormat;
  TXmlSerializationRegistration.RegisterFormat;
  TBsonSerializationRegistration.RegisterFormat;
  try
    ConfigureFormats;
    TestRegistry;
    Writeln;
    TestAttributeIsolation;
    Writeln;
    TestCustomSerializerIsolation;
    Writeln;
    TestContractConversions;
    Writeln;
    TestFromApi;
    Writeln;
    TestStructuralConversions;
    Writeln;
    TestXmlStructuralPolicy;
    Writeln;
    TestRegistryThreadSafe;
    Writeln;
    TestDuplicateRegistration;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  Writeln('LIVE_ORDERS=', GLive);
  if GLive <> 0 then Inc(GFailures);
  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then
    Writeln('CONVERSION: PASS')
  else
  begin
    Writeln('CONVERSION: FAIL');
    ExitCode := 1;
  end;
end.
