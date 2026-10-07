{*******************************************************************************
  PascalForge.DataSet.Internal

  INTERNAL IMPLEMENTATION UNIT - applications should not use this unit directly.

  Implements the DTO-to-DataSet projection engine: cached plans, RTTI
  traversal, type serializer tables and field writing.
  Exposed through the public facade PascalForge.DataSet (TDataSetSerializer).

  Documentation
    docs/dataset-formats.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.DataSet.Internal;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  INTERNAL. The DTO -> DataSet projection engine.

  This unit is the implementation behind PascalForge.DataSet: the cached plans,
  the RTTI traversal, the registration tables and the field writing.
  Application code has no reason to reference it - every developer-facing
  operation is published by TDataSetEngine in PascalForge.DataSet, which is a
  thin facade over TDataSetEngine below.

  The only legitimate consumers are the library's own units and its tests.
  Nothing here is a supported API.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections, System.SyncObjs, System.DateUtils,
  Data.DB, FireDAC.Comp.Client, Datasnap.DBClient,
  PascalForge.Nullable,
  PascalForge.Serialization.Core, PascalForge.Serialization.Internal,
  PascalForge.DataSet;

type

  TDsKind = (Unsupported, BooleanValue, IntegerValue, Int64Value, FloatValue,
    CurrencyValue, StringValue, GuidValue, DateValue, TimeValue, DateTimeValue,
    EnumValue, SetValue, NullableValue, CustomHandler, NestedObject, NestedList,
    NestedDictionary);


  TDataSetTypePlan = class;

  TDataSetMemberPlan = class
  public
    Kind: TDsKind;
    TypeInfo: PTypeInfo;
    FieldType: TFieldType;
    FieldSize: Integer;
    Handler: TCustomDataSetFieldHandler;
    TypeSerializer: TCustomDataSetTypeSerializer;
    NullableAccess: TNullableAccess;
    SetElemTypeInfo: PTypeInfo;
    SetBits: Integer;
    BoundPlan: TDataSetTypePlan;
    ToArrayMethod: TRttiMethod;
    Inner: TDataSetMemberPlan;
    Item: TDataSetMemberPlan;
    Key: TDataSetMemberPlan;
    Value: TDataSetMemberPlan;
    destructor Destroy; override;
  end;

  TDataSetFieldPlan = class
  public
    SourceFieldName: string;
    DataSetFieldName: string;
    JsonName: string;
    Field: TRttiField;
    Offset: Integer;
    SourceTypeInfo: PTypeInfo;
    Kind: TDsKind;
    FieldType: TFieldType;
    FieldSize: Integer;
    Handler: TCustomDataSetFieldHandler;
    NullableAccess: TNullableAccess;
    InnerKind: TDsKind;
    InnerTypeInfo: PTypeInfo;
    SetElemTypeInfo: PTypeInfo;
    SetBits: Integer;
    ChildTypeInfo: PTypeInfo;
    ChildElemTypeInfo: PTypeInfo;
    ChildElemKind: TDsKind;
    ChildElemFieldType: TFieldType;
    ChildElemFieldSize: Integer;
    ChildElemFieldName: string;
    ChildElemIsObject: Boolean;
    ChildElemHandler: TCustomDataSetFieldHandler;
    DictKeyTypeInfo: PTypeInfo;
    DictKeyKind: TDsKind;
    DictKeyFieldType: TFieldType;
    DictKeyFieldSize: Integer;
    DictKeyFieldName: string;
    DictKeyIsObject: Boolean;
    DictKeyHandler: TCustomDataSetFieldHandler;
    DictValTypeInfo: PTypeInfo;
    DictValKind: TDsKind;
    DictValFieldType: TFieldType;
    DictValFieldSize: Integer;
    DictValFieldName: string;
    DictValIsObject: Boolean;
    DictValHandler: TCustomDataSetFieldHandler;
    TypeSerializer: TCustomDataSetTypeSerializer;
    ElemMember: TDataSetMemberPlan;
    DictKeyMember: TDataSetMemberPlan;
    DictValMember: TDataSetMemberPlan;
    destructor Destroy; override;
  end;

  TDataSetTypePlan = class
  public
    TypeInfo: PTypeInfo;
    RttiType: TRttiType;
    { Declaring unit and stable name key, resolved through
      PascalForge.Serialization.Core so they are also correct for types declared
      in an implementation section. }
    UnitName: string;
    TypeKeyName: string;
    Fields: TObjectList<TDataSetFieldPlan>;
    constructor Create;
    destructor Destroy; override;
  end;


  { The engine.  Everything TDataSetEngine used to carry, minus the
    developer-facing surface that now lives on the facade. }
  TDataSetEngine = class
  strict private
  type
    TScopeKind = (Field, ExactClass, ClassAndDescendants, UnitName, UnitPattern);
    TDsRule = record
      Scope: TScopeKind;
      TargetTypeInfo: PTypeInfo;
      TargetTypeName: string;
      TargetClass: TClass;
      UnitPattern: string;
      FieldPattern: string;
      Ovr: TDataSetFieldOverride;
      Order: Integer;
    end;
    TDsChildRule = record
      TargetTypeInfo: PTypeInfo;
      TargetTypeName: string;
      FieldName: string;
      ChildName: string;
      Ovr: TDataSetFieldOverride;
      Order: Integer;
    end;
  strict private
    class var FCtx: TRttiContext;
    class var FPlans: TDictionary<PTypeInfo, TDataSetTypePlan>;
    class var FRules: TList<TDsRule>;
    class var FChildRules: TList<TDsChildRule>;
    class var FTypeHandlers: TDictionary<PTypeInfo, TDataSetFieldHandlerClass>;
    class var FSingletons: TObjectDictionary<TClass, TCustomDataSetFieldHandler>;
    { Handlers the framework built from delegates for a single field
      override.  They are not keyed by class - several fields may carry
      different closures for the same T - so they are owned here and live
      until teardown. }
    class var FAdoptedHandlers: TObjectList<TCustomDataSetFieldHandler>;
    class var FTypeSerializers: TDictionary<PTypeInfo, TDataSetTypeSerializerClass>;
    class var FGenericTypeSerializers: TDictionary<string, TDataSetTypeSerializerClass>;
    class var FTypeSerializerSingletons: TObjectDictionary<TClass, TCustomDataSetTypeSerializer>;
    class var FLock: TCriticalSection;
    class var FFrozen: Boolean;
    class var FOrder: Integer;
    class var FDefaultStringSize: Integer;
    { Provisional plan-cache entries published by the build in progress. }
    class var FBuildDepth: Integer;
    class var FBuildTrail: TList<PTypeInfo>;

    class procedure CheckNotFrozen; static;
    class procedure RollbackBuildTrail; static;
    class function GetDefaultStringSize: Integer; static;
    class procedure SetDefaultStringSize(AValue: Integer); static;
    class function ResolveHandler(
      ACls: TDataSetFieldHandlerClass): TCustomDataSetFieldHandler; static;
    { The one place that decides between a delegate-built handler instance and
      a class singleton, so every plan path treats them identically. }
    class function PickHandler(ACls: TDataSetFieldHandlerClass;
      AInstance: TCustomDataSetFieldHandler): TCustomDataSetFieldHandler; static;
    { Publishes AInstance as THE singleton for ACls, so every existing
      class-keyed lookup finds a pre-configured handler without knowing it was
      built from a closure.  Replaces - and frees - a previous one. }
    class procedure SeedHandler(ACls: TDataSetFieldHandlerClass;
      AInstance: TCustomDataSetFieldHandler); static;
    class function ResolveTypeSerializer(
      ACls: TDataSetTypeSerializerClass): TCustomDataSetTypeSerializer; static;
    class function GenericFamilyKey(ATypeInfo: PTypeInfo; out AKey: string): Boolean; static;
    class function FindTypeSerializer(ATypeInfo: PTypeInfo;
      out ASerializer: TCustomDataSetTypeSerializer): Boolean; static;
    class function ResolveMemberHandler(ATypeInfo: PTypeInfo): TCustomDataSetFieldHandler; static;
    class function UnitOf(ATypeInfo: PTypeInfo;
      const AUnitHint: string = ''): string; static;
    class function TypeKey(ATypeInfo: PTypeInfo;
      const AUnitHint: string = ''): string; static;
    class procedure ResolveOverride(AOwner, ADeclaringOwner: PTypeInfo; AClass: TClass; const AUnit, AFieldName: string;
      var AName: string; var AHasType: Boolean; var AType: TFieldType;
      var AHasSize: Boolean; var ASize: Integer;
      var AHandlerClass: TDataSetFieldHandlerClass;
      var AHandlerInstance: TCustomDataSetFieldHandler;
      var AIgnore: Boolean); static;
    class procedure ResolveChildOverride(AOwner, ADeclaringOwner: PTypeInfo;
      const AFieldName, AChildName: string; var AName: string;
      var AHasType: Boolean; var AType: TFieldType;
      var AHasSize: Boolean; var ASize: Integer); static;
    class procedure Classify(ATypeInfo: PTypeInfo; out AKind: TDsKind; out AType: TFieldType; out ASize: Integer); static;
    class function IsNullableType(ATypeInfo: PTypeInfo; out AInner: PTypeInfo): Boolean; static;
    { The resolved access for a type already known to be a nullable. }
    class function NullableAccessFor(ATypeInfo: PTypeInfo): TNullableAccess; static;
    class function GetPlan(ATypeInfo: PTypeInfo): TDataSetTypePlan; static;
    class function BuildPlan(ATypeInfo: PTypeInfo): TDataSetTypePlan; static;
    class procedure BuildFieldPlan(APlan: TDataSetTypePlan; AField: TRttiField); static;
    class function BuildMemberPlan(ATypeInfo: PTypeInfo): TDataSetMemberPlan; static;
    class procedure WriteScalar(AKind: TDsKind; const AField: TField; const AValue: TValue); static;
    class procedure AddPlanFields(ATypeInfo: PTypeInfo; ADefs: TFieldDefs; const APrefix: string); static;
    class procedure AddPlanFieldsRecursive(ATypeInfo: PTypeInfo;
      ADefs: TFieldDefs; const APrefix: string;
      AActiveTypes: TDictionary<PTypeInfo, Integer>); static;
    class procedure WritePlanFields(ATypeInfo: PTypeInfo; ABase: Pointer; ADataSet: TDataSet; const APrefix: string); static;
    class procedure WriteSetToField(AElemTI: PTypeInfo; ABits: Integer; const AField: TField; const AValue: TValue); static;
    class procedure WriteDictRows(AFP: TDataSetFieldPlan; const ADict: TObject; ANestedDS: TDataSet); static;
    class procedure AddMemberFieldRecursive(APlan: TDataSetMemberPlan;
      ADefs: TFieldDefs; const AName: string;
      AActiveTypes: TDictionary<PTypeInfo, Integer>); static;
    class procedure WriteMember(APlan: TDataSetMemberPlan; const AValue: TValue;
      ADataSet: TDataSet; const AName: string); static;
    class procedure DoCreateStructure(ATypeInfo: PTypeInfo; ADataSet: TDataSet); static;
    class procedure DoAppend(ATypeInfo: PTypeInfo; ABase: Pointer; ADataSet: TDataSet); static;
  public
    class procedure WriteTypedValue(AFP: TDataSetFieldPlan; const AField: TField; const AValue: TValue; AHasValue: Boolean); static;
    class procedure WriteMemberValue(AHandler: TCustomDataSetFieldHandler; AKind: TDsKind; const AField: TField; const AValue: TValue); static;
    class constructor Create;
    class destructor Destroy;
    class procedure AddTypeProjection(ATypeInfo: PTypeInfo; AFieldDefs: TFieldDefs;
      const AName: string); static;
    class procedure WriteTypeProjection(ATypeInfo: PTypeInfo; const AValue: TValue;
      ADataSet: TDataSet; const AName: string); static;
    { Raises when configuration is frozen.  Public so sibling library units
      (PascalForge.DataSet.Json) enforce the same freeze. }
    class procedure CheckConfigurationNotFrozen; static;
    { Internal infrastructure - see the note above the plan classes. }
    class function PlanFor(ATypeInfo: PTypeInfo): TDataSetTypePlan; static;
    { Takes ownership of a handler the framework built itself - today, a
      delegate adapter - so its captured closure lives exactly as long as
      the registrations that use it.  Returns the same instance. }
    class function AdoptHandler(
      AInstance: TCustomDataSetFieldHandler): TCustomDataSetFieldHandler; static;
    { Publishes a pre-built handler as THE singleton for ACls. }
    class procedure PublishHandler(ACls: TDataSetFieldHandlerClass;
      AInstance: TCustomDataSetFieldHandler); static;
    { Diagnostics: the focused regressions assert on this to prove the plan
      cache is reused rather than rebuilt. }
    class var PlansBuilt: Integer;
    { The projection operations the facade forwards to. }
    { Default width for string projections.  A property rather than a public
      class var so that changing it after FreezeConfiguration is a clear
      configuration error instead of a silent divergence from cached plans. }
    class property DefaultStringSize: Integer read GetDefaultStringSize
      write SetDefaultStringSize;

    class procedure CreateStructure(ATypeInfo: PTypeInfo; ADataSet: TDataSet); overload; static;
    class procedure Fill(ATypeInfo: PTypeInfo; const AInstance: TObject; ADataSet: TDataSet); overload; static;

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
    { Compile-time checked - the compiler rejects a handler that does not
      handle T:  TDataSetEngine.RegisterTypeHandler<TMoney, TMoneyHandler>; }
    { No handler class at all:
        TDataSetEngine.RegisterTypeHandler<TMoney>(ftCurrency,
          procedure(const AValue: TMoney; AField: TField)
          begin
            AField.AsCurrency := AValue.Amount;
          end);
      The procedure is captured once, here, and owned by the framework until
      teardown.  It must be stateless or capture only immutable state: filling
      is concurrent and nothing locks around it. }
    class procedure RegisterTypeHandler(ATypeInfo: PTypeInfo;
      AHandlerClass: TDataSetFieldHandlerClass); overload; static;
    { NORMAL.  T is the OWNER type - the DTO that declares AFieldName. }
    { NORMAL.  A projection of T across several fields. }
    class procedure RegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TDataSetTypeSerializerClass); overload; static;
    class procedure RegisterGenericTypeSerializer(ARepresentativeTypeInfo: PTypeInfo;
      ASerializerClass: TDataSetTypeSerializerClass); static;
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;
    class procedure FillRaw(ATypeInfo: PTypeInfo; ABase: Pointer;
      ADataSet: TDataSet); static;
    { Opens an in-memory dataset once its schema is described.  Supports the
      two concrete classes the projection targets: TFDMemTable and
      TClientDataSet. }
    class procedure ActivateDataSet(ADataSet: TDataSet); static;
  end;


