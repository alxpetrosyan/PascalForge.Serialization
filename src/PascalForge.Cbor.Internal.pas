{*******************************************************************************
  PascalForge.Cbor.Internal

  INTERNAL IMPLEMENTATION UNIT - applications should not use this unit directly.

  Implements the CBOR engine: reader, writer, dynamic bridge and contract
  engine.
  Exposed through the public facade PascalForge.Cbor (TCborSerializer).

  Registration
    Format registration lives in PascalForge.Cbor.Registration and is explicit.

  Documentation
    docs/formats/cbor.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Cbor.Internal;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  THE CBOR ENGINE.

  Target: RFC 8949 / STD 94, in full - every major type, every argument
  encoding, indefinite lengths, all three float widths, the simple-value
  space, and semantic tags with the unrecognised ones carried through rather
  than dropped.

  Three layers, and they are separate on purpose:

    the READER and WRITER          bytes <-> TCborValue
    the DYNAMIC BRIDGE             TCborValue <-> TDynamicValue
    the CONTRACT ENGINE            a Delphi value <-> TCborValue

  Nothing routes through another format. A Delphi value becomes CBOR's own
  data model and then CBOR's own bytes; the dynamic tree appears only when
  somebody asks to convert a document whose contract they do not have.

  WHY THE CONTRACT ENGINE BUILDS A TREE RATHER THAN STREAMING

  JSON and BSON here build a cached plan per type and write straight to the
  output. CBOR's contract engine walks RTTI into a TCborValue and encodes
  that, which costs one intermediate allocation per document.

  It buys two things that matter more here than the allocation costs.
  Deterministic encoding (RFC 8949 section 4.2) has to SORT a map's entries
  by their encoded bytes, which cannot be done while streaming because the
  bytes do not exist yet. And a caller who wants to inspect or adjust a
  document before it is written has TCborValue to do it in, which is the
  same model the reader produces - one data model, not two.

  This is written down rather than left to be discovered, because it is a
  real difference from the older formats and somebody profiling a hot loop
  deserves to know where the allocation comes from.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections, System.Generics.Defaults, System.SyncObjs,
  System.DateUtils, System.Math, System.Variants,
  PascalForge.Nullable,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Serialization.Internal,
  PascalForge.Cbor;
type
  { ------------------------------------------------------------------------
    IEEE 754 WIDTHS

    Delphi has no half type, so binary16 is assembled and taken apart by
    hand. The subnormals and the infinities are the whole reason this is
    more than a shift, and getting them wrong is invisible until somebody
    sends 6.103515625e-05.
    ------------------------------------------------------------------------ }
  TCborFloats = record
  public
    { True only when the narrower width holds the value EXACTLY. A lossy
      narrowing is not a shorter encoding of the same number; it is a
      different number. }
    class function TryDoubleToHalf(AValue: Double; out ABits: Word): Boolean; static;
    class function TryDoubleToSingle(AValue: Double; out ABits: UInt32): Boolean; static;
    class function BitsToDouble(ABits: UInt64;
      AWidth: TCborFloatWidth): Double; static;
  end;

  { Tag 37 is sixteen bytes in RFC 4122 order, which is NOT the order a
    Delphi TGUID has in memory: D1 and D2 are little-endian there. Writing
    the memory image would produce a UUID that every other implementation
    reads with its first eight bytes reversed. }
  TCborGuids = record
  public
    class function ToRfc4122(const AValue: TGUID): TBytes; static;
    class function FromRfc4122(const AValue: TBytes): TGUID; static;
  end;

  { Tag 0 is an RFC 3339 date-time string. }
  TCborDateText = record
  public
    class function Encode(AValue: TDateTime): string; static;
    class function TryDecode(const AText: string;
      out AValue: TDateTime): Boolean; static;
    { A TDateTime as whole milliseconds since the Unix epoch, for every epoch
      this engine writes - tag 1, and the bare seconds and milliseconds.
      Delphi's own encoding, so an instant before 1899-12-30 is not put a day
      early, and refused outside the years 1 to 9999. }
    class function EpochMillis(AValue: TDateTime): Int64; static;
  end;

  { ------------------------------------------------------------------------
    ARBITRARY PRECISION, AS BYTES AND AS DIGITS

    CBOR tags 2 and 3 carry an integer of any size as a big-endian
    magnitude, and tag 4 carries a decimal fraction whose mantissa may be
    one of those. Delphi has no big integer, and the dynamic tree holds a
    decimal as TEXT - so the conversion the library actually needs is
    between a byte magnitude and digits, in both directions.

    Long division by ten over a byte array, and multiplication by ten with a
    carry. Not fast, and exact, which is the correct trade for a value whose
    whole point is that a Double would ruin it.
    ------------------------------------------------------------------------ }
  TCborBigInt = record
  public
    { Leading zero bytes carry no information and are not written. }
    class function TrimMagnitude(const AValue: TBytes): TBytes; static;
    class function IncrementMagnitude(const AValue: TBytes): TBytes; static;
    class function DecrementMagnitude(const AValue: TBytes): TBytes; static;
    class function MagnitudeToDecimal(const AValue: TBytes): string; static;
    { The inverse: decimal digits, with no sign, to a big-endian magnitude. }
    class function DecimalToMagnitude(const AText: string): TBytes; static;
    class function Concat(const A, B: TBytes): TBytes; static;

    { A mantissa of any length as the smallest CBOR value that holds it: an
      integer when it fits, and a bignum when it does not. }
    class function MantissaValue(const AMantissa: string): TCborValue; static;

    { Tag 4 and tag 5 contents - a two-element array of exponent and
      mantissa - as decimal text. False when the content is not that shape. }
    class function DecimalFractionToText(AContent: TCborValue;
      out AText: string): Boolean; static;
    class function BigfloatToText(AContent: TCborValue;
      out AText: string): Boolean; static;
  end;

  TCborEngine = class
  strict private
    class var FLock: TCriticalSection;
    class var FFrozen: Boolean;
    class var FDefaultEncode: TCborEncodeOptions;
    class var FDatePolicies: TDateTimePolicies;
    class var FEnumMappings: TDictionary<string, TArray<string>>;
    class var FTypeSerializers: TDictionary<string, TCborValueSerializerClass>;
    class procedure CheckNotFrozen; static;
  public
    class constructor Create;
    class destructor Destroy;

    { --- the codec --- }
    class function Encode(AValue: TCborValue;
      const AOptions: TCborEncodeOptions): TBytes; static;
    class function Decode(const AData: TBytes;
      const AOptions: TCborDecodeOptions): TCborValue; static;
    class function IsDeterministic(const AData: TBytes): Boolean; static;

    { --- the contract --- }
    class function SerializeRoot(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AOptions: TCborEncodeOptions): TBytes; static;
    class function DeserializeRoot(ATypeInfo: PTypeInfo; const AData: TBytes;
      const AExisting: TValue): TValue; static;

    { --- cross-format, reached only through the registry --- }
    class function FromPayload(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; static;
    class function FromPayloadStructural(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat;
      AProfile: TStructuralConversionProfile): TBytes; static;

    { --- the dynamic tree (structural conversion only) --- }
    { A map key that is not text becomes its diagnostic text under Natural -
      documented - and is refused, with its path, under Strict and Lossless:
      the dynamic tree's names are strings, so no destination reached
      through it can keep the key's own type. The one-argument form is
      Natural at '$'. }
    class function CborToDynamic(AValue: TCborValue): TDynamicValue; overload;
      static;
    class function CborToDynamic(AValue: TCborValue;
      const AOptions: TStructuralConversionOptions;
      const APath: string): TDynamicValue; overload; static;
    class function DynamicToCbor(AValue: TDynamicValue): TCborValue; static;

    { --- configuration --- }
    class procedure SetDateTimePolicy(ATypeInfo: PTypeInfo;
      const AFieldName: string; AKind: Integer;
      const APattern: string); static;
    class procedure RegisterEnumMapping(ATypeInfo: PTypeInfo;
      const AValues: array of string); static;
    class procedure RegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TCborValueSerializerClass); static;
    class procedure SetDefaultEncodeOptions(
      const AOptions: TCborEncodeOptions); static;
    class function DefaultEncodeOptions: TCborEncodeOptions; static;
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;
    class procedure ResetConfiguration; static;

    { Looked up on the warm path, so they are here rather than being
      rediscovered from attributes on every value. }
    class function TryGetEnumMapping(ATypeInfo: PTypeInfo;
      out AValues: TArray<string>): Boolean; static;
    class function TryGetTypeSerializer(ATypeInfo: PTypeInfo;
      out AClass: TCborValueSerializerClass): Boolean; static;
  end;

implementation

uses
  System.NetEncoding;

{ ===========================================================================
  THE SHARED HELPERS

  Used by TCborValue in the public unit as well as by the codec below, which
  is why they are in this unit's interface rather than hidden here.
  =========================================================================== }

class function TCborFloats.TryDoubleToHalf(AValue: Double;
  out ABits: Word): Boolean;
var
  S: Single;
  U, Sign, Exp, Mant: UInt32;
  NewExp: Integer;
begin
  ABits := 0;

  if IsNan(AValue) then
  begin
    { The canonical quiet NaN, which is what every implementation writes and
      what the specification's own vectors show. A NaN payload is not data. }
    ABits := $7E00;
    Exit(True);
  end;
  if IsInfinite(AValue) then
  begin
    if AValue < 0 then ABits := $FC00 else ABits := $7C00;
    Exit(True);
  end;

  { Only a value that survives the trip through single can survive the trip
    through half, and going via single makes the exponent and mantissa
    available in a fixed layout. }
  S := AValue;
  if S <> AValue then Exit(False);
  U := PUInt32(@S)^;
  Sign := (U shr 31) and 1;
  Exp := (U shr 23) and $FF;
  Mant := U and $7FFFFF;

  if (Exp = 0) and (Mant = 0) then
  begin
    ABits := Word(Sign shl 15);
    Exit(True);
  end;

  NewExp := Integer(Exp) - 127 + 15;
  if (NewExp >= 1) and (NewExp <= 30) then
  begin
    { Normal. Exact only when the thirteen mantissa bits that half has no
      room for are all zero. }
    if (Mant and $1FFF) <> 0 then Exit(False);
    ABits := Word((Sign shl 15) or (UInt32(NewExp) shl 10) or (Mant shr 13));
    Exit(True);
  end;

  if (NewExp >= -10) and (NewExp <= 0) then
  begin
    { Subnormal: the implicit leading one comes back and the shift grows by
      one for each step below the smallest normal exponent. }
    Mant := Mant or $800000;
    if (Mant and ((UInt32(1) shl (14 - NewExp)) - 1)) <> 0 then Exit(False);
    ABits := Word((Sign shl 15) or (Mant shr (14 - NewExp)));
    Exit(True);
  end;

  Result := False;
end;

class function TCborFloats.TryDoubleToSingle(AValue: Double;
  out ABits: UInt32): Boolean;
var
  S: Single;
begin
  if IsNan(AValue) then
  begin
    ABits := $7FC00000;
    Exit(True);
  end;
  S := AValue;
  if S <> AValue then
  begin
    ABits := 0;
    Exit(False);
  end;
  ABits := PUInt32(@S)^;
  Result := True;
end;

class function TCborFloats.BitsToDouble(ABits: UInt64;
  AWidth: TCborFloatWidth): Double;
var
  Sign, Exp, Mant: Integer;
  S: Single;
  U32: UInt32;
  D: Double;
begin
  case AWidth of
    TCborFloatWidth.Half:
      begin
        Sign := Integer((ABits shr 15) and 1);
        Exp := Integer((ABits shr 10) and $1F);
        Mant := Integer(ABits and $3FF);
        if Exp = $1F then
        begin
          if Mant <> 0 then Exit(NaN);
          if Sign = 1 then Exit(NegInfinity);
          Exit(Infinity);
        end;
        if Exp = 0 then Result := Mant * Power(2, -24)
        else Result := (1024 + Mant) * Power(2, Exp - 25);
        if Sign = 1 then Result := -Result;
      end;
    TCborFloatWidth.Single:
      begin
        U32 := UInt32(ABits);
        S := PSingle(@U32)^;
        Result := S;
      end;
  else
    D := PDouble(@ABits)^;
    Result := D;
  end;
end;

class function TCborGuids.ToRfc4122(const AValue: TGUID): TBytes;
begin
  SetLength(Result, 16);
  Result[0] := Byte(AValue.D1 shr 24);
  Result[1] := Byte(AValue.D1 shr 16);
  Result[2] := Byte(AValue.D1 shr 8);
  Result[3] := Byte(AValue.D1);
  Result[4] := Byte(AValue.D2 shr 8);
  Result[5] := Byte(AValue.D2);
  Result[6] := Byte(AValue.D3 shr 8);
  Result[7] := Byte(AValue.D3);
  Move(AValue.D4[0], Result[8], 8);
end;

class function TCborGuids.FromRfc4122(const AValue: TBytes): TGUID;
begin
  FillChar(Result, SizeOf(Result), 0);
  if Length(AValue) <> 16 then Exit;
  Result.D1 := (UInt32(AValue[0]) shl 24) or (UInt32(AValue[1]) shl 16) or
               (UInt32(AValue[2]) shl 8) or AValue[3];
  Result.D2 := Word((Word(AValue[4]) shl 8) or AValue[5]);
  Result.D3 := Word((Word(AValue[6]) shl 8) or AValue[7]);
  Move(AValue[8], Result.D4[0], 8);
end;

class function TCborDateText.Encode(AValue: TDateTime): string;
begin
  { RFC 3339, which is what tag 0 means. The tree holds a bare TDateTime, so
    the offset written is Z: shifting it by whatever offset the converting
    machine happens to sit at would make the value depend on where it ran.
    FormatDateTime spells a day before year 1 as 0000-00-00, which is not
    even the value, so that is refused first. }
  TStructuralText.CheckDateTime(AValue);
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz"Z"', AValue,
    TFormatSettings.Invariant);
end;

class function TCborDateText.EpochMillis(AValue: TDateTime): Int64;
begin
  if TStructuralText.TryDateTimeToUnixMillis(AValue, Result) then Exit;
  TStructuralText.CheckDateTime(AValue);
  { A day number in range that still rounds to 10000-01-01 at the
    millisecond. }
  raise ESerializationUnsupported.CreateFmt(
    'The TDateTime %s rounds to 10000-01-01, outside the years 1 to 9999: ' +
    'no date format here can state it, and every reader here refuses it.',
    [FloatToStr(AValue, TFormatSettings.Invariant)]);
end;

class function TCborDateText.TryDecode(const AText: string;
  out AValue: TDateTime): Boolean;
begin
  { AReturnUTC is True deliberately: the instant is taken exactly as the
    document states it, and an offset in the text is normalised to UTC. The
    alternative shifts the value by wherever the reading machine happens to
    sit, which would make the same document decode to two different times on
    two different machines - and Encode above writes Z for the same reason. }
  AValue := 0;
  try
    AValue := TStructuralText.DecodeIso8601(AText);
    Result := True;
  except
    on E: EConvertError do Result := False;
  end;
end;

{ ------------------------------------------------------ arbitrary precision }

{ A 64-bit argument as eight big-endian bytes, the shape a magnitude has. }
function UInt64ToBigEndian(AValue: UInt64): TBytes;
var
  I: Integer;
begin
  SetLength(Result, 8);
  for I := 7 downto 0 do
  begin
    Result[I] := Byte(AValue and $FF);
    AValue := AValue shr 8;
  end;
end;

class function TCborBigInt.TrimMagnitude(const AValue: TBytes): TBytes;
var
  I: Integer;
begin
  I := 0;
  while (I < Length(AValue) - 1) and (AValue[I] = 0) do Inc(I);
  Result := System.Copy(AValue, I, Length(AValue) - I);
  if Length(Result) = 0 then Result := TBytes.Create(0);
end;

class function TCborBigInt.IncrementMagnitude(const AValue: TBytes): TBytes;
var
  I: Integer;
  Carry: Boolean;
begin
  Result := System.Copy(AValue, 0, Length(AValue));
  if Length(Result) = 0 then Exit(TBytes.Create(1));
  Carry := True;
  for I := Integer(High(Result)) downto 0 do
  begin
    if not Carry then Break;
    if Result[I] = $FF then Result[I] := 0
    else
    begin
      Inc(Result[I]);
      Carry := False;
    end;
  end;
  if Carry then Result := Concat(TBytes.Create(1), Result);
end;

class function TCborBigInt.DecrementMagnitude(const AValue: TBytes): TBytes;
var
  I: Integer;
  Borrow: Boolean;
begin
  Result := System.Copy(AValue, 0, Length(AValue));
  if Length(Result) = 0 then Exit(TBytes.Create(0));
  Borrow := True;
  for I := Integer(High(Result)) downto 0 do
  begin
    if not Borrow then Break;
    if Result[I] = 0 then Result[I] := $FF
    else
    begin
      Dec(Result[I]);
      Borrow := False;
    end;
  end;
  Result := TrimMagnitude(Result);
end;

class function TCborBigInt.Concat(const A, B: TBytes): TBytes;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then Move(B[0], Result[Length(A)], Length(B));
end;

class function TCborBigInt.MagnitudeToDecimal(const AValue: TBytes): string;
var
  Work: TBytes;
  Digits: string;
  I, Len: Integer;
  Remainder, Cur: Integer;
  AllZero: Boolean;
begin
  Work := System.Copy(AValue, 0, Length(AValue));
  if Length(Work) = 0 then Exit('0');

  Digits := '';
  repeat
    { Long division by ten, most significant byte first. The remainder of
      each step becomes the high part of the next, exactly as on paper. }
    Remainder := 0;
    Len := Integer(Length(Work));
    for I := 0 to Len - 1 do
    begin
      Cur := (Remainder shl 8) or Work[I];
      Work[I] := Byte(Cur div 10);
      Remainder := Cur mod 10;
    end;
    Digits := Char(Ord('0') + Remainder) + Digits;

    AllZero := True;
    for I := 0 to Len - 1 do
      if Work[I] <> 0 then
      begin
        AllZero := False;
        Break;
      end;
  until AllZero;

  { Strip the leading zeros the loop can leave when the magnitude had them. }
  I := 1;
  while (I < Length(Digits)) and (Digits[I] = '0') do Inc(I);
  Result := System.Copy(Digits, I, MaxInt);
end;

class function TCborBigInt.DecimalToMagnitude(const AText: string): TBytes;
var
  I, J: Integer;
  Carry, Cur: Integer;
  Work: TBytes;
begin
  Work := TBytes.Create(0);
  for I := 1 to Length(AText) do
  begin
    if not CharInSet(AText[I], ['0'..'9']) then Continue;
    { Multiply by ten and add the digit, least significant byte last. }
    Carry := Ord(AText[I]) - Ord('0');
    for J := Integer(High(Work)) downto 0 do
    begin
      Cur := Work[J] * 10 + Carry;
      Work[J] := Byte(Cur and $FF);
      Carry := Cur shr 8;
    end;
    while Carry <> 0 do
    begin
      Work := Concat(TBytes.Create(Byte(Carry and $FF)), Work);
      Carry := Carry shr 8;
    end;
  end;
  Result := TrimMagnitude(Work);
end;

class function TCborBigInt.MantissaValue(
  const AMantissa: string): TCborValue;
var
  Negative: Boolean;
  Digits: string;
  Value: Int64;
  Magnitude: TBytes;
begin
  Digits := Trim(AMantissa);
  Negative := (Digits <> '') and (Digits[1] = '-');
  if Negative or ((Digits <> '') and (Digits[1] = '+')) then
    Digits := System.Copy(Digits, 2, MaxInt);

  { An integer when it fits, and a bignum when it does not. Writing a bignum
    for 5 would be correct and would look ridiculous in a hex dump. }
  if TryStrToInt64(AMantissa, Value) then Exit(TCborValue.NewInt(Value));

  Magnitude := DecimalToMagnitude(Digits);
  if Negative then
  begin
    { Tag 3 carries -1-n, so the magnitude written is one less than the
      absolute value. }
    Result := TCborValue.NewBignum(DecrementMagnitude(Magnitude), True);
  end
  else
    Result := TCborValue.NewBignum(Magnitude, False);
end;

{ Multiply a big-endian magnitude by a small factor, byte by byte, because
  the carry has to cross byte boundaries and a shift would only do the one
  factor. AFactor stays small enough that a byte times it plus the carry
  cannot overflow an Integer, which every caller here satisfies. }
function MultiplyMagnitude(const AValue: TBytes; AFactor: Integer): TBytes;
var
  I, Cur, Carry: Integer;
begin
  Result := System.Copy(AValue, 0, Length(AValue));
  Carry := 0;
  for I := Integer(High(Result)) downto 0 do
  begin
    Cur := Result[I] * AFactor + Carry;
    Result[I] := Byte(Cur and $FF);
    Carry := Cur shr 8;
  end;
  while Carry <> 0 do
  begin
    Result := TCborBigInt.Concat(TBytes.Create(Byte(Carry and $FF)), Result);
    Carry := Carry shr 8;
  end;
end;

{ The mantissa of a tag 4 or tag 5 content array, as signed decimal text.
  The mantissa may itself be a bignum, which is why this is not AsInt64. }
function MantissaText(AValue: TCborValue; out AText: string): Boolean;
begin
  AText := '';
  if AValue = nil then Exit(False);
  case AValue.Kind of
    TCborKind.UInt:
      begin
        AText := UIntToStr(AValue.AsUInt64);
        Exit(True);
      end;
    TCborKind.NegInt:
      begin
        if AValue.FitsInt64 then AText := IntToStr(AValue.AsInt64)
        else
          AText := '-' + TCborBigInt.MagnitudeToDecimal(
            TCborBigInt.IncrementMagnitude(AValue.AsBytes));
        Exit(True);
      end;
    TCborKind.Tag:
      begin
        if AValue.TagNumber = TCborTags.PositiveBignum then
        begin
          AText := TCborBigInt.MagnitudeToDecimal(AValue.TagContent.AsBytes);
          Exit(True);
        end;
        if AValue.TagNumber = TCborTags.NegativeBignum then
        begin
          AText := '-' + TCborBigInt.MagnitudeToDecimal(
            TCborBigInt.IncrementMagnitude(AValue.TagContent.AsBytes));
          Exit(True);
        end;
      end;
  end;
  Result := False;
end;

{ Shifts a decimal point into signed digit text. No Double is involved at
  any point, which is the whole reason a decimal is held as text. }
function ApplyDecimalExponent(const AMantissa: string;
  AExponent: Int64): string;
var
  Negative: Boolean;
  Digits: string;
begin
  Digits := AMantissa;
  Negative := (Digits <> '') and (Digits[1] = '-');
  if Negative then Digits := System.Copy(Digits, 2, MaxInt);

  { The zeros in one piece: prepending them one at a time was quadratic in
    the exponent. }
  if AExponent = 0 then Result := Digits
  else if AExponent > 0 then
    Result := Digits + StringOfChar('0', Integer(AExponent))
  else
  begin
    { A negative exponent moves the point left, padding with zeros when the
      mantissa is shorter than the shift. }
    if Length(Digits) <= -AExponent then
      Digits := StringOfChar('0', Integer(-AExponent) - Length(Digits) + 1) +
        Digits;
    Result := System.Copy(Digits, 1, Length(Digits) + Integer(AExponent)) +
      '.' + System.Copy(Digits, Length(Digits) + Integer(AExponent) + 1, MaxInt);
  end;
  if Negative then Result := '-' + Result;
end;

class function TCborBigInt.DecimalFractionToText(AContent: TCborValue;
  out AText: string): Boolean;
var
  Mantissa: string;
  Exponent: TCborValue;
begin
  AText := '';
  if (AContent = nil) or (AContent.Kind <> TCborKind.Arr) or
     (AContent.Count <> 2) then Exit(False);
  Exponent := AContent.Items[0];
  if not Exponent.IsInteger then Exit(False);
  if not MantissaText(AContent.Items[1], Mantissa) then Exit(False);
  { The exponent is how many places the digits run to, so it is bounded
    before a single one is built: eleven bytes asked for four hundred million
    zeros and got EOutOfMemory, and a smaller negative one hung the reader. }
  if (not Exponent.FitsInt64) or (Exponent.AsInt64 > CborDecimalExponentLimit) or
     (Exponent.AsInt64 < -CborDecimalExponentLimit) then
    raise ECborInputError.CreateFmt(
      'A decimal fraction (tag 4) has the exponent %s, and this reader ' +
      'accepts exponents from -%d to %d. Its digits would run to that many ' +
      'places: a few bytes asking for that much text is a denial of ' +
      'service, not a number.',
      [Exponent.ToDiagnostic, CborDecimalExponentLimit, CborDecimalExponentLimit]);
  AText := ApplyDecimalExponent(Mantissa, Exponent.AsInt64);
  Result := True;
end;

class function TCborBigInt.BigfloatToText(AContent: TCborValue;
  out AText: string): Boolean;
var
  Mantissa: string;
  Exponent: Int64;
  Magnitude: TBytes;
  I: Integer;
  Negative: Boolean;
begin
  AText := '';
  if (AContent = nil) or (AContent.Kind <> TCborKind.Arr) or
     (AContent.Count <> 2) then Exit(False);
  if not AContent.Items[0].IsInteger then Exit(False);
  if not MantissaText(AContent.Items[1], Mantissa) then Exit(False);
  { An exponent outside Int64 is far past the limit below, and is declined
    the same way - not handed to AsInt64, which raises ECborRangeError. }
  if not AContent.Items[0].FitsInt64 then Exit(False);
  Exponent := AContent.Items[0].AsInt64;

  { Tag 5 is mantissa times TWO to the exponent, and EVERY such value has an
    exact decimal expansion in both directions: doubling is exact, and so is
    halving, because one over two to the n is five to the n over ten to the
    n. So this never rounds - it only declines an exponent so large that the
    digits would be a denial of service rather than a number. }
  if (Exponent > CborBigfloatExponentLimit) or
     (Exponent < -CborBigfloatExponentLimit) then Exit(False);

  Negative := (Mantissa <> '') and (Mantissa[1] = '-');
  if Negative then Mantissa := System.Copy(Mantissa, 2, MaxInt);
  Magnitude := DecimalToMagnitude(Mantissa);

  if Exponent >= 0 then
  begin
    for I := 1 to Integer(Exponent) do Magnitude := MultiplyMagnitude(Magnitude, 2);
    AText := MagnitudeToDecimal(Magnitude);
  end
  else
  begin
    { m * 2^-k = (m * 5^k) / 10^k: multiply, then move the point k places.
      The result is exact and the trailing zeros it may leave behind are an
      artefact of the arithmetic rather than significance the document
      stated, so they go. }
    for I := 1 to Integer(-Exponent) do Magnitude := MultiplyMagnitude(Magnitude, 5);
    AText := ApplyDecimalExponent(MagnitudeToDecimal(Magnitude), Exponent);
    if Pos('.', AText) > 0 then
    begin
      while (AText <> '') and (AText[Length(AText)] = '0') do
        SetLength(AText, Length(AText) - 1);
      if (AText <> '') and (AText[Length(AText)] = '.') then
        SetLength(AText, Length(AText) - 1);
    end;
  end;

  if Negative then AText := '-' + AText;
  Result := True;
end;


{ ===========================================================================
  THE WRITER

  One head, then the payload. A head is the major type in the top three bits
  and an ARGUMENT in the low five: 0..23 means itself, and 24, 25, 26, 27
  mean the argument follows in one, two, four or eight big-endian bytes. 31
  means indefinite, and 28, 29 and 30 are reserved and are never written.

  SHORTEST FORM ALWAYS. The specification permits a longer head than
  necessary, and every other implementation writes the shortest, so writing
  anything else would make the output look wrong to a human reading a hex
  dump even when it parses. A DECODED value remembers the head width it
  arrived with, so that a document can be re-encoded exactly as it was; that
  memory is used only when the caller has not asked for deterministic
  output.
  =========================================================================== }

type
  TCborWriter = record
  strict private
    FData: TBytes;
    FPos: Integer;
    procedure Ensure(ACount: Integer);
  public
    procedure Init;
    function ToBytes: TBytes;
    procedure PutByte(AValue: Byte);
    procedure PutRaw(const AValue: TBytes);
    procedure PutHead(AMajor: TCborMajorType; AArgument: UInt64;
      AMinWidth: Byte = 0);
    procedure PutIndefiniteHead(AMajor: TCborMajorType);
    procedure PutBreak;
    property Position: Integer read FPos;
  end;

procedure TCborWriter.Init;
begin
  SetLength(FData, 256);
  FPos := 0;
end;

procedure TCborWriter.Ensure(ACount: Integer);
begin
  if FPos + ACount <= Length(FData) then Exit;
  SetLength(FData, Max(Length(FData) * 2, FPos + ACount));
end;

function TCborWriter.ToBytes: TBytes;
begin
  Result := Copy(FData, 0, FPos);
end;

procedure TCborWriter.PutByte(AValue: Byte);
begin
  Ensure(1);
  FData[FPos] := AValue;
  Inc(FPos);
end;

procedure TCborWriter.PutRaw(const AValue: TBytes);
begin
  if Length(AValue) = 0 then Exit;
  Ensure(Integer(Length(AValue)));
  Move(AValue[0], FData[FPos], Length(AValue));
  Inc(FPos, Length(AValue));
end;

procedure TCborWriter.PutHead(AMajor: TCborMajorType; AArgument: UInt64;
  AMinWidth: Byte);
var
  Base: Byte;
  I: Integer;
  Width: Byte;
begin
  Base := Byte(Byte(AMajor) shl 5);

  { The shortest width that holds the argument, unless the caller asked for
    a wider one because that is the width the value arrived with. }
  if AArgument <= 23 then Width := 0
  else if AArgument <= $FF then Width := 1
  else if AArgument <= $FFFF then Width := 2
  else if AArgument <= $FFFFFFFF then Width := 4
  else Width := 8;
  if AMinWidth > Width then Width := AMinWidth;

  case Width of
    0: PutByte(Base or Byte(AArgument));
    1:
      begin
        PutByte(Base or 24);
        PutByte(Byte(AArgument));
      end;
    2:
      begin
        PutByte(Base or 25);
        for I := 1 downto 0 do PutByte(Byte((AArgument shr (I * 8)) and $FF));
      end;
    4:
      begin
        PutByte(Base or 26);
        for I := 3 downto 0 do PutByte(Byte((AArgument shr (I * 8)) and $FF));
      end;
  else
    PutByte(Base or 27);
    for I := 7 downto 0 do PutByte(Byte((AArgument shr (I * 8)) and $FF));
  end;
end;

procedure TCborWriter.PutIndefiniteHead(AMajor: TCborMajorType);
begin
  PutByte(Byte((Byte(AMajor) shl 5) or 31));
end;

procedure TCborWriter.PutBreak;
begin
  PutByte($FF);
end;
{ ---------------------------------------------------------- writing one --- }

procedure WriteValue(var W: TCborWriter; AValue: TCborValue;
  const AOptions: TCborEncodeOptions); forward;

{ Deterministic encoding sorts a map's entries by the encoded bytes of their
  KEYS - which means every key has to be encoded before any of them can be
  placed. That is why the writer builds a tree first; see the unit header. }
function EncodeOne(AValue: TCborValue;
  const AOptions: TCborEncodeOptions): TBytes;
var
  W: TCborWriter;
begin
  W.Init;
  WriteValue(W, AValue, AOptions);
  Result := W.ToBytes;
end;

function CompareEncodedBytes(const A, B: TBytes): Integer;
var
  I, N: Integer;
begin
  { RFC 8949 section 4.2.1: bytewise lexicographic order of the encoded
    keys. A shorter key that is a prefix of a longer one sorts first, which
    falls out of comparing the common prefix and then the lengths. }
  N := Integer(Min(Length(A), Length(B)));
  for I := 0 to N - 1 do
    if A[I] <> B[I] then
    begin
      if A[I] < B[I] then Exit(-1);
      Exit(1);
    end;
  Result := Integer(Length(A) - Length(B));
end;

type
  TEncodedPair = record
    Key: TBytes;
    Value: TBytes;
  end;

procedure WriteMapDeterministic(var W: TCborWriter; AValue: TCborValue;
  const AOptions: TCborEncodeOptions);
var
  Pairs: TArray<TEncodedPair>;
  I: Integer;
begin
  SetLength(Pairs, AValue.Count);
  for I := 0 to AValue.Count - 1 do
  begin
    Pairs[I].Key := EncodeOne(AValue.Keys[I], AOptions);
    Pairs[I].Value := EncodeOne(AValue.Items[I], AOptions);
  end;
  TArray.Sort<TEncodedPair>(Pairs, TComparer<TEncodedPair>.Construct(
    function(const L, R: TEncodedPair): Integer
    begin
      Result := CompareEncodedBytes(L.Key, R.Key);
    end));
  W.PutHead(5, UInt64(Length(Pairs)));
  for I := 0 to Integer(High(Pairs)) do
  begin
    W.PutRaw(Pairs[I].Key);
    W.PutRaw(Pairs[I].Value);
  end;
end;

procedure WriteValue(var W: TCborWriter; AValue: TCborValue;
  const AOptions: TCborEncodeOptions);
var
  I: Integer;
  Bits: UInt64;
  Half: Word;
  SingleBits: UInt32;
  Width: Byte;
  Utf8: TBytes;
begin
  if AValue = nil then
  begin
    W.PutByte($F6);   { null }
    Exit;
  end;

  { The head width a decoded value arrived with is honoured only when the
    caller has not asked for deterministic output. Deterministic means
    shortest, always. }
  if AOptions.Deterministic then Width := 0 else Width := AValue.HeadWidth;

  case AValue.Kind of
    TCborKind.UInt:
      W.PutHead(0, AValue.AsUInt64, Width);
    TCborKind.NegInt:
      W.PutHead(1, AValue.NegativeArgument, Width);

    TCborKind.Bytes:
      begin
        if AValue.Indefinite and not AOptions.Deterministic then
        begin
          W.PutIndefiniteHead(2);
          for I := 0 to AValue.ChunkCount - 1 do
            WriteValue(W, AValue.Chunks[I], AOptions);
          W.PutBreak;
        end
        else
        begin
          W.PutHead(2, UInt64(Length(AValue.AsBytes)), Width);
          W.PutRaw(AValue.AsBytes);
        end;
      end;

    TCborKind.Text:
      begin
        if AValue.Indefinite and not AOptions.Deterministic then
        begin
          W.PutIndefiniteHead(3);
          for I := 0 to AValue.ChunkCount - 1 do
            WriteValue(W, AValue.Chunks[I], AOptions);
          W.PutBreak;
        end
        else
        begin
          { UTF-8 by the library's own strict encoder, never the system code
            page. }
          Utf8 := StringToUtf8Bytes(AValue.AsText);
          W.PutHead(3, UInt64(Length(Utf8)), Width);
          W.PutRaw(Utf8);
        end;
      end;

    TCborKind.Arr:
      begin
        if AValue.Indefinite and not AOptions.Deterministic then
        begin
          W.PutIndefiniteHead(4);
          for I := 0 to AValue.Count - 1 do
            WriteValue(W, AValue.Items[I], AOptions);
          W.PutBreak;
        end
        else
        begin
          W.PutHead(4, UInt64(AValue.Count), Width);
          for I := 0 to AValue.Count - 1 do
            WriteValue(W, AValue.Items[I], AOptions);
        end;
      end;

    TCborKind.Map:
      begin
        if AOptions.Deterministic then
          WriteMapDeterministic(W, AValue, AOptions)
        else if AValue.Indefinite then
        begin
          W.PutIndefiniteHead(5);
          for I := 0 to AValue.Count - 1 do
          begin
            WriteValue(W, AValue.Keys[I], AOptions);
            WriteValue(W, AValue.Items[I], AOptions);
          end;
          W.PutBreak;
        end
        else
        begin
          W.PutHead(5, UInt64(AValue.Count), Width);
          for I := 0 to AValue.Count - 1 do
          begin
            WriteValue(W, AValue.Keys[I], AOptions);
            WriteValue(W, AValue.Items[I], AOptions);
          end;
        end;
      end;

    TCborKind.Tag:
      begin
        W.PutHead(6, AValue.TagNumber, Width);
        WriteValue(W, AValue.TagContent, AOptions);
      end;

    TCborKind.Bool:
      if AValue.AsBool then W.PutByte($F5) else W.PutByte($F4);
    TCborKind.Null:      W.PutByte($F6);
    TCborKind.Undefined: W.PutByte($F7);

    TCborKind.Simple:
      begin
        { 0..23 fit in the head; 24..255 take the one-byte form. 24..31 are
          reserved in the one-byte form and cannot be reached, because the
          public constructor refuses them. }
        if AValue.SimpleValue <= 23 then
          W.PutByte($E0 or AValue.SimpleValue)
        else
        begin
          W.PutByte($F8);
          W.PutByte(AValue.SimpleValue);
        end;
      end;

    TCborKind.Float:
      begin
        { The shortest width that preserves the value EXACTLY. Under
          deterministic encoding that is required; otherwise the width the
          value was built or decoded with is honoured, so a document
          round-trips byte for byte. }
        if AOptions.Deterministic then
        begin
          if TCborFloats.TryDoubleToHalf(AValue.AsFloat, Half) then
          begin
            W.PutByte($F9);
            W.PutByte(Byte(Half shr 8));
            W.PutByte(Byte(Half and $FF));
          end
          else if TCborFloats.TryDoubleToSingle(AValue.AsFloat, SingleBits) then
          begin
            W.PutByte($FA);
            for I := 3 downto 0 do
              W.PutByte(Byte((SingleBits shr (I * 8)) and $FF));
          end
          else
          begin
            Bits := AValue.FloatBits;
            W.PutByte($FB);
            for I := 7 downto 0 do W.PutByte(Byte((Bits shr (I * 8)) and $FF));
          end;
          Exit;
        end;

        case AValue.FloatWidth of
          TCborFloatWidth.Half:
            begin
              if not TCborFloats.TryDoubleToHalf(AValue.AsFloat, Half) then
                Half := Word(AValue.FloatBits);
              W.PutByte($F9);
              W.PutByte(Byte(Half shr 8));
              W.PutByte(Byte(Half and $FF));
            end;
          TCborFloatWidth.Single:
            begin
              if not TCborFloats.TryDoubleToSingle(AValue.AsFloat, SingleBits) then
                SingleBits := UInt32(AValue.FloatBits);
              W.PutByte($FA);
              for I := 3 downto 0 do
                W.PutByte(Byte((SingleBits shr (I * 8)) and $FF));
            end;
        else
          Bits := AValue.FloatBits;
          W.PutByte($FB);
          for I := 7 downto 0 do W.PutByte(Byte((Bits shr (I * 8)) and $FF));
        end;
      end;
  end;
end;

class function TCborEngine.Encode(AValue: TCborValue;
  const AOptions: TCborEncodeOptions): TBytes;
var
  W: TCborWriter;
begin
  W.Init;
  if AOptions.SelfDescribe then
  begin
    { Tag 55799 takes three bytes and says only "what follows is CBOR". }
    W.PutHead(6, TCborTags.SelfDescribed);
  end;
  WriteValue(W, AValue, AOptions);
  Result := W.ToBytes;
end;

{ ===========================================================================
  THE READER

  Every way a document can be ill-formed gets its own exception, because
  "malformed CBOR" tells the person holding the bytes nothing they can act
  on. A truncated payload, a reserved additional-information value, a break
  where no indefinite item is open, a chunk of the wrong type inside an
  indefinite string, text that is not UTF-8, and nesting past the limit are
  six different problems.
  =========================================================================== }

type
  TCborReader = record
  strict private
    FData: TBytes;
    FPos: Integer;
    FEnd: Integer;
    FDepth: Integer;
    FMaxDepth: Integer;
    procedure Need(ACount: Integer);
  public
    procedure Init(const AData: TBytes; AMaxDepth: Integer);
    function AtEnd: Boolean;
    function PeekByte: Byte;
    function ReadByte: Byte;
    function ReadBigEndian(AWidth: Integer): UInt64;
    function ReadRaw(ACount: Int64): TBytes;
    function ReadValue: TCborValue;
    property Position: Integer read FPos;
  end;

procedure TCborReader.Init(const AData: TBytes; AMaxDepth: Integer);
begin
  FData := AData;
  FPos := 0;
  { Positions are Integer. A Win64 array can be longer than that, and
    narrowing its length would put the end somewhere inside it - or before
    the start. Widened through Int64 so the test means the same on Win32. }
  if Int64(Length(AData)) > High(Integer) then
    raise ECborInputError.CreateFmt(
      'A CBOR document of %d bytes is larger than the reader can address; ' +
      'the limit is %d bytes.', [Int64(Length(AData)), High(Integer)]);
  FEnd := Integer(Length(AData));
  FDepth := 0;
  FMaxDepth := AMaxDepth;
end;

function TCborReader.AtEnd: Boolean;
begin
  Result := FPos >= FEnd;
end;

procedure TCborReader.Need(ACount: Integer);
begin
  { A subtraction rather than FPos + ACount, because a length claim near
    High(Integer) would overflow the addition and pass the test. }
  if (ACount < 0) or (ACount > FEnd - FPos) then
    raise ECborTruncatedInput.CreateFmt(
      'The document ends after %d bytes and %d more were needed at offset %d.',
      [FEnd, ACount, FPos]);
end;

function TCborReader.PeekByte: Byte;
begin
  Need(1);
  Result := FData[FPos];
end;

function TCborReader.ReadByte: Byte;
begin
  Need(1);
  Result := FData[FPos];
  Inc(FPos);
end;

function TCborReader.ReadBigEndian(AWidth: Integer): UInt64;
var
  I: Integer;
begin
  Need(AWidth);
  Result := 0;
  for I := 0 to AWidth - 1 do
    Result := (Result shl 8) or FData[FPos + I];
  Inc(FPos, AWidth);
end;

function TCborReader.ReadRaw(ACount: Int64): TBytes;
begin
  { The declared length is the document's claim, checked in 64 bits BEFORE it
    is narrowed or allocated. A document is at most High(Integer) bytes, so
    a claim past that cannot be honest: it is malformed input (an argument
    above High(Int64) arrives here negative), not a request for a terabyte
    and not a range error. Anything smaller goes to Need, which compares it
    with what is left. }
  if (ACount < 0) or (ACount > High(Integer)) then
    raise ECborTruncatedInput.CreateFmt(
      'A string at offset %d declares a length of %s bytes, and only %d ' +
      'remain.', [FPos, UIntToStr(UInt64(ACount)), FEnd - FPos]);
  Need(Integer(ACount));
  Result := Copy(FData, FPos, Integer(ACount));
  Inc(FPos, Integer(ACount));
end;

function TCborReader.ReadValue: TCborValue;
var
  Head, Major, Info: Byte;
  Argument: UInt64;
  HeadWidth: Byte;
  Chunk, Key, Item: TCborValue;
  I: Int64;
  Buf: TBytes;
  Text: string;

  { The argument, and how wide its encoding was. 31 is handled by the
    caller; 28, 29 and 30 are reserved and never valid. }
  procedure ReadArgument;
  begin
    HeadWidth := 0;
    case Info of
      0..23: Argument := Info;
      24:
        begin
          Argument := ReadBigEndian(1);
          HeadWidth := 1;
        end;
      25:
        begin
          Argument := ReadBigEndian(2);
          HeadWidth := 2;
        end;
      26:
        begin
          Argument := ReadBigEndian(4);
          HeadWidth := 4;
        end;
      27:
        begin
          Argument := ReadBigEndian(8);
          HeadWidth := 8;
        end;
    else
      raise ECborReservedAdditionalInfo.CreateFmt(
        'Additional information %d is reserved and has no meaning, at ' +
        'offset %d.', [Info, FPos - 1]);
    end;
  end;

  { An indefinite-length string is a sequence of DEFINITE-length chunks of
    the same major type. Anything else in there is ill-formed, and saying so
    by name is the difference between a diagnosable document and a mystery. }
  function ReadStringChunks(AMajor: Byte): TCborValue;
  var
    Next: Byte;
    Part: TCborValue;
  begin
    if AMajor = 2 then Result := TCborValue.NewIndefiniteBytes
    else Result := TCborValue.NewIndefiniteText;
    try
      while True do
      begin
        Next := PeekByte;
        if Next = $FF then
        begin
          Inc(FPos);
          Break;
        end;
        if (Next shr 5) <> AMajor then
          raise ECborChunkMismatch.CreateFmt(
            'An indefinite-length string of major type %d contains a chunk ' +
            'of major type %d at offset %d. Every chunk has to be the same ' +
            'type as the string it is part of.',
            [AMajor, Next shr 5, FPos]);
        if (Next and $1F) = 31 then
          raise ECborChunkMismatch.CreateFmt(
            'An indefinite-length string contains another indefinite-length ' +
            'string at offset %d. Chunks have to have definite lengths.',
            [FPos]);
        Part := ReadValue;
        Result.AddChunk(Part);
      end;
    except
      Result.Free;
      raise;
    end;
  end;

begin
  Inc(FDepth);
  try
    if FDepth > FMaxDepth then
      raise ECborDepthExceeded.CreateFmt(
        'The document nests more than %d deep at offset %d. A document that ' +
        'nests without bound is a denial-of-service payload, not data.',
        [FMaxDepth, FPos]);

    Head := ReadByte;
    Major := Byte(Head shr 5);
    Info := Head and $1F;

    { A break belongs to the loop that opened an indefinite item. Reaching
      one here means none is open. }
    if Head = $FF then
      raise ECborUnexpectedBreak.CreateFmt(
        'A break code at offset %d closes an indefinite-length item, and ' +
        'none is open.', [FPos - 1]);

    case Major of
      0:
        begin
          ReadArgument;
          Result := TCborValue.NewUInt(Argument);
          Result.HeadWidth := HeadWidth;
        end;

      1:
        begin
          { Major type 1 encodes -1-n, so the argument is n and the value
            reaches -2^64. That does not fit in an Int64 at all, which is
            why the model keeps the argument rather than the value. }
          ReadArgument;
          Result := TCborValue.NewNegativeArgument(Argument);
          Result.HeadWidth := HeadWidth;
        end;

      2:
        begin
          if Info = 31 then Exit(ReadStringChunks(2));
          ReadArgument;
          Result := TCborValue.NewBytes(ReadRaw(Int64(Argument)));
          Result.HeadWidth := HeadWidth;
        end;

      3:
        begin
          if Info = 31 then Exit(ReadStringChunks(3));
          ReadArgument;
          Buf := ReadRaw(Int64(Argument));
          try
            Text := Utf8BytesToString(Buf);
          except
            on E: EInvalidUtf8 do
              raise ECborInvalidText.CreateFmt(
                'A text string at offset %d is not valid UTF-8: %s',
                [FPos - Length(Buf), E.Message]);
          end;
          Result := TCborValue.NewText(Text);
          Result.HeadWidth := HeadWidth;
        end;

      4:
        begin
          if Info = 31 then
          begin
            Result := TCborValue.NewIndefiniteArray;
            try
              while PeekByte <> $FF do Result.Add(ReadValue);
              Inc(FPos);
            except
              Result.Free;
              raise;
            end;
            Exit;
          end;
          ReadArgument;
          Result := TCborValue.NewArray;
          try
            Result.HeadWidth := HeadWidth;
            { The count is checked against the remaining bytes before any
              allocation: a claim of 2^40 elements must not be believed. }
            if Argument > UInt64(FEnd - FPos) then
              raise ECborTruncatedInput.CreateFmt(
                'An array at offset %d claims %d elements and only %d bytes ' +
                'remain.', [FPos, Argument, FEnd - FPos]);
            for I := 1 to Int64(Argument) do Result.Add(ReadValue);
          except
            Result.Free;
            raise;
          end;
        end;

      5:
        begin
          if Info = 31 then
          begin
            Result := TCborValue.NewIndefiniteMap;
            try
              while PeekByte <> $FF do
              begin
                Key := ReadValue;
                try
                  Item := ReadValue;
                except
                  Key.Free;
                  raise;
                end;
                Result.Add(Key, Item);
              end;
              Inc(FPos);
            except
              Result.Free;
              raise;
            end;
            Exit;
          end;
          ReadArgument;
          Result := TCborValue.NewMap;
          try
            Result.HeadWidth := HeadWidth;
            { Each pair is at least two bytes, so a count above half the
              remaining bytes cannot be honest. }
            if Argument > UInt64((FEnd - FPos) div 2 + 1) then
              raise ECborTruncatedInput.CreateFmt(
                'A map at offset %d claims %d pairs and only %d bytes remain.',
                [FPos, Argument, FEnd - FPos]);
            for I := 1 to Int64(Argument) do
            begin
              Key := ReadValue;
              try
                Item := ReadValue;
              except
                Key.Free;
                raise;
              end;
              Result.Add(Key, Item);
            end;
          except
            Result.Free;
            raise;
          end;
        end;

      6:
        begin
          ReadArgument;
          Chunk := ReadValue;
          Result := TCborValue.NewTag(Argument, Chunk);
          Result.HeadWidth := HeadWidth;
        end;

    else
      { Major type 7: the simple values and the floats share a space. }
      case Info of
        0..19:
          Result := TCborValue.NewSimple(Info);
        20: Result := TCborValue.NewBool(False);
        21: Result := TCborValue.NewBool(True);
        22: Result := TCborValue.NewNull;
        23: Result := TCborValue.NewUndefined;
        24:
          begin
            Argument := ReadBigEndian(1);
            { 0..31 in the one-byte form are not well-formed: those values
              have the immediate encoding and the specification forbids the
              longer one. }
            if Argument < 32 then
              raise ECborMalformedSimple.CreateFmt(
                'Simple value %d is written in the two-byte form at offset ' +
                '%d, and values below 32 have to use the one-byte form.',
                [Argument, FPos - 1]);
            Result := TCborValue.NewSimple(Byte(Argument));
          end;
        25:
          begin
            Argument := ReadBigEndian(2);
            Result := TCborValue.NewFloatBits(Argument, TCborFloatWidth.Half);
          end;
        26:
          begin
            Argument := ReadBigEndian(4);
            Result := TCborValue.NewFloatBits(Argument, TCborFloatWidth.Single);
          end;
        27:
          begin
            Argument := ReadBigEndian(8);
            Result := TCborValue.NewFloatBits(Argument, TCborFloatWidth.Double);
          end;
      else
        raise ECborReservedAdditionalInfo.CreateFmt(
          'Additional information %d in major type 7 is reserved, at offset ' +
          '%d.', [Info, FPos - 1]);
      end;
    end;
  finally
    Dec(FDepth);
  end;
end;

class function TCborEngine.Decode(const AData: TBytes;
  const AOptions: TCborDecodeOptions): TCborValue;
var
  R: TCborReader;
begin
  if Length(AData) = 0 then
    raise ECborTruncatedInput.Create('There are no bytes to decode.');
  R.Init(AData, AOptions.MaxDepth);
  Result := R.ReadValue;
  try
    if not AOptions.AllowTrailingData and not R.AtEnd then
      raise ECborTrailingData.CreateFmt(
        'The document ends at offset %d and %d bytes follow it. A whole ' +
        'buffer that decodes to one item and ignores the rest is how a ' +
        'truncation goes unnoticed; set AllowTrailingData to read one item ' +
        'out of a stream.', [R.Position, Length(AData) - R.Position]);
  except
    Result.Free;
    raise;
  end;
end;

class function TCborEngine.IsDeterministic(const AData: TBytes): Boolean;
var
  Value: TCborValue;
  Again: TBytes;
begin
  { The honest test, and the only one: decode it, encode it deterministically,
    and compare. A structural inspection would have to re-implement every
    rule and could disagree with the writer. }
  try
    Value := Decode(AData, TCborDecodeOptions.Default);
  except
    Exit(False);
  end;
  try
    Again := Encode(Value, TCborEncodeOptions.Rfc8949Deterministic);
  finally
    Value.Free;
  end;
  if Length(Again) <> Length(AData) then Exit(False);
  Result := CompareMem(@Again[0], @AData[0], Length(AData));
end;

function DecimalTextToCbor(const AText: string): TCborValue; forward;
function GuidToRfc4122Bytes(const AGuid: TGUID): TBytes; forward;

{ ===========================================================================
  THE DYNAMIC BRIDGE

  CBOR is richer than the dynamic tree in two directions at once: it has
  unsigned integers the tree now carries, and it has a tag space the tree
  carries as an Extended node. Nothing is dropped; a tag this library has no
  meaning for keeps its number and its content.
  =========================================================================== }

class function TCborEngine.CborToDynamic(AValue: TCborValue): TDynamicValue;
begin
  Result := CborToDynamic(AValue, TStructuralConversionOptions.Default, '$');
end;

class function TCborEngine.CborToDynamic(AValue: TCborValue;
  const AOptions: TStructuralConversionOptions;
  const APath: string): TDynamicValue;
var
  Destination: TSerializationFormat;
  Issue: TStructuralIssue;
  Profile: string;
  I: Integer;
  Inner, Payload: TDynamicValue;
  Text: string;
  DT: TDateTime;
  Guid: TGUID;
begin
  case AValue.Kind of
    TCborKind.UInt:
      begin
        if AValue.FitsInt64 then Exit(TDynamicValue.NewInt(AValue.AsInt64));
        Exit(TDynamicValue.NewUInt(AValue.AsUInt64));
      end;

    TCborKind.NegInt:
      begin
        { -1-n. It fits an Int64 when n is below 2^63; below that the value
          is beyond anything Delphi has, and it travels as a big integer
          rather than being wrapped into nonsense. }
        if AValue.FitsInt64 then Exit(TDynamicValue.NewInt(AValue.AsInt64));
        { The payload is the MAGNITUDE (Core's contract for BigIntNegative,
          and what DynamicToCbor reads back): n + 1, from the 64-bit
          argument. }
        Exit(TDynamicValue.NewExtended(TDynamicTag.BigIntNegative,
          TDynamicValue.NewBytes(TCborBigInt.IncrementMagnitude(
            UInt64ToBigEndian(AValue.NegativeArgument)))));
      end;

    TCborKind.Bytes: Exit(TDynamicValue.NewBytes(AValue.AsBytes));
    TCborKind.Text:  Exit(TDynamicValue.NewStr(AValue.AsText));
    TCborKind.Bool:  Exit(TDynamicValue.NewBool(AValue.AsBool));
    TCborKind.Null:  Exit(TDynamicValue.NewNull);

    TCborKind.Undefined:
      Exit(TDynamicValue.NewExtended(TDynamicTag.Undefined, nil));

    TCborKind.Simple:
      Exit(TDynamicValue.NewExtended(TCborDynamicTag.SimpleValue,
        TDynamicValue.NewInt(AValue.SimpleValue)));

    TCborKind.Float: Exit(TDynamicValue.NewFloat(AValue.AsFloat));

    TCborKind.Arr:
      begin
        Result := TDynamicValue.NewArray;
        try
          for I := 0 to AValue.Count - 1 do
            Result.AsArray.Adopt(CborToDynamic(AValue.Items[I], AOptions,
              Format('%s[%d]', [APath, I])));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;

    TCborKind.Map:
      begin
        { CBOR map keys may be any value; the dynamic tree's are strings. A
          key that is not text is rendered as its diagnostic text under
          Natural, which changes its type and is the one place this bridge
          cannot be exact - so it is said here rather than discovered.
          Strict refuses because the key's type would change, and Lossless
          because no destination reached through the dynamic tree can keep
          it: diagnostic text is never lossless. }
        Result := TDynamicValue.NewObject;
        try
          for I := 0 to AValue.Count - 1 do
          begin
            if AValue.Keys[I].Kind = TCborKind.Text then
              Text := AValue.Keys[I].AsText
            else
            begin
              Text := AValue.Keys[I].ToDiagnostic;
              if AOptions.ValuePolicy <> TStructuralValuePolicy.Natural then
              begin
                if AOptions.DestinationFormatKnown then
                  Destination := AOptions.DestinationFormat
                else
                  Destination := TSerializationFormat.Cbor;
                if AOptions.ValuePolicy = TStructuralValuePolicy.Lossless then
                begin
                  Issue := TStructuralIssue.UnsupportedLosslessConversion;
                  Profile := 'Lossless';
                end
                else
                begin
                  Issue := TStructuralIssue.LossyConversion;
                  Profile := 'Strict';
                end;
                raise EStructuralConversionError.CreateFor(Issue, AOptions,
                  Destination, APath + '[' + AValue.Keys[I].ToDiagnostic + ']',
                  TDynamicKind.Obj,
                  Format('the CBOR map key %s is not text, and a structural ' +
                  'conversion names members with text. Writing it as its ' +
                  'diagnostic text would change the key''s type; %s refuses ' +
                  'rather than coerce it. Convert with the Natural profile, ' +
                  'which does, or read the document with TCborSerializer.',
                  [AValue.Keys[I].ToDiagnostic, Profile]));
              end;
            end;
            Result.AsObject.Adopt(Text, CborToDynamic(AValue.Items[I], AOptions,
              APath + '.' + Text));
          end;
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;

    TCborKind.Tag:
      begin
        { A tag this library understands becomes the thing it means. The
          number is 64 bits wide: one past the largest known tag is unknown
          BEFORE the narrowing, or tag 2^32+1 would be read as tag 1. }
        if AValue.TagNumber <= TCborTags.SelfDescribed then
        case Integer(AValue.TagNumber) of
          TCborTags.DateTimeString, TCborTags.EpochDateTime:
            if AValue.TryAsDateTime(DT) then Exit(TDynamicValue.NewDateTime(DT));
          TCborTags.PositiveBignum:
            Exit(TDynamicValue.NewExtended(TDynamicTag.BigIntPositive,
              TDynamicValue.NewBytes(AValue.TagContent.AsBytes)));
          TCborTags.NegativeBignum:
            { Tag 3 carries n for the value -1-n; the dynamic payload is the
              magnitude n + 1, which DynamicToCbor decrements on the way back.
              Passing n through unchanged moved every value by one. }
            Exit(TDynamicValue.NewExtended(TDynamicTag.BigIntNegative,
              TDynamicValue.NewBytes(TCborBigInt.IncrementMagnitude(
                TCborBigInt.TrimMagnitude(AValue.TagContent.AsBytes)))));
          TCborTags.DecimalFraction:
            if AValue.TryAsDecimalText(Text) then
              Exit(TDynamicValue.NewDecimal(Text));
          TCborTags.Uuid:
            { The canonical thirty-six character spelling, which is what
              every other format here writes a GUID as and what a reader on
              the far side can parse - never the diagnostic text, which is
              a sentence about a UUID rather than the UUID. }
            if AValue.TryAsUuid(Guid) then
              Exit(TDynamicValue.NewStr(
                LowerCase(Copy(GUIDToString(Guid), 2, 36))));
          TCborTags.Uri:
            if AValue.TryAsUri(Text) then Exit(TDynamicValue.NewStr(Text));
          TCborTags.SelfDescribed:
            { It says "this is CBOR" and nothing about the value, so the
              value passes through unchanged. }
            Exit(CborToDynamic(AValue.TagContent, AOptions, APath));
        end;

        { And one it does not keeps its number and its content, so that a
          destination which can carry a tag still can, and a round trip back
          to CBOR is exact. }
        Payload := TDynamicValue.NewObject;
        try
          Payload.AsObject.Adopt('number', TDynamicValue.NewUInt(AValue.TagNumber));
          Inner := CborToDynamic(AValue.TagContent, AOptions, APath);
          Payload.AsObject.Adopt('value', Inner);
        except
          Payload.Free;
          raise;
        end;
        Exit(TDynamicValue.NewExtended(TDynamicTag.CborTag, Payload));
      end;
  end;
  Result := TDynamicValue.NewNull;
end;

class function TCborEngine.DynamicToCbor(AValue: TDynamicValue): TCborValue;
var
  I: Integer;
  Number, Content: TDynamicValue;
  Bytes: TBytes;
begin
  case AValue.Kind of
    TDynamicKind.Null:  Exit(TCborValue.NewNull);
    TDynamicKind.Bool:  Exit(TCborValue.NewBool(AValue.AsBool));
    TDynamicKind.Int:   Exit(TCborValue.NewInt(AValue.AsInt));
    TDynamicKind.UInt:  Exit(TCborValue.NewUInt(AValue.AsUInt));
    TDynamicKind.Float: Exit(TCborValue.NewFloat(AValue.AsFloat));
    TDynamicKind.Str:   Exit(TCborValue.NewText(AValue.AsStr));
    TDynamicKind.Bytes: Exit(TCborValue.NewBytes(AValue.AsBytes));

    TDynamicKind.Decimal:
      begin
        { Tag 4 is CBOR's own decimal fraction, and a decimal held as text is
          exactly what it is meant for. }
        Exit(DecimalTextToCbor(AValue.AsDecimal));
      end;

    { Tag 1 is seconds since the epoch - an instant. A calendar day is not
      one, so it goes out as ISO text rather than as a tagged number. }
    TDynamicKind.Date:
      Exit(TCborValue.NewText(TStructuralText.EncodeDate(AValue.AsDateTime)));
    TDynamicKind.Time:
      Exit(TCborValue.NewText(TStructuralText.EncodeTime(AValue.AsDateTime)));

    TDynamicKind.DateTime:
      Exit(TCborValue.NewEpochDateTime(AValue.AsDateTime));

    TDynamicKind.Arr:
      begin
        Result := TCborValue.NewArray;
        try
          for I := 0 to AValue.Count - 1 do
            Result.Add(DynamicToCbor(AValue[I]));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;

    TDynamicKind.Extended:
      begin
        if AValue.IsTagged(TDynamicTag.CborTag) then
        begin
          Number := AValue.ExtendedValue.Find('number');
          Content := AValue.ExtendedValue.Find('value');
          Exit(TCborValue.NewTag(Number.AsUInt, DynamicToCbor(Content)));
        end;
        if AValue.IsTagged(TCborDynamicTag.SimpleValue) then
          Exit(TCborValue.NewSimple(Byte(AValue.ExtendedValue.AsInt)));
        if AValue.IsTagged(TDynamicTag.Undefined) then
          Exit(TCborValue.NewUndefined);
        if AValue.IsTagged(TDynamicTag.BigIntPositive) then
        begin
          Bytes := AValue.ExtendedValue.AsBytes;
          Exit(TCborValue.NewBignum(Bytes, False));
        end;
        if AValue.IsTagged(TDynamicTag.BigIntNegative) then
        begin
          Bytes := AValue.ExtendedValue.AsBytes;
          Exit(TCborValue.NewBignum(Bytes, True));
        end;
        { Every other tag belongs to another format. CBOR has a tag space
          wide enough to carry it, but inventing a number for it would be
          inventing an interpretation, so the payload travels as the value
          it is. }
        if AValue.ExtendedValue <> nil then
          Exit(DynamicToCbor(AValue.ExtendedValue));
        Exit(TCborValue.NewNull);
      end;
  end;

  Result := TCborValue.NewMap;
  try
    for I := 0 to AValue.Count - 1 do
      Result.Add(AValue.Names[I], DynamicToCbor(AValue[I]));
  except
    Result.Free;
    raise;
  end;
end;

{ ===========================================================================
  CROSS-FORMAT
  =========================================================================== }

class function TCborEngine.FromPayload(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload; AFrom: TSerializationFormat): TBytes;
var
  V: TValue;
begin
  V := TSerializationFormats.Get(AFrom).DeserializeTyped(ATypeInfo, ASource);
  try
    Result := SerializeRoot(ATypeInfo, V, DefaultEncodeOptions);
  finally
    TSerializationOwnership.Release(ATypeInfo, V);
  end;
end;

class function TCborEngine.FromPayloadStructural(
  const ASource: TSerializationPayload; AFrom: TSerializationFormat;
  AProfile: TStructuralConversionProfile): TBytes;
var
  Tree: TDynamicValue;
  Value: TCborValue;
  Options: TStructuralConversionOptions;
begin
  { CBOR's own type system covers every dynamic kind - unsigned integers,
    decimals through tag 4, binary, timestamps through tag 1, and a tag
    space for everything else - and a CBOR map key is any value at all, so
    neither policy has anything to decide on the way out. The profile still
    travels, because it decides what the SOURCE may recognize. }
  Options := TStructuralConversionOptions.FromProfile(AProfile)
    .WithSource(AFrom).WithDestination(TSerializationFormat.Cbor);
  Tree := TSerializationFormats.Require(AFrom,
    TSerializationFormatCapability.StructuralParse, Options).ToDynamic(
      ASource, Options);
  try
    Value := DynamicToCbor(Tree);
    try
      Result := Encode(Value, DefaultEncodeOptions);
    finally
      Value.Free;
    end;
  finally
    Tree.Free;
  end;
end;

{ ===========================================================================
  THE CONTRACT ENGINE
  =========================================================================== }

var
  GCtx: TRttiContext;

function TypeKeyOf(ATypeInfo: PTypeInfo): string;
begin
  Result := UTF8ToString(ATypeInfo.Name) + IntToHex(NativeUInt(ATypeInfo), 8);
end;

class procedure TCborEngine.CheckNotFrozen;
begin
  if FFrozen then
    raise ECborInternalError.Create(
      'CBOR configuration is frozen. Register everything before the first ' +
      'document is written, or the second one would be written differently ' +
      'from the first.');
end;

class constructor TCborEngine.Create;
begin
  FLock := TCriticalSection.Create;
  FDatePolicies := TDateTimePolicies.Create(
    TDateTimePolicy.Make(Ord(TCborDateTimeRepresentation.EpochTagged)));
  FEnumMappings := TDictionary<string, TArray<string>>.Create;
  FTypeSerializers := TDictionary<string, TCborValueSerializerClass>.Create;
  FDefaultEncode := TCborEncodeOptions.Default;
end;

class destructor TCborEngine.Destroy;
begin
  FTypeSerializers.Free;
  FEnumMappings.Free;
  FDatePolicies.Free;
  FLock.Free;
end;

class procedure TCborEngine.SetDateTimePolicy(ATypeInfo: PTypeInfo;
  const AFieldName: string; AKind: Integer; const APattern: string);
var
  Policy: TDateTimePolicy;
  TypeKey: string;
begin
  CheckNotFrozen;
  Policy := TDateTimePolicy.Make(AKind, APattern);
  TypeKey := '';
  if ATypeInfo <> nil then TypeKey := TypeKeyOf(ATypeInfo);
  FLock.Enter;
  try
    if ATypeInfo = nil then FDatePolicies.SetGlobal(Policy)
    else if AFieldName = '' then FDatePolicies.SetForType(TypeKey, Policy)
    else FDatePolicies.SetForField(TypeKey, AFieldName, Policy);
  finally
    FLock.Leave;
  end;
end;

class procedure TCborEngine.RegisterEnumMapping(ATypeInfo: PTypeInfo;
  const AValues: array of string);
var
  Copy_: TArray<string>;
  I: Integer;
begin
  CheckNotFrozen;
  SetLength(Copy_, Length(AValues));
  for I := 0 to Integer(High(AValues)) do Copy_[I] := AValues[I];
  FLock.Enter;
  try
    FEnumMappings.AddOrSetValue(TypeKeyOf(ATypeInfo), Copy_);
  finally
    FLock.Leave;
  end;
end;

class procedure TCborEngine.RegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TCborValueSerializerClass);
begin
  CheckNotFrozen;
  FLock.Enter;
  try
    FTypeSerializers.AddOrSetValue(TypeKeyOf(ATypeInfo), ASerializerClass);
  finally
    FLock.Leave;
  end;
