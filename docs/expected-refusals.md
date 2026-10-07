# Every expected refusal, reviewed

A refusal in this library is a decision, not a failure: the library's own
exception, raised before anything is written or while the plan for a type is
built, naming the type, the member, the reason and the way past it. This is
the complete list of the refusals it makes on purpose, and for each one the
five questions that decide whether it should exist at all.

- **Why** - what makes it impossible, or unsafe, to carry.
- **Custom** - can a custom serializer carry it? (Every format has a
  per-type and a per-member registration; see
  [`customization.md`](customization.md).)
- **Schema** - can an explicit schema or context carry it?
- **Option** - can another option of the same format carry it?
- **Default or absolute** - is the refusal only the default, or is it the
  only answer the library will give?

The counts of each in the type-coverage matrix are in
[`delphi-type-coverage.md`](delphi-type-coverage.md).

## Unsafe or non-semantic values

These are refused by every format, for the same reason in each: the value is
an address, a piece of code or a reference to something the library cannot
see. None of them is data.

| type | why | custom | schema | option | refusal is |
| --- | --- | --- | --- | --- | --- |
| `Pointer`, `PChar`, typed pointers | an address, meaningless in another process or at another time | yes - write what it points at | no | no | absolute |
| procedural variable | the address of code | yes - write a name for the choice | no | no | absolute |
| method pointer | the address of code and an object | yes | no | no | absolute |
| anonymous method | an interface to a closure | yes | no | no | absolute |
| interface | a reference to an implementation the library cannot see | yes - write the object behind it | no | no | absolute |
| class reference (`TClass`) | reading a class name back into a constructor would let a document choose what gets instantiated | yes - with an allow-list the serializer owns | no | no | absolute |
| legacy `TList` | a list of untyped pointers | yes | no | use `TList<T>` | absolute |
| `TStrings` with objects attached | the objects would be dropped without a word | yes | no | clear the objects, or use a list of records | absolute |

## Types RTTI cannot describe

| type | why | custom | schema | option | refusal is |
| --- | --- | --- | --- | --- | --- |
| inline static array (declared in place) | the compiler emits no type information for it | yes, for the containing type | no | declare a named array type, which is carried | absolute for the inline form |
| variant record | the alternatives share bytes and nothing says which is live | yes | no | no | absolute |
| `TBcd` | `TBcd.Fraction` is an inline array with no RTTI | yes - as its decimal text | no | no | default: a built-in `TBcd` converter could exist, and would be a new capability |

## Framework objects

| type | why | custom | schema | option | refusal is |
| --- | --- | --- | --- | --- | --- |
| `TStream` and descendants | its value is bytes behind a position that nothing public describes | yes | no | carry a `TBytes` member | absolute |
| `TCollection` | it builds its own items through its `ItemClass`, which a serializer must not choose | yes | no | `TObjectList<T>` | absolute |
| `Exception` | its members are runtime state - a stack pointer, an inner exception | yes | no | carry a DTO | absolute |
| `TComponent` | owner, COM object and component state, not a value | yes | no | carry a DTO | absolute; `TComponent` is deliberately not special-cased |

## Graphs

| case | why | custom | schema | option | refusal is |
| --- | --- | --- | --- | --- | --- |
| a cycle (`A -> B -> A`) | no format here has a back-reference; following it writes forever | yes - write a key | no | JSON: `TJsonRecursiveReferencePolicy.WriteNull` writes the back-reference as null | default in JSON, absolute elsewhere |
| a value nested more than 64 levels deep (each object, record, array, list and dictionary counts one) | every writer recurses: a deep chain or recursive record overflows the stack, and a document deeper than the readers accept would not read back | yes - a type serializer for the chain type can write it as a list | no | hold the chain in a list | absolute (`ESerializationLimitExceeded`) |

## A value the format has no place for

| case | format | why | custom | schema | option | refusal is |
| --- | --- | --- | --- | --- | --- | --- |
| `UInt64` above `High(Int64)` | BSON, Avro | no unsigned 64-bit integer, and a signed one cannot hold it | yes - decimal128, or text | no | no | absolute |
| NaN and infinities | JSON | JSON has no such numbers | yes | no | structural conversion under `Lossless` writes Extended JSON `$numberDouble` | default for the contract |
| U+0000, C0 controls and unpaired UTF-16 surrogates in text | XML | XML 1.0 cannot contain them, literally or escaped | yes - base64 the value | no | no | absolute |
| a `Variant` | XML, CSV | element or cell text has no type of its own | yes | no | no | absolute |
| a `Variant` | Protobuf, Avro, ASN.1 | the schema declares one type per field, and a Variant has none | yes | no | no | absolute |
| `varDispatch`, `varUnknown`, `varByRef`, `varError`, `varRecord`, custom variant types, arrays of more than one dimension | every format that carries Variants | not values: interfaces, references, or shapes the tree cannot hold | yes | no | no | absolute |
| a character the declared code page cannot hold | every format, into `AnsiString`, `AnsiChar`, `ShortString` | it would become `?` | no | no | declare the member `string` | absolute |
| an unpaired UTF-16 surrogate in a `string`, on write | every format but JSON, which writes a `\uXXXX` escape; CSV's text output keeps it and its UTF-8 output refuses it | it is not a character, so UTF-8 cannot encode it and it would become U+FFFD | yes - carry the code units as bytes | no | no | absolute |
| a `TDateTime` or `TDate` outside the years 1 to 9999, on write | every format and representation | no format's date spells it, and every reader would refuse what was written | yes | no | no | absolute |
| more than one character into a `Char` | every format | refused, never truncated | no | no | no | absolute |

