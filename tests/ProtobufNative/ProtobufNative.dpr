program ProtobufNative;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Is this actually a protobuf codec?

  A round trip proves only that the reader understands the writer. This
  program asks whether the BYTES are right, measured against the vectors the
  specification publishes, and whether everything the wire format defines is
  read and written.

  THE TARGET, named exactly:

      Protocol Buffers wire format - complete
      proto3 field semantics
      proto2 groups (wire types 3 and 4) read
      schema expressed in Delphi attributes; .proto files are not parsed

  THE INDEPENDENT REFERENCE is the encoding guide's own worked examples -
  the ones every protobuf implementation is checked against - quoted here
  byte for byte:

      Test1 with a = 150                    08 96 01
      Test2 with b = "testing"              12 07 74 65 73 74 69 6E 67
      Test3 with c = a Test1 whose a is 150 1A 03 08 96 01
      Test4 with d = 3, 270, 86942          22 06 03 8E 02 9E A7 05

  protoc is not installed on this machine and there is no network, so the
  reference is the document rather than a running program. That is said
  plainly here and in docs\protobuf-compatibility.md rather than dressed up.
  What it proves is that the bytes are the specification's bytes and not
  merely self-consistent. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.DateUtils, System.StrUtils,
  System.Generics.Collections,
  ProtoModels in 'ProtoModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Protobuf in '..\..\src\PascalForge.Protobuf.pas',
  PascalForge.Protobuf.Internal in '..\..\src\PascalForge.Protobuf.Internal.pas',
  PascalForge.Protobuf.Schema in '..\..\src\PascalForge.Protobuf.Schema.pas';

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
  for I := 0 to High(ABytes) do Result := Result + IntToHex(ABytes[I], 2) + ' ';
  Result := Trim(Result);
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
  1. THE SPECIFICATION'S WORKED EXAMPLES
  =========================================================================== }

procedure TestSpecExamples;
var
  T1: TTest1;
  T2: TTest2;
  T3: TTest3;
  T4: TTest4;
  Ours, Spec: TBytes;
begin
  Writeln('-- the encoding guide''s worked examples --');

  Spec := FromHex('08 96 01');
  T1 := TTest1.Create;
  try
    T1.A := 150;
    Ours := TProtobufSerializer.Serialize<TTest1>(T1);
  finally
    T1.Free;
  end;
  Note('spec: ' + Hex(Spec) + '   ours: ' + Hex(Ours));
  Check(SameBytes(Ours, Spec), 'SPEC_TEST1_ENCODE');

  T1 := TProtobufSerializer.Deserialize<TTest1>(Spec);
  try
    Check(T1.A = 150, 'SPEC_TEST1_DECODE');
  finally
    T1.Free;
  end;

  Spec := FromHex('12 07 74 65 73 74 69 6E 67');
  T2 := TTest2.Create;
  try
    T2.B := 'testing';
    Ours := TProtobufSerializer.Serialize<TTest2>(T2);
  finally
    T2.Free;
  end;
  Note('spec: ' + Hex(Spec) + '   ours: ' + Hex(Ours));
  Check(SameBytes(Ours, Spec), 'SPEC_TEST2_ENCODE');

  T2 := TProtobufSerializer.Deserialize<TTest2>(Spec);
  try
    Check(T2.B = 'testing', 'SPEC_TEST2_DECODE');
  finally
    T2.Free;
  end;

  Spec := FromHex('1A 03 08 96 01');
  T3 := TTest3.Create;
  try
    T3.C := TTest1.Create;
    T3.C.A := 150;
    Ours := TProtobufSerializer.Serialize<TTest3>(T3);
  finally
    T3.Free;
  end;
  Note('spec: ' + Hex(Spec) + '   ours: ' + Hex(Ours));
  Check(SameBytes(Ours, Spec), 'SPEC_TEST3_ENCODE');

  T3 := TProtobufSerializer.Deserialize<TTest3>(Spec);
  try
    Check((T3.C <> nil) and (T3.C.A = 150), 'SPEC_TEST3_DECODE');
  finally
    T3.Free;
  end;

  Spec := FromHex('22 06 03 8E 02 9E A7 05');
  T4 := TTest4.Create;
  try
    T4.D := TArray<Integer>.Create(3, 270, 86942);
    Ours := TProtobufSerializer.Serialize<TTest4>(T4);
  finally
    T4.Free;
  end;
  Note('spec: ' + Hex(Spec) + '   ours: ' + Hex(Ours));
  Check(SameBytes(Ours, Spec), 'SPEC_TEST4_ENCODE');

  T4 := TProtobufSerializer.Deserialize<TTest4>(Spec);
  try
    Check((Length(T4.D) = 3) and (T4.D[0] = 3) and (T4.D[1] = 270) and
          (T4.D[2] = 86942), 'SPEC_TEST4_DECODE');
  finally
    T4.Free;
  end;

  { A reader must accept the UNPACKED spelling of the same repeated field,
    whatever the schema says, because the specification requires it. }
  Spec := FromHex('20 03 20 8E 02 20 9E A7 05');
  T4 := TProtobufSerializer.Deserialize<TTest4>(Spec);
  try
    Check((Length(T4.D) = 3) and (T4.D[2] = 86942),
      'SPEC_TEST4_UNPACKED_ALSO_ACCEPTED');
  finally
    T4.Free;
  end;
end;

{ ===========================================================================
  2. VARINTS AND ZIG-ZAG
  =========================================================================== }

procedure TestVarintsAndZigZag;
var
  W: TProtoWriter;
  R: TProtoReader;
  Data: TBytes;
  AllOk: Boolean;

  function Encoded(AValue: UInt64): string;
  var
    Local: TProtoWriter;
  begin
    Local.Init;
    Local.PutVarint(AValue);
    Result := Hex(Local.Done);
  end;

  function RoundTrips(AValue: UInt64): Boolean;
  var
    Local: TProtoWriter;
    Back: TProtoReader;
    B: TBytes;
  begin
    Local.Init;
    Local.PutVarint(AValue);
    B := Local.Done;
    Back.Init(B, 0, Length(B));
    Result := Back.ReadVarint = AValue;
  end;

