# CSV

## Purpose

This is the entry point for the CSV format. It summarizes what the format
does and where the code is. For depth, read
[`../csv-behavior.md`](../csv-behavior.md). The API is in
[`../api-reference.md`](../api-reference.md).

CSV is a real engine. A Delphi value is projected straight onto rows of
cells and read straight back. The contract path does not go through the
dynamic tree. The natural payload type is `string`; `SerializeToBytes` and
`DeserializeBytes` give UTF-8 bytes.

A CSV document is a table, not a tree. So the questions CSV forces on a
value are about nested objects, collections and nulls. Each has an explicit
option, and the default for a collection is to refuse.

## Standard/profile

- **RFC 4180**: comma delimiter, double-quote quoting, the doubled-quote
  escape, embedded delimiters, quotes and line breaks inside quoted fields,
  an optional header row.
- Beyond RFC 4180: CRLF, bare LF and bare CR row ends; no final line break;
  a UTF-8 byte-order mark skipped on read.
- Dialects (`TCsvDialect`): `Standard` (RFC 4180, CRLF, header), `Excel`
  (RFC 4180 plus a byte-order mark), `TabSeparated`, and `Custom`, which
  `Dialect` reports when `Delimiter` or `QuoteChar` were set by hand.
- Other `TCsvOptions` fields: `HasHeader`, `WriteBom`, `NewLine` (`CrLf`,
  `Lf`), `AlwaysQuote`, `TrimUnquotedValues` (a quoted value is never
  trimmed), `RaggedRows` (`Error`, `PadWithEmpty`, `Truncate`) and
  `DuplicateHeaders` (`Error`, `Rename`, `UseFirst`, `UseLast`).
- The writer quotes a value that holds the delimiter, the quote, CR, LF, or
  a leading or trailing space.

Not implemented: several tables in one payload, reading child tables back
into their parents, and `RepeatedRows` below the top level. `ExpandDottedNames`
is declared on `TCsvOptions`, but no engine code reads it.

## Public facade

Unit `PascalForge.Csv`, class `TCsvSerializer`. All methods are class
static. `T` is the whole table: `TArray<TRow>`, `TList<TRow>`,
`TObjectList<TRow>`. A single record or class is one row.

| Method | Signature |
| --- | --- |
| `Serialize<T>` | `(const AValue: T): string`, and with `const AOptions: TCsvOptions` |
| `Deserialize<T>` | `(const AText: string): T`, and with `TCsvOptions` |
| `SerializeToBytes<T>` | `(const AValue: T): TBytes`, and with `TCsvOptions` |
| `DeserializeBytes<T>` | `(const AData: TBytes): T`, and with `TCsvOptions` |
| `SerializeTables<T>` | `(const AValue: T): TCsvDocumentSet`, and with `TCsvOptions`; the caller owns the result |
| `DeserializeTables<T>` | `(ATables: TCsvDocumentSet): T`, and with `TCsvOptions`; reads the root table only |
| `TablesFrom` | `(const ASource: TSerializationPayload; ASourceFormat: TSerializationFormat; const AOptions: TCsvOptions): TCsvDocumentSet`, and with an `ASourceContext` for a schema-driven source; a document in another format onto CSV tables; the caller owns the result |
| `InferSchema` | `(const AText: string): TCsvSchema`, and with `TCsvOptions`; the caller owns the result |
| `SchemaOf<T>` | `: TCsvSchema`, and with `TCsvOptions`; the caller owns the result |
| `ToDynamic` / `FromDynamic` | `(const ACsv: string): TDynamicValue` (always an array of objects) / `(AValue: TDynamicValue): string`, each also with `TCsvOptions` - see [`../dynamic.md`](../dynamic.md) |

The general attributes apply; `[CsvName]` and `[CsvIgnore]` beat them for CSV. CSV has no enumeration mapping of its own, so `[SerializationEnum]` is the way to change an enumeration's cell text. See [`../attributes.md`](../attributes.md).

There is no `Populate`, `TryDeserialize` or `From`. The one-argument
overloads use `TCsvOptions.Default`. The one-argument `SerializeTables` and
`DeserializeTables` use `Default` with `CollectionMode.SeparateTable`.

Configuration (call at startup):

- `RegisterTypeSerializer<T>(ASerializerClass: TCsvCellSerializerClass)`
- `SetDateTimeFormat`, `RegisterDateTimeFormat<T>`,
  `RegisterFieldDateTimeFormat<T>`
- `FreezeConfiguration`, `IsFrozen`, `ResetConfiguration` (for tests)

There is no enumeration mapping registration. An enumeration is written as
its member name.

