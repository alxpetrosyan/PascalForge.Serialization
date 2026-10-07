# Avro behaviour

How the Avro engine maps Delphi values to and from Avro binary, as defined by
[Apache Avro 1.12](https://avro.apache.org/docs/1.12.0/specification/). This
document covers **Avro only**; see [`serializer-behavior.md`](serializer-behavior.md),
[`cbor-behavior.md`](cbor-behavior.md) and the other behaviour documents for
the rest.

Ownership is defined once, for every format, in
[`deserialization-ownership.md`](deserialization-ownership.md).

## Avro data is meaningless without its schema

This is not a caveat. It is the design of the format, and everything below
follows from it.

Avro binary contains **no type information at all**. A record is its fields
concatenated, with no names, no tags and no lengths. Two `long` fields are
sixteen bytes that could equally be one `bytes`. There is nothing in the
stream a reader could use to recover the shape — only the schema the writer
used.

So:

* every encode and decode here takes a `TAvroSchema` - `Serialize<T>` and
  `Deserialize<T>` generate theirs from the Delphi type;
* the registry handler declares the two **structural** capabilities only when
  a `TAvroSchema` is present in the conversion options, and
  `ESerializationSchemaRequired` is what a caller gets otherwise — not the
  capability error, because Avro *can* do this and would, given the schema;
* an object container file carries its own schema in its header, which is why
  that one entry point needs nothing extra.

```pascal
Schema := TAvroSerializer.SchemaFor<TCustomer>;        // caller owns it
try
  Data := TAvroSerializer.Serialize<TCustomer>(Customer);
  Back := TAvroSerializer.Deserialize<TCustomer>(Data);
finally
  Schema.Free;
end;

Json := TAvroSerializer.SchemaJsonFor<TCustomer>;      // publish this
```

## The encoding

### Varints are zig-zag

`int` and `long` are variable-length and **zig-zagged**: the value is mapped
to an unsigned number that keeps small magnitudes small in both directions,
`n -> (n shl 1) xor (n shr 63)`.

| Value | Bytes |
| --- | --- |
| `0` | `00` |
| `-1` | `01` |
| `1` | `02` |
| `-64` | `7f` |
| `64` | `80 01` |
| `High(Int64)` | `fe ff ff ff ff ff ff ff ff 01` |

The specification's own worked example is a record of one `long` = 27 and one
`string` = `"foo"`, which encodes as `36 06 66 6f 6f`. The test checks exactly
that.

### Every type the specification defines

| Avro | Encoding |
| --- | --- |
| `null` | zero bytes |
| `boolean` | one byte, `00` or `01` |
| `int`, `long` | zig-zag varint - an `int` is 32 bits, so a varint past that under an `int` schema is malformed and refused (`EAvroInputError`); a `long` is 64 |
| `float` | four bytes, little-endian IEEE 754 |
| `double` | eight bytes, little-endian IEEE 754 |
| `bytes` | a long length, then the bytes |
| `string` | a long length, then UTF-8 |
| `record` | its fields, in declared order, and nothing between them |
| `enum` | the **index** of the symbol, as an int |
| `array`, `map` | block encoding — see below |
| `union` | the branch **index** as a long, then the branch's own encoding |
| `fixed` | the bytes, with **no** length prefix — the schema says how many |

### Block encoding

An array or a map is a sequence of blocks. Each block is a count, then that
many items; a count of zero ends the sequence. A **negative** count means the
absolute number of items follows, preceded by a byte size for the block — which
is what lets a reader skip a block it does not want without decoding it.

Both forms are read. Writing uses one block and a terminating zero, which is
what the specification's simplest conforming writer does.

## Schema resolution

Avro's other defining feature: the reader's schema need not be the writer's.
Resolution is **mandatory**, not an extra — a reader always resolves, even
when the two schemas are identical.

```pascal
Value := TAvroSerializer.Decode(Data, WriterSchema, ReaderSchema);
Typed := TAvroSerializer.DeserializeWith<TCustomer>(Data, WriterSchema);
```

What resolves, per the specification:

* a field present in the reader and absent from the writer takes the reader's
  **default**; a field with no default fails, by name;
* a field present in the writer and absent from the reader is **skipped**,
  which requires decoding it and discarding it, because Avro has no lengths to
  jump over;
* fields are matched by **name**, then by the reader's **aliases**, so a
  renamed field still resolves;
* the numeric promotions the specification allows — `int` to `long`, `int` or
  `long` to `float`, and those to `double`, and `string` to `bytes` and back —
  and **only** those;
* a union branch resolves against the reader's branches;
* an enum symbol the reader does not know fails, unless the reader declares a
  default.

Anything else raises `EAvroResolutionError`, naming both schemas' view of the
field.

## Logical types

A logical type is an annotation on an underlying type. A reader that does not
know the annotation still reads the underlying value correctly, which is the
whole point of the mechanism.

| Logical type | Underlying | Delphi |
| --- | --- | --- |
| `decimal` | `bytes` or `fixed`, with `precision` and `scale` | exact decimal text |
| `uuid` | `string` | `TGUID` |
| `date` | `int` — days since the epoch | `TDate` |
| `time-millis`, `time-micros` | `int`, `long` | `TTime` |
| `timestamp-millis`, `timestamp-micros` | `long` | `TDateTime` |
| `local-timestamp-millis`, `local-timestamp-micros` | `long` | `TDateTime` |
| `duration` | `fixed(12)` — months, days, milliseconds | `TAvroValue.NewDuration` |

An instant before 1899-12-30 with a time of day is written as the instant it
states. A `TDateTime` or `TDate` outside the years 1 to 9999 is refused on
write (`ESerializationUnsupported`, naming the member path), and a `date` or
timestamp datum outside them on read (`EAvroInputError`). In structural
conversion, an integer headed for a temporal field is the raw count the
logical type is defined over - days, milliseconds or microseconds - carried
exactly.

**`decimal` is exact.** It is held as an unscaled big-endian integer plus a
scale, and converted to and from decimal *text*, never through a `Double`.
That is the point of having it: a `Double` destroys a decimal silently, which
is the failure this library exists to prevent.

An annotation this library does not recognise is **kept** and written back
unchanged, because the specification says a reader must fall back to the
underlying type rather than fail.

## Object container files

A self-contained file: a header holding the schema and the codec, a sync
marker, and then blocks of records.

```pascal
Data   := TAvroSerializer.WriteContainer<TCustomer>(Customers, TAvroCodec.Deflate);
People := TAvroSerializer.ReadContainer<TCustomer>(Data);
```

`TAvroCodec` is `Null` or `Deflate`. The specification **requires** null and
**names** deflate; both are here.

### A compressed block is bounded while it decompresses

A few kilobytes of deflate can claim gigabytes. The reader inflates a block
64 KB at a time and checks a budget **before** keeping each chunk, so a
hostile block stops at the budget instead of after full expansion. The
default is 64 MiB per block (`TAvroReadOptions.DefaultMaxInflatedBlockBytes`),
far above what real writers flush. A known producer of larger blocks raises it
per call:

```pascal
Options := TAvroReadOptions.Default.WithMaxInflatedBlockBytes(256 * 1024 * 1024);
Rows    := TAvroSerializer.ReadContainer(Data, nil, Options, WriterSchemaJson);
People  := TAvroSerializer.ReadContainer<TCustomer>(Data, Options);
```

Past the budget the read raises `EAvroInputError` naming the limit. The
overloads without options use the default.

### The sync marker is derived, not random

The specification asks for a random 16-byte marker. This library derives it
from the schema **fingerprint** instead, so that writing the same data twice
produces the same file.

The marker's only job is to be a byte sequence unlikely to occur in the data,
and a derived one does that job. A reproducible build is worth more here than
unpredictability, and the deviation is recorded rather than hidden. A file
written this way is read correctly by any conforming reader, because a reader
takes the marker from the header.

## The schema model

`TAvroSchema` is a `TSerializationSchema`, so it travels in conversion
options.

```pascal
Schema := TAvroSchema.Parse(JsonText);
Json   := Schema.ToJson;
Canon  := Schema.CanonicalForm;     // the specification's Parsing Canonical Form
Print  := Schema.Fingerprint;       // 64-bit Rabin, per the specification
```

`TAvroType` covers `null`, `boolean`, `int`, `long`, `float`, `double`,
`bytes`, `string`, `record`, `enum`, `array`, `map`, `union` and `fixed`.
Named types, references to named types, aliases, documentation, field order
and defaults are all parsed and all written back.

## The Delphi contract

| Delphi | Avro, by default |
| --- | --- |
| `Boolean` | `boolean` |
| integers up to 32 bits | `int` |
| `Int64`, `UInt64` | `long` |
| `Single` | `float` |
| `Double`, `Extended` | `double` |
| `Currency` | `decimal` with scale 4 — exact |
| `string` | `string` |
| `TBytes` | `bytes` |
| `TDateTime` | `timestamp-millis` |
| `TDate` | `date` |
| `TTime` | `time-millis` |
| `TGUID` | `uuid` |
| an enumeration | `enum`, its symbols the member names |
| a set | an `array` of its `enum` - Avro's idiom for "some of these" |
| a class | `["null", record]` |
| a record | `record` |
| a list | `["null", array]` |
| a dynamic or static array | `array` |
| a dictionary | `["null", map]` |
| `TNullable<T>` | `["null", T]` — a union, which is how Avro spells optional |

**A container member is a union with null, like any other class member.**
A Delphi container is an object reference and `nil` is a state it really
has: a nil `TObjectDictionary` is not an empty one, and a schema with no
null branch cannot tell the two apart. Without the null branch a nil list
went out as an empty array and came back as an empty list — silently, which
is the kind of loss that only ever shows up as a customer's missing
section.

**A named type gets an explicit namespace, and is referenced by its full
name.** An enum defined inside one record and used again inside another is
written once and referenced by name afterwards, which is what Avro requires
and what makes a recursive type expressible at all. A *bare* name resolves
against the enclosing namespace, so when the two records come from
different units — which is every real model — a short reference resolved to
a name nothing had defined and the schema this library had just written
would not parse. Every named definition now carries its own `namespace` and
every reference is the full name.

`TNullable<T>` is the one mapping worth dwelling on. Avro has no notion of an
absent field; a field is always present and always has a value. Optionality is
a **union with null**, and that is what this engine emits — so an Avro consumer
sees exactly the idiom it expects.

### Attributes

```pascal
type
  TCustomer = class
  public
    [AvroName('customer_id')] Id: Int64;
    [AvroIgnore] Scratch: string;
    [AvroAliases('name,full_name')] DisplayName: string;
    [AvroSerializer(TMyMoneySerializer)] Odd: TMoney;
  end;
```

| Attribute | Meaning |
| --- | --- |
| `AvroName` | the field name in the schema |
| `AvroIgnore` | not in the schema, never written, never read |
| `AvroAliases` | the names this field also answers to during resolution |
| `AvroSerializer` | a `TCustomAvroValueSerializer` descendant, which also supplies its own `SchemaJson` |

## Structural conversion

Avro declares `ContractSerialize` and `ContractDeserialize` always, and the
two structural capabilities **only when a `TAvroSchema` is in the options**:

```pascal
Payload := TSerialization.Convert(Source, TSerializationFormat.Json,
             TSerializationFormat.Avro,
             TStructuralConversionProfile.Natural, Schema);
```

With the schema supplied, Avro takes part in the conversion ring like any
other format. Without it, `TSerialization.StructuralFormats` does not list
Avro at all, and asking anyway raises `ESerializationSchemaRequired` with the
sentence that says what to bring.

A `decimal` crosses as `TDynamicKind.Decimal`, held as exact decimal text, so
it survives into any destination that has a decimal and refuses honestly into
one that does not.

Writing a tree into Avro, the profile decides three things the schema cannot
(the full rules are in [`formats/avro.md`](formats/avro.md)):

| | `Natural` | `Strict` and `Lossless` |
| --- | --- | --- |
| a member the schema does not name | omitted | refused, with its path |
| a `Double` into `decimal` that is not exactly such a decimal | the shortest text that reads back as the same double | refused |
| a union value two branches hold equally well | the first in declaration order | refused, naming both |

A union branch is always chosen by what the value is - `int` for an integer
that fits in 32 bits, `long` for one that does not, `string` for text -
never because it comes first, and a value no branch holds is refused in
every profile.

## What is proven, and how

`tests/AvroNative` runs **166 checks** against the 1.12 specification.

The independent reference is the specification's own worked example —
`36 06 66 6f 6f` — plus the varint table, which can be computed by hand from
the zig-zag rule.

The ledger it prints covers every type above, block encoding for arrays and
maps, union branch indices, `fixed` having no length prefix, schema JSON
parsing, named types and references, aliases, defaults, the whole of schema
resolution, `decimal`, `uuid`, `date`, `time`, `timestamp` and `duration`
logical types, an unknown annotation being kept, object container files, and
both codecs.

## Not implemented, and why

* **The snappy, bzip2, xz and zstandard container codecs.** The specification
  requires null and names deflate; the rest need third-party libraries. A file
  written with one of them is **refused by name** rather than read as garbage.
* **Avro JSON encoding**, as opposed to the binary one. It is a separate
  encoding in the same specification, and nothing in this library needs it —
  a JSON document is what `PascalForge.Json` is for.
* **Protocols, messages and RPC.** That is the other half of the
  specification and it is not serialization.
* **A random sync marker.** Derived from the schema fingerprint instead, for
  reproducible output. See above.