end;

class procedure TCborEngine.SetDefaultEncodeOptions(
  const AOptions: TCborEncodeOptions);
begin
  CheckNotFrozen;
  FLock.Enter;
  try
    FDefaultEncode := AOptions;
  finally
    FLock.Leave;
  end;
end;

class function TCborEngine.DefaultEncodeOptions: TCborEncodeOptions;
begin
  FLock.Enter;
  try
    Result := FDefaultEncode;
  finally
    FLock.Leave;
  end;
end;

class function TCborEngine.TryGetEnumMapping(ATypeInfo: PTypeInfo;
  out AValues: TArray<string>): Boolean;
begin
  FLock.Enter;
  try
    Result := FEnumMappings.TryGetValue(TypeKeyOf(ATypeInfo), AValues);
  finally
    FLock.Leave;
  end;
end;

class function TCborEngine.TryGetTypeSerializer(ATypeInfo: PTypeInfo;
  out AClass: TCborValueSerializerClass): Boolean;
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

class procedure TCborEngine.FreezeConfiguration;
begin
  FFrozen := True;
end;

class function TCborEngine.IsFrozen: Boolean;
begin
  Result := FFrozen;
end;

class procedure TCborEngine.ResetConfiguration;
begin
  FFrozen := False;
  FLock.Enter;
  try
    FDatePolicies.Reset;
    FEnumMappings.Clear;
    FTypeSerializers.Clear;
    FDefaultEncode := TCborEncodeOptions.Default;
  finally
    FLock.Leave;
  end;
