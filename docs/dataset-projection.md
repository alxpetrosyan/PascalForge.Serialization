# DataSet projection

Turning data into live rows, so a grid, a report or a `TDataSource` can
consume them.

```pascal
uses
  PascalForge.DataSet;
```

DataSet projection is a first-class PascalForge.Serialization subsystem and
`TDataSetSerializer` is a peer of `TJsonSerializer`, `TXmlSerializer` and
`TBsonSerializer`. It shares their whole type foundation - RTTI metadata,
type identity, nullable families, collection recognition, enum metadata,
construction metadata, cached plans.

What it does not share is the **result type**. JSON, XML and BSON produce an
encoded representation that a `TSerializationPayload` can carry as text or
bytes. A `TDataSet` is a live object: ownership, schema objects, fields,
rows, cursor position, editing state, a runtime implementation class. None
of that fits in a payload, which is the whole reason `DataSet` is not a
value of `TSerializationFormat` - a difference of type, not of purpose.

## Three ways to reach a DataSet

```text
A.  a Delphi value
        Shipment
          -> TDataSetSerializer.CreateFDMemTable<TShipment>
          -> TFDMemTable

B.  an encoded document, WITH the Delphi contract
        JSON / XML / BSON
          -> the source format's Deserialize<TShipment>
          -> the projection in A
          -> TFDMemTable

C.  an encoded document, with NO contract
        JSON / XML / BSON
          -> that format's structural parse
          -> the dynamic structural tree
          -> TDataSetSchemaInference
          -> TFDMemTable
```

All three are supported. B reuses A's projection exactly - there is no
second DTO-to-DataSet mapping anywhere in the library - and C never invents
a DTO. The generic overload never secretly infers, and the non-generic one
never secretly uses a contract.

```pascal
// A
DS := TDataSetSerializer.CreateFDMemTable<TShipment>(Shipment);

// B - the contract decides the schema
DS := TDataSetSerializer.CreateFDMemTable<TShipment>(Json,
  TSerializationFormat.Json);

// C - the document decides the schema
DS := TDataSetSerializer.CreateFDMemTable(Json, TSerializationFormat.Json);
DS := TDataSetSerializer.CreateFDMemTable(BsonBytes,
  TSerializationFormat.Bson);
CDS := TDataSetSerializer.CreateClientDataSet(Xml, TSerializationFormat.Xml);
```

`string`, `TBytes` and `TSerializationPayload` overloads exist for each, and
so does an `AOwner` parameter: `nil` means the caller owns the result, a
component means that component does, and if anything raises the half-built
DataSet is freed rather than returned.

**A and B are different from [`dataset-formats.md`](dataset-formats.md)**, which
represents a `TDataSet` *itself* as JSON - schema, rows, deltas. That is a
DataSet going out; this is data coming in.

### The DataSet subsystem names no format

`PascalForge.DataSet` has no reference to `PascalForge.Json`,
`PascalForge.Xml` or `PascalForge.Bson`. B and C reach the source through
the serialization-format registry, so the source's format has to be
registered - `T<Format>SerializationRegistration.RegisterFormat`, explicitly;
if it is not, `ESerializationFormatNotRegistered` says which call to make.
Path A involves no
encoded format and needs no registration at all.

No format's own DOM - `TJSONValue`, `TXmlElement`, `TBsonValue` - ever
reaches the DataSet subsystem. A format contributes by turning its bytes
into the dynamic tree, which is what its handler's `ToDynamic` already does.

### So path C works for any registered structural format

There is no overload per format and there never will be. The non-generic
entry points take a `TSerializationFormat` value, and a format pack added
later is covered the day the application registers it:

```pascal
DS := TDataSetSerializer.CreateFDMemTable(Source, TSerializationFormat.Cbor);
```

Ask before offering it, rather than catching an exception:

```pascal
for F in TSerialization.StructuralFormats do
  ...
```

Three failures, three different messages:

