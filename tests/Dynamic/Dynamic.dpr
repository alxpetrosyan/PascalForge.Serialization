program Dynamic;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The dynamic structural model, end to end.

  What this program checks:
    * every scalar kind and its boundaries;
    * an object's exact-case names, insertion order and unique names;
    * the fluent Append / InsertAt / AddObject / AddArray surface;
    * ownership: what moves in, when, and what a refusal leaves where;
    * extraction, removal and clearing; cycle prevention;
    * clone and deep equality; import and merge under every collision rule;
    * arrays: nesting, the explicit AppendRange flatten;
    * Delphi values projected in - classes, records, lists, dictionaries,
      nullables, sets, Variants - and read back, with the general attributes;
    * Dynamic to and from every structural format, the schema-driven ones
      with their schemas, and through TSerialization at run time;
    * DataSet to and from Dynamic, with and without a contract, under every
      policy, with explicit interpretation only;
    * the shared RTTI metadata: one discovery per type, whichever engine
      asks first. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo, System.Math,
  System.DateUtils, System.Variants, System.IOUtils, System.StrUtils,
  System.Generics.Collections,
  Data.DB, FireDAC.Comp.Client, FireDAC.Stan.Intf, FireDAC.Comp.DataSet,
  AllFormatsRegistered in '..\Shared\AllFormatsRegistered.pas',
  DynamicModels in 'DynamicModels.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization.Attributes in '..\..\src\PascalForge.Serialization.Attributes.pas',
  PascalForge.Serialization.Internal in '..\..\src\PascalForge.Serialization.Internal.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  PascalForge.Xml in '..\..\src\PascalForge.Xml.pas',
  PascalForge.Bson in '..\..\src\PascalForge.Bson.pas',
  PascalForge.Cbor in '..\..\src\PascalForge.Cbor.pas',
  PascalForge.MessagePack in '..\..\src\PascalForge.MessagePack.pas',
  PascalForge.Yaml in '..\..\src\PascalForge.Yaml.pas',
  PascalForge.Csv in '..\..\src\PascalForge.Csv.pas',
  PascalForge.Avro.Schema in '..\..\src\PascalForge.Avro.Schema.pas',
  PascalForge.Avro in '..\..\src\PascalForge.Avro.pas',
  PascalForge.Asn1.Schema in '..\..\src\PascalForge.Asn1.Schema.pas',
  PascalForge.Asn1 in '..\..\src\PascalForge.Asn1.pas',
  PascalForge.Protobuf in '..\..\src\PascalForge.Protobuf.pas',
  PascalForge.Protobuf.Schema in '..\..\src\PascalForge.Protobuf.Schema.pas',
  PascalForge.DataSet in '..\..\src\PascalForge.DataSet.pas';

var
  GFailures: Integer = 0;

procedure Check(ACondition: Boolean; const AName: string);
begin
  if ACondition then
    Writeln(AName, ': PASS')
  else
  begin
    Writeln(AName, ': FAIL');
    Inc(GFailures);
  end;
end;

procedure Note(const AText: string);
begin
  Writeln('  ', AText);
end;

{ True when AStep raised EDynamicError. }
function Refused(const AStep: TProc): Boolean;
begin
  Result := False;
  try
    AStep();
  except
    on E: EDynamicError do Result := True;
  end;
end;

{ =========================================================================
  THE MODEL
  ========================================================================= }

procedure TestScalars;
var
  V: TDynamicValue;
  Ok: Boolean;
begin
  Writeln;
  Writeln('--- scalar kinds and boundaries ---');
  Ok := True;
  V := TDynamicValue.NewInt(Low(Int64));
  try
    Ok := Ok and (V.Kind = TDynamicKind.Int) and (V.AsInt = Low(Int64));
  finally
    V.Free;
  end;
  V := TDynamicValue.NewUInt(High(UInt64));
  try
    Ok := Ok and (V.Kind = TDynamicKind.UInt) and (V.AsUInt = High(UInt64)) and
      (V.AsDecimal = '18446744073709551615');
  finally
    V.Free;
  end;
  { One representation for every ordinary number. }
  V := TDynamicValue.NewUInt(7);
  try
    Ok := Ok and (V.Kind = TDynamicKind.Int) and (V.AsInt = 7);
  finally
    V.Free;
  end;
  Check(Ok, 'DYNAMIC_INTEGER_BOUNDARIES');

  V := TDynamicValue.NewDecimal('123456789012345678901234567890.0001');
  try
    Check((V.Kind = TDynamicKind.Decimal) and
      (V.AsDecimal = '123456789012345678901234567890.0001'),
      'DYNAMIC_DECIMAL_IS_EXACT_TEXT');
  finally
    V.Free;
  end;

  V := TDynamicValue.NewDate(EncodeDateTime(2026, 10, 6, 13, 45, 0, 0));
  try
    Ok := (V.Kind = TDynamicKind.Date) and (Frac(V.AsDateTime) = 0);
  finally
    V.Free;
  end;
  V := TDynamicValue.NewTime(EncodeDateTime(2026, 10, 6, 13, 45, 0, 0));
  try
    Ok := Ok and (V.Kind = TDynamicKind.Time) and (Int(V.AsDateTime) = 0);
  finally
    V.Free;
  end;
  Check(Ok, 'DYNAMIC_DATE_AND_TIME_DROP_THE_OTHER_HALF');

  V := TDynamicValue.NewBytes(TBytes.Create(0, 255, 7));
  try
    Check((V.Kind = TDynamicKind.Bytes) and (Length(V.AsBytes) = 3) and
      (V.AsBytes[1] = 255), 'DYNAMIC_BYTES');
  finally
    V.Free;
  end;

  V := TDynamicValue.NewExtended(TDynamicTag.ObjectId,
    TDynamicValue.NewStr('0123456789abcdef01234567'));
  try
    Check(V.IsTagged(TDynamicTag.ObjectId) and (V.Count = 0) and
      (V.ExtendedValue.AsStr = '0123456789abcdef01234567') and
      (V.ExtendedValue.Parent = V), 'DYNAMIC_EXTENDED_OWNS_ITS_PAYLOAD');
  finally
    V.Free;
  end;
  Check(Refused(procedure begin TDynamicValue.NewExtended('', nil).Free end),
    'DYNAMIC_EXTENDED_NEEDS_A_TAG');
  Check(TDynamicValue.KindName(TDynamicKind.UInt) = 'unsigned integer',
    'DYNAMIC_KIND_NAMES');
end;

procedure TestObjectBasics;
var
  Obj: TDynamicObject;
  Child: TDynamicValue;
  Ok: Boolean;
