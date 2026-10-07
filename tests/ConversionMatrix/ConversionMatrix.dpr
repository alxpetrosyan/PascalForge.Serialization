program ConversionMatrix;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Every implemented format against every other, both directions, both modes.

  The program names no format. It asks the registry which ones are there and
  builds the matrix from that, so the day a new format registers itself it is
  tested against all of its predecessors and they are all retested against
  it. That is the requirement - "rerun all old pairs too, not only pairs
  involving the new format" - expressed as code rather than as a promise.

  TWO MODES, and the difference is the whole point:

    CONTRACT-AWARE  the Delphi type is the contract. Each side applies its
                    own names, its own enum mapping and its own custom
                    serializer, so the SAME order comes out of a JSON->XML
                    conversion as out of a JSON->BSON one.

    STRUCTURAL      no contract. Only what every format can carry survives,
                    and what a destination cannot represent is encoded,
                    described or refused according to the profile - never
                    silently dropped.

  It also writes artifacts\conversion-matrix.md, which is the matrix as a
  table. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.TypInfo, System.StrUtils,
  System.Generics.Collections,
  MatrixModels in 'MatrixModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  PascalForge.Xml in '..\..\src\PascalForge.Xml.pas',
  PascalForge.Bson in '..\..\src\PascalForge.Bson.pas',
  PascalForge.Protobuf in '..\..\src\PascalForge.Protobuf.pas',
  PascalForge.Json.Registration in '..\..\src\PascalForge.Json.Registration.pas',
  PascalForge.Xml.Registration in '..\..\src\PascalForge.Xml.Registration.pas',
  PascalForge.Bson.Registration in '..\..\src\PascalForge.Bson.Registration.pas',
  PascalForge.Protobuf.Registration in '..\..\src\PascalForge.Protobuf.Registration.pas',
  { Every remaining format, in one line. The matrix is built from the
    registry, so this widens it to everything the library implements without
    naming a single format here. }
  AllFormatsRegistered in '..\Shared\AllFormatsRegistered.pas';

var
  GFailures: Integer = 0;
  GReport: TStringList;

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

function Name(AFormat: TSerializationFormat): string;
begin
  Result := TSerialization.FormatName(AFormat);
end;

{ How a pair reads in the generated table. }
function Verdict(AOutcome: Integer): string;
begin
  case AOutcome of
    0: Result := 'PASS';
    1: Result := 'refused';
  else
    Result := 'FAIL';
  end;
end;

{ ===========================================================================
  CONTRACT-AWARE

  The order is written in A, converted to B through the contract, read back
  from B, and compared field by field against the original. Anything the
  Delphi type can hold must survive, whatever the two formats are.
  =========================================================================== }

{ THREE OUTCOMES, NOT TWO.

  The model this matrix uses carries every construct the library claims to
  support, and two destinations cannot take all of it: ASN.1 has no REAL, so
  a Double is refused by name, and a CSV table has no honest column layout
  for a map. Those refusals are the DOCUMENTED behaviour of those formats,
  and a matrix that scored them as failures would be reporting the model
  rather than the library.

  So a pair is Carried, Refused, or Failed. A refusal counts only when it is
  a deliberate, named one - a serialization exception carrying the member
  path. An access violation, an invalid cast or an invalid pointer is a
  FAILURE however it is dressed, and so is a round trip that silently comes
  back different. }
type
  TPairOutcome = (Carried, Refused, Failed);

{ The line between the two. A refusal is something the LIBRARY decided to
  say; these are the ways a program breaks instead, and none of them is ever
  an acceptable answer to "this format cannot carry that value". }
function IsRuntimeFailure(E: Exception): Boolean;
begin
  Result := (E is EExternal) or (E is EInvalidCast) or
            (E is EInvalidPointer) or (E is EOutOfMemory) or
            (E is EIntOverflow) or (E is ERangeError) or
            (E is EInvalidOp) or (E is EAbstractError) or
            (E is EAssertionFailed);
end;

