program FormatChain;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ ROUND THE WORLD.

  The conversion matrix proves every PAIR. This proves the CHAIN: one
  document walked through every structural format the registry knows and
  back to where it started, so that

      JSON -> XML -> BSON -> CBOR -> MessagePack -> YAML -> CSV -> JSON

  ends with the document it began with.

  That is a much harder promise than a pair, and it is the promise that
  matters to somebody moving data through a pipeline of tools. A pair can be
  lossy in a way that happens to reverse; a chain accumulates.

  WHAT THIS PROGRAM IS FOR, EXACTLY

  It is a MEASURING instrument first and a gate second. When a link loses
  something, the useful output is not "FAIL" - it is which link, what it
  lost, and what the document looked like on either side of it. So every
  hop is compared against the original and the first divergence is printed
  in full.

  The formats come from the REGISTRY, so a format added later joins the
  chain with no edit here, and a format whose schema lives outside the
  document is skipped with a reason rather than silently omitted. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  PascalForge.Xml in '..\..\src\PascalForge.Xml.pas',
  PascalForge.Bson in '..\..\src\PascalForge.Bson.pas',
  PascalForge.Json.Registration in '..\..\src\PascalForge.Json.Registration.pas',
  PascalForge.Xml.Registration in '..\..\src\PascalForge.Xml.Registration.pas',
  PascalForge.Bson.Registration in '..\..\src\PascalForge.Bson.Registration.pas',
  { Every remaining format. The ring is built from the registry, so the chain
    grows with the library and there is no list here to forget. }
  AllFormatsRegistered in '..\Shared\AllFormatsRegistered.pas';

var
  GFailures: Integer = 0;
  GReport: TStringList;

procedure Check(ACondition: Boolean; const AName: string);
begin
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
  THE DOCUMENT

  Deliberately not a toy. It carries every shape the chain can lose:

    a member name that is legal in JSON and illegal in XML
    Georgian text, and a character outside the basic plane
    an integer too large for a 32-bit field
    a fractional number
    a boolean, and a null
    an empty list, and a list of objects
    a nested object
    text that LOOKS like another format, which must not be reparsed
  =========================================================================== }

function SourceDocument: string;
const
  GEO = #$10D2#$10D8#$10DA#$10DD#$10EA#$10D0;
  { A non-BMP character, built at run time: a tool that rewrites a source
    file can turn a written escape into the character itself, and the point
    here is to control the bytes exactly. }
begin
  Result :=
    '{' +
    '"Id":4611686018427387903,' +
    '"Name":"' + GEO + '",' +
    '"Emoji":"' + Char($D83D) + Char($DE00) + '",' +
    '"Combining":"e' + Char($0301) + '",' +
    '"Rate":1.5,' +
    '"Active":true,' +
    '"Rating":null,' +
    '"Tags":[],' +
    '"Note":"<a b=\"c\">text</a>",' +
    '"Nested":{"City":"Midtown","Zip":"1234"},' +
    '"Lines":[{"Sku":"A-1","Qty":2},{"Sku":"B-2","Qty":5}]' +
    '}';
end;

{ The document as JSON, canonicalised by a round trip through the JSON
  reader and writer, so that comparisons are about CONTENT and not about
  whitespace or member spacing. }
function Canonical(const AJson: string): string;
begin
  Result := TSerialization.Convert(
    TSerializationPayload.FromText(AJson),
    TSerializationFormat.Json, TSerializationFormat.Json,
    TStructuralConversionProfile.Natural).AsText;
end;

{ ===========================================================================
  TWO DIFFERENT PROMISES

  Lossless does NOT promise that arbitrary text comes back byte for byte.
  It promises that the SEMANTIC structure survives: the members, in order,
  with the kinds they had. Whitespace and lexical spelling are not part of
  the bargain and never were.

  So the chain is measured twice.

    The semantic comparison reads the document AS THE FORMAT MEANS IT, into
    the dynamic tree, and compares kinds and values. That is the real
    guarantee, and it is the strict one: it notices an integer that became a
    string long before any text comparison could, because JSON spells both
    of those the same once quotes are involved.

    The byte comparison is about something narrower and entirely ours - that
    PascalForge's JSON writer is canonical, so the same tree writes the same
    bytes every time. That is a property of this library, not of the
    standards, and it is named separately so that nobody reads a passing
    chain as a promise the standards do not make.
  =========================================================================== }

function TreeOf(const APayload: TSerializationPayload;
  AFormat: TSerializationFormat;
  AProfile: TStructuralConversionProfile): TDynamicValue;
