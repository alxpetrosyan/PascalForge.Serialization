# Unicode and UTF-8

Two different things, and most of the trouble in this area comes from
treating them as one.

```text
a Delphi string    Unicode TEXT. A sequence of UTF-16 code units.
                   It has no byte encoding at all until someone picks one.

TBytes             BYTES. They say nothing about what they mean.
```

`Serialize<T>` returns a string, because a string is what a Delphi caller
wants. `SerializeUtf8<T>` returns `TBytes`, because a socket wants bytes and
somebody has to choose the encoding out loud.

Nothing in this library converts through `AnsiString`, the system code page,
or a locale — not in serialization, not in structural conversion, not in the
DataSet projection.

---

## Text survives conversion

Exactly, as the same code units — not "looks the same":

```text
JSON  ->  structural tree  ->  XML  ->  structural tree  ->  JSON
```

`tests\UnicodeUtf8` asserts code-unit equality for Georgian, Cyrillic, Latin
Extended, CJK, combining marks and non-BMP characters, in both directions and
through BSON as well.

Non-BMP characters deserve a note. `U+1F600` is **two** UTF-16 code units in a
Delphi string and one character to a reader; a surrogate pair is written as a
pair and never split. A surrogate with no partner is not a character and
cannot be encoded as UTF-8. JSON writes it as `\uXXXX`, which JSON can spell,
so the document stays parseable rather than becoming invalid bytes. Every
other format refuses it by name - `ESerializationUnsupported` from
`StringToUtf8Bytes` in the binary formats, `EXmlError`, `EYamlError`,
`EAsn1Error` for `BMPString` and `UniversalString` - rather than writing the
U+FFFD that `TEncoding.UTF8` puts in its place. CSV's text output keeps it,
because a Delphi string can hold it; CSV's UTF-8 output refuses it.

Combining marks are left alone. `e` + `U+0301` is not normalised to `é`: the
document said what it said, and normalising it would change a value nobody
asked to change.

---

## JSON output is readable by default

JSON requires exactly three things to be escaped — the quote, the backslash,
and characters below `U+0020` — and this library escapes exactly those.

```json
{"Name": "დიდი ტელევიზორი"}
```

not

```json
{"Name": "\u10DA\u10D0\u10DA\u10D8 ..."}
```

Both are legal JSON and mean the same thing. The first is the one you can
read in a log.

When a consumer genuinely needs 7-bit output — an old protocol, a pipeline
that mangles high bytes — ask for it:

```pascal
Options := TJsonSerializationOptions.Default;
Options.UnicodeEscape := TJsonUnicodeEscapePolicy.EscapeNonAscii;
Json := TJsonSerializer.Serialize<TShipment>(Shipment, Options);
```

This option is on the JSON facade, not in the shared core, because it is a
fact about how JSON spells text. XML and BSON have nothing like it.

> **Why this library renders its own JSON text.** The RTL offers two
> renderings and neither is right. `TJSONValue.ToJSON` escapes every
> non-ASCII character, so a Georgian document becomes unreadable.
> `TJSONValue.ToString` leaves control characters **literal**, which is not
> valid JSON — a raw `U+0001` inside a string is forbidden by the grammar,
> whatever a lenient parser does with it. So the text is produced here:
> always valid, and legible unless you asked otherwise.

---

## Asking for bytes

```pascal
Bytes := TJsonSerializer.SerializeUtf8<TShipment>(Shipment);
Shipment := TJsonSerializer.DeserializeUtf8<TShipment>(Bytes);

Bytes := TXmlSerializer.SerializeUtf8<TShipment>(Shipment);
Shipment := TXmlSerializer.DeserializeUtf8<TShipment>(Bytes);
```

**No BOM.** A BOM in UTF-8 marks a byte order that does not exist, and several
strict JSON parsers reject a document that starts with one. A leading BOM on
the way *in* is accepted and skipped, because producers emit them anyway.

`SerializeUtf8` on XML turns the XML declaration on, so that

```xml
<?xml version="1.0" encoding="UTF-8"?>
```

and the bytes that follow it agree. A document that announces one encoding and
is written in another is unreadable, and the two are decided in one place
precisely so that cannot happen.

BSON already returns `TBytes` from `Serialize<T>`: it is a binary format and
there was never a string to encode.

### Malformed input is named, not swallowed

`TEncoding.UTF8.GetString` substitutes `U+FFFD` for a malformed sequence and
says nothing, which turns "these bytes are not what you said they were" into
silent corruption three layers later. The decoder here refuses, with the byte
offset:

```pascal
Utf8BytesToString(Bytes);   // raises EInvalidUtf8, E.Offset says where
IsValidUtf8(Bytes);         // for a caller who would rather ask than catch
StringToUtf8Bytes(Text);    // no BOM; an unpaired surrogate raises ESerializationUnsupported
```

Rejected: overlong forms, truncated sequences, stray continuation bytes,
surrogate code points encoded directly, and anything above `U+10FFFF`.

---

## `TSerializationPayload`

A payload is text *or* bytes and knows which. Every method is named for one
direction, and the one that does not apply raises rather than guessing.

| | text payload | binary payload |
| --- | --- | --- |
| `AsText` | the string | **raises** |
| `AsBytes` | **raises** | the bytes |
| `ToUtf8Bytes` | UTF-8 bytes | **raises** |
| `DecodeUtf8Text` | **raises** | decoded as UTF-8 |

`IsText` and `IsBinary` answer the question without an exception.

`ToUtf8Bytes` deliberately does **not** return a binary payload's bytes
unchanged. Those bytes are not UTF-8 text, and calling them that is how a BSON
document ends up being handed to something expecting a string.
`DecodeUtf8Text` is the opposite claim — *these bytes really are UTF-8* — and
the caller takes responsibility for it.

So getting UTF-8 out of a conversion is one expression:

```pascal
Utf8Json := TSerialization.Convert(Xml,
  TSerializationFormat.Xml, TSerializationFormat.Json).ToUtf8Bytes;
```

### Reading a document from bytes

A **text** format — JSON, XML — accepts either shape: a text payload is used
as it stands, and a binary payload is decoded as UTF-8, because UTF-8 bytes
are exactly how a text document travels as bytes. So `TBytes` is a perfectly
good JSON source.

A **binary** format does not accept text. Handing BSON a string raises, naming
the problem:

> BSON is a binary format and this source is text. Text is not re-encoded into
> BSON: the bytes of a string are not a BSON document, and treating them as
> one reads the first four characters as a length.

---

## What this rules out

* A Georgian, Cyrillic or CJK value arriving as `?????`.
* A non-BMP character arriving as two replacement characters.
* A document that says `encoding="UTF-8"` and is not.
* A malformed byte sequence turning into `U+FFFD` without anyone noticing.
* JSON output that is legal but unreadable.
* Bytes being treated as text, or text as bytes, because a method name was
  vague about which it returned.
