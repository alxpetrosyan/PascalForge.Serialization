program ContractMatrix;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ THE CONTRACT-AWARE MATRIX, which is a different question from the structural
  one and had been measured as if it were the same.

  A structural conversion moves a DOCUMENT. It has no Delphi type, so the two
  ends must agree about names and about what a list looks like, and when they
  do not - JSON renames a member for the wire, XML wraps a list, BSON writes a
  Currency as the scaled integer it really is - the hand-off cannot work and
  the library says so.

  A CONTRACT-AWARE conversion moves a VALUE:

      Format A payload
         |  Deserialize<T>      A's attributes apply
      a Delphi T
         |  Serialize<T>        B's attributes apply
      Format B payload

  There is no document in the middle. The Delphi type supplies every name and
  every type on both sides, so none of those disagreements can reach it. A
  member renamed by nine formats to nine different names still arrives; a
  wrapped XML list still arrives as a list; a scaled-integer Currency still
  arrives as 1234.56.

  So on this path there are no representation refusals to report, and anything
  that does not carry is a defect in this library. That is what this program
  asserts, pair by pair, over every format that can do contract work at all. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Math, System.DateUtils,
  System.TypInfo, System.Generics.Collections,
  ContractMatrixModels in 'ContractMatrixModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  AllFormatsRegistered in '..\Shared\AllFormatsRegistered.pas';

var
  GFailures: Integer = 0;
  GChecks: Integer = 0;
  GReport: TStringList;

procedure Check(ACondition: Boolean; const AName: string);
begin
  Inc(GChecks);
  if ACondition then Writeln(AName, ': PASS')
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

function Name(AFormat: TSerializationFormat): string;
begin
  Result := TSerializationFormats.FormatName(AFormat);
end;

{ ===========================================================================
  THE VALUES

  Chosen so that a format which quietly changed one would be caught: a
  Currency with four decimals that a Double cannot hold exactly, an Int64
  past the range a Double represents, a moment with milliseconds, an enum
  that is not the first member.
  =========================================================================== }

const
  ORDER_ID   = Int64(4611686018427387903);
  REFERENCE  = 'ORD-0007';
  TOTAL      = Currency(1234.5678);
  RATE       = Double(1.5);
  LINE_PRICE = Currency(19.5001);

function NewOrder: TProbeOrder;
var
  Line: TProbeLine;
begin
  Result := TProbeOrder.Create;
  Result.OrderId := ORDER_ID;
  Result.Reference := REFERENCE;
  Result.Total := TOTAL;
  Result.Rate := RATE;
  Result.Active := True;
  Result.Flavour := TProbeFlavour.Special;
  Result.Placed := EncodeDateTime(2026, 9, 22, 14, 35, 0, 0);

  Line := TProbeLine.Create;
  Line.Sku := 'SKU-1';
  Line.Quantity := 2;
  Line.UnitPrice := LINE_PRICE;
  Result.Lines.Add(Line);

  Line := TProbeLine.Create;
  Line.Sku := 'SKU-2';
  Line.Quantity := 5;
  Line.UnitPrice := Currency(4.25);
  Result.Lines.Add(Line);

  Result.Shipper.Name := 'Alice';
  Result.Shipper.City := 'Midtown';
end;

function NewRow: TProbeRow;
begin
  Result := TProbeRow.Create;
  Result.Id := ORDER_ID;
  Result.Label_ := 'LBL-1';
  Result.Amount := TOTAL;
  Result.Ratio := RATE;
  Result.Ok := True;
  Result.When := EncodeDateTime(2026, 9, 22, 14, 35, 0, 0);
end;

{ A Currency is an exact scaled integer, so it is compared as one. Comparing
  it as a float is how a library convinces itself it kept four decimals. }
function SameMoney(const A, B: Currency): Boolean;
begin
  Result := PInt64(@A)^ = PInt64(@B)^;
end;

