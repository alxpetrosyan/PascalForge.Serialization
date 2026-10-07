# Known limitations

The real, current limitations of the library, and nothing else. What is
refused on purpose, type by type, is in [`expected-refusals.md`](expected-refusals.md).

Each entry says **what** the limitation is, **why** it exists, **where** it
applies, the **workaround**, and whether anything is **planned**.

---

## Types and RTTI

**A type declared inside a routine has no usable RTTI.**
*Why:* Delphi emits no extended RTTI for a class or record declared in a
procedure body. *Where:* every format. *Workaround:* declare it at unit
scope. The library names the type in the error rather than building an
empty plan. *Planned:* no - it is the compiler's.

**An inline static array and a variant record are refused.**
*Why:* the compiler records no type for the first, and nothing says which
alternative of the second is live. *Where:* every format. *Workaround:*
declare a named array type (which is carried), or register a type serializer.
*Planned:* no.

**`TBcd` needs a custom serializer.**
*Why:* `TBcd.Fraction` is an inline array with no RTTI, so the digits cannot
be read safely by reflection. *Where:* every format. *Workaround:* a type
serializer that writes `BcdToStr` and reads `StrToBcd`. *Planned:* a
built-in converter would be a new capability; not in this release.

**`Extended` is carried at `Double` precision on Win32.**
*Why:* Win32's `Extended` has ten bytes and no format here has an 80-bit
float. *Where:* every format. An `Extended` beyond `Double`'s range (1e400)
becomes infinity in every format that has one; JSON, which has none, refuses
it. *Workaround:* keep the value in `Currency` or text if the extra digits or
the range matter. *Planned:* no.

**A multi-dimensional static array is written flat.**
*Why:* RTTI does not record the length of each dimension of an anonymous
index type, so the elements are written in storage order. *Where:* every
format; the Delphi type still gives the shape back on read, but another
reader sees one flat list. A named inner array type does not help: Delphi
folds `array[0..1] of TRow5` into one array type of ten elements.
*Workaround:* an array of a record that wraps the inner array
(`array[0..1] of TRow` where `TRow = record Cells: TRow5; end`), or a type
serializer. *Planned:* no.

**A `Variant` is carried as its value and family, not its exact `VarType`.**
*Why:* formats have one integer type, one real type, one text type. A
`varSmallint` comes back as the narrowest integer that holds it; `varSingle`
as `Double`. *Where:* JSON, BSON, CBOR, MessagePack, YAML; the other formats
refuse Variants. *Workaround:* a declared member type. *Planned:* no.

**A record's declaring unit is not recoverable from RTTI.**
*Why:* `TTypeData` carries a unit name for classes but not records. *Where:*
name- and unit-scoped registrations for a record declared in an
implementation section. *Workaround:*
`TJsonSerializer.RegisterTypeUnit(TypeInfo(TRec), 'MyUnit')`, or register by
`TypeInfo` from inside the unit. *Planned:* no.

**A closed generic record has no declaring unit at all.**
*Why:* `QualifiedName` raises `ENonPublicType` for `TNullable<Integer>`, and
a specialisation does not point back at its generic. *Where:* nullable
families. *Workaround:* families are recognised by base name, arity and field
layout; see [`nullable-families.md`](nullable-families.md). *Planned:* no.

---

## Graphs and ownership

**A value nested more than 64 levels deep is refused on write.**
Each object, record, static or dynamic array, list, dictionary and `Variant`
array counts one level, the root included, so a tree whose nodes hold their
children in a `TObjectList` reaches 32 generations. *Why:* every writer
recurses. A thousand-object linked list or a recursive record overflowed the
stack, and values far shallower produced documents deeper than the formats'
own readers accept. *Where:* every format; `ESerializationLimitExceeded`.
*Workaround:* hold a long chain as a list, or register a type serializer that
writes it as one. *Planned:* no - 64 is the same default .NET chose.

**Object identity is not preserved.** *Why:* no format here has a
back-reference. A child shared by two parents is written twice; a cycle is
refused. *Where:* every format. *Workaround:* write keys, not references;
JSON can write a back-reference as null with
`TJsonRecursiveReferencePolicy.WriteNull`. *Planned:* no.

**Ownership cannot be inferred from an arbitrary `TObject` reference.**
*Why:* nothing in RTTI tells an owned child from a borrowed one. *Where:*
every format. Consequently a document's `null` DETACHES a member and never
frees it, and a custom serializer that returns a different instance owns the
old one's disposal. *Workaround:* none needed for correctness; free a
detached owned child yourself. See
[`deserialization-ownership.md`](deserialization-ownership.md). *Planned:* no
- a leak is recoverable, a dangling pointer is not.

