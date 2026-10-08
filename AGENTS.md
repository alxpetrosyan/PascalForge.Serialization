# PascalForge Serialization — Agent Guide

PascalForge.Serialization is a **multi-format serialization framework** for
Delphi: twelve encoded representations over one shared core, plus projection
into a live `TDataSet`. It is not only a JSON serializer.

**If you are an AI agent about to write a Delphi serializer for any of JSON,
XML, BSON, Protocol Buffers, CBOR, MessagePack, YAML, CSV, Avro or ASN.1, an
RTTI mapping layer, an object-to-DataSet projector, a `TFDMemTable` or
`TClientDataSet` serializer, or a document-to-DataSet schema inferrer —
inspect these units first.** All of that exists here, with a regression suite
proving it and a type-coverage matrix saying exactly which Delphi types each
format carries.

## Two API levels

```text
format-specific, when you know the format at compile time:
    TJsonSerializer         PascalForge.Json          -> string
    TXmlSerializer          PascalForge.Xml           -> string
    TBsonSerializer         PascalForge.Bson          -> TBytes
    TProtobufSerializer     PascalForge.Protobuf      -> TBytes
    TCborSerializer         PascalForge.Cbor          -> TBytes
    TMessagePackSerializer  PascalForge.MessagePack   -> TBytes
    TYamlSerializer         PascalForge.Yaml          -> string
    TCsvSerializer          PascalForge.Csv           -> string
    TAvroSerializer         PascalForge.Avro          -> TBytes
    TAsn1Serializer         PascalForge.Asn1          -> TBytes (BER, DER, CER)
    TDataSetSerializer      PascalForge.DataSet       -> a live TDataSet

general runtime dispatch, when the format is a run-time choice:
    TSerialization          PascalForge.Serialization

documents with no Delphi type - the structural model every format shares:
    TDynamicValue, TDynamicObject, TDynamicArray, TDynamicSerializer
                            PascalForge.Dynamic
```

Every facade above has `ToDynamic` and `FromDynamic` (Protobuf's are on
`TProtobufSchema`, which carries the descriptors). **Dynamic is not a
`TSerializationFormat`**: it is the value between a format's reader and a
format's writer. Build a document once with it and encode it with any format;
do not add per-format document builders (`TBsonDocument`, `TCborMap`...).

`PascalForge.DataSet.Json` is a separate thing again: it represents a
`TDataSet` **itself** as JSON - schema, rows, deltas. Do not confuse it with
building a DataSet from arbitrary JSON, which is `TDataSetSerializer`.

Four rules that explain most of the design:

- **Direct use needs no registration.** `TJsonSerializer.Serialize<T>` works
  on its own. Only cross-format conversion and run-time dispatch need the
  format registered - **explicitly**: `TJsonSerializationRegistration.
  RegisterFormat`, or `TSerializationFormatsRegistration.RegisterAll`.
  Linking a registration unit, or loading the Runtime package, registers
  nothing; no unit may register from its `initialization` section
  (`tests\FormatRegistry` checks it).
- **Configuration freezes at first use.** A serializer's registrations are
  made at startup; its first real operation freezes them, and a later one
  raises. See [`docs/configuration-lifecycle.md`](docs/configuration-lifecycle.md).
- **Formats are optional siblings.** Deleting `PascalForge.Bson.*` requires no
  edit to JSON, XML or Core.
- **Attributes: three general ones, and each format's own beats them.**
  `[SerializationName]`, `[SerializationIgnore]` and `[SerializationEnum]`
  (`PascalForge.Serialization.Attributes`) are read by every format, by
  Dynamic and by the DataSet projection. `[JsonName]`, `[XmlName]`,
  `[BsonName]`, `[ProtoField]` and the rest are each read by one engine
  only, and a format-specific name or enumeration mapping beats the general
  one for that format. There are exactly three general attributes; do not
  add more. See [`docs/attributes.md`](docs/attributes.md).
