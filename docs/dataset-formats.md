# A DataSet as a document

A `TDataSet` is not a value of `TSerializationFormat`. It is a live object
with a cursor, an edit state and a schema, and none of that fits in a
payload. But a DataSet's **contents** can be written into any format the
registry knows, and that is one operation with two independent arguments:

```pascal
Payload := TDataSetSerializer.Serialize(Customers,
             TSerializationFormat.Xml,
             TDataSetSerializationPolicy.StructureAndRows);
```

| axis | says | values |
| --- | --- | --- |
| `TDataSetSerializationPolicy` | **what** goes in the document | `RowsOnly`, `StructureAndRows`, `DeltaOnly`, `DeltaAndStructure` |
| `TSerializationFormat` | **how** it is spelled | `Json`, `Xml`, `Bson`, … |

They are orthogonal, and deliberately so. There is no JSON-shaped policy
type and no XML-shaped one; what goes into a document does not depend on how
the document is spelled. A format added to the registry later writes these
packets with no edit to the DataSet subsystem, and `tests\DataSetFormats`
proves it by asking the registry for the list and walking it.

## The packet

```text
snapshot with structure
  fields        a list of column definitions, each with a name, a type, a
                size, a required flag and, for a nested table, its children
  rows          a list of objects, one per row, keyed by column name
  dataSetName   optional

snapshot without structure
  the rows list alone

delta
  Fields        optional, as above
  Delta         a list of changes, each with a State of Inserted, Modified
                or Deleted, and an Original and/or Current object
```

`type` is the `TFieldType` ordinal. That is Delphi-specific and it is the
shape these documents have always had; changing it would break every stored
one.

This is the same packet in every format. As JSON it is an object with
`fields` and `rows`; as XML the same members as elements; as BSON the same
document. One writer, one reader.

## Reading: where the schema comes from

A document that arrives from outside either describes its own columns or does
not, and `TDataSetSourceMode` says what to do about it.

```pascal
Table := TDataSetSerializer.CreateFDMemTable(Source,
           TSerializationFormat.Json, TDataSetSourceMode.Auto);
```

| mode | behaviour |
| --- | --- |
| `Auto` *(default)* | look. A complete schema is used; a document that plainly has none is inferred |
| `InferStructure` | ignore any embedded schema and infer from the data, always |
| `EmbeddedStructure` | require the embedded schema; a document without a usable one is an error naming what was missing |

### Detection is by shape, with no signature

The question "does this document describe a table?" is answered on the
**dynamic structural tree**, after the source format has parsed itself and
before anything DataSet-specific happens. So there is one implementation of
the rule, and a packet written as XML is recognized by the same code that
recognizes one written as BSON.

It is answered by **shape alone**. There is no marker, no namespace, no
version member and no signature of this library's to match on. The
consequence is the point: a document produced by somebody else's tooling
that genuinely describes a table is read as one.

```pascal
Match := TDataSetSerializer.ClassifySource(Source, TSerializationFormat.Json);
Why   := TDataSetSerializer.ExplainSource(Source, TSerializationFormat.Json);
```

| `TDataSetMetadataMatch` | means |
| --- | --- |
| `ValidMetadata` | it matches completely and is used as it stands |
| `NotMetadata` | nothing in it claims to describe a table; `Auto` infers |
| `InvalidMetadata` | it **claims** to — the members are there, in the right shapes — but something inside does not check out |

`InvalidMetadata` is deliberately not folded into `NotMetadata`. Silently
treating a broken schema as ordinary data would build a two-column table
called `fields` and `rows`, which is nobody's intention, so `Auto` reports it
and names the problem. `InferStructure` is the documented way to say "no,
really, treat it as data".

A format with fewer types than JSON is accommodated rather than refused: a
packet that came back through XML has its field types as the string `"3"`
rather than the number `3`, and a list of one is a single element rather than
a list. Both are what XML *is*, so the reader accepts both spellings of the
same values.

### RowsOnly is ambiguous, and says so

A rows-only document **is** an ordinary array of objects. Nothing in it says
otherwise, so `Auto` infers its schema — which is the honest answer, and
which means a currency column comes back as a number.

Reading one with the schema the writer had needs the caller to say so:

```pascal
TDataSetSerializer.DeserializeAs(Source, TSerializationFormat.Json, Table,
  TDataSetSerializationPolicy.RowsOnly);
```

`DeserializeAs` is the "I know the shape" form. It is also how a change list
is replayed, with `DeltaOnly` or `DeltaAndStructure`.

## Inference, when it happens

Inference widens across **all** non-null values in a column, not just the
first:

```text
Integer + Largeint          -> Largeint
Integer/Largeint + Float    -> Float
Boolean + Boolean           -> Boolean
anything else mixed         -> WideString
```

A column with no non-null value in any row gets the documented `WideString`
fallback. Only what the source format **states** is used: a JSON string stays
`ftWideString` however much it looks like a date. See
[`dataset-projection.md`](dataset-projection.md).

## The schema, without building the table

```pascal
TDataSetSerializer.ReadFieldDefs(Source, TSerializationFormat.Bson,
  Target.FieldDefs);
```

For a user interface that wants to show what is in a document before
deciding what to do with it. `demo\Conversion\06-LiveFormatConverter` does
exactly that, beside a grid and the detector's verdict.

## A DataSet as a dynamic value

Everything above, with the encoded document left out:

