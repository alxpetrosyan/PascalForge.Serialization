program LosslessRouting;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ HOW A LOSSLESS CONVERSION WAS ACHIEVED.

  There is no published BSON/XML mapping. There are two published mappings
  that meet in the middle -

      BSON  -> MongoDB Extended JSON ->  JSON
      JSON  -> W3C JSON/XML          ->  XML

  - so asking for BSON into XML under Lossless composes them. That is a
  convenience for the caller, and conveniences that happen invisibly are how
  data quietly changes meaning, so this program is about the two things that
  keep it honest:

    the route is a TABLE and not a search, so it is the same every time and
    can be predicted before anything is converted;

    and the route can be READ, both before the conversion (RouteFor) and
    after it (the Convert overload that reports one), naming every standard
    the document actually passed through.

  A caller who asked for Lossless is entitled to know which standards their
  data went through, because that is the entire basis of the guarantee. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes,
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  AllFormatsRegistered in '..\Shared\AllFormatsRegistered.pas';

var
  GFailures: Integer = 0;

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

const
  EXTENDED_JSON = 'MongoDB Extended JSON';
  W3C_JSON_XML  = 'W3C JSON/XML';

{ ===========================================================================
  THE DOCUMENT

  Extended JSON, because that is the text form of a BSON document and it is
  how this test says what the BSON should contain without hand-assembling
  bytes. It carries the BSON types that have no JSON spelling of their own -
  an ObjectId, an instant, a 64-bit integer, a binary - beside the ordinary
  values, because those are what a route either preserves or loses.
  =========================================================================== }

function ExtendedJsonDocument: string;
begin
  Result :=
    '{' +
    '"_id":{"$oid":"64b7f3c2a1d4e5f601234567"},' +
    '"Name":"Midtown",' +
    '"Count":{"$numberLong":"4611686018427387903"},' +
    '"When":{"$date":"2026-09-22T14:35:00Z"},' +
    '"Blob":{"$binary":{"base64":"AQIDBA==","subType":"00"}},' +
    '"Rate":1.5,' +
    '"Active":true,' +
    '"Rating":null,' +
    '"Tags":[1,2,3],' +
    '"Nested":{"City":"Midtown","Zip":"1234"}' +
    '}';
end;

{ The document as BSON bytes: JSON into BSON under Lossless is the Extended
  JSON reader, which is the standard this test is built on. }
function BsonDocument: TSerializationPayload;
begin
  Result := TSerialization.Convert(
    TSerializationPayload.FromText(ExtendedJsonDocument),
    TSerializationFormat.Json, TSerializationFormat.Bson,
    TStructuralConversionProfile.Lossless);
end;

{ And back out again, so that two BSON documents can be compared as text. }
function AsExtendedJson(const APayload: TSerializationPayload): string;
begin
  Result := TSerialization.Convert(APayload,
    TSerializationFormat.Bson, TSerializationFormat.Json,
    TStructuralConversionProfile.Lossless).AsText;
end;

{ Lossless, built from the profile, for the hops this test runs by hand. }
function LosslessOptions: TStructuralConversionOptions;
begin
  Result := TStructuralConversionOptions.FromProfile(
    TStructuralConversionProfile.Lossless);
end;

{ ===========================================================================
  WHAT THE TABLE SAYS
  =========================================================================== }

function IsComposedVia(const ARoute: TStructuralRoute;
  AFrom, AHub, ATo: TSerializationFormat;
  const AFirst, ASecond: string): Boolean;
begin
  Result := (ARoute.HopCount = 2) and ARoute.IsComposed and
    (ARoute.Steps[0].FromFormat = AFrom) and
    (ARoute.Steps[0].ToFormat = AHub) and
    (ARoute.Steps[0].Standard = AFirst) and
    (ARoute.Steps[1].FromFormat = AHub) and
    (ARoute.Steps[1].ToFormat = ATo) and
    (ARoute.Steps[1].Standard = ASecond);
end;

procedure TestBsonToXmlRoute;
var
  Route, Taken: TStructuralRoute;
  Xml, Back: TSerializationPayload;
  Before, After: string;
  Composed: Boolean;
