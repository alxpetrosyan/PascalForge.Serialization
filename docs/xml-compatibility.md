# XML: the profile, the ledger, and the evidence

[`xml-behavior.md`](xml-behavior.md) says what the library *writes* for a
Delphi type. This page answers a different and harder question: **is this
actually an XML processor**, and against what exactly.

---

## The declared profile

```text
XML 1.0 Fifth Edition                    https://www.w3.org/TR/xml/
Namespaces in XML 1.0 Third Edition      https://www.w3.org/TR/xml-names/

non-validating
external entity resolution disabled
```

Every word of that is load-bearing.

**Non-validating.** `<!ELEMENT>`, `<!ATTLIST>` and `<!NOTATION>` are parsed
far enough to find their end and then dropped. Nothing is checked against a
content model, no attribute default is applied, and no attribute type is
used to normalise a value. A validating processor is a different program.

**External entity resolution disabled.** An external identifier on the
DOCTYPE is read and *not fetched*. An external entity *declaration* is
refused by name. This is not a switch that could be turned on: there is no
code in the reader that can open a file or a socket.

**Parameter entities are refused.** A non-validating processor is permitted
by the specification not to process them. Since they are not processed, a
document that depends on one is refused rather than quietly losing whatever
the parameter entity would have declared.

Those three are the complete list of what the profile excludes. Everything
else in XML 1.0 and Namespaces 1.0 is implemented.

---

## Why a reader of its own, rather than an SDK unit

The RTL offers `Xml.XMLDoc` over MSXML (Windows COM), ADOM and OmniXML. Each
was considered and each was rejected for the *library*:

| | |
| --- | --- |
| MSXML | COM, Windows-only, and it needs `CoInitialize`. That is a platform dependency and a process-wide initialisation requirement for a serializer that otherwise needs neither. |
| ADOM / OmniXML | A DOM. The engine wants a stream of elements to drive plans with, not a second tree to walk and then throw away. |
| any of them | External entity behaviour is a *setting* rather than an absence. A default that has to be turned off is a default that will one day be on. |

The reader here is about 400 lines, has no dependencies beyond
`System.SysUtils` and `System.Generics.Collections`, and resolves nothing
external because it contains no code that could.

**MSXML is used as the independent oracle in the tests**, which is exactly
where a different implementation by different people is worth having. See
`tests\XmlNative`.

---

## The feature ledger

Decode = the reader accepts and understands it. Encode = the writer produces
it where the construct applies. Oracle = MSXML agrees, in `tests\XmlNative`.
Malformed = there is a negative fixture for it.

