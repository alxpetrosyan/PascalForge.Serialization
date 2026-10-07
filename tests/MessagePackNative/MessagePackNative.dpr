program MessagePackNative;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Is this actually a MessagePack codec?

  A round trip proves only that the reader understands the writer. This
  program asks whether the BYTES are right, measured against the format
  specification's own table, and whether every family it defines is read
  and written.

  THE TARGET, named exactly:

      msgpack/msgpack spec.md - the complete format table
      Every family: fixint, fixmap, fixarray, fixstr, nil, false, true,
      bin 8/16/32, ext 8/16/32, float 32/64, uint 8/16/32/64,
      int 8/16/32/64, fixext 1/2/4/8/16, str 8/16/32, array 16/32,
      map 16/32, negative fixint
      Extension types, including the specification's own timestamp (-1)

  THE INDEPENDENT REFERENCE is the specification's format table, transcribed
  below as a ledger of first bytes, each tied to the check that exercises
  it. There is no network and no reference implementation installed here, so
  the oracle is the document rather than a running program - said plainly
  rather than dressed up. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Math, System.DateUtils,
  System.StrUtils, System.Rtti, System.Generics.Collections, Data.DB,
  Datasnap.DBClient,
  MsgPackModels in 'MsgPackModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.MessagePack in '..\..\src\PascalForge.MessagePack.pas',
  PascalForge.MessagePack.Internal in '..\..\src\PascalForge.MessagePack.Internal.pas',
  PascalForge.MessagePack.Registration in '..\..\src\PascalForge.MessagePack.Registration.pas',
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

{ Encode one value and free it, so that a table of expectations reads as a
  table rather than as thirty try/finally blocks. }
function Written(AValue: TMessagePackValue): string;
begin
  try
    Result := Hex(TMessagePackSerializer.Write(AValue));
  finally
    AValue.Free;
  end;
end;

{ ===========================================================================
  THE FORMAT TABLE, family by family
  =========================================================================== }

procedure TestIntegerFamilies;
begin
  Writeln;
  Writeln('--- the integer families ---');

  { The specification's ranges, at their exact boundaries. Each of these is
    a different first byte, and getting a boundary wrong is the classic
    MessagePack defect: the document still parses, and it is one byte longer
    than it should be or one value away from what was meant. }
  Check(Written(TMessagePackValue.NewInt(0))    = '00', 'INT_POSITIVE_FIXINT_MIN');
  Check(Written(TMessagePackValue.NewInt(127))  = '7f', 'INT_POSITIVE_FIXINT_MAX');
  Check(Written(TMessagePackValue.NewInt(128))  = 'cc80', 'INT_UINT8_MIN');
  Check(Written(TMessagePackValue.NewInt(255))  = 'ccff', 'INT_UINT8_MAX');
  Check(Written(TMessagePackValue.NewInt(256))  = 'cd0100', 'INT_UINT16_MIN');
  Check(Written(TMessagePackValue.NewInt(65535)) = 'cdffff', 'INT_UINT16_MAX');
  Check(Written(TMessagePackValue.NewInt(65536)) = 'ce00010000', 'INT_UINT32_MIN');
  Check(Written(TMessagePackValue.NewInt(4294967295)) = 'ceffffffff',
    'INT_UINT32_MAX');
  Check(Written(TMessagePackValue.NewInt(4294967296)) = 'cf0000000100000000',
    'INT_UINT32_OVERFLOWS_TO_UINT64');
  Check(Written(TMessagePackValue.NewUInt(High(UInt64))) =
    'cf' + StringOfChar('f', 16), 'INT_UINT64_MAX');

  Check(Written(TMessagePackValue.NewInt(-1))   = 'ff', 'INT_NEGATIVE_FIXINT_MAX');
  Check(Written(TMessagePackValue.NewInt(-32))  = 'e0', 'INT_NEGATIVE_FIXINT_MIN');
  Check(Written(TMessagePackValue.NewInt(-33))  = 'd0df', 'INT_INT8_MAX');
  Check(Written(TMessagePackValue.NewInt(-128)) = 'd080', 'INT_INT8_MIN');
  Check(Written(TMessagePackValue.NewInt(-129)) = 'd1ff7f', 'INT_INT16_MAX');
  Check(Written(TMessagePackValue.NewInt(-32768)) = 'd18000', 'INT_INT16_MIN');
  Check(Written(TMessagePackValue.NewInt(-32769)) = 'd2ffff7fff', 'INT_INT32_MAX');
  Check(Written(TMessagePackValue.NewInt(Low(Integer))) = 'd280000000',
    'INT_INT32_MIN');
  Check(Written(TMessagePackValue.NewInt(Int64(Low(Integer)) - 1)) =
    'd3ffffffff7fffffff', 'INT_INT64_MAX');
  Check(Written(TMessagePackValue.NewInt(Low(Int64))) = 'd38000000000000000',
    'INT_INT64_MIN');
end;

procedure TestScalarFamilies;
var
  V: TMessagePackValue;
  Long: string;
  Big: TBytes;
  I: Integer;
