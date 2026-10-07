# Attributes and their precedence

Two layers of attributes describe a Delphi type to this library.

**The general attributes**, in `PascalForge.Serialization.Attributes`, say
something once for every format, for Dynamic and for the DataSet
projection:

```pascal
uses
  PascalForge.Serialization.Attributes;

type
  [SerializationEnum('draft,sent,paid')]
  TInvoiceState = (Draft, Sent, Paid);

  TInvoice = class
  public
    [SerializationName('invoice_id')]
    Id: Integer;
    [SerializationIgnore]
    PasswordHash: string;
    [SerializationEnum('l,d')]
    Theme: TTheme;
    State: TInvoiceState;
  end;
```

| Attribute | Means |
| --- | --- |
| `[SerializationName('n')]` | the member's name, **used exactly as written** - no format's naming convention (JSON's camelCase, snake_case) is applied to it |
| `[SerializationIgnore]` | the member is not part of the serialized surface: no format writes or reads it, and it is not projected into Dynamic or a DataSet |
| `[SerializationEnum('a,b,c')]` | the text of each value of an enumeration, in declaration order - the list `RegisterEnumMapping` takes, as one string. On an enumeration **type** it applies wherever the type is used - as a member, inside a nullable, as a set's elements, as an array's or list's items, as a dictionary's keys or values, inside nested records; on a **member**, to that member's own value only (directly or through a nullable). Values are trimmed; a value containing a comma takes another separator, `[SerializationEnum('a;b', ';')]` |

There are exactly these three. Anything more specific is a format's own
attribute or registration.

**The format-specific attributes and registrations** - `[JsonName]`,
`[XmlName]`, `[BsonName]`, `[CborName]`, `[MessagePackName]`, `[YamlName]`,
`[CsvName]`, `[AvroName]`, `[DataSetName]`, the `*Ignore` attributes,
`RegisterFieldOverride`, `RegisterEnumMapping` - say something for one
format only. They are unchanged, and they are more specific: **a
format-specific name or enumeration mapping beats the general one, for that
format and no other.**

## Precedence

### Names

From most to least specific:

1. the format's own name attribute (`[JsonName]`, `[XmlName]`, ...);
2. the format's own registered rename (JSON's `RegisterFieldOverride` with
   `TJsonFieldOverride.Rename`, the DataSet's field overrides);
3. `[SerializationName]`;
4. the format's default from the Delphi identifier - for JSON, its naming
   strategy (camelCase by default, or snake_case); for every other format
   and for Dynamic, the identifier as it is.

| Format | Format-specific name | General name applies |
| --- | --- | --- |
| JSON | `[JsonName]`, then a registered rename | yes |
| XML, BSON, CBOR, MessagePack, YAML, CSV, Avro | its `[...Name]` | yes |
| ASN.1 | none | yes - the component's name in structural conversion and in diagnostics; the encoding itself is positional |
| Protobuf | none - fields are numbers | **no**: Protobuf puts no name on the wire |
| DataSet | `[DataSetName]`, then a registered override | yes |
| Dynamic | none | yes |

### Ignoring

`[SerializationIgnore]` removes the member from every format, Dynamic and
the DataSet projection. A format's own ignore attribute (`[JsonIgnore]`,
`[XmlIgnore]`, ...) or registration still removes it from that format alone.
**There is no way to un-ignore**: a general ignore cannot be overridden by a
format, because a member nobody should ever see is the point of it.

### Enumerations

From most to least specific:

1. the format's own field-level mapping (JSON's `RegisterFieldEnumMapping`);
2. the format's own type-level mapping (`RegisterEnumMapping` on that
   serializer);
3. `[SerializationEnum]` on the member;
4. `[SerializationEnum]` on the enumeration type;
5. the Delphi names.

A mapped enumeration reads back its mapped text only, as with a registered
mapping. Where the general mapping does **not** apply, because the format's
own rules are authoritative:

| Format | Enumerations are written as | `[SerializationEnum]` |
| --- | --- | --- |
| JSON, XML, BSON, YAML, CSV, Dynamic | text | applies |
| CBOR, MessagePack | text by default; numbers under their `Ordinal`/`Value` representation | applies to the text form |
| Avro | schema enum **symbols** - schema identifiers, which a text like `in-progress` is not; `RegisterEnumMapping` on `TAvroSerializer` remains the way to change them | does not apply |
| Protobuf | field numbers | does not apply |
| ASN.1 | `ENUMERATED` numbers | does not apply |
| DataSet | integer fields | does not apply |

## Where they are resolved

The general attributes are read once per type, in the shared RTTI metadata
(`PascalForge.Serialization.Internal`) - the same place every engine and
Dynamic get a type's member surface from: public and published fields and
readable properties, a name redeclared by a descendant appearing once as the
most-derived declaration. Each engine then applies its own attributes,
registrations and wire rules on top. `tests\GeneralAttributes` checks every
format and every precedence rule above; `tests\Dynamic` checks that a type's
facts are discovered once whichever engine asks first.
