# Deserialization ownership contract

This is the definitive public contract for what `TJsonSerializer.Deserialize<T>`
and `TJsonSerializer.Populate` do to objects, containers and DataSets that
already exist in a target graph.

The tests that assert it are listed under "Contract tests" at the end. The
rules are written with JSON's examples; every format follows them.

---

## The rule, in one sentence

**Reuse a compatible existing instance; construct only when there is nothing to
reuse; and never destroy an object the serializer cannot prove it owns.**

That single rule applies identically to `Deserialize<T>` and `Populate`, to
fields and to properties.

---

## Why one rule and not two

`Deserialize<T>` and `Populate` are not separate engines:

```text
Deserialize<T>(json)  ->  construct root  ->  PopulateWithPlan(root, json)
Populate(obj, json)   ->                      PopulateWithPlan(obj,  json)
```

Every nested member takes the same path in both cases. The operations differ
only in the starting state of the **root**. For a freshly constructed root each
member is either `nil` — so "reuse" constructs — or an instance the constructor
deliberately created, which is precisely what should be reused.

This is not just simpler; it is more correct. A constructor that does
`Items := TObjectList<TItem>.Create(False)` is declaring a **borrowing** list.
Replacing it with `TObjectList<TItem>.Create` (whose parameterless constructor
sets `OwnsObjects := True`) silently converts it into an owning list that will
later destroy elements it never owned. Reuse preserves the configuration.

---

## Objects

`Compatible` means the member is non-nil and
`Existing.ClassType.InheritsFrom(DeclaredClass)`. A **descendant qualifies** —
that is what keeps polymorphism intact.

| Existing | JSON member | Behaviour |
| --- | --- | --- |
| nil | absent | nothing happens |
| nil | `null` | stays nil |
| nil | object | construct the declared class, populate it, then assign |
| compatible | absent | untouched, including all of its own members |
| compatible | object | **populated in place.** Identity preserved. Members absent from the JSON keep their values. |
| compatible | `null` | **detached**: the member becomes nil and the instance is **not** destroyed |
| incompatible | object | a new declared-class instance is constructed and assigned; the old one is not destroyed |
| any | wrong shape | `EJsonError` naming the member, its type, and the expected vs actual JSON shape. Nothing is mutated. |

```pascal
Order.Customer := TCustomer.Create;
Order.Customer.Name := 'Ann';
Order.Customer.City := 'Midtown';

TJsonSerializer.Populate(Order, '{"customer":{"name":"Bob"}}');
// Order.Customer is the SAME instance.
// Name = 'Bob', City is still 'Midtown'.
```

### Fields and properties behave the same

The one legitimate difference is that a **read-only** property cannot be
assigned, only reused:

- read-only + compatible existing → populated in place
- read-only + `nil` → skipped, because there is no way to deliver the value
  (XML still reads the member's element, so a malformed one raises, and frees
  what it built)

When an instance is reused, **the setter is not called** — nothing is being
assigned, so calling it would be a side effect the caller never requested. The
setter is used only when a new instance is constructed. The serializer never
writes a property's backing field through RTTI to bypass it.

---

## Records

| Existing | JSON member | Behaviour |
| --- | --- | --- |
| any | absent / `null` | untouched |
| any | object | **merged in place**; members absent from the JSON keep their values |
| any | wrong shape | `EJsonError` |

For a record **property** the getter's copy is merged and assigned back through
the setter, so property semantics are respected while still merging.

---

## Arrays

A static or dynamic array member is **replaced**, not refilled: the reader
builds a new array of new elements and assigns it. An array has no owner to
ask, so the objects the old array held are neither reused nor freed - the
class that put them there still owns them. Protobuf appends to a dynamic
array instead, which is the protobuf merge of a repeated field.

Hold owned children in a `TObjectList<T>`, which is refilled in place and
asked what it owns, or leave the array empty in the constructor.

---

## Containers

Lists, object lists and dictionaries — including ordinary descendants such as
`TOrders = class(TObjectList<TOrder>)`.

| Existing | JSON member | Behaviour |
| --- | --- | --- |
| nil | absent / `null` | stays nil |
| nil | array / object | construct, fill, assign |
| compatible | absent | untouched |
| compatible | array / object | **the container instance is reused**: `Clear`, then refill |
| compatible | `null` | detached; the container is not destroyed |
| any | wrong shape | `EJsonError`; the existing container is left **untouched and unclear**ed |

### Container instance vs container contents

These are separate ownership questions and the contract answers them
separately:

- the **instance** is never destroyed by the serializer
- the **contents** are replaced through the container's own `Clear`

`Clear` is deliberately the only disposal the serializer performs, because it
asks the container what it owns instead of the serializer guessing:

| Container | `Clear` | Old elements |
| --- | --- | --- |
| `TObjectList<T>.Create(True)` | destroys elements | destroyed — the list owned them |
| `TObjectList<T>.Create(False)` | detaches | survive — the list never owned them |
| `TList<TObject>` | detaches | survive — something else owns them |
| `TObjectDictionary<K,V>` with `doOwnsValues` | destroys values | destroyed |
| `TDictionary<K,V>` | detaches | survive |

```pascal
Basket.Lines := TObjectList<TLine>.Create(False);   // borrowing
Basket.Lines.Add(SharedLine);

TJsonSerializer.Populate(Basket, '{"lines":[{"sku":"A"}]}');
// Basket.Lines is the SAME list, still OwnsObjects = False.
// SharedLine is still alive - the list never owned it.
```

---

## JSON `null` never destroys

