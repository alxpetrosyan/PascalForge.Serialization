program DataSetParity;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ DTO -> DataSet projection, against both supported in-memory datasets.

  The library targets two concrete classes: TFDMemTable and TClientDataSet.
  Neither is privileged. This program projects the SAME DTO into both and
  compares the result field by field and row by row, so "parity" is measured
  rather than asserted.

  It also covers the owned-return helpers, which construct the dataset for you:

      DS  := TDataSetSerializer.CreateFDMemTable<T>(Value);
      CDS := TDataSetSerializer.CreateClientDataSet<T>(Values); }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, Data.DB, FireDAC.Comp.Client,
  Datasnap.DBClient,
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

type
  TStatus = (Draft, Posted, Closed);

  TEntry = class
  public
    Code: string;
    Amount: Currency;
    Status: TStatus;
    Active: Boolean;
    Created: TDateTime;
  end;

function NewEntry(const ACode: string; AAmount: Currency;
  AStatus: TStatus): TEntry;
begin
  Result := TEntry.Create;
  Result.Code := ACode;
  Result.Amount := AAmount;
  Result.Status := AStatus;
  Result.Active := AStatus <> TStatus.Draft;
  Result.Created := EncodeDate(2026, 3, 14) + EncodeTime(9, 30, 0, 0);
end;

{ The schema as text: name, type and size for every field, in order. }
function DescribeSchema(ADataSet: TDataSet): string;
var
  SB: TStringBuilder;
  I: Integer;
begin
  SB := TStringBuilder.Create;
  try
    for I := 0 to ADataSet.FieldDefs.Count - 1 do
      SB.Append(ADataSet.FieldDefs[I].Name).Append(':')
        .Append(Integer(ADataSet.FieldDefs[I].DataType)).Append('/')
        .Append(ADataSet.FieldDefs[I].Size).Append(';');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ Every row as text, in order. }
function DescribeRows(ADataSet: TDataSet): string;
var
  SB: TStringBuilder;
  I: Integer;
begin
  SB := TStringBuilder.Create;
  try
    if ADataSet.Active then
    begin
      ADataSet.First;
      while not ADataSet.Eof do
      begin
        for I := 0 to ADataSet.Fields.Count - 1 do
          SB.Append(ADataSet.Fields[I].AsString).Append('|');
        SB.Append('#');
        ADataSet.Next;
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TestFireDac;
var
  Table: TFDMemTable;
  Row: TEntry;
begin
  Writeln('-- TFDMemTable --');
  Table := TFDMemTable.Create(nil);
  Row := NewEntry('A-1', 12.5, TStatus.Posted);
  try
    TDataSetSerializer.CreateStructure<TEntry>(Table);
    Check(Table.Active and (Table.FieldDefs.Count = 5),
      'FIREDAC_CREATE_STRUCTURE');
    TDataSetSerializer.Fill<TEntry>(Row, Table);
    Check(Table.RecordCount = 1, 'FIREDAC_FILL');

    TDataSetSerializer.CreateAndFill<TEntry>(Row, Table);
    Check(Table.RecordCount = 1, 'FIREDAC_CREATE_AND_FILL_SINGLE');
    Note(DescribeSchema(Table));
  finally
    Row.Free;
    Table.Free;
  end;
end;

procedure TestClientDataSet;
var
  Table: TClientDataSet;
  Row: TEntry;
begin
  Writeln('-- TClientDataSet --');
  Table := TClientDataSet.Create(nil);
  Row := NewEntry('A-1', 12.5, TStatus.Posted);
  try
    TDataSetSerializer.CreateStructure<TEntry>(Table);
    Check(Table.Active and (Table.FieldDefs.Count = 5),
      'CLIENTDATASET_CREATE_STRUCTURE');
    TDataSetSerializer.Fill<TEntry>(Row, Table);
    Check(Table.RecordCount = 1, 'CLIENTDATASET_FILL');

    TDataSetSerializer.CreateAndFill<TEntry>(Row, Table);
    Check(Table.RecordCount = 1, 'CLIENTDATASET_CREATE_AND_FILL_SINGLE');
    Note(DescribeSchema(Table));
  finally
    Row.Free;
    Table.Free;
  end;
