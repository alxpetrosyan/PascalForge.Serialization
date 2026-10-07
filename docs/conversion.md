# Converting between formats

Two modes, which look similar and are not.

## Contract-aware — prefer this

```pascal
Xml := TSerialization.Convert<TShipment>(Json,
  TSerializationFormat.Json, TSerializationFormat.Xml);

// or, when the destination is known at compile time:
Xml := TXmlSerializer.From<TShipment>(Json, TSerializationFormat.Json);
```

The **Delphi type is the contract**. The source deserializes into `T` by its
own rules and the destination writes `T` by its own, so each side's attributes
apply:

```pascal
[JsonName('orderId')] [XmlName('OrderID')] [XmlAttribute] [BsonName('_id')]
Id: Int64;
```

goes out as `"orderId": …` in JSON, as an `OrderID` attribute in XML, and as
an `_id` int64 in BSON — from the same conversion, in the same program.
Nothing is lost that the Delphi type can hold.

The intermediate `T` never escapes: it is built, written out and released
inside the call, on the way out and on the way out through an exception alike.
Nothing is returned for the caller to free. `tests\FormatBoundary` runs a
thousand conversions and asserts the live instance count is still zero.

## Structural — for a document whose contract you do not have

```pascal
Xml := TSerialization.Convert(Json,
  TSerializationFormat.Json, TSerializationFormat.Xml);
```

No Delphi type is involved, so no attribute applies and nothing is renamed.
The document travels through the **dynamic model** (`TDynamicValue`, see
[`dynamic.md`](dynamic.md)) - the same value a caller gets from a format's
`ToDynamic` and gives to its `FromDynamic`, so a structural conversion is
exactly those two halves with nothing in between. Its kinds:

```
null   boolean   integer   float   string   binary   datetime   array   object
```

plus unsigned 64-bit integers, exact decimals, date and time as kinds of
their own, and Extended values for what one format has natively (a BSON
ObjectId, a CBOR tag). It is not a DOM of any one format, and a contract
path never routes through it - JSON, XML and BSON each serialize a Delphi
value directly along their own path.

### What each format contributes

A format contributes what it actually **states**, and nothing more.

| | JSON | XML | BSON |
| --- | --- | --- | --- |
| integer apart from float | yes | no | yes |
| boolean | yes | no | yes |
| binary | no | no | yes |
| datetime | no | no | yes |

XML element text carries no type at all, so everything out of XML is a string.
A JSON number is a number. A BSON int64 is an integer, a BSON datetime is a
datetime, and BSON binary is binary.

**No format's strings are inspected to guess a type.** A JSON member spelled
`"2026-09-14"` stays a string. Guessing from the spelling is how the same
document becomes a timestamp in one system and text in the next, and the
difference only shows up later, in somebody else's data.

The consequence is visible and documented:

```
{"id":7}  --JSON-->  <Value><id>7</id></Value>  --XML-->  {"id":"7"}
{"id":7}  --JSON-->  BSON int32                 --BSON->  {"id":7}
```

Round-tripping through XML loses the number; through BSON it does not. Use
contract-aware conversion when that matters.

### CSV: one table, or several

CSV is tabular, so a tree has to be **projected** onto rows, and how is
CSV's question: `TCsvOptions` (`NestedObjectMode`, `CollectionMode`,
`Delimiter`, `HasHeader`, `NullPolicy`...). Those options never enter
`TStructuralConversionOptions`. They travel in a `TCsvSchema`, the one
field of the conversion options that belongs to a format:

```pascal
Schema := TCsvSchema.Create(TCsvOptions.Default
  .WithCollectionMode(TCsvCollectionMode.NumberedColumns));
try
  Csv := TSerialization.Convert(Json, TSerializationFormat.Json,
    TSerializationFormat.Csv,
    TStructuralConversionOptions.Default.WithContext(Schema));
finally
  Schema.Free;
end;
```