function SameOrder(A, B: TProbeOrder; out AWhere: string): Boolean;
var
  I: Integer;
begin
  AWhere := '';
  if B = nil then begin AWhere := 'nil'; Exit(False); end;
  if A.OrderId <> B.OrderId then
    begin AWhere := Format('OrderId %d <> %d', [A.OrderId, B.OrderId]); Exit(False); end;
  if A.Reference <> B.Reference then
    begin AWhere := 'Reference "' + A.Reference + '" <> "' + B.Reference + '"'; Exit(False); end;
  if not SameMoney(A.Total, B.Total) then
    begin AWhere := Format('Total %s <> %s',
      [CurrToStr(A.Total, TFormatSettings.Invariant),
       CurrToStr(B.Total, TFormatSettings.Invariant)]); Exit(False); end;
  if not SameValue(A.Rate, B.Rate, 1E-12) then
    begin AWhere := 'Rate'; Exit(False); end;
  if A.Active <> B.Active then begin AWhere := 'Active'; Exit(False); end;
  if A.Flavour <> B.Flavour then begin AWhere := 'Flavour'; Exit(False); end;
  if not SameValue(A.Placed, B.Placed, 1E-6) then
    begin AWhere := Format('Placed %s <> %s',
      [DateTimeToStr(A.Placed), DateTimeToStr(B.Placed)]); Exit(False); end;

  if (A.Lines = nil) <> (B.Lines = nil) then
    begin AWhere := 'Lines (nil)'; Exit(False); end;
  if A.Lines <> nil then
  begin
    if A.Lines.Count <> B.Lines.Count then
      begin AWhere := Format('Lines.Count %d <> %d',
        [A.Lines.Count, B.Lines.Count]); Exit(False); end;
    for I := 0 to A.Lines.Count - 1 do
    begin
      if A.Lines[I].Sku <> B.Lines[I].Sku then
        begin AWhere := Format('Lines[%d].Sku', [I]); Exit(False); end;
      if A.Lines[I].Quantity <> B.Lines[I].Quantity then
        begin AWhere := Format('Lines[%d].Quantity', [I]); Exit(False); end;
      if not SameMoney(A.Lines[I].UnitPrice, B.Lines[I].UnitPrice) then
        begin AWhere := Format('Lines[%d].UnitPrice', [I]); Exit(False); end;
    end;
  end;

  if (A.Shipper = nil) <> (B.Shipper = nil) then
    begin AWhere := 'Shipper (nil)'; Exit(False); end;
  if A.Shipper <> nil then
  begin
    if A.Shipper.Name <> B.Shipper.Name then begin AWhere := 'Shipper.Name'; Exit(False); end;
    if A.Shipper.City <> B.Shipper.City then begin AWhere := 'Shipper.City'; Exit(False); end;
  end;
  Result := True;
end;

function SameRow(A, B: TProbeRow; out AWhere: string): Boolean;
begin
  AWhere := '';
  if B = nil then begin AWhere := 'nil'; Exit(False); end;
  if A.Id <> B.Id then
    begin AWhere := Format('Id %d <> %d', [A.Id, B.Id]); Exit(False); end;
  if A.Label_ <> B.Label_ then begin AWhere := 'Label'; Exit(False); end;
  if not SameMoney(A.Amount, B.Amount) then
    begin AWhere := Format('Amount %s <> %s',
      [CurrToStr(A.Amount, TFormatSettings.Invariant),
       CurrToStr(B.Amount, TFormatSettings.Invariant)]); Exit(False); end;
  if not SameValue(A.Ratio, B.Ratio, 1E-12) then begin AWhere := 'Ratio'; Exit(False); end;
  if A.Ok <> B.Ok then begin AWhere := 'Ok'; Exit(False); end;
  if not SameValue(A.When, B.When, 1E-6) then begin AWhere := 'When'; Exit(False); end;
  Result := True;
end;

