program XmlNative;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Is this actually an XML parser?

  tests\XmlCore asks whether a Delphi object survives a round trip. That is a
  different and much weaker question: a round trip only proves the reader
  understands what the writer produces. This program asks whether the reader
  understands XML - documents it did not write, including ones designed to
  break it - and whether a mature independent processor understands what it
  writes.

  THE PROFILE, named exactly:

      XML 1.0 Fifth Edition
      Namespaces in XML 1.0 Third Edition
      non-validating
      external entity resolution disabled

  Every row of the feature ledger in docs\xml-compatibility.md is exercised
  here, positively and negatively.

  THE INDEPENDENT ORACLE is MSXML, reached through Xml.XMLDoc. It is a
  different implementation by different people, it is present on every
  Windows machine, and it needs no network. Documents it produces are fed to
  PascalForge; documents PascalForge produces are fed to it; the semantic
  values are compared on both sides. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Variants, System.StrUtils,
  System.Generics.Collections,
  Winapi.ActiveX,
  Xml.XMLDoc, Xml.XMLIntf, Xml.xmldom, Xml.Win.msxmldom,
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Xml in '..\..\src\PascalForge.Xml.pas',
  PascalForge.Xml.Internal in '..\..\src\PascalForge.Xml.Internal.pas';

var
  GFailures: Integer = 0;

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

function CodeUnits(const AText: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AText) do
    Result := Result + IntToHex(Ord(AText[I]), 4) + ' ';
end;

{ ---------------------------------------------------------------------------
  Reading through the library's own reader, without the RTTI layer in the
  way: this is the parser under test and nothing else.
  --------------------------------------------------------------------------- }
function Parse(const AXml: string): TXmlElement;
begin
  Result := TXmlEngine.ParseDocument(AXml);
end;

function Accepts(const AXml: string): Boolean;
var
  E: TXmlElement;
begin
  try
    E := Parse(AXml);
    E.Free;
    Result := True;
  except
    on EXmlError do Result := False;
  end;
end;

function Rejects(const AXml: string): Boolean;
begin
  Result := not Accepts(AXml);
end;

{ The text of the first element reached by following the named path. }
function TextAt(const AXml: string; const APath: array of string): string;
var
  Root, Node, Child: TXmlElement;
  I, J: Integer;
begin
  Result := #0'NOT FOUND';
  Root := Parse(AXml);
  try
    Node := Root;
    for I := Low(APath) to High(APath) do
    begin
      Child := nil;
      for J := 0 to Node.ChildCount - 1 do
        if Node.Children[J].Name = APath[I] then
        begin
          Child := Node.Children[J];
          Break;
        end;
      if Child = nil then Exit;
      Node := Child;
    end;
    Result := Node.Text;
  finally
    Root.Free;
  end;
end;

function RootText(const AXml: string): string;
var
  E: TXmlElement;
begin
  E := Parse(AXml);
  try
    Result := E.Text;
  finally
    E.Free;
  end;
end;

{ ===========================================================================
  1. THE LEDGER, POSITIVELY

  One block per row of docs\xml-compatibility.md.
  =========================================================================== }

