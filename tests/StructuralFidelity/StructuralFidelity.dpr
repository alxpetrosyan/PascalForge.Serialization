program StructuralFidelity;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ What happens to a document whose SHAPE the destination format cannot take.

  Two different problems, kept apart on purpose, because the right answer to
  each is a different answer:

    A NAME the destination cannot spell.  "$type" is an ordinary JSON member
    name and is not a legal XML element name.  Nothing is lost by encoding
    it, so it is encoded - reversibly, collision-safely, and by default.

    A VALUE KIND the destination does not have.  BSON binary and BSON
    timestamps have no JSON or XML equivalent.  Something IS lost there, so
    the caller chooses: a natural stand-in, metadata that makes it
    reconstructable, or a refusal with the member path.

  What is never on offer is dropping the member.

  The third thing checked here is that a STRING STAYS A STRING.  Text that
  looks like XML, like JSON, like base64 or like a date is not re-examined
  on the way through: the source format said it was a string. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.StrUtils, System.Classes, System.TypInfo, System.Rtti,
  System.Generics.Collections,
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  PascalForge.Xml in '..\..\src\PascalForge.Xml.pas',
  PascalForge.Bson in '..\..\src\PascalForge.Bson.pas',
  PascalForge.Bson.Internal in '..\..\src\PascalForge.Bson.Internal.pas',
  PascalForge.Json.Registration in '..\..\src\PascalForge.Json.Registration.pas',
  PascalForge.Xml.Registration in '..\..\src\PascalForge.Xml.Registration.pas',
  PascalForge.Bson.Registration in '..\..\src\PascalForge.Bson.Registration.pas';

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

function Has(const AText, AFragment: string): Boolean;
begin
  Result := Pos(AFragment, AText) > 0;
end;

function Text(const AJson: string): TSerializationPayload;
begin
  Result := TSerializationPayload.FromText(AJson);
end;

{ ===========================================================================
  1. THE NAME CODEC ITSELF
  =========================================================================== }

procedure TestNameCodec;
const
  { Every one of these is an ordinary member name in some real document. }
  NAMES: array[0..9] of string = (
    '$type', '@odata.context', '1stValue', 'first name', 'foo/bar', 'a:b',
    '', 'XmlMessage', '_x0024_type', '_x005F_x0024_type');
var
  I: Integer;
  Enc: string;
  Seen: TDictionary<string, string>;
  Collision: Boolean;
begin
  Writeln('-- the name codec --');

  Check(TXmlNameCodec.EncodeName('$type') = '_x0024_type', 'XML_NAME_DOLLAR');
  Check(TXmlNameCodec.EncodeName('@odata.context') = '_x0040_odata.context',
    'XML_NAME_AT_SIGN');
  Check(TXmlNameCodec.EncodeName('1stValue') = '_x0031_stValue',
    'XML_NAME_LEADING_DIGIT');
  Check(TXmlNameCodec.EncodeName('first name') = 'first_x0020_name',
    'XML_NAME_SPACE');
  Check(TXmlNameCodec.EncodeName('foo/bar') = 'foo_x002F_bar',
    'XML_NAME_SLASH');
  Check(TXmlNameCodec.EncodeName('a:b') = 'a_x003A_b', 'XML_NAME_COLON');

  { Every encoded form is a name XML will actually accept, and decoding it
    gives back exactly what went in. }
  Collision := False;
  Seen := TDictionary<string, string>.Create;
  try
    for I := Low(NAMES) to High(NAMES) do
    begin
      Enc := TXmlNameCodec.EncodeName(NAMES[I]);
      Note(Format('%-20s -> %s', ['"' + NAMES[I] + '"', Enc]));
      if not TXmlNameCodec.IsValidName(Enc) then
      begin
        Check(False, 'XML_NAME_ENCODING_PRODUCES_VALID_NAME:' + NAMES[I]);
        Collision := True;
      end;
      if TXmlNameCodec.DecodeName(Enc) <> NAMES[I] then
      begin
        Check(False, 'XML_NAME_ENCODING_ROUNDTRIP:' + NAMES[I]);
        Collision := True;
      end;
      if Seen.ContainsKey(Enc) then Collision := True
      else Seen.Add(Enc, NAMES[I]);
    end;
    Check(not Collision, 'XML_NAME_ENCODING_REVERSIBLE');
  finally
    Seen.Free;
  end;

  { The point of escaping the escape. These two source names must not, and
    do not, arrive at the same destination name. }
  Note('$type          -> ' + TXmlNameCodec.EncodeName('$type'));
  Note('_x0024_type    -> ' + TXmlNameCodec.EncodeName('_x0024_type'));
  Check(TXmlNameCodec.EncodeName('$type') <>
        TXmlNameCodec.EncodeName('_x0024_type'),
    'XML_NAME_ENCODING_COLLISION_SAFE');
  Check(TXmlNameCodec.EncodeName('_x0024_type') = '_x005F_x0024_type',
    'XML_NAME_ENCODING_COLLISION');

  { And it survives being applied to its own output, twice. }
  Enc := TXmlNameCodec.EncodeName(TXmlNameCodec.EncodeName(
    TXmlNameCodec.EncodeName('$type')));
  Check(TXmlNameCodec.DecodeName(TXmlNameCodec.DecodeName(
    TXmlNameCodec.DecodeName(Enc))) = '$type',
    'XML_NAME_ENCODING_NESTED');

  { The same name in two places encodes the same way, every time. }
  Check(TXmlNameCodec.EncodeName('a b') = TXmlNameCodec.EncodeName('a b'),
    'XML_NAME_ENCODING_DETERMINISTIC');
