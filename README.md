# PascalForge Serialization

An RTTI-based serialization library for Delphi. Twelve encoded
representations - JSON, XML, BSON, Protocol Buffers, CBOR, MessagePack,
YAML, CSV, Avro, and ASN.1 in all three of its encoding rules (BER, DER,
CER) - for the classes and records you already have, typed customization
when a default is not what you want, projection of data into a live
`TDataSet`, and conversion between any of them.

No code generation, no base class to inherit from, no interface to implement.

**Version 1.0.0.** Tested with Delphi 12 Athens (12.3) and Delphi 11 Alexandria (11.3), Win32 and Win64.
**License: MIT** ([`LICENSE`](LICENSE)).

## Quick start

```pascal
uses
  PascalForge.Json;

type
  TCustomer = class
  public
    Id: Integer;
    [JsonName('fullName')]
    Name: string;
  end;

Json := TJsonSerializer.Serialize<TCustomer>(Customer);
Customer2 := TJsonSerializer.Deserialize<TCustomer>(Json);
```

That is all a known format needs: **the direct serializers need no
registration.**

```pascal
uses
  PascalForge.Xml, PascalForge.Bson, PascalForge.Protobuf;

Xml   := TXmlSerializer.Serialize<TCustomer>(Customer);
Bson  := TBsonSerializer.Serialize<TCustomer>(Customer);    // TBytes

// Protobuf has no names on the wire, so every member needs a number.
Proto := TProtobufSerializer.Serialize<TShipment>(Shipment);  // TBytes

// A Delphi string is Unicode text. Bytes are a separate, explicit request.
Utf8 := TJsonSerializer.SerializeUtf8<TCustomer>(Customer); // TBytes, no BOM
```

## Documents without a Delphi type - Dynamic

Not every document has a DTO behind it. `TDynamicValue`, `TDynamicObject`
and `TDynamicArray` are a document as values: build one once, then write it
in any format, or read any format into one, change it and write it out.

```pascal
uses
  PascalForge.Dynamic, PascalForge.Json, PascalForge.Bson;

Obj := TDynamicObject.Create;
try
  Obj
    .Append('name', 'Erin')
    .Append('age', 35);
  Obj.InsertAt(1, 'country', 'Utopia');
  Obj.AddObject('address')
    .Append('city', 'Uptown');
  Obj.Append('customer', Customer);       // a Delphi object, projected

  Json := TJsonSerializer.FromDynamic(Obj);
  Bson := TBsonSerializer.FromDynamic(Obj);
finally
  Obj.Free;
end;

Doc := TJsonSerializer.ToDynamic(Json);   // any format back into a value
```

Members keep their order and their exact names; replacing one is explicit;
ownership and cycles are checked; unsigned 64-bit integers, exact decimals,
binary, dates and every format's native values (a BSON ObjectId, a CBOR tag)
survive. Dynamic is not a format: it is the value every format reads into and
writes from. `TDynamicSerializer.Serialize<T>` and `Deserialize<T>` move a
Delphi value in and out, and `TDataSetSerializer.ToDynamic` and
`FromDynamic` do the same for a DataSet. See [`docs/dynamic.md`](docs/dynamic.md).

## Choosing the format at run time - register explicitly

`TSerialization` picks a format by value, so the format has to be in the
registry, and **registration is always an explicit call**:

```pascal
uses
  PascalForge.Serialization,
  PascalForge.Json.Registration;

begin
  TJsonSerializationRegistration.RegisterFormat;       // once, at startup

  Payload := TSerialization.Serialize<TCustomer>(
    Customer,
    TSerializationFormat.Json
  );
```

Naming `PascalForge.Json.Registration` in a uses clause does **not**
register JSON; the call does. Every format - or all of them at once:

```pascal
uses
  PascalForge.Serialization.AllFormats;

begin
  TSerializationFormatsRegistration.RegisterAll;       // explicit too
```

`RegisterAll` is explicit: merely adding `PascalForge.Serialization.AllFormats`
to a uses clause registers nothing. With the formats registered, conversion
works the same way:

```pascal
Cbor := TSerialization.Convert<TCustomer>(Payload,
          TSerializationFormat.Json, TSerializationFormat.Cbor);
```

CSV is tabular, so how a tree becomes rows is a CSV option. Single-table
options travel through `TSerialization.Convert` in a `TCsvSchema`; a
projection into several tables (`SeparateTable`) returns a document set, so
it has its own call, which reads the source through the registry:

