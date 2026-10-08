# API reference

Organised by what you are trying to do. Only currently supported APIs appear
here. Infrastructure and diagnostics are separated at the end.

**The sections up to "Freeze the configuration" are mostly about JSON**,
because JSON has the largest surface and every other engine is easier to read
against it. XML, BSON and Protobuf have the same shape - `Serialize<T>`,
`Deserialize<T>`, `Populate<T>`, `From`/`From<T>`, their own attributes,
their own enum mappings and their own custom-serializer base - and their
contracts are written up separately:

| | |
| --- | --- |
| [`serializer-behavior.md`](serializer-behavior.md) | what JSON writes |
| [`xml-behavior.md`](xml-behavior.md) | what XML writes |
| [`bson-behavior.md`](bson-behavior.md) | what BSON writes |
| [`protobuf-behavior.md`](protobuf-behavior.md) | what Protobuf writes, and why it needs field numbers |
| [`datetime-policies.md`](datetime-policies.md) | how each of them writes a date, and how to change it |
| [`conversion.md`](conversion.md) | moving a document between formats, and the three profiles |
| [`unicode-and-utf8.md`](unicode-and-utf8.md) | text is not bytes, and how to ask for each |
| [`dataset-projection.md`](dataset-projection.md) | the three ways to reach a `TDataSet` |

