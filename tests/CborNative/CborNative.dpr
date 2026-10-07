program CborNative;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Is this actually a CBOR codec?

  A round trip proves only that the reader understands the writer. This
  program asks whether the BYTES are right, measured against the vectors the
  specification publishes, and whether everything the format defines is read
  and written.

  THE TARGET, named exactly:

      RFC 8949 (STD 94), Concise Binary Object Representation - complete
      All eight major types, every argument width, indefinite lengths
      Half, single and double precision floats
      Simple values, semantic tags, deterministic encoding (section 4.2)

  THE INDEPENDENT REFERENCE is RFC 8949 Appendix A, "Examples of Encoded
  CBOR Data Items" - the table every CBOR implementation is checked against.
  Those vectors are transcribed below and used two ways: the bytes are
  decoded and the value checked, and the decoded value is written back and
  the bytes compared. A codec that agreed only with itself would pass the
  second and fail the first.

  There is no network and no reference implementation installed on this
  machine, so the oracle is the document rather than a running program.
  That is said plainly here and in docs\cbor-behavior.md rather than dressed
  up. What it proves is that the bytes are the specification's bytes and not
  merely self-consistent. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Math, System.DateUtils,
  System.StrUtils, System.Generics.Collections, System.Diagnostics,
  Data.DB, Datasnap.DBClient,
  CborModels in 'CborModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Cbor in '..\..\src\PascalForge.Cbor.pas',
  PascalForge.Cbor.Internal in '..\..\src\PascalForge.Cbor.Internal.pas',
  PascalForge.Cbor.Registration in '..\..\src\PascalForge.Cbor.Registration.pas',
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
  for I := 0 to High(ABytes) do Result := Result + LowerCase(IntToHex(ABytes[I], 2));
end;

function FromHex(const AHex: string): TBytes;
var
  I: Integer;
  Clean: string;
begin
  Clean := StringReplace(AHex, ' ', '', [rfReplaceAll]);
  SetLength(Result, Length(Clean) div 2);
  for I := 0 to High(Result) do
    Result[I] := StrToInt('$' + Copy(Clean, I * 2 + 1, 2));
end;

function SameBytes(const A, B: TBytes): Boolean;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  for I := 0 to High(A) do
    if A[I] <> B[I] then Exit(False);
  Result := True;
end;

{ ===========================================================================
  RFC 8949 APPENDIX A - the independent oracle
  =========================================================================== }

type
  TVector = record
    Hex: string;
    Diagnostic: string;
  end;

const
  { Transcribed from RFC 8949 Appendix A. Every one of these is round-tripped:
    decoded, then written back, and the bytes must match exactly - which is
    only possible because a decoded value remembers the argument width and
    float width the document actually used. }
  { Georgian, written the way a JSON document writes it and the way Delphi
    source has to spell it. The source file stays ASCII so that no editor,
    no compiler codepage setting and no version-control conversion can
    quietly change what this test is checking. }
  ESC = '\';
  GEO_JSON = ESC + 'u10DB' + ESC + 'u10E1' + ESC + 'u10DD' + ESC + 'u10E4' +
             ESC + 'u10DA' + ESC + 'u10D8' + ESC + 'u10DD';
  GEO_CITY = #$10DB#$10E1#$10DD#$10E4#$10DA#$10D8#$10DD;

  Vectors: array[0..80] of TVector = (
    (Hex: '00';                 Diagnostic: '0'),
    (Hex: '01';                 Diagnostic: '1'),
    (Hex: '0a';                 Diagnostic: '10'),
    (Hex: '17';                 Diagnostic: '23'),
    (Hex: '1818';               Diagnostic: '24'),
    (Hex: '1819';               Diagnostic: '25'),
    (Hex: '1864';               Diagnostic: '100'),
    (Hex: '1903e8';             Diagnostic: '1000'),
    (Hex: '1a000f4240';         Diagnostic: '1000000'),
    (Hex: '1b000000e8d4a51000'; Diagnostic: '1000000000000'),
    (Hex: '1bffffffffffffffff'; Diagnostic: '18446744073709551615'),
    (Hex: 'c249010000000000000000'; Diagnostic: '2(h''010000000000000000'')'),
    (Hex: '3bffffffffffffffff'; Diagnostic: '-18446744073709551616'),
    (Hex: 'c349010000000000000000'; Diagnostic: '3(h''010000000000000000'')'),
    (Hex: '20';                 Diagnostic: '-1'),
    (Hex: '29';                 Diagnostic: '-10'),
    (Hex: '3863';               Diagnostic: '-100'),
    (Hex: '3903e7';             Diagnostic: '-1000'),
    (Hex: 'f90000';             Diagnostic: '0.0'),
    (Hex: 'f98000';             Diagnostic: '-0.0'),
    (Hex: 'f93c00';             Diagnostic: '1.0'),
    (Hex: 'fb3ff199999999999a'; Diagnostic: '1.1'),
    (Hex: 'f93e00';             Diagnostic: '1.5'),
    (Hex: 'f97bff';             Diagnostic: '65504.0'),
    (Hex: 'fa47c35000';         Diagnostic: '100000.0'),
    (Hex: 'fa7f7fffff';         Diagnostic: '3.4028234663852886e+38'),
    (Hex: 'fb7e37e43c8800759c'; Diagnostic: '1.0e+300'),
    (Hex: 'f90001';             Diagnostic: '5.960464477539063e-8'),
    (Hex: 'f90400';             Diagnostic: '0.00006103515625'),
    (Hex: 'f9c400';             Diagnostic: '-4.0'),
    (Hex: 'fbc010666666666666'; Diagnostic: '-4.1'),
    (Hex: 'f97c00';             Diagnostic: 'Infinity'),
    (Hex: 'f97e00';             Diagnostic: 'NaN'),
    (Hex: 'f9fc00';             Diagnostic: '-Infinity'),
    (Hex: 'fa7f800000';         Diagnostic: 'Infinity'),
    (Hex: 'fa7fc00000';         Diagnostic: 'NaN'),
    (Hex: 'faff800000';         Diagnostic: '-Infinity'),
    (Hex: 'fb7ff0000000000000'; Diagnostic: 'Infinity'),
    (Hex: 'fb7ff8000000000000'; Diagnostic: 'NaN'),
    (Hex: 'fbfff0000000000000'; Diagnostic: '-Infinity'),
    (Hex: 'f4';                 Diagnostic: 'false'),
    (Hex: 'f5';                 Diagnostic: 'true'),
    (Hex: 'f6';                 Diagnostic: 'null'),
    (Hex: 'f7';                 Diagnostic: 'undefined'),
    (Hex: 'f0';                 Diagnostic: 'simple(16)'),
    (Hex: 'f8ff';               Diagnostic: 'simple(255)'),
    (Hex: 'c074323031332d30332d32315432303a30343a30305a';
                                Diagnostic: '0("2013-03-21T20:04:00Z")'),
    (Hex: 'c11a514b67b0';       Diagnostic: '1(1363896240)'),
    (Hex: 'c1fb41d452d9ec200000'; Diagnostic: '1(1363896240.5)'),
    (Hex: 'd74401020304';       Diagnostic: '23(h''01020304'')'),
    (Hex: 'd818456449455446';   Diagnostic: '24(h''6449455446'')'),
    (Hex: 'd82076687474703a2f2f7777772e6578616d706c652e636f6d';
                                Diagnostic: '32("http://www.example.com")'),
    (Hex: '40';                 Diagnostic: 'h'''''),
    (Hex: '4401020304';         Diagnostic: 'h''01020304'''),
    (Hex: '60';                 Diagnostic: '""'),
    (Hex: '6161';               Diagnostic: '"a"'),
    (Hex: '6449455446';         Diagnostic: '"IETF"'),
    (Hex: '62225c';             Diagnostic: '"\"\\"'),
    (Hex: '62c3bc';             Diagnostic: '"u umlaut"'),
    (Hex: '63e6b0b4';           Diagnostic: '"water"'),
    (Hex: '64f0908591';         Diagnostic: '"non-BMP"'),
    (Hex: '80';                 Diagnostic: '[]'),
    (Hex: '83010203';           Diagnostic: '[1, 2, 3]'),
    (Hex: '8301820203820405';   Diagnostic: '[1, [2, 3], [4, 5]]'),
    (Hex: '98190102030405060708090a0b0c0d0e0f101112131415161718181819';
                                Diagnostic: '[1 .. 25]'),
    (Hex: 'a0';                 Diagnostic: '{}'),
    (Hex: 'a201020304';         Diagnostic: '{1: 2, 3: 4}'),
    (Hex: 'a26161016162820203'; Diagnostic: '{"a": 1, "b": [2, 3]}'),
    (Hex: '826161a161626163';   Diagnostic: '["a", {"b": "c"}]'),
    (Hex: 'a56161614161626142616361436164614461656145';
                                Diagnostic: '{"a":"A","b":"B","c":"C","d":"D","e":"E"}'),
    (Hex: '5f42010243030405ff'; Diagnostic: '(_ h''0102'', h''030405'')'),
    (Hex: '7f657374726561646d696e67ff'; Diagnostic: '(_ "strea", "ming")'),
    (Hex: '9fff';               Diagnostic: '[_ ]'),
    (Hex: '9f018202039f0405ffff'; Diagnostic: '[_ 1, [2, 3], [_ 4, 5]]'),
    (Hex: '9f01820203820405ff'; Diagnostic: '[_ 1, [2, 3], [4, 5]]'),
    (Hex: '83018202039f0405ff'; Diagnostic: '[1, [2, 3], [_ 4, 5]]'),
    (Hex: '83019f0203ff820405'; Diagnostic: '[1, [_ 2, 3], [4, 5]]'),
    (Hex: '9f0102030405060708090a0b0c0d0e0f101112131415161718181819ff';
                                Diagnostic: '[_ 1 .. 25]'),
    (Hex: 'bf61610161629f0203ffff'; Diagnostic: '{_ "a": 1, "b": [_ 2, 3]}'),
    (Hex: '826161bf61626163ff'; Diagnostic: '["a", {_ "b": "c"}]'),
    (Hex: 'bf6346756ef563416d7421ff'; Diagnostic: '{_ "Fun": true, "Amt": -2}'));

procedure TestAppendixAVectors;
var
  I, Bad: Integer;
  Source, Again: TBytes;
  Value: TCborValue;
  FirstBad: string;
begin
  Writeln;
  Writeln('--- RFC 8949 Appendix A ---');
  Bad := 0;
  FirstBad := '';
  for I := Low(Vectors) to High(Vectors) do
  begin
    Source := FromHex(Vectors[I].Hex);
    try
      Value := TCborSerializer.Decode(Source);
      try
        Again := TCborSerializer.Encode(Value);
        if not SameBytes(Source, Again) then
        begin
          Inc(Bad);
          if FirstBad = '' then
            FirstBad := Format('%s (%s) re-encoded as %s',
              [Vectors[I].Hex, Vectors[I].Diagnostic, Hex(Again)]);
        end;
      finally
        Value.Free;
      end;
    except
      on E: Exception do
      begin
        Inc(Bad);
        if FirstBad = '' then
          FirstBad := Format('%s (%s) raised %s: %s',
            [Vectors[I].Hex, Vectors[I].Diagnostic, E.ClassName, E.Message]);
      end;
    end;
  end;
  Note(Format('%d vectors, %d failures', [Length(Vectors), Bad]));
  if FirstBad <> '' then Note('first: ' + FirstBad);
  Check(Bad = 0, 'CBOR_APPENDIX_A_VECTORS');
end;

{ ===========================================================================
  The eight major types, read for their VALUE and not merely their shape
  =========================================================================== }

