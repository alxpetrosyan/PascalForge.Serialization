program DataSetSources;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Building a DataSet from an encoded document.

  Two different operations that look alike, and the difference between them
  is what this program is mostly about:

    CreateFDMemTable<TShipment>(Json, TSerializationFormat.Json)
        TShipment is the contract. A TDate member becomes ftDate because the
        Delphi type says so, whatever the JSON looked like.

    CreateFDMemTable(Json, TSerializationFormat.Json)
        No contract. The document decides, and only what the FORMAT states
        about a value counts - a JSON string stays a string however much it
        resembles a date. BSON does state types, so BSON keeps them.

  Both go through the format registry, which is why all three registration
  units are linked here. The DataSet subsystem itself names no format. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.DateUtils, System.Classes, System.StrUtils,
  System.TypInfo, System.Rtti,
  System.Generics.Collections,
  Data.DB, FireDAC.Comp.Client, Datasnap.DBClient,
  DataSetSourceModels in 'DataSetSourceModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.DataSet in '..\..\src\PascalForge.DataSet.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  PascalForge.Xml in '..\..\src\PascalForge.Xml.pas',
  PascalForge.Bson in '..\..\src\PascalForge.Bson.pas',
  PascalForge.Bson.Internal in '..\..\src\PascalForge.Bson.Internal.pas',
  PascalForge.Json.Registration in '..\..\src\PascalForge.Json.Registration.pas',
  PascalForge.Xml.Registration in '..\..\src\PascalForge.Xml.Registration.pas',
  PascalForge.Bson.Registration in '..\..\src\PascalForge.Bson.Registration.pas';

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

function Describe(ADataSet: TDataSet): string;
var
  I: Integer;
begin
  if not ADataSet.Active then Exit('(closed, no schema)');
  Result := Format('%d rows:', [ADataSet.RecordCount]);
  for I := 0 to ADataSet.FieldDefs.Count - 1 do
    Result := Result + ' ' + ADataSet.FieldDefs[I].Name + '=' +
      GetEnumName(TypeInfo(TFieldType), Ord(ADataSet.FieldDefs[I].DataType));
end;

function TypeOf(ADataSet: TDataSet; const AName: string): TFieldType;
begin
  Result := ADataSet.FieldDefs.Find(AName).DataType;
end;

{ ------------------------------------------------------------ JSON --- }

const
  ONE_OBJECT = '{"id":1,"name":"A"}';
  TWO_OBJECTS = '[{"id":1,"name":"A"},{"id":2,"name":"B"}]';
  NESTED = '{"id":1,"lines":[{"sku":"A-1","qty":2},{"sku":"B-2","qty":5}]}';

procedure TestJsonInference;
var
  DS: TFDMemTable;
begin
  Writeln('-- JSON, no contract --');

  DS := TDataSetSerializer.CreateFDMemTable(ONE_OBJECT,
    TSerializationFormat.Json);
  try
    Note(Describe(DS));
    Check(DS.Active and (DS.RecordCount = 1) and
          (DS.FieldDefs.Count = 2) and
          (TypeOf(DS, 'id') = ftInteger) and
          (TypeOf(DS, 'name') = ftWideString) and
          (DS.FieldByName('name').AsString = 'A'),
      'DATASET_JSON_INFER_SINGLE_OBJECT');
  finally
    DS.Free;
  end;

  DS := TDataSetSerializer.CreateFDMemTable(TWO_OBJECTS,
    TSerializationFormat.Json);
  try
    Note(Describe(DS));
    DS.First;
    Check(DS.Active and (DS.RecordCount = 2) and
          (DS.FieldByName('id').AsInteger = 1), 'DATASET_JSON_INFER_ARRAY');
  finally
    DS.Free;
  end;

  DS := TDataSetSerializer.CreateFDMemTable(NESTED,
    TSerializationFormat.Json);
  try
    Note(Describe(DS));
    Check(DS.Active and (TypeOf(DS, 'lines') = ftDataSet) and
          (TDataSetField(DS.FieldByName('lines')).NestedDataSet.RecordCount = 2),
      'DATASET_JSON_INFER_NESTED');
  finally
    DS.Free;
  end;