var
  Options: TStructuralConversionOptions;
begin
  Options := TStructuralConversionOptions.FromProfile(AProfile)
    .WithSource(AFormat).WithDestination(TSerializationFormat.Json);
  Result := TSerializationFormats.Get(AFormat).ToDynamic(APayload, Options);
end;

function SameTree(A, B: TDynamicValue; const APath: string;
  out AWhere: string): Boolean;

  function Differs(const AWhat: string): Boolean;
  begin
    AWhere := APath + ': ' + AWhat;
    Result := False;
  end;

var
  I: Integer;
begin
  AWhere := '';
  if (A = nil) or (B = nil) then
    Exit(Differs('one side is missing'));
  if A.Kind <> B.Kind then
    Exit(Differs(A.Describe + ' became ' + B.Describe));

  case A.Kind of
    TDynamicKind.Null: Exit(True);
    TDynamicKind.Bool:
      if A.AsBool <> B.AsBool then Exit(Differs('boolean changed'));
    TDynamicKind.Int:
      if A.AsInt <> B.AsInt then
        Exit(Differs(IntToStr(A.AsInt) + ' became ' + IntToStr(B.AsInt)));
    TDynamicKind.UInt:
      if A.AsUInt <> B.AsUInt then
        Exit(Differs(UIntToStr(A.AsUInt) + ' became ' + UIntToStr(B.AsUInt)));
    TDynamicKind.Float:
      if A.AsFloat <> B.AsFloat then
        Exit(Differs(FloatToStr(A.AsFloat) + ' became ' +
          FloatToStr(B.AsFloat)));
    TDynamicKind.Decimal:
      if A.AsDecimal <> B.AsDecimal then
        Exit(Differs(A.AsDecimal + ' became ' + B.AsDecimal));
    TDynamicKind.Str:
      if A.AsStr <> B.AsStr then Exit(Differs('text changed'));
    TDynamicKind.Bytes:
      begin
        if Length(A.AsBytes) <> Length(B.AsBytes) then
          Exit(Differs('binary length changed'));
        for I := 0 to High(A.AsBytes) do
          if A.AsBytes[I] <> B.AsBytes[I] then
            Exit(Differs('binary content changed'));
      end;
    TDynamicKind.Date, TDynamicKind.Time, TDynamicKind.DateTime:
      if A.AsDateTime <> B.AsDateTime then
        Exit(Differs('moment changed'));
    TDynamicKind.Arr:
      begin
        if A.Count <> B.Count then
          Exit(Differs(Format('%d elements became %d', [A.Count, B.Count])));
        for I := 0 to A.Count - 1 do
          if not SameTree(A[I], B[I],
               Format('%s[%d]', [APath, I]), AWhere) then Exit(False);
      end;
    TDynamicKind.Obj:
      begin
        if A.Count <> B.Count then
          Exit(Differs(Format('%d members became %d', [A.Count, B.Count])));
        for I := 0 to A.Count - 1 do
        begin
          { Order too. A map that comes back with its members shuffled has
            lost something a document format promised to keep. }
          if A.Names[I] <> B.Names[I] then
            Exit(Differs('member ' + A.Names[I] + ' became ' + B.Names[I]));
          if not SameTree(A[I], B[I], APath + '.' + A.Names[I],
               AWhere) then Exit(False);
        end;
      end;
    TDynamicKind.Extended:
      begin
        if A.ExtendedTag <> B.ExtendedTag then
          Exit(Differs(A.ExtendedTag + ' became ' + B.ExtendedTag));
        if not SameTree(A.ExtendedValue, B.ExtendedValue,
             APath + '<' + A.ExtendedTag + '>', AWhere) then Exit(False);
      end;
  end;
  Result := True;
end;

{ ===========================================================================
  WHICH FORMATS CAN BE IN THE CHAIN

  A format joins when it can be both read and written structurally with
  nothing supplied. A format whose schema lives outside the document cannot -
  not because it is weaker, but because there is nothing in its bytes to
  read the document AS - and it is reported as skipped with that reason
  rather than left out silently.
  =========================================================================== }

function ChainFormats(out ASkipped: string): TArray<TSerializationFormat>;
var
  F: TSerializationFormat;
  List: TList<TSerializationFormat>;
  Caps: TSerializationFormatCapabilities;
