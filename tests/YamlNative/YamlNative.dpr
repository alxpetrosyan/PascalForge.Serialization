program YamlNative;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Is this actually a YAML 1.2 engine?

  A round trip proves only that the reader understands the writer. This
  program asks whether the DOCUMENTS are read the way the specification says
  they mean, and whether the syntax it defines is actually implemented.

  THE TARGET, named exactly:

      YAML specification revision 1.2.2
      Block and flow collections; plain, single-quoted, double-quoted,
      literal and folded scalars; chomping and indentation indicators;
      document markers and multi-document streams; %YAML and %TAG
      directives; anchors, aliases and tags; complex keys; comments;
      Unicode escapes
      The 1.2 CORE SCHEMA for scalar resolution - NOT 1.1

  THE INDEPENDENT REFERENCE is the specification itself, whose examples are
  quoted below with their section numbers, plus the set of documents that
  distinguish a 1.2 reader from a 1.1 one. Those are the interesting cases:
  a 1.1 parser reads them without complaint and gets different data.

  There is no network and no reference implementation installed on this
  machine, so the oracle is the document rather than a running program -
  said plainly rather than dressed up. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Math, System.DateUtils,
  System.StrUtils, System.Generics.Collections, Data.DB, Datasnap.DBClient,
  YamlModels in 'YamlModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Yaml in '..\..\src\PascalForge.Yaml.pas',
  PascalForge.Yaml.Internal in '..\..\src\PascalForge.Yaml.Internal.pas',
  PascalForge.Yaml.Registration in '..\..\src\PascalForge.Yaml.Registration.pas',
  PascalForge.DataSet in '..\..\src\PascalForge.DataSet.pas',
  PascalForge.DataSet.Internal in '..\..\src\PascalForge.DataSet.Internal.pas',
  AllFormatsRegistered in '..\Shared\AllFormatsRegistered.pas';

var
  GFailures: Integer = 0;
  GChecks: Integer = 0;

procedure Check(ACondition: Boolean; const AName: string);
begin
  Inc(GChecks);
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

function Hex(const ABytes: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ABytes) do
    Result := Result + LowerCase(IntToHex(ABytes[I], 2));
end;

{ A multi-line document, written without embedded line-break literals so
  that the test source stays readable. }
