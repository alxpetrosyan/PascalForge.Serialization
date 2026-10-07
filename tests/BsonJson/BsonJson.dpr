program BsonJson;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ BSON and JSON, three ways - and none of them is a wrapper of this
  library's own.

  BSON has twenty-two element types and JSON has six, so something has to
  give. What this program checks is that the three answers on offer are all
  answers somebody else would recognize:

    PLAIN               idiomatic JSON, type information gone, says so
    PLAIN + SCHEMA      the same JSON, plus a SEPARATE type-definition
                        object; put back together, exact
    EXTENDED JSON       MongoDB's published Extended JSON, one document,
                        exact, and readable by mongosh

  And the fourth thing, which matters as much as the three: going from plain
  JSON to BSON, nothing is inferred from the SPELLING of a value. A
  twenty-four character hex string is a string. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.DateUtils, System.Classes,
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  PascalForge.Bson in '..\..\src\PascalForge.Bson.pas',
  PascalForge.Bson.Internal in '..\..\src\PascalForge.Bson.Internal.pas',
  PascalForge.Json.Registration in '..\..\src\PascalForge.Json.Registration.pas',
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

function Decimal(const AText: string): TBytes;
begin
  if not TDecimal128.TryFromText(AText, Result) then
    raise Exception.CreateFmt('"%s" is not a decimal128.', [AText]);
end;

{ Every exotic BSON type in one document, so that no mode can pass by
  covering only the easy half. }
function RichDocument: TBytes;
var
  Doc, Scope: TBsonValue;
begin
  Doc := TBsonValue.NewDocument;
  try
    Doc.Add('Id', TBsonValue.NewObjectId(
      TBsonObjectId.FromHex('507f1f77bcf86cd799439011')));
    Doc.Add('Count', TBsonValue.NewInt32(42));
    Doc.Add('Big', TBsonValue.NewInt64(4611686018427387903));
    Doc.Add('Rate', TBsonValue.NewDouble(1.5));
    Doc.Add('Name', TBsonValue.NewString('Ada'));
    Doc.Add('Active', TBsonValue.NewBool(True));
    Doc.Add('Nothing', TBsonValue.NewNull);
    Doc.Add('Blob', TBsonValue.NewBinary(TBytes.Create(1, 2, 3, 250, 255)));
    Doc.Add('Uuid', TBsonValue.NewBinary(TBytes.Create(9, 9, 9), Byte(4)));
    Doc.Add('CreatedAt', TBsonValue.NewDateTime(
      EncodeDate(2026, 3, 14) + EncodeTime(9, 26, 53, 120)));
    Doc.Add('Stamp', TBsonValue.NewTimestamp(
      (UInt64(1770000000) shl 32) or 7));
    Doc.Add('Money', TBsonValue.NewDecimal128(
      Decimal('123.45')));
    Doc.Add('Pattern', TBsonValue.NewRegex('^a.*z$', 'i'));
    Doc.Add('Code', TBsonValue.NewJavaScript('return 1;'));
    Scope := TBsonValue.NewDocument;
    Scope.Add('x', TBsonValue.NewInt32(1));
    Doc.Add('Scoped', TBsonValue.NewJavaScriptScope('return x;', Scope));
    Doc.Add('Sym', TBsonValue.NewSymbol('legacy'));
    Doc.Add('Gone', TBsonValue.NewUndefined);
    Doc.Add('Ptr', TBsonValue.NewDbPointer('db.coll',
      TBsonObjectId.FromHex('507f191e810c19729de860ea')));
    Doc.Add('Lowest', TBsonValue.NewMinKey);
    Doc.Add('Highest', TBsonValue.NewMaxKey);
    Result := TBsonEngine.WriteDocument(Doc);
  finally
    Doc.Free;
  end;
end;

{ ===========================================================================
  1. DECIMAL128 AS TEXT

  Extended JSON spells a decimal128 in DIGITS, so the sixteen bytes have to
  become digits somewhere. It is worth checking that conversion on its own,
  against values whose answers are not in doubt.
  =========================================================================== }

