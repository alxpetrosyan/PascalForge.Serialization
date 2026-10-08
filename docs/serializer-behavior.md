# JSON behaviour

How the JSON engine maps Delphi values to and from JSON. This document covers
**JSON only** — XML and BSON have their own rules and their own attributes; see
[`xml-behavior.md`](xml-behavior.md) and [`bson-behavior.md`](bson-behavior.md).

Ownership is defined once, for every format, in
[`deserialization-ownership.md`](deserialization-ownership.md). What appears
here is JSON's view of it, not a second definition.

## Member naming

- Default: the Delphi name with a lower-cased first character —
  `ReferenceId` → `referenceId`, `Ccy` → `ccy`.
- An escaped identifier loses its ampersand in RTTI, so `&Type` maps to
  `type` and `&To` to `to`. Nothing has to handle `&` explicitly.
- `[JsonName('result')]` overrides the derived name.
- `[JsonIgnore]` removes the member from both directions.

Naming can also be set per unit or per class with `RegisterUnitNaming` and
`RegisterClassNaming`, including `TJsonNaming.SnakeCase`.

## Presence and omission

- Non-nullable scalars, enumerations and sets are **always** emitted.
- A nullable with no value is **omitted** — never written as `"f": null`.
- An object, list or dictionary member that is `nil` is **omitted**.
- On read, an absent member leaves the target as constructed; a nullable stays
  empty.
- Unknown JSON members are ignored, so a document from a newer producer still
  deserializes.

## Scalars

| Delphi | JSON |
| --- | --- |
| `Boolean`, `ByteBool`, `WordBool`, `LongBool` | `true` / `false` |
| every integer width, `Int64` | number |
| `Single`, `Double`, `Extended` | number |
| `Currency` | number |
| `string` | string |

## Text, escaping and bytes

A Delphi `string` is Unicode text. JSON requires exactly three things to be
escaped — the quote, the backslash and characters below `U+0020` — and this
library escapes exactly those, so a Georgian, Cyrillic or CJK value stays
legible in the output instead of becoming a row of `\uXXXX` groups.

```json
{"Name": "დიდი ტელევიზორი"}
```

For a consumer that genuinely needs 7-bit output, set
`TJsonSerializationOptions.UnicodeEscape` to `EscapeNonAscii`. Both spellings
are valid JSON and carry the same values.

`Serialize<T>` returns text and has no byte encoding at all.
`SerializeUtf8<T>` returns `TBytes`: UTF-8, no BOM.
`DeserializeUtf8<T>` reads them back and accepts a leading BOM. Nothing here
goes through `AnsiString`, a code page or a locale — see
[`unicode-and-utf8.md`](unicode-and-utf8.md).

The library renders its own JSON text rather than using the RTL's, because
`ToJSON` escapes all non-ASCII and `ToString` emits raw control characters,
which is not valid JSON.

## Date, time and GUID

The defaults below are what you get with no configuration, and they have not
changed:

| Delphi | Wire |
| --- | --- |
| `TDate` | `YYYY-MM-DD` |
| `TTime` | `HH:MM:SS` |
| `TDateTime` | ISO 8601 |
| `TGUID` | lower-case canonical, no braces |

Date and time representation is configurable — per field, per type, or
globally — and JSON's settings are independent of XML's and BSON's. See
[`datetime-policies.md`](datetime-policies.md). Configuring nothing leaves the
wire output exactly as above.

`TDateTime` carries no time zone. The library does not invent one: an ISO 8601
value is written without an offset. Text without an offset is read as
written; text with one is read as the instant it states, normalised to UTC.

## Enumerations

- Default: the RTTI name — `TContractType.Priority` → `"Priority"`.
- `RegisterEnumMapping<T>(['a', 'b', ...])` maps ordinal *N* to
  `Mapping[N]` in both directions, for APIs whose codes are not the Delphi
  names. An ordinal or wire value outside the mapping raises a clear
  `EJsonError`.
- `Boolean` is a JSON boolean, not an enumeration name.

## Sets

- Comma-separated names: `[Retail, Government]` → `"Retail,Government"`.
- The empty set → `""`.
- If the element enumeration has a registered mapping, it applies per element.
- Nullable sets are supported.

## Nullable values

`PascalForge.Nullable.TNullable<T>` is recognised automatically. A foreign
nullable family is recognised once it is registered with
`TSerialization.RegisterNullableFamily<T>` — see
[`nullable-families.md`](nullable-families.md). Recognition is shared: JSON,
XML, BSON and the DataSet projection all consume the same metadata.

Supported inner types: `string`, every integer width, `Int64`, `Currency`,
`TDate`, `TTime`, `TDateTime`, `TGUID`, enumerations, sets, and anything
reachable through a registered custom serializer.

## Objects and inheritance

- Nested object members are populated recursively; `nil` is omitted.
- Inherited members appear exactly once, even when a descendant republishes a
  property.
- Instances are created through the class's parameterless constructor, a
  discovered zero-argument constructor, or a registered
  `RegisterClassFactory<T>`.

On read, an existing member instance is **reused, not replaced**:

| existing member | payload | result |
| --- | --- | --- |
| compatible instance | an object | populated in place; same instance |
| compatible instance | absent | left alone |
| compatible instance | `null` | detached, **not** freed |
| `nil` | an object | constructed |

The serializer never destroys an instance it cannot prove it owns. Anything it
built itself and then failed to hand over, it frees.

## Collections

Recognition is by **class ancestry**, not by name:

- lists: `TList<T>` and every descendant, so `TObjectList<T>` and an
  application's `TOrders = class(TObjectList<TOrder>)` both work with no
  registration;
- dictionaries: `TDictionary<K,V>` and every descendant, including
  `TObjectDictionary<K,V>`, written as a JSON object.

Dictionary keys convert by the same primitive rules — string, enumeration name,
integer. Element and value types are read from the container's `Add` method.

A container that already exists is **reused**: cleared, then refilled.
Disposal is the container's own business — `Clear` on an owning container
disposes of its elements, and on a non-owning one does not. The serializer
never frees elements on a guess.

## Custom serializers

Resolution order, most specific first:

1. `[JsonSerializer(TSomething)]` on the member
2. a field override (`TJsonFieldOverride.SerializeWith`), resolved across its
   own scopes: exact field, exact class, class and descendants, unit name,
   unit pattern - the latest registration wins within one scope
3. an owner-unit registration (`RegisterUnitClassTypeSerializer`)
4. a serializer registered for the exact type (`RegisterTypeSerializer`)
5. a generic-family registration (`RegisterGenericTypeSerializer`)
6. a class-hierarchy registration (`RegisterClassTypeSerializer`)

The authoritative statement is the comment above `RegisterTypeSerializer` in
`PascalForge.Json.pas`.

`TCustomJsonValueSerializer<T>` is the normal base — it names the Delphi type,
so implementations need no `TValue`. The untyped
`TCustomJsonValueSerializer` remains for genuinely dynamic cases. A custom
serializer on a nullable member applies to the **inner** value and keeps
omission semantics.

JSON custom serializers are JSON's. They do not become XML or BSON
serializers; those formats have their own contracts.

## Errors

`EJsonError` and its descendants name the class, the member, the JSON name and
the expected type wherever practical — an invalid enumeration value, an
ordinal outside a mapping, an array where an object was expected.
`EJsonInputError` marks failures caused by the document,
`EJsonInternalError` failures caused by the model or configuration. That
split is what `TryDeserialize` uses to decide what it may absorb.