function SetValueToInteger(const AValue: TValue): Integer;
function GuidWire(const G: TGUID): string;


implementation

uses
  System.StrUtils;

const
  { A class is a list or a dictionary when it IS one of these RTL families
    or DERIVES from one.  Recognition walks the real ancestry, so
    TObjectList<T>, TObjectDictionary<K,V> and any application
    descendant - TOrders = class(TObjectList<TOrder>) - are all covered
    without naming them. }
  DATASET_LIST_BASE_NAMES: array[0..0] of string = ('TList<');
  DATASET_DICT_BASE_NAMES: array[0..0] of string = ('TDictionary<');

{ An instance is addressed by the same raw pointer a record or a field is. }
function InstanceAddress(AObject: TObject): Pointer; inline;
begin
  {$WARN UNSAFE_CAST OFF}
  Result := Pointer(AObject);
  {$WARN UNSAFE_CAST ON}
end;

function GuidWire(const G: TGUID): string;
begin
  Result := LowerCase(Copy(G.ToString, 2, 36));
end;

function SetValueToInteger(const AValue: TValue): Integer;
var
  p: PByte;
  sz, i: Integer;
begin
  Result := 0;
  p := AValue.GetReferenceToRawData;
  sz := AValue.DataSize;
  if sz > 4 then sz := 4;
  for i := 0 to sz - 1 do
    Result := Result or (PByte(p + i)^ shl (i * 8));
end;

{ TCustomDataSetFieldHandler }


{ TDataSetFieldOverride }







{ TDataSetTypePlan }

destructor TDataSetMemberPlan.Destroy;
begin
  Inner.Free;
  Item.Free;
  Key.Free;
  Value.Free;
  inherited;
end;

destructor TDataSetFieldPlan.Destroy;
begin
  ElemMember.Free;
  DictKeyMember.Free;
  DictValMember.Free;
  inherited;
end;

constructor TDataSetTypePlan.Create;
begin
  inherited Create;
  Fields := TObjectList<TDataSetFieldPlan>.Create(True);
end;

destructor TDataSetTypePlan.Destroy;
begin
  Fields.Free;
  inherited;
end;

{ TDataSetEngine }

class constructor TDataSetEngine.Create;
begin
  FCtx := TRttiContext.Create;
  FPlans := TDictionary<PTypeInfo, TDataSetTypePlan>.Create;
  FRules := TList<TDsRule>.Create;
  FChildRules := TList<TDsChildRule>.Create;
  FTypeHandlers := TDictionary<PTypeInfo, TDataSetFieldHandlerClass>.Create;
  FSingletons := TObjectDictionary<TClass, TCustomDataSetFieldHandler>.Create([doOwnsValues]);
  FAdoptedHandlers := TObjectList<TCustomDataSetFieldHandler>.Create(True);
  FTypeSerializers := TDictionary<PTypeInfo, TDataSetTypeSerializerClass>.Create;
  FGenericTypeSerializers := TDictionary<string, TDataSetTypeSerializerClass>.Create;
  FTypeSerializerSingletons := TObjectDictionary<TClass, TCustomDataSetTypeSerializer>.Create([doOwnsValues]);
  FLock := TCriticalSection.Create;
  FDefaultStringSize := 255;
  FBuildTrail := TList<PTypeInfo>.Create;
end;

class destructor TDataSetEngine.Destroy;
var
  P: TDataSetTypePlan;
begin
  for P in FPlans.Values do P.Free;
  FPlans.Free;
  FRules.Free;
  FChildRules.Free;
  FTypeHandlers.Free;
  FAdoptedHandlers.Free;
  FSingletons.Free;
  FTypeSerializers.Free;
  FGenericTypeSerializers.Free;
  FTypeSerializerSingletons.Free;
  FBuildTrail.Free;
  FLock.Free;
  FCtx.Free;
end;

class function TDataSetEngine.GetDefaultStringSize: Integer;
begin
  Result := FDefaultStringSize;
end;

class procedure TDataSetEngine.SetDefaultStringSize(AValue: Integer);
begin
  CheckNotFrozen;
  FDefaultStringSize := AValue;
end;

class procedure TDataSetEngine.CheckConfigurationNotFrozen;
begin
  CheckNotFrozen;
end;

class procedure TDataSetEngine.CheckNotFrozen;
begin
  if FFrozen then raise EDataSetSerializationError.Create('DataSet serializer configuration is frozen.');
end;

class procedure TDataSetEngine.FreezeConfiguration;
begin
  FFrozen := True;
end;

class function TDataSetEngine.IsFrozen: Boolean;
begin
  Result := FFrozen;
end;

{ ------------------------------------------- the typed handler bridges --- }

{ Turns the engine's TValue into T, so the implementation never sees one.
  This is the whole reason TCustomDataSetFieldHandler<T> exists. }




{ ------------------------------------------------ the delegate adapter --- }





{ ------------------------------------------------- typed field builders --- }






class function TDataSetEngine.AdoptHandler(
  AInstance: TCustomDataSetFieldHandler): TCustomDataSetFieldHandler;
begin
  FLock.Enter;
  try
    FAdoptedHandlers.Add(AInstance);
  finally
    FLock.Leave;
  end;
  Result := AInstance;
end;

class function TDataSetEngine.PickHandler(ACls: TDataSetFieldHandlerClass;
  AInstance: TCustomDataSetFieldHandler): TCustomDataSetFieldHandler;
begin
  { An instance wins: it carries closures a class cannot. }
  if AInstance <> nil then
    Result := AInstance
  else
    Result := ResolveHandler(ACls);
end;

class procedure TDataSetEngine.PublishHandler(ACls: TDataSetFieldHandlerClass;
  AInstance: TCustomDataSetFieldHandler);
begin
  SeedHandler(ACls, AInstance);
end;

class procedure TDataSetEngine.SeedHandler(ACls: TDataSetFieldHandlerClass;
  AInstance: TCustomDataSetFieldHandler);
begin
  FLock.Enter;
  try
    { FSingletons owns its values, so re-registering a type releases the
      closure the previous registration captured. }
    FSingletons.AddOrSetValue(ACls, AInstance);
  finally
    FLock.Leave;
  end;
end;








class function TDataSetEngine.ResolveHandler(
  ACls: TDataSetFieldHandlerClass): TCustomDataSetFieldHandler;
begin
  if ACls = nil then Exit(nil);
  FLock.Enter;
  try
    if not FSingletons.TryGetValue(ACls, Result) then
    begin
      Result := ACls.Create;
      FSingletons.Add(ACls, Result);
    end;
  finally
    FLock.Leave;
  end;
end;

class function TDataSetEngine.ResolveTypeSerializer(
  ACls: TDataSetTypeSerializerClass): TCustomDataSetTypeSerializer;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  if ACls = nil then Exit(nil);
  FLock.Enter;
  try
    if not FTypeSerializerSingletons.TryGetValue(ACls, Result) then
    begin
      Result := ACls.Create;
      FTypeSerializerSingletons.Add(ACls, Result);
    end;
  finally
    FLock.Leave;
  end;