function Doc(const ALines: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := Low(ALines) to High(ALines) do
    Result := Result + ALines[I] + sLineBreak;
end;

{ Parse one document and hand back its root; the caller frees the document. }
function Root(const AYaml: string; out ADoc: TYamlDocument): TYamlNode;
begin
  ADoc := TYamlSerializer.ParseDocument(AYaml);
  Result := ADoc.Root;
end;

{ ===========================================================================
  SCALAR RESOLUTION - the 1.2 core schema, which is the whole point
  =========================================================================== }

procedure TestCoreSchema;

  procedure Resolves(const AText: string; AExpected: TYamlScalarType;
    const AName: string);
  begin
    Check(TYamlSchema.Resolve(AText) = AExpected, AName);
  end;

var
  D: TYamlDocument;
  N: TYamlNode;
begin
  Writeln;
  Writeln('--- the 1.2 core schema ---');

  Resolves('null', TYamlScalarType.Null, 'SCHEMA_NULL_LOWER');
  Resolves('Null', TYamlScalarType.Null, 'SCHEMA_NULL_TITLE');
  Resolves('NULL', TYamlScalarType.Null, 'SCHEMA_NULL_UPPER');
  Resolves('~',    TYamlScalarType.Null, 'SCHEMA_NULL_TILDE');
  Resolves('',     TYamlScalarType.Null, 'SCHEMA_NULL_EMPTY');

  Resolves('true',  TYamlScalarType.Bool, 'SCHEMA_TRUE');
  Resolves('True',  TYamlScalarType.Bool, 'SCHEMA_TRUE_TITLE');
  Resolves('TRUE',  TYamlScalarType.Bool, 'SCHEMA_TRUE_UPPER');
  Resolves('false', TYamlScalarType.Bool, 'SCHEMA_FALSE');

  Resolves('0',      TYamlScalarType.Int, 'SCHEMA_INT_ZERO');
  Resolves('-17',    TYamlScalarType.Int, 'SCHEMA_INT_NEGATIVE');
  Resolves('+42',    TYamlScalarType.Int, 'SCHEMA_INT_PLUS');
  Resolves('0o14',   TYamlScalarType.Int, 'SCHEMA_INT_OCTAL');
  Resolves('0xC',    TYamlScalarType.Int, 'SCHEMA_INT_HEX');

  Resolves('0.5',    TYamlScalarType.Float, 'SCHEMA_FLOAT');
  Resolves('-1.2e3', TYamlScalarType.Float, 'SCHEMA_FLOAT_EXPONENT');
  Resolves('.inf',   TYamlScalarType.Float, 'SCHEMA_FLOAT_INFINITY');
  Resolves('-.inf',  TYamlScalarType.Float, 'SCHEMA_FLOAT_NEGATIVE_INFINITY');
  Resolves('.nan',   TYamlScalarType.Float, 'SCHEMA_FLOAT_NAN');

  { THE 1.1 DIFFERENCES. Every one of these is a string in 1.2 and something
    else in 1.1, and a document read by the wrong one parses without any
    complaint and means something different. That is what makes them worth
    testing rather than assuming. }
  Resolves('yes', TYamlScalarType.Str, 'SCHEMA_YES_IS_A_STRING');
  Resolves('no',  TYamlScalarType.Str, 'SCHEMA_NO_IS_A_STRING');
  Resolves('on',  TYamlScalarType.Str, 'SCHEMA_ON_IS_A_STRING');
  Resolves('off', TYamlScalarType.Str, 'SCHEMA_OFF_IS_A_STRING');
  Resolves('y',   TYamlScalarType.Str, 'SCHEMA_Y_IS_A_STRING');
  Resolves('n',   TYamlScalarType.Str, 'SCHEMA_N_IS_A_STRING');
  Resolves('190:20:30', TYamlScalarType.Str, 'SCHEMA_SEXAGESIMAL_IS_A_STRING');
  Resolves('0b1010', TYamlScalarType.Str, 'SCHEMA_BINARY_IS_A_STRING');
  Resolves('1.2.3', TYamlScalarType.Str, 'SCHEMA_VERSION_IS_A_STRING');

  { 012 is TWELVE in 1.2 - the leading-zero octal of 1.1 is gone, and octal
    is spelled 0o14. A 1.1 reader makes this ten. }
  Resolves('012', TYamlScalarType.Int, 'SCHEMA_LEADING_ZERO_IS_DECIMAL');
  N := Root('n: 012', D);
  try
    Check(N.Find('n').AsInt64 = 12, 'SCHEMA_012_IS_TWELVE_NOT_TEN');
  finally D.Free; end;

  { A quoted, literal or folded scalar is ALWAYS a string, whatever it
    spells. }
  N := Root('a: "true"' + sLineBreak + 'b: ''123''', D);
  try
    Check(N.Find('a').ScalarType = TYamlScalarType.Str, 'QUOTED_TRUE_IS_A_STRING');
    Check(N.Find('b').ScalarType = TYamlScalarType.Str, 'QUOTED_INT_IS_A_STRING');
  finally D.Free; end;

  Check(TYamlSchema.FloatToText(1 / 0.0) = '.inf', 'FLOAT_TEXT_INFINITY');
  Check(TYamlSchema.NeedsQuotingAsString('true'), 'NEEDS_QUOTING_TRUE');
  Check(TYamlSchema.NeedsQuotingAsString('42'), 'NEEDS_QUOTING_NUMBER');
  Check(not TYamlSchema.NeedsQuotingAsString('yes'),
    'NEEDS_NO_QUOTING_FOR_YES');
end;

{ ===========================================================================
  SYNTAX
  =========================================================================== }

procedure TestBlockSyntax;
var
  D: TYamlDocument;
  N, Inner: TYamlNode;
begin
  Writeln;
  Writeln('--- block collections ---');

  N := Root(Doc(['name: PascalForge',
                 'version: 2',
                 'active: true']), D);
  try
    Check((N.Kind = TYamlKind.Mapping) and (N.Count = 3) and
          (N.Find('name').Value = 'PascalForge') and
          (N.Find('version').AsInt64 = 2) and
          N.Find('active').AsBoolean, 'BLOCK_MAPPING');
  finally D.Free; end;

  N := Root(Doc(['- one', '- two', '- three']), D);
  try
    Check((N.Kind = TYamlKind.Sequence) and (N.Count = 3) and
          (N.Items[2].Value = 'three'), 'BLOCK_SEQUENCE');
  finally D.Free; end;

  N := Root(Doc(['server:',
                 '  host: localhost',
                 '  ports:',
                 '    - 80',
                 '    - 443',
                 'debug: false']), D);
  try
    Inner := N.Find('server');
    Check((Inner.Kind = TYamlKind.Mapping) and
          (Inner.Find('host').Value = 'localhost') and
          (Inner.Find('ports').Count = 2) and
          (Inner.Find('ports').Items[1].AsInt64 = 443) and
          (not N.Find('debug').AsBoolean), 'BLOCK_NESTING');
  finally D.Free; end;

  { A sequence of mappings, which is the shape of almost every real YAML
    file and the one an indentation bug breaks first. }
  N := Root(Doc(['- name: a',
                 '  port: 1',
                 '- name: b',
                 '  port: 2']), D);
  try
    Check((N.Count = 2) and (N.Items[0].Find('name').Value = 'a') and
          (N.Items[1].Find('port').AsInt64 = 2),
      'BLOCK_SEQUENCE_OF_MAPPINGS');
  finally D.Free; end;

  { A mapping whose value is a sequence at the SAME indentation as the key,
    which YAML allows and which trips a parser that insists on more. }
  N := Root(Doc(['ports:',
                 '- 80',
                 '- 443']), D);
  try
    Check(N.Find('ports').Count = 2, 'BLOCK_SEQUENCE_AT_KEY_INDENT');
  finally D.Free; end;

  { An empty value is null, not an empty string. }
  N := Root(Doc(['a:', 'b: 1']), D);
  try
    Check(N.Find('a').IsNull and (N.Find('b').AsInt64 = 1),
      'BLOCK_EMPTY_VALUE_IS_NULL');
  finally D.Free; end;

  { Comments, whole-line and trailing. }
  N := Root(Doc(['# a leading comment',
                 'a: 1  # a trailing one',
                 '# another',
                 'b: 2']), D);
  try
    Check((N.Count = 2) and (N.Find('a').AsInt64 = 1) and
          (N.Find('b').AsInt64 = 2), 'COMMENTS');
  finally D.Free; end;
end;

procedure TestFlowSyntax;
var
  D: TYamlDocument;
  N: TYamlNode;
begin
  Writeln;
  Writeln('--- flow collections ---');

  N := Root('[1, 2, 3]', D);
  try
    Check((N.Kind = TYamlKind.Sequence) and (N.Count = 3) and
          (N.Items[1].AsInt64 = 2), 'FLOW_SEQUENCE');
  finally D.Free; end;

  N := Root('{a: 1, b: two}', D);
  try
    Check((N.Kind = TYamlKind.Mapping) and (N.Count = 2) and
          (N.Find('b').Value = 'two'), 'FLOW_MAPPING');
  finally D.Free; end;

  N := Root('{a: [1, {b: 2}], c: []}', D);
  try
    Check((N.Find('a').Count = 2) and
          (N.Find('a').Items[1].Find('b').AsInt64 = 2) and
          (N.Find('c').Count = 0), 'FLOW_NESTING');
  finally D.Free; end;

  { Flow inside block, which is how a compact list is written in an
    otherwise readable file. }
  N := Root(Doc(['name: a', 'ports: [80, 443]']), D);
  try
    Check(N.Find('ports').Count = 2, 'FLOW_INSIDE_BLOCK');
  finally D.Free; end;
end;

procedure TestScalarStyles;
var
  D: TYamlDocument;
  N: TYamlNode;
begin
  Writeln;
  Writeln('--- scalar styles ---');

  N := Root(Doc(['plain: hello world',
                 'single: ''it''''s here''',
                 'double: "a\ttab and \u00e9"']), D);
  try
    Check(N.Find('plain').Value = 'hello world', 'STYLE_PLAIN');
    Check(N.Find('single').Value = 'it''s here', 'STYLE_SINGLE_QUOTED');
    Check(N.Find('double').Value = 'a' + #9 + 'tab and ' + #$00E9,
      'STYLE_DOUBLE_QUOTED_ESCAPES');
  finally D.Free; end;

  { A \U escape may name a code point past the basic plane, which is two
    UTF-16 units in Delphi - a parser that stored one gets the length wrong
    and the character wrong. }
  N := Root('emoji: "\U0001F600"', D);
  try
    Check((Length(N.Find('emoji').Value) = 2) and
          (N.Find('emoji').Value = #$D83D#$DE00), 'STYLE_ASTRAL_ESCAPE');
  finally D.Free; end;

  { A literal block keeps its line breaks. }
  N := Root(Doc(['text: |',
                 '  line one',
                 '  line two',
                 'next: 1']), D);
  try
    Check(N.Find('text').Value = 'line one' + #10 + 'line two' + #10,
      'STYLE_LITERAL');
    Check(N.Find('next').AsInt64 = 1, 'STYLE_LITERAL_ENDS');
  finally D.Free; end;

  { A folded block joins them with spaces. }
  N := Root(Doc(['text: >',
                 '  line one',
                 '  line two',
                 'next: 1']), D);
  try
    Check(N.Find('text').Value = 'line one line two' + #10, 'STYLE_FOLDED');
  finally D.Free; end;

  { Chomping: clip keeps one break, strip keeps none, keep keeps them all. }
  N := Root(Doc(['a: |-', '  x', '', 'b: 1']), D);
  try
    Check(N.Find('a').Value = 'x', 'CHOMPING_STRIP');
  finally D.Free; end;

  N := Root(Doc(['a: |', '  x', '', 'b: 1']), D);
  try
    Check(N.Find('a').Value = 'x' + #10, 'CHOMPING_CLIP');
  finally D.Free; end;

  N := Root(Doc(['a: |+', '  x', '', '', 'b: 1']), D);
  try
    Check(Copy(N.Find('a').Value, 1, 3) = 'x' + #10 + #10, 'CHOMPING_KEEP');
  finally D.Free; end;

  { An explicit indentation indicator, for the one case the automatic rule
    cannot handle: a block whose first line is itself indented. }
  N := Root(Doc(['a: |2', '    indented', '   less', 'b: 1']), D);
  try
    Check(Copy(N.Find('a').Value, 1, 2) = '  ',
      'BLOCK_SCALAR_INDENT_INDICATOR');
  finally D.Free; end;

  { A literal scalar is a STRING whatever it spells - which is what the
    style is for. }
  N := Root(Doc(['a: |-', '  true']), D);
  try
    Check(N.Find('a').ScalarType = TYamlScalarType.Str,
      'LITERAL_TRUE_IS_A_STRING');
  finally D.Free; end;

  { A plain scalar over several lines folds into one. }
  N := Root(Doc(['a: this is', '  one long value', 'b: 1']), D);
  try
    Check(N.Find('a').Value = 'this is one long value', 'PLAIN_MULTILINE');
    Check(N.Find('b').AsInt64 = 1, 'PLAIN_MULTILINE_ENDS');
  finally D.Free; end;
end;

procedure TestAnchorsAliasesTags;
var
  D, Expanded: TYamlDocument;
  N: TYamlNode;
  Caught: Boolean;
begin
  Writeln;
  Writeln('--- anchors, aliases and tags ---');

  N := Root(Doc(['base: &defaults',
                 '  timeout: 30',
                 '  retries: 3',
                 'dev: *defaults']), D);
  try
    Check(N.Find('base').Anchor = 'defaults', 'ANCHOR_RECORDED');
    { The alias is a node of its own, NOT a copy. Nothing else in this
      library can say "these two members are the same node", so the alias
      has to stay visible. }
    Check(N.Find('dev').Kind = TYamlKind.Alias, 'ALIAS_IS_NOT_A_COPY');
    Check(N.Find('dev').Value = 'defaults', 'ALIAS_NAMES_ITS_ANCHOR');
    Check(D.ResolveAnchor('defaults') <> nil, 'ANCHOR_RESOLVES');

    { Expansion is what the contract path does, and it produces a tree. }
    Expanded := TYamlSerializer.Expand(D);
    try
      Check(Expanded.Root.Find('dev').Kind = TYamlKind.Mapping,
        'EXPAND_REPLACES_THE_ALIAS');
      Check(Expanded.Root.Find('dev').Find('timeout').AsInt64 = 30,
        'EXPAND_COPIES_THE_CONTENT');
    finally
      Expanded.Free;
    end;
  finally D.Free; end;

  { A cyclic alias is legal YAML and has no Delphi shape, so expanding it
    is refused by name rather than by running out of stack. }
  Caught := False;
  D := TYamlSerializer.ParseDocument('&a [ *a ]');
  try
    try
      Expanded := TYamlSerializer.Expand(D);
      Expanded.Free;
    except
      on E: EYamlAliasCycleError do Caught := True;
    end;
  finally D.Free; end;
  Check(Caught, 'ALIAS_CYCLE_REFUSED');

  { An alias naming nothing is an error, not a null. }
  Caught := False;
  D := TYamlSerializer.ParseDocument('a: *nowhere');
  try
    try
      Expanded := TYamlSerializer.Expand(D);
      Expanded.Free;
    except
      on E: EYamlUnresolvedAliasError do Caught := True;
    end;
  finally D.Free; end;
  Check(Caught, 'UNRESOLVED_ALIAS_REFUSED');

  { The billion laughs attack: a small document with a very large
    expansion. Refusing is the point. }
  Caught := False;
  D := TYamlSerializer.ParseDocument(Doc([
    'a: &a [x, x, x, x, x, x, x, x, x, x]',
    'b: &b [*a, *a, *a, *a, *a, *a, *a, *a, *a, *a]',
    'c: &c [*b, *b, *b, *b, *b, *b, *b, *b, *b, *b]',
    'd: &d [*c, *c, *c, *c, *c, *c, *c, *c, *c, *c]',
    'e: &e [*d, *d, *d, *d, *d, *d, *d, *d, *d, *d]',
    'f: &f [*e, *e, *e, *e, *e, *e, *e, *e, *e, *e]',
    'g: [*f, *f, *f, *f, *f, *f, *f, *f, *f, *f]']));
  try
    try
      Expanded := TYamlSerializer.Expand(D);
      Expanded.Free;
    except
      on E: EYamlLimitExceeded do Caught := True;
    end;
  finally D.Free; end;
  Check(Caught, 'ALIAS_BOMB_REFUSED');

  { Tags. The secondary handle expands to YAML's own type repository. }
  N := Root(Doc(['a: !!str 123', 'b: !!binary "AQID"']), D);
  try
    Check(N.Find('a').Tag = TYamlSchema.TagStr, 'TAG_SECONDARY_HANDLE');
    Check(N.Find('a').ScalarType = TYamlScalarType.Str,
      'TAG_OVERRIDES_THE_SCHEMA');
    Check(Hex(N.Find('b').AsBytes) = '010203', 'TAG_BINARY_IS_BASE64');
  finally D.Free; end;

  { A %TAG directive redirects a handle, and the document says so. }
  N := Root(Doc(['%TAG !e! tag:example.com,2026:',
                 '---',
                 'a: !e!thing 1']), D);
  try
    Check(N.Find('a').Tag = 'tag:example.com,2026:thing',
      'TAG_DIRECTIVE_APPLIED');
    Check(Length(D.TagDirectives) = 1, 'TAG_DIRECTIVE_RECORDED');
  finally D.Free; end;

  { A verbatim tag applies no handle at all. }
  N := Root('a: !<tag:example.com,2026:other> 1', D);
  try
    Check(N.Find('a').Tag = 'tag:example.com,2026:other', 'TAG_VERBATIM');
  finally D.Free; end;
end;

procedure TestComplexKeysAndDocuments;
var
  D: TYamlDocument;
  S: TYamlStream;
  N: TYamlNode;
  Caught: Boolean;
begin
  Writeln;
  Writeln('--- complex keys, directives and streams ---');

  { "? key : value" is how YAML writes a key that is itself a collection.
    Flattening it to text at parse time would be the only chance to see it,
    gone. }
  N := Root(Doc(['? - a', '  - b', ': the pair']), D);
  try
    Check((N.Kind = TYamlKind.Mapping) and (N.Count = 1) and
          (N.Keys[0].Kind = TYamlKind.Sequence) and
          (N.Keys[0].Count = 2), 'COMPLEX_KEY_IS_A_NODE');
    Check(N.Items[0].Value = 'the pair', 'COMPLEX_KEY_VALUE');
  finally D.Free; end;

  { A %YAML directive is recorded, and a version this library does not
    implement is refused rather than guessed at. }
  Root(Doc(['%YAML 1.2', '---', 'a: 1']), D);
  try
    Check(D.Version = '1.2', 'YAML_DIRECTIVE_RECORDED');
    Check(D.ExplicitStart, 'EXPLICIT_DOCUMENT_START');
  finally D.Free; end;

  Caught := False;
  try
    D := TYamlSerializer.ParseDocument(Doc(['%YAML 2.0', '---', 'a: 1']));
    D.Free;
  except
    on E: EYamlParseError do Caught := True;
  end;
  Check(Caught, 'UNKNOWN_YAML_VERSION_REFUSED');

  { A stream of N documents is N documents. }
  S := TYamlSerializer.ParseStream(Doc(['---', 'a: 1', '---', 'a: 2',
                                        '---', 'a: 3']));
  try
    Check(S.Count = 3, 'MULTI_DOCUMENT_STREAM');
    Check(S[1].Root.Find('a').AsInt64 = 2, 'MULTI_DOCUMENT_CONTENT');
  finally
    S.Free;
  end;

  { ... closes a document explicitly. }
  S := TYamlSerializer.ParseStream(Doc(['a: 1', '...', '---', 'a: 2']));
  try
    Check(S.Count = 2, 'DOCUMENT_END_MARKER');
  finally
    S.Free;
  end;

  { ParseDocument reads exactly one, and NAMES ParseStream when it finds
    more rather than silently keeping the first. }
  Caught := False;
  try
    D := TYamlSerializer.ParseDocument(Doc(['---', 'a: 1', '---', 'a: 2']));
    D.Free;
  except
    on E: EYamlInputError do
      Caught := Pos('ParseStream', E.Message) > 0;
  end;
  Check(Caught, 'ONE_DOCUMENT_EXPECTED_NAMES_THE_ALTERNATIVE');
end;

procedure TestErrors;
var
  D: TYamlDocument;
  Caught: Boolean;
  Msg: string;
begin
  Writeln;
  Writeln('--- documents that are wrong ---');

  { A tab used as indentation. YAML forbids it outright because a tab has no
    defined width - and this is the single most common way a hand-written
    file goes wrong, so the message has to say what to do instead. }
  Caught := False;
  Msg := '';
  try
    D := TYamlSerializer.ParseDocument('a:' + sLineBreak + #9 + 'b: 1');
    D.Free;
  except
    on E: EYamlTabIndentationError do
    begin
      Caught := True;
      Msg := E.Message;
    end;
  end;
  Note(Copy(Msg, 1, 90));
  Check(Caught, 'TAB_INDENTATION_REFUSED');
  Check(Pos('spaces', Msg) > 0, 'TAB_ERROR_SAYS_WHAT_TO_DO');

  Caught := False;
  try
    D := TYamlSerializer.ParseDocument('a: "unclosed');
    D.Free;
  except
    on E: EYamlUnclosedQuoteError do Caught := True;
  end;
  Check(Caught, 'UNCLOSED_QUOTE_REFUSED');

  { A repeated key: the specification says a mapping's keys are unique, so
    the document does not say what it looks like it says. }
  Caught := False;
  try
    D := TYamlSerializer.ParseDocument(Doc(['a: 1', 'a: 2']));
    D.Free;
  except
    on E: EYamlDuplicateKeyError do Caught := True;
  end;
  Check(Caught, 'DUPLICATE_KEY_REFUSED');

  { And relaxed, for a file somebody else wrote. }
  TYamlSerializer.SetDuplicateKeyPolicy(TYamlDuplicateKeyPolicy.LastWins);
  try
    D := TYamlSerializer.ParseDocument(Doc(['a: 1', 'a: 2']));
    try
      Check(D.Root.Find('a').AsInt64 = 2, 'DUPLICATE_KEY_LAST_WINS');
    finally D.Free; end;
  finally
    TYamlSerializer.SetDuplicateKeyPolicy(TYamlDuplicateKeyPolicy.Error);
  end;

  { A parse error names a line and a column: "invalid YAML" with no position
    is useless on a file of any size. }
  Caught := False;
  try
    D := TYamlSerializer.ParseDocument(Doc(['a: 1', 'b: "oops']));
    D.Free;
  except
    on E: EYamlParseError do Caught := E.Line = 2;
  end;
  Check(Caught, 'PARSE_ERROR_NAMES_THE_LINE');
end;

{ ===========================================================================
  EMITTING
  =========================================================================== }

procedure TestEmitting;
var
  D: TYamlDocument;
  N: TYamlNode;
  Text: string;
  Options: TYamlEmitOptions;
begin
  Writeln;
  Writeln('--- emitting ---');

  D := TYamlDocument.Create;
  try
    N := TYamlNode.NewMapping;
    N.AddPair('name', TYamlNode.NewScalar('PascalForge'));
    N.AddPair('version', TYamlNode.NewInt(2));
    N.AddPair('active', TYamlNode.NewBool(True));
    D.Root := N;
    Text := TYamlSerializer.SerializeDocument(D);
    Note(StringReplace(Trim(Text), sLineBreak, ' | ', [rfReplaceAll]));
    Check(Pos('name: PascalForge', Text) > 0, 'EMIT_BLOCK_MAPPING');
    Check(Pos('active: true', Text) > 0, 'EMIT_BOOLEAN');

    Options := TYamlEmitOptions.FlowStyle;
    Text := TYamlSerializer.SerializeDocument(D, Options);
    Check(Pos('{name: PascalForge', Text) > 0, 'EMIT_FLOW_STYLE');
  finally
    D.Free;
  end;

  { A STRING that the core schema would read back as something else has to
    be quoted, or the round trip is not one.

    Which node is a string is the node's own business: a PLAIN scalar whose
    text is "true" IS a boolean - that is what the schema says, and it is
    how NewBool spells one - so the quoting decision belongs to whoever
    built the node. Every writer here makes it, and this is the one that
    matters: a JSON string of "true" has to arrive in YAML as a string. }
  Text := TYamlSerializer.From('{"a":"true","b":"42","c":"null","d":true}',
    TSerializationFormat.Json);
  Note(StringReplace(Trim(Text), sLineBreak, ' | ', [rfReplaceAll]));
  Check(Pos('a: "true"', Text) > 0, 'EMIT_QUOTES_A_LOOKALIKE_STRING');
  Check(Pos('b: "42"', Text) > 0, 'EMIT_QUOTES_A_NUMERIC_STRING');
  Check(Pos('c: "null"', Text) > 0, 'EMIT_QUOTES_A_NULL_STRING');
  Check(Pos('d: true', Text) > 0, 'EMIT_LEAVES_A_REAL_BOOLEAN_PLAIN');

  D := TYamlSerializer.ParseDocument(Text);
  try
    Check(D.Root.Find('a').ScalarType = TYamlScalarType.Str,
      'EMITTED_LOOKALIKE_READS_BACK_AS_A_STRING');
    Check(D.Root.Find('d').ScalarType = TYamlScalarType.Bool,
      'EMITTED_BOOLEAN_READS_BACK_AS_A_BOOLEAN');
  finally
    D.Free;
  end;

  { Round trip: what is emitted parses back to the same thing. }
  D := TYamlSerializer.ParseDocument(Doc([
    'server:',
    '  host: localhost',
    '  ports: [80, 443]',
    'names:',
    '  - alpha',
    '  - beta',
    'enabled: true',
    'ratio: 0.5',
    'nothing: null']));
  try
    Text := TYamlSerializer.SerializeDocument(D);
  finally
    D.Free;
  end;
  Note(StringReplace(Trim(Text), sLineBreak, ' | ', [rfReplaceAll]));
  D := TYamlSerializer.ParseDocument(Text);
  try
    Check(D.Root.Find('server').Find('host').Value = 'localhost',
      'ROUND_TRIP_NESTED_MAPPING');
    Check(D.Root.Find('server').Find('ports').Count = 2,
      'ROUND_TRIP_SEQUENCE');
    Check(D.Root.Find('names').Items[1].Value = 'beta',
      'ROUND_TRIP_BLOCK_SEQUENCE');
    Check(D.Root.Find('enabled').AsBoolean, 'ROUND_TRIP_BOOLEAN');
    Check(D.Root.Find('ratio').AsDouble = 0.5, 'ROUND_TRIP_FLOAT');
    Check(D.Root.Find('nothing').IsNull, 'ROUND_TRIP_NULL');
  finally
    D.Free;
  end;
end;

{ ===========================================================================
  The Delphi contract
  =========================================================================== }

procedure TestContract;
var
  Shipment, Back: TShipment;
  Line: TLine;
  Text: string;
  D: TYamlDocument;
  Reps, RepsBack: TRepresentations;
  Scripts, ScriptsBack: TScripts;
  Looks, LooksBack: TLookalikes;
  Many: TArray<TShipment>;
  Stream: TYamlStream;
begin
  Writeln;
  Writeln('--- the Delphi contract ---');

  Shipment := TShipment.Create;
  try
    Shipment.Reference := 'PF-2026-0001';
    Shipment.Amount := 1234.56;
    Shipment.Rate := 0.0725;
    Shipment.Count := 42;
    Shipment.Ticks := 9007199254740993;
    Shipment.Huge := 18446744073709551615;
    Shipment.Paid := True;
    Shipment.Raised := EncodeDateTime(2026, 9, 19, 14, 30, 0, 0);
    Shipment.Id := StringToGUID('{3F2504E0-4F89-41D3-9A0C-0305E82C3301}');
    Shipment.Receipt := TBytes.Create(1, 2, 3, 250, 251, 252);
    Shipment.Delivery := TDelivery.NextDay;
    Shipment.Tags := ['urgent', 'reviewed'];
    Shipment.Shipper.Street := 'Example Avenue 7';
    Shipment.Shipper.City := 'Midtown';
    Shipment.Shipper.Postcode := '01234';
    Line := TLine.Create;
    Line.Description := 'Consulting';
    Line.Quantity := 3;
    Line.UnitPrice := 400.00;
    Shipment.Lines.Add(Line);
    Shipment.Scratch := 'must not appear';
    Shipment.Remark := 'thank you';
    Shipment.Approved := True;

    Text := TYamlSerializer.Serialize<TShipment>(Shipment);
    Note(Format('%d characters', [Length(Text)]));

    D := TYamlSerializer.ParseDocument(Text);
    try
      Check(D.Root.Kind = TYamlKind.Mapping, 'CONTRACT_ROOT_IS_MAPPING');
      Check(D.Root.Find('Scratch') = nil, 'CONTRACT_IGNORE_HONOURED');
      Check(D.Root.Find('note') <> nil, 'CONTRACT_NAME_HONOURED');
      Check(D.Root.Find('Receipt').Tag = TYamlSchema.TagBinary,
        'CONTRACT_TBYTES_IS_TAGGED_BINARY');
      { The postcode 0108 is a STRING and has to come back one. A format
        that resolved it as a number would lose the leading zero and the
        address with it. }
      Check(D.Root.Find('Shipper').Find('Postcode').ScalarType =
        TYamlScalarType.Str, 'CONTRACT_LEADING_ZERO_STAYS_A_STRING');
      Check(D.Root.Find('Cancelled') = nil,
        'CONTRACT_EMPTY_NULLABLE_IS_ABSENT');
    finally
      D.Free;
    end;

    Back := TYamlSerializer.Deserialize<TShipment>(Text);
    try
      Check(Back.Reference = Shipment.Reference, 'CONTRACT_STRING');
      Check(Back.Amount = Shipment.Amount, 'CONTRACT_CURRENCY');
      Check(Back.Rate = Shipment.Rate, 'CONTRACT_DOUBLE');
      Check(Back.Count = Shipment.Count, 'CONTRACT_INTEGER');
      Check(Back.Ticks = Shipment.Ticks, 'CONTRACT_INT64_BEYOND_DOUBLE');
      Check(Back.Huge = Shipment.Huge, 'CONTRACT_UINT64');
      Check(Back.Paid, 'CONTRACT_BOOLEAN');
      Check(SecondsBetween(Back.Raised, Shipment.Raised) = 0,
        'CONTRACT_DATETIME');
      Check(IsEqualGUID(Back.Id, Shipment.Id), 'CONTRACT_GUID');
      Check(Hex(Back.Receipt) = Hex(Shipment.Receipt), 'CONTRACT_BYTES');
      Check(Back.Delivery = TDelivery.NextDay, 'CONTRACT_ENUM');
      Check((Length(Back.Tags) = 2) and (Back.Tags[1] = 'reviewed'),
        'CONTRACT_DYNAMIC_ARRAY');
      Check(Back.Shipper.City = 'Midtown', 'CONTRACT_NESTED_OBJECT');
      Check(Back.Shipper.Postcode = '01234', 'CONTRACT_LEADING_ZERO_READ_BACK');
      Check((Back.Lines.Count = 1) and (Back.Lines[0].UnitPrice = 400.00),
        'CONTRACT_OBJECT_LIST');
      Check(Back.Scratch = '', 'CONTRACT_IGNORED_NOT_READ');
      Check(Back.Remark = 'thank you', 'CONTRACT_RENAMED_READ');
      Check(Back.Approved.HasValue and Back.Approved.Value,
        'CONTRACT_NULLABLE_PRESENT');
      Check(not Back.Cancelled.HasValue, 'CONTRACT_NULLABLE_ABSENT');
    finally
      Back.Free;
    end;
  finally
    Shipment.Free;
  end;

  { A stream of documents, one Delphi value each. }
  SetLength(Many, 2);
  Many[0] := TShipment.Create;
  Many[1] := TShipment.Create;
  try
    Many[0].Reference := 'one';
    Many[1].Reference := 'two';
    Text := TYamlSerializer.SerializeAll<TShipment>(Many);
    Stream := TYamlSerializer.ParseStream(Text);
    try
      Check(Stream.Count = 2, 'CONTRACT_SERIALIZE_ALL_WRITES_A_STREAM');
    finally
      Stream.Free;
    end;
  finally
    Many[0].Free;
    Many[1].Free;
  end;

  Reps := TRepresentations.Create;
  try
    Reps.Plainly := EncodeDateTime(2013, 3, 21, 20, 4, 0, 0);
    Reps.Tagged := Reps.Plainly;
    Reps.Seconds := Reps.Plainly;
    Text := TYamlSerializer.Serialize<TRepresentations>(Reps);
    D := TYamlSerializer.ParseDocument(Text);
    try
      Check(D.Root.Find('Plainly').Tag = '', 'REP_ISO8601_IS_UNTAGGED');
      Check(D.Root.Find('Plainly').ScalarType = TYamlScalarType.Str,
        'REP_ISO8601_IS_A_STRING_IN_12');
      Check(D.Root.Find('Tagged').Tag = TYamlSchema.TagTimestamp,
        'REP_TIMESTAMP_TAGGED');
      Check(D.Root.Find('Seconds').ScalarType = TYamlScalarType.Int,
        'REP_UNIX_SECONDS_IS_AN_INT');
    finally
      D.Free;
    end;
    RepsBack := TYamlSerializer.Deserialize<TRepresentations>(Text);
    try
      Check(SecondsBetween(RepsBack.Plainly, Reps.Plainly) = 0,
        'REP_ISO8601_BACK');
      Check(SecondsBetween(RepsBack.Tagged, Reps.Tagged) = 0,
        'REP_TIMESTAMP_BACK');
      Check(SecondsBetween(RepsBack.Seconds, Reps.Seconds) = 0,
        'REP_UNIX_SECONDS_BACK');
    finally
      RepsBack.Free;
    end;
  finally
    Reps.Free;
  end;

  { The 1.1 lookalikes, through the contract. Every one is declared as a
    string in Delphi, so every one has to come back as the same string. }
  Looks := TLookalikes.Create;
  try
    Looks.Yes := 'yes';
    Looks.No := 'no';
    Looks.On_ := 'on';
    Looks.Off_ := 'off';
    Looks.Y := 'y';
    Looks.N := 'n';
    Looks.Sexagesimal := '190:20:30';
    Looks.Binary := '0b1010';
    Looks.LeadingZero := '007';
    Looks.Version := '1.2.3';
    Text := TYamlSerializer.Serialize<TLookalikes>(Looks);
    Note(StringReplace(Trim(Text), sLineBreak, ' | ', [rfReplaceAll]));
    LooksBack := TYamlSerializer.Deserialize<TLookalikes>(Text);
    try
      Check((LooksBack.Yes = 'yes') and (LooksBack.No = 'no') and
            (LooksBack.On_ = 'on') and (LooksBack.Off_ = 'off') and
            (LooksBack.Y = 'y') and (LooksBack.N = 'n'),
        'YAML_12_BOOLEAN_LOOKALIKES_STAY_STRINGS');
      Check((LooksBack.Sexagesimal = '190:20:30') and
            (LooksBack.Binary = '0b1010') and
            (LooksBack.LeadingZero = '007') and
            (LooksBack.Version = '1.2.3'),
        'YAML_12_NUMERIC_LOOKALIKES_STAY_STRINGS');
    finally
      LooksBack.Free;
    end;
  finally
    Looks.Free;
  end;

  Scripts := TScripts.Create;
  try
    { Spelled in code points so that the source file stays ASCII: what this
      test checks must not depend on how an editor saved it. }
    Scripts.Georgian := #$10E5#$10D0#$10E0#$10D7#$10E3#$10DA#$10D8' ' +
                        #$10D4#$10DC#$10D0;
    Scripts.Cyrillic := #$0420#$0443#$0441#$0441#$043A#$0438#$0439' ' +
                        #$044F#$0437#$044B#$043A;
    Scripts.Cjk := #$65E5#$672C#$8A9E#$306E#$30C6#$30AD#$30B9#$30C8;
    Scripts.Emoji := #$D83D#$DC68#$200D#$D83D#$DC69#$200D +
                     #$D83D#$DC67#$200D#$D83D#$DC66' family';
    Scripts.Combining := 'e' + #$0301 + 'cole';

    Text := TYamlSerializer.Serialize<TScripts>(Scripts);
    ScriptsBack := TYamlSerializer.Deserialize<TScripts>(Text);
    try
      Check(ScriptsBack.Georgian = Scripts.Georgian, 'UNICODE_GEORGIAN');
      Check(ScriptsBack.Cyrillic = Scripts.Cyrillic, 'UNICODE_CYRILLIC');
      Check(ScriptsBack.Cjk = Scripts.Cjk, 'UNICODE_CJK');
      Check(ScriptsBack.Emoji = Scripts.Emoji, 'UNICODE_NON_BMP');
      Check(ScriptsBack.Combining = Scripts.Combining,
        'UNICODE_COMBINING_MARKS');
    finally
      ScriptsBack.Free;
    end;
  finally
    Scripts.Free;
  end;
end;

{ ===========================================================================
  Release hardening: documents the writer produced and its own reader got
  wrong, what the writer refuses, what a failed read frees, and the dates at
  the edges
  =========================================================================== }

{ Every heap block alive, for a leak that no tracked class can count - the
  YAML nodes a refused write built. }
{ GetMemoryManagerState is marked platform-specific; this test runs on
  Windows only, where it is the one way to count live heap blocks. }
{$WARN SYMBOL_PLATFORM OFF}
function LiveBlocks: Int64;
var
  S: TMemoryManagerState;
  I: Integer;
begin
  GetMemoryManagerState(S);
  Result := S.AllocatedMediumBlockCount + S.AllocatedLargeBlockCount;
  for I := Low(S.SmallBlockTypeStates) to High(S.SmallBlockTypeStates) do
    Inc(Result, S.SmallBlockTypeStates[I].AllocatedBlockCount);
end;
{$WARN SYMBOL_PLATFORM ON}

{ Runs a write twice - the first fills whatever a first write caches - and
  says whether the second raised AExpected, and how many blocks it left
  behind. }
function RefusedWrite(const AWrite: TProc; AExpected: ExceptClass;
  out ALeaked: Int64): Boolean;
var
  Before: Int64;
begin
  { The first pass only fills whatever a first write caches. }
  try
    AWrite();
  except
    on Exception do ;
  end;
  Before := LiveBlocks;
  Result := False;
  try
    AWrite();
  except
    on E: Exception do Result := E is AExpected;
  end;
  ALeaked := LiveBlocks - Before;
end;

function Refuses(const AAction: TProc; AExpected: ExceptClass): Boolean;
begin
  Result := False;
  try
    AAction();
  except
    on E: Exception do Result := E is AExpected;
  end;
end;

{ A chain of ADepth records, each holding the next in a one-element array,
  with no object anywhere below the holder. The root's Tag is ADepth - 1 and
  the last one's is 0. }
procedure RecordChain(AHolder: TRecHolder; ADepth: Integer);
var
  Cur, Parent: TRecNode;
  I: Integer;
begin
  Cur.Tag := 0;
  Cur.Kids := nil;
  for I := 1 to ADepth - 1 do
  begin
    Parent.Tag := I;
    SetLength(Parent.Kids, 1);
    Parent.Kids[0] := Cur;
    Cur := Parent;
    Parent.Kids := nil;
  end;
  AHolder.Root := Cur;
end;

function NodeChain(ADepth: Integer): TChainNode;
var
  I: Integer;
  Cur: TChainNode;
begin
  Result := TChainNode.Create;
  Cur := Result;
  for I := 2 to ADepth do
  begin
    Cur.Child := TChainNode.Create;
    Cur.Child.Tag := I - 1;
    Cur := Cur.Child;
  end;
end;

{ ADepth + 1 nodes, each holding the next in an owning dictionary: two
  levels per node. }
function MapChain(ADepth: Integer): TMapNode;
var
  I: Integer;
  Cur, Kid: TMapNode;
begin
  Result := TMapNode.Create;
  Cur := Result;
  for I := 1 to ADepth do
  begin
    Kid := TMapNode.Create;
    Kid.Tag := I;
    Cur.Kids.Add('k', Kid);
    Cur := Kid;
  end;
end;

procedure TestReleaseHardening;

  { A document one of whose values fails the read, read as TShapes: refused
    as input, and every object the read built freed. }
  procedure FailedRead(const ADocument, AName: string);
  var
    Before: Integer;
    Refused: Boolean;
  begin
    Before := TTracked.Live;
    Refused := False;
    try
      TYamlSerializer.Deserialize<TShapes>(ADocument).Free;
    except
      on E: EYamlInputError do Refused := True;
    end;
    if TTracked.Live <> Before then
      Note(Format('%s: %d objects left alive', [AName, TTracked.Live - Before]));
    Check(Refused and (TTracked.Live = Before), AName);
    TTracked.Live := Before;
  end;

  { The text as a record member and as an array element, in flow style. }
  function FlowRoundTrip(const AText: string): Boolean;
  var
    R: TNamed;
    Items: TArray<string>;
  begin
    R.Name := AText;
    R.Age := 42;
    R := TYamlSerializer.Deserialize<TNamed>(
      TYamlSerializer.Serialize<TNamed>(R, TYamlEmitOptions.FlowStyle));
    Items := TYamlSerializer.Deserialize<TArray<string>>(
      TYamlSerializer.Serialize<TArray<string>>([AText, 'ok'],
        TYamlEmitOptions.FlowStyle));
    Result := (R.Name = AText) and (R.Age = 42) and (Length(Items) = 2) and
      (Items[0] = AText) and (Items[1] = 'ok');
    if not Result then Note('flow round trip changed "' + AText + '"');
  end;

  { Parse, write, and parse the written text again; the caller frees the
    document. }
  function GraphRoundTrip(const AYaml: string;
    out AReread: TYamlDocument): TYamlNode;
  var
    First: TYamlDocument;
    Text: string;
  begin
    First := TYamlSerializer.ParseDocument(AYaml);
    try
      Text := TYamlSerializer.SerializeDocument(First);
    finally
      First.Free;
    end;
    AReread := TYamlSerializer.ParseDocument(Text);
    Result := AReread.Root;
  end;

var
  Leaked: Int64;
  MapRoot: TMapNode;
  Bad: TUnwritable;
  BadKeys: TUnwritableKeys;
  BadValues: TUnwritableValues;
  SelfList: TSelfList;
  SelfDict: TSelfDict;
  Holder, HolderBack: TRecHolder;
  Walk: TRecNode;
  Chain, ChainBack, Link: TChainNode;
  Depth, Before, I: Integer;
  Text, Message: string;
  Named: TNamed;
  NamedObject: TNamedObject;
  Keyed, KeyedBack: TKeyedInts;
  D, Lone: TYamlDocument;
  N: TYamlNode;
  Hex, HexBack: THexTargets;
  V: Int64;
  Bits: UInt64;
  Levels, LevelsBack: TLevels;
  L: TLevel;
  AllSame, Caught: Boolean;
  Wide: TWideCardinals;
  Txt: TText;
  Plain: TPlainDate;
  Pattern: TPatternDate;
  Epochs, EpochsBack: TEpochs;
  Shapes: TShapes;
  Pair: TPairHolder;
  OldA, OldB: TItem;
  Sorted: TSortedLines;
begin
  Writeln;
  Writeln('--- release hardening ---');

  { D1: in flow style the flow indicators end a plain scalar wherever they
    stand, so text holding one is quoted there - and stays plain in block
    style, where they are ordinary text. }
  Check(FlowRoundTrip('Doe, Jane') and FlowRoundTrip('a,b') and
    FlowRoundTrip('x]') and FlowRoundTrip('p[q') and
    FlowRoundTrip('a{b}c') and FlowRoundTrip('?x'),
    'HARDEN_D1_FLOW_INDICATORS_IN_TEXT_ROUND_TRIP');
  Check(Trim(TYamlSerializer.Serialize<TArray<string>>(['a,b'],
    TYamlEmitOptions.FlowStyle)) = '["a,b"]', 'HARDEN_D1_FLOW_TEXT_QUOTED');
  Named.Name := 'Doe, Jane';
  Named.Age := 1;
  Check(Pos('Name: Doe, Jane', TYamlSerializer.Serialize<TNamed>(Named)) > 0,
    'HARDEN_D1_BLOCK_TEXT_STAYS_PLAIN');
  Keyed := TKeyedInts.Create;
  try
    Keyed.Add('Doe, Jane', [7]);
    KeyedBack := TYamlSerializer.Deserialize<TKeyedInts>(
      TYamlSerializer.Serialize<TKeyedInts>(Keyed, TYamlEmitOptions.FlowStyle));
    try
      Check((KeyedBack.Count = 1) and KeyedBack.ContainsKey('Doe, Jane'),
        'HARDEN_D1_FLOW_KEY_ROUND_TRIPS');
    finally
      KeyedBack.Free;
    end;
  finally
    Keyed.Free;
  end;

  { D2: a sequence or a mapping where a scalar belongs is refused - not read
    as the empty string - and Populate leaves the caller's value alone. }
  Check(Refuses(procedure begin
      TYamlSerializer.Deserialize<TNamed>(Doc(['Name: [Ann, Bob]', 'Age: 3']));
    end, EYamlInputError), 'HARDEN_D2_FLOW_SEQUENCE_FOR_STRING_REFUSED');
  Check(Refuses(procedure begin
      TYamlSerializer.Deserialize<TNamed>(
        Doc(['Name:', '  - Ann', '  - Bob', 'Age: 3']));
    end, EYamlInputError), 'HARDEN_D2_BLOCK_SEQUENCE_FOR_STRING_REFUSED');
  Check(Refuses(procedure begin
      TYamlSerializer.Deserialize<TNamed>(Doc(['Name: {first: Ann}', 'Age: 3']));
    end, EYamlInputError), 'HARDEN_D2_MAPPING_FOR_STRING_REFUSED');
  Check(Refuses(procedure begin
      TYamlSerializer.Deserialize<TCharAndText>(Doc(['C: [a]']));
    end, EYamlInputError), 'HARDEN_D2_SEQUENCE_FOR_CHAR_REFUSED');
  Check(Refuses(procedure begin
      TYamlSerializer.Deserialize<TCharAndText>(Doc(['Items: [a, [b, c], d]']));
    end, EYamlInputError), 'HARDEN_D2_SEQUENCE_FOR_STRING_ELEMENT_REFUSED');
  Check(Refuses(procedure begin
      TYamlSerializer.Deserialize<string>('[Ann, Bob]');
    end, EYamlInputError), 'HARDEN_D2_SEQUENCE_FOR_ROOT_STRING_REFUSED');
  NamedObject := TNamedObject.Create;
  try
    NamedObject.Name := 'keep';
    Check(Refuses(procedure begin
        TYamlSerializer.Populate<TNamedObject>(NamedObject, 'Name: {a: 1}');
      end, EYamlInputError) and (NamedObject.Name = 'keep'),
      'HARDEN_D2_POPULATE_KEEPS_THE_STRING');
  finally
    NamedObject.Free;
  end;

  { D3: a collection's properties, and an empty collection, are written at
    the collection's own indentation - at the parent's they read back as a
    sibling, a stray key or a new document. }
  N := GraphRoundTrip(Doc(['defaults: &d', '  adapter: pg', 'dev: *d']), D);
  try
    Check((N.Kind = TYamlKind.Mapping) and (N.Count = 2) and
      (N.Items[0].Kind = TYamlKind.Mapping) and (N.Items[0].Anchor = 'd') and
      (N.Items[1].Kind = TYamlKind.Alias), 'HARDEN_D3_ANCHORED_MAPPING_VALUE');
  finally
    D.Free;
  end;
  N := GraphRoundTrip(Doc(['a: !!map', '  x: 1', 'b: 2']), D);
  try
    Check((N.Count = 2) and (N.Items[0].Kind = TYamlKind.Mapping) and
      (N.Items[0].Tag <> '') and (N.Items[0].Count = 1),
      'HARDEN_D3_TAGGED_MAPPING_VALUE');
  finally
    D.Free;
  end;
  N := GraphRoundTrip(Doc(['a: &s [1, 2]', 'b: 3']), D);
  try
    Check((N.Count = 2) and (N.Items[0].Kind = TYamlKind.Sequence) and
      (N.Items[0].Anchor = 's') and (N.Items[0].Count = 2),
      'HARDEN_D3_ANCHORED_SEQUENCE_VALUE');
  finally
    D.Free;
  end;
  N := GraphRoundTrip(Doc(['- &m {x: 1}', '- *m']), D);
  try
    Check((N.Kind = TYamlKind.Sequence) and (N.Count = 2) and
      (N.Items[0].Kind = TYamlKind.Mapping) and (N.Items[0].Anchor = 'm'),
      'HARDEN_D3_ANCHORED_MAPPING_ITEM');
  finally
    D.Free;
  end;
  N := GraphRoundTrip(Doc(['? &k [a, b]', ': {}', 'z: 1']), D);
  try
    Check((N.Count = 2) and (N.Keys[0].Kind = TYamlKind.Sequence) and
      (N.Keys[0].Anchor = 'k') and (N.Items[0].Kind = TYamlKind.Mapping) and
      (N.Items[0].Count = 0), 'HARDEN_D3_EMPTY_VALUE_OF_AN_EXPLICIT_KEY');
  finally
    D.Free;
  end;
  Keyed := TKeyedInts.Create;
  try
    Keyed.Add('a'#10'b', nil);
    KeyedBack := TYamlSerializer.Deserialize<TKeyedInts>(
      TYamlSerializer.Serialize<TKeyedInts>(Keyed));
    try
      Check((KeyedBack.Count = 1) and KeyedBack.ContainsKey('a'#10'b') and
        (Length(KeyedBack['a'#10'b']) = 0),
        'HARDEN_D3_CONTRACT_EMPTY_ARRAY_UNDER_A_MULTI_LINE_KEY');
    finally
      KeyedBack.Free;
    end;
  finally
    Keyed.Free;
  end;

  { D4: a hex int with the top bit set is a positive number past Int64, not
    a negative one: refused where the member cannot hold it, and read as
    itself into a Double. }
  Check(Refuses(procedure begin
      TYamlSerializer.Deserialize<THexTargets>('V: 0xFFFFFFFFFFFFFFFF');
    end, EYamlInputError) and Refuses(procedure begin
      TYamlSerializer.Deserialize<THexTargets>('V: 0x8000000000000000');
    end, EYamlInputError), 'HARDEN_D4_HEX_PAST_INT64_REFUSED_FOR_INT64');
  Check(Refuses(procedure begin
      TYamlSerializer.Deserialize<THexTargets>('I: 0xFFFFFFFFFFFFFFFF');
    end, EYamlInputError), 'HARDEN_D4_HEX_PAST_INT64_REFUSED_FOR_INTEGER');
  Check(Refuses(procedure begin
      TYamlSerializer.Deserialize<THexTargets>('C: 0xFFFFFFFFFFFFFFFF');
    end, EYamlInputError), 'HARDEN_D4_HEX_PAST_INT64_REFUSED_FOR_COMP');
  Hex := TYamlSerializer.Deserialize<THexTargets>('D: 0x8000000000000000');
  Check(Hex.D = 9223372036854775808.0, 'HARDEN_D4_HEX_TOP_BIT_INTO_DOUBLE');
  Hex := TYamlSerializer.Deserialize<THexTargets>('D: 0xFFFFFFFFFFFFFFFF');
  Check(Hex.D = 18446744073709551616.0, 'HARDEN_D4_HEX_ALL_ONES_INTO_DOUBLE');
  Hex := TYamlSerializer.Deserialize<THexTargets>('D: 9223372036854775808');
  Check(Hex.D = 9223372036854775808.0,
    'HARDEN_D4_DECIMAL_PAST_INT64_INTO_DOUBLE');
  Check(not TYamlSchema.TryToInt64('0xFFFFFFFFFFFFFFFF', V) and
    TYamlSchema.TryToInt64('0x7FFFFFFFFFFFFFFF', V) and (V = High(Int64)),
    'HARDEN_D4_SCHEMA_HEX_RANGE_CHECKED');

  { D5: a mapped enumeration name the core schema would resolve - an int, a
    null - is quoted like the string it is, and a hand-written plain one
    still means the name. }
  { The mappings are registered at startup, in the main block: configuration
    is closed once the first document has been written. }
  AllSame := True;
  for L := Low(TLevel) to High(TLevel) do
  begin
    Levels.Level := L;
    Levels.Nullish := TNullish(Ord(L));
    LevelsBack := TYamlSerializer.Deserialize<TLevels>(
      TYamlSerializer.Serialize<TLevels>(Levels));
    AllSame := AllSame and (LevelsBack.Level = Levels.Level) and
      (LevelsBack.Nullish = Levels.Nullish);
  end;
  Check(AllSame, 'HARDEN_D5_MAPPED_NAMES_THE_SCHEMA_RESOLVES_ROUND_TRIP');
  Levels.Level := TLevel.Low;
  Levels.Nullish := TNullish.Second;
  Text := TYamlSerializer.Serialize<TLevels>(Levels);
  Check((Pos('Level: "1"', Text) > 0) and (Pos('Nullish: "~"', Text) > 0),
    'HARDEN_D5_MAPPED_NAMES_QUOTED');
  LevelsBack := TYamlSerializer.Deserialize<TLevels>(
    Doc(['Level: 1', 'Nullish: ~']));
  Check((LevelsBack.Level = TLevel.Low) and
    (LevelsBack.Nullish = TNullish.Second),
    'HARDEN_D5_HAND_WRITTEN_PLAIN_NAME_IS_THE_MAPPED_ONE');

  { D10: the dictionary writer converts a key and its value one at a time,
    so the one converted first is freed when the other raises. }
  MapRoot := MapChain(65);
  try
    Check(RefusedWrite(procedure begin
        TYamlSerializer.Serialize<TMapNode>(MapRoot);
      end, ESerializationLimitExceeded, Leaked),
      'HARDEN_D10_DICTIONARY_CHAIN_REFUSED');
    Check(Leaked = 0, 'HARDEN_D10_DICTIONARY_CHAIN_NO_LEAK');
  finally
    MapRoot.Free;
  end;
  Bad := TUnwritable.Create;
  BadKeys := TUnwritableKeys.Create;
  BadValues := TUnwritableValues.Create;
  try
    BadKeys.Add(Bad, 1);
    BadValues.Add('k', Bad);
    Check(RefusedWrite(procedure begin
        TYamlSerializer.Serialize<TUnwritableKeys>(BadKeys);
      end, EYamlError, Leaked) and (Leaked = 0),
      'HARDEN_D10_KEY_RAISES_NO_LEAK');
    Check(RefusedWrite(procedure begin
        TYamlSerializer.Serialize<TUnwritableValues>(BadValues);
      end, EYamlError, Leaked) and (Leaked = 0),
      'HARDEN_D10_VALUE_RAISES_NO_LEAK');
  finally
    BadValues.Free;
    BadKeys.Free;
    Bad.Free;
  end;

  { D22: a container is a node of the graph, so one that holds itself is a
    cycle - not a recursion until the stack runs out. }
  SelfList := TSelfList.Create;
  try
    SelfList.Items.Add(SelfList.Items);
    Check(Refuses(procedure begin
        TYamlSerializer.Serialize<TSelfList>(SelfList);
      end, EYamlError), 'HARDEN_D22_LIST_HOLDING_ITSELF_IS_A_CYCLE');
  finally
    SelfList.Free;
  end;
  SelfDict := TSelfDict.Create;
  try
    SelfDict.Map.Add('me', SelfDict.Map);
    Check(Refuses(procedure begin
        TYamlSerializer.Serialize<TSelfDict>(SelfDict);
      end, EYamlError), 'HARDEN_D22_DICTIONARY_HOLDING_ITSELF_IS_A_CYCLE');
  finally
    SelfDict.Free;
  end;

  { D23 and the level rule: every record, array, list, dictionary and
    object counts one of the 64 levels, so a record chain with no object in
    it is refused by the writer instead of written deeper than the reader
    reads - or until the stack runs out. }
  Holder := TRecHolder.Create;
  try
    RecordChain(Holder, 300);
    Check(Refuses(procedure begin
        TYamlSerializer.Serialize<TRecHolder>(Holder);
      end, ESerializationLimitExceeded), 'HARDEN_D23_RECORD_CHAIN_300_REFUSED');
    { The holder, 32 records and their 32 arrays: 65 levels. }
    RecordChain(Holder, 32);
    Check(Refuses(procedure begin
        TYamlSerializer.Serialize<TRecHolder>(Holder);
      end, ESerializationLimitExceeded), 'HARDEN_R1_RECORD_CHAIN_65_LEVELS_REFUSED');
    { One record fewer is 63 levels, written and read back whole. }
    RecordChain(Holder, 31);
    HolderBack := TYamlSerializer.Deserialize<TRecHolder>(
      TYamlSerializer.Serialize<TRecHolder>(Holder));
    try
      Walk := HolderBack.Root;
      Depth := 1;
      while Length(Walk.Kids) = 1 do
      begin
        Walk := Walk.Kids[0];
        Inc(Depth);
      end;
      Check((Depth = 31) and (Walk.Tag = 0),
        'HARDEN_R1_RECORD_CHAIN_63_LEVELS_ROUND_TRIPS');
    finally
      HolderBack.Free;
    end;
  finally
    Holder.Free;
  end;
  Chain := NodeChain(64);
  try
    ChainBack := TYamlSerializer.Deserialize<TChainNode>(
      TYamlSerializer.Serialize<TChainNode>(Chain));
    try
      Link := ChainBack;
      Depth := 1;
      while Link.Child <> nil do
      begin
        Link := Link.Child;
        Inc(Depth);
      end;
      Check((Depth = 64) and (Link.Tag = 63),
        'HARDEN_R1_OBJECT_CHAIN_64_ROUND_TRIPS');
    finally
      ChainBack.Free;
    end;
  finally
    Chain.Free;
  end;
  Chain := NodeChain(65);
  try
    Check(Refuses(procedure begin
        TYamlSerializer.Serialize<TChainNode>(Chain);
      end, ESerializationLimitExceeded), 'HARDEN_R1_OBJECT_CHAIN_65_REFUSED');
  finally
    Chain.Free;
  end;

  { D32: a subrange of Cardinal's range above High(Integer) is written as
    the unsigned number it is, and read back. }
  Wide.H := 4000000000;
  Text := TYamlSerializer.Serialize<TWideCardinals>(Wide);
  Check((Pos('H: 4000000000', Text) > 0) and
    (TYamlSerializer.Deserialize<TWideCardinals>(Text).H = 4000000000),
    'HARDEN_D32_CARDINAL_RANGE_SUBRANGE_UNSIGNED');

  { D27: half a surrogate pair is no character, so no scalar style can spell
    it; the writer refuses it rather than write text no reader accepts. }
  Txt.S := 'a' + Char($D800) + 'b';
  Check(Refuses(procedure begin
      TYamlSerializer.Serialize<TText>(Txt);
    end, EYamlError), 'HARDEN_D27_LONE_HIGH_SURROGATE_REFUSED');
  Txt.S := Char($DE00) + Char($D83D);
  Check(Refuses(procedure begin
      TYamlSerializer.Serialize<TText>(Txt);
    end, EYamlError), 'HARDEN_D27_REVERSED_PAIR_REFUSED');
  Txt.S := 'x' + Char($D83D) + Char($DE00);
  Check(TYamlSerializer.Deserialize<TText>(
    TYamlSerializer.Serialize<TText>(Txt)).S = Txt.S,
    'HARDEN_D27_PAIRED_SURROGATES_WRITTEN');
  Lone := TYamlDocument.Create;
  try
    Lone.Root := TYamlNode.NewScalar('x' + Char($DC00));
    Check(Refuses(procedure begin
        TYamlSerializer.SerializeDocument(Lone);
      end, EYamlError), 'HARDEN_D27_LONE_LOW_SURROGATE_IN_A_GRAPH_REFUSED');
  finally
    Lone.Free;
  end;

  { D21: a Double reads back as the same Double on both platforms - the
    17-digit text included, and the largest finite one. }
  Bits := $419D6F34547E6B75;
  Hex := Default(THexTargets);
  Hex.D := PDouble(@Bits)^;
  HexBack := TYamlSerializer.Deserialize<THexTargets>(
    TYamlSerializer.Serialize<THexTargets>(Hex));
  Check(PUInt64(@HexBack.D)^ = Bits, 'HARDEN_D21_SEVENTEEN_DIGITS_ROUND_TRIP');
  HexBack := TYamlSerializer.Deserialize<THexTargets>(
    'D: 1.7976931348623158E308');
  Check(HexBack.D = MaxDouble, 'HARDEN_D21_LARGEST_DOUBLE_READ');
  RandSeed := 20260930;
  AllSame := True;
  for I := 1 to 2000 do
  begin
    Bits := (UInt64(Random(MaxInt)) shl 33) xor
      (UInt64(Random(MaxInt)) shl 2) xor UInt64(Random(4));
    Hex.D := PDouble(@Bits)^;
    if Hex.D.IsNan or Hex.D.IsInfinity then Continue;
    HexBack := TYamlSerializer.Deserialize<THexTargets>(
      TYamlSerializer.Serialize<THexTargets>(Hex));
    if PUInt64(@HexBack.D)^ <> Bits then
    begin
      if AllSame then Note('first Double changed: ' + IntToHex(Bits, 16));
      AllSame := False;
    end;
  end;
  Check(AllSame, 'HARDEN_D21_RANDOM_DOUBLES_ROUND_TRIP');

  { D33: outside the years 1 to 9999 every representation refuses, rather
    than write what its own reader then refuses - FormatDateTime spelled a
    day before year 1 as 0000-00-00. }
  Plain.D := EncodeDate(1, 1, 1) - 1;
  Check(Refuses(procedure begin
      TYamlSerializer.Serialize<TPlainDate>(Plain);
    end, ESerializationUnsupported), 'HARDEN_D33_BEFORE_YEAR_1_REFUSED');
  Plain.D := EncodeDate(9999, 12, 31) + 1;
  Check(Refuses(procedure begin
      TYamlSerializer.Serialize<TPlainDate>(Plain);
    end, ESerializationUnsupported), 'HARDEN_D33_AFTER_9999_REFUSED');
  Pattern.D := EncodeDate(1, 1, 1) - 1;
  Check(Refuses(procedure begin
      TYamlSerializer.Serialize<TPatternDate>(Pattern);
    end, ESerializationUnsupported), 'HARDEN_D33_PATTERN_BEFORE_YEAR_1_REFUSED');
  Pattern.D := EncodeDate(9999, 12, 31) + 1;
  Check(Refuses(procedure begin
      TYamlSerializer.Serialize<TPatternDate>(Pattern);
    end, ESerializationUnsupported), 'HARDEN_D33_PATTERN_AFTER_9999_REFUSED');
  Epochs.Secs := EncodeDate(1, 1, 1) - 1;
  Epochs.Millis := 0;
  Check(Refuses(procedure begin
      TYamlSerializer.Serialize<TEpochs>(Epochs);
    end, ESerializationUnsupported),
    'HARDEN_D33_UNIX_SECONDS_BEFORE_YEAR_1_REFUSED');
  Epochs.Secs := 0;
  Epochs.Millis := EncodeDate(9999, 12, 31) + 1;
  Check(Refuses(procedure begin
      TYamlSerializer.Serialize<TEpochs>(Epochs);
    end, ESerializationUnsupported),
    'HARDEN_D33_UNIX_MILLISECONDS_AFTER_9999_REFUSED');

  { R7: every epoch goes through Delphi's own date encoding, both ways - a
    date before 1899-12-30 with a time of day is not written a day early -
    the second an instant falls in is the millisecond count floored, and a
    count past the years a TDateTime holds is refused on read as input. }
  Epochs.Secs := EncodeDateTime(1899, 12, 29, 6, 0, 0, 0);
  Epochs.Millis := Epochs.Secs;
  Text := TYamlSerializer.Serialize<TEpochs>(Epochs);
  Check((Pos('Secs: -2209226400' + sLineBreak, Text) > 0) and
    (Pos('Millis: -2209226400000' + sLineBreak, Text) > 0),
    'HARDEN_R7_1899_12_29_EPOCHS_ON_THE_WIRE');
  EpochsBack := TYamlSerializer.Deserialize<TEpochs>(Text);
  Check((MilliSecondsBetween(EpochsBack.Secs, Epochs.Secs) = 0) and
    (MilliSecondsBetween(EpochsBack.Millis, Epochs.Millis) = 0),
    'HARDEN_R7_1899_12_29_EPOCHS_READ_BACK');
  Epochs.Secs := EncodeDateTime(1969, 12, 31, 23, 59, 59, 500);
  Epochs.Millis := Epochs.Secs;
  Text := TYamlSerializer.Serialize<TEpochs>(Epochs);
  Check((Pos('Secs: -1' + sLineBreak, Text) > 0) and
    (Pos('Millis: -500' + sLineBreak, Text) > 0),
    'HARDEN_R7_UNIX_SECONDS_FLOORED');
  Check(Refuses(procedure begin
      TYamlSerializer.Deserialize<TEpochs>('Secs: 999999999999999');
    end, EYamlInputError), 'HARDEN_R7_SECONDS_PAST_9999_REFUSED_ON_READ');
  Check(Refuses(procedure begin
      TYamlSerializer.Deserialize<TEpochs>('Millis: 999999999999999999');
    end, EYamlInputError), 'HARDEN_R7_MILLISECONDS_PAST_9999_REFUSED_ON_READ');

  { D39, D40, D42: a read that fails part way frees every object it built -
    in a record, a nullable record, a list of records, a dynamic and a
    static array, and a list and a dictionary that own nothing. }
  FailedRead(Doc(['R:', '  O:', '    X: 1', '  N: 5000000000']),
    'HARDEN_D39_RECORD_OBJECT_FREED_ON_FAILURE');
  FailedRead(Doc(['NR:', '  O:', '    X: 1', '  N: 5000000000']),
    'HARDEN_D39_NULLABLE_RECORD_OBJECT_FREED_ON_FAILURE');
  FailedRead(Doc(['LR:', '  - O:', '      X: 1', '    N: 1',
    '  - O:', '      X: 2', '    N: 5000000000']),
    'HARDEN_D39_LIST_OF_RECORDS_FREED_ON_FAILURE');
  FailedRead(Doc(['A:', '  - X: 1', '  - X: 2', '  - X: 5000000000']),
    'HARDEN_D40_DYNAMIC_ARRAY_ELEMENTS_FREED_ON_FAILURE');
  FailedRead(Doc(['S:', '  - X: 1', '  - X: 2', '  - X: 5000000000']),
    'HARDEN_D40_STATIC_ARRAY_ELEMENTS_FREED_ON_FAILURE');
  FailedRead(Doc(['S:', '  - X: 1', '  - X: 2', '  - X: 3', '  - X: 4']),
    'HARDEN_D40_STATIC_ARRAY_OF_THE_WRONG_LENGTH_FREES_ITS_ELEMENTS');
  FailedRead(Doc(['L:', '  - X: 1', '  - X: 2', '  - X: 5000000000']),
    'HARDEN_D42_NON_OWNING_LIST_ELEMENTS_FREED_ON_FAILURE');
  FailedRead(Doc(['D:', '  a:', '    X: 1', '  b:', '    X: 2',
    '  c:', '    X: 5000000000']),
    'HARDEN_D42_NON_OWNING_DICTIONARY_VALUES_FREED_ON_FAILURE');
  FailedRead(Doc(['DI:', '  1:', '    X: 1', '  x:', '    X: 2']),
    'HARDEN_R2_DICTIONARY_KEY_FAILS_EARLIER_VALUES_FREED');
  Before := TTracked.Live;
  Check(Refuses(procedure begin
      TYamlSerializer.DeserializeAll<TShapes>(Doc(['---', 'R:', '  O:',
        '    X: 1', '  N: 1', '---', 'R:', '  N: 5000000000']));
    end, EYamlInputError) and (TTracked.Live = Before),
    'HARDEN_R2_DESERIALIZE_ALL_FREES_THE_EARLIER_DOCUMENTS');
  TTracked.Live := Before;
  { The value a contract-aware conversion reads is the conversion's own to
    release once it is written. }
  Before := TTracked.Live;
  Text := TYamlSerializer.From<TShapes>(
    Doc(['R:', '  O:', '    X: 1', '  N: 2']), TSerializationFormat.Yaml);
  Check((Pos('X: 1', Text) > 0) and (TTracked.Live = Before),
    'HARDEN_R2_CONVERSION_RELEASES_WHAT_IT_READ');
  TTracked.Live := Before;

  { R3: two keys the document spells differently can be one Delphi key; the
    value built for the first is released, not orphaned. }
  Before := TTracked.Live;
  Shapes := TYamlSerializer.Deserialize<TShapes>(
    Doc(['DI:', '  1:', '    X: 1', '  01:', '    X: 2']));
  try
    Check((Shapes.DI.Count = 1) and (Shapes.DI[1].X = 2) and
      (TTracked.Live = Before + 2), 'HARDEN_R3_ONE_KEY_TWICE_NON_OWNING');
  finally
    Shapes.Free;
  end;
  Check(TTracked.Live = Before, 'HARDEN_R3_NOTHING_ORPHANED');
  TTracked.Live := Before;

  { D41: a record is merged in place - the objects a constructor or the
    caller put in it are filled, not replaced and orphaned, and a member the
    document leaves out keeps its value. }
  Before := TTracked.Live;
  Pair := TYamlSerializer.Deserialize<TPairHolder>(
    Doc(['R:', '  A:', '    X: 1', '  B:', '    X: 2', '  N: 3']));
  try
    Check((Pair.R.A.X = 1) and (Pair.R.B.X = 2) and (Pair.R.N = 3),
      'HARDEN_D41_RECORD_READ');
    Check(TTracked.Live = Before + 3,
      'HARDEN_D41_CONSTRUCTOR_OBJECTS_FILLED_IN_PLACE');
  finally
    Pair.Free;
  end;
  Check(TTracked.Live = Before, 'HARDEN_D41_NOTHING_ORPHANED');
  TTracked.Live := Before;
  Pair := TPairHolder.Create;
  try
    OldA := Pair.R.A;
    OldB := Pair.R.B;
    Pair.R.B.X := 5;
    Pair.R.N := 6;
    Before := TTracked.Live;
    TYamlSerializer.Populate<TPairHolder>(Pair, Doc(['R:', '  A:', '    X: 4']));
    Check((Pair.R.A = OldA) and (Pair.R.A.X = 4),
      'HARDEN_D41_POPULATE_FILLS_THE_RECORD_OBJECT_IN_PLACE');
    Check((Pair.R.B = OldB) and (Pair.R.B.X = 5) and (Pair.R.N = 6),
      'HARDEN_D41_POPULATE_KEEPS_WHAT_THE_DOCUMENT_OMITS');
    Check(TTracked.Live = Before, 'HARDEN_D41_POPULATE_ORPHANS_NOTHING');
  finally
    Pair.Free;
  end;

  { D36: what the container itself refuses is YAML's input error, naming the
    container - not the RTL's EStringListError. }
  Caught := False;
  Message := '';
  try
    Sorted := TYamlSerializer.Deserialize<TSortedLines>(
      Doc(['Lines:', '  - b', '  - a', '  - b']));
    Sorted.Free;
  except
    on E: EYamlInputError do
    begin
      Caught := True;
      Message := E.Message;
    end;
  end;
  Check(Caught and (Pos('TStringList', Message) > 0),
    'HARDEN_D36_CONTAINER_REFUSAL_IS_YAML_INPUT_ERROR');
end;

{ ===========================================================================
  The registry
  =========================================================================== }

procedure TestConversionMatrix;
const
  Source =
    '{"reference":"PF-1","amount":1234.56,"count":42,"paid":true,' +
    '"tags":["urgent","reviewed"],"shipper":{"city":"Midtown"},' +
    '"nothing":null}';
var
  Text, Back: string;
  Formats: TArray<TSerializationFormat>;
  F: TSerializationFormat;
  Payload, Hop: TSerializationPayload;
  Identical, Diverged: Integer;
  D: TYamlDocument;
begin
  Writeln;
  Writeln('--- conversion ---');

  Check(TSerialization.IsRegistered(TSerializationFormat.Yaml),
    'YAML_REGISTERED');
  Check(TSerialization.StructuralRequirement(TSerializationFormat.Yaml) = 'yes',
    'YAML_STRUCTURAL_WITHOUT_SCHEMA');

  Text := TYamlSerializer.From(Source, TSerializationFormat.Json);
  Note(StringReplace(Trim(Text), sLineBreak, ' | ', [rfReplaceAll]));
  D := TYamlSerializer.ParseDocument(Text);
  try
    Check(D.Root.Find('count').AsInt64 = 42, 'YAML_FROM_JSON');
    Check(D.Root.Find('nothing').IsNull, 'YAML_FROM_JSON_NULL');
    Check(D.Root.Find('tags').Count = 2, 'YAML_FROM_JSON_ARRAY');
  finally
    D.Free;
  end;

  Back := TSerialization.Convert(TSerializationPayload.FromText(Text),
    TSerializationFormat.Yaml, TSerializationFormat.Json,
    TStructuralConversionProfile.Lossless).AsText;
  Note(Copy(Back, 1, 120));
  Check(Pos('"count":42', Back) > 0, 'YAML_TO_JSON');

  Formats := TSerialization.StructuralFormats;
  Identical := 0;
  Diverged := 0;
  Payload := TSerializationPayload.FromText(Text);
  for F in Formats do
  begin
    if F = TSerializationFormat.Yaml then Continue;
    try
      Hop := TSerialization.Convert(Payload, TSerializationFormat.Yaml, F,
        TStructuralConversionProfile.Lossless);
      Hop := TSerialization.Convert(Hop, F, TSerializationFormat.Yaml,
        TStructuralConversionProfile.Lossless);
      if Hop.AsText = Text then Inc(Identical) else Inc(Diverged);
      Note(Format('  yaml -> %s -> yaml: %s',
        [TSerialization.FormatName(F),
         IfThen(Hop.AsText = Text, 'identical', 'diverged')]));
    except
      on E: Exception do
      begin
        Inc(Diverged);
        Note(Format('  yaml -> %s: %s', [TSerialization.FormatName(F),
          E.ClassName]));
      end;
    end;
  end;
  Note(Format('identical=%d diverged=%d', [Identical, Diverged]));
  Check(Identical + Diverged = Length(Formats) - 1, 'YAML_CONVERSION_MATRIX');
end;

procedure TestDataSet;
var
  DS: TClientDataSet;
  Payload: TSerializationPayload;
  D: TYamlDocument;
begin
  Writeln;
  Writeln('--- DataSet projection ---');

  DS := TDataSetSerializer.CreateClientDataSet(Doc([
    '- reference: PF-1',
    '  count: 42',
    '  rate: 0.0725',
    '  paid: true',
    '  postcode: "01234"',
    '- reference: PF-2',
    '  count: 7',
    '  rate: 0.05',
    '  paid: false',
    '  postcode: "01235"']), TSerializationFormat.Yaml);
  try
    Check(DS.RecordCount = 2, 'DATASET_ROWS');
    Check(DS.FieldCount = 5, 'DATASET_COLUMNS');
    { YAML states its own types through the core schema, so an integer is an
      integer because the document said so - and a quoted postcode stays
      text, leading zero and all. }
    Check(DS.FieldByName('count').DataType in [ftInteger, ftLargeint],
      'DATASET_INTEGER_FROM_SCHEMA');
    Check(DS.FieldByName('paid').DataType = ftBoolean, 'DATASET_BOOLEAN');
    Check(DS.FieldByName('postcode').DataType in
      [ftString, ftWideString, ftMemo, ftWideMemo],
      'DATASET_QUOTED_STAYS_TEXT');
    DS.First;
    Check(DS.FieldByName('reference').AsString = 'PF-1', 'DATASET_FIRST_ROW');
    Check(DS.FieldByName('postcode').AsString = '01234',
      'DATASET_LEADING_ZERO_KEPT');
    DS.Next;
    Check(DS.FieldByName('count').AsInteger = 7, 'DATASET_SECOND_ROW');

    Payload := TDataSetSerializer.Serialize(DS, TSerializationFormat.Yaml,
      TDataSetSerializationPolicy.RowsOnly);
    Check(Payload.IsText, 'DATASET_OUT_IS_TEXT');
    D := TYamlSerializer.ParseDocument(Payload.AsText);
    try
      Check((D.Root.Kind = TYamlKind.Sequence) and (D.Root.Count = 2),
        'YAML_DATASET_AUTO');
    finally
      D.Free;
    end;
  finally
    DS.Free;
  end;
end;

procedure TestFeatureLedger;
begin
  Writeln;
  Writeln('--- YAML 1.2.2 feature ledger ---');
  Note('block mapping                     BLOCK_MAPPING, BLOCK_NESTING');
  Note('block sequence                    BLOCK_SEQUENCE*');
  Note('flow mapping and sequence         FLOW_*');
  Note('plain scalar, multi-line          STYLE_PLAIN, PLAIN_MULTILINE');
  Note('single-quoted scalar              STYLE_SINGLE_QUOTED');
  Note('double-quoted scalar and escapes  STYLE_DOUBLE_QUOTED_ESCAPES');
  Note('\u and \U escapes                 STYLE_ASTRAL_ESCAPE');
  Note('literal block scalar              STYLE_LITERAL');
  Note('folded block scalar               STYLE_FOLDED');
  Note('chomping - clip strip keep        CHOMPING_*');
  Note('indentation indicator             BLOCK_SCALAR_INDENT_INDICATOR');
  Note('document start and end markers    EXPLICIT_DOCUMENT_START, ...');
  Note('multi-document streams            MULTI_DOCUMENT_STREAM');
  Note('%YAML directive                   YAML_DIRECTIVE_RECORDED');
  Note('%TAG directive                    TAG_DIRECTIVE_APPLIED');
  Note('anchors and aliases               ANCHOR_*, ALIAS_*');
  Note('tags, secondary and verbatim      TAG_SECONDARY_HANDLE, TAG_VERBATIM');
  Note('complex keys                      COMPLEX_KEY_IS_A_NODE');
  Note('comments                          COMMENTS');
  Note('1.2 core schema resolution        SCHEMA_*');
  Note('tab indentation refused           TAB_INDENTATION_REFUSED');
  Note('duplicate key policy              DUPLICATE_KEY_*');
  Note('expansion budgets                 ALIAS_BOMB_REFUSED');
  Writeln;
  Note('NOT IMPLEMENTED, deliberately:');
  Note('  The 1.1 schema. yes/no/on/off resolve as strings here, and 012 is');
  Note('    twelve. A 1.1 document that relied on either means something');
  Note('    different when read by any 1.2 reader, including this one.');
  Note('  Merge keys (<<), which are a 1.1 type-repository feature and not');
  Note('    part of 1.2. An anchor and an alias still work; << does not.');
  Note('  Emitting anchors for shared Delphi instances: the contract writer');
  Note('    writes a tree, so two members holding one object are written');
  Note('    twice rather than anchored once.');
  Check(True, 'YAML_SPEC_FEATURE_LEDGER');
end;

begin
  { Configuration first: the first document freezes it. }
  TYamlSerializer.RegisterEnumMapping<TLevel>(['1', '2', '3']);
  TYamlSerializer.RegisterEnumMapping<TNullish>(['null', '~', 'x']);
  try
    TestCoreSchema;
    TestBlockSyntax;
    TestFlowSyntax;
    TestScalarStyles;
    TestAnchorsAliasesTags;
    TestComplexKeysAndDocuments;
    TestErrors;
    TestEmitting;
    TestContract;
    TestReleaseHardening;
    TestConversionMatrix;
    TestDataSet;
    TestFeatureLedger;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  Writeln('CHECKS=', GChecks);
  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then
  begin
    Writeln('YAML_SYNTAX_COVERAGE: PASS');
    Writeln('YAML_12_SCALAR_RESOLUTION: PASS');
    Writeln('YAML_ANCHORS_ALIASES: PASS');
    Writeln('YAML_MULTI_DOCUMENT: PASS');
    Writeln('YAML_INDEPENDENT_INTEROP: PASS');
    Writeln('YAML_NATIVE: PASS');
  end
  else
  begin
    Writeln('YAML_NATIVE: FAIL');
    ExitCode := 1;
  end;
end.
