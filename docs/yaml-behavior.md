# YAML behaviour

How the YAML engine maps Delphi values to and from YAML, as defined by
[YAML 1.2.2](https://yaml.org/spec/1.2.2/). This document covers **YAML
only**; see [`serializer-behavior.md`](serializer-behavior.md),
[`xml-behavior.md`](xml-behavior.md), [`cbor-behavior.md`](cbor-behavior.md)
and the rest for the other formats.

Ownership is defined once, for every format, in
[`deserialization-ownership.md`](deserialization-ownership.md).

YAML is a real engine: a real parser and a real emitter, written against the
1.2.2 specification. It does **not** go through JSON. YAML 1.2 is a superset
of JSON on paper, and parsing YAML as JSON is exactly how anchors, block
scalars, comments, multiple documents and the core schema's resolution rules
all get lost at once.

## The text

```pascal
Text    := TYamlSerializer.Serialize<TShipment>(Shipment);   // string
Shipment := TYamlSerializer.Deserialize<TShipment>(Text);
TYamlSerializer.Populate<TShipment>(Existing, Text);
```

Several documents in one stream:

```pascal
Text    := TYamlSerializer.SerializeAll<TShipment>(Shipments);
Shipments := TYamlSerializer.DeserializeAll<TShipment>(Text);
```

And with no contract:

```pascal
Stream := TYamlSerializer.ParseStream(Text);     // TYamlStream, caller owns
Doc    := TYamlSerializer.ParseDocument(Text);   // exactly one document
Text   := TYamlSerializer.SerializeStream(Stream);
Flat   := TYamlSerializer.Expand(Doc);           // aliases replaced by copies
```

## The single most surprising thing: the 1.2 core schema

**`yes`, `no`, `on` and `off` are strings.** **`012` is the integer twelve.**

YAML 1.1 resolved `yes`/`no`/`on`/`off` as booleans and treated a leading zero
as octal. YAML 1.2's core schema does neither, and this library implements
1.2. A 1.1 document that relied on either means something *different* when
read by any 1.2 parser, including this one — so the difference is stated here
rather than left to be discovered in production.

`TYamlSchema.Resolve` is the whole rule, in one place:

| Text | Resolves as |
| --- | --- |
| `null`, `Null`, `NULL`, `~`, empty | null |
| `true`, `True`, `TRUE`, `false`, `False`, `FALSE` | bool |
| `yes`, `no`, `on`, `off`, `y`, `n` | **str** |
| `-?[0-9]+` | int |
| `0o7`, `0x2A` | int (octal and hexadecimal) |
| `007`, `012` | int — seven and twelve. 1.2 dropped 1.1 leading-zero octal and spells octal `0o14` |
| `1.5`, `1e3`, `.inf`, `-.Inf`, `.nan` | float |
| `190:20:30` | **str** — sexagesimal was 1.1 |
| `0b1010` | **str** — binary was 1.1 |
| `1.2.3` | str |

`TYamlSchema` is public, so an application can ask the same question the
parser asks.

## Structure

### Block and flow collections

Both, nested in either order:

```yaml
server:
  host: localhost
  ports:
    - 80
    - 443
matrix: {rows: 2, cols: [1, 2]}
```

A block sequence is allowed at its parent key's own column, which is the
specification's exception and the spelling almost every real file uses:

```yaml
ports:
- 80
- 443
```

### Scalar styles

All five, and the emitter preserves the style a node carries.

| Style | Example |
| --- | --- |
| plain | `host: localhost` |
| single-quoted | `note: 'it''s here'` |
| double-quoted | `path: "c:\\temp\n"` — with escapes |
| literal, introduced by the vertical bar | newlines kept |
| folded, introduced by `>` | newlines folded to spaces |

Block scalars carry a **chomping indicator** (`clip` by default, `strip` for
`-`, `keep` for `+`) and an optional **indentation indicator**. All are read
and written.

A plain scalar may span several lines; the continuation is measured against
the **parent's** indentation, not against the scalar's own column.

### Anchors and aliases are graph semantics

```yaml
defaults: &d
  retries: 3
staging: *d
production: *d
```

An alias says the two members are **the same node**, not two equal ones. No
other format here can say that.

* `TYamlNode` of kind `Alias` holds the anchor name.
* `TYamlSerializer.Expand` returns a new document with every alias replaced by
  a **copy**, for a consumer that only wants a tree.
* In structural conversion an alias becomes `TDynamicTag.YamlAlias`, payload
  `Str` — the anchor name — so a destination that cannot express sharing
  refuses by name instead of silently duplicating the subtree.
* An alias with no anchor raises `EYamlUnresolvedAliasError`; an anchor that
  refers to itself raises `EYamlAliasCycleError`.

### Tags

Primary (`!local`), secondary (`!!str`) and verbatim (`!<tag:example.com,2024:x>`)
handles are all parsed, and `%TAG` directives are honoured. A tag this library
has no better mapping for becomes `TDynamicTag.FormatTag` in the dynamic tree:
an object of `tag` and `value`.

### Complex keys

`? ` introduces a key that is itself a node — a sequence or a mapping. Parsed
and represented; `TYamlNode.Keys[]` is a node, not a string, for exactly this
reason.

### Several documents in one stream

`---` starts a document and `...` ends one. `%YAML` and `%TAG` directives
apply per document.

The registry handler makes one specific choice worth knowing:

* **reading** a stream of several documents structurally produces an
  **array**, one element per document;
* **writing** produces **one** document.

A stream is not a value, so reading one has to become something; an array is
the only honest answer. Writing cannot invent a document boundary, so it does
not try. `SerializeAll` / `DeserializeAll` and `ParseStream` /
`SerializeStream` are the API for callers who want streams as streams.

## Documents that are wrong, refused by name

| Exception | Raised for |
| --- | --- |
| `EYamlTabIndentationError` | a tab used for indentation — the specification forbids it, and the message says to use spaces |
| `EYamlUnclosedQuoteError` | a quoted scalar with no closing quote |
| `EYamlDuplicateKeyError` | a repeated mapping key, under the `Error` policy |
| `EYamlUnresolvedAliasError` | an alias naming an anchor that does not exist |
| `EYamlAliasCycleError` | an anchor that refers to itself |
| `EYamlLimitExceeded` | past `TYamlLimits` — see below |
| `EYamlParseError` | anything else, carrying `Line` and `Column` |

Every parse error carries the line and the column. A parser that says only
"invalid YAML" is not worth having.

### Duplicate keys

```pascal
TYamlSerializer.SetDuplicateKeyPolicy(TYamlDuplicateKeyPolicy.Error);
```

`Error` (raise), `LastWins` or `FirstWins`. The specification says a duplicate
key is an error, so that is the default; the other two exist because real
files contain them.

### Expansion budgets

```pascal
Limits := TYamlSerializer.Limits;
Limits.MaxDepth := 100;
Limits.MaxExpandedNodes := 1000000;
TYamlSerializer.SetLimits(Limits);
```

An alias may refer to a node that contains aliases, which is enough to write a
kilobyte of YAML that expands to gigabytes — the billion-laughs attack. Both
limits are checked during expansion and exceeding either raises
`EYamlLimitExceeded` rather than exhausting memory.

## Emitting

```pascal
Options := TYamlEmitOptions.Default;      // block style, two-space indent
Options := TYamlEmitOptions.FlowStyle;    // {a: 1, b: [2, 3]}
Options.ExplicitDocumentStart := True;    // write --- even for one document
Options.ExplicitDocumentEnd := True;      // write ...
TYamlSerializer.SetDefaultEmitOptions(Options);
```

**The node's style is the authority.** A node created as `Plain` is emitted
plain; a node created as `DoubleQuoted` is emitted quoted. What the emitter
decides for itself is only what keeps a document reading back as written:

- a *string* whose text would resolve as something else under the core
  schema is quoted, so that `"true"`, `"42"` and `"null"` survive as strings.
  `TYamlSchema.NeedsQuotingAsString` is that test, and it is public;
- in flow style, a plain scalar that holds a comma, a bracket or a brace, or
  starts with `?`, is double-quoted - `{Name: "Doe, Jane"}`;
- a block collection's anchor or tag, and an empty `[]` or `{}` that starts
  its own line, are written at the collection's own indentation;
- a scalar, key, anchor, tag, alias or directive holding an unpaired UTF-16
  surrogate is refused with `EYamlError`: it is half a character, and YAML
  has no spelling for it.

## The Delphi contract

| Delphi | YAML, by default |
| --- | --- |
| `Boolean` | `true` / `false` |
| every integer width | a plain int scalar |
| `Single`, `Double`, `Extended` | a plain float scalar |
| `Currency` | a plain decimal scalar |
| `string` | a scalar, quoted only when it would resolve as something else |
| `TBytes` | base64 text |
| `TDateTime` | ISO 8601 text |
| `TGUID` | the canonical 36-character text |
| an enumeration | its member name, or its `RegisterEnumMapping` name, double-quoted when the core schema would read it as something else (`"1"`, `"~"`, `"null"`, `"True"`); on read a registered name is matched before the schema resolves the scalar |
| a class or record | a block mapping |
| a list or dynamic array | a block sequence |
| a dictionary | a mapping |
| `TNullable<T>` with no value | **absent** from the mapping, not `null` |

### Attributes

```pascal
type
  TShipment = class
  public
    [YamlName('ref')] Reference: string;
    [YamlIgnore] Scratch: string;
    [YamlDateTimeRepresentation(TYamlDateTimeRepresentation.UnixSeconds)]
      Issued: TDateTime;
  end;
```

`YamlName`, `YamlIgnore`, and the date-time representation
(`Iso8601`, `Timestamp`, `UnixSeconds`, `UnixMilliseconds`, `CustomString`).
`Iso8601` is the default: the 1.2 core schema leaves such text a string,
which is exactly what it is. `UnixSeconds` is the second the instant falls
in, rounded toward the past. Every representation refuses a `TDateTime`
outside the years 1 to 9999 on write (`ESerializationUnsupported`); on read,
an epoch count outside them is an `EYamlInputError`, and so is a sequence or
mapping where a scalar belongs.

## Structural conversion

YAML declares all four capabilities with nothing supplied.

```pascal
Payload := TSerialization.Convert(Source, TSerializationFormat.Json,
             TSerializationFormat.Yaml);
```

Scalars resolve through the core schema, so a YAML `42` becomes
`TDynamicKind.Int` and a YAML `"42"` becomes `TDynamicKind.Str`. An alias
becomes `TDynamicTag.YamlAlias` and a tag this library does not map becomes
`TDynamicTag.FormatTag`.

## What is proven, and how

`tests/YamlNative` runs **241 checks** against the 1.2.2 specification.

The ledger it prints covers block mappings and sequences, flow collections,
all five scalar styles including multi-line plain scalars, all three chomping
modes, the indentation indicator, document start and end markers,
multi-document streams, anchors and aliases, primary/secondary/verbatim tags,
complex keys, comments, core-schema resolution, tab indentation, all three
duplicate-key policies, and the expansion budgets.

## Not implemented, and why

* **The 1.1 schema.** `yes`/`no`/`on`/`off` resolve as strings here and `012`
  is twelve. A 1.1 document that relied on either means something different
  when read by any 1.2 parser, and pretending otherwise would make this
  library disagree with every other current one.
* **Merge keys (`<<`)** are a 1.1 type-repository feature and not part of 1.2.
  Anchors and aliases still work; `<<` does not.
* **Emitting anchors for shared Delphi instances.** The contract writer writes
  a tree, so two members holding one object are written twice rather than
  anchored once. Reading an anchored document works; producing one from object
  identity does not.
