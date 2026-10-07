# XML behaviour

How the XML engine maps Delphi values to and from XML. This document covers
**XML only** — JSON and BSON have their own rules and their own attributes;
see [`serializer-behavior.md`](serializer-behavior.md) and
[`bson-behavior.md`](bson-behavior.md).

*Which* XML — the exact standard and profile, the full feature ledger, the
security audit, and the evidence from an independent processor — is in
[`xml-compatibility.md`](xml-compatibility.md). This page is about what the
library writes for a Delphi type; that one is about whether it is an XML
processor at all.

Ownership is defined once, for every format, in
[`deserialization-ownership.md`](deserialization-ownership.md).

XML is a real engine. `TXmlSerializer.Serialize<T>` writes a Delphi value
straight to XML and `Deserialize<T>` reads it straight back; nothing routes
through JSON, through BSON, or through the dynamic tree. Using it needs no
registration — `PascalForge.Xml.Registration` exists only for code that picks
a format at run time.

## The document

```pascal
Xml := TXmlSerializer.Serialize<TShipment>(Shipment);
Shipment := TXmlSerializer.Deserialize<TShipment>(Xml);
TXmlSerializer.Populate<TShipment>(Existing, Xml);
```

`TXmlSerializationOptions` has three fields, all off by default because the
compact form is the wire form: `Indent`, `Declaration`, and `RootName`.

### The reader

Deliberately small and strict. It handles elements, attributes, text, CDATA,
comments, processing instructions, the five predefined entities, numeric
character references, and namespace declarations.

It **refuses a `DOCTYPE`** rather than ignoring one. A parser that quietly
accepts a document type declaration is how XXE attacks get in, and a
serialization format has no use for one. There is no DTD support, no external
entity resolution, and no entity beyond the predefined five.

## Naming

- Root element: `TXmlSerializationOptions.RootName` if set, else `[XmlName]`
  on the type, else the type's name with a leading `T` removed when what
  remains is a valid XML name (`TShipment` → `Shipment`), else `Value`. A closed
  generic's name carries angle brackets and cannot be an element name at all,
  so it falls through to `Value`.
- Member element: **the Delphi member name, unchanged**. XML's convention is
  PascalCase, and unlike JSON nothing is lower-cased.
- `[XmlName('ShipmentID')]` overrides either.
- `[XmlIgnore]` removes the member from both directions.

A name that is not a valid XML name is refused when the plan is built, naming
the member.

## Placement

| attribute | effect |
| --- | --- |
| *(none)* | a child element |
| `[XmlAttribute]` | an attribute of the owner's element |
| `[XmlText]` | the owner element's own text content |

`[XmlAttribute]` and `[XmlText]` require a value with a single text form: a
scalar, an enumeration, a set, a GUID, a `TBytes`, a date, or a nullable of
one of those. Anything else raises at plan-build time saying so. At most one
member of a type may be `[XmlText]`; a second one raises.

## Presence and absence

XML has no null, and one is not invented.

- A nullable with no value is **omitted**.
- An object, list or dictionary member that is `nil` is **omitted**.
- On read, an absent element leaves the target as constructed.
- An element carrying `xsi:nil="true"` **detaches** an object member without
  freeing it, and empties a nullable. That is read-only behaviour: the engine
  never writes `xsi:nil` for a member, because omission already says "absent".

## Scalars

| Delphi | XML |
| --- | --- |
| `Boolean` and friends | `true` / `false` |
| every integer width, `Int64` | the digits |
| `Single`, `Double`, `Extended` | invariant decimal |
| `Currency` | invariant decimal |
| `string` | the text, with `& < >` escaped |
| `TBytes` | base64 (`xs:base64Binary`) |

## Date, time and GUID

Defaults, with nothing configured:

| Delphi | XML |
| --- | --- |
| `TDate` | `xs:date` — `2026-03-14` |
| `TTime` | `xs:time` — `17:30:00`, with `.zzz` when there are milliseconds |
| `TDateTime` | `xs:dateTime` — `2026-03-14T09:26:53`, **no offset** |
| `TGUID` | lower-case, unbraced |

A `TDateTime` carries no time zone, so none is invented. An offset in an
incoming document is accepted and **ignored**: the wall-clock fields are taken
as written, which is the only reading a `TDateTime` can represent honestly.

A `TDate` or `TDateTime` outside the years 1 to 9999 is refused on write with
`ESerializationUnsupported`, in every form but `xs:time`; a Unix count outside
them is an `EXmlInputError` on read. `UnixSeconds` writes the second an
instant falls in, rounded toward the past.