Configuration freezes automatically at the first real serializer operation
(any call that builds or looks up a plan, including the registry's typed
calls). After that, configuration is immutable and concurrent use is safe. A
registration made after the freeze raises `ECsvInternalError` saying the
configuration is frozen. `FreezeConfiguration` freezes earlier. See
[`../configuration-lifecycle.md`](../configuration-lifecycle.md) for the full
lifecycle.

Exceptions: `ECsvError`, `ECsvInputError` (the document is at fault),
`ECsvInternalError` (model or configuration), and `ECsvProjectionError` (the
value does not fit a table under the options; it carries `Path`, the Delphi
member path). A type every format refuses, and a `Variant`, raise `ECsvError`
itself.

## Explicit registry registration

```pascal
uses
  PascalForge.Csv.Registration;
...
TCsvSerializationRegistration.RegisterFormat;
```

- Linking or importing `PascalForge.Csv.Registration` does **not** register
  the format.
- Loading the `PascalForge.Serialization.Runtime` package does
  **not** register it.
- `RegisterFormat` is idempotent. It raises `ESerializationFormatConflict`
  if a different handler already holds `TSerializationFormat.Csv`.
- `UnregisterFormat` is safe when the format is absent, and never removes
  another unit's handler.
- `IsRegistered` reports whether this unit's handler holds the format.

Direct `TCsvSerializer` use needs no registration. Registration is needed
only for `TSerialization` (format chosen at run time), `TSerialization.Convert`,
and the `TDataSetSerializer` overloads that take a `TSerializationFormat`.

All formats at once: `TSerializationFormatsRegistration.RegisterAll` in unit
`PascalForge.Serialization.AllFormats`. It is also explicit.

Registry mutation happens at startup and shutdown. It must not run
concurrently with serialization.

The registry handler uses `TCsvOptions.Default` unless the conversion
options carry a `TCsvSchema` for the role CSV plays - a destination schema
when writing, a source schema when reading - in which case it uses that
schema's `Options`. CSV options never enter `TStructuralConversionOptions`;
the schema is how they travel. The contract path (`TSerialization.Serialize`)
has no conversion options and always uses the defaults.

## Native Delphi mappings

| Delphi | CSV cell, by default |
| --- | --- |
| `Boolean` (and `ByteBool`, `WordBool`, `LongBool`) | `true` / `false`; read also accepts `1`/`0`, `yes`/`no`, `y`/`n` |
| integers of every width, `Comp` | digits, with the type's own sign (`UInt64` above `High(Int64)` included) |
| `Single`, `Double`, `Extended` | shortest round-trip decimal, invariant; `NaN`, `INF`, `-INF` |
| `Currency` | invariant decimal text |
| `string`, `Char`, Ansi and short strings | the text, quoted only when needed |
| `TBytes` | base64 |
| `TDateTime` | `yyyy-mm-ddThh:nn:ss.zzz` |
| `TDate`, `TTime` | `yyyy-mm-dd`, `hh:nn:ss.zzz` |
| `TGUID` | lowercase 36 characters, no braces |
| enumeration | member name; read also accepts an in-range ordinal |
| set | comma-joined member names in one cell |
| nested class, record | `TCsvNestedObjectMode` (default `Flatten`: `Shipper.City` columns) |
| list, dynamic or static array | `TCsvCollectionMode` (default `Error`) |
| dictionary | `NestedObjectMode.JsonCell` only; every other mode refuses |
| `TNullable<T>` with no value | `TCsvNullPolicy` (default `EmptyField`) |
| `Variant` | refused |

Projection modes:

- `TCsvNestedObjectMode`: `Flatten` (default), `JsonCell`, `SeparateTable`,
  `Error`. `Flatten` joins member names with `PathSeparator` (`.`).
- `TCsvCollectionMode`: `Error` (default), `JsonCell`, `RepeatedRows`,
  `SeparateTable`, `NumberedColumns` (`Tags_1`, `Tags_2`...; scalar
  elements only).
- `TCsvMultipleCollections`: `Error` (default) refuses two collections with
  more than one element under `RepeatedRows`; `CartesianProduct` writes
  every pairing.
- `SeparateTable` produces several documents, so it is reachable only
  through the calls that return a `TCsvDocumentSet`: `SerializeTables` for a
  Delphi value and `TablesFrom` for a document in another format.
  `Serialize` refuses it with `ECsvProjectionError`, and
  `TSerialization.Convert` with `ESerializationFormatCapability`, both
  naming those two calls. Relationships travel on the `TCsvDocumentSet`,
  never in a file. `[CsvKey]` names the join key; without one a `RowKey`
  column is generated.
