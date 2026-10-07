{*******************************************************************************
  PascalForge.Json

  Public JSON serialization facade for PascalForge.Serialization.

  Responsibilities
    - Typed JSON serialization/deserialization.
    - Population of existing values.
    - JSON-specific options and customization API.

  Registration
    Direct TJsonSerializer use does not require format registration.
    Generic TSerialization operations require explicit registration:
    TJsonSerializationRegistration.RegisterFormat (PascalForge.Json.Registration).

  Configuration
    Global serializer configuration becomes immutable after first use.

  Threading
    Serialization is safe for concurrent use after configuration is frozen.

  Documentation
    docs/formats/json.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Json;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  The JSON serializer's public API.

  Using this one unit is enough for everything an application normally does:
  serialize, deserialize, populate, the [JsonName]/[JsonIgnore]/[JsonSerializer]
  attributes, and every registration that customises how a type is written.

      uses
        PascalForge.Json;

  The engine itself - cached execution plans, RTTI traversal, member
  conversion - lives in PascalForge.Json.Internal and is not part of this
  contract.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo, System.JSON,
  System.Generics.Collections,
  PascalForge.Serialization.Core, PascalForge.Dynamic;

type
  EJsonError = class(Exception);

  { ------------------------------------------------------------------------
    DESERIALIZATION ERROR CATEGORIES.

    Both are EJsonError descendants, so every existing handler and every
    existing message is unaffected: only the class becomes more specific.
    They exist so TryDeserialize can tell "the caller handed us input this
    type cannot represent" apart from "something inside the serializer, a
    constructor, or a custom serializer went wrong" - a distinction that
    cannot be made from the exception class alone, because the member
    wrapper turns every failure into an EJsonError for context.

    EJsonInputError is raised ONLY where the failure is caused by the input:
    a wrong JSON shape, an unknown enum or set value, a scalar that will not
    convert.  It is never raised for a construction failure, a registration
    defect, an unsupported target type or an unexpected exception.

    EJsonInternalError marks a failure that did NOT originate in input
    handling but was wrapped to add member context.  It always propagates
    out of TryDeserialize.
    ------------------------------------------------------------------------ }
  EJsonInputError = class(EJsonError);
  EJsonInternalError = class(EJsonError);

  { Raised when a serialization operation that was given an explicit output
    budget exceeds it.  This is NOT a serializer defect and NOT a statement
    about the value being serialized: it means the caller asked to be
    protected from an unbounded graph and that protection fired.

    Production serialization has no budget, so this can never occur unless a
    caller sets TJsonSerializationOptions.MaxOutputBytes. }
  EJsonSerializationLimitExceeded = class(EJsonError)
  private
    FLimit: Int64;
    FEstimated: Int64;
    FPath: string;
  public
    constructor CreateLimit(ALimit, AEstimated: Int64; const APath: string);
    { The budget that was set, in estimated output bytes. }
    property Limit: Int64 read FLimit;
    { The running estimate at the moment the budget was exceeded. }
    property Estimated: Int64 read FEstimated;
    { Best-effort "Type.Member" of the member being written when the budget
      was hit.  May be empty. }
    property Path: string read FPath;
  end;

  { The categories a caller may ask TryDeserialize to report as an ordinary
    False instead of an exception.  Anything outside these categories - an
    access violation, a broken constructor, a custom serializer bug, an
    internal invariant failure - always propagates. }
  TJsonDeserializationError = (
    { The text is not syntactically valid JSON. }
    InvalidJson,
    { The text is valid JSON but cannot represent the requested target type
      under current serializer semantics. }
    TypeMismatch
  );
  TJsonDeserializationErrors = set of TJsonDeserializationError;

  TJsonSerializerContext = record
    OwnerTypeInfo: PTypeInfo;
    MemberName: string;
    DeclaredTypeInfo: PTypeInfo;
  end;

  TJsonNaming = (DefaultStyle, SnakeCase);

  TJsonRecursiveReferencePolicy = (WriteNull, Error);
  TJsonMemberStrategy = (PublicSurface, FieldsOnly, PropertiesOnly, AllRTTI);
  TJsonPropertyReadErrorPolicy = (RaiseError, SkipMember, WriteNull);
  { HOW MUCH OF A STRING GETS SPELLED AS \uXXXX

    Both settings produce valid JSON and the same values; they differ only
    in how the document reads to a human.

    JSON requires exactly three things to be escaped - the quote, the
    backslash, and characters below U+0020 - and PascalForge escapes exactly
    those. Everything else is written as itself, so

        "Name": "დიდი ტელევიზორი"

    stays legible instead of turning into sixteen \uXXXX groups. That is the
    default, and it is what the emitted UTF-8 bytes then carry.

    EscapeNonAscii is for a consumer that genuinely needs 7-bit output - an
    old protocol, a log pipeline that mangles high bytes - and it is a
    deliberate request, never something that happens by default.

    This lives in the JSON facade, not in the shared core: it is a fact
    about how JSON spells text, and XML and BSON have nothing like it. }
  TJsonUnicodeEscapePolicy = (
    { Escape only what JSON requires. The default. }
    PreserveUnicode,
    { Additionally escape every character above U+007F as \uXXXX, a
      surrogate pair as two groups. }
    EscapeNonAscii
  );

  TJsonSerializationOptions = record
  public
    PropertyReadErrorPolicy: TJsonPropertyReadErrorPolicy;
    { Default: PreserveUnicode. }
    UnicodeEscape: TJsonUnicodeEscapePolicy;
    { Per-operation ceiling on the ESTIMATED size of the JSON this operation
      will produce, in bytes.  0 - the default - means UNLIMITED, which is
      the production behaviour and is byte-for-byte what it always was.

      When set, the estimate is accumulated AS the document is built and the
      operation aborts with EJsonSerializationLimitExceeded as soon as the
      running total passes the ceiling, so a pathological graph is stopped
      before it has allocated a large tree rather than after.

      The budget belongs to one operation on one thread: it is not global
      configuration, it does not participate in FreezeConfiguration, it never
      touches a cached plan, and two threads may serialize concurrently with
      different budgets.

      What is counted, deliberately conservatively:
        * every scalar's text, plus its quotes
        * every member name, plus its quotes, colon and separator
        * every dictionary key, likewise
        * two bytes for each object and array
      The estimate tracks the final document closely but is not a promise of
      exact byte accounting; its purpose is to bound memory growth. }
    MaxOutputBytes: Int64;
    class function Default: TJsonSerializationOptions; static;
  end;


  TCustomJsonValueSerializer = class
  public
    function SerializeValue(const AValue: TValue): TJSONValue; virtual; abstract;
    function DeserializeValue(const AJson: TJSONValue; ATypeInfo: PTypeInfo): TValue; virtual; abstract;
    function DeserializeInto(const AJson: TJSONValue; ATypeInfo: PTypeInfo;
      AExisting: TObject; out AValue: TValue): Boolean; virtual;
    function SerializeValueContext(const AValue: TValue;
      const AContext: TJsonSerializerContext): TJSONValue; virtual;
    function DeserializeValueContext(const AJson: TJSONValue;
      ATypeInfo: PTypeInfo; const AContext: TJsonSerializerContext): TValue; virtual;
    function DeserializeIntoContext(const AJson: TJSONValue;
      ATypeInfo: PTypeInfo; AExisting: TObject;
      const AContext: TJsonSerializerContext; out AValue: TValue): Boolean; virtual;
  end;
  { Canonical class reference for every serializer registration.  Passing a
    class that is not a TCustomJsonValueSerializer descendant is now a
    compile-time error instead of a runtime ResolveSerializer failure. }
  TJsonValueSerializerClass = class of TCustomJsonValueSerializer;

  { ------------------------------------------------------------------------
    THE TYPED EXTENSION LAYER.

    TValue is infrastructure.  A developer who knows the Delphi type at
    compile time should write that type, so these sit on top of the runtime
    contract above and do the TValue bridging themselves:

      type
        TPurposeSerializer = class(TCustomJsonValueSerializer<string>)
        public
          function SerializeValue(const AValue: string): TJSONValue; override;
          function DeserializeValue(const AJson: TJSONValue): string; override;
        end;

    Nothing here changes how the engine runs.  A TCustomJsonValueSerializer<T>
    IS a TCustomJsonValueSerializer, resolved to the same framework-owned
    singleton and held in the same plan.

    Use the NON-generic base instead when the implementation deliberately
    handles more than one runtime type - a generic-family serializer
    registered for TBound<Integer>, TBound<string> and TBound<TDateTime>
    knows its closed type only from RTTI, and TValue/PTypeInfo is the right
    tool for that job.
    ------------------------------------------------------------------------ }
  TCustomJsonValueSerializer<T> = class(TCustomJsonValueSerializer)
  public
    { --- the contract an implementation overrides ---------------------- }
    function SerializeValue(const AValue: T): TJSONValue; reintroduce; overload; virtual; abstract;
    function DeserializeValue(const AJson: TJSONValue): T; reintroduce; overload; virtual; abstract;
    { Optional, and only meaningful when T is a class: populate the instance
      the caller already owns instead of constructing a new one.  Returning
      False - the default - means "not handled", and the engine falls back to
      DeserializeValue exactly as it does for the untyped base.

      NEVER free AExisting: it belongs to the caller.  This is the same
      ownership contract as the untyped DeserializeInto; see
      docs\deserialization-ownership.md. }
    function DeserializeInto(const AJson: TJSONValue; AExisting: T): Boolean; reintroduce; overload; virtual;

    { --- the bridges; an implementation never touches these ------------ }
    function SerializeValue(const AValue: TValue): TJSONValue; overload; override;
    function DeserializeValue(const AJson: TJSONValue;
      ATypeInfo: PTypeInfo): TValue; overload; override;
    function DeserializeInto(const AJson: TJSONValue; ATypeInfo: PTypeInfo;
      AExisting: TObject; out AValue: TValue): Boolean; overload; override;
  end;

  { Delegates, for a transformation too small to deserve a class. }
  TJsonSerializeFunc<T> = reference to function(const AValue: T): TJSONValue;
  TJsonDeserializeFunc<T> = reference to function(const AJson: TJSONValue): T;
  TJsonDeserializeIntoFunc<T> = reference to function(const AJson: TJSONValue;
    AExisting: T): Boolean;

  { INTERNAL INFRASTRUCTURE.  The adapter that makes a set of delegates look
    like an ordinary serializer to the engine.  It is in the interface
    section only because Delphi requires a generic method declared there to
    reference declared types; construct it through SerializeWith<T>,
    DeserializeWith<T> or RegisterTypeSerializer<T>, never directly.

    An unassigned delegate is not an error: it means "that direction was not
    customised", and the two TValue overrides below route it to the built-in
    behaviour. }
  TJsonDelegateSerializer<T> = class(TCustomJsonValueSerializer<T>)
  private
    FSerialize: TJsonSerializeFunc<T>;
    FDeserialize: TJsonDeserializeFunc<T>;
    FDeserializeInto: TJsonDeserializeIntoFunc<T>;
  public
    constructor Create(const ASerialize: TJsonSerializeFunc<T>;
      const ADeserialize: TJsonDeserializeFunc<T>;
      const ADeserializeInto: TJsonDeserializeIntoFunc<T>);
    function SerializeValue(const AValue: T): TJSONValue; override;
    function DeserializeValue(const AJson: TJSONValue): T; override;
    function DeserializeInto(const AJson: TJSONValue; AExisting: T): Boolean; override;
    { A one-sided registration leaves one of these unassigned.  These two
      intercept the engine's call before the typed bridge runs, and hand the
      untouched direction back to the built-in behaviour for the member's
      declared type. }
    function SerializeValue(const AValue: TValue): TJSONValue; override;
    function DeserializeValue(const AJson: TJSONValue;
      ATypeInfo: PTypeInfo): TValue; override;
  end;

  TJsonFieldOverride = record
  public
    HasJsonName: Boolean;
    JsonName: string;
    SerializerClass: TJsonValueSerializerClass;
    { Set instead of SerializerClass when the override carries delegates: a
      delegate adapter cannot be built by a parameterless constructor, so it
      is created once here and owned by the framework for the life of the
      process.  Exactly one of the two is ever set. }
    SerializerInstance: TCustomJsonValueSerializer;
    HasIgnore: Boolean;
    DoIgnore: Boolean;
    HasMemberStrategy: Boolean;
    MemberStrategy: TJsonMemberStrategy;
    HasRecursionPolicy: Boolean;
    RecursionPolicy: TJsonRecursiveReferencePolicy;
    class function Rename(const AJsonName: string): TJsonFieldOverride; static;
    { Untyped: for a serializer that deliberately spans several runtime
      types.  No compile-time relationship between the member and the
      serializer is possible, or wanted, here. }
    class function SerializeWith(
      ASerializerClass: TJsonValueSerializerClass): TJsonFieldOverride; overload; static;

    { ------------------------------------------------------------------
      TYPED.  The member's Delphi type is stated once and the serializer is
      checked against it:

        TJsonSerializer.RegisterFieldOverride<TEntry>('Purpose',
          TJsonFieldOverride.SerializeWith<string>(TPurposeSerializer));

      Delphi has no generic class references (`class of TFoo<T>` does not
      compile), so the class argument cannot be typed by the compiler. It is
      checked HERE instead - when the descriptor is built, before
      registration - and the error names the expected type, the actual
      serializer and the member contract it implements.

      For a guarantee the compiler enforces, use the two-parameter form
      below, which Delphi rejects at compile time with E2515. }
    class function SerializeWith<T>(
      ASerializerClass: TJsonValueSerializerClass): TJsonFieldOverride; overload; static;

    { Compile-time checked: the serializer is a TYPE argument, so a mismatch
      is E2515 rather than a message at startup.

        TJsonFieldOverride.SerializeWith<string, TPurposeSerializer> }
    class function SerializeWith<T; TSer: TCustomJsonValueSerializer<T>,
      constructor>: TJsonFieldOverride; overload; static;

    { Delegates, for a transformation too small to deserve a class:

        TJsonFieldOverride.SerializeWith<string>(
          function(const Value: string): TJSONValue
          begin
            Result := TJSONString.Create(Value.Trim);
          end,
          function(const Json: TJSONValue): string
          begin
            Result := Json.Value.Trim;
          end)

      The adapter is built once, here, and reused for every value - never per
      operation.  Delegates must be stateless, or capture only immutable
      state; anything mutable they capture is the caller's to make
      thread-safe. }
    class function SerializeWith<T>(const ASerialize: TJsonSerializeFunc<T>;
      const ADeserialize: TJsonDeserializeFunc<T>): TJsonFieldOverride; overload; static;

    { The same, plus the optional populate-in-place delegate for a
      class-valued member.  ADeserializeInto must never free AExisting. }
    class function SerializeWith<T>(const ASerialize: TJsonSerializeFunc<T>;
      const ADeserialize: TJsonDeserializeFunc<T>;
      const ADeserializeInto: TJsonDeserializeIntoFunc<T>): TJsonFieldOverride; overload; static;

    { ONE-SIDED.  Customise only the direction you care about; the other one
      keeps doing exactly what it would have done with no registration at all,
      for the member's declared type.  There is no pass-through delegate to
      write, and nothing fails because the opposite delegate is absent.

        // written as a trimmed string, read back the ordinary way
        TJsonFieldOverride.SerializeWith<string>(
          function(const Value: string): TJSONValue
          begin
            Result := TJSONString.Create(Value.Trim);
          end)

        // written the ordinary way, read through a parser
        TJsonFieldOverride.DeserializeWith<TMoney>(
          function(const Json: TJSONValue): TMoney
          begin
            Result := TMoney.Parse(Json.Value);
          end) }
    class function SerializeWith<T>(
      const ASerialize: TJsonSerializeFunc<T>): TJsonFieldOverride; overload; static;
    class function DeserializeWith<T>(
      const ADeserialize: TJsonDeserializeFunc<T>): TJsonFieldOverride; overload; static;
    { Reading only, including how to fill an instance the caller already owns.
      ADeserializeInto must never free AExisting. }
    class function DeserializeWith<T>(
      const ADeserialize: TJsonDeserializeFunc<T>;
      const ADeserializeInto: TJsonDeserializeIntoFunc<T>): TJsonFieldOverride; overload; static;
    class function Create(const AJsonName: string;
      ASerializerClass: TJsonValueSerializerClass): TJsonFieldOverride; static;
    class function Ignore: TJsonFieldOverride; static;
    class function Members(AStrategy: TJsonMemberStrategy): TJsonFieldOverride; static;
    class function RecursiveReferences(
      APolicy: TJsonRecursiveReferencePolicy): TJsonFieldOverride; static;
  end;

  TJsonClassFactory = reference to function: TObject;

  { ------------------------------------------------------------------------
    ATTRIBUTES

    Annotate a member where it is declared.  They live in this unit, so a DTO
    needs no second uses entry:

        type
          TShipment = class
          public
            [JsonName('shipment_id')] Id: string;
            [JsonIgnore]             Scratch: Integer;
            [JsonSerializer(TMoneyJsonSerializer)] Amount: TMoney;
          end;
    ------------------------------------------------------------------------ }

  { The JSON member name to use instead of the derived one. }
  JsonNameAttribute = class(TCustomAttribute)
  private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

  { Leave the member out of the JSON document entirely, in both directions. }
  { How a TDate, TTime or TDateTime member is written. JSON's setting; it
    has no effect on XML or BSON, which have their own.

    Iso8601 is the built-in default: yyyy-mm-dd for TDate, hh:nn:ss for
    TTime, and ISO 8601 with no zone offset for TDateTime, because a
    TDateTime carries none. Text with an offset is read as the instant it
    states, normalised to UTC. }
  TJsonDateTimeFormat = (
    Iso8601,
    { Whole seconds since 1970-01-01T00:00:00, as a JSON number. }
    UnixSeconds,
    { Milliseconds since the same epoch, as a JSON number. }
    UnixMilliseconds,
    { A Delphi FormatDateTime pattern, used for both directions. }
    Custom);

  JsonDateTimeFormatAttribute = class(TCustomAttribute)
  strict private
    FFormat: TJsonDateTimeFormat;
    FPattern: string;
  public
    constructor Create(AFormat: TJsonDateTimeFormat); overload;
    constructor Create(const APattern: string); overload;
    property Format: TJsonDateTimeFormat read FFormat;
    property Pattern: string read FPattern;
  end;

  JsonIgnoreAttribute = class(TCustomAttribute)
  end;

  { Write and read this member through a specific serializer.  The class is
    checked by the compiler. }
  JsonSerializerAttribute = class(TCustomAttribute)
  private
    FSerializerClass: TJsonValueSerializerClass;
  public
    constructor Create(ASerializerClass: TJsonValueSerializerClass);
    property SerializerClass: TJsonValueSerializerClass read FSerializerClass;
  end;

  { ------------------------------------------------------------------------
    INFRASTRUCTURE.

    The typed extension layer above is built out of these four, so that the
    conversion and ownership they perform is written once rather than in every
    serializer.  Normal code never calls them; they are published only because
    a generic method body may reference nothing but interface declarations.
    ------------------------------------------------------------------------ }
  TJsonExtensionSupport = class
  public
    { The Delphi name of T, for a diagnostic.  '<unnamed>' when T has no RTTI
      name, which some anonymous types do not. }
    class function TypeNameOf<T>: string; static;
    { AValue.AsType<T> with a message that says which serializer expected what
      and what it actually received.  A failure here is framework misuse - a
      serializer registered against the wrong member - not a JSON type
      mismatch, and it must not be mistaken for one. }
    class function ValueAsTyped<T>(const AValue: TValue;
      ASerializerClass: TClass): T; static;
    { Takes ownership of a serializer the framework built itself - today, a
      delegate adapter - so its captured state lives exactly as long as the
      registrations that use it.  Returns the same instance. }
    class function AdoptSerializer(
      AInstance: TCustomJsonValueSerializer): TCustomJsonValueSerializer; static;
    { What the engine would do for ATypeInfo with nothing registered for it.
      A one-sided delegate uses these for the direction it does not implement,
      and because no registry is consulted they cannot lead back into the
      serializer that called them. }
    class function SerializeBuiltIn(ATypeInfo: PTypeInfo;
      const AValue: TValue): TJSONValue; static;
    class function DeserializeBuiltIn(ATypeInfo: PTypeInfo;
      const AJson: TJSONValue): TValue; static;
  end;


  { ------------------------------------------------------------------------
    THE SERIALIZER

    Everything an application does with JSON. The operations come first, then
    the registrations that customise them; both are documented where they are
    declared.

    This class is a facade. The engine behind it - cached execution plans,
    RTTI traversal, member conversion - lives in PascalForge.Json.Internal, and
    none of it appears here.
    ------------------------------------------------------------------------ }
  TJsonSerializer = class
  strict private
    { The engine lives in a unit this one may only reach from its
      implementation section, and a generic method body may reference nothing
      but interface declarations.  These five non-generic bridges are how the
      generic entry points below get there. }
    class function DoSerialize(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AOptions: TJsonSerializationOptions): string; static;
    class function DoDeserialize(ATypeInfo: PTypeInfo;
      const AJson: TJSONValue): TValue; static;
    class function DoTryParse(const AJson: string; out AParsed: TJSONValue;
      out AError: string): Boolean; static;
    class function DoClassifyError(E: Exception;
      out AKind: TJsonDeserializationError): Boolean; static;
    class procedure DoCheckNotFrozen; static;
    class function DoFrom(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload; AFrom: TSerializationFormat): string; static;
    class procedure DoSetDateTimePolicy(ATypeInfo: PTypeInfo;
      const AFieldName: string; AFormat: TJsonDateTimeFormat;
      const APattern: string); static;
    class procedure DoSeedDelegate(ATypeInfo: PTypeInfo;
      ASerializerClass: TJsonValueSerializerClass;
      AInstance: TCustomJsonValueSerializer); static;
  public
    class function ToJson(const AInstance: TObject): TJSONObject; static;
    class function ToJsonString(const AInstance: TObject): string; static;
    class procedure Populate(const AInstance: TObject; const AJson: TJSONValue); overload; static;
    class procedure Populate(const AInstance: TObject; const AJson: string); overload; static;

    class function Serialize<T>(const AInstance: T): string; overload; static;
    class function Serialize<T>(const AInstance: T; const AOptions: TJsonSerializationOptions): string; overload; static;
    class function Deserialize<T>(const AJson: string): T; overload; static;
    class function DeserializeValue<T>(const AJson: TJSONValue): T; overload; static;

    { --- UTF-8, when what you need is bytes --------------------------------

      Serialize<T> returns a Delphi string, which is Unicode TEXT and has no
      byte encoding at all until somebody picks one. That is the right
      result for a string, and it is unchanged.

      When the destination is a socket, a file or an HTTP body, the bytes
      have to be chosen explicitly - and UTF-8 is the only encoding JSON
      specifies, so it is the only one offered:

          Bytes := TJsonSerializer.SerializeUtf8<TShipment>(Shipment);

      No BOM. A BOM in UTF-8 marks a byte order that does not exist, and
      several strict JSON parsers reject a document that starts with one.
      DeserializeUtf8 accepts one anyway, because producers emit them.

      Nothing here goes near an AnsiString, the system code page or a
      locale. Malformed input bytes raise EInvalidUtf8 naming the offset
      rather than turning into U+FFFD. }
    class function SerializeUtf8<T>(const AInstance: T): TBytes; overload; static;
    class function SerializeUtf8<T>(const AInstance: T;
      const AOptions: TJsonSerializationOptions): TBytes; overload; static;
    class function DeserializeUtf8<T>(const AJson: TBytes): T; static;

    { --- destination-oriented conversion -----------------------------------

      JSON is the destination and is known at compile time, so only the
      SOURCE format is looked up. This unit has no compile-time dependency
      on any other format: the source is reached through the registry, which
      means the source format has to be registered explicitly at startup.

          Json := TJsonSerializer.From(Xml, TSerializationFormat.Xml);
          Json := TJsonSerializer.From<TShipment>(Xml, TSerializationFormat.Xml);

      The generic form is CONTRACT-AWARE: the source deserializes into T by
      its own rules and JSON writes T by its own, so each side's attributes
      apply. The non-generic form is STRUCTURAL and carries only what every
      format shares.

      A binary source arrives as TBytes or as a TSerializationPayload. There
      is no base64-pretending-to-be-text overload. }
    class function From(const ASource: string;
      AFrom: TSerializationFormat): string; overload; static;
    class function From(const ASource: TBytes;
      AFrom: TSerializationFormat): string; overload; static;
    class function From(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): string; overload; static;

    { Structural conversion, with the profile named. See
      TStructuralConversionProfile: Natural writes idiomatic JSON, Lossless
      writes the published standard for the pair - MongoDB Extended JSON for
      BSON's types - or refuses, and Strict refuses anything JSON cannot
      represent directly - with the member path in the message. }
    class function From(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat;
      AProfile: TStructuralConversionProfile): string; overload; static;
    class function From(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat; AProfile: TStructuralConversionProfile;
      AEscape: TJsonUnicodeEscapePolicy): string; overload; static;

    class function From<T>(const ASource: string;
      AFrom: TSerializationFormat): string; overload; static;
    class function From<T>(const ASource: TBytes;
      AFrom: TSerializationFormat): string; overload; static;
    class function From<T>(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): string; overload; static;

    { ----------------------------------------------------------------------
      TryDeserialize - the same deserialization, with selected INPUT failures
      reported as False instead of raising.

        if TJsonSerializer.TryDeserialize<TCustomer>(Json, Customer) then ...

      By default only malformed JSON text is handled; add TypeMismatch to
      also absorb valid JSON that the target type cannot represent:

        if not TJsonSerializer.TryDeserialize<TCustomer>(Json, Customer, Err,
             [TJsonDeserializationError.InvalidJson,
              TJsonDeserializationError.TypeMismatch]) then
          Log(Err);

      This is NOT a catch-all.  An access violation, a failing constructor, a
      custom serializer bug or any internal serializer failure propagates,
      whatever AHandledErrors says.

      On a handled failure AValue is Default(T) - never a partially
      deserialized value, and nothing is leaked: the deserializer frees what
      it built before the failure, and the completed value is assigned to
      AValue only after it is complete.  That guarantee is possible here
      precisely because a NEW value is produced; Populate mutates a target the
      caller already owns and therefore stays exception-based.
      ---------------------------------------------------------------------- }
    class function TryDeserialize<T>(const AJson: string; out AValue: T;
      AHandledErrors: TJsonDeserializationErrors =
        [TJsonDeserializationError.InvalidJson]): Boolean; overload; static;
    { AError carries the serializer's own contextual message on a handled
      failure, and '' on success. }
    class function TryDeserialize<T>(const AJson: string; out AValue: T;
      out AError: string; AHandledErrors: TJsonDeserializationErrors =
        [TJsonDeserializationError.InvalidJson]): Boolean; overload; static;

    class procedure RegisterFieldOverride<T>(const AFieldName: string;
      const AOverride: TJsonFieldOverride); overload; static;
    class procedure RegisterFieldOverride(AClass: TClass; const AFieldName: string; const AOverride: TJsonFieldOverride); overload; static;
    class procedure RegisterFieldOverride(AOwnerTypeInfo: PTypeInfo; const AFieldName: string; const AOverride: TJsonFieldOverride); overload; static;
    class procedure RegisterFieldOverride(const AQualifiedOwnerTypeName, AFieldName: string;
      const AOverride: TJsonFieldOverride); overload; static;
    class procedure RegisterClassFieldOverride(AClass: TClass; const AFieldPattern: string; const AOverride: TJsonFieldOverride; AIncludeDescendants: Boolean = False); static;
    class procedure RegisterUnitFieldOverride(const AUnitPattern, AFieldPattern: string; const AOverride: TJsonFieldOverride); static;
    class procedure RegisterUnitNaming(const AUnitPattern: string; ANaming: TJsonNaming); static;
    class procedure RegisterClassNaming(AClass: TClass; ANaming: TJsonNaming; AIncludeDescendants: Boolean = False); overload; static;
    class procedure RegisterClassNaming(const AQualifiedTypeName: string; ANaming: TJsonNaming); overload; static;
    { ----------------------------------------------------------------------
      SERIALIZER PRECEDENCE.

      A member's serializer is chosen once, while its plan is built, in this
      order.  The first source that yields a class wins; later sources are not
      consulted:

        1. [JsonSerializer(...)] attribute on the field or property
        2. field override rule - TJsonFieldOverride.SerializeWith, resolved
           across its own scopes as: exact field > exact class > class and
           descendants > unit name > unit pattern, and within one scope the
           latest registration wins
        3. RegisterUnitClassTypeSerializer - matched on the OWNER's declaring
           unit and the value's base class
        4. RegisterTypeSerializer - exact PTypeInfo
        5. RegisterGenericTypeSerializer - declaring unit + generic base name
           + arity of the declared type
        6. RegisterClassTypeSerializer - nearest registered ancestor of the
           declared class
        7. no serializer: the built-in kind-based executor

      Two runtime refinements apply on top of that plan decision:
        - For an object-shaped member with no plan-level serializer, steps
          4-6 are re-evaluated against the RUNTIME class of the value, so a
          descendant can still be handled by its own registration.
        - RegisterSerializationSurface, when it matches, decides which member
          contract is used; it does not select a serializer.
      ---------------------------------------------------------------------- }
    class procedure RegisterTypeSerializer<T>(
      ASerializerClass: TJsonValueSerializerClass); overload; static;
    { Compile-time checked: the compiler rejects a serializer that is not a
      TCustomJsonValueSerializer<T>.  Prefer this to the line above.
        TJsonSerializer.RegisterTypeSerializer<TMoney, TMoneySerializer>; }
    class procedure RegisterTypeSerializer<T; TSer: TCustomJsonValueSerializer<T>,
      constructor>; overload; static;
    { No class at all - two functions, named or inline:
        TJsonSerializer.RegisterTypeSerializer<TMoney>(
          function(const AValue: TMoney): TJSONValue
          begin
            Result := TJSONString.Create(AValue.ToString);
          end,
          function(const AJson: TJSONValue): TMoney
          begin
            Result := TMoney.Parse(AJson.Value);
          end);
      The closures are captured once, here, and owned by the framework until
      teardown.  They must be stateless or capture only immutable state:
      serialization is concurrent and nothing locks around them. }
    class procedure RegisterTypeSerializer<T>(
      const ASerialize: TJsonSerializeFunc<T>;
      const ADeserialize: TJsonDeserializeFunc<T>); overload; static;
    { The third function fills a caller-owned instance in place and returns
      True; returning False - or omitting it - means "build a new one". }
    class procedure RegisterTypeSerializer<T>(
      const ASerialize: TJsonSerializeFunc<T>;
      const ADeserialize: TJsonDeserializeFunc<T>;
      const ADeserializeInto: TJsonDeserializeIntoFunc<T>); overload; static;
    class procedure RegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TJsonValueSerializerClass); overload; static;
    class procedure RegisterGenericTypeSerializer<T>(
      ASerializerClass: TJsonValueSerializerClass); overload; static;
    class procedure RegisterGenericTypeSerializer(ARepresentativeTypeInfo: PTypeInfo;
      ASerializerClass: TJsonValueSerializerClass); overload; static;
    class procedure RegisterClassTypeSerializer(ABaseClass: TClass;
      ASerializerClass: TJsonValueSerializerClass); static;
    class procedure RegisterUnitClassTypeSerializer(const AOwnerUnitPattern: string;
      AValueBaseClass: TClass;
      ASerializerClass: TJsonValueSerializerClass); static;
    class procedure RegisterOpaqueClass(ABaseClass: TClass); static;
    { Advanced: force ARuntimeClass (and its descendants that have no closer
      rule) to serialize through the member contract of AContractClass.  This
      is the explicit form of the public-surface downgrade that used to happen
      automatically for every implementation-declared class. }
    class procedure RegisterSerializationSurface(ARuntimeClass,
      AContractClass: TClass); static;
    class procedure SetDefaultMemberStrategy(AStrategy: TJsonMemberStrategy); static;
    class procedure RegisterTypeMemberStrategy(ATypeInfo: PTypeInfo;
      AStrategy: TJsonMemberStrategy); overload; static;
    class procedure RegisterTypeMemberStrategy<T>(
      AStrategy: TJsonMemberStrategy); overload; static;
    class procedure SetDefaultRecursiveReferencePolicy(
      APolicy: TJsonRecursiveReferencePolicy); static;
    class procedure RegisterTypeRecursiveReferencePolicy(ATypeInfo: PTypeInfo;
      APolicy: TJsonRecursiveReferencePolicy); overload; static;
    class procedure RegisterTypeRecursiveReferencePolicy<T>(
      APolicy: TJsonRecursiveReferencePolicy); overload; static;
    { --- date and time ----------------------------------------------------

      JSON's settings, independent of XML's and BSON's. Resolution is a
      member attribute, then a field registration, then a type
      registration, then this global default, then the built-in ISO 8601
      forms - and it happens once, while a plan is built. }
    class procedure SetDateTimeFormat(AFormat: TJsonDateTimeFormat); overload; static;
    class procedure SetDateTimeFormat(const APattern: string); overload; static;
    class procedure RegisterDateTimeFormat<T>(
      AFormat: TJsonDateTimeFormat); overload; static;
    class procedure RegisterDateTimeFormat<T>(
      const APattern: string); overload; static;
    class procedure RegisterFieldDateTimeFormat<T>(const AFieldName: string;
      AFormat: TJsonDateTimeFormat); overload; static;
    class procedure RegisterFieldDateTimeFormat<T>(const AFieldName: string;
      const APattern: string); overload; static;

    class procedure RegisterEnumMapping<T>(const AValues: array of string); overload; static;
    class procedure RegisterEnumMapping(ATypeInfo: PTypeInfo; const AValues: array of string); overload; static;
    class procedure RegisterEnumMapping(const AQualifiedTypeName: string; const AValues: array of string); overload; static;
    class procedure RegisterFieldEnumMapping(const AQualifiedOwnerTypeName, AFieldName: string;
      const AValues: array of string); static;
    class procedure RegisterClassFactory<T>(const AFactory: TJsonClassFactory); overload; static;
    class procedure RegisterClassFactory(ATypeInfo: PTypeInfo; const AFactory: TJsonClassFactory); overload; static;

    { Declares the unit that owns a type.  Only needed for records declared
      in an implementation section, whose RTTI carries no unit name; without
      it, unit-scoped and qualified-name-scoped registrations cannot match
      such a record.  Call it once from the declaring unit. }
    class procedure RegisterTypeUnit(ATypeInfo: PTypeInfo;
      const AUnitName: string); static;
    { The stable registration key of a type, matching what qualified-name
      scoped registrations are compared against. }
    class function TypeKeyFor(ATypeInfo: PTypeInfo): string; static;

    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;

    { --- dynamic ---------------------------------------------------------

      A JSON document as a dynamic value, and a dynamic value as JSON text,
      with no Delphi type involved. The tree is the caller's. }
    class function ToDynamic(const AJson: string): TDynamicValue; overload; static;
    class function ToDynamic(const AJson: string;
      const AOptions: TStructuralConversionOptions): TDynamicValue; overload; static;
    class function FromDynamic(AValue: TDynamicValue): string; overload; static;
    class function FromDynamic(AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions): string; overload; static;
  end;

implementation

uses
  PascalForge.Json.Internal;
constructor EJsonSerializationLimitExceeded.CreateLimit(ALimit,
  AEstimated: Int64; const APath: string);
begin
  if APath = '' then
    inherited CreateFmt(
      'JSON serialization limit exceeded: limit=%d estimated=%d',
      [ALimit, AEstimated])
  else
    inherited CreateFmt(
      'JSON serialization limit exceeded: limit=%d estimated=%d path=%s',
      [ALimit, AEstimated, APath]);
  FLimit := ALimit;
  FEstimated := AEstimated;
  FPath := APath;
end;
function TCustomJsonValueSerializer.DeserializeInto(const AJson: TJSONValue;
  ATypeInfo: PTypeInfo; AExisting: TObject; out AValue: TValue): Boolean;
begin
  Result := False;
end;
function TCustomJsonValueSerializer.SerializeValueContext(const AValue: TValue;
  const AContext: TJsonSerializerContext): TJSONValue;
begin
  Result := SerializeValue(AValue);
end;
function TCustomJsonValueSerializer.DeserializeValueContext(
  const AJson: TJSONValue; ATypeInfo: PTypeInfo;
  const AContext: TJsonSerializerContext): TValue;
begin
  Result := DeserializeValue(AJson, ATypeInfo);
end;
function TCustomJsonValueSerializer.DeserializeIntoContext(
  const AJson: TJSONValue; ATypeInfo: PTypeInfo; AExisting: TObject;
  const AContext: TJsonSerializerContext; out AValue: TValue): Boolean;
begin
  Result := DeserializeInto(AJson, ATypeInfo, AExisting, AValue);
end;
class function TJsonSerializationOptions.Default: TJsonSerializationOptions;
begin
  Result := System.Default(TJsonSerializationOptions);
  Result.PropertyReadErrorPolicy := TJsonPropertyReadErrorPolicy.RaiseError;
  Result.UnicodeEscape := TJsonUnicodeEscapePolicy.PreserveUnicode;
end;
class function TJsonFieldOverride.Rename(const AJsonName: string): TJsonFieldOverride;
begin
  Result := Default(TJsonFieldOverride);
  Result.HasJsonName := True;
  Result.JsonName := AJsonName;
end;
class function TJsonFieldOverride.SerializeWith(
  ASerializerClass: TJsonValueSerializerClass): TJsonFieldOverride;
begin
  Result := Default(TJsonFieldOverride);
  Result.SerializerClass := ASerializerClass;
end;
class function TJsonFieldOverride.Create(const AJsonName: string;
  ASerializerClass: TJsonValueSerializerClass): TJsonFieldOverride;
begin
  Result := Default(TJsonFieldOverride);
  Result.HasJsonName := True;
  Result.JsonName := AJsonName;
  Result.SerializerClass := ASerializerClass;
end;
class function TJsonFieldOverride.Ignore: TJsonFieldOverride;
begin
  Result := Default(TJsonFieldOverride);
  Result.HasIgnore := True;
  Result.DoIgnore := True;
end;
class function TJsonFieldOverride.Members(
  AStrategy: TJsonMemberStrategy): TJsonFieldOverride;
begin
  Result := Default(TJsonFieldOverride);
  Result.HasMemberStrategy := True;
  Result.MemberStrategy := AStrategy;
end;
class function TJsonFieldOverride.RecursiveReferences(
  APolicy: TJsonRecursiveReferencePolicy): TJsonFieldOverride;
begin
  Result := Default(TJsonFieldOverride);
  Result.HasRecursionPolicy := True;
  Result.RecursionPolicy := APolicy;
end;
function TCustomJsonValueSerializer<T>.SerializeValue(
  const AValue: TValue): TJSONValue;
var
  Typed: T;
begin
  Typed := TJsonExtensionSupport.ValueAsTyped<T>(AValue, ClassType);
  Result := SerializeValue(Typed);
end;
function TCustomJsonValueSerializer<T>.DeserializeValue(
  const AJson: TJSONValue; ATypeInfo: PTypeInfo): TValue;
begin
  { TValue.From<T> is correct for managed types: it copies the value and the
    local goes out of scope normally, so a string or a record with managed
    fields is neither leaked nor double-freed. }
  Result := TValue.From<T>(DeserializeValue(AJson));
end;
function TCustomJsonValueSerializer<T>.DeserializeInto(const AJson: TJSONValue;
  AExisting: T): Boolean;
begin
  { Not handled, which is exactly what the untyped base defaults to.  An
    implementation overrides this only when it can populate a caller-owned
    instance in place. }
  Result := False;
end;
function TCustomJsonValueSerializer<T>.DeserializeInto(const AJson: TJSONValue;
  ATypeInfo: PTypeInfo; AExisting: TObject; out AValue: TValue): Boolean;
var
  Typed: T;
begin
  AValue := TValue.Empty;
  { Populating in place is meaningful only for a class.  For a record, a
    string or a scalar there is no instance to reuse, so the engine's normal
    construct-and-assign path applies. }
  if (AExisting = nil) or (PTypeInfo(System.TypeInfo(T)) = nil) or
     (PTypeInfo(System.TypeInfo(T))^.Kind <> tkClass) then
    Exit(False);
  { The engine only ever offers an instance it already established is
    compatible with the member's declared type, but a serializer registered
    for a base class can still be handed a descendant - so this is checked
    rather than assumed. }
  if not AExisting.InheritsFrom(GetTypeData(System.TypeInfo(T))^.ClassType) then
    Exit(False);
  Typed := TValue.From<TObject>(AExisting).AsType<T>;
  Result := DeserializeInto(AJson, Typed);
  if Result then
    { The SAME instance goes back: identity is preserved, and nothing is
      freed - AExisting belongs to the caller. }
    AValue := TValue.From<T>(Typed);
end;
constructor TJsonDelegateSerializer<T>.Create(
  const ASerialize: TJsonSerializeFunc<T>;
  const ADeserialize: TJsonDeserializeFunc<T>;
  const ADeserializeInto: TJsonDeserializeIntoFunc<T>);
begin
  inherited Create;
  FSerialize := ASerialize;
  FDeserialize := ADeserialize;
  FDeserializeInto := ADeserializeInto;
end;
function TJsonDelegateSerializer<T>.SerializeValue(const AValue: T): TJSONValue;
begin
  { Unreachable through the engine - the TValue override below diverts first -
    but a direct caller deserves a real answer rather than a nil. }
  if not Assigned(FSerialize) then
    raise EJsonError.CreateFmt(
      'No serialize delegate was registered for %s', [TJsonExtensionSupport.TypeNameOf<T>]);
  Result := FSerialize(AValue);
end;
function TJsonDelegateSerializer<T>.DeserializeValue(const AJson: TJSONValue): T;
begin
  if not Assigned(FDeserialize) then
    raise EJsonError.CreateFmt(
      'No deserialize delegate was registered for %s', [TJsonExtensionSupport.TypeNameOf<T>]);
  Result := FDeserialize(AJson);
end;
function TJsonDelegateSerializer<T>.SerializeValue(const AValue: TValue): TJSONValue;
var
  Ti: PTypeInfo;
begin
  if Assigned(FSerialize) then Exit(inherited SerializeValue(AValue));
  { DeserializeWith<T> customised reading only.  Writing stays exactly what it
    would have been with no registration at all: SerializeBuiltIn consults no
    registry, so this cannot come back here. }
  Ti := AValue.TypeInfo;
  if Ti = nil then Ti := System.TypeInfo(T);
  Result := TJsonExtensionSupport.SerializeBuiltIn(Ti, AValue);
end;
function TJsonDelegateSerializer<T>.DeserializeValue(const AJson: TJSONValue;
  ATypeInfo: PTypeInfo): TValue;
begin
  if Assigned(FDeserialize) then Exit(inherited DeserializeValue(AJson, ATypeInfo));
  { SerializeWith<T> customised writing only; reading stays built-in. }
  if ATypeInfo = nil then ATypeInfo := System.TypeInfo(T);
  Result := TJsonExtensionSupport.DeserializeBuiltIn(ATypeInfo, AJson);
end;
function TJsonDelegateSerializer<T>.DeserializeInto(const AJson: TJSONValue;
  AExisting: T): Boolean;
begin
  if not Assigned(FDeserializeInto) then Exit(False);
  Result := FDeserializeInto(AJson, AExisting);
end;
class function TJsonFieldOverride.SerializeWith<T>(
  ASerializerClass: TJsonValueSerializerClass): TJsonFieldOverride;
begin
  Result := Default(TJsonFieldOverride);
  { Checked here, while the descriptor is built, so the message arrives at
    the registration that is wrong rather than at the first serialization of
    some unrelated object. }
  if (ASerializerClass <> nil) and
     not ASerializerClass.InheritsFrom(TCustomJsonValueSerializer<T>) then
    raise EJsonError.CreateFmt(
      '%s cannot serialize %s: SerializeWith<%s> requires a ' +
      'TCustomJsonValueSerializer<%s> descendant. Use the untyped ' +
      'SerializeWith for a serializer that handles several runtime types.',
      [ASerializerClass.ClassName, TJsonExtensionSupport.TypeNameOf<T>, TJsonExtensionSupport.TypeNameOf<T>, TJsonExtensionSupport.TypeNameOf<T>]);
  Result.SerializerClass := ASerializerClass;
end;
class function TJsonFieldOverride.SerializeWith<T, TSer>: TJsonFieldOverride;
begin
  Result := Default(TJsonFieldOverride);
  { The constraint did the checking; there is nothing left to validate. }
  Result.SerializerClass := TJsonValueSerializerClass(TSer);
end;
class function TJsonFieldOverride.SerializeWith<T>(
  const ASerialize: TJsonSerializeFunc<T>;
  const ADeserialize: TJsonDeserializeFunc<T>): TJsonFieldOverride;
begin
  Result := SerializeWith<T>(ASerialize, ADeserialize, nil);
end;
class function TJsonFieldOverride.SerializeWith<T>(
  const ASerialize: TJsonSerializeFunc<T>): TJsonFieldOverride;
begin
  { Writing only.  Reading is left unassigned, which the adapter reads as
    "use the built-in behaviour". }
  Result := SerializeWith<T>(ASerialize, nil, nil);
end;
class function TJsonFieldOverride.DeserializeWith<T>(
  const ADeserialize: TJsonDeserializeFunc<T>): TJsonFieldOverride;
begin
  Result := DeserializeWith<T>(ADeserialize, nil);
end;
class function TJsonFieldOverride.DeserializeWith<T>(
  const ADeserialize: TJsonDeserializeFunc<T>;
  const ADeserializeInto: TJsonDeserializeIntoFunc<T>): TJsonFieldOverride;
begin
  { Reading only; writing stays built-in. }
  Result := SerializeWith<T>(nil, ADeserialize, ADeserializeInto);
end;
class function TJsonFieldOverride.SerializeWith<T>(
  const ASerialize: TJsonSerializeFunc<T>;
  const ADeserialize: TJsonDeserializeFunc<T>;
  const ADeserializeInto: TJsonDeserializeIntoFunc<T>): TJsonFieldOverride;
begin
  Result := Default(TJsonFieldOverride);
  { Built once, owned by the framework, and reused by the plan for every
    value - never constructed per operation. }
  Result.SerializerInstance := TJsonExtensionSupport.AdoptSerializer(
    TJsonDelegateSerializer<T>.Create(ASerialize, ADeserialize,
      ADeserializeInto));
end;
{ ---------------------------------------------------- extension support --- }

class function TJsonExtensionSupport.TypeNameOf<T>: string;
begin
  Result := TSerializationTypeInfo.TypeNameOf<T>;
end;

class function TJsonExtensionSupport.ValueAsTyped<T>(const AValue: TValue;
  ASerializerClass: TClass): T;
var
  Actual, SerName: string;
begin
  try
    Result := AValue.AsType<T>;
  except
    on E: Exception do
    begin
      Actual := TSerializationTypeInfo.ActualNameOf(AValue);
      if ASerializerClass <> nil then
        SerName := ASerializerClass.ClassName
      else
        SerName := '<serializer>';
      { Deliberately NOT phrased as a JSON problem: the JSON was never
        looked at.  A serializer was registered against a member whose type
        it does not handle. }
      raise EJsonError.CreateFmt(
        '%s expects %s but the member holds %s. The serializer is registered ' +
        'against a member of the wrong type. (%s)',
        [SerName, TSerializationTypeInfo.TypeNameOf<T>, Actual, E.Message]);
    end;
  end;
end;

class function TJsonExtensionSupport.AdoptSerializer(
  AInstance: TCustomJsonValueSerializer): TCustomJsonValueSerializer;
begin
  Result := TJsonEngine.AdoptSerializer(AInstance);
end;

class function TJsonExtensionSupport.SerializeBuiltIn(ATypeInfo: PTypeInfo;
  const AValue: TValue): TJSONValue;
begin
  Result := TJsonEngine.SerializeBuiltIn(ATypeInfo, AValue);
end;

class function TJsonExtensionSupport.DeserializeBuiltIn(ATypeInfo: PTypeInfo;
  const AJson: TJSONValue): TValue;
begin
  Result := TJsonEngine.DeserializeBuiltIn(ATypeInfo, AJson);
end;

{ ------------------------------------------------------------ attributes --- }

constructor JsonDateTimeFormatAttribute.Create(AFormat: TJsonDateTimeFormat);
begin
  inherited Create;
  FFormat := AFormat;
  FPattern := '';
end;

constructor JsonDateTimeFormatAttribute.Create(const APattern: string);
begin
  inherited Create;
  FFormat := TJsonDateTimeFormat.Custom;
  FPattern := APattern;
end;

constructor JsonNameAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

constructor JsonSerializerAttribute.Create(
  ASerializerClass: TJsonValueSerializerClass);
begin
  inherited Create;
  FSerializerClass := ASerializerClass;
end;

{ ------------------------------------------------- facade engine bridges --- }

class function TJsonSerializer.DoSerialize(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AOptions: TJsonSerializationOptions): string;
begin
  Result := TJsonEngine.SerializeRoot(ATypeInfo, AValue, AOptions);
end;

class function TJsonSerializer.DoDeserialize(ATypeInfo: PTypeInfo;
  const AJson: TJSONValue): TValue;
begin
  Result := TJsonEngine.DeserializeRoot(ATypeInfo, AJson);
end;

class function TJsonSerializer.DoTryParse(const AJson: string;
  out AParsed: TJSONValue; out AError: string): Boolean;
begin
  Result := TJsonEngine.TryParseJsonText(AJson, AParsed, AError);
end;

class function TJsonSerializer.DoClassifyError(E: Exception;
  out AKind: TJsonDeserializationError): Boolean;
begin
  Result := TJsonEngine.ClassifyDeserializationError(E, AKind);
end;

class procedure TJsonSerializer.DoCheckNotFrozen;
begin
  TJsonEngine.CheckConfigurationNotFrozen;
end;

class procedure TJsonSerializer.DoSeedDelegate(ATypeInfo: PTypeInfo;
  ASerializerClass: TJsonValueSerializerClass;
  AInstance: TCustomJsonValueSerializer);
begin
  TJsonEngine.PublishSerializer(ASerializerClass, AInstance);
  TJsonEngine.RegisterTypeSerializer(ATypeInfo, ASerializerClass);
end;

{ ------------------------------------------------------ typed operations --- }

class function TJsonSerializer.Serialize<T>(const AInstance: T): string;
begin
  Result := Serialize<T>(AInstance, TJsonSerializationOptions.Default);
end;

class function TJsonSerializer.Serialize<T>(const AInstance: T;
  const AOptions: TJsonSerializationOptions): string;
var
  Value: TValue;
begin
  TValue.Make(@AInstance, System.TypeInfo(T), Value);
  Result := DoSerialize(System.TypeInfo(T), Value, AOptions);
end;

class function TJsonSerializer.Deserialize<T>(const AJson: string): T;
var
  V: TJSONValue;
begin
  V := TJSONObject.ParseJSONValue(AJson);
  try
    if V = nil then raise EJsonInputError.Create('Invalid JSON text');
    Result := DeserializeValue<T>(V);
  finally
    V.Free;
  end;
end;

class function TJsonSerializer.DeserializeValue<T>(const AJson: TJSONValue): T;
begin
  Result := DoDeserialize(System.TypeInfo(T), AJson).AsType<T>;
end;

class function TJsonSerializer.TryDeserialize<T>(const AJson: string;
  out AValue: T; AHandledErrors: TJsonDeserializationErrors): Boolean;
var
  Ignored: string;
begin
  Result := TryDeserialize<T>(AJson, AValue, Ignored, AHandledErrors);
end;

class function TJsonSerializer.TryDeserialize<T>(const AJson: string;
  out AValue: T; out AError: string;
  AHandledErrors: TJsonDeserializationErrors): Boolean;
var
  Parsed: TJSONValue;
  Temp: T;
  Kind: TJsonDeserializationError;
begin
  { The out parameters are established before anything can fail, so every
    exit path - including a propagating exception - leaves the caller with a
    default value rather than a half-built one. }
  AValue := Default(T);
  AError := '';
  { Temp is deliberately NOT pre-initialised: it is read only after a
    successful DeserializeValue, and pre-setting it would be dead code the
    compiler rightly flags. }

  if not DoTryParse(AJson, Parsed, AError) then
  begin
    if TJsonDeserializationError.InvalidJson in AHandledErrors then
      Exit(False);
    { Not handled: behave exactly as Deserialize<T> does. }
    raise EJsonInputError.Create(AError);
  end;

  try
    try
      Temp := DeserializeValue<T>(Parsed);
    except
      on E: Exception do
      begin
        if DoClassifyError(E, Kind) and (Kind in AHandledErrors) then
        begin
          { The serializer frees whatever it had built before raising, so
            there is nothing to release here - and Temp was never assigned
            to AValue, so no partial value escapes. }
          AError := E.Message;
          AValue := Default(T);
          Exit(False);
        end;
        raise;
      end;
    end;
  finally
    Parsed.Free;
  end;

  AValue := Temp;
  AError := '';
  Result := True;
end;

{ --------------------------------------------------- typed registrations --- }

class procedure TJsonSerializer.RegisterFieldOverride<T>(
  const AFieldName: string; const AOverride: TJsonFieldOverride);
begin
  RegisterFieldOverride(System.TypeInfo(T), AFieldName, AOverride);
end;

class procedure TJsonSerializer.RegisterTypeSerializer<T>(
  ASerializerClass: TJsonValueSerializerClass);
begin
  RegisterTypeSerializer(System.TypeInfo(T), ASerializerClass);
end;

class procedure TJsonSerializer.RegisterTypeSerializer<T, TSer>;
begin
  { The constraint already proved TSer handles T; there is nothing to check. }
  RegisterTypeSerializer(System.TypeInfo(T), TJsonValueSerializerClass(TSer));
end;

class procedure TJsonSerializer.RegisterTypeSerializer<T>(
  const ASerialize: TJsonSerializeFunc<T>;
  const ADeserialize: TJsonDeserializeFunc<T>);
begin
  RegisterTypeSerializer<T>(ASerialize, ADeserialize, nil);
end;

class procedure TJsonSerializer.RegisterTypeSerializer<T>(
  const ASerialize: TJsonSerializeFunc<T>;
  const ADeserialize: TJsonDeserializeFunc<T>;
  const ADeserializeInto: TJsonDeserializeIntoFunc<T>);
begin
  { Checked before anything is built, so a registration attempted after the
    configuration is frozen changes nothing at all - and allocates nothing.
    Delegates are not a way around the freeze. }
  DoCheckNotFrozen;
  { Every instantiation of TJsonDelegateSerializer<T> is a distinct class, so
    T's delegates can be published as that class's singleton.  The engine
    then resolves them through the ordinary class-keyed path - no second
    registry, no per-operation lookup, no per-operation allocation. }
  DoSeedDelegate(System.TypeInfo(T), TJsonDelegateSerializer<T>,
    TJsonDelegateSerializer<T>.Create(ASerialize, ADeserialize,
      ADeserializeInto));
end;

class procedure TJsonSerializer.RegisterGenericTypeSerializer<T>(
  ASerializerClass: TJsonValueSerializerClass);
begin
  RegisterGenericTypeSerializer(System.TypeInfo(T), ASerializerClass);
end;

class procedure TJsonSerializer.RegisterTypeMemberStrategy<T>(
  AStrategy: TJsonMemberStrategy);
begin
  RegisterTypeMemberStrategy(System.TypeInfo(T), AStrategy);
end;

class procedure TJsonSerializer.RegisterTypeRecursiveReferencePolicy<T>(
  APolicy: TJsonRecursiveReferencePolicy);
begin
  RegisterTypeRecursiveReferencePolicy(System.TypeInfo(T), APolicy);
end;

class function TJsonSerializer.DoFrom(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload; AFrom: TSerializationFormat): string;
begin
  Result := TJsonEngine.FromPayload(ATypeInfo, ASource, AFrom);
end;

class function TJsonSerializer.From(const ASource: string;
  AFrom: TSerializationFormat): string;
begin
  Result := From(TSerializationPayload.FromText(ASource), AFrom);
end;

class function TJsonSerializer.From(const ASource: TBytes;
  AFrom: TSerializationFormat): string;
begin
  Result := From(TSerializationPayload.FromBytes(ASource), AFrom);
end;

class function TJsonSerializer.From(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): string;
begin
  Result := From(ASource, AFrom, TStructuralConversionProfile.Natural);
end;

class function TJsonSerializer.From(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat;
  AProfile: TStructuralConversionProfile): string;
begin
  Result := From(ASource, AFrom, AProfile,
    TJsonUnicodeEscapePolicy.PreserveUnicode);
end;

class function TJsonSerializer.From(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat; AProfile: TStructuralConversionProfile;
  AEscape: TJsonUnicodeEscapePolicy): string;
begin
  Result := TJsonEngine.FromPayloadStructural(ASource, AFrom, AProfile,
    AEscape);
end;

{ ----------------------------------------------------------------- UTF-8 --- }

class function TJsonSerializer.SerializeUtf8<T>(const AInstance: T): TBytes;
begin
  Result := SerializeUtf8<T>(AInstance, TJsonSerializationOptions.Default);
end;

class function TJsonSerializer.SerializeUtf8<T>(const AInstance: T;
  const AOptions: TJsonSerializationOptions): TBytes;
begin
  { One conversion, at the very edge, from the text the engine produced. The
    engine itself never sees a byte. }
  Result := StringToUtf8Bytes(Serialize<T>(AInstance, AOptions));
end;

class function TJsonSerializer.DeserializeUtf8<T>(const AJson: TBytes): T;
begin
  Result := Deserialize<T>(Utf8BytesToString(AJson));
end;

class function TJsonSerializer.From<T>(const ASource: string;
  AFrom: TSerializationFormat): string;
begin
  Result := From<T>(TSerializationPayload.FromText(ASource), AFrom);
end;

class function TJsonSerializer.From<T>(const ASource: TBytes;
  AFrom: TSerializationFormat): string;
begin
  Result := From<T>(TSerializationPayload.FromBytes(ASource), AFrom);
end;

class function TJsonSerializer.From<T>(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): string;
begin
  Result := DoFrom(System.TypeInfo(T), ASource, AFrom);
end;

class procedure TJsonSerializer.DoSetDateTimePolicy(ATypeInfo: PTypeInfo;
  const AFieldName: string; AFormat: TJsonDateTimeFormat;
  const APattern: string);
begin
  TJsonEngine.SetDateTimePolicy(ATypeInfo, AFieldName, Ord(AFormat), APattern);
end;

class procedure TJsonSerializer.SetDateTimeFormat(AFormat: TJsonDateTimeFormat);
begin
  TJsonEngine.SetDateTimePolicy(nil, '', Ord(AFormat), '');
end;

class procedure TJsonSerializer.SetDateTimeFormat(const APattern: string);
begin
  TJsonEngine.SetDateTimePolicy(nil, '', Ord(TJsonDateTimeFormat.Custom),
    APattern);
end;

class procedure TJsonSerializer.RegisterDateTimeFormat<T>(
  AFormat: TJsonDateTimeFormat);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), '', AFormat, '');
