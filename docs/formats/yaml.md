# YAML

## Purpose

This is the entry point for the YAML format. It summarizes what the format
does and where the code is. For depth, read
[`../yaml-behavior.md`](../yaml-behavior.md). The API is in
[`../api-reference.md`](../api-reference.md).

YAML is a real engine: a hand-written parser, an emitter and an alias
expander. A Delphi value is written straight to YAML nodes and read straight
back. Nothing goes through JSON text, another format, or the dynamic tree on
the contract path. The natural payload type is `string`.

## Standard/profile

- **YAML 1.2.2** (the specification revision 1.2.2), with the **1.2 core
  schema** for resolving plain scalars. Not the JSON schema: `True`, `TRUE`,
  `~`, `0o14`, `0x2A` and `.inf` all resolve.
- Block and flow collections, nested either way; a block sequence at its
  parent key's own column.
- All five scalar styles: plain (multi-line too), single-quoted,
  double-quoted with escapes, literal and folded. Chomping indicators
  (`clip`, `strip`, `keep`) and the indentation indicator.
- Document markers `---` and `...`, multi-document streams, `%YAML` and
  `%TAG` directives.
- Anchors and aliases; primary (`!x`), secondary (`!!x`) and verbatim
  (`!<...>`) tags; complex keys (`? key`); comments.

Core schema resolution is `TYamlSchema.Resolve`, public:

| Plain text | Resolves as |
| --- | --- |
| `null`, `Null`, `NULL`, `~`, empty | null |
| `true`, `True`, `TRUE`, `false`, `False`, `FALSE` | bool |
| `[-+]?[0-9]+`, `0o[0-7]+`, `0x[0-9a-fA-F]+` | int (`012` is twelve) |
| `1.5`, `1e3`, `.inf`, `-.Inf`, `.nan` | float |
| `yes`, `no`, `on`, `off`, `y`, `n`, `190:20:30`, `0b1010` | str |

A quoted, literal or folded scalar is always a string. A tag the document
wrote (`!!str`, `!!int`, ...) outranks the schema.

Not implemented: the YAML 1.1 schema (`yes`/`on` are strings, no
leading-zero octal, no sexagesimal, no binary literal), merge keys (`<<` is
an ordinary key), and emitting anchors for shared Delphi instances.

## Public facade

Unit `PascalForge.Yaml`, class `TYamlSerializer`. All methods are class
static.

| Method | Signature |
| --- | --- |
| `Serialize<T>` | `(const AValue: T): string`, and with `TYamlEmitOptions` |
| `Deserialize<T>` | `(const AYaml: string): T`; exactly one document |
| `Populate<T>` | `(const AInstance: T; const AYaml: string)` |
| `SerializeAll<T>` | `(const AValues: TArray<T>): string`, and with `TYamlEmitOptions`; one document per value |
| `DeserializeAll<T>` | `(const AYaml: string): TArray<T>`; one value per document |
| `ParseStream` | `(const AYaml: string): TYamlStream`; the caller owns the result |
| `ParseDocument` | `(const AYaml: string): TYamlDocument`; exactly one document; the caller owns it |
| `SerializeStream` | `(AStream: TYamlStream): string`, and with `TYamlEmitOptions` |
| `SerializeDocument` | `(ADocument: TYamlDocument): string`, and with `TYamlEmitOptions` |
| `Expand` | `(ADocument: TYamlDocument): TYamlDocument`; aliases replaced by copies; the caller owns the copy |
| `From` | structural: `(ASource: string / TBytes / TSerializationPayload; AFrom: TSerializationFormat): string`, and a payload overload with `TStructuralConversionProfile` |
| `From<T>` | contract-aware: the same source overloads |
| `ToDynamic` / `FromDynamic` | `(const AYaml: string): TDynamicValue` / `(AValue: TDynamicValue): string` (one document), each also with `TStructuralConversionOptions` - see [`../dynamic.md`](../dynamic.md) |

The general attributes apply; `[YamlName]`, `[YamlIgnore]` and `RegisterEnumMapping` beat them for YAML. See [`../attributes.md`](../attributes.md).

There is no `TryDeserialize`. The representation graph is `TYamlStream`,
`TYamlDocument` and `TYamlNode` (kinds `Scalar`, `Sequence`, `Mapping`,
`Alias`; a mapping key is a node).

Configuration (call at startup):

- `SetDateTimeRepresentation` (a representation, or a pattern),
  `RegisterDateTimeRepresentation<T>`, `RegisterFieldDateTimeRepresentation<T>`
- `RegisterEnumMapping<T>(const AValues: array of string)`
- `RegisterTypeSerializer<T>(ASerializerClass: TYamlValueSerializerClass)`
- `SetDefaultEmitOptions`, `DefaultEmitOptions`
- `SetDuplicateKeyPolicy`, `DuplicateKeyPolicy` (`Error` by default,
  `LastWins`, `FirstWins`)
