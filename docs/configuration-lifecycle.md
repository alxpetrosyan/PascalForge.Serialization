# Configuration lifecycle

An application goes through the same five steps whatever formats it uses:

```text
1. register formats           (only for run-time format choice)
2. configure serializers      (attributes need nothing; registrations go here)
3. optional FreezeConfiguration
4. steady state: serialize and deserialize, concurrently
5. shutdown: unregister formats
```

Steps 1 and 2 are **two different kinds of registration**, and they are
easy to confuse:

| | format registration | serializer configuration |
| --- | --- | --- |
| what it does | puts a format in the `TSerialization` registry | tells one engine how to handle a type |
| examples | `TJsonSerializationRegistration.RegisterFormat`, `TSerializationFormatsRegistration.RegisterAll` | `TJsonSerializer.RegisterTypeSerializer<T>`, `RegisterEnumMapping<T>`, `RegisterFieldOverride<T>`, date policies |
| needed by | `TSerialization`, `Convert`, format-taking `TDataSetSerializer` overloads | whatever the configuration is about |
| not needed by | the direct serializers - `TJsonSerializer.Serialize<T>` and its siblings | - |
| when | startup, and shutdown | startup, before the first use of that serializer |

## 1. Register formats - explicitly

```pascal
uses
  PascalForge.Serialization,
  PascalForge.Json.Registration,
  PascalForge.Xml.Registration;

begin
  TJsonSerializationRegistration.RegisterFormat;
  TXmlSerializationRegistration.RegisterFormat;
  ...
  Payload := TSerialization.Serialize<TCustomer>(Customer, TSerializationFormat.Xml);
```

or every format at once:

```pascal
uses
  PascalForge.Serialization.AllFormats;

begin
  TSerializationFormatsRegistration.RegisterAll;
```

**Nothing registers a format for you.** Naming a registration unit - or
`PascalForge.Serialization.AllFormats` - in a uses clause registers nothing,
and loading a format's runtime package registers nothing. No unit of the
library registers from its `initialization` section; `tests\FormatRegistry`
fails if one ever does.

The calls are deterministic:

| call | behaviour |
| --- | --- |
| `RegisterFormat` twice | the second is a no-op |
| `RegisterFormat` when a different handler holds the format | raises `ESerializationFormatConflict` |
| `UnregisterFormat` when not registered | a no-op; it never removes another unit's handler |
| `RegisterAll`, `UnregisterAll` twice | idempotent, like the calls they make |
| `IsRegistered` | whether this unit's handler holds the format |

`TAsn1SerializationRegistration.RegisterFormat` registers all three ASN.1
encodings - `Asn1Ber`, `Asn1Der`, `Asn1Cer` - as one operation.

A format nobody registered raises `ESerializationFormatNotRegistered`, and
the message names the call to make.

**The registry is mutated at startup and shutdown only.** `TSerialization`
uses the handler it looked up after the registry's lock is released, so
unregistering a format while another thread serializes through it is not
safe. Reading the registry concurrently is.

## 2. Configure serializers

Attributes on a type need no configuration at all. Registrations - type
serializers, field overrides, enum mappings, date policies, factories, the
DataSet default string size - are made at startup, before the serializer is
first used:

```pascal
TJsonSerializer.RegisterTypeSerializer<TMoney, TMoneyJsonSerializer>;
TJsonSerializer.RegisterEnumMapping<TStatus>(['draft', 'active', 'closed']);
TCborSerializer.RegisterDateTimeRepresentation<TOrder>(
  TCborDateTimeRepresentation.UnixMilliseconds);
```

DataSet members inside JSON documents are enabled here too, explicitly:

```pascal
TDataSetJsonIntegration.Register;
TDataSetJsonIntegration.SetDefaultPolicy(TDataSetSerializationPolicy.StructureAndRows);
```

## 3. Freeze - automatically, or when you choose

**The first real operation of a serializer freezes its configuration.** The
first plan built or configuration looked up is the point after which a
registration would be silently ignored - the plan already holds the old
decision - so it is refused instead:

```pascal
Json := TJsonSerializer.Serialize<TCustomer>(Customer);    // freezes JSON
TJsonSerializer.RegisterTypeSerializer<TMoney, TMoneySerializer>;
// raises: JSON serializer configuration is frozen
```

Each serializer freezes independently: using JSON does not freeze XML. The
DataSet serializer freezes at its first projection. The DataSet-in-JSON
factory and policies freeze when JSON or DataSet configuration freezes, or
when the integration first resolves a policy.

`FreezeConfiguration` - on every serializer facade - freezes earlier, at a
point the application chooses, for example at the end of startup code, so a
late registration anywhere fails at a predictable place. `IsFrozen` reports
it.

Per-operation options - `TJsonSerializationOptions`, `TCsvOptions`, encode
options passed to a call - are arguments, not configuration, and are never
frozen.

## 4. Steady state

Once frozen, configuration and plans are immutable. Serializer instances,
format handlers and plans are shared across threads and hold no
per-operation state, so any number of threads may serialize and deserialize
concurrently. `tests\Robustness` races eight threads into a cold type in
every format, and `tests\Lifecycle` checks the freeze of every serializer
after its first real use.

## 5. Shutdown

```pascal
TSerializationFormatsRegistration.UnregisterAll;
```

Optional: a registration unit's `finalization` removes its own handler if it
is still registered, and so does unloading its package. Unregistering must
not overlap serialization through the registry.

## Tests only

`ResetConfiguration`, on the facades that have one, clears the registrations
and unfreezes the serializer. It exists for tests; an application has no
reason to call it.