end;

class function TDataSetEngine.GenericFamilyKey(ATypeInfo: PTypeInfo;
  out AKey: string): Boolean;
begin
  { Class-only, matching RegisterGenericTypeSerializer's contract; the shared
    implementation lives in PascalForge.Serialization.Core. }
  AKey := '';
  Result := (ATypeInfo <> nil) and (ATypeInfo.Kind = tkClass) and
    GenericFamilyKeyOf(ATypeInfo, AKey);
end;

class function TDataSetEngine.FindTypeSerializer(ATypeInfo: PTypeInfo;
  out ASerializer: TCustomDataSetTypeSerializer): Boolean;
var
  C: TDataSetTypeSerializerClass;
  Key: string;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  ASerializer := nil;
  if FTypeSerializers.TryGetValue(ATypeInfo, C) then
  begin
    ASerializer := ResolveTypeSerializer(C);
    Exit(True);
  end;
  Result := GenericFamilyKey(ATypeInfo, Key) and
    FGenericTypeSerializers.TryGetValue(Key, C);
  if Result then ASerializer := ResolveTypeSerializer(C);
end;

class procedure TDataSetEngine.RegisterFieldOverride(AClass: TClass; const AFieldName: string; const AOverride: TDataSetFieldOverride);
begin
  RegisterFieldOverride(AClass.ClassInfo, AFieldName, AOverride);
end;

class procedure TDataSetEngine.RegisterFieldOverride(AOwnerTypeInfo: PTypeInfo; const AFieldName: string; const AOverride: TDataSetFieldOverride);
var
  R: TDsRule;
begin
  CheckNotFrozen;
  R := Default(TDsRule);
  R.Scope := TScopeKind.Field; R.TargetTypeInfo := AOwnerTypeInfo; R.FieldPattern := AFieldName;
  R.Ovr := AOverride; R.Order := FOrder; Inc(FOrder);
  FRules.Add(R);
end;

class procedure TDataSetEngine.RegisterFieldOverride(
  const AQualifiedOwnerTypeName, AFieldName: string;
  const AOverride: TDataSetFieldOverride);
var
  R: TDsRule;
begin
  CheckNotFrozen;
  R := Default(TDsRule);
  R.Scope := TScopeKind.Field;
  R.TargetTypeName := AQualifiedOwnerTypeName;
  R.FieldPattern := AFieldName;
  R.Ovr := AOverride;
  R.Order := FOrder; Inc(FOrder);
  FRules.Add(R);
end;

class procedure TDataSetEngine.RegisterChildFieldOverride(AClass: TClass;
  const AFieldName, AChildName: string;
  const AOverride: TDataSetFieldOverride);
begin
  RegisterChildFieldOverride(AClass.ClassInfo, AFieldName, AChildName, AOverride);
end;

class procedure TDataSetEngine.RegisterChildFieldOverride(
  AOwnerTypeInfo: PTypeInfo; const AFieldName, AChildName: string;
  const AOverride: TDataSetFieldOverride);
var
  R: TDsChildRule;
begin
  CheckNotFrozen;
  R := Default(TDsChildRule);
  R.TargetTypeInfo := AOwnerTypeInfo;
  R.FieldName := AFieldName;
  R.ChildName := AChildName;
  R.Ovr := AOverride;
  R.Order := FOrder; Inc(FOrder);
  FChildRules.Add(R);
end;

class procedure TDataSetEngine.RegisterChildFieldOverride(
  const AQualifiedOwnerTypeName, AFieldName, AChildName: string;
  const AOverride: TDataSetFieldOverride);
var
  R: TDsChildRule;
begin
  CheckNotFrozen;
  R := Default(TDsChildRule);
  R.TargetTypeName := AQualifiedOwnerTypeName;
  R.FieldName := AFieldName;
  R.ChildName := AChildName;
  R.Ovr := AOverride;
  R.Order := FOrder; Inc(FOrder);
  FChildRules.Add(R);
end;

class procedure TDataSetEngine.RegisterClassFieldOverride(AClass: TClass; const AFieldPattern: string; const AOverride: TDataSetFieldOverride; AIncludeDescendants: Boolean);
var
  R: TDsRule;
begin
  CheckNotFrozen;
  R := Default(TDsRule);
  if AIncludeDescendants then R.Scope := TScopeKind.ClassAndDescendants else R.Scope := TScopeKind.ExactClass;
  R.TargetClass := AClass; R.FieldPattern := AFieldPattern;
  R.Ovr := AOverride; R.Order := FOrder; Inc(FOrder);
  FRules.Add(R);
end;

class procedure TDataSetEngine.RegisterUnitFieldOverride(const AUnitPattern, AFieldPattern: string; const AOverride: TDataSetFieldOverride);
var
  R: TDsRule;
begin
  CheckNotFrozen;
  R := Default(TDsRule);
  if AUnitPattern.Contains('*') then R.Scope := TScopeKind.UnitPattern else R.Scope := TScopeKind.UnitName;
  R.UnitPattern := AUnitPattern; R.FieldPattern := AFieldPattern;
  R.Ovr := AOverride; R.Order := FOrder; Inc(FOrder);
  FRules.Add(R);
end;

class procedure TDataSetEngine.RegisterTypeHandler(ATypeInfo: PTypeInfo;
  AHandlerClass: TDataSetFieldHandlerClass);
begin
  CheckNotFrozen;
  FTypeHandlers.AddOrSetValue(ATypeInfo, AHandlerClass);
end;

class procedure TDataSetEngine.RegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TDataSetTypeSerializerClass);
begin
  CheckNotFrozen;
  FTypeSerializers.AddOrSetValue(ATypeInfo, ASerializerClass);
end;

class procedure TDataSetEngine.RegisterGenericTypeSerializer(
  ARepresentativeTypeInfo: PTypeInfo;
  ASerializerClass: TDataSetTypeSerializerClass);
var
  Key: string;
begin
  CheckNotFrozen;
  if not GenericFamilyKey(ARepresentativeTypeInfo, Key) then
    raise EDataSetSerializationError.CreateFmt(
      '%s is not a direct closed generic class specialization',
      [UTF8ToString(ARepresentativeTypeInfo.Name)]);
  FGenericTypeSerializers.AddOrSetValue(Key, ASerializerClass);
end;

class function TDataSetEngine.ResolveMemberHandler(ATypeInfo: PTypeInfo): TCustomDataSetFieldHandler;
var
  cls: TDataSetFieldHandlerClass;
begin
  if (ATypeInfo <> nil) and FTypeHandlers.TryGetValue(ATypeInfo, cls) then
    Result := ResolveHandler(cls)
  else
    Result := nil;
end;

class function TDataSetEngine.UnitOf(ATypeInfo: PTypeInfo;
  const AUnitHint: string): string;
begin
  { Never calls QualifiedName directly: it raises ENonPublicType for a type
    declared in an implementation section. }
  Result := TypeUnitOf(ATypeInfo, AUnitHint);
end;

class function TDataSetEngine.TypeKey(ATypeInfo: PTypeInfo;
  const AUnitHint: string): string;
begin
  Result := TypeKeyOf(ATypeInfo, AUnitHint);
end;

{ The same shared rule the JSON engine uses - deliberately the same call, so
  that a nullable family registered once is a nullable everywhere. }
class function TDataSetEngine.IsNullableType(ATypeInfo: PTypeInfo; out AInner: PTypeInfo): Boolean;
var
  Access: TNullableAccess;
begin
  AInner := nil;
  Result := TSerializationTypes.TryGetNullableAccess(ATypeInfo, Access);
  if Result then AInner := Access.ValueType;
end;

class function TDataSetEngine.NullableAccessFor(ATypeInfo: PTypeInfo): TNullableAccess;
begin
  if not TSerializationTypes.TryGetNullableAccess(ATypeInfo, Result) then
    raise EDataSetSerializationError.CreateFmt(
      'Internal: %s was classified as a nullable but its layout cannot be resolved.',
      [UTF8ToString(ATypeInfo.Name)]);
end;

class procedure TDataSetEngine.Classify(ATypeInfo: PTypeInfo; out AKind: TDsKind; out AType: TFieldType; out ASize: Integer);
var
  ordType: TOrdType;
begin
  AKind := TDsKind.Unsupported; AType := ftUnknown; ASize := 0;
  if ATypeInfo = nil then Exit;
  if ATypeInfo = System.TypeInfo(TGUID) then begin AKind := TDsKind.GuidValue; AType := ftGuid; Exit; end;
  if ATypeInfo = System.TypeInfo(TDate) then begin AKind := TDsKind.DateValue; AType := ftDate; Exit; end;
  if ATypeInfo = System.TypeInfo(TTime) then begin AKind := TDsKind.TimeValue; AType := ftTime; Exit; end;
  if ATypeInfo = System.TypeInfo(TDateTime) then begin AKind := TDsKind.DateTimeValue; AType := ftDateTime; Exit; end;
  if (ATypeInfo = System.TypeInfo(Boolean)) or (ATypeInfo = System.TypeInfo(ByteBool)) or
     (ATypeInfo = System.TypeInfo(WordBool)) or (ATypeInfo = System.TypeInfo(LongBool)) then
  begin AKind := TDsKind.BooleanValue; AType := ftBoolean; Exit; end;
  case ATypeInfo.Kind of
    tkInteger:
    begin
      AKind := TDsKind.IntegerValue;
      ordType := GetTypeData(ATypeInfo).OrdType;
      case ordType of
        otUByte: AType := ftByte;
        otUWord: AType := ftWord;
        otULong: AType := ftLongWord;
        otSByte, otSWord: AType := ftSmallint;
      else
        AType := ftInteger;
      end;
    end;
    tkInt64: begin AKind := TDsKind.Int64Value; AType := ftLargeint; end;
    tkFloat:
      if GetTypeData(ATypeInfo).FloatType = ftCurr then begin AKind := TDsKind.CurrencyValue; AType := ftCurrency; end
      else begin AKind := TDsKind.FloatValue; AType := ftFloat; end;
    tkEnumeration: begin AKind := TDsKind.EnumValue; AType := ftInteger; end;
    tkSet:
      begin
        { Malformed or absent set element RTTI must not be dereferenced
          downstream; the JSON engine already guarded this. }
        if GetTypeData(ATypeInfo).CompType = nil then
          raise EDataSetSerializationError.CreateFmt(
            'Cannot classify set type %s: its element type RTTI is unavailable.',
            [UTF8ToString(ATypeInfo.Name)]);
        AKind := TDsKind.SetValue; AType := ftInteger;
      end;
    tkChar, tkWChar, tkString, tkLString, tkWString, tkUString:
      begin AKind := TDsKind.StringValue; AType := ftWideString; ASize := FDefaultStringSize; end;
    tkRecord, tkMRecord: begin AKind := TDsKind.NestedObject; AType := ftUnknown; end;
    tkClass:
      { The one question, asked in one place - see the note in the JSON
        engine. Ancestry, so ordinary descendants such as
        TOrders = class(TObjectList<TOrder>) are still projected as lists. }
      case TSerializationTypes.ContainerKindOf(ATypeInfo) of
        TContainerKind.List:
          begin AKind := TDsKind.NestedList; AType := ftDataSet; end;
        TContainerKind.Dictionary:
          begin AKind := TDsKind.NestedDictionary; AType := ftDataSet; end;
      else
        begin AKind := TDsKind.NestedObject; AType := ftUnknown; end;
      end;
  end;
