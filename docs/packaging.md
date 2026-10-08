# Packaging

The library can be consumed as source units or as runtime packages. Both give
the same behaviour, and in both **format registration is an explicit
application decision**: loading a PascalForge package does not register a
format.

## Source units

Put `src\` on the unit search path and name the units you use:

```pascal
uses
  PascalForge.Json;                       // direct use: nothing else needed

Json := TJsonSerializer.Serialize<TCustomer>(Customer);
```

A format is linked only when a unit of it is named, so an application that
never names BSON links no BSON. For run-time format choice, add the format's
registration unit and register it at startup:

```pascal
uses
  PascalForge.Serialization,
  PascalForge.Json.Registration;

TJsonSerializationRegistration.RegisterFormat;
Payload := TSerialization.Serialize<TCustomer>(Customer, TSerializationFormat.Json);
```

Dynamic and the general attributes need nothing beyond the core:

```pascal
uses
  PascalForge.Dynamic,                    // TDynamicObject, TDynamicSerializer
  PascalForge.Serialization.Attributes;   // [SerializationName] and the rest
```

They are part of the core, beside the shared metadata every format builds
on, and in the Runtime package with it.

## Runtime packages

There is one set of package projects per Delphi version, as JVCL and most
Delphi libraries ship them:

| Delphi | folder | group project | BPL suffix |
| --- | --- | --- | --- |
| 12 Athens | `projects\Delphi12` | `PascalForge.Serialization.Delphi12.groupproj` | `290` |
| 11 Alexandria | `projects\Delphi11` | `PascalForge.Serialization.Delphi11.groupproj` | `280` |

The packages use `{$LIBSUFFIX AUTO}`, so a BPL is named after the compiler -
`PascalForge.Serialization.Runtime290.bpl` for Delphi 12,
`PascalForge.Serialization.Runtime280.bpl` for Delphi 11 - and both can be
installed on one machine. The DCP keeps the plain name, so a project's
*Runtime packages* list says `PascalForge.Serialization.Runtime` whichever
version builds it. Each version builds two packages, Win32 and Win64, into
`artifacts\packages\Delphi<version>\<Platform>\<Config>`:

| package | contains | requires |
| --- | --- | --- |
| `PascalForge.Serialization.Runtime` | the core (`PascalForge.Serialization.Core`, `.Serialization.Attributes`, the internal `.Serialization.Internal`, `PascalForge.Dynamic`, `.Dynamic.Internal`, `PascalForge.Nullable`, `PascalForge.Serialization`); every format - `PascalForge.<Format>`, `.Internal`, `.Registration` (and `.Schema` for Protobuf, Avro and ASN.1) for JSON, XML, BSON, Protobuf, CBOR, MessagePack, YAML, CSV, Avro and ASN.1; `PascalForge.Serialization.AllFormats` | `rtl` |
| `PascalForge.Serialization.DataSet` | `PascalForge.DataSet`, `.DataSet.Internal`, `.DataSet.Packet`, `.DataSet.Json` | `rtl`, `dbrtl`, `dsnap`, `FireDAC`, `FireDACCommonDriver`, `PascalForge.Serialization.Runtime` |

Notes:

- **Why two, not one.** The DataSet projection needs `Data.DB`, FireDAC and
  DataSnap; nothing else in the library does. An application that only
  serializes objects ships `PascalForge.Serialization.Runtime`, which
  requires the RTL alone, and no database package. Everything else - the
  core and the ten formats - shares one dependency set, so it is one
  package.
- **Why the formats are not separate packages.** A format package bought
  nothing a deployment could use: every format requires only the RTL and the
  core, and registration is explicit either way. One Runtime package is one
  thing to deploy and one thing to version.
- **The package is the unit of deployment, not of design.** In source the
  formats are still separate units with no dependency on one another; a
  program compiled from source links only the formats it names
  (`scripts\check-format-isolation.ps1`).
- **A package is never named after a unit it contains.** The package is
  `PascalForge.Serialization.Runtime` because it contains the unit
  `PascalForge.Serialization`: on Win64 an application that links a package
  and uses the unit of the same name dies at startup with runtime error 217.
  `scripts\check-packages.ps1` refuses the clash (`PACKAGE_NAME_UNIT_CLASH`).
- **TDataSet as JSON is in the DataSet package.** `PascalForge.DataSet.Json`
  needs JSON, which every DataSet user now has through Runtime, and the
  database packages, which only DataSet users have; a third package would
  add nothing. Its integration is still explicit:
  `TDataSetJsonIntegration.Register` at startup. The DataSet overloads that
  take a `TSerializationFormat` reach a format through the registry, so the
  format must be registered.
- The packages are runtime-only (`{$RUNONLY}`): there is nothing to install in
  the IDE.
- Win32 and Win64 are built from the same projects; `scripts\check-packages.ps1`
  builds both packages on both and checks that each produced a `.bpl` and a
  `.dcp` and no `.exe`.

## Package load is not format registration

```pascal
// PascalForge.Serialization.Runtime<suffix>.bpl is loaded: no format is registered.

TJsonSerializationRegistration.RegisterFormat;
// now TSerialization can reach TSerializationFormat.Json - and only JSON

TSerializationFormatsRegistration.RegisterAll;
// every format, explicitly
```

A package's initialization registers nothing - the registration units have no
registration in their `initialization` sections. The direct serializers
(`TJsonSerializer` and the rest) need no registration at all. Registering
the same handler twice is harmless; a different handler for a registered
format raises `ESerializationFormatConflict`. Each registration unit's
`finalization` removes its own handler if it is still registered, so the
process shuts down cleanly with formats registered. Loading the DataSet
package registers no format and does not switch on the JSON integration.

`scripts\check-packages.ps1` proves it with real packages: it builds
`tests\PackageProbe` **with runtime packages** against the packages it just
built and runs it on each platform -

```text
RUNTIME_LOAD_REGISTERS_NO_FORMAT: PASS
DIRECT_SERIALIZER_NEEDS_NO_REGISTRATION: PASS
RUNTIME_LOOKUP_SEES_ONLY_REGISTERED_FORMATS: PASS
EXPLICIT_JSON_REGISTERS_JSON_ONLY: PASS
REGISTER_JSON_TWICE_IS_HARMLESS: PASS
UNREGISTER_JSON_LEAVES_NONE: PASS
REGISTER_ALL_REGISTERS_EVERY_FORMAT (12 of 12): PASS
REGISTER_ALL_TWICE_IS_HARMLESS: PASS
UNREGISTER_ALL_LEAVES_NONE: PASS
DATASET_BPL_LOAD_REGISTERS_NO_FORMAT: PASS
DATASET_BPL_LOAD_DOES_NOT_REGISTER_JSON_INTEGRATION: PASS
DATASET_BPL_UNLOAD_LEAVES_THE_REGISTRY_EMPTY: PASS
EXIT_WITH_EVERY_FORMAT_REGISTERED: PASS
```

- requiring the process to exit with code 0 - and checks that Runtime
requires the RTL only and implicitly imports nothing, and that DataSet
requires only Runtime and the database packages (`PACKAGE_ISOLATION`).

## Format isolation

`scripts\check-format-isolation.ps1` builds a probe for every format alone,
and for chosen pairs, and fails if the linker map shows any other format.
`scripts\check-dependencies.ps1` proves a console program on Core and JSON
links no VCL, FMX, FireDAC or `Data.DB`.

## Build output

Nothing is written beside source: every project sends binaries, DCUs, BPLs
and DCPs under `artifacts\`, which one `.gitignore` rule covers. The package
`.res` files are the deliberate exception - a `.dpk` does not compile without
one.