end;

class procedure TJsonSerializer.RegisterDateTimeFormat<T>(
  const APattern: string);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), '', TJsonDateTimeFormat.Custom,
    APattern);
end;

class procedure TJsonSerializer.RegisterFieldDateTimeFormat<T>(
  const AFieldName: string; AFormat: TJsonDateTimeFormat);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), AFieldName, AFormat, '');
end;

class procedure TJsonSerializer.RegisterFieldDateTimeFormat<T>(
  const AFieldName, APattern: string);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), AFieldName,
    TJsonDateTimeFormat.Custom, APattern);
end;

class procedure TJsonSerializer.RegisterEnumMapping<T>(
  const AValues: array of string);
begin
  RegisterEnumMapping(System.TypeInfo(T), AValues);
end;

class procedure TJsonSerializer.RegisterClassFactory<T>(
  const AFactory: TJsonClassFactory);
begin
  RegisterClassFactory(System.TypeInfo(T), AFactory);
end;

{ ------------------------------------------------------- plain forwards --- }
class function TJsonSerializer.ToJson(const AInstance: TObject): TJSONObject;
begin
  Result := TJsonEngine.ToJson(AInstance);
end;

class function TJsonSerializer.ToJsonString(const AInstance: TObject): string;
begin
  Result := TJsonEngine.ToJsonString(AInstance);
