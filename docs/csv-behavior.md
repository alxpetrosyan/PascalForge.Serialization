# CSV behaviour

How the CSV engine maps Delphi values to and from comma-separated values, as
defined by [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180) and by the
dialects real files are written in. This document covers **CSV only**; see
[`serializer-behavior.md`](serializer-behavior.md),
[`xml-behavior.md`](xml-behavior.md) and the other behaviour documents for the
rest.

Ownership is defined once, for every format, in
[`deserialization-ownership.md`](deserialization-ownership.md).

CSV is the odd one out and this document is mostly about why.

**A CSV file is a table.** Every other format here carries a tree, and a
table is not a tree. So the interesting questions are not about quoting — they
are about what happens to a nested object, to a collection, and to a null,
none of which a table has a place for. This engine answers every one of them
with an explicit option, and the **default for the hard ones is to refuse**,
because a silent guess about the shape of somebody's data is worse than an
error message.

## The text

```pascal
Text    := TCsvSerializer.Serialize<TArray<TCustomer>>(Customers);
Customers := TCsvSerializer.Deserialize<TArray<TCustomer>>(Text);

Data    := TCsvSerializer.SerializeToBytes<TArray<TCustomer>>(Customers);
Customers := TCsvSerializer.DeserializeBytes<TArray<TCustomer>>(Data);
```

The byte forms exist because a byte-order mark is a property of the file, not
of the string.

## The lexer is a real parser

Not `Split(',')`. RFC 4180 in full, and the things RFC 4180 does not mention
but every file contains:

| Case | Behaviour |
| --- | --- |
| `a,"b,c",d` | an embedded delimiter inside quotes is data |
| `"He said ""hi"""` | a doubled quote is one quote |
| `"line one\nline two"` | an embedded line break inside quotes is data |
| CRLF or LF line endings | both accepted; `TCsvNewLine` chooses on write |
| no final line break | accepted |
| a UTF-8 byte-order mark | skipped on read; `WriteBom` chooses on write |
| a ragged row | `TCsvRaggedRowPolicy`: `Error`, `PadWithEmpty`, `Truncate` |
| a duplicate header | `TCsvDuplicateHeaderPolicy`: `Error`, `Rename`, `UseFirst`, `UseLast` |
| no header at all | `HasHeader := False` |

## Dialects

```pascal
Options := TCsvOptions.ForDialect(TCsvDialect.Excel);
Options := TCsvOptions.ForDialect(TCsvDialect.TabSeparated);

Options := TCsvOptions.Default;
Options.Delimiter := ';';
Options.QuoteChar := '''';
Options.NewLine := TCsvNewLine.Lf;
Options.AlwaysQuote := True;
Options.TrimUnquotedValues := True;
```

`Standard` is RFC 4180. `Excel` is what Excel writes and reads. `TabSeparated`
is TSV. `Custom` is whatever the record says.

## Nested objects

A `TCustomer` with an `Address` member has to become columns somehow.
`TCsvNestedObjectMode` says how:

| Mode | Result |
| --- | --- |
| `Flatten` | `Shipper.Street`, `Shipper.City`, `Shipper.Postcode` — the path, joined by `PathSeparator` |
| `JsonCell` | one column holding the object as JSON text |
| `SeparateTable` | a second table, linked by a key column |
| `Error` | refuse, naming the member path |

```
Number,Total,Shipper.Street,Shipper.City,Shipper.Postcode
INV-1,99.95,Example Avenue 7,Midtown,12345
```

versus `JsonCell`:

```
Number,Total,Shipper
INV-1,99.95,"{""street"":""Example Avenue 7"",""city"":""Midtown"",""postcode"":""12345""}"
```

### An object with no columns is refused

`Flatten` writes a nested object as `Prefix.Member` columns, and a class
with no serializable members contributes none. The row is then identical to
the row for a member that was `nil`, and reading it back produces `nil` —
which is a different document, and nothing would have said so.

```text
$.ManualCamt053 is present and has no members, so flattening it writes no
columns and reading the row back would find nothing there. A table cannot
say "an empty object was here". NestedObjectMode.JsonCell writes it as one
cell.
```

The reader deliberately will not invent an empty object from an all-absent
prefix, so the honest place to stop is at the writer. `JsonCell` carries it.

`JsonCell` reaches JSON **through the registry**, not by importing it. This
unit has no compile-time dependency on `PascalForge.Json`; the mode simply
fails, by name, in a build where JSON is not registered.

## Collections

A member that is a list is harder, because a table row has one value per
column. `TCsvCollectionMode`:

| Mode | Result |
| --- | --- |
| `Error` | refuse, naming the member — **the default** |
| `NumberedColumns` | `Tags_1`, `Tags_2`, `Tags_3` |
| `RepeatedRows` | one row per element, with the scalar columns repeated |
| `JsonCell` | one column holding the array as JSON text |
| `SeparateTable` | a child table, keyed back to the parent |

```
Id,Customer,Tags_1,Tags_2,Tags_3        NumberedColumns
1,Alice,urgent,reviewed,paid

Id,Customer,Tags                        RepeatedRows
1,Alice,urgent
1,Alice,reviewed
1,Alice,paid
```

An element the target container itself refuses - a sorted `TStringList` with
`dupError` - is an `ECsvInputError` naming the container class.

### The Cartesian-product guard

Two collections under `RepeatedRows` produce every pairing of the two — three
tags and four lines become twelve rows, and the twelve rows are not what the
data says. `TCsvMultipleCollections` decides:

* `Error` — **the default**: refuse, naming both members;
* `CartesianProduct` — do it, because the caller said so.

## Document sets

`SeparateTable` cannot return one string, so it returns a set:

