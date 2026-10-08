# MessagePack

## Purpose

This is the entry point for the MessagePack format. It summarizes what the
format does and where the code is. For depth, read
[`../messagepack-behavior.md`](../messagepack-behavior.md). The API is in
[`../api-reference.md`](../api-reference.md).

MessagePack is a real engine. A Delphi value is written straight to
MessagePack bytes and read straight back. Nothing goes through JSON text,
another format, or the dynamic tree on the contract path. The natural payload
type is `TBytes`. There is no base64 API.

## Standard/profile

- **The MessagePack specification** (`msgpack/msgpack`, `spec.md`), the
  current form in which `str` and `bin` are separate families.
- Every format family: positive and negative fixint, `uint 8/16/32/64`,
  `int 8/16/32/64`, `float 32/64`, `nil`, `false`, `true`, fixstr and
  `str 8/16/32`, `bin 8/16/32`, fixarray and `array 16/32`, fixmap and
  `map 16/32`, `fixext 1/2/4/8/16` and `ext 8/16/32`.
- The timestamp extension, type -1
  (`MessagePackTimestampExtensionType`), in all three encodings:
  timestamp 32, 64 and 96. The writer picks the smallest encoding that is
  exact. The reader takes any of them.
- Shortest form on write, any form on read. One exception: a `Single` is
  written as `float 32`, and a `float 32` keeps its kind when read.
- `str` is validated UTF-8. `0xc1` ("never used") is refused by name.

Not implemented: the old raw family, in which text and binary were one type.
Its bytes (`0xd9`-`0xdb` and fixstr) are read as `str`, which is what they
mean now. A document that used them for binary fails UTF-8 validation rather
than producing mojibake. A buffer holds one value; concatenated value streams
are not read.

## Public facade

Unit `PascalForge.MessagePack`, class `TMessagePackSerializer`. All methods
are class static.

| Method | Signature |
| --- | --- |
| `Serialize<T>` | `(const AValue: T): TBytes` |
| `Deserialize<T>` | `(const AData: TBytes): T` |
| `Populate<T>` | `(const AInstance: T; const AData: TBytes)` |
| `Parse` | `(const AData: TBytes): TMessagePackValue`; the caller owns the result |
| `Write` | `(AValue: TMessagePackValue): TBytes` |
| `From` | structural: `(ASource: string / TBytes / TSerializationPayload; AFrom: TSerializationFormat): TBytes`, and a payload overload with `TStructuralConversionProfile` |
| `From<T>` | contract-aware: the same source overloads |
| `ToDynamic` / `FromDynamic` | `(const AData: TBytes): TDynamicValue` / `(AValue: TDynamicValue): TBytes`, each also with `TStructuralConversionOptions` - see [`../dynamic.md`](../dynamic.md) |

The general attributes apply - `[SerializationEnum]` to the name representation of an enumeration, not the ordinal one; `[MessagePackName]`, `[MessagePackIgnore]` and `RegisterEnumMapping` beat them for MessagePack. See [`../attributes.md`](../attributes.md).

There is no options record and no `Serialize` overload that takes one. There
is no `TryDeserialize`. The root is any value, not only a map, so an
`Integer` serializes to one byte.

Configuration (call at startup):

- `SetDateTimeRepresentation` (a representation or a pattern),
  `RegisterDateTimeRepresentation<T>`,
  `RegisterFieldDateTimeRepresentation<T>`
- `RegisterEnumMapping<T>(const AValues: array of string)`
- `RegisterTypeSerializer<T>(ASerializerClass: TMessagePackValueSerializerClass)`
- `FreezeConfiguration`, `IsFrozen`, `ResetConfiguration` (for tests)