| Feature | Spec | Decode | Encode | Oracle | Malformed | Status |
| --- | --- | --- | --- | --- | --- | --- |
| XML declaration | §2.8 | yes | yes | yes | — | PASS |
| `encoding=` in the declaration | §4.3.3 | yes | UTF-8 | yes | — | PASS |
| `standalone=` | §2.9 | accepted, no effect (non-validating) | no | yes | — | PASS |
| Element, start/end tag | §3.1 | yes | yes | yes | yes | PASS |
| Empty-element tag `<a/>` | §3.1 | yes | yes | yes | — | PASS |
| Attribute, both quote styles | §3.1 | yes | `"` | yes | yes | PASS |
| Attribute-value normalisation | §3.3.3 | references resolved | — | yes | — | PASS |
| Character data | §2.4 | yes | yes | yes | — | PASS |
| Character references `&#n;` `&#xn;` | §4.1 | yes | where required | yes | yes | PASS |
| Non-BMP character references | §4.1 | yes, as a surrogate pair | yes | yes | yes | PASS |
| The five predefined entities | §4.6 | yes | yes | yes | — | PASS |
| CDATA sections | §2.7 | yes | escaped text instead | yes | yes | PASS |
| Comments | §2.5 | skipped | no | yes | yes | PASS |
| Processing instructions | §2.6 | skipped | no | yes | yes | PASS |
| Name grammar | §2.3 | yes | yes | yes | yes | PASS |
| Names above U+007F | §2.3, App. B | permissive | permissive | yes | — | PASS |
| Well-formedness: one root | §2.1 | enforced | — | — | yes | PASS |
| Well-formedness: matching tags | §3.1 | enforced | — | — | yes | PASS |
| DOCTYPE, name only | §2.8 | yes | no | yes | — | PASS |
| DOCTYPE, external identifier | §4.2.2 | parsed, **not fetched** | no | yes | — | PASS |
| Internal subset | §2.8 | yes | no | yes | yes | PASS |
| `<!ENTITY>`, internal general | §4.2 | yes | no | yes | yes | PASS |
| Entity referring to an entity | §4.4 | yes | no | yes | yes | PASS |
| Entity expanding to markup | §4.4.2 | yes | no | yes | — | PASS |
| Character reference inside an entity value | §4.4.5 | yes, stays text | no | yes | — | PASS |
| `<!ELEMENT>` `<!ATTLIST>` `<!NOTATION>` | §3.2, §3.3 | parsed, ignored | no | yes | — | PASS (non-validating) |
| External entity declaration | §4.2.2 | **REFUSED by name** | no | — | yes | PASS (profile) |
| Parameter entities | §4.2.2 | **REFUSED by name** | no | — | yes | PASS (profile) |
| Default namespace | NS §6.2 | yes | yes | yes | — | PASS |
| Prefixed namespace | NS §3 | yes | yes | yes | yes | PASS |
| Namespace redeclaration on a child | NS §6.1 | yes | yes | yes | — | PASS |
| Undeclaring the default namespace | NS §6.2 | yes | yes | yes | — | PASS |
| Unprefixed attributes are in no namespace | NS §6.3 | yes | yes | yes | — | PASS |
| Identity is URI + local name | NS §3 | yes | yes | yes | — | PASS |
| Undeclared prefix | NS §3 | rejected | — | — | yes | PASS |
| Unicode text, all planes | §2.2 | yes | yes | yes | — | PASS |
| Characters XML cannot represent, and unpaired UTF-16 surrogates | §2.2 | — | **refused by name** | — | yes | PASS |
| UTF-8 bytes in and out | §4.3.3 | yes, BOM tolerated | yes, no BOM | yes | yes | PASS |

Nothing has been removed from this table because it was difficult. The three
`PASS (profile)` rows are the declared exclusions above, and they are
refusals with messages rather than silent omissions.

---

## Resource and security audit

| Hazard | Answer |
| --- | --- |
| XXE - external entity reads a file | No code can open a file. An external entity declaration is refused by name. |
| SSRF - external entity fetches a URL | Same. No network code exists in the reader. |
| Billion laughs / quadratic blowup | Every declared entity's **fully expanded length is computed from the declarations alone**, before any content is read. Over 8 MB is refused there and then, so the expansion never starts. |
| Recursive entity | Found by the same pass, as a cycle, with the entity named. |
| Stack exhaustion by nesting | Elements deeper than 512 are refused with a message. A crash is not a diagnosis. |
| Unbounded entity name | Reference scanning stops after 64 characters. |
| Integer overflow in a character reference | Code points are range-checked against U+10FFFF. |
| Truncated input | Every scan is bounded by the document length; each produces a message with a line and column. |
| Invalid UTF-8 on the byte path | `Utf8BytesToString` refuses by byte offset instead of substituting U+FFFD. |
| Unterminated construct | Comment, PI, CDATA, attribute value, literal, internal subset - each has a negative fixture. |

---

## Independent interoperability

The oracle is **MSXML**, through `Xml.XMLDoc`, in `tests\XmlNative`. It is a
different implementation, written by different people, present on every
Windows machine and needing no network.

```text
INDEPENDENT_ORACLE_AVAILABLE: PASS
INDEPENDENT_INTEROP_DECODE: PASS      ten fixtures, oracle -> semantic values -> compared
INDEPENDENT_INTEROP_ENCODE: PASS      our writer -> oracle -> semantic values -> compared
INDEPENDENT_INTEROP_UNICODE: PASS     Georgian through the oracle, by code unit
INDEPENDENT_INTEROP_FOREIGN_ESCAPING: PASS
```