function ContractPair(AFrom, ATo: TSerializationFormat;
  out ADetail: string): TPairOutcome;
var
  Order, Back: TOrder;
  Source, Converted: TSerializationPayload;
  Expected: string;
begin
  ADetail := '';
  Order := SampleOrder;
  try
    Expected := Describe(Order);
    try
      Source := TSerialization.Serialize<TOrder>(Order, AFrom);
    except
      on E: Exception do
      begin
        ADetail := E.ClassName + ': ' + E.Message;
        if IsRuntimeFailure(E) then Exit(TPairOutcome.Failed);
        Exit(TPairOutcome.Refused);
      end;
    end;
  finally
    Order.Free;
  end;

  try
    Converted := TSerialization.Convert<TOrder>(Source, AFrom, ATo);
  except
    on E: Exception do
    begin
      ADetail := E.ClassName + ': ' + E.Message;
      if IsRuntimeFailure(E) then Exit(TPairOutcome.Failed);
      Exit(TPairOutcome.Refused);
    end;
  end;

  Back := TSerialization.Deserialize<TOrder>(Converted, ATo);
  try
    ADetail := Describe(Back);
    if ADetail = Expected then Exit(TPairOutcome.Carried);
    Note('expected: ' + Expected);
    Note('got     : ' + ADetail);
    Result := TPairOutcome.Failed;
  finally
    Back.Free;
  end;
end;

{ ===========================================================================
  STRUCTURAL

  A document with no contract at all. Under the Lossless profile the tree
  that comes back must equal the tree that went in - which is checked by
  rendering both through the same format and comparing the text.
  =========================================================================== }

const
  { Chosen to exercise every dynamic kind a text format can carry, plus
    member names that not every format can spell. }
  STRUCTURAL_SOURCE =
    '{"$type":"Subject","first name":"Ada","Id":4611686018427387903,' +
    '"Rate":1.5,"Active":true,"Rating":null,"Tags":[],' +
    '"Lines":[{"Sku":"A-1","Qty":2},{"Sku":"B-2","Qty":5}],' +
    '"Name":"' + #$10DA#$10DD#$10D3#$10D8 + '"}';

{ THE DOCUMENT, AS TEXT, MEMBER BY MEMBER.

  Every scalar is rendered the way a format with no type system would have to
  render it. That is the comparison the Natural profile deserves: a
  destination that has no integers is DOCUMENTED to bring them back as text,
  so insisting on Int here would be testing the documentation rather than the
  conversion. What must never differ is the set of members, their order,
  their nesting, their nulls, and the TEXT of every value.

  The Lossless profile is held to the stricter standard separately. }
procedure FlattenDynamic(AValue: TDynamicValue; const APath: string;
  ASB: TStringBuilder);
var
  I: Integer;
begin
  case AValue.Kind of
    TDynamicKind.Null:  ASB.Append(APath).Append('=<null>;');
    TDynamicKind.Bool:
      if AValue.AsBool then ASB.Append(APath).Append('=true;')
      else ASB.Append(APath).Append('=false;');
    TDynamicKind.Int:
      ASB.Append(APath).Append('=').Append(IntToStr(AValue.AsInt)).Append(';');
    TDynamicKind.Float:
      ASB.Append(APath).Append('=')
         .Append(FloatToStr(AValue.AsFloat, TFormatSettings.Invariant))
         .Append(';');
    TDynamicKind.Str:
      ASB.Append(APath).Append('=').Append(AValue.AsStr).Append(';');
    TDynamicKind.Bytes:
      ASB.Append(APath).Append('=')
         .Append(TStructuralText.EncodeBinary(AValue.AsBytes)).Append(';');
    TDynamicKind.DateTime:
      ASB.Append(APath).Append('=')
         .Append(TStructuralText.EncodeDateTime(AValue.AsDateTime))
         .Append(';');
    TDynamicKind.Arr:
      begin
        ASB.Append(APath).Append('=[').Append(AValue.Count).Append('];');
        for I := 0 to AValue.Count - 1 do
          FlattenDynamic(AValue[I], TStructuralPath.Index(APath, I), ASB);
      end;
    TDynamicKind.Extended:
      begin
        ASB.Append(APath).Append('=').Append(AValue.ExtendedTag).Append('(');
        if AValue.ExtendedValue <> nil then
          FlattenDynamic(AValue.ExtendedValue, APath, ASB);
        ASB.Append(');');
      end;
    TDynamicKind.Obj:
      begin
        ASB.Append(APath).Append('={').Append(AValue.Count).Append('};');
        for I := 0 to AValue.Count - 1 do
          FlattenDynamic(AValue[I],
            TStructuralPath.Member(APath, AValue.Names[I]), ASB);
      end;
  end;
