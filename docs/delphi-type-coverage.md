# Delphi type coverage

Which Delphi types every format carries, which it adapts, and which it
refuses - measured, not asserted. Every cell below is the outcome of a real
round trip through a real format, produced by `tests\TypeCoverage`, and
every refusal in it is one the harness was told to expect, with the reason.

```text
powershell -File scripts\run-type-coverage.ps1                 # Win32
powershell -File scripts\run-type-coverage.ps1 -Platform Win64
powershell -File scripts\run-type-coverage.ps1 -Only 'TBcd'   # one probe
```

## The result

```text
PROBES=62                  one type family each
CELLS=744                  62 probes x 12 formats
CELLS_OK=501               carried: written, read back, deep-equal
CELLS_REFUSED=243          refused deliberately, and allowed by the table
CELLS_RTL=0                a bare RTL exception reached the caller
CELLS_DIFF=0               read back, but not equal
CELLS_UNSAFE=0             the value was read or written through memory
CELLS_READBACK=0           the format's reader rejected its own writer
CELLS_UNEXPECTED=0         a refusal the table does not allow
PROCESSES_DIED=0           heap corruption, stack overflow, access violation

DELPHI_TYPE_COVERAGE: PASS         Win32 and Win64, cell for cell identical
```

## How a cell is decided

Each probe is a class holding one family of types, filled with values chosen
to break a careless implementation: integers at both ends of their range, a
subrange enumeration starting at 10, a set with members past bit 31, a
static array indexed from 5, text with an embedded `#0`. The harness writes
it with the format's own contract writer, reads it back with the same
format's reader, and compares every member deeply. It runs **one probe per
process**, so a type that corrupts the heap in one format cannot take the
rest of the run with it and be reported as something else.

The outcome is one of these, and only the first two are not defects:

| outcome | means |
| --- | --- |
| **ok** | written, read back, deep-equal - and for a typed binary format, written as the native wire type (an integer as an integer, not as text) |
| **refused** | the library's OWN exception, with a reason, AND the expectation table allows this format to refuse this probe |
| RTL | an `EConvertError`, `EInvalidCast`, `ERangeError` and so on reached the caller: the library did not decide, the RTL did |
| DIFF | the value came back different - a silent change |
| UNSAFE | a member was read or written as raw memory |
| READBACK | the format's reader refused what its own writer produced |
| UNEXPECTED | a refusal the table does not allow: a regression |

A refusal counts only when it is both deliberate and expected. Catching an
exception and calling it a refusal is exactly what the RTL outcome exists to
prevent, and a probe marked "must refuse" fails if a format ever accepts it.

## The matrix

`✓` carried, `R` refused deliberately. BER, DER and CER are the three ASN.1
encodings.

