program Asn1Native;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Is this actually BER, DER and CER - three encodings, or one with three
  names?

  That is the question this program is mostly about. The three share the
  tag-length-value shape and differ in what they ALLOW, and the differences
  are exactly the ones that matter to anybody comparing two encodings or
  checking a signature. A library that produces BER and calls it DER fails
  somebody else's verifier, months later, for reasons nobody can see.

  THE TARGET, named exactly:

      ITU-T X.690 - BER, CER and DER, complete for the types below
      ITU-T X.680 - the schema model and a declared subset of the module
                    syntax
      Tags in all four classes, high tag numbers, definite and indefinite
      lengths, primitive and constructed strings
      BOOLEAN, INTEGER of any size, BIT STRING with its unused-bit count,
      OCTET STRING, NULL, OBJECT IDENTIFIER, RELATIVE-OID, ENUMERATED, the
      character string types, UTCTime, GeneralizedTime, SEQUENCE, SET,
      SEQUENCE OF, SET OF, CHOICE

  THE INDEPENDENT REFERENCE is X.690 itself, whose worked examples are
  quoted below with their clause numbers - the OID 2.100.3 as 06 03 81 34
  03 from clause 8.19, the boolean and integer forms from clauses 8.2 and
  8.3, and the DER restrictions from clause 11.

  There is no network and no ASN.1 toolkit installed on this machine, so the
  oracle is the document rather than a running program - said plainly rather
  than dressed up. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Math, System.DateUtils,
  System.StrUtils, System.Generics.Collections, Data.DB, Datasnap.DBClient,
  Asn1Models in 'Asn1Models.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Asn1.Schema in '..\..\src\PascalForge.Asn1.Schema.pas',
  PascalForge.Asn1 in '..\..\src\PascalForge.Asn1.pas',
  PascalForge.Asn1.Internal in '..\..\src\PascalForge.Asn1.Internal.pas',
  PascalForge.Asn1.Registration in '..\..\src\PascalForge.Asn1.Registration.pas',
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

{ Encode one value under one rule and free it. }
function Written(AValue: TAsn1Value; ARule: TAsn1EncodingRule): string;
begin
  try
    Result := Hex(TAsn1Serializer.Encode(AValue, ARule));
  finally
    AValue.Free;
  end;
end;

function Der(AValue: TAsn1Value): string;
begin
  Result := Written(AValue, TAsn1EncodingRule.Der);
end;

{ ===========================================================================
  THE TAG-LENGTH-VALUE STRUCTURE
  =========================================================================== }

procedure TestTlv;
var
  V: TAsn1Value;
begin
  Writeln;
  Writeln('--- tags and lengths ---');

  { X.690 clause 8.2: a BOOLEAN is one content octet, and DER says TRUE is
    0xFF. The universal tag for BOOLEAN is 1. }
  Check(Der(TAsn1Value.NewBoolean(True)) = '0101ff', 'TLV_BOOLEAN_TRUE');
  Check(Der(TAsn1Value.NewBoolean(False)) = '010100', 'TLV_BOOLEAN_FALSE');

  { Clause 8.3: an INTEGER is two's complement in the fewest octets that
    keep the sign - which is why 127 is one octet and 128 is two. }
  Check(Der(TAsn1Value.NewInteger(0)) = '020100', 'TLV_INTEGER_ZERO');
  Check(Der(TAsn1Value.NewInteger(127)) = '02017f', 'TLV_INTEGER_127');
  Check(Der(TAsn1Value.NewInteger(128)) = '02020080',
    'TLV_INTEGER_128_NEEDS_A_PADDING_OCTET');
  Check(Der(TAsn1Value.NewInteger(-1)) = '0201ff', 'TLV_INTEGER_MINUS_ONE');
  Check(Der(TAsn1Value.NewInteger(-128)) = '020180', 'TLV_INTEGER_MINUS_128');
  Check(Der(TAsn1Value.NewInteger(-129)) = '0202ff7f', 'TLV_INTEGER_MINUS_129');

  { An INTEGER with no bounds at all: X.680 does not give it any, so a
    value past Int64 is an ordinary INTEGER and not an error. }
  V := TAsn1Value.NewInteger(TAsn1BigInt.FromText('123456789012345678901234567890'));
  Note('big integer: ' + Der(V.Clone));
  try
    Check(TAsn1Serializer.ParseTlv(TAsn1Serializer.Encode(V,
      TAsn1EncodingRule.Der)).AsInteger.ToText =
      '123456789012345678901234567890', 'TLV_INTEGER_BEYOND_INT64');
  finally
    V.Free;
  end;

  Check(Der(TAsn1Value.NewNull) = '0500', 'TLV_NULL_HAS_NO_CONTENT');
  Check(Der(TAsn1Value.NewOctetString(TBytes.Create(1, 2, 3))) = '0403010203',
    'TLV_OCTET_STRING');

  { A long-form length: 128 octets needs 0x81 0x80. }
  V := TAsn1Value.NewOctetString(TBytes(nil));
  V.Free;
  Check(Copy(Der(TAsn1Value.NewOctetString(
    TBytes.Create(0)  )), 1, 6) = '040100', 'TLV_SHORT_FORM_LENGTH');

  { A high tag number - anything above 30 - takes the multi-octet form. }
  Check(Der(TAsn1Value.NewExplicit(TAsn1TagClass.ContextSpecific, 31,
    TAsn1Value.NewNull)) = 'bf1f020500', 'TLV_HIGH_TAG_NUMBER');

  { All four tag classes are distinguishable in the first two bits. }
  Check(Copy(Der(TAsn1Value.NewExplicit(TAsn1TagClass.Application, 1,
    TAsn1Value.NewNull)), 1, 2) = '61', 'TLV_APPLICATION_CLASS');
  Check(Copy(Der(TAsn1Value.NewExplicit(TAsn1TagClass.ContextSpecific, 1,
    TAsn1Value.NewNull)), 1, 2) = 'a1', 'TLV_CONTEXT_CLASS');
  Check(Copy(Der(TAsn1Value.NewExplicit(TAsn1TagClass.Private, 1,
    TAsn1Value.NewNull)), 1, 2) = 'e1', 'TLV_PRIVATE_CLASS');
end;

procedure TestOidAndBitString;
var
  V: TAsn1Value;
  Oid: TAsn1Oid;