procedure TestDecimal128;
var
  Bytes: TBytes;
  T: string;

  procedure RoundTrip(const AText, AExpected: string);
  var
    B: TBytes;
    Out_: string;
  begin
    if not TDecimal128.TryFromText(AText, B) then
    begin
      Check(False, 'DECIMAL128_PARSE:' + AText);
      Exit;
    end;
    if not TDecimal128.TryToText(B, Out_) then
    begin
      Check(False, 'DECIMAL128_RENDER:' + AText);
      Exit;
    end;
    Note(Format('%-24s -> %s', [AText, Out_]));
    if Out_ <> AExpected then Check(False, 'DECIMAL128_TEXT:' + AText);
  end;

begin
  Writeln('-- decimal128 as text --');

  { The spellings the decimal-arithmetic specification gives for
    to-scientific-string, which is the form Extended JSON requires. }
  RoundTrip('0', '0');
  RoundTrip('123', '123');
  RoundTrip('-123', '-123');
  RoundTrip('1.5', '1.5');
  RoundTrip('123.45', '123.45');
  RoundTrip('0.001', '0.001');
  RoundTrip('1E+30', '1E+30');
  RoundTrip('-1.5E-10', '-1.5E-10');
  RoundTrip('9999999999999999999999999999999999', '9999999999999999999999999999999999');
  RoundTrip('NaN', 'NaN');
  RoundTrip('Infinity', 'Infinity');
  RoundTrip('-Infinity', '-Infinity');
  Check(GFailures = 0, 'DECIMAL128_TEXT_ROUND_TRIP');

  { Thirty-five significant digits is one too many, and that is an error
    rather than a rounding opportunity. }
  Check(not TDecimal128.TryFromText('12345678901234567890123456789012345',
    Bytes), 'DECIMAL128_REFUSES_TOO_MANY_DIGITS');
  Check(not TDecimal128.TryFromText('not a number', Bytes),
    'DECIMAL128_REFUSES_NONSENSE');
  Check(not TDecimal128.TryToText(TBytes.Create(1, 2, 3), T),
    'DECIMAL128_REFUSES_WRONG_LENGTH');
end;

{ ===========================================================================
  2. THE THREE MODES
  =========================================================================== }

procedure TestPlain;
var
  Data: TBytes;
  Json: string;
begin
  Writeln;
  Writeln('-- plain --');
  Data := RichDocument;
  Json := TBsonSerializer.ToJson(Data);
  Note(Copy(Json, 1, 400));

  { Idiomatic, and nothing in it claims to be anything else. }
  Check(Has(Json, '"Id":"507f1f77bcf86cd799439011"') and
        Has(Json, '"Count":42') and Has(Json, '"Rate":1.5') and
        Has(Json, '"Name":"Ada"') and Has(Json, '"Active":true') and
        Has(Json, '"Nothing":null') and
        Has(Json, '"CreatedAt":"2026-03-14T09:26:53.120"') and
        Has(Json, '"Money":"123.45"'),
    'BSON_PLAIN_JSON_IS_IDIOMATIC');
  Check(not Has(Json, '$oid') and not Has(Json, '$numberDecimal') and
        not Has(Json, 'pascalforge'),
    'BSON_PLAIN_JSON_HAS_NO_TYPE_MARKERS');
end;

procedure TestExtended;
var
  Data, Back: TBytes;
  Json, Json2: string;
