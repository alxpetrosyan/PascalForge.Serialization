# CBOR

## Purpose

This is the entry point for the CBOR format. It summarizes what the format
does and where the code is. For depth, read
[`../cbor-behavior.md`](../cbor-behavior.md). The API is in
[`../api-reference.md`](../api-reference.md).

CBOR is a real engine. A Delphi value is written straight to CBOR bytes and
read straight back. Nothing goes through JSON text, another format, or the
dynamic tree on the contract path. The natural payload type is `TBytes`.

## Standard/profile

- **RFC 8949 (STD 94)**, Concise Binary Object Representation.
- All eight major types, every argument width (immediate, 1, 2, 4 and 8
  bytes), and indefinite lengths for byte strings, text strings, arrays and
  maps.
- Half, single and double precision floats. Half precision is implemented
  by hand. A decoded float keeps its width and exact bits.
- Simple values 0-255, semantic tags, deterministic encoding (section 4.2)
  and well-formedness rules (section 5.6).
- Diagnostic notation (section 8) is written by `TCborValue.ToDiagnostic`.
  It is output only.

Not implemented: CBOR sequences (RFC 8742; one document per call), COSE,
CDDL, CBOR patching, and a diagnostic-notation parser.

## Public facade

Unit `PascalForge.Cbor`, class `TCborSerializer`. All methods are class
static.

| Method | Signature |
| --- | --- |
| `Serialize<T>` | `(const AValue: T): TBytes` |
| `Serialize<T>` | `(const AValue: T; const AOptions: TCborEncodeOptions): TBytes` |
| `Deserialize<T>` | `(const AData: TBytes): T` |
| `Populate<T>` | `(const AInstance: T; const AData: TBytes)` |
| `Encode` | `(AValue: TCborValue): TBytes`, and with `TCborEncodeOptions` |
| `Decode` | `(const AData: TBytes): TCborValue`, and with `TCborDecodeOptions`; the caller owns the result |
| `IsDeterministic` | `(const AData: TBytes): Boolean` |
| `From` | structural: `(ASource: string / TBytes / TSerializationPayload; AFrom: TSerializationFormat): TBytes`, and a payload overload with `TStructuralConversionProfile` |
| `From<T>` | contract-aware: the same source overloads |
| `ToDynamic` / `FromDynamic` | `(const ACbor: TBytes): TDynamicValue`, also with `TStructuralConversionOptions` / `(AValue: TDynamicValue): TBytes` - see [`../dynamic.md`](../dynamic.md) |

The general attributes apply - `[SerializationEnum]` to the text representation of an enumeration, not to `[CborEnumRepresentation(Value)]`; `[CborName]`, `[CborIgnore]` and `RegisterEnumMapping` beat them for CBOR. See [`../attributes.md`](../attributes.md).

Configuration (call at startup):

- `SetDateTimeRepresentation`, `RegisterDateTimeRepresentation<T>`,
  `RegisterFieldDateTimeRepresentation<T>`
- `RegisterEnumMapping<T>(const AValues: array of string)`
- `RegisterTypeSerializer<T>(ASerializerClass: TCborValueSerializerClass)`
- `SetDefaultEncodeOptions`, `DefaultEncodeOptions`
- `FreezeConfiguration`, `IsFrozen`, `ResetConfiguration` (for tests)