CBOR, MessagePack, YAML, CSV, Avro and ASN.1 arrived after those documents
were written, and each has its own engine, its own attributes and its own
options. Their reference entries are in
[The other engines](#the-other-engines), below the JSON and DataSet material.

- Ownership semantics when deserializing into an existing graph:
  [`deserialization-ownership.md`](deserialization-ownership.md)
- Design and internals: [`architecture.md`](architecture.md)
- Where each format stands, and what a schema-driven one needs:
  [`format-program.md`](format-program.md) and the format documents in
  [`formats/`](formats/json.md)
- What the library cannot do: [`limitations.md`](limitations.md)

---

## Pick a format at run time

```pascal
uses
  PascalForge.Serialization,
  PascalForge.Json.Registration,
  PascalForge.Xml.Registration;

// Registration is explicit: linking the units registers nothing.
TJsonSerializationRegistration.RegisterFormat;
TXmlSerializationRegistration.RegisterFormat;
// or: TSerializationFormatsRegistration.RegisterAll (PascalForge.Serialization.AllFormats)

Payload := TSerialization.Serialize<TShipment>(Shipment,
  TSerializationFormat.Xml);
Shipment := TSerialization.Deserialize<TShipment>(Payload,
  TSerializationFormat.Xml);

if TSerialization.IsRegistered(TSerializationFormat.Bson) then ...
```

`TSerialization` is non-generic and delegates only; the serialization lives
in each format's own engine. A `TSerializationFormat` value with no handler
raises `ESerializationFormatNotRegistered` naming the unit to include, and
never falls back to another format.

A registered format that cannot do what is being asked of it raises
`ESerializationFormatCapability` instead — a different exception, because
the fix is not to add a unit:

```pascal
if TSerialization.Supports(F, TSerializationFormatCapability.StructuralParse)
  then ...

for F in TSerialization.StructuralFormats do ...   // the ones that can
```

A `TSerializationPayload` is text or bytes, never both, and every accessor is
named for one direction:

```pascal
Payload.IsText          Payload.IsBinary
Payload.AsText          // text -> string;      binary -> raises
Payload.AsBytes         // binary -> bytes;     text   -> raises
Payload.ToUtf8Bytes     // text -> UTF-8 bytes; binary -> raises
Payload.DecodeUtf8Text  // binary -> string;    text   -> raises
```

So getting UTF-8 out of a conversion is one expression:

```pascal
Utf8 := TSerialization.Convert(Xml,
  TSerializationFormat.Xml, TSerializationFormat.Json).ToUtf8Bytes;
```

---

## Convert between formats

```pascal
// contract-aware: each side applies its own attributes
Xml := TSerialization.Convert<TShipment>(Json,
  TSerializationFormat.Json, TSerializationFormat.Xml);

// structural: no contract, and the profile says what may be adapted
Xml := TSerialization.Convert(Json,
  TSerializationFormat.Json, TSerializationFormat.Xml,
  TStructuralConversionProfile.Lossless);
```

| profile | a name the destination cannot spell | a value kind it does not have |
| --- | --- | --- |
| `Natural` *(default)* | encoded reversibly | the destination's idiom |
| `Lossless` | encoded reversibly | written with reconstructable metadata |
| `Strict` | refused, with the path | refused, with the path |

The two are independent policies underneath:

```pascal
Options := TStructuralConversionOptions.Default;
Options.NamePolicy  := TStructuralNamePolicy.Encode;   // or Error
Options.ValuePolicy := TStructuralValuePolicy.Error;   // or Natural, Lossless
Payload := TSerialization.Convert(Json, AFrom, ATo, Options);
```

Failures are `EStructuralConversionError`, carrying `SourceFormat`,
`DestinationFormat`, `Path` (`$.Subject.PersonInfo.$type`), `SourceKind` and
`Issue`. Nothing is silently dropped, with one documented exception: under
`Natural`, a schema-driven destination (Avro, ASN.1) omits a member its
schema does not name, where `Strict` and `Lossless` refuse it. See
[`conversion.md`](conversion.md).

The reversible XML name codec is public, for reading a converted document
elsewhere:

```pascal
TXmlNameCodec.EncodeName('$type');        // '_x0024_type'
TXmlNameCodec.DecodeName('_x0024_type');  // '$type'
TXmlNameCodec.IsValidName('1stValue');    // False
```

---

## Work with a document as values - Dynamic

`PascalForge.Dynamic`. A document with no Delphi type, to build, inspect or
change, then write in any format. Dynamic is not a `TSerializationFormat`.
The whole model is in [`dynamic.md`](dynamic.md).

```pascal
Obj := TDynamicObject.Create;
Obj
  .Append('name', 'Erin')                 // string, Int64, Boolean, a TDynamicValue,
  .Append('age', 35)                      // or any Delphi value, projected
  .Append('person', Person);
Obj.InsertAt(1, 'country', 'Utopia');    // 0..Count; Count appends
Obj.AddObject('address').Append('city', 'Uptown');   // returns the child
Obj.Append(Person);                       // the projection's members, imported
Obj.AppendOrReplace('name', TDynamicValue.NewStr('Erika'));  // explicit
Child := Obj.Extract('address');          // the caller owns it now
Obj.Import(Other, TDynamicCollision.DeepMerge);
Obj.MoveFrom(Other, TDynamicCollision.Overwrite);

Arr := TDynamicArray.Create;
Arr.Append(10).Append(20).Append(Person);
Arr.InsertAt(1, 15);
Arr.AppendRange(OtherArray);              // the explicit flatten

Value  := TDynamicSerializer.Serialize<TPerson>(Person);
Person := TDynamicSerializer.Deserialize<TPerson>(Value);
TDynamicSerializer.Populate(Existing, Value);
```

| Type | |
| --- | --- |
| `TDynamicValue` | a value: `Kind`, `As*`, `AsObject`, `AsArray`, `Count`, `Items`, `Names`, `Find`, `Parent`, `Clone`, `Equals`, `Describe`; scalars from `NewNull`, `NewBool`, `NewInt`, `NewUInt`, `NewFloat`, `NewDecimal`, `NewStr`, `NewBytes`, `NewDate`, `NewTime`, `NewDateTime`, `NewExtended` |
| `TDynamicObject` | `Append`, `InsertAt`, `AddObject`, `AddArray`, `AppendNull`, `AppendValue`, `InsertValueAt`, `Adopt`, `AppendOrReplace`, `Find`, `Get`, `Contains`, `IndexOf`, `Extract`, `ExtractAt`, `Remove`, `Delete` (by name or index), `Clear`, `Import`, `MoveFrom` |
| `TDynamicArray` | `Append`, `InsertAt`, `AddObject`, `AddArray`, `AppendNull`, `AppendValue`, `InsertValueAt`, `Adopt`, `AppendRange`, `ReplaceAt`, `ExtractAt`, `Delete`, `Clear` |
| `TDynamicKind` | `Null`, `Bool`, `Int`, `UInt`, `Float`, `Decimal`, `Str`, `Bytes`, `Date`, `Time`, `DateTime`, `Arr`, `Obj`, `Extended` |
| `TDynamicTag` | the tags an Extended value carries: `ObjectId`, `Decimal128`, `CborTag`, `MsgPackExtension`, `BigIntPositive`, `YamlAlias`, ... |
| `TDynamicCollision` | `Error`, `KeepExisting`, `Overwrite`, `DeepMerge` |
| `TDynamicSerializer` | `Serialize<T>`, `Serialize(TValue)`, `Deserialize<T>`, `Deserialize(Value, PTypeInfo)`, `Populate` |
| `EDynamicError` | the model's own refusals |

Each `As*` accessor reads its own kind and raises `EDynamicError` for any
other; the only cross-kind readings are `AsUInt` of a non-negative `Int`,
`AsDecimal` of an `Int` or `UInt`, and `AsDateTime` of a `Date` or `Time`.
`NewBytes` and `AsBytes` copy. See [`dynamic.md`](dynamic.md).

Every format reads into and writes from it, directly and with no
registration:

```pascal
Value := TJsonSerializer.ToDynamic(Json);    Json  := TJsonSerializer.FromDynamic(Value);
Value := TXmlSerializer.ToDynamic(Xml);      Xml   := TXmlSerializer.FromDynamic(Value, 'Root');
Value := TBsonSerializer.ToDynamic(Bytes);   Bytes := TBsonSerializer.FromDynamic(Value);
// CBOR, MessagePack, YAML and CSV the same; CSV takes TCsvOptions
Value := TAvroSerializer.ToDynamic(Bytes, Schema);   Bytes := TAvroSerializer.FromDynamic(Value, Schema);
Value := TAsn1Serializer.ToDynamic(Bytes, Module, 'Type');
Value := Descriptors.ToDynamic(Bytes, 'pkg.Message');   // TProtobufSchema

// the format chosen at run time - registration required
Value   := TSerialization.ToDynamic(Payload, TSerializationFormat.Bson);
Payload := TSerialization.FromDynamic(Value, TSerializationFormat.Xml);
```

Each text and binary format also takes `TStructuralConversionOptions`, for
the profile; `TSerialization` takes options or a schema context.

---

## The general attributes

`PascalForge.Serialization.Attributes`. Read by every format, by Dynamic and
by the DataSet projection; a format's own attribute or registration beats
them for that format. Precedence, format by format:
[`attributes.md`](attributes.md).

```pascal
[SerializationName('id')]           // the member's name, verbatim
[SerializationIgnore]               // in no format at all
[SerializationEnum('a,b,c')]        // on an enumeration type, or on a member
[SerializationEnum('a;b', ';')]     // another separator
```

---

## Ask for UTF-8 bytes

`Serialize<T>` returns Unicode **text** with no byte encoding. When bytes are
what you need, choose the encoding out loud:

```pascal
Bytes := TJsonSerializer.SerializeUtf8<TShipment>(Shipment);          // no BOM
Bytes := TJsonSerializer.SerializeUtf8<TShipment>(Shipment, Options);
Shipment := TJsonSerializer.DeserializeUtf8<TShipment>(Bytes);        // BOM ok

Bytes := TXmlSerializer.SerializeUtf8<TShipment>(Shipment);   // declaration on
Shipment := TXmlSerializer.DeserializeUtf8<TShipment>(Bytes);
```

JSON escapes only what JSON requires, so non-ASCII text stays legible. For a
7-bit consumer:

```pascal
Options := TJsonSerializationOptions.Default;
Options.UnicodeEscape := TJsonUnicodeEscapePolicy.EscapeNonAscii;
```

The standalone helpers, for a caller holding bytes of its own:

```pascal
StringToUtf8Bytes(Text);     // no BOM; an unpaired surrogate raises ESerializationUnsupported
Utf8BytesToString(Bytes);    // raises EInvalidUtf8, with the byte offset
IsValidUtf8(Bytes);
```

See [`unicode-and-utf8.md`](unicode-and-utf8.md).

---

## Serialize an object

```pascal
uses PascalForge.Json;

Json := TJsonSerializer.Serialize<TCustomer>(Customer);
```

`T` may be a class, a record, a `TNullable<T>`, a list, a dictionary, a set or
a scalar.

With per-operation options:

```pascal
var Opts := TJsonSerializationOptions.Default;
Opts.PropertyReadErrorPolicy := TJsonPropertyReadErrorPolicy.SkipMember;
Json := TJsonSerializer.Serialize<TCustomer>(Customer, Opts);
```

| `TJsonPropertyReadErrorPolicy` | Effect when a property getter raises |
| --- | --- |
| `RaiseError` (default) | the exception propagates, wrapped with the member name |
| `SkipMember` | the member is omitted |
| `WriteNull` | the member is written as `null` |

### Bounding the output of one operation

`MaxOutputBytes` is `0` by default, which means **unlimited** — the
production behaviour, unchanged. Set it and the operation aborts with
`EJsonSerializationLimitExceeded` as soon as the estimated document size
passes the ceiling:

```pascal
var Opts := TJsonSerializationOptions.Default;
Opts.MaxOutputBytes := 5 * 1024 * 1024;
Json := TJsonSerializer.Serialize<TGraph>(Value, Opts);
```

The estimate is accumulated **as the document is built**, so an unbounded
graph is stopped while the tree is still small rather than diagnosed after
the memory has been spent. The exception carries `Limit`, `Estimated` and the
member `Path` it stopped at.

Options are per call, never global, and are not affected by
`FreezeConfiguration`. A budget belongs to one operation on one thread: two
threads may serialize concurrently with different budgets, and an unbudgeted
operation is unaffected by a budgeted one. The estimate counts every scalar
as its text plus quotes and every structural token as a fixed cost, which
over-estimates slightly and never under-estimates.

## Deserialize an object

```pascal
Customer := TJsonSerializer.Deserialize<TCustomer>(Json);
```

The caller owns the returned graph. Bad input raises.

## Deserialize without raising

```pascal
if TJsonSerializer.TryDeserialize<TCustomer>(Json, Customer) then
  Use(Customer);
```

Malformed JSON text returns `False`; `Customer` is `nil`. Add
`TypeMismatch` to also absorb valid JSON that the type cannot represent, and
take the reason:

```pascal
if not TJsonSerializer.TryDeserialize<TCustomer>(Json, Customer, Error,
     [TJsonDeserializationError.InvalidJson,
      TJsonDeserializationError.TypeMismatch]) then
  Log(Error);
```

| Category | Means |
| --- | --- |
| `InvalidJson` | the text is not syntactically valid JSON. **The default** |
| `TypeMismatch` | valid JSON, but the target type cannot represent it: wrong shape, unknown enum or set value, a scalar that will not convert |

`TryDeserialize` is not a catch-all. A failing constructor, a bug in your own
custom serializer, an unsupported target type or an access violation
propagates no matter what `AHandledErrors` contains: only the categories you
name are turned into `False`, because anything else is a defect to fix rather
than input to reject.

On a handled failure the value is `Default(T)`: never a partially
deserialized graph, and nothing is leaked.

## Populate an existing object

```pascal
TJsonSerializer.Populate(Customer, Json);          // JSON text
TJsonSerializer.Populate(Customer, ParsedValue);   // an already-parsed TJSONValue
```

`Populate` merges: members absent from the JSON keep their current values, and
an existing compatible child is populated in place rather than replaced. Read
[`deserialization-ownership.md`](deserialization-ownership.md) before relying on the details — in
particular, an explicit `null` detaches a member **without** freeing it.

`Populate` is exception-based and stays that way: there is deliberately no
`TryPopulate`. It mutates a graph you already own, and can partially mutate it
before a later failure, so a Boolean result would imply a transactional
guarantee it cannot make. `TryDeserialize<T>` can make that guarantee only
because it builds a **new** value and hands it over on success.

## Serialize through a base class

```pascal
type
  TOrder = class(TJsonBase)   // gains ToJson / ToJsonString / Populate
  public
    Id: Integer;
  end;

Json := Order.ToJsonString;
Order.Populate(SomeJsonValue);
```

`TJsonBase` is optional convenience; `TJsonSerializer` works on any class.

---

## Rename or ignore a member

By attribute, on the declaration:

```pascal
uses PascalForge.Json;   // the attributes live in the facade

type
  TShipment = class
  public
    [JsonName('shipment_id')] Id: string;
    [JsonIgnore]             Scratch: Integer;
  end;
```

By registration, when you cannot edit the type:

```pascal
TJsonSerializer.RegisterFieldOverride<TShipment>('Id',
  TJsonFieldOverride.Rename('shipment_id'));
TJsonSerializer.RegisterFieldOverride<TShipment>('Scratch',
  TJsonFieldOverride.Ignore);

// by owner type name (works for implementation-section types too)
TJsonSerializer.RegisterFieldOverride('MyUnit.TShipment', 'Id',
  TJsonFieldOverride.Rename('shipment_id'));

// every member of a class matching a pattern, optionally including descendants
TJsonSerializer.RegisterClassFieldOverride(TComponent, 'ComObject',
  TJsonFieldOverride.Ignore, True);

// every matching member across a unit pattern
TJsonSerializer.RegisterUnitFieldOverride('MyApp.Wire.*', 'Internal*',
  TJsonFieldOverride.Ignore);
```

`TJsonFieldOverride` builders: `Rename`, `Ignore`, `SerializeWith`, `Members`,
`RecursiveReferences`, `Create`.

Resolution: most specific scope wins
(`field > exact class > class and descendants > unit name > unit pattern`);
within one scope, the latest registration wins.

## Choose member naming

```pascal
TJsonSerializer.RegisterUnitNaming('MyApp.Wire.*', TJsonNaming.SnakeCase);
TJsonSerializer.RegisterClassNaming(TShipment, TJsonNaming.SnakeCase, True);
```

`TJsonNaming.DefaultStyle` is camelCase with a leading underscore stripped.

## Register an enum mapping

```pascal
TJsonSerializer.RegisterEnumMapping<TStatus>(['new', 'active', 'closed']);
TJsonSerializer.RegisterEnumMapping('MyUnit.TStatus', ['new', 'active', 'closed']);

// only for one member
TJsonSerializer.RegisterFieldEnumMapping('MyUnit.TOrder', 'Status',
  ['N', 'A', 'C']);
```

Positional: entry *i* is the wire text for ordinal *i*. An ordinal outside the
mapping raises an `EJsonError` naming the type, the ordinal and the mapping
length. Unmapped enums use their Delphi identifier. Sets use the element
enum's mapping and are written as a comma-joined string.

## Register a custom serializer

Write it against the Delphi type you actually have. `TValue` and `PTypeInfo`
are not part of this:

```pascal
type
  TMoneyJsonSerializer = class(TCustomJsonValueSerializer<TMoney>)
  public
    function SerializeValue(const AValue: TMoney): TJSONValue; override;
    function DeserializeValue(const AJson: TJSONValue): TMoney; override;
  end;

function TMoneyJsonSerializer.SerializeValue(const AValue: TMoney): TJSONValue;
begin
  Result := TJSONString.Create(AValue.ToText);
end;

function TMoneyJsonSerializer.DeserializeValue(
  const AJson: TJSONValue): TMoney;
begin
  Result := TMoney.Parse(AJson.Value);
end;

TJsonSerializer.RegisterTypeSerializer<TMoney, TMoneyJsonSerializer>;
```

The two-parameter form is checked by the compiler: passing a serializer that
does not handle `TMoney` is a compile error, not a run-time surprise. The
one-parameter form `RegisterTypeSerializer<TMoney>(TMoneyJsonSerializer)`
takes a bare class reference — Delphi has no generic class references — and is
checked at registration instead, with a message naming both types.

For a **class-valued** member, add the optional third method so `Populate` can
reuse the instance the caller already owns:

```pascal
function TMetadataSerializer.DeserializeInto(const AJson: TJSONValue;
  AExisting: TMetadata): Boolean;
begin
  AExisting.Tag := AJson.Value;
  Result := True;         // "keep the instance you gave me"
end;
```

Return `False`, or do not override it, to mean "build a new one". The
framework never frees `AExisting` either way — see
[`deserialization-ownership.md`](deserialization-ownership.md).

### Without a class: delegates

A transformation too small to deserve a class can be registered as one or two
functions, named or inline:

```pascal
TJsonSerializer.RegisterFieldOverride<TNote>('Body',
  TJsonFieldOverride.SerializeWith<string>(
    function(const AValue: string): TJSONValue
    begin
      Result := TJSONString.Create('[' + AValue + ']');
    end,
    function(const AJson: TJSONValue): string
    begin
      Result := AJson.Value;
    end));

// or for every member of that type
TJsonSerializer.RegisterTypeSerializer<TMoney>(MoneyToJson, MoneyFromJson);
```

A delegate registration is an ordinary serializer as far as the engine is
concerned: the adapter is built **once**, when the registration is written,
and reused for every value. Nothing is allocated per operation, and the plan
cache is unaffected.

Two rules come with that:

- delegates are called concurrently and nothing locks around them, so keep
  them **stateless or capture only immutable state**;
- a delegate registration checks the configuration freeze before publishing
  anything, so delegates are not a way around `FreezeConfiguration`.

### One direction at a time

Either direction can be customised alone. The untouched direction keeps doing
exactly what it would have done with no registration at all, for the member's
declared type — there is no pass-through delegate to write, and nothing fails
because the opposite delegate is absent:

```pascal
// written with a prefix, read back the ordinary way
TJsonFieldOverride.SerializeWith<string>(AddPrefix)

// written the ordinary way, read through a parser
TJsonFieldOverride.DeserializeWith<TMoney>(ParseMoney)

// reading only, including populating an instance the caller owns
TJsonFieldOverride.DeserializeWith<TMetadata>(BuildMeta, FillMeta)
```

The fallback goes to the engine's built-in behaviour for that type, which
consults no registration of any kind, so a one-sided override cannot re-enter
itself.

### Where a serializer can be attached

| Registration | Matches |
| --- | --- |
| `RegisterTypeSerializer<T, TSer>` | that exact type, compiler-checked |
| `RegisterTypeSerializer<T>(Serialize, Deserialize)` | that exact type, from delegates |
| `TJsonFieldOverride.SerializeWith<T, TSer>` | one member, compiler-checked |
| `TJsonFieldOverride.SerializeWith<T>(...)` / `DeserializeWith<T>(...)` | one member, from delegates |
| `[JsonSerializer(...)]` | one member, on the declaration |
| `RegisterGenericTypeSerializer<TBound<Integer>>` | every specialization of that generic family (declaring unit + base name + arity) |
| `RegisterClassTypeSerializer(TStream, ...)` | that class and every descendant |
| `RegisterUnitClassTypeSerializer('MyApp.*', TDataSet, ...)` | that value base class, but only for members whose **owner** is in a matching unit |
| `TJsonFieldOverride.SerializeWith(...)` (untyped) | one member, any runtime type |

Precedence is documented in the interface section of `PascalForge.Json.pas`
immediately above `RegisterTypeSerializer`.

### Advanced / infrastructure: when TValue and PTypeInfo are the answer

The last four rows of that table cannot be expressed against a single Delphi
type, and for them `TCustomJsonValueSerializer` — the untyped base — remains
the contract:

```pascal
type
  { ONE implementation over SEVERAL Delphi types. }
  TFlexibleSerializer = class(TCustomJsonValueSerializer)
  public
    function SerializeValue(const AValue: TValue): TJSONValue; override;
    function DeserializeValue(const AJson: TJSONValue;
      ATypeInfo: PTypeInfo): TValue; override;
  end;
```

Use it for: dynamic runtime serializers; serializers intentionally handling
several Delphi types; generic-family serializers spanning many closed generic
types; unit/context infrastructure; low-level bridge code. Everything else is
better written against `TCustomJsonValueSerializer<T>`.

Two further optional overrides exist on the untyped base for infrastructure
that needs to know where a value came from:

- `SerializeValueContext` / `DeserializeValueContext` — receive a
  `TJsonSerializerContext` (owner type, member name, declared type)
- `DeserializeIntoContext` — the same, plus the existing instance

## Register a class factory

For a type without a usable zero-argument constructor:

```pascal
TJsonSerializer.RegisterClassFactory<TOrder>(
  function: TObject
  begin
    Result := TOrder.Create(SomeDependency);
  end);
```

## Configure member visibility and recursion

```pascal
TJsonSerializer.SetDefaultMemberStrategy(TJsonMemberStrategy.PublicSurface);
TJsonSerializer.RegisterTypeMemberStrategy<TAudit>(TJsonMemberStrategy.AllRTTI);
TJsonSerializer.RegisterFieldOverride<TContainer>('Detailed',
  TJsonFieldOverride.Members(TJsonMemberStrategy.AllRTTI));

TJsonSerializer.SetDefaultRecursiveReferencePolicy(
  TJsonRecursiveReferencePolicy.WriteNull);
TJsonSerializer.RegisterTypeRecursiveReferencePolicy<TNode>(
  TJsonRecursiveReferencePolicy.Error);
TJsonSerializer.RegisterFieldOverride<TContainer>('RootNode',
  TJsonFieldOverride.RecursiveReferences(TJsonRecursiveReferencePolicy.Error));

// never serialize instances of this hierarchy; emit null instead
TJsonSerializer.RegisterOpaqueClass(TMyHandleWrapper);
```

`TJsonMemberStrategy`: `PublicSurface` (default), `FieldsOnly`,
`PropertiesOnly`, `AllRTTI`.

## Work with implementation-section types

```pascal
// from inside the declaring unit
TJsonSerializer.RegisterTypeUnit(TypeInfo(TInternalRecord), 'MyUnit');

// force a runtime class to serialize through a public contract
TJsonSerializer.RegisterSerializationSurface(TInternalChild, TPublicBase);

// the key that name-scoped registrations are compared against
Key := TJsonSerializer.TypeKeyFor(TypeInfo(TInternalRecord));
```

Records need `RegisterTypeUnit` for unit-scoped and name-scoped registrations
to match, because record RTTI carries no unit name. Classes do not.

## Freeze the configuration

```pascal
TJsonSerializer.FreezeConfiguration;
TDataSetSerializer.FreezeConfiguration;
```

After freezing, any further registration raises. **The first real operation
of a serializer freezes it too**, so this call only chooses an earlier point -
the end of startup - at which a late registration anywhere fails.

Each engine freezes its own: every serializer facade has
`FreezeConfiguration` and `IsFrozen`, because each keeps its own
registration tables and one format's freeze has no business stopping
another's startup. `ResetConfiguration`, on the facades that have one, is for
tests. See [`configuration-lifecycle.md`](configuration-lifecycle.md).

---

## Recognize another library's nullable

```pascal
uses
  PascalForge.Serialization;

// at startup, before anything of that type is serialized
TSerialization.RegisterNullableFamily<TMaybe<Integer>>;            // FValue / FHasValue
TSerialization.RegisterNullableFamily<TOptional<Integer>>(
  TNullableLayout.Fields('FPayload', 'FPresent'));

TSerialization.IsNullableType(TypeInfo(TMaybe<string>));          // True
TSerialization.RegisteredNullableFamilies;                        // for diagnostics
```

`PascalForge.Nullable.TNullable<T>` needs no registration. The specialization
is a sample: the whole generic family is registered, and every format and the
DataSet projection recognize it. `TNullableLayout` and `ENullableFamilyError`
are re-exported by `PascalForge.Serialization`, so no other unit is needed.
See [`nullable-families.md`](nullable-families.md).

## Internal: the engine plumbing in Core

`PascalForge.Serialization.Core` also declares the machinery the engines
share. It is public only because Delphi has no visibility between units; it
is **not part of the supported API**, may change in any release, and
application code should not call it:

`TSerializationTypes`, `TSerializationGraphGuard`, `TSerializationOwnership`,
`TSerializationVariants`, `TSerializationTypeInfo`, `TStructuralText`,
`TStructuralPath`, `TStructuralRoute`, `TStructuralRouteStep`,
`TNullableAccess`, `TListAccess`, `TDictionaryAccess`, `TContainerKind`,
`TDateTimePolicy`, `TDateTimePolicies`, and the format-handler contract
`TSerializationFormatHandler` / `TSerializationFormats` (formats are
registered with `T<Format>SerializationRegistration` and queried through
`TSerialization`).

Everything else Core declares - the exceptions, `TSerializationFormat`,
`TSerializationPayload`, the structural conversion options and profiles,
`TSerializationContext` and `TSerializationSchema`, `TSerializationFormatCapability`,
`TDecimal128`, `TNullableLayout` - is public API.

---

## The other engines

Each of these is a real engine. A Delphi value is written straight to the
format and read straight back; nothing routes through JSON text or through
the dynamic tree. What is shared is the Delphi type foundation in
`PascalForge.Serialization.Core` — what a nullable is, what a collection is,
how a type is named — and nothing else. Each format reads only its own
attributes: `[YamlName]` never sees `[JsonName]`.

Using any of them directly needs no registration. `uses PascalForge.Cbor` is
the whole prerequisite for `TCborSerializer`. The matching
`PascalForge.*.Registration` unit - `TCborSerializationRegistration.
RegisterFormat` and its siblings, called explicitly - exists only so that code
choosing a format at run time can reach the engine through `TSerialization`,
and ASN.1's registers three format values from one call.

---

## CBOR — `PascalForge.Cbor`

RFC 8949 / STD 94.

```pascal
uses PascalForge.Cbor;

Data    := TCborSerializer.Serialize<TShipment>(Shipment);            // TBytes
Data    := TCborSerializer.Serialize<TShipment>(Shipment, AOptions);
Shipment := TCborSerializer.Deserialize<TShipment>(Data);
TCborSerializer.Populate<TShipment>(Existing, Data);
```

CBOR is binary, so `TBytes` is what it returns and what it reads. There is no
base64 API pretending otherwise.

### The document, without a contract

```pascal
class function Encode(AValue: TCborValue): TBytes; overload; static;
class function Encode(AValue: TCborValue;
  const AOptions: TCborEncodeOptions): TBytes; overload; static;
class function Decode(const AData: TBytes): TCborValue; overload; static;
class function Decode(const AData: TBytes;
  const AOptions: TCborDecodeOptions): TCborValue; overload; static;
class function IsDeterministic(const AData: TBytes): Boolean; static;
```

`Encode` borrows; `Decode` hands the caller a tree it owns. `TCborValue` is
CBOR's own model and reaches everything Delphi has no type for — an integer up
to 18446744073709551615, an unregistered tag, a simple value with no assigned
meaning. `TCborKind` names twelve of them: `UInt`, `NegInt`, `Bytes`, `Text`,
`Arr`, `Map`, `Tag`, `Bool`, `Null`, `Undefined`, `Simple` and `Float`.

A decoded value remembers more than its meaning — the argument width its head
used, whether a string, array or map was definite or indefinite, where an
indefinite string's chunks ended, and a float's exact width and bits. None of
that is needed to understand the value; all of it is needed to write the
document back out unchanged, which is the difference between a codec and a
lossy reader.

`IsDeterministic` answers by decoding and re-encoding deterministically, so it
applies the encoder's own rules rather than a second copy of them that could
drift.

`TCborValue.ToDiagnostic` renders a value in the notation of RFC 8949 section
8. There is no `FromDiagnostic`: the specification defines how to write
diagnostic notation down and defines no parser for it, so it is a display form
and anything that has to survive a round trip travels as bytes.

`TCborTags` names the tag numbers this library understands well enough to name
— `DateTimeString`, `EpochDateTime`, `PositiveBignum`, `NegativeBignum`,
`DecimalFraction`, `Bigfloat`, `Uuid`, `SelfDescribed` and the rest — with
`TCborTags.Describe(ANumber)` and `TCborTags.IsKnown(ANumber)`. A tag outside
that list is still read, still written and still carried through conversion; it
simply has no meaning attached to it here.

### Options

```pascal
TCborEncodeOptions = record
public
  Deterministic: Boolean;
  SelfDescribe: Boolean;
  class function Default: TCborEncodeOptions; static;
  class function Rfc8949Deterministic: TCborEncodeOptions; static;
  function WithSelfDescribe: TCborEncodeOptions;
end;

TCborDecodeOptions = record
public
  MaxDepth: Integer;
  AllowTrailingData: Boolean;
  class function Default: TCborDecodeOptions; static;
  function WithMaxDepth(AValue: Integer): TCborDecodeOptions;
end;
```

`Serialize<T>` takes encode options. `Deserialize<T>` takes none and reads with
the defaults; decode options steer a raw `Decode`, which is where a caller is
reading somebody else's buffer and the depth and the trailing bytes are the
caller's problem.

`AllowTrailingData` is `False` by default, because a whole-buffer decode that
ignores half its input is how a truncation goes unnoticed. CBOR documents are
commonly concatenated in a stream, so a caller reading one item out of a longer
buffer sets it.

`Deterministic` is RFC 8949 section 4.2 and does **not** include section
4.2.2's optional extra: an integral float stays a float, because turning `1.0`
into `1` behind the caller's back is a preference some applications adopt and
not part of deterministic encoding.

Three constants: `CborDefaultMaxDepth` is 256; `CborBigfloatExponentLimit`
is 1024 — beyond which `TryAsDecimalText` returns `False` for a tag 5 value
rather than spending unbounded time on digits nobody asked for; and
`CborDecimalExponentLimit` is 6144 — a tag 4 decimal fraction whose exponent
is outside ±6144 is refused with `ECborInputError` (`TryAsDecimalText`
raises rather than returning `False`), and the writer refuses with
`ECborError` to produce one. An eleven-byte tag 4 used to make the reader
expand its exponent into digits until it hung or ran out of memory.

### Attributes

| Attribute | Effect |
| --- | --- |
| `[CborName('id')]` | the member's map key |
| `[CborIgnore]` | removes the member from both directions |
| `[CborDateTimeRepresentation(...)]` | a `TCborDateTimeRepresentation`, or a `FormatDateTime` pattern |
| `[CborGuidRepresentation(...)]` | `TaggedUuid` *(default)*, `LowercaseString`, `RawBytes` |
| `[CborCurrencyRepresentation(...)]` | `DecimalFraction` *(default)*, `ScaledInt64`, `Double`, `DecimalString` |
| `[CborEnumRepresentation(...)]` | `Name` *(default)* or `Value` |
| `[CborSerializer(TSomething)]` | a custom serializer for one member |

`TCborDateTimeRepresentation` is `EpochTagged` — tag 1 over seconds since the
Unix epoch, the default for `TDateTime` — `Rfc3339Tagged`, `UnixSeconds`,
`UnixMilliseconds`, `Iso8601Text` and `CustomString`. `TDate` and `TTime`
default to `Iso8601Text`, because neither is an instant and writing one as a
tagged epoch would claim a point in time it does not have.

`Currency` defaults to tag 4 with exponent -4 and the scaled integer Delphi
actually stores. A `Currency` **is** a decimal fraction with four places and
tag 4 **is** a decimal fraction, so that pairing is a translation rather than a
decision, which is why it is the default.

### Custom serializers

```pascal
type
  TCoordinateCborSerializer = class(TCustomCborValueSerializer<TCoordinate>)
  public
    function SerializeValue(const AValue: TCoordinate): TCborValue; override;
    function DeserializeValue(AValue: TCborValue;
      const AExisting: TCoordinate): TCoordinate; override;
  end;

TCborSerializer.RegisterTypeSerializer<TCoordinate>(TCoordinateCborSerializer);
```

`AExisting` is what the member already held: reuse it when it is an instance
you can populate, and say so by returning it. The untyped
`TCustomCborValueSerializer` — `Serialize(const AValue: TValue)` and
`Deserialize(AValue: TCborValue; ATypeInfo: PTypeInfo; const AExisting: TValue)`
— is there for infrastructure that deliberately covers several Delphi types.

### Registrations and conversion

```pascal
class procedure RegisterEnumMapping<T>(const AValues: array of string); static;
class procedure RegisterTypeSerializer<T>(
  ASerializerClass: TCborValueSerializerClass); static;

class procedure SetDateTimeRepresentation(
  ARepresentation: TCborDateTimeRepresentation); overload; static;
class procedure SetDateTimeRepresentation(const APattern: string); overload; static;
class procedure RegisterDateTimeRepresentation<T>(
  ARepresentation: TCborDateTimeRepresentation); overload; static;
class procedure RegisterFieldDateTimeRepresentation<T>(const AFieldName: string;
  ARepresentation: TCborDateTimeRepresentation); overload; static;

class procedure SetDefaultEncodeOptions(const AOptions: TCborEncodeOptions); static;
class function DefaultEncodeOptions: TCborEncodeOptions; static;
class procedure FreezeConfiguration; static;
class procedure ResetConfiguration; static;
```

Date and time resolves member attribute, then field registration, then type
registration, then the global default, then the built-in representation — once,
while a plan is built.

```pascal
class function From(const ASource: string; AFrom: TSerializationFormat): TBytes; overload; static;
class function From(const ASource: TBytes; AFrom: TSerializationFormat): TBytes; overload; static;
class function From(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): TBytes; overload; static;
class function From(const ASource: TSerializationPayload; AFrom: TSerializationFormat;
  AProfile: TStructuralConversionProfile): TBytes; overload; static;

class function From<T>(const ASource: string; AFrom: TSerializationFormat): TBytes; overload; static;
class function From<T>(const ASource: TBytes; AFrom: TSerializationFormat): TBytes; overload; static;
class function From<T>(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): TBytes; overload; static;
```

CBOR is the destination and is known at compile time, so only the **source**
format is looked up, through the registry — the unit has no compile-time
dependency on any other format. The generic form is contract-aware; the
non-generic one is structural, and takes a profile.

### Errors

`ECborError`, with `ECborInputError` for bytes at fault and
`ECborInternalError` for a model or configuration at fault. Each way a
document can be ill-formed has its own `ECborInputError` descendant, so a
caller can tell "the bytes stopped early" from "this nests a thousand deep"
without matching on message text: `ECborTruncatedInput`,
`ECborReservedAdditionalInfo`, `ECborUnexpectedBreak`, `ECborChunkMismatch`,
`ECborInvalidText`, `ECborDepthExceeded`, `ECborTrailingData` and
`ECborMalformedSimple`.

`ECborRangeError` descends from `ECborError` directly and not from the input
family, deliberately: 2^64-1 read as an `Int64` means the document is fine and
the request is not.

---

## MessagePack — `PascalForge.MessagePack`

```pascal
uses PascalForge.MessagePack;

Data    := TMessagePackSerializer.Serialize<TShipment>(Shipment);      // TBytes
Shipment := TMessagePackSerializer.Deserialize<TShipment>(Data);
TMessagePackSerializer.Populate<TShipment>(Existing, Data);
```

There is no options record here, and no `Serialize` overload taking one:
writing always chooses the shortest encoding a value fits in, because that is
what every other implementation produces and therefore what an interoperability
comparison is against.

### The document, without a contract

```pascal
class function Parse(const AData: TBytes): TMessagePackValue; static;
class function Write(AValue: TMessagePackValue): TBytes; static;
```

MessagePack's root is **any** value, not a map — unlike BSON, whose root is
always a document — so `Parse` returns whatever the bytes are and `Write`
accepts whatever it is given. No value is ever wrapped under an invented member
name to make it fit.

`TMessagePackKind` is `Null`, `Bool`, `Int`, `UInt`, `Float32`, `Float64`,
`Str`, `Bin`, `Arr`, `Map`, `Extension` and `Timestamp`. Three of those
distinctions are the reason to choose this format and the engine keeps all
three:

- **`Str` is not `Bin`.** A Delphi `string` is text and is written as `str`,
  encoded UTF-8; `TBytes` is bytes and is written as `bin`. The two families
  were separated in 2013 precisely because conflating them made it impossible
  to tell a sentence from a JPEG.
- **Signed is not unsigned.** The integer range runs from -(2^63) to (2^64)-1,
  which is wider than `Int64`. A `uint64` above `High(Int64)` is `UInt` and is
  never rounded into a `Double` or wrapped into a negative `Int64`. Everything
  an `Int64` can hold is `Int`, so a consumer testing for `Int` is not
  surprised by a small number that arrived in a `uint32`.
- **A timestamp is a type.** Extension type -1 is the specification's own, in
  three encodings, and `Timestamp` is a separate kind rather than an
  `Extension` with a flag, because a consumer asking "is this a point in time"
  should not have to know the number.

`MessagePackTimestampExtensionType` is -1 and `MessagePackMaxDepth` is 512.
An extension type this library knows nothing about survives a read and a write
unchanged, which is the whole point of the family.

### Attributes

| Attribute | Effect |
| --- | --- |
| `[MessagePackName('id')]` | the member's map key |
| `[MessagePackIgnore]` | removes the member from both directions |
| `[MessagePackDateTimeRepresentation(...)]` | a `TMessagePackDateTimeRepresentation`, or a `FormatDateTime` pattern |
| `[MessagePackGuidRepresentation(...)]` | `LowercaseString` *(default)* or `Bin` |
| `[MessagePackCurrencyRepresentation(...)]` | `ScaledInt64` *(default)*, `Float64`, `DecimalString` |
| `[MessagePackEnumRepresentation(...)]` | `Name` *(default)* or `Ordinal` |
| `[MessagePackSerializer(TSomething)]` | a custom serializer for one member |

`TMessagePackDateTimeRepresentation` is `Timestamp` — the default for
`TDateTime`, and the only representation another MessagePack implementation
will recognize as an instant — `StringIso8601`, which is the default for
`TDate` and `TTime`, `UnixSeconds`, `UnixMilliseconds` and `CustomString`.

MessagePack has no UUID type and no extension number is defined for one, so the
GUID setting is a choice between two ordinary representations rather than a
translation. Inventing an application extension number would make the document
readable only by this library, which is the opposite of why anyone picks
MessagePack.

### Custom serializers, registrations and conversion

```pascal
type
  TMoneyMsgPackSerializer = class(TCustomMessagePackValueSerializer<TMoney>)
  public
    function SerializeValue(const AValue: TMoney): TMessagePackValue; override;
    function DeserializeValue(AValue: TMessagePackValue;
      const AExisting: TMoney): TMoney; override;
  end;

class procedure RegisterEnumMapping<T>(const AValues: array of string); static;
class procedure RegisterTypeSerializer<T>(
  ASerializerClass: TMessagePackValueSerializerClass); static;

class procedure SetDateTimeRepresentation(
  ARepresentation: TMessagePackDateTimeRepresentation); overload; static;
class procedure SetDateTimeRepresentation(const APattern: string); overload; static;
class procedure RegisterDateTimeRepresentation<T>(
  ARepresentation: TMessagePackDateTimeRepresentation); overload; static;
class procedure RegisterDateTimeRepresentation<T>(const APattern: string); overload; static;
class procedure RegisterFieldDateTimeRepresentation<T>(const AFieldName: string;
  ARepresentation: TMessagePackDateTimeRepresentation); overload; static;
class procedure RegisterFieldDateTimeRepresentation<T>(
  const AFieldName, APattern: string); overload; static;

class procedure FreezeConfiguration; static;
class procedure ResetConfiguration; static;
```

`From` and `From<T>` have the same four plus three overloads CBOR has, with
`TBytes` results.

### Errors

`EMessagePackError`, with `EMessagePackInputError` and
`EMessagePackInternalError`. Three input failures carry their own class and
their own constructor, because each has something specific to report:

| Class | Constructor | Means |
| --- | --- | --- |
| `EMessagePackReservedByte` | `CreateAt(AOffset)` | `0xC1`, the one byte the specification marks "never used". Not reserved-for-later and not unknown: a document containing it is not a MessagePack document |
| `EMessagePackInvalidUtf8` | `CreateAt(AOffset, AReason)` | a `str` whose bytes are not UTF-8. The specification says a `str` is UTF-8, so this is the document lying about itself |
| `EMessagePackDepthExceeded` | `CreateFor(ALimit)` | nesting past `MessagePackMaxDepth` |

---

## YAML — `PascalForge.Yaml`

YAML 1.2.2. The parser is this library's own; RAD Studio ships none.

```pascal
uses PascalForge.Yaml;

Text    := TYamlSerializer.Serialize<TShipment>(Shipment);            // string
Text    := TYamlSerializer.Serialize<TShipment>(Shipment, AOptions);
Shipment := TYamlSerializer.Deserialize<TShipment>(Text);
TYamlSerializer.Populate<TShipment>(Existing, Text);
```

### A stream of N documents is N documents

```pascal
class function SerializeAll<T>(const AValues: TArray<T>): string; overload; static;
class function SerializeAll<T>(const AValues: TArray<T>;
  const AOptions: TYamlEmitOptions): string; overload; static;
class function DeserializeAll<T>(const AYaml: string): TArray<T>; static;
```

Nothing collapses a stream silently. `Deserialize<T>` requires exactly one
document and names `DeserializeAll<T>` when it finds more. Structural
conversion of a three-document stream produces a three-element array, not the
first document; writing back produces **one** document, because the dynamic
tree has no way to say which of the two was meant.

### The representation graph

```pascal
class function ParseStream(const AYaml: string): TYamlStream; static;
class function ParseDocument(const AYaml: string): TYamlDocument; static;
class function SerializeStream(AStream: TYamlStream): string; overload; static;
class function SerializeStream(AStream: TYamlStream;
  const AOptions: TYamlEmitOptions): string; overload; static;
class function SerializeDocument(ADocument: TYamlDocument): string; overload; static;
class function SerializeDocument(ADocument: TYamlDocument;
  const AOptions: TYamlEmitOptions): string; overload; static;
class function Expand(ADocument: TYamlDocument): TYamlDocument; static;
```

The caller owns what these return. `TYamlKind` is `Scalar`, `Sequence`,
`Mapping` and `Alias`; `TYamlScalarStyle` is `Plain`, `SingleQuoted`,
`DoubleQuoted`, `Literal` and `Folded`; `TYamlChomping` is `Clip`, `Strip` and
`Keep`.

A mapping's **key is a node**, not a string — YAML allows a sequence or a
mapping as a key, the `? key : value` form — so `TYamlNode.Keys[I]` is a node
and `KeyText(I)` returns `''` for a key that is not a scalar.

An **alias is a node of its own**, carrying the anchor name, because an alias
says two members are the same node and nothing else in this library can say
that. `TYamlDocument.ResolveAnchor(AName)` hands back the node it names,
borrowed. `Expand` returns a copy with every alias replaced by the node it
names, leaving the original untouched; a contract deserialization expands too,
because a Delphi record has no way to be two members at once.

`TYamlDocument` also carries `Version`, `TagDirectives`, `ExplicitStart` and
`ExplicitEnd`, so a document introduced by `---` and closed by `...` writes
back the same way. `TYamlTagDirective` is a `Handle` and a `Prefix`.

### The core schema, as pure functions

```pascal
TYamlSchema.Resolve(AText)                  // TYamlScalarType
TYamlSchema.IsNullText(AText)
TYamlSchema.IsBoolText(AText, AValue)
TYamlSchema.TryToInt64(AText, AValue)
TYamlSchema.TryToUInt64(AText, AValue)
TYamlSchema.TryToDouble(AText, AValue)
TYamlSchema.FloatToText(AValue)
TYamlSchema.NeedsQuotingAsString(AText)
```

Public because "does this library resolve `yes` as a boolean" is a question
worth being able to ask directly. It does not: resolution is 1.2, not 1.1, so
`yes`, `no`, `on`, `off`, `y` and `n` are strings, `190:20:30` is a string,
`0b1010` is a string, and `012` is the integer twelve because 1.2 dropped
1.1's leading-zero octal and spells octal `0o14`. A quoted, literal or folded
scalar is always a string.

`TYamlScalarType` is `Str`, `Null`, `Bool`, `Int` and `Float`. The tag
constants are on the same record: `DefaultPrefix`, `TagStr`, `TagNull`,
`TagBool`, `TagInt`, `TagFloat`, `TagSeq`, `TagMap`, `TagBinary` — the
published way to put bytes in a YAML document, which is what `TBytes` uses —
and `TagTimestamp`, which is recognized when a document writes it and never
inferred from a plain scalar that merely looks like a date.

### Options and limits

```pascal
TYamlEmitOptions = record
public
  Style: TYamlStyle;                   // Block (default) or Flow
  Indent: Integer;
  ExplicitDocumentStart: Boolean;
  ExplicitDocumentEnd: Boolean;
  class function Default: TYamlEmitOptions; static;
  class function FlowStyle: TYamlEmitOptions; static;
end;

TYamlLimits = record
public
  MaxDepth: Integer;
  MaxExpandedNodes: Integer;
  class function Default: TYamlLimits; static;
end;

class procedure SetDefaultEmitOptions(const AOptions: TYamlEmitOptions); static;
class function DefaultEmitOptions: TYamlEmitOptions; static;
class procedure SetDuplicateKeyPolicy(APolicy: TYamlDuplicateKeyPolicy); static;
class function DuplicateKeyPolicy: TYamlDuplicateKeyPolicy; static;
class procedure SetLimits(const ALimits: TYamlLimits); static;
class function Limits: TYamlLimits; static;
```

`TYamlDuplicateKeyPolicy` is `Error` *(default)*, `LastWins` and `FirstWins`.
The specification says the keys of a mapping are unique, so the default
refuses; the other two are for a caller who has to read somebody else's file.

The two budgets exist because the billion laughs attack is a YAML attack: ten
aliases per level, ten levels, and a small document expands into gigabytes.
Expansion carries a depth budget and a node budget, and exceeding either raises
`EYamlLimitExceeded` rather than allocating.

### Attributes, custom serializers and registrations

| Attribute | Effect |
| --- | --- |
| `[YamlName('id')]` | the member's mapping key |
| `[YamlIgnore]` | removes the member from both directions |
| `[YamlDateTimeRepresentation(...)]` | a `TYamlDateTimeRepresentation`, or a `FormatDateTime` pattern |
| `[YamlSerializer(TSomething)]` | a custom serializer for one member |

`TYamlDateTimeRepresentation` is `Iso8601` *(default)*, `Timestamp` — the same
text carrying the `!!timestamp` tag, so a reader that knows the tag gets a date
rather than a string — `UnixSeconds`, `UnixMilliseconds` and `CustomString`.
There is no GUID, currency or enum representation attribute here; enumerations
are configured through `RegisterEnumMapping<T>`.

```pascal
type
  TMoneyYamlSerializer = class(TCustomYamlValueSerializer<TMoney>)
  public
    function SerializeValue(const AValue: TMoney): TYamlNode; override;
    function DeserializeValue(AValue: TYamlNode; const AExisting: TMoney): TMoney; override;
  end;

class procedure RegisterEnumMapping<T>(const AValues: array of string); static;
class procedure RegisterTypeSerializer<T>(
  ASerializerClass: TYamlValueSerializerClass); static;
class procedure SetDateTimeRepresentation(
  ARepresentation: TYamlDateTimeRepresentation); overload; static;
class procedure SetDateTimeRepresentation(const APattern: string); overload; static;
class procedure RegisterDateTimeRepresentation<T>(
  ARepresentation: TYamlDateTimeRepresentation); overload; static;
class procedure RegisterFieldDateTimeRepresentation<T>(const AFieldName: string;
  ARepresentation: TYamlDateTimeRepresentation); overload; static;
```

`From` and `From<T>` have the same seven overloads CBOR has, returning
`string`.

### Errors

| Class | Means |
| --- | --- |
| `EYamlError` | everything in the unit |
| `EYamlParseError` | the document is at fault. Carries `Line` and `Column`, because "invalid YAML" without a position is useless on a file of any size. `CreateAt(ALine, AColumn, AReason)` |
| `EYamlTabIndentationError` | a tab where indentation was expected. Its own class because it is the commonest way a hand-written file goes wrong |
| `EYamlUnclosedQuoteError` | a quoted scalar that reaches the end of the stream |
| `EYamlDuplicateKeyError` | the same key twice in one mapping, under the default policy |
| `EYamlAliasError` | the alias family |
| `EYamlUnresolvedAliasError` | an alias naming an anchor the document never defined |
| `EYamlAliasCycleError` | `&a [ *a ]` — legal YAML with no Delphi shape. The parser never follows an alias, so a cycle cannot hang it |
| `EYamlLimitExceeded` | a depth or expansion budget was reached |
| `EYamlInputError` | the document parsed and says something the contract cannot accept |
| `EYamlInternalError` | the model or the configuration is at fault |

---

## CSV — `PascalForge.Csv`

CSV is a table, and this unit does not pretend otherwise. Every other format
here writes a tree; a row of cells has no way to say "this member is itself an
object" or "this member is a list of three things". So the projection onto a
table is an explicit decision made by the caller, out of a named set of
strategies, and the default for a collection is to **refuse** with the member
path.

```pascal
uses PascalForge.Csv;

Text := TCsvSerializer.Serialize<TArray<TCustomer>>(Customers);
Back := TCsvSerializer.Deserialize<TArray<TCustomer>>(Text);
```

`T` is the whole table, not one row: `TArray<TCustomer>`, `TList<TCustomer>`,
`TObjectList<TCustomer>`. A single record or class is accepted and produces a
one-row table.

```pascal
class function Serialize<T>(const AValue: T): string; overload; static;
class function Serialize<T>(const AValue: T;
  const AOptions: TCsvOptions): string; overload; static;
class function Deserialize<T>(const AText: string): T; overload; static;
class function Deserialize<T>(const AText: string;
  const AOptions: TCsvOptions): T; overload; static;

class function SerializeToBytes<T>(const AValue: T): TBytes; overload; static;
class function SerializeToBytes<T>(const AValue: T;
  const AOptions: TCsvOptions): TBytes; overload; static;
class function DeserializeBytes<T>(const AData: TBytes): T; overload; static;
class function DeserializeBytes<T>(const AData: TBytes;
  const AOptions: TCsvOptions): T; overload; static;
```

The byte forms are the same text encoded UTF-8, with the mark `WriteBom` asks
for. Reading accepts a mark whether or not one was asked for, and refuses
malformed UTF-8 by name rather than substituting replacement characters.

There is no `Populate` and no `From`. CSV is reached from another format
through `TSerialization.Convert`, which goes via the registry handler — and
that handler uses `TCsvOptions.Default`, because a caller who named only a
format has said nothing about how a tree should be flattened onto rows.

### Several tables, which one payload cannot hold

```pascal
class function SerializeTables<T>(const AValue: T): TCsvDocumentSet; overload; static;
class function SerializeTables<T>(const AValue: T;
  const AOptions: TCsvOptions): TCsvDocumentSet; overload; static;
class function DeserializeTables<T>(ATables: TCsvDocumentSet): T; overload; static;
class function DeserializeTables<T>(ATables: TCsvDocumentSet;
  const AOptions: TCsvOptions): T; overload; static;
```

`SeparateTable` produces a parent table and one child table per collection, and
one `TSerializationPayload` cannot hold several files. It is therefore not
reachable through `Serialize` at all: asking for it there raises
`ECsvProjectionError` naming the member path and pointing at `SerializeTables`.
Nothing is concatenated, no separator is invented, and no archive bytes are
smuggled into a text payload.

A document in another format reaches the same tables through `TablesFrom`,
which reads it with the source format's registered handler (CSV itself needs
no registration):

