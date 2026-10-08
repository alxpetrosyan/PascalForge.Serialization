# Architecture

For a developer - or an AI coding agent - who has to change this library. What
the moving parts are, why they exist, which units are public, and where the
sharp edges are. Per-format detail lives in `docs/formats/<format>.md` - for
example [`formats/json.md`](formats/json.md); the task routing for agents is
in [`agent-guide.md`](agent-guide.md). The lifecycle is
[`configuration-lifecycle.md`](configuration-lifecycle.md), the runtime
packages [`packaging.md`](packaging.md).

---

## The shape

```text
                              Delphi type T
                                    |
               shared semantic / RTTI model  (PascalForge.Serialization.Core,
               .Metadata, .Attributes): a type's member surface and general
               attributes, discovered once; type keys, nullable families,
               containers, sets, range checks, ownership, the depth guard,
               date and number text
                                    |
          +-------------------------+--------------------------+
          |                                                    |
   direct format serializers                          dynamic structural model
   TJsonSerializer ... TAsn1Serializer                (TDynamicValue)
   one engine per format, cached plans                        |
          |                                          structural conversion
          |                                          Natural / Lossless / Strict
          |                                                    |
          +-------------------------+--------------------------+
                                    |
                           DataSet projection
                           (PascalForge.DataSet)
```

Three ways in:

| way in | when | needs the registry |
| --- | --- | --- |
| **Direct** - `TJsonSerializer.Serialize<T>` and its siblings | the format is known at compile time | no |
| **Generic** - `TSerialization.Serialize<T>(V, TSerializationFormat.Json)`, `Convert`, `TDataSetSerializer.CreateFDMemTable(Payload, AFormat)` | the format is a run-time choice | yes, explicit registration |
| **Structural** - `TSerialization.Convert(Payload, From, To, Profile)` | a document with no Delphi type | yes |
| **Dynamic** - `TJsonSerializer.ToDynamic`/`FromDynamic` and their siblings, `TSerialization.ToDynamic`/`FromDynamic`, `TDynamicSerializer` | a document as values, to build, inspect or change | direct: no; `TSerialization`: yes |

A format whose options decide the projection carries them in its own schema
context, never in Core's options: CSV's single-table options travel in a
`TCsvSchema`. A result that is not one payload has its own facade call: CSV
`SeparateTable` is `TCsvSerializer.TablesFrom` (a document, read through the
registry) or `SerializeTables` (a value), both returning a `TCsvDocumentSet`
built by the same table rules.

## Units, public and internal

```text
PascalForge.Serialization.Core      shared Delphi facts, the registry                     (public)
PascalForge.Serialization.Attributes  [SerializationName], [SerializationIgnore], [SerializationEnum]  (public)
PascalForge.Serialization.Internal  the shared RTTI metadata the engines build on          (INTERNAL)
PascalForge.Dynamic                 TDynamicValue/Object/Array, TDynamicSerializer        (public)
PascalForge.Dynamic.Internal        the Delphi <-> Dynamic projection engine              (INTERNAL)
PascalForge.Serialization           TSerialization: run-time format choice, conversion   (public)
PascalForge.Serialization.AllFormats  TSerializationFormatsRegistration.RegisterAll        (public)
PascalForge.Nullable                TNullable<T>                                          (public)
PascalForge.<Format>                facade: serializer, attributes, options               (public)
PascalForge.<Format>.Registration   T<Format>SerializationRegistration + the handler      (public)
PascalForge.<Format>.Schema         Protobuf descriptors, Avro schemas, ASN.1 modules     (public)
PascalForge.<Format>.Internal       the engine: plans, reader, writer                     (INTERNAL)
PascalForge.DataSet                 TDataSetSerializer: DTO <-> DataSet, any format       (public)
PascalForge.DataSet.Internal, .Packet  the projection engine and the packet               (INTERNAL)
PascalForge.DataSet.Json            TDataSet as JSON, DataSet members in JSON graphs      (public)
```

An `.Internal` unit is for the library's own units and its tests. If
application code seems to need one, the public facade is missing something.