```pascal
Value := TDataSetSerializer.ToDynamic(DataSet,
           TDataSetSerializationPolicy.StructureAndRows);
TDataSetSerializer.FromDynamic(Value, Target, TDataSetSourceMode.Auto);
TDataSetSerializer.FromDynamic(Value, Target,
  TDataSetSerializationPolicy.RowsOnly);
TDataSetSerializer.FromDynamic<TOrder>(Value, Target);
```

`ToDynamic` builds the same packet `Serialize` encodes, as a tree the caller
owns, under any policy. `FromDynamic` reads into an existing DataSet under
the same destination contract and pre-validation as `Deserialize`, and the
caller always says how the value is to be read - a source mode or a policy,
with no default - so a value is a DataSet packet only because the caller
said so. `FromDynamic<T>` is contract-aware: `T`'s members, with their
DataSet and general attributes, decide the columns, and an array becomes one
row per item. See [`dynamic.md`](dynamic.md).

## A DataSet inside a larger document

A Delphi type with a `TDataSet`-typed **member** is a different job, and it
is JSON's because it needs JSON's serializer registration and member
context:

```pascal
uses PascalForge.DataSet.Json;   // then, once at startup: TDataSetJsonIntegration.Register;

type
  TReport = class
    Title: string;
    Rows: TFDMemTable;    // becomes a packet, inline
  end;
```

`TDataSetJsonIntegration` is declared in `PascalForge.DataSet.Json` (package
`PascalForge.Serialization.DataSet`); there is no separate integration
unit. It owns the policy resolution for those members —
member policy, then type policy walking up the class hierarchy, then the
default — and the factory that constructs one during deserialization:

```pascal
TDataSetJsonIntegration.SetDefaultPolicy(
  TDataSetSerializationPolicy.StructureAndRows);
TDataSetJsonIntegration.RegisterTypePolicy<TFDMemTable>(
  TDataSetSerializationPolicy.RowsOnly);
TDataSetJsonIntegration.RegisterFieldPolicy<TReport>('Rows',
  TDataSetSerializationPolicy.DeltaOnly);
TDataSetJsonIntegration.DataSetFactory :=
  function(ADeclaredClass: TClass): TDataSet
  begin
    Result := TFDMemTable.Create(nil);
  end;
```

The packet it writes is built by the shared code above, so a nested table is
spelled exactly like a top-level one.

## Guarantees

```text
ROWS_ONLY_SERIALIZE: PASS
STRUCTURE_AND_ROWS_SERIALIZE: PASS
STRUCTURE_AND_ROWS_RECONSTRUCT: PASS
NESTED_DATASET: PASS
DATASET_RECURSION_GUARD: PASS — an active-DataSet identity chain writes null
                                 on a back-edge

DATASET_SERIALIZE_EVERY_FORMAT: PASS — every structural format in the registry
DATASET_POLICY_IS_FORMAT_NEUTRAL: PASS
DATASET_DETECTION_IS_FORMAT_DYNAMIC_XML: PASS
DATASET_DETECTION_IS_FORMAT_DYNAMIC_BSON: PASS
DATASET_FOREIGN_PACKET_IS_RECOGNIZED: PASS — no signature required
DATASET_ROWS_ONLY_IS_AMBIGUOUS: PASS
DATASET_AUTO_REFUSES_BROKEN_METADATA: PASS

GLOBAL_POLICY: PASS
TYPE_POLICY: PASS
FIELD_POLICY: PASS
POLICY_PRECEDENCE: PASS — owning member > exact/runtime type > base type > global

TDATASET_FACTORY: PASS — configurable hook; the default for an exact TDataSet
                          target is TFDMemTable
DATASET_HANDLER_PLAN_CACHED: YES
DATASET_CONTENT_CACHED: NO

PASCALFORGE_JSON_INTEGRATION: PASS — opt-in TDataSetJsonIntegration.Register
JSON_ONLY_LIB_DATASET_INDEPENDENT: PASS
```

`tests\DataSetFormats` and `tests\DataSetJson` hold these.

## Errors

A conversion failure inside a row names the field and the value:

```text
Cannot convert value "not-a-number" to field Id (ftInteger): …
```

A mode failure names what was missing:

```text
This document was read with EmbeddedStructure, which requires it to describe
its own columns, and the document has no fields and rows pair, so its schema
has to be inferred. Use Auto to infer the schema from the data instead.
```

**The destination contract.** Reading into an existing DataSet REBUILDS it:
the document owns the schema, so the DataSet - open or closed - is closed,
cleared and rebuilt. Both `Deserialize` overloads do this, the one that
takes a format context included.

**For `TFDMemTable` and `TClientDataSet`, PascalForge pre-validates the
complete projection on a temporary instance before rebuilding a populated
destination.** This prevents library-detectable schema, value and
projection failures - a value its column cannot hold, a change that refers
to a missing row - from destroying the existing DataSet. Application
callbacks (`BeforePost`, `OnNewRecord`, a field's `OnValidate`) or
destination-specific behaviour during the final application may still raise
after rebuilding has begun: the rehearsal runs on another instance, and it
is not a transaction.

Descendants of the two classes are pre-validated the same way. Any other
`TDataSet` - a live query result, which keeps the schema it was opened
with - is projected directly, as before. An empty, closed destination has
nothing to keep and is not pre-validated.

There is still no `Try` form: the guarantee depends on the destination's
class, and a Boolean result would promise it for every class. It stays
exception-based, as `TJsonSerializer.Populate` does.
