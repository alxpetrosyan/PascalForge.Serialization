program DataSetProjection;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Turning objects into rows.

  The same DTO is projected into both supported in-memory datasets, so the
  parity is visible rather than claimed. Three entry points, and the
  difference between them is the whole API:

      CreateStructure<T>   schema only, on a dataset you supply
      Fill<T>              rows into a schema that already exists
      CreateAndFill<T>     both, on a dataset you supply

  and when you have no dataset yet:

      CreateFDMemTable<T>      construct + schema + fill + hand back
      CreateClientDataSet<T>   the same, for TClientDataSet }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.TypInfo, Data.DB, FireDAC.Comp.Client, Datasnap.DBClient,
  PascalForge.DataSet in '..\..\..\src\PascalForge.DataSet.pas';

type
  TStatus = (Draft, Posted);

  TEntry = class
  public
    [DataSetName('REFERENCE')]
    Reference: string;
    Amount: Currency;
    Status: TStatus;
    [DataSetIgnore]
    InternalNote: string;
  end;

function NewEntry(const ARef: string; AAmount: Currency;
  AStatus: TStatus): TEntry;
begin
  Result := TEntry.Create;
  Result.Reference := ARef;
  Result.Amount := AAmount;
  Result.Status := AStatus;
  Result.InternalNote := 'never becomes a column';
end;

procedure Dump(const ATitle: string; ADataSet: TDataSet);
var
  I: Integer;
  Line: string;
begin
  Writeln;
  Writeln(ATitle, '  (', ADataSet.ClassName, ')');

  Line := '';
  for I := 0 to ADataSet.FieldDefs.Count - 1 do
    Line := Line + Format('%-12s', [ADataSet.FieldDefs[I].Name]);
  Writeln('  ', Line);

  Line := '';
  for I := 0 to ADataSet.FieldDefs.Count - 1 do
    Line := Line + Format('%-12s', [GetEnumName(TypeInfo(TFieldType),
      Ord(ADataSet.FieldDefs[I].DataType))]);
  Writeln('  ', Line);
  Writeln('  ', StringOfChar('-', 12 * ADataSet.FieldDefs.Count));

  ADataSet.First;
  while not ADataSet.Eof do
  begin
    Line := '';
    for I := 0 to ADataSet.Fields.Count - 1 do
      Line := Line + Format('%-12s', [ADataSet.Fields[I].AsString]);
    Writeln('  ', Line);
    ADataSet.Next;
  end;
end;

var
  Entry: TEntry;
  Entries: array[0..2] of TEntry;
  FD: TFDMemTable;
  CDS: TClientDataSet;
  I: Integer;

begin
  Entry := NewEntry('ENT-1', 125.50, TStatus.Posted);
  Entries[0] := NewEntry('ENT-1', 125.50, TStatus.Posted);
  Entries[1] := NewEntry('ENT-2', 80.00, TStatus.Draft);
  Entries[2] := NewEntry('ENT-3', 12.25, TStatus.Posted);
  try
    { --- one object, into a dataset you already have --------------------- }
    FD := TFDMemTable.Create(nil);
    try
      TDataSetSerializer.CreateAndFill<TEntry>(Entry, FD);
      Dump('one object, existing dataset', FD);
    finally
      FD.Free;
    end;

    { --- the same DTO, the other dataset implementation ------------------ }
    CDS := TClientDataSet.Create(nil);
    try
      TDataSetSerializer.CreateAndFill<TEntry>(Entry, CDS);
      Dump('the same DTO, TClientDataSet', CDS);
    finally
      CDS.Free;
    end;

    { --- an array ------------------------------------------------------- }
    CDS := TClientDataSet.Create(nil);
    try
      TDataSetSerializer.CreateAndFill<TEntry>(Entries, CDS);
      Dump('an array of objects', CDS);
    finally
      CDS.Free;
    end;

    { --- no dataset yet: let the library make one ------------------------ }
    FD := TDataSetSerializer.CreateFDMemTable<TEntry>(Entries);
    try
      Dump('CreateFDMemTable, caller owns the result', FD);
    finally
      FD.Free;
    end;

    { --- schema and rows as separate steps ------------------------------- }
    FD := TFDMemTable.Create(nil);
    try
      TDataSetSerializer.CreateStructure<TEntry>(FD);
      for I := 0 to High(Entries) do
        TDataSetSerializer.Fill<TEntry>(Entries[I], FD);
      Dump('CreateStructure once, then Fill per object', FD);
    finally
      FD.Free;
    end;

    Writeln;
    Writeln('note: Reference became the REFERENCE column,');
    Writeln('      InternalNote is not a column at all,');
    Writeln('      and both dataset implementations produced the same shape.');
  finally
    for I := 0 to High(Entries) do Entries[I].Free;
    Entry.Free;
  end;
end.