```pascal
class function TablesFrom(const ASource: TSerializationPayload;
  ASourceFormat: TSerializationFormat;
  const AOptions: TCsvOptions): TCsvDocumentSet; overload; static;
class function TablesFrom(const ASource: TSerializationPayload;
  ASourceFormat: TSerializationFormat; ASourceContext: TSerializationContext;
  const AOptions: TCsvOptions): TCsvDocumentSet; overload; static;
```

`TSerialization.Convert` into CSV takes single-document CSV options from a
`TCsvSchema` in the conversion options, and refuses `SeparateTable` with
`ESerializationFormatCapability` naming `TablesFrom` and `SerializeTables`.
See [`formats/csv.md`](formats/csv.md).

The caller owns the returned document set.

```pascal
TCsvTableDocument = record          // Name, Content, RowCount
TCsvTableRelationship = record      // ParentTable, ChildTable, MemberPath,
                                    // ParentKeyColumn, ChildReferenceColumn,
                                    // KeyIsGenerated
```

`TCsvDocumentSet` has `Count`, `Tables[]`, `IndexOf`, `TableByName`,
`TryGetTable`, `TableNames`, `RelationshipCount`, `Relationships[]`,
`ChildrenOf(AName)`, `RootName` and `Describe`. The relationships are
**metadata** and live on the document set; the files hold data and column names
and nothing else. What does go into a file is the join *value*, which is data:
without it a child table alone cannot be put back together with its parent.