Configuration freezes automatically at the first real serializer operation
(`Serialize`, `Deserialize`, `Populate`, or the registry's typed calls).
After that, configuration is immutable and concurrent use is safe. A
registration made after the freeze raises `ECborInternalError` saying the
configuration is frozen. `FreezeConfiguration` freezes earlier, and
`IsFrozen` reports the state. See
[`../configuration-lifecycle.md`](../configuration-lifecycle.md) for the full
lifecycle.

Exceptions: `ECborError`, `ECborInputError` (the document is at fault) and
its subclasses, `ECborInternalError` (model or configuration), and
`ECborRangeError` (a valid CBOR integer the requested Delphi type cannot
hold).

## Explicit registry registration

```pascal
uses
  PascalForge.Cbor.Registration;
...
TCborSerializationRegistration.RegisterFormat;
```

- Linking or importing `PascalForge.Cbor.Registration` does **not** register
  the format.
- Loading the runtime package `PascalForge.Serialization.Runtime.bpl` does
  **not** register it.
- `RegisterFormat` is idempotent. It raises `ESerializationFormatConflict`
  if a different handler already holds `TSerializationFormat.Cbor`.
- `UnregisterFormat` is safe when the format is absent, and never removes
  another unit's handler.
- `IsRegistered` reports whether this unit's handler holds the format.

Direct `TCborSerializer` use needs no registration. Registration is needed
only for `TSerialization` (format chosen at run time), `TSerialization.Convert`,
and the `TDataSetSerializer` overloads that take a `TSerializationFormat`.

All formats at once: `TSerializationFormatsRegistration.RegisterAll` in unit
`PascalForge.Serialization.AllFormats`. It is also explicit.

Registry mutation happens at startup and shutdown. It must not run
concurrently with serialization.

## Native Delphi mappings

| Delphi | CBOR, by default |
| --- | --- |
| `Boolean` | major 7, `true` / `false` |
| integers of every width | major 0 or 1 |
| `UInt64` above `High(Int64)` | major 0 |
| `Single`, `Double`, `Extended` | major 7 float (`Extended` at `Double` precision) |
| `Currency` | tag 4, exponent -4, the scaled integer Delphi stores |
| `string` | major 3 (UTF-8) |
| `TBytes` | major 2 |
| `TDateTime` | tag 1, epoch seconds (integer when whole, double otherwise) |
| `TDate`, `TTime` | ISO 8601 text, untagged |
| `TGUID` | tag 37, 16 bytes in RFC 4122 order |
| enumeration | member name as text |
| set | array of member names |
| class, record | map with text keys |
| list, dynamic or static array | array |
| dictionary | map |
| `TNullable<T>` with no value | member omitted |
| `Variant` | the value it holds, as CBOR's own type |

Member attributes: `CborName`, `CborIgnore`, `CborDateTimeRepresentation`
(`EpochTagged`, `Rfc3339Tagged`, `UnixSeconds`, `UnixMilliseconds`,
`Iso8601Text`, `CustomString`), `CborGuidRepresentation` (`TaggedUuid`,
`LowercaseString`, `RawBytes`), `CborCurrencyRepresentation`
(`DecimalFraction`, `ScaledInt64`, `Double`, `DecimalString`),
`CborEnumRepresentation` (`Name`, `Value`), `CborSerializer`.

Dates and text:

- A `TDateTime` or `TDate` outside the years 1 to 9999 is refused on write.
- Tag 0 (RFC 3339) text with a zone offset is read as the instant it states,
  normalised to UTC. Tag 0 is written with `Z` and no other offset.
- A `CustomString` pattern is read back with the same pattern (numeric
  specifiers; `TStructuralText.TryDecodePattern`).
- A string with an unpaired UTF-16 surrogate is refused on write
  (`ESerializationUnsupported`), because UTF-8 cannot encode it.

Full detail: [`../cbor-behavior.md`](../cbor-behavior.md),
[`../datetime-policies.md`](../datetime-policies.md),
[`../delphi-type-coverage.md`](../delphi-type-coverage.md).

## Structural representation

CBOR is self-describing. It declares all four registry capabilities with no
schema. The handler reads bytes into `TCborValue` and maps it to
`TDynamicValue` (`TCborEngine.CborToDynamic`), and back
(`TCborEngine.DynamicToCbor`).

| CBOR | `TDynamicValue` |
| --- | --- |
| major 0 / 1 within `Int64` | `Int` |
| major 0 above `High(Int64)` | `UInt` |
| major 1 below `Low(Int64)` | `Extended`, tag `bigintnegative` |
| float | `Float` |
| text / bytes / bool / null | `Str` / `Bytes` / `Bool` / `Null` |
| array / map | `Arr` / `Obj` |
| tag 0, tag 1 | `DateTime` |
| tag 2, tag 3 | `Extended`, tags `bigint` / `bigintnegative` |
| tag 4 | `Decimal` (exact text) |
| tag 37 | `Str`, the 36-character GUID text |
| tag 32 | `Str` |
| tag 55799 | the content, unwrapped |
| any other tag | `Extended`, tag `cbortag`, object of `number` and `value` |
| simple value | `Extended`, tag `cborsimple` |
| undefined | `Extended`, tag `undefined` |

On the way back, `Date` and `Time` are written as ISO text, `DateTime` as
tag 1, `Decimal` as tag 4, `UInt` as major 0. An `Extended` value from
another format (for example a BSON ObjectId) is written as its payload
value.

A map key that is not text cannot keep its type in the dynamic tree, whose
member names are text. **Under `Natural`** it becomes its RFC 8949
diagnostic notation (`1`, `h'0102'`) - a documented adaptation, and the one
lossy step of the bridge. **`Strict`** refuses, because the key's type would
change, and **`Lossless`** refuses too - diagnostic text is never lossless,
and no destination reached through the dynamic tree can keep the key's own
type. Both raise `EStructuralConversionError` naming the key
(`$[1]`). The contract path, which knows the Delphi key type, reads such
keys exactly.

A text payload handed to the CBOR handler is refused with `ECborInputError`.
CBOR reads bytes only.

## Lossless behavior

CBOR's type system covers every dynamic kind, and a CBOR map key may be any
item. So there is no name to encode and no value to adapt when CBOR is the
destination. `Natural`, `Lossless` and `Strict` produce the same bytes.

When CBOR is the source, `Lossless` depends on the destination. The
destination decides what it can express, except for a non-text map key,
which `Lossless` and `Strict` refuse at the source (above). See
[`../conversion.md`](../conversion.md).

## Contract-aware behavior

These depend on the Delphi type `T` (`Serialize<T>`, `Deserialize<T>`,
`TSerialization.Convert<T>`, `From<T>`):

- member names, `CborName` and `CborIgnore`;
- the representation choices: date/time, GUID, `Currency`, enumeration;
- `TDate` and `TTime` as text rather than instants;
- range checks into the member type (a value too large raises the input
  error; `ECborRangeError` is raised by `TCborValue` accessors);
- `TNullable<T>` absence, sets, collections, dictionaries, `Variant`;
- custom serializers.

Without `T`, a structural conversion carries only what the dynamic tree
holds.

## Schema/context

None is needed. CBOR is self-describing. The structural path works with no
schema in the conversion options.

## DataSet behavior

`TDataSetSerializer.CreateFDMemTable(Bytes, TSerializationFormat.Cbor)` and
the other overloads that take a `TSerializationFormat` need the format
registered. The document is parsed into the dynamic tree and the schema is
inferred from it. See [`../dataset-formats.md`](../dataset-formats.md) and
[`../dataset-projection.md`](../dataset-projection.md).

| CBOR item | Inferred field type |
| --- | --- |
| integer within 32 bits | `ftInteger` |
| wider integer, or major 0 above `High(Int64)` | `ftLargeint` |
| float | `ftFloat` |
| tag 4 decimal fraction | `ftFloat` |
| tag 0 / tag 1 | `ftDateTime` |
| byte string | `ftBlob` |
| bool | `ftBoolean` |
| text, including ISO date text and tag 37 | `ftWideString` |
| map or array of maps | `ftDataSet` (nested) |

CBOR has no date-only or time-only item here. A `TDate` written as ISO text
is a string, so it infers as `ftWideString`. Supply the contract
(`CreateFDMemTable<T>(Bytes, TSerializationFormat.Cbor)`) for Delphi field
types. `TDataSetSerializer.Serialize(DataSet, TSerializationFormat.Cbor,
Policy)` writes a DataSet packet as CBOR.

## Custom serializers

Base classes in `PascalForge.Cbor`:

- `TCustomCborValueSerializer<T>`: override
  `SerializeValue(const AValue: T): TCborValue` and
  `DeserializeValue(AValue: TCborValue; const AExisting: T): T`. Use this one.
- `TCustomCborValueSerializer`: the untyped base with `TValue` and
  `PTypeInfo`, for a type not known at compile time.

Registration:

```pascal
TCborSerializer.RegisterTypeSerializer<TMoney>(TMoneyCborSerializer);
```

Per member: `[CborSerializer(TMoneyCborSerializer)]`.

The caller adopts the `TCborValue` a serializer returns. A read returns a new
instance or the existing one it was given. See
[`../customization.md`](../customization.md) and
[`../deserialization-ownership.md`](../deserialization-ownership.md).

## Limits/security

| Limit | Value | Error |
| --- | --- | --- |
| write depth | 64 levels (each object, record, array, list, dictionary counts one) | `ESerializationLimitExceeded` |
| read nesting | 256 (`CborDefaultMaxDepth`, `TCborDecodeOptions.MaxDepth`); arrays, maps and tags count | `ECborDepthExceeded` |
| tag 4 exponent | +/-6144 (`CborDecimalExponentLimit`), checked before any digit is built | `ECborInputError` |
| tag 5 exponent | +/-1024 (`CborBigfloatExponentLimit`); `TryAsDecimalText` returns False | - |
| declared length | checked against the bytes that remain, before allocation | `ECborTruncatedInput` |
| trailing bytes | refused unless `TCborDecodeOptions.AllowTrailingData` | `ECborTrailingData` |
| invalid UTF-8 text | refused | `ECborInvalidText` |
| reserved additional info 28-30 | refused | `ECborReservedAdditionalInfo` |

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
- a `Variant` of kind `varDispatch`, `varUnknown`, `varByRef`, `varError`,
  `varRecord`, a custom variant type, or a multi-dimensional array;
- a text payload given to the CBOR handler.

CBOR carries `UInt64` above `High(Int64)`, NaN and infinities, and scalar
`Variant` values. See [`../expected-refusals.md`](../expected-refusals.md).

## Interoperability evidence

`tests\CborNative` uses **RFC 8949 Appendix A** as the independent reference.
Every example vector is decoded and checked, then re-encoded and compared
byte for byte with the published hex. No reference implementation runs
offline, so the oracle is the specification's own table. The test also
covers every major type, argument form, simple values, known and unknown
tags, deterministic encoding and malformed input.

## Important implementation units

| Role | Unit |
| --- | --- |
| Facade | `src\PascalForge.Cbor.pas` |
| Implementation | `src\PascalForge.Cbor.Internal.pas` (`TCborEngine`: reader, writer, RTTI walk, dynamic bridge) |
| Registration | `src\PascalForge.Cbor.Registration.pas` (`TCborSerializationRegistration`, `TCborFormatHandler`) |
| Schema | none |
| Tests | `tests\CborNative\CborNative.dpr`, `tests\CborNative\CborModels.pas` |

## Before changing this format

1. Read [`../format-program.md`](../format-program.md) and
   [`../cbor-behavior.md`](../cbor-behavior.md).
2. Run `tests\CborNative`
   (`powershell -File scripts\test.ps1 -Only CborNative`).
3. Run `tests\TypeCoverage` through `scripts\run-type-coverage.ps1`.
4. Run `tests\ReaderContracts`, `tests\ConversionMatrix` and
   `tests\Lifecycle`.
5. Do not change shared dynamic-model semantics (`TDynamicValue`, `TDynamicTag`,
   Core date and range helpers) from a format unit. Change Core deliberately,
   and retest every format.
6. A change to what CBOR writes needs a test that pins the bytes and a
   documentation change.
7. Run `scripts\validate-release.ps1` before calling it finished.
