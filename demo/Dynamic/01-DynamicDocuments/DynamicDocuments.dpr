program DynamicDocuments;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Build a document once, as a dynamic value, and write it in any format.

    1. a TDynamicObject built by hand, fluently, with InsertAt;
    2. Delphi values projected into it through RTTI;
    3. the same value written as JSON, BSON and YAML;
    4. JSON parsed back into a dynamic value and changed;
    5. a DataSet as a dynamic value, written as JSON - and JSON back into a
       DataSet through Dynamic;
    6. the general attributes, and a format-specific one beating them.

  Dynamic is not a format: it is the value every format reads into and
  writes from. Nothing here needs registration except step 5's run-time
  format choice.

  Build:  ..\..\..\scripts\dcc.cmd DynamicDocuments.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.TypInfo,
  Data.DB, FireDAC.Comp.Client,
  InvoiceModels in 'InvoiceModels.pas',
  PascalForge.Serialization.Core in '..\..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\..\src\PascalForge.Serialization.pas',
  PascalForge.Json in '..\..\..\src\PascalForge.Json.pas',
  PascalForge.Bson in '..\..\..\src\PascalForge.Bson.pas',
  PascalForge.Yaml in '..\..\..\src\PascalForge.Yaml.pas',
  PascalForge.Json.Registration in '..\..\..\src\PascalForge.Json.Registration.pas',
  PascalForge.DataSet in '..\..\..\src\PascalForge.DataSet.pas';

function NewCustomer: TCustomer;
begin
  Result := TCustomer.Create;
  Result.Id := 42;
  Result.Name := 'Alice';
  Result.PasswordHash := 'never written';
  Result.State := Sent;
end;

procedure BuildByHand;
var
  Invoice: TDynamicObject;
  Customer: TCustomer;
  Origin: TPoint;
  Bytes: TBytes;
begin
  Writeln('1-3. built by hand, with Delphi values projected in');
  Invoice := TDynamicObject.Create;
  Customer := NewCustomer;
  try
    Invoice
      .Append('number', 'INV-0007')
      .Append('total', TDynamicValue.NewDecimal('1250.50'))
      .Append('paid', False);
    { Order is the caller's: 'currency' goes second. }
    Invoice.InsertAt(1, 'currency', 'EUR');
    { A child object, returned for building. }
    Invoice.AddObject('address')
      .Append('city', 'Midtown')
      .Append('country', 'Utopia');
    Invoice.AddArray('lines')
      .Append(10)
      .Append(20);
    { A class, nested under a name, through the shared RTTI metadata... }
    Invoice.Append('customer', Customer);
    { ...and a record. }
    Origin.X := 3;
    Origin.Y := 4;
    Invoice.Append('origin', Origin);

    { One value, three formats. }
    Writeln('  JSON: ', TJsonSerializer.FromDynamic(Invoice));
    Bytes := TBsonSerializer.FromDynamic(Invoice);
    Writeln(Format('  BSON: %d bytes', [Length(Bytes)]));
    Writeln('  YAML:');
    Write(TYamlSerializer.FromDynamic(Invoice));
  finally
    Customer.Free;
    Invoice.Free;
  end;
end;

procedure ParseAndChange;
var
  Doc: TDynamicValue;
begin
  Writeln;
  Writeln('4. JSON in, changed, JSON out');
  Doc := TJsonSerializer.ToDynamic(
    '{"name":"Erin","tags":["a"],"address":{"city":"Uptown"}}');
  try
    Doc.AsObject.Append('age', 35);
    Doc.AsObject.Get('tags').AsArray.Append('b');
    Doc.AsObject.Get('address').AsObject.AppendOrReplace('city',
      TDynamicValue.NewStr('Cork'));
    Writeln('  ', TJsonSerializer.FromDynamic(Doc));
  finally
    Doc.Free;
  end;
end;

procedure DataSets;
var
  Customers: TArray<TCustomer>;
  DS, Back: TFDMemTable;
  Tree: TDynamicValue;
  Json: string;
  I: Integer;
begin
  Writeln;
  Writeln('5. a DataSet through Dynamic');
  SetLength(Customers, 2);
  for I := 0 to 1 do
  begin
    Customers[I] := NewCustomer;
    Customers[I].Id := I + 1;
  end;
  try
    DS := TDataSetSerializer.CreateFDMemTable<TCustomer>(Customers);
  finally
    for I := 0 to 1 do Customers[I].Free;
  end;
  try
    { DataSet -> Dynamic -> JSON: rows only, an array of objects. }
    Tree := TDataSetSerializer.ToDynamic(DS,
      TDataSetSerializationPolicy.RowsOnly);
    try
      Json := TJsonSerializer.FromDynamic(Tree);
      Writeln('  rows as JSON: ', Json);
    finally
      Tree.Free;
    end;
  finally
    DS.Free;
  end;

  { JSON -> Dynamic -> DataSet, saying how to read it: the columns are
    inferred from the rows. }
  Tree := TJsonSerializer.ToDynamic(Json);
  Back := TFDMemTable.Create(nil);
  try
    TDataSetSerializer.FromDynamic(Tree, Back, TDataSetSourceMode.InferStructure);
    Writeln(Format('  back into a DataSet: %d rows, columns %s, %s, %s',
      [Back.RecordCount, Back.Fields[0].FieldName, Back.Fields[1].FieldName,
       Back.Fields[2].FieldName]));
  finally
    Back.Free;
    Tree.Free;
  end;

  { The same, run-time format choice: the format must be registered. }
  TJsonSerializationRegistration.RegisterFormat;
  Tree := TSerialization.ToDynamic(TSerializationPayload.FromText(Json),
    TSerializationFormat.Json);
  try
    Writeln(Format('  through TSerialization: %d rows', [Tree.Count]));
  finally
    Tree.Free;
  end;
end;

procedure Attributes;
var
  Customer: TCustomer;
  Tree: TDynamicValue;
begin
  Writeln;
  Writeln('6. general attributes, and a format-specific one beating them');
  Customer := NewCustomer;
  try
    Tree := TDynamicSerializer.Serialize<TCustomer>(Customer);
    try
      Writeln('  Dynamic: ', Tree.Describe);
    finally
      Tree.Free;
    end;
    Writeln('  JSON:    ', TJsonSerializer.Serialize<TCustomer>(Customer));
    Writeln('  JSON names the member "displayName" - its own [JsonName] - while');
    Writeln('  Dynamic, YAML and every other format use "display_name".');
  finally
    Customer.Free;
  end;
end;

begin
  BuildByHand;
  ParseAndChange;
  DataSets;
  Attributes;
end.