end;

{ ===========================================================================
  2. NAMES THROUGH AN ACTUAL CONVERSION
  =========================================================================== }

procedure TestNamesThroughXml;
const
  SRC = '{"$type":"Person","@odata.context":"urn:x","1stValue":10,' +
        '"first name":"Ada","foo/bar":true,"a:b":3.5,' +
        '"_x0024_type":"literal"}';
var
  Xml, Back: TSerializationPayload;
  T: string;
begin
  Writeln;
  Writeln('-- names through JSON -> XML -> JSON --');

  { NATURAL is where XML's name problem is real: a member becomes an element
    NAME, and an element name cannot contain a dollar sign, an at sign, a
    space or a colon, and cannot begin with a digit. The encoding is the one
    .NET's XmlConvert.EncodeName uses, so the result is readable by tooling
    that has never heard of this library, and it escapes itself so a member
    that already looks encoded cannot collide with one that was. }
  Xml := TSerialization.Convert(Text(SRC), TSerializationFormat.Json,
    TSerializationFormat.Xml, TStructuralConversionProfile.Natural);
  Note(Xml.AsText);

  T := Xml.AsText;
  Check(Has(T, '<_x0024_type'), 'XML_MEMBER_DOLLAR_SIGN');
  { An @-prefixed member is XML's attribute idiom under Natural, so it
    becomes an attribute rather than an encoded element name. }
  Check(Has(T, 'odata.context="urn:x"'), 'XML_MEMBER_AT_SIGN');
  Check(Has(T, '<_x0031_stValue'), 'XML_MEMBER_LEADING_DIGIT');
  Check(Has(T, '<first_x0020_name'), 'XML_MEMBER_SPACE');
  Check(Has(T, '<a_x003A_b'), 'XML_MEMBER_COLON');
  Check(Has(T, '<_x005F_x0024_type'), 'XML_MEMBER_LOOKS_ENCODED');

  { LOSSLESS has no name problem at all: the W3C mapping keeps a member name
    in a key attribute, where every one of those characters is ordinary
    text. Nothing is encoded, so nothing has to be decoded, so the round
    trip below is exact by construction rather than by convention. }
  Xml := TSerialization.Convert(Text(SRC), TSerializationFormat.Json,
    TSerializationFormat.Xml, TStructuralConversionProfile.Lossless);
  Note(Xml.AsText);
  T := Xml.AsText;
  Check(Has(T, 'key="$type"') and Has(T, 'key="@odata.context"') and
        Has(T, 'key="1stValue"') and Has(T, 'key="first name"') and
        Has(T, 'key="a:b"') and Has(T, 'key="_x0024_type"'),
    'W3C_KEYS_NEED_NO_ENCODING');

  Back := TSerialization.Convert(Xml, TSerializationFormat.Xml,
    TSerializationFormat.Json, TStructuralConversionProfile.Lossless);
  Note(Back.AsText);
  T := Back.AsText;
  Check(Has(T, '"$type":"Person"') and Has(T, '"@odata.context":"urn:x"') and
        Has(T, '"1stValue":10') and Has(T, '"first name":"Ada"') and
        Has(T, '"foo/bar":true') and Has(T, '"a:b":3.5') and
        Has(T, '"_x0024_type":"literal"'),
    'XML_NAME_ENCODING_ROUNDTRIP');

  { The whole document, member for member, value for value. }
  Check(Back.AsText = TSerialization.Convert(Text(SRC),
    TSerializationFormat.Json, TSerializationFormat.Json).AsText,
    'JSON_XML_JSON_ORIGINAL_MEMBER_NAMES');

  { BSON can spell "$type", so BSON is not asked to encode anything. }
  Back := TSerialization.Convert(
    TSerialization.Convert(Text(SRC), TSerializationFormat.Json,
      TSerializationFormat.Bson),
    TSerializationFormat.Bson, TSerializationFormat.Json);
  Check(Has(Back.AsText, '"$type":"Person"'), 'BSON_KEEPS_ORIGINAL_NAME');
end;

{ ===========================================================================
  3. THE THREE PROFILES ON A NAME
  =========================================================================== }

procedure TestNamePolicies;
const
  SRC = '{"$type":"Person"}';
var
  P: TSerializationPayload;
  Options: TStructuralConversionOptions;
  Caught: EStructuralConversionError;
  E2: EStructuralConversionError;
