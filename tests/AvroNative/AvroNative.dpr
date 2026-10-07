program AvroNative;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Is this actually an Avro implementation?

  Avro is the format in this library whose bytes mean NOTHING on their own.
  A record is its fields one after another with nothing between them; an
  int, an enum index and a union branch are all the same zig-zag varint.
  Everything that makes the bytes readable is in the schema - which is why
  the interesting question here is not "does it round-trip" but "does it
  read a file written by a DIFFERENT schema", and that is what most of this
  program is about.

  THE TARGET, named exactly:

      Apache Avro 1.12.x specification
      The schema model, and the JSON schema declaration parsed
      The binary encoding: zig-zag varints, blocks, unions, fixed
      SCHEMA RESOLUTION - writer against reader, which is not optional
      Logical types: decimal, uuid, date, time, timestamp, duration
      Object container files, null and deflate codecs

  THE INDEPENDENT REFERENCE is the specification's own worked example. The
  schema is a record named "test" with a long field a and a string field b;
  the value is a = 27 and b = "foo"; and the specification prints the bytes

      36 06 66 6f 6f

  (The schema is written out in full in TestSpecExample below rather than
  here, because a brace comment ends at the first closing brace and JSON is
  made of them.)

  plus the varint table the specification prints: 0 is 00, -1 is 01, 1 is
  02, -2 is 03, 2 is 04, -64 is 7f and 64 is 80 01.

  There is no network and no Apache Avro installed on this machine, so the
  oracle is the document rather than a running program - said plainly rather
  than dressed up. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Math, System.DateUtils,
  System.StrUtils, System.Generics.Collections, Data.DB, Datasnap.DBClient,
  AvroModels in 'AvroModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Avro.Schema in '..\..\src\PascalForge.Avro.Schema.pas',
  PascalForge.Avro in '..\..\src\PascalForge.Avro.pas',
  PascalForge.Avro.Internal in '..\..\src\PascalForge.Avro.Internal.pas',
  PascalForge.Avro.Registration in '..\..\src\PascalForge.Avro.Registration.pas',
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

{ One long, encoded, so that the specification's varint table can be
  checked a line at a time. }
function LongBytes(AValue: Int64): string;
var
  Schema: TAvroSchema;
  V: TAvroValue;
begin
  Schema := TAvroSchema.Parse('"long"');
  try
    V := TAvroValue.NewLong(AValue);
    try
      Result := Hex(TAvroSerializer.Encode(Schema, V));
    finally
      V.Free;
    end;
  finally
    Schema.Free;
  end;
end;

{ ===========================================================================
  THE BINARY ENCODING
  =========================================================================== }

procedure TestVarints;
begin
  Writeln;
  Writeln('--- zig-zag varints ---');

  { The specification's own table. Zig-zag is what makes a small NEGATIVE
    number as short as a small positive one, and getting the direction
    backwards produces bytes that still decode - as the wrong number. }
  Check(LongBytes(0) = '00', 'VARINT_ZERO');
  Check(LongBytes(-1) = '01', 'VARINT_MINUS_ONE');
  Check(LongBytes(1) = '02', 'VARINT_ONE');
  Check(LongBytes(-2) = '03', 'VARINT_MINUS_TWO');
  Check(LongBytes(2) = '04', 'VARINT_TWO');
  Check(LongBytes(-64) = '7f', 'VARINT_MINUS_SIXTY_FOUR');
  Check(LongBytes(64) = '8001', 'VARINT_SIXTY_FOUR');

  { And the far ends, where a logical shift instead of an arithmetic one
    shows up. }
  Check(LongBytes(High(Int64)) = 'feffffffffffffffff01', 'VARINT_MAX_INT64');
  Check(LongBytes(Low(Int64)) = 'ffffffffffffffffff01', 'VARINT_MIN_INT64');
end;

procedure TestSpecExample;
const
  SchemaJson =
    '{"type":"record","name":"test","fields":[' +
    '{"name":"a","type":"long"},{"name":"b","type":"string"}]}';
var
  Schema: TAvroSchema;
  V, Back: TAvroValue;
  Data: TBytes;
begin
  Writeln;
  Writeln('--- the specification''s worked example ---');

  Schema := TAvroSchema.Parse(SchemaJson);
  try
    Check(Schema.SchemaType = TAvroType.Rec, 'SPEC_SCHEMA_PARSED');
    Check((Schema.FieldCount = 2) and (Schema.Fields[0].Name = 'a') and
          (Schema.Fields[1].FieldType.SchemaType = TAvroType.Str),
      'SPEC_SCHEMA_FIELDS');

    V := TAvroValue.NewRecord;
    try
      V.Add('a', TAvroValue.NewLong(27));
      V.Add('b', TAvroValue.NewStr('foo'));
      Data := TAvroSerializer.Encode(Schema, V);
    finally
      V.Free;
    end;
    Note('encoded: ' + Hex(Data));
    { The specification prints these five bytes. A codec that agreed only
      with itself would round-trip and still be wrong. }
    Check(Hex(Data) = '3606666f6f', 'AVRO_INDEPENDENT_INTEROP');

    Back := TAvroSerializer.Decode(Data, Schema);
    try
      Check((Back.Find('a').AsInt = 27) and (Back.Find('b').AsStr = 'foo'),
        'SPEC_DECODES');
    finally
      Back.Free;
    end;
  finally
    Schema.Free;
  end;
end;

procedure TestEveryType;
var
  Schema: TAvroSchema;
  V, Back: TAvroValue;
  Data: TBytes;
begin
  Writeln;
  Writeln('--- every type the specification defines ---');

  { null is ZERO bytes, which is the encoding a naive implementation gets
    wrong by writing a marker nobody reads. }
  Schema := TAvroSchema.Parse('"null"');
  try
    V := TAvroValue.NewNull;
    try
      Check(Length(TAvroSerializer.Encode(Schema, V)) = 0, 'TYPE_NULL_IS_EMPTY');
    finally V.Free; end;
  finally Schema.Free; end;

  Schema := TAvroSchema.Parse('"boolean"');
  try
    V := TAvroValue.NewBool(True);
    try
      Check(Hex(TAvroSerializer.Encode(Schema, V)) = '01', 'TYPE_BOOLEAN');
    finally V.Free; end;
  finally Schema.Free; end;

  Schema := TAvroSchema.Parse('"float"');
  try
    V := TAvroValue.NewFloat(1.0);
    try
      { Four bytes, little-endian IEEE 754 - 1.0 is 0x3F800000. }
      Check(Hex(TAvroSerializer.Encode(Schema, V)) = '0000803f', 'TYPE_FLOAT');
    finally V.Free; end;
  finally Schema.Free; end;

  Schema := TAvroSchema.Parse('"double"');
  try
    V := TAvroValue.NewDouble(1.0);
    try
      Check(Hex(TAvroSerializer.Encode(Schema, V)) = '000000000000f03f',
        'TYPE_DOUBLE');
    finally V.Free; end;
  finally Schema.Free; end;

  Schema := TAvroSchema.Parse('"bytes"');
  try
    V := TAvroValue.NewBytes(TBytes.Create(1, 2, 3));
    try
      Check(Hex(TAvroSerializer.Encode(Schema, V)) = '06010203', 'TYPE_BYTES');
    finally V.Free; end;
  finally Schema.Free; end;

  { An array is BLOCKS: a count, the items, and a zero-length block that
    says it has ended. A writer that forgot the terminator produces a file
    that reads one item too few or runs off the end. }
  Schema := TAvroSchema.Parse('{"type":"array","items":"long"}');
  try
    V := TAvroValue.NewArray;
    try
      V.Add(TAvroValue.NewLong(1));
      V.Add(TAvroValue.NewLong(2));
      Data := TAvroSerializer.Encode(Schema, V);
      Check(Hex(Data) = '04020400', 'TYPE_ARRAY_BLOCKS');
    finally V.Free; end;
    V := TAvroValue.NewArray;
    try
      Check(Hex(TAvroSerializer.Encode(Schema, V)) = '00',
        'TYPE_EMPTY_ARRAY_IS_ONE_ZERO');
    finally V.Free; end;
    Back := TAvroSerializer.Decode(FromHex('04020400'), Schema);
    try
      Check((Back.Count = 2) and (Back.Items[1].AsInt = 2), 'TYPE_ARRAY_READ');
    finally Back.Free; end;
  finally Schema.Free; end;

  Schema := TAvroSchema.Parse('{"type":"map","values":"long"}');
  try
    V := TAvroValue.NewMap;
    try
      V.Add('a', TAvroValue.NewLong(1));
      Data := TAvroSerializer.Encode(Schema, V);
      Check(Hex(Data) = '020261020' + '0', 'TYPE_MAP_BLOCKS');
    finally V.Free; end;
  finally Schema.Free; end;

  { A union writes the INDEX of its branch, which is why choosing the branch
    is part of the encoding and not a convenience. }
  Schema := TAvroSchema.Parse('["null","string"]');
  try
    V := TAvroValue.NewNull;
    try
      Check(Hex(TAvroSerializer.Encode(Schema, V)) = '00', 'TYPE_UNION_NULL');
    finally V.Free; end;
    V := TAvroValue.NewStr('a');
    try
      Check(Hex(TAvroSerializer.Encode(Schema, V)) = '020261',
        'TYPE_UNION_SECOND_BRANCH');
    finally V.Free; end;
  finally Schema.Free; end;

  Schema := TAvroSchema.Parse(
    '{"type":"enum","name":"Suit","symbols":["SPADES","HEARTS"]}');
  try
    V := TAvroValue.NewEnum('HEARTS');
    try
      Check(Hex(TAvroSerializer.Encode(Schema, V)) = '02',
        'TYPE_ENUM_IS_AN_INDEX');
    finally V.Free; end;
  finally Schema.Free; end;

  { A fixed has NO length prefix: the schema's size is the only thing that
    says how many bytes to read. }
  Schema := TAvroSchema.Parse('{"type":"fixed","name":"F","size":3}');
  try
    V := TAvroValue.NewFixed(TBytes.Create(1, 2, 3));
    try
      Check(Hex(TAvroSerializer.Encode(Schema, V)) = '010203',
        'TYPE_FIXED_HAS_NO_LENGTH');
    finally V.Free; end;
    V := TAvroValue.NewFixed(TBytes.Create(1, 2));
    try
      try
        TAvroSerializer.Encode(Schema, V);
        Check(False, 'TYPE_FIXED_WRONG_SIZE_REFUSED');
      except
        on E: EAvroInputError do
        begin
          Dec(GChecks);
          Check(True, 'TYPE_FIXED_WRONG_SIZE_REFUSED');
        end;
      end;
    finally V.Free; end;
  finally Schema.Free; end;
end;

{ ===========================================================================
  SCHEMA RESOLUTION - the part that is not optional
  =========================================================================== }

procedure TestResolution;
var
  Writer, Reader: TAvroSchema;
  V, Back: TAvroValue;
  Data: TBytes;
  Caught: Boolean;