end;

class procedure TJsonSerializer.Populate(const AInstance: TObject; const AJson: TJSONValue);
begin
  TJsonEngine.Populate(AInstance, AJson);
end;

class procedure TJsonSerializer.Populate(const AInstance: TObject; const AJson: string);
begin
  TJsonEngine.Populate(AInstance, AJson);
end;

class procedure TJsonSerializer.RegisterFieldOverride(AClass: TClass; const AFieldName: string; const AOverride: TJsonFieldOverride);
begin
  TJsonEngine.RegisterFieldOverride(AClass, AFieldName, AOverride);
end;

class procedure TJsonSerializer.RegisterFieldOverride(AOwnerTypeInfo: PTypeInfo; const AFieldName: string; const AOverride: TJsonFieldOverride);
begin
  TJsonEngine.RegisterFieldOverride(AOwnerTypeInfo, AFieldName, AOverride);
end;

class procedure TJsonSerializer.RegisterFieldOverride(const AQualifiedOwnerTypeName, AFieldName: string;
      const AOverride: TJsonFieldOverride);
begin
  TJsonEngine.RegisterFieldOverride(AQualifiedOwnerTypeName, AFieldName, AOverride);
end;

class procedure TJsonSerializer.RegisterClassFieldOverride(AClass: TClass; const AFieldPattern: string; const AOverride: TJsonFieldOverride; AIncludeDescendants: Boolean = False);
begin
  TJsonEngine.RegisterClassFieldOverride(AClass, AFieldPattern, AOverride, AIncludeDescendants);
