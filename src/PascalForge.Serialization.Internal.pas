{*******************************************************************************
  PascalForge.Serialization.Internal

  INTERNAL IMPLEMENTATION UNIT - applications should not use this unit directly.

  The shared RTTI metadata layer of PascalForge.Serialization.

  Responsibilities
    - The format-neutral facts about a Delphi type, discovered once and
      cached: its RTTI type, record or class, constructors, and its members
      - which fields and properties make up its serialized surface, which
      member wins when a descendant redeclares a name, what type each one
      is, whether it can be read and written.
    - The general attributes ([SerializationName], [SerializationIgnore],
      [SerializationEnum]) resolved per member and per type, once.

  Every engine builds its own plan - names under its own conventions, its
  own attributes, wire types, schemas - ON TOP of these facts; nothing here
  knows any format.

  Threading
    Thread-safe. Metadata is built on first request under a lock and never
    changes afterwards. Nothing is registered and nothing is built at unit
    initialization.

  Used by every format engine, the DataSet projection and Dynamic; the
  general attributes it reads are public in
  PascalForge.Serialization.Attributes.

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Serialization.Internal;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Rtti, System.TypInfo, System.SyncObjs,
  System.Generics.Collections,
  PascalForge.Serialization.Attributes;

type
  { One field or property, with the general attributes already read. }
  TSerializationMember = class
  strict private
    FMember: TRttiMember;
    FMemberType: TRttiType;
    FIsField: Boolean;
    FVisibility: TMemberVisibility;
    FIsReadable: Boolean;
    FIsWritable: Boolean;
    FGeneralName: string;
    FHasGeneralName: Boolean;
    FIgnored: Boolean;
    FEnumValues: TArray<string>;
    FHasEnumValues: Boolean;
  public
    constructor Create(AMember: TRttiMember);
    property Member: TRttiMember read FMember;
    function Field: TRttiField;
    function Prop: TRttiProperty;
    { The Delphi identifier. }
    function Name: string;
    property MemberType: TRttiType read FMemberType;
    function TypeInfo: PTypeInfo;
    property IsField: Boolean read FIsField;
    property Visibility: TMemberVisibility read FVisibility;
    property IsReadable: Boolean read FIsReadable;
    property IsWritable: Boolean read FIsWritable;
    { [SerializationName], when the member has one. }
    property HasGeneralName: Boolean read FHasGeneralName;
    property GeneralName: string read FGeneralName;
    { [SerializationIgnore]: the member is not part of any format's surface. }
    property Ignored: Boolean read FIgnored;
    { [SerializationEnum] on the member itself - not on its type. }
    property HasEnumValues: Boolean read FHasEnumValues;
    property EnumValues: TArray<string> read FEnumValues;
    { Whether the member's [SerializationEnum] speaks for ATypeInfo: the
      member's own enumeration, or the one inside its nullable. }
    function EnumAppliesTo(ATypeInfo: PTypeInfo): Boolean;
  end;

  { The format-neutral facts about one type. }
  TSerializationTypeMetadata = class
  strict private
    FTypeInfo: PTypeInfo;
    FRttiType: TRttiType;
    FIsRecord: Boolean;
    FInstanceClass: TClass;
    FDeclaredConstructor: TRttiMethod;
    FTObjectConstructor: TRttiMethod;
    FMembers: TArray<TSerializationMember>;
    FAllMembers: TArray<TSerializationMember>;
    FOwned: TObjectList<TSerializationMember>;
    FEnumValues: TArray<string>;
    FHasEnumValues: Boolean;
    function Wrap(AMember: TRttiMember;
      ACache: TDictionary<TRttiMember, TSerializationMember>): TSerializationMember;
  public
    constructor Create(ATypeInfo: PTypeInfo; ARttiType: TRttiType);
    destructor Destroy; override;
    property TypeInfo: PTypeInfo read FTypeInfo;
    { nil for a type declared inside a routine, which has no RTTI. }
    property RttiType: TRttiType read FRttiType;
    property IsRecord: Boolean read FIsRecord;
    property InstanceClass: TClass read FInstanceClass;
    { The first parameterless constructor a class declares above TObject,
      and TObject's own. }
    property DeclaredConstructor: TRttiMethod read FDeclaredConstructor;
    property TObjectConstructor: TRttiMethod read FTObjectConstructor;
    { THE SERIALIZED SURFACE: public and published fields, then public and
      published readable properties, in RTTI order. A name redeclared by a
      descendant (compared case-insensitively, as Delphi does) appears once,
      as the most-derived declaration. Ignored members are included, flagged
      Ignored - a consumer skips them. }
    property Members: TArray<TSerializationMember> read FMembers;
    { Every field and property at every visibility, the redeclarations
      folded the same way BEFORE visibility is considered - for an engine
      whose member strategy reaches private members. }
    property AllMembers: TArray<TSerializationMember> read FAllMembers;
    { [SerializationEnum] on this enumeration type. }
    property HasEnumValues: Boolean read FHasEnumValues;
    property EnumValues: TArray<string> read FEnumValues;
  end;

  TSerializationMetadata = class
  strict private
    class var FLock: TCriticalSection;
    class var FCache: TObjectDictionary<PTypeInfo, TSerializationTypeMetadata>;
    class var FContext: TRttiContext;
    class var FBuilt: Integer;
    class var FByMember: TDictionary<TRttiMember, TSerializationMember>;
  public
    class constructor Create;
    class destructor Destroy;
    { The metadata of ATypeInfo, built on first request. Never nil. }
    class function Get(ATypeInfo: PTypeInfo): TSerializationTypeMetadata; static;
    { [SerializationEnum] on an enumeration type, or nil. }
    class function EnumValuesOf(ATypeInfo: PTypeInfo): TArray<string>; static;
    { The metadata entry for an RTTI member of a class or record, for an
      engine that walks RTTI members itself; nil for a member that is not
      on the surface (a redeclared one, say). }
    class function MemberInfo(AMember: TRttiMember): TSerializationMember; static;
    { [SerializationName] of AMember, if it has one. }
    class function GeneralName(AMember: TRttiMember; out AName: string): Boolean; static;
    { The general text of the enumeration ATypeInfo as AMember holds it:
      [SerializationEnum] on the member when it applies to ATypeInfo, else
      the one on the type. AMember may be nil. }
    class function GeneralEnum(AMember: TRttiMember; ATypeInfo: PTypeInfo;
      out AValues: TArray<string>): Boolean; static;
    { How many types have had metadata built - for tests proving that one
      type's facts are discovered once, whichever engine asks. }
    class function BuiltCount: Integer; static;
  end;

implementation

uses
  PascalForge.Serialization.Core;

{ ------------------------------------------------------------------------- }

constructor TSerializationMember.Create(AMember: TRttiMember);
var
  Attr: TCustomAttribute;
begin
  inherited Create;
  FMember := AMember;
  FVisibility := AMember.Visibility;
  if AMember is TRttiField then
  begin
    FIsField := True;
    FMemberType := TRttiField(AMember).FieldType;
    FIsReadable := True;
    FIsWritable := True;
  end
  else
  begin
    FMemberType := TRttiProperty(AMember).PropertyType;
    FIsReadable := TRttiProperty(AMember).IsReadable;
    FIsWritable := TRttiProperty(AMember).IsWritable;
  end;
  for Attr in AMember.GetAttributes do
    if Attr is SerializationNameAttribute then
    begin
      FGeneralName := SerializationNameAttribute(Attr).Name;
      FHasGeneralName := True;
    end
    else if Attr is SerializationIgnoreAttribute then
      FIgnored := True
    else if Attr is SerializationEnumAttribute then
    begin
      FEnumValues := SerializationEnumAttribute(Attr).Values;
      FHasEnumValues := True;
    end;
end;

function TSerializationMember.Field: TRttiField;
begin
  if FIsField then Result := TRttiField(FMember) else Result := nil;
end;

function TSerializationMember.Prop: TRttiProperty;
begin
  if FIsField then Result := nil else Result := TRttiProperty(FMember);
end;

function TSerializationMember.Name: string;
begin
  Result := FMember.Name;
end;

function TSerializationMember.TypeInfo: PTypeInfo;
begin
  if FMemberType = nil then Result := nil else Result := FMemberType.Handle;
end;

function TSerializationMember.EnumAppliesTo(ATypeInfo: PTypeInfo): Boolean;
var
  Access: TNullableAccess;
begin
  if not FHasEnumValues or (ATypeInfo = nil) or (TypeInfo = nil) then
    Exit(False);
  if TypeInfo = ATypeInfo then Exit(True);
  Result := TSerializationTypes.TryGetNullableAccess(TypeInfo, Access) and
    (Access.ValueType = ATypeInfo);
end;

{ ------------------------------------------------------------------------- }

function DeclaringClassOf(AMember: TRttiMember): TClass;
begin
  if AMember.Parent is TRttiInstanceType then
    Result := TRttiInstanceType(AMember.Parent).MetaclassType
  else
    Result := nil;
end;

constructor TSerializationTypeMetadata.Create(ATypeInfo: PTypeInfo;
  ARttiType: TRttiType);
var
  Cache: TDictionary<TRttiMember, TSerializationMember>;
  Logical: TList<TRttiMember>;
  Indexes: TDictionary<string, Integer>;
  F: TRttiField;
  P: TRttiProperty;
  M: TRttiMethod;
  Attr: TCustomAttribute;

  { The rule every engine applied on its own before this unit existed: a
    redeclaration replaces the declaration it shadows when it belongs to a
    descendant class. ARequirePriorClass is the stricter form used for
    fields in the all-visibilities pass. }
  procedure Fold(AMember: TRttiMember; ARequirePriorClass: Boolean);
  var
    Key: string;
    At: Integer;
    Candidate, Prior: TClass;
  begin
    Key := LowerCase(AMember.Name);
    if Indexes.TryGetValue(Key, At) then
    begin
      Candidate := DeclaringClassOf(AMember);
      Prior := DeclaringClassOf(Logical[At]);
      if (Candidate <> nil) and
         (((Prior = nil) and not ARequirePriorClass) or
          ((Prior <> nil) and Candidate.InheritsFrom(Prior))) then
        Logical[At] := AMember;
    end
    else
    begin
      Indexes.Add(Key, Integer(Logical.Count));
      Logical.Add(AMember);
    end;
  end;

  function Collect: TArray<TSerializationMember>;
  var
    J: Integer;
  begin
    SetLength(Result, Logical.Count);
    for J := 0 to Integer(Logical.Count) - 1 do Result[J] := Wrap(Logical[J], Cache);
  end;

begin
  inherited Create;
  FTypeInfo := ATypeInfo;
  FRttiType := ARttiType;
  FOwned := TObjectList<TSerializationMember>.Create(True);
  FIsRecord := ATypeInfo.Kind in [tkRecord, tkMRecord];
  if ATypeInfo.Kind = tkClass then FInstanceClass := GetTypeData(ATypeInfo).ClassType;
  if ARttiType = nil then Exit;

  for Attr in ARttiType.GetAttributes do
    if Attr is SerializationEnumAttribute then
    begin
      FEnumValues := SerializationEnumAttribute(Attr).Values;
      FHasEnumValues := True;
    end;

  if not (ATypeInfo.Kind in [tkClass, tkRecord, tkMRecord]) then Exit;

  if FInstanceClass <> nil then
    for M in ARttiType.GetMethods do
      if M.IsConstructor and (Length(M.GetParameters) = 0) then
        if SameText(M.Parent.Name, 'TObject') then
        begin
          if FTObjectConstructor = nil then FTObjectConstructor := M;
        end
        else if FDeclaredConstructor = nil then
          FDeclaredConstructor := M;

  Cache := TDictionary<TRttiMember, TSerializationMember>.Create;
  Logical := TList<TRttiMember>.Create;
  Indexes := TDictionary<string, Integer>.Create;
  try
    { The surface: visibility first, then the redeclarations. }
    for F in ARttiType.GetFields do
      if F.Visibility in [mvPublic, mvPublished] then Fold(F, False);
    for P in ARttiType.GetProperties do
      if (P.Visibility in [mvPublic, mvPublished]) and P.IsReadable then
        Fold(P, False);
    FMembers := Collect;

    { Every member: the redeclarations first, then whatever filter the
      engine's strategy applies. }
    Logical.Clear;
    Indexes.Clear;
    for F in ARttiType.GetFields do Fold(F, True);
    for P in ARttiType.GetProperties do Fold(P, False);
    FAllMembers := Collect;
  finally
    Indexes.Free;
    Logical.Free;
    Cache.Free;
  end;
end;

destructor TSerializationTypeMetadata.Destroy;
begin
  FOwned.Free;
  inherited Destroy;
end;

function TSerializationTypeMetadata.Wrap(AMember: TRttiMember;
  ACache: TDictionary<TRttiMember, TSerializationMember>): TSerializationMember;
begin
  if ACache.TryGetValue(AMember, Result) then Exit;
  Result := TSerializationMember.Create(AMember);
  FOwned.Add(Result);
  ACache.Add(AMember, Result);
end;

{ ------------------------------------------------------------------------- }

class constructor TSerializationMetadata.Create;
begin
  { A lock and an empty cache: nothing is discovered until it is asked
    for. }
  FLock := TCriticalSection.Create;
  FCache := TObjectDictionary<PTypeInfo, TSerializationTypeMetadata>.Create(
    [doOwnsValues]);
  FContext := TRttiContext.Create;
  FByMember := TDictionary<TRttiMember, TSerializationMember>.Create;
end;

class destructor TSerializationMetadata.Destroy;
begin
  FByMember.Free;
  FCache.Free;
  FLock.Free;
  FContext.Free;
end;

class function TSerializationMetadata.Get(
  ATypeInfo: PTypeInfo): TSerializationTypeMetadata;
var
  M: TSerializationMember;
begin
  if ATypeInfo = nil then
    raise EArgumentNilException.Create('No type to describe.');
  FLock.Enter;
  try
    if FCache.TryGetValue(ATypeInfo, Result) then Exit;
    Result := TSerializationTypeMetadata.Create(ATypeInfo,
      FContext.GetType(ATypeInfo));
    try
      FCache.Add(ATypeInfo, Result);
    except
      Result.Free;
      raise;
    end;
    for M in Result.AllMembers do FByMember.AddOrSetValue(M.Member, M);
    for M in Result.Members do FByMember.AddOrSetValue(M.Member, M);
    Inc(FBuilt);
  finally
    FLock.Leave;
  end;
end;

class function TSerializationMetadata.EnumValuesOf(
  ATypeInfo: PTypeInfo): TArray<string>;
var
  Meta: TSerializationTypeMetadata;
begin
  Result := nil;
  if (ATypeInfo = nil) or (ATypeInfo.Kind <> tkEnumeration) then Exit;
  Meta := Get(ATypeInfo);
  if Meta.HasEnumValues then Result := Meta.EnumValues;
end;

class function TSerializationMetadata.MemberInfo(
  AMember: TRttiMember): TSerializationMember;
begin
  Result := nil;
  if AMember = nil then Exit;
  FLock.Enter;
  try
    if FByMember.TryGetValue(AMember, Result) then Exit;
    if not (AMember.Parent is TRttiType) then Exit;
    { The owner's metadata lists the member; building it registers it. }
    Get(TRttiType(AMember.Parent).Handle);
    if not FByMember.TryGetValue(AMember, Result) then Result := nil;
  finally
    FLock.Leave;
  end;
end;

class function TSerializationMetadata.GeneralName(AMember: TRttiMember;
  out AName: string): Boolean;
var
  Info: TSerializationMember;
begin
  AName := '';
  Info := MemberInfo(AMember);
  Result := (Info <> nil) and Info.HasGeneralName;
  if Result then AName := Info.GeneralName;
end;

class function TSerializationMetadata.GeneralEnum(AMember: TRttiMember;
  ATypeInfo: PTypeInfo; out AValues: TArray<string>): Boolean;
var
  Info: TSerializationMember;
begin
  AValues := nil;
  Info := MemberInfo(AMember);
  if (Info <> nil) and Info.EnumAppliesTo(ATypeInfo) then
    AValues := Info.EnumValues
  else
    AValues := EnumValuesOf(ATypeInfo);
  Result := AValues <> nil;
end;

class function TSerializationMetadata.BuiltCount: Integer;
begin
  FLock.Enter;
  try
    Result := FBuilt;
  finally
    FLock.Leave;
  end;
end;

end.