end;

class procedure TDataSetEngine.ResolveOverride(AOwner,
  ADeclaringOwner: PTypeInfo; AClass: TClass; const AUnit, AFieldName: string;
  var AName: string; var AHasType: Boolean; var AType: TFieldType;
  var AHasSize: Boolean; var ASize: Integer;
  var AHandlerClass: TDataSetFieldHandlerClass;
  var AHandlerInstance: TCustomDataSetFieldHandler;
  var AIgnore: Boolean);
var
  R: TDsRule;
  nameScope, typeScope, sizeScope, handScope, ignScope: Integer;
  nameOrder, typeOrder, sizeOrder, handOrder, ignOrder: Integer;
  matches: Boolean; rank: Integer;
  ownerKey, declaringKey: string;
begin
  // more-specific scope wins; within same scope, latest registration wins.
  nameScope := MaxInt; typeScope := MaxInt; sizeScope := MaxInt; handScope := MaxInt; ignScope := MaxInt;
  nameOrder := -1; typeOrder := -1; sizeOrder := -1; handOrder := -1; ignOrder := -1;
  { Resolved once, outside the loop, and through TypeKey rather than
    QualifiedName: the latter raises ENonPublicType for an
    implementation-declared owner, and need not be evaluated per rule. }
  ownerKey := TypeKey(AOwner, AUnit);
  declaringKey := '';
  if (ADeclaringOwner <> nil) and (ADeclaringOwner <> AOwner) then
    declaringKey := TypeKey(ADeclaringOwner, AUnit);
  for R in FRules do
  begin
    if not FieldMatch(R.FieldPattern, AFieldName) then Continue;
    case R.Scope of
      TScopeKind.Field: matches := ((AOwner <> nil) and (R.TargetTypeInfo = AOwner)) or
        ((ADeclaringOwner <> nil) and (R.TargetTypeInfo = ADeclaringOwner)) or
        ((R.TargetTypeName <> '') and
         ((ownerKey <> '') and SameText(R.TargetTypeName, ownerKey) or
          ((declaringKey <> '') and
           SameText(R.TargetTypeName, declaringKey))));
      TScopeKind.ExactClass: matches := (AClass <> nil) and (R.TargetClass = AClass);
      TScopeKind.ClassAndDescendants: matches := (AClass <> nil) and AClass.InheritsFrom(R.TargetClass);
      TScopeKind.UnitName: matches := SameText(R.UnitPattern, AUnit);
      TScopeKind.UnitPattern: matches := GlobMatch(R.UnitPattern, AUnit);
    else matches := False;
    end;
    if not matches then Continue;
    rank := Ord(R.Scope);
    if R.Ovr.HasFieldName and ((rank < nameScope) or ((rank = nameScope) and (R.Order > nameOrder))) then
    begin AName := R.Ovr.FieldName; nameScope := rank; nameOrder := R.Order; end;
    if R.Ovr.HasFieldType and ((rank < typeScope) or ((rank = typeScope) and (R.Order > typeOrder))) then
    begin AType := R.Ovr.FieldType; AHasType := True; typeScope := rank; typeOrder := R.Order; end;
    if R.Ovr.HasFieldSize and ((rank < sizeScope) or ((rank = sizeScope) and (R.Order > sizeOrder))) then
    begin ASize := R.Ovr.FieldSize; AHasSize := True; sizeScope := rank; sizeOrder := R.Order; end;
    if ((R.Ovr.HandlerClass <> nil) or (R.Ovr.HandlerInstance <> nil)) and
       ((rank < handScope) or ((rank = handScope) and (R.Order > handOrder))) then
    begin
      AHandlerClass := R.Ovr.HandlerClass;
      AHandlerInstance := R.Ovr.HandlerInstance;
      handScope := rank; handOrder := R.Order;
    end;
    if R.Ovr.HasIgnore and ((rank < ignScope) or ((rank = ignScope) and (R.Order > ignOrder))) then
    begin AIgnore := R.Ovr.DoIgnore; ignScope := rank; ignOrder := R.Order; end;
  end;
end;

class procedure TDataSetEngine.ResolveChildOverride(AOwner,
  ADeclaringOwner: PTypeInfo; const AFieldName, AChildName: string;
  var AName: string; var AHasType: Boolean; var AType: TFieldType;
  var AHasSize: Boolean; var ASize: Integer);
var
  R: TDsChildRule;
  Matches: Boolean;
  ownerKey, declaringKey: string;
begin
  ownerKey := TypeKey(AOwner);
  declaringKey := '';
  if (ADeclaringOwner <> nil) and (ADeclaringOwner <> AOwner) then
    declaringKey := TypeKey(ADeclaringOwner);
  for R in FChildRules do
  begin
    if not SameText(R.FieldName, AFieldName) or
       not SameText(R.ChildName, AChildName) then Continue;
    Matches := ((AOwner <> nil) and (R.TargetTypeInfo = AOwner)) or
      ((ADeclaringOwner <> nil) and (R.TargetTypeInfo = ADeclaringOwner)) or
      ((R.TargetTypeName <> '') and
       ((ownerKey <> '') and SameText(R.TargetTypeName, ownerKey) or
        ((declaringKey <> '') and
         SameText(R.TargetTypeName, declaringKey))));
    if not Matches then Continue;
    if R.Ovr.HasFieldName then AName := R.Ovr.FieldName;
    if R.Ovr.HasFieldType then
    begin
      AType := R.Ovr.FieldType;
      AHasType := True;
    end;
    if R.Ovr.HasFieldSize then
    begin
      ASize := R.Ovr.FieldSize;
      AHasSize := True;
    end;
  end;
end;

class function TDataSetEngine.GetPlan(ATypeInfo: PTypeInfo): TDataSetTypePlan;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  FLock.Enter;
  try
    if not FPlans.TryGetValue(ATypeInfo, Result) then Result := BuildPlan(ATypeInfo);
  finally
    FLock.Leave;
  end;
end;

class function TDataSetEngine.PlanFor(ATypeInfo: PTypeInfo): TDataSetTypePlan;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  Result := GetPlan(ATypeInfo);
end;

class function TDataSetEngine.BuildPlan(ATypeInfo: PTypeInfo): TDataSetTypePlan;
var
  T: TRttiType; F: TRttiField;
  Member: TSerializationMember;
  I, NewIndex: Integer;
  NewField, Existing: TDataSetFieldPlan;
begin
  Result := TDataSetTypePlan.Create;
  Inc(FBuildDepth);
  try
  Result.TypeInfo := ATypeInfo;
  T := FCtx.GetType(ATypeInfo);
  if T = nil then
    raise EDataSetSerializationError.CreateFmt(
      'Cannot build a DataSet plan for %s: the type exposes no usable RTTI. ' +
      'Types declared inside a routine body have no RTTI; declare the type ' +
      'at unit scope or register a type serializer.',
      [UTF8ToString(ATypeInfo.Name)]);
  Result.RttiType := T;
  Result.UnitName := TypeUnitOf(ATypeInfo);
  Result.TypeKeyName := TypeKeyOf(ATypeInfo, Result.UnitName);
  { Published before members are built so a recursive type resolves to the
    in-progress plan; the except block below un-publishes it if the build
    fails, so a later call can never receive a half-built plan. }
  FPlans.Add(ATypeInfo, Result);
  FBuildTrail.Add(ATypeInfo);
  Inc(PlansBuilt);
  { The public fields of the shared surface - a DataSet projects fields,
    not properties - minus those [SerializationIgnore] removes. }
  for Member in TSerializationMetadata.Get(ATypeInfo).Members do
    if Member.IsField and not Member.Ignored then
    begin
      F := Member.Field;
      NewIndex := Integer(Result.Fields.Count);
      BuildFieldPlan(Result, F);
      if Result.Fields.Count = NewIndex then Continue;
      NewField := Result.Fields[NewIndex];
      for I := 0 to NewIndex - 1 do
      begin
        Existing := Result.Fields[I];
        if not SameText(Existing.DataSetFieldName, NewField.DataSetFieldName) then Continue;
        { Extended RTTI can expose the identical physical field more than
          once for some code-generated classes.  The generator emits that
          member once, so collapse only an occurrence identical in name,
          offset and type. }
        if (Existing.SourceFieldName = NewField.SourceFieldName) and
          (Existing.Offset = NewField.Offset) and
          (Existing.SourceTypeInfo = NewField.SourceTypeInfo) then
        begin
          Result.Fields.Delete(NewIndex);
          Break;
        end;
        raise EDataSetSerializationError.CreateFmt(
          'Duplicate DataSet field name "%s" in plan for %s: source members %s (offset %d) and %s (offset %d).',
          [NewField.DataSetFieldName, UTF8ToString(ATypeInfo.Name), Existing.SourceFieldName,
           Existing.Offset, NewField.SourceFieldName, NewField.Offset]);
      end;
    end;
    Dec(FBuildDepth);
    if FBuildDepth = 0 then FBuildTrail.Clear;
  except
    Dec(FBuildDepth);
    if FBuildDepth = 0 then RollbackBuildTrail;
    raise;
  end;
end;

class procedure TDataSetEngine.RollbackBuildTrail;
var
  TI: PTypeInfo;
  Plan: TDataSetTypePlan;
begin
  { Every provisional entry published by the failed build is removed, not just
    the failing one: a plan completed earlier in the same build may already
    reference a plan we are about to destroy. }
  for TI in FBuildTrail do
    if FPlans.TryGetValue(TI, Plan) then
    begin
      FPlans.Remove(TI);
      Plan.Free;
    end;
  FBuildTrail.Clear;
end;

class function TDataSetEngine.BuildMemberPlan(
  ATypeInfo: PTypeInfo): TDataSetMemberPlan;
var
  InnerTI: PTypeInfo;
  RT: TRttiType;
  AddM: TRttiMethod;
  Params: TArray<TRttiParameter>;
  MaxOrd: Integer;
