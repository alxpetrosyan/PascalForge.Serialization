program GeneralAttributes;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ [SerializationName], [SerializationIgnore] and [SerializationEnum] -
  declared once, read by every format, by Dynamic and by the DataSet
  projection.

  What this program checks:
    * each format writes the general name, leaves the ignored member out
      and, where it writes enumerations as text, writes the general text -
      and reads every one of them back;
    * Protobuf, Avro and ASN.1 keep their wire and schema rules: their
      enumerations stay numbers or schema symbols, and Protobuf has no names
      to change;
    * a format's own attribute, registration or ignore beats the general
      one for that format and no other;
    * a DataSet attribute beats the general one. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.StrUtils,
  Data.DB, FireDAC.Comp.Client, FireDAC.Stan.Intf, FireDAC.Comp.DataSet,
  GeneralModels in 'GeneralModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization.Attributes in '..\..\src\PascalForge.Serialization.Attributes.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  PascalForge.Xml in '..\..\src\PascalForge.Xml.pas',
  PascalForge.Bson in '..\..\src\PascalForge.Bson.pas',
  PascalForge.Cbor in '..\..\src\PascalForge.Cbor.pas',
  PascalForge.MessagePack in '..\..\src\PascalForge.MessagePack.pas',
  PascalForge.Yaml in '..\..\src\PascalForge.Yaml.pas',
  PascalForge.Csv in '..\..\src\PascalForge.Csv.pas',
  PascalForge.Avro.Schema in '..\..\src\PascalForge.Avro.Schema.pas',
  PascalForge.Avro in '..\..\src\PascalForge.Avro.pas',
  PascalForge.Asn1 in '..\..\src\PascalForge.Asn1.pas',
  PascalForge.Protobuf in '..\..\src\PascalForge.Protobuf.pas',
  PascalForge.DataSet in '..\..\src\PascalForge.DataSet.pas';

var
  GFailures: Integer = 0;

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

function NewGeneral: TGeneral;
begin
  Result := TGeneral.Create;
  Result.Key := 7;
  Result.Secret := 'hidden';
  Result.Shade := Dark;
  Result.Stage := InProgress;
  Result.Plain := 'p';
end;

{ The general surface of a binary document, read back as a dynamic tree. }
function SurfaceOk(ATree: TDynamicValue; AEnumAsText: Boolean): Boolean;
begin
  Result := (ATree.Find('id') <> nil) and (ATree.Find('id').AsInt = 7) and
    (ATree.Find('Key') = nil) and (ATree.Find('Secret') = nil);
  if AEnumAsText then
    Result := Result and (ATree.Find('Shade').AsStr = 'd') and
      (ATree.Find('Stage').AsStr = 'in-progress');
  if not Result then Note(ATree.Describe);
end;

function BackOk(ABack: TGeneral): Boolean;
begin
  try
    Result := (ABack.Key = 7) and (ABack.Secret = '') and
      (ABack.Shade = Dark) and (ABack.Stage = InProgress) and
      (ABack.Plain = 'p');
  finally
    ABack.Free;
  end;
end;

procedure TestTextFormats;
var
  G: TGeneral;
  Text: string;
  Rows: TArray<TGeneral>;
  BackRows: TArray<TGeneral>;
  I: Integer;
