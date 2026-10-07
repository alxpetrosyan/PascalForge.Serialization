{*******************************************************************************
  PascalForge.Asn1

  Public ASN.1 (BER, DER, CER) serialization facade for
  PascalForge.Serialization.

  Responsibilities
    - Typed ASN.1 serialization/deserialization under an explicit encoding
      rule.
    - Schema-guided structural conversion (PascalForge.Asn1.Schema).
    - ASN.1-specific attributes, options and customization API.

  Registration
    Direct TAsn1Serializer use does not require format registration.
    Generic TSerialization operations require explicit registration:
    TAsn1SerializationRegistration.RegisterFormat (PascalForge.Asn1.Registration).

  Configuration
    Global serializer configuration becomes immutable after first use.

  Threading
    Serialization is safe for concurrent use after configuration is frozen.

  Documentation
    docs/formats/asn1.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Asn1;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  ASN.1 serialization: BER, DER and CER.

      Data := TAsn1Serializer.Serialize<TShipment>(Shipment, TAsn1EncodingRule.Der);
      Shipment := TAsn1Serializer.Deserialize<TShipment>(Data, TAsn1EncodingRule.Der);

  ASN.1 IS A SCHEMA LANGUAGE AND AN ENCODING IS SOMETHING ELSE. X.680 defines
  the types; X.690 defines three ways of writing a value of one of those types
  down, and they are not interchangeable. BER is permissive: a value has many
  valid encodings. DER and CER are each a canonical SUBSET of BER, and they
  disagree with one another - DER forbids the indefinite length form that CER
  requires for every constructed value. So one set of units serves three
  values of TSerializationFormat, and the encoding rule is an argument
  everywhere rather than a property of the library.

  WHAT IS NOT HERE. The packed encoding rules (PER, X.691) and the octet
  encoding rules (OER, X.696) are deliberately absent. They are further
  encoding rules of the same schema language, they share none of X.690's
  tag-length-value machinery, and a half-done PER would be worse than none.
  Nothing in this unit pretends otherwise: TAsn1EncodingRule has three values.

  XER (XML encoding rules) and JER (JSON encoding rules) are likewise absent,
  and for the additional reason that producing them here would mean reaching
  into another format's units, which this library does not do.

  WHAT A SCHEMA IS FOR. A BER encoding is self-delimiting but not
  self-describing. The octets 30 06 02 01 05 01 01 FF say "a constructed
  universal 16 containing an integer 5 and a boolean true"; they do not say
  that this is a Reading, that the integer is a Celsius temperature or that
  the boolean means the sensor was calibrated. Worse, context-specific tag [0]
  means whatever the module says it means and nothing at all otherwise. So
  structural conversion REQUIRES a schema and raises
  ESerializationSchemaRequired without one, rather than handing back a tree of
  tag numbers and calling it a document.

  Raw tag-length-value decoding is still available, because reading somebody
  else's certificate is a real thing to want - but it is named ParseTlv, it
  is documented as a diagnostic, and it is not offered as a structural
  capability.

  The schema model lives in PascalForge.Asn1.Schema; the codec lives in
  PascalForge.Asn1.Internal. Using either needs no registration.
  PascalForge.Asn1.Registration exists only for code that picks a format at
  run time; its RegisterFormat, called explicitly at startup, registers all
  three encoding rules.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections,
  PascalForge.Serialization.Core, PascalForge.Dynamic;

type
  EAsn1Error = class(Exception);
  { The octets are at fault: a truncated value, a length that overruns its
    parent, a tag this position cannot hold. }
  EAsn1InputError = class(EAsn1Error);
  { The model or the configuration is at fault. }
  EAsn1InternalError = class(EAsn1Error);
  { The octets are valid BER but violate the canonical rules of the encoding
    rule in force. This is deliberately its own class: "not DER" and "not
    ASN.1" are different diagnoses and a caller validating a signed structure
    needs to tell them apart. }
  EAsn1CanonicalError = class(EAsn1InputError)
  strict private
    FRule: string;
  public
    constructor CreateFor(const ARuleName, AWhat, AWhere: string);
    { 'DER' or 'CER'. }
    property Rule: string read FRule;
  end;
  { A schema construct this parser does not implement. Named rather than
    guessed at, because mis-parsing a module silently produces an encoder that
    writes the wrong bytes. }
  EAsn1SchemaError = class(EAsn1Error);

  { --- tags ---------------------------------------------------------------

    The two high bits of the identifier octet, in their natural order, so the
    ordinal IS the bit pattern. }
  TAsn1TagClass = (Universal, Application, ContextSpecific, Private);

  { The universal tag numbers X.680 assigns. Only the ones this library
    implements are named; a universal tag outside this list is carried
    verbatim as TAsn1Kind.Unknown rather than being mapped to something
    plausible. }
  TAsn1UniversalTag = record
  public const
    EndOfContents    = 0;
    BooleanTag       = 1;
    IntegerTag       = 2;
    BitString        = 3;
    OctetString      = 4;
    NullTag          = 5;
    Oid              = 6;
    Real             = 9;
    Enumerated       = 10;
    Utf8String       = 12;
    RelativeOid      = 13;
    Sequence         = 16;
    SetTag           = 17;
    NumericString    = 18;
    PrintableString  = 19;
    TeletexString    = 20;
    Ia5String        = 22;
    UtcTime          = 23;
    GeneralizedTime  = 24;
    VisibleString    = 26;
    GeneralString    = 27;
    UniversalString  = 28;
    BmpString        = 30;
  end;

  { Which of X.690's three encoding rules. Passed to every encode and decode
    call: the same document model produces different octets under each, and a
    reader enforces different rules. }
  TAsn1EncodingRule = (
    { X.690 clause 8: every valid form allowed. Indefinite lengths,
      constructed strings, non-minimal lengths - all accepted on read, and all
      producible on write when the value asks for them. }
    Ber,
    { X.690 clause 10: the distinguished encoding rules. Definite lengths in
      the shortest form, primitive strings, sorted SET OF, one encoding per
      value. What a signature is computed over. }
    Der,
    { X.690 clause 9: the canonical encoding rules. Also one encoding per
      value, but a DIFFERENT one - indefinite length for every constructed
      value, and strings longer than a thousand octets split into
      thousand-octet segments, so that an encoder can stream without knowing
      the total length in advance. }
    Cer);

  { ------------------------------------------------------------------------
    ARBITRARY PRECISION INTEGERS

    ASN.1's INTEGER has no width. A certificate serial number is routinely
    twenty octets and an RSA modulus is two hundred and fifty-six, so an Int64
    is not a narrow case here - it is the exception. This record carries sign
    and magnitude and converts to and from X.690's two's-complement content
    octets exactly.

    No general arithmetic is offered. What is here is what encoding and
    decoding need: multiply-and-add by a small value, divide by a small value,
    and compare. Anything more would be a big-number library, and this is not
    one.
    ------------------------------------------------------------------------ }
  TAsn1BigInt = record
  strict private
    FNegative: System.Boolean;
    { Big-endian magnitude with no leading zero octets. An empty array is
      zero, which is the one value whose sign is not carried. }
    FMagnitude: TBytes;
    class function Normalize(const AMagnitude: TBytes): TBytes; static;
    class function MulAddSmall(const AMagnitude: TBytes;
      AMultiplier, AAddend: UInt32): TBytes; static;
    class function DivModSmall(const AMagnitude: TBytes; ADivisor: UInt32;
      out ARemainder: UInt32): TBytes; static;
    class function CompareMagnitude(const A, B: TBytes): System.Integer; static;
  public
    class function Zero: TAsn1BigInt; static;
    class function FromInt64(AValue: System.Int64): TAsn1BigInt; static;
    class function FromUInt64(AValue: UInt64): TAsn1BigInt; static;
    { ANegative is ignored when AMagnitude is zero: negative zero is not a
      value this record can hold, because it is not a value X.690 can
      encode. }
    class function FromMagnitude(ANegative: System.Boolean;
      const AMagnitude: TBytes): TAsn1BigInt; static;
    { Decimal text, with an optional leading '-' or '+'. }
    class function FromText(const AText: string): TAsn1BigInt; static;
    class function TryFromText(const AText: string;
      out AValue: TAsn1BigInt): System.Boolean; static;

    { X.690 clause 8.3: two's complement, big-endian, in the fewest octets
      that do not change the value. This is the DER form, and BER permits
      nothing shorter, so it is the only form ever written. }
    function ToTwosComplement: TBytes;
    { The inverse. ABytes must be at least one octet. }
    class function FromTwosComplement(const ABytes: TBytes): TAsn1BigInt; static;

    function ToText: string;
    function TryToInt64(out AValue: System.Int64): System.Boolean;
    function IsZero: System.Boolean;
    function Compare(const AOther: TAsn1BigInt): System.Integer;
    function Equals(const AOther: TAsn1BigInt): System.Boolean;

    property Negative: System.Boolean read FNegative;
    property Magnitude: TBytes read FMagnitude;
  end;

  { ------------------------------------------------------------------------
    OBJECT IDENTIFIER

    An OID is a path through a tree of arcs, not a string, and it is stored
    here as its arcs. Keeping it as text - '1.2.840.113549.1.1.11' - and
    re-splitting on demand would be smaller code and would quietly lose the
    distinction between an arc written 0 and an arc written 00, and would make
    an arc larger than Int64 unrepresentable. X.509 has such arcs.

    The first two arcs are packed into one subidentifier as arc1 * 40 + arc2,
    which is why arc1 is limited to 0, 1 or 2 and why arc2 is limited to 39
    when arc1 is 0 or 1 - and unlimited when arc1 is 2. That asymmetry is
    X.690's, not this library's, and it is enforced rather than papered over.
    ------------------------------------------------------------------------ }
  TAsn1Oid = record
  public
    Arcs: TArray<TAsn1BigInt>;
    class function FromArcs(const AArcs: array of System.Int64): TAsn1Oid; static;
    class function FromText(const AText: string): TAsn1Oid; static;
    class function TryFromText(const AText: string;
      out AOid: TAsn1Oid): System.Boolean; static;
    function ToText: string;
    function ArcCount: System.Integer;
    function Equals(const AOther: TAsn1Oid): System.Boolean;
  end;

  { What a TAsn1Value is, as opposed to what tag it carries.

    The two are not the same question. An IMPLICIT [0] IA5String has the tag
    [0] and the kind Ia5String: the tag says where it sits in its containing
    type and the kind says how its content octets are to be read. Losing the
    kind is how an implicitly tagged string turns into an opaque blob. }
  TAsn1Kind = (
    { A tag this library does not interpret. The content octets are kept
      verbatim and written back unchanged, which is what lets an unknown
      extension survive a round trip. }
    Unknown,
    BooleanValue,
    IntegerValue,
    BitString,
    OctetString,
    NullValue,
    Oid,
    RelativeOid,
    Enumerated,
    { X.690 clause 8.5. Kept as a Double, because that is what a
      caller has: the binary encoding is a base, an exponent and a
      mantissa, and an IEEE double decomposes into base 2 exactly. }
    RealValue,
    Utf8String,
    NumericString,
    PrintableString,
    Ia5String,
    VisibleString,
    BmpString,
    UniversalString,
    TeletexString,
    GeneralString,
    { SEQUENCE and SEQUENCE OF share universal tag 16, and SET and SET OF
      share 17, so nothing in the octets tells them apart. They are separate
      kinds anyway because the CANONICAL RULES differ: a SET's components are
      ordered by tag and a SET OF's by their encoded octets, and a decoder
      that cannot tell which it has cannot check either. Only a schema
      resolves it; raw decoding yields the structured form. }
    Sequence,
    SequenceOf,
    SetValue,
    SetOf,
    UtcTime,
    GeneralizedTime,
    { An explicitly tagged value: a constructed wrapper under an application,
      context-specific or private tag, holding exactly one inner value. }
    Tagged);

  { ------------------------------------------------------------------------
    THE DOCUMENT MODEL

    One node per tag-length-value. A custom encoder needs somewhere to build,
    a decoder needs somewhere to put what it found, and the schema layer needs
    something to validate against - and all three want the same tree.

    Lifetime: a parent OWNS its children. Add adopts. Encode and the schema
    layer borrow.
    ------------------------------------------------------------------------ }
  TAsn1Value = class
  strict private
    FTagClass: TAsn1TagClass;
    FTagNumber: UInt64;
    FConstructed: System.Boolean;
    FKind: TAsn1Kind;
    FBool: System.Boolean;
    FInt: TAsn1BigInt;
    FReal: System.Double;
    FBytes: TBytes;
    FUnusedBits: Byte;
    FText: string;
    FOid: TAsn1Oid;
    FDateTime: TDateTime;
    FItems: TObjectList<TAsn1Value>;
    FIndefinite: System.Boolean;
    FSegmentSize: System.Integer;
    FName: string;
    FChoiceAlternative: string;
    function GetCount: System.Integer;
    function GetItem(AIndex: System.Integer): TAsn1Value;
    procedure EnsureItems;
  public
    constructor Create(AKind: TAsn1Kind);
    destructor Destroy; override;

    class function NewBoolean(AValue: System.Boolean): TAsn1Value; static;
    class function NewInteger(AValue: System.Int64): TAsn1Value; overload; static;
    class function NewInteger(const AValue: TAsn1BigInt): TAsn1Value; overload; static;
    { AUnusedBits is the number of bits of the final octet that are NOT part
      of the value, 0..7, and it is part of the value's identity: a BIT STRING
      of nine bits and one of sixteen can hold the same two octets. Losing it
      is a defect, so it is a required argument rather than a property that
      defaults to zero. }
    class function NewBitString(const ABits: TBytes;
      AUnusedBits: Byte): TAsn1Value; static;
    class function NewOctetString(const ABytes: TBytes): TAsn1Value; static;
    class function NewNull: TAsn1Value; static;
    class function NewOid(const AOid: TAsn1Oid): TAsn1Value; overload; static;
    class function NewOid(const AText: string): TAsn1Value; overload; static;
    class function NewRelativeOid(const AOid: TAsn1Oid): TAsn1Value; static;
    class function NewEnumerated(AValue: System.Int64): TAsn1Value; static;
    { A REAL. Zero, minus zero, both infinities and a NaN are all
      representable - X.690 clause 8.5.9 gives each its own single
      content octet - so nothing here has to be refused or flattened. }
    class function NewReal(AValue: System.Double): TAsn1Value; static;
    { AKind must be one of the string kinds. The text is validated against
      that kind's permitted character repertoire on encode, not here, so a
      caller building a tree does not pay for it twice. }
    class function NewString(AKind: TAsn1Kind;
      const AText: string): TAsn1Value; static;
    class function NewSequence: TAsn1Value; static;
    class function NewSequenceOf: TAsn1Value; static;
    class function NewSet: TAsn1Value; static;
    class function NewSetOf: TAsn1Value; static;
    class function NewUtcTime(AValue: TDateTime): TAsn1Value; static;
    class function NewGeneralizedTime(AValue: TDateTime): TAsn1Value; static;

    { EXPLICIT tagging: a new constructed wrapper carrying the tag, with
      AInner as its single component. AInner is adopted. }
    class function NewExplicit(ATagClass: TAsn1TagClass; ATagNumber: UInt64;
      AInner: TAsn1Value): TAsn1Value; static;
    { IMPLICIT tagging: AInner's own tag is REPLACED. Its kind survives, which
      is the whole point - the content octets are still a PrintableString's
      content octets, and only the label on the front has changed. AInner is
      adopted and returned. }
    class function NewImplicit(ATagClass: TAsn1TagClass; ATagNumber: UInt64;
      AInner: TAsn1Value): TAsn1Value; static;

    { A tag this library does not interpret, with its content octets
      verbatim. }
    class function NewRaw(ATagClass: TAsn1TagClass; ATagNumber: UInt64;
      AConstructed: System.Boolean; const AContent: TBytes): TAsn1Value; static;

    { Adopts AValue. }
    procedure Add(AValue: TAsn1Value);
    { Releases AValue from this node's ownership and returns it. For a caller
      that needs to keep one component after the tree is freed. }
    function Extract(AIndex: System.Integer): TAsn1Value;

    function AsBoolean: System.Boolean;
    function AsInteger: TAsn1BigInt;
    function AsReal: System.Double;
    { Raises when the value does not fit, rather than truncating. }
    function AsInt64: System.Int64;
    { BIT STRING bits, OCTET STRING octets, or the raw content of an
      uninterpreted value. }
    function AsBytes: TBytes;
    function AsText: string;
    function AsOid: TAsn1Oid;
    function AsDateTime: TDateTime;

    function Describe: string;
    function Clone: TAsn1Value;
    { Deep structural and value equality, ignoring the encoding hints. }
    function SameAs(AOther: TAsn1Value): System.Boolean;

    property TagClass: TAsn1TagClass read FTagClass;
    property TagNumber: UInt64 read FTagNumber;
    property IsConstructed: System.Boolean read FConstructed;
    property Kind: TAsn1Kind read FKind;
    property UnusedBits: Byte read FUnusedBits;
    property Count: System.Integer read GetCount;
    property Items[AIndex: System.Integer]: TAsn1Value read GetItem; default;

    { The component name a schema gave this node, for diagnostics and for the
      dynamic bridge. Empty for anything decoded without a schema, because
      nothing in the octets carries a name. }
    property Name: string read FName write FName;

    { When a schema resolved this node as the alternative of a CHOICE, the
      alternative's name - kept apart from Name, which is the component
      the CHOICE fills. The dynamic bridge writes the CHOICE as an object
      with this one member, so the alternative survives a round trip. }
    property ChoiceAlternative: string read FChoiceAlternative
      write FChoiceAlternative;

    { --- BER encoding hints -------------------------------------------------

      These ask for one of BER's optional forms and have NO effect under DER
      or CER, which have exactly one encoding per value and would not be
      canonical if a caller could steer them. A decoder sets them to record
      what it found, so that a BER document read and written again comes back
      the same. }

    { Write this constructed value with the indefinite length form and a pair
      of end-of-contents octets. Ignored for a primitive value, which has no
      indefinite form. }
    property UseIndefiniteLength: System.Boolean
      read FIndefinite write FIndefinite;
    { Split this primitive string into constructed segments of at most this
      many octets. Zero, the default, means primitive. Ignored for anything
      that is not a string. }
    property SegmentSize: System.Integer read FSegmentSize write FSegmentSize;
  end;

{ ===========================================================================
  ATTRIBUTES - ASN.1's own, and only ASN.1's.
  =========================================================================== }

type
  { A context-specific, application or private tag on a member. Without it a
    member takes its type's universal tag, which is what an untagged SEQUENCE
    component does. }
  Asn1TagAttribute = class(TCustomAttribute)
  strict private
    FTagClass: TAsn1TagClass;
    FNumber: System.Integer;
  public
    { The common case: a context-specific tag, [0], [1], [2]. }
    constructor Create(ANumber: System.Integer); overload;
    constructor Create(ATagClass: TAsn1TagClass;
      ANumber: System.Integer); overload;
    property TagClass: TAsn1TagClass read FTagClass;
    property Number: System.Integer read FNumber;
  end;

  { The member may be absent. On write it is omitted when its TNullable is
    empty - without this attribute an empty nullable is written as NULL; on
    read its absence is not an error. }
  Asn1OptionalAttribute = class(TCustomAttribute)
  end;

  { Applied to the MEMBER whose record type is the CHOICE, naming the field
    of that record that says which alternative is
    selected. A CHOICE is not a bag of nullable fields that happen to be
    mostly empty - exactly one alternative is present and the encoding says
    which - so the selector is mandatory and its value is what the encoder
    reads to decide what to write.

    The selector field is an enumeration or an integer holding the zero-based
    position of the selected alternative among the type's other fields. }
  Asn1ChoiceAttribute = class(TCustomAttribute)
  strict private
    FSelectorField: string;
  public
    constructor Create(const ASelectorField: string);
    property SelectorField: string read FSelectorField;
  end;

  { IMPLICIT tagging for this member: the tag REPLACES the type's own, so the
    universal tag is gone from the octets and only the schema knows what the
    content is. Smaller, and unreadable without the module. }
  Asn1ImplicitAttribute = class(TCustomAttribute)
  end;

  { EXPLICIT tagging for this member: the tag WRAPS the type's own encoding,
    so both are present. Larger, and self-describing to the extent that BER
    ever is. The default when neither attribute appears, because it is what a
    module with no DEFINITIONS clause means. }
  Asn1ExplicitAttribute = class(TCustomAttribute)
  end;

  { Which ASN.1 string type a Delphi string member becomes. UTF8String is the
    default because it is the only one of them that can carry an arbitrary
    Delphi string without loss; PrintableString and the rest have restricted
    repertoires and an out-of-repertoire character raises rather than being
    substituted. }
  Asn1StringTypeAttribute = class(TCustomAttribute)
  strict private
    FKind: TAsn1Kind;
  public
    constructor Create(AKind: TAsn1Kind);
    property Kind: TAsn1Kind read FKind;
  end;

  Asn1IgnoreAttribute = class(TCustomAttribute)
  end;

  { ---------------------------------------------------------------------
    A TYPE THIS UNIT CANNOT MAP, MAPPED BY THE CALLER

    Every other format here has this, and ASN.1 needs it more than most: a
    peer's module often fixes a representation the Delphi type does not
    say - a Double as an INTEGER of scaled units, a PrintableString, a
    two-INTEGER SEQUENCE - and a caller has nowhere else to say so.

    The refusal message says exactly that. This is the thing it is telling
    the caller to reach for. }
  TCustomAsn1ValueSerializer = class
  public
    { The value as an ASN.1 value the caller owns until it is returned. }
    function Serialize(const AValue: TValue): TAsn1Value; virtual; abstract;
    { AValue is BORROWED and must not be freed here. }
    function Deserialize(AValue: TAsn1Value; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; virtual; abstract;
  end;

  TAsn1ValueSerializerClass = class of TCustomAsn1ValueSerializer;

  { The typed base, and the one to use: it names the Delphi type, so an
    implementation never touches TValue or PTypeInfo. }
  TCustomAsn1ValueSerializer<T> = class(TCustomAsn1ValueSerializer)
  public
    function SerializeValue(const AValue: T): TAsn1Value; virtual; abstract;
    function DeserializeValue(AValue: TAsn1Value;
      const AExisting: T): T; virtual; abstract;

    function Serialize(const AValue: TValue): TAsn1Value; override; final;
    function Deserialize(AValue: TAsn1Value; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; override; final;
  end;

  { Names the custom serializer for ONE member, which overrides any
    registration for the member's type. }
  Asn1SerializerAttribute = class(TCustomAttribute)
  strict private
    FSerializerClass: TAsn1ValueSerializerClass;
  public
    constructor Create(ASerializerClass: TAsn1ValueSerializerClass);
    property SerializerClass: TAsn1ValueSerializerClass read FSerializerClass;
  end;

{ =========================================================================== }

type
  TAsn1Serializer = class
  strict private
    class function DoSerialize(ATypeInfo: PTypeInfo; const AValue: TValue;
      ARule: TAsn1EncodingRule): TBytes; static;
    class function DoDeserialize(ATypeInfo: PTypeInfo; const AData: TBytes;
      ARule: TAsn1EncodingRule): TValue; static;
    class procedure DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TAsn1ValueSerializerClass); static;
    class procedure DoResetConfiguration; static;
  public
    { --- the document model ------------------------------------------------ }

    { Encodes a borrowed tree under the given rule. Under DER and CER the
      result is canonical by construction: the components of a SET OF are
      sorted, a SET's are put in tag order, and the encoding hints on the
      tree are ignored. }
    class function Encode(AValue: TAsn1Value;
      ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): TBytes; static;

    { --- raw decoding, as a DIAGNOSTIC ------------------------------------

      Decodes the octets into a tree of tags with no schema, interpreting
      universal tags by their number - which is the one thing X.690 does let a
      reader do without a module.

      THIS IS NOT STRUCTURAL PARSING and it is not offered as one. A tree
      whose nodes are called "context-specific 0" is not a document: it has no
      member names, it cannot tell a SEQUENCE from a SEQUENCE OF, and every
      implicitly tagged value in it has lost its type. It is here because
      inspecting somebody else's certificate is a real thing to want, and
      because a byte-exact re-encode is how this library proves its writer
      agrees with everyone else's.

      The caller owns the result. ARule selects how strictly the octets are
      checked: Ber accepts every valid form, Der and Cer reject anything
      outside their canonical subset. }
    class function ParseTlv(const AData: TBytes;
      ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): TAsn1Value; static;

    { --- schema-driven ----------------------------------------------------

      ASchema must be a TAsn1Schema from PascalForge.Asn1.Schema; the
      parameter is typed as the base class only because that unit sits above
      this one. A schema for another format raises
      ESerializationSchemaRequired rather than being ignored. }

    class function DecodeWithSchema(const AData: TBytes;
      ASchema: TSerializationSchema; const ATypeName: string;
      ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): TAsn1Value; static;
    class function EncodeWithSchema(AValue: TAsn1Value;
      ASchema: TSerializationSchema; const ATypeName: string;
      ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): TBytes; static;

    { The dynamic tree, for cross-format conversion. Both directions need the
      schema and the name of the type being converted, and say so by name when
      they do not have them. }
    class function ToDynamic(const AData: TBytes; ASchema: TSerializationSchema;
      const ATypeName: string;
      ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): TDynamicValue; static;
    class function FromDynamic(AValue: TDynamicValue;
      ASchema: TSerializationSchema; const ATypeName: string;
      ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): TBytes; static;

    { --- contract-aware ----------------------------------------------------

      The Delphi type is the schema. A record or class becomes a SEQUENCE of
      its fields in declaration order, honouring the ASN.1 attributes above.
      A type whose members cannot be mapped raises, naming the member and the
      Delphi type, rather than dropping it. }
    class function Serialize<T>(const AValue: T;
      ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): TBytes; static;
    class function Deserialize<T>(const AData: TBytes;
      ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): T; static;

    { --- registrations -----------------------------------------------------

      A custom serializer for every value of a type, wherever it appears:

          TAsn1Serializer.RegisterTypeSerializer<TCoordinate>(TAsn1Coordinate);

      [Asn1Serializer] on a member overrides this for that member. }
    class procedure RegisterTypeSerializer<T>(
      ASerializerClass: TAsn1ValueSerializerClass); static;
    { Tests only. }
    class procedure ResetConfiguration; static;
    { Configuration freezes by itself at the first serialization; this
      freezes it earlier, at a point the application chooses. }
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;
  end;

{ The X.680 name of an encoding rule, for diagnostics: 'BER', 'DER', 'CER'. }
function Asn1RuleName(ARule: TAsn1EncodingRule): string;
{ The rule that belongs to a TSerializationFormat value. Raises for a format
  that is not one of the three ASN.1 values. }
function Asn1RuleOf(AFormat: TSerializationFormat): TAsn1EncodingRule;
function Asn1FormatOf(ARule: TAsn1EncodingRule): TSerializationFormat;
{ A readable name for a tag, as a module would write it: '[0]',
  '[APPLICATION 3]', 'SEQUENCE'. }
function Asn1TagName(ATagClass: TAsn1TagClass; ATagNumber: UInt64;
  AConstructed: Boolean): string;
function Asn1KindName(AKind: TAsn1Kind): string;
{ True for the kinds whose content octets are text. }
function Asn1IsStringKind(AKind: TAsn1Kind): Boolean;

implementation

uses
  System.Math, System.DateUtils,
  PascalForge.Asn1.Internal;

{ --- free functions ------------------------------------------------------- }

function Asn1RuleName(ARule: TAsn1EncodingRule): string;
begin
  case ARule of
    TAsn1EncodingRule.Ber: Result := 'BER';
    TAsn1EncodingRule.Der: Result := 'DER';
  else
    Result := 'CER';
  end;
end;

function Asn1RuleOf(AFormat: TSerializationFormat): TAsn1EncodingRule;
begin
  case AFormat of
    TSerializationFormat.Asn1Ber: Result := TAsn1EncodingRule.Ber;
    TSerializationFormat.Asn1Der: Result := TAsn1EncodingRule.Der;
    TSerializationFormat.Asn1Cer: Result := TAsn1EncodingRule.Cer;
  else
    raise EAsn1InternalError.CreateFmt(
      'The format %s is not one of the ASN.1 encoding rules.',
      [TSerializationFormats.FormatName(AFormat)]);
  end;
end;

function Asn1FormatOf(ARule: TAsn1EncodingRule): TSerializationFormat;
begin
  case ARule of
    TAsn1EncodingRule.Ber: Result := TSerializationFormat.Asn1Ber;
    TAsn1EncodingRule.Der: Result := TSerializationFormat.Asn1Der;
  else
    Result := TSerializationFormat.Asn1Cer;
  end;
end;

function Asn1TagName(ATagClass: TAsn1TagClass; ATagNumber: UInt64;
  AConstructed: Boolean): string;
begin
  case ATagClass of
    TAsn1TagClass.Universal:
      { The whole number decides: narrowed, 2^32 + 1 would name BOOLEAN. }
      if ATagNumber > UInt64(TAsn1UniversalTag.BmpString) then
        Result := Format('[UNIVERSAL %u]', [ATagNumber])
      else
      case Integer(ATagNumber) of
        TAsn1UniversalTag.BooleanTag:      Result := 'BOOLEAN';
        TAsn1UniversalTag.IntegerTag:      Result := 'INTEGER';
        TAsn1UniversalTag.BitString:       Result := 'BIT STRING';
        TAsn1UniversalTag.OctetString:     Result := 'OCTET STRING';
        TAsn1UniversalTag.NullTag:         Result := 'NULL';
        TAsn1UniversalTag.Oid:             Result := 'OBJECT IDENTIFIER';
        TAsn1UniversalTag.Real:            Result := 'REAL';
        TAsn1UniversalTag.Enumerated:      Result := 'ENUMERATED';
        TAsn1UniversalTag.Utf8String:      Result := 'UTF8String';
        TAsn1UniversalTag.RelativeOid:     Result := 'RELATIVE-OID';
        TAsn1UniversalTag.Sequence:        Result := 'SEQUENCE';
        TAsn1UniversalTag.SetTag:          Result := 'SET';
        TAsn1UniversalTag.NumericString:   Result := 'NumericString';
        TAsn1UniversalTag.PrintableString: Result := 'PrintableString';
        TAsn1UniversalTag.TeletexString:   Result := 'TeletexString';
        TAsn1UniversalTag.Ia5String:       Result := 'IA5String';
        TAsn1UniversalTag.UtcTime:         Result := 'UTCTime';
        TAsn1UniversalTag.GeneralizedTime: Result := 'GeneralizedTime';
        TAsn1UniversalTag.VisibleString:   Result := 'VisibleString';
        TAsn1UniversalTag.GeneralString:   Result := 'GeneralString';
        TAsn1UniversalTag.UniversalString: Result := 'UniversalString';
        TAsn1UniversalTag.BmpString:       Result := 'BMPString';
      else
        Result := Format('[UNIVERSAL %u]', [ATagNumber]);
      end;
    TAsn1TagClass.Application:
      Result := Format('[APPLICATION %u]', [ATagNumber]);
    TAsn1TagClass.ContextSpecific:
      Result := Format('[%u]', [ATagNumber]);
  else
    Result := Format('[PRIVATE %u]', [ATagNumber]);
  end;
  if AConstructed and (ATagClass <> TAsn1TagClass.Universal) then
    Result := Result + ' (constructed)';
end;

function Asn1KindName(AKind: TAsn1Kind): string;
begin
  case AKind of
    TAsn1Kind.Unknown:         Result := 'an uninterpreted tag';
    TAsn1Kind.BooleanValue:    Result := 'BOOLEAN';
    TAsn1Kind.IntegerValue:    Result := 'INTEGER';
    TAsn1Kind.BitString:       Result := 'BIT STRING';
    TAsn1Kind.OctetString:     Result := 'OCTET STRING';
    TAsn1Kind.NullValue:       Result := 'NULL';
    TAsn1Kind.Oid:             Result := 'OBJECT IDENTIFIER';
    TAsn1Kind.RelativeOid:     Result := 'RELATIVE-OID';
    TAsn1Kind.Enumerated:      Result := 'ENUMERATED';
    TAsn1Kind.RealValue:       Result := 'REAL';
    TAsn1Kind.Utf8String:      Result := 'UTF8String';
    TAsn1Kind.NumericString:   Result := 'NumericString';
    TAsn1Kind.PrintableString: Result := 'PrintableString';
    TAsn1Kind.Ia5String:       Result := 'IA5String';
    TAsn1Kind.VisibleString:   Result := 'VisibleString';
    TAsn1Kind.BmpString:       Result := 'BMPString';
    TAsn1Kind.UniversalString: Result := 'UniversalString';
    TAsn1Kind.TeletexString:   Result := 'TeletexString';
    TAsn1Kind.GeneralString:   Result := 'GeneralString';
    TAsn1Kind.Sequence:        Result := 'SEQUENCE';
    TAsn1Kind.SequenceOf:      Result := 'SEQUENCE OF';
    TAsn1Kind.SetValue:        Result := 'SET';
    TAsn1Kind.SetOf:           Result := 'SET OF';
    TAsn1Kind.UtcTime:         Result := 'UTCTime';
    TAsn1Kind.GeneralizedTime: Result := 'GeneralizedTime';
  else
    Result := 'a tagged value';
  end;
end;

function Asn1IsStringKind(AKind: TAsn1Kind): Boolean;
begin
  Result := AKind in [TAsn1Kind.Utf8String, TAsn1Kind.NumericString,
    TAsn1Kind.PrintableString, TAsn1Kind.Ia5String, TAsn1Kind.VisibleString,
    TAsn1Kind.BmpString, TAsn1Kind.UniversalString, TAsn1Kind.TeletexString,
    TAsn1Kind.GeneralString];
end;

{ --- EAsn1CanonicalError -------------------------------------------------- }

constructor EAsn1CanonicalError.CreateFor(const ARuleName, AWhat,
  AWhere: string);
begin
  FRule := ARuleName;
  inherited CreateFmt(
    'These octets are valid BER but they are not %s: %s, at %s.' + sLineBreak +
    sLineBreak +
    '%s admits exactly one encoding of any value, which is what makes it ' +
    'usable under a signature. Accepting a second one here would mean two ' +
    'byte sequences verify as the same value, so this is refused rather ' +
    'than tolerated. Decode it as BER if you only need to read it.',
    [ARuleName, AWhat, AWhere, ARuleName]);
end;

{ --- TAsn1BigInt ---------------------------------------------------------- }

class function TAsn1BigInt.Normalize(const AMagnitude: TBytes): TBytes;
var
  First, I: Integer;
begin
  First := 0;
  while (First < Length(AMagnitude)) and (AMagnitude[First] = 0) do Inc(First);
  SetLength(Result, Length(AMagnitude) - First);
  for I := 0 to Integer(High(Result)) do Result[I] := AMagnitude[First + I];
end;

class function TAsn1BigInt.MulAddSmall(const AMagnitude: TBytes;
  AMultiplier, AAddend: UInt32): TBytes;
var
  I: Integer;
  Carry: UInt64;
  Work: TBytes;
  Extra: TBytes;
  ExtraCount: Integer;
begin
  SetLength(Work, Length(AMagnitude));
  Carry := AAddend;
  for I := Integer(High(AMagnitude)) downto 0 do
  begin
    Carry := Carry + UInt64(AMagnitude[I]) * AMultiplier;
    Work[I] := Byte(Carry and $FF);
    Carry := Carry shr 8;
  end;
  if Carry = 0 then Exit(Normalize(Work));

  SetLength(Extra, 8);
  ExtraCount := 0;
  while Carry <> 0 do
  begin
    Extra[ExtraCount] := Byte(Carry and $FF);
    Carry := Carry shr 8;
    Inc(ExtraCount);
  end;
  SetLength(Result, ExtraCount + Length(Work));
  { Extra holds the carry least-significant first; the result is
    big-endian. }
  for I := 0 to ExtraCount - 1 do Result[I] := Extra[ExtraCount - 1 - I];
  for I := 0 to Integer(High(Work)) do Result[ExtraCount + I] := Work[I];
  Result := Normalize(Result);
end;

class function TAsn1BigInt.DivModSmall(const AMagnitude: TBytes;
  ADivisor: UInt32; out ARemainder: UInt32): TBytes;
var
  I: Integer;
  Acc: UInt64;
  Work: TBytes;
begin
  if ADivisor = 0 then
    raise EAsn1InternalError.Create('Division by zero in ASN.1 integer text ' +
      'conversion.');
  SetLength(Work, Length(AMagnitude));
  Acc := 0;
  { The invariant is that Acc stays below ADivisor, so Acc * 256 + octet stays
    below ADivisor * 256 and the quotient octet cannot overflow a byte. }
  for I := 0 to Integer(High(AMagnitude)) do
  begin
    Acc := (Acc shl 8) or AMagnitude[I];
    Work[I] := Byte(Acc div ADivisor);
    Acc := Acc mod ADivisor;
  end;
  ARemainder := UInt32(Acc);
  Result := Normalize(Work);
end;

class function TAsn1BigInt.CompareMagnitude(const A, B: TBytes): Integer;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(CompareValue(Length(A), Length(B)));
  for I := 0 to Integer(High(A)) do
    if A[I] <> B[I] then
      Exit(CompareValue(A[I], B[I]));
  Result := 0;
end;

class function TAsn1BigInt.Zero: TAsn1BigInt;
begin
  Result.FNegative := False;
  Result.FMagnitude := nil;
end;

class function TAsn1BigInt.FromUInt64(AValue: UInt64): TAsn1BigInt;
var
  Work: TBytes;
  I: Integer;
begin
  SetLength(Work, 8);
  for I := 7 downto 0 do
  begin
    Work[I] := Byte(AValue and $FF);
    AValue := AValue shr 8;
  end;
  Result.FNegative := False;
  Result.FMagnitude := Normalize(Work);
end;

class function TAsn1BigInt.FromInt64(AValue: Int64): TAsn1BigInt;
begin
  if AValue < 0 then
  begin
    { Low(Int64) has no positive counterpart, so the magnitude is taken on the
      unsigned representation rather than by negating. }
    Result := FromUInt64(UInt64(0) - UInt64(AValue));
    Result.FNegative := Length(Result.FMagnitude) > 0;
  end
  else
    Result := FromUInt64(UInt64(AValue));
end;

class function TAsn1BigInt.FromMagnitude(ANegative: Boolean;
  const AMagnitude: TBytes): TAsn1BigInt;
begin
  Result.FMagnitude := Normalize(AMagnitude);
  Result.FNegative := ANegative and (Length(Result.FMagnitude) > 0);
end;

class function TAsn1BigInt.TryFromText(const AText: string;
  out AValue: TAsn1BigInt): Boolean;
var
  I, Start: Integer;
  Neg: Boolean;
  Mag: TBytes;
  Digit: UInt32;
begin
  AValue := Zero;
  if AText = '' then Exit(False);
  Start := Low(string);
  Neg := False;
  if (AText[Start] = '-') or (AText[Start] = '+') then
  begin
    Neg := AText[Start] = '-';
    Inc(Start);
  end;
  if Start > High(AText) then Exit(False);
  Mag := nil;
  for I := Start to High(AText) do
  begin
    if (AText[I] < '0') or (AText[I] > '9') then Exit(False);
    Digit := UInt32(Ord(AText[I]) - Ord('0'));
    Mag := MulAddSmall(Mag, 10, Digit);
  end;
  AValue := FromMagnitude(Neg, Mag);
  Result := True;
end;

class function TAsn1BigInt.FromText(const AText: string): TAsn1BigInt;
begin
  if not TryFromText(AText, Result) then
    raise EAsn1InputError.CreateFmt(
      '"%s" is not a decimal integer.', [AText]);
end;

function TAsn1BigInt.ToText: string;
var
  Mag: TBytes;
  Rem: UInt32;
  Chunk: string;
begin
  if Length(FMagnitude) = 0 then Exit('0');
  Result := '';
  Mag := FMagnitude;
  { Nine digits at a time: a billion is the largest power of ten whose
    remainder still fits the UInt32 the division helper returns. }
  while Length(Mag) > 0 do
  begin
    Mag := DivModSmall(Mag, 1000000000, Rem);
    if Length(Mag) = 0 then
      Chunk := UIntToStr(Rem)
    else
      Chunk := Format('%.9u', [Rem]);
    Result := Chunk + Result;
  end;
  if FNegative then Result := '-' + Result;
end;

function TAsn1BigInt.TryToInt64(out AValue: Int64): Boolean;
var
  I: Integer;
  Acc: UInt64;
begin
  AValue := 0;
  if Length(FMagnitude) = 0 then Exit(True);
  if Length(FMagnitude) > 8 then Exit(False);
  Acc := 0;
  for I := 0 to Integer(High(FMagnitude)) do Acc := (Acc shl 8) or FMagnitude[I];
  if FNegative then
  begin
    { Low(Int64)'s magnitude is one larger than High(Int64), and it is a
      perfectly good value, so it is admitted explicitly. }
    if Acc > UInt64(High(Int64)) + 1 then Exit(False);
    AValue := Int64(UInt64(0) - Acc);
  end
  else
  begin
    if Acc > UInt64(High(Int64)) then Exit(False);
    AValue := Int64(Acc);
  end;
  Result := True;
end;

function TAsn1BigInt.IsZero: Boolean;
begin
  Result := Length(FMagnitude) = 0;
end;

function TAsn1BigInt.Compare(const AOther: TAsn1BigInt): Integer;
begin
  if FNegative <> AOther.FNegative then
  begin
    if FNegative then Exit(-1) else Exit(1);
  end;
  Result := CompareMagnitude(FMagnitude, AOther.FMagnitude);
  if FNegative then Result := -Result;
end;

function TAsn1BigInt.Equals(const AOther: TAsn1BigInt): Boolean;
begin
  Result := Compare(AOther) = 0;
end;

function TAsn1BigInt.ToTwosComplement: TBytes;
var
  I, N: Integer;
  Carry: Integer;
begin
  if Length(FMagnitude) = 0 then
  begin
    SetLength(Result, 1);
    Result[0] := 0;
    Exit;
  end;
  N := Integer(Length(FMagnitude));
  if not FNegative then
  begin
    { A leading octet with its top bit set would read back as negative, so a
      zero octet goes in front - and only then. }
    if FMagnitude[0] and $80 <> 0 then
    begin
      SetLength(Result, N + 1);
      Result[0] := 0;
      for I := 0 to N - 1 do Result[I + 1] := FMagnitude[I];
    end
    else
      Result := Copy(FMagnitude, 0, N);
    Exit;
  end;

  { Two's complement of the magnitude over its own width. }
  SetLength(Result, N);
  Carry := 1;
  for I := N - 1 downto 0 do
  begin
    Carry := (FMagnitude[I] xor $FF) + Carry;
    Result[I] := Byte(Carry and $FF);
    Carry := Carry shr 8;
  end;
  { If the top bit did not end up set, the value would read back positive, so
    an all-ones octet goes in front. A magnitude that is an exact power of two
    complements to itself with the top bit already set and needs nothing. }
  if Result[0] and $80 = 0 then
    Result := Concat(TBytes.Create($FF), Result);
end;

class function TAsn1BigInt.FromTwosComplement(const ABytes: TBytes): TAsn1BigInt;
var
  I, N: Integer;
  Work: TBytes;
  Carry: Integer;
begin
  N := Integer(Length(ABytes));
  if N = 0 then
    raise EAsn1InputError.Create(
      'An INTEGER must have at least one content octet; this one has none.');
  if ABytes[0] and $80 = 0 then
  begin
    Result.FNegative := False;
    Result.FMagnitude := Normalize(ABytes);
    Exit;
  end;
  SetLength(Work, N);
  Carry := 1;
  for I := N - 1 downto 0 do
  begin
    Carry := (ABytes[I] xor $FF) + Carry;
    Work[I] := Byte(Carry and $FF);
    Carry := Carry shr 8;
  end;
  Result.FMagnitude := Normalize(Work);
  Result.FNegative := Length(Result.FMagnitude) > 0;
end;

{ --- TAsn1Oid ------------------------------------------------------------- }

class function TAsn1Oid.FromArcs(const AArcs: array of Int64): TAsn1Oid;
var
  I: Integer;
begin
  SetLength(Result.Arcs, Length(AArcs));
  for I := 0 to Integer(High(AArcs)) do Result.Arcs[I] := TAsn1BigInt.FromInt64(AArcs[I]);
end;

class function TAsn1Oid.TryFromText(const AText: string;
  out AOid: TAsn1Oid): Boolean;
var
  Parts: TArray<string>;
  I: Integer;
begin
  AOid.Arcs := nil;
  if AText = '' then Exit(False);
  Parts := AText.Split(['.']);
  if Length(Parts) = 0 then Exit(False);
  SetLength(AOid.Arcs, Length(Parts));
  for I := 0 to Integer(High(Parts)) do
  begin
    if not TAsn1BigInt.TryFromText(Parts[I], AOid.Arcs[I]) then Exit(False);
    if AOid.Arcs[I].Negative then Exit(False);
  end;
  Result := True;
end;

class function TAsn1Oid.FromText(const AText: string): TAsn1Oid;
begin
  if not TryFromText(AText, Result) then
    raise EAsn1InputError.CreateFmt(
      '"%s" is not an object identifier: arcs are non-negative integers ' +
      'separated by dots.', [AText]);
end;

function TAsn1Oid.ToText: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Integer(High(Arcs)) do
  begin
    if I > 0 then Result := Result + '.';
    Result := Result + Arcs[I].ToText;
  end;
end;

function TAsn1Oid.ArcCount: Integer;
begin
  Result := Integer(Length(Arcs));
end;

function TAsn1Oid.Equals(const AOther: TAsn1Oid): Boolean;
var
  I: Integer;
begin
  if Length(Arcs) <> Length(AOther.Arcs) then Exit(False);
  for I := 0 to Integer(High(Arcs)) do
    if not Arcs[I].Equals(AOther.Arcs[I]) then Exit(False);
  Result := True;
end;

{ --- TAsn1Value ----------------------------------------------------------- }

constructor TAsn1Value.Create(AKind: TAsn1Kind);
begin
  inherited Create;
  FKind := AKind;
  FTagClass := TAsn1TagClass.Universal;
  FInt := TAsn1BigInt.Zero;
end;

destructor TAsn1Value.Destroy;
begin
  FItems.Free;
  inherited;
end;

procedure TAsn1Value.EnsureItems;
begin
  if FItems = nil then FItems := TObjectList<TAsn1Value>.Create(True);
end;

function TAsn1Value.GetCount: Integer;
begin
  if FItems = nil then Result := 0 else Result := Integer(FItems.Count);
end;

function TAsn1Value.GetItem(AIndex: Integer): TAsn1Value;
begin
  if (FItems = nil) or (AIndex < 0) or (AIndex >= FItems.Count) then
    raise EAsn1InternalError.CreateFmt(
      'Component %d does not exist; %s has %d.',
      [AIndex, Describe, GetCount]);
  Result := FItems[AIndex];
end;

procedure TAsn1Value.Add(AValue: TAsn1Value);
begin
  if AValue = nil then
    raise EAsn1InternalError.Create('A nil component cannot be added.');
  if not FConstructed then
  begin
    AValue.Free;
    raise EAsn1InternalError.CreateFmt(
      '%s is primitive and cannot hold components.', [Describe]);
  end;
  EnsureItems;
  FItems.Add(AValue);
end;

function TAsn1Value.Extract(AIndex: Integer): TAsn1Value;
begin
  Result := GetItem(AIndex);
  FItems.Extract(Result);
end;

class function TAsn1Value.NewBoolean(AValue: Boolean): TAsn1Value;
begin
  Result := TAsn1Value.Create(TAsn1Kind.BooleanValue);
  Result.FTagNumber := TAsn1UniversalTag.BooleanTag;
  Result.FBool := AValue;
end;

class function TAsn1Value.NewInteger(AValue: Int64): TAsn1Value;
begin
  Result := NewInteger(TAsn1BigInt.FromInt64(AValue));
end;

class function TAsn1Value.NewInteger(const AValue: TAsn1BigInt): TAsn1Value;
begin
  Result := TAsn1Value.Create(TAsn1Kind.IntegerValue);
  Result.FTagNumber := TAsn1UniversalTag.IntegerTag;
  Result.FInt := AValue;
end;

class function TAsn1Value.NewBitString(const ABits: TBytes;
  AUnusedBits: Byte): TAsn1Value;
begin
  if AUnusedBits > 7 then
    raise EAsn1InternalError.CreateFmt(
      'A BIT STRING has 0 to 7 unused bits in its final octet, not %d.',
      [AUnusedBits]);
  if (Length(ABits) = 0) and (AUnusedBits <> 0) then
    raise EAsn1InternalError.Create(
      'An empty BIT STRING has no final octet, so it cannot have unused ' +
      'bits in one.');
  Result := TAsn1Value.Create(TAsn1Kind.BitString);
  Result.FTagNumber := TAsn1UniversalTag.BitString;
  Result.FBytes := Copy(ABits, 0, Length(ABits));
  Result.FUnusedBits := AUnusedBits;
end;

class function TAsn1Value.NewOctetString(const ABytes: TBytes): TAsn1Value;
begin
  Result := TAsn1Value.Create(TAsn1Kind.OctetString);
  Result.FTagNumber := TAsn1UniversalTag.OctetString;
  Result.FBytes := Copy(ABytes, 0, Length(ABytes));
end;

class function TAsn1Value.NewNull: TAsn1Value;
begin
  Result := TAsn1Value.Create(TAsn1Kind.NullValue);
  Result.FTagNumber := TAsn1UniversalTag.NullTag;
end;

class function TAsn1Value.NewOid(const AOid: TAsn1Oid): TAsn1Value;
begin
  Result := TAsn1Value.Create(TAsn1Kind.Oid);
  Result.FTagNumber := TAsn1UniversalTag.Oid;
  Result.FOid := AOid;
end;

class function TAsn1Value.NewOid(const AText: string): TAsn1Value;
begin
  Result := NewOid(TAsn1Oid.FromText(AText));
end;

class function TAsn1Value.NewRelativeOid(const AOid: TAsn1Oid): TAsn1Value;
begin
  Result := TAsn1Value.Create(TAsn1Kind.RelativeOid);
  Result.FTagNumber := TAsn1UniversalTag.RelativeOid;
  Result.FOid := AOid;
end;

class function TAsn1Value.NewEnumerated(AValue: Int64): TAsn1Value;
begin
  Result := TAsn1Value.Create(TAsn1Kind.Enumerated);
  Result.FTagNumber := TAsn1UniversalTag.Enumerated;
  Result.FInt := TAsn1BigInt.FromInt64(AValue);
end;

class function TAsn1Value.NewReal(AValue: Double): TAsn1Value;
begin
  Result := TAsn1Value.Create(TAsn1Kind.RealValue);
  Result.FTagNumber := TAsn1UniversalTag.Real;
  Result.FReal := AValue;
end;

class function TAsn1Value.NewString(AKind: TAsn1Kind;
  const AText: string): TAsn1Value;
begin
  if not Asn1IsStringKind(AKind) then
    raise EAsn1InternalError.CreateFmt(
      '%s is not a string type.', [Asn1KindName(AKind)]);
  Result := TAsn1Value.Create(AKind);
  Result.FTagNumber := UInt64(Asn1UniversalTagOfKind(AKind));
  Result.FText := AText;
end;

class function TAsn1Value.NewSequence: TAsn1Value;
begin
  Result := TAsn1Value.Create(TAsn1Kind.Sequence);
  Result.FTagNumber := TAsn1UniversalTag.Sequence;
  Result.FConstructed := True;
end;

class function TAsn1Value.NewSequenceOf: TAsn1Value;
begin
  Result := TAsn1Value.Create(TAsn1Kind.SequenceOf);
  Result.FTagNumber := TAsn1UniversalTag.Sequence;
  Result.FConstructed := True;
end;

class function TAsn1Value.NewSet: TAsn1Value;
begin
  Result := TAsn1Value.Create(TAsn1Kind.SetValue);
  Result.FTagNumber := TAsn1UniversalTag.SetTag;
  Result.FConstructed := True;
end;

class function TAsn1Value.NewSetOf: TAsn1Value;
begin
  Result := TAsn1Value.Create(TAsn1Kind.SetOf);
  Result.FTagNumber := TAsn1UniversalTag.SetTag;
  Result.FConstructed := True;
end;

{ The text is spelled BEFORE the value exists: spelling refuses a moment
  outside the years 1 to 9999, and a refusal after Create leaked the value. }
class function TAsn1Value.NewUtcTime(AValue: TDateTime): TAsn1Value;
var
  Text: string;
begin
  Text := Asn1EncodeUtcTime(AValue);
  Result := TAsn1Value.Create(TAsn1Kind.UtcTime);
  Result.FTagNumber := TAsn1UniversalTag.UtcTime;
  Result.FDateTime := AValue;
  Result.FText := Text;
end;

class function TAsn1Value.NewGeneralizedTime(AValue: TDateTime): TAsn1Value;
var
  Text: string;
begin
  Text := Asn1EncodeGeneralizedTime(AValue);
  Result := TAsn1Value.Create(TAsn1Kind.GeneralizedTime);
  Result.FTagNumber := TAsn1UniversalTag.GeneralizedTime;
  Result.FDateTime := AValue;
  Result.FText := Text;
end;

class function TAsn1Value.NewExplicit(ATagClass: TAsn1TagClass;
  ATagNumber: UInt64; AInner: TAsn1Value): TAsn1Value;
begin
  if AInner = nil then
    raise EAsn1InternalError.Create(
      'An explicitly tagged value wraps something; nil is not something.');
  if ATagClass = TAsn1TagClass.Universal then
  begin
    AInner.Free;
    raise EAsn1InternalError.Create(
      'A universal tag cannot be applied to a value: the universal class is ' +
      'the one X.680 reserves for the built-in types.');
  end;
  Result := TAsn1Value.Create(TAsn1Kind.Tagged);
  Result.FTagClass := ATagClass;
  Result.FTagNumber := ATagNumber;
  Result.FConstructed := True;
  Result.EnsureItems;
  Result.FItems.Add(AInner);
end;

class function TAsn1Value.NewImplicit(ATagClass: TAsn1TagClass;
  ATagNumber: UInt64; AInner: TAsn1Value): TAsn1Value;
begin
  if AInner = nil then
    raise EAsn1InternalError.Create(
      'An implicitly tagged value re-labels something; nil is not ' +
      'something.');
  if ATagClass = TAsn1TagClass.Universal then
  begin
    AInner.Free;
    raise EAsn1InternalError.Create(
      'A universal tag cannot be applied to a value: the universal class is ' +
      'the one X.680 reserves for the built-in types.');
  end;
  Result := AInner;
  Result.FTagClass := ATagClass;
  Result.FTagNumber := ATagNumber;
end;

class function TAsn1Value.NewRaw(ATagClass: TAsn1TagClass; ATagNumber: UInt64;
  AConstructed: Boolean; const AContent: TBytes): TAsn1Value;
begin
  Result := TAsn1Value.Create(TAsn1Kind.Unknown);
  Result.FTagClass := ATagClass;
  Result.FTagNumber := ATagNumber;
  Result.FConstructed := AConstructed;
  Result.FBytes := Copy(AContent, 0, Length(AContent));
end;

function TAsn1Value.AsBoolean: Boolean;
begin
  if FKind <> TAsn1Kind.BooleanValue then
    raise EAsn1InternalError.CreateFmt('%s is not a BOOLEAN.', [Describe]);
  Result := FBool;
end;

function TAsn1Value.AsInteger: TAsn1BigInt;
begin
  if not (FKind in [TAsn1Kind.IntegerValue, TAsn1Kind.Enumerated]) then
    raise EAsn1InternalError.CreateFmt('%s is not an INTEGER.', [Describe]);
  Result := FInt;
end;

function TAsn1Value.AsReal: Double;
begin
  if FKind <> TAsn1Kind.RealValue then
    raise EAsn1InternalError.CreateFmt('%s is not a REAL.', [Describe]);
  Result := FReal;
end;

function TAsn1Value.AsInt64: Int64;
begin
  if not AsInteger.TryToInt64(Result) then
    raise EAsn1InputError.CreateFmt(
      'The INTEGER %s does not fit in an Int64. ASN.1 integers have no ' +
      'width, so read this one with AsInteger and keep it as a ' +
      'TAsn1BigInt.', [FInt.ToText]);
end;

function TAsn1Value.AsBytes: TBytes;
begin
  Result := FBytes;
end;

function TAsn1Value.AsText: string;
begin
  if not (Asn1IsStringKind(FKind) or
          (FKind in [TAsn1Kind.UtcTime, TAsn1Kind.GeneralizedTime])) then
    raise EAsn1InternalError.CreateFmt('%s is not a string.', [Describe]);
  Result := FText;
end;

function TAsn1Value.AsOid: TAsn1Oid;
begin
  if not (FKind in [TAsn1Kind.Oid, TAsn1Kind.RelativeOid]) then
    raise EAsn1InternalError.CreateFmt(
      '%s is not an object identifier.', [Describe]);
  Result := FOid;
end;

function TAsn1Value.AsDateTime: TDateTime;
begin
  if not (FKind in [TAsn1Kind.UtcTime, TAsn1Kind.GeneralizedTime]) then
    raise EAsn1InternalError.CreateFmt('%s is not a time.', [Describe]);
  Result := FDateTime;
end;

function TAsn1Value.Describe: string;
begin
  if FKind = TAsn1Kind.Unknown then
    Result := Asn1TagName(FTagClass, FTagNumber, FConstructed)
  else if FTagClass = TAsn1TagClass.Universal then
    Result := Asn1KindName(FKind)
  else
    Result := Format('%s %s', [Asn1TagName(FTagClass, FTagNumber,
      FConstructed), Asn1KindName(FKind)]);
  if FName <> '' then Result := Format('%s (%s)', [Result, FName]);
end;

function TAsn1Value.Clone: TAsn1Value;
var
  I: Integer;
begin
  Result := TAsn1Value.Create(FKind);
  Result.FTagClass := FTagClass;
  Result.FTagNumber := FTagNumber;
  Result.FConstructed := FConstructed;
  Result.FBool := FBool;
  Result.FInt := FInt;
  Result.FBytes := Copy(FBytes, 0, Length(FBytes));
  Result.FUnusedBits := FUnusedBits;
  Result.FText := FText;
  Result.FOid := FOid;
  Result.FDateTime := FDateTime;
  Result.FIndefinite := FIndefinite;
  Result.FSegmentSize := FSegmentSize;
  Result.FName := FName;
  Result.FChoiceAlternative := FChoiceAlternative;
  if FItems <> nil then
  begin
    Result.EnsureItems;
    for I := 0 to Integer(FItems.Count) - 1 do Result.FItems.Add(FItems[I].Clone);
  end;
end;

function TAsn1Value.SameAs(AOther: TAsn1Value): Boolean;
var
  I: Integer;
begin
  if AOther = nil then Exit(False);
  if (FKind <> AOther.FKind) or (FTagClass <> AOther.FTagClass) or
     (FTagNumber <> AOther.FTagNumber) or
     (FConstructed <> AOther.FConstructed) then Exit(False);
  if Count <> AOther.Count then Exit(False);
  case FKind of
    TAsn1Kind.BooleanValue:
      if FBool <> AOther.FBool then Exit(False);
    TAsn1Kind.IntegerValue, TAsn1Kind.Enumerated:
      if not FInt.Equals(AOther.FInt) then Exit(False);
    TAsn1Kind.Oid, TAsn1Kind.RelativeOid:
      if not FOid.Equals(AOther.FOid) then Exit(False);
    TAsn1Kind.UtcTime, TAsn1Kind.GeneralizedTime:
      if FText <> AOther.FText then Exit(False);
    TAsn1Kind.BitString:
      begin
        if FUnusedBits <> AOther.FUnusedBits then Exit(False);
        if not Asn1SameBytes(FBytes, AOther.FBytes) then Exit(False);
      end;
    TAsn1Kind.OctetString, TAsn1Kind.Unknown:
      if not Asn1SameBytes(FBytes, AOther.FBytes) then Exit(False);
  else
    if Asn1IsStringKind(FKind) and (FText <> AOther.FText) then Exit(False);
  end;
  for I := 0 to Count - 1 do
    if not Items[I].SameAs(AOther.Items[I]) then Exit(False);
  Result := True;
end;

{ --- TAsn1Serializer ------------------------------------------------------ }

class function TAsn1Serializer.Encode(AValue: TAsn1Value;
  ARule: TAsn1EncodingRule): TBytes;
begin
  Result := TAsn1Codec.Encode(AValue, ARule);
end;

class function TAsn1Serializer.ParseTlv(const AData: TBytes;
  ARule: TAsn1EncodingRule): TAsn1Value;
begin
  Result := TAsn1Codec.Decode(AData, ARule);
end;

class function TAsn1Serializer.DecodeWithSchema(const AData: TBytes;
  ASchema: TSerializationSchema; const ATypeName: string;
  ARule: TAsn1EncodingRule): TAsn1Value;
begin
  Result := TAsn1SchemaCodec.Decode(AData, ASchema, ATypeName, ARule);
end;

class function TAsn1Serializer.EncodeWithSchema(AValue: TAsn1Value;
  ASchema: TSerializationSchema; const ATypeName: string;
  ARule: TAsn1EncodingRule): TBytes;
begin
  Result := TAsn1SchemaCodec.Encode(AValue, ASchema, ATypeName, ARule);
end;

class function TAsn1Serializer.ToDynamic(const AData: TBytes;
  ASchema: TSerializationSchema; const ATypeName: string;
  ARule: TAsn1EncodingRule): TDynamicValue;
begin
  Result := TAsn1SchemaCodec.ToDynamic(AData, ASchema, ATypeName, ARule);
end;

class function TAsn1Serializer.FromDynamic(AValue: TDynamicValue;
  ASchema: TSerializationSchema; const ATypeName: string;
  ARule: TAsn1EncodingRule): TBytes;
begin
  Result := TAsn1SchemaCodec.FromDynamic(AValue, ASchema, ATypeName, ARule);
end;

class function TAsn1Serializer.DoSerialize(ATypeInfo: PTypeInfo;
  const AValue: TValue; ARule: TAsn1EncodingRule): TBytes;
begin
  Result := TAsn1Engine.SerializeRoot(ATypeInfo, AValue, ARule);
end;

class function TAsn1Serializer.DoDeserialize(ATypeInfo: PTypeInfo;
  const AData: TBytes; ARule: TAsn1EncodingRule): TValue;
begin
  Result := TAsn1Engine.DeserializeRoot(ATypeInfo, AData, ARule);
end;

class procedure TAsn1Serializer.DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TAsn1ValueSerializerClass);
begin
  TAsn1Engine.RegisterTypeSerializer(ATypeInfo, ASerializerClass);
end;

class procedure TAsn1Serializer.DoResetConfiguration;
begin
  TAsn1Engine.ResetConfiguration;
end;

class procedure TAsn1Serializer.FreezeConfiguration;
begin
  TAsn1Engine.FreezeConfiguration;
end;

class function TAsn1Serializer.IsFrozen: Boolean;
begin
  Result := TAsn1Engine.IsFrozen;
end;

class function TAsn1Serializer.Serialize<T>(const AValue: T;
  ARule: TAsn1EncodingRule): TBytes;
begin
  Result := DoSerialize(System.TypeInfo(T), TValue.From<T>(AValue), ARule);
end;

class function TAsn1Serializer.Deserialize<T>(const AData: TBytes;
  ARule: TAsn1EncodingRule): T;
begin
  Result := DoDeserialize(System.TypeInfo(T), AData, ARule).AsType<T>;
end;

class procedure TAsn1Serializer.RegisterTypeSerializer<T>(
  ASerializerClass: TAsn1ValueSerializerClass);
begin
  DoRegisterTypeSerializer(System.TypeInfo(T), ASerializerClass);
end;

class procedure TAsn1Serializer.ResetConfiguration;
begin
  DoResetConfiguration;
end;

{ --- custom serializers --------------------------------------------------- }

function TCustomAsn1ValueSerializer<T>.Serialize(
  const AValue: TValue): TAsn1Value;
begin
  Result := SerializeValue(AValue.AsType<T>);
end;

function TCustomAsn1ValueSerializer<T>.Deserialize(AValue: TAsn1Value;
  ATypeInfo: PTypeInfo; const AExisting: TValue): TValue;
var
  Existing: T;
begin
  if AExisting.IsEmpty then Existing := Default(T)
  else Existing := AExisting.AsType<T>;
  Result := TValue.From<T>(DeserializeValue(AValue, Existing));
end;

constructor Asn1SerializerAttribute.Create(
  ASerializerClass: TAsn1ValueSerializerClass);
begin
  inherited Create;
  FSerializerClass := ASerializerClass;
end;

{ --- attributes ----------------------------------------------------------- }

constructor Asn1TagAttribute.Create(ANumber: Integer);
begin
  inherited Create;
  FTagClass := TAsn1TagClass.ContextSpecific;
  FNumber := ANumber;
end;

constructor Asn1TagAttribute.Create(ATagClass: TAsn1TagClass;
  ANumber: Integer);
begin
  inherited Create;
  FTagClass := ATagClass;
  FNumber := ANumber;
end;

constructor Asn1ChoiceAttribute.Create(const ASelectorField: string);
begin
  inherited Create;
  FSelectorField := ASelectorField;
end;

constructor Asn1StringTypeAttribute.Create(AKind: TAsn1Kind);
begin
  inherited Create;
  FKind := AKind;
end;

end.