Representation is configurable per member, per field, per type and globally,
independently of JSON's and BSON's — see
[`datetime-policies.md`](datetime-policies.md).

## Enumerations and sets

- Enumeration: the RTTI name, or `TXmlSerializer.RegisterEnumMapping<T>`'s
  value for that ordinal. XML's mapping table is its own; JSON's is a
  different table for the same enumeration.
- Set: **space-separated**, which is what `xs:list` does —
  `<Channels>Retail Government</Channels>`. JSON joins the same set with
  commas. The two formats are not obliged to agree, and here they do not.

## Nullable values

`PascalForge.Nullable.TNullable<T>` is recognised automatically, and a foreign
nullable family once it is registered — see
[`nullable-families.md`](nullable-families.md). Recognition is shared with
JSON, BSON and the DataSet projection.

## Objects and records

A nested object or record becomes a child element containing its own members.
Inherited members appear exactly once, even when a descendant republishes a
property. Instances are constructed through a parameterless constructor.

On read an existing member instance is **reused, not replaced**: populated in
place, keeping every member the document does not mention.

## Collections

Recognition is by RTL class ancestry, not by name — `TList<T>` and
`TDictionary<K,V>` and every descendant.

```xml
<Lines>
  <OrderLine><Sku>A-1</Sku><Quantity>2</Quantity></OrderLine>
  <OrderLine><Sku>B-2</Sku><Quantity>5</Quantity></OrderLine>
</Lines>
```

- The **wrapper** is named after the member. `[XmlArray('Items')]` renames it;
  `[XmlArray('')]` removes it, and the items become repeated siblings of the
  owner's element.
- An **item** is named after its own type by the root-name rule
  (`TOrderLine` → `OrderLine`), or `Item` for a scalar element type.
  `[XmlItemName('Line')]` overrides it.
- A **dictionary** is entries carrying the key as an attribute, which keeps
  one entry to one element whatever the value turns out to be:

```xml
<Rates><Entry key="USD">1</Entry><Entry key="GBP">0.79</Entry></Rates>
```

  The entry element is named `Entry` by default and the key attribute is
  always `key`. A dictionary key must have a single text form.

A container that already exists is **reused**: every key and element is read
first, then the container is cleared and refilled. A container element that
holds anything but its item elements - another element name or namespace, or
text - a dictionary entry with no key, or an element that does not read is
refused with `EXmlInputError` before the container is touched.

## Namespaces

`[XmlNamespace('urn:example:envelope')]` on a type sets the root's namespace
and is inherited by every member that does not say otherwise;
`[XmlNamespace(...)]` on a member overrides it for that element.

**Identity is the namespace URI. A prefix is a spelling.** Two documents that
spell the same namespace `p` and `ns1` are the same document to this engine,
and reading compares URIs rather than raw tag text. The writer declares every
namespace once, on the root, and picks the prefixes itself — the root's own
namespace becomes the default so the common case reads like ordinary XML.
Prefix spelling is therefore **not contractual**; the URI is.

An unprefixed attribute is in no namespace, default declaration or not, which
is the XML rule and is what makes `xsi:nil` behave the same under a default
namespace as without one.

## Custom serializers

```pascal
TTypeSerializer = class(TCustomXmlValueSerializer<TCoordinate>)
  procedure SerializeValue(const AValue: TCoordinate; AElement: TXmlElement); override;
  function DeserializeValue(AElement: TXmlElement; const AExisting: TCoordinate): TCoordinate; override;
end;
```

A custom XML serializer is handed **the element the value occupies**, so it
may write text, attributes, children, or all three.
`TXmlTextValueSerializer<T>` is the convenience base for a value that is one
piece of text. `[XmlSerializer(TSomething)]` names one for a single member;
`RegisterTypeSerializer<T>` covers every value of a type.

An XML serializer is XML's. It does not become a JSON or a BSON serializer —
those formats have their own contracts and their own natural shape for the
same Delphi value.

## Structural conversion

`TSerialization.Convert(Source, Xml, Json)` has no Delphi contract, so
XML-only structure has to go somewhere. The convention is deterministic and
lossy, and it is stated rather than hidden:

| XML | dynamic / JSON |
| --- | --- |
| an element with only text | a string |
| an element with children | an object |
| repeated children of one name | an array under that name |
| an attribute `a` | a member named `@a` |
| text alongside children | a member named `#text` |
| a namespace URI | a member named `@xmlns` |