begin
  Writeln;
  Writeln('-- BSON into XML --');

  Route := TSerialization.RouteFor(TSerializationFormat.Bson,
    TSerializationFormat.Xml, TStructuralConversionProfile.Lossless);
  Note('route: ' + Route.Describe);

  Composed := IsComposedVia(Route, TSerializationFormat.Bson,
    TSerializationFormat.Json, TSerializationFormat.Xml,
    EXTENDED_JSON, W3C_JSON_XML);

  { And the conversion itself, reporting the route it actually took, which
    must be the one that was predicted. A resolver that answered one thing
    and did another would be worse than no resolver. }
  Before := AsExtendedJson(BsonDocument);
  Xml := TSerialization.Convert(BsonDocument,
    TSerializationFormat.Bson, TSerializationFormat.Xml,
    TStructuralConversionProfile.Lossless, Taken);

  Note('taken: ' + Taken.Describe);
  Note('xml  : ' + Copy(Xml.AsText, 1, 200));

  Check(Composed and (Taken.Describe = Route.Describe) and (Xml.AsText <> ''),
    'LOSSLESS_BSON_XML_STANDARD_ROUTE');

  { The whole point of the route: what went in comes out. The BSON-only
    types travel through XML as the Extended JSON objects the first standard
    made of them, and the second half of the journey turns them back. }
  Back := TSerialization.Convert(Xml,
    TSerializationFormat.Xml, TSerializationFormat.Bson,
    TStructuralConversionProfile.Lossless);
  After := AsExtendedJson(Back);

  if Before <> After then
  begin
    Note('before: ' + Before);
    Note('after : ' + After);
  end;
  Check(Before = After, 'LOSSLESS_BSON_XML_BSON_PRESERVES_DOCUMENT');
end;

procedure TestXmlToBsonRoute;
var
  Route, Taken: TStructuralRoute;
  Xml, Bson: TSerializationPayload;
  Composed: Boolean;
begin
  Writeln;
  Writeln('-- XML into BSON --');

  Route := TSerialization.RouteFor(TSerializationFormat.Xml,
    TSerializationFormat.Bson, TStructuralConversionProfile.Lossless);
  Note('route: ' + Route.Describe);

  Composed := IsComposedVia(Route, TSerializationFormat.Xml,
    TSerializationFormat.Json, TSerializationFormat.Bson,
    W3C_JSON_XML, EXTENDED_JSON);

  Xml := TSerialization.Convert(BsonDocument,
    TSerializationFormat.Bson, TSerializationFormat.Xml,
    TStructuralConversionProfile.Lossless);

  Bson := TSerialization.Convert(Xml,
    TSerializationFormat.Xml, TSerializationFormat.Bson,
    TStructuralConversionProfile.Lossless, Taken);

  Note('taken: ' + Taken.Describe);
  Check(Composed and (Taken.Describe = Route.Describe) and
    (Length(Bson.AsBytes) > 0), 'LOSSLESS_XML_BSON_STANDARD_ROUTE');
end;

{ ===========================================================================
  DETERMINISM

  A table gives the same answer every time and does not consult the
  document. A search would not necessarily do either.
  =========================================================================== }

procedure TestDeterminism;
var
  I: Integer;
  First, Again: TStructuralRoute;
  Same: Boolean;
  Natural, Strict, Reported: TStructuralRoute;
  Small, Large: TSerializationPayload;
  RouteSmall, RouteLarge: TStructuralRoute;
begin
  Writeln;
  Writeln('-- the same answer every time --');

  First := TSerialization.RouteFor(TSerializationFormat.Bson,
    TSerializationFormat.Xml, TStructuralConversionProfile.Lossless);
  Same := True;
  for I := 1 to 100 do
  begin
    Again := TSerialization.RouteFor(TSerializationFormat.Bson,
      TSerializationFormat.Xml, TStructuralConversionProfile.Lossless);
    if Again.Describe <> First.Describe then Same := False;
  end;
  Check(Same, 'ROUTE_REPEATS_IDENTICALLY');

  { And it does not depend on the payload, which is the other half of being
    predictable: the caller can read the route out of the source before they
    have any data at all. }
  Small := TSerialization.Convert(
    TSerializationPayload.FromText('{"A":1}'),
    TSerializationFormat.Json, TSerializationFormat.Bson,
    TStructuralConversionProfile.Lossless);
  Large := BsonDocument;
  TSerialization.Convert(Small, TSerializationFormat.Bson,
    TSerializationFormat.Xml, TStructuralConversionProfile.Lossless,
    RouteSmall);
  TSerialization.Convert(Large, TSerializationFormat.Bson,
    TSerializationFormat.Xml, TStructuralConversionProfile.Lossless,
    RouteLarge);
  Check(RouteSmall.Describe = RouteLarge.Describe,
    'ROUTE_DOES_NOT_DEPEND_ON_PAYLOAD');

  { Composition is a LOSSLESS affair. Natural already converts these pairs
    directly and idiomatically; routing one through a hub would change what
    it writes for no reason the caller asked for. }
  Natural := TSerialization.RouteFor(TSerializationFormat.Bson,
    TSerializationFormat.Xml, TStructuralConversionProfile.Natural);
  Strict := TSerialization.RouteFor(TSerializationFormat.Bson,
    TSerializationFormat.Xml, TStructuralConversionProfile.Strict);
  Note('natural: ' + Natural.Describe);
  Note('strict : ' + Strict.Describe);
  Check((Natural.HopCount = 1) and not Natural.IsComposed and
        (Strict.HopCount = 1) and not Strict.IsComposed,
    'ONLY_LOSSLESS_COMPOSES');

  { Everything not in the table is one hop. There are two rows in it, so
    JSON into XML - which HAS a published mapping of its own - is direct,
    and no third format is quietly involved. }
  Reported := TSerialization.RouteFor(TSerializationFormat.Json,
    TSerializationFormat.Xml, TStructuralConversionProfile.Lossless);
  Check((Reported.HopCount = 1) and
        (Reported.Steps[0].Standard = W3C_JSON_XML),
    'DIRECT_PAIRS_STAY_DIRECT');

  Check(Same and (RouteSmall.Describe = RouteLarge.Describe) and
        (Natural.HopCount = 1) and (Strict.HopCount = 1) and
        (Reported.HopCount = 1),
    'LOSSLESS_ROUTE_DETERMINISTIC');
