program XmlBenchmark;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ XML throughput, cold and warm, for spotting a regression.

  These numbers are a reference point on one machine with one model, not a
  claim about anything universal. What they are good for is noticing that an
  operation suddenly costs three times what it did last week.

  COLD is measured separately here, because "the first use of a type builds
  its plan" is a design claim and a claim deserves a number. The cold figure
  is one serialization of a type nothing has touched; the warm figures are
  the steady state after the plan exists.

  Three payload sizes, because a parser can be fast on small documents and
  quadratic on large ones, and only the second kind ruins an afternoon. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Diagnostics, System.Generics.Collections,
  PascalForge.Xml in '..\..\src\PascalForge.Xml.pas',
  PascalForge.Xml.Internal in '..\..\src\PascalForge.Xml.Internal.pas';

const
  ITERATIONS = 10000;
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

  TOrder = class
  private
    FShipTo: TAddress;
    FLines: TObjectList<TLine>;
  public
    Reference: string;
    Placed: TDateTime;
    Status: TStatus;
    Total: Currency;
    constructor Create;
    destructor Destroy; override;
    property ShipTo: TAddress read FShipTo;
    property Lines: TObjectList<TLine> read FLines;
  end;

  { A second type, structurally identical, used once and only once: the cold
    measurement needs a type whose plan does not exist yet. }
  TColdOrder = class(TOrder);

constructor TOrder.Create;
begin
  inherited Create;
  FShipTo := TAddress.Create;
  FLines := TObjectList<TLine>.Create(True);
end;

destructor TOrder.Destroy;
begin
  FLines.Free;
  FShipTo.Free;
  inherited Destroy;
end;

function NewOrder(ALines: Integer): TOrder;
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
  for I := 1 to ALines do
  begin
    Line := TLine.Create;
    Line.Sku := 'SKU-' + I.ToString;
    Line.Quantity := I;
    Line.Price := I * 10.25;
    Result.Lines.Add(Line);
  end;
end;

procedure Report(const AName: string; AIterations: Integer;
  AElapsedMs: Double; ABytes: Integer);
var
  PerSecond, MicrosPerOp: Double;
begin
  if AElapsedMs <= 0 then AElapsedMs := 0.001;
  PerSecond := AIterations / (AElapsedMs / 1000);
  MicrosPerOp := (AElapsedMs * 1000) / AIterations;
  Writeln(Format('%-18s %8d iterations %9.1f ms %12.0f ops/sec %8.2f us/op',
    [AName, AIterations, AElapsedMs, PerSecond, MicrosPerOp]));
  if ABytes > 0 then
    Writeln(Format('%-18s payload %d bytes', [' ', ABytes]));
end;

procedure MeasureSize(ALines, AIterations: Integer; const ALabel: string);
var
  Order, Restored: TOrder;
  Xml: string;
  SW: TStopwatch;
  I: Integer;
begin
  Order := NewOrder(ALines);
  try
    for I := 1 to WARMUP do
    begin
      Xml := TXmlSerializer.Serialize<TOrder>(Order);
      Restored := TXmlSerializer.Deserialize<TOrder>(Xml);
      Restored.Free;
    end;

    SW := TStopwatch.StartNew;
    for I := 1 to AIterations do
      Xml := TXmlSerializer.Serialize<TOrder>(Order);
    SW.Stop;
    Report(ALabel + ' serialize', AIterations, SW.Elapsed.TotalMilliseconds,
      Length(Xml));

    SW := TStopwatch.StartNew;
    for I := 1 to AIterations do
    begin
      Restored := TXmlSerializer.Deserialize<TOrder>(Xml);
      Restored.Free;
    end;
    SW.Stop;
    Report(ALabel + ' deserialize', AIterations,
      SW.Elapsed.TotalMilliseconds, 0);

    { The reader on its own, with no RTTI layer above it - so a parser
      regression cannot hide behind the mapper, or the other way round. }
    SW := TStopwatch.StartNew;
    for I := 1 to AIterations do
      TXmlEngine.ParseDocument(Xml).Free;
    SW.Stop;
    Report(ALabel + ' parse only', AIterations,
      SW.Elapsed.TotalMilliseconds, 0);
  finally
    Order.Free;
  end;
end;

var
  Cold: TColdOrder;
  SW: TStopwatch;
  Ignored: string;

begin
  Writeln('PascalForge XML benchmark');
  Writeln('  reference numbers for this machine, not a universal claim');
  Writeln;

  { COLD: one serialization of a type whose plan does not exist. Everything
    after this line is warm by definition. }
  Cold := TColdOrder(NewOrder(5));
  try
    SW := TStopwatch.StartNew;
    Ignored := TXmlSerializer.Serialize<TColdOrder>(Cold);
    SW.Stop;
    Report('cold plan build', 1, SW.Elapsed.TotalMilliseconds,
      Length(Ignored));
  finally
    Cold.Free;
  end;
  Writeln;

  MeasureSize(3, ITERATIONS, 'small ');
  Writeln;
  MeasureSize(50, ITERATIONS div 5, 'medium');
  Writeln;
  MeasureSize(2000, ITERATIONS div 200, 'large ');

  Writeln;
  Writeln('XML_BENCHMARK: DONE');
end.
