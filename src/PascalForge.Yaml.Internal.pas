{*******************************************************************************
  PascalForge.Yaml.Internal

  INTERNAL IMPLEMENTATION UNIT - applications should not use this unit directly.

  Implements the YAML engine: parser, emitter, alias expander and the
  contract/dynamic walks.
  Exposed through the public facade PascalForge.Yaml (TYamlSerializer).

  Registration
    Format registration lives in PascalForge.Yaml.Registration and is explicit.

  Documentation
    docs/formats/yaml.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Yaml.Internal;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  The YAML engine.

  NOT PART OF THE PUBLIC API. Everything here is reachable through
  PascalForge.Yaml; this unit exists so that the public one can be read in
  one sitting.

  WHAT IS IN HERE

    TYamlParser   text        -> representation graph
    TYamlEmitter  graph       -> text
    TYamlExpander graph       -> graph, with aliases resolved
    TYamlEngine   everything else: the contract walk, the dynamic bridge,
                  and the configuration that outlives a call.

  WHY A HAND-WRITTEN PARSER

  RAD Studio ships no YAML reader, and the ones available as third-party
  code are either 1.1 or are wrappers around libyaml, which would make this
  library depend on a DLL. So: our own, targeting revision 1.2.2, with the
  1.2 core schema. The differences from 1.1 are not cosmetic - yes is a
  string in 1.2 and a boolean in 1.1, 012 is twelve in 1.2 and ten in 1.1 -
  and getting them right is the whole reason this is not a two-hundred-line
  splitter.

  WHY A DIRECT RTTI WALK AND NOT A CACHED PLAN

  JSON, XML, BSON and MessagePack build a cached plan per type, because
  their members map one-to-one onto a document's members and the plan is a
  pure function of the type. YAML's contract path walks the RTTI directly,
  the way CBOR's does. The reason is the same: emitting a YAML node needs
  decisions that depend on the VALUE and not only on the type - whether a
  string has to be quoted, whether a scalar needs a block style, how deep
  the node sits - so the work a plan would cache is not the work that costs
  anything here. Said plainly so that the difference reads as a decision
  rather than an omission.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections, System.Generics.Defaults,
  System.SyncObjs, System.Math, System.DateUtils, System.NetEncoding,
  System.StrUtils, System.Variants,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Serialization.Internal,
  PascalForge.Nullable,
  PascalForge.Yaml;

type
  { The engine. Everything the public unit delegates to, and nothing else. }
  TYamlEngine = class
  strict private
    class var FLock: TCriticalSection;
    class var FDatePolicies: TDateTimePolicies;
    class var FEnumMappings: TDictionary<string, TArray<string>>;
    class var FTypeSerializers: TDictionary<string, TYamlValueSerializerClass>;
    class var FDefaultEmit: TYamlEmitOptions;
    class var FDuplicateKeys: TYamlDuplicateKeyPolicy;
    class var FLimits: TYamlLimits;
    class var FFrozen: Boolean;
    class procedure CheckNotFrozen; static;
  public
    class constructor Create;
    class destructor Destroy;

    { --- the representation graph --- }
    class function ParseStream(const AYaml: string): TYamlStream; static;
    class function ParseSingleDocument(const AYaml: string): TYamlDocument; static;
    class function EmitStream(AStream: TYamlStream;
      const AOptions: TYamlEmitOptions): string; static;
    class function EmitDocument(ADocument: TYamlDocument;
      const AOptions: TYamlEmitOptions): string; static;
    class function ExpandDocument(ADocument: TYamlDocument): TYamlDocument; static;

    { --- the contract --- }
    class function SerializeRoot(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AOptions: TYamlEmitOptions): string; static;
    class function SerializeRootAll(ATypeInfo: PTypeInfo;
      const AValues: TArray<TValue>;
      const AOptions: TYamlEmitOptions): string; static;
    class function DeserializeRoot(ATypeInfo: PTypeInfo; const AYaml: string;
      const AExisting: TValue): TValue; static;
    class function DeserializeRootAll(ATypeInfo: PTypeInfo;
      const AYaml: string): TArray<TValue>; static;

    { --- cross-format, reached only through the registry --- }
    class function FromPayload(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): string; static;
    class function FromPayloadStructural(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat;
      AProfile: TStructuralConversionProfile): string; static;

    { --- the dynamic tree (structural conversion only) --- }
    class function YamlToDynamic(ANode: TYamlNode;
      const AOptions: TStructuralConversionOptions): TDynamicValue; static;
    class function StreamToDynamic(AStream: TYamlStream;
      const AOptions: TStructuralConversionOptions): TDynamicValue; static;
    class function DynamicToYaml(AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions): TYamlNode; static;

    { --- configuration --- }
    class procedure SetDateTimePolicy(ATypeInfo: PTypeInfo;
      const AFieldName: string; AKind: Integer;
      const APattern: string); static;
    class procedure RegisterEnumMapping(ATypeInfo: PTypeInfo;
      const AValues: array of string); static;
    class procedure RegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TYamlValueSerializerClass); static;
    class procedure SetDefaultEmitOptions(
      const AOptions: TYamlEmitOptions); static;
    class function DefaultEmitOptions: TYamlEmitOptions; static;
    class procedure SetDuplicateKeyPolicy(
      APolicy: TYamlDuplicateKeyPolicy); static;
    class function DuplicateKeyPolicy: TYamlDuplicateKeyPolicy; static;
    class procedure SetLimits(const ALimits: TYamlLimits); static;
    class function Limits: TYamlLimits; static;
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;
    class procedure ResetConfiguration; static;

    class function TryGetEnumMapping(ATypeInfo: PTypeInfo;
      out AValues: TArray<string>): Boolean; static;
    class function TryGetTypeSerializer(ATypeInfo: PTypeInfo;
      out AClass: TYamlValueSerializerClass): Boolean; static;
    class function DatePolicyFor(ATypeInfo: PTypeInfo;
      const AFieldName: string): TDateTimePolicy; static;
  end;

implementation

var
  GCtx: TRttiContext;

{ A stable key for a type. Two types can share a name across units, so the
  address goes in too. }
function TypeKeyOf(ATypeInfo: PTypeInfo): string;
begin
  if ATypeInfo = nil then Exit('');
  Result := UTF8ToString(ATypeInfo.Name) + IntToHex(NativeUInt(ATypeInfo), 8);
end;

{ ===========================================================================
  THE PARSER

  YAML's grammar is context-sensitive in one specific way that shapes
  everything below: a node's extent is decided by INDENTATION in block
  context and by BRACKETS in flow context, and the two nest inside each
  other. So there are two parsers here, and they call each other.

  The block parser works a line at a time and is driven by the column of the
  first non-space character. The flow parser works a character at a time and
  is driven by the bracket and brace pairs and by commas.

  Position is tracked as an index into the whole text plus the index of the
  current line's first character, which makes the column a subtraction and
  means a parse error can always say where.
  =========================================================================== }

type
  TYamlParser = class
  strict private
    FText: string;
    FPos: Integer;
    FLine: Integer;
    FLineStart: Integer;
    FDepth: Integer;
    FLimits: TYamlLimits;
    FDuplicates: TYamlDuplicateKeyPolicy;
    FDocument: TYamlDocument;
    FTagHandles: TDictionary<string, string>;

    function AtEnd: Boolean; inline;
    function Cur: Char; inline;
    function At(AOffset: Integer): Char;
    procedure Advance;
    procedure AdvanceBy(ACount: Integer);
    function Column: Integer; inline;
    procedure Fail(const AReason: string);
    procedure RequirePrintable;
    procedure FailTab;

    procedure SkipSpaces;
    procedure SkipToLineEnd;
    procedure SkipLineBreak;
    { Skips blank lines and whole-line comments, leaving FPos on the first
      character of the next line that has content - or at the end. }
    procedure SkipBlanks;
    function LineIndent: Integer;
    function AtDocumentMarker(out AIsEnd: Boolean): Boolean;

    procedure EnterDepth;
    procedure LeaveDepth; inline;

    { Node properties - an anchor, a tag, or both in either order. }
    procedure ReadProperties(out AAnchor, ATag: string);
    function ResolveTag(const AHandle: string): string;

    function ReadPlainScalar(AIndent: Integer; AInFlow: Boolean): string;
    function ReadSingleQuoted: string;
    function ReadDoubleQuoted: string;
    function ReadBlockScalar(AIndent: Integer; AFolded: Boolean): string;

    function ParseFlowNode: TYamlNode;
    function ParseFlowSequence: TYamlNode;
    function ParseFlowMapping: TYamlNode;

    function ParseBlockNode(AIndent: Integer): TYamlNode;
    function ParseBlockSequence(AIndent: Integer): TYamlNode;
    function ParseBlockMapping(AIndent: Integer): TYamlNode;
    function LooksLikeBlockMapping: Boolean;

    procedure RegisterAnchors(ANode: TYamlNode);
    procedure AddMapPair(AMap, AKey, AValue: TYamlNode);
    function ParseDirectives(ADocument: TYamlDocument): Boolean;
  public
    constructor Create(const AText: string; const ALimits: TYamlLimits;
      ADuplicates: TYamlDuplicateKeyPolicy);
    destructor Destroy; override;
    function ParseStream: TYamlStream;
  end;

constructor TYamlParser.Create(const AText: string;
  const ALimits: TYamlLimits; ADuplicates: TYamlDuplicateKeyPolicy);