What is **not** recoverable in this profile: prefix spelling, ordering between
differently-named siblings, and the difference between one repeated element
and an array of one.

### Member names XML cannot spell

A structural document from JSON or BSON can have member names that are not
legal XML element names — `$type`, `first name`, `@odata.context`,
`1stValue`, `foo/bar`, `a:b`. Under `Natural` they are **encoded**, never
dropped and never mangled, in the convention .NET's `XmlConvert.EncodeName`
uses:

```text
$type  ->  <_x0024_type>
```

An underscore followed by an `x` is encoded too, so a name that already looks
encoded cannot collide with one that had to be. The codec is public as
`TXmlNameCodec`.

**Reading does not decode.** An element genuinely called `<_x0041_>` is a
member called `_x0041_`, because the XML being read is somebody else's and
nothing in it agreed to this convention. So `Natural` is one-way for such a
name: `$type` goes out as `<_x0024_type>` and comes back as `"_x0024_type"`.
A caller who knows where the document came from calls
`TXmlNameCodec.DecodeName` on the names they care about.

`Strict` refuses such a name instead, with the member path. `Lossless` has no
name problem at all — see below. The scheme, the collision rule and the proof
are in [`conversion.md`](conversion.md).

### The Lossless profile is the W3C JSON/XML mapping

XML text carries no type, so a structural round trip through XML under
`Natural` turns `7` into `"7"`. `TStructuralConversionProfile.Lossless`
answers that with a **published standard** rather than with a convention of
this library's: the mapping "XPath and XQuery Functions and Operators 3.1"
defines as `fn:json-to-xml` and `fn:xml-to-json`.

```xml
<map xmlns="http://www.w3.org/2005/xpath-functions">
  <number key="Id">1</number>
  <boolean key="Active">true</boolean>
  <array key="Tags"/>
  <null key="Rating"/>
  <string key="$type">Subject</string>
</map>
```

Six element names — `map`, `array`, `string`, `number`, `boolean`, `null` —
and the member name in a `key` attribute, which is why nothing has to be
encoded: `$type`, `first name` and a Georgian identifier are all ordinary
attribute text. Text XML cannot hold at all carries `escaped="true"` and JSON
backslash escapes; a key in the same position carries `escaped-key="true"`.

Every XSLT 3.0 and XQuery 3.1 processor reads this vocabulary, so a document
written here is not a document only this library understands.

In that profile the `@name` / `#text` projection above is **not** used: every
value is one of the six elements, and member order survives exactly.

**Reading is unconditional.** A document whose root element is in that
namespace is read as that vocabulary in every profile, because the namespace
is the W3C's and an ordinary document cannot wander into it by accident.

**A dynamic kind JSON does not have is refused, not improvised.** The W3C
mapping is a mapping of JSON, so BSON binary and BSON timestamps have no
place in it. Converting one raises
`TStructuralIssue.UnsupportedLosslessConversion`, and the message names the
route that works: BSON → JSON under `Lossless` is MongoDB Extended JSON, and
that is ordinary JSON, which the W3C mapping carries exactly.

Under `Natural`, an empty array is written as one empty element rather than
dropped. The member survives; the fact that it was a list does not. That is
the profile's stated bargain and there is no marker to change it.

Contract-aware conversion — `Convert<T>` — keeps everything without any of
this machinery, because the Delphi type says what each member is. Prefer it
whenever the semantics matter. See [`conversion.md`](conversion.md).

### Text with characters XML cannot hold

XML 1.0 has no spelling for most control characters — not literally, and not
as a numeric reference either — nor for an unpaired UTF-16 surrogate, half a
character. A value containing one is **refused** by name (`EXmlError`) rather
than written into a document no parser will read back; a whole surrogate
pair is written normally. Encode it (as base64, say) before it becomes XML.

## Unicode and UTF-8

`Serialize<T>` returns a Delphi string: Unicode text with no byte encoding.
`SerializeUtf8<T>` returns `TBytes`, turns the XML declaration on, and writes
UTF-8 with no BOM — so `encoding="UTF-8"` and the bytes that follow it agree.
`DeserializeUtf8<T>` accepts a leading BOM. See
[`unicode-and-utf8.md`](unicode-and-utf8.md).

## Errors

`EXmlError` and its two descendants: `EXmlInputError` for a document at fault
(not well formed, a scalar that will not parse, a DOCTYPE) and
`EXmlInternalError` for a model or configuration at fault (a member that
cannot be an attribute, two `[XmlText]` members, a duplicate element name).
Reader errors carry a line and column.