{ ===========================================================================
  ONE HAND-OFF

  Serialize with A's contract, convert through the Delphi value, deserialize
  with B's contract. Exactly TSerialization.Convert<T>, which is the API an
  application calls.
  =========================================================================== }

type
  TOutcome = (Carried, Refused, Failed);

function IsLibraryRefusal(E: Exception): Boolean;
begin
  { A refusal has to be this library saying so, deliberately. An RTL exception
    out of the middle of a writer is a defect wearing a polite message. }
  Result := (E is ESerializationFormatCapability) or
            (E is ESerializationSchemaRequired) or
            (E is ESerializationPayloadKind) or
            (E is ESerializationFormatNotRegistered) or
            (E is EStructuralConversionError) or
            (Pos('PascalForge', E.UnitName) > 0) or
            (E.ClassName.StartsWith('ECsv')) or
            (E.ClassName.StartsWith('EJson')) or
            (E.ClassName.StartsWith('EXml')) or
            (E.ClassName.StartsWith('EBson')) or
            (E.ClassName.StartsWith('ECbor')) or
            (E.ClassName.StartsWith('EMessagePack')) or
            (E.ClassName.StartsWith('EYaml')) or
            (E.ClassName.StartsWith('EAvro')) or
            (E.ClassName.StartsWith('EAsn1')) or
            (E.ClassName.StartsWith('EProtobuf'));
end;

function OrderPair(A, B: TSerializationFormat; out ADetail: string): TOutcome;
var
  Source: TProbeOrder;
  Back: TProbeOrder;
  PayloadA, PayloadB: TSerializationPayload;
  Where: string;
begin
  ADetail := '';
  Source := NewOrder;
  Back := nil;
  try
    try
      PayloadA := TSerialization.Serialize<TProbeOrder>(Source, A);
      PayloadB := TSerialization.Convert<TProbeOrder>(PayloadA, A, B);
      Back := TSerialization.Deserialize<TProbeOrder>(PayloadB, B);
    except
      on E: Exception do
      begin
        ADetail := E.ClassName + ': ' + E.Message;
        if IsLibraryRefusal(E) then Exit(TOutcome.Refused);
        Exit(TOutcome.Failed);
      end;
    end;
    if SameOrder(Source, Back, Where) then Exit(TOutcome.Carried);
    ADetail := Where;
    Result := TOutcome.Failed;
  finally
    Back.Free;
    Source.Free;
  end;
end;

function RowPair(A, B: TSerializationFormat; out ADetail: string): TOutcome;
var
  Source, Back: TProbeRow;
  PayloadA, PayloadB: TSerializationPayload;
  Where: string;
begin
  ADetail := '';
  Source := NewRow;
  Back := nil;
  try
    try
      PayloadA := TSerialization.Serialize<TProbeRow>(Source, A);
      PayloadB := TSerialization.Convert<TProbeRow>(PayloadA, A, B);
      Back := TSerialization.Deserialize<TProbeRow>(PayloadB, B);
    except
      on E: Exception do
      begin
        ADetail := E.ClassName + ': ' + E.Message;
        if IsLibraryRefusal(E) then Exit(TOutcome.Refused);
        Exit(TOutcome.Failed);
      end;
    end;
    if SameRow(Source, Back, Where) then Exit(TOutcome.Carried);
    ADetail := Where;
    Result := TOutcome.Failed;
  finally
    Back.Free;
    Source.Free;
  end;
end;

{ ===========================================================================
  THE NINE NAMED PROBES

  Each is one pair chosen because it is exactly the disagreement a structural
  conversion cannot bridge - and the contract path has to.
  =========================================================================== }

procedure Probe(AName: string; A, B: TSerializationFormat; ARow: Boolean);
var
  Outcome: TOutcome;
  Detail: string;
begin
  if ARow then Outcome := RowPair(A, B, Detail)
  else Outcome := OrderPair(A, B, Detail);
  if Outcome <> TOutcome.Carried then Note(Detail);
  Check(Outcome = TOutcome.Carried, AName);
