# JSON

## Purpose

This is the entry point for the JSON format. It summarizes what the format
does and where the code is. For depth, read
[`../serializer-behavior.md`](../serializer-behavior.md) (what JSON writes for
a Delphi type) and [`../customization.md`](../customization.md) (the developer
API map). The API is in [`../api-reference.md`](../api-reference.md), whose
first sections are mostly about JSON.

JSON is a real engine. A Delphi value is written straight to JSON text and
read straight back. Nothing goes through another format or the dynamic tree
on the contract path. The natural payload type is `string`. `SerializeUtf8`
returns UTF-8 `TBytes`.

## Standard/profile

- **RFC 8259**, the JSON data interchange format. This is the target
  [`../format-program.md`](../format-program.md) and
  [`../limitations.md`](../limitations.md) name.
- Text is parsed by the RTL (`System.JSON`, `TJSONObject.ParseJSONValue`).
  The library renders its own text, because `TJSONValue.ToJSON` escapes all
  non-ASCII and `ToString` leaves control characters raw, which is not valid
  JSON.
- Only what JSON requires is escaped: the quote, the backslash and characters
  below `U+0020`. `TJsonUnicodeEscapePolicy.EscapeNonAscii` also escapes
  everything above `U+007F` (a surrogate pair as two groups).
- UTF-8 is the only byte encoding offered. No BOM is written. A leading BOM
  is accepted on read.

Not implemented: JSON Schema, JSON Pointer and Patch, JSON Lines (one
document per call), comments, and a polymorphic discriminator on read.

## Public facade

Unit `PascalForge.Json`, class `TJsonSerializer`. All methods are class
static.

| Method | Signature |
| --- | --- |
| `Serialize<T>` | `(const AInstance: T): string`, and with `const AOptions: TJsonSerializationOptions` |
| `SerializeUtf8<T>` | `(const AInstance: T): TBytes`, and with `TJsonSerializationOptions`; no BOM |
| `Deserialize<T>` | `(const AJson: string): T` |
| `DeserializeUtf8<T>` | `(const AJson: TBytes): T`; a BOM is accepted, malformed UTF-8 raises `EInvalidUtf8` |
| `DeserializeValue<T>` | `(const AJson: TJSONValue): T` |
| `TryDeserialize<T>` | `(const AJson: string; out AValue: T; AHandledErrors: TJsonDeserializationErrors = [InvalidJson]): Boolean`, and with `out AError: string` |
| `Populate` | `(const AInstance: TObject; const AJson: string)`, and with `const AJson: TJSONValue` |
| `ToJson` / `ToJsonString` | `(const AInstance: TObject): TJSONObject` / `string` |
| `From` | structural: `(ASource: string / TBytes / TSerializationPayload; AFrom: TSerializationFormat): string`, and payload overloads with `TStructuralConversionProfile` and with a `TJsonUnicodeEscapePolicy` |
| `From<T>` | contract-aware: the same three source overloads |
| `ToDynamic` / `FromDynamic` | `(const AJson: string): TDynamicValue` / `(AValue: TDynamicValue): string`, each also with `TStructuralConversionOptions` - see [`../dynamic.md`](../dynamic.md) |

The general attributes (`[SerializationName]`, `[SerializationIgnore]`, `[SerializationEnum]`) apply; `[JsonName]`, a registered rename, `[JsonIgnore]` and `RegisterEnumMapping`/`RegisterFieldEnumMapping` beat them for JSON. A general name is used verbatim - JSON's naming strategy is not applied to it. See [`../attributes.md`](../attributes.md).

`TJsonSerializationOptions` (per call, never frozen): `PropertyReadErrorPolicy`
(`RaiseError`, `SkipMember`, `WriteNull`), `UnicodeEscape`, and
`MaxOutputBytes` (0, unlimited, by default; past it
`EJsonSerializationLimitExceeded` with `Limit`, `Estimated`, `Path`).

`TryDeserialize` turns only the named categories into `False`:
`InvalidJson` (the default) and `TypeMismatch`. A constructor failure, a
custom serializer bug or an internal error still propagates. There is no
`TryPopulate`.

