program DataSetFormats;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ A DataSet is not a format, and the two questions about it are not the same
  question.

    WHAT goes into the document  - rows, schema and rows, or only what
                                   changed. That is the POLICY.
    HOW it is spelled            - JSON, XML, BSON. That is the FORMAT.

  They are independent, and this program is mostly about proving that: the
  same four policies, through every structural format the registry knows,
  with no per-format policy type anywhere.

  The other half is reading. A document either describes its own columns or
  does not, and TDataSetSourceMode says whether to look, to insist, or to
  ignore what is there. The looking is done on the DYNAMIC TREE by shape
  alone, with no signature of this library's to match on - so a table
  description written by somebody else's tooling is read as one. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.DateUtils, System.Math,
  System.TypInfo, Data.DB, FireDAC.Comp.Client,
  Datasnap.DBClient,
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  PascalForge.Xml in '..\..\src\PascalForge.Xml.pas',
  PascalForge.Bson in '..\..\src\PascalForge.Bson.pas',
  PascalForge.Json.Registration in '..\..\src\PascalForge.Json.Registration.pas',
  PascalForge.Xml.Registration in '..\..\src\PascalForge.Xml.Registration.pas',
  PascalForge.Bson.Registration in '..\..\src\PascalForge.Bson.Registration.pas',
  PascalForge.DataSet in '..\..\src\PascalForge.DataSet.pas',
  PascalForge.Avro.Schema in '..\..\src\PascalForge.Avro.Schema.pas',
  { Every remaining format. The DataSet layer is format-agnostic and asks the
    registry which formats can be parsed, so this widens the matrix with no
    DataSet code anywhere naming a format. }
  AllFormatsRegistered in '..\Shared\AllFormatsRegistered.pas';

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

function Has(const AText, AFragment: string): Boolean;
begin
  Result := Pos(AFragment, AText) > 0;
end;

const
  GEO_NAME = #$10D2#$10D8#$10DA#$10DD#$10EA#$10D0;

function NewTable: TFDMemTable;
begin
  Result := TFDMemTable.Create(nil);
  Result.FieldDefs.Add('Id', ftInteger);
  Result.FieldDefs.Add('Name', ftWideString, 60);
  Result.FieldDefs.Add('Amount', ftCurrency);
  Result.FieldDefs.Add('Active', ftBoolean);
  Result.CreateDataSet;
  Result.AppendRecord([1, GEO_NAME, 10.5, True]);
  Result.AppendRecord([2, 'two', 20.25, False]);
end;

function FormatName(AFormat: TSerializationFormat): string;
begin
  Result := TSerializationFormats.FormatName(AFormat);
end;

{ ===========================================================================
  1. ONE POLICY SET, EVERY FORMAT
  =========================================================================== }

procedure TestSerializeAcrossFormats;
var
  Source: TFDMemTable;
  Formats: TArray<TSerializationFormat>;
  F: TSerializationFormat;
  Payload: TSerializationPayload;
  Target: TFDMemTable;
  Count, Refused: Integer;
begin
  Writeln('-- the same DataSet, every structural format --');
  Source := NewTable;
  try
    Formats := TSerialization.StructuralFormats;
    Count := 0;
    Refused := 0;
    for F in Formats do
    begin
      { A DESTINATION MAY REFUSE THIS PACKET, AND THAT IS AN ANSWER.

        StructureAndRows is an object of two members: an ARRAY of column
        descriptors and an ARRAY of rows. CSV is a table, and a table has no
        cell that holds an array - so CSV refuses it by name under the
        registry's default options, exactly as it refuses any other nested
        collection. RowsOnly is the policy that suits a table, and
        TestPolicies below covers it.

        Counting that as a failure would be asserting that every format must
        be able to express every packet shape, which is the opposite of what
        this library promises. }
      try
        Payload := TDataSetSerializer.Serialize(Source, F,
          TDataSetSerializationPolicy.StructureAndRows);
      except
        on E: Exception do
        begin
          Note(Format('%-6s refuses the structure packet: %s',
            [FormatName(F), Copy(E.Message, 1, 90)]));
          Inc(Refused);
          Continue;
        end;
      end;

      { Straight back into a new table, schema and all, with no format-
        specific call anywhere in sight. }
      Target := TDataSetSerializer.CreateFDMemTable(Payload, F,
        TDataSetSourceMode.Auto);
      try
        if (Target.FieldDefs.Count <> 4) or (Target.RecordCount <> 2) then
        begin
          Check(False, 'DATASET_FORMAT_ROUND_TRIP:' + FormatName(F));
          Continue;
        end;
        Target.First;
        if Target.FieldByName('Name').AsString <> GEO_NAME then
        begin
          Check(False, 'DATASET_FORMAT_UNICODE:' + FormatName(F));
          Continue;
        end;
        if Target.FieldByName('Amount').AsCurrency <> 10.5 then
        begin
          Check(False, 'DATASET_FORMAT_VALUES:' + FormatName(F));
          Continue;
        end;
        Inc(Count);
        Note(Format('%-6s round trips, %d columns, %d rows',
          [FormatName(F), Target.FieldDefs.Count, Target.RecordCount]));
      finally
        Target.Free;
      end;
    end;
    Writeln('DATASET_FORMATS_CARRIED=', Count);
    Writeln('DATASET_FORMATS_REFUSED=', Refused);
    Check(Count + Refused = Length(Formats), 'DATASET_SERIALIZE_EVERY_FORMAT');
    Check(Count >= 3, 'DATASET_FORMAT_COVERAGE');
  finally
    Source.Free;
  end;
