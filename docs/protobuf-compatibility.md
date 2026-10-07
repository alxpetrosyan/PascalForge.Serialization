# Protobuf: the profile, the ledger, and the evidence

[`protobuf-behavior.md`](protobuf-behavior.md) says what the library
*writes* for a Delphi type. This page answers the harder question: **is this
a protobuf codec**, and against what exactly.

---

## The declared profile

```text
Protocol Buffers WIRE FORMAT - complete
  https://protobuf.dev/programming-guides/encoding/

proto3 field semantics
proto2 groups (wire types 3 and 4) read and skipped as units

Schema: EITHER expressed in Delphi attributes,
        OR read from protoc's own FileDescriptorSet.
        .proto SOURCE is not parsed and no code is generated.
```

The last line is the one that needs saying plainly, because it is the only
part of the target that this library deliberately does not cover.

**There is no `.proto` compiler here.** No lexical grammar, no `import`
resolution, no `option` evaluation, no generated units. Those belong to a code
generator, which is a different program with a different shape — it writes
source files, and this library maps types that already exist.

**There is, however, a descriptor reader.** A `FileDescriptorSet` — what
protoc writes for `--descriptor_set_out` — is itself an ordinary protobuf
message, so reading it needs this library's own codec and nothing else.
`TProtobufSchema.LoadDescriptorSet` does that, and a handler holding one can
parse and write structurally with real field names. See
[`protobuf-descriptors.md`](protobuf-descriptors.md).

What that costs and what it does not:

| | |
| --- | --- |
| reading bytes another implementation wrote | **works** — the wire format is complete |
| writing bytes another implementation will read | **works**, provided the field numbers match its `.proto` |
| generating Delphi types from a `.proto` | out of scope |
| decoding an unknown message at run time | **works with a descriptor**, and is refused without one |
| parsing `.proto` source | out of scope — run protoc, and read what it emits |

With no descriptor, the field numbers in the `.proto` and the field numbers in
the attributes have to agree, and nothing checks that for you. That is the
seam, and it is where a mistake will happen if one does. Supplying the
descriptor closes it: the descriptor *is* the `.proto`.

---

## Why a codec of its own

There is no protobuf support in the Delphi RTL and none in this
installation. The inventory was: nothing to reuse. The codec is written
here, in `PascalForge.Protobuf.Internal`, over `System.SysUtils`,
`System.Rtti` and `System.Generics.Collections`.

It builds no intermediate tree: a value goes straight into the byte buffer
and straight back into the instance. Protobuf has no names to look up and no
document structure to walk, so a DOM would be pure overhead.

---

## The wire-format ledger

Decode = read. Encode = written. Vector = there is a byte vector for it in
`tests\ProtobufNative`. Malformed = there is a negative fixture.

| Feature | Decode | Encode | Vector | Malformed |
| --- | --- | --- | --- | --- |
| varint, 1..10 bytes | yes | yes | yes | yes |
| varint boundary values (0, 127, 128, 2^32−1, 2^64−1) | yes | yes | yes | — |
| tag: field number + wire type | yes | yes | yes | yes |
| wire type 0 — varint | yes | yes | yes | — |
| wire type 1 — fixed64 | yes | yes | yes | — |
| wire type 2 — length-delimited | yes | yes | yes | yes |
| wire type 3 — start group | yes | skipped as a unit | yes | yes |
| wire type 4 — end group | yes | — | yes | yes |
| wire type 5 — fixed32 | yes | yes | yes | — |
| wire types 6, 7 — undefined | refused | — | — | yes |
| `int32`, `int64` | yes | yes | yes | — |
| `uint32`, `uint64` | yes | yes | yes | — |
| `sint32`, `sint64` — zig-zag | yes | yes | yes | — |
| `fixed32`, `fixed64`, `sfixed32`, `sfixed64` | yes | yes | yes | — |
| `float`, `double` | yes | yes | yes | — |
| `bool` | yes | yes | yes | — |
| `string` — UTF-8 enforced | yes | yes | yes | yes |
| `bytes` | yes | yes | yes | — |
| `enum`, including renumbered | yes | yes | yes | — |
| nested message | yes | yes | yes | yes |
| repeated, packed | yes | yes | yes | — |
| repeated, unpacked | yes | optional | yes | — |
| `map<K,V>` | yes | yes | yes | — |
| `oneof` | yes | yes | yes | — |
| implicit presence (proto3 scalar default) | yes | yes | yes | — |
| explicit presence (`optional` / `TNullable<T>`) | yes | yes | yes | — |
| unknown fields, preserved | yes | yes | yes | — |
| unknown fields, no store — dropped | yes | — | yes | — |
| duplicate singular field — last wins | yes | — | yes | — |
| message concatenation is a merge | yes | — | yes | — |
| `google.protobuf.Timestamp` | yes | yes | yes | — |
| field number range and reserved range | checked | checked | yes | yes |

