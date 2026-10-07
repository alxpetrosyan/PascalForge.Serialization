program FormatBoundary;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The type-erased boundary, and who owns what across it.

  TSerialization reaches a format handler with a PTypeInfo and a TValue. A
  TValue holding a class reference says nothing about who frees the instance,
  so the rule is written down on TSerializationFormatHandler and checked here:

      SerializeTyped   BORROWS   - the caller still owns what it passed
      DeserializeTyped TRANSFERS - the caller releases what came back
      ToDynamic        TRANSFERS - the caller frees the tree
      FromDynamic      BORROWS   - the tree is still the caller's

  Instance accounting is done by the DTOs themselves: every construction and
  destruction moves a counter, so a leak is a number at the end of the run and
  not a hope. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  PascalForge.Json.Registration in '..\..\src\PascalForge.Json.Registration.pas';

var
  GFailures: Integer = 0;
  GLive: Integer = 0;

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
  { Counts itself, so "did that leak" is a fact rather than an opinion. }
  TCounted = class
  public
    constructor Create;
    destructor Destroy; override;
  end;

  TShipment = class(TCounted)
  public
    Id: Int64;
    Amount: Currency;
    Consignee: string;
  end;

constructor TCounted.Create;
begin
  inherited Create;
  Inc(GLive);
end;

destructor TCounted.Destroy;
begin
  Dec(GLive);
  inherited Destroy;
end;

function SampleShipment: TShipment;
begin
  Result := TShipment.Create;
  Result.Id := 4711;
  Result.Amount := 128.55;
  Result.Consignee := 'Ada';
end;

const
  SAMPLE_JSON = '{"id":4711,"amount":128.55,"consignee":"Ada"}';

{ ------------------------------------------------------ handler identity --- }

procedure TestHandlerIsAStatelessSingleton;
var
  A, B: TSerializationFormatHandler;
begin
  Writeln('-- the handler --');
  A := TSerializationFormats.Get(TSerializationFormat.Json);
  B := TSerializationFormats.Get(TSerializationFormat.Json);
  { One instance, shared by every caller on every thread - which is why the
    contract forbids per-operation state in a handler. }
  Check((A <> nil) and (A = B), 'HANDLER_IS_A_SINGLETON');
  Check(A.PayloadKind = TSerializationPayloadKind.Text, 'HANDLER_DECLARES_PAYLOAD_KIND');
  Note('handler class: ' + A.ClassName);
end;

{ ------------------------------------------------------------- borrowing --- }

procedure TestSerializeBorrows;
var
  P: TShipment;
  Payload: TSerializationPayload;
  Before: Integer;
begin
  Writeln('-- SerializeTyped borrows --');
  P := SampleShipment;
  try
    Before := GLive;
    Payload := TSerialization.Serialize<TShipment>(P, TSerializationFormat.Json);
    { Still alive, still usable, still ours. }
    Check((GLive = Before) and (P.Consignee = 'Ada') and (Payload.AsText <> ''),
      'SERIALIZE_TYPED_BORROWS_THE_VALUE');
  finally
    P.Free;
  end;
  Check(GLive = 0, 'SERIALIZE_TYPED_FREES_NOTHING_OF_THE_CALLERS');
end;

{ ----------------------------------------------------------- transferring --- }

procedure TestDeserializeTransfers;
var
  P: TShipment;
begin
  Writeln('-- DeserializeTyped transfers --');
  P := TSerialization.Deserialize<TShipment>(
    TSerializationPayload.FromText(SAMPLE_JSON), TSerializationFormat.Json);
  try
    Check((GLive = 1) and (P.Id = 4711) and (P.Consignee = 'Ada'),
      'DESERIALIZE_TYPED_TRANSFERS_OWNERSHIP');
  finally
    P.Free;
  end;
  Check(GLive = 0, 'DESERIALIZE_TYPED_RESULT_IS_THE_CALLERS_TO_FREE');
end;

{ ------------------------------------------------------------- releasing --- }

procedure TestReleaseContract;
var
  V: TValue;
  P: TShipment;
  Arr: TArray<TShipment>;
  I: Integer;
begin
  Writeln('-- TSerializationOwnership --');

  { A value that owns nothing needs no release, and saying so is not an
    error. }
  Check((not TSerializationOwnership.IsOwningType(TypeInfo(Integer))) and
        (not TSerializationOwnership.IsOwningType(TypeInfo(string))) and
        (not TSerializationOwnership.IsOwningType(TypeInfo(TGUID))) and
        (not TSerializationOwnership.IsOwningType(TypeInfo(TArray<Integer>))) and
        (not TSerializationOwnership.IsOwningType(nil)),
    'NON_OWNING_TYPES_NEED_NO_RELEASE');
  Check(TSerializationOwnership.IsOwningType(TypeInfo(TShipment)) and
        TSerializationOwnership.IsOwningType(TypeInfo(TArray<TShipment>)),
    'OWNING_TYPES_ARE_RECOGNIZED');

  { A no-op has to be genuinely safe, including on an empty value. }
  TSerializationOwnership.Release(TypeInfo(Integer), TValue.From<Integer>(7));
  TSerializationOwnership.Release(TypeInfo(string), TValue.From<string>('x'));
  TSerializationOwnership.Release(TypeInfo(TShipment), TValue.Empty);
  TSerializationOwnership.Release(nil, TValue.Empty);
  Check(True, 'RELEASE_IS_SAFE_ON_NOTHING_TO_RELEASE');

  P := SampleShipment;
  V := TValue.From<TShipment>(P);
  TSerializationOwnership.Release(TypeInfo(TShipment), V);
  Check(GLive = 0, 'RELEASE_FREES_A_CLASS_VALUE');

  SetLength(Arr, 3);
  for I := 0 to 2 do Arr[I] := SampleShipment;
  V := TValue.From<TArray<TShipment>>(Arr);
  Arr := nil;
  TSerializationOwnership.Release(TypeInfo(TArray<TShipment>), V);
  Check(GLive = 0, 'RELEASE_FREES_AN_ARRAY_OF_CLASS_VALUES');
