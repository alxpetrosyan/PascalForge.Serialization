{*******************************************************************************
  PascalForge.Asn1.Internal

  INTERNAL IMPLEMENTATION UNIT - applications should not use this unit directly.

  Implements the ASN.1 engine: BER/DER/CER writer and reader, schema-guided
  codec and the Delphi contract walk.
  Exposed through the public facade PascalForge.Asn1 (TAsn1Serializer).

  Registration
    Format registration lives in PascalForge.Asn1.Registration and is explicit.

  Documentation
    docs/formats/asn1.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Asn1.Internal;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  The ASN.1 engine: BER, DER and CER.

  NOT PART OF THE PUBLIC API. Everything here is reachable through
  PascalForge.Asn1; this unit exists so that the public one can be read in
  one sitting.

  WHAT IS IN HERE

    TAsn1Writer      a value, under one set of rules, as octets
    TAsn1Reader      octets as a value, with the rules CHECKED
    TAsn1Codec       the two together
    TAsn1SchemaCodec the same, guided by an X.680 type definition
    TAsn1Engine      the Delphi contract walk

  WHY THREE RULES AND NOT ONE

  BER, DER and CER are not three names for one encoding. They share the
  tag-length-value shape and differ in what they ALLOW, and the differences
  are exactly the ones that matter to anybody who has to compare two
  encodings or check a signature:

    BER   A length may be definite or indefinite. A string may be primitive
          or segmented. A boolean's true may be any non-zero octet. A SET's
          components may be in any order. Several encodings of one value.

    DER   Exactly one encoding of any value. Definite lengths, always the
          shortest form. Primitive strings. True is 0xFF and nothing else.
          A SET's components sorted by their encoded octets. Default values
          ABSENT. This is what a signature is computed over.

    CER   Also canonical, and NOT the same as DER: lengths are INDEFINITE
          for every constructed value, and a string longer than 1000 octets
          is segmented into 1000-octet pieces. It exists for the case where
          the encoder cannot know the length in advance.

  Relabelling DER as CER, or writing BER and calling it DER, produces octets
  that decode and then fail a signature check somewhere the author cannot
  see. So the rule is carried through every call here and CHECKED on the way
  in, not only applied on the way out.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections, System.Generics.Defaults, System.SyncObjs,
  System.Math, System.DateUtils, System.StrUtils,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Serialization.Internal,
  PascalForge.Nullable,
  PascalForge.Asn1.Schema,
  PascalForge.Asn1;

type
  { Encoding and decoding with no schema: the tag-length-value structure and
    the universal types, which is as far as the octets alone can go. }
  TAsn1Codec = class
  public
    class function Encode(AValue: TAsn1Value;
      ARule: TAsn1EncodingRule): TBytes; static;
    class function Decode(const AData: TBytes;
      ARule: TAsn1EncodingRule): TAsn1Value; static;
  end;

  { The same, guided by an X.680 type definition - which is the only thing
    that can tell a SEQUENCE from a SEQUENCE OF, name a component, or say
    which alternative of a CHOICE arrived. }
  TAsn1SchemaCodec = class
  public
    class function Decode(const AData: TBytes; ASchema: TSerializationSchema;
      const ATypeName: string; ARule: TAsn1EncodingRule): TAsn1Value; static;
    class function Encode(AValue: TAsn1Value; ASchema: TSerializationSchema;
      const ATypeName: string; ARule: TAsn1EncodingRule): TBytes; static;
    class function ToDynamic(const AData: TBytes;
      ASchema: TSerializationSchema; const ATypeName: string;
      ARule: TAsn1EncodingRule): TDynamicValue; static;
    { A member the selected type does not declare is omitted under Natural
      and refused, with its path, under Strict and Lossless. The form
      without options is Natural. }
    class function FromDynamic(AValue: TDynamicValue;
      ASchema: TSerializationSchema; const ATypeName: string;
      ARule: TAsn1EncodingRule): TBytes; overload; static;
    class function FromDynamic(AValue: TDynamicValue;
      ASchema: TSerializationSchema; const ATypeName: string;
      ARule: TAsn1EncodingRule;
      const AOptions: TStructuralConversionOptions): TBytes; overload; static;
    { The value tree of a schema-decoded document, as a dynamic tree. }
    class function ValueToDynamic(AValue: TAsn1Value): TDynamicValue; static;
  end;

  { The Delphi contract: the type's members are the components, and the
    attributes say what a member's tag and string type are. }
  TAsn1Engine = class
  strict private
    class var FTypeSerializers: TDictionary<PTypeInfo,
      TAsn1ValueSerializerClass>;
    class var FLock: TCriticalSection;
    class var FFrozen: Boolean;
  public
    class constructor Create;
    class destructor Destroy;

    class function SerializeRoot(ATypeInfo: PTypeInfo; const AValue: TValue;
      ARule: TAsn1EncodingRule): TBytes; static;
    class function DeserializeRoot(ATypeInfo: PTypeInfo; const AData: TBytes;
      ARule: TAsn1EncodingRule): TValue; static;

    class procedure RegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TAsn1ValueSerializerClass); static;
    class function TryGetTypeSerializer(ATypeInfo: PTypeInfo;
      out AClass: TAsn1ValueSerializerClass): Boolean; static;
    class procedure ResetConfiguration; static;
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;
  end;

{ --- the few helpers the public unit needs -------------------------------

  PascalForge.Asn1 builds values and has to know one or two things the codec
  also knows: the universal tag a kind carries, and how a time is spelled.
  Duplicating either would give the library two answers to one question, so
  they live here, once, and the public unit reaches them from its
  implementation section. }

{ The universal tag number X.680 assigns to a kind, or -1 for a kind that
  has none. }
function Asn1UniversalTagOfKind(AKind: TAsn1Kind): Integer;
{ YYMMDDhhmmssZ, which is the only form DER and CER allow. }
function Asn1EncodeUtcTime(AValue: TDateTime): string;
{ YYYYMMDDHHMMSS[.fff]Z, with no trailing zero in the fraction and no
  fraction at all when it is zero - which is what DER and CER require. }
function Asn1EncodeGeneralizedTime(AValue: TDateTime): string;
function Asn1SameBytes(const A, B: TBytes): Boolean;

implementation

var
  GCtx: TRttiContext;

{ The two different diagnoses, kept apart.

  "These octets are not ASN.1" and "these octets are ASN.1 but not DER" are
  different problems with different answers, and a caller validating a
  signed structure needs to tell them apart - which is why the public unit
  has two exception classes and why these are two procedures. }
procedure FailAt(APos: Integer; const AReason: string);
begin
  raise EAsn1InputError.CreateFmt('%s (at octet %d)', [AReason, APos]);
end;

function RuleName(ARule: TAsn1EncodingRule): string;
begin
  case ARule of
    TAsn1EncodingRule.Der: Result := 'DER';
    TAsn1EncodingRule.Cer: Result := 'CER';
  else
    Result := 'BER';
  end;
end;

procedure FailCanonical(ARule: TAsn1EncodingRule; const AWhat: string;
  APos: Integer);
begin
  raise EAsn1CanonicalError.CreateFor(RuleName(ARule), AWhat,
    Format('octet %d', [APos]));
end;

{ ===========================================================================
  UNIVERSAL TAG NUMBERS

  The numbers X.680 assigns. They are here rather than in the public unit
  because a caller works in kinds, not numbers - but the codec has to know
  both, and this is the one table that maps them.
  =========================================================================== }

const
  TagBoolean          = 1;
  TagInteger          = 2;
  TagBitString        = 3;
  TagOctetString      = 4;
  TagNull             = 5;
  TagOid              = 6;
  TagEnumerated       = 10;
  TagReal             = 9;
  TagUtf8String       = 12;
  TagRelativeOid      = 13;
  TagSequence         = 16;
  TagSet              = 17;
  TagNumericString    = 18;
  TagPrintableString  = 19;
  TagTeletexString    = 20;
  TagIa5String        = 22;
  TagUtcTime          = 23;
  TagGeneralizedTime  = 24;
  TagGraphicString    = 25;
  TagVisibleString    = 26;
  TagGeneralString    = 27;
  TagUniversalString  = 28;
  TagBmpString        = 30;

  { CER segments a long string into pieces of exactly this many octets. }
  CerSegmentSize = 1000;

function UniversalTagOf(AKind: TAsn1Kind): Integer;
begin
  case AKind of
    TAsn1Kind.BooleanValue:    Result := TagBoolean;
    TAsn1Kind.IntegerValue:    Result := TagInteger;
    TAsn1Kind.BitString:       Result := TagBitString;
    TAsn1Kind.OctetString:     Result := TagOctetString;
    TAsn1Kind.NullValue:       Result := TagNull;
    TAsn1Kind.Oid:             Result := TagOid;
    TAsn1Kind.RelativeOid:     Result := TagRelativeOid;
    TAsn1Kind.Enumerated:      Result := TagEnumerated;
    TAsn1Kind.RealValue:       Result := TagReal;
    TAsn1Kind.Utf8String:      Result := TagUtf8String;
    TAsn1Kind.NumericString:   Result := TagNumericString;
    TAsn1Kind.PrintableString: Result := TagPrintableString;
    TAsn1Kind.TeletexString:   Result := TagTeletexString;
    TAsn1Kind.Ia5String:       Result := TagIa5String;
    TAsn1Kind.VisibleString:   Result := TagVisibleString;
    TAsn1Kind.GeneralString:   Result := TagGeneralString;
    TAsn1Kind.UniversalString: Result := TagUniversalString;
    TAsn1Kind.BmpString:       Result := TagBmpString;
    TAsn1Kind.Sequence,
    TAsn1Kind.SequenceOf:      Result := TagSequence;
    TAsn1Kind.SetValue,
    TAsn1Kind.SetOf:           Result := TagSet;
    TAsn1Kind.UtcTime:         Result := TagUtcTime;
    TAsn1Kind.GeneralizedTime: Result := TagGeneralizedTime;
  else
    Result := -1;
  end;
end;

function KindOfUniversalTag(ATag: UInt64; AConstructed: Boolean): TAsn1Kind;
begin
  { The whole 64-bit number decides, never its low 32 bits: 2^32 + 1 is an
    unknown tag, not BOOLEAN. Every known tag is below 31. }
  if ATag > UInt64(TagBmpString) then Exit(TAsn1Kind.Unknown);
  case Integer(ATag) of
    TagBoolean:          Result := TAsn1Kind.BooleanValue;
    TagInteger:          Result := TAsn1Kind.IntegerValue;
    TagBitString:        Result := TAsn1Kind.BitString;
    TagOctetString:      Result := TAsn1Kind.OctetString;
    TagNull:             Result := TAsn1Kind.NullValue;
    TagOid:              Result := TAsn1Kind.Oid;
    TagRelativeOid:      Result := TAsn1Kind.RelativeOid;
    TagEnumerated:       Result := TAsn1Kind.Enumerated;
    TagReal:             Result := TAsn1Kind.RealValue;
    TagUtf8String:       Result := TAsn1Kind.Utf8String;
    TagNumericString:    Result := TAsn1Kind.NumericString;
    TagPrintableString:  Result := TAsn1Kind.PrintableString;
    TagTeletexString:    Result := TAsn1Kind.TeletexString;
    TagIa5String:        Result := TAsn1Kind.Ia5String;
    TagUtcTime:          Result := TAsn1Kind.UtcTime;
    TagGeneralizedTime:  Result := TAsn1Kind.GeneralizedTime;
    TagVisibleString:    Result := TAsn1Kind.VisibleString;
    TagGeneralString:    Result := TAsn1Kind.GeneralString;
    TagUniversalString:  Result := TAsn1Kind.UniversalString;
    TagBmpString:        Result := TAsn1Kind.BmpString;
    { A SEQUENCE and a SEQUENCE OF share tag 16, and a SET and a SET OF
      share 17. Nothing in the octets tells them apart, so raw decoding
      yields the structured form and only a schema resolves it. }
    TagSequence:         Result := TAsn1Kind.Sequence;
    TagSet:              Result := TAsn1Kind.SetValue;
  else
    Result := TAsn1Kind.Unknown;
  end;
  { A constructed string (AConstructed with a string kind) is BER's
    segmented form: the pieces are the value, and reassembling them is the
    reader's job. The kind stays what the tag says it is. }
end;

function IsStringKind(AKind: TAsn1Kind): Boolean;
begin
  Result := AKind in [TAsn1Kind.Utf8String, TAsn1Kind.NumericString,
    TAsn1Kind.PrintableString, TAsn1Kind.TeletexString, TAsn1Kind.Ia5String,
    TAsn1Kind.VisibleString, TAsn1Kind.GeneralString,
    TAsn1Kind.UniversalString, TAsn1Kind.BmpString];
end;

{ ===========================================================================
  THE WRITER
  =========================================================================== }

type
  TOctetWriter = record
  strict private
    FData: TBytes;
    FPos: Integer;
    procedure Ensure(ACount: Integer);
  public
    procedure Init;
    procedure PutByte(AValue: Byte);
    procedure PutRaw(const AValue: TBytes);
    function Done: TBytes;
    property Position: Integer read FPos;
  end;

procedure TOctetWriter.Init;
begin
  SetLength(FData, 128);
  FPos := 0;
end;

procedure TOctetWriter.Ensure(ACount: Integer);
begin
  if FPos + ACount <= Length(FData) then Exit;
  SetLength(FData, Max(Length(FData) * 2, FPos + ACount));
end;

procedure TOctetWriter.PutByte(AValue: Byte);
begin
  Ensure(1);
  FData[FPos] := AValue;
  Inc(FPos);
end;

procedure TOctetWriter.PutRaw(const AValue: TBytes);
begin
  if Length(AValue) = 0 then Exit;
  Ensure(Integer(Length(AValue)));
  Move(AValue[0], FData[FPos], Length(AValue));
  Inc(FPos, Length(AValue));
end;

function TOctetWriter.Done: TBytes;
begin
  SetLength(FData, FPos);
  Result := FData;
end;

{ The identifier octets: two class bits, one constructed bit and five tag
  bits, with a high-tag-number form for anything above 30. }
function EncodeIdentifier(ATagClass: TAsn1TagClass; ATagNumber: UInt64;
  AConstructed: Boolean): TBytes;
var
  First: Byte;
  Digits: TBytes;
  N: UInt64;
  I: Integer;
begin
  case ATagClass of
    TAsn1TagClass.Universal:       First := $00;
    TAsn1TagClass.Application:     First := $40;
    TAsn1TagClass.ContextSpecific: First := $80;
  else
    First := $C0;
  end;
  if AConstructed then First := First or $20;

  if ATagNumber <= 30 then Exit(TBytes.Create(First or Byte(ATagNumber)));

  { The high-tag-number form: 0x1F, then base-128 big-endian with the
    continuation bit set on every octet but the last. }
  SetLength(Digits, 0);
  N := ATagNumber;
  repeat
    Digits := TBytes.Create(Byte(N and $7F)) + Digits;
    N := N shr 7;
  until N = 0;
  for I := 0 to Integer(High(Digits)) - 1 do Digits[I] := Digits[I] or $80;
  Result := TBytes.Create(First or $1F) + Digits;
end;

{ The length octets, in the SHORTEST definite form - which is a DER and CER
  requirement and simply good manners in BER. }
function EncodeLength(ALength: Integer): TBytes;
var
  Digits: TBytes;
  N: Integer;
begin
  if ALength < 128 then Exit(TBytes.Create(Byte(ALength)));
  SetLength(Digits, 0);
  N := ALength;
  while N > 0 do
  begin
    Digits := TBytes.Create(Byte(N and $FF)) + Digits;
    N := N shr 8;
  end;
  Result := TBytes.Create(Byte($80 or Length(Digits))) + Digits;
end;

{ An INTEGER's content octets: two's complement, big-endian, in the fewest
  octets that keep the sign - which is why 128 takes two octets and -128
  takes one. }
{ ===========================================================================
  REAL - X.690 clause 8.5

  Three encodings share one tag, and a decoder has to accept all three:

    no content octets at all      the value is zero (8.5.2)
    first octet bit 8 = 1         BINARY: base, scale, exponent, mantissa
    first octet bits 8..7 = 00    DECIMAL: ISO 6093 text in the rest (8.5.7)
    first octet bits 8..7 = 01    a SPECIAL value, one octet only (8.5.9)

  This library WRITES the binary form, because it is the one DER and CER
  require and the only one that is exact: an IEEE double is already a sign, a
  power of two and an integer mantissa, so base 2 carries it with nothing
  rounded and nothing invented. It READS all three, because somebody else's
  encoder may have written any of them.

  THE CANONICAL RULES (X.690 clause 11.3.1) are not optional for DER and CER,
  and they are cheap, so the BER writer follows them too: base 2, scale
  factor zero, the mantissa shifted down until it is ODD, and the exponent in
  the fewest octets that hold it. Two encoders that both "write a REAL" but
  disagree about normalisation produce different bytes for the same number,
  and a signature over those bytes then fails for no reason anybody can see.
  =========================================================================== }

const
  { 8.5.9: each special value is a single content octet with bit 8 set and
    bit 7 clear. }
  RealPlusInfinity  = $40;
  RealMinusInfinity = $41;
  RealNotANumber    = $42;
  RealMinusZero     = $43;

{ The exponent, two's complement, in as few octets as hold it. }
function EncodeRealExponent(AExponent: Integer): TBytes;
var
  I, First: Integer;
  Raw: array[0..3] of Byte;
begin
  Raw[0] := Byte((AExponent shr 24) and $FF);
  Raw[1] := Byte((AExponent shr 16) and $FF);
  Raw[2] := Byte((AExponent shr 8) and $FF);
  Raw[3] := Byte(AExponent and $FF);
  { Drop leading octets that only repeat the sign bit, but never the one that
    carries it: $00 $80 is +128 and $80 alone is -128. }
  First := 0;
  while (First < 3) and
        (((Raw[First] = $00) and ((Raw[First + 1] and $80) = 0)) or
         ((Raw[First] = $FF) and ((Raw[First + 1] and $80) <> 0))) do
    Inc(First);
  SetLength(Result, 4 - First);
  for I := First to 3 do Result[I - First] := Raw[I];
end;

function EncodeRealContent(AValue: Double): TBytes;
var
  Bits: UInt64;
  Sign: Boolean;
  RawExp: Integer;
  Mantissa: UInt64;
  Exponent: Integer;
  ExpBytes, MantBytes: TBytes;
  First: Integer;
  I: Integer;
  Header: Byte;
begin
  Bits := PUInt64(@AValue)^;
  Sign := (Bits and UInt64($8000000000000000)) <> 0;
  RawExp := Integer((Bits shr 52) and $7FF);
  Mantissa := Bits and UInt64($000FFFFFFFFFFFFF);

  { 8.5.9, and the reason this function cannot simply refuse them: ASN.1 has
    a spelling for every one of these, so nothing is lost and nothing is
    silently turned into null or zero. }
  if RawExp = $7FF then
  begin
    if Mantissa <> 0 then Exit(TBytes.Create(RealNotANumber));
    if Sign then Exit(TBytes.Create(RealMinusInfinity));
    Exit(TBytes.Create(RealPlusInfinity));
  end;

  if (RawExp = 0) and (Mantissa = 0) then
  begin
    { 8.5.2: positive zero has NO content octets. Minus zero is a different
      value and has its own, which is the only way to tell them apart. }
    if Sign then Exit(TBytes.Create(RealMinusZero));
    SetLength(Result, 0);
    Exit;
  end;

  if RawExp = 0 then
  begin
    { Subnormal: no implicit leading bit, and the exponent is fixed. }
    Exponent := -1074;
  end
  else
  begin
    Mantissa := Mantissa or UInt64($0010000000000000);
    Exponent := RawExp - 1075;
  end;

  { 11.3.1: the mantissa is odd, so the pair (mantissa, exponent) is unique.
    Without this, 1.0 could be written as 1x2^0 or 2x2^-1 or 4x2^-2, all
    correct and all different bytes. }
  while (Mantissa and 1) = 0 do
  begin
    Mantissa := Mantissa shr 1;
    Inc(Exponent);
  end;

  ExpBytes := EncodeRealExponent(Exponent);

  { The mantissa, unsigned, base 256, shortest. Its sign lives in the header
    octet, not here. }
  SetLength(MantBytes, 8);
  for I := 0 to 7 do
    MantBytes[I] := Byte((Mantissa shr (8 * (7 - I))) and $FF);
  First := 0;
  while (First < 7) and (MantBytes[First] = 0) do Inc(First);
  MantBytes := Copy(MantBytes, First, 8 - First);

  { 8.5.7.1-8.5.7.4: bit 8 set marks binary; bit 7 is the sign; bits 6-5 are
    the base (00 = 2); bits 4-3 are the scale factor (00); bits 2-1 say how
    the exponent length is given. }
  Header := $80;
  if Sign then Header := Header or $40;
  case Integer(Length(ExpBytes)) of
    1: ;                                    { bits 2-1 = 00 }
    2: Header := Header or $01;
    3: Header := Header or $02;
  else
    Header := Header or $03;                { the next octet is the length }
  end;

  if Length(ExpBytes) <= 3 then
    Result := TBytes.Create(Header) + ExpBytes + MantBytes
  else
    Result := TBytes.Create(Header, Byte(Length(ExpBytes))) + ExpBytes +
      MantBytes;
end;

{ M x 2^E as the nearest Double, rounding half to even as IEEE 754 does,
  with ASticky saying whether nonzero bits below M were already dropped.
  Built from the bits, so it is exact wherever a Double can be and correct
  at both ends - subnormals, and overflow to infinity - on every platform. }
function ComposeDouble(ANegative: Boolean; AMantissa: UInt64; AExponent: Int64;
  ASticky: Boolean): Double;
var
  Bits, Dropped, Half: UInt64;
  Width, Shift: Integer;
  Biased: Int64;
  Sticky: Boolean;

  { AMantissa shr AShift, rounded half to even, with the sticky bit. }
  function RoundedShift(AValue: UInt64; AShift: Integer): UInt64;
  begin
    if AShift <= 0 then Exit(AValue);
    if AShift >= 64 then
    begin
      { Everything is below the last place. It rounds up only when it is
        more than half of it - which, shifted this far, it never is. }
      Exit(0);
    end;
    Result := AValue shr AShift;
    Dropped := AValue and ((UInt64(1) shl AShift) - 1);
    Half := UInt64(1) shl (AShift - 1);
    if (Dropped > Half) or ((Dropped = Half) and (Sticky or ((Result and 1) = 1)))
    then
      Inc(Result);
  end;

begin
  Sticky := ASticky;
  if AMantissa = 0 then
  begin
    if ANegative then Exit(-0.0);
    Exit(0.0);
  end;

  Width := 0;
  Bits := AMantissa;
  while Bits <> 0 do
  begin
    Inc(Width);
    Bits := Bits shr 1;
  end;

  { To exactly 53 significant bits: value = Bits x 2^AExponent. }
  if Width > 53 then
  begin
    Bits := RoundedShift(AMantissa, Width - 53);
    Inc(AExponent, Width - 53);
    { Rounding up can carry into a 54th bit. }
    if Bits = (UInt64(1) shl 53) then
    begin
      Bits := Bits shr 1;
      Inc(AExponent);
    end;
  end
  else
  begin
    Bits := AMantissa shl (53 - Width);
    Dec(AExponent, 53 - Width);
  end;

  Biased := AExponent + 1075;
  if Biased >= 2047 then
    Bits := UInt64($7FF0000000000000)                 { overflow: infinity }
  else if Biased >= 1 then
    Bits := (UInt64(Biased) shl 52) or (Bits and UInt64($000FFFFFFFFFFFFF))
  else
  begin
    { Subnormal: the exponent field is 0 and the value is Bits x 2^-1074,
      so the 53 bits lose 1 - Biased of their low places. A carry out of
      the rounding lands in the exponent field, where it belongs. }
    Shift := Integer(1 - Biased);
    if Shift > 60 then Shift := 64;
    Bits := RoundedShift(Bits, Shift);
  end;
  if ANegative then Bits := Bits or UInt64($8000000000000000);
  Result := PDouble(@Bits)^;
end;

function DecodeRealContent(const AContent: TBytes;
  AFail: TProc<string>): Double;
var
  Header: Byte;
  Base, ScaleFactor, ExpLen, I, Cursor, Extra: Integer;
  Exponent: Int64;
  Top: UInt64;
  Sticky: Boolean;
  Negative: Boolean;
  Text: string;
begin
  { 8.5.2 }
  if Length(AContent) = 0 then Exit(0.0);

  Header := AContent[0];

  { 8.5.9 }
  if (Header and $C0) = $40 then
  begin
    if Length(AContent) <> 1 then
      AFail('A special REAL value is one content octet and this one has ' +
        IntToStr(Length(AContent)) + '.');
    case Header of
      RealPlusInfinity:  Exit(Infinity);
      RealMinusInfinity: Exit(NegInfinity);
      RealNotANumber:    Exit(NaN);
      RealMinusZero:     Exit(-0.0);
    else
      AFail(Format('A REAL whose first content octet is $%.2x, which X.690 ' +
        'clause 8.5.9 does not define.', [Header]));
      Exit(0.0);
    end;
  end;

  { 8.5.7: the decimal form. Somebody else's encoder may prefer it, and ISO
    6093 numbers are ordinary decimal text once the format nibble is off. }
  if (Header and $80) = 0 then
  begin
    Text := TEncoding.ASCII.GetString(Copy(AContent, 1, Length(AContent) - 1));
    Text := Text.Trim.Replace(',', '.');
    { Correctly rounded: TryStrToFloat misread 17-digit text on Win64, and on
      Win32 refused the text of MaxDouble itself as out of range. }
    if not TStructuralText.TryParseFloat(Text, Result) then
    begin
      AFail('A decimal REAL whose content "' + Text +
        '" is not an ISO 6093 number.');
      Exit(0.0);
    end;
    Exit;
  end;

  { 8.5.6: the binary form. }
  Negative := (Header and $40) <> 0;
  case (Header shr 4) and $03 of
    0: Base := 2;
    1: Base := 8;
    2: Base := 16;
  else
    AFail('A binary REAL whose base field is 3, which X.690 clause 8.5.7.2 ' +
      'reserves.');
    Exit(0.0);
  end;
  ScaleFactor := (Header shr 2) and $03;

  Cursor := 1;
  case Header and $03 of
    0: ExpLen := 1;
    1: ExpLen := 2;
    2: ExpLen := 3;
  else
    if Length(AContent) < 2 then
    begin
      AFail('A binary REAL that says its exponent length follows and then ' +
        'ends.');
      Exit(0.0);
    end;
    ExpLen := AContent[1];
    Cursor := 2;
    if ExpLen = 0 then
    begin
      AFail('A binary REAL with an exponent of zero octets.');
      Exit(0.0);
    end;
  end;

  if Length(AContent) < Cursor + ExpLen + 1 then
  begin
    AFail('A binary REAL shorter than its own exponent and mantissa.');
    Exit(0.0);
  end;
  if ExpLen > 8 then
  begin
    AFail('A binary REAL with an exponent of ' + IntToStr(ExpLen) +
      ' octets, which no finite double can need.');
    Exit(0.0);
  end;

  { Two's complement, sign-extended from the first octet. }
  if (AContent[Cursor] and $80) <> 0 then Exponent := -1 else Exponent := 0;
  for I := 0 to ExpLen - 1 do
    Exponent := (Exponent shl 8) or AContent[Cursor + I];
  Inc(Cursor, ExpLen);

  { value = S x N x 2^F x base^E (8.5.7), and every base is a power of two,
    so the whole thing is N x 2^(F + E x log2(base)) - composed from its bits
    below, exactly. Power() was approximate, and on Win64, where Extended is
    Double, there was no extra range to hide it: 2^-1074 came back as 0 and
    MaxDouble as a neighbour of itself. }
  Top := 0;
  Sticky := False;
  Extra := 0;
  for I := Cursor to Integer(High(AContent)) do
    if Top <= (High(UInt64) shr 8) then
      Top := (Top shl 8) or AContent[I]
    else
    begin
      { Beyond 64 significant bits: what falls off only matters for
        rounding, and a sticky bit says whether any of it was set. }
      Inc(Extra, 8);
      if AContent[I] <> 0 then Sticky := True;
    end;

  if Exponent > 100000 then Exponent := 100000
  else if Exponent < -100000 then Exponent := -100000;
  case Base of
    8:  Exponent := Exponent * 3;
    16: Exponent := Exponent * 4;
  end;
  Result := ComposeDouble(Negative, Top, Exponent + ScaleFactor + Extra, Sticky);
end;

function EncodeIntegerContent(const AValue: TAsn1BigInt): TBytes;
begin
  Result := AValue.ToTwosComplement;
end;

{ Long division and multiply-add on a big-endian magnitude.

  TAsn1BigInt keeps its own versions of these private, which is right: they
  are its arithmetic, not its API. The magnitude itself IS public, so the
  codec does its own - six lines each - rather than widening a record's
  interface for one caller. }
function MagnitudeDivMod(const AMagnitude: TBytes; ADivisor: Cardinal;
  out ARemainder: Cardinal): TBytes;
var
  I, Start: Integer;
  Cur: UInt64;
begin
  SetLength(Result, Length(AMagnitude));
  ARemainder := 0;
  for I := 0 to Integer(High(AMagnitude)) do
  begin
    Cur := (UInt64(ARemainder) shl 8) or AMagnitude[I];
    Result[I] := Byte(Cur div ADivisor);
    ARemainder := Cardinal(Cur mod ADivisor);
  end;
  { Trim the leading zeros, so that "is it zero yet" is a length test. }
  Start := 0;
  while (Start < Length(Result)) and (Result[Start] = 0) do Inc(Start);
  Result := Copy(Result, Start, Length(Result) - Start);
end;

function MagnitudeMulAdd(const AMagnitude: TBytes;
  AMultiplier, AAddend: Cardinal): TBytes;
var
  I: Integer;
  Carry, Cur: UInt64;
begin
  Result := Copy(AMagnitude, 0, Length(AMagnitude));
  Carry := AAddend;
  for I := Integer(High(Result)) downto 0 do
  begin
    Cur := UInt64(Result[I]) * AMultiplier + Carry;
    Result[I] := Byte(Cur and $FF);
    Carry := Cur shr 8;
  end;
  while Carry <> 0 do
  begin
    Result := TBytes.Create(Byte(Carry and $FF)) + Result;
    Carry := Carry shr 8;
  end;
  I := 0;
  while (I < High(Result)) and (Result[I] = 0) do Inc(I);
  Result := Copy(Result, I, Length(Result) - I);
end;

{ An OID arc is an UNBOUNDED integer - X.660 gives it no ceiling, and real
  arcs have exceeded 64 bits - which is why the model holds them as big
  integers and why the base-128 encoding here is long division rather than
  a shift. Casting an arc to UInt64 would work on every OID anybody has
  written down and then fail on the one that matters. }
function EncodeArc(const AArc: TAsn1BigInt): TBytes;
var
  Magnitude, Digits: TBytes;
  Remainder: Cardinal;
  I: Integer;
begin
  Magnitude := AArc.Magnitude;
  SetLength(Digits, 0);
  if Length(Magnitude) = 0 then Digits := TBytes.Create(0)
  else
    repeat
      Magnitude := MagnitudeDivMod(Magnitude, 128, Remainder);
      Digits := TBytes.Create(Byte(Remainder)) + Digits;
    until Length(Magnitude) = 0;
  { Every octet but the last carries the continuation bit. }
  for I := 0 to Integer(High(Digits)) - 1 do Digits[I] := Digits[I] or $80;
  Result := Digits;
end;

function EncodeOidContent(const AOid: TAsn1Oid; ARelative: Boolean): TBytes;
var
  I: Integer;
  W: TOctetWriter;
  First: TBytes;
  Lead: Int64;
begin
  W.Init;
  if ARelative then
  begin
    for I := 0 to AOid.ArcCount - 1 do W.PutRaw(EncodeArc(AOid.Arcs[I]));
    Exit(W.Done);
  end;

  if AOid.ArcCount < 2 then
    raise EAsn1Error.Create(
      'An OBJECT IDENTIFIER needs at least two arcs: X.690 combines the ' +
      'first two into one subidentifier, so one arc has nothing to combine ' +
      'with.');
  { X.690 clause 8.19.4: the first subidentifier is 40 times the first arc
    plus the second, which is why 1.2.840 starts with the octet 0x2A.

    The first arc is 0, 1 or 2 - X.660 defines exactly three roots - so 40
    times it is a small number, and the addition is done onto the SECOND
    arc's magnitude, which may be arbitrarily large. }
  if (not AOid.Arcs[0].TryToInt64(Lead)) or (Lead < 0) or (Lead > 2) then
    raise EAsn1Error.Create(
      'The first arc of an OBJECT IDENTIFIER is 0, 1 or 2. X.660 defines ' +
      'those three roots and no others, and the encoding has no room for a ' +
      'fourth.');
  First := MagnitudeMulAdd(AOid.Arcs[1].Magnitude, 1,
    UInt32(Lead * 40));
  W.PutRaw(EncodeArc(TAsn1BigInt.FromMagnitude(False, First)));
  for I := 2 to AOid.ArcCount - 1 do W.PutRaw(EncodeArc(AOid.Arcs[I]));
  Result := W.Done;
end;

function EncodeUtcTime(AValue: TDateTime): string;
begin
  { Refused before it is spelled: FormatDateTime renders a day before year 1
    as 0000-00-00, which the reader then refuses. }
  TStructuralText.CheckDateTime(AValue);
  { YYMMDDhhmmssZ - the only form DER and CER allow, and the one everything
    else writes too. }
  Result := FormatDateTime('yymmddhhnnss', AValue, TFormatSettings.Invariant) +
    'Z';
end;

function EncodeGeneralizedTime(AValue: TDateTime): string;
var
  Millis: Word;
  Y, M, D, H, N, S: Word;
begin
  { YYYY holds the years 1 to 9999 and the reader accepts nothing else; past
    them FormatDateTime wrote 0000-00-00 or a fifth digit. }
  TStructuralText.CheckDateTime(AValue);
  DecodeDateTime(AValue, Y, M, D, H, N, S, Millis);
  Result := FormatDateTime('yyyymmddhhnnss', AValue, TFormatSettings.Invariant);
  { DER and CER forbid a trailing zero in the fraction and forbid the
    fraction entirely when it is zero, so it is only written when there is
    something to write. }
  if Millis <> 0 then
  begin
    Result := Result + '.' + Format('%.3d', [Millis]);
    while (Result <> '') and (Result[Length(Result)] = '0') do
      SetLength(Result, Length(Result) - 1);
  end;
  Result := Result + 'Z';
end;

{ A surrogate at AIndex with no partner: a high one not followed by a low
  one, or a low one not preceded by a high one. }
function IsUnpairedSurrogate(const AText: string; AIndex: Integer): Boolean;
var
  C: Char;
begin
  C := AText[AIndex];
  if (C >= #$D800) and (C <= #$DBFF) then
    Result := (AIndex >= Length(AText)) or (AText[AIndex + 1] < #$DC00) or
      (AText[AIndex + 1] > #$DFFF)
  else if (C >= #$DC00) and (C <= #$DFFF) then
    Result := (AIndex <= 1) or (AText[AIndex - 1] < #$D800) or
      (AText[AIndex - 1] > #$DBFF)
  else
    Result := False;
end;

{ Half of a character is not a character, and UCS-2 and UCS-4 have no
  spelling for it: the UCS-4 writer combined a lone high surrogate with
  whatever followed it into a code point nobody wrote. Refused, as the UTF-8
  types refuse it. }
procedure RefuseUnpairedSurrogate(AKind: TAsn1Kind; const AText: string;
  AIndex: Integer);
begin
  if IsUnpairedSurrogate(AText, AIndex) then
    raise EAsn1Error.CreateFmt(
      'U+%s at character %d cannot be written as a %s: it is an unpaired ' +
      'UTF-16 surrogate, half of a character, and silently replacing it ' +
      'would change the value. Remove it, or carry the value as an OCTET ' +
      'STRING.',
      [IntToHex(Ord(AText[AIndex]), 4), AIndex,
       GetEnumName(System.TypeInfo(TAsn1Kind), Ord(AKind))]);
end;

function StringContentOf(AKind: TAsn1Kind; const AText: string): TBytes;
var
  I: Integer;
  Code: Cardinal;
begin
  case AKind of
    TAsn1Kind.Utf8String, TAsn1Kind.GeneralString:
      Exit(StringToUtf8Bytes(AText));
    TAsn1Kind.BmpString:
      begin
        { BMPString is UCS-2, BIG-endian - the opposite of Delphi's own
          UTF-16 order, which is the single most common way a BMPString is
          written wrong. }
        SetLength(Result, Length(AText) * 2);
        for I := 1 to Length(AText) do
        begin
          RefuseUnpairedSurrogate(AKind, AText, I);
          Result[(I - 1) * 2] := Byte(Ord(AText[I]) shr 8);
          Result[(I - 1) * 2 + 1] := Byte(Ord(AText[I]) and $FF);
        end;
        Exit;
      end;
    TAsn1Kind.UniversalString:
      begin
        { UCS-4, big-endian. A surrogate pair in the Delphi string is one
          code point here. }
        SetLength(Result, 0);
        I := 1;
        while I <= Length(AText) do
        begin
          RefuseUnpairedSurrogate(AKind, AText, I);
          Code := Ord(AText[I]);
          if (Code >= $D800) and (Code <= $DBFF) then
          begin
            Code := $10000 + ((Code - $D800) shl 10) +
              (Cardinal(Ord(AText[I + 1])) - Cardinal($DC00));
            Inc(I);
          end;
          Result := Result + TBytes.Create(Byte(Code shr 24),
            Byte(Code shr 16), Byte(Code shr 8), Byte(Code));
          Inc(I);
        end;
        Exit;
      end;
  end;
  { The rest are single-octet character sets whose repertoire is a subset of
    ASCII, so a code point above 127 is a value the type cannot hold and is
    refused rather than truncated. }
  SetLength(Result, Length(AText));
  for I := 1 to Length(AText) do
  begin
    if Ord(AText[I]) > 127 then
      raise EAsn1Error.CreateFmt(
        'U+%s cannot be written as a %s: that type holds only the characters ' +
        'X.680 lists for it, and silently replacing the character would ' +
        'change the value.',
        [IntToHex(Ord(AText[I]), 4), GetEnumName(System.TypeInfo(TAsn1Kind),
          Ord(AKind))]);
    Result[I - 1] := Byte(Ord(AText[I]));
  end;
end;

function EncodeValue(AValue: TAsn1Value; ARule: TAsn1EncodingRule): TBytes;
  forward;

{ The content octets of a constructed value: its components, one after
  another, with a SET's sorted when the rules say so. }
function ConstructedContent(AValue: TAsn1Value;
  ARule: TAsn1EncodingRule): TBytes;
var
  Parts: TArray<TBytes>;
  I: Integer;
  W: TOctetWriter;
begin
  SetLength(Parts, AValue.Count);
  for I := 0 to AValue.Count - 1 do
    Parts[I] := EncodeValue(AValue.Items[I], ARule);

  { DER and CER sort a SET's components by their ENCODED OCTETS, which is
    what makes the encoding canonical - and a SET OF's by the same rule.
    BER leaves the order alone, because BER allows any. }
  if (ARule <> TAsn1EncodingRule.Ber) and
     (AValue.Kind in [TAsn1Kind.SetValue, TAsn1Kind.SetOf]) then
    TArray.Sort<TBytes>(Parts, TComparer<TBytes>.Construct(
      function(const A, B: TBytes): Integer
      var
        K, N: Integer;
      begin
        N := Integer(Min(Length(A), Length(B)));
        for K := 0 to N - 1 do
          if A[K] <> B[K] then Exit(Integer(A[K]) - Integer(B[K]));
        { A shorter encoding that is a prefix of a longer one sorts first,
          which is the rule X.690 clause 11.6 gives. }
        Result := Integer(Length(A) - Length(B));
      end));

  W.Init;
  for I := 0 to Integer(High(Parts)) do W.PutRaw(Parts[I]);
  Result := W.Done;
end;

{ CER (X.690 9.2) writes a string past 1000 content octets as primitive
  fragments of exactly 1000 content octets, the last excepted, inside a
  constructed value with an indefinite length. A character string is an
  IMPLICIT OCTET STRING underneath (X.690 8.23.5), so its fragments are
  OCTET STRINGs, never its own tag. A BIT STRING's fragments are BIT
  STRINGs: each one's first content octet is its unused-bit count - zero
  for all but the last - so each carries 999 octets of bits. AContent is
  the whole primitive content, the unused-bit octet first for a BIT STRING. }
function CerSegments(AValue: TAsn1Value; const AContent: TBytes): TBytes;
var
  W: TOctetWriter;
  Offset, Take, Start, Room, FragmentTag: Integer;
  Piece: TBytes;
  BitString: Boolean;
begin
  BitString := AValue.Kind = TAsn1Kind.BitString;
  if BitString then
  begin
    FragmentTag := TagBitString;
    Start := 1;
    Room := CerSegmentSize - 1;
  end
  else
  begin
    FragmentTag := TagOctetString;
    Start := 0;
    Room := CerSegmentSize;
  end;
  W.Init;
  W.PutRaw(EncodeIdentifier(AValue.TagClass, AValue.TagNumber, True));
  W.PutByte($80);   { indefinite length }
  Offset := Start;
  while Offset < Length(AContent) do
  begin
    Take := Integer(Min(Room, Length(AContent) - Offset));
    Piece := Copy(AContent, Offset, Take);
    if BitString then
    begin
      if Offset + Take < Length(AContent) then
        Piece := TBytes.Create(0) + Piece
      else
        Piece := TBytes.Create(AContent[0]) + Piece;
    end;
    W.PutRaw(EncodeIdentifier(TAsn1TagClass.Universal, UInt64(FragmentTag),
      False));
    W.PutRaw(EncodeLength(Integer(Length(Piece))));
    W.PutRaw(Piece);
    Inc(Offset, Take);
  end;
  W.PutByte(0);
  W.PutByte(0);
  Result := W.Done;
end;

function EncodeValue(AValue: TAsn1Value; ARule: TAsn1EncodingRule): TBytes;
var
  Content: TBytes;
  W: TOctetWriter;
  Constructed: Boolean;
  Tag: Integer;
begin
  if AValue = nil then
    raise EAsn1Error.Create('Nothing to encode.');

  Constructed := AValue.IsConstructed;

  case AValue.Kind of
    TAsn1Kind.BooleanValue:
      { DER and CER say TRUE is 0xFF and nothing else; BER allows any
        non-zero octet, and writing 0xFF there too costs nothing and is
        what every other encoder does. }
      if AValue.AsBoolean then Content := TBytes.Create($FF)
      else Content := TBytes.Create($00);

    TAsn1Kind.IntegerValue, TAsn1Kind.Enumerated:
      Content := EncodeIntegerContent(AValue.AsInteger);

    TAsn1Kind.RealValue:
      Content := EncodeRealContent(AValue.AsReal);

    TAsn1Kind.BitString:
      { The FIRST content octet is the number of unused bits in the last
        one. Losing it turns a 3-bit string into a 8-bit one that happens to
        compare equal sometimes. }
      Content := TBytes.Create(AValue.UnusedBits) + AValue.AsBytes;

    TAsn1Kind.OctetString:
      Content := AValue.AsBytes;

    TAsn1Kind.NullValue:
      SetLength(Content, 0);

    TAsn1Kind.Oid:
      Content := EncodeOidContent(AValue.AsOid, False);

    TAsn1Kind.RelativeOid:
      Content := EncodeOidContent(AValue.AsOid, True);

    TAsn1Kind.UtcTime:
      Content := StringContentOf(TAsn1Kind.Ia5String,
        EncodeUtcTime(AValue.AsDateTime));

    TAsn1Kind.GeneralizedTime:
      Content := StringContentOf(TAsn1Kind.Ia5String,
        EncodeGeneralizedTime(AValue.AsDateTime));

    TAsn1Kind.Sequence, TAsn1Kind.SequenceOf,
    TAsn1Kind.SetValue, TAsn1Kind.SetOf:
      begin
        Constructed := True;
        Content := ConstructedContent(AValue, ARule);
      end;

    TAsn1Kind.Tagged:
      begin
        if AValue.Count <> 1 then
          raise EAsn1Error.Create(
            'A tagged value holds exactly one inner value.');
        Constructed := True;
        Content := EncodeValue(AValue.Items[0], ARule);
      end;

    TAsn1Kind.Unknown:
      begin
        { A tag this library does not interpret: its content octets travel
          unchanged, which is what lets an unknown extension survive. }
        if AValue.IsConstructed then Content := ConstructedContent(AValue, ARule)
        else Content := AValue.AsBytes;
      end;
  else
    if IsStringKind(AValue.Kind) then
      Content := StringContentOf(AValue.Kind, AValue.AsText)
    else
      raise EAsn1Error.CreateFmt('Cannot encode %s.', [AValue.Describe]);
  end;

  { CER: every constructed value takes an indefinite length, and a string
    over 1000 octets is segmented. This is the difference from DER, and
    producing DER and calling it CER is exactly the defect this branch
    exists to avoid. }
  if ARule = TAsn1EncodingRule.Cer then
  begin
    Tag := UniversalTagOf(AValue.Kind);
    if (IsStringKind(AValue.Kind) or (AValue.Kind = TAsn1Kind.OctetString) or
        (AValue.Kind = TAsn1Kind.BitString)) and
       (Length(Content) > CerSegmentSize) and (Tag > 0) then
      Exit(CerSegments(AValue, Content));
    if Constructed then
    begin
      W.Init;
      W.PutRaw(EncodeIdentifier(AValue.TagClass, AValue.TagNumber, True));
      W.PutByte($80);
      W.PutRaw(Content);
      W.PutByte(0);
      W.PutByte(0);
      Exit(W.Done);
    end;
  end;

  { BER honours an explicit request for an indefinite length, because BER is
    the rule that allows one. }
  if (ARule = TAsn1EncodingRule.Ber) and AValue.UseIndefiniteLength and
     Constructed then
  begin
    W.Init;
    W.PutRaw(EncodeIdentifier(AValue.TagClass, AValue.TagNumber, True));
    W.PutByte($80);
    W.PutRaw(Content);
    W.PutByte(0);
    W.PutByte(0);
    Exit(W.Done);
  end;

  W.Init;
  W.PutRaw(EncodeIdentifier(AValue.TagClass, AValue.TagNumber, Constructed));
  W.PutRaw(EncodeLength(Integer(Length(Content))));
  W.PutRaw(Content);
  Result := W.Done;
end;

{ ===========================================================================
  THE READER

  Every rule is CHECKED here, not merely applied on the way out. A decoder
  that accepts an indefinite length while claiming to read DER will accept a
  document that no DER encoder could have produced - and the whole point of
  DER is that there is only one such document.
  =========================================================================== }

type
  TOctetReader = record
  strict private
    FData: TBytes;
    FPos: Integer;
    FEnd: Integer;
    FRule: TAsn1EncodingRule;
    FDepth: Integer;
  public
    procedure Init(const AData: TBytes; ARule: TAsn1EncodingRule);
    procedure Need(ACount: Integer);
    function CheckedLength(AValue: UInt64; AAt: Integer): Integer;
    function AtEnd: Boolean;
    function GetByte: Byte;
    function Peek: Byte;
    function GetRaw(ACount: Integer): TBytes;
    function ReadValue: TAsn1Value;
    property Position: Integer read FPos write FPos;
    property Limit: Integer read FEnd write FEnd;
    property Rule: TAsn1EncodingRule read FRule;
  end;

procedure TOctetReader.Init(const AData: TBytes; ARule: TAsn1EncodingRule);
begin
  { Positions are Integer, so a buffer past High(Integer) is refused before
    its length is narrowed rather than read through a wrapped end. }
  if Int64(Length(AData)) > Int64(High(Integer)) then
    raise EAsn1InputError.CreateFmt('A document of %d octets. This library ' +
      'reads documents up to %d octets.', [Int64(Length(AData)), High(Integer)]);
  FData := AData;
  FPos := 0;
  FEnd := Integer(Length(AData));
  FRule := ARule;
  FDepth := 0;
end;

procedure TOctetReader.Need(ACount: Integer);
begin
  { A subtraction, not an addition: FPos + ACount can overflow on a length
    the document claims but does not have, and the overflow would make the
    check pass. }
  if (ACount < 0) or (ACount > FEnd - FPos) then
    FailAt(FPos,
      Format('This value claims %d more octets and only %d remain. Either ' +
        'the data is truncated or a length octet was misread.',
        [ACount, FEnd - FPos]));
end;

{ A definite length as the document wrote it, checked at full width BEFORE
  it becomes an Integer: four length octets can say 0xFFFFFFFF, and narrowed
  that is -1. AAt is the length octet, for the message. }
function TOctetReader.CheckedLength(AValue: UInt64; AAt: Integer): Integer;
begin
  if AValue > UInt64(High(Integer)) then
    FailAt(AAt, Format('A definite length of %s octets, past the %d this ' +
      'library addresses.', [UIntToStr(AValue), High(Integer)]));
  if AValue > UInt64(FEnd - FPos) then
    FailAt(AAt, Format('This value claims %s more octets and only %d ' +
      'remain. Either the data is truncated or a length octet was misread.',
      [UIntToStr(AValue), FEnd - FPos]));
  Result := Integer(AValue);
end;

function TOctetReader.AtEnd: Boolean;
begin
  Result := FPos >= FEnd;
end;

function TOctetReader.GetByte: Byte;
begin
  Need(1);
  Result := FData[FPos];
  Inc(FPos);
end;

function TOctetReader.Peek: Byte;
begin
  Need(1);
  Result := FData[FPos];
end;

function TOctetReader.GetRaw(ACount: Integer): TBytes;
begin
  Need(ACount);
  SetLength(Result, ACount);
  if ACount > 0 then Move(FData[FPos], Result[0], ACount);
  Inc(FPos, ACount);
end;

function DecodeIntegerContent(const AContent: TBytes;
  APos: Integer): TAsn1BigInt;
begin
  if Length(AContent) = 0 then
    FailAt(APos,
      'An INTEGER with no content octets. Zero is one octet, 0x00.');
  { X.690 clause 8.3.2: the first nine bits may not all be ones and may not
    all be zeros - which is the rule that makes the shortest form the only
    form, and a decoder that skips it accepts two encodings of one number. }
  if Length(AContent) > 1 then
    if ((AContent[0] = $00) and ((AContent[1] and $80) = 0)) or
       ((AContent[0] = $FF) and ((AContent[1] and $80) <> 0)) then
      FailAt(APos,
        'An INTEGER whose first nine bits are all the same. X.690 forbids ' +
        'the padding octet, so this is not the shortest encoding of the ' +
        'value and no conforming encoder produced it.');
  Result := TAsn1BigInt.FromTwosComplement(AContent);
end;

function DecodeOidContent(const AContent: TBytes; ARelative: Boolean;
  APos: Integer): TAsn1Oid;
var
  Arcs: TArray<Int64>;
  Value: UInt64;
  I: Integer;
  Started: Boolean;
begin
  SetLength(Arcs, 0);
  Value := 0;
  Started := False;
  for I := 0 to Integer(High(AContent)) do
  begin
    if (not Started) and (AContent[I] = $80) then
      FailAt(APos,
        'An object identifier arc with a leading 0x80. The base-128 ' +
        'encoding has no padding, so this is not the shortest form.');
    Started := True;
    { An arc is unbounded in X.660, and this accumulator is not. Rather than
      wrap it silently - which would produce a valid-looking OID that is a
      different OID - the overflow is named. }
    if Value > (High(UInt64) shr 7) then
      FailAt(APos, 'An object identifier arc wider than 64 bits. This ' +
        'library reads arcs up to that size.');
    Value := (Value shl 7) or (AContent[I] and $7F);
    if (AContent[I] and $80) = 0 then
    begin
      if (not ARelative) and (Length(Arcs) = 0) then
      begin
        { X.690 clause 8.19.4 again, unpacked: the first subidentifier is
          40 * the first arc + the second. }
        if Value < 40 then Arcs := Arcs + [Int64(0), Int64(Value)]
        else if Value < 80 then Arcs := Arcs + [Int64(1), Int64(Value - 40)]
        else Arcs := Arcs + [Int64(2), Int64(Value - 80)];
      end
      else
        Arcs := Arcs + [Int64(Value)];
      Value := 0;
      Started := False;
    end;
  end;
  if Started then
    FailAt(APos,
      'An object identifier that ends in the middle of an arc.');
  Result := TAsn1Oid.FromArcs(Arcs);
end;

function DecodeStringContent(AKind: TAsn1Kind; const AContent: TBytes): string;
var
  I: Integer;
  Code: Cardinal;
begin
  case AKind of
    TAsn1Kind.Utf8String, TAsn1Kind.GeneralString:
      Exit(Utf8BytesToString(AContent));
    TAsn1Kind.BmpString:
      begin
        Result := '';
        I := 0;
        while I + 1 <= High(AContent) do
        begin
          Result := Result + Char((Cardinal(AContent[I]) shl 8) or
            AContent[I + 1]);
          Inc(I, 2);
        end;
        Exit;
      end;
    TAsn1Kind.UniversalString:
      begin
        Result := '';
        I := 0;
        while I + 3 <= High(AContent) do
        begin
          Code := (Cardinal(AContent[I]) shl 24) or
                  (Cardinal(AContent[I + 1]) shl 16) or
                  (Cardinal(AContent[I + 2]) shl 8) or AContent[I + 3];
          if Code > $FFFF then
          begin
            Dec(Code, $10000);
            Result := Result + Char($D800 or (Code shr 10)) +
              Char($DC00 or (Code and $3FF));
          end
          else
            Result := Result + Char(Code);
          Inc(I, 4);
        end;
        Exit;
      end;
  end;
  Result := '';
  for I := 0 to Integer(High(AContent)) do Result := Result + Char(AContent[I]);
end;

{ Two or four decimal digits of a time's text. Anything else is a malformed
  time - StrToInt raised the RTL's EConvertError for it. }
function TimeDigits(const ABody: string; AFrom, ACount, APos: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := AFrom to AFrom + ACount - 1 do
  begin
    if (I > Length(ABody)) or not CharInSet(ABody[I], ['0'..'9']) then
      FailAt(APos, Format('A time whose text "%s" has something other than ' +
        'a digit where a digit belongs', [ABody]));
    Result := Result * 10 + Ord(ABody[I]) - Ord('0');
  end;
end;

function EncodeTimeParts(Y, M, D, H, N, S, Ms, APos: Integer): TDateTime;
begin
  if not TryEncodeDateTime(Word(Y), Word(M), Word(D), Word(H), Word(N),
    Word(S), Word(Ms), Result) then
    FailAt(APos, Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d is not a moment of ' +
      'any calendar', [Y, M, D, H, N, S]));
end;

function DecodeUtcTime(const AText: string; APos: Integer): TDateTime;
var
  Y, M, D, H, N, S: Integer;
  Body: string;
begin
  Body := AText;
  if (Body = '') or (Body[Length(Body)] <> 'Z') then
    FailAt(APos,
      'A UTCTime without the Z suffix. DER and CER require it, and a time ' +
      'with no zone is a time nobody can place.');
  SetLength(Body, Length(Body) - 1);
  if Length(Body) <> 12 then
    FailAt(APos,
      'A UTCTime that is not YYMMDDhhmmssZ. DER and CER allow no other ' +
      'form.');
  Y := TimeDigits(Body, 1, 2, APos);
  { RFC 5280's window, which is what every X.509 implementation uses:
    50..99 is 1950..1999 and 00..49 is 2000..2049. A two-digit year has no
    other defensible reading. }
  if Y >= 50 then Inc(Y, 1900) else Inc(Y, 2000);
  M := TimeDigits(Body, 3, 2, APos);
  D := TimeDigits(Body, 5, 2, APos);
  H := TimeDigits(Body, 7, 2, APos);
  N := TimeDigits(Body, 9, 2, APos);
  S := TimeDigits(Body, 11, 2, APos);
  Result := EncodeTimeParts(Y, M, D, H, N, S, 0, APos);
end;

function DecodeGeneralizedTime(const AText: string; APos: Integer): TDateTime;
var
  Body, Frac: string;
  Y, M, D, H, N, S, Ms: Integer;
  Dot: Integer;
begin
  Body := AText;
  if (Body = '') or (Body[Length(Body)] <> 'Z') then
    FailAt(APos,
      'A GeneralizedTime without the Z suffix. DER and CER require it.');
  SetLength(Body, Length(Body) - 1);
  Ms := 0;
  Dot := Pos('.', Body);
  if Dot > 0 then
  begin
    Frac := Copy(Body, Dot + 1, MaxInt);
    Body := Copy(Body, 1, Dot - 1);
    if Frac = '' then
      FailAt(APos, 'A GeneralizedTime with a point and no fraction after it');
    { Every digit checked, not only the three kept: StrToIntDef made a
      damaged fraction 0 milliseconds, silently. }
    TimeDigits(Frac, 1, Length(Frac), APos);
    while Length(Frac) < 3 do Frac := Frac + '0';
    Ms := TimeDigits(Frac, 1, 3, APos);
  end;
  if Length(Body) <> 14 then
    FailAt(APos,
      'A GeneralizedTime that is not YYYYMMDDHHMMSS with an optional ' +
      'fraction. DER and CER allow no other form.');
  Y := TimeDigits(Body, 1, 4, APos);
  M := TimeDigits(Body, 5, 2, APos);
  D := TimeDigits(Body, 7, 2, APos);
  H := TimeDigits(Body, 9, 2, APos);
  N := TimeDigits(Body, 11, 2, APos);
  S := TimeDigits(Body, 13, 2, APos);
  Result := EncodeTimeParts(Y, M, D, H, N, S, Ms, APos);
end;

function TOctetReader.ReadValue: TAsn1Value;
var
  First: Byte;
  TagClass: TAsn1TagClass;
  Constructed, Indefinite: Boolean;
  TagNumber: UInt64;
  Length_: Integer;
  Length64: UInt64;
  B: Byte;
  Count, I: Integer;
  Content: TBytes;
  Kind: TAsn1Kind;
  Start, SavedEnd: Integer;
  Child: TAsn1Value;
  Gathered: TBytes;
  Tagged: TAsn1Value;
  Unused: Byte;
  Fragments, LastOctets, LastAt: Integer;

  { One fragment of a constructed string, appended to Gathered. CER
    (X.690 9.2) allows exactly one shape: primitive fragments - OCTET
    STRINGs, or BIT STRINGs for a BIT STRING, since a character string is
    an IMPLICIT OCTET STRING underneath - every one but the last holding
    1000 content octets, and only the last with unused bits. }
  procedure TakeFragment;
  var
    At, Octets: Integer;
    Piece: TAsn1Value;
    Expected: TAsn1Kind;
  begin
    At := FPos;
    Piece := ReadValue;
    try
      if FRule = TAsn1EncodingRule.Cer then
      begin
        if Kind = TAsn1Kind.BitString then Expected := TAsn1Kind.BitString
        else Expected := TAsn1Kind.OctetString;
        if Piece.IsConstructed or (Piece.Kind <> Expected) then
          FailCanonical(FRule, Format('a %s fragment of a constructed %s. ' +
            'CER fragments are primitive %ss', [Piece.Describe,
            Asn1KindName(Kind), Asn1KindName(Expected)]), At);
        if (Fragments > 0) and (LastOctets <> CerSegmentSize) then
          FailCanonical(FRule, Format('a string fragment of %d content ' +
            'octets that is not the last. CER fills every fragment but the ' +
            'last to exactly %d', [LastOctets, CerSegmentSize]), LastAt);
        if (Fragments > 0) and (Unused <> 0) then
          FailCanonical(FRule, Format('a BIT STRING fragment with %d unused ' +
            'bits that is not the last. Only the last fragment may have ' +
            'unused bits', [Unused]), LastAt);
      end;
      Octets := Integer(Length(Piece.AsBytes));
      if Kind = TAsn1Kind.BitString then Inc(Octets);
      Gathered := Gathered + Piece.AsBytes;
      Unused := Piece.UnusedBits;
      Inc(Fragments);
      LastOctets := Octets;
      LastAt := At;
    finally
      Piece.Free;
    end;
  end;

begin
  Start := FPos;
  Inc(FDepth);
  try
    if FDepth > 256 then
      FailAt(FPos,
        'This document nests more than 256 levels deep. A document that ' +
        'deep is far more often a generated attack than a design.');

    First := GetByte;
    case First and $C0 of
      $00: TagClass := TAsn1TagClass.Universal;
      $40: TagClass := TAsn1TagClass.Application;
      $80: TagClass := TAsn1TagClass.ContextSpecific;
    else
      TagClass := TAsn1TagClass.Private;
    end;
    Constructed := (First and $20) <> 0;
    TagNumber := First and $1F;
    if TagNumber = $1F then
    begin
      TagNumber := 0;
      repeat
        B := GetByte;
        { Past 64 bits the shift would wrap, and 2^64 + 1 would come back as
          tag 1 - BOOLEAN. Named instead. }
        if TagNumber > (High(UInt64) shr 7) then
          FailAt(FPos - 1, 'A tag number wider than 64 bits. This library ' +
            'reads tag numbers up to that size.');
        TagNumber := (TagNumber shl 7) or (B and $7F);
      until (B and $80) = 0;
    end;

    { The length octets. }
    B := GetByte;
    Indefinite := B = $80;
    Length_ := 0;
    if Indefinite then
    begin
      if FRule <> TAsn1EncodingRule.Ber then
        { CER uses indefinite lengths too, but only where it CHOOSES to, and
          a CER decoder still has to accept them; DER never does. }
        if FRule = TAsn1EncodingRule.Der then
          FailCanonical(FRule,
            'an indefinite length. DER has exactly one encoding of any ' +
            'value and a definite length is part of it, so these octets ' +
            'are not DER whatever else they are', FPos - 1);
      if not Constructed then
        FailAt(FPos - 1,
          'An indefinite length on a PRIMITIVE value. There is no ' +
          'end-of-contents marker to look for inside one.');
    end
    else if (B and $80) = 0 then
      Length_ := B
    else
    begin
      Count := B and $7F;
      if Count = $7F then
        FailAt(FPos - 1,
          'The reserved length octet 0xFF.');
      if Count > 4 then
        FailAt(FPos - 1,
          'A length of more than four octets, which is more data than this ' +
          'library will address.');
      Length64 := 0;
      for I := 1 to Count do Length64 := (Length64 shl 8) or GetByte;
      Length_ := CheckedLength(Length64, FPos - Count - 1);
      if (FRule <> TAsn1EncodingRule.Ber) and (Length_ < 128) then
        FailCanonical(FRule,
          Format('a long-form length octet for the value %d, which fits ' +
            'the short form', [Length_]), FPos - 1);
    end;

    { CER (X.690 9.1): EVERY constructed encoding - a SEQUENCE, a SET, a
      segmented string, an explicit tag, an uninterpreted constructed tag -
      takes the indefinite length. }
    if (FRule = TAsn1EncodingRule.Cer) and Constructed and not Indefinite then
      FailCanonical(FRule,
        'a constructed value with a definite length. CER writes every ' +
        'constructed encoding with an indefinite length', Start);

    Kind := TAsn1Kind.Unknown;
    if TagClass = TAsn1TagClass.Universal then
      Kind := KindOfUniversalTag(TagNumber, Constructed);

    { A constructed value: read its children until the length runs out, or
      until the end-of-contents marker for an indefinite one. }
    if Constructed then
    begin
      if TagClass <> TAsn1TagClass.Universal then
      begin
        { A context-specific or application constructed value is a TAG, and
          what is inside it is the value it tags. }
        Result := TAsn1Value.NewRaw(TagClass, TagNumber, True, nil);
        try
          if Indefinite then
          begin
            while True do
            begin
              if (Peek = 0) and (FPos + 1 < FEnd) and (FData[FPos + 1] = 0) then
              begin
                GetByte;
                GetByte;
                Break;
              end;
              Result.Add(ReadValue);
            end;
          end
          else
          begin
            Need(Length_);
            SavedEnd := FEnd;
            FEnd := FPos + Length_;
            try
              while not AtEnd do Result.Add(ReadValue);
            finally
              FEnd := SavedEnd;
            end;
          end;
        except
          Result.Free;
          raise;
        end;
        Result.UseIndefiniteLength := Indefinite;
        { A constructed context, application or private tag holding exactly
          ONE value is an EXPLICIT tag, and saying so is what lets the
          contract and the schema unwrap it. One holding several is an
          IMPLICIT tag on a constructed type - a SEQUENCE whose own tag was
          replaced - and there is nothing to unwrap, so it keeps the raw
          form and the schema decides what it was. }
        if Result.Count = 1 then
        begin
          Child := Result.Extract(0);
          try
            Tagged := TAsn1Value.NewExplicit(TagClass, TagNumber, Child);
          except
            Child.Free;
            raise;
          end;
          Tagged.UseIndefiniteLength := Indefinite;
          Result.Free;
          Result := Tagged;
        end;
        Exit;
      end;

      { X.690 8.2-8.20: BOOLEAN, INTEGER, ENUMERATED, REAL, NULL, OBJECT
        IDENTIFIER and RELATIVE-OID are primitive in EVERY rule, BER
        included. Constructed, they are not ASN.1 - and read as children
        they would come back as a SEQUENCE, a different value. }
      if Kind in [TAsn1Kind.BooleanValue, TAsn1Kind.IntegerValue,
        TAsn1Kind.Enumerated, TAsn1Kind.RealValue, TAsn1Kind.NullValue,
        TAsn1Kind.Oid, TAsn1Kind.RelativeOid] then
        FailAt(Start, Format('A constructed %s. X.690 requires the ' +
          'primitive form for this type under every encoding rule, BER ' +
          'included.', [Asn1KindName(Kind)]));

      { A constructed STRING is BER's segmented form: the pieces are the
        value. DER and CER forbid it for a string, and CER only for one
        under 1000 octets. UTCTime and GeneralizedTime are VisibleStrings
        underneath (X.680 46-47), so BER segments them the same way. }
      if IsStringKind(Kind) or (Kind = TAsn1Kind.OctetString) or
         (Kind = TAsn1Kind.BitString) or (Kind = TAsn1Kind.UtcTime) or
         (Kind = TAsn1Kind.GeneralizedTime) then
      begin
        if FRule = TAsn1EncodingRule.Der then
          FailCanonical(FRule,
            'a constructed string. DER requires the primitive form, so ' +
            'these octets are not DER', Start);
        SetLength(Gathered, 0);
        Unused := 0;
        Fragments := 0;
        LastOctets := 0;
        LastAt := Start;
        if Indefinite then
        begin
          while True do
          begin
            if (Peek = 0) and (FPos + 1 < FEnd) and (FData[FPos + 1] = 0) then
            begin
              GetByte;
              GetByte;
              Break;
            end;
            TakeFragment;
          end;
        end
        else
        begin
          Need(Length_);
          SavedEnd := FEnd;
          FEnd := FPos + Length_;
          try
            while not AtEnd do TakeFragment;
          finally
            FEnd := SavedEnd;
          end;
        end;
        { CER (X.690 9.2): a string of 1000 content octets or fewer is
          primitive, so a constructed one must be longer. }
        if FRule = TAsn1EncodingRule.Cer then
        begin
          LastOctets := Integer(Length(Gathered));
          if Kind = TAsn1Kind.BitString then Inc(LastOctets);
          if LastOctets <= CerSegmentSize then
            FailCanonical(FRule, Format('a constructed string of %d content ' +
              'octets. CER keeps a string of %d or fewer primitive',
              [LastOctets, CerSegmentSize]), Start);
        end;
        if Kind = TAsn1Kind.BitString then
          Result := TAsn1Value.NewBitString(Gathered, Unused)
        else if Kind = TAsn1Kind.OctetString then
          Result := TAsn1Value.NewOctetString(Gathered)
        else if Kind = TAsn1Kind.UtcTime then
          Result := TAsn1Value.NewUtcTime(DecodeUtcTime(
            DecodeStringContent(TAsn1Kind.Ia5String, Gathered), Start))
        else if Kind = TAsn1Kind.GeneralizedTime then
          Result := TAsn1Value.NewGeneralizedTime(DecodeGeneralizedTime(
            DecodeStringContent(TAsn1Kind.Ia5String, Gathered), Start))
        else
          Result := TAsn1Value.NewString(Kind,
            DecodeStringContent(Kind, Gathered));
        Result.UseIndefiniteLength := Indefinite;
        Exit;
      end;

      { A constructed universal tag this library does not interpret keeps
        its own tag number, as a primitive one does: read as a SEQUENCE it
        would be re-written as 0x30, a different document. }
      if Kind = TAsn1Kind.SetValue then Result := TAsn1Value.NewSet
      else if Kind = TAsn1Kind.Unknown then
        Result := TAsn1Value.NewRaw(TagClass, TagNumber, True, nil)
      else Result := TAsn1Value.NewSequence;
      try
        if Indefinite then
        begin
          while True do
          begin
            if (Peek = 0) and (FPos + 1 < FEnd) and (FData[FPos + 1] = 0) then
            begin
              GetByte;
              GetByte;
              Break;
            end;
            Result.Add(ReadValue);
          end;
        end
        else
        begin
          Need(Length_);
          SavedEnd := FEnd;
          FEnd := FPos + Length_;
          try
            while not AtEnd do Result.Add(ReadValue);
          finally
            FEnd := SavedEnd;
          end;
        end;
      except
        Result.Free;
        raise;
      end;
      Result.UseIndefiniteLength := Indefinite;
      Exit;
    end;

    { Primitive. }
    Content := GetRaw(Length_);

    if TagClass <> TAsn1TagClass.Universal then
      Exit(TAsn1Value.NewRaw(TagClass, TagNumber, False, Content));

    { CER (X.690 9.2): a string past 1000 content octets is constructed. }
    if (FRule = TAsn1EncodingRule.Cer) and
       (Length(Content) > CerSegmentSize) and
       (IsStringKind(Kind) or (Kind in [TAsn1Kind.OctetString,
        TAsn1Kind.BitString, TAsn1Kind.UtcTime, TAsn1Kind.GeneralizedTime])) then
      FailCanonical(FRule, Format('a primitive %s of %d content octets. CER ' +
        'segments a string past %d octets', [Asn1KindName(Kind),
        Length(Content), CerSegmentSize]), Start);

    case Kind of
      TAsn1Kind.BooleanValue:
        begin
          if Length(Content) <> 1 then
            FailAt(Start,
              'A BOOLEAN whose content is not exactly one octet.');
          if (FRule <> TAsn1EncodingRule.Ber) and
             not (Content[0] in [$00, $FF]) then
            FailCanonical(FRule,
              Format('a BOOLEAN encoded as 0x%.2X. DER and CER say TRUE is ' +
                '0xFF and nothing else, so these octets are not canonical ' +
                'even though every decoder reads them as true',
                [Content[0]]), Start);
          Exit(TAsn1Value.NewBoolean(Content[0] <> 0));
        end;

      TAsn1Kind.IntegerValue:
        Exit(TAsn1Value.NewInteger(DecodeIntegerContent(Content, Start)));

      { Checked: the RTL's string helper raised EConvertError for an
        ENUMERATED past Int64, which no enumeration has. }
      TAsn1Kind.Enumerated:
        begin
          var Big := DecodeIntegerContent(Content, Start);
          var E64: Int64;
          if not Big.TryToInt64(E64) then
            FailAt(Start, Format('An ENUMERATED of %s, which no enumeration ' +
              'has', [Big.ToText]));
          Exit(TAsn1Value.NewEnumerated(E64));
        end;

      TAsn1Kind.RealValue:
        Exit(TAsn1Value.NewReal(DecodeRealContent(Content,
          procedure(AWhy: string)
          begin
            FailAt(Start, AWhy);
          end)));

      TAsn1Kind.BitString:
        begin
          if Length(Content) = 0 then
            FailAt(Start,
              'A BIT STRING with no content. The first octet is the number ' +
              'of unused bits and is never absent.');
          if Content[0] > 7 then
            FailAt(Start,
              Format('A BIT STRING claiming %d unused bits. An octet has ' +
                'eight, so at most seven can be unused.', [Content[0]]));
          Exit(TAsn1Value.NewBitString(Copy(Content, 1, Length(Content) - 1),
            Content[0]));
        end;

      TAsn1Kind.OctetString: Exit(TAsn1Value.NewOctetString(Content));

      TAsn1Kind.NullValue:
        begin
          if Length(Content) <> 0 then
            FailAt(Start,
              'A NULL with content octets. NULL has none, ever.');
          Exit(TAsn1Value.NewNull);
        end;

      TAsn1Kind.Oid:
        Exit(TAsn1Value.NewOid(DecodeOidContent(Content, False, Start)));

      TAsn1Kind.RelativeOid:
        Exit(TAsn1Value.NewRelativeOid(
          DecodeOidContent(Content, True, Start)));

      TAsn1Kind.UtcTime:
        Exit(TAsn1Value.NewUtcTime(DecodeUtcTime(
          DecodeStringContent(TAsn1Kind.Ia5String, Content), Start)));

      TAsn1Kind.GeneralizedTime:
        Exit(TAsn1Value.NewGeneralizedTime(DecodeGeneralizedTime(
          DecodeStringContent(TAsn1Kind.Ia5String, Content), Start)));
    end;

    if IsStringKind(Kind) then
      Exit(TAsn1Value.NewString(Kind, DecodeStringContent(Kind, Content)));

    { A universal tag this library does not interpret keeps its octets, so
      that a document containing one still round-trips. }
    Result := TAsn1Value.NewRaw(TagClass, TagNumber, False, Content);
  finally
    Dec(FDepth);
  end;
end;

{ ===========================================================================
  TAsn1Codec
  =========================================================================== }

class function TAsn1Codec.Encode(AValue: TAsn1Value;
  ARule: TAsn1EncodingRule): TBytes;
begin
  Result := EncodeValue(AValue, ARule);
end;

class function TAsn1Codec.Decode(const AData: TBytes;
  ARule: TAsn1EncodingRule): TAsn1Value;
var
  R: TOctetReader;
begin
  R.Init(AData, ARule);
  Result := R.ReadValue;
  try
    if not R.AtEnd then
      FailAt(R.Position,
        'Octets after the end of the value. A TLV document is one value; ' +
        'a buffer holding several is a stream, and reading it as one ' +
        'value would silently ignore the rest.');
  except
    Result.Free;
    raise;
  end;
end;


{ ===========================================================================
  THE DELPHI CONTRACT

  A record or a class is a SEQUENCE and its members are the components, in
  declaration order - because ASN.1 puts nothing between them and order is
  the only thing that says which is which.

  The attributes are where the parts a Delphi type cannot express are said:
  which context tag a member carries, whether it is OPTIONAL, which of the
  string types a string is, and which member of a CHOICE is present.
  =========================================================================== }

function MemberIgnored(AMember: TRttiMember): Boolean;
var
  Attr: TCustomAttribute;
begin
  Result := False;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is Asn1IgnoreAttribute then Exit(True);
end;

function MemberTag(AMember: TRttiMember; out ATagClass: TAsn1TagClass;
  out ANumber: Integer): Boolean;
var
  Attr: TCustomAttribute;
begin
  ATagClass := TAsn1TagClass.ContextSpecific;
  ANumber := 0;
  Result := False;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is Asn1TagAttribute then
    begin
      ATagClass := Asn1TagAttribute(Attr).TagClass;
      ANumber := Asn1TagAttribute(Attr).Number;
      Exit(True);
    end;
end;

{ EXPLICIT unless the member says IMPLICIT. X.680's own default for a module
  with no tag-default clause is EXPLICIT, and explicit tagging is the one
  that never loses the inner tag - so it is what a member gets when nobody
  said otherwise. }
function MemberTagIsImplicit(AMember: TRttiMember): Boolean;
var
  Attr: TCustomAttribute;
begin
  Result := False;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is Asn1ImplicitAttribute then Exit(True);
end;

function MemberOptional(AMember: TRttiMember): Boolean;
var
  Attr: TCustomAttribute;
begin
  Result := False;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is Asn1OptionalAttribute then Exit(True);
end;

{ The custom serializer named on THIS member, which beats any registration
  for the member's type. nil when there is none. }
function MemberSerializerOf(AMember: TRttiMember): TAsn1ValueSerializerClass;
var
  Attr: TCustomAttribute;
begin
  Result := nil;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is Asn1SerializerAttribute then
      Exit(Asn1SerializerAttribute(Attr).SerializerClass);
end;

function MemberChoiceSelector(AMember: TRttiMember): string;
var
  Attr: TCustomAttribute;
begin
  Result := '';
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is Asn1ChoiceAttribute then
      Exit(Asn1ChoiceAttribute(Attr).SelectorField);
end;

function MemberStringKind(AMember: TRttiMember): TAsn1Kind;
var
  Attr: TCustomAttribute;
begin
  { UTF8String unless the member says otherwise. It is the only universal
    string type that can hold anything a Delphi string can, so it is the one
    that never silently loses a character. }
  Result := TAsn1Kind.Utf8String;
  if AMember = nil then Exit;
  for Attr in AMember.GetAttributes do
    if Attr is Asn1StringTypeAttribute then
      Exit(Asn1StringTypeAttribute(Attr).Kind);
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

{ What a member already holds, for the reader to fill in place, as every
  other format does: its object, or its record. Passing nothing made the
  reader construct a second object and store it over the first, which
  nothing then referred to - the child list a constructor makes is the
  everyday case, and it leaked on every read. A record is merged the same
  way, because a record can hold objects too: read from a zeroed one, every
  object a constructor had put in it was replaced and orphaned, and every
  member the document omits was reset. An array is replaced, not merged, so
  it gets nothing. }
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

function ElementTypeOf(AType: TRttiType): TRttiType;
begin
  Result := nil;
  if (AType = nil) or (AType.TypeKind <> tkDynArray) then Exit;
  if GetTypeData(AType.Handle).DynArrElType = nil then Exit;
  Result := GCtx.GetType(GetTypeData(AType.Handle).DynArrElType^);
end;

{ A list, seen through RTTI: a one-argument Add, a ToArray, and a
  parameterless constructor. The same test the other engines use, so the same
  Delphi types are recognised everywhere.

  Without it a TObjectList is a class like any other, and the SEQUENCE walk
  describes its private layout - its notify events, its comparer - instead of
  its elements. }
function ListMethodsOf(AType: TRttiType; out AAdd, AToArray, ACreate: TRttiMethod;
  out AItem: TRttiType): Boolean;
var
  Access: TListAccess;
begin
  { CORE ANSWERS THIS: recognition is by ancestry, once, in
    TSerializationTypes - never by probing the method list, which recognises
    a class that merely looks like a list and can miss a real one. }
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

{ A dictionary, seen through RTTI: a two-argument AddOrSetValue and a ToArray
  that yields key/value pairs.

  X.680 has no map type, so a dictionary is a SEQUENCE OF two-component
  SEQUENCEs - which is what every .asn1 module that needs one writes by hand.
  Without this test a TDictionary is a class like any other and the SEQUENCE
  walk describes its private layout. }
function DictionaryMethodsOf(AType: TRttiType;
  out AAddOrSet, AToArray, ACreate: TRttiMethod;
  out AKey, AValue: TRttiType): Boolean;
var
  Access: TDictionaryAccess;
begin
  { Core answers this; see the note on ListMethodsOf above. }
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

{ What an error calls a member: its name when there is one, and otherwise
  the type, which is all an array element or a root has. }
function MemberLabel(AMember: TRttiMember; AType: TRttiType): string;
begin
  if AMember <> nil then Exit(AMember.Name);
  if AType <> nil then Exit(AType.Name);
  Result := 'a value';
end;

function ValueToAsn1(AType: TRttiType; const AValue: TValue;
  AMember: TRttiMember; const APath: string): TAsn1Value; forward;

{ Whether a member can be written at all, asked from its TYPE before its
  getter is called - a member with no RTTI type raised EInsufficientRtti
  from the getter before anything had looked at it. }
procedure RefuseUnwritableMember(AMember: TRttiMember; AType: TRttiType;
  const APath: string);
var
  Why: string;
  SerCls: TAsn1ValueSerializerClass;
begin
  if MemberSerializerOf(AMember) <> nil then Exit;
  if AType = nil then
    raise EAsn1Error.CreateFmt(
      'At %s: %s %s. Leave it out with [Asn1Ignore], or register an ASN.1 ' +
      'type serializer for the type that holds it.',
      [APath, AMember.Name, TSerializationTypes.UnsupportedReason(nil)]);
  if TAsn1Engine.TryGetTypeSerializer(AType.Handle, SerCls) then Exit;
  Why := TSerializationTypes.UnsupportedReason(AType.Handle);
  if Why <> '' then
    raise EAsn1Error.CreateFmt(
      'At %s: %s %s. Leave it out with [Asn1Ignore], or register an ASN.1 ' +
      'type serializer for its type.', [APath, AMember.Name, Why]);
end;

{ A CHOICE, which is a real thing and not a record with nullable fields.

  X.680's CHOICE is exactly one alternative, and the encoding carries the
  one that is present and nothing about the others. A Delphi record cannot
  say that on its own, so the selector field does: it names which of the
  siblings is the alternative in force, and only that one is written. }
function ChoiceToAsn1(AType: TRttiType; const AValue: TValue;
  const ASelector, APath: string): TAsn1Value;
var
  Members: TArray<TRttiMember>;
  M, Sel: TRttiMember;
  Which: string;
  Index, I: Integer;
  TagClass: TAsn1TagClass;
  Number: Integer;
  Inner: TAsn1Value;
begin
  Members := MembersOf(AType);
  Sel := nil;
  for M in Members do
    if SameText(M.Name, ASelector) then
    begin
      Sel := M;
      Break;
    end;
  if Sel = nil then
    raise EAsn1InternalError.CreateFmt(
      'At %s: [Asn1Choice] names the selector field "%s" and %s has no ' +
      'member of that name. The selector is what says which alternative is ' +
      'present, and without it nothing can be written.',
      [APath, ASelector, AType.Name]);

  { The selector is an enumeration whose ordinal picks the alternative among
    the OTHER members, in declaration order. }
  Which := '';
  Index := Integer(MemberValueOf(Sel, AValue).AsOrdinal);
  I := 0;
  for M in Members do
  begin
    if M = Sel then Continue;
    if I = Index then
    begin
      Which := M.Name;
      { The alternative's own tag if it declared one, and its POSITION
        otherwise - which is what makes the alternatives distinguishable
        without every one of them needing an attribute. MemberTag clears
        its out-parameters before it looks, so the position has to be put
        back when it finds nothing. }
      if not MemberTag(M, TagClass, Number) then
      begin
        TagClass := TAsn1TagClass.ContextSpecific;
        Number := I;
      end;
      Inner := ValueToAsn1(MemberTypeOf(M), MemberValueOf(M, AValue), M,
        APath + '.' + M.Name);
      { A CHOICE alternative carries a context tag so that the decoder can
        tell which one arrived - which is the whole reason X.680 requires
        a CHOICE's alternatives to have distinct tags. }
      if MemberTagIsImplicit(M) then
        Exit(TAsn1Value.NewImplicit(TagClass, UInt64(Number), Inner));
      Exit(TAsn1Value.NewExplicit(TagClass, UInt64(Number), Inner));
    end;
    Inc(I);
  end;
  raise EAsn1InternalError.CreateFmt(
    'At %s: the selector says alternative %d and there are only %d.',
    [APath, Index, I]);
end;

function ValueToAsn1(AType: TRttiType; const AValue: TValue;
  AMember: TRttiMember; const APath: string): TAsn1Value;
var
  Why: string;
  Name_: string;
  Access: TNullableAccess;
  Inner: TValue;
  Members: TArray<TRttiMember>;
  M: TRttiMember;
  I: Integer;
  Child: TAsn1Value;
  TagClass: TAsn1TagClass;
  Number: Integer;
  Selector: string;
  Guid: TGUID;
  MemberValue: TValue;
  SerCls: TAsn1ValueSerializerClass;
  Ser: TCustomAsn1ValueSerializer;
  ListAdd, ListToArray, ListCreate, DictAdd: TRttiMethod;
  ListItem, DictKey, PairElem: TRttiType;
  KeyField, ValueField: TRttiField;
  Elements, Pair: TValue;
  Entry: TAsn1Value;
begin
  if AType = nil then
    raise EAsn1Error.CreateFmt(
      '%s %s. Leave it out with [Asn1Ignore], or register an ASN.1 type ' +
      'serializer for the type that holds it.',
      [MemberLabel(AMember, nil), TSerializationTypes.UnsupportedReason(nil)]);

  { The caller's own mapping, before anything this unit would decide. }
  SerCls := MemberSerializerOf(AMember);
  if SerCls = nil then
    TAsn1Engine.TryGetTypeSerializer(AType.Handle, SerCls);
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
    is asked only after [Asn1Ignore] and every custom serializer have had
    their say, so a caller who wants one of these can always have it. }
  Why := TSerializationTypes.UnsupportedReason(AType.Handle);
  if Why <> '' then
    raise EAsn1Error.CreateFmt(
      '%s %s. Leave it out with [Asn1Ignore], or register an ASN.1 type ' +
      'serializer for its type.', [MemberLabel(AMember, AType), Why]);

  if TSerializationTypes.TryGetNullableAccess(AType.Handle, Access) then
  begin
    if not Access.HasValue(AValue.GetReferenceToRawData) then
      Exit(TAsn1Value.NewNull);
    Inner := Access.GetValue(AValue.GetReferenceToRawData);
    Exit(ValueToAsn1(GCtx.GetType(Access.ValueType), Inner, AMember, APath));
  end;

  if AType.Handle = System.TypeInfo(TGUID) then
  begin
    Guid := AValue.AsType<TGUID>;
    Exit(TAsn1Value.NewOctetString(TBytes.Create(
      Byte(Guid.D1 shr 24), Byte(Guid.D1 shr 16), Byte(Guid.D1 shr 8),
      Byte(Guid.D1),
      Byte(Guid.D2 shr 8), Byte(Guid.D2),
      Byte(Guid.D3 shr 8), Byte(Guid.D3),
      Guid.D4[0], Guid.D4[1], Guid.D4[2], Guid.D4[3],
      Guid.D4[4], Guid.D4[5], Guid.D4[6], Guid.D4[7])));
  end;
  if (AType.Handle = System.TypeInfo(TDateTime)) or
     (AType.Handle = System.TypeInfo(TDate)) or
     (AType.Handle = System.TypeInfo(TTime)) then
  begin
    { Refused by name before anything is written: a GeneralizedTime has four
      digits of year, and the reader refuses a moment outside the years 1 to
      9999 - which is what the writer produced for one, as 0000-00-00. }
    if not TStructuralText.IsDateTimeInRange(AValue.AsType<TDateTime>) then
      raise EAsn1Error.CreateFmt(
        'At %s: the %s %s is outside the years 1 to 9999, which is all a ' +
        'GeneralizedTime can state and all this reader accepts back.',
        [APath, AType.Name,
         FloatToStr(AValue.AsType<TDateTime>, TFormatSettings.Invariant)]);
    { GeneralizedTime rather than UTCTime: UTCTime's two-digit year needs a
      windowing rule to read at all, and a library that writes one is
      writing a value that means something different in 2050. }
    Exit(TAsn1Value.NewGeneralizedTime(AValue.AsType<TDateTime>));
  end;
  if AType.Handle = System.TypeInfo(TBytes) then
    Exit(TAsn1Value.NewOctetString(AValue.AsType<TBytes>));

  case AType.TypeKind of
    tkInteger: Exit(TAsn1Value.NewInteger(AValue.AsOrdinal));
    { An INTEGER has no width, so a UInt64 above High(Int64) is written as
      the positive number it is - nine content octets - where AsInt64 wrote
      it as -1. }
    tkInt64:
      if TSerializationTypes.IsUnsignedInteger(AType.Handle) then
        Exit(TAsn1Value.NewInteger(TAsn1BigInt.FromUInt64(
          UInt64(TSerializationTypes.Int64Bits(AValue)))))
      else
        Exit(TAsn1Value.NewInteger(TSerializationTypes.Int64Bits(AValue)));
    tkChar, tkWChar, tkString, tkLString, tkWString, tkUString:
      Exit(TAsn1Value.NewString(MemberStringKind(AMember), AValue.AsString));
    tkEnumeration:
      begin
        if AType.Handle = System.TypeInfo(Boolean) then
          Exit(TAsn1Value.NewBoolean(AValue.AsBoolean));
        Exit(TAsn1Value.NewEnumerated(AValue.AsOrdinal));
      end;
    tkSet:
      begin
        { SET OF ENUMERATED, which is what X.680 calls "some of these". The
          alternative would be a BIT STRING whose bit positions mean nothing
          without the Delphi declaration; ENUMERATED values are numbers the
          module can name.

          The bits are read from the value's own storage: TValue.AsOrdinal
          raises for a set, and a set wider than four bytes has no ordinal. }
        Result := TAsn1Value.NewSetOf;
        try
          { Through TSerializationTypes: bit 0 is the byte holding the
            lowest member, not ordinal 0. }
          for I in TSerializationTypes.SetOrdinals(AType.Handle, AValue) do
            Result.Add(TAsn1Value.NewEnumerated(I));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
    tkFloat:
      begin
        { A Currency is NOT a floating-point number. Delphi stores it as an
          Int64 of ten-thousandths, and an INTEGER of those units carries it
          exactly - which is the very thing the message below tells a caller
          to do by hand for a Double. Doing it for the one type that already
          IS scaled units costs nothing and loses nothing. }
        if GetTypeData(AType.Handle).FloatType = ftCurr then
          Exit(TAsn1Value.NewInteger(
            PInt64(AValue.GetReferenceToRawData)^));
        { Comp is a 64-bit integer RTTI files under tkFloat: an INTEGER. }
        if TSerializationTypes.IsCompType(AType.Handle) then
          Exit(TAsn1Value.NewInteger(TSerializationTypes.Int64Bits(AValue)));

        { Everything else is a REAL - X.690 clause 8.5, base 2, which
          carries an IEEE double exactly because a double already IS a sign,
          a power of two and an integer mantissa. The infinities, the NaN
          and minus zero each have their own spelling in clause 8.5.9, so
          none of them has to be refused or flattened. }
        Exit(TAsn1Value.NewReal(AValue.AsExtended));
      end;
    { An array is one level of the nesting limit, as an object is: a record
      holding an array of itself nests with no object anywhere, and ran the
      writer out of stack. }
    tkDynArray:
      begin
        TSerializationGraphGuard.EnterLevel;
        try
          Result := TAsn1Value.NewSequenceOf;
          try
            for I := 0 to Integer(AValue.GetArrayLength) - 1 do
              Result.Add(ValueToAsn1(ElementTypeOf(AType),
                AValue.GetArrayElement(I), nil, Format('%s[%d]', [APath, I])));
          except
            Result.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
        Exit;
      end;
    { A static array is a SEQUENCE OF exactly its length, flat in the order
      Delphi stores it. }
    tkArray:
      begin
        TSerializationGraphGuard.EnterLevel;
        try
          Result := TAsn1Value.NewSequenceOf;
          try
            for I := 0 to Integer(AValue.GetArrayLength) - 1 do
              Result.Add(ValueToAsn1(TRttiArrayType(AType).ElementType,
                AValue.GetArrayElement(I), nil, Format('%s[%d]', [APath, I])));
          except
            Result.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
        Exit;
      end;
    tkRecord, tkMRecord, tkClass:
      begin
        if (AType.TypeKind = tkClass) and
           ((not AValue.IsObject) or (AValue.AsObject = nil)) then
          Exit(TAsn1Value.NewNull);

        { ONE LEVEL of the nesting limit for each of these. Enter counts an
          object - a list or a map included, which also makes a container
          that holds itself a cycle rather than a stack overflow - and
          EnterLevel counts a record, a CHOICE among them. }
        if AType.TypeKind = tkClass then
        begin
          if not TSerializationGraphGuard.Enter(AValue.AsObject) then
            raise EAsn1Error.CreateFmt(
              'At %s: %s is already being written further up the graph: it ' +
              'is a cycle, and ASN.1 has no back-reference. Break the cycle, ' +
              'or register an ASN.1 type serializer that writes a key instead.',
              [APath, AValue.AsObject.ClassName]);
        end
        else
          TSerializationGraphGuard.EnterLevel;
        try
        { A MAP IS A SEQUENCE OF TWO-COMPONENT SEQUENCEs. X.680 has no map,
          and this is what a module that needs one declares. Tested before
          the list, because a dictionary has a ToArray too. }
        if (AType.TypeKind = tkClass) and
           DictionaryMethodsOf(AType, DictAdd, ListToArray, ListCreate,
             DictKey, ListItem) then
        begin
          Result := TAsn1Value.NewSequenceOf;
          try
            Elements := ListToArray.Invoke(AValue.AsObject, []);
            PairElem := TRttiDynamicArrayType(
              GCtx.GetType(Elements.TypeInfo)).ElementType;
            KeyField := PairElem.GetField('Key');
            ValueField := PairElem.GetField('Value');
            if (KeyField = nil) or (ValueField = nil) then
              raise EAsn1InternalError.CreateFmt(
                'At %s: %s looks like a map but its ToArray does not yield ' +
                'Key/Value pairs.', [APath, AType.Name]);
            for I := 0 to Integer(Elements.GetArrayLength) - 1 do
            begin
              Pair := Elements.GetArrayElement(I);
              Entry := TAsn1Value.NewSequence;
              try
                Entry.Add(ValueToAsn1(DictKey,
                  KeyField.GetValue(Pair.GetReferenceToRawData), nil,
                  Format('%s{%d}.key', [APath, I])));
                Entry.Add(ValueToAsn1(ListItem,
                  ValueField.GetValue(Pair.GetReferenceToRawData), nil,
                  Format('%s{%d}.value', [APath, I])));
              except
                Entry.Free;
                raise;
              end;
              Result.Add(Entry);
            end;
          except
            Result.Free;
            raise;
          end;
          Exit;
        end;

        { A LIST IS A SEQUENCE OF ITS ELEMENTS, not a SEQUENCE of the
          container's own members. Without this test a TObjectList is a class
          like any other and the walk below describes its private layout -
          its notify events, its comparer - and then refuses one of them by
          name, which tells the caller nothing useful at all. }
        if (AType.TypeKind = tkClass) and
           ListMethodsOf(AType, ListAdd, ListToArray, ListCreate, ListItem) then
        begin
          Result := TAsn1Value.NewSequenceOf;
          try
            Elements := TSerializationTypes.ListElements(AValue.AsObject,
              ListToArray);
            for I := 0 to Integer(Elements.GetArrayLength) - 1 do
              Result.Add(ValueToAsn1(ListItem, Elements.GetArrayElement(I),
                nil, Format('%s[%d]', [APath, I])));
          except
            Result.Free;
            raise;
          end;
          Exit;
        end;

        Selector := MemberChoiceSelector(AMember);
        if Selector <> '' then Exit(ChoiceToAsn1(AType, AValue, Selector, APath));

        { A class ASN.1 writes must be one it can read back: there is no
          factory to build it another way, so a class with no parameterless
          constructor - Exception, TComponent - is refused here rather than
          written and then unreadable. }
        if (AType.TypeKind = tkClass) and
           (TSerializationTypes.DefaultConstructor(AType) = nil) then
          raise EAsn1Error.CreateFmt(
            'At %s: %s has no parameterless constructor, so ASN.1 could ' +
            'write it but never read it back. Register an ASN.1 type ' +
            'serializer for it, or carry the values in a class that has one.',
            [APath, AType.Name]);
        Result := TAsn1Value.NewSequence;
        try
          Members := MembersOf(AType);
          for M in Members do
          begin
            RefuseUnwritableMember(M, MemberTypeOf(M), APath + '.' + M.Name);
            { An OPTIONAL member with no value is ABSENT - not null. That
              distinction is the whole reason OPTIONAL exists, and writing a
              NULL in its place would be a different document. }
            { An OPTIONAL member with no value is ABSENT - not null. That
              distinction is the whole reason OPTIONAL exists, and writing a
              NULL in its place would be a different document.

              The member's value is held in a LOCAL first: taking the
              address of a function result works on one platform and reads a
              temporary that has already gone on the other, which is exactly
              the kind of defect that passes Win32 and fails Win64. }
            MemberValue := MemberValueOf(M, AValue);
            if MemberOptional(M) and
               TSerializationTypes.TryGetNullableAccess(
                 MemberTypeOf(M).Handle, Access) and
               (not Access.HasValue(MemberValue.GetReferenceToRawData)) then
              Continue;

            Child := ValueToAsn1(MemberTypeOf(M), MemberValue, M,
              APath + '.' + M.Name);
            { [SerializationName] names the component; ASN.1 has no name
              attribute of its own. }
            if not TSerializationMetadata.GeneralName(M, Name_) then
              Name_ := M.Name;
            Child.Name := Name_;
            if MemberTag(M, TagClass, Number) then
            begin
              if MemberTagIsImplicit(M) then
                Child := TAsn1Value.NewImplicit(TagClass, UInt64(Number), Child)
              else
                Child := TAsn1Value.NewExplicit(TagClass, UInt64(Number), Child);
            end;
            Result.Add(Child);
          end;
        except
          Result.Free;
          raise;
        end;
        finally
          if AType.TypeKind = tkClass then
            TSerializationGraphGuard.Leave(AValue.AsObject)
          else
            TSerializationGraphGuard.LeaveLevel;
        end;
        Exit;
      end;
  end;

  raise EAsn1InternalError.CreateFmt(
    'At %s: ASN.1 has no type here for %s.', [APath, AType.Name]);
end;

{ The value inside a tag, whichever way it was tagged. }
function Untagged(AValue: TAsn1Value): TAsn1Value;
begin
  Result := AValue;
  while (Result <> nil) and (Result.Kind = TAsn1Kind.Tagged) and
        (Result.Count = 1) do
    Result := Result.Items[0];
end;

{ The universal tag the octets of a member WOULD have carried, had the
  member not been implicitly tagged. }
function UniversalTagForType(AType: TRttiType;
  AMember: TRttiMember): Integer;
var
  Access: TNullableAccess;
begin
  Result := -1;
  if AType = nil then Exit;
  if TSerializationTypes.TryGetNullableAccess(AType.Handle, Access) then
    Exit(UniversalTagForType(GCtx.GetType(Access.ValueType), AMember));
  if AType.Handle = System.TypeInfo(TGUID) then Exit(TagOctetString);
  if (AType.Handle = System.TypeInfo(TDateTime)) or
     (AType.Handle = System.TypeInfo(TDate)) or
     (AType.Handle = System.TypeInfo(TTime)) then Exit(TagGeneralizedTime);
  if AType.Handle = System.TypeInfo(TBytes) then Exit(TagOctetString);
  case AType.TypeKind of
    tkInteger, tkInt64: Result := TagInteger;
    { A Currency is written as an INTEGER of ten-thousandths, so an
      implicitly tagged one is re-read as one. No other float reaches here. }
    tkFloat:
      if GetTypeData(AType.Handle).FloatType in [ftCurr, ftComp] then
        Result := TagInteger
      else Result := TagReal;
    tkChar, tkWChar, tkString, tkLString, tkWString, tkUString:
      Result := UniversalTagOf(MemberStringKind(AMember));
    tkEnumeration:
      if AType.Handle = System.TypeInfo(Boolean) then Result := TagBoolean
      else Result := TagEnumerated;
    tkDynArray, tkArray: Result := TagSequence;
    tkRecord, tkMRecord, tkClass: Result := TagSequence;
  end;
end;

{ An IMPLICIT tag REPLACES the universal one, so the octets no longer say
  what they are: only the schema - or here, the Delphi type - does. The
  content is therefore re-read under the tag the member's type implies.

  The result is a NEW value when a reinterpretation happened, and AValue
  itself when none was needed, so the caller frees it only when the two
  differ. }
function ReinterpretImplicit(AValue: TAsn1Value; AType: TRttiType;
  AMember: TRttiMember): TAsn1Value;
var
  Tag: Integer;
  W: TOctetWriter;
  R: TOctetReader;
  Content: TBytes;
begin
  Result := AValue;
  if (AValue = nil) or (AValue.Kind <> TAsn1Kind.Unknown) then Exit;
  if AValue.IsConstructed then Exit;
  Tag := UniversalTagForType(AType, AMember);
  if Tag < 0 then Exit;
  Content := AValue.AsBytes;
  W.Init;
  W.PutRaw(EncodeIdentifier(TAsn1TagClass.Universal, UInt64(Tag), False));
  W.PutRaw(EncodeLength(Integer(Length(Content))));
  W.PutRaw(Content);
  R.Init(W.Done, TAsn1EncodingRule.Ber);
  Result := R.ReadValue;
end;

function Asn1ToValue(AType: TRttiType; AValue: TAsn1Value;
  AMember: TRttiMember; const AExisting: TValue;
  const APath: string): TValue; forward;

function Asn1ToChoice(AType: TRttiType; AValue: TAsn1Value;
  const AExisting: TValue; const ASelector, APath: string): TValue;
var
  Members: TArray<TRttiMember>;
  M, Sel: TRttiMember;
  I, Index: Integer;
  Inner: TAsn1Value;
begin
  { A CHOICE is a record, and merged in place like one: the object an
    alternative already holds is filled rather than replaced and orphaned. }
  if AExisting.IsEmpty then
    TValue.Make(nil, AType.Handle, Result)
  else
    TValue.Make(AExisting.GetReferenceToRawData, AType.Handle, Result);
  Members := MembersOf(AType);
  Sel := nil;
  for M in Members do
    if SameText(M.Name, ASelector) then
    begin
      Sel := M;
      Break;
    end;
  if Sel = nil then
    raise EAsn1InternalError.CreateFmt(
      'At %s: [Asn1Choice] names the selector field "%s" and there is no ' +
      'member of that name.', [APath, ASelector]);

  { The tag number says which alternative arrived. That is what a CHOICE's
    distinct tags are FOR, and reading the members in order and hoping would
    silently pick the wrong one. }
  if AValue.Kind <> TAsn1Kind.Tagged then
    raise EAsn1InputError.CreateFmt(
      'At %s: a CHOICE alternative arrives under its own context tag and ' +
      'this value has none, so nothing says which alternative it is.',
      [APath]);
  { Checked at full width: narrowed, alternative 2^32 would be alternative
    0. No CHOICE has that many. }
  if AValue.TagNumber > UInt64(High(Integer)) then
    raise EAsn1InputError.CreateFmt(
      'At %s: the document carries alternative %s, which no CHOICE has.',
      [APath, UIntToStr(AValue.TagNumber)]);
  Index := Integer(AValue.TagNumber);
  Inner := Untagged(AValue);

  I := 0;
  for M in Members do
  begin
    if M = Sel then Continue;
    if I = Index then
    begin
      SetMemberValueOf(Sel, Result, TValue.FromOrdinal(
        MemberTypeOf(Sel).Handle, Index));
      SetMemberValueOf(M, Result,
        Asn1ToValue(MemberTypeOf(M), Inner, M, ExistingValueOf(M, Result),
          APath + '.' + M.Name));
      Exit;
    end;
    Inc(I);
  end;
  raise EAsn1InputError.CreateFmt(
    'At %s: the document carries alternative %d and the CHOICE has only %d.',
    [APath, Index, I]);
end;

function Asn1ToValue(AType: TRttiType; AValue: TAsn1Value;
  AMember: TRttiMember; const AExisting: TValue;
  const APath: string): TValue;
var
  Access: TNullableAccess;
  Members: TArray<TRttiMember>;
  M: TRttiMember;
  I, Next: Integer;
  Obj: TObject;
  Instance, Arr, Elem, Key, Payload: TValue;
  ArrLen: NativeInt;
  Method: TRttiMethod;
  Item: TRttiType;
  Selector: string;
  Raw: TBytes;
  Guid: TGUID;
  Child: TAsn1Value;
  Reinterpreted: TAsn1Value;
  TagClass: TAsn1TagClass;
  Number: Integer;
  Ords: TArray<Integer>;
  Elems: TArray<TValue>;
  SerCls: TAsn1ValueSerializerClass;
  Ser: TCustomAsn1ValueSerializer;
  ListAdd, ListToArray, ListCreate, DictAdd: TRttiMethod;
  ListItem, DictKey: TRttiType;
  Built: Boolean;
  ListAccess: TListAccess;
  DictAccess: TDictionaryAccess;
  FloatWhy: string;

  { A set, an array, a list, a map and a SEQUENCE all arrive constructed.
    A primitive there - an INTEGER where a SEQUENCE OF belongs - is a
    document that does not match the contract, and reading its zero
    components made an empty list, silently. }
  procedure RequireConstructed;
  begin
    if not (AValue.Kind in [TAsn1Kind.Sequence, TAsn1Kind.SequenceOf,
         TAsn1Kind.SetValue, TAsn1Kind.SetOf]) then
      raise EAsn1InputError.CreateFmt(
        'At %s: %s is written as a SEQUENCE or a SET, and the octets there ' +
        'are %s.', [APath, AType.Name, AValue.Describe]);
  end;

begin
  Result := TValue.Empty;
  if AType = nil then Exit;

  { The caller's own mapping, before anything this unit would decide. }
  SerCls := MemberSerializerOf(AMember);
  if SerCls = nil then
    TAsn1Engine.TryGetTypeSerializer(AType.Handle, SerCls);
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
    if (AValue = nil) or (AValue.Kind = TAsn1Kind.NullValue) then Exit;
    { A payload that is there already is merged, as the member it wraps
      would be: its objects are filled in place rather than orphaned. }
    Payload := TValue.Empty;
    if (not AExisting.IsEmpty) and
       Access.HasValue(AExisting.GetReferenceToRawData) then
    begin
      Payload := Access.GetValue(AExisting.GetReferenceToRawData);
      if Payload.IsObject and (Payload.AsObject = nil) then
        Payload := TValue.Empty;
    end;
    Access.SetValue(Result.GetReferenceToRawData,
      Asn1ToValue(GCtx.GetType(Access.ValueType), AValue, AMember,
        Payload, APath));
    Exit;
  end;

  if (AValue = nil) or (AValue.Kind = TAsn1Kind.NullValue) then
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
  begin
    Raw := AValue.AsBytes;
    if Length(Raw) <> 16 then
      raise EAsn1InputError.CreateFmt(
        'At %s: a GUID is sixteen octets and this OCTET STRING has %d.',
        [APath, Length(Raw)]);
    Guid.D1 := (Cardinal(Raw[0]) shl 24) or (Cardinal(Raw[1]) shl 16) or
               (Cardinal(Raw[2]) shl 8) or Raw[3];
    Guid.D2 := Word((Word(Raw[4]) shl 8) or Raw[5]);
    Guid.D3 := Word((Word(Raw[6]) shl 8) or Raw[7]);
    for I := 0 to 7 do Guid.D4[I] := Raw[8 + I];
    Exit(TValue.From<TGUID>(Guid));
  end;
  if (AType.Handle = System.TypeInfo(TDateTime)) or
     (AType.Handle = System.TypeInfo(TDate)) or
     (AType.Handle = System.TypeInfo(TTime)) then
    Exit(TValue.From<Double>(AValue.AsDateTime).Cast(AType.Handle));
  if AType.Handle = System.TypeInfo(TBytes) then
    Exit(TValue.From<TBytes>(AValue.AsBytes));

  case AType.TypeKind of
    { Range-checked against the member's own type, through the INTEGER's
      digits - which reach past High(Int64) for a UInt64. }
    tkInteger, tkInt64:
      begin
        if not TSerializationTypes.TryIntegerFromText(AType.Handle,
             AValue.AsInteger.ToText, Result) then
          raise EAsn1InputError.CreateFmt('At %s: %s does not fit in %s.',
            [APath, AValue.AsInteger.ToText, AType.Name]);
        Exit;
      end;
    tkFloat:
      begin
        { The inverse of the Currency branch on the way out: the INTEGER is
          ten-thousandths, and putting the bits straight back is exact.
          Every other float type has no ASN.1 form and does not reach here,
          because writing one already refused. }
        if GetTypeData(AType.Handle).FloatType in [ftCurr, ftComp] then
        begin
          if AValue.Kind <> TAsn1Kind.IntegerValue then
            raise EAsn1InputError.CreateFmt(
              'At %s: %s is written as an INTEGER, and the octets there are %s.',
              [APath, AType.Name, AValue.Describe]);
          TValue.Make(nil, AType.Handle, Result);
          PInt64(Result.GetReferenceToRawData)^ := AValue.AsInt64;
          Exit;
        end;
        { Into the member's own width, checked: a Single does not become
          infinity for a REAL it cannot hold. }
        if AValue.Kind = TAsn1Kind.RealValue then
        begin
          if not TSerializationTypes.TryFloatFromDouble(AType.Handle,
               AValue.AsReal, Result, FloatWhy) then
            raise EAsn1InputError.CreateFmt('At %s: %s.', [APath, FloatWhy]);
          Exit;
        end;

        { A REAL is what a float is written as, so anything else here is a
          document that does not match the contract - and saying which tag
          arrived is more use than saying the type is unsupported. }
        raise EAsn1InputError.CreateFmt(
          'At %s: %s is a floating-point member and the octets there are %s, '
          + 'not a REAL.', [APath, AType.Name, AValue.Describe]);
      end;
    { Into the member's own code page, refusing text it cannot hold. }
    tkChar, tkWChar, tkString, tkLString, tkWString, tkUString:
      begin
        if not TSerializationTypes.TryStringFromText(AType.Handle,
             AValue.AsText, Result, Selector) then
          raise EAsn1InputError.CreateFmt('At %s: %s.', [APath, Selector]);
        Exit;
      end;
    tkEnumeration:
      begin
        if AType.Handle = System.TypeInfo(Boolean) then
          Exit(TValue.From<Boolean>(AValue.AsBoolean));
        if (AValue.AsInt64 < GetTypeData(AType.Handle).MinValue) or
           (AValue.AsInt64 > GetTypeData(AType.Handle).MaxValue) then
          raise EAsn1InputError.CreateFmt('At %s: %d is not a value of %s.',
            [APath, AValue.AsInt64, AType.Name]);
        Exit(TValue.FromOrdinal(AType.Handle, AValue.AsInt64));
      end;
    tkSet:
      begin
        { The inverse of SET OF ENUMERATED, built by TSerializationTypes: a
          TIntegerSet held 32 of up to 256 members, from ordinal 0. }
        RequireConstructed;
        Ords := nil;
        for I := 0 to AValue.Count - 1 do
          Ords := Ords + [Integer(AValue.Items[I].AsInt64)];
        if not TSerializationTypes.TryMakeSet(AType.Handle, Ords, Result,
             Selector) then
          raise EAsn1InputError.CreateFmt('At %s: %s.', [APath, Selector]);
        Exit;
      end;
    tkArray:
      begin
        RequireConstructed;
        SetLength(Elems, AValue.Count);
        try
          for I := 0 to AValue.Count - 1 do
            Elems[I] := Asn1ToValue(TRttiArrayType(AType).ElementType,
              AValue.Items[I], nil, TValue.Empty, Format('%s[%d]', [APath, I]));
          if not TSerializationTypes.TryMakeArray(AType.Handle, Elems, Result,
               Selector) then
            raise EAsn1InputError.CreateFmt('At %s: %s.', [APath, Selector]);
        except
          { The elements read before the failure are this read's, and were
            lost with the local array. }
          TSerializationOwnership.ReleaseBuiltElements(
            TRttiArrayType(AType).ElementType.Handle, Elems);
          raise;
        end;
        Exit;
      end;
    tkDynArray:
      begin
        RequireConstructed;
        Item := ElementTypeOf(AType);
        TValue.Make(nil, AType.Handle, Arr);
        ArrLen := AValue.Count;
        DynArraySetLength(PPointer(Arr.GetReferenceToRawData)^,
          AType.Handle, 1, @ArrLen);
        try
          for I := 0 to AValue.Count - 1 do
          begin
            Elem := Asn1ToValue(Item, AValue.Items[I], nil, TValue.Empty,
              Format('%s[%d]', [APath, I]));
            Arr.SetArrayElement(I, Elem);
          end;
        except
          TSerializationOwnership.ReleaseBuilt(AType.Handle, Arr, TValue.Empty);
          raise;
        end;
        Exit(Arr);
      end;
    tkRecord, tkMRecord, tkClass:
      begin
        { The inverse of the map: each component is a two-component SEQUENCE
          of key and value. }
        if (AType.TypeKind = tkClass) and
           DictionaryMethodsOf(AType, DictAdd, ListToArray, ListCreate,
             DictKey, ListItem) then
        begin
          RequireConstructed;
          if ListCreate = nil then
            raise EAsn1InputError.CreateFmt(
              'At %s: %s has no parameterless constructor.',
              [APath, AType.Name]);
          TSerializationTypes.TryGetDictionaryAccess(AType.Handle, DictAccess);
          { An existing map is refilled, as in every other format - not
            added to, which kept whatever a constructor had put there. }
          Built := not (AExisting.IsObject and (AExisting.AsObject <> nil));
          if Built then
            Obj := ListCreate.Invoke(
              TRttiInstanceType(AType).MetaclassType, []).AsObject
          else
          begin
            Obj := AExisting.AsObject;
            if DictAccess.ClearMethod <> nil then
              DictAccess.ClearMethod.Invoke(Obj, []);
          end;
          try
            for I := 0 to AValue.Count - 1 do
            begin
              if AValue.Items[I].Count < 2 then
                raise EAsn1InputError.CreateFmt(
                  'At %s: a map entry needs two components and this one has %d.',
                  [APath, AValue.Items[I].Count]);
              Key := Asn1ToValue(DictKey, AValue.Items[I].Items[0], nil,
                TValue.Empty, Format('%s{%d}.key', [APath, I]));
              try
                Elem := Asn1ToValue(ListItem, AValue.Items[I].Items[1], nil,
                  TValue.Empty, Format('%s{%d}.value', [APath, I]));
              except
                TSerializationOwnership.ReleaseBuilt(DictKey.Handle, Key,
                  TValue.Empty);
                raise;
              end;
              try
                { A key the document repeats replaces the earlier value, and
                  the earlier value - built by this read - is released rather
                  than dropped: AddOrSetValue orphaned it in a map that does
                  not own its values. }
                TSerializationOwnership.AddOrSetBuilt(DictAccess, Obj, Key, Elem);
              except
                on E: Exception do
                begin
                  TSerializationOwnership.ReleaseBuilt(DictKey.Handle, Key,
                    TValue.Empty);
                  TSerializationOwnership.ReleaseBuilt(ListItem.Handle, Elem,
                    TValue.Empty);
                  if string(E.UnitName).StartsWith('PascalForge.') then raise;
                  raise EAsn1InputError.CreateFmt(
                    'At %s{%d}: the %s refused an element the document ' +
                    'holds: %s', [APath, I, Obj.ClassName, E.Message]);
                end;
              end;
            end;
          except
            { What this read built is this read's to free - the map, and the
              keys and values in it when the map does not own them. }
            if Built then TSerializationOwnership.ReleaseBuiltContainer(Obj);
            raise;
          end;
          TValue.Make(@Obj, AType.Handle, Result);
          Exit;
        end;

        { The inverse of the SEQUENCE OF a list is written as: build the
          container and Add each element, rather than setting the container's
          own members from the components. }
        if (AType.TypeKind = tkClass) and
           ListMethodsOf(AType, ListAdd, ListToArray, ListCreate, ListItem) then
        begin
          RequireConstructed;
          if ListCreate = nil then
            raise EAsn1InputError.CreateFmt(
              'At %s: %s has no parameterless constructor.',
              [APath, AType.Name]);
          Built := not (AExisting.IsObject and (AExisting.AsObject <> nil));
          if Built then
            Obj := ListCreate.Invoke(
              TRttiInstanceType(AType).MetaclassType, []).AsObject
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
              Elem := Asn1ToValue(ListItem, AValue.Items[I], nil,
                TValue.Empty, Format('%s[%d]', [APath, I]));
              try
                ListAdd.Invoke(Obj, [Elem]);
              except
                { The container's own refusal - a sorted TStringList with
                  dupError - is a document this contract cannot hold, and
                  reached the caller as the RTL's EStringListError. }
                on E: Exception do
                begin
                  TSerializationOwnership.ReleaseBuilt(ListItem.Handle, Elem,
                    TValue.Empty);
                  if string(E.UnitName).StartsWith('PascalForge.') then raise;
                  raise EAsn1InputError.CreateFmt(
                    'At %s[%d]: the %s refused an element the document ' +
                    'holds: %s', [APath, I, Obj.ClassName, E.Message]);
                end;
              end;
            end;
          except
            { A list this read built is freed with the elements this read put
              in it, unless it owns them: a TList<TObject> freed alone
              orphaned every one. }
            if Built then TSerializationOwnership.ReleaseBuiltContainer(Obj);
            raise;
          end;
          TValue.Make(@Obj, AType.Handle, Result);
          Exit;
        end;

        Selector := MemberChoiceSelector(AMember);
        if Selector <> '' then
          Exit(Asn1ToChoice(AType, AValue, AExisting, Selector, APath));

        RequireConstructed;
        Built := False;
        if AType.TypeKind = tkClass then
        begin
          if AExisting.IsObject and (AExisting.AsObject <> nil) then
            Instance := AExisting
          else
          begin
            Method := TSerializationTypes.DefaultConstructor(AType);
            if Method = nil then
              raise EAsn1InputError.CreateFmt(
                'At %s: %s has no parameterless constructor.',
                [APath, AType.Name]);
            Obj := Method.Invoke(
              TRttiInstanceType(AType).MetaclassType, []).AsObject;
            TValue.Make(@Obj, AType.Handle, Instance);
            Built := True;
          end;
        end
        else if AExisting.IsEmpty then
          TValue.Make(nil, AType.Handle, Instance)
        else
          { A record is merged in place, from a COPY of the value it holds:
            the objects in it are filled rather than replaced, the members the
            document omits keep their values, and on a failure the copy is
            what says which objects this read put there. A TValue assignment
            would share the one buffer and hide that. }
          TValue.Make(AExisting.GetReferenceToRawData, AType.Handle, Instance);
        try

        { The components are read IN ORDER, because that is the only thing
          the octets say about which is which. An OPTIONAL member that is
          absent is skipped by looking at the tag of what actually arrived -
          which is why an OPTIONAL member needs a distinct tag to be
          unambiguous, exactly as X.680 requires. }
        Members := MembersOf(AType);
        Next := 0;
        for M in Members do
        begin
          if Next >= AValue.Count then
          begin
            if MemberOptional(M) then Continue;
            raise EAsn1InputError.CreateFmt(
              'At %s: the document ends before the component "%s", which is ' +
              'not OPTIONAL.', [APath, M.Name]);
          end;
          Child := AValue.Items[Next];
          { An OPTIONAL member is recognised by its tag. That is why X.680
            requires the alternatives of an optional run to have distinct
            tags: without one there is nothing in the octets that says
            whether the value present is this member or the next. }
          if MemberOptional(M) and MemberTag(M, TagClass, Number) then
            if ((Child.Kind <> TAsn1Kind.Tagged) and
                (Child.TagClass <> TagClass)) or
               ((Child.TagClass = TagClass) and
                (Child.TagNumber <> UInt64(Number))) then
              Continue;

          Reinterpreted := nil;
          if MemberTag(M, TagClass, Number) then
          begin
            if MemberTagIsImplicit(M) then
            begin
              Reinterpreted := ReinterpretImplicit(Child, MemberTypeOf(M), M);
              if Reinterpreted <> Child then Child := Reinterpreted
              else Reinterpreted := nil;
            end
            else
              Child := Untagged(Child);
          end;
          try
            SetMemberValueOf(M, Instance,
              Asn1ToValue(MemberTypeOf(M), Child, M, ExistingValueOf(M, Instance),
                APath + '.' + M.Name));
          finally
            Reinterpreted.Free;
          end;
          Inc(Next);
        end;
        except
          { What this read constructed is this read's to free when it fails;
            an instance the caller passed in is never freed. A record has no
            destructor to free its members, so the objects this read put in
            it - those not in the same place of the value it started from -
            are freed here: they were lost with the local copy. }
          if Built then Instance.AsObject.Free
          else if AType.TypeKind <> tkClass then
            TSerializationOwnership.ReleaseBuilt(AType.Handle, Instance,
              AExisting);
          raise;
        end;
        Exit(Instance);
      end;
  end;

  raise EAsn1InternalError.CreateFmt('At %s: cannot read %s from ASN.1.',
    [APath, AType.Name]);
end;

class constructor TAsn1Engine.Create;
begin
  FTypeSerializers := TDictionary<PTypeInfo, TAsn1ValueSerializerClass>.Create;
  FLock := TCriticalSection.Create;
end;

class destructor TAsn1Engine.Destroy;
begin
  FLock.Free;
  FTypeSerializers.Free;
end;

class procedure TAsn1Engine.RegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TAsn1ValueSerializerClass);
begin
  FLock.Enter;
  try
    if FFrozen then
      raise EAsn1InternalError.Create('The ASN.1 configuration is frozen: ' +
        'the first serialization froze it, so a type serializer registered ' +
        'now would disagree with what was already written. Register at ' +
        'startup, before the first use.');
    FTypeSerializers.AddOrSetValue(ATypeInfo, ASerializerClass);
  finally
    FLock.Leave;
  end;
end;

class function TAsn1Engine.TryGetTypeSerializer(ATypeInfo: PTypeInfo;
  out AClass: TAsn1ValueSerializerClass): Boolean;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  AClass := nil;
  if ATypeInfo = nil then Exit(False);
  FLock.Enter;
  try
    Result := FTypeSerializers.TryGetValue(ATypeInfo, AClass);
  finally
    FLock.Leave;
  end;
end;

class procedure TAsn1Engine.ResetConfiguration;
begin
  FLock.Enter;
  try
    FTypeSerializers.Clear;
    FFrozen := False;
  finally
    FLock.Leave;
  end;
end;

class procedure TAsn1Engine.FreezeConfiguration;
begin
  FFrozen := True;
end;

class function TAsn1Engine.IsFrozen: Boolean;
begin
  Result := FFrozen;
end;

class function TAsn1Engine.SerializeRoot(ATypeInfo: PTypeInfo;
  const AValue: TValue; ARule: TAsn1EncodingRule): TBytes;
var
  Tree: TAsn1Value;
  Mark: Integer;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  { The level this write started from comes back however it ends, so a
    failure deep in one write cannot leave the next one on this thread
    starting part way down. }
  Mark := TSerializationGraphGuard.Level;
  try
    Tree := ValueToAsn1(GCtx.GetType(ATypeInfo), AValue, nil, '$');
  finally
    TSerializationGraphGuard.RestoreLevel(Mark);
  end;
  try
    Result := TAsn1Codec.Encode(Tree, ARule);
  finally
    Tree.Free;
  end;
end;

class function TAsn1Engine.DeserializeRoot(ATypeInfo: PTypeInfo;
  const AData: TBytes; ARule: TAsn1EncodingRule): TValue;
var
  Tree: TAsn1Value;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  Tree := TAsn1Codec.Decode(AData, ARule);
  try
    Result := Asn1ToValue(GCtx.GetType(ATypeInfo), Tree, nil, TValue.Empty,
      '$');
  finally
    Tree.Free;
  end;
end;

{ ===========================================================================
  THE SCHEMA-DRIVEN CODEC

  A schema is what turns a tree of anonymous octets into named components. It
  is also the only thing that can tell a SEQUENCE from a SEQUENCE OF - they
  share tag 16 - or say which alternative of a CHOICE arrived.
  =========================================================================== }

function RequireSchema(ASchema: TSerializationSchema;
  const ATypeName: string): TAsn1TypeDef;
var
  Schema: TAsn1Schema;
begin
  if not (ASchema is TAsn1Schema) then
    raise ESerializationSchemaRequired.CreateFor(TSerializationFormat.Asn1Ber,
      'structural conversion');
  Schema := TAsn1Schema(ASchema);
  Result := Schema.FindType(ATypeName);
  if Result = nil then
    raise EAsn1SchemaError.CreateFmt(
      'This module has no type assignment named "%s". ASN.1 octets are ' +
      'anonymous, so the type name is the only thing that says what they ' +
      'are.', [ATypeName]);
  Result := Result.Resolve(Schema);
end;

{ Walk a decoded tree against a type definition, naming the components and
  resolving the forms the octets alone cannot. The tree is modified in
  place - names are set on it - and handed back. }
procedure ApplySchema(AValue: TAsn1Value; ADef: TAsn1TypeDef;
  ASchema: TAsn1Schema; const APath: string);
var
  I, Next: Integer;
  Comp: TAsn1Component;
  Child: TAsn1Value;
  Target, Alt: TAsn1TypeDef;
  AltTag: Integer;
  Opaque: Boolean;
begin
  if (AValue = nil) or (ADef = nil) then Exit;
  Target := ADef.Resolve(ASchema);

  case Target.TypeKind of
    TAsn1TypeKind.Sequence, TAsn1TypeKind.SetType:
      begin
        Next := 0;
        for I := 0 to Target.ComponentCount - 1 do
        begin
          Comp := Target.Components[I];
          if Next >= AValue.Count then
          begin
            if Comp.Optional or Comp.HasDefault then Continue;
            raise EAsn1InputError.CreateFmt(
              'At %s: the document ends before the component "%s", which ' +
              'the schema does not mark OPTIONAL and gives no DEFAULT.',
              [APath, Comp.Name]);
          end;
          Child := AValue.Items[Next];
          if (Comp.Optional or Comp.HasDefault) and Comp.Tagged then
            if (Child.Kind <> TAsn1Kind.Tagged) or
               (Child.TagClass <> Comp.TagClass) or
               (Child.TagNumber <> Comp.TagNumber) then
              Continue;
          Child.Name := Comp.Name;
          if Comp.Tagged and Comp.TagExplicit and
             (Child.Kind = TAsn1Kind.Tagged) and (Child.Count = 1) then
          begin
            Child.Items[0].Name := Comp.Name;
            ApplySchema(Child.Items[0], Comp.TypeDef, ASchema,
              APath + '.' + Comp.Name);
          end
          else
            ApplySchema(Child, Comp.TypeDef, ASchema,
              APath + '.' + Comp.Name);
          Inc(Next);
        end;
      end;

    TAsn1TypeKind.SequenceOf, TAsn1TypeKind.SetOf:
      for I := 0 to AValue.Count - 1 do
        ApplySchema(AValue.Items[I], Target.ElementType, ASchema,
          Format('%s[%d]', [APath, I]));

    TAsn1TypeKind.Choice:
      begin
        { A CHOICE alternative arrives under its own tag, and the tag is what
          names it. The name goes on ChoiceAlternative, not on Name: Name is
          the component this CHOICE fills, and overwriting it lost both. }
        for I := 0 to Target.ComponentCount - 1 do
        begin
          Comp := Target.Components[I];
          if not Comp.Tagged then Continue;
          if (Comp.TagClass = AValue.TagClass) and
             (Comp.TagNumber = AValue.TagNumber) then
          begin
            AValue.ChoiceAlternative := Comp.Name;
            if Comp.TagExplicit and (AValue.Kind = TAsn1Kind.Tagged) and
               (AValue.Count = 1) then
            begin
              AValue.Items[0].Name := Comp.Name;
              ApplySchema(AValue.Items[0], Comp.TypeDef, ASchema,
                APath + '.' + Comp.Name);
            end
            else
              ApplySchema(AValue, Comp.TypeDef, ASchema,
                APath + '.' + Comp.Name);
            Exit;
          end;
        end;
        { An untagged alternative is told apart by its own universal tag. }
        Opaque := False;
        if AValue.TagClass = TAsn1TagClass.Universal then
          for I := 0 to Target.ComponentCount - 1 do
          begin
            Comp := Target.Components[I];
            if Comp.Tagged then Continue;
            Alt := Comp.TypeDef.Resolve(ASchema);
            case Alt.TypeKind of
              TAsn1TypeKind.Sequence, TAsn1TypeKind.SequenceOf:
                AltTag := TagSequence;
              TAsn1TypeKind.SetType, TAsn1TypeKind.SetOf:
                AltTag := TagSet;
              TAsn1TypeKind.Base:
                AltTag := UniversalTagOf(Alt.BaseKind);
            else
              AltTag := -1;
            end;
            { A CHOICE inside a CHOICE, or a type with no universal tag of
              its own, has nothing to match: such a value stays unresolved
              rather than being refused. }
            if AltTag < 0 then
            begin
              Opaque := True;
              Continue;
            end;
            if AValue.TagNumber = UInt64(AltTag) then
            begin
              AValue.ChoiceAlternative := Comp.Name;
              ApplySchema(AValue, Alt, ASchema, APath + '.' + Comp.Name);
              Exit;
            end;
          end;
        if not Opaque then
          raise EAsn1InputError.CreateFmt(
            'At %s: the value carries %s, and no alternative of this CHOICE ' +
            'has that tag.', [APath, Asn1TagName(AValue.TagClass,
              AValue.TagNumber, AValue.IsConstructed)]);
      end;
  end;
end;

class function TAsn1SchemaCodec.Decode(const AData: TBytes;
  ASchema: TSerializationSchema; const ATypeName: string;
  ARule: TAsn1EncodingRule): TAsn1Value;
var
  Def: TAsn1TypeDef;
begin
  Def := RequireSchema(ASchema, ATypeName);
  Result := TAsn1Codec.Decode(AData, ARule);
  try
    ApplySchema(Result, Def, TAsn1Schema(ASchema), '$');
  except
    Result.Free;
    raise;
  end;
end;

class function TAsn1SchemaCodec.Encode(AValue: TAsn1Value;
  ASchema: TSerializationSchema; const ATypeName: string;
  ARule: TAsn1EncodingRule): TBytes;
begin
  { The schema is consulted to CHECK the value rather than to build it: the
    value already carries its own tags and kinds, and a schema that
    disagreed with them would be describing a different document. }
  RequireSchema(ASchema, ATypeName);
  Result := TAsn1Codec.Encode(AValue, ARule);
end;

{ One value as a dynamic value, without the CHOICE wrapper ValueToDynamic adds. }
function Asn1BodyToDynamic(AValue: TAsn1Value): TDynamicValue;
var
  I: Integer;
  I64: Int64;
  Name: string;
  Payload: TDynamicValue;
begin
  if AValue = nil then Exit(TDynamicValue.NewNull);
  case AValue.Kind of
    TAsn1Kind.NullValue: Exit(TDynamicValue.NewNull);
    TAsn1Kind.BooleanValue: Exit(TDynamicValue.NewBool(AValue.AsBoolean));
    TAsn1Kind.IntegerValue, TAsn1Kind.Enumerated:
      begin
        { An ASN.1 INTEGER has no bounds at all, so one that does not fit an
          Int64 travels as its exact decimal TEXT rather than being wrapped
          into a number it is not. }
        if AValue.AsInteger.TryToInt64(I64) then
          Exit(TDynamicValue.NewInt(I64));
        Exit(TDynamicValue.NewDecimal(AValue.AsInteger.ToText));
      end;
    TAsn1Kind.RealValue: Exit(TDynamicValue.NewFloat(AValue.AsReal));
    TAsn1Kind.OctetString: Exit(TDynamicValue.NewBytes(AValue.AsBytes));
    TAsn1Kind.BitString:
      begin
        { A BIT STRING is octets AND a count of unused bits in the last one,
          and nothing else here has both - so it travels as the pair it is
          rather than as octets that have quietly grown up to seven bits. }
        Payload := TDynamicValue.NewObject;
        try
          Payload.AsObject.Adopt('bits', TDynamicValue.NewBytes(AValue.AsBytes));
          Payload.AsObject.Adopt('unused', TDynamicValue.NewInt(AValue.UnusedBits));
        except
          Payload.Free;
          raise;
        end;
        Exit(TDynamicValue.NewExtended(TDynamicTag.FormatTag, Payload));
      end;
    TAsn1Kind.Oid, TAsn1Kind.RelativeOid:
      Exit(TDynamicValue.NewStr(AValue.AsOid.ToText));
    TAsn1Kind.UtcTime, TAsn1Kind.GeneralizedTime:
      Exit(TDynamicValue.NewDateTime(AValue.AsDateTime));
    TAsn1Kind.Sequence, TAsn1Kind.SetValue, TAsn1Kind.Unknown:
      begin
        { A tag this library does not interpret keeps its octets, so that a
          document containing one still converts rather than being refused. }
        if (AValue.Kind = TAsn1Kind.Unknown) and not AValue.IsConstructed then
          Exit(TDynamicValue.NewBytes(AValue.AsBytes));
        { A named component becomes a member; an unnamed one - which is what
          a document read without a schema has - becomes a positional name,
          because the dynamic tree's members have names and ASN.1's do not. }
        Result := TDynamicValue.NewObject;
        try
          for I := 0 to AValue.Count - 1 do
          begin
            Name := AValue.Items[I].Name;
            if Name = '' then Name := Format('item%d', [I + 1]);
            Result.AsObject.Adopt(Name, TAsn1SchemaCodec.ValueToDynamic(AValue.Items[I]));
          end;
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
    TAsn1Kind.SequenceOf, TAsn1Kind.SetOf:
      begin
        Result := TDynamicValue.NewArray;
        try
          for I := 0 to AValue.Count - 1 do
            Result.AsArray.Adopt(TAsn1SchemaCodec.ValueToDynamic(AValue.Items[I]));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
    TAsn1Kind.Tagged:
      begin
        if AValue.Count = 1 then Exit(TAsn1SchemaCodec.ValueToDynamic(AValue.Items[0]));
        Exit(TDynamicValue.NewNull);
      end;
  end;
  if IsStringKind(AValue.Kind) then Exit(TDynamicValue.NewStr(AValue.AsText));
  Result := TDynamicValue.NewNull;
end;

class function TAsn1SchemaCodec.ValueToDynamic(AValue: TAsn1Value): TDynamicValue;
var
  Payload: TDynamicValue;
begin
  { A CHOICE the schema resolved is an object with one member naming the
    alternative - the shape FromDynamic reads back. Without it the
    alternative's name was lost and the document could not be written
    again. }
  if (AValue = nil) or (AValue.ChoiceAlternative = '') then
    Exit(Asn1BodyToDynamic(AValue));
  Payload := Asn1BodyToDynamic(AValue);
  Result := TDynamicValue.NewObject;
  try
    Result.AsObject.Adopt(AValue.ChoiceAlternative, Payload);
  except
    Result.Free;
    raise;
  end;
end;

class function TAsn1SchemaCodec.ToDynamic(const AData: TBytes;
  ASchema: TSerializationSchema; const ATypeName: string;
  ARule: TAsn1EncodingRule): TDynamicValue;
var
  Tree: TAsn1Value;
begin
  Tree := Decode(AData, ASchema, ATypeName, ARule);
  try
    Result := ValueToDynamic(Tree);
  finally
    Tree.Free;
  end;
end;

{ A dynamic tree as an ASN.1 value of a given type. The schema is not
  optional here and never could be: the dynamic tree says "a string" and
  ASN.1 has nine string types, so only the schema can say which. }
function Asn1RuleFormat(ARule: TAsn1EncodingRule): TSerializationFormat;
begin
  case ARule of
    TAsn1EncodingRule.Der: Result := TSerializationFormat.Asn1Der;
    TAsn1EncodingRule.Cer: Result := TSerializationFormat.Asn1Cer;
  else
    Result := TSerializationFormat.Asn1Ber;
  end;
end;

{ A member the selected SEQUENCE or SET does not declare. The module is the
  destination's whole vocabulary and ASN.1 has no standard place for a
  component it does not name, so Natural omits it - documented in
  docs\asn1-behavior.md - and Strict and Lossless refuse, naming it: the
  result would otherwise be a smaller document than the one given, and
  nothing proprietary is written to carry it. }
procedure CheckDeclaredMembers(AValue: TDynamicValue; ATarget: TAsn1TypeDef;
  const APath: string; const AOptions: TStructuralConversionOptions;
  ARule: TAsn1EncodingRule);
var
  I, J: Integer;
  Declared: Boolean;
  Issue: TStructuralIssue;
  Profile: string;
begin
  if AOptions.ValuePolicy = TStructuralValuePolicy.Natural then Exit;
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
  for I := 0 to AValue.Count - 1 do
  begin
    Declared := False;
    for J := 0 to ATarget.ComponentCount - 1 do
      if ATarget.Components[J].Name = AValue.Names[I] then
      begin
        Declared := True;
        Break;
      end;
    if not Declared then
      raise EStructuralConversionError.CreateFor(Issue, AOptions,
        Asn1RuleFormat(ARule), APath + '.' + AValue.Names[I],
        AValue.Items[I].Kind, Format(
        'the member "%s" is not a component of the ASN.1 type %s, so ' +
        'writing it would drop the member. %s refuses rather than omit it; ' +
        'declare the component in the module, or convert with the Natural ' +
        'profile, which omits it.',
        [AValue.Names[I], ATarget.Name, Profile]));
  end;
end;

{ Whether a (non-null) dynamic value's kind is one the ASN.1 base type can
  hold exactly. Only the conversions that already existed and are exact. }
function DynamicKindFits(AValue: TDynamicValue; ABaseKind: TAsn1Kind): Boolean;
begin
  case ABaseKind of
    TAsn1Kind.BooleanValue:
      Result := AValue.Kind = TDynamicKind.Bool;
    TAsn1Kind.IntegerValue:
      Result := AValue.Kind in [TDynamicKind.Int, TDynamicKind.UInt,
        TDynamicKind.Decimal];
    TAsn1Kind.Enumerated:
      Result := (AValue.Kind = TDynamicKind.Int) or
        ((AValue.Kind = TDynamicKind.UInt) and
         (AValue.AsUInt <= UInt64(High(Int64))));
    TAsn1Kind.RealValue:
      Result := AValue.Kind in [TDynamicKind.Int, TDynamicKind.Float,
        TDynamicKind.Decimal];
    TAsn1Kind.NullValue:
      Result := AValue.Kind = TDynamicKind.Null;
    TAsn1Kind.OctetString:
      Result := AValue.Kind = TDynamicKind.Bytes;
    TAsn1Kind.BitString:
      Result := (AValue.Kind = TDynamicKind.Bytes) or
        (AValue.IsTagged(TDynamicTag.FormatTag) and
         (AValue.ExtendedValue <> nil));
    TAsn1Kind.Oid, TAsn1Kind.RelativeOid:
      Result := AValue.Kind = TDynamicKind.Str;
    TAsn1Kind.UtcTime, TAsn1Kind.GeneralizedTime:
      Result := AValue.Kind in [TDynamicKind.DateTime, TDynamicKind.Date];
  else
    if IsStringKind(ABaseKind) then
      Result := AValue.Kind = TDynamicKind.Str
    else
      { Not a base type this writer knows: its own error says so below. }
      Result := True;
  end;
end;

function DynamicKindText(AKind: TDynamicKind): string;
begin
  case AKind of
    TDynamicKind.Null:     Result := 'null';
    TDynamicKind.Bool:     Result := 'a boolean';
    TDynamicKind.Int:      Result := 'an integer';
    TDynamicKind.UInt:     Result := 'an unsigned integer';
    TDynamicKind.Float:    Result := 'a floating-point number';
    TDynamicKind.Decimal:  Result := 'a decimal';
    TDynamicKind.Str:      Result := 'a string';
    TDynamicKind.Bytes:    Result := 'bytes';
    TDynamicKind.Date:     Result := 'a date';
    TDynamicKind.Time:     Result := 'a time of day';
    TDynamicKind.DateTime: Result := 'a date-time';
    TDynamicKind.Arr:      Result := 'an array';
    TDynamicKind.Obj:      Result := 'an object';
  else
    Result := 'an extended value';
  end;
end;

{ A value the destination type cannot hold, refused in every profile: this
  is data the module cannot carry, not a naming policy. }
procedure RefuseDynamicKind(AValue: TDynamicValue; ABaseKind: TAsn1Kind;
  const APath: string; const AOptions: TStructuralConversionOptions;
  ARule: TAsn1EncodingRule);
begin
  raise EStructuralConversionError.CreateFor(
    TStructuralIssue.UnsupportedValueKind, AOptions, Asn1RuleFormat(ARule),
    APath, AValue.Kind, Format('the module says %s and the value is %s, ' +
    'which that type cannot hold exactly.', [Asn1TagName(
    TAsn1TagClass.Universal, UInt64(UniversalTagOf(ABaseKind)), False),
    DynamicKindText(AValue.Kind)]));
end;

function DynamicToAsn1(AValue: TDynamicValue; ADef: TAsn1TypeDef;
  ASchema: TAsn1Schema; const APath: string;
  const AOptions: TStructuralConversionOptions;
  ARule: TAsn1EncodingRule): TAsn1Value;
var
  I: Integer;
  Comp: TAsn1Component;
  Child: TDynamicValue;
  Target: TAsn1TypeDef;
  Inner: TAsn1Value;
  Parsed: Double;
  Exact: Boolean;
begin
  if ADef = nil then
    raise ESerializationSchemaRequired.CreateFor(TSerializationFormat.Asn1Ber,
      'writing a structural tree');
  Target := ADef.Resolve(ASchema);

  case Target.TypeKind of
    TAsn1TypeKind.Sequence, TAsn1TypeKind.SetType:
      begin
        if (AValue = nil) or (AValue.Kind <> TDynamicKind.Obj) then
          raise EAsn1InputError.CreateFmt(
            'At %s: the schema says %s and this value is not an object.',
            [APath, Target.Name]);
        CheckDeclaredMembers(AValue, Target, APath, AOptions, ARule);
        if Target.TypeKind = TAsn1TypeKind.SetType then
          Result := TAsn1Value.NewSet
        else
          Result := TAsn1Value.NewSequence;
        try
          for I := 0 to Target.ComponentCount - 1 do
          begin
            Comp := Target.Components[I];
            Child := AValue.Find(Comp.Name);
            if Child = nil then
            begin
              if Comp.Optional or Comp.HasDefault then Continue;
              raise EAsn1InputError.CreateFmt(
                'At %s: the schema requires the component "%s" and the ' +
                'value has no member of that name.', [APath, Comp.Name]);
            end;
            Inner := DynamicToAsn1(Child, Comp.TypeDef, ASchema,
              APath + '.' + Comp.Name, AOptions, ARule);
            Inner.Name := Comp.Name;
            if Comp.Tagged then
              if Comp.TagExplicit then
                Inner := TAsn1Value.NewExplicit(Comp.TagClass, Comp.TagNumber,
                  Inner)
              else
                Inner := TAsn1Value.NewImplicit(Comp.TagClass, Comp.TagNumber,
                  Inner);
            Result.Add(Inner);
          end;
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;

    TAsn1TypeKind.SequenceOf, TAsn1TypeKind.SetOf:
      begin
        if (AValue = nil) or (AValue.Kind <> TDynamicKind.Arr) then
          raise EAsn1InputError.CreateFmt(
            'At %s: the schema says a SEQUENCE OF and this value is not an ' +
            'array.', [APath]);
        if Target.TypeKind = TAsn1TypeKind.SetOf then
          Result := TAsn1Value.NewSetOf
        else
          Result := TAsn1Value.NewSequenceOf;
        try
          for I := 0 to AValue.Count - 1 do
            Result.Add(DynamicToAsn1(AValue.Items[I], Target.ElementType,
              ASchema, Format('%s[%d]', [APath, I]), AOptions, ARule));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;

    TAsn1TypeKind.Choice:
      begin
        if (AValue = nil) or (AValue.Kind <> TDynamicKind.Obj) or
           (AValue.Count <> 1) then
          raise EAsn1InputError.CreateFmt(
            'At %s: a CHOICE is exactly one alternative, so the value has ' +
            'to be an object with exactly one member naming it.', [APath]);
        { The exact name first: ASN.1 identifiers are case-sensitive, and
          "aB" and "ab" can be two alternatives. A case-insensitive match is
          the fallback it always was. }
        Exact := False;
        for I := 0 to Target.ComponentCount - 1 do
          if Target.Components[I].Name = AValue.Names[0] then
          begin
            Exact := True;
            Break;
          end;
        for I := 0 to Target.ComponentCount - 1 do
        begin
          Comp := Target.Components[I];
          if Exact then
          begin
            if Comp.Name <> AValue.Names[0] then Continue;
          end
          else if not SameText(Comp.Name, AValue.Names[0]) then Continue;
          Inner := DynamicToAsn1(AValue.Items[0], Comp.TypeDef, ASchema,
            APath + '.' + Comp.Name, AOptions, ARule);
          Inner.Name := Comp.Name;
          if Comp.Tagged then
            if Comp.TagExplicit then
              Exit(TAsn1Value.NewExplicit(Comp.TagClass, Comp.TagNumber, Inner))
            else
              Exit(TAsn1Value.NewImplicit(Comp.TagClass, Comp.TagNumber, Inner));
          Exit(Inner);
        end;
        raise EAsn1InputError.CreateFmt(
          'At %s: "%s" is not one of the alternatives of this CHOICE.',
          [APath, AValue.Names[0]]);
      end;
  end;

  { A base type. }
  if (AValue = nil) or (AValue.Kind = TDynamicKind.Null) then
  begin
    if Target.BaseKind = TAsn1Kind.NullValue then Exit(TAsn1Value.NewNull);
    raise EAsn1InputError.CreateFmt(
      'At %s: a null value, and the schema says %s. ASN.1 has NULL as a ' +
      'type of its own; a component that may be absent is OPTIONAL.',
      [APath, GetEnumName(System.TypeInfo(TAsn1Kind), Ord(Target.BaseKind))]);
  end;

  { Only a value the type can hold EXACTLY is written. The dynamic accessors
    are plain field reads, so anything else - a string into INTEGER, bytes
    into UTF8String - would become 0 or '' without a word. }
  if not DynamicKindFits(AValue, Target.BaseKind) then
    RefuseDynamicKind(AValue, Target.BaseKind, APath, AOptions, ARule);

  case Target.BaseKind of
    TAsn1Kind.BooleanValue: Exit(TAsn1Value.NewBoolean(AValue.AsBool));
    TAsn1Kind.IntegerValue:
      if AValue.Kind = TDynamicKind.Decimal then
        Exit(TAsn1Value.NewInteger(TAsn1BigInt.FromText(AValue.AsDecimal)))
      else if AValue.Kind = TDynamicKind.UInt then
        Exit(TAsn1Value.NewInteger(TAsn1BigInt.FromUInt64(AValue.AsUInt)))
      else
        Exit(TAsn1Value.NewInteger(AValue.AsInt));
    TAsn1Kind.Enumerated: Exit(TAsn1Value.NewEnumerated(AValue.AsInt));
    TAsn1Kind.RealValue:
      begin
        { A Decimal arrives as exact text, so it is parsed rather than read
          through a Double that has already rounded it - and parsed correctly
          rounded, which StrToFloat was not on Win64. }
        if AValue.Kind = TDynamicKind.Decimal then
        begin
          if not TStructuralText.TryParseFloat(AValue.AsDecimal, Parsed) then
            raise EAsn1InputError.CreateFmt(
              'At %s: the decimal "%s" is not a number, and the schema says ' +
              'REAL.', [APath, AValue.AsDecimal]);
          Exit(TAsn1Value.NewReal(Parsed));
        end;
        if AValue.Kind = TDynamicKind.Int then
          Exit(TAsn1Value.NewReal(AValue.AsInt));
        Exit(TAsn1Value.NewReal(AValue.AsFloat));
      end;
    TAsn1Kind.NullValue: Exit(TAsn1Value.NewNull);
    TAsn1Kind.OctetString: Exit(TAsn1Value.NewOctetString(AValue.AsBytes));
    TAsn1Kind.BitString:
      begin
        if AValue.IsTagged(TDynamicTag.FormatTag) and
           (AValue.ExtendedValue <> nil) then
          Exit(TAsn1Value.NewBitString(
            AValue.ExtendedValue.Find('bits').AsBytes,
            Byte(AValue.ExtendedValue.Find('unused').AsInt)));
        Exit(TAsn1Value.NewBitString(AValue.AsBytes, 0));
      end;
    TAsn1Kind.Oid: Exit(TAsn1Value.NewOid(AValue.AsStr));
    TAsn1Kind.RelativeOid:
      Exit(TAsn1Value.NewRelativeOid(TAsn1Oid.FromText(AValue.AsStr)));
    TAsn1Kind.UtcTime: Exit(TAsn1Value.NewUtcTime(AValue.AsDateTime));
    TAsn1Kind.GeneralizedTime:
      Exit(TAsn1Value.NewGeneralizedTime(AValue.AsDateTime));
  end;

  if IsStringKind(Target.BaseKind) then
    Exit(TAsn1Value.NewString(Target.BaseKind, AValue.AsStr));

  raise EAsn1InputError.CreateFmt('At %s: cannot write a %s.',
    [APath, GetEnumName(System.TypeInfo(TAsn1Kind), Ord(Target.BaseKind))]);
end;

class function TAsn1SchemaCodec.FromDynamic(AValue: TDynamicValue;
  ASchema: TSerializationSchema; const ATypeName: string;
  ARule: TAsn1EncodingRule): TBytes;
begin
  Result := FromDynamic(AValue, ASchema, ATypeName, ARule,
    TStructuralConversionOptions.Default);
end;

class function TAsn1SchemaCodec.FromDynamic(AValue: TDynamicValue;
  ASchema: TSerializationSchema; const ATypeName: string;
  ARule: TAsn1EncodingRule;
  const AOptions: TStructuralConversionOptions): TBytes;
var
  Def: TAsn1TypeDef;
  Tree: TAsn1Value;
begin
  Def := RequireSchema(ASchema, ATypeName);
  Tree := DynamicToAsn1(AValue, Def, TAsn1Schema(ASchema), '$', AOptions,
    ARule);
  try
    Result := TAsn1Codec.Encode(Tree, ARule);
  finally
    Tree.Free;
  end;
end;


{ --- the helpers the public unit reaches ---------------------------------- }

function Asn1UniversalTagOfKind(AKind: TAsn1Kind): Integer;
begin
  Result := UniversalTagOf(AKind);
end;

function Asn1EncodeUtcTime(AValue: TDateTime): string;
begin
  Result := EncodeUtcTime(AValue);
end;

function Asn1EncodeGeneralizedTime(AValue: TDateTime): string;
begin
  Result := EncodeGeneralizedTime(AValue);
end;

function Asn1SameBytes(const A, B: TBytes): Boolean;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  for I := 0 to Integer(High(A)) do
    if A[I] <> B[I] then Exit(False);
  Result := True;
end;

end.
