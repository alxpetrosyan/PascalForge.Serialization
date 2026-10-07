# XML

## Purpose

This is the entry point for the XML format. It summarizes what the format
does and where the code is. For depth, read
[`../xml-behavior.md`](../xml-behavior.md) (what the library writes for a
Delphi type) and [`../xml-compatibility.md`](../xml-compatibility.md) (the
profile, the feature ledger and the security audit). The API is in
[`../api-reference.md`](../api-reference.md).

XML is a real engine. A Delphi value is written straight to XML text and
read straight back. Nothing goes through JSON, another format, or the
dynamic tree on the contract path. The reader is the library's own; no SDK
XML unit is used by the library. The natural payload type is `string`.

## Standard/profile

- **XML 1.0 Fifth Edition** and **Namespaces in XML 1.0 Third Edition**.
- **Non-validating.** `<!ELEMENT>`, `<!ATTLIST>` and `<!NOTATION>` are
  parsed and ignored. No attribute default is applied.
- **External entity resolution disabled.** A DOCTYPE external identifier is
  parsed and not fetched. An external entity declaration is refused by name.
  The reader contains no code that can open a file or a socket.
- **Parameter entities are refused** by name.
- A DOCTYPE with an internal subset and internal general entities is read.
  The five predefined entities, decimal and hex character references, CDATA,
  comments and processing instructions are handled (comments and PIs are
  skipped).
- Namespace identity is URI plus local name. A prefix is a spelling and is
  not contractual.

Not implemented: validation, external entities, parameter entities, and
Canonical XML (C14N). Output is deterministic for a given input and options,
which is a weaker statement than C14N.

## Public facade

Unit `PascalForge.Xml`, class `TXmlSerializer`. All methods are class
static.

| Method | Signature |
| --- | --- |
| `Serialize<T>` | `(const AValue: T): string`, and with `TXmlSerializationOptions` |
| `SerializeUtf8<T>` | `(const AInstance: T): TBytes` (declaration on), and with `TXmlSerializationOptions` |
| `Deserialize<T>` | `(const AXml: string): T` |
| `DeserializeUtf8<T>` | `(const AXml: TBytes): T`; a leading BOM is accepted |
| `Populate<T>` | `(const AInstance: T; const AXml: string)` |
| `From` | structural: `(ASource: string / TBytes / TSerializationPayload; AFrom: TSerializationFormat): string`, and payload overloads with `TStructuralConversionProfile` and optionally `TXmlSerializationOptions` |
| `From<T>` | contract-aware: the same source overloads, and a payload overload with `TXmlSerializationOptions` |
| `ToDynamic` / `FromDynamic` | `(const AXml: string): TDynamicValue` / `(AValue: TDynamicValue; const ARootName: string = 'Value'): string`, each also with `TStructuralConversionOptions` - see [`../dynamic.md`](../dynamic.md) |

The general attributes apply; `[XmlName]`, `[XmlIgnore]` and `RegisterEnumMapping` beat them for XML. See [`../attributes.md`](../attributes.md).

There is no `TryDeserialize` and no UTF-8 `Populate`. `TXmlSerializationOptions`
has `Indent`, `Declaration` and `RootName`, all off or empty by default.

`TXmlNameCodec` (`EncodeName`, `DecodeName`, `IsValidName`) is public, for a
caller who reads a converted document with other XML tools. `TXmlElement` is
the small document model a custom serializer writes into.

Configuration (call at startup):

- `SetDateTimeFormat` (a `TXmlDateTimeFormat` or a pattern),
  `RegisterDateTimeFormat<T>`, `RegisterFieldDateTimeFormat<T>(AFieldName, ...)`
- `RegisterEnumMapping<T>(const AValues: array of string)`
- `RegisterTypeSerializer<T>(ASerializerClass: TXmlValueSerializerClass)`
- `FreezeConfiguration`, `IsFrozen`, `ResetConfiguration` (for tests)

