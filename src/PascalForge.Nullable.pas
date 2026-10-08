{*******************************************************************************
  PascalForge.Nullable

  Public nullable value type for PascalForge.Serialization.

  Responsibilities
    - TNullable<T>: a value plus a HasValue flag, with implicit conversions
      and equality.
    - TNullableHelper: RTTI access to a nullable's value and flag.

  Registration
    TNullable<T> is recognised by every format with no registration. Other
    libraries' nullables are registered with
    TSerialization.RegisterNullableFamily<T> (PascalForge.Serialization).

  Documentation
    docs/nullable-families.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Nullable;

interface

uses
  System.Rtti,
  System.SysUtils,
  System.Types,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.Math,
  System.TypInfo,
  System.DateUtils,
  System.Variants;

type
  TNullable<T> = record
  private
    FValue: T;
    FHasValue: Boolean;
    class var FComparer: IEqualityComparer<T>;

    class function EqualsComparer(const left, right: T): Boolean; static;
    class function EqualsInternal(const left, right: T): Boolean; static;
  public
    class operator Implicit(const Value: T): TNullable<T>;
    class operator Implicit(Value: Pointer): TNullable<T>;
    class operator Implicit(const Value: TNullable<T>): T;
    {class operator Implicit(const Value: Variant): TNullable<T>;
    class operator Implicit(const Value: TNullable<T>): Variant; }

    class operator Equal(const left, right: TNullable<T>): Boolean;
    class operator Equal(const left: TNullable<T>; const right: T): Boolean;
    class operator NotEqual(const left, right: TNullable<T>): Boolean;
    class operator NotEqual(const left: TNullable<T>; const right: T): Boolean;

    function Equals(const other: TNullable<T>): Boolean;

    property HasValue: Boolean read FHasValue;
    property Value: T read FValue;
  end;

  TNullableHelper = record
  strict private
    fValueType: PTypeInfo;
    fValueOffset: NativeInt;
    fHasValueOffset: NativeInt;
  public
    constructor Create(typeInfo: PTypeInfo);
    function GetValue(instance: Pointer): TValue; inline;
    function HasValue(instance: Pointer): Boolean; inline;
    procedure SetValue(instance: Pointer; const value: TValue); inline;
    procedure SetExactValue(instance: Pointer; const value: TValue); inline;
    property ValueType: PTypeInfo read fValueType;
  end;

function AsNullableString(const AValue: string): TNullable<string>;

implementation

function AsNullableString(const AValue: string): TNullable<string>;
begin
  if string.IsNullOrWhiteSpace(AValue) then
    Result := nil
  else
    Result := AValue;
end;

{ TNullable<T> }

function TNullable<T>.Equals(const other: TNullable<T>): Boolean;
begin
  if not HasValue then
    Exit(not other.HasValue);
  if not other.HasValue then
    Exit(False);
  Result := EqualsInternal(fValue, other.fValue);
end;

class function TNullable<T>.EqualsComparer(const left, right: T): Boolean;
begin
  if not Assigned(fComparer) then
    FComparer := TEqualityComparer<T>.Default;
  Result := FComparer.Equals(left, right);
end;

class function TNullable<T>.EqualsInternal(const left, right: T): Boolean;
var
  TypeKind: TTypeKind;
  ti: PTypeInfo;
begin
  Result := False;
  TypeKind := tkUnknown;

  ti := TypeInfo(T);
  if Assigned(ti) then
    TypeKind := ti.Kind;

  case TypeKind of
    tkInteger, tkEnumeration:
    begin
      case Integer(SizeOf(T)) of
        1: Result := PByte(@left)^ = PByte(@right)^;
        2: Result := PWord(@left)^ = PWord(@right)^;
        4: Result := PCardinal(@left)^ = PCardinal(@right)^;
      end;
    end;
{$IFNDEF NEXTGEN}
    tkChar: Result := PAnsiChar(@left)^ = PAnsiChar(@right)^;
    tkString: Result := PShortString(@left)^ = PShortString(@right)^;
    tkLString: Result := PAnsiString(@left)^ = PAnsiString(@right)^;
    tkWString: Result := PWideString(@left)^ = PWideString(@right)^;
{$ENDIF}
    tkFloat:
    begin
      if TypeInfo(T) = TypeInfo(Single) then
        Result := System.Math.SameValue(PSingle(@left)^, PSingle(@right)^)
      else if TypeInfo(T) = TypeInfo(Double) then
        Result := System.Math.SameValue(PDouble(@left)^, PDouble(@right)^)
      else if TypeInfo(T) = TypeInfo(Extended) then
        Result := System.Math.SameValue(PExtended(@left)^, PExtended(@right)^)
      else if TypeInfo(T) = TypeInfo(TDateTime) then
        Result := SameDateTime(PDateTime(@left)^, PDateTime(@right)^)
      else
        case GetTypeData(TypeInfo(T)).FloatType of
          ftSingle: Result := System.Math.SameValue(PSingle(@left)^, PSingle(@right)^);
          ftDouble: Result := System.Math.SameValue(PDouble(@left)^, PDouble(@right)^);
          ftExtended: Result := System.Math.SameValue(PExtended(@left)^, PExtended(@right)^);
          ftComp: Result := PComp(@left)^ = PComp(@right)^;
          ftCurr: Result := PCurrency(@left)^ = PCurrency(@right)^;
        end;
    end;
    tkWChar: Result := PWideChar(@left)^ = PWideChar(@right)^;
    tkInt64: Result := PInt64(@left)^ = PInt64(@right)^;
    tkUString: Result := PUnicodeString(@left)^ = PUnicodeString(@right)^;
  else
    Result := EqualsComparer(left, right);
  end;
end;

{class operator TNullable<T>.Implicit(const Value: TNullable<T>): Variant;
begin
  if Value.HasValue then
  begin
    var val := TValue.From<T>(Value.Value);
    Result := val.AsVariant;
  end
  else
    Result := Null;
end;}

class operator TNullable<T>.Implicit(const Value: T): TNullable<T>;
begin
  Result.FValue := Value;
  Result.FHasValue := True;
end;

class operator TNullable<T>.Implicit(Value: Pointer): TNullable<T>;
begin
  Assert(Value = nil, 'The only valid value is nil');
  Result.FHasValue := False;
end;

class operator TNullable<T>.Equal(const left, right: TNullable<T>): Boolean;
begin
  Result := left.Equals(right);
end;

class operator TNullable<T>.Equal(const left: TNullable<T>; const right: T): Boolean;
begin
  if not left.HasValue then
    Exit(False);
  Result := EqualsInternal(left.Value, right);
end;

class operator TNullable<T>.Implicit(const Value: TNullable<T>): T;
begin
  if not Value.FHasValue then
    Result := default (T)
  else
    Result := Value.FValue;
end;

class operator TNullable<T>.NotEqual(const left, right: TNullable<T>): Boolean;
begin
  Result := not left.Equals(right);
end;

class operator TNullable<T>.NotEqual(const left: TNullable<T>; const right: T): Boolean;
begin
  if not left.HasValue then
    Exit(True);
  Result := not EqualsInternal(left.Value, right);
end;

{class operator TNullable<T>.Implicit(const Value: Variant): TNullable<T>;
begin
  if Value = Null then
    Result := nil
  else
  begin
    var val := TValue.FromVariant(Value);
    Result := val.AsType<T>;
  end;
end;    }

{ TNullableHelper }

constructor TNullableHelper.Create(typeInfo: PTypeInfo);
var
  p: PByte;
  field: PRecordTypeField;
  fieldCount, I: Integer;

  function SkipShortString(P: PByte): Pointer;
  begin
    Result := P + P^ + 1;
  end;

begin
  p := @typeInfo.TypeData.ManagedFldCount;
  // skip TTypeData.ManagedFldCount and TTypeData.ManagedFields
  Inc(p, SizeOf(Integer) + SizeOf(TManagedField) * PInteger(p)^);
  // skip TTypeData.NumOps and TTypeData.RecOps
  Inc(p, SizeOf(Byte) + SizeOf(Pointer) * p^);
  fieldCount := PInteger(p)^;
  Inc(p, SizeOf(Integer));
  fValueType := nil;
  fValueOffset := 0;
  fHasValueOffset := 0;
  for I := 0 to fieldCount - 1 do
  begin
    field := PRecordTypeField(p);
    if SameText(UTF8ToString(field.Name), 'FValue') or
       SameText(UTF8ToString(field.Name), 'Value') then
    begin
      fValueType := field.Field.TypeRef^;
      fValueOffset := field.Field.FldOffset;
    end
    else if SameText(UTF8ToString(field.Name), 'FHasValue') or
            SameText(UTF8ToString(field.Name), 'HasValue') then
      fHasValueOffset := field.Field.FldOffset;
    p := PByte(SkipShortString(@field.Name)) + SizeOf(TAttrData);
  end;
  if fValueType = nil then
    raise EInvalidOp.CreateFmt('Nullable value field not found in %s',
      [UTF8ToString(typeInfo.Name)]);
end;

function TNullableHelper.GetValue(instance: Pointer): TValue;
begin
  TValue.Make(PByte(instance) + fValueOffset, fValueType, Result);
end;

function TNullableHelper.HasValue(instance: Pointer): Boolean;
begin
  Result := PBoolean(PByte(instance) + fHasValueOffset)^;
end;

procedure TNullableHelper.SetValue(instance: Pointer; const value: TValue);
begin
  value.Cast(fValueType).ExtractRawData(PByte(instance) + fValueOffset);

  if value.IsEmpty then
    PBoolean(PByte(instance) + fHasValueOffset)^ := False
  else
    PBoolean(PByte(instance) + fHasValueOffset)^ := True;
end;

procedure TNullableHelper.SetExactValue(instance: Pointer; const value: TValue);
begin
  // The caller has already proved that the TValue has precisely the nullable
  // inner type.  Avoid TValue.Cast while retaining normal managed assignment
  // through ExtractRawData.
  value.ExtractRawData(PByte(instance) + fValueOffset);
  PBoolean(PByte(instance) + fHasValueOffset)^ := not value.IsEmpty;
end;

end.
