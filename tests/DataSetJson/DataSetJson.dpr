program DataSetJson;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ TDataSet <-> JSON, which is a different job from DTO -> DataSet projection.

  Projection (PascalForge.DataSet) turns an object into rows. This layer
  (PascalForge.DataSet.Json) moves a dataset itself over the wire: its schema,
  its rows, or only what changed since the last update. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.JSON, Data.DB, FireDAC.Comp.Client,
  Datasnap.DBClient,
  PascalForge.Serialization.Core,
  PascalForge.DataSet,
  PascalForge.Json.Registration,
  PascalForge.DataSet.Json in '..\..\src\PascalForge.DataSet.Json.pas';

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

function NewTable: TFDMemTable;
begin
  Result := TFDMemTable.Create(nil);
  Result.FieldDefs.Add('Id', ftInteger);
  Result.FieldDefs.Add('Name', ftWideString, 40);
  Result.FieldDefs.Add('Amount', ftCurrency);
  Result.CreateDataSet;
  Result.AppendRecord([1, 'one', 10.5]);
  Result.AppendRecord([2, 'two', 20.25]);
end;

procedure TestSnapshot;
var
  Source: TFDMemTable;
  Json: string;
  Target: TFDMemTable;
begin
  Writeln('-- snapshot --');
  Source := NewTable;
  try
    { Rows only: the receiver must already know the schema. }
    Json := TDataSetSerializer.Serialize(Source,
      TSerializationFormat.Json, TDataSetSerializationPolicy.RowsOnly).AsText;
    Note(Json);
    Check(Json.Contains('"one"') and not Json.Contains('"fields"'),
      'DATASET_JSON_ROWS_ONLY');

    { Schema and rows: a complete, self-describing document. }
    Json := TDataSetSerializer.Serialize(Source,
      TSerializationFormat.Json, TDataSetSerializationPolicy.StructureAndRows).AsText;
    Check(Json.Contains('"fields"') and Json.Contains('"rows"'),
      'DATASET_JSON_STRUCTURE_AND_ROWS');
  finally
    Source.Free;
  end;

  { And it comes back. }
  Target := TDataSetSerializer.CreateFDMemTable(Json, TSerializationFormat.Json,
    TDataSetSourceMode.EmbeddedStructure);
  try
    Check((Target.FieldDefs.Count = 3) and (Target.RecordCount = 2),
      'DATASET_JSON_ROUNDTRIP');
    Target.First;
    Check(Target.FieldByName('Name').AsString = 'one',
      'DATASET_JSON_ROUNDTRIP_VALUES');
  finally
    Target.Free;
  end;
end;

procedure TestClientDataSetTarget;
var
  Source: TFDMemTable;
  Json: string;
  Target: TClientDataSet;
begin
  Writeln('-- the same document into a TClientDataSet --');
  Source := NewTable;
  try
    Json := TDataSetSerializer.Serialize(Source,
      TSerializationFormat.Json, TDataSetSerializationPolicy.StructureAndRows).AsText;
  finally
    Source.Free;
  end;

  Target := TClientDataSet.Create(nil);
  try
    TDataSetSerializer.Deserialize(Json, TSerializationFormat.Json, Target,
      TDataSetSourceMode.EmbeddedStructure);
    Check((Target.FieldDefs.Count = 3) and (Target.RecordCount = 2),
      'DATASET_JSON_CLIENTDATASET');
    Target.First;
    Check(Target.FieldByName('Amount').AsCurrency = 10.5,
      'DATASET_JSON_CLIENTDATASET_VALUES');
  finally
    Target.Free;
  end;
end;

procedure TestDelta;
var
  Source: TFDMemTable;
  Json: string;
begin
  Writeln('-- delta --');
  Source := NewTable;
  try
    { A delta is the dataset's own change journal, so the dataset has to
      be keeping one.  CommitUpdates draws the line: everything up to here
      is the baseline, and only what follows is a change. }
    Source.CachedUpdates := True;
    Source.CommitUpdates;

    Source.First;
    Source.Edit;
    Source.FieldByName('Name').AsString := 'changed';
    Source.Post;

    Json := TDataSetSerializer.Serialize(Source,
      TSerializationFormat.Json, TDataSetSerializationPolicy.DeltaOnly).AsText;
    Note(Json);
    { A delta carries the change, not the whole table. }
    Check(Json.Contains('changed'), 'DATASET_JSON_DELTA_CARRIES_CHANGE');
    Check(not Json.Contains('"two"'), 'DATASET_JSON_DELTA_OMITS_UNCHANGED');
  finally
    Source.Free;
  end;
end;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TJsonSerializationRegistration.RegisterFormat;
  try
    TestSnapshot;
    TestClientDataSetTarget;
    TestDelta;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  if GFailures = 0 then
    Writeln('DATASET_JSON: PASS')
  else
    Writeln('DATASET_JSON: FAIL (', GFailures, ')');
  ExitCode := Ord(GFailures <> 0);
end.
