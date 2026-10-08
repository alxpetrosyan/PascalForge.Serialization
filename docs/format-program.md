# The format program

A format is not finished because a DTO round-trips. That only proves the
reader understands the writer.

Every format in this library goes through the same sequence, and none of it
is optional:

```text
 1  lock the exact specification, version and profile
 2  build a complete feature ledger - no row removed for being difficult
 3  prove native decoding and encoding against that ledger
 4  validate malformed input, including the resource attacks
 5  prove interoperability against an independent reference
 6  integrate the shared RTTI plans
 7  format-specific attributes, options and custom serializers
 8  direct round trip
 9  structural conversion, both directions, against every other format
10  contract-aware conversion, both directions, against every other format
11  DataSet contract projection and schema inference
12  rerun every earlier pairing
13  rerun the JSON and DataSet regressions
14  Win32 and Win64
15  documentation and demos
```

Step 12 is the one that is easy to promise and hard to keep, so it is not a
promise: `tests\ConversionMatrix` asks the **registry** which formats exist
and builds the matrix from that. Adding a format retests every earlier pair
automatically, because there is no list to forget to update.

Getting a format into that registry is one edit.
`tests\Shared\AllFormatsRegistered.pas` calls
`TSerializationFormatsRegistration.RegisterAll` from its initialization - test
scaffolding making the explicit call - so a test that includes it has every
implemented format registered without naming any of them. Each of the six
formats that arrived after Protobuf
includes it, and each one's native test then converts to and from **every
structurally capable format the registry reports**, printing the result
pair by pair:

```text
cbor -> Json -> cbor: identical
cbor -> Xml -> cbor: identical
cbor -> Bson -> cbor: identical
cbor -> MessagePack -> cbor: identical
cbor -> Yaml -> cbor: identical
cbor -> Csv: ECsvProjectionError
```

The last line is not a failure. A tree with a nested object cannot become a
table, CSV refuses by name rather than inventing a column, and the check is
that every pair was attempted and accounted for — not that every pair comes
back identical.

`tests\ConversionMatrix`, `tests\FormatChain` and `tests\DataSetFormats`
build their matrices from the registry the same way, but their uses clauses
still name registration units one at a time: four in the first, three in the
other two. So the table in `artifacts\conversion-matrix.md` is JSON, XML,
BSON and Protobuf, and the other six formats are paired against their
predecessors in their own native tests instead. Including
`AllFormatsRegistered` in those three programs is one line each and widens
the generated table to everything registered.

---

## The order they arrived

```text
 1  JSON          6  MessagePack
 2  XML           7  YAML
 3  BSON          8  CSV
 4  Protobuf      9  Avro
 5  CBOR         10  ASN.1 - BER, DER and CER
```

That is the order of `TSerializationFormat` in
`PascalForge.Serialization.Core`, and it is the order of `$formatStems` in
`scripts\build.ps1`, which is commented as the order each format joined the
library. The two agree because a format is appended to the enumeration when
it is implemented, never reserved ahead of itself.

**CSV was inserted before Avro**, after the numbered task packs that
commissioned the work had been written, and the packs were **not**
renumbered afterwards. A pack number is therefore a historical label and not
a position in the list above. Renumbering them would have quietly rewritten
what was asked for and in what order, which is worse than a numbering that
no longer counts from one.

ASN.1 is one entry here and **three** values of the enumeration. X.680
defines the types and X.690 defines three ways of writing one down; BER
permits several encodings of the same value, and DER and CER are each a
canonical subset of BER with *different* canonical rules. The enumeration
identifies representations, so it has three.

---

## Where each format stands

| Format | Target | Schema |
| --- | --- | --- |
| JSON | RFC 8259 | in the document |
| XML | XML 1.0 Fifth Edition + Namespaces 1.0, non-validating, no external entities | in the document |
| BSON | BSON 1.1, every element type | in the document |
| Protobuf | Protocol Buffers encoding; proto3 semantics; descriptor sets loaded, `.proto` text not parsed | **outside** — a `FileDescriptorSet` |
| CBOR | RFC 8949 / STD 94 | in the document |
| MessagePack | the current specification, every format family | in the document |
| YAML | YAML 1.2.2 | in the document |
| CSV | a real dialect-aware parser; tabular by nature | in the document, weakly |
| Avro | Apache Avro 1.12.0 | **outside** — a schema, and a reader schema too |
| ASN.1 BER/DER/CER | X.690, three encoding rules | **outside** — an X.680 module |