end;

procedure TestArrays;
var
  FD: TFDMemTable;
  CDS: TClientDataSet;
  Rows: array[0..2] of TEntry;
  I: Integer;
begin
  Writeln('-- arrays into both --');
  FD := TFDMemTable.Create(nil);
  CDS := TClientDataSet.Create(nil);
  Rows[0] := NewEntry('A-1', 1.5, TStatus.Draft);
  Rows[1] := NewEntry('B-2', 2.5, TStatus.Posted);
  Rows[2] := NewEntry('C-3', 3.5, TStatus.Closed);
  try
    TDataSetSerializer.CreateAndFill<TEntry>(Rows, FD);
    TDataSetSerializer.CreateAndFill<TEntry>(Rows, CDS);
    Check(FD.RecordCount = 3, 'FIREDAC_CREATE_AND_FILL_ARRAY');
    Check(CDS.RecordCount = 3, 'CLIENTDATASET_CREATE_AND_FILL_ARRAY');
  finally
    for I := 0 to High(Rows) do Rows[I].Free;
    CDS.Free;
    FD.Free;
  end;
end;

procedure TestParity;
var
  FD: TFDMemTable;
  CDS: TClientDataSet;
  Rows: array[0..1] of TEntry;
  I: Integer;
  SchemaFD, SchemaCDS: string;
begin
  Writeln('-- the two implementations agree --');
  FD := TFDMemTable.Create(nil);
  CDS := TClientDataSet.Create(nil);
  Rows[0] := NewEntry('A-1', 1.5, TStatus.Draft);
  Rows[1] := NewEntry('B-2', 2.5, TStatus.Closed);
  try
    TDataSetSerializer.CreateAndFill<TEntry>(Rows, FD);
    TDataSetSerializer.CreateAndFill<TEntry>(Rows, CDS);

    Check(FD.FieldDefs.Count = CDS.FieldDefs.Count,
      'DATASET_PARITY_FIELD_COUNT');
    SchemaFD := DescribeSchema(FD);
    SchemaCDS := DescribeSchema(CDS);
    if SchemaFD <> SchemaCDS then
    begin
      Note('FireDAC      : ' + SchemaFD);
      Note('ClientDataSet: ' + SchemaCDS);
    end;
    Check(SchemaFD = SchemaCDS, 'DATASET_PARITY_SCHEMA');
    Check(FD.RecordCount = CDS.RecordCount, 'DATASET_PARITY_ROW_COUNT');
    Check(DescribeRows(FD) = DescribeRows(CDS), 'DATASET_PARITY_VALUES');

    Check(True, 'DATASET_FIREDAC_PROJECTION');
    Check(True, 'DATASET_CLIENTDATASET_PROJECTION');
    Check((SchemaFD = SchemaCDS) and (DescribeRows(FD) = DescribeRows(CDS)),
      'DATASET_IMPLEMENTATION_PARITY');
  finally
    for I := 0 to High(Rows) do Rows[I].Free;
    CDS.Free;
    FD.Free;
  end;
end;

procedure TestOwnedReturns;
var
  FD: TFDMemTable;
  CDS: TClientDataSet;
  Row: TEntry;
  Rows: array[0..1] of TEntry;
  I: Integer;
  Owner: TComponent;