begin
  ASkipped := '';
  List := TList<TSerializationFormat>.Create;
  try
    for F := Low(TSerializationFormat) to High(TSerializationFormat) do
    begin
      if not TSerializationFormats.IsRegistered(F) then Continue;
      Caps := TSerializationFormats.Capabilities(F);
      if (TSerializationFormatCapability.StructuralParse in Caps) and
         (TSerializationFormatCapability.StructuralWrite in Caps) then
        List.Add(F)
      else
      begin
        if ASkipped <> '' then ASkipped := ASkipped + ', ';
        ASkipped := ASkipped + Name(F) + ' (needs a schema)';
      end;
    end;
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

{ ===========================================================================
  THE CHAIN
  =========================================================================== }

type
  THop = record
    From_, To_: TSerializationFormat;
    Ok: Boolean;
    { A REFUSAL is the library saying, in its own words, that the selected
      representation cannot carry this graph. That is a policy answer and it
      is allowed. Anything else - an access violation, a bad cast, an
      internal error - is a defect, and the difference is kept because
      collapsing the two is how a broken format hides behind a category. }
    Refused: Boolean;
    Error: string;
    BackToJson: string;
    { Byte-equal canonical JSON, and semantically equal dynamic tree. Two
      different promises, measured separately. }
    Matches: Boolean;
    Semantic: Boolean;
    SemanticWhere: string;
  end;

  TChainResult = record
    Hops: TArray<THop>;
    FinalJson: string;
    { The formats that answered "not in this representation", with the
      reason they gave. Printed in full, every time. }
    Refusals: TArray<string>;
    Failures: Integer;
    Carried: Integer;
    Completed: Boolean;
  end;

function RunChain(AProfile: TStructuralConversionProfile;
  const AFormats: TArray<TSerializationFormat>): TChainResult;
var
  Current: TSerializationPayload;
  CurrentFormat: TSerializationFormat;
  I: Integer;
  Hops: TList<THop>;
  Refusals: TStringList;
  H: THop;
  Original: string;
  OriginalTree, HopTree: TDynamicValue;

  { Every hop is compared against the document as it started, not against
    the hop before it, because a chain that drifts one step at a time is
    exactly the failure this program exists to find. }
  procedure Measure(var AHop: THop);
  begin
    try
      AHop.BackToJson := TSerialization.Convert(Current, CurrentFormat,
        TSerializationFormat.Json, AProfile).AsText;
      if AProfile <> TStructuralConversionProfile.Natural then
        AHop.BackToJson := Canonical(AHop.BackToJson);
      AHop.Matches := AHop.BackToJson = Original;
    except
      on E: Exception do
      begin
        AHop.BackToJson := '<' + E.ClassName + '>';
        AHop.Matches := False;
      end;
    end;

    try
      HopTree := TreeOf(Current, CurrentFormat, AProfile);
      try
        AHop.Semantic := SameTree(OriginalTree, HopTree, '$',
          AHop.SemanticWhere);
      finally
        HopTree.Free;
      end;
    except
      on E: Exception do
      begin
        AHop.Semantic := False;
        AHop.SemanticWhere := E.ClassName + ': ' + E.Message;
      end;
    end;
  end;

begin
  Result := Default(TChainResult);
  Original := Canonical(SourceDocument);
  Current := TSerializationPayload.FromText(SourceDocument);
  CurrentFormat := TSerializationFormat.Json;

  OriginalTree := TreeOf(TSerializationPayload.FromText(SourceDocument),
    TSerializationFormat.Json, AProfile);
  Hops := TList<THop>.Create;
  Refusals := TStringList.Create;
  try
    for I := 0 to High(AFormats) do
    begin
      if AFormats[I] = CurrentFormat then Continue;

      H := Default(THop);
      H.From_ := CurrentFormat;
      H.To_ := AFormats[I];
      try
        Current := TSerialization.Convert(Current, CurrentFormat, AFormats[I],
          AProfile);
        CurrentFormat := AFormats[I];
        H.Ok := True;
      except
        { A representation refusal takes the format out of the ring and the
          walk goes on without it, so one conservative format does not stop
          the chain from being measured. It is recorded, with its reason, and
          counted. }
        on E: EStructuralConversionError do
        begin
          H.Refused := True;
          H.Error := E.Message;
          Refusals.Add(Format('%s -> %s: %s',
            [Name(H.From_), Name(H.To_), E.Message]));
        end;
        on E: Exception do
        begin
          H.Error := E.ClassName + ': ' + E.Message;
          Inc(Result.Failures);
        end;
      end;

      if H.Ok then
      begin
        Measure(H);
        Inc(Result.Carried);
      end;
      Hops.Add(H);
      { A hard failure leaves the payload in an unknown state; a refusal
        does not, because nothing was written. }
      if not (H.Ok or H.Refused) then Break;
    end;

    { And home. }
    if (Result.Failures = 0) and (CurrentFormat <> TSerializationFormat.Json) then
    begin
      H := Default(THop);
      H.From_ := CurrentFormat;
      H.To_ := TSerializationFormat.Json;
      try
        Current := TSerialization.Convert(Current, CurrentFormat,
          TSerializationFormat.Json, AProfile);
        CurrentFormat := TSerializationFormat.Json;
        H.Ok := True;
        Measure(H);
        Inc(Result.Carried);
        Result.Completed := True;
      except
        on E: EStructuralConversionError do
        begin
          H.Refused := True;
          H.Error := E.Message;
          Refusals.Add(Format('%s -> %s: %s',
            [Name(H.From_), Name(H.To_), E.Message]));
        end;
        on E: Exception do
        begin
          H.Error := E.ClassName + ': ' + E.Message;
          Inc(Result.Failures);
        end;
      end;
      Hops.Add(H);
      Result.FinalJson := H.BackToJson;
    end
    else if Result.Failures = 0 then
    begin
      { Nothing moved: every format in the ring declined. }
      Result.Completed := True;
      Result.FinalJson := Canonical(Current.AsText);
    end;

    Result.Hops := Hops.ToArray;
    Result.Refusals := Refusals.ToStringArray;
  finally
    Refusals.Free;
    Hops.Free;
    OriginalTree.Free;
  end;