begin
  Result := TDataSetMemberPlan.Create;
  try
    Result.TypeInfo := ATypeInfo;
    if FindTypeSerializer(ATypeInfo, Result.TypeSerializer) then
    begin
      Result.Kind := TDsKind.NestedObject;
      Exit;
    end;
    if IsNullableType(ATypeInfo, InnerTI) then
    begin
      Result.Kind := TDsKind.NullableValue;
      Result.NullableAccess := NullableAccessFor(ATypeInfo);
      Result.Inner := BuildMemberPlan(InnerTI);
      Exit;
    end;
    Classify(ATypeInfo, Result.Kind, Result.FieldType, Result.FieldSize);
    Result.Handler := ResolveMemberHandler(ATypeInfo);
    if Result.Handler <> nil then
    begin
      Result.Kind := TDsKind.CustomHandler;
      Result.FieldType := Result.Handler.FieldType;
      Result.FieldSize := Result.Handler.FieldSize;
      Exit;
    end;
    case Result.Kind of
      TDsKind.SetValue:
      begin
        Result.SetElemTypeInfo := ATypeInfo.TypeData.CompType^;
        MaxOrd := GetTypeData(Result.SetElemTypeInfo).MaxValue;
        if MaxOrd < 32 then begin Result.SetBits := 32; Result.FieldType := ftInteger; end
        else if MaxOrd < 64 then begin Result.SetBits := 64; Result.FieldType := ftLargeint; end
        else raise EDataSetSerializationError.CreateFmt(
          'Cannot create recursive DataSet member %s: set requires %d bits.',
          [UTF8ToString(ATypeInfo.Name), MaxOrd + 1]);
      end;
      TDsKind.NestedObject:
        Result.BoundPlan := GetPlan(ATypeInfo);
      TDsKind.NestedList:
      begin
        Result.BoundPlan := GetPlan(ATypeInfo);
        RT := FCtx.GetType(ATypeInfo);
        Result.ToArrayMethod := RT.GetMethod('ToArray');
        AddM := RT.GetMethod('Add');
        if AddM <> nil then
        begin
          Params := AddM.GetParameters;
          if Length(Params) >= 1 then
            Result.Item := BuildMemberPlan(Params[0].ParamType.Handle);
        end;
      end;
      TDsKind.NestedDictionary:
      begin
        Result.BoundPlan := GetPlan(ATypeInfo);
        RT := FCtx.GetType(ATypeInfo);
        AddM := RT.GetMethod('Add');
        if AddM <> nil then
        begin
          Params := AddM.GetParameters;
          if Length(Params) >= 2 then
          begin
            Result.Key := BuildMemberPlan(Params[0].ParamType.Handle);
            Result.Value := BuildMemberPlan(Params[1].ParamType.Handle);
          end;
        end;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

class procedure TDataSetEngine.BuildFieldPlan(APlan: TDataSetTypePlan; AField: TRttiField);
var
  FP: TDataSetFieldPlan;
  A: TCustomAttribute;
  ti, inner: PTypeInfo;
  attrName: string; hasAttrName: Boolean;
  attrType: TFieldType; hasAttrType: Boolean;
  attrSize: Integer; hasAttrSize: Boolean;
  handlerCls: TDataSetFieldHandlerClass;
  ownerUnit, ruleName: string;
  ruleHasType, ruleHasSize: Boolean;
  ruleType: TFieldType; ruleSize: Integer; ruleHandler: TDataSetFieldHandlerClass;
  ruleHandlerInst: TCustomDataSetFieldHandler;
  baseKind: TDsKind; baseType: TFieldType; baseSize: Integer;
  ownerClass: TClass;
  addM: TRttiMethod;
  ek: TDsKind; eft: TFieldType; esz: Integer;
  ruleIgnore: Boolean;
  maxOrd: Integer;
  childName: string;
  childHasType, childHasSize: Boolean;
  childType: TFieldType;
  childSize: Integer;
begin
  ti := AField.FieldType.Handle;
  attrName := ''; hasAttrName := False;
  attrType := ftUnknown; hasAttrType := False;
  attrSize := 0; hasAttrSize := False;
  handlerCls := nil;

  for A in AField.GetAttributes do
  begin
    if A is DataSetIgnoreAttribute then Exit;
    if A is DataSetNameAttribute then begin attrName := DataSetNameAttribute(A).Name; hasAttrName := True; end;
    if A is DataSetFieldAttribute then
    begin
      attrType := DataSetFieldAttribute(A).FieldType; hasAttrType := True;
      if DataSetFieldAttribute(A).Size > 0 then begin attrSize := DataSetFieldAttribute(A).Size; hasAttrSize := True; end;
    end;
    if A is DataSetHandlerAttribute then
      handlerCls := DataSetHandlerAttribute(A).HandlerClass;
  end;

  FP := TDataSetFieldPlan.Create;
  FP.Field := AField;
  FP.SourceFieldName := AField.Name;
  FP.Offset := AField.Offset;
  FP.SourceTypeInfo := ti;

  ownerUnit := UnitOf(APlan.TypeInfo);
  if APlan.TypeInfo.Kind = tkClass then ownerClass := APlan.TypeInfo.TypeData.ClassType else ownerClass := nil;
  ruleName := ''; ruleHasType := False; ruleHasSize := False;
  ruleType := ftUnknown; ruleSize := 0; ruleHandler := nil; ruleIgnore := False;
  ruleHandlerInst := nil;
  ResolveOverride(APlan.TypeInfo, AField.Parent.Handle, ownerClass, ownerUnit, AField.Name,
    ruleName, ruleHasType, ruleType, ruleHasSize, ruleSize, ruleHandler,
    ruleHandlerInst, ruleIgnore);
  if ruleIgnore then begin FP.Free; Exit; end;

  // built-in inference
  Classify(ti, baseKind, baseType, baseSize);

  // nullable keeps a nullable plan; inner is classified for field type/size
  if (baseKind = TDsKind.NestedObject) and IsNullableType(ti, inner) then
  begin
    FP.NullableAccess := NullableAccessFor(ti);
    FP.InnerTypeInfo := inner;
    Classify(inner, FP.InnerKind, baseType, baseSize);
    FP.Kind := TDsKind.NullableValue;
  end
  else
  begin
    FP.Kind := baseKind;
    inner := nil;
  end;

  // handler resolution (attr > rule > type(ti) > type(inner))
  { An attribute beats a rule; a rule - whether it named a class or carried
    a closure - beats a type registration. }
  if (handlerCls = nil) and (ruleHandlerInst = nil) then handlerCls := ruleHandler;
  if (handlerCls = nil) and (ruleHandlerInst = nil) then FTypeHandlers.TryGetValue(ti, handlerCls);
  if (handlerCls = nil) and (ruleHandlerInst = nil) and (FP.Kind = TDsKind.NullableValue) then FTypeHandlers.TryGetValue(inner, handlerCls);

  if (handlerCls <> nil) or (ruleHandlerInst <> nil) then
  begin
    FP.Handler := PickHandler(handlerCls, ruleHandlerInst);
    // A nullable field with an inner type handler REMAINS nullable; the handler
    // is applied to the extracted inner value at runtime.
    if FP.Kind <> TDsKind.NullableValue then FP.Kind := TDsKind.CustomHandler;
    FP.FieldType := FP.Handler.FieldType;
    FP.FieldSize := FP.Handler.FieldSize;
  end
  else
  begin
    FP.FieldType := baseType;
    FP.FieldSize := baseSize;
  end;

  // set field width chosen from actual enum ordinal range (no handler case)
  if (FP.Handler = nil) and ((FP.Kind = TDsKind.SetValue) or ((FP.Kind = TDsKind.NullableValue) and (FP.InnerKind = TDsKind.SetValue))) then
  begin
    if FP.Kind = TDsKind.NullableValue then FP.SetElemTypeInfo := FP.InnerTypeInfo.TypeData.CompType^
    else FP.SetElemTypeInfo := ti.TypeData.CompType^;
    maxOrd := GetTypeData(FP.SetElemTypeInfo).MaxValue;
    if maxOrd < 32 then begin FP.SetBits := 32; FP.FieldType := ftInteger; end
    else if maxOrd < 64 then begin FP.SetBits := 64; FP.FieldType := ftLargeint; end
    else raise EDataSetSerializationError.CreateFmt(
      'Cannot create DataSet field %s.%s: set type %s requires %d bits; DataSet set projection currently supports at most 64 bits.',
      [UTF8ToString(APlan.TypeInfo.Name), AField.Name, UTF8ToString(FP.SetElemTypeInfo.Name), maxOrd + 1]);
  end;

  // type/size overrides (attr > rule)
  if hasAttrType then FP.FieldType := attrType
  else if ruleHasType then FP.FieldType := ruleType;
  if hasAttrSize then FP.FieldSize := attrSize
  else if ruleHasSize then FP.FieldSize := ruleSize;

  // name: [DataSetName], then a registered rule, then the general
  // [SerializationName], then the Delphi name
  if hasAttrName then FP.DataSetFieldName := attrName
  else if ruleName <> '' then FP.DataSetFieldName := ruleName
  else if not TSerializationMetadata.GeneralName(AField, FP.DataSetFieldName) then
    FP.DataSetFieldName := AField.Name;

  FP.JsonName := AField.Name;
  FP.JsonName[1] := LowerCase(FP.JsonName[1])[1];

  if FP.Kind = TDsKind.NestedObject then
  begin
    FP.ChildTypeInfo := ti;
    FindTypeSerializer(ti, FP.TypeSerializer);
  end
  else if FP.Kind = TDsKind.NestedList then
  begin
    FP.ChildElemFieldName := 'Item';
    addM := (AField.FieldType as TRttiInstanceType).GetMethod('Add');
    if (addM <> nil) and (Length(addM.GetParameters) >= 1) then
    begin
      FP.ChildElemTypeInfo := addM.GetParameters[0].ParamType.Handle;
      FP.ElemMember := BuildMemberPlan(FP.ChildElemTypeInfo);
      Classify(FP.ChildElemTypeInfo, ek, eft, esz);
      FP.ChildElemKind := ek;
      FP.ChildElemFieldType := eft;
      FP.ChildElemFieldSize := esz;
      FP.ChildElemIsObject := (ek = TDsKind.NestedObject);
      FP.ChildElemHandler := ResolveMemberHandler(FP.ChildElemTypeInfo);
      if FP.ChildElemHandler <> nil then
      begin
        FP.ChildElemFieldType := FP.ChildElemHandler.FieldType;
        FP.ChildElemFieldSize := FP.ChildElemHandler.FieldSize;
      end;
      childName := FP.ChildElemFieldName;
      childHasType := False; childHasSize := False;
      childType := FP.ChildElemFieldType; childSize := FP.ChildElemFieldSize;
      ResolveChildOverride(APlan.TypeInfo, AField.Parent.Handle,
        AField.Name, 'Item', childName, childHasType, childType,
        childHasSize, childSize);
      FP.ChildElemFieldName := childName;
      if childHasType then FP.ChildElemFieldType := childType;
      if childHasSize then FP.ChildElemFieldSize := childSize;
      if FP.ElemMember <> nil then
      begin
        if childHasType then FP.ElemMember.FieldType := childType;
        if childHasSize then FP.ElemMember.FieldSize := childSize;
      end;
    end;
  end
  else if FP.Kind = TDsKind.NestedDictionary then
  begin
    FP.DictKeyFieldName := 'Key';
    FP.DictValFieldName := 'Value';
    addM := (AField.FieldType as TRttiInstanceType).GetMethod('Add');
    if (addM <> nil) and (Length(addM.GetParameters) >= 2) then
    begin
      FP.DictKeyTypeInfo := addM.GetParameters[0].ParamType.Handle;
      FP.DictKeyMember := BuildMemberPlan(FP.DictKeyTypeInfo);
      Classify(FP.DictKeyTypeInfo, FP.DictKeyKind, FP.DictKeyFieldType, FP.DictKeyFieldSize);
      FP.DictKeyIsObject := (FP.DictKeyKind = TDsKind.NestedObject);
      FP.DictKeyHandler := ResolveMemberHandler(FP.DictKeyTypeInfo);
      if FP.DictKeyHandler <> nil then
      begin
        FP.DictKeyFieldType := FP.DictKeyHandler.FieldType;
        FP.DictKeyFieldSize := FP.DictKeyHandler.FieldSize;
      end;
      childName := FP.DictKeyFieldName;
      childHasType := False; childHasSize := False;
      childType := FP.DictKeyFieldType; childSize := FP.DictKeyFieldSize;
      ResolveChildOverride(APlan.TypeInfo, AField.Parent.Handle,
        AField.Name, 'Key', childName, childHasType, childType,
        childHasSize, childSize);
      FP.DictKeyFieldName := childName;
      if childHasType then FP.DictKeyFieldType := childType;
      if childHasSize then FP.DictKeyFieldSize := childSize;
      if FP.DictKeyMember <> nil then
      begin
        if childHasType then FP.DictKeyMember.FieldType := childType;
        if childHasSize then FP.DictKeyMember.FieldSize := childSize;
      end;

      FP.DictValTypeInfo := addM.GetParameters[1].ParamType.Handle;
      FP.DictValMember := BuildMemberPlan(FP.DictValTypeInfo);
      Classify(FP.DictValTypeInfo, FP.DictValKind, FP.DictValFieldType, FP.DictValFieldSize);
      FP.DictValIsObject := (FP.DictValKind = TDsKind.NestedObject);
      FP.DictValHandler := ResolveMemberHandler(FP.DictValTypeInfo);
      if FP.DictValHandler <> nil then
      begin
        FP.DictValFieldType := FP.DictValHandler.FieldType;
        FP.DictValFieldSize := FP.DictValHandler.FieldSize;
      end;
      childName := FP.DictValFieldName;
      childHasType := False; childHasSize := False;
      childType := FP.DictValFieldType; childSize := FP.DictValFieldSize;
      ResolveChildOverride(APlan.TypeInfo, AField.Parent.Handle,
        AField.Name, 'Value', childName, childHasType, childType,
        childHasSize, childSize);
      FP.DictValFieldName := childName;
      if childHasType then FP.DictValFieldType := childType;
      if childHasSize then FP.DictValFieldSize := childSize;
      if FP.DictValMember <> nil then
      begin
        if childHasType then FP.DictValMember.FieldType := childType;
        if childHasSize then FP.DictValMember.FieldSize := childSize;
      end;
    end;
  end;

  APlan.Fields.Add(FP);