end;

procedure TestPolicies;
var
  Source: TFDMemTable;
  Rows, Both: string;
begin
  Writeln;
  Writeln('-- the policies --');
  Source := NewTable;
  try
    Rows := TDataSetSerializer.Serialize(Source, TSerializationFormat.Json,
      TDataSetSerializationPolicy.RowsOnly).AsText;
    Note(Rows);
    Check(Rows.StartsWith('[') and not Has(Rows, '"fields"'),
      'DATASET_POLICY_ROWS_ONLY');

    Both := TDataSetSerializer.Serialize(Source, TSerializationFormat.Json,
      TDataSetSerializationPolicy.StructureAndRows).AsText;
    Check(Has(Both, '"fields"') and Has(Both, '"rows"'),
      'DATASET_POLICY_STRUCTURE_AND_ROWS');

    { The policy is not part of the format, so the same one produces the
      same CONTENT in a different spelling. }
    Both := TDataSetSerializer.Serialize(Source, TSerializationFormat.Xml,
      TDataSetSerializationPolicy.StructureAndRows).AsText;
    Check(Has(Both, '<fields>') and Has(Both, '<rows>'),
      'DATASET_POLICY_IS_FORMAT_NEUTRAL');
  finally
    Source.Free;
  end;
end;

procedure TestDelta;
var
  Source, Target: TFDMemTable;
  Json: string;
begin
  Writeln;
  Writeln('-- the change list --');
  Source := NewTable;
  try
    Source.CachedUpdates := True;
    Source.CommitUpdates;
    Source.First;
    Source.Edit;
    Source.FieldByName('Name').AsString := 'changed';
    Source.Post;

    Json := TDataSetSerializer.Serialize(Source, TSerializationFormat.Json,
      TDataSetSerializationPolicy.DeltaAndStructure).AsText;
    Note(Json);
    Check(Has(Json, '"Delta"') and Has(Json, '"Fields"') and
          Has(Json, 'changed') and not Has(Json, '"two"'),
      'DATASET_POLICY_DELTA');
  finally
    Source.Free;
  end;

  { A change list describes itself as completely as a table does, so Auto
    recognizes it and replays it. }
  Target := TDataSetSerializer.CreateFDMemTable(Json,
    TSerializationFormat.Json, TDataSetSourceMode.Auto);
  try
    Target.First;
    Check((Target.RecordCount = 1) and
          (Target.FieldByName('Name').AsString = 'changed'),
      'DATASET_DELTA_REPLAYS');
  finally
    Target.Free;
  end;
end;

{ ===========================================================================
  2. WHERE THE SCHEMA COMES FROM
  =========================================================================== }

procedure TestSourceModes;
var
  Source, Target: TFDMemTable;
  Packet, Plain, Broken: string;
  Caught: Boolean;