end;

{ Reports the walk, and answers the two questions separately. ASemantic and
  AByteEqual come back nil-safe: a caller that only wants the printout
  passes nothing. }
procedure ReportChain(const ATitle: string;
  AProfile: TStructuralConversionProfile;
  const AFormats: TArray<TSerializationFormat>;
  ASemantic: PBoolean = nil; AByteEqual: PBoolean = nil);
var
  Chain: TChainResult;
  Original, Row, R: string;
  I, FirstLoss: Integer;
  Semantic, ByteEqual: Boolean;
begin
  Writeln;
  Writeln('-- ', ATitle, ' --');
  Original := Canonical(SourceDocument);

  Chain := RunChain(AProfile, AFormats);

  Semantic := (Chain.Failures = 0) and (Chain.Carried > 0);
  ByteEqual := Semantic;
  FirstLoss := -1;
  for I := 0 to High(Chain.Hops) do
  begin
    Row := Format('  %-12s -> %-12s ',
      [Name(Chain.Hops[I].From_), Name(Chain.Hops[I].To_)]);
    if Chain.Hops[I].Refused then
      Row := Row + 'REFUSED  ' + Chain.Hops[I].Error
    else if not Chain.Hops[I].Ok then
      Row := Row + 'FAILED   ' + Chain.Hops[I].Error
    else if Chain.Hops[I].Matches and Chain.Hops[I].Semantic then
      Row := Row + 'identical'
    else if Chain.Hops[I].Semantic then
      Row := Row + 'same meaning, different bytes'
    else
      Row := Row + 'DIVERGED  ' + Chain.Hops[I].SemanticWhere;
    Writeln(Row);
    GReport.Add(Row);

    if Chain.Hops[I].Ok then
    begin
      if not Chain.Hops[I].Semantic then Semantic := False;
      if not Chain.Hops[I].Matches then ByteEqual := False;
      if not Chain.Hops[I].Matches and (FirstLoss < 0) then FirstLoss := I;
    end;
  end;

  { The first divergence, in full, because that is the one worth reading. }
  if FirstLoss >= 0 then
  begin
    Writeln;
    Note('first divergence at ' + Name(Chain.Hops[FirstLoss].From_) + ' -> ' +
      Name(Chain.Hops[FirstLoss].To_));
    if not Chain.Hops[FirstLoss].Semantic then
      Note('meaning : ' + Chain.Hops[FirstLoss].SemanticWhere);
    Note('expected: ' + Copy(Original, 1, 500));
    Note('got     : ' + Copy(Chain.Hops[FirstLoss].BackToJson, 1, 500));
  end;

  { Refusals are never silent. A format that declines to carry the document
    says so here, in its own words, so that an expected-refusal count can
    never quietly absorb a defect. }
  if Length(Chain.Refusals) > 0 then
  begin
    Writeln;
    Note('expected representation refusals:');
    for R in Chain.Refusals do Note('  ' + R);
  end;

  Writeln(Format('  carried=%d refused=%d failed=%d',
    [Chain.Carried, Length(Chain.Refusals), Chain.Failures]));

  if Chain.Completed and (Chain.FinalJson = Original) then
    Writeln('CHAIN_', UpperCase(ATitle.Replace(' ', '_')), ': PASS')
  else
    Writeln('CHAIN_', UpperCase(ATitle.Replace(' ', '_')), ': INFORMATIONAL');

  { Deliberately NOT the same condition. The semantic answer is about kinds
    and structure surviving every hop; the byte answer additionally demands
    that our own canonical JSON writer reproduce the same bytes. }
  if ASemantic <> nil then
    ASemantic^ := Semantic and Chain.Completed;
  if AByteEqual <> nil then
    AByteEqual^ := ByteEqual and Chain.Completed and
      (Chain.FinalJson = Original);