| | |
| --- | --- |
| nobody registered the format | `ESerializationFormatNotRegistered`, naming the unit |
| registered, but it has no structural parser | `ESerializationFormatCapability` |
| the source is the wrong shape for the format | the format's own error - BSON will not read text |

`tests\DataSetSources` runs the same projection over
`TSerialization.StructuralFormats` and names no format in the loop.

### DataSet naming is DataSet's, not XML's

A column name comes from the source member name unchanged. `$type` stays
`$type`, `first name` stays `first name` - a `TFieldDef` has no objection to
either, and the reversible XML name encoding is **not** applied here.

```text
JSON -> XML       XML's naming rules apply, so "$type" is encoded
JSON -> BSON      BSON can spell it, so "$type" is unchanged
JSON -> DataSet   DataSet's rules apply, so "$type" is unchanged
```

Name adaptation belongs to the destination that cannot take the name. The
dynamic tree is never mutated on the way, which is what keeps these three
independent.

## Schema inference, when there is no contract

`TDataSetSchemaInference` consumes the dynamic tree, so JSON, XML and BSON
all get the same widening, the same nesting and the same root-shape rules
from one implementation.

### Root shapes

| the document is | the DataSet is |
| --- | --- |
| an array of objects | one row per element, columns from every element |
| a single object | one row |
| an array of scalars | one column named `value`, one row per element |
| a scalar | one column named `value`, one row |
| an empty array | **no schema and no rows** - it comes back closed |
| null | no schema and no rows |
| a mixed array | objects contribute their columns; a scalar element goes to `value` |

An empty document yields no schema rather than an invented placeholder
column, and reporting that honestly is the point.

### Column types

A column is one type for the whole table, so every value in it widens
together:

```text
Integer + Largeint        -> Largeint
Integer/Largeint + Float  -> Float
Date + DateTime           -> DateTime
Time + DateTime           -> DateTime
Date + Time               -> WideString   (no common moment)
anything else mixed       -> WideString
```

and a structural kind becomes the strongest safe field type:

| dynamic | field |
| --- | --- |
| boolean | `ftBoolean` |
| integer within 32 bits | `ftInteger` |
| wider integer | `ftLargeint` |
| unsigned integer above `High(Int64)` | `ftWideString` (its exact digits; no integer field holds it) |
| float | `ftFloat` |
| decimal | `ftFloat` (the digits rounded once to the nearest double, as a text format's number is; one past the double range is refused) |
| date | `ftDate` |
| time | `ftTime` |
| datetime | `ftDateTime` |
| binary | `ftBlob` |
| string, and the all-null fallback | `ftWideString` |

### What is deliberately NOT inferred

**A string stays a string.** A JSON member spelled `"2026-09-14"` becomes
`ftWideString`, not `ftDate`. JSON never said it was a date, and guessing
from the spelling is how the same document becomes a timestamp in one system
and text in the next. The same goes for `"14:35:00"` and
`"2026-09-14T14:35:00"`, and for XML element text, which carries no type at
all. `tests\DataSetFormats` asserts it by name:
`DATASET_JSON_TEXT_DOES_NOT_BECOME_FTDATE`.

**A date becomes `ftDate` only when the source format has a date.** Avro's
`date` logical type, ASN.1's `DATE`, a `TDate` member on the
contract path — those say *a day* (CBOR's date tags 0 and 1 are instants,
and give `ftDateTime`), and the column is `ftDate` rather than a
`ftDateTime` at midnight. `ftTime` the same way. The distinction comes from
the source's own type system and from nowhere else.

**BSON is different, because BSON says so.** A native BSON datetime becomes
`ftDateTime`, an int64 stays `ftLargeint` rather than collapsing to a double,
and binary becomes `ftBlob`. Inference preserves what the source format
actually stated and invents nothing - which is why the asymmetry between
BSON and the text formats is deliberate rather than an oversight.

If you want Delphi semantics, supply the contract: that is what path B is
for, and `tests\DataSetSources` asserts the two produce visibly different
schemas from the same bytes.

### Nested shapes from a document

A member that is an object, or an array of objects, becomes an `ftDataSet`
column with its own `ChildDefs` - the same nested semantics the DTO
projection uses. An array of scalars becomes a nested table of one column
named `value`, so nothing is flattened away and nothing is invented. Nesting
is not collapsed merely because the data arrived as JSON.

A nested table whose rows share no member names gets no columns rather than
an invented one.

## Three operations, and why they stay distinct

```pascal
TDataSetSerializer.CreateStructure<T>(ADataSet);        // schema only
TDataSetSerializer.Fill<T>(AValue, ADataSet);           // rows into a schema
TDataSetSerializer.CreateAndFill<T>(AValue, ADataSet);  // both
```

`Fill<T>` never builds a schema. That is deliberate: appending to a dataset
whose columns you established yourself, once, and then filling it repeatedly is
the common case, and a `Fill` that silently recreated the schema would discard
the rows already in it.

`CreateAndFill<T>` **recreates** the schema, so anything the dataset held
before is gone. Both take a single value or an `array of T`.

## When you have no dataset yet

```pascal
FD  := TDataSetSerializer.CreateFDMemTable<TEntry>(Entry);
CDS := TDataSetSerializer.CreateClientDataSet<TEntry>(Entries);
```

These construct the concrete dataset, describe the schema, fill it and return
it open. They are `CreateAndFill<T>` with the construction in front — not a
second projection path.

Ownership follows `TComponent`: with `AOwner` nil the result is yours to free;
with an owner, freeing the owner is enough. If describing or filling raises,
the half-built dataset is freed here and the exception propagates, so a
partially initialised dataset is never returned.

## Both dataset implementations are first class

`TFDMemTable` and `TClientDataSet` are equally supported and produce the same
field names, the same field types and the same values from the same DTO. The
only implementation-specific step is activation — neither base class declares
it — and the library performs the right one for each.

A dataset of any other class is filled but not activated: it is yours, and it
may already be open or be opened some other way.

## Shaping the columns

```pascal
type
  TEntry = class
  public
    [DataSetName('REFERENCE')]      // column name
    Reference: string;

    [DataSetField(ftString, 34)]    // column type and size
    Sku: string;

    [DataSetHandler(TMoneyHandler)] // write this member yourself
    Amount: TMoney;

    [DataSetIgnore]                 // not a column at all
    InternalNote: string;
  end;
```

The same choices are available as registrations, for types you do not own:

```pascal
TDataSetSerializer.RegisterFieldOverride<TEntry>('Net',
  TDataSetFieldOverride.WriteWith<Currency, TCurrencyHandler>);

TDataSetSerializer.RegisterTypeHandler<TMoney>(ftCurrency,
  procedure(const AValue: TMoney; AField: TField)
  begin
    AField.AsCurrency := AValue.Amount;
  end);
```

## Writing a handler

Against the Delphi type, with no untyped plumbing:

```pascal
type
  TCurrencyHandler = class(TCustomDataSetFieldHandler<Currency>)
  public
    function FieldType: TFieldType; override;
    procedure WriteValue(const AValue: Currency; AField: TField); override;
  end;
```

Override `FieldSize` as well whenever `FieldType` needs one — `ftString`,
`ftWideString`, `ftBytes`. The base returns 0, which is a zero-length field.

When one member should become **several** columns, write a
`TCustomDataSetTypeSerializer<T>`: it declares the fields in `AddFields` and
writes them in `WriteValue`, both against `T`.

## Nested shapes

Nested objects become prefixed columns (`Validity.From`, `Validity.To`).
Nested lists and dictionaries become `ftDataSet` columns with their own child
definitions. A DTO with no projectable members is a documented no-op: the
dataset is left closed rather than given an artificial column.