Without a schema the conservative defaults apply: a nested object is
flattened and a collection is refused.

**Single-document projection options** - `JsonCell`, `RepeatedRows`,
`NumberedColumns`, the dialect, the null policy - are supported through
structural conversion this way. **`SeparateTable`** is not a payload: it
produces several CSV documents and a `TSerializationPayload` holds one, so
`TSerialization.Convert` refuses it with `ESerializationFormatCapability`
and names the API that returns them:

```pascal
Tables := TCsvSerializer.TablesFrom(Json, TSerializationFormat.Json,
  TCsvOptions.Default.WithCollectionMode(TCsvCollectionMode.SeparateTable));
```

`TablesFrom` reads the document with the source format's registered handler
and returns a `TCsvDocumentSet` - the same tables `SerializeTables<T>`
produces from a Delphi value, through the same table rules. See
[`formats/csv.md`](formats/csv.md).

## The two things that can go wrong, and the three profiles

Structural conversion meets two *different* problems, and they are kept apart
because the right answer to each is a different answer.

**A member name the destination cannot spell.** `$type` is an ordinary JSON
member name and is not a legal XML element name. Nothing is *lost* by
encoding it, so the default is to encode it, in a convention the
destination's own world already uses.

**A value kind the destination does not have.** BSON binary and BSON
timestamps have no JSON or XML equivalent. Something *is* lost here, so the
caller decides.

```pascal
Xml := TSerialization.Convert(Json,
  TSerializationFormat.Json, TSerializationFormat.Xml,
  TStructuralConversionProfile.Lossless);
```

| profile | names | values |
| --- | --- | --- |
| `Natural` *(default)* | encoded the way the destination's own tooling does | the destination's idiom: base64 for binary, ISO-8601 for a timestamp, hex for an ObjectId |
| `Lossless` | whatever the standard says, which is usually nothing to encode | the **published standard** for that pair of formats |
| `Strict` | **refused**, with the path | **refused**, with the path |

The two are separate knobs underneath, and a caller who wants adapted names
but a hard error on an unrepresentable value can say exactly that:

```pascal
Options := TStructuralConversionOptions.Default;
Options.NamePolicy  := TStructuralNamePolicy.Encode;
Options.ValuePolicy := TStructuralValuePolicy.Error;
Payload := TSerialization.Convert(Json, ..., Options);
```

**There is no `Skip` and no `Drop`.** Silently losing a member is the one
behaviour this design does not offer.

**One documented omission, under `Natural` only.** A schema-driven
destination - Avro, and ASN.1 in BER, DER and CER - writes only what its
schema names. Under `Natural`, a member the schema does not name is omitted:
the schema is the destination's whole vocabulary, and the caller who chose
that schema and that profile asked for its idiom. `Strict` and `Lossless`
refuse it with `EStructuralConversionError` naming its path
(`$.Customer.InternalCode`). The same split applies to a CBOR map key that
is not text: `Natural` writes its diagnostic notation, and `Strict` and
`Lossless` refuse. See [`formats/avro.md`](formats/avro.md),
[`formats/asn1.md`](formats/asn1.md) and [`formats/cbor.md`](formats/cbor.md).

### No private interchange metadata

This library does not invent a wrapper, a marker attribute, a reserved member
name or a provenance flag and write it into somebody's document.

An earlier version did. Lossless conversion used to add a two-member object
of its own to JSON and an attribute in a namespace of its own to XML. It was
reversible, and it was worthless to every tool that was not this one — which
is most of them, and eventually includes the reader of the document three
years from now.

So `Lossless` now means one of exactly two things:

* the **published standard** for that pair of formats is used, or
* the conversion **refuses**, with `TStructuralIssue.UnsupportedLosslessConversion`
  and a message naming the route that does work.