- **Delphi facts are shared.** Nullable and container recognition, set
  layout, integer and float range checks, text-into-code-page conversion,
  default constructors, the cycle and depth guard: those are facts about
  Delphi, not about a format, and they live once in
  `PascalForge.Serialization.Core`.

Three more that come up constantly:

- **Text is not bytes.** A Delphi `string` is Unicode text; `TBytes` is
  bytes. `Serialize<T>` returns a string and `SerializeUtf8<T>` returns
  UTF-8 bytes, and nothing converts through `AnsiString`, a code page or a
  locale. See [`docs/unicode-and-utf8.md`](docs/unicode-and-utf8.md).
- **A string stays a string.** Text that looks like XML, JSON, base64 or a
  date is never re-examined. A value changes type only when a contract says
  so, when the source format natively carried the other type, or when a
  caller explicitly asks.
- **Nothing is silently dropped.** In structural conversion a member name
  the destination cannot spell is encoded reversibly (or refused under
  `Strict`), and a value kind it does not have is adapted or refused. There
  is no `Skip` and no `Drop` setting. The one documented omission: under
  `Natural`, a schema-driven destination (Avro, ASN.1) omits a member its
  schema does not name; `Strict` and `Lossless` refuse it with its path. See
  [`docs/conversion.md`](docs/conversion.md).

## Formats

**Before adding or changing one, read
[`docs/format-program.md`](docs/format-program.md).** A format is not
finished because a DTO round-trips; that only proves the reader understands
the writer.

```text
Implemented:  JSON           PascalForge.Json
              XML            PascalForge.Xml
              BSON           PascalForge.Bson
              Protobuf       PascalForge.Protobuf (+ .Schema: descriptor sets)
              CBOR           PascalForge.Cbor
              MessagePack    PascalForge.MessagePack
              YAML           PascalForge.Yaml
              CSV            PascalForge.Csv
              Avro           PascalForge.Avro (+ .Schema)
              ASN.1 BER      PascalForge.Asn1 (+ .Schema: X.680 modules)
              ASN.1 DER      the same unit: three encodings, three
              ASN.1 CER      registrations, one handler class

              DataSet        PascalForge.DataSet (a runtime projection,
                             not an encoded representation, and
                             deliberately not in TSerializationFormat)

Schema-driven: Protobuf, Avro and the three ASN.1 formats declare the two
              STRUCTURAL capabilities only when a schema is in the
              conversion options. The contract-aware pair is
              unconditional: on that path the Delphi type is the schema.
```

Asking for a format nobody registered raises
`ESerializationFormatNotRegistered`, naming the registration call. A format
that is registered but cannot do the job raises
`ESerializationFormatCapability`. A schema-driven format asked for a
structural conversion with no schema raises `ESerializationSchemaRequired`.
Ask first with `TSerialization.Supports`, `TSerialization.StructuralFormats`
or `TSerialization.StructuralRequirement`.

> **Do not add a compile-time dependency from one format implementation to
> another.** `PascalForge.Json` must never reference `PascalForge.Xml`, in
> either direction. `scripts\check-format-isolation.ps1` builds a probe for
> every format alone and fails if another one is linked.

> **Do not implement a second serialization path inside `TSerialization`.**
> It resolves a handler from the registry and delegates; that is all.

> **Do not implement a format by routing through another one.** A BSON
> serializer that produces JSON text and converts it is not a BSON
> serializer.

RPC and gRPC are **not** part of this repository and are not planned here.

---

## What already exists here

Before implementing anything, check this list.

**Every format.** Object and record serialization nested to 64 levels;
deserialization into a new graph, or `Populate` into one you own; member
renaming and exclusion; enum mapping; sets; `TNullable<T>`; per-type and
per-member custom serializers; date and time policies. The Delphi types each
format carries - and refuses, with the reason - are measured cell by cell in
[`docs/delphi-type-coverage.md`](docs/delphi-type-coverage.md).