- `JsonCell` reaches JSON through the registry, not by import. JSON must be
  registered, or the call raises `ESerializationFormatNotRegistered`. On
  read, a `JsonCell` member is **replaced**, not refilled
  ([`../limitations.md`](../limitations.md)).
- `TCsvNullPolicy`: `EmptyField` (not reversible: an empty string reads
  back as null), `Literal` (writes `NullLiteral`, default `NULL`), `Error`.

Member attributes: `CsvName`, `CsvIgnore`, `CsvKey`, `CsvTable` (on the row
type), `CsvDateTimeFormat`, `CsvSerializer`.

Dates and text:

- A `TDateTime` or `TDate` outside the years 1 to 9999 is refused on write.
- Date text with a zone offset (or `Z`) is refused on read with
  `ECsvInputError`. The reader accepts a date, a time, or both, joined by
  `T` or a space, and no offset. Nothing is written with an offset.
- A `CsvDateTimeFormat` or registered pattern is read back with the same
  pattern (numeric specifiers; `TStructuralText.TryDecodePattern`), and ISO
  text is still accepted.
- Float text is read correctly rounded (`TStructuralText.TryParseFloat`).
- An unpaired UTF-16 surrogate: `Serialize` keeps it in the string;
  `SerializeToBytes` refuses it (`ESerializationUnsupported`), because UTF-8
  cannot encode it. `DeserializeBytes` refuses malformed UTF-8
  (`EInvalidUtf8`).

Full detail: [`../csv-behavior.md`](../csv-behavior.md),
[`../datetime-policies.md`](../datetime-policies.md),
[`../unicode-and-utf8.md`](../unicode-and-utf8.md),
[`../delphi-type-coverage.md`](../delphi-type-coverage.md).

## Structural representation

CSV declares all four registry capabilities with no schema, except
`StructuralWrite` when a destination `TCsvSchema` asks for `SeparateTable`.
The handler's payload kind is text. `TCsvEngine.TextToDynamic` and
`TCsvEngine.DynamicToText` do the work, with `TCsvOptions.Default` or the
`Options` of a `TCsvSchema` in the conversion options:

```pascal
Schema := TCsvSchema.Create(TCsvOptions.Default
  .WithCollectionMode(TCsvCollectionMode.JsonCell));
try
  Csv := TSerialization.Convert(Json, TSerializationFormat.Json,
    TSerializationFormat.Csv,
    TStructuralConversionOptions.Default.WithContext(Schema));
finally
  Schema.Free;
end;
```

Every single-document option applies: `Delimiter`, `HasHeader`,
`NullPolicy`, `NestedObjectMode` `Flatten` and `JsonCell`, and
`CollectionMode` `JsonCell`, `NumberedColumns` and `RepeatedRows`.

A table is always an `Arr` of `Obj`, one object per row, even for one row.
Column names are taken literally; `Address.City` stays one key. A headerless
file names columns `Column1`, `Column2`... Each column's type is inferred
over all its cells (`SchemaInference`, default `Conservative`).

| CSV cell | `TDynamicValue` |
| --- | --- |
| empty (under `EmptyField`) | `Null` |
| `true` / `false` in a Boolean column | `Bool` |
| plain integer in an integer column | `Int` |
| plain fraction in a float column | `Float` |
| anything else, including `007`, dates, GUIDs | `Str` |
| ISO date-time / base64, `Extended` inference only | `DateTime` / `Bytes` |

On the way back: `Bool` as `true`/`false`, `Int` and `UInt` as digits,
`Float` as shortest decimal, `Decimal` as its exact text, `Bytes` as base64,
`DateTime`, `Date` and `Time` as ISO text. A root `Obj` is a one-row table.
A nested `Obj` follows `NestedObjectMode` (default: flattened). An `Arr`
member follows `CollectionMode` and is refused under the default
`CollectionMode.Error`. An `Extended` value is refused. A root that is not
an object or an array of objects is refused.

**Several tables from one document.** `SeparateTable` returns a
`TCsvDocumentSet`, so it is never a payload. `TCsvSerializer.TablesFrom`
reads the document through its format's registered handler and projects the
tree with the same table rules as `SerializeTables`:

```pascal
TJsonSerializationRegistration.RegisterFormat;     // the SOURCE format
Tables := TCsvSerializer.TablesFrom(JsonPayload, TSerializationFormat.Json,
  TCsvOptions.Default.WithCollectionMode(TCsvCollectionMode.SeparateTable));
try
  for I := 0 to Tables.Count - 1 do
    TFile.WriteAllText(Tables[I].Name + '.csv', Tables[I].Content);
finally
  Tables.Free;
end;
```