end;

class procedure TJsonSerializer.RegisterUnitFieldOverride(const AUnitPattern, AFieldPattern: string; const AOverride: TJsonFieldOverride);
begin
  TJsonEngine.RegisterUnitFieldOverride(AUnitPattern, AFieldPattern, AOverride);
end;

class procedure TJsonSerializer.RegisterUnitNaming(const AUnitPattern: string; ANaming: TJsonNaming);
begin
  TJsonEngine.RegisterUnitNaming(AUnitPattern, ANaming);
end;

class procedure TJsonSerializer.RegisterClassNaming(AClass: TClass; ANaming: TJsonNaming; AIncludeDescendants: Boolean = False);
begin
  TJsonEngine.RegisterClassNaming(AClass, ANaming, AIncludeDescendants);
end;

class procedure TJsonSerializer.RegisterClassNaming(const AQualifiedTypeName: string; ANaming: TJsonNaming);
begin
  TJsonEngine.RegisterClassNaming(AQualifiedTypeName, ANaming);
end;

class procedure TJsonSerializer.RegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TJsonValueSerializerClass);
begin
  TJsonEngine.RegisterTypeSerializer(ATypeInfo, ASerializerClass);
end;

class procedure TJsonSerializer.RegisterGenericTypeSerializer(ARepresentativeTypeInfo: PTypeInfo;
      ASerializerClass: TJsonValueSerializerClass);
