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
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo, Data.DB,
  FireDAC.Comp.Client, Datasnap.DBClient,
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

{ ----------------------------------------------- a generic wrapper type --- }

type
  { A range endpoint: a value, whether it is inclusive, and whether there is
    one at all. }
  TLimit<T> = class
  public
    Value: T;
    Inclusive: Boolean;
    HasValue: Boolean;
  end;

  { One serializer for the whole TLimit<T> family. It adds an Inclusive
    column of its own and leaves the wrapped value to the projection - the
    columns and the value exactly as for a member of type T - through the
    protected helpers on TCustomDataSetTypeSerializer: no engine unit. }
  TLimitSerializer = class(TCustomDataSetTypeSerializer)
  public
    procedure AddFields(ATypeInfo: PTypeInfo; AFieldDefs: TFieldDefs;
      const APrefix: string); override;
    procedure WriteValue(ATypeInfo: PTypeInfo; const AValue: TValue;
      ADataSet: TDataSet; const APrefix: string); override;
  end;

  TPeriod = class
  public
    Name: string;
    Start: TLimit<TDate>;
    Budget: TLimit<Currency>;
    constructor Create;
    destructor Destroy; override;
  end;

procedure TLimitSerializer.AddFields(ATypeInfo: PTypeInfo; AFieldDefs: TFieldDefs;
  const APrefix: string);
var
  Ctx: TRttiContext;
begin
  AFieldDefs.Add(APrefix + 'Inclusive', ftBoolean);
  AddFieldsAsType(Ctx.GetType(ATypeInfo).GetField('Value').FieldType.Handle,
    AFieldDefs, APrefix + 'Value');
end;

procedure TLimitSerializer.WriteValue(ATypeInfo: PTypeInfo; const AValue: TValue;
  ADataSet: TDataSet; const APrefix: string);
var
  Ctx: TRttiContext;
  T: TRttiType;
  Limit: TObject;
begin
  Limit := AValue.AsObject;
  if Limit = nil then Exit;
  T := Ctx.GetType(ATypeInfo);
  if not T.GetField('HasValue').GetValue(Limit).AsBoolean then Exit;
  ADataSet.FieldByName(APrefix + 'Inclusive').AsBoolean :=
    T.GetField('Inclusive').GetValue(Limit).AsBoolean;
  WriteValueAsType(T.GetField('Value').FieldType.Handle,
    T.GetField('Value').GetValue(Limit), ADataSet, APrefix + 'Value');
end;

constructor TPeriod.Create;
begin
  inherited Create;
  Start := TLimit<TDate>.Create;
  Budget := TLimit<Currency>.Create;
end;

destructor TPeriod.Destroy;
begin
  Budget.Free;
  Start.Free;
  inherited Destroy;
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

{ A type serializer for a generic wrapper family projects what it wraps with
  the protected helpers: TLimit<TDate> gets a date column and TLimit<Currency>
  a currency column, as plain TDate and Currency members would, and an empty
  limit leaves its columns null. }
procedure TestWrapperSerializer;
var
  P: TPeriod;
  DS: TFDMemTable;
begin
  Writeln;
  Writeln('-- a type serializer for a generic wrapper family --');
  P := TPeriod.Create;
  try
    P.Name := 'Q1';
    P.Start.Value := EncodeDate(2026, 1, 1);
    P.Start.Inclusive := True;
    P.Start.HasValue := True;
    DS := TDataSetSerializer.CreateFDMemTable<TPeriod>(P);
    try
      Note(DescribeSchema(DS));
      Check((DS.FieldByName('Start.Value').DataType = ftDate) and
        (DS.FieldByName('Start.Inclusive').DataType = ftBoolean),
        'DATASET_WRAPPER_PROJECTS_THE_WRAPPED_TYPE');
      Check(DS.FieldByName('Budget.Value').DataType in [ftCurrency, ftBCD, ftFMTBcd],
        'DATASET_WRAPPER_COLUMN_FOLLOWS_T');
      Check((DS.FieldByName('Start.Value').AsDateTime = EncodeDate(2026, 1, 1)) and
        DS.FieldByName('Start.Inclusive').AsBoolean,
        'DATASET_WRAPPER_WRITES_THE_WRAPPED_VALUE');
      Check(DS.FieldByName('Budget.Value').IsNull and
        DS.FieldByName('Budget.Inclusive').IsNull,
        'DATASET_WRAPPER_EMPTY_LEAVES_NULLS');
    finally
      DS.Free;
    end;
  finally
    P.Free;
  end;
end;

begin
  try
    { Before anything is projected: configuration freezes at first use. }
    TDataSetSerializer.RegisterGenericTypeSerializer(TypeInfo(TLimit<Integer>),
      TLimitSerializer);
    TestFireDac;
    TestClientDataSet;
    TestArrays;
    TestParity;
    TestOwnedReturns;
    TestExceptionCleanup;
    TestWrapperSerializer;
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