end;

{ --------------------------------------------------- reading the members --- }

{ THE ROOT HAS NO MEMBER. Every one of these is asked with nil when the
  value being written is the root of the document rather than a field of
  something, so each answers for "no attributes at all" rather than
  dereferencing what it was not given. }

function MemberName(AMember: TRttiMember): string;
var
  Attr: TCustomAttribute;
begin
  if AMember = nil then Exit('');
  for Attr in AMember.GetAttributes do
    if Attr is CborNameAttribute then Exit(CborNameAttribute(Attr).Name);
  { [CborName] beats [SerializationName], which beats the Delphi name. }
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
    if Attr is CborIgnoreAttribute then Exit(True);
end;

function MemberSerializer(AMember: TRttiMember): TCborValueSerializerClass;
var
  Attr: TCustomAttribute;
begin
  Result := nil;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is CborSerializerAttribute then
      Exit(CborSerializerAttribute(Attr).SerializerClass);
end;

function MemberDateRepresentation(AMember: TRttiMember;
  out APattern: string): TCborDateTimeRepresentation;
var
  Attr: TCustomAttribute;
begin
  APattern := '';
  Result := TCborDateTimeRepresentation.EpochTagged;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is CborDateTimeRepresentationAttribute then
    begin
      APattern := CborDateTimeRepresentationAttribute(Attr).Pattern;
      if APattern <> '' then Exit(TCborDateTimeRepresentation.CustomString);
      Exit(CborDateTimeRepresentationAttribute(Attr).Representation);
    end;