begin
  TJsonEngine.RegisterGenericTypeSerializer(ARepresentativeTypeInfo, ASerializerClass);
end;

class procedure TJsonSerializer.RegisterClassTypeSerializer(ABaseClass: TClass;
      ASerializerClass: TJsonValueSerializerClass);
begin
  TJsonEngine.RegisterClassTypeSerializer(ABaseClass, ASerializerClass);
end;

class procedure TJsonSerializer.RegisterUnitClassTypeSerializer(const AOwnerUnitPattern: string;
      AValueBaseClass: TClass;
      ASerializerClass: TJsonValueSerializerClass);
begin
  TJsonEngine.RegisterUnitClassTypeSerializer(AOwnerUnitPattern, AValueBaseClass, ASerializerClass);
end;

class procedure TJsonSerializer.RegisterOpaqueClass(ABaseClass: TClass);
begin
  TJsonEngine.RegisterOpaqueClass(ABaseClass);
end;

class procedure TJsonSerializer.RegisterSerializationSurface(ARuntimeClass,
      AContractClass: TClass);
begin
  TJsonEngine.RegisterSerializationSurface(ARuntimeClass, AContractClass);
end;

class procedure TJsonSerializer.SetDefaultMemberStrategy(AStrategy: TJsonMemberStrategy);
begin
  TJsonEngine.SetDefaultMemberStrategy(AStrategy);