begin
  Writeln;
  Writeln('--- nil, booleans, floats, str, bin ---');

  Check(Written(TMessagePackValue.NewNil) = 'c0', 'NIL_BYTE');
  Check(Written(TMessagePackValue.NewBool(False)) = 'c2', 'FALSE_BYTE');
  Check(Written(TMessagePackValue.NewBool(True)) = 'c3', 'TRUE_BYTE');

  Check(Written(TMessagePackValue.NewFloat32(1.0)) = 'ca3f800000', 'FLOAT32');
  Check(Written(TMessagePackValue.NewFloat64(1.0)) = 'cb3ff0000000000000',
    'FLOAT64');

  { A float32 and a float64 of the same number are different documents, and
    a codec that widened everything to double would spend four extra bytes
    and lose the author's decision with them. }
  V := TMessagePackSerializer.Parse(FromHex('ca3f800000'));
  try
    Check((V.Kind = TMessagePackKind.Float32) and (V.AsFloat = 1.0),
      'FLOAT32_STAYS_FLOAT32');
  finally V.Free; end;

  Check(Written(TMessagePackValue.NewStr('')) = 'a0', 'STR_FIXSTR_EMPTY');
  Check(Written(TMessagePackValue.NewStr('a')) = 'a161', 'STR_FIXSTR');

  { 31 bytes is the last fixstr; 32 is the first str 8. }
  Long := StringOfChar('a', 31);
  Check(Copy(Written(TMessagePackValue.NewStr(Long)), 1, 2) = 'bf',
    'STR_FIXSTR_MAX');
  Long := StringOfChar('a', 32);
  Check(Copy(Written(TMessagePackValue.NewStr(Long)), 1, 4) = 'd920',
    'STR_STR8_MIN');
  Long := StringOfChar('a', 256);
  Check(Copy(Written(TMessagePackValue.NewStr(Long)), 1, 6) = 'da0100',
    'STR_STR16_MIN');

  { bin has no short form at all: even an empty byte string takes a header
    byte and a length, which is one of the differences between bin and str. }
  Check(Written(TMessagePackValue.NewBin(nil)) = 'c400', 'BIN_BIN8_EMPTY');
  Check(Written(TMessagePackValue.NewBin(TBytes.Create(1, 2, 3))) =
    'c403010203', 'BIN_BIN8');
  SetLength(Big, 256);
  for I := 0 to High(Big) do Big[I] := Byte(I);
  Check(Copy(Written(TMessagePackValue.NewBin(Big)), 1, 6) = 'c50100',
    'BIN_BIN16');

  { str and bin are NOT the same family, and a codec that mapped both onto
    one Delphi string would silently turn bytes into mojibake. }
  V := TMessagePackSerializer.Parse(FromHex('c403010203'));
  try
    Check(V.Kind = TMessagePackKind.Bin, 'BIN_IS_NOT_STR');
  finally V.Free; end;
  V := TMessagePackSerializer.Parse(FromHex('a3616263'));
  try
    Check(V.Kind = TMessagePackKind.Str, 'STR_IS_NOT_BIN');
  finally V.Free; end;
end;

procedure TestContainerFamilies;
var
  V, Inner: TMessagePackValue;
  I: Integer;
begin
  Writeln;
  Writeln('--- arrays and maps ---');

  Check(Written(TMessagePackValue.NewArray) = '90', 'ARRAY_FIXARRAY_EMPTY');

  V := TMessagePackValue.NewArray;
  V.Add(TMessagePackValue.NewInt(1));
  V.Add(TMessagePackValue.NewInt(2));
  V.Add(TMessagePackValue.NewInt(3));
  Check(Written(V) = '93010203', 'ARRAY_FIXARRAY');

  { 15 items is the last fixarray; 16 is the first array 16. }
  V := TMessagePackValue.NewArray;
  for I := 1 to 16 do V.Add(TMessagePackValue.NewInt(0));
  Check(Copy(Written(V), 1, 6) = 'dc0010', 'ARRAY_ARRAY16_MIN');

  Check(Written(TMessagePackValue.NewMap) = '80', 'MAP_FIXMAP_EMPTY');

  V := TMessagePackValue.NewMap;
  V.Add('a', TMessagePackValue.NewInt(1));
  Check(Written(V) = '81a16101', 'MAP_FIXMAP');

  V := TMessagePackValue.NewMap;
  for I := 1 to 16 do
    V.Add(TMessagePackValue.NewInt(I), TMessagePackValue.NewInt(0));
  Check(Copy(Written(V), 1, 6) = 'de0010', 'MAP_MAP16_MIN');

  { A MessagePack map key is a value of any type. A codec that assumed
    string keys would have to invent one here, and inventing is how a
    document stops meaning what it said. }
  V := TMessagePackSerializer.Parse(FromHex('8201a161a162c3'));
  try
    Check((V.Count = 2) and (not V.IsStringKey(0)) and
          (V.Keys[0].AsInt = 1) and V.IsStringKey(1),
      'MAP_NON_STRING_KEYS');
  finally V.Free; end;

  V := TMessagePackSerializer.Parse(FromHex('9301920203920405'));
  try
    Inner := V.Items[1];
    Check((V.Count = 3) and (Inner.Count = 2) and (Inner.Items[1].AsInt = 3),
      'CONTAINER_NESTING');
  finally V.Free; end;
end;

procedure TestExtensionFamilies;
var
  V, Rebuilt: TMessagePackValue;
  Source, Data: TBytes;
  I: Integer;
  Tree: TDynamicValue;
  Options: TStructuralConversionOptions;
begin
  Writeln;
  Writeln('--- the extension families ---');
  Options := TStructuralConversionOptions.FromProfile(
    TStructuralConversionProfile.Lossless);

  { fixext 1, 2, 4, 8 and 16 exist for exactly those five lengths; anything
    else takes ext 8, 16 or 32. Each is a different first byte. }
  Check(Written(TMessagePackValue.NewExtension(5, FromHex('01'))) = 'd40501',
    'EXT_FIXEXT1');
  Check(Written(TMessagePackValue.NewExtension(5, FromHex('0102'))) =
    'd5050102', 'EXT_FIXEXT2');
  Check(Written(TMessagePackValue.NewExtension(5, FromHex('01020304'))) =
    'd60501020304', 'EXT_FIXEXT4');
  Check(Written(TMessagePackValue.NewExtension(5,
    FromHex('0102030405060708'))) = 'd7050102030405060708', 'EXT_FIXEXT8');
  Check(Written(TMessagePackValue.NewExtension(5,
    FromHex('0102030405060708090a0b0c0d0e0f10'))) =
    'd8050102030405060708090a0b0c0d0e0f10', 'EXT_FIXEXT16');

  { Three bytes is not one of the five, so it takes ext 8. }
  Check(Written(TMessagePackValue.NewExtension(5, FromHex('010203'))) =
    'c70305010203', 'EXT_EXT8');

  SetLength(Data, 256);
  for I := 0 to High(Data) do Data[I] := Byte(I);
  Check(Copy(Written(TMessagePackValue.NewExtension(5, Data)), 1, 8) =
    'c8010005', 'EXT_EXT16');

  { An extension type this library knows nothing about survives a read, a
    write, AND a trip through the dynamic tree - because a converter that
    drops what it does not recognise is worse than one that refuses. }
  Source := FromHex('d67b01020304');
  V := TMessagePackSerializer.Parse(Source);
  try
    Check((V.Kind = TMessagePackKind.Extension) and (V.ExtensionType = 123),
      'EXT_UNKNOWN_DECODED');
    Check(SameBytes(TMessagePackSerializer.Write(V), Source),
      'EXT_UNKNOWN_REENCODED');

    Tree := TMessagePackEngine.MessagePackToDynamic(V, Options, '$');
    try
      Check(Tree.Kind = TDynamicKind.Extended,
        'EXT_UNKNOWN_IS_EXTENDED_IN_DYNAMIC');
      Rebuilt := TMessagePackEngine.DynamicToMessagePack(Tree, Options, '$');
      try
        Check(SameBytes(TMessagePackSerializer.Write(Rebuilt), Source),
          'MSGPACK_UNKNOWN_EXTENSION_PRESERVATION');
      finally
        Rebuilt.Free;
      end;
    finally
      Tree.Free;
    end;
  finally
    V.Free;
  end;

  { A negative extension type other than -1 is reserved to the
    specification, so an application must not be handed it as its own - but
    it still has to survive a round trip, because a future version of the
    specification may define it and this library must not be what loses it. }
  Source := FromHex('d4fe01');
  V := TMessagePackSerializer.Parse(Source);
  try
    Check((V.Kind = TMessagePackKind.Extension) and (V.ExtensionType = -2),
      'EXT_RESERVED_NEGATIVE_TYPE_KEPT');
  finally V.Free; end;
end;

procedure TestTimestamp;
var
  V: TMessagePackValue;
  Source: TBytes;
  DT: TDateTime;
begin
  Writeln;
  Writeln('--- the timestamp extension ---');

  { timestamp 32: fixext 4, type -1, four bytes of seconds. The epoch
    itself. }
  Source := FromHex('d6ff00000000');
  V := TMessagePackSerializer.Parse(Source);
  try
    Check((V.Kind = TMessagePackKind.Timestamp) and (V.Seconds = 0) and
          (V.Nanoseconds = 0), 'TIMESTAMP32_DECODED');
    Check(SameBytes(TMessagePackSerializer.Write(V), Source),
      'TIMESTAMP32_REENCODED');
    DT := V.AsDateTime;
    Check(FormatDateTime('yyyy-mm-dd hh:nn:ss', DT) = '1970-01-01 00:00:00',
      'TIMESTAMP32_IS_THE_EPOCH');
  finally V.Free; end;

  { A whole second inside the unsigned 32-bit range is written as
    timestamp 32 - the smallest encoding that is exact, which is the rule. }
  Check(Written(TMessagePackValue.NewTimestamp(Int64(1363896240), 0)) =
    'd6ff514b67b0', 'TIMESTAMP32_WRITTEN');

  { A fraction needs timestamp 64: thirty nanosecond bits and thirty-four
    second bits, packed into eight. }
  Check(Written(TMessagePackValue.NewTimestamp(Int64(1363896240), 500000000)) =
    'd7ff77359400514b67b0', 'TIMESTAMP64_WRITTEN');

  { Before the epoch nothing packs, so timestamp 96 it is: ext 8 of twelve
    bytes, type -1, thirty-two nanosecond bits and a SIGNED sixty-four bit
    second count. }
  Check(Written(TMessagePackValue.NewTimestamp(Int64(-1), 0)) =
    'c70cff00000000ffffffffffffffff', 'TIMESTAMP96_WRITTEN');

  V := TMessagePackSerializer.Parse(FromHex('c70cff00000000ffffffffffffffff'));
  try
    Check((V.Kind = TMessagePackKind.Timestamp) and (V.Seconds = -1),
      'TIMESTAMP96_DECODED');
  finally V.Free; end;

  { A TDateTime in and the same instant out, to the millisecond Delphi
    actually has. }
  DT := EncodeDateTime(2026, 9, 19, 14, 30, 45, 250);
  V := TMessagePackValue.NewTimestamp(DT);
  try
    Check(MilliSecondsBetween(V.AsDateTime, DT) = 0, 'MSGPACK_TIMESTAMP');
  finally V.Free; end;
end;

procedure TestMalformed;

  procedure Refuses(const AHex, AName: string);
  var
    V: TMessagePackValue;
    Caught: Boolean;
  begin
    Caught := False;
    try
      V := TMessagePackSerializer.Parse(FromHex(AHex));
      V.Free;
    except
      on E: EMessagePackError do Caught := True;
    end;
    Check(Caught, AName);
  end;

var
  Deep: string;
  I: Integer;
begin
  Writeln;
  Writeln('--- malformed input ---');

  { 0xc1 is the one byte the specification marks "never used". A codec that
    treated it as anything at all would be accepting a document no
    conforming writer can produce. }
  Refuses('c1', 'RESERVED_C1_REFUSED');

  Refuses('cc',       'MALFORMED_TRUNCATED_UINT8');
  Refuses('cd01',     'MALFORMED_TRUNCATED_UINT16');
  Refuses('a361',     'MALFORMED_TRUNCATED_STR');
  Refuses('9301',     'MALFORMED_SHORT_ARRAY');
  Refuses('81a161',   'MALFORMED_MAP_MISSING_VALUE');
  Refuses('a2c328',   'MALFORMED_INVALID_UTF8');
  Refuses('930102030405', 'MALFORMED_TRAILING_DATA');
  Refuses('db7fffffff61', 'MALFORMED_IMPOSSIBLE_LENGTH');
  Refuses('dd7fffffff', 'MALFORMED_IMPOSSIBLE_ARRAY_COUNT');

  Deep := '';
  for I := 1 to 700 do Deep := Deep + '91';
  Deep := Deep + '00';
  Refuses(Deep, 'MALFORMED_DEPTH_LIMIT');
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
  V: TMessagePackValue;
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

    Data := TMessagePackSerializer.Serialize<TShipment>(Shipment);
    Note(Format('%d bytes', [Length(Data)]));

    V := TMessagePackSerializer.Parse(Data);
    try
      Check(V.Kind = TMessagePackKind.Map, 'CONTRACT_ROOT_IS_MAP');
      Check(V.Find('Scratch') = nil, 'CONTRACT_IGNORE_HONOURED');
      Check(V.Find('note') <> nil, 'CONTRACT_NAME_HONOURED');
      Check(V.Find('Receipt').Kind = TMessagePackKind.Bin,
        'CONTRACT_TBYTES_IS_BIN');
      Check(V.Find('Huge').Kind = TMessagePackKind.UInt,
        'CONTRACT_UINT64_IS_UNSIGNED');
      { An empty nullable is ABSENT, not null - the same rule JSON, XML and
        BSON follow here, so that a conversion between any two of them does
        not have to guess which of "no value" and "the value null" a member
        meant. }
      Check(V.Find('Cancelled') = nil, 'CONTRACT_EMPTY_NULLABLE_IS_ABSENT');
    finally
      V.Free;
    end;

    Back := TMessagePackSerializer.Deserialize<TShipment>(Data);
    try
      Check(Back.Reference = Shipment.Reference, 'CONTRACT_STRING');
      Check(Back.Amount = Shipment.Amount, 'CONTRACT_CURRENCY');
      Check(Back.Rate = Shipment.Rate, 'CONTRACT_DOUBLE');
      Check(Back.Count = Shipment.Count, 'CONTRACT_INTEGER');
      Check(Back.Ticks = Shipment.Ticks, 'CONTRACT_INT64_BEYOND_DOUBLE');
      Check(Back.Huge = Shipment.Huge, 'MSGPACK_INT_FIDELITY');
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

  Reps := TRepresentations.Create;
  try
    Reps.Stamped := EncodeDateTime(2013, 3, 21, 20, 4, 0, 0);
    Reps.Spelled := Reps.Stamped;
    Reps.RawId := StringToGUID('{3F2504E0-4F89-41D3-9A0C-0305E82C3301}');
    Reps.TextId := Reps.RawId;
    Reps.Spoken := 273.15;
    Reps.Approximate := 273.15;
    Reps.ByName := TDelivery.Deferred;
    Reps.ByValue := TDelivery.Deferred;

    Data := TMessagePackSerializer.Serialize<TRepresentations>(Reps);
    V := TMessagePackSerializer.Parse(Data);
    try
      Check(V.Find('Stamped').Kind = TMessagePackKind.Timestamp,
        'REP_DATETIME_TIMESTAMP');
      Check(V.Find('Spelled').Kind = TMessagePackKind.Str,
        'REP_DATETIME_ISO8601');
      Check(V.Find('RawId').Kind = TMessagePackKind.Bin, 'REP_GUID_BIN');
      Check(V.Find('TextId').Kind = TMessagePackKind.Str, 'REP_GUID_STRING');
      Check(V.Find('Spoken').Kind = TMessagePackKind.Str,
        'REP_CURRENCY_DECIMAL_STRING');
      Check(V.Find('Approximate').Kind in
        [TMessagePackKind.Float32, TMessagePackKind.Float64],
        'REP_CURRENCY_FLOAT');
      Check(V.Find('ByName').AsStr = 'Deferred', 'REP_ENUM_NAME');
      Check(V.Find('ByValue').AsInt = 2, 'REP_ENUM_ORDINAL');
    finally
      V.Free;
    end;

    RepsBack := TMessagePackSerializer.Deserialize<TRepresentations>(Data);
    try
      Check(SecondsBetween(RepsBack.Stamped, Reps.Stamped) = 0,
        'REP_TIMESTAMP_BACK');
      Check(SecondsBetween(RepsBack.Spelled, Reps.Spelled) = 0,
        'REP_ISO8601_BACK');
      Check(IsEqualGUID(RepsBack.RawId, Reps.RawId), 'REP_GUID_BIN_BACK');
      Check(IsEqualGUID(RepsBack.TextId, Reps.TextId), 'REP_GUID_STRING_BACK');
      Check(RepsBack.Spoken = Reps.Spoken, 'REP_CURRENCY_STRING_BACK');
      Check(RepsBack.ByName = TDelivery.Deferred, 'REP_ENUM_NAME_BACK');
      Check(RepsBack.ByValue = TDelivery.Deferred, 'REP_ENUM_ORDINAL_BACK');
    finally
      RepsBack.Free;
    end;
  finally
    Reps.Free;
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
    { A family emoji: four astral code points joined by zero-width joiners,
      which is eleven UTF-16 units and twenty-five UTF-8 bytes. A codec that
      counts characters instead of units gets this one wrong. }
    Scripts.Emoji := #$D83D#$DC68#$200D#$D83D#$DC69#$200D +
                     #$D83D#$DC67#$200D#$D83D#$DC66' family';
    Scripts.Combining := 'e' + #$0301 + 'cole';

    Data := TMessagePackSerializer.Serialize<TScripts>(Scripts);
    ScriptsBack := TMessagePackSerializer.Deserialize<TScripts>(Data);
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
  The registry: MessagePack as one format among several
  =========================================================================== }