end;

function MemberGuidRepresentation(AMember: TRttiMember): TCborGuidRepresentation;
var
  Attr: TCustomAttribute;
begin
  Result := TCborGuidRepresentation.TaggedUuid;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is CborGuidRepresentationAttribute then
      Exit(CborGuidRepresentationAttribute(Attr).Representation);
end;

function MemberCurrencyRepresentation(
  AMember: TRttiMember): TCborCurrencyRepresentation;
var
  Attr: TCustomAttribute;
begin
  Result := TCborCurrencyRepresentation.DecimalFraction;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is CborCurrencyRepresentationAttribute then
      Exit(CborCurrencyRepresentationAttribute(Attr).Representation);
end;

function MemberEnumRepresentation(AMember: TRttiMember): TCborEnumRepresentation;
var
  Attr: TCustomAttribute;
begin
  Result := TCborEnumRepresentation.Name;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is CborEnumRepresentationAttribute then
      Exit(CborEnumRepresentationAttribute(Attr).Representation);
end;

{ The members of a class or record: the shared surface - public fields
  and readable properties, a redeclared name once - minus those ignored in
  general or by [CborIgnore]. }
function MembersOf(AType: TRttiType): TArray<TRttiMember>;
var
  List: TList<TRttiMember>;
  M: TSerializationMember;