Formats are siblings: no format unit references another, and deleting
`PascalForge.Bson.*` requires no edit anywhere else
(`scripts\check-format-isolation.ps1` builds every format alone). Each unit
holds its own attributes - `[JsonName]` in `PascalForge.Json`, `[DataSetName]`
in `PascalForge.DataSet`. The three general attributes live once, in
`PascalForge.Serialization.Attributes`, and a format's own attribute or
registration beats them for that format: see [`attributes.md`](attributes.md).

## Shared RTTI metadata

`TSerializationMetadata` (`PascalForge.Serialization.Internal`, an internal unit) holds the
format-neutral facts about a Delphi type, discovered on first request and
cached for the life of the process: its RTTI type, whether it is a record or
a class, its parameterless constructors, and its **member surface** -
public and published fields, then public and published readable properties,
a name redeclared by a descendant (compared case-insensitively, as Delphi
does) appearing once as the most-derived declaration. Each member carries
its type, whether it can be read and written, and what the general
attributes say about it, read once. `AllMembers` is the same fold over every
visibility, for JSON's member strategies.

Every engine - the eleven format engines, the DataSet projection and
Dynamic - gets a type's members from here and builds its own plan on top:
its own names and attributes, wire types, schemas and date rules stay in the
engine. What is shared is the member and type facts; format-specific work is
not. An engine still resolves for itself what only it needs - JSON its
construction factories and member strategies, the containers' `Add` and
enumerator methods through `TSerializationTypes`, Protobuf and Avro their
schemas - and CBOR, YAML, Avro and ASN.1, which build no plan, read their
own attributes per value. Nothing is discovered at unit initialization; the cache is filled
under a lock and never changes afterwards. `tests\Dynamic` checks that a
type is described once whichever engine asks first.

---

## Cached plans

Nothing is discovered by RTTI during serialization. The first time an engine
sees a type it builds a **plan** - the member list, offsets or accessors,
names, the resolved serializer, container accessors, nullable helpers, enum
mappings, date policies - caches it, and every later operation walks the plan.
If you find yourself adding an RTTI lookup inside a per-value read or write
method, it belongs in the plan instead.

Plans are built under the engine's lock and published before their members
are built, so a recursive type resolves to the plan in progress. If a build
fails, every provisional entry it published is rolled back (JSON:
`FBuildDepth` and `FBuildTrail`; the DataSet engine has the same mechanism);
a refused plan never stays cached, and the plan it was building is freed.

In the JSON engine: `TJsonTypePlan` is one class or record, `TJsonFieldPlan`
one member of it, `TJsonMemberPlan` a *value* - a root, a list element, a
dictionary key or value. In a member plan `Inner`, `Item`, `Key`, `Value` and
`DictAccess` are **owned**; `BoundPlan` is **borrowed** from the cache - freeing
it through a member plan is a double free.

The CBOR, YAML, Avro and ASN.1 engines build no plan: they take a type's
member list from the shared metadata and read their configuration tables and
member attributes per value; the lifecycle below is the same for them.

---

## Registration - two different things

**Format registration** puts a handler for a `TSerializationFormat` in the
registry (`TSerializationFormats` in Core), so that `TSerialization` can reach
the format by value. It is **always explicit**:

```pascal
TJsonSerializationRegistration.RegisterFormat;          // one format
TSerializationFormatsRegistration.RegisterAll;          // all of them
```

No unit registers a format from its `initialization` section, so linking a
registration unit, or loading the Runtime package, registers nothing.
`RegisterFormat` is idempotent; a *different* handler for a format already
held raises `ESerializationFormatConflict`; `UnregisterFormat` is a no-op when
the unit's own handler is not registered and never removes another. A
registration unit's `finalization` removes its own handler, so shutting
down - or unloading the Runtime package - leaves no handler whose code is
gone. `tests\FormatRegistry` scans
`src` and fails if any unit registers from its initialization.

**Serializer configuration** - `RegisterTypeSerializer`, `RegisterEnumMapping`,
field overrides, date policies - tells one engine how to handle a type. It is
per format, independent of the registry, and it freezes (below).

The registry hands out the handler itself, so **registry mutation must not run
concurrently with serialization**: register at startup, unregister at
shutdown.

## The configuration lifecycle

```text
register formats -> configure serializers -> first real operation -> frozen -> steady state
```