end;

{ Every LEAF, in document order, as its text - and nothing else.

  This is what the Natural profile actually promises, stated precisely
  enough to test: no member is dropped, and no text is changed. It
  deliberately does not look at member names or at container kinds, because
  Natural does adapt both of those and says so:

    a name XML cannot spell is written the XmlConvert.EncodeName way and is
    not decoded on the way back, because the reader has no way to know that
    a foreign document used that convention;

    an empty list has no repeated sibling element to write, so it becomes an
    empty element and comes back as an empty string.

  Both are documented losses of the Natural profile and both are exactly why
  the Lossless profile exists - which the row below this one checks with a
  full, exact comparison. }
procedure FlattenTexts(AValue: TDynamicValue; ASB: TStringBuilder);
var
  I: Integer;
begin
  case AValue.Kind of
    TDynamicKind.Arr, TDynamicKind.Obj:
      begin
        { An empty container has no leaf of its own, and neither has the
          empty element it becomes; both contribute one empty slot. }
        if AValue.Count = 0 then ASB.Append(';')
        else
          for I := 0 to AValue.Count - 1 do FlattenTexts(AValue[I], ASB);
      end;
    TDynamicKind.Null:  ASB.Append('<null>;');
    TDynamicKind.Bool:
      if AValue.AsBool then ASB.Append('true;') else ASB.Append('false;');
    TDynamicKind.Int:   ASB.Append(AValue.AsInt).Append(';');
    TDynamicKind.Float: ASB.Append(FloatToStr(AValue.AsFloat,
                          TFormatSettings.Invariant)).Append(';');
    TDynamicKind.Bytes: ASB.Append(
                          TStructuralText.EncodeBinary(AValue.AsBytes))
                          .Append(';');
    TDynamicKind.DateTime: ASB.Append(
                          TStructuralText.EncodeDateTime(AValue.AsDateTime))
                          .Append(';');
    TDynamicKind.Extended:
      begin
        if AValue.ExtendedValue <> nil then
          FlattenTexts(AValue.ExtendedValue, ASB)
        else
          ASB.Append(';');
      end;
  else
    ASB.Append(AValue.AsStr).Append(';');
  end;
end;

function Flatten(const APayload: TSerializationPayload;
  AFormat: TSerializationFormat): string; forward;

function FlattenLeaves(const APayload: TSerializationPayload;
  AFormat: TSerializationFormat): string;
var
  Tree: TDynamicValue;
  SB: TStringBuilder;
begin
  Tree := TSerializationFormats.Get(AFormat).ToDynamic(APayload,
    TStructuralConversionOptions.Default.WithSource(AFormat));
  try
    SB := TStringBuilder.Create;
    try
      FlattenTexts(Tree, SB);
      Result := SB.ToString;
    finally
      SB.Free;
    end;
  finally
    Tree.Free;
  end;
end;

function Flatten(const APayload: TSerializationPayload;
  AFormat: TSerializationFormat): string;
var
  Tree: TDynamicValue;
  SB: TStringBuilder;
begin
  Tree := TSerializationFormats.Get(AFormat).ToDynamic(APayload,
    TStructuralConversionOptions.Default.WithSource(AFormat));
  try
    SB := TStringBuilder.Create;
    try
      FlattenDynamic(Tree, TStructuralPath.Root, SB);
      Result := SB.ToString;
    finally
      SB.Free;
    end;
  finally
    Tree.Free;
  end;
