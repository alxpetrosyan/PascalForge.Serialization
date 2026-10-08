{*******************************************************************************
  PascalForge.Json.Internal

  INTERNAL IMPLEMENTATION UNIT - applications should not use this unit directly.

  Implements the JSON engine: cached execution plans, RTTI traversal,
  serializer registration tables and conversion plumbing.
  Exposed through the public facade PascalForge.Json (TJsonSerializer).

  Registration
    Format registration lives in PascalForge.Json.Registration and is explicit.

  Documentation
    docs/formats/json.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Json.Internal;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  INTERNAL. The JSON engine.

  This unit is the implementation behind PascalForge.Json. It holds the cached
  execution plans, the RTTI traversal, the registration tables and the
  conversion plumbing. Application code has no reason to reference it: every
  developer-facing operation is published by TJsonEngine in PascalForge.Json,
  which is a thin facade over TJsonEngine below.

  The only legitimate consumers are the library's own units - notably
  PascalForge.DataSet.Json, which reuses JSON plan decisions so a DataSet and a
  JSON document agree about the same member - and the library's tests.

  Nothing here is a supported API. Signatures, ownership rules and lifetimes
  are implementation detail and may change without notice.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo, System.JSON,
  System.Generics.Collections, System.SyncObjs, System.DateUtils, System.Diagnostics,
  PascalForge.Nullable,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Serialization.Internal,
  PascalForge.Json;

{ ---------------------------------------------------------------------------
  RENDERING JSON TEXT

  Neither of the RTL's two renderings is what this library needs.

    TJSONValue.ToJSON    escapes every non-ASCII character as \uXXXX, so a
                         Georgian name comes out as sixteen escape groups
                         and the document stops being readable.

    TJSONValue.ToString  leaves control characters LITERAL, which is not
                         valid JSON - a raw U+0001 inside a string is
                         forbidden by the grammar, whatever a lenient parser
                         does with it.

  So the text is produced here instead: always valid, escaping exactly what
  JSON requires, and leaving the choice about non-ASCII to the caller.

  A lone surrogate - half of a pair, which a Delphi string can hold and
  UTF-8 cannot encode - is always written as \uXXXX regardless of policy,
  because the alternative is a byte sequence no UTF-8 decoder will accept. }
function RenderJson(AValue: TJSONValue;
  APolicy: TJsonUnicodeEscapePolicy): string;

type
  TJsonKind = (Unsupported, BooleanValue, IntegerValue, Int64Value, FloatValue,
    CurrencyValue, StringValue, GuidValue, DateValue, TimeValue, DateTimeValue,
    EnumValue, SetValue, ObjectValue, RecordValue, ListValue, DictionaryValue,
    NullableValue, CustomSerializer, VariantValue);

  { INTERNAL DIAGNOSTICS.  Opt-in benchmark counters, enabled by setting the
    PASCALFORGE_POPULATE_PROFILE environment variable to 1.  The normal executor
    only tests a boolean guard; no counter or timestamp is touched unless
    profiling is enabled.  Unlike the removed PASCALFORGE_OPT_STAGE switch this
    variable changes measurement only - never serialization semantics. }
  TJsonPopulateProfile = record
    MemberLookups, MemberLookupTicks: Int64;
    ScalarConversions, ScalarConversionTicks: Int64;
    StringConversions, StringConversionTicks: Int64;
    NullableExecutions, NullableTicks: Int64;
    ObjectConstructions, ObjectConstructionTicks: Int64;
    NestedExecutions, NestedTicks: Int64;
    ListExecutions, ListTicks: Int64;
    ListAdds, ListAddTicks: Int64;
    RecordExecutions, RecordTicks: Int64;
    CustomSerializerCalls, CustomSerializerTicks: Int64;
  end;

  { ------------------------------------------------------------------------
    INTERNAL INFRASTRUCTURE.

    TJsonTypePlan, TJsonFieldPlan, TJsonMemberPlan and TJsonKind are the
    cached execution plans of the serializer.  They are declared here only
    because they appear in TJsonEngine's own private method signatures and
    because PascalForge.DataSet.Json consumes a small part of them.  They are not
    a developer-facing API: their fields, ownership rules and lifetimes are
    implementation detail and may change without notice.  Do not construct,
    mutate or retain them from application code.

    Ownership note for TJsonMemberPlan: Inner/Item/Key/Value are owned and
    freed by the destructor; BoundPlan is a borrowed reference into the plan
    cache and must never be freed through a member plan.
    ------------------------------------------------------------------------ }

  TJsonTypePlan = class;

  { Cached RTTI execution metadata for one dictionary shape.  Resolved once
    while the owning plan is built so warm serialization never rediscovers
    the same enumerator methods. }
  TJsonDictAccess = class
  public
    GetEnumeratorMethod: TRttiMethod;
    MoveNextMethod: TRttiMethod;
    CurrentProp: TRttiProperty;
    KeyField: TRttiField;
    ValueField: TRttiField;
    EnumeratorClass: TClass;
    function IsValidFor(ADictClass: TClass): Boolean;
  end;

  { Case-insensitive member index built once per JSON object during
    population, instead of rescanning every pair for every missing member.
    Internal infrastructure; operation-local and never cached. }
  TJsonMemberIndex = class
  strict private
    FMap: TDictionary<string, TJSONValue>;
  public
    constructor Create(const AObj: TJSONObject);
    destructor Destroy; override;
    function TryGet(const AName: string; out AValue: TJSONValue): Boolean;
  end;

  TJsonMemberPlan = class
  public
    Kind: TJsonKind;
    TypeInfo: PTypeInfo;
    Serializer: TCustomJsonValueSerializer;
    NullableAccess: TNullableAccess;
    EnumMapping: TArray<string>;
    SetElemTypeInfo: PTypeInfo;
    SetElemMapping: TArray<string>;
    BoundPlan: TJsonTypePlan;
    ToArrayMethod: TRttiMethod;
    AddMethod: TRttiMethod;
    Inner: TJsonMemberPlan;
    Item: TJsonMemberPlan;
    Key: TJsonMemberPlan;
    Value: TJsonMemberPlan;
    Context: TJsonSerializerContext;
    RuntimePlans: TObjectDictionary<TClass, TJsonTypePlan>;
    DictAccess: TJsonDictAccess;
    { For a list: what Core says appends to it and reads it, so a queue,
      a stack and a TStrings are lists exactly as a TList<T> is. }
    ListAccess: TListAccess;
    { Resolved once, while this plan is built. The warm path never looks a
      date policy up. }
    DateFormat: TJsonDateTimeFormat;
    DatePattern: string;
    destructor Destroy; override;
  end;

  TJsonFieldPlan = class
  public
    FieldName: string;
    DeclaringTypeName: string;
    JsonName: string;
    Field: TRttiField;
    Prop: TRttiProperty;
    IsProperty: Boolean;
    CanRead: Boolean;
    CanWrite: Boolean;
    RecursionPolicy: TJsonRecursiveReferencePolicy;
    Context: TJsonSerializerContext;
    Offset: Integer;
    Kind: TJsonKind;
    FieldTypeInfo: PTypeInfo;
    DirectScalarWrite: Boolean;
    Serializer: TCustomJsonValueSerializer;
    SerializerOnInner: Boolean;
    NullableAccess: TNullableAccess;
    InnerKind: TJsonKind;
    InnerTypeInfo: PTypeInfo;
    EnumMapping: TArray<string>;
    SetElemTypeInfo: PTypeInfo;
    SetElemMapping: TArray<string>;
    { All four resolved once, while this plan is built: the member's own
      kind, a nullable's inner kind, a list element's, a dictionary
      value's. The warm path never looks a policy up. }
    DateFormat: TJsonDateTimeFormat;
    DatePattern: string;
    InnerDateFormat: TJsonDateTimeFormat;
    InnerDatePattern: string;
    ElemDateFormat: TJsonDateTimeFormat;
    ElemDatePattern: string;
    DictValDateFormat: TJsonDateTimeFormat;
    DictValDatePattern: string;
    FieldClass: TClass;
    ChildPlan: TJsonTypePlan;
    ChildPlanClass: TClass;
    ChildPlans: TDictionary<TClass, TJsonTypePlan>;
    ScopedChildPlans: TObjectDictionary<TClass, TJsonTypePlan>;
    HasMemberStrategy: Boolean;
    MemberStrategy: TJsonMemberStrategy;
    HasRecursionPolicy: Boolean;
    ContainerPlan: TJsonTypePlan;
    ElemKind: TJsonKind;
    ElemTypeInfo: PTypeInfo;
    ElemClass: TClass;
    ElemMapping: TArray<string>;
    ElemSerializer: TCustomJsonValueSerializer;
    ElemPlan: TJsonTypePlan;
    ListToArrayMethod: TRttiMethod;
    ListAddMethod: TRttiMethod;
    DictAddMethod: TRttiMethod;
    { Clear is the container-reuse primitive: it asks the container what it
      owns instead of the serializer guessing.  See
      docs\deserialization-ownership.md. }
    ContainerClearMethod: TRttiMethod;
    DictKeyKind: TJsonKind;
    DictKeyTypeInfo: PTypeInfo;
    DictKeyMapping: TArray<string>;
    DictKeySerializer: TCustomJsonValueSerializer;
    DictValKind: TJsonKind;
    DictValTypeInfo: PTypeInfo;
    DictValClass: TClass;
    DictValMapping: TArray<string>;
    DictValSerializer: TCustomJsonValueSerializer;
    ElemMember: TJsonMemberPlan;
    DictKeyMember: TJsonMemberPlan;
    DictValMember: TJsonMemberPlan;
    DictAccess: TJsonDictAccess;
    OwnerUnitName: string;
    { Set for a member that is a value with no container object - a TArray<T>
      or a static array. It is written and read whole, through the member-
      plan path that roots and elements already use, instead of through the
      container path, which needs an object to call Add and ToArray on. }
    WholeMember: TJsonMemberPlan;
    ListAccess: TListAccess;
    destructor Destroy; override;
  end;

  TJsonTypePlan = class
  public
    TypeInfo: PTypeInfo;
    RttiType: TRttiType;
    ClassType: TClass;
    IsRecord: Boolean;
    { Declaring unit and stable name key, resolved through
      PascalForge.Serialization.Core so they are also correct for types declared
      in an implementation section. }
    UnitName: string;
    TypeKey: string;
    ZeroConstructor: TRttiMethod;
    TObjectConstructor: TRttiMethod;
    HasDeclaredConstructor: Boolean;
    MemberStrategy: TJsonMemberStrategy;
    RecursionPolicy: TJsonRecursiveReferencePolicy;
    IsOpaque: Boolean;
    Fields: TObjectList<TJsonFieldPlan>;
    constructor Create;
    destructor Destroy; override;
  end;

  { The engine.  Everything TJsonEngine used to carry, minus the
    developer-facing surface that now lives on the facade. }
  TJsonEngine = class
  strict private
  type
    TScopeKind = (Field, ExactClass, ClassAndDescendants, UnitName, UnitPattern);
    TJsonRule = record
      Scope: TScopeKind;
      TargetTypeInfo: PTypeInfo;
      TargetTypeName: string;
      TargetClass: TClass;
      UnitPattern: string;
      FieldPattern: string;
      Ovr: TJsonFieldOverride;
      Order: Integer;
    end;
    TJsonNamingRule = record
      Scope: TScopeKind;
      TargetClass: TClass;
      TargetTypeName: string;
      UnitPattern: string;
      Naming: TJsonNaming;
      Order: Integer;
    end;
    TJsonContextSerializerRule = record
      OwnerUnitPattern: string;
      ValueBaseClass: TClass;
      SerializerClass: TJsonValueSerializerClass;
      Order: Integer;
    end;
  strict private
    class var FCtx: TRttiContext;
    class var FPlans: TDictionary<PTypeInfo, TJsonTypePlan>;
    class var FRootPlans: TObjectDictionary<PTypeInfo, TJsonMemberPlan>;
    class var FRules: TList<TJsonRule>;
    class var FNamingRules: TList<TJsonNamingRule>;
    class var FContextSerializerRules: TList<TJsonContextSerializerRule>;
    class var FTypeSerializers: TDictionary<PTypeInfo, TJsonValueSerializerClass>;
    class var FGenericTypeSerializers: TDictionary<string, TJsonValueSerializerClass>;
    class var FClassTypeSerializers: TDictionary<TClass, TJsonValueSerializerClass>;
    class var FSerializationSurfaces: TDictionary<TClass, TClass>;
    class var FMemberStrategies: TDictionary<PTypeInfo, TJsonMemberStrategy>;
    class var FRecursionPolicies: TDictionary<PTypeInfo, TJsonRecursiveReferencePolicy>;
    class var FOpaqueClasses: TList<TClass>;
    class var FDefaultMemberStrategy: TJsonMemberStrategy;
    class var FDefaultRecursionPolicy: TJsonRecursiveReferencePolicy;
    class var FEnumMappings: TDictionary<PTypeInfo, TArray<string>>;
    class var FEnumNameMappings: TDictionary<string, TArray<string>>;
    class var FFieldEnumMappings: TDictionary<string, TArray<string>>;
    class var FFactories: TDictionary<PTypeInfo, TJsonClassFactory>;
    class var FSingletons: TObjectDictionary<TClass, TCustomJsonValueSerializer>;
    { Delegate adapters, which have no parameterless constructor and so cannot
      live in FSingletons.  One per registration, created when the descriptor
      is built and owned until teardown. }
    class var FAdopted: TObjectList<TCustomJsonValueSerializer>;
    class var FProfileEnabled: Boolean;
    class var FPopulateProfile: TJsonPopulateProfile;
    class var FLock: TCriticalSection;
    class var FFrozen: Boolean;
    class var FOrder: Integer;
    { Provisional plan-cache entries published by the build currently in
      progress, so a failed build can un-publish all of them. }
    class var FBuildDepth: Integer;
    class var FBuildTrail: TList<PTypeInfo>;
    class var FDatePolicies: TDateTimePolicies;
    class var FTimePolicies: TDateTimePolicies;
    class var FTimestampPolicies: TDateTimePolicies;

    class procedure CheckNotFrozen; static;
    class procedure RollbackBuildTrail; static;
    { AOutputBudget is the operation's estimated-output ceiling in bytes;
      0 - the default and every production call - means unlimited. }
    class procedure BeginSerializationContext(AOutputBudget: Int64 = 0); static;
    class procedure EndSerializationContext; static;
    { The one place that decides between a delegate instance and a class
      singleton, so every plan path treats them identically. }
    class function PickSerializer(ACls: TJsonValueSerializerClass;
      AInstance: TCustomJsonValueSerializer): TCustomJsonValueSerializer; static;
    { Publishes AInstance as THE singleton for ACls, so every existing
      class-keyed lookup path finds a pre-configured instance without knowing
      it was built from closures.  Replaces - and frees - a previous one. }
    class procedure SeedSerializer(ACls: TJsonValueSerializerClass;
      AInstance: TCustomJsonValueSerializer); static;
    class function ResolveSerializer(
      ACls: TJsonValueSerializerClass): TCustomJsonValueSerializer; static;
    class function GenericFamilyKey(ATypeInfo: PTypeInfo; out AKey: string): Boolean; static;
    class function FindRegisteredTypeSerializer(ATypeInfo: PTypeInfo;
      out ASerializerClass: TJsonValueSerializerClass): Boolean; static;
    class function FindContextSerializer(AOwnerTypeInfo, AValueTypeInfo: PTypeInfo;
      out ASerializerClass: TJsonValueSerializerClass): Boolean; static;
    class function UnitOf(ATypeInfo: PTypeInfo; const AUnitHint: string = ''): string; static;
    class function TypeKey(ATypeInfo: PTypeInfo; const AUnitHint: string = ''): string; static;
    class procedure ResolveOverride(AOwner: PTypeInfo; AClass: TClass;
      const AUnit, AOwnerKey, AFieldName: string;
      out AName: string; out ASerializerClass: TJsonValueSerializerClass;
      out ASerializerInstance: TCustomJsonValueSerializer; out AIgnore: Boolean;
      out AHasMemberStrategy: Boolean; out AMemberStrategy: TJsonMemberStrategy;
      out AHasRecursionPolicy: Boolean;
      out ARecursionPolicy: TJsonRecursiveReferencePolicy); static;

    class function GetPlan(ATypeInfo: PTypeInfo;
      const AUnitHint: string = ''): TJsonTypePlan; static;
    class function HasUsableStructuralRtti(AClass: TClass): Boolean; static;
    class function IsCompatibleExisting(AExisting: TObject;
      ADeclaredTypeInfo: PTypeInfo): Boolean; static;
    class procedure ClearContainer(AContainer: TObject;
      AFP: TJsonFieldPlan); static;
    class function SelectClassSurface(ADeclaredTypeInfo: PTypeInfo;
      ARuntimeClass: TClass): PTypeInfo; static;
    class function BuildDictAccess(ADictTypeInfo: PTypeInfo): TJsonDictAccess; static;
    class function ResolveChildPlan(AFieldPlan: TJsonFieldPlan;
      ARuntimeClass: TClass): TJsonTypePlan; static;
    class function ResolveMemberObjectPlan(APlan: TJsonMemberPlan;
      ARuntimeClass: TClass): TJsonTypePlan; static;
    class function BuildPlan(ATypeInfo: PTypeInfo; ACache: Boolean = True;
      AHasMemberStrategy: Boolean = False;
      AMemberStrategy: TJsonMemberStrategy = TJsonMemberStrategy.PublicSurface;
      AHasRecursionPolicy: Boolean = False;
      ARecursionPolicy: TJsonRecursiveReferencePolicy =
        TJsonRecursiveReferencePolicy.WriteNull;
      const AUnitHint: string = ''): TJsonTypePlan; static;
    class procedure BuildFieldPlan(APlan: TJsonTypePlan; AField: TRttiField); static;
    class procedure BuildPropertyPlan(APlan: TJsonTypePlan;
      AProp: TRttiProperty); static;
    class function BuildMemberPlan(ATypeInfo: PTypeInfo): TJsonMemberPlan; static;
    class function GetRootPlan(ATypeInfo: PTypeInfo): TJsonMemberPlan; static;
    class procedure ValidateRootJson(APlan: TJsonMemberPlan;
      const AJson: TJSONValue); static;
    class function ClassifyType(ATypeInfo: PTypeInfo): TJsonKind; static;
    class function IsNullableType(ATypeInfo: PTypeInfo; out AInner: PTypeInfo): Boolean; static;
    class function DatePoliciesFor(AKind: TJsonKind): TDateTimePolicies; static;
    class procedure ResolveDatePolicy(AKind: TJsonKind;
      const AOwnerKey, AFieldName: string; out AFormat: TJsonDateTimeFormat;
      out APattern: string); static;
    class procedure ApplyDatePolicies(APlan: TJsonTypePlan;
      AFP: TJsonFieldPlan;
      const AAttributes: TArray<TCustomAttribute>); static;
    { The resolved access for a type already known to be a nullable. }
    class function NullableAccessFor(ATypeInfo: PTypeInfo): TNullableAccess; static;
    class function DefaultJsonName(const AFieldName: string): string; static;
    { True when JSON itself registered a mapping for the enumeration, by
      type or by qualified name. }
    class function HasRegisteredEnumMapping(ATypeInfo: PTypeInfo): Boolean; static;
    { [SerializationEnum] on a member, applied to its enumeration (or a
      nullable's), unless JSON registered one for that type. A JSON field
      mapping, applied after this, still beats it. }
    class procedure ApplyGeneralEnum(AFP: TJsonFieldPlan;
      AMember: TRttiMember); static;
    class function SnakeCase(const AName: string): string; static;
    class function ResolveNaming(AClass: TClass;
      const AUnit, ATypeKey: string): TJsonNaming; static;
    class function EnumMappingFor(ATypeInfo: PTypeInfo): TArray<string>; static;
    class function FieldEnumMappingFor(const AOwnerKey, AFieldName: string;
      out AValues: TArray<string>): Boolean; static;

    { The date arguments default to the built-in ISO 8601 forms, so every
      call site that has no plan to consult produces exactly what it always
      did. }
    class function ValueToJson(AKind: TJsonKind; ATypeInfo: PTypeInfo; const AValue: TValue; const AMapping: TArray<string>;
      ADateFormat: TJsonDateTimeFormat = TJsonDateTimeFormat.Iso8601;
      const ADatePattern: string = ''): TJSONValue; static;
    class function JsonToValue(AKind: TJsonKind; ATypeInfo: PTypeInfo; const AJson: TJSONValue; const AMapping: TArray<string>;
      ADateFormat: TJsonDateTimeFormat = TJsonDateTimeFormat.Iso8601;
      const ADatePattern: string = ''): TValue; static;
    class function EnumToJson(ATypeInfo: PTypeInfo; AOrdinal: Integer; const AMapping: TArray<string>): TJSONValue; static;
    class function JsonToEnumOrdinal(ATypeInfo: PTypeInfo; const AJson: TJSONValue; const AMapping: TArray<string>): Integer; static;
    class function SetToJson(AElemTypeInfo: PTypeInfo; const AValue: TValue; const AMapping: TArray<string>): TJSONValue; static;
    class function JsonToSet(ASetTypeInfo, AElemTypeInfo: PTypeInfo; const AJson: TJSONValue; const AMapping: TArray<string>): TValue; static;

    class function NewInstanceOf(ATypeInfo: PTypeInfo): TObject; static;
    class function NewInstanceWithPlan(APlan: TJsonTypePlan): TObject; static;

    class function SerializeToObject(ATypeInfo: PTypeInfo; ABase: Pointer;
      const AOptions: TJsonSerializationOptions;
      const AUnitHint: string = ''): TJSONObject; static;
    class function SerializeWithPlan(APlan: TJsonTypePlan; ABase: Pointer; const AOptions: TJsonSerializationOptions): TJSONObject; static;
    class procedure PopulateBase(ATypeInfo: PTypeInfo; ABase: Pointer;
      const AJson: TJSONValue; const AUnitHint: string = ''); static;
    class procedure PopulateWithPlan(APlan: TJsonTypePlan; ABase: Pointer; const AJson: TJSONObject); static;
    class procedure SerializeField(ABase: Pointer; AFP: TJsonFieldPlan; const AResult: TJSONObject; const AOptions: TJsonSerializationOptions); static;
    class procedure DeserializeField(ABase: Pointer; AFP: TJsonFieldPlan;
      const AJsonObj: TJSONObject; AIndex: TJsonMemberIndex); static;
    class procedure RaiseShapeError(AFP: TJsonFieldPlan;
      const AExpected: string; const AJson: TJSONValue); static;
    class function WholeMemberValue(AFP: TJsonFieldPlan;
      const AJson: TJSONValue; AIsNull: Boolean): TValue; static;
    class procedure RequireMemberShape(APlan: TJsonMemberPlan;
      AKind: TJsonKind; const AJson: TJSONValue); static;
    class function JsonShapeName(const AJson: TJSONValue): string; static;
    class procedure NormalizeSetMapping(AFP: TJsonFieldPlan); static;
    { The date arguments default to the built-in ISO 8601 forms, so a call
      site with no plan to consult behaves exactly as it always did. }
    class function ConvertScalarMember(AFP: TJsonFieldPlan; AKind: TJsonKind;
      ATypeInfo: PTypeInfo; const AJson: TJSONValue;
      const AMapping: TArray<string>;
      ADateFormat: TJsonDateTimeFormat = TJsonDateTimeFormat.Iso8601;
      const ADatePattern: string = ''): TValue; static;
    class procedure SetScalarFieldValue(ABase: Pointer; AFP: TJsonFieldPlan; const AValue: TValue); static;
    class function SerializeList(const AList: TObject; AFP: TJsonFieldPlan; const AOptions: TJsonSerializationOptions): TJSONValue; static;
    class procedure DeserializeList(const AList: TObject; AFP: TJsonFieldPlan; const AArr: TJSONArray); static;
    class function SerializeDict(const ADict: TObject; AFP: TJsonFieldPlan; const AOptions: TJsonSerializationOptions): TJSONValue; static;
    class procedure DeserializeDict(const ADict: TObject; AFP: TJsonFieldPlan; const AObj: TJSONObject); static;
    class function SerializeMember(APlan: TJsonMemberPlan; const AValue: TValue; const AOptions: TJsonSerializationOptions): TJSONValue; static;
    class function ToJsonWithOptions(const AInstance: TObject; const AOptions: TJsonSerializationOptions): TJSONObject; static;
    class function DeserializeMember(APlan: TJsonMemberPlan; const AJson: TJSONValue): TValue; static;
  public
    { INFRASTRUCTURE.  The facade publishes the typed half of these; what
      remains here is what only the engine can do. }
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

  public
    class constructor Create;
    class destructor Destroy;

    { The root entry points behind TJsonSerializer's generic operations.
      They exist because a generic method body may reference nothing but
      interface declarations, so the facade cannot inline this itself. }
    class function SerializeRoot(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AOptions: TJsonSerializationOptions): string; static;
    class function DeserializeRoot(ATypeInfo: PTypeInfo;
      const AJson: TJSONValue): TValue; static;
    { Raises when the configuration is frozen.  Public so the facade can
      apply the same freeze to a delegate registration BEFORE it builds
      the adapter. }
    class procedure CheckConfigurationNotFrozen; static;
    { Publishes a pre-built instance as THE singleton for ACls. }
    class procedure PublishSerializer(ACls: TJsonValueSerializerClass;
      AInstance: TCustomJsonValueSerializer); static;

    class function ToJson(const AInstance: TObject): TJSONObject; static;
    class function ToJsonString(const AInstance: TObject): string; static;
    class procedure Populate(const AInstance: TObject; const AJson: TJSONValue); overload; static;
    class procedure Populate(const AInstance: TObject; const AJson: string); overload; static;


    { ----------------------------------------------------------------------
      TryDeserialize - the same deserialization, with selected INPUT failures
      reported as False instead of raising.

        if TJsonEngine.TryDeserialize<TCustomer>(Json, Customer) then ...

      By default only malformed JSON text is handled; add TypeMismatch to
      also absorb valid JSON that the target type cannot represent:

        if not TJsonEngine.TryDeserialize<TCustomer>(Json, Customer, Err,
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
    { AError carries the serializer's own contextual message on a handled
      failure, and '' on success. }

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
    { Compile-time checked: the compiler rejects a serializer that is not a
      TCustomJsonValueSerializer<T>.  Prefer this to the line above.
        TJsonEngine.RegisterTypeSerializer<TMoney, TMoneySerializer>; }
    { No class at all - two functions, named or inline:
        TJsonEngine.RegisterTypeSerializer<TMoney>(
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
    { The third function fills a caller-owned instance in place and returns
      True; returning False - or omitting it - means "build a new one". }
    class procedure RegisterTypeSerializer(ATypeInfo: PTypeInfo;
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
    class procedure SetDefaultRecursiveReferencePolicy(
      APolicy: TJsonRecursiveReferencePolicy); static;
    class procedure RegisterTypeRecursiveReferencePolicy(ATypeInfo: PTypeInfo;
      APolicy: TJsonRecursiveReferencePolicy); overload; static;
    class procedure RegisterEnumMapping(ATypeInfo: PTypeInfo; const AValues: array of string); overload; static;
    class procedure SetDateTimePolicy(ATypeInfo: PTypeInfo;
      const AFieldName: string; AKind: Integer;
      const APattern: string); static;

    { --- cross-format, reached only through the registry ---------------

      JSON is the destination and is known at compile time, so only the
      SOURCE is looked up. This unit therefore has no compile-time
      knowledge that any other format exists. }
    class function FromPayload(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload; AFrom: TSerializationFormat): string; static;
    class function FromPayloadStructural(
      const ASource: TSerializationPayload; AFrom: TSerializationFormat;
      AProfile: TStructuralConversionProfile;
      AEscape: TJsonUnicodeEscapePolicy): string; static;

    { --- the dynamic tree (structural conversion only) --- }

    { Plain JSON, taken entirely at its word: an object is an object, and a
      string is a string however it happens to be spelled. }
    class function JsonToDynamic(AJson: TJSONValue): TDynamicValue; overload; static;
    { The same, except that under Lossless the MongoDB Extended JSON forms
      are recognized for what the standard says they are. Under every other
      profile this is exactly the overload above. }
    class function JsonToDynamic(AJson: TJSONValue;
      const AOptions: TStructuralConversionOptions): TDynamicValue; overload; static;
    class function DynamicToJson(AValue: TDynamicValue): TJSONValue; overload; static;
    class function DynamicToJson(AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions;
      const APath: string): TJSONValue; overload; static;
    class procedure RegisterEnumMapping(const AQualifiedTypeName: string; const AValues: array of string); overload; static;
    class procedure RegisterFieldEnumMapping(const AQualifiedOwnerTypeName, AFieldName: string;
      const AValues: array of string); static;
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

    { ----------------------------------------------------------------------
      Everything below this line is plumbing, kept on the engine because the
      library's own units need it: TryGetFieldJsonName and the
      Convert*/*TypedValue helpers are the PascalForge.DataSet.Json bridge, and
      the profile calls and counters are what the regression tools assert on
      to prove the plan cache is not rebuilt.
      ---------------------------------------------------------------------- }
    class function TryGetFieldJsonName(ATypeInfo: PTypeInfo; const AFieldName: string; out AJsonName: string): Boolean; static;
    class function CreateInstance(ATypeInfo: PTypeInfo): TObject; static;
    class function ConvertMember(AOwnerTypeInfo: PTypeInfo; const AFieldName: string; const AMember: TJSONValue; out AValue: TValue; out AHasValue: Boolean): Boolean; static;
    class function SerializeTypedValue(ATypeInfo: PTypeInfo; const AValue: TValue): TJSONValue; static;
    class function DeserializeTypedValue(ATypeInfo: PTypeInfo; const AJson: TJSONValue): TValue; static;
    class procedure ResetPopulateProfile; static;
    class function GetPopulateProfile: TJsonPopulateProfile; static;
    class function ConvertListElement(AOwnerTypeInfo: PTypeInfo; const AFieldName: string; const AItem: TJSONValue): TValue; static;
    class function ConvertDictKey(AOwnerTypeInfo: PTypeInfo; const AFieldName, AKeyName: string): TValue; static;
    class function ConvertDictValue(AOwnerTypeInfo: PTypeInfo; const AFieldName: string; const AValueJson: TJSONValue): TValue; static;

    { ----------------------------------------------------------------------
      READ-ONLY PLAN INTROSPECTION.

      Three lookups into machinery the serializer already runs, so an external
      analyser can compare a produced payload against what the serializer
      PLANNED to emit instead of re-deriving serialization rules from RTTI.

      They add no behaviour and change no policy.  Each result is a BORROWED
      reference into the plan cache: read it, never mutate or free it.  As with
      everything in this block, the plan structures are implementation detail
      and may change without notice.

      A diagnostic view of a built plan, for answering "why is this member
      being written like that".  Nothing in the serializer depends on it -
      it reads the plan cache and reports, and removing it would change no
      behaviour.
      ---------------------------------------------------------------------- }
    class function InspectTypePlan(ATypeInfo: PTypeInfo;
      const AUnitHint: string = ''): TJsonTypePlan; static;
    { The plan the serializer would use for a value of declared type
      ADeclaredTypeInfo whose runtime class is ARuntimeClass - i.e. after the
      serialization-surface rules have been applied. }
    { Whether a registered type serializer owns the representation of
      ATypeInfo.  A node it owns must not be compared against the default
      member plan - the serializer decides that node's shape. }

    { ----------------------------------------------------------------------
      DESERIALIZATION FAILURE CLASSIFICATION.

      The two primitives behind every Try* entry point, here rather than in
      the implementation section because a generic method declared in an
      interface section may only reference interface-declared symbols - and
      because PascalForge.DataSet.Json shares them, so the JSON and DataSet
      serializers cannot drift into two different error models.
      ---------------------------------------------------------------------- }

    { THE one place malformed JSON text becomes InvalidJson.  ParseJSONValue
      returns nil for most malformed input but raises for some shapes; both
      are normalised here so a Try caller cannot see nil for one malformed
      document and an exception for another.  Only parser and conversion
      exceptions are absorbed - an out-of-memory during parsing still
      propagates. }
    class function TryParseJsonText(const AJson: string;
      out AValue: TJSONValue; out AError: string): Boolean; static;

    { True when E represents an input failure a caller may choose to handle,
      with its category in AKind.  False means E must propagate: it is a
      construction failure, a custom serializer fault, an unsupported target
      type, an internal invariant failure or an unrelated runtime error. }
    class function ClassifyDeserializationError(E: Exception;
      out AKind: TJsonDeserializationError): Boolean; static;

    class var PlansBuilt: Integer;
    class var SingletonsCreated: Integer;
  end;

implementation

uses
  System.StrUtils, System.NetEncoding, System.Math, System.Variants;

{ The plans read and write members through an untyped instance address, and
  an object's address is its reference: the one place that cast is made. }
{$WARN UNSAFE_CAST OFF}
function InstanceAddress(AObject: TObject): Pointer; inline;
begin
  Result := Pointer(AObject);
end;
{$WARN UNSAFE_CAST ON}

{ ===========================================================================
  NUMBERS

  The RTL's JSON number writes a float with fifteen significant digits, so
  1/3 came back as a different Double; Currency went through a Double and
  lost its last digits; and an unsigned integer went out as whatever its
  bits meant signed. Every number now leaves as text that reads back as
  exactly the value it was, and comes back range-checked against the type
  it is going into.

  THE ".0" STAYS. An integral float is written 1.0 rather than 1, as the
  RTL writer always did, so that a value that did round-trip before is
  written exactly as before.
  =========================================================================== }

function MarkFloat(const AText: string): string;
begin
  Result := AText;
  if (Pos('.', Result) = 0) and (Pos('E', Result) = 0) then
    Result := Result + '.0';
end;

function JsonDoubleText(AValue: Double): string;
begin
  Result := MarkFloat(TStructuralText.EncodeFloat(AValue));
end;

function JsonCurrencyText(AValue: Currency): string;
begin
  Result := MarkFloat(CurrToStr(AValue, TFormatSettings.Invariant));
end;

{ JSON has no NaN and no infinity: the RTL wrote them as bare NAN and INF,
  which is not JSON, and the reader then rejected its own writer's output.
  They are refused, by name. }
function JsonFloatText(ATypeInfo: PTypeInfo; const AValue: TValue): string;
var
  D: Double;
begin
  D := AValue.AsExtended;
  if D.IsNan or D.IsInfinity then
    raise EJsonError.CreateFmt(
      'JSON has no number %s, so a %s holding one cannot be written. Give ' +
      'the member a custom serializer that chooses a representation, or ' +
      'keep the value finite.',
      [TStructuralText.EncodeFloat(D), UTF8ToString(ATypeInfo.Name)]);
  if GetTypeData(ATypeInfo).FloatType = ftSingle then
    Result := MarkFloat(TStructuralText.EncodeSingle(AValue.AsExtended))
  else
    Result := JsonDoubleText(D);
end;

{ A Variant through the dynamic tree, which is the one bridge every format
  shares: see TSerializationVariants. Natural profile, so a date is written
  as ISO text - JSON has no date - and reads back as text. }
function VariantToJson(const AValue: Variant): TJSONValue;
var
  N: TDynamicValue;
  Why: string;
begin
  if not TSerializationVariants.TryToDynamic(AValue, N, Why) then
    raise EJsonError.Create('The value ' + Why + '.');
  try
    Result := TJsonEngine.DynamicToJson(N, TStructuralConversionOptions.Default, '$');
  finally
    N.Free;
  end;
end;

function JsonToVariantValue(ATypeInfo: PTypeInfo; AJson: TJSONValue): TValue;
var
  N: TDynamicValue;
  V: Variant;
  OV: OleVariant;
  Why: string;
begin
  N := TJsonEngine.JsonToDynamic(AJson);
  try
    if not TSerializationVariants.TryFromDynamic(N, V, Why) then
      raise EJsonInputError.Create('The JSON value ' + Why + '.');
  finally
    N.Free;
  end;
  { An OleVariant holds OLE types only, and assigning converts the string. }
  if ATypeInfo = System.TypeInfo(OleVariant) then
  begin
    OV := V;
    TValue.Make(@OV, ATypeInfo, Result);
  end
  else
    TValue.Make(@V, ATypeInfo, Result);
end;

function JsonIntegerValue(ATypeInfo: PTypeInfo; const AText: string): TValue;
begin
  if not TSerializationTypes.TryIntegerFromText(ATypeInfo, AText, Result) then
    raise EJsonInputError.CreateFmt('%s is not a %s: it is not an integer, ' +
      'or it is outside the range of the type.',
      [AText, UTF8ToString(ATypeInfo.Name)]);
end;

function JsonFloatValue(ATypeInfo: PTypeInfo; const AText: string): TValue;
var
  D: Double;
  S: Single;
  E: Extended;
begin
  { Correctly rounded, the same on Win32 and Win64: the RTL's TryStrToFloat
    misread 17-digit text on Win64 and refused 1.7976931348623158E308 on
    Win32. JSON has no infinity, so a number past Double's range is still
    not one. }
  if not TStructuralText.TryParseFloat(AText, D) or D.IsNan or D.IsInfinity then
    raise EJsonInputError.CreateFmt('%s is not a number.', [AText]);
  { Converted to the member's own width, which TValue.Make does not do: it
    copies bytes, and the first four bytes of a Double are not a Single. }
  case GetTypeData(ATypeInfo).FloatType of
    ftSingle:
      begin
        if Abs(D) > MaxSingle then
          raise EJsonInputError.CreateFmt('%s does not fit in a Single.',
            [AText]);
        S := D;
        TValue.Make(@S, ATypeInfo, Result);
      end;
    ftExtended:
      begin
        E := D;
        TValue.Make(@E, ATypeInfo, Result);
      end;
  else
    TValue.Make(@D, ATypeInfo, Result);
  end;
end;

{ ===========================================================================
  THE JSON TEXT WRITER
  =========================================================================== }

procedure RenderJsonString(ASB: TStringBuilder; const AText: string;
  APolicy: TJsonUnicodeEscapePolicy);
var
  I, Len, RunStart: Integer;
  C: Char;

  { Characters written as they are accumulate into a run, and the run is
    copied in one Append when an escape interrupts it or the text ends:
    one call per run rather than one per character, which is most of the
    writer's cost on ordinary text. }
  procedure Flush(AUpTo: Integer);
  begin
    if AUpTo > RunStart then
      ASB.Append(AText, RunStart - 1, AUpTo - RunStart);
  end;

  procedure Escape(const AEscape: string);
  begin
    Flush(I);
    ASB.Append(AEscape);
    RunStart := I + 1;
  end;

begin
  ASB.Append('"');
  Len := Length(AText);
  RunStart := 1;
  I := 1;
  while I <= Len do
  begin
    C := AText[I];
    case C of
      '"':  Escape('\"');
      '\':  Escape('\\');
      #8:   Escape('\b');
      #9:   Escape('\t');
      #10:  Escape('\n');
      #12:  Escape('\f');
      #13:  Escape('\r');
    else
      if C < #32 then
        Escape('\u' + IntToHex(Ord(C), 4))
      else if C < #127 then
        { written as it is: part of the run }
      else if APolicy = TJsonUnicodeEscapePolicy.EscapeNonAscii then
        Escape('\u' + IntToHex(Ord(C), 4))
      else
      begin
        { A character above the BMP is TWO code units here and one
          character to the reader, so the pair is written together - the
          high half is not a character on its own and asking whether to
          escape it separately is the wrong question.

          A surrogate with no partner is not a character at all, cannot be
          encoded as UTF-8, and is written as an escape so that the
          document stays parseable rather than becoming invalid bytes. }
        if (C >= #$D800) and (C <= #$DBFF) and (I < Len) and
           (AText[I + 1] >= #$DC00) and (AText[I + 1] <= #$DFFF) then
          Inc(I)  { the pair stays in the run }
        else if (C >= #$D800) and (C <= #$DFFF) then
          Escape('\u' + IntToHex(Ord(C), 4));
        { any other character stays in the run }
      end;
    end;
    Inc(I);
  end;
  Flush(Len + 1);
  ASB.Append('"');
end;

procedure RenderJsonTo(ASB: TStringBuilder; AValue: TJSONValue;
  APolicy: TJsonUnicodeEscapePolicy);
var
  I: Integer;
  Pair: TJSONPair;
begin
  if (AValue = nil) or (AValue is TJSONNull) then
  begin
    ASB.Append('null');
    Exit;
  end;
  { TJSONNumber DESCENDS FROM TJSONString in the RTL, so it has to be tested
    first - the other order quotes every number in the document. }
  if AValue is TJSONNumber then
  begin
    { The number's own text, so an integer stays an integer and a value
      written with a particular precision keeps it. }
    ASB.Append(TJSONNumber(AValue).Value);
    Exit;
  end;
  if AValue is TJSONString then
  begin
    RenderJsonString(ASB, TJSONString(AValue).Value, APolicy);
    Exit;
  end;
  if AValue is TJSONBool then
  begin
    if TJSONBool(AValue).AsBoolean then ASB.Append('true')
    else ASB.Append('false');
    Exit;
  end;
  if AValue is TJSONArray then
  begin
    ASB.Append('[');
    for I := 0 to TJSONArray(AValue).Count - 1 do
    begin
      if I > 0 then ASB.Append(',');
      RenderJsonTo(ASB, TJSONArray(AValue).Items[I], APolicy);
    end;
    ASB.Append(']');
    Exit;
  end;
  if AValue is TJSONObject then
  begin
    ASB.Append('{');
    for I := 0 to TJSONObject(AValue).Count - 1 do
    begin
      if I > 0 then ASB.Append(',');
      Pair := TJSONObject(AValue).Pairs[I];
      RenderJsonString(ASB, Pair.JsonString.Value, APolicy);
      ASB.Append(':');
      RenderJsonTo(ASB, Pair.JsonValue, APolicy);
    end;
    ASB.Append('}');
    Exit;
  end;
  { Nothing else can appear in a document this library built. }
  ASB.Append(AValue.ToJSON);
end;

function RenderJson(AValue: TJSONValue;
  APolicy: TJsonUnicodeEscapePolicy): string;
var
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create(256);
  try
    RenderJsonTo(SB, AValue, APolicy);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

const
  { A class is a list or a dictionary when it IS one of these RTL families
    or DERIVES from one.  Recognition walks the real ancestry, so
    TObjectList<T>, TObjectDictionary<K,V> and any application
    descendant - TOrders = class(TObjectList<TOrder>) - are all covered
    without naming them. }
  LIST_BASE_NAMES: array[0..0] of string = ('TList<');
  DICTIONARY_BASE_NAMES: array[0..0] of string = ('TDictionary<');

threadvar
  GActiveJsonObjects: TDictionary<TObject, Byte>;
  GJsonSerializeDepth: Integer;
  { Operation-local output budget.  0 = unlimited, which is every production
    operation. }
  GJsonOutputBudget: Int64;
  GJsonOutputUsed: Int64;
  { Best-effort location for the diagnostic, updated only while a budget is
    active so an unbudgeted operation pays nothing for it. }
  GJsonBudgetPath: string;

var
  { How many operations, across ALL threads, currently have a budget.  In a
    production process this is permanently zero, and the accounting hot path
    is then a single read of this global - no thread-local lookup, no
    arithmetic.  It is the reason an unlimited operation is unchanged. }
  GBudgetedOperations: Integer = 0;


{ ------------------------------------------------- serialization budget --- }


procedure BeginJsonSerialization(AOutputBudget: Int64 = 0);
begin
  if GJsonSerializeDepth = 0 then
  begin
    GActiveJsonObjects := TDictionary<TObject, Byte>.Create;
    GJsonOutputBudget := AOutputBudget;
    GJsonOutputUsed := 0;
    GJsonBudgetPath := '';
    if AOutputBudget > 0 then
      AtomicIncrement(GBudgetedOperations);
  end;
  Inc(GJsonSerializeDepth);
end;

procedure EndJsonSerialization;
begin
  Dec(GJsonSerializeDepth);
  if GJsonSerializeDepth = 0 then
  begin
    GActiveJsonObjects.Free;
    GActiveJsonObjects := nil;
    if GJsonOutputBudget > 0 then
      AtomicDecrement(GBudgetedOperations);
    GJsonOutputBudget := 0;
    GJsonOutputUsed := 0;
    GJsonBudgetPath := '';
  end;
end;

{ Records where the document is being built, for the abort diagnostic only.
  Never called unless some operation somewhere has a budget. }
procedure NoteJsonBudgetPath(const AOwner, AMember: string);
begin
  if GBudgetedOperations = 0 then Exit;
  if GJsonOutputBudget <= 0 then Exit;
  if AOwner = '' then
    GJsonBudgetPath := AMember
  else
    GJsonBudgetPath := AOwner + '.' + AMember;
end;

procedure RaiseJsonBudget(AEstimated: Int64);
begin
  raise EJsonSerializationLimitExceeded.CreateLimit(GJsonOutputBudget,
    AEstimated, GJsonBudgetPath);
end;

{ The accounting hot path.  Charges an estimated contribution to the output
  and aborts the operation the moment the running total passes the budget -
  while the document is still small, which is the entire point. }
procedure ChargeJsonOutput(ABytes: Integer); inline;
begin
  { Production: one global compare and out. }
  if GBudgetedOperations = 0 then Exit;
  if GJsonOutputBudget <= 0 then Exit;
  Inc(GJsonOutputUsed, ABytes);
  if GJsonOutputUsed > GJsonOutputBudget then
    RaiseJsonBudget(GJsonOutputUsed);
end;

{ Charges a finished scalar node.  TJSONNumber descends from TJSONString in
  System.JSON, so both are measured through Value; the two quotes charged for
  a number are a deliberate over-estimate. }
procedure ChargeJsonValue(AValue: TJSONValue); inline;
begin
  if GBudgetedOperations = 0 then Exit;
  if AValue is TJSONString then
    ChargeJsonOutput(Length(TJSONString(AValue).Value) + 2)
  else
    ChargeJsonOutput(8);
end;

class procedure TJsonEngine.BeginSerializationContext(AOutputBudget: Int64);
begin
  BeginJsonSerialization(AOutputBudget);
end;

class procedure TJsonEngine.EndSerializationContext;
begin
  EndJsonSerialization;
end;

function EnterJsonObject(AObject: TObject;
  APolicy: TJsonRecursiveReferencePolicy): Boolean;
begin
  if AObject = nil then Exit(False);
  if GActiveJsonObjects.ContainsKey(AObject) then
  begin
    if APolicy = TJsonRecursiveReferencePolicy.Error then
      raise EJsonError.CreateFmt('Recursive object reference encountered for %s: ' +
        'the object is already being written further up the graph, and JSON ' +
        'has no back-reference. Break the cycle, or ask for ' +
        'TJsonRecursiveReferencePolicy.WriteNull to write it as null.',
        [AObject.ClassName]);
    Exit(False);
  end;
  { The depth limit every writer shares, counted on the shared level - see
    TSerializationGraphGuard. JSON keeps its own set only for the cycle and
    its recursion policy: an object, a list or a dictionary is one level,
    as a record or an array is (EnterLevel in their branches), so every
    format agrees on what nests too deep. Checked before anything is
    added, so a refusal leaves nothing for LeaveJsonObject to undo. }
  TSerializationGraphGuard.CheckDepth(TSerializationGraphGuard.Level, AObject);
  TSerializationGraphGuard.EnterLevel;
  GActiveJsonObjects.Add(AObject, 0);
  Result := True;
end;

procedure LeaveJsonObject(AObject: TObject);
begin
  if (GActiveJsonObjects <> nil) and (AObject <> nil) and
     GActiveJsonObjects.ContainsKey(AObject) then
  begin
    GActiveJsonObjects.Remove(AObject);
    TSerializationGraphGuard.LeaveLevel;
  end;
end;





function GuidToWire(const G: TGUID): string;
begin
  Result := LowerCase(Copy(G.ToString, 2, 36));
end;

function WireToGuid(const S: string): TGUID;
var
  T: string;
begin
  T := Trim(S);
  if (T <> '') and (T[1] <> '{') then
    T := '{' + T + '}';
  Result := StringToGUID(T);
end;

{ TJsonMemberIndex }

constructor TJsonMemberIndex.Create(const AObj: TJSONObject);
var
  Pair: TJSONPair;
  Key: string;
begin
  inherited Create;
  FMap := TDictionary<string, TJSONValue>.Create(AObj.Count);
  { First writer wins, so an exact-cased duplicate keeps the same pair the
    direct Values[] lookup would have returned. }
  for Pair in AObj do
  begin
    Key := LowerCase(Pair.JsonString.Value);
    if not FMap.ContainsKey(Key) then FMap.Add(Key, Pair.JsonValue);
  end;
end;

destructor TJsonMemberIndex.Destroy;
begin
  FMap.Free;
  inherited;
end;

function TJsonMemberIndex.TryGet(const AName: string;
  out AValue: TJSONValue): Boolean;
begin
  Result := FMap.TryGetValue(LowerCase(AName), AValue);
end;

{ Member lookup.  AHasValue is True for a present non-null member; AIsNull is
  True when the member is present and explicitly JSON null, which callers must
  distinguish from an absent member. }
function TryGetMember(const AObj: TJSONObject; const AName: string;
  out AValue: TJSONValue; AIndex: TJsonMemberIndex;
  out AIsNull: Boolean): Boolean;
begin
  AIsNull := False;
  AValue := AObj.Values[AName];
  { The exact-case hit is preferred; the case-insensitive index is consulted
    only when it misses, which preserves existing precedence. }
  if (AValue = nil) and (AIndex <> nil) then AIndex.TryGet(AName, AValue);
  if AValue = nil then Exit(False);
  AIsNull := AValue is TJSONNull;
  Result := not AIsNull;
end;

function TryUnwrapNullable(const AJson: TJSONValue; out AInner: TJSONValue;
  out AHasValue: Boolean): Boolean;
var HasJson: TJSONValue;
begin
  Result := False;
  AInner := AJson;
  AHasValue := not (AJson is TJSONNull);
  if not (AJson is TJSONObject) then Exit;
  HasJson := TJSONObject(AJson).Values['HasValue'];
  if not (HasJson is TJSONBool) then Exit;
  Result := True;
  AHasValue := TJSONBool(HasJson).AsBoolean;
  AInner := TJSONObject(AJson).Values['Value'];
  if AInner = nil then AHasValue := False;
end;

{ TJsonFieldOverride }








{ TJsonDictAccess }

function TJsonDictAccess.IsValidFor(ADictClass: TClass): Boolean;
begin
  Result := (MoveNextMethod <> nil) and (CurrentProp <> nil) and
    (KeyField <> nil) and (ValueField <> nil) and
    (GetEnumeratorMethod <> nil) and (EnumeratorClass <> nil) and
    (ADictClass <> nil);
end;

{ TJsonTypePlan }

destructor TJsonMemberPlan.Destroy;
begin
  RuntimePlans.Free;
  Inner.Free;
  Item.Free;
  Key.Free;
  Value.Free;
  DictAccess.Free;
  inherited;
end;

destructor TJsonFieldPlan.Destroy;
begin
  ScopedChildPlans.Free;
  ChildPlans.Free;
  ElemMember.Free;
  WholeMember.Free;
  DictKeyMember.Free;
  DictValMember.Free;
  DictAccess.Free;
  inherited;
end;

constructor TJsonTypePlan.Create;
begin
  inherited Create;
  Fields := TObjectList<TJsonFieldPlan>.Create(True);
end;

destructor TJsonTypePlan.Destroy;
begin
  Fields.Free;
  inherited;
end;

{ TJsonEngine }

class function TJsonEngine.SerializeRoot(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AOptions: TJsonSerializationOptions): string;
var
  Plan: TJsonMemberPlan;
  Json: TJSONValue;
  Mark: Integer;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  { The shared level this write started from: a failure deep in it cannot
    leave the next write on the thread starting part way down. }
  Mark := TSerializationGraphGuard.Level;
  BeginSerializationContext(AOptions.MaxOutputBytes);
  try
    Plan := GetRootPlan(ATypeInfo);
    if (Plan.Kind = TJsonKind.ObjectValue) and Plan.BoundPlan.IsOpaque and
       (AValue.AsObject <> nil) then
      raise EJsonError.CreateFmt('Cannot serialize opaque class %s at JSON root',
        [AValue.AsObject.ClassName]);
    Json := SerializeMember(Plan, AValue, AOptions);
    try
      Result := RenderJson(Json, AOptions.UnicodeEscape);
    finally
      Json.Free;
    end;
  finally
    EndSerializationContext;
    TSerializationGraphGuard.RestoreLevel(Mark);
  end;
end;

class function TJsonEngine.DeserializeRoot(ATypeInfo: PTypeInfo;
  const AJson: TJSONValue): TValue;
var
  Plan: TJsonMemberPlan;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  Plan := GetRootPlan(ATypeInfo);
  ValidateRootJson(Plan, AJson);
  Result := DeserializeMember(Plan, AJson);
end;

class procedure TJsonEngine.CheckConfigurationNotFrozen;
begin
  CheckNotFrozen;
end;

class procedure TJsonEngine.PublishSerializer(ACls: TJsonValueSerializerClass;
  AInstance: TCustomJsonValueSerializer);
begin
  SeedSerializer(ACls, AInstance);
end;

class constructor TJsonEngine.Create;
begin
  FCtx := TRttiContext.Create;
  FPlans := TDictionary<PTypeInfo, TJsonTypePlan>.Create;
  FRootPlans := TObjectDictionary<PTypeInfo, TJsonMemberPlan>.Create([doOwnsValues]);
  FRules := TList<TJsonRule>.Create;
  FNamingRules := TList<TJsonNamingRule>.Create;
  FContextSerializerRules := TList<TJsonContextSerializerRule>.Create;
  FTypeSerializers := TDictionary<PTypeInfo, TJsonValueSerializerClass>.Create;
  FGenericTypeSerializers := TDictionary<string, TJsonValueSerializerClass>.Create;
  FClassTypeSerializers := TDictionary<TClass, TJsonValueSerializerClass>.Create;
  FSerializationSurfaces := TDictionary<TClass, TClass>.Create;
  FMemberStrategies := TDictionary<PTypeInfo, TJsonMemberStrategy>.Create;
  FRecursionPolicies := TDictionary<PTypeInfo, TJsonRecursiveReferencePolicy>.Create;
  FOpaqueClasses := TList<TClass>.Create;
  FDefaultMemberStrategy := TJsonMemberStrategy.PublicSurface;
  { Error, not WriteNull: a cycle written as null is a back-reference lost
    without a word, and reading the document back gives a graph that is
    not the one written. A caller who wants the null asks for it. }
  FDefaultRecursionPolicy := TJsonRecursiveReferencePolicy.Error;
  FEnumMappings := TDictionary<PTypeInfo, TArray<string>>.Create;
  FEnumNameMappings := TDictionary<string, TArray<string>>.Create;
  FFieldEnumMappings := TDictionary<string, TArray<string>>.Create;
  FFactories := TDictionary<PTypeInfo, TJsonClassFactory>.Create;
  FSingletons := TObjectDictionary<TClass, TCustomJsonValueSerializer>.Create([doOwnsValues]);
  FAdopted := TObjectList<TCustomJsonValueSerializer>.Create(True);
  FBuildTrail := TList<PTypeInfo>.Create;
  FProfileEnabled := SameText(GetEnvironmentVariable('PASCALFORGE_POPULATE_PROFILE'), '1');
  FPopulateProfile := Default(TJsonPopulateProfile);
  FLock := TCriticalSection.Create;
  { The built-in defaults are exactly what JSON produced before a policy
    mechanism existed, which is why they are constructor arguments rather
    than a hard-coded zero: adding the mechanism moves no output. }
  FDatePolicies := TDateTimePolicies.Create(
    TDateTimePolicy.Make(Ord(TJsonDateTimeFormat.Iso8601)));
  FTimePolicies := TDateTimePolicies.Create(
    TDateTimePolicy.Make(Ord(TJsonDateTimeFormat.Iso8601)));
  FTimestampPolicies := TDateTimePolicies.Create(
    TDateTimePolicy.Make(Ord(TJsonDateTimeFormat.Iso8601)));
end;

class destructor TJsonEngine.Destroy;
var
  P: TJsonTypePlan;
begin
  for P in FPlans.Values do P.Free;
  FPlans.Free;
  FRootPlans.Free;
  FRules.Free;
  FNamingRules.Free;
  FContextSerializerRules.Free;
  FTypeSerializers.Free;
  FGenericTypeSerializers.Free;
  FClassTypeSerializers.Free;
  FSerializationSurfaces.Free;
  FMemberStrategies.Free;
  FRecursionPolicies.Free;
  FOpaqueClasses.Free;
  FEnumMappings.Free;
  FEnumNameMappings.Free;
  FFieldEnumMappings.Free;
  FFactories.Free;
  FAdopted.Free;
  FSingletons.Free;
  FBuildTrail.Free;
  FTimestampPolicies.Free;
  FTimePolicies.Free;
  FDatePolicies.Free;
  FLock.Free;
  FCtx.Free;
end;

class procedure TJsonEngine.CheckNotFrozen;
begin
  if FFrozen then
    raise EJsonError.Create('JSON serializer configuration is frozen.');
end;

class procedure TJsonEngine.RegisterTypeUnit(ATypeInfo: PTypeInfo;
  const AUnitName: string);
begin
  CheckNotFrozen;
  RegisterTypeUnitName(ATypeInfo, AUnitName);
end;

class function TJsonEngine.TypeKeyFor(ATypeInfo: PTypeInfo): string;
begin
  Result := TypeKeyOf(ATypeInfo);
end;

class procedure TJsonEngine.FreezeConfiguration;
begin
  FFrozen := True;
end;

class function TJsonEngine.IsFrozen: Boolean;
begin
  Result := FFrozen;
end;


{ ------------------------------------------------- plan introspection --- }

class function TJsonEngine.InspectTypePlan(ATypeInfo: PTypeInfo;
  const AUnitHint: string): TJsonTypePlan;
begin
  Result := GetPlan(ATypeInfo, AUnitHint);
end;

class function TJsonEngine.TryGetFieldJsonName(ATypeInfo: PTypeInfo; const AFieldName: string; out AJsonName: string): Boolean;
var
  plan: TJsonTypePlan;
  FP: TJsonFieldPlan;
begin
  Result := False;
  plan := GetPlan(ATypeInfo);
  for FP in plan.Fields do
    if SameText(FP.FieldName, AFieldName) then
    begin
      AJsonName := FP.JsonName;
      Exit(True);
    end;
end;

class function TJsonEngine.ConvertMember(AOwnerTypeInfo: PTypeInfo; const AFieldName: string;
  const AMember: TJSONValue; out AValue: TValue; out AHasValue: Boolean): Boolean;
var
  plan: TJsonTypePlan;
  FP, found: TJsonFieldPlan;
begin
  Result := False; AHasValue := False;
  plan := GetPlan(AOwnerTypeInfo);
  found := nil;
  for FP in plan.Fields do
    if SameText(FP.FieldName, AFieldName) then begin found := FP; Break; end;
  if found = nil then Exit;
  if found.Kind in [TJsonKind.ObjectValue, TJsonKind.RecordValue, TJsonKind.ListValue, TJsonKind.DictionaryValue] then Exit; // bridge handles structurally
  Result := True;
  if (AMember = nil) or (AMember is TJSONNull) then Exit;
  case found.Kind of
    TJsonKind.CustomSerializer:
      begin AValue := found.Serializer.DeserializeValue(AMember, found.FieldTypeInfo); AHasValue := True; end;
    TJsonKind.NullableValue:
      begin
        if found.SerializerOnInner then AValue := found.Serializer.DeserializeValue(AMember, found.InnerTypeInfo)
        else AValue := JsonToValue(found.InnerKind, found.InnerTypeInfo,
          AMember, found.EnumMapping, found.InnerDateFormat,
          found.InnerDatePattern);
        AHasValue := True;
      end;
  else
    AValue := JsonToValue(found.Kind, found.FieldTypeInfo, AMember,
      found.EnumMapping, found.DateFormat, found.DatePattern);
    AHasValue := True;
  end;
end;

class function TJsonEngine.SerializeTypedValue(ATypeInfo: PTypeInfo;
  const AValue: TValue): TJSONValue;
var
  C: TJsonValueSerializerClass;
begin
  // This helper deliberately does not perform generic-family matching. Family
  // matching is resolved once while the owning field plan is built.
  if FTypeSerializers.TryGetValue(ATypeInfo, C) then
    Exit(ResolveSerializer(C).SerializeValue(AValue));
  Result := SerializeBuiltIn(ATypeInfo, AValue);
end;

class function TJsonEngine.SerializeBuiltIn(ATypeInfo: PTypeInfo;
  const AValue: TValue): TJSONValue;
var
  K: TJsonKind;
begin
  { What the engine would have produced for ATypeInfo if nothing had been
    registered for it.  No registry is consulted, so a serializer that calls
    this for the direction it does not implement cannot reach itself again. }
  K := ClassifyType(ATypeInfo);
  case K of
    TJsonKind.ObjectValue:
      if AValue.AsObject = nil then Result := TJSONNull.Create
      else Result := ToJson(AValue.AsObject);
    TJsonKind.RecordValue: Result := SerializeToObject(ATypeInfo, AValue.GetReferenceToRawData, TJsonSerializationOptions.Default);
    TJsonKind.EnumValue: Result := ValueToJson(K, ATypeInfo, AValue, EnumMappingFor(ATypeInfo));
    TJsonKind.SetValue: Result := ValueToJson(K, ATypeInfo, AValue, EnumMappingFor(ATypeInfo.TypeData.CompType^));
  else
    Result := ValueToJson(K, ATypeInfo, AValue, nil);
  end;
end;

class function TJsonEngine.DeserializeTypedValue(ATypeInfo: PTypeInfo;
  const AJson: TJSONValue): TValue;
var
  C: TJsonValueSerializerClass;
begin
  if FTypeSerializers.TryGetValue(ATypeInfo, C) then
    Exit(ResolveSerializer(C).DeserializeValue(AJson, ATypeInfo));
  Result := DeserializeBuiltIn(ATypeInfo, AJson);
end;

class function TJsonEngine.DeserializeBuiltIn(ATypeInfo: PTypeInfo;
  const AJson: TJSONValue): TValue;
var
  K: TJsonKind;
  Obj: TObject;
begin
  { The counterpart of SerializeBuiltIn; see the note there. }
  K := ClassifyType(ATypeInfo);
  case K of
    TJsonKind.ObjectValue:
      begin
        if AJson is TJSONNull then Exit(TValue.From<TObject>(nil));
        Obj := NewInstanceOf(ATypeInfo);
        try
          PopulateBase(ATypeInfo, InstanceAddress(Obj), AJson);
        except
          Obj.Free;
          raise;
        end;
        TValue.Make(@Obj, ATypeInfo, Result);
      end;
    TJsonKind.RecordValue:
      begin
        TValue.Make(nil, ATypeInfo, Result);
        try
          PopulateBase(ATypeInfo, Result.GetReferenceToRawData, AJson);
        except
          { A fresh record: what is in it is this read's. }
          TSerializationOwnership.ReleaseBuilt(ATypeInfo, Result, TValue.Empty);
          raise;
        end;
      end;
    TJsonKind.EnumValue: Result := JsonToValue(K, ATypeInfo, AJson, EnumMappingFor(ATypeInfo));
    TJsonKind.SetValue: Result := JsonToValue(K, ATypeInfo, AJson, EnumMappingFor(ATypeInfo.TypeData.CompType^));
  else
    Result := JsonToValue(K, ATypeInfo, AJson, nil);
  end;
end;

{ ------------------------------------------------------- cross-format --- }

class function TJsonEngine.FromPayload(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload; AFrom: TSerializationFormat): string;
var
  V: TValue;
begin
  { Contract-aware: the source reads T by ITS rules, JSON writes T by its
    own. The source format is reached through the registry, so nothing here
    names it. }
  V := TSerializationFormats.Get(AFrom).DeserializeTyped(ATypeInfo, ASource);
  try
    Result := SerializeRoot(ATypeInfo, V, TJsonSerializationOptions.Default);
  finally
    { The intermediate belongs to this call. }
    TSerializationOwnership.Release(ATypeInfo, V);
  end;
end;

{ ------------------------------------------------------ the dynamic tree --- }

{ ---------------------------------------------------------------------------
  MONGODB EXTENDED JSON

  JSON has six types. The dynamic tree has nine basic kinds plus the
  source-native extended ones, so converting a BSON document into JSON runs
  out of JSON somewhere around the first ObjectId.

  There are exactly two honest answers to that, and this unit implements
  both:

    Natural    write the idiomatic JSON - a hex string for an ObjectId, an
               ISO-8601 string for a timestamp, base64 for bytes. A reader
               cannot tell the result from a string that was always a
               string, so it does not round trip, and that is the stated
               bargain.

    Lossless   write MongoDB Extended JSON, which is a PUBLISHED STANDARD
               for exactly this problem, understood by mongosh, by every
               MongoDB driver, and by anything else that has implemented
               it. The result round trips here AND elsewhere.

  There is no third answer where this library invents its own wrapper. A
  destination that Extended JSON does not cover raises instead.

  RECOGNITION IS NOT AUTOMATIC. An object whose only member is "$oid" is
  read back as an ObjectId only under Lossless, because under any other
  profile it is an ordinary object with an ordinary member spelled
  "$oid" - which real documents do contain - and reinterpreting it would be
  the same guess-from-spelling this library refuses everywhere else.
  --------------------------------------------------------------------------- }
const
  EJSON_OID       = '$oid';
  EJSON_DATE      = '$date';
  EJSON_BINARY    = '$binary';
  EJSON_DECIMAL   = '$numberDecimal';
  EJSON_INT       = '$numberInt';
  EJSON_LONG      = '$numberLong';
  EJSON_DOUBLE    = '$numberDouble';
  EJSON_TIMESTAMP = '$timestamp';
  EJSON_REGEX     = '$regularExpression';
  EJSON_CODE      = '$code';
  EJSON_SCOPE     = '$scope';
  EJSON_SYMBOL    = '$symbol';
  EJSON_UNDEFINED = '$undefined';
  EJSON_DBPOINTER = '$dbPointer';
  EJSON_MINKEY    = '$minKey';
  EJSON_MAXKEY    = '$maxKey';
  EJSON_REF       = '$ref';
  EJSON_ID        = '$id';
  { Read, never written: the canonical form of a UUID is $binary. }
  EJSON_UUID      = '$uuid';

{ The Extended JSON $date wrapper carries milliseconds since the Unix epoch,
  and the tree carries a bare TDateTime, so the two have to be converted.

  BOTH DIRECTIONS GO THROUGH CORE, and not through arithmetic written here.
  The obvious spelling - add the quotient of the milliseconds and the
  length of a day to the epoch - loses six seconds on Win64, where Extended
  is a Double and the sum needs more significant digits than one has; and
  its inverse, (AValue - UnixDateDelta) * MSecsPerDay, put every instant
  before 1899-12-30 that has a time of day a day early, because Delphi
  keeps that time in the fraction's absolute value.

  There is a second reason, which would be enough on its own: BSON's own
  reader and writer use the same two functions, so a datetime that travels
  BSON -> Extended JSON -> BSON is converted by the same code in both
  halves and cannot drift between them. }
function MillisToDateTime(AMillis: Int64): TDateTime;
begin
  if not TStructuralText.TryUnixMillisToDateTime(AMillis, Result) then
    raise EJsonInputError.CreateFmt(
      '%d ms is outside the years a TDateTime holds.', [AMillis]);
end;

function DateTimeToMillis(AValue: TDateTime): Int64;
begin
  { False only outside the years 1 to 9999, which no reader here accepts
    back: refused by name rather than written. }
  if not TStructuralText.TryDateTimeToUnixMillis(AValue, Result) then
    TStructuralText.CheckDateTime(AValue);
end;

function ObjectMember(AJson: TJSONValue; const AName: string): TJSONValue;
begin
  Result := nil;
  if not (AJson is TJSONObject) then Exit;
  Result := TJSONObject(AJson).Values[AName];
end;

function MemberText(AJson: TJSONValue; const AName: string;
  out AText: string): Boolean;
var
  V: TJSONValue;
begin
  AText := '';
  V := ObjectMember(AJson, AName);
  { TJSONNumber descends from TJSONString in the RTL, so "is TJSONString"
    would accept a number here. The test is for a value that is a string and
    is not a number. }
  Result := (V <> nil) and (V is TJSONString) and not (V is TJSONNumber);
  if Result then AText := V.Value;
end;

function MemberInt(AJson: TJSONValue; const AName: string;
  out AValue: Int64): Boolean;
var
  V: TJSONValue;
begin
  AValue := 0;
  V := ObjectMember(AJson, AName);
  if V = nil then Exit(False);
  { Extended JSON writes these as JSON numbers in the relaxed forms and as
    quoted digits in the canonical ones; both are accepted. }
  Result := TryStrToInt64(V.Value, AValue);
end;

{ True when AJson is one of the Extended JSON forms, in which case AValue is
  the dynamic value it denotes and the caller owns it.

  The shape test is deliberately tight: the right member names, the right
  member COUNT, and the right member types. An "$oid" whose value is the
  number 5 is not an ObjectId and is not treated as one. }
function TryExtendedJsonToDynamic(AJson: TJSONValue;
  out AValue: TDynamicValue): Boolean; forward;

function ExtendedJsonBinary(AJson: TJSONValue;
  out AValue: TDynamicValue): Boolean;
var
  Inner: TJSONValue;
  B64, Sub: string;
  Bytes, SubBytes: TBytes;
begin
  AValue := nil;
  Inner := ObjectMember(AJson, EJSON_BINARY);
  if not (Inner is TJSONObject) then Exit(False);
  if TJSONObject(Inner).Count <> 2 then Exit(False);
  if not (MemberText(Inner, 'base64', B64) and
          MemberText(Inner, 'subType', Sub)) then Exit(False);
  if not TStructuralText.TryDecodeBinary(B64, Bytes) then Exit(False);
  if not TStructuralText.TryDecodeHex(Sub, SubBytes) then Exit(False);
  if Length(SubBytes) <> 1 then Exit(False);
  if SubBytes[0] = 0 then AValue := TDynamicValue.NewBytes(Bytes)
  else
  begin
    AValue := TDynamicValue.NewObject;
    try
      AValue.AsObject.Adopt('subtype', TDynamicValue.NewInt(SubBytes[0]));
      AValue.AsObject.Adopt('data', TDynamicValue.NewBytes(Bytes));
      AValue := TDynamicValue.NewExtended(TDynamicTag.BinarySubtype, AValue);
    except
      FreeAndNil(AValue);
      raise;
    end;
  end;
  Result := True;
end;

{ "$uuid" is the specification's shorthand for binary subtype 4: a UUID in
  its 36-character hyphenated form, whose hex is in RFC 4122 byte order -
  the order subtype 4 stores. Anything else under "$uuid" is one of the
  specification's parse errors, and is refused rather than read as an
  ordinary object with a member spelled "$uuid", or as a sub-document. }
function ExtendedJsonUuid(AJson: TJSONValue;
  out AValue: TDynamicValue): Boolean;
var
  Inner: TJSONValue;
  Text, Hex: string;
  Bytes: TBytes;
  I: Integer;
  Ok: Boolean;
  Payload: TDynamicValue;
begin
  AValue := nil;
  Ok := MemberText(AJson, EJSON_UUID, Text) and (Length(Text) = 36);
  Hex := '';
  if Ok then
    for I := 1 to 36 do
      if (I = 9) or (I = 14) or (I = 19) or (I = 24) then
        Ok := Ok and (Text[I] = '-')
      else if CharInSet(Text[I], ['0'..'9', 'a'..'f', 'A'..'F']) then
        Hex := Hex + Text[I]
      else
        Ok := False;
  Ok := Ok and TStructuralText.TryDecodeHex(Hex, Bytes) and
    (Length(Bytes) = 16);
  if not Ok then
  begin
    Inner := ObjectMember(AJson, EJSON_UUID);
    raise EJsonInputError.CreateFmt('"%s" holds %s, which is not a UUID: ' +
      'Extended JSON spells one as 36 characters, hex digits grouped ' +
      '8-4-4-4-12 by hyphens.', [EJSON_UUID, Inner.ToJSON]);
  end;
  Payload := TDynamicValue.NewObject;
  try
    Payload.AsObject.Adopt('subtype', TDynamicValue.NewInt(4));
    Payload.AsObject.Adopt('data', TDynamicValue.NewBytes(Bytes));
  except
    Payload.Free;
    raise;
  end;
  AValue := TDynamicValue.NewExtended(TDynamicTag.BinarySubtype, Payload);
  Result := True;
end;

function ExtendedJsonDate(AJson: TJSONValue;
  out AValue: TDynamicValue): Boolean;
var
  Inner: TJSONValue;
  Millis: Int64;
  Text: string;
  DT: TDateTime;
begin
  AValue := nil;
  Inner := ObjectMember(AJson, EJSON_DATE);
  if Inner = nil then Exit(False);
  { Canonical: a "$date" whose value is an object with one member,
    "$numberLong", holding the milliseconds since the epoch as text. }
  if Inner is TJSONObject then
  begin
    if TJSONObject(Inner).Count <> 1 then Exit(False);
    if not MemberText(Inner, EJSON_LONG, Text) then Exit(False);
    if not TryStrToInt64(Text, Millis) then Exit(False);
    AValue := TDynamicValue.NewDateTime(MillisToDateTime(Millis));
    Exit(True);
  end;
  { Relaxed: a "$date" whose value is an ISO-8601 string. The tree holds a
    bare TDateTime, so
    only the offset-free spelling this library itself writes is accepted -
    anything carrying a zone would have to be shifted, and by what is
    exactly the question the tree cannot answer. }
  if (Inner is TJSONString) and not (Inner is TJSONNumber) then
  begin
    if not TStructuralText.TryDecodeDateTime(Inner.Value, DT) then Exit(False);
    AValue := TDynamicValue.NewDateTime(DT);
    Exit(True);
  end;
  Result := False;
end;

function TryExtendedJsonToDynamic(AJson: TJSONValue;
  out AValue: TDynamicValue): Boolean;
var
  Obj: TJSONObject;
  First, Text, Pattern, Options, Ref: string;
  Count: Integer;
  Inner: TJSONValue;
  Seconds, Increment: Int64;
  Bytes: TBytes;
  Dbl: Double;
  Payload: TDynamicValue;

  function Simple(const ATag: string; APayload: TDynamicValue): Boolean;
  begin
    AValue := TDynamicValue.NewExtended(ATag, APayload);
    Result := True;
  end;

begin
  AValue := nil;
  if not (AJson is TJSONObject) then Exit(False);
  Obj := TJSONObject(AJson);
  Count := Obj.Count;
  if Count = 0 then Exit(False);

  { Extended JSON is recognized by its FIRST member, exactly as the
    specification says. An object whose first member is not one of the
    reserved names is an ordinary object, whatever else it contains. }
  First := Obj.Pairs[0].JsonString.Value;
  if (First = '') or (First[1] <> '$') then Exit(False);

  if (First = EJSON_OID) and (Count = 1) then
  begin
    if not MemberText(Obj, EJSON_OID, Text) then Exit(False);
    if Length(Text) <> 24 then Exit(False);
    if not TStructuralText.TryDecodeHex(Text, Bytes) then Exit(False);
    Exit(Simple(TDynamicTag.ObjectId, TDynamicValue.NewStr(LowerCase(Text))));
  end;

  if (First = EJSON_DATE) and (Count = 1) then
    Exit(ExtendedJsonDate(Obj, AValue));

  if (First = EJSON_BINARY) and (Count = 1) then
    Exit(ExtendedJsonBinary(Obj, AValue));

  if (First = EJSON_UUID) and (Count = 1) then
    Exit(ExtendedJsonUuid(Obj, AValue));

  if (First = EJSON_DECIMAL) and (Count = 1) then
  begin
    if not MemberText(Obj, EJSON_DECIMAL, Text) then Exit(False);
    if not TDecimal128.TryFromText(Text, Bytes) then Exit(False);
    Exit(Simple(TDynamicTag.Decimal128, TDynamicValue.NewBytes(Bytes)));
  end;

  { The three number wrappers are not extended kinds - they are JSON's own
    numbers said precisely, and they become the tree's own Int and Float. }
  if ((First = EJSON_INT) or (First = EJSON_LONG)) and (Count = 1) then
  begin
    if not MemberText(Obj, First, Text) then Exit(False);
    if not TryStrToInt64(Text, Seconds) then Exit(False);
    AValue := TDynamicValue.NewInt(Seconds);
    Exit(True);
  end;
  if (First = EJSON_DOUBLE) and (Count = 1) then
  begin
    if not MemberText(Obj, EJSON_DOUBLE, Text) then Exit(False);
    if SameText(Text, 'Infinity') then Dbl := Infinity
    else if SameText(Text, '-Infinity') then Dbl := NegInfinity
    else if SameText(Text, 'NaN') then Dbl := NaN
    else if not TStructuralText.TryParseFloat(Text, Dbl) then
      Exit(False);
    AValue := TDynamicValue.NewFloat(Dbl);
    Exit(True);
  end;

  if (First = EJSON_TIMESTAMP) and (Count = 1) then
  begin
    Inner := ObjectMember(Obj, EJSON_TIMESTAMP);
    if not (Inner is TJSONObject) then Exit(False);
    if TJSONObject(Inner).Count <> 2 then Exit(False);
    if not (MemberInt(Inner, 't', Seconds) and
            MemberInt(Inner, 'i', Increment)) then Exit(False);
    Payload := TDynamicValue.NewObject;
    try
      Payload.AsObject.Adopt('t', TDynamicValue.NewInt(Seconds));
      Payload.AsObject.Adopt('i', TDynamicValue.NewInt(Increment));
    except
      Payload.Free;
      raise;
    end;
    Exit(Simple(TDynamicTag.Timestamp, Payload));
  end;

  if (First = EJSON_REGEX) and (Count = 1) then
  begin
    Inner := ObjectMember(Obj, EJSON_REGEX);
    if not (Inner is TJSONObject) then Exit(False);
    if TJSONObject(Inner).Count <> 2 then Exit(False);
    if not (MemberText(Inner, 'pattern', Pattern) and
            MemberText(Inner, 'options', Options)) then Exit(False);
    Payload := TDynamicValue.NewObject;
    try
      Payload.AsObject.Adopt('pattern', TDynamicValue.NewStr(Pattern));
      Payload.AsObject.Adopt('options', TDynamicValue.NewStr(Options));
    except
      Payload.Free;
      raise;
    end;
    Exit(Simple(TDynamicTag.Regex, Payload));
  end;

  if First = EJSON_CODE then
  begin
    if not MemberText(Obj, EJSON_CODE, Text) then Exit(False);
    if Count = 1 then
      Exit(Simple(TDynamicTag.JavaScript, TDynamicValue.NewStr(Text)));
    if Count <> 2 then Exit(False);
    Inner := ObjectMember(Obj, EJSON_SCOPE);
    if not (Inner is TJSONObject) then Exit(False);
    Payload := TDynamicValue.NewObject;
    try
      Payload.AsObject.Adopt('code', TDynamicValue.NewStr(Text));
      Payload.AsObject.Adopt('scope', TJsonEngine.JsonToDynamic(Inner));
    except
      Payload.Free;
      raise;
    end;
    Exit(Simple(TDynamicTag.JavaScriptScope, Payload));
  end;

  if (First = EJSON_SYMBOL) and (Count = 1) then
  begin
    if not MemberText(Obj, EJSON_SYMBOL, Text) then Exit(False);
    Exit(Simple(TDynamicTag.Symbol, TDynamicValue.NewStr(Text)));
  end;

  if (First = EJSON_UNDEFINED) and (Count = 1) then
  begin
    Inner := ObjectMember(Obj, EJSON_UNDEFINED);
    if not ((Inner is TJSONBool) and TJSONBool(Inner).AsBoolean) then Exit(False);
    Exit(Simple(TDynamicTag.Undefined, nil));
  end;

  if ((First = EJSON_MINKEY) or (First = EJSON_MAXKEY)) and (Count = 1) then
  begin
    if not MemberInt(Obj, First, Seconds) then Exit(False);
    if Seconds <> 1 then Exit(False);
    if First = EJSON_MINKEY then Exit(Simple(TDynamicTag.MinKey, nil));
    Exit(Simple(TDynamicTag.MaxKey, nil));
  end;

  if (First = EJSON_DBPOINTER) and (Count = 1) then
  begin
    Inner := ObjectMember(Obj, EJSON_DBPOINTER);
    if not (Inner is TJSONObject) then Exit(False);
    if TJSONObject(Inner).Count <> 2 then Exit(False);
    if not MemberText(Inner, EJSON_REF, Ref) then Exit(False);
    if not MemberText(ObjectMember(Inner, EJSON_ID), EJSON_OID, Text) then
      Exit(False);
    if Length(Text) <> 24 then Exit(False);
    if not TStructuralText.TryDecodeHex(Text, Bytes) then Exit(False);
    Payload := TDynamicValue.NewObject;
    try
      Payload.AsObject.Adopt('namespace', TDynamicValue.NewStr(Ref));
      Payload.AsObject.Adopt('id', TDynamicValue.NewStr(LowerCase(Text)));
    except
      Payload.Free;
      raise;
    end;
    Exit(Simple(TDynamicTag.DbPointer, Payload));
  end;

  Result := False;
end;

class function TJsonEngine.FromPayloadStructural(
  const ASource: TSerializationPayload; AFrom: TSerializationFormat;
  AProfile: TStructuralConversionProfile;
  AEscape: TJsonUnicodeEscapePolicy): string;
var
  Tree: TDynamicValue;
  Json: TJSONValue;
  Options: TStructuralConversionOptions;
begin
  Options := TStructuralConversionOptions.FromProfile(AProfile).WithSource(AFrom)
    .WithDestination(TSerializationFormat.Json);
  Tree := TSerializationFormats.Require(AFrom,
    TSerializationFormatCapability.StructuralParse).ToDynamic(ASource, Options);
  try
    Json := DynamicToJson(Tree, Options, TStructuralPath.Root);
    try
      Result := RenderJson(Json, AEscape);
    finally
      Json.Free;
    end;
  finally
    Tree.Free;
  end;
end;

class function TJsonEngine.JsonToDynamic(AJson: TJSONValue): TDynamicValue;
var
  I: Integer;
  I64: Int64;
  U64: UInt64;
  Dbl: Double;
begin
  if (AJson = nil) or (AJson is TJSONNull) then Exit(TDynamicValue.NewNull);

  if AJson is TJSONObject then
  begin
    Result := TDynamicValue.NewObject;
    try
      { Member names go in exactly as the document spelled them. There is
        nothing reserved to collide with and nothing to unescape: a member
        called "$oid", "$type" or "_x0024_type" is a member with that
        name. }
      for I := 0 to TJSONObject(AJson).Count - 1 do
        Result.AsObject.Adopt(TJSONObject(AJson).Pairs[I].JsonString.Value,
          JsonToDynamic(TJSONObject(AJson).Pairs[I].JsonValue));
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  if AJson is TJSONArray then
  begin
    Result := TDynamicValue.NewArray;
    try
      for I := 0 to TJSONArray(AJson).Count - 1 do
        Result.AsArray.Adopt(JsonToDynamic(TJSONArray(AJson).Items[I]));
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  if AJson is TJSONBool then
    Exit(TDynamicValue.NewBool(TJSONBool(AJson).AsBoolean));

  if AJson is TJSONNumber then
  begin
    { An integral number stays integral: round-tripping 1 as 1.0 would be a
      visible change for every format that tells them apart. }
    if TryStrToInt64(AJson.Value, I64) then Exit(TDynamicValue.NewInt(I64));
    { Past High(Int64) but still an integer: unsigned, not a Double - which
      would round 18446744073709551615 to 1.8446744073709552E19. }
    if TryStrToUInt64(AJson.Value, U64) then Exit(TDynamicValue.NewUInt(U64));
    { Correctly rounded: AsDouble is the RTL's StrToFloat, which misreads
      17-digit text on Win64. A number past Double's range is left to it,
      as before. }
    if TStructuralText.TryParseFloat(AJson.Value, Dbl) and
       not Dbl.IsInfinity then
      Exit(TDynamicValue.NewFloat(Dbl));
    Exit(TDynamicValue.NewFloat(TJSONNumber(AJson).AsDouble));
  end;

  { A JSON string stays a string. It is NOT inspected to see whether it looks
    like a date: JSON does not say that it is one, and guessing from the
    spelling is how "2026-03-14" becomes a timestamp in one system and text
    in the next. }
  Result := TDynamicValue.NewStr(AJson.Value);
end;

class function TJsonEngine.JsonToDynamic(AJson: TJSONValue;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
var
  I: Integer;
begin
  { TWO conditions, and both of them matter.

    Lossless, because under any other profile an object whose only member is
    "$oid" is an object whose only member is "$oid".

    And a BSON destination, because Extended JSON is JSON that MEANS BSON.
    Reading it as BSON types is right when BSON is where it is going and
    wrong everywhere else: on the way to XML it would turn a perfectly
    convertible object into a binary the W3C mapping cannot carry, and the
    conversion would fail for a document that had nothing wrong with it. }
  if (AOptions.ValuePolicy <> TStructuralValuePolicy.Lossless) or
     not AOptions.DestinationIs(TSerializationFormat.Bson) then
    Exit(JsonToDynamic(AJson));

  if AJson is TJSONObject then
  begin
    { An Extended JSON value is that value and not an object, so this is
      asked BEFORE the object is built. }
    if TryExtendedJsonToDynamic(AJson, Result) then Exit;
    Result := TDynamicValue.NewObject;
    try
      for I := 0 to TJSONObject(AJson).Count - 1 do
        Result.AsObject.Adopt(TJSONObject(AJson).Pairs[I].JsonString.Value,
          JsonToDynamic(TJSONObject(AJson).Pairs[I].JsonValue, AOptions));
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  if AJson is TJSONArray then
  begin
    Result := TDynamicValue.NewArray;
    try
      for I := 0 to TJSONArray(AJson).Count - 1 do
        Result.AsArray.Adopt(JsonToDynamic(TJSONArray(AJson).Items[I], AOptions));
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  Result := JsonToDynamic(AJson);
end;

class function TJsonEngine.DynamicToJson(AValue: TDynamicValue): TJSONValue;
begin
  Result := DynamicToJson(AValue, TStructuralConversionOptions.Default,
    TStructuralPath.Root);
end;

{ JSON's type system is the dynamic tree's, minus binary, minus timestamps
  and minus every source-native extended kind. Those are where a policy is
  needed; everything else is written directly, and no member name is ever a
  problem because a JSON member name is any string at all. }
class function TJsonEngine.DynamicToJson(AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions;
  const APath: string): TJSONValue;
var
  I: Integer;
  Text: string;
  Payload: TDynamicValue;

  { One reserved name and one value: the shape most Extended JSON forms
    take. }
  function Ext(const AName: string; AInner: TJSONValue): TJSONValue;
  var
    Obj: TJSONObject;
  begin
    Obj := TJSONObject.Create;
    try
      Obj.AddPair(AName, AInner);
    except
      Obj.Free;
      AInner.Free;
      raise;
    end;
    Result := Obj;
  end;

  function ExtText(const AName, AText: string): TJSONValue;
  begin
    Result := Ext(AName, TJSONString.Create(AText));
  end;

  procedure Refuse(const AWhat: string);
  begin
    raise EStructuralConversionError.CreateFor(
      TStructuralIssue.UnsupportedValueKind, AOptions,
      TSerializationFormat.Json, APath, AValue.Kind,
      Format('JSON has no %s. The Natural profile writes the idiomatic ' +
        'text form and the Lossless profile writes MongoDB Extended JSON',
        [AWhat]));
  end;

  procedure NoStandard(const AWhat: string);
  begin
    raise EStructuralConversionError.CreateFor(
      TStructuralIssue.UnsupportedLosslessConversion, AOptions,
      TSerializationFormat.Json, APath, AValue.Kind,
      Format('no published JSON representation covers %s', [AWhat]));
  end;

  { The part of the payload a tag promised, or nil. }
  function Part(const AName: string): TDynamicValue;
  begin
    Result := nil;
    if (Payload = nil) or (Payload.Kind <> TDynamicKind.Obj) then Exit;
    Result := Payload.Find(AName);
  end;

  function PartText(const AName: string): string;
  var
    V: TDynamicValue;
  begin
    V := Part(AName);
    if V = nil then Exit('');
    Result := V.AsStr;
  end;

  function PartInt(const AName: string): Int64;
  var
    V: TDynamicValue;
  begin
    V := Part(AName);
    if V = nil then Exit(0);
    Result := V.AsInt;
  end;

  { A tagged value under Natural: the idiomatic JSON a reader expects, with
    no claim that it was ever anything else. }
  function NaturalExtended: TJSONValue;
  var
    Inner: TJSONObject;
    Data: TDynamicValue;
  begin
    if AValue.IsTagged(TDynamicTag.ObjectId) or
       AValue.IsTagged(TDynamicTag.Symbol) or
       AValue.IsTagged(TDynamicTag.JavaScript) then
      Exit(TJSONString.Create(Payload.AsStr));
    if AValue.IsTagged(TDynamicTag.Undefined) or
       AValue.IsTagged(TDynamicTag.MinKey) or
       AValue.IsTagged(TDynamicTag.MaxKey) then
      Exit(TJSONNull.Create);
    if AValue.IsTagged(TDynamicTag.Decimal128) then
    begin
      if not TDecimal128.TryToText(Payload.AsBytes, Text) then
        Text := TStructuralText.EncodeHex(Payload.AsBytes);
      Exit(TJSONString.Create(Text));
    end;
    if AValue.IsTagged(TDynamicTag.Timestamp) then
      { As TEXT, not as a number: a BSON timestamp is a full 64-bit unsigned
        value and JSON numbers cannot carry one exactly. }
      Exit(TJSONString.Create(UIntToStr(
        (UInt64(PartInt('t')) shl 32) or
        (UInt64(PartInt('i')) and UInt64($FFFFFFFF)))));
    if AValue.IsTagged(TDynamicTag.BinarySubtype) then
    begin
      Data := Part('data');
      if Data = nil then Exit(TJSONNull.Create);
      Exit(TJSONString.Create(TStructuralText.EncodeBinary(Data.AsBytes)));
    end;
    if AValue.IsTagged(TDynamicTag.Regex) then
    begin
      Inner := TJSONObject.Create;
      try
        Inner.AddPair('pattern', PartText('pattern'));
        Inner.AddPair('options', PartText('options'));
      except
        Inner.Free;
        raise;
      end;
      Exit(Inner);
    end;
    if AValue.IsTagged(TDynamicTag.DbPointer) then
    begin
      Inner := TJSONObject.Create;
      try
        Inner.AddPair('namespace', PartText('namespace'));
        Inner.AddPair('id', PartText('id'));
      except
        Inner.Free;
        raise;
      end;
      Exit(Inner);
    end;
    if AValue.IsTagged(TDynamicTag.JavaScriptScope) then
    begin
      Inner := TJSONObject.Create;
      try
        Inner.AddPair('code', PartText('code'));
        Inner.AddPair('scope', DynamicToJson(Part('scope'), AOptions,
          TStructuralPath.Member(APath, 'scope')));
      except
        Inner.Free;
        raise;
      end;
      Exit(Inner);
    end;
    Refuse('representation for ' + AValue.ExtendedTag);
    Result := nil;
  end;

  { The same value under Lossless: the MongoDB Extended JSON canonical form,
    which is somebody else's standard and reads back anywhere. }
  function LosslessExtended: TJSONValue;
  var
    Inner, IdObj: TJSONObject;
  begin
    if AValue.IsTagged(TDynamicTag.ObjectId) then
      Exit(ExtText(EJSON_OID, Payload.AsStr));
    if AValue.IsTagged(TDynamicTag.Symbol) then
      Exit(ExtText(EJSON_SYMBOL, Payload.AsStr));
    if AValue.IsTagged(TDynamicTag.JavaScript) then
      Exit(ExtText(EJSON_CODE, Payload.AsStr));
    if AValue.IsTagged(TDynamicTag.Undefined) then
      Exit(Ext(EJSON_UNDEFINED, TJSONBool.Create(True)));
    if AValue.IsTagged(TDynamicTag.MinKey) then
      Exit(Ext(EJSON_MINKEY, TJSONNumber.Create(1)));
    if AValue.IsTagged(TDynamicTag.MaxKey) then
      Exit(Ext(EJSON_MAXKEY, TJSONNumber.Create(1)));
    if AValue.IsTagged(TDynamicTag.Decimal128) then
    begin
      if not TDecimal128.TryToText(Payload.AsBytes, Text) then
        NoStandard('a decimal128 whose sixteen bytes are not a decimal128');
      Exit(ExtText(EJSON_DECIMAL, Text));
    end;
    if AValue.IsTagged(TDynamicTag.Timestamp) then
    begin
      Inner := TJSONObject.Create;
      try
        Inner.AddPair('t', TJSONNumber.Create(PartInt('t')));
        Inner.AddPair('i', TJSONNumber.Create(PartInt('i')));
      except
        Inner.Free;
        raise;
      end;
      Exit(Ext(EJSON_TIMESTAMP, Inner));
    end;
    if AValue.IsTagged(TDynamicTag.Regex) then
    begin
      Inner := TJSONObject.Create;
      try
        Inner.AddPair('pattern', PartText('pattern'));
        Inner.AddPair('options', PartText('options'));
      except
        Inner.Free;
        raise;
      end;
      Exit(Ext(EJSON_REGEX, Inner));
    end;
    if AValue.IsTagged(TDynamicTag.BinarySubtype) then
    begin
      Inner := TJSONObject.Create;
      try
        Inner.AddPair('base64',
          TStructuralText.EncodeBinary(Part('data').AsBytes));
        Inner.AddPair('subType',
          TStructuralText.EncodeHex(TBytes.Create(Byte(PartInt('subtype')))));
      except
        Inner.Free;
        raise;
      end;
      Exit(Ext(EJSON_BINARY, Inner));
    end;
    if AValue.IsTagged(TDynamicTag.DbPointer) then
    begin
      Inner := TJSONObject.Create;
      try
        Inner.AddPair(EJSON_REF, PartText('namespace'));
        IdObj := TJSONObject.Create;
        Inner.AddPair(EJSON_ID, IdObj);
        IdObj.AddPair(EJSON_OID, PartText('id'));
      except
        Inner.Free;
        raise;
      end;
      Exit(Ext(EJSON_DBPOINTER, Inner));
    end;
    if AValue.IsTagged(TDynamicTag.JavaScriptScope) then
    begin
      Inner := TJSONObject.Create;
      try
        Inner.AddPair(EJSON_CODE, PartText('code'));
        Inner.AddPair(EJSON_SCOPE, DynamicToJson(Part('scope'), AOptions,
          TStructuralPath.Member(APath, 'scope')));
      except
        Inner.Free;
        raise;
      end;
      Exit(Inner);
    end;
    NoStandard(AValue.ExtendedTag);
    Result := nil;
  end;

begin
  case AValue.Kind of
    TDynamicKind.Null:  Exit(TJSONNull.Create);
    TDynamicKind.Bool:  Exit(TJSONBool.Create(AValue.AsBool));
    TDynamicKind.Int:   Exit(TJSONNumber.Create(AValue.AsInt));
    { JSON numbers have no width, so an unsigned value above High(Int64) is
      written as digits rather than lost. A consumer whose numbers are IEEE
      doubles will round it, which is JSON's problem and not a reason to
      write something false here. }
    TDynamicKind.UInt:  Exit(TJSONNumber.Create(UIntToStr(AValue.AsUInt)));
    TDynamicKind.Decimal: Exit(TJSONNumber.Create(AValue.AsDecimal));
    TDynamicKind.Float:
      begin
        { JSON has no NaN and no infinity. Extended JSON does, and Lossless
          writes it; nothing else may write NULL for one, or a bare token
          that is not JSON at all. }
        if AValue.AsFloat.IsNan or AValue.AsFloat.IsInfinity then
        begin
          if AOptions.ValuePolicy = TStructuralValuePolicy.Lossless then
            Exit(Ext(EJSON_DOUBLE, TJSONString.Create(
              TStructuralText.EncodeFloat(AValue.AsFloat))));
          raise EStructuralConversionError.CreateFor(
            TStructuralIssue.UnsupportedValueKind, AOptions,
            TSerializationFormat.Json, APath, AValue.Kind,
            Format('JSON has no number %s. The Lossless profile writes it as ' +
              'Extended JSON {"$numberDouble": "%0:s"}',
              [TStructuralText.EncodeFloat(AValue.AsFloat)]));
        end;
        Exit(TJSONNumber.Create(JsonDoubleText(AValue.AsFloat)));
      end;
    { A string stays a string. Text that looks like XML, like JSON, like
      base64 or like a date is written as a JSON string and nothing else. }
    TDynamicKind.Str:   Exit(TJSONString.Create(AValue.AsStr));
    TDynamicKind.Bytes:
      begin
        if AOptions.ValuePolicy = TStructuralValuePolicy.Error then
          Refuse('binary type');
        if AOptions.ValuePolicy = TStructuralValuePolicy.Lossless then
        begin
          Result := TJSONObject.Create;
          try
            TJSONObject(Result).AddPair('base64',
              TStructuralText.EncodeBinary(AValue.AsBytes));
            TJSONObject(Result).AddPair('subType', '00');
          except
            Result.Free;
            raise;
          end;
          Exit(Ext(EJSON_BINARY, Result));
        end;
        { Base64 is the convention, and it is applied here rather than
          pretended away. }
        Exit(TJSONString.Create(
          TStructuralText.EncodeBinary(AValue.AsBytes)));
      end;
    TDynamicKind.DateTime:
      begin
        if AOptions.ValuePolicy = TStructuralValuePolicy.Error then
          Refuse('timestamp type');
        if AOptions.ValuePolicy = TStructuralValuePolicy.Lossless then
          Exit(Ext(EJSON_DATE, ExtText(EJSON_LONG,
            IntToStr(DateTimeToMillis(AValue.AsDateTime)))));
        Exit(TJSONString.Create(
          TStructuralText.EncodeDateTime(AValue.AsDateTime)));
      end;
    { A CALENDAR DAY AND A TIME OF DAY HAVE NO EXTENDED JSON FORM.

      Extended JSON defines $date and nothing else temporal, so there is no
      published JSON representation that a reader could tell from a string.
      Natural writes the ISO reduced form, which is what a JSON consumer
      expects to see and is documented not to round trip; Lossless refuses
      rather than inventing a representation, which is the same rule that
      governs decimal128 into XML. }
    TDynamicKind.Date, TDynamicKind.Time:
      begin
        if AOptions.ValuePolicy = TStructuralValuePolicy.Error then
          Refuse('date or time type');
        if AOptions.ValuePolicy = TStructuralValuePolicy.Lossless then
          raise EStructuralConversionError.CreateFor(
            TStructuralIssue.UnsupportedLosslessConversion, AOptions,
            TSerializationFormat.Json, APath, AValue.Kind,
            'Extended JSON has $date for an instant and no form at all for ' +
            'a date without a time or a time without a date. Natural writes ' +
            'the ISO reduced form as a string, which reads back as a string');
        if AValue.Kind = TDynamicKind.Date then
          Exit(TJSONString.Create(
            TStructuralText.EncodeDate(AValue.AsDateTime)));
        Exit(TJSONString.Create(TStructuralText.EncodeTime(AValue.AsDateTime)));
      end;
    TDynamicKind.Extended:
      begin
        Payload := AValue.ExtendedValue;
        if AOptions.ValuePolicy = TStructuralValuePolicy.Error then
          Refuse(AValue.ExtendedTag);
        if AOptions.ValuePolicy = TStructuralValuePolicy.Lossless then
          Exit(LosslessExtended);
        Exit(NaturalExtended);
      end;
    TDynamicKind.Arr:
      begin
        Result := TJSONArray.Create;
        try
          for I := 0 to AValue.Count - 1 do
            TJSONArray(Result).AddElement(DynamicToJson(AValue[I], AOptions,
              TStructuralPath.Index(APath, I)));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;
  end;

  Result := TJSONObject.Create;
  try
    { Every member name is written exactly as the tree spelled it. JSON can
      spell any of them, so there is nothing to encode, nothing to escape
      and nothing to reserve. }
    for I := 0 to AValue.Count - 1 do
      TJSONObject(Result).AddPair(AValue.Names[I],
        DynamicToJson(AValue[I], AOptions,
          TStructuralPath.Member(APath, AValue.Names[I])));
  except
    Result.Free;
    raise;
  end;
end;

class procedure TJsonEngine.ResetPopulateProfile;
begin
  FPopulateProfile := Default(TJsonPopulateProfile);
end;

class function TJsonEngine.GetPopulateProfile: TJsonPopulateProfile;
begin
  Result := FPopulateProfile;
end;

function FindFieldPlan(APlan: TJsonTypePlan; const AFieldName: string): TJsonFieldPlan;
begin
  for Result in APlan.Fields do
    if SameText(Result.FieldName, AFieldName) then Exit;
  Result := nil;
end;

class function TJsonEngine.ConvertListElement(AOwnerTypeInfo: PTypeInfo; const AFieldName: string; const AItem: TJSONValue): TValue;
var
  FP: TJsonFieldPlan;
begin
  FP := FindFieldPlan(GetPlan(AOwnerTypeInfo), AFieldName);
  if (FP <> nil) and (FP.ElemSerializer <> nil) then
    Result := FP.ElemSerializer.DeserializeValue(AItem, FP.ElemTypeInfo)
  else if FP <> nil then
    Result := JsonToValue(FP.ElemKind, FP.ElemTypeInfo, AItem, FP.ElemMapping,
      FP.ElemDateFormat, FP.ElemDatePattern)
  else
    Result := TValue.Empty;
end;

class function TJsonEngine.ConvertDictKey(AOwnerTypeInfo: PTypeInfo; const AFieldName, AKeyName: string): TValue;
var
  FP: TJsonFieldPlan;
  ks: TJSONString;
begin
  FP := FindFieldPlan(GetPlan(AOwnerTypeInfo), AFieldName);
  if FP = nil then Exit(TValue.Empty);
  ks := TJSONString.Create(AKeyName);
  try
    if FP.DictKeySerializer <> nil then Result := FP.DictKeySerializer.DeserializeValue(ks, FP.DictKeyTypeInfo)
    else Result := JsonToValue(FP.DictKeyKind, FP.DictKeyTypeInfo, ks, FP.DictKeyMapping);
  finally
    ks.Free;
  end;
end;

class function TJsonEngine.ConvertDictValue(AOwnerTypeInfo: PTypeInfo; const AFieldName: string; const AValueJson: TJSONValue): TValue;
var
  FP: TJsonFieldPlan;
begin
  FP := FindFieldPlan(GetPlan(AOwnerTypeInfo), AFieldName);
  if (FP <> nil) and (FP.DictValSerializer <> nil) then
    Result := FP.DictValSerializer.DeserializeValue(AValueJson, FP.DictValTypeInfo)
  else if FP <> nil then
    Result := JsonToValue(FP.DictValKind, FP.DictValTypeInfo, AValueJson,
      FP.DictValMapping, FP.DictValDateFormat, FP.DictValDatePattern)
  else
    Result := TValue.Empty;
end;



class function TJsonEngine.PickSerializer(ACls: TJsonValueSerializerClass;
  AInstance: TCustomJsonValueSerializer): TCustomJsonValueSerializer;
begin
  { A delegate registration carries a ready-made instance; a class
    registration is resolved to its framework-owned singleton.  Both end up
    as one instance in the plan, which is why nothing downstream - execution,
    coverage, torture - can tell them apart. }
  if AInstance <> nil then
    Result := AInstance
  else
    Result := ResolveSerializer(ACls);
end;

class function TJsonEngine.AdoptSerializer(
  AInstance: TCustomJsonValueSerializer): TCustomJsonValueSerializer;
begin
  Result := AInstance;
  if AInstance = nil then Exit;
  FLock.Enter;
  try
    FAdopted.Add(AInstance);
  finally
    FLock.Leave;
  end;
end;
{ ----------------------------------------- the typed serializer bridges --- }

{ Turns the engine's TValue into T, calls the implementation, and turns the
  answer back.  This is the whole reason TCustomJsonValueSerializer<T> exists:
  the four TValue operations below are the ones an implementation would
  otherwise have to write for itself, in every serializer, correctly. }





{ --------------------------------------------- the delegate adapter --- }

{ One instance per registration, holding the caller's closures.  It is a
  TCustomJsonValueSerializer<T> like any other, so the engine cannot tell the
  difference between a delegate registration and a class registration. }






{ ------------------------------------------------ typed field builders --- }








class procedure TJsonEngine.SeedSerializer(ACls: TJsonValueSerializerClass;
  AInstance: TCustomJsonValueSerializer);
begin
  FLock.Enter;
  try
    { FSingletons owns its values, so re-registering a type releases the
      closures the previous registration captured. }
    FSingletons.AddOrSetValue(ACls, AInstance);
  finally
    FLock.Leave;
  end;
end;

class function TJsonEngine.ResolveSerializer(
  ACls: TJsonValueSerializerClass): TCustomJsonValueSerializer;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  if ACls = nil then Exit(nil);
  FLock.Enter;
  try
    if not FSingletons.TryGetValue(ACls, Result) then
    begin
      Result := ACls.Create;
      FSingletons.Add(ACls, Result);
      Inc(SingletonsCreated);
    end;
  finally
    FLock.Leave;
  end;
end;

class function TJsonEngine.GenericFamilyKey(ATypeInfo: PTypeInfo; out AKey: string): Boolean;
begin
  { Class-only, to preserve the existing RegisterGenericTypeSerializer
    contract.  The general form (which also covers records) lives in
    PascalForge.Serialization.Core. }
  AKey := '';
  Result := (ATypeInfo <> nil) and (ATypeInfo.Kind = tkClass) and
    GenericFamilyKeyOf(ATypeInfo, AKey);
end;

class function TJsonEngine.FindRegisteredTypeSerializer(ATypeInfo: PTypeInfo;
  out ASerializerClass: TJsonValueSerializerClass): Boolean;
var
  Key: string;
  C: TClass;
begin
  if FTypeSerializers.TryGetValue(ATypeInfo, ASerializerClass) then Exit(True);
  if GenericFamilyKey(ATypeInfo, Key) and
    FGenericTypeSerializers.TryGetValue(Key, ASerializerClass) then Exit(True);
  if ATypeInfo.Kind = tkClass then
  begin
    C := ATypeInfo.TypeData.ClassType;
    while C <> nil do
    begin
      if FClassTypeSerializers.TryGetValue(C, ASerializerClass) then Exit(True);
      C := C.ClassParent;
    end;
  end;
  Result := False;
end;

class function TJsonEngine.FindContextSerializer(AOwnerTypeInfo,
  AValueTypeInfo: PTypeInfo; out ASerializerClass: TJsonValueSerializerClass): Boolean;
var R: TJsonContextSerializerRule; ValueClass: TClass; BestOrder: Integer;
  OwnerUnit: string;
begin
  Result := False;
  BestOrder := -1;
  if (AOwnerTypeInfo = nil) or (AValueTypeInfo = nil) or
     (AValueTypeInfo.Kind <> tkClass) then Exit;
  OwnerUnit := UnitOf(AOwnerTypeInfo);
  ValueClass := AValueTypeInfo.TypeData.ClassType;
  for R in FContextSerializerRules do
    if (R.Order > BestOrder) and GlobMatch(R.OwnerUnitPattern, OwnerUnit) and
       ValueClass.InheritsFrom(R.ValueBaseClass) then
    begin
      ASerializerClass := R.SerializerClass;
      BestOrder := R.Order;
      Result := True;
    end;
end;

class procedure TJsonEngine.RegisterFieldOverride(AClass: TClass; const AFieldName: string; const AOverride: TJsonFieldOverride);
begin
  RegisterFieldOverride(AClass.ClassInfo, AFieldName, AOverride);
end;


class procedure TJsonEngine.RegisterFieldOverride(AOwnerTypeInfo: PTypeInfo; const AFieldName: string; const AOverride: TJsonFieldOverride);
var
  R: TJsonRule;
begin
  CheckNotFrozen;
  R := Default(TJsonRule);
  R.Scope := TScopeKind.Field;
  R.TargetTypeInfo := AOwnerTypeInfo;
  R.FieldPattern := AFieldName;
  R.Ovr := AOverride;
  R.Order := FOrder; Inc(FOrder);
  FRules.Add(R);
end;

class procedure TJsonEngine.RegisterFieldOverride(const AQualifiedOwnerTypeName,
  AFieldName: string; const AOverride: TJsonFieldOverride);
var
  R: TJsonRule;
begin
  CheckNotFrozen;
  R := Default(TJsonRule);
  R.Scope := TScopeKind.Field;
  R.TargetTypeName := AQualifiedOwnerTypeName;
  R.FieldPattern := AFieldName;
  R.Ovr := AOverride;
  R.Order := FOrder; Inc(FOrder);
  FRules.Add(R);
end;

class procedure TJsonEngine.RegisterClassFieldOverride(AClass: TClass; const AFieldPattern: string; const AOverride: TJsonFieldOverride; AIncludeDescendants: Boolean);
var
  R: TJsonRule;
begin
  CheckNotFrozen;
  R := Default(TJsonRule);
  if AIncludeDescendants then R.Scope := TScopeKind.ClassAndDescendants else R.Scope := TScopeKind.ExactClass;
  R.TargetClass := AClass;
  R.FieldPattern := AFieldPattern;
  R.Ovr := AOverride;
  R.Order := FOrder; Inc(FOrder);
  FRules.Add(R);
end;

class procedure TJsonEngine.RegisterUnitFieldOverride(const AUnitPattern, AFieldPattern: string; const AOverride: TJsonFieldOverride);
var
  R: TJsonRule;
begin
  CheckNotFrozen;
  R := Default(TJsonRule);
  if AUnitPattern.Contains('*') then R.Scope := TScopeKind.UnitPattern else R.Scope := TScopeKind.UnitName;
  R.UnitPattern := AUnitPattern;
  R.FieldPattern := AFieldPattern;
  R.Ovr := AOverride;
  R.Order := FOrder; Inc(FOrder);
  FRules.Add(R);
end;

class procedure TJsonEngine.RegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TJsonValueSerializerClass);
begin
  CheckNotFrozen;
  FTypeSerializers.AddOrSetValue(ATypeInfo, ASerializerClass);
end;





class procedure TJsonEngine.RegisterGenericTypeSerializer(
  ARepresentativeTypeInfo: PTypeInfo;
  ASerializerClass: TJsonValueSerializerClass);
var
  Key: string;
begin
  CheckNotFrozen;
  if not GenericFamilyKey(ARepresentativeTypeInfo, Key) then
    raise EJsonError.CreateFmt('%s is not a direct closed generic class specialization',
      [UTF8ToString(ARepresentativeTypeInfo.Name)]);
  FGenericTypeSerializers.AddOrSetValue(Key, ASerializerClass);
end;


class procedure TJsonEngine.RegisterClassTypeSerializer(ABaseClass: TClass;
  ASerializerClass: TJsonValueSerializerClass);
begin
  CheckNotFrozen;
  if ABaseClass = nil then
    raise EJsonError.Create('Class serializer base class cannot be nil');
  FClassTypeSerializers.AddOrSetValue(ABaseClass, ASerializerClass);
end;

class procedure TJsonEngine.RegisterUnitClassTypeSerializer(
  const AOwnerUnitPattern: string; AValueBaseClass: TClass;
  ASerializerClass: TJsonValueSerializerClass);
var R: TJsonContextSerializerRule;
begin
  CheckNotFrozen;
  if (AValueBaseClass = nil) or (ASerializerClass = nil) then
    raise EJsonError.Create('Context class serializer requires classes');
  R.OwnerUnitPattern := AOwnerUnitPattern;
  R.ValueBaseClass := AValueBaseClass;
  R.SerializerClass := ASerializerClass;
  R.Order := FOrder;
  Inc(FOrder);
  FContextSerializerRules.Add(R);
end;

class procedure TJsonEngine.RegisterOpaqueClass(ABaseClass: TClass);
begin
  CheckNotFrozen;
  if ABaseClass = nil then
    raise EJsonError.Create('Opaque base class cannot be nil');
  if not FOpaqueClasses.Contains(ABaseClass) then FOpaqueClasses.Add(ABaseClass);
end;

class procedure TJsonEngine.RegisterSerializationSurface(ARuntimeClass,
  AContractClass: TClass);
begin
  CheckNotFrozen;
  if (ARuntimeClass = nil) or (AContractClass = nil) then
    raise EJsonError.Create('Serialization surface requires two classes');
  if not ARuntimeClass.InheritsFrom(AContractClass) then
    raise EJsonError.CreateFmt(
      '%s does not inherit from the requested serialization contract %s',
      [ARuntimeClass.ClassName, AContractClass.ClassName]);
  FSerializationSurfaces.AddOrSetValue(ARuntimeClass, AContractClass);
end;

class procedure TJsonEngine.SetDefaultMemberStrategy(
  AStrategy: TJsonMemberStrategy);
begin
  CheckNotFrozen;
  FDefaultMemberStrategy := AStrategy;
end;

class procedure TJsonEngine.RegisterTypeMemberStrategy(ATypeInfo: PTypeInfo;
  AStrategy: TJsonMemberStrategy);
begin
  CheckNotFrozen;
  FMemberStrategies.AddOrSetValue(ATypeInfo, AStrategy);
end;


class procedure TJsonEngine.SetDefaultRecursiveReferencePolicy(
  APolicy: TJsonRecursiveReferencePolicy);
begin
  CheckNotFrozen;
  FDefaultRecursionPolicy := APolicy;
end;

class procedure TJsonEngine.RegisterTypeRecursiveReferencePolicy(
  ATypeInfo: PTypeInfo; APolicy: TJsonRecursiveReferencePolicy);
begin
  CheckNotFrozen;
  FRecursionPolicies.AddOrSetValue(ATypeInfo, APolicy);
end;



class procedure TJsonEngine.RegisterEnumMapping(ATypeInfo: PTypeInfo; const AValues: array of string);
var
  A: TArray<string>;
  I: Integer;
begin
  CheckNotFrozen;
  SetLength(A, Length(AValues));
  for I := 0 to Integer(High(AValues)) do A[I] := AValues[I];
  FEnumMappings.AddOrSetValue(ATypeInfo, A);
end;

class procedure TJsonEngine.RegisterEnumMapping(const AQualifiedTypeName: string;
  const AValues: array of string);
var
  A: TArray<string>;
  I: Integer;
begin
  CheckNotFrozen;
  SetLength(A, Length(AValues));
  for I := 0 to Integer(High(AValues)) do A[I] := AValues[I];
  FEnumNameMappings.AddOrSetValue(LowerCase(AQualifiedTypeName), A);
end;

class procedure TJsonEngine.RegisterFieldEnumMapping(const AQualifiedOwnerTypeName,
  AFieldName: string; const AValues: array of string);
var
  A: TArray<string>;
  I: Integer;
begin
  CheckNotFrozen;
  SetLength(A, Length(AValues));
  for I := 0 to Integer(High(AValues)) do A[I] := AValues[I];
  FFieldEnumMappings.AddOrSetValue(
    LowerCase(AQualifiedOwnerTypeName + '|' + AFieldName), A);
end;

class procedure TJsonEngine.RegisterClassFactory(ATypeInfo: PTypeInfo; const AFactory: TJsonClassFactory);
begin
  CheckNotFrozen;
  FFactories.AddOrSetValue(ATypeInfo, AFactory);
end;


class function TJsonEngine.EnumMappingFor(ATypeInfo: PTypeInfo): TArray<string>;
var
  Key: string;
begin
  if FEnumMappings.TryGetValue(ATypeInfo, Result) then Exit;
  { TypeKey never raises: it degrades to a unit-qualified or bare name for
    types declared in an implementation section. }
  Key := TypeKey(ATypeInfo);
  if (Key = '') or
     not FEnumNameMappings.TryGetValue(LowerCase(Key), Result) then
    { Nothing registered for JSON: [SerializationEnum] on the type. }
    Result := TSerializationMetadata.EnumValuesOf(ATypeInfo);
end;

class function TJsonEngine.HasRegisteredEnumMapping(ATypeInfo: PTypeInfo): Boolean;
var
  Key: string;
begin
  if (ATypeInfo = nil) or FEnumMappings.ContainsKey(ATypeInfo) then
    Exit(ATypeInfo <> nil);
  Key := TypeKey(ATypeInfo);
  Result := (Key <> '') and FEnumNameMappings.ContainsKey(LowerCase(Key));
end;

class procedure TJsonEngine.ApplyGeneralEnum(AFP: TJsonFieldPlan;
  AMember: TRttiMember);
var
  Info: TSerializationMember;
begin
  Info := TSerializationMetadata.MemberInfo(AMember);
  if (Info = nil) or not Info.HasEnumValues then Exit;
  if (AFP.Kind = TJsonKind.EnumValue) and
     not HasRegisteredEnumMapping(AFP.FieldTypeInfo) then
    AFP.EnumMapping := Info.EnumValues
  else if (AFP.Kind = TJsonKind.NullableValue) and
          (AFP.InnerKind = TJsonKind.EnumValue) and
          not HasRegisteredEnumMapping(AFP.InnerTypeInfo) then
    AFP.EnumMapping := Info.EnumValues;
end;

class function TJsonEngine.FieldEnumMappingFor(const AOwnerKey,
  AFieldName: string; out AValues: TArray<string>): Boolean;
begin
  Result := (AOwnerKey <> '') and FFieldEnumMappings.TryGetValue(
    LowerCase(AOwnerKey + '|' + AFieldName), AValues);
end;

class function TJsonEngine.DefaultJsonName(const AFieldName: string): string;
begin
  Result := AFieldName;
  if Result.StartsWith('_') then Delete(Result, 1, 1);
  if Result <> '' then Result[1] := LowerCase(Result[1])[1];
end;

class function TJsonEngine.SnakeCase(const AName: string): string;
var
  i: Integer;
  ch: Char;
begin
  Result := '';
  for i := 1 to Length(AName) do
  begin
    ch := AName[i];
    if CharInSet(ch, ['A'..'Z']) then
    begin
      if (i > 1) and not CharInSet(AName[i - 1], ['A'..'Z', '_']) then Result := Result + '_';
      Result := Result + LowerCase(ch)[1];
    end
    else
      Result := Result + ch;
  end;
end;

class procedure TJsonEngine.RegisterUnitNaming(const AUnitPattern: string; ANaming: TJsonNaming);
var R: TJsonNamingRule;
begin
  CheckNotFrozen;
  R := Default(TJsonNamingRule);
  if AUnitPattern.Contains('*') then R.Scope := TScopeKind.UnitPattern else R.Scope := TScopeKind.UnitName;
  R.UnitPattern := AUnitPattern; R.Naming := ANaming; R.Order := FOrder; Inc(FOrder);
  FNamingRules.Add(R);
end;

class procedure TJsonEngine.RegisterClassNaming(AClass: TClass; ANaming: TJsonNaming; AIncludeDescendants: Boolean);
var R: TJsonNamingRule;
begin
  CheckNotFrozen;
  R := Default(TJsonNamingRule);
  if AIncludeDescendants then R.Scope := TScopeKind.ClassAndDescendants else R.Scope := TScopeKind.ExactClass;
  R.TargetClass := AClass; R.Naming := ANaming; R.Order := FOrder; Inc(FOrder);
  FNamingRules.Add(R);
end;

class procedure TJsonEngine.RegisterClassNaming(const AQualifiedTypeName: string;
  ANaming: TJsonNaming);
var R: TJsonNamingRule;
begin
  CheckNotFrozen;
  R := Default(TJsonNamingRule);
  R.Scope := TScopeKind.ExactClass;
  R.TargetTypeName := AQualifiedTypeName;
  R.Naming := ANaming;
  R.Order := FOrder; Inc(FOrder);
  FNamingRules.Add(R);
end;

class function TJsonEngine.ResolveNaming(AClass: TClass;
  const AUnit, ATypeKey: string): TJsonNaming;
var
  R: TJsonNamingRule;
  classTypeName: string;
  bestScope, bestOrder, rank: Integer;
  matches: Boolean;
begin
  Result := TJsonNaming.DefaultStyle;
  classTypeName := ATypeKey;
  if (classTypeName = '') and (AClass <> nil) then
    classTypeName := TypeKey(AClass.ClassInfo, AUnit);
  bestScope := MaxInt; bestOrder := -1;
  for R in FNamingRules do
  begin
    case R.Scope of
      TScopeKind.ExactClass: matches := (AClass <> nil) and
        (((R.TargetClass <> nil) and (R.TargetClass = AClass)) or
         ((R.TargetTypeName <> '') and SameText(R.TargetTypeName, classTypeName)));
      TScopeKind.ClassAndDescendants: matches := (AClass <> nil) and AClass.InheritsFrom(R.TargetClass);
      TScopeKind.UnitName: matches := SameText(R.UnitPattern, AUnit);
      TScopeKind.UnitPattern: matches := GlobMatch(R.UnitPattern, AUnit);
    else matches := False;
    end;
    if not matches then Continue;
    rank := Ord(R.Scope);
    if (rank < bestScope) or ((rank = bestScope) and (R.Order > bestOrder)) then
    begin Result := R.Naming; bestScope := rank; bestOrder := R.Order; end;
  end;
end;

class function TJsonEngine.UnitOf(ATypeInfo: PTypeInfo;
  const AUnitHint: string): string;
begin
  Result := TypeUnitOf(ATypeInfo, AUnitHint);
end;

class function TJsonEngine.TypeKey(ATypeInfo: PTypeInfo;
  const AUnitHint: string): string;
begin
  Result := TypeKeyOf(ATypeInfo, AUnitHint);
end;

class procedure TJsonEngine.ResolveOverride(AOwner: PTypeInfo; AClass: TClass;
  const AUnit, AOwnerKey, AFieldName: string;
  out AName: string; out ASerializerClass: TJsonValueSerializerClass;
  out ASerializerInstance: TCustomJsonValueSerializer; out AIgnore: Boolean;
  out AHasMemberStrategy: Boolean; out AMemberStrategy: TJsonMemberStrategy;
  out AHasRecursionPolicy: Boolean;
  out ARecursionPolicy: TJsonRecursiveReferencePolicy);
var
  R: TJsonRule;
  bestNameScope, bestSerScope, bestIgnScope: Integer;
  bestNameOrder, bestSerOrder, bestIgnOrder: Integer;
  bestMemberScope, bestRecursionScope, bestMemberOrder, bestRecursionOrder: Integer;
  matches: Boolean;
  scopeRank: Integer;
  ownerTypeName: string;
begin
  // more-specific scope wins; within same scope, latest registration wins.
  AName := ''; ASerializerClass := nil; ASerializerInstance := nil; AIgnore := False;
  AHasMemberStrategy := False; AHasRecursionPolicy := False;
  AMemberStrategy := TJsonMemberStrategy.PublicSurface;
  ARecursionPolicy := TJsonRecursiveReferencePolicy.WriteNull;
  bestNameScope := MaxInt; bestSerScope := MaxInt; bestIgnScope := MaxInt;
  bestNameOrder := -1; bestSerOrder := -1; bestIgnOrder := -1;
  bestMemberScope := MaxInt; bestRecursionScope := MaxInt;
  bestMemberOrder := -1; bestRecursionOrder := -1;
  ownerTypeName := AOwnerKey;
  if (ownerTypeName = '') and (AOwner <> nil) then
    ownerTypeName := TypeKey(AOwner, AUnit);
  for R in FRules do
  begin
    if not FieldMatch(R.FieldPattern, AFieldName) then Continue;
    case R.Scope of
      TScopeKind.Field: matches := ((R.TargetTypeInfo <> nil) and (R.TargetTypeInfo = AOwner)) or
        ((R.TargetTypeName <> '') and SameText(R.TargetTypeName, ownerTypeName));
      TScopeKind.ExactClass: matches := (AClass <> nil) and (R.TargetClass = AClass);
      TScopeKind.ClassAndDescendants: matches := (AClass <> nil) and AClass.InheritsFrom(R.TargetClass);
      TScopeKind.UnitName: matches := SameText(R.UnitPattern, AUnit);
      TScopeKind.UnitPattern: matches := GlobMatch(R.UnitPattern, AUnit);
    else
      matches := False;
    end;
    if not matches then Continue;
    scopeRank := Ord(R.Scope);
    if R.Ovr.HasJsonName and
       ((scopeRank < bestNameScope) or ((scopeRank = bestNameScope) and (R.Order > bestNameOrder))) then
    begin
      AName := R.Ovr.JsonName; bestNameScope := scopeRank; bestNameOrder := R.Order;
    end;
    { A class registration and a delegate registration compete on exactly the
      same scope/order rules; only the winner's carrier differs. }
    if ((R.Ovr.SerializerClass <> nil) or (R.Ovr.SerializerInstance <> nil)) and
       ((scopeRank < bestSerScope) or ((scopeRank = bestSerScope) and (R.Order > bestSerOrder))) then
    begin
      ASerializerClass := R.Ovr.SerializerClass;
      ASerializerInstance := R.Ovr.SerializerInstance;
      bestSerScope := scopeRank; bestSerOrder := R.Order;
    end;
    if R.Ovr.HasIgnore and
       ((scopeRank < bestIgnScope) or ((scopeRank = bestIgnScope) and (R.Order > bestIgnOrder))) then
    begin
      AIgnore := R.Ovr.DoIgnore; bestIgnScope := scopeRank; bestIgnOrder := R.Order;
    end;
    if R.Ovr.HasMemberStrategy and
       ((scopeRank < bestMemberScope) or
        ((scopeRank = bestMemberScope) and (R.Order > bestMemberOrder))) then
    begin
      AHasMemberStrategy := True;
      AMemberStrategy := R.Ovr.MemberStrategy;
      bestMemberScope := scopeRank; bestMemberOrder := R.Order;
    end;
    if R.Ovr.HasRecursionPolicy and
       ((scopeRank < bestRecursionScope) or
        ((scopeRank = bestRecursionScope) and (R.Order > bestRecursionOrder))) then
    begin
      AHasRecursionPolicy := True;
      ARecursionPolicy := R.Ovr.RecursionPolicy;
      bestRecursionScope := scopeRank; bestRecursionOrder := R.Order;
    end;
  end;
end;

{ Nullable recognition is not the JSON engine's business: it is a shared
  type-system fact, so that JSON, XML, BSON and the DataSet projection cannot
  disagree about which records are nullables.  The whole rule lives in
  PascalForge.Serialization.Core; families are registered with
  TSerialization.RegisterNullableFamily<T>. }
class function TJsonEngine.IsNullableType(ATypeInfo: PTypeInfo; out AInner: PTypeInfo): Boolean;
var
  Access: TNullableAccess;
begin
  AInner := nil;
  Result := TSerializationTypes.TryGetNullableAccess(ATypeInfo, Access);
  if Result then AInner := Access.ValueType;
end;

class function TJsonEngine.NullableAccessFor(ATypeInfo: PTypeInfo): TNullableAccess;
begin
  if not TSerializationTypes.TryGetNullableAccess(ATypeInfo, Result) then
    raise EJsonInternalError.CreateFmt(
      'Internal: %s was classified as a nullable but its layout cannot be resolved.',
      [UTF8ToString(ATypeInfo.Name)]);
end;

class function TJsonEngine.DatePoliciesFor(AKind: TJsonKind): TDateTimePolicies;
begin
  case AKind of
    TJsonKind.DateValue: Result := FDatePolicies;
    TJsonKind.TimeValue: Result := FTimePolicies;
  else
    Result := FTimestampPolicies;
  end;
end;

{ Field, then type, then global, then built-in - resolved once, here, while
  a plan is built.  A non-date kind resolves to Iso8601 and never asks. }
class procedure TJsonEngine.ResolveDatePolicy(AKind: TJsonKind;
  const AOwnerKey, AFieldName: string; out AFormat: TJsonDateTimeFormat;
  out APattern: string);
var
  Policy: TDateTimePolicy;
begin
  AFormat := TJsonDateTimeFormat.Iso8601;
  APattern := '';
  if not (AKind in [TJsonKind.DateValue, TJsonKind.TimeValue,
    TJsonKind.DateTimeValue]) then Exit;
  Policy := DatePoliciesFor(AKind).Resolve(AOwnerKey, AFieldName);
  AFormat := TJsonDateTimeFormat(Policy.Kind);
  APattern := Policy.Pattern;
end;

class procedure TJsonEngine.SetDateTimePolicy(ATypeInfo: PTypeInfo;
  const AFieldName: string; AKind: Integer; const APattern: string);
var
  Policy: TDateTimePolicy;
  TypeKey: string;
begin
  CheckNotFrozen;
  Policy := TDateTimePolicy.Make(AKind, APattern);
  TypeKey := '';
  if ATypeInfo <> nil then TypeKey := TypeKeyOf(ATypeInfo);
  FLock.Enter;
  try
    if ATypeInfo = nil then
    begin
      FDatePolicies.SetGlobal(Policy);
      FTimePolicies.SetGlobal(Policy);
      FTimestampPolicies.SetGlobal(Policy);
    end
    else if AFieldName = '' then
    begin
      FDatePolicies.SetForType(TypeKey, Policy);
      FTimePolicies.SetForType(TypeKey, Policy);
      FTimestampPolicies.SetForType(TypeKey, Policy);
    end
    else
    begin
      FDatePolicies.SetForField(TypeKey, AFieldName, Policy);
      FTimePolicies.SetForField(TypeKey, AFieldName, Policy);
      FTimestampPolicies.SetForField(TypeKey, AFieldName, Policy);
    end;
  finally
    FLock.Leave;
  end;
end;

class function TJsonEngine.ClassifyType(ATypeInfo: PTypeInfo): TJsonKind;
var
  Inner: PTypeInfo;
begin
  if ATypeInfo = nil then Exit(TJsonKind.Unsupported);
  if ATypeInfo = System.TypeInfo(TGUID) then Exit(TJsonKind.GuidValue);
  if ATypeInfo = System.TypeInfo(TDate) then Exit(TJsonKind.DateValue);
  if ATypeInfo = System.TypeInfo(TTime) then Exit(TJsonKind.TimeValue);
  if ATypeInfo = System.TypeInfo(TDateTime) then Exit(TJsonKind.DateTimeValue);
  if ATypeInfo = System.TypeInfo(Currency) then Exit(TJsonKind.CurrencyValue);
  if (ATypeInfo = System.TypeInfo(Boolean)) or (ATypeInfo = System.TypeInfo(ByteBool)) or
     (ATypeInfo = System.TypeInfo(WordBool)) or (ATypeInfo = System.TypeInfo(LongBool)) then Exit(TJsonKind.BooleanValue);
  if IsNullableType(ATypeInfo, Inner) then Exit(TJsonKind.NullableValue);
  case ATypeInfo.Kind of
    tkInteger: Result := TJsonKind.IntegerValue;
    tkInt64: Result := TJsonKind.Int64Value;
    tkFloat:
      { Comp is a 64-bit integer that RTTI files under tkFloat. Sent through
        a Double it loses everything past 2^53, so it is written as the
        integer it is. }
      if GetTypeData(ATypeInfo).FloatType = ftCurr then Result := TJsonKind.CurrencyValue
      else if GetTypeData(ATypeInfo).FloatType = ftComp then Result := TJsonKind.Int64Value
      else Result := TJsonKind.FloatValue;
    tkEnumeration: Result := TJsonKind.EnumValue;
    tkSet:
      if ATypeInfo.TypeData.CompType = nil then Result := TJsonKind.Unsupported
      else Result := TJsonKind.SetValue;
    tkChar, tkWChar, tkString, tkLString, tkWString, tkUString: Result := TJsonKind.StringValue;
    { A managed record is a record: its operators run when RTTI copies it,
      which is all the lifetime it asks for. }
    tkRecord, tkMRecord: Result := TJsonKind.RecordValue;
    tkVariant: Result := TJsonKind.VariantValue;
    { A static array is a fixed-length sequence - written as an array, and
      read back only when the element count matches the type exactly. }
    tkArray: Result := TJsonKind.ListValue;
    { A dynamic array IS a sequence, so it is a list - the same kind, and
      therefore the same wire shape, as TList<T>. The two differ only in how
      the elements are reached, and the plan records which by leaving the
      container methods nil.

      Before this, tkDynArray fell through to Unsupported, which meant a
      TArray<T> member was silently absent from the document. That is the
      defect this branch closes. }
    tkDynArray: Result := TJsonKind.ListValue;
    tkClass:
      { Detection walks the real ancestry, so an ordinary descendant such as
        TOrders = class(TObjectList<TOrder>) is still recognized as a list.
        Dictionaries are tested first because TObjectDictionary is not a
        TList descendant but shares no prefix with it either. }
      { THE ONE QUESTION, ASKED IN ONE PLACE. TSerializationTypes matches by
        ancestry, so TOrders = class(TObjectList<TOrder>) is a list and a
        class that merely has an Add and a ToArray is not. }
      case TSerializationTypes.ContainerKindOf(ATypeInfo) of
        TContainerKind.Dictionary: Result := TJsonKind.DictionaryValue;
        TContainerKind.List:       Result := TJsonKind.ListValue;
      else
        Result := TJsonKind.ObjectValue;
      end;
  else
    Result := TJsonKind.Unsupported;
  end;
end;

class function TJsonEngine.GetPlan(ATypeInfo: PTypeInfo;
  const AUnitHint: string): TJsonTypePlan;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  FLock.Enter;
  try
    if not FPlans.TryGetValue(ATypeInfo, Result) then
      Result := BuildPlan(ATypeInfo, True,
        False, TJsonMemberStrategy.PublicSurface,
        False, TJsonRecursiveReferencePolicy.WriteNull, AUnitHint);
  finally
    FLock.Leave;
  end;
end;

class function TJsonEngine.HasUsableStructuralRtti(AClass: TClass): Boolean;
var RttiType: TRttiType;
begin
  { Eligibility for a structural plan is decided by whether member
    enumeration works, NOT by IsPublicType.  Extended RTTI reports Name,
    TypeKind, BaseType, GetFields, GetProperties, attributes, constructors
    and field offsets for implementation-section declarations; only
    QualifiedName is unavailable, and nothing structural needs it. }
  Result := False;
  if AClass = nil then Exit;
  try
    RttiType := FCtx.GetType(AClass.ClassInfo);
    if RttiType = nil then Exit;
    RttiType.GetFields;
    RttiType.GetProperties;
    Result := True;
  except
    Result := False;
  end;
end;

class function TJsonEngine.IsCompatibleExisting(AExisting: TObject;
  ADeclaredTypeInfo: PTypeInfo): Boolean;
begin
  { An existing instance is reusable when it satisfies the member's declared
    contract.  A DESCENDANT qualifies, which is what preserves polymorphism:
    a member declared TChild but holding a TDerivedChild keeps its runtime
    class instead of being downgraded on every deserialization. }
  Result := (AExisting <> nil) and (ADeclaredTypeInfo <> nil) and
    (ADeclaredTypeInfo.Kind = tkClass) and
    AExisting.ClassType.InheritsFrom(GetTypeData(ADeclaredTypeInfo).ClassType);
end;

class procedure TJsonEngine.ClearContainer(AContainer: TObject;
  AFP: TJsonFieldPlan);
var
  ClearMethod: TRttiMethod;
begin
  { Clear is deliberately the only disposal the serializer performs.  It asks
    the container what it owns - TObjectList.OwnsObjects, a dictionary's
    doOwnsValues - instead of the serializer
    guessing from a member declaration.  A non-owning container therefore
    keeps its elements alive, and an owning one disposes of them exactly as it
    would on any other Clear. }
  if AContainer = nil then Exit;
  ClearMethod := AFP.ContainerClearMethod;
  if ClearMethod = nil then
    ClearMethod := FCtx.GetType(AContainer.ClassType).GetMethod('Clear');
  if ClearMethod = nil then
    raise EJsonError.CreateFmt(
      'Cannot reuse the existing %s in %s.%s: it has no Clear method',
      [AContainer.ClassName, AFP.DeclaringTypeName, AFP.FieldName]);
  ClearMethod.Invoke(AContainer, []);
end;

class function TJsonEngine.SelectClassSurface(
  ADeclaredTypeInfo: PTypeInfo; ARuntimeClass: TClass): PTypeInfo;
var DeclaredClass, Candidate, Contract: TClass;
begin
  if ARuntimeClass = nil then
    raise EJsonError.Create('Cannot select a serialization surface for a nil runtime class');

  { An explicitly registered contract always wins: this is the opt-in form of
    the public-ancestor downgrade. }
  Candidate := ARuntimeClass;
  while Candidate <> nil do
  begin
    if FSerializationSurfaces.TryGetValue(Candidate, Contract) then
      Exit(Contract.ClassInfo);
    Candidate := Candidate.ClassParent;
  end;

  { Otherwise the runtime class serializes through its own members, whether or
    not it is declared in an interface section. }
  if HasUsableStructuralRtti(ARuntimeClass) then Exit(ARuntimeClass.ClassInfo);

  DeclaredClass := nil;
  if (ADeclaredTypeInfo <> nil) and (ADeclaredTypeInfo.Kind = tkClass) then
    DeclaredClass := ADeclaredTypeInfo.TypeData.ClassType;
  if (DeclaredClass <> nil) and (DeclaredClass <> TObject) and
     ARuntimeClass.InheritsFrom(DeclaredClass) and
     HasUsableStructuralRtti(DeclaredClass) then
    Exit(DeclaredClass.ClassInfo);

  Candidate := ARuntimeClass.ClassParent;
  while Candidate <> nil do
  begin
    if HasUsableStructuralRtti(Candidate) then Exit(Candidate.ClassInfo);
    Candidate := Candidate.ClassParent;
  end;
  raise EJsonError.CreateFmt(
    'Cannot serialize %s: its RTTI does not expose enumerable members and no ancestor does either. Register a custom serializer, a serialization surface, or expose a serialization contract.',
    [ARuntimeClass.ClassName]);
end;

class function TJsonEngine.ResolveMemberObjectPlan(APlan: TJsonMemberPlan;
  ARuntimeClass: TClass): TJsonTypePlan;
var SurfaceTypeInfo: PTypeInfo;
begin
  FLock.Enter;
  try
    if (APlan.RuntimePlans <> nil) and
       APlan.RuntimePlans.TryGetValue(ARuntimeClass, Result) then Exit;
    SurfaceTypeInfo := SelectClassSurface(APlan.TypeInfo, ARuntimeClass);
    Result := GetPlan(SurfaceTypeInfo);
    if APlan.RuntimePlans = nil then
      APlan.RuntimePlans := TObjectDictionary<TClass, TJsonTypePlan>.Create([]);
    APlan.RuntimePlans.Add(ARuntimeClass, Result);
  finally
    FLock.Leave;
  end;
end;

class function TJsonEngine.ResolveChildPlan(AFieldPlan: TJsonFieldPlan;
  ARuntimeClass: TClass): TJsonTypePlan;
var SurfaceTypeInfo: PTypeInfo;
begin
  if ARuntimeClass = nil then
    ARuntimeClass := AFieldPlan.FieldTypeInfo.TypeData.ClassType;
  FLock.Enter;
  try
    if AFieldPlan.HasMemberStrategy or AFieldPlan.HasRecursionPolicy then
    begin
      if (AFieldPlan.ScopedChildPlans <> nil) and
         AFieldPlan.ScopedChildPlans.TryGetValue(ARuntimeClass, Result) then Exit;
      try
        SurfaceTypeInfo := SelectClassSurface(AFieldPlan.FieldTypeInfo,
          ARuntimeClass);
        Result := BuildPlan(SurfaceTypeInfo, False,
          AFieldPlan.HasMemberStrategy, AFieldPlan.MemberStrategy,
          AFieldPlan.HasRecursionPolicy, AFieldPlan.RecursionPolicy);
      except
        on E: Exception do
          raise EJsonError.CreateFmt('Cannot build scoped child plan for %s.%s (%s): %s',
            [AFieldPlan.DeclaringTypeName, AFieldPlan.FieldName,
             ARuntimeClass.ClassName, E.Message]);
      end;
      if AFieldPlan.ScopedChildPlans = nil then
        AFieldPlan.ScopedChildPlans := TObjectDictionary<TClass, TJsonTypePlan>.Create([doOwnsValues]);
      AFieldPlan.ScopedChildPlans.Add(ARuntimeClass, Result);
      Exit;
    end;
    if (AFieldPlan.ChildPlan <> nil) and
       (AFieldPlan.ChildPlanClass = ARuntimeClass) then Exit(AFieldPlan.ChildPlan);
    if (AFieldPlan.ChildPlans <> nil) and
       AFieldPlan.ChildPlans.TryGetValue(ARuntimeClass, Result) then Exit;
    try
      SurfaceTypeInfo := SelectClassSurface(AFieldPlan.FieldTypeInfo,
        ARuntimeClass);
      Result := GetPlan(SurfaceTypeInfo);
    except
      on E: Exception do
        raise EJsonError.CreateFmt('Cannot build child plan for %s.%s (%s): %s',
          [AFieldPlan.DeclaringTypeName, AFieldPlan.FieldName,
           ARuntimeClass.ClassName, E.Message]);
    end;
    if AFieldPlan.ChildPlan = nil then
    begin
      AFieldPlan.ChildPlan := Result;
      AFieldPlan.ChildPlanClass := ARuntimeClass;
    end
    else
    begin
      if AFieldPlan.ChildPlans = nil then
        AFieldPlan.ChildPlans := TDictionary<TClass, TJsonTypePlan>.Create;
      AFieldPlan.ChildPlans.AddOrSetValue(ARuntimeClass, Result);
    end;
  finally
    FLock.Leave;
  end;
end;

class function TJsonEngine.BuildPlan(ATypeInfo: PTypeInfo; ACache: Boolean;
  AHasMemberStrategy: Boolean; AMemberStrategy: TJsonMemberStrategy;
  AHasRecursionPolicy: Boolean;
  ARecursionPolicy: TJsonRecursiveReferencePolicy;
  const AUnitHint: string): TJsonTypePlan;
var
  T: TRttiType;
  F: TRttiField;
  Prop: TRttiProperty;
  M: TRttiMethod;
  IsTObjectCtor: Boolean;
  OpaqueBase: TClass;
  Names: TDictionary<string, string>;
  FP: TJsonFieldPlan;
  ExistingMember: string;
  Shared: TSerializationMember;
  Member: TRttiMember;
  FieldCountBefore: Integer;
  Cached: Boolean;
begin
  Result := TJsonTypePlan.Create;
  Cached := False;
  Inc(FBuildDepth);
  try
  Result.TypeInfo := ATypeInfo;
  T := FCtx.GetType(ATypeInfo);
  if T = nil then
    raise EJsonError.CreateFmt(
      'Cannot build a JSON plan for %s: the type exposes no usable RTTI. ' +
      'Types declared inside a routine body have no RTTI; declare the type ' +
      'at unit scope or register a custom serializer.',
      [UTF8ToString(ATypeInfo.Name)]);
  Result.RttiType := T;
  Result.IsRecord := ATypeInfo.Kind in [tkRecord, tkMRecord];
  Result.UnitName := TypeUnitOf(ATypeInfo, AUnitHint);
  Result.TypeKey := TypeKeyOf(ATypeInfo, Result.UnitName);
  if not Result.IsRecord then
  begin
    Result.ClassType := ATypeInfo.TypeData.ClassType;
    Result.IsOpaque := False;
    for OpaqueBase in FOpaqueClasses do
      if Result.ClassType.InheritsFrom(OpaqueBase) then
      begin
        Result.IsOpaque := True;
        Break;
      end;
    for M in T.GetMethods do
      if M.IsConstructor and (Length(M.GetParameters) = 0) then
      begin
        IsTObjectCtor := SameText(M.Parent.Name, 'TObject');
        if not IsTObjectCtor then
        begin
          Result.HasDeclaredConstructor := True;
          if Result.ZeroConstructor = nil then Result.ZeroConstructor := M;
        end
        else if Result.TObjectConstructor = nil then
          Result.TObjectConstructor := M;
      end;
  end;
  { TryGetValue RESETS its out parameter to the default when the key is
    missing, so reading it straight into the plan overwrote the configured
    default with ordinal 0 on every type that had no registration of its own
    - SetDefaultMemberStrategy and SetDefaultRecursiveReferencePolicy had no
    effect at all. }
  if not FMemberStrategies.TryGetValue(ATypeInfo, Result.MemberStrategy) then
    Result.MemberStrategy := FDefaultMemberStrategy;
  if AHasMemberStrategy then Result.MemberStrategy := AMemberStrategy;
  if not FRecursionPolicies.TryGetValue(ATypeInfo, Result.RecursionPolicy) then
    Result.RecursionPolicy := FDefaultRecursionPolicy;
  if AHasRecursionPolicy then Result.RecursionPolicy := ARecursionPolicy;
  { The plan is published to the cache before its members are built so that a
    recursive type resolves to the in-progress plan.  Any failure after this
    point must therefore un-publish it (see the except block below), or a
    later call would silently receive a half-built plan. }
  if ACache then
  begin
    FPlans.Add(ATypeInfo, Result);
    FBuildTrail.Add(ATypeInfo);
    Cached := True;
  end;
  Inc(PlansBuilt);
  if not Result.IsOpaque and
     not (ClassifyType(ATypeInfo) in [TJsonKind.ListValue,
       TJsonKind.DictionaryValue]) then
  begin
      { Delphi identifier shadowing is normalized before visibility, JSON
        attributes, naming, or collision validation - by the shared metadata,
        which also carries [SerializationIgnore]. }
      for Shared in TSerializationMetadata.Get(ATypeInfo).AllMembers do
      begin
        if Shared.Ignored then Continue;
        Member := Shared.Member;
        if Member is TRttiField then
        begin
          F := TRttiField(Member);
          if (Result.MemberStrategy <> TJsonMemberStrategy.PropertiesOnly) and
             ((Result.MemberStrategy = TJsonMemberStrategy.AllRTTI) or
              (F.Visibility in [mvPublic, mvPublished])) then
            try
              FieldCountBefore := Integer(Result.Fields.Count);
              BuildFieldPlan(Result, F);
              if AHasRecursionPolicy and (Result.Fields.Count > FieldCountBefore) and
                 not Result.Fields.Last.HasRecursionPolicy then
              begin
                Result.Fields.Last.HasRecursionPolicy := True;
                Result.Fields.Last.RecursionPolicy := ARecursionPolicy;
              end;
            except on E: Exception do raise EJsonError.CreateFmt(
              'Cannot build member plan for %s.%s: %s', [F.Parent.Name, F.Name, E.Message]); end;
        end
        else if Member is TRttiProperty then
        begin
          Prop := TRttiProperty(Member);
          if (Result.MemberStrategy <> TJsonMemberStrategy.FieldsOnly) and Prop.IsReadable and
             ((Result.MemberStrategy = TJsonMemberStrategy.AllRTTI) or
              (Prop.Visibility in [mvPublic, mvPublished])) then
            try
              FieldCountBefore := Integer(Result.Fields.Count);
              BuildPropertyPlan(Result, Prop);
              if AHasRecursionPolicy and (Result.Fields.Count > FieldCountBefore) and
                 not Result.Fields.Last.HasRecursionPolicy then
              begin
                Result.Fields.Last.HasRecursionPolicy := True;
                Result.Fields.Last.RecursionPolicy := ARecursionPolicy;
              end;
            except on E: Exception do raise EJsonError.CreateFmt(
              'Cannot build member plan for %s.%s: %s', [Prop.Parent.Name, Prop.Name, E.Message]); end;
        end;
      end;
  end;
  Names := TDictionary<string, string>.Create;
  try
    for FP in Result.Fields do
      if Names.TryGetValue(LowerCase(FP.JsonName), ExistingMember) then
        raise EJsonError.CreateFmt(
          'Duplicate JSON name "%s" in %s: Delphi members %s and %s',
          [FP.JsonName, UTF8ToString(ATypeInfo.Name), ExistingMember,
           FP.DeclaringTypeName + '.' + FP.FieldName])
      else
        Names.Add(LowerCase(FP.JsonName), FP.DeclaringTypeName + '.' + FP.FieldName);
  finally
    Names.Free;
  end;
    Dec(FBuildDepth);
    if FBuildDepth = 0 then FBuildTrail.Clear;
  except
    Dec(FBuildDepth);
    { Roll back every provisional cache entry published by this build, not
      just this one: a plan completed earlier in the same build may already
      hold a borrowed reference to a plan we are about to destroy.  Cached
      plans are freed by the rollback; an uncached (field-scoped) plan is
      owned by this frame and is freed here. }
    if not Cached then Result.Free;
    if FBuildDepth = 0 then RollbackBuildTrail;
    raise;
  end;
end;

class procedure TJsonEngine.RollbackBuildTrail;
var
  TI: PTypeInfo;
  Plan: TJsonTypePlan;
begin
  for TI in FBuildTrail do
    if FPlans.TryGetValue(TI, Plan) then
    begin
      FPlans.Remove(TI);
      Plan.Free;
    end;
  FBuildTrail.Clear;
end;

class function TJsonEngine.BuildMemberPlan(ATypeInfo: PTypeInfo): TJsonMemberPlan;
var
  StaticElem: PTypeInfo;
  StaticCount, StaticSize: Integer;
  RT: TRttiType;
  M: TRttiMethod;
  P: TArray<TRttiParameter>;
  SerCls: TJsonValueSerializerClass;
begin
  Result := TJsonMemberPlan.Create;
  try
    Result.TypeInfo := ATypeInfo;
    Result.Kind := ClassifyType(ATypeInfo);
    { A member plan has no owner and no member name - it is a root, an
      element, a key - so only the global default and the built-in can
      apply to it. }
    ResolveDatePolicy(Result.Kind, '', '', Result.DateFormat,
      Result.DatePattern);
    if FindRegisteredTypeSerializer(ATypeInfo, SerCls) then
    begin
      Result.Kind := TJsonKind.CustomSerializer;
      Result.Serializer := ResolveSerializer(SerCls);
      Exit;
    end;
    case Result.Kind of
      TJsonKind.NullableValue:
      begin
        Result.NullableAccess := NullableAccessFor(ATypeInfo);
        Result.Inner := BuildMemberPlan(Result.NullableAccess.ValueType);
      end;
      TJsonKind.EnumValue: Result.EnumMapping := EnumMappingFor(ATypeInfo);
      TJsonKind.SetValue:
      begin
        Result.SetElemTypeInfo := ATypeInfo.TypeData.CompType^;
        Result.SetElemMapping := EnumMappingFor(Result.SetElemTypeInfo);
        { Execution reads EnumMapping for both enum and set members. }
        Result.EnumMapping := Result.SetElemMapping;
      end;
      TJsonKind.ObjectValue, TJsonKind.RecordValue:
        Result.BoundPlan := GetPlan(ATypeInfo);
      TJsonKind.ListValue:
      if ATypeInfo.Kind = tkArray then
      begin
        Result.AddMethod := nil;
        Result.ToArrayMethod := nil;
        if not TSerializationTypes.TryGetStaticArrayShape(ATypeInfo, StaticElem,
             StaticCount, StaticSize) then
          raise EJsonError.CreateFmt(
            'Cannot serialize %s: its element type has no RTTI, so there is ' +
            'nothing to say what the elements are.', [UTF8ToString(ATypeInfo.Name)]);
        Result.Item := BuildMemberPlan(StaticElem);
      end
      else if ATypeInfo.Kind = tkDynArray then
      begin
        { A dynamic array has no container object: it IS the sequence. There
          is nothing to call Add on and nothing to call ToArray on, and the
          two nil methods are exactly what the execution sites below test to
          tell a TArray<T> from a TList<T>. The element type comes from the
          array's own RTTI. }
        Result.AddMethod := nil;
        Result.ToArrayMethod := nil;
        if GetTypeData(ATypeInfo).DynArrElType = nil then
          raise EJsonError.CreateFmt(
            'Cannot serialize %s: its element type has no RTTI, so there is ' +
            'nothing to say what the elements are.', [UTF8ToString(ATypeInfo.Name)]);
        Result.Item := BuildMemberPlan(GetTypeData(ATypeInfo).DynArrElType^);
      end
      else
      begin
        Result.BoundPlan := GetPlan(ATypeInfo);
        { The methods Core names for this family - never ones looked up here
          by the name Add, which a TQueue<T> does not have. }
        if not TSerializationTypes.TryGetListAccess(ATypeInfo, Result.ListAccess) then
          raise EJsonError.CreateFmt('%s is a list with no usable methods to ' +
            'add to it and read it.', [UTF8ToString(ATypeInfo.Name)]);
        Result.AddMethod := Result.ListAccess.AddMethod;
        Result.ToArrayMethod := Result.ListAccess.ToArrayMethod;
        if Result.ListAccess.ElementType <> nil then
          Result.Item := BuildMemberPlan(Result.ListAccess.ElementType);
      end;
      TJsonKind.DictionaryValue:
      begin
        Result.BoundPlan := GetPlan(ATypeInfo);
        Result.DictAccess := BuildDictAccess(ATypeInfo);
        RT := FCtx.GetType(ATypeInfo);
        M := RT.GetMethod('Add');
        Result.AddMethod := M;
        if M <> nil then
        begin
          P := M.GetParameters;
          if Length(P) >= 2 then
          begin
            Result.Key := BuildMemberPlan(P[0].ParamType.Handle);
            Result.Value := BuildMemberPlan(P[1].ParamType.Handle);
          end;
        end;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TJsonEngine.GetRootPlan(
  ATypeInfo: PTypeInfo): TJsonMemberPlan;
begin
  FLock.Enter;
  try
    if not FRootPlans.TryGetValue(ATypeInfo, Result) then
    begin
      Result := BuildMemberPlan(ATypeInfo);
      FRootPlans.Add(ATypeInfo, Result);
    end;
  finally
    FLock.Leave;
  end;
end;

class procedure TJsonEngine.ValidateRootJson(APlan: TJsonMemberPlan;
  const AJson: TJSONValue);
var
  Expected: string;
begin
  if AJson = nil then
    raise EJsonError.Create('Invalid JSON text');
  if APlan = nil then
    raise EJsonError.Create('Missing root JSON member plan');
  if APlan.Kind = TJsonKind.CustomSerializer then Exit;
  if APlan.Kind = TJsonKind.NullableValue then
  begin
    if AJson is TJSONNull then Exit;
    ValidateRootJson(APlan.Inner, AJson);
    Exit;
  end;
  { Reference-shaped members already use JSON null to represent nil. }
  if (AJson is TJSONNull) and
     (APlan.Kind in [TJsonKind.ObjectValue, TJsonKind.ListValue, TJsonKind.DictionaryValue]) then Exit;
  Expected := '';
  case APlan.Kind of
    TJsonKind.ObjectValue, TJsonKind.RecordValue, TJsonKind.DictionaryValue:
      if not (AJson is TJSONObject) then Expected := 'object';
    TJsonKind.ListValue:
      if not (AJson is TJSONArray) then Expected := 'array';
    TJsonKind.SetValue:
      { The canonical wire form of a set is the comma-joined string produced
        by SetToJson, at the root exactly as inside an object, so the root
        expects a string - which is what lets Serialize<TMySet> /
        Deserialize<TMySet> round-trip. }
      if not (AJson is TJSONString) then Expected := 'string';
  end;
  if Expected <> '' then
    raise EJsonInputError.CreateFmt('Expected JSON %s for %s but found %s',
      [Expected, UTF8ToString(APlan.TypeInfo.Name), JsonShapeName(AJson)]);
end;

{ Every date in one member resolves together: the member itself, a
  nullable's inner value, a list element, a dictionary value. They share an
  owner and a member name, so they share a policy - saying "dates in
  CreatedAt are Unix seconds" should not have to be said four times. }
class procedure TJsonEngine.ApplyDatePolicies(APlan: TJsonTypePlan;
  AFP: TJsonFieldPlan; const AAttributes: TArray<TCustomAttribute>);
var
  A: TCustomAttribute;
  Found: JsonDateTimeFormatAttribute;
begin
  ResolveDatePolicy(AFP.Kind, APlan.TypeKey, AFP.FieldName,
    AFP.DateFormat, AFP.DatePattern);
  ResolveDatePolicy(AFP.InnerKind, APlan.TypeKey, AFP.FieldName,
    AFP.InnerDateFormat, AFP.InnerDatePattern);
  ResolveDatePolicy(AFP.ElemKind, APlan.TypeKey, AFP.FieldName,
    AFP.ElemDateFormat, AFP.ElemDatePattern);
  ResolveDatePolicy(AFP.DictValKind, APlan.TypeKey, AFP.FieldName,
    AFP.DictValDateFormat, AFP.DictValDatePattern);
  Found := nil;
  for A in AAttributes do
    if A is JsonDateTimeFormatAttribute then
      Found := JsonDateTimeFormatAttribute(A);
  if Found = nil then Exit;
  { A member attribute beats every registration: it is the most specific
    statement anyone can make about this member. }
  AFP.DateFormat := Found.Format;
  AFP.DatePattern := Found.Pattern;
  AFP.InnerDateFormat := Found.Format;
  AFP.InnerDatePattern := Found.Pattern;
  AFP.ElemDateFormat := Found.Format;
  AFP.ElemDatePattern := Found.Pattern;
  AFP.DictValDateFormat := Found.Format;
  AFP.DictValDatePattern := Found.Pattern;
end;

{ A member whose type cannot be serialized at all is REFUSED, by name, with
  the remedy. Skipping it would leave the member silently absent from the
  document and, on reading back, at whatever the constructor put there: a
  round trip that loses data and reports success, which is the one thing a
  serializer must never do.

  The decision is TSerializationTypes.UnsupportedReason, shared by every
  format, so a pointer is refused for the same reason in all of them. It is
  asked only after [JsonIgnore], the member rules and every custom serializer
  registration have had their say - so a caller who wants one of these types
  can always have it, by saying how. }
procedure RefuseUnsupportedMember(const AMember: string; ATypeInfo: PTypeInfo);
var
  Why: string;
begin
  Why := TSerializationTypes.UnsupportedReason(ATypeInfo);
  if Why = '' then Exit;
  raise EJsonError.CreateFmt(
    '%s %s. Leave it out with [JsonIgnore], or register a JSON type ' +
    'serializer for its type.', [AMember, Why]);
end;

class procedure TJsonEngine.BuildFieldPlan(APlan: TJsonTypePlan; AField: TRttiField);
var
  FP: TJsonFieldPlan;
  A: TCustomAttribute;
  attrName, ownerUnit: string;
  attrSerCls, ruleSerCls, serCls: TJsonValueSerializerClass;
  ruleSerInst: TCustomJsonValueSerializer;
  ti, inner: PTypeInfo;
  elemType: TRttiType;
  fieldMapping: TArray<string>;
  addM: TRttiMethod;
  ruleName, generalName: string;
  ruleIgnore: Boolean;
  ruleHasMemberStrategy, ruleHasRecursionPolicy: Boolean;
  ruleMemberStrategy: TJsonMemberStrategy;
  ruleRecursionPolicy: TJsonRecursiveReferencePolicy;
begin
  { Some members have no RTTI type at all - Data.FmtBcd's
    TBcd.Fraction: array[0..N] of Byte is the case that exposed this, and
    extended RTTI reports FieldType = nil for it.  Dereferencing that nil to
    read Handle raised an access violation which the plan builder wrapped as
    'Cannot build member plan for TBcd.Fraction', making EVERY type that
    contained a TBcd unserializable.

    It is no longer skipped. A member that is silently absent from the
    document comes back as whatever the constructor left there, and that is a
    loss nothing reports. [JsonIgnore] still leaves it out, deliberately;
    without it the member is refused by name. }
  if AField.FieldType = nil then
  begin
    for A in AField.GetAttributes do
      if A is JsonIgnoreAttribute then Exit;
    RefuseUnsupportedMember(AField.Name, nil);
  end;
  ti := AField.FieldType.Handle;
  attrName := '';
  attrSerCls := nil;

  for A in AField.GetAttributes do
  begin
    if A is JsonIgnoreAttribute then Exit;
    if A is JsonNameAttribute then attrName := JsonNameAttribute(A).Name;
    if A is JsonSerializerAttribute then
      attrSerCls := JsonSerializerAttribute(A).SerializerClass;
  end;

  FP := TJsonFieldPlan.Create;
  { Owned here until the type plan takes it: a refusal below - an
    unsupported member, a failing element plan - would otherwise leave it,
    and what it already holds, owned by nothing, on every retry. }
  try
    FP.Field := AField;
    FP.FieldName := AField.Name;
    FP.DeclaringTypeName := AField.Parent.Name;
    FP.Offset := AField.Offset;
    FP.FieldTypeInfo := ti;
    FP.Context.OwnerTypeInfo := APlan.TypeInfo;
    FP.Context.MemberName := AField.Name;
    FP.Context.DeclaredTypeInfo := ti;
    FP.Kind := ClassifyType(ti);
    FP.DirectScalarWrite := FP.Kind in [TJsonKind.IntegerValue, TJsonKind.Int64Value, TJsonKind.FloatValue, TJsonKind.CurrencyValue,
      TJsonKind.EnumValue, TJsonKind.SetValue, TJsonKind.GuidValue, TJsonKind.DateValue, TJsonKind.TimeValue, TJsonKind.DateTimeValue];
    // Boolean aliases can have a different storage width from Boolean; keep
    // those on RTTI unless their returned TValue exactly matches the field.
    if ti = System.TypeInfo(Boolean) then FP.DirectScalarWrite := True;

    ownerUnit := APlan.UnitName;
    FP.OwnerUnitName := ownerUnit;
    ResolveOverride(APlan.TypeInfo, APlan.ClassType, ownerUnit, APlan.TypeKey,
      AField.Name, ruleName, ruleSerCls, ruleSerInst, ruleIgnore, ruleHasMemberStrategy,
      ruleMemberStrategy, ruleHasRecursionPolicy, ruleRecursionPolicy);
    if ruleIgnore then Exit;
    FP.HasMemberStrategy := ruleHasMemberStrategy;
    FP.MemberStrategy := ruleMemberStrategy;
    FP.HasRecursionPolicy := ruleHasRecursionPolicy;
    FP.RecursionPolicy := ruleRecursionPolicy;

    // name precedence: attribute first, then field rules, then the general
    // [SerializationName] - verbatim, no naming strategy applied - then the
    // naming strategy, then default
    if attrName <> '' then FP.JsonName := attrName
    else if ruleName <> '' then FP.JsonName := ruleName
    else if TSerializationMetadata.GeneralName(AField, generalName) then FP.JsonName := generalName
    else if ResolveNaming(APlan.ClassType, ownerUnit, APlan.TypeKey) = TJsonNaming.SnakeCase then FP.JsonName := SnakeCase(AField.Name)
    else FP.JsonName := DefaultJsonName(AField.Name);

    // serializer precedence: attribute, rule, type serializer
    serCls := attrSerCls;
    if (serCls = nil) and (ruleSerInst = nil) then serCls := ruleSerCls;

    if FP.Kind = TJsonKind.NullableValue then
    begin
      FP.NullableAccess := NullableAccessFor(ti);
      inner := FP.NullableAccess.ValueType;
      FP.InnerTypeInfo := inner;
      FP.InnerKind := ClassifyType(inner);
      if (serCls = nil) and (ruleSerInst = nil) then FindContextSerializer(APlan.TypeInfo, inner, serCls);
      if (serCls = nil) and (ruleSerInst = nil) then FindRegisteredTypeSerializer(inner, serCls);
      if (serCls = nil) and (ruleSerInst = nil) then
        RefuseUnsupportedMember(AField.Name, inner);
      if FP.InnerKind = TJsonKind.EnumValue then FP.EnumMapping := EnumMappingFor(inner)
      else if FP.InnerKind = TJsonKind.SetValue then
      begin
        FP.SetElemTypeInfo := inner.TypeData.CompType^;
        FP.SetElemMapping := EnumMappingFor(FP.SetElemTypeInfo);
      end;
      if (serCls <> nil) or (ruleSerInst <> nil) then
      begin
        FP.Serializer := PickSerializer(serCls, ruleSerInst);
        FP.SerializerOnInner := True;
      end;
    end
    else
    begin
      if (serCls = nil) and (ruleSerInst = nil) then FindContextSerializer(APlan.TypeInfo, ti, serCls);
      if (serCls = nil) and (ruleSerInst = nil) then FindRegisteredTypeSerializer(ti, serCls);
      if (serCls = nil) and (ruleSerInst = nil) then
        RefuseUnsupportedMember(AField.Name, ti);
      if (serCls <> nil) or (ruleSerInst <> nil) then
      begin
        FP.Serializer := PickSerializer(serCls, ruleSerInst);
        FP.Kind := TJsonKind.CustomSerializer;
      end
      else if ti.Kind in [tkDynArray, tkArray] then
      begin
        { This took the container path, whose first step casts the member's
          type to a class - so every TArray<T> field raised 'Invalid class
          typecast' while its plan was built, and the type could not be
          serialized at all. }
        FP.WholeMember := BuildMemberPlan(ti);
        FP.WholeMember.Context := FP.Context;
      end
      else
      case FP.Kind of
        TJsonKind.EnumValue: FP.EnumMapping := EnumMappingFor(ti);
        TJsonKind.SetValue:
        begin
          FP.SetElemTypeInfo := ti.TypeData.CompType^;
          FP.SetElemMapping := EnumMappingFor(FP.SetElemTypeInfo);
        end;
        TJsonKind.ObjectValue:
        begin
          FP.FieldClass := ti.TypeData.ClassType;
        end;
        TJsonKind.ListValue:
        begin
          FP.ContainerPlan := GetPlan(ti, ownerUnit);
          if not TSerializationTypes.TryGetListAccess(ti, FP.ListAccess) then
            raise EJsonError.CreateFmt('%s is a list with no usable methods to ' +
              'add to it and read it.', [UTF8ToString(ti.Name)]);
          FP.ContainerClearMethod := FP.ListAccess.ClearMethod;
          addM := FP.ListAccess.AddMethod;
          FP.ListAddMethod := addM;
          FP.ListToArrayMethod := FP.ListAccess.ToArrayMethod;
          if (addM <> nil) and (Length(addM.GetParameters) >= 1) then
          begin
            elemType := addM.GetParameters[0].ParamType;
            if elemType <> nil then
            begin
              FP.ElemTypeInfo := elemType.Handle;
              FP.ElemKind := ClassifyType(FP.ElemTypeInfo);
              if FP.ElemKind = TJsonKind.ObjectValue then
              begin
                FP.ElemClass := FP.ElemTypeInfo.TypeData.ClassType;
                FP.ElemPlan := GetPlan(FP.ElemTypeInfo);
              end
              else if FP.ElemKind = TJsonKind.EnumValue then FP.ElemMapping := EnumMappingFor(FP.ElemTypeInfo);
              if FindRegisteredTypeSerializer(FP.ElemTypeInfo, serCls) then
                FP.ElemSerializer := ResolveSerializer(serCls);
              FP.ElemMember := BuildMemberPlan(FP.ElemTypeInfo);
              FP.ElemMember.Context := FP.Context;
              FP.ElemMember.Context.DeclaredTypeInfo := FP.ElemTypeInfo;
              if FindContextSerializer(APlan.TypeInfo, FP.ElemTypeInfo, serCls) then
              begin
                FP.ElemMember.Kind := TJsonKind.CustomSerializer;
                FP.ElemMember.Serializer := ResolveSerializer(serCls);
              end;
            end;
          end;
        end;
        TJsonKind.DictionaryValue:
        begin
          FP.ContainerPlan := GetPlan(ti, ownerUnit);
          FP.ContainerClearMethod :=
            (AField.FieldType as TRttiInstanceType).GetMethod('Clear');
          FP.DictAccess := BuildDictAccess(ti);
          addM := (AField.FieldType as TRttiInstanceType).GetMethod('Add');
          FP.DictAddMethod := addM;
          if (addM <> nil) and (Length(addM.GetParameters) >= 2) then
          begin
            FP.DictKeyTypeInfo := addM.GetParameters[0].ParamType.Handle;
            FP.DictKeyKind := ClassifyType(FP.DictKeyTypeInfo);
            if FP.DictKeyKind = TJsonKind.EnumValue then FP.DictKeyMapping := EnumMappingFor(FP.DictKeyTypeInfo);
            if FindRegisteredTypeSerializer(FP.DictKeyTypeInfo, serCls) then
              FP.DictKeySerializer := ResolveSerializer(serCls);
            FP.DictKeyMember := BuildMemberPlan(FP.DictKeyTypeInfo);
            FP.DictKeyMember.Context := FP.Context;
            FP.DictKeyMember.Context.DeclaredTypeInfo := FP.DictKeyTypeInfo;
            FP.DictValTypeInfo := addM.GetParameters[1].ParamType.Handle;
            FP.DictValKind := ClassifyType(FP.DictValTypeInfo);
            if FP.DictValKind = TJsonKind.ObjectValue then FP.DictValClass := FP.DictValTypeInfo.TypeData.ClassType
            else if FP.DictValKind = TJsonKind.EnumValue then FP.DictValMapping := EnumMappingFor(FP.DictValTypeInfo);
            if FindRegisteredTypeSerializer(FP.DictValTypeInfo, serCls) then
              FP.DictValSerializer := ResolveSerializer(serCls);
            FP.DictValMember := BuildMemberPlan(FP.DictValTypeInfo);
            FP.DictValMember.Context := FP.Context;
            FP.DictValMember.Context.DeclaredTypeInfo := FP.DictValTypeInfo;
            if FindContextSerializer(APlan.TypeInfo, FP.DictValTypeInfo, serCls) then
            begin
              FP.DictValMember.Kind := TJsonKind.CustomSerializer;
              FP.DictValMember.Serializer := ResolveSerializer(serCls);
            end;
          end;
        end;
      end;
    end;

    ApplyGeneralEnum(FP, AField);
    if FieldEnumMappingFor(APlan.TypeKey, AField.Name, fieldMapping) then
      case FP.Kind of
        TJsonKind.EnumValue: FP.EnumMapping := fieldMapping;
        TJsonKind.SetValue: FP.SetElemMapping := fieldMapping;
        TJsonKind.NullableValue:
          if FP.InnerKind = TJsonKind.EnumValue then FP.EnumMapping := fieldMapping
          else if FP.InnerKind = TJsonKind.SetValue then FP.SetElemMapping := fieldMapping;
        TJsonKind.ListValue: if FP.ElemKind = TJsonKind.EnumValue then FP.ElemMapping := fieldMapping;
      end;
    ApplyDatePolicies(APlan, FP, AField.GetAttributes);
    NormalizeSetMapping(FP);

    APlan.Fields.Add(FP);
    FP := nil;
  finally
    FP.Free;
  end;
end;

class procedure TJsonEngine.BuildPropertyPlan(APlan: TJsonTypePlan;
  AProp: TRttiProperty);
var
  FP: TJsonFieldPlan;
  A: TCustomAttribute;
  AttrName, OwnerUnit, RuleName, GeneralName: string;
  AttrSerCls, RuleSerCls, SerCls: TJsonValueSerializerClass;
  RuleSerInst: TCustomJsonValueSerializer;
  Ti, Inner: PTypeInfo;
  ElemType: TRttiType;
  AddM: TRttiMethod;
  RuleIgnore: Boolean;
  HasUnnamedSetElement: Boolean;
  RuleHasMemberStrategy, RuleHasRecursionPolicy: Boolean;
  RuleMemberStrategy: TJsonMemberStrategy;
  RuleRecursionPolicy: TJsonRecursiveReferencePolicy;
begin
  if not AProp.IsReadable then Exit;
  { Same guard as BuildFieldPlan: a property whose RTTI carries no type is
    skipped rather than dereferenced. }
  if AProp.PropertyType = nil then Exit;
  Ti := AProp.PropertyType.Handle;
  AttrName := '';
  AttrSerCls := nil;
  HasUnnamedSetElement := (Ti.Kind = tkSet) and
    ((Ti.TypeData.CompType = nil) or
     UTF8ToString(Ti.TypeData.CompType^.Name).StartsWith(':'));
  if not HasUnnamedSetElement then
    for A in AProp.GetAttributes do
    begin
      if A is JsonIgnoreAttribute then Exit;
      if A is JsonNameAttribute then AttrName := JsonNameAttribute(A).Name;
      if A is JsonSerializerAttribute then
        AttrSerCls := JsonSerializerAttribute(A).SerializerClass;
    end;

  FP := TJsonFieldPlan.Create;
  try
    FP.Prop := AProp;
    FP.IsProperty := True;
    FP.CanRead := AProp.IsReadable;
    FP.CanWrite := AProp.IsWritable;
    FP.FieldName := AProp.Name;
    FP.DeclaringTypeName := AProp.Parent.Name;
    FP.FieldTypeInfo := Ti;
    FP.Context.OwnerTypeInfo := APlan.TypeInfo;
    FP.Context.MemberName := AProp.Name;
    FP.Context.DeclaredTypeInfo := Ti;
    FP.Kind := ClassifyType(Ti);

    OwnerUnit := APlan.UnitName;
    FP.OwnerUnitName := OwnerUnit;
    ResolveOverride(APlan.TypeInfo, APlan.ClassType, OwnerUnit, APlan.TypeKey,
      AProp.Name, RuleName, RuleSerCls, RuleSerInst, RuleIgnore, RuleHasMemberStrategy,
      RuleMemberStrategy, RuleHasRecursionPolicy, RuleRecursionPolicy);
    if RuleIgnore then Exit;
    FP.HasMemberStrategy := RuleHasMemberStrategy;
    FP.MemberStrategy := RuleMemberStrategy;
    FP.HasRecursionPolicy := RuleHasRecursionPolicy;
    FP.RecursionPolicy := RuleRecursionPolicy;
    if AttrName <> '' then FP.JsonName := AttrName
    else if RuleName <> '' then FP.JsonName := RuleName
    else if TSerializationMetadata.GeneralName(AProp, GeneralName) then
      FP.JsonName := GeneralName
    else if ResolveNaming(APlan.ClassType, OwnerUnit, APlan.TypeKey) = TJsonNaming.SnakeCase then
      FP.JsonName := SnakeCase(AProp.Name)
    else FP.JsonName := DefaultJsonName(AProp.Name);

    SerCls := AttrSerCls;
    if (SerCls = nil) and (RuleSerInst = nil) then SerCls := RuleSerCls;
    if FP.Kind = TJsonKind.NullableValue then
    begin
      FP.NullableAccess := NullableAccessFor(Ti);
      Inner := FP.NullableAccess.ValueType;
      FP.InnerTypeInfo := Inner;
      FP.InnerKind := ClassifyType(Inner);
      if (SerCls = nil) and (RuleSerInst = nil) then FindContextSerializer(APlan.TypeInfo, Inner, SerCls);
      if (SerCls = nil) and (RuleSerInst = nil) then FindRegisteredTypeSerializer(Inner, SerCls);
      if (SerCls = nil) and (RuleSerInst = nil) then
        RefuseUnsupportedMember(AProp.Name, Inner);
      if FP.InnerKind = TJsonKind.EnumValue then FP.EnumMapping := EnumMappingFor(Inner);
      if (SerCls <> nil) or (RuleSerInst <> nil) then
      begin
        FP.Serializer := PickSerializer(SerCls, RuleSerInst);
        FP.SerializerOnInner := True;
      end;
    end
    else
    begin
      if not HasUnnamedSetElement then
      begin
        if (SerCls = nil) and (RuleSerInst = nil) then FindContextSerializer(APlan.TypeInfo, Ti, SerCls);
        if (SerCls = nil) and (RuleSerInst = nil) then FindRegisteredTypeSerializer(Ti, SerCls);
      end;
      if (SerCls = nil) and (RuleSerInst = nil) then
        RefuseUnsupportedMember(AProp.Name, Ti);
      if (SerCls <> nil) or (RuleSerInst <> nil) then
      begin
        FP.Serializer := PickSerializer(SerCls, RuleSerInst);
        FP.Kind := TJsonKind.CustomSerializer;
      end
      else if Ti.Kind in [tkDynArray, tkArray] then
      begin
        FP.WholeMember := BuildMemberPlan(Ti);
        FP.WholeMember.Context := FP.Context;
      end
      else case FP.Kind of
        TJsonKind.EnumValue: FP.EnumMapping := EnumMappingFor(Ti);
        TJsonKind.SetValue:
        begin
          FP.SetElemTypeInfo := Ti.TypeData.CompType^;
          if not HasUnnamedSetElement then
            FP.SetElemMapping := EnumMappingFor(FP.SetElemTypeInfo);
        end;
        TJsonKind.ObjectValue:
        begin
          FP.FieldClass := Ti.TypeData.ClassType;
        end;
        TJsonKind.ListValue:
        begin
          FP.ContainerPlan := GetPlan(Ti, OwnerUnit);
          if not TSerializationTypes.TryGetListAccess(Ti, FP.ListAccess) then
            raise EJsonError.CreateFmt('%s is a list with no usable methods ' +
              'to add to it and read it.', [UTF8ToString(Ti.Name)]);
          FP.ContainerClearMethod := FP.ListAccess.ClearMethod;
          AddM := FP.ListAccess.AddMethod;
          FP.ListAddMethod := AddM;
          FP.ListToArrayMethod := FP.ListAccess.ToArrayMethod;
          if (AddM <> nil) and (Length(AddM.GetParameters) >= 1) then
          begin
            ElemType := AddM.GetParameters[0].ParamType;
            FP.ElemTypeInfo := ElemType.Handle;
            FP.ElemKind := ClassifyType(FP.ElemTypeInfo);
            FP.ElemMember := BuildMemberPlan(FP.ElemTypeInfo);
            FP.ElemMember.Context := FP.Context;
            FP.ElemMember.Context.DeclaredTypeInfo := FP.ElemTypeInfo;
            if FindContextSerializer(APlan.TypeInfo, FP.ElemTypeInfo, SerCls) then
            begin
              FP.ElemMember.Kind := TJsonKind.CustomSerializer;
              FP.ElemMember.Serializer := ResolveSerializer(SerCls);
            end;
          end;
        end;
        TJsonKind.DictionaryValue:
        begin
          FP.ContainerPlan := GetPlan(Ti, OwnerUnit);
          FP.ContainerClearMethod :=
            (AProp.PropertyType as TRttiInstanceType).GetMethod('Clear');
          FP.DictAccess := BuildDictAccess(Ti);
          AddM := (AProp.PropertyType as TRttiInstanceType).GetMethod('Add');
          FP.DictAddMethod := AddM;
          if (AddM <> nil) and (Length(AddM.GetParameters) >= 2) then
          begin
            FP.DictKeyTypeInfo := AddM.GetParameters[0].ParamType.Handle;
            FP.DictValTypeInfo := AddM.GetParameters[1].ParamType.Handle;
            FP.DictKeyKind := ClassifyType(FP.DictKeyTypeInfo);
            FP.DictValKind := ClassifyType(FP.DictValTypeInfo);
            FP.DictKeyMember := BuildMemberPlan(FP.DictKeyTypeInfo);
            FP.DictValMember := BuildMemberPlan(FP.DictValTypeInfo);
            FP.DictKeyMember.Context := FP.Context;
            FP.DictKeyMember.Context.DeclaredTypeInfo := FP.DictKeyTypeInfo;
            FP.DictValMember.Context := FP.Context;
            FP.DictValMember.Context.DeclaredTypeInfo := FP.DictValTypeInfo;
            if FindContextSerializer(APlan.TypeInfo, FP.DictValTypeInfo, SerCls) then
            begin
              FP.DictValMember.Kind := TJsonKind.CustomSerializer;
              FP.DictValMember.Serializer := ResolveSerializer(SerCls);
            end;
          end;
        end;
      end;
    end;
    ApplyGeneralEnum(FP, AProp);
    ApplyDatePolicies(APlan, FP, AProp.GetAttributes);
    NormalizeSetMapping(FP);
    APlan.Fields.Add(FP);
    FP := nil;
  finally
    FP.Free;
  end;
end;

{ enum / set }

class function TJsonEngine.EnumToJson(ATypeInfo: PTypeInfo; AOrdinal: Integer; const AMapping: TArray<string>): TJSONValue;
begin
  if ATypeInfo.Kind <> tkEnumeration then
    Exit(TJSONString.Create(TSerializationTypes.SetElementText(ATypeInfo, AOrdinal)));
  if AMapping <> nil then
  begin
    if (AOrdinal < 0) or (AOrdinal > High(AMapping)) then
      raise EJsonError.CreateFmt('Mapped enum %s ordinal %d out of range 0..%d', [UTF8ToString(ATypeInfo.Name), AOrdinal, High(AMapping)]);
    Result := TJSONString.Create(AMapping[AOrdinal]);
  end
  else
    Result := TJSONString.Create(GetEnumName(ATypeInfo, AOrdinal));
end;

class function TJsonEngine.JsonToEnumOrdinal(ATypeInfo: PTypeInfo; const AJson: TJSONValue; const AMapping: TArray<string>): Integer;
var
  S: string;
  I: Integer;
begin
  S := AJson.Value;
  { A set of an integer subrange or of characters: members are ordinals. }
  if ATypeInfo.Kind <> tkEnumeration then
  begin
    if not TSerializationTypes.TrySetElementOrdinal(ATypeInfo, Trim(S), Result) then
      raise EJsonInputError.CreateFmt('Value "%s" is not a member of %s', [S, UTF8ToString(ATypeInfo.Name)]);
    Exit;
  end;
  if AMapping <> nil then
  begin
    for I := 0 to Integer(High(AMapping)) do
      if SameText(AMapping[I], S) then Exit(I);
    raise EJsonInputError.CreateFmt('Value "%s" not a valid mapped code for %s', [S, UTF8ToString(ATypeInfo.Name)]);
  end;
  Result := GetEnumValue(ATypeInfo, S);
  if Result < 0 then
    raise EJsonInputError.CreateFmt('Value "%s" not a valid name for enum %s', [S, UTF8ToString(ATypeInfo.Name)]);
end;

{ Through TSerializationTypes, which knows where a set's bits start. This
  used to count from ordinal 0, so in a set of 10..19 the value 10 - bit 2
  - was read as ordinal 2 and written as whatever name that had. }
class function TJsonEngine.SetToJson(AElemTypeInfo: PTypeInfo; const AValue: TValue; const AMapping: TArray<string>): TJSONValue;
var
  parts: TArray<string>;
  ords: TArray<Integer>;
  i, o: Integer;
begin
  ords := TSerializationTypes.SetOrdinals(AValue.TypeInfo, AValue);
  SetLength(parts, Length(ords));
  for i := 0 to Integer(High(ords)) do
  begin
    o := ords[i];
    if AMapping <> nil then
    begin
      { Same mapping validation quality as EnumToJson: never index a
        positional mapping out of range. }
      if (o < 0) or (o > High(AMapping)) then
        raise EJsonError.CreateFmt(
          'Mapped set element %s ordinal %d out of range 0..%d',
          [UTF8ToString(AElemTypeInfo.Name), o, High(AMapping)]);
      parts[i] := AMapping[o];
    end
    else parts[i] := TSerializationTypes.SetElementText(AElemTypeInfo, o);
  end;
  Result := TJSONString.Create(string.Join(',', parts));
end;

class function TJsonEngine.JsonToSet(ASetTypeInfo, AElemTypeInfo: PTypeInfo; const AJson: TJSONValue; const AMapping: TArray<string>): TValue;
var
  S, nm, why: string;
  names: TArray<string>;
  ords: TArray<Integer>;
  elemJson: TJSONString;
begin
  ords := nil;
  S := Trim(AJson.Value);
  if S <> '' then
  begin
    names := S.Split([',']);
    for nm in names do
    begin
      if Trim(nm) = '' then Continue;
      { Owned here and freed below: one temporary per set element. }
      elemJson := TJSONString.Create(Trim(nm));
      try
        ords := ords + [JsonToEnumOrdinal(AElemTypeInfo, elemJson, AMapping)];
      finally
        elemJson.Free;
      end;
    end;
  end;
  { A positional mapping registered with MORE entries than its enum has
    values yields an ordinal outside the element type, so this is checked
    rather than trusted - it is a write, not a read. }
  if not TSerializationTypes.TryMakeSet(ASetTypeInfo, ords, Result, why) then
    raise EJsonError.CreateFmt('"%s" is not a %s: %s',
      [S, UTF8ToString(ASetTypeInfo.Name), why]);
end;

{ scalar value <-> json }

{ The date policy is a plan value, not a lookup: every caller either has a
  plan and passes what it resolved, or has no plan and gets Iso8601, which
  is what the library always produced. }
function JsonDateToWire(AKind: TJsonKind; AValue: TDateTime;
  AFormat: TJsonDateTimeFormat; const APattern: string): TJSONValue;
var
  Millis, Seconds: Int64;
begin
  case AFormat of
    TJsonDateTimeFormat.UnixSeconds, TJsonDateTimeFormat.UnixMilliseconds:
      begin
        { Through Core, which follows Delphi's encoding before 1899-12-30:
          the linear (AValue - UnixDateDelta) * MSecsPerDay put such an
          instant a day early. Outside the years 1 to 9999, which the
          reader refuses, it is refused here. }
        if not TStructuralText.TryDateTimeToUnixMillis(AValue, Millis) then
          TStructuralText.CheckDateTime(AValue);
        if AFormat = TJsonDateTimeFormat.UnixMilliseconds then
          Exit(TJSONNumber.Create(Millis));
        { The second the instant is in, by floor: half a second before the
          epoch is second -1. DateTimeToUnix truncated it to 0. }
        Seconds := Millis div 1000;
        if Millis mod 1000 < 0 then Dec(Seconds);
        Exit(TJSONNumber.Create(Seconds));
      end;
    TJsonDateTimeFormat.Custom:
      begin
        { FormatDateTime renders a day before year 1 as 0000-00-00, which is
          not even the value. }
        TStructuralText.CheckDateTime(AValue);
        Exit(TJSONString.Create(
          FormatDateTime(APattern, AValue, TFormatSettings.Invariant)));
      end;
  end;
  case AKind of
    TJsonKind.DateValue:
      begin
        TStructuralText.CheckDateTime(AValue);
        Result := TJSONString.Create(
          FormatDateTime('yyyy-mm-dd', AValue, TFormatSettings.Invariant));
      end;
    { The milliseconds are written when there are any. hh:nn:ss alone lost
      them, and a whole second is still written exactly as before. }
    TJsonKind.TimeValue:
      if MilliSecondOf(AValue) = 0 then
        Result := TJSONString.Create(
          FormatDateTime('hh:nn:ss', AValue, TFormatSettings.Invariant))
      else
        Result := TJSONString.Create(TStructuralText.EncodeTime(AValue));
  else
    { NO OFFSET. A TDateTime has no time zone, and DateToISO8601(AValue,
      False) appended the zone of whichever machine wrote the document - a
      fact about the writer's clock, not about the value. }
    Result := TJSONString.Create(TStructuralText.EncodeDateTime(AValue));
  end;
end;

function JsonWireToDate(AKind: TJsonKind; const AJson: TJSONValue;
  AFormat: TJsonDateTimeFormat; const APattern: string): Double;
var
  I64: Int64;
  D: TDateTime;
begin
  case AFormat of
    TJsonDateTimeFormat.UnixSeconds:
      begin
        if not TryStrToInt64(AJson.Value, I64) or
           not TStructuralText.TryUnixSecondsToDateTime(I64, D) then
          raise EJsonInputError.CreateFmt(
            '"%s" is not a Unix second count a TDateTime holds.', [AJson.Value]);
        Exit(D);
      end;
    TJsonDateTimeFormat.UnixMilliseconds:
      begin
        if not TryStrToInt64(AJson.Value, I64) or
           not TStructuralText.TryUnixMillisToDateTime(I64, D) then
          raise EJsonInputError.CreateFmt(
            '"%s" is not a Unix millisecond count a TDateTime holds.',
            [AJson.Value]);
        Exit(D);
      end;
    TJsonDateTimeFormat.Custom:
      begin
        { The pattern the writer wrote with, then the RTL's invariant
          reading, which is what 0.9 used and still reads what it read. }
        if not TStructuralText.TryDecodePattern(AJson.Value, APattern, D) and
           not TryStrToDateTime(AJson.Value, D, TFormatSettings.Invariant) then
          raise EJsonInputError.CreateFmt(
            '"%s" does not match the configured pattern "%s".',
            [AJson.Value, APattern]);
        Exit(D);
      end;
  end;
  case AKind of
    TJsonKind.DateValue: Result := Trunc(TStructuralText.DecodeIso8601(AJson.Value));
    { hh:nn:ss[.zzz] decoded as a time of day, by EncodeTime. Going through
      a whole date and taking the fraction lost the low bits: 14:35:07.123
      came back 1.5E-12 away from itself. }
    TJsonKind.TimeValue:
      if not TStructuralText.TryDecodeTime(AJson.Value, D) then
        Result := Frac(TStructuralText.DecodeIso8601('2000-01-01T' + AJson.Value))
      else
        Result := D;
  else
    { An offset in the text is honoured by normalising to UTC, which is the
      one answer that does not depend on the machine reading it. Text
      without one is taken as written. ISO8601ToDate(.., False) did the
      opposite of both: it shifted zone-less text by the reader's own
      offset, so the same document read differently in every time zone. }
    Result := TStructuralText.DecodeIso8601(AJson.Value);
  end;
end;

class function TJsonEngine.ValueToJson(AKind: TJsonKind; ATypeInfo: PTypeInfo; const AValue: TValue; const AMapping: TArray<string>;
  ADateFormat: TJsonDateTimeFormat; const ADatePattern: string): TJSONValue;
var
  g: TGUID;
begin
  case AKind of
    TJsonKind.BooleanValue: Result := TJSONBool.Create(AValue.AsBoolean);
    { Digits with the sign the TYPE gives them. AsInteger on a Cardinal and
      AsInt64 on a UInt64 both reinterpret the bits, which wrote 4294967295
      as -1: it read back into the same field, and it was false. }
    TJsonKind.IntegerValue, TJsonKind.Int64Value:
      Result := TJSONNumber.Create(TSerializationTypes.IntegerText(AValue));
    TJsonKind.FloatValue: Result := TJSONNumber.Create(JsonFloatText(ATypeInfo, AValue));
    TJsonKind.CurrencyValue:
      Result := TJSONNumber.Create(JsonCurrencyText(PCurrency(AValue.GetReferenceToRawData)^));
    TJsonKind.StringValue: Result := TJSONString.Create(AValue.AsString);
    TJsonKind.GuidValue: begin AValue.ExtractRawData(@g); Result := TJSONString.Create(GuidToWire(g)); end;
    TJsonKind.DateValue, TJsonKind.TimeValue, TJsonKind.DateTimeValue:
      Result := JsonDateToWire(AKind, AValue.AsExtended, ADateFormat,
        ADatePattern);
    TJsonKind.EnumValue: Result := EnumToJson(ATypeInfo, Integer(AValue.AsOrdinal), AMapping);
    TJsonKind.SetValue: Result := SetToJson(ATypeInfo.TypeData.CompType^, AValue, AMapping);
    TJsonKind.VariantValue: Result := VariantToJson(AValue.AsVariant);
  else
    raise EJsonError.CreateFmt('Cannot serialize kind %d (%s)', [Ord(AKind), UTF8ToString(ATypeInfo.Name)]);
  end;
  { Every scalar in the document passes through here, which makes this the
    one place that has to charge them.  A budgeted operation therefore stops
    growing within one value of its ceiling. }
  ChargeJsonValue(Result);
end;

class function TJsonEngine.JsonToValue(AKind: TJsonKind; ATypeInfo: PTypeInfo; const AJson: TJSONValue; const AMapping: TArray<string>;
  ADateFormat: TJsonDateTimeFormat; const ADatePattern: string): TValue;
var
  d: Double; c: Currency; g: TGUID; ordv: Integer; s, Why: string;
begin
  case AKind of
    TJsonKind.BooleanValue: Result := TValue.From<Boolean>((AJson as TJSONBool).AsBoolean);
    TJsonKind.IntegerValue, TJsonKind.Int64Value:
      Result := JsonIntegerValue(ATypeInfo, (AJson as TJSONNumber).Value);
    TJsonKind.FloatValue:
      Result := JsonFloatValue(ATypeInfo, (AJson as TJSONNumber).Value);
    TJsonKind.CurrencyValue:
      begin
        { From the digits, not through a Double: Currency has four decimal
          places and nineteen significant digits, and a Double has neither. }
        if not TryStrToCurr((AJson as TJSONNumber).Value, c, TFormatSettings.Invariant) then
        begin
          { An exponent form, 1.5e3: correctly rounded, not the RTL's. }
          if not TStructuralText.TryParseFloat((AJson as TJSONNumber).Value, d) then
            raise EJsonInputError.CreateFmt('%s is not a number.',
              [(AJson as TJSONNumber).Value]);
          { The bounds are compared at the platform's Extended precision,
            which on Win64 is a Double. }
          {$WARN LOST_EXTENDED_PRECISION OFF}
          if (d < -922337203685477.5808) or (d > 922337203685477.5807) then
          {$WARN LOST_EXTENDED_PRECISION ON}
            raise EJsonInputError.CreateFmt('%s does not fit in a Currency.',
              [(AJson as TJSONNumber).Value]);
          c := d;
        end;
        TValue.Make(@c, ATypeInfo, Result);
      end;
    TJsonKind.VariantValue: Result := JsonToVariantValue(ATypeInfo, AJson);
    TJsonKind.StringValue:
      begin
        { Through the shared conversion, which encodes into the member's own
          code page. TValue.Make(@s, ...) handed a UnicodeString to an
          AnsiString, a ShortString or a WideString as if it were one, and
          what came back was whatever those bytes meant to the other type. }
        s := AJson.Value;
        if not TSerializationTypes.TryStringFromText(ATypeInfo, s, Result, Why) then
          raise EJsonInputError.Create(Why + '.');
      end;
    TJsonKind.GuidValue: begin g := WireToGuid(AJson.Value); TValue.Make(@g, ATypeInfo, Result); end;
    TJsonKind.DateValue:
      begin d := JsonWireToDate(AKind, AJson, ADateFormat, ADatePattern);
        TValue.Make(@d, System.TypeInfo(TDate), Result); end;
    TJsonKind.TimeValue:
      begin d := JsonWireToDate(AKind, AJson, ADateFormat, ADatePattern);
        TValue.Make(@d, System.TypeInfo(TTime), Result); end;
    TJsonKind.DateTimeValue:
      begin d := JsonWireToDate(AKind, AJson, ADateFormat, ADatePattern);
        TValue.Make(@d, System.TypeInfo(TDateTime), Result); end;
    TJsonKind.EnumValue: begin ordv := JsonToEnumOrdinal(ATypeInfo, AJson, AMapping); Result := TValue.FromOrdinal(ATypeInfo, ordv); end;
    TJsonKind.SetValue: Result := JsonToSet(ATypeInfo, ATypeInfo.TypeData.CompType^, AJson, AMapping);
  else
    raise EJsonError.CreateFmt('Cannot deserialize kind %d (%s)', [Ord(AKind), UTF8ToString(ATypeInfo.Name)]);
  end;
end;

{ construction }

class function TJsonEngine.CreateInstance(ATypeInfo: PTypeInfo): TObject;
begin
  Result := NewInstanceOf(ATypeInfo);
end;

class function TJsonEngine.BuildDictAccess(
  ADictTypeInfo: PTypeInfo): TJsonDictAccess;
var
  DictType, EnumType, PairType: TRttiType;
  GetEnum: TRttiMethod;
  EnumTypeInfo: PTypeInfo;
begin
  { Resolved once, while the owning plan is built.  Warm dictionary
    serialization must not rediscover GetEnumerator/MoveNext/Current/Key/Value
    on every call. }
  Result := nil;
  if (ADictTypeInfo = nil) or (ADictTypeInfo.Kind <> tkClass) then Exit;
  DictType := FCtx.GetType(ADictTypeInfo);
  if DictType = nil then Exit;
  GetEnum := DictType.GetMethod('GetEnumerator');
  if (GetEnum = nil) or (GetEnum.ReturnType = nil) then Exit;
  EnumTypeInfo := GetEnum.ReturnType.Handle;
  if (EnumTypeInfo = nil) or (EnumTypeInfo.Kind <> tkClass) then Exit;
  EnumType := FCtx.GetType(EnumTypeInfo);
  if EnumType = nil then Exit;
  Result := TJsonDictAccess.Create;
  try
    Result.GetEnumeratorMethod := GetEnum;
    Result.EnumeratorClass := GetTypeData(EnumTypeInfo).ClassType;
    Result.MoveNextMethod := EnumType.GetMethod('MoveNext');
    Result.CurrentProp := EnumType.GetProperty('Current');
    if Result.CurrentProp <> nil then
    begin
      PairType := Result.CurrentProp.PropertyType;
      if PairType <> nil then
      begin
        Result.KeyField := PairType.GetField('Key');
        Result.ValueField := PairType.GetField('Value');
      end;
    end;
  except
    Result.Free;
    raise;
  end;
  if not Result.IsValidFor(GetTypeData(ADictTypeInfo).ClassType) then
    FreeAndNil(Result);
end;

class function TJsonEngine.NewInstanceOf(ATypeInfo: PTypeInfo): TObject;
begin
  { Construction metadata (factory, zero-argument constructor, TJsonBase)
    lives on the cached plan; there is no separate RTTI discovery path. }
  Result := NewInstanceWithPlan(GetPlan(ATypeInfo));
end;

class function TJsonEngine.NewInstanceWithPlan(APlan: TJsonTypePlan): TObject;
var
  C: TClass;
  fac: TJsonClassFactory;
  tick: Int64;
begin
  tick := 0;
  if FProfileEnabled then tick := TStopwatch.GetTimeStamp;
  try
    if FFactories.TryGetValue(APlan.TypeInfo, fac) then Exit(fac());
    C := APlan.ClassType;
    if APlan.ZeroConstructor <> nil then Exit(APlan.ZeroConstructor.Invoke(C, []).AsObject);
    if APlan.HasDeclaredConstructor then
      raise EJsonError.CreateFmt('Cannot construct %s: no usable zero-argument or inherited zero-argument constructor and no registered factory.', [C.ClassName]);
    if APlan.TObjectConstructor <> nil then Exit(APlan.TObjectConstructor.Invoke(C, []).AsObject);
    Result := C.Create;
  finally
    if FProfileEnabled then
    begin
      Inc(FPopulateProfile.ObjectConstructions);
      Inc(FPopulateProfile.ObjectConstructionTicks, TStopwatch.GetTimeStamp - tick);
    end;
  end;
end;

{ ------------------------------------------ what a failed read built --- }

{ Asked only after a dictionary's Add refused, to tell a key the document
  repeats from any other refusal. }
function DictionaryHoldsKey(ADict: TObject; const AKey: TValue): Boolean;
var
  Ctx: TRttiContext;
  M: TRttiMethod;
begin
  Result := False;
  Ctx := TRttiContext.Create;
  try
    try
      M := Ctx.GetType(ADict.ClassType).GetMethod('ContainsKey');
      if M <> nil then Result := M.Invoke(ADict, [AKey]).AsBoolean;
    except
      { Only the message depends on it. }
      Result := False;
    end;
  finally
    Ctx.Free;
  end;
end;

{ Adds an element this read built to a container through the family's own
  Add. When the container itself refuses it - a sorted TStringList with
  dupError - that is the document's doing: it reaches the caller as a JSON
  input error naming the container, never as the RTL exception, and the
  element, which is in no container, is freed first. The library's own
  errors pass unchanged, and so does running out of memory, which is not
  the document's doing. }
procedure AddBuiltElement(AAdd: TRttiMethod; AContainer: TObject;
  AElementType: PTypeInfo; const AElement: TValue);
begin
  try
    AAdd.Invoke(AContainer, [AElement]);
  except
    on E: Exception do
    begin
      TSerializationOwnership.ReleaseBuilt(AElementType, AElement,
        TValue.Empty);
      if (E is EOutOfMemory) or
         string(E.UnitName).StartsWith('PascalForge.') then raise;
      raise EJsonInputError.CreateFmt(
        'The %s refused an element the document holds: %s',
        [AContainer.ClassName, E.Message]);
    end;
  end;
end;

{ The same for a dictionary, whose Add refuses a key it already holds: JSON
  reads a dictionary with Add, so a key the document repeats is refused -
  as an input error naming the key, with the key and value built for the
  repeat freed rather than orphaned. }
procedure AddBuiltPair(AAdd: TRttiMethod; ADict: TObject;
  AKeyType, AValueType: PTypeInfo; const AKey, AValue: TValue;
  const AKeyText: string);
var
  Repeated: Boolean;
begin
  try
    AAdd.Invoke(ADict, [AKey, AValue]);
  except
    on E: Exception do
    begin
      Repeated := DictionaryHoldsKey(ADict, AKey);
      TSerializationOwnership.ReleaseBuilt(AValueType, AValue, TValue.Empty);
      TSerializationOwnership.ReleaseBuilt(AKeyType, AKey, TValue.Empty);
      if (E is EOutOfMemory) or
         string(E.UnitName).StartsWith('PascalForge.') then raise;
      if Repeated then
        raise EJsonInputError.CreateFmt(
          'The document holds the key "%s" more than once, and a %s holds ' +
          'one value per key.', [AKeyText, ADict.ClassName]);
      raise EJsonInputError.CreateFmt(
        'The %s refused an element the document holds: %s',
        [ADict.ClassName, E.Message]);
    end;
  end;
end;

{ collections }

class function TJsonEngine.SerializeMember(APlan: TJsonMemberPlan;
  const AValue: TValue; const AOptions: TJsonSerializationOptions): TJSONValue;
var
  Arr: TJSONArray;
  Obj: TJSONObject;
  ArrayValue, PairValue, KeyValue, ValValue: TValue;
  Enumerator: TObject;
  MoveNext: TRttiMethod;
  Current: TRttiProperty;
  KeyField, ValField: TRttiField;
  Access: TJsonDictAccess;
  I: Integer;
  KeyJson: TJSONValue;
  RuntimePlan: TJsonTypePlan;
  SerializerClass: TJsonValueSerializerClass;
begin
  if APlan = nil then
    raise EJsonError.Create('Missing recursive JSON member plan');
  case APlan.Kind of
    TJsonKind.CustomSerializer: Exit(APlan.Serializer.SerializeValueContext(AValue,
      APlan.Context));
    TJsonKind.NullableValue:
      if not APlan.NullableAccess.HasValue(AValue.GetReferenceToRawData) then
        Exit(TJSONNull.Create)
      else
        Exit(SerializeMember(APlan.Inner,
          APlan.NullableAccess.GetValue(AValue.GetReferenceToRawData), AOptions));
    TJsonKind.ObjectValue:
      if AValue.AsObject = nil then Exit(TJSONNull.Create)
      else if FindRegisteredTypeSerializer(AValue.AsObject.ClassInfo,
        SerializerClass) then
        Exit(ResolveSerializer(SerializerClass).SerializeValueContext(AValue,
          APlan.Context))
      else if ResolveMemberObjectPlan(APlan,
        AValue.AsObject.ClassType).IsOpaque then Exit(TJSONNull.Create)
      else if not EnterJsonObject(AValue.AsObject,
        ResolveMemberObjectPlan(APlan,
          AValue.AsObject.ClassType).RecursionPolicy) then Exit(TJSONNull.Create)
      else
      try
        RuntimePlan := ResolveMemberObjectPlan(APlan,
          AValue.AsObject.ClassType);
        Exit(SerializeWithPlan(RuntimePlan, InstanceAddress(AValue.AsObject), AOptions));
      finally
        LeaveJsonObject(AValue.AsObject);
      end;
    TJsonKind.RecordValue:
      Exit(SerializeWithPlan(APlan.BoundPlan, AValue.GetReferenceToRawData, AOptions));
    TJsonKind.ListValue:
    begin
      if APlan.ToArrayMethod = nil then
      begin
        { A dynamic array: the value already IS the sequence, so there is no
          object to guard against recursion and no ToArray to call. An empty
          one is [], not null - a TArray<T> has no nil. It is still one
          level: a record holding an array of itself nests with no object
          in it. }
        TSerializationGraphGuard.EnterLevel;
        try
          ChargeJsonOutput(2);   { brackets }
          Arr := TJSONArray.Create;
          try
            for I := 0 to Integer(AValue.GetArrayLength - 1) do
            begin
              ChargeJsonOutput(1);   { element separator }
              Arr.AddElement(SerializeMember(APlan.Item,
                AValue.GetArrayElement(I), AOptions));
            end;
            Exit(Arr);
          except
            Arr.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
      end;
      if AValue.AsObject = nil then Exit(TJSONNull.Create);
      if not EnterJsonObject(AValue.AsObject,
        APlan.BoundPlan.RecursionPolicy) then Exit(TJSONNull.Create);
      try
        ChargeJsonOutput(2);   { brackets }
        Arr := TJSONArray.Create;
        try
          ArrayValue := APlan.ListAccess.Elements(AValue);
          for I := 0 to Integer(ArrayValue.GetArrayLength - 1) do
          begin
            ChargeJsonOutput(1);   { element separator }
            Arr.AddElement(SerializeMember(APlan.Item, ArrayValue.GetArrayElement(I), AOptions));
          end;
          Result := Arr;
        except
          Arr.Free;
          raise;
        end;
      finally
        LeaveJsonObject(AValue.AsObject);
      end;
      Exit;
    end;
    TJsonKind.DictionaryValue:
    begin
      if AValue.AsObject = nil then Exit(TJSONNull.Create);
      if not EnterJsonObject(AValue.AsObject,
        APlan.BoundPlan.RecursionPolicy) then Exit(TJSONNull.Create);
      try
        ChargeJsonOutput(2);   { braces }
        Obj := TJSONObject.Create;
        try
          Access := APlan.DictAccess;
          if (Access = nil) or
             (Access.EnumeratorClass <> nil) and
             not (AValue.AsObject.ClassType.InheritsFrom(APlan.TypeInfo.TypeData.ClassType)) then
            Access := nil;
          if Access = nil then
            raise EJsonError.CreateFmt(
              'Cannot enumerate dictionary %s: no cached enumerator metadata',
              [AValue.AsObject.ClassName]);
          Enumerator := Access.GetEnumeratorMethod.Invoke(AValue.AsObject, []).AsObject;
          try
            MoveNext := Access.MoveNextMethod;
            Current := Access.CurrentProp;
            KeyField := Access.KeyField;
            ValField := Access.ValueField;
            while MoveNext.Invoke(Enumerator, []).AsBoolean do
            begin
              PairValue := Current.GetValue(InstanceAddress(Enumerator));
              KeyValue := KeyField.GetValue(PairValue.GetReferenceToRawData);
              ValValue := ValField.GetValue(PairValue.GetReferenceToRawData);
              KeyJson := SerializeMember(APlan.Key, KeyValue, AOptions);
              try
                ChargeJsonOutput(Length(KeyJson.Value) + 4);
                Obj.AddPair(KeyJson.Value, SerializeMember(APlan.Value, ValValue, AOptions));
              finally
                KeyJson.Free;
              end;
            end;
          finally
            Enumerator.Free;
          end;
          Result := Obj;
        except
          Obj.Free;
          raise;
        end;
      finally
        LeaveJsonObject(AValue.AsObject);
      end;
      Exit;
    end;
  end;
  Result := ValueToJson(APlan.Kind, APlan.TypeInfo, AValue, APlan.EnumMapping,
    APlan.DateFormat, APlan.DatePattern);
end;

class function TJsonEngine.DeserializeMember(APlan: TJsonMemberPlan;
  const AJson: TJSONValue): TValue;
var
  Obj: TObject;
  E, KeyValue, ValValue, InnerValue: TValue;
  J: TJSONValue;
  Pair: TJSONPair;
  NullableJson: TJSONValue;
  NullableHasValue: Boolean;
  Elems: TArray<TValue>;
  I: Integer;
  ArrLen: NativeInt;
begin
  if APlan = nil then
    raise EJsonError.Create('Missing recursive JSON member plan');
  if APlan.Kind = TJsonKind.CustomSerializer then
    Exit(APlan.Serializer.DeserializeValueContext(AJson, APlan.TypeInfo,
      APlan.Context));
  if APlan.Kind = TJsonKind.NullableValue then
  begin
    TValue.Make(nil, APlan.TypeInfo, Result);
    NullableJson := AJson;
    NullableHasValue := not (AJson is TJSONNull);
    TryUnwrapNullable(AJson, NullableJson, NullableHasValue);
    if NullableHasValue and (NullableJson <> nil) and
       not (NullableJson is TJSONNull) then
    begin
      InnerValue := DeserializeMember(APlan.Inner, NullableJson);
      if InnerValue.TypeInfo = APlan.NullableAccess.ValueType then
        APlan.NullableAccess.SetExactValue(Result.GetReferenceToRawData, InnerValue)
      else
        APlan.NullableAccess.SetValue(Result.GetReferenceToRawData, InnerValue);
    end;
    Exit;
  end;
  case APlan.Kind of
    TJsonKind.ObjectValue:
    begin
      Obj := nil;
      if not (AJson is TJSONNull) then
      begin
        RequireMemberShape(APlan, TJsonKind.ObjectValue, AJson);
        Obj := NewInstanceWithPlan(APlan.BoundPlan);
        try
          PopulateWithPlan(APlan.BoundPlan, InstanceAddress(Obj), TJSONObject(AJson));
        except
          Obj.Free;
          raise;
        end;
      end;
      TValue.Make(@Obj, APlan.TypeInfo, Result);
    end;
    TJsonKind.RecordValue:
    begin
      TValue.Make(nil, APlan.TypeInfo, Result);
      if not (AJson is TJSONNull) then
      begin
        RequireMemberShape(APlan, TJsonKind.RecordValue, AJson);
        { A fresh record, so every object in it when a later member fails is
          one this read built - a custom serializer hands over every
          instance it returns - and nothing else can reach it. }
        try
          PopulateWithPlan(APlan.BoundPlan, Result.GetReferenceToRawData,
            TJSONObject(AJson));
        except
          TSerializationOwnership.ReleaseBuilt(APlan.TypeInfo, Result,
            TValue.Empty);
          raise;
        end;
      end;
    end;
    TJsonKind.ListValue:
    begin
      if (APlan.AddMethod = nil) and (APlan.TypeInfo.Kind = tkArray) then
      begin
        { A static array has exactly as many elements as its type says, and a
          document with any other number is not this type. }
        RequireMemberShape(APlan, TJsonKind.ListValue, AJson);
        TValue.Make(nil, APlan.TypeInfo, Result);
        if TJSONArray(AJson).Count <> Result.GetArrayLength then
          raise EJsonInputError.CreateFmt(
            '%s holds exactly %d elements, and the document has %d.',
            [UTF8ToString(APlan.TypeInfo.Name), Result.GetArrayLength,
             TJSONArray(AJson).Count]);
        try
          for I := 0 to TJSONArray(AJson).Count - 1 do
            Result.SetArrayElement(I,
              DeserializeMember(APlan.Item, TJSONArray(AJson).Items[I]));
        except
          { The elements already read are this read's, and in nothing else. }
          TSerializationOwnership.ReleaseBuilt(APlan.TypeInfo, Result,
            TValue.Empty);
          raise;
        end;
        Exit;
      end;
      if APlan.AddMethod = nil then
      begin
        { A dynamic array. null and an empty array both produce an array of
          no elements, because a TArray<T> has no nil to distinguish them
          with - said here rather than discovered. }
        SetLength(Elems, 0);
        if not (AJson is TJSONNull) then
        begin
          RequireMemberShape(APlan, TJsonKind.ListValue, AJson);
          try
            for J in TJSONArray(AJson) do
              Elems := Elems + [DeserializeMember(APlan.Item, J)];
          except
            TSerializationOwnership.ReleaseBuiltElements(APlan.Item.TypeInfo,
              Elems);
            raise;
          end;
        end;
        TValue.Make(nil, APlan.TypeInfo, Result);
        ArrLen := Length(Elems);
        DynArraySetLength(PPointer(Result.GetReferenceToRawData)^,
          APlan.TypeInfo, 1, @ArrLen);
        for I := 0 to Integer(High(Elems)) do Result.SetArrayElement(I, Elems[I]);
        Exit;
      end;
      Obj := nil;
      if not (AJson is TJSONNull) then
      begin
        RequireMemberShape(APlan, TJsonKind.ListValue, AJson);
        Obj := NewInstanceWithPlan(APlan.BoundPlan);
        try
          for J in TJSONArray(AJson) do
          begin
            E := DeserializeMember(APlan.Item, J);
            AddBuiltElement(APlan.AddMethod, Obj, APlan.Item.TypeInfo, E);
          end;
        except
          { With what it holds, unless it owns that: a TList<T> owns
            nothing, and its elements were built here too. }
          TSerializationOwnership.ReleaseBuiltContainer(Obj);
          raise;
        end;
      end;
      TValue.Make(@Obj, APlan.TypeInfo, Result);
    end;
    TJsonKind.DictionaryValue:
    begin
      Obj := nil;
      if not (AJson is TJSONNull) then
      begin
        RequireMemberShape(APlan, TJsonKind.DictionaryValue, AJson);
        Obj := NewInstanceWithPlan(APlan.BoundPlan);
        try
          for Pair in TJSONObject(AJson) do
          begin
            KeyValue := DeserializeMember(APlan.Key, Pair.JsonString);
            try
              ValValue := DeserializeMember(APlan.Value, Pair.JsonValue);
            except
              TSerializationOwnership.ReleaseBuilt(APlan.Key.TypeInfo,
                KeyValue, TValue.Empty);
              raise;
            end;
            AddBuiltPair(APlan.AddMethod, Obj, APlan.Key.TypeInfo,
              APlan.Value.TypeInfo, KeyValue, ValValue, Pair.JsonString.Value);
          end;
        except
          TSerializationOwnership.ReleaseBuiltContainer(Obj);
          raise;
        end;
      end;
      TValue.Make(@Obj, APlan.TypeInfo, Result);
    end;
  else
    if AJson is TJSONString then
      case APlan.Kind of
        TJsonKind.IntegerValue, TJsonKind.Int64Value:
          Result := JsonIntegerValue(APlan.TypeInfo, AJson.Value);
      else
        Result := JsonToValue(APlan.Kind, APlan.TypeInfo, AJson,
          APlan.EnumMapping, APlan.DateFormat, APlan.DatePattern);
      end
    else
      Result := JsonToValue(APlan.Kind, APlan.TypeInfo, AJson,
        APlan.EnumMapping, APlan.DateFormat, APlan.DatePattern);
  end;
end;

class function TJsonEngine.SerializeList(const AList: TObject; AFP: TJsonFieldPlan; const AOptions: TJsonSerializationOptions): TJSONValue;
var
  arr: TJSONArray;
  toArray: TRttiMethod;
  v, elem: TValue;
  i: Integer;
begin
  if not EnterJsonObject(AList, FDefaultRecursionPolicy) then
    Exit(TJSONNull.Create);
  try
    ChargeJsonOutput(2);   { brackets }
    arr := TJSONArray.Create;
    try
      { Through Core, which also refuses what a family cannot carry - a
        TStrings with objects on its lines. }
      if AFP.ListAccess.IsValid then
        v := AFP.ListAccess.Elements(TValue.From<TObject>(AList))
      else
      begin
        if AFP.ListToArrayMethod <> nil then
          toArray := AFP.ListToArrayMethod
        else
          toArray := FCtx.GetType(AList.ClassType).GetMethod('ToArray');
        v := toArray.Invoke(AList, []);
      end;
      for i := 0 to Integer(v.GetArrayLength - 1) do
      begin
        ChargeJsonOutput(1);   { element separator }
        elem := v.GetArrayElement(i);
        if AFP.ElemMember <> nil then
        begin
          arr.AddElement(SerializeMember(AFP.ElemMember, elem, AOptions));
          Continue;
        end;
        if AFP.ElemSerializer <> nil then
        arr.AddElement(AFP.ElemSerializer.SerializeValueContext(elem,
          AFP.Context))
        else
        case AFP.ElemKind of
          TJsonKind.ObjectValue:
            if elem.AsObject = nil then arr.AddElement(TJSONNull.Create)
            else if AFP.ElemPlan <> nil then
              arr.AddElement(SerializeWithPlan(AFP.ElemPlan, InstanceAddress(elem.AsObject), AOptions))
            else arr.AddElement(ToJsonWithOptions(elem.AsObject, AOptions));
          TJsonKind.RecordValue:
            arr.AddElement(SerializeToObject(AFP.ElemTypeInfo, elem.GetReferenceToRawData, AOptions));
        else
          arr.AddElement(ValueToJson(AFP.ElemKind, AFP.ElemTypeInfo, elem,
            AFP.ElemMapping, AFP.ElemDateFormat, AFP.ElemDatePattern));
        end;
      end;
      Result := arr;
    except
      arr.Free;
      raise;
    end;
  finally
    LeaveJsonObject(AList);
  end;
end;

class procedure TJsonEngine.DeserializeList(const AList: TObject; AFP: TJsonFieldPlan; const AArr: TJSONArray);
var
  addM: TRttiMethod;
  je: TJSONValue;
  child: TObject;
  ev: TValue;
  tick, addTick: Int64;
begin
  tick := 0;
  addTick := 0;
  if FProfileEnabled then tick := TStopwatch.GetTimeStamp;
  if AFP.ListAddMethod <> nil then
    addM := AFP.ListAddMethod
  else
    addM := FCtx.GetType(AList.ClassType).GetMethod('Add');
  for je in AArr do
  begin
    if AFP.ElemMember <> nil then
    begin
      ev := DeserializeMember(AFP.ElemMember, je);
      AddBuiltElement(addM, AList, AFP.ElemTypeInfo, ev);
      Continue;
    end;
    if AFP.ElemSerializer <> nil then
    begin
      if je is TJSONNull then Continue;
        if FProfileEnabled then addTick := TStopwatch.GetTimeStamp;
        AddBuiltElement(addM, AList, AFP.ElemTypeInfo,
          AFP.ElemSerializer.DeserializeValueContext(je, AFP.ElemTypeInfo,
            AFP.Context));
        if FProfileEnabled then begin Inc(FPopulateProfile.ListAdds); Inc(FPopulateProfile.ListAddTicks, TStopwatch.GetTimeStamp - addTick); end;
      Continue;
    end;
    case AFP.ElemKind of
      TJsonKind.ObjectValue:
      begin
        if je is TJSONNull then Continue;
        // The element plan was resolved while its containing plan was built.
        // Do not re-enter the plan cache for every object element in a warm loop.
        if AFP.ElemPlan <> nil then
          child := NewInstanceWithPlan(AFP.ElemPlan)
        else
          child := NewInstanceOf(AFP.ElemTypeInfo);
        try
          if AFP.ElemPlan <> nil then
            PopulateWithPlan(AFP.ElemPlan, InstanceAddress(child), TJSONObject(je))
          else
            Populate(child, je);
        except
          child.Free;
          raise;
        end;
        if FProfileEnabled then addTick := TStopwatch.GetTimeStamp;
        AddBuiltElement(addM, AList, AFP.ElemTypeInfo, child);
        if FProfileEnabled then begin Inc(FPopulateProfile.ListAdds); Inc(FPopulateProfile.ListAddTicks, TStopwatch.GetTimeStamp - addTick); end;
      end;
    else
      ev := JsonToValue(AFP.ElemKind, AFP.ElemTypeInfo, je, AFP.ElemMapping,
        AFP.ElemDateFormat, AFP.ElemDatePattern);
      if FProfileEnabled then addTick := TStopwatch.GetTimeStamp;
      AddBuiltElement(addM, AList, AFP.ElemTypeInfo, ev);
      if FProfileEnabled then begin Inc(FPopulateProfile.ListAdds); Inc(FPopulateProfile.ListAddTicks, TStopwatch.GetTimeStamp - addTick); end;
    end;
  end;
  if FProfileEnabled then begin Inc(FPopulateProfile.ListExecutions); Inc(FPopulateProfile.ListTicks, TStopwatch.GetTimeStamp - tick); end;
end;

class function TJsonEngine.SerializeDict(const ADict: TObject; AFP: TJsonFieldPlan; const AOptions: TJsonSerializationOptions): TJSONValue;
var
  obj: TJSONObject;
  enum: TObject;
  moveNext: TRttiMethod;
  currentProp: TRttiProperty;
  pair, keyV, valV: TValue;
  keyF, valF: TRttiField;
  keyStr: string;
  access: TJsonDictAccess;
begin
  if not EnterJsonObject(ADict, FDefaultRecursionPolicy) then
    Exit(TJSONNull.Create);
  try
    ChargeJsonOutput(2);   { braces }
    obj := TJSONObject.Create;
    try
      access := AFP.DictAccess;
      if access = nil then
        raise EJsonError.CreateFmt(
          'Cannot enumerate dictionary %s.%s: no cached enumerator metadata',
          [AFP.DeclaringTypeName, AFP.FieldName]);
      enum := access.GetEnumeratorMethod.Invoke(ADict, []).AsObject;
      try
        moveNext := access.MoveNextMethod;
        currentProp := access.CurrentProp;
        keyF := access.KeyField;
        valF := access.ValueField;
        while moveNext.Invoke(enum, []).AsBoolean do
        begin
          pair := currentProp.GetValue(InstanceAddress(enum));
          keyV := keyF.GetValue(pair.GetReferenceToRawData);
          valV := valF.GetValue(pair.GetReferenceToRawData);
          if AFP.DictKeyMember <> nil then
          begin
            var recursiveKey := SerializeMember(AFP.DictKeyMember, keyV, AOptions);
            try keyStr := recursiveKey.Value; finally recursiveKey.Free; end;
          end
          else if AFP.DictKeySerializer <> nil then
          begin
          var kj := AFP.DictKeySerializer.SerializeValueContext(keyV, AFP.Context);
            keyStr := kj.Value; kj.Free;
          end
          else case AFP.DictKeyKind of
            TJsonKind.StringValue: keyStr := keyV.AsString;
            TJsonKind.EnumValue:
            begin
              var kj := EnumToJson(AFP.DictKeyTypeInfo, Integer(keyV.AsOrdinal), AFP.DictKeyMapping);
              keyStr := kj.Value; kj.Free;
            end;
            TJsonKind.IntegerValue: keyStr := IntToStr(keyV.AsInteger);
            TJsonKind.Int64Value: keyStr := IntToStr(keyV.AsInt64);
          else keyStr := keyV.ToString;
          end;
          ChargeJsonOutput(Length(keyStr) + 4);
          if AFP.DictValMember <> nil then
            obj.AddPair(keyStr, SerializeMember(AFP.DictValMember, valV, AOptions))
          else if AFP.DictValSerializer <> nil then
          obj.AddPair(keyStr, AFP.DictValSerializer.SerializeValueContext(valV,
            AFP.Context))
          else case AFP.DictValKind of
            TJsonKind.ObjectValue:
              if valV.AsObject = nil then obj.AddPair(keyStr, TJSONNull.Create)
              else obj.AddPair(keyStr, ToJsonWithOptions(valV.AsObject, AOptions));
          else
            obj.AddPair(keyStr, ValueToJson(AFP.DictValKind,
              AFP.DictValTypeInfo, valV, AFP.DictValMapping,
              AFP.DictValDateFormat, AFP.DictValDatePattern));
          end;
        end;
      finally
        enum.Free;
      end;
      Result := obj;
    except
      obj.Free;
      raise;
    end;
  finally
    LeaveJsonObject(ADict);
  end;
end;

class procedure TJsonEngine.DeserializeDict(const ADict: TObject; AFP: TJsonFieldPlan; const AObj: TJSONObject);
var
  addM: TRttiMethod;
  pair: TJSONPair;
  keyV, valV: TValue;
  child: TObject;
begin
  if AFP.DictAddMethod <> nil then addM := AFP.DictAddMethod
  else addM := FCtx.GetType(ADict.ClassType).GetMethod('Add');
  for pair in AObj do
  begin
    if AFP.DictKeyMember <> nil then
      keyV := DeserializeMember(AFP.DictKeyMember, pair.JsonString)
    else
    case AFP.DictKeyKind of
      TJsonKind.StringValue: keyV := TValue.From<string>(pair.JsonString.Value);
      TJsonKind.EnumValue: keyV := TValue.FromOrdinal(AFP.DictKeyTypeInfo, JsonToEnumOrdinal(AFP.DictKeyTypeInfo, pair.JsonString, AFP.DictKeyMapping));
      TJsonKind.IntegerValue: keyV := TValue.FromOrdinal(AFP.DictKeyTypeInfo, StrToInt(pair.JsonString.Value));
      TJsonKind.Int64Value: keyV := TValue.From<Int64>(StrToInt64(pair.JsonString.Value));
    else
      keyV := TValue.From<string>(pair.JsonString.Value);
    end;
    if (AFP.DictKeyMember = nil) and (AFP.DictKeySerializer <> nil) then
      keyV := AFP.DictKeySerializer.DeserializeValueContext(pair.JsonString,
        AFP.DictKeyTypeInfo, AFP.Context);
    try
      if AFP.DictValMember <> nil then
        valV := DeserializeMember(AFP.DictValMember, pair.JsonValue)
      else if pair.JsonValue is TJSONNull then Continue
      else if AFP.DictValSerializer <> nil then
        valV := AFP.DictValSerializer.DeserializeValueContext(pair.JsonValue,
          AFP.DictValTypeInfo, AFP.Context)
      else
      case AFP.DictValKind of
        TJsonKind.ObjectValue:
        begin
          child := NewInstanceOf(AFP.DictValTypeInfo);
          try
            Populate(child, pair.JsonValue);
          except
            child.Free;
            raise;
          end;
          valV := child;
        end;
      else
        valV := JsonToValue(AFP.DictValKind, AFP.DictValTypeInfo,
          pair.JsonValue, AFP.DictValMapping, AFP.DictValDateFormat,
          AFP.DictValDatePattern);
      end;
    except
      { The key built for a value that failed is in no dictionary. }
      TSerializationOwnership.ReleaseBuilt(AFP.DictKeyTypeInfo, keyV,
        TValue.Empty);
      raise;
    end;
    AddBuiltPair(addM, ADict, AFP.DictKeyTypeInfo, AFP.DictValTypeInfo,
      keyV, valV, pair.JsonString.Value);
  end;
end;

{ field executors }

class procedure TJsonEngine.SerializeField(ABase: Pointer; AFP: TJsonFieldPlan; const AResult: TJSONObject; const AOptions: TJsonSerializationOptions);
var
  pData: Pointer;
  child: TObject;
  v: TValue;
  jv: TJSONValue;
  ChildPlan: TJsonTypePlan;
  SerializerClass: TJsonValueSerializerClass;
begin
  { One charge per member for its name, quotes, colon and separator, and the
    location for the abort diagnostic.  Charging here rather than at each
    AddPair keeps the accounting in one place; a member that turns out to be
    omitted is over-charged, which is the safe direction. }
  if GBudgetedOperations <> 0 then
  begin
    NoteJsonBudgetPath(AFP.DeclaringTypeName, AFP.FieldName);
    ChargeJsonOutput(Length(AFP.JsonName) + 4);
  end;
  if AFP.IsProperty then
  begin
    if not AFP.CanRead then Exit;
    try
      v := AFP.Prop.GetValue(ABase);
    except
      { Running out of memory is not a property-read problem and no read
        policy may have an opinion about it.  Previously it was wrapped as an
        EJsonError under RaiseError and, worse, SILENTLY SWALLOWED under
        SkipMember - a policy meant to tolerate a bad VALUE would quietly
        absorb the process running out of address space.  It is re-raised
        unchanged so a caller can recognise it: exhausting a 32-bit address
        space is not a bad value, and must not be reported as one. }
      on EOutOfMemory do
        raise;
      on E: Exception do
        case AOptions.PropertyReadErrorPolicy of
          TJsonPropertyReadErrorPolicy.SkipMember: Exit;
          TJsonPropertyReadErrorPolicy.WriteNull:
          begin AResult.AddPair(AFP.JsonName, TJSONNull.Create); Exit; end;
        else
          raise EJsonError.CreateFmt('Cannot read property %s.%s: %s',
            [AFP.DeclaringTypeName, AFP.FieldName, E.Message]);
        end;
    end;
    if AFP.WholeMember <> nil then
    begin
      AResult.AddPair(AFP.JsonName, SerializeMember(AFP.WholeMember, v, AOptions));
      Exit;
    end;
    { Unassigned is no value at all, so the member is left out - which is
      how reading it back leaves the Variant Unassigned. }
    if (AFP.Kind = TJsonKind.VariantValue) and VarIsEmpty(v.AsVariant) then Exit;
    case AFP.Kind of
      TJsonKind.CustomSerializer: jv := AFP.Serializer.SerializeValueContext(v, AFP.Context);
      TJsonKind.NullableValue:
        if not AFP.NullableAccess.HasValue(v.GetReferenceToRawData) then Exit
        else if AFP.SerializerOnInner then
          jv := AFP.Serializer.SerializeValueContext(
            AFP.NullableAccess.GetValue(v.GetReferenceToRawData), AFP.Context)
        else
          jv := ValueToJson(AFP.InnerKind, AFP.InnerTypeInfo,
            AFP.NullableAccess.GetValue(v.GetReferenceToRawData),
            AFP.EnumMapping, AFP.InnerDateFormat, AFP.InnerDatePattern);
      TJsonKind.ObjectValue:
        if v.AsObject = nil then Exit
        else if FindRegisteredTypeSerializer(v.AsObject.ClassInfo,
          SerializerClass) then
          jv := ResolveSerializer(SerializerClass).SerializeValueContext(v,
            AFP.Context)
        else begin
          ChildPlan := ResolveChildPlan(AFP, v.AsObject.ClassType);
          if ChildPlan.IsOpaque then jv := TJSONNull.Create
        else if not EnterJsonObject(v.AsObject,
          ChildPlan.RecursionPolicy) then jv := TJSONNull.Create
        else
        try
          jv := SerializeWithPlan(ChildPlan, InstanceAddress(v.AsObject), AOptions);
        finally
          LeaveJsonObject(v.AsObject);
        end; end;
      TJsonKind.RecordValue: jv := SerializeWithPlan(
          GetPlan(AFP.FieldTypeInfo, AFP.OwnerUnitName),
          v.GetReferenceToRawData, AOptions);
      TJsonKind.ListValue:
        if v.AsObject = nil then Exit else jv := SerializeList(v.AsObject, AFP, AOptions);
      TJsonKind.DictionaryValue:
        if v.AsObject = nil then Exit else jv := SerializeDict(v.AsObject, AFP, AOptions);
      TJsonKind.Unsupported: Exit;
    else
      jv := ValueToJson(AFP.Kind, AFP.FieldTypeInfo, v, AFP.EnumMapping,
        AFP.DateFormat, AFP.DatePattern);
    end;
    if jv <> nil then AResult.AddPair(AFP.JsonName, jv);
    Exit;
  end;
  pData := PByte(ABase) + AFP.Offset;
  if AFP.WholeMember <> nil then
  begin
    TValue.Make(pData, AFP.FieldTypeInfo, v);
    AResult.AddPair(AFP.JsonName, SerializeMember(AFP.WholeMember, v, AOptions));
    Exit;
  end;
  if (AFP.Kind = TJsonKind.VariantValue) and VarIsEmpty(PVariant(pData)^) then
    Exit;
  case AFP.Kind of
    TJsonKind.CustomSerializer:
    begin
      TValue.Make(pData, AFP.FieldTypeInfo, v);
      jv := AFP.Serializer.SerializeValueContext(v, AFP.Context);
      { A custom serializer returning TJSONNull has explicitly chosen to emit
        JSON null; that is not the same as skipping the member, and it must
        behave identically on the field and property paths. }
      if jv <> nil then AResult.AddPair(AFP.JsonName, jv);
    end;
    TJsonKind.NullableValue:
      if AFP.NullableAccess.HasValue(pData) then
      begin
        v := AFP.NullableAccess.GetValue(pData);
        if AFP.SerializerOnInner then
        begin
          jv := AFP.Serializer.SerializeValueContext(v, AFP.Context);
          if jv <> nil then AResult.AddPair(AFP.JsonName, jv);
        end
        else
          AResult.AddPair(AFP.JsonName,
            ValueToJson(AFP.InnerKind, AFP.InnerTypeInfo, v, AFP.EnumMapping,
              AFP.InnerDateFormat, AFP.InnerDatePattern));
      end;
    TJsonKind.ObjectValue:
    begin
      child := PObject(pData)^;
      if child <> nil then
      begin
        if FindRegisteredTypeSerializer(child.ClassInfo, SerializerClass) then
        begin
          TValue.Make(pData, AFP.FieldTypeInfo, v);
          jv := ResolveSerializer(SerializerClass).SerializeValueContext(v,
            AFP.Context);
          if jv <> nil then AResult.AddPair(AFP.JsonName, jv);
        end
        else
        begin
          ChildPlan := ResolveChildPlan(AFP, child.ClassType);
          if ChildPlan.IsOpaque then
          AResult.AddPair(AFP.JsonName, TJSONNull.Create)
          else if not EnterJsonObject(child, ChildPlan.RecursionPolicy) then
          AResult.AddPair(AFP.JsonName, TJSONNull.Create)
          else
          try
            AResult.AddPair(AFP.JsonName,
              SerializeWithPlan(ChildPlan, InstanceAddress(child), AOptions));
          finally
            LeaveJsonObject(child);
          end;
        end;
      end;
    end;
    TJsonKind.RecordValue:
      AResult.AddPair(AFP.JsonName,
        SerializeToObject(AFP.FieldTypeInfo, pData, AOptions,
          AFP.OwnerUnitName));
    TJsonKind.ListValue:
    begin
      child := PObject(pData)^;
      if child <> nil then AResult.AddPair(AFP.JsonName, SerializeList(child, AFP, AOptions));
    end;
    TJsonKind.DictionaryValue:
    begin
      child := PObject(pData)^;
      if child <> nil then AResult.AddPair(AFP.JsonName, SerializeDict(child, AFP, AOptions));
    end;
    TJsonKind.Unsupported: ;
  else
    TValue.Make(pData, AFP.FieldTypeInfo, v);
    AResult.AddPair(AFP.JsonName, ValueToJson(AFP.Kind, AFP.FieldTypeInfo, v,
      AFP.EnumMapping, AFP.DateFormat, AFP.DatePattern));
  end;
end;

class procedure TJsonEngine.SetScalarFieldValue(ABase: Pointer;
  AFP: TJsonFieldPlan; const AValue: TValue);
var
  pData: Pointer;
begin
  // Direct writes are restricted to unmanaged values and require an exact
  // TValue type match. This deliberately leaves strings, interfaces, dynamic
  // arrays, managed records, and coercing Boolean aliases on the RTTI path.
  if AFP.DirectScalarWrite and (AValue.TypeInfo = AFP.FieldTypeInfo) then
  begin
    pData := PByte(ABase) + AFP.Offset;
    AValue.ExtractRawData(pData);
  end
  else
    AFP.Field.SetValue(ABase, AValue);
end;

class procedure TJsonEngine.NormalizeSetMapping(AFP: TJsonFieldPlan);
begin
  { A set member carries its element mapping in SetElemMapping, but every
    execution site reads EnumMapping.  Collapsing them here is what makes a
    type- or field-scoped mapping actually reach SetToJson/JsonToSet; the two
    kinds are mutually exclusive, so nothing is lost. }
  if AFP = nil then Exit;
  if (AFP.Kind = TJsonKind.SetValue) or
     ((AFP.Kind = TJsonKind.NullableValue) and
      (AFP.InnerKind = TJsonKind.SetValue)) then
    AFP.EnumMapping := AFP.SetElemMapping;
end;

class function TJsonEngine.JsonShapeName(const AJson: TJSONValue): string;
begin
  if AJson = nil then Exit('absent');
  if AJson is TJSONNull then Exit('null');
  if AJson is TJSONObject then Exit('object');
  if AJson is TJSONArray then Exit('array');
  if AJson is TJSONBool then Exit('boolean');
  if AJson is TJSONNumber then Exit('number');
  if AJson is TJSONString then Exit('string');
  Result := AJson.ClassName;
end;

{ Shape guard for a MEMBER plan: list elements, dictionary keys and values, and
  root values.  DeserializeMember used hard casts here (TJSONObject(AJson)), so
  a wrong-shaped list element such as ["not-an-object"] was cast rather than
  rejected.  ValidateRootJson only covers the root. }
class procedure TJsonEngine.RequireMemberShape(APlan: TJsonMemberPlan;
  AKind: TJsonKind; const AJson: TJSONValue);
var
  Expected: string;
  Ok: Boolean;
begin
  case AKind of
    TJsonKind.ListValue:
      begin Expected := 'array'; Ok := AJson is TJSONArray; end;
  else
    Expected := 'object';
    Ok := AJson is TJSONObject;
  end;
  if Ok then Exit;
  if APlan.Context.MemberName <> '' then
    raise EJsonInputError.CreateFmt(
      'Expected JSON %s for %s within %s.%s but found %s',
      [Expected, UTF8ToString(APlan.TypeInfo.Name),
       UTF8ToString(APlan.Context.OwnerTypeInfo.Name), APlan.Context.MemberName,
       JsonShapeName(AJson)])
  else
    raise EJsonInputError.CreateFmt('Expected JSON %s for %s but found %s',
      [Expected, UTF8ToString(APlan.TypeInfo.Name), JsonShapeName(AJson)]);
end;

{ A member read whole: an array through its member plan, a Variant through
  the dynamic tree. Errors name the member, because the plan below does not
  know it. }
class function TJsonEngine.WholeMemberValue(AFP: TJsonFieldPlan;
  const AJson: TJSONValue; AIsNull: Boolean): TValue;
var
  Null_: TJSONNull;
begin
  try
    if AFP.WholeMember <> nil then
    begin
      if AIsNull or (AJson = nil) or (AJson is TJSONNull) then
      begin
        { A TArray<T> has no nil, so null is the empty array - said here
          rather than discovered. A static array cannot be empty. }
        if AFP.FieldTypeInfo.Kind = tkArray then
          RaiseShapeError(AFP, 'array', AJson);
        TValue.Make(nil, AFP.FieldTypeInfo, Result);
        Exit;
      end;
      Exit(DeserializeMember(AFP.WholeMember, AJson));
    end;
    if AIsNull or (AJson = nil) then
    begin
      Null_ := TJSONNull.Create;
      try
        Exit(JsonToVariantValue(AFP.FieldTypeInfo, Null_));
      finally
        Null_.Free;
      end;
    end;
    Result := JsonToVariantValue(AFP.FieldTypeInfo, AJson);
  except
    on E: EJsonInputError do
      raise EJsonInputError.CreateFmt('%s.%s: %s',
        [AFP.DeclaringTypeName, AFP.FieldName, E.Message]);
  end;
end;

class procedure TJsonEngine.RaiseShapeError(AFP: TJsonFieldPlan;
  const AExpected: string; const AJson: TJSONValue);
begin
  raise EJsonInputError.CreateFmt(
    'Expected JSON %s for %s.%s (%s) but found %s',
    [AExpected, AFP.DeclaringTypeName, AFP.FieldName,
     UTF8ToString(AFP.FieldTypeInfo.Name), JsonShapeName(AJson)]);
end;

{ Converts a present scalar member, turning the RTL's raw EInvalidCast /
  EConvertError into a contextual EJsonError that names the member and the
  offending JSON shape.  Custom serializer failures are never routed here. }
class function TJsonEngine.ConvertScalarMember(AFP: TJsonFieldPlan;
  AKind: TJsonKind; ATypeInfo: PTypeInfo; const AJson: TJSONValue;
  const AMapping: TArray<string>; ADateFormat: TJsonDateTimeFormat;
  const ADatePattern: string): TValue;
begin
  try
    Result := JsonToValue(AKind, ATypeInfo, AJson, AMapping, ADateFormat,
      ADatePattern);
  except
    on E: EJsonError do
      raise;
    on E: Exception do
      raise EJsonInputError.CreateFmt('Cannot convert JSON %s to %s for %s.%s: %s',
        [JsonShapeName(AJson), UTF8ToString(ATypeInfo.Name),
         AFP.DeclaringTypeName, AFP.FieldName, E.Message]);
  end;
end;

class procedure TJsonEngine.DeserializeField(ABase: Pointer;
  AFP: TJsonFieldPlan; const AJsonObj: TJSONObject; AIndex: TJsonMemberIndex);
var
  pData: Pointer;
  member: TJSONValue;
  present, isNull: Boolean;
  child, existing: TObject;
  v: TValue;
  tick: Int64;
  nullableMember: TJSONValue;
  nullableHasValue: Boolean;
  ChildPlan: TJsonTypePlan;
  SerializerClass: TJsonValueSerializerClass;
  recordBefore: TValue;
begin
  if AFP.IsProperty then
  begin
    { A read-only property still participates when its value can be populated
      in place - an object, a list or a dictionary reached through its getter.
      Everything else needs a setter to deliver the value at all. }
    if not AFP.CanWrite and
       not (AFP.CanRead and (AFP.Kind in [TJsonKind.ObjectValue,
              TJsonKind.ListValue, TJsonKind.DictionaryValue])) then Exit;
    present := TryGetMember(AJsonObj, AFP.JsonName, member, AIndex, isNull);
    if not present and not isNull then Exit;
    if (AFP.WholeMember <> nil) or (AFP.Kind = TJsonKind.VariantValue) then
    begin
      if not AFP.CanWrite then Exit;
      AFP.Prop.SetValue(ABase, WholeMemberValue(AFP, member, isNull));
      Exit;
    end;
    case AFP.Kind of
      TJsonKind.CustomSerializer:
      begin
        if AFP.CanRead and (AFP.FieldTypeInfo.Kind = tkClass) then
          existing := AFP.Prop.GetValue(ABase).AsObject
        else existing := nil;
        if AFP.Serializer.DeserializeIntoContext(member, AFP.FieldTypeInfo,
          existing, AFP.Context, v) then
          AFP.Prop.SetValue(ABase, v)
        else
          AFP.Prop.SetValue(ABase,
            AFP.Serializer.DeserializeValueContext(member, AFP.FieldTypeInfo,
              AFP.Context));
      end;
      TJsonKind.NullableValue:
      begin
        if AFP.CanRead then v := AFP.Prop.GetValue(ABase)
        else TValue.Make(nil, AFP.FieldTypeInfo, v);
        nullableMember := member;
        nullableHasValue := not isNull;
        if not isNull then
          TryUnwrapNullable(member, nullableMember, nullableHasValue);
        if not nullableHasValue or (nullableMember = nil) or
           (nullableMember is TJSONNull) then
          { An explicit JSON null clears the nullable. }
          TValue.Make(nil, AFP.FieldTypeInfo, v)
        else if AFP.SerializerOnInner then
          AFP.NullableAccess.SetValue(v.GetReferenceToRawData,
            AFP.Serializer.DeserializeValueContext(nullableMember,
              AFP.InnerTypeInfo, AFP.Context))
        else
          AFP.NullableAccess.SetValue(v.GetReferenceToRawData,
            ConvertScalarMember(AFP, AFP.InnerKind, AFP.InnerTypeInfo,
              nullableMember, AFP.EnumMapping, AFP.InnerDateFormat,
              AFP.InnerDatePattern));
        if AFP.CanWrite then AFP.Prop.SetValue(ABase, v);
      end;
      TJsonKind.ObjectValue:
      begin
        existing := nil;
        if AFP.CanRead then
          existing := AFP.Prop.GetValue(ABase).AsObject;
        if (existing <> nil) and FindRegisteredTypeSerializer(
          existing.ClassInfo, SerializerClass) then
        begin
          if ResolveSerializer(SerializerClass).DeserializeIntoContext(member,
            existing.ClassInfo, existing, AFP.Context, v) then
          begin
            if AFP.CanWrite and not v.IsEmpty then
              AFP.Prop.SetValue(ABase, v);
          end
          else if AFP.CanWrite then
            AFP.Prop.SetValue(ABase, ResolveSerializer(SerializerClass).
              DeserializeValueContext(member, existing.ClassInfo, AFP.Context));
          Exit;
        end;
        if isNull then
        begin
          if AFP.CanWrite then
          begin
            TValue.Make(nil, AFP.FieldTypeInfo, v);
            AFP.Prop.SetValue(ABase, v);
          end;
          Exit;
        end;
        if not (member is TJSONObject) then RaiseShapeError(AFP, 'object', member);
        if IsCompatibleExisting(existing, AFP.FieldTypeInfo) then
        begin
          { Reuse in place.  The setter is deliberately NOT called: nothing is
            being assigned, so invoking it would be a side effect the caller
            never asked for.  This is also what makes a read-only object
            property work. }
          ChildPlan := ResolveChildPlan(AFP, existing.ClassType);
          PopulateWithPlan(ChildPlan, InstanceAddress(existing), TJSONObject(member));
          Exit;
        end;
        if not AFP.CanWrite then Exit;
        ChildPlan := ResolveChildPlan(AFP, nil);
        child := NewInstanceWithPlan(ChildPlan);
        try
          PopulateWithPlan(ChildPlan, InstanceAddress(child), TJSONObject(member));
          v := child;
          AFP.Prop.SetValue(ABase, v);
          child := nil;
        finally
          child.Free;
        end;
      end;
      TJsonKind.RecordValue:
      begin
        if isNull then Exit;
        if not (member is TJSONObject) then RaiseShapeError(AFP, 'object', member);
        { Merge into the CURRENT value, matching the field path.  Starting from
          a zeroed record silently discarded every member absent from the
          JSON.  The getter returns a copy, so the copy is populated and
          assigned back through the setter - the property's own semantics are
          respected rather than bypassed. }
        if AFP.CanRead then v := AFP.Prop.GetValue(ABase)
        else TValue.Make(nil, AFP.FieldTypeInfo, v);
        { A copy of what the getter returned, so a failure frees the objects
          this read built into the copy and none that were already there. }
        TValue.Make(v.GetReferenceToRawData, AFP.FieldTypeInfo, recordBefore);
        try
          PopulateWithPlan(GetPlan(AFP.FieldTypeInfo, AFP.OwnerUnitName),
            v.GetReferenceToRawData, TJSONObject(member));
        except
          TSerializationOwnership.ReleaseBuilt(AFP.FieldTypeInfo, v,
            recordBefore);
          raise;
        end;
        if AFP.CanWrite then AFP.Prop.SetValue(ABase, v);
      end;
      TJsonKind.ListValue, TJsonKind.DictionaryValue:
      begin
        if isNull then
        begin
          if AFP.CanWrite then
          begin
            TValue.Make(nil, AFP.FieldTypeInfo, v);
            AFP.Prop.SetValue(ABase, v);
          end;
          Exit;
        end;
        if AFP.Kind = TJsonKind.ListValue then
        begin
          if not (member is TJSONArray) then RaiseShapeError(AFP, 'array', member);
        end
        else if not (member is TJSONObject) then
          RaiseShapeError(AFP, 'object', member);
        existing := nil;
        if AFP.CanRead then
          existing := AFP.Prop.GetValue(ABase).AsObject;
        if IsCompatibleExisting(existing, AFP.FieldTypeInfo) then
        begin
          { Reuse the container instance and replace its contents; the setter
            is not called because nothing is assigned.  Mirrors the field
            path exactly. }
          ClearContainer(existing, AFP);
          if AFP.Kind = TJsonKind.ListValue then
            DeserializeList(existing, AFP, TJSONArray(member))
          else
            DeserializeDict(existing, AFP, TJSONObject(member));
          Exit;
        end;
        if not AFP.CanWrite then Exit;
        child := NewInstanceWithPlan(AFP.ContainerPlan);
        try
          if AFP.Kind = TJsonKind.ListValue then DeserializeList(child, AFP, TJSONArray(member))
          else DeserializeDict(child, AFP, TJSONObject(member));
          v := child;
          AFP.Prop.SetValue(ABase, v);
        except
          { With the elements this read added, unless the container owns
            them: a TList<T> freed alone orphaned every one. }
          TSerializationOwnership.ReleaseBuiltContainer(child);
          raise;
        end;
      end;
      TJsonKind.Unsupported: ;
    else
      if isNull then Exit;
      AFP.Prop.SetValue(ABase, ConvertScalarMember(AFP, AFP.Kind,
        AFP.FieldTypeInfo, member, AFP.EnumMapping, AFP.DateFormat,
        AFP.DatePattern));
    end;
    Exit;
  end;
  pData := PByte(ABase) + AFP.Offset;
  tick := 0;
  if FProfileEnabled then tick := TStopwatch.GetTimeStamp;
  present := TryGetMember(AJsonObj, AFP.JsonName, member, AIndex, isNull);
  if FProfileEnabled then begin Inc(FPopulateProfile.MemberLookups); Inc(FPopulateProfile.MemberLookupTicks, TStopwatch.GetTimeStamp - tick); end;
  if not present and not isNull then Exit;
  if (AFP.WholeMember <> nil) or (AFP.Kind = TJsonKind.VariantValue) then
  begin
    AFP.Field.SetValue(ABase, WholeMemberValue(AFP, member, isNull));
    Exit;
  end;
  case AFP.Kind of
    TJsonKind.CustomSerializer:
      begin
        if FProfileEnabled then tick := TStopwatch.GetTimeStamp;
        if AFP.FieldTypeInfo.Kind = tkClass then existing := PObject(pData)^
        else existing := nil;
        if AFP.Serializer.DeserializeIntoContext(member, AFP.FieldTypeInfo,
          existing, AFP.Context, v) then
          AFP.Field.SetValue(ABase, v)
        else
          AFP.Field.SetValue(ABase, AFP.Serializer.DeserializeValueContext(member,
            AFP.FieldTypeInfo, AFP.Context));
        if FProfileEnabled then begin Inc(FPopulateProfile.CustomSerializerCalls); Inc(FPopulateProfile.CustomSerializerTicks, TStopwatch.GetTimeStamp - tick); end;
      end;
    TJsonKind.NullableValue:
      begin
        nullableMember := member;
        nullableHasValue := not isNull;
        if not isNull then
          TryUnwrapNullable(member, nullableMember, nullableHasValue);
        if FProfileEnabled then tick := TStopwatch.GetTimeStamp;
        if not nullableHasValue or (nullableMember = nil) or
           (nullableMember is TJSONNull) then
        begin
          { A present JSON null clears the nullable; an absent member never
            reaches this point and therefore preserves the existing value. }
          TValue.Make(nil, AFP.FieldTypeInfo, v);
          AFP.Field.SetValue(ABase, v);
        end
        else
        begin
          if AFP.SerializerOnInner then v := AFP.Serializer.DeserializeValueContext(
            nullableMember, AFP.InnerTypeInfo, AFP.Context)
          else v := ConvertScalarMember(AFP, AFP.InnerKind, AFP.InnerTypeInfo,
            nullableMember, AFP.EnumMapping, AFP.InnerDateFormat,
            AFP.InnerDatePattern);
          if v.TypeInfo = AFP.InnerTypeInfo then
            AFP.NullableAccess.SetExactValue(pData, v)
          else
            AFP.NullableAccess.SetValue(pData, v);
        end;
        if FProfileEnabled then begin Inc(FPopulateProfile.NullableExecutions); Inc(FPopulateProfile.NullableTicks, TStopwatch.GetTimeStamp - tick); end;
      end;
    TJsonKind.ObjectValue:
      begin
        existing := PObject(pData)^;
        if (existing <> nil) and FindRegisteredTypeSerializer(
          existing.ClassInfo, SerializerClass) then
        begin
          if ResolveSerializer(SerializerClass).DeserializeIntoContext(member,
            existing.ClassInfo, existing, AFP.Context, v) then
          begin
            { A serializer that hands back a different instance owns the
              decision about the old one; it may be cached or shared, so the
              engine must not destroy it. }
            if not v.IsEmpty and (v.AsObject <> existing) then
              PObject(pData)^ := v.AsObject;
          end
          else
          begin
            v := ResolveSerializer(SerializerClass).DeserializeValueContext(
              member, existing.ClassInfo, AFP.Context);
            PObject(pData)^ := v.AsObject;
          end;
          Exit;
        end;
        if isNull then
        begin
          { Detach, do not destroy: nothing in RTTI says this member owns what
            it points at, and destroying a shared or borrowed reference is
            unrecoverable.  The caller owns the detached instance. }
          PObject(pData)^ := nil;
          Exit;
        end;
        if not (member is TJSONObject) then RaiseShapeError(AFP, 'object', member);
        if IsCompatibleExisting(existing, AFP.FieldTypeInfo) then
        begin
          { Reuse: populate in place through the plan for the instance's own
            runtime class.  Identity is preserved, members absent from the JSON
            keep their values, and nothing is destroyed. }
          ChildPlan := ResolveChildPlan(AFP, existing.ClassType);
          if FProfileEnabled then tick := TStopwatch.GetTimeStamp;
          PopulateWithPlan(ChildPlan, InstanceAddress(existing), TJSONObject(member));
          if FProfileEnabled then begin Inc(FPopulateProfile.NestedExecutions); Inc(FPopulateProfile.NestedTicks, TStopwatch.GetTimeStamp - tick); end;
          Exit;
        end;
        // Construction metadata belongs to the pre-bound child plan.  This
        // preserves the normal factory/constructor rules without a per-child
        // RTTI discovery or plan-cache lookup.
        ChildPlan := ResolveChildPlan(AFP, nil);
        child := NewInstanceWithPlan(ChildPlan);
        if FProfileEnabled then tick := TStopwatch.GetTimeStamp;
        try
          PopulateWithPlan(ChildPlan, InstanceAddress(child), TJSONObject(member));
        except
          child.Free;
          raise;
        end;
        if FProfileEnabled then begin Inc(FPopulateProfile.NestedExecutions); Inc(FPopulateProfile.NestedTicks, TStopwatch.GetTimeStamp - tick); end;
        { Transactional: the member is repointed only once the replacement is
          fully populated, so a failure leaves the previous value in place. }
        PObject(pData)^ := child;
      end;
    TJsonKind.RecordValue:
      begin
        if isNull then Exit;
        if not (member is TJSONObject) then RaiseShapeError(AFP, 'object', member);
        if FProfileEnabled then tick := TStopwatch.GetTimeStamp;
        PopulateBase(AFP.FieldTypeInfo, pData, member, AFP.OwnerUnitName);
        if FProfileEnabled then begin Inc(FPopulateProfile.RecordExecutions); Inc(FPopulateProfile.RecordTicks, TStopwatch.GetTimeStamp - tick); end;
      end;
    TJsonKind.ListValue, TJsonKind.DictionaryValue:
      begin
        existing := PObject(pData)^;
        if isNull then
        begin
          { Detach, do not destroy - see the object branch above. }
          PObject(pData)^ := nil;
          Exit;
        end;
        if AFP.Kind = TJsonKind.ListValue then
        begin
          if not (member is TJSONArray) then RaiseShapeError(AFP, 'array', member);
        end
        else if not (member is TJSONObject) then
          RaiseShapeError(AFP, 'object', member);
        if IsCompatibleExisting(existing, AFP.FieldTypeInfo) then
        begin
          { Reuse the container INSTANCE and replace its CONTENTS.  Clear
            delegates element disposal to the container's own ownership, so an
            owning list disposes of its elements and a borrowing one does not -
            and the instance keeps whatever ownership its constructor chose. }
          ClearContainer(existing, AFP);
          if AFP.Kind = TJsonKind.ListValue then
            DeserializeList(existing, AFP, TJSONArray(member))
          else
            DeserializeDict(existing, AFP, TJSONObject(member));
          Exit;
        end;
        child := NewInstanceWithPlan(AFP.ContainerPlan);
        try
          if AFP.Kind = TJsonKind.ListValue then
            DeserializeList(child, AFP, TJSONArray(member))
          else
            DeserializeDict(child, AFP, TJSONObject(member));
        except
          { As the property path: the elements go with it unless it owns
            them. }
          TSerializationOwnership.ReleaseBuiltContainer(child);
          raise;
        end;
        PObject(pData)^ := child;
      end;
    TJsonKind.Unsupported: ;
  else
    if isNull then Exit;
    if FProfileEnabled then tick := TStopwatch.GetTimeStamp;
    v := ConvertScalarMember(AFP, AFP.Kind, AFP.FieldTypeInfo, member,
      AFP.EnumMapping, AFP.DateFormat, AFP.DatePattern);
    if FProfileEnabled then
    begin
      Inc(FPopulateProfile.ScalarConversions);
      Inc(FPopulateProfile.ScalarConversionTicks, TStopwatch.GetTimeStamp - tick);
      if AFP.Kind = TJsonKind.StringValue then
      begin
        Inc(FPopulateProfile.StringConversions);
        Inc(FPopulateProfile.StringConversionTicks, TStopwatch.GetTimeStamp - tick);
      end;
    end;
    SetScalarFieldValue(ABase, AFP, v);
  end;
end;

class function TJsonEngine.SerializeToObject(ATypeInfo: PTypeInfo;
  ABase: Pointer; const AOptions: TJsonSerializationOptions;
  const AUnitHint: string): TJSONObject;
var
  plan: TJsonTypePlan;
begin
  plan := GetPlan(ATypeInfo, AUnitHint);
  Result := SerializeWithPlan(plan, ABase, AOptions);
end;

class function TJsonEngine.SerializeWithPlan(APlan: TJsonTypePlan; ABase: Pointer; const AOptions: TJsonSerializationOptions): TJSONObject;
var
  FP: TJsonFieldPlan;
  IsRecord: Boolean;
begin
  { A record is one level, as an object is. An object's level was counted
    by EnterJsonObject before it got here; every record write - member,
    field, property, list element, root - passes here once, so none is
    counted twice. }
  IsRecord := APlan.IsRecord;
  if IsRecord then TSerializationGraphGuard.EnterLevel;
  try
    ChargeJsonOutput(2);   { braces }
    Result := TJSONObject.Create;
    try
      for FP in APlan.Fields do SerializeField(ABase, FP, Result, AOptions);
    except
      Result.Free; raise;
    end;
  finally
    if IsRecord then TSerializationGraphGuard.LeaveLevel;
  end;
end;

class procedure TJsonEngine.PopulateBase(ATypeInfo: PTypeInfo; ABase: Pointer;
  const AJson: TJSONValue; const AUnitHint: string);
var
  plan: TJsonTypePlan;
begin
  if (AJson = nil) or (AJson is TJSONNull) then Exit;
  if not (AJson is TJSONObject) then
    raise EJsonInputError.CreateFmt('Expected JSON object for %s but found %s',
      [UTF8ToString(ATypeInfo.Name), JsonShapeName(AJson)]);
  plan := GetPlan(ATypeInfo, AUnitHint);
  PopulateWithPlan(plan, ABase, TJSONObject(AJson));
end;

class procedure TJsonEngine.PopulateWithPlan(APlan: TJsonTypePlan; ABase: Pointer;
  const AJson: TJSONObject);
var
  FP: TJsonFieldPlan;
  Index: TJsonMemberIndex;
begin
  if APlan.Fields.Count = 0 then Exit;
  { One case-insensitive index per JSON object, not one linear rescan per
    member that missed the exact-case lookup. }
  Index := TJsonMemberIndex.Create(AJson);
  try
    for FP in APlan.Fields do
      try
        DeserializeField(ABase, FP, AJson, Index);
      except
        { Every failure is re-raised with member context, exactly as before -
          the messages here are unchanged.  What IS preserved now is the
          CATEGORY: wrapping used to turn an access violation, a failing
          constructor and a bad enum value into the same EJsonError, so a Try
          caller could not tell an input problem from a serializer or
          application fault.  Each branch keeps the incoming classification;
          the most specific class is tested first because both markers
          descend from EJsonError. }
        on E: EJsonInputError do
          raise EJsonInputError.CreateFmt('%s.%s: %s',
            [UTF8ToString(APlan.TypeInfo.Name), FP.FieldName, E.Message]);
        on E: EJsonInternalError do
          raise EJsonInternalError.CreateFmt('%s.%s: %s',
            [UTF8ToString(APlan.TypeInfo.Name), FP.FieldName, E.Message]);
        on E: EJsonError do
          raise EJsonError.CreateFmt('%s.%s: %s',
            [UTF8ToString(APlan.TypeInfo.Name), FP.FieldName, E.Message]);
        on E: Exception do
          { A foreign exception - a constructor that raised, a custom
            serializer bug, an access violation.  It is wrapped for context
            as before, but marked so it can never be mistaken for bad
            input. }
          raise EJsonInternalError.CreateFmt('%s.%s: %s (%s)',
            [UTF8ToString(APlan.TypeInfo.Name), FP.FieldName, E.Message,
             E.ClassName]);
      end;
  finally
    Index.Free;
  end;
end;

{ public core }

class function TJsonEngine.ToJson(const AInstance: TObject): TJSONObject;
begin
  Result := ToJsonWithOptions(AInstance, TJsonSerializationOptions.Default);
end;

class function TJsonEngine.ToJsonWithOptions(const AInstance: TObject; const AOptions: TJsonSerializationOptions): TJSONObject;
var
  Plan: TJsonTypePlan;
  SurfaceTypeInfo: PTypeInfo;
  Mark: Integer;
begin
  if AInstance = nil then Exit(nil);
  { As SerializeRoot: this write ends at the level it started from. }
  Mark := TSerializationGraphGuard.Level;
  BeginSerializationContext(AOptions.MaxOutputBytes);
  try
    SurfaceTypeInfo := SelectClassSurface(TypeInfo(TObject),
      AInstance.ClassType);
    Plan := GetPlan(SurfaceTypeInfo);
    if Plan.IsOpaque then
      raise EJsonError.CreateFmt('Cannot serialize opaque class %s at JSON root',
        [AInstance.ClassName]);
    if not EnterJsonObject(AInstance, Plan.RecursionPolicy) then
      raise EJsonError.CreateFmt('Recursive object %s cannot be a JSON root',
        [AInstance.ClassName]);
    try
      Result := SerializeWithPlan(Plan, InstanceAddress(AInstance), AOptions);
    finally
      LeaveJsonObject(AInstance);
    end;
  finally
    EndSerializationContext;
    TSerializationGraphGuard.RestoreLevel(Mark);
  end;
end;

class function TJsonEngine.ToJsonString(const AInstance: TObject): string;
var
  o: TJSONObject;
begin
  o := ToJson(AInstance);
  try
    if o = nil then Exit('null');
    Result := RenderJson(o, TJsonUnicodeEscapePolicy.PreserveUnicode);
  finally
    o.Free;
  end;
end;

class procedure TJsonEngine.Populate(const AInstance: TObject; const AJson: TJSONValue);
var SurfaceTypeInfo: PTypeInfo;
begin
  if AInstance = nil then
    raise EJsonError.Create('Populate target is nil');
  SurfaceTypeInfo := SelectClassSurface(TypeInfo(TObject),
    AInstance.ClassType);
  PopulateBase(SurfaceTypeInfo, InstanceAddress(AInstance), AJson);
end;

class procedure TJsonEngine.Populate(const AInstance: TObject;
  const AJson: string);
var
  JsonValue: TJSONValue;
begin
  if AInstance = nil then
    raise EJsonError.Create('Populate target is nil');
  JsonValue := TJSONObject.ParseJSONValue(AJson);
  try
    if JsonValue = nil then raise EJsonError.Create('Invalid JSON text');
    Populate(AInstance, JsonValue);
  finally
    JsonValue.Free;
  end;
end;




{ --------------------------------------- deserialization failure handling --- }

class function TJsonEngine.TryParseJsonText(const AJson: string;
  out AValue: TJSONValue; out AError: string): Boolean;
begin
  AValue := nil;
  AError := '';
  try
    AValue := TJSONObject.ParseJSONValue(AJson);
  except
    { Only the parser's own failure modes are absorbed.  Anything else -
      EOutOfMemory above all - is not a statement about the input and must
      reach the caller. }
    on E: EJSONException do AError := E.Message;
    on E: EConvertError do AError := E.Message;
  end;
  if AValue = nil then
  begin
    if AError = '' then AError := 'Invalid JSON text';
    Exit(False);
  end;
  Result := True;
end;

class function TJsonEngine.ClassifyDeserializationError(E: Exception;
  out AKind: TJsonDeserializationError): Boolean;
begin
  AKind := TJsonDeserializationError.TypeMismatch;
  if E = nil then Exit(False);

  { Order matters: EJsonInternalError is also an EJsonError, and it exists
    precisely to say "this was wrapped for context but did not come from the
    input".  It must be tested before the input class. }
  if E is EJsonInternalError then Exit(False);
  if E is EJsonInputError then
  begin
    AKind := TJsonDeserializationError.TypeMismatch;
    Exit(True);
  end;
  if E is EJSONException then
  begin
    AKind := TJsonDeserializationError.InvalidJson;
    Exit(True);
  end;
  { A plain EJsonError is deliberately NOT classified.  Most of them describe
    a registration defect, an unsupported target type or a broken
    construction contract, and turning those into a False would tell the
    caller their JSON was bad when it was not. }
  Result := False;
end;



end.