- `SetLimits`, `Limits`
- `FreezeConfiguration`, `IsFrozen`, `ResetConfiguration` (for tests)

Configuration freezes automatically at the first real serializer operation
(`Serialize`, `Deserialize`, `Populate`, `SerializeAll`, `DeserializeAll`,
`From<T>`, or the registry's typed calls). `ParseStream`, `ParseDocument`,
`Expand` and the emit calls do not freeze it. After the freeze,
configuration is immutable and concurrent use is safe. A registration made
after the freeze raises `EYamlInternalError` saying the configuration is
frozen. `FreezeConfiguration` freezes earlier. See
[`../configuration-lifecycle.md`](../configuration-lifecycle.md) for the full
lifecycle.

Exceptions: `EYamlError` (base), `EYamlParseError` (carries `Line` and
`Column`) with `EYamlTabIndentationError`, `EYamlUnclosedQuoteError` and
`EYamlDuplicateKeyError`; `EYamlAliasError` with `EYamlUnresolvedAliasError`
and `EYamlAliasCycleError`; `EYamlLimitExceeded`; `EYamlInputError` (the
document parsed but does not fit the contract); `EYamlInternalError` (model
or configuration).

## Explicit registry registration

```pascal
uses
  PascalForge.Yaml.Registration;
...
TYamlSerializationRegistration.RegisterFormat;
```

- Linking or importing `PascalForge.Yaml.Registration` does **not** register
  the format.
- Loading the runtime package `PascalForge.Serialization.Runtime.bpl` does
  **not** register it.
- `RegisterFormat` is idempotent. It raises `ESerializationFormatConflict`
  if a different handler already holds `TSerializationFormat.Yaml`.
- `UnregisterFormat` is safe when the format is absent, and never removes
  another unit's handler.
- `IsRegistered` reports whether this unit's handler holds the format.

Direct `TYamlSerializer` use needs no registration. Registration is needed
only for `TSerialization` (format chosen at run time), `TSerialization.Convert`,
and the `TDataSetSerializer` overloads that take a `TSerializationFormat`.

All formats at once: `TSerializationFormatsRegistration.RegisterAll` in unit
`PascalForge.Serialization.AllFormats`. It is also explicit.

Registry mutation happens at startup and shutdown. It must not run
concurrently with serialization.

## Native Delphi mappings

| Delphi | YAML, by default |
| --- | --- |
| `Boolean` | `true` / `false` |
| integers of every width, `Comp` | plain int scalar |
| `UInt64` above `High(Int64)` | plain int scalar (its decimal digits) |
| `Single`, `Double`, `Extended` | plain float scalar, shortest round-trip text; `.nan`, `.inf`, `-.inf` |
| `Currency` | plain decimal scalar, the exact value (`12.3456`) |
| `string`, `Char` | scalar, double-quoted only when the core schema would read it as something else |
| `TBytes` | `!!binary`, base64 |
| `TDateTime`, `TDate`, `TTime` | ISO 8601 date-time text, untagged (`Iso8601`) |
| `TGUID` | 36-character lower-case text, plain |
| enumeration | member name, or its `RegisterEnumMapping` name; quoted when the schema would resolve it |
| set | sequence of member names |
| class, record | block mapping |
| list, dynamic or static array | block sequence |
| dictionary | mapping |
| `TNullable<T>` with no value | member omitted |
| `Variant` | the value it holds, through the shared variant bridge; `Unassigned` omitted |

Member attributes: `YamlName`, `YamlIgnore`, `YamlDateTimeRepresentation`
(`Iso8601`, `Timestamp` (the same text with `!!timestamp`), `UnixSeconds`,
`UnixMilliseconds`, `CustomString`, or a pattern), `YamlSerializer`. There is
no GUID, `Currency` or enumeration representation attribute.

Dates and text:

- A `TDateTime` or `TDate` outside the years 1 to 9999 is refused on write.
- Text with a zone offset is read as the instant it states, normalised to
  UTC (`TStructuralText.DecodeIso8601`). No offset is ever written.
- A `CustomString` pattern is read back with the same pattern (numeric
  specifiers; `TStructuralText.TryDecodePattern`).
- Float text is read correctly rounded (`TStructuralText.TryParseFloat`, via
  `TYamlSchema.TryToDouble`), the same on Win32 and Win64.
- A string with an unpaired UTF-16 surrogate is refused on write
  (`EYamlError`): YAML has no spelling for half a character.

Full detail: [`../yaml-behavior.md`](../yaml-behavior.md),
[`../datetime-policies.md`](../datetime-policies.md),
[`../delphi-type-coverage.md`](../delphi-type-coverage.md).

## Structural representation

YAML is self-describing. It declares all four registry capabilities with no
schema. The handler parses the text into a `TYamlStream` and maps it to
`TDynamicValue` (`TYamlEngine.YamlToDynamic`, `StreamToDynamic`), and back
(`TYamlEngine.DynamicToYaml`). Aliases are not expanded on this path.

| YAML | `TDynamicValue` |
| --- | --- |
| plain int within `Int64` | `Int` |
| plain int above `High(Int64)` | `UInt` |
| plain float, including `.nan` / `.inf` | `Float` |
| plain `true` / `false` / null | `Bool` / `Null` |
| quoted, literal or folded scalar; any other plain text | `Str` |
| `!!binary` | `Bytes` |
| `!!timestamp` in the exact form this library writes | `DateTime` |
| scalar with any other tag | resolved by that tag if it is a core tag, otherwise `Str`; the tag itself is dropped |
| sequence / mapping | `Arr` / `Obj` |
| alias | `Extended`, tag `yamlalias`, payload `Str` (the anchor name) |
| stream of several documents | `Arr`, one element per document |

The anchor on the anchored node is not carried into the dynamic tree. A
complex (non-scalar) key becomes its description text. These are the lossy
steps of the bridge.

On the way back the handler writes **one** document. `DateTime` is written
with `!!timestamp`, `Bytes` as `!!binary`, `Date` and `Time` as plain ISO
text, `Decimal` as plain digits (read back as a float), `UInt` as plain
digits. A `yamlalias` value is written as an alias. Any other `Extended`
value that reaches the YAML writer is refused with
`EStructuralConversionError`. A string the schema would resolve is
double-quoted.

## Lossless behavior

The YAML handler does not consult the profile: `Natural`, `Lossless` and
`Strict` give the same text from `DynamicToYaml`. A mapping key is any
string, so no member name needs encoding. The kinds YAML lacks are `Decimal`
(written as digits, read back as `Float`), `Date` and `Time` (written as
text, read back as `Str`) and non-YAML `Extended` values (refused).

When YAML is the source, `Lossless` depends on the destination. The
destination decides what it can express, `yamlalias` included. See
[`../conversion.md`](../conversion.md).

## Contract-aware behavior

These depend on the Delphi type `T` (`Serialize<T>`, `Deserialize<T>`,
`TSerialization.Convert<T>`, `From<T>`):

- member names, `YamlName` and `YamlIgnore`;
- the date/time representation, and `RegisterEnumMapping` names (matched
  before the schema resolves the scalar);
- alias expansion: the contract reader expands aliases first, under the
  budgets, because a Delphi member cannot be two members at once;
- range checks into the member type, and a sequence or mapping where a
  scalar belongs, both `EYamlInputError`;
- `Currency` read back exactly from its decimal text;
- `TNullable<T>` absence, sets, collections, dictionaries, `Variant`;
- custom serializers.

Without `T`, a structural conversion carries only what the dynamic tree
holds.

## Schema/context

None is needed. YAML is self-describing; the core schema is built in. The
structural path works with no schema in the conversion options.

## DataSet behavior

`TDataSetSerializer.CreateFDMemTable(Text, TSerializationFormat.Yaml)` and
the other overloads that take a `TSerializationFormat` need the format
registered. The document is parsed into the dynamic tree and the schema is
inferred from it. See [`../dataset-formats.md`](../dataset-formats.md) and
[`../dataset-projection.md`](../dataset-projection.md).

| YAML item | Inferred field type |
| --- | --- |
| plain int within 32 bits | `ftInteger` |
| wider plain int, or above `High(Int64)` | `ftLargeint` |
| plain float | `ftFloat` |
| `!!timestamp` in the library's own form | `ftDateTime` |
| `!!binary` | `ftBlob` |
| `true` / `false` | `ftBoolean` |
| quoted text, plain text, untagged ISO date text, alias | `ftWideString` |
| mapping or sequence of mappings | `ftDataSet` (nested) |

A quoted `"0108"` stays text with its leading zero. The core schema has no
date type, so an untagged date is a string and infers as `ftWideString`.
Supply the contract (`CreateFDMemTable<T>(Text, TSerializationFormat.Yaml)`)
for Delphi field types. `TDataSetSerializer.Serialize(DataSet,
TSerializationFormat.Yaml, Policy)` writes a DataSet packet as YAML.

## Custom serializers

Base classes in `PascalForge.Yaml`:

- `TCustomYamlValueSerializer<T>`: override
  `SerializeValue(const AValue: T): TYamlNode` and
  `DeserializeValue(AValue: TYamlNode; const AExisting: T): T`. Use this one.
- `TCustomYamlValueSerializer`: the untyped base with `TValue` and
  `PTypeInfo`, for a type not known at compile time.

Registration:

```pascal
TYamlSerializer.RegisterTypeSerializer<TMoney>(TMoneyYamlSerializer);
```

Per member: `[YamlSerializer(TMoneyYamlSerializer)]`.

The caller adopts the `TYamlNode` a serializer returns. On read the
serializer sees the node with aliases already expanded. A read returns a new
instance or the existing one it was given. See
[`../customization.md`](../customization.md) and
[`../deserialization-ownership.md`](../deserialization-ownership.md).

## Limits/security

| Limit | Value | Error |
| --- | --- | --- |
| write depth | 64 levels (each object, record, array, list, dictionary counts one) | `ESerializationLimitExceeded` |
| parse nesting | 200 (`TYamlLimits.MaxDepth`, `TYamlLimits.Default`) | `EYamlLimitExceeded` |
| expansion depth | the same `MaxDepth`, counted through aliases | `EYamlLimitExceeded` |
| expanded nodes | 250000 (`TYamlLimits.MaxExpandedNodes`); every node the expander produces counts, keys included | `EYamlLimitExceeded` |
| alias cycle | refused, not followed | `EYamlAliasCycleError` |
| control character (C0 other than tab and line feed) | refused before scanning | `EYamlParseError` |
| tab used for indentation | refused | `EYamlTabIndentationError` |

`SetLimits` moves both budgets (before the freeze). The expansion budget
applies to contract reads and `Expand`; the structural path does not expand.
There is no separate document-size or scalar-length limit. A leading BOM is
skipped. `tests\Robustness` covers nesting bombs, alias expansion (billion
laughs) and truncation.

## Expected refusals

By design, not bugs:

- the refusals every format makes: pointers, procedural and method types,
  interfaces, class references, legacy `TList`, `TCollection`, streams,
  `Exception`, `TComponent`, cycles, inline static arrays, variant records,
  `TBcd` without a custom serializer;
- a value nested deeper than 64 levels;
- a `TDateTime` or `TDate` outside the years 1 to 9999, on write;
- an unpaired UTF-16 surrogate in a string, on write;
- a repeated mapping key, under the default `Error` policy;
- a stream of more than one document given to `Deserialize<T>` or
  `ParseDocument`;
- an alias with no anchor, or a cyclic alias, on a contract read or `Expand`;
- a sequence or mapping where a scalar belongs;
- an `Extended` value from another format reaching the YAML writer.

YAML carries `UInt64` above `High(Int64)`, NaN and infinities, embedded
`#0` and control characters (escaped), and `Variant` values. See
[`../expected-refusals.md`](../expected-refusals.md) and
[`../limitations.md`](../limitations.md).

## Interoperability evidence

`tests\YamlNative` uses the **YAML 1.2.2 specification** as the independent
reference: documents written as the specification defines them, and the
documents that distinguish a 1.2 reader from a 1.1 one (`yes`, `012`,
`190:20:30`, `0b1010`). No reference implementation runs offline, so the
oracle is the specification rather than a running program. The test prints
a feature ledger covering block and flow collections, all scalar styles,
chomping, directives, streams, anchors and aliases, tags, complex keys,
core-schema resolution, duplicate-key policies, the budgets, the contract
path and DataSet projection.

## Important implementation units

| Role | Unit |
| --- | --- |
| Facade | `src\PascalForge.Yaml.pas` (`TYamlSerializer`, `TYamlSchema`, the node model) |
| Implementation | `src\PascalForge.Yaml.Internal.pas` (`TYamlParser`, `TYamlEmitter`, `TYamlExpander`, `TYamlEngine`: RTTI walk, dynamic bridge, configuration) |
| Registration | `src\PascalForge.Yaml.Registration.pas` (`TYamlSerializationRegistration`, `TYamlFormatHandler`) |
| Schema | none (the core schema is `TYamlSchema` in the facade) |
| Tests | `tests\YamlNative\YamlNative.dpr`, `tests\YamlNative\YamlModels.pas` |

## Before changing this format

1. Read [`../format-program.md`](../format-program.md) and
   [`../yaml-behavior.md`](../yaml-behavior.md).
2. Run `tests\YamlNative`
   (`powershell -File scripts\test.ps1 -Only YamlNative`).
3. Run `tests\TypeCoverage` through `scripts\run-type-coverage.ps1`.
4. Run `tests\ReaderContracts`, `tests\ConversionMatrix`, `tests\Lifecycle`
   and `tests\Robustness`.
5. Do not change shared dynamic-model semantics (`TDynamicValue`, `TDynamicTag`,
   Core date and range helpers) from a format unit. Change Core deliberately,
   and retest every format.
6. Do not change scalar resolution casually. `TYamlSchema.Resolve` decides
   what every plain scalar means; a change there changes data.
7. A change to what YAML writes needs a test that pins the text and a
   documentation change.
8. Run `scripts\validate-release.ps1` before calling it finished.