end;

procedure TestNamedProbes;
begin
  Writeln;
  Writeln('-- the disagreements a contract hand-off must not notice --');

  { Every member of the model is renamed differently by JSON and by XML. If
    the hand-off went through a document, none of them would match. }
  Probe('JSON_RENAMED_MEMBER_TO_XML_CONTRACT',
    TSerializationFormat.Json, TSerializationFormat.Xml, False);
  Probe('XML_RENAMED_MEMBER_TO_JSON_CONTRACT',
    TSerializationFormat.Xml, TSerializationFormat.Json, False);

  { XML wraps a list in an element named after the member; JSON writes a bare
    array. Both are right, and the contract knows which is which. }
  Probe('XML_WRAPPED_LIST_TO_JSON_CONTRACT',
    TSerializationFormat.Xml, TSerializationFormat.Json, False);
  Probe('JSON_LIST_TO_XML_CONTRACT',
    TSerializationFormat.Json, TSerializationFormat.Xml, False);

  { BSON writes a Currency as the scaled Int64 Delphi stores. On a document
    path that reads as twelve million; on this path it is 1234.5678. }
  Probe('BSON_CURRENCY_TO_JSON_CONTRACT',
    TSerializationFormat.Bson, TSerializationFormat.Json, False);
  Probe('JSON_CURRENCY_TO_BSON_CONTRACT',
    TSerializationFormat.Json, TSerializationFormat.Bson, False);
  Probe('MESSAGEPACK_CURRENCY_TO_XML_CONTRACT',
    TSerializationFormat.MessagePack, TSerializationFormat.Xml, False);

  { CSV writes every cell as text. The destination's contract types it again,
    so an Int64 is an Int64 on the far side. }
  Probe('CSV_SCALAR_TYPED_TO_JSON_CONTRACT',
    TSerializationFormat.Csv, TSerializationFormat.Json, True);
  Probe('JSON_SCALAR_TYPED_TO_CSV_CONTRACT',
    TSerializationFormat.Json, TSerializationFormat.Csv, True);
end;

{ ===========================================================================
  AND EVERY PAIR

  From the registry, so a format added later is in the matrix with no edit
  here. Two corpora: a graph, which CSV declines under its conservative
  default, and a flat row, which nothing may decline.
  =========================================================================== }

procedure RunMatrix(const ATitle: string; ARow: Boolean;
  out ACarried, ARefused, AFailed: Integer);
var
  A, B: TSerializationFormat;
  Formats: TArray<TSerializationFormat>;
  I, J: Integer;
  Outcome: TOutcome;
  Detail, Row: string;
begin
  ACarried := 0; ARefused := 0; AFailed := 0;
  Formats := TSerialization.ContractFormats;

  Writeln;
  Writeln('-- ', ATitle, ' --');
  GReport.Add('### ' + ATitle);
  GReport.Add('');
  Row := '| from \ to |';
  for B in Formats do Row := Row + ' ' + Name(B) + ' |';
  GReport.Add(Row);
  Row := '| --- |';
  for B in Formats do Row := Row + ' --- |';
  GReport.Add(Row);

  for I := 0 to High(Formats) do
  begin
    A := Formats[I];
    Row := '| ' + Name(A) + ' |';
    for J := 0 to High(Formats) do
    begin
      B := Formats[J];
      if I = J then begin Row := Row + ' - |'; Continue; end;
      if ARow then Outcome := RowPair(A, B, Detail)
      else Outcome := OrderPair(A, B, Detail);
      case Outcome of
        TOutcome.Carried:
          begin Inc(ACarried); Row := Row + ' ok |'; end;
        TOutcome.Refused:
          begin
            Inc(ARefused);
            Row := Row + ' refused |';
            Writeln(Format('  %-12s -> %-12s REFUSED  %s',
              [Name(A), Name(B), Copy(Detail, 1, 150)]));
          end;
      else
        Inc(AFailed);
        Row := Row + ' **FAILED** |';
        Writeln(Format('  %-12s -> %-12s FAILED   %s',
          [Name(A), Name(B), Copy(Detail, 1, 200)]));
      end;
    end;
    GReport.Add(Row);
  end;
  GReport.Add('');
  Writeln(Format('  carried=%d refused=%d failed=%d',
    [ACarried, ARefused, AFailed]));
