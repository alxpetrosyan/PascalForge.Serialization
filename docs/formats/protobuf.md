# Protobuf

## Purpose

This is the entry point for the Protocol Buffers format. It summarizes what
the format does and where the code is. For depth, read
[`../protobuf-behavior.md`](../protobuf-behavior.md) (the contract-aware
engine), [`../protobuf-compatibility.md`](../protobuf-compatibility.md) (the
wire-format ledger and evidence) and
[`../protobuf-descriptors.md`](../protobuf-descriptors.md) (descriptor sets
and structural conversion). The shared API is in
[`../api-reference.md`](../api-reference.md).

Protobuf is a real engine. A Delphi value is written straight to protobuf
bytes and read straight back. There is no intermediate tree on the contract
path. The natural payload type is `TBytes`.

Protobuf is not self-describing. A message is a sequence of (field number,
wire type, payload), with no names. So the contract path needs a field
number on every member, and the structural path needs a descriptor.

## Standard/profile

- The **Protocol Buffers binary wire format**, complete
  (<https://protobuf.dev/programming-guides/encoding/>): varints up to ten
  bytes, tags, wire types 0, 1, 2 and 5, zig-zag, fixed widths, packed and
  unpacked repeated fields, maps, `oneof`, nested messages.
- **proto3 field semantics**: implicit presence for plain scalars, explicit
  presence for `TNullable<T>` and class references, packed by default,
  unknown fields preserved when there is a store for them.
- **proto2 groups** (wire types 3 and 4) are read and skipped as a unit.
  They are never written. proto2 `required` is read from descriptors.
- The schema is either the Delphi type with its attributes, or protoc's own
  `FileDescriptorSet` (`protoc --descriptor_set_out`).

Not implemented: a `.proto` parser, a code generator, extensions and `Any`
(they arrive as unknown fields), and well-known types other than
`google.protobuf.Timestamp` (they are ordinary messages). Protobuf has no
canonical encoding. The output is deterministic for a given value and
options. RPC and gRPC are out of scope.

## Public facade

Unit `PascalForge.Protobuf`, class `TProtobufSerializer`. All methods are
class static.

| Method | Signature |
| --- | --- |
| `Serialize<T>` | `(const AValue: T): TBytes`, and with `TProtobufSerializationOptions` |
| `Deserialize<T>` | `(const AData: TBytes): T`, and with `TProtobufSerializationOptions` |
| `DeserializeMessage<T>` | `(const AData: TBytes): TProtobufMessage<T>`, and with options; keeps the root's unknown fields |
| `SerializeMessage<T>` | `(const AMessage: TProtobufMessage<T>): TBytes`, and with options; writes them back after the known fields |
| `Populate<T>` | `(const AInstance: T; const AData: TBytes)` |
| `From<T>` | contract-aware: `(ASource: string / TBytes / TSerializationPayload; AFrom: TSerializationFormat): TBytes` |
| `TProtobufSchema.ToDynamic` / `FromDynamic` | `(const AData: TBytes; const AMessageName: string): TDynamicValue` / `(AValue: TDynamicValue; const AMessageName: string): TBytes` - on the loaded descriptor set, which Protobuf cannot be read without; see [`../dynamic.md`](../dynamic.md) |

`[SerializationIgnore]` removes a member even when it has a `[ProtoField]` number. `[SerializationName]` and `[SerializationEnum]` do not apply: Protobuf writes field numbers and enumeration numbers. See [`../attributes.md`](../attributes.md).

There is no non-generic `From`. A structural conversion into protobuf goes
through `TSerialization.Convert` with a descriptor (see Schema/context).
There is no `TryDeserialize`. The root must be a message: `Serialize<Integer>`
and `Serialize<TArray<T>>` raise.

`TProtobufSerializationOptions` (`Default`): `PackRepeated` (default `True`)
and `Schema`, a borrowed `TProtobufDescriptorSchema` that respells the root
message's scalar fields.

Configuration (call at startup):

- `RegisterEnumNumbers<T>(const ANumbers: array of Integer)`
- `RegisterTypeSerializer<T>(ASerializerClass: TProtoValueSerializerClass)`
- `FreezeConfiguration`, `IsFrozen`, `ResetConfiguration` (tests only)

Configuration freezes automatically at the first real serializer operation
(`Serialize`, `Deserialize`, `Populate`, the message envelope, or the
registry's typed calls). After that, configuration is immutable and
concurrent use is safe. A registration made after the freeze raises
`EProtobufInternalError` saying the configuration is frozen.
`FreezeConfiguration` freezes earlier. See
[`../configuration-lifecycle.md`](../configuration-lifecycle.md) for the full
lifecycle.

Exceptions: `EProtobufError`, `EProtobufInputError` (the bytes are at fault),
`EProtobufInternalError` (model or configuration), and `EProtobufSchemaError`
(in `PascalForge.Protobuf.Schema`: the descriptor set is at fault, or a name
is not in it).

## Explicit registry registration

```pascal
uses
  PascalForge.Protobuf.Registration;
...
TProtobufSerializationRegistration.RegisterFormat;
```

- Linking or importing `PascalForge.Protobuf.Registration` does **not**
  register the format.
- Loading the runtime package `PascalForge.Serialization.Runtime.bpl` does
  **not** register it.
- `RegisterFormat` is idempotent. It raises `ESerializationFormatConflict`
  if a different handler already holds `TSerializationFormat.Protobuf`.
- `UnregisterFormat` is safe when the format is absent, and never removes
  another unit's handler.
- `IsRegistered` reports whether this unit's handler holds the format.

Direct `TProtobufSerializer` use needs no registration, and neither does
using a `TProtobufSchema` on its own. Registration is needed only for
`TSerialization` (format chosen at run time), `TSerialization.Convert`, and
the `TDataSetSerializer` overloads that take a `TSerializationFormat`.

All formats at once: `TSerializationFormatsRegistration.RegisterAll` in unit
`PascalForge.Serialization.AllFormats`. It is also explicit.

Registry mutation happens at startup and shutdown. It must not run
concurrently with serialization.

## Native Delphi mappings

Every serialized member needs `[ProtoField(n)]`. A member without one is not
written. Numbers must be in 1..536870911 and outside 19000..19999; a
duplicate number is refused when the plan is built. A class that has members
but numbers none of them is refused, because its message would be empty.

| Delphi | .proto, by default (`TProtoScalar.Auto`) |
| --- | --- |
| `Boolean` and its variants | `bool` |
| `ShortInt` .. `Integer` | `int32` |
| `Byte`, `Word`, `Cardinal` | `uint32` |
| `Int64` / `UInt64` | `int64` / `uint64` |
| `Single` | `float` (fixed32) |
| `Double`, `Extended` | `double` (fixed64) |
| `Currency` | `sint64`, the scaled `Int64` Delphi stores |
| `string` | `string`, UTF-8 |
| `TBytes` | `bytes` |
| `TGUID` | `bytes`, the 16 bytes of the `TGUID` record as it is in memory |
| enumeration | its number (the ordinal, or `RegisterEnumNumbers`) |
| `TDateTime` | `google.protobuf.Timestamp` (`seconds`, `nanos`) |
| `TDate`, `TTime` | `string`, `yyyy-mm-dd` / `hh:nn:ss.zzz` |
| set | packed repeated enum |
| class, record | nested message |
| `TList<T>` and descendants, `TArray<T>` | repeated; numeric elements packed |
| `TDictionary<K,V>` and descendants | `map<K,V>` (entries: key field 1, value field 2) |
| `TNullable<T>`, class reference | explicit presence |
| plain scalar equal to its default | not written (implicit presence) |

Member attributes: `ProtoField`, `ProtoType` (`Int32`, `Int64`, `UInt32`,
`UInt64`, `SInt32`, `SInt64`, `Fixed32`, `Fixed64`, `SFixed32`, `SFixed64`,
`Float`, `Double`, `Bool`, `Text`, `Bytes`, `EnumValue`), `ProtoIgnore`,
`ProtoPacked`, `ProtoOneOf` (members sharing a name are exclusive; reading
one clears the others), `ProtoUnknown` (a `TBytes` store for unknown
fields, at any depth), `ProtoSerializer`.

Reading follows the field's declared scalar, as the specification says. An
`int32` or `uint32` field keeps the low 32 bits of a wider varint; an
`int64` field reads a `uint64` above `High(Int64)` as negative. The result
is then range-checked into the member: 300 into a `Byte` is refused. A
reader accepts packed and unpacked spellings whatever the plan says.
Without a `[ProtoUnknown]` member (or the message envelope), unknown fields
are dropped.

Dates and text:

- A `TDateTime` or `TDate` outside the years 1 to 9999 is refused on write
  (`ESerializationUnsupported`). A `Timestamp` outside them is refused on
  read (`EProtobufInputError`).
- A `Timestamp` has no zone. Nothing is written with an offset.
- `TDate` and `TTime` text is parsed by position, not by locale.
- A string field is UTF-8 by specification. Invalid UTF-8 is refused on read
  as `EProtobufInputError`. A string with an unpaired UTF-16 surrogate is
  refused on write (`ESerializationUnsupported`).

Full detail: [`../protobuf-behavior.md`](../protobuf-behavior.md),
[`../datetime-policies.md`](../datetime-policies.md),
[`../delphi-type-coverage.md`](../delphi-type-coverage.md).

## Structural representation

Only with a descriptor. The handler declares `ContractSerialize` and
`ContractDeserialize` always, and `StructuralParse` and `StructuralWrite`
only when the conversion options hold a `TProtobufSchema` or a
`TProtobufSerializationContext` for Protobuf. `ToDynamic` and `FromDynamic`
delegate to `TProtobufSchema.ToDynamic` / `FromDynamic`.

| Protobuf field (descriptor type) | `TDynamicValue` |
| --- | --- |
| `int32`, `sint32`, `sfixed32`, `uint32`, `fixed32` | `Int` |
| `int64`, `sint64`, `sfixed64` | `Int` |
| `uint64`, `fixed64` | `UInt` |
| `float`, `double` | `Float` |
| `bool` | `Bool` |
| `string` | `Str` |
| `bytes` | `Bytes` |
| enum | `Str`, the value name; `Int` when the descriptor has no name for the number |
| `google.protobuf.Timestamp` | `DateTime` |
| other message | `Obj`, members in declared field order, named by the `.proto` field name |
| repeated field | `Arr`, always |
| map field | `Obj`, keys rendered as text |
| absent field | absent |
| field the descriptor does not mention | dropped |
| group | refused (`EProtobufSchemaError`) |

On the way back, fields are written in declared order. A member the
descriptor does not name is refused by name, before anything is written. A
`null` is an absent field. A value is accepted only in a spelling the field
type allows: an `Int` or text integer for an integer field, base64 text for
`bytes`, a `DateTime` or instant text for a `Timestamp`, an enum name or
number for an enum. Anything else raises `EProtobufInternalError`.

A text payload handed to the Protobuf handler is refused with
`EProtobufInputError`. Protobuf reads bytes only.

## Lossless behavior

When Protobuf is the destination, the descriptor decides. There is no name
encoding: a member the descriptor does not declare has no field number, so
it is refused under every profile, including `Natural`. `Natural`,
`Lossless` and `Strict` produce the same bytes for a tree the descriptor
accepts.

When Protobuf is the source, unknown fields are already dropped on the way
into the tree. Use `DeserializeMessage` / `SerializeMessage` when they must
survive. `Lossless` then depends on the destination. See
[`../conversion.md`](../conversion.md).

## Contract-aware behavior

These depend on the Delphi type `T` (`Serialize<T>`, `Deserialize<T>`,
`TSerialization.Convert<T>`, `From<T>`):

- field numbers, `[ProtoType]`, `[ProtoPacked]`, `[ProtoOneOf]`,
  `[ProtoIgnore]` and `[ProtoUnknown]`;
- presence: implicit for plain scalars, explicit for `TNullable<T>`;
- `Currency` exact as scaled `sint64`, `TDate` and `TTime` as text;
- enum numbers from `RegisterEnumNumbers`;
- range checks into the member type (the input error);
- sets, collections, dictionaries as maps, custom serializers.

The contract path needs no descriptor: the Delphi type is the schema.
`TProtobufSerializationOptions.Schema` may still override the root message's
scalars, for example a `Currency` the `.proto` declares as `double`.

## Schema/context

Structural conversion needs a descriptor in the conversion options. Without
one it raises `ESerializationSchemaRequired`, **not**
`ESerializationFormatCapability`: the format can do it, given the schema.

```pascal
uses
  PascalForge.Protobuf.Schema;

Schema := TProtobufSchema.LoadDescriptorSet(
            TFile.ReadAllBytes('shop.desc'), 'shop.Order');
try
  Json := TSerialization.Convert(Wire, TSerializationFormat.Protobuf,
            TSerializationFormat.Json,
            TStructuralConversionProfile.Natural, Schema);
finally
  Schema.Free;
end;
```

- Produce the set with `protoc --descriptor_set_out=x.desc
  --include_imports x.proto`. Without `--include_imports` a type from
  another file does not resolve, and loading says so.
- The caller owns the schema. Nothing that receives it frees it.
- Which message the bytes are: `MessageName` (or the second
  `LoadDescriptorSet` argument). Left empty, the set must declare exactly one
  message that is not a map entry; otherwise the error lists the candidates.
- `TProtobufSerializationContext.Create(Schema, 'shop.Receipt')` names the
  message per conversion without touching the shared schema. Two contexts
  make Protobuf-to-Protobuf possible.
- `TSerialization.Convert(Source, From, To, Profile, AContext,
  ASecondContext)` takes one or two contexts. When both ends are Protobuf,
  build `TStructuralConversionOptions` with `WithSourceContext` and
  `WithDestinationContext`.
- `TSerialization.StructuralFormats(Options)` and
  `StructuralRequirement` report `schema` for Protobuf.

## DataSet behavior

With a contract, `TDataSetSerializer.CreateFDMemTable<T>(Bytes,
TSerializationFormat.Protobuf)` works like any other format. Without one, the
plain `CreateFDMemTable(Bytes, TSerializationFormat.Protobuf, Mode)` raises
`ESerializationSchemaRequired`. Pass the descriptor instead:
`TDataSetSerializer.Deserialize(Payload, TSerializationFormat.Protobuf,
Context, DataSet)`, or `CreateFDMemTable` / `CreateClientDataSet` with an
`ASchema: TSerializationContext`. The column names are the `.proto` field
names. See [`../dataset-formats.md`](../dataset-formats.md) and
[`../dataset-projection.md`](../dataset-projection.md).

| Protobuf field, through a descriptor | Inferred field type |
| --- | --- |
| 32-bit integer types, `uint32`, `fixed32` | `ftInteger` |
| `int64`, `sint64`, `sfixed64` beyond 32 bits | `ftLargeint` |
| `uint64`, `fixed64` | `ftLargeint` |
| `float`, `double` | `ftFloat` |
| `google.protobuf.Timestamp` | `ftDateTime` |
| `bytes` | `ftBlob` |
| `bool` | `ftBoolean` |
| `string`, enum by name | `ftWideString` |
| nested message, repeated message | `ftDataSet` (nested) |

A column's type is inferred from the values in it, so an `int64` column
whose values all fit 32 bits infers as `ftInteger`. An unset field is
absent, so a column can be all-null and fall back to `ftWideString`. A
`TDate` written by the contract path is a `string` field and infers as
`ftWideString`. `TDataSetSerializer.Serialize(DataSet,
TSerializationFormat.Protobuf, Policy)` has no context parameter, so it
raises `ESerializationSchemaRequired`.

## Custom serializers

Base classes in `PascalForge.Protobuf`:

- `TCustomProtoValueSerializer<T>`: override
  `SerializeValue(const AValue: T; out AWireType: TProtoWireType): TBytes`
  and `DeserializeValue(const AData: TBytes; AWireType: TProtoWireType;
  const AExisting: T): T`. Use this one.
- `TCustomProtoValueSerializerBase`: the untyped base with `TValue` and
  `PTypeInfo`, for a type not known at compile time.

The serializer chooses its own wire type, so a value object can be one
length-delimited blob rather than a nested message.

Registration:

```pascal
TProtobufSerializer.RegisterTypeSerializer<TCoordinate>(TCoordinateProto);
```

Per member: `[ProtoSerializer(TCoordinateProto)]`.

A read returns a new instance or the existing one it was given. See
[`../customization.md`](../customization.md) and
[`../deserialization-ownership.md`](../deserialization-ownership.md).

## Limits/security

| Limit | Value | Error |
| --- | --- | --- |
| write depth | 64 levels (each object, record, array, list, dictionary counts one) | `ESerializationLimitExceeded` |
| read nesting, contract path | 100 below the root (`PROTO_MAX_DEPTH`; 101 messages including the root); groups count too | `EProtobufInputError` |
| read nesting, descriptor path | 100 (`SCHEMA_MAX_DEPTH`) | `EProtobufInputError` |
| varint length | 10 bytes (`PROTO_MAX_VARINT_BYTES`) | `EProtobufInputError` |
| declared length | checked by subtraction against the enclosing message and the buffer, before allocation | `EProtobufInputError` |
| wire types 6 and 7 | refused | `EProtobufInputError` |
| field number 0 or above 2^29-1 | refused | `EProtobufInputError` |
| group without its end tag, or a mismatched one | refused | `EProtobufInputError` |
| invalid UTF-8 in a string field | refused | `EProtobufInputError` |
| wrong wire type for a descriptor field | refused, naming the field | `EProtobufInputError` |

Input errors name the byte offset. `tests\Robustness` covers nesting bombs,
huge lengths and truncation.

## Expected refusals

By design, not bugs:

- the refusals every format makes: pointers, procedural and method types,
  interfaces, class references, legacy `TList`, `TCollection`, streams,
  `Exception`, `TComponent`, cycles, inline static arrays, variant records,
  `TBcd` without a custom serializer;
- a value nested deeper than 64 levels;
- a `TDateTime` or `TDate` outside the years 1 to 9999, on write;
- an unpaired UTF-16 surrogate in a string, on write;
- a `Variant` of any kind: a field has one declared type;
- a repeated field of repeated fields (`TArray<TArray<T>>`), or a map whose
  value is a list;
- a null element in a repeated field, or a nil message element;
- a repeated field or map in a `oneof`;
- `TNullable<T>` of a list or map;
- `[ProtoType]` of another family (an `Integer` as `string`), at plan build;
- a value outside its declared scalar (5 000 000 000 as `int32`), on write;
- a non-message root, a duplicate or reserved field number, a class with
  members and no numbers;
- structural conversion, or a DataSet from bytes, with no descriptor;
- a member the descriptor does not declare, on structural write;
- a text payload given to the Protobuf handler.

Protobuf carries `UInt64` above `High(Int64)`, and NaN and infinities in
`float` and `double`. See [`../expected-refusals.md`](../expected-refusals.md).

## Interoperability evidence

- `tests\ProtobufReference` uses **fixtures produced by official protoc**
  (libprotoc 36.2), committed under `tests\fixtures\protobuf\reference\`:
  `ref-probe.proto`, its `.desc` descriptor set, a message encoded by
  `protoc --encode` and decoded by `protoc --decode`. The test reads protoc's
  descriptor set, decodes protoc's bytes, and encodes the same message and
  compares it with protoc's bytes exactly. The probe carries a packed
  repeated field, a map, a non-contiguous enum, a nested message, `sint64`,
  `fixed64` and a `Timestamp`. The test does not run protoc.
- `tests\ProtobufNative` uses the **encoding guide's worked examples**
  (Test1 to Test4), its varint table and its zig-zag table, byte for byte,
  in both directions. It also covers the wire-format ledger and malformed
  input.
- `tests\ProtobufSchema` builds a descriptor set with this library's
  contract engine and reads it with the descriptor reader, which shares no
  code with it. That is a cross-check, not independent evidence.

## Important implementation units

| Role | Unit |
| --- | --- |
| Facade | `src\PascalForge.Protobuf.pas` |
| Implementation | `src\PascalForge.Protobuf.Internal.pas` (`TProtoEngine`: wire codec, plans, direct value/bytes engine) |
| Registration | `src\PascalForge.Protobuf.Registration.pas` (`TProtobufSerializationRegistration`, `TProtobufFormatHandler`) |
| Schema | `src\PascalForge.Protobuf.Schema.pas` (`TProtobufSchema`, `TProtobufSerializationContext`, descriptor model, `ToDynamic` / `FromDynamic`) |
| Tests | `tests\ProtobufNative\ProtobufNative.dpr`, `tests\ProtobufNative\ProtoModels.pas`, `tests\ProtobufReference\ProtobufReference.dpr`, `tests\ProtobufSchema\ProtobufSchema.dpr`, `tests\ProtobufSchema\ProtobufSchemaModels.pas` |

## Before changing this format

1. Read [`../format-program.md`](../format-program.md),
   [`../protobuf-behavior.md`](../protobuf-behavior.md) and, for the
   structural path, [`../protobuf-descriptors.md`](../protobuf-descriptors.md).
2. Run `tests\ProtobufNative`, `tests\ProtobufReference` and
   `tests\ProtobufSchema`
   (`powershell -File scripts\test.ps1 -Only ProtobufNative`, and so on).
3. Run `tests\TypeCoverage` through `scripts\run-type-coverage.ps1`.
4. Run `tests\ReaderContracts`, `tests\ConversionMatrix` and
   `tests\Lifecycle`.
5. Do not change shared dynamic-model semantics (`TDynamicValue`, `TDynamicTag`,
   Core date and range helpers) from a format unit. Change Core deliberately,
   and retest every format.
6. A change to what Protobuf writes needs a test that pins the bytes and a
   documentation change. Keep the protoc fixture
   comparison passing; regenerate fixtures only with the commands recorded in
   `ref-probe.proto`.
7. Run `scripts\validate-release.ps1` before calling it finished.
