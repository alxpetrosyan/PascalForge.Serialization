# ASN.1

## Purpose

This is the entry point for the ASN.1 formats. It summarizes what they do
and where the code is. For depth, read
[`../asn1-behavior.md`](../asn1-behavior.md). The API is in
[`../api-reference.md`](../api-reference.md).

ASN.1 is a real engine. A Delphi value is written straight to BER, DER or
CER octets and read straight back. Nothing goes through JSON text, another
format, or the dynamic tree on the contract path. The natural payload type
is `TBytes`.

ASN.1 is a schema language, and an encoding is something else. The octets
are self-delimiting but not self-describing: they carry tags and lengths,
never names. So the contract path uses the Delphi type as the schema, and
the structural path needs an X.680 module.

## Standard/profile

- **ITU-T X.690**: BER (clause 8), CER (clause 9) and DER (clause 10), as
  three separate encoding rules, not one with three names.
- **ITU-T X.680** for the type model, and a declared subset of its module
  syntax (see Schema/context).
- Identifier octets in all four tag classes (`Universal`, `Application`,
  `ContextSpecific`, `Private`), and the high tag number form.
- Short, long and indefinite length forms. Primitive and constructed strings
  (UTCTime and GeneralizedTime included); BER segments are reassembled on
  read. A constructed BOOLEAN, INTEGER, ENUMERATED, REAL, NULL, OBJECT
  IDENTIFIER or RELATIVE-OID is refused under every rule (X.690).
- BOOLEAN, INTEGER of any size, BIT STRING with its unused-bit count, OCTET
  STRING, NULL, OBJECT IDENTIFIER (arcs of any size), RELATIVE-OID,
  ENUMERATED, REAL, UTF8String, NumericString, PrintableString, IA5String,
  VisibleString, BMPString, UniversalString, TeletexString, GeneralString,
  UTCTime, GeneralizedTime, SEQUENCE, SEQUENCE OF, SET, SET OF, CHOICE.
- A universal tag outside that list is kept verbatim as `TAsn1Kind.Unknown`.

| | BER | DER | CER |
| --- | --- | --- | --- |
| definite length | yes | **required**, shortest form | primitives only |
| indefinite length | yes | refused | **required** for every constructed value; a definite one is refused |
| constructed strings | yes | refused | **required** above 1000 content octets and refused at or below; fragments are primitive OCTET STRINGs (BIT STRINGs for a BIT STRING) of exactly 1000 content octets but the last |
| BOOLEAN true | any non-zero | `FF` only | `FF` only |

Not implemented: PER (X.691), OER (X.696), XER and JER, and the X.681, X.682
and X.683 information object layer, with parameterized types,
`ANY DEFINED BY` and constraint algebra.

## Public facade

Unit `PascalForge.Asn1`, class `TAsn1Serializer`. All methods are class
static. Every one takes `ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der`.
`TAsn1EncodingRule` is `Ber`, `Der` or `Cer`; DER is the default because it
is the one whose output is defined.

| Method | Signature |
| --- | --- |
| `Serialize<T>` | `(const AValue: T; ARule): TBytes` |
| `Deserialize<T>` | `(const AData: TBytes; ARule): T` |
| `Encode` | `(AValue: TAsn1Value; ARule): TBytes`; the tree is borrowed |
| `ParseTlv` | `(const AData: TBytes; ARule): TAsn1Value`; a diagnostic decode with no schema, the caller owns the result |
| `DecodeWithSchema` | `(const AData: TBytes; ASchema: TSerializationSchema; const ATypeName: string; ARule): TAsn1Value` |
| `EncodeWithSchema` | `(AValue: TAsn1Value; ASchema: TSerializationSchema; const ATypeName: string; ARule): TBytes` |
| `ToDynamic` | `(const AData: TBytes; ASchema: TSerializationSchema; const ATypeName: string; ARule): TDynamicValue` |
| `FromDynamic` | `(AValue: TDynamicValue; ASchema: TSerializationSchema; const ATypeName: string; ARule): TBytes` |
| `ToDynamic` / `FromDynamic` | `(const AData: TBytes; ASchema: TSerializationSchema; const ATypeName: string; ARule): TDynamicValue` / `(AValue: TDynamicValue; ASchema; const ATypeName: string; ARule): TBytes`; the module is required - see [`../dynamic.md`](../dynamic.md) |