end;

var
  GraphCarried, GraphRefused, GraphFailed: Integer;
  FlatCarried, FlatRefused, FlatFailed: Integer;
  Formats: TArray<TSerializationFormat>;
begin
  GReport := TStringList.Create;
  try
    try
      Formats := TSerialization.ContractFormats;
      Writeln('-- contract-capable formats, from the registry --');
      Note(IntToStr(Length(Formats)) + ' of them');
      Check(Length(Formats) >= 10, 'CONTRACT_MATRIX_HAS_SOMETHING_TO_COMPARE');

      GReport.Add('# Contract-aware conversion matrix');
      GReport.Add('');
      GReport.Add('Generated by `tests\ContractMatrix`. Every contract-capable');
      GReport.Add('format against every other, through `TSerialization.Convert<T>`:');
      GReport.Add('deserialize with the source format''s contract, serialize with');
      GReport.Add('the destination''s. No document passes between them, so wire');
      GReport.Add('naming and wire representation cannot affect the result.');
      GReport.Add('');

      TestNamedProbes;

      RunMatrix('a graph: renamed members, a wrapped list, a nested object, a Currency',
        False, GraphCarried, GraphRefused, GraphFailed);
      RunMatrix('a flat row: typed scalars only',
        True, FlatCarried, FlatRefused, FlatFailed);

      Writeln;
      Writeln('CONTRACT_MATRIX_GRAPH_CARRIED=', GraphCarried);
      Writeln('CONTRACT_MATRIX_GRAPH_REFUSED=', GraphRefused);
      Writeln('CONTRACT_MATRIX_GRAPH_FAILED=', GraphFailed);
      Writeln('CONTRACT_MATRIX_FLAT_CARRIED=', FlatCarried);
      Writeln('CONTRACT_MATRIX_FLAT_REFUSED=', FlatRefused);
      Writeln('CONTRACT_MATRIX_FLAT_FAILED=', FlatFailed);

      { A flat row of typed scalars has no shape any format can object to, so
        a refusal there is as much a defect as a failure. }
      Check(FlatFailed = 0, 'CONTRACT_FLAT_MATRIX_NOTHING_FAILED');
      Check(FlatRefused = 0, 'CONTRACT_FLAT_MATRIX_NOTHING_REFUSED');
      Check(GraphFailed = 0, 'CONTRACT_GRAPH_MATRIX_NOTHING_FAILED');

      GReport.Add(Format('Graph: %d carried, %d refused, %d failed.',
        [GraphCarried, GraphRefused, GraphFailed]));
      GReport.Add(Format('Flat: %d carried, %d refused, %d failed.',
        [FlatCarried, FlatRefused, FlatFailed]));
      ForceDirectories('..\..\artifacts');
      GReport.SaveToFile('..\..\artifacts\contract-matrix.md', TEncoding.UTF8);

      Writeln;
      Writeln('CHECKS=', GChecks);
      Writeln('FAILURES=', GFailures);
      if GFailures = 0 then
      begin
        Writeln('CONTRACT_CONVERSION_MATRIX: PASS');
        Writeln('CONTRACT_MATRIX: PASS');
      end
      else
      begin
        Writeln('CONTRACT_MATRIX: FAIL');
        Halt(1);
      end;
    except
      on E: Exception do
      begin
        Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
        Writeln('CONTRACT_MATRIX: FAIL');
        Halt(1);
      end;
    end;
  finally
    GReport.Free;
  end;
end.