```pascal
Tables := TCsvSerializer.SerializeTables<TBasket>(Basket);
try
  for I := 0 to Tables.Count - 1 do
    WriteFile(Tables[I].Name, Tables[I].Content);
  // Tables.Relationships[] says which column links which pair
finally
  Tables.Free;
end;
```

`TCsvTableRelationship` records the parent table, the child table, the member
path, the key column on each side, and whether the key was **generated** —
because a parent with no natural key needs one invented, and a reader has to
know that the column is not part of the data.

The relationships travel **out of band**, in the document set, and never as an
extra column with a special name. A CSV file produced here is an ordinary CSV
file.

## Nulls

CSV has no null. `TCsvNullPolicy`:

| Policy | Result |
| --- | --- |
| `EmptyField` | an empty field — the default, and ambiguous with an empty string |
| `Literal` | the text in `NullLiteral`, conventionally `\N` |
| `Error` | refuse, naming the member |

## Reading a file with no contract

`InferSchema` looks at the header and the rows and produces a `TCsvSchema` —
which is a `TSerializationSchema`, so it can travel in conversion options.

`TCsvSchemaInferencePolicy` decides how far it is willing to go:

| Policy | Infers |
| --- | --- |
| `StringsOnly` | every column is text |
| `Conservative` | integers, floats and booleans that are unambiguous — **the default** |
| `Numeric` | the above, plus wider numeric recognition |
| `Extended` | the above, plus dates and GUIDs |

The default stops short of dates on purpose. `01/02/2024` is a date in two
countries and two different dates, and `1-800-FLOWERS` is not a number. A
string stays a string unless the caller asked for more.

`SchemaOf<T>` produces the same thing from a Delphi type, with no guessing at
all.

## Writing: one machine, one file

Every number and every date written here uses invariant formatting. A
`Double` is `0.0725` on a machine whose locale says `0,0725`, because a file
written on one machine is read on another.

Column types (`TCsvColumnType`): `Str`, `Boolean`, `Int32`, `Int64`, `Float`,
`DateTime`, `Guid`, `Binary`.

## The Delphi contract

The root of a CSV document is a **table**, so it is a collection of rows: an
array, a list, or a single record which becomes one row.

| Delphi | CSV |
| --- | --- |
| `Boolean` | `true` / `false` |
| every integer width | digits |
| `Single`, `Double`, `Extended`, `Currency` | invariant decimal |
| `string` | the text, quoted only when it has to be |
| `TBytes` | base64 |
| `TDateTime`, `TDate`, `TTime` | ISO 8601, or `CsvDateTimeFormat` |
| `TGUID` | the canonical 36 characters |
| an enumeration | its member name |
| a nested class or record | `TCsvNestedObjectMode` |
| a dictionary | `JsonCell` writes it in one cell; every other mode refuses |
| a list or dynamic array | `TCsvCollectionMode` |
| `TNullable<T>` with no value | `TCsvNullPolicy` |
| `TNullable<T>` of a record, class or collection, with a value | its value's own cells - `Flatten`, or the collection mode - read back present when one of them says something; a present value whose cells would all be empty, or a present nil object, is refused on write with `ECsvProjectionError`. `JsonCell` keeps the difference |

A header whose columns nest objects deeper than 256 levels
(`Next.Next.….Id`) is refused with `ECsvInputError`; the writer never nests
past 64.

### Attributes

```pascal
type
  [CsvTable('invoices')]
  TInvoice = class
  public
    [CsvKey] [CsvName('id')] Number: string;
    [CsvIgnore] Scratch: string;
    [CsvDateTimeFormat('yyyy-mm-dd')] Issued: TDateTime;
  end;
```

| Attribute | Meaning |
| --- | --- |
| `CsvName` | the column header to use |
| `CsvIgnore` | never written, never read |
| `CsvKey` | this member is the row's identity, and is the key `SeparateTable` links on — declaring one stops a key being generated |
| `CsvTable` | the table's name in a document set |
| `CsvDateTimeFormat` | a `FormatDateTime` pattern for this member |

## Structural conversion

CSV declares all four capabilities with nothing supplied.

```pascal
Payload := TSerialization.Convert(Source, TSerializationFormat.Json,
             TSerializationFormat.Csv);
```

The registry handler uses `TCsvOptions.Default`, which is deliberately the
configuration that **refuses rather than guesses**: a JSON document with a
nested object or an array member converts to CSV only when the caller passes
options saying what should happen to it.

One asymmetry is worth naming: a CSV document read structurally has an
**array** at its root, because a table is rows. A destination whose document
must be a map — BSON is the example — refuses such a tree, and says so.

## What is proven, and how

`tests/CsvNative` runs **160 checks**.

The ledger it prints covers RFC 4180 quoting and doubling, embedded
delimiters and line breaks, CRLF and LF and a missing final break, the
byte-order mark, the Excel/TSV/custom dialects, headerless files, ragged
rows, duplicate headers, all four nested-object modes, all five collection
modes, the Cartesian-product guard, document sets, out-of-band relationships,
all three null policies, all four inference policies, `SchemaOf<T>`, and
`JsonCell` reaching JSON through the registry.

## Not implemented, and why

* **A CSV payload holding several tables.** A table is a file. A document set
  is what `SerializeTables` returns; nothing here concatenates two CSVs or
  puts ZIP bytes inside a CSV payload.
* **Reading a child table back into its parent.** `SerializeTables` writes the
  keys that would make it possible and the relationships that describe it;
  `DeserializeTables` reads the **root** table and says so.
* **`RepeatedRows` for a collection nested below the top level.** The grouping
  signal is the repetition of the other columns, and at depth there is no
  longer one row per element to repeat.