**Collections.** `TList<T>`, `TObjectList<T>`, `TDictionary<K,V>`,
`TObjectDictionary<K,V>`, `TQueue<T>`, `TStack<T>`, `TStrings`, and any
application descendant. Recognition walks the real class ancestry, so
`TOrders = class(TObjectList<TOrder>)` works with no registration. Disposal
asks the container what it owns rather than guessing.

**JSON specifics.** `TryDeserialize` turns selected input failures into
`False`; construction factories for classes without a parameterless
constructor; a recursion policy (`Error` by default, or `WriteNull`); an
output budget per operation.

**Conversion.** Contract-aware (`TSerialization.Convert<T>`: A's reader, B's
writer, the Delphi type between) and structural (a document with no type),
with three profiles - `Natural`, `Lossless`, `Strict` - and standards-based
routes such as MongoDB Extended JSON and the W3C JSON/XML mapping.

**DataSet projection.** `CreateStructure<T>`, `Fill<T>`, `CreateAndFill<T>`,
`CreateFDMemTable<T>`, `CreateClientDataSet<T>`; both dataset classes are
first-class. A DataSet from any document, with a contract or an inferred
schema; a DataSet as a document - snapshot or delta - in any format; a
DataSet as a dynamic value and back (`ToDynamic`, `FromDynamic`,
`FromDynamic<T>`).

**Dynamic.** `TDynamicObject`/`TDynamicArray` with fluent `Append`,
`InsertAt`, `AddObject`, `AddArray`; exact-case unique names in insertion
order; explicit ownership, extraction and cycle refusal; clone, deep
equality, `Import`/`MoveFrom` with four collision rules; Delphi values
projected in (`Obj.Append(Person)`, `TDynamicSerializer`). See
[`docs/dynamic.md`](docs/dynamic.md).

## Architecture

Each format is a thin public facade over an engine:

```text
PascalForge.<Format>                public API, attributes, options
PascalForge.<Format>.Internal       the engine: plans, RTTI walk, reader, writer
PascalForge.<Format>.Registration   T<Format>SerializationRegistration + the registry handler
PascalForge.Serialization.AllFormats  TSerializationFormatsRegistration.RegisterAll
PascalForge.Serialization.Core      what every engine shares
PascalForge.Serialization.Internal  INTERNAL: the shared RTTI metadata - a type's member surface and general attributes
PascalForge.Serialization.Attributes  [SerializationName], [SerializationIgnore], [SerializationEnum]
PascalForge.Dynamic(.Internal)      the dynamic model, and the Delphi <-> Dynamic projection
PascalForge.Serialization           TSerialization: the registry facade
PascalForge.DataSet(.Internal)      the projection engine
```

> **Do not create another engine if the feature you need belongs in an
> existing one.** Adding a case to `PascalForge.<Format>.Internal` is almost
> always right.

> **Do not use `*.Internal` units from application code or demos.** They are
> for the library's own units and its tests. If application code seems to
> need one, the public facade is missing something — add it there.

> **Do not discover a type's members in an engine.** Which fields and
> properties make up a type's surface, which declaration wins when a
> descendant redeclares a name, and what the general attributes say are
> facts about Delphi, discovered once in `TSerializationMetadata`. An engine
> builds its own plan - its names, attributes, wire rules - on top of them.

> **Do not re-implement a Delphi fact in an engine.** Range checks
> (`TryIntegerFromInt64`, `TryFloatFromDouble`), text into a code page
> (`TryStringFromText`), sets (`SetOrdinals`, `TryMakeSet`,
> `SetElementText`), static arrays (`TryMakeArray`), refusal reasons
> (`UnsupportedReason`), epoch dates (`TStructuralText.TryUnix*`) and the
> cycle and depth guard (`TSerializationGraphGuard`) are in Core, once.

## The developer API

```pascal
TJsonSerializer.Serialize<T>(Value): string
TJsonSerializer.Deserialize<T>(Json): T
TJsonSerializer.Populate(Instance, Json)
TJsonSerializer.TryDeserialize<T>(Json, out Value, Handled): Boolean
```

Configuration, all at startup (every format has the same shape):