end;

{ ------------------------------------------------------------ conversion --- }

{ A conversion builds a T, writes it out, and must not hand anyone the T. }
procedure TestConvertReleasesTheIntermediate;
var
  Out1: TSerializationPayload;
  I: Integer;
begin
  Writeln('-- contract-aware conversion --');
  Out1 := TSerialization.Convert<TShipment>(
    TSerializationPayload.FromText(SAMPLE_JSON), TSerializationFormat.Json, TSerializationFormat.Json);
  Check(Out1.AsText.Contains('4711'), 'CONVERT_TYPED_PRODUCES_THE_PAYLOAD');
  Check(GLive = 0, 'CONVERT_TYPED_RELEASES_THE_INTERMEDIATE');

  { Repeated, because one leak is easy to miss and a thousand are not. }
  for I := 1 to 1000 do
    TSerialization.Convert<TShipment>(
      TSerializationPayload.FromText(SAMPLE_JSON), TSerializationFormat.Json, TSerializationFormat.Json);
  Check(GLive = 0, 'CONVERT_TYPED_LEAKS_NOTHING_OVER_MANY_CALLS');
  Note(Format('live instances after 1001 conversions: %d', [GLive]));
end;

{ The interesting half: the intermediate exists when the WRITE fails, and it
  still has to go. TSerializationFormat.Xml is not registered in this program, so the
  destination lookup is the failure - and it happens before anything is
  built. TSerializationFormat.Cbor likewise. To fail on the way OUT instead, the source
  must parse and the destination must raise; the unregistered-destination
  check below therefore also asserts nothing was constructed at all. }
procedure TestConvertFailures;
var
  Raised: Boolean;
begin
  Writeln('-- conversion that fails --');

  Raised := False;
  try
    TSerialization.Convert<TShipment>(
      TSerializationPayload.FromText(SAMPLE_JSON), TSerializationFormat.Json, TSerializationFormat.Xml);
  except
    on E: ESerializationFormatNotRegistered do Raised := True;
  end;
  Check(Raised, 'CONVERT_TYPED_UNREGISTERED_DESTINATION_RAISES');
  Check(GLive = 0, 'CONVERT_TYPED_UNREGISTERED_DESTINATION_BUILDS_NOTHING');

  { A source that cannot be parsed: the deserializer raises, and by contract
    it has already released whatever it half-built. }
  Raised := False;
  try
    TSerialization.Convert<TShipment>(
      TSerializationPayload.FromText('{"id":'), TSerializationFormat.Json, TSerializationFormat.Json);
  except
    on E: Exception do Raised := True;
  end;
  Check(Raised, 'CONVERT_TYPED_BAD_SOURCE_RAISES');
  Check(GLive = 0, 'FAILED_DESERIALIZE_LEAVES_NOTHING_BEHIND');

  { A structurally valid document whose members do not fit the contract. }
  Raised := False;
  try
    TSerialization.Convert<TShipment>(
      TSerializationPayload.FromText('{"id":"not a number"}'),
      TSerializationFormat.Json, TSerializationFormat.Json);
  except
    on E: Exception do Raised := True;
  end;
  Check(GLive = 0, 'FAILED_TYPED_CONVERSION_LEAKS_NOTHING');
  Note(Format('raised=%s, live=%d', [BoolToStr(Raised, True), GLive]));
end;

{ -------------------------------------------------------------- dynamic --- }

procedure TestDynamicOwnership;
var
  H: TSerializationFormatHandler;
  Tree: TDynamicValue;
  Round: TSerializationPayload;
begin
  Writeln('-- the dynamic tree --');
  H := TSerializationFormats.Get(TSerializationFormat.Json);
  Tree := H.ToDynamic(TSerializationPayload.FromText(SAMPLE_JSON),
    TStructuralConversionOptions.Default);
  try
    Check((Tree <> nil) and (Tree.Kind = TDynamicKind.Obj) and (Tree.Count = 3),
      'TO_DYNAMIC_TRANSFERS_THE_TREE');
    { FromDynamic borrows: the tree must still be intact and usable after. }
    Round := H.FromDynamic(Tree, TStructuralConversionOptions.Default);
    Check((Tree.Count = 3) and (Tree.Find('consignee') <> nil) and
          Round.AsText.Contains('4711'),
      'FROM_DYNAMIC_BORROWS_THE_TREE');
    { Borrowed means borrowed: calling it again has to work. }
    Round := H.FromDynamic(Tree, TStructuralConversionOptions.Default);
    Check(Round.AsText.Contains('Ada'), 'FROM_DYNAMIC_IS_REPEATABLE');
  finally
    Tree.Free;
  end;
end;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TJsonSerializationRegistration.RegisterFormat;
  ReportMemoryLeaksOnShutdown := True;
  try
    TestHandlerIsAStatelessSingleton;
    Writeln;
    TestSerializeBorrows;
    Writeln;
    TestDeserializeTransfers;
    Writeln;
    TestReleaseContract;
    Writeln;
    TestConvertReleasesTheIntermediate;
    Writeln;
    TestConvertFailures;
    Writeln;
    TestDynamicOwnership;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  Writeln('LIVE_INSTANCES=', GLive);
  if GLive <> 0 then Inc(GFailures);
  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then
    Writeln('FORMAT_BOUNDARY: PASS')
  else
  begin
    Writeln('FORMAT_BOUNDARY: FAIL');
    ExitCode := 1;
  end;
end.
