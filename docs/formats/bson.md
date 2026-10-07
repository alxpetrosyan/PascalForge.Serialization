# BSON

## Purpose

This is the entry point for the BSON format. It summarizes what the format
does and where the code is. For depth, read
[`../bson-behavior.md`](../bson-behavior.md) (what BSON writes for a Delphi
type) and [`../bson-compatibility.md`](../bson-compatibility.md) (the
element-type ledger, the security audit and the evidence). The API is in
[`../api-reference.md`](../api-reference.md).

BSON is a real engine. A Delphi value is written straight to BSON bytes and
read straight back. Nothing goes through JSON text, XML, or the dynamic tree
on the contract path. The natural payload type is `TBytes`.

## Standard/profile

- **BSON specification, version 1.1** (bsonspec.org). This is the version
  the code and `tests\BsonNative` name.
- Every element type the specification defines is read and written,
  including the three it marks deprecated: undefined (`0x06`), DBPointer
  (`0x0C`) and symbol (`0x0E`).
- The binary subtype byte is kept exactly, including the user-defined range
  `0x80`-`0xFF`.
- A type byte the specification does not define is refused by name
  (`EBsonUnsupportedType`), never skipped.
- Encoding is deterministic for a given element order, and element order is
  preserved.

Not implemented: a MongoDB driver or wire protocol, ObjectId generation, and
decimal128 arithmetic (a decimal128 is carried as its sixteen bytes).
MongoDB Extended JSON is a separate standard; it is used for BSON-JSON
conversion (see [Lossless behavior](#lossless-behavior)).

## Public facade

Unit `PascalForge.Bson`, class `TBsonSerializer`. All methods are class
static.

| Method | Signature |
| --- | --- |
| `Serialize<T>` | `(const AValue: T): TBytes` |
| `Deserialize<T>` | `(const AData: TBytes): T` |
| `Populate<T>` | `(const AInstance: T; const AData: TBytes)` |
| `ParseDocument` | `(const AData: TBytes): TBsonValue`; the caller owns the result |
| `WriteDocument` | `(ADocument: TBsonValue): TBytes`; borrows the tree |
| `ToJson` / `FromJson` | `(const AData: TBytes): string` / `(const AJson: string): TBytes` - plain JSON |
| `ToJsonWithSchema` / `FromJson` | `(const AData: TBytes; out ASchema: string): string` / `(const AJson, ASchema: string): TBytes` |
| `ToExtendedJson` / `FromExtendedJson` | `(const AData: TBytes): string` / `(const AJson: string): TBytes` - MongoDB Extended JSON |
| `From` | structural: `(ASource: string / TBytes / TSerializationPayload; AFrom: TSerializationFormat): TBytes`, and a payload overload with `TStructuralConversionProfile` |
| `From<T>` | contract-aware: the same source overloads |
| `ToDynamic` / `FromDynamic` | `(const ABson: TBytes): TDynamicValue` / `(AValue: TDynamicValue): TBytes`; native BSON values are Extended values - see [`../dynamic.md`](../dynamic.md) |

The general attributes apply; `[BsonName]`, `[BsonIgnore]` and `RegisterEnumMapping` beat them for BSON. See [`../attributes.md`](../attributes.md).

There is no `TryDeserialize` and no encode-options record. The six JSON
methods reach JSON through the registry, so JSON must be registered
(`TJsonSerializationRegistration.RegisterFormat`); otherwise they raise
`ESerializationFormatNotRegistered`.

Configuration (call at startup):

- `SetDateTimeRepresentation` (a `TBsonDateTimeRepresentation` or a
  pattern), `RegisterDateTimeRepresentation<T>`,
  `RegisterFieldDateTimeRepresentation<T>`
- `RegisterEnumMapping<T>(const AValues: array of string)`
- `RegisterTypeSerializer<T>(ASerializerClass: TBsonValueSerializerClass)`
- `FreezeConfiguration`, `IsFrozen`, `ResetConfiguration` (for tests)

Configuration freezes automatically at the first real serializer operation
(`Serialize`, `Deserialize`, `Populate`, `From<T>`, or the registry's typed
calls). After that, configuration is immutable and concurrent use is safe. A
registration made after the freeze raises `EBsonInternalError` saying the
configuration is frozen. `FreezeConfiguration` freezes earlier, and
`IsFrozen` reports the state. See
[`../configuration-lifecycle.md`](../configuration-lifecycle.md) for the full
lifecycle.

Exceptions: `EBsonError`, `EBsonInputError` (the bytes are at fault),
`EBsonUnsupportedType` (a subclass of the input error: an undefined type
byte), and `EBsonInternalError` (model or configuration). Messages for
malformed bytes name the byte offset.

## Explicit registry registration

```pascal
uses
  PascalForge.Bson.Registration;
...
TBsonSerializationRegistration.RegisterFormat;
```

- Linking or importing `PascalForge.Bson.Registration` does **not** register
  the format.
- Loading the runtime package `PascalForge.Serialization.Runtime.bpl` does
  **not** register it.
- `RegisterFormat` is idempotent. It raises `ESerializationFormatConflict`
  if a different handler already holds `TSerializationFormat.Bson`.
- `UnregisterFormat` is safe when the format is absent, and never removes
  another unit's handler.
- `IsRegistered` reports whether this unit's handler holds the format.

Direct `TBsonSerializer` use needs no registration. Registration is needed
only for `TSerialization` (format chosen at run time), `TSerialization.Convert`,
and the `TDataSetSerializer` overloads that take a `TSerializationFormat`.

All formats at once: `TSerializationFormatsRegistration.RegisterAll` in unit
`PascalForge.Serialization.AllFormats`. It is also explicit.

Registry mutation happens at startup and shutdown. It must not run
concurrently with serialization.

## Native Delphi mappings

A BSON root is always a document. A root that is not a class, record or
dictionary travels under the name `value`, and reading applies the same rule.

| Delphi | BSON, by default |
| --- | --- |
| `Boolean` | `0x08` boolean |
| integers up to 32 bits | `0x10` int32 (a `Cardinal` above `High(Integer)` as int64) |
| `Int64`, `UInt64` up to `High(Int64)` | `0x12` int64, even when the value fits in 32 bits |
| `UInt64` above `High(Int64)` | refused (`EBsonError`) |
| `Single`, `Double`, `Extended` | `0x01` double |
| `Currency` | `0x12` int64, the scaled integer Delphi stores (value x 10 000) |
| `string` | `0x02` string (UTF-8) |
| `TBytes` | `0x05` binary, subtype 0 |
| `TDateTime` | `0x09` UTC datetime, milliseconds since the Unix epoch |
| `TDate`, `TTime` | ISO 8601 string (`2026-03-14`, `17:30:00`) |
| `TGUID` | `0x05` binary, subtype 4, in RFC 4122 byte order |
| `TBsonObjectId` | `0x07` ObjectId |
| enumeration | member name (or the registered mapping) as a string |
| set | comma-joined string of member names |
| class, record | `0x03` document |
| list, dynamic or static array | `0x04` array |
| dictionary | `0x03` document; the key must be a string, integer, enumeration or GUID |
| `TNullable<T>` with no value, `nil` object | member omitted |
| `Variant` | the value it holds, as BSON's own type |

Member attributes: `BsonName`, `BsonIgnore`, `BsonDateTimeRepresentation`
(`Native`, `StringIso8601`, `UnixSeconds`, `UnixMilliseconds`,
`CustomString`), `BsonGuidRepresentation` (`BinaryUuid`, `LowercaseString`),
`BsonCurrencyRepresentation` (`ScaledInt64`, `Double`, `DecimalString`),
`BsonSerializer`.

GUIDs: `{73FFD264-44B3-4C69-90E8-E7D1DFC035D4}` is written as the bytes
`73 FF D2 64 44 B3 4C 69 ...`, as the bson-corpus vector, mongosh and the
drivers have it. Sixteen bytes under any other subtype (the legacy subtype 3)
are read in `TGUID`'s memory layout. Builds before 0.9.0 wrote the memory
layout under subtype 4, so such a document now reads as a different GUID.
A string GUID is also accepted on read.

Element types with no Delphi counterpart are reached through `TBsonValue`
only, directly or from a typed custom serializer: a BSON timestamp is the raw
`UInt64` (`NewTimestamp`, `AsTimestamp`), **not** a `TDateTime`; a
decimal128 is its sixteen bytes, carried but not interpreted; regular
expression, JavaScript, JavaScript with scope, symbol, DBPointer, min key,
max key and undefined have their own `TBsonKind`.

Dates and text:

- A `TDateTime` or `TDate` outside the years 1 to 9999 is refused on write
  (`ESerializationUnsupported`), in every representation. A BSON datetime
  outside those years is refused on read.
- ISO 8601 text with a zone offset is read with the wall-clock fields as
  written; the offset is ignored. Nothing writes an offset.
- A `CustomString` pattern is read back with the same pattern (numeric
  specifiers; `TStructuralText.TryDecodePattern`).
- A string with an unpaired UTF-16 surrogate is refused on write
  (`ESerializationUnsupported`), because UTF-8 cannot encode it. So is a
  zero byte in an element name (`EBsonInternalError`).
- A double is accepted for an integer member only when it is exactly
  integral.

Full detail: [`../bson-behavior.md`](../bson-behavior.md),
[`../datetime-policies.md`](../datetime-policies.md),
[`../delphi-type-coverage.md`](../delphi-type-coverage.md).

## Structural representation

BSON is self-describing. It declares all four registry capabilities with no
schema. The handler parses bytes into `TBsonValue` and maps it to
`TDynamicValue` (`TBsonEngine.BsonToDynamic`), and back
(`TBsonEngine.DynamicToBson`).

| BSON | `TDynamicValue` |
| --- | --- |
| int32, int64 | `Int` (the width is not kept) |
| double | `Float` |
| string / bool / null | `Str` / `Bool` / `Null` |
| binary, subtype 0 | `Bytes` |
| binary, any other subtype (UUID included) | `Extended`, tag `binarysubtype`, object of `subtype` and `data` |
| UTC datetime | `DateTime` |
| document / array | `Obj` / `Arr` |
| ObjectId | `Extended`, tag `objectid`, 24 lower-case hex characters |
| timestamp | `Extended`, tag `timestamp`, object of `t` and `i` |
| decimal128 | `Extended`, tag `decimal128`, the sixteen bytes |
| regular expression | `Extended`, tag `regex`, object of `pattern` and `options` |
| JavaScript / with scope | `Extended`, tags `javascript` / `javascriptscope` |
| symbol, DBPointer | `Extended`, tags `symbol` / `dbpointer` |
| undefined, min key, max key | `Extended`, tags `undefined` / `minkey` / `maxkey` |

On the way back, `Int` is int32 when it fits in 32 bits and int64 otherwise,
`UInt` is int64 up to `High(Int64)` and decimal128 above it, `Decimal` is
decimal128 when it fits (a string otherwise), `Date` and `Time` are ISO text,
and every BSON tag above becomes its element again. An `Extended` tag BSON
has no element for raises `EBsonError`. A non-document root is wrapped under
`value`.

Member names pass through unchanged in both directions: `$type` and `$oid`
stay members with those names.

A text payload handed to the BSON handler is refused with `EBsonInputError`.
BSON reads bytes only.

## Lossless behavior

BSON's type system covers every dynamic kind, and a BSON member name is an
arbitrary string. So there is no name to encode and no value to adapt when
BSON is the destination. `Natural`, `Lossless` and `Strict` produce the same
bytes. The profile still decides what the source may recognize: `$oid` is
read as an ObjectId only under `Lossless` with BSON as the destination.

When BSON is the source, the destination decides:

| Pair | `Lossless` |
| --- | --- |
| BSON -> JSON | MongoDB Extended JSON (`$oid`, `$date`, `$binary`, `$numberDecimal`, `$timestamp`, ...) |
| JSON -> BSON | MongoDB Extended JSON, read back (`$uuid` accepted as input) |
| BSON -> XML | composed route: MongoDB Extended JSON, then the W3C JSON/XML mapping (`TSerialization.RouteFor` shows it) |
| XML -> BSON | the same route, reversed |

Under `Natural`, BSON -> JSON writes base64, ISO text and hex; under
`Strict` it refuses with the member path. The options overload of
`TSerialization.Convert` never composes, so it refuses BSON -> XML under
`Lossless` with `TStructuralIssue.UnsupportedLosslessConversion`. See
[`../conversion.md`](../conversion.md).

## Contract-aware behavior

These depend on the Delphi type `T` (`Serialize<T>`, `Deserialize<T>`,
`TSerialization.Convert<T>`, `From<T>`):

- member names, `BsonName` and `BsonIgnore`;
- the representation choices: date/time, GUID, `Currency`;
- int32 versus int64 by the declared member type, not the value;
- `TDate` and `TTime` as text rather than instants;
- `TBsonObjectId` members (also read from 24-digit hex text);
- range checks into the member type (a value too large is `EBsonInputError`);
- `TNullable<T>` absence, sets, collections, dictionaries, `Variant`;
- custom serializers.

Without `T`, a structural conversion carries only what the dynamic tree
holds.

## Schema/context

None is needed. BSON is self-describing. The structural path works with no
schema in the conversion options.

The "schema" of `ToJsonWithSchema` / `FromJson(Json, Schema)` is not a
conversion schema. It is a separate JSON object mapping each path to its
MongoDB `$type` alias (`binData:NN` carries the subtype), so plain JSON can
be turned back into exact BSON.

## DataSet behavior

`TDataSetSerializer.CreateFDMemTable(Bytes, TSerializationFormat.Bson)` and
the other overloads that take a `TSerializationFormat` need the format
registered. The document is parsed into the dynamic tree and the schema is
inferred from it. See [`../dataset-formats.md`](../dataset-formats.md) and
[`../dataset-projection.md`](../dataset-projection.md).

| BSON element | Inferred field type |
| --- | --- |
| int32, or int64 whose value fits in 32 bits | `ftInteger` |
| int64 wider than 32 bits | `ftLargeint` |
| double | `ftFloat` |
| UTC datetime | `ftDateTime` |
| binary, subtype 0 | `ftBlob` |
| bool | `ftBoolean` |
| string, including ISO date text | `ftWideString` |
| binary with another subtype (a `TGUID`), ObjectId, decimal128, timestamp, other exotic types | `ftWideString` |
| document or array of documents | `ftDataSet` (nested) |

The inference sees values, not widths: an int64 element holding a small
value infers as `ftInteger`, and widens to `ftLargeint` when another row
needs it. A `TDate` written as ISO text is a string, so it infers as
`ftWideString`. Supply the contract
(`CreateFDMemTable<T>(Bytes, TSerializationFormat.Bson)`) for Delphi field
types. `TDataSetSerializer.Serialize(DataSet, TSerializationFormat.Bson,
Policy)` writes a DataSet packet as BSON.

## Custom serializers

Base classes in `PascalForge.Bson`:

- `TCustomBsonValueSerializer<T>`: override
  `SerializeValue(const AValue: T): TBsonValue` and
  `DeserializeValue(AValue: TBsonValue; const AExisting: T): T`. Use this one.
- `TCustomBsonValueSerializer`: the untyped base with `TValue` and
  `PTypeInfo`, for a type not known at compile time.

Registration:

```pascal
TBsonSerializer.RegisterTypeSerializer<TMoney>(TMoneyBsonSerializer);
```

Per member: `[BsonSerializer(TMoneyBsonSerializer)]`.

A custom serializer may return any `TBsonValue`, so it can use any element
type, decimal128 or timestamp included. The caller adopts the value it
returns. A read returns a new instance or the existing one it was given. See
[`../customization.md`](../customization.md) and
[`../deserialization-ownership.md`](../deserialization-ownership.md).

## Limits/security

| Limit | Value | Error |
| --- | --- | --- |
| write depth | 64 levels (each object, record, array, list, dictionary counts one) | `ESerializationLimitExceeded` |
| document nesting, read | 512 documents and arrays (`BSON_MAX_DEPTH`) | `EBsonInputError` |
| document nesting, `WriteDocument` | 512 (`BSON_MAX_DEPTH`), so it never writes what the reader refuses | `EBsonInternalError` |
| declared document length | checked against the buffer before anything is read or allocated; shorter than 5 bytes refused | `EBsonInputError` |
| string, binary, element bounds | checked against both the declared length and the buffer | `EBsonInputError` |
| code-with-scope length | checked against its contents | `EBsonInputError` |
| trailing bytes after the root | refused | `EBsonInputError` |
| undefined type byte | refused, naming the byte | `EBsonUnsupportedType` |
| invalid UTF-8 text | refused | `EBsonInputError` |

A `TBsonValue` tree built by hand much deeper than 512 levels (around 800)
overflows the stack when it is freed; see
[`../limitations.md`](../limitations.md). `tests\Robustness` covers nesting
bombs, huge lengths and truncation.

## Expected refusals

By design, not bugs:

- the refusals every format makes: pointers, procedural and method types,
  interfaces, class references, legacy `TList`, `TCollection`, streams,
  `Exception`, `TComponent`, cycles, inline static arrays, variant records,
  `TBcd` without a custom serializer;
- a value nested deeper than 64 levels;
- `UInt64` above `High(Int64)`: BSON has no unsigned 64-bit integer (a
  custom serializer can write decimal128 or text);
- a `TDateTime` or `TDate` outside the years 1 to 9999, on write;
- an unpaired UTF-16 surrogate in a string, on write;
- a `Variant` of a kind no format carries (see the shared list);
- a dictionary key with no text form, when the plan is built;
- a text payload given to the BSON handler.

BSON carries NaN and infinities, and scalar `Variant` values. See
[`../expected-refusals.md`](../expected-refusals.md).

## Interoperability evidence

`tests\BsonNative` uses the **BSON 1.1 specification's own byte vectors** as
the independent reference: the published `{"hello": "world"}` and
`{"BSON": ["awesome", 5.05, 1986]}` documents, one vector per element type
built from the specification's table, and the bson-corpus `subtype 0x04
UUID` vector (with its legacy subtype 3 case). Each vector is decoded and
checked, then re-encoded and compared byte for byte. No second BSON
implementation runs offline, so the oracle is the specification, not a
driver. `tests\BsonNative` also covers malformed input and every element
type.

`tests\BsonCore` checks the default contract, reading the bytes back to
confirm the element type actually written. `tests\BsonJson` checks the three
JSON routes, including Extended JSON and decimal128 text.

## Important implementation units

| Role | Unit |
| --- | --- |
| Facade | `src\PascalForge.Bson.pas` (`TBsonSerializer`, `TBsonValue`, `TBsonObjectId`, attributes) |
| Implementation | `src\PascalForge.Bson.Internal.pas` (`TBsonReader`, `TBsonWriter`, `TBsonEngine`: plans, RTTI walk, dynamic bridge, JSON schema) |
| Registration | `src\PascalForge.Bson.Registration.pas` (`TBsonSerializationRegistration`, `TBsonFormatHandler`) |
| Schema | none |
| Tests | `tests\BsonCore\BsonCore.dpr`, `tests\BsonCore\BsonModels.pas`, `tests\BsonNative\BsonNative.dpr`, `tests\BsonJson\BsonJson.dpr` |

## Before changing this format

1. Read [`../format-program.md`](../format-program.md),
   [`../bson-behavior.md`](../bson-behavior.md) and
   [`../bson-compatibility.md`](../bson-compatibility.md).
2. Run `tests\BsonCore`, `tests\BsonNative` and `tests\BsonJson`
   (`powershell -File scripts\test.ps1 -Only BsonNative`, and so on).
3. Run `tests\TypeCoverage` through `scripts\run-type-coverage.ps1`.
4. Run `tests\ReaderContracts`, `tests\ConversionMatrix` and
   `tests\Lifecycle`; for conversion changes also `tests\LosslessRouting`.
5. Do not change shared dynamic-model semantics (`TDynamicValue`, `TDynamicTag`,
   Core date and range helpers) from a format unit. Change Core deliberately,
   and retest every format.
6. A change to what BSON writes needs a test that pins the bytes and a
   documentation change.
7. Run `scripts\validate-release.ps1` before calling it finished.
