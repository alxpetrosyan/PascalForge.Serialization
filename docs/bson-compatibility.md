# BSON: the profile, the ledger, and the evidence

[`bson-behavior.md`](bson-behavior.md) says what the library *writes* for a
Delphi type. This page answers the harder question: **is this a BSON codec**,
and against what exactly.

---

## The declared target

```text
BSON specification, version 1.1          https://bsonspec.org/spec.html
```

No profile, no exclusions, no "the useful subset". **Every element type the
specification defines is read and written**, including the three it marks
deprecated — Undefined, DBPointer and Symbol — because a reader that refuses
a deprecated type cannot read a document somebody wrote in 2009, and that
document still exists.

---

## Why a codec of its own

There is no BSON support in the Delphi RTL and none in this installation.
The inventory was: nothing to reuse. The codec is written here, in
`PascalForge.Bson.Internal`, over `System.SysUtils` and
`System.Generics.Collections` and nothing else.

---

## The element-type ledger

Decode = read. Encode = written back byte for byte. Vector = there is a byte
vector for it in `tests\BsonNative`, decoded and then re-encoded and compared
to the original bytes. Malformed = there is a negative fixture.

| Type | Byte | Carried as | Decode | Encode | Vector | Malformed |
| --- | --- | --- | --- | --- | --- | --- |
| double | `0x01` | `Double` | yes | yes | yes | — |
| string | `0x02` | `string`, UTF-8 on the wire | yes | yes | yes | yes |
| embedded document | `0x03` | `TBsonValue` document | yes | yes | yes | yes |
| array | `0x04` | `TBsonValue` array | yes | yes | yes | — |
| binary, subtype `0x00` | `0x05` | `TBytes` | yes | yes | yes | yes |
| binary, subtype `0x04` (UUID) | `0x05` | `TBytes` / `TGUID` | yes | yes | yes | — |
| binary, any other subtype | `0x05` | `TBytes` + the subtype byte | yes | yes | yes | — |
| undefined *(deprecated)* | `0x06` | `TBsonKind.Undefined` | yes | yes | yes | — |
| ObjectId | `0x07` | **`TBsonObjectId`** | yes | yes | yes | yes |
| boolean | `0x08` | `Boolean` | yes | yes | yes | — |
| UTC datetime | `0x09` | `TDateTime` | yes | yes | yes | — |
| null | `0x0A` | `TBsonKind.Null` | yes | yes | yes | — |
| regular expression | `0x0B` | pattern + options | yes | yes | yes | — |
| DBPointer *(deprecated)* | `0x0C` | namespace + `TBsonObjectId` | yes | yes | yes | — |
| JavaScript code | `0x0D` | `string` | yes | yes | yes | — |
| symbol *(deprecated)* | `0x0E` | `string` | yes | yes | yes | — |
| JavaScript with scope | `0x0F` | code + a scope document | yes | yes | yes | yes |
| int32 | `0x10` | `Integer` | yes | yes | yes | — |
| timestamp | `0x11` | `UInt64`, **not** a datetime | yes | yes | yes | — |
| int64 | `0x12` | `Int64` | yes | yes | yes | — |
| decimal128 | `0x13` | 16 bytes, exactly | yes | yes | yes | — |
| min key | `0xFF` | `TBsonKind.MinKey` | yes | yes | yes | — |
| max key | `0x7F` | `TBsonKind.MaxKey` | yes | yes | yes | — |
| *any other byte* | — | **refused, by name** | — | — | — | yes |

**The unsupported-feature list is empty.** A type byte outside this table is
not a BSON element, and it raises `EBsonUnsupportedType` naming the byte
rather than being skipped.

Two entries deserve their own sentence.

**A BSON timestamp is not a datetime.** It is a MongoDB-internal value: a
seconds count in the high 32 bits and a per-second increment in the low 32.
Converting one into a `TDateTime` would produce a plausible-looking date that
means something else, so it is carried as the raw `UInt64` it is.

