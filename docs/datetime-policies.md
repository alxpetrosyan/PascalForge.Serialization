# Date and time policies

Every format decides for itself how a `TDate`, a `TTime` and a `TDateTime` are
written. The *mechanism* is shared; the *meaning* is not.

## The defaults never moved

Configuring nothing leaves every format's output exactly where it was before
policies existed. The built-in default is a constructor argument to each
format's policy table rather than a hard-coded zero, precisely so that adding
the mechanism could not move anything.

| | `TDate` | `TTime` | `TDateTime` |
| --- | --- | --- | --- |
| **JSON** | `2026-03-14` | `17:30:00` | ISO 8601, **no** offset |
| **XML** | `xs:date` | `xs:time` | `xs:dateTime`, **no** offset |
| **BSON** | ISO 8601 string | ISO 8601 string | **native BSON datetime** |

## Resolution order

Strongest first. Resolved **once**, while the type's plan is built, and cached
there — nothing is looked up while a document is being written.

1. a member attribute — `[JsonDateTimeFormat]`, `[XmlDateTimeFormat]`,
   `[BsonDateTimeRepresentation]`
2. a field registration — `RegisterFieldDateTimeFormat<T>('CreatedAt', ...)`
3. a type registration — `RegisterDateTimeFormat<T>(...)`
4. that format's global default — `SetDateTimeFormat(...)`
5. the built-in form in the table above

A member attribute cannot be overridden by any registration: it is the most
specific statement anyone can make about that member.

## The three tables are independent

```pascal
TJsonSerializer.RegisterFieldDateTimeFormat<TOrder>('Created',
  TJsonDateTimeFormat.UnixSeconds);
TXmlSerializer.RegisterFieldDateTimeFormat<TOrder>('Created',
  TXmlDateTimeFormat.Xsd);
TBsonSerializer.RegisterFieldDateTimeRepresentation<TOrder>('Created',
  TBsonDateTimeRepresentation.Native);
```

One member, three configurations, all in force at once. Configuring JSON's
moves no XML and no BSON output — `tests\Conversion` asserts exactly that.

Within one format there are three tables, one per value kind, so a policy for
timestamps does not silently change how dates are written.

## The representations

**JSON** — `TJsonDateTimeFormat`

| | |
| --- | --- |
| `Iso8601` | the built-in forms; the default |
| `UnixSeconds` | a JSON **number**, whole seconds since the epoch - the second the instant falls in, rounded toward the past, so 1969-12-31T23:59:59.5 is -1 |
| `UnixMilliseconds` | a JSON **number**, milliseconds |
| `Custom` | a `FormatDateTime` pattern, as a string, used both ways |

**XML** — `TXmlDateTimeFormat`

| | |
| --- | --- |
| `Xsd` | `xs:date` / `xs:time` / `xs:dateTime`; the default |
| `UnixSeconds`, `UnixMilliseconds` | an integer |
| `Custom` | a `FormatDateTime` pattern |

**BSON** — `TBsonDateTimeRepresentation`

| | |
| --- | --- |
| `Native` | BSON's datetime element; the default for `TDateTime` |
| `StringIso8601` | an ISO 8601 string; the default for `TDate` and `TTime` |
| `UnixSeconds`, `UnixMilliseconds` | int64 |
| `CustomString` | a `FormatDateTime` pattern, as a string |

A custom pattern is symmetrical: the same pattern is used to write and to
read, in every format that has one. The reader
(`TStructuralText.TryDecodePattern`) reads the numeric specifiers - `yyyy`,
`yy`, `mm`, `m`, `dd`, `d`, `hh`, `h`, `nn`, `n`, `ss`, `s`, `zzz`, `z`, with
`m` after an `h` the minute, as `FormatDateTime` has it - and matches quoted
text and every other character literally. `yy` reads as 20yy. A pattern with
words - month or day names, `am/pm` - is written but cannot be read back
without a locale; text it does not match is then tried the way earlier
builds read it, and refused if that fails too.

Every representation refuses a `TDateTime` or `TDate` outside the years 1 to
9999 on write, with `ESerializationUnsupported`: no format here can state
one, and every reader refuses it. An instant before 1899-12-30 with a time of
day - which Delphi encodes as a negative day and a positive time - is the
instant it states in every representation.

## Time zones

**A `TDateTime` carries no time zone.** The library does not invent one, and
each format's honesty about that is part of its contract:

- **Every format writes no offset**, because the value has none.
- **JSON, YAML and CBOR** read text with an offset as the instant it states,
  normalised to UTC (`TStructuralText.DecodeIso8601`, which applies the
  offset through the Unix millisecond count, so it is right before
  1899-12-30 too). Text without one is taken as written.
- **XML** writes `xs:dateTime` with **no** offset. An offset in an incoming
  document is accepted and **ignored**: the wall-clock fields are taken as
  written, which is the only reading a `TDateTime` can represent honestly.
  The ISO text of BSON and MessagePack is read the same way. CSV refuses a
  cell with an offset.
- **BSON** stores milliseconds since the Unix epoch and treats the
  `TDateTime` as the instant it states. Nothing is shifted, because a shift
  would make the stored value depend on where the process happened to run.
- The **Unix** representations, in every format, do the same: the `TDateTime`
  is the instant, and no conversion is applied.

If your application needs a zone, carry it as its own member. A serializer
that guesses one is a serializer that is wrong in a different country.

## Where the mechanism lives

`TDateTimePolicies` in `PascalForge.Serialization.Core` stores a policy as an
opaque `(Kind: Integer; Pattern: string)` and resolves it in the order above.
It never compares a `Kind` against a constant and contains no format
enumeration: each format stores the ordinal of *its own* enumeration and
interprets it alone. The resolution order and the resolve-once-at-plan-build
discipline are shared because they are the same problem; what a policy *means*
is not shared, because it is not the same thing.
