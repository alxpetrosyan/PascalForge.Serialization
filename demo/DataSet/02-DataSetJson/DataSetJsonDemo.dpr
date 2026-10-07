program DataSetJsonDemo;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Moving a TDataSet itself over the wire.

  This is a different job from projecting objects into rows: here the dataset
  IS the payload - its schema, its rows, or only what changed. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, Data.DB, FireDAC.Comp.Client,
  PascalForge.Serialization.Core,
  PascalForge.DataSet,
  PascalForge.Json.Registration,
  PascalForge.DataSet.Json in '..\..\..\src\PascalForge.DataSet.Json.pas';

function NewTable: TFDMemTable;
begin
  Result := TFDMemTable.Create(nil);
  Result.FieldDefs.Add('Id', ftInteger);
  Result.FieldDefs.Add('Name', ftWideString, 40);
  Result.CreateDataSet;
  Result.AppendRecord([1, 'one']);
  Result.AppendRecord([2, 'two']);
end;

var
  Table, Restored: TFDMemTable;
  Json: string;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TJsonSerializationRegistration.RegisterFormat;
  Table := NewTable;
  try
    { Rows only. Compact, but the receiver must already know the schema. }
    Writeln('RowsOnly:');
    Writeln('  ', TDataSetSerializer.Serialize(Table,
      TSerializationFormat.Json, TDataSetSerializationPolicy.RowsOnly).AsText);
    Writeln;

    { Schema and rows: self-describing, and the exact round-trip format. }
    Json := TDataSetSerializer.Serialize(Table,
      TSerializationFormat.Json, TDataSetSerializationPolicy.StructureAndRows).AsText;
    Writeln('StructureAndRows:');
    Writeln('  ', Json);
    Writeln;

    { Only what changed since the last commit. }
    Table.CachedUpdates := True;
    Table.CommitUpdates;
    Table.First;
    Table.Edit;
    Table.FieldByName('Name').AsString := 'changed';
    Table.Post;

    Writeln('DeltaOnly (after editing row 1):');
    Writeln('  ', TDataSetSerializer.Serialize(Table,
      TSerializationFormat.Json, TDataSetSerializationPolicy.DeltaOnly).AsText);
  finally
    Table.Free;
  end;

  { And back again. }
  Restored := TDataSetSerializer.CreateFDMemTable(Json,
    TSerializationFormat.Json, TDataSetSourceMode.EmbeddedStructure);
  try
    Writeln;
    Writeln('round-tripped: ', Restored.FieldDefs.Count, ' fields, ',
      Restored.RecordCount, ' rows');
  finally
    Restored.Free;
  end;
end.