begin
  List := TList<TRttiMember>.Create;
  try
    for M in TSerializationMetadata.Get(AType.Handle).Members do
      if not M.Ignored and not MemberIgnored(M.Member) then List.Add(M.Member);
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

{ The text of an enumeration's values: CBOR's own registration, then
  [SerializationEnum] on the member, then on the type. }
function EnumNamesFor(AMember: TRttiMember; AType: PTypeInfo;
  out ANames: TArray<string>): Boolean;
begin
  Result := TCborEngine.TryGetEnumMapping(AType, ANames) or
    TSerializationMetadata.GeneralEnum(AMember, AType, ANames);
end;

function MemberType(AMember: TRttiMember): TRttiType;
begin
  if AMember is TRttiField then Result := TRttiField(AMember).FieldType
  else Result := TRttiProperty(AMember).PropertyType;
end;

{ RTTI GetValue and SetValue take the instance as an untyped pointer, so an
  object instance is passed as its address. }
function MemberValue(AMember: TRttiMember; const AInstance: TValue): TValue;
begin
  if AMember is TRttiField then
  begin
    if AInstance.IsObject then
      {$WARN UNSAFE_CAST OFF}
      Result := TRttiField(AMember).GetValue(AInstance.AsObject)
      {$WARN UNSAFE_CAST ON}
    else
      Result := TRttiField(AMember).GetValue(AInstance.GetReferenceToRawData);
  end
  else
  begin
    if AInstance.IsObject then
      {$WARN UNSAFE_CAST OFF}
      Result := TRttiProperty(AMember).GetValue(AInstance.AsObject)
      {$WARN UNSAFE_CAST ON}
    else
      Result := TRttiProperty(AMember).GetValue(AInstance.GetReferenceToRawData);
  end;
end;

{ The object or record a member already holds, for the reader to fill in
  place, as every other format does. Passing nothing made the reader
  construct a second object and store it over the first, which nothing then
  referred to - the child list a constructor makes is the everyday case, and
  it leaked on every read. A record counts too: it is a value, but the
  objects in it are not, and reading it from a zeroed one replaced and
  orphaned every object a constructor or the caller had put there, and reset
  the members the document left out. An array is replaced, not merged. }
function ExistingValueOf(AMember: TRttiMember; const AInstance: TValue): TValue;
var
  T: TRttiType;
begin
  Result := TValue.Empty;
  T := MemberType(AMember);
  if T = nil then Exit;
  if T.TypeKind in [tkRecord, tkMRecord] then
    Exit(MemberValue(AMember, AInstance));
  if T.TypeKind <> tkClass then Exit;
  Result := MemberValue(AMember, AInstance);
  if Result.IsObject and (Result.AsObject = nil) then Result := TValue.Empty;
end;

procedure SetMemberValue(AMember: TRttiMember; const AInstance: TValue;
  const AValue: TValue);
begin
  if AMember is TRttiField then
  begin
    if AInstance.IsObject then
      {$WARN UNSAFE_CAST OFF}
      TRttiField(AMember).SetValue(AInstance.AsObject, AValue)
      {$WARN UNSAFE_CAST ON}
    else
      TRttiField(AMember).SetValue(AInstance.GetReferenceToRawData, AValue);
  end
  else if TRttiProperty(AMember).IsWritable then
  begin
    if AInstance.IsObject then
      {$WARN UNSAFE_CAST OFF}
      TRttiProperty(AMember).SetValue(AInstance.AsObject, AValue)
      {$WARN UNSAFE_CAST ON}
    else
      TRttiProperty(AMember).SetValue(AInstance.GetReferenceToRawData, AValue);
  end;
end;

{ ----------------------------------------------------- a value to a tree --- }

{ RFC 4122 byte order, which is what tag 37 means and is NOT the order a
  Delphi TGUID has in memory: D1 and D2 are little-endian there. }
function GuidToRfc4122Bytes(const AGuid: TGUID): TBytes;
begin
  SetLength(Result, 16);
  Result[0] := Byte(AGuid.D1 shr 24);
  Result[1] := Byte(AGuid.D1 shr 16);
  Result[2] := Byte(AGuid.D1 shr 8);
  Result[3] := Byte(AGuid.D1);
  Result[4] := Byte(AGuid.D2 shr 8);
  Result[5] := Byte(AGuid.D2);
  Result[6] := Byte(AGuid.D3 shr 8);
  Result[7] := Byte(AGuid.D3);
  Move(AGuid.D4[0], Result[8], 8);
end;

{ A decimal held as text becomes tag 4 - CBOR's own decimal fraction - by
  splitting it into a mantissa and a power of ten. Text in, text out: no
  Double is involved at any point, which is the whole reason the dynamic
  tree holds a decimal as text. }
function DecimalTextToCbor(const AText: string): TCborValue;
var
  S, Mantissa: string;
  DotPos, EPos, Exponent, Extra: Integer;
begin
  S := Trim(AText);
  if S = '' then Exit(TCborValue.NewText(AText));
  Exponent := 0;
  EPos := Pos('E', UpperCase(S));
  if EPos > 0 then
  begin
    if not TryStrToInt(Copy(S, EPos + 1, MaxInt), Exponent) then
      Exit(TCborValue.NewText(AText));
    S := Copy(S, 1, EPos - 1);
  end;
  DotPos := Pos('.', S);
  if DotPos > 0 then
  begin
    Extra := Length(S) - DotPos;
    Mantissa := Copy(S, 1, DotPos - 1) + Copy(S, DotPos + 1, MaxInt);
    Dec(Exponent, Extra);
  end
  else
    Mantissa := S;
  if Mantissa = '' then Exit(TCborValue.NewText(AText));
  { The reader refuses a tag 4 past this, so the writer does not produce
    one. }
  if (Exponent > CborDecimalExponentLimit) or
     (Exponent < -CborDecimalExponentLimit) then
    raise ECborError.CreateFmt(
      'The decimal %s has the exponent %d, and CBOR''s reader accepts a ' +
      'decimal fraction only from -%d to %d.',
      [AText, Exponent, CborDecimalExponentLimit, CborDecimalExponentLimit]);
  Result := TCborValue.NewDecimalFraction(Exponent, Mantissa);