end;

function StructuralPair(AFrom, ATo: TSerializationFormat;
  AProfile: TStructuralConversionProfile;
  out ADetail: string): TPairOutcome;
var
  Seed, InA, InB, BackInA: TSerializationPayload;
  Canonical, RoundTripped: string;
begin
  try
  ADetail := '';
  { The same document, expressed in A. JSON is only the way it is written
    here; from this point nothing knows where it came from. }
  Seed := TSerializationPayload.FromText(STRUCTURAL_SOURCE);
  { Getting the document INTO A is setup, not the thing being measured, so it
    uses whichever profile can express it. Under Strict that step would
    refuse a name the destination cannot spell and the pair A->B would never
    be reached - which would make the audit below a report about the seeding
    rather than about the pair. }
  if AProfile = TStructuralConversionProfile.Lossless then
    InA := TSerialization.Convert(Seed, TSerializationFormat.Json, AFrom,
      AProfile)
  else
    InA := TSerialization.Convert(Seed, TSerializationFormat.Json, AFrom,
      TStructuralConversionProfile.Natural);

  InB := TSerialization.Convert(InA, AFrom, ATo, AProfile);
  BackInA := TSerialization.Convert(InB, ATo, AFrom, AProfile);

  if AProfile = TStructuralConversionProfile.Lossless then
  begin
    { Lossless means exactly that: the same tree, kinds included. }
    Canonical := TSerialization.Convert(InA, AFrom,
      TSerializationFormat.Json, AProfile).AsText;
    RoundTripped := TSerialization.Convert(BackInA, AFrom,
      TSerializationFormat.Json, AProfile).AsText;
  end
  else
  begin
    { Natural: every leaf, in order, with the same text. Nothing is dropped
      and no text is changed - which is the whole of what Natural promises.
      What it does NOT promise is a name XML cannot spell coming back in its
      original spelling, or an empty list still being a list; see
      FlattenTexts above, and the Lossless row below, which does compare
      everything. }
    Canonical := FlattenLeaves(InA, AFrom);
    RoundTripped := FlattenLeaves(BackInA, AFrom);
  end;

  ADetail := RoundTripped;
  if Canonical = RoundTripped then Exit(TPairOutcome.Carried);
  Note('canonical  : ' + Copy(Canonical, 1, 240));
  Note('round trip : ' + Copy(RoundTripped, 1, 240));
  Result := TPairOutcome.Failed;
  except
    on E: Exception do
    begin
      ADetail := E.ClassName + ': ' + E.Message;
      if IsRuntimeFailure(E) then Exit(TPairOutcome.Failed);
      Exit(TPairOutcome.Refused);
    end;
  end;
end;

{ ===========================================================================
  WHAT A REFUSAL WAS ABOUT

  Counting refusals is not enough: a number can absorb a defect. What a
  reader needs is the LIST of distinct reasons, so that every remaining
  refusal can be read and judged on its own.

  A category is the library's own sentence with the member path and the two
  format names taken out, because "$.Tags is an array and a CSV cell holds
  one value" and "$.Lines is an array and a CSV cell holds one value" are
  the same policy answered twice.
  =========================================================================== }

function RefusalCategory(const AMessage: string): string;
var
  P: Integer;
  S, Word_: string;
  Parts: TArray<string>;
begin
  S := AMessage;

  { Everything up to and including the "failed at $.Member (kind): " preamble
    is about WHERE, not about WHY. }
  P := Pos('): ', S);
  if P > 0 then S := Copy(S, P + 3, MaxInt);

  { One sentence is the reason; the rest is advice about what to do. }
  P := Pos('. ', S);
  if P > 0 then S := Copy(S, 1, P - 1);

  { And the path itself, wherever it appears, so two members with the same
    problem are one category. }
  Parts := S.Split([' ']);
  S := '';
  for Word_ in Parts do
  begin
    if S <> '' then S := S + ' ';
    if Word_.StartsWith('$') then S := S + '$.<member>'
    else S := S + Word_;
  end;
  Result := S.Trim(['.', ' ']);