| family | probe | JSON | XML | BSON | Proto | CBOR | MsgPack | YAML | CSV | Avro | BER | DER | CER |
| --- | --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| integers | integers at their minimum | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| integers | integers at their maximum | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| integers | integers at zero | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| integers | UInt64 above High(Int64) | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ |
| floats | Single Double Extended Currency Comp | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| floats | NaN and the infinities | R | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| floats | minus zero | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| text | Char WideChar and Unicode text | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| text | embedded #0 | ✓ | R | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| text | control characters | ✓ | R | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| text | AnsiString and AnsiChar | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| text | UTF8String | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| text | RawByteString | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| text | ShortString | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| enums | enums incl. a subrange with MinValue 10 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| sets | small, 40-member, offset, empty and full sets | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| sets | set of AnsiChar, of Byte, of 0..63 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| arrays | dynamic arrays | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |
| arrays | TBytes | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| arrays | static array [0..2] | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |
| arrays | static array [5..7] | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |
| arrays | two-dimensional static array | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |
| arrays | inline static array (no RTTI) | R | R | R | R | R | R | R | R | R | R | R | R |
| arrays | jagged TArray<TArray<Integer>> | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |
| arrays | TArray<TNullable<Integer>> | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |
| records | plain record and array of record | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |
| records | managed record | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| records | generic record | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| records | variant record | R | R | R | R | R | R | R | R | R | R | R | R |
| records | packed record | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| classes | three-level inheritance | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| classes | read-only, write-only and indexed properties | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| collections | TList and TObjectList | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |
| collections | TDictionary and TObjectDictionary | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |
| collections | TDictionary<Integer, string> | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |
| collections | containers inside containers | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |
| collections | TQueue<Integer> | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |
| collections | TStack<Integer> | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |
| collections | TNullable with and without a value | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| legacy | TStringList | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |
| legacy | legacy TList of pointers | R | R | R | R | R | R | R | R | R | R | R | R |
| legacy | TCollection | R | R | R | R | R | R | R | R | R | R | R | R |
| temporal | TDate TTime TDateTime | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| identifiers | TGUID | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| identifiers | TBcd | R | R | R | R | R | R | R | R | R | R | R | R |
| variants | Variant holding scalars | ✓ | R | ✓ | R | ✓ | ✓ | ✓ | R | R | R | R | R |
| variants | Variant Null and Empty | ✓ | R | ✓ | R | ✓ | ✓ | ✓ | R | R | R | R | R |
| variants | variant array | ✓ | R | ✓ | R | ✓ | ✓ | ✓ | R | R | R | R | R |
| variants | OleVariant | ✓ | R | ✓ | R | ✓ | ✓ | ✓ | R | R | R | R | R |
| unsafe | Pointer | R | R | R | R | R | R | R | R | R | R | R | R |
| unsafe | PChar | R | R | R | R | R | R | R | R | R | R | R | R |
| unsafe | procedural variable | R | R | R | R | R | R | R | R | R | R | R | R |
| unsafe | method pointer | R | R | R | R | R | R | R | R | R | R | R | R |
| unsafe | anonymous method | R | R | R | R | R | R | R | R | R | R | R | R |
| unsafe | class reference | R | R | R | R | R | R | R | R | R | R | R | R |
| unsafe | interface | R | R | R | R | R | R | R | R | R | R | R | R |
| framework | TMemoryStream | R | R | R | R | R | R | R | R | R | R | R | R |
| framework | Exception | R | R | R | R | R | R | R | R | R | R | R | R |
| framework | TComponent with an owned child | R | R | R | R | R | R | R | R | R | R | R | R |
| graphs | a cycle A -> B -> A | R | R | R | R | R | R | R | R | R | R | R | R |
| graphs | one child shared by two parents | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| empties | nil, empty, zero, false, default, no value | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | R | ✓ | ✓ | ✓ | ✓ |

## What each family means

The classification the release report uses - every family is exactly one of
these, per format:

| class | means | how to get more |
| --- | --- | --- |
| **Supported** | carried exactly, in the format's natural type | - |
| **Format-specific representation** | carried exactly, but in a shape the format chose because it has no direct counterpart | see the format's `*-behavior.md` |
| **Schema/context required** | the format can carry it when told how - an option, a mode or a schema | the named option |
| **Custom serializer required** | the value has no representation a serializer may infer | register a type serializer for the type, or one for the member |
| **Deliberately refused** | carrying it would be unsafe or would lie about the data | carry a different type |
| **RTTI cannot safely describe** | the compiler records nothing that says what the bytes mean | give it a declared type, or a custom serializer |

### Supported everywhere

Integers of every width at their minimum, maximum and zero; `Single`,
`Double`, `Extended`, `Currency` and `Comp`; minus zero; `Char`, `WideChar`
and Unicode text; `AnsiString`, `AnsiChar`, `UTF8String`, `RawByteString`
and `ShortString`; enumerations, including a subrange that starts at 10;
sets of every width up to 256 members, and sets of characters and of integer
subranges; `TBytes`; static arrays, including offset bounds; managed,
generic and packed records; three-level inheritance; read-only, write-only
and indexed properties; `TDate`, `TTime`, `TDateTime`; `TGUID`; a child
shared by two parents; nil, empty and default values of every kind.

Notes that hold across all formats:

- **Legacy text** is encoded into the member's declared code page and
  checked: a character the code page cannot hold is refused with the reason,
  never written as `?`. `RawByteString` declares no code page, so text read
  into one is held as UTF-8 and tagged so.
- **`Extended`** is carried at `Double` precision on Win32, where it has ten
  bytes: no format here has an 80-bit float, and the digits past the
  seventeenth are not stored.
- **`Comp`** is a 64-bit integer that RTTI files under floating point; it is
  written as an integer everywhere.
- **Sets of characters and of integer subranges** have no names; their
  members are written as their ordinals.
