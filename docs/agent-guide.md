# Agent guide

For an AI coding agent - or a maintainer - about to change this library.
[`../AGENTS.md`](../AGENTS.md) is the short orientation; this is where to
start for a given task, and what must run afterwards.

## Where to start

1. [`architecture.md`](architecture.md) - the moving parts, public and
   internal units, the lifecycle, ownership, the error model.
2. The format's own document, `formats/<format>.md` - for example
   [`formats/json.md`](formats/json.md). It names the facade, the engine,
   the registration unit, the schema unit, and the tests.
3. [`configuration-lifecycle.md`](configuration-lifecycle.md) - format
   registration versus serializer configuration, and the freeze.
4. [`delphi-type-coverage.md`](delphi-type-coverage.md) and
   [`expected-refusals.md`](expected-refusals.md) - what each format carries
   and what it refuses on purpose.

## Units

| unit | public? | what it is |
| --- | --- | --- |
| `PascalForge.Serialization.Core` | public API plus shared infrastructure | Delphi facts every format shares, the registry, ownership, the depth guard, date and number text |
| `PascalForge.Serialization.Internal` | **internal** | the shared RTTI metadata: a type's member surface and general attributes, discovered once |
| `PascalForge.Serialization.Attributes` | public | `[SerializationName]`, `[SerializationIgnore]`, `[SerializationEnum]` |
| `PascalForge.Dynamic` | public | `TDynamicValue`, `TDynamicObject`, `TDynamicArray`, `TDynamicSerializer`: the structural model every format reads into and writes from |
| `PascalForge.Dynamic.Internal` | **internal** | the Delphi <-> Dynamic projection engine |
| `PascalForge.Serialization` | public | `TSerialization`: run-time format choice and conversion |
| `PascalForge.Serialization.AllFormats` | public | `TSerializationFormatsRegistration.RegisterAll` |
| `PascalForge.<Format>` | public | the facade, the attributes, the options |
| `PascalForge.<Format>.Registration` | public | `T<Format>SerializationRegistration` and the registry handler |
| `PascalForge.<Format>.Schema` | public | Protobuf descriptor sets, Avro schemas, ASN.1 modules |
| `PascalForge.<Format>.Internal` | **internal** | the engine |
| `PascalForge.DataSet` | public | `TDataSetSerializer` |
| `PascalForge.DataSet.Internal`, `.Packet` | **internal** | the projection engine, the packet |
| `PascalForge.DataSet.Json` | public | TDataSet as JSON, DataSet members in JSON graphs; declares `TDataSetJsonIntegration` |

Never use an `.Internal` unit from a demo or application code; if a demo
needs one, the facade is missing something.

## How it works, in five lines

- **Plans.** Each engine builds a plan per type on first use, caches it, and
  walks it afterwards, on top of the shared metadata
  (`TSerializationMetadata`), which discovers a type's members and general
  attributes once for every engine. RTTI belongs in plan building, never in
  the per-value path.
- **Registration.** Formats enter the registry only by an explicit
  `RegisterFormat` / `RegisterAll` call. No `initialization` section
  registers anything.
- **Configuration.** Registrations on a serializer are made at startup; the
  first real operation freezes them; a late one raises.
- **Ownership.** Reuse what is there, construct only when nothing is, never
  free what the read did not build; a failed read frees what it built.
- **Coverage.** `tests\TypeCoverage` is the matrix of Delphi type families
  through every format; a new refusal needs an `Allow()` entry with a reason.

## Task routing