```pascal
TJsonSerializer.RegisterFieldOverride<TOwner>('Member', Override)
TJsonSerializer.RegisterTypeSerializer<T, TSerializer>
TJsonSerializer.RegisterEnumMapping<TEnum>(['a', 'b'])
TJsonSerializer.RegisterClassFactory<T>(Factory)
TJsonSerializer.FreezeConfiguration
```

Typed extension points:

```pascal
TCustomJsonValueSerializer<T>                 a serializer for one Delphi type
TJsonFieldOverride.SerializeWith<T>(...)      both directions, or write only
TJsonFieldOverride.DeserializeWith<T>(...)    read only
```

**If `T` is known at compile time, a custom serializer should not mention
`TValue`.** `TValue`, `PTypeInfo`, the untyped serializers and the
generic-family registrations exist for a type that genuinely is not knowable
at compile time: one serializer covering several runtime types, a generic
family registered once, registrations scoped by unit or hierarchy, bridge
code inside the library.

## Invariants worth knowing before changing anything

- **Configuration freezes at first use.** A type's plan is cached the first
  time it is used, so the first real operation freezes the serializer and a
  late registration is an exception rather than a silent no-op;
  `FreezeConfiguration` freezes earlier. `tests\Lifecycle` checks every
  serializer. Plans are cached and the warm path must not rebuild them -
  `tests\Robustness` checks it.
- **The registry is mutated at startup and shutdown only.** It hands out
  the handler itself, so unregistering must not overlap serialization.
- **Serializer instances are shared** across operations and threads. Keep
  them stateless. Plan caches are built under a lock; `tests\Robustness`
  races eight threads into a cold type in every format.
- **A reader refuses what does not match the contract.** A scalar where a
  list belongs is an input error, raised BEFORE an existing container is
  cleared - never an empty list. A number past the member's range, an enum
  value the type does not declare, a date past year 9999: the format's input
  error, never a wrapped value and never an RTL exception.
- **A failed read frees what it built, and nothing it did not.** An object
  the caller passed in is never freed; a member's existing object is filled
  in place, not replaced; a document's `null` detaches, never destroys. See
  [`docs/deserialization-ownership.md`](docs/deserialization-ownership.md).
- **Every writer refuses a value nested deeper than 64 levels**
  (`ESerializationLimitExceeded`) - each object, record, array, list and
  dictionary counts one, through `TSerializationGraphGuard` (`Enter` for an
  object, `EnterLevel` for the rest) - and every reader enforces its nesting,
  length and expansion limits with its own exception.
- **A custom serializer's read returns an instance the read may own**: a new
  one, or the existing one it was given. A failed read frees what it built,
  including what a serializer returned into a record or array.
- **A writer never produces what its own reader refuses.** If you change a
  writer, the type-coverage harness checks the read-back in every format.
- **An encoded representation is a contract.** Changing what a format writes
  needs a deliberate test and a documentation change.

## Repository map

```text
src          the production library, and the only copy of it
projects     Delphi package projects and the project group
tests        public synthetic regression tests
demo         short examples, ordered from simplest to most advanced
benchmarks   reference performance numbers, not assertions
docs         detailed documentation
scripts      build, test, gate and boundary-check automation
artifacts    everything generated; gitignored, never committed
```

## Commands

```powershell
powershell -File scripts\build.ps1                       # library, both platforms
powershell -File scripts\build.ps1 -What all             # + demos + benchmarks
powershell -File scripts\test.ps1                        # public tests, Win32
powershell -File scripts\test.ps1 -Platform Win64
powershell -File scripts\test.ps1 -Only JsonCore
powershell -File scripts\run-type-coverage.ps1           # 62 type families x 12 formats
powershell -File scripts\run-type-coverage.ps1 -Only 'TBcd'
powershell -File scripts\run-demos.ps1                   # build AND run every demo
powershell -File scripts\check-banned-markers.ps1        # no retired name or design is back
powershell -File scripts\check-repository-layout.ps1     # no duplicate units
powershell -File scripts\check-format-isolation.ps1      # each format removable
powershell -File scripts\check-dependencies.ps1          # no GUI or DB in the core
powershell -File scripts\check-docs.ps1                  # links, orphans, counts
powershell -File scripts\check-source-audit.ps1          # dead code, references, pollution
powershell -File scripts\check-compiler-warnings.ps1     # zero warnings/hints (after a build)
powershell -File scripts\check-all.ps1                   # the working check
powershell -File scripts\validate-release.ps1            # the release gate
```