Configuration freezes automatically at the first real serializer operation
(`Serialize`, `Deserialize`, `Populate`, or the registry's typed calls).
After that, configuration is immutable and concurrent use is safe. A
registration made after the freeze raises `EMessagePackInternalError` saying
the configuration is frozen. `FreezeConfiguration` freezes earlier, and
`IsFrozen` reports the state. See
[`../configuration-lifecycle.md`](../configuration-lifecycle.md) for the full
lifecycle.

Exceptions: `EMessagePackError`, `EMessagePackInputError` (the document is at
fault) and its subclasses `EMessagePackReservedByte`,
`EMessagePackInvalidUtf8` and `EMessagePackDepthExceeded`, and
`EMessagePackInternalError` (model or configuration).

## Explicit registry registration

```pascal
uses
  PascalForge.MessagePack.Registration;
...
TMessagePackSerializationRegistration.RegisterFormat;
```

- Linking or importing `PascalForge.MessagePack.Registration` does **not**
  register the format.
- Loading the `PascalForge.Serialization.Runtime` package
  does **not** register it.
- `RegisterFormat` is idempotent. It raises `ESerializationFormatConflict`
  if a different handler already holds `TSerializationFormat.MessagePack`.
- `UnregisterFormat` is safe when the format is absent, and never removes
  another unit's handler.
- `IsRegistered` reports whether this unit's handler holds the format.

Direct `TMessagePackSerializer` use needs no registration. Registration is
needed only for `TSerialization` (format chosen at run time),
`TSerialization.Convert`, and the `TDataSetSerializer` overloads that take a
`TSerializationFormat`.

All formats at once: `TSerializationFormatsRegistration.RegisterAll` in unit
`PascalForge.Serialization.AllFormats`. It is also explicit.

Registry mutation happens at startup and shutdown. It must not run
concurrently with serialization.

## Native Delphi mappings

| Delphi | MessagePack, by default |
| --- | --- |
| `Boolean` | `true` / `false` |
| integers of every width | the shortest int or uint family that holds the value |
| `UInt64` above `High(Int64)` | `uint 64` |
| `Single` | `float 32` |
| `Double`, `Extended` | `float 64` (`Extended` at `Double` precision) |
| `Currency` | the scaled `Int64` Delphi stores (value times 10 000), as an integer |
| `string` | `str` (UTF-8) |
| `TBytes` | `bin` |
| `TDateTime` | timestamp extension -1 |
| `TDate`, `TTime` | ISO 8601 `str` |
| `TGUID` | the lower-case 36-character `str` |
| enumeration | member name as `str` |
| set | array of member names |
| class, record | map with `str` keys |
| list, dynamic or static array | array |
| dictionary | map; the key keeps its own type (an `Integer` key is an integer) |
| `TNullable<T>` with no value | member omitted |
| `Variant` | the value it holds, as MessagePack's own type |

Member attributes: `MessagePackName`, `MessagePackIgnore`,
`MessagePackDateTimeRepresentation` (`Timestamp`, `StringIso8601`,
`UnixSeconds`, `UnixMilliseconds`, `CustomString`),
`MessagePackGuidRepresentation` (`LowercaseString`, `Bin`),
`MessagePackCurrencyRepresentation` (`ScaledInt64`, `Float64`,
`DecimalString`), `MessagePackEnumRepresentation` (`Name`, `Ordinal`),
`MessagePackSerializer`.

`TGUID` as `Bin` is the 16 bytes of the `TGUID` record as Delphi holds it in
memory, read back the same way. `Currency` as `Float64` is lossy past fifteen
significant digits.

Dates and text:

- A `TDateTime` or `TDate` outside the years 1 to 9999 is refused on write
  (`ESerializationUnsupported`), in every representation.
- A timestamp resolves to the millisecond: `TDateTime` has no finer
  resolution, so the written nanoseconds are a multiple of one million. An
  instant before the epoch borrows a second, so the nanosecond field is
  never negative.
- Where `Timestamp` is configured, a read also accepts an integer or float
  count of Unix seconds.
- ISO 8601 text with a zone offset is read by its wall-clock fields; the
  offset is ignored. No offset is ever written.
- A `CustomString` pattern is read back with the same pattern (numeric
  specifiers; `TStructuralText.TryDecodePattern`), then with the RTL's
  invariant date reading.
- A string with an unpaired UTF-16 surrogate is refused on write
  (`ESerializationUnsupported`), because UTF-8 cannot encode it.

Full detail: [`../messagepack-behavior.md`](../messagepack-behavior.md),
[`../datetime-policies.md`](../datetime-policies.md),
[`../delphi-type-coverage.md`](../delphi-type-coverage.md).

## Structural representation

MessagePack is self-describing. It declares all four registry capabilities
with no schema. The handler reads bytes into `TMessagePackValue` and maps it
to `TDynamicValue` (`TMessagePackEngine.MessagePackToDynamic`), and back
(`TMessagePackEngine.DynamicToMessagePack`).

| MessagePack | `TDynamicValue` |
| --- | --- |
| int / uint within `Int64` | `Int` |
| `uint 64` above `High(Int64)` | `UInt` |
| `float 32` / `float 64` | `Float` |
| `str` / `bin` / bool / `nil` | `Str` / `Bytes` / `Bool` / `Null` |
| array / map | `Arr` / `Obj` |
| timestamp extension -1 | `DateTime` |
| timestamp outside the `TDateTime` years | `Extended`, tag `msgpackextension` (kept as the raw extension) |
| any other extension | `Extended`, tag `msgpackextension`, object of `type` (`Int`) and `data` (`Bytes`) |

On the way back, `DateTime` is written as the timestamp extension, `Date`
and `Time` as ISO text, `UInt` as `uint 64`, `Float` as `float 64`, and a
`msgpackextension` value as the extension it names (a `type` outside
-128..127 is refused). `Decimal` is written as its digits in a `str` under
`Natural`. An `Extended` value from another format (for example a BSON
ObjectId) is written as its payload under `Natural` when that payload is a
string, bytes or null.

A map key that is not a `str` has no name in the dynamic tree. Under the
`Encode` name policy (`Natural`, `Lossless`) an integer, boolean or `nil` key
is rendered as text. Under `Error` (`Strict`) it is refused with the path. A
float, `bin`, array or map key is refused under either policy. This is the
one lossy step of the bridge.

A text payload handed to the MessagePack handler is refused with
`EMessagePackInputError`. MessagePack reads bytes only.

## Lossless behavior

When MessagePack is the destination, every dynamic kind but two has a native
type. The two decisions:

| Tree value | `Natural` | `Lossless` | `Strict` |
| --- | --- | --- | --- |
| `Decimal` | the digits as `str` | refused: no decimal type, a float would round | refused |
| `Extended` from another format | its payload value | refused: no published extension number for it | refused |

Member names need no encoding: any string is a valid map key.

When MessagePack is the source, `Lossless` refuses a timestamp whose
fraction is finer than a millisecond, because the dynamic `DateTime` cannot
hold it. Otherwise the destination decides what it can express. See
[`../conversion.md`](../conversion.md).

## Contract-aware behavior

These depend on the Delphi type `T` (`Serialize<T>`, `Deserialize<T>`,
`TSerialization.Convert<T>`, `From<T>`):

- member names, `MessagePackName` and `MessagePackIgnore`;
- the representation choices: date/time, GUID, `Currency`, enumeration;
- `TDate` and `TTime` as text rather than instants;
- `Single` as `float 32` rather than `float 64`;
- range checks into the member type (a value too large raises
  `EMessagePackInputError`; a float is read as an integer only when it is
  integral);
- `TNullable<T>` absence, sets, collections, dictionaries with typed keys,
  `Variant`;
- custom serializers.

Without `T`, a structural conversion carries only what the dynamic tree
holds.

## Schema/context

None is needed. MessagePack is self-describing. The structural path works
with no schema in the conversion options.

## DataSet behavior

`TDataSetSerializer.CreateFDMemTable(Bytes, TSerializationFormat.MessagePack)`
and the other overloads that take a `TSerializationFormat` need the format
registered. The document is parsed into the dynamic tree and the schema is
inferred from it. See [`../dataset-formats.md`](../dataset-formats.md) and
[`../dataset-projection.md`](../dataset-projection.md).

| MessagePack item | Inferred field type |
| --- | --- |
| integer within 32 bits | `ftInteger` |
| wider integer, or `uint 64` above `High(Int64)` | `ftLargeint` |
| `float 32` / `float 64` | `ftFloat` |
| timestamp extension -1 | `ftDateTime` |
| `bin` | `ftBlob` |
| bool | `ftBoolean` |
| `str`, including ISO date text and GUID text | `ftWideString` |
| any other extension | `ftWideString` |
| map or array of maps | `ftDataSet` (nested) |

MessagePack has no date-only or time-only item. A `TDate` written as ISO
text is a string, so it infers as `ftWideString`. A `Currency` written as the
scaled integer infers as an integer, not as money. Supply the contract
(`CreateFDMemTable<T>(Bytes, TSerializationFormat.MessagePack)`) for Delphi
field types. `TDataSetSerializer.Serialize(DataSet,
TSerializationFormat.MessagePack, Policy)` writes a DataSet packet as
MessagePack.

## Custom serializers

Base classes in `PascalForge.MessagePack`:

- `TCustomMessagePackValueSerializer<T>`: override
  `SerializeValue(const AValue: T): TMessagePackValue` and
  `DeserializeValue(AValue: TMessagePackValue; const AExisting: T): T`. Use
  this one.
- `TCustomMessagePackValueSerializer`: the untyped base with `TValue` and
  `PTypeInfo`, for a type not known at compile time.

Registration:

```pascal
TMessagePackSerializer.RegisterTypeSerializer<TMoney>(TMoneyMsgPackSerializer);
```

Per member: `[MessagePackSerializer(TMoneyMsgPackSerializer)]`.

The caller adopts the `TMessagePackValue` a serializer returns. A read
returns a new instance or the existing one it was given. See
[`../customization.md`](../customization.md) and
[`../deserialization-ownership.md`](../deserialization-ownership.md).

## Limits/security

| Limit | Value | Error |
| --- | --- | --- |
| write depth | 64 levels (each object, record, array, list, dictionary counts one) | `ESerializationLimitExceeded` |
| read nesting | 512 (`MessagePackMaxDepth`, a constant); arrays and maps count | `EMessagePackDepthExceeded` |
| declared length | checked against the bytes that remain, before allocation | `EMessagePackInputError` |
| element count | checked against the bytes that remain (at least 1 byte per array element, 2 per map entry) | `EMessagePackInputError` |
| trailing bytes | refused; one buffer is one value | `EMessagePackInputError` |
| empty buffer | refused | `EMessagePackInputError` |
| byte `0xc1` | refused, with the offset | `EMessagePackReservedByte` |
| invalid UTF-8 in a `str` | refused, with the offset and the reason | `EMessagePackInvalidUtf8` |
| timestamp not 4, 8 or 12 bytes, or nanoseconds of one second or more | refused | `EMessagePackInputError` |

`tests\Robustness` covers nesting bombs, huge lengths and truncation.

## Expected refusals

By design, not bugs:

- the refusals every format makes: pointers, procedural and method types,
  interfaces, class references, legacy `TList`, `TCollection`, streams,
  `Exception`, `TComponent`, cycles, inline static arrays, variant records,
  `TBcd` without a custom serializer;
- a value nested deeper than 64 levels;
- a `TDateTime` or `TDate` outside the years 1 to 9999, on write;
- an unpaired UTF-16 surrogate in a string, on write;
- a `Variant` the shared Variant bridge refuses (for example `varDispatch`,
  `varUnknown`);
- a text payload given to the MessagePack handler;
- in structural conversion, a non-`str` map key under `Strict`, and a
  `Decimal` or foreign `Extended` value under `Lossless` or `Strict`.

MessagePack carries `UInt64` above `High(Int64)`, NaN and infinities, and
scalar `Variant` values. See
[`../expected-refusals.md`](../expected-refusals.md).

## Interoperability evidence

`tests\MessagePackNative` uses **the specification's format table** as the
independent reference. The program's header names the target
(`msgpack/msgpack` `spec.md`). A ledger of first bytes walks the table
family by family, including `0xc1`, all extension widths, all three
timestamp encodings, and the boundaries between integer widths. Byte
sequences that can be computed by hand from the table are written in hex and
compared literally. No reference implementation runs offline, so the oracle
is the document. The test also covers malformed input, the contract, the
conversion matrix, DataSet projection, dates before the Delphi epoch, the
date range, read-failure ownership, unpaired surrogates and writer levels.

## Important implementation units

| Role | Unit |
| --- | --- |
| Facade | `src\PascalForge.MessagePack.pas` (`TMessagePackSerializer`, `TMessagePackValue`, attributes, exceptions) |
| Implementation | `src\PascalForge.MessagePack.Internal.pas` (`TMessagePackReader`, `TMessagePackWriter`, `TMessagePackEngine`: plans, RTTI walk, dynamic bridge) |
| Registration | `src\PascalForge.MessagePack.Registration.pas` (`TMessagePackSerializationRegistration`, `TMessagePackFormatHandler`) |
| Schema | none |
| Tests | `tests\MessagePackNative\MessagePackNative.dpr`, `tests\MessagePackNative\MsgPackModels.pas` |

## Before changing this format

1. Read [`../format-program.md`](../format-program.md) and
   [`../messagepack-behavior.md`](../messagepack-behavior.md).
2. Run `tests\MessagePackNative`
   (`powershell -File scripts\test.ps1 -Only MessagePackNative`).
3. Run `tests\TypeCoverage` through `scripts\run-type-coverage.ps1`.
4. Run `tests\ReaderContracts`, `tests\ConversionMatrix` and
   `tests\Lifecycle`.
5. Do not change shared dynamic-model semantics (`TDynamicValue`, `TDynamicTag`,
   Core date and range helpers) from a format unit. Change Core deliberately,
   and retest every format.
6. A change to what MessagePack writes needs a test that pins the bytes and a
   documentation change.
7. Run `scripts\validate-release.ps1` before calling it finished.