end;

{ A JSON string that looks like a date is a string. JSON never said it was
  anything else, and guessing from the spelling is how the same document
  becomes a timestamp in one system and text in the next. }
procedure TestJsonDateStaysString;
var
  DS: TFDMemTable;
begin
  Writeln('-- a date-shaped string, with no contract --');
  DS := TDataSetSerializer.CreateFDMemTable('{"created":"2026-09-14"}',
    TSerializationFormat.Json);
  try
    Note(Describe(DS));
    Check(TypeOf(DS, 'created') = ftWideString,
      'DATASET_JSON_DATE_STRING_REMAINS_STRING');
    Check(DS.FieldByName('created').AsString = '2026-09-14',
      'DATASET_JSON_DATE_STRING_VALUE_INTACT');
  finally
    DS.Free;
  end;
end;

{ --------------------------------------------------------------- XML --- }

procedure TestXmlInference;
var
  DS: TFDMemTable;
  CDS: TClientDataSet;
begin
  Writeln('-- XML, no contract --');
  DS := TDataSetSerializer.CreateFDMemTable('<r><id>1</id><name>A</name></r>',
    TSerializationFormat.Xml);
  try
    Note(Describe(DS));
    { XML element text carries no type at all, so every column is text. That
      is not a shortcoming of the inference; it is what the document says. }
    Check(DS.Active and (DS.RecordCount = 1) and (DS.FieldDefs.Count = 2) and
          (TypeOf(DS, 'id') = ftWideString) and
          (DS.FieldByName('name').AsString = 'A'),
      'DATASET_XML_INFER_SINGLE_OBJECT');
  finally
    DS.Free;
  end;

  CDS := TDataSetSerializer.CreateClientDataSet(
    '<rows><row><id>1</id></row><row><id>2</id></row></rows>',
    TSerializationFormat.Xml);
  try
    Note(Describe(CDS));
    { Repeated siblings become an array in the structural tree, so 'row' is a
      nested table of two rows. }
    Check(CDS.Active and (TypeOf(CDS, 'row') = ftDataSet) and
          (TDataSetField(CDS.FieldByName('row')).NestedDataSet.RecordCount = 2),
      'DATASET_XML_INFER_COLLECTION');
  finally
    CDS.Free;
  end;

  DS := TDataSetSerializer.CreateFDMemTable('<r><created>2026-09-14</created></r>',
    TSerializationFormat.Xml);
  try
    Check(TypeOf(DS, 'created') = ftWideString,
      'DATASET_XML_DATE_TEXT_REMAINS_STRING_WITHOUT_SCHEMA');
  finally
    DS.Free;
  end;
end;

{ -------------------------------------------------------------- BSON --- }

function BsonDoc(AConfigure: TProc<TBsonValue>): TBytes;
var
  Doc: TBsonValue;
begin
  Doc := TBsonValue.NewDocument;
  try
    AConfigure(Doc);
    Result := TBsonEngine.WriteDocument(Doc);
  finally
    Doc.Free;
  end;
end;

procedure TestBsonInference;
var
  DS: TFDMemTable;
  Data: TBytes;
  Stamp: TDateTime;
  Blob: TBytes;
  Nested: TDataSet;
