# PascalForge JSON developer API map

## Common operations

```text
I WANT TO...                     USE...
----------------------------------------------------------------------------
Serialize value                  TJsonSerializer.Serialize<T>(Value)
Deserialize value                TJsonSerializer.Deserialize<T>(Json)
Deserialize, no raise            TryDeserialize<T>(Json, Value)
Deserialize, no raise + reason   TryDeserialize<T>(Json, Value, Error)
Deserialize, tolerate mismatch   TryDeserialize<T>(Json, Value, [InvalidJson, TypeMismatch])
Populate object                  TJsonSerializer.Populate(Object, Json)
Serialize root list              TJsonSerializer.Serialize<TList<T>>(List)
Serialize root dictionary        TJsonSerializer.Serialize<TDictionary<K,V>>(Map)
Custom exact type                RegisterTypeSerializer<T, TSerializer>
Custom field                     RegisterFieldOverride<TOwner>(Name, Override)
Custom DTO->DataSet field        TDataSetSerializer.RegisterFieldOverride<T>
Custom generic family            RegisterGenericTypeSerializer<TGen<X>>(Serializer)
Enum mapping                     RegisterEnumMapping<TEnum>(Values)
Member strategy                  RegisterTypeMemberStrategy<T>(Strategy)
Field member strategy            RegisterFieldOverride<TOwner>(Name, Members(...))
Recursive-reference policy       RegisterTypeRecursiveReferencePolicy<T>(Policy)
Field recursion policy           RegisterFieldOverride<TOwner>(Name, RecursiveReferences(...))
Opaque class                     RegisterOpaqueClass(ClassType)
Construction factory             RegisterClassFactory<T>(Factory)
Serialize DataSet                TDataSetSerializer.Serialize(DS, Format, Policy)
Serialize DataSet delta          Serialize(DS, Format, DeltaOnly)
Deserialize into DataSet         TDataSetSerializer.Deserialize(Src, Format, DS, Mode)
Create DataSet                   TDataSetSerializer.CreateFDMemTable(Src, Format, Mode)
Read a known shape               TDataSetSerializer.DeserializeAs(Src, Format, DS, Policy)
Nested DataSet member policy     TDataSetJsonIntegration.RegisterFieldPolicy<T>(Name, Policy)
Custom DataSet format            inherit TCustomDataSetJsonSerializer
Tolerate throwing getters        Serialize(Value, TJsonSerializationOptions)
```

All registrations must occur before the first serialization operation freezes
configuration.

There is no `TryPopulate` and no Try form for deserializing into an EXISTING
DataSet, on purpose: both mutate a target the caller already owns, so a
Boolean result would imply a transactional guarantee they cannot make. The Try
APIs exist exactly where a NEW value is produced and can be handed over only
on success - see "Deserialize without raising" in
[`api-reference.md`](api-reference.md).

## The general attributes

Three attributes say something once for every format, for Dynamic and for
the DataSet projection; a format's own attribute or registration beats them
for that format:

```pascal
uses PascalForge.Serialization.Attributes;

[SerializationName('id')]        // the name, verbatim, everywhere
[SerializationIgnore]            // in no format at all
[SerializationEnum('a,b,c')]     // an enumeration's text, on the type or a member
```

See [`attributes.md`](attributes.md) for the precedence, format by format.

## Customising one value

The question this table answers is "the library's default encoding for this
member is wrong - what do I write?". It is ordered by how much you have to
write, and the first seven rows cover almost everything.

```text
I WANT TO...                         USE...
---------------------------------------------------------------------------
Custom fixed Delphi type             TCustomJsonValueSerializer<T>
Custom one field                     SerializeWith<T>(SerializerClass)
Custom one field inline              SerializeWith<T>(Serialize, Deserialize)
Custom writing only                  SerializeWith<T>(Serialize)
Custom reading only                  DeserializeWith<T>(Deserialize)
Custom DTO->DataSet field            TCustomDataSetFieldHandler<T>
Custom DTO->DataSet field inline     WriteWith<T>(FieldType, WriteProc)
---------------------------------------------------------------------------
Dynamic runtime serializer           TCustomJsonValueSerializer
Generic family over many T           RegisterGenericTypeSerializer
```

None of the typed rows involves `TValue` or `PTypeInfo`. The last two do, and
that is what the line separates.

## Customisation, easiest first

Each entry is complete - nothing above it is a prerequisite.

**1. Rename a field**

```pascal
TJsonSerializer.RegisterFieldOverride<TOrder>('Total',
  TJsonFieldOverride.Rename('order_total'));
```

**2. Ignore a field**

```pascal
TJsonSerializer.RegisterFieldOverride<TOrder>('InternalId',
  TJsonFieldOverride.Ignore);
```

**3. Map an enum to strings**

```pascal
TJsonSerializer.RegisterEnumMapping<TStatus>(['active', 'closed']);
```

**4. A typed custom field serializer**

```pascal
type
  TPurposeSerializer = class(TCustomJsonValueSerializer<string>)
  public
    function SerializeValue(const AValue: string): TJSONValue; override;
    function DeserializeValue(const AJson: TJSONValue): string; override;
  end;

TJsonSerializer.RegisterFieldOverride<TDocument>('Purpose',
  TJsonFieldOverride.SerializeWith<string, TPurposeSerializer>);
```

`SerializeWith<T, TSer>` is checked by the compiler. `SerializeWith<T>(TSer)`
is the same thing with a bare class reference, checked at registration.

**5. A delegate custom field serializer**