begin
  Writeln;
  Writeln('--- the text formats ---');
  G := NewGeneral;
  try
    Text := TJsonSerializer.Serialize<TGeneral>(G);
    Note(Text);
    { Stage is "I", not "in-progress": JSON has its own mapping for TStage
      registered at startup, and a format's registration beats the type's
      general one - for JSON only (XML below still writes in-progress). }
    Check(ContainsStr(Text, '"id":7') and not ContainsStr(Text, 'hidden') and
      ContainsStr(Text, '"d"') and ContainsStr(Text, '"stage":"I"') and
      ContainsStr(Text, '"plain"'), 'GENERAL_JSON_WRITES');
    Check(BackOk(TJsonSerializer.Deserialize<TGeneral>(Text)), 'GENERAL_JSON_READS');

    Text := TXmlSerializer.Serialize<TGeneral>(G);
    Note(Text);
    Check(ContainsStr(Text, '<id>7</id>') and not ContainsStr(Text, 'hidden') and
      ContainsStr(Text, '>d<') and ContainsStr(Text, '>in-progress<'),
      'GENERAL_XML_WRITES');
    Check(BackOk(TXmlSerializer.Deserialize<TGeneral>(Text)), 'GENERAL_XML_READS');

    Text := TYamlSerializer.Serialize<TGeneral>(G);
    Check(ContainsStr(Text, 'id: 7') and not ContainsStr(Text, 'hidden') and
      ContainsStr(Text, 'in-progress'), 'GENERAL_YAML_WRITES');
    if not ContainsStr(Text, 'id: 7') then Note(Text);
    Check(BackOk(TYamlSerializer.Deserialize<TGeneral>(Text)), 'GENERAL_YAML_READS');

    Rows := [G];
    Text := TCsvSerializer.Serialize<TArray<TGeneral>>(Rows);
    Note(StringReplace(Text, sLineBreak, ' | ', [rfReplaceAll]));
    Check(StartsStr('id,', Text) and not ContainsStr(Text, 'hidden') and
      not ContainsStr(Text, 'Secret') and ContainsStr(Text, 'in-progress') and
      ContainsStr(Text, ',d,'), 'GENERAL_CSV_WRITES');
    BackRows := TCsvSerializer.Deserialize<TArray<TGeneral>>(Text);
    Check((Length(BackRows) = 1) and BackOk(BackRows[0]), 'GENERAL_CSV_READS');
    for I := 1 to High(BackRows) do BackRows[I].Free;
  finally
    G.Free;
  end;
end;

procedure TestBinaryFormats;
var
  G: TGeneral;
  Bytes: TBytes;
  Tree: TDynamicValue;
begin
  Writeln;
  Writeln('--- the binary formats ---');
  G := NewGeneral;
  try
    Bytes := TBsonSerializer.Serialize<TGeneral>(G);
    Tree := TBsonSerializer.ToDynamic(Bytes);
    try
      Check(SurfaceOk(Tree, True), 'GENERAL_BSON_WRITES');
    finally
      Tree.Free;
    end;
    Check(BackOk(TBsonSerializer.Deserialize<TGeneral>(Bytes)), 'GENERAL_BSON_READS');

    Bytes := TCborSerializer.Serialize<TGeneral>(G);
    Tree := TCborSerializer.ToDynamic(Bytes);
    try
      Check(SurfaceOk(Tree, True), 'GENERAL_CBOR_WRITES');
    finally
      Tree.Free;
    end;
    Check(BackOk(TCborSerializer.Deserialize<TGeneral>(Bytes)), 'GENERAL_CBOR_READS');

    Bytes := TMessagePackSerializer.Serialize<TGeneral>(G);
    Tree := TMessagePackSerializer.ToDynamic(Bytes);
    try
      Check(SurfaceOk(Tree, True), 'GENERAL_MESSAGEPACK_WRITES');
    finally
      Tree.Free;
    end;
    Check(BackOk(TMessagePackSerializer.Deserialize<TGeneral>(Bytes)),
      'GENERAL_MESSAGEPACK_READS');
  finally
    G.Free;
  end;
end;

procedure TestSchemaFormats;
var
  G: TGeneral;
  P, PBack: TGeneralProto;
  Bytes: TBytes;
  Schema: string;
begin
  Writeln;
  Writeln('--- the schema-driven formats keep their own rules ---');
  G := NewGeneral;
  try
    { Avro: the general name is the field name; the enumeration's symbols
      stay Avro symbols - the Delphi names - because a symbol is a schema
      identifier and 'in-progress' is not one. }
    Schema := TAvroSerializer.SchemaJsonFor<TGeneral>;
    Note(Schema);
    Check(ContainsStr(Schema, '"name":"id"') and not ContainsStr(Schema, 'Secret') and
      ContainsStr(Schema, '"InProgress"') and not ContainsStr(Schema, 'in-progress'),
      'GENERAL_AVRO_NAME_AND_IGNORE_SYMBOLS_UNCHANGED');
    Bytes := TAvroSerializer.Serialize<TGeneral>(G);
    Check(BackOk(TAvroSerializer.Deserialize<TGeneral>(Bytes)), 'GENERAL_AVRO_READS');

    { ASN.1: components are positional; the ignored member is not one. }
    Bytes := TAsn1Serializer.Serialize<TGeneral>(G);
    Check(BackOk(TAsn1Serializer.Deserialize<TGeneral>(Bytes)), 'GENERAL_ASN1_READS');
  finally
    G.Free;
  end;

  { Protobuf: the ignored member is not written even though it has a field
    number; the enumeration stays its number. }
  P := TGeneralProto.Create;
  try
    P.Key := 7;
    P.Secret := 'hidden';
    P.Stage := Done;
    Bytes := TProtobufSerializer.Serialize<TGeneralProto>(P);
    Check(not ContainsStr(TEncoding.ANSI.GetString(Bytes), 'hidden') and
      (Length(Bytes) = 4) and (Bytes[2] = $18) and (Bytes[3] = 2),
      'GENERAL_PROTOBUF_IGNORE_AND_NUMERIC_ENUM');
    PBack := TProtobufSerializer.Deserialize<TGeneralProto>(Bytes);
    try
      Check((PBack.Key = 7) and (PBack.Secret = '') and (PBack.Stage = Done),
        'GENERAL_PROTOBUF_READS');
    finally
      PBack.Free;
    end;
  finally
    P.Free;
  end;