begin
  Writeln;
  Writeln('-- name policy --');

  P := TSerialization.Convert(Text(SRC), TSerializationFormat.Json,
    TSerializationFormat.Xml, TStructuralConversionProfile.Natural);
  Check(Has(P.AsText, '_x0024_type'), 'STRUCTURAL_INVALID_NAME_NATURAL_ENCODE');

  { Lossless has no name problem to solve: the W3C mapping puts a member
    name in a key ATTRIBUTE, where "$type" is just text, so there is nothing
    to encode and nothing to decode. }
  P := TSerialization.Convert(Text(SRC), TSerializationFormat.Json,
    TSerializationFormat.Xml, TStructuralConversionProfile.Lossless);
  Check(Has(P.AsText, 'key="$type"') and not Has(P.AsText, '_x0024_'),
    'STRUCTURAL_INVALID_NAME_LOSSLESS');

  Caught := nil;
  try
    TSerialization.Convert(Text('{"IndPersonInfo":{"$type":"Person"}}'),
      TSerializationFormat.Json, TSerializationFormat.Xml,
      TStructuralConversionProfile.Strict);
  except
    on E: EStructuralConversionError do
      Caught := EStructuralConversionError(AcquireExceptionObject);
  end;
  try
    Check(Caught <> nil, 'STRUCTURAL_INVALID_NAME_STRICT_ERROR');
    if Caught <> nil then
    begin
      Note(Caught.Message);
      Check((Caught.Path = '$.IndPersonInfo.$type') and
            (Caught.Issue = TStructuralIssue.InvalidDestinationName) and
            (Caught.DestinationFormat = TSerializationFormat.Xml) and
            Caught.SourceFormatKnown and
            (Caught.SourceFormat = TSerializationFormat.Json),
        'STRUCTURAL_ERROR_PATH');
    end;
  finally
    Caught.Free;
  end;

  { The two policies are separate knobs, and a caller may set them
    separately: encode the name, but refuse a value that cannot be kept. }
  Options := TStructuralConversionOptions.Default;
  Options.NamePolicy := TStructuralNamePolicy.Encode;
  Options.ValuePolicy := TStructuralValuePolicy.Error;
  P := TSerialization.Convert(Text(SRC), TSerializationFormat.Json,
    TSerializationFormat.Xml, Options);
  Check(Has(P.AsText, '_x0024_type'), 'STRUCTURAL_POLICIES_ARE_INDEPENDENT');

  { ... and the other way round. }
  Options.NamePolicy := TStructuralNamePolicy.Error;
  Options.ValuePolicy := TStructuralValuePolicy.Natural;
  E2 := nil;
  try
    TSerialization.Convert(Text(SRC), TSerializationFormat.Json,
      TSerializationFormat.Xml, Options);
  except
    on E: EStructuralConversionError do
      E2 := EStructuralConversionError(AcquireExceptionObject);
  end;
  try
    Check(E2 <> nil, 'STRUCTURAL_NAME_POLICY');
  finally
    E2.Free;
  end;
end;

{ ===========================================================================
  4. VALUES THE DESTINATION HAS NO TYPE FOR

  BSON has binary and timestamps; JSON and XML have neither. So a BSON
  document is the fixture, and what JSON and XML do with it is the test.
  =========================================================================== }

function BinaryAndDateBson: TSerializationPayload;
var
  Doc: TBsonValue;
  Bytes: TBytes;
begin
  Bytes := TBytes.Create(1, 2, 3, 250, 255);
  Doc := TBsonValue.NewDocument;
  try
    Doc.Add('Blob', TBsonValue.NewBinary(Bytes));
    Doc.Add('CreatedAt', TBsonValue.NewDateTime(EncodeDate(2026, 3, 14) +
      EncodeTime(9, 26, 53, 120)));
    Doc.Add('Note', TBsonValue.NewString('plain'));
    Result := TSerializationPayload.FromBytes(TBsonEngine.WriteDocument(Doc));
  finally
    Doc.Free;
  end;
end;

procedure TestValuePolicies;
var
  Src, P, Back, Reserved, Composed, ByHand: TSerializationPayload;
  Caught: EStructuralConversionError;
  Route: TStructuralRoute;
  T, Lossless: string;