| pair | the standard used |
| --- | --- |
| JSON → XML | the W3C JSON/XML mapping — `fn:json-to-xml`, namespace `http://www.w3.org/2005/xpath-functions` |
| XML → JSON | the same mapping, read back |
| BSON → JSON | MongoDB Extended JSON |
| JSON → BSON | MongoDB Extended JSON, read back |
| anything → BSON | nothing to write: BSON's own types cover the dynamic tree |

`scripts\check-banned-markers.ps1` enforces the absence, across source,
tests, demos and documentation, and reports
`PASCALFORGE_STRUCTURAL_METADATA_REFERENCES: 0`.

### Errors carry a path

Every structural failure is an `EStructuralConversionError` and names where it
happened, what was there and why it could not be written:

```text
Structural conversion Json -> Xml failed at $.IndPersonInfo.$type (string):
cannot represent member "$type" directly as an XML element name. …
```

```pascal
E.SourceFormat       // Json
E.DestinationFormat  // Xml
E.Path               // '$.IndPersonInfo.$type'
E.SourceKind         // the dynamic kind that could not be written
E.Issue              // InvalidDestinationName | UnsupportedValueKind |
                     // UnsupportedLosslessConversion | …
```

Array elements appear as `$.RelatedPersons[4].Name`.

### XML names under Natural

`Natural` has to put a member name into an XML *element name*, and an element
name cannot contain a dollar sign, an at sign, a space or a colon and cannot
begin with a digit. The convention used is the one .NET's
`XmlConvert.EncodeName` uses, so the result is readable by tooling that has
never heard of this library:

```text
$type           ->  _x0024_type
@odata.context  ->  _x0040_odata.context
1stValue        ->  _x0031_stValue
first name      ->  first_x0020_name
foo/bar         ->  foo_x002F_bar
a:b             ->  a_x003A_b
```

**The escape escapes itself**, which is the part that makes it safe. An
underscore followed by an `x` is always encoded, even though XML would accept
it, so a name that already *looks* encoded cannot collide with one that had
to be:

```text
$type        ->  _x0024_type
_x0024_type  ->  _x005F_x0024_type
```

Since `decode(encode(s)) = s` for every `s`, `encode` is injective: two
different source names can never arrive at the same destination name.

**Decoding is explicit and is never automatic.**

```pascal
TXmlNameCodec.EncodeName('$type');        // '_x0024_type'
TXmlNameCodec.DecodeName('_x0024_type');  // '$type'
```

Reading XML structurally does **not** decode. The XML being read is somebody
else's, and an element genuinely called `<_x0041_>` is a member called
`_x0041_` — not a member called `A`. Rewriting foreign documents on the
strength of a convention they never agreed to is exactly the
guess-from-spelling this library refuses everywhere else. A caller who *knows*
the document came from this convention calls `TXmlNameCodec.DecodeName`
themselves, on the names they care about.

The consequence is stated plainly: **`Natural` does not round trip an
XML-impossible name.** `$type` goes out as `<_x0024_type>` and comes back as
`"_x0024_type"`. The profile that survives that trip is `Lossless`, which
puts the name in an attribute where nothing needs encoding at all.

Names beginning with `xml` are reserved by the XML specification and are
deliberately **not** encoded: every parser accepts `<XmlMessage>`, and turning
it into `_x0058_mlMessage` would buy nothing.

**Name adaptation belongs to the destination.** JSON → XML encodes, because
XML cannot spell the name. JSON → BSON does not, because BSON can: `$type`
arrives in BSON as `$type`. JSON → DataSet applies DataSet's rules, not XML's.
Nothing renames a member in the dynamic tree itself.

### Lossless JSON and XML: the W3C mapping

"XPath and XQuery Functions and Operators 3.1" defines `fn:json-to-xml` and
`fn:xml-to-json`, a complete bidirectional mapping between JSON's data model
and an XML vocabulary. It is implemented by every XSLT 3.0 and XQuery 3.1
processor — Saxon, BaseX, eXist — which means a document written here is read
by tools that have never heard of this library.