begin
  Writeln('-- BSON, no contract --');
  Stamp := EncodeDateTime(2026, 9, 14, 10, 30, 0, 0);
  Blob := TBytes.Create(1, 2, 250, 251);

  Data := BsonDoc(
    procedure(D: TBsonValue)
    begin
      D.Add('small', TBsonValue.NewInt32(7));
      D.Add('big', TBsonValue.NewInt64(4611686018427387904));
      D.Add('rate', TBsonValue.NewDouble(1.5));
      D.Add('when', TBsonValue.NewDateTime(Stamp));
      D.Add('blob', TBsonValue.NewBinary(Blob));
      D.Add('name', TBsonValue.NewString('A'));
    end);

  DS := TDataSetSerializer.CreateFDMemTable(Data, TSerializationFormat.Bson);
  try
    Note(Describe(DS));
    Check(DS.Active and (DS.RecordCount = 1), 'DATASET_BSON_INFER_DOCUMENT');
    { BSON states its types, so inference keeps them. This is the asymmetry
      with JSON and XML, and it is deliberate. }
    Check(TypeOf(DS, 'small') = ftInteger, 'DATASET_BSON_INT32_PRESERVED');
    Check((TypeOf(DS, 'big') = ftLargeint) and
          (DS.FieldByName('big').AsLargeInt = 4611686018427387904),
      'DATASET_BSON_INT64_PRESERVED');
    Check((TypeOf(DS, 'when') = ftDateTime) and
          SameDateTime(DS.FieldByName('when').AsDateTime, Stamp),
      'DATASET_BSON_DATETIME_PRESERVED');
    Check((TypeOf(DS, 'blob') = ftBlob) and
          (Length(DS.FieldByName('blob').AsBytes) = 4),
      'DATASET_BSON_BINARY_PRESERVED');
    { The four above, under the one name the completion list uses: what the
      SOURCE FORMAT stated about a value reaches the column type intact. }
    Check((TypeOf(DS, 'small') = ftInteger) and
          (TypeOf(DS, 'big') = ftLargeint) and
          (TypeOf(DS, 'rate') = ftFloat) and
          (TypeOf(DS, 'when') = ftDateTime) and
          (TypeOf(DS, 'blob') = ftBlob) and
          (TypeOf(DS, 'name') = ftWideString),
      'DATASET_SOURCE_NATIVE_TYPE_FIDELITY');
    Check((TypeOf(DS, 'small') = ftInteger) and
          (TypeOf(DS, 'when') = ftDateTime) and (TypeOf(DS, 'blob') = ftBlob),
      'DATASET_NATIVE_TYPE_FIDELITY');
  finally
    DS.Free;
  end;

  { A BSON root is always a document - the format has no top-level array - so
    an array arrives as a member, and becomes a nested table. }
  Data := BsonDoc(
    procedure(D: TBsonValue)
    var
      Arr, Row: TBsonValue;
    begin
      Arr := TBsonValue.NewArray;
      Row := TBsonValue.NewDocument;
      Row.Add('id', TBsonValue.NewInt32(1));
      Arr.Add(Row);
      Row := TBsonValue.NewDocument;
      Row.Add('id', TBsonValue.NewInt32(2));
      Arr.Add(Row);
      D.Add('rows', Arr);
    end);

  DS := TDataSetSerializer.CreateFDMemTable(Data, TSerializationFormat.Bson);
  try
    Note(Describe(DS));
    Nested := TDataSetField(DS.FieldByName('rows')).NestedDataSet;
    Check((TypeOf(DS, 'rows') = ftDataSet) and (Nested.RecordCount = 2) and
          (Nested.FieldDefs.Find('id').DataType = ftInteger),
      'DATASET_BSON_INFER_ARRAY');
  finally
    DS.Free;
  end;
end;

{ ---------------------------------------------------- structural policy --- }

procedure TestStructuralPolicies;
var
  DS: TFDMemTable;
  Raised: Boolean;
