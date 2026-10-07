# Protobuf descriptors

How a `FileDescriptorSet` makes protobuf self-describing, and what that buys.

[`protobuf-behavior.md`](protobuf-behavior.md) covers the contract-aware
engine, where a Delphi type and its `[ProtoField]` attributes are the schema.
[`protobuf-compatibility.md`](protobuf-compatibility.md) is the codec ledger.
This page is about the other schema: the one protoc emits.

---

## Why

A protobuf message is a sequence of (field number, wire type, payload) and
nothing else. There are no names, and a length-delimited field might be a
string, a byte array, a nested message or a packed run of integers. Given only
the bytes, a reader recovers the shape and not the meaning.

That is why `PascalForge.Protobuf.Registration` declares only the two
contract-aware capabilities when it is handed nothing — and all four when it
is handed a descriptor.

A descriptor is the `.proto` **the other end was compiled against**, which
makes it a better authority than any opinion this side could form from a
Delphi type.

## Getting one

```
protoc --descriptor_set_out=shop.desc --include_imports shop.proto
```

`--include_imports` matters. A field whose type lives in another file will not
resolve without it, and loading such a set raises an error that says exactly
this.

```pascal
uses
  PascalForge.Protobuf.Schema;

Schema := TProtobufSchema.LoadDescriptorSet(
            TFile.ReadAllBytes('shop.desc'), 'shop.Order');
try
  ...
finally
  Schema.Free;
end;
```

The caller owns the schema and frees it. Nothing that receives one in
conversion options frees it — that is the library-wide rule for schemas.

There is **no `.proto` parser here and there is not going to be one**. A
`.proto` file is protoc's input; a `FileDescriptorSet` is protoc's output.
That output is itself an ordinary protobuf message, so reading it needs this
library's own codec and nothing else — which is what the parser in
`PascalForge.Protobuf.Schema` is. A second implementation of the `.proto`
grammar would be a second thing to keep correct, for no gain over running the
tool that already exists.

## What is read

Enough of `descriptor.proto` to describe data:

| Message | Fields read |
| --- | --- |
| `FileDescriptorSet` | `file` |
| `FileDescriptorProto` | `name`, `package`, `message_type`, `enum_type`, `syntax` |
| `DescriptorProto` | `name`, `field`, `nested_type`, `enum_type`, `options.map_entry` |
| `FieldDescriptorProto` | `name`, `number`, `label`, `type`, `type_name`, `json_name`, `options.packed`, `oneof_index`, `proto3_optional` |
| `EnumDescriptorProto` | `name`, `value` |
| `EnumValueDescriptorProto` | `name`, `number` |

Services, extensions, custom options and source-code info are **skipped as
unknown fields**, which is what any protobuf reader does with what it was not
compiled to understand. They describe RPC and tooling, not the shape of a
message.

`json_name` is used when present and computed from the declared name when not.

## Which message are these bytes?

A descriptor set describes many messages and a protobuf document does not say
which one it is. There is no header, no name, nothing. The conversion options
have nowhere to carry the answer either, so the **schema** carries it:

```pascal
Schema.MessageName := 'shop.Order';
```

Leave it empty and the set is used only if it declares exactly one message
that is not a map entry. Anything else raises and **names the candidates**,
because picking one would be picking how to misread the document.

```pascal
Names := Schema.MessageNames;               // every message, fully qualified
Msg   := Schema.FindMessage('shop.Order');  // nil when absent
Msg   := Schema.RequireMessage('shop.Order');  // raises, listing what is there
```

## The model

```pascal
TProtoMessageDescriptor
  Name, FullName, IsMapEntry, Proto3
  FieldCount, Fields[], FieldByNumber(n), FieldByName(s)
  NestedCount, Nested[]

TProtoFieldDescriptor
  Name, JsonName, Number, TypeName
  FieldType: TProtoFieldType     // descriptor.proto's own numbers
  FieldLabel: TProtoFieldLabel   // Optional, Required, Repeated
  MessageType, EnumType          // resolved, borrowed
  IsRepeated, IsRequired, IsMap, IsPackable, IsPacked

TProtoEnumDescriptor
  Name, FullName, ValueCount, ValueNames[], ValueNumbers[]
  TryName(number), TryNumber(name)
```

`FieldByName` matches the declared name first and `json_name` second, so a
tree written by another implementation's proto3 JSON output is understood
without the caller renaming anything.

`IsPacked` is the *effective* answer: the explicit option if there is one,
otherwise proto3's default of packed and proto2's of not. Reading accepts both
spellings regardless, as the specification requires.

## Bytes into a named tree

```pascal
Tree := Schema.ToDynamic(Wire);                    // uses MessageName
Tree := Schema.ToDynamic(Wire, 'shop.Line');       // or name it per call
```

The rules, exactly:

* **an object per message**, its members in **declared field order**, not
  arrival order, so two encodings of the same message produce the same tree;
* the member name is the **`.proto` field name as declared** — not
  `json_name`. A conversion to XML, to CSV or to a DataSet column wants the
  name the schema author wrote, and the proto3 JSON mapping's lowerCamelCase
  is a rule about JSON that this tree is not;
* a **repeated** field is an array, always, even with one element;
* a **map** field is an object, its keys the map keys rendered as text;
* an **absent** field is absent. proto3 cannot tell a field set to its default
  from one never set, and writing `0` for every unset int would be inventing
  data the document does not contain;
* an **enum** is the value *name* as a string, or the number when the
  descriptor has no name for it — proto3 requires a reader to keep an
  unrecognized enum value rather than reject the message;
