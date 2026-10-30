program Concurrency;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Many threads using the library at once, released together, each checking
  that it gets exactly what one thread alone would get.

  tests\Robustness already races the plan caches: a cold type, then warm
  round trips, one format at a time. This program covers what that does not:

  SHARED_SOURCE     One object, never written to, serialized by every
                    thread at once. Every payload is byte-for-byte the
                    payload one thread produced before the race - writing
                    reads the source and nothing else.

  MIXED_FORMATS     Every thread cycles through every format, each starting
                    at a different one, so different formats run side by
                    side over the same types. Each thread reads back its own
                    values.

  CYCLES            The record of objects "already being written" belongs to
                    one operation on one thread. A cycle written as null on
                    one thread, a diamond written twice on another, and a
                    cycle that raises on a third do not see each other - and
                    a raise leaves nothing behind for the next operation.

  REGISTERED_SERIALIZERS
                    Field overrides and type serializers, registered once at
                    startup and shared by every thread.

  DATASETS          DataSets with a nested table, written and read back on
                    every thread; and objects projected onto DataSets.

  CONVERSION        Document-to-document conversion through every structural
                    format, matching the single-thread result.

  Nothing built by any of it is left alive. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.JSON,
  System.Generics.Collections,
  Data.DB, FireDAC.Comp.Client,
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  PascalForge.Protobuf in '..\..\src\PascalForge.Protobuf.pas',
  PascalForge.DataSet in '..\..\src\PascalForge.DataSet.pas',
  AllFormatsRegistered in '..\Shared\AllFormatsRegistered.pas';

const
  THREAD_COUNT = 8;
  ITERATIONS = 60;

type
  { Counts its instances, so a leak on any thread shows. }
  TTracked = class
  public
    class var Live: Integer;
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;
  end;

  TCustomer = class(TTracked)
  public
    [ProtoField(1)] Code: Integer;
    [ProtoField(2)] Name: string;
  end;

  { Flat enough for CSV: scalars and one nested object. }
  TOrder = class(TTracked)
  public
    [ProtoField(1)] Id: Int64;
    [ProtoField(2)] Reference: string;
    [ProtoField(3)] Total: Currency;
    [ProtoField(4)] Placed: TDateTime;
    [ProtoField(5)] Paid: Boolean;
    [ProtoField(6)] Customer: TCustomer;
    constructor Create;
    destructor Destroy; override;
    procedure Fill(AThread, AIteration: Integer);
    function Matches(AThread, AIteration: Integer): Boolean;
  end;

  TLine = class(TTracked)
  public
    [ProtoField(1)] Sku: string;
    [ProtoField(2)] Quantity: Integer;
  end;

  { The containers, for every format but CSV. }
  TBasket = class(TTracked)
  public
    [ProtoField(1)] Owner: string;
    [ProtoField(2)] Lines: TObjectList<TLine>;
    [ProtoField(3)] Tags: TArray<string>;
    constructor Create;
    destructor Destroy; override;
    procedure Fill(AThread, AIteration: Integer);
    function Matches(AThread, AIteration: Integer): Boolean;
  end;

  { Written as null where it would repeat an object already being written. }
  TGraphNode = class(TTracked)
  public
    Name: string;
    Left: TGraphNode;
    Right: TGraphNode;
  end;

  { The library default for a cycle: raise. }
  TStrictNode = class(TTracked)
  public
    Name: string;
    Next: TStrictNode;
  end;

  TPoint2 = record
    X, Y: Integer;
  end;

  { A member with a field override, and a member whose type has a
    registered serializer. }
  TTagged = class(TTracked)
  public
    Code: string;
    At: TPoint2;
  end;

var
  GFailures: Integer = 0;

procedure TTracked.AfterConstruction;
begin
  inherited;
  TInterlocked.Increment(Live);
end;

procedure TTracked.BeforeDestruction;
begin
  TInterlocked.Decrement(Live);
  inherited;
end;

constructor TOrder.Create;
begin
  inherited Create;
  Customer := TCustomer.Create;
end;

destructor TOrder.Destroy;
begin
  Customer.Free;
  inherited;
end;