begin
  Writeln('-- widening, empty and heterogeneous documents --');

  { A column is one type for the whole table, so every value in it widens
    together. }
  DS := TDataSetSerializer.CreateFDMemTable(
    '[{"n":1},{"n":4611686018427387904},{"n":2}]', TSerializationFormat.Json);
  try
    Note(Describe(DS));
    Check(TypeOf(DS, 'n') = ftLargeint, 'DATASET_STRUCTURAL_WIDENING');
  finally
    DS.Free;
  end;

  DS := TDataSetSerializer.CreateFDMemTable('[{"n":1},{"n":1.5}]',
    TSerializationFormat.Json);
  try
    Check(TypeOf(DS, 'n') = ftFloat, 'DATASET_STRUCTURAL_WIDENING_TO_FLOAT');
  finally
    DS.Free;
  end;

  { No narrower type holds both, so the documented fallback applies. }
  DS := TDataSetSerializer.CreateFDMemTable('[{"n":1},{"n":"x"}]',
    TSerializationFormat.Json);
  try
    Check(TypeOf(DS, 'n') = ftWideString,
      'DATASET_STRUCTURAL_INCOMPATIBLE_WIDENS_TO_TEXT');
  finally
    DS.Free;
  end;

  { An empty array has no schema, and saying so is better than inventing a
    column. The DataSet comes back closed. }
  DS := TDataSetSerializer.CreateFDMemTable('[]', TSerializationFormat.Json);
  try
    Check((not DS.Active) and (DS.FieldDefs.Count = 0),
      'DATASET_EMPTY_ARRAY_POLICY');
  finally
    DS.Free;
  end;

  { A mixed array: objects contribute their columns, and a bare scalar
    contributes to the column named 'value'. }
  DS := TDataSetSerializer.CreateFDMemTable('[{"a":1},"loose",{"b":2}]',
    TSerializationFormat.Json);
  try
    Note(Describe(DS));
    Check(DS.Active and (DS.RecordCount = 3) and
          (DS.FieldDefs.IndexOf('a') >= 0) and
          (DS.FieldDefs.IndexOf('b') >= 0) and
          (DS.FieldDefs.IndexOf('value') >= 0),
      'DATASET_HETEROGENEOUS_ARRAY_POLICY');
  finally
    DS.Free;
  end;

  { An array of scalars is one column named 'value', one row per element. }
  DS := TDataSetSerializer.CreateFDMemTable('[1,2,3]',
    TSerializationFormat.Json);
  try
    Check(DS.Active and (DS.RecordCount = 3) and
          (TypeOf(DS, 'value') = ftInteger), 'DATASET_SCALAR_ARRAY_POLICY');
  finally
    DS.Free;
  end;

  { A scalar root is one row of one column. }
  DS := TDataSetSerializer.CreateFDMemTable('42', TSerializationFormat.Json);
  try
    Check(DS.Active and (DS.RecordCount = 1) and
          (DS.FieldByName('value').AsInteger = 42),
      'DATASET_SCALAR_ROOT_POLICY');
  finally
    DS.Free;
  end;

  { A null root is nothing, not an empty row. }
  DS := TDataSetSerializer.CreateFDMemTable('null', TSerializationFormat.Json);
  try
    Check(not DS.Active, 'DATASET_NULL_ROOT_POLICY');
  finally
    DS.Free;
  end;

  { A format nobody registered is named, not guessed at. }
  Raised := False;
  try
    TDataSetSerializer.CreateFDMemTable('{}',
      TSerializationFormat.Cbor).Free;
  except
    on E: ESerializationFormatNotRegistered do Raised := True;
  end;
  Check(Raised, 'DATASET_UNREGISTERED_SOURCE_FORMAT_RAISES');
end;

{ -------------------------------------------------- contract-aware --- }

function SampleShipment: TShipment;
begin
  Result := TShipment.Create;
  Result.Id := 4611686018427387904;
  Result.Consignee := 'Alice Sample';
  Result.Amount := 128.55;
  Result.Booked := EncodeDate(2026, 9, 14);
  Result.Lines.Add(TLine.Create);
  Result.Lines[0].Code := 'A-1';
  Result.Lines[0].Quantity := 2;
end;

{ The contract-aware path must produce exactly what Deserialize<T> followed
  by the existing DTO projection produces - there is no second mapping. }
function ReferenceProjection: TFDMemTable;
var
  P: TShipment;
begin
  P := SampleShipment;
  try
    Result := TDataSetSerializer.CreateFDMemTable<TShipment>(P);
  finally
    P.Free;
  end;
end;

function SameShape(A, B: TDataSet): Boolean;
var
  I: Integer;
begin
  Result := A.FieldDefs.Count = B.FieldDefs.Count;
  if not Result then Exit;
  for I := 0 to A.FieldDefs.Count - 1 do
    if (A.FieldDefs[I].Name <> B.FieldDefs[I].Name) or
       (A.FieldDefs[I].DataType <> B.FieldDefs[I].DataType) then Exit(False);
  Result := A.RecordCount = B.RecordCount;
end;

