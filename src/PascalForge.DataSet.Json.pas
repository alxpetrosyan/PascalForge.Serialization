{*******************************************************************************
  PascalForge.DataSet.Json

  Public JSON/DataSet integration unit for PascalForge.Serialization.

  Responsibilities
    - TDataSet-typed members inside JSON documents, written as DataSet
      packets (TDataSetJsonIntegration).
    - DTO-contract helpers that read JSON through a Delphi type into a
      DataSet: CreateStructure, Append, Fill.

  Registration
    TDataSet members inside JSON documents require an explicit startup call,
    TDataSetJsonIntegration.Register. Nothing calls it for you.

  Configuration
    The DataSet factory and policies freeze once JSON or DataSet
    configuration has frozen, or once the integration has been used.

  Documentation
    docs/dataset-formats.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.DataSet.Json;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  WHERE JSON AND DATASET MEET

  This unit is NOT the way to turn a DataSet into a document. That is
  TDataSetSerializer.Serialize, which takes the format as an argument and
  writes JSON, XML, BSON or anything else the registry knows from one
  implementation.

  What lives here is the part that is genuinely about JSON and could not be
  anywhere else: a Delphi type with a TDataSet-typed MEMBER, serialized as
  part of a larger JSON document.

      type
        TReport = class
          Title: string;
          Rows: TFDMemTable;   // this
        end;

  Making that work needs JSON's own serializer-registration machinery, its
  member context and its plans, so it needs to see PascalForge.Json. The
  DataSet packet it writes into that member is built by the shared code in
  PascalForge.DataSet.Packet, so a nested table is spelled exactly as a
  top-level one.

  Also here: the DTO-contract helpers - CreateStructure, Append, Fill - which
  read a JSON document THROUGH a Delphi type rather than structurally, and so
  need JSON's plans as well.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.TypInfo, System.Rtti, System.JSON,
  System.Generics.Collections, Data.DB, PascalForge.DataSet, PascalForge.Json;

type
  { Consulted when a TDataSet-typed member has to be constructed during
    deserialization, before the built-in rules. }
  TDataSetFactory = reference to function(ADeclaredClass: TClass): TDataSet;

  { The hook for replacing how a TDataSet member is written and read. Derive,
    override the two methods, and register the class with
    TJsonSerializer.RegisterClassTypeSerializer. }
  TCustomDataSetJsonSerializer = class(TCustomJsonValueSerializer)
  protected
    function DataSetToJson(ADataSet: TDataSet;
      const AContext: TJsonSerializerContext): TJSONValue; virtual; abstract;
    procedure JsonToDataSet(const AJson: TJSONValue; ADataSet: TDataSet;
      const AContext: TJsonSerializerContext); virtual; abstract;
  public
    function SerializeValue(const AValue: TValue): TJSONValue; override;
    function DeserializeValue(const AJson: TJSONValue;
      ATypeInfo: PTypeInfo): TValue; override;
    function DeserializeInto(const AJson: TJSONValue; ATypeInfo: PTypeInfo;
      AExisting: TObject; out AValue: TValue): Boolean; override;
    function SerializeValueContext(const AValue: TValue;
      const AContext: TJsonSerializerContext): TJSONValue; override;
    function DeserializeValueContext(const AJson: TJSONValue;
      ATypeInfo: PTypeInfo; const AContext: TJsonSerializerContext): TValue; override;
    function DeserializeIntoContext(const AJson: TJSONValue;
      ATypeInfo: PTypeInfo; AExisting: TObject;
      const AContext: TJsonSerializerContext; out AValue: TValue): Boolean; override;
  end;

  { ------------------------------------------------------------------------
    A DATASET INSIDE A JSON DOCUMENT

    Registration, policy resolution and construction for TDataSet-typed
    members. Call Register once, at startup - nothing calls it for you - and
    any member whose type descends from TDataSet is written as a packet and
    read back as one.

    LIFECYCLE. The factory and the policies are configuration: they may be
    set before the integration is used, and are refused - with
    EDataSetSerializationError - once JSON or DataSet configuration has
    frozen, or once the integration has resolved a policy or built a DataSet
    for a document. They are never mutated while documents are read or
    written.

    The policy is TDataSetSerializationPolicy, the same one
    TDataSetSerializer.Serialize takes. There is no JSON-specific policy type
    and never was a good reason for one: what goes into the document does not
    depend on how the document is spelled.
    ------------------------------------------------------------------------ }
  TDataSetJsonIntegration = class
  strict private
    class var FDefaultPolicy: TDataSetSerializationPolicy;
    class var FDataSetFactory: TDataSetFactory;
    class var FTypePolicies: TDictionary<TClass, TDataSetSerializationPolicy>;
    class var FFieldPolicies: TDictionary<string, TDataSetSerializationPolicy>;
    class var FInUse: Boolean;
    class var FRegistered: Boolean;
    class procedure CheckNotFrozen(const AWhat: string); static;
    class function GetDataSetFactory: TDataSetFactory; static;
    class procedure SetDataSetFactory(const AValue: TDataSetFactory); static;
    class function PolicyKey(AOwnerTypeInfo: PTypeInfo;
      const AMemberName: string): string; static;
    class procedure WriteFromJson(ATypeInfo: PTypeInfo;
      const AJson: TJSONObject; ADataSet: TDataSet; const APrefix: string); static;
  public
    class constructor Create;
    class destructor Destroy;

    { Consulted before the built-in construction rules. A property rather
      than a public class var so that changing it after
      TDataSetSerializer.FreezeConfiguration is a clear configuration error
      instead of a silent divergence from already-built plans. }
    class property DataSetFactory: TDataSetFactory read GetDataSetFactory
      write SetDataSetFactory;

    { What a nested DataSet member gets when nothing more specific applies.
      StructureAndRows out of the box, because a member read back has no
      other schema to fall back on. }
    class procedure SetDefaultPolicy(APolicy: TDataSetSerializationPolicy); static;
    class procedure RegisterTypePolicy<T: TDataSet>(
      APolicy: TDataSetSerializationPolicy); overload; static;
    class procedure RegisterTypePolicy(ADataSetClass: TClass;
      APolicy: TDataSetSerializationPolicy); overload; static;
    class procedure RegisterFieldPolicy<T>(const AMemberName: string;
      APolicy: TDataSetSerializationPolicy); overload; static;
    class procedure RegisterFieldPolicy(AOwnerTypeInfo: PTypeInfo;
      const AMemberName: string;
      APolicy: TDataSetSerializationPolicy); overload; static;
    { Member policy, then type policy walking up the class hierarchy, then
      the default. }
    class function ResolvePolicy(ADataSetClass: TClass;
      const AContext: TJsonSerializerContext): TDataSetSerializationPolicy; static;

    { The DataSet for a member of this declared type, through the factory
      when one is set. }
    class function CreateDataSet(ADeclaredClass: TClass): TDataSet; static;

    { --- the DTO-contract helpers --------------------------------------

      These read JSON THROUGH a Delphi type: the type decides the columns
      and the conversions, exactly as TDataSetSerializer.CreateStructure<T>
      does, and the JSON is matched against its members. Structural
      inference is not involved and neither is the packet. }
    class procedure CreateStructure<T>(ADataSet: TDataSet); static;
    class procedure Append<T>(const AJson: TJSONObject; ADataSet: TDataSet); static;
    class procedure Fill<T>(const AJson: TJSONArray; ADataSet: TDataSet); static;

    { Teaches TJsonSerializer that a TDataSet-typed member is a packet. An
      explicit startup call - no unit makes it for you - and idempotent. }
    class procedure Register; static;
    class function IsRegistered: Boolean; static;
    { Whether the factory and policies can still change. }
    class function IsFrozen: Boolean; static;
  end;

implementation

uses
  System.DateUtils, System.Variants, Datasnap.DBClient,
  FireDAC.Comp.Client, FireDAC.Comp.DataSet,
  { The engines. This unit is part of the library, not an application of it:
    it reuses plan decisions both serializers have already made so a DataSet
    column and a JSON member cannot disagree. }
  PascalForge.Json.Internal, PascalForge.DataSet.Internal,
  { The packet, built once for every format. }
  PascalForge.DataSet.Packet,
  PascalForge.Serialization.Core, PascalForge.Dynamic;

type
  TDataSetJsonFieldSerializer = class(TCustomDataSetJsonSerializer)
  protected
    function DataSetToJson(ADataSet: TDataSet;
      const AContext: TJsonSerializerContext): TJSONValue; override;
    procedure JsonToDataSet(const AJson: TJSONValue; ADataSet: TDataSet;
      const AContext: TJsonSerializerContext); override;
  end;

{ --------------------------------------------------- the packet, as JSON --- }

function PacketAsJson(ADataSet: TDataSet;
  APolicy: TDataSetSerializationPolicy): TJSONValue;
var
  Tree: TDynamicValue;
begin
  Tree := TDataSetSerializer.ToDynamic(ADataSet, APolicy);
  try
    Result := TJsonEngine.DynamicToJson(Tree);
  finally
    Tree.Free;
  end;
end;

procedure JsonAsPacket(const AJson: TJSONValue; ADataSet: TDataSet;
  APolicy: TDataSetSerializationPolicy);
var
  Tree: TDynamicValue;
begin
  if (AJson = nil) or (AJson is TJSONNull) or (ADataSet = nil) then Exit;
  Tree := TJsonEngine.JsonToDynamic(AJson);
  try
    ApplyPacket(Tree, ADataSet, APolicy);
  finally
    Tree.Free;
  end;
end;

{ -------------------------------------------------------- the policy map --- }

class constructor TDataSetJsonIntegration.Create;
begin
  FTypePolicies := TDictionary<TClass, TDataSetSerializationPolicy>.Create;
  FFieldPolicies := TDictionary<string, TDataSetSerializationPolicy>.Create;
  FDefaultPolicy := TDataSetSerializationPolicy.StructureAndRows;
end;

class destructor TDataSetJsonIntegration.Destroy;
begin
  FTypePolicies.Free;
  FFieldPolicies.Free;
end;

class function TDataSetJsonIntegration.GetDataSetFactory: TDataSetFactory;
begin
  Result := FDataSetFactory;
end;

class function TDataSetJsonIntegration.IsFrozen: Boolean;
begin
  Result := FInUse or TDataSetSerializer.IsFrozen or TJsonSerializer.IsFrozen;
end;

class procedure TDataSetJsonIntegration.CheckNotFrozen(const AWhat: string);
begin
  if IsFrozen then
    raise EDataSetSerializationError.CreateFmt(
      'The DataSet-in-JSON %s cannot change now: JSON or DataSet ' +
      'configuration has frozen, or the integration has already been used. ' +
      'Set it at startup, before the first document.', [AWhat]);
end;

class procedure TDataSetJsonIntegration.SetDataSetFactory(
  const AValue: TDataSetFactory);
begin
  CheckNotFrozen('factory');
  FDataSetFactory := AValue;
end;

class function TDataSetJsonIntegration.PolicyKey(AOwnerTypeInfo: PTypeInfo;
  const AMemberName: string): string;
begin
  if AOwnerTypeInfo = nil then Exit('');
  Result := UTF8ToString(AOwnerTypeInfo.Name) + '.' + AMemberName;
end;

class procedure TDataSetJsonIntegration.SetDefaultPolicy(
  APolicy: TDataSetSerializationPolicy);
begin
  CheckNotFrozen('default policy');
  FDefaultPolicy := APolicy;
end;

class procedure TDataSetJsonIntegration.RegisterTypePolicy(
  ADataSetClass: TClass; APolicy: TDataSetSerializationPolicy);
begin
  CheckNotFrozen('type policy');
  FTypePolicies.AddOrSetValue(ADataSetClass, APolicy);
end;

class procedure TDataSetJsonIntegration.RegisterTypePolicy<T>(
  APolicy: TDataSetSerializationPolicy);
begin
  RegisterTypePolicy(T, APolicy);
end;

class procedure TDataSetJsonIntegration.RegisterFieldPolicy(
  AOwnerTypeInfo: PTypeInfo; const AMemberName: string;
  APolicy: TDataSetSerializationPolicy);
begin
  CheckNotFrozen('field policy');
  FFieldPolicies.AddOrSetValue(PolicyKey(AOwnerTypeInfo, AMemberName), APolicy);
end;

class procedure TDataSetJsonIntegration.RegisterFieldPolicy<T>(
  const AMemberName: string; APolicy: TDataSetSerializationPolicy);
begin
  RegisterFieldPolicy(System.TypeInfo(T), AMemberName, APolicy);
end;

class function TDataSetJsonIntegration.ResolvePolicy(ADataSetClass: TClass;
  const AContext: TJsonSerializerContext): TDataSetSerializationPolicy;
var
  C: TClass;
begin
  { From here on the dictionaries are only read. }
  FInUse := True;
  if FFieldPolicies.TryGetValue(PolicyKey(AContext.OwnerTypeInfo,
    AContext.MemberName), Result) then Exit;
  C := ADataSetClass;
  while C <> nil do
  begin
    if FTypePolicies.TryGetValue(C, Result) then Exit;
    C := C.ClassParent;
  end;
  Result := FDefaultPolicy;
end;

class function TDataSetJsonIntegration.CreateDataSet(
  ADeclaredClass: TClass): TDataSet;
begin
  FInUse := True;
  if Assigned(DataSetFactory) then Exit(DataSetFactory(ADeclaredClass));
  if (ADeclaredClass = nil) or (ADeclaredClass = TDataSet) then
    Exit(TFDMemTable.Create(nil));
  if not ADeclaredClass.InheritsFrom(TDataSet) then
    raise EDataSetSerializationError.CreateFmt('%s is not a TDataSet class',
      [ADeclaredClass.ClassName]);
  Result := TDataSet(TComponentClass(ADeclaredClass).Create(nil));
end;

class procedure TDataSetJsonIntegration.Register;
begin
  if FRegistered then Exit;
  TJsonSerializer.RegisterClassTypeSerializer(TDataSet,
    TDataSetJsonFieldSerializer);
  FRegistered := True;
end;

class function TDataSetJsonIntegration.IsRegistered: Boolean;
begin
  Result := FRegistered;
end;

{ ---------------------------------------------------- the member serializer }

function TCustomDataSetJsonSerializer.SerializeValue(
  const AValue: TValue): TJSONValue;
begin
  Result := SerializeValueContext(AValue, Default(TJsonSerializerContext));
end;

function TCustomDataSetJsonSerializer.DeserializeValue(const AJson: TJSONValue;
  ATypeInfo: PTypeInfo): TValue;
begin
  Result := DeserializeValueContext(AJson, ATypeInfo,
    Default(TJsonSerializerContext));
end;

function TCustomDataSetJsonSerializer.DeserializeInto(const AJson: TJSONValue;
  ATypeInfo: PTypeInfo; AExisting: TObject; out AValue: TValue): Boolean;
begin
  Result := DeserializeIntoContext(AJson, ATypeInfo, AExisting,
    Default(TJsonSerializerContext), AValue);
end;

function TCustomDataSetJsonSerializer.SerializeValueContext(
  const AValue: TValue; const AContext: TJsonSerializerContext): TJSONValue;
var
  DataSet: TDataSet;
begin
  DataSet := TDataSet(AValue.AsObject);
  if DataSet = nil then Exit(TJSONNull.Create);
  Result := DataSetToJson(DataSet, AContext);
end;

function TCustomDataSetJsonSerializer.DeserializeValueContext(
  const AJson: TJSONValue; ATypeInfo: PTypeInfo;
  const AContext: TJsonSerializerContext): TValue;
var
  DataSet: TDataSet;
  Obj: TObject;
begin
  DataSet := nil;
  if not (AJson is TJSONNull) then
  begin
    DataSet := TDataSetJsonIntegration.CreateDataSet(ATypeInfo.TypeData.ClassType);
    try
      JsonToDataSet(AJson, DataSet, AContext);
    except
      DataSet.Free;
      raise;
    end;
  end;
  Obj := DataSet;
  TValue.Make(@Obj, ATypeInfo, Result);
end;

function TCustomDataSetJsonSerializer.DeserializeIntoContext(
  const AJson: TJSONValue; ATypeInfo: PTypeInfo; AExisting: TObject;
  const AContext: TJsonSerializerContext; out AValue: TValue): Boolean;
var
  DataSet: TDataSet;
  Obj: TObject;
  OwnsDataSet: Boolean;
begin
  Result := True;
  DataSet := nil;
  OwnsDataSet := False;
  if not (AJson is TJSONNull) then
  begin
    if AExisting is TDataSet then DataSet := TDataSet(AExisting)
    else
    begin
      DataSet := TDataSetJsonIntegration.CreateDataSet(ATypeInfo.TypeData.ClassType);
      OwnsDataSet := True;
    end;
    try
      JsonToDataSet(AJson, DataSet, AContext);
    except
      if OwnsDataSet then DataSet.Free;
      raise;
    end;
  end;
  Obj := DataSet;
  TValue.Make(@Obj, ATypeInfo, AValue);
end;

function TDataSetJsonFieldSerializer.DataSetToJson(ADataSet: TDataSet;
  const AContext: TJsonSerializerContext): TJSONValue;
begin
  Result := PacketAsJson(ADataSet,
    TDataSetJsonIntegration.ResolvePolicy(ADataSet.ClassType, AContext));
end;

procedure TDataSetJsonFieldSerializer.JsonToDataSet(const AJson: TJSONValue;
  ADataSet: TDataSet; const AContext: TJsonSerializerContext);
begin
  JsonAsPacket(AJson, ADataSet,
    TDataSetJsonIntegration.ResolvePolicy(ADataSet.ClassType, AContext));
end;

{ ------------------------------------------------- the DTO-contract path --- }

class procedure TDataSetJsonIntegration.CreateStructure<T>(ADataSet: TDataSet);
begin
  TDataSetSerializer.CreateStructure<T>(ADataSet);
end;

class procedure TDataSetJsonIntegration.WriteFromJson(ATypeInfo: PTypeInfo; const AJson: TJSONObject; ADataSet: TDataSet; const APrefix: string);
var
  plan: TDataSetTypePlan;
  FP: TDataSetFieldPlan;
  jsonName: string;
  member, item: TJSONValue;
  fld: TField;
  nestedDS: TDataSet;
  arr: TJSONArray;
  pair: TJSONPair;
  v: TValue;
  hasVal: Boolean;
begin
  plan := TDataSetEngine.PlanFor(ATypeInfo);
  for FP in plan.Fields do
  begin
    if FP.Kind = TDsKind.Unsupported then Continue;
    if not TJsonEngine.TryGetFieldJsonName(ATypeInfo, FP.SourceFieldName, jsonName) then
      jsonName := FP.JsonName;
    member := AJson.Values[jsonName];

    case FP.Kind of
      TDsKind.NestedObject:
        if member is TJSONObject then
          WriteFromJson(FP.ChildTypeInfo, TJSONObject(member), ADataSet, APrefix + FP.DataSetFieldName + '.');
      TDsKind.NestedList:
      begin
        fld := ADataSet.FindField(APrefix + FP.DataSetFieldName);
        if (fld <> nil) and (member is TJSONArray) then
        begin
          nestedDS := TDataSetField(fld).NestedDataSet;
          arr := TJSONArray(member);
          for item in arr do
          begin
            nestedDS.Append;
            if FP.ChildElemIsObject and (item is TJSONObject) then
              WriteFromJson(FP.ChildElemTypeInfo, TJSONObject(item), nestedDS, '')
            else
              TDataSetEngine.WriteMemberValue(FP.ChildElemHandler, FP.ChildElemKind,
                nestedDS.FieldByName('Item'),
                TJsonEngine.ConvertListElement(ATypeInfo, FP.SourceFieldName, item));
            nestedDS.Post;
          end;
        end;
      end;
      TDsKind.NestedDictionary:
      begin
        fld := ADataSet.FindField(APrefix + FP.DataSetFieldName);
        if (fld <> nil) and (member is TJSONObject) then
        begin
          nestedDS := TDataSetField(fld).NestedDataSet;
          for pair in TJSONObject(member) do
          begin
            nestedDS.Append;
            if not FP.DictKeyIsObject then
              TDataSetEngine.WriteMemberValue(FP.DictKeyHandler, FP.DictKeyKind, nestedDS.FieldByName('Key'),
                TJsonEngine.ConvertDictKey(ATypeInfo, FP.SourceFieldName, pair.JsonString.Value));
            if FP.DictValIsObject and (pair.JsonValue is TJSONObject) then
              WriteFromJson(FP.DictValTypeInfo, TJSONObject(pair.JsonValue), nestedDS, 'Value.')
            else if not FP.DictValIsObject then
              TDataSetEngine.WriteMemberValue(FP.DictValHandler, FP.DictValKind, nestedDS.FieldByName('Value'),
                TJsonEngine.ConvertDictValue(ATypeInfo, FP.SourceFieldName, pair.JsonValue));
            nestedDS.Post;
          end;
        end;
      end;
    else
      // scalar / enum / nullable / handler / guid / date -> reuse real JSON conversion
      fld := ADataSet.FindField(APrefix + FP.DataSetFieldName);
      if fld <> nil then
        if TJsonEngine.ConvertMember(ATypeInfo, FP.SourceFieldName, member, v, hasVal) then
          TDataSetEngine.WriteTypedValue(FP, fld, v, hasVal)
        else if (member = nil) or (member is TJSONNull) then
          fld.Clear;
    end;
  end;
end;

class procedure TDataSetJsonIntegration.Append<T>(const AJson: TJSONObject; ADataSet: TDataSet);
begin
  ADataSet.Append;
  WriteFromJson(System.TypeInfo(T), AJson, ADataSet, '');
  ADataSet.Post;
end;

class procedure TDataSetJsonIntegration.Fill<T>(const AJson: TJSONArray; ADataSet: TDataSet);
var
  item: TJSONValue;
begin
  for item in AJson do
    if item is TJSONObject then
      Append<T>(TJSONObject(item), ADataSet);
end;

end.