end;

class procedure TDataSetEngine.WriteScalar(AKind: TDsKind; const AField: TField; const AValue: TValue);
var
  g: TGUID;
begin
  case AKind of
    TDsKind.BooleanValue: AField.AsBoolean := AValue.AsBoolean;
    TDsKind.IntegerValue:
      if AField.DataType in [ftByte, ftWord, ftLongWord] then
        AField.AsLargeInt := Int64(AValue.AsUInt64)
      else
        AField.AsInteger := AValue.AsInteger;
    TDsKind.Int64Value: AField.AsLargeInt := AValue.AsInt64;
    TDsKind.FloatValue: AField.AsFloat := AValue.AsExtended;
    TDsKind.CurrencyValue: AField.AsCurrency := AValue.AsCurrency;
    TDsKind.StringValue: AField.AsString := AValue.AsString;
    TDsKind.GuidValue: begin AValue.ExtractRawData(@g); AField.AsGuid := g; end;
    TDsKind.DateValue, TDsKind.TimeValue, TDsKind.DateTimeValue: AField.AsDateTime := AValue.AsExtended;
    TDsKind.EnumValue: AField.AsInteger := Integer(AValue.AsOrdinal);
    TDsKind.SetValue: AField.AsInteger := SetValueToInteger(AValue);
  else
    raise EDataSetSerializationError.CreateFmt('Unsupported DataSet scalar kind %d', [Ord(AKind)]);
  end;
end;

class procedure TDataSetEngine.WriteSetToField(AElemTI: PTypeInfo; ABits: Integer; const AField: TField; const AValue: TValue);
var
  p: PByte;
  sz, o, maxOrd: Integer;
  mask: Int64;
begin
  // build the bit mask by iterating the enum's valid ordinals (RTTI metadata),
  // testing membership -- independent of raw set storage layout.
  p := AValue.GetReferenceToRawData;
  sz := AValue.DataSize;
  maxOrd := GetTypeData(AElemTI).MaxValue;
  mask := 0;
  for o := GetTypeData(AElemTI).MinValue to maxOrd do
    if ((o shr 3) < sz) and ((PByte(p + (o shr 3))^ and (1 shl (o and 7))) <> 0) then
      mask := mask or (Int64(1) shl o);
  if ABits <= 32 then AField.AsInteger := Integer(mask) else AField.AsLargeInt := mask;
end;