```xml
<map xmlns="http://www.w3.org/2005/xpath-functions">
  <string key="$type">Subject</string>
  <number key="Id">1</number>
  <boolean key="Active">true</boolean>
  <array key="Tags"/>
  <null key="Rating"/>
  <string key="first name">Ada</string>
</map>
```

Six element names — `map`, `array`, `string`, `number`, `boolean`, `null` —
and the member name in a `key` **attribute**, which is why `$type`, a name
with a space in it and a Georgian identifier all travel as themselves. Text
that XML cannot hold at all carries `escaped="true"` and JSON backslash
escapes, and a key in the same position carries `escaped-key="true"`; both are
the specification's, not this library's.

Reading is symmetric, and it is **not** gated on the profile: a document whose
root element is in that namespace is in that vocabulary, unambiguously,
because the namespace is the W3C's. (MongoDB Extended JSON is gated, because
it has no namespace and `$oid` is a member name real documents contain — see
below.)

### Lossless BSON and JSON: MongoDB Extended JSON

BSON has twenty-two element types and JSON has six. MongoDB Extended JSON is
the published answer to exactly that, and it is what `Lossless` writes:

```json
{
  "_id":       {"$oid": "507f1f77bcf86cd799439011"},
  "CreatedAt": {"$date": {"$numberLong": "1773480413120"}},
  "Blob":      {"$binary": {"base64": "AQID+v8=", "subType": "00"}},
  "Money":     {"$numberDecimal": "123.45"}
}
```

`ToExtendedJson` and `FromExtendedJson` on `TBsonSerializer` are the direct
route; `TSerialization.Convert(…, Lossless)` is the same thing through the
general facade.

**Recognition is deliberate, not automatic.** An object whose only member is
`$oid` is read back as an ObjectId only when the caller asked for `Lossless`
*and* the destination is BSON. Under `Natural` it is an object with a member
called `$oid`, because that is what it is, and real documents do contain one.

### Where no standard covers the pair, the facade composes one

BSON binary into XML has no published representation of its own: the W3C
mapping is a mapping of *JSON*, and JSON has no binary. There are two
published standards that meet in the middle —

```text
BSON
  ↓ MongoDB Extended JSON
JSON
  ↓ W3C JSON/XML
XML
```

— and asking for the *profile* composes them:

```pascal
Xml := TSerialization.Convert(Bson, TSerializationFormat.Bson,
         TSerializationFormat.Xml, TStructuralConversionProfile.Lossless);
```

The caller writes one call. They do not run both bridges by hand, and the
BSON-only types — an ObjectId, an instant, a 64-bit integer, a binary —
travel through XML as the Extended JSON objects the first standard made of
them, and come back on the way home. `tests\LosslessRouting` asserts the
whole trip.

**The routes are a table, not a search.** There is no path finding here and
deliberately none: a resolver that searched would one day pick a surprising
three-hop route through a format nobody expected, and a caller would have no
way to predict what their data had been through. The table is in
`PascalForge.Serialization` and it currently has two rows — BSON to XML and
XML to BSON, both via JSON. Adding a route means adding a row and citing the
standards it rests on.

Only `Lossless` composes. `Natural` already converts these pairs directly
and idiomatically, and routing one through a hub would change what it writes
for no reason the caller asked for.

#### Routing is inspectable

A caller who asked for Lossless is entitled to know which standards their
data went through, because that is the entire basis of the guarantee. So
every conversion can report its route — before it runs, and after:

```pascal
Route := TSerialization.RouteFor(Bson, Xml, Lossless);
Writeln(Route.Describe);
// Bson -> MongoDB Extended JSON -> Json -> W3C JSON/XML -> Xml
Writeln(Route.HopCount, ' ', Route.IsComposed);   // 2 TRUE

Result := TSerialization.Convert(Src, Bson, Xml, Lossless, Route);
// Route now says what it DID, and it is the same route.
```

