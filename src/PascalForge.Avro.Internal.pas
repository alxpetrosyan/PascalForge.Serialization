{*******************************************************************************
  PascalForge.Avro.Internal

  INTERNAL IMPLEMENTATION UNIT - applications should not use this unit directly.

  Implements the Avro engine: writer, reader, schema resolver, object
  container files and schema generation from Delphi types.
  Exposed through the public facade PascalForge.Avro (TAvroSerializer).

  Registration
    Format registration lives in PascalForge.Avro.Registration and is explicit.

  Documentation
    docs/formats/avro.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Avro.Internal;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  The Avro engine.

  NOT PART OF THE PUBLIC API. Everything here is reachable through
  PascalForge.Avro; this unit exists so that the public one can be read in
  one sitting.

  WHAT IS IN HERE

    TAvroWriter     a datum, given its schema, as bytes
    TAvroReader     bytes, given the WRITER's schema, as a datum
    TAvroResolver   the writer's schema against the reader's - the part of
                    Avro that is not optional
    TAvroContainer  the object container file format
    TAvroEngine     everything else: the contract walk, the schema a Delphi
                    type generates, and the configuration.

  WHY SCHEMA RESOLUTION IS NOT OPTIONAL

  Avro bytes carry NO type information at all. A record is its fields, one
  after another, with nothing between them; an int is a zig-zag varint and
  so is the branch index of a union. Nothing in the bytes says which. So the
  writer's schema is not a nicety that improves the decoding - it IS the
  decoding, and a reader that assumed its own schema would read a file
  written by an older version of the same program as garbage, silently.

  That is why every read path here takes two schemas, and why the reader and
  the resolver are separate: the reader walks the WRITER's schema, because
  that is what the bytes are, and the resolver decides what the reader's
  schema makes of each piece.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections, System.SyncObjs, System.Math,
  System.DateUtils, System.ZLib, System.NetEncoding, System.StrUtils,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Serialization.Internal,
  PascalForge.Nullable,
  PascalForge.Avro.Schema,
  PascalForge.Avro;

type
  TAvroEngine = class
  strict private
    class var FLock: TCriticalSection;
    class var FEnumMappings: TDictionary<string, TArray<string>>;
    class var FTypeSerializers: TDictionary<string, TAvroValueSerializerClass>;
    class var FSchemas: TObjectDictionary<string, TAvroSchema>;
    class var FFrozen: Boolean;
    class procedure CheckNotFrozen; static;
  public
    class constructor Create;
    class destructor Destroy;

    { --- the schema a Delphi type generates --- }
    class function SchemaJsonFor(ATypeInfo: PTypeInfo): string; static;
    class function SchemaFor(ATypeInfo: PTypeInfo): TAvroSchema; static;

    { --- the datum level --- }
    class function EncodeDatum(ASchema: TAvroSchema;
      AValue: TAvroValue): TBytes; static;
    class function DecodeDatum(const AData: TBytes;
      AWriter, AReader: TAvroSchema): TAvroValue; static;

    { --- the contract --- }
    class function SerializeRoot(ATypeInfo: PTypeInfo;
      const AValue: TValue): TBytes; static;
    class function DeserializeRoot(ATypeInfo: PTypeInfo; const AData: TBytes;
      const AExisting: TValue): TValue; static;
    class function DeserializeRootWith(ATypeInfo: PTypeInfo;
      const AData: TBytes; AWriter: TAvroSchema;
      const AExisting: TValue): TValue; static;

    { --- container files --- }
    class function WriteContainer(ASchema: TAvroSchema;
      const AValues: array of TAvroValue; ACodec: TAvroCodec): TBytes; static;
    { AMaxInflatedBlockBytes bounds each deflate block while it inflates. }
    class function ReadContainer(const AData: TBytes; AReader: TAvroSchema;
      AMaxInflatedBlockBytes: Integer;
      out AWriterSchemaJson: string): TObjectList<TAvroValue>; static;
    class function ReadContainerTyped(ATypeInfo: PTypeInfo;
      const AData: TBytes; AMaxInflatedBlockBytes: Integer): TArray<TValue>; static;
    class function WriteContainerTyped(ATypeInfo: PTypeInfo;
      const AValues: TArray<TValue>; ACodec: TAvroCodec): TBytes; static;

    { --- cross-format, reached only through the registry --- }
    class function FromPayload(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; static;

    { --- the dynamic tree (structural conversion only, SCHEMA REQUIRED) --- }
    class function AvroToDynamic(AValue: TAvroValue): TDynamicValue; static;
    { The profile decides what happens to what the schema cannot say: a
      member it does not name, a float into a decimal, a union value two
      branches fit equally. Natural adapts (documented in
      docs\avro-behavior.md); Lossless and Strict refuse with the path. The
      two-argument form is Natural at '$'. }
    class function DynamicToAvro(AValue: TDynamicValue;
      ASchema: TAvroSchema): TAvroValue; overload; static;
    class function DynamicToAvro(AValue: TDynamicValue; ASchema: TAvroSchema;
      const AOptions: TStructuralConversionOptions;
      const APath: string): TAvroValue; overload; static;

    { --- configuration --- }
    class procedure RegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TAvroValueSerializerClass); static;
    class procedure RegisterEnumMapping(ATypeInfo: PTypeInfo;
      const ASymbols: array of string); static;
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;
    class procedure ResetConfiguration; static;
    class function TryGetEnumMapping(ATypeInfo: PTypeInfo;
      out AValues: TArray<string>): Boolean; static;
    class function TryGetTypeSerializer(ATypeInfo: PTypeInfo;
      out AClass: TAvroValueSerializerClass): Boolean; static;
  end;

implementation

var
  GCtx: TRttiContext;

function TypeKeyOf(ATypeInfo: PTypeInfo): string;
begin
  if ATypeInfo = nil then Exit('');
  Result := UTF8ToString(ATypeInfo.Name) + IntToHex(NativeUInt(ATypeInfo), 8);
end;

{ ===========================================================================
  THE BINARY ENCODING

  Avro's encoding is small because it says nothing: an int is a zig-zag
  varint, a record is its fields one after another, and there is no tag, no
  length prefix on a record and no name anywhere. Everything that makes the
  bytes meaningful is in the schema.
  =========================================================================== }

type
  TAvroByteWriter = record
  strict private
    FData: TBytes;
    FPos: Integer;
    procedure Ensure(ACount: Integer);
  public
    procedure Init;
    procedure PutByte(AValue: Byte);
    procedure PutRaw(const AValue: TBytes);
    { Zig-zag then variable-length: the encoding that makes a small negative
      number as short as a small positive one. }
    procedure PutLong(AValue: Int64);
    procedure PutFloat(AValue: Single);
    procedure PutDouble(AValue: Double);
    procedure PutBytes(const AValue: TBytes);
    procedure PutString(const AValue: string);
    function Done: TBytes;
    property Position: Integer read FPos;
  end;

procedure TAvroByteWriter.Init;
begin
  SetLength(FData, 256);
  FPos := 0;
end;

procedure TAvroByteWriter.Ensure(ACount: Integer);
begin
  if FPos + ACount <= Length(FData) then Exit;
  SetLength(FData, Max(Length(FData) * 2, FPos + ACount));
end;

procedure TAvroByteWriter.PutByte(AValue: Byte);
begin
  Ensure(1);
  FData[FPos] := AValue;
  Inc(FPos);
end;

procedure TAvroByteWriter.PutRaw(const AValue: TBytes);
begin
  if Length(AValue) = 0 then Exit;
  Ensure(Integer(Length(AValue)));
  Move(AValue[0], FData[FPos], Length(AValue));
  Inc(FPos, Length(AValue));
end;

procedure TAvroByteWriter.PutLong(AValue: Int64);
var
  U: UInt64;
begin
  { Zig-zag: (n shl 1) xor (n shr 63), with an ARITHMETIC shift so that the
    sign fills. Delphi's shr on a signed Int64 is logical, which is why the
    sign is taken separately here rather than shifted down. }
  if AValue < 0 then U := (UInt64(-(AValue + 1)) shl 1) or 1
  else U := UInt64(AValue) shl 1;
  repeat
    if U > $7F then PutByte(Byte(U and $7F) or $80)
    else PutByte(Byte(U and $7F));
    U := U shr 7;
  until U = 0;
end;

procedure TAvroByteWriter.PutFloat(AValue: Single);
var
  Bits: Cardinal;
begin
  Bits := PCardinal(@AValue)^;
  { Little-endian, which is what the specification says and what x86 has
    anyway - written a byte at a time so that it stays true elsewhere. }
  PutByte(Byte(Bits));
  PutByte(Byte(Bits shr 8));
  PutByte(Byte(Bits shr 16));
  PutByte(Byte(Bits shr 24));
end;

procedure TAvroByteWriter.PutDouble(AValue: Double);
var
  Bits: UInt64;
  I: Integer;
begin
  Bits := PUInt64(@AValue)^;
  for I := 0 to 7 do PutByte(Byte(Bits shr (I * 8)));
end;

procedure TAvroByteWriter.PutBytes(const AValue: TBytes);
begin
  PutLong(Length(AValue));
  PutRaw(AValue);
end;

procedure TAvroByteWriter.PutString(const AValue: string);
begin
  PutBytes(StringToUtf8Bytes(AValue));
end;

function TAvroByteWriter.Done: TBytes;
begin
  SetLength(FData, FPos);
  Result := FData;
end;

type
  TAvroByteReader = record
  strict private
    FData: TBytes;
    FPos: Integer;
    FEnd: Integer;
    procedure Need(ACount: Integer);
  public
    procedure Init(const AData: TBytes);
    function AtEnd: Boolean;
    function GetByte: Byte;
    function GetRaw(ACount: Integer): TBytes;
    function GetLong: Int64;
    function GetFloat: Single;
    function GetDouble: Double;
    function GetBytes: TBytes;
    function GetString: string;
    procedure Skip(ACount: Integer);
    function Remaining: Integer;
    property Position: Integer read FPos write FPos;
    property Limit: Integer read FEnd;
  public
    { How deep the datum being read is nested - see ReadDatum. }
    Depth: Integer;
  end;

procedure TAvroByteReader.Init(const AData: TBytes);
begin
  { Every position and length here is an Integer. A buffer past MaxInt bytes
    (possible on Win64 only) is refused rather than read through a truncated
    end, so both platforms read exactly the same inputs. }
  if Int64(Length(AData)) > MaxInt then
    raise EAvroInputError.CreateFmt(
      'The Avro data is %d bytes; this reader handles at most %d.',
      [Int64(Length(AData)), MaxInt]);
  FData := AData;
  FPos := 0;
  FEnd := Integer(Length(AData));
  Depth := 0;
end;

function TAvroByteReader.AtEnd: Boolean;
begin
  Result := FPos >= FEnd;
end;

function TAvroByteReader.Remaining: Integer;
begin
  Result := FEnd - FPos;
end;

procedure TAvroByteReader.Need(ACount: Integer);
begin
  { A subtraction, not an addition: FPos + ACount can overflow when the
    document claims a length it does not have, and the overflow would make
    the check pass. }
  if (ACount < 0) or (ACount > FEnd - FPos) then
    raise EAvroInputError.CreateFmt(
      'The data ends after %d bytes and something claims %d more at ' +
      'offset %d. Either the file is truncated or it was read with the ' +
      'wrong schema - Avro bytes carry no types, so the wrong schema reads ' +
      'a length out of what was never a length.', [FEnd, ACount, FPos]);
end;

procedure TAvroByteReader.Skip(ACount: Integer);
begin
  Need(ACount);
  Inc(FPos, ACount);
end;

function TAvroByteReader.GetByte: Byte;
begin
  Need(1);
  Result := FData[FPos];
  Inc(FPos);
end;

function TAvroByteReader.GetRaw(ACount: Integer): TBytes;
begin
  Need(ACount);
  SetLength(Result, ACount);
  if ACount > 0 then Move(FData[FPos], Result[0], ACount);
  Inc(FPos, ACount);
end;

function TAvroByteReader.GetLong: Int64;
var
  Shift: Integer;
  B: Byte;
  U: UInt64;
begin
  U := 0;
  Shift := 0;
  repeat
    if Shift > 63 then
      raise EAvroInputError.CreateFmt(
        'A variable-length integer at offset %d is longer than ten bytes, ' +
        'which no Avro long can be.', [FPos]);
    B := GetByte;
    U := U or (UInt64(B and $7F) shl Shift);
    Inc(Shift, 7);
  until (B and $80) = 0;
  { Un-zig-zag. An odd U is -(U shr 1) - 1, which is "not (U shr 1)": no
    negation, so Low(Int64) (U = all ones) decodes without an overflow. }
  if (U and 1) <> 0 then Result := not Int64(U shr 1)
  else Result := Int64(U shr 1);
end;

function TAvroByteReader.GetFloat: Single;
var
  Bits: Cardinal;
begin
  Bits := GetByte or (Cardinal(GetByte) shl 8) or
          (Cardinal(GetByte) shl 16) or (Cardinal(GetByte) shl 24);
  Result := PSingle(@Bits)^;
end;

function TAvroByteReader.GetDouble: Double;
var
  Bits: UInt64;
  I: Integer;
begin
  Bits := 0;
  for I := 0 to 7 do Bits := Bits or (UInt64(GetByte) shl (I * 8));
  Result := PDouble(@Bits)^;
end;

function TAvroByteReader.GetBytes: TBytes;
var
  Len: Int64;
begin
  Len := GetLong;
  if (Len < 0) or (Len > MaxInt) then
    raise EAvroInputError.CreateFmt(
      'A byte string at offset %d claims a length of %d.', [FPos, Len]);
  Result := GetRaw(Integer(Len));
end;

function TAvroByteReader.GetString: string;
var
  Raw: TBytes;
begin
  Raw := GetBytes;
  { Avro strings are UTF-8 by definition, and a sequence that is not valid
    UTF-8 is a document that is wrong - not text to be guessed at. }
  Result := Utf8BytesToString(Raw);
end;

{ ===========================================================================
  DECIMAL, which travels as a two's-complement big-endian integer
  =========================================================================== }

{ The unscaled value of a decimal, as big-endian two's complement - which is
  what Avro's decimal logical type carries and why a decimal is exact here
  and approximate in a format that uses a double. }
function DecimalTextToUnscaled(const AText: string; AScale: Integer): TBytes;
var
  Digits: string;
  Negative: Boolean;
  Dot, I, Frac: Integer;
  Magnitude: TBytes;
  Carry, Cur: Integer;
  Value: TBytes;
  Any: Boolean;
begin
  Digits := Trim(AText);
  Negative := (Digits <> '') and (Digits[1] = '-');
  if Negative or ((Digits <> '') and (Digits[1] = '+')) then
    Digits := Copy(Digits, 2, MaxInt);
  Dot := Pos('.', Digits);
  if Dot > 0 then
  begin
    Frac := Length(Digits) - Dot;
    Digits := Copy(Digits, 1, Dot - 1) + Copy(Digits, Dot + 1, MaxInt);
  end
  else
    Frac := 0;
  { Rescale to exactly AScale places: pad with zeros when the text has
    fewer, and refuse when it has more, because dropping a digit here is
    losing money without saying so. }
  while Frac < AScale do
  begin
    Digits := Digits + '0';
    Inc(Frac);
  end;
  if Frac > AScale then
    raise EAvroInputError.CreateFmt(
      '"%s" has %d decimal places and the schema says %d. Writing it would ' +
      'drop a digit, so it is refused rather than rounded.',
      [AText, Frac, AScale]);

  { Decimal digits to a big-endian magnitude, by repeated multiply-by-ten. }
  SetLength(Magnitude, 0);
  for I := 1 to Length(Digits) do
  begin
    if not CharInSet(Digits[I], ['0'..'9']) then
      raise EAvroInputError.CreateFmt('"%s" is not a decimal number.',
        [AText]);
    Carry := Ord(Digits[I]) - Ord('0');
    for Frac := Integer(High(Magnitude)) downto 0 do
    begin
      Cur := Magnitude[Frac] * 10 + Carry;
      Magnitude[Frac] := Byte(Cur and $FF);
      Carry := Cur shr 8;
    end;
    while Carry <> 0 do
    begin
      SetLength(Value, Length(Magnitude) + 1);
      Value[0] := Byte(Carry and $FF);
      if Length(Magnitude) > 0 then
        Move(Magnitude[0], Value[1], Length(Magnitude));
      Magnitude := Value;
      Carry := Carry shr 8;
    end;
  end;

  { Trim leading zeros, then make room for a sign bit: two's complement
    needs the top bit clear for a positive value. }
  I := 0;
  while (I < High(Magnitude)) and (Magnitude[I] = 0) do Inc(I);
  Magnitude := Copy(Magnitude, I, Length(Magnitude) - I);
  if Length(Magnitude) = 0 then Magnitude := TBytes.Create(0);
  if (Magnitude[0] and $80) <> 0 then
    Magnitude := TBytes.Create(0) + Magnitude;

  if not Negative then Exit(Magnitude);

  { Negate: invert every byte and add one. }
  SetLength(Result, Length(Magnitude));
  for I := 0 to Integer(High(Magnitude)) do Result[I] := not Magnitude[I];
  Any := False;
  for I := Integer(High(Result)) downto 0 do
  begin
    if Result[I] = $FF then Result[I] := 0
    else
    begin
      Result[I] := Byte(Result[I] + 1);
      Any := True;
      Break;
    end;
  end;
  if not Any then Result := TBytes.Create($FF) + Result;
end;

function UnscaledToDecimalText(const AValue: TBytes; AScale: Integer): string;
var
  Magnitude: TBytes;
  Negative: Boolean;
  I, J, Cur, Remainder: Integer;
  Digits: string;
  Any: Boolean;
begin
  if Length(AValue) = 0 then Exit('0');
  Negative := (AValue[0] and $80) <> 0;
  Magnitude := Copy(AValue, 0, Length(AValue));
  if Negative then
  begin
    { Two's complement back to a magnitude: subtract one, then invert. }
    for I := Integer(High(Magnitude)) downto 0 do
      if Magnitude[I] = 0 then Magnitude[I] := $FF
      else
      begin
        Magnitude[I] := Byte(Magnitude[I] - 1);
        Break;
      end;
    for I := 0 to Integer(High(Magnitude)) do Magnitude[I] := not Magnitude[I];
  end;

  { Long division by ten, most significant byte first. }
  Digits := '';
  repeat
    Remainder := 0;
    Any := False;
    for I := 0 to Integer(High(Magnitude)) do
    begin
      Cur := (Remainder shl 8) or Magnitude[I];
      Magnitude[I] := Byte(Cur div 10);
      if Magnitude[I] <> 0 then Any := True;
      Remainder := Cur mod 10;
    end;
    Digits := Chr(Ord('0') + Remainder) + Digits;
  until not Any;

  while Length(Digits) <= AScale do Digits := '0' + Digits;
  if AScale > 0 then
    Digits := Copy(Digits, 1, Length(Digits) - AScale) + '.' +
              Copy(Digits, Length(Digits) - AScale + 1, AScale);
  J := 1;
  while (J < Length(Digits)) and (Digits[J] = '0') and (Digits[J + 1] <> '.') do
    Inc(J);
  Digits := Copy(Digits, J, MaxInt);
  if Negative then Digits := '-' + Digits;
  Result := Digits;
end;

{ ===========================================================================
  WRITING A DATUM
  =========================================================================== }

procedure WriteDatum(var AW: TAvroByteWriter; ASchema: TAvroSchema;
  AValue: TAvroValue; const APath: string); forward;

{ The branch of a union a value belongs to. Avro writes the INDEX, so this
  decision is part of the encoding and not a convenience. }
function BranchFor(ASchema: TAvroSchema; AValue: TAvroValue;
  const APath: string): Integer;
var
  I: Integer;
  B: TAvroSchema;
begin
  for I := 0 to ASchema.BranchCount - 1 do
  begin
    B := ASchema.Branches[I];
    case AValue.Kind of
      TAvroKind.Null:   if B.SchemaType = TAvroType.Null then Exit(I);
      TAvroKind.Bool:   if B.SchemaType = TAvroType.Bool then Exit(I);
      TAvroKind.Int:    if B.SchemaType = TAvroType.Int then Exit(I);
      { A long goes to an int branch only when it fits: an int is 32 bits,
        and a wider value written there is a varint no reader accepts. }
      TAvroKind.Long:
        if (B.SchemaType = TAvroType.Long) or
           ((B.SchemaType = TAvroType.Int) and (AValue.AsInt >= Low(Integer)) and
            (AValue.AsInt <= High(Integer))) then Exit(I);
      TAvroKind.Float:  if B.SchemaType = TAvroType.Float then Exit(I);
      TAvroKind.Double: if B.SchemaType = TAvroType.Double then Exit(I);
      TAvroKind.Bytes:  if B.SchemaType = TAvroType.Bytes then Exit(I);
      TAvroKind.Str:    if B.SchemaType = TAvroType.Str then Exit(I);
      TAvroKind.Rec:    if B.SchemaType = TAvroType.Rec then Exit(I);
      TAvroKind.Enum:   if B.SchemaType = TAvroType.Enum then Exit(I);
      TAvroKind.Arr:    if B.SchemaType = TAvroType.Arr then Exit(I);
      TAvroKind.Map:    if B.SchemaType = TAvroType.Map then Exit(I);
      TAvroKind.Fixed:  if B.SchemaType = TAvroType.Fixed then Exit(I);
      TAvroKind.Decimal:
        if B.LogicalType = TAvroLogicalType.Decimal then Exit(I);
      TAvroKind.DateTime:
        if B.LogicalType in [TAvroLogicalType.Date,
          TAvroLogicalType.TimeMillis, TAvroLogicalType.TimeMicros,
          TAvroLogicalType.TimestampMillis, TAvroLogicalType.TimestampMicros,
          TAvroLogicalType.LocalTimestampMillis,
          TAvroLogicalType.LocalTimestampMicros] then Exit(I);
      TAvroKind.Duration:
        if B.LogicalType = TAvroLogicalType.Duration then Exit(I);
    end;
  end;
  raise EAvroInputError.CreateFmt(
    'At %s: no branch of the union %s accepts %s. A union writes the index ' +
    'of the branch, so a value that fits none of them cannot be written at ' +
    'all.', [APath, ASchema.TypeName, AValue.Describe]);
end;
{ A date or an instant outside the years 1 to 9999 is refused, not written:
  every reader here refuses it, and before year 1 there is no calendar date
  to state. }
procedure RefuseDateTime(AValue: TDateTime; const APath: string);
begin
  raise ESerializationUnsupported.CreateFmt(
    'At %s: the TDateTime %s is outside the years 1 to 9999, which no reader ' +
    'here reads back, so it is refused rather than written.',
    [APath, FloatToStr(AValue, TFormatSettings.Invariant)]);
end;

{ The instant a date/time logical type stores, as the integer it stores.

  Every one of these is a count from an epoch or from midnight, and getting
  the UNIT wrong produces a timestamp that is off by a factor of a thousand
  and still looks like a date. }
function DateTimeToRaw(AValue: TAvroValue; ALogical: TAvroLogicalType;
  const APath: string): Int64;
var
  DT: TDateTime;
begin
  { A value that arrived as raw units keeps them, so that reading a file and
    writing it back does not go through a TDateTime and lose the precision
    the file had. }
  if AValue.RawValue <> 0 then Exit(AValue.RawValue);
  DT := AValue.AsDateTime;
  case ALogical of
    TAvroLogicalType.Date:
      begin
        if not TStructuralText.IsDateTimeInRange(DT) then
          RefuseDateTime(DT, APath);
        Result := Trunc(DT) - Trunc(UnixDateDelta);
      end;
    TAvroLogicalType.TimeMillis:
      Result := Round(Frac(Abs(DT)) * MSecsPerDay);
    TAvroLogicalType.TimeMicros:
      Result := Round(Frac(Abs(DT)) * MSecsPerDay) * 1000;
  else
    { Through Core, which follows Delphi's encoding: before 1899-12-30 a
      TDateTime is a negative day plus a POSITIVE time of day, and the linear
      (DT - UnixDateDelta) * MSecsPerDay put every such instant a day early. }
    if not TStructuralText.TryDateTimeToUnixMillis(DT, Result) then
      RefuseDateTime(DT, APath);
    if ALogical in [TAvroLogicalType.TimestampMicros,
                    TAvroLogicalType.LocalTimestampMicros] then
      Result := Result * 1000;
  end;
end;

{ And back. The inverse has to exist explicitly: a value read from a file
  carries the raw count, and something has to turn it into the TDateTime a
  Delphi member holds. }
function RawToDateTime(ARaw: Int64; ALogical: TAvroLogicalType): TDateTime;
var
  Millis: Int64;
begin
  case ALogical of
    TAvroLogicalType.Date:
      begin
        { Days, range-checked like every other epoch count: an int spells
          days far past the year 9999. }
        Result := UnixDateDelta + ARaw;
        if not TStructuralText.IsDateTimeInRange(Result) then
          raise EAvroInputError.CreateFmt(
            'The date %d days from the epoch is outside the years a TDateTime ' +
            'holds.', [ARaw]);
      end;
    TAvroLogicalType.TimeMillis:
      Result := ARaw / MSecsPerDay;
    TAvroLogicalType.TimeMicros:
      Result := (ARaw div 1000) / MSecsPerDay;
    TAvroLogicalType.TimestampMicros,
    TAvroLogicalType.LocalTimestampMicros:
      begin
        { FLOOR division: before the epoch, div truncates toward zero and
          moves the instant to the later millisecond. }
        Millis := ARaw div 1000;
        if (ARaw mod 1000) < 0 then Dec(Millis);
        if not TStructuralText.TryUnixMillisToDateTime(Millis, Result) then
          raise EAvroInputError.CreateFmt(
            'The timestamp %d us is outside the years a TDateTime holds.', [ARaw]);
      end;
  else
    if not TStructuralText.TryUnixMillisToDateTime(ARaw, Result) then
      raise EAvroInputError.CreateFmt(
        'The timestamp %d ms is outside the years a TDateTime holds.', [ARaw]);
  end;
end;

procedure WriteDatum(var AW: TAvroByteWriter; ASchema: TAvroSchema;
  AValue: TAvroValue; const APath: string);
var
  I, Index: Integer;
  Field: TAvroField;
  Child: TAvroValue;
  Raw: TBytes;
  Sym: Integer;
  Number: Int64;
begin
  if ASchema = nil then
    raise EAvroInternalError.CreateFmt('At %s: no schema.', [APath]);
  if AValue = nil then
    raise EAvroInputError.CreateFmt('At %s: no value.', [APath]);

  case ASchema.SchemaType of
    TAvroType.Null: Exit;   { zero bytes, which is the whole encoding }

    TAvroType.Bool:
      begin
        if AValue.AsBool then AW.PutByte(1) else AW.PutByte(0);
        Exit;
      end;

    TAvroType.Int, TAvroType.Long:
      begin
        if ASchema.LogicalType in [TAvroLogicalType.Date,
          TAvroLogicalType.TimeMillis, TAvroLogicalType.TimeMicros,
          TAvroLogicalType.TimestampMillis, TAvroLogicalType.TimestampMicros,
          TAvroLogicalType.LocalTimestampMillis,
          TAvroLogicalType.LocalTimestampMicros] then
          Number := DateTimeToRaw(AValue, ASchema.LogicalType, APath)
        else
          Number := AValue.AsInt;
        { An int is 32 bits: a wider value is refused rather than written as
          a varint the reader refuses. }
        if (ASchema.SchemaType = TAvroType.Int) and
           ((Number < Low(Integer)) or (Number > High(Integer))) then
          raise EAvroInputError.CreateFmt(
            'At %s: %d does not fit in an Avro int, which is 32 bits. Write it ' +
            'with a long schema.', [APath, Number]);
        AW.PutLong(Number);
        Exit;
      end;

    TAvroType.Float:
      begin
        AW.PutFloat(AValue.AsFloat);
        Exit;
      end;

    TAvroType.Double:
      begin
        AW.PutDouble(AValue.AsFloat);
        Exit;
      end;

    TAvroType.Bytes:
      begin
        if ASchema.LogicalType = TAvroLogicalType.Decimal then
          AW.PutBytes(DecimalTextToUnscaled(AValue.AsDecimal, ASchema.Scale))
        else
          AW.PutBytes(AValue.AsBytes);
        Exit;
      end;

    TAvroType.Str:
      begin
        AW.PutString(AValue.AsStr);
        Exit;
      end;

    TAvroType.Fixed:
      begin
        if ASchema.LogicalType = TAvroLogicalType.Decimal then
        begin
          Raw := DecimalTextToUnscaled(AValue.AsDecimal, ASchema.Scale);
          { A fixed decimal is sign-extended to the declared width. }
          while Length(Raw) < ASchema.Size do
            if (Length(Raw) > 0) and ((Raw[0] and $80) <> 0) then
              Raw := TBytes.Create($FF) + Raw
            else
              Raw := TBytes.Create(0) + Raw;
        end
        else if ASchema.LogicalType = TAvroLogicalType.Duration then
        begin
          SetLength(Raw, 12);
          PCardinal(@Raw[0])^ := AValue.DurationMonths;
          PCardinal(@Raw[4])^ := AValue.DurationDays;
          PCardinal(@Raw[8])^ := AValue.DurationMillis;
        end
        else
          Raw := AValue.AsBytes;
        if Length(Raw) <> ASchema.Size then
          raise EAvroInputError.CreateFmt(
            'At %s: the schema says fixed(%d) and this value is %d bytes. A ' +
            'fixed has no length prefix, so the two have to agree exactly.',
            [APath, ASchema.Size, Length(Raw)]);
        AW.PutRaw(Raw);
        Exit;
      end;

    TAvroType.Enum:
      begin
        Sym := ASchema.IndexOfSymbol(AValue.AsStr);
        if Sym < 0 then
          raise EAvroInputError.CreateFmt(
            'At %s: "%s" is not one of the symbols of %s. An enum writes the ' +
            'INDEX of its symbol, so a symbol the schema does not list has ' +
            'no number to write.', [APath, AValue.AsStr, ASchema.TypeName]);
        AW.PutLong(Sym);
        Exit;
      end;

    TAvroType.Rec:
      begin
        for I := 0 to ASchema.FieldCount - 1 do
        begin
          Field := ASchema.Fields[I];
          Child := AValue.Find(Field.Name);
          if Child = nil then
            raise EAvroInputError.CreateFmt(
              'At %s: the record has no field "%s" and the schema requires ' +
              'one. Avro writes the fields in order with nothing between ' +
              'them, so a missing one is not an omission - it shifts every ' +
              'byte after it.', [APath, Field.Name]);
          WriteDatum(AW, Field.FieldType, Child,
            APath + '.' + Field.Name);
        end;
        Exit;
      end;

    TAvroType.Arr:
      begin
        if AValue.Count > 0 then
        begin
          AW.PutLong(AValue.Count);
          for I := 0 to AValue.Count - 1 do
            WriteDatum(AW, ASchema.ItemType, AValue.Items[I],
              Format('%s[%d]', [APath, I]));
        end;
        { The terminating zero-length block, which is what says the array
          has ended. }
        AW.PutLong(0);
        Exit;
      end;

    TAvroType.Map:
      begin
        if AValue.Count > 0 then
        begin
          AW.PutLong(AValue.Count);
          for I := 0 to AValue.Count - 1 do
          begin
            AW.PutString(AValue.Names[I]);
            WriteDatum(AW, ASchema.ValueType, AValue.Items[I],
              APath + '.' + AValue.Names[I]);
          end;
        end;
        AW.PutLong(0);
        Exit;
      end;

    TAvroType.Union:
      begin
        Index := BranchFor(ASchema, AValue, APath);
        AW.PutLong(Index);
        WriteDatum(AW, ASchema.Branches[Index], AValue, APath);
        Exit;
      end;
  end;
  raise EAvroInternalError.CreateFmt('At %s: cannot write %s.',
    [APath, ASchema.TypeName]);
end;

{ ===========================================================================
  READING A DATUM, WITH RESOLUTION

  The reader walks the WRITER's schema, because that is what the bytes are.
  The reader's schema decides what to make of each piece - and what to
  DISCARD, which is the half that a naive implementation forgets: a field
  the writer has and the reader does not still has to be read past, or every
  byte after it is misaligned.
  =========================================================================== }

function ReadDatum(var AR: TAvroByteReader; AWriter, AReader: TAvroSchema;
  const APath: string): TAvroValue; forward;

{ Can a value written as AWriter be read as AReader? The promotions are the
  specification's list and no more: int to long, float or double; long to
  float or double; float to double; string to bytes and bytes to string. }
function Promotes(AWriter, AReader: TAvroType): Boolean;
begin
  if AWriter = AReader then Exit(True);
  case AWriter of
    TAvroType.Int:
      Result := AReader in [TAvroType.Long, TAvroType.Float, TAvroType.Double];
    TAvroType.Long:
      Result := AReader in [TAvroType.Float, TAvroType.Double];
    TAvroType.Float:
      Result := AReader = TAvroType.Double;
    TAvroType.Str:
      Result := AReader = TAvroType.Bytes;
    TAvroType.Bytes:
      Result := AReader = TAvroType.Str;
  else
    Result := False;
  end;
end;

{ The reader's counterpart of a writer schema, with unions on either side
  resolved. Returns nil when the reader has nothing that matches, which is
  an error everywhere except inside a record whose field the reader dropped. }
function MatchReader(AWriter, AReader: TAvroSchema): TAvroSchema;
var
  I: Integer;
begin
  if AReader = nil then Exit(nil);

  { A reader union takes the first branch the writer's schema can be read
    as, which is the specification's rule. }
  if (AReader.SchemaType = TAvroType.Union) and
     (AWriter.SchemaType <> TAvroType.Union) then
  begin
    for I := 0 to AReader.BranchCount - 1 do
      if MatchReader(AWriter, AReader.Branches[I]) <> nil then
        Exit(AReader.Branches[I]);
    Exit(nil);
  end;

  if AWriter.SchemaType = TAvroType.Union then Exit(AReader);

  if AWriter.SchemaType in [TAvroType.Rec, TAvroType.Enum, TAvroType.Fixed] then
  begin
    if AReader.SchemaType <> AWriter.SchemaType then Exit(nil);
    { A named type matches by full name OR by one of the reader's aliases,
      which is how a schema is renamed without breaking the files already
      written. }
    if AReader.Matches(AWriter.FullName) then Exit(AReader);
    Exit(nil);
  end;

  if AWriter.SchemaType = TAvroType.Arr then
    if AReader.SchemaType = TAvroType.Arr then Exit(AReader) else Exit(nil);
  if AWriter.SchemaType = TAvroType.Map then
    if AReader.SchemaType = TAvroType.Map then Exit(AReader) else Exit(nil);

  if Promotes(AWriter.SchemaType, AReader.SchemaType) then Exit(AReader);
  Result := nil;
end;

{ A bytes default: the specification encodes it as JSON text whose code
  points 0..255 ARE the bytes, which is why it cannot just be UTF-8 encoded. }
function DefaultBytesOf(ADefault: TAvroDefault): TBytes;
var
  S: string;
  I: Integer;
begin
  S := ADefault.AsStr;
  SetLength(Result, Length(S));
  for I := 1 to Length(S) do
  begin
    if Ord(S[I]) > 255 then
      raise EAvroResolutionError.CreateFmt(
        'A bytes default contains U+%s, and the specification encodes a ' +
        'bytes default as code points 0 to 255 only.',
        [IntToHex(Ord(S[I]), 4)]);
    Result[I - 1] := Byte(Ord(S[I]));
  end;
end;

{ A field the reader wants and the writer never wrote: its DEFAULT, turned
  into a value of the reader's type. Without this, adding a field to a
  schema would make every file written before it unreadable. }
function DefaultToValue(ASchema: TAvroSchema; ADefault: TAvroDefault;
  const APath: string): TAvroValue;
var
  I: Integer;
  Branch: TAvroSchema;
begin
  if ADefault = nil then
    raise EAvroResolutionError.CreateFmt(
      'At %s: the reader''s schema has a field the writer''s does not, and ' +
      'it has no default. There is nothing in the bytes to read and nothing ' +
      'to put there instead, so the two schemas cannot be resolved.',
      [APath]);

  { A union's default is a value of its FIRST branch - the specification is
    explicit, and it is why "null" has to come first in a nullable field. }
  Branch := ASchema;
  if Branch.SchemaType = TAvroType.Union then
  begin
    if Branch.BranchCount = 0 then
      raise EAvroResolutionError.CreateFmt('At %s: an empty union.', [APath]);
    Branch := Branch.Branches[0];
  end;

  case Branch.SchemaType of
    TAvroType.Null: Exit(TAvroValue.NewNull);
    TAvroType.Bool: Exit(TAvroValue.NewBool(ADefault.AsBool));
    TAvroType.Int:
      begin
        { A default is a value of the field's type, and an int is 32 bits:
          a wider one was narrowed to a different number without a word. }
        if (ADefault.AsInt < Low(Integer)) or (ADefault.AsInt > High(Integer)) then
          raise EAvroResolutionError.CreateFmt(
            'At %s: the default %d does not fit in an Avro int, which is 32 ' +
            'bits.', [APath, ADefault.AsInt]);
        Exit(TAvroValue.NewInt(Integer(ADefault.AsInt)));
      end;
    TAvroType.Long: Exit(TAvroValue.NewLong(ADefault.AsInt));
    TAvroType.Float: Exit(TAvroValue.NewFloat(ADefault.AsFloat));
    TAvroType.Double: Exit(TAvroValue.NewDouble(ADefault.AsFloat));
    TAvroType.Str: Exit(TAvroValue.NewStr(ADefault.AsStr));
    TAvroType.Enum: Exit(TAvroValue.NewEnum(ADefault.AsStr));
    TAvroType.Bytes, TAvroType.Fixed:
      { A bytes default is JSON text whose code points 0..255 are the bytes,
        which is the specification's own encoding for it. }
      Exit(TAvroValue.NewBytes(DefaultBytesOf(ADefault)));
    TAvroType.Arr:
      begin
        Result := TAvroValue.NewArray;
        try
          for I := 0 to ADefault.Count - 1 do
            Result.Add(DefaultToValue(Branch.ItemType, ADefault.Items[I],
              Format('%s[%d]', [APath, I])));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
    TAvroType.Map:
      begin
        Result := TAvroValue.NewMap;
        try
          for I := 0 to ADefault.Count - 1 do
            Result.Add(ADefault.Names[I],
              DefaultToValue(Branch.ValueType, ADefault.Items[I],
                APath + '.' + ADefault.Names[I]));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
    TAvroType.Rec:
      begin
        Result := TAvroValue.NewRecord;
        try
          for I := 0 to Branch.FieldCount - 1 do
            Result.Add(Branch.Fields[I].Name,
              DefaultToValue(Branch.Fields[I].FieldType,
                ADefault.Find(Branch.Fields[I].Name),
                APath + '.' + Branch.Fields[I].Name));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
  end;
  raise EAvroResolutionError.CreateFmt(
    'At %s: cannot build a default of type %s.', [APath, Branch.TypeName]);
end;

{ Read past a datum without building anything - for a field the writer has
  and the reader dropped. The bytes still have to be consumed, because Avro
  puts nothing between fields. }
const
  { How deep a datum may nest before the reader refuses. Every record,
    array, map and union is a recursive call, and a recursive schema lets a
    few bytes per level nest as deep as the data likes: a hundred thousand
    levels overflowed the stack.

    Far above what this library writes: the writer stops at 64 levels
    (TSerializationGraphGuard), and a level is at most two datums here - an
    object, list or dictionary member is a union and its branch - plus the
    scalar at the end. }
  AVRO_MAX_DEPTH = 512;

procedure EnterDatum(var AR: TAvroByteReader);
begin
  if AR.Depth >= AVRO_MAX_DEPTH then
    raise EAvroInputError.CreateFmt(
      'The datum nests more than %d deep at byte %d.',
      [AVRO_MAX_DEPTH, AR.Position]);
  Inc(AR.Depth);
end;

{ An int datum: a zig-zag varint like a long, but 32 bits. A varint that
  decodes past that is not an Avro int, and narrowing it handed back a
  different number without a word - 5000000000 read as 705032704. }
function GetIntDatum(var AR: TAvroByteReader; const APath: string): Int64;
begin
  Result := AR.GetLong;
  if (Result < Low(Integer)) or (Result > High(Integer)) then
    raise EAvroInputError.CreateFmt(
      'At %s: the int datum ending at byte %d is %d, and an Avro int is 32 ' +
      'bits. The data is malformed, or it was written with a long schema.',
      [APath, AR.Position, Result]);
end;

{ Can a datum of this schema be zero bytes long? Only null, a fixed of size
  0, and a record made of nothing else. Everything else - a varint, a
  length, a union index, an array's terminating zero - takes at least one
  byte, which is what lets a block count be checked against the input left.
  A schema too deep to prove anything about answers True: no bound. }
function AvroDatumCanBeEmpty(ASchema: TAvroSchema; ADepth: Integer = 0): Boolean;
var
  I: Integer;
begin
  if ADepth > AVRO_MAX_DEPTH then Exit(True);
  case ASchema.SchemaType of
    TAvroType.Null: Result := True;
    TAvroType.Fixed: Result := ASchema.Size = 0;
    TAvroType.Rec:
      begin
        for I := 0 to ASchema.FieldCount - 1 do
          if not AvroDatumCanBeEmpty(ASchema.Fields[I].FieldType, ADepth + 1) then
            Exit(False);
        Result := True;
      end;
  else
    Result := False;
  end;
end;

{ The header of one block - of an array, a map, or a container header's
  metadata map - checked before anything is narrowed, allocated or looped
  over. The count is an Avro long: 0 ends the collection; a negative count
  means its absolute value in items, followed by a long byte size of the
  block. Low(Int64) has no absolute value and is refused rather than
  negated; a count past MaxInt is refused rather than truncated; a byte size
  that is negative, past MaxInt or past the input left is refused. When
  every item takes at least one byte (AEachItemTakesAByte), a count larger
  than the input left - or than the block's own byte size - cannot be true
  and is refused before the loop starts. ABlockSize is the byte size, or -1
  when the block did not carry one. }
function GetBlockCount(var AR: TAvroByteReader; AEachItemTakesAByte: Boolean;
  const AWhat: string; out ABlockSize: Integer): Integer;
var
  At, Avail: Integer;
  Raw, Items, Size: Int64;
begin
  ABlockSize := -1;
  At := AR.Position;
  Raw := AR.GetLong;
  if Raw = 0 then Exit(0);
  if Raw = Low(Int64) then
    raise EAvroInputError.CreateFmt(
      'At byte %d: %s declares a block count of %d, which has no item count ' +
      '(a negative count is its absolute value in items).', [At, AWhat, Raw]);
  if Raw < 0 then
  begin
    Items := -Raw;
    Size := AR.GetLong;
    if (Size < 0) or (Size > MaxInt) or (Size > AR.Remaining) then
      raise EAvroInputError.CreateFmt(
        'At byte %d: %s declares a block of %d bytes, and %d bytes are left.',
        [At, AWhat, Size, AR.Remaining]);
    ABlockSize := Integer(Size);
  end
  else
    Items := Raw;
  if Items > MaxInt then
    raise EAvroInputError.CreateFmt(
      'At byte %d: %s declares a block of %d items, more than this reader ' +
      'can hold (%d).', [At, AWhat, Items, MaxInt]);
  { The bytes the items must fit in: the block's own size when it has one
    (already checked to be within the input left), else the input left. }
  if ABlockSize >= 0 then Avail := ABlockSize else Avail := AR.Remaining;
  if AEachItemTakesAByte and (Items > Avail) then
    raise EAvroInputError.CreateFmt(
      'At byte %d: %s declares a block of %d items, each at least one byte, ' +
      'and only %d bytes are there for them.', [At, AWhat, Items, Avail]);
  Result := Integer(Items);
end;

procedure SkipDatumBody(var AR: TAvroByteReader; AWriter: TAvroSchema); forward;

procedure SkipDatum(var AR: TAvroByteReader; AWriter: TAvroSchema);
begin
  EnterDatum(AR);
  try
    SkipDatumBody(AR, AWriter);
  finally
    Dec(AR.Depth);
  end;
end;

procedure SkipDatumBody(var AR: TAvroByteReader; AWriter: TAvroSchema);
var
  I, N: Integer;
  Count: Int64;
  Size: Integer;
begin
  case AWriter.SchemaType of
    TAvroType.Null: ;
    TAvroType.Bool: AR.Skip(1);
    TAvroType.Int: GetIntDatum(AR, 'a field the reader''s schema drops');
    TAvroType.Long, TAvroType.Enum: AR.GetLong;
    TAvroType.Float: AR.Skip(4);
    TAvroType.Double: AR.Skip(8);
    TAvroType.Bytes, TAvroType.Str: AR.GetBytes;
    TAvroType.Fixed: AR.Skip(AWriter.Size);
    TAvroType.Rec:
      for I := 0 to AWriter.FieldCount - 1 do
        SkipDatum(AR, AWriter.Fields[I].FieldType);
    TAvroType.Arr, TAvroType.Map:
      repeat
        N := GetBlockCount(AR, (AWriter.SchemaType = TAvroType.Map) or
          not AvroDatumCanBeEmpty(AWriter.ItemType), 'a skipped ' +
          AWriter.TypeName, Size);
        if N = 0 then Break;
        if Size >= 0 then
        begin
          { A negative count is followed by the block's byte size, which is
            exactly what makes skipping cheap. }
          AR.Skip(Size);
          Continue;
        end;
        for I := 1 to N do
        begin
          if AWriter.SchemaType = TAvroType.Map then AR.GetBytes;
          if AWriter.SchemaType = TAvroType.Map then
            SkipDatum(AR, AWriter.ValueType)
          else
            SkipDatum(AR, AWriter.ItemType);
        end;
      until False;
    TAvroType.Union:
      begin
        Count := AR.GetLong;
        if (Count < 0) or (Count >= AWriter.BranchCount) then
          raise EAvroInputError.CreateFmt(
            'A union branch index of %d, and the schema has %d branches.',
            [Count, AWriter.BranchCount]);
        SkipDatum(AR, AWriter.Branches[Integer(Count)]);
      end;
  end;
end;

function ReadDatumBody(var AR: TAvroByteReader; AWriter, AReader: TAvroSchema;
  const APath: string): TAvroValue; forward;

function ReadDatum(var AR: TAvroByteReader; AWriter, AReader: TAvroSchema;
  const APath: string): TAvroValue;
begin
  EnterDatum(AR);
  try
    Result := ReadDatumBody(AR, AWriter, AReader, APath);
  finally
    Dec(AR.Depth);
  end;
end;

function ReadDatumBody(var AR: TAvroByteReader; AWriter, AReader: TAvroSchema;
  const APath: string): TAvroValue;
var
  I, J, N, BlockSize: Integer;
  Count, Index: Int64;
  Field, ReaderField: TAvroField;
  Child: TAvroValue;
  Raw: TBytes;
  Sym: string;
  Name: string;
  Target: TAvroSchema;
  Seen: TStringList;
begin
  Target := MatchReader(AWriter, AReader);
  if (AReader <> nil) and (Target = nil) then
    raise EAvroResolutionError.CreateFmt(
      'At %s: the writer wrote %s and the reader expects %s. Avro resolves ' +
      'only the promotions the specification lists, and this is not one of ' +
      'them.', [APath, AWriter.TypeName, AReader.TypeName]);

  case AWriter.SchemaType of
    TAvroType.Null: Exit(TAvroValue.NewNull);

    TAvroType.Bool: Exit(TAvroValue.NewBool(AR.GetByte <> 0));

    TAvroType.Int, TAvroType.Long:
      begin
        if AWriter.SchemaType = TAvroType.Int then
          Count := GetIntDatum(AR, APath)
        else
          Count := AR.GetLong;
        if AWriter.LogicalType in [TAvroLogicalType.Date,
          TAvroLogicalType.TimeMillis, TAvroLogicalType.TimeMicros,
          TAvroLogicalType.TimestampMillis, TAvroLogicalType.TimestampMicros,
          TAvroLogicalType.LocalTimestampMillis,
          TAvroLogicalType.LocalTimestampMicros] then
          Exit(TAvroValue.NewExactDateTime(
            RawToDateTime(Count, AWriter.LogicalType),
            AWriter.LogicalType, Count));
        if (Target <> nil) and (Target.SchemaType = TAvroType.Float) then
          Exit(TAvroValue.NewFloat(Count));
        if (Target <> nil) and (Target.SchemaType = TAvroType.Double) then
          Exit(TAvroValue.NewDouble(Count));
        if AWriter.SchemaType = TAvroType.Int then
          Exit(TAvroValue.NewInt(Integer(Count)));
        Exit(TAvroValue.NewLong(Count));
      end;

    TAvroType.Float:
      begin
        if (Target <> nil) and (Target.SchemaType = TAvroType.Double) then
          Exit(TAvroValue.NewDouble(AR.GetFloat));
        Exit(TAvroValue.NewFloat(AR.GetFloat));
      end;

    TAvroType.Double: Exit(TAvroValue.NewDouble(AR.GetDouble));

    TAvroType.Bytes:
      begin
        Raw := AR.GetBytes;
        if AWriter.LogicalType = TAvroLogicalType.Decimal then
          Exit(TAvroValue.NewDecimal(
            UnscaledToDecimalText(Raw, AWriter.Scale)));
        if (Target <> nil) and (Target.SchemaType = TAvroType.Str) then
          Exit(TAvroValue.NewStr(Utf8BytesToString(Raw)));
        Exit(TAvroValue.NewBytes(Raw));
      end;

    TAvroType.Str:
      begin
        Raw := AR.GetBytes;
        if (Target <> nil) and (Target.SchemaType = TAvroType.Bytes) then
          Exit(TAvroValue.NewBytes(Raw));
        Exit(TAvroValue.NewStr(Utf8BytesToString(Raw)));
      end;

    TAvroType.Fixed:
      begin
        Raw := AR.GetRaw(AWriter.Size);
        if AWriter.LogicalType = TAvroLogicalType.Decimal then
          Exit(TAvroValue.NewDecimal(
            UnscaledToDecimalText(Raw, AWriter.Scale)));
        if (AWriter.LogicalType = TAvroLogicalType.Duration) and
           (Length(Raw) = 12) then
          Exit(TAvroValue.NewDuration(PCardinal(@Raw[0])^,
            PCardinal(@Raw[4])^, PCardinal(@Raw[8])^));
        Exit(TAvroValue.NewFixed(Raw));
      end;

    TAvroType.Enum:
      begin
        Index := AR.GetLong;
        if (Index < 0) or (Index > High(AWriter.Symbols)) then
          raise EAvroInputError.CreateFmt(
            'At %s: an enum index of %d, and the writer''s schema has %d ' +
            'symbols.', [APath, Index, Length(AWriter.Symbols)]);
        Sym := AWriter.Symbols[Index];
        if (Target <> nil) and (Target.IndexOfSymbol(Sym) < 0) then
        begin
          { The writer used a symbol the reader has never heard of. The
            reader's own default is the specification's answer; without one
            there is nothing honest to return. }
          if Target.HasEnumDefault then Exit(TAvroValue.NewEnum(Target.EnumDefault));
          raise EAvroResolutionError.CreateFmt(
            'At %s: the writer wrote the symbol "%s" and the reader''s enum ' +
            '%s does not list it and has no default.',
            [APath, Sym, Target.TypeName]);
        end;
        Exit(TAvroValue.NewEnum(Sym));
      end;

    TAvroType.Rec:
      begin
        Result := TAvroValue.NewRecord;
        Seen := TStringList.Create;
        try
          { Avro names are case-sensitive: "name" and "Name" are two fields. }
          Seen.CaseSensitive := True;
          for I := 0 to AWriter.FieldCount - 1 do
          begin
            Field := AWriter.Fields[I];
            ReaderField := nil;
            if Target <> nil then
            begin
              ReaderField := Target.FindField(Field.Name);
              if ReaderField = nil then
                for J := 0 to Target.FieldCount - 1 do
                  if Target.Fields[J].Matches(Field.Name) then
                  begin
                    ReaderField := Target.Fields[J];
                    Break;
                  end;
            end;
            if (Target <> nil) and (ReaderField = nil) then
            begin
              { The reader dropped this field. The bytes still have to go
                past, or everything after it is read at the wrong offset. }
              SkipDatum(AR, Field.FieldType);
              Continue;
            end;
            if ReaderField <> nil then
            begin
              Child := ReadDatum(AR, Field.FieldType, ReaderField.FieldType,
                APath + '.' + Field.Name);
              Result.Add(ReaderField.Name, Child);
              Seen.Add(ReaderField.Name);
            end
            else
            begin
              Child := ReadDatum(AR, Field.FieldType, nil,
                APath + '.' + Field.Name);
              Result.Add(Field.Name, Child);
              Seen.Add(Field.Name);
            end;
          end;

          { And the fields the reader wants that the writer never wrote. }
          if Target <> nil then
            for J := 0 to Target.FieldCount - 1 do
              if Seen.IndexOf(Target.Fields[J].Name) < 0 then
                Result.Add(Target.Fields[J].Name,
                  DefaultToValue(Target.Fields[J].FieldType,
                    Target.Fields[J].Default,
                    APath + '.' + Target.Fields[J].Name));
        except
          Seen.Free;
          Result.Free;
          raise;
        end;
        Seen.Free;
        Exit;
      end;

    TAvroType.Arr:
      begin
        Result := TAvroValue.NewArray;
        try
          repeat
            { A block's byte size, when it has one, is checked and then not
              needed: the items are read one by one. }
            N := GetBlockCount(AR, not AvroDatumCanBeEmpty(AWriter.ItemType),
              'the array at ' + APath, BlockSize);
            if N = 0 then Break;
            for I := 1 to N do
            begin
              if Target <> nil then
                Result.Add(ReadDatum(AR, AWriter.ItemType, Target.ItemType,
                  Format('%s[%d]', [APath, Result.Count])))
              else
                Result.Add(ReadDatum(AR, AWriter.ItemType, nil,
                  Format('%s[%d]', [APath, Result.Count])));
            end;
          until False;
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;

    TAvroType.Map:
      begin
        Result := TAvroValue.NewMap;
        try
          repeat
            { Every map entry starts with its key's length: one byte at
              least, whatever the values are. }
            N := GetBlockCount(AR, True, 'the map at ' + APath, BlockSize);
            if N = 0 then Break;
            for I := 1 to N do
            begin
              Name := AR.GetString;
              if Target <> nil then
                Result.Add(Name, ReadDatum(AR, AWriter.ValueType,
                  Target.ValueType, APath + '.' + Name))
              else
                Result.Add(Name, ReadDatum(AR, AWriter.ValueType, nil,
                  APath + '.' + Name));
            end;
          until False;
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;

    TAvroType.Union:
      begin
        Index := AR.GetLong;
        if (Index < 0) or (Index >= AWriter.BranchCount) then
          raise EAvroInputError.CreateFmt(
            'At %s: a union branch index of %d, and the writer''s schema ' +
            'has %d branches.', [APath, Index, AWriter.BranchCount]);
        Exit(ReadDatum(AR, AWriter.Branches[Integer(Index)], AReader, APath));
      end;
  end;
  raise EAvroInternalError.CreateFmt('At %s: cannot read %s.',
    [APath, AWriter.TypeName]);
end;

{ ===========================================================================
  TAvroEngine
  =========================================================================== }

class constructor TAvroEngine.Create;
begin
  FLock := TCriticalSection.Create;
  FEnumMappings := TDictionary<string, TArray<string>>.Create;
  FTypeSerializers := TDictionary<string, TAvroValueSerializerClass>.Create;
  FSchemas := TObjectDictionary<string, TAvroSchema>.Create([doOwnsValues]);
end;

class destructor TAvroEngine.Destroy;
begin
  FSchemas.Free;
  FTypeSerializers.Free;
  FEnumMappings.Free;
  FLock.Free;
end;

class procedure TAvroEngine.CheckNotFrozen;
begin
  if FFrozen then
    raise EAvroInternalError.Create(
      'The Avro configuration is frozen. FreezeConfiguration is the point ' +
      'at which every setting stops moving, so that nothing registered ' +
      'afterwards can silently change the schema an already-running thread ' +
      'is writing against.');
end;

class function TAvroEngine.EncodeDatum(ASchema: TAvroSchema;
  AValue: TAvroValue): TBytes;
var
  W: TAvroByteWriter;
begin
  W.Init;
  WriteDatum(W, ASchema, AValue, '$');
  Result := W.Done;
end;

class function TAvroEngine.DecodeDatum(const AData: TBytes;
  AWriter, AReader: TAvroSchema): TAvroValue;
var
  R: TAvroByteReader;
begin
  if AWriter = nil then
    raise ESerializationSchemaRequired.CreateFor(TSerializationFormat.Avro,
      'decoding a datum');
  R.Init(AData);
  Result := ReadDatum(R, AWriter, AReader, '$');
  { A bare datum is exactly its bytes. Bytes left over mean the schema it
    was read with is not the one it was written with - Avro bytes carry no
    types, so a double read as a float reads four of its eight bytes and
    finds nothing wrong - or that something else was appended. Either way
    the value just read is not the document's. }
  if not R.AtEnd then
  begin
    FreeAndNil(Result);
    raise EAvroInputError.CreateFmt(
      'The datum ends after %d of %d bytes. Either it was read with a ' +
      'schema other than the one it was written with, or something follows ' +
      'it; a bare Avro datum is exactly its bytes.',
      [R.Position, Length(AData)]);
  end;
end;

class procedure TAvroEngine.RegisterEnumMapping(ATypeInfo: PTypeInfo;
  const ASymbols: array of string);
var
  Copy_: TArray<string>;
  I: Integer;
begin
  CheckNotFrozen;
  SetLength(Copy_, Length(ASymbols));
  for I := 0 to Integer(High(ASymbols)) do Copy_[I] := ASymbols[I];
  FLock.Enter;
  try
    FEnumMappings.AddOrSetValue(TypeKeyOf(ATypeInfo), Copy_);
  finally
    FLock.Leave;
  end;
end;

class function TAvroEngine.TryGetEnumMapping(ATypeInfo: PTypeInfo;
  out AValues: TArray<string>): Boolean;
begin
  AValues := nil;
  if ATypeInfo = nil then Exit(False);
  FLock.Enter;
  try
    Result := FEnumMappings.TryGetValue(TypeKeyOf(ATypeInfo), AValues);
  finally
    FLock.Leave;
  end;
end;

class procedure TAvroEngine.RegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TAvroValueSerializerClass);
begin
  CheckNotFrozen;
  FLock.Enter;
  try
    FTypeSerializers.AddOrSetValue(TypeKeyOf(ATypeInfo), ASerializerClass);
  finally
    FLock.Leave;
  end;
end;

class function TAvroEngine.TryGetTypeSerializer(ATypeInfo: PTypeInfo;
  out AClass: TAvroValueSerializerClass): Boolean;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  AClass := nil;
  if ATypeInfo = nil then Exit(False);
  FLock.Enter;
  try
    Result := FTypeSerializers.TryGetValue(TypeKeyOf(ATypeInfo), AClass);
  finally
    FLock.Leave;
  end;
end;

class procedure TAvroEngine.FreezeConfiguration;
begin
  FFrozen := True;
end;

class function TAvroEngine.IsFrozen: Boolean;
begin
  Result := FFrozen;
end;

class procedure TAvroEngine.ResetConfiguration;
begin
  FFrozen := False;
  FLock.Enter;
  try
    FEnumMappings.Clear;
    FTypeSerializers.Clear;
    FSchemas.Clear;
  finally
    FLock.Leave;
  end;
end;

{ The schema of one field of a record schema, or nil. A nil means the walk
  is running without a schema to follow, which the contract path never is. }
function FieldSchema(ASchema: TAvroSchema; const AName: string): TAvroSchema;
var
  F: TAvroField;
begin
  Result := nil;
  if (ASchema = nil) or (ASchema.SchemaType <> TAvroType.Rec) then Exit;
  F := ASchema.FindField(AName);
  if F <> nil then Result := F.FieldType;
end;

{ The item schema of an array schema, or nil. }
function ItemSchema(ASchema: TAvroSchema): TAvroSchema;
begin
  Result := nil;
  if (ASchema <> nil) and (ASchema.SchemaType = TAvroType.Arr) then
    Result := ASchema.ItemType;
end;

{ The value schema of a map schema, or nil. }
function MapValueSchema(ASchema: TAvroSchema): TAvroSchema;
begin
  Result := nil;
  if (ASchema <> nil) and (ASchema.SchemaType = TAvroType.Map) then
    Result := ASchema.ItemType;
end;

{ A dictionary, seen through RTTI: a two-argument AddOrSetValue and a
  ToArray that yields key/value pairs. The same test every other engine in
  this library uses, so the same Delphi types are recognised everywhere.

  It matters more here than elsewhere: a dictionary walked as a RECORD reads
  TDictionary's own private layout - its notify events, its comparer, its
  bucket array - and asks Avro to describe them. }
function DictionaryMethodsOf(AType: TRttiType;
  out AAddOrSet, AToArray, ACreate: TRttiMethod;
  out AKey, AValue: TRttiType): Boolean;
var
  Access: TDictionaryAccess;
begin
  { CORE ANSWERS THIS, and this is the adapter that reshapes its answer into
    the locals the walks below already use.

    Recognition is by ancestry, once, in TSerializationTypes - never by
    probing the method list, which recognises more than it should and
    nothing at all for a container whose methods are inherited under other
    names. }
  AAddOrSet := nil;
  AToArray := nil;
  ACreate := nil;
  AKey := nil;
  AValue := nil;
  Result := False;
  if AType = nil then Exit;
  if not TSerializationTypes.TryGetDictionaryAccess(AType.Handle, Access) then
    Exit;
  AAddOrSet := Access.AddOrSetMethod;
  AToArray := Access.ToArrayMethod;
  ACreate := Access.CreateMethod;
  AKey := GCtx.GetType(Access.KeyType);
  AValue := GCtx.GetType(Access.ValueType);
  Result := True;
end;



{ ===========================================================================
  THE SCHEMA A DELPHI TYPE GENERATES

  The schema is produced as JSON TEXT and then parsed, rather than assembled
  as an object graph. That is deliberate: the parser is the one place that
  decides what a well-formed schema is, and going through it means a
  generated schema is checked by exactly the same rules as one that arrived
  from somebody else. A generator that built the graph directly could
  produce something the parser would have refused.
  =========================================================================== }

function AvroNameOf(const ADelphiName: string): string;
var
  I: Integer;
begin
  { An Avro name is [A-Za-z_][A-Za-z0-9_]*. Delphi identifiers already are,
    except for the generic mangling - TList`1<...> - which has to go. }
  Result := '';
  for I := 1 to Length(ADelphiName) do
    if CharInSet(ADelphiName[I], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Result := Result + ADelphiName[I]
    else
      Result := Result + '_';
  if (Result = '') or not CharInSet(Result[1], ['A'..'Z', 'a'..'z', '_']) then
    Result := '_' + Result;
end;

function JsonQuote(const AText: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '"';
  for I := 1 to Length(AText) do
  begin
    C := AText[I];
    case C of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8:  Result := Result + '\b';
      #9:  Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if C < ' ' then
        Result := Result + '\u' + LowerCase(IntToHex(Ord(C), 4))
      else
        Result := Result + C;
    end;
  end;
  Result := Result + '"';
end;

type
  { The names already written into this schema. Avro forbids defining a name
    twice, so the second appearance of a record type is a REFERENCE to it -
    which is also how a recursive type is expressed at all. }
  TAvroNameSet = class(TStringList)
  public
    constructor Create;
  end;

constructor TAvroNameSet.Create;
begin
  inherited Create;
  CaseSensitive := True;
  Sorted := True;
  Duplicates := dupIgnore;
end;

function MemberAvroName(AMember: TRttiMember): string;
var
  Attr: TCustomAttribute;
begin
  if AMember = nil then Exit('');
  for Attr in AMember.GetAttributes do
    if Attr is AvroNameAttribute then Exit(AvroNameAttribute(Attr).Name);
  { [AvroName] beats [SerializationName], which beats the Delphi name. }
  if not TSerializationMetadata.GeneralName(AMember, Result) then
    Result := AMember.Name;
end;

function MemberIgnored(AMember: TRttiMember): Boolean;
var
  Attr: TCustomAttribute;
begin
  Result := False;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is AvroIgnoreAttribute then Exit(True);
end;

function MemberAliases(AMember: TRttiMember): TArray<string>;
var
  Attr: TCustomAttribute;
begin
  Result := nil;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is AvroAliasesAttribute then
      Exit(AvroAliasesAttribute(Attr).Names);
end;

function MemberSerializerOf(AMember: TRttiMember): TAvroValueSerializerClass;
var
  Attr: TCustomAttribute;
begin
  Result := nil;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is AvroSerializerAttribute then
      Exit(AvroSerializerAttribute(Attr).SerializerClass);
end;

{ The shared surface - public fields and readable properties, a
  redeclared name once - minus read-only properties, which a schema-driven
  record cannot round-trip, and minus those ignored in general or by this
  format's own ignore attribute. }
function MembersOf(AType: TRttiType): TArray<TRttiMember>;
var
  List: TList<TRttiMember>;
  M: TSerializationMember;
begin
  List := TList<TRttiMember>.Create;
  try
    for M in TSerializationMetadata.Get(AType.Handle).Members do
      if not M.Ignored and M.IsWritable and not MemberIgnored(M.Member) then
        List.Add(M.Member);
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

function MemberTypeOf(AMember: TRttiMember): TRttiType;
begin
  if AMember is TRttiField then Result := TRttiField(AMember).FieldType
  else if AMember is TRttiProperty then
    Result := TRttiProperty(AMember).PropertyType
  else Result := nil;
end;

function MemberValueOf(AMember: TRttiMember; const AInstance: TValue): TValue;
begin
  { RTTI takes an untyped instance pointer, and an object's is the reference
    itself. }
  if AMember is TRttiField then
  begin
    if AInstance.IsObject then
      {$WARN UNSAFE_CAST OFF}
      Result := TRttiField(AMember).GetValue(AInstance.AsObject)
      {$WARN UNSAFE_CAST ON}
    else
      Result := TRttiField(AMember).GetValue(AInstance.GetReferenceToRawData);
  end
  else if AMember is TRttiProperty then
  begin
    if AInstance.IsObject then
      {$WARN UNSAFE_CAST OFF}
      Result := TRttiProperty(AMember).GetValue(AInstance.AsObject)
      {$WARN UNSAFE_CAST ON}
    else
      Result := TRttiProperty(AMember).GetValue(
        AInstance.GetReferenceToRawData);
  end
  else
    Result := TValue.Empty;
end;

{ The object a member already holds, for the reader to fill in place, as
  every other format does. Passing nothing made the reader construct a
  second one and store it over the first, which nothing then referred to -
  the child list a constructor makes is the everyday case, and it leaked on
  every read.

  And the record a member already holds, which is merged in place the same
  way: read from a zeroed record, the objects a constructor or the caller
  put in it were replaced and orphaned, and the members the document omits
  were reset. An array is replaced, not merged, so it gets nothing. }
function ExistingValueOf(AMember: TRttiMember; const AInstance: TValue): TValue;
var
  T: TRttiType;
begin
  Result := TValue.Empty;
  T := MemberTypeOf(AMember);
  if (T = nil) or not (T.TypeKind in [tkClass, tkRecord, tkMRecord]) then Exit;
  Result := MemberValueOf(AMember, AInstance);
  if Result.IsObject and (Result.AsObject = nil) then Result := TValue.Empty;
end;

procedure SetMemberValueOf(AMember: TRttiMember; const AInstance: TValue;
  const AValue: TValue);
begin
  if AValue.IsEmpty then Exit;
  { RTTI takes an untyped instance pointer, and an object's is the reference
    itself. }
  if AMember is TRttiField then
  begin
    if AInstance.IsObject then
      {$WARN UNSAFE_CAST OFF}
      TRttiField(AMember).SetValue(AInstance.AsObject, AValue)
      {$WARN UNSAFE_CAST ON}
    else
      TRttiField(AMember).SetValue(AInstance.GetReferenceToRawData, AValue);
  end
  else if (AMember is TRttiProperty) and TRttiProperty(AMember).IsWritable then
  begin
    if AInstance.IsObject then
      {$WARN UNSAFE_CAST OFF}
      TRttiProperty(AMember).SetValue(AInstance.AsObject, AValue)
      {$WARN UNSAFE_CAST ON}
    else
      TRttiProperty(AMember).SetValue(AInstance.GetReferenceToRawData, AValue);
  end;
end;

{ The element type of a dynamic array, or nil. }
function ElementTypeOf(AType: TRttiType): TRttiType;
begin
  Result := nil;
  if (AType = nil) or (AType.TypeKind <> tkDynArray) then Exit;
  if GetTypeData(AType.Handle).DynArrElType = nil then Exit;
  Result := GCtx.GetType(GetTypeData(AType.Handle).DynArrElType^);
end;

{ A TList-shaped class: one that has both Add(x) and ToArray. }
function ListMethodsOf(AType: TRttiType; out AAdd, AToArray, ACreate: TRttiMethod;
  out AItem: TRttiType): Boolean;
var
  Access: TListAccess;
begin
  { Core answers this; see the note on DictionaryMethodsOf above. }
  AAdd := nil;
  AToArray := nil;
  ACreate := nil;
  AItem := nil;
  Result := False;
  if AType = nil then Exit;
  if not TSerializationTypes.TryGetListAccess(AType.Handle, Access) then Exit;
  AAdd := Access.AddMethod;
  AToArray := Access.ToArrayMethod;
  ACreate := Access.CreateMethod;
  AItem := GCtx.GetType(Access.ElementType);
  Result := True;
end;

function SchemaJsonOf(AType: TRttiType; AMember: TRttiMember;
  ANames: TAvroNameSet; const APath: string): string; forward;

{ The namespace of a named type: its unit. Taken from the qualified name by
  removing the type's own name from the end - NOT by cutting at the last
  dot, which for TGenericRecord<System.Integer> cut inside the brackets and
  produced a namespace no Avro reader accepts. }
function AvroNamespaceOf(AType: TRttiType): string;
var
  Q: string;
begin
  Result := '';
  if AType is TRttiInstanceType then
    Exit(TRttiInstanceType(AType).MetaclassType.UnitName);
  { Never QualifiedName directly: it raises the RTL's ENonPublicType for a
    type declared in a program or an implementation section, and such a
    type simply has no namespace. }
  if not TryTypeQualifiedName(AType.Handle, Q) then Exit;
  if Q.EndsWith('.' + AType.Name) then
    Result := Copy(Q, 1, Length(Q) - Length(AType.Name) - 1);
end;

{ A class Avro can write must be one it can read back: a schema-driven
  format has no factory to build an instance another way. A class with no
  parameterless constructor - Exception, TComponent - is refused while the
  schema is written, rather than written and then unreadable. }
procedure RequireConstructible(AType: TRttiType; const APath: string);
begin
  if TSerializationTypes.DefaultConstructor(AType) = nil then
    raise EAvroError.CreateFmt(
      'At %s: %s has no parameterless constructor, so Avro could write it but ' +
      'never read it back. Register an Avro type serializer for it, or carry ' +
      'the values in a class that has one.', [APath, AType.Name]);
end;

{ Whether a member can be written at all, asked from its TYPE before its
  getter is called: TComponent's ComObject getter used to run, and raise,
  before anything had looked at what the member was. }
procedure RefuseUnwritableMember(AMember: TRttiMember; AType: TRttiType;
  const APath: string);
var
  Why: string;
  SerCls: TAvroValueSerializerClass;
begin
  if MemberSerializerOf(AMember) <> nil then Exit;
  if AType = nil then
    raise EAvroError.CreateFmt(
      'At %s: %s %s. Leave it out with [AvroIgnore], or register an Avro ' +
      'type serializer for the type that holds it.',
      [APath, AMember.Name, TSerializationTypes.UnsupportedReason(nil)]);
  if TAvroEngine.TryGetTypeSerializer(AType.Handle, SerCls) then Exit;
  Why := TSerializationTypes.UnsupportedReason(AType.Handle);
  if Why <> '' then
    raise EAvroError.CreateFmt(
      'At %s: %s %s. Leave it out with [AvroIgnore], or register an Avro ' +
      'type serializer for its type.', [APath, AMember.Name, Why]);
end;

{ A map key as the text an Avro map requires, and back. The Delphi type
  says what the key really is, so an Integer key written as "42" reads back
  as 42 - the same bargain JSON makes with its object keys. }
function IsTextKeyType(AType: TRttiType): Boolean;
begin
  Result := (AType <> nil) and
    ((AType.TypeKind in [tkString, tkLString, tkWString, tkUString, tkChar,
       tkWChar, tkInteger, tkInt64, tkEnumeration]) or
     (AType.Handle = System.TypeInfo(TGUID)));
end;

function KeyToText(AType: TRttiType; const AKey: TValue): string;
begin
  if AType.Handle = System.TypeInfo(TGUID) then
    Exit(LowerCase(Copy(GUIDToString(AKey.AsType<TGUID>), 2, 36)));
  case AType.TypeKind of
    tkInteger, tkInt64: Result := TSerializationTypes.IntegerText(AKey);
    tkEnumeration:
      if AType.Handle = System.TypeInfo(Boolean) then
        Result := LowerCase(BoolToStr(AKey.AsBoolean, True))
      else
        Result := GetEnumName(AType.Handle, Integer(AKey.AsOrdinal));
  else
    Result := AKey.AsString;
  end;
end;

function TextToKey(AType: TRttiType; const AText, APath: string): TValue;
var
  Ordinal: Integer;
  Why: string;
begin
  if AType.Handle = System.TypeInfo(TGUID) then
  begin
    try
      Exit(TValue.From<TGUID>(StringToGUID('{' + AText + '}')));
    except
      on E: EConvertError do
        raise EAvroInputError.CreateFmt('At %s: "%s" is not a GUID.',
          [APath, AText]);
    end;
  end;
  case AType.TypeKind of
    tkInteger, tkInt64:
      if not TSerializationTypes.TryIntegerFromText(AType.Handle, AText,
           Result) then
        raise EAvroInputError.CreateFmt('At %s: the key "%s" is not a %s.',
          [APath, AText, AType.Name]);
    tkEnumeration:
      begin
        if AType.Handle = System.TypeInfo(Boolean) then
          Exit(TValue.From<Boolean>(SameText(AText, 'true')));
        Ordinal := GetEnumValue(AType.Handle, AText);
        if Ordinal < 0 then
          raise EAvroInputError.CreateFmt('At %s: the key "%s" is not a %s.',
            [APath, AText, AType.Name]);
        Result := TValue.FromOrdinal(AType.Handle, Ordinal);
      end;
  else
    if not TSerializationTypes.TryStringFromText(AType.Handle, AText, Result,
         Why) then
      raise EAvroInputError.CreateFmt('At %s: %s.', [APath, Why]);
  end;
end;

{ The Avro schema of one record or class, as JSON. }
function RecordSchemaJson(AType: TRttiType; ANames: TAvroNameSet;
  const APath: string): string;
var
  Members: TArray<TRttiMember>;
  M: TRttiMember;
  FullName, Namespace, Name: string;
  Fields: string;
  Aliases: TArray<string>;
  I: Integer;
begin
  Name := AvroNameOf(AType.Name);
  Namespace := AvroNamespaceOf(AType);
  if Namespace = '' then FullName := Name else FullName := Namespace + '.' + Name;

  { The second appearance of a named type is a reference to it, which is what
    Avro requires and what makes a recursive type expressible at all. }
  if ANames.IndexOf(FullName) >= 0 then Exit(JsonQuote(FullName));
  ANames.Add(FullName);

  if AType is TRttiInstanceType then RequireConstructible(AType, APath);
  Fields := '';
  Members := MembersOf(AType);
  for M in Members do
  begin
    RefuseUnwritableMember(M, MemberTypeOf(M), APath + '.' + M.Name);
    if Fields <> '' then Fields := Fields + ',';
    Fields := Fields + '{"name":' + JsonQuote(MemberAvroName(M)) +
      ',"type":' + SchemaJsonOf(MemberTypeOf(M), M, ANames,
        APath + '.' + M.Name);
    Aliases := MemberAliases(M);
    if Length(Aliases) > 0 then
    begin
      Fields := Fields + ',"aliases":[';
      for I := 0 to Integer(High(Aliases)) do
      begin
        if I > 0 then Fields := Fields + ',';
        Fields := Fields + JsonQuote(Trim(Aliases[I]));
      end;
      Fields := Fields + ']';
    end;
    Fields := Fields + '}';
  end;

  Result := '{"type":"record","name":' + JsonQuote(Name);
  if Namespace <> '' then
    Result := Result + ',"namespace":' + JsonQuote(Namespace);
  Result := Result + ',"fields":[' + Fields + ']}';
end;

function SchemaJsonOf(AType: TRttiType; AMember: TRttiMember;
  ANames: TAvroNameSet; const APath: string): string;
var
  Access: TNullableAccess;
  Symbols: TArray<string>;
  I: Integer;
  Name, Namespace, FullName: string;
  Add, ToArray, Create_, AddOrSet: TRttiMethod;
  Item, Key: TRttiType;
  SerCls: TAvroValueSerializerClass;
  TypeData: PTypeData;
begin
  { Nothing to describe: refused, rather than described as "null" and left
    for the RTL to fail on with EInsufficientRtti. }
  if AType = nil then
    raise EAvroError.CreateFmt(
      'At %s: %s. Leave it out with [AvroIgnore], or register an Avro type ' +
      'serializer for the type that holds it.',
      [APath, TSerializationTypes.UnsupportedReason(nil)]);

  SerCls := MemberSerializerOf(AMember);
  if SerCls = nil then TAvroEngine.TryGetTypeSerializer(AType.Handle, SerCls);
  if SerCls <> nil then Exit(SerCls.SchemaJson);

  { A nullable is a union of null and its value, with NULL FIRST - which is
    not decoration: the specification says a union's default is a value of
    its first branch, so null-first is what makes an absent value the
    default. }
  if TSerializationTypes.TryGetNullableAccess(AType.Handle, Access) then
    Exit('["null",' +
      SchemaJsonOf(GCtx.GetType(Access.ValueType), AMember, ANames, APath) +
      ']');

  if AType.Handle = System.TypeInfo(TGUID) then
    Exit('{"type":"string","logicalType":"uuid"}');
  if AType.Handle = System.TypeInfo(TDateTime) then
    Exit('{"type":"long","logicalType":"timestamp-millis"}');
  if AType.Handle = System.TypeInfo(TDate) then
    Exit('{"type":"int","logicalType":"date"}');
  if AType.Handle = System.TypeInfo(TTime) then
    Exit('{"type":"int","logicalType":"time-millis"}');
  if AType.Handle = System.TypeInfo(Currency) then
    { A Currency is an exact decimal with four places, and Avro's decimal
      logical type is the only thing that keeps it exact. A double would
      lose it, quietly, at the fifteenth digit. }
    Exit('{"type":"bytes","logicalType":"decimal","precision":19,"scale":4}');
  if AType.Handle = System.TypeInfo(TBytes) then Exit('"bytes"');

  case AType.TypeKind of
    { An Avro int is 32 bits SIGNED, so a Cardinal - whose top half it does
      not hold - is a long. It was an int, and 4294967295 went out as -1. }
    tkInteger:
      if GetTypeData(AType.Handle).OrdType = otULong then Exit('"long"')
      else Exit('"int"');
    tkInt64:
      Exit('"long"');
    tkFloat:
      begin
        if GetTypeData(AType.Handle).FloatType = ftSingle then Exit('"float"');
        { Comp is a 64-bit integer RTTI files under tkFloat. }
        if GetTypeData(AType.Handle).FloatType = ftComp then Exit('"long"');
        Exit('"double"');
      end;
    tkChar, tkWChar, tkString, tkLString, tkWString, tkUString:
      Exit('"string"');
    tkEnumeration:
      begin
        if AType.Handle = System.TypeInfo(Boolean) then Exit('"boolean"');

        { THE FULL NAME, and an explicit namespace - exactly as a record
          gets. A bare name in an Avro schema resolves against the
          ENCLOSING namespace, so an enum defined inside one record and
          referenced from another that sits in a different unit resolved to
          a name nothing had defined, and the schema this library had just
          written would not parse.

          It only showed up where the two records came from different
          units, which is every real model and no small test. }
        Name := AvroNameOf(AType.Name);
        Namespace := AvroNamespaceOf(AType);
        if Namespace = '' then FullName := Name
        else FullName := Namespace + '.' + Name;

        if ANames.IndexOf(FullName) >= 0 then Exit(JsonQuote(FullName));
        ANames.Add(FullName);
        if not TAvroEngine.TryGetEnumMapping(AType.Handle, Symbols) then
        begin
          TypeData := GetTypeData(AType.Handle);
          SetLength(Symbols, TypeData.MaxValue - TypeData.MinValue + 1);
          for I := 0 to Integer(High(Symbols)) do
            Symbols[I] := GetEnumName(AType.Handle, TypeData.MinValue + I);
        end;
        Result := '{"type":"enum","name":' + JsonQuote(Name);
        if Namespace <> '' then
          Result := Result + ',"namespace":' + JsonQuote(Namespace);
        Result := Result + ',"symbols":[';
        for I := 0 to Integer(High(Symbols)) do
        begin
          if I > 0 then Result := Result + ',';
          Result := Result + JsonQuote(AvroNameOf(Symbols[I]));
        end;
        Result := Result + ']}';
        Exit;
      end;
    tkSet:
      { A set is an ARRAY OF ITS ENUM, which is the Avro idiom for "some of
        these". A bitmask would be an int whose meaning lives nowhere in the
        schema, and would break the moment somebody inserted a member into
        the enumeration. }
      { A set of an integer subrange or of characters has no symbols: its
        members are their ordinals, an array of int. }
      if GetTypeData(AType.Handle).CompType^.Kind <> tkEnumeration then
        Exit('{"type":"array","items":"int"}')
      else
        Exit('{"type":"array","items":' +
          SchemaJsonOf(GCtx.GetType(GetTypeData(AType.Handle).CompType^),
            nil, ANames, APath + '[]') + '}');
    tkDynArray:
      Exit('{"type":"array","items":' +
        SchemaJsonOf(ElementTypeOf(AType), nil, ANames, APath + '[]') + '}');
    { A static array is an array of exactly its length, flat in the order
      Delphi stores it; the type restores the shape on the way back. }
    tkArray:
      Exit('{"type":"array","items":' +
        SchemaJsonOf(TRttiArrayType(AType).ElementType, nil, ANames,
          APath + '[]') + '}');
    tkRecord, tkMRecord:
      Exit(RecordSchemaJson(AType, ANames, APath));
    tkClass:
      begin
        { A dictionary is an Avro MAP, which is the idiom Avro has for
          exactly this. Tested before the list test, because a dictionary
          has a ToArray too and would otherwise fall through to the record
          walk and be described by its private layout. }
        if DictionaryMethodsOf(AType, AddOrSet, ToArray, Create_, Key, Item) then
        begin
          { An Avro map has string keys. A key with one text form - an
            integer, an enumeration, a GUID - is written as that text and
            read back through the Delphi type; anything else has none. }
          if not IsTextKeyType(Key) then
            raise EAvroError.CreateFmt(
              'At %s: an Avro map has string keys, and the keys of %s are ' +
              '%s, which has no single text form. Carry the entries as a ' +
              'list of key/value records, or register a serializer.',
              [APath, AType.Name, Key.Name]);
          { NULL-FIRST, like every other class member. A Delphi container is
            an object reference and nil is a state it really has: a nil
            TObjectDictionary is not an empty one, and a schema with no null
            branch cannot tell the caller which they had. Without this the
            round trip turns nil into empty, silently, which is the kind of
            loss that only shows up as a customer's missing section. }
          Exit('["null",{"type":"map","values":' +
            SchemaJsonOf(Item, nil, ANames, APath + '{}') + '}]');
        end;
        if ListMethodsOf(AType, Add, ToArray, Create_, Item) then
        begin
          RequireConstructible(AType, APath);
          Exit('["null",{"type":"array","items":' +
            SchemaJsonOf(Item, nil, ANames, APath + '[]') + '}]');
        end;
        { A class member is a union of null and the record, because a Delphi
          object reference can be nil and an Avro record cannot. }
        Exit('["null",' + RecordSchemaJson(AType, ANames, APath) + ']');
      end;
  end;

  raise EAvroInternalError.CreateFmt(
    'At %s: Avro has no type for %s. Every Avro value has a schema, so a ' +
    'member this library cannot describe cannot be written at all - give it ' +
    'a custom serializer with [AvroSerializer], or leave it out with ' +
    '[AvroIgnore].', [APath, AType.Name]);
end;

class function TAvroEngine.SchemaJsonFor(ATypeInfo: PTypeInfo): string;
var
  Names: TAvroNameSet;
  T, Item: TRttiType;
  Add, ToArray, Create_: TRttiMethod;
begin
  T := GCtx.GetType(ATypeInfo);
  if T = nil then
    raise EAvroInternalError.Create(
      'This type exposes no RTTI, so no Avro schema can be written for it.');
  Names := TAvroNameSet.Create;
  try
    { The ROOT of a contract is the record itself, not a union with null: a
      file of nullable records would make every reader unwrap something that
      is never absent. A LIST at the root is still an array, because that is
      what it is. }
    if (T.TypeKind in [tkRecord, tkMRecord]) or
       ((T.TypeKind = tkClass) and
        (not ListMethodsOf(T, Add, ToArray, Create_, Item))) then
      Result := RecordSchemaJson(T, Names, '$')
    else
      Result := SchemaJsonOf(T, nil, Names, '$');
  finally
    Names.Free;
  end;
end;

class function TAvroEngine.SchemaFor(ATypeInfo: PTypeInfo): TAvroSchema;
var
  Key, Json: string;
begin
  Key := TypeKeyOf(ATypeInfo);
  FLock.Enter;
  try
    if FSchemas.TryGetValue(Key, Result) then Exit;
  finally
    FLock.Leave;
  end;
  Json := SchemaJsonFor(ATypeInfo);
  Result := TAvroSchema.Parse(Json);
  FLock.Enter;
  try
    if FSchemas.ContainsKey(Key) then
    begin
      { Another thread got there first. Its schema is the one every plan
        already points at, so this one is discarded rather than replacing it
        under their feet. }
      Result.Free;
      Result := FSchemas[Key];
    end
    else
      FSchemas.Add(Key, Result);
  finally
    FLock.Leave;
  end;
end;

{ ===========================================================================
  THE CONTRACT WALK

  A Delphi value becomes a TAvroValue guided by the SCHEMA, not by the type
  alone: the schema is what says a Currency is a decimal and an object
  reference is a union, and following it here is what makes the bytes match
  the schema the file carries.
  =========================================================================== }

{ What an error calls a member: its name when there is one, and otherwise
  the type, which is all an array element or a root has. }
function MemberLabel(AMember: TRttiMember; AType: TRttiType): string;
begin
  if AMember <> nil then Exit(AMember.Name);
  if AType <> nil then Exit(AType.Name);
  Result := 'a value';
end;

function ValueToAvro(AType: TRttiType; const AValue: TValue;
  ASchema: TAvroSchema; AMember: TRttiMember;
  const APath: string): TAvroValue; forward;

{ The non-null branch of a nullable union, or the schema itself. }
function NonNullBranch(ASchema: TAvroSchema): TAvroSchema;
var
  I: Integer;
begin
  Result := ASchema;
  if (ASchema = nil) or (ASchema.SchemaType <> TAvroType.Union) then Exit;
  for I := 0 to ASchema.BranchCount - 1 do
    if ASchema.Branches[I].SchemaType <> TAvroType.Null then
      Exit(ASchema.Branches[I]);
end;

{ An object the writer descends into - a class instance, or a list or
  dictionary - through the graph guard, which counts its level and refuses it
  when it is already open further up. Leave pairs with it. }
procedure EnterObject(AObject: TObject; const APath: string);
begin
  if not TSerializationGraphGuard.Enter(AObject) then
    raise EAvroError.CreateFmt(
      'At %s: %s is already being written further up the graph: it is ' +
      'a cycle, and Avro has no back-reference. Break the cycle, or ' +
      'register an Avro type serializer that writes a key instead.',
      [APath, AObject.ClassName]);
end;

function ValueToAvro(AType: TRttiType; const AValue: TValue;
  ASchema: TAvroSchema; AMember: TRttiMember;
  const APath: string): TAvroValue;
var
  Why: string;
  Access: TNullableAccess;
  Inner: TValue;
  Members: TArray<TRttiMember>;
  M: TRttiMember;
  I: Integer;
  Add, ToArray, Create_: TRttiMethod;
  Item: TRttiType;
  Arr: TValue;
  Target: TAvroSchema;
  SerCls: TAvroValueSerializerClass;
  Ser: TCustomAvroValueSerializer;
  Names: TArray<string>;
  Ordinal: Int64;
  ElemInfo: PTypeInfo;
  AddOrSet: TRttiMethod;
  Key: TRttiType;
  PairType, PairElem: TRttiType;
  KeyField, ValueField: TRttiField;
  Pair: TValue;
begin
  if AType = nil then
    raise EAvroError.CreateFmt(
      '%s %s. Leave it out with [AvroIgnore], or register an Avro type ' +
      'serializer for the type that holds it.',
      [MemberLabel(AMember, nil), TSerializationTypes.UnsupportedReason(nil)]);

  SerCls := MemberSerializerOf(AMember);
  if SerCls = nil then TAvroEngine.TryGetTypeSerializer(AType.Handle, SerCls);
  if SerCls <> nil then
  begin
    Ser := SerCls.Create;
    try
      Exit(Ser.Serialize(AValue));
    finally
      Ser.Free;
    end;
  end;

  { Refused, not written: a type with no RTTI must not become null, and a
    pointer, a method, a class reference or an interface must not reach the
    scalar writer, which would write an address as a number. The decision is
    TSerializationTypes.UnsupportedReason, shared by every format, and it
    is asked only after [AvroIgnore] and every custom serializer have had
    their say, so a caller who wants one of these can always have it. }
  Why := TSerializationTypes.UnsupportedReason(AType.Handle);
  if Why <> '' then
    raise EAvroError.CreateFmt(
      '%s %s. Leave it out with [AvroIgnore], or register an Avro type ' +
      'serializer for its type.', [MemberLabel(AMember, AType), Why]);

  if TSerializationTypes.TryGetNullableAccess(AType.Handle, Access) then
  begin
    if not Access.HasValue(AValue.GetReferenceToRawData) then
      Exit(TAvroValue.NewNull);
    Inner := Access.GetValue(AValue.GetReferenceToRawData);
    Exit(ValueToAvro(GCtx.GetType(Access.ValueType), Inner,
      NonNullBranch(ASchema), AMember, APath));
  end;

  Target := NonNullBranch(ASchema);

  if AType.Handle = System.TypeInfo(TGUID) then
    Exit(TAvroValue.NewStr(
      LowerCase(Copy(GUIDToString(AValue.AsType<TGUID>), 2, 36))));
  if (AType.Handle = System.TypeInfo(TDateTime)) or
     (AType.Handle = System.TypeInfo(TDate)) or
     (AType.Handle = System.TypeInfo(TTime)) then
    Exit(TAvroValue.NewDateTime(AValue.AsType<TDateTime>));
  if AType.Handle = System.TypeInfo(Currency) then
    Exit(TAvroValue.NewDecimal(
      CurrToStr(AValue.AsCurrency, TFormatSettings.Invariant)));
  if AType.Handle = System.TypeInfo(TBytes) then
    Exit(TAvroValue.NewBytes(AValue.AsType<TBytes>));

  case AType.TypeKind of
    tkInteger:
      if GetTypeData(AType.Handle).OrdType = otULong then
        Exit(TAvroValue.NewLong(AValue.AsOrdinal))
      else
        Exit(TAvroValue.NewInt(AValue.AsInteger));
    { An Avro long is signed. A UInt64 above High(Int64) is refused rather
      than written as the negative number its bits spell. }
    tkInt64:
      begin
        if TSerializationTypes.IsUnsignedInteger(AType.Handle) and
           (TSerializationTypes.Int64Bits(AValue) < 0) then
          raise EAvroError.CreateFmt(
            'At %s: %s does not fit in an Avro long, which is signed. Keep ' +
            '%s at or below %d, or register an Avro type serializer that ' +
            'writes it as a decimal.',
            [APath, TSerializationTypes.IntegerText(AValue), AType.Name,
             High(Int64)]);
        Exit(TAvroValue.NewLong(TSerializationTypes.Int64Bits(AValue)));
      end;
    tkFloat:
      begin
        if TSerializationTypes.IsCompType(AType.Handle) then
          Exit(TAvroValue.NewLong(TSerializationTypes.Int64Bits(AValue)));
        if GetTypeData(AType.Handle).FloatType = ftSingle then
          Exit(TAvroValue.NewFloat(AValue.AsExtended));
        Exit(TAvroValue.NewDouble(AValue.AsExtended));
      end;
    tkChar, tkWChar, tkString, tkLString, tkWString, tkUString:
      Exit(TAvroValue.NewStr(AValue.AsString));
    tkEnumeration:
      begin
        if AType.Handle = System.TypeInfo(Boolean) then
          Exit(TAvroValue.NewBool(AValue.AsBoolean));
        Ordinal := AValue.AsOrdinal;
        if TAvroEngine.TryGetEnumMapping(AType.Handle, Names) and
           (Ordinal >= 0) and (Ordinal <= High(Names)) then
          Exit(TAvroValue.NewEnum(AvroNameOf(Names[Ordinal])));
        Exit(TAvroValue.NewEnum(
          AvroNameOf(GetEnumName(AType.Handle, Integer(Ordinal)))));
      end;
    tkSet:
      begin
        { The bits, read from the value's own storage and bounded by the
          element type's range and the value's size. TValue.AsOrdinal raises
          for a set, and a set wider than four bytes has no ordinal at all. }
        ElemInfo := GetTypeData(AType.Handle).CompType^;
        Result := TAvroValue.NewArray;
        try
          { Through TSerializationTypes: bit 0 is the byte holding the
            lowest member, not ordinal 0. }
          for I in TSerializationTypes.SetOrdinals(AType.Handle, AValue) do
            if ElemInfo.Kind <> tkEnumeration then
              Result.Add(TAvroValue.NewInt(I))
            else
              Result.Add(TAvroValue.NewEnum(AvroNameOf(GetEnumName(ElemInfo, I))));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
    { A record, and an array, count one level each - an object counts its
      own in Enter below: a record type that holds a dynamic array of itself
      nests without any object in it, and ran the writer out of stack. }
    tkDynArray:
      begin
        TSerializationGraphGuard.EnterLevel;
        try
          Result := TAvroValue.NewArray;
          try
            for I := 0 to Integer(AValue.GetArrayLength) - 1 do
              Result.Add(ValueToAvro(ElementTypeOf(AType),
                AValue.GetArrayElement(I),
                ItemSchema(Target), nil,
                Format('%s[%d]', [APath, I])));
          except
            Result.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
        Exit;
      end;
    tkArray:
      begin
        TSerializationGraphGuard.EnterLevel;
        try
          Result := TAvroValue.NewArray;
          try
            for I := 0 to Integer(AValue.GetArrayLength) - 1 do
              Result.Add(ValueToAvro(TRttiArrayType(AType).ElementType,
                AValue.GetArrayElement(I), ItemSchema(Target), nil,
                Format('%s[%d]', [APath, I])));
          except
            Result.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
        Exit;
      end;
    tkRecord, tkMRecord:
      begin
        TSerializationGraphGuard.EnterLevel;
        try
          Result := TAvroValue.NewRecord;
          try
            Members := MembersOf(AType);
            for M in Members do
            begin
              RefuseUnwritableMember(M, MemberTypeOf(M), APath + '.' + M.Name);
              Result.Add(MemberAvroName(M),
                ValueToAvro(MemberTypeOf(M), MemberValueOf(M, AValue),
                  FieldSchema(Target, MemberAvroName(M)), M,
                  APath + '.' + M.Name));
            end;
          except
            Result.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
        Exit;
      end;
    tkClass:
      begin
        if DictionaryMethodsOf(AType, AddOrSet, ToArray, Create_, Key, Item) then
        begin
          { A nil dictionary is NULL, not an empty map. See the schema. }
          if (not AValue.IsObject) or (AValue.AsObject = nil) then
            Exit(TAvroValue.NewNull);
          { A container is an object, and is entered as one: that counts its
            level, and makes a container that holds itself a cycle rather
            than a stack overflow. }
          EnterObject(AValue.AsObject, APath);
          try
            Result := TAvroValue.NewMap;
            try
              Arr := ToArray.Invoke(AValue.AsObject, []);
              PairType := GCtx.GetType(Arr.TypeInfo);
              PairElem := TRttiDynamicArrayType(PairType).ElementType;
              KeyField := PairElem.GetField('Key');
              ValueField := PairElem.GetField('Value');
              if (KeyField = nil) or (ValueField = nil) then
                raise EAvroInternalError.CreateFmt(
                  'At %s: %s looks like a map but its ToArray does not ' +
                  'yield Key/Value pairs.', [APath, AType.Name]);
              for I := 0 to Integer(Arr.GetArrayLength) - 1 do
              begin
                Pair := Arr.GetArrayElement(I);
                Result.Add(
                  KeyToText(Key, KeyField.GetValue(Pair.GetReferenceToRawData)),
                  ValueToAvro(Item,
                    ValueField.GetValue(Pair.GetReferenceToRawData),
                    MapValueSchema(Target), nil,
                    Format('%s{%d}', [APath, I])));
              end;
            except
              Result.Free;
              raise;
            end;
          finally
            TSerializationGraphGuard.Leave(AValue.AsObject);
          end;
          Exit;
        end;
        if ListMethodsOf(AType, Add, ToArray, Create_, Item) then
        begin
          { A nil list is NULL, not an empty array - see the schema, which
            gives every container a null branch for exactly this. }
          if (not AValue.IsObject) or (AValue.AsObject = nil) then
            Exit(TAvroValue.NewNull);
          EnterObject(AValue.AsObject, APath);
          try
            Result := TAvroValue.NewArray;
            try
              Arr := TSerializationTypes.ListElements(AValue.AsObject, ToArray);
              for I := 0 to Integer(Arr.GetArrayLength) - 1 do
                Result.Add(ValueToAvro(Item, Arr.GetArrayElement(I),
                  ItemSchema(Target), nil,
                  Format('%s[%d]', [APath, I])));
            except
              Result.Free;
              raise;
            end;
          finally
            TSerializationGraphGuard.Leave(AValue.AsObject);
          end;
          Exit;
        end;
        if (not AValue.IsObject) or (AValue.AsObject = nil) then
          Exit(TAvroValue.NewNull);
        EnterObject(AValue.AsObject, APath);
        try
          Result := TAvroValue.NewRecord;
          try
            Members := MembersOf(AType);
            for M in Members do
            begin
              RefuseUnwritableMember(M, MemberTypeOf(M), APath + '.' + M.Name);
              Result.Add(MemberAvroName(M),
                ValueToAvro(MemberTypeOf(M), MemberValueOf(M, AValue),
                  FieldSchema(Target, MemberAvroName(M)), M,
                  APath + '.' + M.Name));
            end;
          except
            Result.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.Leave(AValue.AsObject);
        end;
        Exit;
      end;
  end;

  raise EAvroInternalError.CreateFmt('At %s: cannot write %s as Avro.',
    [APath, AType.Name]);
end;

function AvroToValue(AType: TRttiType; AValue: TAvroValue;
  AMember: TRttiMember; const AExisting: TValue;
  const APath: string): TValue; forward;

function HandleOf(AType: TRttiType): PTypeInfo;
begin
  if AType = nil then Result := nil else Result := AType.Handle;
end;

{ What the container itself raised while the reader added an element - a
  sorted TStringList with Duplicates = dupError raises EStringListError - as
  Avro's input error naming the container, rather than the RTL's exception
  reaching the caller. }
function ContainerRefusal(E: Exception; AContainer: TObject;
  const APath: string): EAvroInputError;
begin
  Result := EAvroInputError.CreateFmt(
    'At %s: the %s refused an element the document holds: %s',
    [APath, AContainer.ClassName, E.Message]);
end;

function AvroToValue(AType: TRttiType; AValue: TAvroValue;
  AMember: TRttiMember; const AExisting: TValue;
  const APath: string): TValue;
var
  Access: TNullableAccess;
  Members: TArray<TRttiMember>;
  M: TRttiMember;
  Child: TAvroValue;
  Obj: TObject;
  Instance, Elem, Arr, KeyValue: TValue;
  I, Ordinal: Integer;
  ArrLen: NativeInt;
  Add, ToArray, Create_: TRttiMethod;
  Item: TRttiType;
  SerCls: TAvroValueSerializerClass;
  Ser: TCustomAvroValueSerializer;
  Names: TArray<string>;
  Sym: string;
  ElemInfo: PTypeInfo;
  AddOrSet: TRttiMethod;
  Key: TRttiType;
  Cur: Currency;
  Ords: TArray<Integer>;
  Elems: TArray<TValue>;
  Built: Boolean;
  ListAccess: TListAccess;
  DictAccess: TDictionaryAccess;
begin
  Result := TValue.Empty;
  if AType = nil then Exit;

  SerCls := MemberSerializerOf(AMember);
  if SerCls = nil then TAvroEngine.TryGetTypeSerializer(AType.Handle, SerCls);
  if SerCls <> nil then
  begin
    Ser := SerCls.Create;
    try
      Exit(Ser.Deserialize(AValue, AType.Handle, AExisting));
    finally
      Ser.Free;
    end;
  end;

  if TSerializationTypes.TryGetNullableAccess(AType.Handle, Access) then
  begin
    TValue.Make(nil, AType.Handle, Result);
    if (AValue = nil) or (AValue.Kind = TAvroKind.Null) then Exit;
    Access.SetValue(Result.GetReferenceToRawData,
      AvroToValue(GCtx.GetType(Access.ValueType), AValue, AMember,
        TValue.Empty, APath));
    Exit;
  end;

  if (AValue = nil) or (AValue.Kind = TAvroKind.Null) then
  begin
    if AType.TypeKind = tkClass then
    begin
      Obj := nil;
      TValue.Make(@Obj, AType.Handle, Result);
    end
    else
      TValue.Make(nil, AType.Handle, Result);
    Exit;
  end;

  if AType.Handle = System.TypeInfo(TGUID) then
    Exit(TextToKey(AType, Trim(AValue.AsStr), APath));
  if (AType.Handle = System.TypeInfo(TDateTime)) or
     (AType.Handle = System.TypeInfo(TDate)) or
     (AType.Handle = System.TypeInfo(TTime)) then
    Exit(TValue.From<Double>(AValue.AsDateTime).Cast(AType.Handle));
  { StrToCurr raised the RTL's EConvertError on a decimal past Currency's
    range. }
  if AType.Handle = System.TypeInfo(Currency) then
  begin
    if not TryStrToCurr(AValue.AsDecimal, Cur, TFormatSettings.Invariant) then
      raise EAvroInputError.CreateFmt('At %s: %s is not a Currency value.',
        [APath, AValue.AsDecimal]);
    Exit(TValue.From<Currency>(Cur));
  end;
  if AType.Handle = System.TypeInfo(TBytes) then
    Exit(TValue.From<TBytes>(AValue.AsBytes));

  case AType.TypeKind of
    { Range-checked against the member's own type. }
    tkInteger, tkInt64:
      begin
        if not TSerializationTypes.TryIntegerFromInt64(AType.Handle,
             AValue.AsInt, Result) then
          raise EAvroInputError.CreateFmt('At %s: %d does not fit in %s.',
            [APath, AValue.AsInt, AType.Name]);
        Exit;
      end;
    tkFloat:
      begin
        if TSerializationTypes.IsCompType(AType.Handle) then
        begin
          if not TSerializationTypes.TryIntegerFromInt64(AType.Handle,
               AValue.AsInt, Result) then
            raise EAvroInputError.CreateFmt('At %s: %d is not a Comp.',
              [APath, AValue.AsInt]);
          Exit;
        end;
        { Into the member's own width, checked: a Single does not become
          infinity for a double it cannot hold. }
        if not TSerializationTypes.TryFloatFromDouble(AType.Handle,
             AValue.AsFloat, Result, Sym) then
          raise EAvroInputError.CreateFmt('At %s: %s.', [APath, Sym]);
        Exit;
      end;
    { Into the member's own code page, refusing text it cannot hold. }
    tkChar, tkWChar, tkString, tkLString, tkWString, tkUString:
      begin
        if not TSerializationTypes.TryStringFromText(AType.Handle,
             AValue.AsStr, Result, Sym) then
          raise EAvroInputError.CreateFmt('At %s: %s.', [APath, Sym]);
        Exit;
      end;
    tkEnumeration:
      begin
        if AType.Handle = System.TypeInfo(Boolean) then
          Exit(TValue.From<Boolean>(AValue.AsBool));
        Sym := AValue.AsStr;
        if TAvroEngine.TryGetEnumMapping(AType.Handle, Names) then
          for I := 0 to Integer(High(Names)) do
            if SameText(AvroNameOf(Names[I]), Sym) then
              Exit(TValue.FromOrdinal(AType.Handle, I));
        Ordinal := GetEnumValue(AType.Handle, Sym);
        if Ordinal < 0 then
          raise EAvroInputError.CreateFmt(
            'At %s: "%s" is not one of the values of %s.',
            [APath, Sym, AType.Name]);
        Exit(TValue.FromOrdinal(AType.Handle, Ordinal));
      end;
    tkSet:
      begin
        ElemInfo := GetTypeData(AType.Handle).CompType^;
        Ords := nil;
        for I := 0 to AValue.Count - 1 do
        begin
          if ElemInfo.Kind <> tkEnumeration then
          begin
            { Range-checked by TryMakeSet below; only the width here. }
            if (AValue.Items[I].AsInt < 0) or (AValue.Items[I].AsInt > 255) then
              raise EAvroInputError.CreateFmt(
                'At %s: %d is not a member of %s.',
                [APath, AValue.Items[I].AsInt, UTF8ToString(ElemInfo.Name)]);
            Ordinal := Integer(AValue.Items[I].AsInt);
          end
          else
          begin
            Ordinal := GetEnumValue(ElemInfo, AValue.Items[I].AsStr);
            if Ordinal < 0 then
              raise EAvroInputError.CreateFmt(
                'At %s: "%s" is not one of the values of %s.',
                [APath, AValue.Items[I].AsStr, UTF8ToString(ElemInfo.Name)]);
          end;
          Ords := Ords + [Ordinal];
        end;
        { TSerializationTypes builds it: a TIntegerSet held 32 members of a
          set that can have 256. }
        if not TSerializationTypes.TryMakeSet(AType.Handle, Ords, Result, Sym) then
          raise EAvroInputError.CreateFmt('At %s: %s.', [APath, Sym]);
        Exit;
      end;
    { An array is collected before it is assembled, and a failure part way
      frees the objects the elements before it built: they are nowhere
      else. }
    tkArray:
      begin
        Item := TRttiArrayType(AType).ElementType;
        SetLength(Elems, AValue.Count);
        try
          for I := 0 to AValue.Count - 1 do
            Elems[I] := AvroToValue(Item, AValue.Items[I], nil, TValue.Empty,
              Format('%s[%d]', [APath, I]));
          if not TSerializationTypes.TryMakeArray(AType.Handle, Elems, Result,
               Sym) then
            raise EAvroInputError.CreateFmt('At %s: %s.', [APath, Sym]);
        except
          TSerializationOwnership.ReleaseBuiltElements(HandleOf(Item), Elems);
          raise;
        end;
        Exit;
      end;
    tkDynArray:
      begin
        Item := ElementTypeOf(AType);
        TValue.Make(nil, AType.Handle, Arr);
        ArrLen := AValue.Count;
        DynArraySetLength(PPointer(Arr.GetReferenceToRawData)^,
          AType.Handle, 1, @ArrLen);
        try
          for I := 0 to AValue.Count - 1 do
          begin
            Elem := AvroToValue(Item, AValue.Items[I], nil, TValue.Empty,
              Format('%s[%d]', [APath, I]));
            Arr.SetArrayElement(I, Elem);
          end;
        except
          TSerializationOwnership.ReleaseBuilt(AType.Handle, Arr, TValue.Empty);
          raise;
        end;
        Exit(Arr);
      end;
    tkRecord, tkMRecord:
      begin
        { Merged into the record the member already holds, as every object
          member is filled in place - read from a zeroed record, the objects
          a constructor put there were replaced and orphaned. A COPY of it,
          so that the failure path below can still tell what was there. }
        if AExisting.IsEmpty then TValue.Make(nil, AType.Handle, Result)
        else TValue.Make(AExisting.GetReferenceToRawData, AType.Handle, Result);
        try
          Members := MembersOf(AType);
          for M in Members do
          begin
            Child := AValue.Find(MemberAvroName(M));
            if Child = nil then Continue;
            SetMemberValueOf(M, Result,
              AvroToValue(MemberTypeOf(M), Child, M, ExistingValueOf(M, Result),
                APath + '.' + M.Name));
          end;
        except
          { The record is stored only on success, so the objects this read
            built into it are freed here - and none of those it found there
            and filled in place. }
          TSerializationOwnership.ReleaseBuilt(AType.Handle, Result, AExisting);
          raise;
        end;
        Exit;
      end;
    tkClass:
      begin
        { A container that is already there is refilled, never replaced -
          replacing it leaked it - and one built here is freed here when
          the read fails. }
        Built := not (AExisting.IsObject and (AExisting.AsObject <> nil));
        if DictionaryMethodsOf(AType, AddOrSet, ToArray, Create_, Key, Item) then
        begin
          TSerializationTypes.TryGetDictionaryAccess(AType.Handle, DictAccess);
          if Built then
          begin
            if Create_ = nil then
              raise EAvroInputError.CreateFmt(
                'At %s: %s has no parameterless constructor.',
                [APath, AType.Name]);
            Obj := Create_.Invoke(
              TRttiInstanceType(AType).MetaclassType, []).AsObject;
          end
          else
          begin
            Obj := AExisting.AsObject;
            if DictAccess.ClearMethod <> nil then
              DictAccess.ClearMethod.Invoke(Obj, []);
          end;
          try
            for I := 0 to AValue.Count - 1 do
            begin
              KeyValue := TextToKey(Key, AValue.Names[I],
                Format('%s{%d}', [APath, I]));
              Elem := AvroToValue(Item, AValue.Items[I], nil, TValue.Empty,
                Format('%s{%d}', [APath, I]));
              try
                { A key the document repeats releases the value the read
                  built for its earlier occurrence, owning dictionary or
                  not, rather than orphaning it. }
                TSerializationOwnership.AddOrSetBuilt(DictAccess, Obj,
                  KeyValue, Elem);
              except
                on E: Exception do
                begin
                  TSerializationOwnership.ReleaseBuilt(HandleOf(Item), Elem,
                    TValue.Empty);
                  if string(E.UnitName).StartsWith('PascalForge.') then raise;
                  raise ContainerRefusal(E, Obj, Format('%s{%d}', [APath, I]));
                end;
              end;
            end;
          except
            { A dictionary built here goes with the objects the read put in
              it: a TDictionary<K, TObject> freed alone orphaned them. }
            if Built then TSerializationOwnership.ReleaseBuiltContainer(Obj);
            raise;
          end;
          TValue.Make(@Obj, AType.Handle, Result);
          Exit;
        end;
        if ListMethodsOf(AType, Add, ToArray, Create_, Item) then
        begin
          if Built then
          begin
            if Create_ = nil then
              raise EAvroInputError.CreateFmt(
                'At %s: %s has no parameterless constructor.',
                [APath, AType.Name]);
            Obj := Create_.Invoke(
              TRttiInstanceType(AType).MetaclassType, []).AsObject;
          end
          else
          begin
            Obj := AExisting.AsObject;
            if TSerializationTypes.TryGetListAccess(AType.Handle, ListAccess) and
               (ListAccess.ClearMethod <> nil) then
              ListAccess.ClearMethod.Invoke(Obj, []);
          end;
          try
            for I := 0 to AValue.Count - 1 do
            begin
              Elem := AvroToValue(Item, AValue.Items[I], nil, TValue.Empty,
                Format('%s[%d]', [APath, I]));
              try
                Add.Invoke(Obj, [Elem]);
              except
                on E: Exception do
                begin
                  TSerializationOwnership.ReleaseBuilt(HandleOf(Item), Elem,
                    TValue.Empty);
                  if string(E.UnitName).StartsWith('PascalForge.') then raise;
                  raise ContainerRefusal(E, Obj, Format('%s[%d]', [APath, I]));
                end;
              end;
            end;
          except
            { And a list built here, with the elements it does not own. }
            if Built then TSerializationOwnership.ReleaseBuiltContainer(Obj);
            raise;
          end;
          TValue.Make(@Obj, AType.Handle, Result);
          Exit;
        end;
        if not Built then
          Instance := AExisting
        else
        begin
          Create_ := TSerializationTypes.DefaultConstructor(AType);
          if Create_ = nil then
            raise EAvroInputError.CreateFmt(
              'At %s: %s has no parameterless constructor, so Avro cannot ' +
              'build one.', [APath, AType.Name]);
          Obj := Create_.Invoke(
            TRttiInstanceType(AType).MetaclassType, []).AsObject;
          TValue.Make(@Obj, AType.Handle, Instance);
        end;
        try
          Members := MembersOf(AType);
          for M in Members do
          begin
            Child := AValue.Find(MemberAvroName(M));
            if Child = nil then Continue;
            SetMemberValueOf(M, Instance,
              AvroToValue(MemberTypeOf(M), Child, M,
                ExistingValueOf(M, Instance), APath + '.' + M.Name));
          end;
        except
          if Built then Instance.AsObject.Free;
          raise;
        end;
        Exit(Instance);
      end;
  end;

  raise EAvroInternalError.CreateFmt('At %s: cannot read %s from Avro.',
    [APath, AType.Name]);
end;

class function TAvroEngine.SerializeRoot(ATypeInfo: PTypeInfo;
  const AValue: TValue): TBytes;
var
  Schema: TAvroSchema;
  Datum: TAvroValue;
  Mark: Integer;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  Schema := SchemaFor(ATypeInfo);
  { The level this write started from, restored whatever happens, so that a
    failure deep in one write cannot start the next part way down. }
  Mark := TSerializationGraphGuard.Level;
  try
    Datum := ValueToAvro(GCtx.GetType(ATypeInfo), AValue, Schema, nil, '$');
  finally
    TSerializationGraphGuard.RestoreLevel(Mark);
  end;
  try
    Result := EncodeDatum(Schema, Datum);
  finally
    Datum.Free;
  end;
end;

class function TAvroEngine.DeserializeRoot(ATypeInfo: PTypeInfo;
  const AData: TBytes; const AExisting: TValue): TValue;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  { No writer schema was supplied, so the reader's own is used for both -
    which is correct only when the bytes were written by this same contract.
    DeserializeWith is the call for anything else, and the bytes themselves
    cannot tell the two apart. }
  Result := DeserializeRootWith(ATypeInfo, AData, SchemaFor(ATypeInfo),
    AExisting);
end;

class function TAvroEngine.DeserializeRootWith(ATypeInfo: PTypeInfo;
  const AData: TBytes; AWriter: TAvroSchema;
  const AExisting: TValue): TValue;
var
  Datum: TAvroValue;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  if AWriter = nil then
    raise ESerializationSchemaRequired.CreateFor(TSerializationFormat.Avro,
      'reading a datum');
  Datum := DecodeDatum(AData, AWriter, SchemaFor(ATypeInfo));
  try
    Result := AvroToValue(GCtx.GetType(ATypeInfo), Datum, nil, AExisting, '$');
  finally
    Datum.Free;
  end;
end;

class function TAvroEngine.FromPayload(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): TBytes;
var
  Handler: TSerializationFormatHandler;
  Value: TValue;
begin
  { Contract-aware: the source format deserializes into T by ITS rules and
    Avro writes T by its own, against the schema T generates. Reached
    through the registry, so this unit has no compile-time dependency on any
    other format. }
  Handler := TSerializationFormats.Get(AFrom);
  Value := Handler.DeserializeTyped(ATypeInfo, ASource);
  Result := SerializeRoot(ATypeInfo, Value);
end;

{ ===========================================================================
  OBJECT CONTAINER FILES

  The format that makes an Avro file self-describing: the schema travels in
  the header, so a file can be read without anybody having to send the
  schema separately. It is the ONLY Avro artefact that carries its own
  schema, which is why a bare datum still needs one supplied.
  =========================================================================== }

const
  AvroMagic: array[0..3] of Byte = (Ord('O'), Ord('b'), Ord('j'), 1);
  AvroSyncSize = 16;

{ The sync marker. The specification says sixteen random bytes; this derives
  them from the schema's own fingerprint instead, so that writing the same
  data twice produces the same file. A reproducible build is worth more here
  than unpredictability, and the marker's job is only to be unlikely to
  appear in the data. }
function SyncMarkerFor(ASchema: TAvroSchema): TBytes;
var
  Finger: UInt64;
  I: Integer;
begin
  Finger := ASchema.Fingerprint;
  SetLength(Result, AvroSyncSize);
  for I := 0 to 7 do Result[I] := Byte(Finger shr (I * 8));
  for I := 8 to 15 do
    Result[I] := Byte((Finger shr ((I - 8) * 8)) xor $A5);
end;

class function TAvroEngine.WriteContainer(ASchema: TAvroSchema;
  const AValues: array of TAvroValue; ACodec: TAvroCodec): TBytes;
const
  AVRO_WRITE_BLOCK_BYTES = 1024 * 1024;
var
  W, Body, Datum: TAvroByteWriter;
  Sync: TBytes;
  I, InBlock: Integer;

  procedure FlushBlock;
  var
    Raw, Packed_: TBytes;
    Stream: TMemoryStream;
    Compressor: TZCompressionStream;
  begin
    Raw := Body.Done;
    if ACodec = TAvroCodec.Deflate then
    begin
      Stream := TMemoryStream.Create;
      try
        { RFC 1951 RAW deflate - no zlib header, which is what the Avro
          specification asks for and what -15 window bits means. }
        Compressor := TZCompressionStream.Create(Stream, zcDefault, -15);
        try
          if Length(Raw) > 0 then Compressor.WriteBuffer(Raw[0], Length(Raw));
        finally
          Compressor.Free;
        end;
        SetLength(Packed_, Stream.Size);
        if Stream.Size > 0 then
          Move(TMemoryStream(Stream).Memory^, Packed_[0], NativeInt(Stream.Size));
      finally
        Stream.Free;
      end;
    end
    else
      Packed_ := Raw;
    W.PutLong(InBlock);
    W.PutLong(Length(Packed_));
    W.PutRaw(Packed_);
    W.PutRaw(Sync);
  end;

begin
  Sync := SyncMarkerFor(ASchema);
  W.Init;
  for I := 0 to 3 do W.PutByte(AvroMagic[I]);

  { The metadata map: two entries, then the terminating zero-length block. }
  W.PutLong(2);
  W.PutString('avro.schema');
  W.PutBytes(StringToUtf8Bytes(ASchema.ToJson));
  W.PutString('avro.codec');
  if ACodec = TAvroCodec.Deflate then W.PutBytes(StringToUtf8Bytes('deflate'))
  else W.PutBytes(StringToUtf8Bytes('null'));
  W.PutLong(0);
  W.PutRaw(Sync);

  { Datums go out in blocks of about AVRO_WRITE_BLOCK_BYTES, as real writers
    flush them, so that no block a default write makes is past what a
    default read inflates (TAvroReadOptions.DefaultMaxInflatedBlockBytes):
    a block is under the target, or one datum on its own. }
  Body.Init;
  InBlock := 0;
  for I := 0 to Integer(High(AValues)) do
  begin
    Datum.Init;
    WriteDatum(Datum, ASchema, AValues[I], Format('$[%d]', [I]));
    if (ACodec = TAvroCodec.Deflate) and
       (Datum.Position > TAvroReadOptions.DefaultMaxInflatedBlockBytes) then
      raise EAvroError.CreateFmt(
        '$[%d] encodes to %d bytes. A deflate block holding it would ' +
        'inflate past %d bytes, the default read limit ' +
        '(TAvroReadOptions.DefaultMaxInflatedBlockBytes), so a default ' +
        'read could not open the file. Write it with TAvroCodec.Null.',
        [I, Datum.Position, TAvroReadOptions.DefaultMaxInflatedBlockBytes]);
    if (InBlock > 0) and
       (Int64(Body.Position) + Datum.Position > AVRO_WRITE_BLOCK_BYTES) then
    begin
      FlushBlock;
      Body.Init;
      InBlock := 0;
    end;
    Body.PutRaw(Datum.Done);
    Inc(InBlock);
  end;
  if InBlock > 0 then FlushBlock;

  Result := W.Done;
end;

class function TAvroEngine.ReadContainer(const AData: TBytes;
  AReader: TAvroSchema; AMaxInflatedBlockBytes: Integer;
  out AWriterSchemaJson: string): TObjectList<TAvroValue>;
var
  R, Block: TAvroByteReader;
  I, N, BlockSize, At: Integer;
  Count, Size: Int64;
  Key: string;
  Meta: TBytes;
  Codec: string;
  Writer: TAvroSchema;
  Raw, Plain: TBytes;
  Stream: TMemoryStream;
  Decompressor: TZDecompressionStream;
  Buffer: TBytes;
  Read: Integer;
  Owned: Boolean;
begin
  AWriterSchemaJson := '';
  { The facade refuses a budget that is not positive; this is the backstop
    for any other caller. }
  if AMaxInflatedBlockBytes <= 0 then
    raise EAvroError.CreateFmt('A deflate block budget of %d bytes. It must ' +
      'be positive.', [AMaxInflatedBlockBytes]);
  R.Init(AData);
  for I := 0 to 3 do
    if R.GetByte <> AvroMagic[I] then
      raise EAvroInputError.Create(
        'This is not an Avro container file: the first four bytes are not ' +
        '"Obj" followed by version 1.');

  Codec := 'null';
  repeat
    { The metadata is an Avro map of bytes: each entry is at least its key's
      length byte. }
    N := GetBlockCount(R, True, 'the container header''s metadata map',
      BlockSize);
    if N = 0 then Break;
    for I := 1 to N do
    begin
      Key := R.GetString;
      Meta := R.GetBytes;
      if Key = 'avro.schema' then AWriterSchemaJson := Utf8BytesToString(Meta)
      else if Key = 'avro.codec' then Codec := Utf8BytesToString(Meta);
    end;
  until False;

  if AWriterSchemaJson = '' then
    raise EAvroInputError.Create(
      'This container file carries no avro.schema in its header, so there ' +
      'is nothing that says what its bytes are.');
  if (Codec <> 'null') and (Codec <> 'deflate') then
    raise EAvroInputError.CreateFmt(
      'This container file was written with the "%s" codec, which this ' +
      'library does not implement. It reads null and deflate.', [Codec]);

  R.Skip(AvroSyncSize);

  Writer := TAvroSchema.Parse(AWriterSchemaJson);
  Owned := True;
  Result := TObjectList<TAvroValue>.Create(True);
  try
    while not R.AtEnd do
    begin
      { A data block: a count of objects, which is never negative here,
        and the byte size of what follows. Both are checked before either
        is narrowed or used. }
      At := R.Position;
      Count := R.GetLong;
      if (Count < 0) or (Count > MaxInt) then
        raise EAvroInputError.CreateFmt(
          'At byte %d: a container data block declares %d objects.',
          [At, Count]);
      Size := R.GetLong;
      if (Size < 0) or (Size > MaxInt) or (Size > R.Remaining) then
        raise EAvroInputError.CreateFmt(
          'At byte %d: a container data block declares %d bytes, and %d ' +
          'bytes are left.', [At, Size, R.Remaining]);
      Raw := R.GetRaw(Integer(Size));
      if Codec = 'deflate' then
      begin
        Stream := TMemoryStream.Create;
        try
          if Length(Raw) > 0 then Stream.WriteBuffer(Raw[0], Length(Raw));
          Stream.Position := 0;
          Decompressor := TZDecompressionStream.Create(Stream, -15);
          try
            SetLength(Plain, 0);
            SetLength(Buffer, 65536);
            repeat
              Read := Decompressor.Read(Buffer[0], Integer(Length(Buffer)));
              if Read > 0 then
              begin
                { THE BUDGET IS CHECKED BEFORE THE CHUNK IS KEPT, so
                  decompression stops at the caller's limit instead of after
                  inflating whatever the block claims. Int64 arithmetic, so
                  the comparison is the same on both platforms. }
                if Int64(Length(Plain)) + Read > AMaxInflatedBlockBytes then
                  raise EAvroInputError.CreateFmt(
                    'At byte %d: a deflate container block inflates past the ' +
                    '%d-byte limit (TAvroReadOptions.MaxInflatedBlockBytes).',
                    [At, AMaxInflatedBlockBytes]);
                SetLength(Plain, Length(Plain) + Read);
                Move(Buffer[0], Plain[Length(Plain) - Read], Read);
              end;
            until Read <= 0;
          finally
            Decompressor.Free;
          end;
        finally
          Stream.Free;
        end;
      end
      else
        Plain := Raw;

      Block.Init(Plain);
      { Each object takes at least a byte unless the schema can be empty. }
      if (Count > Block.Remaining) and not AvroDatumCanBeEmpty(Writer) then
        raise EAvroInputError.CreateFmt(
          'At byte %d: a container data block declares %d objects in %d ' +
          'bytes, and each takes at least one.',
          [At, Count, Block.Remaining]);
      for I := 1 to Integer(Count) do
        Result.Add(ReadDatum(Block, Writer, AReader, Format('$[%d]', [I - 1])));
      R.Skip(AvroSyncSize);
    end;
  except
    Result.Free;
    if Owned then Writer.Free;
    raise;
  end;
  Writer.Free;
end;

class function TAvroEngine.ReadContainerTyped(ATypeInfo: PTypeInfo;
  const AData: TBytes; AMaxInflatedBlockBytes: Integer): TArray<TValue>;
var
  Values: TObjectList<TAvroValue>;
  Json: string;
  I: Integer;
  T: TRttiType;
begin
  T := GCtx.GetType(ATypeInfo);
  Values := ReadContainer(AData, SchemaFor(ATypeInfo), AMaxInflatedBlockBytes,
    Json);
  try
    SetLength(Result, Values.Count);
    try
      for I := 0 to Integer(Values.Count) - 1 do
        Result[I] := AvroToValue(T, Values[I], nil, TValue.Empty,
          Format('$[%d]', [I]));
    except
      { The datums read before the one that failed are nowhere else. }
      TSerializationOwnership.ReleaseBuiltElements(ATypeInfo, Result);
      raise;
    end;
  finally
    Values.Free;
  end;
end;

class function TAvroEngine.WriteContainerTyped(ATypeInfo: PTypeInfo;
  const AValues: TArray<TValue>; ACodec: TAvroCodec): TBytes;
var
  Schema: TAvroSchema;
  Data: TObjectList<TAvroValue>;
  Boxed: TArray<TAvroValue>;
  T: TRttiType;
  I, Mark: Integer;
begin
  Schema := SchemaFor(ATypeInfo);
  T := GCtx.GetType(ATypeInfo);
  Data := TObjectList<TAvroValue>.Create(True);
  try
    { Each value is a root, and starts where this write started. }
    Mark := TSerializationGraphGuard.Level;
    try
      for I := 0 to Integer(High(AValues)) do
        Data.Add(ValueToAvro(T, AValues[I], Schema, nil,
          Format('$[%d]', [I])));
    finally
      TSerializationGraphGuard.RestoreLevel(Mark);
    end;
    SetLength(Boxed, Data.Count);
    for I := 0 to Integer(Data.Count) - 1 do Boxed[I] := Data[I];
    Result := WriteContainer(Schema, Boxed, ACodec);
  finally
    Data.Free;
  end;
end;

{ ===========================================================================
  THE DYNAMIC BRIDGE

  Structural conversion only, and it REQUIRES A SCHEMA in the Avro
  direction: Avro bytes are meaningless without one, so there is no honest
  way to write a dynamic tree as Avro without being told what shape it
  should take. Reading is the easy half, because the caller has already
  supplied the schema to get a datum at all.
  =========================================================================== }

class function TAvroEngine.AvroToDynamic(AValue: TAvroValue): TDynamicValue;
var
  I: Integer;
begin
  if AValue = nil then Exit(TDynamicValue.NewNull);
  case AValue.Kind of
    TAvroKind.Null: Exit(TDynamicValue.NewNull);
    TAvroKind.Bool: Exit(TDynamicValue.NewBool(AValue.AsBool));
    TAvroKind.Int, TAvroKind.Long: Exit(TDynamicValue.NewInt(AValue.AsInt));
    TAvroKind.Float, TAvroKind.Double:
      Exit(TDynamicValue.NewFloat(AValue.AsFloat));
    TAvroKind.Bytes, TAvroKind.Fixed:
      Exit(TDynamicValue.NewBytes(AValue.AsBytes));
    TAvroKind.Str, TAvroKind.Enum: Exit(TDynamicValue.NewStr(AValue.AsStr));
    TAvroKind.Decimal: Exit(TDynamicValue.NewDecimal(AValue.AsDecimal));
    { AVRO IS THE FORMAT THAT DISTINGUISHES THESE, so the dynamic tree keeps
      the distinction rather than flattening all three onto an instant. The
      logical type is the schema's own statement about what the value means
      and it is already on the value; nothing here is inferred. }
    TAvroKind.DateTime:
      case AValue.LogicalType of
        TAvroLogicalType.Date:
          Exit(TDynamicValue.NewDate(AValue.AsDateTime));
        TAvroLogicalType.TimeMillis, TAvroLogicalType.TimeMicros:
          Exit(TDynamicValue.NewTime(AValue.AsDateTime));
      else
        Exit(TDynamicValue.NewDateTime(AValue.AsDateTime));
      end;
    TAvroKind.Duration:
      { Months, days and milliseconds together are not a quantity any other
        format here has, so it travels as the three numbers it is rather
        than as a total nobody could reconstruct. }
      begin
        Result := TDynamicValue.NewObject;
        try
          Result.AsObject.Adopt('months', TDynamicValue.NewInt(AValue.DurationMonths));
          Result.AsObject.Adopt('days', TDynamicValue.NewInt(AValue.DurationDays));
          Result.AsObject.Adopt('millis', TDynamicValue.NewInt(AValue.DurationMillis));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
    TAvroKind.Arr:
      begin
        Result := TDynamicValue.NewArray;
        try
          for I := 0 to AValue.Count - 1 do
            Result.AsArray.Adopt(AvroToDynamic(AValue.Items[I]));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
    TAvroKind.Rec, TAvroKind.Map:
      begin
        Result := TDynamicValue.NewObject;
        try
          for I := 0 to AValue.Count - 1 do
            Result.AsObject.Adopt(AValue.Names[I], AvroToDynamic(AValue.Items[I]));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
  end;
  Result := TDynamicValue.NewNull;
end;

{ The instant, day or time of day a dynamic value carries, for a field whose
  schema declares one of the temporal logical types.

  The three temporal kinds give it directly. TEXT IS PARSED HERE AND ONLY
  HERE, because the schema has said what this field is - that is one of the
  three authorities allowed to say so - and a tree that arrived from JSON
  carries the ISO form as a string. Anything else is a genuine mismatch and
  is named. }
function DynamicMoment(AValue: TDynamicValue; ALogical: TAvroLogicalType;
  const APath: string): TDateTime;
begin
  case AValue.Kind of
    TDynamicKind.Date, TDynamicKind.Time, TDynamicKind.DateTime:
      Exit(AValue.AsDateTime);
    TDynamicKind.Str:
      begin
        if TStructuralText.TryDecodeDateTime(AValue.AsStr, Result) then Exit;
        if TStructuralText.TryDecodeDate(AValue.AsStr, Result) then Exit;
        if TStructuralText.TryDecodeTime(AValue.AsStr, Result) then Exit;
        raise EAvroInputError.CreateFmt(
          'At %s: the schema says %s and the text offered is not a date or ' +
          'a time this library wrote.',
          [APath, GetEnumName(System.TypeInfo(TAvroLogicalType),
            Ord(ALogical))]);
      end;
  end;
  raise EAvroInputError.CreateFmt(
    'At %s: the schema says %s and the value offered is %s.',
    [APath, GetEnumName(System.TypeInfo(TAvroLogicalType), Ord(ALogical)),
     AValue.Describe]);
end;

{ A dynamic value for a field with a temporal logical type. An Int is the raw
  unit count the logical type is defined over - days since the epoch,
  milliseconds after midnight - and the caller who put it there meant it, so
  it is carried as that count exactly - never taken for a TDateTime serial,
  which would write day 1 as -25568. }
function DynamicTemporal(AValue: TDynamicValue;
  ASchema: TAvroSchema): TAvroValue;
begin
  if AValue.Kind = TDynamicKind.Int then
  begin
    if (ASchema.SchemaType = TAvroType.Int) and
       ((AValue.AsInt < Low(Integer)) or (AValue.AsInt > High(Integer))) then
      raise EAvroInputError.CreateFmt(
        '%d does not fit in an Avro int, which is 32 bits. Declare the ' +
        'field a long.', [AValue.AsInt]);
    Exit(TAvroValue.NewExactDateTime(
      RawToDateTime(AValue.AsInt, ASchema.LogicalType), ASchema.LogicalType,
      AValue.AsInt));
  end;
  Result := TAvroValue.NewDateTime(
    DynamicMoment(AValue, ASchema.LogicalType, ASchema.TypeName));
end;

{ ---------------------------------------------------------------------------
  WHAT THE PROFILE DECIDES ON THE WAY INTO AVRO

  A structural tree is written against a schema the tree knows nothing
  about, so three things can happen that a contract write never meets:

    a member the schema does not name     Natural omits it - the schema is
                                          the destination's whole vocabulary
                                          and says nothing about it; Strict
                                          and Lossless refuse, naming it
    a Double into an exact decimal        exact when the double IS such a
                                          decimal; otherwise Natural writes
                                          the shortest text that reads back
                                          as that double, and Strict and
                                          Lossless refuse
    a union value two branches fit alike  Natural takes the first in
                                          declaration order; Strict and
                                          Lossless refuse, naming both

  Everything else - a value no branch can hold, a required field missing,
  more decimal places than the schema's scale - is refused in every
  profile. docs\avro-behavior.md states the same rules for readers.
  --------------------------------------------------------------------------- }

function AvroAdapts(const AOptions: TStructuralConversionOptions): Boolean;
begin
  Result := AOptions.ValuePolicy = TStructuralValuePolicy.Natural;
end;

procedure AvroRefuse(const AOptions: TStructuralConversionOptions;
  const APath: string; AKind: TDynamicKind; const AReason: string);
var
  Issue: TStructuralIssue;
begin
  if AOptions.ValuePolicy = TStructuralValuePolicy.Lossless then
    Issue := TStructuralIssue.UnsupportedLosslessConversion
  else
    Issue := TStructuralIssue.LossyConversion;
  raise EStructuralConversionError.CreateFor(Issue, AOptions,
    TSerializationFormat.Avro, APath, AKind, AReason);
end;

function AvroProfileName(const AOptions: TStructuralConversionOptions): string;
begin
  if AOptions.ValuePolicy = TStructuralValuePolicy.Lossless then
    Result := 'Lossless'
  else
    Result := 'Strict';
end;

{ The exact decimal a double is, when it has at most AScale places.

  Every finite double is a finite decimal, but most need far more places
  than a schema allows: 0.1 is 0.1000000000000000055511151231257827... A
  double with n binary places has exactly n decimal places, so doubling it
  (which is exact) until it is whole says how many; the digits are then the
  whole number times 5^n. False when that takes more than AScale places, or
  when the value is too large for its digits to be read off exactly. }
function ExactDecimalOfDouble(AValue: Double; AScale: Integer;
  out AText: string): Boolean;
var
  M: Double;
  N, I, D, Carry: Integer;
  Digits: string;
  Negative: Boolean;
begin
  Result := False;
  AText := '';
  if AValue.IsNan or AValue.IsInfinity then Exit;
  Negative := AValue < 0;
  M := Abs(AValue);
  N := 0;
  while Frac(M) <> 0 do
  begin
    if N >= AScale then Exit;
    M := M * 2;
    Inc(N);
  end;
  if M >= 9.2e18 then Exit;
  Digits := UIntToStr(UInt64(Trunc(M)));
  for I := 1 to N do
  begin
    Carry := 0;
    for D := Length(Digits) downto 1 do
    begin
      Carry := (Ord(Digits[D]) - Ord('0')) * 5 + Carry;
      Digits[D] := Char(Ord('0') + Carry mod 10);
      Carry := Carry div 10;
    end;
    while Carry > 0 do
    begin
      Digits := Char(Ord('0') + Carry mod 10) + Digits;
      Carry := Carry div 10;
    end;
  end;
  if N > 0 then
  begin
    while Length(Digits) <= N do Digits := '0' + Digits;
    Digits := Copy(Digits, 1, Length(Digits) - N) + '.' +
      Copy(Digits, Length(Digits) - N + 1, N);
  end;
  if Negative and (M <> 0) then Digits := '-' + Digits;
  AText := Digits;
  Result := True;
end;

{ '1.5E-7' as '0.00000015': the decimal encoder reads plain notation only. }
function PlainDecimalText(const AText: string): string;
var
  E, Exp, Dot: Integer;
  Mant, Sign, IntPart, FracPart: string;
begin
  E := Pos('E', UpperCase(AText));
  if E = 0 then Exit(AText);
  Mant := Copy(AText, 1, E - 1);
  if not TryStrToInt(Copy(AText, E + 1, MaxInt), Exp) then Exit(AText);
  Sign := '';
  if (Mant <> '') and CharInSet(Mant[1], ['-', '+']) then
  begin
    if Mant[1] = '-' then Sign := '-';
    Delete(Mant, 1, 1);
  end;
  Dot := Pos('.', Mant);
  if Dot > 0 then
  begin
    IntPart := Copy(Mant, 1, Dot - 1);
    FracPart := Copy(Mant, Dot + 1, MaxInt);
  end
  else
  begin
    IntPart := Mant;
    FracPart := '';
  end;
  Mant := IntPart + FracPart;
  Dot := Length(IntPart) + Exp;
  if Dot <= 0 then
    Result := '0.' + StringOfChar('0', -Dot) + Mant
  else if Dot >= Length(Mant) then
    Result := Mant + StringOfChar('0', Dot - Length(Mant))
  else
    Result := Copy(Mant, 1, Dot) + '.' + Copy(Mant, Dot + 1, MaxInt);
  Result := Sign + Result;
end;

{ The decimal text for a field whose schema says decimal.

  Accepted as exact in every profile: a dynamic Decimal, an integer, and
  text in plain decimal notation (the schema is what says the text is a
  number). A Double is exact only when it IS a decimal with the schema's
  places or fewer; any other Double is an approximation, which Natural
  writes as the shortest text that reads back as the same double and
  Strict and Lossless refuse. The encoder still refuses more places than the
  scale, in every profile: nothing here rounds. }
function DynamicDecimalText(AValue: TDynamicValue; ASchema: TAvroSchema;
  const AOptions: TStructuralConversionOptions; const APath: string): string;
begin
  case AValue.Kind of
    TDynamicKind.Decimal: Exit(AValue.AsDecimal);
    TDynamicKind.Int: Exit(IntToStr(AValue.AsInt));
    TDynamicKind.UInt: Exit(UIntToStr(AValue.AsUInt));
    TDynamicKind.Str: Exit(Trim(AValue.AsStr));
    TDynamicKind.Float:
      begin
        if ExactDecimalOfDouble(AValue.AsFloat, ASchema.Scale, Result) then
          Exit;
        if AvroAdapts(AOptions) then
          Exit(PlainDecimalText(TStructuralText.EncodeFloat(AValue.AsFloat)));
        AvroRefuse(AOptions, APath, AValue.Kind, Format(
          'the schema says decimal with %d places, and the binary float %s ' +
          'is not exactly such a decimal. %s does not approximate a float ' +
          'into an exact decimal; carry the value as a decimal, an integer ' +
          'or decimal text, or convert with the Natural profile.',
          [ASchema.Scale, TStructuralText.EncodeFloat(AValue.AsFloat),
           AvroProfileName(AOptions)]));
      end;
  end;
  raise EAvroInputError.CreateFmt(
    'At %s: the schema says decimal and the value offered is %s.',
    [APath, AValue.Describe]);
end;

function IsAvroTemporal(ALogical: TAvroLogicalType): Boolean;
begin
  Result := ALogical in [TAvroLogicalType.Date, TAvroLogicalType.TimeMillis,
    TAvroLogicalType.TimeMicros, TAvroLogicalType.TimestampMillis,
    TAvroLogicalType.TimestampMicros, TAvroLogicalType.LocalTimestampMillis,
    TAvroLogicalType.LocalTimestampMicros];
end;

function IsPlainDecimalText(const AText: string): Boolean;
var
  I, Dots, Digits: Integer;
  S: string;
begin
  S := Trim(AText);
  if (S <> '') and CharInSet(S[1], ['-', '+']) then Delete(S, 1, 1);
  Dots := 0;
  Digits := 0;
  for I := 1 to Length(S) do
    if S[I] = '.' then Inc(Dots)
    else if CharInSet(S[I], ['0'..'9']) then Inc(Digits)
    else Exit(False);
  Result := (Digits > 0) and (Dots <= 1);
end;

{ How well one union branch holds a value, for choosing among branches.

    3  the branch is the value's own Avro type
    2  a wider type of the same family (long for an int that fits in 32
       bits, double for a float, a map for an object, a string's enum)
    1  a representation the schema sanctions: text or a raw unit count read
       as a date, an integer or decimal text as a decimal, an integer a
       double holds exactly
    0  it cannot hold the value at all

  A branch is never chosen because it comes first when it cannot hold the
  value: an integer is not written into a string branch, and one past 32
  bits is not written into an int. }
function AvroBranchFit(AValue: TDynamicValue; ABranch: TAvroSchema): Integer;
var
  L: TAvroLogicalType;
  T: TDateTime;
  I, Named: Integer;
  Field: TAvroField;
begin
  Result := 0;
  L := ABranch.LogicalType;
  if L = TAvroLogicalType.Unknown then L := TAvroLogicalType.None;
  case AValue.Kind of
    TDynamicKind.Bool:
      if ABranch.SchemaType = TAvroType.Bool then Result := 3;

    TDynamicKind.Int:
      case ABranch.SchemaType of
        TAvroType.Int:
          if (AValue.AsInt >= Low(Integer)) and (AValue.AsInt <= High(Integer)) then
            if L = TAvroLogicalType.None then Result := 3
            else if IsAvroTemporal(L) then Result := 1;
        TAvroType.Long:
          if L = TAvroLogicalType.None then Result := 2
          else if IsAvroTemporal(L) then Result := 1;
        TAvroType.Double:
          if (AValue.AsInt >= -(Int64(1) shl 53)) and
             (AValue.AsInt <= (Int64(1) shl 53)) then Result := 1;
        TAvroType.Float:
          if (AValue.AsInt >= -(1 shl 24)) and (AValue.AsInt <= (1 shl 24)) then
            Result := 1;
        TAvroType.Bytes, TAvroType.Fixed:
          if L = TAvroLogicalType.Decimal then Result := 1;
      end;

    TDynamicKind.UInt:
      if (ABranch.SchemaType in [TAvroType.Bytes, TAvroType.Fixed]) and
         (L = TAvroLogicalType.Decimal) then Result := 1;

    TDynamicKind.Float:
      case ABranch.SchemaType of
        TAvroType.Double:
          if L = TAvroLogicalType.None then Result := 3;
        TAvroType.Float:
          if (L = TAvroLogicalType.None) and
             (Abs(AValue.AsFloat) <= MaxSingle) and
             (Double(Single(AValue.AsFloat)) = AValue.AsFloat) then Result := 2;
        TAvroType.Bytes, TAvroType.Fixed:
          if L = TAvroLogicalType.Decimal then Result := 1;
      end;

    TDynamicKind.Decimal:
      if (ABranch.SchemaType in [TAvroType.Bytes, TAvroType.Fixed]) and
         (L = TAvroLogicalType.Decimal) then Result := 3;

    TDynamicKind.Str:
      case ABranch.SchemaType of
        TAvroType.Str:
          if L = TAvroLogicalType.None then Result := 3 else Result := 2;
        TAvroType.Enum:
          if ABranch.IndexOfSymbol(AValue.AsStr) >= 0 then Result := 2;
        TAvroType.Int, TAvroType.Long:
          if IsAvroTemporal(L) and
             (TStructuralText.TryDecodeDateTime(AValue.AsStr, T) or
              TStructuralText.TryDecodeDate(AValue.AsStr, T) or
              TStructuralText.TryDecodeTime(AValue.AsStr, T)) then Result := 1;
        TAvroType.Bytes, TAvroType.Fixed:
          if (L = TAvroLogicalType.Decimal) and IsPlainDecimalText(AValue.AsStr) then
            Result := 1;
      end;

    TDynamicKind.Bytes:
      case ABranch.SchemaType of
        TAvroType.Bytes:
          if L = TAvroLogicalType.None then Result := 3;
        TAvroType.Fixed:
          if (L = TAvroLogicalType.None) and
             (ABranch.Size = Length(AValue.AsBytes)) then Result := 3;
      end;

    TDynamicKind.Date:
      if L = TAvroLogicalType.Date then Result := 3
      else if L in [TAvroLogicalType.TimestampMillis, TAvroLogicalType.TimestampMicros,
        TAvroLogicalType.LocalTimestampMillis, TAvroLogicalType.LocalTimestampMicros] then
        Result := 2;

    TDynamicKind.Time:
      if L in [TAvroLogicalType.TimeMillis, TAvroLogicalType.TimeMicros] then
        Result := 3;

    TDynamicKind.DateTime:
      if L in [TAvroLogicalType.TimestampMillis, TAvroLogicalType.TimestampMicros,
        TAvroLogicalType.LocalTimestampMillis, TAvroLogicalType.LocalTimestampMicros] then
        Result := 3;

    TDynamicKind.Arr:
      if ABranch.SchemaType = TAvroType.Arr then Result := 3;

    TDynamicKind.Obj:
      case ABranch.SchemaType of
        TAvroType.Rec:
          begin
            { A record fits exactly when it names every member the object
              has and the object has every field without a default; a
              record that would need members omitted fits only as an
              adaptation. }
            Named := 0;
            for I := 0 to AValue.Count - 1 do
              if ABranch.IndexOfField(AValue.Names[I]) >= 0 then Inc(Named);
            Result := 3;
            if Named < AValue.Count then Result := 1;
            for I := 0 to ABranch.FieldCount - 1 do
            begin
              Field := ABranch.Fields[I];
              if (AValue.Find(Field.Name) = nil) and (Field.Default = nil) and
                 not ((Field.FieldType.SchemaType = TAvroType.Union) and
                      (Field.FieldType.IndexOfBranchType(TAvroType.Null) >= 0)) then
                Exit(0);
            end;
          end;
        TAvroType.Map:
          Result := 2;
      end;
  end;
end;

{ A value whose kind the schema's type cannot hold. Refused in every
  profile: writing it anyway would put a field's zero value on the wire for
  a string, a byte array or a boolean that was never zero. }
procedure RefuseAvroKind(AValue: TDynamicValue; ASchema: TAvroSchema;
  const AOptions: TStructuralConversionOptions; const APath: string);
begin
  raise EStructuralConversionError.CreateFor(
    TStructuralIssue.UnsupportedValueKind, AOptions, TSerializationFormat.Avro,
    APath, AValue.Kind, Format('the schema says %s and the value is %s.',
    [ASchema.TypeName, EStructuralConversionError.KindName(AValue.Kind)]));
end;

{ A float or double field from a value that is a number but not a binary
  float: an integer is exact up to the field's precision, as before; a
  decimal is an approximation, which only Natural writes. }
function AvroFloatOf(AValue: TDynamicValue; ASchema: TAvroSchema;
  const AOptions: TStructuralConversionOptions; const APath: string): Double;
begin
  case AValue.Kind of
    TDynamicKind.Float: Exit(AValue.AsFloat);
    TDynamicKind.Int: Exit(AValue.AsInt);
    TDynamicKind.Decimal:
      if AvroAdapts(AOptions) and
         TStructuralText.TryParseFloat(AValue.AsDecimal, Result) then Exit;
  end;
  RefuseAvroKind(AValue, ASchema, AOptions, APath);
  Result := 0;
end;

class function TAvroEngine.DynamicToAvro(AValue: TDynamicValue;
  ASchema: TAvroSchema): TAvroValue;
begin
  Result := DynamicToAvro(AValue, ASchema, TStructuralConversionOptions.Default,
    '$');
end;

class function TAvroEngine.DynamicToAvro(AValue: TDynamicValue;
  ASchema: TAvroSchema; const AOptions: TStructuralConversionOptions;
  const APath: string): TAvroValue;
var
  I, Index, Fit, Best, Second: Integer;
  Field: TAvroField;
  Child: TDynamicValue;
  Target: TAvroSchema;
begin
  if ASchema = nil then
    raise ESerializationSchemaRequired.CreateFor(TSerializationFormat.Avro,
      'writing a structural tree');

  { A union: the branch is chosen by what the value IS - never merely by
    coming first. Null goes to the null branch. Otherwise every branch is
    scored by AvroBranchFit and the best one wins; a value no branch holds
    is refused in every profile, and a tie at the top is Natural's to break
    by declaration order and Strict's and Lossless's to refuse. }
  if ASchema.SchemaType = TAvroType.Union then
  begin
    if (AValue = nil) or (AValue.Kind = TDynamicKind.Null) then
    begin
      Index := ASchema.IndexOfBranchType(TAvroType.Null);
      if Index < 0 then
        raise EAvroInputError.CreateFmt(
          'At %s: a null value, and no branch of this union is null.',
          [APath]);
      Exit(TAvroValue.NewNull);
    end;
    Best := -1;
    Second := -1;
    Fit := 0;
    for I := 0 to ASchema.BranchCount - 1 do
    begin
      Index := AvroBranchFit(AValue, ASchema.Branches[I]);
      if Index = 0 then Continue;
      if (Best < 0) or (Index > Fit) then
      begin
        Best := I;
        Second := -1;
        Fit := Index;
      end
      else if (Index = Fit) and (Second < 0) then
        Second := I;
    end;
    if Best < 0 then
      raise EStructuralConversionError.CreateFor(
        TStructuralIssue.UnsupportedValueKind, AOptions,
        TSerializationFormat.Avro, APath, AValue.Kind,
        'no branch of the union can hold this value (' +
        ASchema.ToJson + ').');
    if (Second >= 0) and not AvroAdapts(AOptions) then
      AvroRefuse(AOptions, APath, AValue.Kind, Format(
        'the union branches %s and %s hold this value equally well, and %s ' +
        'does not pick one for the caller. Convert with Natural, which takes ' +
        'the first in declaration order, or narrow the schema.',
        [ASchema.Branches[Best].TypeName, ASchema.Branches[Second].TypeName,
         AvroProfileName(AOptions)]));
    Exit(DynamicToAvro(AValue, ASchema.Branches[Best], AOptions, APath));
  end;

  if (AValue = nil) or (AValue.Kind = TDynamicKind.Null) then
  begin
    if ASchema.SchemaType = TAvroType.Null then Exit(TAvroValue.NewNull);
    raise EAvroInputError.CreateFmt(
      'At %s: a null value, and the schema says %s. Avro has no null except ' +
      'the null type, so a nullable field has to be a union with it.',
      [APath, ASchema.TypeName]);
  end;

  case ASchema.SchemaType of
    TAvroType.Bool:
      begin
        if AValue.Kind <> TDynamicKind.Bool then
          RefuseAvroKind(AValue, ASchema, AOptions, APath);
        Exit(TAvroValue.NewBool(AValue.AsBool));
      end;
    TAvroType.Int:
      begin
        if ASchema.LogicalType in [TAvroLogicalType.Date,
          TAvroLogicalType.TimeMillis] then
          Exit(DynamicTemporal(AValue, ASchema));
        if AValue.Kind <> TDynamicKind.Int then
          RefuseAvroKind(AValue, ASchema, AOptions, APath);
        { An int is 32 bits: narrowing a wider value wrote a different
          number without a word - 5000000000 as 705032704. }
        if (AValue.AsInt < Low(Integer)) or (AValue.AsInt > High(Integer)) then
          raise EAvroInputError.CreateFmt(
            'At %s: %d does not fit in an Avro int, which is 32 bits. ' +
            'Declare the field a long.', [APath, AValue.AsInt]);
        Exit(TAvroValue.NewInt(Integer(AValue.AsInt)));
      end;
    TAvroType.Long:
      if ASchema.LogicalType <> TAvroLogicalType.None then
        Exit(DynamicTemporal(AValue, ASchema))
      else
      begin
        if AValue.Kind <> TDynamicKind.Int then
          RefuseAvroKind(AValue, ASchema, AOptions, APath);
        Exit(TAvroValue.NewLong(AValue.AsInt));
      end;
    TAvroType.Float:
      Exit(TAvroValue.NewFloat(AvroFloatOf(AValue, ASchema, AOptions, APath)));
    TAvroType.Double:
      Exit(TAvroValue.NewDouble(AvroFloatOf(AValue, ASchema, AOptions, APath)));
    TAvroType.Str, TAvroType.Enum:
      begin
        if AValue.Kind <> TDynamicKind.Str then
          RefuseAvroKind(AValue, ASchema, AOptions, APath);
        if ASchema.SchemaType = TAvroType.Enum then
          Exit(TAvroValue.NewEnum(AValue.AsStr));
        Exit(TAvroValue.NewStr(AValue.AsStr));
      end;
    TAvroType.Bytes, TAvroType.Fixed:
      begin
        if ASchema.LogicalType = TAvroLogicalType.Decimal then
          Exit(TAvroValue.NewDecimal(
            DynamicDecimalText(AValue, ASchema, AOptions, APath)));
        if AValue.Kind <> TDynamicKind.Bytes then
          RefuseAvroKind(AValue, ASchema, AOptions, APath);
        if ASchema.SchemaType = TAvroType.Fixed then
          Exit(TAvroValue.NewFixed(AValue.AsBytes));
        Exit(TAvroValue.NewBytes(AValue.AsBytes));
      end;
    TAvroType.Arr:
      begin
        if AValue.Kind <> TDynamicKind.Arr then
          RefuseAvroKind(AValue, ASchema, AOptions, APath);
        Result := TAvroValue.NewArray;
        try
          for I := 0 to AValue.Count - 1 do
            Result.Add(DynamicToAvro(AValue.Items[I], ASchema.ItemType,
              AOptions, Format('%s[%d]', [APath, I])));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
    TAvroType.Map:
      begin
        if AValue.Kind <> TDynamicKind.Obj then
          RefuseAvroKind(AValue, ASchema, AOptions, APath);
        Result := TAvroValue.NewMap;
        try
          for I := 0 to AValue.Count - 1 do
            Result.Add(AValue.Names[I],
              DynamicToAvro(AValue.Items[I], ASchema.ValueType, AOptions,
                APath + '.' + AValue.Names[I]));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
    TAvroType.Rec:
      begin
        if AValue.Kind <> TDynamicKind.Obj then
          RefuseAvroKind(AValue, ASchema, AOptions, APath);
        { A member the schema does not name. The schema is the destination's
          whole vocabulary, so Natural omits it - documented - and Strict and
          Lossless refuse, because the result would silently be a smaller
          document than the one given. Avro has no standard place to carry
          it, so Lossless has nothing to fall back on. }
        if not AvroAdapts(AOptions) then
          for I := 0 to AValue.Count - 1 do
            if ASchema.IndexOfField(AValue.Names[I]) < 0 then
              AvroRefuse(AOptions, APath + '.' + AValue.Names[I],
                AValue.Items[I].Kind, Format(
                'the member "%s" is not a field of the Avro record %s, so ' +
                'writing the record would drop it. %s refuses rather than ' +
                'omit it; add the field to the schema, or convert with the ' +
                'Natural profile, which omits it.',
                [AValue.Names[I], ASchema.TypeName, AvroProfileName(AOptions)]));
        Result := TAvroValue.NewRecord;
        try
          for I := 0 to ASchema.FieldCount - 1 do
          begin
            Field := ASchema.Fields[I];
            Child := AValue.Find(Field.Name);
            if Child = nil then
            begin
              Target := Field.FieldType;
              if (Target.SchemaType = TAvroType.Union) and
                 (Target.IndexOfBranchType(TAvroType.Null) >= 0) then
              begin
                Result.Add(Field.Name, TAvroValue.NewNull);
                Continue;
              end;
              { THE FIELD'S OWN DEFAULT, when the schema declares one.

                This is the same rule resolution uses for a field the writer
                never wrote, applied to a tree that does not have it either.
                It is what makes schema evolution work through the dynamic
                tree: reading a document written against an older schema and
                writing it against a newer one fills the added field from the
                newer schema's default, exactly as an Avro reader would. }
              if Field.Default <> nil then
              begin
                Result.Add(Field.Name,
                  DefaultToValue(Target, Field.Default,
                    APath + '.' + Field.Name));
                Continue;
              end;
              raise EAvroInputError.CreateFmt(
                'At %s: the schema requires the field "%s" and the value has ' +
                'no member of that name. Avro writes fields in order with ' +
                'nothing between them, so a missing one shifts every byte ' +
                'after it.', [APath, Field.Name]);
            end;
            Result.Add(Field.Name, DynamicToAvro(Child, Field.FieldType,
              AOptions, APath + '.' + Field.Name));
          end;
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
  end;
  raise EAvroInputError.CreateFmt('At %s: cannot write a %s.',
    [APath, ASchema.TypeName]);
end;

end.