function FieldDefNameExists(ADefs: TFieldDefs; const AName: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to ADefs.Count - 1 do
    if SameText(ADefs[I].Name, AName) then Exit(True);
  Result := False;
end;

procedure AddScalarDef(ADefs: TFieldDefs; const AName: string; AType: TFieldType; ASize: Integer);
begin
  if FieldDefNameExists(ADefs, AName) then
    raise EDataSetSerializationError.CreateFmt(
      'Duplicate DataSet field name "%s" while expanding a flattened object plan.', [AName]);
  if AType in [ftString, ftWideString, ftFixedChar, ftFixedWideChar] then
    ADefs.Add(AName, AType, ASize)
  else
    ADefs.Add(AName, AType);
end;

procedure ValidateFieldDefs(ADefs: TFieldDefs; const APath: string);
var
  I, J: Integer;
begin
  for I := 0 to ADefs.Count - 1 do
  begin
    for J := 0 to I - 1 do
      if SameText(ADefs[I].Name, ADefs[J].Name) then
        raise EDataSetSerializationError.CreateFmt(
          'Duplicate DataSet field name "%s%s" detected before DataSet creation.',
          [APath, ADefs[I].Name]);
    if ADefs[I].DataType = ftDataSet then
      ValidateFieldDefs(ADefs[I].ChildDefs, APath + ADefs[I].Name + '.');
  end;
end;

class procedure TDataSetEngine.AddMemberFieldRecursive(
  APlan: TDataSetMemberPlan; ADefs: TFieldDefs; const AName: string;
  AActiveTypes: TDictionary<PTypeInfo, Integer>);
var
  FD: TFieldDef;
  Prefix: string;
  ActiveCount: Integer;
begin
  if APlan = nil then
    raise EDataSetSerializationError.Create('Missing recursive DataSet member plan');
  case APlan.Kind of
    TDsKind.Unsupported: ;
    TDsKind.NullableValue:
      AddMemberFieldRecursive(APlan.Inner, ADefs, AName, AActiveTypes);
    TDsKind.NestedObject:
    begin
      if not AActiveTypes.TryGetValue(APlan.TypeInfo, ActiveCount) then
        ActiveCount := 0;
      if ActiveCount >= 2 then Exit;
      if AName = '' then Prefix := '' else Prefix := AName + '.';
      if APlan.TypeSerializer <> nil then
        APlan.TypeSerializer.AddFields(APlan.TypeInfo, ADefs, Prefix)
      else
        AddPlanFieldsRecursive(APlan.TypeInfo, ADefs, Prefix, AActiveTypes);
    end;
    TDsKind.NestedList:
    begin
      if (APlan.Item <> nil) and
         (APlan.Item.Kind = TDsKind.NestedObject) and
         AActiveTypes.TryGetValue(APlan.Item.TypeInfo, ActiveCount) and
         (ActiveCount >= 2) then Exit;
      FD := ADefs.AddFieldDef;
      FD.Name := AName;
      FD.DataType := ftDataSet;
      if APlan.Item.Kind = TDsKind.NestedObject then
        AddMemberFieldRecursive(APlan.Item, FD.ChildDefs, '', AActiveTypes)
      else
        AddMemberFieldRecursive(APlan.Item, FD.ChildDefs, 'Item', AActiveTypes);
    end;
    TDsKind.NestedDictionary:
    begin
      FD := ADefs.AddFieldDef;
      FD.Name := AName;
      FD.DataType := ftDataSet;
      AddMemberFieldRecursive(APlan.Key, FD.ChildDefs, 'Key', AActiveTypes);
      AddMemberFieldRecursive(APlan.Value, FD.ChildDefs, 'Value', AActiveTypes);
    end;
  else
    AddScalarDef(ADefs, AName, APlan.FieldType, APlan.FieldSize);
  end;
end;

class procedure TDataSetEngine.WriteMember(APlan: TDataSetMemberPlan;
  const AValue: TValue; ADataSet: TDataSet; const AName: string);
var
  F: TField;
  Base: Pointer;
  Nested: TDataSet;
  Arr, Elem, PairValue, KeyValue, ValValue: TValue;
  I: NativeInt;
  Enumerator: TObject;
  MoveNext: TRttiMethod;
  Current: TRttiProperty;
  PairType: TRttiType;
  KeyField, ValField: TRttiField;
  Prefix: string;
begin
  if APlan = nil then
    raise EDataSetSerializationError.Create('Missing recursive DataSet member plan');
  case APlan.Kind of
    TDsKind.Unsupported: ;
    TDsKind.NullableValue:
    begin
      if not APlan.NullableAccess.HasValue(AValue.GetReferenceToRawData) then
      begin
        F := ADataSet.FindField(AName);
        if F <> nil then F.Clear;
      end
      else
        WriteMember(APlan.Inner,
          APlan.NullableAccess.GetValue(AValue.GetReferenceToRawData),
          ADataSet, AName);
    end;
    TDsKind.NestedObject:
    begin
      if AName = '' then Prefix := '' else Prefix := AName + '.';
      if APlan.TypeSerializer <> nil then
      begin
        APlan.TypeSerializer.WriteValue(APlan.TypeInfo, AValue, ADataSet, Prefix);
        Exit;
      end;
      if APlan.TypeInfo.Kind = tkClass then Base := InstanceAddress(AValue.AsObject)
      else Base := AValue.GetReferenceToRawData;
      if Base <> nil then
        WritePlanFields(APlan.TypeInfo, Base, ADataSet, Prefix);
    end;
    TDsKind.NestedList:
    begin
      F := ADataSet.FindField(AName);
      if (F = nil) or (AValue.AsObject = nil) then Exit;
      Nested := TDataSetField(F).NestedDataSet;
      Arr := APlan.ToArrayMethod.Invoke(AValue.AsObject, []);
      for I := 0 to Arr.GetArrayLength - 1 do
      begin
        Elem := Arr.GetArrayElement(I);
        Nested.Append;
        if APlan.Item.Kind = TDsKind.NestedObject then
          WriteMember(APlan.Item, Elem, Nested, '')
        else
          WriteMember(APlan.Item, Elem, Nested, 'Item');
        Nested.Post;
      end;
    end;
    TDsKind.NestedDictionary:
    begin
      F := ADataSet.FindField(AName);
      if (F = nil) or (AValue.AsObject = nil) then Exit;
      Nested := TDataSetField(F).NestedDataSet;
      Enumerator := FCtx.GetType(AValue.AsObject.ClassType).GetMethod('GetEnumerator').Invoke(AValue.AsObject, []).AsObject;
      try
        MoveNext := FCtx.GetType(Enumerator.ClassType).GetMethod('MoveNext');
        Current := FCtx.GetType(Enumerator.ClassType).GetProperty('Current');
        PairType := Current.PropertyType;
        KeyField := PairType.GetField('Key');
        ValField := PairType.GetField('Value');
        while MoveNext.Invoke(Enumerator, []).AsBoolean do
        begin
          PairValue := Current.GetValue(InstanceAddress(Enumerator));
          KeyValue := KeyField.GetValue(PairValue.GetReferenceToRawData);
          ValValue := ValField.GetValue(PairValue.GetReferenceToRawData);
          Nested.Append;
          WriteMember(APlan.Key, KeyValue, Nested, 'Key');
          WriteMember(APlan.Value, ValValue, Nested, 'Value');
          Nested.Post;
        end;
      finally
        Enumerator.Free;
      end;
    end;
    TDsKind.CustomHandler:
    begin
      F := ADataSet.FindField(AName);
      if F <> nil then APlan.Handler.WriteValue(F, AValue);
    end;
    TDsKind.SetValue:
    begin
      F := ADataSet.FindField(AName);
      if F <> nil then WriteSetToField(APlan.SetElemTypeInfo, APlan.SetBits, F, AValue);
    end;
  else
    F := ADataSet.FindField(AName);
    if F <> nil then WriteScalar(APlan.Kind, F, AValue);
  end;
end;

class procedure TDataSetEngine.AddPlanFields(ATypeInfo: PTypeInfo; ADefs: TFieldDefs; const APrefix: string);
var ActiveTypes: TDictionary<PTypeInfo, Integer>;
begin
  ActiveTypes := TDictionary<PTypeInfo, Integer>.Create;
  try
    AddPlanFieldsRecursive(ATypeInfo, ADefs, APrefix, ActiveTypes);
  finally
    ActiveTypes.Free;
  end;
end;

class procedure TDataSetEngine.AddPlanFieldsRecursive(
  ATypeInfo: PTypeInfo; ADefs: TFieldDefs; const APrefix: string;
  AActiveTypes: TDictionary<PTypeInfo, Integer>);
var
  plan: TDataSetTypePlan;
  FP: TDataSetFieldPlan;
  fd: TFieldDef;
  ActiveCount, PriorActiveCount: Integer;
begin
  if not AActiveTypes.TryGetValue(ATypeInfo, PriorActiveCount) then
    PriorActiveCount := 0;
  { A static DataSet schema cannot represent an unbounded recursive Delphi
    type.  Preserve the root occurrence plus one recursive child occurrence;
    the next repeating branch is omitted.  Runtime rows at the retained child
    level are still mapped normally. }
  if PriorActiveCount >= 2 then Exit;
  AActiveTypes.AddOrSetValue(ATypeInfo, PriorActiveCount + 1);
  try
  plan := GetPlan(ATypeInfo);
  for FP in plan.Fields do
  begin
    case FP.Kind of
      TDsKind.Unsupported: ;
      TDsKind.NestedObject:
        if FP.TypeSerializer <> nil then
          FP.TypeSerializer.AddFields(FP.ChildTypeInfo, ADefs,
            APrefix + FP.DataSetFieldName + '.')
        else
          AddPlanFieldsRecursive(FP.ChildTypeInfo, ADefs,
            APrefix + FP.DataSetFieldName + '.', AActiveTypes);
      TDsKind.NestedList:
      begin
        if (FP.ElemMember <> nil) and
           (FP.ElemMember.Kind = TDsKind.NestedObject) and
           AActiveTypes.TryGetValue(FP.ElemMember.TypeInfo, ActiveCount) and
           (ActiveCount >= 2) then Continue;
        if FieldDefNameExists(ADefs, APrefix + FP.DataSetFieldName) then
          raise EDataSetSerializationError.CreateFmt(
            'Duplicate DataSet field name "%s" while expanding plan for %s.',
            [APrefix + FP.DataSetFieldName, UTF8ToString(ATypeInfo.Name)]);
        fd := ADefs.AddFieldDef;
        fd.Name := APrefix + FP.DataSetFieldName;
        fd.DataType := ftDataSet;
        if FP.ElemMember <> nil then
        begin
          if FP.ElemMember.Kind = TDsKind.NestedObject then
            AddMemberFieldRecursive(FP.ElemMember, fd.ChildDefs, '',
              AActiveTypes)
          else
            AddMemberFieldRecursive(FP.ElemMember, fd.ChildDefs,
              FP.ChildElemFieldName, AActiveTypes);
        end
        else if FP.ChildElemIsObject then
          AddPlanFieldsRecursive(FP.ChildElemTypeInfo, fd.ChildDefs, '',
            AActiveTypes)
        else
          AddScalarDef(fd.ChildDefs, FP.ChildElemFieldName,
            FP.ChildElemFieldType, FP.ChildElemFieldSize);
      end;
      TDsKind.NestedDictionary:
      begin
        if FieldDefNameExists(ADefs, APrefix + FP.DataSetFieldName) then
          raise EDataSetSerializationError.CreateFmt(
            'Duplicate DataSet field name "%s" while expanding plan for %s.',
            [APrefix + FP.DataSetFieldName, UTF8ToString(ATypeInfo.Name)]);
        fd := ADefs.AddFieldDef;
        fd.Name := APrefix + FP.DataSetFieldName;
        fd.DataType := ftDataSet;
        if FP.DictKeyMember <> nil then
          AddMemberFieldRecursive(FP.DictKeyMember, fd.ChildDefs,
            FP.DictKeyFieldName, AActiveTypes)
        else if FP.DictKeyIsObject then AddPlanFieldsRecursive(FP.DictKeyTypeInfo,
          fd.ChildDefs, FP.DictKeyFieldName + '.', AActiveTypes)
        else AddScalarDef(fd.ChildDefs, FP.DictKeyFieldName,
          FP.DictKeyFieldType, FP.DictKeyFieldSize);
        if FP.DictValMember <> nil then
          AddMemberFieldRecursive(FP.DictValMember, fd.ChildDefs,
            FP.DictValFieldName, AActiveTypes)
        else if FP.DictValIsObject then AddPlanFieldsRecursive(FP.DictValTypeInfo,
          fd.ChildDefs, FP.DictValFieldName + '.', AActiveTypes)
        else AddScalarDef(fd.ChildDefs, FP.DictValFieldName,
          FP.DictValFieldType, FP.DictValFieldSize);
      end;
    else
      AddScalarDef(ADefs, APrefix + FP.DataSetFieldName, FP.FieldType, FP.FieldSize);
    end;
  end;
  finally
    if PriorActiveCount = 0 then AActiveTypes.Remove(ATypeInfo)
    else AActiveTypes.AddOrSetValue(ATypeInfo, PriorActiveCount);
  end;
end;

class procedure TDataSetEngine.WritePlanFields(ATypeInfo: PTypeInfo; ABase: Pointer; ADataSet: TDataSet; const APrefix: string);
var
  plan: TDataSetTypePlan;
  FP: TDataSetFieldPlan;
  fld: TField;
  pData, childBase: Pointer;
  v, arr, elem: TValue;
  nestedDS: TDataSet;
  toArray: TRttiMethod;
  i: NativeInt;
begin
  plan := GetPlan(ATypeInfo);
  for FP in plan.Fields do
  begin
    pData := PByte(ABase) + FP.Offset;
    case FP.Kind of
      TDsKind.Unsupported: ;
      TDsKind.NestedObject:
      begin
        if FP.ChildTypeInfo.Kind = tkClass then childBase := PPointer(pData)^
        else childBase := pData;
        if childBase <> nil then
          if FP.TypeSerializer <> nil then
          begin
            TValue.Make(pData, FP.ChildTypeInfo, v);
            FP.TypeSerializer.WriteValue(FP.ChildTypeInfo, v, ADataSet,
              APrefix + FP.DataSetFieldName + '.');
          end
          else
            WritePlanFields(FP.ChildTypeInfo, childBase, ADataSet,
              APrefix + FP.DataSetFieldName + '.');
      end;
      TDsKind.NestedList:
      begin
        fld := ADataSet.FindField(APrefix + FP.DataSetFieldName);
        if (fld = nil) or (PObject(pData)^ = nil) then Continue;
        nestedDS := TDataSetField(fld).NestedDataSet;
        toArray := FCtx.GetType(PObject(pData)^.ClassType).GetMethod('ToArray');
        arr := toArray.Invoke(PObject(pData)^, []);
        for i := 0 to arr.GetArrayLength - 1 do
        begin
          elem := arr.GetArrayElement(i);
          nestedDS.Append;
          if FP.ElemMember <> nil then
          begin
            if FP.ElemMember.Kind = TDsKind.NestedObject then
              WriteMember(FP.ElemMember, elem, nestedDS, '')
            else
              WriteMember(FP.ElemMember, elem, nestedDS, FP.ChildElemFieldName);
          end
          else if FP.ChildElemIsObject then
            WritePlanFields(FP.ChildElemTypeInfo, InstanceAddress(elem.AsObject), nestedDS, '')
          else
            WriteMemberValue(FP.ChildElemHandler, FP.ChildElemKind,
              nestedDS.FieldByName(FP.ChildElemFieldName), elem);
          nestedDS.Post;
        end;
      end;
      TDsKind.NestedDictionary:
      begin
        fld := ADataSet.FindField(APrefix + FP.DataSetFieldName);
        if (fld = nil) or (PObject(pData)^ = nil) then Continue;
        WriteDictRows(FP, PObject(pData)^, TDataSetField(fld).NestedDataSet);
      end;
      TDsKind.CustomHandler:
      begin
        fld := ADataSet.FindField(APrefix + FP.DataSetFieldName);
        if fld <> nil then FP.Handler.WriteValue(fld, FP.Field.GetValue(ABase));
      end;
      TDsKind.NullableValue:
      begin
        fld := ADataSet.FindField(APrefix + FP.DataSetFieldName);
        if fld <> nil then
          if FP.NullableAccess.HasValue(pData) then
          begin
            v := FP.NullableAccess.GetValue(pData);
            if FP.Handler <> nil then FP.Handler.WriteValue(fld, v)
            else if FP.InnerKind = TDsKind.SetValue then WriteSetToField(FP.SetElemTypeInfo, FP.SetBits, fld, v)
            else WriteScalar(FP.InnerKind, fld, v);
          end
          else
            fld.Clear;
      end;
      TDsKind.SetValue:
      begin
        fld := ADataSet.FindField(APrefix + FP.DataSetFieldName);
        if fld <> nil then WriteSetToField(FP.SetElemTypeInfo, FP.SetBits, fld, FP.Field.GetValue(ABase));
      end;
    else
      fld := ADataSet.FindField(APrefix + FP.DataSetFieldName);
      if fld <> nil then
      begin
        v := FP.Field.GetValue(ABase);
        WriteScalar(FP.Kind, fld, v);
      end;
    end;
  end;
end;

class procedure TDataSetEngine.WriteDictRows(AFP: TDataSetFieldPlan; const ADict: TObject; ANestedDS: TDataSet);
var
  enum: TObject;
  moveNext: TRttiMethod;
  currentProp: TRttiProperty;
  pairType: TRttiType;
  keyF, valF: TRttiField;
  pair, keyV, valV: TValue;
  keyBase, valBase: Pointer;
begin
  enum := FCtx.GetType(ADict.ClassType).GetMethod('GetEnumerator').Invoke(ADict, []).AsObject;
  try
    moveNext := FCtx.GetType(enum.ClassType).GetMethod('MoveNext');
    currentProp := FCtx.GetType(enum.ClassType).GetProperty('Current');
    pairType := currentProp.PropertyType;
    keyF := pairType.GetField('Key');
    valF := pairType.GetField('Value');
    while moveNext.Invoke(enum, []).AsBoolean do
    begin
      pair := currentProp.GetValue(InstanceAddress(enum));
      keyV := keyF.GetValue(pair.GetReferenceToRawData);
      valV := valF.GetValue(pair.GetReferenceToRawData);
      ANestedDS.Append;
      if AFP.DictKeyMember <> nil then
        WriteMember(AFP.DictKeyMember, keyV, ANestedDS, AFP.DictKeyFieldName)
      else if AFP.DictKeyIsObject then
      begin
        if AFP.DictKeyTypeInfo.Kind = tkClass then keyBase := InstanceAddress(keyV.AsObject) else keyBase := keyV.GetReferenceToRawData;
        if keyBase <> nil then WritePlanFields(AFP.DictKeyTypeInfo, keyBase,
          ANestedDS, AFP.DictKeyFieldName + '.');
      end
      else
        WriteMemberValue(AFP.DictKeyHandler, AFP.DictKeyKind,
          ANestedDS.FieldByName(AFP.DictKeyFieldName), keyV);
      if AFP.DictValMember <> nil then
        WriteMember(AFP.DictValMember, valV, ANestedDS, AFP.DictValFieldName)
      else if AFP.DictValIsObject then
      begin
        if AFP.DictValTypeInfo.Kind = tkClass then valBase := InstanceAddress(valV.AsObject) else valBase := valV.GetReferenceToRawData;
        if valBase <> nil then WritePlanFields(AFP.DictValTypeInfo, valBase,
          ANestedDS, AFP.DictValFieldName + '.');
      end
      else
        WriteMemberValue(AFP.DictValHandler, AFP.DictValKind,
          ANestedDS.FieldByName(AFP.DictValFieldName), valV);
      ANestedDS.Post;
    end;
  finally
    enum.Free;
  end;
end;

class procedure TDataSetEngine.WriteTypedValue(AFP: TDataSetFieldPlan; const AField: TField; const AValue: TValue; AHasValue: Boolean);
begin
  if not AHasValue then AField.Clear
  else if AFP.Handler <> nil then AFP.Handler.WriteValue(AField, AValue)
  else if (AFP.Kind = TDsKind.SetValue) or ((AFP.Kind = TDsKind.NullableValue) and (AFP.InnerKind = TDsKind.SetValue)) then
    WriteSetToField(AFP.SetElemTypeInfo, AFP.SetBits, AField, AValue)
  else if AFP.Kind = TDsKind.NullableValue then
    WriteScalar(AFP.InnerKind, AField, AValue)
  else
    WriteScalar(AFP.Kind, AField, AValue);
end;

class procedure TDataSetEngine.WriteMemberValue(AHandler: TCustomDataSetFieldHandler; AKind: TDsKind; const AField: TField; const AValue: TValue);
begin
  if AHandler <> nil then AHandler.WriteValue(AField, AValue)
  else WriteScalar(AKind, AField, AValue);
end;

class procedure TDataSetEngine.AddTypeProjection(ATypeInfo: PTypeInfo;
  AFieldDefs: TFieldDefs; const AName: string);
var
  K: TDsKind;
  FT: TFieldType;
  Size: Integer;
  H: TCustomDataSetFieldHandler;
  S: TCustomDataSetTypeSerializer;
begin
  H := ResolveMemberHandler(ATypeInfo);
  if H <> nil then
  begin
    AddScalarDef(AFieldDefs, AName, H.FieldType, H.FieldSize);
    Exit;
  end;
  if FindTypeSerializer(ATypeInfo, S) then
  begin
    S.AddFields(ATypeInfo, AFieldDefs, AName + '.');
    Exit;
  end;
  Classify(ATypeInfo, K, FT, Size);
  if K = TDsKind.NestedObject then AddPlanFields(ATypeInfo, AFieldDefs, AName + '.')
  else AddScalarDef(AFieldDefs, AName, FT, Size);
end;

class procedure TDataSetEngine.WriteTypeProjection(ATypeInfo: PTypeInfo;
  const AValue: TValue; ADataSet: TDataSet; const AName: string);
var
  K: TDsKind;
  FT: TFieldType;
  Size: Integer;
  H: TCustomDataSetFieldHandler;
  S: TCustomDataSetTypeSerializer;
  Base: Pointer;
  F: TField;
begin
  H := ResolveMemberHandler(ATypeInfo);
  if FindTypeSerializer(ATypeInfo, S) then
  begin
    S.WriteValue(ATypeInfo, AValue, ADataSet, AName + '.');
    Exit;
  end;
  Classify(ATypeInfo, K, FT, Size);
  if K = TDsKind.NestedObject then
  begin
    if ATypeInfo.Kind = tkClass then Base := InstanceAddress(AValue.AsObject)
    else Base := AValue.GetReferenceToRawData;
    if Base <> nil then WritePlanFields(ATypeInfo, Base, ADataSet, AName + '.');
    Exit;
  end;
  F := ADataSet.FindField(AName);
  if F = nil then Exit;
  if H <> nil then H.WriteValue(F, AValue) else WriteScalar(K, F, AValue);
end;

class procedure TDataSetEngine.DoCreateStructure(ATypeInfo: PTypeInfo; ADataSet: TDataSet);
var
  Plan: TDataSetTypePlan;
  S: TCustomDataSetTypeSerializer;
begin
  ADataSet.Close;
  ADataSet.FieldDefs.Clear;
  if FindTypeSerializer(ATypeInfo, S) then Plan := nil else Plan := GetPlan(ATypeInfo);
  if (Plan <> nil) and (Plan.Fields.Count = 0) then Exit;
  try
    if S <> nil then S.AddFields(ATypeInfo, ADataSet.FieldDefs, '')
    else AddPlanFields(ATypeInfo, ADataSet.FieldDefs, '');
  except
    on E: EDatabaseError do
      if E.Message.Contains('Duplicate name') then
        raise EDataSetSerializationError.CreateFmt(
          'Duplicate logical DataSet field while expanding plan for %s: %s',
          [UTF8ToString(ATypeInfo.Name), E.Message])
      else
        raise;
  end;
  ValidateFieldDefs(ADataSet.FieldDefs, '');
  ActivateDataSet(ADataSet);
end;

class procedure TDataSetEngine.ActivateDataSet(ADataSet: TDataSet);
begin
  { An in-memory dataset has to be told that the field definitions are
    complete before it can be appended to.  TDataSet does not declare that
    step, so the two supported implementations are named explicitly.  A
    dataset of any other class is left alone: it is the caller's, and it may
    already be open or may be opened some other way. }
  if ADataSet is TFDMemTable then
    TFDMemTable(ADataSet).CreateDataSet
  else if ADataSet is TClientDataSet then
    TClientDataSet(ADataSet).CreateDataSet;
end;

class procedure TDataSetEngine.DoAppend(ATypeInfo: PTypeInfo; ABase: Pointer; ADataSet: TDataSet);
var
  S: TCustomDataSetTypeSerializer;
  V: TValue;
  O: TObject;
begin
  { A zero-field DTO has no DataSet projection.  FireDAC cannot open or append
    such a table, so Fill is intentionally a no-op and the table remains
    closed, with no artificial compatibility field. }
  if not FindTypeSerializer(ATypeInfo, S) and (GetPlan(ATypeInfo).Fields.Count = 0) then Exit;
  ADataSet.Append;
  if S <> nil then
  begin
    O := PObject(@ABase)^;
    TValue.Make(@O, ATypeInfo, V);
    S.WriteValue(ATypeInfo, V, ADataSet, '');
  end
  else WritePlanFields(ATypeInfo, ABase, ADataSet, '');
  ADataSet.Post;
end;


class procedure TDataSetEngine.CreateStructure(ATypeInfo: PTypeInfo; ADataSet: TDataSet);
begin
  DoCreateStructure(ATypeInfo, ADataSet);
end;


class procedure TDataSetEngine.Fill(ATypeInfo: PTypeInfo; const AInstance: TObject; ADataSet: TDataSet);
begin
  if AInstance = nil then Exit;
  DoAppend(ATypeInfo, InstanceAddress(AInstance), ADataSet);
end;

class procedure TDataSetEngine.FillRaw(ATypeInfo: PTypeInfo;
  ABase: Pointer; ADataSet: TDataSet);
begin
  DoAppend(ATypeInfo, ABase, ADataSet);
end;

end.
