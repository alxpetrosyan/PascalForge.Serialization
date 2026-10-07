{*******************************************************************************
  PascalForge.Csv

  Public CSV serialization facade for PascalForge.Serialization.

  Responsibilities
    - Typed CSV serialization/deserialization of tabular values.
    - Explicit projection strategies for nested objects and collections.
    - CSV dialect options, document sets and customization API.

  Registration
    Direct TCsvSerializer use does not require format registration.
    Generic TSerialization operations require explicit registration:
    TCsvSerializationRegistration.RegisterFormat (PascalForge.Csv.Registration).

  Configuration
    Global serializer configuration becomes immutable after first use.

  Threading
    Serialization is safe for concurrent use after configuration is frozen.

  Documentation
    docs/formats/csv.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Csv;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  CSV serialization.

      Text := TCsvSerializer.Serialize<TArray<TCustomer>>(Customers);
      Back := TCsvSerializer.Deserialize<TArray<TCustomer>>(Text);

  CSV IS A TABLE, AND THIS UNIT DOES NOT PRETEND OTHERWISE.

  Every other format in this library writes a tree. CSV writes rows of cells,
  and a row of cells has no way to say "this member is itself an object" or
  "this member is a list of three things". That is not a gap in the parser -
  it is what the format is, and a serializer that quietly invented a
  convention for it would produce files that only it can read.

  So the projection from a Delphi value onto a table is an explicit decision,
  made by the caller, out of a named set of strategies:

      NestedObjectMode   Flatten (default), JsonCell, SeparateTable, Error
      CollectionMode     Error (default), JsonCell, RepeatedRows,
                         SeparateTable, NumberedColumns

  and the DEFAULT for a collection is to refuse, naming the member path,
  because a row of cells genuinely cannot hold one and silently dropping it
  is the one behaviour this library will not offer.

  A DOCUMENT SET, NOT A CONCATENATION. SeparateTable produces several CSV
  files - a parent table and one child table per collection - and one
  TSerializationPayload cannot hold several files. It is therefore not
  reachable through Serialize at all: SerializeTables returns a
  TCsvDocumentSet, Serialize raises and says so. Nothing is concatenated,
  no separator is invented, and no archive bytes are smuggled into a text
  payload.

  READING IS LITERAL. A column called 'Address.City' is a column whose name
  is 'Address.City'. Reading a CSV file that nobody supplied a contract or a
  schema for never expands a dotted name into a nested object, because the
  dot might be part of somebody's column name; expansion happens when the
  Delphi contract says that member is nested, or when the caller explicitly
  asks for it with ExpandDottedNames.

  The parser is a real one: a configurable delimiter and quote character,
  quoted values, the doubled-quote escape, embedded delimiters, quotes and
  line breaks inside quoted fields, CRLF and bare LF input, an optional
  byte-order mark, ragged rows and duplicate headers under explicit
  policies.

  Using this unit needs no registration. PascalForge.Csv.Registration exists
  only for code that picks a format at run time.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections,
  PascalForge.Serialization.Core, PascalForge.Dynamic;

type
  ECsvError = class(Exception);

  { The document is at fault: a quote that never closes, a ragged row under a
    policy that refuses one, a duplicate header. }
  ECsvInputError = class(ECsvError);

  { The model or the configuration is at fault. }
  ECsvInternalError = class(ECsvError);

  { The value cannot be projected onto a table under the selected options.
    Always carries the member path, because "it does not fit" without saying
    WHICH member does not fit is not a diagnosis. }
  ECsvProjectionError = class(ECsvError)
  strict private
    FPath: string;
  public
    constructor CreateForPath(const APath, AReason: string);
    { 'Customer.Orders' - the Delphi member path, not a cell reference. }
    property Path: string read FPath;
  end;

{ ===========================================================================
  DIALECT AND OPTIONS
  =========================================================================== }

type
  { The three spellings of CSV that have names, and the fourth value for
    everything else. Setting a delimiter or a quote character by hand moves
    the options to Custom, so Dialect always reports what the options
    actually are rather than what they were asked for. }
  TCsvDialect = (
    { RFC 4180: comma, double quote, CRLF, a header row. }
    Standard,
    { What a spreadsheet expects when it opens a UTF-8 file by double click:
      RFC 4180 plus a byte-order mark, without which the spreadsheet reads
      the bytes in the machine's own code page and mangles every non-ASCII
      name in the file. }
    Excel,
    { Tab-separated. Still quoted by the same rules - a tab inside a value is
      as real as a comma inside one. }
    TabSeparated,
    Custom);

  TCsvNewLine = (CrLf, Lf);

  { How a member whose type is a record or a class is projected. }
  TCsvNestedObjectMode = (
    { One column per leaf, named by the path: Address.City. The default,
      because it is what a table can actually express, and it reverses
      exactly when a contract says which columns belong to which member. }
    Flatten,
    { One cell holding a JSON document. Reached through the format registry,
      never by importing the JSON unit; raises
      ESerializationFormatNotRegistered when nothing registered JSON. Never a
      default: it puts one format's document inside another's, which is a
      choice a caller makes deliberately. }
    JsonCell,
    { A parent table and a child table, joined on a key. Only reachable
      through SerializeTables. }
    SeparateTable,
    { Refuse, naming the member path. }
    Error);

  { How a member whose type is a list or an array is projected. A table has
    one cell per column per row and a collection has N values, so every one
    of these is a real decision with a real cost. }
  TCsvCollectionMode = (
    { Refuse, naming the member path. THE DEFAULT: a row cannot hold a list,
      and the alternatives all cost something the caller should choose
      knowingly. }
    Error,
    { One cell holding a JSON array, through the registry. }
    JsonCell,
    { One row per element, with the parent's columns repeated on each. The
      table grows down rather than across. }
    RepeatedRows,
    { A child table, joined to the parent on a key. The preferred rich
      representation: it is the one strategy that does not multiply, does not
      widen without bound, and does not embed another format. Only reachable
      through SerializeTables. }
    SeparateTable,
    { Orders[0].Id, Orders[1].Id ... The header depends on the longest
      collection in the whole source, so the source is buffered completely
      before the header is written. }
    NumberedColumns);

  { What RepeatedRows does when a row type has TWO collections. }
  TCsvMultipleCollections = (
    { Refuse. Two independent collections of N and M elements have no single
      correct row count, and the arithmetic that produces one - N times M -
      invents pairings that the source never contained. THE DEFAULT. }
    Error,
    { Produce every pairing: N times M rows. Three collections multiply
      three ways. The caller has said in writing that the pairings are
      wanted; they are still invented. }
    CartesianProduct);

  { Two columns in one header with the same name. }
  TCsvDuplicateHeaderPolicy = (
    { Refuse, naming the column. THE DEFAULT, because every other answer
      silently decides which of two columns a caller meant. }
    Error,
    { Keep both, renaming the later ones - Name, Name_2, Name_3. }
    Rename,
    { Both columns are read; lookups by name find the first. }
    UseFirst,
    { Both columns are read; lookups by name find the last. }
    UseLast);

  { A row with more or fewer cells than the header has columns. }
  TCsvRaggedRowPolicy = (
    { Refuse, naming the row number and both counts. THE DEFAULT. }
    Error,
    { A short row gains empty cells; a long row keeps its extra cells, which
      are reachable by index and have no column name. }
    PadWithEmpty,
    { A short row gains empty cells; a long row loses its extra cells. }
    Truncate);

  { CSV has no null. It has an empty field, and an empty field is also how
    the empty string is written, so one of the two has to give. }
  TCsvNullPolicy = (
    { A null is written as an empty field, and an empty field is read as a
      null. Idiomatic, and NOT reversible: a string that was empty comes back
      as a null, because the document did not record the difference. THE
      DEFAULT, because it is what every other CSV producer does. }
    EmptyField,
    { A null is written as NullLiteral - 'NULL' unless configured otherwise -
      and an empty field is read as the empty string. Both round trip, at the
      cost that the literal text itself can no longer be an ordinary value in
      that column. }
    Literal,
    { Writing a null raises, naming the member path. For a caller who has
      decided that their data has no nulls and wants to be told when it
      does. }
    Error);

  { How much a reader may conclude from the way a value is spelled.

    CSV states nothing about types. Every one of these policies is therefore
    a guess with a stated boundary, and the default one guesses as little as
    is useful. }
  TCsvSchemaInferencePolicy = (
    { Nothing is inferred. Every column is text. }
    StringsOnly,
    { A column of unambiguous true/false becomes Boolean. Plain signed
      integers become Integer or Int64 by magnitude. Plain fractional values
      become Float. EVERYTHING ELSE stays text - including '00123', '+001'
      and '000001', whose leading zeros and signs may be significant, and
      including anything that merely looks like a date, a time, a GUID or
      base64. THE DEFAULT. }
    Conservative,
    { Conservative, plus the numeric spellings Conservative refuses on
      purpose: a leading '+', leading zeros, an exponent with no point. For a
      caller who knows the column is a number and has decided that how it was
      written does not matter. }
    Numeric,
    { Numeric, plus dates, times, GUIDs and base64 binary recognized by
      spelling. The ONLY policy under which a string that looks like a date
      becomes a date, and it is opt-in for exactly that reason. }
    Extended);

  { The column names SeparateTable uses to join a child table to its parent.

    Relationship METADATA - which table is a child of which, through which
    member - lives in TCsvDocumentSet and is never written into a CSV file.
    What does go into the file is the join VALUE, which is data: without it a
    child table alone cannot be put back together with its parent. }
  TCsvRelationshipNaming = record
  public
    { The column added to a CHILD table holding the parent row's key. Empty
      means derive it: the parent table's name, an underscore, and the parent
      key column's name - 'Customer_Id'. }
    ReferenceColumn: string;
    { The column added to a PARENT table when the contract exposes no key of
      its own and one has to be generated. }
    GeneratedKeyColumn: string;
    { Appended, with a counter, when a generated name collides with a column
      the row type already has. }
    CollisionSuffix: string;
    class function Default: TCsvRelationshipNaming; static;
    function Describe: string;
  end;

  { Everything CSV needs to know, in one record, in THIS unit.

    None of it belongs in Core: how a table is quoted, how a tree is
    projected onto rows and what an empty field means are CSV's questions and
    nobody else's. }
  TCsvOptions = record
  public
    Delimiter: Char;
    QuoteChar: Char;
    { False means the first line is already data and columns are known only
      by position. }
    HasHeader: Boolean;
    { Prepends U+FEFF to the text, which becomes the three-byte UTF-8 mark
      when the payload is encoded. Reading accepts and skips one whether or
      not this is set. }
    WriteBom: Boolean;
    NewLine: TCsvNewLine;
    NestedObjectMode: TCsvNestedObjectMode;
    CollectionMode: TCsvCollectionMode;
    MultipleCollections: TCsvMultipleCollections;
    { Between the parts of a flattened name. '.' by default. }
    PathSeparator: string;
    NullPolicy: TCsvNullPolicy;
    { What NullPolicy.Literal writes and reads. 'NULL' by default. }
    NullLiteral: string;
    SchemaInference: TCsvSchemaInferencePolicy;
    RelationshipNaming: TCsvRelationshipNaming;
    DuplicateHeaders: TCsvDuplicateHeaderPolicy;
    RaggedRows: TCsvRaggedRowPolicy;
    { Strips spaces around an UNQUOTED value. A quoted value is never
      trimmed: the quotes are what say the spaces were meant. }
    TrimUnquotedValues: Boolean;
    { Quote every field, whether or not it needs it. Some consumers prefer
      it; the parser does not care either way. }
    AlwaysQuote: Boolean;
    { Read a dotted column name back into a nested member even with no
      contract. Off by default, because a dot is a legal character in a
      column name and guessing otherwise silently restructures somebody's
      data. }
    ExpandDottedNames: Boolean;

    class function Default: TCsvOptions; static;
    class function ForDialect(ADialect: TCsvDialect): TCsvOptions; static;

    { What the options actually are, which is not always what was asked for:
      changing the delimiter of a Standard dialect makes it Custom. }
    function Dialect: TCsvDialect;
    { The line terminator NewLine names. }
    function NewLineText: string;
    { True when this configuration produces more than one table, and so
      cannot be reached through Serialize. }
    function RequiresSeparateTables: Boolean;
    function Describe: string;

    function WithDelimiter(ADelimiter: Char): TCsvOptions;
    function WithQuoteChar(AQuoteChar: Char): TCsvOptions;
    function WithHeader(AHasHeader: Boolean): TCsvOptions;
    function WithBom(AWriteBom: Boolean): TCsvOptions;
    function WithNewLine(ANewLine: TCsvNewLine): TCsvOptions;
    function WithNestedObjectMode(AMode: TCsvNestedObjectMode): TCsvOptions;
    function WithCollectionMode(AMode: TCsvCollectionMode): TCsvOptions;
    function WithMultipleCollections(
      AMode: TCsvMultipleCollections): TCsvOptions;
    function WithPathSeparator(const ASeparator: string): TCsvOptions;
    function WithNullPolicy(APolicy: TCsvNullPolicy): TCsvOptions; overload;
    function WithNullPolicy(APolicy: TCsvNullPolicy;
      const ALiteral: string): TCsvOptions; overload;
    function WithSchemaInference(
      APolicy: TCsvSchemaInferencePolicy): TCsvOptions;
    function WithRelationshipNaming(
      const ANaming: TCsvRelationshipNaming): TCsvOptions;
    function WithDuplicateHeaders(
      APolicy: TCsvDuplicateHeaderPolicy): TCsvOptions;
    function WithRaggedRows(APolicy: TCsvRaggedRowPolicy): TCsvOptions;
    function WithTrimmedValues(ATrim: Boolean): TCsvOptions;
    function WithAlwaysQuote(AAlways: Boolean): TCsvOptions;
    function WithExpandedDottedNames(AExpand: Boolean): TCsvOptions;
  end;

{ ===========================================================================
  A SCHEMA, ALONGSIDE THE FILE AND NEVER INSIDE IT

  CSV carries no types, so anything known about the types has to travel
  separately. That is what this is: a description of the columns, produced by
  inference from a document or by reading a Delphi contract, and consumed by
  a later read that wants the same answers without guessing again.

  It is never serialized into the CSV. A header row holds names; it does not
  hold a type, a size or a nested path, and putting them there would produce
  a file that no other CSV reader understands.
  =========================================================================== }

type
  TCsvColumnType = (
    { A Delphi string. What everything is until something says otherwise. }
    Str,
    Boolean,
    Int32,
    Int64,
    Float,
    { Only ever inferred under SchemaInference.Extended; otherwise it comes
      from a contract, which actually knows. }
    DateTime,
    Guid,
    { Base64 text standing for bytes. Same rule. }
    Binary);

  TCsvColumn = record
  public
    { The header cell, exactly as it appears in the file. }
    Name: string;
    ColumnType: TCsvColumnType;
    { True when the column was seen holding a null, or when the contract
      member is a nullable. }
    Nullable: System.Boolean;
    { The longest text observed in the column, or a declared width. Zero when
      nothing is known - this is a hint for a consumer building a table, not
      a constraint this unit enforces. }
    Size: Integer;
    { A FormatDateTime pattern for a DateTime column. Empty means ISO 8601. }
    DateFormat: string;
    { The member path this column was flattened from - 'Address.City' - or
      empty for a column that came from a document rather than a contract. }
    Path: string;
    class function Make(const AName: string;
      AType: TCsvColumnType): TCsvColumn; static;
    function Describe: string;
  end;

const
  { What every single-payload call says when the options ask for
    SeparateTable: the answer is a different return shape, not a missing
    feature. }
  CSV_SEPARATE_TABLE_GUIDANCE =
    'SeparateTable produces several CSV documents, and this call produces ' +
    'ONE payload. Use TCsvSerializer.TablesFrom for a document in another ' +
    'format, or TCsvSerializer.SerializeTables for a Delphi value; both ' +
    'return a TCsvDocumentSet.';

type
  TCsvSchema = class(TSerializationSchema)
  strict private
    FColumns: TList<TCsvColumn>;
    FOptions: TCsvOptions;
    FTableName: string;
    function GetColumn(AIndex: Integer): TCsvColumn;
    function GetCount: Integer;
  public
    constructor Create; overload;
    constructor Create(const AOptions: TCsvOptions); overload;
    destructor Destroy; override;

    function Format: TSerializationFormat; override;
    function Describe: string; override;

    procedure Add(const AColumn: TCsvColumn);
    procedure SetColumn(AIndex: Integer; const AColumn: TCsvColumn);
    function IndexOf(const AName: string): Integer;
    function TryGetColumn(const AName: string; out AColumn: TCsvColumn): System.Boolean;
    property Count: Integer read GetCount;
    property Columns[AIndex: Integer]: TCsvColumn read GetColumn; default;

    { THE OPTIONS TRAVEL WITH THE SCHEMA, and that is not decoration.

      A format handler is asked what it can do through
      Capabilities(AOptions), where AOptions is the CORE conversion policy
      and has no room for a delimiter or a projection mode. The schema is the
      one thing in that record that belongs to this format, so it is how CSV
      options reach the handler - and it is why CSV can answer honestly that
      it cannot write a structural tree when the caller has asked for
      SeparateTable. }
    property Options: TCsvOptions read FOptions write FOptions;
    { The table this schema describes, for a schema that came from a document
      set. Empty otherwise. }
    property TableName: string read FTableName write FTableName;
  end;

{ ===========================================================================
  SEVERAL TABLES, WHICH ONE PAYLOAD CANNOT HOLD
  =========================================================================== }

type
  TCsvTableDocument = record
  public
    { 'Customer', 'Customer_Orders'. The file name a caller would give it,
      without an extension. }
    Name: string;
    { The CSV text of this one table, complete and independently readable. }
    Content: string;
    { How many data rows Content holds, excluding the header. }
    RowCount: Integer;
    class function Make(const AName, AContent: string;
      ARowCount: Integer): TCsvTableDocument; static;
    function Describe: string;
  end;

  { How one child table is joined to its parent. This is METADATA and it
    lives here, out of band - the CSV files hold data and column names and
    nothing else. }
  TCsvTableRelationship = record
  public
    ParentTable: string;
    ChildTable: string;
    { The Delphi member path that produced the child table -
      'Customer.Orders'. }
    MemberPath: string;
    { The column in the parent table holding the key. }
    ParentKeyColumn: string;
    { The column in the child table holding the parent's key. }
    ChildReferenceColumn: string;
    { True when the contract exposed no key and one was generated. A
      generated key is an artefact of this projection: it is stable within
      one document set and means nothing outside it. }
    KeyIsGenerated: System.Boolean;
    function Describe: string;
  end;

  TCsvDocumentSet = class
  strict private
    FTables: TList<TCsvTableDocument>;
    FRelationships: TList<TCsvTableRelationship>;
    function GetTable(AIndex: Integer): TCsvTableDocument;
    function GetCount: Integer;
    function GetRelationship(AIndex: Integer): TCsvTableRelationship;
    function GetRelationshipCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Add(const ATable: TCsvTableDocument);
    procedure AddRelationship(const ARelationship: TCsvTableRelationship);

    property Count: Integer read GetCount;
    property Tables[AIndex: Integer]: TCsvTableDocument read GetTable; default;
    function IndexOf(const AName: string): Integer;
    { Raises when there is no such table, because a caller asking for one by
      name has a reason to believe it is there. }
    function TableByName(const AName: string): TCsvTableDocument;
    function TryGetTable(const AName: string;
      out ATable: TCsvTableDocument): System.Boolean;
    function TableNames: TArray<string>;

    property RelationshipCount: Integer read GetRelationshipCount;
    property Relationships[AIndex: Integer]: TCsvTableRelationship
      read GetRelationship;
    { The relationships whose parent is AName, in the order the tables were
      produced. }
    function ChildrenOf(const AName: string): TArray<TCsvTableRelationship>;

    { The root table - the first one added, which is the one every other
      table hangs off. }
    function RootName: string;
    function Describe: string;
  end;

{ ===========================================================================
  ATTRIBUTES - CSV's own, and only CSV's.
  =========================================================================== }

type
  CsvNameAttribute = class(TCustomAttribute)
  strict private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

  CsvIgnoreAttribute = class(TCustomAttribute)
  end;

  { Names the member whose value identifies a row.

    SeparateTable needs a key to join a child table to its parent. When the
    contract has one - an Id, a customer number - this says so, and that
    column is used as it stands. Without it a key is generated, which works
    and is honest but means nothing outside the document set it was made
    for. }
  CsvKeyAttribute = class(TCustomAttribute)
  end;

  { The table name for a row type, overriding the one derived from the type's
    own name. }
  CsvTableAttribute = class(TCustomAttribute)
  strict private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

  { A FormatDateTime pattern for one member. CSV's setting; it has no effect
    on any other format. An empty pattern means ISO 8601. }
  CsvDateTimeFormatAttribute = class(TCustomAttribute)
  strict private
    FPattern: string;
  public
    constructor Create(const APattern: string);
    property Pattern: string read FPattern;
  end;

{ ===========================================================================
  CUSTOM CELL SERIALIZERS - CSV's, not JSON's.

  A cell is text, so a custom CSV serializer is a pair of text conversions
  and nothing more. It cannot produce a structure, because there is nowhere
  in a cell to put one.
  =========================================================================== }

type
  TCustomCsvCellSerializer = class
  public
    function Serialize(const AValue: TValue): string; virtual; abstract;
    function Deserialize(const AText: string; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; virtual; abstract;
  end;

  TCsvCellSerializerClass = class of TCustomCsvCellSerializer;

  { The typed base, and the one to use: it names the Delphi type, so an
    implementation never touches TValue or PTypeInfo. }
  TCustomCsvCellSerializer<T> = class(TCustomCsvCellSerializer)
  public
    function SerializeValue(const AValue: T): string; virtual; abstract;
    function DeserializeValue(const AText: string; const AExisting: T): T; virtual; abstract;

    function Serialize(const AValue: TValue): string; override; final;
    function Deserialize(const AText: string; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; override; final;
  end;

  CsvSerializerAttribute = class(TCustomAttribute)
  strict private
    FSerializerClass: TCsvCellSerializerClass;
  public
    constructor Create(ASerializerClass: TCsvCellSerializerClass);
    property SerializerClass: TCsvCellSerializerClass read FSerializerClass;
  end;

{ =========================================================================== }

type
  TCsvSerializer = class
  strict private
    { A generic method body declared in an interface section may reference
      only interface-declared symbols, so every generic entry point below is
      a thin shell over one of these. }
    class function DoSerialize(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AOptions: TCsvOptions): string; static;
    class function DoDeserialize(ATypeInfo: PTypeInfo; const AText: string;
      const AOptions: TCsvOptions): TValue; static;
    class function DoSerializeTables(ATypeInfo: PTypeInfo;
      const AValue: TValue; const AOptions: TCsvOptions): TCsvDocumentSet; static;
    class function DoDeserializeTables(ATypeInfo: PTypeInfo;
      ATables: TCsvDocumentSet; const AOptions: TCsvOptions): TValue; static;
    class function DoSchemaOf(ATypeInfo: PTypeInfo;
      const AOptions: TCsvOptions): TCsvSchema; static;
    class procedure DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TCsvCellSerializerClass); static;
    class procedure DoSetDateTimeFormat(ATypeInfo: PTypeInfo;
      const AFieldName, APattern: string); static;
  public
    { --- the normal API ----------------------------------------------------

      T is the WHOLE TABLE, not one row: TArray<TCustomer>,
      TList<TCustomer>, TObjectList<TCustomer>. A single record or class is
      accepted too and produces a one-row table, because that is occasionally
      what a caller has. }
    class function Serialize<T>(const AValue: T): string; overload; static;
    class function Serialize<T>(const AValue: T;
      const AOptions: TCsvOptions): string; overload; static;
    class function Deserialize<T>(const AText: string): T; overload; static;
    class function Deserialize<T>(const AText: string;
      const AOptions: TCsvOptions): T; overload; static;

    { --- bytes -------------------------------------------------------------

      The same text, encoded UTF-8, with the byte-order mark WriteBom asks
      for. Reading accepts a mark whether or not one was asked for, and
      refuses malformed UTF-8 by name rather than substituting replacement
      characters. }
    class function SerializeToBytes<T>(const AValue: T): TBytes; overload; static;
    class function SerializeToBytes<T>(const AValue: T;
      const AOptions: TCsvOptions): TBytes; overload; static;
    class function DeserializeBytes<T>(const AData: TBytes): T; overload; static;
    class function DeserializeBytes<T>(const AData: TBytes;
      const AOptions: TCsvOptions): T; overload; static;

    { --- several tables ----------------------------------------------------

      The rich representation. A parent table and one child table per
      collection, joined on a key, with the relationships recorded on the
      document set rather than in the files.

      The caller owns the returned document set. }
    class function SerializeTables<T>(const AValue: T): TCsvDocumentSet; overload; static;
    class function SerializeTables<T>(const AValue: T;
      const AOptions: TCsvOptions): TCsvDocumentSet; overload; static;
    class function DeserializeTables<T>(ATables: TCsvDocumentSet): T; overload; static;
    class function DeserializeTables<T>(ATables: TCsvDocumentSet;
      const AOptions: TCsvOptions): T; overload; static;

    { --- several tables from a document in another format ----------------

      A document with no Delphi type - JSON, YAML, BSON, anything registered
      that can be read structurally - projected onto CSV tables with these
      options. The same projection as SerializeTables, read from the
      document instead of from a value: SeparateTable opens a child table
      per collection, joined on a generated key.

      The document root has no name, so a root object's members that become
      tables are named after the member ('customers', 'customers_orders')
      and its remaining members form the one-row table 'root'; a root array
      is the table 'root'. Nothing is recognised by name: a document with
      'fields' and 'rows' members is two tables, never a DataSet.

      CSV itself needs no registration here; the SOURCE format is reached
      through the registry, so its handler must be registered, and a
      schema-driven source needs its context. The caller owns the result. }
    class function TablesFrom(const ASource: TSerializationPayload;
      ASourceFormat: TSerializationFormat;
      const AOptions: TCsvOptions): TCsvDocumentSet; overload; static;
    class function TablesFrom(const ASource: TSerializationPayload;
      ASourceFormat: TSerializationFormat;
      ASourceContext: TSerializationContext;
      const AOptions: TCsvOptions): TCsvDocumentSet; overload; static;

    { --- schemas -----------------------------------------------------------

      Two ways to get one, and they answer different questions. InferSchema
      reads a document and reports what the SPELLING of its values supports
      under the inference policy. SchemaOf reads a Delphi contract and
      reports what the TYPES actually are - no guessing involved, because the
      contract knows.

      The caller owns the returned schema. }
    class function InferSchema(const AText: string): TCsvSchema; overload; static;
    class function InferSchema(const AText: string;
      const AOptions: TCsvOptions): TCsvSchema; overload; static;
    class function SchemaOf<T>: TCsvSchema; overload; static;
    class function SchemaOf<T>(const AOptions: TCsvOptions): TCsvSchema; overload; static;

    { --- registrations -----------------------------------------------------

      CSV's own, independent of every other format's. }
    class procedure RegisterTypeSerializer<T>(
      ASerializerClass: TCsvCellSerializerClass); static;

    { Date and time, resolved once while a plan is built: a member attribute
      beats a field registration, which beats a type registration, which
      beats this global default, which beats ISO 8601. }
    class procedure SetDateTimeFormat(const APattern: string); static;
    class procedure RegisterDateTimeFormat<T>(const APattern: string); static;
    class procedure RegisterFieldDateTimeFormat<T>(
      const AFieldName, APattern: string); static;

    { --- configuration lifecycle ------------------------------------------- }
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;

    { --- dynamic ---------------------------------------------------------

      A CSV table as a dynamic ARRAY OF OBJECTS - always an array, even for
      one row - and an array of objects as a table, under AOptions (cell
      text, repeated rows, numbered columns: docs/formats/csv.md). The tree
      is the caller's. }
    class function ToDynamic(const ACsv: string): TDynamicValue; overload; static;
    class function ToDynamic(const ACsv: string;
      const AOptions: TCsvOptions): TDynamicValue; overload; static;
    class function FromDynamic(AValue: TDynamicValue): string; overload; static;
    class function FromDynamic(AValue: TDynamicValue;
      const AOptions: TCsvOptions): string; overload; static;
    class procedure ResetConfiguration; static;
  end;

implementation

uses
  PascalForge.Csv.Internal;

{ ------------------------------------------------------------------ errors - }

constructor ECsvProjectionError.CreateForPath(const APath, AReason: string);
begin
  inherited Create(AReason);
  FPath := APath;
end;

{ ------------------------------------------------------------ relationships - }

class function TCsvRelationshipNaming.Default: TCsvRelationshipNaming;
begin
  Result.ReferenceColumn := '';
  Result.GeneratedKeyColumn := 'RowKey';
  Result.CollisionSuffix := '_';
end;

function TCsvRelationshipNaming.Describe: string;
begin
  if ReferenceColumn = '' then
    Result := 'reference column derived from the parent table and key'
  else
    Result := 'reference column "' + ReferenceColumn + '"';
  Result := Result + ', generated key column "' + GeneratedKeyColumn + '"';
end;

{ ----------------------------------------------------------------- options - }

class function TCsvOptions.Default: TCsvOptions;
begin
  Result := ForDialect(TCsvDialect.Standard);
end;

class function TCsvOptions.ForDialect(ADialect: TCsvDialect): TCsvOptions;
begin
  Result.Delimiter := ',';
  Result.QuoteChar := '"';
  Result.HasHeader := True;
  Result.WriteBom := False;
  Result.NewLine := TCsvNewLine.CrLf;
  Result.NestedObjectMode := TCsvNestedObjectMode.Flatten;
  Result.CollectionMode := TCsvCollectionMode.Error;
  Result.MultipleCollections := TCsvMultipleCollections.Error;
  Result.PathSeparator := '.';
  Result.NullPolicy := TCsvNullPolicy.EmptyField;
  Result.NullLiteral := 'NULL';
  Result.SchemaInference := TCsvSchemaInferencePolicy.Conservative;
  Result.RelationshipNaming := TCsvRelationshipNaming.Default;
  Result.DuplicateHeaders := TCsvDuplicateHeaderPolicy.Error;
  Result.RaggedRows := TCsvRaggedRowPolicy.Error;
  Result.TrimUnquotedValues := False;
  Result.AlwaysQuote := False;
  Result.ExpandDottedNames := False;

  case ADialect of
    TCsvDialect.Excel: Result.WriteBom := True;
    TCsvDialect.TabSeparated: Result.Delimiter := #9;
  end;
end;

function TCsvOptions.Dialect: TCsvDialect;
begin
  if QuoteChar <> '"' then Exit(TCsvDialect.Custom);
  if Delimiter = #9 then
  begin
    if WriteBom then Exit(TCsvDialect.Custom);
    Exit(TCsvDialect.TabSeparated);
  end;
  if Delimiter <> ',' then Exit(TCsvDialect.Custom);
  if WriteBom then Exit(TCsvDialect.Excel);
  Result := TCsvDialect.Standard;
end;

function TCsvOptions.NewLineText: string;
begin
  if NewLine = TCsvNewLine.Lf then Result := #10 else Result := #13#10;
end;

function TCsvOptions.RequiresSeparateTables: System.Boolean;
begin
  Result := (NestedObjectMode = TCsvNestedObjectMode.SeparateTable) or
    (CollectionMode = TCsvCollectionMode.SeparateTable);
end;

function TCsvOptions.Describe: string;
const
  CDialect: array[TCsvDialect] of string =
    ('standard', 'excel', 'tab-separated', 'custom');
  CNested: array[TCsvNestedObjectMode] of string =
    ('flatten', 'json cell', 'separate table', 'error');
  CCollection: array[TCsvCollectionMode] of string =
    ('error', 'json cell', 'repeated rows', 'separate table',
     'numbered columns');
begin
  Result := System.SysUtils.Format(
    '%s dialect, nested objects: %s, collections: %s',
    [CDialect[Dialect], CNested[NestedObjectMode], CCollection[CollectionMode]]);
end;

function TCsvOptions.WithDelimiter(ADelimiter: Char): TCsvOptions;
begin
  Result := Self;
  Result.Delimiter := ADelimiter;
end;

function TCsvOptions.WithQuoteChar(AQuoteChar: Char): TCsvOptions;
begin
  Result := Self;
  Result.QuoteChar := AQuoteChar;
end;

function TCsvOptions.WithHeader(AHasHeader: System.Boolean): TCsvOptions;
begin
  Result := Self;
  Result.HasHeader := AHasHeader;
end;

function TCsvOptions.WithBom(AWriteBom: System.Boolean): TCsvOptions;
begin
  Result := Self;
  Result.WriteBom := AWriteBom;
end;

function TCsvOptions.WithNewLine(ANewLine: TCsvNewLine): TCsvOptions;
begin
  Result := Self;
  Result.NewLine := ANewLine;
end;

function TCsvOptions.WithNestedObjectMode(
  AMode: TCsvNestedObjectMode): TCsvOptions;
begin
  Result := Self;
  Result.NestedObjectMode := AMode;
end;

function TCsvOptions.WithCollectionMode(AMode: TCsvCollectionMode): TCsvOptions;
begin
  Result := Self;
  Result.CollectionMode := AMode;
end;

function TCsvOptions.WithMultipleCollections(
  AMode: TCsvMultipleCollections): TCsvOptions;
begin
  Result := Self;
  Result.MultipleCollections := AMode;
end;

function TCsvOptions.WithPathSeparator(const ASeparator: string): TCsvOptions;
begin
  Result := Self;
  Result.PathSeparator := ASeparator;
end;

function TCsvOptions.WithNullPolicy(APolicy: TCsvNullPolicy): TCsvOptions;
begin
  Result := Self;
  Result.NullPolicy := APolicy;
end;

function TCsvOptions.WithNullPolicy(APolicy: TCsvNullPolicy;
  const ALiteral: string): TCsvOptions;
begin
  Result := Self;
  Result.NullPolicy := APolicy;
  Result.NullLiteral := ALiteral;
end;

function TCsvOptions.WithSchemaInference(
  APolicy: TCsvSchemaInferencePolicy): TCsvOptions;
begin
  Result := Self;
  Result.SchemaInference := APolicy;
end;

function TCsvOptions.WithRelationshipNaming(
  const ANaming: TCsvRelationshipNaming): TCsvOptions;
begin
  Result := Self;
  Result.RelationshipNaming := ANaming;
end;

function TCsvOptions.WithDuplicateHeaders(
  APolicy: TCsvDuplicateHeaderPolicy): TCsvOptions;
begin
  Result := Self;
  Result.DuplicateHeaders := APolicy;
end;

function TCsvOptions.WithRaggedRows(APolicy: TCsvRaggedRowPolicy): TCsvOptions;
begin
  Result := Self;
  Result.RaggedRows := APolicy;
end;

function TCsvOptions.WithTrimmedValues(ATrim: System.Boolean): TCsvOptions;
begin
  Result := Self;
  Result.TrimUnquotedValues := ATrim;
end;

function TCsvOptions.WithAlwaysQuote(AAlways: System.Boolean): TCsvOptions;
begin
  Result := Self;
  Result.AlwaysQuote := AAlways;
end;

function TCsvOptions.WithExpandedDottedNames(AExpand: System.Boolean): TCsvOptions;
begin
  Result := Self;
  Result.ExpandDottedNames := AExpand;
end;

{ ------------------------------------------------------------------ schema - }

class function TCsvColumn.Make(const AName: string;
  AType: TCsvColumnType): TCsvColumn;
begin
  Result.Name := AName;
  Result.ColumnType := AType;
  Result.Nullable := False;
  Result.Size := 0;
  Result.DateFormat := '';
  Result.Path := '';
end;

function TCsvColumn.Describe: string;
const
  CNames: array[TCsvColumnType] of string =
    ('string', 'boolean', 'int32', 'int64', 'float', 'datetime', 'guid',
     'binary');
begin
  Result := Name + ': ' + CNames[ColumnType];
  if Nullable then Result := Result + ', nullable';
  if Size > 0 then Result := Result + ', size ' + IntToStr(Size);
  if DateFormat <> '' then Result := Result + ', format ' + DateFormat;
  if (Path <> '') and (Path <> Name) then Result := Result + ', path ' + Path;
end;

constructor TCsvSchema.Create;
begin
  Create(TCsvOptions.Default);
end;

constructor TCsvSchema.Create(const AOptions: TCsvOptions);
begin
  inherited Create;
  FColumns := TList<TCsvColumn>.Create;
  FOptions := AOptions;
end;

destructor TCsvSchema.Destroy;
begin
  FColumns.Free;
  inherited Destroy;
end;

function TCsvSchema.Format: TSerializationFormat;
begin
  Result := TSerializationFormat.Csv;
end;

function TCsvSchema.Describe: string;
begin
  if FTableName <> '' then
    Result := System.SysUtils.Format('table %s, %d columns',
      [FTableName, FColumns.Count])
  else
    Result := System.SysUtils.Format('%d columns', [FColumns.Count]);
end;

procedure TCsvSchema.Add(const AColumn: TCsvColumn);
begin
  FColumns.Add(AColumn);
end;

procedure TCsvSchema.SetColumn(AIndex: Integer; const AColumn: TCsvColumn);
begin
  FColumns[AIndex] := AColumn;
end;

function TCsvSchema.GetColumn(AIndex: Integer): TCsvColumn;
begin
  Result := FColumns[AIndex];
end;

function TCsvSchema.GetCount: Integer;
begin
  Result := Integer(FColumns.Count);
end;

function TCsvSchema.IndexOf(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to Integer(FColumns.Count - 1) do
    if FColumns[I].Name = AName then Exit(I);
  Result := -1;
end;

function TCsvSchema.TryGetColumn(const AName: string;
  out AColumn: TCsvColumn): System.Boolean;
var
  Index: Integer;
begin
  Index := IndexOf(AName);
  Result := Index >= 0;
  if Result then AColumn := FColumns[Index];
end;

{ ----------------------------------------------------------- document sets - }

class function TCsvTableDocument.Make(const AName, AContent: string;
  ARowCount: Integer): TCsvTableDocument;
begin
  Result.Name := AName;
  Result.Content := AContent;
  Result.RowCount := ARowCount;
end;

function TCsvTableDocument.Describe: string;
begin
  Result := System.SysUtils.Format('%s (%d rows, %d characters)',
    [Name, RowCount, Length(Content)]);
end;

function TCsvTableRelationship.Describe: string;
begin
  Result := System.SysUtils.Format('%s.%s -> %s, on %s.%s = %s.%s',
    [ParentTable, MemberPath, ChildTable, ParentTable, ParentKeyColumn,
     ChildTable, ChildReferenceColumn]);
  if KeyIsGenerated then Result := Result + ' (generated key)';
end;

constructor TCsvDocumentSet.Create;
begin
  inherited Create;
  FTables := TList<TCsvTableDocument>.Create;
  FRelationships := TList<TCsvTableRelationship>.Create;
end;

destructor TCsvDocumentSet.Destroy;
begin
  FRelationships.Free;
  FTables.Free;
  inherited Destroy;
end;

procedure TCsvDocumentSet.Add(const ATable: TCsvTableDocument);
begin
  FTables.Add(ATable);
end;

procedure TCsvDocumentSet.AddRelationship(
  const ARelationship: TCsvTableRelationship);
begin
  FRelationships.Add(ARelationship);
end;

function TCsvDocumentSet.GetTable(AIndex: Integer): TCsvTableDocument;
begin
  Result := FTables[AIndex];
end;

function TCsvDocumentSet.GetCount: Integer;
begin
  Result := Integer(FTables.Count);
end;

function TCsvDocumentSet.GetRelationship(
  AIndex: Integer): TCsvTableRelationship;
begin
  Result := FRelationships[AIndex];
end;

function TCsvDocumentSet.GetRelationshipCount: Integer;
begin
  Result := Integer(FRelationships.Count);
end;

function TCsvDocumentSet.IndexOf(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to Integer(FTables.Count - 1) do
    if SameText(FTables[I].Name, AName) then Exit(I);
  Result := -1;
end;

function TCsvDocumentSet.TryGetTable(const AName: string;
  out ATable: TCsvTableDocument): System.Boolean;
var
  Index: Integer;
begin
  Index := IndexOf(AName);
  Result := Index >= 0;
  if Result then ATable := FTables[Index];
end;

function TCsvDocumentSet.TableByName(const AName: string): TCsvTableDocument;
var
  Index: Integer;
begin
  Index := IndexOf(AName);
  if Index < 0 then
    raise ECsvInputError.CreateFmt(
      'This document set has no table called "%s". It has: %s',
      [AName, string.Join(', ', TableNames)]);
  Result := FTables[Index];
end;

function TCsvDocumentSet.TableNames: TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, FTables.Count);
  for I := 0 to Integer(FTables.Count - 1) do Result[I] := FTables[I].Name;
end;

function TCsvDocumentSet.ChildrenOf(
  const AName: string): TArray<TCsvTableRelationship>;
var
  I, N: Integer;
begin
  SetLength(Result, FRelationships.Count);
  N := 0;
  for I := 0 to Integer(FRelationships.Count - 1) do
    if SameText(FRelationships[I].ParentTable, AName) then
    begin
      Result[N] := FRelationships[I];
      Inc(N);
    end;
  SetLength(Result, N);
end;

function TCsvDocumentSet.RootName: string;
begin
  if FTables.Count = 0 then Exit('');
  Result := FTables[0].Name;
end;

function TCsvDocumentSet.Describe: string;
begin
  Result := System.SysUtils.Format('%d tables, %d relationships',
    [FTables.Count, FRelationships.Count]);
end;

{ -------------------------------------------------------------- attributes - }

constructor CsvNameAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

constructor CsvTableAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

constructor CsvDateTimeFormatAttribute.Create(const APattern: string);
begin
  inherited Create;
  FPattern := APattern;
end;

constructor CsvSerializerAttribute.Create(
  ASerializerClass: TCsvCellSerializerClass);
begin
  inherited Create;
  FSerializerClass := ASerializerClass;
end;

{ ------------------------------------------------------- custom serializers - }

function TCustomCsvCellSerializer<T>.Serialize(const AValue: TValue): string;
begin
  Result := SerializeValue(AValue.AsType<T>);
end;

function TCustomCsvCellSerializer<T>.Deserialize(const AText: string;
  ATypeInfo: PTypeInfo; const AExisting: TValue): TValue;
var
  Existing: T;
begin
  if AExisting.IsEmpty then Existing := System.Default(T)
  else Existing := AExisting.AsType<T>;
  Result := TValue.From<T>(DeserializeValue(AText, Existing));
end;

{ ------------------------------------------------------------- the facade - }

class function TCsvSerializer.DoSerialize(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AOptions: TCsvOptions): string;
begin
  Result := TCsvEngine.SerializeRoot(ATypeInfo, AValue, AOptions);
end;

class function TCsvSerializer.DoDeserialize(ATypeInfo: PTypeInfo;
  const AText: string; const AOptions: TCsvOptions): TValue;
begin
  Result := TCsvEngine.DeserializeRoot(ATypeInfo, AText, AOptions);
end;

class function TCsvSerializer.DoSerializeTables(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AOptions: TCsvOptions): TCsvDocumentSet;
begin
  Result := TCsvEngine.SerializeRootTables(ATypeInfo, AValue, AOptions);
end;

class function TCsvSerializer.TablesFrom(const ASource: TSerializationPayload;
  ASourceFormat: TSerializationFormat;
  const AOptions: TCsvOptions): TCsvDocumentSet;
begin
  Result := TablesFrom(ASource, ASourceFormat, nil, AOptions);
end;

class function TCsvSerializer.TablesFrom(const ASource: TSerializationPayload;
  ASourceFormat: TSerializationFormat; ASourceContext: TSerializationContext;
  const AOptions: TCsvOptions): TCsvDocumentSet;
var
  Options: TStructuralConversionOptions;
  Tree: TDynamicValue;
begin
  Options := TStructuralConversionOptions.Default.WithSource(ASourceFormat)
    .WithDestination(TSerializationFormat.Csv);
  if ASourceContext <> nil then
    Options := Options.WithSourceContext(ASourceContext);
  Tree := TSerializationFormats.Require(ASourceFormat,
    TSerializationFormatCapability.StructuralParse, Options).ToDynamic(
      ASource, Options);
  try
    Result := TCsvEngine.DynamicToTables(Tree, AOptions);
  finally
    Tree.Free;
  end;
end;

class function TCsvSerializer.DoDeserializeTables(ATypeInfo: PTypeInfo;
  ATables: TCsvDocumentSet; const AOptions: TCsvOptions): TValue;
begin
  Result := TCsvEngine.DeserializeRootTables(ATypeInfo, ATables, AOptions);
end;

class function TCsvSerializer.DoSchemaOf(ATypeInfo: PTypeInfo;
  const AOptions: TCsvOptions): TCsvSchema;
begin
  Result := TCsvEngine.SchemaOfType(ATypeInfo, AOptions);
end;

class procedure TCsvSerializer.DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TCsvCellSerializerClass);
begin
  TCsvEngine.RegisterTypeSerializer(ATypeInfo, ASerializerClass);
end;

class procedure TCsvSerializer.DoSetDateTimeFormat(ATypeInfo: PTypeInfo;
  const AFieldName, APattern: string);
begin
  TCsvEngine.SetDateTimeFormat(ATypeInfo, AFieldName, APattern);
end;

class function TCsvSerializer.Serialize<T>(const AValue: T): string;
begin
  Result := DoSerialize(System.TypeInfo(T), TValue.From<T>(AValue),
    TCsvOptions.Default);
end;

class function TCsvSerializer.Serialize<T>(const AValue: T;
  const AOptions: TCsvOptions): string;
begin
  Result := DoSerialize(System.TypeInfo(T), TValue.From<T>(AValue), AOptions);
end;

class function TCsvSerializer.Deserialize<T>(const AText: string): T;
begin
  Result := DoDeserialize(System.TypeInfo(T), AText,
    TCsvOptions.Default).AsType<T>;
end;

class function TCsvSerializer.Deserialize<T>(const AText: string;
  const AOptions: TCsvOptions): T;
begin
  Result := DoDeserialize(System.TypeInfo(T), AText, AOptions).AsType<T>;
end;

class function TCsvSerializer.SerializeToBytes<T>(const AValue: T): TBytes;
begin
  Result := SerializeToBytes<T>(AValue, TCsvOptions.Default);
end;

class function TCsvSerializer.SerializeToBytes<T>(const AValue: T;
  const AOptions: TCsvOptions): TBytes;
begin
  Result := StringToUtf8Bytes(
    DoSerialize(System.TypeInfo(T), TValue.From<T>(AValue), AOptions));
end;

class function TCsvSerializer.DeserializeBytes<T>(const AData: TBytes): T;
begin
  Result := DeserializeBytes<T>(AData, TCsvOptions.Default);
end;

class function TCsvSerializer.DeserializeBytes<T>(const AData: TBytes;
  const AOptions: TCsvOptions): T;
begin
  Result := DoDeserialize(System.TypeInfo(T), Utf8BytesToString(AData),
    AOptions).AsType<T>;
end;

class function TCsvSerializer.SerializeTables<T>(
  const AValue: T): TCsvDocumentSet;
begin
  Result := SerializeTables<T>(AValue,
    TCsvOptions.Default
      .WithNestedObjectMode(TCsvNestedObjectMode.Flatten)
      .WithCollectionMode(TCsvCollectionMode.SeparateTable));
end;

class function TCsvSerializer.SerializeTables<T>(const AValue: T;
  const AOptions: TCsvOptions): TCsvDocumentSet;
begin
  Result := DoSerializeTables(System.TypeInfo(T), TValue.From<T>(AValue),
    AOptions);
end;

class function TCsvSerializer.DeserializeTables<T>(
  ATables: TCsvDocumentSet): T;
begin
  Result := DeserializeTables<T>(ATables,
    TCsvOptions.Default
      .WithNestedObjectMode(TCsvNestedObjectMode.Flatten)
      .WithCollectionMode(TCsvCollectionMode.SeparateTable));
end;

class function TCsvSerializer.DeserializeTables<T>(ATables: TCsvDocumentSet;
  const AOptions: TCsvOptions): T;
begin
  Result := DoDeserializeTables(System.TypeInfo(T), ATables,
    AOptions).AsType<T>;
end;

class function TCsvSerializer.InferSchema(const AText: string): TCsvSchema;
begin
  Result := InferSchema(AText, TCsvOptions.Default);
end;

class function TCsvSerializer.InferSchema(const AText: string;
  const AOptions: TCsvOptions): TCsvSchema;
begin
  Result := TCsvEngine.InferSchema(AText, AOptions);
end;

class function TCsvSerializer.SchemaOf<T>: TCsvSchema;
begin
  Result := DoSchemaOf(System.TypeInfo(T), TCsvOptions.Default);
end;

class function TCsvSerializer.SchemaOf<T>(
  const AOptions: TCsvOptions): TCsvSchema;
begin
  Result := DoSchemaOf(System.TypeInfo(T), AOptions);
end;

class procedure TCsvSerializer.RegisterTypeSerializer<T>(
  ASerializerClass: TCsvCellSerializerClass);
begin
  DoRegisterTypeSerializer(System.TypeInfo(T), ASerializerClass);
end;

class procedure TCsvSerializer.SetDateTimeFormat(const APattern: string);
begin
  DoSetDateTimeFormat(nil, '', APattern);
end;

class procedure TCsvSerializer.RegisterDateTimeFormat<T>(
  const APattern: string);
begin
  DoSetDateTimeFormat(System.TypeInfo(T), '', APattern);
end;

class procedure TCsvSerializer.RegisterFieldDateTimeFormat<T>(
  const AFieldName, APattern: string);
begin
  DoSetDateTimeFormat(System.TypeInfo(T), AFieldName, APattern);
end;

class procedure TCsvSerializer.FreezeConfiguration;
begin
  TCsvEngine.FreezeConfiguration;
end;

class function TCsvSerializer.IsFrozen: Boolean;
begin
  Result := TCsvEngine.IsFrozen;
end;

class procedure TCsvSerializer.ResetConfiguration;
begin
  TCsvEngine.ResetConfiguration;
end;


{ ---------------------------------------------------------------- dynamic --- }

class function TCsvSerializer.ToDynamic(const ACsv: string): TDynamicValue;
begin
  Result := ToDynamic(ACsv, TCsvOptions.Default);
end;

class function TCsvSerializer.ToDynamic(const ACsv: string;
  const AOptions: TCsvOptions): TDynamicValue;
begin
  Result := TCsvEngine.TextToDynamic(ACsv, AOptions,
    TStructuralConversionOptions.Default);
end;

class function TCsvSerializer.FromDynamic(AValue: TDynamicValue): string;
begin
  Result := FromDynamic(AValue, TCsvOptions.Default);
end;

class function TCsvSerializer.FromDynamic(AValue: TDynamicValue;
  const AOptions: TCsvOptions): string;
begin
  Result := TCsvEngine.DynamicToText(AValue, AOptions,
    TStructuralConversionOptions.Default);
end;

end.
