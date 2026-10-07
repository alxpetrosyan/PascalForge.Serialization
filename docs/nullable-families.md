# Nullable families

A nullable is a record that holds a value and a flag saying whether the value
is there. The library ships one — `PascalForge.Nullable.TNullable<T>` — and
recognises any other library's nullable once you register it.

Recognition is shared. JSON, XML, BSON and the DataSet projection all consult
the same table in `PascalForge.Serialization.Core`, so a type cannot be a
nullable in one format and an opaque record in another.

## Registering someone else's nullable

```pascal
uses
  PascalForge.Serialization.Core, Other.Maybe;

TSerializationTypes.RegisterNullableFamily<TMaybe<Integer>>;
```

That registers the **family**, not the specialization. `TMaybe<string>`,
`TMaybe<TDateTime>`, `TMaybe<TMyEnum>` and every specialization written later
are nullables from that point on. The `Integer` specialization is a sample: it
contributes the base name, the arity and proof that the named fields exist.

Nothing about its offsets is kept, because offsets are not a property of a
family. On Win32:

| type | value at | flag at |
| --- | --- | --- |
| `TMaybe<Byte>` | 0 | 1 |
| `TMaybe<Currency>` | 0 | 8 |
| `TMaybe<TGUID>` | 0 | 16 |

Each specialization resolves its own inner type and its own two offsets the
first time it is seen — while its serialization plan is being built — and the
result is cached both in the plan and in the shared table. On the
serialize/deserialize path a nullable costs pointer arithmetic and nothing
else: no interface, no virtual call, no lookup.

### Different field names

```pascal
TSerializationTypes.RegisterNullableFamily<TOptional<Integer>>(
  TNullableLayout.Fields('FPayload', 'FPresent'));
```

The default layout is `FValue` / `FHasValue`. The value field may be of any
type. The flag field must be a one-byte `Boolean` or `ByteBool`: it is read
through a `PBoolean`, and anything wider would read past it.

### When to register

Before anything of that type is serialized. A type's plan is built and cached
the first time it is used, and a registration made after that is a silent
no-op — the same rule as every other registration in the library. Startup,
next to your other configuration, is the right place.

## What identifies a family

Base name, arity, the registered field names — and the declaring unit on the
rare occasions RTTI carries one.

Delphi emits no declaring unit for a closed generic **record**.
`TRttiType.QualifiedName` raises `ENonPublicType` for
`TNullable<System.Integer>` even though `TNullable<T>` is declared in a unit's
interface section. (Non-generic records are fine: `TGUID` reports
`System.TGUID`.) There is no other route to the unit — no back-pointer from a
specialization to its generic definition, and the type arguments say nothing
about where the container was declared.

So a generic record family is identified by everything else, and the
consequence is stated rather than hidden: **two nullable families that share a
base name and an arity cannot be told apart.** Registering the second one
raises `ENullableFamilyError`, naming both, instead of guessing:

```
RegisterNullableFamily: TMaybe<System.Integer> cannot be registered with the
layout FItem/FLoaded because the family TMaybe<1> [FValue/FHasValue] is
already registered. ...
```

If both libraries happen to use the same field names, the registration is a
no-op and both work — they are operationally the same family. It is only a
disagreement about layout that has no safe answer.

Belonging to a family is necessary but not sufficient: the record must also
carry the fields the family was registered with, checked per specialization.

## What is refused

`RegisterNullableFamily` raises `ENullableFamilyError`, at registration time
and with the reason, for:

| registration | why |
| --- | --- |
| a non-record (`Integer`, `TObject`) | a nullable family is a record |
| a record that is not generic | there is no family to register |
| no value field of the named name | nothing to read |
| no flag field of the named name | no way to express "empty" |
| a flag that is not a one-byte Boolean | the flag is read as one byte |
| an incomplete layout | both names are required |
| a family already registered with a different layout | see above |

A refused registration changes nothing: the type is still not a nullable
afterwards.

## Behaviour

Once registered, a foreign nullable behaves exactly like the library's own.

- **JSON** — a present value is written as its inner type; an empty one is
  **omitted**, never `"field": null`. On read, an absent member leaves the
  nullable empty. See [`serializer-behavior.md`](serializer-behavior.md).
- **DataSet** — a nullable projects as a column of its **inner** type, and an
  empty one as `NULL`. See [`dataset-projection.md`](dataset-projection.md).
- A custom serializer on a nullable member applies to the **inner** value and
  keeps the omission semantics.

Supported inner types are the same as for `TNullable<T>`: `string`, every
integer width, `Int64`, `Currency`, `TDate`, `TTime`, `TDateTime`, `TGUID`,
enumerations, sets, and anything reachable through a registered custom
serializer.

## Inspecting the table

```pascal
for var S in TSerializationTypes.RegisteredNullableFamilies do
  Writeln(S);        //  TNullable<1> [FValue/FHasValue]
                     //  TMaybe<1> [FValue/FHasValue]
                     //  TOptional<1> [FPayload/FPresent]
```

`TSerializationTypes.IsNullableType(TypeInfo(TMaybe<string>))` answers the
question directly, and `TryGetNullableAccess` returns the resolved inner type
and offsets if you need them.

The library's own `TNullable<T>` is the first row of that table and nothing
more: it is registered from `PascalForge.Serialization.Core`'s initialization,
through the same public call, and no engine has a special case for it.