procedure TOrder.Fill(AThread, AIteration: Integer);
begin
  Id := Int64(AThread) * 1000000000 + AIteration;
  Reference := Format('T%d/I%d "q" <&> '#$00E9, [AThread, AIteration]);
  Total := AThread * 100 + AIteration + 0.25;
  Placed := EncodeDate(2026, 1 + AThread mod 12, 1 + AIteration mod 28) +
    EncodeTime(AThread mod 24, AIteration mod 60, 7, 0);
  Paid := Odd(AThread + AIteration);
  Customer.Code := AThread;
  Customer.Name := 'customer ' + IntToStr(AThread);
end;

function TOrder.Matches(AThread, AIteration: Integer): Boolean;
var
  Expected: TOrder;
begin
  Expected := TOrder.Create;
  try
    Expected.Fill(AThread, AIteration);
    Result := (Id = Expected.Id) and (Reference = Expected.Reference) and
      (Total = Expected.Total) and
      (Abs(Placed - Expected.Placed) < 1 / (24 * 3600)) and
      (Paid = Expected.Paid) and (Customer <> nil) and
      (Customer.Code = Expected.Customer.Code) and
      (Customer.Name = Expected.Customer.Name);
  finally
    Expected.Free;
  end;
end;

constructor TBasket.Create;
begin
  inherited Create;
  Lines := TObjectList<TLine>.Create(True);
end;

destructor TBasket.Destroy;
begin
  Lines.Free;
  inherited;
end;

procedure TBasket.Fill(AThread, AIteration: Integer);
var
  I: Integer;
  Line: TLine;
begin
  Owner := Format('owner %d/%d', [AThread, AIteration]);
  for I := 1 to 1 + AThread mod 4 do
  begin
    Line := TLine.Create;
    Line.Sku := Format('SKU-%d-%d', [AThread, I]);
    Line.Quantity := AIteration * 10 + I;
    Lines.Add(Line);
  end;
  Tags := ['t' + IntToStr(AThread), 'i' + IntToStr(AIteration)];
end;

function TBasket.Matches(AThread, AIteration: Integer): Boolean;
var
  I: Integer;
begin
  Result := (Owner = Format('owner %d/%d', [AThread, AIteration])) and
    (Lines.Count = 1 + AThread mod 4) and (Length(Tags) = 2) and
    (Tags[0] = 't' + IntToStr(AThread)) and
    (Tags[1] = 'i' + IntToStr(AIteration));
  if Result then
    for I := 0 to Lines.Count - 1 do
      if (Lines[I].Sku <> Format('SKU-%d-%d', [AThread, I + 1])) or
         (Lines[I].Quantity <> AIteration * 10 + I + 1) then
        Exit(False);
end;

{ ------------------------------------------------------------- harness --- }

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

function FmtKey(AFormat: TSerializationFormat): string;
begin
  Result := UpperCase(TSerialization.FormatName(AFormat));
end;

function SamePayload(const A, B: TSerializationPayload): Boolean;
var
  X, Y: TBytes;
begin
  if A.IsText <> B.IsText then Exit(False);
  if A.IsText then Exit(A.AsText = B.AsText);
  X := A.AsBytes;
  Y := B.AsBytes;
  Result := (Length(X) = Length(Y)) and
    ((Length(X) = 0) or CompareMem(@X[0], @Y[0], Length(X)));
end;

{ Runs AWork(ThreadIndex) on THREAD_COUNT threads released at the same
  moment. A worker reports a wrong answer by raising; the first message is
  returned, '' when every thread finished clean. }
function RunThreads(const AWork: TProc<Integer>): string;
var
  Threads: array[0..THREAD_COUNT - 1] of TThread;
  Go: TEvent;
  Lock: TCriticalSection;
  FirstError: string;
  I: Integer;

  function MakeWorker(AIndex: Integer): TThread;
  begin
    Result := TThread.CreateAnonymousThread(
      procedure
      begin
        Go.WaitFor(INFINITE);
        try
          AWork(AIndex);
        except
          on E: Exception do
          begin
            Lock.Enter;
            try
              if FirstError = '' then
                FirstError := Format('thread %d: %s: %s',
                  [AIndex, E.ClassName, E.Message]);
            finally
              Lock.Leave;
            end;
          end;
        end;
      end);
    Result.FreeOnTerminate := False;
  end;

begin
  FirstError := '';
  Go := TEvent.Create(nil, True, False, '');
  Lock := TCriticalSection.Create;
  try
    for I := 0 to THREAD_COUNT - 1 do
    begin
      Threads[I] := MakeWorker(I);
      Threads[I].Start;
    end;
    Go.SetEvent;
    for I := 0 to THREAD_COUNT - 1 do
    begin
      Threads[I].WaitFor;
      Threads[I].Free;
    end;
  finally
    Lock.Free;
    Go.Free;
  end;
  Result := FirstError;
end;

procedure Expect(ACondition: Boolean; const AWhat: string);
begin
  if not ACondition then raise Exception.Create(AWhat);
end;

{ ------------------------------------------------------- shared source --- }

procedure TestSharedSource;
var
  F: TSerializationFormat;
  Shared: TOrder;
  Basket: TBasket;
  RefOrder, RefBasket: TSerializationPayload;
  Detail: string;
  Rich: Boolean;
  Before: Integer;
begin
  Writeln;
  Writeln('-- SHARED_SOURCE: one object, every thread writing it --');
  Before := TTracked.Live;
  Shared := TOrder.Create;
  Basket := TBasket.Create;
  try
    Shared.Fill(3, 4);
    Basket.Fill(3, 4);
    for F in TSerialization.ContractFormats do
    begin
      Rich := F <> TSerializationFormat.Csv;
      RefOrder := TSerialization.Serialize<TOrder>(Shared, F);
      if Rich then RefBasket := TSerialization.Serialize<TBasket>(Basket, F);
      Detail := RunThreads(
        procedure(AIndex: Integer)
        var
          N: Integer;
        begin
          for N := 1 to ITERATIONS do
          begin
            Expect(SamePayload(TSerialization.Serialize<TOrder>(Shared, F),
              RefOrder), 'order payload differs from the single-thread one');
            if Rich then
              Expect(SamePayload(TSerialization.Serialize<TBasket>(Basket, F),
                RefBasket), 'basket payload differs from the single-thread one');
          end;
        end);
      Check((Detail = '') and Shared.Matches(3, 4) and Basket.Matches(3, 4),
        'SHARED_SOURCE_' + FmtKey(F));
      if Detail <> '' then Note(Detail);
    end;
  finally
    Basket.Free;
    Shared.Free;
  end;
  Check(TTracked.Live = Before, 'SHARED_SOURCE_NOTHING_LEFT_ALIVE');
end;

{ ------------------------------------------------------- mixed formats --- }

procedure TestMixedFormats;
var
  Formats: TArray<TSerializationFormat>;
  Detail: string;
  Before: Integer;
begin
  Writeln;
  Writeln('-- MIXED_FORMATS: every thread through every format, staggered --');
  Formats := TSerialization.ContractFormats;
  Before := TTracked.Live;
  Detail := RunThreads(
    procedure(AIndex: Integer)
    var
      N: Integer;
      F: TSerializationFormat;
      Order, OrderBack: TOrder;
      Basket, BasketBack: TBasket;
      P: TSerializationPayload;
    begin
      for N := 1 to ITERATIONS do
      begin
        F := Formats[(AIndex + N) mod Length(Formats)];
        Order := TOrder.Create;
        try
          Order.Fill(AIndex, N);
          P := TSerialization.Serialize<TOrder>(Order, F);
        finally
          Order.Free;
        end;
        OrderBack := TSerialization.Deserialize<TOrder>(P, F);
        try
          Expect(OrderBack.Matches(AIndex, N),
            TSerialization.FormatName(F) + ' read back another order');
        finally
          OrderBack.Free;
        end;

        if F = TSerializationFormat.Csv then Continue;
        Basket := TBasket.Create;
        try
          Basket.Fill(AIndex, N);
          P := TSerialization.Serialize<TBasket>(Basket, F);
        finally
          Basket.Free;
        end;
        BasketBack := TSerialization.Deserialize<TBasket>(P, F);
        try
          Expect(BasketBack.Matches(AIndex, N),
            TSerialization.FormatName(F) + ' read back another basket');
        finally
          BasketBack.Free;
        end;
      end;
    end);
  Check(Detail = '', 'MIXED_FORMATS_OWN_VALUES');
  if Detail <> '' then Note(Detail);
  Check(TTracked.Live = Before, 'MIXED_FORMATS_NOTHING_LEFT_ALIVE');
end;

{ -------------------------------------------------------------- cycles --- }

{ Root.Left and Root.Right are the same node: a diamond, written twice.
  That node's Left is Root: a cycle, written as null. }
function NewDiamond(const ATag: string): TGraphNode;
var
  Shared: TGraphNode;
begin
  Result := TGraphNode.Create;
  Result.Name := 'root ' + ATag;
  Shared := TGraphNode.Create;
  Shared.Name := 'shared ' + ATag;
  Shared.Left := Result;
  Result.Left := Shared;
  Result.Right := Shared;
end;

procedure FreeDiamond(ARoot: TGraphNode);
begin
  ARoot.Left.Free;
  ARoot.Free;
end;

function ExpectedDiamond(const ATag: string): string;
var
  Root: TGraphNode;
begin
  Root := NewDiamond(ATag);
  try
    Result := TJsonSerializer.Serialize<TGraphNode>(Root);
  finally
    FreeDiamond(Root);
  end;
end;

procedure TestCycles;
var
  Sample, Detail: string;
  Before: Integer;
begin
  Writeln;
  Writeln('-- CYCLES: what is being written belongs to one operation --');
  Before := TTracked.Live;
  Sample := ExpectedDiamond('x');
  Note(Sample);
  Check(Sample.Contains('"left":null') and
    (Sample.IndexOf('"name":"shared x"') <>
     Sample.LastIndexOf('"name":"shared x"')),
    'CYCLES_SINGLE_THREAD_SHAPE');

  Detail := RunThreads(
    procedure(AIndex: Integer)
    var
      N: Integer;
      Tag, Expected, Json: string;
      Root: TGraphNode;
      A, B: TStrictNode;
      Raised: Boolean;
    begin
      Tag := IntToStr(AIndex);
      Expected := ExpectedDiamond(Tag);
      for N := 1 to ITERATIONS do
      begin
        { Every third operation on every thread is a cycle the library
          refuses. Whatever it had recorded must be gone when it raises. }
        if (N + AIndex) mod 3 = 0 then
        begin
          A := TStrictNode.Create;
          B := TStrictNode.Create;
          try
            A.Name := 'a';
            B.Name := 'b';
            A.Next := B;
            B.Next := A;
            Raised := False;
            try
              TJsonSerializer.Serialize<TStrictNode>(A);
            except
              on E: EJsonError do Raised := True;
            end;
            Expect(Raised, 'a cycle under the Error policy was written');
          finally
            B.Free;
            A.Free;
          end;
        end;

        Root := NewDiamond(Tag);
        try
          Json := TJsonSerializer.Serialize<TGraphNode>(Root);
        finally
          FreeDiamond(Root);
        end;
        Expect(Json = Expected, 'diamond written as ' + Json);
      end;
    end);
  Check(Detail = '', 'CYCLES_TRACKED_PER_OPERATION');
  if Detail <> '' then Note(Detail);
  Check(TTracked.Live = Before, 'CYCLES_NOTHING_LEFT_ALIVE');
end;

{ ------------------------------------------------ registered serializers --- }

procedure TestRegisteredSerializers;
var
  Detail: string;
  Before: Integer;
begin
  Writeln;
  Writeln('-- REGISTERED_SERIALIZERS: one registration, every thread --');
  Before := TTracked.Live;
  Detail := RunThreads(
    procedure(AIndex: Integer)
    var
      N: Integer;
      Tagged, Back: TTagged;
      Json: string;
    begin
      for N := 1 to ITERATIONS do
      begin
        Tagged := TTagged.Create;
        try
          Tagged.Code := Format('c%d.%d', [AIndex, N]);
          Tagged.At.X := AIndex;
          Tagged.At.Y := N;
          Json := TJsonSerializer.Serialize<TTagged>(Tagged);
        finally
          Tagged.Free;
        end;
        Expect(Json.Contains(Format('"code":"T/c%d.%d"', [AIndex, N])) and
          Json.Contains(Format('"at":"%d,%d"', [AIndex, N])),
          'written as ' + Json);
        Back := TJsonSerializer.Deserialize<TTagged>(Json);
        try
          Expect((Back.Code = Format('c%d.%d', [AIndex, N])) and
            (Back.At.X = AIndex) and (Back.At.Y = N), 'read back wrong');
        finally
          Back.Free;
        end;
      end;
    end);
  Check(Detail = '', 'REGISTERED_SERIALIZERS_SHARED');
  if Detail <> '' then Note(Detail);
  Check(TTracked.Live = Before, 'REGISTERED_SERIALIZERS_NOTHING_LEFT_ALIVE');
end;

{ ------------------------------------------------------------ datasets --- }

{ Id, Name and a nested table of lines; the child schema is defined through
  ChildDefs, before the DataSet is created. }
function NewNestedTable(AThread, AIteration: Integer): TFDMemTable;
var
  Def: TFieldDef;
  Lines: TDataSet;
  I: Integer;
begin
  Result := TFDMemTable.Create(nil);
  try
    Result.FieldDefs.Add('Id', ftInteger);
    Result.FieldDefs.Add('Name', ftWideString, 40);
    Def := Result.FieldDefs.AddFieldDef;
    Def.Name := 'Lines';
    Def.DataType := ftDataSet;
    Def.ChildDefs.Add('Sku', ftWideString, 20);
    Def.ChildDefs.Add('Quantity', ftInteger);
    Result.CreateDataSet;
    Result.Append;
    Result.FieldByName('Id').AsInteger := AThread * 1000 + AIteration;
    Result.FieldByName('Name').AsString := 'thread ' + IntToStr(AThread);
    Lines := TDataSetField(Result.FieldByName('Lines')).NestedDataSet;
    for I := 1 to 1 + AThread mod 3 do
    begin
      Lines.Append;
      Lines.FieldByName('Sku').AsString := Format('S%d-%d', [AThread, I]);
      Lines.FieldByName('Quantity').AsInteger := AIteration + I;
      Lines.Post;
    end;
    Result.Post;
  except
    Result.Free;
    raise;
  end;
end;

function NestedTableMatches(ADataSet: TDataSet;
  AThread, AIteration: Integer): Boolean;
var
  Lines: TDataSet;
  I: Integer;
begin
  ADataSet.First;
  Lines := TDataSetField(ADataSet.FieldByName('Lines')).NestedDataSet;
  Result := (ADataSet.RecordCount = 1) and
    (ADataSet.FieldByName('Id').AsInteger = AThread * 1000 + AIteration) and
    (ADataSet.FieldByName('Name').AsString = 'thread ' + IntToStr(AThread)) and
    (Lines.RecordCount = 1 + AThread mod 3);
  if not Result then Exit;
  Lines.First;
  for I := 1 to 1 + AThread mod 3 do
  begin
    if (Lines.FieldByName('Sku').AsString <> Format('S%d-%d', [AThread, I])) or
       (Lines.FieldByName('Quantity').AsInteger <> AIteration + I) then
      Exit(False);
    Lines.Next;
  end;
end;

procedure TestDataSets;
var
  Detail: string;
  Before: Integer;
begin
  Writeln;
  Writeln('-- DATASETS: nested tables and projections on every thread --');
  Before := TTracked.Live;
  Detail := RunThreads(
    procedure(AIndex: Integer)
    var
      N: Integer;
      Source, Back, Projected: TFDMemTable;
      Text: string;
      Order: TOrder;
    begin
      for N := 1 to ITERATIONS div 2 do
      begin
        Source := NewNestedTable(AIndex, N);
        try
          Text := TDataSetSerializer.Serialize(Source, TSerializationFormat.Json,
            TDataSetSerializationPolicy.StructureAndRows).AsText;
        finally
          Source.Free;
        end;
        Back := TFDMemTable.Create(nil);
        try
          TDataSetSerializer.Deserialize(Text, TSerializationFormat.Json, Back);
          Expect(NestedTableMatches(Back, AIndex, N),
            'nested table read back wrong: ' + Text);
        finally
          Back.Free;
        end;

        Projected := TFDMemTable.Create(nil);
        Order := TOrder.Create;
        try
          Order.Fill(AIndex, N);
          TDataSetSerializer.CreateStructure<TOrder>(Projected);
          TDataSetSerializer.Fill<TOrder>(Order, Projected);
          Projected.First;
          Expect((Projected.RecordCount = 1) and
            (Projected.FieldByName('Id').AsLargeInt = Order.Id) and
            (Projected.FieldByName('Reference').AsString = Order.Reference),
            'projection wrote another order');
        finally
          Order.Free;
          Projected.Free;
        end;
      end;
    end);
  Check(Detail = '', 'DATASETS_NESTED_ROUND_TRIP_AND_PROJECTION');
  if Detail <> '' then Note(Detail);
  Check(TTracked.Live = Before, 'DATASETS_NOTHING_LEFT_ALIVE');
end;

{ ---------------------------------------------------------- conversion --- }

procedure TestConversion;
var
  Formats: TArray<TSerializationFormat>;
  Sources: array[0..THREAD_COUNT - 1] of TSerializationPayload;
  Expected: array[0..THREAD_COUNT - 1] of TArray<TSerializationPayload>;
  Order: TOrder;
  I, J: Integer;
  Detail: string;
begin
  Writeln;
  Writeln('-- CONVERSION: JSON to every structural format, on every thread --');
  Formats := TSerialization.StructuralFormats;
  { The single-thread answers, first. }
  for I := 0 to THREAD_COUNT - 1 do
  begin
    Order := TOrder.Create;
    try
      Order.Fill(I, 1);
      Sources[I] := TSerialization.Serialize<TOrder>(Order,
        TSerializationFormat.Json);
    finally
      Order.Free;
    end;
    SetLength(Expected[I], Length(Formats));
    for J := 0 to High(Formats) do
      Expected[I][J] := TSerialization.Convert(Sources[I],
        TSerializationFormat.Json, Formats[J]);
  end;

  Detail := RunThreads(
    procedure(AIndex: Integer)
    var
      N, K: Integer;
      Converted: TSerializationPayload;
    begin
      for N := 1 to ITERATIONS div 4 do
        for K := 0 to High(Formats) do
        begin
          Converted := TSerialization.Convert(Sources[AIndex],
            TSerializationFormat.Json, Formats[K]);
          Expect(SamePayload(Converted, Expected[AIndex][K]),
            'JSON to ' + TSerialization.FormatName(Formats[K]) +
            ' differs from the single-thread conversion');
        end;
    end);
  Check(Detail = '', 'CONVERSION_MATCHES_SINGLE_THREAD');
  if Detail <> '' then Note(Detail);
end;

{ -------------------------------------------------------------- main --- }

{ Every registration, before anything is serialized: configuration freezes
  at first use. }
procedure Configure;
begin
  TJsonSerializer.RegisterTypeRecursiveReferencePolicy<TGraphNode>(
    TJsonRecursiveReferencePolicy.WriteNull);
  TJsonSerializer.RegisterFieldOverride<TTagged>('Code',
    TJsonFieldOverride.SerializeWith<string>(
      function(const AValue: string): TJSONValue
      begin
        Result := TJSONString.Create('T/' + AValue);
      end,
      function(const AJson: TJSONValue): string
      begin
        Result := AJson.Value.Substring(2);
      end));
  TJsonSerializer.RegisterTypeSerializer<TPoint2>(
    function(const AValue: TPoint2): TJSONValue
    begin
      Result := TJSONString.Create(Format('%d,%d', [AValue.X, AValue.Y]));
    end,
    function(const AJson: TJSONValue): TPoint2
    var
      Parts: TArray<string>;
    begin
      Parts := AJson.Value.Split([',']);
      Result.X := StrToInt(Parts[0]);
      Result.Y := StrToInt(Parts[1]);
    end);
end;

begin
  try
    Configure;
    TestSharedSource;
    TestMixedFormats;
    TestCycles;
    TestRegisteredSerializers;
    TestDataSets;
    TestConversion;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then
    Writeln('CONCURRENCY: PASS')
  else
  begin
    Writeln('CONCURRENCY: FAIL');
    ExitCode := 1;
  end;
end.