The individual scripts are the ones to run while working - seconds each.
`validate-release.ps1` is the one to run before calling something finished:
"it passes" is a claim about all of them at once and about both platforms,
and it states the release markers from what the runs wrote.

**What to read first and what to run after each kind of change is the
task-routing table in [`docs/agent-guide.md`](docs/agent-guide.md).** The
architecture is [`docs/architecture.md`](docs/architecture.md); each format
has one authoritative document, `docs/formats/<format>.md`.

Test projects worth knowing about before changing a format:

- `tests\TypeCoverage` - every Delphi type family through every format, one
  process per probe, against an expectation table in
  `TypeCoverage.dpr`. **A new refusal needs an `Allow()` entry with a
  reason**; a probe marked "must refuse" fails if any format accepts it.
- `tests\ReaderContracts` - a document of one shape read as another, through
  every format; and the ownership round trip.
- `tests\Dynamic` - the dynamic model, Delphi projection, every format and
  DataSet through Dynamic, and the shared metadata being discovered once.
- `tests\GeneralAttributes` - the three general attributes in every format,
  and every precedence rule against format-specific configuration.
- `tests\Robustness` - nesting bombs, huge lengths, entity and alias
  expansion, every truncation and hostile substitutions of every format's
  documents, threading, and plan-cache stability.
- `tests\Lifecycle` - explicit registration of every format family, and the
  automatic configuration freeze of every serializer.
- `tests\PackageProbe` - built by `scripts\check-packages.ps1` with runtime
  packages: loading Runtime registers no format, JSON alone and
  `RegisterAll` register what they say, and loading the DataSet package
  registers nothing.
- `tests\<Format>Native` - is the reader a real processor of the format: the
  feature ledger, malformed input, and an independent reference where one
  exists (MSXML for XML, protoc fixtures for Protobuf, the specifications'
  byte vectors for BSON and ASN.1).
- `tests\ConversionMatrix` and `tests\ContractMatrix` - every pair of formats,
  built from the registry, so a new format retests every earlier pair.
- `tests\FormatChain`, `tests\LosslessRouting`, `tests\DataSetFormats` - one
  document around every format; the standards-based routes; every format
  with every DataSet policy.

`demo\Conversion\06-LiveFormatConverter` is a VCL window and also a headless
self-test: `LiveFormatConverter.exe --selftest` presses every control from
code. `scripts\run-demos.ps1` runs it that way.

Build the packages from the IDE with the group project for your Delphi:
`projects\Delphi12\PascalForge.Serialization.Delphi12.groupproj` or
`projects\Delphi11\PascalForge.Serialization.Delphi11.groupproj`. The scripts
use Delphi 12 by default; set `PASCALFORGE_DELPHI=11` to run any of them with
Delphi 11.

## Before you change behaviour

1. **Check whether the feature already exists** - the list above, then
   `docs\customization.md` and `docs\api-reference.md`.
2. **Prefer the typed public API** over `TValue` and `PTypeInfo`.
3. **Do not expose engine internals** through the public facades.
4. **Do not change what a format writes** without a test that pins the new
   output and a documentation change.
5. **Do not weaken a test to make it pass** - no removing a probe, no new
   `Allow()` without a reason, no catching an exception and calling it a
   refusal.
6. **Do not duplicate a production unit.** There is one copy of each, in `src`.
7. **Keep every generated file under `artifacts\`.**
8. **Never add company-specific or private source to this tree.**
9. **Run the focused tests first, then `validate-release.ps1`.**
