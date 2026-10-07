program JsonBenchmark;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Warm JSON throughput, for spotting a regression.

  These numbers are a reference point on one machine with one model, not a
  claim about anything universal. What they are good for is noticing that an
  operation suddenly costs three times what it did last week.

  Plan building is deliberately excluded: the first serialization of a type
  discovers its RTTI and caches an execution plan, so a run that included it
  would be measuring startup rather than steady state. The warm-up below pays
  that cost before the clock starts. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Diagnostics, System.Generics.Collections,
  PascalForge.Json in '..\..\src\PascalForge.Json.pas';

const
  ITERATIONS = 20000;
  WARMUP     = 100;

type
  TStatus = (Draft, Active, Closed);

  TAddress = class
  public
    City: string;
    Zip: string;
    Country: string;
  end;

  TLine = class
  public
    Sku: string;
    Quantity: Integer;
    Price: Currency;
  end;

  { Deep enough to exercise nesting, a list and a dictionary; small enough
    that the numbers are about the engine, not about one enormous payload. }
  TOrder = class
  private
    FShipTo: TAddress;
    FLines: TObjectList<TLine>;
    FLabels: TDictionary<string, string>;
  public
    Reference: string;
    Placed: TDateTime;
    Status: TStatus;
    Total: Currency;
    constructor Create;
    destructor Destroy; override;
    property ShipTo: TAddress read FShipTo;
    property Lines: TObjectList<TLine> read FLines;
    property Labels: TDictionary<string, string> read FLabels;
  end;

constructor TOrder.Create;
begin
  inherited Create;
  FShipTo := TAddress.Create;
  FLines := TObjectList<TLine>.Create(True);
  FLabels := TDictionary<string, string>.Create;
end;

destructor TOrder.Destroy;
begin
  FLabels.Free;
  FLines.Free;
  FShipTo.Free;
  inherited Destroy;
end;

function NewOrder: TOrder;
var
  I: Integer;
  Line: TLine;
begin
  Result := TOrder.Create;
  Result.Reference := 'ORD-00042';
  Result.Placed := EncodeDate(2026, 3, 14) + EncodeTime(9, 30, 0, 0);
  Result.Status := TStatus.Active;
  Result.Total := 1250.75;
  Result.ShipTo.City := 'Midtown';
  Result.ShipTo.Zip := '12345';
  Result.ShipTo.Country := 'GE';
  for I := 1 to 5 do
  begin
    Line := TLine.Create;
    Line.Sku := 'SKU-' + I.ToString;
    Line.Quantity := I;
    Line.Price := I * 10.25;
    Result.Lines.Add(Line);
  end;
  Result.Labels.Add('channel', 'web');
  Result.Labels.Add('priority', 'normal');
end;

procedure Report(const AName: string; AIterations: Integer;
  AElapsedMs: Double; ABytes: Integer);
var
  PerSecond, MicrosPerOp: Double;
begin
  if AElapsedMs <= 0 then AElapsedMs := 0.001;
  PerSecond := AIterations / (AElapsedMs / 1000);
  MicrosPerOp := (AElapsedMs * 1000) / AIterations;
  Writeln(Format('%-14s %8d iterations %9.1f ms %12.0f ops/sec %8.2f us/op',
    [AName, AIterations, AElapsedMs, PerSecond, MicrosPerOp]));
  if ABytes > 0 then
    Writeln(Format('%-14s payload %d bytes', [' ', ABytes]));
end;

var
  Order, Restored: TOrder;
  Json: string;
  SW: TStopwatch;
  I: Integer;

begin
  Writeln('PascalForge JSON benchmark');
  Writeln('  reference numbers for this machine, not a universal claim');
  Writeln;

  Order := NewOrder;
  try
    { Warm up: build the plan, resolve the serializers, touch the code paths
      once, so the measured loop is steady state only. }
    for I := 1 to WARMUP do
    begin
      Json := TJsonSerializer.Serialize(Order);
      Restored := TJsonSerializer.Deserialize<TOrder>(Json);
      Restored.Free;
    end;

    SW := TStopwatch.StartNew;
    for I := 1 to ITERATIONS do
      Json := TJsonSerializer.Serialize(Order);
    SW.Stop;
    Report('Serialize<T>', ITERATIONS, SW.Elapsed.TotalMilliseconds, Length(Json));

    SW := TStopwatch.StartNew;
    for I := 1 to ITERATIONS do
    begin
      Restored := TJsonSerializer.Deserialize<TOrder>(Json);
      Restored.Free;
    end;
    SW.Stop;
    Report('Deserialize<T>', ITERATIONS, SW.Elapsed.TotalMilliseconds, 0);

    SW := TStopwatch.StartNew;
    for I := 1 to ITERATIONS do
      TJsonSerializer.Populate(Order, Json);
    SW.Stop;
    Report('Populate', ITERATIONS, SW.Elapsed.TotalMilliseconds, 0);
  finally
    Order.Free;
  end;

  Writeln;
  Writeln('JSON_BENCHMARK: DONE');
end.