end;

{ ===========================================================================
  INSPECTABILITY

  The route names every standard, in order, in a form somebody can put in a
  log line or an error message.
  =========================================================================== }

procedure TestInspectable;
var
  Route, Direct: TStructuralRoute;
  Text: string;
begin
  Writeln;
  Writeln('-- and it can be read --');

  Route := TSerialization.RouteFor(TSerializationFormat.Bson,
    TSerializationFormat.Xml, TStructuralConversionProfile.Lossless);
  Text := Route.Describe;
  Note(Text);

  Check(Text = Name(TSerializationFormat.Bson) + ' -> ' + EXTENDED_JSON +
        ' -> ' + Name(TSerializationFormat.Json) + ' -> ' + W3C_JSON_XML +
        ' -> ' + Name(TSerializationFormat.Xml),
    'ROUTE_DESCRIBES_EVERY_STANDARD');

  { A one-hop route is inspectable too, and names the standard it rests on
    when it has one. Lossless JSON into BSON is Extended JSON whether or not
    anything was composed to get there. }
  Direct := TSerialization.RouteFor(TSerializationFormat.Json,
    TSerializationFormat.Bson, TStructuralConversionProfile.Lossless);
  Note(Direct.Describe);
  Check(Direct.Steps[0].Standard = EXTENDED_JSON,
    'DIRECT_ROUTE_NAMES_ITS_STANDARD');

  Check((Pos(EXTENDED_JSON, Text) > 0) and (Pos(W3C_JSON_XML, Text) > 0) and
        (Pos(EXTENDED_JSON, Text) < Pos(W3C_JSON_XML, Text)) and
        (Direct.Steps[0].Standard = EXTENDED_JSON),
    'LOSSLESS_ROUTE_INSPECTABLE');
end;

{ ===========================================================================
  AND THE CONVENIENCE ITSELF

  The caller writes one Convert. They do not run either bridge by hand.
  =========================================================================== }

procedure TestStandardRouting;
var
  Xml, Back, ByHandXml, ByHandBack: TSerializationPayload;
  Before, After: string;
  Ok: Boolean;
begin
  Writeln;
  Writeln('-- one call, not two --');

  Before := AsExtendedJson(BsonDocument);

  { What the application developer writes. }
  Xml := TSerialization.Convert(BsonDocument,
    TSerializationFormat.Bson, TSerializationFormat.Xml,
    TStructuralConversionProfile.Lossless);
  Back := TSerialization.Convert(Xml,
    TSerializationFormat.Xml, TSerializationFormat.Bson,
    TStructuralConversionProfile.Lossless);
  After := AsExtendedJson(Back);

  { And what they would otherwise have had to write. The OPTIONS overload is
    the one-hop primitive and never composes, so these four calls really are
    the two standards run by hand. The results must agree, or the
    composition is doing something of its own invention. }
  ByHandXml := TSerialization.Convert(
    TSerialization.Convert(BsonDocument, TSerializationFormat.Bson,
      TSerializationFormat.Json, LosslessOptions),
    TSerializationFormat.Json, TSerializationFormat.Xml, LosslessOptions);
  ByHandBack := TSerialization.Convert(
    TSerialization.Convert(ByHandXml, TSerializationFormat.Xml,
      TSerializationFormat.Json, LosslessOptions),
    TSerializationFormat.Json, TSerializationFormat.Bson, LosslessOptions);

  Ok := (Before = After) and (Xml.AsText = ByHandXml.AsText) and
        (AsExtendedJson(ByHandBack) = After);
  if not Ok then
  begin
    Note('before   : ' + Before);
    Note('after    : ' + After);
    Note('composed : ' + Copy(Xml.AsText, 1, 300));
    Note('by hand  : ' + Copy(ByHandXml.AsText, 1, 300));
  end;
  Check(Ok, 'LOSSLESS_STANDARD_ROUTING');
end;

begin
  try
    TestBsonToXmlRoute;
    TestXmlToBsonRoute;
    TestDeterminism;
    TestInspectable;
    TestStandardRouting;

    Writeln;
    Writeln('FAILURES=', GFailures);
    if GFailures = 0 then Writeln('LOSSLESS_ROUTING: PASS')
    else
    begin
      Writeln('LOSSLESS_ROUTING: FAIL');
      Halt(1);
    end;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Writeln('LOSSLESS_ROUTING: FAIL');
      Halt(1);
    end;
  end;
end.