### Options

```pascal
TCsvOptions = record
public
  Delimiter: Char;
  QuoteChar: Char;
  HasHeader: Boolean;
  WriteBom: Boolean;
  NewLine: TCsvNewLine;
  NestedObjectMode: TCsvNestedObjectMode;
  CollectionMode: TCsvCollectionMode;
  MultipleCollections: TCsvMultipleCollections;
  PathSeparator: string;
  NullPolicy: TCsvNullPolicy;
  NullLiteral: string;
  SchemaInference: TCsvSchemaInferencePolicy;
  RelationshipNaming: TCsvRelationshipNaming;
  DuplicateHeaders: TCsvDuplicateHeaderPolicy;
  RaggedRows: TCsvRaggedRowPolicy;
  TrimUnquotedValues: Boolean;
  AlwaysQuote: Boolean;
  ExpandDottedNames: Boolean;

  class function Default: TCsvOptions; static;
  class function ForDialect(ADialect: TCsvDialect): TCsvOptions; static;

  function Dialect: TCsvDialect;
  function NewLineText: string;
  function RequiresSeparateTables: Boolean;
  function Describe: string;
end;
```

Every field has a `With...` builder: `WithDelimiter`, `WithQuoteChar`,
`WithHeader`, `WithBom`, `WithNewLine`, `WithNestedObjectMode`,
`WithCollectionMode`, `WithMultipleCollections`, `WithPathSeparator`,
`WithNullPolicy` (two overloads, the second taking the literal),
`WithSchemaInference`, `WithRelationshipNaming`, `WithDuplicateHeaders`,
`WithRaggedRows`, `WithTrimmedValues`, `WithAlwaysQuote` and
`WithExpandedDottedNames`.

`Dialect` reports what the options **are**, not what they were asked for:
setting a delimiter by hand moves a `Standard` dialect to `Custom`.