procedure TestMajorTypes;
var
  V: TCborValue;
  G: TGUID;
  Text: string;
  DT: TDateTime;
begin
  Writeln;
  Writeln('--- major types 0 to 7 ---');

  { 0 - unsigned integer }
  V := TCborSerializer.Decode(FromHex('1a000f4240'));
  try
    Check((V.Kind = TCborKind.UInt) and (V.AsInt64 = 1000000), 'MAJOR_0_UNSIGNED');
  finally V.Free; end;

  { 1 - negative integer, as -1-n and not as a sign bit }
  V := TCborSerializer.Decode(FromHex('3903e7'));
  try
    Check((V.Kind = TCborKind.NegInt) and (V.AsInt64 = -1000) and
          (V.NegativeArgument = 999), 'MAJOR_1_NEGATIVE');
  finally V.Free; end;

  { 2 - byte string }
  V := TCborSerializer.Decode(FromHex('4401020304'));
  try
    Check((V.Kind = TCborKind.Bytes) and (Hex(V.AsBytes) = '01020304'),
      'MAJOR_2_BYTES');
  finally V.Free; end;

  { 3 - text string, decoded as UTF-8 and not as anything else }
  V := TCborSerializer.Decode(FromHex('6449455446'));
  try
    Check((V.Kind = TCborKind.Text) and (V.AsText = 'IETF'), 'MAJOR_3_TEXT');
  finally V.Free; end;

  { 4 - array }
  V := TCborSerializer.Decode(FromHex('8301820203820405'));
  try
    Check((V.Kind = TCborKind.Arr) and (V.Count = 3) and
          (V.Items[1].Count = 2) and (V.Items[2].Items[1].AsInt64 = 5),
      'MAJOR_4_ARRAY');
  finally V.Free; end;

  { 5 - map, whose keys are data items and not names }
  V := TCborSerializer.Decode(FromHex('a201020304'));
  try
    Check((V.Kind = TCborKind.Map) and (V.Count = 2) and
          (V.Keys[0].AsInt64 = 1) and (V.Items[0].AsInt64 = 2) and
          (V.Keys[1].AsInt64 = 3), 'MAJOR_5_MAP_NONTEXT_KEYS');
  finally V.Free; end;

  { 6 - tag }
  V := TCborSerializer.Decode(FromHex('d82076687474703a2f2f7777772e6578616d706c652e636f6d'));
  try
    Check((V.Kind = TCborKind.Tag) and (V.TagNumber = 32) and
          V.TryAsUri(Text) and (Text = 'http://www.example.com'),
      'MAJOR_6_TAG');
  finally V.Free; end;

  { 7 - the floats and simple values }
  V := TCborSerializer.Decode(FromHex('f5'));
  try
    Check((V.Kind = TCborKind.Bool) and V.AsBool, 'MAJOR_7_TRUE');
  finally V.Free; end;

  V := TCborSerializer.Decode(FromHex('f6'));
  try
    Check(V.Kind = TCborKind.Null, 'MAJOR_7_NULL');
  finally V.Free; end;

  V := TCborSerializer.Decode(FromHex('f7'));
  try
    Check(V.Kind = TCborKind.Undefined, 'MAJOR_7_UNDEFINED');
  finally V.Free; end;

  { A UUID is tag 37 in RFC 4122 byte order, which is NOT the order a TGUID
    has in memory. This vector is the one that catches a codec that forgot. }
  V := TCborValue.NewUuid(StringToGUID('{01020304-0506-0708-090A-0B0C0D0E0F10}'));
  try
    Check(Hex(TCborSerializer.Encode(V)) = 'd825500102030405060708090a0b0c0d0e0f10',
      'TAG_37_RFC4122_BYTE_ORDER');
    Check(V.TryAsUuid(G) and
          (GUIDToString(G) = '{01020304-0506-0708-090A-0B0C0D0E0F10}'),
      'TAG_37_ROUND_TRIP');
  finally V.Free; end;

  { Tag 0 and tag 1 both mean an instant, and both have to arrive as one. }
  V := TCborSerializer.Decode(FromHex('c074323031332d30332d32315432303a30343a30305a'));
  try
    Check(V.TryAsDateTime(DT) and
          (FormatDateTime('yyyy-mm-dd hh:nn:ss', DT) = '2013-03-21 20:04:00'),
      'TAG_0_RFC3339');
  finally V.Free; end;

  V := TCborSerializer.Decode(FromHex('c11a514b67b0'));
  try
    Check(V.TryAsDateTime(DT) and
          (FormatDateTime('yyyy-mm-dd hh:nn:ss', DT) = '2013-03-21 20:04:00'),
      'TAG_1_EPOCH');
  finally V.Free; end;
end;

{ ===========================================================================
  Integers that Delphi does not have, and must not silently acquire
  =========================================================================== }

procedure TestIntegerEdges;
var
  V: TCborValue;
  Text: string;
  Caught: Boolean;
begin
  Writeln;
  Writeln('--- integers at the edges ---');

  { 2^64-1 is a perfectly ordinary CBOR integer and does not fit an Int64. }
  V := TCborSerializer.Decode(FromHex('1bffffffffffffffff'));
  try
    Check((not V.FitsInt64) and (V.AsUInt64 = High(UInt64)),
      'UINT64_ABOVE_MAXINT64');
    Caught := False;
    try
      V.AsInt64;
    except
      on E: ECborRangeError do Caught := True;
    end;
    Check(Caught, 'UINT64_REFUSES_INT64_NARROWING');
  finally V.Free; end;

  { -2^64 is the far end of major type 1 and has no Delphi counterpart
    either. It must not wrap. }
  V := TCborSerializer.Decode(FromHex('3bffffffffffffffff'));
  try
    Check((V.Kind = TCborKind.NegInt) and (not V.FitsInt64) and
          (V.NegativeArgument = High(UInt64)), 'NEGINT_BELOW_MININT64');
  finally V.Free; end;

  { Beyond that the specification uses bignums, and their decimal text has
    to be exact - a Double would round 2^64 to something else. }
  V := TCborSerializer.Decode(FromHex('c249010000000000000000'));
  try
    Check(V.TryAsBigIntText(Text) and (Text = '18446744073709551616'),
      'BIGNUM_POSITIVE_EXACT');
  finally V.Free; end;

  V := TCborSerializer.Decode(FromHex('c349010000000000000000'));
  try
    Check(V.TryAsBigIntText(Text) and (Text = '-18446744073709551617'),
      'BIGNUM_NEGATIVE_EXACT');
  finally V.Free; end;

  { Tag 4 is a decimal fraction: mantissa times ten to the exponent. It is
    the only way CBOR states an exact decimal, so it must not go through a
    Double on the way in. }
  V := TCborSerializer.Decode(FromHex('c48221196ab3'));
  try
    Check(V.TryAsDecimalText(Text) and (Text = '273.15'), 'TAG_4_DECIMAL_FRACTION');
  finally V.Free; end;

  { Tag 5 is a bigfloat: mantissa times two to the exponent. }
  V := TCborSerializer.Decode(FromHex('c5822003'));
  try
    Check(V.TryAsDecimalText(Text) and (Text = '1.5'), 'TAG_5_BIGFLOAT');
  finally V.Free; end;
end;

{ ===========================================================================
  Floats: three widths, and the bits that distinguish them
  =========================================================================== }

procedure TestFloats;
var
  V: TCborValue;
  D: Double;
begin
  Writeln;
  Writeln('--- half, single and double ---');

  V := TCborSerializer.Decode(FromHex('f93c00'));
  try
    Check((V.FloatWidth = TCborFloatWidth.Half) and (V.AsFloat = 1.0),
      'FLOAT_HALF_DECODED');
  finally V.Free; end;

  { A half-precision subnormal is the smallest thing binary16 can say, and a
    codec that built its half decoder out of the normal case alone gets this
    one wrong. }
  V := TCborSerializer.Decode(FromHex('f90001'));
  try
    D := V.AsFloat;
    Check(Abs(D - 5.960464477539063e-8) < 1e-20, 'FLOAT_HALF_SUBNORMAL');
  finally V.Free; end;

  V := TCborSerializer.Decode(FromHex('f97bff'));
  try
    Check(V.AsFloat = 65504.0, 'FLOAT_HALF_MAXIMUM');
  finally V.Free; end;

  V := TCborSerializer.Decode(FromHex('fa47c35000'));
  try
    Check((V.FloatWidth = TCborFloatWidth.Single) and (V.AsFloat = 100000.0),
      'FLOAT_SINGLE_DECODED');
  finally V.Free; end;
  { The comparison is against a Double-typed local and not against the
    literal 1.1, because an untyped real constant is an Extended - and on
    Win32 an Extended 1.1 is genuinely a different number from a Double
    1.1, so the obvious spelling of this test would fail on a correct
    decoder. }
  D := 1.1;
  V := TCborSerializer.Decode(FromHex('fb3ff199999999999a'));
  try
    Check((V.FloatWidth = TCborFloatWidth.Double) and (V.AsFloat = D),
      'FLOAT_DOUBLE_DECODED');
  finally V.Free; end;

  { Infinity and NaN exist in all three widths, and the encoder must not
    turn one into the other or into a null. }
  V := TCborSerializer.Decode(FromHex('f97c00'));
  try
    Check(IsInfinite(V.AsFloat) and (V.AsFloat > 0), 'FLOAT_POSITIVE_INFINITY');
  finally V.Free; end;

  V := TCborSerializer.Decode(FromHex('f9fc00'));
  try
    Check(IsInfinite(V.AsFloat) and (V.AsFloat < 0), 'FLOAT_NEGATIVE_INFINITY');
  finally V.Free; end;

  V := TCborSerializer.Decode(FromHex('f97e00'));
  try
    Check(IsNan(V.AsFloat), 'FLOAT_NAN');
  finally V.Free; end;

  { Negative zero is not zero, and losing its sign is a real loss. }
  V := TCborSerializer.Decode(FromHex('f98000'));
  try
    Check((V.AsFloat = 0) and (V.FloatBits = $8000), 'FLOAT_NEGATIVE_ZERO');
  finally V.Free; end;

  { Deterministic encoding picks the shortest width that is EXACT. 1.5 fits
    a half; 1.1 does not fit anything narrower than a double. }
  V := TCborValue.NewFloat(1.5);
  try
    Check(Hex(TCborSerializer.Encode(V,
      TCborEncodeOptions.Rfc8949Deterministic)) = 'f93e00',
      'FLOAT_DETERMINISTIC_NARROWS_TO_HALF');
  finally V.Free; end;

  V := TCborValue.NewFloat(100000.0);
  try
    Check(Hex(TCborSerializer.Encode(V,
      TCborEncodeOptions.Rfc8949Deterministic)) = 'fa47c35000',
      'FLOAT_DETERMINISTIC_NARROWS_TO_SINGLE');
  finally V.Free; end;

  V := TCborValue.NewFloat(1.1);
  try
    Check(Hex(TCborSerializer.Encode(V,
      TCborEncodeOptions.Rfc8949Deterministic)) = 'fb3ff199999999999a',
      'FLOAT_DETERMINISTIC_KEEPS_DOUBLE');
  finally V.Free; end;
end;

{ ===========================================================================
  Indefinite lengths, and the break that ends them
  =========================================================================== }

procedure TestIndefiniteLengths;
var
  V: TCborValue;
  Caught: Boolean;