The fixtures are written by hand rather than by either implementation, so
neither gets to define the question. They cover empty elements, text,
attributes, repeated children, all five predefined entities, decimal and hex
character references, CDATA, comments, an XML declaration, non-ASCII text in
both an attribute and an element, and a DOCTYPE with an internal entity.

`CANONICAL_OR_DETERMINISTIC_MODE: NOT_APPLICABLE` — the library does not
claim Canonical XML (C14N). Its output is deterministic for a given input
and options, which `WRITER_OUTPUT_IS_STABLE` asserts, but that is a weaker
statement than C14N and is not offered as one.

---

## Conversion and DataSet

Generated fresh on every run by `tests\ConversionMatrix`, which asks the
registry which formats exist rather than naming any:

```text
CONTRACT_CONVERSION_MATRIX: PASS
STRUCTURAL_CONVERSION_MATRIX: PASS
STRUCTURAL_LOSSLESS_MATRIX: PASS
ALL_PREVIOUS_PAIRINGS_RERUN: PASS
```

The full table, including what the Strict profile refuses for each ordered
pair, is written to `artifacts\conversion-matrix.md`.

DataSet results are in `tests\DataSetSources`:

```text
DATASET_CONTRACT_PROJECTION: PASS
DATASET_CLIENTDATASET_CONTRACT: PASS
DATASET_STRUCTURAL_INFERENCE: PASS
DATASET_NATIVE_TYPE_FIDELITY: PASS
```

---

## The gate

```text
FORMAT: XML
STANDARD_TARGET: XML 1.0 Fifth Edition + Namespaces in XML 1.0 Third Edition
PROFILE: non-validating, external entity resolution disabled

FEATURE_LEDGER_COMPLETE: PASS
NATIVE_SYNTAX_COMPATIBILITY: PASS
NATIVE_TYPE_COMPATIBILITY: PASS
MALFORMED_INPUT_VALIDATION: PASS

INDEPENDENT_INTEROP_DECODE: PASS
INDEPENDENT_INTEROP_ENCODE: PASS
CANONICAL_OR_DETERMINISTIC_MODE: NOT_APPLICABLE

DIRECT_SERIALIZE_DESERIALIZE: PASS
DELPHI_OBJECT_ROUNDTRIP: PASS
OWNERSHIP_CONTRACT: PASS
PLAN_CACHE_WARM_PATH: PASS
CUSTOMIZATION_API: PASS
DATE_TIME_POLICY: PASS

REGISTRATION_ISOLATED: PASS
UNREGISTERED_RUNTIME_ERROR: PASS
FORMAT_SOURCE_ISOLATION: PASS

STRUCTURAL_CONVERSION_MATRIX: PASS
CONTRACT_CONVERSION_MATRIX: PASS
ALL_PREVIOUS_PAIRINGS_RERUN: PASS

DATASET_CONTRACT_PROJECTION: PASS
DATASET_CLIENTDATASET_CONTRACT: PASS
DATASET_STRUCTURAL_INFERENCE: PASS
DATASET_NATIVE_TYPE_FIDELITY: PASS

PREVIOUS_FORMAT_REGRESSION: PASS
JSON_REGRESSION: PASS
DATASET_REGRESSION: PASS

WIN32: PASS
WIN64: PASS
DOCS: PASS
DEMOS: PASS
BANNED_MARKERS: PASS
```

**Compatibility claim.** PascalForge reads and writes **XML 1.0 Fifth Edition
with Namespaces 1.0, non-validating, with external entity resolution
disabled**, and every row of the ledger above passes both ways against an
independent processor.

It is deliberately **not** claimed to be a complete XML 1.0 processor: a
validating processor and one that resolves external entities are different
programs, and the second is one this library will not become. The
unsupported list is exactly the three profile exclusions named at the top of
this page, and each is a refusal with a message rather than a silent
omission.

SDK units reused: none in the library. `Xml.XMLDoc`, `Xml.Win.msxmldom` and
`Winapi.ActiveX` are used only by `tests\XmlNative`, as the oracle.