A tree has no type names and no `[CsvKey]`, so the document root names its
tables: a root array is the table `root`; on a root object, each member that
is a table of its own (an array under `CollectionMode.SeparateTable`, an
object under `NestedObjectMode.SeparateTable`) is a top-level table named
after the member, and the remaining members form the one-row table `root`
(omitted when empty). Below that the shared rule applies: a collection in a
row of `customers` is the table `customers_orders`, joined on a generated
`RowKey` column in the parent and `customers_RowKey` in the child, with the
relationship on the document set. Nothing is recognised by name: a document
with `fields` and `rows` members is two tables, `fields` and `rows` - DataSet
meaning belongs to `TDataSetSerializer`. CSV needs no registration for
`TablesFrom`; the source format does.

A projection refusal on this path is raised as `EStructuralConversionError`
(issue `UnsupportedValueKind`), carrying the `ECsvProjectionError` path and
message.

## Lossless behavior

`DynamicToText` does not read the profile; the CSV options decide the
projection. `Natural`, `Lossless` and `Strict` produce the same text, and
refuse the same values.

CSV as a destination is lossy by nature: every cell is text, and types are
re-inferred on the way back. An empty string and a null are one cell under
`EmptyField`. A flattened `{"a":{"b":1}}` and a key `a.b` write the same
column. See [`../conversion.md`](../conversion.md).

When CSV is the source, the tree holds only the inferred kinds above. The
destination decides what it can express. A destination whose root must be a
map (BSON) refuses the array a CSV table becomes.

## Contract-aware behavior

These depend on the Delphi type `T` (`Serialize<T>`, `Deserialize<T>`,
`TSerialization.Convert<T>`):

- column names, `CsvName`, `CsvIgnore`, `CsvKey`, `CsvTable`;
- which dotted columns belong to a nested member (only the contract expands
  them);
- cell types: range checks into the member type, text into its code page,
  `TDate` and `TTime` as their own text, sets, `TGUID`, `TBytes`;
- date patterns, per member, field, type or globally;
- `TNullable<T>` presence; a present nullable composite whose cells would
  all be empty is refused on write (`ECsvProjectionError`);
- the projection modes and custom cell serializers.

Through the registry the contract path uses `TCsvOptions.Default`, so a
collection member is refused there. Use `TCsvSerializer` directly for any
other mode.

## Schema/context

None is needed. `TCsvSchema` (a `TSerializationSchema`) exists as a
description alongside the file: `InferSchema` reports what the spelling of
the values supports, `SchemaOf<T>` what the contract types are. Column types
are `Str`, `Boolean`, `Int32`, `Int64`, `Float`, `DateTime`, `Guid`,
`Binary`. The schema is never written into the CSV, and the registry
handler does not consult it.

## DataSet behavior

`TDataSetSerializer.CreateFDMemTable(Text, TSerializationFormat.Csv)` and
the other overloads that take a `TSerializationFormat` need the format
registered. The table is parsed into the dynamic tree and the schema is
inferred from it. The handler always infers with `Conservative`. See
[`../dataset-formats.md`](../dataset-formats.md) and
[`../dataset-projection.md`](../dataset-projection.md).

| CSV column | Inferred field type |
| --- | --- |
| plain integers within 32 bits | `ftInteger` |
| wider plain integers | `ftLargeint` |
| plain fractions, or integers mixed with fractions | `ftFloat` |
| `true` / `false` | `ftBoolean` |
| text, leading zeros, dates, GUIDs, base64, mixed spellings | `ftWideString` |
| all empty | `ftWideString` |

CSV has no nested dataset here: a dotted column is a plain field. A date
column is text, so it infers as `ftWideString`. Supply the contract
(`CreateFDMemTable<T>(Text, TSerializationFormat.Csv)`) for Delphi field
types. `TDataSetSerializer.Serialize(DataSet, TSerializationFormat.Csv,
TDataSetSerializationPolicy.RowsOnly)` writes the rows as a CSV table. A
`StructureAndRows` packet is an object of two arrays and is refused.

## Custom serializers

Base classes in `PascalForge.Csv`:

- `TCustomCsvCellSerializer<T>`: override
  `SerializeValue(const AValue: T): string` and
  `DeserializeValue(const AText: string; const AExisting: T): T`. Use this
  one.
- `TCustomCsvCellSerializer`: the untyped base with `TValue` and
  `PTypeInfo`, for a type not known at compile time.

A cell is text, so a serializer is a pair of text conversions. It cannot
produce structure.

Registration:

```pascal
TCsvSerializer.RegisterTypeSerializer<TMoney>(TMoneyCsvSerializer);
```