`[SerializationName]` names a component (structural conversion and diagnostics; the encoding is positional) and `[SerializationIgnore]` removes it; `[Asn1Ignore]` removes it from ASN.1 alone. `[SerializationEnum]` does not apply: `ENUMERATED` is a number. See [`../attributes.md`](../attributes.md).

There is no `Populate`, no `TryDeserialize` and no `From`. A structural
conversion goes through `ToDynamic` / `FromDynamic` or `TSerialization.Convert`
with a module (see Schema/context). `ParseTlv` is not structural parsing: its
nodes have no names, and it cannot tell a SEQUENCE from a SEQUENCE OF.

Unit functions: `Asn1RuleName`, `Asn1RuleOf` (raises for a format that is
not one of the three), `Asn1FormatOf`, `Asn1TagName`, `Asn1KindName`,
`Asn1IsStringKind`.

Configuration (call at startup):

- `RegisterTypeSerializer<T>(ASerializerClass: TAsn1ValueSerializerClass)`
- `FreezeConfiguration`, `IsFrozen`, `ResetConfiguration` (tests only)

Configuration freezes automatically at the first real serializer operation
(`Serialize`, `Deserialize`, or the registry's typed calls). After that,
configuration is immutable and concurrent use is safe. A registration made
after the freeze raises `EAsn1InternalError` saying the configuration is
frozen. `FreezeConfiguration` freezes earlier, and `IsFrozen` reports the
state. See [`../configuration-lifecycle.md`](../configuration-lifecycle.md)
for the full lifecycle.

Exceptions: `EAsn1Error`, `EAsn1InputError` (the octets are at fault),
`EAsn1CanonicalError` (an `EAsn1InputError`: valid BER that breaks the DER or
CER rules; `Rule` is `'DER'` or `'CER'`), `EAsn1InternalError` (model or
configuration) and `EAsn1SchemaError` (a module construct outside the
subset, or a type name the module does not declare).

## Explicit registry registration

```pascal
uses
  PascalForge.Asn1.Registration;
...
TAsn1SerializationRegistration.RegisterFormat;
```

- One call registers **all three** `TSerializationFormat` values, `Asn1Ber`,
  `Asn1Der` and `Asn1Cer`, as one operation. They share one handler class
  and differ only in the rule it carries.
- Linking or importing `PascalForge.Asn1.Registration` does **not** register
  the formats.
- Loading the `PascalForge.Serialization.Runtime` package does
  **not** register them.
- `RegisterFormat` is idempotent. It raises `ESerializationFormatConflict`
  if a different handler already holds one of the three values.
- `UnregisterFormat` removes all three, is safe when they are absent, and
  never removes another unit's handler.
- `IsRegistered` reports whether this unit's handlers hold all three.

Direct `TAsn1Serializer` use needs no registration, and neither does parsing
a module with `TAsn1Schema`. Registration is needed only for `TSerialization`
(format chosen at run time), `TSerialization.Convert`, and the
`TDataSetSerializer` overloads that take a `TSerializationFormat`.

All formats at once: `TSerializationFormatsRegistration.RegisterAll` in unit
`PascalForge.Serialization.AllFormats`. It is also explicit.

Registry mutation happens at startup and shutdown. It must not run
concurrently with serialization.

## Native Delphi mappings

A record or class is a SEQUENCE, and its members are the components in
declaration order.

| Delphi | ASN.1, by default |
| --- | --- |
| `Boolean` | BOOLEAN |
| integers of every width, `Comp` | INTEGER |
| `UInt64` above `High(Int64)` | INTEGER, the positive value it is |
| `Currency` | INTEGER, the scaled `Int64` Delphi stores |
| `Single`, `Double`, `Extended` | REAL, binary, base 2 |
| `string`, `Char` | UTF8String, unless `[Asn1StringType]` says otherwise |
| `TBytes` | OCTET STRING |
| `TGUID` | OCTET STRING, 16 octets, `D1`..`D3` big-endian |
| `TDateTime`, `TDate`, `TTime` | GeneralizedTime |
| enumeration | ENUMERATED |
| set | SET OF ENUMERATED |
| class, record | SEQUENCE |
| list, dynamic or static array | SEQUENCE OF |
| dictionary | SEQUENCE OF two-component SEQUENCE (key, value); X.680 has no map |
| `TNullable<T>` with no value, `[Asn1Optional]` member | absent, which is what OPTIONAL means |
| `TNullable<T>` with no value, otherwise; nil object | NULL |

INTEGER has no width: `TAsn1BigInt` carries sign and magnitude and converts
to X.690's two's-complement content octets exactly. A value too large for
the member is refused on read.

REAL is written in the binary form, exact in both directions, with X.690's
own special values for zero, minus zero, the infinities and NaN. The decimal
forms another encoder may write are read correctly rounded.

Member attributes: `Asn1Tag(n)` or `Asn1Tag(TagClass, n)`, `Asn1Explicit`
(the default: the tag wraps the type's own), `Asn1Implicit` (the tag replaces
it), `Asn1Optional`, `Asn1Choice('Selector')`, `Asn1StringType(TAsn1Kind)`,
`Asn1Serializer(cls)`, `Asn1Ignore`.

CHOICE is a real CHOICE. `[Asn1Choice('Which')]` goes on the member whose
type is the CHOICE record, and names that record's selector field: an
enumeration holding the zero-based position of the selected alternative
among the record's other fields. Only that alternative is
written, under its own tag or a context tag equal to its position. On read
the selector is set from the tag that arrived.

Dates and text:

- A `TDateTime` outside the years 1 to 9999 is refused on write with
  `EAsn1Error`, naming the member: GeneralizedTime has four year digits.
- GeneralizedTime is written as `YYYYMMDDHHMMSS[.fff]Z`, with no trailing
  zero in the fraction, which DER and CER require. UTCTime is read and is
  available on `TAsn1Value`; the contract path never writes it.
- A string with an unpaired UTF-16 surrogate is refused on write: as
  UTF8String with `ESerializationUnsupported`, as BMPString or
  UniversalString with `EAsn1Error`.
- The single-octet string types refuse a character outside their repertoire
  rather than substituting it. BMPString is written big-endian.

Full detail: [`../asn1-behavior.md`](../asn1-behavior.md),
[`../datetime-policies.md`](../datetime-policies.md),
[`../delphi-type-coverage.md`](../delphi-type-coverage.md).

## Structural representation

Only with a module. The three handlers declare `ContractSerialize` and
`ContractDeserialize` always, and `StructuralParse` and `StructuralWrite`
only when the conversion options hold a `TAsn1Schema` or a
`TAsn1SerializationContext`. `ToDynamic` and `FromDynamic` delegate to
`TAsn1SchemaCodec` in the engine.

| ASN.1 | `TDynamicValue` |
| --- | --- |
| INTEGER, ENUMERATED within `Int64` | `Int` |
| INTEGER beyond `Int64` | `Decimal`, the exact digits |
| REAL | `Float` |
| BOOLEAN / NULL | `Bool` / `Null` |
| OCTET STRING | `Bytes` |
| BIT STRING | `Extended`, tag `FormatTag`, object of `bits` and `unused` |
| OBJECT IDENTIFIER, RELATIVE-OID | `Str`, dotted arcs |
| the character string types | `Str` |
| UTCTime, GeneralizedTime | `DateTime` |
| SEQUENCE, SET | `Obj`, members named by the module's components |
| SEQUENCE OF, SET OF | `Arr` |
| tagged value | the value inside |
| a CHOICE resolved by the module | `Obj` of exactly one member, the alternative's name: `{"pick": {"text": "hi"}}` |
| uninterpreted tag (including a universal tag number the library does not know, of any width) | `Bytes`, the content octets; a constructed one, an `Obj` of its children |
| absent OPTIONAL or DEFAULT component | absent |

On the way back, the module decides. Components are written in the module's
order. A member the selected type does not declare is omitted by `Natural` -
the module is the destination's whole vocabulary - and refused by `Strict`
and `Lossless` with its path (`$.customer.internalCode`), under BER, DER and
CER alike: ASN.1 has no standard place for a component the module does not
name, and nothing proprietary is written to carry one. A missing
component that is neither OPTIONAL nor DEFAULT, a `null` for a type other
than NULL, and a CHOICE value that is not an object with exactly one member
naming an alternative raise `EAsn1InputError`. A `Decimal` into INTEGER is
exact, and into REAL it is parsed correctly rounded.

**A value is written only when its kind is one the type holds exactly** -
`Bool` for BOOLEAN; `Int`, `UInt` or `Decimal` for INTEGER; `Int`, `Float` or
`Decimal` for REAL; `Bytes` for OCTET STRING and BIT STRING; `Str` for an
OBJECT IDENTIFIER and the string types; `DateTime` or `Date` for the time
types; `Null` for NULL. Any other kind - a string into INTEGER, bytes into
UTF8String - is refused with `EStructuralConversionError`
(`UnsupportedValueKind`) in every profile, never written as zero or empty.

**CHOICE round-trips structurally** under BER, DER and CER: JSON -> ASN.1 ->
JSON -> ASN.1 gives identical octets for a CHOICE component, an inline
CHOICE, untagged alternatives and a CHOICE at the root
(`ASN1_CHOICE_STRUCTURAL_VERIFIED`). The alternative is matched by its exact
name first. **Limitation:** an IMPLICITLY tagged primitive component (any
component under `IMPLICIT TAGS` or `AUTOMATIC TAGS`, in a CHOICE or not)
is read back as raw `Bytes`, because the tag that replaced the universal
one is not mapped back to the schema type on read. Writing such a tree back
is refused (`UnsupportedValueKind`) rather than corrupted
(`ASN1_CHOICE_STRUCTURAL_KNOWN_LIMITATION`).

Tag numbers and lengths are full-width: a universal tag number above 30, at
any width, is an unknown tag and never aliases a known one; a tag wider than
64 bits, and a length above `High(Integer)` or beyond the remaining input,
are refused with `EAsn1InputError`.

A text payload handed to an ASN.1 handler is refused with `EAsn1InputError`.
ASN.1 reads octets only; a PEM body must be decoded to `TBytes` first.

## Lossless behavior

When ASN.1 is the destination, the module decides. There is no name to
encode, because components are positional; a member name reaches the octets
only through the module. `Natural`, `Lossless` and `Strict` produce the same
octets for a tree whose members the module all declares; a member it does
not declare is omitted by `Natural` and refused by the other two.

When ASN.1 is the source, the dynamic tree carries what the module names.
A BIT STRING keeps its unused-bit count, and an INTEGER of any size is
exact. `Lossless` then depends on the destination. See
[`../conversion.md`](../conversion.md).

## Contract-aware behavior

These depend on the Delphi type `T` (`Serialize<T>`, `Deserialize<T>`,
`TSerialization.Convert<T>`, `TSerialization.Serialize<T>` with an ASN.1
format):

- component order (declaration order), `[Asn1Tag]`, `[Asn1Explicit]`,
  `[Asn1Implicit]`, `[Asn1Optional]`, `[Asn1Ignore]`;
- the string type of each member (`[Asn1StringType]`);
- CHOICE through `[Asn1Choice]` and its selector;
- `Currency` exact as INTEGER, sets as SET OF ENUMERATED, dictionaries as
  SEQUENCE OF pairs;
- range checks into the member type (`EAsn1InputError`);
- custom serializers.

On read, a record member, a `TNullable<record>` payload and a CHOICE record
are merged in place: objects already in the record are filled, and an
OPTIONAL component the document leaves out keeps the member's value.

The contract path needs no module: the Delphi type is the schema.

## Schema/context

Structural conversion needs an ASN.1 module in the conversion options.
Without one it raises `ESerializationSchemaRequired`, **not**
`ESerializationFormatCapability`: the format can do it, given the module.

```pascal
uses
  PascalForge.Asn1.Schema;

Schema := TAsn1Schema.ParseModule(ModuleText);
try
  Context := Schema.ForType('Shipment');
  try
    Json := TSerialization.Convert(Der, TSerializationFormat.Asn1Der,
              TSerializationFormat.Json,
              TStructuralConversionProfile.Natural, Context);
  finally
    Context.Free;
  end;
finally
  Schema.Free;
end;
```

- The octets do not say which assignment they are. `Schema.ForType(Name)`
  or `TAsn1SerializationContext.Create(Schema, Name, Rule)` names it per
  conversion, and raises `EAsn1SchemaError` for a name the module does not
  declare.
- A bare `TAsn1Schema` works when `RootType` is set or the module has exactly
  one assignment. Otherwise it raises `EAsn1SchemaError`, giving the count
  and naming `ForType`.
- The caller owns the schema and the context. A context borrows its schema.
- One module serves all three rules. `Rule` on the schema or context decides
  only which `TSerializationFormat` it reports.
- Contexts are routed by role: a source context to read, a destination
  context to write, so ASN.1 to ASN.1 works with two contexts.

The module parser implements a declared subset of X.680: the module header
with `EXPLICIT TAGS`, `IMPLICIT TAGS` or `AUTOMATIC TAGS`, EXPORTS, IMPORTS,
type assignments, SEQUENCE, SET, CHOICE, SEQUENCE OF and SET OF, the base
types above including REAL, named number lists, type references, tags in all
four classes, OPTIONAL and DEFAULT with scalar values, SIZE and value range
constraints with MIN and MAX, and both comment forms.

Everything else is refused by name with `EAsn1SchemaError` and the line:
ANY and ANY DEFINED BY, value assignments, parameterized types, information
object classes, COMPONENTS OF, the extension marker and version brackets,
WITH COMPONENTS, CONTAINING, compound constraints, selection types, EXTERNAL,
EMBEDDED PDV, CHARACTER STRING, ObjectDescriptor, GraphicString,
VideotexString, T61String, ISO646String and EXTENSIBILITY IMPLIED.
`TAsn1Schema.SubsetDescription` returns the list at run time.

## DataSet behavior

With a contract, `TDataSetSerializer.CreateFDMemTable<T>(Bytes,
TSerializationFormat.Asn1Der)` works like any other format. Without one,
the handler needs the module: pass it as the `ASchema` argument, for example
`CreateClientDataSet(Payload, TSerializationFormat.Asn1Der, Schema)`; with no
schema the call raises `ESerializationSchemaRequired`. The column names are
the module's component names. See
[`../dataset-formats.md`](../dataset-formats.md) and
[`../dataset-projection.md`](../dataset-projection.md).

| ASN.1, through a module | Inferred field type |
| --- | --- |
| INTEGER, ENUMERATED within 32 bits | `ftInteger` |
| wider INTEGER within `Int64` | `ftLargeint` |
| INTEGER beyond `Int64`, REAL | `ftFloat` |
| UTCTime, GeneralizedTime | `ftDateTime` |
| OCTET STRING | `ftBlob` |
| BOOLEAN | `ftBoolean` |
| character strings, OBJECT IDENTIFIER, BIT STRING | `ftWideString` |
| nested SEQUENCE, SEQUENCE OF SEQUENCE | `ftDataSet` (nested) |

A column's type is inferred from its values, so an INTEGER column whose
values all fit 32 bits infers as `ftInteger`. Supply the contract for Delphi
field types.

## Custom serializers

Base classes in `PascalForge.Asn1`:

- `TCustomAsn1ValueSerializer<T>`: override
  `SerializeValue(const AValue: T): TAsn1Value` and
  `DeserializeValue(AValue: TAsn1Value; const AExisting: T): T`. Use this
  one.
- `TCustomAsn1ValueSerializer`: the untyped base with `TValue` and
  `PTypeInfo`, for a type not known at compile time.

Registration:

```pascal
TAsn1Serializer.RegisterTypeSerializer<TCoordinate>(TAsn1Coordinate);
```

Per member: `[Asn1Serializer(TAsn1Coordinate)]`, which overrides the
registration. A custom serializer is consulted before any refusal, so it can
carry a type ASN.1 has no mapping for, or fix a representation a peer's
module requires (a coordinate as an INTEGER of ten-millionths).

The caller adopts the `TAsn1Value` a serializer returns. `DeserializeValue`
borrows its argument and must not free it. A read returns a new instance or
the existing one it was given. See
[`../customization.md`](../customization.md) and
[`../deserialization-ownership.md`](../deserialization-ownership.md).

## Limits/security

| Limit | Value | Error |
| --- | --- | --- |
| write depth | 64 levels (each object, record, array, list, dictionary counts one) | `ESerializationLimitExceeded` |
| read nesting | 256 constructed levels | `EAsn1InputError` |
| declared length | checked against the octets that remain | `EAsn1InputError` |
| end-of-contents with no indefinite length open | refused | `EAsn1InputError` |
| NULL with content, a tag whose form contradicts its type | refused | `EAsn1InputError` |
| constructed BOOLEAN, INTEGER, ENUMERATED, REAL, NULL, OBJECT IDENTIFIER, RELATIVE-OID | refused under BER, DER and CER | `EAsn1InputError` |
| non-minimal length, indefinite length under DER, BOOLEAN true not `FF` | refused under DER / CER | `EAsn1CanonicalError` |
| definite-length constructed value; string segmented against X.690 9.2 (see the table above) | refused under CER | `EAsn1CanonicalError` |
| cycle in the object graph | refused, naming the class | `EAsn1Error` |

Decoder errors name the octet offset; contract-path errors name the member
path. `tests\Robustness` covers nesting bombs,
huge lengths and truncation.

## Expected refusals

By design, not bugs:

- the refusals every format makes: pointers, procedural and method types,
  interfaces, class references, legacy `TList`, `TCollection`, streams,
  `Exception`, `TComponent`, cycles, inline static arrays, variant records,
  `TBcd` without a custom serializer;
- a value nested deeper than 64 levels;
- a `TDateTime` outside the years 1 to 9999, on write;
- an unpaired UTF-16 surrogate in a string, on write;
- a character outside a restricted string type's repertoire, on write;
- a `Variant` of any kind: a component has one declared type;
- a class with no parameterless constructor, which could be written but
  never read back;
- structural conversion, or a DataSet from octets, with no module;
- a module construct outside the declared X.680 subset;
- a text payload given to an ASN.1 handler.

ASN.1 carries `UInt64` above `High(Int64)`, INTEGER of any size, and NaN,
infinities and minus zero in REAL. See
[`../expected-refusals.md`](../expected-refusals.md).

## Interoperability evidence

`tests\Asn1Native` uses **X.690 itself** as the independent reference,
quoting its clause numbers: the OID `2.100.3` as `06 03 81 34 03` from
clause 8.19, the BOOLEAN and INTEGER forms from clauses 8.2 and 8.3, the
REAL octets of clause 8.5 worked out by hand under the canonical rules of
clause 11.3.1, and the DER restrictions of clause 11. No ASN.1 toolkit runs
offline, so the oracle is the Recommendation, not a program. The test also
covers all four tag classes, high tag numbers, the three length forms,
constructed strings under BER, the DER and CER canonical rules including
CER's 1000-octet segmentation, CHOICE, module parsing, a multi-type module
through the registry, read ownership, the writer limits and malformed input.

## Important implementation units

| Role | Unit |
| --- | --- |
| Facade | `src\PascalForge.Asn1.pas` (`TAsn1Serializer`, `TAsn1Value`, `TAsn1BigInt`, `TAsn1Oid`, attributes) |
| Implementation | `src\PascalForge.Asn1.Internal.pas` (`TAsn1Codec`, `TAsn1SchemaCodec`, `TAsn1Engine`: writer, reader, RTTI walk, dynamic bridge) |
| Registration | `src\PascalForge.Asn1.Registration.pas` (`TAsn1SerializationRegistration`, `TAsn1FormatHandler` and its three rule subclasses) |
| Schema | `src\PascalForge.Asn1.Schema.pas` (`TAsn1Schema`, `TAsn1SerializationContext`, `TAsn1TypeDef`, the module parser) |
| Tests | `tests\Asn1Native\Asn1Native.dpr`, `tests\Asn1Native\Asn1Models.pas` |

## Before changing this format

1. Read [`../format-program.md`](../format-program.md) and
   [`../asn1-behavior.md`](../asn1-behavior.md).
2. Run `tests\Asn1Native`
   (`powershell -File scripts\test.ps1 -Only Asn1Native`).
3. Run `tests\TypeCoverage` through `scripts\run-type-coverage.ps1`.
4. Run `tests\ReaderContracts`, `tests\ConversionMatrix` and
   `tests\Lifecycle`.
5. Do not change shared dynamic-model semantics (`TDynamicValue`, `TDynamicTag`,
   Core date and range helpers) from a format unit. Change Core deliberately,
   and retest every format.
6. A change to what BER, DER or CER writes needs a test that pins the
   octets and a documentation change. Keep the X.690
   vectors passing; DER and CER output is canonical, and a changed byte
   breaks every signature over it.
7. Run `scripts\validate-release.ps1` before calling it finished.
