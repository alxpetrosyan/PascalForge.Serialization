program UnicodeUtf8;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ TEXT IS NOT BYTES.

  A Delphi string is Unicode text - a sequence of UTF-16 code units - and it
  has no byte encoding at all until somebody chooses one. A TBytes is bytes,
  and says nothing about what they mean. Confusing the two is how a Georgian
  name becomes a row of question marks somewhere between a database and a
  browser, and the whole point of this test is that it cannot happen here.

  Three separate claims are checked:

    1. LOSSLESS THROUGH CONVERSION. Text survives JSON -> XML -> JSON and
       back the other way as the same code units. Not "looks the same" -
       the same code points, compared one by one, including non-BMP
       characters that are two UTF-16 units each.

    2. READABLE BY DEFAULT. JSON escapes what JSON requires and nothing
       else, so a Georgian value stays Georgian in the output instead of
       becoming sixteen \uXXXX groups. Callers who need 7-bit output ask
       for it.

    3. UTF-8 IS EXPLICIT. SerializeUtf8 chooses the encoding out loud,
       writes no BOM, and never touches a code page. The bytes it produces
       are decoded here by a decoder written IN THIS FILE, so the check does
       not rest on the same code it is checking. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.StrUtils, System.Classes, System.JSON,
  System.Generics.Collections,
  UnicodeModels in 'UnicodeModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  PascalForge.Xml in '..\..\src\PascalForge.Xml.pas',
  PascalForge.Bson in '..\..\src\PascalForge.Bson.pas',
  PascalForge.Json.Registration in '..\..\src\PascalForge.Json.Registration.pas',
  PascalForge.Xml.Registration in '..\..\src\PascalForge.Xml.Registration.pas',
  PascalForge.Bson.Registration in '..\..\src\PascalForge.Bson.Registration.pas';

{ ---------------------------------------------------------------------------
  THE FIXTURES

  Written as code points, deliberately. A literal in the source file would
  make this test a test of how the file was saved and of what the compiler
  assumed about it; these are the exact UTF-16 units and nothing can change
  them.
  --------------------------------------------------------------------------- }
const
  { Georgian: "lali jishkariani" }
  GEO_NAME = #$10DA#$10DD#$10D3#$10D8' '#$10EF#$10D8#$10E8#$10D9#$10D0 +
             #$10E0#$10D8#$10D0#$10DC#$10D8;
  { Georgian: "sakartvelo" }
  GEO_COUNTRY = #$10E1#$10D0#$10E5#$10D0#$10E0#$10D7#$10D5#$10D4#$10DA#$10DD;
  { Georgian: "individualuri metsarme" }
  GEO_FORM = #$10D8#$10DC#$10D3#$10D8#$10D5#$10D8#$10D3#$10E3#$10D0#$10DA +
             #$10E3#$10E0#$10D8' '#$10DB#$10D4#$10EC#$10D0#$10E0#$10DB#$10D4;
  { Georgian: "motsmoba" }
  GEO_DOC = #$10DB#$10DD#$10EC#$10DB#$10DD#$10D1#$10D0;
  { Georgian: a street address, with punctuation, a slash and digits
    mixed into the script. }
  GEO_ADDRESS = #$10E5'.'#$10E5#$10E3#$10D7#$10D0#$10D8#$10E1#$10E8#$10D8 +
                '/'#$10EF#$10D0#$10DC#$10D4#$10DA#$10D8#$10EB#$10D8#$10E1 +
                ' 14 '#$10D8#$10DB#$10D4#$10D3#$10D0#$10E8#$10D5#$10D8 +
                #$10DA#$10D8#$10E1#$10E1#$10D0#$10EE#$10DA#$10D8'.9';

  { Cyrillic: "privet, mir" }
  CYRILLIC = #$041F#$0440#$0438#$0432#$0435#$0442', '#$043C#$0438#$0440;
  { Latin-1 supplement and Latin Extended-A and -B }
  LATIN_EXT = #$00E0#$00E9#$00EE#$00F5#$00FC' '#$0106#$017C' '#$01C4;
  { CJK: five Han characters }
  CJK = #$65E5#$672C#$8A9E#$6F22#$5B57;
  { U+1F600 and the flag U+1F1EC U+1F1EA - four surrogate halves, two
    characters. }
  EMOJI = #$D83D#$DE00#$D83C#$DDEC#$D83C#$DDEA;
  { e + COMBINING ACUTE, a + COMBINING DIAERESIS + COMBINING MACRON.  These
    must NOT be normalised away: the document said what it said. }
  COMBINING = 'e'#$0301'a'#$0308#$0304;

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