**An array member is replaced, not refilled.** *Why:* an array has no owner
to ask, so nothing tells whether the objects a constructor put in a
`TArray<TItem>` or an `array[0..1] of TItem` belong to the class. The reader
builds a new array and assigns it; the objects the old one held are not
freed. Protobuf appends to a dynamic array instead, which is the protobuf
merge of a repeated field. *Where:* arrays of objects, every format; a list,
a dictionary, a record and an object member are refilled in place.
*Workaround:* hold owned children in a `TObjectList<T>`, or leave the array
empty in the constructor. *Planned:* no.

**BSON and MessagePack do not read into a read-only property.** *Why:* their
readers skip a member with no setter, including one that returns an object
the class owns - a `TList<T>` or `TDictionary<K, V>` exposed as
`property Items: TList<T> read FItems`. JSON, XML, YAML, CBOR and Dynamic
fill such an object in place. *Where:* BSON and MessagePack readers; writing
is unaffected. *Workaround:* expose the container as a public field or give
the property a setter. *Planned:* possible - filling a read-only property's
object in place, as the other readers do.

**An in-place merge is not atomic.** *Why:* `Populate` fills the caller's
instance as it reads. *Where:* every format's `Populate`. A failure half way
leaves the members read so far; nothing is freed or left dangling.
*Workaround:* deserialize into a new instance and swap. *Planned:* no.

**Protobuf: a `oneof` member that is an object is detached, not freed, when a
sibling arrives.** *Why:* the rule above - the reader cannot prove it owns
what the member held. *Where:* Protobuf messages with object members in a
oneof. *Workaround:* free it in the message's own setter, or keep oneof
members scalar. *Planned:* no.

**CSV: under `CollectionMode.JsonCell` a container member is replaced, not
refilled - and so is a nested object or record under
`NestedObjectMode.JsonCell`.** *Why:* the cell is read through the JSON
format by the registry, which has no populate operation. *Where:* CSV
`JsonCell` only; every other mode, and every other format, refills the
existing member. *Workaround:* leave the member nil in the constructor, or
use another mode. *Planned:* possible, with a populate operation on the
registry.

---

## Configuration

**Configuration is process-global.** *Why:* one registration set per format
per process keeps plans cacheable. *Where:* every format. *Workaround:* none;
two independent configurations in one process are not supported. *Planned:*
not in this release.

**Freezing is one-way, and plans live for the process.** *Why:* a plan built
before a registration would silently disagree with one built after it.
*Where:* every format that caches plans (JSON, XML, BSON, Protobuf,
MessagePack, CSV). *Workaround:* register at startup, then
`FreezeConfiguration`. *Planned:* no.

**CBOR, YAML, Avro and ASN.1 build no plan of their own.** They take each
type's member list from the shared metadata cache - discovered once per type,
as for every engine - but read each member's format attributes, custom
serializer and representation per value rather than from a cached plan.
*Why:* they were built without a plan cache. *Where:* performance only - the
behaviour is the same. *Workaround:* none needed. *Planned:* a cache, if a
benchmark shows the need.

---

## What each format writes

**JSON has no NaN and no infinity.** *Why:* RFC 8259 has no such numbers.
*Where:* the JSON contract refuses them by name. *Workaround:* a custom
serializer; structural conversion under `Lossless` writes Extended JSON's
`$numberDouble`. *Planned:* no.

**JSON reads no polymorphic discriminator.** *Why:* no reader consults a
type discriminator; a nil member is built as its declared class. *Where:*
JSON.
*Workaround:* a custom serializer, or an existing instance of the descendant
(which is reused). *Planned:* not in this release.

**A JSON, BSON and CSV set is a comma-joined string**, XML's space-separated,
the binary formats' an array. *Why:* each format's established convention;
changing one would break its readers. *Where:* as listed. *Workaround:* a
custom serializer for a different spelling. *Planned:* no.

**GUID text is fixed in JSON and XML** - unbraced, lower case. BSON is
configurable (binary subtype 4, or a string). *Planned:* not in this release.

**JSON member names are camelCase or snake_case.** `TJsonNaming` has
`DefaultStyle` and `SnakeCase`, per unit or class, and `[JsonName]` per
member; there is no "as declared" style. *Planned:* not in this release.

**`UInt64` above `High(Int64)` is refused by BSON and Avro.** *Why:* neither
has an unsigned 64-bit integer. *Workaround:* a custom serializer writing
decimal128 or text. *Planned:* no.

**XML cannot hold U+0000, other C0 control characters, or an unpaired UTF-16
surrogate.** *Why:* XML 1.0 has no representation for them, literal or
escaped. *Workaround:* base64 the value. *Planned:* no.