A one-hop route is inspectable too, and names the standard it rests on when
it has one: `RouteFor(Json, Bson, Lossless).Steps[0].Standard` is
`'MongoDB Extended JSON'`.

#### The one-hop primitive still refuses

The overload that takes `TStructuralConversionOptions` is the primitive: it
converts exactly once and never composes. Asked for BSON into XML it refuses,
with `TStructuralIssue.UnsupportedLosslessConversion`, and names the route
that works:

```text
Structural conversion Bson -> Xml failed at $.Blob (binary): the W3C JSON/XML
mapping is a mapping of JSON, and JSON has no binary type. Convert to JSON
under the Lossless profile first - that writes MongoDB Extended JSON - and
convert the result to XML
```

Naming a *profile* is asking for an outcome, so that overload may compose.
Supplying *options* is asking for one conversion, so that one does not. A
caller who wants to know whether a single hop is possible asks the
primitive; `tests\StructuralFidelity` asserts both halves of that.

### What Lossless buys, exactly

The guarantee is about MEANING, and it is worth stating precisely because
the obvious reading of "lossless" is wrong:

> The source's semantic structure and its supported native semantic types
> are preserved through the declared standards-based conversion.

Whitespace, indentation, member spacing, attribute order and every other
piece of lexical trivia are **not** preserved unless a format's own API says
so. `Lossless` is not a promise that arbitrary text comes back byte for byte.

```pascal
Canon := TSerialization.Convert(Src, Json, Json);
Round := TSerialization.Convert(
           TSerialization.Convert(Src, Json, Xml, Lossless),
           Xml, Json, Lossless);
// Round = Canon, exactly - member names, order, nulls, empty arrays,
// integers as integers and booleans as booleans.
```

That works because of a second, narrower property which is **ours and not
the standards'**: PascalForge's JSON writer is canonical, so an unchanged
tree writes unchanged bytes. The two are asserted separately, and named
separately, so that a passing chain is never read as a promise the standards
do not make:

```text
LOSSLESS_SEMANTIC_CHAIN_EQUAL     the dynamic tree survived every hop -
                                  members, order, and kinds
CANONICAL_JSON_CHAIN_BYTE_EQUAL   and our canonical JSON reproduced the
                                  same bytes
```

`tests\FormatChain` walks one document through every structural format the
registry has and back, and asserts both. `tests\StructuralFidelity` asserts
the pair on a document with `$type` discriminators, Georgian text, nulls,
empty arrays and an embedded XML document as a string.
`tests\ConversionMatrix` asserts it for **every** pair of structural formats
the registry knows.

### What Natural costs

Under `Natural`, XML is still XML, and two things do not survive the trip
back:

* **types.** Scalars come back as text, because XML text has no type.
* **the difference between an empty list and an empty element.** XML writes a
  list as repeated sibling elements, so a list with no members has nothing to
  repeat. It is written as one empty element rather than dropped — the member
  survives; its kind does not.

Both are asserted, so the documentation stays true. Neither is a reason to
add a marker: `Lossless` is the answer, and it is one sentence away.

## A string stays a string

Text that *looks* like another format is not re-examined. The source said it
was a string.

```json
{"XmlMessage": "<GetSubjectInfoResponse xmlns=\"…\">…</GetSubjectInfoResponse>"}
```

becomes, in XML, an escaped string — never child elements:

```xml
<XmlMessage>&lt;GetSubjectInfoResponse …&gt;…&lt;/GetSubjectInfoResponse&gt;</XmlMessage>
```

The same holds for JSON-looking, base64-looking and date-looking text, and it
holds even when the destination *has* the type being suggested: a date-shaped
string converted to BSON becomes a BSON string, not a BSON datetime. A value
changes type only when a contract says so, when the source format natively
carried the other type, or when a caller explicitly asks.

## XML-only structure

XML carries things the dynamic tree does not. Each has a documented
convention rather than silent loss:

