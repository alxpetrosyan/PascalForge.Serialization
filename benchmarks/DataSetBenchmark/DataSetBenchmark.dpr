program DataSetBenchmark;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Projection throughput, for both supported dataset implementations.

  This is not a contest between TFDMemTable and TClientDataSet: they have
  different internals and will not produce the same number. It is here so a
  regression in the projection path shows up as a change against the previous
  run of the SAME row. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Diagnostics, Data.DB, FireDAC.Comp.Client,
  Datasnap.DBClient,
  PascalForge.DataSet in '..\..\src\PascalForge.DataSet.pas';

const
  ROWS   = 5000;
  ROUNDS = 10;

type
  TStatus = (Draft, Posted, Closed);

  TEntry = class
  public
    Reference: string;
    Amount: Currency;
    Status: TStatus;
    Posted_: Boolean;
    Created: TDateTime;
    Note: string;
  end;

var
  Entries: array of TEntry;

procedure BuildRows;
var
  I: Integer;
begin
  SetLength(Entries, ROWS);
  for I := 0 to ROWS - 1 do
  begin
    Entries[I] := TEntry.Create;
    Entries[I].Reference := 'ENT-' + I.ToString;
    Entries[I].Amount := I * 1.25;
    Entries[I].Status := TStatus(I mod 3);
    Entries[I].Posted_ := Odd(I);
    Entries[I].Created := EncodeDate(2026, 3, 14);
    Entries[I].Note := 'row ' + I.ToString;
  end;
end;

procedure FreeRows;
var
  I: Integer;
begin
  for I := 0 to High(Entries) do Entries[I].Free;
  SetLength(Entries, 0);
end;

procedure Report(const AName: string; ARows: Integer; AElapsedMs: Double);
begin
  if AElapsedMs <= 0 then AElapsedMs := 0.001;
  Writeln(Format('%-16s %8d rows %9.1f ms %12.0f rows/sec',
    [AName, ARows, AElapsedMs, ARows / (AElapsedMs / 1000)]));
end;

procedure MeasureFireDac;
var
  Table: TFDMemTable;
  SW: TStopwatch;
  Round: Integer;
begin
  Table := TFDMemTable.Create(nil);
  try
    { Warm up: build the plan before the clock starts. }
    TDataSetSerializer.CreateAndFill<TEntry>(Entries, Table);

    SW := TStopwatch.StartNew;
    for Round := 1 to ROUNDS do
      TDataSetSerializer.CreateAndFill<TEntry>(Entries, Table);
    SW.Stop;
    Report('TFDMemTable', ROWS * ROUNDS, SW.Elapsed.TotalMilliseconds);
  finally
    Table.Free;
  end;
end;

procedure MeasureClientDataSet;
var
  Table: TClientDataSet;
  SW: TStopwatch;
  Round: Integer;
begin
  Table := TClientDataSet.Create(nil);
  try
    TDataSetSerializer.CreateAndFill<TEntry>(Entries, Table);

    SW := TStopwatch.StartNew;
    for Round := 1 to ROUNDS do
      TDataSetSerializer.CreateAndFill<TEntry>(Entries, Table);
    SW.Stop;
    Report('TClientDataSet', ROWS * ROUNDS, SW.Elapsed.TotalMilliseconds);
  finally
    Table.Free;
  end;
end;

begin
  Writeln('PascalForge DataSet projection benchmark');
  Writeln('  reference numbers for this machine; the two implementations are');
  Writeln('  not comparable to each other, only to their own previous runs');
  Writeln;

  BuildRows;
  try
    MeasureFireDac;
    MeasureClientDataSet;
  finally
    FreeRows;
  end;

  Writeln;
  Writeln('DATASET_BENCHMARK: DONE');
end.