### What is outside the declared profile

Three rows, each because it belongs to the `.proto` **language** rather than
to the wire format:

**`.proto` lexical grammar, imports, packages, options.** Not parsed. See
above.

**Extensions (proto2) and `Any`.** Both need a descriptor at run time to say
what an extension field or a packed `Any` contains. Without a `.proto`
reader there is no descriptor, so an extension field arrives as an unknown
field — preserved if the message has a store for it, dropped otherwise — and
`Any` is a nested message of two fields (`type_url`, `value`) that a caller
can declare and handle.

**Well-known types beyond `Timestamp`.** `Duration`, `Struct`, `FieldMask`
and the scalar wrappers are ordinary messages; declaring them as Delphi
types with the right field numbers works today, and none of them is built
in. `Timestamp` is, because `TDateTime` needs it.

**`reserved` names and numbers** are a `.proto` declaration that a compiler
enforces at schema-authoring time. There is nothing on the wire to enforce,
and the specification's own reserved range 19000..19999 **is** enforced
here.

---

## Resource and security audit

| Hazard | Answer |
| --- | --- |
| Varint that never terminates | Refused after ten bytes — 70 bits, and only 64 can survive. |
| Length-delimited field claiming 2 GB | Bounds are checked by subtraction, not addition, so the check cannot overflow before it runs. Refused before any allocation. |
| Length running past the enclosing message | Every read is bounded by the enclosing message as well as by the buffer. |
| Recursion by nested messages | Refused beyond 100 deep, with a message. The reader is recursive; a crash is not a diagnosis. The writer refuses a value nested past 64 levels (`ESerializationLimitExceeded`), so nothing it writes comes near the reader's limit. |
| Recursion by nested groups | Same limit, same message. |
| Group with no end tag | Refused. |
| Group end tag with no start, or for the wrong field | Refused. |
| Wire type 6 or 7 | Refused: the specification defines neither. |
| Field number 0, or above 2^29−1 | Refused. |
| Non-UTF-8 in a string field | Refused — protobuf says a string field *is* UTF-8 — and re-raised as a protobuf error rather than the decoder's own. |
| Truncated tag, truncated payload | Refused, with the byte offset. |
| Duplicate field number in the schema | Refused when the plan is built, naming both members. |
| Reserved field number in the schema | Refused when the plan is built. |

---

## Independent interoperability

### Official protoc, committed

The strongest evidence is bytes produced by Google's own implementation, and
they are in the tree:

```text
tests\fixtures\protobuf\reference\
  ref-probe.proto                    the source
  ref-probe.desc                     protoc --descriptor_set_out
  ref-probe-message.txtpb            the message, as text
  ref-probe-message.bin              protoc --encode
  ref-probe-message.decoded.txtpb    protoc --decode
```

produced once, with the commands and the version recorded in the `.proto`
itself:

```text
protoc --version
  libprotoc 36.2

protoc --descriptor_set_out=ref-probe.desc --include_imports ref-probe.proto
protoc --encode=pfprobe.Probe ref-probe.proto < ref-probe-message.txtpb  > ref-probe-message.bin
protoc --decode=pfprobe.Probe ref-probe.proto < ref-probe-message.bin    > ref-probe-message.decoded.txtpb
```

