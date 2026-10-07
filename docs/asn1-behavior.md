# ASN.1 behaviour

How the ASN.1 engine maps Delphi values to and from BER, DER and CER, as
defined by [ITU-T X.690](https://www.itu.int/rec/T-REC-X.690), with the schema
model drawn from X.680. This document covers **ASN.1 only**; see the other
behaviour documents for the rest.

Ownership is defined once, for every format, in
[`deserialization-ownership.md`](deserialization-ownership.md).

## Three encodings, not one with three names

BER, DER and CER are registered as **three formats**:

| Format | What it is |
| --- | --- |
| `Asn1Ber` | Basic Encoding Rules. Several encodings of one value are legal. What a sender may emit. |
| `Asn1Der` | Distinguished Encoding Rules. Exactly **one** encoding of any value. What a signature is computed over, and what a verifier must be handed. |
| `Asn1Cer` | Canonical Encoding Rules. Also canonical, and **not the same as DER**: indefinite lengths everywhere, and strings segmented at 1000 octets. |

A single enum value called `Asn1` would make the difference invisible at the
one place a caller decides it — which is how a library ends up producing BER,
calling it DER, and failing a signature check in somebody else's verifier
months later.

The three share one handler class with the rule as a field; the three
registrations differ only in that field. (This is why
`TSerializationFormatHandler.Create` is virtual: the registry constructs a
handler from its class, and without a virtual constructor all three would
silently have been BER.)

```pascal
Der := TAsn1Serializer.Serialize<TCertificate>(Cert);                 // DER by default
Ber := TAsn1Serializer.Serialize<TCertificate>(Cert, TAsn1EncodingRule.Ber);

Payload := TSerialization.Serialize<TCertificate>(Cert,
             TSerializationFormat.Asn1Der);
```

Every entry point takes `ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der`.
DER is the default because it is the one whose output is defined.

## Tag, length, value

### Identifier octets

All four tag classes — `Universal`, `Application`, `ContextSpecific`,
`Private` — and both tag forms. A tag number of 31 or more is written in the
**high tag number form**: `11111` in the low five bits, then base-128
continuation octets. Read and written.

### Length octets

* **Short form**, one octet, for lengths 0–127.
* **Long form**, a count octet then that many length octets.
* **Indefinite form** (`0x80`), terminated by end-of-contents `00 00`.

Which are legal depends on the rule:

| | BER | DER | CER |
| --- | --- | --- | --- |
| definite length | yes | **required** | only for primitives |
| indefinite length | yes | refused | **required** for every constructed value; a definite one is refused |
| shortest length form | not required | **required** | required |

`ber: 30060201010101ff` and `der: 30060201010101ff` are the same bytes for a
simple SEQUENCE; `cer: 30800201010101ff0000` is not, and that is the point.

### Primitive and constructed strings

BER allows an OCTET STRING, a BIT STRING or a character string to be
**constructed**: a series of segments that a reader concatenates. This engine
reassembles them. UTCTime and GeneralizedTime are VisibleStrings underneath,
so they are reassembled the same way.

The other universal types - BOOLEAN, INTEGER, ENUMERATED, REAL, NULL, OBJECT
IDENTIFIER and RELATIVE-OID - are primitive under every rule, BER included.
A constructed one is not ASN.1 and raises `EAsn1InputError`; it is never read
as a SEQUENCE of its pieces.

DER forbids it. CER *requires* it for any string longer than 1000 content
octets and forbids it for any shorter, and requires that every segment except
the last be exactly 1000 content octets (X.690 9.2). The fragments are
primitive OCTET STRINGs - a character string is an IMPLICIT OCTET STRING
underneath, so its fragments never carry its own tag - and a BIT STRING's
are BIT STRINGs: one unused-bit octet and 999 octets of bits each, with
unused bits only in the last. This engine writes exactly that under CER and
refuses anything else with `EAsn1CanonicalError`.

CER also writes **every** constructed value - a SEQUENCE, a SET, an explicit
tag, a segmented string - with an indefinite length (X.690 9.1), and a CER
read refuses a definite-length one with `EAsn1CanonicalError`. BER reads
both forms; DER requires the definite one.

## The type ledger

| ASN.1 | Notes |
| --- | --- |
| `BOOLEAN` | DER requires `FF` for true; BER accepts any non-zero |
| `INTEGER` | **any size** — `TAsn1BigInt`, two's complement, no width limit |
| `BIT STRING` | with its **unused-bit count**, which is part of the value |
| `OCTET STRING` | primitive and constructed |
| `NULL` | zero content octets, and a non-empty one is refused |
| `OBJECT IDENTIFIER` | arcs as arbitrary-precision integers |
| `RELATIVE-OID` | the same arc encoding without the first-pair rule |
| `ENUMERATED` | |
| `UTF8String`, `NumericString`, `PrintableString`, `IA5String`, `VisibleString`, `BMPString`, `UniversalString`, `TeletexString`, `GeneralString` | each a distinct kind, never silently substituted; an unpaired UTF-16 surrogate is refused on write (`ESerializationUnsupported` for the UTF-8 kinds, `EAsn1Error` for `BMPString` and `UniversalString`) |
| `REAL` | binary, base 2, exact in both directions, with X.690's special values for zero, minus zero, the infinities and NaN; the decimal forms are read correctly rounded |
| `UTCTime`, `GeneralizedTime` | |
| `SEQUENCE`, `SEQUENCE OF` | order is the value |
| `SET`, `SET OF` | DER sorts a SET OF by encoded value |
| `CHOICE` | a real CHOICE — see below |

### OBJECT IDENTIFIER arcs are big integers

An OID arc is not bounded by 64 bits, and real OIDs exceed it. `TAsn1Oid`
holds arcs as `TAsn1BigInt`, and the encoder does base-128 arithmetic on the
magnitude rather than casting to `UInt64`.

The first subidentifier is `40 * arc0 + arc1`, with `arc0` in 0, 1 or 2. X.690
clause 8.19's worked example is the OID `2.100.3`, which encodes as
`06 03 81 34 03`; the test checks exactly those bytes.

### BIT STRING keeps its unused-bit count

A BIT STRING is a number of **bits**, not a number of bytes. The first content
octet says how many bits of the last byte are padding. Dropping it would make
`0x0A` with 4 unused bits indistinguishable from `0x0A` with 0, which are
different values.

### CHOICE is a real CHOICE

A CHOICE is **one** alternative, and the encoding says which. It is not a
record of nullable fields — those would all be encoded, and a CHOICE encodes
one.

```pascal
type
  TNameForm = (ByRfc822, ByDns, ByIp);

  TGeneralName = record
    Which: TNameForm;      { the selector }
    Rfc822: string;
    Dns: string;
    Ip: TBytes;
  end;

  THolder = record
    [Asn1Choice('Which')] Name: TGeneralName;
  end;
```

`[Asn1Choice]` names the member that says which alternative is present. On
write, only that alternative is encoded, under the context tag its position
gives it. On read, the selector is set from the tag that arrived.

## Malformed octets, refused by name

`EAsn1InputError` for truncation, a length the remaining octets cannot
satisfy, an end-of-contents with no indefinite length open, a `NULL` with
content, and a tag whose form contradicts its type. `EAsn1SchemaError` for a
module that does not say what these octets are. Every message names the
offending construct rather than reporting "bad ASN.1".

DER and CER additionally refuse what their own rules forbid — a non-minimal
length, an indefinite length under DER, a `BOOLEAN` true that is not `FF`.

## The X.680 schema

ASN.1 octets are **anonymous**. A SEQUENCE is its components with nothing
between them, there are no names anywhere, and a `SEQUENCE` and a
`SEQUENCE OF` share one tag. So a structural tree — which needs names — needs
the module.

```pascal
Schema := TAsn1Schema.ParseModule(ModuleText);   // a declared subset of X.680
try
  Tree := TAsn1Serializer.ToDynamic(Data, Schema, 'Person',
            TAsn1EncodingRule.Der);
finally
  Schema.Free;
end;
```

`TAsn1Schema` is a `TSerializationContext`, so it travels in conversion
options.

### A module may declare as many types as it likes

ASN.1 octets are anonymous and a real module usually declares several
assignments, so a conversion has to be told **which one** these octets are.
The conversion options have nowhere to put a type *name* — it would mean
nothing to the other nine format families, and a generic
`TStructuralConversionOptions.TypeName` would be a field most formats ignore
and one format depends on. So the name travels with the schema it belongs
to, in an ASN.1 context:

```pascal
Schema := TAsn1Schema.ParseModule(ModuleText);   // Header, Customer, Shipment…
try
  Context := Schema.ForType('Shipment');          // or TAsn1SerializationContext.Create
  try
    Json := TSerialization.Convert(Der, TSerializationFormat.Asn1Der,
              TSerializationFormat.Json,
              TStructuralConversionProfile.Natural, Context);
  finally
    Context.Free;
  end;
finally
  Schema.Free;
end;
```

`ForType` raises if the module declares no such assignment, so a typo is
found where it was made rather than as a mystery in the middle of a
conversion. A context also carries the encoding rule, because the same
`Shipment` in the same module is different octets under BER and under DER.

**A one-type module still needs no name.** Handed a bare `TAsn1Schema`, the
handler uses the schema's `RootType` when it has one, and its sole assignment
when it has exactly one — so the simple case stays simple. What it will not
do is pick one of several: that raises, naming the assignments it found.

`TAsn1Serializer.ToDynamic` and `FromDynamic` take the type name directly and
always have. `tests\Asn1Native` asserts the registry route on a four-type
module — `ASN1_MULTI_TYPE_MODULE` and `ASN1_ROOT_TYPE_SELECTION`.

## The Delphi contract

A record or class is a `SEQUENCE` and its members are the components **in
declaration order**, because ASN.1 puts nothing between them.

| Delphi | ASN.1, by default |
| --- | --- |
| `Boolean` | `BOOLEAN` |
| every integer width | `INTEGER` |
| `Currency` | `INTEGER`, the scaled value Delphi stores |
| `string` | `UTF8String`, unless `[Asn1StringType]` says otherwise |
| `TBytes` | `OCTET STRING` |
| `TDateTime` | `GeneralizedTime` - the years 1 to 9999; one outside them is refused on write with `EAsn1Error`, naming the member |
| `TGUID` | `OCTET STRING` |
| an enumeration | `ENUMERATED` |
| a set | `SET OF ENUMERATED` - X.680's way of saying "some of these" |
| a class or record | `SEQUENCE` |
| a list or dynamic array | `SEQUENCE OF` |
| a dictionary | `SEQUENCE OF` two-component `SEQUENCE`s - X.680 has no map |
| `TNullable<T>` with no value | **absent** with `[Asn1Optional]` - which is what `OPTIONAL` means; `NULL` without it |
| `Single`, `Double`, `Extended` | `REAL`, binary |

A record member, a `TNullable<record>` payload and a CHOICE record are merged
in place on read: objects already in the record are filled, and an
`OPTIONAL` component the document leaves out keeps the member's value.

### Attributes

```pascal
type
  TTagged = record
    [Asn1Tag(0)] Primary: string;
    [Asn1Tag(1)] [Asn1Optional] Secondary: TNullable<string>;
    [Asn1Tag(2)] [Asn1Implicit] Count: Integer;
    [Asn1StringType(TAsn1Kind.PrintableString)] Code: string;
    [Asn1StringType(TAsn1Kind.Ia5String)] Email: string;
    [Asn1Ignore] Scratch: string;
  end;
```

| Attribute | Meaning |
| --- | --- |
| `Asn1Tag(n)` | the context-specific tag number for this component |
| `Asn1Optional` | `OPTIONAL` — absent rather than null when it has no value |
| `Asn1Implicit` | implicit tagging: the tag replaces the type's own |
| `Asn1Explicit` | explicit tagging: the tag wraps the type's own |
| `Asn1Choice('Selector')` | this member is a CHOICE; the named member says which alternative |
| `Asn1StringType(kind)` | which of the nine character string types to use |
| `Asn1Serializer(cls)` | a `TCustomAsn1ValueSerializer<T>` descendant for this member |
| `Asn1Ignore` | never written, never read |

### When ASN.1 has no type for yours

A type this unit has no mapping for is refused by name, and the refusal says
what to do instead: register a type serializer that says what the value
means. A `REAL` carries a `Double` exactly, but a peer's module may want a
coordinate as an `INTEGER` of ten-millionths:

```pascal
type
  TAsn1Coordinate = class(TCustomAsn1ValueSerializer<TCoordinate>)
  public
    function SerializeValue(const AValue: TCoordinate): TAsn1Value; override;
    function DeserializeValue(AValue: TAsn1Value;
      const AExisting: TCoordinate): TCoordinate; override;
  end;

TAsn1Serializer.RegisterTypeSerializer<TCoordinate>(TAsn1Coordinate);
```

The caller knows what the two doubles mean — a coordinate to seven decimal
places is a centimetre — and an `INTEGER` of ten-millionths carries it
exactly. The library will not choose that scale on anybody's behalf, and a
member-level `[Asn1Serializer]` overrides the registration.

## Structural conversion

The three ASN.1 formats declare `ContractSerialize` and `ContractDeserialize`
always, and the two **structural** capabilities only when an ASN.1 context is
present in the conversion options — in the **role** that end needs it for: a
source context to read, a destination context to write. Converting one ASN.1
module into another is therefore ordinary rather than ambiguous.

```pascal
Payload := TSerialization.Convert(Source, TSerializationFormat.Asn1Der,
             TSerializationFormat.Json,
             TStructuralConversionProfile.Natural, Schema);
```

Without one, `ESerializationSchemaRequired` is raised — not the capability
error, because ASN.1 *can* do this and would, given the module.

An `INTEGER` too large for `Int64` crosses as an exact `TDynamicKind.Decimal`
with all its digits, and a decimal is read back into an `INTEGER`, so it is
carried exactly rather than rounded.

A member the selected `SEQUENCE` or `SET` does not declare is omitted under
`Natural` - the module is the destination's whole vocabulary - and refused
under `Strict` and `Lossless` with `EStructuralConversionError` naming its
path, in BER, DER and CER alike. Nothing proprietary is written to carry it.

## What is proven, and how

`tests/Asn1Native` runs **185 checks** against X.690 itself, quoting its
clause numbers.

The independent reference is the Recommendation's own worked examples — the
OID `2.100.3` as `06 03 81 34 03` from clause 8.19, the BOOLEAN and INTEGER
forms from clauses 8.2 and 8.3, and the DER restrictions from clause 11.

The ledger covers all four tag classes, high tag numbers, all three length
forms, every type above, constructed strings under BER, the DER canonical
restrictions, CER's indefinite lengths and 1000-octet segmentation, CHOICE,
X.680 module parsing, and schema-driven structural conversion.

## Not implemented, and why

* **PER, OER, XER and JER.** They are separate encodings in separate
  Recommendations. This is X.690.
* **The X.681/682/683 information object layer**, parameterized types,
  `ANY DEFINED BY` and constraint algebra. The module parser **names** each one
  it meets rather than skipping it silently.
