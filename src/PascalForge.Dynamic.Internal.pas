{*******************************************************************************
  PascalForge.Dynamic.Internal

  INTERNAL IMPLEMENTATION UNIT - applications should not use this unit directly.

  The engine behind TDynamicSerializer and the projecting Append overloads:
  Delphi values onto the dynamic model through the shared RTTI metadata,
  and back, under the shared depth limit.
  Exposed through the public unit PascalForge.Dynamic.

  Documentation
    docs/dynamic.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Dynamic.Internal;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  PascalForge.Dynamic;

type
  TDynamicEngine = class
  public
    { A new root the caller owns. }
    class function FromDelphi(const AValue: TValue): TDynamicValue; static;
    { A new Delphi value: for a class, a new instance the caller owns. }
    class function ToDelphi(AValue: TDynamicValue;
      ATypeInfo: PTypeInfo): TValue; static;
    { Fills AInstance from an object, member by member. }
    class procedure Populate(AInstance: TObject;
      AValue: TDynamicValue); static;
  end;

implementation

uses
  System.Classes, System.Variants, System.Math, System.Generics.Collections,
  PascalForge.Serialization.Core,
  PascalForge.Serialization.Internal;

{ =========================================================================
  SHARED
  ========================================================================= }

function TypeNameOf(ATypeInfo: PTypeInfo): string;
begin
  if ATypeInfo = nil then Exit('a value without type information');
  Result := UTF8ToString(ATypeInfo.Name);
end;

{ The name a member has in a dynamic object: [SerializationName], else the
  Delphi identifier exactly. Dynamic applies no naming convention. }
function MemberNameOf(AMember: TSerializationMember): string;
begin
  if AMember.HasGeneralName then Result := AMember.GeneralName
  else Result := AMember.Name;
end;

function MemberValue(AMember: TSerializationMember;
  const AInstance: TValue): TValue;
begin
  if AInstance.IsObject then
  begin
    {$WARN UNSAFE_CAST OFF}
    if AMember.IsField then
      Result := AMember.Field.GetValue(AInstance.AsObject)
    else
      Result := AMember.Prop.GetValue(AInstance.AsObject);
    {$WARN UNSAFE_CAST ON}
  end
  else if AMember.IsField then
    Result := AMember.Field.GetValue(AInstance.GetReferenceToRawData)
  else
    Result := AMember.Prop.GetValue(AInstance.GetReferenceToRawData);
end;

procedure SetMemberValue(AMember: TSerializationMember; const AInstance,
  AValue: TValue);
begin
  if AInstance.IsObject then
  begin
    {$WARN UNSAFE_CAST OFF}
    if AMember.IsField then
      AMember.Field.SetValue(AInstance.AsObject, AValue)
    else
      AMember.Prop.SetValue(AInstance.AsObject, AValue);
    {$WARN UNSAFE_CAST ON}
  end
  else if AMember.IsField then
    AMember.Field.SetValue(AInstance.GetReferenceToRawData, AValue)
  else
    AMember.Prop.SetValue(AInstance.GetReferenceToRawData, AValue);
end;

{ The general text of an enumeration's values, as AMember holds it. }
function EnumTexts(AMember: TSerializationMember;
  ATypeInfo: PTypeInfo): TArray<string>;
begin
  if (AMember <> nil) and AMember.EnumAppliesTo(ATypeInfo) then
    Result := AMember.EnumValues
  else
    Result := TSerializationMetadata.EnumValuesOf(ATypeInfo);
end;

function IsBooleanType(ATypeInfo: PTypeInfo): Boolean;
begin
  Result := (ATypeInfo = System.TypeInfo(Boolean)) or
    (ATypeInfo = System.TypeInfo(ByteBool)) or
    (ATypeInfo = System.TypeInfo(WordBool)) or
    (ATypeInfo = System.TypeInfo(LongBool)) or
    ((ATypeInfo.Kind = tkEnumeration) and
     (GetTypeData(ATypeInfo).BaseType <> nil) and
     (GetTypeData(ATypeInfo).BaseType^ = System.TypeInfo(Boolean)));
end;

function IsUnsignedInt64(ATypeInfo: PTypeInfo): Boolean;
var
  TD: PTypeData;
begin
  if ATypeInfo = System.TypeInfo(UInt64) then Exit(True);
  if ATypeInfo.Kind <> tkInt64 then Exit(False);
  TD := GetTypeData(ATypeInfo);
  Result := (TD.MinInt64Value = 0) and (TD.MaxInt64Value = -1);
end;

function CurrencyDigits(AValue: Currency): string;
begin
  { Exact, and always with a point: a Currency of 3 is a real number that
    happens to be whole. The same digits the Variant bridge writes. }
  Result := CurrToStr(AValue, TFormatSettings.Invariant);
  if Pos('.', Result) = 0 then Result := Result + '.0';
end;

{ =========================================================================
  DELPHI -> DYNAMIC
  ========================================================================= }

function ToDyn(ATypeInfo: PTypeInfo; const AValue: TValue;
  AMember: TSerializationMember): TDynamicValue; forward;

procedure Refuse(ATypeInfo: PTypeInfo; AMember: TSerializationMember;
  const AWhy: string);
var
  Where: string;
begin
  if AMember <> nil then
    Where := AMember.Name + ' (' + TypeNameOf(ATypeInfo) + ')'
  else
    Where := TypeNameOf(ATypeInfo);
  raise EDynamicError.CreateFmt('%s %s. Leave the member out with ' +
    '[SerializationIgnore].', [Where, AWhy]);
end;

{ The members of a class or record, onto AObject. An empty nullable and an
  Unassigned Variant are left out - absent, not null - as every format here
  leaves them out. }
procedure MembersToDyn(ATypeInfo: PTypeInfo; const AInstance: TValue;
  AObject: TDynamicObject);
var
  Member: TSerializationMember;
  V: TValue;
  Access: TNullableAccess;
begin
  for Member in TSerializationMetadata.Get(ATypeInfo).Members do
  begin
    if Member.Ignored then Continue;
    if Member.MemberType = nil then
      Refuse(nil, Member, TSerializationTypes.UnsupportedReason(nil));
    V := MemberValue(Member, AInstance);
    if TSerializationTypes.TryGetNullableAccess(Member.TypeInfo, Access) and
       not Access.HasValue(V.GetReferenceToRawData) then
      Continue;
    if (Member.TypeInfo.Kind = tkVariant) and VarIsEmpty(V.AsVariant) then
      Continue;
    AObject.Adopt(MemberNameOf(Member), ToDyn(Member.TypeInfo, V, Member));
  end;
end;

function KeyText(const AKey: TValue): string;
begin
  case AKey.Kind of
    tkUString, tkString, tkLString, tkWString, tkChar, tkWChar:
      Result := AKey.AsString;
    tkInteger, tkInt64:
      Result := TSerializationTypes.IntegerText(AKey);
    tkEnumeration:
      { Through [SerializationEnum] on the key's type, as any enumeration
        value is. }
      Result := TSerializationTypes.MappedSetElementText(AKey.TypeInfo,
        Integer(AKey.AsOrdinal),
        TSerializationMetadata.EnumValuesOf(AKey.TypeInfo));
  else
    raise EDynamicError.CreateFmt('A dictionary keyed by %s cannot become ' +
      'an object: a member name is text, and only a string, an integer or ' +
      'an enumeration key has one exact text form.',
      [TypeNameOf(AKey.TypeInfo)]);
  end;
end;

function ContainerToDyn(ATypeInfo: PTypeInfo; AObject: TObject): TDynamicValue;
var
  List: TListAccess;
  Dict: TDictionaryAccess;
  Items, Pairs, Pair: TValue;
  I: Integer;
begin
  if not TSerializationGraphGuard.Enter(AObject) then
    raise EDynamicError.CreateFmt('%s is already being projected further up ' +
      'the graph: a dynamic tree has no back-references, so a cycle cannot ' +
      'become one.', [AObject.ClassName]);
  try
    if TSerializationTypes.TryGetListAccess(ATypeInfo, List) then
    begin
      Result := TDynamicArray.Create;
      try
        Items := List.Elements(AObject);
        for I := 0 to Integer(Items.GetArrayLength) - 1 do
          TDynamicArray(Result).Adopt(ToDyn(List.ElementType,
            Items.GetArrayElement(I), nil));
      except
        Result.Free;
        raise;
      end;
      Exit;
    end;
    if not TSerializationTypes.TryGetDictionaryAccess(ATypeInfo, Dict) then
      raise EDynamicError.CreateFmt('%s is a container with no usable ' +
        'methods to read it.', [TypeNameOf(ATypeInfo)]);
    Result := TDynamicObject.Create;
    try
      Pairs := Dict.Pairs(AObject);
      for I := 0 to Integer(Pairs.GetArrayLength) - 1 do
      begin
        Pair := Pairs.GetArrayElement(I);
        TDynamicObject(Result).Adopt(KeyText(Dict.KeyOf(Pair)),
          ToDyn(Dict.ValueType, Dict.ValueOf(Pair), nil));
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    TSerializationGraphGuard.Leave(AObject);
  end;
end;

function ArrayToDyn(const AValue: TValue): TDynamicValue;
var
  I: Integer;
  Element: TValue;
begin
  TSerializationGraphGuard.EnterLevel;
  try
    Result := TDynamicArray.Create;
    try
      for I := 0 to Integer(AValue.GetArrayLength) - 1 do
      begin
        Element := AValue.GetArrayElement(I);
        TDynamicArray(Result).Adopt(ToDyn(Element.TypeInfo, Element, nil));
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    TSerializationGraphGuard.LeaveLevel;
  end;
end;

function ToDyn(ATypeInfo: PTypeInfo; const AValue: TValue;
  AMember: TSerializationMember): TDynamicValue;
var
  Why: string;
  Access: TNullableAccess;
  Texts: TArray<string>;
  Ordinal: Int64;
  Ord_: Integer;
  Obj: TObject;
  Tree: TDynamicValue;
  Guid: TGUID;
begin
  if (ATypeInfo = nil) and AValue.IsEmpty then
    Exit(TDynamicValue.NewNull);
  if ATypeInfo = nil then ATypeInfo := AValue.TypeInfo;

  Why := TSerializationTypes.UnsupportedReason(ATypeInfo);
  if Why <> '' then Refuse(ATypeInfo, AMember, Why);

  { A nullable is its value, or null. }
  if TSerializationTypes.TryGetNullableAccess(ATypeInfo, Access) then
  begin
    if not Access.HasValue(AValue.GetReferenceToRawData) then
      Exit(TDynamicValue.NewNull);
    Exit(ToDyn(Access.ValueType, Access.GetValue(AValue.GetReferenceToRawData),
      AMember));
  end;

  case ATypeInfo.Kind of
    tkInteger, tkInt64:
      begin
        if IsUnsignedInt64(ATypeInfo) then
          Exit(TDynamicValue.NewUInt(AValue.AsUInt64));
        Exit(TDynamicValue.NewInt(TSerializationTypes.Int64Bits(AValue)));
      end;

    tkFloat:
      begin
        if TSerializationTypes.IsCompType(ATypeInfo) then
          Exit(TDynamicValue.NewInt(TSerializationTypes.Int64Bits(AValue)));
        if GetTypeData(ATypeInfo).FloatType = ftCurr then
          Exit(TDynamicValue.NewDecimal(CurrencyDigits(AValue.AsCurrency)));
        if ATypeInfo = System.TypeInfo(TDate) then
          Exit(TDynamicValue.NewDate(AValue.AsExtended));
        if ATypeInfo = System.TypeInfo(TTime) then
          Exit(TDynamicValue.NewTime(AValue.AsExtended));
        if ATypeInfo = System.TypeInfo(TDateTime) then
          Exit(TDynamicValue.NewDateTime(AValue.AsExtended));
        Exit(TDynamicValue.NewFloat(AValue.AsExtended));
      end;

    tkEnumeration:
      begin
        if IsBooleanType(ATypeInfo) then
          Exit(TDynamicValue.NewBool(AValue.AsOrdinal <> 0));
        Ordinal := AValue.AsOrdinal;
        Texts := EnumTexts(AMember, ATypeInfo);
        if (Texts <> nil) and (Ordinal >= 0) and (Ordinal <= High(Texts)) then
          Exit(TDynamicValue.NewStr(Texts[Ordinal]));
        Exit(TDynamicValue.NewStr(GetEnumName(ATypeInfo, Integer(Ordinal))));
      end;

    tkSet:
      begin
        Result := TDynamicArray.Create;
        try
          { An enumeration's elements through [SerializationEnum] on the
            element type. }
          Texts := TSerializationMetadata.EnumValuesOf(
            TSerializationTypes.SetElementType(ATypeInfo));
          for Ord_ in TSerializationTypes.SetOrdinals(ATypeInfo, AValue) do
            TDynamicArray(Result).Append(TSerializationTypes.MappedSetElementText(
              TSerializationTypes.SetElementType(ATypeInfo), Ord_, Texts));
        except
          Result.Free;
          raise;
        end;
        Exit;
      end;

    tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
      Exit(TDynamicValue.NewStr(AValue.AsString));

    tkVariant:
      begin
        if not TSerializationVariants.TryToDynamic(AValue.AsVariant, Tree, Why) then
          Refuse(ATypeInfo, AMember, 'holds a Variant that ' + Why);
        Exit(Tree);
      end;

    tkDynArray:
      begin
        if ATypeInfo = System.TypeInfo(TBytes) then
          Exit(TDynamicValue.NewBytes(Copy(AValue.AsType<TBytes>)));
        Exit(ArrayToDyn(AValue));
      end;

    tkArray:
      Exit(ArrayToDyn(AValue));

    tkRecord, tkMRecord:
      begin
        if ATypeInfo = System.TypeInfo(TGUID) then
        begin
          { The canonical thirty-six characters, without braces, as every
            format here writes a GUID. }
          Guid := AValue.AsType<TGUID>;
          Exit(TDynamicValue.NewStr(LowerCase(Copy(GUIDToString(Guid), 2, 36))));
        end;
        TSerializationGraphGuard.EnterLevel;
        try
          Result := TDynamicObject.Create;
          try
            MembersToDyn(ATypeInfo, AValue, TDynamicObject(Result));
          except
            Result.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
        Exit;
      end;

    tkClass:
      begin
        Obj := AValue.AsObject;
        if Obj = nil then Exit(TDynamicValue.NewNull);
        { A dynamic value inside a Delphi graph is itself, copied. }
        if Obj is TDynamicValue then Exit(TDynamicValue(Obj).Clone);
        { The runtime class decides: a member declared TObject holding a
          list is a list. }
        ATypeInfo := Obj.ClassInfo;
        if TSerializationTypes.ContainerKindOf(ATypeInfo) <> TContainerKind.None then
          Exit(ContainerToDyn(ATypeInfo, Obj));
        if Obj is TStrings then
        begin
          Result := TDynamicArray.Create;
          try
            for Ord_ := 0 to TStrings(Obj).Count - 1 do
              TDynamicArray(Result).Append(TStrings(Obj)[Ord_]);
          except
            Result.Free;
            raise;
          end;
          Exit;
        end;
        if not TSerializationGraphGuard.Enter(Obj) then
          raise EDynamicError.CreateFmt('%s is already being projected ' +
            'further up the graph: a dynamic tree has no back-references, so ' +
            'a cycle cannot become one.', [Obj.ClassName]);
        try
          Result := TDynamicObject.Create;
          try
            MembersToDyn(ATypeInfo, AValue, TDynamicObject(Result));
          except
            Result.Free;
            raise;
          end;
        finally
          TSerializationGraphGuard.Leave(Obj);
        end;
        Exit;
      end;
  end;

  Refuse(ATypeInfo, AMember, 'has no dynamic form');
  Result := nil;
end;

class function TDynamicEngine.FromDelphi(const AValue: TValue): TDynamicValue;
var
  Mark: Integer;
begin
  { A projection that failed deep down must not leave the next one on this
    thread starting part way down the depth limit. }
  Mark := TSerializationGraphGuard.Level;
  try
    Result := ToDyn(AValue.TypeInfo, AValue, nil);
  finally
    TSerializationGraphGuard.RestoreLevel(Mark);
  end;
end;

{ =========================================================================
  DYNAMIC -> DELPHI
  ========================================================================= }

function FromDyn(ATypeInfo: PTypeInfo; AValue: TDynamicValue;
  AMember: TSerializationMember; const AExisting: TValue;
  const APath: string): TValue; forward;

procedure Mismatch(ATypeInfo: PTypeInfo; AValue: TDynamicValue;
  const AExpected: string);
begin
  raise EDynamicError.CreateFmt('Expected %s for %s, found %s.',
    [AExpected, TypeNameOf(ATypeInfo), AValue.Describe]);
end;

{ The member of AObject that a Delphi member reads from: the exact name,
  else - Delphi identifiers being case-insensitive - the one member that
  matches ignoring case. }
function FindMember(AObject: TDynamicValue; const AName,
  APath: string): TDynamicValue;
var
  I: Integer;
  Candidates: string;
  Found: Integer;
begin
  Result := AObject.Find(AName);
  if Result <> nil then Exit;
  Found := 0;
  Candidates := '';
  for I := 0 to AObject.Count - 1 do
    if SameText(AObject.Names[I], AName) then
    begin
      Inc(Found);
      if Candidates <> '' then Candidates := Candidates + ', ';
      Candidates := Candidates + '"' + AObject.Names[I] + '"';
      Result := AObject.Items[I];
    end;
  { Two or more members that differ from the contract's name only in case,
    and none spelled exactly like it: which one was meant is not something
    to guess, and leaving the member unset would be silent. }
  if Found > 1 then
    raise EDynamicError.CreateFmt('%s: the object has no member spelled ' +
      'exactly "%s", and %d that match it ignoring case (%s). Which one is ' +
      'meant is ambiguous; name it exactly.', [APath, AName, Found, Candidates]);
end;

function ExistingValueOf(AMember: TSerializationMember;
  const AInstance: TValue): TValue;
begin
  Result := TValue.Empty;
  if AMember.TypeInfo = nil then Exit;
  if AMember.TypeInfo.Kind in [tkRecord, tkMRecord] then
    Exit(MemberValue(AMember, AInstance));
  if AMember.TypeInfo.Kind <> tkClass then Exit;
  if not AMember.IsReadable then Exit;
  Result := MemberValue(AMember, AInstance);
  if Result.IsObject and (Result.AsObject = nil) then Result := TValue.Empty;
end;

procedure MembersFromDyn(ATypeInfo: PTypeInfo; AObject: TDynamicValue;
  const AInstance: TValue; const APath: string);
var
  Member: TSerializationMember;
  Child: TDynamicValue;
begin
  for Member in TSerializationMetadata.Get(ATypeInfo).Members do
  begin
    if Member.Ignored or (Member.MemberType = nil) then Continue;
    Child := FindMember(AObject, MemberNameOf(Member), APath);
    if Child = nil then Continue;
    if not Member.IsWritable then
    begin
      { A read-only property holding an object is filled in place. }
      if (Member.TypeInfo.Kind = tkClass) and Member.IsReadable then
        FromDyn(Member.TypeInfo, Child, Member, ExistingValueOf(Member, AInstance),
          APath + '.' + MemberNameOf(Member));
      Continue;
    end;
    SetMemberValue(Member, AInstance,
      FromDyn(Member.TypeInfo, Child, Member, ExistingValueOf(Member, AInstance),
        APath + '.' + MemberNameOf(Member)));
  end;
end;

function KeyFromText(ATypeInfo: PTypeInfo; const AText: string): TValue;
var
  Why: string;
  Ordinal: Integer;
begin
  case ATypeInfo.Kind of
    tkUString, tkString, tkLString, tkWString, tkChar, tkWChar:
      if not TSerializationTypes.TryStringFromText(ATypeInfo, AText, Result, Why) then
        raise EDynamicError.Create(Why + '.');
    tkInteger, tkInt64:
      if not TSerializationTypes.TryIntegerFromText(ATypeInfo, AText, Result) then
        raise EDynamicError.CreateFmt('"%s" is not a %s key.',
          [AText, TypeNameOf(ATypeInfo)]);
    tkEnumeration:
      begin
        if not TSerializationTypes.TryMappedSetElementOrdinal(ATypeInfo, AText,
             TSerializationMetadata.EnumValuesOf(ATypeInfo), Ordinal) then
          Ordinal := -1;
        if Ordinal < 0 then
          raise EDynamicError.CreateFmt('"%s" is not a value of %s.',
            [AText, TypeNameOf(ATypeInfo)]);
        Result := TValue.FromOrdinal(ATypeInfo, Ordinal);
      end;
  else
    raise EDynamicError.CreateFmt('A dictionary keyed by %s cannot be read ' +
      'from an object, whose member names are text.', [TypeNameOf(ATypeInfo)]);
  end;
end;

{ Fills a list or dictionary instance; False when the type is neither. }
function FillContainer(ATypeInfo: PTypeInfo; AInstance: TObject;
  AValue: TDynamicValue; const APath: string): Boolean;
var
  List: TListAccess;
  Dict: TDictionaryAccess;
  I: Integer;
  Key, Item: TValue;
begin
  if TSerializationTypes.TryGetListAccess(ATypeInfo, List) then
  begin
    { Checked before the list is cleared: a document of the wrong shape
      does not erase the caller's items on its way to failing. }
    if AValue.Kind <> TDynamicKind.Arr then Mismatch(ATypeInfo, AValue, 'an array');
    List.Clear(AInstance);
    for I := 0 to AValue.Count - 1 do
    begin
      Item := FromDyn(List.ElementType, AValue.Items[I], nil, TValue.Empty,
        APath + '[' + IntToStr(I) + ']');
      try
        List.Add(AInstance, Item);
      except
        TSerializationOwnership.ReleaseBuilt(List.ElementType, Item, TValue.Empty);
        raise;
      end;
    end;
    Exit(True);
  end;
  if not TSerializationTypes.TryGetDictionaryAccess(ATypeInfo, Dict) then
    Exit(False);
  if AValue.Kind <> TDynamicKind.Obj then Mismatch(ATypeInfo, AValue, 'an object');
  Dict.Clear(AInstance);
  for I := 0 to AValue.Count - 1 do
  begin
    Key := KeyFromText(Dict.KeyType, AValue.Names[I]);
    Item := FromDyn(Dict.ValueType, AValue.Items[I], nil, TValue.Empty,
      APath + '.' + AValue.Names[I]);
    try
      TSerializationOwnership.AddOrSetBuilt(Dict, AInstance, Key, Item);
    except
      TSerializationOwnership.ReleaseBuilt(Dict.ValueType, Item, TValue.Empty);
      raise;
    end;
  end;
  Result := True;
end;

{ 2^63, exactly, as a Double: the bounds of an Int64 a Double can be
  checked against. }
const
  TWO_POW_63: Double = 9223372036854775808.0;

function IntegralOf(AValue: TDynamicValue; ATypeInfo: PTypeInfo): TValue;
var
  D: Double;
begin
  case AValue.Kind of
    TDynamicKind.Int:
      if TSerializationTypes.TryIntegerFromInt64(ATypeInfo, AValue.AsInt, Result) then
        Exit;
    TDynamicKind.UInt:
      if TSerializationTypes.TryIntegerFromUInt64(ATypeInfo, AValue.AsUInt, Result) then
        Exit;
    TDynamicKind.Decimal:
      if TSerializationTypes.TryIntegerFromText(ATypeInfo, AValue.AsDecimal, Result) then
        Exit;
    TDynamicKind.Float:
      begin
        { Only a whole number is an integer: 2.5 is not 2. }
        D := AValue.AsFloat;
        if not D.IsNan and not D.IsInfinity and (Frac(D) = 0) and
           (D >= -TWO_POW_63) and (D < TWO_POW_63) and
           TSerializationTypes.TryIntegerFromInt64(ATypeInfo, Trunc(D), Result) then
          Exit;
      end;
  else
    Mismatch(ATypeInfo, AValue, 'an integer');
  end;
  raise EDynamicError.CreateFmt('%s does not fit in %s.',
    [AValue.Describe, TypeNameOf(ATypeInfo)]);
end;

function FloatOf(AValue: TDynamicValue; ATypeInfo: PTypeInfo): TValue;
var
  D: Double;
  Why: string;
begin
  case AValue.Kind of
    TDynamicKind.Float: D := AValue.AsFloat;
    TDynamicKind.Int: D := AValue.AsInt;
    TDynamicKind.UInt: D := AValue.AsUInt;
    TDynamicKind.Decimal:
      if not TStructuralText.TryParseFloat(AValue.AsDecimal, D) then
        Mismatch(ATypeInfo, AValue, 'a number');
  else
    Mismatch(ATypeInfo, AValue, 'a number');
  end;
  if not TSerializationTypes.TryFloatFromDouble(ATypeInfo, D, Result, Why) then
    raise EDynamicError.Create(Why + '.');
end;

function CurrencyOf(AValue: TDynamicValue; ATypeInfo: PTypeInfo): TValue;
var
  C: Currency;
  Text, Why: string;
begin
  case AValue.Kind of
    TDynamicKind.Decimal, TDynamicKind.Int, TDynamicKind.UInt:
      Text := AValue.AsDecimal;
    TDynamicKind.Str:
      Text := Trim(AValue.AsStr);
    TDynamicKind.Float:
      begin
        if not TSerializationTypes.TryFloatFromDouble(ATypeInfo, AValue.AsFloat,
             Result, Why) then
          raise EDynamicError.Create(Why + '.');
        Exit;
      end;
  else
    Mismatch(ATypeInfo, AValue, 'a currency amount');
  end;
  if not TryStrToCurr(Text, C, TFormatSettings.Invariant) then
    raise EDynamicError.CreateFmt('%s is not a currency amount.',
      [AValue.Describe]);
  TValue.Make(@C, ATypeInfo, Result);
end;

function DateTimeOf(AValue: TDynamicValue; ATypeInfo: PTypeInfo): TValue;
var
  D: TDateTime;
  Ok: Boolean;
begin
  case AValue.Kind of
    TDynamicKind.Date, TDynamicKind.Time, TDynamicKind.DateTime:
      D := AValue.AsDateTime;
    { Text is read as a date where the CONTRACT says it is one - a JSON
      document carries dates as strings. }
    TDynamicKind.Str:
      begin
        if ATypeInfo = System.TypeInfo(TDate) then
          Ok := TStructuralText.TryDecodeDate(AValue.AsStr, D) or
            TStructuralText.TryDecodeDateTime(AValue.AsStr, D)
        else if ATypeInfo = System.TypeInfo(TTime) then
          Ok := TStructuralText.TryDecodeTime(AValue.AsStr, D) or
            TStructuralText.TryDecodeDateTime(AValue.AsStr, D)
        else
          Ok := TStructuralText.TryDecodeDateTime(AValue.AsStr, D);
        if not Ok then
          raise EDynamicError.CreateFmt('"%s" is not a %s.',
            [AValue.AsStr, TypeNameOf(ATypeInfo)]);
      end;
  else
    Mismatch(ATypeInfo, AValue, 'a date or time');
  end;
  if ATypeInfo = System.TypeInfo(TDate) then D := System.Int(D)
  else if ATypeInfo = System.TypeInfo(TTime) then D := System.Frac(System.Abs(D));
  TValue.Make(@D, ATypeInfo, Result);
end;

function EnumOf(AValue: TDynamicValue; ATypeInfo: PTypeInfo;
  AMember: TSerializationMember): TValue;
var
  Texts: TArray<string>;
  I, Ordinal: Integer;
  TD: PTypeData;
begin
  if IsBooleanType(ATypeInfo) then
  begin
    if AValue.Kind <> TDynamicKind.Bool then Mismatch(ATypeInfo, AValue, 'a boolean');
    Exit(TValue.FromOrdinal(ATypeInfo, Ord(AValue.AsBool)));
  end;
  TD := GetTypeData(ATypeInfo);
  if AValue.Kind = TDynamicKind.Int then
  begin
    if (AValue.AsInt < TD.MinValue) or (AValue.AsInt > TD.MaxValue) then
      raise EDynamicError.CreateFmt('%d is not a value of %s.',
        [AValue.AsInt, TypeNameOf(ATypeInfo)]);
    Exit(TValue.FromOrdinal(ATypeInfo, AValue.AsInt));
  end;
  if AValue.Kind <> TDynamicKind.Str then Mismatch(ATypeInfo, AValue, 'an enumeration value');
  Texts := EnumTexts(AMember, ATypeInfo);
  if Texts <> nil then
  begin
    { A mapped enumeration reads its mapped text, as every format does. }
    for I := 0 to Integer(High(Texts)) do
      if SameText(Texts[I], AValue.AsStr) then
        Exit(TValue.FromOrdinal(ATypeInfo, I));
    raise EDynamicError.CreateFmt('"%s" is not a mapped value of %s.',
      [AValue.AsStr, TypeNameOf(ATypeInfo)]);
  end;
  Ordinal := GetEnumValue(ATypeInfo, AValue.AsStr);
  if Ordinal < 0 then
    raise EDynamicError.CreateFmt('"%s" is not a value of %s.',
      [AValue.AsStr, TypeNameOf(ATypeInfo)]);
  Result := TValue.FromOrdinal(ATypeInfo, Ordinal);
end;

function SetOf(AValue: TDynamicValue; ATypeInfo: PTypeInfo): TValue;
var
  Ords: TArray<Integer>;
  I, Ordinal: Integer;
  Why: string;
  Texts: TArray<string>;
begin
  if AValue.Kind <> TDynamicKind.Arr then Mismatch(ATypeInfo, AValue, 'an array');
  Texts := TSerializationMetadata.EnumValuesOf(
    TSerializationTypes.SetElementType(ATypeInfo));
  SetLength(Ords, AValue.Count);
  for I := 0 to AValue.Count - 1 do
  begin
    if (AValue.Items[I].Kind <> TDynamicKind.Str) or
       not TSerializationTypes.TryMappedSetElementOrdinal(
         TSerializationTypes.SetElementType(ATypeInfo), AValue.Items[I].AsStr,
         Texts, Ordinal) then
      raise EDynamicError.CreateFmt('%s is not a member of %s.',
        [AValue.Items[I].Describe, TypeNameOf(ATypeInfo)]);
    Ords[I] := Ordinal;
  end;
  if not TSerializationTypes.TryMakeSet(ATypeInfo, Ords, Result, Why) then
    raise EDynamicError.Create(Why + '.');
end;

function DynArrayOf(AValue: TDynamicValue; ATypeInfo: PTypeInfo;
  const APath: string): TValue;
var
  ElemType: PTypeInfo;
  Len: NativeInt;
  I: Integer;
  Bytes: TBytes;
begin
  if ATypeInfo = System.TypeInfo(TBytes) then
  begin
    case AValue.Kind of
      TDynamicKind.Bytes: Exit(TValue.From<TBytes>(Copy(AValue.AsBytes)));
      { A document with no binary type carries base64 text. }
      TDynamicKind.Str:
        if TStructuralText.TryDecodeBinary(AValue.AsStr, Bytes) then
          Exit(TValue.From<TBytes>(Bytes));
    end;
    Mismatch(ATypeInfo, AValue, 'binary');
  end;
  if AValue.Kind <> TDynamicKind.Arr then Mismatch(ATypeInfo, AValue, 'an array');
  ElemType := GetTypeData(ATypeInfo).DynArrElType^;
  TValue.Make(nil, ATypeInfo, Result);
  Len := AValue.Count;
  DynArraySetLength(PPointer(Result.GetReferenceToRawData)^, ATypeInfo, 1, @Len);
  try
    for I := 0 to AValue.Count - 1 do
      Result.SetArrayElement(I, FromDyn(ElemType, AValue.Items[I], nil,
        TValue.Empty, APath + '[' + IntToStr(I) + ']'));
  except
    TSerializationOwnership.ReleaseBuilt(ATypeInfo, Result, TValue.Empty);
    raise;
  end;
end;

function StaticArrayOf(AValue: TDynamicValue; ATypeInfo: PTypeInfo;
  const APath: string): TValue;
var
  ElemType: PTypeInfo;
  Count, Size, I: Integer;
  Elems: TArray<TValue>;
  Why: string;
begin
  if AValue.Kind <> TDynamicKind.Arr then Mismatch(ATypeInfo, AValue, 'an array');
  if not TSerializationTypes.TryGetStaticArrayShape(ATypeInfo, ElemType, Count,
       Size) then
    raise EDynamicError.CreateFmt('%s has no element type information.',
      [TypeNameOf(ATypeInfo)]);
  SetLength(Elems, AValue.Count);
  I := 0;
  try
    while I < AValue.Count do
    begin
      Elems[I] := FromDyn(ElemType, AValue.Items[I], nil, TValue.Empty,
        APath + '[' + IntToStr(I) + ']');
      Inc(I);
    end;
    if not TSerializationTypes.TryMakeArray(ATypeInfo, Elems, Result, Why) then
      raise EDynamicError.Create(Why + '.');
  except
    TSerializationOwnership.ReleaseBuiltElements(ElemType, Copy(Elems, 0, I));
    raise;
  end;
end;

function GuidOf(AValue: TDynamicValue; ATypeInfo: PTypeInfo): TValue;
var
  Text: string;
  Guid: TGUID;
begin
  if AValue.Kind <> TDynamicKind.Str then Mismatch(ATypeInfo, AValue, 'a GUID');
  Text := Trim(AValue.AsStr);
  if (Text <> '') and (Text[1] <> '{') then Text := '{' + Text + '}';
  try
    Guid := StringToGUID(Text);
  except
    on E: EConvertError do
      raise EDynamicError.CreateFmt('"%s" is not a GUID.', [AValue.AsStr]);
  end;
  Result := TValue.From<TGUID>(Guid);
end;

function RecordOf(AValue: TDynamicValue; ATypeInfo: PTypeInfo;
  const AExisting: TValue; const APath: string): TValue;
var
  Prior: TValue;
begin
  if AValue.Kind <> TDynamicKind.Obj then Mismatch(ATypeInfo, AValue, 'an object');
  { Merged into a COPY of the current value: the members the object leaves
    out keep what they had, and a failure can tell the objects this read
    built from the ones that were there. }
  if (not AExisting.IsEmpty) and (AExisting.TypeInfo = ATypeInfo) then
    Prior := AExisting
  else
    Prior := TValue.Empty;
  if Prior.IsEmpty then TValue.Make(nil, ATypeInfo, Result)
  else TValue.Make(Prior.GetReferenceToRawData, ATypeInfo, Result);
  try
    MembersFromDyn(ATypeInfo, AValue, Result, APath);
  except
    TSerializationOwnership.ReleaseBuilt(ATypeInfo, Result, Prior);
    raise;
  end;
end;

function ClassOf(AValue: TDynamicValue; ATypeInfo: PTypeInfo;
  const AExisting: TValue; const APath: string): TValue;
var
  Built: Boolean;
  Obj: TObject;
  Meta: TSerializationTypeMetadata;
  Ctor: TRttiMethod;
begin
  if AExisting.IsObject and (AExisting.AsObject <> nil) then
  begin
    Result := AExisting;
    Built := False;
  end
  else
  begin
    Meta := TSerializationMetadata.Get(ATypeInfo);
    Ctor := TSerializationTypes.DefaultConstructor(Meta.RttiType);
    if Ctor = nil then
      raise EDynamicError.CreateFmt('%s has no parameterless constructor, so ' +
        'it cannot be built from a dynamic value. Pass an instance to ' +
        'Populate instead.', [TypeNameOf(ATypeInfo)]);
    Obj := Ctor.Invoke(GetTypeData(ATypeInfo).ClassType, []).AsObject;
    TValue.Make(@Obj, ATypeInfo, Result);
    Built := True;
  end;
  try
    if FillContainer(ATypeInfo, Result.AsObject, AValue, APath) then Exit;
    if Result.AsObject is TStrings then
    begin
      if AValue.Kind <> TDynamicKind.Arr then Mismatch(ATypeInfo, AValue, 'an array');
      TStrings(Result.AsObject).Clear;
      for var I := 0 to AValue.Count - 1 do
      begin
        if AValue.Items[I].Kind <> TDynamicKind.Str then
          Mismatch(ATypeInfo, AValue.Items[I], 'a string');
        TStrings(Result.AsObject).Add(AValue.Items[I].AsStr);
      end;
      Exit;
    end;
    if AValue.Kind <> TDynamicKind.Obj then Mismatch(ATypeInfo, AValue, 'an object');
    MembersFromDyn(Result.AsObject.ClassInfo, AValue, Result, APath);
  except
    { What this read constructed is this read's to free; an instance the
      caller passed in is never freed. }
    if Built then
    begin
      if TSerializationTypes.ContainerKindOf(ATypeInfo) <> TContainerKind.None then
        TSerializationOwnership.ReleaseBuiltContainer(Result.AsObject)
      else
        Result.AsObject.Free;
    end;
    raise;
  end;
end;

function FromDynValue(ATypeInfo: PTypeInfo; AValue: TDynamicValue;
  AMember: TSerializationMember; const AExisting: TValue;
  const APath: string): TValue;
var
  Access: TNullableAccess;
  V: Variant;
  OV: OleVariant;
  Why: string;
  Obj: TObject;
begin
  if ATypeInfo = nil then
    raise EDynamicError.Create('There is no type to read into.');
  Why := TSerializationTypes.UnsupportedReason(ATypeInfo);
  if Why <> '' then
    raise EDynamicError.CreateFmt('%s %s.', [TypeNameOf(ATypeInfo), Why]);

  if TSerializationTypes.TryGetNullableAccess(ATypeInfo, Access) then
  begin
    TValue.Make(nil, ATypeInfo, Result);
    if (AValue = nil) or AValue.IsNull then Exit;
    Access.SetValue(Result.GetReferenceToRawData,
      FromDyn(Access.ValueType, AValue, AMember, TValue.Empty, APath));
    Exit;
  end;

  if ATypeInfo.Kind = tkVariant then
  begin
    if not TSerializationVariants.TryFromDynamic(AValue, V, Why) then
      raise EDynamicError.Create('The dynamic value ' + Why + '.');
    if ATypeInfo = System.TypeInfo(OleVariant) then
    begin
      OV := V;
      TValue.Make(@OV, ATypeInfo, Result);
    end
    else
      TValue.Make(@V, ATypeInfo, Result);
    Exit;
  end;

  if (AValue = nil) or AValue.IsNull then
  begin
    if ATypeInfo.Kind = tkClass then
    begin
      Obj := nil;
      TValue.Make(@Obj, ATypeInfo, Result);
    end
    else
      TValue.Make(nil, ATypeInfo, Result);
    Exit;
  end;

  case ATypeInfo.Kind of
    tkInteger, tkInt64:
      Exit(IntegralOf(AValue, ATypeInfo));
    tkFloat:
      begin
        if TSerializationTypes.IsCompType(ATypeInfo) then
          Exit(IntegralOf(AValue, ATypeInfo));
        if GetTypeData(ATypeInfo).FloatType = ftCurr then
          Exit(CurrencyOf(AValue, ATypeInfo));
        if (ATypeInfo = System.TypeInfo(TDateTime)) or
           (ATypeInfo = System.TypeInfo(TDate)) or
           (ATypeInfo = System.TypeInfo(TTime)) then
          Exit(DateTimeOf(AValue, ATypeInfo));
        Exit(FloatOf(AValue, ATypeInfo));
      end;
    tkEnumeration:
      Exit(EnumOf(AValue, ATypeInfo, AMember));
    tkSet:
      Exit(SetOf(AValue, ATypeInfo));
    tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
      begin
        if AValue.Kind <> TDynamicKind.Str then Mismatch(ATypeInfo, AValue, 'a string');
        if not TSerializationTypes.TryStringFromText(ATypeInfo, AValue.AsStr,
             Result, Why) then
          raise EDynamicError.Create(Why + '.');
        Exit;
      end;
    tkDynArray:
      Exit(DynArrayOf(AValue, ATypeInfo, APath));
    tkArray:
      Exit(StaticArrayOf(AValue, ATypeInfo, APath));
    tkRecord, tkMRecord:
      begin
        if ATypeInfo = System.TypeInfo(TGUID) then Exit(GuidOf(AValue, ATypeInfo));
        Exit(RecordOf(AValue, ATypeInfo, AExisting, APath));
      end;
    tkClass:
      Exit(ClassOf(AValue, ATypeInfo, AExisting, APath));
  end;
  raise EDynamicError.CreateFmt('%s cannot be read from a dynamic value.',
    [TypeNameOf(ATypeInfo)]);
end;

{ Every object and array the read descends into is one level of the same
  limit every writer enforces (TSerializationGraphGuard): a hand-built tree
  nested deeper than SERIALIZATION_MAX_GRAPH_DEPTH is refused with
  ESerializationLimitExceeded, naming where, rather than running the stack
  out. }
function FromDyn(ATypeInfo: PTypeInfo; AValue: TDynamicValue;
  AMember: TSerializationMember; const AExisting: TValue;
  const APath: string): TValue;
begin
  if (AValue = nil) or not (AValue.Kind in [TDynamicKind.Arr,
     TDynamicKind.Obj]) then
    Exit(FromDynValue(ATypeInfo, AValue, AMember, AExisting, APath));
  try
    TSerializationGraphGuard.EnterLevel;
  except
    on E: ESerializationLimitExceeded do
      raise ESerializationLimitExceeded.CreateFmt('%s: %s', [APath, E.Message]);
  end;
  try
    Result := FromDynValue(ATypeInfo, AValue, AMember, AExisting, APath);
  finally
    TSerializationGraphGuard.LeaveLevel;
  end;
end;

class function TDynamicEngine.ToDelphi(AValue: TDynamicValue;
  ATypeInfo: PTypeInfo): TValue;
var
  Mark: Integer;
begin
  { A read that failed deep down must not leave the next one on this thread
    starting part way down the depth limit. }
  Mark := TSerializationGraphGuard.Level;
  try
    Result := FromDyn(ATypeInfo, AValue, nil, TValue.Empty, '$');
  finally
    TSerializationGraphGuard.RestoreLevel(Mark);
  end;
end;

class procedure TDynamicEngine.Populate(AInstance: TObject;
  AValue: TDynamicValue);
var
  Instance: TValue;
  Mark: Integer;
begin
  if AInstance = nil then
    raise EDynamicError.Create('There is no instance to populate.');
  if AValue = nil then
    raise EDynamicError.Create('There is no dynamic value to read.');
  TValue.Make(@AInstance, AInstance.ClassInfo, Instance);
  Mark := TSerializationGraphGuard.Level;
  try
    FromDyn(AInstance.ClassInfo, AValue, nil, Instance, '$');
  finally
    TSerializationGraphGuard.RestoreLevel(Mark);
  end;
end;

end.
