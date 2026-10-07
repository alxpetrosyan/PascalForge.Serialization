program BsonNative;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Is this actually a BSON codec?

  tests\BsonCore asks whether a Delphi object survives a round trip, which
  only proves the reader understands the writer. This program asks whether
  the bytes are right - measured against byte vectors this library did not
  produce - and whether every element type the specification defines is read
  and written.

  THE TARGET, named exactly:

      BSON specification version 1.1        https://bsonspec.org/spec.html

  THE INDEPENDENT REFERENCE is the specification's own published byte
  vectors, quoted below exactly as bsonspec.org gives them, plus vectors
  built by hand from the element-type table. There is no second BSON
  implementation available offline on this machine - no MongoDB driver, no
  Python bson - so the reference is the document rather than a running
  program, and this is said plainly rather than dressed up. What it does
  prove is that the bytes are the specification's bytes and not merely
  self-consistent.

  Two directions for every vector:

      vector -> decode -> expected values
      expected values -> encode -> the same vector, byte for byte

  BSON is deterministic for a given element order, so the second is a real
  equality and not an approximation. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.DateUtils, System.StrUtils,
  System.Generics.Collections,
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Bson in '..\..\src\PascalForge.Bson.pas',
  PascalForge.Bson.Internal in '..\..\src\PascalForge.Bson.Internal.pas';

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

function Hex(const ABytes: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ABytes) do Result := Result + IntToHex(ABytes[I], 2);
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

function Accepts(const AData: TBytes): Boolean;
var
  D: TBsonValue;
begin
  try
    D := TBsonEngine.ParseDocument(AData);
    D.Free;
    Result := True;
  except
    on EBsonError do Result := False;
  end;
end;

function Rejects(const AData: TBytes): Boolean;
begin
  Result := not Accepts(AData);
end;

{ Refused as a malformed document - EBsonInputError and nothing else. An
  access violation or a range error is not a refusal: it is the reader
  reading outside the buffer, and it is reported so. }
function RejectsAsInput(const AData: TBytes): Boolean;
var
  D: TBsonValue;
begin
  try
    D := TBsonEngine.ParseDocument(AData);
    D.Free;
    Result := False;
  except
    on E: EBsonInputError do Result := True;
    on E: Exception do
    begin
      Writeln('  ', E.ClassName, ': ', E.Message);
      Result := False;
    end;
  end;
end;

{ AProc raises exactly AClass (or a descendant); anything else is noted. }
function RaisesClass(AProc: TProc; AClass: ExceptClass): Boolean;
begin
  try
    AProc;
    Result := False;
  except
    on E: Exception do
    begin
      Result := E is AClass;
      if not Result then Writeln('  ', E.ClassName, ': ', E.Message);
    end;
  end;
end;

{ ===========================================================================
  1. THE SPECIFICATION'S OWN VECTORS

  These two appear on bsonspec.org under "Examples". They are quoted here
  byte for byte.
  =========================================================================== }

procedure TestSpecExamples;
var
  Doc: TBsonValue;
  Data, Ours: TBytes;
begin
  Writeln('-- the specification''s published examples --');

  { the document: "hello" mapped to "world" }
  Data := FromHex('16000000 02 68656C6C6F 00 06000000 776F726C6400 00');
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check((Doc.Count = 1) and (Doc.Names[0] = 'hello') and
          (Doc[0].Kind = TBsonKind.Str) and (Doc[0].AsString = 'world'),
      'SPEC_HELLO_WORLD_DECODE');
    Ours := TBsonEngine.WriteDocument(Doc);
    if not SameBytes(Ours, Data) then
    begin
      Note('spec : ' + Hex(Data));
      Note('ours : ' + Hex(Ours));
    end;
    Check(SameBytes(Ours, Data), 'SPEC_HELLO_WORLD_ENCODE');
  finally
    Doc.Free;
  end;

  { the document: "BSON" mapped to the array "awesome", 5.05, 1986 }
  Data := FromHex(
    '31000000' +
    '04' + '42534F4E' + '00' +
      '26000000' +
      '02' + '3000' + '08000000' + '617765736F6D6500' +
      '01' + '3100' + '3333333333331440' +
      '10' + '3200' + 'C2070000' +
      '00' +
    '00');
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check((Doc.Count = 1) and (Doc.Names[0] = 'BSON') and
          (Doc[0].Kind = TBsonKind.Arr) and (Doc[0].Count = 3) and
          (Doc[0][0].AsString = 'awesome') and
          (Abs(Doc[0][1].AsDouble - 5.05) < 1e-12) and
          (Doc[0][2].AsInt64 = 1986),
      'SPEC_BSON_ARRAY_DECODE');
    Ours := TBsonEngine.WriteDocument(Doc);
    if not SameBytes(Ours, Data) then
    begin
      Note('spec : ' + Hex(Data));
      Note('ours : ' + Hex(Ours));
    end;
    Check(SameBytes(Ours, Data), 'SPEC_BSON_ARRAY_ENCODE');
  finally
    Doc.Free;
  end;

  { An empty document is five bytes: the length, then the terminator. }
  Data := FromHex('0500000000');
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check(Doc.Count = 0, 'SPEC_EMPTY_DOCUMENT_DECODE');
    Check(SameBytes(TBsonEngine.WriteDocument(Doc), Data),
      'SPEC_EMPTY_DOCUMENT_ENCODE');
  finally
    Doc.Free;
  end;