The first real operation of a serializer - the first plan built, the first
configuration looked up - freezes that serializer's configuration. A
registration made afterwards raises the format's own error saying so, because
cached plans already hold the old decision and a silent no-op would be worse.
`FreezeConfiguration` freezes earlier, at a point the application chooses.
After the freeze, plans and configuration are immutable and concurrent use is
safe. Per-operation options (`TJsonSerializationOptions` and the like) are
arguments, not configuration, and are never frozen.

`TDataSetJsonIntegration` - DataSet members inside JSON graphs - is enabled by
an explicit startup call, `TDataSetJsonIntegration.Register`, and its factory
and policies freeze when JSON or DataSet configuration freezes or when the
integration is first used. See
[`configuration-lifecycle.md`](configuration-lifecycle.md).

---

## The dynamic model, and conversion

`TDynamicValue` (`PascalForge.Dynamic`) is a format-independent document: null, booleans,
integers (with `UInt` for values past `High(Int64)`), floats, exact decimals,
text, bytes, date, time and instant as three kinds, arrays, objects with
ordered names, and `Extended` values carrying a tag for what a format has that
the others lack (a CBOR tag, an ObjectId, a big integer).

Member names are kept exactly as the source spelled them and `Find` matches
the exact spelling: `name`, `Name` and `NAME` are three members. Only an
array has unnamed children and only an object has named ones; an `Extended`
node's payload is `ExtendedValue`, not a child.

It is the library's one structural model and its **common document
builder**: `TDynamicObject` and `TDynamicArray` are built fluently, Delphi
values are projected into them through the shared metadata
(`TDynamicSerializer`, `Obj.Append(Person)`), and every format reads into and
writes from them (`T<Format>Serializer.ToDynamic`/`FromDynamic`,
`TSerialization.ToDynamic`/`FromDynamic`, `TDataSetSerializer.ToDynamic`/
`FromDynamic`). Dynamic is not a `TSerializationFormat`. Format-specific value
types (`TBsonValue`, `TCborValue`, `TAsn1Value`) remain for genuinely native
operations; there are no per-format document builders. See
[`dynamic.md`](dynamic.md).

**Structural conversion** reads a document into the tree with one handler's
`ToDynamic` and writes it with another's `FromDynamic`. The profile decides
what happens to what the destination cannot say:

| profile | a name the destination cannot spell | a value kind it does not have |
| --- | --- | --- |
| `Natural` | encoded reversibly | adapted to the destination's idiom |
| `Lossless` | the published standard for the pair (MongoDB Extended JSON, the W3C JSON/XML mapping) | the published standard, or refused |
| `Strict` | refused | refused |

Nothing is silently dropped. The one documented omission is `Natural`
writing into a schema-driven format (Avro, ASN.1): a member the schema does
not name is omitted, where `Strict` and `Lossless` refuse it with its path.
**Contract-aware conversion**
- `TSerialization.Convert<T>` - reads with A's engine into a `T` and writes
it with B's: the Delphi type is the contract, and each side applies its own
attributes. Prefer it whenever semantics matter. See
[`conversion.md`](conversion.md).

**Schema-driven formats** - Protobuf, Avro and the three ASN.1 formats -
carry no types in their bytes. Their contract path needs nothing (the Delphi
type is the schema); their structural path needs a descriptor set, an Avro
schema or an ASN.1 module in the conversion options, and without one raises
`ESerializationSchemaRequired`.

## DataSet projection

`TDataSetSerializer` projects a DTO, a list of them, or any document into a
live `TFDMemTable` or `TClientDataSet` - with the Delphi type as the schema,
or with a schema inferred from the document - and writes a DataSet back as a
document, snapshot or delta, in any format. `PascalForge.DataSet` needs no
format; the overloads that take a `TSerializationFormat` go through the
registry. `PascalForge.DataSet.Json` is TDataSet **as** JSON, in the same DataSet
runtime package.

---

## Ownership

One rule, for `Deserialize<T>` and `Populate` alike (they are one engine):
**reuse a compatible existing instance; construct only when there is nothing
to reuse; never destroy an object the serializer cannot prove it owns.** A
document's `null` detaches, never frees. A container's contents are replaced
through its own `Clear`, which asks it what it owns. An array member is
replaced, not refilled. A failed read frees what it built - including objects
inside records and arrays, and the elements of a list or dictionary it built
- and nothing else (`TSerializationOwnership.ReleaseBuilt` and siblings).
Whether a type can hold an object at all is decided by
`TypeMayHoldObjects`, which walks the type to any depth and stops only at a
type it is already inside. See
[`deserialization-ownership.md`](deserialization-ownership.md).