end;

procedure NoteRefusal(ACategories: TStringList; const ADetail: string);
var
  Cat: string;
  Index: Integer;
begin
  Cat := RefusalCategory(ADetail);
  if Cat = '' then Cat := '(no reason given)';
  Index := ACategories.IndexOfName(Cat);
  if Index < 0 then ACategories.Add(Cat + '=1')
  else ACategories.ValueFromIndex[Index] :=
    IntToStr(StrToIntDef(ACategories.ValueFromIndex[Index], 0) + 1);
end;

{ ===========================================================================
  THE MATRIX
  =========================================================================== }

function Supports(AFormat: TSerializationFormat;
  const AList: TArray<TSerializationFormat>): Boolean;
var
  F: TSerializationFormat;
begin
  for F in AList do
    if F = AFormat then Exit(True);
  Result := False;
end;

procedure RunMatrix;
var
  Contract, Structural: TArray<TSerializationFormat>;
  A, B: TSerializationFormat;
  I, J, ContractPairs, StructuralPairs: Integer;
  Ok: Boolean;
  Detail, Row: string;
  ContractOk, StructuralOk, LosslessOk: Boolean;
  Outcome: TPairOutcome;
  ContractRefused, StructuralRefused, LosslessRefused: Integer;
  { The three categories, over the whole matrix rather than per mode,
    because that is the shape Carried / Refused / Failed is reported in. }
  Carried, Refused, Failed: Integer;
  Categories: TStringList;
  K: Integer;