begin
  Writeln;
  Writeln('-- MongoDB Extended JSON --');
  Data := RichDocument;
  Json := TBsonSerializer.ToExtendedJson(Data);
  Note(Copy(Json, 1, 600));

  { Every wrapper below is one the Extended JSON specification defines. }
  Check(Has(Json, '"$oid":"507f1f77bcf86cd799439011"') and
        Has(Json, '"$date"') and Has(Json, '"$numberLong"') and
        Has(Json, '"$binary"') and Has(Json, '"subType":"00"') and
        Has(Json, '"subType":"04"') and
        Has(Json, '"$numberDecimal":"123.45"') and
        Has(Json, '"$timestamp"') and
        Has(Json, '"$regularExpression"') and Has(Json, '"$code"') and
        Has(Json, '"$scope"') and Has(Json, '"$symbol"') and
        Has(Json, '"$undefined":true') and Has(Json, '"$dbPointer"') and
        Has(Json, '"$minKey":1') and Has(Json, '"$maxKey":1'),
    'BSON_EXTENDED_JSON_USES_THE_STANDARD');
  Check(not Has(Json, 'pascalforge') and not Has(Json, 'pf:'),
    'BSON_EXTENDED_JSON_HAS_NO_PRIVATE_METADATA');

  { And it comes back, byte for byte. }
  Back := TBsonSerializer.FromExtendedJson(Json);
  Json2 := TBsonSerializer.ToExtendedJson(Back);
  Check(Json2 = Json, 'BSON_EXTENDED_JSON_ROUND_TRIPS');
  Check(Length(Back) = Length(Data), 'BSON_EXTENDED_JSON_SAME_LENGTH');

  { The datetime specifically, to the millisecond, because the obvious way to
    write that conversion loses six seconds on Win64 - where Extended is a
    Double and the sum of the epoch and the offset needs more significant
    digits than one has. Both directions go through the RTL's own
    IncMilliSecond and Round, which is also what BSON's reader and writer
    use, so the two halves cannot drift apart. }
  Check(Has(Json, '"$numberLong":"1773480413120"'),
    'BSON_EXTENDED_JSON_DATE_IS_EXACT');
  Check(Has(TBsonSerializer.ToExtendedJson(Back),
    '"$numberLong":"1773480413120"'),
    'BSON_EXTENDED_JSON_DATE_SURVIVES_THE_ROUND_TRIP');
end;

procedure TestSchemaMode;
var
  Data, Back: TBytes;
  Json, Schema, Json2, Schema2: string;
begin
  Writeln;
  Writeln('-- plain plus a separate schema --');
  Data := RichDocument;
  Json := TBsonSerializer.ToJsonWithSchema(Data, Schema);
  Note('data  : ' + Copy(Json, 1, 300));
  Note('schema: ' + Copy(Schema, 1, 400));

  { The DATA document is the plain one, unchanged: a consumer that does not
    care about types reads it and never knows the schema exists. }
  Check(Json = TBsonSerializer.ToJson(Data),
    'BSON_SCHEMA_MODE_LEAVES_THE_DATA_PLAIN');
  Check(not Has(Json, '$oid') and not Has(Json, '"types"'),
    'BSON_SCHEMA_IS_NOT_IN_THE_DATA');

  { The SCHEMA is a separate document, and it names BSON's own type
    aliases. }
  Check(Has(Schema, '"types"') and Has(Schema, '"$.Id":"objectId"') and
        Has(Schema, '"$.Count":"int"') and Has(Schema, '"$.Big":"long"') and
        Has(Schema, '"$.Rate":"double"') and
        Has(Schema, '"$.CreatedAt":"date"') and
        Has(Schema, '"$.Money":"decimal"') and
        Has(Schema, '"$.Blob":"binData"') and
        Has(Schema, '"$.Uuid":"binData:04"') and
        Has(Schema, '"$.Stamp":"timestamp"') and
        Has(Schema, '"$.Pattern":"regex"') and
        Has(Schema, '"$.Sym":"symbol"') and
        Has(Schema, '"$.Gone":"undefined"') and
        Has(Schema, '"$.Ptr":"dbPointer"') and
        Has(Schema, '"$.Lowest":"minKey"') and
        Has(Schema, '"$.Highest":"maxKey"'),
    'BSON_SCHEMA_NAMES_EVERY_TYPE');

  { Put back together, the document is the one that went in. }
  Back := TBsonSerializer.FromJson(Json, Schema);
  Json2 := TBsonSerializer.ToJsonWithSchema(Back, Schema2);
  Check((Json2 = Json) and (Schema2 = Schema),
    'BSON_SCHEMA_MODE_ROUND_TRIPS');
  Check(TBsonSerializer.ToExtendedJson(Back) =
        TBsonSerializer.ToExtendedJson(Data),
    'BSON_SCHEMA_MODE_IS_EXACT');
end;

{ ===========================================================================
  3. WHAT PLAIN JSON PROVES
  =========================================================================== }

procedure TestConservativeInference;
const
  SRC = '{"Hex":"507f1f77bcf86cd799439011",' +
        '"Date":"2026-03-14T09:26:53.120",' +
        '"B64":"AQID",' +
        '"Guid":"6B29FC40-CA47-1067-B31D-00DD010662DA",' +
        '"Small":42,"Large":4611686018427387903,"Real":1.5,' +
        '"Yes":true,"Empty":null,"List":[1,2],"Nested":{"a":1}}';
