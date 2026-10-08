# Avro

## Purpose

This is the entry point for the Apache Avro format. It summarizes what the
format does and where the code is. For depth, read
[`../avro-behavior.md`](../avro-behavior.md). The API is in
[`../api-reference.md`](../api-reference.md).

Avro is a real engine. A Delphi value is written straight to Avro binary and
read straight back. Nothing goes through JSON text or another format on the
contract path. The natural payload type is `TBytes`.

Avro is schema-driven. A datum carries no type information: no tags, no
field names, and no lengths except the ones the types imply. The same bytes
are a record, two longs or a string, depending on the schema they are read
with. So every read needs the schema the writer used.

## Standard/profile

- **Apache Avro specification 1.12.0**
  (<https://avro.apache.org/docs/1.12.0/specification/>).
- The binary encoding of a single datum, in both directions: zig-zag
  varints, little-endian `float` and `double`, length-prefixed `bytes` and
  `string`, records, enums by index, unions by branch index, `fixed` with no
  length prefix, and block encoding for arrays and maps (negative block
  counts with a byte size are read; one block and a terminating zero are
  written).
- The schema language: named types and references to them, namespaces,
  aliases, documentation, field order, defaults and logical types.
- Schema resolution, always applied on read: numeric promotion, reader
  defaults, skipped writer fields, aliases, branch-wise union resolution and
  the enum default.
- Object container files with the `null` and `deflate` codecs.
- Parsing Canonical Form and the 64-bit Rabin fingerprint.

Not implemented: the `snappy`, `bzip2`, `xz` and `zstandard` codecs (a file
using one is refused by name), the JSON encoding of data, single-object
encoding and schema-registry framings, and protocols and RPC. The container
sync marker is derived from the schema fingerprint, not random, so the same
data gives the same file.

## Public facade

Unit `PascalForge.Avro`, class `TAvroSerializer`. All methods are class
static. The schema model is in `PascalForge.Avro.Schema`.

| Method | Signature |
| --- | --- |
| `SchemaFor<T>` | `: TAvroSchema`; a fresh tree the caller owns and frees |
| `SchemaJsonFor<T>` | `: string` |
| `Serialize<T>` | `(const AValue: T): TBytes` |
| `Deserialize<T>` | `(const AData: TBytes): T` |
| `Populate<T>` | `(const AInstance: T; const AData: TBytes)` |
| `DeserializeWith<T>` | `(const AData: TBytes; AWriter: TAvroSchema): T`; resolves the writer's schema against `T`'s |
| `Encode` | `(ASchema: TAvroSchema; AValue: TAvroValue): TBytes` |
| `Decode` | `(const ABytes: TBytes; AWriter: TAvroSchema): TAvroValue`, and `(ABytes; AWriter, AReader: TAvroSchema)`; the caller owns the result |
| `WriteContainer` | `(ASchema: TAvroSchema; const AValues: array of TAvroValue; ACodec: TAvroCodec = TAvroCodec.Null): TBytes` |
| `ReadContainer` | `(const AData: TBytes; out AWriterSchemaJson: string): TObjectList<TAvroValue>`, and with `AReader: TAvroSchema`; the caller owns the list |
| `WriteContainer<T>` | `(const AValues: array of T; ACodec: TAvroCodec = TAvroCodec.Null): TBytes` |
| `ReadContainer<T>` | `(const AData: TBytes): TArray<T>` |
| `From<T>` | contract-aware: `(ASource: string / TBytes / TSerializationPayload; AFrom: TSerializationFormat): TBytes` |
| `ToDynamic` / `FromDynamic` | `(const AData: TBytes; AWriter: TAvroSchema; AReader: TAvroSchema = nil): TDynamicValue` / `(AValue: TDynamicValue; ASchema: TAvroSchema): TBytes`, also with `TStructuralConversionOptions`; the schema is required - see [`../dynamic.md`](../dynamic.md) |

`[SerializationName]` and `[SerializationIgnore]` apply; `[AvroName]` and `[AvroIgnore]` beat them for Avro. `[SerializationEnum]` does **not** change Avro enum symbols, which are schema identifiers - `RegisterEnumMapping` on `TAvroSerializer` is the way to. See [`../attributes.md`](../attributes.md).

There is no non-generic `From`: a structural Avro payload needs a schema,
and that signature has nowhere to put one. Use `TSerialization.Convert` with
a schema (see Schema/context).

Configuration (call at startup):

- `RegisterTypeSerializer<T>(ASerializerClass: TAvroValueSerializerClass)`
- `RegisterEnumMapping<T>(const ASymbols: array of string)`
- `FreezeConfiguration`, `IsFrozen`, `ResetConfiguration` (for tests)

Configuration freezes automatically at the first real serializer operation
(`Serialize`, `Deserialize`, `Populate`, `DeserializeWith`, or the
registry's typed calls). After that, configuration is immutable and
concurrent use is safe. A registration made after the freeze raises
`EAvroInternalError` saying the configuration is frozen.
`FreezeConfiguration` freezes earlier, and `IsFrozen` reports the state. See
[`../configuration-lifecycle.md`](../configuration-lifecycle.md) for the full
lifecycle.

Exceptions: `EAvroError`, `EAvroInputError` (the bytes or the datum are at
fault), `EAvroInternalError` (model or configuration), `EAvroResolutionError`
(descends from `EAvroInputError`: the writer's and reader's schemas cannot be
reconciled), and `EAvroSchemaError` (in `PascalForge.Avro.Schema`: the schema
JSON is at fault).

## Explicit registry registration

```pascal
uses
  PascalForge.Avro.Registration;
...
TAvroSerializationRegistration.RegisterFormat;
```

- Linking or importing `PascalForge.Avro.Registration` does **not** register
  the format.
- Loading the `PascalForge.Serialization.Runtime` package does
  **not** register it.
- `RegisterFormat` is idempotent. It raises `ESerializationFormatConflict`
  if a different handler already holds `TSerializationFormat.Avro`.
- `UnregisterFormat` is safe when the format is absent, and never removes
  another unit's handler.
- `IsRegistered` reports whether this unit's handler holds the format.

Direct `TAvroSerializer` use needs no registration, and neither does parsing
a `TAvroSchema`. Registration is needed only for `TSerialization` (format
chosen at run time), `TSerialization.Convert`, and the `TDataSetSerializer`
overloads that take a `TSerializationFormat`.

All formats at once: `TSerializationFormatsRegistration.RegisterAll` in unit
`PascalForge.Serialization.AllFormats`. It is also explicit.

Registry mutation happens at startup and shutdown. It must not run
concurrently with serialization.

## Native Delphi mappings

The contract path generates the schema from the Delphi type
(`SchemaFor<T>`); publish `SchemaJsonFor<T>` beside the bytes.

| Delphi | Avro, by default |
| --- | --- |
| `Boolean` | `boolean` |
| signed integers up to 32 bits, `Byte`, `Word` | `int` |
| `Cardinal` | `long` (an `int` is 32 bits signed) |
| `Int64`, `UInt64`, `Comp` | `long` |
| `Single` | `float` |
| `Double`, `Extended` | `double` |
| `Currency` | `bytes`, `decimal` precision 19, scale 4 (exact) |
| `string` | `string` (UTF-8) |
| `TBytes` | `bytes` |
| `TDateTime` | `long`, `timestamp-millis` |
| `TDate` | `int`, `date` |
| `TTime` | `int`, `time-millis` |
| `TGUID` | `string`, `uuid` |
| enumeration | `enum`, the member names (or `RegisterEnumMapping`) |
| set | `array` of its `enum` (`array` of `int` for a non-enumeration set) |
| record | `record` |
| class member | `["null", record]` |
| dynamic or static array | `array` |
| list | `["null", array]` |
| dictionary | `["null", map]`; keys must have one text form |
| `TNullable<T>` | `["null", T]`, null first |

Named types carry an explicit namespace and are referenced by full name.
Member attributes: `AvroName`, `AvroIgnore`, `AvroAliases` (one
comma-separated string: `[AvroAliases('emailAddress, email_address')]`),
`AvroSerializer`.

Integers:

- An `int` is 32 bits. An `int` datum whose varint decodes past that is
  refused on read (`EAvroInputError`), never narrowed. A `long` value in a
  union goes to the `long` branch when an `int` cannot hold it. An `int`
  default past 32 bits is refused (`EAvroResolutionError`).
- A `UInt64` above `High(Int64)` is refused on write: an Avro `long` is
  signed.

Logical types: `decimal` (exact, held as decimal text, never a `Double`),
`uuid`, `date`, `time-millis`, `time-micros`, `timestamp-millis`,
`timestamp-micros`, `local-timestamp-millis`, `local-timestamp-micros`,
`duration` (`TAvroValue.NewDuration`). An annotation this library does not
know is kept and written back, and the underlying type is read.

Dates and text:

- An instant before 1899-12-30 with a time of day is written as the instant
  it states.
- A `TDateTime` or `TDate` outside the years 1 to 9999 is refused on write
  (`ESerializationUnsupported`, naming the member path). A `date` or
  timestamp datum outside them is refused on read (`EAvroInputError`).
- A string with an unpaired UTF-16 surrogate is refused on write
  (`ESerializationUnsupported`), because UTF-8 cannot encode it. Invalid
  UTF-8 is refused on read.

Full detail: [`../avro-behavior.md`](../avro-behavior.md),
[`../datetime-policies.md`](../datetime-policies.md),
[`../delphi-type-coverage.md`](../delphi-type-coverage.md).

## Structural representation

Only with a schema. The handler declares `ContractSerialize` and
`ContractDeserialize` always, and `StructuralParse` and `StructuralWrite`
only when the conversion options hold a `TAvroSchema` or a
`TAvroSerializationContext`. Reading decodes to `TAvroValue` and maps it to
`TDynamicValue` (`TAvroEngine.AvroToDynamic`); writing goes back through
`TAvroEngine.DynamicToAvro`.

| Avro | `TDynamicValue` |
| --- | --- |
| `int`, `long` | `Int` |
| `float`, `double` | `Float` |
| `bytes`, `fixed` | `Bytes` |
| `string`, `enum` | `Str` (the symbol for an enum) |
| `boolean`, `null` | `Bool`, `Null` |
| `decimal` | `Decimal` (exact text) |
| `date` | `Date` |
| `time-millis`, `time-micros` | `Time` |
| `timestamp-*`, `local-timestamp-*` | `DateTime` |
| `duration` | `Obj` of `months`, `days`, `millis` |
| `record`, `map` | `Obj`, fields in declared order |
| `array` | `Arr` |
| union | the branch's value |

On the way back, the schema decides every type. A record field the tree
lacks takes null when its type is a union with null, otherwise the field's
default, otherwise it is refused by name. A structural `Int` under a
temporal logical type is the raw unit count the type is defined over (days,
milliseconds or microseconds), carried exactly; text there is parsed as an
ISO date or time. A null where the schema has no null branch is refused.

**A union branch is chosen by what the value is, never by coming first.**
Each branch is ranked: the value's own Avro type first (`int` for an
integer that fits in 32 bits, `long` for one that does not, `string` for
text, `double` for a float, `bytes` for binary, a record that names every
member); then a wider type of the same family (`long` for a small integer, a
`float` that holds the double exactly, a `map` for an object, an `enum`
whose symbol the text is); then a form the schema sanctions (text or a raw
count under a temporal logical type, an integer or decimal text into a
`decimal`). The best rank wins. A value no branch can hold is refused in
every profile (`EStructuralConversionError`, `UnsupportedValueKind`). When
two branches tie at the best rank - four bytes into
`["null", fixed(4), "bytes"]` - `Natural` takes the first in declaration
order and `Strict` and `Lossless` refuse, naming both.

**A `decimal` is written only from what is decimal.** A dynamic `Decimal`,
an integer and text in plain decimal notation are exact in every profile. A
`Double` is exact only when it *is* a decimal with the schema's places or
fewer (0.5 into scale 2); any other `Double` (0.1 is
0.1000000000000000055...) is refused by `Strict` and `Lossless`, and
`Natural` writes the shortest text that reads back as the same double. No
profile rounds: more places than the scale is refused.

**A value is written only when its kind is one the field's type holds** -
`Bool` for boolean; `Int` for int and long (an int must fit in 32 bits);
`Float`, `Int` (and, under `Natural` only, `Decimal`) for float and double;
`Str` for string and enum; `Bytes` for bytes and fixed; `Arr` for an array;
`Obj` for a map and a record. Any other kind - a string into an int, text
into bytes - is refused with `EStructuralConversionError`
(`UnsupportedValueKind`) in every profile, never written as zero or empty.
JSON has no bytes, so text is not decoded as base64 into a bytes field.

**Block counts and sizes are checked before use.** A block count of
`Low(Int64)`, an item count or block size above `High(Integer)`, or one the
remaining input cannot hold (when every item takes at least a byte) is
refused with `EAvroInputError` before anything is narrowed, allocated or
looped over.

**A member the schema does not name** is omitted by `Natural` - the schema is
the destination's whole vocabulary - and refused by `Strict` and `Lossless`
with its path (`$.Customer.InternalCode`): Avro has no standard place to
carry it, so writing the record would silently drop it.

A text payload handed to the Avro handler is refused with `EAvroInputError`.
Avro reads bytes only.

## Lossless behavior

When Avro is the destination, the schema decides. There is no name encoding:
a record's fields are the schema's fields. `Natural`, `Lossless` and
`Strict` produce the same bytes for a tree the schema represents exactly;
they differ only where something would be adapted - a member the schema does
not name, a `Double` that is not exactly a decimal, a union tie - which
`Natural` adapts as described above and the other two refuse. A `decimal`
crosses as `TDynamicKind.Decimal`, so it survives into a destination with a
decimal and refuses honestly into one without.

When Avro is the source, `Lossless` depends on the destination. See
[`../conversion.md`](../conversion.md).

## Contract-aware behavior

These depend on the Delphi type `T` (`Serialize<T>`, `Deserialize<T>`,
`DeserializeWith<T>`, `TSerialization.Convert<T>`, `From<T>`):

- the generated schema: names, `AvroName`, `AvroIgnore`, `AvroAliases`,
  enum symbols from `RegisterEnumMapping`;
- `Currency` exact as `decimal`, `TDate` and `TTime` as `date` and
  `time-millis`, `TGUID` as `uuid`;
- nil against empty for classes and containers, through the null branch;
- range checks into the member type (the input error);
- sets, collections, dictionaries, custom serializers.

On read, an object or record a member already holds is merged in place, not
replaced; an array is replaced. See
[`../deserialization-ownership.md`](../deserialization-ownership.md).

The contract path needs no schema from the caller: the Delphi type is the
schema. `Deserialize<T>` assumes the bytes were written with `T`'s own
schema. For bytes written with any other schema, use `DeserializeWith<T>`
with the writer's schema, or an object container file, which carries it.

## Schema/context

Structural conversion needs a schema in the conversion options. Without one
it raises `ESerializationSchemaRequired`, **not**
`ESerializationFormatCapability`: the format can do it, given the schema.

```pascal
uses
  PascalForge.Avro.Schema;

Schema := TAvroSchema.Parse(TFile.ReadAllText('customer.avsc'));
try
  Json := TSerialization.Convert(Wire, TSerializationFormat.Avro,
            TSerializationFormat.Json,
            TStructuralConversionProfile.Natural, Schema);
finally
  Schema.Free;
end;
```

- A bare `TAvroSchema` is accepted as the context. In the source role it is
  the writer's schema; in the destination role, the schema to write.
- `TAvroSerializationContext.Create(Writer, Reader)` adds a reader's schema
  to resolve into, which makes Avro-to-Avro resolution expressible.
- The caller owns every schema. Nothing that receives one frees it.
- A bare datum must be exactly its bytes. Bytes left over after the read
  mean the wrong schema or appended data, and are refused. The bytes alone
  cannot always tell a wrong schema apart.
- `ToJson`, `CanonicalForm` and `Fingerprint` print, canonicalize and
  fingerprint a schema without encoding a byte.
- `TSerialization.StructuralFormats(Options)` and
  `StructuralRequirement` report `schema` for Avro.

## DataSet behavior

With a contract, `TDataSetSerializer.CreateFDMemTable<T>(Bytes,
TSerializationFormat.Avro)` works like any other format. Without one, pass
the writer's schema: `TDataSetSerializer.Deserialize(Payload,
TSerializationFormat.Avro, Schema, DataSet)`, or `CreateFDMemTable` /
`CreateClientDataSet` with an `ASchema: TSerializationContext`. The schema is
borrowed. Without a schema, the structural read raises
`ESerializationSchemaRequired`. See
[`../dataset-formats.md`](../dataset-formats.md) and
[`../dataset-projection.md`](../dataset-projection.md).

| Avro, through a schema | Inferred field type |
| --- | --- |
| `int`, `long` within 32 bits | `ftInteger` |
| `long` beyond 32 bits | `ftLargeint` |
| `float`, `double`, `decimal` | `ftFloat` |
| `date` | `ftDate` |
| `time-millis`, `time-micros` | `ftTime` |
| `timestamp-*`, `local-timestamp-*` | `ftDateTime` |
| `bytes`, `fixed` | `ftBlob` |
| `boolean` | `ftBoolean` |
| `string`, `enum`, `uuid` | `ftWideString` |
| nested record, array of records | `ftDataSet` (nested) |

Avro is one of the sources that has a date, so a `date` column is `ftDate`,
not `ftDateTime` at midnight. `TDataSetSerializer.Serialize(DataSet,
TSerializationFormat.Avro, Policy)` has no schema parameter, so it raises
`ESerializationSchemaRequired`.

## Custom serializers

Base classes in `PascalForge.Avro`:

- `TCustomAvroValueSerializer<T>`: override `class function SchemaJson:
  string`, `SerializeValue(const AValue: T): TAvroValue` and
  `DeserializeValue(AValue: TAvroValue; const AExisting: T): T`. Use this one.
- `TCustomAvroValueSerializer`: the untyped base with `TValue` and
  `PTypeInfo`, for a type not known at compile time.

A serializer must supply its schema as well as its value, because the bytes
it produces cannot be read without one. `SchemaJson` is parsed once and
spliced into the schema generated for the owning type.

Registration:

```pascal
TAvroSerializer.RegisterTypeSerializer<TMoney>(TMoneyAvroSerializer);
```

Per member: `[AvroSerializer(TMoneyAvroSerializer)]`.

The caller adopts the `TAvroValue` a serializer returns. A read returns a new
instance or the existing one it was given. See
[`../customization.md`](../customization.md) and
[`../deserialization-ownership.md`](../deserialization-ownership.md).

## Limits/security

| Limit | Value | Error |
| --- | --- | --- |
| write depth | 64 levels (each object, record, array, list, dictionary counts one) | `ESerializationLimitExceeded` |
| read nesting | 512 datums (`AVRO_MAX_DEPTH`); every record, array, map and union counts, so a union and the record inside it count one each | `EAvroInputError` |
| varint length | 10 bytes | `EAvroInputError` |
| declared length | checked by subtraction against the bytes that remain, before allocation | `EAvroInputError` |
| trailing bytes after a bare datum | refused | `EAvroInputError` |
| `int` datum past 32 bits | refused | `EAvroInputError` |
| union branch index out of range | refused | `EAvroInputError` |
| invalid UTF-8 in a `string` | refused | `EInvalidUtf8` (Core) |
| unknown container codec | refused by name | `EAvroInputError` |
| decompressed size of one deflate container block | 64 MiB by default (`TAvroReadOptions.DefaultMaxInflatedBlockBytes`); set per call with `TAvroReadOptions.MaxInflatedBlockBytes`. Enforced while inflating, a 64 KB chunk at a time, so a small hostile block never expands past the budget | `EAvroInputError` |
| `MaxInflatedBlockBytes` of zero or less | refused (`TAvroReadOptions.Validate`) | `EAvroError` |
| container block size on write | flushed at about 1 MiB; a larger datum is a block alone, so a default read opens every default write | - |
| one deflate datum past `DefaultMaxInflatedBlockBytes` on write | refused, since no default read could open it; the null codec writes it | `EAvroError` |
| fixed `size` past an Integer, or not a whole number | refused | `EAvroSchemaError` |

`tests\Robustness` covers huge lengths, huge counts, nesting and
truncation.

## Expected refusals

By design, not bugs:

- the refusals every format makes: pointers, procedural and method types,
  interfaces, class references, legacy `TList`, `TCollection`, streams,
  `Exception`, `TComponent`, cycles, inline static arrays, variant records,
  `TBcd` without a custom serializer;
- a value nested deeper than 64 levels, on write;
- a `TDateTime` or `TDate` outside the years 1 to 9999, on write;
- an unpaired UTF-16 surrogate in a string, on write;
- a `UInt64` above `High(Int64)`;
- a `Variant` of any kind: a field has one declared type;
- a class with no parameterless constructor;
- a dictionary whose key type has no single text form;
- structural conversion, or a DataSet from bytes, with no schema;
- a datum read with a schema other than its writer's, when the bytes do not
  add up;
- an `int` datum or default past 32 bits;
- a text payload given to the Avro handler.

See [`../expected-refusals.md`](../expected-refusals.md) and
[`../limitations.md`](../limitations.md).

## Interoperability evidence

`tests\AvroNative` uses the **Avro 1.12 specification's own encodings** as
the independent reference: the worked example (a record of `long` 27 and
`string` `"foo"`, `36 06 66 6f 6f`) and the zig-zag varint table, byte for
byte. No reference implementation runs offline, so the oracle is the
specification. The ledger also covers every type, block encoding, union
indices, `fixed` with no prefix, schema parsing, named types, aliases,
defaults, schema resolution and its refused promotions, the logical types,
an unknown annotation being kept, object container files, both codecs, and
malformed input.

## Important implementation units

| Role | Unit |
| --- | --- |
| Facade | `src\PascalForge.Avro.pas` (`TAvroSerializer`, `TAvroValue`, attributes, custom serializer bases) |
| Implementation | `src\PascalForge.Avro.Internal.pas` (`TAvroEngine`: byte reader and writer, resolution, schema generation, RTTI walk, containers, dynamic bridge) |
| Registration | `src\PascalForge.Avro.Registration.pas` (`TAvroSerializationRegistration`, `TAvroFormatHandler`) |
| Schema | `src\PascalForge.Avro.Schema.pas` (`TAvroSchema`, `TAvroSerializationContext`, parser, canonical form, fingerprint) |
| Tests | `tests\AvroNative\AvroNative.dpr`, `tests\AvroNative\AvroModels.pas` |

## Before changing this format

1. Read [`../format-program.md`](../format-program.md) and
   [`../avro-behavior.md`](../avro-behavior.md).
2. Run `tests\AvroNative`
   (`powershell -File scripts\test.ps1 -Only AvroNative`).
3. Run `tests\TypeCoverage` through `scripts\run-type-coverage.ps1`.
4. Run `tests\ReaderContracts`, `tests\ConversionMatrix` and
   `tests\Lifecycle`.
5. Do not change shared dynamic-model semantics (`TDynamicValue`, `TDynamicTag`,
   Core date and range helpers) from a format unit. Change Core deliberately,
   and retest every format.
6. A change to what Avro writes, including the generated schema, needs a
   test that pins the bytes and a documentation change.
   Keep the specification's worked example passing.
7. Run `scripts\validate-release.ps1` before calling it finished.