end;

{ What an error calls a member: its name when there is one, and otherwise
  the type, which is all an array element or a root has. }
function MemberLabel(AMember: TRttiMember; AType: TRttiType): string;
begin
  if AMember <> nil then Exit(AMember.Name);
  if AType <> nil then Exit(AType.Name);
  Result := 'a value';
end;

{ Whether a member can be written at all, asked from its TYPE before its
  getter is called, so a getter that raises - TComponent's ComObject
  raises EComponentError - never runs for a member that is refused anyway.
  A member a custom serializer covers is always writable. }
procedure RefuseUnwritableMember(AMember: TRttiMember; AType: TRttiType);
var
  Why: string;
  SerializerClass: TCborValueSerializerClass;
begin
  if AType = nil then
    raise ECborError.CreateFmt(
      '%s %s. Leave it out with [CborIgnore], or register a CBOR type ' +
      'serializer for the type that holds it.',
      [MemberDisplayName(AMember.Parent.Name, AMember.Name),
       TSerializationTypes.UnsupportedReason(nil)]);
  if MemberSerializer(AMember) <> nil then Exit;
  if TCborEngine.TryGetTypeSerializer(AType.Handle, SerializerClass) then Exit;
  Why := TSerializationTypes.UnsupportedReason(AType.Handle);
  if Why <> '' then
    raise ECborError.CreateFmt(
      '%s %s. Leave it out with [CborIgnore], or register a CBOR type ' +
      'serializer for its type.',
      [MemberDisplayName(AMember.Parent.Name, AMember.Name), Why]);
end;

function ValueToCbor(AType: TRttiType; const AValue: TValue;
  AMember: TRttiMember): TCborValue; forward;

function DateTimeToCbor(AValue: TDateTime;
  ARepresentation: TCborDateTimeRepresentation;
  const APattern: string): TCborValue;
var
  Millis: Int64;
begin
  case ARepresentation of
    TCborDateTimeRepresentation.EpochTagged:
      Result := TCborValue.NewEpochDateTime(AValue);
    TCborDateTimeRepresentation.Rfc3339Tagged:
      Result := TCborValue.NewTextDateTime(AValue);
    TCborDateTimeRepresentation.UnixSeconds:
      begin
        { The second an instant falls in is the millisecond count FLOORED:
          half a second before the epoch is second -1, not second 0. }
        Millis := TCborDateText.EpochMillis(AValue);
        if Millis < 0 then
          Result := TCborValue.NewInt((Millis - (MSecsPerSec - 1)) div MSecsPerSec)
        else
          Result := TCborValue.NewInt(Millis div MSecsPerSec);
      end;
    TCborDateTimeRepresentation.UnixMilliseconds:
      Result := TCborValue.NewInt(TCborDateText.EpochMillis(AValue));
    TCborDateTimeRepresentation.CustomString:
      begin
        TStructuralText.CheckDateTime(AValue);
        Result := TCborValue.NewText(
          FormatDateTime(APattern, AValue, TFormatSettings.Invariant));
      end;
  else
    Result := TCborValue.NewText(TStructuralText.EncodeDateTime(AValue));
  end;
end;

{ An empty nullable is ABSENT, not null.

  That is this library's rule across every format: JSON omits the member,
  BSON omits it, XML omits it, and so does this. The alternative - writing
  null - looks equivalent and is not: a document then cannot distinguish
  "the sender had no value" from "the sender said the value is null", and
  converting between two formats would have to pick one and be wrong half
  the time.

  A nullable that HAS a value writes its value, and a value of a type that
  has its own null writes that. Only the empty case disappears. }
function IsEmptyNullable(AType: TRttiType; const AValue: TValue): Boolean;
var
  Access: TNullableAccess;
begin
  Result := False;
  if AType = nil then Exit;
  if not TSerializationTypes.TryGetNullableAccess(AType.Handle, Access) then
    Exit;
  Result := not Access.HasValue(AValue.GetReferenceToRawData);
end;