A format that is *reserved* is a name in the enumeration and nothing else:
no stub, no partial implementation, no silent fallback. Asking for one
raises `ESerializationFormatNotRegistered` naming the unit that does not
exist yet. `docs\architecture.md` has the current state of each; `scripts\check-format-isolation.ps1` prints
`ISOLATION_SKIPPED_NOT_PRESENT` for any that are still names.

**There are no reserved names left.** Every value of `TSerializationFormat`
has a unit that implements it and a registration unit that puts it in the
registry, so that script prints no `ISOLATION_SKIPPED_NOT_PRESENT` line at
all and builds sixteen probe applications per platform: one for each of the
ten formats alone, five combinations, and one containing every format. The
rule above is kept for the next format rather than describing anything in
the enumeration today.

### The schema column is the important one

Seven of these formats say what their own contents are and three do not —
counted as values of `TSerializationFormat` that is seven against five,
because ASN.1 is three of them. The difference runs through the whole design
rather than being a detail of three implementations.

A self-describing format can be read structurally by anyone: the bytes carry
the names and the types. A **schema-driven** format cannot, at all. A
Protobuf message is (field number, wire type, payload); an Avro datum is a
bare sequence of values; an ASN.1 encoding is tags and lengths. There is
nothing in any of them to read the document *as*.

So schema-driven formats do not get a weaker structural implementation —
they get one that **requires the schema as an argument**:

```pascal
Schema  := TProtobufSchema.LoadDescriptorSet(DescriptorBytes);
Payload := TSerialization.Convert(Bytes,
             TSerializationFormat.Protobuf, TSerializationFormat.Json,
             TStructuralConversionProfile.Natural, Schema);
```

and without it they raise `ESerializationSchemaRequired` rather than
inventing field names from field numbers. Capability follows the same rule:
`TSerializationFormats.Capabilities(Protobuf)` answers contract-only, and
`Capabilities(Protobuf, OptionsCarryingTheSchema)` answers all four. See
`docs\conversion.md`.

A schema is needed for **structural** conversion only. The contract-aware
path needs nothing extra from any of the three, because the Delphi type is
the contract: Protobuf reads its field numbers from the type's attributes,
Avro generates the schema from the type and hands it back so the caller can
publish it beside the bytes, and ASN.1 takes the encoding rule as an
argument. `TSerialization.StructuralRequirement` gives the one-word answer —
`'yes'` for the seven self-describing formats, `'schema'` for Protobuf, Avro
and the three ASN.1 values — and `'schema'` rather than `'no'` is the
difference between a wall and a door.

---

## The packages

Two packages, in one folder per Delphi version (`projects\Delphi11`,
`projects\Delphi12`), each built by that folder's group project:

| package | contains |
| --- | --- |
| `PascalForge.Serialization.Runtime.dpk` | the core - `TSerializationFormat`, the registry, the handler contract, the dynamic model, the internal metadata, `PascalForge.Nullable` - and every format with its registration unit, plus `PascalForge.Serialization.AllFormats` |
| `PascalForge.Serialization.DataSet.dpk` | the DataSet projection, and TDataSet as JSON (`PascalForge.DataSet.Json`) |

**A new format's units go into the Runtime package's `contains` list** -
in every version folder - and
its registration unit with them; Runtime requires `rtl` and nothing else,
and `scripts\check-packages.ps1` fails if that changes. Isolation between
formats is not expressed in the packaging any more but in source, where
`scripts\check-format-isolation.ps1` proves that each format links alone.

The DataSet package requires Runtime and `dbrtl`, `dsnap` and FireDAC, which
is the whole reason it is a separate package - an application that only
serializes objects should not ship any of that. No package shares its name
with a unit it contains - see [packaging.md](packaging.md).

A package does not register anything by being linked. An `initialization`
section runs when its unit is reachable from the application's uses graph,
so shipping the Runtime package and never mentioning
`PascalForge.Cbor.Registration` leaves CBOR unregistered — which is what
makes `ESerializationFormatNotRegistered` nameable rather than mysterious.

---

## Where each format's behaviour is written down

Each format's contract — what it writes for a Delphi value, its attributes,
its enum mappings, its date policy — is its own document. They do not share
rules and the documents do not cross-reference as if they did.