An explicit `null` **detaches**: the member becomes nil and whatever it pointed
at survives.

This is a deliberate choice. Nothing in Delphi RTTI distinguishes

```pascal
Child: TChild;   // owned by me
Child: TChild;   // borrowed from my caller
Child: TChild;   // shared with three other objects
```

so a serializer that frees on `null` destroys shared and borrowed references
with no way to detect it, and the damage is unrecoverable. Leaking is
recoverable; a dangling pointer is not.

> **Caller responsibility.** After a `null` detaches a member you own, dispose
> of the instance yourself, or capture it before the call:
>
> ```pascal
> Old := Order.Customer;
> TJsonSerializer.Populate(Order, '{"customer":null}');
> Old.Free;
> ```
>
> A member whose disposal must follow the JSON is a job for a custom
> serializer, which can encode the ownership the model knows and RTTI does not.

The same applies to a container `null`, and to the case where a custom
serializer returns a different instance than the one it was given.

---

## Nullable members

`TNullable<T>` is a value, not a reference, so ownership does not arise:

| Existing | JSON member | Behaviour |
| --- | --- | --- |
| has value | absent | unchanged |
| has value | `null` | cleared (`HasValue` becomes False) |
| any | value | replaced |

---

## Custom serializers

`TCustomJsonValueSerializer.DeserializeIntoContext` receives the existing
instance and may reuse it — that is how a serializer opts into in-place
population. `TCustomDataSetJsonSerializer` already does this.

The engine does **not** dispose of a previous instance when a serializer returns
a different one: a serializer that replaces an instance owns that decision.

What a serializer returns, the engine treats as built by this read. If the read
fails later, an object the serializer returned into a record, an array or a
container the read itself constructed is freed with them - and
`TSerialization.Convert` frees its intermediate value the same way. So a
serializer returns a new instance, or the existing one it was given; **never a
cached or shared instance**. A value that names one of a fixed set of shared
objects is carried as its key, and the model looks the object up.

---

## DataSets

A `TDataSet` member is an object with meaningful existing state — a schema, an
active cursor, rows — so reuse matters more here than anywhere else.

| Existing | Behaviour |
| --- | --- |
| a compatible `TDataSet` | **reused**: the JSON is loaded into it according to the resolved policy |
| nil | constructed via `TDataSetJsonIntegration.DataSetFactory`, else `TFDMemTable` for a member declared exactly `TDataSet`, else the declared concrete class |
| `null` in the JSON | detached, not destroyed |

This was already the DataSet layer's behaviour; the generic engine now matches
it instead of being more destructive.

Policies (`RowsOnly`, `StructureAndRows`, `DeltaOnly`, `DeltaAndStructure`) and
everything each format writes are unchanged. Note that `RowsOnly` carries no schema, so it
can only be loaded into a DataSet that already has one — which is another reason
reuse is the right default for DataSet members.

---

## Exception safety

The guarantee is:

> **No reference is destroyed or left dangling by a failed deserialization.**

| Path | Guarantee |
| --- | --- |
| construct-and-assign (object, container) | fully transactional — the member still holds its previous value if construction or population fails |
| reuse of an object | the reference always survives; the instance may be partially populated |
| reuse of a container | the reference always survives; contents may be partially replaced |
| record merge | the record may be partially populated; no reference is lost |
| wrong JSON shape | detected before anything is mutated, cleared or constructed |
| what the failed read built | freed: objects it constructed, including those inside records and arrays, and the elements of a list or dictionary it constructed unless that container owns them |

In-place merging cannot be atomic — replacing contents is by definition
destructive to the old contents. What the library guarantees is that you never
lose the *instance*.

```pascal
Kept := Order.Customer;
try
  TJsonSerializer.Populate(Order, '{"customer":{"age":"not-a-number"}}');
except
  // Order.Customer is still Kept, still alive.
  // Some of its members may already carry the new values.
end;
```

---

## What the library will not do

- It will not infer ownership from a member declaration. `Field: TObject` says
  nothing about who owns it.
- It will not free an object it did not create, except through a container's own
  `Clear`.
- It will not preserve object identity across a cyclic graph (there is no
  `$ref` support); a shared child reached twice in one JSON payload is
  populated twice.
- It offers no `ExistingInstancePolicy`. Every cell of the matrix has one
  defensible answer, so a mode switch would only add a way to get it wrong. If
  you need a fresh instance, pass a target whose member is `nil`, or use
  `Deserialize<T>`.

---

## Contract tests

| test | what it asserts |
| --- | --- |
| `tests\ReaderContracts` (`OWNERSHIP_ROUND_TRIP_*`) | a constructor's child list and child object survive a round trip through every format: reused, not replaced, nothing leaked |
| `tests\JsonCore` (`JSON_POPULATE_REUSES_INSTANCE`) | `Populate` fills the existing instance |
| `tests\BsonCore`, `tests\XmlCore` (`*_EXISTING_INSTANCE_REUSE`, `*_CONTAINER_REUSE`, `*_NULL_DETACHES`) | reuse of objects and containers; `null` detaches |
| `tests\CoreFoundation` (`OBJECTLIST_OWNS_ITS_ELEMENTS`, `OBJECTDICTIONARY_OWNS_ITS_VALUES`, `CORE_LIST_DOES_NOT_OWN`) | disposal asks the container what it owns |
| `tests\<Format>Native`, `tests\Robustness` | a failed read frees what it built - records, arrays, constructed containers - and nothing else; the run fails on any leak `scripts\test.ps1` sees |