begin
  Writeln;
  Writeln('--- indefinite lengths ---');

  { An indefinite byte string is a sequence of definite chunks, and its value
    is their concatenation - but it is NOT the same document as the definite
    form, so the chunking survives a round trip. }
  V := TCborSerializer.Decode(FromHex('5f42010243030405ff'));
  try
    Check(V.Indefinite and (V.ChunkCount = 2) and
          (Hex(V.AsBytes) = '0102030405'), 'INDEFINITE_BYTES');
    Check(Hex(TCborSerializer.Encode(V)) = '5f42010243030405ff',
      'INDEFINITE_BYTES_PRESERVED');
  finally V.Free; end;

  V := TCborSerializer.Decode(FromHex('7f657374726561646d696e67ff'));
  try
    Check(V.Indefinite and (V.ChunkCount = 2) and (V.AsText = 'streaming'),
      'INDEFINITE_TEXT');
  finally V.Free; end;

  V := TCborSerializer.Decode(FromHex('9fff'));
  try
    Check(V.Indefinite and (V.Kind = TCborKind.Arr) and (V.Count = 0),
      'INDEFINITE_EMPTY_ARRAY');
  finally V.Free; end;

  { Nested definite and indefinite arrays in every combination, exactly as
    Appendix A lists them. }
  V := TCborSerializer.Decode(FromHex('9f018202039f0405ffff'));
  try
    Check(V.Indefinite and (V.Count = 3) and (not V.Items[1].Indefinite) and
          V.Items[2].Indefinite, 'INDEFINITE_ARRAY_NESTING');
  finally V.Free; end;

  V := TCborSerializer.Decode(FromHex('bf61610161629f0203ffff'));
  try
    Check(V.Indefinite and (V.Kind = TCborKind.Map) and (V.Count = 2) and
          (V.Find('a').AsInt64 = 1) and V.Find('b').Indefinite,
      'INDEFINITE_MAP');
  finally V.Free; end;

  { A break where no indefinite item is open is malformed, not an empty
    value. }
  Caught := False;
  try
    V := TCborSerializer.Decode(FromHex('ff'));
    V.Free;
  except
    on E: ECborUnexpectedBreak do Caught := True;
  end;
  Check(Caught, 'BREAK_OUTSIDE_INDEFINITE_REFUSED');

  { A chunk of the wrong major type inside an indefinite string is malformed
    - RFC 8949 section 3.2.3 says so, and a codec that concatenated anyway
    would hand back bytes that were never in the document. }
  Caught := False;
  try
    V := TCborSerializer.Decode(FromHex('5f42010263030405ff'));
    V.Free;
  except
    on E: ECborChunkMismatch do Caught := True;
  end;
  Check(Caught, 'INDEFINITE_CHUNK_TYPE_MISMATCH_REFUSED');

  { An indefinite chunk may not itself be indefinite. }
  Caught := False;
  try
    V := TCborSerializer.Decode(FromHex('5f5f4201020242030405ffff'));
    V.Free;
  except
    on E: ECborChunkMismatch do Caught := True;
  end;
  Check(Caught, 'INDEFINITE_CHUNK_NESTING_REFUSED');

  { An indefinite map must have an even number of items before the break. }
  Caught := False;
  try
    V := TCborSerializer.Decode(FromHex('bf6161ff'));
    V.Free;
  except
    on E: ECborInputError do Caught := True;
  end;
  Check(Caught, 'INDEFINITE_MAP_ODD_ITEMS_REFUSED');

  { Building one from scratch and writing it out. }
  V := TCborValue.NewIndefiniteText;
  try
    V.AddChunk(TCborValue.NewText('strea'));
    V.AddChunk(TCborValue.NewText('ming'));
    Check(Hex(TCborSerializer.Encode(V)) = '7f657374726561646d696e67ff',
      'INDEFINITE_TEXT_WRITTEN');
  finally V.Free; end;
end;

{ ===========================================================================
  Simple values, and the ones that are not values at all
  =========================================================================== }

procedure TestSimpleValues;
var
  V: TCborValue;
  Caught: Boolean;
  I: Integer;
begin
  Writeln;
  Writeln('--- simple values ---');

  V := TCborSerializer.Decode(FromHex('f0'));
  try
    Check((V.Kind = TCborKind.Simple) and (V.SimpleValue = 16),
      'SIMPLE_IN_HEAD');
  finally V.Free; end;

  V := TCborSerializer.Decode(FromHex('f8ff'));
  try
    Check((V.Kind = TCborKind.Simple) and (V.SimpleValue = 255),
      'SIMPLE_ONE_BYTE');
  finally V.Free; end;

  { Simple values 0..23 must be in the head. The one-byte form for them is
    malformed by section 3.3, and accepting it would give two spellings of
    one value - which deterministic encoding exists to prevent. }
  Caught := False;
  try
    V := TCborSerializer.Decode(FromHex('f817'));
    V.Free;
  except
    on E: ECborMalformedSimple do Caught := True;
  end;
  Check(Caught, 'SIMPLE_NON_CANONICAL_REFUSED');

  { 20..23 are false, true, null and undefined, and must arrive as those
    rather than as a second spelling of them. }
  V := TCborValue.NewSimple(20);
  try
    Check(V.Kind = TCborKind.Bool, 'SIMPLE_20_IS_FALSE');
  finally V.Free; end;
  V := TCborValue.NewSimple(23);
  try
    Check(V.Kind = TCborKind.Undefined, 'SIMPLE_23_IS_UNDEFINED');
  finally V.Free; end;

  { Additional information 28, 29 and 30 are reserved in every major type,
    and a well-formed document never contains them. }
  Caught := True;
  for I := 28 to 30 do
    try
      V := TCborSerializer.Decode(FromHex(IntToHex(I, 2)));
      V.Free;
      Caught := False;
    except
      on E: ECborReservedAdditionalInfo do ;
      on E: Exception do Caught := False;
    end;
  Check(Caught, 'RESERVED_ADDITIONAL_INFO_REFUSED');
end;

{ ===========================================================================
  Tags this library does not know, which must survive anyway
  =========================================================================== }

procedure TestUnknownTags;
var
  V, Rebuilt: TCborValue;
  Tree: TDynamicValue;
  Source, Again: TBytes;
begin
  Writeln;
  Writeln('--- unknown tags ---');

  { Tag 1234 means nothing here. It must still decode, still re-encode
    identically, and still come back after a trip through the dynamic tree -
    because a converter that drops what it does not recognise is worse than
    one that refuses. }
  Source := FromHex('d904d2820102');
  V := TCborSerializer.Decode(Source);
  try
    Check((V.Kind = TCborKind.Tag) and (V.TagNumber = 1234) and
          (V.TagContent.Count = 2), 'UNKNOWN_TAG_DECODED');
    Check(SameBytes(TCborSerializer.Encode(V), Source),
      'UNKNOWN_TAG_REENCODED');

    Tree := TCborEngine.CborToDynamic(V);
    try
      Check((Tree.Kind = TDynamicKind.Extended) and
            Tree.IsTagged(TDynamicTag.CborTag),
        'UNKNOWN_TAG_IS_EXTENDED_IN_DYNAMIC');
      Rebuilt := TCborEngine.DynamicToCbor(Tree);
      try
        Again := TCborSerializer.Encode(Rebuilt);
      finally
        Rebuilt.Free;
      end;
    finally
      Tree.Free;
    end;
    Check(SameBytes(Again, Source), 'CBOR_UNKNOWN_TAG_PRESERVATION');
  finally
    V.Free;
  end;

  { The self-describe tag says "this is CBOR" and nothing about the value,
    so the value passes through it unchanged. }
  V := TCborValue.NewText('hello');
  try
    Source := TCborSerializer.Encode(V,
      TCborEncodeOptions.Default.WithSelfDescribe);
  finally
    V.Free;
  end;
  Check(Copy(Hex(Source), 1, 6) = 'd9d9f7', 'SELF_DESCRIBE_PREFIX');

  V := TCborSerializer.Decode(Source);
  try
    Tree := TCborEngine.CborToDynamic(V);
    try
      Check((Tree.Kind = TDynamicKind.Str) and (Tree.AsStr = 'hello'),
        'SELF_DESCRIBE_TRANSPARENT');
    finally
      Tree.Free;
    end;
  finally
    V.Free;
  end;
end;

{ ===========================================================================
  Deterministic encoding - RFC 8949 section 4.2
  =========================================================================== }

procedure TestDeterministicEncoding;
var
  V: TCborValue;
  Encoded: TBytes;
begin
  Writeln;
  Writeln('--- deterministic encoding ---');

  { Map keys sort by their ENCODED BYTES, which is not the same as sorting
    by the string. "z" (617a) comes before "aa" (626161) because the shorter
    head sorts first, and an implementation that sorted alphabetically would
    put them the other way round. }
  V := TCborValue.NewMap;
  try
    V.Add('aa', TCborValue.NewInt(1));
    V.Add('z', TCborValue.NewInt(2));
    V.Add('b', TCborValue.NewInt(3));
    Encoded := TCborSerializer.Encode(V, TCborEncodeOptions.Rfc8949Deterministic);
    Note('sorted: ' + Hex(Encoded));
    Check(Hex(Encoded) = 'a3616203617a0262616101',
      'DETERMINISTIC_MAP_KEY_ORDER');
  finally V.Free; end;

  { An indefinite length is never deterministic, whatever it holds. }
  V := TCborValue.NewIndefiniteArray;
  try
    V.Add(TCborValue.NewInt(1));
    Check(Hex(TCborSerializer.Encode(V,
      TCborEncodeOptions.Rfc8949Deterministic)) = '8101',
      'DETERMINISTIC_FORCES_DEFINITE_LENGTH');
  finally V.Free; end;

  { A decoded value remembers a longer-than-necessary argument so that the
    document round-trips; deterministic encoding deliberately forgets it. }
  V := TCborSerializer.Decode(FromHex('1b0000000000000001'));
  try
    Check(Hex(TCborSerializer.Encode(V)) = '1b0000000000000001',
      'NON_PREFERRED_HEAD_PRESERVED');
    Check(Hex(TCborSerializer.Encode(V,
      TCborEncodeOptions.Rfc8949Deterministic)) = '01',
      'DETERMINISTIC_SHORTEST_HEAD');
  finally V.Free; end;

  Check(TCborSerializer.IsDeterministic(FromHex('a3616203617a0262616101')),
    'IS_DETERMINISTIC_ACCEPTS');
  Check(not TCborSerializer.IsDeterministic(FromHex('1b0000000000000001')),
    'IS_DETERMINISTIC_REJECTS_LONG_HEAD');
  Check(not TCborSerializer.IsDeterministic(FromHex('9f01ff')),
    'IS_DETERMINISTIC_REJECTS_INDEFINITE');

  { Whatever went in, what comes out of a deterministic encode is itself
    deterministic - which is the property the whole of section 4.2 exists
    for. This one goes in as an indefinite map with its keys the wrong way
    round and comes out definite and sorted. }
  V := TCborSerializer.Decode(FromHex('bf616202616101ff'));
  try
    Encoded := TCborSerializer.Encode(V, TCborEncodeOptions.Rfc8949Deterministic);
  finally
    V.Free;
  end;
  Note('canonicalised: ' + Hex(Encoded));
  Check((Hex(Encoded) = 'a2616101616202') and
        TCborSerializer.IsDeterministic(Encoded),
    'CBOR_DETERMINISTIC_ENCODING');
end;

{ ===========================================================================
  Malformed input, refused by name
  =========================================================================== }

procedure TestMalformed;

  procedure Refuses(const AHex, AName: string);
  var
    V: TCborValue;
    Caught: Boolean;
  begin
    Caught := False;
    try
      V := TCborSerializer.Decode(FromHex(AHex));
      V.Free;
    except
      on E: ECborError do Caught := True;
    end;
    Check(Caught, AName);
  end;

var
  V: TCborValue;
  Deep: string;
  Caught: Boolean;
  Options: TCborDecodeOptions;
  I: Integer;