| task | read first | run afterwards |
| --- | --- | --- |
| a bug in one format (JSON as the example) | `formats/json.md`, `PascalForge.Json.Internal` | `tests\JsonCore` (the format's own `tests\<Format>Native` / `<Format>Core`), `scripts\run-type-coverage.ps1`, `tests\ReaderContracts` |
| a change to what a format writes | the format document, [`limitations.md`](limitations.md) | the format's tests, TypeCoverage, `tests\ConversionMatrix`, `tests\FormatChain` |
| Core RTTI, type identity, containers, nullables | `architecture.md`, `PascalForge.Serialization.Core` | `tests\CoreFoundation`, then every format's tests (`scripts\test.ps1`) and TypeCoverage |
| ownership or failure paths | [`deserialization-ownership.md`](deserialization-ownership.md) | `tests\ReaderContracts` (`OWNERSHIP`), `tests\Robustness`, the format's tests |
| format registration, the registry | `configuration-lifecycle.md`, [`architecture.md`](architecture.md) | `tests\FormatRegistry`, `tests\Lifecycle`, `tests\FormatBoundary`, `scripts\check-format-isolation.ps1` |
| serializer configuration, the freeze | `configuration-lifecycle.md` | `tests\Lifecycle`, the format's tests |
| structural conversion, profiles | [`conversion.md`](conversion.md) | `tests\ConversionMatrix`, `tests\FormatChain`, `tests\LosslessRouting`, `tests\StructuralFidelity` |
| contract-aware conversion | `conversion.md` | `tests\ContractMatrix`, `tests\Conversion` |
| the dynamic model, Delphi <-> Dynamic, a format's `ToDynamic`/`FromDynamic` | [`dynamic.md`](dynamic.md), `PascalForge.Dynamic` | `tests\Dynamic`, `tests\CoreFoundation`, `tests\ConversionMatrix`, `tests\StructuralFidelity` |
| member discovery, the general attributes, precedence | [`attributes.md`](attributes.md), `PascalForge.Serialization.Internal` | `tests\GeneralAttributes`, `tests\Dynamic`, every format's tests, TypeCoverage |
| DataSet projection | [`dataset-projection.md`](dataset-projection.md), [`dataset-formats.md`](dataset-formats.md) | `tests\DataSetFormats`, `tests\DataSetSources`, `tests\DataSetParity`, `tests\DataSetJson` |
| Protobuf schema, descriptor sets | `formats/protobuf.md`, [`protobuf-descriptors.md`](protobuf-descriptors.md) | `tests\ProtobufSchema`, `tests\ProtobufReference` (the protoc interop), `tests\ProtobufNative` |
| Avro or ASN.1 schemas | `formats/avro.md`, `formats/asn1.md` | `tests\AvroNative`, `tests\Asn1Native` |
| CSV projection: options through conversion, several tables | `formats/csv.md` ("Structural representation"): single-table options travel in a `TCsvSchema`; `SeparateTable` is `TCsvSerializer.TablesFrom` / `SerializeTables`, never `TSerialization.Convert` | `tests\CsvNative` (`CSV_STRUCTURAL_*`, `CSV_SINGLE_PAYLOAD_*`), `tests\ConversionMatrix`, the converter demo's self-test |
| hostile input, limits | the format document's "Limits/security" | `tests\Robustness`, the format's malformed-input section |
| Unicode, UTF-8 | [`unicode-and-utf8.md`](unicode-and-utf8.md) | `tests\UnicodeUtf8`, `tests\CoreFoundation` |
| a package or its dependencies | [`packaging.md`](packaging.md) | `scripts\check-packages.ps1` (with `PACKAGE_ISOLATION` and `tests\PackageProbe`), `scripts\check-format-isolation.ps1`, `scripts\check-dependencies.ps1` |
| a demo | the demo's own header comment | `scripts\run-demos.ps1` |
| documentation | the document itself | `scripts\check-docs.ps1`, `scripts\check-banned-markers.ps1` |
| any change to source | - | `scripts\check-compiler-warnings.ps1` after a build (zero warnings and hints in PascalForge code, both platforms; library units are built with every warning family on), `scripts\check-source-audit.ps1` |

Before calling anything finished: `scripts\validate-release.ps1`, which runs
every public gate on Win32 and Win64 and derives the release markers from
what the runs wrote.

## Rules that are easy to break

- Do not add a compile-time dependency from one format to another, or from
  Core to any format.
- Do not register a format from an `initialization` section, anywhere.
- Do not configure a serializer after its first use - in a test either; put
  the registration in the test's startup.
- Do not change the shared dynamic-model semantics from a format unit.
- Do not weaken a test to make it pass: no removed check, no `Allow()`
  without a reason, no catching an exception and calling it a refusal.
- Do not put generated files beside source; everything goes under
  `artifacts\`.
- Do not add private or company-specific source or names to this tree.
