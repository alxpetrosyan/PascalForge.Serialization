program DataSetFromEncoded;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Three ways to reach a DataSet, and the difference between the last two.

  Build:  ..\..\..\scripts\dcc.cmd DataSetFromEncoded.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.TypInfo,
  Data.DB, FireDAC.Comp.Client,
  DataSetModels in 'DataSetModels.pas',
  PascalForge.Serialization.Core in '..\..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.DataSet in '..\..\..\src\PascalForge.DataSet.pas',
  PascalForge.Json in '..\..\..\src\PascalForge.Json.pas',
  PascalForge.Json.Registration in '..\..\..\src\PascalForge.Json.Registration.pas';

procedure Show(const ACaption: string; ADataSet: TDataSet);
var
  I: Integer;
begin
  Writeln(ACaption);
  if not ADataSet.Active then
  begin
    Writeln('  (no schema could be inferred, so it is still closed)');
    Exit;
  end;
  for I := 0 to ADataSet.FieldDefs.Count - 1 do
    Writeln(Format('  %-10s %s', [ADataSet.FieldDefs[I].Name,
      GetEnumName(TypeInfo(TFieldType), Ord(ADataSet.FieldDefs[I].DataType))]));
  Writeln(Format('  %d row(s)', [ADataSet.RecordCount]));
end;

const
  JSON = '{"id":1,"consignee":"Ada","booked":"2026-09-14"}';
var
  Shipment: TShipment;
  DS: TFDMemTable;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TJsonSerializationRegistration.RegisterFormat;
  { A. A Delphi value. No encoded format is involved, so no registration
       unit is needed for this one. }
  Shipment := TShipment.Create;
  try
    Shipment.Id := 1;
    Shipment.Consignee := 'Ada';
    Shipment.Booked := EncodeDate(2026, 9, 14);
    DS := TDataSetSerializer.CreateFDMemTable<TShipment>(Shipment);
  finally
    Shipment.Free;
  end;
  try
    Show('A. from a Delphi value:', DS);
  finally
    DS.Free;
  end;

  { B. An encoded document WITH the contract. JSON deserializes into
       TShipment, and the existing DTO projection does the rest - there is no
       second mapping implementation. }
  Writeln;
  DS := TDataSetSerializer.CreateFDMemTable<TShipment>(JSON,
    TSerializationFormat.Json);
  try
    Show('B. from JSON, using TShipment as the contract:', DS);
    Writeln('   Booked is ftDate because TShipment says TDate.');
  finally
    DS.Free;
  end;

  { C. The same document with NO contract. The structure decides, and only
       what JSON itself states about a value counts. }
  Writeln;
  DS := TDataSetSerializer.CreateFDMemTable(JSON, TSerializationFormat.Json);
  try
    Show('C. from the same JSON, with no contract:', DS);
    Writeln('   booked is ftWideString: JSON never said it was a date, and');
    Writeln('   guessing from the spelling is how the same document becomes');
    Writeln('   a timestamp in one system and text in the next.');
  finally
    DS.Free;
  end;

  Writeln;
  Writeln('BSON is the interesting case for C: it states its types, so an');
  Writeln('int64 stays ftLargeint and a BSON datetime stays ftDateTime.');
end.