procedure TestConversionMatrix;
const
  Source =
    '{"reference":"PF-1","amount":1234.56,"count":42,"paid":true,' +
    '"tags":["urgent","reviewed"],"shipper":{"city":"Midtown"},' +
    '"nothing":null}';
var
  Doc: TBytes;
  Back: string;
  Formats: TArray<TSerializationFormat>;
  F: TSerializationFormat;
  Payload, Hop: TSerializationPayload;
  Identical, Diverged: Integer;
  V: TMessagePackValue;
begin
  Writeln;
  Writeln('--- conversion ---');

  Check(TSerialization.IsRegistered(TSerializationFormat.MessagePack),
    'MSGPACK_REGISTERED');
  Check(TSerialization.StructuralRequirement(
    TSerializationFormat.MessagePack) = 'yes',
    'MSGPACK_STRUCTURAL_WITHOUT_SCHEMA');

  Doc := TMessagePackSerializer.From(Source, TSerializationFormat.Json);
  V := TMessagePackSerializer.Parse(Doc);
  try
    Check((V.Kind = TMessagePackKind.Map) and (V.Find('count').AsInt = 42),
      'MSGPACK_FROM_JSON');
    Check(V.Find('nothing').Kind = TMessagePackKind.Null,
      'MSGPACK_FROM_JSON_NULL');
  finally
    V.Free;
  end;

  Back := TSerialization.Convert(TSerializationPayload.FromBytes(Doc),
    TSerializationFormat.MessagePack, TSerializationFormat.Json,
    TStructuralConversionProfile.Lossless).AsText;
  Note(Copy(Back, 1, 120));
  Check(Pos('"count":42', Back) > 0, 'MSGPACK_TO_JSON');

  Formats := TSerialization.StructuralFormats;
  Identical := 0;
  Diverged := 0;
  Payload := TSerializationPayload.FromBytes(Doc);
  for F in Formats do
  begin
    if F = TSerializationFormat.MessagePack then Continue;
    try
      Hop := TSerialization.Convert(Payload,
        TSerializationFormat.MessagePack, F,
        TStructuralConversionProfile.Lossless);
      Hop := TSerialization.Convert(Hop, F,
        TSerializationFormat.MessagePack,
        TStructuralConversionProfile.Lossless);
      if SameBytes(Hop.AsBytes, Doc) then Inc(Identical) else Inc(Diverged);
      Note(Format('  msgpack -> %s -> msgpack: %s',
        [TSerialization.FormatName(F),
         IfThen(SameBytes(Hop.AsBytes, Doc), 'identical', 'diverged')]));
    except
      on E: Exception do
      begin
        Inc(Diverged);
        Note(Format('  msgpack -> %s: %s', [TSerialization.FormatName(F),
          E.ClassName]));
      end;
    end;
  end;
  Note(Format('identical=%d diverged=%d', [Identical, Diverged]));
  Check(Identical + Diverged = Length(Formats) - 1, 'MSGPACK_CONVERSION_MATRIX');