The registry boundary is type-erased: `SerializeTyped` **borrows**,
`DeserializeTyped` **transfers**; `ToDynamic` transfers the tree,
`FromDynamic` borrows it. `TSerializationOwnership.Release` discharges a
transferred temporary.

## Custom serializers

Every format has a typed base class - `TCustomJsonValueSerializer<T>`,
`TCustomCborValueSerializer`, ... - registered per type
(`RegisterTypeSerializer<T>`) or per member (an attribute). A serializer class
is instantiated once and shared across threads, so it must be stateless. A
serializer's read returns an instance the read may own: a new one or the
existing one it was given, never a cached or shared one. See
[`customization.md`](customization.md).

## The depth guard and cycles

Every writer counts one level for each object, record, array, list,
dictionary and `Variant` array it descends into, on one per-thread counter
(`TSerializationGraphGuard`), and refuses the 65th with
`ESerializationLimitExceeded`. Objects and containers also enter a cycle set,
so a value that holds itself is refused as a cycle (JSON can write the
back-reference as null under `TJsonRecursiveReferencePolicy.WriteNull`).
Every reader has its own nesting, length and expansion limits.

## Threading

Serializer instances, handlers, plans and the shared metadata are shared
across threads and hold no per-operation state. A dynamic value is an
ordinary object: one thread changes it at a time. Plans are built under a lock; `tests\Robustness`
races eight threads into a cold type in every format. Steady-state use is safe
concurrently once configuration is frozen - which the first use does - and as
long as nobody mutates the registry at the same time.

## The error model

| exception | means |
| --- | --- |
| `E<Format>InputError` | the document is at fault: malformed, or not the shape the contract says |
| `E<Format>InternalError` / `E<Format>Error` | the model or configuration is at fault, including a late configuration after the freeze |
| `ESerializationUnsupported` | a value no format here can state: a date outside the years 1 to 9999, an unpaired surrogate |
| `ESerializationLimitExceeded` | a value nested past 64 levels |
| `ESerializationFormatNotRegistered` | a format nobody registered - the message names the call |
| `ESerializationFormatConflict` | a different handler already holds the format |
| `ESerializationFormatCapability` | registered, but cannot do this |
| `ESerializationSchemaRequired` | a schema-driven format asked for structural work without its schema |

A refusal is the library speaking in its own exception class, with the member
and the reason. An RTL exception reaching the caller from a read or write is
a defect.

---

## Engine notes

**Type identity.** `TRttiType.QualifiedName` raises `ENonPublicType` for a
type declared in an implementation section or a `.dpr`;
`TryTypeQualifiedName` in Core is the only place allowed to touch it.
`TypeKeyOf` gives `'MyUnit.TFoo'`, or `'TFoo'` when no unit is known, never
`'.TFoo'`. `GenericFamilyKeyOf` reduces a closed generic to declaring unit,
base name and arity - how generic-family serializers and nullable families
match. Container classification walks the class ancestry, so
`TOrders = class(TObjectList<TOrder>)` is a list.

**Non-public RTTI.** Eligibility for a structural plan is
`HasUsableStructuralRtti` - does member enumeration work - never
`IsPublicType`; an implementation-section class serializes its own members.

**Construction.** One path: a registered factory, then a declared
zero-argument constructor, then `TObject.Create`; a type with only
parameterised constructors and no factory raises, saying so.

**Nullable families** are decided once, in Core, for every format:
`TSerialization.RegisterNullableFamily<T>`. See
[`nullable-families.md`](nullable-families.md).

**Text and bytes.** Encoding is an explicit step at the edge -
`StringToUtf8Bytes`, which refuses an unpaired surrogate, and a strict decoder
that refuses malformed input by offset. See
[`unicode-and-utf8.md`](unicode-and-utf8.md).

**Two traps.** `TJSONNumber` descends from `TJSONString`, so
`AJson is TJSONString` is true for every JSON number. And `Populate` and
`Deserialize<T>` are one engine: do not thread per-operation mode switches
through the recursive calls.