```pascal
Tables := TCsvSerializer.TablesFrom(Payload, TSerializationFormat.Json,
  TCsvOptions.Default.WithCollectionMode(TCsvCollectionMode.SeparateTable));
// Tables[0].Name = 'customers', Tables[1].Name = 'customers_orders', ...
```

See [`docs/formats/csv.md`](docs/formats/csv.md).

A format nobody registered raises `ESerializationFormatNotRegistered`, and
the message names the call to make. See
[`docs/configuration-lifecycle.md`](docs/configuration-lifecycle.md).

```pascal
uses
  PascalForge.DataSet;

DS := TDataSetSerializer.CreateFDMemTable<TCustomer>(Customer);          // a value: no registration

// a document names its format, so that format must be registered
DS := TDataSetSerializer.CreateFDMemTable<TCustomer>(Json,
        TSerializationFormat.Json);                                       // with a contract
DS := TDataSetSerializer.CreateFDMemTable(Json, TSerializationFormat.Json); // no contract: the document decides
```

## Two kinds of representation

```text
                      Delphi semantic model
                    class / record / scalar
                               |
                 +-------------+-------------+
                 |                           |
        encoded representations       runtime projections
        -----------------------       -------------------
        JSON                          TDataSet
        XML
        BSON
        Protobuf      (a descriptor to be read structurally)
        CBOR
        MessagePack
        YAML
        CSV
        Avro          (a schema, always)
        ASN.1 BER
        ASN.1 DER     (three encodings, not one with three names)
        ASN.1 CER
```

An **encoded representation** is text or bytes, which a
`TSerializationPayload` carries: persistence, interchange, storage,
transport, caching, archiving. A **runtime projection** is a live `TDataSet`
with ownership, fields, rows and cursor state - which is why DataSet
projection has its own facade rather than a `TSerializationFormat` value.
Both share one foundation: RTTI metadata, type identity, nullable families,
collection recognition, member access, construction and cached plans.

## What it carries, and what it refuses

Every format was put through the same 62 Delphi type families - integers at
both ends of their range, every float type, every string type, enumerations,
sets up to 256 members, static and dynamic arrays, records of every kind,
inheritance, properties, lists, dictionaries, queues, stacks, `TStrings`,
nullables, Variants, dates, GUIDs, graphs - and every one of the 744 cells
either carries the value exactly or refuses it with the library's own
exception and a reason. None faults, none changes a value silently, none
raises a bare RTL exception. The matrix is
[`docs/delphi-type-coverage.md`](docs/delphi-type-coverage.md); every
deliberate refusal - pointers, method pointers, interfaces, class references,
streams, variant records, a cycle - is reviewed in
[`docs/expected-refusals.md`](docs/expected-refusals.md).

| | |
| --- | --- |
| **Classes and records** | fields and properties, managed records, inheritance, nested to 64 levels deep |
| **Collections** | `TList<T>`, `TObjectList<T>`, `TDictionary<K,V>`, `TObjectDictionary<K,V>`, `TQueue<T>`, `TStack<T>`, `TStrings`, and your own descendants, recognised by ancestry |
| **Arrays** | dynamic and static, including offset bounds and several dimensions |
| **Nullable values** | `TNullable<T>`, and any nullable family you teach it |
| **Enumerations and sets** | by name, by ordinal, or mapped to the strings your API expects |
| **Variants** | by value and family, in the formats with a dynamic value of their own |
| **Customization** | per type or per member, as a class or as a function, in one direction or both |
| **Existing objects** | `Populate` fills a graph you own; a failed read frees what it built and nothing else |
| **Untrusted input** | every reader refuses a document that does not match the contract, with its own exception, and enforces nesting, length and expansion limits |
| **Format-specific attributes** | one member can be `shipmentId` in JSON, a `ShipmentID` attribute in XML, `_id` in BSON and field 1 in Protobuf, all at once |
| **Conversion** | contract-aware through the Delphi type, or structural for a document you have no type for: what a destination cannot represent is refused or documented - `Natural` omits a member a schema-driven destination's schema does not name; `Strict` and `Lossless` refuse it |
| **Unicode** | text is Unicode end to end; UTF-8 is an explicit, separate API |
| **Dates and times** | `TDate`, `TTime` and `TDateTime` distinct all the way through, from the source format's own types - never from what a string looks like |
| **DataSets** | objects into `TFDMemTable` or `TClientDataSet`; a document into a dataset with your contract or an inferred schema; a dataset's schema, rows or delta as a document |
| **Threads** | configuration freezes at first use; plans are cached once and shared safely |