| Enumeration | Values |
| --- | --- |
| `TCsvDialect` | `Standard` (RFC 4180), `Excel` (RFC 4180 plus a byte-order mark), `TabSeparated`, `Custom` |
| `TCsvNewLine` | `CrLf`, `Lf` |
| `TCsvNestedObjectMode` | `Flatten` *(default)*, `JsonCell`, `SeparateTable`, `Error` |
| `TCsvCollectionMode` | `Error` *(default)*, `JsonCell`, `RepeatedRows`, `SeparateTable`, `NumberedColumns` |
| `TCsvMultipleCollections` | `Error` *(default)*, `CartesianProduct` |
| `TCsvDuplicateHeaderPolicy` | `Error` *(default)*, `Rename`, `UseFirst`, `UseLast` |
| `TCsvRaggedRowPolicy` | `Error` *(default)*, `PadWithEmpty`, `Truncate` |
| `TCsvNullPolicy` | `EmptyField` *(default)*, `Literal`, `Error` |
| `TCsvSchemaInferencePolicy` | `StringsOnly`, `Conservative` *(default)*, `Numeric`, `Extended` |

Four of those defaults are `Error`, and each for the same reason. A row cannot
hold a list; two independent collections of N and M elements have no single
correct row count, and the N-times-M arithmetic that produces one invents
pairings the source never contained; two columns with one name silently decide
which of them a caller meant; a ragged row silently decides what the missing
cells were.

`EmptyField` is the null default because it is what every other CSV producer
does, and it is **not reversible**: CSV has no null, an empty field is also how
the empty string is written, and the document did not record the difference.
`Literal` round-trips both, at the cost that the literal text can no longer be
an ordinary value in that column.

`Conservative` infers a Boolean from unambiguous true/false, an `Integer` or
`Int64` from a plain signed integer, and a `Float` from a plain fractional
value. Everything else stays text — including `00123`, `+001` and `000001`,
whose leading zeros and signs may be significant, and including anything that
merely looks like a date, a time, a GUID or base64. `Extended` is the only
policy under which a string that looks like a date becomes one, and it is
opt-in for exactly that reason.

Reading is literal in the same spirit: a column called `Address.City` is a
column whose name is `Address.City`. Expansion into a nested object happens
when the Delphi contract says that member is nested, or when the caller sets
`ExpandDottedNames` — never on the strength of a dot, which is a legal
character in a column name.

`TCsvRelationshipNaming` has `ReferenceColumn`, `GeneratedKeyColumn`,
`CollisionSuffix`, `Default` and `Describe`. An empty `ReferenceColumn` means
derive one: the parent table's name, an underscore, and the parent key column's
name — `Customer_Id`.

### A schema, alongside the file and never inside it

```pascal
class function InferSchema(const AText: string): TCsvSchema; overload; static;
class function InferSchema(const AText: string;
  const AOptions: TCsvOptions): TCsvSchema; overload; static;
class function SchemaOf<T>: TCsvSchema; overload; static;
class function SchemaOf<T>(const AOptions: TCsvOptions): TCsvSchema; overload; static;
```

The two answer different questions. `InferSchema` reads a document and reports
what the **spelling** of its values supports under the inference policy;
`SchemaOf` reads a Delphi contract and reports what the **types** actually are,
with no guessing involved. The caller owns what comes back.

`TCsvSchema` descends from `TSerializationSchema`:

```pascal
TCsvSchema = class(TSerializationSchema)
public
  constructor Create; overload;
  constructor Create(const AOptions: TCsvOptions); overload;
  function Format: TSerializationFormat; override;
  function Describe: string; override;
  procedure Add(const AColumn: TCsvColumn);
  procedure SetColumn(AIndex: Integer; const AColumn: TCsvColumn);
  function IndexOf(const AName: string): Integer;
  function TryGetColumn(const AName: string; out AColumn: TCsvColumn): System.Boolean;
  property Count: Integer read GetCount;
  property Columns[AIndex: Integer]: TCsvColumn read GetColumn; default;
  property Options: TCsvOptions read FOptions write FOptions;
  property TableName: string read FTableName write FTableName;
end;

TCsvColumn = record
public
  Name: string;
  ColumnType: TCsvColumnType;
  Nullable: System.Boolean;
  Size: Integer;
  DateFormat: string;
  Path: string;
  class function Make(const AName: string; AType: TCsvColumnType): TCsvColumn; static;
  function Describe: string;
end;
```

`TCsvColumnType` is `Str`, `Boolean`, `Int32`, `Int64`, `Float`, `DateTime`,
`Guid` and `Binary`. The options the schema was built with travel on it, so a
schema handed onwards carries the dialect it describes. `Size` is the longest
text observed or a declared width: a hint for a consumer building a table, not
a constraint this unit enforces.

A schema is never serialized into the CSV. A header row holds names; it does
not hold a type, a size or a nested path, and putting them there would produce
a file no other CSV reader understands.

### Attributes and custom cell serializers

| Attribute | Effect |
| --- | --- |
| `[CsvName('ID')]` | the column name |
| `[CsvIgnore]` | removes the member from both directions |
| `[CsvKey]` | names the member whose value identifies a row, which `SeparateTable` joins on. Without one a key is generated, which works and means nothing outside the document set it was made for |
| `[CsvTable('Customer')]` | the table name for a row type |
| `[CsvDateTimeFormat('yyyy-mm-dd')]` | a `FormatDateTime` pattern for one member; empty means ISO 8601 |
| `[CsvSerializer(TSomething)]` | a custom cell serializer for one member |

```pascal
type
  TMoneyCsvSerializer = class(TCustomCsvCellSerializer<TMoney>)
  public
    function SerializeValue(const AValue: TMoney): string; override;
    function DeserializeValue(const AText: string; const AExisting: TMoney): TMoney; override;
  end;

class procedure RegisterTypeSerializer<T>(
  ASerializerClass: TCsvCellSerializerClass); static;
class procedure SetDateTimeFormat(const APattern: string); static;
class procedure RegisterDateTimeFormat<T>(const APattern: string); static;
class procedure RegisterFieldDateTimeFormat<T>(
  const AFieldName, APattern: string); static;
class procedure FreezeConfiguration; static;
class procedure ResetConfiguration; static;
```

A cell is text, so a custom CSV serializer is a pair of text conversions and
nothing more. It cannot produce a structure, because there is nowhere in a cell
to put one. Date and time resolves member attribute, then field registration,
then type registration, then the global default, then ISO 8601.

### Errors

`ECsvError`, with `ECsvInputError` for the document — a quote that never
closes, a ragged row, a duplicate header — and `ECsvInternalError` for the
model or the configuration. `ECsvProjectionError` is raised when the value
cannot be projected onto a table under the selected options, and it always
carries `Path`, the Delphi member path, because "it does not fit" without
saying which member does not fit is not a diagnosis:

```pascal
constructor CreateForPath(const APath, AReason: string);
property Path: string read FPath;    // 'Customer.Orders'
```

---

## Avro — `PascalForge.Avro` and `PascalForge.Avro.Schema`

Apache Avro 1.12.0.

An Avro datum carries no type information at all — no tags, no field names, no
lengths except the ones the types themselves imply — so the same five bytes are
a record, a pair of longs or a string depending entirely on the schema you read
them with. Everything here therefore takes a schema, and the two places one
might be missing say so rather than improvising: structural conversion without
a schema in the options raises `ESerializationSchemaRequired`, and
contract-aware serialization **generates** the schema from the Delphi type and
hands it back so the caller can publish it beside the bytes.

```pascal
uses PascalForge.Avro, PascalForge.Avro.Schema;

class function SchemaFor<T>: TAvroSchema; static;
class function SchemaJsonFor<T>: string; static;

class function Serialize<T>(const AValue: T): TBytes; static;
class function Deserialize<T>(const AData: TBytes): T; static;
class procedure Populate<T>(const AInstance: T; const AData: TBytes); static;
class function DeserializeWith<T>(const AData: TBytes; AWriter: TAvroSchema): T; static;
```

The caller **owns** what `SchemaFor<T>` returns and frees it. It is a fresh
tree each time, because a schema is a mutable object and handing out a shared
one would let any caller's edit reach every other.

`Serialize<T>` and `Deserialize<T>` both use the schema generated for `T`, as
writer and as reader. `DeserializeWith<T>` reads bytes written with a
**different** schema, resolving the writer's against `T`'s.

### The datum level

```pascal
class function Encode(ASchema: TAvroSchema; AValue: TAvroValue): TBytes; static;
class function Decode(const ABytes: TBytes; AWriter: TAvroSchema): TAvroValue; overload; static;
class function Decode(const ABytes: TBytes;
  AWriter, AReader: TAvroSchema): TAvroValue; overload; static;
```

Writer and reader schemas are both first class, because data written with one
schema being read with another is the whole point of Avro's schema evolution.
The two-schema `Decode` applies the specification's Schema Resolution rules:
numeric promotion, defaults for fields the writer did not have, skipping fields
the reader does not want, aliases for renamed records and fields, branch-wise
union resolution and the enum default.

`TAvroKind` is `Null`, `Bool`, `Int`, `Long`, `Float`, `Double`, `Bytes`,
`Str`, `Rec`, `Enum`, `Arr`, `Map`, `Fixed`, and three that are logical types
rather than Avro types: `Decimal`, `DateTime` and `Duration`. They are kinds
because the alternative is worse — a decimal held as a `Double` is destroyed
silently, a timestamp held as a bare `Int64` is unreadable, and a duration is
three unsigned numbers that are not a count of anything on their own.

`Int` and `Long` are distinct kinds because they are distinct Avro types with
distinct encodings; handing a `Long` to an `int` schema is an error rather than
a silent narrowing - on every path: a union takes its `long` branch for a
value an `int` cannot hold, an `int` datum whose varint decodes past 32 bits is
refused on read with `EAvroInputError`, and an `int` default past 32 bits with
`EAvroResolutionError`. `TAvroValue.NewExactDateTime(AValue, ALogical, ARaw)`
carries the exact underlying integer the writer wrote, which is why a
timestamp-micros value re-encodes to the bytes it came from even though a
`TDateTime` resolves to the millisecond.

### Object container files

```pascal
class function WriteContainer(ASchema: TAvroSchema;
  const AValues: array of TAvroValue;
  ACodec: TAvroCodec = TAvroCodec.Null): TBytes; overload; static;
class function ReadContainer(const AData: TBytes;
  out AWriterSchemaJson: string): TObjectList<TAvroValue>; overload; static;
class function ReadContainer(const AData: TBytes; AReader: TAvroSchema;
  out AWriterSchemaJson: string): TObjectList<TAvroValue>; overload; static;
class function ReadContainer(const AData: TBytes; AReader: TAvroSchema;
  const AOptions: TAvroReadOptions;
  out AWriterSchemaJson: string): TObjectList<TAvroValue>; overload; static;
class function ReadContainer<T>(const AData: TBytes): TArray<T>; overload; static;
class function ReadContainer<T>(const AData: TBytes;
  const AOptions: TAvroReadOptions): TArray<T>; overload; static;
class function WriteContainer<T>(const AValues: array of T;
  ACodec: TAvroCodec = TAvroCodec.Null): TBytes; overload; static;
```

`AWriterSchemaJson` receives the schema the file itself carries, which is the
only schema that can read it. The caller owns the list and everything in it.

`TAvroReadOptions` carries per-call read limits. `MaxInflatedBlockBytes`
bounds what one deflate block may decompress to, enforced while inflating;
`TAvroReadOptions.Default` sets it to `DefaultMaxInflatedBlockBytes`
(64 MiB), and `WithMaxInflatedBlockBytes` returns a copy with another value.
Past it, `EAvroInputError`. The overloads without options use the default.
The budget must be positive: `Validate` raises `EAvroError` for zero or a
negative value, and `WithMaxInflatedBlockBytes` and every `ReadContainer`
that takes options call it - which also catches a `TAvroReadOptions`
declared without `Default`.

`WriteContainer` flushes a block at about 1 MiB, or gives a larger datum a
block of its own, so a default read opens every default write however much
data it holds. Under `TAvroCodec.Deflate` a single datum that encodes past
`DefaultMaxInflatedBlockBytes` raises `EAvroError` on write: no default read
could open the file. `TAvroCodec.Null` writes it.

`TAvroCodec` has two values, `Null` and `Deflate` — RFC 1951 raw deflate,
through `System.ZLib`. The `snappy`, `bzip2`, `xz` and `zstandard` codecs are
**not** implemented, each needing a compressor this library will not take a
dependency on. A container file using one is detected and named on read, never
silently mis-read.

Two further things are outside the implemented profile and are named here
rather than discovered later. The JSON **encoding of data** is not produced or
consumed — the JSON schema language is fully implemented, and the JSON data
encoding is a diagnostic representation that is a different thing. RPC —
protocols, messages, handshakes — is a separate specification layered on this
one. Single-object encoding and the schema-registry framings are absent too;
the fingerprint they are built from is here, the framing is not.

### The schema model

`PascalForge.Avro.Schema` is a separate unit so a caller may parse, inspect,
fingerprint and print a schema without ever encoding a byte. It knows nothing
about Delphi RTTI: a schema arriving as JSON somebody else wrote — from a
registry, from a `.avsc` file, from a container file's metadata — is modelled
exactly as written, including the parts this library makes no further use of.
A generated schema and an external one are the same kind of object and travel
the same code paths.

```pascal
TAvroSchema = class(TSerializationSchema)
public
  constructor Create(AType: TAvroType);
  class function Parse(const AJson: string): TAvroSchema; static;
  function Format: TSerializationFormat; override;
  function Describe: string; override;
  function ToJson: string;
  function CanonicalForm: string;
  function Fingerprint: UInt64;
  function IsNamed: Boolean;
  function Matches(const AFullName: string): Boolean;
  function IndexOfField(const AName: string): Integer;
  function FindField(const AName: string): TAvroField;
  function IndexOfBranchType(AType: TAvroType): Integer;
  function IndexOfSymbol(const ASymbol: string): Integer;
  function TypeName: string;
  { SchemaType, Name, Namespace, FullName, Doc, Aliases, FieldCount, Fields[],
    Symbols, EnumDefault, HasEnumDefault, ItemType, ValueType, BranchCount,
    Branches[], Size, LogicalType, LogicalName, Precision, Scale }
end;
```

`Parse` returns the root, which owns every node under it. Nodes are **not**
owned by their parents, because Avro schemas share and recurse — a named type
used a second time is the same node, and a record may contain itself — so every
node from one `Parse` call is owned by an arena on the root. Freeing the root
frees the lot, once each. A schema handed to the library through
`TStructuralConversionOptions` is borrowed and never freed there.

`TAvroType` has the fourteen types the specification defines: `Null`, `Bool`,
`Int`, `Long`, `Float`, `Double`, `Bytes`, `Str`, `Rec`, `Enum`, `Arr`, `Map`,
`Union`, `Fixed`. There is no "reference" member, because a named type used a
second time resolves to the same node and a reference is invisible by the time
parsing has finished.

`TAvroLogicalType` is `None`, `Decimal`, `Uuid`, `Date`, `TimeMillis`,
`TimeMicros`, `TimestampMillis`, `TimestampMicros`, `LocalTimestampMillis`,
`LocalTimestampMicros`, `Duration` and `Unknown`. The specification is explicit
that an implementation which does not recognise an annotation must fall back to
the underlying type rather than fail, so an unrecognised one is `Unknown` and
its text is kept in `LogicalName`.