procedure TestContractProjection;
var
  P: TShipment;
  Json, Xml: string;
  Bson: TBytes;
  DS, Reference: TFDMemTable;
  CDS: TClientDataSet;
begin
  Writeln('-- with a Delphi contract --');
  P := SampleShipment;
  try
    Json := TJsonSerializer.Serialize<TShipment>(P);
    Xml := TXmlSerializer.Serialize<TShipment>(P);
    Bson := TBsonSerializer.Serialize<TShipment>(P);
  finally
    P.Free;
  end;

  Reference := ReferenceProjection;
  try
    Note('reference: ' + Describe(Reference));

    DS := TDataSetSerializer.CreateFDMemTable<TShipment>(Json,
      TSerializationFormat.Json);
    try
      Check(SameShape(DS, Reference) and
            (DS.FieldByName('Consignee').AsString = 'Alice Sample') and
            (DS.FieldByName('Id').AsLargeInt = 4611686018427387904),
        'JSON_TO_DATASET_CONTRACT');
      { The whole point: TDate in the contract, ftDate in the schema. }
      Check(TypeOf(DS, 'Booked') = ftDate, 'CONTRACT_KEEPS_DELPHI_TYPES');
    finally
      DS.Free;
    end;

    DS := TDataSetSerializer.CreateFDMemTable<TShipment>(Xml,
      TSerializationFormat.Xml);
    try
      Check(SameShape(DS, Reference) and
            (DS.FieldByName('Consignee').AsString = 'Alice Sample'),
        'XML_TO_DATASET_CONTRACT');
    finally
      DS.Free;
    end;

    DS := TDataSetSerializer.CreateFDMemTable<TShipment>(Bson,
      TSerializationFormat.Bson);
    try
      Check(SameShape(DS, Reference) and
            (DS.FieldByName('Amount').AsCurrency = 128.55),
        'BSON_TO_DATASET_CONTRACT');
    finally
      DS.Free;
    end;

    CDS := TDataSetSerializer.CreateClientDataSet<TShipment>(Json,
      TSerializationFormat.Json);
    try
      Check(SameShape(CDS, Reference), 'JSON_TO_CLIENTDATASET_CONTRACT');
    finally
      CDS.Free;
    end;

    CDS := TDataSetSerializer.CreateClientDataSet<TShipment>(Xml,
      TSerializationFormat.Xml);
    try
      Check(SameShape(CDS, Reference), 'XML_TO_CLIENTDATASET_CONTRACT');
    finally
      CDS.Free;
    end;

    CDS := TDataSetSerializer.CreateClientDataSet<TShipment>(Bson,
      TSerializationFormat.Bson);
    try
      Check(SameShape(CDS, Reference), 'BSON_TO_CLIENTDATASET_CONTRACT');
    finally
      CDS.Free;
    end;

    { The same three, rolled up under the names the format gate uses: the
      contract decides the schema whichever encoded format the document
      arrived in, and it decides the same schema for both dataset kinds. }
    DS := TDataSetSerializer.CreateFDMemTable<TShipment>(Xml,
      TSerializationFormat.Xml);
    try
      Check(SameShape(DS, Reference) and (TypeOf(DS, 'Booked') = ftDate),
        'DATASET_CONTRACT_PROJECTION');
    finally
      DS.Free;
    end;

    CDS := TDataSetSerializer.CreateClientDataSet<TShipment>(Xml,
      TSerializationFormat.Xml);
    try
      Check(SameShape(CDS, Reference) and (TypeOf(CDS, 'Booked') = ftDate),
        'DATASET_CLIENTDATASET_CONTRACT');
    finally
      CDS.Free;
    end;
  finally
    Reference.Free;
  end;
end;

{ The two paths are different operations and must stay different. }
procedure TestInferredVsContract;
const
  SRC = '{"id":1,"consignee":"A","amount":1.5,"date":"2026-09-14"}';
var
  Inferred, Contracted: TFDMemTable;