**`TDateTime` carries no zone.** *Why:* the type has none. It is written
without an offset by every format. Text with an offset is read three ways,
by format: JSON, YAML and CBOR (tag 0) read it as the instant it states,
normalised to UTC; XML and the ISO text of BSON and MessagePack take the
wall-clock fields as written and ignore the offset; CSV refuses it. *Where:*
every text form; the binary formats' native instants (BSON datetime,
Protobuf Timestamp, CBOR tag 1, MessagePack timestamp) are UTC by
definition. See [`datetime-policies.md`](datetime-policies.md).

---

## XML, the standard

XML 1.0 Fifth Edition and Namespaces 1.0 Third Edition, non-validating, with
external entity resolution disabled. Its exclusions are complete:

- **Not a validating processor.** `<!ELEMENT>`, `<!ATTLIST>` and
  `<!NOTATION>` are parsed and ignored.
- **External entities are refused, by name.** There is no code in the reader
  that can open a file or a socket.
- **Parameter entities are refused, by name.**
- **Canonical XML (C14N) is not implemented.** Output is deterministic, which
  is a weaker statement.

Limits: elements nest at most 512 deep; entity expansion is capped at 8 MB
and 32 levels. See [`xml-compatibility.md`](xml-compatibility.md).

## BSON, the standard

Every element type the specification defines is read and written. What is
limited is the Delphi mapping: **decimal128 is carried, not interpreted**
(Delphi has no 128-bit decimal); **a BSON timestamp is a `UInt64`**, not a
`TDateTime`; **regular expressions, JavaScript, symbols, DBPointers, min/max
keys and undefined** are reachable through `TBsonValue`
(`TBsonSerializer.ParseDocument`), not as member types. Documents nest at most
512 deep, read or written (`WriteDocument` refuses a deeper tree). A
`TBsonValue` tree a caller builds by hand much deeper than that - around 800
levels - overflows the stack when it is freed. The independent reference is
the specification's byte vectors, the bson-corpus `subtype 0x04 UUID` vector
among them; no second implementation was available offline. See
[`bson-compatibility.md`](bson-compatibility.md).

## Protobuf, the standard

The encoding is complete. What is not here is the `.proto` **language**:
**no `.proto` parser and no code generator** - the schema is the Delphi type
with `[ProtoField(n)]` on every member, or a protoc descriptor set for
structural conversion; **nothing checks that your field numbers agree with a
`.proto`**; **extensions and `Any`** arrive as unknown fields, kept only if
the message declares a `[ProtoUnknown] TBytes` store; **groups are read,
never written**; **only `google.protobuf.Timestamp` has a meaning** among the
well-known types. Messages nest at most 100 deep, as in the reference
implementation. An `int32` or `uint32` field keeps the low 32 bits of a wider
varint, as the specification says, so the range check into the member sees
the cast value; see [`protobuf-behavior.md`](protobuf-behavior.md).
See [`protobuf-compatibility.md`](protobuf-compatibility.md)
and [`protobuf-descriptors.md`](protobuf-descriptors.md).

## CBOR, the standard

**CBOR sequences (RFC 8742) are one document per call.** **COSE, CDDL and
CBOR patching are not implemented.** **There is no diagnostic-notation
parser** - `TCborValue.ToDiagnostic` writes section 8 notation, nothing reads
it. Documents nest at most 256 deep by default (`TCborDecodeOptions`).

## MessagePack, the standard

**The pre-2013 raw family is read as `str`**, which is what it means in the
current specification: a document that used it for binary fails UTF-8
validation rather than producing mojibake.

## YAML, the standard

**The 1.1 schema is not implemented and will not be**: `yes` and `on` are
strings, `012` is twelve. **Merge keys (`<<`) are not supported.** **Anchors
are not emitted for shared Delphi instances** - reading an anchored document
works; producing one from object identity does not. Nesting is limited by
`TYamlLimits.MaxDepth` (200) and alias expansion by
`TYamlLimits.MaxExpandedNodes`.

## CSV, the tabular problem

**A map has no honest column layout** - refused unless
`NestedObjectMode.JsonCell`. **A collection is refused by default** -
`CollectionMode` offers four ways, and `Error` is the default because
guessing is worse. **Two collections under `RepeatedRows` are refused** unless
`CartesianProduct` is asked for. **One payload holds one table**;
**`DeserializeTables` reads the root table only**; **`RepeatedRows` works at
the top level only**; **a DataSet packet under `StructureAndRows`** is an
object of two arrays and cannot be ONE table - through
`TCsvSerializer.TablesFrom` with `SeparateTable` it is two, `fields` and
`rows`, as any such object is.

## Avro, the standard