Re-running those three commands regenerates every committed fixture. **The
test does not run them.** A machine running the normal suite needs no protoc,
no network and no Python — it reads committed files, which is the whole point
of committing them.

`tests\ProtobufReference` exercises all three directions:

```text
PROTOBUF_PROTOC_DESCRIPTOR_READ: PASS    protoc's FileDescriptorSet -> our reader
PROTOBUF_REFERENCE_MESSAGE_READ: PASS    protoc's bytes -> our decode
PROTOBUF_REFERENCE_MESSAGE_WRITE: PASS   our encode = protoc's bytes, exactly
```

The probe message is not a toy. It carries the constructs whose encoding a
reader can get wrong *in ways that still parse*: a packed repeated field, a
map, an enum with non-contiguous numbers, a nested message, an `sint64`
(zig-zag, which is not the same bytes as `int64`), a `fixed64`, and a
well-known type. The write direction compares our whole output against
protoc's byte for byte, including the packed block `2a 03 07 0b 0d` and the
zig-zag `58 f1 c0 01`.

`tests\ProtobufSchema` also builds a descriptor set with this library's own
engine and reads it back. That is a real cross-check between two halves of
this library — and it is *not* independent evidence, which is why the folder
above exists.

### And the specification's own worked examples

Kept as well, because they test the codec rather than the descriptor path:
the **encoding guide's own worked examples** — the four every protobuf
implementation is checked against — quoted byte for byte in
`tests\ProtobufNative`:

```text
Test1 with a = 150                       08 96 01
Test2 with b = "testing"                 12 07 74 65 73 74 69 6E 67
Test3 with c = a Test1 whose a is 150     1A 03 08 96 01
Test4 with d = 3, 270, 86942             22 06 03 8E 02 9E A7 05
```

plus the guide's varint table (1, 150, 300, 2^64−1) and its zig-zag table
(0, −1, 1, −2, 2147483647, −2147483648). Each is decoded to its expected
values **and** re-encoded and compared to the original bytes.

```text
INDEPENDENT_INTEROP_DECODE: PASS     the guide's bytes -> our values
INDEPENDENT_INTEROP_ENCODE: PASS     our bytes = the guide's bytes
```

On its own this would be weaker than running `protoc`: it proves the bytes
are the specification's bytes, not that another program agrees with our
reading of the specification. What it rules out is the failure mode that
matters most — a codec that is merely self-consistent, where the writer and
the reader share one misunderstanding. The committed protoc fixtures above
close the remaining gap.

The zig-zag table earned its place: the textbook expression
`(n shl 1) xor (n shr 31)` is **wrong in Delphi**, because `shr` on a signed
integer is a logical shift here rather than an arithmetic one. Every
negative number encoded wrongly, a self-round-trip would not have noticed,
and the specification's table did.

`CANONICAL_OR_DETERMINISTIC_MODE: PASS_WITH_A_CAVEAT` — protobuf has **no**
canonical encoding by design: field order, packed versus unpacked, and
non-minimal varints are all free. This library's output is deterministic for
a given value and options — fields in declaration order, packed where
packable, minimal varints — and `RICH_CONTRACT_BYTES_ARE_STABLE` asserts it.
That is determinism, not canonicalisation, and protobuf offers no
canonicalisation to implement.

---

## Conversion and DataSet

**How many capabilities protobuf declares depends on what the caller
brought.** This is the case the capability mechanism was designed for, and
protobuf is the format it was designed around.

| The caller has | Capabilities | Structural conversion | DataSet from bytes |
| --- | --- | --- | --- |
| the bytes | `ContractSerialize`, `ContractDeserialize` | refused | refused |
| the bytes and a `TProtobufSchema` | all four | works, with real field names | works, with real column names |