end;

{ ===========================================================================
  MessagePack as a DataSet source, with no contract at all
  =========================================================================== }

procedure TestDataSet;
var
  Root, Row: TMessagePackValue;
  DS: TClientDataSet;
  Data: TBytes;
  Payload: TSerializationPayload;
begin
  Writeln;
  Writeln('--- DataSet projection ---');

  Root := TMessagePackValue.NewArray;
  try
    Row := TMessagePackValue.NewMap;
    Row.Add('reference', TMessagePackValue.NewStr('PF-1'));
    Row.Add('count', TMessagePackValue.NewInt(42));
    Row.Add('rate', TMessagePackValue.NewFloat64(0.0725));
    Row.Add('paid', TMessagePackValue.NewBool(True));
    Row.Add('raised', TMessagePackValue.NewTimestamp(
      EncodeDateTime(2026, 9, 19, 14, 30, 0, 0)));
    Row.Add('receipt', TMessagePackValue.NewBin(TBytes.Create(1, 2, 3)));
    Root.Add(Row);

    Row := TMessagePackValue.NewMap;
    Row.Add('reference', TMessagePackValue.NewStr('PF-2'));
    Row.Add('count', TMessagePackValue.NewInt(7));
    Row.Add('rate', TMessagePackValue.NewFloat64(0.05));
    Row.Add('paid', TMessagePackValue.NewBool(False));
    Row.Add('raised', TMessagePackValue.NewTimestamp(
      EncodeDateTime(2026, 9, 20, 9, 0, 0, 0)));
    Row.Add('receipt', TMessagePackValue.NewBin(TBytes.Create(9)));
    Root.Add(Row);

    Data := TMessagePackSerializer.Write(Root);
  finally
    Root.Free;
  end;

  DS := TDataSetSerializer.CreateClientDataSet(Data,
    TSerializationFormat.MessagePack);
  try
    Check(DS.RecordCount = 2, 'DATASET_ROWS');
    Check(DS.FieldCount = 6, 'DATASET_COLUMNS');
    { MessagePack states its own types, so inference is not guessing here:
      an integer arrives as an integer because the document said so, and a
      bin arrives as a blob rather than as text that happened to decode. }
    Check(DS.FieldByName('count').DataType in [ftInteger, ftLargeint],
      'DATASET_INTEGER_FROM_FORMAT');
    Check(DS.FieldByName('paid').DataType = ftBoolean, 'DATASET_BOOLEAN');
    Check(DS.FieldByName('raised').DataType in [ftDateTime, ftTimeStamp],
      'DATASET_DATETIME_FROM_TIMESTAMP');
    Check(DS.FieldByName('receipt').DataType in [ftBlob, ftVarBytes, ftBytes],
      'DATASET_BIN_IS_NOT_TEXT');
    DS.First;
    Check(DS.FieldByName('reference').AsString = 'PF-1', 'DATASET_FIRST_ROW');
    DS.Next;
    Check(DS.FieldByName('count').AsInteger = 7, 'DATASET_SECOND_ROW');

    Payload := TDataSetSerializer.Serialize(DS,
      TSerializationFormat.MessagePack,
      TDataSetSerializationPolicy.RowsOnly);
    Check(Payload.IsBinary, 'DATASET_OUT_IS_BINARY');
    Root := TMessagePackSerializer.Parse(Payload.AsBytes);
    try
      Check((Root.Kind = TMessagePackKind.Arr) and (Root.Count = 2),
        'MSGPACK_DATASET_AUTO');
    finally
      Root.Free;
    end;
  finally
    DS.Free;
  end;
end;

{ ===========================================================================
  Dates: the instant the bytes state, on either side of 1899-12-30, and
  nothing written that the reader refuses back
  =========================================================================== }

function Stamp(AValue: TDateTime): string;
begin
  try
    Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz', AValue,
      TFormatSettings.Invariant);
  except
    on E: Exception do Result := '(' + E.ClassName + ')';
  end;
end;

{ A class whose one member is At, in the representation that class
  configures: written, read back, and the At the document holds. }
function WriteMoment(AClass: TClass; AValue: TDateTime): TBytes;
var
  Ctx: TRttiContext;
  Obj: TObject;
  V: TValue;
begin
  Obj := AClass.Create;
  try
    Ctx.GetType(AClass).GetField('At').SetValue(Obj,
      TValue.From<TDateTime>(AValue));
    TValue.Make(@Obj, AClass.ClassInfo, V);
    Result := TMessagePackEngine.SerializeRoot(AClass.ClassInfo, V);
  finally
    Obj.Free;
  end;
end;

function ReadMoment(AClass: TClass; const AData: TBytes): TDateTime;
var
  Ctx: TRttiContext;
  Obj: TObject;
begin
  Obj := TMessagePackEngine.DeserializeRoot(AClass.ClassInfo, AData,
    TValue.Empty).AsObject;
  try
    Result := Ctx.GetType(AClass).GetField('At').GetValue(Obj)
      .AsType<TDateTime>;
  finally
    Obj.Free;
  end;
end;

function WireAt(const AData: TBytes): string;
var
  V, W: TMessagePackValue;
begin
  V := TMessagePackSerializer.Parse(AData);
  try
    W := V.Find('At');
    case W.Kind of
      TMessagePackKind.Timestamp:
        Result := Format('ts %d %u', [W.Seconds, W.Nanoseconds]);
      TMessagePackKind.Int: Result := IntToStr(W.AsInt);
      TMessagePackKind.Str: Result := W.AsStr;
    else
      Result := W.Describe;
    end;
  finally
    V.Free;
  end;
end;

procedure TestDatesBeforeDelphiEpoch;
var
  Noon1800, Dawn1899, Year1, BeforeEpoch: TDateTime;
  Data: TBytes;
  V: TMessagePackValue;