## Installing

Add `src` to your unit search path, or open the group project for your
Delphi - `projects\Delphi12\PascalForge.Serialization.Delphi12.groupproj` or
`projects\Delphi11\PascalForge.Serialization.Delphi11.groupproj` - and build
the two runtime packages: `PascalForge.Serialization.Runtime` - the core and every format,
requiring the RTL only - and the optional `PascalForge.Serialization.DataSet`
- the DataSet projection and TDataSet-as-JSON, which adds Data.DB, FireDAC and
DataSnap. Compiled from source, a program still links only the formats it
names. See [`docs/packaging.md`](docs/packaging.md).

**Loading a package is not registering a format:**

```pascal
// PascalForge.Serialization.Runtime<suffix>.bpl loaded: no format is registered
TJsonSerializationRegistration.RegisterFormat;       // JSON, and only JSON
TSerializationFormatsRegistration.RegisterAll;       // or every format
```

```text
src\
  the shared core - every format needs these
    PascalForge.Serialization.Core.pas   RTTI primitives, nullable families,
                                         the format registry, the dynamic tree
    PascalForge.Nullable.pas             TNullable<T>
    PascalForge.Serialization.pas        pick a format at run time
    PascalForge.Serialization.AllFormats.pas
                                         RegisterAll / UnregisterAll

  one set per format - take the ones you use
    PascalForge.<Format>.pas              the facade and the format's attributes
    PascalForge.<Format>.Internal.pas     the engine; never used directly
    PascalForge.<Format>.Registration.pas T<Format>SerializationRegistration:
                                          only for run-time choice and conversion
    for Json, Xml, Bson, Protobuf, Cbor, MessagePack, Yaml, Csv, Avro, Asn1
    PascalForge.Protobuf.Schema.pas       protoc descriptor sets
    PascalForge.Avro.Schema.pas           Avro schemas
    PascalForge.Asn1.Schema.pas           ASN.1 modules

  the DataSet projection
    PascalForge.DataSet.pas                  data -> a live TDataSet
    PascalForge.DataSet.Internal.pas         the projection engine
    PascalForge.DataSet.Packet.pas           a dataset as a document
    PascalForge.DataSet.Json.pas             a TDataSet <-> JSON, and live
                                             datasets inside JSON graphs
                                             (TDataSetJsonIntegration.Register)
```

`TDataSetJsonIntegration` is declared in the unit
`PascalForge.DataSet.Json` (runtime package
`PascalForge.Serialization.DataSet`); import it with
`uses PascalForge.DataSet.Json;`, and call
`TDataSetJsonIntegration.Register` once at startup.

Name the facade of the format you want - `PascalForge.Json`,
`PascalForge.Xml`, `PascalForge.Cbor` and so on. That is the whole uses
clause: each format's attributes live in its own facade. A
`*.Registration` unit - and its explicit `RegisterFormat` call - is needed
**only** for choosing a format at run time or converting between formats; a
format you do not name is not linked at all,
which `scripts\check-format-isolation.ps1` proves by building a probe for
every format alone and in combination.

Requires Delphi with extended RTTI. Tested with Delphi 12 Athens (12.3) and
Delphi 11 Alexandria (11.3), Win32 and Win64: every test, demo and package
builds and passes on both. Earlier versions are not tested.
The DataSet layer needs FireDAC and DataSnap; the formats need neither, and
`scripts\check-dependencies.ps1` proves from the linker map that a console
program on Core and JSON links no VCL, FMX, FireDAC or Data.DB.

## Attributes

```pascal
type
  TDevice = class
  public
    [JsonName('accountNumber')]          // a different name on the wire
    Number: string;

    [JsonIgnore]                         // never written, never read
    CachedScore: Currency;

    [JsonSerializer(TMoneySerializer)]   // this member, this serializer
    Score: TMoney;
  end;
```

Every format has its own: `[XmlName]`, `[BsonName]`, `[ProtoField]`,
`[CborName]`, `[YamlName]` and so on, and each engine reads only its own.

Three **general** attributes say it once for every format, for Dynamic and
for the DataSet projection - and a format's own attribute or registration
still beats them, for that format only:

```pascal
uses
  PascalForge.Serialization.Attributes;

  [SerializationName('account_number')]   // every format's name for it
  Number: string;
  [SerializationIgnore]                   // in no format at all
  PasswordHash: string;
  [SerializationEnum('open,closed')]      // the text of each value
  State: TAccountState;
```

The precedence, format by format, is in [`docs/attributes.md`](docs/attributes.md).

## Customizing a type

Write a serializer against the Delphi type:

```pascal
type
  TMoneySerializer = class(TCustomJsonValueSerializer<TMoney>)
  public
    function SerializeValue(const AValue: TMoney): TJSONValue; override;
    function DeserializeValue(const AJson: TJSONValue): TMoney; override;
  end;

TJsonSerializer.RegisterTypeSerializer<TMoney, TMoneySerializer>;
```

Both type parameters are checked by the compiler. For something too small to
deserve a class, register functions instead - for one member or a whole
type, in one direction or both:

```pascal
TJsonSerializer.RegisterFieldOverride<TInvoice>('Comment',
  TJsonFieldOverride.SerializeWith<string>(
    function(const Value: string): TJSONValue
    begin
      Result := TJSONString.Create(Value.Trim);
    end,
    function(const Json: TJSONValue): string
    begin
      Result := Json.Value.Trim;
    end));
```

Register everything once at startup. A type's plan is cached the first time
it is used, so a registration after that could not reach it: **the first
real operation freezes the serializer's configuration**, and a later
registration raises instead of being silently ignored. `FreezeConfiguration`
freezes earlier, at a point you choose.

## DataSets

```pascal
TDataSetSerializer.CreateStructure<TEntry>(DataSet);       // schema only
TDataSetSerializer.Fill<TEntry>(Entry, DataSet);           // rows into a schema
TDataSetSerializer.CreateAndFill<TEntry>(Entry, DataSet);  // both

FD  := TDataSetSerializer.CreateFDMemTable<TEntry>(Entry);  // yours to free
CDS := TDataSetSerializer.CreateClientDataSet<TEntry>(Entries);
```

A dataset itself as a document, in any format:

```pascal
Payload := TDataSetSerializer.Serialize(DataSet, TSerializationFormat.Xml,
             TDataSetSerializationPolicy.StructureAndRows);
Table := TDataSetSerializer.CreateFDMemTable(Payload,
           TSerializationFormat.Xml, TDataSetSourceMode.Auto);
```

See [`docs/dataset-formats.md`](docs/dataset-formats.md).

## Tests, demos and the release gate

```powershell
powershell -File scripts\build.ps1                    # library, Win32 + Win64
powershell -File scripts\test.ps1                     # public tests, Win32
powershell -File scripts\test.ps1 -Platform Win64
powershell -File scripts\run-type-coverage.ps1        # 62 type families x 12 formats
powershell -File scripts\run-demos.ps1                # build AND run every demo
powershell -File scripts\check-all.ps1                # the working check
powershell -File scripts\validate-release.ps1         # the release gate, both platforms
```

Everything generated goes to `artifacts\`, which is gitignored.

The demos are meant to be read in order:

```text
demo\Json\01-Basic                  serialize, deserialize, populate
demo\Json\02-AttributesAndEnums     names, ignores, enum mapping
demo\Json\03-CustomSerialization    serializer classes and delegates
demo\Json\04-Collections            lists, dictionaries, nesting
demo\DataSet\01-Projection          objects into both dataset kinds
demo\DataSet\02-DataSetJson         a dataset as the payload
demo\Conversion\04-ContractAware    the same document, four ways
demo\Conversion\05-ProfilesAndUnicode
                                    names XML cannot spell, the three
                                    structural profiles, and UTF-8
demo\Conversion\06-LiveFormatConverter
                                    a VCL window over every format