| format | behaviour document |
| --- | --- |
| JSON | `docs\serializer-behavior.md` |
| XML | `docs\xml-behavior.md` |
| BSON | `docs\bson-behavior.md` |
| Protobuf | `docs\protobuf-behavior.md` |
| CBOR | `docs\cbor-behavior.md` |
| MessagePack | `docs\messagepack-behavior.md` |
| YAML | `docs\yaml-behavior.md` |
| CSV | `docs\csv-behavior.md` |
| Avro | `docs\avro-behavior.md` |
| ASN.1 | `docs\asn1-behavior.md` |

**All ten are in `docs\`.** Protobuf has a third, `protobuf-descriptors.md`,
because its schema lives outside the document and loading one is its own
subject.

*Which* standard, in what profile, with the full feature ledger and the
security audit, is a second document for the first four formats:
`docs\xml-compatibility.md`, `docs\bson-compatibility.md` and
`docs\protobuf-compatibility.md`. For CBOR, MessagePack, YAML, CSV, Avro and
ASN.1 the ledger is the one transcribed into the native test, row by row,
beside the check that exercises it, and each behaviour document's *What is
proven, and how* section summarises it and names the oracle.

---

## What "complete" means, and what it does not

**Complete** means every row of that format's ledger passes in both
directions, malformed input is refused with a message rather than a crash,
and an independent reference agrees. The ledger and the evidence are in the
format's own compatibility document, and so is every exclusion.

It does **not** mean the format's every feature has a Delphi type. BSON's
decimal128 has none, so it is carried as sixteen bytes and says so. XML's
validating-processor behaviour is out of profile, and says so. Those are
written down in the ledger rather than discovered later.

**A missing row is a failure, not a deferral.** If a ledger row cannot pass,
the honest outcome is either to implement it or to narrow the declared
profile and name the exclusion — never to leave the row blank.

---

## The evidence, per format

| | XML | BSON | Protobuf |
| --- | --- | --- | --- |
| ledger rows | 39 | 23 element types | 31 wire-format rows |
| native test | `tests\XmlNative` | `tests\BsonNative` | `tests\ProtobufNative` |
| independent reference | MSXML, both directions | the specification's byte vectors, both directions | the encoding guide's byte vectors, both directions |
| malformed fixtures | 20 | 14 | 13 |
| resource audit | 10 hazards | 13 hazards | 13 hazards |
| benchmark | `benchmarks\XmlBenchmark` | `benchmarks\BsonBenchmark` | `benchmarks\ProtobufBenchmark` |

All three compatibility documents carry the full gate.

---

## Lossless is somebody else's standard, or it does not happen

Step 9 — structural conversion against every other format — used to be met by
writing a wrapper of this library's own into the destination document: a
reserved member name in JSON, an attribute in a namespace of ours in XML. It
round-tripped, and it was worthless to every tool that was not this one.

It is gone, and the rule that replaced it is part of the program:

* a `Lossless` conversion uses the **published standard** for that pair of
  formats — the W3C JSON/XML mapping, MongoDB Extended JSON — or
* it **refuses**, with `TStructuralIssue.UnsupportedLosslessConversion` and a
  message naming a route that works.

A new format joining the program answers the same question: for each pair it
forms, is there a published lossless mapping? If yes, implement it and cite
it. If no, say so in the ledger and let `Lossless` raise. **Inventing one is
not an option**, and `scripts\check-banned-markers.ps1` reports
`PASCALFORGE_STRUCTURAL_METADATA_REFERENCES: 0` to keep it that way.

---

## Not every format can do everything

Protobuf is the first format here whose schema lives **outside** the
document, and it made the shape of the program visible.

A protobuf message is (field number, wire type, payload) with no names, so
there is no honest way to read one without something that describes it —
either the Delphi type, or the `.proto`.

So its handler declares **two capabilities or four, depending on what the
caller brought**:

- the **contract-aware** matrix includes it always, in both directions,
  against every other format;
- the **structural** matrix includes it exactly when a `TProtobufSchema` is in
  the conversion options. Asking without one raises
  `ESerializationSchemaRequired`, which names the descriptor and how to load
  it — deliberately **not** `ESerializationFormatCapability`, which would say
  the format cannot do this when in fact only this caller cannot.

`TSerializationFormatHandler.RaiseUnsupported` is the override point that lets
a handler choose between those two sentences. Avro and the three ASN.1
formats use it for exactly the same reason.

`tests\ConversionMatrix` builds the two matrices from two registry queries, so
each schema-driven format gets the same treatment with no edit.