{ Code points, spelled out - so a failure message says WHICH unit differs
  rather than printing two strings the console cannot render anyway. }
function CodeUnits(const AText: string): string;
var
  I: Integer;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for I := 1 to Length(AText) do
    begin
      if I > 1 then SB.Append(' ');
      SB.Append(IntToHex(Ord(AText[I]), 4));
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function Hex(const ABytes: TBytes): string;
var
  I: Integer;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for I := 0 to High(ABytes) do
    begin
      if I > 0 then SB.Append(' ');
      SB.Append(IntToHex(ABytes[I], 2));
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function Has(const AText, AFragment: string): Boolean;
begin
  Result := Pos(AFragment, AText) > 0;
end;

{ The JSON escape for one code unit, assembled at run time.  Deliberately not
  written as a literal: a source file full of backslash-u sequences invites
  every tool between here and the compiler to have an opinion about them. }
function Esc(const AHex: string): string;
begin
  Result := '\' + 'u' + AHex;
end;

{ ---------------------------------------------------------------------------
  AN INDEPENDENT UTF-8 DECODER

  Written here, from the specification, so that "the bytes are valid UTF-8
  carrying these characters" is not checked by the same code that produced
  them. If both were wrong in the same way, this would still catch it.
  --------------------------------------------------------------------------- }
function IndependentUtf8Decode(const ABytes: TBytes; out AText: string): Boolean;
var
  I, N, Extra, CP, J: Integer;
  B: Byte;
  SB: TStringBuilder;
begin
  AText := '';
  N := Length(ABytes);
  SB := TStringBuilder.Create;
  try
    I := 0;
    while I < N do
    begin
      B := ABytes[I];
      if B < $80 then begin CP := B; Extra := 0 end
      else if (B and $E0) = $C0 then begin CP := B and $1F; Extra := 1 end
      else if (B and $F0) = $E0 then begin CP := B and $0F; Extra := 2 end
      else if (B and $F8) = $F0 then begin CP := B and $07; Extra := 3 end
      else Exit(False);
      if I + Extra >= N then Exit(False);
      for J := 1 to Extra do
      begin
        if (ABytes[I + J] and $C0) <> $80 then Exit(False);
        CP := (CP shl 6) or (ABytes[I + J] and $3F);
      end;
      Inc(I, Extra + 1);
      if CP < $10000 then SB.Append(Char(CP))
      else
      begin
        Dec(CP, $10000);
        SB.Append(Char($D800 or (CP shr 10)));
        SB.Append(Char($DC00 or (CP and $3FF)));
      end;
    end;
    AText := SB.ToString;
    Result := True;
  finally
    SB.Free;
  end;
end;

function ContainsBytes(const AHaystack, ANeedle: TBytes): Boolean;
var
  I, J: Integer;
  Match: Boolean;
begin
  if Length(ANeedle) = 0 then Exit(True);
  for I := 0 to Length(AHaystack) - Length(ANeedle) do
  begin
    Match := True;
    for J := 0 to High(ANeedle) do
      if AHaystack[I + J] <> ANeedle[J] then
      begin
        Match := False;
        Break;
      end;
    if Match then Exit(True);
  end;
  Result := False;
end;

function Text(const AValue: string): TSerializationPayload;
begin
  Result := TSerializationPayload.FromText(AValue);
end;

function JsonWith(const AValue: string): string;
begin
  { One member, one value, so a failure is about the value and nothing
    else. Nothing in these fixtures needs JSON escaping. }
  Result := '{"v":"' + AValue + '"}';
