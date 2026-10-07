{*******************************************************************************
  PascalForge.DataSet

  Public DataSet facade for PascalForge.Serialization.

  Responsibilities
    - Projecting DTOs onto TDataSet: structure creation and row filling.
    - DataSet attributes, type serializers and configuration.
    - DataSet snapshots and deltas in any registered format
      (TDataSetSerializer.Serialize and the reading counterparts).

  Registration
    Projecting a Delphi value needs no format registration. Reading or
    writing an encoded format goes through the registry, so that format must
    be registered explicitly at startup, e.g.
    TJsonSerializationRegistration.RegisterFormat.

  Configuration
    Global DataSet configuration becomes immutable after first use.

  Documentation
    docs/dataset-formats.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.DataSet;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  Projecting a DTO onto a TDataSet - the public API.

  This one unit is enough for everything an application normally does: create
  the schema, fill rows, the [DataSetName]/[DataSetField]/[DataSetHandler]/
  [DataSetIgnore] attributes, and every registration that customises how a
  member becomes a column.

      uses
        PascalForge.DataSet;

  The projection engine - cached plans, RTTI traversal, field writing - lives
  in PascalForge.DataSet.Internal and is not part of this contract.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.DateUtils, System.NetEncoding, System.Generics.Collections,
  Data.DB, FireDAC.Comp.Client, Datasnap.DBClient,
  PascalForge.Nullable,
  PascalForge.Serialization.Core, PascalForge.Dynamic;

type
  EDataSetSerializationError = class(Exception);

  { ------------------------------------------------------------------------
    WHAT OF A DATASET GOES INTO A DOCUMENT

    Orthogonal to TSerializationFormat, and deliberately so. Every one of
    these can be written as JSON, as XML, as BSON or as anything else the
    registry knows; choosing one says nothing about choosing the other, and
    there is no per-format policy type to keep in step.
    ------------------------------------------------------------------------ }
  TDataSetSerializationPolicy = (
    { The rows alone, as an array. The smallest document - and the one that
      cannot be read back without a schema from somewhere else, because an
      array of rows does not say what any column IS. }
    RowsOnly,
    { Schema and rows. The exact round trip. }
    StructureAndRows,
    { Only what changed since the last merge: inserted, modified and deleted
      rows with their before and after values. Needs a DataSet that keeps a
      change journal - TFDMemTable or TClientDataSet. }
    DeltaOnly,
    { The same, with the schema in front of it. }
    DeltaAndStructure
  );

  { ------------------------------------------------------------------------
    WHERE THE SCHEMA COMES FROM, READING

    A document that arrives from outside either describes its own columns or
    does not, and the two cases need different handling. This says which one
    the caller is in - or asks the library to find out.
    ------------------------------------------------------------------------ }
  TDataSetSourceMode = (
    { Look at the document. If it carries a complete DataSet schema, use it;
      if it plainly does not, infer the schema from the rows. The default,
      and the only mode that needs no advance knowledge of what will
      arrive. }
    Auto,
    { Ignore any embedded schema and infer from the data, always. For a
      document whose "fields" and "rows" members are its own data rather
      than a description of a table. }
    InferStructure,
    { Require the embedded schema. A document without a usable one is an
      error naming what was missing, rather than something to guess at. }
    EmbeddedStructure
  );

  { What a document turned out to be, when asked whether it carries a
    DataSet schema. }
  TDataSetMetadataMatch = (
    { Nothing in it claims to describe a table. Ordinary data, and Auto
      infers. }
    NotMetadata,
    { It matches the schema completely and can be used as it stands. }
    ValidMetadata,
    { It CLAIMS to be a table description - the members are there, in the
      right shapes, at the top - but something inside does not check out: a
      column with no name, a type that is not a field type, a row that is
      not an object.

      Deliberately not folded into NotMetadata. Silently treating a broken
      schema as ordinary data would produce a two-column table called
      "fields" and "rows", which is nobody's intention, so Auto reports it
      instead. }
    InvalidMetadata
  );

  { ------------------------------------------------------------------------
    IS THIS DOCUMENT A TABLE?

    The question is answered on the DYNAMIC STRUCTURAL TREE - after the
    source format has parsed itself, before anything DataSet-specific
    happens - so there is one implementation of the rule and a packet
    written as XML is recognized by the same code that recognizes one
    written as BSON.

    IT IS ANSWERED BY SHAPE ALONE. There is no marker, no namespace, no
    version member and no library signature to look for. A document
    produced by somebody else's tooling that genuinely describes a table is
    read as one; a document of this library's that has been edited into
    something else is not. The recognized shape is

        fields : a non-empty list of objects, each with a name and a type
        rows   : a list of objects

    or, for a change list, Fields and Delta.
    ------------------------------------------------------------------------ }
  TDataSetEmbeddedStructureDetector = record
  public
    class function Classify(ARoot: TDynamicValue): TDataSetMetadataMatch; static;
    { One sentence saying why Classify answered as it did. Suitable for an
      error message and for a user interface that wants to show it. }
    class function Explain(ARoot: TDynamicValue): string; static;
    { True for the change-list shape rather than the table shape. Only
      meaningful when Classify said ValidMetadata. }
    class function IsDelta(ARoot: TDynamicValue): Boolean; static;
  end;


  TCustomDataSetFieldHandler = class
  public
    function FieldType: TFieldType; virtual; abstract;
    function FieldSize: Integer; virtual;
    procedure WriteValue(const AField: TField; const AValue: TValue); virtual; abstract;
  end;
  TDataSetFieldHandlerClass = class of TCustomDataSetFieldHandler;

  TCustomDataSetTypeSerializer = class
  public
    procedure AddFields(ATypeInfo: PTypeInfo; AFieldDefs: TFieldDefs;
      const APrefix: string); virtual; abstract;
    procedure WriteValue(ATypeInfo: PTypeInfo; const AValue: TValue;
      ADataSet: TDataSet; const APrefix: string); virtual; abstract;
  end;
  TDataSetTypeSerializerClass = class of TCustomDataSetTypeSerializer;

  { ------------------------------------------------------------------------
    THE TYPED EXTENSION LAYER

    Everything below exists so that writing a DTO member into a dataset field
    never requires TValue or PTypeInfo.  It is a layer over the two untyped
    contracts above, not a replacement for them: the untyped forms remain the
    universal contract, and a handler that deliberately covers several
    runtime types still implements TCustomDataSetFieldHandler directly.
    ---------------------------------------------------------------------- }

  { NORMAL.  Write one value of one known Delphi type into one dataset field.

      type
        TMoneyHandler = class(TCustomDataSetFieldHandler<TMoney>)
          function FieldType: TFieldType; override;
          procedure WriteValue(const AValue: TMoney;
            AField: TField); override;
        end;

      function TMoneyHandler.FieldType: TFieldType;
      begin
        Result := ftBCD;
      end;

      procedure TMoneyHandler.WriteValue(const AValue: TMoney;
        AField: TField);
      begin
        AField.AsCurrency := AValue.Amount;
      end;

    Override FieldSize as well when the field type needs one (ftString,
    ftBytes, ftBCD precision and so on). }
  TCustomDataSetFieldHandler<T> = class(TCustomDataSetFieldHandler)
  public
    procedure WriteValue(const AValue: T;
      AField: TField); reintroduce; overload; virtual; abstract;
    { The bridge the engine calls.  Converts, then delegates.  Not intended
      to be overridden. }
    procedure WriteValue(const AField: TField;
      const AValue: TValue); overload; override;
  end;

  { NORMAL.  The same thing as a function, for a handler with no state worth
    a class.  Used through TDataSetFieldOverride.WriteWith<T> and
    TDataSetSerializer.RegisterTypeHandler<T>.

    A delegate is captured once, at registration, and called concurrently
    without a lock: it must be stateless, or capture only immutable state. }
  TDataSetWriteProc<T> = reference to procedure(const AValue: T;
    AField: TField);

  { NORMAL.  Project one value of one known Delphi type onto SEVERAL dataset
    fields - the flattening case, where a single DTO member becomes
    'Validity.From' and 'Validity.To'.

      type
        TPeriodSerializer = class(TCustomDataSetTypeSerializer<TPeriod>)
        public
          procedure AddFields(AFieldDefs: TFieldDefs;
            const APrefix: string); override;
          procedure WriteValue(const AValue: TPeriod; ADataSet: TDataSet;
            const APrefix: string); override;
        end;

      procedure TPeriodSerializer.AddFields(AFieldDefs: TFieldDefs;
        const APrefix: string);
      begin
        AFieldDefs.Add(APrefix + 'From', ftDate);
        AFieldDefs.Add(APrefix + 'To', ftDate);
      end;

    APrefix is the already-composed name stem for this member, dot included
    ('Validity.'); append the part name to it in BOTH methods, identically. }
  TCustomDataSetTypeSerializer<T> = class(TCustomDataSetTypeSerializer)
  public
    procedure AddFields(AFieldDefs: TFieldDefs;
      const APrefix: string); reintroduce; overload; virtual; abstract;
    procedure WriteValue(const AValue: T; ADataSet: TDataSet;
      const APrefix: string); reintroduce; overload; virtual; abstract;
    { The bridges the engine calls.  Not intended to be overridden. }
    procedure AddFields(ATypeInfo: PTypeInfo; AFieldDefs: TFieldDefs;
      const APrefix: string); overload; override;
    procedure WriteValue(ATypeInfo: PTypeInfo; const AValue: TValue;
      ADataSet: TDataSet; const APrefix: string); overload; override;
  end;

  { INTERNAL.  The adapter behind every delegate registration.  It is an
    ordinary TCustomDataSetFieldHandler<T>, so the engine cannot tell a
    delegate registration from a class registration.  Reach it through
    TDataSetFieldOverride.WriteWith<T> or
    TDataSetSerializer.RegisterTypeHandler<T>, never directly. }
  TDataSetDelegateHandler<T> = class(TCustomDataSetFieldHandler<T>)
  private
    FFieldType: TFieldType;
    FFieldSize: Integer;
    FWrite: TDataSetWriteProc<T>;
  public
    constructor Create(AFieldType: TFieldType; AFieldSize: Integer;
      const AWrite: TDataSetWriteProc<T>);
    function FieldType: TFieldType; override;
    function FieldSize: Integer; override;
    procedure WriteValue(const AValue: T; AField: TField); override;
  end;

  TDataSetFieldOverride = record
  public
    HasFieldName: Boolean; FieldName: string;
    HasFieldType: Boolean; FieldType: TFieldType;
    HasFieldSize: Boolean; FieldSize: Integer;
    HandlerClass: TDataSetFieldHandlerClass;
    { Set instead of HandlerClass when the handler was built from delegates.
      The plan treats the two identically; see PickHandler. }
    HandlerInstance: TCustomDataSetFieldHandler;
    HasIgnore: Boolean; DoIgnore: Boolean;
    class function Rename(const AName: string): TDataSetFieldOverride; static;
    class function WithSize(ASize: Integer): TDataSetFieldOverride; static;
    class function WithType(AType: TFieldType; ASize: Integer = 0): TDataSetFieldOverride; static;
    { ADVANCED.  Any handler, including one that covers several runtime
      types.  Prefer one of the WriteWith forms below. }
    class function HandleWith(
      AHandlerClass: TDataSetFieldHandlerClass): TDataSetFieldOverride; static;

    { NORMAL.  A TCustomDataSetFieldHandler<T> for a member of type T.
      Checked here, where the registration is written:
        TDataSetFieldOverride.WriteWith<TMoney>(TMoneyHandler) }
    class function WriteWith<T>(
      AHandlerClass: TDataSetFieldHandlerClass): TDataSetFieldOverride; overload; static;
    { NORMAL, compile-time checked - the compiler rejects a handler that does
      not handle T:
        TDataSetFieldOverride.WriteWith<TMoney, TMoneyHandler> }
    class function WriteWith<T; THandler: TCustomDataSetFieldHandler<T>,
      constructor>: TDataSetFieldOverride; overload; static;
    { NORMAL.  No handler class at all - a field type and one procedure:
        TDataSetFieldOverride.WriteWith<TMoney>(ftCurrency,
          procedure(const AValue: TMoney; AField: TField)
          begin
            AField.AsCurrency := AValue.Amount;
          end) }
    class function WriteWith<T>(AFieldType: TFieldType;
      const AWrite: TDataSetWriteProc<T>): TDataSetFieldOverride; overload; static;
    { The same, for a field type that needs a size - ftString, ftBytes,
      ftWideString:
        TDataSetFieldOverride.WriteWith<TIban>(ftString, 34,
          procedure(const AValue: TIban; AField: TField)
          begin
            AField.AsString := AValue.Formatted;
          end) }
    class function WriteWith<T>(AFieldType: TFieldType; AFieldSize: Integer;
      const AWrite: TDataSetWriteProc<T>): TDataSetFieldOverride; overload; static;

    class function Create(const AName: string; AType: TFieldType;
      ASize: Integer;
      AHandlerClass: TDataSetFieldHandlerClass): TDataSetFieldOverride; static;
    class function Ignore: TDataSetFieldOverride; static;
  end;

  { ------------------------------------------------------------------------
    INTERNAL INFRASTRUCTURE.

    TDataSetTypePlan, TDataSetFieldPlan, TDataSetMemberPlan, TDsKind and
    PlanFor are the cached execution plans of the DataSet engine.  They are
    declared here only because they appear in TDataSetSerializer's own
    private method signatures and because PascalForge.DataSet.Json consumes a
    small part of them.  Their fields, ownership rules and lifetimes are
    implementation detail and may change without notice.  Do not construct,
    mutate or retain them from application code.
    ------------------------------------------------------------------------ }

  { ------------------------------------------------------------------------
    ATTRIBUTES

    Annotate a member where it is declared.  They live in this unit, so a DTO
    needs no second uses entry:

        type
          TPriceRow = class
          public
            [DataSetName('PRICE')]          Net: Currency;
            [DataSetField(ftString, 34)]    Sku: string;
            [DataSetHandler(TMoneyHandler)] Fee: TMoney;
            [DataSetIgnore]                 Scratch: Integer;
          end;
    ------------------------------------------------------------------------ }

  { The column name to use instead of the member name. }
  DataSetNameAttribute = class(TCustomAttribute)
  private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

  { The column type, and a size for the types that need one. }
  DataSetFieldAttribute = class(TCustomAttribute)
  private
    FFieldType: TFieldType;
    FSize: Integer;
  public
    constructor Create(AFieldType: TFieldType; ASize: Integer = 0);
    property FieldType: TFieldType read FFieldType;
    property Size: Integer read FSize;
  end;

  { Write this member through a specific handler.  The class is checked by the
    compiler. }
  DataSetHandlerAttribute = class(TCustomAttribute)
  private
    FHandlerClass: TDataSetFieldHandlerClass;
  public
    constructor Create(AHandlerClass: TDataSetFieldHandlerClass);
    property HandlerClass: TDataSetFieldHandlerClass read FHandlerClass;
  end;

  { Leave the member out of the projection entirely. }
  DataSetIgnoreAttribute = class(TCustomAttribute)
  end;

  { ------------------------------------------------------------------------
    INFRASTRUCTURE.

    The typed handler layer above is built out of these two, so the conversion
    and ownership they perform is written once rather than in every handler.
    Normal code never calls them; they are published only because a generic
    method body may reference nothing but interface declarations.
    ------------------------------------------------------------------------ }
  TDataSetExtensionSupport = class
  public
    { AValue.AsType<T> with a message that says which handler expected what
      and what it actually received.  A failure here is framework misuse - a
      handler registered against the wrong member - not bad data. }
    class function ValueAsTyped<T>(const AValue: TValue;
      AHandlerClass: TClass): T; static;
    { Takes ownership of a handler the framework built itself - today, a
      delegate adapter - so its captured closure lives exactly as long as the
      registrations that use it.  Returns the same instance. }
    class function AdoptHandler(
      AInstance: TCustomDataSetFieldHandler): TCustomDataSetFieldHandler; static;
  end;

  { ------------------------------------------------------------------------
    THE PROJECTION

    CreateStructure builds the schema, Fill writes values into a schema that
    already exists, and CreateAndFill does both in one call.  The three stay
    distinct on purpose: Fill never rebuilds a schema behind your back.
    ------------------------------------------------------------------------ }
  { ------------------------------------------------------------------------
    SCHEMA INFERENCE FROM A STRUCTURAL DOCUMENT

    For the case where there is no Delphi contract: somebody handed you JSON,
    XML or BSON and you want a DataSet out of it. The structure of the
    document decides the schema.

    The input is a TDynamicValue - the format-dynamic structural tree from
    PascalForge.Serialization.Core - so this code is shared by every format
    and knows about none of them. A format contributes by turning its bytes
    into that tree, which is what its handler's ToDynamic already does; no
    format's own DOM ever reaches here.

    WHAT IS NOT DONE. A string stays a string. A JSON member spelled
    "2026-09-14" is not promoted to a date, because JSON never said it was
    one and guessing from the spelling is how the same document becomes a
    timestamp in one system and text in the next. BSON's native datetime IS a
    datetime, because BSON says so. That asymmetry is the point: inference
    preserves what the source format actually stated and invents nothing.

    ROOT SHAPES, all deterministic and all documented in
    docs\dataset-projection.md:

      an array of objects   one row per element, columns from every element
      a single object       one row
      an array of scalars   one column named 'value', one row per element
      a scalar              one column named 'value', one row
      an empty array        no schema and no rows - reported, not invented
      null                  no schema and no rows
      a mixed array         objects contribute their columns; a scalar
                            element contributes to 'value'
    ------------------------------------------------------------------------ }
  TDataSetSchemaInference = class
  public
    { Widens across ALL non-null values in the column, not just the first:
        Integer + Largeint          -> Largeint
        Integer/Largeint + Float    -> Float
        DateTime + DateTime         -> DateTime
        Binary + Binary             -> Blob
        anything else mixed         -> WideString
      ASize is the maximum observed text length for string columns and 0
      otherwise. Returns False when the column has no non-null value in any
      row, in which case AFieldType/ASize describe the documented WideString
      fallback. }
    class function InferFieldType(ARows: TDynamicValue;
      const AFieldName: string; out AFieldType: TFieldType;
      out ASize: Integer): Boolean; static;

    { Appends one field def per distinct member name across ARows, in the
      order the names were first seen. Returns False and adds nothing when no
      schema can be inferred; it never invents a placeholder column. }
    class function InferSchema(ARows: TDynamicValue;
      ADefs: TFieldDefs): Boolean; static;

    { InferSchema against ADataSet.FieldDefs. Does nothing and returns False
      when the DataSet already has a schema. }
    class function InferSchemaInto(ARows: TDynamicValue;
      ADataSet: TDataSet): Boolean; static;

    { Normalizes any structural root into the row array the two methods above
      expect, by the table at the top of this comment. The result is a NEW
      tree that the caller owns; ARoot is left alone. }
    class function RowsOf(ARoot: TDynamicValue): TDynamicValue; static;

    { The whole job: normalize the root, infer the schema, activate the
      DataSet and write the rows. ADataSet must be closed and empty. }
    class procedure Project(ARoot: TDynamicValue; ADataSet: TDataSet); static;
  end;

  TDataSetSerializer = class
  strict private
    { A generic method body declared in an interface section may reference
      only interface-declared symbols, so the contract-aware overloads above
      are thin shells over this one (E2506). }
    class procedure DoFillFromPayload(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload; AFormat: TSerializationFormat;
      ADataSet: TDataSet); static;
    class procedure ProjectPayloadWith(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat; ASchema: TSerializationContext;
      ADataSet: TDataSet); static;
    class procedure ProjectPayload(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat; ADataSet: TDataSet); static;
    { The source, parsed once, as a dynamic tree the caller frees. }
    class function ParseSource(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat): TDynamicValue; static;
    { The mode decision, in one place, so every entry point makes it the
      same way. }
    class procedure ApplyTree(ATree: TDynamicValue; ADataSet: TDataSet;
      AMode: TDataSetSourceMode); static;
    { FromDynamic<T>'s body, reachable from a generic method (E2506). }
    class procedure DoFillFromDynamic(ATypeInfo: PTypeInfo;
      AValue: TDynamicValue; ADataSet: TDataSet); static;
  strict private
    { The engine lives in a unit this one may only reach from its
      implementation section, and a generic method body may reference nothing
      but interface declarations.  These bridges are how the generic entry
      points below get there. }
    class procedure DoCreateStructure(ATypeInfo: PTypeInfo;
      ADataSet: TDataSet); static;
    class procedure DoFill(ATypeInfo: PTypeInfo; AInstance: Pointer;
      ADataSet: TDataSet); static;
    class procedure DoCheckNotFrozen; static;
    class procedure DoRegisterTypeHandler(ATypeInfo: PTypeInfo;
      AHandlerClass: TDataSetFieldHandlerClass); static;
    class procedure DoPublishHandler(AHandlerClass: TDataSetFieldHandlerClass;
      AInstance: TCustomDataSetFieldHandler); static;
  public
    class function GetDefaultStringSize: Integer; static;
    class procedure SetDefaultStringSize(AValue: Integer); static;
  public
    { Default width for string projections.  A property rather than a public
      class var so that changing it after FreezeConfiguration is a clear
      configuration error instead of a silent divergence from cached plans. }
    class property DefaultStringSize: Integer read GetDefaultStringSize
      write SetDefaultStringSize;

    class procedure CreateStructure<T>(ADataSet: TDataSet); overload; static;
    class procedure CreateStructure(ATypeInfo: PTypeInfo; ADataSet: TDataSet); overload; static;
    class procedure Fill<T>(const AInstance: T; ADataSet: TDataSet); overload; static;
    class procedure Fill(ATypeInfo: PTypeInfo; const AInstance: TObject; ADataSet: TDataSet); overload; static;
    class procedure Fill<T>(const AItems: array of T; ADataSet: TDataSet); overload; static;

    class procedure RegisterFieldOverride(AClass: TClass; const AFieldName: string; const AOverride: TDataSetFieldOverride); overload; static;
    class procedure RegisterFieldOverride(AOwnerTypeInfo: PTypeInfo; const AFieldName: string; const AOverride: TDataSetFieldOverride); overload; static;
    class procedure RegisterFieldOverride(const AQualifiedOwnerTypeName,
      AFieldName: string; const AOverride: TDataSetFieldOverride); overload; static;
    class procedure RegisterChildFieldOverride(AClass: TClass;
      const AFieldName, AChildName: string;
      const AOverride: TDataSetFieldOverride); overload; static;
    class procedure RegisterChildFieldOverride(AOwnerTypeInfo: PTypeInfo;
      const AFieldName, AChildName: string;
      const AOverride: TDataSetFieldOverride); overload; static;
    class procedure RegisterChildFieldOverride(const AQualifiedOwnerTypeName,
      AFieldName, AChildName: string;
      const AOverride: TDataSetFieldOverride); overload; static;
    class procedure RegisterClassFieldOverride(AClass: TClass; const AFieldPattern: string; const AOverride: TDataSetFieldOverride; AIncludeDescendants: Boolean = False); static;
    class procedure RegisterUnitFieldOverride(const AUnitPattern, AFieldPattern: string; const AOverride: TDataSetFieldOverride); static;
    { NORMAL.  Everything of type T, everywhere it appears, is written by
      this handler.  The typed forms are checked; the untyped form is not. }
    class procedure RegisterTypeHandler<T>(
      AHandlerClass: TDataSetFieldHandlerClass); overload; static;
    { Compile-time checked - the compiler rejects a handler that does not
      handle T:  TDataSetSerializer.RegisterTypeHandler<TMoney, TMoneyHandler>; }
    class procedure RegisterTypeHandler<T; THandler: TCustomDataSetFieldHandler<T>,
      constructor>; overload; static;
    { No handler class at all:
        TDataSetSerializer.RegisterTypeHandler<TMoney>(ftCurrency,
          procedure(const AValue: TMoney; AField: TField)
          begin
            AField.AsCurrency := AValue.Amount;
          end);
      The procedure is captured once, here, and owned by the framework until
      teardown.  It must be stateless or capture only immutable state: filling
      is concurrent and nothing locks around it. }
    class procedure RegisterTypeHandler<T>(AFieldType: TFieldType;
      const AWrite: TDataSetWriteProc<T>); overload; static;
    class procedure RegisterTypeHandler<T>(AFieldType: TFieldType;
      AFieldSize: Integer; const AWrite: TDataSetWriteProc<T>); overload; static;
    class procedure RegisterTypeHandler(ATypeInfo: PTypeInfo;
      AHandlerClass: TDataSetFieldHandlerClass); overload; static;
    { NORMAL.  T is the OWNER type - the DTO that declares AFieldName. }
    class procedure RegisterFieldOverride<T>(const AFieldName: string;
      const AOverride: TDataSetFieldOverride); overload; static;
    { NORMAL.  A projection of T across several fields. }
    class procedure RegisterTypeSerializer<T>(
      ASerializerClass: TDataSetTypeSerializerClass); overload; static;
    class procedure RegisterTypeSerializer<T; TSer: TCustomDataSetTypeSerializer<T>,
      constructor>; overload; static;
    class procedure RegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TDataSetTypeSerializerClass); overload; static;
    class procedure RegisterGenericTypeSerializer(ARepresentativeTypeInfo: PTypeInfo;
      ASerializerClass: TDataSetTypeSerializerClass); static;
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;

    { Schema and rows in one call: exactly CreateStructure<T> followed by
      Fill<T>, with no second projection path.  Like CreateStructure, it
      recreates the schema, so anything the dataset held before is gone. }
    class procedure CreateAndFill<T>(const AValue: T;
      ADataSet: TDataSet); overload; static;
    class procedure CreateAndFill<T>(const AValues: array of T;
      ADataSet: TDataSet); overload; static;

    { ----------------------------------------------------------------------
      When you do not have a dataset yet.

      These construct the concrete dataset, describe its schema, fill it, and
      hand it back open.  They are exactly CreateAndFill<T> with the
      construction in front, not a second projection path.

          DS := TDataSetSerializer.CreateFDMemTable<TEntry>(Entry);
          try
            ...
          finally
            DS.Free;
          end;

      With AOwner nil the result is yours to free.  With an owner, ordinary
      TComponent ownership applies and you must not free it yourself.

      If describing or filling raises, the half-built dataset is freed here
      and the exception propagates: a partially initialised dataset is never
      returned. }
    class function CreateFDMemTable<T>(const AValue: T;
      AOwner: TComponent = nil): TFDMemTable; overload; static;
    class function CreateFDMemTable<T>(const AValues: array of T;
      AOwner: TComponent = nil): TFDMemTable; overload; static;
    class function CreateClientDataSet<T>(const AValue: T;
      AOwner: TComponent = nil): TClientDataSet; overload; static;
    class function CreateClientDataSet<T>(const AValues: array of T;
      AOwner: TComponent = nil): TClientDataSet; overload; static;

    { ----------------------------------------------------------------------
      FROM AN ENCODED DOCUMENT

      Two different operations, which look similar and are not:

        CreateFDMemTable<TShipment>(Json, TSerializationFormat.Json)
            TShipment is the CONTRACT. The source format deserializes into it
            by its own rules, and the existing DTO projection turns it into
            columns. A TDate member becomes ftDate because TShipment says so.

        CreateFDMemTable(Json, TSerializationFormat.Json)
            There is no contract. The structure of the document decides the
            schema, and only what the format itself states about a value is
            used - a JSON string stays ftWideString however much it looks
            like a date. See TDataSetSchemaInference.

      The generic form never falls back to inference, and the non-generic
      form never invents a DTO.

      Both reach the source format through the serialization-format registry,
      so this unit has no compile-time dependency on JSON, XML or BSON. The
      source format has to be registered explicitly at startup; if it is not,
      ESerializationFormatNotRegistered says which one. Projecting a Delphi
      value - CreateFDMemTable<T>(Value) - involves no encoded format and
      needs no registration at all.

      AOwner follows the usual VCL rule: nil means the caller owns the
      result, a component means that component does. If anything raises, the
      half-built DataSet is freed here and never returned. }
    class function CreateFDMemTable<T>(const ASource: string;
      AFormat: TSerializationFormat; AOwner: TComponent = nil): TFDMemTable; overload; static;
    class function CreateFDMemTable<T>(const ASource: TBytes;
      AFormat: TSerializationFormat; AOwner: TComponent = nil): TFDMemTable; overload; static;
    class function CreateFDMemTable<T>(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat; AOwner: TComponent = nil): TFDMemTable; overload; static;

    class function CreateFDMemTable(const ASource: string;
      AFormat: TSerializationFormat; AOwner: TComponent = nil): TFDMemTable; overload; static;
    class function CreateFDMemTable(const ASource: TBytes;
      AFormat: TSerializationFormat; AOwner: TComponent = nil): TFDMemTable; overload; static;
    class function CreateFDMemTable(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat; AOwner: TComponent = nil): TFDMemTable; overload; static;

    class function CreateClientDataSet<T>(const ASource: string;
      AFormat: TSerializationFormat; AOwner: TComponent = nil): TClientDataSet; overload; static;
    class function CreateClientDataSet<T>(const ASource: TBytes;
      AFormat: TSerializationFormat; AOwner: TComponent = nil): TClientDataSet; overload; static;
    class function CreateClientDataSet<T>(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat; AOwner: TComponent = nil): TClientDataSet; overload; static;

    class function CreateClientDataSet(const ASource: string;
      AFormat: TSerializationFormat; AOwner: TComponent = nil): TClientDataSet; overload; static;
    class function CreateClientDataSet(const ASource: TBytes;
      AFormat: TSerializationFormat; AOwner: TComponent = nil): TClientDataSet; overload; static;
    class function CreateClientDataSet(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat; AOwner: TComponent = nil): TClientDataSet; overload; static;

    { ----------------------------------------------------------------------
      A DATASET AS A DOCUMENT, IN ANY FORMAT

      The other direction: a live DataSet written out, in whichever format
      the caller names, with whichever policy they want.

          Payload := TDataSetSerializer.Serialize(Customers,
                       TSerializationFormat.Xml,
                       TDataSetSerializationPolicy.StructureAndRows);

      The two axes are independent. The policy decides WHAT goes in the
      document - rows, schema and rows, or only what changed - and the
      format decides how it is spelled. There is no JSON-only policy type
      and no XML-only one, because the packet is built in the dynamic
      structural tree and handed to the format registry like any other
      document.

      The format has to be registered and has to be able to WRITE
      structurally; if it is not, or cannot, the exception says which. }
    class function Serialize(ADataSet: TDataSet;
      AFormat: TSerializationFormat;
      APolicy: TDataSetSerializationPolicy =
        TDataSetSerializationPolicy.StructureAndRows;
      AIncludeDataSetName: Boolean = False): TSerializationPayload; overload; static;

    { ----------------------------------------------------------------------
      A DATASET AS A DYNAMIC VALUE, AND BACK

      The same packet and the same projection the format paths above use,
      with the encoded document left out - so a DataSet can be inspected,
      changed or merged as a dynamic value and then written in any format,
      and a dynamic value built by hand or read from any format can become a
      DataSet.

      ToDynamic returns a new tree the caller owns; APolicy decides what
      goes in it, as for Serialize.

      FromDynamic reads INTO an existing DataSet, open or closed, under the
      destination contract of Deserialize, and the caller says how the value
      is to be read - there is deliberately no default: a value is a DataSet
      packet only because the caller said so (AMode, APolicy), never because
      it happens to hold members called "fields" and "rows".

        AMode     Auto uses a schema the value carries and infers one when
                  it carries none; InferStructure always infers;
                  EmbeddedStructure requires the schema.
        APolicy  the shape the caller knows the value has - RowsOnly into a
                  DataSet that already has its columns, a change list
                  replayed onto ADataSet's journal.

      FromDynamic<T> is the contract-aware form: T is the DTO, and its
      members - with their DataSet attributes and general attributes -
      decide the columns. An array becomes one row per item; an object one
      row. AValue stays the caller's. }
    class function ToDynamic(ADataSet: TDataSet;
      APolicy: TDataSetSerializationPolicy =
        TDataSetSerializationPolicy.StructureAndRows;
      AIncludeDataSetName: Boolean = False): TDynamicValue; static;
    class procedure FromDynamic(AValue: TDynamicValue; ADataSet: TDataSet;
      AMode: TDataSetSourceMode); overload; static;
    class procedure FromDynamic(AValue: TDynamicValue; ADataSet: TDataSet;
      APolicy: TDataSetSerializationPolicy); overload; static;
    class procedure FromDynamic<T>(AValue: TDynamicValue;
      ADataSet: TDataSet); overload; static;

    { ----------------------------------------------------------------------
      AND BACK

      Reads an encoded document into an EXISTING DataSet, open or closed.
      AMode decides where the schema comes from - see TDataSetSourceMode.
      The document owns the schema: the DataSet is closed, cleared and
      rebuilt, so anything it held is gone. For a populated TFDMemTable or
      TClientDataSet (or descendant) the complete projection is first
      pre-validated on a temporary instance, so a schema, value or
      projection failure the library can detect does not destroy the
      existing DataSet. Application callbacks or destination-specific
      behaviour during the final application may still raise after
      rebuilding has begun. See THE DESTINATION CONTRACT in the
      implementation.

      Auto is the default and is what most callers want: a document this
      library wrote with StructureAndRows describes its own columns and is
      used as it stands, and a document that does not is inferred. A
      RowsOnly document is by construction indistinguishable from an
      ordinary array of objects, so Auto infers it - which is the honest
      answer, because nothing in it says otherwise. }
    class procedure Deserialize(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat; ADataSet: TDataSet;
      AMode: TDataSetSourceMode = TDataSetSourceMode.Auto); overload; static;
    class procedure Deserialize(const ASource: string;
      AFormat: TSerializationFormat; ADataSet: TDataSet;
      AMode: TDataSetSourceMode = TDataSetSourceMode.Auto); overload; static;
    class procedure Deserialize(const ASource: TBytes;
      AFormat: TSerializationFormat; ADataSet: TDataSet;
      AMode: TDataSetSourceMode = TDataSetSourceMode.Auto); overload; static;

    { THE SAME, FOR A FORMAT WHOSE SCHEMA IS NOT IN ITS BYTES.

      Protobuf, Avro and ASN.1 cannot be read without the descriptor, the
      writer schema or the module that says what the bytes mean. That
      context is BORROWED - the caller owns it and it has to outlive the
      call - and it is the only thing that differs from the overload above:
      the projection, the inference and the field types are the same generic
      machinery, because a DataSet does not care where the shape came from.

      There is no AMode, because a document that needed a context to be read
      at all did not describe its own columns; its schema comes from the
      context and the rows are inferred from the tree. The destination
      contract is the overload's above: open or closed, it is rebuilt, after
      the same pre-validation. }
    class procedure Deserialize(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat; AContext: TSerializationContext;
      ADataSet: TDataSet); overload; static;

    { The same, constructing the DataSet. AOwner follows the usual VCL rule:
      nil means the caller owns the result. If anything raises, the
      half-built DataSet is freed here and never returned. }
    class function CreateFDMemTable(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat; AMode: TDataSetSourceMode;
      AOwner: TComponent = nil): TFDMemTable; overload; static;
    class function CreateFDMemTable(const ASource: string;
      AFormat: TSerializationFormat; AMode: TDataSetSourceMode;
      AOwner: TComponent = nil): TFDMemTable; overload; static;
    class function CreateFDMemTable(const ASource: TBytes;
      AFormat: TSerializationFormat; AMode: TDataSetSourceMode;
      AOwner: TComponent = nil): TFDMemTable; overload; static;

    { WITH A SCHEMA, for a format that cannot read its own bytes.

      Avro is the one here: its bytes carry no type information at all, so a
      structural read of them needs the writer's schema and there is nowhere
      else to put it. The schema is BORROWED - the caller owns it and it has
      to outlive the call - and it stays format-specific, so a TAvroSchema
      goes to Avro and to nothing else.

      For every other format this overload is simply the one above with a
      nil schema, which is what the plain call already passes. }
    class function CreateClientDataSet(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat; ASchema: TSerializationContext;
      AOwner: TComponent = nil): TClientDataSet; overload; static;
    class function CreateFDMemTable(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat; ASchema: TSerializationContext;
      AOwner: TComponent = nil): TFDMemTable; overload; static;

    class function CreateClientDataSet(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat; AMode: TDataSetSourceMode;
      AOwner: TComponent = nil): TClientDataSet; overload; static;
    class function CreateClientDataSet(const ASource: string;
      AFormat: TSerializationFormat; AMode: TDataSetSourceMode;
      AOwner: TComponent = nil): TClientDataSet; overload; static;
    class function CreateClientDataSet(const ASource: TBytes;
      AFormat: TSerializationFormat; AMode: TDataSetSourceMode;
      AOwner: TComponent = nil): TClientDataSet; overload; static;

    { The other way round: the caller already knows what shape the document
      has, because they asked for it with that policy, and says so instead
      of asking the library to work it out.

      This is the form to use for a RowsOnly document - which cannot be
      told from an ordinary array of objects and so needs a schema the
      DataSet already has - and for a change list, which is replayed onto
      ADataSet so that its own journal ends up holding the same changes. }
    class procedure DeserializeAs(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat; ADataSet: TDataSet;
      APolicy: TDataSetSerializationPolicy); overload; static;
    class procedure DeserializeAs(const ASource: string;
      AFormat: TSerializationFormat; ADataSet: TDataSet;
      APolicy: TDataSetSerializationPolicy); overload; static;
    class procedure DeserializeAs(const ASource: TBytes;
      AFormat: TSerializationFormat; ADataSet: TDataSet;
      APolicy: TDataSetSerializationPolicy); overload; static;

    { What a document IS, before deciding what to do with it. Parses the
      source with the named format and asks the detector. For a caller - or
      a user interface - that wants to show the answer rather than act on
      it. }
    class function ClassifySource(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat): TDataSetMetadataMatch; overload; static;
    class function ExplainSource(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat): string; static;

    { The schema a document carries, without building the table. Raises when
      the document carries none. }
    class procedure ReadFieldDefs(const ASource: TSerializationPayload;
      AFormat: TSerializationFormat; ADefs: TFieldDefs); static;
  end;

implementation

uses
  PascalForge.DataSet.Internal, PascalForge.DataSet.Packet;
{ ------------------------------------------------- TDataSetSchemaInference --- }

{$SCOPEDENUMS OFF}
type
  { The widening lattice, ordered from narrowest to widest. Two values in a
    column widen to the narrowest kind that can hold both. }
  TInferredKind = (ikNone, ikBoolean, ikInteger, ikLargeint, ikFloat,
    ikDate, ikTime, ikDateTime, ikBinary, ikString);
{$SCOPEDENUMS ON}

function InferredKindOf(AValue: TDynamicValue): TInferredKind;
begin
  if AValue = nil then Exit(ikNone);
  case AValue.Kind of
    TDynamicKind.Null: Result := ikNone;
    TDynamicKind.Bool: Result := ikBoolean;
    TDynamicKind.Int:
      if (AValue.AsInt > High(Integer)) or (AValue.AsInt < Low(Integer)) then
        Result := ikLargeint
      else
        Result := ikInteger;
    { An unsigned value is above High(Int64) - a smaller one is an Int - so
      no integer field holds it; its exact digits do. }
    TDynamicKind.UInt: Result := ikString;
    TDynamicKind.Float, TDynamicKind.Decimal: Result := ikFloat;
    TDynamicKind.Bytes: Result := ikBinary;
    { Only because the SOURCE FORMAT said so. A string that happens to look
      like a date is a string; see the comment on the class. }
    TDynamicKind.Date: Result := ikDate;
    TDynamicKind.Time: Result := ikTime;
    TDynamicKind.DateTime: Result := ikDateTime;
  else
    { A string, and also an object or an array, which become their text
      description rather than being flattened into the parent row. }
    Result := ikString;
  end;
end;

function WidenInferredKind(A, B: TInferredKind): TInferredKind;
begin
  if A = ikNone then Exit(B);
  if B = ikNone then Exit(A);
  if A = B then Exit(A);
  { Numeric widening. Every other mix - a boolean with a number, a datetime
    with a string - falls back to the documented WideString representation,
    because there is no narrower type that can hold both without lying. }
  if (A in [ikInteger, ikLargeint, ikFloat]) and
     (B in [ikInteger, ikLargeint, ikFloat]) then
  begin
    if (A = ikFloat) or (B = ikFloat) then Exit(ikFloat);
    Exit(ikLargeint);
  end;
  { Temporal widening, and only the coherent half of it. A column holding
    days and instants is a column of instants, and the same for times; a
    column holding days and times of day is neither, and falls through to
    text rather than inventing a moment that joins them. }
  if (A in [ikDate, ikDateTime]) and (B in [ikDate, ikDateTime]) then
    Exit(ikDateTime);
  if (A in [ikTime, ikDateTime]) and (B in [ikTime, ikDateTime]) then
    Exit(ikDateTime);
  Result := ikString;
end;

{ The text a scalar contributes to a WideString column, and to the maximum
  length that sizes it. }
function DynamicText(AValue: TDynamicValue): string;
begin
  if AValue = nil then Exit('');
  case AValue.Kind of
    TDynamicKind.Null: Result := '';
    TDynamicKind.Bool: if AValue.AsBool then Result := 'true' else Result := 'false';
    TDynamicKind.Int: Result := IntToStr(AValue.AsInt);
    TDynamicKind.UInt: Result := UIntToStr(AValue.AsUInt);
    TDynamicKind.Decimal: Result := AValue.AsDecimal;
    TDynamicKind.Float: Result := TStructuralText.EncodeFloat(AValue.AsFloat);
    TDynamicKind.Str: Result := AValue.AsStr;
    TDynamicKind.Bytes: Result := TNetEncoding.Base64.EncodeBytesToString(AValue.AsBytes);
    TDynamicKind.Date: Result := TStructuralText.EncodeDate(AValue.AsDateTime);
    TDynamicKind.Time: Result := TStructuralText.EncodeTime(AValue.AsDateTime);
    TDynamicKind.DateTime:
      Result := TStructuralText.EncodeDateTime(AValue.AsDateTime);
  else
    Result := AValue.Describe;
  end;
end;

class function TDataSetSchemaInference.InferFieldType(ARows: TDynamicValue;
  const AFieldName: string; out AFieldType: TFieldType;
  out ASize: Integer): Boolean;
var
  I: Integer;
  Row, V: TDynamicValue;
  Kind: TInferredKind;
  MaxLen: Integer;
begin
  Kind := ikNone;
  MaxLen := 0;
  if (ARows <> nil) and (ARows.Kind = TDynamicKind.Arr) then
    for I := 0 to ARows.Count - 1 do
    begin
      Row := ARows[I];
      if (Row = nil) or (Row.Kind <> TDynamicKind.Obj) then Continue;
      V := FindFieldMember(Row, AFieldName);
      if (V = nil) or (V.Kind = TDynamicKind.Null) then Continue;
      Kind := WidenInferredKind(Kind, InferredKindOf(V));
      if Length(DynamicText(V)) > MaxLen then MaxLen := Length(DynamicText(V));
    end;
  Result := Kind <> ikNone;
  ASize := 0;
  case Kind of
    ikBoolean: AFieldType := ftBoolean;
    ikInteger: AFieldType := ftInteger;
    ikLargeint: AFieldType := ftLargeint;
    ikFloat: AFieldType := ftFloat;
    ikDate: AFieldType := ftDate;
    ikTime: AFieldType := ftTime;
    ikDateTime: AFieldType := ftDateTime;
    ikBinary: AFieldType := ftBlob;
  else
    { ikString, and the all-null fallback. }
    AFieldType := ftWideString;
    ASize := MaxLen;
    if ASize < 1 then ASize := 1;
  end;
end;

{ True when this member is a nested table rather than a scalar: an array of
  objects, or an object. A nested scalar array becomes a one-column table. }
function IsNestedMember(AValue: TDynamicValue): Boolean;
begin
  Result := (AValue <> nil) and
    (AValue.Kind in [TDynamicKind.Obj, TDynamicKind.Arr]);
end;

{ Every row a nested member contributes, as a row array the caller owns. }
function NestedRowsOf(AValue: TDynamicValue): TDynamicValue;
var
  I: Integer;
  Wrapper: TDynamicValue;
begin
  Result := TDynamicValue.NewArray;
  try
    if AValue = nil then Exit;
    if AValue.Kind = TDynamicKind.Obj then
    begin
      Result.AsArray.Adopt(AValue.Clone);
      Exit;
    end;
    for I := 0 to AValue.Count - 1 do
      if AValue[I].Kind = TDynamicKind.Obj then
        Result.AsArray.Adopt(AValue[I].Clone)
      else
      begin
        { An array of scalars becomes a one-column table, so nothing is
          flattened away and nothing is invented. }
        Wrapper := TDynamicValue.NewObject;
        Wrapper.AsObject.Adopt('value', AValue[I].Clone);
        Result.AsArray.Adopt(Wrapper);
      end;
  except
    Result.Free;
    raise;
  end;
end;

class function TDataSetSchemaInference.InferSchema(ARows: TDynamicValue;
  ADefs: TFieldDefs): Boolean;
var
  Names: TStringList;
  I, J: Integer;
  Row, V: TDynamicValue;
  FieldType: TFieldType;
  Size: Integer;
  FD: TFieldDef;
  Nested: TDynamicValue;
  Name: string;
begin
  Result := False;
  if (ARows = nil) or (ADefs = nil) or (ARows.Kind <> TDynamicKind.Arr) then Exit;
  Names := TStringList.Create;
  try
    Names.CaseSensitive := False;
    Names.Duplicates := dupIgnore;
    for I := 0 to ARows.Count - 1 do
    begin
      Row := ARows[I];
      if (Row = nil) or (Row.Kind <> TDynamicKind.Obj) then Continue;
      for J := 0 to Row.Count - 1 do
        if Names.IndexOf(Row.Names[J]) < 0 then Names.Add(Row.Names[J]);
    end;
    { No columns means no schema. Reporting that honestly is the point; a
      placeholder column would corrupt whatever is built on top of it. }
    if Names.Count = 0 then Exit;

    for Name in Names do
    begin
      { Is this member a nested structure anywhere in the document? One row
        deciding it is enough - a column is one shape for the whole table. }
      Nested := nil;
      for I := 0 to ARows.Count - 1 do
      begin
        Row := ARows[I];
        if (Row = nil) or (Row.Kind <> TDynamicKind.Obj) then Continue;
        V := FindFieldMember(Row, Name);
        if IsNestedMember(V) then
        begin
          Nested := V;
          Break;
        end;
      end;

      if Nested <> nil then
      begin
        FD := ADefs.AddFieldDef;
        FD.Name := Name;
        FD.DataType := ftDataSet;
        V := NestedRowsOf(Nested);
        try
          { A nested table with no inferable columns is left empty rather
            than given an invented one. }
          InferSchema(V, FD.ChildDefs);
        finally
          V.Free;
        end;
      end
      else
      begin
        InferFieldType(ARows, Name, FieldType, Size);
        ADefs.Add(Name, FieldType, Size);
      end;
    end;
    Result := True;
  finally
    Names.Free;
  end;
end;

class function TDataSetSchemaInference.InferSchemaInto(ARows: TDynamicValue;
  ADataSet: TDataSet): Boolean;
begin
  Result := False;
  if (ADataSet = nil) or (ADataSet.FieldDefs.Count > 0) then Exit;
  Result := InferSchema(ARows, ADataSet.FieldDefs);
end;

class function TDataSetSchemaInference.RowsOf(ARoot: TDynamicValue): TDynamicValue;
var
  I: Integer;
  Wrapper: TDynamicValue;
begin
  Result := TDynamicValue.NewArray;
  try
    if (ARoot = nil) or (ARoot.Kind = TDynamicKind.Null) then Exit;
    case ARoot.Kind of
      TDynamicKind.Obj: Result.AsArray.Adopt(ARoot.Clone);
      TDynamicKind.Arr:
        for I := 0 to ARoot.Count - 1 do
          if ARoot[I].Kind = TDynamicKind.Obj then
            Result.AsArray.Adopt(ARoot[I].Clone)
          else
          begin
            Wrapper := TDynamicValue.NewObject;
            Wrapper.AsObject.Adopt('value', ARoot[I].Clone);
            Result.AsArray.Adopt(Wrapper);
          end;
    else
      { A bare scalar is one row of one column. }
      Wrapper := TDynamicValue.NewObject;
      Wrapper.AsObject.Adopt('value', ARoot.Clone);
      Result.AsArray.Adopt(Wrapper);
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ Writes one row's members into ADataSet, which is already in Append. }
procedure WriteInferredRow(ADataSet: TDataSet; ARow: TDynamicValue); forward;

procedure WriteInferredValue(AField: TField; AValue: TDynamicValue);
var
  Nested: TDataSet;
  Rows: TDynamicValue;
  I: Integer;
  Stream: TBytesStream;
  D: Double;
begin
  if (AValue = nil) or (AValue.Kind = TDynamicKind.Null) then
  begin
    AField.Clear;
    Exit;
  end;
  if AField.DataType = ftDataSet then
  begin
    Nested := TDataSetField(AField).NestedDataSet;
    Rows := NestedRowsOf(AValue);
    try
      for I := 0 to Rows.Count - 1 do
      begin
        Nested.Append;
        WriteInferredRow(Nested, Rows[I]);
        Nested.Post;
      end;
    finally
      Rows.Free;
    end;
    Exit;
  end;
  case AField.DataType of
    ftBoolean: AField.AsBoolean := AValue.AsBool;
    ftInteger: AField.AsInteger := Integer(AValue.AsInt);
    ftLargeint: AField.AsLargeInt := AValue.AsInt;
    ftFloat:
      case AValue.Kind of
        TDynamicKind.Int: AField.AsFloat := AValue.AsInt;
        { A decimal's digits, rounded once to the nearest double - what a
          text format's number in the same column becomes. }
        TDynamicKind.Decimal:
          begin
            if not TStructuralText.TryParseFloat(AValue.AsDecimal, D) then
              raise EDataSetSerializationError.CreateFmt(
                'Column %s: the decimal %s is outside the range of a float field.',
                [AField.FieldName, AValue.AsDecimal]);
            AField.AsFloat := D;
          end;
      else
        AField.AsFloat := AValue.AsFloat;
      end;
    { All three temporal field types take the TDateTime directly. Going via
      AsString would put the conversion at the mercy of the machine's locale,
      which is exactly what the invariant text forms exist to avoid. }
    ftDate, ftTime, ftDateTime: AField.AsDateTime := AValue.AsDateTime;
    ftBlob:
      begin
        Stream := TBytesStream.Create(AValue.AsBytes);
        try
          TBlobField(AField).LoadFromStream(Stream);
        finally
          Stream.Free;
        end;
      end;
  else
    AField.AsString := DynamicText(AValue);
  end;
end;

procedure WriteInferredRow(ADataSet: TDataSet; ARow: TDynamicValue);
var
  I: Integer;
  F: TField;
begin
  if (ARow = nil) or (ARow.Kind <> TDynamicKind.Obj) then Exit;
  for I := 0 to ARow.Count - 1 do
  begin
    F := ADataSet.FindField(ARow.Names[I]);
    { A member with no column - only possible in a nested table whose schema
      came from a different row - is skipped rather than raising. }
    if F <> nil then WriteInferredValue(F, ARow[I]);
  end;
end;

class procedure TDataSetSchemaInference.Project(ARoot: TDynamicValue;
  ADataSet: TDataSet);
var
  Rows: TDynamicValue;
  I: Integer;
begin
  if ADataSet = nil then
    raise EDataSetSerializationError.Create(
      'Project needs a DataSet to project into.');
  if ADataSet.Active then
    raise EDataSetSerializationError.Create(
      'Project needs a closed DataSet: it builds the schema itself.');
  Rows := RowsOf(ARoot);
  try
    { An empty document yields an empty DataSet with no schema, which is
      reported by leaving it closed rather than by inventing a column. }
    if not InferSchemaInto(Rows, ADataSet) then Exit;
    TDataSetEngine.ActivateDataSet(ADataSet);
    for I := 0 to Rows.Count - 1 do
    begin
      ADataSet.Append;
      WriteInferredRow(ADataSet, Rows[I]);
      ADataSet.Post;
    end;
    if not ADataSet.IsEmpty then ADataSet.First;
  finally
    Rows.Free;
  end;
end;

function TCustomDataSetFieldHandler.FieldSize: Integer;
begin
  Result := 0;
end;
class function TDataSetFieldOverride.Rename(const AName: string): TDataSetFieldOverride;
begin
  Result := Default(TDataSetFieldOverride);
  Result.HasFieldName := True; Result.FieldName := AName;
end;
class function TDataSetFieldOverride.WithSize(ASize: Integer): TDataSetFieldOverride;
begin
  Result := Default(TDataSetFieldOverride);
  Result.HasFieldSize := True; Result.FieldSize := ASize;
end;
class function TDataSetFieldOverride.WithType(AType: TFieldType; ASize: Integer): TDataSetFieldOverride;
begin
  Result := Default(TDataSetFieldOverride);
  Result.HasFieldType := True; Result.FieldType := AType;
  if ASize > 0 then begin Result.HasFieldSize := True; Result.FieldSize := ASize; end;
end;
class function TDataSetFieldOverride.HandleWith(
  AHandlerClass: TDataSetFieldHandlerClass): TDataSetFieldOverride;
begin
  Result := Default(TDataSetFieldOverride);
  Result.HandlerClass := AHandlerClass;
end;
class function TDataSetFieldOverride.Create(const AName: string;
  AType: TFieldType; ASize: Integer;
  AHandlerClass: TDataSetFieldHandlerClass): TDataSetFieldOverride;
begin
  Result := Default(TDataSetFieldOverride);
  Result.HasFieldName := True; Result.FieldName := AName;
  Result.HasFieldType := True; Result.FieldType := AType;
  if ASize > 0 then begin Result.HasFieldSize := True; Result.FieldSize := ASize; end;
  Result.HandlerClass := AHandlerClass;
end;
class function TDataSetFieldOverride.Ignore: TDataSetFieldOverride;
begin
  Result := Default(TDataSetFieldOverride);
  Result.HasIgnore := True; Result.DoIgnore := True;
end;
procedure TCustomDataSetFieldHandler<T>.WriteValue(const AField: TField;
  const AValue: TValue);
var
  Typed: T;
begin
  Typed := TDataSetExtensionSupport.ValueAsTyped<T>(AValue, ClassType);
  WriteValue(Typed, AField);
end;
procedure TCustomDataSetTypeSerializer<T>.AddFields(ATypeInfo: PTypeInfo;
  AFieldDefs: TFieldDefs; const APrefix: string);
begin
  { ATypeInfo is T's, by construction: the registration bound this serializer
    to T.  The typed override therefore does not need it. }
  AddFields(AFieldDefs, APrefix);
end;
procedure TCustomDataSetTypeSerializer<T>.WriteValue(ATypeInfo: PTypeInfo;
  const AValue: TValue; ADataSet: TDataSet; const APrefix: string);
var
  Typed: T;
begin
  Typed := TDataSetExtensionSupport.ValueAsTyped<T>(AValue, ClassType);
  WriteValue(Typed, ADataSet, APrefix);
end;
constructor TDataSetDelegateHandler<T>.Create(AFieldType: TFieldType;
  AFieldSize: Integer; const AWrite: TDataSetWriteProc<T>);
begin
  inherited Create;
  FFieldType := AFieldType;
  FFieldSize := AFieldSize;
  FWrite := AWrite;
end;
function TDataSetDelegateHandler<T>.FieldType: TFieldType;
begin
  Result := FFieldType;
end;
function TDataSetDelegateHandler<T>.FieldSize: Integer;
begin
  Result := FFieldSize;
end;
procedure TDataSetDelegateHandler<T>.WriteValue(const AValue: T;
  AField: TField);
begin
  if not Assigned(FWrite) then
    raise EDataSetSerializationError.CreateFmt(
      'No write procedure was registered for %s',
      [TSerializationTypeInfo.TypeNameOf<T>]);
  FWrite(AValue, AField);
end;
class function TDataSetFieldOverride.WriteWith<T>(
  AHandlerClass: TDataSetFieldHandlerClass): TDataSetFieldOverride;
begin
  Result := Default(TDataSetFieldOverride);
  { Checked here, while the descriptor is built, so the message arrives at the
    registration that is wrong rather than at the first Fill of some unrelated
    object. }
  if (AHandlerClass <> nil) and
     not AHandlerClass.InheritsFrom(TCustomDataSetFieldHandler<T>) then
    raise EDataSetSerializationError.CreateFmt(
      '%s cannot write %s: WriteWith<%s> requires a ' +
      'TCustomDataSetFieldHandler<%s> descendant. Use HandleWith for a ' +
      'handler that covers several runtime types.',
      [AHandlerClass.ClassName, TSerializationTypeInfo.TypeNameOf<T>,
       TSerializationTypeInfo.TypeNameOf<T>, TSerializationTypeInfo.TypeNameOf<T>]);
  Result.HandlerClass := AHandlerClass;
end;
class function TDataSetFieldOverride.WriteWith<T, THandler>: TDataSetFieldOverride;
begin
  Result := Default(TDataSetFieldOverride);
  { The constraint did the checking; there is nothing left to validate. }
  Result.HandlerClass := TDataSetFieldHandlerClass(THandler);
end;
class function TDataSetFieldOverride.WriteWith<T>(AFieldType: TFieldType;
  const AWrite: TDataSetWriteProc<T>): TDataSetFieldOverride;
begin
  Result := WriteWith<T>(AFieldType, 0, AWrite);
end;
class function TDataSetFieldOverride.WriteWith<T>(AFieldType: TFieldType;
  AFieldSize: Integer; const AWrite: TDataSetWriteProc<T>): TDataSetFieldOverride;
begin
  Result := Default(TDataSetFieldOverride);
  { Built once, owned by the framework, and reused by the plan for every row -
    never constructed per value. }
  Result.HandlerInstance := TDataSetExtensionSupport.AdoptHandler(
    TDataSetDelegateHandler<T>.Create(AFieldType, AFieldSize, AWrite));
end;
{ ---------------------------------------------------- extension support --- }

class function TDataSetExtensionSupport.ValueAsTyped<T>(const AValue: TValue;
  AHandlerClass: TClass): T;
var
  HandlerName: string;
begin
  try
    Result := AValue.AsType<T>;
  except
    on E: Exception do
    begin
      if AHandlerClass <> nil then
        HandlerName := AHandlerClass.ClassName
      else
        HandlerName := '<handler>';
      { Deliberately NOT phrased as a data problem: no field was written. A
        handler was registered against a member whose type it does not
        handle. }
      raise EDataSetSerializationError.CreateFmt(
        '%s expects %s but the member holds %s. The handler is registered ' +
        'against a member of the wrong type. (%s)',
        [HandlerName, TSerializationTypeInfo.TypeNameOf<T>,
         TSerializationTypeInfo.ActualNameOf(AValue), E.Message]);
    end;
  end;
end;

class function TDataSetExtensionSupport.AdoptHandler(
  AInstance: TCustomDataSetFieldHandler): TCustomDataSetFieldHandler;
begin
  Result := TDataSetEngine.AdoptHandler(AInstance);
end;

{ ------------------------------------------------------------ attributes --- }

constructor DataSetNameAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

constructor DataSetFieldAttribute.Create(AFieldType: TFieldType; ASize: Integer);
begin
  inherited Create;
  FFieldType := AFieldType;
  FSize := ASize;
end;

constructor DataSetHandlerAttribute.Create(
  AHandlerClass: TDataSetFieldHandlerClass);
begin
  inherited Create;
  FHandlerClass := AHandlerClass;
end;

{ ------------------------------------------------- facade engine bridges --- }

class procedure TDataSetSerializer.DoCreateStructure(ATypeInfo: PTypeInfo;
  ADataSet: TDataSet);
begin
  TDataSetEngine.CreateStructure(ATypeInfo, ADataSet);
end;

class procedure TDataSetSerializer.DoFill(ATypeInfo: PTypeInfo;
  AInstance: Pointer; ADataSet: TDataSet);
begin
  TDataSetEngine.FillRaw(ATypeInfo, AInstance, ADataSet);
end;

class procedure TDataSetSerializer.DoCheckNotFrozen;
begin
  TDataSetEngine.CheckConfigurationNotFrozen;
end;

class procedure TDataSetSerializer.DoRegisterTypeHandler(ATypeInfo: PTypeInfo;
  AHandlerClass: TDataSetFieldHandlerClass);
begin
  TDataSetEngine.RegisterTypeHandler(ATypeInfo, AHandlerClass);
end;

class procedure TDataSetSerializer.DoPublishHandler(
  AHandlerClass: TDataSetFieldHandlerClass;
  AInstance: TCustomDataSetFieldHandler);
begin
  TDataSetEngine.PublishHandler(AHandlerClass, AInstance);
end;

{ ------------------------------------------------------ typed operations --- }

class procedure TDataSetSerializer.CreateStructure<T>(ADataSet: TDataSet);
begin
  DoCreateStructure(System.TypeInfo(T), ADataSet);
end;

class procedure TDataSetSerializer.Fill<T>(const AInstance: T;
  ADataSet: TDataSet);
var
  Ti: PTypeInfo;
begin
  Ti := System.TypeInfo(T);
  if Ti.Kind = tkClass then
    DoFill(Ti, PPointer(@AInstance)^, ADataSet)
  else
    DoFill(Ti, @AInstance, ADataSet);
end;

class procedure TDataSetSerializer.Fill<T>(const AItems: array of T;
  ADataSet: TDataSet);
var
  I: NativeInt;
begin
  for I := Low(AItems) to High(AItems) do
    Fill<T>(AItems[I], ADataSet);
end;

class procedure TDataSetSerializer.CreateAndFill<T>(const AValue: T;
  ADataSet: TDataSet);
begin
  { Deliberately the two existing operations, in order - not a second
    projection path that could drift from them. }
  CreateStructure<T>(ADataSet);
  Fill<T>(AValue, ADataSet);
end;

class procedure TDataSetSerializer.CreateAndFill<T>(const AValues: array of T;
  ADataSet: TDataSet);
begin
  { An empty array still recreates the schema, so the dataset is left open and
    empty rather than holding whatever it had before. }
  CreateStructure<T>(ADataSet);
  Fill<T>(AValues, ADataSet);
end;

class function TDataSetSerializer.CreateFDMemTable<T>(const AValue: T;
  AOwner: TComponent): TFDMemTable;
begin
  Result := TFDMemTable.Create(AOwner);
  try
    CreateAndFill<T>(AValue, Result);
  except
    Result.Free;
    raise;
  end;
end;

class function TDataSetSerializer.CreateFDMemTable<T>(const AValues: array of T;
  AOwner: TComponent): TFDMemTable;
begin
  Result := TFDMemTable.Create(AOwner);
  try
    CreateAndFill<T>(AValues, Result);
  except
    Result.Free;
    raise;
  end;
end;

class function TDataSetSerializer.CreateClientDataSet<T>(const AValue: T;
  AOwner: TComponent): TClientDataSet;
begin
  Result := TClientDataSet.Create(AOwner);
  try
    CreateAndFill<T>(AValue, Result);
  except
    Result.Free;
    raise;
  end;
end;

class function TDataSetSerializer.CreateClientDataSet<T>(const AValues: array of T;
  AOwner: TComponent): TClientDataSet;
begin
  Result := TClientDataSet.Create(AOwner);
  try
    CreateAndFill<T>(AValues, Result);
  except
    Result.Free;
    raise;
  end;
end;

{ --------------------------------------------------- typed registrations --- }

class procedure TDataSetSerializer.RegisterTypeHandler<T>(
  AHandlerClass: TDataSetFieldHandlerClass);
begin
  if (AHandlerClass <> nil) and
     not AHandlerClass.InheritsFrom(TCustomDataSetFieldHandler<T>) then
    raise EDataSetSerializationError.CreateFmt(
      '%s cannot write %s: RegisterTypeHandler<%s> requires a ' +
      'TCustomDataSetFieldHandler<%s> descendant. Use the PTypeInfo form for ' +
      'a handler that covers several runtime types.',
      [AHandlerClass.ClassName, TSerializationTypeInfo.TypeNameOf<T>,
       TSerializationTypeInfo.TypeNameOf<T>, TSerializationTypeInfo.TypeNameOf<T>]);
  DoRegisterTypeHandler(System.TypeInfo(T), AHandlerClass);
end;

class procedure TDataSetSerializer.RegisterTypeHandler<T, THandler>;
begin
  { The constraint already proved THandler handles T. }
  DoRegisterTypeHandler(System.TypeInfo(T), TDataSetFieldHandlerClass(THandler));
end;

class procedure TDataSetSerializer.RegisterTypeHandler<T>(AFieldType: TFieldType;
  const AWrite: TDataSetWriteProc<T>);
begin
  RegisterTypeHandler<T>(AFieldType, 0, AWrite);
end;

class procedure TDataSetSerializer.RegisterTypeHandler<T>(AFieldType: TFieldType;
  AFieldSize: Integer; const AWrite: TDataSetWriteProc<T>);
begin
  { Checked before anything is built, so a registration attempted after the
    configuration is frozen changes nothing at all - delegates are not a way
    around the freeze. }
  DoCheckNotFrozen;
  { Every instantiation of TDataSetDelegateHandler<T> is a distinct class, so
    T's closure can be published as that class's singleton.  The engine then
    resolves it through the ordinary class-keyed path - no second registry, no
    per-value lookup, no per-value allocation. }
  DoPublishHandler(TDataSetDelegateHandler<T>,
    TDataSetDelegateHandler<T>.Create(AFieldType, AFieldSize, AWrite));
  DoRegisterTypeHandler(System.TypeInfo(T), TDataSetDelegateHandler<T>);
end;

class procedure TDataSetSerializer.RegisterFieldOverride<T>(
  const AFieldName: string; const AOverride: TDataSetFieldOverride);
begin
  RegisterFieldOverride(System.TypeInfo(T), AFieldName, AOverride);
end;

class procedure TDataSetSerializer.RegisterTypeSerializer<T>(
  ASerializerClass: TDataSetTypeSerializerClass);
begin
  if (ASerializerClass <> nil) and
     not ASerializerClass.InheritsFrom(TCustomDataSetTypeSerializer<T>) then
    raise EDataSetSerializationError.CreateFmt(
      '%s cannot project %s: RegisterTypeSerializer<%s> requires a ' +
      'TCustomDataSetTypeSerializer<%s> descendant. Use the PTypeInfo form ' +
      'for a serializer that covers several runtime types.',
      [ASerializerClass.ClassName, TSerializationTypeInfo.TypeNameOf<T>,
       TSerializationTypeInfo.TypeNameOf<T>, TSerializationTypeInfo.TypeNameOf<T>]);
  RegisterTypeSerializer(System.TypeInfo(T), ASerializerClass);
end;

class procedure TDataSetSerializer.RegisterTypeSerializer<T, TSer>;
begin
  RegisterTypeSerializer(System.TypeInfo(T), TDataSetTypeSerializerClass(TSer));
end;

{ ------------------------------------------------------- plain forwards --- }
class procedure TDataSetSerializer.CreateStructure(ATypeInfo: PTypeInfo; ADataSet: TDataSet);
begin
  TDataSetEngine.CreateStructure(ATypeInfo, ADataSet);
end;

class procedure TDataSetSerializer.Fill(ATypeInfo: PTypeInfo; const AInstance: TObject; ADataSet: TDataSet);
begin
  TDataSetEngine.Fill(ATypeInfo, AInstance, ADataSet);
end;

class procedure TDataSetSerializer.RegisterFieldOverride(AClass: TClass; const AFieldName: string; const AOverride: TDataSetFieldOverride);
begin
  TDataSetEngine.RegisterFieldOverride(AClass, AFieldName, AOverride);
end;

class procedure TDataSetSerializer.RegisterFieldOverride(AOwnerTypeInfo: PTypeInfo; const AFieldName: string; const AOverride: TDataSetFieldOverride);
begin
  TDataSetEngine.RegisterFieldOverride(AOwnerTypeInfo, AFieldName, AOverride);
end;

class procedure TDataSetSerializer.RegisterFieldOverride(const AQualifiedOwnerTypeName,
      AFieldName: string; const AOverride: TDataSetFieldOverride);
begin
  TDataSetEngine.RegisterFieldOverride(AQualifiedOwnerTypeName, AFieldName, AOverride);
end;

class procedure TDataSetSerializer.RegisterChildFieldOverride(AClass: TClass;
      const AFieldName, AChildName: string;
      const AOverride: TDataSetFieldOverride);
begin
  TDataSetEngine.RegisterChildFieldOverride(AClass, AFieldName, AChildName, AOverride);
end;

class procedure TDataSetSerializer.RegisterChildFieldOverride(AOwnerTypeInfo: PTypeInfo;
      const AFieldName, AChildName: string;
      const AOverride: TDataSetFieldOverride);
begin
  TDataSetEngine.RegisterChildFieldOverride(AOwnerTypeInfo, AFieldName, AChildName, AOverride);
end;

class procedure TDataSetSerializer.RegisterChildFieldOverride(const AQualifiedOwnerTypeName,
      AFieldName, AChildName: string;
      const AOverride: TDataSetFieldOverride);
begin
  TDataSetEngine.RegisterChildFieldOverride(AQualifiedOwnerTypeName, AFieldName, AChildName, AOverride);
end;

class procedure TDataSetSerializer.RegisterClassFieldOverride(AClass: TClass; const AFieldPattern: string; const AOverride: TDataSetFieldOverride; AIncludeDescendants: Boolean = False);
begin
  TDataSetEngine.RegisterClassFieldOverride(AClass, AFieldPattern, AOverride, AIncludeDescendants);
end;

class procedure TDataSetSerializer.RegisterUnitFieldOverride(const AUnitPattern, AFieldPattern: string; const AOverride: TDataSetFieldOverride);
begin
  TDataSetEngine.RegisterUnitFieldOverride(AUnitPattern, AFieldPattern, AOverride);
end;

class procedure TDataSetSerializer.RegisterTypeHandler(ATypeInfo: PTypeInfo;
      AHandlerClass: TDataSetFieldHandlerClass);
begin
  TDataSetEngine.RegisterTypeHandler(ATypeInfo, AHandlerClass);
end;

class procedure TDataSetSerializer.RegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TDataSetTypeSerializerClass);
begin
  TDataSetEngine.RegisterTypeSerializer(ATypeInfo, ASerializerClass);
end;

class procedure TDataSetSerializer.RegisterGenericTypeSerializer(ARepresentativeTypeInfo: PTypeInfo;
      ASerializerClass: TDataSetTypeSerializerClass);
begin
  TDataSetEngine.RegisterGenericTypeSerializer(ARepresentativeTypeInfo, ASerializerClass);
end;

class procedure TDataSetSerializer.FreezeConfiguration;
begin
  TDataSetEngine.FreezeConfiguration;
end;

class function TDataSetSerializer.IsFrozen: Boolean;
begin
  Result := TDataSetEngine.IsFrozen;
end;

class function TDataSetSerializer.GetDefaultStringSize: Integer;
begin
  Result := TDataSetEngine.DefaultStringSize;
end;

class procedure TDataSetSerializer.SetDefaultStringSize(AValue: Integer);
begin
  TDataSetEngine.DefaultStringSize := AValue;
end;

{ ------------------------------------------------- from an encoded source --- }

class procedure TDataSetSerializer.DoFillFromPayload(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  ADataSet: TDataSet);
var
  V: TValue;
begin
  { The source format is reached through the registry; nothing here names
    JSON, XML or BSON. What comes back is a Delphi value of ATypeInfo, and
    from that point this is the ordinary DTO projection - there is no second
    mapping implementation. }
  V := TSerializationFormats.Require(AFormat,
    TSerializationFormatCapability.ContractDeserialize).DeserializeTyped(
    ATypeInfo, ASource);
  try
    TDataSetEngine.CreateStructure(ATypeInfo, ADataSet);
    { The same raw-pointer entry point Fill<T> uses, so a class root and a
      record root behave here exactly as they do there. }
    if ATypeInfo.Kind = tkClass then
      TDataSetEngine.FillRaw(ATypeInfo, PPointer(V.GetReferenceToRawData)^, ADataSet)
    else
      TDataSetEngine.FillRaw(ATypeInfo, V.GetReferenceToRawData, ADataSet);
  finally
    { The intermediate belongs to this call: it was built here, projected
      here, and nothing outside will ever see it. }
    TSerializationOwnership.Release(ATypeInfo, V);
  end;
end;

class procedure TDataSetSerializer.ProjectPayload(
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  ADataSet: TDataSet);
var
  Tree: TDynamicValue;
begin
  { ToDynamic IS the structural parse: a format turns its own bytes into the
    dynamic tree, and no format's DOM - TJSONValue, TXmlElement, TBsonValue -
    ever reaches the DataSet subsystem.

    Require rather than Get, so the two different failures stay apart. A
    format nobody registered raises ESerializationFormatNotRegistered and
    names the registration call to make; a format that IS registered but has
    no structural parser raises ESerializationFormatCapability, because
    telling that caller to register a format they already registered would
    waste their afternoon. }
  Tree := TSerializationFormats.Require(AFormat,
    TSerializationFormatCapability.StructuralParse).ToDynamic(ASource,
      TStructuralConversionOptions.Default.WithSource(AFormat));
  try
    TDataSetSchemaInference.Project(Tree, ADataSet);
  finally
    Tree.Free;
  end;
end;

class function TDataSetSerializer.CreateFDMemTable<T>(const ASource: string;
  AFormat: TSerializationFormat; AOwner: TComponent): TFDMemTable;
begin
  Result := CreateFDMemTable<T>(TSerializationPayload.FromText(ASource),
    AFormat, AOwner);
end;

class function TDataSetSerializer.CreateFDMemTable<T>(const ASource: TBytes;
  AFormat: TSerializationFormat; AOwner: TComponent): TFDMemTable;
begin
  Result := CreateFDMemTable<T>(TSerializationPayload.FromBytes(ASource),
    AFormat, AOwner);
end;

class function TDataSetSerializer.CreateFDMemTable<T>(
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  AOwner: TComponent): TFDMemTable;
begin
  Result := TFDMemTable.Create(AOwner);
  try
    DoFillFromPayload(System.TypeInfo(T), ASource, AFormat, Result);
  except
    Result.Free;
    raise;
  end;
end;

class function TDataSetSerializer.CreateFDMemTable(const ASource: string;
  AFormat: TSerializationFormat; AOwner: TComponent): TFDMemTable;
begin
  Result := CreateFDMemTable(TSerializationPayload.FromText(ASource), AFormat,
    AOwner);
end;

class function TDataSetSerializer.CreateFDMemTable(const ASource: TBytes;
  AFormat: TSerializationFormat; AOwner: TComponent): TFDMemTable;
begin
  Result := CreateFDMemTable(TSerializationPayload.FromBytes(ASource), AFormat,
    AOwner);
end;

class function TDataSetSerializer.CreateFDMemTable(
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  AOwner: TComponent): TFDMemTable;
begin
  Result := TFDMemTable.Create(AOwner);
  try
    ProjectPayload(ASource, AFormat, Result);
  except
    Result.Free;
    raise;
  end;
end;

class function TDataSetSerializer.CreateClientDataSet<T>(const ASource: string;
  AFormat: TSerializationFormat; AOwner: TComponent): TClientDataSet;
begin
  Result := CreateClientDataSet<T>(TSerializationPayload.FromText(ASource),
    AFormat, AOwner);
end;

class function TDataSetSerializer.CreateClientDataSet<T>(const ASource: TBytes;
  AFormat: TSerializationFormat; AOwner: TComponent): TClientDataSet;
begin
  Result := CreateClientDataSet<T>(TSerializationPayload.FromBytes(ASource),
    AFormat, AOwner);
end;

class function TDataSetSerializer.CreateClientDataSet<T>(
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  AOwner: TComponent): TClientDataSet;
begin
  Result := TClientDataSet.Create(AOwner);
  try
    DoFillFromPayload(System.TypeInfo(T), ASource, AFormat, Result);
  except
    Result.Free;
    raise;
  end;
end;

class function TDataSetSerializer.CreateClientDataSet(const ASource: string;
  AFormat: TSerializationFormat; AOwner: TComponent): TClientDataSet;
begin
  Result := CreateClientDataSet(TSerializationPayload.FromText(ASource),
    AFormat, AOwner);
end;

class function TDataSetSerializer.CreateClientDataSet(const ASource: TBytes;
  AFormat: TSerializationFormat; AOwner: TComponent): TClientDataSet;
begin
  Result := CreateClientDataSet(TSerializationPayload.FromBytes(ASource),
    AFormat, AOwner);
end;

{ ---------------------------------------------------------------------------
  THE DESTINATION CONTRACT

  Reading a document into an existing DataSet REBUILDS it: the document
  decides the schema, so the DataSet is closed, its field definitions and
  fields are cleared, and it is rebuilt and filled. Every Deserialize
  overload does exactly this - with a context or without, open or closed.

  And it PRE-VALIDATES. A document can be parsed and still fail half way
  through being written - a value its column cannot hold, a change that
  refers to a row that is not there - and by then the DataSet has been
  closed and cleared. So when the destination holds anything worth keeping,
  the complete projection is first rehearsed on a temporary DataSet of the
  destination's own class, and the destination is rebuilt only if that
  succeeds. A schema, value or projection failure the library can detect
  therefore does not destroy the existing DataSet.

  What the rehearsal cannot cover is the destination itself: an
  application's event handler on the real DataSet (BeforePost,
  OnNewRecord, a field's OnValidate...) or behaviour specific to that
  instance may still raise during the final application, after rebuilding
  has begun. That is a limit of rehearsing on another instance, not a
  promise of a transaction.

  Where practical: the rehearsal needs a class that stands alone -
  TFDMemTable, TClientDataSet and their descendants. Any other TDataSet (a
  live query result, which keeps the schema it was opened with) is projected
  directly, as before. An empty, closed destination has nothing to keep and
  is not rehearsed, so building a new DataSet costs one projection.
  --------------------------------------------------------------------------- }

{ Inference builds the schema from the data, which means the DataSet has to
  arrive without one. Clearing is part of reading, not something the caller
  should have to remember. }
procedure InferInto(ATree: TDynamicValue; ADataSet: TDataSet);
begin
  ADataSet.Close;
  ADataSet.FieldDefs.Clear;
  ADataSet.Fields.Clear;
  TDataSetSchemaInference.Project(ATree, ADataSet);
end;

{ Runs AWork on a scratch DataSet of ADataSet's own class first, when
  ADataSet holds something to keep and its class can stand alone. Raises
  what AWork raises, before ADataSet has been touched. }
procedure Rehearse(ADataSet: TDataSet; const AWork: TProc<TDataSet>);
var
  Scratch: TDataSet;
begin
  if not ADataSet.Active and (ADataSet.FieldDefs.Count = 0) then Exit;
  if not ((ADataSet is TFDMemTable) or (ADataSet is TClientDataSet)) then Exit;
  Scratch := TDataSetClass(ADataSet.ClassType).Create(nil);
  try
    { A change list with no schema of its own is replayed onto the schema
      the destination already has; every other path clears this. }
    Scratch.FieldDefs.Assign(ADataSet.FieldDefs);
    AWork(Scratch);
  finally
    Scratch.Free;
  end;
end;

{ The projection, given a schema the format may need. The schema travels in
  the conversion options, which is the one place this library puts one, and
  it stays borrowed the whole way down. }
class procedure TDataSetSerializer.ProjectPayloadWith(
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  ASchema: TSerializationContext; ADataSet: TDataSet);
var
  Tree: TDynamicValue;
  Options: TStructuralConversionOptions;
begin
  Options := TStructuralConversionOptions.Default.WithSource(AFormat);
  if ASchema <> nil then Options := Options.WithContext(ASchema);
  Tree := TSerializationFormats.Require(AFormat,
    TSerializationFormatCapability.StructuralParse, Options).ToDynamic(
      ASource, Options);
  try
    Rehearse(ADataSet,
      procedure(ATarget: TDataSet)
      begin
        InferInto(Tree, ATarget);
      end);
    InferInto(Tree, ADataSet);
  finally
    Tree.Free;
  end;
end;

class procedure TDataSetSerializer.Deserialize(
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  AContext: TSerializationContext; ADataSet: TDataSet);
begin
  if ADataSet = nil then
    raise EDataSetSerializationError.Create(
      'There is no DataSet to read into.');
  ProjectPayloadWith(ASource, AFormat, AContext, ADataSet);
end;

class function TDataSetSerializer.CreateClientDataSet(
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  ASchema: TSerializationContext; AOwner: TComponent): TClientDataSet;
begin
  Result := TClientDataSet.Create(AOwner);
  try
    ProjectPayloadWith(ASource, AFormat, ASchema, Result);
  except
    Result.Free;
    raise;
  end;
end;

class function TDataSetSerializer.CreateFDMemTable(
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  ASchema: TSerializationContext; AOwner: TComponent): TFDMemTable;
begin
  Result := TFDMemTable.Create(AOwner);
  try
    ProjectPayloadWith(ASource, AFormat, ASchema, Result);
  except
    Result.Free;
    raise;
  end;
end;

class function TDataSetSerializer.CreateClientDataSet(
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  AOwner: TComponent): TClientDataSet;
begin
  Result := TClientDataSet.Create(AOwner);
  try
    ProjectPayload(ASource, AFormat, Result);
  except
    Result.Free;
    raise;
  end;
end;


{ ---------------------------------------- the embedded-structure detector --- }

class function TDataSetEmbeddedStructureDetector.Classify(
  ARoot: TDynamicValue): TDataSetMetadataMatch;
begin
  Result := ClassifyPacket(ARoot);
end;

class function TDataSetEmbeddedStructureDetector.Explain(
  ARoot: TDynamicValue): string;
begin
  Result := ExplainPacket(ARoot);
end;

class function TDataSetEmbeddedStructureDetector.IsDelta(
  ARoot: TDynamicValue): Boolean;
begin
  Result := PacketIsDelta(ARoot);
end;

{ ------------------------------------------------ a DataSet as a document --- }

class function TDataSetSerializer.ToDynamic(ADataSet: TDataSet;
  APolicy: TDataSetSerializationPolicy;
  AIncludeDataSetName: Boolean): TDynamicValue;
begin
  if ADataSet = nil then
    raise EDataSetSerializationError.Create(
      'There is no DataSet to serialize.');
  Result := DataSetToPacket(ADataSet, APolicy, AIncludeDataSetName);
end;

class function TDataSetSerializer.Serialize(ADataSet: TDataSet;
  AFormat: TSerializationFormat; APolicy: TDataSetSerializationPolicy;
  AIncludeDataSetName: Boolean): TSerializationPayload;
var
  Tree: TDynamicValue;
  Options: TStructuralConversionOptions;
  Handler: TSerializationFormatHandler;
begin
  { The capability is checked BEFORE the packet is built, so a format that
    cannot write one fails without walking every row first. }
  Handler := TSerializationFormats.Require(AFormat,
    TSerializationFormatCapability.StructuralWrite);
  Tree := ToDynamic(ADataSet, APolicy, AIncludeDataSetName);
  try
    { A DataSet packet holds nothing a format has to adapt: its values are
      nulls, booleans, numbers and strings, and its member names are column
      names. Natural is therefore not a compromise here - it is exact. }
    Options := TStructuralConversionOptions.Default;
    Result := Handler.FromDynamic(Tree, Options);
  finally
    Tree.Free;
  end;
end;

{ Reads the source into the tree, once, for everything below. }
class function TDataSetSerializer.ParseSource(
  const ASource: TSerializationPayload;
  AFormat: TSerializationFormat): TDynamicValue;
var
  Options: TStructuralConversionOptions;
begin
  { Natural, deliberately. A DataSet packet is plain data, and reading it
    under Lossless would additionally reinterpret an object whose only
    member is "$oid" as an ObjectId - which is right for a BSON round trip
    and wrong for a column value. }
  Options := TStructuralConversionOptions.Default.WithSource(AFormat);
  Result := TSerializationFormats.Require(AFormat,
    TSerializationFormatCapability.StructuralParse).ToDynamic(ASource, Options);
end;

class function TDataSetSerializer.ClassifySource(
  const ASource: TSerializationPayload;
  AFormat: TSerializationFormat): TDataSetMetadataMatch;
var
  Tree: TDynamicValue;
begin
  Tree := ParseSource(ASource, AFormat);
  try
    Result := TDataSetEmbeddedStructureDetector.Classify(Tree);
  finally
    Tree.Free;
  end;
end;

class function TDataSetSerializer.ExplainSource(
  const ASource: TSerializationPayload;
  AFormat: TSerializationFormat): string;
var
  Tree: TDynamicValue;
begin
  Tree := ParseSource(ASource, AFormat);
  try
    Result := TDataSetEmbeddedStructureDetector.Explain(Tree);
  finally
    Tree.Free;
  end;
end;

class procedure TDataSetSerializer.ReadFieldDefs(
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  ADefs: TFieldDefs);
var
  Tree: TDynamicValue;
begin
  Tree := ParseSource(ASource, AFormat);
  try
    PacketFieldDefs(Tree, ADefs);
  finally
    Tree.Free;
  end;
end;

class procedure TDataSetSerializer.ApplyTree(ATree: TDynamicValue;
  ADataSet: TDataSet; AMode: TDataSetSourceMode);
var
  Match: TDataSetMetadataMatch;
begin
  case AMode of
    TDataSetSourceMode.InferStructure:
      begin
        { No question is asked of the document at all: the caller has said
          that whatever it contains is data. }
        InferInto(ATree, ADataSet);
        Exit;
      end;
    TDataSetSourceMode.EmbeddedStructure:
      begin
        Match := TDataSetEmbeddedStructureDetector.Classify(ATree);
        if Match <> TDataSetMetadataMatch.ValidMetadata then
          raise EDataSetSerializationError.CreateFmt(
            'This document was read with EmbeddedStructure, which requires ' +
            'it to describe its own columns, and %s. Use Auto to infer the ' +
            'schema from the data instead.',
            [TDataSetEmbeddedStructureDetector.Explain(ATree)]);
        if TDataSetEmbeddedStructureDetector.IsDelta(ATree) then
          PacketDeltaToDataSet(ATree, ADataSet)
        else
          PacketToDataSet(ATree, ADataSet);
        Exit;
      end;
  end;

  Match := TDataSetEmbeddedStructureDetector.Classify(ATree);
  case Match of
    TDataSetMetadataMatch.ValidMetadata:
      if TDataSetEmbeddedStructureDetector.IsDelta(ATree) then
        PacketDeltaToDataSet(ATree, ADataSet)
      else
        PacketToDataSet(ATree, ADataSet);
    TDataSetMetadataMatch.NotMetadata: InferInto(ATree, ADataSet);
  else
    { Something in this document claims to describe a table and does not do
      it correctly. Inferring from it would build a table with two columns
      called "fields" and "rows", and that would be a worse answer than
      saying what is wrong. }
    raise EDataSetSerializationError.CreateFmt(
      'This document describes its own columns but the description is not ' +
      'usable: %s. Read it with InferStructure to treat it as ordinary ' +
      'data instead.',
      [TDataSetEmbeddedStructureDetector.Explain(ATree)]);
  end;
end;

class procedure TDataSetSerializer.Deserialize(
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  ADataSet: TDataSet; AMode: TDataSetSourceMode);
var
  Tree: TDynamicValue;
begin
  if ADataSet = nil then
    raise EDataSetSerializationError.Create(
      'There is no DataSet to read into.');
  Tree := ParseSource(ASource, AFormat);
  try
    Rehearse(ADataSet,
      procedure(ATarget: TDataSet)
      begin
        ApplyTree(Tree, ATarget, AMode);
      end);
    ApplyTree(Tree, ADataSet, AMode);
  finally
    Tree.Free;
  end;
end;

class procedure TDataSetSerializer.Deserialize(const ASource: string;
  AFormat: TSerializationFormat; ADataSet: TDataSet;
  AMode: TDataSetSourceMode);
begin
  Deserialize(TSerializationPayload.FromText(ASource), AFormat, ADataSet, AMode);
end;

class procedure TDataSetSerializer.Deserialize(const ASource: TBytes;
  AFormat: TSerializationFormat; ADataSet: TDataSet;
  AMode: TDataSetSourceMode);
begin
  Deserialize(TSerializationPayload.FromBytes(ASource), AFormat, ADataSet, AMode);
end;

class procedure TDataSetSerializer.FromDynamic(AValue: TDynamicValue;
  ADataSet: TDataSet; AMode: TDataSetSourceMode);
begin
  if ADataSet = nil then
    raise EDataSetSerializationError.Create(
      'There is no DataSet to read into.');
  if AValue = nil then
    raise EDataSetSerializationError.Create(
      'There is no dynamic value to read.');
  { Exactly Deserialize, from the tree on: the same pre-validation, the same
    mode decision. }
  Rehearse(ADataSet,
    procedure(ATarget: TDataSet)
    begin
      ApplyTree(AValue, ATarget, AMode);
    end);
  ApplyTree(AValue, ADataSet, AMode);
end;

class procedure TDataSetSerializer.FromDynamic(AValue: TDynamicValue;
  ADataSet: TDataSet; APolicy: TDataSetSerializationPolicy);
begin
  if ADataSet = nil then
    raise EDataSetSerializationError.Create(
      'There is no DataSet to read into.');
  if AValue = nil then
    raise EDataSetSerializationError.Create(
      'There is no dynamic value to read.');
  ApplyPacket(AValue, ADataSet, APolicy);
end;

class procedure TDataSetSerializer.FromDynamic<T>(AValue: TDynamicValue;
  ADataSet: TDataSet);
begin
  DoFillFromDynamic(System.TypeInfo(T), AValue, ADataSet);
end;

class procedure TDataSetSerializer.DoFillFromDynamic(ATypeInfo: PTypeInfo;
  AValue: TDynamicValue; ADataSet: TDataSet);

  { One item, read as T through the shared projection and projected as a
    row - the same two steps the payload path takes, with Dynamic in place
    of the source format. }
  procedure FillOne(AItem: TDynamicValue);
  var
    V: TValue;
  begin
    V := TDynamicSerializer.Deserialize(AItem, ATypeInfo);
    try
      if ATypeInfo.Kind = tkClass then
        TDataSetEngine.FillRaw(ATypeInfo, PPointer(V.GetReferenceToRawData)^,
          ADataSet)
      else
        TDataSetEngine.FillRaw(ATypeInfo, V.GetReferenceToRawData, ADataSet);
    finally
      TSerializationOwnership.Release(ATypeInfo, V);
    end;
  end;

var
  I: Integer;
begin
  if ADataSet = nil then
    raise EDataSetSerializationError.Create(
      'There is no DataSet to read into.');
  if AValue = nil then
    raise EDataSetSerializationError.Create(
      'There is no dynamic value to read.');
  TDataSetEngine.CreateStructure(ATypeInfo, ADataSet);
  { An array of objects is a table: one row per item, when T is the row
    type. T that is itself a collection takes the array whole. }
  if (AValue.Kind = TDynamicKind.Arr) and
     (ATypeInfo.Kind in [tkClass, tkRecord, tkMRecord]) and
     (TSerializationTypes.ContainerKindOf(ATypeInfo) = TContainerKind.None) then
  begin
    for I := 0 to AValue.Count - 1 do FillOne(AValue.Items[I]);
    Exit;
  end;
  FillOne(AValue);
end;

class procedure TDataSetSerializer.DeserializeAs(
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  ADataSet: TDataSet; APolicy: TDataSetSerializationPolicy);
var
  Tree: TDynamicValue;
begin
  if ADataSet = nil then
    raise EDataSetSerializationError.Create(
      'There is no DataSet to read into.');
  Tree := ParseSource(ASource, AFormat);
  try
    ApplyPacket(Tree, ADataSet, APolicy);
  finally
    Tree.Free;
  end;
end;

class procedure TDataSetSerializer.DeserializeAs(const ASource: string;
  AFormat: TSerializationFormat; ADataSet: TDataSet;
  APolicy: TDataSetSerializationPolicy);
begin
  DeserializeAs(TSerializationPayload.FromText(ASource), AFormat, ADataSet,
    APolicy);
end;

class procedure TDataSetSerializer.DeserializeAs(const ASource: TBytes;
  AFormat: TSerializationFormat; ADataSet: TDataSet;
  APolicy: TDataSetSerializationPolicy);
begin
  DeserializeAs(TSerializationPayload.FromBytes(ASource), AFormat, ADataSet,
    APolicy);
end;

class function TDataSetSerializer.CreateFDMemTable(
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  AMode: TDataSetSourceMode; AOwner: TComponent): TFDMemTable;
begin
  Result := TFDMemTable.Create(AOwner);
  try
    Deserialize(ASource, AFormat, Result, AMode);
  except
    Result.Free;
    raise;
  end;
end;

class function TDataSetSerializer.CreateFDMemTable(const ASource: string;
  AFormat: TSerializationFormat; AMode: TDataSetSourceMode;
  AOwner: TComponent): TFDMemTable;
begin
  Result := CreateFDMemTable(TSerializationPayload.FromText(ASource), AFormat,
    AMode, AOwner);
end;

class function TDataSetSerializer.CreateFDMemTable(const ASource: TBytes;
  AFormat: TSerializationFormat; AMode: TDataSetSourceMode;
  AOwner: TComponent): TFDMemTable;
begin
  Result := CreateFDMemTable(TSerializationPayload.FromBytes(ASource), AFormat,
    AMode, AOwner);
end;

class function TDataSetSerializer.CreateClientDataSet(
  const ASource: TSerializationPayload; AFormat: TSerializationFormat;
  AMode: TDataSetSourceMode; AOwner: TComponent): TClientDataSet;
begin
  Result := TClientDataSet.Create(AOwner);
  try
    Deserialize(ASource, AFormat, Result, AMode);
  except
    Result.Free;
    raise;
  end;
end;

class function TDataSetSerializer.CreateClientDataSet(const ASource: string;
  AFormat: TSerializationFormat; AMode: TDataSetSourceMode;
  AOwner: TComponent): TClientDataSet;
begin
  Result := CreateClientDataSet(TSerializationPayload.FromText(ASource),
    AFormat, AMode, AOwner);
end;

class function TDataSetSerializer.CreateClientDataSet(const ASource: TBytes;
  AFormat: TSerializationFormat; AMode: TDataSetSourceMode;
  AOwner: TComponent): TClientDataSet;
begin
  Result := CreateClientDataSet(TSerializationPayload.FromBytes(ASource),
    AFormat, AMode, AOwner);
end;

end.