`TAvroField` has `Name`, `Doc`, `Aliases`, `FieldType` (borrowed from the
arena), `Default` (owned, `nil` when there is none), `Order` and
`Matches(AName)`. `TAvroFieldOrder` is `Ascending`, `Descending` and `Ignore`,
kept because a schema says it — dropping an attribute the author wrote would
make `ToJson` print a different schema from the one that was parsed.

`TAvroDefault` holds a default as the JSON shape it had, because a default
cannot be modelled as "a value of the field's type" while the field's type may
still be an unresolved named reference. `TAvroDefaultKind` is `Null`, `Bool`,
`Num`, `Str`, `Arr` and `Obj`, and `IsIntegral` distinguishes a default of `1`
for a long from `1.0`.

Four things at unit level:

```pascal
const AVRO_EMPTY_FINGERPRINT64 = UInt64($c15d213aa4d7a795);

function AvroFingerprint64(const ABytes: TBytes): UInt64;
function IsValidAvroName(const AName: string): Boolean;
function IsValidAvroFullName(const AName: string): Boolean;
function AvroJsonQuote(const AText: string): string;
```

`CanonicalForm` is the specification's Parsing Canonical Form and `Fingerprint`
is the 64-bit Rabin fingerprint of it, including the published initial
constant, which is what the single-object encoding and most schema registries
use. `AvroFingerprint64` is exposed for a caller holding canonical-form text
from elsewhere who needs to fingerprint it without building a schema.

### Attributes, custom serializers and registrations

| Attribute | Effect |
| --- | --- |
| `[AvroName('emailAddress')]` | the field name in the generated schema |
| `[AvroIgnore]` | removes the member from both directions |
| `[AvroAliases('emailAddress, email_address')]` | aliases, for reading data written before a rename |
| `[AvroSerializer(TSomething)]` | a custom serializer for one member |

`AvroAliases` takes one comma-separated string rather than an open array,
because a Delphi attribute argument must be a constant expression and an open
array of strings is not reliably one across the compilers this library targets.
`Names: TArray<string>` splits it. On a class or record the aliases are the
record's and are namespace-qualified against its own namespace when written
unqualified; on a member they are the field's, and field aliases are plain
names because the specification does not namespace them.

```pascal
type
  TMoneyAvroSerializer = class(TCustomAvroValueSerializer<TMoney>)
  public
    class function SchemaJson: string; override;
    function SerializeValue(const AValue: TMoney): TAvroValue; override;
    function DeserializeValue(AValue: TAvroValue; const AExisting: TMoney): TMoney; override;
  end;
```

An Avro custom serializer has to supply a **schema** as well as a value,
because without one the bytes it produces cannot be read by anybody, including
this library. `SchemaJson` is parsed once and spliced into the schema generated
for the owning type.

```pascal
class procedure RegisterTypeSerializer<T>(
  ASerializerClass: TAvroValueSerializerClass); static;
class procedure RegisterEnumMapping<T>(const ASymbols: array of string); static;
class procedure FreezeConfiguration; static;
class procedure ResetConfiguration; static;

class function From<T>(const ASource: string; AFrom: TSerializationFormat): TBytes; overload; static;
class function From<T>(const ASource: TBytes; AFrom: TSerializationFormat): TBytes; overload; static;
class function From<T>(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): TBytes; overload; static;
```

Avro symbols must be legal Avro names, which is stricter than Delphi, so
`RegisterEnumMapping<T>` is how a Delphi enumeration with an unrepresentable
spelling gets one that works.

There is **no non-generic `From`**: a structural Avro payload needs a schema
and that signature has nowhere to put one. Use `TSerialization.Convert` with
the schema overload instead.

### Errors

`EAvroError`, with `EAvroInputError` for the bytes or the datum and
`EAvroInternalError` for the Delphi model or the configuration.
`EAvroResolutionError` descends from `EAvroInputError` and has its own class
because it is the one failure a caller can usually fix by changing a schema
rather than by changing data: the writer's schema and the reader's cannot be
reconciled by the specification's resolution rules.

`EAvroSchemaError`, from `PascalForge.Avro.Schema`, is raised when the schema —
or the JSON claiming to be one — is at fault.

---

## ASN.1 — `PascalForge.Asn1` and `PascalForge.Asn1.Schema`

X.690, in all three encoding rules.

ASN.1 is a schema language and an encoding is something else. X.680 defines the
types; X.690 defines three ways of writing a value of one of those types down,
and they are not interchangeable — DER forbids the indefinite length form that
CER requires for every constructed value. So one engine serves three
`TSerializationFormat` values, and the encoding rule is an argument everywhere
rather than a property of the library.

```pascal
uses PascalForge.Asn1;

Data    := TAsn1Serializer.Serialize<TShipment>(Shipment, TAsn1EncodingRule.Der);
Shipment := TAsn1Serializer.Deserialize<TShipment>(Data, TAsn1EncodingRule.Der);
```

```pascal
class function Serialize<T>(const AValue: T;
  ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): TBytes; static;
class function Deserialize<T>(const AData: TBytes;
  ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): T; static;
```

The Delphi type is the schema for these two: a record or class becomes a
SEQUENCE of its fields in declaration order, honouring the ASN.1 attributes. A
type whose members cannot be mapped raises, naming the member and the Delphi
type, rather than dropping it. There is no `Populate` and no `From`.

`TAsn1EncodingRule` is `Ber` — X.690 clause 8, every valid form allowed —
`Der`, clause 10, definite lengths in the shortest form, primitive strings,
sorted SET OF, one encoding per value, which is what a signature is computed
over — and `Cer`, clause 9, also one encoding per value but a different one:
indefinite length for every constructed value, and strings longer than a
thousand octets split into thousand-octet segments, so an encoder can stream
without knowing the total length in advance.

PER (X.691) and OER (X.696) are deliberately absent. They are further encoding
rules of the same schema language, they share none of X.690's tag-length-value
machinery, and a half-done PER would be worse than none. XER and JER are absent
too, and for the additional reason that producing them here would mean reaching
into another format's units, which this library does not do.
`TAsn1EncodingRule` has three values and nothing pretends otherwise.

### The document model

```pascal
class function Encode(AValue: TAsn1Value;
  ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): TBytes; static;
class function ParseTlv(const AData: TBytes;
  ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): TAsn1Value; static;
```

`Encode` borrows the tree. Under DER and CER the result is canonical by
construction: a SET OF's components are sorted, a SET's are put in tag order,
and the encoding hints on the tree are ignored.

`ParseTlv` is a **diagnostic**, and is named and documented as one. It decodes
the octets into a tree of tags with no schema, interpreting universal tags by
their number, which is the one thing X.690 lets a reader do without a module.
It is not structural parsing and is not offered as a structural capability: a
tree whose nodes are called "context-specific 0" has no member names, cannot
tell a SEQUENCE from a SEQUENCE OF, and has lost the type of every implicitly
tagged value in it. It is here because inspecting somebody else's certificate
is a real thing to want, and because a byte-exact re-encode is how this library
proves its writer agrees with everyone else's. `ARule` selects how strictly the
octets are checked.

`TAsn1Value` carries a tag and a **kind**, and the two are not the same
question. An IMPLICIT `[0]` IA5String has the tag `[0]` and the kind
`Ia5String`: the tag says where it sits in its containing type and the kind
says how its content octets are to be read. Losing the kind is how an
implicitly tagged string turns into an opaque blob.

`Name` is the component a value fills; when a schema resolved the value as
the alternative of a CHOICE, `ChoiceAlternative` holds the alternative's
name (`''` otherwise), and the structural bridge writes the CHOICE as an
object with that one member.

`TAsn1TagClass` is `Universal`, `Application`, `ContextSpecific` and `Private`,
in that order, so the ordinal **is** the bit pattern of the two high bits of the
identifier octet. `TAsn1UniversalTag` holds the universal tag numbers as
constants — `BooleanTag`, `IntegerTag`, `BitString`, `OctetString`, `NullTag`,
`Oid`, `Enumerated`, `Utf8String`, `Sequence`, `SetTag`, `UtcTime`,
`GeneralizedTime` and the rest.

Constructors, all `static`:

```pascal
NewBoolean, NewInteger (Int64 or TAsn1BigInt), NewBitString(ABits, AUnusedBits),
NewOctetString, NewNull, NewOid (TAsn1Oid or text), NewRelativeOid,
NewEnumerated, NewString(AKind, AText), NewSequence, NewSequenceOf, NewSet,
NewSetOf, NewUtcTime, NewGeneralizedTime,
NewExplicit(ATagClass, ATagNumber, AInner), NewImplicit(...), NewRaw(...)
```

`AUnusedBits` is a required argument rather than a property that defaults to
zero, because it is part of the value's identity: a BIT STRING of nine bits and
one of sixteen can hold the same two octets, and losing the count is a defect.

`NewExplicit` builds a constructed wrapper carrying the tag with `AInner` as its
single component. `NewImplicit` **replaces** `AInner`'s own tag and returns it;
its kind survives, which is the whole point — the content octets are still a
PrintableString's content octets, and only the label on the front has changed.
Both adopt `AInner`.

A parent owns its children. `Add` adopts; `Extract(AIndex)` releases one from
ownership and returns it, for a caller who needs to keep a component after the
tree is freed.

`TAsn1Kind` separates `Sequence` from `SequenceOf` and `SetValue` from `SetOf`
although nothing in the octets tells them apart, because the **canonical rules**
differ: a SET's components are ordered by tag and a SET OF's by their encoded
octets, and a decoder that cannot tell which it has cannot check either. Only a
schema resolves it; raw decoding yields the structured form. `Unknown` is a tag
this library does not interpret, kept verbatim and written back unchanged,
which is what lets an unknown extension survive a round trip.

Two BER encoding hints sit on a value — `UseIndefiniteLength` and
`SegmentSize` — and have **no** effect under DER or CER, which have exactly one
encoding per value and would not be canonical if a caller could steer them. A
decoder sets them to record what it found, so a BER document read and written
again comes back the same.

### Arbitrary precision, and object identifiers

```pascal
TAsn1BigInt = record
public
  class function Zero: TAsn1BigInt; static;
  class function FromInt64(AValue: System.Int64): TAsn1BigInt; static;
  class function FromUInt64(AValue: UInt64): TAsn1BigInt; static;
  class function FromMagnitude(ANegative: System.Boolean;
    const AMagnitude: TBytes): TAsn1BigInt; static;
  class function FromText(const AText: string): TAsn1BigInt; static;
  class function TryFromText(const AText: string;
    out AValue: TAsn1BigInt): System.Boolean; static;
  class function FromTwosComplement(const ABytes: TBytes): TAsn1BigInt; static;
  function ToTwosComplement: TBytes;
  function ToText: string;
  function TryToInt64(out AValue: System.Int64): System.Boolean;
  function IsZero: System.Boolean;
  function Compare(const AOther: TAsn1BigInt): System.Integer;
  function Equals(const AOther: TAsn1BigInt): System.Boolean;
  property Negative: System.Boolean read FNegative;
  property Magnitude: TBytes read FMagnitude;
end;
```

ASN.1's INTEGER has no width. A certificate serial number is routinely twenty
octets and an RSA modulus two hundred and fifty-six, so an `Int64` is not a
narrow case here — it is the exception. No general arithmetic is offered: what
is here is what encoding and decoding need. Negative zero is not a value this
record can hold, because it is not a value X.690 can encode.

```pascal
TAsn1Oid = record
public
  Arcs: TArray<TAsn1BigInt>;
  class function FromArcs(const AArcs: array of System.Int64): TAsn1Oid; static;
  class function FromText(const AText: string): TAsn1Oid; static;
  class function TryFromText(const AText: string; out AOid: TAsn1Oid): System.Boolean; static;
  function ToText: string;
  function ArcCount: System.Integer;
  function Equals(const AOther: TAsn1Oid): System.Boolean;
end;
```

An OID is a path through a tree of arcs, not a string, and it is stored as its
arcs. Keeping it as text and re-splitting on demand would be smaller code, and
would lose the distinction between an arc written `0` and one written `00`, and
would make an arc larger than `Int64` unrepresentable. X.509 has such arcs.

### Schema-driven

```pascal
class function DecodeWithSchema(const AData: TBytes;
  ASchema: TSerializationSchema; const ATypeName: string;
  ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): TAsn1Value; static;
class function EncodeWithSchema(AValue: TAsn1Value;
  ASchema: TSerializationSchema; const ATypeName: string;
  ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): TBytes; static;

class function ToDynamic(const AData: TBytes; ASchema: TSerializationSchema;
  const ATypeName: string;
  ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): TDynamicValue; static;
class function FromDynamic(AValue: TDynamicValue; ASchema: TSerializationSchema;
  const ATypeName: string;
  ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der): TBytes; static;
```

`ASchema` must be a `TAsn1Schema`; the parameter is typed as the base class
only because `PascalForge.Asn1.Schema` sits above `PascalForge.Asn1`. A schema
for another format raises `ESerializationSchemaRequired` rather than being
ignored, and so does a missing one.

A BER encoding is self-delimiting but not self-describing. The octets
`30 06 02 01 05 01 01 FF` say "a constructed universal 16 containing an integer
5 and a boolean true"; they do not say that this is a Reading, that the integer
is a Celsius temperature or that the boolean means the sensor was calibrated.
Context-specific tag `[0]` means whatever the module says it means and nothing
at all otherwise. That is why structural conversion requires a schema, and why
`ATypeName` is an argument: nothing in an encoding says which assignment a
payload holds.

### The module parser

```pascal
uses PascalForge.Asn1.Schema;

Schema := TAsn1Schema.ParseModule(ModuleText);
Def    := Schema.FindType('Certificate');
```

```pascal
TAsn1Schema = class(TSerializationSchema)
public
  class function ParseModule(const AText: string): TAsn1Schema; static;
  class function SubsetDescription: string; static;
  function FindType(const AName: string): TAsn1TypeDef;
  function RequireType(const AName: string): TAsn1TypeDef;
  function IsExported(const AName: string): Boolean;
  function Format: TSerializationFormat; override;
  function Describe: string; override;
  procedure AddType(ATypeDef: TAsn1TypeDef);
  procedure SetModuleName(const AName, AOid: string);
  procedure SetTagDefault(AValue: TAsn1TagDefault);
  procedure SetExports(AAll: Boolean; const ASymbols: TArray<string>);
  procedure SetImports(const AImports: TArray<TAsn1Import>);
  { ModuleName, ModuleOid, TagDefault, TypeCount, Types[], HasExports,
    ExportsAll, ExportedSymbols, Imports, RootType, Rule }
end;
```

