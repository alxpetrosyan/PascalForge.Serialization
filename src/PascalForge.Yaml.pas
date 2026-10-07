{*******************************************************************************
  PascalForge.Yaml

  Public YAML 1.2.2 serialization facade for PascalForge.Serialization.

  Responsibilities
    - Typed YAML serialization/deserialization, single and multi-document.
    - Population of existing values.
    - YAML representation graph, options and customization API.

  Registration
    Direct TYamlSerializer use does not require format registration.
    Generic TSerialization operations require explicit registration:
    TYamlSerializationRegistration.RegisterFormat (PascalForge.Yaml.Registration).

  Configuration
    Global serializer configuration becomes immutable after first use.

  Threading
    Serialization is safe for concurrent use after configuration is frozen.

  Documentation
    docs/formats/yaml.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Yaml;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  YAML 1.2.2 serialization.

      Text    := TYamlSerializer.Serialize<TShipment>(Shipment);   // string
      Shipment := TYamlSerializer.Deserialize<TShipment>(Text);
      TYamlSerializer.Populate<TShipment>(Existing, Text);

  YAML is text, so its natural Delphi type is a string and that is what this
  unit returns. The target is the YAML specification revision 1.2.2, and the
  parser is this library's own: RAD Studio ships none.

  This is a real YAML engine. A Delphi value is written straight to YAML and
  read straight back; nothing routes through JSON text, through XML, or
  through the dynamic tree. The only thing shared with the other formats is
  the Delphi type foundation in PascalForge.Serialization.Core: what a
  nullable is, what a collection is, how a type is named.

  Everything else is YAML's own. YAML reads only YAML attributes - [YamlName]
  never sees [JsonName].

  Using this unit needs no registration. PascalForge.Yaml.Registration exists
  only for code that picks a format at run time.

  =========================================================================
  THE FOUR DECISIONS A YAML READER CANNOT AVOID, AND THE ANSWERS HERE
  =========================================================================

  1. SCALAR RESOLUTION IS 1.2, NOT 1.1.

     The core schema of YAML 1.2 resolves exactly this much and no more:

       null      null Null NULL ~   and the empty scalar
       bool      true True TRUE false False FALSE
       int       [-+]?[0-9]+   0o[0-7]+   0x[0-9a-fA-F]+
       float     [-+]?(.[0-9]+|[0-9]+(.[0-9]*)?)([eE][-+]?[0-9]+)?
                 [-+]?.inf  .nan  and their capitalised spellings
       str       everything else

     So yes, no, on, off, y and n are STRINGS. A sexagesimal such as
     190:20:30 is a STRING. 0b1010 is a STRING - 1.2 has no binary literal.
     012 is the INTEGER TWELVE, because 1.2 dropped the leading-zero octal
     of 1.1 and spells octal 0o14 instead. Those are the differences that
     silently change data when a 1.1 parser reads a 1.2 document, and they
     are the ones this library is tested on.

     A quoted, literal or folded scalar is ALWAYS a string. "true" is the
     four-letter word, and this library will not decide otherwise.

  2. ANCHORS AND ALIASES ARE GRAPH SEMANTICS, NOT COPY AND PASTE.

     An alias says two members of a document are THE SAME NODE. Nothing
     else in this library can say that, so an alias is never silently
     duplicated into two equal values.

       * The representation graph keeps it: an alias is a node of its own,
         of kind Alias, carrying the anchor name. TYamlDocument.ResolveAnchor
         hands back the node it names.
       * STRUCTURAL conversion keeps it too: an alias becomes an Extended
         node tagged TDynamicTag.YamlAlias whose payload is the anchor name,
         so a destination that cannot express sharing SEES the alias rather
         than a copy it cannot tell from an original.
       * CONTRACT deserialization EXPANDS it, because a Delphi record has no
         way to be two members at once. Expansion is budgeted - see 4.

     A cyclic alias - the classic &a [ *a ] - is legal YAML and has no
     Delphi shape at all. It is detected and refused with
     EYamlAliasCycleError. The parser itself never follows an alias, so a
     cycle cannot hang it.

  3. A STREAM OF N DOCUMENTS IS N DOCUMENTS.

     ParseStream returns them all. SerializeAll writes them all. Nothing
     collapses a stream silently:

       Deserialize<T>    requires exactly one document and names
                         DeserializeAll<T> when it finds more.
       DeserializeAll<T> returns one T per document.
       ToDynamic         yields the single document's tree for a
                         one-document stream, and an ARRAY of the documents
                         for a stream of more than one. So
                         TSerialization.Convert of a three-document stream
                         produces a three-element array, not the first
                         document.
       FromDynamic       writes ONE document. An array at the root becomes
                         a sequence inside that document, not three
                         documents - the dynamic tree has no way to say
                         which of the two was meant.

  4. A DUPLICATE KEY IS AN ERROR, AND SO IS AN ALIAS BOMB.

     The specification says the keys of a mapping are unique, so a repeated
     key raises EYamlDuplicateKeyError by default. SetDuplicateKeyPolicy
     relaxes that to LastWins or FirstWins for a caller who has to read
     somebody else's file.

     The billion laughs attack is a YAML attack: ten aliases per level, ten
     levels, and a small document expands into gigabytes. Expansion
     therefore carries both a depth budget and a node budget, and exceeding
     either raises EYamlLimitExceeded rather than allocating. SetLimits
     moves them.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections,
  PascalForge.Serialization.Core, PascalForge.Dynamic;

type
  EYamlError = class(Exception);

  { The document is at fault. Every parse failure names a line and a column,
    because "invalid YAML" without a position is useless on a file of any
    size. }
  EYamlParseError = class(EYamlError)
  strict private
    FLine: Integer;
    FColumn: Integer;
  public
    constructor CreateAt(ALine, AColumn: Integer; const AReason: string);
    property Line: Integer read FLine;
    property Column: Integer read FColumn;
  end;

  { A tab character used where indentation was expected. YAML forbids this
    outright, and it has its own class because it is the single most common
    way a hand-written YAML file goes wrong and the error message for it has
    to say what to do instead. }
  EYamlTabIndentationError = class(EYamlParseError);

  { A quoted scalar that reaches the end of the stream without its closing
    quote. }
  EYamlUnclosedQuoteError = class(EYamlParseError);

  { The same key twice in one mapping, under the default policy. }
  EYamlDuplicateKeyError = class(EYamlParseError);

  EYamlAliasError = class(EYamlError);
  { An alias naming an anchor the document never defined. }
  EYamlUnresolvedAliasError = class(EYamlAliasError);
  { An alias that, followed, would arrive back at itself. }
  EYamlAliasCycleError = class(EYamlAliasError);

  { A depth or expansion budget was reached. Refusing is the point: the
    alternative is to allocate what the document asked for. }
  EYamlLimitExceeded = class(EYamlError);

  { The document parsed, but says something the Delphi contract cannot
    accept. }
  EYamlInputError = class(EYamlError);
  { The model or the configuration is at fault. }
  EYamlInternalError = class(EYamlError);

{ ===========================================================================
  THE REPRESENTATION GRAPH

  YAML's own node model, as the specification describes it: a scalar, a
  sequence, a mapping, or an alias to a node one of those three anchored.

  A mapping's KEY IS A NODE, not a string. YAML allows a sequence or a
  mapping as a key - the "? key : value" form - and flattening those to text
  at parse time would throw away the only chance to see them.
  =========================================================================== }

type
  TYamlKind = (Scalar, Sequence, Mapping, Alias);

  { How a scalar was written. It is kept because it is the difference
    between the word true and the boolean: a plain scalar is resolved by the
    schema, and every other style is a string. }
  TYamlScalarStyle = (Plain, SingleQuoted, DoubleQuoted, Literal, Folded);

  { What the 1.2 core schema says a scalar IS. }
  TYamlScalarType = (Str, Null, Bool, Int, Float);

  { How the trailing line breaks of a block scalar are treated. }
  TYamlChomping = (Clip, Strip, Keep);

  { The core schema, as a set of pure functions over text. Public because
    "does this library resolve yes as a boolean" is a question worth being
    able to ask directly, and because the answer is the same everywhere. }
  TYamlSchema = record
  public const
    { The tag namespace of YAML's own type repository - what the secondary
      handle "!!" expands to. }
    DefaultPrefix = 'tag:yaml.org,2002:';
    TagStr        = 'tag:yaml.org,2002:str';
    TagNull       = 'tag:yaml.org,2002:null';
    TagBool       = 'tag:yaml.org,2002:bool';
    TagInt        = 'tag:yaml.org,2002:int';
    TagFloat      = 'tag:yaml.org,2002:float';
    TagSeq        = 'tag:yaml.org,2002:seq';
    TagMap        = 'tag:yaml.org,2002:map';
    { Base64, from YAML's type repository. It is the published way to put
      bytes in a YAML document, which is why TBytes uses it. }
    TagBinary     = 'tag:yaml.org,2002:binary';
    { Not part of the 1.2 core schema. It is recognized when a document
      writes it, because then the document itself said so - but a plain
      scalar that merely looks like a date stays a string. }
    TagTimestamp  = 'tag:yaml.org,2002:timestamp';
  public
    { The core schema's resolution of a PLAIN scalar. Never applied to a
      quoted, literal or folded one. }
    class function Resolve(const AText: string): TYamlScalarType; static;
    class function IsNullText(const AText: string): Boolean; static;
    class function IsBoolText(const AText: string;
      out AValue: Boolean): Boolean; static;
    class function TryToInt64(const AText: string;
      out AValue: Int64): Boolean; static;
    { For the decimal integers above High(Int64) that still fit unsigned. }
    class function TryToUInt64(const AText: string;
      out AValue: UInt64): Boolean; static;
    class function TryToDouble(const AText: string;
      out AValue: Double): Boolean; static;
    { The shortest text that reads back as exactly this Double, with .inf,
      -.inf and .nan for the three values decimal digits cannot spell. }
    class function FloatToText(AValue: Double): string; static;
    { True when a plain scalar of this text would be read back as something
      other than a string, so an emitter has to quote it. }
    class function NeedsQuotingAsString(const AText: string): Boolean; static;
  end;

  TYamlNode = class
  strict private
    FKind: TYamlKind;
    FStyle: TYamlScalarStyle;
    FValue: string;
    FTag: string;
    FAnchor: string;
    FItems: TObjectList<TYamlNode>;
    FKeys: TObjectList<TYamlNode>;
    function GetCount: Integer;
    function GetItem(AIndex: Integer): TYamlNode;
    function GetKey(AIndex: Integer): TYamlNode;
  public
    constructor Create(AKind: TYamlKind);
    destructor Destroy; override;

    class function NewScalar(const AText: string;
      AStyle: TYamlScalarStyle = TYamlScalarStyle.Plain): TYamlNode; static;
    class function NewNull: TYamlNode; static;
    class function NewBool(AValue: Boolean): TYamlNode; static;
    class function NewInt(AValue: Int64): TYamlNode; static;
    class function NewFloat(AValue: Double): TYamlNode; static;
    class function NewSequence: TYamlNode; static;
    class function NewMapping: TYamlNode; static;
    { An alias to AAnchor. Carries no content of its own - by design: the
      content belongs to the node that was anchored. }
    class function NewAlias(const AAnchor: string): TYamlNode; static;

    { Sequence: appends. Adopts AValue. }
    procedure Add(AValue: TYamlNode); overload;
    { Mapping: appends the pair. Adopts both, including on failure. }
    procedure Add(AKey, AValue: TYamlNode); overload;
    { Mapping, for the ordinary case of a plain string key. }
    procedure AddPair(const AName: string; AValue: TYamlNode);
    { Mapping: replaces the pair at AIndex, freeing what was there. Adopts
      both. This exists for the duplicate-key policies: LastWins has to
      replace the earlier pair IN PLACE rather than append a second one,
      because Find returns the first match and a document with two entries
      under one key is exactly what the policy is there to avoid. }
    procedure Replace(AIndex: Integer; AKey, AValue: TYamlNode);
    { The value whose key is the scalar AName, or nil. }
    function Find(const AName: string): TYamlNode;
    { The text of the key at AIndex. '' when the key is not a scalar - use
      Keys[AIndex] for those. }
    function KeyText(AIndex: Integer): string;
    function HasKey(const AName: string): Boolean;

    { What the core schema makes of this node. A quoted, literal or folded
      scalar is always Str; a tag, when the document gave one, wins over
      the schema. }
    function ScalarType: TYamlScalarType;
    function IsNull: Boolean;
    function AsBoolean: Boolean;
    function AsInt64: Int64;
    function AsDouble: Double;
    { The scalar's text, exactly as it resolved - no schema applied. }
    function AsString: string;
    { Base64 of a !!binary scalar, decoded. }
    function AsBytes: TBytes;

    function Describe: string;
    function Clone: TYamlNode;

    property Kind: TYamlKind read FKind;
    property Style: TYamlScalarStyle read FStyle write FStyle;
    { Scalar text, or - for an Alias - the anchor name it refers to. }
    property Value: string read FValue write FValue;
    { The resolved tag URI, or '' when the document gave none. }
    property Tag: string read FTag write FTag;
    { The anchor this node carries, or ''. }
    property Anchor: string read FAnchor write FAnchor;
    property Count: Integer read GetCount;
    property Items[AIndex: Integer]: TYamlNode read GetItem; default;
    property Keys[AIndex: Integer]: TYamlNode read GetKey;
  end;

  { One %TAG directive: a handle such as '!e!' and the prefix it stands for. }
  TYamlTagDirective = record
    Handle: string;
    Prefix: string;
  end;

  TYamlDocument = class
  strict private
    FRoot: TYamlNode;
    FVersion: string;
    FTagDirectives: TArray<TYamlTagDirective>;
    FExplicitStart: Boolean;
    FExplicitEnd: Boolean;
    FAnchors: TDictionary<string, TYamlNode>;
    procedure SetRoot(AValue: TYamlNode);
  public
    constructor Create;
    destructor Destroy; override;

    { The node AName anchors, or nil. The node is BORROWED - it lives in
      this document's tree. }
    function ResolveAnchor(const AName: string): TYamlNode;
    procedure RegisterAnchor(const AName: string; ANode: TYamlNode);
    function AnchorNames: TArray<string>;

    { Adopts. }
    property Root: TYamlNode read FRoot write SetRoot;
    { '1.2' when the document carried a %YAML directive, '' otherwise. }
    property Version: string read FVersion write FVersion;
    property TagDirectives: TArray<TYamlTagDirective>
      read FTagDirectives write FTagDirectives;
    { True when the document was introduced by '---'. }
    property ExplicitStart: Boolean read FExplicitStart write FExplicitStart;
    { True when the document was closed by '...'. }
    property ExplicitEnd: Boolean read FExplicitEnd write FExplicitEnd;
  end;

  TYamlStream = class
  strict private
    FDocuments: TObjectList<TYamlDocument>;
    function GetCount: Integer;
    function GetDocument(AIndex: Integer): TYamlDocument;
  public
    constructor Create;
    destructor Destroy; override;
    { Adopts. }
    procedure Add(ADocument: TYamlDocument);
    property Count: Integer read GetCount;
    property Documents[AIndex: Integer]: TYamlDocument
      read GetDocument; default;
  end;

{ ===========================================================================
  OPTIONS
  =========================================================================== }

type
  { Block style is the readable one and the default. Flow style is JSON-like
    and compact, for a caller who wants one line. }
  TYamlStyle = (Block, Flow);

  TYamlEmitOptions = record
  public
    Style: TYamlStyle;
    { Spaces per nesting level, for block style. }
    Indent: Integer;
    { Write '---' before the document even when there is only one. }
    ExplicitDocumentStart: Boolean;
    { Write '...' after each document. }
    ExplicitDocumentEnd: Boolean;
    class function Default: TYamlEmitOptions; static;
    class function FlowStyle: TYamlEmitOptions; static;
  end;

  { What to do about a mapping whose key appears twice. The specification
    says the keys are unique, so the default refuses. }
  TYamlDuplicateKeyPolicy = (Error, LastWins, FirstWins);

  { The two budgets that stop a small document becoming a large allocation. }
  TYamlLimits = record
  public
    { Nesting depth, in the parser and in alias expansion. }
    MaxDepth: Integer;
    { Total nodes produced by expanding aliases. The billion laughs attack
      is exactly a small document with a large expansion. }
    MaxExpandedNodes: Integer;
    class function Default: TYamlLimits; static;
  end;

{ ===========================================================================
  ATTRIBUTES - YAML's own, and only YAML's.
  =========================================================================== }

type
  YamlNameAttribute = class(TCustomAttribute)
  strict private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

  YamlIgnoreAttribute = class(TCustomAttribute)
  end;

  { How a TDate, TTime or TDateTime member is written. YAML's setting; it
    has no effect on JSON, XML or BSON. }
  TYamlDateTimeRepresentation = (
    { An ISO 8601 string, which is what a YAML consumer expects and what the
      1.2 core schema leaves as a string. The default. }
    Iso8601,
    { The same text, carrying the !!timestamp tag from YAML's type
      repository, so a reader that knows that tag gets a date rather than a
      string. }
    Timestamp,
    UnixSeconds,
    UnixMilliseconds,
    { A Delphi FormatDateTime pattern, written as a string. }
    CustomString);

  YamlDateTimeRepresentationAttribute = class(TCustomAttribute)
  strict private
    FRepresentation: TYamlDateTimeRepresentation;
    FPattern: string;
  public
    constructor Create(ARepresentation: TYamlDateTimeRepresentation); overload;
    constructor Create(const APattern: string); overload;
    property Representation: TYamlDateTimeRepresentation read FRepresentation;
    property Pattern: string read FPattern;
  end;

{ ===========================================================================
  CUSTOM SERIALIZERS - YAML's, not JSON's.
  =========================================================================== }

type
  TCustomYamlValueSerializer = class
  public
    { Returns the YAML node for AValue. The caller adopts it. }
    function Serialize(const AValue: TValue): TYamlNode; virtual; abstract;
    { AExisting is what the member already held; reuse it when it is an
      instance you can populate, and say so by returning it. }
    function Deserialize(AValue: TYamlNode; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; virtual; abstract;
  end;

  TYamlValueSerializerClass = class of TCustomYamlValueSerializer;

  { The typed base, and the one to use: it names the Delphi type, so an
    implementation never touches TValue or PTypeInfo. }
  TCustomYamlValueSerializer<T> = class(TCustomYamlValueSerializer)
  public
    function SerializeValue(const AValue: T): TYamlNode; virtual; abstract;
    function DeserializeValue(AValue: TYamlNode;
      const AExisting: T): T; virtual; abstract;

    function Serialize(const AValue: TValue): TYamlNode; override; final;
    function Deserialize(AValue: TYamlNode; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; override; final;
  end;

  YamlSerializerAttribute = class(TCustomAttribute)
  strict private
    FSerializerClass: TYamlValueSerializerClass;
  public
    constructor Create(ASerializerClass: TYamlValueSerializerClass);
    property SerializerClass: TYamlValueSerializerClass read FSerializerClass;
  end;

{ =========================================================================== }

type
  TYamlSerializer = class
  strict private
    { A generic method body declared in an interface section may reference
      only interface-declared symbols, so every generic entry point below is
      a thin shell over one of these. }
    class function DoSerialize(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AOptions: TYamlEmitOptions): string; static;
    class function DoDeserialize(ATypeInfo: PTypeInfo;
      const AYaml: string): TValue; static;
    class procedure DoPopulate(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AYaml: string); static;
    class function DoFrom(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): string; static;
    class procedure DoSetDateTimePolicy(ATypeInfo: PTypeInfo;
      const AFieldName: string; ARepresentation: TYamlDateTimeRepresentation;
      const APattern: string); static;
    class procedure DoRegisterEnumMapping(ATypeInfo: PTypeInfo;
      const AValues: array of string); static;
    class procedure DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TYamlValueSerializerClass); static;
  public
    { --- the normal API ---------------------------------------------------- }
    class function Serialize<T>(const AValue: T): string; overload; static;
    class function Serialize<T>(const AValue: T;
      const AOptions: TYamlEmitOptions): string; overload; static;
    { Exactly one document. A stream of more raises, naming DeserializeAll. }
    class function Deserialize<T>(const AYaml: string): T; static;
    class procedure Populate<T>(const AInstance: T; const AYaml: string); static;

    { --- multi-document streams --------------------------------------------

      A YAML stream is a sequence of documents and this library never
      pretends otherwise. These two are the typed door to that. }
    class function SerializeAll<T>(const AValues: TArray<T>): string; overload; static;
    class function SerializeAll<T>(const AValues: TArray<T>;
      const AOptions: TYamlEmitOptions): string; overload; static;
    class function DeserializeAll<T>(const AYaml: string): TArray<T>; static;

    { --- the representation graph -------------------------------------------

      For a document with no Delphi contract: anchors, aliases, tags,
      directives and complex keys, all still visible. The caller owns what
      these return. }
    class function ParseStream(const AYaml: string): TYamlStream; static;
    { Exactly one document; raises otherwise. }
    class function ParseDocument(const AYaml: string): TYamlDocument; static;
    class function SerializeStream(AStream: TYamlStream): string; overload; static;
    class function SerializeStream(AStream: TYamlStream;
      const AOptions: TYamlEmitOptions): string; overload; static;
    class function SerializeDocument(ADocument: TYamlDocument): string; overload; static;
    class function SerializeDocument(ADocument: TYamlDocument;
      const AOptions: TYamlEmitOptions): string; overload; static;

    { A copy of ADocument with every alias replaced by the node it names.
      The caller owns the copy; ADocument is untouched.

      This is where the budgets bite. A cyclic alias raises
      EYamlAliasCycleError and an alias bomb raises EYamlLimitExceeded -
      neither is expanded, and neither is allowed to run the process out of
      memory first. }
    class function Expand(ADocument: TYamlDocument): TYamlDocument; static;

    { --- destination-oriented conversion -----------------------------------

      YAML is the destination and is known at compile time, so only the
      SOURCE format is looked up, through the registry. This unit has no
      compile-time dependency on any other format. }
    class function From(const ASource: string;
      AFrom: TSerializationFormat): string; overload; static;
    class function From(const ASource: TBytes;
      AFrom: TSerializationFormat): string; overload; static;
    class function From(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): string; overload; static;
    class function From(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat;
      AProfile: TStructuralConversionProfile): string; overload; static;

    class function From<T>(const ASource: string;
      AFrom: TSerializationFormat): string; overload; static;
    class function From<T>(const ASource: TBytes;
      AFrom: TSerializationFormat): string; overload; static;
    class function From<T>(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): string; overload; static;

    { --- configuration ------------------------------------------------------ }

    class procedure SetDefaultEmitOptions(
      const AOptions: TYamlEmitOptions); static;
    class function DefaultEmitOptions: TYamlEmitOptions; static;
    class procedure SetDuplicateKeyPolicy(
      APolicy: TYamlDuplicateKeyPolicy); static;
    class function DuplicateKeyPolicy: TYamlDuplicateKeyPolicy; static;
    class procedure SetLimits(const ALimits: TYamlLimits); static;
    class function Limits: TYamlLimits; static;

    class procedure SetDateTimeRepresentation(
      ARepresentation: TYamlDateTimeRepresentation); overload; static;
    class procedure SetDateTimeRepresentation(
      const APattern: string); overload; static;
    class procedure RegisterDateTimeRepresentation<T>(
      ARepresentation: TYamlDateTimeRepresentation); overload; static;
    class procedure RegisterFieldDateTimeRepresentation<T>(
      const AFieldName: string;
      ARepresentation: TYamlDateTimeRepresentation); overload; static;

    class procedure RegisterEnumMapping<T>(
      const AValues: array of string); static;
    class procedure RegisterTypeSerializer<T>(
      ASerializerClass: TYamlValueSerializerClass); static;

    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;

    { --- dynamic ---------------------------------------------------------

      A YAML stream as a dynamic value - the document's tree for a
      one-document stream, an array of documents for a longer one - and a
      dynamic value as ONE YAML document. Tags and aliases this library
      does not resolve are Extended values. The tree is the caller's. }
    class function ToDynamic(const AYaml: string): TDynamicValue; overload; static;
    class function ToDynamic(const AYaml: string;
      const AOptions: TStructuralConversionOptions): TDynamicValue; overload; static;
    class function FromDynamic(AValue: TDynamicValue): string; overload; static;
    class function FromDynamic(AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions): string; overload; static;
    class procedure ResetConfiguration; static;
  end;

implementation

uses
  System.Math, System.NetEncoding,
  PascalForge.Yaml.Internal;

{ ------------------------------------------------------------ exceptions --- }

constructor EYamlParseError.CreateAt(ALine, AColumn: Integer;
  const AReason: string);
begin
  inherited CreateFmt('%s (line %d, column %d)', [AReason, ALine, AColumn]);
  FLine := ALine;
  FColumn := AColumn;
end;

{ ----------------------------------------------------------- TYamlSchema --- }

class function TYamlSchema.IsNullText(const AText: string): Boolean;
begin
  Result := (AText = '') or (AText = '~') or (AText = 'null') or
            (AText = 'Null') or (AText = 'NULL');
end;

class function TYamlSchema.IsBoolText(const AText: string;
  out AValue: Boolean): Boolean;
begin
  AValue := False;
  { The core schema lists six spellings and six only. "yes", "on" and "y"
    are 1.1's, and reading them as booleans is the single most damaging
    difference between the two revisions - it turns the country code NO into
    False. }
  if (AText = 'true') or (AText = 'True') or (AText = 'TRUE') then
  begin
    AValue := True;
    Exit(True);
  end;
  Result := (AText = 'false') or (AText = 'False') or (AText = 'FALSE');
end;

{ Digits only, at least one, in the given base. }
function AllDigitsIn(const AText: string; AStart: Integer;
  ABase: Integer): Boolean;
var
  I: Integer;
  C: Char;
begin
  if AStart > Length(AText) then Exit(False);
  for I := AStart to Length(AText) do
  begin
    C := AText[I];
    case ABase of
      8: if not CharInSet(C, ['0'..'7']) then Exit(False);
      10: if not CharInSet(C, ['0'..'9']) then Exit(False);
      16: if not CharInSet(C, ['0'..'9', 'a'..'f', 'A'..'F']) then Exit(False);
    else
      Exit(False);
    end;
  end;
  Result := True;
end;

{ The shape of the core schema's int production, without converting. }
function LooksLikeCoreInt(const AText: string): Boolean;
var
  Start: Integer;
begin
  if AText = '' then Exit(False);
  Start := 1;
  if CharInSet(AText[1], ['-', '+']) then Start := 2;
  if AllDigitsIn(AText, Start, 10) then Exit(True);
  { 0o and 0x carry no sign in the core schema's own grammar, so neither
    does this. }
  if Start <> 1 then Exit(False);
  if (Length(AText) > 2) and (AText[1] = '0') and (AText[2] = 'o') then
    Exit(AllDigitsIn(AText, 3, 8));
  if (Length(AText) > 2) and (AText[1] = '0') and (AText[2] = 'x') then
    Exit(AllDigitsIn(AText, 3, 16));
  Result := False;
end;

function LooksLikeCoreFloat(const AText: string): Boolean;
var
  I, Start, Digits: Integer;
  SeenDot: Boolean;
  Body: string;
begin
  if AText = '' then Exit(False);
  Body := AText;
  Start := 1;
  if CharInSet(Body[1], ['-', '+']) then Start := 2;

  { The three values decimal digits cannot spell. .nan takes no sign. }
  if (Copy(Body, Start, MaxInt) = '.inf') or
     (Copy(Body, Start, MaxInt) = '.Inf') or
     (Copy(Body, Start, MaxInt) = '.INF') then Exit(True);
  if (Body = '.nan') or (Body = '.NaN') or (Body = '.NAN') then Exit(True);

  SeenDot := False;
  Digits := 0;
  I := Start;
  while I <= Length(Body) do
  begin
    case Body[I] of
      '0'..'9': Inc(Digits);
      '.':
        begin
          if SeenDot then Exit(False);
          SeenDot := True;
        end;
      { The exponent ends the scan either way, so nothing after it is read
        as mantissa: a second point or a second e is simply not a digit. }
      'e', 'E':
        begin
          if Digits = 0 then Exit(False);
          if (I < Length(Body)) and CharInSet(Body[I + 1], ['-', '+']) then
            Inc(I);
          if (I >= Length(Body)) or not AllDigitsIn(Body, I + 1, 10) then
            Exit(False);
          Exit(True);
        end;
    else
      Exit(False);
    end;
    Inc(I);
  end;
  { A bare run of digits is an int, not a float, so a float needs the point
    - and a lone point is nothing at all. }
  Result := SeenDot and (Digits > 0);
end;

class function TYamlSchema.Resolve(const AText: string): TYamlScalarType;
var
  B: Boolean;
begin
  if IsNullText(AText) then Exit(TYamlScalarType.Null);
  if IsBoolText(AText, B) then Exit(TYamlScalarType.Bool);
  if LooksLikeCoreInt(AText) then Exit(TYamlScalarType.Int);
  if LooksLikeCoreFloat(AText) then Exit(TYamlScalarType.Float);
  Result := TYamlScalarType.Str;
end;

class function TYamlSchema.TryToInt64(const AText: string;
  out AValue: Int64): Boolean;
var
  Body: string;
  Negative: Boolean;
  U: UInt64;
begin
  AValue := 0;
  if not LooksLikeCoreInt(AText) then Exit(False);
  Body := AText;
  Negative := False;
  if (Body <> '') and CharInSet(Body[1], ['-', '+']) then
  begin
    Negative := Body[1] = '-';
    Delete(Body, 1, 1);
  end;
  { Written out rather than folded into the expression above, because the
    three bases need three different conversions and a clever one-liner here
    was wrong twice. }
  if (Length(Body) > 2) and (Body[1] = '0') and (Body[2] = 'o') then
  begin
    AValue := 0;
    Result := True;
    for var I := 3 to Length(Body) do
    begin
      if AValue > (High(Int64) - (Ord(Body[I]) - Ord('0'))) div 8 then
        Exit(False);
      AValue := AValue * 8 + (Ord(Body[I]) - Ord('0'));
    end;
  end
  else if (Length(Body) > 2) and (Body[1] = '0') and (Body[2] = 'x') then
  begin
    { Unsigned, then range-checked, as the octal loop is: the RTL's '$'
      branch takes any sixteen hex digits as a bit pattern, so
      0xFFFFFFFFFFFFFFFF came back as -1 and passed every range check. }
    Result := TryStrToUInt64('$' + Copy(Body, 3, MaxInt), U) and
      (U <= UInt64(High(Int64)));
    if Result then AValue := Int64(U) else AValue := 0;
  end
  else
    { Decimal digits keep their sign. Low(Int64) has no positive twin, so
      stripping the minus and negating afterwards overflowed on exactly
      that value - and the reader then called it a string. }
    Exit(TryStrToInt64(AText, AValue));

  if Result and Negative then AValue := -AValue;
end;

class function TYamlSchema.TryToUInt64(const AText: string;
  out AValue: UInt64): Boolean;
begin
  AValue := 0;
  if not LooksLikeCoreInt(AText) then Exit(False);
  if (AText <> '') and (AText[1] = '-') then Exit(False);
  if (AText <> '') and (AText[1] = '+') then
    Exit(TryStrToUInt64(Copy(AText, 2, MaxInt), AValue));
  if (Length(AText) > 2) and (AText[1] = '0') and (AText[2] = 'x') then
    Exit(TryStrToUInt64('$' + Copy(AText, 3, MaxInt), AValue));
  Result := TryStrToUInt64(AText, AValue);
end;

class function TYamlSchema.TryToDouble(const AText: string;
  out AValue: Double): Boolean;
var
  Body: string;
  Negative: Boolean;
  I: Int64;
  U: UInt64;
begin
  AValue := 0;
  if TryToInt64(AText, I) then
  begin
    AValue := I;
    Exit(True);
  end;
  { An int above High(Int64) is still a number: 0x8000000000000000 and
    9223372036854775808 are positive, and a Double holds them. }
  if TryToUInt64(AText, U) then
  begin
    AValue := U;
    Exit(True);
  end;
  if not LooksLikeCoreFloat(AText) then Exit(False);
  Body := AText;
  Negative := False;
  if (Body <> '') and CharInSet(Body[1], ['-', '+']) then
  begin
    Negative := Body[1] = '-';
    Delete(Body, 1, 1);
  end;
  if (Body = '.inf') or (Body = '.Inf') or (Body = '.INF') then
  begin
    if Negative then AValue := Double.NegativeInfinity
    else AValue := Double.PositiveInfinity;
    Exit(True);
  end;
  if (Body = '.nan') or (Body = '.NaN') or (Body = '.NAN') then
  begin
    AValue := Double.NaN;
    Exit(True);
  end;
  { Correctly rounded on both platforms; the RTL's TryStrToFloat misreads
    17-digit text on Win64 and refuses 1.7976931348623158E308 on Win32. }
  Result := TStructuralText.TryParseFloat(Body, AValue);
  if Result and Negative then AValue := -AValue;
end;

class function TYamlSchema.FloatToText(AValue: Double): string;
begin
  if AValue.IsNan then Exit('.nan');
  if AValue.IsPositiveInfinity then Exit('.inf');
  if AValue.IsNegativeInfinity then Exit('-.inf');
  { The shortest decimal that reads back identically, and -0 for minus
    zero, which FloatToStrF wrote as 0. }
  Result := TStructuralText.EncodeFloat(AValue);
  { A float has to look like one, or reading it back gives an integer. }
  if (Pos('.', Result) = 0) and (Pos('E', Result) = 0) and
     (Pos('e', Result) = 0) then
    Result := Result + '.0';
end;

class function TYamlSchema.NeedsQuotingAsString(const AText: string): Boolean;
begin
  Result := Resolve(AText) <> TYamlScalarType.Str;
end;

{ ------------------------------------------------------------- TYamlNode --- }

constructor TYamlNode.Create(AKind: TYamlKind);
begin
  inherited Create;
  FKind := AKind;
  if AKind in [TYamlKind.Sequence, TYamlKind.Mapping] then
    FItems := TObjectList<TYamlNode>.Create(True);
  if AKind = TYamlKind.Mapping then
    FKeys := TObjectList<TYamlNode>.Create(True);
end;

destructor TYamlNode.Destroy;
begin
  FKeys.Free;
  FItems.Free;
  inherited Destroy;
end;

class function TYamlNode.NewScalar(const AText: string;
  AStyle: TYamlScalarStyle): TYamlNode;
begin
  Result := TYamlNode.Create(TYamlKind.Scalar);
  Result.FValue := AText;
  Result.FStyle := AStyle;
end;

class function TYamlNode.NewNull: TYamlNode;
begin
  Result := NewScalar('null');
end;

class function TYamlNode.NewBool(AValue: Boolean): TYamlNode;
begin
  if AValue then Result := NewScalar('true') else Result := NewScalar('false');
end;

class function TYamlNode.NewInt(AValue: Int64): TYamlNode;
begin
  Result := NewScalar(IntToStr(AValue));
end;

class function TYamlNode.NewFloat(AValue: Double): TYamlNode;
begin
  Result := NewScalar(TYamlSchema.FloatToText(AValue));
end;

class function TYamlNode.NewSequence: TYamlNode;
begin
  Result := TYamlNode.Create(TYamlKind.Sequence);
end;

class function TYamlNode.NewMapping: TYamlNode;
begin
  Result := TYamlNode.Create(TYamlKind.Mapping);
end;

class function TYamlNode.NewAlias(const AAnchor: string): TYamlNode;
begin
  Result := TYamlNode.Create(TYamlKind.Alias);
  Result.FValue := AAnchor;
end;

function TYamlNode.GetCount: Integer;
begin
  if FItems = nil then Exit(0);
  Result := Integer(FItems.Count);
end;

function TYamlNode.GetItem(AIndex: Integer): TYamlNode;
begin
  Result := FItems[AIndex];
end;

function TYamlNode.GetKey(AIndex: Integer): TYamlNode;
begin
  if FKeys = nil then
    raise EYamlInternalError.Create('Only a mapping has keys.');
  Result := FKeys[AIndex];
end;

procedure TYamlNode.Add(AValue: TYamlNode);
begin
  if FKind <> TYamlKind.Sequence then
  begin
    AValue.Free;
    raise EYamlInternalError.Create(
      'Only a sequence takes a value without a key.');
  end;
  FItems.Add(AValue);
end;

procedure TYamlNode.Add(AKey, AValue: TYamlNode);
begin
  if FKind <> TYamlKind.Mapping then
  begin
    AKey.Free;
    AValue.Free;
    raise EYamlInternalError.Create('Only a mapping takes a key and a value.');
  end;
  FKeys.Add(AKey);
  try
    FItems.Add(AValue);
  except
    FKeys.Delete(FKeys.Count - 1);
    AValue.Free;
    raise;
  end;
end;

procedure TYamlNode.Replace(AIndex: Integer; AKey, AValue: TYamlNode);
begin
  if FKind <> TYamlKind.Mapping then
  begin
    AKey.Free;
    AValue.Free;
    raise EYamlInternalError.Create(
      'Replace is a mapping operation and this node is not a mapping.');
  end;
  if (AIndex < 0) or (AIndex >= FKeys.Count) then
  begin
    AKey.Free;
    AValue.Free;
    raise EYamlInternalError.CreateFmt(
      'There is no pair at index %d to replace.', [AIndex]);
  end;
  { The lists own their items, so assigning through the list frees what was
    there - which is what makes this a replacement and not a leak. }
  FKeys[AIndex] := AKey;
  FItems[AIndex] := AValue;
end;

procedure TYamlNode.AddPair(const AName: string; AValue: TYamlNode);
begin
  Add(NewScalar(AName), AValue);
end;

function TYamlNode.KeyText(AIndex: Integer): string;
begin
  if (FKeys = nil) or (FKeys[AIndex].Kind <> TYamlKind.Scalar) then Exit('');
  Result := FKeys[AIndex].Value;
end;

function TYamlNode.Find(const AName: string): TYamlNode;
var
  I: Integer;
begin
  if FKeys = nil then Exit(nil);
  for I := 0 to Integer(FKeys.Count - 1) do
    if (FKeys[I].Kind = TYamlKind.Scalar) and (FKeys[I].Value = AName) then
      Exit(FItems[I]);
  Result := nil;
end;

function TYamlNode.HasKey(const AName: string): Boolean;
begin
  Result := Find(AName) <> nil;
end;

function TYamlNode.ScalarType: TYamlScalarType;
begin
  if FKind <> TYamlKind.Scalar then
    raise EYamlInternalError.CreateFmt(
      'Asked what kind of scalar %s is, and it is not a scalar.', [Describe]);
  { A tag the document itself wrote wins: it is the document saying what the
    value is, which outranks a schema guessing from the characters. }
  if FTag <> '' then
  begin
    if FTag = TYamlSchema.TagStr then Exit(TYamlScalarType.Str);
    if FTag = TYamlSchema.TagNull then Exit(TYamlScalarType.Null);
    if FTag = TYamlSchema.TagBool then Exit(TYamlScalarType.Bool);
    if FTag = TYamlSchema.TagInt then Exit(TYamlScalarType.Int);
    if FTag = TYamlSchema.TagFloat then Exit(TYamlScalarType.Float);
    Exit(TYamlScalarType.Str);
  end;
  { Quoting is how a YAML document says "this is text". Resolving a quoted
    scalar would undo that. }
  if FStyle <> TYamlScalarStyle.Plain then Exit(TYamlScalarType.Str);
  Result := TYamlSchema.Resolve(FValue);
end;

function TYamlNode.IsNull: Boolean;
begin
  Result := (FKind = TYamlKind.Scalar) and
            (ScalarType = TYamlScalarType.Null);
end;

function TYamlNode.AsBoolean: Boolean;
begin
  if (FKind <> TYamlKind.Scalar) or
     not TYamlSchema.IsBoolText(FValue, Result) then
    raise EYamlInputError.CreateFmt('Expected a boolean, found %s.',
      [Describe]);
end;

function TYamlNode.AsInt64: Int64;
begin
  if (FKind <> TYamlKind.Scalar) or
     not TYamlSchema.TryToInt64(FValue, Result) then
  begin
    { 0xFFFFFFFFFFFFFFFF is an integer, just not one an Int64 holds - and
      "expected an integer, found an integer" said nothing. }
    if (FKind = TYamlKind.Scalar) and (ScalarType = TYamlScalarType.Int) then
      raise EYamlInputError.CreateFmt(
        '%s is an integer outside the range of Int64.', [FValue]);
    raise EYamlInputError.CreateFmt('Expected an integer, found %s.',
      [Describe]);
  end;
end;

function TYamlNode.AsDouble: Double;
begin
  if (FKind <> TYamlKind.Scalar) or
     not TYamlSchema.TryToDouble(FValue, Result) then
    raise EYamlInputError.CreateFmt('Expected a number, found %s.',
      [Describe]);
end;

function TYamlNode.AsString: string;
begin
  if FKind <> TYamlKind.Scalar then
    raise EYamlInputError.CreateFmt('Expected a scalar, found %s.',
      [Describe]);
  Result := FValue;
end;

function TYamlNode.AsBytes: TBytes;
var
  Cleaned: string;
  C: Char;
begin
  if FKind <> TYamlKind.Scalar then
    raise EYamlInputError.CreateFmt('Expected a scalar, found %s.',
      [Describe]);
  { Base64 in YAML is habitually written as a block scalar over several
    lines, so the line breaks and the indentation whitespace are not part of
    the data. }
  Cleaned := '';
  for C in FValue do
    if not CharInSet(C, [#9, #10, #13, ' ']) then Cleaned := Cleaned + C;
  if not TStructuralText.TryDecodeBinary(Cleaned, Result) then
    raise EYamlInputError.Create(
      'A !!binary scalar has to be base64, and this one is not.');
end;

function TYamlNode.Describe: string;
begin
  case FKind of
    TYamlKind.Scalar:
      case ScalarType of
        TYamlScalarType.Null: Result := 'a null scalar';
        TYamlScalarType.Bool: Result := 'a boolean';
        TYamlScalarType.Int: Result := 'an integer';
        TYamlScalarType.Float: Result := 'a float';
      else
        Result := Format('the string "%s"', [FValue]);
      end;
    TYamlKind.Sequence: Result := Format('a sequence of %d items', [Count]);
    TYamlKind.Mapping: Result := Format('a mapping of %d pairs', [Count]);
    TYamlKind.Alias: Result := Format('an alias to the anchor "%s"', [FValue]);
  else
    Result := 'an unknown node';
  end;
end;

function TYamlNode.Clone: TYamlNode;
var
  I: Integer;
begin
  Result := TYamlNode.Create(FKind);
  try
    Result.FValue := FValue;
    Result.FStyle := FStyle;
    Result.FTag := FTag;
    Result.FAnchor := FAnchor;
    case FKind of
      TYamlKind.Sequence:
        for I := 0 to Count - 1 do Result.Add(FItems[I].Clone);
      TYamlKind.Mapping:
        for I := 0 to Count - 1 do
          Result.Add(FKeys[I].Clone, FItems[I].Clone);
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ --------------------------------------------------------- TYamlDocument --- }

constructor TYamlDocument.Create;
begin
  inherited Create;
  FAnchors := TDictionary<string, TYamlNode>.Create;
end;

destructor TYamlDocument.Destroy;
begin
  FAnchors.Free;
  FRoot.Free;
  inherited Destroy;
end;

procedure TYamlDocument.SetRoot(AValue: TYamlNode);
begin
  if AValue = FRoot then Exit;
  FRoot.Free;
  FRoot := AValue;
end;

function TYamlDocument.ResolveAnchor(const AName: string): TYamlNode;
begin
  if not FAnchors.TryGetValue(AName, Result) then Result := nil;
end;

procedure TYamlDocument.RegisterAnchor(const AName: string; ANode: TYamlNode);
begin
  { The specification allows an anchor name to be reused; the later
    definition wins for aliases that follow it. }
  FAnchors.AddOrSetValue(AName, ANode);
end;

function TYamlDocument.AnchorNames: TArray<string>;
begin
  Result := FAnchors.Keys.ToArray;
end;

{ ----------------------------------------------------------- TYamlStream --- }

constructor TYamlStream.Create;
begin
  inherited Create;
  FDocuments := TObjectList<TYamlDocument>.Create(True);
end;

destructor TYamlStream.Destroy;
begin
  FDocuments.Free;
  inherited Destroy;
end;

procedure TYamlStream.Add(ADocument: TYamlDocument);
begin
  FDocuments.Add(ADocument);
end;

function TYamlStream.GetCount: Integer;
begin
  Result := Integer(FDocuments.Count);
end;

function TYamlStream.GetDocument(AIndex: Integer): TYamlDocument;
begin
  Result := FDocuments[AIndex];
end;

{ --------------------------------------------------------------- options --- }

class function TYamlEmitOptions.Default: TYamlEmitOptions;
begin
  Result.Style := TYamlStyle.Block;
  Result.Indent := 2;
  Result.ExplicitDocumentStart := False;
  Result.ExplicitDocumentEnd := False;
end;

class function TYamlEmitOptions.FlowStyle: TYamlEmitOptions;
begin
  Result := Default;
  Result.Style := TYamlStyle.Flow;
end;

class function TYamlLimits.Default: TYamlLimits;
begin
  { Deep enough for any document a human wrote and any machine-generated one
    this library has met; shallow enough that a malicious file of nothing
    but opening brackets runs out of budget long before it runs out of
    stack. }
  Result.MaxDepth := 200;
  Result.MaxExpandedNodes := 250000;
end;

{ ------------------------------------------------------------- attributes --- }

constructor YamlNameAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

constructor YamlDateTimeRepresentationAttribute.Create(
  ARepresentation: TYamlDateTimeRepresentation);
begin
  inherited Create;
  FRepresentation := ARepresentation;
  FPattern := '';
end;

constructor YamlDateTimeRepresentationAttribute.Create(const APattern: string);
begin
  inherited Create;
  FRepresentation := TYamlDateTimeRepresentation.CustomString;
  FPattern := APattern;
end;

constructor YamlSerializerAttribute.Create(
  ASerializerClass: TYamlValueSerializerClass);
begin
  inherited Create;
  FSerializerClass := ASerializerClass;
end;

{ ------------------------------------------------- typed custom serializer --- }

function TCustomYamlValueSerializer<T>.Serialize(
  const AValue: TValue): TYamlNode;
begin
  Result := SerializeValue(AValue.AsType<T>);
end;

function TCustomYamlValueSerializer<T>.Deserialize(AValue: TYamlNode;
  ATypeInfo: PTypeInfo; const AExisting: TValue): TValue;
var
  Existing: T;
begin
  if AExisting.IsEmpty then Existing := Default(T)
  else Existing := AExisting.AsType<T>;
  Result := TValue.From<T>(DeserializeValue(AValue, Existing));
end;

{ --------------------------------------------------------------- bridges --- }

class function TYamlSerializer.DoSerialize(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AOptions: TYamlEmitOptions): string;
begin
  Result := TYamlEngine.SerializeRoot(ATypeInfo, AValue, AOptions);
end;

class function TYamlSerializer.DoDeserialize(ATypeInfo: PTypeInfo;
  const AYaml: string): TValue;
begin
  Result := TYamlEngine.DeserializeRoot(ATypeInfo, AYaml, TValue.Empty);
end;

class procedure TYamlSerializer.DoPopulate(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AYaml: string);
begin
  TYamlEngine.DeserializeRoot(ATypeInfo, AYaml, AValue);
end;

class function TYamlSerializer.DoFrom(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload; AFrom: TSerializationFormat): string;
begin
  Result := TYamlEngine.FromPayload(ATypeInfo, ASource, AFrom);
end;

class procedure TYamlSerializer.DoSetDateTimePolicy(ATypeInfo: PTypeInfo;
  const AFieldName: string; ARepresentation: TYamlDateTimeRepresentation;
  const APattern: string);
begin
  TYamlEngine.SetDateTimePolicy(ATypeInfo, AFieldName, Ord(ARepresentation),
    APattern);
end;

class procedure TYamlSerializer.DoRegisterEnumMapping(ATypeInfo: PTypeInfo;
  const AValues: array of string);
begin
  TYamlEngine.RegisterEnumMapping(ATypeInfo, AValues);
end;

class procedure TYamlSerializer.DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TYamlValueSerializerClass);
begin
  TYamlEngine.RegisterTypeSerializer(ATypeInfo, ASerializerClass);
end;

{ ------------------------------------------------------------- operations --- }

class function TYamlSerializer.Serialize<T>(const AValue: T): string;
begin
  Result := Serialize<T>(AValue, TYamlEngine.DefaultEmitOptions);
end;

class function TYamlSerializer.Serialize<T>(const AValue: T;
  const AOptions: TYamlEmitOptions): string;
var
  V: TValue;
begin
  TValue.Make(@AValue, System.TypeInfo(T), V);
  Result := DoSerialize(System.TypeInfo(T), V, AOptions);
end;

class function TYamlSerializer.Deserialize<T>(const AYaml: string): T;
begin
  Result := DoDeserialize(System.TypeInfo(T), AYaml).AsType<T>;
end;

class procedure TYamlSerializer.Populate<T>(const AInstance: T;
  const AYaml: string);
var
  V: TValue;
begin
  TValue.Make(@AInstance, System.TypeInfo(T), V);
  DoPopulate(System.TypeInfo(T), V, AYaml);
end;

class function TYamlSerializer.SerializeAll<T>(
  const AValues: TArray<T>): string;
begin
  Result := SerializeAll<T>(AValues, TYamlEngine.DefaultEmitOptions);
end;

class function TYamlSerializer.SerializeAll<T>(const AValues: TArray<T>;
  const AOptions: TYamlEmitOptions): string;
var
  Values: TArray<TValue>;
  I: Integer;
begin
  SetLength(Values, Length(AValues));
  for I := 0 to Integer(High(AValues)) do
    TValue.Make(@AValues[I], System.TypeInfo(T), Values[I]);
  Result := TYamlEngine.SerializeRootAll(System.TypeInfo(T), Values, AOptions);
end;

class function TYamlSerializer.DeserializeAll<T>(
  const AYaml: string): TArray<T>;
var
  Values: TArray<TValue>;
  I: Integer;
begin
  Values := TYamlEngine.DeserializeRootAll(System.TypeInfo(T), AYaml);
  SetLength(Result, Length(Values));
  for I := 0 to Integer(High(Values)) do Result[I] := Values[I].AsType<T>;
end;

{ ------------------------------------------------- the representation graph --- }

class function TYamlSerializer.ParseStream(const AYaml: string): TYamlStream;
begin
  Result := TYamlEngine.ParseStream(AYaml);
end;

class function TYamlSerializer.ParseDocument(
  const AYaml: string): TYamlDocument;
begin
  Result := TYamlEngine.ParseSingleDocument(AYaml);
end;

class function TYamlSerializer.SerializeStream(AStream: TYamlStream): string;
begin
  Result := SerializeStream(AStream, TYamlEngine.DefaultEmitOptions);
end;

class function TYamlSerializer.SerializeStream(AStream: TYamlStream;
  const AOptions: TYamlEmitOptions): string;
begin
  Result := TYamlEngine.EmitStream(AStream, AOptions);
end;

class function TYamlSerializer.SerializeDocument(
  ADocument: TYamlDocument): string;
begin
  Result := SerializeDocument(ADocument, TYamlEngine.DefaultEmitOptions);
end;

class function TYamlSerializer.SerializeDocument(ADocument: TYamlDocument;
  const AOptions: TYamlEmitOptions): string;
begin
  Result := TYamlEngine.EmitDocument(ADocument, AOptions);
end;

class function TYamlSerializer.Expand(ADocument: TYamlDocument): TYamlDocument;
begin
  Result := TYamlEngine.ExpandDocument(ADocument);
end;

{ ------------------------------------------------------------ conversion --- }

class function TYamlSerializer.From(const ASource: string;
  AFrom: TSerializationFormat): string;
begin
  Result := From(TSerializationPayload.FromText(ASource), AFrom);
end;

class function TYamlSerializer.From(const ASource: TBytes;
  AFrom: TSerializationFormat): string;
begin
  Result := From(TSerializationPayload.FromBytes(ASource), AFrom);
end;

class function TYamlSerializer.From(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): string;
begin
  Result := From(ASource, AFrom, TStructuralConversionProfile.Natural);
end;

class function TYamlSerializer.From(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat;
  AProfile: TStructuralConversionProfile): string;
begin
  Result := TYamlEngine.FromPayloadStructural(ASource, AFrom, AProfile);
end;

class function TYamlSerializer.From<T>(const ASource: string;
  AFrom: TSerializationFormat): string;
begin
  Result := From<T>(TSerializationPayload.FromText(ASource), AFrom);
end;

class function TYamlSerializer.From<T>(const ASource: TBytes;
  AFrom: TSerializationFormat): string;
begin
  Result := From<T>(TSerializationPayload.FromBytes(ASource), AFrom);
end;

class function TYamlSerializer.From<T>(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): string;
begin
  Result := DoFrom(System.TypeInfo(T), ASource, AFrom);
end;

{ ---------------------------------------------------------- configuration --- }

class procedure TYamlSerializer.SetDefaultEmitOptions(
  const AOptions: TYamlEmitOptions);
begin
  TYamlEngine.SetDefaultEmitOptions(AOptions);
end;

class function TYamlSerializer.DefaultEmitOptions: TYamlEmitOptions;
begin
  Result := TYamlEngine.DefaultEmitOptions;
end;

class procedure TYamlSerializer.SetDuplicateKeyPolicy(
  APolicy: TYamlDuplicateKeyPolicy);
begin
  TYamlEngine.SetDuplicateKeyPolicy(APolicy);
end;

class function TYamlSerializer.DuplicateKeyPolicy: TYamlDuplicateKeyPolicy;
begin
  Result := TYamlEngine.DuplicateKeyPolicy;
end;

class procedure TYamlSerializer.SetLimits(const ALimits: TYamlLimits);
begin
  TYamlEngine.SetLimits(ALimits);
end;

class function TYamlSerializer.Limits: TYamlLimits;
begin
  Result := TYamlEngine.Limits;
end;

class procedure TYamlSerializer.SetDateTimeRepresentation(
  ARepresentation: TYamlDateTimeRepresentation);
begin
  TYamlEngine.SetDateTimePolicy(nil, '', Ord(ARepresentation), '');
end;

class procedure TYamlSerializer.SetDateTimeRepresentation(
  const APattern: string);
begin
  TYamlEngine.SetDateTimePolicy(nil, '',
    Ord(TYamlDateTimeRepresentation.CustomString), APattern);
end;

class procedure TYamlSerializer.RegisterDateTimeRepresentation<T>(
  ARepresentation: TYamlDateTimeRepresentation);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), '', ARepresentation, '');
end;

class procedure TYamlSerializer.RegisterFieldDateTimeRepresentation<T>(
  const AFieldName: string; ARepresentation: TYamlDateTimeRepresentation);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), AFieldName, ARepresentation, '');
end;

class procedure TYamlSerializer.RegisterEnumMapping<T>(
  const AValues: array of string);
begin
  DoRegisterEnumMapping(System.TypeInfo(T), AValues);
end;

class procedure TYamlSerializer.RegisterTypeSerializer<T>(
  ASerializerClass: TYamlValueSerializerClass);
begin
  DoRegisterTypeSerializer(System.TypeInfo(T), ASerializerClass);
end;

class procedure TYamlSerializer.FreezeConfiguration;
begin
  TYamlEngine.FreezeConfiguration;
end;

class function TYamlSerializer.IsFrozen: Boolean;
begin
  Result := TYamlEngine.IsFrozen;
end;

class procedure TYamlSerializer.ResetConfiguration;
begin
  TYamlEngine.ResetConfiguration;
end;


{ ---------------------------------------------------------------- dynamic --- }

class function TYamlSerializer.ToDynamic(const AYaml: string): TDynamicValue;
begin
  Result := ToDynamic(AYaml, TStructuralConversionOptions.Default);
end;

class function TYamlSerializer.ToDynamic(const AYaml: string;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
var
  Stream: TYamlStream;
begin
  Stream := TYamlEngine.ParseStream(AYaml);
  try
    Result := TYamlEngine.StreamToDynamic(Stream, AOptions);
  finally
    Stream.Free;
  end;
end;

class function TYamlSerializer.FromDynamic(AValue: TDynamicValue): string;
begin
  Result := FromDynamic(AValue, TStructuralConversionOptions.Default);
end;

class function TYamlSerializer.FromDynamic(AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): string;
var
  Doc: TYamlDocument;
begin
  { One document: an array at the root is a sequence inside it, not
    several documents. }
  Doc := TYamlDocument.Create;
  try
    Doc.Root := TYamlEngine.DynamicToYaml(AValue, AOptions);
    Result := TYamlEngine.EmitDocument(Doc, TYamlEngine.DefaultEmitOptions);
  finally
    Doc.Free;
  end;
end;

end.