Configuration (call at startup):

- `RegisterFieldOverride<T>` (and by `TClass`, `PTypeInfo`, qualified name),
  `RegisterClassFieldOverride`, `RegisterUnitFieldOverride`
- `RegisterUnitNaming`, `RegisterClassNaming` (`TJsonNaming.DefaultStyle`,
  `SnakeCase`)
- `RegisterTypeSerializer<T>` (class, `<T, TSer>`, delegates),
  `RegisterGenericTypeSerializer`, `RegisterClassTypeSerializer`,
  `RegisterUnitClassTypeSerializer`, `RegisterOpaqueClass`,
  `RegisterSerializationSurface`
- `SetDefaultMemberStrategy`, `RegisterTypeMemberStrategy`
- `SetDefaultRecursiveReferencePolicy`, `RegisterTypeRecursiveReferencePolicy`
- `SetDateTimeFormat`, `RegisterDateTimeFormat<T>`,
  `RegisterFieldDateTimeFormat<T>`
- `RegisterEnumMapping<T>`, `RegisterFieldEnumMapping`
- `RegisterClassFactory<T>`, `RegisterTypeUnit`
- `FreezeConfiguration`, `IsFrozen`

Configuration freezes automatically at the first real serializer operation
(`Serialize`, `Deserialize`, `Populate`, `TryDeserialize`, or the registry's
typed calls). After that, configuration is immutable and concurrent use is
safe. A registration made after the freeze raises `EJsonError` saying the
JSON serializer configuration is frozen. `FreezeConfiguration` freezes
earlier, and `IsFrozen` reports the state. See
[`../configuration-lifecycle.md`](../configuration-lifecycle.md) for the full
lifecycle.

Exceptions: `EJsonError`, `EJsonInputError` (the document is at fault; what
`TryDeserialize` may absorb), `EJsonInternalError` (model, configuration or a
wrapped failure; always propagates), and `EJsonSerializationLimitExceeded`
(the output budget).

## Explicit registry registration

```pascal
uses
  PascalForge.Json.Registration;
...
TJsonSerializationRegistration.RegisterFormat;
```

- Linking or importing `PascalForge.Json.Registration` does **not** register
  the format.
- Loading the runtime package `PascalForge.Serialization.Runtime.bpl` does
  **not** register it.
- `RegisterFormat` is idempotent. It raises `ESerializationFormatConflict`
  if a different handler already holds `TSerializationFormat.Json`.
- `UnregisterFormat` is safe when the format is absent, and never removes
  another unit's handler.
- `IsRegistered` reports whether this unit's handler holds the format.