end;

class procedure TJsonSerializer.RegisterTypeMemberStrategy(ATypeInfo: PTypeInfo;
      AStrategy: TJsonMemberStrategy);
begin
  TJsonEngine.RegisterTypeMemberStrategy(ATypeInfo, AStrategy);
end;

class procedure TJsonSerializer.SetDefaultRecursiveReferencePolicy(
      APolicy: TJsonRecursiveReferencePolicy);
begin
  TJsonEngine.SetDefaultRecursiveReferencePolicy(APolicy);
end;

class procedure TJsonSerializer.RegisterTypeRecursiveReferencePolicy(ATypeInfo: PTypeInfo;
      APolicy: TJsonRecursiveReferencePolicy);
begin
  TJsonEngine.RegisterTypeRecursiveReferencePolicy(ATypeInfo, APolicy);
end;

class procedure TJsonSerializer.RegisterEnumMapping(ATypeInfo: PTypeInfo; const AValues: array of string);
begin
  TJsonEngine.RegisterEnumMapping(ATypeInfo, AValues);
end;

class procedure TJsonSerializer.RegisterEnumMapping(const AQualifiedTypeName: string; const AValues: array of string);
begin
  TJsonEngine.RegisterEnumMapping(AQualifiedTypeName, AValues);
end;