end;

{ Reads a member back with the RTL's own parser - a second implementation, so
  the round trip is not judged by the code that produced it. }
function MemberOf(const AJson, AName: string): string;
var
  V: TJSONValue;
begin
  V := TJSONObject.ParseJSONValue(AJson);
  if V = nil then Exit(#0'PARSE FAILED');
  try
    if not TJSONObject(V).TryGetValue<string>(AName, Result) then
      Result := #0'MEMBER ' + AName + ' NOT FOUND';
  finally
    V.Free;
  end;
end;

function ValueOf(const AJson: string): string;
begin
  Result := MemberOf(AJson, 'v');
end;

{ ===========================================================================
  1. THROUGH THE FORMATS
  =========================================================================== }

procedure RoundTrip(const AValue, AName: string);
var
  Xml, Back: TSerializationPayload;
  Got: string;
begin
  Xml := TSerialization.Convert(Text(JsonWith(AValue)),
    TSerializationFormat.Json, TSerializationFormat.Xml);
  Back := TSerialization.Convert(Xml, TSerializationFormat.Xml,
    TSerializationFormat.Json);
  Got := ValueOf(Back.AsText);
  if Got <> AValue then
  begin
    Note('expected: ' + CodeUnits(AValue));
    Note('got:      ' + CodeUnits(Got));
  end;
  Check(Got = AValue, AName);
end;

procedure TestConversionIsLossless;
var
  Xml, Json, Back: TSerializationPayload;
begin
  Writeln('-- text through the formats --');

  RoundTrip(GEO_NAME, 'UNICODE_GEORGIAN_JSON_XML_JSON');
  RoundTrip(CYRILLIC, 'UNICODE_CYRILLIC_ROUNDTRIP');
  RoundTrip(LATIN_EXT, 'UNICODE_LATIN_EXTENDED_ROUNDTRIP');
  RoundTrip(CJK, 'UNICODE_CJK_ROUNDTRIP');
  RoundTrip(EMOJI, 'UNICODE_EMOJI_NONBMP_ROUNDTRIP');
  RoundTrip(COMBINING, 'UNICODE_COMBINING_MARKS_ROUNDTRIP');
  RoundTrip(GEO_ADDRESS, 'UNICODE_GEORGIAN_ADDRESS_ROUNDTRIP');

  { The emoji is two characters and four UTF-16 units, and all four come
    back - a surrogate pair that survives as a pair is the case a naive
    per-character conversion gets wrong. }
  Check(Length(EMOJI) = 6, 'UNICODE_NONBMP_IS_SURROGATE_PAIRS');
  Xml := TSerialization.Convert(Text(JsonWith(EMOJI)),
    TSerializationFormat.Json, TSerializationFormat.Xml);
  Back := TSerialization.Convert(Xml, TSerializationFormat.Xml,
    TSerializationFormat.Json);
  Check(CodeUnits(ValueOf(Back.AsText)) = CodeUnits(EMOJI), 'UNICODE_NONBMP');

  { The other direction: XML first. }
  Xml := Text('<r><v>' + GEO_NAME + '</v></r>');
  Json := TSerialization.Convert(Xml, TSerializationFormat.Xml,
    TSerializationFormat.Json);
  Back := TSerialization.Convert(Json, TSerializationFormat.Json,
    TSerializationFormat.Xml);
  Check(Has(Back.AsText, GEO_NAME), 'UNICODE_GEORGIAN_XML_JSON_XML');

  { And through BSON, whose strings are UTF-8 on the inside. }
  Back := TSerialization.Convert(
    TSerialization.Convert(Text(JsonWith(GEO_FORM)),
      TSerializationFormat.Json, TSerializationFormat.Bson),
    TSerializationFormat.Bson, TSerializationFormat.Json);
  Check(ValueOf(Back.AsText) = GEO_FORM, 'UNICODE_INTERNAL_LOSSLESS');
end;

{ ===========================================================================
  2. WHAT THE JSON TEXT LOOKS LIKE
  =========================================================================== }

procedure TestJsonEscaping;
var
  S: TSubject;
  Json, Escaped: string;
  Options: TJsonSerializationOptions;
begin
  Writeln;
  Writeln('-- JSON escaping --');

  S := TSubject.Create(1, GEO_NAME, GEO_COUNTRY, GEO_DOC);
  try
    Json := TJsonSerializer.Serialize<TSubject>(S);
    Note(CodeUnits(Copy(Json, 1, 40)) + ' ...');

    { The Georgian characters are IN the text, as themselves. }
    Check(Has(Json, GEO_NAME) and Has(Json, GEO_COUNTRY) and
          Has(Json, GEO_DOC),
      'JSON_DEFAULT_PRESERVES_GEORGIAN_TEXT');
    Check(not Has(Json, '\u10'), 'JSON_DEFAULT_UNESCAPED_UNICODE');

    { ... and the document is still valid JSON, which is the other half of
      the claim: the RTL's parser reads it back. }
    Check(ValueOf('{"v":' + '"' + GEO_NAME + '"}') = GEO_NAME,
      'JSON_DEFAULT_IS_STILL_VALID_JSON');

    { Asking for 7-bit output is a deliberate act and it works. }
    Options := TJsonSerializationOptions.Default;
    Options.UnicodeEscape := TJsonUnicodeEscapePolicy.EscapeNonAscii;
    Escaped := TJsonSerializer.Serialize<TSubject>(S, Options);
    Note(Copy(Escaped, 1, 80) + ' ...');
    Check(Has(Escaped, Esc('10DA')) and not Has(Escaped, GEO_NAME),
      'JSON_ESCAPE_NONASCII_OPTION');
  finally
    S.Free;
  end;

  { Both spellings carry the same values, and both come back the same. }
  S := TJsonSerializer.Deserialize<TSubject>(Escaped);
  try
    Check((S.Name = GEO_NAME) and (S.Country = GEO_COUNTRY),
      'JSON_ESCAPE_NONASCII_ROUNDTRIP');
  finally
    S.Free;
  end;

  { A control character is escaped in BOTH modes - JSON requires it, and the
    RTL's ToString does not do it, which is why this library renders its own
    text. }
  S := TSubject.Create(2, 'a'#1'b', 'x', 'y');
  try
    Json := TJsonSerializer.Serialize<TSubject>(S);
    Check(Has(Json, Esc('0001')), 'JSON_CONTROL_CHARACTERS_ESCAPED');
    Check(ValueOf('{"v":"a' + Esc('0001') + 'b"}') = 'a'#1'b',
      'JSON_CONTROL_CHARACTER_ROUNDTRIP');
  finally
    S.Free;
  end;
end;

{ ===========================================================================
  3. UTF-8
  =========================================================================== }

procedure TestUtf8;
var
  S, Back: TSubject;
  Bytes, Geo: TBytes;
  Decoded: string;
  Payload: TSerializationPayload;
  Raised: Boolean;
begin
  Writeln;
  Writeln('-- UTF-8 --');

  { U+10DA is E1 83 9A in UTF-8. Nothing about that depends on the machine
    this runs on, which is the point. }
  Geo := TBytes.Create($E1, $83, $9A);

  S := TSubject.Create(7, GEO_NAME, GEO_COUNTRY, GEO_ADDRESS);
  try
    Bytes := TJsonSerializer.SerializeUtf8<TSubject>(S);
  finally
    S.Free;
  end;
  Note(Hex(Copy(Bytes, 0, 24)) + ' ...');

  Check((Length(Bytes) >= 3) and
        not ((Bytes[0] = $EF) and (Bytes[1] = $BB) and (Bytes[2] = $BF)),
    'JSON_UTF8_NO_BOM_DEFAULT');
  Check(ContainsBytes(Bytes, Geo), 'JSON_UTF8_GEORGIAN');

  { Decoded by the decoder written at the top of this file, then parsed by
    the RTL's parser. Neither is the code being tested. }
  Check(IndependentUtf8Decode(Bytes, Decoded), 'JSON_UTF8_SERIALIZE');
  Check(MemberOf(Decoded, 'name') = GEO_NAME,
    'JSON_UTF8_GEORGIAN_VALUE_SURVIVES');

  { A code-page conversion would have produced one byte per character and
    filled it with question marks. Three bytes per Georgian character is
    what UTF-8 gives, and there is not a '?' in sight. }
  Check(Length(StringToUtf8Bytes(GEO_COUNTRY)) = 3 * Length(GEO_COUNTRY),
    'UTF8_NO_SYSTEM_CODEPAGE_DEPENDENCY');
  Check((Length(StringToUtf8Bytes(GEO_COUNTRY)) = 3 * Length(GEO_COUNTRY)) and
        ContainsBytes(Bytes, Geo) and
        not ContainsBytes(StringToUtf8Bytes(GEO_NAME),
          TBytes.Create(Ord('?'))),
    'JSON_UTF8_NO_CODEPAGE_DEPENDENCY');
  Check(not ContainsBytes(StringToUtf8Bytes(GEO_COUNTRY),
    TBytes.Create(Ord('?'))), 'UTF8_NO_SUBSTITUTION');
  Check(Length(StringToUtf8Bytes(GEO_NAME)) > 0, 'UTF8_NO_BOM_DEFAULT');

  { Back the other way. }
  Back := TJsonSerializer.DeserializeUtf8<TSubject>(Bytes);
  try
    Check((Back.Name = GEO_NAME) and (Back.Country = GEO_COUNTRY) and
          (Back.Note = GEO_ADDRESS), 'JSON_UTF8_DESERIALIZE');
  finally
    Back.Free;
  end;

  { A BOM on the way in is accepted, because producers write them. }
  Back := TJsonSerializer.DeserializeUtf8<TSubject>(
    Concat(TBytes.Create($EF, $BB, $BF), Bytes));
  try
    Check(Back.Name = GEO_NAME, 'JSON_UTF8_BOM_ACCEPTED_ON_INPUT');
  finally
    Back.Free;
  end;

  { Malformed bytes are named, not quietly turned into U+FFFD. }
  Raised := False;
  try
    Utf8BytesToString(TBytes.Create($41, $E1, $83));
  except
    on E: EInvalidUtf8 do Raised := True;
  end;
  Check(Raised, 'UTF8_MALFORMED_INPUT_IS_REFUSED');
  Check(not IsValidUtf8(TBytes.Create($C0, $80)), 'UTF8_OVERLONG_IS_REFUSED');

  { XML says UTF-8 in its declaration and means it. }
  S := TSubject.Create(7, GEO_NAME, GEO_COUNTRY, GEO_ADDRESS);
  try
    Bytes := TXmlSerializer.SerializeUtf8<TSubject>(S);
  finally
    S.Free;
  end;
  Check(IndependentUtf8Decode(Bytes, Decoded), 'XML_UTF8');
  Note(Copy(Decoded, 1, 60) + ' ...');
  Check(Has(Decoded, 'encoding="UTF-8"') and Has(Decoded, GEO_NAME),
    'XML_UTF8_GEORGIAN');
  Check(ContainsBytes(Bytes, Geo), 'XML_UTF8_BYTES_ARE_UTF8');
  Back := TXmlSerializer.DeserializeUtf8<TSubject>(Bytes);
  try
    Check(Back.Name = GEO_NAME, 'XML_UTF8_ROUNDTRIP');
  finally
    Back.Free;
  end;

  { --- the payload's own API ------------------------------------------- }
  Payload := TSerializationPayload.FromText(GEO_NAME);
  Check(Payload.IsText and (Payload.AsText = GEO_NAME) and
        (Payload.ToUtf8Bytes[0] = $E1), 'SERIALIZATION_PAYLOAD_UTF8_API');

  Raised := False;
  try Payload.AsBytes except on E: ESerializationPayloadKind do Raised := True end;
  Check(Raised, 'PAYLOAD_TEXT_HAS_NO_BYTES');

  Raised := False;
  try Payload.DecodeUtf8Text except on E: ESerializationPayloadKind do Raised := True end;
  Check(Raised, 'PAYLOAD_TEXT_IS_NOT_DECODED');

  Payload := TSerializationPayload.FromBytes(StringToUtf8Bytes(GEO_NAME));
  Check(Payload.IsBinary and (Payload.DecodeUtf8Text = GEO_NAME),
    'PAYLOAD_BINARY_DECODES_EXPLICITLY');

  Raised := False;
  try Payload.AsText except on E: ESerializationPayloadKind do Raised := True end;
  Check(Raised, 'PAYLOAD_BINARY_HAS_NO_TEXT');

  { The one that used to be a trap: ToUtf8Bytes on a binary payload used to
    hand back the bytes as though they were text. It refuses now. }
  Raised := False;
  try Payload.ToUtf8Bytes except on E: ESerializationPayloadKind do Raised := True end;
  Check(Raised, 'PAYLOAD_BINARY_IS_NOT_CALLED_UTF8_TEXT');

  { A binary format will not read text, and says why. }
  Raised := False;
  try
    TSerialization.Convert(Text('{"a":1}'), TSerializationFormat.Bson,
      TSerializationFormat.Json);
  except
    on E: Exception do
    begin
      Raised := True;
      Note(E.Message);
    end;
  end;
  Check(Raised, 'BSON_REFUSES_A_TEXT_SOURCE');
end;

{ ===========================================================================
  4. AFTER A CONVERSION
  =========================================================================== }

procedure TestPostConversionUtf8;
var
  Src, Xml, Json: TSerializationPayload;
  Bytes: TBytes;
  Decoded: string;
begin
  Writeln;
  Writeln('-- UTF-8 after JSON -> XML -> JSON --');

  Src := Text('{"Name":"' + GEO_NAME + '","Country":"' + GEO_COUNTRY +
    '","Address":"' + GEO_ADDRESS + '"}');

  Xml := TSerialization.Convert(Src, TSerializationFormat.Json,
    TSerializationFormat.Xml, TStructuralConversionProfile.Lossless);
  Json := TSerialization.Convert(Xml, TSerializationFormat.Xml,
    TSerializationFormat.Json, TStructuralConversionProfile.Lossless);

  { The natural way to get bytes out of a conversion: convert, then say
    which encoding you want. }
  Bytes := Json.ToUtf8Bytes;
  Check(Length(Bytes) > 0, 'PAYLOAD_CONVERT_THEN_UTF8');
  Check(IndependentUtf8Decode(Bytes, Decoded), 'POST_CONVERSION_JSON_UTF8_VALID');
  Check(ContainsBytes(Bytes, TBytes.Create($E1, $83, $9A)),
    'POST_CONVERSION_JSON_UTF8_GEORGIAN');

  { Readable, not sixteen escape groups. }
  Check(not Has(Decoded, '\u10'), 'POST_CONVERSION_JSON_HUMAN_READABLE_UNICODE');
  Check(Has(Decoded, GEO_NAME) and Has(Decoded, GEO_COUNTRY) and
        Has(Decoded, GEO_ADDRESS), 'JSON_XML_JSON_UTF8_GEORGIAN');

  { The same document, decoded independently and parsed by the RTL. }
  Check(TJSONObject.ParseJSONValue(Decoded) <> nil,
    'POST_CONVERSION_PARSES_INDEPENDENTLY');

  Xml := TSerialization.Convert(Src, TSerializationFormat.Json,
    TSerializationFormat.Xml);
  Check(IndependentUtf8Decode(Xml.ToUtf8Bytes, Decoded) and
        Has(Decoded, GEO_ADDRESS), 'XML_UTF8_GEORGIAN_AFTER_CONVERSION');
end;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TJsonSerializationRegistration.RegisterFormat;
  TXmlSerializationRegistration.RegisterFormat;
  TBsonSerializationRegistration.RegisterFormat;
  try
    TestConversionIsLossless;
    TestJsonEscaping;
    TestUtf8;
    TestPostConversionUtf8;
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
    Writeln('UNICODE_UTF8: PASS')
  else
  begin
    Writeln('UNICODE_UTF8: FAIL');
    ExitCode := 1;
  end;
end.