## Protobuf's shapes

Protobuf has a field for a scalar, a message, a repeated scalar or message,
and a map. Anything else has no field.

| case | why | custom | schema | option | refusal is |
| --- | --- | --- | --- | --- | --- |
| a repeated field of repeated fields (`TArray<TArray<T>>`), a map whose value is a list | an element of a repeated field is a scalar or a message | yes | no | wrap the inner list in a message | absolute |
| a null element in a repeated field, a nil message element | a repeated field has no null element; writing nothing shifted every element after it | yes | no | make the element a message with an optional field | absolute |
| a repeated field or map in a `oneof` | a oneof holds singular fields only | no | no | take it out of the oneof | absolute |
| `TNullable<T>` of a list or map | a repeated field has no presence: absent and empty are the same bytes | no | no | declare the container itself | absolute |
| `[ProtoType]` of another family (an `Integer` as `string`) | the tag and the payload would disagree | no | no | choose a scalar of the member's family | absolute, at plan build |
| a value outside its declared scalar (5 000 000 000 as `int32`) | the field would carry a different number | no | no | declare a wider scalar | absolute, at write |
| a member with no `[ProtoField]` number | protobuf has no names on the wire | no | a descriptor gives numbers only to the root's scalars | number it | the member is simply not a field |

## Schema and context

| case | why | custom | schema | option | refusal is |
| --- | --- | --- | --- | --- | --- |
| structural conversion from or to Protobuf, Avro or ASN.1 with no schema | the bytes do not say what they are | no | **yes** - a descriptor, an Avro schema or an ASN.1 module in the options (`ESerializationSchemaRequired` names which) | no | default only |
| a collection, array or map in CSV | a cell holds one value, and the default `CollectionMode` is `Error` | yes | no | **yes** - `JsonCell`, `RepeatedRows`, `NumberedColumns`, `SeparateTable`; `NestedObjectMode.JsonCell` for a map | default only |
| an Avro datum read with another schema than it was written with | Avro bytes carry no types; a bare datum is refused when its bytes do not add up | no | **yes** - `DeserializeWith` and the writer's schema, or an object container file, which carries it | no | default only |
| a class Avro cannot construct (no parameterless constructor) | Avro writes only what it can read back | yes | no | no | absolute for the contract path |
| a class any reader cannot construct | nothing tells it how | JSON: `RegisterClassFactory` | no | `Populate` an instance you built | default only |

## Structural conversion

Structural conversion moves a document with no Delphi type in between, so a
member name the destination cannot spell, or a value kind it does not have,
is decided by the conversion profile. See [`conversion.md`](conversion.md).

| case | `Natural` | `Lossless` | `Strict` |
| --- | --- | --- | --- |
| a name the destination cannot spell (`$type` into XML) | encoded reversibly | encoded as the standard for the pair says | refused: `InvalidDestinationName` |
| a value kind the destination does not have | adapted to the destination's idiom | the published standard for the pair | refused: `UnsupportedValueKind` |

There is no `Skip` and no `Drop` at any setting: nothing is ever silently
lost.

## Input the reader refuses

These are not refusals of a TYPE but of a DOCUMENT, and they are listed
because each one used to be something worse:

| case | was | now |
| --- | --- | --- |
| a scalar where a list, map or object belongs | an empty list (and the caller's list erased) | the format's input error, before anything is cleared |
| a number past the member's range (300 into a `Byte`, 1e300 into a `Single` or `Currency`) | a wrapped or infinite value | the format's input error |
| an enumeration value the type does not declare | an ordinal the type does not have | the format's input error |
| a date past the years 1 to 9999 | an RTL overflow | the format's input error |
| a sequence or mapping where a scalar belongs (YAML) | an empty string, `#0`, or the default | the format's input error |
| an element the container itself refuses - a sorted `TStringList` with `dupError` | the RTL's `EStringListError` | the format's input error, naming the container class |
| a key a document repeats, into a dictionary | the value built for the first one leaked | the last one wins, as before, and the first is freed; JSON refuses a repeated key |
| an Avro `int` whose varint is past 32 bits | narrowed silently: 5 000 000 000 read as 705 032 704 | the format's input error |
| a CBOR tag 4 exponent outside ±6144 | a hang, or `EOutOfMemory` | the format's input error |
| a CSV header nesting deeper than 256 levels (`Next.Next.….Id`) | a stack overflow | the format's input error |
| a Protobuf field with the wrong wire type | garbage read as a length | the format's input error |
| nesting, declared lengths, entity and alias expansion past the limits | a stack overflow, an out-of-memory, a hang | the format's own limit error |

A reader that fails frees everything it built, and nothing it did not.
