# CBOR behaviour

How the CBOR engine maps Delphi values to and from CBOR, as defined by
[RFC 8949](https://www.rfc-editor.org/rfc/rfc8949). This document covers **CBOR
only** — every other format has its own rules and its own attributes; see
[`serializer-behavior.md`](serializer-behavior.md) for JSON,
[`xml-behavior.md`](xml-behavior.md), [`bson-behavior.md`](bson-behavior.md),
[`messagepack-behavior.md`](messagepack-behavior.md) and the rest.

Ownership is defined once, for every format, in
[`deserialization-ownership.md`](deserialization-ownership.md).

CBOR is a real engine. Bytes are written and read directly. Nothing routes
through JSON text, through the dynamic tree, or through any other format's
codec — which matters here because CBOR's data model is *larger* than JSON's,
and routing through JSON would quietly discard the parts that do not fit.

## The bytes

```pascal
Data    := TCborSerializer.Serialize<TShipment>(Shipment);   // TBytes
Shipment := TCborSerializer.Deserialize<TShipment>(Data);
TCborSerializer.Populate<TShipment>(Existing, Data);
```

CBOR is binary, so its natural Delphi type is `TBytes` and that is what the
API returns.

The document API, for a caller with no contract:

```pascal
Value := TCborSerializer.Decode(Data);        // the caller owns it
Data  := TCborSerializer.Encode(Value);
Text  := Value.ToDiagnostic;                  // RFC 8949 section 8
```

## The data model

`TCborValue` is CBOR's own eight major types as a small tree. It exists
because a CBOR document is perfectly capable of holding things Delphi has no
type for.

| `TCborKind` | Major type | What it is |
| --- | --- | --- |
| `UInt` | 0 | `0 .. 18446744073709551615` |
| `NegInt` | 1 | `-1 .. -18446744073709551616` |
| `Bytes` | 2 | a byte string |
| `Text` | 3 | a text string, UTF-8 on the wire |
| `Arr` | 4 | an array |
| `Map` | 5 | a map, with keys of **any** type |
| `Tag` | 6 | a tag number and the item it is about |
| `Bool` | 7 (20, 21) | `false`, `true` |
| `Null` | 7 (22) | `null` |
| `Undefined` | 7 (23) | `undefined` |
| `Simple` | 7 (0–19, 32–255) | a simple value with no assigned meaning |
| `Float` | 7 (25, 26, 27) | half, single or double precision |

**Every major type is read and written, and so is every shape each of them
can take.** A decoded value additionally remembers what it needs in order to
be written back out unchanged:

* the **width of the argument in its head**, so a document that spelled a
  three-byte string's length in four bytes writes back the same way;
* whether a string, array or map was **definite or indefinite**, and where an
  indefinite string's chunk boundaries fell;
* a float's **exact width and exact bits**, so a NaN payload survives and so
  does the difference between `1.0` written as a half and `1.0` written as a
  double.

None of that is needed to understand a value. All of it is needed to write
the document back unchanged, which is the difference between a codec and a
lossy reader.

## Integers

CBOR's integer range is wider than any single Delphi type: major type 0
reaches `2^64-1` and major type 1 reaches `-2^64`. Both ends are held exactly.

```pascal
Value.IsInteger      // major type 0 or 1
Value.FitsInt64      // whether AsInt64 is lossless
Value.AsUInt64       // major 0 up to 2^64-1
Value.NegativeArgument  // major 1: the encoded argument n, meaning -1-n
```

Asking for a value the requested Delphi type cannot hold raises
`ECborRangeError` — which is deliberately **not** an input error. The document
is fine; the request is not.

Beyond 64 bits, tags 2 and 3 carry arbitrary-precision integers as a
big-endian magnitude, and `TryAsBigIntText` renders one as exact decimal text.

## Tags

`TCborTags` names the ones this library understands, and `TCborTags.Describe`
and `TCborTags.IsKnown` answer for any number.

| Tag | Meaning | What the engine does |
| --- | --- | --- |
| 0 | RFC 3339 date-time string | read as the instant the text states |
| 1 | epoch seconds | read and written as a `TDateTime` |
| 2, 3 | positive and negative bignum | exact decimal text via `TryAsBigIntText` |
| 4 | decimal fraction | exact decimal text via `TryAsDecimalText`; an exponent outside ±6144 (`CborDecimalExponentLimit`) is refused with `ECborInputError` before any digit is built |
| 5 | bigfloat | exact decimal text — every tag-5 value has one |
| 21, 22, 23 | expected base64url / base64 / base16 | carried |
| 24 | encoded CBOR data item | carried |
| 32 | URI | `TryAsUri` |
| 33, 34 | base64url and base64 text | carried |
| 35 | regular expression | carried |
| 36 | MIME message | carried |
| 37 | UUID | `TryAsUuid`, and `NewUuid` writes one. Structurally it becomes the canonical thirty-six character text, which is what every format here writes a GUID as |
| 55799 | self-described CBOR | recognised on read; written when asked |

**A tag nobody has registered is carried exactly.** It is neither dropped nor
guessed at, and re-encoding produces the same bytes.

Tag 5 deserves a note. A bigfloat is a mantissa times a power of two, and a
negative exponent is the usual case. Every such value has an *exact* decimal
expansion, because `m·2⁻ᵏ = m·5ᵏ/10ᵏ`, so the text this library produces is
exact rather than rounded.

## Floats

Half precision is implemented by hand, in both directions, because Delphi has
no 16-bit float. A decoded float keeps its width and its raw bits, so:

* `1.0` as a half stays a half;
* a NaN with a payload keeps its payload;
* `-0.0` stays `-0.0`.

Under deterministic encoding (below) a float is written in the **shortest**
width that preserves its value exactly, which is what RFC 8949 section 4.2.2
requires.

## Indefinite lengths

Arrays, maps, byte strings and text strings may all be written with
additional information 31 and terminated by the break stop code. All four are
read and written.

```pascal
Value := TCborValue.NewIndefiniteText;
Value.AddChunk(TCborValue.NewText('Hello, '));
Value.AddChunk(TCborValue.NewText('world'));
```

The chunk boundaries are remembered, so an indefinite string re-encodes to
the same bytes rather than being silently collapsed into a definite one.

A break where no indefinite item is open raises `ECborUnexpectedBreak`. A
chunk of the wrong major type raises `ECborChunkMismatch`.

## Deterministic encoding

RFC 8949 section 4.2, in full:

```pascal
Data := TCborSerializer.Encode(Value, TCborEncodeOptions.Rfc8949Deterministic);
Ok   := TCborSerializer.IsDeterministic(Data);
```

* every argument in the shortest form that holds it;
* every float in the shortest width that is exact;
* map keys sorted by their **encoded bytes**, which is the specification's
  rule and not a lexical sort of the decoded keys;
* no indefinite lengths anywhere.

`IsDeterministic` answers by decoding and re-encoding deterministically, so it
applies the encoder's own rules rather than a second, drifting copy of them.

`TCborEncodeOptions.SelfDescribe` wraps the item in tag 55799.

## Diagnostic notation

`TCborValue.ToDiagnostic` produces RFC 8949 section 8 diagnostic notation —
the human-readable spelling the specification defines for describing CBOR in
prose and in test vectors:

```
{1: 2, 3: [4, 5]}
h'0102'
1(1363896240)
_ ["a", "b"]
```

It is a diagnostic aid, not a second encoding: there is no parser for it.

## Malformed input, refused by name

| Exception | Raised for |
| --- | --- |
| `ECborTruncatedInput` | the document ends inside an item |
| `ECborReservedAdditionalInfo` | additional information 28, 29 or 30 |
| `ECborUnexpectedBreak` | a break with no indefinite item open |
| `ECborChunkMismatch` | an indefinite string chunk of the wrong type |
| `ECborInvalidText` | a text string that is not well-formed UTF-8 |
| `ECborDepthExceeded` | nesting past `TCborDecodeOptions.MaxDepth` |
| `ECborTrailingData` | bytes after the outermost item |
| `ECborMalformedSimple` | a simple value 0–31 in the two-byte form, which section 3.3 declares not well-formed |
| `ECborInputError` | a tag 4 decimal fraction whose exponent is outside ±6144, and a container that refuses an element the document holds (a sorted `TStringList` with `dupError`), named by class |

`ECborDepthExceeded` exists because a deeply nested document is the cheapest
way to make a naive decoder recurse until the stack runs out.
`TCborDecodeOptions.MaxDepth` is the limit and
`TCborDecodeOptions.AllowTrailingData` is the one relaxation.

## The Delphi contract

| Delphi | CBOR, by default |
| --- | --- |
| `Boolean` | major 7, `true` / `false` |
| every integer width | major 0 or 1 |
| `UInt64` above `High(Int64)` | major 0, unsigned |
| `Single`, `Double`, `Extended` | major 7 float |
| `Currency` | tag 4, exponent −4, with the scaled integer Delphi actually stores |
| `string` | major 3 |
| `TBytes` | major 2 |
| `TDateTime` | tag 1, epoch seconds |
| `TDate`, `TTime` | ISO 8601 text — they are not instants |
| `TGUID` | tag 37 |
| an enumeration | its member name, as text |
| a set | an array of member names |
| a class or record | a map with text keys |
| a list or dynamic array | an array |
| a dictionary | a **map**, not an array of pairs |
| `TNullable<T>` with no value | **absent** — see below |

### An empty nullable is absent, not null

A `TNullable<T>` carrying no value is **omitted from the map**. It is not
written as `null`.

This is the same rule JSON, XML and BSON already followed, and CBOR was
brought into line with them rather than the other way round: "the member is
not there" and "the member is there and is null" are different statements,
and a library that conflates them makes a round trip lossy in a way nobody
notices until it matters.

### Attributes

CBOR reads only CBOR's own attributes. A member may carry attributes for
every format at once, and each engine ignores all but its own.

```pascal
type
  TShipment = class
  public
    [CborName('ref')] Reference: string;
    [CborIgnore] Scratch: string;
    [CborDateTimeRepresentation(TCborDateTimeRepresentation.Rfc3339Tagged)]
      Issued: TDateTime;
    [CborCurrencyRepresentation(TCborCurrencyRepresentation.DecimalString)]
      Amount: Currency;
    [CborEnumRepresentation(TCborEnumRepresentation.Value)] Status: TStatus;
    [CborGuidRepresentation(TCborGuidRepresentation.LowercaseString)] Id: TGUID;
    [CborSerializer(TMyMoneySerializer)] Odd: TMoney;
  end;
```

| Attribute | Choices |
| --- | --- |
| `CborName` | the map key to use |
| `CborIgnore` | never written, never read |
| `CborDateTimeRepresentation` | `EpochTagged`, `Rfc3339Tagged`, `UnixSeconds`, `UnixMilliseconds`, `Iso8601Text`, `CustomString` |
| `CborGuidRepresentation` | `TaggedUuid`, `LowercaseString`, `RawBytes` |
| `CborCurrencyRepresentation` | `DecimalFraction`, `ScaledInt64`, `Double`, `DecimalString` |
| `CborEnumRepresentation` | `Name`, `Value` |
| `CborSerializer` | a `TCustomCborValueSerializer<T>` descendant |

`Currency` defaults to `DecimalFraction` because a `Currency` *is* a decimal
fraction with four places and tag 4 *is* a decimal fraction. The two line up
exactly, so the default is a translation rather than a decision.

## Structural conversion

CBOR declares all four capabilities with nothing supplied: it is
self-describing, so a document can be read into the dynamic tree and written
back with no Delphi type anywhere.

```pascal
Payload := TSerialization.Convert(Source, TSerializationFormat.Json,
             TSerializationFormat.Cbor);
```

What crosses, and what does not:

* integers, floats, text, bytes, booleans, null, arrays and maps map onto the
  dynamic kinds directly; a `UInt` above `High(Int64)` becomes
  `TDynamicKind.UInt`, which exists for exactly this;
* tag 4 and tag 5 become `TDynamicKind.Decimal`, held as exact decimal text
  (a tag 4 whose exponent is outside ±6144 is refused, and a dynamic decimal
  with such an exponent is refused on the way back, with `ECborError`);
* tags 2 and 3 become `TDynamicTag.BigIntPositive` / `BigIntNegative`;
* a simple value becomes `TCborDynamicTag.SimpleValue`;
* **any other tag** becomes `TDynamicTag.CborTag`, an object of `number` and
  `value`, so a destination that cannot express it can still say so by name
  rather than dropping it;
* a map with non-text keys has no exact counterpart, because a dynamic
  object's names are text. Under `Natural` each such key becomes its CBOR
  diagnostic text (`1`, `h'0102'`) - the one lossy step of this bridge,
  stated here rather than discovered. `Strict` refuses because the key's
  type would change, and `Lossless` refuses because diagnostic text is never
  lossless; both raise `EStructuralConversionError` naming the key (`$[1]`).
  The contract path, which knows the Delphi key type, reads such keys
  exactly.

## What is proven, and how

`tests/CborNative` runs **191 checks** against RFC 8949 itself.

The independent reference is **RFC 8949 Appendix A**: all 81 of its example
vectors are decoded and then re-encoded, and each re-encoding is compared
byte for byte with the hex in the table. That is the whole appendix, not a
selection.

The ledger the test prints covers every major type, arguments 0–23 and the
24/25/26/27 forms, additional information 31, the reserved 28–30, the break
stop code, all three float widths, simple values 0–255, tags 0, 1, 2, 3, 4, 5,
32, 37 and 55799, unregistered tags, section 4.2 deterministic encoding and
section 5.6 well-formedness.

## Not implemented, and why

* **CBOR sequences (RFC 8742)** — a stream of items rather than one document.
  `TCborDecodeOptions.AllowTrailingData` is the hook a sequence reader would
  need, but a sequence reader is a separate API rather than a decode flag,
  and it is not here.
* **COSE, CDDL and CBOR patching** are separate specifications. This is
  RFC 8949.
* **No diagnostic-notation parser.** `ToDiagnostic` writes; nothing reads it
  back.