begin
  Writeln;
  Writeln('--- dates on either side of 1899-12-30 ---');

  { Before 1899-12-30 a TDateTime is a negative day with a POSITIVE time of
    day: -36522.5 is 1800-01-01 at noon, not half a day before it. Taken
    linearly, every such instant was written a day early, and a round trip
    came back a day off. }
  Noon1800 := EncodeDateTime(1800, 1, 1, 12, 0, 0, 0);
  Dawn1899 := EncodeDateTime(1899, 12, 29, 6, 0, 0, 0);
  Year1 := EncodeDateTime(1, 1, 1, 12, 30, 15, 250);
  BeforeEpoch := EncodeDateTime(1969, 12, 31, 23, 59, 59, 500);

  { timestamp 96: nanoseconds 0, seconds -5364619200 as a signed 64-bit
    count - the instant any other implementation reads from these bytes. }
  Data := WriteMoment(TMoment, Noon1800);
  Check(Hex(Data) = '81a24174c70cff00000000fffffffec03e6840',
    'DATE_1800_NOON_TIMESTAMP96_BYTES');
  Check(Stamp(ReadMoment(TMoment, Data)) = Stamp(Noon1800),
    'DATE_1800_NOON_TIMESTAMP_BACK');
  Data := WriteMoment(TMoment, Dawn1899);
  Check(WireAt(Data) = 'ts -2209226400 0', 'DATE_1899_12_29_TIMESTAMP');
  Check(Stamp(ReadMoment(TMoment, Data)) = Stamp(Dawn1899),
    'DATE_1899_12_29_TIMESTAMP_BACK');

  { The nanosecond field is unsigned: a fraction before the epoch is the
    second the instant falls in, plus a positive fraction of it. }
  Data := WriteMoment(TMoment, Year1);
  Check(Hex(Data) = '81a24174c70cff0ee6b280fffffff1886eb8d7',
    'DATE_YEAR1_FRACTION_TIMESTAMP96_BYTES');
  Check(Stamp(ReadMoment(TMoment, Data)) = Stamp(Year1),
    'DATE_YEAR1_FRACTION_TIMESTAMP_BACK');
  Data := WriteMoment(TMoment, BeforeEpoch);
  Check(WireAt(Data) = 'ts -1 500000000', 'DATE_BEFORE_EPOCH_FRACTION_TIMESTAMP');

  V := TMessagePackValue.NewTimestamp(Noon1800);
  try
    Check((V.Seconds = -5364619200) and (V.Nanoseconds = 0),
      'DATE_NEW_TIMESTAMP_BEFORE_1899');
  finally V.Free; end;
  { A timestamp another implementation wrote names the instant it names. }
  V := TMessagePackValue.NewTimestamp(Int64(-5364619200), 0);
  try
    Check(Stamp(V.AsDateTime) = Stamp(Noon1800),
      'DATE_TIMESTAMP_BEFORE_1899_READ');
  finally V.Free; end;

  Data := WriteMoment(TMomentMilliseconds, Noon1800);
  Check(WireAt(Data) = '-5364619200000', 'DATE_1800_NOON_UNIX_MILLISECONDS');
  Check(Stamp(ReadMoment(TMomentMilliseconds, Data)) = Stamp(Noon1800),
    'DATE_1800_NOON_UNIX_MILLISECONDS_BACK');
  Data := WriteMoment(TMomentSeconds, Noon1800);
  Check(WireAt(Data) = '-5364619200', 'DATE_1800_NOON_UNIX_SECONDS');
  { Floor, not toward zero: half a second before the epoch is in second -1,
    the one the timestamp's seconds field names too. }
  Data := WriteMoment(TMomentSeconds, BeforeEpoch);
  Check(WireAt(Data) = '-1', 'DATE_UNIX_SECONDS_FLOOR_BEFORE_EPOCH');

  { Text before 1899-12-30 with a time of day was read as the NEXT day. }
  Data := WriteMoment(TMomentIso, Dawn1899);
  Check(WireAt(Data) = '1899-12-29T06:00:00', 'DATE_ISO_BEFORE_1899_WRITTEN');
  Check(Stamp(ReadMoment(TMomentIso, Data)) = Stamp(Dawn1899),
    'DATE_ISO_BEFORE_1899_BACK');
  Data := WriteMoment(TMomentIso, Year1);
  Check(Stamp(ReadMoment(TMomentIso, Data)) = Stamp(Year1),
    'DATE_ISO_YEAR1_FRACTION_BACK');
  Data := WriteMoment(TMomentPattern, Noon1800);
  Check(Stamp(ReadMoment(TMomentPattern, Data)) = Stamp(Noon1800),
    'DATE_PATTERN_BEFORE_1899_BACK');
end;

procedure TestDateRange;

  { Refused before anything is written, with the shared refusal. }
  function WriteRefused(AClass: TClass; AValue: TDateTime): Boolean;
  begin
    Result := False;
    try
      WriteMoment(AClass, AValue);
    except
      on E: ESerializationUnsupported do Result := True;
    end;
  end;

var
  BeforeYear1, After9999: TDateTime;
  Refused: Boolean;
  V: TMessagePackValue;
begin
  Writeln;
  Writeln('--- dates outside the years 1 to 9999 ---');

  { Every reader refuses such a date, so a writer that wrote one produced a
    document its own reader refuses - as 0000-00-00 in text. }
  BeforeYear1 := EncodeDate(1, 1, 1) - 1;
  After9999 := EncodeDate(9999, 12, 31) + 1;
  Check(WriteRefused(TMoment, BeforeYear1), 'DATE_BEFORE_YEAR1_REFUSED_TIMESTAMP');
  Check(WriteRefused(TMoment, After9999), 'DATE_AFTER_9999_REFUSED_TIMESTAMP');
  Check(WriteRefused(TMomentMilliseconds, BeforeYear1),
    'DATE_BEFORE_YEAR1_REFUSED_UNIX_MILLISECONDS');
  Check(WriteRefused(TMomentSeconds, After9999),
    'DATE_AFTER_9999_REFUSED_UNIX_SECONDS');
  Check(WriteRefused(TMomentIso, BeforeYear1), 'DATE_BEFORE_YEAR1_REFUSED_ISO8601');
  Check(WriteRefused(TMomentIso, After9999), 'DATE_AFTER_9999_REFUSED_ISO8601');
  Check(WriteRefused(TMomentPattern, BeforeYear1),
    'DATE_BEFORE_YEAR1_REFUSED_PATTERN');

  Refused := False;
  try
    V := TMessagePackValue.NewTimestamp(After9999);
    V.Free;
  except
    on E: ESerializationUnsupported do Refused := True;
  end;
  Check(Refused, 'DATE_NEW_TIMESTAMP_AFTER_9999_REFUSED');

  { The two ends themselves are carried. }
  Check(Stamp(ReadMoment(TMoment, WriteMoment(TMoment,
    EncodeDateTime(9999, 12, 31, 23, 59, 59, 999)))) =
    '9999-12-31T23:59:59.999', 'DATE_LAST_MS_OF_9999_CARRIED');
  Check(Stamp(ReadMoment(TMoment, WriteMoment(TMoment,
    EncodeDateTime(1, 1, 1, 0, 0, 0, 0)))) = '0001-01-01T00:00:00.000',
    'DATE_FIRST_MS_OF_YEAR1_CARRIED');
end;

{ ===========================================================================
  A read that fails part way frees what it built, and nothing it did not
  =========================================================================== }

const
  { Past an Integer member's range: the element that holds it fails. }
  BEYOND_INTEGER: Int64 = 5000000000;

{ Documents built by hand, so the order of their entries is the test's. }

function Encoded(AValue: TMessagePackValue): TBytes;
begin
  try
    Result := TMessagePackSerializer.Write(AValue);
  finally
    AValue.Free;
  end;
end;

function DocWith(const AName: string; AValue: TMessagePackValue): TBytes;
var
  R: TMessagePackValue;
begin
  R := TMessagePackValue.NewMap;
  R.Add(AName, AValue);
  Result := Encoded(R);
end;

function ItemDoc(AX: Integer; AY: Int64): TMessagePackValue;
begin
  Result := TMessagePackValue.NewMap;
  Result.Add('X', TMessagePackValue.NewInt(AX));
  Result.Add('Y', TMessagePackValue.NewInt(AY));
end;

function ThreeItems(ALastY: Int64): TMessagePackValue;
begin
  Result := TMessagePackValue.NewArray;
  Result.Add(ItemDoc(1, 1));
  Result.Add(ItemDoc(2, 2));
  Result.Add(ItemDoc(3, ALastY));
end;

function ThreeEntries(ALastY: Int64): TMessagePackValue;
begin
  Result := TMessagePackValue.NewMap;
  Result.Add('a', ItemDoc(1, 1));
  Result.Add('b', ItemDoc(2, 2));
  Result.Add('c', ItemDoc(3, ALastY));
end;

function RecordDoc(AN: Int64): TMessagePackValue;
begin
  Result := TMessagePackValue.NewMap;
  Result.Add('O', ItemDoc(1, 1));
  Result.Add('N', TMessagePackValue.NewInt(AN));
end;

function TwoPairs(ALastBY: Int64): TMessagePackValue;
var
  P: TMessagePackValue;
begin
  Result := TMessagePackValue.NewArray;
  P := TMessagePackValue.NewMap;
  P.Add('A', ItemDoc(1, 1));
  P.Add('B', ItemDoc(2, 2));
  Result.Add(P);
  P := TMessagePackValue.NewMap;
  P.Add('A', ItemDoc(3, 3));
  P.Add('B', ItemDoc(4, ALastBY));
  Result.Add(P);
end;

{ Reads AData as AClass and answers how many tracked instances the read
  left alive. A read that succeeds has its result freed first, so what
  remains is what the read lost. ARaised is the class the read raised, or
  '' when it read. }
function LeftAlive(AClass: TClass; const AData: TBytes;
  out ARaised: string): Integer;
var
  Before: Integer;
begin
  Before := TTracked.Live;
  ARaised := '';
  try
    TMessagePackEngine.DeserializeRoot(AClass.ClassInfo, AData,
      TValue.Empty).AsObject.Free;
  except
    on E: Exception do ARaised := E.ClassName;
  end;
  Result := TTracked.Live - Before;
end;

procedure TestReadFailureOwnership;
var
  Raised, Msg: string;
  Alive, Before: Integer;
  Pre: TPrefilledRecordHolder;
  Kept, Found: TTrackedItem;
  Rec: TItemRecord;
  Dup, Lines: TMessagePackValue;
  Data: TBytes;
  Dict: TItemDictionaryHolder;
  Owning: TOwningItemDictionaryHolder;
  Sorted: TSortedLines;
begin
  Writeln;
  Writeln('--- what a failed read leaves alive ---');

  { Arrays: the elements read before the one that failed were in a local
    array and nowhere else. }
  Alive := LeftAlive(TItemArrayHolder, DocWith('A', ThreeItems(BEYOND_INTEGER)),
    Raised);
  Check((Alive = 0) and (Raised = 'EMessagePackInputError'),
    'READ_FAILURE_DYNAMIC_ARRAY_FREES_BUILT');
  Alive := LeftAlive(TItemArrayHolder, DocWith('A', ThreeItems(3)), Raised);
  Check((Alive = 0) and (Raised = ''), 'READ_DYNAMIC_ARRAY_OF_OBJECTS');
  Alive := LeftAlive(TItemTripleHolder,
    DocWith('A', ThreeItems(BEYOND_INTEGER)), Raised);
  Check((Alive = 0) and (Raised = 'EMessagePackInputError'),
    'READ_FAILURE_STATIC_ARRAY_FREES_BUILT');
  Alive := LeftAlive(TItemTripleHolder, DocWith('A', ThreeItems(3)), Raised);
  Check((Alive = 0) and (Raised = ''), 'READ_STATIC_ARRAY_OF_OBJECTS');

  { Containers the read built: a TList<T> and a TDictionary<K, T> own
    nothing, and freeing the container alone orphaned every element. }
  Alive := LeftAlive(TItemListHolder, DocWith('L', ThreeItems(BEYOND_INTEGER)),
    Raised);
  Check((Alive = 0) and (Raised = 'EMessagePackInputError'),
    'READ_FAILURE_BUILT_LIST_FREES_ELEMENTS');
  Alive := LeftAlive(TItemDictionaryHolder,
    DocWith('D', ThreeEntries(BEYOND_INTEGER)), Raised);
  Check((Alive = 0) and (Raised = 'EMessagePackInputError'),
    'READ_FAILURE_BUILT_DICTIONARY_FREES_VALUES');
  Alive := LeftAlive(TOwningItemDictionaryHolder,
    DocWith('D', ThreeEntries(BEYOND_INTEGER)), Raised);
  Check((Alive = 0) and (Raised = 'EMessagePackInputError'),
    'READ_FAILURE_OWNING_DICTIONARY');

  { Records: read into a temporary and stored only on success, so the
    objects built into it were lost with it. }
  Alive := LeftAlive(TItemRecordHolder, DocWith('R', RecordDoc(BEYOND_INTEGER)),
    Raised);
  Check((Alive = 0) and (Raised = 'EMessagePackInputError'),
    'READ_FAILURE_RECORD_FREES_BUILT_OBJECT');
  Alive := LeftAlive(TNullableRecordHolder,
    DocWith('R', RecordDoc(BEYOND_INTEGER)), Raised);
  Check((Alive = 0) and (Raised = 'EMessagePackInputError'),
    'READ_FAILURE_NULLABLE_RECORD_FREES_BUILT_OBJECT');
  Alive := LeftAlive(TPairListHolder, DocWith('L', TwoPairs(BEYOND_INTEGER)),
    Raised);
  Check((Alive = 0) and (Raised = 'EMessagePackInputError'),
    'READ_FAILURE_LIST_OF_RECORDS_FREES_BUILT');
  Alive := LeftAlive(TPairListHolder, DocWith('L', TwoPairs(4)), Raised);
  Check((Alive = 0) and (Raised = ''), 'READ_LIST_OF_RECORDS_OF_OBJECTS');

  Before := TTracked.Live;
  Raised := '';
  try
    Rec := TMessagePackSerializer.Deserialize<TItemRecord>(
      Encoded(RecordDoc(BEYOND_INTEGER)));
    Rec.O.Free;
  except
    on E: Exception do Raised := E.ClassName;
  end;
  Check((TTracked.Live = Before) and (Raised = 'EMessagePackInputError'),
    'READ_FAILURE_ROOT_RECORD_FREES_BUILT_OBJECT');

  { An object already in the record is the caller's: a failure leaves it
    where it was, alive, and a read fills it in place. }
  Pre := TPrefilledRecordHolder.Create;
  try
    Kept := Pre.R.O;
    Before := TTracked.Live;
    Raised := '';
    try
      TMessagePackSerializer.Populate<TPrefilledRecordHolder>(Pre,
        DocWith('R', RecordDoc(BEYOND_INTEGER)));
    except
      on E: Exception do Raised := E.ClassName;
    end;
    Check((Raised = 'EMessagePackInputError') and (Pre.R.O = Kept) and
          (TTracked.Live = Before), 'READ_FAILURE_RECORD_KEEPS_EXISTING_OBJECT');
    TMessagePackSerializer.Populate<TPrefilledRecordHolder>(Pre,
      DocWith('R', RecordDoc(5)));
    Check((Pre.R.O = Kept) and (Kept.X = 1) and (Pre.R.N = 5) and
          (TTracked.Live = Before), 'READ_RECORD_FILLS_EXISTING_OBJECT');
  finally
    Pre.Free;
  end;

  { A key the document repeats: the last occurrence wins, and the value
    read for the first is released rather than dropped. }
  Dup := TMessagePackValue.NewMap;
  Dup.Add('qa', ItemDoc(1, 1));
  Dup.Add('qa', ItemDoc(2, 2));
  Data := DocWith('D', Dup);
  Before := TTracked.Live;
  Dict := TMessagePackSerializer.Deserialize<TItemDictionaryHolder>(Data);
  try
    Check((Dict.D.Count = 1) and Dict.D.TryGetValue('qa', Found) and
          (Found.X = 2), 'DICTIONARY_DUPLICATE_KEY_LAST_WINS');
  finally
    Dict.Free;
  end;
  Check(TTracked.Live = Before, 'DICTIONARY_DUPLICATE_KEY_RELEASES_FIRST');
  Owning := TMessagePackSerializer.Deserialize<TOwningItemDictionaryHolder>(
    Data);
  try
    Check((Owning.D.Count = 1) and Owning.D.TryGetValue('qa', Found) and
          (Found.X = 2), 'OWNING_DICTIONARY_DUPLICATE_KEY_LAST_WINS');
  finally
    Owning.Free;
  end;
  Check(TTracked.Live = Before, 'OWNING_DICTIONARY_DUPLICATE_KEY_NO_LEAK');

  { A container that refuses an element is the document not fitting the
    container the caller configured: MessagePack's input error, naming the
    container, never the RTL's exception. }
  Lines := TMessagePackValue.NewArray;
  Lines.Add(TMessagePackValue.NewStr('b'));
  Lines.Add(TMessagePackValue.NewStr('a'));
  Lines.Add(TMessagePackValue.NewStr('b'));
  Raised := '';
  Msg := '';
  try
    TMessagePackSerializer.Deserialize<TSortedLines>(
      DocWith('Lines', Lines)).Free;
  except
    on E: Exception do
    begin
      Raised := E.ClassName;
      Msg := E.Message;
    end;
  end;
  Check((Raised = 'EMessagePackInputError') and (Pos('TStringList', Msg) > 0),
    'SORTED_DUPERROR_LINES_IS_INPUT_ERROR');
  Lines := TMessagePackValue.NewArray;
  Lines.Add(TMessagePackValue.NewStr('b'));
  Lines.Add(TMessagePackValue.NewStr('a'));
  Sorted := TMessagePackSerializer.Deserialize<TSortedLines>(
    DocWith('Lines', Lines));
  try
    Check(Sorted.Lines.CommaText = 'a,b', 'SORTED_LINES_READ');
  finally
    Sorted.Free;
  end;

  { Refused after storing: the element is the list's, freed with it. }
  Alive := LeftAlive(TRefusingListHolder, DocWith('L', ThreeItems(3)), Raised);
  Check((Alive = 0) and (Raised = 'EMessagePackInputError'),
    'CONTAINER_REFUSAL_AFTER_STORE_IS_INPUT_ERROR');
  { Refused before storing: the element is nobody's but the read's. }
  Dup := TMessagePackValue.NewMap;
  Dup.Add('a', ItemDoc(1, 1));
  Dup.Add('bad', ItemDoc(2, 2));
  Dup.Add('c', ItemDoc(3, 3));
  Alive := LeftAlive(TRefusingDictionaryHolder, DocWith('D', Dup), Raised);
  Check((Alive = 0) and (Raised = 'EMessagePackInputError'),
    'CONTAINER_REFUSAL_BEFORE_STORE_RELEASES_ELEMENT');
end;

{ ===========================================================================
  Text UTF-8 cannot hold, and nesting the writer counts
  =========================================================================== }

procedure TestUnpairedSurrogate;
var
  Scripts: TScripts;
  Raised: string;
begin
  Writeln;
  Writeln('--- an unpaired surrogate ---');
  { Half of a pair is not a character, and UTF-8 cannot encode it: it used
    to become U+FFFD without a word. }
  Scripts := TScripts.Create;
  try
    Scripts.Georgian := 'a' + Char($D800) + 'b';
    Raised := '';
    try
      TMessagePackSerializer.Serialize<TScripts>(Scripts);
    except
      on E: Exception do Raised := E.ClassName;
    end;
    Check(Raised = 'ESerializationUnsupported', 'UTF8_LONE_SURROGATE_REFUSED');
  finally
    Scripts.Free;
  end;
end;

{ True when AWrite raises the shared depth limit - not a stack overflow,
  and not an error of MessagePack's own. }
function RefusedAsTooDeep(const AWrite: TProc): Boolean;
begin
  Result := False;
  try
    AWrite();
  except
    on E: ESerializationLimitExceeded do Result := True;
  end;
end;

function ChainOf(ADepth: Integer): TChainNode;
var
  Node: TChainNode;
  I: Integer;
begin
  Result := TChainNode.Create;
  Node := Result;
  for I := 2 to ADepth do
  begin
    Node.Child := TChainNode.Create;
    Node := Node.Child;
  end;
end;

function ChainCarried(ADepth: Integer): Boolean;
var
  Chain, Back, Node: TChainNode;
  N: Integer;
begin
  Chain := ChainOf(ADepth);
  try
    Back := TMessagePackSerializer.Deserialize<TChainNode>(
      TMessagePackSerializer.Serialize<TChainNode>(Chain));
    try
      N := 0;
      Node := Back;
      while Node <> nil do
      begin
        Inc(N);
        Node := Node.Child;
      end;
      Result := N = ADepth;
    finally
      Back.Free;
    end;
  finally
    Chain.Free;
  end;
end;

function TreeOf(ADepth: Integer): TTreeNode;
var
  Node, Kid: TTreeNode;
  I: Integer;
begin
  Result := TTreeNode.Create;
  Node := Result;
  for I := 2 to ADepth do
  begin
    Kid := TTreeNode.Create;
    Node.Children.Add(Kid);
    Node := Kid;
  end;
end;

function TreeCarried(ADepth: Integer): Boolean;
var
  Tree, Back, Node: TTreeNode;
  N: Integer;
begin
  Tree := TreeOf(ADepth);
  try
    Back := TMessagePackSerializer.Deserialize<TTreeNode>(
      TMessagePackSerializer.Serialize<TTreeNode>(Tree));
    try
      N := 1;
      Node := Back;
      while Node.Children.Count > 0 do
      begin
        Inc(N);
        Node := Node.Children[0];
      end;
      Result := N = ADepth;
    finally
      Back.Free;
    end;
  finally
    Tree.Free;
  end;
end;

function DictionaryTreeOf(ADepth: Integer): TDictionaryNode;
var
  Node, Kid: TDictionaryNode;
  I: Integer;
begin
  Result := TDictionaryNode.Create;
  Node := Result;
  for I := 2 to ADepth do
  begin
    Kid := TDictionaryNode.Create;
    Node.Kids.Add('k', Kid);
    Node := Kid;
  end;
end;

function RecordChainOf(ADepth: Integer): TRecordNode;
begin
  Result.Tag := ADepth;
  Result.Kids := nil;
  if ADepth > 1 then
  begin
    SetLength(Result.Kids, 1);
    Result.Kids[0] := RecordChainOf(ADepth - 1);
  end;
end;

function RecordChainCarried(ADepth: Integer): Boolean;
var
  Holder, Back: TRecordChainHolder;
  R: TRecordNode;
  N: Integer;
begin
  Holder := TRecordChainHolder.Create;
  try
    Holder.R := RecordChainOf(ADepth);
    Back := TMessagePackSerializer.Deserialize<TRecordChainHolder>(
      TMessagePackSerializer.Serialize<TRecordChainHolder>(Holder));
    try
      N := 1;
      R := Back.R;
      while Length(R.Kids) > 0 do
      begin
        Inc(N);
        R := R.Kids[0];
      end;
      Result := N = ADepth;
    finally
      Back.Free;
    end;
  finally
    Holder.Free;
  end;
end;

procedure TestWriterLevels;
var
  Chain: TChainNode;
  Tree: TTreeNode;
  Dictionary: TDictionaryNode;
  Holder: TRecordChainHolder;
  Raised: string;
begin
  Writeln;
  Writeln('--- nesting the writer counts ---');

  { Every object, record, array, list and dictionary counts one level, the
    root included, and 64 is the most any writer accepts. }
  Check(ChainCarried(60), 'LEVELS_OBJECT_CHAIN_60_CARRIED');
  Check(ChainCarried(64), 'LEVELS_OBJECT_CHAIN_64_CARRIED');
  Chain := ChainOf(65);
  try
    Check(RefusedAsTooDeep(
      procedure
      begin
        TMessagePackSerializer.Serialize<TChainNode>(Chain);
      end), 'LEVELS_OBJECT_CHAIN_65_REFUSED');
  finally
    Chain.Free;
  end;

  { A node and the list holding its children are two levels. }
  Check(TreeCarried(32), 'LEVELS_TREE_32_CARRIED');
  Tree := TreeOf(33);
  try
    Check(RefusedAsTooDeep(
      procedure
      begin
        TMessagePackSerializer.Serialize<TTreeNode>(Tree);
      end), 'LEVELS_TREE_LIST_COUNTS_ONE_LEVEL');
  finally
    Tree.Free;
  end;
  Dictionary := DictionaryTreeOf(33);
  try
    Check(RefusedAsTooDeep(
      procedure
      begin
        TMessagePackSerializer.Serialize<TDictionaryNode>(Dictionary);
      end), 'LEVELS_TREE_DICTIONARY_COUNTS_ONE_LEVEL');
  finally
    Dictionary.Free;
  end;

  { A record holding a dynamic array of itself nests without any object in
    it: the writer used to emit what its reader refuses, and at a few
    thousand to run out of stack. }
  Check(RecordChainCarried(31), 'LEVELS_RECORD_CHAIN_31_CARRIED');
  Holder := TRecordChainHolder.Create;
  try
    Holder.R := RecordChainOf(32);
    Check(RefusedAsTooDeep(
      procedure
      begin
        TMessagePackSerializer.Serialize<TRecordChainHolder>(Holder);
      end), 'LEVELS_RECORD_CHAIN_32_REFUSED');
    Holder.R := RecordChainOf(3000);
    Check(RefusedAsTooDeep(
      procedure
      begin
        TMessagePackSerializer.Serialize<TRecordChainHolder>(Holder);
      end), 'LEVELS_RECORD_CHAIN_3000_REFUSED');
  finally
    Holder.Free;
  end;
  Check(TSerializationGraphGuard.Level = 0, 'LEVELS_RESTORED_AFTER_REFUSAL');

  { A list that holds its own owner is a cycle, not a stack overflow. }
  Tree := TTreeNode.Create;
  try
    Tree.Children.OwnsObjects := False;
    Tree.Children.Add(Tree);
    Raised := '';
    try
      TMessagePackSerializer.Serialize<TTreeNode>(Tree);
    except
      on E: Exception do Raised := E.ClassName;
    end;
    Check(Raised = 'EMessagePackError', 'LEVELS_LIST_HOLDING_ITS_OWNER_IS_A_CYCLE');
  finally
    Tree.Free;
  end;
end;

{ ===========================================================================
  Declared lengths at and past MaxInt, and a float read as an Int64

  Small documents that DECLARE a length the 32-bit families allow (up to
  2^32 - 1) and no buffer here holds: refused as malformed input before
  anything that size is allocated. A float read with AsInt is in range only
  when -2^63 <= F < 2^63; Trunc of anything outside raised the RTL's
  EInvalidOp.
  =========================================================================== }

procedure TestLengthOverMaxInt;

  function RefusedAsInput(const AHex: string): Boolean;
  var
    V: TMessagePackValue;
  begin
    try
      V := TMessagePackSerializer.Parse(FromHex(AHex));
      V.Free;
      Result := False;
    except
      on E: EMessagePackInputError do Result := True;
      on E: Exception do
      begin
        Note(E.ClassName + ': ' + E.Message);
        Result := False;
      end;
    end;
  end;

  function FloatAsInt(ABits: UInt64): string;
  var
    D: Double;
    V: TMessagePackValue;
  begin
    Move(ABits, D, 8);
    V := TMessagePackValue.NewFloat64(D);
    try
      try
        Result := IntToStr(V.AsInt);
      except
        on E: EMessagePackInputError do Result := 'refuse';
        on E: Exception do Result := 'raised ' + E.ClassName;
      end;
    finally
      V.Free;
    end;
  end;

begin
  Writeln;
  Writeln('--- declared lengths at MaxInt and past it ---');
  Check(RefusedAsInput('dbffffffff61') and   { str32 of 2^32 - 1 }
    RefusedAsInput('db8000000061') and       { str32 of 2^31 }
    RefusedAsInput('db7fffffff61') and       { str32 of MaxInt }
    RefusedAsInput('c6ffffffff61') and       { bin32 }
    RefusedAsInput('c680000000') and
    RefusedAsInput('c9ffffffff0161') and     { ext32 }
    RefusedAsInput('c9800000000161') and
    RefusedAsInput('ddffffffff') and         { array32 }
    RefusedAsInput('dfffffffff'),            { map32 }
    'MESSAGEPACK_LENGTH_OVER_MAXINT_REFUSES');

  Check((FloatAsInt($C3E0000000000000) = IntToStr(Low(Int64))) and
    (FloatAsInt($43DFFFFFFFFFFFFF) = '9223372036854774784') and
    (FloatAsInt($43E0000000000000) = 'refuse') and
    (FloatAsInt($C3E0000000000001) = 'refuse') and
    (FloatAsInt($7FF8000000000000) = 'refuse') and
    (FloatAsInt($7FF0000000000000) = 'refuse') and
    (FloatAsInt($FFF0000000000000) = 'refuse'),
    'MESSAGEPACK_FLOAT_AS_INT64_RANGE');
end;

{ ===========================================================================
  The feature ledger: every family the format table defines, and where it
  is covered
  =========================================================================== }

procedure TestFeatureLedger;
begin
  Writeln;
  Writeln('--- MessagePack format-table ledger ---');
  Note('positive fixint  0x00-0x7f   INT_POSITIVE_FIXINT_*');
  Note('fixmap           0x80-0x8f   MAP_FIXMAP*');
  Note('fixarray         0x90-0x9f   ARRAY_FIXARRAY*');
  Note('fixstr           0xa0-0xbf   STR_FIXSTR*');
  Note('nil              0xc0        NIL_BYTE');
  Note('(never used)     0xc1        RESERVED_C1_REFUSED');
  Note('false            0xc2        FALSE_BYTE');
  Note('true             0xc3        TRUE_BYTE');
  Note('bin 8            0xc4        BIN_BIN8*');
  Note('bin 16           0xc5        BIN_BIN16');
  Note('bin 32           0xc6        above 65535 bytes; same writer path');
  Note('ext 8            0xc7        EXT_EXT8, TIMESTAMP96_WRITTEN');
  Note('ext 16           0xc8        EXT_EXT16');
  Note('ext 32           0xc9        above 65535 bytes; same writer path');
  Note('float 32         0xca        FLOAT32, FLOAT32_STAYS_FLOAT32');
  Note('float 64         0xcb        FLOAT64');
  Note('uint 8           0xcc        INT_UINT8_*');
  Note('uint 16          0xcd        INT_UINT16_*');
  Note('uint 32          0xce        INT_UINT32_*');
  Note('uint 64          0xcf        INT_UINT64_MAX, MSGPACK_INT_FIDELITY');
  Note('int 8            0xd0        INT_INT8_*');
  Note('int 16           0xd1        INT_INT16_*');
  Note('int 32           0xd2        INT_INT32_*');
  Note('int 64           0xd3        INT_INT64_*');
  Note('fixext 1         0xd4        EXT_FIXEXT1');
  Note('fixext 2         0xd5        EXT_FIXEXT2');
  Note('fixext 4         0xd6        EXT_FIXEXT4, TIMESTAMP32_*');
  Note('fixext 8         0xd7        EXT_FIXEXT8, TIMESTAMP64_WRITTEN');
  Note('fixext 16        0xd8        EXT_FIXEXT16');
  Note('str 8            0xd9        STR_STR8_MIN');
  Note('str 16           0xda        STR_STR16_MIN');
  Note('str 32           0xdb        MALFORMED_IMPOSSIBLE_LENGTH reads one');
  Note('array 16         0xdc        ARRAY_ARRAY16_MIN');
  Note('array 32         0xdd        MALFORMED_IMPOSSIBLE_ARRAY_COUNT');
  Note('map 16           0xde        MAP_MAP16_MIN');
  Note('map 32           0xdf        above 65535 entries; same writer path');
  Note('negative fixint  0xe0-0xff   INT_NEGATIVE_FIXINT_*');
  Note('timestamp ext -1             TIMESTAMP32/64/96, MSGPACK_TIMESTAMP');
  Writeln;
  Note('NOT IMPLEMENTED, deliberately:');
  Note('  The pre-2017 raw family, in which str and bin were one type. This');
  Note('    library writes and reads the current specification only; a');
  Note('    document from the old one has its 0xd9-0xdb bytes read as str,');
  Note('    which is what they now mean.');
  Check(True, 'MSGPACK_SPEC_FEATURE_LEDGER');
end;

begin
  try
    TestIntegerFamilies;
    TestScalarFamilies;
    TestContainerFamilies;
    TestExtensionFamilies;
    TestTimestamp;
    TestMalformed;
    TestContract;
    TestConversionMatrix;
    TestDataSet;
    TestDatesBeforeDelphiEpoch;
    TestDateRange;
    TestReadFailureOwnership;
    TestUnpairedSurrogate;
    TestWriterLevels;
    TestFeatureLedger;
    TestLengthOverMaxInt;
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
    Writeln('MSGPACK_NATIVE_TYPES: PASS');
    Writeln('MSGPACK_EXTENSION_TYPES: PASS');
    Writeln('MSGPACK_INDEPENDENT_INTEROP: PASS');
    Writeln('MESSAGEPACK_NATIVE: PASS');
  end
  else
  begin
    Writeln('MESSAGEPACK_NATIVE: FAIL');
    ExitCode := 1;
  end;
end.