begin
  Writeln;
  Writeln('--- an object: exact names, order, fluent building ---');
  Obj := TDynamicObject.Create;
  try
    { The task's own example, verbatim. }
    Obj
      .Append('name', 'Erin')
      .Append('age', 35)
      .Append('active', True);
    Obj.InsertAt(1, 'country', 'Utopia');
    Obj.AddObject('address')
      .Append('city', 'Uptown')
      .Append('country', 'Ireland');

    Check((Obj.Count = 5) and (Obj.Names[0] = 'name') and
      (Obj.Names[1] = 'country') and (Obj.Names[2] = 'age') and
      (Obj.Names[3] = 'active') and (Obj.Names[4] = 'address'),
      'DYNAMIC_INSERTION_ORDER');
    Check((Obj.Get('age').Kind = TDynamicKind.Int) and
      (Obj.Get('age').AsInt = 35) and (Obj.Get('active').AsBool) and
      (Obj.Get('address').AsObject.Get('city').AsStr = 'Uptown'),
      'DYNAMIC_FLUENT_VALUES');

    { Exact case: three different members. }
    Obj.Append('Name', 'upper').Append('NAME', 'shout');
    Check((Obj.Find('name').AsStr = 'Erin') and
      (Obj.Find('Name').AsStr = 'upper') and (Obj.Find('nAmE') = nil),
      'DYNAMIC_EXACT_CASE_NAMES');

    { A duplicate is refused, the object unchanged. }
    Check(Refused(procedure begin Obj.Append('name', 'again') end) and
      (Obj.Count = 7) and (Obj.Get('name').AsStr = 'Erin'),
      'DYNAMIC_DUPLICATE_REFUSED');
    { Replacement is explicit. }
    Obj.AppendOrReplace('name', TDynamicValue.NewStr('Erika'));
    Check((Obj.Count = 7) and (Obj.IndexOf('name') = 0) and
      (Obj.Get('name').AsStr = 'Erika'), 'DYNAMIC_REPLACE_IS_EXPLICIT');

    { InsertAt(Count) appends; past it is refused. }
    Obj.InsertAt(Obj.Count, 'last', 1);
    Check((Obj.Names[Obj.Count - 1] = 'last') and
      Refused(procedure begin Obj.InsertAt(Obj.Count + 1, 'x', 1) end),
      'DYNAMIC_INSERT_AT_COUNT_APPENDS');

    { Many members: the index takes over and still finds exactly. }
    Ok := True;
    for var I := 0 to 99 do Obj.Append('k' + IntToStr(I), I);
    for var I := 0 to 99 do
      if Obj.Get('k' + IntToStr(I)).AsInt <> I then Ok := False;
    Check(Ok and (Obj.Find('K5') = nil) and (Obj.IndexOf('k50') = 58),
      'DYNAMIC_LARGE_OBJECT_LOOKUP');

    { Extraction: the caller owns the member, now a root. }
    Child := Obj.Extract('address');
    try
      Check((Child <> nil) and (Child.Parent = nil) and not Obj.Contains('address') and
        (Child.AsObject.Get('country').AsStr = 'Ireland'), 'DYNAMIC_EXTRACT');
    finally
      Child.Free;
    end;
    Check(Obj.Remove('last') and not Obj.Remove('last'), 'DYNAMIC_REMOVE');
    Obj.Delete(0);
    Check(Obj.Names[0] = 'country', 'DYNAMIC_DELETE_AT');
    Obj.Clear;
    Check((Obj.Count = 0) and (Obj.Find('k1') = nil), 'DYNAMIC_CLEAR');
  finally
    Obj.Free;
  end;
end;

procedure TestOwnership;
var
  A, B: TDynamicObject;
  Arr: TDynamicArray;
  V: TDynamicValue;
begin
  Writeln;
  Writeln('--- ownership and cycles ---');
  A := TDynamicObject.Create;
  B := TDynamicObject.Create;
  try
    V := TDynamicValue.NewStr('mine');
    A.Append('v', V);
    Check(V.Parent = A, 'DYNAMIC_APPEND_TRANSFERS_OWNERSHIP');
    { A value that belongs to A cannot also belong to B. }
    Check(Refused(procedure begin B.Append('v', V) end) and (V.Parent = A) and
      (B.Count = 0), 'DYNAMIC_ONE_OWNER');

    { A refused Append leaves the value with the caller. }
    V := TDynamicValue.NewStr('second');
    try
      Check(Refused(procedure begin A.Append('v', V) end) and (V.Parent = nil),
        'DYNAMIC_REFUSAL_KEEPS_CALLER_OWNERSHIP');
    finally
      V.Free;
    end;

    { Cycles: a container cannot hold itself or an ancestor. }
    Check(Refused(procedure begin A.Append('self', A) end), 'DYNAMIC_NO_SELF_CYCLE');
    A.Append('b', B);
    Check(Refused(procedure begin B.Append('up', A) end) and (B.Count = 0),
      'DYNAMIC_NO_ANCESTOR_CYCLE');
    B := nil;
  finally
    B.Free;
    A.Free;
  end;

  Arr := TDynamicArray.Create;
  try
    Check(Refused(procedure begin Arr.Append(Arr) end) and
      Refused(procedure begin Arr.Append(TDynamicValue(nil)) end),
      'DYNAMIC_ARRAY_NO_CYCLE_NO_NIL');
  finally
    Arr.Free;
  end;
end;

procedure TestArrays;
var
  Arr, Inner, Flat: TDynamicArray;
begin
  Writeln;
  Writeln('--- arrays ---');
  Arr := TDynamicArray.Create;
  try
    Arr
      .Append(10)
      .Append(20)
      .Append('thirty');
    Arr.InsertAt(1, 15);
    Check((Arr.Count = 4) and (Arr[1].AsInt = 15) and (Arr[3].AsStr = 'thirty'),
      'DYNAMIC_ARRAY_FLUENT');

    { Appending an array nests it. }
    Inner := TDynamicArray.Create;
    Inner.Append(1).Append(2);
    Arr.Append(Inner);
    Check((Arr.Count = 5) and (Arr[4].Kind = TDynamicKind.Arr) and
      (Arr[4].Count = 2), 'DYNAMIC_ARRAY_APPEND_NESTS');

    { AppendRange is the explicit flatten, and copies. }
    Flat := TDynamicArray.Create;
    try
      Flat.AppendRange(Inner).AppendRange(Inner);
      Check((Flat.Count = 4) and (Flat[3].AsInt = 2) and (Inner.Count = 2),
        'DYNAMIC_ARRAY_APPEND_RANGE_FLATTENS');
    finally
      Flat.Free;
    end;
    Arr.ReplaceAt(0, TDynamicValue.NewStr('ten'));
    Arr.Delete(1);
    Check((Arr[0].AsStr = 'ten') and (Arr[1].AsInt = 20), 'DYNAMIC_ARRAY_EDIT');
    Arr.AddObject.Append('k', 'v');
    Arr.AddArray.Append(True);
    Check((Arr[Arr.Count - 2].AsObject.Get('k').AsStr = 'v') and
      Arr[Arr.Count - 1][0].AsBool, 'DYNAMIC_ARRAY_ADD_CHILDREN');
  finally
    Arr.Free;
  end;
end;

procedure TestCloneEquality;
var
  A, B: TDynamicObject;
  C: TDynamicValue;
begin
  Writeln;
  Writeln('--- clone and equality ---');
  A := TDynamicObject.Create;
  B := TDynamicObject.Create;
  try
    A.Append('x', 1).Append('y', 'two').AddArray('z').Append(1).Append(2);
    { Same members, other order. }
    B.AddArray('z').Append(1).Append(2);
    B.Append('y', 'two').Append('x', 1);
    Check(A.Equals(B) and (A.GetHashCode = B.GetHashCode),
      'DYNAMIC_OBJECT_EQUALITY_IGNORES_ORDER');
    B.Get('z').AsArray.ReplaceAt(0, TDynamicValue.NewInt(2));
    B.Get('z').AsArray.ReplaceAt(1, TDynamicValue.NewInt(1));
    Check(not A.Equals(B), 'DYNAMIC_ARRAY_EQUALITY_IS_ORDERED');

    C := A.Clone;
    try
      Check(C.Equals(A) and (C.Parent = nil) and (C <> A), 'DYNAMIC_CLONE_EQUALS');
      C.AsObject.Append('w', 0);
      Check(not C.Equals(A) and (A.Count = 3), 'DYNAMIC_CLONE_IS_INDEPENDENT');
    finally
      C.Free;
    end;
    { Kinds matter: 1 and 1.0 are different values. }
    C := TDynamicValue.NewFloat(1);
    try
      Check(not C.Equals(A.Get('x')), 'DYNAMIC_EQUALITY_COMPARES_KINDS');
    finally
      C.Free;
    end;
  finally
    B.Free;
    A.Free;
  end;
end;

procedure TestMerge;
var
  Base, Incoming, Work: TDynamicObject;

  function Fresh: TDynamicObject;
  begin
    Result := Base.Clone.AsObject;
  end;

begin
  Writeln;
  Writeln('--- import and merge ---');
  Base := TDynamicObject.Create;
  Incoming := TDynamicObject.Create;
  try
    Base.Append('a', 1).AddObject('o').Append('p', 1).Append('q', 1);
    Base.AddArray('list').Append(1);
    Incoming.Append('a', 2).Append('b', 2).AddObject('o').Append('q', 2)
      .Append('r', 2);
    Incoming.AddArray('list').Append(9).Append(9);

    Work := Fresh;
    try
      Check(Refused(procedure begin Work.Import(Incoming) end) and
        Work.Equals(Base), 'DYNAMIC_IMPORT_ERROR_IS_ATOMIC');
      Work.Import(Incoming, TDynamicCollision.KeepExisting);
      Check((Work.Get('a').AsInt = 1) and (Work.Get('b').AsInt = 2) and
        (Work.Get('o').Count = 2), 'DYNAMIC_IMPORT_KEEP_EXISTING');
    finally
      Work.Free;
    end;

    Work := Fresh;
    try
      Work.Import(Incoming, TDynamicCollision.Overwrite);
      Check((Work.Get('a').AsInt = 2) and (Work.IndexOf('a') = 0) and
        (Work.Get('o').Find('p') = nil) and (Work.Get('list').Count = 2),
        'DYNAMIC_IMPORT_OVERWRITE');
    finally
      Work.Free;
    end;

    Work := Fresh;
    try
      Work.Import(Incoming, TDynamicCollision.DeepMerge);
      { Objects merge member by member; an array is replaced, never
        concatenated. }
      Check((Work.Get('o').AsObject.Get('p').AsInt = 1) and
        (Work.Get('o').AsObject.Get('q').AsInt = 2) and
        (Work.Get('o').AsObject.Get('r').AsInt = 2) and
        (Work.Get('list').Count = 2) and (Work.Get('list')[0].AsInt = 9),
        'DYNAMIC_IMPORT_DEEP_MERGE');
      Check(Incoming.Count = 4, 'DYNAMIC_IMPORT_LEAVES_SOURCE');
    finally
      Work.Free;
    end;

    Work := Fresh;
    try
      Work.MoveFrom(Incoming, TDynamicCollision.Overwrite);
      Check((Incoming.Count = 0) and (Work.Get('b').AsInt = 2) and
        (Work.Get('b').Parent = Work), 'DYNAMIC_MOVE_FROM_TRANSFERS');
    finally
      Work.Free;
    end;
  finally
    Incoming.Free;
    Base.Free;
  end;
end;

{ =========================================================================
  DELPHI VALUES
  ========================================================================= }

function NewPerson: TPerson;
begin
  Result := TPerson.Create;
  Result.Name := 'Erin';
  Result.Age := 35;
  Result.Active := True;
  Result.Address.City := 'Uptown';
  Result.Address.Country := 'Ireland';
  Result.Tags.Add('a');
  Result.Tags.Add('b');
end;

procedure TestProjection;
var
  Person, Back: TPerson;
  Obj: TDynamicObject;
  Arr: TDynamicArray;
  V: TDynamicValue;
  P: TPoint;
begin
  Writeln;
  Writeln('--- Delphi values in and out ---');
  Person := NewPerson;
  try
    Obj := TDynamicObject.Create;
    try
      Obj.Append('person', Person);
      Check((Obj.Get('person').AsObject.Get('Name').AsStr = 'Erin') and
        (Obj.Get('person').AsObject.Get('Address').AsObject.Get('City').AsStr =
          'Uptown') and (Obj.Get('person').AsObject.Get('Tags').Count = 2),
        'DYNAMIC_APPEND_NAMED_PROJECTS');
    finally
      Obj.Free;
    end;

    Obj := TDynamicObject.Create;
    try
      Obj.Append('kind', 'person');
      Obj.Append(Person);
      Check((Obj.Count = 6) and (Obj.Names[0] = 'kind') and
        (Obj.Get('Age').AsInt = 35), 'DYNAMIC_APPEND_UNNAMED_IMPORTS_MEMBERS');
      { Its members are already there: importing again collides. }
      Check(Refused(procedure begin Obj.Append(Person) end),
        'DYNAMIC_APPEND_UNNAMED_COLLISION_REFUSED');
      Check(Refused(procedure begin Obj.Append<Integer>(5) end),
        'DYNAMIC_APPEND_UNNAMED_SCALAR_REFUSED');
    finally
      Obj.Free;
    end;

    Arr := TDynamicArray.Create;
    try
      Arr.Append(Person).Append(Person);
      Check((Arr.Count = 2) and (Arr[1].AsObject.Get('Name').AsStr = 'Erin'),
        'DYNAMIC_ARRAY_APPEND_PROJECTS');
    finally
      Arr.Free;
    end;

    V := TDynamicSerializer.Serialize<TPerson>(Person);
    try
      Back := TDynamicSerializer.Deserialize<TPerson>(V);
      try
        Check((Back.Name = 'Erin') and (Back.Age = 35) and Back.Active and
          (Back.Address.Country = 'Ireland') and (Back.Tags.Count = 2) and
          (Back.Tags[1] = 'b'), 'DYNAMIC_SERIALIZER_ROUND_TRIP');
      finally
        Back.Free;
      end;
      { Populate fills an instance the caller owns, in place. }
      Back := TPerson.Create;
      try
        TDynamicSerializer.Populate(Back, V);
        Check(Back.Address.City = 'Uptown', 'DYNAMIC_POPULATE');
      finally
        Back.Free;
      end;
    finally
      V.Free;
    end;
  finally
    Person.Free;
  end;

  P.X := 3;
  P.Y := -4;
  V := TDynamicSerializer.Serialize<TPoint>(P);
  try
    P := TDynamicSerializer.Deserialize<TPoint>(V);
    Check((V.Count = 2) and (P.X = 3) and (P.Y = -4), 'DYNAMIC_RECORD_ROUND_TRIP');
  finally
    V.Free;
  end;

  { Names: Delphi identifiers are case-insensitive, so a member read back
    from a camelCase document still finds its field when no exact match
    exists. }
  Obj := TDynamicObject.Create;
  try
    Obj.Append('name', 'lower').Append('age', 9);
    Back := TDynamicSerializer.Deserialize<TPerson>(Obj);
    try
      Check((Back.Name = 'lower') and (Back.Age = 9),
        'DYNAMIC_READ_MATCHES_IDENTIFIER_CASE_INSENSITIVELY');
    finally
      Back.Free;
    end;
    Obj.Append('Age', 'not a number');
    Check(Refused(procedure begin TDynamicSerializer.Deserialize<TPerson>(Obj).Free end),
      'DYNAMIC_READ_REFUSES_A_MISMATCH');
  finally
    Obj.Free;
  end;
end;

procedure TestEveryKind;
var
  E, Back: TEverything;
  V: TDynamicValue;
  A: TAddress;
  Ok: Boolean;
  Bad: string;
begin
  Writeln;
  Writeln('--- every Delphi kind through Dynamic ---');
  E := TEverything.Create;
  try
    E.I8 := -128; E.U8 := 255; E.I32 := Low(Integer); E.U32 := High(Cardinal);
    E.I64 := Low(Int64); E.U64 := High(UInt64);
    E.F64 := 0.1; E.F32 := 1.5; E.Money := 1234.5678;
    E.Day := EncodeDate(2026, 10, 6); E.Clock := EncodeTime(13, 45, 30, 0);
    E.Moment := EncodeDateTime(2026, 10, 6, 13, 45, 30, 123);
    E.Flag := True; E.Text := 'midtown ' + #$10D2#$10D0; E.Letter := 'Z';
    E.Blob := TBytes.Create(1, 2, 3);
    E.Id := StringToGUID('{0F8FAD5B-D9CB-469F-A165-70867728950E}');
    E.Colors := [Red, Blue]; E.State := InProgress; E.Maybe := 42;
    E.Anything := 'variant';
    E.Ints := [1, 2, 3]; E.Fixed[0] := 7; E.Fixed[2] := 9;
    E.Point.X := 1; E.Point.Y := 2;
    E.Scores.Add('alpha', 1);
    A := TAddress.Create; A.City := 'Seaport'; E.People.Add(A);

    V := TDynamicSerializer.Serialize<TEverything>(E);
    try
      Ok := (V.Find('U64').Kind = TDynamicKind.UInt) and
        (V.Find('Money').Kind = TDynamicKind.Decimal) and
        (V.Find('Money').AsDecimal = '1234.5678') and
        (V.Find('Day').Kind = TDynamicKind.Date) and
        (V.Find('Clock').Kind = TDynamicKind.Time) and
        (V.Find('Moment').Kind = TDynamicKind.DateTime) and
        (V.Find('Blob').Kind = TDynamicKind.Bytes) and
        (V.Find('Id').AsStr = '0f8fad5b-d9cb-469f-a165-70867728950e') and
        (V.Find('Colors').Count = 2) and
        (V.Find('State').AsStr = 'in-progress') and
        (V.Find('Maybe').AsInt = 42) and (V.Find('Missing') = nil) and
        (V.Find('Scores').Find('alpha').AsInt = 1) and
        (V.Find('People')[0].Find('City').AsStr = 'Seaport');
      Check(Ok, 'DYNAMIC_EVERY_KIND_HAS_ITS_DYNAMIC_KIND');
      if not Ok then Note(V.Describe);

      Back := TDynamicSerializer.Deserialize<TEverything>(V);
      try
        Bad := '';
        if not ((Back.I8 = -128) and (Back.U8 = 255) and (Back.I32 = Low(Integer)) and
          (Back.U32 = High(Cardinal)) and (Back.I64 = Low(Int64)) and
          (Back.U64 = High(UInt64))) then Bad := Bad + ' integers';
        if not ((Back.F64 = E.F64) and (Back.F32 = E.F32)) then Bad := Bad + ' floats';
        if Back.Money <> 1234.5678 then Bad := Bad + ' currency';
        if not ((Back.Day = E.Day) and (Back.Clock = E.Clock) and
          (Back.Moment = E.Moment)) then Bad := Bad + ' dates';
        if not (Back.Flag and (Back.Text = E.Text) and (Back.Letter = 'Z')) then
          Bad := Bad + ' text';
        if not ((Length(Back.Blob) = 3) and (Back.Blob[2] = 3)) then Bad := Bad + ' bytes';
        if not IsEqualGUID(Back.Id, E.Id) then Bad := Bad + ' guid';
        if Back.Colors <> [Red, Blue] then Bad := Bad + ' set';
        if Back.State <> InProgress then Bad := Bad + ' enum';
        if not (Back.Maybe.HasValue and (Back.Maybe.Value = 42) and
          not Back.Missing.HasValue) then Bad := Bad + ' nullable';
        if not VarSameValue(Back.Anything, 'variant') then Bad := Bad + ' variant';
        if not ((Length(Back.Ints) = 3) and (Back.Fixed[2] = 9) and
          (Back.Point.Y = 2)) then Bad := Bad + ' arrays';
        if not (Back.Scores.ContainsKey('alpha') and (Back.People.Count = 1) and
          (Back.People[0].City = 'Seaport')) then Bad := Bad + ' containers';
        Check(Bad = '', 'DYNAMIC_EVERY_KIND_ROUND_TRIPS');
        if Bad <> '' then Note('wrong:' + Bad);
      finally
        Back.Free;
      end;
    finally
      V.Free;
    end;

    { Out of range on the way back is refused, not wrapped. }
    V := TDynamicSerializer.Serialize<TEverything>(E);
    try
      V.AsObject.AppendOrReplace('U8', TDynamicValue.NewInt(256));
      Check(Refused(procedure begin TDynamicSerializer.Deserialize<TEverything>(V).Free end),
        'DYNAMIC_READ_RANGE_CHECKED');
    finally
      V.Free;
    end;
  finally
    E.Free;
  end;
end;

procedure TestGeneralAttributes;
var
  A, Back: TAttributed;
  V: TDynamicValue;
begin
  Writeln;
  Writeln('--- the general attributes in Dynamic ---');
  A := TAttributed.Create;
  try
    A.Key := 7; A.Secret := 'hidden'; A.Color := Green; A.State := Done;
    A.Plain := 'p';
    V := TDynamicSerializer.Serialize<TAttributed>(A);
    try
      Check((V.Find('id').AsInt = 7) and (V.Find('Key') = nil),
        'DYNAMIC_SERIALIZATION_NAME');
      Check(V.Find('Secret') = nil, 'DYNAMIC_SERIALIZATION_IGNORE');
      Check((V.Find('Color').AsStr = 'g') and (V.Find('State').AsStr = 'done'),
        'DYNAMIC_SERIALIZATION_ENUM_MEMBER_AND_TYPE');
      V.AsObject.Append('Secret', 'injected');
      Back := TDynamicSerializer.Deserialize<TAttributed>(V);
      try
        Check((Back.Key = 7) and (Back.Secret = '') and (Back.Color = Green) and
          (Back.State = Done), 'DYNAMIC_GENERAL_ATTRIBUTES_READ_BACK');
      finally
        Back.Free;
      end;
    finally
      V.Free;
    end;
  finally
    A.Free;
  end;
end;

{ =========================================================================
  FORMATS
  ========================================================================= }

function SampleTree: TDynamicObject;
begin
  Result := TDynamicObject.Create;
  Result
    .Append('name', 'Erin')
    .Append('age', 35)
    .Append('active', True)
    .AppendNull('nothing');
  Result.AddObject('address').Append('city', 'Uptown');
  Result.AddArray('tags').Append('a').Append('b');
end;

procedure TestFormats;
var
  Tree: TDynamicObject;
  Back: TDynamicValue;
  Json, Xml, Yaml, Csv: string;
  Bytes: TBytes;
  Rows: TDynamicArray;

  procedure Same(ABack: TDynamicValue; const AName: string);
  begin
    try
      Check(Tree.Equals(ABack), AName);
      if not Tree.Equals(ABack) then Note(ABack.Describe);
    finally
      ABack.Free;
    end;
  end;

begin
  Writeln;
  Writeln('--- Dynamic to and from each format ---');
  Tree := SampleTree;
  try
    Json := TJsonSerializer.FromDynamic(Tree);
    Note(Json);
    Same(TJsonSerializer.ToDynamic(Json), 'DYNAMIC_JSON_ROUND_TRIP');
    Bytes := TBsonSerializer.FromDynamic(Tree);
    Same(TBsonSerializer.ToDynamic(Bytes), 'DYNAMIC_BSON_ROUND_TRIP');
    Bytes := TCborSerializer.FromDynamic(Tree);
    Same(TCborSerializer.ToDynamic(Bytes), 'DYNAMIC_CBOR_ROUND_TRIP');
    Bytes := TMessagePackSerializer.FromDynamic(Tree);
    Same(TMessagePackSerializer.ToDynamic(Bytes), 'DYNAMIC_MESSAGEPACK_ROUND_TRIP');
    Yaml := TYamlSerializer.FromDynamic(Tree);
    Same(TYamlSerializer.ToDynamic(Yaml), 'DYNAMIC_YAML_ROUND_TRIP');

    { XML carries text: the structure survives, the scalars come back as
      what XML holds. }
    Xml := TXmlSerializer.FromDynamic(Tree, 'Person');
    Note(Xml);
    Back := TXmlSerializer.ToDynamic(Xml);
    try
      Check((Back.Find('name').AsStr = 'Erin') and
        (Back.Find('address').Find('city').AsStr = 'Uptown') and
        (Back.Find('tags').Count = 2), 'DYNAMIC_XML_ROUND_TRIP_STRUCTURE');
    finally
      Back.Free;
    end;
  finally
    Tree.Free;
  end;

  { CSV: a table is an array of flat objects. }
  Rows := TDynamicArray.Create;
  try
    Rows.AddObject.Append('id', 1).Append('name', 'one');
    Rows.AddObject.Append('id', 2).Append('name', 'two');
    Csv := TCsvSerializer.FromDynamic(Rows);
    Note(StringReplace(Csv, sLineBreak, ' | ', [rfReplaceAll]));
    Back := TCsvSerializer.ToDynamic(Csv);
    try
      Check((Back.Kind = TDynamicKind.Arr) and (Back.Count = 2) and
        (Back[1].Find('name').AsStr = 'two'), 'DYNAMIC_CSV_ROUND_TRIP');
    finally
      Back.Free;
    end;
  finally
    Rows.Free;
  end;

  { A document that repeats a member name is refused: an object holds a name
    once, and keeping either occurrence would be a silent choice. }
  Check(Refused(procedure begin TJsonSerializer.ToDynamic('{"a":1,"a":2}').Free end),
    'DYNAMIC_SOURCE_DUPLICATE_NAME_REFUSED');
end;

procedure TestNativeValues;
var
  Tree, Back: TDynamicValue;
  Obj: TDynamicObject;
  Bytes: TBytes;
begin
  Writeln;
  Writeln('--- format-native values stay native ---');
  Obj := TDynamicObject.Create;
  try
    Obj.Append('_id', TDynamicValue.NewExtended(TDynamicTag.ObjectId,
      TDynamicValue.NewStr('5f1d7f3e2b9c4a0012345678')));
    Obj.Append('big', TDynamicValue.NewUInt(High(UInt64)));
    Obj.Append('when', TDynamicValue.NewDateTime(EncodeDateTime(2026, 1, 2, 3, 4, 5, 0)));
    Obj.Append('blob', TDynamicValue.NewBytes(TBytes.Create(9, 8)));
    Bytes := TBsonSerializer.FromDynamic(Obj);
    Back := TBsonSerializer.ToDynamic(Bytes);
    try
      Check(Back.Find('_id').IsTagged(TDynamicTag.ObjectId) and
        (Back.Find('blob').Kind = TDynamicKind.Bytes) and
        (Back.Find('when').Kind = TDynamicKind.DateTime),
        'DYNAMIC_BSON_NATIVE_VALUES');
    finally
      Back.Free;
    end;
    Bytes := TCborSerializer.FromDynamic(Obj);
    Back := TCborSerializer.ToDynamic(Bytes);
    try
      Check((Back.Find('big').Kind = TDynamicKind.UInt) and
        (Back.Find('big').AsUInt = High(UInt64)) and
        (Back.Find('blob').Kind = TDynamicKind.Bytes),
        'DYNAMIC_CBOR_NATIVE_VALUES');
    finally
      Back.Free;
    end;
  finally
    Obj.Free;
  end;
  { A CBOR semantic tag nobody interprets survives, tag and all. }
  Tree := TDynamicValue.NewExtended(TDynamicTag.CborTag, nil);
  Tree.Free;
  Obj := TDynamicObject.Create;
  try
    Obj.Append('number', 99999).Append('value', 'payload');
    Tree := TDynamicValue.NewExtended(TDynamicTag.CborTag, Obj.Clone);
    try
      Back := TCborSerializer.ToDynamic(TCborSerializer.FromDynamic(Tree));
      try
        Check(Back.IsTagged(TDynamicTag.CborTag) and Back.Equals(Tree),
          'DYNAMIC_CBOR_UNKNOWN_TAG_SURVIVES');
      finally
        Back.Free;
      end;
    finally
      Tree.Free;
    end;
  finally
    Obj.Free;
  end;
end;

procedure TestSchemaFormats;
const
  AVRO_SCHEMA = '{"type":"record","name":"Person","fields":[' +
    '{"name":"name","type":"string"},{"name":"age","type":"int"}]}';
  ASN1_MODULE =
    { Untagged components: an implicitly tagged primitive reads back as its
      raw octets structurally - a documented limitation. }
    'People DEFINITIONS ::= BEGIN ' +
    '  Person ::= SEQUENCE { name UTF8String, age INTEGER } ' +
    'END';
var
  Tree: TDynamicObject;
  Back: TDynamicValue;
  Avro: TAvroSchema;
  Asn1: TAsn1Schema;
  Proto: TProtobufSchema;
  Bytes, Official: TBytes;
  Dir: string;
  Caught: Boolean;
begin
  Writeln;
  Writeln('--- schema-driven formats need their schemas ---');
  Tree := TDynamicObject.Create;
  try
    Tree.Append('name', 'Erin').Append('age', 35);

    Avro := TAvroSchema.Parse(AVRO_SCHEMA);
    try
      Bytes := TAvroSerializer.FromDynamic(Tree, Avro);
      Back := TAvroSerializer.ToDynamic(Bytes, Avro);
      try
        Check(Tree.Equals(Back), 'DYNAMIC_AVRO_WITH_SCHEMA');
      finally
        Back.Free;
      end;
    finally
      Avro.Free;
    end;

    Asn1 := TAsn1Schema.ParseModule(ASN1_MODULE);
    try
      Bytes := TAsn1Serializer.FromDynamic(Tree, Asn1, 'Person');
      Back := TAsn1Serializer.ToDynamic(Bytes, Asn1, 'Person');
      try
        Check((Back.Find('name').AsStr = 'Erin') and (Back.Find('age').AsInt = 35),
          'DYNAMIC_ASN1_WITH_SCHEMA');
        if Back.Find('age') = nil then Note(Back.Describe)
        else if Back.Find('age').AsInt <> 35 then Note(Back.Describe);
      finally
        Back.Free;
      end;
    finally
      Asn1.Free;
    end;

    { No schema, no guess. }
    Caught := False;
    try
      TSerialization.FromDynamic(Tree, TSerializationFormat.Avro);
    except
      on E: ESerializationSchemaRequired do Caught := True;
    end;
    Check(Caught, 'DYNAMIC_SCHEMA_REQUIRED_IS_REFUSED');
  finally
    Tree.Free;
  end;

  { Protobuf, against protoc's own descriptor and encoding. }
  Dir := TPath.GetFullPath(TPath.Combine(ExtractFilePath(ParamStr(0)),
    '..\..\..\tests\fixtures\protobuf\reference'));
  if not TDirectory.Exists(Dir) then
    Dir := TPath.Combine(GetCurrentDir, 'tests\fixtures\protobuf\reference');
  Proto := TProtobufSchema.LoadDescriptorSet(
    TFile.ReadAllBytes(TPath.Combine(Dir, 'ref-probe.desc')));
  try
    Official := TFile.ReadAllBytes(TPath.Combine(Dir, 'ref-probe-message.bin'));
    Back := Proto.ToDynamic(Official, 'pfprobe.Probe');
    try
      Bytes := Proto.FromDynamic(Back, 'pfprobe.Probe');
      Tree := Proto.ToDynamic(Bytes, 'pfprobe.Probe').AsObject;
      try
        Check((Back.Find('reference') <> nil) and Back.Equals(Tree),
          'DYNAMIC_PROTOBUF_WITH_DESCRIPTOR');
      finally
        Tree.Free;
      end;
    finally
      Back.Free;
    end;
  finally
    Proto.Free;
  end;
end;

procedure TestRuntimeFormat;
var
  Tree, Back: TDynamicValue;
  Payload: TSerializationPayload;
begin
  Writeln;
  Writeln('--- TSerialization: the format chosen at run time ---');
  Tree := SampleTree;
  try
    Payload := TSerialization.FromDynamic(Tree, TSerializationFormat.Bson);
    Back := TSerialization.ToDynamic(Payload, TSerializationFormat.Bson);
    try
      Check(Tree.Equals(Back), 'DYNAMIC_RUNTIME_BSON_ROUND_TRIP');
      Payload := TSerialization.FromDynamic(Back, TSerializationFormat.Xml);
      Check(Pos('<city>Uptown</city>', Payload.AsText) > 0,
        'DYNAMIC_RUNTIME_BSON_TO_XML');
    finally
      Back.Free;
    end;
  finally
    Tree.Free;
  end;
end;

{ =========================================================================
  DATASETS
  ========================================================================= }

function NewOrders: TFDMemTable;
var
  Rows: TArray<TOrderRow>;
  I: Integer;
begin
  SetLength(Rows, 2);
  for I := 0 to 1 do
  begin
    Rows[I] := TOrderRow.Create;
    Rows[I].Id := I + 1;
    Rows[I].Customer := 'c' + IntToStr(I + 1);
    Rows[I].Total := 10.25 * (I + 1);
    Rows[I].Internal := 'x';
  end;
  try
    Result := TDataSetSerializer.CreateFDMemTable<TOrderRow>(Rows);
  finally
    for I := 0 to 1 do Rows[I].Free;
  end;
end;

procedure TestDataSet;
var
  Source, Target: TFDMemTable;
  Tree: TDynamicValue;
  Arr: TDynamicArray;
  Obj: TDynamicObject;
  Caught: Boolean;
begin
  Writeln;
  Writeln('--- DataSet to and from Dynamic ---');
  Source := NewOrders;
  try
    { The contract decided the columns: general names, the DataSet name
      beating the general one, the ignored member absent. }
    Check((Source.FindField('order_id') <> nil) and
      (Source.FindField('TOTAL') <> nil) and
      (Source.FindField('total_general') = nil) and
      (Source.FindField('Internal') = nil), 'DYNAMIC_DATASET_CONTRACT_COLUMNS');

    Tree := TDataSetSerializer.ToDynamic(Source);
    try
      Check((Tree.Find('fields') <> nil) and (Tree.Find('rows').Count = 2),
        'DYNAMIC_DATASET_TO_DYNAMIC');
      Target := TFDMemTable.Create(nil);
      try
        TDataSetSerializer.FromDynamic(Tree, Target, TDataSetSourceMode.Auto);
        Target.Last;
        Check((Target.RecordCount = 2) and
          (Target.FieldByName('TOTAL').DataType = ftCurrency) and
          (Target.FieldByName('TOTAL').AsCurrency = 20.5),
          'DYNAMIC_DATASET_STRUCTURE_AND_ROWS_ROUND_TRIP');
      finally
        Target.Free;
      end;
      { InferStructure: the same value read as plain data, on request. }
      Target := TFDMemTable.Create(nil);
      try
        TDataSetSerializer.FromDynamic(Tree, Target,
          TDataSetSourceMode.InferStructure);
        Check(Target.FindField('order_id') = nil,
          'DYNAMIC_DATASET_INTERPRETATION_IS_EXPLICIT');
      finally
        Target.Free;
      end;
    finally
      Tree.Free;
    end;

    Tree := TDataSetSerializer.ToDynamic(Source, TDataSetSerializationPolicy.RowsOnly);
    try
      Target := TFDMemTable.Create(nil);
      try
        TDataSetSerializer.CreateStructure<TOrderRow>(Target);
        TDataSetSerializer.FromDynamic(Tree, Target,
          TDataSetSerializationPolicy.RowsOnly);
        Check((Tree.Kind = TDynamicKind.Arr) and (Target.RecordCount = 2),
          'DYNAMIC_DATASET_ROWS_ONLY');
      finally
        Target.Free;
      end;
    finally
      Tree.Free;
    end;

    Source.CachedUpdates := True;
    Source.CommitUpdates;
    Source.First;
    Source.Edit;
    Source.FieldByName('Customer').AsString := 'changed';
    Source.Post;
    Tree := TDataSetSerializer.ToDynamic(Source,
      TDataSetSerializationPolicy.DeltaAndStructure);
    try
      Target := TFDMemTable.Create(nil);
      try
        TDataSetSerializer.FromDynamic(Tree, Target, TDataSetSourceMode.Auto);
        Target.First;
        Check((Target.RecordCount = 1) and
          (Target.FieldByName('Customer').AsString = 'changed'),
          'DYNAMIC_DATASET_DELTA_REPLAYS');
      finally
        Target.Free;
      end;
    finally
      Tree.Free;
    end;
  finally
    Source.Free;
  end;

  { Contract-aware: TOrderRow decides the columns of a hand-built value. }
  Arr := TDynamicArray.Create;
  try
    Arr.AddObject.Append('order_id', 7).Append('Customer', 'seven')
      .Append('total_general', TDynamicValue.NewDecimal('1.5'));
    Arr.AddObject.Append('order_id', 8).Append('Customer', 'eight');
    Target := TFDMemTable.Create(nil);
    try
      TDataSetSerializer.FromDynamic<TOrderRow>(Arr, Target);
      Target.First;
      Check((Target.RecordCount = 2) and
        (Target.FieldByName('order_id').AsInteger = 7) and
        (Target.FieldByName('TOTAL').AsCurrency = 1.5),
        'DYNAMIC_DATASET_FROM_DYNAMIC_WITH_CONTRACT');
    finally
      Target.Free;
    end;
  finally
    Arr.Free;
  end;

  { Contract-free, inferred. }
  Arr := TDynamicArray.Create;
  try
    Arr.AddObject.Append('a', 1).Append('b', 'x');
    Target := TFDMemTable.Create(nil);
    try
      TDataSetSerializer.FromDynamic(Arr, Target, TDataSetSourceMode.Auto);
      Check((Target.RecordCount = 1) and (Target.FieldByName('b').AsString = 'x'),
        'DYNAMIC_DATASET_FROM_DYNAMIC_INFERRED');
    finally
      Target.Free;
    end;
    { A decimal (CBOR's decimal fraction, a Currency member) in an inferred
      float column is its value, not zero; an unsigned value above Int64 is
      its exact digits, not a negative Largeint. }
    Arr.AddObject.Append('a', TDynamicValue.NewDecimal('1235.5600'))
      .Append('b', TDynamicValue.NewUInt(High(UInt64)));
    Target := TFDMemTable.Create(nil);
    try
      TDataSetSerializer.FromDynamic(Arr, Target, TDataSetSourceMode.InferStructure);
      Target.Last;
      Check((Target.FieldByName('a').DataType = ftFloat) and
        SameValue(Target.FieldByName('a').AsFloat, 1235.56) and
        (Target.FieldByName('b').AsString = '18446744073709551615'),
        'DYNAMIC_DATASET_INFERRED_DECIMAL_AND_UNSIGNED');
      Target.First;
      Check(Target.FieldByName('a').AsFloat = 1, 'DYNAMIC_DATASET_INFERRED_INT_IN_FLOAT_COLUMN');
    finally
      Target.Free;
    end;
    { EmbeddedStructure refuses a value that does not describe a table. }
    Target := TFDMemTable.Create(nil);
    try
      Caught := False;
      try
        TDataSetSerializer.FromDynamic(Arr, Target,
          TDataSetSourceMode.EmbeddedStructure);
      except
        on E: EDataSetSerializationError do Caught := True;
      end;
      Check(Caught, 'DYNAMIC_DATASET_EMBEDDED_REQUIRES_A_SCHEMA');
    finally
      Target.Free;
    end;
  finally
    Arr.Free;
  end;

  { An object that merely HAS "fields" and "rows" is data under
    InferStructure. }
  Obj := TDynamicObject.Create;
  try
    Obj.AddArray('fields').AddObject.Append('name', 'n').Append('type', 'String');
    Obj.AddArray('rows');
    Target := TFDMemTable.Create(nil);
    try
      TDataSetSerializer.FromDynamic(Obj, Target,
        TDataSetSourceMode.InferStructure);
      Check(Target.FindField('n') = nil, 'DYNAMIC_DATASET_NO_SHAPE_GUESSING');
    finally
      Target.Free;
    end;
  finally
    Obj.Free;
  end;
end;

{ =========================================================================
  SHARED METADATA
  ========================================================================= }

procedure TestMetadataReuse;
var
  F: TFreshForMetadata;
  Before, AfterFirst: Integer;
  V: TDynamicValue;
begin
  Writeln;
  Writeln('--- one RTTI discovery per type, whichever engine asks ---');
  F := TFreshForMetadata.Create;
  try
    F.Alpha := 1;
    F.Beta := 'b';
    Before := TSerializationMetadata.BuiltCount;
    TJsonSerializer.Serialize<TFreshForMetadata>(F);
    AfterFirst := TSerializationMetadata.BuiltCount;
    TBsonSerializer.Serialize<TFreshForMetadata>(F);
    TXmlSerializer.Serialize<TFreshForMetadata>(F);
    TCborSerializer.Serialize<TFreshForMetadata>(F);
    TMessagePackSerializer.Serialize<TFreshForMetadata>(F);
    TYamlSerializer.Serialize<TFreshForMetadata>(F);
    V := TDynamicSerializer.Serialize<TFreshForMetadata>(F);
    V.Free;
    Check((AfterFirst > Before) and
      (TSerializationMetadata.BuiltCount = AfterFirst),
      'DYNAMIC_SHARED_METADATA_DISCOVERED_ONCE');
    Note(Format('metadata built: %d before, %d after the first engine, %d ' +
      'after seven', [Before, AfterFirst, TSerializationMetadata.BuiltCount]));
  finally
    F.Free;
  end;
end;

{ =========================================================================
  PUBLICATION HARDENING
  ========================================================================= }

{ Every scalar accessor reads its own kind, and the documented compatible
  readings only; anything else is refused, never a zero or another kind's
  storage reinterpreted. }
procedure TestAccessorSafety;
var
  Values: array[0..11] of TDynamicValue;
  Names: array[0..11] of string;
  I: Integer;
  Bad: string;

  function Reads(AValue: TDynamicValue; const AAccessor: string): Boolean;
  begin
    Result := True;
    try
      if AAccessor = 'AsBool' then AValue.AsBool
      else if AAccessor = 'AsInt' then AValue.AsInt
      else if AAccessor = 'AsUInt' then AValue.AsUInt
      else if AAccessor = 'AsFloat' then AValue.AsFloat
      else if AAccessor = 'AsDecimal' then AValue.AsDecimal
      else if AAccessor = 'AsStr' then AValue.AsStr
      else if AAccessor = 'AsBytes' then AValue.AsBytes
      else if AAccessor = 'AsDateTime' then AValue.AsDateTime
      else if AAccessor = 'AsObject' then AValue.AsObject
      else if AAccessor = 'AsArray' then AValue.AsArray;
    except
      on E: EDynamicError do Result := False;
    end;
  end;

  { AExpected lists, by index into Values, which ones the accessor reads. }
  procedure Expect(const AAccessor: string; const AExpected: array of Integer);
  var
    J, K: Integer;
    Should: Boolean;
  begin
    for J := 0 to High(Values) do
    begin
      Should := False;
      for K in AExpected do
        if K = J then Should := True;
      if Reads(Values[J], AAccessor) <> Should then
        Bad := Bad + Format(' %s(%s)', [AAccessor, Names[J]]);
    end;
  end;

begin
  Writeln;
  Writeln('--- scalar accessors read their own kind only ---');
  Values[0] := TDynamicValue.NewNull;                     Names[0] := 'null';
  Values[1] := TDynamicValue.NewBool(True);               Names[1] := 'bool';
  Values[2] := TDynamicValue.NewInt(5);                   Names[2] := 'int';
  Values[3] := TDynamicValue.NewInt(-5);                  Names[3] := 'negint';
  Values[4] := TDynamicValue.NewUInt(High(UInt64));       Names[4] := 'uint';
  Values[5] := TDynamicValue.NewFloat(1.5);               Names[5] := 'float';
  Values[6] := TDynamicValue.NewDecimal('1.25');          Names[6] := 'decimal';
  Values[7] := TDynamicValue.NewStr('text');              Names[7] := 'str';
  Values[8] := TDynamicValue.NewBytes(TBytes.Create(1));  Names[8] := 'bytes';
  Values[9] := TDynamicValue.NewDate(Now);                Names[9] := 'date';
  Values[10] := TDynamicObject.Create;                    Names[10] := 'object';
  Values[11] := TDynamicArray.Create;                     Names[11] := 'array';
  try
    Bad := '';
    Expect('AsBool', [1]);
    Expect('AsInt', [2, 3]);
    Expect('AsUInt', [2, 4]);          { a non-negative Int, or a UInt }
    Expect('AsFloat', [5]);
    Expect('AsDecimal', [2, 3, 4, 6]); { exact numbers }
    Expect('AsStr', [7]);
    Expect('AsBytes', [8]);
    Expect('AsDateTime', [9]);
    Expect('AsObject', [10]);
    Expect('AsArray', [11]);
    Check(Bad = '', 'DYNAMIC_ACCESSORS_REFUSE_THE_WRONG_KIND');
    if Bad <> '' then Note('wrong:' + Bad);

    { Signed and unsigned are never each other's bits. }
    Check((Values[2].AsUInt = 5) and not Reads(Values[3], 'AsUInt') and
      not Reads(Values[4], 'AsInt') and (Values[4].AsUInt = High(UInt64)) and
      (Values[4].AsDecimal = '18446744073709551615'),
      'DYNAMIC_SIGNED_UNSIGNED_SAFETY');
  finally
    for I := 0 to High(Values) do Values[I].Free;
  end;
end;

procedure TestImmutableBytes;
var
  Source, Read: TBytes;
  V, C: TDynamicValue;
begin
  Writeln;
  Writeln('--- binary values are immutable ---');
  Source := TBytes.Create(1, 2, 3);
  V := TDynamicValue.NewBytes(Source);
  try
    Source[0] := 99;
    Check(V.AsBytes[0] = 1, 'DYNAMIC_BYTES_NOT_CHANGED_BY_THE_CALLERS_ARRAY');
    Read := V.AsBytes;
    Read[1] := 99;
    Check(V.AsBytes[1] = 2, 'DYNAMIC_BYTES_NOT_CHANGED_THROUGH_A_READ');
    C := V.Clone;
    try
      Check(V.Equals(C) and (C.AsBytes[2] = 3), 'DYNAMIC_BYTES_CLONE');
    finally
      C.Free;
    end;
  finally
    V.Free;
  end;
end;

procedure TestEnumContainers;
var
  E, Back: TEnumContainers;
  V: TDynamicValue;
  Ok: Boolean;
begin
  Writeln;
  Writeln('--- [SerializationEnum] through every container ---');
  E := TEnumContainers.Create;
  try
    E.Direct := InProgress;
    E.Maybe := Done;
    E.States := [Pending, InProgress];
    E.Arr := [Done, InProgress];
    E.Inner.State := InProgress;
    E.Items.Add(InProgress);
    E.ByState.Add(InProgress, Done);
    V := TDynamicSerializer.Serialize<TEnumContainers>(E);
    try
      Ok := (V.Find('Direct').AsStr = 'in-progress') and
        (V.Find('Maybe').AsStr = 'done') and
        (V.Find('States').Count = 2) and (V.Find('States')[1].AsStr = 'in-progress') and
        (V.Find('Arr')[1].AsStr = 'in-progress') and
        (V.Find('Inner').Find('State').AsStr = 'in-progress') and
        (V.Find('Items')[0].AsStr = 'in-progress') and
        (V.Find('ByState').Find('in-progress') <> nil) and
        (V.Find('ByState').Find('in-progress').AsStr = 'done');
      Check(Ok, 'DYNAMIC_ENUM_MAPPING_IN_EVERY_CONTAINER');
      if not Ok then Note(V.Describe);
      Back := TDynamicSerializer.Deserialize<TEnumContainers>(V);
      try
        Check((Back.Direct = InProgress) and (Back.Maybe.Value = Done) and
          (Back.States = [Pending, InProgress]) and (Back.Arr[1] = InProgress) and
          (Back.Inner.State = InProgress) and (Back.Items[0] = InProgress) and
          (Back.ByState[InProgress] = Done), 'DYNAMIC_ENUM_MAPPING_CONTAINERS_READ_BACK');
      finally
        Back.Free;
      end;
      { A mapped enumeration reads its mapped text only. }
      V.Find('States').AsArray.ReplaceAt(1, TDynamicValue.NewStr('InProgress'));
      Check(Refused(procedure begin TDynamicSerializer.Deserialize<TEnumContainers>(V).Free end),
        'DYNAMIC_ENUM_MAPPED_SET_REFUSES_THE_DELPHI_NAME');
    finally
      V.Free;
    end;
  finally
    E.Free;
  end;
end;

procedure TestAmbiguousMembers;
var
  Obj: TDynamicObject;
  P: TPerson;
  Msg: string;
begin
  Writeln;
  Writeln('--- case-insensitive member matching ---');
  Obj := TDynamicObject.Create;
  try
    { Exact wins, whatever else is there. }
    Obj.Append('Name', 'exact').Append('name', 'lower').Append('NAME', 'upper');
    P := TDynamicSerializer.Deserialize<TPerson>(Obj);
    try
      Check(P.Name = 'exact', 'DYNAMIC_MATCH_EXACT_WINS');
    finally
      P.Free;
    end;
    { Two candidates and no exact one: refused, naming both and the path. }
    Obj.Remove('Name');
    Msg := '';
    try
      TDynamicSerializer.Deserialize<TPerson>(Obj).Free;
    except
      on E: EDynamicError do Msg := E.Message;
    end;
    Check(ContainsStr(Msg, '"name"') and ContainsStr(Msg, '"NAME"') and
      ContainsStr(Msg, '$') and ContainsStr(Msg, 'ambiguous'),
      'DYNAMIC_MATCH_AMBIGUOUS_REFUSED');
    if Msg <> '' then Note(Msg);
    { One candidate: the established fallback. }
    Obj.Remove('NAME');
    P := TDynamicSerializer.Deserialize<TPerson>(Obj);
    try
      Check(P.Name = 'lower', 'DYNAMIC_MATCH_UNIQUE_FALLBACK');
    finally
      P.Free;
    end;
  finally
    Obj.Free;
  end;
end;

procedure TestDepthLimit;
var
  Root, Cur: TDynamicObject;
  Arr, Inner: TDynamicArray;
  N: TNode;
  H: TVariantHolder;
  I: Integer;
  Outcome: string;

  function Chain(ADepth: Integer): TDynamicObject;
  var
    J: Integer;
    C: TDynamicObject;
  begin
    Result := TDynamicObject.Create;
    C := Result;
    for J := 1 to ADepth do
    begin
      C.Append('Value', J);
      C := C.AddObject('Next');
    end;
  end;

  function Read(AValue: TDynamicValue; ATypeInfo: PTypeInfo): string;
  var
    Back: TValue;
  begin
    try
      Back := TDynamicSerializer.Deserialize(AValue, ATypeInfo);
      if Back.IsObject then Back.AsObject.Free;
      Result := 'read';
    except
      on E: ESerializationLimitExceeded do Result := 'limit';
      on E: Exception do Result := E.ClassName + ': ' + E.Message;
    end;
  end;

begin
  Writeln;
  Writeln('--- Dynamic -> Delphi nests no deeper than every writer ---');
  Root := Chain(20);
  try
    Check(Read(Root, TypeInfo(TNode)) = 'read', 'DYNAMIC_DEPTH_NESTED_OBJECTS_BELOW_LIMIT');
  finally
    Root.Free;
  end;
  Root := Chain(SERIALIZATION_MAX_GRAPH_DEPTH + 10);
  try
    Outcome := Read(Root, TypeInfo(TNode));
    Check(Outcome = 'limit', 'DYNAMIC_DEPTH_NESTED_OBJECTS_REFUSED');
    if Outcome <> 'limit' then Note(Outcome);
  finally
    Root.Free;
  end;

  { Arrays, through a Variant member: nested Variant arrays. }
  Root := TDynamicObject.Create;
  try
    Arr := Root.AddArray('V');
    for I := 1 to SERIALIZATION_MAX_GRAPH_DEPTH + 10 do
    begin
      Inner := Arr.AddArray;
      Arr := Inner;
    end;
    Arr.Append(1);
    Outcome := Read(Root, TypeInfo(TVariantHolder));
    Check(Outcome = 'limit', 'DYNAMIC_DEPTH_NESTED_ARRAYS_REFUSED');
    if Outcome <> 'limit' then Note(Outcome);
  finally
    Root.Free;
  end;
  Root := TDynamicObject.Create;
  try
    Arr := Root.AddArray('V');
    Arr.AddArray.AddArray.Append(1);
    Check(Read(Root, TypeInfo(TVariantHolder)) = 'read',
      'DYNAMIC_DEPTH_NESTED_ARRAYS_BELOW_LIMIT');
  finally
    Root.Free;
  end;

  { Mixed: objects inside arrays inside objects. }
  Root := TDynamicObject.Create;
  try
    Cur := Root;
    for I := 1 to SERIALIZATION_MAX_GRAPH_DEPTH do
      Cur := Cur.AddArray('Children').AddObject;
    Outcome := Read(Root, TypeInfo(TNode));
    Check(Outcome = 'limit', 'DYNAMIC_DEPTH_MIXED_NESTING_REFUSED');
    if Outcome <> 'limit' then Note(Outcome);
  finally
    Root.Free;
  end;

  { The level is restored after a refusal: an ordinary read still works. }
  Root := Chain(3);
  try
    Check(Read(Root, TypeInfo(TNode)) = 'read', 'DYNAMIC_DEPTH_RESTORED_AFTER_REFUSAL');
  finally
    Root.Free;
  end;
  N := nil;
  H := nil;
  N.Free;
  H.Free;
end;

procedure TestMetadataCache;
var
  A, B: TObject;
begin
  Writeln;
  Writeln('--- the shared metadata cache, now internal ---');
  A := TSerializationMetadata.Get(TypeInfo(TPerson));
  B := TSerializationMetadata.Get(TypeInfo(TPerson));
  Check((A = B) and (TSerializationMetadata.Get(TypeInfo(TPerson)).Members <> nil),
    'DYNAMIC_SHARED_METADATA_ONE_INSTANCE_PER_TYPE');
end;

begin
  try
    TestScalars;
    TestObjectBasics;
    TestOwnership;
    TestArrays;
    TestCloneEquality;
    TestMerge;
    TestProjection;
    TestEveryKind;
    TestGeneralAttributes;
    TestFormats;
    TestNativeValues;
    TestSchemaFormats;
    TestRuntimeFormat;
    TestDataSet;
    TestMetadataReuse;
    TestAccessorSafety;
    TestImmutableBytes;
    TestEnumContainers;
    TestAmbiguousMembers;
    TestDepthLimit;
    TestMetadataCache;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then
    Writeln('DYNAMIC: PASS')
  else
  begin
    Writeln('DYNAMIC: FAIL');
    ExitCode := 1;
  end;
end.