- **A two-dimensional static array** is carried flat, in the order Delphi
  stores it, because RTTI does not record the length of each dimension of an
  anonymous index type. Its type still says the shape, so it reads back
  exactly.
- **`TDateTime`** is written without a zone offset, because it carries none.
  Text with an offset is read as the instant it states, normalised to UTC, by
  JSON, YAML and CBOR; XML and the ISO text of BSON and MessagePack ignore
  the offset; CSV refuses it. An instant before 1899-12-30 with a time of day
  - a negative day and a positive time, as Delphi encodes it - is carried
  exactly by every epoch representation. See
  [`datetime-policies.md`](datetime-policies.md).
- **A deep value**: every writer refuses a value nested more than 64 levels
  deep - each object, record, array, list and dictionary counts one - with
  `ESerializationLimitExceeded`. See "Limits" below.

### Format-specific representation

| type | where | how |
| --- | --- | --- |
| sets | every format | the members' names (ordinals for characters and integers): JSON, BSON and CSV a comma-joined string, XML space-separated text, CBOR, MessagePack and YAML an array, Protobuf a packed repeated enum, Avro an array of enum symbols, ASN.1 `SET OF ENUMERATED` |
| `Currency` | per format | JSON, XML, YAML and CSV the exact decimal text of the value, with at most four fractional digits (`1.5`, `12.3456`); BSON and MessagePack the scaled `Int64` Delphi stores; CBOR a decimal fraction (tag 4); Protobuf `sint64` scaled by 10 000; Avro `decimal` with scale 4; ASN.1 the scaled `INTEGER` |
| NaN and infinities | XML, YAML, CSV | the format's own spelling (`NaN`, `INF`, `.nan`, `.inf`) |
| `TGUID` | per format | the canonical 36 characters, or sixteen bytes where the format has a native form: BSON binary subtype 4, CBOR tag 37, Protobuf `bytes`, ASN.1 `OCTET STRING` |
| `Variant` | JSON, BSON, CBOR, MessagePack, YAML | the value it holds, as that format's own type; see "Variants" |
| dictionaries with non-string keys | Avro | the key's text, because an Avro map key is a string |

### Schema/context required

| type | where | how |
| --- | --- | --- |
| collections and arrays | CSV | a cell holds one value, and the default `CollectionMode` is `Error`. `JsonCell`, `RepeatedRows`, `NumberedColumns` or `SeparateTable` carry them |
| dictionaries | CSV | a map's keys are data, not a fixed set of columns: `NestedObjectMode.JsonCell` carries one |
| structural conversion | Protobuf, Avro, ASN.1 | a descriptor, an Avro schema or an ASN.1 module in the conversion options. The contract path needs none: the Delphi type is the schema |

### Custom serializer required

| type | where | why |
| --- | --- | --- |
| `TBcd` | every format | `TBcd.Fraction` is an inline array with no RTTI, so the digits cannot be read safely. A type serializer carries it as the decimal text it is |
| `UInt64` above `High(Int64)` | BSON, Avro | neither has an unsigned 64-bit integer, and a signed one cannot hold it. A custom serializer can choose decimal128 or text |
| NaN and infinities | JSON | JSON has no NaN and no infinity. Structural conversion under `Lossless` uses MongoDB Extended JSON's `$numberDouble`; a contract member needs a custom serializer that chooses a spelling |
| `Variant` | XML, CSV | text has no type of its own, so a Variant read back could not know what it held |
| `Variant` | Protobuf, Avro, ASN.1 | a Variant has no fixed type, and a schema-driven format writes only what its schema declares |
| `Exception` | every format | its runtime members are a stack pointer and an inner exception, which are not data |
| `TComponent` | every format | its public surface is an owner, a COM object and component state, not a value; a DTO or a custom serializer carries what matters |

### Deliberately refused