**The snappy, bzip2, xz and zstandard codecs are not implemented** - null and
deflate are; a file with another codec is refused by name. **Avro's JSON
encoding, protocols and RPC are not implemented.** **A bare datum carries no
types**: read with a schema other than its writer's, it is detected only when
the byte count disagrees - use `DeserializeWith` with the writer's schema, or
an object container file, which carries it. **The container sync marker is
derived from the schema fingerprint**, not random, for reproducible output.
Datums nest at most 512 deep. A compressed container block is bounded while
it decompresses: 64 MiB by default, `TAvroReadOptions.MaxInflatedBlockBytes`
to change it. The writer flushes blocks at about 1 MiB, so that limit never
stands between a default write and a default read; the one exception, a
single datum encoding past 64 MiB, is refused under deflate on write and
needs the null codec.

## ASN.1, the standard

**PER, OER, XER and JER are not implemented** - this is X.690 (BER, DER,
CER). **The X.681-683 information-object layer, parameterized types,
`ANY DEFINED BY` and constraint algebra are not implemented**; the module
parser names each one it meets. A structural conversion through the
registry names the type of a multi-assignment module in an ASN.1 context:
`Schema.ForType('Shipment')`. Documents nest at most 256 deep.
**An implicitly tagged primitive component reads back as raw bytes** in a
structural conversion - every component under `IMPLICIT TAGS` or
`AUTOMATIC TAGS`: the reader does not map the implicit tag back to the
schema type. Writing such a tree back is refused, not corrupted.
*Workaround:* `EXPLICIT TAGS`, or contract-aware conversion through a Delphi
type. *Planned:* yes. A CHOICE itself round-trips; see
[`formats/asn1.md`](formats/asn1.md).

---

## Structural conversion

**`Natural` does not round-trip types through XML** - element text has no
type, so `{"id":7}` comes back as `{"id":"7"}`. `Lossless` uses the W3C
JSON/XML mapping; contract-aware conversion avoids the question.
**`Lossless` does not keep XML's attribute/element distinction**, and
`Natural` keeps it but loses the kinds. **`Natural` does not round-trip a
member name XML cannot spell**, because a reader cannot tell an encoded name
from a real one; `TXmlNameCodec.DecodeName` is there for a caller who knows.
**An empty list through XML under `Natural`** comes back as an empty string.
**Nothing infers a type from the spelling of a string**, in any profile. **No
member is ever dropped**: there is no `Skip` policy, and none is planned. See
[`conversion.md`](conversion.md).

## Dynamic

**Member names are text**: a CBOR or MessagePack map key that is not text
becomes its diagnostic text under `Natural` and is refused under `Strict`
and `Lossless` - there is no non-string-keyed map kind. **A name appears
once in an object**: a source document with a repeated member name is
refused rather than read with one occurrence silently winning. **A tree has
no back-references**: projecting a Delphi graph with a cycle is refused, as
in every format. **A dictionary becomes an object only when its keys have
one exact text form** (string, integer, enumeration). **`Obj.Append(Value)`
without a name needs the value to project to an object.** **Protobuf's
dynamic entry points are on `TProtobufSchema`**, not `TProtobufSerializer`:
reading a message needs its descriptors, and the facade unit cannot name
the schema unit. **An implicitly tagged ASN.1 primitive reads back as its
raw octets** structurally, as before. **A DataSet stores an enumeration as an
integer field**, so `[SerializationEnum]` does not reach a DataSet column.
See [`dynamic.md`](dynamic.md) and [`attributes.md`](attributes.md).

## Text and encoding

**UTF-8 is the only encoding offered**, and no BOM is written; a leading BOM
on input is skipped. **Unicode normalisation is never applied.** A
`TJsonUnicodeEscapePolicy` is per operation, never global. See
[`unicode-and-utf8.md`](unicode-and-utf8.md).

## DataSet

**Schema inference keeps what the source format states and invents nothing**:
from JSON a `Currency` or BCD column is `ftFloat`, a GUID or a date is
`ftWideString`, and width is lost; from XML every column is `ftWideString`;
BSON keeps int64, datetime and binary. Supply the contract
(`CreateFDMemTable<T>(Source, Format)`) for Delphi semantics, or use
`StructureAndRows` for an exact round trip. **A column null in every row**
cannot be typed and falls back to `ftWideString`; **empty rows** yield no
schema. **A member declared exactly `TDataSet`** is built as a `TFDMemTable`
(or whatever `TDataSetJsonIntegration.DataSetFactory` returns) when nil.
**`PascalForge.DataSet` requires FireDAC**; the format units do not, and
`scripts\check-dependencies.ps1` proves it. **A delta whose packet carries a
schema rebuilds the DataSet's fields.** See
[`dataset-projection.md`](dataset-projection.md).