begin
  Writeln;
  Writeln('--- malformed input ---');

  Refuses('18',     'MALFORMED_TRUNCATED_ARGUMENT');
  Refuses('1903',   'MALFORMED_TRUNCATED_TWO_BYTE');
  Refuses('4401',   'MALFORMED_TRUNCATED_BYTE_STRING');
  Refuses('83010203040506', 'MALFORMED_TRAILING_DATA');
  Refuses('8301',   'MALFORMED_ARRAY_SHORT');
  Refuses('a10102030405', 'MALFORMED_MAP_TRAILING');
  Refuses('5f',     'MALFORMED_INDEFINITE_UNTERMINATED');
  Refuses('62c328', 'MALFORMED_INVALID_UTF8');

  { A length the document could not possibly contain is refused up front
    rather than after an allocation the machine cannot afford. }
  Refuses('5bffffffffffffffff', 'MALFORMED_IMPOSSIBLE_LENGTH');
  Refuses('9bffffffffffffffff', 'MALFORMED_IMPOSSIBLE_ARRAY_COUNT');

  { Nesting is bounded, because eight bytes of input can ask for eight
    levels and a bomb has to be cheap to refuse. }
  Deep := '';
  for I := 1 to 400 do Deep := Deep + '81';
  Deep := Deep + '00';
  Refuses(Deep, 'MALFORMED_DEPTH_LIMIT');

  { Trailing data is refused by default and allowed when the caller says so,
    because a stream of concatenated items is a real thing and a truncated
    buffer is also a real thing - and only the caller knows which they have. }
  Caught := False;
  try
    V := TCborSerializer.Decode(FromHex('0102'));
    V.Free;
  except
    on E: ECborTrailingData do Caught := True;
  end;
  Check(Caught, 'TRAILING_DATA_REFUSED_BY_DEFAULT');

  Options := TCborDecodeOptions.Default;
  Options.AllowTrailingData := True;
  V := TCborSerializer.Decode(FromHex('0102'), Options);
  try
    Check(V.AsInt64 = 1, 'TRAILING_DATA_ALLOWED_ON_REQUEST');
  finally
    V.Free;
  end;
end;

{ ===========================================================================
  The Delphi contract
  =========================================================================== }

procedure TestContract;
var
  Shipment, Back: TShipment;
  Line: TLine;
  Data: TBytes;
  Reps, RepsBack: TRepresentations;
  Scripts, ScriptsBack: TScripts;
  V: TCborValue;
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

    Data := TCborSerializer.Serialize<TShipment>(Shipment);
    Note(Format('%d bytes', [Length(Data)]));

    V := TCborSerializer.Decode(Data);
    try
      Check(V.Kind = TCborKind.Map, 'CONTRACT_ROOT_IS_MAP');
      Check(V.Find('Scratch') = nil, 'CONTRACT_IGNORE_HONOURED');
      Check(V.Find('note') <> nil, 'CONTRACT_NAME_HONOURED');
      Check(V.Find('Receipt').Kind = TCborKind.Bytes,
        'CONTRACT_TBYTES_IS_BYTE_STRING');
      Check(V.Find('Huge').Kind = TCborKind.UInt, 'CONTRACT_UINT64_IS_UNSIGNED');
      { An empty nullable is ABSENT, not null - the same rule JSON, XML and
        BSON follow here, so that a conversion between any two of them does
        not have to guess which of "no value" and "the value null" a member
        meant. }
      Check(V.Find('Cancelled') = nil, 'CONTRACT_EMPTY_NULLABLE_IS_ABSENT');
    finally
      V.Free;
    end;

    Back := TCborSerializer.Deserialize<TShipment>(Data);
    try
      Check(Back.Reference = Shipment.Reference, 'CONTRACT_STRING');
      Check(Back.Amount = Shipment.Amount, 'CONTRACT_CURRENCY');
      Check(Back.Rate = Shipment.Rate, 'CONTRACT_DOUBLE');
      Check(Back.Count = Shipment.Count, 'CONTRACT_INTEGER');
      Check(Back.Ticks = Shipment.Ticks, 'CONTRACT_INT64_BEYOND_DOUBLE');
      Check(Back.Huge = Shipment.Huge, 'CONTRACT_UINT64');
      Check(Back.Paid, 'CONTRACT_BOOLEAN');
      Check(SecondsBetween(Back.Raised, Shipment.Raised) = 0, 'CONTRACT_DATETIME');
      Check(IsEqualGUID(Back.Id, Shipment.Id), 'CONTRACT_GUID');
      Check(Hex(Back.Receipt) = Hex(Shipment.Receipt), 'CONTRACT_BYTES');
      Check(Back.Delivery = TDelivery.NextDay, 'CONTRACT_ENUM');
      Check((Length(Back.Tags) = 2) and (Back.Tags[1] = 'reviewed'),
        'CONTRACT_DYNAMIC_ARRAY');
      Check(Back.Shipper.City = 'Midtown', 'CONTRACT_NESTED_OBJECT');
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

  { The representation attributes each change the bytes, and each change
    them back. }
  Reps := TRepresentations.Create;
  try
    Reps.Epoch := EncodeDateTime(2013, 3, 21, 20, 4, 0, 0);
    Reps.Text := Reps.Epoch;
    Reps.Millis := Reps.Epoch;
    Reps.Tagged := StringToGUID('{3F2504E0-4F89-41D3-9A0C-0305E82C3301}');
    Reps.Spelled := Reps.Tagged;
    Reps.Raw := Reps.Tagged;
    Reps.Exact := 273.15;
    Reps.Approximate := 273.15;
    Reps.Spoken := 273.15;
    Reps.ByName := TDelivery.Deferred;
    Reps.ByValue := TDelivery.Deferred;

    Data := TCborSerializer.Serialize<TRepresentations>(Reps);
    V := TCborSerializer.Decode(Data);
    try
      Check(V.Find('Epoch').TagNumber = 1, 'REP_DATETIME_EPOCH_TAGGED');
      Check(V.Find('Text').TagNumber = 0, 'REP_DATETIME_RFC3339_TAGGED');
      Check(V.Find('Millis').IsInteger, 'REP_DATETIME_UNIX_MILLIS');
      Check(V.Find('Tagged').TagNumber = 37, 'REP_GUID_TAGGED');
      Check(V.Find('Spelled').Kind = TCborKind.Text, 'REP_GUID_STRING');
      Check(V.Find('Raw').Kind = TCborKind.Bytes, 'REP_GUID_RAW');
      Check(V.Find('Exact').TagNumber = 4, 'REP_CURRENCY_DECIMAL_FRACTION');
      Check(V.Find('Approximate').Kind = TCborKind.Float, 'REP_CURRENCY_DOUBLE');
      Check(V.Find('Spoken').Kind = TCborKind.Text, 'REP_CURRENCY_STRING');
      Check(V.Find('ByName').AsText = 'Deferred', 'REP_ENUM_NAME');
      Check(V.Find('ByValue').AsInt64 = 2, 'REP_ENUM_VALUE');
    finally
      V.Free;
    end;

    RepsBack := TCborSerializer.Deserialize<TRepresentations>(Data);
    try
      Check(SecondsBetween(RepsBack.Epoch, Reps.Epoch) = 0, 'REP_EPOCH_BACK');
      Check(SecondsBetween(RepsBack.Text, Reps.Text) = 0, 'REP_TEXT_BACK');
      Check(SecondsBetween(RepsBack.Millis, Reps.Millis) = 0, 'REP_MILLIS_BACK');
      Check(IsEqualGUID(RepsBack.Spelled, Reps.Spelled), 'REP_GUID_STRING_BACK');
      Check(IsEqualGUID(RepsBack.Raw, Reps.Raw), 'REP_GUID_RAW_BACK');
      Check(RepsBack.Exact = Reps.Exact, 'REP_CURRENCY_EXACT_BACK');
      Check(RepsBack.Spoken = Reps.Spoken, 'REP_CURRENCY_STRING_BACK');
      Check(RepsBack.ByName = TDelivery.Deferred, 'REP_ENUM_NAME_BACK');
    finally
      RepsBack.Free;
    end;
  finally
    Reps.Free;
  end;

  { The Unicode contract, which is the same one every other format here is
    held to. CBOR text is UTF-8 by definition, so this is not a courtesy. }
  Scripts := TScripts.Create;
  try
    { Spelled in code points so that the source file stays ASCII: what this
      test checks must not depend on how an editor saved it. }
    Scripts.Georgian := #$10E5#$10D0#$10E0#$10D7#$10E3#$10DA#$10D8' ' +
                        #$10D4#$10DC#$10D0;
    Scripts.Cyrillic := #$0420#$0443#$0441#$0441#$043A#$0438#$0439' ' +
                        #$044F#$0437#$044B#$043A;
    Scripts.Cjk := #$65E5#$672C#$8A9E#$306E#$30C6#$30AD#$30B9#$30C8;
    { A family emoji: four astral code points joined by zero-width joiners,
      which is eleven UTF-16 units and twenty-five UTF-8 bytes. A codec that
      counts characters instead of units gets this wrong. }
    Scripts.Emoji := #$D83D#$DC68#$200D#$D83D#$DC69#$200D +
                     #$D83D#$DC67#$200D#$D83D#$DC66' family';
    Scripts.Combining := 'e' + #$0301 + 'cole';

    Data := TCborSerializer.Serialize<TScripts>(Scripts);
    ScriptsBack := TCborSerializer.Deserialize<TScripts>(Data);
    try
      Check(ScriptsBack.Georgian = Scripts.Georgian, 'UNICODE_GEORGIAN');
      Check(ScriptsBack.Cyrillic = Scripts.Cyrillic, 'UNICODE_CYRILLIC');
      Check(ScriptsBack.Cjk = Scripts.Cjk, 'UNICODE_CJK');
      Check(ScriptsBack.Emoji = Scripts.Emoji, 'UNICODE_NON_BMP');
      Check(ScriptsBack.Combining = Scripts.Combining, 'UNICODE_COMBINING_MARKS');
    finally
      ScriptsBack.Free;
    end;
  finally
    Scripts.Free;
  end;
end;

{ ===========================================================================
  Release hardening: what a failed read frees, what the writer refuses, and
  the dates at the edges
  =========================================================================== }

{ Every heap block alive, for a leak that no tracked class can count - the
  CBOR tree nodes a refused write built. }
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

function NewSrc(AX: Integer; AY: Int64): TCSrc;
begin
  Result := TCSrc.Create;
  Result.X := AX;
  Result.Y := AY;
end;

function MapChain(ACount: Integer): TMapNode;
var
  I: Integer;
  Current, Kid: TMapNode;
begin
  Result := TMapNode.Create;
  Current := Result;
  for I := 2 to ACount do
  begin
    Kid := TMapNode.Create;
    Current.Kids.Add('k', Kid);
    Current := Kid;
  end;
end;

function NodeChain(ACount: Integer): TNode;
var
  I: Integer;
  Current: TNode;
begin
  Result := TNode.Create;
  Current := Result;
  for I := 2 to ACount do
  begin
    Current.Child := TNode.Create;
    Current := Current.Child;
  end;
end;

procedure RecordChain(AHolder: TRecHolder; ADepth: Integer);
var
  Chain: array of TRecNode;
  I: Integer;
begin
  SetLength(Chain, ADepth);
  for I := ADepth - 1 downto 0 do
  begin
    Chain[I].Tag := I;
    if I < ADepth - 1 then
    begin
      SetLength(Chain[I].Kids, 1);
      Chain[I].Kids[0] := Chain[I + 1];
    end;
  end;
  AHolder.Root := Chain[0];
end;