begin
  Writeln;
  Writeln('--- schema resolution ---');

  { A FIELD ADDED to the reader's schema. Without the default, every file
    written before the field existed becomes unreadable. }
  Writer := TAvroSchema.Parse(
    '{"type":"record","name":"R","fields":[{"name":"a","type":"long"}]}');
  Reader := TAvroSchema.Parse(
    '{"type":"record","name":"R","fields":[' +
    '{"name":"a","type":"long"},' +
    '{"name":"b","type":"string","default":"unset"}]}');
  try
    V := TAvroValue.NewRecord;
    try
      V.Add('a', TAvroValue.NewLong(7));
      Data := TAvroSerializer.Encode(Writer, V);
    finally V.Free; end;
    Back := TAvroSerializer.Decode(Data, Writer, Reader);
    try
      Check(Back.Find('a').AsInt = 7, 'RESOLVE_ADDED_FIELD_KEEPS_THE_OLD');
      Check((Back.Find('b') <> nil) and (Back.Find('b').AsStr = 'unset'),
        'RESOLVE_ADDED_FIELD_USES_THE_DEFAULT');
    finally Back.Free; end;
  finally
    Writer.Free;
    Reader.Free;
  end;

  { A FIELD REMOVED from the reader's schema. The bytes still have to be
    read past, or everything after them is at the wrong offset - which is
    the single most common way a hand-written Avro reader is wrong. }
  Writer := TAvroSchema.Parse(
    '{"type":"record","name":"R","fields":[' +
    '{"name":"a","type":"long"},{"name":"gone","type":"string"},' +
    '{"name":"c","type":"long"}]}');
  Reader := TAvroSchema.Parse(
    '{"type":"record","name":"R","fields":[' +
    '{"name":"a","type":"long"},{"name":"c","type":"long"}]}');
  try
    V := TAvroValue.NewRecord;
    try
      V.Add('a', TAvroValue.NewLong(1));
      V.Add('gone', TAvroValue.NewStr('a long string that has to be skipped'));
      V.Add('c', TAvroValue.NewLong(99));
      Data := TAvroSerializer.Encode(Writer, V);
    finally V.Free; end;
    Back := TAvroSerializer.Decode(Data, Writer, Reader);
    try
      Check(Back.Find('gone') = nil, 'RESOLVE_REMOVED_FIELD_IS_DROPPED');
      Check(Back.Find('c').AsInt = 99,
        'RESOLVE_REMOVED_FIELD_IS_READ_PAST_CORRECTLY');
    finally Back.Free; end;
  finally
    Writer.Free;
    Reader.Free;
  end;

  { A FIELD RENAMED, matched by the reader's alias. }
  Writer := TAvroSchema.Parse(
    '{"type":"record","name":"R","fields":[{"name":"old","type":"long"}]}');
  Reader := TAvroSchema.Parse(
    '{"type":"record","name":"R","fields":[' +
    '{"name":"new","type":"long","aliases":["old"]}]}');
  try
    V := TAvroValue.NewRecord;
    try
      V.Add('old', TAvroValue.NewLong(5));
      Data := TAvroSerializer.Encode(Writer, V);
    finally V.Free; end;
    Back := TAvroSerializer.Decode(Data, Writer, Reader);
    try
      Check((Back.Find('new') <> nil) and (Back.Find('new').AsInt = 5),
        'RESOLVE_FIELD_ALIAS');
    finally Back.Free; end;
  finally
    Writer.Free;
    Reader.Free;
  end;

  { The promotions the specification lists, and only those: int to long,
    float or double; long to float or double; float to double. }
  Writer := TAvroSchema.Parse('"int"');
  Reader := TAvroSchema.Parse('"long"');
  try
    V := TAvroValue.NewInt(300);
    try
      Data := TAvroSerializer.Encode(Writer, V);
    finally V.Free; end;
    Back := TAvroSerializer.Decode(Data, Writer, Reader);
    try
      Check(Back.AsInt = 300, 'RESOLVE_INT_TO_LONG');
    finally Back.Free; end;
  finally
    Writer.Free;
    Reader.Free;
  end;

  Writer := TAvroSchema.Parse('"int"');
  Reader := TAvroSchema.Parse('"double"');
  try
    V := TAvroValue.NewInt(7);
    try
      Data := TAvroSerializer.Encode(Writer, V);
    finally V.Free; end;
    Back := TAvroSerializer.Decode(Data, Writer, Reader);
    try
      Check((Back.Kind = TAvroKind.Double) and (Back.AsFloat = 7.0),
        'RESOLVE_INT_TO_DOUBLE');
    finally Back.Free; end;
  finally
    Writer.Free;
    Reader.Free;
  end;

  { And a promotion the specification does NOT allow. Refusing is the
    point: reading a double as an int would be a number, just not the one
    that was written. }
  Writer := TAvroSchema.Parse('"double"');
  Reader := TAvroSchema.Parse('"int"');
  Caught := False;
  try
    V := TAvroValue.NewDouble(1.5);
    try
      Data := TAvroSerializer.Encode(Writer, V);
    finally V.Free; end;
    try
      Back := TAvroSerializer.Decode(Data, Writer, Reader);
      Back.Free;
    except
      on E: EAvroResolutionError do Caught := True;
    end;
  finally
    Writer.Free;
    Reader.Free;
  end;
  Check(Caught, 'RESOLVE_REFUSES_A_NARROWING');

  { An enum symbol the reader has never heard of: its own default, or an
    error. }
  Writer := TAvroSchema.Parse(
    '{"type":"enum","name":"E","symbols":["A","B","C"]}');
  Reader := TAvroSchema.Parse(
    '{"type":"enum","name":"E","symbols":["A","B"],"default":"A"}');
  try
    V := TAvroValue.NewEnum('C');
    try
      Data := TAvroSerializer.Encode(Writer, V);
    finally V.Free; end;
    Back := TAvroSerializer.Decode(Data, Writer, Reader);
    try
      Check(Back.AsStr = 'A', 'RESOLVE_UNKNOWN_ENUM_USES_THE_DEFAULT');
    finally Back.Free; end;
  finally
    Writer.Free;
    Reader.Free;
  end;

  Writer := TAvroSchema.Parse(
    '{"type":"enum","name":"E","symbols":["A","B","C"]}');
  Reader := TAvroSchema.Parse('{"type":"enum","name":"E","symbols":["A","B"]}');
  Caught := False;
  try
    V := TAvroValue.NewEnum('C');
    try
      Data := TAvroSerializer.Encode(Writer, V);
    finally V.Free; end;
    try
      Back := TAvroSerializer.Decode(Data, Writer, Reader);
      Back.Free;
    except
      on E: EAvroResolutionError do Caught := True;
    end;
  finally
    Writer.Free;
    Reader.Free;
  end;
  Check(Caught, 'RESOLVE_UNKNOWN_ENUM_WITHOUT_A_DEFAULT_REFUSED');

  { A field the reader wants that the writer never wrote AND that has no
    default: there is nothing in the bytes and nothing to put there. }
  Writer := TAvroSchema.Parse(
    '{"type":"record","name":"R","fields":[{"name":"a","type":"long"}]}');
  Reader := TAvroSchema.Parse(
    '{"type":"record","name":"R","fields":[' +
    '{"name":"a","type":"long"},{"name":"b","type":"string"}]}');
  Caught := False;
  try
    V := TAvroValue.NewRecord;
    try
      V.Add('a', TAvroValue.NewLong(1));
      Data := TAvroSerializer.Encode(Writer, V);
    finally V.Free; end;
    try
      Back := TAvroSerializer.Decode(Data, Writer, Reader);
      Back.Free;
    except
      on E: EAvroResolutionError do Caught := True;
    end;
  finally
    Writer.Free;
    Reader.Free;
  end;
  Check(Caught, 'RESOLVE_MISSING_FIELD_WITHOUT_A_DEFAULT_REFUSED');
end;

{ ===========================================================================
  LOGICAL TYPES
  =========================================================================== }

procedure TestLogicalTypes;
var
  Schema: TAvroSchema;
  V, Back: TAvroValue;
  Data: TBytes;
  DT: TDateTime;
begin
  Writeln;
  Writeln('--- logical types ---');

  { A decimal travels as a two's-complement big-endian unscaled integer,
    which is what makes it EXACT. A format that put it through a double
    would lose it at the fifteenth digit, silently, and this is money. }
  Schema := TAvroSchema.Parse(
    '{"type":"bytes","logicalType":"decimal","precision":10,"scale":2}');
  try
    Check(Schema.LogicalType = TAvroLogicalType.Decimal,
      'LOGICAL_DECIMAL_PARSED');
    Check((Schema.Precision = 10) and (Schema.Scale = 2),
      'LOGICAL_DECIMAL_PRECISION_AND_SCALE');

    V := TAvroValue.NewDecimal('123.45');
    try
      Data := TAvroSerializer.Encode(Schema, V);
    finally V.Free; end;
    { 123.45 at scale 2 is the unscaled integer 12345, which is 0x3039. }
    Check(Hex(Data) = '043039', 'LOGICAL_DECIMAL_UNSCALED_BYTES');

    Back := TAvroSerializer.Decode(Data, Schema);
    try
      Check(Back.AsDecimal = '123.45', 'LOGICAL_DECIMAL_EXACT');
    finally Back.Free; end;

    { A negative one, where two's complement is the whole point. }
    V := TAvroValue.NewDecimal('-1.00');
    try
      Data := TAvroSerializer.Encode(Schema, V);
    finally V.Free; end;
    Back := TAvroSerializer.Decode(Data, Schema);
    try
      { Scale 2 means two places, so -1 comes back written to two places:
        the schema says how many, and dropping them would be a different
        number to a consumer that cares. }
      Check(Back.AsDecimal = '-1.00', 'LOGICAL_DECIMAL_NEGATIVE');
    finally Back.Free; end;

    { And a value with MORE places than the scale, which cannot be written
      without dropping a digit - so it is refused rather than rounded. }
    V := TAvroValue.NewDecimal('1.234');
    try
      try
        TAvroSerializer.Encode(Schema, V);
        Check(False, 'LOGICAL_DECIMAL_REFUSES_TO_ROUND');
      except
        on E: EAvroInputError do
        begin
          Dec(GChecks);
          Check(True, 'LOGICAL_DECIMAL_REFUSES_TO_ROUND');
        end;
      end;
    finally V.Free; end;

    { A value far beyond what a Double can hold exactly still comes back
      exactly, which is the whole reason decimal exists. }
    V := TAvroValue.NewDecimal('99999999.99');
    try
      Data := TAvroSerializer.Encode(Schema, V);
    finally V.Free; end;
    Back := TAvroSerializer.Decode(Data, Schema);
    try
      Check(Back.AsDecimal = '99999999.99',
        'AVRO_DECIMAL_DOES_NOT_GO_THROUGH_A_DOUBLE');
    finally Back.Free; end;
  finally
    Schema.Free;
  end;

  { timestamp-millis: a long, milliseconds since the Unix epoch. }
  Schema := TAvroSchema.Parse(
    '{"type":"long","logicalType":"timestamp-millis"}');
  try
    DT := EncodeDateTime(2026, 9, 19, 14, 30, 45, 250);
    V := TAvroValue.NewDateTime(DT);
    try
      Data := TAvroSerializer.Encode(Schema, V);
    finally V.Free; end;
    Back := TAvroSerializer.Decode(Data, Schema);
    try
      Check(MilliSecondsBetween(Back.AsDateTime, DT) = 0,
        'LOGICAL_TIMESTAMP_MILLIS');
    finally Back.Free; end;
  finally
    Schema.Free;
  end;

  { date: an int, days since 1970-01-01. }
  Schema := TAvroSchema.Parse('{"type":"int","logicalType":"date"}');
  try
    V := TAvroValue.NewDateTime(EncodeDate(1970, 1, 2));
    try
      Check(Hex(TAvroSerializer.Encode(Schema, V)) = '02',
        'LOGICAL_DATE_IS_DAYS_SINCE_THE_EPOCH');
    finally V.Free; end;
  finally
    Schema.Free;
  end;

  { uuid: a string, and the annotation is kept even though the bytes are a
    plain string - a reader that knows the logical type gets a UUID. }
  Schema := TAvroSchema.Parse('{"type":"string","logicalType":"uuid"}');
  try
    Check(Schema.LogicalType = TAvroLogicalType.Uuid, 'LOGICAL_UUID_PARSED');
  finally
    Schema.Free;
  end;

  { duration: months, days and milliseconds - three numbers, not one, which
    is why it is its own kind rather than an interval in some unit. }
  Schema := TAvroSchema.Parse(
    '{"type":"fixed","name":"D","size":12,"logicalType":"duration"}');
  try
    V := TAvroValue.NewDuration(1, 2, 3);
    try
      Data := TAvroSerializer.Encode(Schema, V);
    finally V.Free; end;
    Check(Length(Data) = 12, 'LOGICAL_DURATION_IS_TWELVE_BYTES');
    Back := TAvroSerializer.Decode(Data, Schema);
    try
      Check((Back.DurationMonths = 1) and (Back.DurationDays = 2) and
            (Back.DurationMillis = 3), 'LOGICAL_DURATION_ROUND_TRIP');
    finally Back.Free; end;
  finally
    Schema.Free;
  end;

  { An annotation this version does not implement is KEPT as written rather
    than dropped, because a reader that does know it still can. }
  Schema := TAvroSchema.Parse(
    '{"type":"string","logicalType":"something-new"}');
  try
    Check(Schema.LogicalName = 'something-new',
      'LOGICAL_UNKNOWN_ANNOTATION_IS_KEPT');
    Check(Schema.LogicalType = TAvroLogicalType.Unknown,
      'LOGICAL_UNKNOWN_IS_NAMED_UNKNOWN');
  finally
    Schema.Free;
  end;
end;

{ ===========================================================================
  CONTAINER FILES
  =========================================================================== }

procedure TestContainer;
var
  Schema: TAvroSchema;
  Values: TArray<TAvroValue>;
  Data: TBytes;
  Back: TObjectList<TAvroValue>;
  Json: string;
  I: Integer;
begin
  Writeln;
  Writeln('--- object container files ---');

  Schema := TAvroSchema.Parse(
    '{"type":"record","name":"R","fields":[{"name":"n","type":"long"}]}');
  try
    SetLength(Values, 3);
    for I := 0 to 2 do
    begin
      Values[I] := TAvroValue.NewRecord;
      Values[I].Add('n', TAvroValue.NewLong(I + 1));
    end;
    try
      Data := TAvroSerializer.WriteContainer(Schema, Values);
    finally
      for I := 0 to 2 do Values[I].Free;
    end;

    { The magic is "Obj" followed by version 1 - the only thing that says
      this is a container file rather than a bare datum. }
    Check((Data[0] = Ord('O')) and (Data[1] = Ord('b')) and
          (Data[2] = Ord('j')) and (Data[3] = 1), 'CONTAINER_MAGIC');

    Back := TAvroSerializer.ReadContainer(Data, Json);
    try
      Check(Back.Count = 3, 'CONTAINER_DATUM_COUNT');
      Check(Back[2].Find('n').AsInt = 3, 'CONTAINER_DATUM_CONTENT');
      { The schema travels in the header, which is what makes a container
        file readable without anybody sending the schema separately - and
        it is the only Avro artefact that does. }
      Check(Pos('"name":"R"', Json) > 0, 'AVRO_CONTAINER_CARRIES_ITS_SCHEMA');
    finally
      Back.Free;
    end;

    { Deflate, which the specification names alongside null. }
    SetLength(Values, 1);
    Values[0] := TAvroValue.NewRecord;
    Values[0].Add('n', TAvroValue.NewLong(42));
    try
      Data := TAvroSerializer.WriteContainer(Schema, Values,
        TAvroCodec.Deflate);
    finally
      Values[0].Free;
    end;
    Back := TAvroSerializer.ReadContainer(Data, Json);
    try
      Check((Back.Count = 1) and (Back[0].Find('n').AsInt = 42),
        'CONTAINER_DEFLATE_CODEC');
    finally
      Back.Free;
    end;
  finally
    Schema.Free;
  end;
end;

{ ===========================================================================
  THE DELPHI CONTRACT
  =========================================================================== }

procedure TestContract;
var
  Shipment, Back: TShipment;
  Json: string;
  Data: TBytes;
  Spec, SpecBack: TSpecExample;
  Scripts, ScriptsBack: TScripts;
  Schema: TAvroSchema;
  Many, ManyBack: TArray<TShipment>;
  I: Integer;
begin
  Writeln;
  Writeln('--- the Delphi contract ---');

  { The schema a Delphi type generates is produced as JSON and PARSED, so
    it is checked by exactly the same rules as one that arrived from
    somebody else. }
  Json := TAvroSerializer.SchemaJsonFor<TShipment>;
  Note(Copy(Json, 1, 160));
  Schema := TAvroSchema.Parse(Json);
  try
    Check(Schema.SchemaType = TAvroType.Rec, 'CONTRACT_SCHEMA_IS_A_RECORD');
    Check(Schema.FindField('Scratch') = nil, 'CONTRACT_IGNORE_HONOURED');
    Check(Schema.FindField('note') <> nil, 'CONTRACT_NAME_HONOURED');
    { A Currency is an exact decimal with four places, and the schema says
      so - which is what keeps it exact through the bytes. }
    Check(Schema.FindField('Amount').FieldType.LogicalType =
      TAvroLogicalType.Decimal, 'CONTRACT_CURRENCY_IS_A_DECIMAL');
    Check(Schema.FindField('Raised').FieldType.LogicalType =
      TAvroLogicalType.TimestampMillis, 'CONTRACT_DATETIME_IS_A_TIMESTAMP');
    Check(Schema.FindField('Id').FieldType.LogicalType =
      TAvroLogicalType.Uuid, 'CONTRACT_GUID_IS_A_UUID');
    { A nullable is a union with NULL FIRST, because a union's default is a
      value of its first branch. }
    Check((Schema.FindField('Approved').FieldType.SchemaType = TAvroType.Union) and
          (Schema.FindField('Approved').FieldType.Branches[0].SchemaType =
            TAvroType.Null), 'CONTRACT_NULLABLE_IS_A_NULL_FIRST_UNION');
    Check(Schema.FindField('Tags').FieldType.SchemaType = TAvroType.Arr,
      'CONTRACT_DYNAMIC_ARRAY_IS_AN_ARRAY');
    Check(Schema.FindField('Shipper').FieldType.SchemaType = TAvroType.Rec,
      'CONTRACT_NESTED_RECORD');
  finally
    Schema.Free;
  end;

  Shipment := TShipment.Create;
  try
    Shipment.Reference := 'PF-2026-0001';
    Shipment.Count := 42;
    Shipment.Ticks := 9007199254740993;
    Shipment.Rate := 0.0725;
    Shipment.Ratio := 0.5;
    Shipment.Paid := True;
    Shipment.Amount := 1234.5600;
    Shipment.Raised := EncodeDateTime(2026, 9, 19, 14, 30, 0, 0);
    Shipment.Id := StringToGUID('{3F2504E0-4F89-41D3-9A0C-0305E82C3301}');
    Shipment.Receipt := TBytes.Create(1, 2, 3, 250);
    Shipment.Delivery := TDelivery.NextDay;
    Shipment.Tags := ['urgent', 'reviewed'];
    Shipment.Shipper.Street := 'Example Avenue 7';
    Shipment.Shipper.City := 'Midtown';
    Shipment.Scratch := 'must not appear';
    Shipment.Remark := 'thank you';
    Shipment.Approved := True;

    Data := TAvroSerializer.Serialize<TShipment>(Shipment);
    Note(Format('%d bytes', [Length(Data)]));

    Back := TAvroSerializer.Deserialize<TShipment>(Data);
    try
      Check(Back.Reference = Shipment.Reference, 'CONTRACT_STRING');
      Check(Back.Count = Shipment.Count, 'CONTRACT_INTEGER');
      Check(Back.Ticks = Shipment.Ticks, 'CONTRACT_INT64_BEYOND_DOUBLE');
      Check(Back.Rate = Shipment.Rate, 'CONTRACT_DOUBLE');
      Check(Back.Ratio = Shipment.Ratio, 'CONTRACT_SINGLE');
      Check(Back.Paid, 'CONTRACT_BOOLEAN');
      Check(Back.Amount = Shipment.Amount, 'CONTRACT_CURRENCY_EXACT');
      Check(SecondsBetween(Back.Raised, Shipment.Raised) = 0,
        'CONTRACT_DATETIME');
      Check(IsEqualGUID(Back.Id, Shipment.Id), 'CONTRACT_GUID');
      Check(Hex(Back.Receipt) = Hex(Shipment.Receipt), 'CONTRACT_BYTES');
      Check(Back.Delivery = TDelivery.NextDay, 'CONTRACT_ENUM');
      Check((Length(Back.Tags) = 2) and (Back.Tags[1] = 'reviewed'),
        'CONTRACT_DYNAMIC_ARRAY');
      Check(Back.Shipper.City = 'Midtown', 'CONTRACT_NESTED_RECORD_VALUE');
      Check(Back.Scratch = '', 'CONTRACT_IGNORED_NOT_READ');
      Check(Back.Remark = 'thank you', 'CONTRACT_RENAMED_READ');
      Check(Back.Approved.HasValue and Back.Approved.Value,
        'CONTRACT_NULLABLE_PRESENT');
    finally
      Back.Free;
    end;
  finally
    Shipment.Free;
  end;

  { The specification's own record shape, through the contract path, against
    the bytes the specification prints. }
  Spec.a := 27;
  Spec.b := 'foo';
  Data := TAvroSerializer.Serialize<TSpecExample>(Spec);
  Check(Hex(Data) = '3606666f6f', 'CONTRACT_MATCHES_THE_SPEC_BYTES');
  SpecBack := TAvroSerializer.Deserialize<TSpecExample>(Data);
  Check((SpecBack.a = 27) and (SpecBack.b = 'foo'), 'CONTRACT_SPEC_ROUND_TRIP');

  { A container file of Delphi values. }
  SetLength(Many, 2);
  Many[0] := TShipment.Create;
  Many[1] := TShipment.Create;
  try
    Many[0].Reference := 'one';
    Many[1].Reference := 'two';
    Data := TAvroSerializer.WriteContainer<TShipment>(Many);
    ManyBack := TAvroSerializer.ReadContainer<TShipment>(Data);
    try
      Check(Length(ManyBack) = 2, 'CONTRACT_CONTAINER_COUNT');
      Check(ManyBack[1].Reference = 'two', 'CONTRACT_CONTAINER_CONTENT');
    finally
      for I := 0 to High(ManyBack) do ManyBack[I].Free;
    end;
  finally
    Many[0].Free;
    Many[1].Free;
  end;

  Scripts := TScripts.Create;
  try
    { Spelled in code points so that the source file stays ASCII. }
    Scripts.Georgian := #$10E5#$10D0#$10E0#$10D7#$10E3#$10DA#$10D8' ' +
                        #$10D4#$10DC#$10D0;
    Scripts.Cyrillic := #$0420#$0443#$0441#$0441#$043A#$0438#$0439' ' +
                        #$044F#$0437#$044B#$043A;
    Scripts.Cjk := #$65E5#$672C#$8A9E#$306E#$30C6#$30AD#$30B9#$30C8;
    Scripts.Emoji := #$D83D#$DC68#$200D#$D83D#$DC69#$200D +
                     #$D83D#$DC67#$200D#$D83D#$DC66' family';
    Scripts.Combining := 'e' + #$0301 + 'cole';

    Data := TAvroSerializer.Serialize<TScripts>(Scripts);
    ScriptsBack := TAvroSerializer.Deserialize<TScripts>(Data);
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
  THE REGISTRY - and the one format here that needs a schema to be
  structural at all
  =========================================================================== }

procedure TestConversionMatrix;
const
  SchemaJson =
    '{"type":"record","name":"Row","fields":[' +
    '{"name":"id","type":"long"},{"name":"name","type":"string"},' +
    '{"name":"active","type":"boolean"}]}';
  Source = '{"id":1,"name":"Alice","active":true}';
var
  Schema: TAvroSchema;
  Options: TStructuralConversionOptions;
  Payload, Hop: TSerializationPayload;
  Back: string;
  Caught: Boolean;
  Formats: TArray<TSerializationFormat>;
  F: TSerializationFormat;
  Supported, Refused: Integer;
begin
  Writeln;
  Writeln('--- conversion ---');

  Check(TSerialization.IsRegistered(TSerializationFormat.Avro),
    'AVRO_REGISTERED');

  { Avro is the one format here whose bytes mean nothing on their own, and
    the registry says so rather than pretending. }
  Check(TSerialization.StructuralRequirement(TSerializationFormat.Avro) =
    'schema', 'AVRO_STRUCTURAL_REQUIRES_A_SCHEMA');

  Caught := False;
  try
    TSerialization.Convert(TSerializationPayload.FromText(Source),
      TSerializationFormat.Json, TSerializationFormat.Avro,
      TStructuralConversionProfile.Lossless);
  except
    on E: Exception do
      Caught := (E is ESerializationSchemaRequired) or
                (E is ESerializationFormatCapability);
  end;
  Check(Caught, 'AVRO_WITHOUT_A_SCHEMA_IS_REFUSED_BY_NAME');

  Schema := TAvroSchema.Parse(SchemaJson);
  try
    Options := TStructuralConversionOptions.FromProfile(
      TStructuralConversionProfile.Lossless).WithContext(Schema);

    Payload := TSerialization.Convert(TSerializationPayload.FromText(Source),
      TSerializationFormat.Json, TSerializationFormat.Avro, Options);
    Note('avro: ' + Hex(Payload.AsBytes));
    Check(Length(Payload.AsBytes) > 0, 'AVRO_FROM_JSON_WITH_A_SCHEMA');

    Back := TSerialization.Convert(Payload, TSerializationFormat.Avro,
      TSerializationFormat.Json, Options).AsText;
    Note(Back);
    Check(Pos('"name":"Alice"', Back) > 0, 'AVRO_TO_JSON_WITH_A_SCHEMA');

    { The whole matrix, with the schema supplied at both ends. }
    Formats := TSerialization.StructuralFormats(Options);
    Supported := 0;
    Refused := 0;
    for F in Formats do
    begin
      if F = TSerializationFormat.Avro then Continue;
      try
        Hop := TSerialization.Convert(Payload, TSerializationFormat.Avro, F,
          Options);
        Hop := TSerialization.Convert(Hop, F, TSerializationFormat.Avro,
          Options);
        Inc(Supported);
        Note(Format('  avro -> %s -> avro: supported with schema context',
          [TSerialization.FormatName(F)]));
      except
        on E: Exception do
        begin
          Inc(Refused);
          Note(Format('  avro -> %s: %s', [TSerialization.FormatName(F),
            E.ClassName]));
        end;
      end;
    end;
    Note(Format('supported=%d refused=%d', [Supported, Refused]));
    Check(Supported + Refused = Length(Formats) - 1,
      'AVRO_CONVERSION_MATRIX');
    Check(Supported > 0, 'AVRO_CONVERTS_WITH_SCHEMA_CONTEXT');
  finally
    Schema.Free;
  end;
end;

procedure TestDataSet;
const
  SchemaJson =
    '{"type":"array","items":{"type":"record","name":"Row","fields":[' +
    '{"name":"reference","type":"string"},{"name":"count","type":"long"},' +
    '{"name":"paid","type":"boolean"}]}}';
var
  Schema: TAvroSchema;
  Options: TStructuralConversionOptions;
  Payload: TSerializationPayload;
  DS: TClientDataSet;
begin
  Writeln;
  Writeln('--- DataSet projection ---');

  Schema := TAvroSchema.Parse(SchemaJson);
  try
    Options := TStructuralConversionOptions.FromProfile(
      TStructuralConversionProfile.Lossless).WithContext(Schema);
    Payload := TSerialization.Convert(TSerializationPayload.FromText(
      '[{"reference":"PF-1","count":42,"paid":true},' +
      '{"reference":"PF-2","count":7,"paid":false}]'),
      TSerializationFormat.Json, TSerializationFormat.Avro, Options);

    DS := TDataSetSerializer.CreateClientDataSet(Payload,
      TSerializationFormat.Avro, Schema);
    try
      Check(DS.RecordCount = 2, 'DATASET_ROWS');
      Check(DS.FieldCount = 3, 'DATASET_COLUMNS');
      { Avro states its own types through the schema, so inference is not
        guessing here: a long is a long because the schema said so. }
      Check(DS.FieldByName('count').DataType in [ftInteger, ftLargeint],
        'DATASET_INTEGER_FROM_SCHEMA');
      Check(DS.FieldByName('paid').DataType = ftBoolean, 'DATASET_BOOLEAN');
      DS.First;
      Check(DS.FieldByName('reference').AsString = 'PF-1', 'DATASET_FIRST_ROW');
      DS.Next;
      Check(DS.FieldByName('count').AsInteger = 7,
        'AVRO_DATASET_WITH_SCHEMA');
    finally
      DS.Free;
    end;
  finally
    Schema.Free;
  end;
end;

{ ===========================================================================
  AVRO SCHEMA A TO AVRO SCHEMA B

  Both ends are Avro, so format identity says nothing about which schema
  belongs where. This is the conversion the old Schema/SecondSchema pair
  could not express at all, and it is not an exotic one: schema evolution is
  the reason Avro exists.

  Schema B adds a field with a default and drops one that A had. Reading A's
  bytes and writing B's is exactly what a producer upgrading a topic does.
  =========================================================================== }

procedure TestSchemaAToSchemaB;
const
  SchemaA =
    '{"type":"record","name":"Row","fields":[' +
    '{"name":"id","type":"long"},{"name":"name","type":"string"},' +
    '{"name":"legacy","type":"string"}]}';
  SchemaB =
    '{"type":"record","name":"Row","fields":[' +
    '{"name":"id","type":"long"},{"name":"name","type":"string"},' +
    '{"name":"region","type":"string","default":"eu"}]}';
  Source = '{"id":7,"name":"Alice","legacy":"old"}';
var
  A, B: TAvroSchema;
  CtxA, CtxB: TAvroSerializationContext;
  Options: TStructuralConversionOptions;
  InA, InB: TSerializationPayload;
  BackJson: string;
  Caught: Boolean;
begin
  Writeln;
  Writeln('--- schema A to schema B, both Avro ---');

  A := TAvroSchema.Parse(SchemaA);
  B := TAvroSchema.Parse(SchemaB);
  CtxA := TAvroSerializationContext.Create(A);
  CtxB := TAvroSerializationContext.Create(B);
  try
    { A document in A. }
    InA := TSerialization.Convert(TSerializationPayload.FromText(Source),
      TSerializationFormat.Json, TSerializationFormat.Avro,
      TStructuralConversionProfile.Lossless, CtxA);
    Check(Length(InA.AsBytes) > 0, 'AVRO_A_ENCODED');

    { A to B, with the role of each context said outright. The source
      context says what these bytes were written with; the destination
      context says what to write. }
    Options := TStructuralConversionOptions.FromProfile(
      TStructuralConversionProfile.Natural)
      .WithSource(TSerializationFormat.Avro)
      .WithDestination(TSerializationFormat.Avro)
      .WithSourceContext(CtxA)
      .WithDestinationContext(CtxB);

    InB := TSerialization.Convert(InA, TSerializationFormat.Avro,
      TSerializationFormat.Avro, Options);
    Check(Length(InB.AsBytes) > 0, 'AVRO_SCHEMA_A_TO_SCHEMA_B');

    { And B's bytes really are B's: read them back with B and the field B
      added is there, the field only A had is gone. }
    BackJson := TSerialization.Convert(InB, TSerializationFormat.Avro,
      TSerializationFormat.Json, TStructuralConversionProfile.Natural,
      CtxB).AsText;
    Note(BackJson);
    Check(Pos('"region"', BackJson) > 0, 'AVRO_B_HAS_ITS_OWN_FIELD');
    Check(Pos('"legacy"', BackJson) = 0, 'AVRO_B_DROPPED_THE_FIELD_A_HAD');
    Check(Pos('"name":"Alice"', BackJson) > 0, 'AVRO_A_TO_B_CARRIED_THE_DATA');

    { One context cannot say which end it is for when both ends are Avro. }
    Caught := False;
    try
      TSerialization.Convert(InA, TSerializationFormat.Avro,
        TSerializationFormat.Avro, TStructuralConversionProfile.Natural, CtxA);
    except
      on E: ESerializationSchemaRequired do Caught := True;
    end;
    Check(Caught, 'AVRO_SAME_FORMAT_ONE_CONTEXT_IS_AMBIGUOUS');
  finally
    CtxB.Free;
    CtxA.Free;
    B.Free;
    A.Free;
  end;
end;

{ ===========================================================================
  THE RELEASE-REVIEW REGRESSIONS

  Each of these was a reproduced defect: a number or an instant changed
  without a word, a write its own reader then refused, or an object a
  failed read left alive. TLiveItem's live counter is what turns a leak into
  a failed check rather than a line in a shutdown report.
  =========================================================================== }

{ Passes when AProc raises AClass, and says what it raised otherwise. }
procedure CheckRefused(const AProc: TProc; AClass: ExceptClass;
  const AName: string);
var
  Got: string;
  Refused: Boolean;
begin
  Got := 'nothing was raised';
  Refused := False;
  try
    AProc();
  except
    on E: Exception do
    begin
      Got := E.ClassName + ': ' + E.Message;
      Refused := E is AClass;
    end;
  end;
  if not Refused then Note(Got);
  Check(Refused, AName);
end;

{ The TLiveItems a read left alive when the Nth construction from now is
  refused, and the class of what it raised. }
function LeftAlive(const ARead: TProc; AFailAt: Integer;
  out ARaised: string): Integer;
var
  Live0: Integer;
begin
  Live0 := GLiveItems;
  ARaised := 'nothing';
  GItemFailAt := GItemConstructions + AFailAt;
  try
    try
      ARead();
    except
      on E: Exception do ARaised := E.ClassName;
    end;
  finally
    GItemFailAt := 0;
  end;
  Result := GLiveItems - Live0;
end;

procedure CheckLeftNothing(const ARead: TProc; AFailAt: Integer;
  const AName: string);
var
  Left: Integer;
  Raised: string;
begin
  Left := LeftAlive(ARead, AFailAt, Raised);
  if (Left <> 0) or (Raised <> 'EItemRefused') then
    Note(Format('left alive %d, raised %s', [Left, Raised]));
  Check((Left = 0) and (Raised = 'EItemRefused'), AName);
end;

{ The long a record of one timestamp field is, read back as a bare long. }
function WireLong(const AData: TBytes): Int64;
var
  Schema: TAvroSchema;
  V: TAvroValue;
begin
  Schema := TAvroSchema.Parse('"long"');
  try
    V := TAvroSerializer.Decode(AData, Schema);
    try
      Result := V.AsInt;
    finally
      V.Free;
    end;
  finally
    Schema.Free;
  end;
end;

procedure TestIntIsThirtyTwoBits;
var
  Wide: TWideCount;
  Narrow: TNarrowCount;
  Data: TBytes;
  Schema, Writer, Reader: TAvroSchema;
  V: TAvroValue;
  N: TDynamicValue;
begin
  Writeln;
  Writeln('--- an int is 32 bits ---');

  { A long member's bytes read by a contract whose member is an Integer:
    5000000000 came back as 705032704. The int datum is malformed, and it
    is refused before the member is touched. }
  Wide := TWideCount.Create;
  try
    Wide.Z := 5000000000;
    Data := TAvroSerializer.Serialize<TWideCount>(Wide);
  finally
    Wide.Free;
  end;
  Narrow := TNarrowCount.Create;
  try
    Narrow.Z := 7;
    CheckRefused(
      procedure begin TAvroSerializer.Populate<TNarrowCount>(Narrow, Data) end,
      EAvroInputError, 'D50_INT_MEMBER_REFUSES_A_WIDER_DATUM');
    Check(Narrow.Z = 7, 'D50_REFUSED_BEFORE_THE_MEMBER_CHANGED');
  finally
    Narrow.Free;
  end;

  Schema := TAvroSchema.Parse('"int"');
  try
    { 5000000000 as a zig-zag varint, under an int schema. }
    CheckRefused(
      procedure begin TAvroSerializer.Decode(FromHex('80c8afa025'), Schema).Free end,
      EAvroInputError, 'D50_INT_VARINT_PAST_32_BITS_IS_MALFORMED');
    V := TAvroSerializer.Decode(FromHex('feffffff0f'), Schema);
    try
      Check(V.AsInt = High(Integer), 'D50_INT_MAXIMUM_STILL_READ');
    finally V.Free; end;
    V := TAvroSerializer.Decode(FromHex('ffffffff0f'), Schema);
    try
      Check(V.AsInt = Low(Integer), 'D50_INT_MINIMUM_STILL_READ');
    finally V.Free; end;
    V := TAvroValue.NewLong(5000000000);
    try
      CheckRefused(
        procedure begin TAvroSerializer.Encode(Schema, V) end,
        EAvroInputError, 'D50_INT_SCHEMA_REFUSES_A_WIDER_VALUE');
    finally V.Free; end;
    { And a structural tree headed for an int: narrowed, it wrote
      705032704. }
    N := TDynamicValue.NewInt(5000000000);
    try
      CheckRefused(
        procedure begin TAvroEngine.DynamicToAvro(N, Schema).Free end,
        EAvroInputError, 'D50_DYNAMIC_INT_PAST_32_BITS_REFUSED');
    finally N.Free; end;
  finally
    Schema.Free;
  end;

  { A union offers the long branch for a long that an int cannot hold,
    instead of the int branch the value does not fit. }
  Schema := TAvroSchema.Parse('["int","long"]');
  try
    V := TAvroValue.NewLong(5000000000);
    try
      Data := TAvroSerializer.Encode(Schema, V);
    finally V.Free; end;
    Check(Copy(Hex(Data), 1, 2) = '02', 'D50_UNION_TAKES_THE_LONG_BRANCH');
    V := TAvroSerializer.Decode(Data, Schema);
    try
      Check(V.AsInt = 5000000000, 'D50_UNION_WIDE_LONG_ROUND_TRIP');
    finally V.Free; end;
  finally
    Schema.Free;
  end;

  { An int field the reader's schema drops is still an int. }
  Writer := TAvroSchema.Parse(
    '{"type":"record","name":"R","fields":[{"name":"i","type":"int"}]}');
  Reader := TAvroSchema.Parse('{"type":"record","name":"R","fields":[]}');
  try
    CheckRefused(
      procedure begin
        TAvroSerializer.Decode(FromHex('80c8afa025'), Writer, Reader).Free
      end,
      EAvroInputError, 'D50_SKIPPED_INT_PAST_32_BITS_REFUSED');
  finally
    Reader.Free;
    Writer.Free;
  end;

  { And a default: a value of the field's type, so 32 bits too. }
  Writer := TAvroSchema.Parse('{"type":"record","name":"R","fields":[]}');
  Reader := TAvroSchema.Parse('{"type":"record","name":"R","fields":[' +
    '{"name":"i","type":"int","default":5000000000}]}');
  try
    CheckRefused(
      procedure begin TAvroSerializer.Decode(nil, Writer, Reader).Free end,
      EAvroResolutionError, 'D50_INT_DEFAULT_PAST_32_BITS_REFUSED');
  finally
    Reader.Free;
    Writer.Free;
  end;
end;

procedure CheckMoment(AValue: TDateTime; AMillis: Int64; const AName: string);
var
  M, Back: TMomentHolder;
  Data: TBytes;
begin
  M := TMomentHolder.Create;
  try
    M.At := AValue;
    Data := TAvroSerializer.Serialize<TMomentHolder>(M);
  finally
    M.Free;
  end;
  if WireLong(Data) <> AMillis then
    Note(Format('wire ms %d, expected %d', [WireLong(Data), AMillis]));
  Check(WireLong(Data) = AMillis, AName + '_IS_THE_RIGHT_INSTANT');
  Back := TAvroSerializer.Deserialize<TMomentHolder>(Data);
  try
    Check(SameValue(Back.At, AValue, 1 / MSecsPerDay / 2), AName + '_ROUND_TRIP');
  finally
    Back.Free;
  end;
end;

procedure TestDatesOutsideTheLinearRange;
var
  Schema: TAvroSchema;
  V: TAvroValue;
  Millis: Int64;
begin
  Writeln;
  Writeln('--- TDateTime before 1899-12-30 and outside 1..9999 ---');

  { Before 1899-12-30 a TDateTime is a negative day plus a POSITIVE time of
    day, and the linear arithmetic put every such instant a day early. }
  CheckMoment(EncodeDateTime(1800, 1, 1, 12, 0, 0, 0), -5364619200000,
    'D7_TIMESTAMP_1800_01_01T12');
  CheckMoment(EncodeDateTime(1899, 12, 29, 6, 0, 0, 0), -2209226400000,
    'D26_TIMESTAMP_1899_12_29T06');
  CheckMoment(EncodeDateTime(1, 1, 1, 12, 30, 15, 250), -62135551784750,
    'D26_TIMESTAMP_YEAR_ONE_WITH_A_TIME');

  Schema := TAvroSchema.Parse(
    '{"type":"long","logicalType":"timestamp-micros"}');
  try
    V := TAvroValue.NewDateTime(EncodeDateTime(1800, 1, 1, 12, 0, 0, 0));
    try
      Check(WireLong(TAvroSerializer.Encode(Schema, V)) = -5364619200000000,
        'D7_TIMESTAMP_MICROS_1800_01_01T12');
    finally V.Free; end;
    { One microsecond before the epoch is in the millisecond before it:
      FLOOR division, not truncation toward zero. }
    V := TAvroSerializer.Decode(FromHex('01'), Schema);
    try
      Check(TStructuralText.TryDateTimeToUnixMillis(V.AsDateTime, Millis) and
            (Millis = -1), 'R7_TIMESTAMP_MICROS_BEFORE_THE_EPOCH_FLOORS');
    finally V.Free; end;
  finally
    Schema.Free;
  end;

  { Written, and then refused by its own reader: now refused on write. }
  CheckRefused(
    procedure
    var
      M: TMomentHolder;
    begin
      M := TMomentHolder.Create;
      try
        M.At := EncodeDate(1, 1, 1) - 1;
        TAvroSerializer.Serialize<TMomentHolder>(M);
      finally
        M.Free;
      end;
    end, ESerializationUnsupported, 'D33_DATETIME_BEFORE_YEAR_1_REFUSED_ON_WRITE');
  CheckRefused(
    procedure
    var
      M: TMomentHolder;
    begin
      M := TMomentHolder.Create;
      try
        M.At := EncodeDate(9999, 12, 31) + 1;
        TAvroSerializer.Serialize<TMomentHolder>(M);
      finally
        M.Free;
      end;
    end, ESerializationUnsupported, 'D33_DATETIME_AFTER_9999_REFUSED_ON_WRITE');
  CheckRefused(
    procedure
    var
      D: TDayHolder;
    begin
      D := TDayHolder.Create;
      try
        D.D := EncodeDate(1, 1, 1) - 1;
        TAvroSerializer.Serialize<TDayHolder>(D);
      finally
        D.Free;
      end;
    end, ESerializationUnsupported, 'D33_DATE_BEFORE_YEAR_1_REFUSED_ON_WRITE');
  CheckRefused(
    procedure
    var
      D: TDayHolder;
    begin
      D := TDayHolder.Create;
      try
        D.D := EncodeDate(9999, 12, 31) + 1;
        TAvroSerializer.Serialize<TDayHolder>(D);
      finally
        D.Free;
      end;
    end, ESerializationUnsupported, 'D33_DATE_AFTER_9999_REFUSED_ON_WRITE');

  { A date datum is an int of days, which spells days far past 9999. }
  Schema := TAvroSchema.Parse('{"type":"int","logicalType":"date"}');
  try
    CheckRefused(
      procedure begin TAvroSerializer.Decode(FromHex('feffffff0f'), Schema).Free end,
      EAvroInputError, 'D33_DATE_DATUM_PAST_9999_REFUSED');
  finally
    Schema.Free;
  end;
end;

procedure TestFailedReadsFreeWhatTheyBuilt;
var
  Pairs: TPairHolder;
  NullPairs: TNullablePairHolder;
  PairList: TPairListHolder;
  Arr: TItemArrayHolder;
  Triple: TItemTripleHolder;
  List: TItemListHolder;
  Dict: TItemDictHolder;
  P: TItemPair;
  Many: TArray<TPairHolder>;
  PairData, NullData, PairListData, ArrData, TripleData, ListData, DictData,
  FileData: TBytes;
  I, Live0: Integer;
begin
  Writeln;
  Writeln('--- a failed read frees what it built ---');
  Live0 := GLiveItems;

  Pairs := TPairHolder.Create;
  try
    Pairs.R.A := TLiveItem.Create;
    Pairs.R.B := TLiveItem.Create;
    Pairs.R.N := 3;
    PairData := TAvroSerializer.Serialize<TPairHolder>(Pairs);
  finally
    Pairs.Free;
  end;
  CheckLeftNothing(
    procedure begin TAvroSerializer.Deserialize<TPairHolder>(PairData).Free end,
    2, 'D39_RECORD_HOLDING_OBJECTS_LEAKS_NOTHING');

  NullPairs := TNullablePairHolder.Create;
  try
    P.A := TLiveItem.Create;
    P.B := TLiveItem.Create;
    P.N := 3;
    NullPairs.R := P;
    NullData := TAvroSerializer.Serialize<TNullablePairHolder>(NullPairs);
  finally
    NullPairs.Free;
  end;
  CheckLeftNothing(
    procedure begin TAvroSerializer.Deserialize<TNullablePairHolder>(NullData).Free end,
    2, 'D39_NULLABLE_RECORD_HOLDING_OBJECTS_LEAKS_NOTHING');

  PairList := TPairListHolder.Create;
  try
    PairList.L := TList<TItemPair>.Create;
    for I := 1 to 2 do
    begin
      P.A := TLiveItem.Create;
      P.B := TLiveItem.Create;
      P.N := I;
      PairList.L.Add(P);
    end;
    PairListData := TAvroSerializer.Serialize<TPairListHolder>(PairList);
  finally
    PairList.Free;
  end;
  CheckLeftNothing(
    procedure begin TAvroSerializer.Deserialize<TPairListHolder>(PairListData).Free end,
    4, 'D39_LIST_OF_RECORDS_HOLDING_OBJECTS_LEAKS_NOTHING');

  Arr := TItemArrayHolder.Create;
  try
    SetLength(Arr.A, 3);
    for I := 0 to 2 do Arr.A[I] := TLiveItem.Create;
    ArrData := TAvroSerializer.Serialize<TItemArrayHolder>(Arr);
  finally
    Arr.Free;
  end;
  CheckLeftNothing(
    procedure begin TAvroSerializer.Deserialize<TItemArrayHolder>(ArrData).Free end,
    3, 'D40_DYNAMIC_ARRAY_OF_OBJECTS_LEAKS_NOTHING');

  Triple := TItemTripleHolder.Create;
  try
    for I := 0 to 2 do Triple.A[I] := TLiveItem.Create;
    TripleData := TAvroSerializer.Serialize<TItemTripleHolder>(Triple);
  finally
    Triple.Free;
  end;
  CheckLeftNothing(
    procedure begin TAvroSerializer.Deserialize<TItemTripleHolder>(TripleData).Free end,
    3, 'D40_STATIC_ARRAY_OF_OBJECTS_LEAKS_NOTHING');

  { A TList<T> and a TDictionary<K, T> own nothing: freed alone, the
    container the read built orphaned every element it had added. }
  List := TItemListHolder.Create;
  try
    List.L := TList<TLiveItem>.Create;
    for I := 0 to 2 do List.L.Add(TLiveItem.Create);
    ListData := TAvroSerializer.Serialize<TItemListHolder>(List);
  finally
    List.Free;
  end;
  CheckLeftNothing(
    procedure begin TAvroSerializer.Deserialize<TItemListHolder>(ListData).Free end,
    3, 'D42_READER_BUILT_TLIST_LEAKS_NOTHING');

  Dict := TItemDictHolder.Create;
  try
    Dict.D := TDictionary<string, TLiveItem>.Create;
    Dict.D.Add('k1', TLiveItem.Create);
    Dict.D.Add('k2', TLiveItem.Create);
    Dict.D.Add('k3', TLiveItem.Create);
    DictData := TAvroSerializer.Serialize<TItemDictHolder>(Dict);
  finally
    Dict.Free;
  end;
  CheckLeftNothing(
    procedure begin TAvroSerializer.Deserialize<TItemDictHolder>(DictData).Free end,
    3, 'D42_READER_BUILT_TDICTIONARY_LEAKS_NOTHING');

  { A container file of values: the ones read before the failure are
    nowhere else. }
  SetLength(Many, 3);
  for I := 0 to 2 do
  begin
    Many[I] := TPairHolder.Create;
    Many[I].R.A := TLiveItem.Create;
    Many[I].R.B := TLiveItem.Create;
  end;
  try
    FileData := TAvroSerializer.WriteContainer<TPairHolder>(Many);
  finally
    for I := 0 to 2 do Many[I].Free;
  end;
  CheckLeftNothing(
    procedure
    var
      Back: TArray<TPairHolder>;
      J: Integer;
    begin
      Back := TAvroSerializer.ReadContainer<TPairHolder>(FileData);
      for J := 0 to High(Back) do Back[J].Free;
    end, 5, 'R2_CONTAINER_FILE_OF_VALUES_LEAKS_NOTHING');

  Check(GLiveItems = Live0, 'OWNERSHIP_NOTHING_LEFT_ALIVE_IN_TOTAL');
end;

procedure TestRecordsAndContainers;
var
  Src, Dst: TPairOwner;
  A: TLiveItem;
  Dict, DictBack: TItemDictHolder;
  Item: TLiveItem;
  Lines: TLinesSource;
  Text: TTextHolder;
  Data, LineData: TBytes;
  I, Live0, Patched: Integer;
begin
  Writeln;
  Writeln('--- records merge in place, containers refuse as Avro ---');
  Live0 := GLiveItems;

  { The objects a constructor put in a record member are filled in place,
    not replaced and orphaned. }
  Src := TPairOwner.Create;
  try
    Src.R.A.X := 1;
    Src.R.B.X := 2;
    Src.R.N := 3;
    Data := TAvroSerializer.Serialize<TPairOwner>(Src);
  finally
    Src.Free;
  end;
  Dst := TAvroSerializer.Deserialize<TPairOwner>(Data);
  try
    Check((Dst.R.A.X = 1) and (Dst.R.B.X = 2) and (Dst.R.N = 3),
      'D41_RECORD_MEMBER_READ');
  finally
    Dst.Free;
  end;
  Check(GLiveItems = Live0, 'D41_RECORD_MERGED_IN_PLACE_LEAKS_NOTHING');
  Dst := TPairOwner.Create;
  try
    A := Dst.R.A;
    TAvroSerializer.Populate<TPairOwner>(Dst, Data);
    Check((Dst.R.A = A) and (Dst.R.A.X = 1) and (Dst.R.N = 3),
      'D41_POPULATE_FILLS_THE_RECORDS_OBJECT_IN_PLACE');
  finally
    Dst.Free;
  end;
  Check(GLiveItems = Live0, 'D41_POPULATE_LEAKS_NOTHING');

  { A key the document repeats, into a TDictionary<string, T> the read
    builds: the value built for its first occurrence was orphaned. }
  Dict := TItemDictHolder.Create;
  try
    Dict.D := TDictionary<string, TLiveItem>.Create;
    Item := TLiveItem.Create;
    Item.X := 1;
    Dict.D.Add('qa', Item);
    Item := TLiveItem.Create;
    Item.X := 2;
    Dict.D.Add('qb', Item);
    Data := TAvroSerializer.Serialize<TItemDictHolder>(Dict);
  finally
    Dict.Free;
  end;
  Patched := 0;
  for I := 0 to High(Data) - 1 do
    if (Data[I] = Ord('q')) and (Data[I + 1] = Ord('b')) then
    begin
      Data[I + 1] := Ord('a');
      Inc(Patched);
    end;
  Check(Patched = 1, 'D45_DOCUMENT_PATCHED_TO_REPEAT_A_KEY');
  DictBack := TAvroSerializer.Deserialize<TItemDictHolder>(Data);
  try
    Check((DictBack.D.Count = 1) and (DictBack.D['qa'].X = 2),
      'D45_DUPLICATE_KEY_LAST_ONE_WINS');
  finally
    DictBack.Free;
  end;
  Check(GLiveItems = Live0, 'D45_DUPLICATE_KEY_RELEASES_THE_EARLIER_VALUE');

  { What the container itself raises reaches the caller as Avro's input
    error, not as the RTL's EStringListError. }
  Lines := TLinesSource.Create;
  try
    Lines.Lines.Add('b');
    Lines.Lines.Add('a');
    Lines.Lines.Add('b');
    LineData := TAvroSerializer.Serialize<TLinesSource>(Lines);
  finally
    Lines.Free;
  end;
  CheckRefused(
    procedure begin TAvroSerializer.Deserialize<TSortedLines>(LineData).Free end,
    EAvroInputError, 'D36_CONTAINER_REFUSAL_IS_AN_AVRO_INPUT_ERROR');

  { An unpaired surrogate is half a character, and UTF-8 has no spelling
    for it: refused, not written as U+FFFD. }
  Text := TTextHolder.Create;
  try
    Text.S := 'a' + Char($D800) + 'b';
    CheckRefused(
      procedure begin TAvroSerializer.Serialize<TTextHolder>(Text) end,
      ESerializationUnsupported, 'D27_UNPAIRED_SURROGATE_REFUSED_ON_WRITE');
  finally
    Text.Free;
  end;
end;

{ How deep a chain of each shape went, written and read back; 0 when the
  write refused past the limit. }
function RecordChainRoundTrip(ADepth: Integer): Integer;
var
  H, Back: TRecChainHolder;
  Chain: TRecChain;
  Data: TBytes;
  I: Integer;
begin
  Chain.Tag := ADepth;
  Chain.Kids := nil;
  for I := ADepth - 1 downto 1 do
  begin
    Chain.Kids := [Chain];
    Chain.Tag := I;
  end;
  H := TRecChainHolder.Create;
  try
    H.R := Chain;
    try
      Data := TAvroSerializer.Serialize<TRecChainHolder>(H);
    except
      on ESerializationLimitExceeded do Exit(0);
    end;
  finally
    H.Free;
  end;
  Back := TAvroSerializer.Deserialize<TRecChainHolder>(Data);
  try
    Result := 1;
    Chain := Back.R;
    while Length(Chain.Kids) > 0 do
    begin
      Inc(Result);
      Chain := Chain.Kids[0];
    end;
  finally
    Back.Free;
  end;
end;

function ObjectChainRoundTrip(ADepth: Integer): Integer;
var
  Root, N, Back: TChainNode;
  Data: TBytes;
  I: Integer;
begin
  Root := TChainNode.Create;
  try
    N := Root;
    for I := 2 to ADepth do
    begin
      N.Child := TChainNode.Create;
      N := N.Child;
      N.V := I;
    end;
    try
      Data := TAvroSerializer.Serialize<TChainNode>(Root);
    except
      on ESerializationLimitExceeded do Exit(0);
    end;
  finally
    Root.Free;
  end;
  Back := TAvroSerializer.Deserialize<TChainNode>(Data);
  try
    Result := 0;
    N := Back;
    while N <> nil do
    begin
      Inc(Result);
      N := N.Child;
    end;
  finally
    Back.Free;
  end;
end;

function ListTreeRoundTrip(ADepth: Integer): Integer;
var
  Root, N, Kid, Back: TListNode;
  Data: TBytes;
  I: Integer;
begin
  Root := TListNode.Create;
  try
    N := Root;
    for I := 2 to ADepth do
    begin
      N.Kids := TObjectList<TListNode>.Create(True);
      Kid := TListNode.Create;
      Kid.V := I;
      N.Kids.Add(Kid);
      N := Kid;
    end;
    try
      Data := TAvroSerializer.Serialize<TListNode>(Root);
    except
      on ESerializationLimitExceeded do Exit(0);
    end;
  finally
    Root.Free;
  end;
  Back := TAvroSerializer.Deserialize<TListNode>(Data);
  try
    Result := 1;
    N := Back;
    while (N.Kids <> nil) and (N.Kids.Count > 0) do
    begin
      Inc(Result);
      N := N.Kids[0];
    end;
  finally
    Back.Free;
  end;
end;

function DictTreeRoundTrip(ADepth: Integer): Integer;
var
  Root, N, Kid, Back: TDictNode;
  Data: TBytes;
  I: Integer;
begin
  Root := TDictNode.Create;
  try
    N := Root;
    for I := 2 to ADepth do
    begin
      N.Kids := TDictionary<string, TDictNode>.Create;
      Kid := TDictNode.Create;
      Kid.V := I;
      N.Kids.Add('k', Kid);
      N := Kid;
    end;
    try
      Data := TAvroSerializer.Serialize<TDictNode>(Root);
    except
      on ESerializationLimitExceeded do Exit(0);
    end;
  finally
    Root.Free;
  end;
  Back := TAvroSerializer.Deserialize<TDictNode>(Data);
  try
    Result := 1;
    N := Back;
    while (N.Kids <> nil) and (N.Kids.Count > 0) do
    begin
      Inc(Result);
      N := N.Kids['k'];
    end;
  finally
    Back.Free;
  end;
end;

procedure TestWriterLevels;
begin
  Writeln;
  Writeln('--- every composite the writer enters is one level of 64 ---');
  { The holder, then a record and its Kids array per link: 1 + 2 * 31 = 63
    levels, and one link more is past 64. A chain of records has no object
    in it, and 1000 of them ran the writer out of stack. }
  Check(RecordChainRoundTrip(31) = 31, 'D23_RECORD_CHAIN_WITHIN_64_LEVELS_ROUND_TRIP');
  Check(RecordChainRoundTrip(32) = 0, 'D23_RECORD_CHAIN_PAST_64_LEVELS_REFUSED');
  Check(RecordChainRoundTrip(1000) = 0, 'D23_RECORD_CHAIN_1000_DEEP_REFUSED_NOT_A_CRASH');
  Check(ObjectChainRoundTrip(60) = 60, 'R1_OBJECT_CHAIN_60_ROUND_TRIP');
  Check(ObjectChainRoundTrip(64) = 64, 'R1_OBJECT_CHAIN_64_ROUND_TRIP');
  Check(ObjectChainRoundTrip(65) = 0, 'R1_OBJECT_CHAIN_65_REFUSED');
  { A node and its list are two levels, and whatever the writer accepts the
    reader reads back: 64 levels are well inside the datum depth limit. }
  Check(ListTreeRoundTrip(32) = 32, 'R1_NODE_AND_LIST_64_LEVELS_ROUND_TRIP');
  Check(ListTreeRoundTrip(33) = 0, 'R1_NODE_AND_LIST_PAST_64_LEVELS_REFUSED');
  Check(DictTreeRoundTrip(32) = 32, 'R1_NODE_AND_DICTIONARY_64_LEVELS_ROUND_TRIP');
  Check(DictTreeRoundTrip(33) = 0, 'R1_NODE_AND_DICTIONARY_PAST_64_LEVELS_REFUSED');
  Check(TSerializationGraphGuard.Level = 0, 'R1_GUARD_LEVEL_RESTORED_AFTER_REFUSALS');
end;

procedure TestFloatDefaults;
const
  WriterJson = '{"type":"record","name":"R","fields":[]}';
var
  Writer, Reader: TAvroSchema;
  V: TAvroValue;
  I, Bad: Integer;
  D, Want: Double;
  Text: string;
  Seed: UInt64;
begin
  Writeln;
  Writeln('--- schema double defaults are correctly rounded ---');
  { Seventeen significant digits: the RTL's conversion misread about a
    third of them by an ulp on Win64. }
  Bad := 0;
  Seed := 88172645463325252;
  Writer := TAvroSchema.Parse(WriterJson);
  try
    for I := 1 to 300 do
    begin
      Seed := Seed xor (Seed shl 13);
      Seed := Seed xor (Seed shr 7);
      Seed := Seed xor (Seed shl 17);
      D := (Seed shr 11) / 9007199254740992.0 * Power(10, Integer(Seed mod 7) - 3);
      Text := StringReplace(
        FloatToStrF(D, ffExponent, 17, 0, TFormatSettings.Invariant), '+', '', []);
      if not TStructuralText.TryParseFloat(Text, Want) then Continue;
      Reader := TAvroSchema.Parse('{"type":"record","name":"R","fields":[' +
        '{"name":"d","type":"double","default":' + Text + '}]}');
      try
        V := TAvroSerializer.Decode(nil, Writer, Reader);
        try
          if V.Find('d').AsFloat <> Want then
          begin
            if Bad = 0 then Note(Text + ' misread');
            Inc(Bad);
          end;
        finally
          V.Free;
        end;
      finally
        Reader.Free;
      end;
    end;
  finally
    Writer.Free;
  end;
  Check(Bad = 0, 'R6_DOUBLE_DEFAULTS_CORRECTLY_ROUNDED');
end;

{ A dynamic Int under a temporal logical type is the raw unit count the type
  is defined over. It was taken for a TDateTime serial: day 1 was -25568. }
procedure TestDynamicIntIsTheRawCount;

  function Written(const ASchemaJson: string; ACount: Int64): string;
  var
    Schema: TAvroSchema;
    N: TDynamicValue;
    V: TAvroValue;
  begin
    Schema := TAvroSchema.Parse(ASchemaJson);
    N := TDynamicValue.NewInt(ACount);
    try
      V := TAvroEngine.DynamicToAvro(N, Schema);
      try
        Result := Hex(TAvroSerializer.Encode(Schema, V));
      finally
        V.Free;
      end;
    finally
      N.Free;
      Schema.Free;
    end;
  end;

begin
  Writeln;
  Writeln('--- a dynamic Int under a temporal logical type ---');
  Check(Written('{"type":"int","logicalType":"date"}', 1) = '02',
    'DYNAMIC_INT_DATE_IS_DAYS');
  Check(Written('{"type":"int","logicalType":"time-millis"}', 1000) = 'd00f',
    'DYNAMIC_INT_TIME_MILLIS_IS_MILLISECONDS');
  Check(Written('{"type":"long","logicalType":"timestamp-micros"}', -1) = '01',
    'DYNAMIC_INT_TIMESTAMP_MICROS_IS_MICROSECONDS');
end;

{ What the conversion profile decides on the way into Avro: a member the
  schema does not name, which union branch a value takes, and what may be
  written into an exact decimal. Natural adapts, as documented; Strict and
  Lossless refuse with the path. }
procedure TestProfileSemantics;
const
  CUSTOMER = '{"type":"record","name":"Customer","fields":[' +
    '{"name":"Name","type":"string"}]}';
  ORDERDOC = '{"Customer":{"Name":"Alice","InternalCode":"X-17"}}';
  ORDER = '{"type":"record","name":"Order","fields":[' +
    '{"name":"Customer","type":' + CUSTOMER + '}]}';
  UNION = '["null","int","long","string"]';
  AMBIGUOUS = '["null",{"type":"fixed","name":"F4","size":4},"bytes"]';
  DECIMAL2 = '{"type":"bytes","logicalType":"decimal","precision":10,"scale":2}';
  DECIMAL4 = '{"type":"bytes","logicalType":"decimal","precision":19,"scale":4}';

  function Profile(AProfile: TStructuralConversionProfile;
    ASchema: TAvroSchema): TStructuralConversionOptions;
  begin
    Result := TStructuralConversionOptions.FromProfile(AProfile)
      .WithContext(ASchema);
  end;

  { The bytes a dynamic value becomes under a schema, or the class and
    message of what refused it. }
  function Written(const ASchemaJson: string; AValue: TDynamicValue;
    AProfile: TStructuralConversionProfile): string;
  var
    Schema: TAvroSchema;
    V: TAvroValue;
  begin
    Schema := TAvroSchema.Parse(ASchemaJson);
    try
      try
        V := TAvroEngine.DynamicToAvro(AValue, Schema,
          TStructuralConversionOptions.FromProfile(AProfile), '$');
        try
          Result := Hex(TAvroSerializer.Encode(Schema, V));
        finally
          V.Free;
        end;
      except
        on E: Exception do Result := E.ClassName + ': ' + E.Message;
      end;
    finally
      AValue.Free;
      Schema.Free;
    end;
  end;

  function Refused(const AOutcome, APath: string): Boolean;
  begin
    Result := StartsText('EStructuralConversionError', AOutcome) and
      ((APath = '') or ContainsText(AOutcome, APath));
    if not Result then Note(AOutcome);
  end;

  function OrderAs(AProfile: TStructuralConversionProfile): string;
  var
    Schema: TAvroSchema;
    Payload: TSerializationPayload;
  begin
    Schema := TAvroSchema.Parse(ORDER);
    try
      try
        Payload := TSerialization.Convert(
          TSerializationPayload.FromText(ORDERDOC), TSerializationFormat.Json,
          TSerializationFormat.Avro, Profile(AProfile, Schema));
        Result := Hex(Payload.AsBytes);
      except
        on E: Exception do Result := E.ClassName + ': ' + E.Message;
      end;
    finally
      Schema.Free;
    end;
  end;

  function DecimalOf(const ASchemaJson: string; AValue: TDynamicValue): string;
  var
    Schema: TAvroSchema;
    V, Back: TAvroValue;
  begin
    Schema := TAvroSchema.Parse(ASchemaJson);
    try
      try
        V := TAvroEngine.DynamicToAvro(AValue, Schema,
          TStructuralConversionOptions.FromProfile(
            TStructuralConversionProfile.Strict), '$');
        try
          Back := TAvroSerializer.Decode(TAvroSerializer.Encode(Schema, V),
            Schema);
          try
            Result := Back.AsDecimal;
          finally
            Back.Free;
          end;
        finally
          V.Free;
        end;
      except
        on E: Exception do Result := E.ClassName + ': ' + E.Message;
      end;
    finally
      AValue.Free;
      Schema.Free;
    end;
  end;

var
  Natural, Outcome: string;
  Shipment, Back: TShipment;
  Data: TBytes;
begin
  Writeln;
  Writeln('--- profile semantics on the way into Avro ---');

  { A member the schema does not name. Natural omits it - the bytes are the
    record without it, exactly the one-field record - and the other two
    refuse, naming the member's path. }
  Natural := OrderAs(TStructuralConversionProfile.Natural);
  Check(Natural = '0a416c696365', 'AVRO_UNKNOWN_MEMBER_NATURAL');
  if Natural <> '0a416c696365' then Note(Natural);
  Check(Refused(OrderAs(TStructuralConversionProfile.Strict),
    '$.Customer.InternalCode'), 'AVRO_UNKNOWN_MEMBER_STRICT_REFUSES');
  Check(Refused(OrderAs(TStructuralConversionProfile.Lossless),
    '$.Customer.InternalCode'), 'AVRO_UNKNOWN_MEMBER_LOSSLESS_REFUSES');

  { A union branch is chosen by what the value is. Index 1 is int, 2 long,
    3 string; the index is the first zigzag varint. }
  Check(Written(UNION, TDynamicValue.NewInt(5),
    TStructuralConversionProfile.Strict) = '020a', 'AVRO_UNION_INT_BRANCH');
  Check(Written(UNION, TDynamicValue.NewInt(5000000000),
    TStructuralConversionProfile.Strict) = '0480c8afa025',
    'AVRO_UNION_LONG_BRANCH');
  Check(Written(UNION, TDynamicValue.NewStr('x'),
    TStructuralConversionProfile.Strict) = '060278',
    'AVRO_UNION_STRING_BRANCH');
  Check(Refused(Written(UNION, TDynamicValue.NewBool(True),
    TStructuralConversionProfile.Natural), '$'),
    'AVRO_UNION_NO_COMPATIBLE_BRANCH_REFUSES');
  { Four bytes fit the fixed(4) and the bytes branch equally. Natural takes
    the first in declaration order - the fixed, index 1 - and Strict and
    Lossless refuse to choose. }
  Outcome := Written(AMBIGUOUS, TDynamicValue.NewBytes(TBytes.Create(1, 2, 3, 4)),
    TStructuralConversionProfile.Natural);
  Check((Outcome = '0201020304') and
    Refused(Written(AMBIGUOUS, TDynamicValue.NewBytes(TBytes.Create(1, 2, 3, 4)),
      TStructuralConversionProfile.Strict), '') and
    Refused(Written(AMBIGUOUS, TDynamicValue.NewBytes(TBytes.Create(1, 2, 3, 4)),
      TStructuralConversionProfile.Lossless), ''),
    'AVRO_UNION_AMBIGUITY_POLICY');
  if Outcome <> '0201020304' then Note(Outcome);

  { Exact decimals. An integer and a dynamic decimal are exact in every
    profile, and so is a Currency through the contract path. }
  Check(DecimalOf(DECIMAL2, TDynamicValue.NewInt(12)) = '12.00',
    'AVRO_DECIMAL_INTEGER_EXACT');
  Check(DecimalOf(DECIMAL4, TDynamicValue.NewDecimal('922337203685477.5807')) =
    '922337203685477.5807', 'AVRO_DECIMAL_DYNAMIC_DECIMAL_EXACT');
  Shipment := TShipment.Create;
  try
    Shipment.Amount := 922337203685477.5807;
    Data := TAvroSerializer.Serialize<TShipment>(Shipment);
    Back := TAvroSerializer.Deserialize<TShipment>(Data);
    try
      Check((Back.Amount = Shipment.Amount) and
        (DecimalOf(DECIMAL4, TDynamicValue.NewDecimal(
          CurrToStr(Shipment.Amount, TFormatSettings.Invariant))) =
          '922337203685477.5807'), 'AVRO_DECIMAL_CURRENCY_EXACT');
    finally
      Back.Free;
    end;
  finally
    Shipment.Free;
  end;

  { A binary float. 0.5 IS a decimal with two places, so it is exact in any
    profile; 0.1 is not (it is 0.1000000000000000055...), so Strict and
    Lossless refuse and Natural writes the shortest text that reads back as
    the same double. }
  Check((DecimalOf(DECIMAL2, TDynamicValue.NewFloat(0.5)) = '0.50') and
    Refused(Written(DECIMAL2, TDynamicValue.NewFloat(0.1),
      TStructuralConversionProfile.Strict), '$'),
    'AVRO_DECIMAL_FLOAT_STRICT_POLICY');
  Check(Refused(Written(DECIMAL2, TDynamicValue.NewFloat(0.1),
      TStructuralConversionProfile.Lossless), '$') and
    (Written(DECIMAL2, TDynamicValue.NewFloat(0.1),
      TStructuralConversionProfile.Natural) = '020a'),
    'AVRO_DECIMAL_FLOAT_LOSSLESS_POLICY');
end;

{ ===========================================================================
  BLOCK COUNTS, BLOCK SIZES AND LENGTHS ARE CHECKED BEFORE THEY ARE NARROWED

  Every count and size on the wire is an Avro long. Each crafted input below
  is a few bytes that DECLARE a huge one; the reader must refuse it with
  EAvroInputError before narrowing it to an Integer, allocating or looping.
  Narrowing used to turn 2^32+1 items into 1 and 2^31 into a negative
  bound - a silent desync - and Low(Int64) has no absolute value at all.

  Zig-zag varints by hand: n >= 0 is 2n, n < 0 is -2n-1, seven bits a byte
  low group first, high bit set on every byte but the last.
      2^31      -> zz 2^32      -> 80 80 80 80 10
      2^32+1    -> zz 2^33+2    -> 82 80 80 80 20
      Low(Int64)-> zz 2^64-1    -> ff ff ff ff ff ff ff ff ff 01
      -1        -> 01
  =========================================================================== }

function DecodeHexOutcome(const ASchemaJson, AHex: string): string;
var
  Schema: TAvroSchema;
  V: TAvroValue;
begin
  Schema := TAvroSchema.Parse(ASchemaJson);
  try
    try
      V := TAvroSerializer.Decode(FromHex(AHex), Schema);
      try
        Result := 'decoded ' + IntToStr(V.Count);
      finally
        V.Free;
      end;
    except
      on E: Exception do Result := E.ClassName + ': ' + E.Message;
    end;
  finally
    Schema.Free;
  end;
end;

function RefusedAsInput(const AOutcome: string): Boolean;
begin
  Result := StartsText('EAvroInputError', AOutcome);
  if not Result then Note(AOutcome);
end;

{ A container file whose header and one data block are given as hex: magic,
  metadata (avro.schema = "int", avro.codec = null), a sync marker of
  sixteen zero bytes, then ABlocks. AMetaCount replaces the metadata count
  when it is not empty. }
function ContainerOutcome(const AMetaCount, ABlocks: string): string;
const
  SYNC = '00000000000000000000000000000000';
var
  Hex, Json: string;
  Back: TObjectList<TAvroValue>;
begin
  Hex := '4f626a01';
  if AMetaCount <> '' then Hex := Hex + AMetaCount else Hex := Hex + '04';
  { "avro.schema" (11 bytes) -> "int" with its quotes (5 bytes) }
  Hex := Hex + '16' + '6176726f2e736368656d61' + '0a' + '22696e7422';
  { "avro.codec" (10 bytes) -> "null" (4 bytes) }
  Hex := Hex + '14' + '6176726f2e636f646563' + '08' + '6e756c6c';
  Hex := Hex + '00' + SYNC + ABlocks;
  try
    Back := TAvroSerializer.ReadContainer(FromHex(Hex), Json);
    try
      Result := 'read ' + IntToStr(Back.Count);
    finally
      Back.Free;
    end;
  except
    on E: Exception do Result := E.ClassName + ': ' + E.Message;
  end;
end;

procedure TestBlockCountsAreChecked;
const
  INTS = '{"type":"array","items":"int"}';
  NULLS = '{"type":"array","items":"null"}';
  MAP = '{"type":"map","values":"int"}';
  STR = '"string"';
  SYNC = '00000000000000000000000000000000';
  { A record whose first field is an array the reader below drops, so the
    array is SKIPPED rather than read. }
  SKIP_WRITER = '{"type":"record","name":"S","fields":[' +
    '{"name":"a","type":{"type":"array","items":"int"}},' +
    '{"name":"b","type":"int"}]}';
  SKIP_READER = '{"type":"record","name":"S","fields":[{"name":"b","type":"int"}]}';
var
  Writer, Reader: TAvroSchema;
  SkipOutcome: string;
begin
  Writeln;
  Writeln('--- block counts and sizes are checked before narrowing ---');

  { The control: the same shapes with honest counts read. A negative count
    with its true byte size is an ordinary block; five nulls take no bytes
    at all, so a count above the input left is legitimate for them. }
  Check(DecodeHexOutcome(INTS, '01020200') = 'decoded 1',
    'AVRO_NEGATIVE_BLOCK_COUNT_WITH_SIZE_READS');
  Check(DecodeHexOutcome(NULLS, '0a00') = 'decoded 5',
    'AVRO_ZERO_BYTE_ITEMS_NOT_BOUNDED_BY_INPUT');

  { 2^31 items used to narrow to a negative loop bound, and 2^32+1 to one
    item: the array below decoded as [1]. }
  Check(RefusedAsInput(DecodeHexOutcome(INTS, '808080801002' + '00')) and
    RefusedAsInput(DecodeHexOutcome(INTS, '828080802002' + '00')),
    'AVRO_BLOCK_COUNT_OVERFLOW_REFUSES');

  { Low(Int64) as a count: it cannot be negated, and is refused, not
    overflowed. As a positive count past MaxInt is refused too, the null
    array cannot slip it through. }
  Check(RefusedAsInput(DecodeHexOutcome(INTS, 'ffffffffffffffffff01' + '00')) and
    RefusedAsInput(DecodeHexOutcome(NULLS, 'ffffffffffffffffff01' + '00')),
    'AVRO_LOW_INT64_BLOCK_COUNT_REFUSES');

  { Arrays and maps, including a count within MaxInt but larger than the
    bytes left when each item needs one; and the container header's own
    metadata map, and a container data block's object count. }
  Check(RefusedAsInput(DecodeHexOutcome(MAP, '82808080200278' + '0200')) and
    RefusedAsInput(DecodeHexOutcome(MAP, 'd00f0278' + '0200')) and
    RefusedAsInput(DecodeHexOutcome(INTS, 'd00f0200')) and
    StartsText('read ', ContainerOutcome('', '02' + '02' + '02' + SYNC)) and
    RefusedAsInput(ContainerOutcome('8280808020', '02' + '02' + '02' + SYNC)) and
    RefusedAsInput(ContainerOutcome('', '8280808020' + '02' + '02' + SYNC)) and
    RefusedAsInput(ContainerOutcome('', '01' + '02' + '02' + SYNC)) and
    RefusedAsInput(ContainerOutcome('', '14' + '02' + '02' + SYNC)),
    'AVRO_COLLECTION_COUNT_NO_NARROWING');

  { A negative count's byte size: past MaxInt, and past the input left -
    read, and skipped, where Integer(2^32+1) used to skip one byte and the
    record then decoded with the wrong b. A container block's byte size
    past MaxInt. And a bytes/string length past MaxInt. }
  Writer := TAvroSchema.Parse(SKIP_WRITER);
  Reader := TAvroSchema.Parse(SKIP_READER);
  try
    try
      TAvroSerializer.Decode(FromHex('01' + '8280808020' + '02' + '00' + '04'),
        Writer, Reader).Free;
      SkipOutcome := 'decoded';
    except
      on E: Exception do SkipOutcome := E.ClassName + ': ' + E.Message;
    end;
  finally
    Reader.Free;
    Writer.Free;
  end;
  Check(RefusedAsInput(DecodeHexOutcome(INTS, '01' + '8080808010' + '0200')) and
    RefusedAsInput(DecodeHexOutcome(INTS, '01' + 'c801' + '0200')) and
    RefusedAsInput(SkipOutcome) and
    RefusedAsInput(ContainerOutcome('', '02' + '8280808020' + '02' + SYNC)) and
    RefusedAsInput(DecodeHexOutcome(STR, '8280808020' + '78')),
    'AVRO_BLOCK_SIZE_NO_NARROWING');
end;

{ TDynamicValue.Find is exact, and so is an Avro name: "Name" and "name"
  are two members, and the schema's "name" takes the one spelled "name". }
procedure TestCaseDistinctLookup;
const
  P_SCHEMA = '{"type":"record","name":"P","fields":[' +
    '{"name":"name","type":"string"}]}';
  DOC = '{"Name":"wrong","name":"correct"}';
  { "correct": length 7 (zz 0e) and its UTF-8 bytes. }
  EXPECTED = '0e636f7272656374';
  RWRITER = '{"type":"record","name":"Q","fields":[' +
    '{"name":"Name","type":"string"}]}';
  RREADER = '{"type":"record","name":"Q","fields":[' +
    '{"name":"Name","type":"string"},' +
    '{"name":"name","type":"string","default":"d"}]}';

  function Converted(AProfile: TStructuralConversionProfile): string;
  var
    Schema: TAvroSchema;
  begin
    Schema := TAvroSchema.Parse(P_SCHEMA);
    try
      try
        Result := Hex(TSerialization.Convert(TSerializationPayload.FromText(DOC),
          TSerializationFormat.Json, TSerializationFormat.Avro,
          TStructuralConversionOptions.FromProfile(AProfile)
            .WithContext(Schema)).AsBytes);
      except
        on E: Exception do Result := E.ClassName + ': ' + E.Message;
      end;
    finally
      Schema.Free;
    end;
  end;

  function RefusedAt(const AOutcome, APath: string): Boolean;
  begin
    Result := StartsText('EStructuralConversionError', AOutcome) and
      ContainsText(AOutcome, APath);
    if not Result then Note(AOutcome);
  end;

var
  Natural: string;
  Writer, Reader: TAvroSchema;
  W, V: TAvroValue;
  Resolved: Boolean;
begin
  Writeln;
  Writeln('--- names are case-sensitive ---');
  Natural := Converted(TStructuralConversionProfile.Natural);
  if Natural <> EXPECTED then Note(Natural);
  Check((Natural = EXPECTED) and
    RefusedAt(Converted(TStructuralConversionProfile.Strict), '$.Name') and
    RefusedAt(Converted(TStructuralConversionProfile.Lossless), '$.Name'),
    'AVRO_CASE_DISTINCT_SCHEMA_LOOKUP');

  { Resolution too: the writer wrote "Name", and the reader's "name" is a
    different field, filled from its default rather than taken as seen. }
  Writer := TAvroSchema.Parse(RWRITER);
  Reader := TAvroSchema.Parse(RREADER);
  try
    W := TAvroValue.NewRecord;
    try
      W.Add('Name', TAvroValue.NewStr('w'));
      V := TAvroSerializer.Decode(TAvroSerializer.Encode(Writer, W), Writer,
        Reader);
      try
        Resolved := (V.Find('Name') <> nil) and (V.Find('Name').AsStr = 'w') and
          (V.Find('name') <> nil) and (V.Find('name').AsStr = 'd');
      finally
        V.Free;
      end;
    finally
      W.Free;
    end;
  finally
    Reader.Free;
    Writer.Free;
  end;
  Check(Resolved, 'AVRO_CASE_DISTINCT_RESOLUTION_DEFAULT');
end;

{ A value whose kind the field's type cannot hold is refused, in every
  profile - never written as the field's zero value. }
procedure TestStructuralKindMismatch;
const
  ROW_SCHEMA = '{"type":"record","name":"Row","fields":[' +
    '{"name":"id","type":"int"},{"name":"flag","type":"boolean"},' +
    '{"name":"name","type":"string"},{"name":"data","type":["null","bytes"]},' +
    '{"name":"blob","type":"bytes","default":""}]}';
  { JSON has no bytes, so a bytes field is null or absent in a valid
    document; text is not decoded as base64 behind the caller's back. }
  GOOD = '{"id":5,"flag":true,"name":"n","data":null}';
var
  Schema: TAvroSchema;
  P: TStructuralConversionProfile;
  Ok: Boolean;

  function Outcome(const AJson: string;
    AProfile: TStructuralConversionProfile): string;
  begin
    try
      Result := Hex(TSerialization.Convert(TSerializationPayload.FromText(AJson),
        TSerializationFormat.Json, TSerializationFormat.Avro,
        TStructuralConversionOptions.FromProfile(AProfile).WithContext(
          Schema)).AsBytes);
    except
      on E: Exception do Result := E.ClassName + ': ' + E.Message;
    end;
  end;

  function Refused(const AJson, APath: string;
    AProfile: TStructuralConversionProfile): Boolean;
  var
    Got: string;
  begin
    Got := Outcome(AJson, AProfile);
    Result := StartsText('EStructuralConversionError', Got) and
      ContainsText(Got, APath);
    if not Result then Note(Got);
  end;

begin
  Writeln;
  Writeln('--- a value of the wrong kind is refused, not zeroed ---');
  Schema := TAvroSchema.Parse(ROW_SCHEMA);
  try
    Ok := not StartsText('E', Outcome(GOOD, TStructuralConversionProfile.Natural));
    for P := Low(TStructuralConversionProfile) to High(TStructuralConversionProfile) do
      Ok := Ok and
        Refused('{"id":"abc","flag":true,"name":"n","data":null}', '$.id', P) and
        Refused('{"id":5,"flag":"yes","name":"n","data":null}', '$.flag', P) and
        Refused('{"id":5,"flag":true,"name":7,"data":null}', '$.name', P) and
        Refused('{"id":5,"flag":true,"name":"n","data":12}', '$.data', P) and
        Refused('{"id":5,"flag":true,"name":"n","data":null,"blob":"AQI="}',
          '$.blob', P);
    Check(Ok, 'AVRO_STRUCTURAL_KIND_MISMATCH_REFUSES');
  finally
    Schema.Free;
  end;
end;

{ A deflate container block is bounded WHILE it inflates: a few kilobytes of
  input cannot make the reader allocate whatever its decompressed form is. }
procedure TestDeflateBudget;
const
  BIG = 4 * 1024 * 1024;
var
  Schema: TAvroSchema;
  Value: TAvroValue;
  Data, Damaged, Sync: TBytes;
  Back: TObjectList<TAvroValue>;
  Json, Outcome, Normal: string;
  I, P, Start, BlockLen: Integer;
  Small: TAvroReadOptions;

  { Reads a zigzag varint at AP and returns the value; AP moves past it. }
  function GetLong(var AP: Integer): Int64;
  var
    U: UInt64;
    Shift: Integer;
    B: Byte;
  begin
    U := 0;
    Shift := 0;
    repeat
      B := Damaged[AP];
      Inc(AP);
      U := U or (UInt64(B and $7F) shl Shift);
      Inc(Shift, 7);
    until (B and $80) = 0;
    Result := Int64(U shr 1) xor -Int64(U and 1);
  end;

  function ReadWith(const AData: TBytes; const AOptions: TAvroReadOptions): string;
  var
    L: TObjectList<TAvroValue>;
    J: string;
  begin
    try
      L := TAvroSerializer.ReadContainer(AData, nil, AOptions, J);
      try
        Result := 'read ' + IntToStr(L.Count) + ' ' +
          IntToStr(Length(L[0].AsStr));
      finally
        L.Free;
      end;
    except
      on E: Exception do Result := E.ClassName + ': ' + E.Message;
    end;
  end;

begin
  Writeln;
  Writeln('--- a deflate container block is bounded while it inflates ---');

  { A normal block reads under the default limit. }
  Schema := TAvroSchema.Parse('{"type":"record","name":"R","fields":[' +
    '{"name":"id","type":"long"},{"name":"name","type":"string"}]}');
  try
    Value := TAvroValue.NewRecord;
    try
      Value.Add('id', TAvroValue.NewLong(7));
      Value.Add('name', TAvroValue.NewStr('deflated'));
      Data := TAvroSerializer.WriteContainer(Schema, [Value], TAvroCodec.Deflate);
    finally
      Value.Free;
    end;
    Back := TAvroSerializer.ReadContainer(Data, nil, TAvroReadOptions.Default, Json);
    try
      Check((Back.Count = 1) and (Back[0].Find('name').AsStr = 'deflated'),
        'AVRO_DEFLATE_NORMAL_BLOCK');
    finally
      Back.Free;
    end;
  finally
    Schema.Free;
  end;

  { 4 MB of one character compresses to a few kilobytes. }
  Schema := TAvroSchema.Parse('"string"');
  try
    Value := TAvroValue.NewStr(StringOfChar('a', BIG));
    try
      Data := TAvroSerializer.WriteContainer(Schema, [Value], TAvroCodec.Deflate);
    finally
      Value.Free;
    end;
  finally
    Schema.Free;
  end;
  Small := TAvroReadOptions.Default.WithMaxInflatedBlockBytes(64 * 1024);
  Normal := ReadWith(Data, TAvroReadOptions.Default);
  Outcome := ReadWith(Data, Small);
  Check((Length(Data) < 64 * 1024) and (Normal = 'read 1 ' + IntToStr(BIG)) and
    StartsText('EAvroInputError', Outcome) and ContainsText(Outcome, 'limit'),
    'AVRO_DEFLATE_LIMIT_REFUSES');
  if not StartsText('EAvroInputError', Outcome) then Note(Outcome);

  { Damage the second half of the compressed block. Inflating it completely
    reaches the damage; a reader that stops at the budget never gets there,
    so it reports the limit rather than the damage. }
  Damaged := Copy(Data);
  Sync := Copy(Data, Length(Data) - 16, 16);
  Start := -1;
  for I := 4 to Length(Data) - 32 do
    if CompareMem(@Data[I], @Sync[0], 16) then
    begin
      Start := I + 16;
      Break;
    end;
  P := Start;
  GetLong(P);                       { the object count }
  BlockLen := Integer(GetLong(P));  { the compressed size; data starts at P }
  for I := P + BlockLen div 2 to P + BlockLen - 1 do Damaged[I] := $FF;
  Normal := ReadWith(Damaged, TAvroReadOptions.Default);
  Outcome := ReadWith(Damaged, Small);
  Check((Start > 0) and not StartsText('read', Normal) and
    not ContainsText(Normal, 'limit') and
    StartsText('EAvroInputError', Outcome) and ContainsText(Outcome, 'limit'),
    'AVRO_DEFLATE_LIMIT_STOPS_BEFORE_FULL_EXPANSION');
  if not ContainsText(Outcome, 'limit') or StartsText('read', Normal) then
  begin
    Note('full: ' + Normal);
    Note('budget: ' + Outcome);
  end;
end;

{ A fixed "size" an Integer cannot hold is a schema error, not the RTL's
  conversion error escaping the parser. }
procedure TestOversizedFixedSize;
var
  Size, Got, All: string;
  S: TAvroSchema;
begin
  Writeln;
  Writeln('--- a fixed size an Integer cannot hold ---');
  All := '';
  for Size in ['2147483648', '99999999999999999999', '1.5', '1e3'] do
  begin
    try
      S := TAvroSchema.Parse('{"type":"fixed","name":"F","size":' + Size + '}');
      S.Free;
      Got := 'parsed';
    except
      on E: Exception do Got := E.ClassName;
    end;
    All := All + Size + '=' + Got + ' ';
  end;
  Check(All = '2147483648=EAvroSchemaError 99999999999999999999=EAvroSchemaError ' +
    '1.5=EAvroSchemaError 1e3=EAvroSchemaError ', 'AVRO_SCHEMA_OVERSIZED_SIZE_REFUSES');
  if not ContainsText(All, 'Error 1e3=EAvroSchemaError') then Note(All);
end;

{ Whatever a default write makes, a default read opens: blocks are flushed
  at about 1 MiB, so data far past the 64 MiB read limit still reads. A
  single deflate datum past that limit is refused on write, not left for
  the reader to refuse. }
procedure TestDefaultWriteReadsBack;
const
  MIB = 1024 * 1024;
  COUNT = 66;
var
  Schema: TAvroSchema;
  Values: TArray<TAvroValue>;
  Chunk, Data: TBytes;
  Back: TObjectList<TAvroValue>;
  Json, Got: string;
  I: Integer;
  Total: Int64;
  Ok: Boolean;
begin
  Writeln;
  Writeln('--- a default write reads back with default options ---');
  Schema := TAvroSchema.Parse('"bytes"');
  try
    SetLength(Chunk, MIB);
    for I := 0 to High(Chunk) do Chunk[I] := Byte(I mod 251);
    SetLength(Values, COUNT);
    try
      for I := 0 to COUNT - 1 do Values[I] := TAvroValue.NewBytes(Chunk);
      Data := TAvroSerializer.WriteContainer(Schema, Values, TAvroCodec.Deflate);
    finally
      for I := 0 to COUNT - 1 do Values[I].Free;
    end;
    Got := '';
    Total := 0;
    Ok := False;
    try
      Back := TAvroSerializer.ReadContainer(Data, Json);
      try
        Ok := Back.Count = COUNT;
        for I := 0 to Back.Count - 1 do
          Inc(Total, Length(Back[I].AsBytes));
        if Ok then
          Ok := CompareMem(@Back[COUNT - 1].AsBytes[0], @Chunk[0], MIB);
      finally
        Back.Free;
      end;
    except
      on E: Exception do Got := E.ClassName + ': ' + E.Message;
    end;
    Check(Ok and (Total = Int64(COUNT) * MIB) and (Total > 64 * MIB),
      'AVRO_DEFAULT_WRITE_PAST_64_MIB_READS_BACK');
    if Got <> '' then Note(Got);
    Data := nil;

    { One datum past the limit: refused under deflate, written under null. }
    SetLength(Chunk, TAvroReadOptions.DefaultMaxInflatedBlockBytes + 1);
    Values := [TAvroValue.NewBytes(Chunk)];
    try
      try
        TAvroSerializer.WriteContainer(Schema, Values, TAvroCodec.Deflate);
        Got := 'written';
      except
        on E: Exception do Got := E.ClassName;
      end;
      Data := TAvroSerializer.WriteContainer(Schema, Values, TAvroCodec.Null);
    finally
      Values[0].Free;
    end;
    Check((Got = 'EAvroError') and (Length(Data) > Length(Chunk)),
      'AVRO_DEFLATE_WRITE_REFUSES_A_DATUM_PAST_THE_READ_LIMIT');
    if Got <> 'EAvroError' then Note(Got);
    Data := nil;
    Chunk := nil;
  finally
    Schema.Free;
  end;
end;

{ A budget of zero or less is refused by name - set through
  WithMaxInflatedBlockBytes or directly on the field. }
procedure TestNonPositiveBudget;
var
  Data: TBytes;
  Schema: TAvroSchema;
  Value: TAvroValue;
  Options: TAvroReadOptions;
  Budget: Integer;
  All, Json: string;

  function Outcome(const AProc: TProc): string;
  begin
    try
      AProc();
      Result := 'accepted';
    except
      on E: Exception do Result := E.ClassName;
    end;
  end;

begin
  Writeln;
  Writeln('--- a non-positive inflate budget is refused ---');
  Schema := TAvroSchema.Parse('"long"');
  try
    Value := TAvroValue.NewLong(5);
    try
      Data := TAvroSerializer.WriteContainer(Schema, [Value], TAvroCodec.Deflate);
    finally
      Value.Free;
    end;
  finally
    Schema.Free;
  end;
  All := '';
  for Budget in [0, -1, Low(Integer)] do
  begin
    All := All + Outcome(
      procedure
      begin
        TAvroReadOptions.Default.WithMaxInflatedBlockBytes(Budget);
      end) + ' ';
    Options := TAvroReadOptions.Default;
    Options.MaxInflatedBlockBytes := Budget;
    All := All + Outcome(
      procedure
      var
        L: TObjectList<TAvroValue>;
      begin
        L := TAvroSerializer.ReadContainer(Data, nil, Options, Json);
        L.Free;
      end) + ' ';
    All := All + Outcome(
      procedure
      begin
        TAvroSerializer.ReadContainer<Int64>(Data, Options);
      end) + ' ';
  end;
  Check(All = DupeString('EAvroError ', 9),
    'AVRO_READ_OPTIONS_NONPOSITIVE_REFUSED');
  if All <> DupeString('EAvroError ', 9) then Note(All);
  Options := TAvroReadOptions.Default.WithMaxInflatedBlockBytes(1);
  Check(Options.MaxInflatedBlockBytes = 1, 'AVRO_READ_OPTIONS_ONE_IS_ACCEPTED');
end;

procedure TestFeatureLedger;
begin
  Writeln;
  Writeln('--- Avro 1.12 feature ledger ---');
  Note('null, boolean, int, long          TYPE_*, VARINT_*');
  Note('float, double                     TYPE_FLOAT, TYPE_DOUBLE');
  Note('bytes, string                     TYPE_BYTES, SPEC_*');
  Note('record                            SPEC_*, CONTRACT_*');
  Note('enum                              TYPE_ENUM_IS_AN_INDEX');
  Note('array, map - block encoding       TYPE_ARRAY_BLOCKS, TYPE_MAP_BLOCKS');
  Note('union - branch index              TYPE_UNION_*');
  Note('fixed - no length prefix          TYPE_FIXED_HAS_NO_LENGTH');
  Note('schema JSON declaration parsed    SPEC_SCHEMA_PARSED, every Parse');
  Note('named types and references        CONTRACT_NESTED_RECORD');
  Note('aliases                           RESOLVE_FIELD_ALIAS');
  Note('defaults                          RESOLVE_ADDED_FIELD_*');
  Note('SCHEMA RESOLUTION                 RESOLVE_*');
  Note('  field added                     RESOLVE_ADDED_FIELD_*');
  Note('  field removed                   RESOLVE_REMOVED_FIELD_*');
  Note('  field renamed by alias          RESOLVE_FIELD_ALIAS');
  Note('  the specification''s promotions  RESOLVE_INT_TO_*');
  Note('  everything else refused         RESOLVE_REFUSES_A_NARROWING');
  Note('logical decimal                   LOGICAL_DECIMAL_*');
  Note('logical uuid                      LOGICAL_UUID_PARSED');
  Note('logical date, time, timestamp     LOGICAL_DATE_*, LOGICAL_TIMESTAMP_*');
  Note('logical duration                  LOGICAL_DURATION_*');
  Note('unknown logical annotation kept   LOGICAL_UNKNOWN_*');
  Note('object container files            CONTAINER_*');
  Note('null and deflate codecs           CONTAINER_DEFLATE_CODEC');
  Writeln;
  Note('NOT IMPLEMENTED, deliberately:');
  Note('  The snappy, bzip2, xz and zstandard container codecs. The');
  Note('    specification requires null and names deflate; the rest need');
  Note('    third-party libraries, and a file written with one is REFUSED');
  Note('    by name rather than read as garbage.');
  Note('  Avro JSON encoding (as opposed to the binary one). It is a');
  Note('    separate encoding in the same specification and nothing in this');
  Note('    library needs it: a JSON document is what PascalForge.Json is');
  Note('    for.');
  Note('  Protocols, messages and RPC. Those are the other half of the');
  Note('    specification and are not serialization.');
  Note('  The sync marker is derived from the schema fingerprint rather');
  Note('    than random, so that writing the same data twice produces the');
  Note('    same file. The specification asks for random; a reproducible');
  Note('    build is worth more here and the marker''s only job is to be');
  Note('    unlikely to appear in the data.');
  Check(True, 'AVRO_FEATURE_LEDGER');
end;

begin
  try
    TestVarints;
    TestSpecExample;
    TestEveryType;
    TestResolution;
    TestLogicalTypes;
    TestContainer;
    TestContract;
    TestConversionMatrix;
    TestSchemaAToSchemaB;
    TestDataSet;
    TestIntIsThirtyTwoBits;
    TestDatesOutsideTheLinearRange;
    TestFailedReadsFreeWhatTheyBuilt;
    TestRecordsAndContainers;
    TestWriterLevels;
    TestFloatDefaults;
    TestDynamicIntIsTheRawCount;
    TestProfileSemantics;
    TestStructuralKindMismatch;
    TestDeflateBudget;
    TestOversizedFixedSize;
    TestDefaultWriteReadsBack;
    TestNonPositiveBudget;
    TestBlockCountsAreChecked;
    TestCaseDistinctLookup;
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
    Writeln('AVRO_SCHEMA_MODEL: PASS');
    Writeln('AVRO_BINARY_ENCODING: PASS');
    Writeln('AVRO_SCHEMA_RESOLUTION: PASS');
    Writeln('AVRO_LOGICAL_TYPES: PASS');
    Writeln('AVRO_CONTAINER_FILES: PASS');
    Writeln('AVRO_INDEPENDENT_INTEROP: PASS');
    Writeln('AVRO_NATIVE: PASS');
  end
  else
  begin
    Writeln('AVRO_NATIVE: FAIL');
    ExitCode := 1;
  end;
end.