X.680 is a large language — parameterized types, information object classes,
the X.681/682/683 layer, value set arithmetic, constraint algebra. All of it is
real and none of it is here. What is parsed is the part that describes a data
structure: the module header with its tag default, EXPORTS, IMPORTS, type
assignments, SEQUENCE, SET and CHOICE with their component lists, SEQUENCE OF
and SET OF nested to any depth, the base types this library has an encoder for,
named number lists, references to other types in the same module, tags in all
four classes, OPTIONAL and DEFAULT, SIZE and value range constraints with MIN
and MAX, and both comment forms.

Everything else is **refused by name**. The parser raises `EAsn1SchemaError`
naming the construct and the line rather than skipping it, because a module
that half-parsed would produce an encoder that writes the wrong octets and
nobody would find out until somebody else's decoder rejected them. The refusals
that matter in practice are ANY and ANY DEFINED BY, value assignments,
parameterized types, information object classes, COMPONENTS OF, the extension
marker, WITH COMPONENTS, constraint unions and intersections, EXTERNAL,
EMBEDDED PDV, CHARACTER STRING, the character string types with no encoder
here, and selection types. `SubsetDescription` returns the whole list at run
time, so a program can print what it supports rather than quoting a comment.

One schema serves all three encoding rules. A module describes types; BER, DER
and CER are three ways of writing a value of one of them down, so
`TAsn1Schema` does not belong to one of the three. `Rule` only decides which
`TSerializationFormat` value `Format` reports, for code that routes by format;
it does not restrict what the schema can be used with. `RootType` says which
assignment a payload holds — when it is empty and the module has exactly one
assignment, that one is used, and otherwise the call raises rather than
picking.

`TAsn1TagDefault` is `ExplicitTags` (X.680's default when the header says
nothing), `ImplicitTags` and `AutomaticTags`. `TAsn1TypeKind` is `Base`,
`Sequence`, `SetType`, `Choice`, `SequenceOf`, `SetOf` and `Reference`.
`TAsn1TypeDef.Resolve(ASchema)` follows a chain of references to the type that
actually has a shape, and raises when the chain is broken or circular.
`TAsn1Constraint` is a `Present`/`HasLower`/`HasUpper`/`Lower`/`Upper` record
with `None`, `Range`, `Admits` and `Describe`; an absent bound is what MIN and
MAX mean.

A `TAsn1Component` with a DEFAULT is implicitly optional in the encoding, and
under DER and CER a value equal to the default **must** be omitted.

Lifetime: a schema is borrowed everywhere, like every `TSerializationSchema`.
The caller that parsed it frees it.

### Attributes

| Attribute | Effect |
| --- | --- |
| `[Asn1Tag(0)]` / `[Asn1Tag(TAsn1TagClass.Application, 3)]` | a context-specific, application or private tag on a member. Without it a member takes its type's universal tag |
| `[Asn1Optional]` | the member may be absent. On write it is omitted when its `TNullable` is empty (without the attribute an empty nullable is written as `NULL`); on read its absence is not an error |
| `[Asn1Choice('Selector')]` | applied to the **member** whose record type is the CHOICE, naming the field that says which alternative is selected |
| `[Asn1Implicit]` | the tag replaces the type's own. Smaller, and unreadable without the module |
| `[Asn1Explicit]` | the tag wraps the type's own encoding. The default when neither appears, because it is what a module with no DEFINITIONS clause means |
| `[Asn1StringType(TAsn1Kind.PrintableString)]` | which ASN.1 string type a Delphi string member becomes |
| `[Asn1Serializer(TMyThing)]` | a `TCustomAsn1ValueSerializer<T>` descendant for this one member |
| `[Asn1Ignore]` | removes the member from both directions |

### A type ASN.1 has no encoding for

```pascal
TCustomAsn1ValueSerializer<T> = class(TCustomAsn1ValueSerializer)
public
  function SerializeValue(const AValue: T): TAsn1Value; virtual; abstract;
  function DeserializeValue(AValue: TAsn1Value;
    const AExisting: T): T; virtual; abstract;
end;

class procedure TAsn1Serializer.RegisterTypeSerializer<T>(
  ASerializerClass: TAsn1ValueSerializerClass); static;
class procedure TAsn1Serializer.ResetConfiguration; static;
```

`Double`, `Single` and `Extended` are written as a binary X.690 `REAL`,
exactly. A type the unit has no mapping for is refused by name, and the
refusal message points at a type serializer: the caller knows what
their float means and says so — an `INTEGER` of scaled units, a string, a
two-component `SEQUENCE`. A member-level `[Asn1Serializer]` overrides a
registration for the type.

`Currency` needs none of this. Delphi stores it as an `Int64` of
ten-thousandths, and that is what is written, exactly.

A CHOICE is not a bag of nullable fields that happen to be mostly empty —
exactly one alternative is present and the encoding says which — so the selector
is mandatory and its value is what the encoder reads to decide what to write.
The selector field is an enumeration or an integer holding the zero-based
position of the selected alternative among the type's other fields.

`Asn1StringType` defaults to UTF8String because it is the only ASN.1 string
type that can carry an arbitrary Delphi string without loss. PrintableString
and the rest have restricted repertoires, and an out-of-repertoire character
raises rather than being substituted.

### Unit-level functions

```pascal
function Asn1RuleName(ARule: TAsn1EncodingRule): string;
function Asn1RuleOf(AFormat: TSerializationFormat): TAsn1EncodingRule;
function Asn1FormatOf(ARule: TAsn1EncodingRule): TSerializationFormat;
function Asn1TagName(ATagClass: TAsn1TagClass; ATagNumber: UInt64;
  AConstructed: Boolean): string;
function Asn1KindName(AKind: TAsn1Kind): string;
function Asn1IsStringKind(AKind: TAsn1Kind): Boolean;
```

`Asn1RuleOf` raises for a format that is not one of the three ASN.1 values.
`Asn1TagName` writes a tag the way a module would: `[0]`, `[APPLICATION 3]`,
`SEQUENCE`.

### Errors

`EAsn1Error`, with `EAsn1InputError` for the octets — a truncated value, a
length that overruns its parent, a tag this position cannot hold — and
`EAsn1InternalError` for the model or the configuration.

`EAsn1CanonicalError` descends from `EAsn1InputError` and is deliberately its
own class: "not DER" and "not ASN.1" are different diagnoses, and a caller
validating a signed structure needs to tell them apart. It carries `Rule`,
which is `'DER'` or `'CER'`, and is constructed with
`CreateFor(ARuleName, AWhat, AWhere)`. Under CER it is raised for a
definite-length constructed value and for a string segmented other than as
X.690 9.2 requires.

`EAsn1SchemaError` is a schema construct this parser does not implement, named
rather than guessed at, because mis-parsing a module silently produces an
encoder that writes the wrong octets.

---

## Convert a format that needs a schema

Seven of the twelve `TSerializationFormat` values - JSON, XML, BSON, CBOR,
MessagePack, YAML and CSV - describe documents that say what they contain;
the other five do not. A Protobuf message is (field number, wire
type, payload); an Avro datum is a sequence of values with no names at all; an
ASN.1 encoding is tags and lengths. There is nothing in any of them to read the
document *as*, so the schema is passed in:

```pascal
class function Convert(const ASource: TSerializationPayload;
  AFrom, ATo: TSerializationFormat;
  AProfile: TStructuralConversionProfile;
  AContext: TSerializationContext;
  ASecondContext: TSerializationContext = nil): TSerializationPayload; overload; static;
```

Pass two when both ends need one — Protobuf to Avro. Both ends are set first
and then each context is placed in the **role** it matches: a context for the
source format reads, one for the destination format writes. Without it the
conversion raises `ESerializationSchemaRequired` rather than guessing: a tree
of plausible field names invented from field numbers is worse than an error,
because it looks like an answer.

For the case the positional form cannot express — the **same format at both
ends**, with a different schema at each — name the roles:

```pascal
Options := TStructuralConversionOptions.FromProfile(Lossless)
             .WithSourceContext(WrittenWith)
             .WithDestinationContext(ReadInto);
Out_ := TSerialization.Convert(Src, Avro, Avro, Options);
```

`SourceContextFor(F)`, `DestinationContextFor(F)`, `AnyContextFor(F)`,
`RequireSourceContext(F, AWhat)` and `RequireDestinationContext(F, AWhat)` are
how a handler asks. One context supplied for a conversion whose two ends are
the same format is **ambiguous**, and raises
`ESerializationSchemaRequired.CreateAmbiguousRole` rather than picking a role.

The context is **borrowed** everywhere in this library. It is expensive to
parse and meant to be reused, so nothing frees one — not a descriptor set, not
an Avro schema, not an ASN.1 module; the caller owns it for as long as the
conversions that reference it.

```pascal
TSerializationContext = class
public
  function Format: TSerializationFormat; virtual; abstract;
  function Describe: string; virtual;
end;

TSerializationSchema = class(TSerializationContext)
end;
```

The base class is empty on purpose. A Protobuf descriptor set *and a message
name*, an Avro writer schema *and optionally a reader schema*, an ASN.1 module
*and a root type*, and a CSV column list have nothing in common beyond being
the thing their format needs, and inventing a shared vocabulary for them from
one example would have been inventing it. The core knows only that the caller
supplied something and which format it belongs to, which is exactly enough to
route it and to refuse it when it is for the wrong one.
`ESerializationSchemaRequired` carries `Format` and has three constructors:
`CreateFor(AFormat, AWhat)`, `CreateMismatch(AExpected, AActual)` and
`CreateAmbiguousRole(AFormat)`.

`TSerializationSchema` remains as a descendant, because a bare schema *is* a
context for a format that needs nothing else — `TCsvSchema` and `TAvroSchema`
are both still schemas.

Which formats can be converted structurally depends on what the caller holds,
so there are two ways to ask:

```pascal
for F in TSerialization.StructuralFormats do ...             // with nothing
for F in TSerialization.StructuralFormats(Options) do ...    // holding these contexts

Word := TSerialization.StructuralRequirement(F);   // 'yes', 'schema' or 'no'
```

### The schema types, one per format

| Format | Schema class | Unit |
| --- | --- | --- |
| Protobuf | `TProtobufSchema`, under `TProtobufDescriptorSchema` | `PascalForge.Protobuf.Schema` |
| Avro | `TAvroSchema` | `PascalForge.Avro.Schema` |
| ASN.1 | `TAsn1Schema` | `PascalForge.Asn1.Schema` |
| CSV | `TCsvSchema` | `PascalForge.Csv` |

### `TProtobufSchema` — protoc's own descriptor

```pascal
class function LoadDescriptorSet(const AData: TBytes): TProtobufSchema; overload; static;
class function LoadDescriptorSet(const AData: TBytes;
  const AMessageName: string): TProtobufSchema; overload; static;

function MessageNames: TArray<string>;
function FindMessage(const AFullName: string): TProtoMessageDescriptor;
function FindEnum(const AFullName: string): TProtoEnumDescriptor;
function RequireMessage(const AFullName: string): TProtoMessageDescriptor;

property MessageName: string read FMessageName write SetMessageName;
function RootMessage: TProtoMessageDescriptor;

function TryFieldScalar(ANumber: Integer;
  out AScalar: TProtoScalar): Boolean; override;

function ToDynamic(const AData: TBytes): TDynamicValue; overload;
function ToDynamic(const AData: TBytes;
  const AMessageName: string): TDynamicValue; overload;
function FromDynamic(AValue: TDynamicValue): TBytes; overload;
function FromDynamic(AValue: TDynamicValue;
  const AMessageName: string): TBytes; overload;
```

The bytes come from `protoc --descriptor_set_out=x.desc --include_imports`.
`MessageName` says which message a run of octets is, because a protobuf
document does not; leaving it empty works only when the set declares exactly
one message that is not a map entry. See
[`protobuf-descriptors.md`](protobuf-descriptors.md).

### Telling a caller which of three things went wrong

```pascal
{ TSerializationFormatHandler }
procedure RaiseUnsupported(ACapability: TSerializationFormatCapability;
  AFormat: TSerializationFormat;
  const AOptions: TStructuralConversionOptions); virtual;
```

`TSerializationFormats.Require` calls this when a capability is missing, so
the handler that said no can say why. The default raises
`ESerializationFormatCapability`. Protobuf, Avro and the three ASN.1 handlers
override it and raise `ESerializationSchemaRequired` instead, because "this
format cannot do that" would be false of the format and would send the caller
the wrong way.

---

## Serialize a DataSet, in any format

```pascal
uses PascalForge.DataSet, PascalForge.Xml.Registration;

TXmlSerializationRegistration.RegisterFormat;   // the format is chosen by value
Payload := TDataSetSerializer.Serialize(DataSet,
             TSerializationFormat.Xml,
             TDataSetSerializationPolicy.StructureAndRows);

Value := TDataSetSerializer.ToDynamic(DataSet,
           TDataSetSerializationPolicy.RowsOnly);   // to inspect or change before encoding
```

The format and the policy are independent arguments. There is no
format-specific policy type.

| `TDataSetSerializationPolicy` | document content | reading it back needs |
| --- | --- | --- |
| `RowsOnly` | the rows array alone | a schema from somewhere else |
| `StructureAndRows` | `fields` + `rows` | nothing — the exact round trip |
| `DeltaOnly` | the change journal | an existing schema |
| `DeltaAndStructure` | `Fields` + `Delta` | nothing |

## Read a document into a DataSet

An existing DataSet, open or closed, is rebuilt by the document - with a
format context or without. For a populated `TFDMemTable` or
`TClientDataSet`, the complete projection is first pre-validated on a
temporary instance, so a schema, value or projection failure the library
can detect does not destroy the existing DataSet; application callbacks or
destination-specific behaviour during the final application may still raise
after rebuilding has begun. See [`dataset-formats.md`](dataset-formats.md).

```pascal
TDataSetSerializer.Deserialize(Source, TSerializationFormat.Json, DataSet,
  TDataSetSourceMode.Auto);

DataSet := TDataSetSerializer.CreateFDMemTable(Source,
             TSerializationFormat.Json, TDataSetSourceMode.Auto);
DataSet := TDataSetSerializer.CreateClientDataSet(Source,
             TSerializationFormat.Bson, TDataSetSourceMode.EmbeddedStructure);
```

| `TDataSetSourceMode` | where the schema comes from |
| --- | --- |
| `Auto` *(default)* | the document, if it describes its own columns; inference if it plainly does not; an error if it claims to and the claim does not check out |
| `InferStructure` | always from the data, whatever the document contains |
| `EmbeddedStructure` | always from the document; an error when there is none |

When the caller already knows the shape — because they asked for it with that
policy — they say so instead:

```pascal
TDataSetSerializer.DeserializeAs(Source, TSerializationFormat.Json, DataSet,
  TDataSetSerializationPolicy.RowsOnly);
```

That is the form for a rows-only document, which is indistinguishable from an
ordinary array of objects, and for replaying a change list.