{ Is this the Delphi type UInt64, or an alias of it?

  Delphi files UInt64 under tkInt64 alongside Int64, and the two are NOT
  interchangeable here: CBOR gives unsigned and negative integers different
  major types, so getting this wrong writes 2^64-1 as -1. The distinguishing
  mark in the RTTI is the declared range - zero at the bottom, and a top
  that has wrapped past Int64's own maximum. }
function IsUnsignedInt64(AType: TRttiType): Boolean;
var
  Int64Type: TRttiInt64Type;
begin
  if AType = nil then Exit(False);
  if AType.Handle = System.TypeInfo(UInt64) then Exit(True);
  if AType.TypeKind <> tkInt64 then Exit(False);
  if not (AType is TRttiInt64Type) then Exit(False);
  Int64Type := TRttiInt64Type(AType);
  Result := (Int64Type.MinValue = 0) and (Int64Type.MaxValue = -1);
end;

function CollectionToCbor(AType: TRttiType; const AValue: TValue;
  AMember: TRttiMember; out AHandled: Boolean): TCborValue;
var
  Access: TNullableAccess;
  Inner: TValue;
  Method: TRttiMethod;
  Enumerator, Current: TValue;
  EnumType: TRttiType;
  MoveNext: TRttiMethod;
  CurrentProp: TRttiProperty;
  IsMap: Boolean;
  PairType: TRttiType;
  KeyField, ValueField: TRttiField;
  PairKey, PairValue: TValue;
  Key, Item: TCborValue;
begin
  AHandled := True;

  { A nullable is its value, or null. }
  if TSerializationTypes.TryGetNullableAccess(AType.Handle, Access) then
  begin
    if not Access.HasValue(AValue.GetReferenceToRawData) then
      Exit(TCborValue.NewNull);
    Inner := Access.GetValue(AValue.GetReferenceToRawData);
    Exit(ValueToCbor(GCtx.GetType(Access.ValueType), Inner, AMember));
  end;

  { WHAT KIND OF CONTAINER THIS IS COMES FROM CORE; HOW IT IS TRAVERSED IS
    THIS ENGINE'S BUSINESS.

    Ancestry decides, once, in TSerializationTypes - not the presence of a
    GetEnumerator or an AddOrSetValue, which would take a cursor, a parser
    or a tree node for a container. A container family outside the RTL is
    registered with RegisterListFamily.

    The ITERATION is still the enumerator, which streams rather than
    materialising a ToArray copy of a large collection. }
  if (AType.TypeKind = tkClass) and AValue.IsObject and
     (AValue.AsObject <> nil) and
     (TSerializationTypes.ContainerKindOf(AType.Handle) <> TContainerKind.None) then
  begin
    Method := AType.GetMethod('GetEnumerator');
    if Method <> nil then
    begin
      { Assigned here rather than inside the IsMap branch below. The branch
        that fills them and the branch that reads them test the same flag,
        but the compiler cannot see that, and a warning nobody can act on
        costs more than two assignments. }
      KeyField := nil;
      ValueField := nil;
      IsMap := TSerializationTypes.ContainerKindOf(AType.Handle) =
        TContainerKind.Dictionary;

      { A container is a node of the graph like any other object: one level
        of the depth limit, and a cycle when it holds itself. An element
        declared TObject is written by its runtime class, so a list that
        contains itself came straight back here and recursed until the stack
        ran out. }
      if not TSerializationGraphGuard.Enter(AValue.AsObject) then
        raise ECborError.CreateFmt(
          '%s is already being written further up the graph: it is a ' +
          'cycle, and CBOR has no back-reference. Break the cycle, or ' +
          'register a CBOR type serializer that writes a key instead.',
          [AValue.AsObject.ClassName]);
      try
        if IsMap then Result := TCborValue.NewMap else Result := TCborValue.NewArray;
        try
          Enumerator := Method.Invoke(AValue.AsObject, []);
          try
            EnumType := GCtx.GetType(Enumerator.TypeInfo);
            MoveNext := EnumType.GetMethod('MoveNext');
            CurrentProp := EnumType.GetProperty('Current');
            if IsMap then
            begin
              if CurrentProp <> nil then
              begin
                PairType := CurrentProp.PropertyType;
                if PairType <> nil then
                begin
                  KeyField := PairType.GetField('Key');
                  ValueField := PairType.GetField('Value');
                end;
              end;
              if (KeyField = nil) or (ValueField = nil) then
                raise ECborInputError.CreateFmt(
                  '%s looks like a dictionary but its enumerator does not ' +
                  'yield Key/Value pairs, so CBOR cannot tell its entries ' +
                  'apart.', [AType.Name]);
            end;
            if (MoveNext <> nil) and (CurrentProp <> nil) then
              while MoveNext.Invoke(Enumerator, []).AsBoolean do
              begin
                { GetValue takes the enumerator object as an untyped pointer. }
                {$WARN UNSAFE_CAST OFF}
                Current := CurrentProp.GetValue(Enumerator.AsObject);
                {$WARN UNSAFE_CAST ON}
                if IsMap then
                begin
                  PairKey := KeyField.GetValue(Current.GetReferenceToRawData);
                  PairValue := ValueField.GetValue(Current.GetReferenceToRawData);
                  { One at a time, as the reader does. Built inline as the two
                    arguments of Add, the one converted first leaked when the
                    other raised - the key on Win64, the value on Win32. }
                  Key := ValueToCbor(GCtx.GetType(PairKey.TypeInfo), PairKey, nil);
                  try
                    Item := ValueToCbor(GCtx.GetType(PairValue.TypeInfo),
                      PairValue, nil);
                  except
                    Key.Free;
                    raise;
                  end;
                  Result.Add(Key, Item);
                end
                else
                  Result.Add(ValueToCbor(GCtx.GetType(Current.TypeInfo), Current,
                    nil));
              end;
          finally
            if Enumerator.IsObject then Enumerator.AsObject.Free;
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

  AHandled := False;
  Result := nil;
end;

function ValueToCbor(AType: TRttiType; const AValue: TValue;
  AMember: TRttiMember): TCborValue;
var
  Why: string;
  Handled: Boolean;
  I: Integer;
  Members: TArray<TRttiMember>;
  M: TRttiMember;
  Guid: TGUID;
  Pattern: string;
  Names: TArray<string>;
  Ordinal: Int64;
  SerializerClass: TCborValueSerializerClass;
  Serializer: TCustomCborValueSerializer;
  Cur: Currency;
  MemberVal: TValue;
  Tree: TDynamicValue;
  SetOrd: Integer;
begin
  if AType = nil then
    raise ECborError.CreateFmt(
      '%s %s. Leave it out with [CborIgnore], or register a CBOR type ' +
      'serializer for the type that holds it.',
      [MemberLabel(AMember, nil), TSerializationTypes.UnsupportedReason(nil)]);

  { A registered or attributed custom serializer wins over everything. }
  SerializerClass := MemberSerializer(AMember);
  if SerializerClass = nil then
    TCborEngine.TryGetTypeSerializer(AType.Handle, SerializerClass);
  if SerializerClass <> nil then
  begin
    Serializer := SerializerClass.Create;
    try
      Exit(Serializer.Serialize(AValue));
    finally
      Serializer.Free;
    end;
  end;

  { Refused, not written: a type with no RTTI must not become null, and a
    pointer, a method, a class reference or an interface must not reach the
    scalar writer, which would write an address as a number. The decision is
    TSerializationTypes.UnsupportedReason, shared by every format, and it
    is asked only after [CborIgnore] and every custom serializer have had
    their say, so a caller who wants one of these can always have it. }
  Why := TSerializationTypes.UnsupportedReason(AType.Handle);
  if Why <> '' then
    raise ECborError.CreateFmt(
      '%s %s. Leave it out with [CborIgnore], or register a CBOR type ' +
      'serializer for its type.', [MemberLabel(AMember, AType), Why]);

  Result := CollectionToCbor(AType, AValue, AMember, Handled);
  if Handled then Exit;

  case AType.TypeKind of
    tkInteger, tkInt64:
      begin
        if AType.Handle = System.TypeInfo(Currency) then
        begin
          Cur := AValue.AsCurrency;
          case MemberCurrencyRepresentation(AMember) of
            TCborCurrencyRepresentation.ScaledInt64:
              Exit(TCborValue.NewInt(PInt64(@Cur)^));
            TCborCurrencyRepresentation.Double:
              Exit(TCborValue.NewFloat(Cur));
            TCborCurrencyRepresentation.DecimalString:
              Exit(TCborValue.NewText(
                CurrToStr(Cur, TFormatSettings.Invariant)));
          else
            { A Currency IS a decimal fraction with four places, and tag 4 IS
              a decimal fraction. The two line up exactly. }
            Exit(TCborValue.NewDecimalFraction(-4, IntToStr(PInt64(@Cur)^)));
          end;
        end;
        { An unsigned 64-bit member is major type 0, not a negative integer.
          Delphi's RTTI files UInt64 under tkInt64, so AsInt64 on a value
          above High(Int64) is a two's-complement reading of it and would
          write 18446744073709551615 as -1 - which is a different number
          and a different major type. A UInt64 type is the one whose RTTI
          says its range runs from zero up past Int64's end. }
        if IsUnsignedInt64(AType) then
          Exit(TCborValue.NewUInt(AValue.AsUInt64));
        Exit(TCborValue.NewInt(TSerializationTypes.Int64Bits(AValue)));
      end;

    tkFloat:
      begin
        { Comp is a 64-bit integer RTTI files under tkFloat. As a float it
          lost everything past 2^53. }
        if TSerializationTypes.IsCompType(AType.Handle) then
          Exit(TCborValue.NewInt(TSerializationTypes.Int64Bits(AValue)));
        if AType.Handle = System.TypeInfo(Currency) then
        begin
          Cur := AValue.AsCurrency;
          case MemberCurrencyRepresentation(AMember) of
            TCborCurrencyRepresentation.ScaledInt64:
              Exit(TCborValue.NewInt(PInt64(@Cur)^));
            TCborCurrencyRepresentation.Double:
              Exit(TCborValue.NewFloat(Cur));
            TCborCurrencyRepresentation.DecimalString:
              Exit(TCborValue.NewText(
                CurrToStr(Cur, TFormatSettings.Invariant)));
          else
            Exit(TCborValue.NewDecimalFraction(-4, IntToStr(PInt64(@Cur)^)));
          end;
        end;
        if (AType.Handle = System.TypeInfo(TDateTime)) or
           (AType.Handle = System.TypeInfo(TDate)) or
           (AType.Handle = System.TypeInfo(TTime)) then
        begin
          if AType.Handle = System.TypeInfo(TDateTime) then
            Exit(DateTimeToCbor(AValue.AsExtended,
              MemberDateRepresentation(AMember, Pattern), Pattern));
          { A date and a time are not instants, so the default for them is
            text rather than a tagged epoch second that would claim more
            than the value holds. }
          MemberDateRepresentation(AMember, Pattern);
          if Pattern <> '' then
          begin
            TStructuralText.CheckDateTime(AValue.AsExtended);
            Exit(TCborValue.NewText(FormatDateTime(Pattern, AValue.AsExtended,
              TFormatSettings.Invariant)));
          end;
          Exit(TCborValue.NewText(
            TStructuralText.EncodeDateTime(AValue.AsExtended)));
        end;
        Exit(TCborValue.NewFloat(AValue.AsExtended));
      end;

    tkEnumeration:
      begin
        if AType.Handle = System.TypeInfo(Boolean) then
          Exit(TCborValue.NewBool(AValue.AsBoolean));
        Ordinal := AValue.AsOrdinal;
        if MemberEnumRepresentation(AMember) = TCborEnumRepresentation.Value then
          Exit(TCborValue.NewInt(Ordinal));
        if EnumNamesFor(AMember, AType.Handle, Names) and
           (Ordinal >= 0) and (Ordinal <= High(Names)) then
          Exit(TCborValue.NewText(Names[Ordinal]));
        Exit(TCborValue.NewText(GetEnumName(AType.Handle, Integer(Ordinal))));
      end;

    tkSet:
      begin
        { A set is written as an array of its member names - CBOR has no set,
          and a bitmask would be unreadable and version-brittle. }
        { Through TSerializationTypes: a TIntegerSet cast read 32 bits of a
          set that can be 256 wide, and counted from ordinal 0 in a set whose
          storage starts at its lowest member. }
        { An enumeration's elements through its mapping: CBOR's own, then
          [SerializationEnum]. }
        if not EnumNamesFor(AMember, GetTypeData(AType.Handle)^.CompType^,
             Names) then
          Names := nil;
        Result := TCborValue.NewArray;
        try
          for SetOrd in TSerializationTypes.SetOrdinals(AType.Handle, AValue) do
            Result.Add(TCborValue.NewText(TSerializationTypes.MappedSetElementText(
              GetTypeData(AType.Handle)^.CompType^, SetOrd, Names)));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;

    tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
      Exit(TCborValue.NewText(AValue.AsString));

    tkDynArray:
      begin
        if AType.Handle = System.TypeInfo(TBytes) then
          Exit(TCborValue.NewBytes(AValue.AsType<TBytes>));
        { One level, as every composite counts: a record holding a dynamic
          array of itself nests with no object in it, and it wrote documents
          deeper than the reader accepts until the stack ran out. }
        TSerializationGraphGuard.EnterLevel;
        try
          Result := TCborValue.NewArray;
          try
            for I := 0 to Integer(AValue.GetArrayLength) - 1 do
              Result.Add(ValueToCbor(
                GCtx.GetType(AValue.GetArrayElement(I).TypeInfo),
                AValue.GetArrayElement(I), nil));
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
          Result := TCborValue.NewArray;
          try
            for I := 0 to Integer(AValue.GetArrayLength) - 1 do
              Result.Add(ValueToCbor(
                GCtx.GetType(AValue.GetArrayElement(I).TypeInfo),
                AValue.GetArrayElement(I), nil));
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
        if AType.Handle = System.TypeInfo(TGUID) then
        begin
          Guid := AValue.AsType<TGUID>;
          case MemberGuidRepresentation(AMember) of
            TCborGuidRepresentation.LowercaseString:
              Exit(TCborValue.NewText(LowerCase(GUIDToString(Guid))));
            TCborGuidRepresentation.RawBytes:
              Exit(TCborValue.NewBytes(GuidToRfc4122Bytes(Guid)));
          else
            Exit(TCborValue.NewUuid(Guid));
          end;
        end;
        TSerializationGraphGuard.EnterLevel;
        try
          Result := TCborValue.NewMap;
          try
            Members := MembersOf(AType);
            for M in Members do
            begin
              RefuseUnwritableMember(M, MemberType(M));
              MemberVal := MemberValue(M, AValue);
              if IsEmptyNullable(MemberType(M), MemberVal) then Continue;
              if (MemberType(M).TypeKind = tkVariant) and
                 VarIsEmpty(MemberVal.AsVariant) then Continue;
              Result.Add(MemberName(M), ValueToCbor(MemberType(M), MemberVal, M));
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
        if AValue.AsObject = nil then Exit(TCborValue.NewNull);
        if not TSerializationGraphGuard.Enter(AValue.AsObject) then
          raise ECborError.CreateFmt(
            '%s is already being written further up the graph: it is a ' +
            'cycle, and CBOR has no back-reference. Break the cycle, or ' +
            'register a CBOR type serializer that writes a key instead.',
            [AValue.AsObject.ClassName]);
        try
          Result := TCborValue.NewMap;
          try
            Members := MembersOf(AType);
            for M in Members do
            begin
              RefuseUnwritableMember(M, MemberType(M));
              MemberVal := MemberValue(M, AValue);
              if IsEmptyNullable(MemberType(M), MemberVal) then Continue;
              { Unassigned is no value at all, so the member is left out. }
              if (MemberType(M).TypeKind = tkVariant) and
                 VarIsEmpty(MemberVal.AsVariant) then Continue;
              Result.Add(MemberName(M), ValueToCbor(MemberType(M), MemberVal, M));
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

    { A Variant through the dynamic tree - the bridge every format shares. }
    tkVariant:
      begin
        if not TSerializationVariants.TryToDynamic(AValue.AsVariant, Tree,
             Why) then
          raise ECborError.CreateFmt('%s: the value %s.',
            [MemberLabel(AMember, AType), Why]);
        try
          Exit(TCborEngine.DynamicToCbor(Tree));
        finally
          Tree.Free;
        end;
      end;
  end;

  { Nothing above can write this. Writing a CBOR null instead would read back
    as a value nobody wrote. }
  raise ECborError.CreateFmt('%s is a %s, which CBOR has no way to write. ' +
    'Register a CBOR type serializer for it, or leave it out with ' +
    '[CborIgnore].', [MemberLabel(AMember, AType), AType.Name]);
end;

{ ----------------------------------------------------- a tree to a value --- }

function CborToValue(AType: TRttiType; AValue: TCborValue;
  AMember: TRttiMember; const AExisting: TValue): TValue; forward;

function CborToDateTime(AValue: TCborValue;
  ARepresentation: TCborDateTimeRepresentation;
  const APattern: string): TDateTime;
begin
  if AValue.TryAsDateTime(Result) then Exit;
  { A date tag that TryAsDateTime declined is one no TDateTime holds - past
    year 9999, or not a number - and reading on would make it something. }
  if (AValue.Kind = TCborKind.Tag) and
     ((AValue.TagNumber = TCborTags.EpochDateTime) or
      (AValue.TagNumber = TCborTags.DateTimeString)) then
    raise ECborInputError.CreateFmt('%s is not a date and time a TDateTime ' +
      'holds.', [AValue.ToDiagnostic]);
  case ARepresentation of
    TCborDateTimeRepresentation.UnixSeconds:
      begin
        if (AValue.Kind in [TCborKind.UInt, TCborKind.NegInt, TCborKind.Float]) and
           TStructuralText.TryUnixFloatSecondsToDateTime(AValue.AsFloat, Result) then
          Exit;
        raise ECborInputError.CreateFmt(
          '%s is not a count of seconds a TDateTime holds.', [AValue.ToDiagnostic]);
      end;
    TCborDateTimeRepresentation.UnixMilliseconds:
      begin
        if AValue.IsInteger and AValue.FitsInt64 and
           TStructuralText.TryUnixMillisToDateTime(AValue.AsInt64, Result) then
          Exit;
        raise ECborInputError.CreateFmt(
          '%s is not a count of milliseconds a TDateTime holds.',
          [AValue.ToDiagnostic]);
      end;
  end;
  if AValue.Kind = TCborKind.Text then
  begin
    { ONE SPELLING, READ EVERYWHERE. A TDate is written as yyyy-mm-dd and a
      TTime as hh:nn:ss by every format here, so every format here reads
      both. Without the second and third lines a perfectly ordinary
      "10:20:30" arriving from BSON or MessagePack reached ISO8601ToDate,
      which wants a full date and raised EDateTimeException - an RTL
      exception in the middle of a contract read, saying nothing about
      which member or which format. A custom pattern is read with itself
      first: it is what this member's writer wrote. }
    if (ARepresentation = TCborDateTimeRepresentation.CustomString) and
       TStructuralText.TryDecodePattern(AValue.AsText, APattern, Result) then
      Exit;
    if TStructuralText.TryDecodeDateTime(AValue.AsText, Result) then Exit;
    if TStructuralText.TryDecodeDate(AValue.AsText, Result) then Exit;
    if TStructuralText.TryDecodeTime(AValue.AsText, Result) then Exit;
    try
      Exit(TStructuralText.DecodeIso8601(AValue.AsText));
    except
      on E: Exception do
        raise ECborInputError.CreateFmt(
          '"%s" is not a date, a time or a date and time.',
          [AValue.AsText]);
    end;
  end;
  { Nothing above read it: it is not a date in any spelling this engine
    knows - refused, never read as 1899-12-30. }
  raise ECborInputError.CreateFmt('%s is not a date, a time or a date and time.',
    [AValue.ToDiagnostic]);
end;

{ Fill a collection object from a CBOR array or map, and say whether it was
  one at all.

  The writer's rule is "anything with a GetEnumerator is a sequence"; this is
  its inverse, and the two have to agree or a list survives one direction and
  not the other. A list is a class with a one-argument Add; a dictionary is a
  class with a two-argument AddOrSetValue. Anything else is an ordinary
  object and this declines it, leaving the member walk to do its work.

  The instance is cleared first. A caller using Populate handed in a live
  object, and appending to whatever it already held would make the result
  depend on what was there before - which is not what a document says. }
function FillCollection(AType: TRttiType; const AInstance: TValue;
  AValue: TCborValue): Boolean;
var
  AddMethod, ClearMethod: TRttiMethod;
  Params: TArray<TRttiParameter>;
  IsMap: Boolean;
  ListAccess: TListAccess;
  DictAccess: TDictionaryAccess;
  I: Integer;
  KeyType, ValueType: TRttiType;
  Key, Item: TValue;

  { An element that never reached the container - the container refused
    it, or its key's value failed - is this read's to free. }
  procedure Discard(AElementType: TRttiType; const AElement: TValue);
  begin
    if AElementType <> nil then
      TSerializationOwnership.ReleaseBuilt(AElementType.Handle, AElement,
        TValue.Empty);
  end;

  { What the container itself raised - a sorted TStringList with
    dupError raises EStringListError - is a document this container cannot
    hold, and reached the caller as the RTL's exception. }
  function Refusal(E: Exception): Exception;
  begin
    Result := ECborInputError.CreateFmt(
      'The %s refused an element the document holds: %s',
      [AInstance.AsObject.ClassName, E.Message]);
  end;

begin
  Result := False;
  if (AType = nil) or (AValue = nil) then Exit;
  if not AInstance.IsObject or (AInstance.AsObject = nil) then Exit;

  { The same classification the writer uses, from the same place, so a list
    cannot survive one direction and not the other. }
  case TSerializationTypes.ContainerKindOf(AType.Handle) of
    TContainerKind.Dictionary:
      begin
        IsMap := True;
        if not TSerializationTypes.TryGetDictionaryAccess(AType.Handle,
          DictAccess) then Exit;
        AddMethod := DictAccess.AddOrSetMethod;
        ClearMethod := DictAccess.ClearMethod;
      end;
    TContainerKind.List:
      begin
        IsMap := False;
        if not TSerializationTypes.TryGetListAccess(AType.Handle,
          ListAccess) then Exit;
        AddMethod := ListAccess.AddMethod;
        ClearMethod := ListAccess.ClearMethod;
      end;
  else
    Exit;
  end;
  if AddMethod = nil then Exit;

  { Checked BEFORE the container is cleared: an array where a dictionary
    belongs, or a map where a list does, is a document that does not match
    the contract - not an empty container, and not a reason to erase the
    caller's items on the way to failing. }
  if IsMap and (AValue.Kind <> TCborKind.Map) then
    raise ECborInputError.CreateFmt('Expected a map for %s, found %s.',
      [AType.Name, AValue.ToDiagnostic]);
  if (not IsMap) and (AValue.Kind <> TCborKind.Arr) then
    raise ECborInputError.CreateFmt('Expected an array for %s, found %s.',
      [AType.Name, AValue.ToDiagnostic]);

  if ClearMethod <> nil then ClearMethod.Invoke(AInstance.AsObject, []);
  Params := AddMethod.GetParameters;

  if IsMap then
  begin
    { A CBOR map's keys are data items, so they convert like any other
      value rather than being assumed to be strings. }
    if AValue.Kind <> TCborKind.Map then Exit;
    KeyType := Params[0].ParamType;
    ValueType := Params[1].ParamType;
    for I := 0 to AValue.Count - 1 do
    begin
      Key := CborToValue(KeyType, AValue.Keys[I], nil, TValue.Empty);
      try
        Item := CborToValue(ValueType, AValue.Items[I], nil, TValue.Empty);
      except
        Discard(KeyType, Key);
        raise;
      end;
      try
        { Not AddOrSetValue: a key the document repeats replaced the value
          this read built for its first occurrence, and a dictionary that
          does not own its values orphaned it. }
        TSerializationOwnership.AddOrSetBuilt(DictAccess, AInstance.AsObject,
          Key, Item);
      except
        on E: Exception do
        begin
          Discard(KeyType, Key);
          Discard(ValueType, Item);
          if string(E.UnitName).StartsWith('PascalForge.') then raise;
          raise Refusal(E);
        end;
      end;
    end;
    Exit(True);
  end;

  if AValue.Kind <> TCborKind.Arr then Exit;
  ValueType := Params[0].ParamType;
  for I := 0 to AValue.Count - 1 do
  begin
    Item := CborToValue(ValueType, AValue.Items[I], nil, TValue.Empty);
    try
      AddMethod.Invoke(AInstance.AsObject, [Item]);
    except
      on E: Exception do
      begin
        Discard(ValueType, Item);
        if string(E.UnitName).StartsWith('PascalForge.') then raise;
        raise Refusal(E);
      end;
    end;
  end;
  Result := True;
end;

function CborToValue(AType: TRttiType; AValue: TCborValue;
  AMember: TRttiMember; const AExisting: TValue): TValue;
var
  I: Integer;
  Len: NativeInt;
  Members: TArray<TRttiMember>;
  M: TRttiMember;
  Obj: TObject;
  Instance: TValue;
  Child: TCborValue;
  Names: TArray<string>;
  Pattern: string;
  Guid: TGUID;
  GuidText: string;
  Arr: TValue;
  Access: TNullableAccess;
  SerializerClass: TCborValueSerializerClass;
  Serializer: TCustomCborValueSerializer;
  Method: TRttiMethod;
  ElemType: TRttiType;
  Elem: TValue;
  EnumOrd: Integer;
  Ords: TArray<Integer>;
  Elems: TArray<TValue>;
  Why: string;
  Tree: TDynamicValue;
  V: Variant;
  OV: OleVariant;
  Built: Boolean;
  TD: PTypeData;
  Prior: TValue;

  { Checked, from each spelling this engine or another producer writes: a
    decimal fraction, text, a float and the scaled integer. StrToCurr raised
    the RTL's EConvertError, and a float assignment made NaN or 1e300 into
    -922337203685477.5808. }
  function ReadCurrency: TValue;
  var
    Text, FloatWhy: string;
    C: Currency;
    S64: Int64;
  begin
    if AValue.TryAsDecimalText(Text) or (AValue.Kind = TCborKind.Text) then
    begin
      if AValue.Kind = TCborKind.Text then Text := AValue.AsText;
      if not TryStrToCurr(Trim(Text), C, TFormatSettings.Invariant) then
        raise ECborInputError.CreateFmt('"%s" is not a currency value.', [Text]);
      Exit(TValue.From<Currency>(C));
    end;
    if AValue.Kind = TCborKind.Float then
    begin
      if not TSerializationTypes.TryFloatFromDouble(System.TypeInfo(Currency),
           AValue.AsFloat, Result, FloatWhy) then
        raise ECborInputError.Create(FloatWhy + '.');
      Exit;
    end;
    if not AValue.IsInteger then
      raise ECborInputError.CreateFmt('Expected a currency, found %s.',
        [AValue.ToDiagnostic]);
    S64 := AValue.AsInt64;
    C := PCurrency(@S64)^;
    Result := TValue.From<Currency>(C);
  end;

begin
  Result := TValue.Empty;
  if AType = nil then Exit;

  SerializerClass := MemberSerializer(AMember);
  if SerializerClass = nil then
    TCborEngine.TryGetTypeSerializer(AType.Handle, SerializerClass);
  if SerializerClass <> nil then
  begin
    Serializer := SerializerClass.Create;
    try
      Exit(Serializer.Deserialize(AValue, AType.Handle, AExisting));
    finally
      Serializer.Free;
    end;
  end;

  if TSerializationTypes.TryGetNullableAccess(AType.Handle, Access) then
  begin
    if (AValue = nil) or (AValue.Kind = TCborKind.Null) or
       (AValue.Kind = TCborKind.Undefined) then
    begin
      TValue.Make(nil, AType.Handle, Result);
      Exit;
    end;
    TValue.Make(nil, AType.Handle, Result);
    Access.SetValue(Result.GetReferenceToRawData,
      CborToValue(GCtx.GetType(Access.ValueType), AValue, AMember,
        TValue.Empty));
    Exit;
  end;

  { CBOR null into a Variant is Null, not Unassigned: the two are different
    values, and a document that says null said which. }
  if (AType.TypeKind = tkVariant) and (AValue <> nil) and
     (AValue.Kind = TCborKind.Null) then
  begin
    V := Null;
    TValue.Make(@V, AType.Handle, Result);
    Exit;
  end;

  if (AValue = nil) or (AValue.Kind = TCborKind.Null) or
     (AValue.Kind = TCborKind.Undefined) then
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

  case AType.TypeKind of
    tkInteger, tkInt64:
      begin
        { The mirror of the writer: a UInt64 member reads major type 0 as
          the unsigned value it is. AsInt64 would raise above
          High(Int64), which is exactly the range a UInt64 exists for. }
        { Range-checked against the member's own type: FromOrdinal made a
          Byte out of 300. }
        if IsUnsignedInt64(AType) or
           (AValue.IsInteger and not AValue.FitsInt64) then
        begin
          if not TSerializationTypes.TryIntegerFromUInt64(AType.Handle,
               AValue.AsUInt64, Result) then
            raise ECborInputError.CreateFmt('%s does not fit in %s.',
              [AValue.ToDiagnostic, AType.Name]);
          Exit;
        end;
        if not TSerializationTypes.TryIntegerFromInt64(AType.Handle,
             AValue.AsInt64, Result) then
          raise ECborInputError.CreateFmt('%s does not fit in %s.',
            [AValue.ToDiagnostic, AType.Name]);
        Exit;
      end;

    tkFloat:
      begin
        if TSerializationTypes.IsCompType(AType.Handle) then
        begin
          if not TSerializationTypes.TryIntegerFromInt64(AType.Handle,
               AValue.AsInt64, Result) then
            raise ECborInputError.CreateFmt('%s does not fit in %s.',
              [AValue.ToDiagnostic, AType.Name]);
          Exit;
        end;
        if GetTypeData(AType.Handle).FloatType = ftCurr then
          Exit(ReadCurrency);
        if (AType.Handle = System.TypeInfo(TDateTime)) or
           (AType.Handle = System.TypeInfo(TDate)) or
           (AType.Handle = System.TypeInfo(TTime)) then
        begin
          Exit(TValue.From<TDateTime>(CborToDateTime(AValue,
            MemberDateRepresentation(AMember, Pattern), Pattern)));
        end;
        { Into the member's own width, checked: a Single does not become
          infinity for a double it cannot hold. }
        if not TSerializationTypes.TryFloatFromDouble(AType.Handle,
             AValue.AsFloat, Result, Why) then
          raise ECborInputError.CreateFmt('%s: %s.', [AType.Name, Why]);
        Exit;
      end;

    tkEnumeration:
      begin
        if AType.Handle = System.TypeInfo(Boolean) then
          Exit(TValue.From<Boolean>(AValue.AsBool));
        { An ordinal the type does not have is no value of it. }
        if AValue.IsInteger then
        begin
          TD := GetTypeData(AType.Handle);
          if (not AValue.FitsInt64) or (AValue.AsInt64 < TD.MinValue) or
             (AValue.AsInt64 > TD.MaxValue) then
            raise ECborInputError.CreateFmt('%s is not a value of %s.',
              [AValue.ToDiagnostic, AType.Name]);
          Exit(TValue.FromOrdinal(AType.Handle, AValue.AsInt64));
        end;
        if EnumNamesFor(AMember, AType.Handle, Names) then
          for I := 0 to Integer(High(Names)) do
            if SameText(Names[I], AValue.AsText) then
              Exit(TValue.FromOrdinal(AType.Handle, I));
        EnumOrd := GetEnumValue(AType.Handle, AValue.AsText);
        if EnumOrd < 0 then
          raise ECborInputError.CreateFmt(
            '"%s" is not a member of %s.', [AValue.AsText, AType.Name]);
        Exit(TValue.FromOrdinal(AType.Handle, EnumOrd));
      end;

    tkSet:
      begin
        { A member name the set does not have is refused, not skipped. }
        if AValue.Kind <> TCborKind.Arr then
          raise ECborInputError.CreateFmt('Expected an array for %s, found %s.',
            [AType.Name, AValue.ToDiagnostic]);
        Ords := nil;
        if not EnumNamesFor(AMember, GetTypeData(AType.Handle)^.CompType^,
             Names) then
          Names := nil;
        for I := 0 to AValue.Count - 1 do
        begin
          if not TSerializationTypes.TryMappedSetElementOrdinal(
               GetTypeData(AType.Handle)^.CompType^, AValue.Items[I].AsText,
               Names, EnumOrd) then
            raise ECborInputError.CreateFmt('"%s" is not a member of %s.',
              [AValue.Items[I].AsText, AType.Name]);
          Ords := Ords + [EnumOrd];
        end;
        if not TSerializationTypes.TryMakeSet(AType.Handle, Ords, Result, Why) then
          raise ECborInputError.CreateFmt('%s is not a %s: %s.',
            [AValue.ToDiagnostic, AType.Name, Why]);
        Exit;
      end;

    { Into the member's own code page, refusing text it cannot hold. }
    tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
      begin
        if not TSerializationTypes.TryStringFromText(AType.Handle,
             AValue.AsText, Result, Why) then
          raise ECborInputError.Create(Why + '.');
        Exit;
      end;

    { A static array has exactly as many elements as its type says. It had
      no reader at all, so the member was left as it was. }
    tkArray:
      begin
        if AValue.Kind <> TCborKind.Arr then
          raise ECborInputError.CreateFmt('Expected an array for %s, found %s.',
            [AType.Name, AValue.ToDiagnostic]);
        ElemType := TRttiArrayType(AType).ElementType;
        SetLength(Elems, AValue.Count);
        I := 0;
        try
          while I < AValue.Count do
          begin
            Elems[I] := CborToValue(ElemType, AValue.Items[I], nil, TValue.Empty);
            Inc(I);
          end;
          if not TSerializationTypes.TryMakeArray(AType.Handle, Elems, Result,
               Why) then
            raise ECborInputError.Create(Why + '.');
        except
          { The elements built so far are this read's, and nothing else
            holds them yet. }
          if ElemType <> nil then
            TSerializationOwnership.ReleaseBuiltElements(ElemType.Handle,
              System.Copy(Elems, 0, I));
          raise;
        end;
        Exit;
      end;

    tkVariant:
      begin
        Tree := TCborEngine.CborToDynamic(AValue);
        try
          if not TSerializationVariants.TryFromDynamic(Tree, V, Why) then
            raise ECborInputError.Create('The CBOR value ' + Why + '.');
        finally
          Tree.Free;
        end;
        if AType.Handle = System.TypeInfo(OleVariant) then
        begin
          OV := V;
          TValue.Make(@OV, AType.Handle, Result);
        end
        else
          TValue.Make(@V, AType.Handle, Result);
        Exit;
      end;

    tkDynArray:
      begin
        if AType.Handle = System.TypeInfo(TBytes) then
          Exit(TValue.From<TBytes>(AValue.AsBytes));
        { A scalar where an array belongs is not an empty array. }
        if AValue.Kind <> TCborKind.Arr then
          raise ECborInputError.CreateFmt('Expected an array for %s, found %s.',
            [AType.Name, AValue.ToDiagnostic]);
        ElemType := TRttiDynamicArrayType(AType).ElementType;
        Arr := TValue.Empty;
        TValue.Make(nil, AType.Handle, Arr);
        Len := AValue.Count;
        DynArraySetLength(PPointer(Arr.GetReferenceToRawData)^,
          AType.Handle, 1, @Len);
        try
          for I := 0 to AValue.Count - 1 do
          begin
            Elem := CborToValue(ElemType, AValue.Items[I], nil, TValue.Empty);
            Arr.SetArrayElement(I, Elem);
          end;
        except
          { Every element of the fresh array is this read's; the ones not
            reached yet are nil. }
          TSerializationOwnership.ReleaseBuilt(AType.Handle, Arr, TValue.Empty);
          raise;
        end;
        Exit(Arr);
      end;

    tkRecord, tkMRecord:
      begin
        if AType.Handle = System.TypeInfo(TGUID) then
        begin
          { All three representations this engine writes, read back: tag 37,
            sixteen raw bytes, and text. A member written with
            [CborGuidRepresentation(RawBytes)] arrives as a bare byte string
            with no tag on it to say what it is, so the length is the only
            thing identifying it - which is why this is a guarded test and
            not a cast. }
          if AValue.TryAsUuid(Guid) then Exit(TValue.From<TGUID>(Guid));
          if (AValue.Kind = TCborKind.Bytes) and
             (Length(AValue.AsBytes) = 16) then
            Exit(TValue.From<TGUID>(TCborGuids.FromRfc4122(AValue.AsBytes)));
          { BRACES ARE OPTIONAL, because every format in this library writes
            a GUID as the canonical thirty-six characters WITHOUT them and
            StringToGUID insists on them. CBOR alone did not add them back,
            so a perfectly ordinary GUID string arriving from JSON, YAML,
            XML or anywhere else raised EConvertError - an exception from
            the RTL, in the middle of a contract read, saying only that the
            text was not a GUID.

            It also raises a CBOR error rather than that one, so a caller
            can tell which format was reading when it happened. }
          GuidText := Trim(AValue.AsText);
          if (GuidText <> '') and (GuidText[1] <> '{') then
            GuidText := '{' + GuidText + '}';
          try
            Exit(TValue.From<TGUID>(StringToGUID(GuidText)));
          except
            on E: Exception do
              raise ECborInputError.CreateFmt('"%s" is not a GUID.',
                [AValue.AsText]);
          end;
        end;
        { A record is a map; anything else found no member and left every
          one at its default, silently. }
        if AValue.Kind <> TCborKind.Map then
          raise ECborInputError.CreateFmt('Expected a map for %s, found %s.',
            [AType.Name, AValue.ToDiagnostic]);
        { Merged into a COPY of the current value, as the class branch fills
          an existing instance: a zeroed record replaced every object already
          in it and reset every member the document left out. A copy, not
          the TValue itself - assigning it shares its data, so a failure
          could not tell the objects this read built from the ones that were
          there. }
        if (not AExisting.IsEmpty) and (AExisting.TypeInfo = AType.Handle) then
          Prior := AExisting
        else
          Prior := TValue.Empty;
        if Prior.IsEmpty then TValue.Make(nil, AType.Handle, Result)
        else TValue.Make(Prior.GetReferenceToRawData, AType.Handle, Result);
        try
          Members := MembersOf(AType);
          for M in Members do
          begin
            Child := AValue.Find(MemberName(M));
            if Child = nil then Continue;
            SetMemberValue(M, Result,
              CborToValue(MemberType(M), Child, M, ExistingValueOf(M, Result)));
          end;
        except
          { The record reaches its owner only on success, so an object this
            read put in it before a later member failed went with the
            temporary. }
          TSerializationOwnership.ReleaseBuilt(AType.Handle, Result, Prior);
          raise;
        end;
        Exit;
      end;

    tkClass:
      begin
        Built := False;
        if AExisting.IsObject and (AExisting.AsObject <> nil) then
          Instance := AExisting
        else
        begin
          Method := TSerializationTypes.DefaultConstructor(AType);
          if Method = nil then
            raise ECborInputError.CreateFmt(
              '%s has no parameterless constructor, so CBOR cannot build ' +
              'one. Pass an instance to Populate instead.', [AType.Name]);
          Obj := Method.Invoke(TRttiInstanceType(AType).MetaclassType,
            []).AsObject;
          TValue.Make(@Obj, AType.Handle, Instance);
          Built := True;
        end;
        { What this read constructed is this read's to free when it fails;
          an instance the caller passed in is never freed. }
        try
          { A class that was written as a sequence has to be read back as
            one. The writer treats anything with a GetEnumerator as a
            sequence, so the reader looks for the matching Add - and this
            has to happen BEFORE the member walk, because a TObjectList<T>
            also has fields and walking them would fill none of them and lose
            every element. }
          if FillCollection(AType, Instance, AValue) then Exit(Instance);
          if AValue.Kind <> TCborKind.Map then
            raise ECborInputError.CreateFmt('Expected a map for %s, found %s.',
              [AType.Name, AValue.ToDiagnostic]);
          Members := MembersOf(AType);
          for M in Members do
          begin
            Child := AValue.Find(MemberName(M));
            if Child = nil then Continue;
            SetMemberValue(M, Instance,
              CborToValue(MemberType(M), Child, M, ExistingValueOf(M, Instance)));
          end;
        except
          { A list or dictionary that does not own its elements, freed alone,
            orphaned every object this read had added to it. }
          if Built then
          begin
            if TSerializationTypes.ContainerKindOf(AType.Handle) <>
               TContainerKind.None then
              TSerializationOwnership.ReleaseBuiltContainer(Instance.AsObject)
            else
              Instance.AsObject.Free;
          end;
          raise;
        end;
        Exit(Instance);
      end;
  end;

  { Nothing above matched: the member is left as it was rather than being
    given a value this engine cannot justify. }
end;

class function TCborEngine.SerializeRoot(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AOptions: TCborEncodeOptions): TBytes;
var
  Tree: TCborValue;
  Mark: Integer;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  { A write that failed deep down must not leave the next one on this
    thread starting part way down the depth limit. }
  Mark := TSerializationGraphGuard.Level;
  try
    Tree := ValueToCbor(GCtx.GetType(ATypeInfo), AValue, nil);
  finally
    TSerializationGraphGuard.RestoreLevel(Mark);
  end;
  try
    Result := Encode(Tree, AOptions);
  finally
    Tree.Free;
  end;
end;

class function TCborEngine.DeserializeRoot(ATypeInfo: PTypeInfo;
  const AData: TBytes; const AExisting: TValue): TValue;
var
  Tree: TCborValue;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  Tree := Decode(AData, TCborDecodeOptions.Default);
  try
    Result := CborToValue(GCtx.GetType(ATypeInfo), Tree, nil, AExisting);
  finally
    Tree.Free;
  end;
end;

end.