| type | why | instead |
| --- | --- | --- |
| `Pointer`, `PChar`, any typed pointer | a memory address means nothing in another process or at another time | the value it points at |
| procedural variable | the address of code, not data | an enumeration naming the choice |
| method pointer (`TNotifyEvent` and friends) | the address of code and of an object | - |
| anonymous method | an interface to a closure the library cannot see | - |
| interface | a reference to an implementation the library cannot see | the object behind it, declared |
| class reference (`TClass`) | reading a class name back into a constructor would let a document instantiate arbitrary classes | an enumeration, or a custom serializer with an allow-list |
| legacy `TList` | a list of untyped pointers | `TList<T>` of the real type |
| `TCollection` | it makes its own items through its `ItemClass`, a choice a serializer must not make for it | `TObjectList<T>`, or a custom serializer |
| `TStream` and descendants | its value is bytes behind a position that nothing on its surface describes | a `TBytes` member |
| a cycle (`A -> B -> A`) | no format here has a back-reference; following it writes forever | break the cycle, or write a key; JSON can write the back-reference as null with `TJsonRecursiveReferencePolicy.WriteNull` |
| `TStrings` with objects attached | the objects would be dropped without a word | a list of records |
| a repeated field of repeated fields, a null element, a nil message element | Protobuf has no field of that shape | wrap the inner list or the optional value in a message |
| text with U+0000 or another C0 control | XML 1.0 cannot contain them, literally or escaped | base64 the value, or use another format |

### RTTI cannot safely describe

| type | why |
| --- | --- |
| an inline static array (`A: array[0..2] of Integer` declared in place) | the compiler emits no type information for it, so nothing says how many elements of what are there |
| a variant record (`case` part) | the alternatives share the same bytes and nothing records which one is meaningful |

The refusal happens while the type's plan is built, names the member, the
type and the reason, and says how to get past it: leave the member out with
the format's ignore attribute, or register a type serializer.

## Variants

A `Variant` is carried by the formats that have a dynamic value of their own
- JSON, BSON, CBOR, MessagePack and YAML. The contract is the VALUE and its
FAMILY, not the exact `VarType`:

| family | Delphi `VarType`s | read back as |
| --- | --- | --- |
| Empty | `varEmpty` | the member is omitted, and stays `Unassigned` |
| Null | `varNull` | `Null` |
| Boolean | `varBoolean` | `Boolean` |
| Integer | `varSmallint` ... `varUInt64` | the narrowest of `Integer`, `Int64`, `UInt64` that holds it |
| Real | `varSingle`, `varDouble`, `varCurrency` | `Double`; `Currency` when the format carried an exact decimal that fits one |
| Date | `varDate` | `TDateTime` |
| Text | `varOleStr`, `varString`, `varUString` | `string` |
| Array | a one-dimensional variant array | a variant array of the same length |

Refused, always, with the reason: `varDispatch` and `varUnknown` (interfaces),
`varByRef` (a reference), `varError`, `varRecord`, custom variant types, and
arrays of more than one dimension.

## Limits

These are not type families, but they decide what a type can be:

| limit | value | why |
| --- | --- | --- |
| value depth, on write | 64 levels: each object, record, static or dynamic array, list, dictionary and `Variant` array counts one, the root included | every writer recurses; a thousand-deep linked list or recursive record overflowed the stack, and far shallower values made documents deeper than the formats' own readers accept |
| document nesting, on read | JSON, BSON and MessagePack 512 levels; XML 513 elements, the root included; CBOR 256; ASN.1 255 constructed levels; YAML 200 (`TYamlLimits.MaxDepth`); Protobuf 101 messages, the root included; Avro 512 datum levels, where a union and the record inside it count one each | a small document nesting without bound is a denial-of-service payload |
| YAML alias expansion | `TYamlLimits.MaxExpandedNodes` | the billion-laughs document |
| XML entities | 8 MB of expansion per document, 32 levels of nesting | the same attack in XML |
| declared lengths | checked against the bytes that remain, before anything is allocated | a four-byte header claiming four gigabytes |

Every reader's limit is above what 64 writer levels produce, so whatever a
writer accepts reads back - `tests\Robustness` writes and reads a value at
the limit in every format. A tree whose nodes hold their children
in a `TObjectList` uses two levels per generation - the node and the list -
so it reaches 32 generations. Hold a long chain as a list.

## The expectation table

The table lives in `tests\TypeCoverage\TypeCoverage.dpr`, in
`RegisterProbes`. Each probe is added with its family and filler, and each
allowed refusal with the formats it applies to and the reason, in words -
so a new refusal cannot appear without somebody writing down why it is
right. A probe added with "must refuse" fails if any format ever accepts it:
a pointer that serialized would be a defect, not a feature.

The harness is permanent. It runs as part of `scripts\validate-release.ps1`
on both platforms, and a change to any engine that moves one cell shows up
as a named cell, not as a count.