**A decimal128 is carried, not interpreted.** Delphi has no 128-bit decimal,
so no arithmetic is offered and none is attempted. The sixteen bytes round
trip exactly, which is the whole promise and is stated as the whole promise.

---

## Numeric fidelity

| | |
| --- | --- |
| int32 stays int32 | nothing widens on the way out |
| int64 stays int64 | including `9223372036854775807`, which a `Double` cannot hold |
| double stays double | and is not re-parsed through text |
| `Currency` | written as the scaled `Int64` Delphi actually stores, so it is exact; a double or a decimal string are available per member |

`VALUE_INT64_MAX` in `tests\BsonNative` is the check that matters here: a
codec that routed integers through `Double` loses the bottom bits of that
number, and the test would notice.

---

## Resource and security audit

| Hazard | Answer |
| --- | --- |
| Declared length larger than the buffer | Refused before anything is read; the message names the byte offset. |
| Declared length smaller than an empty document | Refused. |
| Negative length | Refused. |
| Allocation bomb - a length field claiming 2 GB | Refused on the buffer bound, before any allocation. |
| String length of zero | Refused: the length includes the terminator, so it can never be zero. |
| String or binary running past the document | Every read is bounds-checked against both the declared length and the buffer. |
| Unterminated element name | Refused. |
| Missing document terminator | Refused. |
| Elements overrunning the document | Refused. |
| Bytes after the root document | Refused. |
| `code_w_s` declaring a length that does not match its contents | Checked rather than trusted, and refused. |
| Undefined element type byte | Refused, naming the byte. |
| A zero byte inside an element name on write | Refused: a C string cannot carry one. |

There is no external-reference construct in BSON, so there is no XXE
equivalent to defend against. Nothing in the codec opens a file or a socket.

---

## Independent interoperability

**Stated plainly: there is no second BSON implementation available offline on
this machine** — no MongoDB driver, no Python `bson`. So the independent
reference is the **specification's own published byte vectors**, quoted
exactly in `tests\BsonNative`:

```text
{"hello": "world"}                 16 00 00 00 02 68 65 6C 6C 6F 00 ...
{"BSON": ["awesome", 5.05, 1986]}  31 00 00 00 04 42 53 4F 4E 00 ...
```

plus one vector per element type, built from the specification's element
table. Each is decoded to its expected values and then **re-encoded and
compared to the original bytes**. BSON is deterministic for a given element
order, so that comparison is an equality and not an approximation.

```text
INDEPENDENT_INTEROP_DECODE: PASS     the specification's bytes -> our values
INDEPENDENT_INTEROP_ENCODE: PASS     our bytes = the specification's bytes
```

This is weaker than running a second implementation, and it is worth being
clear about which weakness it is: it proves the bytes match the document, not
that some other program agrees with our reading of the document. What it
rules out is the failure mode that matters most — a codec that is merely
self-consistent, where the writer and reader share the same misunderstanding.

`CANONICAL_OR_DETERMINISTIC_MODE: PASS` — BSON has no canonical form beyond
element order, and element order is preserved exactly, so the encoding is
deterministic. `ROUNDTRIP_BYTES_ARE_STABLE` asserts it.

---

## BSON and JSON, three ways

BSON has twenty-two element types and JSON has six. There is no single right
answer to that, so there are three — and **none of them is a convention of
this library's own**. Each is either idiomatic JSON, or a separate document,
or somebody else's published standard.

```pascal
Json := TBsonSerializer.ToJson(Data);                        // 1
Json := TBsonSerializer.ToJsonWithSchema(Data, Schema);      // 2
Json := TBsonSerializer.ToExtendedJson(Data);                // 3

Data := TBsonSerializer.FromJson(Json);                      // 1
Data := TBsonSerializer.FromJson(Json, Schema);              // 2
Data := TBsonSerializer.FromExtendedJson(Json);              // 3
```

### 1. Plain

Idiomatic JSON. An ObjectId is its hex string, a UTC datetime an ISO-8601
string, a binary base64, a decimal128 its digits, a timestamp its unsigned
64-bit value as text.