end;

{ ===========================================================================
  2. EVERY ELEMENT TYPE THE SPECIFICATION DEFINES

  One vector per type byte, built from the element-type table: type byte,
  name as a C string, then the payload the table specifies. Each is decoded
  and then re-encoded and compared byte for byte.
  =========================================================================== }

type
  TTypeCase = record
    Marker: string;
    Hex: string;
  end;

{ A document around the given elements, with the length field computed.
  'v' as a one-character element name is 76 00. }
function Document(const AElements: string): string;
var
  Total: Integer;
begin
  { 4 bytes of length + elements + one terminator. }
  Total := 4 + Length(AElements) div 2 + 1;
  Result := IntToHex(Total and $FF, 2) + IntToHex((Total shr 8) and $FF, 2) +
            IntToHex((Total shr 16) and $FF, 2) +
            IntToHex((Total shr 24) and $FF, 2) + AElements + '00';
end;

procedure TestEveryElementType;
const
  CASES: array[0..19] of TTypeCase = (
    (Marker: 'TYPE_01_DOUBLE';      Hex: '01' + '7600' + '0000000000001440'),
    (Marker: 'TYPE_02_STRING';      Hex: '02' + '7600' + '02000000' + '6100'),
    (Marker: 'TYPE_03_DOCUMENT';    Hex: '03' + '7600' + '0500000000'),
    (Marker: 'TYPE_04_ARRAY';       Hex: '04' + '7600' + '0500000000'),
    (Marker: 'TYPE_05_BINARY_00';   Hex: '05' + '7600' + '02000000' + '00' + '0102'),
    (Marker: 'TYPE_05_BINARY_04';   Hex: '05' + '7600' + '10000000' + '04' +
                                          '000102030405060708090A0B0C0D0E0F'),
    (Marker: 'TYPE_05_BINARY_USER'; Hex: '05' + '7600' + '01000000' + '81' + 'FF'),
    (Marker: 'TYPE_06_UNDEFINED';   Hex: '06' + '7600'),
    (Marker: 'TYPE_07_OBJECTID';    Hex: '07' + '7600' + '507F1F77BCF86CD799439011'),
    (Marker: 'TYPE_08_BOOL_TRUE';   Hex: '08' + '7600' + '01'),
    (Marker: 'TYPE_09_DATETIME';    Hex: '09' + '7600' + '0000000000000000'),
    (Marker: 'TYPE_0A_NULL';        Hex: '0A' + '7600'),
    (Marker: 'TYPE_0B_REGEX';       Hex: '0B' + '7600' + '61626300' + '696D00'),
    (Marker: 'TYPE_0C_DBPOINTER';   Hex: '0C' + '7600' + '02000000' + '6300' +
                                          '507F1F77BCF86CD799439011'),
    (Marker: 'TYPE_0D_CODE';        Hex: '0D' + '7600' + '05000000' + '782B313B00'),
    (Marker: 'TYPE_0E_SYMBOL';      Hex: '0E' + '7600' + '02000000' + '7300'),
    (Marker: 'TYPE_10_INT32';       Hex: '10' + '7600' + 'D2040000'),
    (Marker: 'TYPE_11_TIMESTAMP';   Hex: '11' + '7600' + '0100000002000000'),
    (Marker: 'TYPE_12_INT64';       Hex: '12' + '7600' + 'FFFFFFFFFFFFFF7F'),
    (Marker: 'TYPE_13_DECIMAL128';  Hex: '13' + '7600' +
                                          '0100000000000000000000000000403C')
  );
var
  I: Integer;
  Data, Ours: TBytes;
  Doc: TBsonValue;
  AllOk: Boolean;
begin
  Writeln;
  Writeln('-- every element type the specification defines --');
  AllOk := True;

  for I := Low(CASES) to High(CASES) do
  begin
    Data := FromHex(Document(CASES[I].Hex));
    try
      Doc := TBsonEngine.ParseDocument(Data);
    except
      on E: Exception do
      begin
        Check(False, CASES[I].Marker);
        Note('decode: ' + E.Message);
        AllOk := False;
        Continue;
      end;
    end;
    try
      Ours := TBsonEngine.WriteDocument(Doc);
      if not SameBytes(Ours, Data) then
      begin
        Note('vector: ' + Hex(Data));
        Note('ours  : ' + Hex(Ours));
        AllOk := False;
      end;
      Check(SameBytes(Ours, Data), CASES[I].Marker);
    finally
      Doc.Free;
    end;
  end;

  { MinKey and MaxKey have the two type bytes at the ends of the range. }
  Data := FromHex(Document('FF' + '7600'));
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check((Doc[0].Kind = TBsonKind.MinKey) and
          SameBytes(TBsonEngine.WriteDocument(Doc), Data), 'TYPE_FF_MINKEY');
  finally
    Doc.Free;
  end;

  Data := FromHex(Document('7F' + '7600'));
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check((Doc[0].Kind = TBsonKind.MaxKey) and
          SameBytes(TBsonEngine.WriteDocument(Doc), Data), 'TYPE_7F_MAXKEY');
  finally
    Doc.Free;
  end;

  { Code with scope carries its own total length, which has to be written as
    well as read. }
  Data := FromHex(Document('0F' + '7600' +
    '12000000' +                          { total: 4 + 9 + 5 = 18 }
    '05000000' + '782B313B00' +           { code "x+1;" }
    '0500000000'));                       { empty scope document }
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check((Doc[0].Kind = TBsonKind.JavaScriptScope) and
          (Doc[0].AsCode = 'x+1;') and
          SameBytes(TBsonEngine.WriteDocument(Doc), Data),
      'TYPE_0F_CODE_WITH_SCOPE');
  finally
    Doc.Free;
  end;

  Check(AllOk, 'NATIVE_TYPE_COMPATIBILITY');