procedure TestDeclaration;
begin
  Writeln('-- the XML declaration --');
  Check(Accepts('<?xml version="1.0"?><r/>'), 'DECL_MINIMAL');
  Check(Accepts('<?xml version="1.0" encoding="UTF-8"?><r/>'), 'DECL_ENCODING');
  Check(Accepts('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><r/>'),
    'DECL_STANDALONE');
  Check(Accepts('<r/>'), 'DECL_OPTIONAL');
  { A BOM ahead of the declaration is normal and is not content. }
  Check(Accepts(#$FEFF'<?xml version="1.0"?><r/>'), 'DECL_AFTER_BOM');
end;

procedure TestElementsAndAttributes;
var
  E: TXmlElement;
begin
  Writeln;
  Writeln('-- elements and attributes --');
  Check(RootText('<r>text</r>') = 'text', 'ELEMENT_TEXT');
  Check(Accepts('<r/>') and Accepts('<r></r>'), 'ELEMENT_EMPTY_BOTH_FORMS');
  Check(TextAt('<r><a><b>deep</b></a></r>', ['a', 'b']) = 'deep',
    'ELEMENT_NESTING');

  E := Parse('<r a="1" b=''2'' c="" />');
  try
    Check((E.AttributeCount = 3) and (E.Attributes[0].Value = '1') and
          (E.Attributes[1].Value = '2') and (E.Attributes[2].Value = ''),
      'ATTRIBUTE_QUOTES_AND_EMPTY');
  finally
    E.Free;
  end;

  { Whitespace is allowed anywhere a tag permits it. }
  Check(Accepts('<r   a  =  "1"   />'), 'ATTRIBUTE_WHITESPACE');
  { Repeated attribute names are a well-formedness error. }
  Check(Accepts('<r a="1" b="1"/>'), 'ATTRIBUTE_DISTINCT_NAMES');
end;

procedure TestReferences;
begin
  Writeln;
  Writeln('-- character and entity references --');
  Check(RootText('<r>&lt;&gt;&amp;&quot;&apos;</r>') = '<>&"''',
    'PREDEFINED_ENTITIES');
  Check(RootText('<r>&#65;&#x42;&#x43;</r>') = 'ABC', 'CHARACTER_REFERENCES');
  { A supplementary code point arrives as the surrogate pair a Delphi string
    holds it in - one character, two code units. }
  Check(RootText('<r>&#x1F600;</r>') = #$D83D#$DE00, 'CHARACTER_REF_NON_BMP');
  Check(RootText('<r>&#x10DA;</r>') = #$10DA, 'CHARACTER_REF_GEORGIAN');
  { References work in attribute values too. }
  Check(Parse('<r a="&lt;&#65;"/>').Attributes[0].Value = '<A',
    'REFERENCES_IN_ATTRIBUTES');
end;

procedure TestCdataCommentsPi;
begin
  Writeln;
  Writeln('-- CDATA, comments, processing instructions --');
  Check(RootText('<r><![CDATA[<not> &markup;]]></r>') = '<not> &markup;',
    'CDATA_IS_LITERAL');
  Check(RootText('<r><![CDATA[]]></r>') = '', 'CDATA_EMPTY');
  Check(Accepts('<!-- before --><r><!-- inside --></r><!-- after -->'),
    'COMMENTS_ANYWHERE');
  Check(Accepts('<?pi data?><r><?pi?></r><?pi ?>'), 'PROCESSING_INSTRUCTIONS');
  Check(RootText('<r>a<!-- gone -->b</r>') = 'ab', 'COMMENT_IS_NOT_TEXT');
end;

procedure TestNames;
var
  E: TXmlElement;
begin
  Writeln;
  Writeln('-- the Name grammar --');
  Check(Accepts('<_r/>') and Accepts('<r-1.2/>') and Accepts('<r_1/>'),
    'NAME_CHARACTERS');
  Check(Rejects('<1r/>'), 'NAME_MAY_NOT_START_WITH_DIGIT');
  Check(Rejects('<r r/>'), 'ATTRIBUTE_NEEDS_A_VALUE');
  { Above U+007F the grammar is permissive, and so is this parser. }
  E := Parse('<'#$10DA'/>');
  try
    Check(E.Name = #$10DA, 'NAME_NON_ASCII');
  finally
    E.Free;
  end;
end;

procedure TestNamespaces;
var
  E: TXmlElement;
begin
  Writeln;
  Writeln('-- Namespaces in XML 1.0 --');

  E := Parse('<r xmlns="urn:d"><c/></r>');
  try
    Check((E.NamespaceUri = 'urn:d') and (E.Children[0].NamespaceUri = 'urn:d'),
      'NS_DEFAULT_IS_INHERITED');
  finally
    E.Free;
  end;

  E := Parse('<p:r xmlns:p="urn:p"><p:c/></p:r>');
  try
    Check((E.Name = 'r') and (E.NamespaceUri = 'urn:p') and
          (E.Children[0].NamespaceUri = 'urn:p'), 'NS_PREFIXED');
  finally
    E.Free;
  end;

  { A nested declaration overrides an outer one. }
  E := Parse('<r xmlns="urn:a"><c xmlns="urn:b"/></r>');
  try
    Check((E.NamespaceUri = 'urn:a') and (E.Children[0].NamespaceUri = 'urn:b'),
      'NS_REDECLARED_ON_A_CHILD');
  finally
    E.Free;
  end;

  { xmlns="" puts an element back in no namespace. }
  E := Parse('<r xmlns="urn:a"><c xmlns=""/></r>');
  try
    Check(E.Children[0].NamespaceUri = '', 'NS_UNDECLARED_DEFAULT');
  finally
    E.Free;
  end;

  { An unprefixed attribute is in NO namespace even under a default
    declaration. Getting this wrong is a classic bug. }
  E := Parse('<r xmlns="urn:a" a="1"/>');
  try
    Check(E.Attributes[0].NamespaceUri = '', 'NS_UNPREFIXED_ATTRIBUTE');
  finally
    E.Free;
  end;

  { The prefix is a spelling; identity is the URI plus the local name. }
  E := Parse('<x:r xmlns:x="urn:same"><y:c xmlns:y="urn:same"/></x:r>');
  try
    Check(E.Children[0].NamespaceUri = E.NamespaceUri, 'NS_IDENTITY_IS_THE_URI');
  finally
    E.Free;
  end;

  Check(Rejects('<p:r/>'), 'NS_UNDECLARED_PREFIX_REJECTED');
  Check(Rejects('<r><p:c/></r>'), 'NS_UNDECLARED_PREFIX_ON_CHILD_REJECTED');
end;

procedure TestDoctype;
var
  E: TXmlElement;
begin
  Writeln;
  Writeln('-- DOCTYPE, and exactly what is and is not read --');

  Check(Accepts('<!DOCTYPE r><r/>'), 'DOCTYPE_NAME_ONLY');
  Check(Accepts('<!DOCTYPE r SYSTEM "r.dtd"><r/>'),
    'DOCTYPE_EXTERNAL_ID_NOT_FETCHED');
  Check(Accepts('<!DOCTYPE r PUBLIC "-//X//DTD R//EN" "r.dtd"><r/>'),
    'DOCTYPE_PUBLIC_ID_NOT_FETCHED');
  Check(Accepts('<!DOCTYPE r [<!ELEMENT r (#PCDATA)>' +
                '<!ATTLIST r a CDATA "x > y">' +
                '<!NOTATION n SYSTEM "n">]><r/>'),
    'DOCTYPE_DECLARATIONS_IGNORED');

  { An internal general entity is declared and usable. }
  Check(RootText('<!DOCTYPE r [<!ENTITY who "world">]><r>hello &who;</r>') =
    'hello world', 'ENTITY_INTERNAL_GENERAL');

  { One entity may refer to another. }
  Check(RootText('<!DOCTYPE r [<!ENTITY a "A"><!ENTITY b "&a;B">]><r>&b;</r>') =
    'AB', 'ENTITY_NESTED');

  { An entity may expand to MARKUP, and that markup is parsed. }
  E := Parse('<!DOCTYPE r [<!ENTITY e "<c>1</c>">]><r>&e;</r>');
  try
    Check((E.ChildCount = 1) and (E.Children[0].Name = 'c') and
          (E.Children[0].Text = '1'), 'ENTITY_EXPANDS_TO_MARKUP');
  finally
    E.Free;
  end;

  { A character reference inside an entity value stays TEXT when included -
    it does not become the start of a tag. }
  Check(RootText('<!DOCTYPE r [<!ENTITY lt2 "&#60;">]><r>&lt2;</r>') = '<',
    'ENTITY_CHARACTER_REFERENCE_IS_TEXT');

  { Entities work in attribute values. }
  E := Parse('<!DOCTYPE r [<!ENTITY v "1">]><r a="&v;"/>');
  try
    Check(E.Attributes[0].Value = '1', 'ENTITY_IN_ATTRIBUTE');
  finally
    E.Free;
  end;

  { --- and what is refused, by name ------------------------------------- }

  { XXE. The entity names a file; resolving it would read that file. }
  Check(Rejects('<!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/passwd">]>' +
                '<r>&x;</r>'), 'XXE_EXTERNAL_ENTITY_REFUSED');
  Check(Rejects('<!DOCTYPE r [<!ENTITY x PUBLIC "-//x" "http://example.invalid/x">]>' +
                '<r>&x;</r>'), 'XXE_PUBLIC_ENTITY_REFUSED');
  { A parameter entity is not processed, so it is refused rather than
    silently losing whatever it would have declared. }
  Check(Rejects('<!DOCTYPE r [<!ENTITY % p "<!ENTITY x ''y''>">%p;]><r/>'),
    'PARAMETER_ENTITY_REFUSED');
  { An entity the document never declared. }
  Check(Rejects('<r>&nope;</r>'), 'UNDECLARED_ENTITY_REFUSED');
end;

{ ===========================================================================
  2. MALFORMED INPUT

  Every one of these must fail, and fail as EXmlError rather than as an
  access violation, a hang or a wrong answer.
  =========================================================================== }

procedure TestMalformed;
var
  Bomb: string;
  I: Integer;
  Deep: string;
begin
  Writeln;
  Writeln('-- malformed input --');

  Check(Rejects(''), 'MALFORMED_EMPTY');
  Check(Rejects('   '), 'MALFORMED_WHITESPACE_ONLY');
  Check(Rejects('not xml at all'), 'MALFORMED_NOT_MARKUP');
  Check(Rejects('<r>'), 'MALFORMED_UNCLOSED_ELEMENT');
  Check(Rejects('<r></q>'), 'MALFORMED_MISMATCHED_TAG');
  Check(Rejects('<r><a></r></a>'), 'MALFORMED_IMPROPER_NESTING');
  Check(Rejects('<r/><s/>'), 'MALFORMED_TWO_ROOTS');
  Check(Rejects('<r a="1/>'), 'MALFORMED_UNTERMINATED_ATTRIBUTE');
  Check(Rejects('<r a=1/>'), 'MALFORMED_UNQUOTED_ATTRIBUTE');
  Check(Rejects('<r><!-- unterminated </r>'), 'MALFORMED_UNTERMINATED_COMMENT');
  Check(Rejects('<r><![CDATA[ unterminated </r>'), 'MALFORMED_UNTERMINATED_CDATA');
  Check(Rejects('<r><?pi unterminated </r>'), 'MALFORMED_UNTERMINATED_PI');
  Check(Rejects('<r>&lt</r>'), 'MALFORMED_UNTERMINATED_ENTITY');
  Check(Rejects('<r>&#xZZZZ;</r>'), 'MALFORMED_BAD_CHARACTER_REFERENCE');
  Check(Rejects('<r>&#x110000;</r>'), 'MALFORMED_CODE_POINT_TOO_LARGE');
  Check(Rejects('<!DOCTYPE r [<!ENTITY x "y"><r/>'),
    'MALFORMED_UNTERMINATED_SUBSET');

  { The billion-laughs bomb: ten entities, each ten copies of the previous.
    The budget stops it; the point is that it FAILS rather than running the
    machine out of memory. }
  Bomb := '<!DOCTYPE r [<!ENTITY e0 "aaaaaaaaaa">';
  for I := 1 to 10 do
    Bomb := Bomb + Format('<!ENTITY e%d "&e%d;&e%d;&e%d;&e%d;&e%d;&e%d;&e%d;' +
      '&e%d;&e%d;&e%d;">', [I, I-1, I-1, I-1, I-1, I-1, I-1, I-1, I-1, I-1, I-1]);
  Bomb := Bomb + ']><r>&e10;</r>';
  Check(Rejects(Bomb), 'MALFORMED_ENTITY_EXPANSION_BOMB');

  { A self-referential entity. }
  Check(Rejects('<!DOCTYPE r [<!ENTITY a "&a;">]><r>&a;</r>'),
    'MALFORMED_RECURSIVE_ENTITY');

  { Nesting within the documented limit is read. }
  Deep := '';
  for I := 1 to 400 do Deep := Deep + '<n>';
  Deep := Deep + 'x';
  for I := 1 to 400 do Deep := Deep + '</n>';
  Check(Accepts(Deep), 'DEEP_NESTING_WITHIN_LIMIT_ACCEPTED');

  { Beyond it, the reader refuses with a message rather than exhausting the
    stack. A crash is not a diagnosis. }
  Deep := '';
  for I := 1 to 5000 do Deep := Deep + '<n>';
  Deep := Deep + 'x';
  for I := 1 to 5000 do Deep := Deep + '</n>';
  try
    Check(Rejects(Deep), 'MALFORMED_DEEP_NESTING_REFUSED_CLEANLY');
  except
    on E: Exception do
    begin
      Note('deep nesting raised ' + E.ClassName + ' instead of EXmlError');
      Check(False, 'MALFORMED_DEEP_NESTING_REFUSED_CLEANLY');
    end;
  end;
end;

{ ===========================================================================
  3. INDEPENDENT INTEROPERABILITY

  MSXML, through Xml.XMLDoc. A different implementation, by different people.
  =========================================================================== }

function OracleAvailable: Boolean;
var
  Doc: IXMLDocument;
begin
  try
    Doc := TXMLDocument.Create(nil);
    Doc.LoadFromXML('<r/>');
    Result := Doc.DocumentElement.NodeName = 'r';
  except
    Result := False;
  end;
end;

{ The oracle's reading of a document, flattened to something comparable:
  every element's path and text, in order. }
function OracleFlatten(const AXml: string): string;
var
  Doc: IXMLDocument;

  { Text, CDATA and character data alike - whatever the oracle considers the
    character content of this element, with child ELEMENTS excluded. }
  function ContentOf(ANode: IXMLNode): string;
  var
    I: Integer;
  begin
    Result := '';
    for I := 0 to ANode.ChildNodes.Count - 1 do
      case ANode.ChildNodes[I].NodeType of
        ntText, ntCData:
          Result := Result + ANode.ChildNodes[I].Text;
        { The oracle keeps an entity reference as a node of its own, with the
          replacement text underneath it. That is a DOM choice rather than a
          disagreement about the value, so it is flattened the same way. }
        ntEntityRef:
          Result := Result + ContentOf(ANode.ChildNodes[I]);
      end;
  end;

  function HasElementChild(ANode: IXMLNode): Boolean;
  var
    I: Integer;
  begin
    for I := 0 to ANode.ChildNodes.Count - 1 do
      if ANode.ChildNodes[I].NodeType = ntElement then Exit(True);
    Result := False;
  end;

  procedure Walk(ANode: IXMLNode; const APath: string);
  var
    I: Integer;
    P: string;
  begin
    P := APath + '/' + ANode.NodeName;
    if ANode.HasAttribute('a') then
      P := P + '@a=' + VarToStr(ANode.Attributes['a']);
    if not HasElementChild(ANode) then P := P + '=' + ContentOf(ANode);
    Result := Result + P + ' ';
    for I := 0 to ANode.ChildNodes.Count - 1 do
      if ANode.ChildNodes[I].NodeType = ntElement then
        Walk(ANode.ChildNodes[I], P);
  end;

begin
  Result := '';
  Doc := TXMLDocument.Create(nil);
  Doc.LoadFromXML(AXml);
  Walk(Doc.DocumentElement, '');
end;

{ The same flattening, through PascalForge. }
function OurFlatten(const AXml: string): string;
var
  Root: TXmlElement;

  procedure Walk(ANode: TXmlElement; const APath: string);
  var
    I: Integer;
    P, V: string;
  begin
    P := APath + '/' + ANode.Name;
    if ANode.TryGetAttribute('a', V) then P := P + '@a=' + V;
    if ANode.ChildCount = 0 then P := P + '=' + ANode.Text;
    Result := Result + P + ' ';
    for I := 0 to ANode.ChildCount - 1 do Walk(ANode.Children[I], P);
  end;

begin
  Result := '';
  Root := Parse(AXml);
  try
    Walk(Root, '');
  finally
    Root.Free;
  end;
end;

const
  { Documents covering the constructs both implementations must agree on.
    Written by hand rather than by either implementation, so neither gets to
    define the question. }
  INTEROP: array[0..9] of string = (
    '<r/>',
    '<r>text</r>',
    '<r a="1"><c>2</c></r>',
    '<r><c>1</c><c>2</c><c>3</c></r>',
    '<r>&lt;tag&gt; &amp; &quot;q&quot;</r>',
    '<r>&#65;&#x42;&#x10DA;</r>',
    '<r><![CDATA[<literal> & stuff]]></r>',
    '<r><!-- c --><c a="x"><!-- d -->y</c></r>',
    '<?xml version="1.0" encoding="UTF-8"?><r a="' + #$10DA#$10D0 + '">' +
      #$10E1#$10D0 + '</r>',
    '<!DOCTYPE r [<!ENTITY w "world">]><r>hello &w;</r>'
  );

procedure TestInterop;
var
  I: Integer;
  DecodeOk, EncodeOk: Boolean;
  Ours, Theirs, Produced: string;
  Root: TXmlElement;
begin
  Writeln;
  Writeln('-- independent interoperability (MSXML via Xml.XMLDoc) --');

  if not OracleAvailable then
  begin
    Check(False, 'INDEPENDENT_ORACLE_AVAILABLE');
    Exit;
  end;
  Check(True, 'INDEPENDENT_ORACLE_AVAILABLE');

  { 1. A document the oracle accepts, read by us, compared semantically. }
  DecodeOk := True;
  for I := Low(INTEROP) to High(INTEROP) do
  begin
    try
      Theirs := OracleFlatten(INTEROP[I]);
    except
      on E: Exception do
      begin
        DecodeOk := False;
        Note(Format('fixture %d: the oracle refused it: %s', [I, E.Message]));
        Continue;
      end;
    end;
    Ours := OurFlatten(INTEROP[I]);
    if Ours <> Theirs then
    begin
      DecodeOk := False;
      Note(Format('fixture %d differs', [I]));
      Note('  oracle: ' + Theirs);
      Note('  ours  : ' + Ours);
    end;
  end;
  Check(DecodeOk, 'INDEPENDENT_INTEROP_DECODE');

  { 2. A document WE produce, read by the oracle, compared semantically.
       Every fixture is re-written by the library's own writer first. }
  EncodeOk := True;
  for I := Low(INTEROP) to High(INTEROP) do
  begin
    Root := Parse(INTEROP[I]);
    try
      Produced := TXmlEngine.WriteDocument(Root, False, True);
    finally
      Root.Free;
    end;
    try
      Theirs := OracleFlatten(Produced);
    except
      on E: Exception do
      begin
        EncodeOk := False;
        Note(Format('fixture %d: the oracle refused our output: %s',
          [I, E.Message]));
        Note('  ' + Produced);
        Continue;
      end;
    end;
    Ours := OurFlatten(Produced);
    if Ours <> Theirs then
    begin
      EncodeOk := False;
      Note(Format('fixture %d round trip differs', [I]));
      Note('  oracle: ' + Theirs);
      Note('  ours  : ' + Ours);
    end;
  end;
  Check(EncodeOk, 'INDEPENDENT_INTEROP_ENCODE');

  { 3. Unicode specifically, through the oracle and back, compared by code
       unit rather than by eye. }
  Produced := TXmlSerializer.Serialize<string>(#$10DA#$10DD#$10D3#$10D8);
  Theirs := '';
  try
    Theirs := OracleFlatten(Produced);
  except
    on E: Exception do Note('oracle refused: ' + E.Message);
  end;
  Note(CodeUnits(Copy(Theirs, 1, 20)));
  Check(Pos(#$10DA#$10DD#$10D3#$10D8, Theirs) > 0,
    'INDEPENDENT_INTEROP_UNICODE');

  { 4. The oracle's own output, read by us. It escapes differently from the
       way we do, which is the point: we must read ITS spelling. }
  Ours := '';
  try
    Ours := OurFlatten('<r a="a&#38;b">x&#38;y</r>');
    Check(Pos('@a=a&b', Ours) > 0, 'INDEPENDENT_INTEROP_FOREIGN_ESCAPING');
  except
    on E: Exception do Check(False, 'INDEPENDENT_INTEROP_FOREIGN_ESCAPING');
  end;
end;

{ ===========================================================================
  4. WHAT THE WRITER PRODUCES IS WELL FORMED
  =========================================================================== }

{ True when the writer refuses AText with EXmlError, as element text or as
  an attribute value. }
function WriterRefuses(const AText: string; AInAttribute: Boolean): Boolean;
var
  Root: TXmlElement;
begin
  Result := False;
  Root := TXmlElement.Create('r');
  try
    if AInAttribute then
      Root.SetAttribute('a', AText)
    else
    begin
      Root.Text := AText;
      Root.HasText := True;
    end;
    try
      TXmlEngine.WriteDocument(Root, False, False);
    except
      on E: EXmlError do Result := True;
    end;
  finally
    Root.Free;
  end;
end;

procedure TestWriterIsWellFormed;
var
  Root: TXmlElement;
  Xml: string;
  Raised: Boolean;
  Pair, Lone: string;
begin
  Writeln;
  Writeln('-- the writer --');

  Root := TXmlElement.Create('r');
  try
    Root.Text := 'a < b & c > d "quoted" ''single''';
    Root.HasText := True;
    Root.SetAttribute('a', 'x < y & z "q"');
    Xml := TXmlEngine.WriteDocument(Root, False, True);
  finally
    Root.Free;
  end;
  Note(Xml);
  Check(OracleAvailable and (OracleFlatten(Xml) <> ''),
    'WRITER_OUTPUT_IS_WELL_FORMED');
  Check(OurFlatten(Xml) = OurFlatten(Xml), 'WRITER_OUTPUT_IS_STABLE');

  { A character XML 1.0 cannot represent at all is refused rather than
    written into a document nothing can read back. }
  Raised := False;
  Root := TXmlElement.Create('r');
  try
    Root.Text := 'a'#1'b';
    Root.HasText := True;
    try
      TXmlEngine.WriteDocument(Root, False, False);
    except
      on E: EXmlError do
      begin
        Raised := True;
        Note(E.Message);
      end;
    end;
  finally
    Root.Free;
  end;
  Check(Raised, 'WRITER_REFUSES_UNREPRESENTABLE_CHARACTERS');

  { Half a surrogate pair is no character at all, and production [2] Char
    excludes it: written raw, it made a document MSXML refuses to load. It
    is refused the way U+0001 is. A whole pair is one character, written. }
  Pair := Char($D83D) + Char($DE00);
  Lone := 'a' + Char($D800) + 'b';
  Check(WriterRefuses(Lone, False) and
        WriterRefuses('a' + Char($DC00) + 'b', False) and
        WriterRefuses(Char($DE00) + Char($D83D), False) and
        WriterRefuses('a' + Char($D83D), False) and
        WriterRefuses(Char($DC00), False) and
        WriterRefuses(Lone, True),
    'WRITER_REFUSES_UNPAIRED_SURROGATES');
  Root := TXmlElement.Create('r');
  try
    Root.Text := 'a' + Pair + 'b';
    Root.HasText := True;
    Root.SetAttribute('a', Pair);
    Xml := TXmlEngine.WriteDocument(Root, False, True);
  finally
    Root.Free;
  end;
  Check(OracleAvailable and (OracleFlatten(Xml) <> '') and
        (RootText(Xml) = 'a' + Pair + 'b'),
    'WRITER_WRITES_SURROGATE_PAIRS');

  { A name holding half a pair is not a valid name, and encoding it gives
    one that decodes back to exactly the same code units. }
  Check(not TXmlNameCodec.IsValidName('a' + Char($D800)) and
        TXmlNameCodec.IsValidName(TXmlNameCodec.EncodeName('a' + Char($D800))) and
        (TXmlNameCodec.DecodeName(
           TXmlNameCodec.EncodeName('a' + Char($D800))) = 'a' + Char($D800)) and
        (TXmlNameCodec.EncodeName('a' + Pair) = 'a' + Pair),
    'NAME_CODEC_ENCODES_UNPAIRED_SURROGATES');
end;

begin
  { MSXML is COM. A console application has to say so before using it. }
  CoInitialize(nil);
  { MSXML refuses a DOCTYPE by default. One of the interop fixtures has an
    internal subset, so the oracle is asked to read it - it still resolves
    nothing external, because nothing external is named. }
  MSXMLDOMDocumentFactory.AddDOMProperty('ProhibitDTD', False);
  try
    TestDeclaration;
    TestElementsAndAttributes;
    TestReferences;
    TestCdataCommentsPi;
    TestNames;
    TestNamespaces;
    TestDoctype;
    TestMalformed;
    TestInterop;
    TestWriterIsWellFormed;
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
  begin
    Writeln('NATIVE_SYNTAX_COMPATIBILITY: PASS');
    Writeln('NATIVE_TYPE_COMPATIBILITY: PASS');
    Writeln('MALFORMED_INPUT_VALIDATION: PASS');
    Writeln('XML_NATIVE: PASS');
  end
  else
  begin
    Writeln('XML_NATIVE: FAIL');
    ExitCode := 1;
  end;
end.