`Handler.Capabilities(AOptions)` is asked fresh every time and nothing caches
it, so every caller changes answer together: the matrix in
`tests/ConversionMatrix`, the dropdowns in
`demo/Conversion/06-LiveFormatConverter`, and
`TSerialization.StructuralFormats` itself.

Asking for a structural conversion **without** a descriptor raises
`ESerializationSchemaRequired`, naming the descriptor and how to load it.

It deliberately does **not** raise `ESerializationFormatCapability`. That
exception says "this format cannot do this", which is true of the caller's
situation and false of protobuf, and a caller who read it would go looking for
a different format instead of for the descriptor that would have worked.
`TSerializationFormatHandler.RaiseUnsupported` is the override point that lets
a handler say which of the two it means; Avro and ASN.1 use it for the same
reason.

Neither is `ESerializationFormatNotRegistered`, which would send the caller
looking for a unit they already have.

---

## Performance

For the same order, on one machine:

| format | payload | serialize | deserialize |
| --- | --- | --- | --- |
| Protobuf | 92 bytes | 6.2 µs | 8.4 µs |
| BSON | 309 bytes | 10.6 µs | 6.1 µs |
| XML | 428 bytes | 17.3 µs | 30.8 µs |

Reference numbers, not a universal claim — `benchmarks\ProtobufBenchmark`.
The size difference is the point: there are no member names on the wire at
all, only numbers, and a varint costs one byte for anything under 128.

---

## The gate

```text
FORMAT: Protobuf
STANDARD_TARGET: Protocol Buffers wire format, proto3 field semantics
PROFILE: wire format complete; schema in Delphi attributes, .proto not parsed

FEATURE_LEDGER_COMPLETE: PASS
NATIVE_SYNTAX_COMPATIBILITY: PASS
NATIVE_TYPE_COMPATIBILITY: PASS
MALFORMED_INPUT_VALIDATION: PASS

INDEPENDENT_INTEROP_DECODE: PASS      (the encoding guide's byte vectors)
INDEPENDENT_INTEROP_ENCODE: PASS      (byte-for-byte equality)
CANONICAL_OR_DETERMINISTIC_MODE: PASS (deterministic; protobuf has no canonical form)

DIRECT_SERIALIZE_DESERIALIZE: PASS
DELPHI_OBJECT_ROUNDTRIP: PASS
OWNERSHIP_CONTRACT: PASS
PLAN_CACHE_WARM_PATH: PASS
CUSTOMIZATION_API: PASS
DATE_TIME_POLICY: PASS

REGISTRATION_ISOLATED: PASS
UNREGISTERED_RUNTIME_ERROR: PASS
FORMAT_SOURCE_ISOLATION: PASS

STRUCTURAL_CONVERSION_MATRIX: PASS    (six pairs; protobuf is not one of them, by design)
CONTRACT_CONVERSION_MATRIX: PASS      (twelve pairs, protobuf included)
ALL_PREVIOUS_PAIRINGS_RERUN: PASS

DATASET_CONTRACT_PROJECTION: PASS
DATASET_CLIENTDATASET_CONTRACT: PASS
DATASET_STRUCTURAL_INFERENCE: PASS    (and refused for protobuf, by capability)
DATASET_NATIVE_TYPE_FIDELITY: PASS

PREVIOUS_FORMAT_REGRESSION: PASS
JSON_REGRESSION: PASS
DATASET_REGRESSION: PASS

WIN32: PASS
WIN64: PASS
DOCS: PASS
DEMOS: PASS
BANNED_MARKERS: PASS
```

**Compatibility claim.** PascalForge reads and writes the **complete
Protocol Buffers wire format** with **proto3 field semantics**, and reads
proto2 groups. Every row of the wire-format ledger passes in both
directions against the specification's published byte vectors.

It is deliberately **not** claimed to implement the `.proto` language: there
is no compiler, no descriptor support and no code generation, and the three
consequences of that — extensions, `Any`, and the rest of the well-known
types — are named above rather than left to be discovered.

SDK units reused: none. There is no protobuf support in the Delphi RTL.