class procedure TJsonSerializer.RegisterFieldEnumMapping(const AQualifiedOwnerTypeName, AFieldName: string;
      const AValues: array of string);
begin
  TJsonEngine.RegisterFieldEnumMapping(AQualifiedOwnerTypeName, AFieldName, AValues);
end;

class procedure TJsonSerializer.RegisterClassFactory(ATypeInfo: PTypeInfo; const AFactory: TJsonClassFactory);
begin
  TJsonEngine.RegisterClassFactory(ATypeInfo, AFactory);
end;

class procedure TJsonSerializer.RegisterTypeUnit(ATypeInfo: PTypeInfo;
      const AUnitName: string);
begin
  TJsonEngine.RegisterTypeUnit(ATypeInfo, AUnitName);
end;

class function TJsonSerializer.TypeKeyFor(ATypeInfo: PTypeInfo): string;
begin
  Result := TJsonEngine.TypeKeyFor(ATypeInfo);
end;

class procedure TJsonSerializer.FreezeConfiguration;
begin
  TJsonEngine.FreezeConfiguration;
end;

class function TJsonSerializer.IsFrozen: Boolean;
begin
  Result := TJsonEngine.IsFrozen;
end;


{ ---------------------------------------------------------------- dynamic --- }

class function TJsonSerializer.ToDynamic(const AJson: string): TDynamicValue;
begin
  Result := ToDynamic(AJson, TStructuralConversionOptions.Default);
end;

class function TJsonSerializer.ToDynamic(const AJson: string;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
var
  Parsed: TJSONValue;
begin
  Parsed := TJSONObject.ParseJSONValue(AJson);
  if Parsed = nil then
    raise EJsonInputError.Create('Invalid JSON text');
  try
    Result := TJsonEngine.JsonToDynamic(Parsed, AOptions);
  finally
    Parsed.Free;
  end;
end;

class function TJsonSerializer.FromDynamic(AValue: TDynamicValue): string;
begin
  Result := FromDynamic(AValue, TStructuralConversionOptions.Default);
end;

class function TJsonSerializer.FromDynamic(AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): string;
var
  Json: TJSONValue;
begin
  Json := TJsonEngine.DynamicToJson(AValue, AOptions, TStructuralPath.Root);
  try
    { PreserveUnicode: the text is meant to be readable, and the bytes it
      becomes are UTF-8 either way. }
    Result := RenderJson(Json, TJsonUnicodeEscapePolicy.PreserveUnicode);
  finally
    Json.Free;
  end;
end;

end.