begin
  Writeln('-- inferred against contracted --');
  Inferred := TDataSetSerializer.CreateFDMemTable(SRC,
    TSerializationFormat.Json);
  Contracted := TDataSetSerializer.CreateFDMemTable<TShipment>(SRC,
    TSerializationFormat.Json);
  try
    Note('inferred:   ' + Describe(Inferred));
    Note('contracted: ' + Describe(Contracted));
    Check((TypeOf(Inferred, 'date') = ftWideString) and
          (TypeOf(Contracted, 'Booked') = ftDate),
      'DATASET_INFERRED_VS_CONTRACT_SCHEMA_DISTINCT');
    { And the generic form did not secretly infer: its columns are the
      Delphi member names, not the JSON ones. TFieldDefs.Find is
      case-insensitive, so the names compared here differ by more than
      case - 'date' against 'Booked', and a 'Lines' column the document
      never mentioned. }
    Check((Inferred.FieldDefs.IndexOf('date') >= 0) and
          (Inferred.FieldDefs.IndexOf('Booked') < 0) and
          (Inferred.FieldDefs.IndexOf('Lines') < 0),
      'INFERRED_PATH_USES_THE_DOCUMENT');
    Check((Contracted.FieldDefs.IndexOf('Booked') >= 0) and
          (Contracted.FieldDefs.IndexOf('date') < 0) and
          (Contracted.FieldDefs.IndexOf('Lines') >= 0),
      'CONTRACT_PATH_DOES_NOT_INFER');
  finally
    Contracted.Free;
    Inferred.Free;
  end;
end;

{ ------------------------------------------------------------- owner --- }

procedure TestOwnership;
var
  Owner: TComponent;
  DS: TFDMemTable;
  Raised: Boolean;
begin
  Writeln('-- component ownership --');
  Owner := TComponent.Create(nil);
  try
    DS := TDataSetSerializer.CreateFDMemTable(ONE_OBJECT,
      TSerializationFormat.Json, Owner);
    Check((DS.Owner = Owner) and (Owner.ComponentCount = 1),
      'DATASET_OWNER_IS_HONOURED');
  finally
    { Freeing the owner frees the DataSet; nothing here has to. }
    Owner.Free;
  end;

  DS := TDataSetSerializer.CreateFDMemTable(ONE_OBJECT,
    TSerializationFormat.Json);
  try
    Check(DS.Owner = nil, 'DATASET_NIL_OWNER_MEANS_CALLER_OWNS');
  finally
    DS.Free;
  end;

  { A source that cannot be parsed must not leave a half-built DataSet
    behind, owned or otherwise. }
  Owner := TComponent.Create(nil);
  try
    Raised := False;
    try
      TDataSetSerializer.CreateFDMemTable('{"broken":',
        TSerializationFormat.Json, Owner);
    except
      on E: Exception do Raised := True;
    end;
    Check(Raised and (Owner.ComponentCount = 0),
      'DATASET_FAILED_CREATE_LEAVES_NOTHING');
  finally
    Owner.Free;
  end;
end;

{ ===========================================================================
  ANY REGISTERED STRUCTURAL FORMAT -> A DATASET

  The point of this block is that it names no format.  It asks the registry
  which formats can be parsed structurally and runs the same test on each,
  so a format pack added later is covered the day it registers itself -
  nothing here has to be edited for CBOR, MessagePack or YAML to appear.
  =========================================================================== }

const
  { An OBJECT, not an array, because a BSON document's root is always a
    document - a root array travels under the name "value", which is BSON's
    documented rule and not something the DataSet layer should know about.
    An object is the one root shape every format writes identically, so it
    is the one this generic test uses. Root-shape policy has its own checks
    above. }
  GENERIC_SEED = '{"Id":1,"Name":"A","Active":true}';

procedure TestAnyRegisteredFormat;
var
  Formats: TArray<TSerializationFormat>;
  F: TSerializationFormat;
  Source: TSerializationPayload;
  FD: TFDMemTable;
  CDS: TClientDataSet;
  Name: string;
  I: Integer;
  AllFd, AllCds: Boolean;