end;

{ ===========================================================================
  3. VALUES, NOT JUST SHAPES
  =========================================================================== }

procedure TestValues;
var
  Doc: TBsonValue;
  Data: TBytes;
begin
  Writeln;
  Writeln('-- the values the vectors carry --');

  Data := FromHex(Document('01' + '7600' + '0000000000001440'));
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check(Abs(Doc[0].AsDouble - 5.0) < 1e-12, 'VALUE_DOUBLE');
  finally
    Doc.Free;
  end;

  Data := FromHex(Document('12' + '7600' + 'FFFFFFFFFFFFFF7F'));
  Doc := TBsonEngine.ParseDocument(Data);
  try
    { The largest Int64. A codec that routed integers through Double would
      lose the bottom bits here, and this is where that shows. }
    Check(Doc[0].AsInt64 = 9223372036854775807, 'VALUE_INT64_MAX');
  finally
    Doc.Free;
  end;

  Data := FromHex(Document('10' + '7600' + '00000080'));
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check(Doc[0].AsInt64 = -2147483648, 'VALUE_INT32_MIN');
  finally
    Doc.Free;
  end;

  Data := FromHex(Document('07' + '7600' + '507F1F77BCF86CD799439011'));
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check(Doc[0].AsObjectId.ToHex = '507f1f77bcf86cd799439011',
      'VALUE_OBJECTID_HEX');
  finally
    Doc.Free;
  end;

  Data := FromHex(Document('11' + '7600' + '0100000002000000'));
  Doc := TBsonEngine.ParseDocument(Data);
  try
    { A BSON timestamp is two uint32s in one uint64: increment in the low
      word, seconds in the high word. It is NOT a datetime, and is not
      converted into one. }
    Check(Doc[0].AsTimestamp = (UInt64(2) shl 32) or 1, 'VALUE_TIMESTAMP');
    Check(Doc[0].Kind <> TBsonKind.DateTime, 'VALUE_TIMESTAMP_IS_NOT_A_DATE');
  finally
    Doc.Free;
  end;

  { The Unix epoch, as BSON writes it: zero milliseconds. }
  Data := FromHex(Document('09' + '7600' + '0000000000000000'));
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check(Abs(Doc[0].AsDateTime - UnixDateDelta) < 1e-9, 'VALUE_DATETIME_EPOCH');
  finally
    Doc.Free;
  end;

  { Before 1899-12-30 a TDateTime is a negative day with a POSITIVE time of
    day. 1800-01-01T12:00Z is -5364619200000 ms; the writer used to compute
    it linearly and put the instant a day early, at -5364705600000. Both
    directions, byte for byte. }
  Data := FromHex(Document('09' + '7600' + '003AC7F31EFBFFFF'));
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check(SameDateTime(Doc[0].AsDateTime, EncodeDateTime(1800, 1, 1, 12, 0, 0, 0)),
      'VALUE_DATETIME_BEFORE_1899_DECODE');
  finally
    Doc.Free;
  end;
  Doc := TBsonValue.NewDocument;
  try
    Doc.Add('v', TBsonValue.NewDateTime(EncodeDateTime(1800, 1, 1, 12, 0, 0, 0)));
    Check(SameBytes(TBsonEngine.WriteDocument(Doc), Data),
      'VALUE_DATETIME_BEFORE_1899_ENCODE');
  finally
    Doc.Free;
  end;
  { 1899-12-29T06:00Z, the TDateTime -1.25: -2209226400000 ms. }
  Doc := TBsonValue.NewDocument;
  try
    Doc.Add('v', TBsonValue.NewDateTime(EncodeDateTime(1899, 12, 29, 6, 0, 0, 0)));
    Check(SameBytes(TBsonEngine.WriteDocument(Doc),
      FromHex(Document('09' + '7600' + '005FD89FFDFDFFFF'))),
      'VALUE_DATETIME_DAY_BEFORE_DELPHI_EPOCH_ENCODE');
  finally
    Doc.Free;
  end;

  { UTF-8 in both a value and a name. }
  { name: one Georgian letter. value: two Georgian letters and an 'A' -
    seven UTF-8 bytes, so the declared length is eight with the terminator. }
  Data := FromHex(Document('02' + 'E1839A00' + '08000000' + 'E1839AE1839041' + '00'));
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check((Doc.Names[0] = #$10DA) and (Doc[0].AsString = #$10DA#$10D0'A'),
      'VALUE_UTF8_NAME_AND_STRING');
    Check(SameBytes(TBsonEngine.WriteDocument(Doc), Data),
      'VALUE_UTF8_ENCODES_BACK');
  finally
    Doc.Free;
  end;

  { A binary subtype outside the two the library names must survive. }
  Data := FromHex(Document('05' + '7600' + '01000000' + '81' + 'FF'));
  Doc := TBsonEngine.ParseDocument(Data);
  try
    Check(Doc[0].SubtypeByte = $81, 'VALUE_USER_BINARY_SUBTYPE_PRESERVED');
  finally
    Doc.Free;
  end;
end;

{ ===========================================================================
  4. MALFORMED INPUT
  =========================================================================== }

type
  TTextHolder = class
  public
    S: string;
  end;

  TBytesHolder = class
  public
    B: TBytes;
  end;

procedure TestMalformed;
var
  Big: TBytes;
begin
  Writeln;
  Writeln('-- malformed input --');

  Check(Rejects(nil), 'MALFORMED_EMPTY');
  Check(Rejects(FromHex('01020304')), 'MALFORMED_TOO_SHORT');
  { A length that claims more than the buffer holds. }
  Check(Rejects(FromHex('2000000000')), 'MALFORMED_LENGTH_TOO_LARGE');
  { A length smaller than an empty document. }
  Check(Rejects(FromHex('0100000000')), 'MALFORMED_LENGTH_TOO_SMALL');
  { A negative length. }
  Check(Rejects(FromHex('FFFFFFFF00')), 'MALFORMED_NEGATIVE_LENGTH');
  { No terminating zero. }
  Check(Rejects(FromHex('0500000001')), 'MALFORMED_MISSING_TERMINATOR');
  { An undefined element type byte. }
  Check(Rejects(FromHex(Document('63' + '7600'))), 'MALFORMED_UNKNOWN_TYPE');
  { A string whose declared length runs past the document. }
  Check(Rejects(FromHex(Document('02' + '7600' + 'FF000000' + '6100'))),
    'MALFORMED_STRING_OVERRUNS');
  { A string with a zero length - the length includes the terminator, so it
    can never be zero. }
  Check(Rejects(FromHex(Document('02' + '7600' + '00000000'))),
    'MALFORMED_STRING_ZERO_LENGTH');
  { A binary element with a negative length. }
  Check(Rejects(FromHex(Document('05' + '7600' + 'FFFFFFFF' + '00'))),
    'MALFORMED_BINARY_NEGATIVE_LENGTH');
  { An unterminated element name. }
  Check(Rejects(FromHex('0700000010' + '76')), 'MALFORMED_UNTERMINATED_NAME');
  { An ObjectId cut short. }
  Check(Rejects(FromHex(Document('07' + '7600' + '507F1F77'))),
    'MALFORMED_OBJECTID_TRUNCATED');
  { A code-with-scope whose declared total does not match its contents. }
  Check(Rejects(FromHex(Document('0F' + '7600' + 'FF000000' +
    '05000000' + '782B313B00' + '0500000000'))),
    'MALFORMED_CODE_SCOPE_LENGTH');
  { Bytes after the root document. }
  Check(Rejects(FromHex('050000000000')), 'MALFORMED_TRAILING_BYTES');

  { A length field claiming two gigabytes, with nothing behind it. The check
    is that this fails immediately on the buffer bound rather than trying to
    allocate what the document asked for. }
  Big := FromHex('FFFFFF7F00');
  Check(Rejects(Big), 'MALFORMED_ALLOCATION_BOMB');

  { The same two gigabytes declared INSIDE a document whose own length is
    right. The bound was FPos + length > the buffer, which overflowed to a
    negative number and passed, so the string read went gigabytes past the
    buffer (an access violation) and the binary one asked for a range the
    array does not have. }
  Check(RejectsAsInput(FromHex('0E000000' + '02' + '5300' + 'FFFFFF7F' +
    '7800' + '00')), 'MALFORMED_STRING_LENGTH_NEAR_MAXINT');
  Check(RejectsAsInput(FromHex('0F000000' + '05' + '4200' + 'FFFFFF7F' + '00' +
    '7800' + '00')), 'MALFORMED_BINARY_LENGTH_NEAR_MAXINT');
  Check(RejectsAsInput(FromHex('0D000000' + '03' + '6100' + 'FFFFFF7F' +
    '00' + '00')), 'MALFORMED_SUBDOCUMENT_LENGTH_NEAR_MAXINT');
  Check(RejectsAsInput(FromHex('0D000000' + '0F' + '6100' + 'FFFFFF7F' +
    '00' + '00')), 'MALFORMED_CODE_SCOPE_LENGTH_NEAR_MAXINT');
  { And through the contract, which parses the same way. }
  Check(RaisesClass(
    procedure
    begin
      TBsonSerializer.Deserialize<TTextHolder>(FromHex('0E000000' + '02' +
        '5300' + 'FFFFFF7F' + '7800' + '00')).Free;
    end, EBsonInputError), 'MALFORMED_STRING_LENGTH_NEAR_MAXINT_CONTRACT');
  Check(RaisesClass(
    procedure
    begin
      TBsonSerializer.Deserialize<TBytesHolder>(FromHex('0F000000' + '05' +
        '4200' + 'FFFFFF7F' + '00' + '7800' + '00')).Free;
    end, EBsonInputError), 'MALFORMED_BINARY_LENGTH_NEAR_MAXINT_CONTRACT');
end;

{ ===========================================================================
  5. ROUND TRIP THROUGH THE VALUE MODEL

  Everything built by hand, written, read back, and compared - so the writer
  and the reader are checked against each other as well as against the
  vectors.
  =========================================================================== }

procedure TestRoundTrip;
var
  Doc, Back, Scope: TBsonValue;
  Data: TBytes;
  Id: TBsonObjectId;
begin
  Writeln;
  Writeln('-- the whole element table, built and read back --');
  Id := TBsonObjectId.FromHex('507f1f77bcf86cd799439011');

  Doc := TBsonValue.NewDocument;
  try
    Doc.Add('d', TBsonValue.NewDouble(5.05));
    Doc.Add('s', TBsonValue.NewString('text'));
    Doc.Add('sub', TBsonValue.NewDocument);
    Doc.Add('arr', TBsonValue.NewArray);
    Doc.Add('bin', TBsonValue.NewBinary(TBytes.Create(1, 2, 3)));
    Doc.Add('uuid', TBsonValue.NewBinary(TBytes.Create(1), TBsonBinarySubtype.Uuid));
    Doc.Add('user', TBsonValue.NewBinary(TBytes.Create(9), Byte($81)));
    Doc.Add('undef', TBsonValue.NewUndefined);
    Doc.Add('oid', TBsonValue.NewObjectId(Id));
    Doc.Add('b', TBsonValue.NewBool(True));
    Doc.Add('dt', TBsonValue.NewDateTime(EncodeDate(2026, 3, 14)));
    Doc.Add('n', TBsonValue.NewNull);
    Doc.Add('re', TBsonValue.NewRegex('a.c', 'im'));
    Doc.Add('dbp', TBsonValue.NewDbPointer('c', Id));
    Doc.Add('js', TBsonValue.NewJavaScript('x+1;'));
    Doc.Add('sym', TBsonValue.NewSymbol('s'));
    Scope := TBsonValue.NewDocument;
    Scope.Add('x', TBsonValue.NewInt32(1));
    Doc.Add('jss', TBsonValue.NewJavaScriptScope('x+1;', Scope));
    Doc.Add('i32', TBsonValue.NewInt32(1234));
    Doc.Add('ts', TBsonValue.NewTimestamp((UInt64(2) shl 32) or 1));
    Doc.Add('i64', TBsonValue.NewInt64(9223372036854775807));
    Doc.Add('dec', TBsonValue.NewDecimal128(
      FromHex('0100000000000000000000000000403C')));
    Doc.Add('min', TBsonValue.NewMinKey);
    Doc.Add('max', TBsonValue.NewMaxKey);

    Data := TBsonEngine.WriteDocument(Doc);
  finally
    Doc.Free;
  end;
  Note(Format('%d elements, %d bytes', [23, Length(Data)]));

  Back := TBsonEngine.ParseDocument(Data);
  try
    Check(Back.Count = 23, 'ROUNDTRIP_ELEMENT_COUNT');
    Check(Back.Find('oid').AsObjectId.Equals(Id), 'ROUNDTRIP_OBJECTID');
    Check(Back.Find('ts').AsTimestamp = (UInt64(2) shl 32) or 1,
      'ROUNDTRIP_TIMESTAMP');
    Check(Back.Find('re').AsPattern = 'a.c', 'ROUNDTRIP_REGEX_PATTERN');
    Check(Back.Find('re').AsOptions = 'im', 'ROUNDTRIP_REGEX_OPTIONS');
    Check(Back.Find('jss').Scope.Find('x').AsInt64 = 1, 'ROUNDTRIP_CODE_SCOPE');
    Check(Back.Find('user').SubtypeByte = $81, 'ROUNDTRIP_BINARY_SUBTYPE');
    Check(Back.Find('dec').Kind = TBsonKind.Decimal128, 'ROUNDTRIP_DECIMAL128');
    Check(Back.Find('min').Kind = TBsonKind.MinKey, 'ROUNDTRIP_MINKEY');
    Check(Back.Find('max').Kind = TBsonKind.MaxKey, 'ROUNDTRIP_MAXKEY');
    Check(Back.Find('undef').Kind = TBsonKind.Undefined, 'ROUNDTRIP_UNDEFINED');
    Check(Back.Find('sym').Kind = TBsonKind.Symbol, 'ROUNDTRIP_SYMBOL');
    Check(Back.Find('dbp').AsObjectId.Equals(Id), 'ROUNDTRIP_DBPOINTER');

    { And the bytes are stable: writing what was read gives the same bytes. }
    Check(SameBytes(TBsonEngine.WriteDocument(Back), Data),
      'ROUNDTRIP_BYTES_ARE_STABLE');
  finally
    Back.Free;
  end;
end;

{ ===========================================================================
  6. AN OBJECTID MEMBER, THROUGH THE CONTRACT

  TBsonObjectId keeps its twelve bytes in an inline array that has no RTTI.
  The shared refusal rule refuses exactly that in a record it knows nothing
  about, and it once refused this one too - so a DTO with an ObjectId member
  could not be serialized at all. BSON knows the type and writes the element.
  =========================================================================== }

type
  TOidHolder = class
  public
    Id: TBsonObjectId;
    Name: string;
  end;

procedure TestObjectIdMember;
var
  Obj, Back: TOidHolder;
  Data: TBytes;
begin
  Writeln;
  Writeln('-- an ObjectId member, written and read by the contract --');
  Obj := TOidHolder.Create;
  try
    Obj.Id := TBsonObjectId.FromHex('507f1f77bcf86cd799439011');
    Obj.Name := 'n';
    Data := TBsonSerializer.Serialize<TOidHolder>(Obj);
  finally
    Obj.Free;
  end;
  { element type 07 followed by "Id" 00 and the twelve bytes }
  Check(Pos('07496400507F1F77BCF86CD799439011', UpperCase(Hex(Data))) > 0,
    'OBJECTID_MEMBER_IS_AN_OBJECTID_ELEMENT');
  Back := TBsonSerializer.Deserialize<TOidHolder>(Data);
  try
    Check(Back.Id.ToHex = '507f1f77bcf86cd799439011',
      'OBJECTID_MEMBER_ROUND_TRIP');
  finally
    Back.Free;
  end;
end;

{ ===========================================================================
  7. A TGUID AS BINARY SUBTYPE 4

  The BSON corpus (bson-corpus, binary.json, "subtype 0x04 UUID") gives
  the UUID 73ffd264-44b3-4c69-90e8-e7d1dfc035d4 as these bytes: RFC 4122
  order, the order the text reads, which is what a driver and mongosh show.
  A TGUID keeps D1, D2 and D3 little-endian in memory, and copying that
  memory wrote 64D2FF73 B344 694C instead - a different UUID to everyone
  else - and read the corpus bytes as a different GUID.
  =========================================================================== }

type
  TUuidHolder = class
  public
    [BsonName('x')] X: TGUID;
  end;

procedure TestUuidSubtype4;
const
  CORPUS_UUID = '1D000000057800100000000473FFD26444B34C6990E8E7D1DFC035D400';
  { The corpus's legacy "subtype 0x03" case: the same sixteen bytes. }
  CORPUS_LEGACY = '1D000000057800100000000373FFD26444B34C6990E8E7D1DFC035D400';
var
  Obj, Back: TUuidHolder;
  G: TGUID;
  Data: TBytes;
  Doc: TBsonValue;
begin
  Writeln;
  Writeln('-- a TGUID member is binary subtype 4 in RFC 4122 order --');
  G := StringToGUID('{73FFD264-44B3-4C69-90E8-E7D1DFC035D4}');
  Obj := TUuidHolder.Create;
  try
    Obj.X := G;
    Data := TBsonSerializer.Serialize<TUuidHolder>(Obj);
  finally
    Obj.Free;
  end;
  if Hex(Data) <> CORPUS_UUID then
  begin
    Note('corpus: ' + CORPUS_UUID);
    Note('ours  : ' + Hex(Data));
  end;
  Check(Hex(Data) = CORPUS_UUID, 'CORPUS_UUID_SUBTYPE4_ENCODE');

  Back := TBsonSerializer.Deserialize<TUuidHolder>(FromHex(CORPUS_UUID));
  try
    Check(Back.X = G, 'CORPUS_UUID_SUBTYPE4_DECODE');
  finally
    Back.Free;
  end;

  Doc := TBsonEngine.ParseDocument(FromHex(CORPUS_UUID));
  try
    Check((Doc[0].Kind = TBsonKind.Binary) and
          (Doc[0].Subtype = TBsonBinarySubtype.Uuid) and
          (Hex(Doc[0].AsBytes) = '73FFD26444B34C6990E8E7D1DFC035D4'),
      'CORPUS_UUID_ELEMENT_BYTES');
  finally
    Doc.Free;
  end;

  { Sixteen bytes under the legacy subtype 3, whose byte order each driver
    chose for itself, are read as they always were: in TGUID's own layout. }
  Back := TBsonSerializer.Deserialize<TUuidHolder>(FromHex(CORPUS_LEGACY));
  try
    Check(Back.X = StringToGUID('{64D2FF73-B344-694C-90E8-E7D1DFC035D4}'),
      'UUID_LEGACY_SUBTYPE3_READ_UNCHANGED');
  finally
    Back.Free;
  end;
end;

{ ===========================================================================
  8. WHAT WRITEDOCUMENT REFUSES

  WriteDocument never writes what ParseDocument refuses: a tree nested
  deeper than the reader's 512 documents and arrays, nil where a document or
  an element belongs, and text UTF-8 cannot encode.
  =========================================================================== }

function Nested(ADepth: Integer): TBsonValue;
var
  I: Integer;
  Cur, Child: TBsonValue;
begin
  Result := TBsonValue.NewDocument;
  Cur := Result;
  for I := 2 to ADepth do
  begin
    Child := TBsonValue.NewDocument;
    Cur.Add('a', Child);
    Cur := Child;
  end;
end;

procedure TestWriteDocumentRefusals;
var
  Doc, Back: TBsonValue;
  Data: TBytes;
begin
  Writeln;
  Writeln('-- what WriteDocument refuses --');

  Doc := Nested(512);
  try
    Data := TBsonEngine.WriteDocument(Doc);
  finally
    Doc.Free;
  end;
  Back := TBsonEngine.ParseDocument(Data);
  Back.Free;
  Check(Length(Data) > 0, 'WRITEDOCUMENT_512_DEEP_WRITTEN_AND_READ');

  { One deeper, or any deeper, wrote a document its own reader refused. }
  Doc := Nested(513);
  try
    Check(RaisesClass(
      procedure begin TBsonEngine.WriteDocument(Doc); end, EBsonInternalError),
      'WRITEDOCUMENT_513_DEEP_REFUSED');
  finally
    Doc.Free;
  end;
  Doc := Nested(600);
  try
    Check(RaisesClass(
      procedure begin TBsonEngine.WriteDocument(Doc); end, EBsonInternalError),
      'WRITEDOCUMENT_600_DEEP_REFUSED');
  finally
    Doc.Free;
  end;

  Check(RaisesClass(
    procedure begin TBsonSerializer.WriteDocument(nil); end, EBsonInternalError),
    'WRITEDOCUMENT_NIL_REFUSED');
  Doc := TBsonValue.NewDocument;
  try
    Doc.Add('a', nil);
    Check(RaisesClass(
      procedure begin TBsonEngine.WriteDocument(Doc); end, EBsonInternalError),
      'WRITEDOCUMENT_NIL_ELEMENT_REFUSED');
  finally
    Doc.Free;
  end;

  { An unpaired surrogate is half a character; TEncoding wrote U+FFFD in its
    place, so the text read back was not the text written. }
  Doc := TBsonValue.NewDocument;
  try
    Doc.Add('s', TBsonValue.NewString('a' + Char($D800) + 'b'));
    Check(RaisesClass(
      procedure begin TBsonEngine.WriteDocument(Doc); end,
      ESerializationUnsupported), 'WRITEDOCUMENT_LONE_SURROGATE_VALUE_REFUSED');
  finally
    Doc.Free;
  end;
  Doc := TBsonValue.NewDocument;
  try
    Doc.Add('n' + Char($DC00), TBsonValue.NewInt32(1));
    Check(RaisesClass(
      procedure begin TBsonEngine.WriteDocument(Doc); end,
      ESerializationUnsupported), 'WRITEDOCUMENT_LONE_SURROGATE_NAME_REFUSED');
  finally
    Doc.Free;
  end;
  { A real pair is one character, and is written as its four UTF-8 bytes. }
  Doc := TBsonValue.NewDocument;
  try
    Doc.Add('S', TBsonValue.NewString(Char($D83D) + Char($DE00)));
    Check(Hex(TBsonEngine.WriteDocument(Doc)) =
      '1100000002530005000000F09F98800000', 'WRITEDOCUMENT_SURROGATE_PAIR_WRITTEN');
  finally
    Doc.Free;
  end;
end;

{ ===========================================================================
  A DOUBLE INTO AN INT64, AND LENGTHS PAST MaxInt

  A double converts to an Int64 exactly when -2^63 <= D < 2^63 (and it is
  integral). Both bounds are Doubles; High(Int64) is not. The decimal
  literal the reader used to compare against was 2^63 - 8 at Win32's
  Extended precision and 2^63 at Win64's Double, so Low(Int64) itself was
  refused on Win32 only. The values are built from their bit patterns so
  that neither platform's literal parsing is in the test.
  =========================================================================== }

type
  TI64Holder = class
  public
    N: Int64;
  end;

function DoubleOfBits(ABits: UInt64): Double;
begin
  Move(ABits, Result, 8);
end;

{ Through the contract (a double element into an Int64 member) and through
  TBsonValue.AsInt64. 'accept(n)' only when both accept with the same n;
  'refuse' only when both raise an EBsonError. Anything else is reported as
  itself and cannot match an expected set. }
function DoubleIntoInt64(AValue: Double): string;
var
  Doc: TBsonValue;
  Data: TBytes;
  Obj: TI64Holder;
  Contract, Direct: string;
begin
  Doc := TBsonValue.NewDocument;
  try
    Doc.Add('N', TBsonValue.NewDouble(AValue));
    Data := TBsonEngine.WriteDocument(Doc);
    try
      Obj := TBsonSerializer.Deserialize<TI64Holder>(Data);
      try
        Contract := Format('accept(%d)', [Obj.N]);
      finally
        Obj.Free;
      end;
    except
      on E: EBsonError do Contract := 'refuse';
      on E: Exception do Contract := 'raised ' + E.ClassName;
    end;
    try
      Direct := Format('accept(%d)', [Doc[0].AsInt64]);
    except
      on E: EBsonError do Direct := 'refuse';
      on E: Exception do Direct := 'raised ' + E.ClassName;
    end;
  finally
    Doc.Free;
  end;
  if Contract = Direct then Result := Contract
  else Result := 'contract ' + Contract + ' / AsInt64 ' + Direct;
end;

procedure TestDoubleIntoInt64;
const
  { exactly the set both platforms must print }
  EXPECTED =
    'neg2p63=accept(-9223372036854775808) ' +
    'below2p63=accept(9223372036854774784) ' +
    '2p63=refuse ' +
    'neg2p63minus1ulp=refuse';
var
  Neg2p63, Below2p63, Pos2p63, BelowNeg2p63: string;
  PlatformSet, Marker: string;
  AllRefused: Boolean;
  procedure Refused(AValue: Double; const ALabel: string);
  var
    R: string;
  begin
    R := DoubleIntoInt64(AValue);
    Note(ALabel + ' -> ' + R);
    if R <> 'refuse' then AllRefused := False;
  end;
begin
  Writeln;
  Writeln('-- a double into an Int64 --');
  Neg2p63 := DoubleIntoInt64(DoubleOfBits($C3E0000000000000));      { -2^63 }
  Below2p63 := DoubleIntoInt64(DoubleOfBits($43DFFFFFFFFFFFFF));    { 2^63 - 1024 }
  Pos2p63 := DoubleIntoInt64(DoubleOfBits($43E0000000000000));      { 2^63 }
  BelowNeg2p63 := DoubleIntoInt64(DoubleOfBits($C3E0000000000001)); { next below -2^63 }
  PlatformSet := 'neg2p63=' + Neg2p63 + ' below2p63=' + Below2p63 +
    ' 2p63=' + Pos2p63 + ' neg2p63minus1ulp=' + BelowNeg2p63;
  {$IFDEF WIN64}
  Marker := 'BSON_DOUBLE_INT64_BOUND_WIN64';
  {$ELSE}
  Marker := 'BSON_DOUBLE_INT64_BOUND_WIN32';
  {$ENDIF}
  Check((Neg2p63 = Format('accept(%d)', [Low(Int64)])) and
    (Below2p63 = 'accept(9223372036854774784)') and
    (Pos2p63 = 'refuse') and (BelowNeg2p63 = 'refuse'), Marker);
  Note('set: ' + PlatformSet);
  Check(PlatformSet = EXPECTED, 'BSON_DOUBLE_INT64_PLATFORM_PARITY');

  AllRefused := True;
  Refused(1e19, '1e19');
  Refused(-1e19, '-1e19');
  Refused(1e300, '1e300');
  Refused(DoubleOfBits($7FF8000000000000), 'NaN');
  Refused(DoubleOfBits($7FF0000000000000), '+Inf');
  Refused(DoubleOfBits($FFF0000000000000), '-Inf');
  Check(AllRefused, 'BSON_DOUBLE_INT64_OUT_OF_RANGE_REFUSES');
end;

{ Small documents that DECLARE a length near or past MaxInt: refused as
  malformed input, before anything that size is allocated or read. }
procedure TestLengthOverMaxInt;
begin
  Writeln;
  Writeln('-- declared lengths at MaxInt and past it --');
  Check(RejectsAsInput(FromHex('FFFFFF7F00')) and
    RejectsAsInput(FromHex('FFFFFFFF00')) and
    { a string, then a binary, then a code-with-scope declaring 2^31 - 1 }
    RejectsAsInput(FromHex(Document('02' + '7600' + 'FFFFFF7F' + '6100'))) and
    RejectsAsInput(FromHex(Document('05' + '7600' + 'FFFFFF7F' + '00' + '61'))) and
    RejectsAsInput(FromHex(Document('0F' + '7600' + 'FFFFFF7F' + '0000'))) and
    { 0xFFFFFFFF as a string length: -1, past MaxInt read unsigned }
    RejectsAsInput(FromHex(Document('02' + '7600' + 'FFFFFFFF' + '6100'))),
    'BSON_LENGTH_OVER_MAXINT_REFUSES');
end;

begin
  try
    TestDoubleIntoInt64;
    TestLengthOverMaxInt;
    TestSpecExamples;
    TestEveryElementType;
    TestValues;
    TestMalformed;
    TestRoundTrip;
    TestObjectIdMember;
    TestUuidSubtype4;
    TestWriteDocumentRefusals;
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
    Writeln('MALFORMED_INPUT_VALIDATION: PASS');
    Writeln('INDEPENDENT_INTEROP_DECODE: PASS');
    Writeln('INDEPENDENT_INTEROP_ENCODE: PASS');
    Writeln('BSON_NATIVE: PASS');
  end
  else
  begin
    Writeln('BSON_NATIVE: FAIL');
    ExitCode := 1;
  end;
end.