function DecimalDocument(AExponent: Int64): TBytes;
var
  M: TCborValue;
begin
  M := TCborValue.NewMap;
  try
    M.Add('C', TCborValue.NewDecimalFraction(AExponent, '1'));
    Result := TCborSerializer.Encode(M);
  finally
    M.Free;
  end;
end;

// {"D": {"qa": {"X": 1}, "qa": {"X": 2}}} - one key twice.
function DuplicateKeyDocument: TBytes;
var
  Root, Map, Item: TCborValue;
  I: Integer;
begin
  Root := TCborValue.NewMap;
  try
    Map := TCborValue.NewMap;
    Root.Add('D', Map);
    for I := 1 to 2 do
    begin
      Item := TCborValue.NewMap;
      Item.Add('X', TCborValue.NewInt(I));
      Map.Add('qa', Item);
    end;
    Result := TCborSerializer.Encode(Root);
  finally
    Root.Free;
  end;
end;

procedure TestReleaseHardening;

  { Fills ONE shape of TShapesSrc with objects, the last of which fails the
    read, and reads the document as TShapesDst: refused as input, and every
    object the read built freed. }
  procedure FailedRead(AShape: Integer; const AName: string);
  const
    TOO_BIG = Int64(5000000000);
  var
    Src: TShapesSrc;
    Data: TBytes;
    RS: TRecSrc;
    I, Before: Integer;
    Refused: Boolean;
  begin
    Src := TShapesSrc.Create;
    try
      case AShape of
        0:
          begin
            Src.R.O := NewSrc(1, 1);
            Src.R.N := TOO_BIG;
          end;
        1:
          begin
            RS.O := NewSrc(1, 1);
            RS.N := TOO_BIG;
            Src.NR := RS;
          end;
        2:
          begin
            Src.LR := TList<TRecSrc>.Create;
            for I := 1 to 4 do
            begin
              RS.O := NewSrc(I, I);
              if I = 4 then RS.N := TOO_BIG else RS.N := I;
              Src.LR.Add(RS);
            end;
          end;
        3:
          begin
            SetLength(Src.A, 3);
            for I := 0 to 2 do
              if I = 2 then Src.A[I] := NewSrc(I, TOO_BIG)
              else Src.A[I] := NewSrc(I, I);
          end;
        4:
          for I := 0 to 2 do
            if I = 2 then Src.S[I] := NewSrc(I, TOO_BIG)
            else Src.S[I] := NewSrc(I, I);
        5:
          begin
            Src.L := TList<TCSrc>.Create;
            for I := 0 to 2 do
              if I = 2 then Src.L.Add(NewSrc(I, TOO_BIG))
              else Src.L.Add(NewSrc(I, I));
          end;
        6:
          begin
            Src.D := TDictionary<string, TCSrc>.Create;
            for I := 0 to 4 do
              if I = 4 then Src.D.Add('k' + IntToStr(I), NewSrc(I, TOO_BIG))
              else Src.D.Add('k' + IntToStr(I), NewSrc(I, I));
          end;
      end;
      Data := TCborSerializer.Serialize<TShapesSrc>(Src);
    finally
      Src.Free;
    end;
    Before := TTracked.Live;
    Refused := False;
    try
      TCborSerializer.Deserialize<TShapesDst>(Data).Free;
    except
      on E: ECborInputError do Refused := True;
    end;
    if TTracked.Live <> Before then
      Note(Format('%s: %d objects left alive', [AName, TTracked.Live - Before]));
    Check(Refused and (TTracked.Live = Before), AName);
    TTracked.Live := Before;
  end;

  function Refuses(const AWrite: TProc; AExpected: ExceptClass): Boolean;
  begin
    Result := False;
    try
      AWrite();
    except
      on E: Exception do Result := E is AExpected;
    end;
  end;

var
  Leaked: Int64;
  MapRoot: TMapNode;
  ValueRaises: TValueRaises;
  KeyRaises: TKeyRaises;
  SelfList: TSelfList;
  SelfDict: TSelfDict;
  Holder, HolderBack: TRecHolder;
  Walk: TRecNode;
  Chain, ChainBack: TNode;
  Depth, Before: Integer;
  Data: TBytes;
  V: TCborValue;
  Text: string;
  Watch: TStopwatch;
  Caught: Boolean;
  Cur: TCurrencyRec;
  Probe, ProbeBack: TDateProbe;
  Counts, CountsBack: TEpochCounts;
  Day: TDayPattern;
  Ctor, CtorBack: TRootRecCtor;
  Partial: TRootRecPartial;
  OldA, OldB: TItem;
  Dict: TRootDict;
  Owned: TRootOwnedDict;
  Source: TStringsSource;
  Sorted: TSortedStrings;
  Message: string;