```json
{"_id": "507f1f77bcf86cd799439011", "Money": "123.45"}
```

Anything reads it, nothing has to be taught anything, and the type
information is gone. `FromJson` without a schema cannot get it back, and says
so rather than guessing.

### 2. Plain, plus a separate schema

The same plain JSON, and **separately** a small JSON object mapping each
value's path to its BSON type name:

```json
{
  "version": 1,
  "types": {
    "$": "object",
    "$._id": "objectId",
    "$.Count": "int",
    "$.Big": "long",
    "$.CreatedAt": "date",
    "$.Blob": "binData",
    "$.Uuid": "binData:04",
    "$.Money": "decimal"
  }
}
```

The names are MongoDB's own `$type` aliases, so every one of them can be
looked up. `binData:NN` is the one spelling not lifted straight from the
standard: it carries the subtype byte, which the standard's alias has no room
for.

The **data document is untouched** — a consumer that does not care about
types reads it and never knows the schema exists — and
`FromJson(Json, Schema)` puts the two back together exactly. This is the
mode for a pipeline that wants clean JSON on the wire and exact types at the
other end.

### 3. MongoDB Extended JSON

The canonical form defined by the MongoDB Extended JSON specification. One
document, exactly reversible, and readable by `mongosh` and by every MongoDB
driver — because the representation is theirs:

| BSON | Extended JSON |
| --- | --- |
| ObjectId | `{"$oid": "507f1f77bcf86cd799439011"}` |
| UTC datetime | `{"$date": {"$numberLong": "1773480413120"}}` |
| binary | `{"$binary": {"base64": "AQID", "subType": "00"}}` |
| binary subtype 4 (UUID), read also as | `{"$uuid": "73ffd264-44b3-4c69-90e8-e7d1dfc035d4"}` - the specification's relaxed input form, in RFC 4122 byte order; written back as `$binary`, and a malformed one is an `EJsonInputError` |
| decimal128 | `{"$numberDecimal": "123.45"}` |
| timestamp | `{"$timestamp": {"t": 1770000000, "i": 7}}` |
| regular expression | `{"$regularExpression": {"pattern": "^a", "options": "i"}}` |
| JavaScript | `{"$code": "return 1;"}` |
| JavaScript with scope | `{"$code": "…", "$scope": { … }}` |
| symbol | `{"$symbol": "legacy"}` |
| undefined | `{"$undefined": true}` |
| DBPointer | `{"$dbPointer": {"$ref": "db.coll", "$id": {"$oid": "…"}}}` |
| min key / max key | `{"$minKey": 1}` / `{"$maxKey": 1}` |

A decimal128 is written in **digits**, which means the sixteen bytes have to
become digits: `TDecimal128` in the core does that conversion, in both
directions, using the decimal-arithmetic specification's
*to-scientific-string* rules. `tests\BsonJson` checks it against values whose
answers are not in doubt, including the infinities and NaN.

`TStructuralConversionProfile.Lossless` through the general facade is the
same thing: `TSerialization.Convert(Data, Bson, Json, Lossless)` writes
Extended JSON, and reading it back writes the native elements again.

### What plain JSON proves, going the other way

`FromJson` with no schema infers only what JSON itself **states**:

| JSON | BSON |
| --- | --- |
| a whole number that fits in 32 bits | int32 |
| a whole number that does not | int64 |
| a number with a fraction or an exponent | double |
| `true` / `false` | boolean |
| `null` | null |
| a string | string |
| an array | array |
| an object | document |

A twenty-four character hex string is **not** an ObjectId. An
ISO-8601-looking string is **not** a date. Base64-looking text is **not**
binary. A GUID-looking string is **not** a UUID binary. JSON did not say so,
and the difference between "could have been" and "was" is the difference
between a converter and a guess. Callers who *do* know say so — with the
schema, or with Extended JSON.