Direct `TJsonSerializer` use needs no registration. Registration is needed
only for `TSerialization` (format chosen at run time), `TSerialization.Convert`,
the `TDataSetSerializer` overloads that take a `TSerializationFormat`, and
other formats that reach JSON through the registry (BSON's six JSON methods,
CSV's `JsonCell` modes).

All formats at once: `TSerializationFormatsRegistration.RegisterAll` in unit
`PascalForge.Serialization.AllFormats`. It is also explicit.

Registry mutation happens at startup and shutdown. It must not run
concurrently with serialization.

## Native Delphi mappings

| Delphi | JSON, by default |
| --- | --- |
| `Boolean` (and `ByteBool`, `WordBool`, `LongBool`) | `true` / `false` |
| integers of every width, `UInt64` included | number, with the sign the type gives it |
| `Single`, `Double`, `Extended` | number (`Extended` at `Double` precision) |
| `Currency` | number, the exact decimal text (at most four fractional digits) |
| `string` | string |
| `TDate` | `"2026-03-14"` |
| `TTime` | `"17:30:00"`, milliseconds added when there are any |
| `TDateTime` | ISO 8601 string, **no** offset |
| `TGUID` | lower-case canonical string, no braces |
| enumeration | member name (or the registered mapping) as a string |
| set | comma-joined string of member names; the empty set is `""` |
| class, record | object |
| list, dynamic or static array | array |
| dictionary | object; keys by the primitive rules (string, enumeration name, integer) |
| `TNullable<T>` with no value, `nil` object or container | member omitted |
| `Variant` | the value it holds, through the dynamic tree (a date as ISO text) |

Member names: the Delphi name with a lower-cased first character, unless
`[JsonName]`, a field override or a naming registration says otherwise.
Unknown members are ignored on read.

Member attributes: `JsonName`, `JsonIgnore`, `JsonSerializer`,
`JsonDateTimeFormat` (`Iso8601`, `UnixSeconds`, `UnixMilliseconds`, `Custom`,
or a pattern).

Dates and text:

- `TDateTime` is written as ISO 8601 with no offset, because it carries none.
  Text with an offset is read as the instant it states, normalised to UTC
  (`TStructuralText.DecodeIso8601`). Text without one is taken as written.
- `UnixSeconds` is the second the instant falls in, by floor (half a second
  before the epoch is -1). `UnixMilliseconds` is the millisecond count. Both
  are JSON numbers.
- A `Custom` pattern is read back with the same pattern (numeric specifiers;
  `TStructuralText.TryDecodePattern`).
- A `TDateTime` or `TDate` outside the years 1 to 9999 is refused on write
  (`ESerializationUnsupported`), in every representation.
- A string with an unpaired UTF-16 surrogate is written as a `\uXXXX`
  escape, whatever the escape policy, so the document stays valid UTF-8.

Full detail: [`../serializer-behavior.md`](../serializer-behavior.md),
[`../datetime-policies.md`](../datetime-policies.md),
[`../unicode-and-utf8.md`](../unicode-and-utf8.md),
[`../delphi-type-coverage.md`](../delphi-type-coverage.md).

## Structural representation

JSON is self-describing. It declares all four registry capabilities with no
schema. The handler parses text into `TJSONValue` and maps it to
`TDynamicValue` (`TJsonEngine.JsonToDynamic`), and back
(`TJsonEngine.DynamicToJson`). A binary payload is decoded as UTF-8, so
`TBytes` is a valid JSON source.

| JSON | `TDynamicValue` |
| --- | --- |
| number, integral within `Int64` | `Int` |
| number, integral above `High(Int64)` | `UInt` |
| any other number | `Float` (correctly rounded) |
| string / true, false / null | `Str` / `Bool` / `Null` |
| array / object | `Arr` / `Obj`, member names exactly as spelled |

A string is never inspected: `"2026-09-14"` stays `Str`. `$oid`, `$type` and
`_x0024_type` are ordinary member names.

On the way back, `Decimal` is a number, `UInt` its digits, and the kinds JSON
lacks depend on the profile:

| dynamic kind | `Natural` | `Lossless` | `Strict` |
| --- | --- | --- | --- |
| `Bytes` | base64 string | `{"$binary": {"base64": ..., "subType": "00"}}` | refused |
| `DateTime` | ISO 8601 string | `{"$date": {"$numberLong": "..."}}` | refused |
| `Date`, `Time` | ISO reduced form | refused (Extended JSON has no form) | refused |
| NaN, infinity | refused | `{"$numberDouble": "..."}` | refused |
| `Extended` (ObjectId, timestamp, decimal128, ...) | idiomatic text or `null` | its Extended JSON form | refused |

A refusal is `EStructuralConversionError` with the member path.

## Lossless behavior

`Lossless` means a published standard for the pair, or a refusal naming the
route that works. There is no private wrapper or metadata member.

| Pair | `Lossless` |
| --- | --- |
| BSON -> JSON | MongoDB Extended JSON (`$oid`, `$date`, `$binary`, `$numberDecimal`, `$numberDouble`, `$timestamp`, ...) |
| JSON -> BSON | MongoDB Extended JSON, read back; `$uuid` is read as binary subtype 4 |
| JSON -> XML | the W3C JSON/XML mapping (`fn:json-to-xml`, namespace `http://www.w3.org/2005/xpath-functions`) |
| XML -> JSON | the same mapping, read back |
| BSON <-> XML | composed through JSON: Extended JSON, then the W3C mapping |

Extended JSON is recognized only under `Lossless` **and** with BSON as the
destination. Elsewhere, `{"$oid": ...}` is an object with a member called
`$oid`. A malformed `$uuid` is refused (`EJsonInputError`). See
[`../conversion.md`](../conversion.md).

## Contract-aware behavior

These depend on the Delphi type `T` (`Serialize<T>`, `Deserialize<T>`,
`TSerialization.Convert<T>`, `From<T>`):

- member names, `JsonName`, `JsonIgnore`, naming registrations, member
  strategy (`PublicSurface`, `FieldsOnly`, `PropertiesOnly`, `AllRTTI`);
- the date/time format, enumeration mappings, sets;
- `TDate`, `TTime` and `TGUID` as text rather than strings of no meaning;
- range checks into the member type (a value too large is
  `EJsonInputError`);
- `TNullable<T>` absence, collections, dictionaries, `Variant`;
- construction (parameterless constructor, a discovered one, or
  `RegisterClassFactory<T>`) and in-place reuse on `Populate`;
- custom serializers and the recursion policy.

Without `T`, a structural conversion carries only what the dynamic tree
holds.

## Schema/context

None is needed. JSON is self-describing. The structural path works with no
schema in the conversion options.

## DataSet behavior

`TDataSetSerializer.CreateFDMemTable(Json, TSerializationFormat.Json)` and
the other overloads that take a `TSerializationFormat` need the format
registered. The document is parsed into the dynamic tree and the schema is
inferred from it. See [`../dataset-formats.md`](../dataset-formats.md) and
[`../dataset-projection.md`](../dataset-projection.md).

| JSON value | Inferred field type |
| --- | --- |
| integer within 32 bits | `ftInteger` |
| wider integer | `ftLargeint` |
| other number (a `Currency` or BCD included) | `ftFloat` |
| `true` / `false` | `ftBoolean` |
| string, including ISO date text, GUID text and base64 | `ftWideString` |
| object or array of objects | `ftDataSet` (nested) |

JSON states no dates and no binary, so width and Delphi type are lost. Supply
the contract (`CreateFDMemTable<T>(Json, TSerializationFormat.Json)`) for
Delphi field types. `TDataSetSerializer.Serialize(DataSet,
TSerializationFormat.Json, Policy)` writes a DataSet packet as JSON.

A `TDataSet` **member** inside a JSON object graph is a different job:
`uses PascalForge.DataSet.Json`, then call `TDataSetJsonIntegration.Register`
once at startup. Its policies and `DataSetFactory` freeze when JSON or
DataSet configuration freezes. `PascalForge.DataSet.Json` is TDataSet **as**
JSON; do not confuse it with `TDataSetSerializer`.

## Custom serializers

Base classes in `PascalForge.Json`:

- `TCustomJsonValueSerializer<T>`: override
  `SerializeValue(const AValue: T): TJSONValue` and
  `DeserializeValue(const AJson: TJSONValue): T`, and optionally
  `DeserializeInto(const AJson: TJSONValue; AExisting: T): Boolean`. Use this
  one.
- `TCustomJsonValueSerializer`: the untyped base with `TValue` and
  `PTypeInfo` (plus the `...Context` overrides), for a type not known at
  compile time or a generic family.

Registration:

```pascal
TJsonSerializer.RegisterTypeSerializer<TMoney, TMoneyJsonSerializer>;
TJsonSerializer.RegisterTypeSerializer<TMoney>(MoneyToJson, MoneyFromJson);
```

Per member: `[JsonSerializer(TMoneyJsonSerializer)]`, or
`TJsonFieldOverride.SerializeWith<T>` / `DeserializeWith<T>` (one direction
only; the other keeps the built-in behaviour). Precedence is documented above
`RegisterTypeSerializer` in `PascalForge.Json.pas`. Delegates must be
stateless. `DeserializeInto` never frees `AExisting`. See
[`../customization.md`](../customization.md) and
[`../deserialization-ownership.md`](../deserialization-ownership.md).

## Limits/security

| Limit | Value | Error |
| --- | --- | --- |
| write depth | 64 levels (each object, record, array, list, dictionary counts one) | `ESerializationLimitExceeded` |
| read nesting | at most 512 levels, the RTL parser's limit | refused by the parser |
| output size | `MaxOutputBytes`, per call; unlimited by default | `EJsonSerializationLimitExceeded` |
| a cycle | refused by default (`TJsonRecursiveReferencePolicy.Error`); `WriteNull` writes the back-reference as `null` | `EJsonError` |
| invalid JSON text | refused | `EJsonInputError` |
| a key the document repeats, into a dictionary | refused, naming the key; what was built is freed | `EJsonInputError` |
| a number past the member's range | refused | `EJsonInputError` |
| malformed UTF-8 bytes | refused, naming the offset | `EInvalidUtf8` |

`tests\Robustness` covers nesting bombs, threading and plan-cache stability.

## Expected refusals

By design, not bugs:

- the refusals every format makes: pointers, procedural and method types,
  interfaces, class references, legacy `TList`, `TCollection`, streams,
  `Exception`, `TComponent`, inline static arrays, variant records, `TBcd`
  without a custom serializer;
- a cycle, under the default recursion policy;
- a value nested deeper than 64 levels;
- NaN and infinities, by name (`EJsonError`); structural conversion under
  `Lossless` writes Extended JSON `$numberDouble`;
- a `TDateTime` or `TDate` outside the years 1 to 9999, on write;
- a repeated key into a dictionary;
- a `Variant` of kind `varDispatch`, `varUnknown`, `varByRef`, `varError`,
  `varRecord`, a custom variant type, or a multi-dimensional array.

JSON carries `UInt64` above `High(Int64)`, an unpaired surrogate (as an
escape), and scalar `Variant` values. See
[`../expected-refusals.md`](../expected-refusals.md).

## Interoperability evidence

There is no separate JSON native-test project. The independent reference is the RTL's own
parser, which reads every document the writer produces. `tests\JsonCore`
checks the default contract, the configuration freeze, `TryDeserialize`,
nesting levels, repeated keys, Extended JSON `$uuid`, correctly rounded
`Double` text on both platforms, and dates before 1899-12-30 and outside the
years 1 to 9999. `tests\UnicodeUtf8` checks escaping and UTF-8 code-unit
equality. `tests\BsonJson` checks the BSON routes, Extended JSON included.
`tests\LosslessRouting` checks the W3C JSON/XML mapping and the composed
routes.

## Important implementation units

| Role | Unit |
| --- | --- |
| Facade | `src\PascalForge.Json.pas` (`TJsonSerializer`, options, attributes, custom-serializer bases, `TJsonFieldOverride`) |
| Implementation | `src\PascalForge.Json.Internal.pas` (`TJsonEngine`: plans, RTTI walk, renderer, dynamic bridge, Extended JSON) |
| Registration | `src\PascalForge.Json.Registration.pas` (`TJsonSerializationRegistration`, `TJsonFormatHandler`) |
| DataSet members | `src\PascalForge.DataSet.Json.pas` (`TDataSetJsonIntegration`) |
| Schema | none |
| Tests | `tests\JsonCore\JsonCore.dpr`, `tests\UnicodeUtf8`, `tests\BsonJson\BsonJson.dpr`, `tests\DataSetJson` |

## Before changing this format

1. Read [`../format-program.md`](../format-program.md),
   [`../serializer-behavior.md`](../serializer-behavior.md) and
   [`../conversion.md`](../conversion.md).
2. Run `tests\JsonCore` (`powershell -File scripts\test.ps1 -Only JsonCore`),
   and `tests\BsonJson` for Extended JSON.
3. Run `tests\TypeCoverage` through `scripts\run-type-coverage.ps1`.
4. Run `tests\ReaderContracts`, `tests\ConversionMatrix` and
   `tests\Lifecycle`; for conversion changes also `tests\LosslessRouting`.
5. Do not change shared dynamic-model semantics (`TDynamicValue`, `TDynamicTag`,
   Core date and range helpers) from a format unit. Change Core deliberately,
   and retest every format.
6. A change to what JSON writes needs a test that pins the text and a
   documentation change.
7. Run `scripts\validate-release.ps1` before calling it finished.