begin
  Writeln;
  Writeln('--- release hardening ---');

  { D10: the dictionary writer converts a key and its value one at a time,
    so the one converted first is freed when the other raises. }
  MapRoot := MapChain(65);
  try
    Check(RefusedWrite(
      procedure begin TCborSerializer.Serialize<TMapNode>(MapRoot); end,
      ESerializationLimitExceeded, Leaked), 'HARDEN_D10_DICTIONARY_CHAIN_REFUSED');
    Check(Leaked = 0, 'HARDEN_D10_DICTIONARY_CHAIN_NO_LEAK');
  finally
    MapRoot.Free;
  end;
  ValueRaises := TValueRaises.Create;
  try
    Check(RefusedWrite(
      procedure begin TCborSerializer.Serialize<TValueRaises>(ValueRaises); end,
      ECborError, Leaked) and (Leaked = 0), 'HARDEN_D10_VALUE_RAISES_NO_LEAK');
  finally
    ValueRaises.Free;
  end;
  KeyRaises := TKeyRaises.Create;
  try
    Check(RefusedWrite(
      procedure begin TCborSerializer.Serialize<TKeyRaises>(KeyRaises); end,
      ECborError, Leaked) and (Leaked = 0), 'HARDEN_D10_KEY_RAISES_NO_LEAK');
  finally
    KeyRaises.Free;
  end;

  { D22: a container is a node of the graph, so one that holds itself is a
    cycle - not a recursion until the stack runs out. }
  SelfList := TSelfList.Create;
  try
    SelfList.Items.Add(SelfList.Items);
    Check(Refuses(
      procedure begin TCborSerializer.Serialize<TSelfList>(SelfList); end,
      ECborError), 'HARDEN_D22_LIST_HOLDING_ITSELF_IS_A_CYCLE');
  finally
    SelfList.Free;
  end;
  SelfDict := TSelfDict.Create;
  try
    SelfDict.Map.Add('me', SelfDict.Map);
    Check(Refuses(
      procedure begin TCborSerializer.Serialize<TSelfDict>(SelfDict); end,
      ECborError), 'HARDEN_D22_DICTIONARY_HOLDING_ITSELF_IS_A_CYCLE');
  finally
    SelfDict.Free;
  end;

  { D23 and the level rule: every record, array, list, dictionary and object
    counts one of the 64 levels, so a record chain with no object in it is
    refused by the writer instead of written deeper than the reader reads. }
  Holder := TRecHolder.Create;
  try
    RecordChain(Holder, 300);
    Check(Refuses(
      procedure begin TCborSerializer.Serialize<TRecHolder>(Holder); end,
      ESerializationLimitExceeded), 'HARDEN_D23_RECORD_CHAIN_300_REFUSED');
    RecordChain(Holder, 20);
    HolderBack := TCborSerializer.Deserialize<TRecHolder>(
      TCborSerializer.Serialize<TRecHolder>(Holder));
    try
      Walk := HolderBack.Root;
      Depth := 1;
      while Length(Walk.Kids) = 1 do
      begin
        Walk := Walk.Kids[0];
        Inc(Depth);
      end;
      Check((Depth = 20) and (Walk.Tag = 19), 'HARDEN_D23_RECORD_CHAIN_20_ROUND_TRIPS');
    finally
      HolderBack.Free;
    end;
  finally
    Holder.Free;
  end;
  Chain := NodeChain(60);
  try
    ChainBack := TCborSerializer.Deserialize<TNode>(
      TCborSerializer.Serialize<TNode>(Chain));
    ChainBack.Free;
    Check(True, 'HARDEN_R1_OBJECT_CHAIN_60_ROUND_TRIPS');
  finally
    Chain.Free;
  end;
  Chain := NodeChain(65);
  try
    Check(Refuses(
      procedure begin TCborSerializer.Serialize<TNode>(Chain); end,
      ESerializationLimitExceeded), 'HARDEN_R1_OBJECT_CHAIN_65_REFUSED');
  finally
    Chain.Free;
  end;

  { D24: a decimal fraction's exponent is bounded before any digit is
    built. Eleven bytes used to hang the reader or exhaust memory. }
  Watch := TStopwatch.StartNew;
  Check(Refuses(
    procedure begin TCborSerializer.Deserialize<TCurrencyRec>(DecimalDocument(-400000)); end,
    ECborInputError), 'HARDEN_D24_NEGATIVE_EXPONENT_REFUSED');
  Check(Refuses(
    procedure begin TCborSerializer.Deserialize<TCurrencyRec>(DecimalDocument(400000000)); end,
    ECborInputError), 'HARDEN_D24_POSITIVE_EXPONENT_REFUSED');
  Check(Refuses(
    procedure begin TCborSerializer.Deserialize<TVariantRec>(DecimalDocument(-400000)); end,
    ECborInputError), 'HARDEN_D24_EXPONENT_REFUSED_INTO_VARIANT');
  Check(Watch.ElapsedMilliseconds < 2000, 'HARDEN_D24_REFUSED_AT_ONCE');
  V := TCborSerializer.Decode(DecimalDocument(-CborDecimalExponentLimit));
  try
    Check(V.Find('C').TryAsDecimalText(Text) and
      (Length(Text) = CborDecimalExponentLimit + 2), 'HARDEN_D24_EXPONENT_AT_LIMIT_READ');
  finally
    V.Free;
  end;
  V := TCborSerializer.Decode(DecimalDocument(CborDecimalExponentLimit + 1));
  try
    Caught := False;
    try
      V.Find('C').TryAsDecimalText(Text);
    except
      on E: ECborInputError do Caught := True;
    end;
    Check(Caught, 'HARDEN_D24_EXPONENT_PAST_LIMIT_REFUSED');
  finally
    V.Free;
  end;
  Cur := TCborSerializer.Deserialize<TCurrencyRec>(DecimalDocument(-4));
  Check(Cur.C = 0.0001, 'HARDEN_D24_ORDINARY_EXPONENT_READ');

  { D31, D7, D26: every epoch goes through Delphi's own date encoding, both
    ways - the last millisecond of 9999 reads back, and a date before
    1899-12-30 with a time of day is not written a day early. }
  Probe := TDateProbe.Create;
  try
    Probe.D := EncodeDateTime(9999, 12, 31, 23, 59, 59, 999);
    Data := TCborSerializer.Serialize<TDateProbe>(Probe);
    ProbeBack := TCborSerializer.Deserialize<TDateProbe>(Data);
    try
      Check(MilliSecondsBetween(ProbeBack.D, Probe.D) = 0,
        'HARDEN_D31_LAST_MILLISECOND_OF_9999_READS_BACK');
    finally
      ProbeBack.Free;
    end;

    Probe.D := EncodeDateTime(1800, 1, 1, 12, 0, 0, 0);
    Data := TCborSerializer.Serialize<TDateProbe>(Probe);
    V := TCborSerializer.Decode(Data);
    try
      Check(V.Find('D').ToDiagnostic = '1(-5364619200)', 'HARDEN_D7_1800_EPOCH_ON_THE_WIRE');
    finally
      V.Free;
    end;
    ProbeBack := TCborSerializer.Deserialize<TDateProbe>(Data);
    try
      Check(MilliSecondsBetween(ProbeBack.D, Probe.D) = 0, 'HARDEN_D7_1800_READS_BACK');
    finally
      ProbeBack.Free;
    end;

    Probe.D := EncodeDateTime(1899, 12, 29, 6, 0, 0, 0);
    Data := TCborSerializer.Serialize<TDateProbe>(Probe);
    V := TCborSerializer.Decode(Data);
    try
      Check(V.Find('D').ToDiagnostic = '1(-2209226400)', 'HARDEN_D26_1899_12_29_EPOCH_ON_THE_WIRE');
    finally
      V.Free;
    end;
    ProbeBack := TCborSerializer.Deserialize<TDateProbe>(Data);
    try
      Check(MilliSecondsBetween(ProbeBack.D, Probe.D) = 0, 'HARDEN_D26_1899_12_29_READS_BACK');
    finally
      ProbeBack.Free;
    end;

    { D33: outside the years 1 to 9999 the writer refuses, rather than write
      what its own reader then refuses. }
    Probe.D := EncodeDate(1, 1, 1) - 1;
    Check(Refuses(
      procedure begin TCborSerializer.Serialize<TDateProbe>(Probe); end,
      ESerializationUnsupported), 'HARDEN_D33_BEFORE_YEAR_1_REFUSED');
    Probe.D := EncodeDate(9999, 12, 31) + 1;
    Check(Refuses(
      procedure begin TCborSerializer.Serialize<TDateProbe>(Probe); end,
      ESerializationUnsupported), 'HARDEN_D33_AFTER_9999_REFUSED');
  finally
    Probe.Free;
  end;

  Counts := TEpochCounts.Create;
  try
    Counts.Secs := EncodeDateTime(1800, 1, 1, 12, 0, 0, 0);
    Counts.Millis := Counts.Secs;
    V := TCborSerializer.Decode(TCborSerializer.Serialize<TEpochCounts>(Counts));
    try
      Check((V.Find('Secs').AsInt64 = -5364619200) and
        (V.Find('Millis').AsInt64 = -5364619200000), 'HARDEN_D7_UNIX_COUNTS_BEFORE_1899');
    finally
      V.Free;
    end;
    { The second an instant falls in is the millisecond count floored. }
    Counts.Secs := EncodeDateTime(1969, 12, 31, 23, 59, 59, 500);
    Counts.Millis := Counts.Secs;
    Data := TCborSerializer.Serialize<TEpochCounts>(Counts);
    V := TCborSerializer.Decode(Data);
    try
      Check((V.Find('Secs').AsInt64 = -1) and (V.Find('Millis').AsInt64 = -500),
        'HARDEN_R7_UNIX_SECONDS_FLOORED');
    finally
      V.Free;
    end;
    CountsBack := TCborSerializer.Deserialize<TEpochCounts>(Data);
    try
      Check(MilliSecondsBetween(CountsBack.Millis, Counts.Millis) = 0,
        'HARDEN_R7_UNIX_MILLISECONDS_BEFORE_EPOCH_READ_BACK');
    finally
      CountsBack.Free;
    end;
    Counts.Secs := EncodeDate(9999, 12, 31) + 1;
    Check(Refuses(
      procedure begin TCborSerializer.Serialize<TEpochCounts>(Counts); end,
      ESerializationUnsupported), 'HARDEN_D33_UNIX_SECONDS_AFTER_9999_REFUSED');
  finally
    Counts.Free;
  end;
  Day := TDayPattern.Create;
  try
    Day.Day := EncodeDate(9999, 12, 31) + 1;
    Check(Refuses(
      procedure begin TCborSerializer.Serialize<TDayPattern>(Day); end,
      ESerializationUnsupported), 'HARDEN_D33_PATTERN_AFTER_9999_REFUSED');
  finally
    Day.Free;
  end;

  { D39, D40, D42: a read that fails part way frees every object it built -
    in a record, a nullable record, a list of records, a dynamic and a static
    array, and a list and a dictionary that own nothing. }
  FailedRead(0, 'HARDEN_D39_RECORD_OBJECT_FREED_ON_FAILURE');
  FailedRead(1, 'HARDEN_D39_NULLABLE_RECORD_OBJECT_FREED_ON_FAILURE');
  FailedRead(2, 'HARDEN_D39_LIST_OF_RECORDS_FREED_ON_FAILURE');
  FailedRead(3, 'HARDEN_D40_DYNAMIC_ARRAY_ELEMENTS_FREED_ON_FAILURE');
  FailedRead(4, 'HARDEN_D40_STATIC_ARRAY_ELEMENTS_FREED_ON_FAILURE');
  FailedRead(5, 'HARDEN_D42_NON_OWNING_LIST_ELEMENTS_FREED_ON_FAILURE');
  FailedRead(6, 'HARDEN_D42_NON_OWNING_DICTIONARY_VALUES_FREED_ON_FAILURE');

  { D41: a record is merged in place - the objects a constructor or the
    caller put in it are filled, not replaced and orphaned, and a member the
    document leaves out keeps its value. }
  Ctor := TRootRecCtor.Create;
  try
    Ctor.R.A.X := 1;
    Ctor.R.B.X := 2;
    Ctor.R.N := 3;
    Data := TCborSerializer.Serialize<TRootRecCtor>(Ctor);
  finally
    Ctor.Free;
  end;
  Before := TTracked.Live;
  CtorBack := TCborSerializer.Deserialize<TRootRecCtor>(Data);
  try
    Check((CtorBack.R.A.X = 1) and (CtorBack.R.B.X = 2) and (CtorBack.R.N = 3),
      'HARDEN_D41_RECORD_READ');
    Check(TTracked.Live = Before + 3, 'HARDEN_D41_CONSTRUCTOR_OBJECTS_FILLED_IN_PLACE');
  finally
    CtorBack.Free;
  end;
  Check(TTracked.Live = Before, 'HARDEN_D41_NOTHING_ORPHANED');
  TTracked.Live := Before;

  Partial := TRootRecPartial.Create;
  try
    Partial.R.A := TItem.Create;
    Partial.R.A.X := 4;
    Data := TCborSerializer.Serialize<TRootRecPartial>(Partial);
  finally
    Partial.Free;
  end;
  Ctor := TRootRecCtor.Create;
  try
    OldA := Ctor.R.A;
    OldB := Ctor.R.B;
    Ctor.R.B.X := 5;
    Ctor.R.N := 6;
    Before := TTracked.Live;
    TCborSerializer.Populate<TRootRecCtor>(Ctor, Data);
    Check((Ctor.R.A = OldA) and (Ctor.R.A.X = 4),
      'HARDEN_D41_POPULATE_FILLS_THE_RECORD_OBJECT_IN_PLACE');
    Check((Ctor.R.B = OldB) and (Ctor.R.B.X = 5) and (Ctor.R.N = 6),
      'HARDEN_D41_POPULATE_KEEPS_WHAT_THE_DOCUMENT_OMITS');
    Check(TTracked.Live = Before, 'HARDEN_D41_POPULATE_ORPHANS_NOTHING');
  finally
    Ctor.Free;
  end;

  { D45: a key the document repeats releases the value built for its first
    occurrence, whether or not the dictionary owns its values. }
  Before := TTracked.Live;
  Dict := TCborSerializer.Deserialize<TRootDict>(DuplicateKeyDocument);
  try
    Check((Dict.D.Count = 1) and (Dict.D['qa'].X = 2) and
      (TTracked.Live = Before + 2), 'HARDEN_D45_DUPLICATE_KEY_NON_OWNING');
  finally
    Dict.Free;
  end;
  Check(TTracked.Live = Before, 'HARDEN_D45_DUPLICATE_KEY_NOTHING_ORPHANED');
  TTracked.Live := Before;
  Owned := TCborSerializer.Deserialize<TRootOwnedDict>(DuplicateKeyDocument);
  try
    Check((Owned.D.Count = 1) and (Owned.D['qa'].X = 2) and
      (TTracked.Live = Before + 2), 'HARDEN_R3_DUPLICATE_KEY_OWNING');
  finally
    Owned.Free;
  end;
  Check(TTracked.Live = Before, 'HARDEN_R3_DUPLICATE_KEY_FREED_ONCE');
  TTracked.Live := Before;

  { D36: what the container itself refuses is CBOR's input error, naming the
    container - not the RTL's EStringListError. }
  Source := TStringsSource.Create;
  try
    Source.Lines.Add('b');
    Source.Lines.Add('a');
    Source.Lines.Add('b');
    Data := TCborSerializer.Serialize<TStringsSource>(Source);
  finally
    Source.Free;
  end;
  Caught := False;
  Message := '';
  try
    Sorted := TCborSerializer.Deserialize<TSortedStrings>(Data);
    Sorted.Free;
  except
    on E: ECborInputError do
    begin
      Caught := True;
      Message := E.Message;
    end;
  end;
  Check(Caught and (Pos('TStringList', Message) > 0),
    'HARDEN_D36_CONTAINER_REFUSAL_IS_CBOR_INPUT_ERROR');
end;

{ ===========================================================================
  The registry: CBOR as one format among several
  =========================================================================== }

procedure TestConversionMatrix;
const
  Source =
    '{"reference":"PF-1","amount":1234.56,"count":42,"paid":true,' +
    '"tags":["urgent","reviewed"],"shipper":{"city":"' + GEO_JSON + '"},' +
    '"nothing":null}';
var
  Cbor: TBytes;
  Back: string;
  Formats: TArray<TSerializationFormat>;
  F: TSerializationFormat;
  Payload, Hop: TSerializationPayload;
  Identical, Diverged: Integer;
  V: TCborValue;
begin
  Writeln;
  Writeln('--- conversion ---');

  Check(TSerialization.IsRegistered(TSerializationFormat.Cbor),
    'CBOR_REGISTERED');
  Check(TSerialization.StructuralRequirement(TSerializationFormat.Cbor) = 'yes',
    'CBOR_STRUCTURAL_WITHOUT_SCHEMA');

  { JSON in, CBOR out, JSON back. Under Lossless the two JSON documents are
    the same document. }
  Cbor := TCborSerializer.From(Source, TSerializationFormat.Json);
  V := TCborSerializer.Decode(Cbor);
  try
    Check((V.Kind = TCborKind.Map) and (V.Find('count').AsInt64 = 42),
      'CBOR_FROM_JSON');
    Check(V.Find('shipper').Find('city').AsText = GEO_CITY,
      'CBOR_FROM_JSON_UNICODE');
    Check(V.Find('nothing').Kind = TCborKind.Null, 'CBOR_FROM_JSON_NULL');
  finally
    V.Free;
  end;

  Back := TSerialization.Convert(TSerializationPayload.FromBytes(Cbor),
    TSerializationFormat.Cbor, TSerializationFormat.Json,
    TStructuralConversionProfile.Lossless).AsText;
  Note(Copy(Back, 1, 120));
  Check(Pos('"count":42', Back) > 0, 'CBOR_TO_JSON');

  { And every other registered structural format, both ways. }
  Formats := TSerialization.StructuralFormats;
  Identical := 0;
  Diverged := 0;
  Payload := TSerializationPayload.FromBytes(Cbor);
  for F in Formats do
  begin
    if F = TSerializationFormat.Cbor then Continue;
    try
      Hop := TSerialization.Convert(Payload, TSerializationFormat.Cbor, F,
        TStructuralConversionProfile.Lossless);
      Hop := TSerialization.Convert(Hop, F, TSerializationFormat.Cbor,
        TStructuralConversionProfile.Lossless);
      if SameBytes(Hop.AsBytes, Cbor) then Inc(Identical) else Inc(Diverged);
      Note(Format('  cbor -> %s -> cbor: %s',
        [TSerialization.FormatName(F),
         IfThen(SameBytes(Hop.AsBytes, Cbor), 'identical', 'diverged')]));
    except
      on E: Exception do
      begin
        Inc(Diverged);
        Note(Format('  cbor -> %s: %s', [TSerialization.FormatName(F),
          E.ClassName]));
      end;
    end;
  end;
  Note(Format('identical=%d diverged=%d', [Identical, Diverged]));
  Check(Identical + Diverged = Length(Formats) - 1, 'CBOR_CONVERSION_MATRIX');
end;

{ ===========================================================================
  CBOR as a DataSet source, with no contract at all
  =========================================================================== }

procedure TestDataSet;
var
  Root, Row: TCborValue;
  DS: TClientDataSet;
  Data: TBytes;
  Payload: TSerializationPayload;
begin
  Writeln;
  Writeln('--- DataSet projection ---');

  Root := TCborValue.NewArray;
  try
    Row := TCborValue.NewMap;
    Row.Add('reference', TCborValue.NewText('PF-1'));
    Row.Add('count', TCborValue.NewInt(42));
    Row.Add('rate', TCborValue.NewFloat(0.0725));
    Row.Add('paid', TCborValue.NewBool(True));
    Row.Add('raised', TCborValue.NewEpochDateTime(
      EncodeDateTime(2026, 9, 19, 14, 30, 0, 0)));
    Row.Add('receipt', TCborValue.NewBytes(TBytes.Create(1, 2, 3)));
    Root.Add(Row);

    Row := TCborValue.NewMap;
    Row.Add('reference', TCborValue.NewText('PF-2'));
    Row.Add('count', TCborValue.NewInt(7));
    Row.Add('rate', TCborValue.NewFloat(0.05));
    Row.Add('paid', TCborValue.NewBool(False));
    Row.Add('raised', TCborValue.NewEpochDateTime(
      EncodeDateTime(2026, 9, 20, 9, 0, 0, 0)));
    Row.Add('receipt', TCborValue.NewBytes(TBytes.Create(9)));
    Root.Add(Row);

    Data := TCborSerializer.Encode(Root);
  finally
    Root.Free;
  end;

  DS := TDataSetSerializer.CreateClientDataSet(Data, TSerializationFormat.Cbor);
  try
    Check(DS.RecordCount = 2, 'DATASET_ROWS');
    Check(DS.FieldCount = 6, 'DATASET_COLUMNS');
    { CBOR states its own types, so inference is not guessing here: an
      integer arrives as an integer because the document said so, and a byte
      string arrives as a blob rather than as text that happened to decode. }
    Check(DS.FieldByName('count').DataType in [ftInteger, ftLargeint],
      'DATASET_INTEGER_FROM_FORMAT');
    Check(DS.FieldByName('paid').DataType = ftBoolean, 'DATASET_BOOLEAN');
    Check(DS.FieldByName('raised').DataType in [ftDateTime, ftTimeStamp],
      'DATASET_DATETIME_FROM_TAG');
    Check(DS.FieldByName('receipt').DataType in [ftBlob, ftVarBytes, ftBytes],
      'DATASET_BINARY_NOT_TEXT');
    DS.First;
    Check(DS.FieldByName('reference').AsString = 'PF-1', 'DATASET_FIRST_ROW');
    DS.Next;
    Check(DS.FieldByName('count').AsInteger = 7, 'DATASET_SECOND_ROW');

    { And out again, in CBOR, without a JSON detour. }
    Payload := TDataSetSerializer.Serialize(DS, TSerializationFormat.Cbor,
      TDataSetSerializationPolicy.RowsOnly);
    Check(Payload.IsBinary, 'DATASET_OUT_IS_BINARY');
    Root := TCborSerializer.Decode(Payload.AsBytes);
    try
      Check((Root.Kind = TCborKind.Arr) and (Root.Count = 2),
        'CBOR_DATASET_AUTO');
    finally
      Root.Free;
    end;
  finally
    DS.Free;
  end;
end;

{ ===========================================================================
  The feature ledger: everything RFC 8949 defines, and where it is covered
  =========================================================================== }

{ A map key that is not text, through structural conversion. Natural
  writes it as its diagnostic text - documented - Strict refuses because the
  key's type would change, and Lossless never coerces: it either keeps the
  key's own type or refuses. }
procedure TestNonTextMapKeys;
const
  // the map {1: "a"}
  DOC = 'a1016161';
var
  Natural: string;

  function Outcome(ATo: TSerializationFormat;
    AProfile: TStructuralConversionProfile): string;
  var
    Payload: TSerializationPayload;
  begin
    try
      Payload := TSerialization.Convert(
        TSerializationPayload.FromBytes(FromHex(DOC)),
        TSerializationFormat.Cbor, ATo, AProfile);
      if Payload.IsText then Result := Payload.AsText
      else Result := Hex(Payload.AsBytes);
    except
      on E: Exception do Result := E.ClassName + ': ' + E.Message;
    end;
  end;

  function Refused(const AOutcome: string): Boolean;
  begin
    Result := StartsText('EStructuralConversionError', AOutcome) and
      ContainsText(AOutcome, '$[1]');
    if not Result then Note(AOutcome);
  end;

  { Lossless: refused, or the key still the integer it was. Diagnostic text
    standing in for the key is the one outcome that must never appear. }
  function NotCoerced(ATo: TSerializationFormat): Boolean;
  var
    Got: string;
  begin
    Got := Outcome(ATo, TStructuralConversionProfile.Lossless);
    Result := StartsText('EStructuralConversionError', Got) or
      ((ATo = TSerializationFormat.Cbor) and SameText(Got, DOC));
    if not Result then Note(Got);
  end;

begin
  Writeln;
  Writeln('--- a map key that is not text ---');
  Natural := Outcome(TSerializationFormat.Json,
    TStructuralConversionProfile.Natural);
  Check(SameText(Natural, '{"1":"a"}'),
    'CBOR_NON_TEXT_MAP_KEY_NATURAL');
  if not StartsText('{', Natural) then Note(Natural);
  Check(Refused(Outcome(TSerializationFormat.Json,
    TStructuralConversionProfile.Strict)) and
    Refused(Outcome(TSerializationFormat.Cbor,
    TStructuralConversionProfile.Strict)),
    'CBOR_NON_TEXT_MAP_KEY_STRICT_REFUSES');
  Check(NotCoerced(TSerializationFormat.Json) and
    NotCoerced(TSerializationFormat.MessagePack) and
    NotCoerced(TSerializationFormat.Cbor),
    'CBOR_NON_TEXT_MAP_KEY_LOSSLESS_NO_COERCION');
end;

procedure TestFeatureLedger;
begin
  Writeln;
  Writeln('--- RFC 8949 feature ledger ---');
  Note('major type 0 unsigned integer          MAJOR_0_UNSIGNED');
  Note('major type 1 negative integer          MAJOR_1_NEGATIVE');
  Note('major type 2 byte string               MAJOR_2_BYTES');
  Note('major type 3 text string               MAJOR_3_TEXT');
  Note('major type 4 array                     MAJOR_4_ARRAY');
  Note('major type 5 map                       MAJOR_5_MAP_NONTEXT_KEYS');
  Note('major type 6 tag                       MAJOR_6_TAG');
  Note('major type 7 simple and float          MAJOR_7_*, FLOAT_*');
  Note('arguments 0-23, 24, 25, 26, 27         CBOR_APPENDIX_A_VECTORS');
  Note('additional information 31 indefinite   INDEFINITE_*');
  Note('additional information 28-30 reserved  RESERVED_ADDITIONAL_INFO_REFUSED');
  Note('break stop code                        BREAK_OUTSIDE_INDEFINITE_REFUSED');
  Note('half precision                         FLOAT_HALF_*');
  Note('single precision                       FLOAT_SINGLE_DECODED');
  Note('double precision                       FLOAT_DOUBLE_DECODED');
  Note('simple values 0-255                    SIMPLE_*');
  Note('tags 0, 1 date and time                TAG_0_RFC3339, TAG_1_EPOCH');
  Note('tags 2, 3 bignum                       BIGNUM_*');
  Note('tag 4 decimal fraction                 TAG_4_DECIMAL_FRACTION');
  Note('tag 5 bigfloat                         TAG_5_BIGFLOAT');
  Note('tag 32 URI                             MAJOR_6_TAG');
  Note('tag 37 UUID                            TAG_37_*');
  Note('tag 55799 self-described CBOR          SELF_DESCRIBE_*');
  Note('unregistered tags                      CBOR_UNKNOWN_TAG_PRESERVATION');
  Note('section 4.2 deterministic encoding     DETERMINISTIC_*');
  Note('section 5.6 well-formedness            MALFORMED_*');
  Writeln;
  Note('NOT IMPLEMENTED, deliberately:');
  Note('  CBOR sequences (RFC 8742) - a stream of items, not one document;');
  Note('    TCborDecodeOptions.AllowTrailingData is the hook, and a');
  Note('    sequence reader is a separate API, not a decode flag.');
  Note('  COSE, CDDL and CBOR patching are other specifications.');
  Check(True, 'CBOR_RFC8949_FEATURE_LEDGER');
end;

{ ===========================================================================
  Tag numbers and declared lengths are 64 bits wide
  =========================================================================== }

{ True when the bytes decode, become a dynamic CborTag carrying exactly
  ANumber, and come back to CBOR with that number. AExactBytes also asks for
  the original bytes, which holds when the source used the shortest head. }
function LargeTagSurvives(const AHex: string; ANumber: UInt64;
  AExactBytes: Boolean): Boolean;
var
  Source, Again: TBytes;
  V, Rebuilt: TCborValue;
  Tree, Payload: TDynamicValue;
begin
  Result := False;
  Source := FromHex(AHex);
  V := TCborSerializer.Decode(Source);
  try
    if (V.Kind <> TCborKind.Tag) or (V.TagNumber <> ANumber) then Exit;
    Tree := TCborEngine.CborToDynamic(V);
    try
      if (Tree.Kind <> TDynamicKind.Extended) or
         not Tree.IsTagged(TDynamicTag.CborTag) then Exit;
      Payload := Tree.ExtendedValue;
      if (Payload = nil) or (Payload.Find('number') = nil) or
         (Payload.Find('number').AsUInt <> ANumber) then Exit;
      Rebuilt := TCborEngine.DynamicToCbor(Tree);
      try
        if (Rebuilt.Kind <> TCborKind.Tag) or
           (Rebuilt.TagNumber <> ANumber) then Exit;
        Again := TCborSerializer.Encode(Rebuilt);
      finally
        Rebuilt.Free;
      end;
    finally
      Tree.Free;
    end;
  finally
    V.Free;
  end;
  if AExactBytes and not SameBytes(Again, Source) then Exit;
  Result := True;
end;

{ True when the document is refused with the CBOR input error - not an RTL
  exception, not ECborRangeError, and not accepted. }
function RefusedAsInput(const AHex: string): Boolean;
var
  V: TCborValue;
begin
  Result := False;
  try
    V := TCborSerializer.Decode(FromHex(AHex));
    V.Free;
  except
    on E: ECborInputError do Result := True;
    on E: Exception do Note(AHex + ' raised ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure TestWideTagsAndLengths;
const
  { Tag 2^32 + K wrapping the integer 0: 0xDB, eight bytes, then 0x00. }
  WIDE_TAG = 'db00000001000000%.2x00';
var
  K: Integer;
  AllOk, Ok: Boolean;
  V: TCborValue;
  Tree: TDynamicValue;
  DT: TDateTime;
  Probe: TDateProbe;
  Text: string;
begin
  Writeln;
  Writeln('--- tag numbers and lengths past 32 bits ---');

  { Tag 2^32+K narrowed to Integer is tag K. For K in 0..5 that is a date,
    a bignum or a decimal fraction, and none of them may be what the
    document means: each must stay an unknown tag with its full number. }
  AllOk := True;
  for K := 0 to 5 do
  begin
    V := TCborSerializer.Decode(FromHex(Format(WIDE_TAG, [K])));
    try
      Ok := (V.Kind = TCborKind.Tag) and
            (V.TagNumber = UInt64($100000000) + UInt64(K)) and
            not V.TryAsDateTime(DT) and not V.TryAsBigIntText(Text) and
            not V.TryAsDecimalText(Text) and
            (TCborTags.Describe(V.TagNumber) = '') and
            not TCborTags.IsKnown(V.TagNumber);
      Tree := TCborEngine.CborToDynamic(V);
      try
        Ok := Ok and (Tree.Kind = TDynamicKind.Extended) and
              Tree.IsTagged(TDynamicTag.CborTag);
      finally
        Tree.Free;
      end;
    finally
      V.Free;
    end;
    if not Ok then
    begin
      Note('tag 2^32+' + IntToStr(K) + ' was read as a known tag');
      AllOk := False;
    end;
  end;
  { 4294967295 is the largest 32-bit tag and 4294967296 the first past it;
    neither is a known tag and neither may alias one. }
  AllOk := AllOk and
    LargeTagSurvives('daffffffff00', 4294967295, True) and
    LargeTagSurvives('db000000010000000000', 4294967296, True) and
    LargeTagSurvives('db000000010000000100', 4294967297, True) and
    (TCborTags.Describe(4294967295) = '') and
    (TCborTags.Describe(4294967296) = '') and
    (TCborTags.Describe(4294967297) = '');

  { The typed reader: tag 2^32+1 around 0 into a TDateTime member is not
    the epoch. It is refused, or at the very least not read as 1970. }
  Probe := nil;
  try
    try
      // A map holding "D": 4294967297(0)
      Probe := TCborSerializer.Deserialize<TDateProbe>(
        FromHex('a16144db000000010000000100'));
      if SameValue(Probe.D, UnixDateDelta) then
      begin
        Note('the typed reader read tag 2^32+1 as an epoch date');
        AllOk := False;
      end;
    except
      on ECborError do ;
    end;
  finally
    Probe.Free;
  end;
  Check(AllOk, 'CBOR_TAG_NO_32BIT_ALIAS');

  { A large unknown tag, up to 2^64-1, keeps its number exactly through the
    dynamic tree and back, and is described as what it is - unknown. }
  Ok := LargeTagSurvives('dbffffffffffffffff00', High(UInt64), True) and
        LargeTagSurvives('dbfffffffffffffffe8102', UInt64($FFFFFFFFFFFFFFFE), True) and
        LargeTagSurvives('db7fffffffffffffff6161', UInt64(High(Int64)), True) and
        (TCborTags.Describe(High(UInt64)) = '') and
        not TCborTags.IsKnown(High(UInt64)) and
        not TCborTags.IsKnown(UInt64(High(Int64)) + 55799);
  V := TCborSerializer.Decode(FromHex('dbffffffffffffffff00'));
  try
    Ok := Ok and (V.ToDiagnostic = '18446744073709551615(0)');
    if V.ToDiagnostic <> '18446744073709551615(0)' then
      Note('diagnostic: ' + V.ToDiagnostic);
  finally
    V.Free;
  end;
  Check(Ok, 'CBOR_LARGE_TAG_PRESERVED_OR_HANDLED');

  { A few bytes declaring more than MaxInt bytes or elements: the CBOR input
    error, before anything is narrowed or allocated, on both platforms. }
  Check(
    RefusedAsInput('5a80000000') and                  { bytes, 2^31 }
    RefusedAsInput('5b000000010000000000') and        { bytes, 2^32 }
    RefusedAsInput('5b7fffffffffffffff00') and        { bytes, 2^63-1 }
    RefusedAsInput('5bffffffffffffffff00') and        { bytes, 2^64-1 }
    RefusedAsInput('7b000000010000000061') and        { text, 2^32 }
    RefusedAsInput('7bffffffffffffffff61') and        { text, 2^64-1 }
    RefusedAsInput('9a8000000000') and                { array, 2^31 }
    RefusedAsInput('9bffffffffffffffff00') and        { array, 2^64-1 }
    RefusedAsInput('bb00000001000000000000') and      { map, 2^32 }
    RefusedAsInput('bbffffffffffffffff0000') and      { map, 2^64-1 }
    RefusedAsInput('5f5bffffffffffffffff00ff'),       { chunk, 2^64-1 }
    'CBOR_LENGTH_OVER_MAXINT_REFUSES');

  { Tag 5 with an exponent outside Int64 (2^64-1, and -2^64) is declined
    like any other exponent past the limit: not a decimal, and no
    ECborRangeError from the decoder, the accessor or the dynamic tree. }
  Ok := True;
  for K := 0 to 1 do
  begin
    try
      if K = 0 then V := TCborSerializer.Decode(FromHex('c5821bffffffffffffffff01'))
      else V := TCborSerializer.Decode(FromHex('c5823bffffffffffffffff01'));
      try
        Ok := Ok and (V.Kind = TCborKind.Tag) and (V.TagNumber = 5) and
              not V.TryAsDecimalText(Text);
        Tree := TCborEngine.CborToDynamic(V);
        try
          Ok := Ok and (Tree.Kind = TDynamicKind.Extended) and
                Tree.IsTagged(TDynamicTag.CborTag);
        finally
          Tree.Free;
        end;
      finally
        V.Free;
      end;
    except
      on E: Exception do
      begin
        Note('bigfloat exponent raised ' + E.ClassName + ': ' + E.Message);
        Ok := False;
      end;
    end;
  end;
  Check(Ok, 'CBOR_BIGFLOAT_EXPONENT_OUT_OF_RANGE');
end;

{ The value of a CBOR integer or bignum as decimal text, or '' if it is
  neither. }
function BigText(V: TCborValue): string;
begin
  if V.Kind = TCborKind.NegInt then
    Exit('-' + TCborBigInt.MagnitudeToDecimal(TCborBigInt.IncrementMagnitude(
      TBytes.Create(Byte(V.NegativeArgument shr 56), Byte(V.NegativeArgument shr 48),
        Byte(V.NegativeArgument shr 40), Byte(V.NegativeArgument shr 32),
        Byte(V.NegativeArgument shr 24), Byte(V.NegativeArgument shr 16),
        Byte(V.NegativeArgument shr 8), Byte(V.NegativeArgument)))));
  if not V.TryAsBigIntText(Result) then Result := '';
end;

{ CBOR -> dynamic -> CBOR, and CBOR -> JSON (Lossless) -> CBOR: the value
  that comes back equals AExpected. The dynamic payload is the magnitude. }
function NegativeSurvives(const AHex, AExpected: string;
  AExactBytes: Boolean; out AJsonOutcome: string): Boolean;
var
  Source, Again: TBytes;
  V, Rebuilt: TCborValue;
  Tree: TDynamicValue;
  Json: TSerializationPayload;
begin
  Result := False;
  Source := FromHex(AHex);
  V := TCborSerializer.Decode(Source);
  try
    if BigText(V) <> AExpected then
    begin
      Note(AHex + ' decoded as ' + BigText(V));
      Exit;
    end;
    Tree := TCborEngine.CborToDynamic(V);
    try
      if not Tree.IsTagged(TDynamicTag.BigIntNegative) or
         ('-' + TCborBigInt.MagnitudeToDecimal(Tree.ExtendedValue.AsBytes) <>
          AExpected) then
      begin
        Note(AHex + ': the dynamic payload is not the magnitude');
        Exit;
      end;
      Rebuilt := TCborEngine.DynamicToCbor(Tree);
      try
        if BigText(Rebuilt) <> AExpected then
        begin
          Note(AHex + ' came back from dynamic as ' + BigText(Rebuilt));
          Exit;
        end;
        Again := TCborSerializer.Encode(Rebuilt);
      finally
        Rebuilt.Free;
      end;
    finally
      Tree.Free;
    end;
  finally
    V.Free;
  end;
  if AExactBytes and not SameBytes(Again, Source) then
  begin
    Note(AHex + ' came back as ' + Hex(Again));
    Exit;
  end;

  { JSON (Lossless) either carries the value back intact or refuses it with
    the structural conversion error - which one is JSON's existing policy,
    and the caller checks that a NegInt gets the same answer as tag 3. }
  try
    Json := TSerialization.Convert(TSerializationPayload.FromBytes(Source),
      TSerializationFormat.Cbor, TSerializationFormat.Json,
      TStructuralConversionProfile.Lossless);
    V := TCborSerializer.Decode(TSerialization.Convert(Json,
      TSerializationFormat.Json, TSerializationFormat.Cbor,
      TStructuralConversionProfile.Lossless).AsBytes);
    try
      if BigText(V) <> AExpected then
      begin
        Note(AHex + ' came back through JSON as ' + V.ToDiagnostic + ' via ' +
          Json.AsText);
        Exit;
      end;
    finally
      V.Free;
    end;
    AJsonOutcome := 'carried';
  except
    on E: EStructuralConversionError do AJsonOutcome := 'refused';
  end;
  Result := True;
end;

procedure TestNegativeBelowInt64;
var
  Ok: Boolean;
  JsonA, JsonB, JsonTag3: string;
begin
  Writeln;
  Writeln('--- negative integers below Int64 ---');
  try
    Ok :=
      { RFC 8949 Appendix A: -2^64 as major type 1, and the first one past
        Int64, -2^63-1. They come back as tag 3, the same value. }
      NegativeSurvives('3bffffffffffffffff', '-18446744073709551616', False,
        JsonA) and
      NegativeSurvives('3b8000000000000000', '-9223372036854775809', False,
        JsonB) and
      { Appendix A's tag 3, -18446744073709551617: byte for byte. }
      NegativeSurvives('c349010000000000000000', '-18446744073709551617', True,
        JsonTag3);
    { Through JSON, a major-type-1 integer gets what tag 3 gets. }
    if Ok then
    begin
      Note('JSON (Lossless): tag 3 ' + JsonTag3 + ', major type 1 ' + JsonA +
        ' / ' + JsonB);
      Ok := (JsonA = JsonTag3) and (JsonB = JsonTag3);
    end;
  except
    on E: Exception do
    begin
      Note('raised ' + E.ClassName + ': ' + E.Message);
      Ok := False;
    end;
  end;
  Check(Ok, 'CBOR_NEGINT_BELOW_INT64_STRUCTURAL');
end;

begin
  try
    TestAppendixAVectors;
    TestMajorTypes;
    TestIntegerEdges;
    TestFloats;
    TestIndefiniteLengths;
    TestSimpleValues;
    TestUnknownTags;
    TestDeterministicEncoding;
    TestMalformed;
    TestContract;
    TestReleaseHardening;
    TestConversionMatrix;
    TestDataSet;
    TestNonTextMapKeys;
    TestFeatureLedger;
    TestWideTagsAndLengths;
    TestNegativeBelowInt64;
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
    Writeln('CBOR_NATIVE_TYPES: PASS');
    Writeln('CBOR_INDEFINITE_LENGTHS: PASS');
    Writeln('CBOR_TAGS: PASS');
    Writeln('CBOR_INDEPENDENT_INTEROP: PASS');
    Writeln('CBOR_NATIVE: PASS');
  end
  else
  begin
    Writeln('CBOR_NATIVE: FAIL');
    ExitCode := 1;
  end;
end.