begin
  Writeln;
  Writeln('-- source modes --');
  Source := NewTable;
  try
    Packet := TDataSetSerializer.Serialize(Source, TSerializationFormat.Json,
      TDataSetSerializationPolicy.StructureAndRows).AsText;
  finally
    Source.Free;
  end;

  { A document that describes its own columns is USED, exactly: ftCurrency
    stays ftCurrency, which inference could never have worked out from a
    JSON number. }
  Check(TDataSetSerializer.ClassifySource(
    TSerializationPayload.FromText(Packet), TSerializationFormat.Json) =
    TDataSetMetadataMatch.ValidMetadata, 'DATASET_DETECT_VALID_METADATA');
  Note(TDataSetSerializer.ExplainSource(
    TSerializationPayload.FromText(Packet), TSerializationFormat.Json));

  Target := TDataSetSerializer.CreateFDMemTable(Packet,
    TSerializationFormat.Json, TDataSetSourceMode.Auto);
  try
    Check(Target.FieldByName('Amount').DataType = ftCurrency,
      'DATASET_AUTO_USES_EMBEDDED_SCHEMA');
  finally
    Target.Free;
  end;

  { InferStructure ignores it entirely and reads the document as data - so
    the table it builds has two columns called "fields" and "rows". That is
    a strange thing to want, and it is exactly what was asked for. }
  Target := TDataSetSerializer.CreateFDMemTable(Packet,
    TSerializationFormat.Json, TDataSetSourceMode.InferStructure);
  try
    Check((Target.FindField('fields') <> nil) and
          (Target.FindField('rows') <> nil) and
          (Target.FindField('Amount') = nil),
      'DATASET_INFER_IGNORES_EMBEDDED_SCHEMA');
  finally
    Target.Free;
  end;

  { An ordinary array of objects describes nothing, so Auto infers. }
  Plain := '[{"Id":1,"Name":"' + GEO_NAME + '"},{"Id":2,"Name":"two"}]';
  Check(TDataSetSerializer.ClassifySource(
    TSerializationPayload.FromText(Plain), TSerializationFormat.Json) =
    TDataSetMetadataMatch.NotMetadata, 'DATASET_DETECT_NOT_METADATA');

  Target := TDataSetSerializer.CreateFDMemTable(Plain,
    TSerializationFormat.Json, TDataSetSourceMode.Auto);
  try
    Check((Target.RecordCount = 2) and (Target.FieldDefs.Count = 2),
      'DATASET_AUTO_INFERS_WHEN_THERE_IS_NOTHING_TO_USE');
  finally
    Target.Free;
  end;

  { ROWS-ONLY IS AMBIGUOUS BY CONSTRUCTION and the library says so rather
    than pretending: a rows-only document IS an ordinary array of objects,
    so Auto infers it. Reading it with the schema the writer had needs
    DeserializeAs, where the caller states the shape. }
  Source := NewTable;
  try
    Plain := TDataSetSerializer.Serialize(Source, TSerializationFormat.Json,
      TDataSetSerializationPolicy.RowsOnly).AsText;
  finally
    Source.Free;
  end;
  Check(TDataSetSerializer.ClassifySource(
    TSerializationPayload.FromText(Plain), TSerializationFormat.Json) =
    TDataSetMetadataMatch.NotMetadata, 'DATASET_ROWS_ONLY_IS_AMBIGUOUS');

  Target := TDataSetSerializer.CreateFDMemTable(Plain,
    TSerializationFormat.Json, TDataSetSourceMode.Auto);
  try
    { Inferred: the currency column came back as a number, because the
      document never said it was money. }
    Check((Target.RecordCount = 2) and
          (Target.FieldByName('Amount').DataType <> ftCurrency),
      'DATASET_ROWS_ONLY_AUTO_INFERS');
  finally
    Target.Free;
  end;

  Target := TFDMemTable.Create(nil);
  try
    Target.FieldDefs.Add('Id', ftInteger);
    Target.FieldDefs.Add('Name', ftWideString, 60);
    Target.FieldDefs.Add('Amount', ftCurrency);
    Target.FieldDefs.Add('Active', ftBoolean);
    Target.CreateDataSet;
    TDataSetSerializer.DeserializeAs(Plain, TSerializationFormat.Json, Target,
      TDataSetSerializationPolicy.RowsOnly);
    Target.First;
    Check((Target.RecordCount = 2) and
          (Target.FieldByName('Amount').AsCurrency = 10.5),
      'DATASET_ROWS_ONLY_WITH_A_KNOWN_SCHEMA');
  finally
    Target.Free;
  end;

  { EmbeddedStructure insists, and the message says what was missing. }
  Caught := False;
  try
    TDataSetSerializer.CreateFDMemTable(Plain, TSerializationFormat.Json,
      TDataSetSourceMode.EmbeddedStructure).Free;
  except
    on E: EDataSetSerializationError do
    begin
      Caught := True;
      Note(E.Message);
    end;
  end;
  Check(Caught, 'DATASET_EMBEDDED_MODE_INSISTS');

  { A document that CLAIMS to describe columns and gets it wrong is neither
    valid metadata nor ordinary data, and Auto refuses rather than building
    a table called "fields" and "rows" out of it. }
  Broken := '{"fields":[{"name":"Id","type":"not a number"}],"rows":[]}';
  Check(TDataSetSerializer.ClassifySource(
    TSerializationPayload.FromText(Broken), TSerializationFormat.Json) =
    TDataSetMetadataMatch.InvalidMetadata, 'DATASET_DETECT_INVALID_METADATA');
  Caught := False;
  try
    TDataSetSerializer.CreateFDMemTable(Broken, TSerializationFormat.Json,
      TDataSetSourceMode.Auto).Free;
  except
    on E: EDataSetSerializationError do
    begin
      Caught := True;
      Note(E.Message);
    end;
  end;
  Check(Caught, 'DATASET_AUTO_REFUSES_BROKEN_METADATA');

  { ... and InferStructure is the documented way out of that. }
  Target := TDataSetSerializer.CreateFDMemTable(Broken,
    TSerializationFormat.Json, TDataSetSourceMode.InferStructure);
  try
    Check(Target.FindField('fields') <> nil,
      'DATASET_INFER_IS_THE_WAY_OUT');
  finally
    Target.Free;
  end;