```

`demo\Xml`, `demo\Bson`, `demo\Protobuf` and the rest of `demo\Json`,
`demo\DataSet` and `demo\Conversion` have more; the other formats are
shown in their `tests\<Format>Native` projects and in
[`docs/api-reference.md`](docs/api-reference.md).

## Documentation

| | |
| --- | --- |
| [`docs/api-reference.md`](docs/api-reference.md) | every public call, format by format |
| [`docs/delphi-type-coverage.md`](docs/delphi-type-coverage.md) | 62 Delphi type families through 12 formats, cell by cell |
| [`docs/expected-refusals.md`](docs/expected-refusals.md) | every deliberate refusal, and what solves it |
| [`docs/limitations.md`](docs/limitations.md) | what it does not do, and why |
| [`docs/architecture.md`](docs/architecture.md) | the architecture: plans, the dynamic tree, registration, ownership, threading, errors |
| [`docs/configuration-lifecycle.md`](docs/configuration-lifecycle.md) | register formats, configure, freeze, steady state, shutdown |
| [`docs/packaging.md`](docs/packaging.md) | source units, runtime packages and their dependencies |
| `docs/formats/` - [`json`](docs/formats/json.md), [`xml`](docs/formats/xml.md), [`bson`](docs/formats/bson.md), [`protobuf`](docs/formats/protobuf.md), [`cbor`](docs/formats/cbor.md), [`messagepack`](docs/formats/messagepack.md), [`yaml`](docs/formats/yaml.md), [`csv`](docs/formats/csv.md), [`avro`](docs/formats/avro.md), [`asn1`](docs/formats/asn1.md) | one authoritative document per format |
| [`docs/agent-guide.md`](docs/agent-guide.md) | for maintainers and AI agents: where to start, what to run |
| [`docs/customization.md`](docs/customization.md) | every extension point, easiest first |
| [`docs/dynamic.md`](docs/dynamic.md) | documents without a Delphi type: building, reading, merging, every format, DataSets |
| [`docs/attributes.md`](docs/attributes.md) | the general attributes, and how format-specific configuration beats them |
| [`docs/deserialization-ownership.md`](docs/deserialization-ownership.md) | who owns what, and what happens on failure |
| [`docs/conversion.md`](docs/conversion.md) | contract-aware and structural conversion, the three profiles |
| [`docs/unicode-and-utf8.md`](docs/unicode-and-utf8.md) | text is not bytes |
| [`docs/datetime-policies.md`](docs/datetime-policies.md) | how each format writes dates, and how to change it |
| [`docs/nullable-families.md`](docs/nullable-families.md) | teaching the library someone else's nullable |
| [`docs/dataset-projection.md`](docs/dataset-projection.md) | the three ways to reach a DataSet, and schema inference |
| [`docs/dataset-formats.md`](docs/dataset-formats.md) | a DataSet as a document: snapshot, delta, schema |
| [`docs/format-program.md`](docs/format-program.md) | what "this format is finished" means |
| [`docs/serializer-behavior.md`](docs/serializer-behavior.md) | JSON's contract, member by member |
| [`docs/xml-behavior.md`](docs/xml-behavior.md), [`docs/xml-compatibility.md`](docs/xml-compatibility.md) | XML: the contract, and the standard proved against an independent processor |
| [`docs/bson-behavior.md`](docs/bson-behavior.md), [`docs/bson-compatibility.md`](docs/bson-compatibility.md) | BSON: native types, and every element type against the specification's vectors |
| [`docs/protobuf-behavior.md`](docs/protobuf-behavior.md), [`docs/protobuf-compatibility.md`](docs/protobuf-compatibility.md), [`docs/protobuf-descriptors.md`](docs/protobuf-descriptors.md) | Protobuf: field numbers and presence, the encoding against protoc, descriptor sets |
| [`docs/cbor-behavior.md`](docs/cbor-behavior.md) | CBOR: all eight major types, tags, deterministic encoding |
| [`docs/messagepack-behavior.md`](docs/messagepack-behavior.md) | MessagePack: the format table, str vs bin, timestamps |
| [`docs/yaml-behavior.md`](docs/yaml-behavior.md) | YAML: the 1.2 core schema, block scalars, anchors |
| [`docs/csv-behavior.md`](docs/csv-behavior.md) | CSV: dialects, and a tree that is not a table |
| [`docs/avro-behavior.md`](docs/avro-behavior.md) | Avro: why the schema is mandatory, resolution, logical types |
| [`docs/asn1-behavior.md`](docs/asn1-behavior.md) | ASN.1: BER, DER and CER, and the X.680 module |
| [`AGENTS.md`](AGENTS.md) | orientation for AI coding agents |

## License

PascalForge.Serialization is released under the **MIT License** - see
[`LICENSE`](LICENSE). Copyright (c) 2026 PascalForge.

- Commercial and private use are allowed.
- You may use, copy, modify, merge, publish, distribute, sublicense and sell
  copies, under the MIT terms.
- Copies and substantial portions must retain the copyright notice and the
  permission notice.
- The software is provided "as is"; the warranty and liability disclaimer is
  in [`LICENSE`](LICENSE).

Every source file carries `SPDX-License-Identifier: MIT`.