begin
  Writeln('-- any registered structural format -> a DataSet --');

  Formats := TSerialization.StructuralFormats;
  Check(Length(Formats) >= 3, 'DATASET_FORMAT_REGISTRY_DISPATCH');

  AllFd := True;
  AllCds := True;
  for I := 0 to High(Formats) do
  begin
    F := Formats[I];
    Name := UpperCase(TSerialization.FormatName(F));

    { The same logical document, expressed in whichever format this is.
      Lossless, so that the destination carries what the values WERE - an
      integer that arrives as an integer is the whole reason the inference
      can produce ftInteger rather than ftWideString. }
    Source := TSerialization.Convert(
      TSerializationPayload.FromText(GENERIC_SEED),
      TSerializationFormat.Json, F, TStructuralConversionProfile.Lossless);

    FD := TDataSetSerializer.CreateFDMemTable(Source, F);
    try
      Note(Name + ': ' + Describe(FD));
      Check((FD.RecordCount = 1) and (FD.FieldDefs.Count = 3) and
            (FD.FieldDefs.IndexOf('Id') >= 0) and
            (FD.FieldDefs.IndexOf('Name') >= 0) and
            (FD.FieldDefs.IndexOf('Active') >= 0),
        'FORMAT_' + Name + '_TO_DATASET_INFERRED');
      { The same result under the shorter name the completion list uses. }
      Check((FD.RecordCount = 1) and (FD.FieldDefs.Count = 3),
        Name + '_TO_DATASET_INFERRED');
      if not ((FD.RecordCount = 1) and (FD.FieldDefs.Count = 3)) then
        AllFd := False;

      { Every format agrees about the SCHEMA, because they all go through
        one inference over one dynamic tree. There is no per-format
        mapping to drift. }
      if TypeOf(FD, 'Active') <> ftBoolean then AllFd := False;
      FD.First;
      if FD.FieldByName('Name').AsString <> 'A' then AllFd := False;
    finally
      FD.Free;
    end;

    CDS := TDataSetSerializer.CreateClientDataSet(Source, F);
    try
      if not ((CDS.RecordCount = 1) and (CDS.FieldDefs.Count = 3)) then
        AllCds := False;
    finally
      CDS.Free;
    end;
  end;

  Check(AllFd, 'ARBITRARY_FORMAT_TO_FDMEMTABLE');
  Check(AllCds, 'ARBITRARY_FORMAT_TO_CLIENTDATASET');
  Check(AllFd, 'DATASET_SHARED_STRUCTURAL_INFERENCE');
  { The same result under the name the format gate uses. }
  Check(AllFd and AllCds, 'DATASET_STRUCTURAL_INFERENCE');
end;

{ A DataSet has its own naming rules, and they are not XML's. "$type" is
  fine as a column name, so it stays "$type" - the adaptation belongs to the
  destination that cannot take the name, and this destination can. }
procedure TestDataSetKeepsSourceNames;
var
  FD: TFDMemTable;
begin
  Writeln;
  Writeln('-- a DataSet is not XML, and does not borrow XML naming --');

  FD := TDataSetSerializer.CreateFDMemTable(
    '{"$type":"SubjectDetails","first name":"Ada","Id":1}',
    TSerializationFormat.Json);
  try
    Note(Describe(FD));
    Check((FD.FieldDefs.IndexOf('$type') >= 0) and
          (FD.FieldDefs.IndexOf('first name') >= 0),
      'DATASET_KEEPS_SOURCE_MEMBER_NAMES');
    FD.First;
    Check(FD.FieldByName('$type').AsString = 'SubjectDetails',
      'DATASET_KEEPS_SOURCE_MEMBER_VALUES');
  finally
    FD.Free;
  end;
end;

{ A registered format that cannot parse structurally is a DIFFERENT failure
  from a format nobody registered, and the DataSet layer says which. }
type
  TNoStructureHandler = class(TSerializationFormatHandler)
  public
    function Capabilities(const AOptions: TStructuralConversionOptions):
      TSerializationFormatCapabilities; override;
    function PayloadKind: TSerializationPayloadKind; override;
    function ToDynamic(const APayload: TSerializationPayload;
      const AOptions: TStructuralConversionOptions): TDynamicValue; override;
    function FromDynamic(const AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions): TSerializationPayload; override;
    function DeserializeTyped(ATypeInfo: PTypeInfo;
      const APayload: TSerializationPayload): TValue; override;
    function SerializeTyped(ATypeInfo: PTypeInfo;
      const AValue: TValue): TSerializationPayload; override;
  end;