For a transformation too small to deserve a class:

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
```

Named functions work identically. Either direction can stand alone -
`SerializeWith<T>(Serialize)` customises writing and leaves reading built-in,
`DeserializeWith<T>(Deserialize)` does the opposite. There is no pass-through
delegate to write, and nothing fails because the other delegate is absent.

Delegates are captured once, at registration, and called concurrently without
a lock: keep them stateless, or let them capture only immutable state.

**6. A typed exact-type serializer**

The same serializer for every member of that Delphi type:

```pascal
TJsonSerializer.RegisterTypeSerializer<TMoney, TMoneySerializer>;

// or from delegates
TJsonSerializer.RegisterTypeSerializer<TMoney>(MoneyToJson, MoneyFromJson);
```

**7. A typed DataSet field handler**

```pascal
type
  TCurrencyDataSetHandler = class(TCustomDataSetFieldHandler<Currency>)
  public
    function FieldType: TFieldType; override;
    procedure WriteValue(const AValue: Currency; AField: TField); override;
  end;

TDataSetSerializer.RegisterFieldOverride<TPriceRow>('Net',
  TDataSetFieldOverride.WriteWith<Currency, TCurrencyDataSetHandler>);
```

Override `FieldSize` as well for a field type that needs one (`ftString`,
`ftWideString`, `ftBytes`); the base returns 0, which is a zero-length field.

**8. A DataSet write delegate**

```pascal
TDataSetSerializer.RegisterFieldOverride<TPriceRow>('Sku',
  TDataSetFieldOverride.WriteWith<string>(ftString, 34,
    procedure(const AValue: string; AField: TField)
    begin
      AField.AsString := AValue.ToUpper;
    end));
```

**9. Member strategy** - which members participate at all:

```pascal
TJsonSerializer.RegisterTypeMemberStrategy<TLegacyDto>(
  TJsonMemberStrategy.FieldsOnly);
```

**10. Recursive-reference policy**

```pascal
TJsonSerializer.RegisterTypeRecursiveReferencePolicy<TNode>(
  TJsonRecursiveReferencePolicy.WriteNull);
```

**11. Construction factory** - for a class with no usable parameterless
constructor:

```pascal
TJsonSerializer.RegisterClassFactory<TService>(
  function: TObject
  begin
    Result := TService.Create(Container);
  end);
```

**12. A generic-family serializer** - one registration for every closed
`TBox<T>`. This one IS advanced: its `T` is not knowable at compile time, so
it is written against the untyped contract.

```pascal
TJsonSerializer.RegisterGenericTypeSerializer(TypeInfo(TBox<Integer>),
  TBoxSerializer);
```

**13. A class-hierarchy serializer** - a base class and its descendants:

```pascal
TJsonSerializer.RegisterClassTypeSerializer(TStreamBase, TStreamSerializer);
```

**14. A unit/context serializer** - every member of a matching value type
declared in a matching unit:

```pascal
TJsonSerializer.RegisterUnitClassTypeSerializer('MyApp.Legacy.*',
  TLegacyBase, TLegacySerializer);
```

## When do I need TValue/PTypeInfo?

Five cases, and nothing else:

- **dynamic runtime serializers** - the implementation decides from the value
  it is handed which of several Delphi types it is looking at;
- **serializers intentionally handling several Delphi types** through a single
  registration;
- **generic-family serializers** spanning many closed generic types, where the
  concrete `T` is not knowable when the serializer is written;
- **unit/context infrastructure** - registrations scoped by declaring unit or
  by class hierarchy, which by definition are not written against one type;
- **low-level bridge code** that talks to the engine's `PTypeInfo` overloads
  directly.

Everything else - and that is nearly everything - is covered by
`TCustomJsonValueSerializer<T>`, `TCustomDataSetFieldHandler<T>` and the
delegate forms. See "Register a custom serializer" in
[`api-reference.md`](api-reference.md).

## Serializing VCL components

The library has no VCL special case and registers nothing on your behalf.
That is deliberate: a serialization framework should not decide that one
class in your application is dangerous to reflect over.

If you serialize `TComponent` descendants, exclude the members whose getters
you do not want executed. The usual one is `TComponent.ComObject`:

```pascal
TJsonSerializer.RegisterClassFieldOverride(
  TComponent, 'ComObject', TJsonFieldOverride.Ignore, True);
```

`True` applies it to descendants as well. Register it at startup, with your
other configuration, before anything is serialized.

There is no DFM-compatible form persistence here, and no attempt to follow
ownership or navigation graphs.

## Property getter failures

Strict getter handling remains the default. A single serialization operation
can opt into tolerant property access:

```pascal
Options := TJsonSerializationOptions.Default;
Options.PropertyReadErrorPolicy :=
  TJsonPropertyReadErrorPolicy.SkipMember;

Json := TJsonSerializer.Serialize<TSomeFrameworkObject>(Obj, Options);
```

- `RaiseError`: strict/default; preserve the contextual getter error.
- `SkipMember`: omit only a property whose getter raises.
- `WriteNull`: emit the property's effective JSON name with a null value.

This option handles property getter failures only. It does not suppress nested
serialization, field, collection, or custom serializer errors. Options are
per call, propagate through the entire graph, and do not create policy-specific
plans.

## DataSet policies

`RowsOnly`, `StructureAndRows`, `DeltaOnly`, and `DeltaAndStructure` are the
four coherent presets. The policy has one data-mode source of truth
(`Snapshot` or `Delta`) plus `IncludeStructure` and `IncludeDataSetName`.

## Advanced APIs

Parsed `TJSONValue` APIs, `PTypeInfo` registration overloads, contextual
`TValue` serializer methods, class/unit-pattern registrations, and plan/profile
types remain available for dynamic or infrastructure code. Ordinary
application code does not need them.