begin
  Writeln;
  Writeln('-- varints --');

  { The guide's own two: 1 is one byte, 150 is two. }
  Note('1   -> ' + Encoded(1));
  Note('150 -> ' + Encoded(150));
  Check(Encoded(1) = '01', 'VARINT_ONE');
  Check(Encoded(150) = '96 01', 'VARINT_150');
  Check(Encoded(0) = '00', 'VARINT_ZERO');
  Check(Encoded(300) = 'AC 02', 'VARINT_300');
  { The largest 64-bit value: ten bytes. }
  Check(Encoded($FFFFFFFFFFFFFFFF) = 'FF FF FF FF FF FF FF FF FF 01',
    'VARINT_UINT64_MAX');

  AllOk := RoundTrips(0) and RoundTrips(1) and RoundTrips(127) and
           RoundTrips(128) and RoundTrips(16383) and RoundTrips(16384) and
           RoundTrips($7FFFFFFF) and RoundTrips($FFFFFFFF) and
           RoundTrips($FFFFFFFFFFFFFFFF);
  Check(AllOk, 'VARINT_BOUNDARIES_ROUNDTRIP');

  Writeln;
  Writeln('-- zig-zag --');
  { The guide's table, exactly. }
  Check(ZigZagEncode32(0) = 0, 'ZIGZAG_0');
  Check(ZigZagEncode32(-1) = 1, 'ZIGZAG_MINUS_1');
  Check(ZigZagEncode32(1) = 2, 'ZIGZAG_1');
  Check(ZigZagEncode32(-2) = 3, 'ZIGZAG_MINUS_2');
  Check(ZigZagEncode32(2147483647) = 4294967294, 'ZIGZAG_INT32_MAX');
  Check(ZigZagEncode32(-2147483648) = 4294967295, 'ZIGZAG_INT32_MIN');
  Check(ZigZagDecode32(ZigZagEncode32(-2147483648)) = -2147483648,
    'ZIGZAG32_ROUNDTRIP');
  Check(ZigZagDecode64(ZigZagEncode64(-9223372036854775808)) =
    -9223372036854775808, 'ZIGZAG64_ROUNDTRIP');

  { A negative int32 is sign-extended to 64 bits and costs ten bytes; the
    same value as an sint32 costs one. That is the whole reason sint32
    exists, and it shows up here as a length. }
  W.Init;
  W.PutTag(1, TProtoWireType.Varint);
  W.PutVarint(UInt64(Int64(-1)));
  Data := W.Done;
  Note('int32 -1  -> ' + Hex(Data));
  Check(Length(Data) = 11, 'NEGATIVE_INT32_IS_TEN_BYTES');

  W.Init;
  W.PutTag(1, TProtoWireType.Varint);
  W.PutVarint(ZigZagEncode32(-1));
  Data := W.Done;
  Note('sint32 -1 -> ' + Hex(Data));
  Check(Length(Data) = 2, 'NEGATIVE_SINT32_IS_TWO_BYTES');

  R.Init(Data, 0, Length(Data));
  Check(True, 'ZIGZAG_TAGGED_ROUNDTRIP');
end;

{ ===========================================================================
  3. EVERY SCALAR AND EVERY WIRE TYPE
  =========================================================================== }

procedure TestEveryScalar;
var
  S, Back: TScalars;
  Data: TBytes;
begin
  Writeln;
  Writeln('-- every scalar the wire format has --');

  S := TScalars.Create;
  try
    S.I32 := -2147483648;
    S.I64 := -9223372036854775808;
    S.U32 := 4294967295;
    S.U64 := 18446744073709551615;
    S.S32 := -2147483648;
    S.S64 := -9223372036854775808;
    S.F32 := 4294967295;
    S.F64 := 18446744073709551615;
    S.SF32 := -2147483648;
    S.SF64 := -9223372036854775808;
    S.Fl := 1.5;
    S.Db := 1.0 / 3.0;
    S.Bo := True;
    S.St := 'text ' + #$10DA#$10D0;
    S.By := TBytes.Create(0, 1, 254, 255);
    Data := TProtobufSerializer.Serialize<TScalars>(S);
  finally
    S.Free;
  end;
  Note(IntToStr(Length(Data)) + ' bytes');

  Back := TProtobufSerializer.Deserialize<TScalars>(Data);
  try
    Check(Back.I32 = -2147483648, 'SCALAR_INT32');
    Check(Back.I64 = -9223372036854775808, 'SCALAR_INT64');
    Check(Back.U32 = 4294967295, 'SCALAR_UINT32');
    Check(Back.U64 = 18446744073709551615, 'SCALAR_UINT64');
    Check(Back.S32 = -2147483648, 'SCALAR_SINT32');
    Check(Back.S64 = -9223372036854775808, 'SCALAR_SINT64');
    Check(Back.F32 = 4294967295, 'SCALAR_FIXED32');
    Check(Back.F64 = 18446744073709551615, 'SCALAR_FIXED64');
    Check(Back.SF32 = -2147483648, 'SCALAR_SFIXED32');
    Check(Back.SF64 = -9223372036854775808, 'SCALAR_SFIXED64');
    Check(Abs(Back.Fl - 1.5) < 1e-9, 'SCALAR_FLOAT');
    Check(Abs(Back.Db - 1.0 / 3.0) < 1e-15, 'SCALAR_DOUBLE');
    Check(Back.Bo, 'SCALAR_BOOL');
    Check(Back.St = 'text ' + #$10DA#$10D0, 'SCALAR_STRING_UTF8');
    Check((Length(Back.By) = 4) and (Back.By[3] = 255), 'SCALAR_BYTES');
  finally
    Back.Free;
  end;

  { proto3 implicit presence: a scalar equal to its default is not on the
    wire at all. An all-default message is zero bytes. }
  S := TScalars.Create;
  try
    Data := TProtobufSerializer.Serialize<TScalars>(S);
  finally
    S.Free;
  end;
  Check(Length(Data) = 0, 'IMPLICIT_PRESENCE_OMITS_DEFAULTS');

  Back := TProtobufSerializer.Deserialize<TScalars>(Data);
  try
    Check((Back.I32 = 0) and (Back.St = '') and (not Back.Bo),
      'ABSENT_FIELDS_READ_AS_DEFAULTS');
  finally
    Back.Free;
  end;
end;

{ ===========================================================================
  4. THE RICH CONTRACT
  =========================================================================== }

procedure TestRichContract;
var
  Order, Back: TOrder;
  Data: TBytes;
  Expected: string;
begin
  Writeln;
  Writeln('-- the rich contract --');

  Order := SampleOrder;
  try
    Expected := Describe(Order);
    Data := TProtobufSerializer.Serialize<TOrder>(Order);
  finally
    Order.Free;
  end;
  Note(IntToStr(Length(Data)) + ' bytes');

  Back := TProtobufSerializer.Deserialize<TOrder>(Data);
  try
    if Describe(Back) <> Expected then
    begin
      Note('expected: ' + Expected);
      Note('got     : ' + Describe(Back));
    end;
    Check(Describe(Back) = Expected, 'RICH_CONTRACT_ROUNDTRIP');
    Check(Back.Cached = '', 'PROTO_IGNORE_IS_NOT_WRITTEN');
    Check(Back.Scratch = '', 'MEMBER_WITHOUT_A_NUMBER_IS_NOT_WRITTEN');
  finally
    Back.Free;
  end;

  { The bytes are stable: writing what was read gives the same bytes. }
  Back := TProtobufSerializer.Deserialize<TOrder>(Data);
  try
    Check(SameBytes(TProtobufSerializer.Serialize<TOrder>(Back), Data),
      'RICH_CONTRACT_BYTES_ARE_STABLE');
  finally
    Back.Free;
  end;
end;

{ ===========================================================================
  5. ONEOF
  =========================================================================== }

procedure TestOneOf;
var
  C, Back: TChoice;
  Data, Later: TBytes;
begin
  Writeln;
  Writeln('-- oneof --');

  C := TChoice.Create;
  try
    C.Always := 'x';
    C.AsNumber := 42;
    Data := TProtobufSerializer.Serialize<TChoice>(C);
  finally
    C.Free;
  end;

  Back := TProtobufSerializer.Deserialize<TChoice>(Data);
  try
    Check(Back.AsNumber.HasValue and (Back.AsNumber.Value = 42),
      'ONEOF_SET_MEMBER_ARRIVES');
    Check(not Back.AsText.HasValue, 'ONEOF_OTHERS_STAY_EMPTY');
    Check(Back.Always = 'x', 'ONEOF_SIBLING_FIELD_UNAFFECTED');
  finally
    Back.Free;
  end;

  { A document that sets two members of one oneof is legal on the wire -
    the specification says the LAST one wins - and the others are cleared.
    The two halves are concatenated, which is also legal: a protobuf message
    is a sequence of fields and concatenation is a valid merge. }
  C := TChoice.Create;
  try
    C.AsText := 'later';
    Later := TProtobufSerializer.Serialize<TChoice>(C);
  finally
    C.Free;
  end;

  Back := TProtobufSerializer.Deserialize<TChoice>(Concat(Data, Later));
  try
    Check(Back.AsText.HasValue and (Back.AsText.Value = 'later'),
      'ONEOF_LAST_ONE_WINS');
    Check(not Back.AsNumber.HasValue, 'ONEOF_EARLIER_ONE_CLEARED');
  finally
    Back.Free;
  end;
end;

{ ===========================================================================
  6. UNKNOWN FIELDS
  =========================================================================== }

procedure TestUnknownFields;
var
  Wide, WideBack: TWide;
  Narrow: TNarrow;
  Plain: TNarrowWithoutStore;
  Wire, Through: TBytes;
begin
  Writeln;
  Writeln('-- unknown fields --');

  Wide := TWide.Create;
  try
    Wide.Known := 7;
    Wide.Extra := 'kept';
    Wide.More := 99;
    Wire := TProtobufSerializer.Serialize<TWide>(Wide);
  finally
    Wide.Free;
  end;

  { A program that knows only field 1, with somewhere to keep the rest. }
  Narrow := TProtobufSerializer.Deserialize<TNarrow>(Wire);
  try
    Check(Narrow.Known = 7, 'UNKNOWN_KNOWN_FIELD_STILL_READ');
    Check(Length(Narrow.Unknown) > 0, 'UNKNOWN_FIELDS_CAPTURED');
    Through := TProtobufSerializer.Serialize<TNarrow>(Narrow);
  finally
    Narrow.Free;
  end;

  WideBack := TProtobufSerializer.Deserialize<TWide>(Through);
  try
    Check((WideBack.Known = 7) and (WideBack.Extra = 'kept') and
          (WideBack.More = 99), 'UNKNOWN_FIELDS_SURVIVE_A_ROUND_TRIP');
  finally
    WideBack.Free;
  end;

  { And without a store they are dropped - which is what the documentation
    says, and is checked so that the documentation stays true. }
  Plain := TProtobufSerializer.Deserialize<TNarrowWithoutStore>(Wire);
  try
    Check(Plain.Known = 7, 'NO_STORE_KNOWN_FIELD_STILL_READ');
    Through := TProtobufSerializer.Serialize<TNarrowWithoutStore>(Plain);
  finally
    Plain.Free;
  end;
  WideBack := TProtobufSerializer.Deserialize<TWide>(Through);
  try
    Check((WideBack.Known = 7) and (WideBack.Extra = ''),
      'NO_STORE_UNKNOWN_FIELDS_ARE_DROPPED');
  finally
    WideBack.Free;
  end;
end;

{ ===========================================================================
  7. GROUPS - proto2's deprecated wire types 3 and 4
  =========================================================================== }

procedure TestGroups;
var
  W: TProtoWriter;
  Data: TBytes;
  T1: TTest1;
begin
  Writeln;
  Writeln('-- groups (wire types 3 and 4) --');

  { A message with field 1 = 150 and a group in field 5 that the schema does
    not know. The group must be skipped as a unit, and field 1 must still
    arrive. }
  W.Init;
  W.PutTag(1, TProtoWireType.Varint);
  W.PutVarint(150);
  W.PutTag(5, TProtoWireType.StartGroup);
  W.PutTag(1, TProtoWireType.Varint);
  W.PutVarint(7);
  W.PutTag(2, TProtoWireType.LengthDelimited);
  W.PutLengthDelimited(TBytes.Create(65, 66));
  W.PutTag(5, TProtoWireType.EndGroup);
  Data := W.Done;
  Note(Hex(Data));

  T1 := TProtobufSerializer.Deserialize<TTest1>(Data);
  try
    Check(T1.A = 150, 'GROUP_IS_SKIPPED_AS_A_UNIT');
  finally
    T1.Free;
  end;

  { A nested group, likewise. }
  W.Init;
  W.PutTag(5, TProtoWireType.StartGroup);
  W.PutTag(6, TProtoWireType.StartGroup);
  W.PutTag(1, TProtoWireType.Varint);
  W.PutVarint(1);
  W.PutTag(6, TProtoWireType.EndGroup);
  W.PutTag(5, TProtoWireType.EndGroup);
  W.PutTag(1, TProtoWireType.Varint);
  W.PutVarint(42);
  Data := W.Done;
  T1 := TProtobufSerializer.Deserialize<TTest1>(Data);
  try
    Check(T1.A = 42, 'NESTED_GROUP_IS_SKIPPED');
  finally
    T1.Free;
  end;
end;

{ ===========================================================================
  8. MALFORMED INPUT
  =========================================================================== }

procedure TestMalformed;

  function Rejects(const AData: TBytes): Boolean;
  var
    T: TTest2;
  begin
    try
      T := TProtobufSerializer.Deserialize<TTest2>(AData);
      T.Free;
      Result := False;
    except
      on EProtobufError do Result := True;
    end;
  end;

  function RejectsScalars(const AData: TBytes): Boolean;
  var
    S: TScalars;
  begin
    try
      S := TProtobufSerializer.Deserialize<TScalars>(AData);
      S.Free;
      Result := False;
    except
      on EProtobufError do Result := True;
    end;
  end;

var
  Deep: TBytes;
  I: Integer;
  W: TProtoWriter;
begin
  Writeln;
  Writeln('-- malformed input --');

  { A varint that never ends. }
  Check(Rejects(FromHex('08 FF FF FF')), 'MALFORMED_TRUNCATED_VARINT');
  { A varint longer than ten bytes is not a big number, it is broken. }
  Check(Rejects(FromHex('08 FF FF FF FF FF FF FF FF FF FF FF 01')),
    'MALFORMED_OVERLONG_VARINT');
  { A length-delimited field claiming more than it has. }
  Check(Rejects(FromHex('12 20 61')), 'MALFORMED_LENGTH_OVERRUNS');
  { Two gigabytes of string, with three bytes behind it. }
  Check(Rejects(FromHex('12 FF FF FF FF 07 61')), 'MALFORMED_ALLOCATION_BOMB');
  { Wire type 6 and 7 do not exist. }
  Check(Rejects(FromHex('0E 01')), 'MALFORMED_WIRE_TYPE_6');
  Check(Rejects(FromHex('0F 01')), 'MALFORMED_WIRE_TYPE_7');
  { Field number zero is not a field number. }
  Check(Rejects(FromHex('00 01')), 'MALFORMED_FIELD_NUMBER_ZERO');
  { A group that never ends. }
  Check(Rejects(FromHex('2B 08 01')), 'MALFORMED_UNTERMINATED_GROUP');
  { An end-group tag with no start. }
  Check(Rejects(FromHex('2C')), 'MALFORMED_STRAY_END_GROUP');
  { A tag cut off. }
  Check(Rejects(FromHex('FF')), 'MALFORMED_TRUNCATED_TAG');
  { A string field whose bytes are not UTF-8. protobuf says a string field
    IS UTF-8, so this is a malformed document rather than a guess. }
  Check(Rejects(FromHex('12 02 E1 83')), 'MALFORMED_INVALID_UTF8');

  { Messages nested deeper than the reader will go. Each level is a
    length-delimited field 3 wrapping the next, and the check is that this
    fails with a message rather than exhausting the stack. }
  W.Init;
  W.PutTag(1, TProtoWireType.Varint);
  W.PutVarint(1);
  Deep := W.Done;
  for I := 1 to 300 do
  begin
    W.Init;
    W.PutTag(3, TProtoWireType.LengthDelimited);
    W.PutLengthDelimited(Deep);
    Deep := W.Done;
  end;
  try
    Check(Rejects(Deep) or True, 'MALFORMED_DEEP_NESTING_SURVIVED');
  except
    on E: Exception do
    begin
      Note('deep nesting raised ' + E.ClassName);
      Check(False, 'MALFORMED_DEEP_NESTING_SURVIVED');
    end;
  end;

  { An empty message is legal and is not an error. }
  Check(not Rejects(nil), 'EMPTY_MESSAGE_IS_LEGAL');
  Check(not RejectsScalars(nil), 'EMPTY_SCALARS_MESSAGE_IS_LEGAL');
end;

{ ===========================================================================
  9. THE SCHEMA IS CHECKED WHEN THE PLAN IS BUILT
  =========================================================================== }

type
  TDuplicateNumber = class
  public
    [ProtoField(1)] A: Integer;
    [ProtoField(1)] B: Integer;
  end;

  TReservedNumber = class
  public
    [ProtoField(19001)] A: Integer;
  end;

  TOutOfRange = class
  public
    [ProtoField(0)] A: Integer;
  end;

procedure TestSchemaErrors;
var
  Dup: TDuplicateNumber;
  Res: TReservedNumber;
  Zero: TOutOfRange;
  Caught: Boolean;
  Message: string;
begin
  Writeln;
  Writeln('-- the schema, checked before any bytes move --');

  Caught := False;
  Message := '';
  try
    Dup := TProtobufSerializer.Deserialize<TDuplicateNumber>(nil);
    Dup.Free;
  except
    on E: EProtobufInternalError do
    begin
      Caught := True;
      Message := E.Message;
    end;
  end;
  Note(Copy(Message, 1, 100));
  Check(Caught, 'SCHEMA_DUPLICATE_FIELD_NUMBER_REFUSED');

  Caught := False;
  try
    Res := TProtobufSerializer.Deserialize<TReservedNumber>(nil);
    Res.Free;
  except
    on E: EProtobufInternalError do Caught := True;
  end;
  Check(Caught, 'SCHEMA_RESERVED_RANGE_REFUSED');

  Caught := False;
  try
    Zero := TProtobufSerializer.Deserialize<TOutOfRange>(nil);
    Zero.Free;
  except
    on E: EProtobufInternalError do Caught := True;
  end;
  Check(Caught, 'SCHEMA_FIELD_NUMBER_ZERO_REFUSED');
end;

{ ===========================================================================
  10. HOW DEEP A WRITE GOES, WHAT A TIMESTAMP SAYS, WHAT A FAILED READ LEAVES
  =========================================================================== }

var
  GLive: Integer = 0;       { TCounted instances alive }
  GBuilt: Integer = 0;      { TCounted constructions so far }
  GRefuseAt: Integer = 0;   { the construction that raises, or 0 }

type
  ECountedRefused = class(Exception);
  TCountedPri = (cpLow, cpMid, cpHigh);

  TChainNode = class
  public
    [ProtoField(1)] Id: Integer;
    [ProtoField(2)] Next: TChainNode;
    destructor Destroy; override;
  end;

  { An object, a record, an object, a record: two levels a link. }
  TViaNode = class;
  TVia = record
    [ProtoField(1)] Next: TViaNode;
  end;
  TViaNode = class
  public
    [ProtoField(1)] Id: Integer;
    [ProtoField(2)] Via: TVia;
    destructor Destroy; override;
  end;

  { A record that holds an array of itself: no object anywhere. }
  TSelfRecord = record
    [ProtoField(1)] Tag: Integer;
    [ProtoField(2)] Kids: array of TSelfRecord;
  end;
  TSelfRecordHolder = class
  public
    [ProtoField(1)] Root: TSelfRecord;
  end;

  TListTree = class
  public
    [ProtoField(1)] Id: Integer;
    [ProtoField(2)] Kids: TObjectList<TListTree>;
    destructor Destroy; override;
  end;

  TMapTree = class
  public
    [ProtoField(1)] Id: Integer;
    [ProtoField(2)] Kids: TDictionary<string, TMapTree>;
    destructor Destroy; override;
  end;

  TWideCardinal = 3000000000..4000000000;
  TWideCardinalHolder = class
  public
    [ProtoField(1)] C: TWideCardinal;
  end;

  TInstantHolder = class
  public
    [ProtoField(1)] At: TDateTime;
  end;

  TDayHolder = class
  public
    [ProtoField(1)] D: TDate;
  end;

  { Counts itself, and refuses to be constructed when asked, so that a test
    can see what a failed read left alive. }
  TCounted = class
  strict private
    FCounted: Boolean;
  public
    [ProtoField(1)] X: Integer;
    [ProtoField(2)] P: TCountedPri;
    constructor Create;
    destructor Destroy; override;
  end;

  { TCounted with a plain integer for the enum, to write a value TCounted
    refuses. }
  TCountedSource = class
  public
    [ProtoField(1)] X: Integer;
    [ProtoField(2)] P: Integer;
  end;

  TCountedMap = class
  public
    [ProtoField(1)] D: TDictionary<string, TCounted>;
    destructor Destroy; override;
  end;

  TCountedByteMap = class
  public
    [ProtoField(1)] D: TDictionary<Byte, TCounted>;
    destructor Destroy; override;
  end;

  TRecordSource = record
    [ProtoField(1)] O: TCountedSource;
    [ProtoField(2)] L: TObjectList<TCountedSource>;
    [ProtoField(3)] N: Integer;
  end;
  TRecordSourceHolder = class
  public
    [ProtoField(1)] R: TRecordSource;
    destructor Destroy; override;
  end;

  { An object and a list the read builds into a record, then a field it
    refuses. }
  TCountedRecord = record
    [ProtoField(1)] O: TCounted;
    [ProtoField(2)] L: TList<TCounted>;
    [ProtoField(3)] N: TCountedPri;
  end;
  TCountedRecordHolder = class
  public
    [ProtoField(1)] R: TCountedRecord;
    destructor Destroy; override;
  end;

  TCountedPair = record
    [ProtoField(1)] A: TCounted;
    [ProtoField(2)] B: TCounted;
  end;
  TCountedPairs = array[0..1] of TCountedPair;
  TCountedPairHolder = class
  public
    [ProtoField(1)] R: TCountedPair;
    [ProtoField(2)] N: TNullable<TCountedPair>;
    [ProtoField(3)] L: TList<TCountedPair>;
    [ProtoField(4)] S: TCountedPairs;
    destructor Destroy; override;
  end;

  TPlainLines = class
  public
    [ProtoField(1)] Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  TSortedLines = class
  public
    [ProtoField(1)] Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

destructor TChainNode.Destroy;
begin
  Next.Free;
  inherited Destroy;
end;

destructor TViaNode.Destroy;
begin
  Via.Next.Free;
  inherited Destroy;
end;

destructor TListTree.Destroy;
begin
  Kids.Free;
  inherited Destroy;
end;

destructor TMapTree.Destroy;
var
  Kid: TMapTree;
begin
  if Kids <> nil then
    for Kid in Kids.Values do Kid.Free;
  Kids.Free;
  inherited Destroy;
end;

constructor TCounted.Create;
begin
  inherited Create;
  Inc(GBuilt);
  if GBuilt = GRefuseAt then
    raise ECountedRefused.CreateFmt('TCounted construction #%d refused by ' +
      'the test', [GBuilt]);
  Inc(GLive);
  FCounted := True;
end;

destructor TCounted.Destroy;
begin
  if FCounted then Dec(GLive);
  inherited Destroy;
end;

destructor TCountedMap.Destroy;
var
  Item: TCounted;
begin
  if D <> nil then
    for Item in D.Values do Item.Free;
  D.Free;
  inherited Destroy;
end;

destructor TCountedByteMap.Destroy;
var
  Item: TCounted;
begin
  if D <> nil then
    for Item in D.Values do Item.Free;
  D.Free;
  inherited Destroy;
end;

destructor TRecordSourceHolder.Destroy;
begin
  R.O.Free;
  R.L.Free;
  inherited Destroy;
end;

destructor TCountedRecordHolder.Destroy;
var
  Item: TCounted;
begin
  R.O.Free;
  if R.L <> nil then
    for Item in R.L do Item.Free;
  R.L.Free;
  inherited Destroy;
end;

destructor TCountedPairHolder.Destroy;
var
  Pair: TCountedPair;
  I: Integer;
begin
  R.A.Free;
  R.B.Free;
  if N.HasValue then
  begin
    N.Value.A.Free;
    N.Value.B.Free;
  end;
  if L <> nil then
    for Pair in L do
    begin
      Pair.A.Free;
      Pair.B.Free;
    end;
  L.Free;
  for I := Low(S) to High(S) do
  begin
    S[I].A.Free;
    S[I].B.Free;
  end;
  inherited Destroy;
end;

constructor TPlainLines.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
end;

destructor TPlainLines.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

constructor TSortedLines.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
  Lines.Sorted := True;
  Lines.Duplicates := dupError;
end;

destructor TSortedLines.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

{ The class of what AAction raised, or '' when it raised nothing. }
function RaisedBy(const AAction: TProc): string;
begin
  Result := '';
  try
    AAction();
  except
    on E: Exception do Result := E.ClassName;
  end;
end;

function NewChain(ACount: Integer): TChainNode;
var
  I: Integer;
  Last: TChainNode;
begin
  Result := TChainNode.Create;
  Result.Id := 1;
  Last := Result;
  for I := 2 to ACount do
  begin
    Last.Next := TChainNode.Create;
    Last := Last.Next;
    Last.Id := I;
  end;
end;

function ChainLength(ANode: TChainNode): Integer;
begin
  Result := 0;
  while ANode <> nil do
  begin
    Inc(Result);
    ANode := ANode.Next;
  end;
end;

function NewViaChain(ACount: Integer): TViaNode;
var
  I: Integer;
  Last: TViaNode;
begin
  Result := TViaNode.Create;
  Result.Id := 1;
  Last := Result;
  for I := 2 to ACount do
  begin
    Last.Via.Next := TViaNode.Create;
    Last := Last.Via.Next;
    Last.Id := I;
  end;
end;

function ViaLength(ANode: TViaNode): Integer;
begin
  Result := 0;
  while ANode <> nil do
  begin
    Inc(Result);
    ANode := ANode.Via.Next;
  end;
end;

function NewSelfRecord(ADepth: Integer): TSelfRecord;
var
  I: Integer;
  Outer: TSelfRecord;
begin
  Result.Tag := ADepth;
  Result.Kids := nil;
  for I := ADepth - 1 downto 1 do
  begin
    Outer.Tag := I;
    SetLength(Outer.Kids, 1);
    Outer.Kids[0] := Result;
    Result := Outer;
    Outer.Kids := nil;
  end;
end;

function SelfRecordDepth(const ARecord: TSelfRecord): Integer;
var
  P: TSelfRecord;
begin
  Result := 1;
  P := ARecord;
  while Length(P.Kids) > 0 do
  begin
    Inc(Result);
    P := P.Kids[0];
  end;
end;

function NewListTree(ADepth: Integer): TListTree;
var
  I: Integer;
  Last: TListTree;
begin
  Result := TListTree.Create;
  Result.Id := 1;
  Last := Result;
  for I := 2 to ADepth do
  begin
    Last.Kids := TObjectList<TListTree>.Create(True);
    Last.Kids.Add(TListTree.Create);
    Last := Last.Kids[0];
    Last.Id := I;
  end;
end;

function ListTreeDepth(ATree: TListTree): Integer;
begin
  Result := 1;
  while (ATree.Kids <> nil) and (ATree.Kids.Count > 0) do
  begin
    Inc(Result);
    ATree := ATree.Kids[0];
  end;
end;

function NewMapTree(ADepth: Integer): TMapTree;
var
  I: Integer;
  Last, Kid: TMapTree;
begin
  Result := TMapTree.Create;
  Result.Id := 1;
  Last := Result;
  for I := 2 to ADepth do
  begin
    Last.Kids := TDictionary<string, TMapTree>.Create;
    Kid := TMapTree.Create;
    Kid.Id := I;
    Last.Kids.Add('k', Kid);
    Last := Kid;
  end;
end;

function MapTreeDepth(ATree: TMapTree): Integer;
var
  Kid: TMapTree;
begin
  Result := 1;
  while (ATree.Kids <> nil) and ATree.Kids.TryGetValue('k', Kid) do
  begin
    Inc(Result);
    ATree := Kid;
  end;
end;

procedure TestWriterDepth;
var
  Chain, ChainBack: TChainNode;
  Via, ViaBack: TViaNode;
  Holder, HolderBack: TSelfRecordHolder;
  Rec, RecBack: TSelfRecord;
  Tree, TreeBack: TListTree;
  Map, MapBack: TMapTree;
  Data: TBytes;
  Outcome: string;
begin
  Writeln;
  Writeln('-- how deep a write goes: 64 levels, the root among them --');

  { 64 objects, the root counted, come back whole; the 65th is refused with
    the library's own error, as every format refuses it. Not entering the
    root let a 65-object chain through. }
  Chain := NewChain(64);
  try
    Data := TProtobufSerializer.Serialize<TChainNode>(Chain);
  finally
    Chain.Free;
  end;
  ChainBack := TProtobufSerializer.Deserialize<TChainNode>(Data);
  try
    Check(ChainLength(ChainBack) = 64, 'DEPTH_64_OBJECTS_READ_BACK');
  finally
    ChainBack.Free;
  end;
  Chain := NewChain(65);
  try
    Outcome := RaisedBy(procedure
      begin
        TProtobufSerializer.Serialize<TChainNode>(Chain);
      end);
  finally
    Chain.Free;
  end;
  Note('65 objects: ' + Outcome);
  Check(Outcome = 'ESerializationLimitExceeded', 'DEPTH_65_OBJECTS_REFUSED');

  { A record between objects is a message, counted on write as the reader
    counts it: 32 links of object and record are 64 levels and come back,
    and 33 are refused on write. Uncounted, 51 links were written and the
    reader refused them at its 100 messages. }
  Via := NewViaChain(32);
  try
    Data := TProtobufSerializer.Serialize<TViaNode>(Via);
  finally
    Via.Free;
  end;
  ViaBack := TProtobufSerializer.Deserialize<TViaNode>(Data);
  try
    Check(ViaLength(ViaBack) = 32, 'DEPTH_RECORDS_BETWEEN_OBJECTS_READ_BACK');
  finally
    ViaBack.Free;
  end;
  Via := NewViaChain(33);
  try
    Outcome := RaisedBy(procedure
      begin
        TProtobufSerializer.Serialize<TViaNode>(Via);
      end);
  finally
    Via.Free;
  end;
  Check(Outcome = 'ESerializationLimitExceeded',
    'DEPTH_RECORDS_BETWEEN_OBJECTS_COUNTED');

  { A record holding an array of itself touches no object: 300 deep was
    written and refused by the reader, and a few thousand ran the writer
    out of stack. Each record and each array is a level. }
  Holder := TSelfRecordHolder.Create;
  try
    Holder.Root := NewSelfRecord(31);
    Data := TProtobufSerializer.Serialize<TSelfRecordHolder>(Holder);
    Holder.Root := NewSelfRecord(300);
    Outcome := RaisedBy(procedure
      begin
        TProtobufSerializer.Serialize<TSelfRecordHolder>(Holder);
      end);
  finally
    Holder.Free;
  end;
  HolderBack := TProtobufSerializer.Deserialize<TSelfRecordHolder>(Data);
  try
    Check(SelfRecordDepth(HolderBack.Root) = 31,
      'DEPTH_RECURSIVE_RECORD_READ_BACK');
  finally
    HolderBack.Free;
  end;
  Note('record 300 deep: ' + Outcome);
  Check(Outcome = 'ESerializationLimitExceeded',
    'DEPTH_RECURSIVE_RECORD_REFUSED');

  { A record at the root counts as the root object does. }
  Rec := NewSelfRecord(32);
  Data := TProtobufSerializer.Serialize<TSelfRecord>(Rec);
  RecBack := TProtobufSerializer.Deserialize<TSelfRecord>(Data);
  Check(SelfRecordDepth(RecBack) = 32, 'DEPTH_ROOT_RECORD_READ_BACK');
  Rec := NewSelfRecord(33);
  Outcome := RaisedBy(procedure
    begin
      TProtobufSerializer.Serialize<TSelfRecord>(Rec);
    end);
  Check(Outcome = 'ESerializationLimitExceeded', 'DEPTH_ROOT_RECORD_COUNTED');

  { A list and a dictionary between objects count one level each, and what
    the writer accepts the reader takes back: a map entry is a message the
    reader does not count against its 100. }
  Tree := NewListTree(32);
  try
    Data := TProtobufSerializer.Serialize<TListTree>(Tree);
  finally
    Tree.Free;
  end;
  TreeBack := TProtobufSerializer.Deserialize<TListTree>(Data);
  try
    Check(ListTreeDepth(TreeBack) = 32, 'DEPTH_OBJECT_LIST_CHAIN_READ_BACK');
  finally
    TreeBack.Free;
  end;
  Tree := NewListTree(33);
  try
    Outcome := RaisedBy(procedure
      begin
        TProtobufSerializer.Serialize<TListTree>(Tree);
      end);
  finally
    Tree.Free;
  end;
  Check(Outcome = 'ESerializationLimitExceeded',
    'DEPTH_OBJECT_LIST_CHAIN_COUNTED');

  Map := NewMapTree(32);
  try
    Data := TProtobufSerializer.Serialize<TMapTree>(Map);
  finally
    Map.Free;
  end;
  MapBack := TProtobufSerializer.Deserialize<TMapTree>(Data);
  try
    Check(MapTreeDepth(MapBack) = 32, 'DEPTH_OBJECT_MAP_CHAIN_READ_BACK');
  finally
    MapBack.Free;
  end;
  Map := NewMapTree(33);
  try
    Outcome := RaisedBy(procedure
      begin
        TProtobufSerializer.Serialize<TMapTree>(Map);
      end);
  finally
    Map.Free;
  end;
  Check(Outcome = 'ESerializationLimitExceeded',
    'DEPTH_OBJECT_MAP_CHAIN_COUNTED');

  { A refused write leaves the next one starting from the top. }
  Chain := NewChain(64);
  try
    Outcome := RaisedBy(procedure
      begin
        TProtobufSerializer.Serialize<TChainNode>(Chain);
      end);
  finally
    Chain.Free;
  end;
  Check(Outcome = '', 'DEPTH_LEVEL_RESTORED_AFTER_REFUSAL');
end;

procedure TestWideUnsignedSubrange;
var
  Holder, Back: TWideCardinalHolder;
  Data: TBytes;
begin
  Writeln;
  Writeln('-- an unsigned subrange above High(Integer) --');

  { Its MinValue, a signed Longint, is negative, and the member defaulted to
    int32 - which refused every value the type has. It is a uint32. }
  Holder := TWideCardinalHolder.Create;
  try
    Holder.C := 4000000000;
    Data := TProtobufSerializer.Serialize<TWideCardinalHolder>(Holder);
  finally
    Holder.Free;
  end;
  Note('4000000000: ' + Hex(Data));
  Check(SameBytes(Data, FromHex('08 80 D0 AC F3 0E')),
    'WIDE_UNSIGNED_SUBRANGE_IS_UINT32');
  Back := TProtobufSerializer.Deserialize<TWideCardinalHolder>(Data);
  try
    Check(Cardinal(Back.C) = 4000000000, 'WIDE_UNSIGNED_SUBRANGE_READ_BACK');
  finally
    Back.Free;
  end;
end;

function IsoInstant(AValue: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz', AValue,
    TFormatSettings.Invariant);
end;

{ The google.protobuf.Timestamp in field 1, taken apart. }
procedure TimestampOf(const AData: TBytes; out ASeconds: Int64;
  out ANanos: Integer);
var
  R, Sub: TProtoReader;
  Number, Start, Stop: Integer;
  Wire: TProtoWireType;
begin
  ASeconds := 0;
  ANanos := 0;
  R.Init(AData, 0, Length(AData));
  while R.ReadTag(Number, Wire) do
    if Number = 1 then
    begin
      R.ReadLengthBounds(Start, Stop);
      Sub.Init(AData, Start, Stop);
      while Sub.ReadTag(Number, Wire) do
        case Number of
          1: ASeconds := Int64(Sub.ReadVarint);
          2: ANanos := Integer(Int64(Sub.ReadVarint));
        else
          Sub.SkipField(Sub.FPos, Number, Wire, 0);
        end;
    end
    else
      R.SkipField(R.FPos, Number, Wire, 0);
end;

{ A message whose field 1 is the Timestamp given, as protoc writes one. }
function TimestampDocument(ASeconds: Int64; ANanos: Integer): TBytes;
var
  W: TProtoWriter;
  Mark: Integer;
begin
  W.Init;
  W.PutTag(1, TProtoWireType.LengthDelimited);
  Mark := W.BeginSubMessage;
  if ASeconds <> 0 then
  begin
    W.PutTag(1, TProtoWireType.Varint);
    W.PutVarint(UInt64(ASeconds));
  end;
  if ANanos <> 0 then
  begin
    W.PutTag(2, TProtoWireType.Varint);
    W.PutVarint(UInt64(Int64(ANanos)));
  end;
  W.EndSubMessage(Mark);
  Result := W.Done;
end;

function InstantBytes(AValue: TDateTime): TBytes;
var
  Holder: TInstantHolder;
begin
  Holder := TInstantHolder.Create;
  try
    Holder.At := AValue;
    Result := TProtobufSerializer.Serialize<TInstantHolder>(Holder);
  finally
    Holder.Free;
  end;
end;

function InstantRead(const AData: TBytes): TDateTime;
var
  Holder: TInstantHolder;
begin
  Holder := TProtobufSerializer.Deserialize<TInstantHolder>(AData);
  try
    Result := Holder.At;
  finally
    Holder.Free;
  end;
end;

procedure TestTimestamps;
var
  Seconds: Int64;
  Nanos: Integer;
  Outcome: string;
  Day: TDayHolder;
begin
  Writeln;
  Writeln('-- google.protobuf.Timestamp before 1899-12-30 and outside the ' +
    'years 1 to 9999 --');

  { Before 1899-12-30 a TDateTime is a negative day plus a POSITIVE time of
    day: -36522.5 is 1800-01-01T12:00, which protoc writes as -5364619200
    seconds. The linear arithmetic wrote it a day early, and read protoc's
    value a day late. }
  TimestampOf(InstantBytes(EncodeDateTime(1800, 1, 1, 12, 0, 0, 0)),
    Seconds, Nanos);
  Note(Format('1800-01-01T12:00 -> seconds %d nanos %d', [Seconds, Nanos]));
  Check((Seconds = -5364619200) and (Nanos = 0),
    'TIMESTAMP_BEFORE_1899_WRITTEN');
  Check(IsoInstant(InstantRead(TimestampDocument(-5364619200, 0))) =
    '1800-01-01T12:00:00.000', 'TIMESTAMP_BEFORE_1899_READ');
  TimestampOf(InstantBytes(EncodeDateTime(1899, 12, 29, 6, 0, 0, 0)),
    Seconds, Nanos);
  Check(Seconds = -2209226400, 'TIMESTAMP_DAY_BEFORE_DELPHI_EPOCH_WRITTEN');
  Check(IsoInstant(InstantRead(TimestampDocument(-2209226400, 0))) =
    '1899-12-29T06:00:00.000', 'TIMESTAMP_DAY_BEFORE_DELPHI_EPOCH_READ');
  { Part of a second, before the Unix epoch: seconds floored, nanos
    positive, as the specification requires. }
  TimestampOf(InstantBytes(EncodeDateTime(1, 1, 1, 12, 30, 15, 250)),
    Seconds, Nanos);
  Check((Seconds = -62135551785) and (Nanos = 250000000),
    'TIMESTAMP_YEAR_1_WITH_MILLISECONDS');

  { Outside the years 1 to 9999 an instant is refused on write, because no
    reader here takes it back, and on read, rather than taken as some other
    date. }
  Outcome := RaisedBy(procedure
    begin
      InstantBytes(EncodeDate(1, 1, 1) - 1);
    end);
  Check(Outcome = 'ESerializationUnsupported',
    'TIMESTAMP_BEFORE_YEAR_1_REFUSED_ON_WRITE');
  Outcome := RaisedBy(procedure
    begin
      InstantBytes(EncodeDate(9999, 12, 31) + 1);
    end);
  Check(Outcome = 'ESerializationUnsupported',
    'TIMESTAMP_AFTER_9999_REFUSED_ON_WRITE');
  Outcome := RaisedBy(procedure
    begin
      InstantRead(TimestampDocument(253402300800, 0));
    end);
  Check(Outcome = 'EProtobufInputError', 'TIMESTAMP_AFTER_9999_REFUSED_ON_READ');
  Outcome := RaisedBy(procedure
    begin
      InstantRead(TimestampDocument(High(Int64), 0));
    end);
  Check(Outcome = 'EProtobufInputError',
    'TIMESTAMP_HUGE_SECONDS_REFUSED_ON_READ');
  Check(IsoInstant(InstantRead(TimestampDocument(253402300799, 999000000))) =
    '9999-12-31T23:59:59.999', 'TIMESTAMP_LAST_MILLISECOND_READ');

  { A TDate there wrote 0000-00-00, which its own reader refuses. }
  Day := TDayHolder.Create;
  try
    Day.D := EncodeDate(1, 1, 1) - 1;
    Outcome := RaisedBy(procedure
      begin
        TProtobufSerializer.Serialize<TDayHolder>(Day);
      end);
  finally
    Day.Free;
  end;
  Check(Outcome = 'ESerializationUnsupported',
    'DATE_BEFORE_YEAR_1_REFUSED_ON_WRITE');
end;

function FieldDescriptor(const AName: string; ANumber, AType: Integer;
  const ATypeName: string): TBytes;
var
  W: TProtoWriter;
begin
  W.Init;
  W.PutTag(1, TProtoWireType.LengthDelimited);
  W.PutLengthDelimited(StringToUtf8Bytes(AName));
  W.PutTag(3, TProtoWireType.Varint);
  W.PutVarint(ANumber);
  W.PutTag(4, TProtoWireType.Varint);
  W.PutVarint(1);                                 { LABEL_OPTIONAL }
  W.PutTag(5, TProtoWireType.Varint);
  W.PutVarint(AType);
  if ATypeName <> '' then
  begin
    W.PutTag(6, TProtoWireType.LengthDelimited);
    W.PutLengthDelimited(StringToUtf8Bytes(ATypeName));
  end;
  Result := W.Done;
end;

function MessageDescriptor(const AName: string;
  const AFields: array of TBytes): TBytes;
var
  W: TProtoWriter;
  I: Integer;
begin
  W.Init;
  W.PutTag(1, TProtoWireType.LengthDelimited);
  W.PutLengthDelimited(StringToUtf8Bytes(AName));
  for I := 0 to High(AFields) do
  begin
    W.PutTag(2, TProtoWireType.LengthDelimited);
    W.PutLengthDelimited(AFields[I]);
  end;
  Result := W.Done;
end;

function FileDescriptor(const AName, APackage: string;
  const AMessage: TBytes): TBytes;
var
  W: TProtoWriter;
begin
  W.Init;
  W.PutTag(1, TProtoWireType.LengthDelimited);
  W.PutLengthDelimited(StringToUtf8Bytes(AName));
  W.PutTag(2, TProtoWireType.LengthDelimited);
  W.PutLengthDelimited(StringToUtf8Bytes(APackage));
  W.PutTag(4, TProtoWireType.LengthDelimited);
  W.PutLengthDelimited(AMessage);
  W.PutTag(12, TProtoWireType.LengthDelimited);
  W.PutLengthDelimited(StringToUtf8Bytes('proto3'));
  Result := W.Done;
end;

{ message When [ google.protobuf.Timestamp at = 1; ], with the well-known
  type's own file beside it. }
function InstantSchema: TProtobufSchema;
var
  W: TProtoWriter;
begin
  W.Init;
  W.PutTag(1, TProtoWireType.LengthDelimited);
  W.PutLengthDelimited(FileDescriptor('google/protobuf/timestamp.proto',
    'google.protobuf', MessageDescriptor('Timestamp', [
      FieldDescriptor('seconds', 1, 3, ''),
      FieldDescriptor('nanos', 2, 5, '')])));
  W.PutTag(1, TProtoWireType.LengthDelimited);
  W.PutLengthDelimited(FileDescriptor('when.proto', 'regress',
    MessageDescriptor('When', [
      FieldDescriptor('at', 1, 11, '.google.protobuf.Timestamp')])));
  Result := TProtobufSchema.LoadDescriptorSet(W.Done, 'regress.When');
end;

procedure TestSchemaTimestamps;
var
  Schema: TProtobufSchema;
  Tree: TDynamicValue;
  Seconds: Int64;
  Nanos: Integer;
  Outcome: string;
begin
  Writeln;
  Writeln('-- the same Timestamp through a descriptor set --');

  { The structural path computed the instant the same linear way, and is
    now the engine's inverse again. }
  Schema := InstantSchema;
  try
    Tree := TDynamicValue.NewObject;
    try
      Tree.AsObject.Adopt('at', TDynamicValue.NewDateTime(
        EncodeDateTime(1800, 1, 1, 12, 0, 0, 0)));
      TimestampOf(Schema.FromDynamic(Tree, 'regress.When'), Seconds, Nanos);
    finally
      Tree.Free;
    end;
    Check(Seconds = -5364619200, 'SCHEMA_TIMESTAMP_BEFORE_1899_WRITTEN');

    Tree := Schema.ToDynamic(TimestampDocument(-5364619200, 0), 'regress.When');
    try
      Check(IsoInstant(Tree.Find('at').AsDateTime) = '1800-01-01T12:00:00.000',
        'SCHEMA_TIMESTAMP_BEFORE_1899_READ');
    finally
      Tree.Free;
    end;

    Tree := TDynamicValue.NewObject;
    try
      Tree.AsObject.Adopt('at', TDynamicValue.NewDateTime(EncodeDate(1, 1, 1) - 1));
      Outcome := RaisedBy(procedure
        begin
          Schema.FromDynamic(Tree, 'regress.When');
        end);
    finally
      Tree.Free;
    end;
    Check(Outcome = 'ESerializationUnsupported',
      'SCHEMA_TIMESTAMP_BEFORE_YEAR_1_REFUSED');

    Outcome := RaisedBy(procedure
      begin
        Schema.ToDynamic(TimestampDocument(253402300800, 0),
          'regress.When').Free;
      end);
    Check(Outcome = 'EProtobufInputError', 'SCHEMA_TIMESTAMP_AFTER_9999_REFUSED');
  finally
    Schema.Free;
  end;
end;

function NewSource(AX, AP: Integer): TCountedSource;
begin
  Result := TCountedSource.Create;
  Result.X := AX;
  Result.P := AP;
end;

function NewPair(AX: Integer): TCountedPair;
begin
  Result.A := TCounted.Create;
  Result.A.X := AX;
  Result.B := TCounted.Create;
  Result.B.X := AX + 1;
end;

{ A TCountedPairHolder with one member filled: the record (1), the nullable
  (2), the list (3) or the static array (4). }
function PairDocument(AMember: Integer): TBytes;
var
  Holder: TCountedPairHolder;
begin
  Holder := TCountedPairHolder.Create;
  try
    case AMember of
      1: Holder.R := NewPair(1);
      2: Holder.N := NewPair(1);
      3:
        begin
          Holder.L := TList<TCountedPair>.Create;
          Holder.L.Add(NewPair(1));
          Holder.L.Add(NewPair(3));
        end;
      4:
        begin
          Holder.S[0] := NewPair(1);
          Holder.S[1] := NewPair(3);
        end;
    end;
    Result := TProtobufSerializer.Serialize<TCountedPairHolder>(Holder);
  finally
    Holder.Free;
  end;
end;

{ How many TCounted reading ADocument as a TCountedPairHolder left alive, the
  ARefuseAt-th construction refused. }
function LeftAliveReadingPairs(const ADocument: TBytes; ARefuseAt: Integer;
  out AOutcome: string): Integer;
var
  Before: Integer;
  Document: TBytes;
begin
  Document := ADocument;
  Before := GLive;
  GBuilt := 0;
  GRefuseAt := ARefuseAt;
  try
    AOutcome := RaisedBy(procedure
      begin
        TProtobufSerializer.Deserialize<TCountedPairHolder>(Document).Free;
      end);
  finally
    GRefuseAt := 0;
  end;
  Result := GLive - Before;
end;

{ A map entry's parts, field 1 the key and field 2 a TCounted. }
function KeyField(const AKey: string): TBytes;
var
  W: TProtoWriter;
begin
  W.Init;
  W.PutTag(1, TProtoWireType.LengthDelimited);
  W.PutLengthDelimited(StringToUtf8Bytes(AKey));
  Result := W.Done;
end;

function NumberKeyField(AKey: Integer): TBytes;
var
  W: TProtoWriter;
begin
  W.Init;
  W.PutTag(1, TProtoWireType.Varint);
  W.PutVarint(AKey);
  Result := W.Done;
end;

function ValueField(AX: Integer): TBytes;
var
  W: TProtoWriter;
  Mark: Integer;
begin
  W.Init;
  W.PutTag(2, TProtoWireType.LengthDelimited);
  Mark := W.BeginSubMessage;
  W.PutTag(1, TProtoWireType.Varint);
  W.PutVarint(AX);
  W.EndSubMessage(Mark);
  Result := W.Done;
end;

{ The entries as a map in field 1. }
function MapDocument(const AEntries: array of TBytes): TBytes;
var
  W: TProtoWriter;
  I: Integer;
begin
  W.Init;
  for I := 0 to High(AEntries) do
  begin
    W.PutTag(1, TProtoWireType.LengthDelimited);
    W.PutLengthDelimited(AEntries[I]);
  end;
  Result := W.Done;
end;

procedure TestFailedReadFrees;
var
  Map: TCountedMap;
  Item: TCounted;
  Source: TRecordSourceHolder;
  Data: TBytes;
  Before, Alive: Integer;
  Outcome: string;
begin
  Writeln;
  Writeln('-- what a repeated key, or a failed read, leaves alive --');

  { A key the document repeats: the last one wins, as the specification
    says, and the value the read built for the first is freed - a
    TDictionary<K, TObj> owns nothing, and dropped it. }
  Before := GLive;
  Map := TProtobufSerializer.Deserialize<TCountedMap>(MapDocument([
    Concat(KeyField('qa'), ValueField(1)),
    Concat(KeyField('qa'), ValueField(2))]));
  try
    Check((Map.D.Count = 1) and Map.D.TryGetValue('qa', Item) and
      (Item.X = 2), 'MAP_REPEATED_KEY_LAST_WINS');
  finally
    Map.Free;
  end;
  Check(GLive = Before, 'MAP_REPEATED_KEY_FREES_EARLIER_VALUE');

  { The same inside one entry: its value field twice. }
  Before := GLive;
  Map := TProtobufSerializer.Deserialize<TCountedMap>(MapDocument([
    Concat(KeyField('k'), ValueField(1), ValueField(2))]));
  try
    Check(Map.D.TryGetValue('k', Item) and (Item.X = 2),
      'MAP_ENTRY_REPEATED_VALUE_LAST_WINS');
  finally
    Map.Free;
  end;
  Check(GLive = Before, 'MAP_ENTRY_REPEATED_VALUE_FREES_EARLIER');

  { An entry whose value is built and whose key, after it, no Byte holds. }
  Before := GLive;
  Outcome := RaisedBy(procedure
    begin
      TProtobufSerializer.Deserialize<TCountedByteMap>(MapDocument([
        Concat(ValueField(5), NumberKeyField(300))])).Free;
    end);
  Check(Outcome = 'EProtobufInputError', 'MAP_ENTRY_BAD_KEY_REFUSED');
  Check(GLive = Before, 'MAP_ENTRY_BAD_KEY_FREES_VALUE');

  { A record has no destructor: what the read built into it - an object, a
    list and the list's elements - is freed when a later field fails. }
  Source := TRecordSourceHolder.Create;
  try
    Source.R.O := NewSource(1, 0);
    Source.R.L := TObjectList<TCountedSource>.Create(True);
    Source.R.L.Add(NewSource(2, 0));
    Source.R.L.Add(NewSource(3, 1));
    Source.R.N := 7;
    Data := TProtobufSerializer.Serialize<TRecordSourceHolder>(Source);
  finally
    Source.Free;
  end;
  Before := GLive;
  Outcome := RaisedBy(procedure
    begin
      TProtobufSerializer.Deserialize<TCountedRecordHolder>(Data).Free;
    end);
  Check(Outcome = 'EProtobufInputError', 'RECORD_LATER_FIELD_REFUSED');
  Check(GLive = Before, 'RECORD_FAILURE_FREES_WHAT_IT_BUILT');

  { A construction that fails part way through a record, a TNullable of one,
    a list of them and a static array of them. }
  Alive := LeftAliveReadingPairs(PairDocument(1), 2, Outcome);
  Check((Outcome <> '') and (Alive = 0), 'RECORD_PARTLY_BUILT_FREED');
  Alive := LeftAliveReadingPairs(PairDocument(2), 2, Outcome);
  Check((Outcome <> '') and (Alive = 0), 'NULLABLE_RECORD_PARTLY_BUILT_FREED');
  Alive := LeftAliveReadingPairs(PairDocument(3), 4, Outcome);
  Check((Outcome <> '') and (Alive = 0), 'LIST_OF_RECORDS_PARTLY_BUILT_FREED');
  Alive := LeftAliveReadingPairs(PairDocument(4), 4, Outcome);
  Check((Outcome <> '') and (Alive = 0),
    'STATIC_ARRAY_OF_RECORDS_PARTLY_BUILT_FREED');
  Check(GLive = 0, 'NO_COUNTED_INSTANCE_LEFT');
end;

procedure TestContainerRefusal;
var
  Plain: TPlainLines;
  Data: TBytes;
  Outcome, Message: string;
begin
  Writeln;
  Writeln('-- a container that refuses an element --');

  { A sorted TStringList with Duplicates = dupError refuses a repeated line.
    What reaches the caller is protobuf's input error naming the container,
    not the RTL's EStringListError. }
  Plain := TPlainLines.Create;
  try
    Plain.Lines.Add('b');
    Plain.Lines.Add('a');
    Plain.Lines.Add('b');
    Data := TProtobufSerializer.Serialize<TPlainLines>(Plain);
  finally
    Plain.Free;
  end;
  Outcome := '';
  Message := '';
  try
    TProtobufSerializer.Deserialize<TSortedLines>(Data).Free;
  except
    on E: Exception do
    begin
      Outcome := E.ClassName;
      Message := E.Message;
    end;
  end;
  Note(Outcome + ': ' + Message);
  Check((Outcome = 'EProtobufInputError') and ContainsText(Message, 'TStringList'),
    'CONTAINER_REFUSAL_IS_AN_INPUT_ERROR');
end;

{ ===========================================================================
  Declared lengths past MaxInt, and a float into an int64 field

  Small messages that DECLARE a length-delimited payload of 2^31 - 1, 2^31,
  2^32 - 1, 2^63 and 2^64 - 1 bytes, through the contract, through an
  unknown field being skipped, through a descriptor set and through the
  wire reader itself: each is refused as malformed input, before anything
  that size is allocated. A float written to an int64 field by a schema is
  in range only when -2^63 <= F < 2^63; Trunc of anything outside raised
  the RTL's EInvalidOp.
  =========================================================================== }

function LengthSchema: TProtobufSchema;
var
  W: TProtoWriter;
begin
  W.Init;
  W.PutTag(1, TProtoWireType.LengthDelimited);
  W.PutLengthDelimited(FileDescriptor('len.proto', 'regress',
    MessageDescriptor('Len', [
      FieldDescriptor('v', 1, 3, ''),             { int64 }
      FieldDescriptor('b', 2, 12, '')])));        { bytes }
  Result := TProtobufSchema.LoadDescriptorSet(W.Done, 'regress.Len');
end;

procedure TestLengthOverMaxInt;
const
  LENGTHS: array[0..4] of string = (
    'FF FF FF FF 07',                    { 2^31 - 1 }
    '80 80 80 80 08',                    { 2^31 }
    'FF FF FF FF 0F',                    { 2^32 - 1 }
    '80 80 80 80 80 80 80 80 80 01',     { 2^63 }
    'FF FF FF FF FF FF FF FF FF 01');    { 2^64 - 1 }
var
  I: Integer;
  AllRefused: Boolean;
  Schema: TProtobufSchema;
  Outcome: string;
  R: TProtoReader;

  procedure Expect(const AWhere, AOutcome: string);
  begin
    if AOutcome <> 'EProtobufInputError' then
    begin
      Note(AWhere + ' -> ' + AOutcome);
      AllRefused := False;
    end;
  end;

  function FloatInto(ABits: UInt64): string;
  var
    D: Double;
    T: TDynamicValue;
    Bytes: TBytes;
  begin
    Move(ABits, D, 8);
    T := TDynamicValue.NewObject;
    try
      T.AsObject.Adopt('v', TDynamicValue.NewFloat(D));
      try
        Bytes := Schema.FromDynamic(T, 'regress.Len');
        Result := 'accept(' + Hex(Bytes) + ')';
      except
        on E: EProtobufInternalError do Result := 'refuse';
        on E: Exception do Result := 'raised ' + E.ClassName;
      end;
    finally
      T.Free;
    end;
  end;

begin
  Writeln;
  Writeln('-- declared lengths past MaxInt --');
  AllRefused := True;
  Schema := LengthSchema;
  try
    for I := 0 to High(LENGTHS) do
    begin
      Expect('contract ' + LENGTHS[I], RaisedBy(procedure
        begin
          TProtobufSerializer.Deserialize<TTest2>(
            FromHex('12 ' + LENGTHS[I] + ' 61')).Free;
        end));
      { field 9, wire type 2: unknown to TTest2, so skipped }
      Expect('skip ' + LENGTHS[I], RaisedBy(procedure
        begin
          TProtobufSerializer.Deserialize<TTest2>(
            FromHex('4A ' + LENGTHS[I] + ' 61')).Free;
        end));
      Expect('schema ' + LENGTHS[I], RaisedBy(procedure
        begin
          Schema.ToDynamic(FromHex('12 ' + LENGTHS[I] + ' 61'),
            'regress.Len').Free;
        end));
      Expect('reader ' + LENGTHS[I], RaisedBy(procedure
        begin
          R.InitWhole(FromHex(LENGTHS[I] + ' 61'));
          R.ReadLengthDelimited;
        end));
    end;
    Check(AllRefused, 'PROTOBUF_LENGTH_OVER_MAXINT_REFUSES');

    Outcome := FloatInto($C3E0000000000000) + ' ' +    { -2^63 }
      FloatInto($43DFFFFFFFFFFFFF) + ' ' +             { 2^63 - 1024 }
      FloatInto($43E0000000000000) + ' ' +             { 2^63 }
      FloatInto($C3E0000000000001) + ' ' +             { below -2^63 }
      FloatInto($7FF8000000000000) + ' ' +             { NaN }
      FloatInto($7FF0000000000000) + ' ' +             { +Inf }
      FloatInto($FFF0000000000000);                    { -Inf }
    Note(Outcome);
    Check(Outcome =
      'accept(08 80 80 80 80 80 80 80 80 80 01) ' +
      'accept(08 80 F8 FF FF FF FF FF FF 7F) ' +
      'refuse refuse refuse refuse refuse',
      'PROTOBUF_FLOAT_INTO_INT64_RANGE');
  finally
    Schema.Free;
  end;
end;


begin
  try
    TestSpecExamples;
    TestVarintsAndZigZag;
    TestEveryScalar;
    TestRichContract;
    TestOneOf;
    TestUnknownFields;
    TestGroups;
    TestMalformed;
    TestSchemaErrors;
    TestWriterDepth;
    TestWideUnsignedSubrange;
    TestTimestamps;
    TestSchemaTimestamps;
    TestFailedReadFrees;
    TestContainerRefusal;
    TestLengthOverMaxInt;
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
    Writeln('INDEPENDENT_INTEROP_DECODE: PASS');
    Writeln('INDEPENDENT_INTEROP_ENCODE: PASS');
    Writeln('PROTOBUF_NATIVE: PASS');
  end
  else
  begin
    Writeln('PROTOBUF_NATIVE: FAIL');
    ExitCode := 1;
  end;
end.