Per member: `[CsvSerializer(TMoneyCsvSerializer)]`. A registered serializer
takes precedence over the built-in refusals, so it can carry a `Variant` or
`TBcd`. See [`../customization.md`](../customization.md) and
[`../deserialization-ownership.md`](../deserialization-ownership.md).

## Limits/security

| Limit | Value | Error |
| --- | --- | --- |
| write depth | 64 levels (each object, record, array, list, dictionary counts one; the row itself included) | `ESerializationLimitExceeded` |
| header nesting on read | 256 (`CSV_MAX_DEPTH`, in `PascalForge.Csv.Internal`), e.g. `Next.Next.….Id` | `ECsvInputError` |
| quoted value never closed | refused, with the row number | `ECsvInputError` |
| ragged row, duplicate header | refused by default | `ECsvInputError` |
| cycle in the written graph | refused, with the path | `ECsvProjectionError` |
| malformed UTF-8 (byte forms) | refused | `EInvalidUtf8` |

There is no separate size limit on input text. `tests\Robustness` covers
the header nesting bomb, truncation and hostile substitutions.

## Expected refusals

By design, not bugs:

- the refusals every format makes: pointers, procedural and method types,
  interfaces, class references, legacy `TList`, `TCollection`, streams,
  `Exception`, `TComponent`, cycles, inline static arrays, variant records,
  `TBcd` without a custom serializer;
- a value nested deeper than 64 levels;
- a `TDateTime` or `TDate` outside the years 1 to 9999, on write;
- an unpaired UTF-16 surrogate, in `SerializeToBytes` output;
- date text with a zone offset, on read;
- a `Variant`, of any kind;
- a collection or array member under the default `CollectionMode.Error`;
- a map under any mode but `NestedObjectMode.JsonCell`;
- two multi-element collections under `RepeatedRows` without
  `CartesianProduct`;
- `SeparateTable` through `Serialize` or the registry - it returns several
  documents; use `SerializeTables` or `TablesFrom`;
- a present nested object with no members under `Flatten`;
- a root that is not a record, a class, or a collection of them.

In the type-coverage matrix most array, collection, record-with-collection
and "empties" probes are `R` for CSV for these reasons. See
[`../expected-refusals.md`](../expected-refusals.md).

## Interoperability evidence

`tests\CsvNative` uses **RFC 4180** as the independent reference. Its rules
are quoted beside the checks that exercise them, for example section 2.6
(`1,"Doe, Jane","He said ""hi""",2` and a quoted line break) and section
2.7 (doubled quotes). No reference implementation runs offline, so the
oracle is the specification's text. The test also covers the dialects,
headerless files, ragged rows, duplicate headers, every nested-object and
collection mode, the Cartesian-product guard, document sets, null policies,
inference policies, DataSet projection, Unicode and `JsonCell` through the
registry.

## Important implementation units

| Role | Unit |
| --- | --- |
| Facade | `src\PascalForge.Csv.pas` (`TCsvSerializer`, `TCsvOptions`, `TCsvSchema`, `TCsvDocumentSet`, attributes) |
| Implementation | `src\PascalForge.Csv.Internal.pas` (`TCsvLexer`, `TCsvTextWriter`, `TCsvTable`, `TCsvBuffer`, `TCsvEngine`: RTTI walk, row writer and reader, inference, dynamic bridge) |
| Registration | `src\PascalForge.Csv.Registration.pas` (`TCsvSerializationRegistration`, `TCsvFormatHandler`) |
| Schema | in the facade (`TCsvSchema`); no separate unit |
| Tests | `tests\CsvNative\CsvNative.dpr`, `tests\CsvNative\CsvModels.pas` |

## Before changing this format

1. Read [`../format-program.md`](../format-program.md) and
   [`../csv-behavior.md`](../csv-behavior.md).
2. Run `tests\CsvNative`
   (`powershell -File scripts\test.ps1 -Only CsvNative`).
3. Run `tests\TypeCoverage` through `scripts\run-type-coverage.ps1`.
4. Run `tests\ReaderContracts`, `tests\ConversionMatrix` and
   `tests\Lifecycle`. For DataSet changes, also `tests\DataSetFormats`.
5. Do not change shared dynamic-model semantics (`TDynamicValue`, `TDynamicTag`,
   Core date and range helpers) from a format unit. Change Core deliberately,
   and retest every format.
6. Keep `PascalForge.Csv.Internal` free of any compile-time reference to
   `PascalForge.Json`; `JsonCell` goes through the registry.
7. A change to what CSV writes needs a test that pins the text and a
   documentation change.
8. Run `scripts\validate-release.ps1` before calling it finished.