Extended JSON is not recognized by `FromJson` either. Asking for
`FromExtendedJson` is how a caller states that the document is in that
format; through the general facade the equivalent statement is
`Lossless` **and** a BSON destination.

`tests\BsonJson` asserts every row of this section.

### Inside the process

Between parsing and writing, an exotic element lives in the dynamic
structural tree as an `Extended` node — a tag naming the BSON type and a
payload carrying its parts. That is an in-memory distinction and it appears
in no document: what a destination writes for one is that destination's
decision, made under the profile the caller asked for.

What the tree does **not** carry is the int32/int64 distinction: both are
`TDynamicKind.Int`, and a 32-bit value that goes out through the tree and
comes back is an int32 again only because it still fits in 32 bits. The three
APIs above are exact regardless, because none of them loses the width:
`ToJsonWithSchema` records it and `ToExtendedJson` writes it.

---


## Delphi types

An ObjectId is a first-class Delphi type, because `_id` is the single most
common BSON member there is:

```pascal
type
  TOrder = class
  public
    [BsonName('_id')]
    Id: TBsonObjectId;
  end;
```

`TBsonObjectId.FromHex`, `ToHex`, `FromBytes`, `ToBytes`, `Equals`,
`IsEmpty`, `Empty`. No generator is offered: an ObjectId is an identifier a
database assigns, and inventing one here would be inventing a value that has
to be unique across machines.

The other exotic element types have no Delphi counterpart to map to. They are
reachable through `TBsonValue` — directly, or from a member through a typed
custom serializer:

```pascal
type
  TDecimalSerializer = class(TCustomBsonValueSerializer<TMyDecimal>)
    function SerializeValue(const AValue: TMyDecimal): TBsonValue; override;
    ...
```

---

## The gate

```text
FORMAT: BSON
STANDARD_TARGET: BSON specification version 1.1
PROFILE: complete - every defined element type, no exclusions

FEATURE_LEDGER_COMPLETE: PASS
NATIVE_SYNTAX_COMPATIBILITY: PASS
NATIVE_TYPE_COMPATIBILITY: PASS
MALFORMED_INPUT_VALIDATION: PASS

INDEPENDENT_INTEROP_DECODE: PASS      (specification byte vectors)
INDEPENDENT_INTEROP_ENCODE: PASS      (byte-for-byte equality)
CANONICAL_OR_DETERMINISTIC_MODE: PASS

DIRECT_SERIALIZE_DESERIALIZE: PASS
DELPHI_OBJECT_ROUNDTRIP: PASS
OWNERSHIP_CONTRACT: PASS
PLAN_CACHE_WARM_PATH: PASS
CUSTOMIZATION_API: PASS
DATE_TIME_POLICY: PASS

REGISTRATION_ISOLATED: PASS
UNREGISTERED_RUNTIME_ERROR: PASS
FORMAT_SOURCE_ISOLATION: PASS

STRUCTURAL_CONVERSION_MATRIX: PASS
CONTRACT_CONVERSION_MATRIX: PASS
ALL_PREVIOUS_PAIRINGS_RERUN: PASS

DATASET_CONTRACT_PROJECTION: PASS
DATASET_CLIENTDATASET_CONTRACT: PASS
DATASET_STRUCTURAL_INFERENCE: PASS
DATASET_NATIVE_TYPE_FIDELITY: PASS

PREVIOUS_FORMAT_REGRESSION: PASS
JSON_REGRESSION: PASS
DATASET_REGRESSION: PASS

WIN32: PASS
WIN64: PASS
DOCS: PASS
DEMOS: PASS
BANNED_MARKERS: PASS
```

**Compatibility claim.** PascalForge reads and writes **every element type
defined by the BSON specification, version 1.1**. The unsupported-feature
list is empty.

The one qualification, stated rather than buried: the independent reference
is the specification's published byte vectors, not a second running
implementation, because none was available offline. See the interoperability
section above for exactly what that does and does not prove.

SDK units reused: none. There is no BSON support in the Delphi RTL.