var
  Data: TBytes;
  Schema: string;
begin
  Writeln;
  Writeln('-- what plain JSON proves --');
  Data := TBsonSerializer.FromJson(SRC);
  TBsonSerializer.ToJsonWithSchema(Data, Schema);
  Note(Schema);

  { NONE of these became something else because of how it is spelled. }
  Check(Has(Schema, '"$.Hex":"string"'), 'JSON_HEX_STAYS_A_STRING');
  Check(Has(Schema, '"$.Date":"string"'), 'JSON_DATE_TEXT_STAYS_A_STRING');
  Check(Has(Schema, '"$.B64":"string"'), 'JSON_BASE64_STAYS_A_STRING');
  Check(Has(Schema, '"$.Guid":"string"'), 'JSON_GUID_TEXT_STAYS_A_STRING');

  { And what JSON DOES prove is used: a whole number that fits is an int32,
    one that does not is an int64, a fractional one is a double. }
  Check(Has(Schema, '"$.Small":"int"'), 'JSON_SMALL_INT_IS_INT32');
  Check(Has(Schema, '"$.Large":"long"'), 'JSON_LARGE_INT_IS_INT64');
  Check(Has(Schema, '"$.Real":"double"'), 'JSON_FRACTION_IS_DOUBLE');
  Check(Has(Schema, '"$.Yes":"bool"') and Has(Schema, '"$.Empty":"null"') and
        Has(Schema, '"$.List":"array"') and Has(Schema, '"$.Nested":"object"'),
    'JSON_STRUCTURE_IS_TAKEN_AT_ITS_WORD');

  { Extended JSON is not recognized by FromJson either - that is what
    FromExtendedJson is for, and asking for it is how a caller says the
    document is in that format. }
  Data := TBsonSerializer.FromJson('{"Id":{"$oid":"507f1f77bcf86cd799439011"}}');
  TBsonSerializer.ToJsonWithSchema(Data, Schema);
  Check(Has(Schema, '"$.Id":"object"') and Has(Schema, '"$.Id.$oid":"string"'),
    'PLAIN_JSON_READER_DOES_NOT_RECOGNIZE_EXTENDED_JSON');

  Data := TBsonSerializer.FromExtendedJson(
    '{"Id":{"$oid":"507f1f77bcf86cd799439011"}}');
  TBsonSerializer.ToJsonWithSchema(Data, Schema);
  Check(Has(Schema, '"$.Id":"objectId"'),
    'EXTENDED_JSON_READER_DOES');
end;

{ ===========================================================================
  4. UNICODE THROUGH ALL THREE
  =========================================================================== }

procedure TestUnicode;
const
  GEO = #$10D2#$10D8#$10DA#$10DD#$10EA#$10D0;
var
  Data, Back: TBytes;
  Json, Schema: string;
begin
  Writeln;
  Writeln('-- Unicode --');
  Data := TBsonSerializer.FromJson('{"Name":"' + GEO + '"}');

  Json := TBsonSerializer.ToJson(Data);
  Check(Has(Json, GEO), 'BSON_JSON_PLAIN_KEEPS_UNICODE');

  Json := TBsonSerializer.ToExtendedJson(Data);
  Check(Has(Json, GEO), 'BSON_JSON_EXTENDED_KEEPS_UNICODE');

  Json := TBsonSerializer.ToJsonWithSchema(Data, Schema);
  Back := TBsonSerializer.FromJson(Json, Schema);
  Check(Has(TBsonSerializer.ToJson(Back), GEO),
    'BSON_JSON_SCHEMA_KEEPS_UNICODE');
end;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TJsonSerializationRegistration.RegisterFormat;
  TBsonSerializationRegistration.RegisterFormat;
  try
    TestDecimal128;
    TestPlain;
    TestExtended;
    TestSchemaMode;
    TestConservativeInference;
    TestUnicode;

    Writeln;
    Writeln('FAILURES=', GFailures);
    if GFailures = 0 then Writeln('BSON_JSON: PASS')
    else Writeln('BSON_JSON: FAIL');
    if GFailures > 0 then Halt(1);
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Writeln('BSON_JSON: FAIL');
      Halt(1);
    end;
  end;
end.