* `int64`, `uint64`, `fixed64` and `sfixed64` are **exact** `Int` or `UInt`
  nodes. The proto3 JSON mapping spells them as strings because JavaScript
  numbers are doubles; the dynamic tree has real 64-bit integers, so it uses
  them, and each destination writer then applies its own rules;
* `google.protobuf.Timestamp` is a **DateTime** node. It is the well-known
  type for an instant and the contract-aware path already writes a `TDateTime`
  as one, so the two agree;
* a field the descriptor **does not mention is dropped**. A tree names its
  members and an unknown field has no name. Use
  `TProtobufSerializer.DeserializeMessage` when unknown fields must survive.

## A tree back into bytes

```pascal
Wire := Schema.FromDynamic(Tree);
Wire := Schema.FromDynamic(Tree, 'shop.Line');
```

* fields are written in **declared order**, so the same tree always produces
  the same message;
* a member the descriptor **does not name is refused**, by name, before
  anything is written. Dropping data on the way *into* an encoding is the
  failure this library exists to prevent, and the asymmetry with reading is
  deliberate;
* a member spelled once by its declared name and once by its `json_name` is
  refused too — which of the two is meant has no answer;
* a `null` is an **absent** field. proto3 has no null, and writing a zero
  would be inventing a value;
* a repeated field must be an **array**, with one element or none.

### The spellings another implementation may send

These are read **because the descriptor says so**. Nothing here guesses from
the shape of the text: a schema is one of the three authorities allowed to say
what a value is (the others being the source format's own native type and the
Delphi contract).

| Tree node | Field type | Read as |
| --- | --- | --- |
| `Str` `"4815162342"` | `int64` | the integer — the proto3 JSON spelling |
| `Str` `"AQIDAP8="` | `bytes` | base64 — the proto3 JSON spelling |
| `Str` `"2024-03-01T12:30:45.000"` | `Timestamp` | the instant |
| `Str` `"STATUS_PAID"` | an enum | that symbol's number |
| `Int` `10` | an enum | the number itself |
| a member under its `json_name` | any | that field |

## Who decides what a `Currency` is

A Delphi `Currency` is written as an `sint64` at Delphi's own scale of ten
thousand, which is exact. If the `.proto` says the field is a `double`, the
`.proto` wins:

```pascal
Options := TProtobufSerializationOptions.Default;
Options.Schema := Schema;                  // MessageName must be set
Wire := TProtobufSerializer.Serialize<TShipment>(Shipment, Options);
```

`TProtobufSchema.TryFieldScalar` is the one question the engine asks the
descriptor, and it applies to the **root** message's scalar fields. Field
numbers are scoped to a message, so a schema that knew only the root's numbers
would otherwise reinterpret every message in the tree.

Only a scalar can be respelled this way. A descriptor that called a nested
message a string would not be describing this data at all.

## Through the registry

```pascal
Payload := TSerialization.Convert(Source, TSerializationFormat.Protobuf,
             TSerializationFormat.Json,
             TStructuralConversionProfile.Natural, Schema);
```

* with no schema, `TSerialization.StructuralFormats` does not list Protobuf,
  and `Capabilities` reports only the contract-aware pair;
* with one, all four are reported and Protobuf joins the conversion ring;
* asking for a structural conversion without one raises
  `ESerializationSchemaRequired` — **not** the capability error. The format
  *can* do this and would, given the descriptor, and the two failures have
  different fixes.

A DataSet follows from the same thing, through the existing format-agnostic
projection:

```pascal
Cds := TDataSetSerializer.CreateClientDataSet(Payload,
         TSerializationFormat.Protobuf, Schema, nil);
```

The column names are the `.proto` field names. There is no protobuf-specific
DataSet code anywhere.

## What is proven, and how

`tests/ProtobufSchema` runs **143 checks**.

There is no protoc on this machine, so the descriptor set the test uses is
**built here** — written by this library's contract-aware engine from Delphi
types that mirror `descriptor.proto`, then read back by the descriptor reader,
which shares no code with the writer. A mistake in either half shows up as a
disagreement rather than as two matching mistakes. Byte sequences that can be
computed by hand from the specification are written out in hex and compared
literally.

Covered: loading and rejecting descriptor sets, nested types, map entries,
enum name and number lookup both ways, `json_name` computation and matching,
packed defaults for proto3 and proto2, `proto2` `required`, resolution
failures naming `--include_imports`, root-message selection and its ambiguity
error, `TryFieldScalar` for every scalar type, the whole `ToDynamic` rule set
above, the whole `FromDynamic` rule set, the proto3 JSON spellings, Unicode
including a non-BMP character and a combining mark, the registry capability
flip, Protobuf-to-JSON and JSON-to-Protobuf, the DataSet projection, and the
descriptor overriding a `Currency`.

## Not implemented, and why

* **No `.proto` parser.** See above.
* **No code generator.** Generating Delphi source from a descriptor is a
  different program.
* **Groups** (`TYPE_GROUP`, proto2) are read by the contract-aware path and
  **refused by name** by the structural one.
* **`Any`, `Struct`, `Value`, `FieldMask` and the wrapper types** are ordinary
  messages here. Only `Timestamp` is given a meaning, because the
  contract-aware path already writes a `TDateTime` as one and the two have to
  agree.
* **Unknown fields are dropped** on the way into the tree. The envelope —
  `TProtobufSerializer.DeserializeMessage` / `SerializeMessage` — is how they
  survive, and it is described in
  [`protobuf-behavior.md`](protobuf-behavior.md).