end;

procedure TestPrecedence;
var
  P: TPrecedence;
  Text: string;
  Bytes: TBytes;
  Tree: TDynamicValue;
  Back: TPrecedence;
begin
  Writeln;
  Writeln('--- a format''s own configuration beats the general one ---');
  P := TPrecedence.Create;
  try
    P.A := 1;
    P.B := 2;
    P.C := 3;
    P.Stage := Done;

    Text := TJsonSerializer.Serialize<TPrecedence>(P);
    Note(Text);
    Check(ContainsStr(Text, '"json_attr":1') and ContainsStr(Text, '"json_rule":2') and
      not ContainsStr(Text, '"C"') and not ContainsStr(Text, ':3') and
      ContainsStr(Text, '"D"') and not ContainsStr(Text, 'general'),
      'GENERAL_PRECEDENCE_JSON');
    Back := TJsonSerializer.Deserialize<TPrecedence>(Text);
    try
      Check((Back.A = 1) and (Back.B = 2) and (Back.Stage = Done),
        'GENERAL_PRECEDENCE_JSON_READS');
    finally
      Back.Free;
    end;

    Text := TXmlSerializer.Serialize<TPrecedence>(P);
    Check(ContainsStr(Text, '<xml_attr>1</xml_attr>') and
      ContainsStr(Text, '<general_b>2</general_b>') and
      ContainsStr(Text, '<C>3</C>') and ContainsStr(Text, '>done<'),
      'GENERAL_PRECEDENCE_XML');
    if not ContainsStr(Text, '<xml_attr>') then Note(Text);

    Bytes := TBsonSerializer.Serialize<TPrecedence>(P);
    Tree := TBsonSerializer.ToDynamic(Bytes);
    try
      Check((Tree.Find('bson_attr').AsInt = 1) and (Tree.Find('general_b').AsInt = 2) and
        (Tree.Find('C').AsInt = 3) and (Tree.Find('Stage').AsStr = 'done'),
        'GENERAL_PRECEDENCE_BSON');
    finally
      Tree.Free;
    end;

    Bytes := TCborSerializer.Serialize<TPrecedence>(P);
    Tree := TCborSerializer.ToDynamic(Bytes);
    try
      Check((Tree.Find('cbor_attr').AsInt = 1) and (Tree.Find('general_b').AsInt = 2),
        'GENERAL_PRECEDENCE_CBOR');
    finally
      Tree.Free;
    end;

    Bytes := TMessagePackSerializer.Serialize<TPrecedence>(P);
    Tree := TMessagePackSerializer.ToDynamic(Bytes);
    try
      Check((Tree.Find('msgpack_attr').AsInt = 1) and
        (Tree.Find('general_b').AsInt = 2), 'GENERAL_PRECEDENCE_MESSAGEPACK');
    finally
      Tree.Free;
    end;

    Text := TYamlSerializer.Serialize<TPrecedence>(P);
    Check(ContainsStr(Text, 'yaml_attr: 1') and ContainsStr(Text, 'general_b: 2'),
      'GENERAL_PRECEDENCE_YAML');

    Tree := TDynamicSerializer.Serialize<TPrecedence>(P);
    try
      Check((Tree.Find('general').AsInt = 1) and (Tree.Find('general_b').AsInt = 2) and
        (Tree.Find('C').AsInt = 3) and (Tree.Find('Stage').AsStr = 'done'),
        'GENERAL_PRECEDENCE_DYNAMIC');
    finally
      Tree.Free;
    end;
  finally
    P.Free;
  end;
end;

procedure TestDataSet;
var
  Row: TPrecedenceRow;
  DS: TFDMemTable;