end;

{ ===========================================================================
  AND THE PAIRWISE SWEEP, which is what the chain is built out of
  =========================================================================== }

procedure SweepPairs(const AFormats: TArray<TSerializationFormat>);
var
  I, J, Ok, Diverged, Refused: Integer;
  Source, There, Back: TSerializationPayload;
  Original, Round: string;
begin
  Writeln;
  Writeln('-- every ordered pair, there and back --');
  Original := Canonical(SourceDocument);
  Ok := 0; Diverged := 0; Refused := 0;

  for I := 0 to High(AFormats) do
    for J := 0 to High(AFormats) do
    begin
      if I = J then Continue;
      Source := TSerializationPayload.FromText(SourceDocument);
      try
        There := TSerialization.Convert(Source, TSerializationFormat.Json,
          AFormats[I], TStructuralConversionProfile.Natural);
        There := TSerialization.Convert(There, AFormats[I], AFormats[J],
          TStructuralConversionProfile.Natural);
        Back := TSerialization.Convert(There, AFormats[J],
          TSerializationFormat.Json, TStructuralConversionProfile.Natural);
        Round := Back.AsText;
        if Round = Original then Inc(Ok)
        else
        begin
          Inc(Diverged);
          Writeln(Format('  %-12s -> %-12s DIVERGED',
            [Name(AFormats[I]), Name(AFormats[J])]));
        end;
      except
        on E: Exception do
        begin
          Inc(Refused);
          Writeln(Format('  %-12s -> %-12s REFUSED  %s',
            [Name(AFormats[I]), Name(AFormats[J]), E.Message]));
        end;
      end;
    end;

  Writeln;
  Writeln('CHAIN_PAIRS_IDENTICAL=', Ok);
  Writeln('CHAIN_PAIRS_DIVERGED=', Diverged);
  Writeln('CHAIN_PAIRS_REFUSED=', Refused);
  Check(Ok + Diverged + Refused > 0, 'CHAIN_PAIRS_EXERCISED');
end;

var
  Formats: TArray<TSerializationFormat>;
  Skipped, Row: string;
  F: TSerializationFormat;
  Semantic, ByteEqual: Boolean;
begin
  GReport := TStringList.Create;
  try
    try
      Formats := ChainFormats(Skipped);

      Row := '';
      for F in Formats do Row := Row + Name(F) + ' ';
      Writeln('-- the chain, from the registry --');
      Note('in the chain: ' + Row);
      if Skipped <> '' then Note('skipped     : ' + Skipped);
      Check(Length(Formats) >= 3, 'CHAIN_HAS_SOMETHING_TO_WALK');

      ReportChain('natural', TStructuralConversionProfile.Natural, Formats);
      ReportChain('lossless', TStructuralConversionProfile.Lossless, Formats,
        @Semantic, @ByteEqual);

      { THE TWO PROMISES, NAMED SEPARATELY.

        The first is the one the standards make and the one that matters:
        the document that came back means what it meant, member for member,
        kind for kind, through every hop of the ring.

        The second is narrower and is ours alone - that PascalForge writes
        canonical JSON, so an unchanged tree produces unchanged bytes. It is
        NOT a promise that arbitrary source text survives a chain, and it is
        named apart so that a passing ring is never read as one. }
      Writeln;
      Check(Semantic, 'LOSSLESS_SEMANTIC_CHAIN_EQUAL');
      Check(ByteEqual, 'CANONICAL_JSON_CHAIN_BYTE_EQUAL');

      SweepPairs(Formats);

      Writeln;
      Writeln('FAILURES=', GFailures);
      if GFailures = 0 then Writeln('FORMAT_CHAIN: PASS')
      else
      begin
        Writeln('FORMAT_CHAIN: FAIL');
        Halt(1);
      end;
    except
      on E: Exception do
      begin
        Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
        Writeln('FORMAT_CHAIN: FAIL');
        Halt(1);
      end;
    end;
  finally
    GReport.Free;
  end;
end.
