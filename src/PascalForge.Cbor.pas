{*******************************************************************************
  PascalForge.Cbor

  Public CBOR (RFC 8949) serialization facade for PascalForge.Serialization.

  Responsibilities
    - Typed CBOR serialization/deserialization (TBytes).
    - Population of existing values.
    - CBOR data model, options and customization API.

  Registration
    Direct TCborSerializer use does not require format registration.
    Generic TSerialization operations require explicit registration:
    TCborSerializationRegistration.RegisterFormat (PascalForge.Cbor.Registration).

  Configuration
    Global serializer configuration becomes immutable after first use.

  Threading
    Serialization is safe for concurrent use after configuration is frozen.

  Documentation
    docs/formats/cbor.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Cbor;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  CBOR serialization - RFC 8949 / STD 94.

      Data  := TCborSerializer.Serialize<TShipment>(Shipment);   // TBytes
      Shipment := TCborSerializer.Deserialize<TShipment>(Data);
      TCborSerializer.Populate<TShipment>(Existing, Data);

  CBOR is binary, so its natural Delphi type is TBytes and that is what this
  unit returns. There is no base64 API pretending otherwise.

  This is a real CBOR engine. A Delphi value is written straight to CBOR and
  read straight back; nothing routes through JSON text, through XML, or
  through the dynamic tree. The only thing shared with the other formats is
  the Delphi type foundation in PascalForge.Serialization.Core: what a
  nullable is, what a collection is, how a type is named.

  ALL EIGHT MAJOR TYPES ARE IMPLEMENTED, in both directions, together with
  every additional-information encoding the specification defines: the
  immediate values 0..23, the one-, two-, four- and eight-byte arguments, and
  the indefinite-length form for byte strings, text strings, arrays and maps.
  The three reserved values 28, 29 and 30 are refused by name, as is an
  indefinite length where the specification does not allow one.

  Integers span the whole of CBOR's range and not merely Delphi's. Major type
  0 reaches 18446744073709551615 and major type 1 reaches -18446744073709551616;
  both are held exactly, and asking for one as an Int64 when it does not fit
  raises rather than wrapping around.

  Using this unit needs no registration. PascalForge.Cbor.Registration exists
  only for code that picks a format at run time.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections,
  PascalForge.Serialization.Core, PascalForge.Dynamic;

type
  ECborError = class(Exception);
  { The document is at fault: malformed bytes, or a value the contract cannot
    accept. }
  ECborInputError = class(ECborError);
  { The model or the configuration is at fault. }
  ECborInternalError = class(ECborError);

  { --- the malformed-input family ------------------------------------------

    Each way a CBOR document can be ill-formed gets its own class, so a
    caller can tell "the bytes stopped early" from "this document nests a
    thousand deep" without matching on message text. All of them are
    ECborInputError. }

  { The item claims more bytes than the data holds. This is also what a
    length field of two gigabytes hits, immediately, before anything is
    allocated. }
  ECborTruncatedInput = class(ECborInputError);
  { Additional information 28, 29 or 30, which RFC 8949 reserves and which no
    well-formed document contains. }
  ECborReservedAdditionalInfo = class(ECborInputError);
  { Additional information 31 on a major type that has no indefinite form -
    an integer, a tag - or the break code where no indefinite-length item is
    open. }
  ECborUnexpectedBreak = class(ECborInputError);
  { A chunk inside an indefinite-length string that is not a definite-length
    string of the same major type. }
  ECborChunkMismatch = class(ECborInputError);
  { A text string whose bytes are not valid UTF-8. }
  ECborInvalidText = class(ECborInputError);
  { More nesting than the decode options allow. A handful of bytes can ask a
    naive decoder to recurse until the stack runs out; this is the answer. }
  ECborDepthExceeded = class(ECborInputError);
  { Bytes after the end of the outermost data item. }
  ECborTrailingData = class(ECborInputError);
  { A simple value 0..31 written in the two-byte form, which RFC 8949 section
    3.3 declares not well-formed because it is not the shortest encoding of
    that value. }
  ECborMalformedSimple = class(ECborInputError);
  { An integer that exists in CBOR but not in the Delphi type being asked
    for: 2^64-1 read as an Int64, a bignum read as a UInt64. Not an input
    error - the document is fine, the request is not. }
  ECborRangeError = class(ECborError);

  { ===========================================================================
    THE DATA MODEL

    CBOR's own major types, as a small tree. It exists because a custom CBOR
    serializer needs somewhere to write, because reading needs somewhere to
    put what it found before the contract is applied, and because a CBOR
    document is perfectly capable of holding things Delphi has no type for -
    a 2^64-1 integer, a tag nobody has registered, a simple value.

    EVERY MAJOR TYPE IS READ AND WRITTEN, and so is every shape each of them
    can take. What a decoded value remembers, beyond its meaning:

      * the width of the argument in its head, so a document that used a
        four-byte length for a three-byte string writes back the same way;
      * whether a string, array or map was definite or indefinite, and where
        an indefinite string's chunk boundaries were;
      * a float's exact width and its exact bits, so a NaN payload and the
        difference between 1.0 as a half and 1.0 as a double both survive.

    None of that is needed to understand the value. All of it is needed to
    write the document back out unchanged, which is the difference between a
    codec and a lossy reader.
    =========================================================================== }
  TCborKind = (
    { Major 0: 0 .. 18446744073709551615. }
    UInt,
    { Major 1: -1 .. -18446744073709551616. }
    NegInt,
    { Major 2. }
    Bytes,
    { Major 3. }
    Text,
    { Major 4. }
    Arr,
    { Major 5. }
    Map,
    { Major 6. }
    Tag,
    { Major 7, additional information 20 and 21. }
    Bool,
    { Major 7, 22. }
    Null,
    { Major 7, 23. }
    Undefined,
    { Major 7, 0..19 and 32..255 - a simple value with no assigned meaning. }
    Simple,
    { Major 7, 25, 26 and 27. }
    Float);

  { The eight major types, by their specification numbers. }
  TCborMajorType = 0..7;

  TCborFloatWidth = (Half, Single, Double);

  { The tag numbers RFC 8949 and the IANA registry define that this library
    understands well enough to name. A tag NOT in this list is still read,
    still written and still carried through conversion - see
    TDynamicTag.CborTag - it simply has no meaning attached to it here. }
  TCborTags = record
  public const
    { RFC 3339 date and time, as a text string. }
    DateTimeString  = 0;
    { Seconds since the Unix epoch, as an integer or a float. }
    EpochDateTime   = 1;
    { An arbitrary-precision integer, as a big-endian byte string. }
    PositiveBignum  = 2;
    { The same, for -1 minus the byte string's value. }
    NegativeBignum  = 3;
    { An array of two: a base-10 exponent and a mantissa. }
    DecimalFraction = 4;
    { An array of two: a base-2 exponent and a mantissa. }
    Bigfloat        = 5;
    { Rendering hints for a byte string converted into a text-based format. }
    ExpectedBase64Url = 21;
    ExpectedBase64    = 22;
    ExpectedBase16    = 23;
    { A byte string that is itself a CBOR data item. }
    EncodedCbor     = 24;
    Uri             = 32;
    Base64UrlText   = 33;
    Base64Text      = 34;
    RegularExpression = 35;
    MimeMessage     = 36;
    { Sixteen bytes, RFC 4122 byte order. }
    Uuid            = 37;
    { The self-described-CBOR marker, whose three bytes at the head of a file
      say "what follows is CBOR" and nothing else. }
    SelfDescribed   = 55799;

    { A sentence for a diagnostic, or '' for a tag with no name here. }
    class function Describe(ANumber: UInt64): string; static;
    class function IsKnown(ANumber: UInt64): Boolean; static;
  end;

  { Tags added to the vocabulary in TDynamicTag for CBOR values the shared
    list has no name for. Only one is needed: CBOR's simple values are a
    numbered space of their own, and false, true, null and undefined are
    merely four of its members that happen to have meanings. A simple value
    with no assigned meaning is not any of the dynamic kinds, and turning it
    into one would be inventing a meaning for it. }
  TCborDynamicTag = record
  public const
    { Payload: Int, the simple value 0..255. }
    SimpleValue = 'cborsimple';
  end;

  TCborValue = class
  strict private
    FKind: TCborKind;
    { Major 0: the value. Major 1: the argument n, where the value is -1-n.
      Simple: the simple value. Tag: the tag number. }
    FUInt: UInt64;
    { A float's exact bits, in its own width. }
    FBits: UInt64;
    FFloatWidth: TCborFloatWidth;
    { 0 for the shortest form, otherwise the forced argument width in bytes:
      1, 2, 4 or 8. Only a decoded value normally carries a non-zero one. }
    FHeadWidth: Byte;
    FStr: string;
    FBytes: TBytes;
    FIndefinite: Boolean;
    FItems: TObjectList<TCborValue>;
    FKeys: TObjectList<TCborValue>;
    FChunks: TObjectList<TCborValue>;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TCborValue;
    function GetKey(AIndex: Integer): TCborValue;
    function GetChunkCount: Integer;
    function GetChunk(AIndex: Integer): TCborValue;
    procedure NeedItems;
  public
    constructor Create(AKind: TCborKind);
    destructor Destroy; override;

    { --- construction ----------------------------------------------------- }

    class function NewUInt(AValue: UInt64): TCborValue; static;
    { Major 0 for a non-negative value, major 1 for a negative one. }
    class function NewInt(AValue: Int64): TCborValue; static;
    { Major 1 directly, by its encoded argument: the value is -1 - AArgument,
      which is how -18446744073709551616 is expressed at all. }
    class function NewNegativeArgument(AArgument: UInt64): TCborValue; static;
    class function NewBytes(const AValue: TBytes): TCborValue; static;
    class function NewText(const AValue: string): TCborValue; static;
    class function NewArray: TCborValue; static;
    class function NewMap: TCborValue; static;
    { Adopts AContent. }
    class function NewTag(ANumber: UInt64; AContent: TCborValue): TCborValue; static;
    class function NewBool(AValue: Boolean): TCborValue; static;
    class function NewNull: TCborValue; static;
    class function NewUndefined: TCborValue; static;
    { 0..255. The values 20..23 are false, true, null and undefined, and this
      returns those kinds for them rather than a second spelling of the same
      thing. }
    class function NewSimple(AValue: Byte): TCborValue; static;
    { A double, written as a double. For the shortest width that preserves the
      value, encode with TCborEncodeOptions.Rfc8949Deterministic. }
    class function NewFloat(AValue: System.Double): TCborValue; overload; static;
    class function NewFloat(AValue: System.Double;
      AWidth: TCborFloatWidth): TCborValue; overload; static;
    { The exact bits, for a caller that has them - a NaN with a payload, or a
      half-precision value read from somewhere else. }
    class function NewFloatBits(ABits: UInt64;
      AWidth: TCborFloatWidth): TCborValue; static;

    { The indefinite-length forms. A string built this way holds chunks, added
      with AddChunk; an array or a map is filled exactly like its
      definite-length twin and only differs in how it is written. }
    class function NewIndefiniteBytes: TCborValue; static;
    class function NewIndefiniteText: TCborValue; static;
    class function NewIndefiniteArray: TCborValue; static;
    class function NewIndefiniteMap: TCborValue; static;

    { --- the tags with a Delphi counterpart -------------------------------- }

    { Tag 37, sixteen bytes in RFC 4122 order - which is NOT the order a TGUID
      has in memory, because D1, D2 and D3 are little-endian there. }
    class function NewUuid(const AValue: TGUID): TCborValue; static;
    { Tag 32. }
    class function NewUri(const AValue: string): TCborValue; static;
    { Tag 1, seconds since the Unix epoch: an integer when the instant falls
      on a whole second, a double otherwise. }
    class function NewEpochDateTime(AValue: TDateTime): TCborValue; static;
    { Tag 0, RFC 3339 text. The instant is written as it stands, with a 'Z'
      suffix, because a TDateTime carries no zone and inventing one would make
      the value depend on where the process runs. }
    class function NewTextDateTime(AValue: TDateTime): TCborValue; static;
    { Tag 2 or tag 3, from a big-endian magnitude. ANegative asks for the
      value -AMagnitude, and the encoded argument becomes AMagnitude-1. }
    class function NewBignum(const AMagnitude: TBytes;
      ANegative: Boolean): TCborValue; static;
    { Tag 4: AMantissa times ten to the AExponent. AMantissa is decimal text
      of any length, so a mantissa wider than an Int64 is written as a nested
      bignum rather than refused. }
    class function NewDecimalFraction(AExponent: Int64;
      const AMantissa: string): TCborValue; static;

    { --- filling ----------------------------------------------------------- }

    { Appends to an array. Adopts AValue. }
    procedure Add(AValue: TCborValue); overload;
    { Appends to a map. CBOR map keys are data items, not names, so both
      halves are values. Adopts both. }
    procedure Add(AKey, AValue: TCborValue); overload;
    { The common case: a map entry under a text-string key. Adopts AValue. }
    procedure Add(const AKey: string; AValue: TCborValue); overload;
    { Appends a chunk to an indefinite-length string. Adopts AValue, which
      must be a definite-length string of this value's own major type. }
    procedure AddChunk(AValue: TCborValue);
    { The value under the first text-string key equal to AKey, or nil. }
    function Find(const AKey: string): TCborValue;

    { --- reading ----------------------------------------------------------- }

    function AsBool: Boolean;
    { Raises ECborRangeError for a value outside Int64 - which major type 0
      reaches above 9223372036854775807 and major type 1 below
      -9223372036854775808. }
    function AsInt64: System.Int64;
    { Raises ECborRangeError for a negative integer. }
    function AsUInt64: UInt64;
    { True for a major type 0 or 1 value. }
    function IsInteger: Boolean;
    { True when AsInt64 will not raise. }
    function FitsInt64: Boolean;
    { The argument of a major type 1 value: the value is -1 minus this. }
    function NegativeArgument: UInt64;
    function AsFloat: System.Double;
    function AsText: string;
    function AsBytes: TBytes;
    function TagNumber: UInt64;
    { The tagged data item. Borrowed. }
    function TagContent: TCborValue;
    function SimpleValue: Byte;
    { Tag 37 as a TGUID. False when this is not a sixteen-byte tag 37. }
    function TryAsUuid(out AValue: TGUID): Boolean;
    { Tag 32 as its text. }
    function TryAsUri(out AValue: string): Boolean;
    { Tag 0 or tag 1 as an instant. }
    function TryAsDateTime(out AValue: TDateTime): Boolean;
    { Tag 2 or tag 3 as a signed decimal string of any length. }
    function TryAsBigIntText(out AValue: string): Boolean;
    { Tag 4 or tag 5 as exact decimal text. A bigfloat whose binary exponent
      is beyond CborBigfloatExponentLimit returns False rather than spending
      unbounded time on digits nobody asked for; a decimal fraction whose
      exponent is beyond CborDecimalExponentLimit raises ECborInputError,
      before any digit is built. }
    function TryAsDecimalText(out AValue: string): Boolean;

    (* RFC 8949 section 8: diagnostic notation - CBOR's own standard way of
       writing a data item down for a human.

           {"a": 1, "b": [2, 3]}
           [_ 1, h'0102', 1(1363896240)]

       It is a DISPLAY form and deliberately one-way: the specification
       defines how to write it and does not define a parser for it, so
       there is no FromDiagnostic here. Anything that has to survive a
       round trip travels as bytes.

       The indefinite-length marker _ is included, because an indefinite
       array and a definite one holding the same items are different
       documents. The optional encoding indicators of section 8.1 are
       not. *)
    function ToDiagnostic: string;

    { A readable one-line rendering, for diagnostics and test failures. }
    function Describe: string;
    { A deep copy the caller owns. }
    function Clone: TCborValue;

    property Kind: TCborKind read FKind;
    { True for a string, array or map that was written - or is to be written -
      with the indefinite-length form. }
    property Indefinite: Boolean read FIndefinite;
    property FloatWidth: TCborFloatWidth read FFloatWidth;
    { A float's bits in its own width, which is what makes a NaN payload
      survive a round trip. }
    property FloatBits: UInt64 read FBits;
    { 0 asks for the shortest form. A decoded value carries the width the
      document actually used, so re-encoding it reproduces the document even
      when the document was not written in the preferred form. Deterministic
      encoding ignores this and always writes the shortest. }
    property HeadWidth: Byte read FHeadWidth write FHeadWidth;
    { Array items, map entries, or the single tagged item. }
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TCborValue read GetItem; default;
    property Keys[AIndex: Integer]: TCborValue read GetKey;
    property ChunkCount: Integer read GetChunkCount;
    property Chunks[AIndex: Integer]: TCborValue read GetChunk;
  end;

const
  { How far tag 5 will go before it declines. Two to the power of a thousand
    is three hundred digits; two to the power of a million is not a number
    anybody meant to write down. }
  CborBigfloatExponentLimit = 1024;
  { How far tag 4 will go before it is refused. A decimal fraction's
    exponent is the number of places its digits run to, so eleven bytes of
    document could ask for four hundred million zeros. decimal128's own
    range, which is wider than any Delphi type that could receive the
    value. }
  CborDecimalExponentLimit = 6144;
  { The default nesting limit. A CBOR document nests one level per array, map
    or tag, and eight bytes of input can ask for eight levels, so a bomb is
    cheap to write and has to be cheap to refuse. }
  CborDefaultMaxDepth = 256;

type
  { ===========================================================================
    ENCODING AND DECODING OPTIONS
    =========================================================================== }

  TCborEncodeOptions = record
  public
    { RFC 8949 section 4.2. Every argument takes its shortest form, every
      string, array and map is written with a definite length, map keys are
      sorted by their encoded bytes, and every float takes the shortest width
      that preserves its value exactly.

      What this deliberately does NOT do is section 4.2.2's optional extra:
      an integral float stays a float. That rule is a preference some
      applications adopt, not part of deterministic encoding, and applying it
      would change 1.0 into 1 behind the caller's back. }
    Deterministic: Boolean;
    { Prefixes the document with tag 55799, whose encoded three bytes are the
      self-described-CBOR marker. }
    SelfDescribe: Boolean;

    class function Default: TCborEncodeOptions; static;
    class function Rfc8949Deterministic: TCborEncodeOptions; static;
    function WithSelfDescribe: TCborEncodeOptions;
  end;

  TCborDecodeOptions = record
  public
    { Nesting beyond this raises ECborDepthExceeded. }
    MaxDepth: Integer;
    { CBOR documents are commonly concatenated in a stream, so a caller that
      reads one item out of a longer buffer sets this. The default is to
      refuse trailing bytes, because a whole-buffer decode that ignores half
      its input is how a truncation goes unnoticed. }
    AllowTrailingData: Boolean;

    class function Default: TCborDecodeOptions; static;
    function WithMaxDepth(AValue: Integer): TCborDecodeOptions;
  end;

  { ===========================================================================
    ATTRIBUTES - CBOR's own, and only CBOR's.
    =========================================================================== }

  CborNameAttribute = class(TCustomAttribute)
  strict private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

  CborIgnoreAttribute = class(TCustomAttribute)
  end;

  { How a TDate, TTime or TDateTime member is represented. CBOR's setting; it
    has no effect on JSON, XML or BSON. }
  TCborDateTimeRepresentation = (
    { Tag 1 over a number of seconds since the Unix epoch. The default for
      TDateTime: it is what a CBOR consumer expects an instant to look like,
      and the tag says what the number means so nothing has to guess. }
    EpochTagged,
    { Tag 0 over RFC 3339 text. }
    Rfc3339Tagged,
    { A bare number of seconds, with no tag. }
    UnixSeconds,
    UnixMilliseconds,
    { A bare ISO 8601 text string. The default for TDate and TTime, which are
      not instants and would be a lie as one. }
    Iso8601Text,
    { A Delphi FormatDateTime pattern, written as a text string. }
    CustomString);

  CborDateTimeRepresentationAttribute = class(TCustomAttribute)
  strict private
    FRepresentation: TCborDateTimeRepresentation;
    FPattern: string;
  public
    constructor Create(ARepresentation: TCborDateTimeRepresentation); overload;
    constructor Create(const APattern: string); overload;
    property Representation: TCborDateTimeRepresentation read FRepresentation;
    property Pattern: string read FPattern;
  end;

  { How a TGUID is represented. }
  TCborGuidRepresentation = (
    { Tag 37 over sixteen bytes in RFC 4122 order. The registered way to put
      a UUID in a CBOR document, and the default. }
    TaggedUuid,
    { The thirty-six character text form, for a consumer that insists. }
    LowercaseString,
    { Sixteen untagged bytes, for a consumer that already knows. }
    RawBytes);

  CborGuidRepresentationAttribute = class(TCustomAttribute)
  strict private
    FRepresentation: TCborGuidRepresentation;
  public
    constructor Create(ARepresentation: TCborGuidRepresentation);
    property Representation: TCborGuidRepresentation read FRepresentation;
  end;

  { How a Currency is represented. }
  TCborCurrencyRepresentation = (
    { Tag 4, with the exponent -4 and the scaled integer Delphi actually
      stores. A Currency IS a decimal fraction with four places, tag 4 IS a
      decimal fraction, and the two line up exactly - so this is a
      translation rather than a decision, and it is the default for that
      reason. }
    DecimalFraction,
    { The scaled integer alone, value times ten thousand. }
    ScaledInt64,
    { A double. Convenient, and lossy beyond 15 significant digits. }
    Double,
    { A decimal text string. }
    DecimalString);

  CborCurrencyRepresentationAttribute = class(TCustomAttribute)
  strict private
    FRepresentation: TCborCurrencyRepresentation;
  public
    constructor Create(ARepresentation: TCborCurrencyRepresentation);
    property Representation: TCborCurrencyRepresentation read FRepresentation;
  end;

  { How an enumeration is represented. }
  TCborEnumRepresentation = (
    { The member's name, as a text string. The default: it survives someone
      inserting a member in the middle. }
    Name,
    { The ordinal, as an integer. Smaller, and brittle in exactly that way. }
    Value);

  CborEnumRepresentationAttribute = class(TCustomAttribute)
  strict private
    FRepresentation: TCborEnumRepresentation;
  public
    constructor Create(ARepresentation: TCborEnumRepresentation);
    property Representation: TCborEnumRepresentation read FRepresentation;
  end;

  { ===========================================================================
    CUSTOM SERIALIZERS - CBOR's, not JSON's.
    =========================================================================== }

  TCustomCborValueSerializer = class
  public
    { Returns the CBOR value for AValue. The caller adopts it. }
    function Serialize(const AValue: TValue): TCborValue; virtual; abstract;
    { AExisting is what the member already held; reuse it when it is an
      instance you can populate, and say so by returning it. }
    function Deserialize(AValue: TCborValue; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; virtual; abstract;
  end;

  TCborValueSerializerClass = class of TCustomCborValueSerializer;

  { The typed base, and the one to use: it names the Delphi type, so an
    implementation never touches TValue or PTypeInfo. }
  TCustomCborValueSerializer<T> = class(TCustomCborValueSerializer)
  public
    function SerializeValue(const AValue: T): TCborValue; virtual; abstract;
    function DeserializeValue(AValue: TCborValue; const AExisting: T): T; virtual; abstract;

    function Serialize(const AValue: TValue): TCborValue; override; final;
    function Deserialize(AValue: TCborValue; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; override; final;
  end;

  CborSerializerAttribute = class(TCustomAttribute)
  strict private
    FSerializerClass: TCborValueSerializerClass;
  public
    constructor Create(ASerializerClass: TCborValueSerializerClass);
    property SerializerClass: TCborValueSerializerClass read FSerializerClass;
  end;

{ =========================================================================== }

type
  TCborSerializer = class
  strict private
    { A generic method body declared in an interface section may reference
      only interface-declared symbols, so every generic entry point below is
      a thin shell over one of these. }
    class function DoSerialize(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AOptions: TCborEncodeOptions): TBytes; static;
    class function DoDeserialize(ATypeInfo: PTypeInfo;
      const AData: TBytes): TValue; static;
    class procedure DoPopulate(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AData: TBytes); static;
    class function DoFrom(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload; AFrom: TSerializationFormat): TBytes; static;
    class procedure DoSetDateTimePolicy(ATypeInfo: PTypeInfo;
      const AFieldName: string; ARepresentation: TCborDateTimeRepresentation;
      const APattern: string); static;
    class procedure DoRegisterEnumMapping(ATypeInfo: PTypeInfo;
      const AValues: array of string); static;
    class procedure DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TCborValueSerializerClass); static;
  public
    { --- the normal API ---------------------------------------------------- }
    class function Serialize<T>(const AValue: T): TBytes; overload; static;
    class function Serialize<T>(const AValue: T;
      const AOptions: TCborEncodeOptions): TBytes; overload; static;
    class function Deserialize<T>(const AData: TBytes): T; static;
    class procedure Populate<T>(const AInstance: T; const AData: TBytes); static;

    { --- the document, without a contract ---------------------------------- }

    { Encodes one data item. The caller still owns AValue. }
    class function Encode(AValue: TCborValue): TBytes; overload; static;
    class function Encode(AValue: TCborValue;
      const AOptions: TCborEncodeOptions): TBytes; overload; static;
    { Decodes one data item, which the caller owns. }
    class function Decode(const AData: TBytes): TCborValue; overload; static;
    class function Decode(const AData: TBytes;
      const AOptions: TCborDecodeOptions): TCborValue; overload; static;

    { True when AData is already exactly what deterministic encoding would
      produce for the item it holds. It answers by decoding and re-encoding
      deterministically, so it is the encoder's own rules being applied and
      not a second, drifting copy of them. }
    class function IsDeterministic(const AData: TBytes): Boolean; static;

    { --- destination-oriented conversion ------------------------------------

      CBOR is the destination and is known at compile time, so only the
      SOURCE format is looked up. This unit has no compile-time dependency on
      any other format: the source is reached through the registry.

      The generic form is CONTRACT-AWARE: the source deserializes into T by
      its own rules and CBOR writes T by its own. The non-generic form is
      STRUCTURAL and carries only what every format shares. }
    class function From(const ASource: string;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From(const ASource: TBytes;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat;
      AProfile: TStructuralConversionProfile): TBytes; overload; static;

    class function From<T>(const ASource: string;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From<T>(const ASource: TBytes;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From<T>(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; overload; static;

    { --- date and time ------------------------------------------------------

      CBOR's settings, independent of JSON's, XML's and BSON's. Resolution is
      a member attribute, then a field registration, then a type
      registration, then this global default, then the built-in
      representation - and it happens once, while a plan is built. }
    class procedure SetDateTimeRepresentation(
      ARepresentation: TCborDateTimeRepresentation); overload; static;
    class procedure SetDateTimeRepresentation(
      const APattern: string); overload; static;
    class procedure RegisterDateTimeRepresentation<T>(
      ARepresentation: TCborDateTimeRepresentation); overload; static;
    class procedure RegisterFieldDateTimeRepresentation<T>(
      const AFieldName: string;
      ARepresentation: TCborDateTimeRepresentation); overload; static;

    { --- registrations ----------------------------------------------------- }

    class procedure RegisterEnumMapping<T>(const AValues: array of string); static;
    class procedure RegisterTypeSerializer<T>(
      ASerializerClass: TCborValueSerializerClass); static;

    { The encoding options every call that does not name its own will use. }
    class procedure SetDefaultEncodeOptions(
      const AOptions: TCborEncodeOptions); static;
    class function DefaultEncodeOptions: TCborEncodeOptions; static;

    { --- configuration lifecycle ------------------------------------------- }
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;

    { --- dynamic ---------------------------------------------------------

      A CBOR data item as a dynamic value, and back. Semantic tags this
      library does not interpret, and bignums, are Extended values kept
      exactly; a map key that is not text is refused except under Natural
      (see docs/formats/cbor.md). The tree is the caller's. }
    class function ToDynamic(const ACbor: TBytes): TDynamicValue; overload; static;
    class function ToDynamic(const ACbor: TBytes;
      const AOptions: TStructuralConversionOptions): TDynamicValue; overload; static;
    class function FromDynamic(AValue: TDynamicValue): TBytes; static;
    class procedure ResetConfiguration; static;
  end;

implementation

uses
  System.Math, System.DateUtils,
  PascalForge.Cbor.Internal;

{ ------------------------------------------------------------- TCborTags --- }

class function TCborTags.Describe(ANumber: UInt64): string;
begin
  { A tag number is 64 bits wide. Narrowing it to dispatch would make tag
    2^32+1 read as tag 1, so anything past the largest known number is
    unknown before the case ever sees it. }
  if ANumber > TCborTags.SelfDescribed then Exit('');
  case Integer(ANumber) of
    0: Result := 'a date and time as RFC 3339 text';
    1: Result := 'a date and time as seconds since the Unix epoch';
    2: Result := 'a positive arbitrary-precision integer';
    3: Result := 'a negative arbitrary-precision integer';
    4: Result := 'a decimal fraction';
    5: Result := 'a bigfloat';
    21: Result := 'a byte string expected to be shown as base64url';
    22: Result := 'a byte string expected to be shown as base64';
    23: Result := 'a byte string expected to be shown as base16';
    24: Result := 'a byte string holding an encoded CBOR data item';
    32: Result := 'a URI';
    33: Result := 'base64url text';
    34: Result := 'base64 text';
    35: Result := 'a regular expression';
    36: Result := 'a MIME message';
    37: Result := 'a UUID';
    55799: Result := 'the self-described CBOR marker';
  else
    Result := '';
  end;
end;

class function TCborTags.IsKnown(ANumber: UInt64): Boolean;
begin
  Result := Describe(ANumber) <> '';
end;

{ ------------------------------------------------------------ TCborValue --- }

constructor TCborValue.Create(AKind: TCborKind);
begin
  inherited Create;
  FKind := AKind;
  if AKind in [TCborKind.Arr, TCborKind.Map, TCborKind.Tag] then
  begin
    FItems := TObjectList<TCborValue>.Create(True);
    if AKind = TCborKind.Map then FKeys := TObjectList<TCborValue>.Create(True);
  end;
end;

destructor TCborValue.Destroy;
begin
  FChunks.Free;
  FKeys.Free;
  FItems.Free;
  inherited Destroy;
end;

procedure TCborValue.NeedItems;
begin
  if FItems = nil then
    raise ECborInternalError.CreateFmt(
      'Only an array, a map or a tag holds items; this is %s.', [Describe]);
end;

class function TCborValue.NewUInt(AValue: UInt64): TCborValue;
begin
  Result := TCborValue.Create(TCborKind.UInt);
  Result.FUInt := AValue;
end;

class function TCborValue.NewInt(AValue: System.Int64): TCborValue;
begin
  if AValue >= 0 then Exit(NewUInt(UInt64(AValue)));
  { Two's complement does the arithmetic exactly: -1-n is not n, and that
    identity holds at Low(Int64) where -1-AValue would have to leave the
    signed range to be computed. }
  Result := TCborValue.Create(TCborKind.NegInt);
  Result.FUInt := UInt64(not AValue);
end;

class function TCborValue.NewNegativeArgument(AArgument: UInt64): TCborValue;
begin
  Result := TCborValue.Create(TCborKind.NegInt);
  Result.FUInt := AArgument;
end;

class function TCborValue.NewBytes(const AValue: TBytes): TCborValue;
begin
  Result := TCborValue.Create(TCborKind.Bytes);
  Result.FBytes := AValue;
end;

class function TCborValue.NewText(const AValue: string): TCborValue;
begin
  Result := TCborValue.Create(TCborKind.Text);
  Result.FStr := AValue;
end;

class function TCborValue.NewArray: TCborValue;
begin
  Result := TCborValue.Create(TCborKind.Arr);
end;

class function TCborValue.NewMap: TCborValue;
begin
  Result := TCborValue.Create(TCborKind.Map);
end;

class function TCborValue.NewTag(ANumber: UInt64;
  AContent: TCborValue): TCborValue;
begin
  if AContent = nil then
    raise ECborInternalError.Create('A tag has to have something to tag.');
  Result := TCborValue.Create(TCborKind.Tag);
  Result.FUInt := ANumber;
  try
    Result.FItems.Add(AContent);
  except
    AContent.Free;
    Result.Free;
    raise;
  end;
end;

class function TCborValue.NewBool(AValue: Boolean): TCborValue;
begin
  Result := TCborValue.Create(TCborKind.Bool);
  Result.FUInt := UInt64(Ord(AValue));
end;

class function TCborValue.NewNull: TCborValue;
begin
  Result := TCborValue.Create(TCborKind.Null);
end;

class function TCborValue.NewUndefined: TCborValue;
begin
  Result := TCborValue.Create(TCborKind.Undefined);
end;

class function TCborValue.NewSimple(AValue: Byte): TCborValue;
begin
  case AValue of
    20: Exit(NewBool(False));
    21: Exit(NewBool(True));
    22: Exit(NewNull);
    23: Exit(NewUndefined);
  end;
  Result := TCborValue.Create(TCborKind.Simple);
  Result.FUInt := AValue;
end;

class function TCborValue.NewFloat(AValue: System.Double): TCborValue;
begin
  Result := NewFloat(AValue, TCborFloatWidth.Double);
end;

class function TCborValue.NewFloat(AValue: System.Double;
  AWidth: TCborFloatWidth): TCborValue;
var
  Half: Word;
  Bits32: Cardinal;
begin
  case AWidth of
    TCborFloatWidth.Half:
      begin
        if not TCborFloats.TryDoubleToHalf(AValue, Half) then
          raise ECborRangeError.Create(
            'This value has no exact half-precision form, so writing it as ' +
            'one would change it. Ask for single or double, or let ' +
            'deterministic encoding pick the shortest width that is exact.');
        Exit(NewFloatBits(Half, TCborFloatWidth.Half));
      end;
    TCborFloatWidth.Single:
      begin
        if not TCborFloats.TryDoubleToSingle(AValue, Bits32) then
          raise ECborRangeError.Create(
            'This value has no exact single-precision form, so writing it as ' +
            'one would change it. Ask for a double.');
        Exit(NewFloatBits(Bits32, TCborFloatWidth.Single));
      end;
  end;
  Result := NewFloatBits(PUInt64(@AValue)^, TCborFloatWidth.Double);
end;

class function TCborValue.NewFloatBits(ABits: UInt64;
  AWidth: TCborFloatWidth): TCborValue;
begin
  Result := TCborValue.Create(TCborKind.Float);
  Result.FBits := ABits;
  Result.FFloatWidth := AWidth;
end;

class function TCborValue.NewIndefiniteBytes: TCborValue;
begin
  Result := TCborValue.Create(TCborKind.Bytes);
  Result.FIndefinite := True;
  Result.FChunks := TObjectList<TCborValue>.Create(True);
end;

class function TCborValue.NewIndefiniteText: TCborValue;
begin
  Result := TCborValue.Create(TCborKind.Text);
  Result.FIndefinite := True;
  Result.FChunks := TObjectList<TCborValue>.Create(True);
end;

class function TCborValue.NewIndefiniteArray: TCborValue;
begin
  Result := TCborValue.Create(TCborKind.Arr);
  Result.FIndefinite := True;
end;

class function TCborValue.NewIndefiniteMap: TCborValue;
begin
  Result := TCborValue.Create(TCborKind.Map);
  Result.FIndefinite := True;
end;

class function TCborValue.NewUuid(const AValue: TGUID): TCborValue;
begin
  Result := NewTag(TCborTags.Uuid, NewBytes(TCborGuids.ToRfc4122(AValue)));
end;

class function TCborValue.NewUri(const AValue: string): TCborValue;
begin
  Result := NewTag(TCborTags.Uri, NewText(AValue));
end;

class function TCborValue.NewEpochDateTime(AValue: TDateTime): TCborValue;
var
  Millis: System.Int64;
begin
  { Not (AValue - UnixDateDelta) * MSecsPerDay: a TDateTime before
    1899-12-30 is a negative day with a positive time of day, and that
    formula put every such instant a day early. Refused outside the years 1
    to 9999, which no reader here accepts back. }
  Millis := TCborDateText.EpochMillis(AValue);
  if Millis mod MSecsPerSec = 0 then
    Result := NewTag(TCborTags.EpochDateTime, NewInt(Millis div MSecsPerSec))
  else
    Result := NewTag(TCborTags.EpochDateTime, NewFloat(Millis / MSecsPerSec));
end;

class function TCborValue.NewTextDateTime(AValue: TDateTime): TCborValue;
begin
  Result := NewTag(TCborTags.DateTimeString,
    NewText(TCborDateText.Encode(AValue)));
end;

class function TCborValue.NewBignum(const AMagnitude: TBytes;
  ANegative: Boolean): TCborValue;
begin
  if ANegative then
    Result := NewTag(TCborTags.NegativeBignum,
      NewBytes(TCborBigInt.DecrementMagnitude(AMagnitude)))
  else
    Result := NewTag(TCborTags.PositiveBignum,
      NewBytes(TCborBigInt.TrimMagnitude(AMagnitude)));
end;

class function TCborValue.NewDecimalFraction(AExponent: System.Int64;
  const AMantissa: string): TCborValue;
var
  Arr: TCborValue;
begin
  Arr := NewArray;
  try
    Arr.Add(NewInt(AExponent));
    Arr.Add(TCborBigInt.MantissaValue(AMantissa));
  except
    Arr.Free;
    raise;
  end;
  Result := NewTag(TCborTags.DecimalFraction, Arr);
end;

procedure TCborValue.Add(AValue: TCborValue);
begin
  if (FItems = nil) or (FKind <> TCborKind.Arr) then
  begin
    AValue.Free;
    raise ECborInternalError.CreateFmt(
      'Only an array takes a bare item; this is %s.', [Describe]);
  end;
  FItems.Add(AValue);
end;

procedure TCborValue.Add(AKey, AValue: TCborValue);
begin
  if (FKind <> TCborKind.Map) or (FItems = nil) then
  begin
    AKey.Free;
    AValue.Free;
    raise ECborInternalError.CreateFmt(
      'Only a map takes a key and a value; this is %s.', [Describe]);
  end;
  FKeys.Add(AKey);
  try
    FItems.Add(AValue);
  except
    FKeys.Delete(FKeys.Count - 1);
    AValue.Free;
    raise;
  end;
end;

procedure TCborValue.Add(const AKey: string; AValue: TCborValue);
begin
  Add(NewText(AKey), AValue);
end;

procedure TCborValue.AddChunk(AValue: TCborValue);
begin
  if not FIndefinite or not (FKind in [TCborKind.Bytes, TCborKind.Text]) then
  begin
    AValue.Free;
    raise ECborInternalError.CreateFmt(
      'Only an indefinite-length string holds chunks; this is %s.', [Describe]);
  end;
  if (AValue.Kind <> FKind) or AValue.Indefinite then
  begin
    AValue.Free;
    raise ECborChunkMismatch.Create(
      'Every chunk of an indefinite-length string has to be a ' +
      'definite-length string of that same major type - RFC 8949 section ' +
      '3.2.3. A chunk of a different type, or a nested indefinite one, is ' +
      'not well-formed.');
  end;
  FChunks.Add(AValue);
  if FKind = TCborKind.Bytes then
    FBytes := TCborBigInt.Concat(FBytes, AValue.AsBytes)
  else
    FStr := FStr + AValue.AsText;
end;

function TCborValue.Find(const AKey: string): TCborValue;
var
  I: Integer;
begin
  if FKind <> TCborKind.Map then Exit(nil);
  for I := 0 to Integer(FKeys.Count) - 1 do
    if (FKeys[I].Kind = TCborKind.Text) and (FKeys[I].AsText = AKey) then
      Exit(FItems[I]);
  Result := nil;
end;

function TCborValue.GetCount: Integer;
begin
  if FItems = nil then Exit(0);
  Result := Integer(FItems.Count);
end;

function TCborValue.GetItem(AIndex: Integer): TCborValue;
begin
  NeedItems;
  Result := FItems[AIndex];
end;

function TCborValue.GetKey(AIndex: Integer): TCborValue;
begin
  if FKeys = nil then
    raise ECborInternalError.CreateFmt('Only a map has keys; this is %s.',
      [Describe]);
  Result := FKeys[AIndex];
end;

function TCborValue.GetChunkCount: Integer;
begin
  if FChunks = nil then Exit(0);
  Result := Integer(FChunks.Count);
end;

function TCborValue.GetChunk(AIndex: Integer): TCborValue;
begin
  if FChunks = nil then
    raise ECborInternalError.CreateFmt(
      'Only an indefinite-length string has chunks; this is %s.', [Describe]);
  Result := FChunks[AIndex];
end;

function TCborValue.AsBool: Boolean;
begin
  if FKind <> TCborKind.Bool then
    raise ECborInputError.CreateFmt('Expected true or false, found %s.',
      [Describe]);
  Result := FUInt <> 0;
end;

function TCborValue.IsInteger: Boolean;
begin
  Result := FKind in [TCborKind.UInt, TCborKind.NegInt];
end;

function TCborValue.FitsInt64: Boolean;
begin
  case FKind of
    TCborKind.UInt: Result := FUInt <= UInt64(High(System.Int64));
    TCborKind.NegInt: Result := FUInt <= UInt64(High(System.Int64));
  else
    Result := False;
  end;
end;

function TCborValue.AsInt64: System.Int64;
begin
  if not IsInteger then
    raise ECborInputError.CreateFmt('Expected an integer, found %s.', [Describe]);
  if not FitsInt64 then
    raise ECborRangeError.CreateFmt(
      '%s does not fit in an Int64. CBOR integers span -18446744073709551616 ' +
      'to 18446744073709551615, which is wider than any Delphi integer; read ' +
      'it as a UInt64 when it is positive, or through tag 2 or tag 3 when it ' +
      'is not.', [Describe]);
  if FKind = TCborKind.UInt then Result := System.Int64(FUInt)
  else Result := System.Int64(not FUInt);
end;

function TCborValue.AsUInt64: UInt64;
begin
  if FKind <> TCborKind.UInt then
  begin
    if FKind = TCborKind.NegInt then
      raise ECborRangeError.CreateFmt(
        '%s is negative and a UInt64 is not.', [Describe]);
    raise ECborInputError.CreateFmt('Expected an integer, found %s.', [Describe]);
  end;
  Result := FUInt;
end;

function TCborValue.NegativeArgument: UInt64;
begin
  if FKind <> TCborKind.NegInt then
    raise ECborInputError.CreateFmt('Expected a negative integer, found %s.',
      [Describe]);
  Result := FUInt;
end;

function TCborValue.AsFloat: System.Double;
begin
  case FKind of
    TCborKind.Float: Result := TCborFloats.BitsToDouble(FBits, FFloatWidth);
    { An integer is a number and reading it as one loses nothing up to the
      point where a double runs out of mantissa; beyond that it raises rather
      than rounding silently. }
    TCborKind.UInt:
      begin
        if FUInt > UInt64(1) shl 53 then
          raise ECborRangeError.CreateFmt(
            '%s needs more than the 53 bits a double has, so reading it as ' +
            'one would change it.', [Describe]);
        Result := FUInt;
      end;
    TCborKind.NegInt:
      begin
        if FUInt >= UInt64(1) shl 53 then
          raise ECborRangeError.CreateFmt(
            '%s needs more than the 53 bits a double has, so reading it as ' +
            'one would change it.', [Describe]);
        Result := -1.0 - FUInt;
      end;
  else
    raise ECborInputError.CreateFmt('Expected a number, found %s.', [Describe]);
  end;
end;

function TCborValue.AsText: string;
begin
  if FKind <> TCborKind.Text then
    raise ECborInputError.CreateFmt('Expected a text string, found %s.',
      [Describe]);
  Result := FStr;
end;

function TCborValue.AsBytes: TBytes;
begin
  if FKind <> TCborKind.Bytes then
    raise ECborInputError.CreateFmt('Expected a byte string, found %s.',
      [Describe]);
  Result := FBytes;
end;

function TCborValue.TagNumber: UInt64;
begin
  if FKind <> TCborKind.Tag then
    raise ECborInputError.CreateFmt('Expected a tag, found %s.', [Describe]);
  Result := FUInt;
end;

function TCborValue.TagContent: TCborValue;
begin
  if (FKind <> TCborKind.Tag) or (FItems.Count <> 1) then
    raise ECborInputError.CreateFmt('Expected a tag, found %s.', [Describe]);
  Result := FItems[0];
end;

function TCborValue.SimpleValue: Byte;
begin
  case FKind of
    TCborKind.Simple: Result := Byte(FUInt);
    TCborKind.Bool: if FUInt <> 0 then Result := 21 else Result := 20;
    TCborKind.Null: Result := 22;
    TCborKind.Undefined: Result := 23;
  else
    raise ECborInputError.CreateFmt('Expected a simple value, found %s.',
      [Describe]);
  end;
end;

function TCborValue.TryAsUuid(out AValue: TGUID): Boolean;
begin
  AValue := TGUID.Empty;
  if (FKind <> TCborKind.Tag) or (FUInt <> TCborTags.Uuid) then Exit(False);
  if TagContent.Kind <> TCborKind.Bytes then Exit(False);
  if Length(TagContent.AsBytes) <> 16 then Exit(False);
  AValue := TCborGuids.FromRfc4122(TagContent.AsBytes);
  Result := True;
end;

function TCborValue.TryAsUri(out AValue: string): Boolean;
begin
  AValue := '';
  if (FKind <> TCborKind.Tag) or (FUInt <> TCborTags.Uri) then Exit(False);
  if TagContent.Kind <> TCborKind.Text then Exit(False);
  AValue := TagContent.AsText;
  Result := True;
end;

function TCborValue.TryAsDateTime(out AValue: TDateTime): Boolean;
var
  Content: TCborValue;
begin
  AValue := 0;
  if FKind <> TCborKind.Tag then Exit(False);
  Content := TagContent;
  if FUInt = TCborTags.DateTimeString then
  begin
    if Content.Kind <> TCborKind.Text then Exit(False);
    Exit(TCborDateText.TryDecode(Content.AsText, AValue));
  end;
  if FUInt <> TCborTags.EpochDateTime then Exit(False);
  { Through the shared epoch readers, whose bounds are the years a TDateTime
    holds - so the last second of 9999-12-31, which the writer produces as
    253402300799.999, is accepted. }
  case Content.Kind of
    TCborKind.UInt, TCborKind.NegInt:
      Result := Content.FitsInt64 and
        TStructuralText.TryUnixSecondsToDateTime(Content.AsInt64, AValue);
    TCborKind.Float:
      Result := TStructuralText.TryUnixFloatSecondsToDateTime(Content.AsFloat,
        AValue);
  else
    Result := False;
  end;
end;

function TCborValue.TryAsBigIntText(out AValue: string): Boolean;
begin
  AValue := '';
  if FKind <> TCborKind.Tag then Exit(False);
  if (FUInt <> TCborTags.PositiveBignum) and
     (FUInt <> TCborTags.NegativeBignum) then Exit(False);
  if TagContent.Kind <> TCborKind.Bytes then Exit(False);
  if FUInt = TCborTags.PositiveBignum then
    AValue := TCborBigInt.MagnitudeToDecimal(TagContent.AsBytes)
  else
    AValue := '-' + TCborBigInt.MagnitudeToDecimal(
      TCborBigInt.IncrementMagnitude(TagContent.AsBytes));
  Result := True;
end;

function TCborValue.TryAsDecimalText(out AValue: string): Boolean;
begin
  AValue := '';
  if FKind <> TCborKind.Tag then Exit(False);
  if FUInt = TCborTags.DecimalFraction then
    Exit(TCborBigInt.DecimalFractionToText(TagContent, AValue));
  if FUInt = TCborTags.Bigfloat then
    Exit(TCborBigInt.BigfloatToText(TagContent, AValue));
  Result := False;
end;

{ --- RFC 8949 section 8, diagnostic notation --------------------------- }

{ A text string, written the way the specification's examples write one:
  JSON's string syntax. Control characters take the \u form so that the
  result is one line whatever the string contains. }
function DiagnosticString(const AValue: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '"';
  for I := 1 to Length(AValue) do
  begin
    C := AValue[I];
    case C of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
    else
      if C < ' ' then
        Result := Result + '\u' + LowerCase(IntToHex(Ord(C), 4))
      else
        Result := Result + C;
    end;
  end;
  Result := Result + '"';
end;

{ A float, written so that it reads back as the same number and so that an
  integral value still looks like a float - 1.0 and 1 are different data
  items and diagnostic notation has to keep them apart. }
function DiagnosticFloat(AValue: Double): string;
begin
  if IsNan(AValue) then Exit('NaN');
  if IsInfinite(AValue) then
    if AValue > 0 then Exit('Infinity') else Exit('-Infinity');
  Result := FloatToStr(AValue, TFormatSettings.Invariant);
  if (Pos('.', Result) = 0) and (Pos('E', UpperCase(Result)) = 0) then
    Result := Result + '.0';
end;

function TCborValue.ToDiagnostic: string;
var
  I: Integer;
  Parts: string;
begin
  case FKind of
    TCborKind.UInt: Exit(UIntToStr(FUInt));

    TCborKind.NegInt:
      begin
        { -1-n, and n may be High(UInt64), which is one past what an Int64
          can say - so the text is built rather than converted. }
        if FUInt = High(UInt64) then Exit('-18446744073709551616');
        Exit('-' + UIntToStr(FUInt + 1));
      end;

    TCborKind.Bytes:
      begin
        if not FIndefinite then
          Exit('h''' + LowerCase(TStructuralText.EncodeHex(FBytes)) + '''');
        Parts := '';
        for I := 0 to ChunkCount - 1 do
        begin
          if I > 0 then Parts := Parts + ', ';
          Parts := Parts + Chunks[I].ToDiagnostic;
        end;
        Exit('(_ ' + Parts + ')');
      end;

    TCborKind.Text:
      begin
        if not FIndefinite then Exit(DiagnosticString(FStr));
        Parts := '';
        for I := 0 to ChunkCount - 1 do
        begin
          if I > 0 then Parts := Parts + ', ';
          Parts := Parts + Chunks[I].ToDiagnostic;
        end;
        Exit('(_ ' + Parts + ')');
      end;

    TCborKind.Arr:
      begin
        Parts := '';
        for I := 0 to Count - 1 do
        begin
          if I > 0 then Parts := Parts + ', ';
          Parts := Parts + Items[I].ToDiagnostic;
        end;
        if FIndefinite then
        begin
          if Parts = '' then Exit('[_ ]');
          Exit('[_ ' + Parts + ']');
        end;
        Exit('[' + Parts + ']');
      end;

    TCborKind.Map:
      begin
        { A CBOR map key is a data item, not a name, so it is written as one
          - which is the whole reason this is not JSON. }
        Parts := '';
        for I := 0 to Count - 1 do
        begin
          if I > 0 then Parts := Parts + ', ';
          Parts := Parts + Keys[I].ToDiagnostic + ': ' + Items[I].ToDiagnostic;
        end;
        if FIndefinite then
        begin
          if Parts = '' then Exit('{_ }');
          Exit('{_ ' + Parts + '}');
        end;
        Exit('{' + Parts + '}');
      end;

    TCborKind.Tag:
      Exit(UIntToStr(FUInt) + '(' + TagContent.ToDiagnostic + ')');

    TCborKind.Bool:
      if FUInt <> 0 then Exit('true') else Exit('false');
    TCborKind.Null: Exit('null');
    TCborKind.Undefined: Exit('undefined');
    TCborKind.Simple: Exit('simple(' + UIntToStr(FUInt) + ')');
    TCborKind.Float: Exit(DiagnosticFloat(AsFloat));
  end;
  Result := '';
end;

function TCborValue.Describe: string;
var
  Name: string;
begin
  case FKind of
    TCborKind.UInt: Result := Format('the unsigned integer %u', [FUInt]);
    TCborKind.NegInt:
      if FUInt = High(UInt64) then Result := 'the integer -18446744073709551616'
      else Result := Format('the negative integer -%u', [FUInt + 1]);
    TCborKind.Bytes:
      if FIndefinite then
        Result := Format('an indefinite-length byte string of %d bytes in %d chunks',
          [Length(FBytes), ChunkCount])
      else Result := Format('a byte string of %d bytes', [Length(FBytes)]);
    TCborKind.Text:
      if FIndefinite then
        Result := Format('an indefinite-length text string in %d chunks',
          [ChunkCount])
      else Result := Format('a text string of %d characters', [Length(FStr)]);
    TCborKind.Arr:
      if FIndefinite then
        Result := Format('an indefinite-length array of %d items', [Count])
      else Result := Format('an array of %d items', [Count]);
    TCborKind.Map:
      if FIndefinite then
        Result := Format('an indefinite-length map of %d entries', [Count])
      else Result := Format('a map of %d entries', [Count]);
    TCborKind.Tag:
      begin
        Name := TCborTags.Describe(FUInt);
        if Name <> '' then Result := Format('tag %u, %s', [FUInt, Name])
        else Result := Format('tag %u', [FUInt]);
      end;
    TCborKind.Bool: if FUInt <> 0 then Result := 'true' else Result := 'false';
    TCborKind.Null: Result := 'null';
    TCborKind.Undefined: Result := 'undefined';
    TCborKind.Simple: Result := Format('simple value %u', [FUInt]);
    TCborKind.Float:
      case FFloatWidth of
        TCborFloatWidth.Half: Result := 'a half-precision float';
        TCborFloatWidth.Single: Result := 'a single-precision float';
      else
        Result := 'a double-precision float';
      end;
  else
    Result := 'an unknown value';
  end;
end;

function TCborValue.Clone: TCborValue;
var
  I: Integer;
begin
  Result := TCborValue.Create(FKind);
  try
    Result.FUInt := FUInt;
    Result.FBits := FBits;
    Result.FFloatWidth := FFloatWidth;
    Result.FHeadWidth := FHeadWidth;
    Result.FStr := FStr;
    Result.FBytes := Copy(FBytes);
    Result.FIndefinite := FIndefinite;
    if FChunks <> nil then
    begin
      Result.FChunks := TObjectList<TCborValue>.Create(True);
      for I := 0 to Integer(FChunks.Count) - 1 do
        Result.FChunks.Add(FChunks[I].Clone);
    end;
    if FItems <> nil then
      for I := 0 to Integer(FItems.Count) - 1 do
      begin
        if FKeys <> nil then Result.FKeys.Add(FKeys[I].Clone);
        Result.FItems.Add(FItems[I].Clone);
      end;
  except
    Result.Free;
    raise;
  end;
end;

{ --------------------------------------------------------------- options --- }

class function TCborEncodeOptions.Default: TCborEncodeOptions;
begin
  Result.Deterministic := False;
  Result.SelfDescribe := False;
end;

class function TCborEncodeOptions.Rfc8949Deterministic: TCborEncodeOptions;
begin
  Result.Deterministic := True;
  Result.SelfDescribe := False;
end;

function TCborEncodeOptions.WithSelfDescribe: TCborEncodeOptions;
begin
  Result := Self;
  Result.SelfDescribe := True;
end;

class function TCborDecodeOptions.Default: TCborDecodeOptions;
begin
  Result.MaxDepth := CborDefaultMaxDepth;
  Result.AllowTrailingData := False;
end;

function TCborDecodeOptions.WithMaxDepth(AValue: Integer): TCborDecodeOptions;
begin
  Result := Self;
  Result.MaxDepth := AValue;
end;

{ ------------------------------------------------------------- attributes --- }

constructor CborNameAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

constructor CborDateTimeRepresentationAttribute.Create(
  ARepresentation: TCborDateTimeRepresentation);
begin
  inherited Create;
  FRepresentation := ARepresentation;
  FPattern := '';
end;

constructor CborDateTimeRepresentationAttribute.Create(const APattern: string);
begin
  inherited Create;
  FRepresentation := TCborDateTimeRepresentation.CustomString;
  FPattern := APattern;
end;

constructor CborGuidRepresentationAttribute.Create(
  ARepresentation: TCborGuidRepresentation);
begin
  inherited Create;
  FRepresentation := ARepresentation;
end;

constructor CborCurrencyRepresentationAttribute.Create(
  ARepresentation: TCborCurrencyRepresentation);
begin
  inherited Create;
  FRepresentation := ARepresentation;
end;

constructor CborEnumRepresentationAttribute.Create(
  ARepresentation: TCborEnumRepresentation);
begin
  inherited Create;
  FRepresentation := ARepresentation;
end;

constructor CborSerializerAttribute.Create(
  ASerializerClass: TCborValueSerializerClass);
begin
  inherited Create;
  FSerializerClass := ASerializerClass;
end;

{ ------------------------------------------------- typed custom serializer --- }

function TCustomCborValueSerializer<T>.Serialize(
  const AValue: TValue): TCborValue;
begin
  Result := SerializeValue(AValue.AsType<T>);
end;

function TCustomCborValueSerializer<T>.Deserialize(AValue: TCborValue;
  ATypeInfo: PTypeInfo; const AExisting: TValue): TValue;
var
  Existing: T;
begin
  if AExisting.IsEmpty then Existing := Default(T)
  else Existing := AExisting.AsType<T>;
  Result := TValue.From<T>(DeserializeValue(AValue, Existing));
end;

{ ---------------------------------------------------------------- bridges --- }

class function TCborSerializer.DoSerialize(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AOptions: TCborEncodeOptions): TBytes;
begin
  Result := TCborEngine.SerializeRoot(ATypeInfo, AValue, AOptions);
end;

class function TCborSerializer.DoDeserialize(ATypeInfo: PTypeInfo;
  const AData: TBytes): TValue;
begin
  Result := TCborEngine.DeserializeRoot(ATypeInfo, AData, TValue.Empty);
end;

class procedure TCborSerializer.DoPopulate(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AData: TBytes);
begin
  TCborEngine.DeserializeRoot(ATypeInfo, AData, AValue);
end;

class function TCborSerializer.DoFrom(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload; AFrom: TSerializationFormat): TBytes;
begin
  Result := TCborEngine.FromPayload(ATypeInfo, ASource, AFrom);
end;

class procedure TCborSerializer.DoSetDateTimePolicy(ATypeInfo: PTypeInfo;
  const AFieldName: string; ARepresentation: TCborDateTimeRepresentation;
  const APattern: string);
begin
  TCborEngine.SetDateTimePolicy(ATypeInfo, AFieldName, Ord(ARepresentation),
    APattern);
end;

class procedure TCborSerializer.DoRegisterEnumMapping(ATypeInfo: PTypeInfo;
  const AValues: array of string);
begin
  TCborEngine.RegisterEnumMapping(ATypeInfo, AValues);
end;

class procedure TCborSerializer.DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TCborValueSerializerClass);
begin
  TCborEngine.RegisterTypeSerializer(ATypeInfo, ASerializerClass);
end;

{ ------------------------------------------------------------- operations --- }

class function TCborSerializer.Serialize<T>(const AValue: T): TBytes;
begin
  Result := Serialize<T>(AValue, TCborEngine.DefaultEncodeOptions);
end;

class function TCborSerializer.Serialize<T>(const AValue: T;
  const AOptions: TCborEncodeOptions): TBytes;
var
  V: TValue;
begin
  TValue.Make(@AValue, System.TypeInfo(T), V);
  Result := DoSerialize(System.TypeInfo(T), V, AOptions);
end;

class function TCborSerializer.Deserialize<T>(const AData: TBytes): T;
begin
  Result := DoDeserialize(System.TypeInfo(T), AData).AsType<T>;
end;

class procedure TCborSerializer.Populate<T>(const AInstance: T;
  const AData: TBytes);
var
  V: TValue;
begin
  TValue.Make(@AInstance, System.TypeInfo(T), V);
  DoPopulate(System.TypeInfo(T), V, AData);
end;

class function TCborSerializer.Encode(AValue: TCborValue): TBytes;
begin
  Result := TCborEngine.Encode(AValue, TCborEngine.DefaultEncodeOptions);
end;

class function TCborSerializer.Encode(AValue: TCborValue;
  const AOptions: TCborEncodeOptions): TBytes;
begin
  Result := TCborEngine.Encode(AValue, AOptions);
end;

class function TCborSerializer.Decode(const AData: TBytes): TCborValue;
begin
  Result := TCborEngine.Decode(AData, TCborDecodeOptions.Default);
end;

class function TCborSerializer.Decode(const AData: TBytes;
  const AOptions: TCborDecodeOptions): TCborValue;
begin
  Result := TCborEngine.Decode(AData, AOptions);
end;

class function TCborSerializer.IsDeterministic(const AData: TBytes): Boolean;
begin
  Result := TCborEngine.IsDeterministic(AData);
end;

class function TCborSerializer.From(const ASource: string;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From(TSerializationPayload.FromText(ASource), AFrom);
end;

class function TCborSerializer.From(const ASource: TBytes;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From(TSerializationPayload.FromBytes(ASource), AFrom);
end;

class function TCborSerializer.From(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From(ASource, AFrom, TStructuralConversionProfile.Natural);
end;

class function TCborSerializer.From(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat;
  AProfile: TStructuralConversionProfile): TBytes;
begin
  Result := TCborEngine.FromPayloadStructural(ASource, AFrom, AProfile);
end;

class function TCborSerializer.From<T>(const ASource: string;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From<T>(TSerializationPayload.FromText(ASource), AFrom);
end;

class function TCborSerializer.From<T>(const ASource: TBytes;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From<T>(TSerializationPayload.FromBytes(ASource), AFrom);
end;

class function TCborSerializer.From<T>(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := DoFrom(System.TypeInfo(T), ASource, AFrom);
end;

{ ------------------------------------------------------------ date and time --- }

class procedure TCborSerializer.SetDateTimeRepresentation(
  ARepresentation: TCborDateTimeRepresentation);
begin
  TCborEngine.SetDateTimePolicy(nil, '', Ord(ARepresentation), '');
end;

class procedure TCborSerializer.SetDateTimeRepresentation(
  const APattern: string);
begin
  TCborEngine.SetDateTimePolicy(nil, '',
    Ord(TCborDateTimeRepresentation.CustomString), APattern);
end;

class procedure TCborSerializer.RegisterDateTimeRepresentation<T>(
  ARepresentation: TCborDateTimeRepresentation);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), '', ARepresentation, '');
end;

class procedure TCborSerializer.RegisterFieldDateTimeRepresentation<T>(
  const AFieldName: string; ARepresentation: TCborDateTimeRepresentation);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), AFieldName, ARepresentation, '');
end;

{ ---------------------------------------------------------- registrations --- }

class procedure TCborSerializer.RegisterEnumMapping<T>(
  const AValues: array of string);
begin
  DoRegisterEnumMapping(System.TypeInfo(T), AValues);
end;

class procedure TCborSerializer.RegisterTypeSerializer<T>(
  ASerializerClass: TCborValueSerializerClass);
begin
  DoRegisterTypeSerializer(System.TypeInfo(T), ASerializerClass);
end;

class procedure TCborSerializer.SetDefaultEncodeOptions(
  const AOptions: TCborEncodeOptions);
begin
  TCborEngine.SetDefaultEncodeOptions(AOptions);
end;

class function TCborSerializer.DefaultEncodeOptions: TCborEncodeOptions;
begin
  Result := TCborEngine.DefaultEncodeOptions;
end;

class procedure TCborSerializer.FreezeConfiguration;
begin
  TCborEngine.FreezeConfiguration;
end;

class function TCborSerializer.IsFrozen: Boolean;
begin
  Result := TCborEngine.IsFrozen;
end;

class procedure TCborSerializer.ResetConfiguration;
begin
  TCborEngine.ResetConfiguration;
end;


{ ---------------------------------------------------------------- dynamic --- }

class function TCborSerializer.ToDynamic(const ACbor: TBytes): TDynamicValue;
begin
  Result := ToDynamic(ACbor, TStructuralConversionOptions.Default);
end;

class function TCborSerializer.ToDynamic(const ACbor: TBytes;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
var
  Value: TCborValue;
begin
  Value := TCborEngine.Decode(ACbor, TCborDecodeOptions.Default);
  try
    Result := TCborEngine.CborToDynamic(Value, AOptions, '$');
  finally
    Value.Free;
  end;
end;

class function TCborSerializer.FromDynamic(AValue: TDynamicValue): TBytes;
var
  Value: TCborValue;
begin
  { CBOR covers every dynamic kind - unsigned integers, decimals through
    tag 4, binary, timestamps through tag 1 - so no policy applies. }
  Value := TCborEngine.DynamicToCbor(AValue);
  try
    Result := TCborEngine.Encode(Value, TCborEngine.DefaultEncodeOptions);
  finally
    Value.Free;
  end;
end;

end.