begin
  Writeln;
  Writeln('--- the DataSet projection ---');
  Row := TPrecedenceRow.Create;
  try
    Row.A := 1;
    Row.B := 2;
    Row.C := 3;
    DS := TDataSetSerializer.CreateFDMemTable<TPrecedenceRow>(Row);
    try
      Check((DS.FindField('DS_NAME') <> nil) and (DS.FindField('general') = nil) and
        (DS.FindField('general_b') <> nil) and (DS.FindField('C') = nil) and
        (DS.FieldByName('general_b').AsInteger = 2),
        'GENERAL_DATASET_NAMES_AND_IGNORE');
    finally
      DS.Free;
    end;
  finally
    Row.Free;
  end;
end;

{ [SerializationEnum] reached through nullables, sets, arrays and dictionary
  keys in every format that writes enumerations as text - and a format's own
  registration beating it there too: JSON has its own TStage mapping, CBOR
  its own TLevel mapping. }
procedure TestEnumContainers;
var
  B: TStageBox;
  Row: TStageRow;
  Rows, BackRows: TArray<TStageRow>;
  Text: string;
  Bytes: TBytes;
  Tree: TDynamicValue;
  I: Integer;

  function NewBox: TStageBox;
  begin
    Result := TStageBox.Create;
    Result.Direct := InProgress;
    Result.Maybe := Done;
    Result.Stages := [Pending, InProgress];
    Result.Arr := [InProgress];
    Result.Level := Hi;
    Result.Levels := [Hi];
    Result.ByStage.Add(InProgress, 7);
  end;

  function BoxBack(ABack: TStageBox): Boolean;
  var
    Bad: string;
  begin
    try
      Bad := '';
      if ABack.Direct <> InProgress then Bad := Bad + ' direct';
      if not ABack.Maybe.HasValue or (ABack.Maybe.Value <> Done) then Bad := Bad + ' nullable';
      if ABack.Stages <> [Pending, InProgress] then Bad := Bad + ' set';
      if (Length(ABack.Arr) <> 1) or (ABack.Arr[0] <> InProgress) then Bad := Bad + ' array';
      if (ABack.Level <> Hi) or (ABack.Levels <> [Hi]) then Bad := Bad + ' level';
      if not ABack.ByStage.ContainsKey(InProgress) then Bad := Bad + ' dictkey';
      Result := Bad = '';
      if not Result then Note('read back wrong:' + Bad);
    finally
      ABack.Free;
    end;
  end;

  { A set as its element texts, whichever way the format writes it: an
    array of them, or one comma-joined string. }
  function SetText(AValue: TDynamicValue): string;
  var
    J: Integer;
  begin
    if AValue.Kind = TDynamicKind.Str then Exit(AValue.AsStr);
    Result := '';
    for J := 0 to AValue.Count - 1 do
    begin
      if J > 0 then Result := Result + ',';
      Result := Result + AValue[J].AsStr;
    end;
  end;

  { The general texts in a dynamic view of a binary document. }
  function TreeOk(ATree: TDynamicValue; const AStage, ALevel: string): Boolean;
  begin
    Result := (ATree.Find('Direct').AsStr = AStage) and
      (SetText(ATree.Find('Stages')) = 'pending,' + AStage) and
      (ATree.Find('Arr')[0].AsStr = AStage) and
      (ATree.Find('ByStage').Find(AStage) <> nil) and
      (ATree.Find('Level').AsStr = ALevel) and
      (SetText(ATree.Find('Levels')) = ALevel);
    if not Result then Note(ATree.Describe);
  end;