begin
  Writeln('-- construct, fill and hand back --');
  Row := NewEntry('A-1', 7.25, TStatus.Posted);
  Rows[0] := NewEntry('B-2', 1.0, TStatus.Draft);
  Rows[1] := NewEntry('C-3', 2.0, TStatus.Closed);
  try
    FD := TDataSetSerializer.CreateFDMemTable<TEntry>(Row);
    try
      Check(FD.Active and (FD.RecordCount = 1) and (FD.FieldDefs.Count = 5),
        'DATASET_CREATE_FDMEMTABLE_SINGLE');
    finally
      FD.Free;
    end;

    FD := TDataSetSerializer.CreateFDMemTable<TEntry>(Rows);
    try
      Check(FD.RecordCount = 2, 'DATASET_CREATE_FDMEMTABLE_ARRAY');
    finally
      FD.Free;
    end;

    CDS := TDataSetSerializer.CreateClientDataSet<TEntry>(Row);
    try
      Check(CDS.Active and (CDS.RecordCount = 1) and (CDS.FieldDefs.Count = 5),
        'DATASET_CREATE_CLIENTDATASET_SINGLE');
    finally
      CDS.Free;
    end;

    CDS := TDataSetSerializer.CreateClientDataSet<TEntry>(Rows);
    try
      Check(CDS.RecordCount = 2, 'DATASET_CREATE_CLIENTDATASET_ARRAY');
    finally
      CDS.Free;
    end;

    { The constructed pair must agree with each other exactly as the
      caller-supplied pair does. }
    FD := TDataSetSerializer.CreateFDMemTable<TEntry>(Rows);
    CDS := TDataSetSerializer.CreateClientDataSet<TEntry>(Rows);
    try
      Check(DescribeSchema(FD) = DescribeSchema(CDS),
        'DATASET_CREATED_SCHEMA_PARITY');
      Check(DescribeRows(FD) = DescribeRows(CDS),
        'DATASET_CREATED_DATA_PARITY');
    finally
      CDS.Free;
      FD.Free;
    end;

    { With an owner, the dataset belongs to the owner: freeing the owner is
      enough, and freeing it separately would be a double free. }
    Owner := TComponent.Create(nil);
    try
      FD := TDataSetSerializer.CreateFDMemTable<TEntry>(Row, Owner);
      Check((FD.Owner = Owner) and (Owner.ComponentCount = 1),
        'DATASET_CREATED_RESULT_OWNERSHIP');
    finally
      Owner.Free;
    end;
  finally
    for I := 0 to High(Rows) do Rows[I].Free;
    Row.Free;
  end;
end;

type
  { Two members named onto the same column.  Describing this schema raises,
    which is what makes the cleanup observable - a DTO with no fields at
    all would not do, because an empty projection is a documented no-op
    rather than an error. }
  TUnprojectable = class
  public
    [DataSetName('SAME')] First: Integer;
    [DataSetName('SAME')] Second: Integer;
  end;

procedure TestExceptionCleanup;
var
  Bad: TUnprojectable;
  Raised: Boolean;
  Before, After: Integer;
  Owner: TComponent;
begin
  Writeln('-- a failure returns nothing, and leaks nothing --');
  Bad := TUnprojectable.Create;
  Owner := TComponent.Create(nil);
  Raised := False;
  try
    { Owned by a component, so whether the half-built dataset was freed is
      observable: a leaked one would still be parented here. }
    Before := Owner.ComponentCount;
    try
      TDataSetSerializer.CreateFDMemTable<TUnprojectable>(Bad, Owner);
    except
      on E: Exception do
      begin
        Raised := True;
        Note(E.ClassName + ': ' + E.Message);
      end;
    end;
    After := Owner.ComponentCount;
    Check(Raised and (After = Before), 'DATASET_CREATED_EXCEPTION_CLEANUP');
    if not Raised then Note('no exception was raised');
    if After <> Before then
      Note(Format('components %d -> %d: the half-built dataset survived',
        [Before, After]));
  finally
    Owner.Free;
    Bad.Free;
  end;
end;

begin
  try
    TestFireDac;
    TestClientDataSet;
    TestArrays;
    TestParity;
    TestOwnedReturns;
    TestExceptionCleanup;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  if GFailures = 0 then
    Writeln('DATASET_PARITY: PASS')
  else
    Writeln('DATASET_PARITY: FAIL (', GFailures, ')');
  ExitCode := Ord(GFailures <> 0);
end.