begin
  { TWO LISTS, because they are two different questions. A schema-driven
    format can go both ways through a Delphi contract and cannot be parsed
    structurally at all, and pretending otherwise would either skip its
    contract pairs or demand structural ones it can never do. }
  Contract := TSerialization.ContractFormats;
  Structural := TSerialization.StructuralFormats;

  Writeln('-- formats discovered from the registry --');
  Row := '';
  for I := 0 to High(Contract) do Row := Row + Name(Contract[I]) + ' ';
  Note('contract-aware: ' + Row);
  Row := '';
  for I := 0 to High(Structural) do Row := Row + Name(Structural[I]) + ' ';
  Note('structural    : ' + Row);
  Check((Length(Contract) >= 2) and (Length(Structural) >= 2),
    'MATRIX_HAS_SOMETHING_TO_COMPARE');

  GReport.Add('# Conversion matrix');
  GReport.Add('');
  GReport.Add('Generated by `tests\ConversionMatrix`. Every implemented');
  GReport.Add('format against every other, both directions, both modes.');
  GReport.Add('');
  GReport.Add('A format that cannot be parsed structurally - one whose');
  GReport.Add('schema lives outside the document - appears in the');
  GReport.Add('contract-aware column and is marked n/a in the others.');
  GReport.Add('');
  GReport.Add('| from | to | contract-aware | structural (Natural) | structural (Lossless) |');
  GReport.Add('| --- | --- | --- | --- | --- |');

  ContractOk := True;
  StructuralOk := True;
  LosslessOk := True;
  ContractPairs := 0;
  StructuralPairs := 0;
  ContractRefused := 0;
  StructuralRefused := 0;
  LosslessRefused := 0;
  Carried := 0;
  Refused := 0;
  Failed := 0;
  Categories := TStringList.Create;

  Writeln;
  Writeln('-- the matrix --');
  for I := 0 to High(Contract) do
    for J := 0 to High(Contract) do
    begin
      if I = J then Continue;
      A := Contract[I];
      B := Contract[J];
      Inc(ContractPairs);
      Row := Format('| %s | %s |', [Name(A), Name(B)]);

      Outcome := ContractPair(A, B, Detail);
      Ok := Outcome <> TPairOutcome.Failed;
      Check(Ok, Format('CONTRACT_%s_TO_%s',
        [UpperCase(Name(A)), UpperCase(Name(B))]));
      if not Ok then ContractOk := False;
      case Outcome of
        TPairOutcome.Carried: Inc(Carried);
        TPairOutcome.Failed:  Inc(Failed);
      end;
      if Outcome = TPairOutcome.Refused then
      begin
        Inc(ContractRefused);
        Inc(Refused);
        NoteRefusal(Categories, Detail);
        Note('refused: ' + Copy(Detail, 1, 150));
      end;
      Row := Row + (' ' + Verdict(Ord(Outcome)) + ' |');

      if Supports(A, Structural) and Supports(B, Structural) then
      begin
        Inc(StructuralPairs);

        Outcome := StructuralPair(A, B,
          TStructuralConversionProfile.Natural, Detail);
        Ok := Outcome <> TPairOutcome.Failed;
        Check(Ok, Format('STRUCTURAL_%s_TO_%s',
          [UpperCase(Name(A)), UpperCase(Name(B))]));
        if not Ok then StructuralOk := False;
        case Outcome of
          TPairOutcome.Carried: Inc(Carried);
          TPairOutcome.Failed:  Inc(Failed);
        end;
        if Outcome = TPairOutcome.Refused then
        begin
          Inc(StructuralRefused);
          Inc(Refused);
          NoteRefusal(Categories, Detail);
          Note('refused: ' + Copy(Detail, 1, 150));
        end;
        Row := Row + (' ' + Verdict(Ord(Outcome)) + ' |');

        Outcome := StructuralPair(A, B,
          TStructuralConversionProfile.Lossless, Detail);
        Ok := Outcome <> TPairOutcome.Failed;
        Check(Ok, Format('LOSSLESS_%s_TO_%s',
          [UpperCase(Name(A)), UpperCase(Name(B))]));
        if not Ok then LosslessOk := False;
        case Outcome of
          TPairOutcome.Carried: Inc(Carried);
          TPairOutcome.Failed:  Inc(Failed);
        end;
        if Outcome = TPairOutcome.Refused then
        begin
          Inc(LosslessRefused);
          Inc(Refused);
          NoteRefusal(Categories, Detail);
        end;
        Row := Row + (' ' + Verdict(Ord(Outcome)) + ' |');
      end
      else
        Row := Row + ' n/a | n/a |';

      GReport.Add(Row);
    end;

  GReport.Add('');
  GReport.Add(Format('Contract-aware pairs: %d, %s. Structural pairs: %d, ' +
    'Natural %s, Lossless %s.',
    [ContractPairs, IfThen(ContractOk, 'PASS', 'FAIL'), StructuralPairs,
     IfThen(StructuralOk, 'PASS', 'FAIL'),
     IfThen(LosslessOk, 'PASS', 'FAIL')]));

  Writeln;
  Writeln('MATRIX_CONTRACT_PAIRS=', ContractPairs);
  Writeln('MATRIX_CONTRACT_REFUSED=', ContractRefused);
  Writeln('MATRIX_STRUCTURAL_REFUSED=', StructuralRefused);
  Writeln('MATRIX_LOSSLESS_REFUSED=', LosslessRefused);
  Writeln('MATRIX_STRUCTURAL_PAIRS=', StructuralPairs);

  { The three categories, and then every distinct reason behind the middle
    one. A refusal total on its own is a place for a defect to hide; the
    list underneath it is not. }
  Writeln('MATRIX_CARRIED=', Carried);
  Writeln('MATRIX_REFUSED=', Refused);
  Writeln('MATRIX_FAILED=', Failed);
  if Categories.Count > 0 then
  begin
    Writeln;
    Writeln('-- expected refusal categories --');
    for K := 0 to Categories.Count - 1 do
    begin
      Note(Format('%3s x %s', [Categories.ValueFromIndex[K],
        Categories.Names[K]]));
      GReport.Add(Format('- %s x %s', [Categories.ValueFromIndex[K],
        Categories.Names[K]]));
    end;
  end;
  Writeln('MATRIX_REFUSAL_CATEGORIES=', Categories.Count);
  Categories.Free;

  Check(ContractOk, 'CONTRACT_CONVERSION_MATRIX');
  Check(StructuralOk, 'STRUCTURAL_CONVERSION_MATRIX');
  Check(LosslessOk, 'STRUCTURAL_LOSSLESS_MATRIX');
  { Every pair that existed before the newest format was added is in the
    loops above, because the loops are over everything the registry has. }
  Check(ContractOk and StructuralOk, 'ALL_PREVIOUS_PAIRINGS_RERUN');
  { And the whole matrix in one answer: nothing failed, in any mode. }
  Check((Failed = 0) and ContractOk and StructuralOk and LosslessOk,
    'FORMAT_CONVERSION_MATRIX');