begin
  inherited Create;
  { A byte-order mark is not content. Leaving it in would make the first key
    of every document written by Notepad a key nobody can match. }
  FText := AText;
  if (FText <> '') and (FText[1] = #$FEFF) then Delete(FText, 1, 1);
  { Normalise line breaks once, here, so that nothing below has to ask which
    of the three forms it is looking at. }
  FText := StringReplace(FText, #13#10, #10, [rfReplaceAll]);
  FText := StringReplace(FText, #13, #10, [rfReplaceAll]);
  RequirePrintable;
  FPos := 1;
  FLine := 1;
  FLineStart := 1;
  FLimits := ALimits;
  FDuplicates := ADuplicates;
  FTagHandles := TDictionary<string, string>.Create;
end;

destructor TYamlParser.Destroy;
begin
  FTagHandles.Free;
  inherited Destroy;
end;

{ YAML 1.2 section 5.1: a stream holds printable characters, and inside a
  quoted scalar - for JSON compatibility - anything but a C0 control. So a
  C0 control other than tab and line feed is never YAML, wherever it is, and
  is refused before the scanner starts: the scanner marks the end of the
  text with #0, and a NUL inside the text sent it round forever, allocating
  until the process ran out of memory. (Line breaks are already normalised
  to #10 by the time this runs.) }
procedure TYamlParser.RequirePrintable;
var
  I, Line, LineStart: Integer;
  C: Char;
begin
  Line := 1;
  LineStart := 1;
  for I := 1 to Length(FText) do
  begin
    C := FText[I];
    if C = #10 then
    begin
      Inc(Line);
      LineStart := I + 1;
    end
    else if (C < #$20) and (C <> #9) then
      raise EYamlParseError.CreateAt(Line, I - LineStart + 1, Format(
        'U+%.4X is a control character, and a YAML stream holds printable ' +
        'text only (specification 1.2, section 5.1). Write it as an escape ' +
        'in a double-quoted scalar, or carry binary data as !!binary.',
        [Ord(C)]));
  end;
end;

function TYamlParser.AtEnd: Boolean;
begin
  Result := FPos > Length(FText);
end;

function TYamlParser.Cur: Char;
begin
  if AtEnd then Result := #0 else Result := FText[FPos];
end;

function TYamlParser.At(AOffset: Integer): Char;
begin
  if FPos + AOffset > Length(FText) then Result := #0
  else Result := FText[FPos + AOffset];
end;

procedure TYamlParser.Advance;
begin
  if AtEnd then Exit;
  if FText[FPos] = #10 then
  begin
    Inc(FLine);
    FLineStart := FPos + 1;
  end;
  Inc(FPos);
end;

procedure TYamlParser.AdvanceBy(ACount: Integer);
var
  I: Integer;
begin
  for I := 1 to ACount do Advance;
end;

function TYamlParser.Column: Integer;
begin
  Result := FPos - FLineStart;
end;

procedure TYamlParser.Fail(const AReason: string);
begin
  raise EYamlParseError.CreateAt(FLine, Column + 1, AReason);
end;

procedure TYamlParser.FailTab;
begin
  raise EYamlTabIndentationError.CreateAt(FLine, Column + 1,
    'A tab character cannot be used for indentation in YAML. Use spaces. ' +
    'This is the specification''s rule, not this library''s preference: a ' +
    'tab has no defined width, so a document indented with tabs has no ' +
    'defined structure');
end;

procedure TYamlParser.EnterDepth;
begin
  Inc(FDepth);
  if FDepth > FLimits.MaxDepth then
    raise EYamlLimitExceeded.CreateFmt(
      'This document nests more than %d levels deep, which is past the ' +
      'limit. A document that deep is far more often a generated attack ' +
      'than a design; TYamlSerializer.SetLimits moves the line.',
      [FLimits.MaxDepth]);
end;

procedure TYamlParser.LeaveDepth;
begin
  Dec(FDepth);
end;

procedure TYamlParser.SkipSpaces;
begin
  while (not AtEnd) and (Cur = ' ') do Advance;
end;

procedure TYamlParser.SkipToLineEnd;
begin
  while (not AtEnd) and (Cur <> #10) do Advance;
end;

procedure TYamlParser.SkipLineBreak;
begin
  if (not AtEnd) and (Cur = #10) then Advance;
end;

{ Skip whatever is not content: spaces, blank lines and comments. Stops on
  the first character that is part of a node, with the column correct.

  The tab rule is here and nowhere else. A tab is ordinary whitespace when
  something has already appeared on the line and is an error when it IS the
  indentation - because a tab has no defined width, so a document indented
  with tabs has no defined structure, and YAML forbids it outright rather
  than guessing. }
procedure TYamlParser.SkipBlanks;
begin
  while not AtEnd do
  begin
    if Cur = ' ' then
    begin
      Advance;
      Continue;
    end;
    if Cur = #9 then
    begin
      if FPos = FLineStart then FailTab;
      { A tab that follows spaces at the head of a line is still
        indentation, whatever came before it. }
      if Trim(Copy(FText, FLineStart, FPos - FLineStart)) = '' then FailTab;
      Advance;
      Continue;
    end;
    if Cur = '#' then
    begin
      SkipToLineEnd;
      Continue;
    end;
    if Cur = #10 then
    begin
      Advance;
      Continue;
    end;
    Exit;
  end;
end;

function TYamlParser.LineIndent: Integer;
var
  I: Integer;
begin
  I := FLineStart;
  Result := 0;
  while (I <= Length(FText)) and (FText[I] = ' ') do
  begin
    Inc(Result);
    Inc(I);
  end;
end;

function TYamlParser.AtDocumentMarker(out AIsEnd: Boolean): Boolean;
begin
  AIsEnd := False;
  Result := False;
  if FPos <> FLineStart then Exit;
  if (At(0) = '-') and (At(1) = '-') and (At(2) = '-') and
     ((At(3) = #0) or (At(3) = ' ') or (At(3) = #10)) then Exit(True);
  if (At(0) = '.') and (At(1) = '.') and (At(2) = '.') and
     ((At(3) = #0) or (At(3) = ' ') or (At(3) = #10)) then
  begin
    AIsEnd := True;
    Exit(True);
  end;
end;

{ --------------------------------------------------------------- scalars --- }

{ A plain scalar: no quotes, and therefore the one style the core schema
  resolves. It ends at a comment, at a structural character in flow context,
  or at a line that is not a continuation.

  Continuation lines are folded into single spaces, which is what the
  specification says a plain multi-line scalar means. }
function TYamlParser.ReadPlainScalar(AIndent: Integer;
  AInFlow: Boolean): string;
var
  Buf: TStringBuilder;
  Piece: string;
  Start: Integer;
  Blanks: Integer;
  NextIndent: Integer;
  SaveLine, SaveLineStart: Integer;
begin
  Buf := TStringBuilder.Create;
  try
    while True do
    begin
      Start := FPos;
      while not AtEnd do
      begin
        if Cur = #10 then Break;
        if (Cur = '#') and (FPos > Start) and
           ((FText[FPos - 1] = ' ') or (FText[FPos - 1] = #9)) then Break;
        if AInFlow and CharInSet(Cur, [',', '[', ']', '{', '}']) then Break;
        { A colon ends a plain scalar only when it is followed by space or
          end - which is why http://example.com is one scalar and a: b is
          two. }
        if (Cur = ':') and
           ((At(1) = #0) or (At(1) = ' ') or (At(1) = #10) or
            (AInFlow and CharInSet(At(1), [',', '[', ']', '{', '}']))) then
          Break;
        Advance;
      end;
      Piece := TrimRight(Copy(FText, Start, FPos - Start));
      if Buf.Length > 0 then Buf.Append(' ');
      Buf.Append(Piece);

      if AInFlow then Break;
      if AtEnd or (Cur <> #10) then Break;

      { A continuation line has to be MORE indented than the node and must
        not start a new construct. Deciding that means looking at the next
        line, so the position is saved FIRST - and the line and the line's
        start with it, because rewinding FPos alone would leave the column
        counter pointing at a line the parser is no longer on, and every
        error message after that would name the wrong place. }
      SaveLine := FLine;
      SaveLineStart := FLineStart;
      Blanks := FPos;
      SkipLineBreak;
      while (not AtEnd) and (Cur = #10) do Advance;
      NextIndent := LineIndent;
      if AtEnd or (NextIndent <= AIndent) then
      begin
        FPos := Blanks;
        FLine := SaveLine;
        FLineStart := SaveLineStart;
        Break;
      end;
      SkipSpaces;
      if Cur = '#' then
      begin
        FPos := Blanks;
        FLine := SaveLine;
        FLineStart := SaveLineStart;
        Break;
      end;
    end;
    Result := Buf.ToString;
  finally
    Buf.Free;
  end;
end;

function TYamlParser.ReadSingleQuoted: string;
var
  OpenLine, OpenColumn: Integer;
  Buf: TStringBuilder;
begin
  { The position of the OPENING quote, because that is where the reader has
    to look. An unclosed quote is only noticed at the end of the stream, and
    reporting the end of the file tells nobody anything. }
  OpenLine := FLine;
  OpenColumn := Column + 1;
  Advance; { the opening quote }
  Buf := TStringBuilder.Create;
  try
    while True do
    begin
      if AtEnd then
        raise EYamlUnclosedQuoteError.CreateAt(OpenLine, OpenColumn,
          'A single-quoted scalar opens here and reaches the end of the ' +
          'stream without its closing quote');
      if Cur = '''' then
      begin
        { Two single quotes are one. That is the ONLY escape a single-quoted
          scalar has - a backslash in one is a backslash. }
        if At(1) = '''' then
        begin
          Buf.Append('''');
          Advance;
          Advance;
          Continue;
        end;
        Advance;
        Break;
      end;
      if Cur = #10 then
      begin
        { A line break inside a quoted scalar folds to a space, and the
          indentation of the next line is not content. }
        Advance;
        while (not AtEnd) and ((Cur = ' ') or (Cur = #9)) do Advance;
        Buf.Append(' ');
        Continue;
      end;
      Buf.Append(Cur);
      Advance;
    end;
    Result := Buf.ToString;
  finally
    Buf.Free;
  end;
end;

{ The escape table of a double-quoted scalar, which is the only style that
  has one. \u and \U are here because a YAML document may name a code point
  it cannot otherwise spell - and \U reaches past the basic plane, so the
  result may be a surrogate pair. }
function TYamlParser.ReadDoubleQuoted: string;
var
  Buf: TStringBuilder;
  Code: Integer;
  Digits: string;
  OpenLine, OpenColumn: Integer;

  procedure ReadHex(ACount: Integer);
  var
    K: Integer;
  begin
    Digits := '';
    for K := 1 to ACount do
    begin
      if AtEnd then Fail('A \x, \u or \U escape is cut short');
      Digits := Digits + Cur;
      Advance;
    end;
    if not TryStrToInt('$' + Digits, Code) then
      Fail('"' + Digits + '" is not hexadecimal, so this escape names no ' +
        'character');
  end;

begin
  { The position of the OPENING quote - see ReadSingleQuoted. }
  OpenLine := FLine;
  OpenColumn := Column + 1;
  Advance; { the opening quote }
  Buf := TStringBuilder.Create;
  try
    while True do
    begin
      if AtEnd then
        raise EYamlUnclosedQuoteError.CreateAt(OpenLine, OpenColumn,
          'A double-quoted scalar opens here and reaches the end of the ' +
          'stream without its closing quote');
      if Cur = '"' then
      begin
        Advance;
        Break;
      end;
      if Cur = '\' then
      begin
        Advance;
        if AtEnd then Fail('A backslash escape is cut short');
        case Cur of
          '0': begin Buf.Append(#0); Advance; end;
          'a': begin Buf.Append(#7); Advance; end;
          'b': begin Buf.Append(#8); Advance; end;
          't': begin Buf.Append(#9); Advance; end;
          #9:  begin Buf.Append(#9); Advance; end;
          'n': begin Buf.Append(#10); Advance; end;
          'v': begin Buf.Append(#11); Advance; end;
          'f': begin Buf.Append(#12); Advance; end;
          'r': begin Buf.Append(#13); Advance; end;
          'e': begin Buf.Append(#27); Advance; end;
          ' ': begin Buf.Append(' '); Advance; end;
          '"': begin Buf.Append('"'); Advance; end;
          '/': begin Buf.Append('/'); Advance; end;
          '\': begin Buf.Append('\'); Advance; end;
          'N': begin Buf.Append(#$0085); Advance; end;
          '_': begin Buf.Append(#$00A0); Advance; end;
          'L': begin Buf.Append(#$2028); Advance; end;
          'P': begin Buf.Append(#$2029); Advance; end;
          'x': begin Advance; ReadHex(2); Buf.Append(Char(Code)); end;
          'u': begin Advance; ReadHex(4); Buf.Append(Char(Code)); end;
          'U':
            begin
              Advance;
              ReadHex(8);
              if Code > $10FFFF then
                Fail('U+' + Digits + ' is past the end of Unicode');
              if Code > $FFFF then
              begin
                { Delphi strings are UTF-16, so an astral code point is two
                  units and has to be written as the pair it will be read
                  back as. }
                Dec(Code, $10000);
                Buf.Append(Char($D800 or (Code shr 10)));
                Buf.Append(Char($DC00 or (Code and $3FF)));
              end
              else
                Buf.Append(Char(Code));
            end;
          #10:
            begin
              { An escaped line break joins the lines with nothing between
                them - which is how a long single-line string is written
                across several lines. }
              Advance;
              while (not AtEnd) and ((Cur = ' ') or (Cur = #9)) do Advance;
            end;
        else
          Fail('\' + Cur + ' is not an escape YAML defines');
        end;
        Continue;
      end;
      if Cur = #10 then
      begin
        Advance;
        while (not AtEnd) and ((Cur = ' ') or (Cur = #9)) do Advance;
        Buf.Append(' ');
        Continue;
      end;
      Buf.Append(Cur);
      Advance;
    end;
    Result := Buf.ToString;
  finally
    Buf.Free;
  end;
end;

{ A literal (|) or folded (>) block scalar.

  The header may carry an explicit indentation indicator and a chomping
  indicator, in either order: |2-, |-2, >+ and so on. The indentation
  indicator exists for the one case the automatic rule cannot handle - a
  block whose first line is itself indented - and leaving it out is why some
  YAML libraries mangle exactly that document. }
function TYamlParser.ReadBlockScalar(AIndent: Integer;
  AFolded: Boolean): string;
var
  Chomp: TYamlChomping;
  Explicit: Integer;
  Indent: Integer;
  Lines: TStringList;
  Buf: TStringBuilder;
  Text: string;
  I, LastContent: Integer;
  ThisIndent: Integer;
  Start: Integer;
  MoreIndented: Boolean;
  PrevBlank: Boolean;
begin
  Advance; { the | or > }
  Chomp := TYamlChomping.Clip;
  Explicit := 0;
  while (not AtEnd) and CharInSet(Cur, ['-', '+', '0'..'9']) do
  begin
    case Cur of
      '-': Chomp := TYamlChomping.Strip;
      '+': Chomp := TYamlChomping.Keep;
      '1'..'9': Explicit := Ord(Cur) - Ord('0');
      '0': Fail('0 is not a valid block-scalar indentation indicator: ' +
             'the content of a block scalar is always indented at least ' +
             'one space past its parent');
    end;
    Advance;
  end;
  SkipSpaces;
  if (not AtEnd) and (Cur = '#') then SkipToLineEnd;
  if (not AtEnd) and (Cur <> #10) then
    Fail('A block scalar header is followed by its content on the NEXT ' +
      'line; "' + Cur + '" here is neither a chomping indicator nor a ' +
      'comment');
  SkipLineBreak;

  Lines := TStringList.Create;
  try
    Indent := -1;
    if Explicit > 0 then Indent := AIndent + Explicit;

    while not AtEnd do
    begin
      Start := FPos;
      ThisIndent := 0;
      while (not AtEnd) and (Cur = ' ') do
      begin
        Inc(ThisIndent);
        Advance;
      end;
      if (not AtEnd) and (Cur = #9) and (Indent >= 0) and
         (ThisIndent < Indent) then FailTab;

      if AtEnd then
      begin
        if ThisIndent > 0 then Lines.Add('');
        Break;
      end;

      if Cur = #10 then
      begin
        { A blank line belongs to the block whatever its indentation, and
          how many there are matters. }
        Lines.Add('');
        Advance;
        Continue;
      end;

      if Indent < 0 then
      begin
        { The first non-blank line fixes the indentation. }
        if ThisIndent <= AIndent then
        begin
          FPos := Start;
          Break;
        end;
        Indent := ThisIndent;
      end
      else if ThisIndent < Indent then
      begin
        FPos := Start;
        Break;
      end;

      Start := FPos;
      SkipToLineEnd;
      Lines.Add(StringOfChar(' ', ThisIndent - Indent) +
        Copy(FText, Start, FPos - Start));
      SkipLineBreak;
    end;

    { Trailing blank lines are what chomping is about, so find where the
      content actually ends before folding anything. }
    LastContent := -1;
    for I := 0 to Lines.Count - 1 do
      if Trim(Lines[I]) <> '' then LastContent := I;

    Buf := TStringBuilder.Create;
    try
      if not AFolded then
      begin
        for I := 0 to LastContent do
        begin
          Buf.Append(Lines[I]);
          Buf.Append(#10);
        end;
      end
      else
      begin
        { Folding: a single line break between two non-blank, non-indented
          lines becomes a space; a blank line becomes a break; and a line
          that is MORE indented than the block keeps its breaks, which is
          how a folded scalar carries a code sample. }
        PrevBlank := False;
        for I := 0 to LastContent do
        begin
          if Lines[I] = '' then
          begin
            Buf.Append(#10);
            PrevBlank := True;
            Continue;
          end;
          MoreIndented := (Lines[I] <> '') and (Lines[I][1] = ' ');
          if (Buf.Length > 0) and (not PrevBlank) then
          begin
            if MoreIndented or
               ((I > 0) and (Lines[I - 1] <> '') and (Lines[I - 1][1] = ' ')) then
              Buf.Append(#10)
            else
              Buf.Append(' ');
          end;
          Buf.Append(Lines[I]);
          PrevBlank := False;
        end;
        if LastContent >= 0 then Buf.Append(#10);
      end;
      Text := Buf.ToString;
    finally
      Buf.Free;
    end;

    case Chomp of
      TYamlChomping.Strip:
        while (Text <> '') and (Text[Length(Text)] = #10) do
          SetLength(Text, Length(Text) - 1);
      TYamlChomping.Keep:
        for I := LastContent + 1 to Lines.Count - 1 do Text := Text + #10;
    end;
    Result := Text;
  finally
    Lines.Free;
  end;
end;

{ ------------------------------------------------------------ properties --- }

function TYamlParser.ResolveTag(const AHandle: string): string;
var
  Prefix: string;
  I: Integer;
begin
  { '!!x' is the secondary handle and means YAML's own type repository;
    '!x' is the primary handle, which a %TAG directive may redirect; and
    '!<...>' is a verbatim URI that no handle applies to. }
  if AHandle = '' then Exit('');
  if Copy(AHandle, 1, 2) = '!<' then
    Exit(Copy(AHandle, 3, Length(AHandle) - 3));
  if Copy(AHandle, 1, 2) = '!!' then
  begin
    if FTagHandles.TryGetValue('!!', Prefix) then
      Exit(Prefix + Copy(AHandle, 3, MaxInt));
    Exit(TYamlSchema.DefaultPrefix + Copy(AHandle, 3, MaxInt));
  end;
  { A named handle, !e!thing. }
  I := Pos('!', AHandle, 2);
  if I > 1 then
  begin
    if FTagHandles.TryGetValue(Copy(AHandle, 1, I), Prefix) then
      Exit(Prefix + Copy(AHandle, I + 1, MaxInt));
  end;
  if FTagHandles.TryGetValue('!', Prefix) then
    Exit(Prefix + Copy(AHandle, 2, MaxInt));
  Result := AHandle;
end;

procedure TYamlParser.ReadProperties(out AAnchor, ATag: string);
var
  Start: Integer;
begin
  AAnchor := '';
  ATag := '';
  while True do
  begin
    SkipSpaces;
    if AtEnd then Exit;
    if Cur = '&' then
    begin
      Advance;
      Start := FPos;
      while (not AtEnd) and (not CharInSet(Cur,
        [' ', #9, #10, ',', '[', ']', '{', '}'])) do Advance;
      AAnchor := Copy(FText, Start, FPos - Start);
      if AAnchor = '' then Fail('An & introduces an anchor and this one has ' +
        'no name');
      Continue;
    end;
    if Cur = '!' then
    begin
      Start := FPos;
      if At(1) = '<' then
      begin
        while (not AtEnd) and (Cur <> '>') do Advance;
        if AtEnd then Fail('A verbatim tag !<...> is not closed');
        Advance;
      end
      else
        while (not AtEnd) and (not CharInSet(Cur,
          [' ', #9, #10, ',', '[', ']', '{', '}'])) do Advance;
      ATag := ResolveTag(Copy(FText, Start, FPos - Start));
      Continue;
    end;
    Exit;
  end;
end;

procedure TYamlParser.RegisterAnchors(ANode: TYamlNode);
var
  I: Integer;
begin
  if ANode = nil then Exit;
  if ANode.Anchor <> '' then FDocument.RegisterAnchor(ANode.Anchor, ANode);
  case ANode.Kind of
    TYamlKind.Sequence:
      for I := 0 to ANode.Count - 1 do RegisterAnchors(ANode.Items[I]);
    TYamlKind.Mapping:
      for I := 0 to ANode.Count - 1 do
      begin
        RegisterAnchors(ANode.Keys[I]);
        RegisterAnchors(ANode.Items[I]);
      end;
  end;
end;

procedure TYamlParser.AddMapPair(AMap, AKey, AValue: TYamlNode);
var
  Name: string;
  I: Integer;
begin
  if (AKey <> nil) and (AKey.Kind = TYamlKind.Scalar) then
  begin
    Name := AKey.Value;
    for I := 0 to AMap.Count - 1 do
      if (AMap.Keys[I].Kind = TYamlKind.Scalar) and
         (AMap.Keys[I].Value = Name) then
      begin
        case FDuplicates of
          TYamlDuplicateKeyPolicy.Error:
            begin
              AKey.Free;
              AValue.Free;
              raise EYamlDuplicateKeyError.CreateAt(FLine, Column + 1,
                Format('The key "%s" appears twice in one mapping. YAML ' +
                  'says a mapping''s keys are unique, so this document ' +
                  'does not say what it looks like it says; ' +
                  'TYamlSerializer.SetDuplicateKeyPolicy relaxes this for ' +
                  'a file you did not write', [Name]));
            end;
          TYamlDuplicateKeyPolicy.FirstWins:
            begin
              AKey.Free;
              AValue.Free;
              Exit;
            end;
          TYamlDuplicateKeyPolicy.LastWins:
            begin
              { Replacing in place keeps the position the document gave the
                key, which is what a reader expects to see again. }
              AMap.Replace(I, AKey, AValue);
              Exit;
            end;
        end;
      end;
  end;
  AMap.Add(AKey, AValue);
end;

{ ------------------------------------------------------------------ flow --- }

function TYamlParser.ParseFlowSequence: TYamlNode;
begin
  EnterDepth;
  try
    Advance; { [ }
    Result := TYamlNode.NewSequence;
    try
      while True do
      begin
        SkipBlanks;
        if AtEnd then Fail('A flow sequence is not closed');
        if Cur = ']' then
        begin
          Advance;
          Break;
        end;
        Result.Add(ParseFlowNode);
        SkipBlanks;
        if AtEnd then Fail('A flow sequence is not closed');
        if Cur = ',' then
        begin
          Advance;
          Continue;
        end;
        if Cur = ']' then
        begin
          Advance;
          Break;
        end;
        Fail('"' + Cur + '" is neither a comma nor a closing bracket');
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    LeaveDepth;
  end;
end;

function TYamlParser.ParseFlowMapping: TYamlNode;
var
  Key, Value, K, V: TYamlNode;
begin
  EnterDepth;
  { A key read and its value not yet: if the value fails - a document cut
    short, the nesting limit reached - the key belongs to nobody, and it
    leaked. Key and Value hold what is not yet in the mapping, and are
    cleared the moment AddMapPair owns them (it frees both itself if it
    refuses them). }
  Key := nil;
  Value := nil;
  try
    Advance; { the brace }
    Result := TYamlNode.NewMapping;
    try
      while True do
      begin
        SkipBlanks;
        if AtEnd then Fail('A flow mapping is not closed');
        if Cur = '}' then
        begin
          Advance;
          Break;
        end;
        if Cur = '?' then
        begin
          Advance;
          SkipBlanks;
        end;
        Key := ParseFlowNode;
        SkipBlanks;
        if (not AtEnd) and (Cur = ':') then
        begin
          Advance;
          SkipBlanks;
          if AtEnd or CharInSet(Cur, [',', '}']) then Value := TYamlNode.NewNull
          else Value := ParseFlowNode;
        end
        else
          { A flow mapping entry with no value is a key whose value is null,
            which is what a comma-separated flow mapping of bare keys
            means. }
          Value := TYamlNode.NewNull;
        K := Key;
        V := Value;
        Key := nil;
        Value := nil;
        AddMapPair(Result, K, V);
        SkipBlanks;
        if AtEnd then Fail('A flow mapping is not closed');
        if Cur = ',' then
        begin
          Advance;
          Continue;
        end;
        if Cur = '}' then
        begin
          Advance;
          Break;
        end;
        Fail('"' + Cur + '" is neither a comma nor a closing brace');
      end;
    except
      Key.Free;
      Value.Free;
      Result.Free;
      raise;
    end;
  finally
    LeaveDepth;
  end;
end;

function TYamlParser.ParseFlowNode: TYamlNode;
var
  Anchor, Tag, Text: string;
  Start: Integer;
begin
  ReadProperties(Anchor, Tag);
  SkipBlanks;
  if AtEnd then Exit(TYamlNode.NewNull);

  if Cur = '*' then
  begin
    Advance;
    Start := FPos;
    while (not AtEnd) and (not CharInSet(Cur,
      [' ', #9, #10, ',', '[', ']', '{', '}'])) do Advance;
    Result := TYamlNode.NewAlias(Copy(FText, Start, FPos - Start));
    Exit;
  end;

  if Cur = '[' then Result := ParseFlowSequence
  else if Cur = '{' then Result := ParseFlowMapping
  else if Cur = '''' then
    Result := TYamlNode.NewScalar(ReadSingleQuoted,
      TYamlScalarStyle.SingleQuoted)
  else if Cur = '"' then
    Result := TYamlNode.NewScalar(ReadDoubleQuoted,
      TYamlScalarStyle.DoubleQuoted)
  else
  begin
    Text := ReadPlainScalar(0, True);
    Result := TYamlNode.NewScalar(Text, TYamlScalarStyle.Plain);
  end;

  Result.Anchor := Anchor;
  if Tag <> '' then Result.Tag := Tag;
end;

{ ----------------------------------------------------------------- block --- }

{ Does the content starting here introduce a block mapping?

  The question is whether a key is followed by ':' at this level. It has to
  be answered by looking ahead, because a plain scalar and a mapping key are
  the same characters until the colon arrives - and the scan must not be
  fooled by a colon inside quotes or inside a flow collection. }
function TYamlParser.LooksLikeBlockMapping: Boolean;
var
  I, Depth: Integer;
  Quote: Char;
begin
  I := FPos;
  Depth := 0;
  Quote := #0;
  while I <= Length(FText) do
  begin
    if Quote <> #0 then
    begin
      if FText[I] = Quote then
      begin
        if (Quote = '''') and (I < Length(FText)) and (FText[I + 1] = '''') then
          Inc(I)
        else
          Quote := #0;
      end
      else if FText[I] = #10 then Exit(False);
      Inc(I);
      Continue;
    end;
    case FText[I] of
      '''', '"': Quote := FText[I];
      '[', '{': Inc(Depth);
      ']', '}': Dec(Depth);
      '#':
        if (I > FPos) and CharInSet(FText[I - 1], [' ', #9]) then Exit(False);
      #10: Exit(False);
      ':':
        if Depth = 0 then
        begin
          if (I = Length(FText)) or CharInSet(FText[I + 1], [' ', #9, #10]) then
            Exit(True);
        end;
    end;
    Inc(I);
  end;
  Result := False;
end;

function TYamlParser.ParseBlockSequence(AIndent: Integer): TYamlNode;
var
  Indent: Integer;
  Anchor, Tag: string;
  Item: TYamlNode;
  Dummy: Boolean;
begin
  EnterDepth;
  try
    Result := TYamlNode.NewSequence;
    try
      Indent := Column;
      while True do
      begin
        if AtEnd then Break;
        if AtDocumentMarker(Dummy) then Break;
        if Column <> Indent then Break;
        if not ((Cur = '-') and ((At(1) = ' ') or (At(1) = #10) or
                                 (At(1) = #0))) then Break;
        Advance; { the dash }
        SkipSpaces;

        if AtEnd or (Cur = #10) or (Cur = '#') then
        begin
          { "-" alone on its line: the item is whatever comes below it, or
            null when nothing does. }
          SkipBlanks;
          if AtEnd or (LineIndent <= Indent) then
            Item := TYamlNode.NewNull
          else
            Item := ParseBlockNode(Indent);
        end
        else
        begin
          ReadProperties(Anchor, Tag);
          if AtEnd or (Cur = #10) then
          begin
            SkipBlanks;
            if AtEnd or (LineIndent <= Indent) then Item := TYamlNode.NewNull
            else Item := ParseBlockNode(Indent);
          end
          else
            { The item starts on the dash's own line, so its indentation for
              nesting purposes is where it actually begins. }
            Item := ParseBlockNode(Column - 1);
          if Anchor <> '' then Item.Anchor := Anchor;
          if Tag <> '' then Item.Tag := Tag;
        end;
        Result.Add(Item);

        SkipBlanks;
        if AtEnd then Break;
        if LineIndent < Indent then Break;
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    LeaveDepth;
  end;
end;

function TYamlParser.ParseBlockMapping(AIndent: Integer): TYamlNode;
var
  Indent: Integer;
  Key, Value, K, V: TYamlNode;
  Anchor, Tag: string;
  Dummy: Boolean;
  KeyColumn: Integer;
begin
  EnterDepth;
  { As in ParseFlowMapping: a key whose value fails is freed, not leaked. }
  Key := nil;
  Value := nil;
  try
    Result := TYamlNode.NewMapping;
    try
      Indent := Column;
      while True do
      begin
        if AtEnd then Break;
        if AtDocumentMarker(Dummy) then Break;
        if Column <> Indent then Break;

        if (Cur = '?') and ((At(1) = ' ') or (At(1) = #10)) then
        begin
          { An explicit key. This is how YAML writes a key that is itself a
            sequence or a mapping, and flattening it to text here would be
            the only chance to see it, gone. }
          Advance;
          SkipSpaces;
          if AtEnd or (Cur = #10) then
          begin
            SkipBlanks;
            Key := ParseBlockNode(Indent);
          end
          else
            Key := ParseBlockNode(Column - 1);
          SkipBlanks;
          if (not AtEnd) and (Cur = ':') and
             ((At(1) = ' ') or (At(1) = #10) or (At(1) = #0)) then
          begin
            Advance;
            SkipSpaces;
            if AtEnd or (Cur = #10) or (Cur = '#') then
            begin
              SkipBlanks;
              if AtEnd or (LineIndent <= Indent) then Value := TYamlNode.NewNull
              else Value := ParseBlockNode(Indent);
            end
            else
              Value := ParseBlockNode(Column - 1);
          end
          else
            Value := TYamlNode.NewNull;
          K := Key;
          V := Value;
          Key := nil;
          Value := nil;
          AddMapPair(Result, K, V);
          SkipBlanks;
          if AtEnd or (LineIndent < Indent) then Break;
          Continue;
        end;

        KeyColumn := Column;
        ReadProperties(Anchor, Tag);
        if Cur = '''' then
          Key := TYamlNode.NewScalar(ReadSingleQuoted,
            TYamlScalarStyle.SingleQuoted)
        else if Cur = '"' then
          Key := TYamlNode.NewScalar(ReadDoubleQuoted,
            TYamlScalarStyle.DoubleQuoted)
        else if Cur = '[' then Key := ParseFlowSequence
        else if Cur = '{' then Key := ParseFlowMapping
        else
          Key := TYamlNode.NewScalar(ReadPlainScalar(KeyColumn, False),
            TYamlScalarStyle.Plain);
        if Anchor <> '' then Key.Anchor := Anchor;
        if Tag <> '' then Key.Tag := Tag;

        SkipSpaces;
        if AtEnd or (Cur <> ':') then
          Fail('A block mapping entry needs a colon after its key');
        Advance;

        SkipSpaces;
        if AtEnd or (Cur = #10) or (Cur = '#') then
        begin
          SkipBlanks;
          { The value is on the following lines, and it has to be MORE
            indented than the key - with one exception the specification
            grants and real files use constantly: a block SEQUENCE may sit
            at the key's own column.

                ports:
                - 80
                - 443

            Without the exception that reads as a null value followed by a
            sequence nobody asked for, and the document silently loses its
            ports. }
          if AtEnd or AtDocumentMarker(Dummy) then
            Value := TYamlNode.NewNull
          else if LineIndent > Indent then
            Value := ParseBlockNode(Indent)
          else if (LineIndent = Indent) and (Cur = '-') and
                  ((At(1) = ' ') or (At(1) = #10) or (At(1) = #0)) then
            Value := ParseBlockSequence(Indent)
          else
            Value := TYamlNode.NewNull;
        end
        else
          Value := ParseBlockNode(Indent);

        K := Key;
        V := Value;
        Key := nil;
        Value := nil;
        AddMapPair(Result, K, V);

        SkipBlanks;
        if AtEnd then Break;
        if AtDocumentMarker(Dummy) then Break;
        if LineIndent < Indent then Break;
      end;
    except
      Key.Free;
      Value.Free;
      Result.Free;
      raise;
    end;
  finally
    LeaveDepth;
  end;
end;

function TYamlParser.ParseBlockNode(AIndent: Integer): TYamlNode;
var
  Anchor, Tag, Text: string;
  Start: Integer;
  Folded: Boolean;
begin
  SkipBlanks;
  if AtEnd then Exit(TYamlNode.NewNull);

  ReadProperties(Anchor, Tag);
  SkipSpaces;

  if AtEnd or (Cur = #10) or (Cur = '#') then
  begin
    { Properties alone on the line: the node itself is below. }
    SkipBlanks;
    if AtEnd or (LineIndent <= AIndent) then
      Result := TYamlNode.NewNull
    else
      Result := ParseBlockNode(AIndent);
    if Anchor <> '' then Result.Anchor := Anchor;
    if Tag <> '' then Result.Tag := Tag;
    Exit;
  end;

  if Cur = '*' then
  begin
    Advance;
    Start := FPos;
    while (not AtEnd) and (not CharInSet(Cur,
      [' ', #9, #10, ',', '[', ']', '{', '}'])) do Advance;
    Result := TYamlNode.NewAlias(Copy(FText, Start, FPos - Start));
    Exit;
  end;

  if (Cur = '|') or (Cur = '>') then
  begin
    { The style is kept, not just the text: a literal or folded scalar is a
      STRING whatever it contains, so remembering which one it was is what
      stops "true" written as |- from being resolved as a boolean later. }
    Folded := Cur = '>';
    Text := ReadBlockScalar(AIndent, Folded);
    if Folded then
      Result := TYamlNode.NewScalar(Text, TYamlScalarStyle.Folded)
    else
      Result := TYamlNode.NewScalar(Text, TYamlScalarStyle.Literal);
  end
  else if Cur = '[' then Result := ParseFlowSequence
  else if Cur = '{' then Result := ParseFlowMapping
  else if (Cur = '-') and ((At(1) = ' ') or (At(1) = #10) or (At(1) = #0)) then
    Result := ParseBlockSequence(AIndent)
  else if (Cur = '?') and ((At(1) = ' ') or (At(1) = #10)) then
    Result := ParseBlockMapping(AIndent)
  else if LooksLikeBlockMapping then
    Result := ParseBlockMapping(AIndent)
  else if Cur = '''' then
    Result := TYamlNode.NewScalar(ReadSingleQuoted,
      TYamlScalarStyle.SingleQuoted)
  else if Cur = '"' then
    Result := TYamlNode.NewScalar(ReadDoubleQuoted,
      TYamlScalarStyle.DoubleQuoted)
  else
  begin
    { The continuation lines of a multi-line plain scalar are measured
      against the PARENT's indentation, not against the column the scalar
      happens to start at. In

          a: this is
            one long value

      the value starts at column 3 and its continuation is indented 2, which
      is still deeper than the mapping at column 0 - so it continues. Using
      the scalar's own column here would end the value at the line break and
      leave the rest of it looking like a new document. }
    Text := ReadPlainScalar(AIndent, False);
    Result := TYamlNode.NewScalar(Text, TYamlScalarStyle.Plain);
  end;

  if Anchor <> '' then Result.Anchor := Anchor;
  if Tag <> '' then Result.Tag := Tag;
end;

{ ------------------------------------------------------------- documents --- }

function TYamlParser.ParseDirectives(ADocument: TYamlDocument): Boolean;
var
  Start: Integer;
  Line: string;
  Parts: TArray<string>;
  Directives: TArray<TYamlTagDirective>;
  D: TYamlTagDirective;
begin
  Result := False;
  Directives := nil;
  while True do
  begin
    SkipBlanks;
    if AtEnd then Break;
    if (FPos <> FLineStart) or (Cur <> '%') then Break;
    Result := True;
    Start := FPos;
    SkipToLineEnd;
    Line := Trim(Copy(FText, Start, FPos - Start));
    SkipLineBreak;
    Parts := Line.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if (Length(Parts) >= 2) and SameText(Parts[0], '%YAML') then
    begin
      ADocument.Version := Parts[1];
      if Copy(Parts[1], 1, 2) <> '1.' then
        raise EYamlParseError.CreateAt(FLine, 1,
          'This document declares YAML version ' + Parts[1] + ', which ' +
          'this library does not implement. It targets 1.2');
    end
    else if (Length(Parts) >= 3) and SameText(Parts[0], '%TAG') then
    begin
      FTagHandles.AddOrSetValue(Parts[1], Parts[2]);
      D.Handle := Parts[1];
      D.Prefix := Parts[2];
      Directives := Directives + [D];
    end;
  end;
  ADocument.TagDirectives := Directives;
end;

function TYamlParser.ParseStream: TYamlStream;
var
  Doc: TYamlDocument;
  IsEnd: Boolean;
  HadDirectives: Boolean;
begin
  Result := TYamlStream.Create;
  try
    while True do
    begin
      SkipBlanks;
      if AtEnd then Break;

      Doc := TYamlDocument.Create;
      FDocument := Doc;
      try
        FTagHandles.Clear;
        HadDirectives := ParseDirectives(Doc);
        SkipBlanks;
        if AtDocumentMarker(IsEnd) and (not IsEnd) then
        begin
          AdvanceBy(3);
          Doc.ExplicitStart := True;
        end
        else if HadDirectives then
          Fail('A %YAML or %TAG directive has to be followed by --- : the ' +
            'directives belong to a document, and without the marker there ' +
            'is nothing to attach them to');

        SkipBlanks;
        FDepth := 0;
        if AtEnd then
          Doc.Root := TYamlNode.NewNull
        else if AtDocumentMarker(IsEnd) then
        begin
          Doc.Root := TYamlNode.NewNull;
          if IsEnd then
          begin
            AdvanceBy(3);
            Doc.ExplicitEnd := True;
          end;
        end
        else
          Doc.Root := ParseBlockNode(-1);

        RegisterAnchors(Doc.Root);

        SkipBlanks;
        if AtDocumentMarker(IsEnd) and IsEnd then
        begin
          AdvanceBy(3);
          Doc.ExplicitEnd := True;
        end;
      except
        Doc.Free;
        FDocument := nil;
        raise;
      end;
      Result.Add(Doc);
      FDocument := nil;
    end;

    if Result.Count = 0 then
    begin
      { An empty stream is one empty document, not zero documents: something
        has to come back from a parse, and null is what an empty YAML
        document contains. }
      Doc := TYamlDocument.Create;
      Doc.Root := TYamlNode.NewNull;
      Result.Add(Doc);
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ ===========================================================================
  THE EMITTER
  =========================================================================== }

type
  TYamlEmitter = class
  strict private
    FBuf: TStringBuilder;
    FOptions: TYamlEmitOptions;
    function Pad(ALevel: Integer): string;
    function ScalarText(ANode: TYamlNode; AInFlow: Boolean): string;
    function IsEmptyCollection(ANode: TYamlNode): Boolean;
    procedure EmitFlow(ANode: TYamlNode);
    procedure EmitBlock(ANode: TYamlNode; ALevel: Integer;
      AAfterDash: Boolean);
    function Properties(ANode: TYamlNode): string;
  public
    constructor Create(const AOptions: TYamlEmitOptions);
    destructor Destroy; override;
    function EmitDocument(ADocument: TYamlDocument; AForceStart: Boolean): string;
  end;

constructor TYamlEmitter.Create(const AOptions: TYamlEmitOptions);
begin
  inherited Create;
  FOptions := AOptions;
  if FOptions.Indent < 1 then FOptions.Indent := 2;
  FBuf := TStringBuilder.Create;
end;

destructor TYamlEmitter.Destroy;
begin
  FBuf.Free;
  inherited Destroy;
end;

function TYamlEmitter.Pad(ALevel: Integer): string;
begin
  Result := StringOfChar(' ', ALevel * FOptions.Indent);
end;

function TYamlEmitter.IsEmptyCollection(ANode: TYamlNode): Boolean;
begin
  Result := (ANode.Kind in [TYamlKind.Sequence, TYamlKind.Mapping]) and
            (ANode.Count = 0);
end;

{ YAML 1.2 section 5.1: a stream is characters, and a UTF-16 surrogate
  without its partner is half of one - no scalar style, quoted or escaped,
  can spell it, and written raw it is text no other reader accepts. It is
  refused here, the way the XML writer refuses U+0000, rather than written. }
procedure RequireCharacters(const AText: string);
var
  I: Integer;
  C: Char;
begin
  I := 1;
  while I <= Length(AText) do
  begin
    C := AText[I];
    if (C >= #$D800) and (C <= #$DBFF) and (I < Length(AText)) and
       (AText[I + 1] >= #$DC00) and (AText[I + 1] <= #$DFFF) then
      Inc(I, 2)
    else if (C >= #$D800) and (C <= #$DFFF) then
      raise EYamlError.CreateFmt(
        'The text holds an unpaired UTF-16 surrogate, U+%.4X at character ' +
        '%d, which cannot appear in a YAML document: it is half of a ' +
        'character, and YAML has no representation for it, literal or ' +
        'escaped. Remove it, or carry the value as bytes (!!binary).',
        [Ord(C), I])
    else
      Inc(I);
  end;
end;

function TYamlEmitter.Properties(ANode: TYamlNode): string;
begin
  Result := '';
  RequireCharacters(ANode.Anchor);
  RequireCharacters(ANode.Tag);
  if ANode.Anchor <> '' then Result := '&' + ANode.Anchor + ' ';
  if ANode.Tag <> '' then
  begin
    { The secondary handle is shorter and is what a reader expects for
      YAML's own types; anything else travels verbatim so that it cannot be
      changed in passing. }
    if Copy(ANode.Tag, 1, Length(TYamlSchema.DefaultPrefix)) =
       TYamlSchema.DefaultPrefix then
      Result := Result + '!!' +
        Copy(ANode.Tag, Length(TYamlSchema.DefaultPrefix) + 1, MaxInt) + ' '
    else
      Result := Result + '!<' + ANode.Tag + '> ';
  end;
end;

{ One scalar, written in a style that reads back as the same node.

  THE STYLE ON THE NODE IS THE AUTHORITY, not a guess made here.

  A plain scalar whose text is "true" IS a boolean - that is what the core
  schema says, and it is how TYamlNode.NewBool spells one. A node that means
  the four-letter WORD carries a quoted style, and every writer in this
  library sets it: the dynamic bridge quotes a string the schema would
  resolve, the contract writer quotes a string member that needs it, and a
  parsed node keeps the style the document used.

  So the only decision left here is whether a plain scalar would come back
  as the same TEXT - a leading dash, an embedded ": ", a trailing space and
  so on all end a plain scalar early - and if it would not, it is quoted.

  A control character - a line feed, a tab, and every other C0 code - is
  never plain: only a double-quoted scalar can spell it, as an escape. A
  NUL written raw was text the reader rightly refuses.

  In FLOW context the flow indicators - the comma, both brackets and both
  braces - end a plain scalar wherever they stand, so one anywhere in the
  text makes it quoted there; and so does a leading ?, which a flow mapping
  reads as the explicit-key indicator. Checking only the first character
  wrote the record Name: 'Doe, Jane' as a flow mapping its own reader
  took as Name: Doe and a second key. Block output keeps the block rule,
  where those characters are ordinary text. }
function HasControlCharacter(const AText: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(AText) do
    if AText[I] < ' ' then Exit(True);
  Result := False;
end;

function TYamlEmitter.ScalarText(ANode: TYamlNode; AInFlow: Boolean): string;
var
  Text: string;
  I: Integer;
  Buf: TStringBuilder;
  C: Char;
begin
  Text := ANode.Value;
  RequireCharacters(Text);

  case ANode.Style of
    TYamlScalarStyle.SingleQuoted:
      Exit('''' + StringReplace(Text, '''', '''''', [rfReplaceAll]) + '''');
    TYamlScalarStyle.DoubleQuoted: ;
    TYamlScalarStyle.Literal, TYamlScalarStyle.Folded: ;
  else
    { The empty string is excluded deliberately: an empty plain scalar is
      NULL by the core schema, so writing nothing would change the value. }
    if (Text <> '') and not HasControlCharacter(Text) and
       (Pos(': ', Text) = 0) and (Pos(' #', Text) = 0) and
       (Text[Length(Text)] <> ':') and
       { - ? and : begin a plain scalar when a non-space follows them - which
         is how -128 and -.inf are written. Quoting every one of them made a
         negative number a string to any other YAML reader. }
       (not CharInSet(Text[1],
         [',', '[', ']', '{', '}', '#', '&', '*', '!', '|',
          '>', '''', '"', '%', '@', '`', ' '])) and
       (not CharInSet(Text[1], ['-', '?', ':']) or
        ((Length(Text) > 1) and not CharInSet(Text[2], [' ', #9]))) and
       (Text[Length(Text)] <> ' ') and
       ((not AInFlow) or
        ((Text[1] <> '?') and (LastDelimiter(',[]{}', Text) = 0))) then
      Exit(Text);
  end;

  { Double-quoted, which is the style that can spell anything. }
  Buf := TStringBuilder.Create;
  try
    Buf.Append('"');
    for I := 1 to Length(Text) do
    begin
      C := Text[I];
      case C of
        '"': Buf.Append('\"');
        '\': Buf.Append('\\');
        #8:  Buf.Append('\b');
        #9:  Buf.Append('\t');
        #10: Buf.Append('\n');
        #12: Buf.Append('\f');
        #13: Buf.Append('\r');
      else
        if C < ' ' then
          Buf.Append('\u').Append(LowerCase(IntToHex(Ord(C), 4)))
        else
          Buf.Append(C);
      end;
    end;
    Buf.Append('"');
    Result := Buf.ToString;
  finally
    Buf.Free;
  end;
end;

procedure TYamlEmitter.EmitFlow(ANode: TYamlNode);
var
  I: Integer;
begin
  case ANode.Kind of
    TYamlKind.Alias:
      begin
        RequireCharacters(ANode.Value);
        FBuf.Append('*').Append(ANode.Value);
        Exit;
      end;
    TYamlKind.Scalar:
      begin
        FBuf.Append(Properties(ANode)).Append(ScalarText(ANode, True));
        Exit;
      end;
    TYamlKind.Sequence:
      begin
        FBuf.Append(Properties(ANode)).Append('[');
        for I := 0 to ANode.Count - 1 do
        begin
          if I > 0 then FBuf.Append(', ');
          EmitFlow(ANode.Items[I]);
        end;
        FBuf.Append(']');
        Exit;
      end;
    TYamlKind.Mapping:
      begin
        FBuf.Append(Properties(ANode)).Append('{');
        for I := 0 to ANode.Count - 1 do
        begin
          if I > 0 then FBuf.Append(', ');
          EmitFlow(ANode.Keys[I]);
          FBuf.Append(': ');
          EmitFlow(ANode.Items[I]);
        end;
        FBuf.Append('}');
        Exit;
      end;
  end;
end;

procedure TYamlEmitter.EmitBlock(ANode: TYamlNode; ALevel: Integer;
  AAfterDash: Boolean);
var
  I: Integer;
  Key: TYamlNode;
  Simple: Boolean;
begin
  case ANode.Kind of
    TYamlKind.Alias:
      begin
        RequireCharacters(ANode.Value);
        FBuf.Append('*').Append(ANode.Value).Append(sLineBreak);
        Exit;
      end;

    TYamlKind.Scalar:
      begin
        FBuf.Append(Properties(ANode)).Append(ScalarText(ANode, False))
            .Append(sLineBreak);
        Exit;
      end;

    { A collection that does not follow an indicator on the same line starts
      a line of its own, and that line - its properties, or the [] or the
      braces of an empty one - is at the collection's OWN indentation.
      Written at column 0 it was the parent's indentation, and read back as
      a sibling: a null entry followed by a stray anchored key, or a new
      document. }
    TYamlKind.Sequence:
      begin
        if ANode.Count = 0 then
        begin
          if not AAfterDash then FBuf.Append(Pad(ALevel));
          FBuf.Append(Properties(ANode)).Append('[]').Append(sLineBreak);
          Exit;
        end;
        if Properties(ANode) <> '' then
        begin
          if not AAfterDash then FBuf.Append(Pad(ALevel));
          FBuf.Append(TrimRight(Properties(ANode))).Append(sLineBreak);
        end;
        for I := 0 to ANode.Count - 1 do
        begin
          FBuf.Append(Pad(ALevel)).Append('- ');
          if ANode.Items[I].Kind in [TYamlKind.Scalar, TYamlKind.Alias] then
            EmitBlock(ANode.Items[I], ALevel + 1, True)
          else if IsEmptyCollection(ANode.Items[I]) then
            EmitBlock(ANode.Items[I], ALevel + 1, True)
          else
          begin
            FBuf.Append(sLineBreak);
            EmitBlock(ANode.Items[I], ALevel + 1, False);
          end;
        end;
        Exit;
      end;

    TYamlKind.Mapping:
      begin
        if ANode.Count = 0 then
        begin
          if not AAfterDash then FBuf.Append(Pad(ALevel));
          FBuf.Append(Properties(ANode)).Append('{}').Append(sLineBreak);
          Exit;
        end;
        if Properties(ANode) <> '' then
        begin
          if not AAfterDash then FBuf.Append(Pad(ALevel));
          FBuf.Append(TrimRight(Properties(ANode))).Append(sLineBreak);
        end;
        for I := 0 to ANode.Count - 1 do
        begin
          Key := ANode.Keys[I];
          Simple := (Key.Kind = TYamlKind.Scalar) and (Pos(#10, Key.Value) = 0);
          if (I > 0) or (not AAfterDash) then FBuf.Append(Pad(ALevel));
          if Simple then
          begin
            FBuf.Append(ScalarText(Key, False)).Append(':');
            if ANode.Items[I].Kind in [TYamlKind.Scalar, TYamlKind.Alias] then
            begin
              FBuf.Append(' ');
              EmitBlock(ANode.Items[I], ALevel + 1, True);
            end
            else if IsEmptyCollection(ANode.Items[I]) then
            begin
              FBuf.Append(' ');
              EmitBlock(ANode.Items[I], ALevel + 1, True);
            end
            else
            begin
              FBuf.Append(sLineBreak);
              EmitBlock(ANode.Items[I], ALevel + 1, False);
            end;
          end
          else
          begin
            { A key that is not a simple scalar takes the explicit form,
              which is the only way YAML can write it down. }
            FBuf.Append('? ');
            if (Key.Kind in [TYamlKind.Scalar, TYamlKind.Alias]) or
               IsEmptyCollection(Key) then
              EmitBlock(Key, ALevel + 1, True)
            else
            begin
              FBuf.Append(sLineBreak);
              EmitBlock(Key, ALevel + 1, False);
            end;
            FBuf.Append(Pad(ALevel)).Append(':');
            { An empty value goes inline, as it does after a simple key: on a
              line of its own it was a stray [] at the parent's column. }
            if (ANode.Items[I].Kind in [TYamlKind.Scalar, TYamlKind.Alias]) or
               IsEmptyCollection(ANode.Items[I]) then
            begin
              FBuf.Append(' ');
              EmitBlock(ANode.Items[I], ALevel + 1, True);
            end
            else
            begin
              FBuf.Append(sLineBreak);
              EmitBlock(ANode.Items[I], ALevel + 1, False);
            end;
          end;
        end;
        Exit;
      end;
  end;
end;

function TYamlEmitter.EmitDocument(ADocument: TYamlDocument;
  AForceStart: Boolean): string;
var
  D: TYamlTagDirective;
  NeedsStart: Boolean;
begin
  FBuf.Clear;
  NeedsStart := AForceStart or FOptions.ExplicitDocumentStart or
                ADocument.ExplicitStart or (ADocument.Version <> '') or
                (Length(ADocument.TagDirectives) > 0);
  RequireCharacters(ADocument.Version);
  if ADocument.Version <> '' then
    FBuf.Append('%YAML ').Append(ADocument.Version).Append(sLineBreak);
  for D in ADocument.TagDirectives do
  begin
    RequireCharacters(D.Handle);
    RequireCharacters(D.Prefix);
    FBuf.Append('%TAG ').Append(D.Handle).Append(' ').Append(D.Prefix)
        .Append(sLineBreak);
  end;
  if NeedsStart then FBuf.Append('---').Append(sLineBreak);

  if ADocument.Root = nil then
    FBuf.Append('null').Append(sLineBreak)
  else if FOptions.Style = TYamlStyle.Flow then
  begin
    EmitFlow(ADocument.Root);
    FBuf.Append(sLineBreak);
  end
  else
    EmitBlock(ADocument.Root, 0, False);

  if FOptions.ExplicitDocumentEnd or ADocument.ExplicitEnd then
    FBuf.Append('...').Append(sLineBreak);
  Result := FBuf.ToString;
end;

{ ===========================================================================
  ALIAS EXPANSION

  An alias says two members are the same node. A Delphi record cannot be two
  members at once, so the contract path expands - and expansion is exactly
  what the billion laughs attack exploits, so it is budgeted and the budget
  is checked before anything is allocated rather than after.
  =========================================================================== }

type
  TYamlExpander = class
  strict private
    FSource: TYamlDocument;
    FLimits: TYamlLimits;
    FCount: Integer;
    FActive: TStringList;
    function ExpandNode(ANode: TYamlNode; ADepth: Integer): TYamlNode;
  public
    constructor Create(ASource: TYamlDocument; const ALimits: TYamlLimits);
    destructor Destroy; override;
    function Run: TYamlDocument;
  end;

constructor TYamlExpander.Create(ASource: TYamlDocument;
  const ALimits: TYamlLimits);
begin
  inherited Create;
  FSource := ASource;
  FLimits := ALimits;
  FActive := TStringList.Create;
end;

destructor TYamlExpander.Destroy;
begin
  FActive.Free;
  inherited Destroy;
end;

function TYamlExpander.ExpandNode(ANode: TYamlNode; ADepth: Integer): TYamlNode;
var
  I: Integer;
  Target: TYamlNode;
  Key, Value: TYamlNode;
begin
  if ANode = nil then Exit(nil);

  Inc(FCount);
  if FCount > FLimits.MaxExpandedNodes then
    raise EYamlLimitExceeded.CreateFmt(
      'Expanding the aliases in this document produces more than %d nodes, ' +
      'which is past the limit. A small document with a very large ' +
      'expansion is the billion laughs attack; ' +
      'TYamlSerializer.SetLimits moves the line if you really meant it.',
      [FLimits.MaxExpandedNodes]);
  if ADepth > FLimits.MaxDepth then
    raise EYamlLimitExceeded.CreateFmt(
      'Expanding the aliases in this document nests more than %d levels ' +
      'deep, which is past the limit.', [FLimits.MaxDepth]);

  case ANode.Kind of
    TYamlKind.Alias:
      begin
        if FActive.IndexOf(ANode.Value) >= 0 then
          raise EYamlAliasCycleError.CreateFmt(
            'The alias *%s refers, directly or through others, back to ' +
            'itself. That is legal YAML and has no Delphi shape: a record ' +
            'cannot contain itself. Read the document with ParseStream ' +
            'instead, where the alias stays an alias.', [ANode.Value]);
        Target := FSource.ResolveAnchor(ANode.Value);
        if Target = nil then
          raise EYamlUnresolvedAliasError.CreateFmt(
            'The alias *%s names an anchor this document never defines.',
            [ANode.Value]);
        FActive.Add(ANode.Value);
        try
          Result := ExpandNode(Target, ADepth + 1);
        finally
          FActive.Delete(FActive.Count - 1);
        end;
        { The expansion is a value of its own now, so it must not claim the
          anchor as well - two nodes with one anchor is not a document. }
        Result.Anchor := '';
        Exit;
      end;

    TYamlKind.Scalar:
      begin
        Result := ANode.Clone;
        Result.Anchor := '';
        Exit;
      end;

    TYamlKind.Sequence:
      begin
        Result := TYamlNode.NewSequence;
        try
          Result.Tag := ANode.Tag;
          for I := 0 to ANode.Count - 1 do
            Result.Add(ExpandNode(ANode.Items[I], ADepth + 1));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;

    TYamlKind.Mapping:
      begin
        Result := TYamlNode.NewMapping;
        try
          Result.Tag := ANode.Tag;
          for I := 0 to ANode.Count - 1 do
          begin
            Key := ExpandNode(ANode.Keys[I], ADepth + 1);
            try
              Value := ExpandNode(ANode.Items[I], ADepth + 1);
            except
              Key.Free;
              raise;
            end;
            Result.Add(Key, Value);
          end;
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
  end;
  Result := TYamlNode.NewNull;
end;

function TYamlExpander.Run: TYamlDocument;
begin
  Result := TYamlDocument.Create;
  try
    Result.Version := FSource.Version;
    Result.TagDirectives := FSource.TagDirectives;
    Result.ExplicitStart := FSource.ExplicitStart;
    Result.ExplicitEnd := FSource.ExplicitEnd;
    FCount := 0;
    Result.Root := ExpandNode(FSource.Root, 0);
  except
    Result.Free;
    raise;
  end;
end;

{ ===========================================================================
  THE DYNAMIC BRIDGE

  Structural conversion only. The contract path never comes through here: it
  reads and writes YAML nodes directly, so a YAML attribute means what it
  says and nothing is translated twice.
  =========================================================================== }

class function TYamlEngine.YamlToDynamic(ANode: TYamlNode;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
var
  I: Integer;
  Name: string;
  U: UInt64;
  DT: TDateTime;
begin
  if ANode = nil then Exit(TDynamicValue.NewNull);

  case ANode.Kind of
    TYamlKind.Alias:
      { An alias says two members are THE SAME NODE. Nothing in the dynamic
        tree can say that, so it travels as what it is rather than as a copy
        the destination could not tell from an original. }
      Exit(TDynamicValue.NewExtended(TDynamicTag.YamlAlias,
        TDynamicValue.NewStr(ANode.Value)));

    TYamlKind.Sequence:
      begin
        Result := TDynamicValue.NewArray;
        try
          for I := 0 to ANode.Count - 1 do
            Result.AsArray.Adopt(YamlToDynamic(ANode.Items[I], AOptions));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;

    TYamlKind.Mapping:
      begin
        Result := TDynamicValue.NewObject;
        try
          for I := 0 to ANode.Count - 1 do
          begin
            { A YAML key may be a sequence or a mapping. The dynamic tree's
              names are strings, so a complex key is rendered as its
              diagnostic text - the one place this bridge cannot be exact,
              and it is said here rather than discovered. }
            if ANode.Keys[I].Kind = TYamlKind.Scalar then
              Name := ANode.Keys[I].Value
            else
              Name := ANode.Keys[I].Describe;
            Result.AsObject.Adopt(Name, YamlToDynamic(ANode.Items[I], AOptions));
          end;
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
  end;

  { A scalar. The document's tag wins when it gave one; otherwise the 1.2
    core schema decides, and only for a PLAIN scalar. }
  if ANode.Tag = TYamlSchema.TagBinary then
    Exit(TDynamicValue.NewBytes(ANode.AsBytes));
  if (ANode.Tag = TYamlSchema.TagTimestamp) and
     TStructuralText.TryDecodeDateTime(ANode.Value, DT) then
    Exit(TDynamicValue.NewDateTime(DT));

  case ANode.ScalarType of
    TYamlScalarType.Null: Exit(TDynamicValue.NewNull);
    TYamlScalarType.Bool: Exit(TDynamicValue.NewBool(ANode.AsBoolean));
    TYamlScalarType.Int:
      begin
        if TYamlSchema.TryToUInt64(ANode.Value, U) and
           (U > UInt64(High(Int64))) then
          Exit(TDynamicValue.NewUInt(U));
        Exit(TDynamicValue.NewInt(ANode.AsInt64));
      end;
    TYamlScalarType.Float: Exit(TDynamicValue.NewFloat(ANode.AsDouble));
  end;
  Result := TDynamicValue.NewStr(ANode.Value);
end;

class function TYamlEngine.StreamToDynamic(AStream: TYamlStream;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
var
  I: Integer;
begin
  { One document is that document; a stream of several is an ARRAY of them.
    Silently taking the first would make a three-document file convert to
    one third of itself. }
  if AStream.Count = 1 then
    Exit(YamlToDynamic(AStream[0].Root, AOptions));
  Result := TDynamicValue.NewArray;
  try
    for I := 0 to AStream.Count - 1 do
      Result.AsArray.Adopt(YamlToDynamic(AStream[I].Root, AOptions));
  except
    Result.Free;
    raise;
  end;
end;

class function TYamlEngine.DynamicToYaml(AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TYamlNode;
var
  I: Integer;
  Inner: TDynamicValue;
begin
  if AValue = nil then Exit(TYamlNode.NewNull);

  case AValue.Kind of
    TDynamicKind.Null: Exit(TYamlNode.NewNull);
    TDynamicKind.Bool: Exit(TYamlNode.NewBool(AValue.AsBool));
    TDynamicKind.Int:  Exit(TYamlNode.NewInt(AValue.AsInt));
    TDynamicKind.UInt:
      { Above High(Int64) there is no Delphi integer to print through, so
        the digits are written as digits. The 1.2 core schema reads them
        back as an int, which is what they are. }
      Exit(TYamlNode.NewScalar(UIntToStr(AValue.AsUInt),
        TYamlScalarStyle.Plain));
    TDynamicKind.Float: Exit(TYamlNode.NewFloat(AValue.AsFloat));
    TDynamicKind.Decimal:
      { An exact decimal is written as its digits. YAML's core schema reads
        them back as a float, which loses the exactness - but quoting them
        would lose the number, and of the two the digits are what the
        document was about. }
      Exit(TYamlNode.NewScalar(AValue.AsDecimal, TYamlScalarStyle.Plain));
    TDynamicKind.Str:
      begin
        Result := TYamlNode.NewScalar(AValue.AsStr, TYamlScalarStyle.Plain);
        { A string the core schema would read back as something else has to
          be quoted, or "true" stops being a word. }
        if TYamlSchema.NeedsQuotingAsString(AValue.AsStr) then
          Result.Style := TYamlScalarStyle.DoubleQuoted;
        Exit;
      end;
    TDynamicKind.Bytes:
      begin
        { YAML's own type repository has a binary type and it is base64, so
          that is what bytes are - not a convention invented here. }
        Result := TYamlNode.NewScalar(
          TNetEncoding.Base64.EncodeBytesToString(AValue.AsBytes),
          TYamlScalarStyle.DoubleQuoted);
        Result.Tag := TYamlSchema.TagBinary;
        Exit;
      end;
    TDynamicKind.DateTime:
      begin
        Result := TYamlNode.NewScalar(
          TStructuralText.EncodeDateTime(AValue.AsDateTime),
          TYamlScalarStyle.Plain);
        Result.Tag := TYamlSchema.TagTimestamp;
        Exit;
      end;
    { The 1.2 core schema resolves neither spelling as anything but a string,
      so these are plain scalars with no tag: claiming !!timestamp for a day
      would say it is an instant, which is the distinction being kept. }
    TDynamicKind.Date:
      begin
        Result := TYamlNode.NewScalar(
          TStructuralText.EncodeDate(AValue.AsDateTime),
          TYamlScalarStyle.Plain);
        Exit;
      end;
    TDynamicKind.Time:
      begin
        Result := TYamlNode.NewScalar(
          TStructuralText.EncodeTime(AValue.AsDateTime),
          TYamlScalarStyle.Plain);
        Exit;
      end;
    TDynamicKind.Arr:
      begin
        Result := TYamlNode.NewSequence;
        try
          for I := 0 to AValue.Count - 1 do
            Result.Add(DynamicToYaml(AValue.Items[I], AOptions));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
    TDynamicKind.Obj:
      begin
        Result := TYamlNode.NewMapping;
        try
          for I := 0 to AValue.Count - 1 do
            Result.AddPair(AValue.Names[I],
              DynamicToYaml(AValue.Items[I], AOptions));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
    TDynamicKind.Extended:
      begin
        if AValue.IsTagged(TDynamicTag.YamlAlias) then
        begin
          Inner := AValue.ExtendedValue;
          if Inner <> nil then Exit(TYamlNode.NewAlias(Inner.AsStr));
          Exit(TYamlNode.NewNull);
        end;
        { Anything else that arrived tagged is another format's idea, and
          YAML has no place to put it that a YAML reader would understand.
          Refusing names the member; writing it as a string would not. }
        raise EStructuralConversionError.CreateFmt(
          'YAML has no way to write a %s value: it is an extension of ' +
          'another format and YAML''s own schema has no counterpart. Use ' +
          'the Natural profile if losing it is acceptable, or a format ' +
          'that can carry it.', [AValue.ExtendedTag]);
      end;
  end;
  Result := TYamlNode.NewNull;
end;

{ ===========================================================================
  THE CONTRACT

  A Delphi value is written straight to YAML nodes and read straight back.
  Nothing routes through the dynamic tree, so a [YamlName] means what it says
  and a [JsonName] is never consulted.
  =========================================================================== }

function MemberName(AMember: TRttiMember): string;
var
  Attr: TCustomAttribute;
begin
  if AMember = nil then Exit('');
  for Attr in AMember.GetAttributes do
    if Attr is YamlNameAttribute then Exit(YamlNameAttribute(Attr).Name);
  { [YamlName] beats [SerializationName], which beats the Delphi name. }
  if not TSerializationMetadata.GeneralName(AMember, Result) then
    Result := AMember.Name;
end;

function MemberIgnored(AMember: TRttiMember): Boolean;
var
  Attr: TCustomAttribute;
begin
  Result := False;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is YamlIgnoreAttribute then Exit(True);
end;

function MemberSerializer(AMember: TRttiMember): TYamlValueSerializerClass;
var
  Attr: TCustomAttribute;
begin
  Result := nil;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is YamlSerializerAttribute then
      Exit(YamlSerializerAttribute(Attr).SerializerClass);
end;

function MemberDateRepresentation(AMember: TRttiMember; AOwner: PTypeInfo;
  out APattern: string): TYamlDateTimeRepresentation;
var
  Attr: TCustomAttribute;
  Policy: TDateTimePolicy;
begin
  APattern := '';
  if AMember <> nil then
    for Attr in AMember.GetAttributes do
      if Attr is YamlDateTimeRepresentationAttribute then
      begin
        APattern := YamlDateTimeRepresentationAttribute(Attr).Pattern;
        if APattern <> '' then Exit(TYamlDateTimeRepresentation.CustomString);
        Exit(YamlDateTimeRepresentationAttribute(Attr).Representation);
      end;
  { No attribute: the registered policy decides - field, then type, then the
    global default, then the built-in one. }
  if AMember <> nil then
    Policy := TYamlEngine.DatePolicyFor(AOwner, AMember.Name)
  else
    Policy := TYamlEngine.DatePolicyFor(AOwner, '');
  APattern := Policy.Pattern;
  Result := TYamlDateTimeRepresentation(Policy.Kind);
end;

{ The shared surface - public fields and readable properties, a
  redeclared name once - minus those ignored in general or by
  [YamlIgnore]. }
function MembersOf(AType: TRttiType): TArray<TRttiMember>;
var
  List: TList<TRttiMember>;
  M: TSerializationMember;
begin
  List := TList<TRttiMember>.Create;
  try
    for M in TSerializationMetadata.Get(AType.Handle).Members do
      if not M.Ignored and not MemberIgnored(M.Member) then List.Add(M.Member);
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

{ The text of an enumeration's values: YAML's own registration, then
  [SerializationEnum] on the member, then on the type. }
function EnumNamesFor(AMember: TRttiMember; AType: PTypeInfo;
  out ANames: TArray<string>): Boolean;
begin
  Result := TYamlEngine.TryGetEnumMapping(AType, ANames) or
    TSerializationMetadata.GeneralEnum(AMember, AType, ANames);
end;

function MemberType(AMember: TRttiMember): TRttiType;
begin
  if AMember is TRttiField then Result := TRttiField(AMember).FieldType
  else if AMember is TRttiProperty then
    Result := TRttiProperty(AMember).PropertyType
  else Result := nil;
end;

{ RTTI GetValue takes the instance as an untyped pointer, so an object
  instance is passed as its address. }
{$WARN UNSAFE_CAST OFF}
function MemberValue(AMember: TRttiMember; const AInstance: TValue): TValue;
begin
  if AMember is TRttiField then
  begin
    if AInstance.IsObject then
      Result := TRttiField(AMember).GetValue(AInstance.AsObject)
    else
      Result := TRttiField(AMember).GetValue(AInstance.GetReferenceToRawData);
  end
  else if AMember is TRttiProperty then
  begin
    if AInstance.IsObject then
      Result := TRttiProperty(AMember).GetValue(AInstance.AsObject)
    else
      Result := TRttiProperty(AMember).GetValue(
        AInstance.GetReferenceToRawData);
  end
  else
    Result := TValue.Empty;
end;
{$WARN UNSAFE_CAST ON}

{ The object a member already holds, for the reader to fill in place, as
  every other format does. Passing nothing made the reader construct a
  second one and store it over the first, which nothing then referred to -
  the child list a constructor makes is the everyday case, and it leaked on
  every read. A record member's current value too: a record is merged in
  place, so the objects a constructor or the caller put in it are filled,
  not replaced and orphaned, and the members a document leaves out keep
  their values. An array is replaced, not merged, so it gets nothing. }
function ExistingValueOf(AMember: TRttiMember; const AInstance: TValue): TValue;
var
  T: TRttiType;
begin
  Result := TValue.Empty;
  T := MemberType(AMember);
  if T = nil then Exit;
  if T.TypeKind in [tkRecord, tkMRecord] then
    Exit(MemberValue(AMember, AInstance));
  if T.TypeKind <> tkClass then Exit;
  Result := MemberValue(AMember, AInstance);
  if Result.IsObject and (Result.AsObject = nil) then Result := TValue.Empty;
end;

{ RTTI SetValue takes the instance as an untyped pointer, so an object
  instance is passed as its address. }
{$WARN UNSAFE_CAST OFF}
procedure SetMemberValue(AMember: TRttiMember; const AInstance: TValue;
  const AValue: TValue);
begin
  if AValue.IsEmpty then Exit;
  if AMember is TRttiField then
  begin
    if AInstance.IsObject then
      TRttiField(AMember).SetValue(AInstance.AsObject, AValue)
    else
      TRttiField(AMember).SetValue(AInstance.GetReferenceToRawData, AValue);
  end
  else if (AMember is TRttiProperty) and TRttiProperty(AMember).IsWritable then
  begin
    if AInstance.IsObject then
      TRttiProperty(AMember).SetValue(AInstance.AsObject, AValue)
    else
      TRttiProperty(AMember).SetValue(AInstance.GetReferenceToRawData, AValue);
  end;
end;
{$WARN UNSAFE_CAST ON}

{ An empty nullable is ABSENT, not null - the rule every format in this
  library follows, so that a conversion between any two of them never has to
  guess which of "no value" and "the value null" a member meant. }
function IsEmptyNullable(AType: TRttiType; const AValue: TValue): Boolean;
var
  Access: TNullableAccess;
begin
  Result := False;
  if AType = nil then Exit;
  if not TSerializationTypes.TryGetNullableAccess(AType.Handle, Access) then
    Exit;
  Result := not Access.HasValue(AValue.GetReferenceToRawData);
end;

{ Delphi files UInt64 under tkInt64 alongside Int64, and the two differ here:
  the digits of 2 to the sixty-fourth minus one are not the digits of -1. }
function IsUnsignedInt64(AType: TRttiType): Boolean;
var
  Int64Type: TRttiInt64Type;
begin
  if AType = nil then Exit(False);
  if AType.Handle = System.TypeInfo(UInt64) then Exit(True);
  if AType.TypeKind <> tkInt64 then Exit(False);
  if not (AType is TRttiInt64Type) then Exit(False);
  Int64Type := TRttiInt64Type(AType);
  Result := (Int64Type.MinValue = 0) and (Int64Type.MaxValue = -1);
end;

{ What an error calls a member: its name when there is one, and otherwise
  the type, which is all an array element or a root has. }
function MemberLabel(AMember: TRttiMember; AType: TRttiType): string;
begin
  if AMember <> nil then Exit(AMember.Name);
  if AType <> nil then Exit(AType.Name);
  Result := 'a value';
end;

{ Whether a member can be written at all, asked from its TYPE before its
  getter is called: TComponent's ComObject getter used to run, and raise
  EComponentError, before anything had looked at what the member was. }
procedure RefuseUnwritableMember(AMember: TRttiMember; AType: TRttiType);
var
  Why: string;
  SerializerClass: TYamlValueSerializerClass;
begin
  if MemberSerializer(AMember) <> nil then Exit;
  if AType = nil then
    raise EYamlError.CreateFmt(
      '%s %s. Leave it out with [YamlIgnore], or register a YAML type ' +
      'serializer for the type that holds it.',
      [MemberDisplayName(AMember.Parent.Name, AMember.Name),
       TSerializationTypes.UnsupportedReason(nil)]);
  if TYamlEngine.TryGetTypeSerializer(AType.Handle, SerializerClass) then Exit;
  Why := TSerializationTypes.UnsupportedReason(AType.Handle);
  if Why <> '' then
    raise EYamlError.CreateFmt(
      '%s %s. Leave it out with [YamlIgnore], or register a YAML type ' +
      'serializer for its type.',
      [MemberDisplayName(AMember.Parent.Name, AMember.Name), Why]);
end;

function ValueToYaml(AType: TRttiType; const AValue: TValue;
  AMember: TRttiMember; AOwner: PTypeInfo): TYamlNode; forward;

{ Whole milliseconds since the epoch, for both epoch writers. A TDateTime
  before 1899-12-30 is a negative day with a POSITIVE time of day, so the
  linear (AValue - UnixDateDelta) * MSecsPerDay put every such instant a day
  early; Core follows the encoding. An instant outside the years 1 to 9999
  is refused before anything is written, because the reader refuses it
  back. }
function DateToUnixMillis(AValue: TDateTime): Int64;
begin
  TStructuralText.CheckDateTime(AValue);
  if not TStructuralText.TryDateTimeToUnixMillis(AValue, Result) then
    raise ESerializationUnsupported.CreateFmt(
      'The TDateTime %s rounds to an instant after 9999-12-31T23:59:59.999, ' +
      'which no reader here accepts back.',
      [FloatToStr(AValue, TFormatSettings.Invariant)]);
end;

function DateToYaml(AValue: TDateTime;
  ARepresentation: TYamlDateTimeRepresentation;
  const APattern: string): TYamlNode;
var
  Millis: Int64;
begin
  case ARepresentation of
    TYamlDateTimeRepresentation.Timestamp:
      begin
        Result := TYamlNode.NewScalar(TStructuralText.EncodeDateTime(AValue),
          TYamlScalarStyle.Plain);
        Result.Tag := TYamlSchema.TagTimestamp;
      end;
    TYamlDateTimeRepresentation.UnixSeconds:
      begin
        { The second an instant falls in is the millisecond count FLOORED:
          half a second before the epoch is second -1, not second 0. }
        Millis := DateToUnixMillis(AValue);
        if Millis < 0 then
          Result := TYamlNode.NewInt((Millis - (MSecsPerSec - 1)) div MSecsPerSec)
        else
          Result := TYamlNode.NewInt(Millis div MSecsPerSec);
      end;
    TYamlDateTimeRepresentation.UnixMilliseconds:
      Result := TYamlNode.NewInt(DateToUnixMillis(AValue));
    TYamlDateTimeRepresentation.CustomString:
      begin
        { FormatDateTime spells a day before year 1 as 0000-00-00, which is
          not even the value, and the reader refuses it back. }
        TStructuralText.CheckDateTime(AValue);
        Result := TYamlNode.NewScalar(
          FormatDateTime(APattern, AValue, TFormatSettings.Invariant),
          TYamlScalarStyle.DoubleQuoted);
      end;
  else
    { ISO 8601. The core schema leaves it a string, which is exactly right: a
      YAML 1.2 document says nothing about dates unless it tags them. }
    Result := TYamlNode.NewScalar(TStructuralText.EncodeDateTime(AValue),
      TYamlScalarStyle.Plain);
  end;
end;

function CollectionToYaml(AType: TRttiType; const AValue: TValue;
  AMember: TRttiMember; AOwner: PTypeInfo; out AHandled: Boolean): TYamlNode;
var
  Access: TNullableAccess;
  Inner: TValue;
  Method: TRttiMethod;
  Enumerator, Current, PairKey, PairValue: TValue;
  EnumType, PairType: TRttiType;
  MoveNext: TRttiMethod;
  CurrentProp: TRttiProperty;
  IsMap: Boolean;
  KeyField, ValueField: TRttiField;
  KeyNode, ValueNode: TYamlNode;
begin
  AHandled := True;

  if TSerializationTypes.TryGetNullableAccess(AType.Handle, Access) then
  begin
    if not Access.HasValue(AValue.GetReferenceToRawData) then
      Exit(TYamlNode.NewNull);
    Inner := Access.GetValue(AValue.GetReferenceToRawData);
    Exit(ValueToYaml(GCtx.GetType(Access.ValueType), Inner, AMember, AOwner));
  end;

  { What kind of container this is comes from Core; how it is traversed is
    this engine's business. See the note in the CBOR engine for what the old
    method-shape probe recognised that it should not have. }
  if (AType.TypeKind = tkClass) and AValue.IsObject and
     (AValue.AsObject <> nil) and
     (TSerializationTypes.ContainerKindOf(AType.Handle) <> TContainerKind.None) then
  begin
    Method := AType.GetMethod('GetEnumerator');
    if Method <> nil then
    begin
      IsMap := TSerializationTypes.ContainerKindOf(AType.Handle) =
        TContainerKind.Dictionary;

      { A container is an object in the graph like any other: an element
        declared TObject is written by its runtime class, so a list that
        holds itself came straight back here and recursed until the stack
        ran out. Enter is the cycle check and counts its level. }
      if not TSerializationGraphGuard.Enter(AValue.AsObject) then
        raise EYamlError.CreateFmt(
          '%s is already being written further up the graph: it is a ' +
          'cycle. YAML anchors could name it, but a contract written back ' +
          'as a graph would claim an identity nothing else here keeps. ' +
          'Break the cycle, or register a YAML type serializer.',
          [AValue.AsObject.ClassName]);
      try
        if IsMap then Result := TYamlNode.NewMapping
        else Result := TYamlNode.NewSequence;
        try
          Enumerator := Method.Invoke(AValue.AsObject, []);
          try
            EnumType := GCtx.GetType(Enumerator.TypeInfo);
            MoveNext := EnumType.GetMethod('MoveNext');
            CurrentProp := EnumType.GetProperty('Current');
            KeyField := nil;
            ValueField := nil;
            if IsMap and (CurrentProp <> nil) then
            begin
              PairType := CurrentProp.PropertyType;
              if PairType <> nil then
              begin
                KeyField := PairType.GetField('Key');
                ValueField := PairType.GetField('Value');
              end;
              if (KeyField = nil) or (ValueField = nil) then
                raise EYamlInternalError.CreateFmt(
                  '%s looks like a dictionary but its enumerator does not ' +
                  'yield Key/Value pairs, so YAML cannot tell its entries ' +
                  'apart.', [AType.Name]);
            end;
            if (MoveNext <> nil) and (CurrentProp <> nil) then
              while MoveNext.Invoke(Enumerator, []).AsBoolean do
              begin
                { RTTI GetValue takes the enumerator instance as an untyped
                  pointer. }
                {$WARN UNSAFE_CAST OFF}
                Current := CurrentProp.GetValue(Enumerator.AsObject);
                {$WARN UNSAFE_CAST ON}
                if IsMap then
                begin
                  PairKey := KeyField.GetValue(Current.GetReferenceToRawData);
                  PairValue := ValueField.GetValue(
                    Current.GetReferenceToRawData);
                  { One at a time, as the reader does: built inline as two
                    arguments, the half converted first leaked when the other
                    raised - the key on Win64, the value on Win32. }
                  KeyNode := ValueToYaml(GCtx.GetType(PairKey.TypeInfo), PairKey,
                    nil, AOwner);
                  try
                    ValueNode := ValueToYaml(GCtx.GetType(PairValue.TypeInfo),
                      PairValue, nil, AOwner);
                  except
                    KeyNode.Free;
                    raise;
                  end;
                  Result.Add(KeyNode, ValueNode);
                end
                else
                  Result.Add(ValueToYaml(GCtx.GetType(Current.TypeInfo),
                    Current, nil, AOwner));
              end;
          finally
            if Enumerator.IsObject then Enumerator.AsObject.Free;
          end;
        except
          Result.Free;
          raise;
        end;
      finally
        TSerializationGraphGuard.Leave(AValue.AsObject);
      end;
      Exit;
    end;
  end;

  AHandled := False;
  Result := nil;
end;

function ValueToYaml(AType: TRttiType; const AValue: TValue;
  AMember: TRttiMember; AOwner: PTypeInfo): TYamlNode;
var
  Why: string;
  Handled: Boolean;
  I: Integer;
  Members: TArray<TRttiMember>;
  M: TRttiMember;
  Names: TArray<string>;
  Ordinal: Int64;
  Pattern, EnumText: string;
  SerializerClass: TYamlValueSerializerClass;
  Serializer: TCustomYamlValueSerializer;
  ElemInfo: PTypeInfo;
  MemberVal: TValue;
  Tree: TDynamicValue;
begin
  if AType = nil then
    raise EYamlError.CreateFmt(
      '%s %s. Leave it out with [YamlIgnore], or register a YAML type ' +
      'serializer for the type that holds it.',
      [MemberLabel(AMember, nil), TSerializationTypes.UnsupportedReason(nil)]);

  SerializerClass := MemberSerializer(AMember);
  if SerializerClass = nil then
    TYamlEngine.TryGetTypeSerializer(AType.Handle, SerializerClass);
  if SerializerClass <> nil then
  begin
    Serializer := SerializerClass.Create;
    try
      Exit(Serializer.Serialize(AValue));
    finally
      Serializer.Free;
    end;
  end;

  { Refused, not written: a type with no RTTI must not become null, and a
    pointer, a method, a class reference or an interface must not reach the
    scalar writer, which would write an address as a number. The decision is
    TSerializationTypes.UnsupportedReason, shared by every format, and it
    is asked only after [YamlIgnore] and every custom serializer have had
    their say, so a caller who wants one of these can always have it. }
  Why := TSerializationTypes.UnsupportedReason(AType.Handle);
  if Why <> '' then
    raise EYamlError.CreateFmt(
      '%s %s. Leave it out with [YamlIgnore], or register a YAML type ' +
      'serializer for its type.', [MemberLabel(AMember, AType), Why]);

  Result := CollectionToYaml(AType, AValue, AMember, AOwner, Handled);
  if Handled then Exit;

  case AType.TypeKind of
    tkInteger, tkInt64:
      begin
        if AType.Handle = System.TypeInfo(Currency) then
          { A Currency is an exact decimal with four places, and its digits
            are what a YAML reader should see. The contract path knows the
            member is a Currency and reads those digits back exactly. }
          Exit(TYamlNode.NewScalar(
            CurrToStr(AValue.AsCurrency, TFormatSettings.Invariant),
            TYamlScalarStyle.Plain));
        if IsUnsignedInt64(AType) then
          Exit(TYamlNode.NewScalar(UIntToStr(AValue.AsUInt64),
            TYamlScalarStyle.Plain));
        { With the sign its type gives it: AsInt64 sign-extends every
          tkInteger type but Cardinal itself, so a 0..4000000000 subrange
          holding 4000000000 was written as -294967296. }
        Exit(TYamlNode.NewScalar(TSerializationTypes.IntegerText(AValue),
          TYamlScalarStyle.Plain));
      end;

    tkFloat:
      begin
        { Comp is a 64-bit integer RTTI files under tkFloat. }
        if TSerializationTypes.IsCompType(AType.Handle) then
          Exit(TYamlNode.NewInt(TSerializationTypes.Int64Bits(AValue)));
        if AType.Handle = System.TypeInfo(Currency) then
          Exit(TYamlNode.NewScalar(
            CurrToStr(AValue.AsCurrency, TFormatSettings.Invariant),
            TYamlScalarStyle.Plain));
        if (AType.Handle = System.TypeInfo(TDateTime)) or
           (AType.Handle = System.TypeInfo(TDate)) or
           (AType.Handle = System.TypeInfo(TTime)) then
          Exit(DateToYaml(AValue.AsExtended,
            MemberDateRepresentation(AMember, AOwner, Pattern), Pattern));
        Exit(TYamlNode.NewFloat(AValue.AsExtended));
      end;

    tkEnumeration:
      begin
        if AType.Handle = System.TypeInfo(Boolean) then
          Exit(TYamlNode.NewBool(AValue.AsBoolean));
        Ordinal := AValue.AsOrdinal;
        if EnumNamesFor(AMember, AType.Handle, Names) and
           (Ordinal >= 0) and (Ordinal <= High(Names)) then
          EnumText := Names[Ordinal]
        else
          EnumText := GetEnumName(AType.Handle, Integer(Ordinal));
        { A name is a string, and quoted like one when the core schema would
          resolve it: a name mapped to '1' went out plain and read back as
          ordinal 1, and one mapped to '~' as null. }
        Result := TYamlNode.NewScalar(EnumText, TYamlScalarStyle.Plain);
        if TYamlSchema.NeedsQuotingAsString(EnumText) then
          Result.Style := TYamlScalarStyle.DoubleQuoted;
        Exit;
      end;

    tkSet:
      begin
        { A set is a sequence of the names it contains, which is the shape
          that survives a member being added to the enumeration.

          THE BITS ARE READ FROM THE VALUE'S OWN STORAGE, not through
          AsOrdinal. TValue.AsOrdinal raises EInvalidCast for tkSet - a set
          is not an ordinal - and a set wider than four bytes has no ordinal
          to give anyway. The loop is bounded by the element type's own
          MinValue and MaxValue and by the value's DataSize, so no byte
          outside the set is ever read and no phantom member appears. }
        ElemInfo := GetTypeData(AType.Handle).CompType^;
        { An enumeration's elements through its mapping: YAML's own, then
          [SerializationEnum]. }
        if not EnumNamesFor(AMember, ElemInfo, Names) then Names := nil;
        Result := TYamlNode.NewSequence;
        try
          { Through TSerializationTypes: bit 0 is the byte holding the
            lowest member, not ordinal 0. }
          for I in TSerializationTypes.SetOrdinals(AType.Handle, AValue) do
            Result.Add(TYamlNode.NewScalar(
              TSerializationTypes.MappedSetElementText(ElemInfo, I, Names),
              TYamlScalarStyle.Plain));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;

    tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
      begin
        Result := TYamlNode.NewScalar(AValue.AsString, TYamlScalarStyle.Plain);
        if TYamlSchema.NeedsQuotingAsString(AValue.AsString) then
          Result.Style := TYamlScalarStyle.DoubleQuoted;
        Exit;
      end;

    tkDynArray:
      begin
        if AType.Handle = System.TypeInfo(TBytes) then
        begin
          Result := TYamlNode.NewScalar(
            TNetEncoding.Base64.EncodeBytesToString(AValue.AsType<TBytes>),
            TYamlScalarStyle.DoubleQuoted);
          Result.Tag := TYamlSchema.TagBinary;
          Exit;
        end;
        { An array is one level of the graph, as an object is: a record that
          holds an array of itself recursed past the 64-level guard until
          the stack ran out, and wrote what the reader refuses long before. }
        TSerializationGraphGuard.EnterLevel;
        try
          Result := TYamlNode.NewSequence;
          try
            for I := 0 to Integer(AValue.GetArrayLength - 1) do
              Result.Add(ValueToYaml(
                GCtx.GetType(AValue.GetArrayElement(I).TypeInfo),
                AValue.GetArrayElement(I), nil, AOwner));
          except
            Result.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
        Exit;
      end;

    tkArray:
      begin
        TSerializationGraphGuard.EnterLevel;
        try
          Result := TYamlNode.NewSequence;
          try
            for I := 0 to Integer(AValue.GetArrayLength - 1) do
              Result.Add(ValueToYaml(
                GCtx.GetType(AValue.GetArrayElement(I).TypeInfo),
                AValue.GetArrayElement(I), nil, AOwner));
          except
            Result.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
        Exit;
      end;

    tkRecord, tkMRecord:
      begin
        if AType.Handle = System.TypeInfo(TGUID) then
          Exit(TYamlNode.NewScalar(
            LowerCase(Copy(GUIDToString(AValue.AsType<TGUID>), 2, 36)),
            TYamlScalarStyle.Plain));
        { A record is one level, as an object is - a TNullable<record>
          payload included, which arrives here. }
        TSerializationGraphGuard.EnterLevel;
        try
          Result := TYamlNode.NewMapping;
          try
            Members := MembersOf(AType);
            for M in Members do
            begin
              RefuseUnwritableMember(M, MemberType(M));
              MemberVal := MemberValue(M, AValue);
              if IsEmptyNullable(MemberType(M), MemberVal) then Continue;
              if (MemberType(M).TypeKind = tkVariant) and
                 VarIsEmpty(MemberVal.AsVariant) then Continue;
              Result.AddPair(MemberName(M),
                ValueToYaml(MemberType(M), MemberVal, M, AType.Handle));
            end;
          except
            Result.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
        Exit;
      end;

    tkClass:
      begin
        if AValue.AsObject = nil then Exit(TYamlNode.NewNull);
        if not TSerializationGraphGuard.Enter(AValue.AsObject) then
          raise EYamlError.CreateFmt(
            '%s is already being written further up the graph: it is a ' +
            'cycle. YAML anchors could name it, but a contract written back ' +
            'as a graph would claim an identity nothing else here keeps. ' +
            'Break the cycle, or register a YAML type serializer.',
            [AValue.AsObject.ClassName]);
        try
          Result := TYamlNode.NewMapping;
          try
            Members := MembersOf(AType);
            for M in Members do
            begin
              RefuseUnwritableMember(M, MemberType(M));
              MemberVal := MemberValue(M, AValue);
              if IsEmptyNullable(MemberType(M), MemberVal) then Continue;
              { Unassigned is no value at all, so the member is left out. }
              if (MemberType(M).TypeKind = tkVariant) and
                 VarIsEmpty(MemberVal.AsVariant) then Continue;
              Result.AddPair(MemberName(M),
                ValueToYaml(MemberType(M), MemberVal, M, AType.Handle));
            end;
          except
            Result.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.Leave(AValue.AsObject);
        end;
        Exit;
      end;

    { A Variant through the dynamic tree - the bridge every format shares. }
    tkVariant:
      begin
        if not TSerializationVariants.TryToDynamic(AValue.AsVariant, Tree,
             Why) then
          raise EYamlError.CreateFmt('%s: the value %s.',
            [MemberLabel(AMember, AType), Why]);
        try
          Exit(TYamlEngine.DynamicToYaml(Tree,
            TStructuralConversionOptions.Default));
        finally
          Tree.Free;
        end;
      end;
  end;

  { Nothing above can write this. Writing a YAML null instead would read back
    as a value nobody wrote. }
  raise EYamlError.CreateFmt('%s is a %s, which YAML has no way to write. ' +
    'Register a YAML type serializer for it, or leave it out with ' +
    '[YamlIgnore].', [MemberLabel(AMember, AType), AType.Name]);
end;

function YamlToValue(AType: TRttiType; ANode: TYamlNode;
  AMember: TRttiMember; AOwner: PTypeInfo;
  const AExisting: TValue): TValue; forward;

function YamlToDate(ANode: TYamlNode;
  ARepresentation: TYamlDateTimeRepresentation;
  const APattern: string): TDateTime;
var
  Count: Int64;
begin
  { Range-checked, and correct before 1899-12-30: UnixDateDelta plus a
    fraction of days put a pre-1899 instant on the wrong day, and
    IncMilliSecond raised the RTL's EIntOverflow, or EConvertError, for a
    count past the years a TDateTime holds. }
  case ARepresentation of
    TYamlDateTimeRepresentation.UnixSeconds:
      if ANode.ScalarType = TYamlScalarType.Int then
      begin
        if not (TYamlSchema.TryToInt64(ANode.Value, Count) and
                TStructuralText.TryUnixSecondsToDateTime(Count, Result)) then
          raise EYamlInputError.CreateFmt(
            '%s is not a count of seconds a TDateTime holds.', [ANode.Value]);
        Exit;
      end;
    TYamlDateTimeRepresentation.UnixMilliseconds:
      if ANode.ScalarType = TYamlScalarType.Int then
      begin
        if not (TYamlSchema.TryToInt64(ANode.Value, Count) and
                TStructuralText.TryUnixMillisToDateTime(Count, Result)) then
          raise EYamlInputError.CreateFmt(
            '%s is not a count of milliseconds a TDateTime holds.',
            [ANode.Value]);
        Exit;
      end;
  end;
  { A custom pattern is read with itself first: it is what this member's
    writer wrote. }
  if (ARepresentation = TYamlDateTimeRepresentation.CustomString) and
     TStructuralText.TryDecodePattern(ANode.Value, APattern, Result) then
    Exit;
  { ONE SPELLING, READ EVERYWHERE - see the same three lines in the CBOR
    engine. A date-only or time-only value written by another format is an
    ordinary thing to receive, and ISO8601ToDate refuses both. }
  if TStructuralText.TryDecodeDateTime(ANode.Value, Result) then Exit;
  if TStructuralText.TryDecodeDate(ANode.Value, Result) then Exit;
  if TStructuralText.TryDecodeTime(ANode.Value, Result) then Exit;
  try
    Result := TStructuralText.DecodeIso8601(ANode.Value);
  except
    on E: Exception do
      raise EYamlError.CreateFmt(
        '"%s" is not a date, a time or a date and time.', [ANode.Value]);
  end;
end;

{ Fill a collection object from a YAML sequence or mapping, and say whether it
  was one. The inverse of CollectionToYaml, and the two have to agree or a
  list survives one direction and not the other. }
function FillCollection(AType: TRttiType; const AInstance: TValue;
  ANode: TYamlNode; AOwner: PTypeInfo): Boolean;
var
  AddMethod, ClearMethod: TRttiMethod;
  ListAccess: TListAccess;
  DictAccess: TDictionaryAccess;
  Params: TArray<TRttiParameter>;
  IsMap: Boolean;
  I: Integer;
  KeyType, ValueType: TRttiType;
  Key, Item: TValue;

  { An element that never reached the container - the container refused
    it, or its key's value failed - is this read's to free. }
  procedure Discard(AElementType: TRttiType; const AElement: TValue);
  begin
    if AElementType <> nil then
      TSerializationOwnership.ReleaseBuilt(AElementType.Handle, AElement,
        TValue.Empty);
  end;

  { What the container itself raised - a sorted TStringList with
    dupError raises EStringListError - is a document this container cannot
    hold, and reached the caller as the RTL's exception. }
  function Refusal(E: Exception): Exception;
  begin
    Result := EYamlInputError.CreateFmt(
      'The %s refused an element the document holds: %s',
      [AInstance.AsObject.ClassName, E.Message]);
  end;

begin
  Result := False;
  if (AType = nil) or (ANode = nil) then Exit;
  if not AInstance.IsObject or (AInstance.AsObject = nil) then Exit;

  { The same classification the writer uses, from the same place. }
  case TSerializationTypes.ContainerKindOf(AType.Handle) of
    TContainerKind.Dictionary:
      begin
        IsMap := True;
        if not TSerializationTypes.TryGetDictionaryAccess(AType.Handle,
          DictAccess) then Exit;
        AddMethod := DictAccess.AddOrSetMethod;
        ClearMethod := DictAccess.ClearMethod;
      end;
    TContainerKind.List:
      begin
        IsMap := False;
        if not TSerializationTypes.TryGetListAccess(AType.Handle,
          ListAccess) then Exit;
        AddMethod := ListAccess.AddMethod;
        ClearMethod := ListAccess.ClearMethod;
      end;
  else
    Exit;
  end;
  if AddMethod = nil then Exit;

  { Checked BEFORE the container is cleared: a scalar or a sequence where a
    dictionary belongs is a document that does not match the contract - not
    an empty container, and not a reason to erase the caller's items on the
    way to failing. }
  if IsMap and (ANode.Kind <> TYamlKind.Mapping) then
    raise EYamlInputError.CreateFmt('Expected a mapping for %s, found %s.',
      [AType.Name, ANode.Describe]);
  if (not IsMap) and (ANode.Kind <> TYamlKind.Sequence) then
    raise EYamlInputError.CreateFmt('Expected a sequence for %s, found %s.',
      [AType.Name, ANode.Describe]);

  if ClearMethod <> nil then ClearMethod.Invoke(AInstance.AsObject, []);
  Params := AddMethod.GetParameters;

  if IsMap then
  begin
    KeyType := Params[0].ParamType;
    ValueType := Params[1].ParamType;
    for I := 0 to ANode.Count - 1 do
    begin
      Key := YamlToValue(KeyType, ANode.Keys[I], nil, AOwner, TValue.Empty);
      try
        Item := YamlToValue(ValueType, ANode.Items[I], nil, AOwner,
          TValue.Empty);
      except
        Discard(KeyType, Key);
        raise;
      end;
      try
        { Not AddOrSetValue: two keys the document spells differently can
          be one Delphi key - 1 and 01 into an Integer - and the second
          replaced the value this read built for the first, which a
          dictionary that does not own its values orphaned. }
        TSerializationOwnership.AddOrSetBuilt(DictAccess, AInstance.AsObject,
          Key, Item);
      except
        on E: Exception do
        begin
          Discard(KeyType, Key);
          Discard(ValueType, Item);
          if string(E.UnitName).StartsWith('PascalForge.') then raise;
          raise Refusal(E);
        end;
      end;
    end;
    Exit(True);
  end;

  if ANode.Kind <> TYamlKind.Sequence then Exit;
  ValueType := Params[0].ParamType;
  for I := 0 to ANode.Count - 1 do
  begin
    Item := YamlToValue(ValueType, ANode.Items[I], nil, AOwner, TValue.Empty);
    try
      AddMethod.Invoke(AInstance.AsObject, [Item]);
    except
      on E: Exception do
      begin
        Discard(ValueType, Item);
        if string(E.UnitName).StartsWith('PascalForge.') then raise;
        raise Refusal(E);
      end;
    end;
  end;
  Result := True;
end;

function YamlToValue(AType: TRttiType; ANode: TYamlNode;
  AMember: TRttiMember; AOwner: PTypeInfo;
  const AExisting: TValue): TValue;
var
  I, Len: Integer;
  Members: TArray<TRttiMember>;
  M: TRttiMember;
  Obj: TObject;
  Instance, Arr, Elem, Prior: TValue;
  Child: TYamlNode;
  Names: TArray<string>;
  Pattern: string;
  Access: TNullableAccess;
  SerializerClass: TYamlValueSerializerClass;
  Serializer: TCustomYamlValueSerializer;
  Method: TRttiMethod;
  ElemType: TRttiType;
  EnumOrd, Ordinal: Integer;
  ArrLen: NativeInt;
  Ords: TArray<Integer>;
  Elems: TArray<TValue>;
  Why: string;
  I64: Int64;
  U64: UInt64;
  Tree: TDynamicValue;
  V: Variant;
  OV: OleVariant;
  Built: Boolean;
  TD: PTypeData;
  Cur: Currency;
begin
  Result := TValue.Empty;
  if AType = nil then Exit;

  SerializerClass := MemberSerializer(AMember);
  if SerializerClass = nil then
    TYamlEngine.TryGetTypeSerializer(AType.Handle, SerializerClass);
  if SerializerClass <> nil then
  begin
    Serializer := SerializerClass.Create;
    try
      Exit(Serializer.Deserialize(ANode, AType.Handle, AExisting));
    finally
      Serializer.Free;
    end;
  end;

  if TSerializationTypes.TryGetNullableAccess(AType.Handle, Access) then
  begin
    TValue.Make(nil, AType.Handle, Result);
    if (ANode = nil) or ANode.IsNull then Exit;
    Access.SetValue(Result.GetReferenceToRawData,
      YamlToValue(GCtx.GetType(Access.ValueType), ANode, AMember, AOwner,
        TValue.Empty));
    Exit;
  end;

  { A YAML null into a Variant is Null, not Unassigned. }
  if (AType.TypeKind = tkVariant) and (ANode <> nil) and ANode.IsNull then
  begin
    V := Null;
    TValue.Make(@V, AType.Handle, Result);
    Exit;
  end;

  { A name registered for an enumeration is looked up before the core
    schema has its say. The writer quotes a name the schema would resolve,
    but a hand-written plain 1 or ~ is still the name the mapping gives:
    read as ordinal 1, or as null and so the default, it was another
    value, silently. }
  if (ANode <> nil) and (ANode.Kind = TYamlKind.Scalar) and
     (AType.TypeKind = tkEnumeration) and
     (AType.Handle <> System.TypeInfo(Boolean)) and
     EnumNamesFor(AMember, AType.Handle, Names) then
    for I := 0 to Integer(High(Names)) do
      if SameText(Names[I], ANode.Value) then
        Exit(TValue.FromOrdinal(AType.Handle, I));

  if (ANode = nil) or ANode.IsNull then
  begin
    if AType.TypeKind = tkClass then
    begin
      Obj := nil;
      TValue.Make(@Obj, AType.Handle, Result);
    end
    else
      TValue.Make(nil, AType.Handle, Result);
    Exit;
  end;

  if ANode.Kind = TYamlKind.Alias then
    raise EYamlAliasError.CreateFmt(
      'An alias (*%s) reached the contract reader unexpanded. Contract ' +
      'deserialization expands aliases first, so this is a defect here ' +
      'rather than a problem with the document.', [ANode.Value]);

  { A sequence or a mapping where a scalar belongs does not match the
    contract. Its Value is '', which every string type accepts and a Char
    reads as #0, so a collection became the empty string - and on Populate
    overwrote the caller's value - while the other scalar kinds refused it
    only because '' happens not to parse. }
  if (ANode.Kind <> TYamlKind.Scalar) and
     (AType.TypeKind in [tkInteger, tkInt64, tkFloat, tkEnumeration, tkChar,
       tkWChar, tkString, tkLString, tkWString, tkUString]) then
    raise EYamlInputError.CreateFmt('Expected a scalar for %s, found %s.',
      [AType.Name, ANode.Describe]);

  case AType.TypeKind of
    tkInteger, tkInt64:
      begin
        { Range-checked against the member's own type, in the schema's own
          integer spellings. }
        if TSerializationTypes.IsUnsignedInteger(AType.Handle) then
        begin
          if not (TYamlSchema.TryToUInt64(Trim(ANode.Value), U64) and
                  TSerializationTypes.TryIntegerFromUInt64(AType.Handle, U64,
                    Result)) then
            raise EYamlInputError.CreateFmt('"%s" is not a %s.',
              [ANode.Value, AType.Name]);
          Exit;
        end;
        if not (TYamlSchema.TryToInt64(Trim(ANode.Value), I64) and
                TSerializationTypes.TryIntegerFromInt64(AType.Handle, I64,
                  Result)) then
          raise EYamlInputError.CreateFmt('"%s" is not a %s.',
            [ANode.Value, AType.Name]);
        Exit;
      end;

    tkFloat:
      begin
        if TSerializationTypes.IsCompType(AType.Handle) then
        begin
          if not (TYamlSchema.TryToInt64(Trim(ANode.Value), I64) and
                  TSerializationTypes.TryIntegerFromInt64(AType.Handle, I64,
                    Result)) then
            raise EYamlInputError.CreateFmt('"%s" is not a %s.',
              [ANode.Value, AType.Name]);
          Exit;
        end;
        { StrToCurr raised the RTL's EConvertError on text that is not one. }
        if GetTypeData(AType.Handle).FloatType = ftCurr then
        begin
          if (ANode.Kind <> TYamlKind.Scalar) or
             not TryStrToCurr(Trim(ANode.Value), Cur, TFormatSettings.Invariant) then
            raise EYamlInputError.CreateFmt('Expected a currency value, found %s.',
              [ANode.Describe]);
          Exit(TValue.From<Currency>(Cur));
        end;
        if (AType.Handle = System.TypeInfo(TDateTime)) or
           (AType.Handle = System.TypeInfo(TDate)) or
           (AType.Handle = System.TypeInfo(TTime)) then
          Exit(TValue.From<Double>(YamlToDate(ANode,
            MemberDateRepresentation(AMember, AOwner, Pattern), Pattern))
            .Cast(AType.Handle));
        { Into the member's own width, checked: a Single does not become
          infinity for a number it cannot hold. }
        if not TSerializationTypes.TryFloatFromDouble(AType.Handle,
             ANode.AsDouble, Result, Why) then
          raise EYamlInputError.CreateFmt('%s: %s.', [AType.Name, Why]);
        Exit;
      end;

    tkEnumeration:
      begin
        if AType.Handle = System.TypeInfo(Boolean) then
          Exit(TValue.From<Boolean>(ANode.AsBoolean));
        { An ordinal the type does not have is no value of it. }
        if ANode.ScalarType = TYamlScalarType.Int then
        begin
          TD := GetTypeData(AType.Handle);
          if not TYamlSchema.TryToInt64(Trim(ANode.Value), I64) or
             (I64 < TD.MinValue) or (I64 > TD.MaxValue) then
            raise EYamlInputError.CreateFmt('%s is not a value of %s.',
              [ANode.Value, AType.Name]);
          Exit(TValue.FromOrdinal(AType.Handle, I64));
        end;
        { A registered name was matched above, before the null check. }
        Ordinal := GetEnumValue(AType.Handle, ANode.Value);
        if Ordinal < 0 then
          raise EYamlInputError.CreateFmt(
            '"%s" is not one of the values of %s.',
            [ANode.Value, AType.Name]);
        Exit(TValue.FromOrdinal(AType.Handle, Ordinal));
      end;

    tkSet:
      begin
        { A member name the set does not have is refused, not skipped, and
          the set is built by TSerializationTypes: a TIntegerSet held 32 of
          its up to 256 members. }
        Ords := nil;
        { A scalar where the set's sequence belongs is not the empty set. }
        if ANode.Kind <> TYamlKind.Sequence then
          raise EYamlInputError.CreateFmt('Expected a sequence for %s, found %s.',
            [AType.Name, ANode.Describe]);
        if not EnumNamesFor(AMember, GetTypeData(AType.Handle).CompType^,
             Names) then
          Names := nil;
        for I := 0 to ANode.Count - 1 do
          begin
            if not TSerializationTypes.TryMappedSetElementOrdinal(
                 GetTypeData(AType.Handle).CompType^, ANode.Items[I].Value,
                 Names, EnumOrd) then
              raise EYamlInputError.CreateFmt('"%s" is not a member of %s.',
                [ANode.Items[I].Value, AType.Name]);
            Ords := Ords + [EnumOrd];
          end;
        if not TSerializationTypes.TryMakeSet(AType.Handle, Ords, Result, Why) then
          raise EYamlInputError.CreateFmt('Not a %s: %s.', [AType.Name, Why]);
        Exit;
      end;

    { Into the member's own code page, refusing text it cannot hold. }
    tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
      begin
        if not TSerializationTypes.TryStringFromText(AType.Handle,
             ANode.Value, Result, Why) then
          raise EYamlInputError.Create(Why + '.');
        Exit;
      end;

    { A static array has exactly as many elements as its type says. It had
      no reader at all, so the member was left as it was. }
    tkArray:
      begin
        if ANode.Kind <> TYamlKind.Sequence then
          raise EYamlInputError.CreateFmt('Expected a sequence for %s.',
            [AType.Name]);
        ElemType := TRttiArrayType(AType).ElementType;
        SetLength(Elems, ANode.Count);
        I := 0;
        try
          while I < ANode.Count do
          begin
            Elems[I] := YamlToValue(ElemType, ANode.Items[I], nil, AOwner,
              TValue.Empty);
            Inc(I);
          end;
          if not TSerializationTypes.TryMakeArray(AType.Handle, Elems, Result,
               Why) then
            raise EYamlInputError.Create(Why + '.');
        except
          { The elements built so far are this read's, and nothing else
            holds them yet - nor anything at all when there were too many. }
          if ElemType <> nil then
            TSerializationOwnership.ReleaseBuiltElements(ElemType.Handle,
              System.Copy(Elems, 0, I));
          raise;
        end;
        Exit;
      end;

    tkVariant:
      begin
        Tree := TYamlEngine.YamlToDynamic(ANode,
          TStructuralConversionOptions.Default);
        try
          if not TSerializationVariants.TryFromDynamic(Tree, V, Why) then
            raise EYamlInputError.Create('The YAML value ' + Why + '.');
        finally
          Tree.Free;
        end;
        if AType.Handle = System.TypeInfo(OleVariant) then
        begin
          OV := V;
          TValue.Make(@OV, AType.Handle, Result);
        end
        else
          TValue.Make(@V, AType.Handle, Result);
        Exit;
      end;

    tkDynArray:
      begin
        if AType.Handle = System.TypeInfo(TBytes) then
          Exit(TValue.From<TBytes>(ANode.AsBytes));
        { Anything but a sequence is refused, never left as it was. }
        if ANode.Kind <> TYamlKind.Sequence then
          raise EYamlInputError.CreateFmt('Expected a sequence for %s, found %s.',
            [AType.Name, ANode.Describe]);
        Len := ANode.Count;
        TValue.Make(nil, AType.Handle, Arr);
        ElemType := nil;
        if GetTypeData(AType.Handle).DynArrElType <> nil then
          ElemType := GCtx.GetType(GetTypeData(AType.Handle).DynArrElType^);
        ArrLen := Len;
        DynArraySetLength(PPointer(Arr.GetReferenceToRawData)^,
          AType.Handle, 1, @ArrLen);
        try
          for I := 0 to Len - 1 do
          begin
            Elem := YamlToValue(ElemType, ANode.Items[I], nil, AOwner,
              TValue.Empty);
            Arr.SetArrayElement(I, Elem);
          end;
        except
          { Every element of the fresh array is this read's; the ones not
            reached yet are nil. }
          TSerializationOwnership.ReleaseBuilt(AType.Handle, Arr, TValue.Empty);
          raise;
        end;
        Exit(Arr);
      end;

    tkRecord, tkMRecord:
      begin
        if AType.Handle = System.TypeInfo(TGUID) then
        begin
          { A YAML error, not the RTL's EConvertError. }
          Pattern := Trim(ANode.Value);
          if (Pattern <> '') and (Pattern[1] <> '{') then
            Pattern := '{' + Pattern + '}';
          try
            Exit(TValue.From<TGUID>(StringToGUID(Pattern)));
          except
            on E: EConvertError do
              raise EYamlInputError.CreateFmt('"%s" is not a GUID.',
                [ANode.Value]);
          end;
        end;
        { A record is a mapping; anything else found no member and left
          every one at its default, silently. }
        if ANode.Kind <> TYamlKind.Mapping then
          raise EYamlInputError.CreateFmt('Expected a mapping for %s, found %s.',
            [AType.Name, ANode.Describe]);
        { Merged into a COPY of the current value, as the class branch fills
          an existing instance: a zeroed record replaced every object already
          in it and reset every member the document left out. A copy, not
          the TValue itself - assigning it shares its data, so a failure
          could not tell the objects this read built from the ones that were
          there. }
        if (not AExisting.IsEmpty) and (AExisting.TypeInfo = AType.Handle) then
          Prior := AExisting
        else
          Prior := TValue.Empty;
        if Prior.IsEmpty then TValue.Make(nil, AType.Handle, Result)
        else TValue.Make(Prior.GetReferenceToRawData, AType.Handle, Result);
        try
          Members := MembersOf(AType);
          for M in Members do
          begin
            Child := ANode.Find(MemberName(M));
            if Child = nil then Continue;
            SetMemberValue(M, Result,
              YamlToValue(MemberType(M), Child, M, AType.Handle,
                ExistingValueOf(M, Result)));
          end;
        except
          { The record reaches its owner only on success, so an object this
            read put in it before a later member failed went with the
            temporary. }
          TSerializationOwnership.ReleaseBuilt(AType.Handle, Result, Prior);
          raise;
        end;
        Exit;
      end;

    tkClass:
      begin
        Built := False;
        if AExisting.IsObject and (AExisting.AsObject <> nil) then
          Instance := AExisting
        else
        begin
          Method := TSerializationTypes.DefaultConstructor(AType);
          if Method = nil then
            raise EYamlInputError.CreateFmt(
              '%s has no parameterless constructor, so YAML cannot build ' +
              'one. Pass an instance to Populate instead.', [AType.Name]);
          Obj := Method.Invoke(TRttiInstanceType(AType).MetaclassType,
            []).AsObject;
          TValue.Make(@Obj, AType.Handle, Instance);
          Built := True;
        end;
        { What this read constructed is this read's to free when it fails;
          an instance the caller passed in is never freed. }
        try
          { A class written as a sequence or a dictionary has to be read back
            as one, and BEFORE the member walk - a TObjectList also has
            fields, and walking them would fill none of them and lose every
            element. }
          if FillCollection(AType, Instance, ANode, AOwner) then Exit(Instance);
          if ANode.Kind <> TYamlKind.Mapping then
            raise EYamlInputError.CreateFmt('Expected a mapping for %s, found %s.',
              [AType.Name, ANode.Describe]);
          Members := MembersOf(AType);
          for M in Members do
          begin
            Child := ANode.Find(MemberName(M));
            if Child = nil then Continue;
            SetMemberValue(M, Instance,
              YamlToValue(MemberType(M), Child, M, AType.Handle,
                ExistingValueOf(M, Instance)));
          end;
        except
          { A list or dictionary that does not own its elements, freed alone,
            orphaned every object this read had added to it. }
          if Built then
          begin
            if TSerializationTypes.ContainerKindOf(AType.Handle) <>
               TContainerKind.None then
              TSerializationOwnership.ReleaseBuiltContainer(Instance.AsObject)
            else
              Instance.AsObject.Free;
          end;
          raise;
        end;
        Exit(Instance);
      end;
  end;
end;

{ ===========================================================================
  TYamlEngine
  =========================================================================== }

class constructor TYamlEngine.Create;
begin
  FLock := TCriticalSection.Create;
  FDatePolicies := TDateTimePolicies.Create(
    TDateTimePolicy.Make(Ord(TYamlDateTimeRepresentation.Iso8601)));
  FEnumMappings := TDictionary<string, TArray<string>>.Create;
  FTypeSerializers := TDictionary<string, TYamlValueSerializerClass>.Create;
  FDefaultEmit := TYamlEmitOptions.Default;
  FDuplicateKeys := TYamlDuplicateKeyPolicy.Error;
  FLimits := TYamlLimits.Default;
end;

class destructor TYamlEngine.Destroy;
begin
  FTypeSerializers.Free;
  FEnumMappings.Free;
  FDatePolicies.Free;
  FLock.Free;
end;

class procedure TYamlEngine.CheckNotFrozen;
begin
  if FFrozen then
    raise EYamlInternalError.Create(
      'The YAML configuration is frozen. FreezeConfiguration is the point ' +
      'at which every setting stops moving, so that nothing registered ' +
      'afterwards can silently change what an already-running thread is ' +
      'writing.');
end;

class function TYamlEngine.ParseStream(const AYaml: string): TYamlStream;
var
  Parser: TYamlParser;
begin
  Parser := TYamlParser.Create(AYaml, Limits, DuplicateKeyPolicy);
  try
    Result := Parser.ParseStream;
  finally
    Parser.Free;
  end;
end;

{ Re-register the anchors of a CLONED tree.

  A clone carries the anchor names because they are part of the node, but a
  document's anchor table points at node instances - so after a clone the
  table would still point into the original tree, and ResolveAnchor would
  hand back a node the caller does not own. Walking the copy fixes that. }
procedure RegisterAnchorsOf(ANode: TYamlNode; ADocument: TYamlDocument);
var
  I: Integer;
begin
  if ANode = nil then Exit;
  if ANode.Anchor <> '' then ADocument.RegisterAnchor(ANode.Anchor, ANode);
  case ANode.Kind of
    TYamlKind.Sequence:
      for I := 0 to ANode.Count - 1 do
        RegisterAnchorsOf(ANode.Items[I], ADocument);
    TYamlKind.Mapping:
      for I := 0 to ANode.Count - 1 do
      begin
        RegisterAnchorsOf(ANode.Keys[I], ADocument);
        RegisterAnchorsOf(ANode.Items[I], ADocument);
      end;
  end;
end;

class function TYamlEngine.ParseSingleDocument(
  const AYaml: string): TYamlDocument;
var
  Stream: TYamlStream;
  Doc: TYamlDocument;
begin
  Stream := ParseStream(AYaml);
  try
    if Stream.Count <> 1 then
      raise EYamlInputError.CreateFmt(
        'This is a stream of %d documents and ParseDocument reads exactly ' +
        'one. Use ParseStream, which returns them all - a YAML stream is a ' +
        'sequence of documents and this library will not silently keep the ' +
        'first.', [Stream.Count]);
    Doc := Stream[0];
    Result := TYamlDocument.Create;
    try
      Result.Version := Doc.Version;
      Result.TagDirectives := Doc.TagDirectives;
      Result.ExplicitStart := Doc.ExplicitStart;
      Result.ExplicitEnd := Doc.ExplicitEnd;
      Result.Root := Doc.Root.Clone;
      RegisterAnchorsOf(Result.Root, Result);
    except
      Result.Free;
      raise;
    end;
  finally
    Stream.Free;
  end;
end;

class function TYamlEngine.EmitDocument(ADocument: TYamlDocument;
  const AOptions: TYamlEmitOptions): string;
var
  Emitter: TYamlEmitter;
begin
  Emitter := TYamlEmitter.Create(AOptions);
  try
    Result := Emitter.EmitDocument(ADocument, False);
  finally
    Emitter.Free;
  end;
end;

class function TYamlEngine.EmitStream(AStream: TYamlStream;
  const AOptions: TYamlEmitOptions): string;
var
  Emitter: TYamlEmitter;
  I: Integer;
  Buf: TStringBuilder;
begin
  Buf := TStringBuilder.Create;
  try
    for I := 0 to AStream.Count - 1 do
    begin
      Emitter := TYamlEmitter.Create(AOptions);
      try
        { Every document after the first MUST carry --- : that marker is the
          only thing separating one document from the next, so leaving it out
          would turn a stream into one unreadable document. }
        Buf.Append(Emitter.EmitDocument(AStream[I], I > 0));
      finally
        Emitter.Free;
      end;
    end;
    Result := Buf.ToString;
  finally
    Buf.Free;
  end;
end;

class function TYamlEngine.ExpandDocument(
  ADocument: TYamlDocument): TYamlDocument;
var
  Expander: TYamlExpander;
begin
  Expander := TYamlExpander.Create(ADocument, Limits);
  try
    Result := Expander.Run;
  finally
    Expander.Free;
  end;
end;

class function TYamlEngine.SerializeRoot(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AOptions: TYamlEmitOptions): string;
var
  Doc: TYamlDocument;
  Mark: Integer;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  Doc := TYamlDocument.Create;
  try
    { A write that failed deep down must not leave the next one on this
      thread starting part way down the depth limit. }
    Mark := TSerializationGraphGuard.Level;
    try
      Doc.Root := ValueToYaml(GCtx.GetType(ATypeInfo), AValue, nil, ATypeInfo);
    finally
      TSerializationGraphGuard.RestoreLevel(Mark);
    end;
    Result := EmitDocument(Doc, AOptions);
  finally
    Doc.Free;
  end;
end;

class function TYamlEngine.SerializeRootAll(ATypeInfo: PTypeInfo;
  const AValues: TArray<TValue>;
  const AOptions: TYamlEmitOptions): string;
var
  Stream: TYamlStream;
  Doc: TYamlDocument;
  I, Mark: Integer;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  Stream := TYamlStream.Create;
  try
    for I := 0 to Integer(High(AValues)) do
    begin
      Doc := TYamlDocument.Create;
      Doc.ExplicitStart := True;
      Stream.Add(Doc);
      Mark := TSerializationGraphGuard.Level;
      try
        Doc.Root := ValueToYaml(GCtx.GetType(ATypeInfo), AValues[I], nil,
          ATypeInfo);
      finally
        TSerializationGraphGuard.RestoreLevel(Mark);
      end;
    end;
    Result := EmitStream(Stream, AOptions);
  finally
    Stream.Free;
  end;
end;

class function TYamlEngine.DeserializeRoot(ATypeInfo: PTypeInfo;
  const AYaml: string; const AExisting: TValue): TValue;
var
  Stream: TYamlStream;
  Expanded: TYamlDocument;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  Stream := ParseStream(AYaml);
  try
    if Stream.Count <> 1 then
      raise EYamlInputError.CreateFmt(
        'This is a stream of %d documents and Deserialize reads exactly ' +
        'one. DeserializeAll<T> returns one value per document.',
        [Stream.Count]);
    { Aliases are expanded here and not in the parser: a Delphi record has no
      way to be two members at once, so the contract path needs a tree while
      the graph path keeps the graph. }
    Expanded := ExpandDocument(Stream[0]);
    try
      Result := YamlToValue(GCtx.GetType(ATypeInfo), Expanded.Root, nil,
        ATypeInfo, AExisting);
    finally
      Expanded.Free;
    end;
  finally
    Stream.Free;
  end;
end;

class function TYamlEngine.DeserializeRootAll(ATypeInfo: PTypeInfo;
  const AYaml: string): TArray<TValue>;
var
  Stream: TYamlStream;
  Expanded: TYamlDocument;
  I, J: Integer;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  Stream := ParseStream(AYaml);
  try
    SetLength(Result, Stream.Count);
    I := 0;
    try
      while I < Stream.Count do
      begin
        Expanded := ExpandDocument(Stream[I]);
        try
          Result[I] := YamlToValue(GCtx.GetType(ATypeInfo), Expanded.Root,
            nil, ATypeInfo, TValue.Empty);
        finally
          Expanded.Free;
        end;
        Inc(I);
      end;
    except
      { The values of the documents before the one that failed are this
        read's too, and the caller never receives them. }
      for J := 0 to I - 1 do
        TSerializationOwnership.Release(ATypeInfo, Result[J]);
      raise;
    end;
  finally
    Stream.Free;
  end;
end;

class function TYamlEngine.FromPayload(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): string;
var
  Handler: TSerializationFormatHandler;
  Value: TValue;
begin
  { Contract-aware: the source format deserializes into T by ITS rules and
    YAML writes T by its own. Reached through the registry, so this unit has
    no compile-time dependency on any other format. }
  Handler := TSerializationFormats.Get(AFrom);
  Value := Handler.DeserializeTyped(ATypeInfo, ASource);
  { DeserializeTyped hands over everything it built, and nothing else holds
    it: written or refused, it is released here. }
  try
    Result := SerializeRoot(ATypeInfo, Value, DefaultEmitOptions);
  finally
    TSerializationOwnership.Release(ATypeInfo, Value);
  end;
end;

class function TYamlEngine.FromPayloadStructural(
  const ASource: TSerializationPayload; AFrom: TSerializationFormat;
  AProfile: TStructuralConversionProfile): string;
var
  Handler: TSerializationFormatHandler;
  Options: TStructuralConversionOptions;
  Tree: TDynamicValue;
  Doc: TYamlDocument;
begin
  Options := TStructuralConversionOptions.FromProfile(AProfile);
  Handler := TSerializationFormats.Require(AFrom,
    TSerializationFormatCapability.StructuralParse, Options);
  Tree := Handler.ToDynamic(ASource, Options);
  try
    Doc := TYamlDocument.Create;
    try
      Doc.Root := DynamicToYaml(Tree, Options);
      Result := EmitDocument(Doc, DefaultEmitOptions);
    finally
      Doc.Free;
    end;
  finally
    Tree.Free;
  end;
end;

class procedure TYamlEngine.SetDateTimePolicy(ATypeInfo: PTypeInfo;
  const AFieldName: string; AKind: Integer; const APattern: string);
begin
  CheckNotFrozen;
  if ATypeInfo = nil then
    FDatePolicies.SetGlobal(TDateTimePolicy.Make(AKind, APattern))
  else if AFieldName = '' then
    FDatePolicies.SetForType(TypeKeyOf(ATypeInfo),
      TDateTimePolicy.Make(AKind, APattern))
  else
    FDatePolicies.SetForField(TypeKeyOf(ATypeInfo), AFieldName,
      TDateTimePolicy.Make(AKind, APattern));
end;

class function TYamlEngine.DatePolicyFor(ATypeInfo: PTypeInfo;
  const AFieldName: string): TDateTimePolicy;
begin
  Result := FDatePolicies.Resolve(TypeKeyOf(ATypeInfo), AFieldName);
end;

class procedure TYamlEngine.RegisterEnumMapping(ATypeInfo: PTypeInfo;
  const AValues: array of string);
var
  Copy_: TArray<string>;
  I: Integer;
begin
  CheckNotFrozen;
  SetLength(Copy_, Length(AValues));
  for I := 0 to Integer(High(AValues)) do Copy_[I] := AValues[I];
  FLock.Enter;
  try
    FEnumMappings.AddOrSetValue(TypeKeyOf(ATypeInfo), Copy_);
  finally
    FLock.Leave;
  end;
end;

class function TYamlEngine.TryGetEnumMapping(ATypeInfo: PTypeInfo;
  out AValues: TArray<string>): Boolean;
begin
  AValues := nil;
  if ATypeInfo = nil then Exit(False);
  FLock.Enter;
  try
    Result := FEnumMappings.TryGetValue(TypeKeyOf(ATypeInfo), AValues);
  finally
    FLock.Leave;
  end;
end;

class procedure TYamlEngine.RegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TYamlValueSerializerClass);
begin
  CheckNotFrozen;
  FLock.Enter;
  try
    FTypeSerializers.AddOrSetValue(TypeKeyOf(ATypeInfo), ASerializerClass);
  finally
    FLock.Leave;
  end;
end;

class function TYamlEngine.TryGetTypeSerializer(ATypeInfo: PTypeInfo;
  out AClass: TYamlValueSerializerClass): Boolean;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  AClass := nil;
  if ATypeInfo = nil then Exit(False);
  FLock.Enter;
  try
    Result := FTypeSerializers.TryGetValue(TypeKeyOf(ATypeInfo), AClass);
  finally
    FLock.Leave;
  end;
end;

class procedure TYamlEngine.SetDefaultEmitOptions(
  const AOptions: TYamlEmitOptions);
begin
  CheckNotFrozen;
  FLock.Enter;
  try
    FDefaultEmit := AOptions;
  finally
    FLock.Leave;
  end;
end;

class function TYamlEngine.DefaultEmitOptions: TYamlEmitOptions;
begin
  FLock.Enter;
  try
    Result := FDefaultEmit;
  finally
    FLock.Leave;
  end;
end;

class procedure TYamlEngine.SetDuplicateKeyPolicy(
  APolicy: TYamlDuplicateKeyPolicy);
begin
  CheckNotFrozen;
  FLock.Enter;
  try
    FDuplicateKeys := APolicy;
  finally
    FLock.Leave;
  end;
end;

class function TYamlEngine.DuplicateKeyPolicy: TYamlDuplicateKeyPolicy;
begin
  FLock.Enter;
  try
    Result := FDuplicateKeys;
  finally
    FLock.Leave;
  end;
end;

class procedure TYamlEngine.SetLimits(const ALimits: TYamlLimits);
begin
  CheckNotFrozen;
  FLock.Enter;
  try
    FLimits := ALimits;
  finally
    FLock.Leave;
  end;
end;

class function TYamlEngine.Limits: TYamlLimits;
begin
  FLock.Enter;
  try
    Result := FLimits;
  finally
    FLock.Leave;
  end;
end;

class procedure TYamlEngine.FreezeConfiguration;
begin
  FFrozen := True;
end;

class function TYamlEngine.IsFrozen: Boolean;
begin
  Result := FFrozen;
end;

class procedure TYamlEngine.ResetConfiguration;
begin
  FFrozen := False;
  FLock.Enter;
  try
    FEnumMappings.Clear;
    FTypeSerializers.Clear;
    FDefaultEmit := TYamlEmitOptions.Default;
    FDuplicateKeys := TYamlDuplicateKeyPolicy.Error;
    FLimits := TYamlLimits.Default;
  finally
    FLock.Leave;
  end;
  FDatePolicies.Reset;
end;

end.