| XML | dynamic / JSON |
| --- | --- |
| an element with only text | a string |
| an element with children | an object |
| repeated children of one name | an array under that name |
| an attribute `a` | a member named `@a` |
| text alongside children | a member named `#text` |
| a namespace URI | a member named `@xmlns` |

Not recoverable in the `Natural` profile: prefix spelling, ordering between
differently-named siblings, and the difference between one repeated element
and an array of one. The `Lossless` profile does not use this projection at
all — every member is an element there, and member order survives exactly —
so an XML document converted out and back under `Lossless` keeps its structure
but loses the attribute/element distinction, while under `Natural` it keeps
the distinction and loses the types. Pick the one whose loss you can afford,
or use contract-aware conversion, which has neither.

Going the other way, a member name that is not a valid XML element name is
**encoded reversibly** under `Natural` and `Lossless`, and refused with its
path under `Strict`. It is never dropped and never mangled.

## The `From` API

Every format facade has the destination-oriented form. The destination is
known at compile time, so only the **source** is looked up:

```pascal
Json := TJsonSerializer.From<TShipment>(Xml, TSerializationFormat.Xml);
Xml  := TXmlSerializer.From<TShipment>(Bson, TSerializationFormat.Bson);
Bson := TBsonSerializer.From<TShipment>(Json, TSerializationFormat.Json);
```

with `string`, `TBytes` and `TSerializationPayload` overloads, and a
non-generic structural form of each. A binary source arrives as bytes; there
is no base64-pretending-to-be-text overload.

No format unit has a compile-time dependency on another. The source is reached
through the registry, by `TSerializationFormat`, at run time — which is why
both formats have to be registered, explicitly, at startup:

```pascal
uses
  PascalForge.Json.Registration,
  PascalForge.Xml.Registration;

TJsonSerializationRegistration.RegisterFormat;
TXmlSerializationRegistration.RegisterFormat;
```

Linking the units registers nothing. A format that nobody registered raises
`ESerializationFormatNotRegistered` naming the call to make. Nothing ever
falls back to another format.

## Registered is not the same as able

A format can be registered and still be unable to do a particular job — a
schema-driven encoding cannot decode its own bytes into a structural tree
without the schema. That is a *different* failure from not being registered,
and it gets a different exception, because telling someone to add a unit they
already have wastes their afternoon.

```pascal
if TSerialization.Supports(F, TSerializationFormatCapability.StructuralParse)
  then …

for F in TSerialization.StructuralFormats do   // the ones that can
  …
```

| | |
| --- | --- |
| `StructuralParse` | `ToDynamic` works |
| `StructuralWrite` | `FromDynamic` works |
| `ContractSerialize` | `SerializeTyped` works |
| `ContractDeserialize` | `DeserializeTyped` works |

Every format answers yes to the contract pair. The schema-driven formats -
Protobuf, Avro and the three ASN.1 formats - answer yes to the structural
pair only when their schema is in the options; the others always do. A
handler that cannot
overrides `Capabilities`, and asking it anyway raises
`ESerializationFormatCapability` naming what is missing.

## Bytes out

A conversion returns a `TSerializationPayload`, which is text or bytes and
knows which. When you need UTF-8 bytes, say so:

```pascal
Utf8 := TSerialization.Convert(Xml,
  TSerializationFormat.Xml, TSerializationFormat.Json).ToUtf8Bytes;
```

`ToUtf8Bytes` raises on a payload that is already binary, rather than handing
its bytes back as though they were text. See
[`unicode-and-utf8.md`](unicode-and-utf8.md).

## What is not a conversion path

`DataSet` is a projection target, not an intermediate. `JSON → DataSet → XML`
is not how cross-format conversion works and is not offered: the dynamic tree
is the intermediate without a contract, and the Delphi model is the
intermediate with one. Building a DataSet from an encoded document is an
explicit, caller-requested operation — see
[`dataset-projection.md`](dataset-projection.md).