Configuration freezes automatically at the first real serializer operation
(`Serialize`, `SerializeUtf8`, `Deserialize`, `Populate`, `From<T>`, or the
registry's typed calls). After that, configuration is immutable and
concurrent use is safe. A registration made after the freeze raises
`EXmlInternalError` saying the configuration is frozen. `FreezeConfiguration`
freezes earlier, and `IsFrozen` reports the state. See
[`../configuration-lifecycle.md`](../configuration-lifecycle.md) for the full
lifecycle.

Exceptions: `EXmlError`, `EXmlInputError` (the document is at fault: not
well formed, a scalar that will not parse, a refused DTD construct; reader
errors carry a line and column), and `EXmlInternalError` (model or
configuration: a member that cannot be an attribute, two `[XmlText]`
members, a late registration).

## Explicit registry registration

```pascal
uses
  PascalForge.Xml.Registration;
...
TXmlSerializationRegistration.RegisterFormat;
```

- Linking or importing `PascalForge.Xml.Registration` does **not** register
  the format.
- Loading the runtime package `PascalForge.Serialization.Runtime.bpl` does
  **not** register it.
- `RegisterFormat` is idempotent. It raises `ESerializationFormatConflict`
  if a different handler already holds `TSerializationFormat.Xml`.
- `UnregisterFormat` is safe when the format is absent, and never removes
  another unit's handler.
- `IsRegistered` reports whether this unit's handler holds the format.

Direct `TXmlSerializer` use needs no registration. Registration is needed
only for `TSerialization` (format chosen at run time), `TSerialization.Convert`,
and the `TDataSetSerializer` overloads that take a `TSerializationFormat`.

All formats at once: `TSerializationFormatsRegistration.RegisterAll` in unit
`PascalForge.Serialization.AllFormats`. It is also explicit.

Registry mutation happens at startup and shutdown. It must not run
concurrently with serialization.

## Native Delphi mappings

| Delphi | XML, by default |
| --- | --- |
| `Boolean` | `true` / `false` |
| integers of every width, `UInt64` | the digits |
| `Single`, `Double`, `Extended` | shortest round-trip decimal; `NaN`, `INF`, `-INF` |
| `Currency` | invariant decimal text |
| `string` | escaped element text |
| `TBytes` | base64 (`xs:base64Binary`) |
| `TDate`, `TTime`, `TDateTime` | `xs:date`, `xs:time`, `xs:dateTime`, no offset; `.zzz` when there are milliseconds |
| `TGUID` | lower case, unbraced |
| enumeration | member name, or the registered mapping |
| set | space-separated member names (`xs:list` style) |
| class, record | child element with its members as children |
| list, dynamic or static array | wrapper element with one element per item |
| dictionary | wrapper with `Entry` elements carrying a `key` attribute |
| `TNullable<T>` with no value, `nil` object | member omitted |
| `Variant` | refused |

Root element: `RootName`, else `[XmlName]` on the type, else the type name
without a leading `T`, else `Value`. Member elements use the Delphi name
unchanged.

Member attributes: `XmlName`, `XmlIgnore`, `XmlAttribute` (write as an
attribute of the owner), `XmlText` (write as the owner's text; at most one),
`XmlNamespace` (URI, optional prefix hint), `XmlArray` (wrapper name;
`''` removes the wrapper), `XmlItemName`, `XmlDateTimeFormat` (`Xsd`,
`UnixSeconds`, `UnixMilliseconds`, `Custom` pattern), `XmlSerializer`.

On read, `xsi:nil="true"` detaches an object member without freeing it and
empties a nullable. The writer never emits `xsi:nil` for a member.

Dates, numbers and text:

- A `TDateTime` or `TDate` outside the years 1 to 9999 is refused on write
  (`ESerializationUnsupported`); an `xs:time` has no year to check.
- A zone offset on `xs:dateTime` text is accepted and **ignored**: the
  wall-clock fields are kept as written. Nothing is written with an offset.
- A `Custom` pattern is read back with the same pattern (numeric
  specifiers; `TStructuralText.TryDecodePattern`), then with the RTL's
  invariant reading.
- Float text is read correctly rounded (`TStructuralText.TryParseFloat`),
  the same on Win32 and Win64.
- U+0000, the other C0 controls except tab, newline and return, and an
  unpaired UTF-16 surrogate are refused on write with `EXmlError`. XML 1.0
  cannot hold them, literally or escaped. A whole surrogate pair is written
  normally.

Full detail: [`../xml-behavior.md`](../xml-behavior.md),
[`../datetime-policies.md`](../datetime-policies.md),
[`../delphi-type-coverage.md`](../delphi-type-coverage.md).

## Structural representation

XML declares all four registry capabilities with no schema. The payload kind
is text. The handler parses into `TXmlElement` and maps it to `TDynamicValue`
(`TXmlEngine.ElementToDynamic`), and back (`TXmlEngine.DynamicToElement`,
root element `Value`).

Element text has no type, so under `Natural` every scalar out of XML is a
string. `{"id":7}` comes back as `{"id":"7"}`.

| XML | `TDynamicValue` |
| --- | --- |
| element with only text, no attributes, no namespace | `Str` |
| empty element | `Str` (empty) |
| element with `xsi:nil="true"` | `Null` |
| element with children or attributes | `Obj` |
| repeated children of one name | `Arr` under that name |
| attribute `a` | member `@a` (`Str`) |
| text beside children or attributes | member `#text` |
| element namespace URI | member `@xmlns` |
| root in the W3C namespace | read as the W3C mapping, in every profile (see below) |

Lost in this projection: prefix spelling, order between differently named
siblings, and the difference between one repeated element and an array of
one.

Writing under `Natural`: `Null` is `xsi:nil="true"`, numbers and booleans are
text, `Bytes` is base64, dates are ISO text, an array is repeated sibling
elements (`Item` at the root), and an empty array is one empty element. A
BSON ObjectId, symbol or JavaScript value is its text; Decimal128 its
decimal text; undefined, MinKey and MaxKey are `xsi:nil`.

Names: a member name XML cannot spell is encoded reversibly by
`TXmlNameCodec`, in the convention of .NET `XmlConvert.EncodeName`
(`$type` becomes `_x0024_type`; `_x` is always encoded, so an encoded-looking
name cannot collide). Reading does **not** decode: `<_x0024_type>` comes back
as the member `_x0024_type`. A caller who knows the convention calls
`TXmlNameCodec.DecodeName`. `Strict` refuses such a name with
`TStructuralIssue.InvalidDestinationName` and the member path.

## Lossless behavior

`Lossless` into XML is the **W3C JSON/XML mapping** of "XPath and XQuery
Functions and Operators 3.1" (`fn:json-to-xml`, `fn:xml-to-json`), namespace
`http://www.w3.org/2005/xpath-functions`. Six element names (`map`, `array`,
`string`, `number`, `boolean`, `null`), member names in a `key` attribute, so
no name is encoded. Text XML cannot hold is written with `escaped="true"` and
JSON backslash escapes; a key the same way with `escaped-key="true"`. Member
order, nulls, empty arrays, integers and booleans survive. An integral
`number` reads back as `Int`, any other as `Float`.

A dynamic kind JSON does not have (binary, date, time, timestamp, a
source-native extended value) is refused with
`TStructuralIssue.UnsupportedLosslessConversion`, and the message names the
working route. As the code stands, `UInt` and `Decimal` values are refused
the same way, because `DynamicToW3C` does not choose an element for them.

BSON to XML under `Lossless` composes two standards through the facade's
route table: BSON, MongoDB Extended JSON, JSON, W3C JSON/XML, XML
(`TSerialization.RouteFor` reports it). XML to BSON is the reverse row. The
one-hop overload that takes `TStructuralConversionOptions` never composes
and refuses instead. `Lossless` does not keep XML's attribute/element
distinction. See [`../conversion.md`](../conversion.md).

## Contract-aware behavior

These depend on the Delphi type `T` (`Serialize<T>`, `Deserialize<T>`,
`TSerialization.Convert<T>`, `From<T>`):

- member and root names, `XmlName`, `XmlIgnore`, namespaces;
- placement: element, `XmlAttribute` or `XmlText`;
- wrappers and item names for collections and dictionaries;
- the typed reading of text: integers, floats, booleans, dates, GUIDs,
  base64, enumerations and sets, with range checks into the member type
  (`EXmlInputError`);
- date/time representation and enumeration mapping;
- `TNullable<T>` absence, `xsi:nil`, reuse of existing instances and
  containers;
- custom serializers.

Name encoding is not applied on this path: a name is what `XmlName` or the
member says, and an invalid one is refused when the plan is built. Without
`T`, a structural conversion carries only strings and structure (or, under
`Lossless`, what the W3C mapping holds).

## Schema/context

None is needed. The structural path works with no schema in the conversion
options. XML Schema (XSD) is not read; the `xs:` names above describe
spellings, not validation.

## DataSet behavior

`TDataSetSerializer.CreateFDMemTable(Xml, TSerializationFormat.Xml)` and the
other overloads that take a `TSerializationFormat` need the format
registered. The document is parsed into the dynamic tree and the schema is
inferred from it. See [`../dataset-formats.md`](../dataset-formats.md) and
[`../dataset-projection.md`](../dataset-projection.md).

| XML | Inferred field type |
| --- | --- |
| element text, attribute, `#text` | `ftWideString` |
| numeric, boolean or date-looking text | `ftWideString` (no string is inspected) |
| a column null (`xsi:nil`) in every row | `ftWideString` |
| nested element, or repeated elements with children | `ftDataSet` (nested) |
| W3C vocabulary: `number` integral, within 32 bits / wider | `ftInteger` / `ftLargeint` |
| W3C vocabulary: other `number` | `ftFloat` |
| W3C vocabulary: `boolean` | `ftBoolean` |

For ordinary XML every inferred column is `ftWideString`. Only a document in
the W3C namespace carries numbers and booleans. Supply the contract
(`CreateFDMemTable<T>(Xml, TSerializationFormat.Xml)`) for Delphi field
types. `TDataSetSerializer.Serialize(DataSet, TSerializationFormat.Xml,
Policy)` writes a DataSet packet as XML; the packet reader accepts field
types as text and a list of one as a single element.

## Custom serializers

Base classes in `PascalForge.Xml`. A serializer is handed the element the
value occupies, already named, and may write text, attributes and children.

- `TCustomXmlValueSerializer<T>`: override
  `SerializeValue(const AValue: T; AElement: TXmlElement)` and
  `DeserializeValue(AElement: TXmlElement; const AExisting: T): T`. Use this
  one.
- `TXmlTextValueSerializer<T>`: override `ToText` and `FromText` for a value
  that is one piece of text.
- `TCustomXmlValueSerializer`: the untyped base with `TValue` and
  `PTypeInfo`, for a type not known at compile time.

Registration:

```pascal
TXmlSerializer.RegisterTypeSerializer<TMoney>(TMoneyXmlSerializer);
```

Per member: `[XmlSerializer(TMoneyXmlSerializer)]`.

A read returns a new instance or the existing one it was given; returning a
different instance transfers the disposal decision for the old one. See
[`../customization.md`](../customization.md) and
[`../deserialization-ownership.md`](../deserialization-ownership.md).

## Limits/security

| Limit | Value | Error |
| --- | --- | --- |
| write depth | 64 levels (each object, record, array, list, dictionary counts one) | `ESerializationLimitExceeded` |
| element nesting, on read | 512 (`XML_ELEMENT_DEPTH_LIMIT`); the root is depth 0, so 513 elements | `EXmlInputError` |
| entity expansion | 8 MB (`XML_ENTITY_EXPANSION_BUDGET`), computed from the declarations before content is read, and charged while expanding | `EXmlInputError` |
| entity nesting | 32 levels (`XML_ENTITY_DEPTH_LIMIT`) | `EXmlInputError` |
| recursive entity | refused, naming the entity | `EXmlInputError` |
| entity reference scan | stops after 64 characters | - |
| character reference | range-checked against U+10FFFF | `EXmlInputError` |
| external entity, parameter entity | refused by name | `EXmlInputError` |
| invalid UTF-8 on the byte path | refused by byte offset, no U+FFFD | - |

`tests\Robustness` covers nesting bombs, entity expansion, truncation and
hostile substitutions.

## Expected refusals

By design, not bugs:

- the refusals every format makes: pointers, `PChar`, procedural and method
  types, anonymous methods, interfaces, class references, legacy `TList`,
  `TCollection`, streams, `Exception`, `TComponent`, cycles, inline static
  arrays, variant records, `TBcd` without a custom serializer;
- a value nested deeper than 64 levels;
- a `TDateTime` or `TDate` outside the years 1 to 9999, on write;
- U+0000, other C0 controls and unpaired UTF-16 surrogates in text, on
  write (`EXmlError`);
- every `Variant`, including `OleVariant` and variant arrays: element text
  has no type to say what one held (`EXmlError` at plan build);
- external entities and parameter entities, on read;
- under `Lossless`, dynamic kinds the W3C mapping of JSON cannot hold, when
  the one-hop primitive is used.

XML carries `UInt64` above `High(Int64)` and NaN and infinities. See
[`../expected-refusals.md`](../expected-refusals.md).

## Interoperability evidence

`tests\XmlNative` uses **MSXML**, through `Xml.XMLDoc`, as the independent
reference. Hand-written fixtures are read by MSXML and by this reader and the
semantic values compared; documents this writer produces are loaded by MSXML
and compared the same way. It also exercises every row of the feature ledger
in [`../xml-compatibility.md`](../xml-compatibility.md), with negative
fixtures for malformed input and the refused DTD constructs. MSXML is used
only by the test, never by the library.

`tests\XmlCore` checks the default contract through `TXmlSerializer` with no
format registered. `tests\LosslessRouting` and `tests\StructuralFidelity`
check the W3C mapping and the composed BSON route.

## Important implementation units

| Role | Unit |
| --- | --- |
| Facade | `src\PascalForge.Xml.pas` (`TXmlSerializer`, attributes, `TXmlElement`, `TXmlNameCodec`) |
| Implementation | `src\PascalForge.Xml.Internal.pas` (`TXmlReader`, writer, `TXmlEngine`: plans, RTTI walk, dynamic bridge, W3C mapping) |
| Registration | `src\PascalForge.Xml.Registration.pas` (`TXmlSerializationRegistration`, `TXmlFormatHandler`) |
| Schema | none |
| Tests | `tests\XmlCore\XmlCore.dpr`, `tests\XmlCore\XmlModels.pas`, `tests\XmlNative\XmlNative.dpr` |

## Before changing this format

1. Read [`../format-program.md`](../format-program.md),
   [`../xml-behavior.md`](../xml-behavior.md) and
   [`../xml-compatibility.md`](../xml-compatibility.md).
2. Run `tests\XmlCore` and `tests\XmlNative`
   (`powershell -File scripts\test.ps1 -Only XmlCore`, then `-Only XmlNative`).
3. Run `tests\TypeCoverage` through `scripts\run-type-coverage.ps1`.
4. Run `tests\ReaderContracts`, `tests\ConversionMatrix`,
   `tests\LosslessRouting` and `tests\Lifecycle`.
5. Do not change shared dynamic-model semantics (`TDynamicValue`, `TDynamicTag`,
   Core date and range helpers) from a format unit. Change Core deliberately,
   and retest every format.
6. A change to what XML writes needs a test that pins the text and a
   documentation change.
7. Run `scripts\validate-release.ps1` before calling it finished.