The same three readings take a dynamic value - built by hand, or read from
any format - with the interpretation always said explicitly, and a
contract-aware form where a DTO decides the columns:

```pascal
TDataSetSerializer.FromDynamic(Value, DataSet, TDataSetSourceMode.Auto);
TDataSetSerializer.FromDynamic(Value, DataSet, TDataSetSerializationPolicy.RowsOnly);
TDataSetSerializer.FromDynamic<TOrder>(Value, DataSet);   // one row per array item
```

## Ask what a document is

```pascal
Match := TDataSetSerializer.ClassifySource(Source, TSerializationFormat.Json);
Why   := TDataSetSerializer.ExplainSource(Source, TSerializationFormat.Json);

TDataSetSerializer.ReadFieldDefs(Source, TSerializationFormat.Json,
  Target.FieldDefs);
```

`TDataSetMetadataMatch` is `NotMetadata`, `ValidMetadata` or
`InvalidMetadata`. The question is answered on the dynamic structural tree by
**shape alone** — no marker, no namespace, no signature — so a table
description written by other tooling is recognized. `Explain` returns the one
sentence behind the verdict, for an error message or a user interface.

`TDataSetEmbeddedStructureDetector` is the same three calls against a tree the
caller already has.

## Configure DataSet members inside an object graph

A `TDataSet`-typed **member** of a Delphi type is JSON's business, because it
needs JSON's serializer registration and member context.
`TDataSetJsonIntegration` is declared in the unit
`PascalForge.DataSet.Json` (runtime package
`PascalForge.Serialization.DataSet`); import it with
`uses PascalForge.DataSet.Json;`, and call
`TDataSetJsonIntegration.Register` once at startup.

```pascal
uses PascalForge.DataSet.Json;

TDataSetJsonIntegration.Register;           // explicit, once, at startup
TDataSetJsonIntegration.SetDefaultPolicy(
  TDataSetSerializationPolicy.StructureAndRows);
TDataSetJsonIntegration.RegisterTypePolicy<TFDMemTable>(
  TDataSetSerializationPolicy.RowsOnly);
TDataSetJsonIntegration.RegisterFieldPolicy<TPackage>('AuditDataSet',
  TDataSetSerializationPolicy.DeltaOnly);

// how a nil TDataSet member is constructed
TDataSetJsonIntegration.DataSetFactory :=
  function(ADeclaredClass: TClass): TDataSet
  begin
    Result := TFDMemTable.Create(nil);
  end;
```

Resolution: member policy, then DataSet class policy (walking ancestors), then
the default. The same `TDataSetSerializationPolicy` as above. The factory and
the policies are configuration: set them at startup; once JSON or DataSet
configuration has frozen, or the integration has been used, they raise.


## Serialize a DataSet inside an object graph

```pascal
uses PascalForge.DataSet.Json;              // TDataSetJsonIntegration.Register at startup

type
  TReport = class
  public
    Name: string;
    Rows: TFDMemTable;      // participates in ordinary JSON plans
  end;
```

## Project a DTO onto a DataSet

```pascal
uses PascalForge.DataSet;

TDataSetSerializer.CreateStructure<TCustomer>(MemTable);
TDataSetSerializer.Fill<TCustomer>(Customer, MemTable);
TDataSetSerializer.Fill<TCustomer>(CustomerArray, MemTable);
```

Nested objects become prefixed columns; nested lists and dictionaries become
`ftDataSet` columns. Customise with `DataSetName`, `DataSetField`,
`DataSetHandler`, `DataSetIgnore` attributes, or:

```pascal
TDataSetSerializer.RegisterFieldOverride<TCustomer>('Name',
  TDataSetFieldOverride.WithType(ftWideString, 120));
TDataSetSerializer.RegisterChildFieldOverride(TCustomer, 'Address', 'City',
  TDataSetFieldOverride.Rename('CITY'));
TDataSetSerializer.DefaultStringSize := 255;   // before FreezeConfiguration
```

To write a member yourself, write a handler against its Delphi type. No
`TValue`:

```pascal
type
  TCurrencyDataSetHandler = class(TCustomDataSetFieldHandler<Currency>)
  public
    function FieldType: TFieldType; override;
    procedure WriteValue(const AValue: Currency; AField: TField); override;
  end;

function TCurrencyDataSetHandler.FieldType: TFieldType;
begin
  Result := ftCurrency;
end;

procedure TCurrencyDataSetHandler.WriteValue(const AValue: Currency;
  AField: TField);
begin
  AField.AsCurrency := AValue;
end;

// one member of one DTO, compiler-checked
TDataSetSerializer.RegisterFieldOverride<TPriceRow>('Net',
  TDataSetFieldOverride.WriteWith<Currency, TCurrencyDataSetHandler>);

// or everything of that type, everywhere
TDataSetSerializer.RegisterTypeHandler<Currency, TCurrencyDataSetHandler>;
```

Override `FieldSize` as well whenever `FieldType` needs one — `ftString`,
`ftWideString`, `ftBytes`. The base returns 0, which is a zero-length field.

A handler small enough not to deserve a class can be a field type and one
procedure:

```pascal
TDataSetSerializer.RegisterFieldOverride<TPriceRow>('Fee',
  TDataSetFieldOverride.WriteWith<Currency>(ftCurrency,
    procedure(const AValue: Currency; AField: TField)
    begin
      AField.AsCurrency := AValue * 2;
    end));

TDataSetSerializer.RegisterFieldOverride<TPriceRow>('Sku',
  TDataSetFieldOverride.WriteWith<string>(ftString, 34,
    procedure(const AValue: string; AField: TField)
    begin
      AField.AsString := AValue.ToUpper;
    end));

TDataSetSerializer.RegisterTypeHandler<TMoney>(ftBCD,
  procedure(const AValue: TMoney; AField: TField)
  begin
    AField.AsCurrency := AValue.Amount;
  end);
```

The same rules as JSON delegates apply: the handler is built once at
registration and reused for every row, it is called concurrently without a
lock, and the registration respects the configuration freeze.

When one member should become **several** columns, write a type serializer
instead — it declares the fields and then writes them:

```pascal
type
  TPeriodTypeSerializer = class(TCustomDataSetTypeSerializer<TPeriod>)
  public
    procedure AddFields(AFieldDefs: TFieldDefs;
      const APrefix: string); override;
    procedure WriteValue(const AValue: TPeriod; ADataSet: TDataSet;
      const APrefix: string); override;
  end;

procedure TPeriodTypeSerializer.AddFields(AFieldDefs: TFieldDefs;
  const APrefix: string);
begin
  AFieldDefs.Add(APrefix + 'From', ftDate);
  AFieldDefs.Add(APrefix + 'To', ftDate);
end;

procedure TPeriodTypeSerializer.WriteValue(const AValue: TPeriod;
  ADataSet: TDataSet; const APrefix: string);
begin
  ADataSet.FieldByName(APrefix + 'From').AsDateTime := AValue.FromDay;
  ADataSet.FieldByName(APrefix + 'To').AsDateTime := AValue.ToDay;
end;

TDataSetSerializer.RegisterTypeSerializer<TPeriod, TPeriodTypeSerializer>;
```

`APrefix` is the composed name stem for the member (`'Validity.'`); append the
part name to it in both methods, identically.

**Advanced / infrastructure.** The untyped `TCustomDataSetFieldHandler` and
`TCustomDataSetTypeSerializer`, and the `PTypeInfo` registration overloads
(`RegisterTypeHandler(TypeInfo(TMoney), ...)`), remain available and unchanged
for a handler that deliberately covers several runtime types.

## Infer a DataSet schema from a schema-less document

```pascal
if not TDataSetSchemaInference.InferSchemaInto(Rows, DataSet) then
  ; // no schema could be inferred - decide what that means for your format

TDataSetSchemaInference.InferFieldType(Rows, 'amount', FieldType, Size);
TDataSetSchemaInference.InferSchema(Rows, DataSet.FieldDefs);
TDataSetSchemaInference.Project(Root, DataSet);
```

These take the **dynamic structural tree**, not a format's DOM, so JSON, XML
and BSON get the same widening, the same nesting and the same root-shape
rules from one implementation. There is no per-format copy of this.

Widens across every non-null value in a column
(`Integer + Largeint -> Largeint`, `… + Float -> Float`, mixed kinds ->
`ftWideString` sized to the longest value), never invents a placeholder
field, and uses only what the source format **states**: a JSON string stays
`ftWideString` however much it looks like a date. It is lossy; see
[`limitations.md`](limitations.md).

Reading through `TDataSetSerializer` calls this for you, under
`TDataSetSourceMode.Auto` when the document describes nothing, and always
under `InferStructure`.

## Build a DataSet from any registered format

```pascal
// the document decides the schema - no Delphi contract involved
DS  := TDataSetSerializer.CreateFDMemTable(Source, TSerializationFormat.Json);
CDS := TDataSetSerializer.CreateClientDataSet(Source, TSerializationFormat.Xml);
DS  := TDataSetSerializer.CreateFDMemTable(Bytes, TSerializationFormat.Bson);

// with a contract, which is a different operation and a different schema
DS  := TDataSetSerializer.CreateFDMemTable<TShipment>(Source,
         TSerializationFormat.Json);
```

`string`, `TBytes`, `TSerializationPayload` and an optional `AOwner` for each.
There is no overload per format: the format is a value, so a format pack
registered later works with no change here.

```pascal
for F in TSerialization.StructuralFormats do
  DS := TDataSetSerializer.CreateFDMemTable(SourceFor(F), F);
```

Column names come from the source unchanged — `$type` stays `$type` — because
DataSet naming is DataSet's and not XML's. The shared inference reads the
dynamic tree, so every format gets the same widening and the same nesting, and
nothing is guessed from the spelling of a string. See
[`dataset-projection.md`](dataset-projection.md).

## Write a custom DataSet packet serializer

```pascal
uses PascalForge.DataSet.Json;

type
  TMyPacketSerializer = class(TCustomDataSetJsonSerializer)
  protected
    function DataSetToJson(ADataSet: TDataSet;
      const AContext: TJsonSerializerContext): TJSONValue; override;
    procedure JsonToDataSet(const AJson: TJSONValue; ADataSet: TDataSet;
      const AContext: TJsonSerializerContext); override;
  end;

TJsonSerializer.RegisterUnitClassTypeSerializer('MyApp.Models',
  TDataSet, TMyPacketSerializer);
```

The base class supplies the value/context/existing-instance plumbing, so a
subclass implements only those two methods. `tools\DeepModelPacket` is the
worked example.

---

## Exceptions

| Type | Raised by |
| --- | --- |
| `EJsonError` | everything in `PascalForge.Json` and `PascalForge.DataSet.Json` |
| `EJsonInputError` | an `EJsonError` descendant, raised only where the failure is caused by the INPUT: a wrong JSON shape, an unknown enum or set value, a scalar or field value that will not convert |
| `EJsonInternalError` | an `EJsonError` descendant marking a foreign failure - a constructor, a custom serializer, a runtime error - that was wrapped to add member context |
| `EJsonSerializationLimitExceeded` | an `EJsonError` descendant raised only when a caller set `MaxOutputBytes` and the operation passed it. Not a defect and not a statement about the value: the caller asked to be protected from an unbounded graph and that protection fired. Carries `Limit`, `Estimated` and `Path` |
| `EDataSetSerializationError` | `PascalForge.DataSet` |

Messages name the declaring type, the member, its Delphi type, and the
expected versus actual JSON shape. Raw RTL exceptions from scalar conversion
(`EInvalidCast`, `EConvertError`) are wrapped with that context and the
original message preserved. Exceptions raised by *your* custom serializer are
not wrapped beyond adding the member path.

`EJsonInputError` and `EJsonInternalError` both descend from `EJsonError`, so
`except on E: EJsonError` catches everything it caught before and every
message is unchanged. They exist so `TryDeserialize` can tell an input problem
from a serializer or application fault — a distinction the exception class
alone could not carry, because the member wrapper turns every failure into an
`EJsonError` to add context.

Both new classes descend from `EJsonError`, so `except on E: EJsonError` keeps
catching everything it caught before and every message is unchanged. They
exist so that `TryDeserialize` can tell an input problem from a serializer or
application fault - a distinction the exception class alone could not carry,
because the member wrapper turns every failure into an `EJsonError` for
context.

---

## Infrastructure - not a developer API

Documented so nobody mistakes it for supported API. Do not construct,
mutate or retain any of it.

**In the `*.Internal` units** (`PascalForge.Json.Internal`,
`PascalForge.DataSet.Internal`) - implementation units an application
does not use:

| Item | What it is |
| --- | --- |
| `TJsonTypePlan`, `TJsonFieldPlan`, `TJsonMemberPlan`, `TJsonKind`, `TJsonDictAccess`, `TJsonMemberIndex` | the JSON engine's cached plans; `PascalForge.DataSet.Json` reads some of them |
| `TDataSetTypePlan`, `TDataSetFieldPlan`, `TDataSetMemberPlan`, `TDsKind` | the DataSet engine's plans, likewise |
| `ConvertMember`, `ConvertScalarByType`, `ConvertListElement`, `ConvertDictKey`, `ConvertDictValue`, `SerializeTypedValue`, `DeserializeTypedValue`, `TryGetFieldJsonName`, `CreateInstance` | the bridge `PascalForge.DataSet.Json` uses to reuse JSON plan decisions |
| `WriteTypedValue`, `WriteFieldValue`, `WriteMemberValue`, `AddTypeProjection`, `WriteTypeProjection` | the DataSet engine's own bridge |
| `PlansBuilt`, `SingletonsCreated`, `TJsonPopulateProfile`, `ResetPopulateProfile`, `GetPopulateProfile` | diagnostics; the focused tests assert on `PlansBuilt` to prove the plan cache is reused. `PASCALFORGE_POPULATE_PROFILE=1` enables the counters and affects measurement only, never semantics |

**In the public facades' interface** (`PascalForge.Json`,
`PascalForge.DataSet`) only because a generic method declared there may
reference interface-declared symbols alone (E2506):

| Item | Why it is there |
| --- | --- |
| `SerializeBuiltIn`, `DeserializeBuiltIn`, `TypeNameOf<T>`, `ValueAsTyped<T>`, `AdoptSerializer`, `TDataSetSerializer.ValueAsTyped<T>`, `AdoptHandler`, `TDataSetSerializer.PlanFor` | what the typed extension layer is built out of: the built-in encoding for a type, the naming used in its diagnostics, and framework ownership of a delegate adapter |
| `TJsonDelegateSerializer<T>`, `TDataSetDelegateHandler<T>` | the adapters behind every delegate registration; construct them through `SerializeWith<T>` / `WriteWith<T>` |

### No polymorphic discriminator

JSON reads no type discriminator: a nil member is always constructed as its
declared class (or by its `RegisterClassFactory` factory). Use a custom
serializer for polymorphic construction.