begin
  Writeln;
  Writeln('-- value policy --');
  Src := BinaryAndDateBson;

  { NATURAL: the destination's own idiom. Base64 for binary, ISO-8601 for a
    timestamp - readable, expected, and not reversible, which is the whole
    reason the other two profiles exist. }
  P := TSerialization.Convert(Src, TSerializationFormat.Bson,
    TSerializationFormat.Json, TStructuralConversionProfile.Natural);
  T := P.AsText;
  Note(T);
  Check(Has(T, '"Blob":"AQID') and Has(T, '"CreatedAt":"2026-03-14T09:26:53'),
    'STRUCTURAL_VALUE_NATURAL');

  { LOSSLESS: MongoDB Extended JSON, which is somebody else's published
    standard for exactly this problem. Not a wrapper of this library's. }
  P := TSerialization.Convert(Src, TSerializationFormat.Bson,
    TSerializationFormat.Json, TStructuralConversionProfile.Lossless);
  Lossless := P.AsText;
  Note(Lossless);
  Check(Has(Lossless, '"$binary"') and Has(Lossless, '"subType":"00"') and
        Has(Lossless, '"$date"') and Has(Lossless, '"$numberLong"'),
    'STRUCTURAL_VALUE_LOSSLESS');
  Check(not Has(Lossless, 'pascalforge') and not Has(Lossless, 'meta:kind'),
    'LOSSLESS_JSON_CARRIES_NO_PRIVATE_METADATA');

  { ... and reading it back gives BSON its native types again. }
  Back := TSerialization.Convert(P, TSerializationFormat.Json,
    TSerializationFormat.Bson, TStructuralConversionProfile.Lossless);
  P := TSerialization.Convert(Back, TSerializationFormat.Bson,
    TSerializationFormat.Json, TStructuralConversionProfile.Lossless);
  Note(P.AsText);
  Check(P.AsText = Lossless, 'STRUCTURAL_LOSSLESS_PROFILE');

  { STRICT: no adaptation at all, and the message says which member. }
  Caught := nil;
  try
    TSerialization.Convert(Src, TSerializationFormat.Bson,
      TSerializationFormat.Json, TStructuralConversionProfile.Strict);
  except
    on E: EStructuralConversionError do
      Caught := EStructuralConversionError(AcquireExceptionObject);
  end;
  try
    Check(Caught <> nil, 'STRUCTURAL_VALUE_STRICT_ERROR');
    if Caught <> nil then
    begin
      Note(Caught.Message);
      Check((Caught.Path = '$.Blob') and
            (Caught.SourceKind = TDynamicKind.Bytes) and
            (Caught.Issue = TStructuralIssue.UnsupportedValueKind),
        'STRUCTURAL_STRICT_PROFILE');
      { The message names both formats, the path, the source kind and the
        reason - the five things a caller needs in order to act. }
      Check(Has(Caught.Message, 'Bson -> Json') and
            Has(Caught.Message, '$.Blob') and
            Has(Caught.Message, 'binary') and Caught.SourceFormatKnown and
            (Caught.SourceFormat = TSerializationFormat.Bson) and
            (Caught.DestinationFormat = TSerializationFormat.Json),
        'STRICT_ERROR_NAMES_EVERYTHING');
    end;
  finally
    Caught.Free;
  end;

  { NO MEMBER NAME IS RESERVED ANY MORE.

    A document is free to contain a member called "$oid", "$meta:kind" or
    anything else. Under Natural nothing looks at member names at all, so
    the document comes back exactly as it went in - through JSON, through
    BSON, and through XML. }
  Reserved := Text('{"$oid":"507f1f77bcf86cd799439011","$meta:kind":"binary",' +
    '"ok":1}');
  P := TSerialization.Convert(Reserved, TSerializationFormat.Json,
    TSerializationFormat.Json, TStructuralConversionProfile.Natural);
  T := P.AsText;
  Note(T);
  Check(Has(T, '"$oid":"507f1f77bcf86cd799439011"') and
        Has(T, '"$meta:kind":"binary"') and not Has(T, '$meta:$meta:'),
    'NO_MEMBER_NAME_IS_ESCAPED');

  Back := TSerialization.Convert(
    TSerialization.Convert(Reserved, TSerializationFormat.Json,
      TSerializationFormat.Bson),
    TSerializationFormat.Bson, TSerializationFormat.Json);
  Note(Back.AsText);
  Check(Back.AsText = T, 'RESERVED_LOOKING_NAMES_SURVIVE_BSON');

  { The same document through the W3C XML mapping, where member names live
    in a key attribute and so need no encoding at all. }
  Back := TSerialization.Convert(
    TSerialization.Convert(Reserved, TSerializationFormat.Json,
      TSerializationFormat.Xml, TStructuralConversionProfile.Lossless),
    TSerializationFormat.Xml, TSerializationFormat.Json,
    TStructuralConversionProfile.Lossless);
  Note(Back.AsText);
  Check(Back.AsText = T, 'RESERVED_LOOKING_NAMES_SURVIVE_W3C_XML');

  { EXTENDED JSON IS ONLY READ AS EXTENDED JSON WHEN IT WAS ASKED FOR.

    Under Natural, an object whose only member is "$oid" is an object whose
    only member is "$oid". Under Lossless it is an ObjectId, and converting
    it to BSON produces the native element. }
  Reserved := Text('{"Id":{"$oid":"507f1f77bcf86cd799439011"}}');
  P := TSerialization.Convert(Reserved, TSerializationFormat.Json,
    TSerializationFormat.Bson, TStructuralConversionProfile.Natural);
  Back := TSerialization.Convert(P, TSerializationFormat.Bson,
    TSerializationFormat.Json, TStructuralConversionProfile.Natural);
  Note(Back.AsText);
  Check(Has(Back.AsText, '{"$oid":"507f1f77bcf86cd799439011"}'),
    'EXTENDED_JSON_NOT_RECOGNIZED_UNDER_NATURAL');

  P := TSerialization.Convert(Reserved, TSerializationFormat.Json,
    TSerializationFormat.Bson, TStructuralConversionProfile.Lossless);
  Back := TSerialization.Convert(P, TSerializationFormat.Bson,
    TSerializationFormat.Json, TStructuralConversionProfile.Natural);
  Note(Back.AsText);
  Check(Has(Back.AsText, '"Id":"507f1f77bcf86cd799439011"'),
    'EXTENDED_JSON_RECOGNIZED_UNDER_LOSSLESS');

  { XML UNDER LOSSLESS IS THE W3C VOCABULARY, and nothing of this library's
    appears in it. }
  P := TSerialization.Convert(Text('{"Id":1,"Active":true,"Tags":[],' +
    '"Rating":null,"Name":"a b"}'), TSerializationFormat.Json,
    TSerializationFormat.Xml, TStructuralConversionProfile.Lossless);
  T := P.AsText;
  Note(T);
  Check(Has(T, 'http://www.w3.org/2005/xpath-functions') and
        Has(T, 'map') and Has(T, 'number') and Has(T, 'boolean') and
        Has(T, 'array') and Has(T, 'null') and Has(T, 'key="Rating"'),
    'W3C_JSON_XML_MAPPING_USED');
  Check(not Has(T, 'pascalforge') and not Has(T, 'urn:pascalforge'),
    'LOSSLESS_XML_CARRIES_NO_PRIVATE_METADATA');

  Back := TSerialization.Convert(P, TSerializationFormat.Xml,
    TSerializationFormat.Json, TStructuralConversionProfile.Lossless);
  Note(Back.AsText);
  Check(Back.AsText = '{"Id":1,"Active":true,"Tags":[],"Rating":null,' +
    '"Name":"a b"}', 'W3C_JSON_XML_ROUND_TRIP');

  { AND WHERE NO STANDARD COVERS THE PAIR DIRECTLY, LOSSLESS SAYS SO.

    BSON binary into XML has no published representation of its own - the
    W3C mapping is a mapping of JSON, and JSON has no binary - so ONE HOP
    refuses and names the route that does work instead of inventing a
    wrapper.

    The options overload is that one hop. It is the primitive: it does
    exactly what it is told, converts once, and never composes. A caller
    who wants a single conversion and a clear answer about whether it is
    possible asks here. }
  Caught := nil;
  try
    TSerialization.Convert(Src, TSerializationFormat.Bson,
      TSerializationFormat.Xml, TStructuralConversionOptions.FromProfile(
        TStructuralConversionProfile.Lossless));
  except
    on E: EStructuralConversionError do
      Caught := EStructuralConversionError(AcquireExceptionObject);
  end;
  try
    Check((Caught <> nil) and
          (Caught.Issue = TStructuralIssue.UnsupportedLosslessConversion),
      'UNSUPPORTED_LOSSLESS_CONVERSION_IS_AN_ERROR');
    if Caught <> nil then Note(Caught.Message);
  finally
    Caught.Free;
  end;

  { ... and the route the message names really does work: BSON to JSON under
    Lossless is Extended JSON, and Extended JSON is ordinary JSON, so the
    W3C mapping carries it exactly. }
  P := TSerialization.Convert(Src, TSerializationFormat.Bson,
    TSerializationFormat.Json, TStructuralConversionProfile.Lossless);
  Back := TSerialization.Convert(
    TSerialization.Convert(P, TSerializationFormat.Json,
      TSerializationFormat.Xml, TStructuralConversionProfile.Lossless),
    TSerializationFormat.Xml, TSerializationFormat.Json,
    TStructuralConversionProfile.Lossless);
  Note(Back.AsText);
  Check(Back.AsText = P.AsText, 'STANDARDS_COMPOSE_BSON_JSON_XML');

  { AND ASKING FOR THE PROFILE COMPOSES IT.

    Naming a profile is asking for an OUTCOME, so the facade is allowed to
    run the two published standards in order to reach it - and it reports
    which ones, because that is the whole basis of the guarantee. What it
    produces has to be exactly what the caller would have got by running
    both hops themselves, or the composition is doing something of its own
    invention rather than the standards. }
  Route := TSerialization.RouteFor(TSerializationFormat.Bson,
    TSerializationFormat.Xml, TStructuralConversionProfile.Lossless);
  Note(Route.Describe);
  Composed := TSerialization.Convert(Src, TSerializationFormat.Bson,
    TSerializationFormat.Xml, TStructuralConversionProfile.Lossless);
  ByHand := TSerialization.Convert(
    TSerialization.Convert(Src, TSerializationFormat.Bson,
      TSerializationFormat.Json, TStructuralConversionOptions.FromProfile(
        TStructuralConversionProfile.Lossless)),
    TSerializationFormat.Json, TSerializationFormat.Xml,
    TStructuralConversionOptions.FromProfile(
      TStructuralConversionProfile.Lossless));
  Check(Route.IsComposed and (Route.HopCount = 2) and
        (Composed.AsText = ByHand.AsText) and (Composed.AsText <> ''),
    'LOSSLESS_FACADE_COMPOSES_THE_STANDARD_ROUTE');

  { And nothing is ever dropped: every member of the source is in every
    rendering, whichever profile produced it. }
  P := TSerialization.Convert(Src, TSerializationFormat.Bson,
    TSerializationFormat.Xml, TStructuralConversionProfile.Natural);
  Check(Has(P.AsText, 'Blob') and Has(P.AsText, 'CreatedAt') and
        Has(P.AsText, 'Note'), 'STRUCTURAL_NOTHING_IS_DROPPED');
end;

{ ===========================================================================
  5. A STRING STAYS A STRING
  =========================================================================== }

procedure TestStringsAreNotReinterpreted;
const
  EMBEDDED_XML =
    '<GetSubjectInfoResponse xmlns="urn:demo"><Ok>true</Ok>' +
    '</GetSubjectInfoResponse>';
var
  Xml, Back: TSerializationPayload;
  Json: string;
  T: string;
begin
  Writeln;
  Writeln('-- a string stays a string --');

  Json := '{"XmlMessage":' + '"' +
    ReplaceStr(ReplaceStr(EMBEDDED_XML, '\', '\\'), '"', '\"') + '",' +
    '"JsonMessage":"{\"a\":1}",' +
    '"Base64Looking":"SGVsbG8=",' +
    '"DateLooking":"2026-03-14",' +
    '"NumberLooking":"0042"}';

  Xml := TSerialization.Convert(Text(Json), TSerializationFormat.Json,
    TSerializationFormat.Xml);
  T := Xml.AsText;
  Note(T);

  { The embedded document is ESCAPED, not parsed. If it had been parsed there
    would be a real <Ok> element in the output. }
  Check(Has(T, '&lt;GetSubjectInfoResponse') and not Has(T, '<Ok>'),
    'EMBEDDED_XML_STRING_PRESERVED');

  Back := TSerialization.Convert(Xml, TSerializationFormat.Xml,
    TSerializationFormat.Json);
  T := Back.AsText;
  Note(T);
  Check(Has(T, '\"a\":1') or Has(T, '{\"a\":1}'),
    'EMBEDDED_JSON_STRING_PRESERVED');

  { None of these became a number, a date or a byte array on the way. }
  Check(Has(T, '"Base64Looking":"SGVsbG8="') and
        Has(T, '"DateLooking":"2026-03-14"') and
        Has(T, '"NumberLooking":"0042"'),
    'STRING_NOT_AUTO_REINTERPRETED');

  { Not even through BSON, which HAS a binary type and a timestamp type and
    would have been the tempting place to guess. }
  Back := TSerialization.Convert(
    TSerialization.Convert(Text(Json), TSerializationFormat.Json,
      TSerializationFormat.Bson),
    TSerializationFormat.Bson, TSerializationFormat.Json);
  Check(Has(Back.AsText, '"DateLooking":"2026-03-14"') and
        Has(Back.AsText, '"Base64Looking":"SGVsbG8="'),
    'STRING_NOT_AUTO_REINTERPRETED_VIA_BSON');
end;

{ ===========================================================================
  6. A REALISTIC DOCUMENT

  Neutral names, but the same structural characteristics as the real thing
  this came from: nested objects, "$type" discriminators, Georgian text,
  nulls, empty arrays, an embedded XML document as a string, dates carried
  as strings, and a nested details object.
  =========================================================================== }

const
  { Georgian: "lali jishkariani". Written as code points so that the test does
    not depend on how this file was saved. }
  GEO_NAME = #$10DA#$10DD#$10D3#$10D8' '#$10EF#$10D8#$10E8#$10D9#$10D0 +
             #$10E0#$10D8#$10D0#$10DC#$10D8;
  { Georgian: "sakartvelo" }
  GEO_COUNTRY = #$10E1#$10D0#$10E5#$10D0#$10E0#$10D7#$10D5#$10D4#$10DA#$10DD;
  { Georgian: "individualuri metsarme" }
  GEO_FORM = #$10D8#$10DC#$10D3#$10D8#$10D5#$10D8#$10D3#$10E3#$10D0#$10DA +
             #$10E3#$10E0#$10D8' '#$10DB#$10D4#$10EC#$10D0#$10E0#$10DB#$10D4;
  { Georgian: "motsmoba" }
  GEO_DOC = #$10DB#$10DD#$10EC#$10DB#$10DD#$10D1#$10D0;

function RealisticFixture: string;
begin
  Result :=
    '{"Subject":{' +
      '"$type":"IndSubject",' +
      '"PersonInfo":{' +
        '"$type":"IndPersonInfo",' +
        '"Name":"' + GEO_NAME + '",' +
        '"Country":"' + GEO_COUNTRY + '",' +
        '"Form":"' + GEO_FORM + '",' +
        '"Document":"' + GEO_DOC + '",' +
        '"BirthDate":"1974-05-06",' +
        '"Rating":null},' +
      '"ClientFields":{' +
        '"$type":"ClientFields",' +
        '"1stValue":10,' +
        '"first name":"' + GEO_NAME + '",' +
        '"foo/bar":true,' +
        '"a:b":3.5},' +
      '"RelatedPersons":[],' +
      '"Documents":[{"Kind":"' + GEO_DOC + '","No":"AA-1"},' +
                   '{"Kind":"' + GEO_DOC + '","No":"AA-2"}],' +
      '"XmlMessage":"<GetSubjectInfoResponse xmlns=\"urn:demo\">' +
        '<Ok>true</Ok></GetSubjectInfoResponse>",' +
      '"Score":1234,' +
      '"Active":true,' +
      '"Missing":null}}';
end;

procedure TestRealisticRoundTrip;
var
  Src, Canon, Xml, Back: TSerializationPayload;
  T: string;
begin
  Writeln;
  Writeln('-- a realistic document, JSON -> XML -> JSON --');
  Src := Text(RealisticFixture);

  { The canonical rendering of the source: the same renderer, so any
    difference below is a difference in the DOCUMENT, not in formatting. }
  Canon := TSerialization.Convert(Src, TSerializationFormat.Json,
    TSerializationFormat.Json);

  Xml := TSerialization.Convert(Src, TSerializationFormat.Json,
    TSerializationFormat.Xml, TStructuralConversionProfile.Lossless);
  Back := TSerialization.Convert(Xml, TSerializationFormat.Xml,
    TSerializationFormat.Json, TStructuralConversionProfile.Lossless);
  T := Back.AsText;

  Check(Has(T, '"$type":"IndSubject"') and Has(T, '"$type":"IndPersonInfo"') and
        Has(T, '"1stValue"') and Has(T, '"first name"') and
        Has(T, '"foo/bar"') and Has(T, '"a:b"'),
    'JSON_XML_JSON_MEMBER_NAMES');
  Check(Has(T, '"Name":"' + GEO_NAME + '"') and
        Has(T, '"Country":"' + GEO_COUNTRY + '"') and
        Has(T, '"Form":"' + GEO_FORM + '"') and
        Has(T, '"Document":"' + GEO_DOC + '"'),
    'JSON_XML_JSON_GEORGIAN_VALUES');
  Check(Has(T, '"No":"AA-1"') and Has(T, '"No":"AA-2"') and
        Has(T, '"Score":1234') and Has(T, '"Active":true'),
    'JSON_XML_JSON_NESTED_VALUES');
  { The embedded document came back as the string it always was - escaped
    inside the XML, unescaped again on the way out, never parsed. }
  Check(Has(T, '"XmlMessage":"<GetSubjectInfoResponse xmlns=\"urn:demo\">'),
    'JSON_XML_JSON_EMBEDDED_XML_STRING');
  Check(Has(T, '"RelatedPersons":[]'), 'JSON_XML_JSON_EMPTY_ARRAYS');
  Check(Has(T, '"Rating":null') and Has(T, '"Missing":null'),
    'JSON_XML_JSON_NULLS');

  { Lossless means lossless: the whole document, exactly. }
  if T <> Canon.AsText then
  begin
    Note('canonical: ' + Copy(Canon.AsText, 1, 400));
    Note('round:     ' + Copy(T, 1, 400));
  end;
  Check(T = Canon.AsText, 'JSON_XML_JSON_REALISTIC_STRUCTURE');

  { The Natural profile keeps every member and every character of text. What
    it does not keep is the difference between 1234 and "1234", the
    difference between an empty list and an empty element, or the original
    spelling of a name XML cannot hold - and the last of those is the one
    worth being precise about.

    "$type" goes out as <_x0024_type>, the XmlConvert.EncodeName spelling.
    It does NOT come back as "$type", because the reader is looking at
    somebody else's XML and an element genuinely called <_x0041_> is a
    member called "_x0041_", not a member called "A". Decoding is available
    and explicit - TXmlNameCodec.DecodeName - for a caller who knows the
    document came from this convention. }
  Xml := TSerialization.Convert(Src, TSerializationFormat.Json,
    TSerializationFormat.Xml, TStructuralConversionProfile.Natural);
  Back := TSerialization.Convert(Xml, TSerializationFormat.Xml,
    TSerializationFormat.Json);
  T := Back.AsText;
  Check(Has(T, '"_x0024_type":"IndSubject"') and
        Has(T, '"Name":"' + GEO_NAME + '"') and
        Has(T, '"Rating":null'),
    'JSON_XML_JSON_NATURAL_KEEPS_NAMES_AND_TEXT');
  Check(TXmlNameCodec.DecodeName('_x0024_type') = '$type',
    'XML_NAME_DECODING_IS_EXPLICIT_AND_AVAILABLE');
  Check(Has(T, '"Score":"1234"'), 'JSON_XML_JSON_NATURAL_SCALARS_ARE_TEXT');
end;

{ ===========================================================================
  7. CAPABILITIES

  Registered and able are different questions, and a caller who asked for
  structural work on a format that has no structural parser must be told
  that, not told the format is missing.
  =========================================================================== }

type
  { A handler that is properly registered and deliberately cannot parse. }
  TSchemaBoundHandler = class(TSerializationFormatHandler)
  public
    function Capabilities(const AOptions: TStructuralConversionOptions):
      TSerializationFormatCapabilities; override;
    function PayloadKind: TSerializationPayloadKind; override;
    function ToDynamic(const APayload: TSerializationPayload;
      const AOptions: TStructuralConversionOptions): TDynamicValue; override;
    function FromDynamic(const AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions): TSerializationPayload; override;
    function DeserializeTyped(ATypeInfo: PTypeInfo;
      const APayload: TSerializationPayload): TValue; override;
    function SerializeTyped(ATypeInfo: PTypeInfo;
      const AValue: TValue): TSerializationPayload; override;
  end;

function TSchemaBoundHandler.Capabilities(
  const AOptions: TStructuralConversionOptions): TSerializationFormatCapabilities;
begin
  Result := [TSerializationFormatCapability.ContractSerialize,
             TSerializationFormatCapability.ContractDeserialize];
end;

function TSchemaBoundHandler.PayloadKind: TSerializationPayloadKind;
begin
  Result := TSerializationPayloadKind.Binary;
end;

function TSchemaBoundHandler.ToDynamic(
  const APayload: TSerializationPayload;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
begin
  Result := nil;
end;

function TSchemaBoundHandler.FromDynamic(const AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
begin
  Result := TSerializationPayload.FromBytes(nil);
end;

function TSchemaBoundHandler.DeserializeTyped(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload): TValue;
begin
  Result := TValue.Empty;
end;

function TSchemaBoundHandler.SerializeTyped(ATypeInfo: PTypeInfo;
  const AValue: TValue): TSerializationPayload;
begin
  Result := TSerializationPayload.FromBytes(nil);
end;

procedure TestCapabilities;
var
  Raised: string;
begin
  Writeln;
  Writeln('-- capabilities --');

  Check(TSerialization.Supports(TSerializationFormat.Json,
          TSerializationFormatCapability.StructuralParse) and
        TSerialization.Supports(TSerializationFormat.Xml,
          TSerializationFormatCapability.StructuralParse) and
        TSerialization.Supports(TSerializationFormat.Bson,
          TSerializationFormatCapability.StructuralParse),
    'STRUCTURAL_CAPABILITY_REPORTED');

  Check(Length(TSerialization.StructuralFormats) = 3,
    'STRUCTURAL_FORMATS_DISCOVERABLE');

  { An unregistered format is a different failure from a registered one that
    cannot do the job, and they get different exceptions. }
  Raised := '';
  try
    TSerialization.Convert(Text('{"a":1}'), TSerializationFormat.Json,
      TSerializationFormat.Protobuf);
  except
    on E: Exception do Raised := E.ClassName;
  end;
  Check(Raised = 'ESerializationFormatNotRegistered',
    'UNREGISTERED_IS_NOT_A_CAPABILITY_ERROR');

  TSerializationFormats.Register(TSerializationFormat.Protobuf,
    TSchemaBoundHandler);
  try
    Check(not TSerialization.Supports(TSerializationFormat.Protobuf,
      TSerializationFormatCapability.StructuralParse),
      'REGISTERED_WITHOUT_STRUCTURAL_PARSE');
    Check(Length(TSerialization.StructuralFormats) = 3,
      'STRUCTURAL_FORMATS_EXCLUDES_IT');

    Raised := '';
    try
      TSerialization.Convert(TSerializationPayload.FromBytes(TBytes.Create(1)),
        TSerializationFormat.Protobuf, TSerializationFormat.Json);
    except
      on E: Exception do Raised := E.ClassName + '|' + E.Message;
    end;
    Note(Raised);
    Check(StartsStr('ESerializationFormatCapability', Raised),
      'CAPABILITY_ERROR_IS_ITS_OWN_EXCEPTION');
  finally
    TSerializationFormats.Unregister(TSerializationFormat.Protobuf);
  end;
end;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TJsonSerializationRegistration.RegisterFormat;
  TXmlSerializationRegistration.RegisterFormat;
  TBsonSerializationRegistration.RegisterFormat;
  try
    TestNameCodec;
    TestNamesThroughXml;
    TestNamePolicies;
    TestValuePolicies;
    TestStringsAreNotReinterpreted;
    TestRealisticRoundTrip;
    TestCapabilities;
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
    Writeln('STRUCTURAL_FIDELITY: PASS')
  else
  begin
    Writeln('STRUCTURAL_FIDELITY: FAIL');
    ExitCode := 1;
  end;
end.