function TNoStructureHandler.Capabilities(
  const AOptions: TStructuralConversionOptions): TSerializationFormatCapabilities;
begin
  Result := [TSerializationFormatCapability.ContractSerialize,
             TSerializationFormatCapability.ContractDeserialize];
end;

function TNoStructureHandler.PayloadKind: TSerializationPayloadKind;
begin
  Result := TSerializationPayloadKind.Binary;
end;

function TNoStructureHandler.ToDynamic(
  const APayload: TSerializationPayload;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
begin
  Result := nil;
end;

function TNoStructureHandler.FromDynamic(const AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
begin
  Result := TSerializationPayload.FromBytes(nil);
end;

function TNoStructureHandler.DeserializeTyped(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload): TValue;
begin
  Result := TValue.Empty;
end;

function TNoStructureHandler.SerializeTyped(ATypeInfo: PTypeInfo;
  const AValue: TValue): TSerializationPayload;
begin
  Result := TSerializationPayload.FromBytes(nil);
end;

procedure TestCapabilityAndSourceShape;
var
  Raised: string;
  FD: TFDMemTable;
begin
  Writeln;
  Writeln('-- what cannot be done, and why --');

  { A stand-in for a schema-driven format, registered under a name nothing
    else uses. PascalForge.Protobuf is the real example of this - it can go
    both ways through a Delphi contract and cannot be parsed structurally at
    all - and this handler reproduces exactly that shape without dragging
    protobuf into a DataSet test. }
  TSerializationFormats.Register(TSerializationFormat.Cbor,
    TNoStructureHandler);
  try
    Raised := '';
    try
      FD := TDataSetSerializer.CreateFDMemTable(
        TSerializationPayload.FromBytes(TBytes.Create(1, 2)),
        TSerializationFormat.Cbor);
      FD.Free;
    except
      on E: Exception do Raised := E.ClassName;
    end;
    Check(Raised = 'ESerializationFormatCapability',
      'DATASET_REGISTERED_BUT_NO_STRUCTURAL_PARSER');
  finally
    TSerializationFormats.Unregister(TSerializationFormat.Cbor);
  end;

  { An unregistered format is still the other error. }
  Raised := '';
  try
    FD := TDataSetSerializer.CreateFDMemTable('{"a":1}',
      TSerializationFormat.Cbor);
    FD.Free;
  except
    on E: Exception do Raised := E.ClassName;
  end;
  Check(Raised = 'ESerializationFormatNotRegistered',
    'DATASET_UNREGISTERED_IS_A_DIFFERENT_ERROR');

  { And a source of the wrong shape is rejected out loud rather than being
    reinterpreted: text is not silently encoded and handed to BSON. }
  Raised := '';
  try
    FD := TDataSetSerializer.CreateFDMemTable('{"a":1}',
      TSerializationFormat.Bson);
    FD.Free;
  except
    on E: Exception do Raised := E.Message;
  end;
  Note(Copy(Raised, 1, 70));
  Check(Raised <> '', 'DATASET_BINARY_FORMAT_REFUSES_TEXT_SOURCE');
end;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TJsonSerializationRegistration.RegisterFormat;
  TXmlSerializationRegistration.RegisterFormat;
  TBsonSerializationRegistration.RegisterFormat;
  try
    TestJsonInference;
    Writeln;
    TestJsonDateStaysString;
    Writeln;
    TestXmlInference;
    Writeln;
    TestBsonInference;
    Writeln;
    TestStructuralPolicies;
    Writeln;
    TestContractProjection;
    Writeln;
    TestInferredVsContract;
    Writeln;
    TestOwnership;
    Writeln;
    TestAnyRegisteredFormat;
    TestDataSetKeepsSourceNames;
    TestCapabilityAndSourceShape;
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
    Writeln('DATASET_SOURCES: PASS')
  else
  begin
    Writeln('DATASET_SOURCES: FAIL');
    ExitCode := 1;
  end;
end.