begin
  Writeln;
  Writeln('--- [SerializationEnum] through containers, every text-enum format ---');
  B := NewBox;
  try
    { JSON: its own TStage mapping wins in every container; TLevel general. }
    Text := TJsonSerializer.Serialize<TStageBox>(B);
    Note(Text);
    Check(ContainsStr(Text, '"direct":"I"') and ContainsStr(Text, '"stages":"P,I"') and
      ContainsStr(Text, '"arr":["I"]') and ContainsStr(Text, '"I":7') and
      ContainsStr(Text, '"maybe":"D"') and ContainsStr(Text, '"levels":"high"') and
      not ContainsStr(Text, 'InProgress'), 'GENERAL_ENUM_CONTAINERS_JSON');
    Check(BoxBack(TJsonSerializer.Deserialize<TStageBox>(Text)),
      'GENERAL_ENUM_CONTAINERS_JSON_READS');

    Text := TXmlSerializer.Serialize<TStageBox>(B);
    Check(ContainsStr(Text, 'in-progress') and ContainsStr(Text, 'high') and
      not ContainsStr(Text, 'InProgress') and not ContainsStr(Text, '>Hi<'),
      'GENERAL_ENUM_CONTAINERS_XML');
    if not ContainsStr(Text, 'in-progress') or ContainsStr(Text, 'InProgress') then Note(Text);
    Check(BoxBack(TXmlSerializer.Deserialize<TStageBox>(Text)),
      'GENERAL_ENUM_CONTAINERS_XML_READS');

    Text := TYamlSerializer.Serialize<TStageBox>(B);
    Check(ContainsStr(Text, 'in-progress') and ContainsStr(Text, 'high') and
      not ContainsStr(Text, 'InProgress') and not ContainsStr(Text, ' Hi'),
      'GENERAL_ENUM_CONTAINERS_YAML');
    if ContainsStr(Text, 'InProgress') then Note(Text);
    Check(BoxBack(TYamlSerializer.Deserialize<TStageBox>(Text)),
      'GENERAL_ENUM_CONTAINERS_YAML_READS');

    Bytes := TBsonSerializer.Serialize<TStageBox>(B);
    Tree := TBsonSerializer.ToDynamic(Bytes);
    try
      Check(TreeOk(Tree, 'in-progress', 'high'), 'GENERAL_ENUM_CONTAINERS_BSON');
    finally
      Tree.Free;
    end;
    Check(BoxBack(TBsonSerializer.Deserialize<TStageBox>(Bytes)),
      'GENERAL_ENUM_CONTAINERS_BSON_READS');

    Bytes := TMessagePackSerializer.Serialize<TStageBox>(B);
    Tree := TMessagePackSerializer.ToDynamic(Bytes);
    try
      Check(TreeOk(Tree, 'in-progress', 'high'), 'GENERAL_ENUM_CONTAINERS_MESSAGEPACK');
    finally
      Tree.Free;
    end;
    Check(BoxBack(TMessagePackSerializer.Deserialize<TStageBox>(Bytes)),
      'GENERAL_ENUM_CONTAINERS_MESSAGEPACK_READS');

    { CBOR: its own TLevel mapping wins; TStage general. }
    Bytes := TCborSerializer.Serialize<TStageBox>(B);
    Tree := TCborSerializer.ToDynamic(Bytes);
    try
      Check(TreeOk(Tree, 'in-progress', 'H'), 'GENERAL_ENUM_CONTAINERS_CBOR');
    finally
      Tree.Free;
    end;
    Check(BoxBack(TCborSerializer.Deserialize<TStageBox>(Bytes)),
      'GENERAL_ENUM_CONTAINERS_CBOR_READS');
  finally
    B.Free;
  end;

  Row := TStageRow.Create;
  try
    Row.Direct := InProgress;
    Row.Maybe := Done;
    Row.Stages := [Pending, InProgress];
    Row.Level := Hi;
    Rows := [Row];
    Text := TCsvSerializer.Serialize<TArray<TStageRow>>(Rows);
    Note(StringReplace(Text, sLineBreak, ' | ', [rfReplaceAll]));
    Check(ContainsStr(Text, 'in-progress,done,"pending,in-progress",high') and
      not ContainsStr(Text, 'InProgress'), 'GENERAL_ENUM_CONTAINERS_CSV');
    BackRows := TCsvSerializer.Deserialize<TArray<TStageRow>>(Text);
    try
      Check((Length(BackRows) = 1) and (BackRows[0].Direct = InProgress) and
        (BackRows[0].Maybe.Value = Done) and
        (BackRows[0].Stages = [Pending, InProgress]) and (BackRows[0].Level = Hi),
        'GENERAL_ENUM_CONTAINERS_CSV_READS');
    finally
      for I := 0 to High(BackRows) do BackRows[I].Free;
    end;
  finally
    Row.Free;
  end;
end;

begin
  try
    { Format-specific configuration, at startup, before the first use
      freezes it. }
    TJsonSerializer.RegisterFieldOverride<TPrecedence>('B',
      TJsonFieldOverride.Rename('json_rule'));
    TJsonSerializer.RegisterEnumMapping<TStage>(['P', 'I', 'D']);
    TCborSerializer.RegisterEnumMapping<TLevel>(['L', 'H']);

    TestTextFormats;
    TestBinaryFormats;
    TestSchemaFormats;
    TestPrecedence;
    TestDataSet;
    TestEnumContainers;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then
    Writeln('GENERAL_ATTRIBUTES: PASS')
  else
  begin
    Writeln('GENERAL_ATTRIBUTES: FAIL');
    ExitCode := 1;
  end;
end.