end;

{ ===========================================================================
  3. DETECTION IS BY SHAPE, NOT BY SIGNATURE
  =========================================================================== }

procedure TestDetectionIsStructural;
const
  { Not written by this library. No namespace, no version member, no marker
    of any kind - just a document that happens to describe a table the way
    this library's packet does. }
  FOREIGN = '{"rows":[{"Code":"AB","Qty":3}],' +
            '"fields":[{"name":"Code","type":24,"size":10,"required":false},' +
            '{"name":"Qty","type":3,"size":0,"required":true}]}';
var
  Target: TFDMemTable;
  Xml, Bson: TSerializationPayload;
begin
  Writeln;
  Writeln('-- detection by shape --');

  Target := TDataSetSerializer.CreateFDMemTable(FOREIGN,
    TSerializationFormat.Json, TDataSetSourceMode.Auto);
  try
    Target.First;
    Check((Target.FieldDefs.Count = 2) and (Target.RecordCount = 1) and
          (Target.FieldByName('Code').AsString = 'AB') and
          Target.FieldDefs[1].Required,
      'DATASET_FOREIGN_PACKET_IS_RECOGNIZED');
  finally
    Target.Free;
  end;

  { Member ORDER is not part of the shape either: the fields member comes
    second above and it is still a schema. }
  Check(TDataSetSerializer.ClassifySource(
    TSerializationPayload.FromText(FOREIGN), TSerializationFormat.Json) =
    TDataSetMetadataMatch.ValidMetadata, 'DATASET_SHAPE_IGNORES_ORDER');

  { And because the question is asked of the DYNAMIC TREE rather than of
    JSON, the same document recognizes the same way after a trip through
    XML or BSON. }
  Xml := TSerialization.Convert(TSerializationPayload.FromText(FOREIGN),
    TSerializationFormat.Json, TSerializationFormat.Xml);
  Check(TDataSetSerializer.ClassifySource(Xml, TSerializationFormat.Xml) =
    TDataSetMetadataMatch.ValidMetadata, 'DATASET_DETECTION_IS_FORMAT_DYNAMIC_XML');

  Bson := TSerialization.Convert(TSerializationPayload.FromText(FOREIGN),
    TSerializationFormat.Json, TSerializationFormat.Bson);
  Check(TDataSetSerializer.ClassifySource(Bson, TSerializationFormat.Bson) =
    TDataSetMetadataMatch.ValidMetadata, 'DATASET_DETECTION_IS_FORMAT_DYNAMIC_BSON');

  { A document with two members that happen to be called "fields" and
    "rows" and are not a schema is ordinary data, not broken metadata. }
  Check(TDataSetSerializer.ClassifySource(
    TSerializationPayload.FromText('{"fields":["a","b"],"rows":12}'),
    TSerializationFormat.Json) = TDataSetMetadataMatch.NotMetadata,
    'DATASET_LOOKALIKE_IS_ORDINARY_DATA');
end;

{ ===========================================================================
  4. THE SCHEMA, WITHOUT BUILDING THE TABLE
  =========================================================================== }

procedure TestReadFieldDefs;
var
  Source, Owner: TFDMemTable;
  Defs: TFieldDefs;
begin
  Writeln;
  Writeln('-- the schema on its own --');
  Source := NewTable;
  Owner := TFDMemTable.Create(nil);
  try
    Defs := Owner.FieldDefs;
    TDataSetSerializer.ReadFieldDefs(
      TDataSetSerializer.Serialize(Source, TSerializationFormat.Bson,
        TDataSetSerializationPolicy.StructureAndRows),
      TSerializationFormat.Bson, Defs);
    Check((Defs.Count = 4) and (Defs[0].Name = 'Id') and
          (Defs[2].DataType = ftCurrency) and (Defs[1].Size = 60),
      'DATASET_READ_FIELD_DEFS');
  finally
    Owner.Free;
    Source.Free;
  end;
end;

{ ===========================================================================
  A DAY IS NOT AN INSTANT, AND THE COLUMN SHOWS IT

  This is the reason the dynamic tree has three temporal kinds rather than
  one. A DataSet field carries its own type, so ftDate on the way out is the
  source stating a semantic; the tree keeps it; and a table inferred from
  that tree gets ftDate back rather than an ftDateTime whose midnight nobody
  supplied.

  The other half is the one that must NOT happen: a column of strings that
  happen to look like dates stays a string column, because the format that
  produced them had only strings.
  =========================================================================== }

function NewTemporalTable: TFDMemTable;
begin
  Result := TFDMemTable.Create(nil);
  Result.FieldDefs.Add('Id', ftInteger);
  Result.FieldDefs.Add('Day', ftDate);
  Result.FieldDefs.Add('Clock', ftTime);
  Result.FieldDefs.Add('Moment', ftDateTime);
  Result.CreateDataSet;
  Result.Append;
  Result.FieldByName('Id').AsInteger := 1;
  Result.FieldByName('Day').AsDateTime := EncodeDate(2026, 9, 22);
  Result.FieldByName('Clock').AsDateTime := EncodeTime(14, 35, 0, 0);
  Result.FieldByName('Moment').AsDateTime :=
    EncodeDate(2026, 9, 22) + EncodeTime(14, 35, 0, 0);
  Result.Post;
end;

function FieldTypeOf(ATable: TDataSet; const AName: string): TFieldType;
begin
  Result := ATable.FieldDefs.Find(AName).DataType;
end;

{ THE DESTINATION CONTRACT. Reading into an existing DataSet rebuilds it,
  open or closed, with a context or without - and a schema, value or
  projection failure the library can detect, found by pre-validating on a
  temporary instance, does not destroy a populated TFDMemTable or
  TClientDataSet. (Application callbacks during the final application are
  outside what pre-validation covers; these tables have none.) }
procedure TestDestinationContract;
const
  AVRO_SCHEMA =
    '{"type":"array","items":{"type":"record","name":"Row","fields":[' +
    '{"name":"reference","type":"string"},{"name":"count","type":"long"}]}}';
  { Valid metadata, and a second row whose Id an integer column cannot hold:
    it fails only after the first row has been written. }
  BAD_PACKET = '{"fields":[{"name":"Id","type":3,"size":0,"required":true}],' +
    '"rows":[{"Id":1},{"Id":"abc"}]}';
var
  Schema: TAvroSchema;
  Avro, Broken: TSerializationPayload;
  Mem: TFDMemTable;
  Cds: TClientDataSet;
  Bytes: TBytes;
  Raised: Boolean;

  { A DataSet already showing something: one column 'a', one row, open. }
  procedure Fill(ADataSet: TDataSet);
  begin
    TDataSetSerializer.Deserialize(TSerializationPayload.FromText('[{"a":1}]'),
      TSerializationFormat.Json, ADataSet);
  end;

  function Untouched(ADataSet: TDataSet): Boolean;
  begin
    Result := ADataSet.Active and (ADataSet.FieldCount = 1) and
      (ADataSet.Fields[0].FieldName = 'a') and (ADataSet.RecordCount = 1);
    if Result then
    begin
      ADataSet.First;
      Result := ADataSet.Fields[0].AsInteger = 1;
    end;
  end;

  function IsAvroRows(ADataSet: TDataSet): Boolean;
  begin
    Result := ADataSet.Active and (ADataSet.FieldCount = 2) and
      (ADataSet.FindField('a') = nil) and (ADataSet.RecordCount = 2) and
      (ADataSet.FindField('reference') <> nil);
    if Result then
    begin
      ADataSet.First;
      Result := ADataSet.FieldByName('reference').AsString = 'PF-1';
    end;
  end;

begin
  Writeln;
  Writeln('--- the destination contract ---');

  { Without a context: an open DataSet is rebuilt by the document. }
  Mem := TFDMemTable.Create(nil);
  Cds := TClientDataSet.Create(nil);
  try
    Fill(Mem);
    Fill(Cds);
    TDataSetSerializer.Deserialize(
      TSerializationPayload.FromText('[{"x":"p"},{"x":"q"}]'),
      TSerializationFormat.Json, Mem);
    TDataSetSerializer.Deserialize(
      TSerializationPayload.FromText('[{"x":"p"},{"x":"q"}]'),
      TSerializationFormat.Json, Cds);
    Check(Mem.Active and (Mem.FieldCount = 1) and (Mem.FindField('x') <> nil) and
      (Mem.RecordCount = 2) and Cds.Active and (Cds.FindField('a') = nil) and
      (Cds.RecordCount = 2), 'DATASET_DESERIALIZE_OPEN_DESTINATION');
  finally
    Cds.Free;
    Mem.Free;
  end;

  Schema := TAvroSchema.Parse(AVRO_SCHEMA);
  try
    Avro := TSerialization.Convert(TSerializationPayload.FromText(
      '[{"reference":"PF-1","count":42},{"reference":"PF-2","count":7}]'),
      TSerializationFormat.Json, TSerializationFormat.Avro,
      TStructuralConversionOptions.Default.WithContext(Schema));

    { With a context: the same contract. This used to refuse an open
      DataSet that the overload without a context rebuilt. }
    Mem := TFDMemTable.Create(nil);
    Cds := TClientDataSet.Create(nil);
    try
      Fill(Mem);
      Fill(Cds);
      TDataSetSerializer.Deserialize(Avro, TSerializationFormat.Avro, Schema,
        Mem);
      TDataSetSerializer.Deserialize(Avro, TSerializationFormat.Avro, Schema,
        Cds);
      Check(IsAvroRows(Mem) and IsAvroRows(Cds),
        'DATASET_CONTEXT_DESERIALIZE_OPEN_DESTINATION');
    finally
      Cds.Free;
      Mem.Free;
    end;

    { A context read that fails leaves the destination as it was. }
    Bytes := Copy(Avro.AsBytes, 0, Length(Avro.AsBytes) - 3);
    Broken := TSerializationPayload.FromBytes(Bytes);
    Mem := TFDMemTable.Create(nil);
    try
      Fill(Mem);
      Raised := False;
      try
        TDataSetSerializer.Deserialize(Broken, TSerializationFormat.Avro,
          Schema, Mem);
      except
        on E: Exception do Raised := True;
      end;
      Check(Raised and Untouched(Mem),
        'DATASET_CONTEXT_FAILURE_PRESERVES_DESTINATION');
    finally
      Mem.Free;
    end;
  finally
    Schema.Free;
  end;

  { A read that fails half way through being WRITTEN - after the schema has
    been built and a row written - leaves the destination as it was too:
    the read is rehearsed on a scratch DataSet of the same class first. }
  Mem := TFDMemTable.Create(nil);
  Cds := TClientDataSet.Create(nil);
  try
    Fill(Mem);
    Fill(Cds);
    Raised := False;
    try
      TDataSetSerializer.Deserialize(TSerializationPayload.FromText(BAD_PACKET),
        TSerializationFormat.Json, Mem);
    except
      on E: Exception do Raised := True;
    end;
    try
      TDataSetSerializer.Deserialize(TSerializationPayload.FromText(BAD_PACKET),
        TSerializationFormat.Json, Cds);
      Raised := False;
    except
      on E: Exception do ;
    end;
    Check(Raised and Untouched(Mem) and Untouched(Cds),
      'DATASET_FAILURE_PRESERVES_DESTINATION');
  finally
    Cds.Free;
    Mem.Free;
  end;
end;

{ The packet's own keywords are matched exactly, because the structural tree
  is exact: an object whose members are FIELDS and ROWS is ordinary data,
  not a packet. A DataSet FIELD name, on the other hand, is case-insensitive
  in Delphi, and a row member is matched to its column the same way. }
procedure TestPacketKeywordsAreExact;
const
  FIELD_ID = '[{"name":"Id","type":3,"size":0,"required":true}]';
var
  Upper, Lower, Mixed: TSerializationPayload;
  Mem: TFDMemTable;
begin
  Writeln;
  Writeln('--- packet keywords are exact, field names are not ---');
  Lower := TSerializationPayload.FromText(
    '{"fields":' + FIELD_ID + ',"rows":[{"Id":1}]}');
  Upper := TSerializationPayload.FromText(
    '{"FIELDS":' + FIELD_ID + ',"ROWS":[{"Id":1}]}');
  Check(TDataSetSerializer.ClassifySource(Lower, TSerializationFormat.Json) =
    TDataSetMetadataMatch.ValidMetadata, 'DATASET_PACKET_KEYWORDS_RECOGNISED');
  Check(TDataSetSerializer.ClassifySource(Upper, TSerializationFormat.Json) =
    TDataSetMetadataMatch.NotMetadata, 'DATASET_PACKET_KEYWORDS_ARE_CASE_SENSITIVE');

  Mixed := TSerializationPayload.FromText(
    '{"fields":' + FIELD_ID + ',"rows":[{"ID":7}]}');
  Mem := TFDMemTable.Create(nil);
  try
    TDataSetSerializer.Deserialize(Mixed, TSerializationFormat.Json, Mem);
    Mem.First;
    Check((Mem.RecordCount = 1) and (Mem.FieldByName('Id').AsInteger = 7),
      'DATASET_FIELD_NAMES_STAY_CASE_INSENSITIVE');
  finally
    Mem.Free;
  end;
end;

procedure TestTemporalColumns;
var
  Source, Target: TFDMemTable;
  Payload: TSerializationPayload;
  Json: string;
begin
  Writeln;
  Writeln('-- a day, a time and an instant, through the tree and back --');

  Source := NewTemporalTable;
  try
    Payload := TDataSetSerializer.Serialize(Source, TSerializationFormat.Json,
      TDataSetSerializationPolicy.RowsOnly);
    Json := Payload.AsText;
    Note(Copy(Json, 1, 160));

    { The reduced ISO forms, which is what says the kind survived the trip
      out. An ftDate written as 2026-09-22T00:00:00.000 would be the old
      behaviour, and the midnight in it is invented. }
    Check(Has(Json, '"Day":"2026-09-22"'), 'DATASET_DATE_WRITES_DAY_ONLY');
    Check(Has(Json, '"Clock":"14:35:00.000"'), 'DATASET_TIME_WRITES_TIME_ONLY');
    Check(Has(Json, '"Moment":"2026-09-22T14:35:00'),
      'DATASET_DATETIME_WRITES_THE_INSTANT');

    { Inferring from THIS document must not recover the types, and that is
      the point rather than a shortfall: JSON wrote three strings, a string
      that looks like a date is a string, and the inference is not allowed to
      decide otherwise. See the refusal checks at the end. }
    Target := TDataSetSerializer.CreateFDMemTable(Payload,
      TSerializationFormat.Json, TDataSetSourceMode.Auto);
    try
      Check(FieldTypeOf(Target, 'Day') <> ftDate,
        'DATASET_JSON_TEXT_DOES_NOT_BECOME_FTDATE');
    finally
      Target.Free;
    end;
  finally
    Source.Free;
  end;

  { CBOR HAS A NATIVE INSTANT (tag 1), so a DateTime kind survives the
    document and the inference has a real type to work from - no text, no
    guessing. This is the mapping the marker is about.

    CBOR rather than BSON because RowsOnly is an ARRAY at the root and a BSON
    document is a map; that refusal is real and is covered elsewhere. }
  Source := NewTemporalTable;
  try
    Payload := TDataSetSerializer.Serialize(Source, TSerializationFormat.Cbor,
      TDataSetSerializationPolicy.RowsOnly);
    Target := TDataSetSerializer.CreateFDMemTable(Payload,
      TSerializationFormat.Cbor, TDataSetSourceMode.InferStructure);
    try
      Check(FieldTypeOf(Target, 'Moment') = ftDateTime,
        'DATASET_DATETIME_TO_FTDATETIME');
      Target.First;
      Check(SameValue(Target.FieldByName('Moment').AsDateTime,
        EncodeDate(2026, 9, 22) + EncodeTime(14, 35, 0, 0),
        1 / (MSecsPerDay * 2)), 'DATASET_DATETIME_VALUE_SURVIVES');
      { CBOR's tag 1 is an instant, so the day and the time of day went out
        as text and come back as text. Stated here rather than discovered. }
      Check(FieldTypeOf(Target, 'Day') <> ftDateTime,
        'DATASET_CBOR_DAY_IS_NOT_AN_INSTANT');
    finally
      Target.Free;
    end;
  finally
    Source.Free;
  end;

  { The same tree, taken straight to a table without the JSON hop, so the
    kinds reach the inference unflattened by any text format. }
  Source := NewTemporalTable;
  try
    Payload := TDataSetSerializer.Serialize(Source, TSerializationFormat.Bson,
      TDataSetSerializationPolicy.StructureAndRows);
    Target := TDataSetSerializer.CreateFDMemTable(Payload,
      TSerializationFormat.Bson, TDataSetSourceMode.Auto);
    try
      { StructureAndRows carries the field types themselves, so these are the
        declared ones rather than inferred ones - and they must come back
        exactly. }
      Check(FieldTypeOf(Target, 'Day') = ftDate, 'DATASET_DATE_TO_FTDATE');
      Check(FieldTypeOf(Target, 'Clock') = ftTime, 'DATASET_TIME_TO_FTTIME');
      Check(FieldTypeOf(Target, 'Moment') = ftDateTime,
        'DATASET_DECLARED_DATETIME_ROUND_TRIPS');
      Target.First;
      Check(SameValue(Target.FieldByName('Day').AsDateTime,
        EncodeDate(2026, 9, 22)), 'DATASET_DATE_VALUE_SURVIVES');
      Check(SameValue(Target.FieldByName('Clock').AsDateTime,
        EncodeTime(14, 35, 0, 0), 1 / (MSecsPerDay * 2)),
        'DATASET_TIME_VALUE_SURVIVES');
    finally
      Target.Free;
    end;
  finally
    Source.Free;
  end;

  { AND THE REFUSAL TO GUESS. These are strings in the document, they look
    exactly like a date and a time, and the inferred column is text. }
  Payload := TSerializationPayload.FromText(
    '[{"Id":1,"Looks":"2026-09-22","Clockish":"14:35:00"},' +
    ' {"Id":2,"Looks":"2026-09-23","Clockish":"15:00:00"}]');
  Target := TDataSetSerializer.CreateFDMemTable(Payload,
    TSerializationFormat.Json, TDataSetSourceMode.InferStructure);
  try
    Check(FieldTypeOf(Target, 'Looks') <> ftDate,
      'DATASET_STRING_DATE_IS_NOT_INFERRED_AS_FTDATE');
    Check(FieldTypeOf(Target, 'Clockish') <> ftTime,
      'DATASET_STRING_TIME_IS_NOT_INFERRED_AS_FTTIME');
    Check(FieldTypeOf(Target, 'Looks') <> ftDateTime,
      'DATASET_STRING_DATE_IS_NOT_INFERRED_AS_FTDATETIME');
    Note('inferred column type for a date-looking string: ' +
      GetEnumName(System.TypeInfo(TFieldType),
        Ord(FieldTypeOf(Target, 'Looks'))));
  finally
    Target.Free;
  end;
end;

begin
  try
    TestSerializeAcrossFormats;
    TestPolicies;
    TestDelta;
    TestSourceModes;
    TestDetectionIsStructural;
    TestReadFieldDefs;
    TestTemporalColumns;
    TestPacketKeywordsAreExact;
    TestDestinationContract;

    Writeln;
    Writeln('FAILURES=', GFailures);
    { The matrix in one answer: every structural-capable registered format
      was discovered, projected onto a DataSet and read back, and nothing
      in that sweep failed. }
    if GFailures = 0 then Writeln('DATASET_FORMAT_MATRIX: PASS')
    else Writeln('DATASET_FORMAT_MATRIX: FAIL');
    if GFailures = 0 then Writeln('DATASET_FORMATS: PASS')
    else Writeln('DATASET_FORMATS: FAIL');
    if GFailures > 0 then Halt(1);
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Writeln('DATASET_FORMATS: FAIL');
      Halt(1);
    end;
  end;
end.