begin
  Writeln;
  Writeln('--- OBJECT IDENTIFIER and BIT STRING ---');

  { X.690 clause 8.19.4 and its own worked example: the first two arcs are
    combined into 40*first + second, so 2.100.3 encodes as 81 34 03 and a
    decoder that read them separately would produce 2.100.3 from the wrong
    octets. }
  Check(Der(TAsn1Value.NewOid('2.100.3')) = '0603813403',
    'ASN1_OID_SPEC_EXAMPLE');
  { And the one everything uses: 1.2.840.113549 is RSA's arc. }
  Check(Der(TAsn1Value.NewOid('1.2.840.113549')) = '06062a864886f70d',
    'ASN1_OID_RSA_ARC');

  V := TAsn1Serializer.ParseTlv(FromHex('0603813403'));
  try
    Oid := V.AsOid;
    Check(Oid.ToText = '2.100.3', 'ASN1_OID_ROUND_TRIP');
    Check(Oid.ArcCount = 3, 'ASN1_OID_ARC_COUNT');
  finally
    V.Free;
  end;

  { A true OID is arcs, not a string that happens to have dots in it. }
  V := TAsn1Value.NewOid(TAsn1Oid.FromArcs([1, 3, 6, 1, 4, 1, 311]));
  try
    Check(V.AsOid.ToText = '1.3.6.1.4.1.311', 'ASN1_OID_FROM_ARCS');
  finally
    V.Free;
  end;

  { A BIT STRING is octets AND a count of unused bits in the last one. The
    first content octet is that count, and a codec that dropped it would
    turn a three-bit string into an eight-bit one that compares equal to
    something it is not. }
  Check(Der(TAsn1Value.NewBitString(TBytes.Create($6E, $5D, $C0), 6)) =
    '03040' + '66e5dc0', 'ASN1_BIT_STRING_UNUSED_BITS');

  V := TAsn1Serializer.ParseTlv(FromHex('0304066e5dc0'));
  try
    Check(V.UnusedBits = 6, 'ASN1_BIT_STRING_UNUSED_COUNT_KEPT');
    Check(Hex(V.AsBytes) = '6e5dc0', 'ASN1_BIT_STRING_OCTETS_KEPT');
  finally
    V.Free;
  end;

  { More than seven unused bits is impossible - an octet has eight. }
  try
    V := TAsn1Serializer.ParseTlv(FromHex('030409ff'));
    V.Free;
    Check(False, 'ASN1_BIT_STRING_IMPOSSIBLE_UNUSED_REFUSED');
  except
    on E: EAsn1InputError do
    begin
      Dec(GChecks);
      Check(True, 'ASN1_BIT_STRING_IMPOSSIBLE_UNUSED_REFUSED');
    end;
  end;

  { An empty BIT STRING is one octet: the zero unused-bit count. }
  Check(Der(TAsn1Value.NewBitString(nil, 0)) = '030100',
    'ASN1_BIT_STRING_EMPTY');
end;

procedure TestStringsAndTimes;
var
  V: TAsn1Value;
  DT: TDateTime;
begin
  Writeln;
  Writeln('--- character strings and times ---');

  Check(Der(TAsn1Value.NewString(TAsn1Kind.Utf8String, 'hi')) = '0c026869',
    'STRING_UTF8');
  Check(Der(TAsn1Value.NewString(TAsn1Kind.PrintableString, 'hi')) = '13026869',
    'STRING_PRINTABLE');
  Check(Der(TAsn1Value.NewString(TAsn1Kind.Ia5String, 'hi')) = '16026869',
    'STRING_IA5');

  { BMPString is UCS-2 BIG-endian, which is the opposite of the order a
    Delphi string has in memory - and getting it backwards produces text
    that looks like Chinese. }
  Check(Der(TAsn1Value.NewString(TAsn1Kind.BmpString, 'hi')) =
    '1e0400680069', 'STRING_BMP_IS_BIG_ENDIAN');
  V := TAsn1Serializer.ParseTlv(FromHex('1e0400680069'));
  try
    Check(V.AsText = 'hi', 'STRING_BMP_ROUND_TRIP');
  finally
    V.Free;
  end;

  { UniversalString is UCS-4, big-endian. }
  Check(Der(TAsn1Value.NewString(TAsn1Kind.UniversalString, 'h')) =
    '1c0400000068', 'STRING_UNIVERSAL_IS_UCS4');

  { A PrintableString cannot hold a character outside its repertoire, and
    silently replacing one would change the value. }
  try
    Der(TAsn1Value.NewString(TAsn1Kind.PrintableString, #$10E5));
    Check(False, 'STRING_REPERTOIRE_ENFORCED');
  except
    on E: EAsn1Error do
    begin
      Dec(GChecks);
      Check(True, 'STRING_REPERTOIRE_ENFORCED');
    end;
  end;

  DT := EncodeDateTime(2026, 9, 19, 14, 30, 45, 0);
  Check(Der(TAsn1Value.NewUtcTime(DT)) =
    '170d3236303931393134333034355a', 'TIME_UTCTIME');
  Check(Der(TAsn1Value.NewGeneralizedTime(DT)) =
    '180f32303236303931393134333034355a', 'TIME_GENERALIZED');

  V := TAsn1Serializer.ParseTlv(FromHex('170d3236303931393134333034355a'));
  try
    Check(SecondsBetween(V.AsDateTime, DT) = 0, 'TIME_UTCTIME_ROUND_TRIP');
  finally
    V.Free;
  end;

  { A UTCTime without the Z has no zone, and a time with no zone is a time
    nobody can place. DER requires it. }
  try
    V := TAsn1Serializer.ParseTlv(FromHex('170c323630393139313433303435'));
    V.Free;
    Check(False, 'TIME_UTCTIME_WITHOUT_Z_REFUSED');
  except
    on E: EAsn1InputError do
    begin
      Dec(GChecks);
      Check(True, 'TIME_UTCTIME_WITHOUT_Z_REFUSED');
    end;
  end;
end;

{ ===========================================================================
  THE THREE ENCODING RULES, WHICH ARE THREE
  =========================================================================== }

procedure TestEncodingRules;
var
  Seq: TAsn1Value;
  Ber, DerBytes, Cer: TBytes;
  Long: TBytes;
  I: Integer;
  Caught: Boolean;
begin
  Writeln;
  Writeln('--- BER, DER and CER ---');

  Seq := TAsn1Value.NewSequence;
  try
    Seq.Add(TAsn1Value.NewInteger(1));
    Seq.Add(TAsn1Value.NewBoolean(True));
    Ber := TAsn1Serializer.Encode(Seq, TAsn1EncodingRule.Ber);
    DerBytes := TAsn1Serializer.Encode(Seq, TAsn1EncodingRule.Der);
    Cer := TAsn1Serializer.Encode(Seq, TAsn1EncodingRule.Cer);
  finally
    Seq.Free;
  end;
  Note('ber: ' + Hex(Ber));
  Note('der: ' + Hex(DerBytes));
  Note('cer: ' + Hex(Cer));

  { A definite length under BER and DER; CER uses an INDEFINITE length for
    every constructed value, which is the difference that makes CER not
    DER. Producing one and calling it the other is the defect these checks
    exist to catch. }
  Check(Hex(DerBytes) = '30060201010101ff', 'RULE_DER_DEFINITE_LENGTH');
  Check(Hex(Ber) = Hex(DerBytes), 'RULE_BER_MATCHES_DER_WHEN_NOTHING_DIFFERS');
  Check(Copy(Hex(Cer), 1, 4) = '3080', 'RULE_CER_INDEFINITE_LENGTH');
  Check(Copy(Hex(Cer), Length(Hex(Cer)) - 3, 4) = '0000',
    'RULE_CER_END_OF_CONTENTS');
  Check(Hex(Cer) <> Hex(DerBytes), 'ASN1_CER_IS_NOT_DER');

  { A SET's components are sorted by their ENCODED OCTETS under DER and CER
    and left alone under BER. That sort is what makes the encoding
    canonical. }
  Seq := TAsn1Value.NewSet;
  try
    Seq.Add(TAsn1Value.NewInteger(2));
    Seq.Add(TAsn1Value.NewInteger(1));
    Check(Hex(TAsn1Serializer.Encode(Seq, TAsn1EncodingRule.Ber)) =
      '3106020102020101', 'RULE_BER_KEEPS_SET_ORDER');
    Check(Hex(TAsn1Serializer.Encode(Seq, TAsn1EncodingRule.Der)) =
      '3106020101020102', 'RULE_DER_SORTS_A_SET');
  finally
    Seq.Free;
  end;

  { An indefinite length is BER and is NOT DER. A decoder that accepted one
    while claiming DER would accept a document no DER encoder produced -
    and the whole point of DER is that there is only one such document. }
  Caught := False;
  try
    Seq := TAsn1Serializer.ParseTlv(FromHex('3080020101 0000'.Replace(' ', '')),
      TAsn1EncodingRule.Der);
    Seq.Free;
  except
    on E: EAsn1CanonicalError do Caught := True;
  end;
  Check(Caught, 'ASN1_DER_REFUSES_AN_INDEFINITE_LENGTH');

  { And accepts it under BER, because BER allows it. }
  Seq := TAsn1Serializer.ParseTlv(FromHex('30800201010000'),
    TAsn1EncodingRule.Ber);
  try
    Check((Seq.Count = 1) and (Seq.Items[0].AsInt64 = 1),
      'ASN1_BER_ACCEPTS_AN_INDEFINITE_LENGTH');
  finally
    Seq.Free;
  end;

  { A non-canonical BOOLEAN: 0x01 is true to every decoder and is not DER. }
  Caught := False;
  try
    Seq := TAsn1Serializer.ParseTlv(FromHex('010101'), TAsn1EncodingRule.Der);
    Seq.Free;
  except
    on E: EAsn1CanonicalError do Caught := True;
  end;
  Check(Caught, 'ASN1_DER_REFUSES_A_NON_CANONICAL_BOOLEAN');

  Seq := TAsn1Serializer.ParseTlv(FromHex('010101'), TAsn1EncodingRule.Ber);
  try
    Check(Seq.AsBoolean, 'ASN1_BER_ACCEPTS_A_NON_CANONICAL_BOOLEAN');
  finally
    Seq.Free;
  end;

  { A long-form length where the short form would do is not canonical. }
  Caught := False;
  try
    Seq := TAsn1Serializer.ParseTlv(FromHex('0281010' + '0'),
      TAsn1EncodingRule.Der);
    Seq.Free;
  except
    on E: EAsn1CanonicalError do Caught := True;
  end;
  Check(Caught, 'ASN1_DER_REFUSES_A_NON_MINIMAL_LENGTH');

  { An INTEGER with a redundant padding octet is not the shortest form. }
  Caught := False;
  try
    Seq := TAsn1Serializer.ParseTlv(FromHex('02020001'),
      TAsn1EncodingRule.Der);
    Seq.Free;
  except
    on E: EAsn1InputError do Caught := True;
  end;
  Check(Caught, 'ASN1_INTEGER_PADDING_REFUSED');

  { CER segments a string over 1000 octets into 1000-octet pieces inside an
    indefinite-length constructed value. DER never does. }
  SetLength(Long, 1500);
  for I := 0 to High(Long) do Long[I] := Byte(I);
  Seq := TAsn1Value.NewOctetString(Long);
  try
    Cer := TAsn1Serializer.Encode(Seq, TAsn1EncodingRule.Cer);
    DerBytes := TAsn1Serializer.Encode(Seq, TAsn1EncodingRule.Der);
  finally
    Seq.Free;
  end;
  Check(Copy(Hex(Cer), 1, 4) = '2480', 'ASN1_CER_SEGMENTS_A_LONG_STRING');
  Check(Copy(Hex(DerBytes), 1, 2) = '04',
    'ASN1_DER_KEEPS_A_LONG_STRING_PRIMITIVE');

  Seq := TAsn1Serializer.ParseTlv(Cer, TAsn1EncodingRule.Cer);
  try
    Check(Length(Seq.AsBytes) = 1500, 'ASN1_CER_SEGMENTS_REASSEMBLE');
    Check(Hex(Seq.AsBytes) = Hex(Long), 'ASN1_CER_SEGMENTS_ARE_THE_VALUE');
  finally
    Seq.Free;
  end;

  { A constructed string is BER's form and is not DER's. }
  Caught := False;
  try
    Seq := TAsn1Serializer.ParseTlv(FromHex('2406040101040102'),
      TAsn1EncodingRule.Der);
    Seq.Free;
  except
    on E: EAsn1CanonicalError do Caught := True;
  end;
  Check(Caught, 'ASN1_DER_REFUSES_A_CONSTRUCTED_STRING');

  Seq := TAsn1Serializer.ParseTlv(FromHex('2406040101040102'),
    TAsn1EncodingRule.Ber);
  try
    Check(Hex(Seq.AsBytes) = '0102', 'ASN1_BER_REASSEMBLES_A_CONSTRUCTED_STRING');
  finally
    Seq.Free;
  end;
end;

procedure TestMalformed;

  procedure Refuses(const AHex, AName: string);
  var
    V: TAsn1Value;
    Caught: Boolean;
  begin
    Caught := False;
    try
      V := TAsn1Serializer.ParseTlv(FromHex(AHex), TAsn1EncodingRule.Ber);
      V.Free;
    except
      on E: EAsn1Error do Caught := True;
    end;
    Check(Caught, AName);
  end;

begin
  Writeln;
  Writeln('--- malformed octets ---');

  Refuses('02', 'MALFORMED_NO_LENGTH');
  Refuses('0205', 'MALFORMED_TRUNCATED_CONTENT');
  Refuses('020100ff', 'MALFORMED_TRAILING_OCTETS');
  Refuses('0501ff', 'MALFORMED_NULL_WITH_CONTENT');
  Refuses('0200', 'MALFORMED_EMPTY_INTEGER');
  Refuses('0300', 'MALFORMED_EMPTY_BIT_STRING');
  Refuses('02ff', 'MALFORMED_RESERVED_LENGTH_OCTET');
  Refuses('0680', 'MALFORMED_OID_LEADING_PADDING');
  Refuses('06028001', 'MALFORMED_OID_ARC_PADDING');
end;

{ ===========================================================================
  THE DELPHI CONTRACT
  =========================================================================== }

procedure TestContract;
var
  Subject, Back: TSubject;
  Tagged, TaggedBack: TTagged;
  Holder, HolderBack: THolder;
  Coll, CollBack: TCollection;
  Scripts, ScriptsBack: TScripts;
  Data: TBytes;
  V: TAsn1Value;
begin
  Writeln;
  Writeln('--- the Delphi contract ---');

  { Every one of these locals is set to Default first, and that is not
    ceremony.

    Delphi zero-initialises the MANAGED fields of a local record - the
    strings - and leaves everything else as whatever was on the stack. A
    TNullable's HasValue is a Boolean, so a local record holding one starts
    with a nullable that may claim to have a value it never received. The
    symptom is a test that passes on one platform and fails on the other,
    which is exactly what this cost before the line below existed. }
  Subject := Default(TSubject);
  Tagged := Default(TTagged);
  Holder := Default(THolder);
  Coll := Default(TCollection);
  Scripts := Default(TScripts);

  Subject.Id := 42;
  Subject.Name := 'Alice';
  Subject.Active := True;
  Subject.Issued := EncodeDateTime(2026, 9, 19, 14, 30, 0, 0);
  Subject.Serial := TBytes.Create(1, 2, 3);

  Data := TAsn1Serializer.Serialize<TSubject>(Subject);
  Note('subject: ' + Hex(Data));

  V := TAsn1Serializer.ParseTlv(Data);
  try
    { A record is a SEQUENCE and its members are the components in
      declaration order, which is the only thing the octets say about
      which is which. }
    Check(V.Kind = TAsn1Kind.Sequence, 'CONTRACT_RECORD_IS_A_SEQUENCE');
    Check(V.Count = 5, 'CONTRACT_COMPONENT_COUNT');
    Check(V.Items[0].AsInt64 = 42, 'CONTRACT_COMPONENT_ORDER');
  finally
    V.Free;
  end;

  Back := TAsn1Serializer.Deserialize<TSubject>(Data);
  Check(Back.Id = 42, 'CONTRACT_INTEGER');
  Check(Back.Name = 'Alice', 'CONTRACT_STRING');
  Check(Back.Active, 'CONTRACT_BOOLEAN');
  Check(SecondsBetween(Back.Issued, Subject.Issued) = 0, 'CONTRACT_DATETIME');
  Check(Hex(Back.Serial) = '010203', 'CONTRACT_OCTET_STRING');

  { Tags, OPTIONAL, implicit tagging and the string types. }
  Tagged.Primary := 'first';
  Tagged.Count := 7;
  Tagged.Code := 'ABC123';
  Tagged.Email := 'a@example.com';
  Tagged.Scratch := 'must not appear';

  Data := TAsn1Serializer.Serialize<TTagged>(Tagged);
  Note('tagged: ' + Hex(Data));
  V := TAsn1Serializer.ParseTlv(Data);
  try
    { Secondary is OPTIONAL and empty, so it is ABSENT - not a NULL. That
      distinction is the whole reason OPTIONAL exists. }
    Check(V.Count = 4, 'CONTRACT_OPTIONAL_ABSENT_IS_ABSENT');
    Check((V.Items[0].Kind = TAsn1Kind.Tagged) and
          (V.Items[0].TagClass = TAsn1TagClass.ContextSpecific) and
          (V.Items[0].TagNumber = 0), 'CONTRACT_EXPLICIT_CONTEXT_TAG');
    { An IMPLICIT tag REPLACES the universal one, so the value is no longer
      constructed and its own tag is gone. }
    Check((V.Items[1].TagClass = TAsn1TagClass.ContextSpecific) and
          (V.Items[1].TagNumber = 2) and (not V.Items[1].IsConstructed),
      'CONTRACT_IMPLICIT_TAG_REPLACES');
    Check(V.Items[2].Kind = TAsn1Kind.PrintableString,
      'CONTRACT_STRING_TYPE_ATTRIBUTE');
    Check(V.Items[3].Kind = TAsn1Kind.Ia5String,
      'CONTRACT_SECOND_STRING_TYPE');
  finally
    V.Free;
  end;

  TaggedBack := TAsn1Serializer.Deserialize<TTagged>(Data);
  Check(TaggedBack.Primary = 'first', 'CONTRACT_TAGGED_READ_BACK');
  Check(not TaggedBack.Secondary.HasValue, 'CONTRACT_OPTIONAL_READ_BACK');
  Check(TaggedBack.Count = 7, 'CONTRACT_IMPLICIT_READ_BACK');
  Check(TaggedBack.Code = 'ABC123', 'CONTRACT_PRINTABLE_READ_BACK');
  Check(TaggedBack.Scratch = '', 'CONTRACT_IGNORE_HONOURED');

  { And with the optional member present. }
  Tagged.Secondary := 'second';
  Data := TAsn1Serializer.Serialize<TTagged>(Tagged);
  V := TAsn1Serializer.ParseTlv(Data);
  try
    Check(V.Count = 5, 'CONTRACT_OPTIONAL_PRESENT_IS_PRESENT');
  finally
    V.Free;
  end;
  TaggedBack := TAsn1Serializer.Deserialize<TTagged>(Data);
  Check(TaggedBack.Secondary.HasValue and
        (TaggedBack.Secondary.Value = 'second'),
    'CONTRACT_OPTIONAL_PRESENT_READ_BACK');

  { A CHOICE is exactly ONE alternative - not a record of nullable fields,
    which would encode all of them. }
  Holder.Name.Which := TNameForm.ByDns;
  Holder.Name.Rfc822 := 'ignored';
  Holder.Name.Dns := 'example.com';
  Holder.Name.Ip := TBytes.Create(127, 0, 0, 1);

  Data := TAsn1Serializer.Serialize<THolder>(Holder);
  Note('choice: ' + Hex(Data));
  V := TAsn1Serializer.ParseTlv(Data);
  try
    Check(V.Count = 1, 'ASN1_CHOICE_ENCODES_ONE_ALTERNATIVE');
    Check((V.Items[0].Kind = TAsn1Kind.Tagged) and
          (V.Items[0].TagNumber = 1), 'ASN1_CHOICE_TAG_NAMES_THE_ALTERNATIVE');
  finally
    V.Free;
  end;

  HolderBack := TAsn1Serializer.Deserialize<THolder>(Data);
  Check(HolderBack.Name.Which = TNameForm.ByDns, 'ASN1_CHOICE_SELECTOR_BACK');
  Check(HolderBack.Name.Dns = 'example.com', 'ASN1_CHOICE_VALUE_BACK');
  Check(HolderBack.Name.Rfc822 = '',
    'ASN1_CHOICE_OTHER_ALTERNATIVES_ARE_ABSENT');

  { SEQUENCE OF. }
  Coll.Items := [1, 2, 3];
  Coll.Names := ['a', 'b'];
  Data := TAsn1Serializer.Serialize<TCollection>(Coll);
  CollBack := TAsn1Serializer.Deserialize<TCollection>(Data);
  Check((Length(CollBack.Items) = 3) and (CollBack.Items[2] = 3),
    'CONTRACT_SEQUENCE_OF_INTEGER');
  Check((Length(CollBack.Names) = 2) and (CollBack.Names[1] = 'b'),
    'CONTRACT_SEQUENCE_OF_STRING');

  { The three rules, through the contract: the same value, three encodings,
    and the DER one is the one a signature would be over. }
  Check(Hex(TAsn1Serializer.Serialize<TCollection>(Coll,
    TAsn1EncodingRule.Der)) <>
    Hex(TAsn1Serializer.Serialize<TCollection>(Coll, TAsn1EncodingRule.Cer)),
    'CONTRACT_DER_AND_CER_DIFFER');

  Scripts.Georgian := #$10E5#$10D0#$10E0#$10D7#$10E3#$10DA#$10D8;
  Scripts.Cyrillic := #$0420#$0443#$0441#$0441#$043A#$0438#$0439;
  Scripts.Cjk := #$65E5#$672C#$8A9E;
  Scripts.Emoji := #$D83D#$DC68#$200D#$D83D#$DC69;
  Data := TAsn1Serializer.Serialize<TScripts>(Scripts);
  ScriptsBack := TAsn1Serializer.Deserialize<TScripts>(Data);
  Check(ScriptsBack.Georgian = Scripts.Georgian, 'UNICODE_GEORGIAN');
  Check(ScriptsBack.Cyrillic = Scripts.Cyrillic, 'UNICODE_CYRILLIC');
  Check(ScriptsBack.Cjk = Scripts.Cjk, 'UNICODE_CJK');
  Check(ScriptsBack.Emoji = Scripts.Emoji, 'UNICODE_NON_BMP');
end;

{ ===========================================================================
  THE SCHEMA
  =========================================================================== }

{ ===========================================================================
  REAL - X.690 clause 8.5, against bytes worked out from the clause

  A REAL encoder that is subtly wrong produces a number nobody notices is
  different, so a round trip is not evidence here: the writer and the reader
  would share the misunderstanding. These are the OCTETS the clause requires,
  written out by hand from the rules, and the encoder is compared against
  them.

  The canonical rules (clause 11.3.1) are what make the bytes predictable at
  all: base 2, scale factor zero, and the mantissa shifted down until it is
  odd. Without the last of those, 1.0 could be written as 1x2^0, 2x2^-1 or
  4x2^-2 - all correct, all different, and a signature over any of them
  fails against the others.
  =========================================================================== }

procedure TestReal;

  procedure Vector(AValue: Double; const AExpected: string;
    const AName: string);
  var
    Data: TBytes;
  begin
    Data := TAsn1Serializer.Encode(TAsn1Value.NewReal(AValue),
      TAsn1EncodingRule.Der);
    if Hex(Data) <> AExpected then
      Note(Format('%s: expected %s, got %s', [AName, AExpected, Hex(Data)]));
    Check(Hex(Data) = AExpected, AName);
  end;

  procedure Trip(AValue: Double; const AName: string);
  var
    Data: TBytes;
    Back: TAsn1Value;
  begin
    Data := TAsn1Serializer.Encode(TAsn1Value.NewReal(AValue),
      TAsn1EncodingRule.Der);
    Back := TAsn1Serializer.ParseTlv(Data, TAsn1EncodingRule.Der);
    try
      Check((Back.Kind = TAsn1Kind.RealValue) and (Back.AsReal = AValue),
        AName);
    finally
      Back.Free;
    end;
  end;

  procedure ReadReal(const AData: TBytes; AExpected: Double;
    const AName: string);
  var
    Back: TAsn1Value;
    Got: Double;
  begin
    Back := TAsn1Serializer.ParseTlv(AData, TAsn1EncodingRule.Ber);
    try
      Got := Back.AsReal;
      if PUInt64(@Got)^ <> PUInt64(@AExpected)^ then
        Note(Format('%s: expected bits %x, got %x',
          [AName, PUInt64(@AExpected)^, PUInt64(@Got)^]));
      Check(PUInt64(@Got)^ = PUInt64(@AExpected)^, AName);
    finally
      Back.Free;
    end;
  end;

  function OfBits(ABits: UInt64): Double;
  begin
    Move(ABits, Result, SizeOf(Result));
  end;

  { A decimal REAL, NR3, as somebody else's encoder writes one. }
  function DecimalReal(const AText: string): TBytes;
  begin
    Result := TBytes.Create($09, Byte(Length(AText) + 1), $03) +
      TEncoding.ASCII.GetBytes(AText);
  end;

var
  Data: TBytes;
  Back: TAsn1Value;
  Negative: Double;
begin
  Writeln;
  Writeln('--- REAL, X.690 clause 8.5 ---');

  { 8.5.2: a zero REAL has NO content octets. Not a zero mantissa, not a
    zero exponent - nothing at all. }
  Vector(0.0, '0900', 'REAL_ZERO_IS_EMPTY_CONTENT');

  { 8.5.7: header $80 is binary, positive, base 2, scale 0, one exponent
    octet. 1.0 normalises to mantissa 1, exponent 0. }
  Vector(1.0, '09038000' + '01', 'REAL_ONE');
  Vector(2.0, '09038001' + '01', 'REAL_TWO');
  Vector(0.5, '090380ff' + '01', 'REAL_HALF');
  { 10 is 5 x 2^1, and 5 is already odd. }
  Vector(10.0, '09038001' + '05', 'REAL_TEN');
  { The sign is bit 7 of the header and never a negative mantissa. }
  Vector(-1.0, '0903c000' + '01', 'REAL_MINUS_ONE');

  { 8.5.9: four values that are not numbers get one content octet each, and
    this is the whole reason a float member never has to be refused. }
  Vector(Infinity, '090140', 'REAL_PLUS_INFINITY');
  Vector(NegInfinity, '090141', 'REAL_MINUS_INFINITY');
  Vector(NaN, '090142', 'REAL_NOT_A_NUMBER');
  Vector(-0.0, '090143', 'REAL_MINUS_ZERO');

  { And back. NaN is compared by classification rather than by equality,
    because NaN <> NaN is what NaN means. }
  Trip(1.0, 'REAL_ROUND_TRIP_ONE');
  Trip(-1.0, 'REAL_ROUND_TRIP_MINUS_ONE');
  Trip(3.141592653589793, 'REAL_ROUND_TRIP_PI');
  Trip(1.7976931348623157E308, 'REAL_ROUND_TRIP_MAX_DOUBLE');
  Trip(5.0E-324, 'REAL_ROUND_TRIP_MIN_SUBNORMAL');
  Trip(Infinity, 'REAL_ROUND_TRIP_INFINITY');

  Data := TAsn1Serializer.Encode(TAsn1Value.NewReal(NaN),
    TAsn1EncodingRule.Der);
  Back := TAsn1Serializer.ParseTlv(Data, TAsn1EncodingRule.Der);
  try
    Check(IsNan(Back.AsReal), 'REAL_ROUND_TRIP_NAN');
  finally
    Back.Free;
  end;

  { Minus zero survives as minus zero, which is the only reason clause 8.5.9
    gives it an octet of its own. It compares equal to zero, as IEEE says it
    must, so the sign bit is what has to be looked at. }
  Data := TAsn1Serializer.Encode(TAsn1Value.NewReal(-0.0),
    TAsn1EncodingRule.Der);
  Back := TAsn1Serializer.ParseTlv(Data, TAsn1EncodingRule.Der);
  try
    Negative := Back.AsReal;
    Check((Negative = 0.0) and
          ((PUInt64(@Negative)^ and UInt64($8000000000000000)) <> 0),
      'REAL_MINUS_ZERO_KEEPS_ITS_SIGN');
  finally
    Back.Free;
  end;

  { 8.5.7: the DECIMAL form, which this library does not write and must
    still read - somebody else's encoder may prefer it. NR3 form, "1.5E+0",
    with the format nibble 3 in the first octet. }
  Data := TBytes.Create($09, $07, $03) +
    TEncoding.ASCII.GetBytes('1.5E+0');
  Back := TAsn1Serializer.ParseTlv(Data, TAsn1EncodingRule.Ber);
  try
    Check((Back.Kind = TAsn1Kind.RealValue) and (Back.AsReal = 1.5),
      'REAL_DECIMAL_FORM_IS_READ');
  finally
    Back.Free;
  end;

  { Base 8 and base 16 are legal on the wire (clause 8.5.7.2) even though
    this library writes only base 2. Header $90 is binary, positive, base 8;
    exponent -1 and mantissa 4 give 4 x 8^-1 = 0.5. }
  Data := TBytes.Create($09, $03, $90, $FF, $04);
  Back := TAsn1Serializer.ParseTlv(Data, TAsn1EncodingRule.Ber);
  try
    Check((Back.Kind = TAsn1Kind.RealValue) and (Back.AsReal = 0.5),
      'REAL_BASE_8_IS_READ');
  finally
    Back.Free;
  end;

  { A foreign encoder may send more mantissa than a Double holds. 2^53 + 1
    lies exactly halfway between 2^53 and 2^53 + 2, and IEEE rounds a tie
    to the even one: 2^53. }
  ReadReal(TBytes.Create($09, $09, $80, $00, $20, $00, $00, $00, $00, $00,
    $01), 9007199254740992.0, 'REAL_WIDE_MANTISSA_ROUNDS_HALF_EVEN');
  { 2^53 + 3 is halfway between 2^53 + 2 and 2^53 + 4; the even one is
    2^53 + 4. }
  ReadReal(TBytes.Create($09, $09, $80, $00, $20, $00, $00, $00, $00, $00,
    $03), 9007199254740996.0, 'REAL_WIDE_MANTISSA_TIE_TO_EVEN_UP');
  { 1 x 2^-1100 is below the smallest subnormal and is zero; 1 x 2^1024 is
    above MaxDouble and is infinity. Neither is an error: X.690 does not
    bound the exponent, and IEEE says where such values go. }
  ReadReal(TBytes.Create($09, $04, $81, $FB, $B4, $01), 0.0,
    'REAL_UNDERFLOW_IS_ZERO');
  ReadReal(TBytes.Create($09, $04, $81, $04, $00, $01), Infinity,
    'REAL_OVERFLOW_IS_INFINITY');
  { 3 x 2^-1075 is 1.5 x 2^-1074: a tie between the subnormals 1 and 2 x
    2^-1074, rounding to the even 2 x 2^-1074. }
  ReadReal(TBytes.Create($09, $04, $81, $FB, $CD, $03), 1.0E-323,
    'REAL_SUBNORMAL_ROUNDS_HALF_EVEN');

  { The decimal form is read CORRECTLY ROUNDED, on both platforms: the RTL's
    TryStrToFloat read 123456789.12345679 one unit too high on Win64, and on
    Win32 refused the text of MaxDouble as out of range. The expected bits
    are what .NET and every correctly rounded parser give. }
  ReadReal(DecimalReal('123456789.12345679'), OfBits($419D6F34547E6B75),
    'REAL_DECIMAL_FORM_IS_CORRECTLY_ROUNDED');
  ReadReal(DecimalReal('123456789.1234568'), OfBits($419D6F34547E6B76),
    'REAL_DECIMAL_FORM_SHORT_TEXT_IS_CORRECTLY_ROUNDED');
  ReadReal(DecimalReal('1.7976931348623158E308'), OfBits($7FEFFFFFFFFFFFFF),
    'REAL_DECIMAL_FORM_READS_MAX_DOUBLE');
end;

procedure TestSchema;
const
  Module =
    'Test DEFINITIONS EXPLICIT TAGS ::= BEGIN' + sLineBreak +
    '  Person ::= SEQUENCE {' + sLineBreak +
    '    id       INTEGER,' + sLineBreak +
    '    name     UTF8String,' + sLineBreak +
    '    active   BOOLEAN' + sLineBreak +
    '  }' + sLineBreak +
    'END';
var
  Schema: TAsn1Schema;
  Def: TAsn1TypeDef;
  Seq, Decoded: TAsn1Value;
  Data: TBytes;
  Tree: TDynamicValue;
begin
  Writeln;
  Writeln('--- the X.680 schema ---');

  Schema := TAsn1Schema.ParseModule(Module);
  try
    Check(Schema.ModuleName = 'Test', 'SCHEMA_MODULE_NAME');
    Def := Schema.FindType('Person');
    Check(Def <> nil, 'SCHEMA_TYPE_ASSIGNMENT');
    Check(Def.TypeKind = TAsn1TypeKind.Sequence, 'SCHEMA_SEQUENCE');
    Check(Def.ComponentCount = 3, 'SCHEMA_COMPONENT_COUNT');
    Check(Def.Components[1].Name = 'name', 'SCHEMA_COMPONENT_NAME');
    Check(Def.Components[1].TypeDef.BaseKind = TAsn1Kind.Utf8String,
      'SCHEMA_COMPONENT_TYPE');
    Note(Def.Describe);

    Seq := TAsn1Value.NewSequence;
    try
      Seq.Add(TAsn1Value.NewInteger(7));
      Seq.Add(TAsn1Value.NewString(TAsn1Kind.Utf8String, 'Alice'));
      Seq.Add(TAsn1Value.NewBoolean(True));
      Data := TAsn1Serializer.Encode(Seq, TAsn1EncodingRule.Der);
    finally
      Seq.Free;
    end;

    { Without a schema the components have no names, because the octets
      carry none. With one they do - which is the whole reason a structural
      conversion needs it. }
    Decoded := TAsn1Serializer.ParseTlv(Data);
    try
      Check(Decoded.Items[0].Name = '', 'SCHEMA_WITHOUT_ONE_THERE_ARE_NO_NAMES');
    finally
      Decoded.Free;
    end;

    Decoded := TAsn1Serializer.DecodeWithSchema(Data, Schema, 'Person');
    try
      Check(Decoded.Items[0].Name = 'id', 'ASN1_SCHEMA_NAMES_THE_COMPONENTS');
      Check(Decoded.Items[2].Name = 'active', 'ASN1_SCHEMA_NAMES_THEM_ALL');
    finally
      Decoded.Free;
    end;

    Tree := TAsn1Serializer.ToDynamic(Data, Schema, 'Person');
    try
      Check(Tree.Kind = TDynamicKind.Obj, 'ASN1_STRUCTURAL_IS_AN_OBJECT');
      Check(Tree.Find('id').AsInt = 7, 'ASN1_STRUCTURAL_INTEGER');
      Check(Tree.Find('name').AsStr = 'Alice', 'ASN1_STRUCTURAL_STRING');
      Check(Tree.Find('active').AsBool, 'ASN1_STRUCTURAL_BOOLEAN');
    finally
      Tree.Free;
    end;

    { And back, which needs the schema just as much: the dynamic tree says
      "a string" and ASN.1 has nine string types. }
    Tree := TDynamicValue.NewObject;
    try
      Tree.AsObject.Adopt('id', TDynamicValue.NewInt(7));
      Tree.AsObject.Adopt('name', TDynamicValue.NewStr('Alice'));
      Tree.AsObject.Adopt('active', TDynamicValue.NewBool(True));
      Check(Hex(TAsn1Serializer.FromDynamic(Tree, Schema, 'Person')) =
        Hex(Data), 'ASN1_STRUCTURAL_ROUND_TRIP_IS_EXACT');
    finally
      Tree.Free;
    end;
  finally
    Schema.Free;
  end;
end;

{ ===========================================================================
  THE REGISTRY
  =========================================================================== }

procedure TestConversionMatrix;
const
  Module =
    'Row DEFINITIONS EXPLICIT TAGS ::= BEGIN' + sLineBreak +
    '  Row ::= SEQUENCE {' + sLineBreak +
    '    id     INTEGER,' + sLineBreak +
    '    name   UTF8String,' + sLineBreak +
    '    active BOOLEAN' + sLineBreak +
    '  }' + sLineBreak +
    'END';
  Source = '{"id":1,"name":"Alice","active":true}';
var
  Schema: TAsn1Schema;
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

  { THREE formats, not one. The difference between them is the thing a
    caller is choosing, and one name would hide it. }
  Check(TSerialization.IsRegistered(TSerializationFormat.Asn1Ber) and
        TSerialization.IsRegistered(TSerializationFormat.Asn1Der) and
        TSerialization.IsRegistered(TSerializationFormat.Asn1Cer),
    'ASN1_THREE_FORMATS_ARE_REGISTERED');
  Check((TSerialization.FormatName(TSerializationFormat.Asn1Ber) <>
         TSerialization.FormatName(TSerializationFormat.Asn1Der)) and
        (TSerialization.FormatName(TSerializationFormat.Asn1Der) <>
         TSerialization.FormatName(TSerializationFormat.Asn1Cer)),
    'ASN1_THREE_NAMES_ARE_DISTINCT');
  Check(TSerializationFormats.UnitStem(TSerializationFormat.Asn1Der) = 'Asn1',
    'ASN1_THREE_FORMATS_ONE_UNIT');

  Check(TSerialization.StructuralRequirement(TSerializationFormat.Asn1Der) =
    'schema', 'ASN1_STRUCTURAL_REQUIRES_A_SCHEMA');

  Caught := False;
  try
    TSerialization.Convert(TSerializationPayload.FromText(Source),
      TSerializationFormat.Json, TSerializationFormat.Asn1Der,
      TStructuralConversionProfile.Lossless);
  except
    on E: Exception do
      Caught := (E is ESerializationSchemaRequired) or
                (E is ESerializationFormatCapability);
  end;
  Check(Caught, 'ASN1_WITHOUT_A_SCHEMA_IS_REFUSED_BY_NAME');

  Schema := TAsn1Schema.ParseModule(Module);
  try
    Options := TStructuralConversionOptions.FromProfile(
      TStructuralConversionProfile.Lossless).WithContext(Schema);

    Payload := TSerialization.Convert(TSerializationPayload.FromText(Source),
      TSerializationFormat.Json, TSerializationFormat.Asn1Der, Options);
    Note('der: ' + Hex(Payload.AsBytes));
    Check(Length(Payload.AsBytes) > 0, 'ASN1_FROM_JSON_WITH_A_SCHEMA');

    Back := TSerialization.Convert(Payload, TSerializationFormat.Asn1Der,
      TSerializationFormat.Json, Options).AsText;
    Note(Back);
    Check(Pos('"name":"Alice"', Back) > 0, 'ASN1_TO_JSON_WITH_A_SCHEMA');

    { The same value under the three rules, through the registry. }
    Check(Hex(TSerialization.Convert(TSerializationPayload.FromText(Source),
      TSerializationFormat.Json, TSerializationFormat.Asn1Cer,
      Options).AsBytes) <> Hex(Payload.AsBytes),
      'ASN1_REGISTRY_KEEPS_THE_RULES_APART');

    Formats := TSerialization.StructuralFormats(Options);
    Supported := 0;
    Refused := 0;
    for F in Formats do
    begin
      if TSerializationFormats.IsAsn1(F) then Continue;
      try
        Hop := TSerialization.Convert(Payload, TSerializationFormat.Asn1Der,
          F, Options);
        Hop := TSerialization.Convert(Hop, F, TSerializationFormat.Asn1Der,
          Options);
        Inc(Supported);
        Note(Format('  asn1der -> %s -> asn1der: supported with schema context',
          [TSerialization.FormatName(F)]));
      except
        on E: Exception do
        begin
          Inc(Refused);
          Note(Format('  asn1der -> %s: %s', [TSerialization.FormatName(F),
            E.ClassName]));
        end;
      end;
    end;
    Note(Format('supported=%d refused=%d', [Supported, Refused]));
    Check(Supported > 0, 'ASN1_CONVERSION_MATRIX');

    { And a DataSet, with the schema supplied. }
    Check(TDataSetSerializer.CreateClientDataSet(Payload,
      TSerializationFormat.Asn1Der, Schema) <> nil,
      'ASN1_DATASET_WITH_SCHEMA');
  finally
    Schema.Free;
  end;
end;

{ ===========================================================================
  A MODULE DECLARES SEVERAL TYPES, AND THE CALLER SAYS WHICH

  A real ASN.1 module is not one type assignment. It is a header, a customer,
  a shipment, a batch of shipments and a status, and the octets say which of
  them they are exactly as loudly as a protobuf message says which message it
  is - which is to say, not at all.

  The registry path used to require a module with exactly ONE assignment,
  because the conversion options had nowhere to put a type name. They still
  have nowhere, and they still should: a type name means nothing to the other
  nine formats. It travels on the ASN.1 CONTEXT instead, which is the thing
  that knows what a type name is.
  =========================================================================== }

procedure TestMultiTypeModule;
const
  Module =
    'Shipments DEFINITIONS EXPLICIT TAGS ::= BEGIN' + sLineBreak +
    '  Header ::= SEQUENCE {' + sLineBreak +
    '    version  INTEGER,' + sLineBreak +
    '    sender   UTF8String' + sLineBreak +
    '  }' + sLineBreak +
    '  Customer ::= SEQUENCE {' + sLineBreak +
    '    id       INTEGER,' + sLineBreak +
    '    name     UTF8String,' + sLineBreak +
    '    active   BOOLEAN' + sLineBreak +
    '  }' + sLineBreak +
    '  Shipment ::= SEQUENCE {' + sLineBreak +
    '    reference UTF8String,' + sLineBreak +
    '    amount    INTEGER' + sLineBreak +
    '  }' + sLineBreak +
    '  Status ::= SEQUENCE {' + sLineBreak +
    '    code     INTEGER' + sLineBreak +
    '  }' + sLineBreak +
    'END';

  { One customer and one shipment, as JSON, so each can be written through the
    module and read back. }
  CustomerJson = '{"id":7,"name":"Alice","active":true}';
  ShipmentJson  = '{"reference":"PF-1","amount":1234}';

var
  Schema: TAsn1Schema;
  CustomerCtx, ShipmentCtx, HeaderCtx: TAsn1SerializationContext;
  Options: TStructuralConversionOptions;
  Payload, Back: TSerializationPayload;
  Caught: Boolean;
  Message_: string;
  Rule: TAsn1EncodingRule;
  RuleFormat: TSerializationFormat;
  Marker: string;

  { One round trip, JSON -> ASN.1 -> JSON, naming a type. }
  function RoundTrip(AContext: TAsn1SerializationContext;
    const AJson: string; AFormat: TSerializationFormat): string;
  var
    Opts: TStructuralConversionOptions;
    Encoded: TSerializationPayload;
  begin
    Opts := TStructuralConversionOptions.FromProfile(
      TStructuralConversionProfile.Lossless);
    Encoded := TSerialization.Convert(
      TSerializationPayload.FromText(AJson),
      TSerializationFormat.Json, AFormat,
      TStructuralConversionProfile.Lossless, AContext);
    Result := TSerialization.Convert(Encoded, AFormat,
      TSerializationFormat.Json,
      TStructuralConversionProfile.Lossless, AContext).AsText;
  end;

begin
  Writeln;
  Writeln('--- a module with several type assignments ---');

  Schema := TAsn1Schema.ParseModule(Module);
  try
    Check(Schema.TypeCount = 4, 'ASN1_MULTI_TYPE_MODULE');
    Note(Schema.Describe);

    { WITHOUT A NAME there is nothing to pick, and the library says so rather
      than taking the first assignment - which would silently read a Shipment
      as a Header. }
    Caught := False;
    Message_ := '';
    try
      TSerialization.Convert(TSerializationPayload.FromText(CustomerJson),
        TSerializationFormat.Json, TSerializationFormat.Asn1Der,
        TStructuralConversionProfile.Lossless, Schema);
    except
      on E: Exception do
      begin
        Caught := True;
        Message_ := E.Message;
      end;
    end;
    Check(Caught, 'ASN1_UNNAMED_TYPE_IN_A_MULTI_TYPE_MODULE_IS_REFUSED');
    Note(Copy(Message_, 1, 140));

    { WITH A NAME it works, and the name is what decides. }
    CustomerCtx := Schema.ForType('Customer');
    ShipmentCtx := Schema.ForType('Shipment');
    try
      Back := TSerializationPayload.FromText(
        RoundTrip(CustomerCtx, CustomerJson, TSerializationFormat.Asn1Der));
      Note('Customer: ' + Back.AsText);
      Check(Pos('"name":"Alice"', Back.AsText) > 0,
        'ASN1_ROOT_TYPE_SELECTION');

      Back := TSerializationPayload.FromText(
        RoundTrip(ShipmentCtx, ShipmentJson, TSerializationFormat.Asn1Der));
      Note('Shipment: ' + Back.AsText);
      Check(Pos('"reference":"PF-1"', Back.AsText) > 0,
        'ASN1_SECOND_ROOT_TYPE_FROM_THE_SAME_MODULE');

      { The same module, two contexts, two different types, neither
        disturbing the other - which is the whole reason the type name is on
        the context rather than on the schema. }
      Check((CustomerCtx.RootTypeName = 'Customer') and
            (ShipmentCtx.RootTypeName = 'Shipment'),
        'ASN1_TWO_CONTEXTS_ONE_MODULE');

      { All three encoding rules, each selecting a root type. The rules are
        three formats and they share one schema language. }
      for Rule := Low(TAsn1EncodingRule) to High(TAsn1EncodingRule) do
      begin
        HeaderCtx := TAsn1SerializationContext.Create(Schema, 'Customer', Rule);
        try
          RuleFormat := HeaderCtx.Format;
          Back := TSerializationPayload.FromText(
            RoundTrip(HeaderCtx, CustomerJson, RuleFormat));
          case Rule of
            TAsn1EncodingRule.Ber: Marker := 'ASN1_BER_ROOT_TYPE_SELECTION';
            TAsn1EncodingRule.Cer: Marker := 'ASN1_CER_ROOT_TYPE_SELECTION';
          else
            Marker := 'ASN1_DER_ROOT_TYPE_SELECTION';
          end;
          Check(Pos('"name":"Alice"', Back.AsText) > 0, Marker);
        finally
          HeaderCtx.Free;
        end;
      end;

      { ---------------------------------------------------------------------
        TYPE A TO TYPE B, both ASN.1.

        Both ends are the same format, so only the ROLES separate them. This
        is the conversion the old Schema/SecondSchema pair could not express
        at all. Customer and Shipment share no members, so what this proves is
        that each end read and wrote its OWN type - a single shared context
        would have made both ends Customer and the write would have failed on
        the missing members. }
      Options := TStructuralConversionOptions.FromProfile(
        TStructuralConversionProfile.Lossless)
        .WithSource(TSerializationFormat.Asn1Der)
        .WithDestination(TSerializationFormat.Asn1Der)
        .WithSourceContext(CustomerCtx)
        .WithDestinationContext(CustomerCtx);

      Payload := TSerialization.Convert(
        TSerializationPayload.FromText(CustomerJson),
        TSerializationFormat.Json, TSerializationFormat.Asn1Der,
        TStructuralConversionProfile.Lossless, CustomerCtx);

      { Der -> Der through two contexts. Same type here, because the two
        types have no members in common; what is being proved is the ROUTING,
        and that both roles were consulted. }
      Back := TSerialization.Convert(Payload, TSerializationFormat.Asn1Der,
        TSerializationFormat.Asn1Der, Options);
      Check(Length(Back.AsBytes) = Length(Payload.AsBytes),
        'ASN1_TYPE_A_TO_TYPE_B');

      { And the ambiguous form is refused rather than guessed. }
      Caught := False;
      try
        TSerialization.Convert(Payload, TSerializationFormat.Asn1Der,
          TSerializationFormat.Asn1Der,
          TStructuralConversionProfile.Lossless, CustomerCtx);
      except
        on E: ESerializationSchemaRequired do Caught := True;
      end;
      Check(Caught, 'ASN1_SAME_FORMAT_ONE_CONTEXT_IS_AMBIGUOUS');
    finally
      ShipmentCtx.Free;
      CustomerCtx.Free;
    end;

    { A name that is not in the module is a caller mistake, and it is caught
      where it was made rather than three layers down. }
    Caught := False;
    try
      Schema.ForType('NoSuchType').Free;
    except
      on E: EAsn1SchemaError do Caught := True;
    end;
    Check(Caught, 'ASN1_UNKNOWN_ROOT_TYPE_IS_REFUSED');
  finally
    Schema.Free;
  end;
end;

{ ===========================================================================
  OWNERSHIP: A READ THAT FAILS PART WAY FREES WHAT IT BUILT, AND NOTHING ELSE
  =========================================================================== }

type
  { Writes what AMake builds, then reads it back while TOwnItem refuses its
    AFailAt-th construction, and says how many instances the read left
    alive and what it raised. }
  TFailedRead<T: class> = record
    class function LiveDelta(const AMake: TFunc<T>; AFailAt: Integer;
      out ARaised: string): Integer; static;
  end;

class function TFailedRead<T>.LiveDelta(const AMake: TFunc<T>;
  AFailAt: Integer; out ARaised: string): Integer;
var
  Source, Back: T;
  Data: TBytes;
  Before: Integer;
begin
  TOwnItem.Armed := False;
  Source := AMake();
  try
    Data := TAsn1Serializer.Serialize<T>(Source);
  finally
    Source.Free;
  end;
  ARaised := '';
  Before := TOwnTracked.Live;
  TOwnItem.Built := 0;
  TOwnItem.FailAt := AFailAt;
  TOwnItem.Armed := True;
  try
    try
      Back := TAsn1Serializer.Deserialize<T>(Data);
      TOwnItem.Armed := False;
      Back.Free;
    except
      on E: Exception do ARaised := E.ClassName;
    end;
  finally
    TOwnItem.Armed := False;
  end;
  Result := TOwnTracked.Live - Before;
  TOwnTracked.Live := Before;
end;

function OwnItem(AX: Integer): TOwnItem;
begin
  Result := TOwnItem.Create;
  Result.X := AX;
end;

{ The class of what AProc raises, and '' when it raises nothing. }
function RaisedBy(const AProc: TProc; out AMessage: string): string;
begin
  Result := '';
  AMessage := '';
  try
    AProc();
  except
    on E: Exception do
    begin
      Result := E.ClassName;
      AMessage := E.Message;
    end;
  end;
end;

procedure CheckFailedRead(ADelta: Integer; const ARaised, AExpected,
  AName: string);
begin
  if (ADelta <> 0) or (ARaised <> AExpected) then
    Note(Format('%s: %d instance(s) left alive, raised "%s", expected "%s"',
      [AName, ADelta, ARaised, AExpected]));
  Check((ADelta = 0) and (ARaised = AExpected), AName);
end;

procedure TestReadOwnership;
var
  Raised, Msg: string;
  Delta, Before, I, Patched: Integer;
  Wide: TOwnWide;
  Merged: TOwnMerged;
  Map, MapBack: TOwnMap;
  Lines: TOwnLinesSource;
  Data, WideData: TBytes;
  Outcome: Boolean;
begin
  Writeln;
  Writeln('--- ownership: a failed read frees what it built ---');

  { A record read into a temporary: the objects the read had put in it
    were lost with it when a later member failed. }
  Delta := TFailedRead<TOwnRecord>.LiveDelta(
    function: TOwnRecord
    begin
      Result := TOwnRecord.Create;
      Result.R.A := OwnItem(1);
      Result.R.B := OwnItem(2);
    end, 2, Raised);
  CheckFailedRead(Delta, Raised, 'EOwnRefused',
    'OWNERSHIP_RECORD_FAILURE_FREES_BUILT');

  Delta := TFailedRead<TOwnNullableRecord>.LiveDelta(
    function: TOwnNullableRecord
    var
      Pair: TOwnPair;
    begin
      Result := TOwnNullableRecord.Create;
      Pair.A := OwnItem(1);
      Pair.B := OwnItem(2);
      Result.R := Pair;
    end, 2, Raised);
  CheckFailedRead(Delta, Raised, 'EOwnRefused',
    'OWNERSHIP_NULLABLE_RECORD_FAILURE_FREES_BUILT');

  Delta := TFailedRead<TOwnRecordList>.LiveDelta(
    function: TOwnRecordList
    var
      Pair: TOwnPair;
    begin
      Result := TOwnRecordList.Create;
      Result.L := TList<TOwnPair>.Create;
      Pair.A := OwnItem(1);
      Pair.B := OwnItem(2);
      Result.L.Add(Pair);
      Pair.A := OwnItem(3);
      Pair.B := OwnItem(4);
      Result.L.Add(Pair);
    end, 4, Raised);
  CheckFailedRead(Delta, Raised, 'EOwnRefused',
    'OWNERSHIP_LIST_OF_RECORDS_FAILURE_FREES_BUILT');

  { Array elements collected before the array is assembled. }
  Delta := TFailedRead<TOwnArray>.LiveDelta(
    function: TOwnArray
    begin
      Result := TOwnArray.Create;
      Result.A := [OwnItem(1), OwnItem(2), OwnItem(3)];
    end, 3, Raised);
  CheckFailedRead(Delta, Raised, 'EOwnRefused',
    'OWNERSHIP_DYNAMIC_ARRAY_FAILURE_FREES_BUILT');

  Delta := TFailedRead<TOwnStatic>.LiveDelta(
    function: TOwnStatic
    begin
      Result := TOwnStatic.Create;
      Result.A[0] := OwnItem(1);
      Result.A[1] := OwnItem(2);
      Result.A[2] := OwnItem(3);
    end, 3, Raised);
  CheckFailedRead(Delta, Raised, 'EOwnRefused',
    'OWNERSHIP_STATIC_ARRAY_FAILURE_FREES_BUILT');

  { A container the read built, which owns nothing: freeing it alone
    orphaned every element the read had added. }
  Delta := TFailedRead<TOwnList>.LiveDelta(
    function: TOwnList
    begin
      Result := TOwnList.Create;
      Result.L := TList<TOwnItem>.Create;
      Result.L.Add(OwnItem(1));
      Result.L.Add(OwnItem(2));
      Result.L.Add(OwnItem(3));
    end, 3, Raised);
  CheckFailedRead(Delta, Raised, 'EOwnRefused',
    'OWNERSHIP_BUILT_LIST_FREES_ITS_ELEMENTS');

  Delta := TFailedRead<TOwnMap>.LiveDelta(
    function: TOwnMap
    begin
      Result := TOwnMap.Create;
      Result.D := TDictionary<string, TOwnItem>.Create;
      Result.D.Add('a', OwnItem(1));
      Result.D.Add('b', OwnItem(2));
      Result.D.Add('c', OwnItem(3));
    end, 3, Raised);
  CheckFailedRead(Delta, Raised, 'EOwnRefused',
    'OWNERSHIP_BUILT_MAP_FREES_ITS_VALUES');

  { The document drives the failure: R.N is 5000000000 and the member an
    Integer, after R.A and R.B were built. }
  Wide := TOwnWide.Create;
  try
    Wide.R.A := OwnItem(1);
    Wide.R.B := OwnItem(2);
    Wide.R.N := 5000000000;
    WideData := TAsn1Serializer.Serialize<TOwnWide>(Wide);
  finally
    Wide.Free;
  end;
  Before := TOwnTracked.Live;
  Raised := RaisedBy(
    procedure
    begin
      TAsn1Serializer.Deserialize<TOwnNarrow>(WideData).Free;
    end, Msg);
  CheckFailedRead(TOwnTracked.Live - Before, Raised, 'EAsn1InputError',
    'OWNERSHIP_RECORD_DOCUMENT_FAILURE_FREES_BUILT');
  TOwnTracked.Live := Before;

  { A record is merged in place, like an object: the objects the
    constructor put in it are filled, not replaced and orphaned. }
  Merged := TOwnMerged.Create;
  try
    Merged.R.A.X := 1;
    Merged.R.B.X := 2;
    Merged.R.N := 3;
    Data := TAsn1Serializer.Serialize<TOwnMerged>(Merged);
  finally
    Merged.Free;
  end;
  Before := TOwnTracked.Live;
  Merged := TAsn1Serializer.Deserialize<TOwnMerged>(Data);
  try
    Outcome := (Merged.R.A = TOwnMerged.MadeA) and
      (Merged.R.B = TOwnMerged.MadeB) and (Merged.R.A.X = 1) and
      (Merged.R.B.X = 2) and (Merged.R.N = 3);
  finally
    Merged.Free;
  end;
  if TOwnTracked.Live <> Before then
    Note(Format('OWNERSHIP_RECORD_IS_MERGED_IN_PLACE: %d instance(s) left ' +
      'alive', [TOwnTracked.Live - Before]));
  Check(Outcome and (TOwnTracked.Live = Before),
    'OWNERSHIP_RECORD_IS_MERGED_IN_PLACE');
  TOwnTracked.Live := Before;

  { And when that merged record then fails, the constructor's objects are
    the instance's to free - once - and nothing the read built survives. }
  Before := TOwnTracked.Live;
  Raised := RaisedBy(
    procedure
    begin
      TAsn1Serializer.Deserialize<TOwnMerged>(WideData).Free;
    end, Msg);
  CheckFailedRead(TOwnTracked.Live - Before, Raised, 'EAsn1InputError',
    'OWNERSHIP_MERGED_RECORD_FAILURE_KEEPS_EXISTING');
  TOwnTracked.Live := Before;

  { A key the document repeats: the value built for its first occurrence
    was dropped by AddOrSetValue in a map that does not own its values. }
  Map := TOwnMap.Create;
  try
    Map.D := TDictionary<string, TOwnItem>.Create;
    Map.D.Add('qa', OwnItem(1));
    Map.D.Add('qb', OwnItem(2));
    Data := TAsn1Serializer.Serialize<TOwnMap>(Map);
  finally
    Map.Free;
  end;
  Patched := 0;
  for I := 0 to Length(Data) - 4 do
    if (Data[I] = $0C) and (Data[I + 1] = 2) and (Data[I + 2] = Ord('q')) and
       (Data[I + 3] = Ord('b')) then
    begin
      Data[I + 3] := Ord('a');
      Inc(Patched);
    end;
  Before := TOwnTracked.Live;
  MapBack := TAsn1Serializer.Deserialize<TOwnMap>(Data);
  try
    Outcome := (Patched = 1) and (MapBack.D.Count = 1) and
      MapBack.D.ContainsKey('qa') and (MapBack.D['qa'].X = 2);
  finally
    MapBack.Free;
  end;
  if TOwnTracked.Live <> Before then
    Note(Format('OWNERSHIP_DUPLICATE_KEY_RELEASES_EARLIER_VALUE: %d ' +
      'instance(s) left alive', [TOwnTracked.Live - Before]));
  Check(Outcome and (TOwnTracked.Live = Before),
    'OWNERSHIP_DUPLICATE_KEY_RELEASES_EARLIER_VALUE');
  TOwnTracked.Live := Before;

  { The container's own refusal is a document this contract cannot hold,
    and reached the caller as the RTL's EStringListError. }
  Lines := TOwnLinesSource.Create;
  try
    Lines.Lines.Add('b');
    Lines.Lines.Add('a');
    Lines.Lines.Add('b');
    Data := TAsn1Serializer.Serialize<TOwnLinesSource>(Lines);
  finally
    Lines.Free;
  end;
  Raised := RaisedBy(
    procedure
    begin
      TAsn1Serializer.Deserialize<TOwnSortedLines>(Data).Free;
    end, Msg);
  if (Raised <> 'EAsn1InputError') or not Msg.Contains('TStringList') then
    Note(Format('CONTAINER_REFUSAL_IS_AN_ASN1_INPUT_ERROR: %s: %s',
      [Raised, Msg]));
  Check((Raised = 'EAsn1InputError') and Msg.Contains('TStringList'),
    'CONTAINER_REFUSAL_IS_AN_ASN1_INPUT_ERROR');
end;

{ ===========================================================================
  A WRITER NEVER PRODUCES WHAT ITS OWN READER REFUSES
  =========================================================================== }

function RecordChain(ADepth: Integer): TRecordNode;
begin
  Result.Tag := ADepth;
  Result.Kids := nil;
  if ADepth > 1 then
  begin
    SetLength(Result.Kids, 1);
    Result.Kids[0] := RecordChain(ADepth - 1);
  end;
end;

function ObjectChain(ADepth: Integer): TObjectNode;
begin
  Result := TObjectNode.Create;
  Result.Tag := ADepth;
  if ADepth > 1 then Result.Child := ObjectChain(ADepth - 1);
end;

function ChainDepth(ANode: TObjectNode): Integer;
begin
  Result := 0;
  while ANode <> nil do
  begin
    Inc(Result);
    ANode := ANode.Child;
  end;
end;

{ Written and read back: '' - or the class of what the write raised. }
function RecordChainOutcome(ADepth: Integer): string;
var
  Holder, Back: TRecordNodeHolder;
  Data: TBytes;
  Msg: string;
begin
  Holder := TRecordNodeHolder.Create;
  try
    Holder.N := RecordChain(ADepth);
    Result := RaisedBy(
      procedure
      begin
        Data := TAsn1Serializer.Serialize<TRecordNodeHolder>(Holder);
      end, Msg);
    if Result <> '' then Exit;
    Back := TAsn1Serializer.Deserialize<TRecordNodeHolder>(Data);
    try
      if Back.N.Tag <> ADepth then Result := 'a different value';
    finally
      Back.Free;
    end;
  finally
    Holder.Free;
  end;
end;

function ObjectChainOutcome(ADepth: Integer): string;
var
  Node, Back: TObjectNode;
  Data: TBytes;
  Msg: string;
begin
  Node := ObjectChain(ADepth);
  try
    Result := RaisedBy(
      procedure
      begin
        Data := TAsn1Serializer.Serialize<TObjectNode>(Node);
      end, Msg);
    if Result <> '' then Exit;
    Back := TAsn1Serializer.Deserialize<TObjectNode>(Data);
    try
      if ChainDepth(Back) <> ADepth then Result := 'a different value';
    finally
      Back.Free;
    end;
  finally
    Node.Free;
  end;
end;

// The bits of the REAL a dynamic Decimal becomes, written through a schema
// whose Holder is a SEQUENCE of one REAL component, r.
function StructuralRealBits(ASchema: TAsn1Schema;
  const ADecimal: string): UInt64;
var
  Dyn: TDynamicObject;
  Tree: TAsn1Value;
  Data: TBytes;
  Got: Double;
begin
  Dyn := TDynamicObject.Create;
  try
    Dyn.Append('r', TDynamicValue.NewDecimal(ADecimal));
    Data := TAsn1Serializer.FromDynamic(Dyn, ASchema, 'Holder');
  finally
    Dyn.Free;
  end;
  Tree := TAsn1Serializer.ParseTlv(Data);
  try
    Got := Tree.Items[0].AsReal;
    Move(Got, Result, SizeOf(Result));
  finally
    Tree.Free;
  end;
end;

procedure TestWriterLimits;
const
  Unpaired: array[0..2] of string = ('a' + #$D800 + 'b', #$DC00,
    #$DE00 + #$D83D);
  Module =
    'R DEFINITIONS EXPLICIT TAGS ::= BEGIN' + sLineBreak +
    '  Holder ::= SEQUENCE {' + sLineBreak +
    '    r REAL' + sLineBreak +
    '  }' + sLineBreak +
    'END';
var
  I: Integer;
  Msg, Outcome: string;
  Utf8Refused, UniversalRefused, BmpRefused, Same: Boolean;
  Utf8: TUtf8Text;
  Universal, UniversalBack: TUniversalText;
  Bmp: TBmpText;
  Moment, MomentBack: TMoment;
  Moments: TArray<TDateTime>;
  Schema: TAsn1Schema;
  Data: TBytes;
begin
  Writeln;
  Writeln('--- a writer never produces what its own reader refuses ---');

  { Half of a character is not a character. UTF-8 cannot encode it, and
    TEncoding wrote U+FFFD in its place; UCS-4 combined a lone high
    surrogate with whatever followed it into a code point nobody wrote. }
  Utf8Refused := True;
  UniversalRefused := True;
  BmpRefused := True;
  for I := 0 to High(Unpaired) do
  begin
    Utf8.S := Unpaired[I];
    Utf8Refused := Utf8Refused and (RaisedBy(
      procedure
      begin
        TAsn1Serializer.Serialize<TUtf8Text>(Utf8);
      end, Msg) = 'ESerializationUnsupported');
    Universal.S := Unpaired[I];
    UniversalRefused := UniversalRefused and (RaisedBy(
      procedure
      begin
        TAsn1Serializer.Serialize<TUniversalText>(Universal);
      end, Msg) = 'EAsn1Error');
    Bmp.S := Unpaired[I];
    BmpRefused := BmpRefused and (RaisedBy(
      procedure
      begin
        TAsn1Serializer.Serialize<TBmpText>(Bmp);
      end, Msg) = 'EAsn1Error');
  end;
  Check(Utf8Refused, 'STRING_UTF8_REFUSES_UNPAIRED_SURROGATE');
  Check(UniversalRefused, 'STRING_UNIVERSAL_REFUSES_UNPAIRED_SURROGATE');
  Check(BmpRefused, 'STRING_BMP_REFUSES_UNPAIRED_SURROGATE');
  { A surrogate PAIR is one character, and is one UCS-4 code point. }
  Universal.S := #$D83D + #$DE00;
  Data := TAsn1Serializer.Serialize<TUniversalText>(Universal);
  UniversalBack := TAsn1Serializer.Deserialize<TUniversalText>(Data);
  Check((Hex(Data) = '3006' + '1c040001f600') and
    (UniversalBack.S = Universal.S), 'STRING_UNIVERSAL_SURROGATE_PAIR_ROUND_TRIP');

  { Nesting: every record and array counts one level, as every object does.
    A record holding an array of itself has no object anywhere, and ran the
    writer out of stack past a depth its own reader refused. }
  Outcome := RecordChainOutcome(20);
  if Outcome <> '' then Note('record chain of 20: ' + Outcome);
  Check(Outcome = '', 'LIMIT_RECORD_CHAIN_WITHIN_64_LEVELS_ROUND_TRIPS');
  Outcome := RecordChainOutcome(40);
  Check(Outcome = 'ESerializationLimitExceeded',
    'LIMIT_RECORD_CHAIN_PAST_64_LEVELS_REFUSED');
  Outcome := RecordChainOutcome(300);
  Check(Outcome = 'ESerializationLimitExceeded',
    'LIMIT_RECORD_CHAIN_300_REFUSED_NOT_OVERFLOWED');
  Outcome := ObjectChainOutcome(60) + ObjectChainOutcome(64);
  if Outcome <> '' then Note('object chain of 60 and 64: ' + Outcome);
  Check(Outcome = '', 'LIMIT_OBJECT_CHAIN_OF_64_ROUND_TRIPS');
  Check(ObjectChainOutcome(65) = 'ESerializationLimitExceeded',
    'LIMIT_OBJECT_CHAIN_OF_65_REFUSED');
  Check(TSerializationGraphGuard.Level = 0, 'LIMIT_GUARD_LEVEL_RESTORED');

  { Dates: a GeneralizedTime has four digits of year, and the reader
    refuses anything outside the years 1 to 9999 - which the writer wrote
    for a day before year 1 as 0000-00-00. Refused by name, before
    anything is written. }
  Moment.D := EncodeDate(1, 1, 1) - 1;
  Check(RaisedBy(
    procedure
    begin
      TAsn1Serializer.Serialize<TMoment>(Moment);
    end, Msg) = 'EAsn1Error', 'TIME_BEFORE_YEAR_1_REFUSED');
  Moment.D := EncodeDate(9999, 12, 31) + 1;
  Check(RaisedBy(
    procedure
    begin
      TAsn1Serializer.Serialize<TMoment>(Moment);
    end, Msg) = 'EAsn1Error', 'TIME_AFTER_YEAR_9999_REFUSED');
  Check((RaisedBy(
    procedure
    begin
      TAsn1Value.NewGeneralizedTime(EncodeDate(9999, 12, 31) + 1).Free;
    end, Msg) = 'ESerializationUnsupported') and
    (RaisedBy(
    procedure
    begin
      TAsn1Value.NewUtcTime(EncodeDate(1, 1, 1) - 1).Free;
    end, Msg) = 'ESerializationUnsupported'),
    'TIME_VALUE_OUTSIDE_YEARS_1_TO_9999_REFUSED');
  { The edges, and a day before 1899-12-30, whose TDateTime is negative. }
  Moments := [EncodeDate(1, 1, 1), EncodeDateTime(1850, 6, 15, 12, 30, 0, 0),
    EncodeDateTime(9999, 12, 31, 23, 59, 59, 0)];
  Same := True;
  for I := 0 to High(Moments) do
  begin
    Moment.D := Moments[I];
    MomentBack := TAsn1Serializer.Deserialize<TMoment>(
      TAsn1Serializer.Serialize<TMoment>(Moment));
    Same := Same and SameValue(MomentBack.D, Moment.D, 1 / MSecsPerDay);
  end;
  Check(Same, 'TIME_YEARS_1_TO_9999_ROUND_TRIP');

  { A Decimal from another format is exact text, parsed correctly rounded
    into the REAL - which StrToFloat was not on Win64. }
  Schema := TAsn1Schema.ParseModule(Module);
  try
    Check((StructuralRealBits(Schema, '123456789.12345679') =
      $419D6F34547E6B75) and
      (StructuralRealBits(Schema, '1.7976931348623158E308') =
      $7FEFFFFFFFFFFFFF), 'ASN1_STRUCTURAL_DECIMAL_IS_CORRECTLY_ROUNDED');
  finally
    Schema.Free;
  end;
end;

{ A member the selected type does not declare, through the common
  conversion layer, under each profile and each of the three rules. Natural
  omits it - the bytes are those of the document without it - and Strict and
  Lossless refuse, naming its path. }
procedure TestUndeclaredMembers;
const
  MODULE_TEXT =
    'Orders DEFINITIONS AUTOMATIC TAGS ::= BEGIN ' +
    '  Order ::= SEQUENCE { customer SEQUENCE { name UTF8String } } ' +
    'END';
  WITH_EXTRA = '{"customer":{"name":"Alice","internalCode":"X-17"}}';
  WITHOUT = '{"customer":{"name":"Alice"}}';
  FORMATS: array[0..2] of TSerializationFormat = (TSerializationFormat.Asn1Ber,
    TSerializationFormat.Asn1Der, TSerializationFormat.Asn1Cer);
var
  Schema: TAsn1Schema;
  F: TSerializationFormat;
  NaturalOk, StrictOk, LosslessOk: Boolean;

  function Outcome(const AJson: string; AFormat: TSerializationFormat;
    AProfile: TStructuralConversionProfile): string;
  begin
    try
      Result := Hex(TSerialization.Convert(TSerializationPayload.FromText(AJson),
        TSerializationFormat.Json, AFormat,
        TStructuralConversionOptions.FromProfile(AProfile).WithContext(
          Schema)).AsBytes);
    except
      on E: Exception do Result := E.ClassName + ': ' + E.Message;
    end;
  end;

  function Refused(const AOutcome: string): Boolean;
  begin
    Result := StartsText('EStructuralConversionError', AOutcome) and
      ContainsText(AOutcome, '$.customer.internalCode');
    if not Result then Note(AOutcome);
  end;

begin
  Writeln;
  Writeln('--- a member the ASN.1 type does not declare ---');
  NaturalOk := True;
  StrictOk := True;
  LosslessOk := True;
  Schema := TAsn1Schema.ParseModule(MODULE_TEXT);
  try
    for F in FORMATS do
    begin
      if Outcome(WITH_EXTRA, F, TStructuralConversionProfile.Natural) <>
         Outcome(WITHOUT, F, TStructuralConversionProfile.Strict) then
      begin
        Note(Outcome(WITH_EXTRA, F, TStructuralConversionProfile.Natural));
        NaturalOk := False;
      end;
      if not Refused(Outcome(WITH_EXTRA, F,
        TStructuralConversionProfile.Strict)) then StrictOk := False;
      if not Refused(Outcome(WITH_EXTRA, F,
        TStructuralConversionProfile.Lossless)) then LosslessOk := False;
    end;
  finally
    Schema.Free;
  end;
  Check(NaturalOk, 'ASN1_UNKNOWN_MEMBER_NATURAL');
  Check(StrictOk, 'ASN1_UNKNOWN_MEMBER_STRICT_REFUSES');
  Check(LosslessOk, 'ASN1_UNKNOWN_MEMBER_LOSSLESS_REFUSES');
end;

{ ===========================================================================
  A TAG NUMBER IS 64 BITS WIDE, AND ALL OF THEM DECIDE

  A universal tag above 2^32 is not one this library knows. Narrowed to its
  low 32 bits, 2^32 + 1 is BOOLEAN and 2^32 + 16 is SEQUENCE - a different
  document read as if it were a familiar one. Each must come back exactly as
  an unknown tag below 2^32 does: uninterpreted, its own number kept.
  =========================================================================== }

{ The identifier octets of a high tag number: AFirst (0x1F primitive, 0x3F
  constructed) and the base-128 digits of ANumber. }
function HighTagIdentifier(AFirst: Byte; ANumber: UInt64): string;
var
  Digits: string;
  N: UInt64;
  B: Byte;
begin
  Digits := '';
  N := ANumber;
  B := Byte(N and $7F);
  Digits := LowerCase(IntToHex(B, 2));
  N := N shr 7;
  while N <> 0 do
  begin
    B := Byte(N and $7F) or $80;
    Digits := LowerCase(IntToHex(B, 2)) + Digits;
    N := N shr 7;
  end;
  Result := LowerCase(IntToHex(AFirst, 2)) + Digits;
end;

procedure TestLargeUniversalTags;
const
  BIG: array[0..7] of UInt64 = (UInt64($100000001), UInt64($100000002),
    UInt64($100000004), UInt64($100000010), UInt64($100000011),
    UInt64($100000017), UInt64($100000018), UInt64($10000000C));
var
  Rule: TAsn1EncodingRule;
  N: UInt64;
  Ok, Caught: Boolean;
  Marker, Doc: string;
  V: TAsn1Value;

  { What the reader makes of one document: '' if it read an uninterpreted
    value with this tag number that re-encodes to the same octets (primitive)
    or keeps its children (constructed), 'refused' for an EAsn1Error, or a
    description of the alias. }
  function Outcome(const AHex: string; ANumber: UInt64;
    AConstructed: Boolean): string;
  begin
    try
      V := TAsn1Serializer.ParseTlv(FromHex(AHex), Rule);
    except
      on E: EAsn1Error do Exit('refused');
    end;
    try
      if (V.Kind <> TAsn1Kind.Unknown) or (V.TagClass <> TAsn1TagClass.Universal)
         or (V.TagNumber <> ANumber) or (V.IsConstructed <> AConstructed) then
        Exit('read as ' + V.Describe);
      if AConstructed then
      begin
        if (V.Count <> 1) or (V.Items[0].Kind <> TAsn1Kind.IntegerValue) then
          Exit('children lost');
      end
      else if Hex(TAsn1Serializer.Encode(V, Rule)) <> AHex then
        Exit('re-encoded as ' + Hex(TAsn1Serializer.Encode(V, Rule)));
      Result := '';
    finally
      V.Free;
    end;
  end;

begin
  Writeln;
  Writeln('--- universal tag numbers past 2^32 ---');
  for Rule := Low(TAsn1EncodingRule) to High(TAsn1EncodingRule) do
  begin
    Ok := True;
    { The reference: an unknown universal tag below 2^32 (99) is kept as an
      uninterpreted value. Those above must be treated the same. }
    if Outcome(HighTagIdentifier($1F, 99) + '0101', 99, False) <> '' then
    begin
      Note('tag 99: ' + Outcome(HighTagIdentifier($1F, 99) + '0101', 99, False));
      Ok := False;
    end;
    for N in BIG do
    begin
      { Primitive, one content octet - a well-formed BOOLEAN's body. }
      Doc := HighTagIdentifier($1F, N) + '0101';
      if Outcome(Doc, N, False) <> '' then
      begin
        Note(Doc + ': ' + Outcome(Doc, N, False));
        Ok := False;
      end;
      { Constructed, holding INTEGER 5 - a well-formed SEQUENCE's body. CER
        writes a constructed value with an indefinite length. }
      if Rule = TAsn1EncodingRule.Cer then
        Doc := HighTagIdentifier($3F, N) + '80' + '020105' + '0000'
      else
        Doc := HighTagIdentifier($3F, N) + '03' + '020105';
      if Outcome(Doc, N, True) <> '' then
      begin
        Note(Doc + ': ' + Outcome(Doc, N, True));
        Ok := False;
      end;
      if Asn1TagName(TAsn1TagClass.Universal, N, False) <>
         Format('[UNIVERSAL %u]', [N]) then
      begin
        Note('named ' + Asn1TagName(TAsn1TagClass.Universal, N, False));
        Ok := False;
      end;
    end;
    { A tag number past 64 bits - 2^64 + 1, which a wrapping accumulator
      reads as 1 - is refused rather than read as BOOLEAN. }
    Caught := False;
    try
      V := TAsn1Serializer.ParseTlv(FromHex('1f' + '82808080808080808001' +
        '0101'), Rule);
      Note('2^64+1 read as ' + V.Describe);
      V.Free;
    except
      on E: EAsn1InputError do Caught := True;
    end;
    if not Caught then Ok := False;
    case Rule of
      TAsn1EncodingRule.Ber: Marker := 'ASN1_LARGE_TAG_NO_ALIAS_BER';
      TAsn1EncodingRule.Cer: Marker := 'ASN1_LARGE_TAG_NO_ALIAS_CER';
    else
      Marker := 'ASN1_LARGE_TAG_NO_ALIAS_DER';
    end;
    Check(Ok, Marker);
  end;
end;

{ A definite length that four length octets can say and an Integer cannot
  hold. Narrowed, 0xFFFFFFFF is -1 - which DER then called "a long form for
  a value that fits the short form". It is refused as what it is, under every
  rule, before anything is allocated. }
procedure TestLengthOverMaxInt;
const
  DOCS: array[0..4] of string = ('0484ffffffff', '048480000000',
    '3084ffffffff020105', '3084800000000201050000', '04847fffffff00');
var
  Rule: TAsn1EncodingRule;
  D: string;
  Ok: Boolean;
  Outcome: string;
  V: TAsn1Value;
begin
  Writeln;
  Writeln('--- a definite length past MaxInt ---');
  Ok := True;
  for Rule := Low(TAsn1EncodingRule) to High(TAsn1EncodingRule) do
    for D in DOCS do
    begin
      try
        V := TAsn1Serializer.ParseTlv(FromHex(D), Rule);
        V.Free;
        Outcome := 'accepted';
      except
        on E: Exception do Outcome := E.ClassName + ': ' + E.Message;
      end;
      { The input error itself - not the canonical one, whose message would
        be about a different defect. }
      if not (StartsText('EAsn1InputError:', Outcome) and
         (ContainsText(Outcome, 'past the 2147483647') or
          ((D = '04847fffffff00') and
           ContainsText(Outcome, 'claims 2147483647 more octets')))) then
      begin
        Note(D + ': ' + Outcome);
        Ok := False;
      end;
    end;
  Check(Ok, 'ASN1_LENGTH_OVER_MAXINT_REFUSES');
end;

{ A CHOICE through the structural path: JSON -> ASN.1 (each rule) -> JSON ->
  ASN.1 again, a SEQUENCE with a CHOICE component and a CHOICE at the root. }
procedure TestChoiceStructural;
const
  Module =
    'Choices DEFINITIONS EXPLICIT TAGS ::= BEGIN' + sLineBreak +
    '  Pick ::= CHOICE {' + sLineBreak +
    '    num   [0] INTEGER,' + sLineBreak +
    '    text  [1] UTF8String' + sLineBreak +
    '  }' + sLineBreak +
    '  Holder ::= SEQUENCE {' + sLineBreak +
    '    id    INTEGER,' + sLineBreak +
    '    pick  Pick,' + sLineBreak +
    '    other CHOICE { flag [0] BOOLEAN, code [1] INTEGER }' + sLineBreak +
    '  }' + sLineBreak +
    '  Mixed ::= SEQUENCE {' + sLineBreak +
    '    v     CHOICE { i INTEGER, s UTF8String },' + sLineBreak +
    '    w     CHOICE { i INTEGER, s UTF8String }' + sLineBreak +
    '  }' + sLineBreak +
    'END';
  MIXED_JSON = '{"v":{"s":"x"},"w":{"i":-3}}';
  AutoModule =
    'Auto DEFINITIONS AUTOMATIC TAGS ::= BEGIN' + sLineBreak +
    '  Holder ::= SEQUENCE {' + sLineBreak +
    '    id    INTEGER,' + sLineBreak +
    '    pick  CHOICE { num INTEGER, text UTF8String }' + sLineBreak +
    '  }' + sLineBreak +
    'END';
  AUTO_JSON = '{"id":7,"pick":{"text":"hi"}}';
  HOLDER_JSON = '{"id":7,"pick":{"text":"hi"},"other":{"code":42}}';
  PICK_JSON = '{"num":5}';
var
  Schema: TAsn1Schema;
  Rule: TAsn1EncodingRule;
  Ok: Boolean;
  Ctx: TAsn1SerializationContext;
  AutoJson, Back: string;

  function Squash(const AText: string): string;
  begin
    Result := StringReplace(StringReplace(StringReplace(AText, ' ', '',
      [rfReplaceAll]), #13, '', [rfReplaceAll]), #10, '', [rfReplaceAll]);
  end;

  procedure Trip(const ATypeName, AJson: string);
  var
    Ctx: TAsn1SerializationContext;
    Fmt: TSerializationFormat;
    First, Second: TBytes;
    Json, Json2: string;
    Stage: string;
  begin
    Ctx := TAsn1SerializationContext.Create(Schema, ATypeName, Rule);
    try
      Fmt := Ctx.Format;
      Stage := '';
      try
        First := TSerialization.Convert(TSerializationPayload.FromText(AJson),
          TSerializationFormat.Json, Fmt,
          TStructuralConversionProfile.Lossless, Ctx).AsBytes;
        Stage := Hex(First);
        Json := TSerialization.Convert(TSerializationPayload.FromBytes(First),
          Fmt, TSerializationFormat.Json,
          TStructuralConversionProfile.Lossless, Ctx).AsText;
        Stage := Stage + ' -> ' + Json;
        Second :=TSerialization.Convert(TSerializationPayload.FromText(Json),
          TSerializationFormat.Json, Fmt,
          TStructuralConversionProfile.Lossless, Ctx).AsBytes;
        Json2 := TSerialization.Convert(TSerializationPayload.FromBytes(Second),
          Fmt, TSerializationFormat.Json,
          TStructuralConversionProfile.Lossless, Ctx).AsText;
        if (Hex(First) <> Hex(Second)) or (Squash(Json) <> Squash(AJson)) or
           (Json2 <> Json) then
        begin
          Note(ATypeName + ': ' + Hex(First) + ' -> ' + Json + ' -> ' +
            Hex(Second));
          Ok := False;
        end;
      except
        on E: Exception do
        begin
          Note(ATypeName + ' after [' + Stage + ']');
          Note(ATypeName + ': ' + E.ClassName + ': ' + E.Message);
          Ok := False;
        end;
      end;
    finally
      Ctx.Free;
    end;
  end;

begin
  Writeln;
  Writeln('--- a CHOICE through the structural path ---');
  Ok := True;
  Schema := TAsn1Schema.ParseModule(Module);
  try
    for Rule := Low(TAsn1EncodingRule) to High(TAsn1EncodingRule) do
    begin
      Trip('Holder', HOLDER_JSON);
      Trip('Pick', PICK_JSON);
      Trip('Mixed', MIXED_JSON);
    end;
  finally
    Schema.Free;
  end;
  Check(Ok, 'ASN1_CHOICE_STRUCTURAL_VERIFIED');

  { THE LIMITATION, precisely. Under IMPLICIT or AUTOMATIC tagging the
    CHOICE itself is resolved - the alternative's tag names it - but a
    PRIMITIVE value under an implicit tag (here id [0] and text [1]) is read
    back as its uninterpreted content octets, not as INTEGER or UTF8String.
    That is true of every implicitly tagged primitive component, CHOICE or
    not, so the octets -> JSON -> octets trip is not exact under those
    tagging modes. Checked here: the alternative survives, and writing the
    raw octets back into INTEGER is refused rather than written as 0. }
  Ok := True;
  Schema := TAsn1Schema.ParseModule(AutoModule);
  try
    for Rule := Low(TAsn1EncodingRule) to High(TAsn1EncodingRule) do
    begin
      Ctx := TAsn1SerializationContext.Create(Schema, 'Holder', Rule);
      try
        try
          AutoJson := TSerialization.Convert(TSerialization.Convert(
            TSerializationPayload.FromText(AUTO_JSON),
            TSerializationFormat.Json, Ctx.Format,
            TStructuralConversionProfile.Lossless, Ctx), Ctx.Format,
            TSerializationFormat.Json,
            TStructuralConversionProfile.Lossless, Ctx).AsText;
        except
          on E: Exception do AutoJson := E.ClassName + ': ' + E.Message;
        end;
        if Pos('"pick":{"text":', AutoJson) = 0 then
        begin
          Note('AUTOMATIC TAGS: ' + AutoJson);
          Ok := False;
        end;
        { The raw octets written back into INTEGER used to become 0, silently.
          They are refused now, naming the component - the limitation is
          visible, not a corrupted document. }
        Back := '';
        try
          Back := 'written ' + Hex(TSerialization.Convert(
            TSerializationPayload.FromText(AutoJson),
            TSerializationFormat.Json, Ctx.Format,
            TStructuralConversionProfile.Lossless, Ctx).AsBytes);
        except
          on E: EStructuralConversionError do
            if (E.Issue = TStructuralIssue.UnsupportedValueKind) and
               (E.Path = '$.id') then Back := 'refused';
          on E: Exception do Back := E.ClassName + ': ' + E.Message;
        end;
        if Back <> 'refused' then
        begin
          Note('AUTOMATIC TAGS written back: ' + Back);
          Ok := False;
        end;
      finally
        Ctx.Free;
      end;
    end;
    Note('AUTOMATIC TAGS read back: ' + AutoJson);
  finally
    Schema.Free;
  end;
  Check(Ok, 'ASN1_CHOICE_STRUCTURAL_KNOWN_LIMITATION');
end;

{ Two JSON members whose names differ only in case, one of them the declared
  component. The lookup is exact, so the declared one is what is written; and
  the other is undeclared, so Strict and Lossless refuse it by its own name. }
procedure TestCaseDistinctSchemaLookup;
const
  MODULE_TEXT =
    'Names DEFINITIONS AUTOMATIC TAGS ::= BEGIN ' +
    '  Rec ::= SEQUENCE { name UTF8String } ' +
    'END';
  BOTH = '{"Name":"wrong","name":"correct"}';
  ONLY = '{"name":"correct"}';
  FORMATS: array[0..2] of TSerializationFormat = (TSerializationFormat.Asn1Ber,
    TSerializationFormat.Asn1Der, TSerializationFormat.Asn1Cer);
var
  Schema: TAsn1Schema;
  F: TSerializationFormat;
  Ok: Boolean;
  Natural, Expected: string;

  function Outcome(const AJson: string; AFormat: TSerializationFormat;
    AProfile: TStructuralConversionProfile): string;
  begin
    try
      Result := Hex(TSerialization.Convert(TSerializationPayload.FromText(AJson),
        TSerializationFormat.Json, AFormat,
        TStructuralConversionOptions.FromProfile(AProfile).WithContext(
          Schema)).AsBytes);
    except
      on E: Exception do Result := E.ClassName + ': ' + E.Message;
    end;
  end;

  function Refused(const AOutcome: string): Boolean;
  begin
    Result := StartsText('EStructuralConversionError', AOutcome) and
      ContainsText(AOutcome, '$.Name');
    if not Result then Note(AOutcome);
  end;

begin
  Writeln;
  Writeln('--- members whose names differ only in case ---');
  Ok := True;
  Schema := TAsn1Schema.ParseModule(MODULE_TEXT);
  try
    for F in FORMATS do
    begin
      Natural := Outcome(BOTH, F, TStructuralConversionProfile.Natural);
      Expected := Outcome(ONLY, F, TStructuralConversionProfile.Strict);
      { "correct" is 636f7272656374 and "wrong" 77726f6e67. }
      if (Natural <> Expected) or (Pos('636f7272656374', Natural) = 0) or
         (Pos('77726f6e67', Natural) > 0) then
      begin
        Note(Natural + ' / ' + Expected);
        Ok := False;
      end;
      if not Refused(Outcome(BOTH, F, TStructuralConversionProfile.Strict)) then
        Ok := False;
      if not Refused(Outcome(BOTH, F,
        TStructuralConversionProfile.Lossless)) then Ok := False;
    end;
  finally
    Schema.Free;
  end;
  Check(Ok, 'ASN1_CASE_DISTINCT_SCHEMA_LOOKUP');
end;

{ A dynamic value of a kind the ASN.1 type cannot hold exactly is refused in
  every profile, under every rule - it used to be written as 0, '' or FALSE,
  because the dynamic accessors are plain field reads. }
procedure TestStructuralKindMismatch;
const
  MODULE_TEXT =
    'Kinds DEFINITIONS AUTOMATIC TAGS ::= BEGIN ' +
    '  I ::= SEQUENCE { v INTEGER } ' +
    '  U ::= SEQUENCE { v UTF8String } ' +
    '  O ::= SEQUENCE { v OCTET STRING } ' +
    '  B ::= SEQUENCE { v BOOLEAN } ' +
    'END';
  PROFILES: array[0..2] of TStructuralConversionProfile = (
    TStructuralConversionProfile.Natural,
    TStructuralConversionProfile.Lossless,
    TStructuralConversionProfile.Strict);
var
  Schema: TAsn1Schema;
  Rule: TAsn1EncodingRule;
  P: TStructuralConversionProfile;
  Ok: Boolean;

  procedure Expect(const ATypeName: string; AValue: TDynamicValue;
    AKind: TDynamicKind; const ASays: string; AProfile: TStructuralConversionProfile);
  var
    Doc: TDynamicValue;
    Outcome: string;
    Right: Boolean;
  begin
    Doc := TDynamicValue.NewObject;
    try
      Doc.AsObject.Adopt('v', AValue);
      Right := False;
      try
        Outcome := 'written ' + Hex(TAsn1SchemaCodec.FromDynamic(Doc, Schema,
          ATypeName, Rule, TStructuralConversionOptions.FromProfile(AProfile)));
      except
        on E: EStructuralConversionError do
        begin
          Outcome := E.ClassName + ': ' + E.Message;
          Right := (E.Issue = TStructuralIssue.UnsupportedValueKind) and
            (E.Path = '$.v') and (E.SourceKind = AKind) and
            ContainsText(E.Reason, 'the module says ' + ASays);
        end;
        on E: Exception do Outcome := E.ClassName + ': ' + E.Message;
      end;
      if not Right then
      begin
        Note(ATypeName + ': ' + Outcome);
        Ok := False;
      end;
    finally
      Doc.Free;
    end;
  end;

begin
  Writeln;
  Writeln('--- a value the ASN.1 type cannot hold ---');
  Ok := True;
  Schema := TAsn1Schema.ParseModule(MODULE_TEXT);
  try
    for Rule := Low(TAsn1EncodingRule) to High(TAsn1EncodingRule) do
      for P in PROFILES do
      begin
        Expect('I', TDynamicValue.NewStr('7'), TDynamicKind.Str, 'INTEGER', P);
        Expect('U', TDynamicValue.NewBytes(TBytes.Create($68, $69)),
          TDynamicKind.Bytes, 'UTF8String', P);
        Expect('O', TDynamicValue.NewBool(True), TDynamicKind.Bool,
          'OCTET STRING', P);
        Expect('B', TDynamicValue.NewInt(1), TDynamicKind.Int, 'BOOLEAN', P);
      end;
  finally
    Schema.Free;
  end;
  Check(Ok, 'ASN1_STRUCTURAL_KIND_MISMATCH_REFUSES');
end;

{ X.690 makes BOOLEAN, INTEGER, ENUMERATED, REAL, NULL, OBJECT IDENTIFIER and
  RELATIVE-OID primitive under every rule. Constructed, they were read as a
  SEQUENCE of their pieces - a different value. A constructed string is
  BER's segmented form, and UTCTime and GeneralizedTime are strings. }
procedure TestConstructedPrimitives;
const
  { Each a constructed wrapper around a well-formed primitive of its type. }
  PRIMITIVE_ONLY: array[0..6] of string = (
    '2103' + '0101ff',          { BOOLEAN }
    '2203' + '020105',          { INTEGER }
    '2a03' + '0a0101',          { ENUMERATED }
    '2903' + '090100',          { REAL, the one-octet zero }
    '2502' + '0500',            { NULL }
    '2605' + '06032a0304',      { OBJECT IDENTIFIER }
    '2d03' + '0d0101');         { RELATIVE-OID }
  UTF8_SEGMENTED = '2c0a' + '0403616263' + '0403646566';
  UTC_SEGMENTED = '3711' + '0406323330313031' + '04073132303030305a';
  GEN_SEGMENTED = '3813' + '04083230323330313031' + '04073132303030305a';
var
  Rule: TAsn1EncodingRule;
  Doc, Got: string;
  Ok: Boolean;
  V: TAsn1Value;

  { 'input' for EAsn1InputError itself, 'canonical' for its DER/CER
    subclass, otherwise what was read. }
  function Outcome(const AHex: string): string;
  begin
    try
      V := TAsn1Serializer.ParseTlv(FromHex(AHex), Rule);
    except
      on E: EAsn1CanonicalError do Exit('canonical');
      on E: EAsn1InputError do Exit('input');
    end;
    try
      Result := 'read ' + V.Describe;
      if V.Kind in [TAsn1Kind.Utf8String] then Result := 'text ' + V.AsText
      else if V.Kind in [TAsn1Kind.UtcTime, TAsn1Kind.GeneralizedTime] then
        Result := 'time ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', V.AsDateTime);
    finally
      V.Free;
    end;
  end;

  { CER writes every constructed value with an indefinite length. }
  function ForRule(const AHex: string): string;
  begin
    if Rule = TAsn1EncodingRule.Cer then
      Result := Copy(AHex, 1, 2) + '80' + Copy(AHex, 5, MaxInt) + '0000'
    else
      Result := AHex;
  end;

begin
  Writeln;
  Writeln('--- constructed encodings of primitive-only types ---');
  for Rule := Low(TAsn1EncodingRule) to High(TAsn1EncodingRule) do
  begin
    Ok := True;
    for Doc in PRIMITIVE_ONLY do
    begin
      Got := Outcome(ForRule(Doc));
      if Got <> 'input' then
      begin
        Note(ForRule(Doc) + ': ' + Got);
        Ok := False;
      end;
    end;
    case Rule of
      TAsn1EncodingRule.Ber: Check(Ok, 'ASN1_CONSTRUCTED_PRIMITIVE_REFUSED_BER');
      TAsn1EncodingRule.Cer: Check(Ok, 'ASN1_CONSTRUCTED_PRIMITIVE_REFUSED_CER');
    else
      Check(Ok, 'ASN1_CONSTRUCTED_PRIMITIVE_REFUSED_DER');
    end;
  end;

  { BER reassembles a segmented string, and its times; DER refuses both. }
  Rule := TAsn1EncodingRule.Ber;
  Got := Outcome(UTF8_SEGMENTED);
  Check(Got = 'text abcdef', 'ASN1_CONSTRUCTED_STRING_BER_READS');
  if Got <> 'text abcdef' then Note(Got);
  Got := Outcome(UTC_SEGMENTED) + ' / ' + Outcome(GEN_SEGMENTED);
  Check(Got = 'time 2023-01-01 12:00:00 / time 2023-01-01 12:00:00',
    'ASN1_CONSTRUCTED_TIME_BER_READS');
  if Got <> 'time 2023-01-01 12:00:00 / time 2023-01-01 12:00:00' then Note(Got);
  Rule := TAsn1EncodingRule.Der;
  Got := Outcome(UTF8_SEGMENTED) + ' / ' + Outcome(UTC_SEGMENTED) + ' / ' +
    Outcome(GEN_SEGMENTED);
  Check(Got = 'canonical / canonical / canonical',
    'ASN1_CONSTRUCTED_STRING_DER_REFUSES');
  if Got <> 'canonical / canonical / canonical' then Note(Got);
end;

{ A universal tag number at or past 2^63 is named unsigned: as a signed
  Int64 it would read as a negative tag. }
procedure TestLargeTagName;
var
  A, B: string;
begin
  Writeln;
  Writeln('--- tag names past 2^63 ---');
  A := Asn1TagName(TAsn1TagClass.Universal, UInt64($8000000000000001), False);
  B := Asn1TagName(TAsn1TagClass.ContextSpecific, High(UInt64), False);
  Check((A = '[UNIVERSAL 9223372036854775809]') and
    (B = '[18446744073709551615]'), 'ASN1_TAG_NAME_UNSIGNED_64');
  if (A <> '[UNIVERSAL 9223372036854775809]') or
     (B <> '[18446744073709551615]') then
    Note(A + ' ' + B);
end;

{ CER (X.690 9.1, 9.2): a string past 1000 content octets is constructed,
  with an indefinite length, in primitive fragments of exactly 1000 content
  octets but the last; a character string's fragments are OCTET STRINGs. A
  string of 1000 or fewer stays primitive. Written that way, read back, and
  every other shape refused. }
procedure TestCerSegmentation;
var
  V, Back: TAsn1Value;
  Text: string;
  Bits, Cer: TBytes;
  I, P, Fragments, LastLen: Integer;
  Ok: Boolean;
  H: string;

  { Walks the fragments of a CER constructed string at the bytes: each must
    be AFragTag; every one but the last exactly 1000 content octets; then
    end-of-contents. Returns the count, or -1. }
  function FragmentsOf(const AData: TBytes; AFragTag: Byte;
    out ALast: Integer): Integer;
  var
    Q, L: Integer;
  begin
    Result := 0;
    ALast := 0;
    Q := 2;
    while (Q + 1 < Length(AData)) and
          not ((AData[Q] = 0) and (AData[Q + 1] = 0)) do
    begin
      if AData[Q] <> AFragTag then Exit(-1);
      if (Result > 0) and (ALast <> 1000) then Exit(-1);
      case AData[Q + 1] of
        $82:
          begin
            L := (AData[Q + 2] shl 8) or AData[Q + 3];
            Inc(Q, 4);
          end;
        $81:
          begin
            L := AData[Q + 2];
            Inc(Q, 3);
          end;
      else
        L := AData[Q + 1];
        Inc(Q, 2);
      end;
      ALast := L;
      Inc(Q, L);
      Inc(Result);
    end;
    if Q + 2 <> Length(AData) then Result := -1;
  end;

  function Refusal(const AHex: string): string;
  begin
    try
      TAsn1Serializer.ParseTlv(FromHex(AHex), TAsn1EncodingRule.Cer).Free;
      Result := 'read';
    except
      on E: EAsn1CanonicalError do Result := 'canonical';
      on E: Exception do Result := E.ClassName + ': ' + E.Message;
    end;
  end;

  function Octets(ACount: Integer): string;
  begin
    Result := DupeString('5a', ACount);
  end;

begin
  Writeln;
  Writeln('--- CER segments long strings, and only long ones ---');

  { A UTF8String of 2501 octets. Two-octet characters straddle the fragment
    boundaries, which is allowed: the fragments are octets. }
  Text := 'a' + DupeString(#$0436, 1250);
  V := TAsn1Value.NewString(TAsn1Kind.Utf8String, Text);
  try
    Cer := TAsn1Serializer.Encode(V, TAsn1EncodingRule.Cer);
  finally
    V.Free;
  end;
  Fragments := FragmentsOf(Cer, $04, LastLen);
  Check((Cer[0] = $2C) and (Cer[1] = $80) and (Fragments = 3) and
    (LastLen = 501), 'ASN1_CER_UTF8_FRAGMENTS_ARE_OCTET_STRINGS_OF_1000');
  if Fragments <> 3 then
    Note(Copy(Hex(Cer), 1, 24) + ' fragments=' + IntToStr(Fragments));
  Back := TAsn1Serializer.ParseTlv(Cer, TAsn1EncodingRule.Cer);
  try
    Check((Back.Kind = TAsn1Kind.Utf8String) and (Back.AsText = Text),
      'ASN1_CER_UTF8_LONG_ROUNDTRIP');
  finally
    Back.Free;
  end;
  Back := TAsn1Serializer.ParseTlv(Cer, TAsn1EncodingRule.Ber);
  try
    Check(Back.AsText = Text, 'ASN1_CER_UTF8_LONG_READS_AS_BER');
  finally
    Back.Free;
  end;

  { 1000 octets stays primitive; 1001 is constructed. }
  Ok := True;
  V := TAsn1Value.NewString(TAsn1Kind.Utf8String, StringOfChar('b', 1000));
  try
    H := Hex(TAsn1Serializer.Encode(V, TAsn1EncodingRule.Cer));
    Ok := Ok and (Copy(H, 1, 8) = '0c8203e8');
  finally
    V.Free;
  end;
  V := TAsn1Value.NewOctetString(FromHex(Octets(1000)));
  try
    H := Hex(TAsn1Serializer.Encode(V, TAsn1EncodingRule.Cer));
    Ok := Ok and (Copy(H, 1, 8) = '048203e8');
  finally
    V.Free;
  end;
  V := TAsn1Value.NewString(TAsn1Kind.Utf8String, StringOfChar('b', 1001));
  try
    H := Hex(TAsn1Serializer.Encode(V, TAsn1EncodingRule.Cer));
    Ok := Ok and (Copy(H, 1, 12) = '2c80048203e8');
  finally
    V.Free;
  end;
  Check(Ok, 'ASN1_CER_STRING_OF_1000_STAYS_PRIMITIVE');

  { A BIT STRING of 2500 octets of bits and 3 unused: fragments of one
    unused-bit octet and 999 of bits, zero unused in all but the last. }
  SetLength(Bits, 2500);
  for I := 0 to High(Bits) do Bits[I] := Byte(I * 7);
  Bits[High(Bits)] := $A8;
  V := TAsn1Value.NewBitString(Bits, 3);
  try
    Cer := TAsn1Serializer.Encode(V, TAsn1EncodingRule.Cer);
  finally
    V.Free;
  end;
  Fragments := FragmentsOf(Cer, $03, LastLen);
  P := 2 + 4 + 1000 + 4;  { the second fragment's unused-bit octet }
  Check((Cer[0] = $23) and (Cer[1] = $80) and (Fragments = 3) and
    (LastLen = 1 + 502) and (Cer[6] = 0) and (Cer[P] = 0) and
    (Cer[P + 1000 + 4] = 3), 'ASN1_CER_BITSTRING_FRAGMENTS');
  if Fragments <> 3 then
    Note(Copy(Hex(Cer), 1, 24) + ' fragments=' + IntToStr(Fragments));
  Back := TAsn1Serializer.ParseTlv(Cer, TAsn1EncodingRule.Cer);
  try
    Check((Back.Kind = TAsn1Kind.BitString) and (Back.UnusedBits = 3) and
      (Hex(Back.AsBytes) = Hex(Bits)), 'ASN1_CER_BITSTRING_LONG_ROUNDTRIP');
  finally
    Back.Free;
  end;

  { The reader refuses every other shape under CER. }
  H := Refusal('248203ef' + '048203e8' + Octets(1000) + '04015a');
  Check(H = 'canonical', 'ASN1_CER_REFUSES_DEFINITE_CONSTRUCTED_STRING');
  if H <> 'canonical' then Note(H);
  H := Refusal('2480' + '0403616263' + '0000');
  Check(H = 'canonical', 'ASN1_CER_REFUSES_CONSTRUCTED_SHORT_STRING');
  if H <> 'canonical' then Note(H);
  H := Refusal('2480' + '048201f4' + Octets(500) + '04820258' + Octets(600) +
    '0000');
  Check(H = 'canonical', 'ASN1_CER_REFUSES_SHORT_INNER_FRAGMENT');
  if H <> 'canonical' then Note(H);
  H := Refusal('048203e9' + Octets(1001));
  Check(H = 'canonical', 'ASN1_CER_REFUSES_LONG_PRIMITIVE_STRING');
  if H <> 'canonical' then Note(H);
  H := Refusal('2c80' + '0c8203e8' + Octets(1000) + '0c015a' + '0000');
  Check(H = 'canonical', 'ASN1_CER_REFUSES_STRING_TAGGED_FRAGMENT');
  if H <> 'canonical' then Note(H);
  H := Refusal('2380' + '038203e8' + '05' + Octets(999) + '0302005a' + '0000');
  Check(H = 'canonical', 'ASN1_CER_REFUSES_UNUSED_BITS_BEFORE_LAST');
  if H <> 'canonical' then Note(H);
end;

{ CER (X.690 9.1): every constructed encoding takes the indefinite length -
  a SEQUENCE, a SET and an explicit tag as much as a segmented string. A
  definite one is refused under CER and still read under BER and DER. }
procedure TestCerDefiniteConstructed;
var
  Rule: TAsn1EncodingRule;

  function Outcome(const AHex: string): string;
  var
    V: TAsn1Value;
  begin
    try
      V := TAsn1Serializer.ParseTlv(FromHex(AHex), Rule);
    except
      on E: EAsn1CanonicalError do Exit('canonical');
      on E: Exception do Exit(E.ClassName);
    end;
    try
      if (V.Kind = TAsn1Kind.Tagged) and (V.Count = 1) and
         (V.Items[0].Kind = TAsn1Kind.IntegerValue) and
         (V.Items[0].AsInt64 = 5) then
        Result := 'tagged 5'
      else if (V.Count = 1) and (V.Items[0].Kind = TAsn1Kind.IntegerValue) and
         (V.Items[0].AsInt64 = 5) then
        Result := Asn1KindName(V.Kind) + ' 5'
      else
        Result := 'read ' + V.Describe;
    finally
      V.Free;
    end;
  end;

  procedure Expect(const AHex, AWant, AName: string);
  var
    Got: string;
  begin
    Got := Outcome(AHex);
    Check(Got = AWant, AName);
    if Got <> AWant then Note(AHex + ': ' + Got);
  end;

begin
  Writeln;
  Writeln('--- CER refuses every definite-length constructed value ---');
  Rule := TAsn1EncodingRule.Cer;
  Expect('3003020105', 'canonical', 'ASN1_CER_REFUSES_DEFINITE_SEQUENCE');
  Expect('3103020105', 'canonical', 'ASN1_CER_REFUSES_DEFINITE_SET');
  Expect('a003020105', 'canonical', 'ASN1_CER_REFUSES_DEFINITE_EXPLICIT_TAG');
  Expect('30800201050000', Asn1KindName(TAsn1Kind.Sequence) + ' 5',
    'ASN1_CER_READS_INDEFINITE_SEQUENCE');
  Expect('31800201050000', Asn1KindName(TAsn1Kind.SetValue) + ' 5',
    'ASN1_CER_READS_INDEFINITE_SET');
  Expect('a0800201050000', 'tagged 5', 'ASN1_CER_READS_INDEFINITE_EXPLICIT_TAG');
  Rule := TAsn1EncodingRule.Ber;
  Expect('3003020105', Asn1KindName(TAsn1Kind.Sequence) + ' 5',
    'ASN1_BER_STILL_READS_DEFINITE_SEQUENCE');
  Rule := TAsn1EncodingRule.Der;
  Expect('3103020105', Asn1KindName(TAsn1Kind.SetValue) + ' 5',
    'ASN1_DER_STILL_READS_DEFINITE_SET');
end;

procedure TestFeatureLedger;
begin
  Writeln;
  Writeln('--- X.690 and X.680 feature ledger ---');
  Note('identifier octets, four classes  TLV_*_CLASS');
  Note('high tag numbers                 TLV_HIGH_TAG_NUMBER');
  Note('definite length, short and long  TLV_*_LENGTH, RULE_DER_*');
  Note('indefinite length and EOC        RULE_CER_*, ASN1_BER_ACCEPTS_*');
  Note('BOOLEAN                          TLV_BOOLEAN_*');
  Note('INTEGER, any size                TLV_INTEGER_*');
  Note('BIT STRING with unused bits      ASN1_BIT_STRING_*');
  Note('OCTET STRING                     TLV_OCTET_STRING');
  Note('NULL                             TLV_NULL_HAS_NO_CONTENT');
  Note('OBJECT IDENTIFIER                ASN1_OID_*');
  Note('RELATIVE-OID                     decoded by the same arc reader');
  Note('ENUMERATED                       CONTRACT_* via the enum members');
  Note('REAL, binary, exact              REAL_*');
  Note('character string types           STRING_*');
  Note('UTCTime, GeneralizedTime         TIME_*');
  Note('SEQUENCE, SET, SEQUENCE OF       CONTRACT_*, RULE_DER_SORTS_A_SET');
  Note('CHOICE, as a real CHOICE         ASN1_CHOICE_*');
  Note('constructed strings, BER         ASN1_BER_REASSEMBLES_*');
  Note('DER canonical restrictions       ASN1_DER_REFUSES_*');
  Note('CER, which is NOT DER            ASN1_CER_*');
  Note('X.680 module parsing             SCHEMA_*');
  Note('schema-driven structural         ASN1_SCHEMA_*, ASN1_STRUCTURAL_*');
  Writeln;
  Note('NOT IMPLEMENTED, deliberately:');
  Note('  PER, OER, XER and JER. They are separate encodings in separate');
  Note('    recommendations; this is X.690.');
  Note('  The X.681/682/683 information object layer, parameterized types,');
  Note('    ANY DEFINED BY and constraint algebra. The module parser names');
  Note('    each one it meets rather than skipping it.');
  Check(True, 'ASN1_FEATURE_LEDGER');
end;

begin
  try
    TestTlv;
    TestOidAndBitString;
    TestStringsAndTimes;
    TestEncodingRules;
    TestMalformed;
    TestContract;
    TestReal;
    TestSchema;
    TestConversionMatrix;
    TestMultiTypeModule;
    TestReadOwnership;
    TestWriterLimits;
    TestUndeclaredMembers;
    TestLargeUniversalTags;
    TestLengthOverMaxInt;
    TestChoiceStructural;
    TestCaseDistinctSchemaLookup;
    TestStructuralKindMismatch;
    TestConstructedPrimitives;
    TestLargeTagName;
    TestCerSegmentation;
    TestCerDefiniteConstructed;
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
    Writeln('ASN1_BER_COMPLETE: PASS');
    Writeln('ASN1_DER_CANONICAL: PASS');
    Writeln('ASN1_CER_SEPARATE: PASS');
    Writeln('ASN1_SCHEMA_MODEL: PASS');
    Writeln('ASN1_CHOICE_IS_REAL: PASS');
    Writeln('ASN1_OID_AND_BIT_STRING: PASS');
    Writeln('ASN1_INDEPENDENT_INTEROP: PASS');
    Writeln('ASN1_NATIVE: PASS');
  end
  else
  begin
    Writeln('ASN1_NATIVE: FAIL');
    ExitCode := 1;
  end;
end.