end;

{ Strict is the compatibility check: it says, for each pair, exactly which
  constructs the destination cannot take directly. That is information, not
  a failure - so what is asserted is that a refusal is a proper structural
  error with a path, and never a silent loss. }
procedure RunStrictAudit;
var
  Formats: TArray<TSerializationFormat>;
  I, J: Integer;
  A, B: TSerializationFormat;
  Detail: string;
  Clean: Boolean;
begin
  Writeln;
  Writeln('-- strict audit: what each destination refuses --');
  GReport.Add('');
  GReport.Add('## Strict profile');
  GReport.Add('');
  GReport.Add('| from | to | outcome |');
  GReport.Add('| --- | --- | --- |');

  Clean := True;
  { Only formats that can be parsed structurally can be audited this way:
    for the rest there is nothing to refuse, because there was never a
    structural path to begin with. }
  Formats := TSerialization.StructuralFormats;
  for I := 0 to High(Formats) do
    for J := 0 to High(Formats) do
    begin
      if I = J then Continue;
      A := Formats[I];
      B := Formats[J];
      try
        { ONE LEG, A to B. Not a round trip: the return leg would be a
          different pair, and attributing its refusal to this one is how an
          audit ends up saying the opposite of what it means. }
        TSerialization.Convert(
          TSerialization.Convert(
            TSerializationPayload.FromText(STRUCTURAL_SOURCE),
            TSerializationFormat.Json, A,
            TStructuralConversionProfile.Natural),
          A, B, TStructuralConversionProfile.Strict);
        Detail := 'accepted';
      except
        on E: EStructuralConversionError do
          Detail := 'refused at ' + E.Path + ' (' +
            GetEnumName(TypeInfo(TStructuralIssue), Ord(E.Issue)) + ')';
        on E: Exception do
        begin
          Detail := 'UNEXPECTED ' + E.ClassName + ': ' + E.Message;
          Clean := False;
        end;
      end;
      Note(Format('%s -> %s: %s', [Name(A), Name(B), Detail]));
      GReport.Add(Format('| %s | %s | %s |', [Name(A), Name(B), Detail]));
    end;

  Check(Clean, 'STRICT_REFUSALS_ARE_STRUCTURAL_ERRORS');
end;

procedure WriteReport;
var
  Dir, Path: string;
begin
  Dir := TPath.Combine(GetCurrentDir, 'artifacts');
  if not TDirectory.Exists(Dir) then TDirectory.CreateDirectory(Dir);
  Path := TPath.Combine(Dir, 'conversion-matrix.md');
  GReport.SaveToFile(Path, TEncoding.UTF8);
  Writeln;
  Writeln('report: ', Path);
end;

begin
  GReport := TStringList.Create;
  try
    try
      ConfigureFormats;
      RunMatrix;
      RunStrictAudit;
      WriteReport;
    except
      on E: Exception do
      begin
        Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
        Inc(GFailures);
      end;
    end;
  finally
    GReport.Free;
  end;

  Writeln;
  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then
    Writeln('CONVERSION_MATRIX: PASS')
  else
  begin
    Writeln('CONVERSION_MATRIX: FAIL');
    ExitCode := 1;
  end;
end.
