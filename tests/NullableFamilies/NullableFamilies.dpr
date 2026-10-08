program NullableFamilies;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Nullable families: one registry, shared by every format.

  A nullable is a record holding a value and a "has value" flag. The library
  knows its own, and learns about anyone else's from a single registration
  that names the GENERIC FAMILY, not a specialization:

      TSerialization.RegisterNullableFamily<TMaybe<Integer>>;

  From that point TMaybe<string>, TMaybe<TDateTime> and every other
  specialization - including ones written later - are nullables too. The
  Integer specialization contributed only the base name, the arity and the
  field layout; nothing about its own offsets is kept.

  What this program checks:
    * the library's own TNullable<T> needs no registration;
    * a foreign family with the usual field names registers with one line;
    * a foreign family with different field names registers with a layout;
    * every specialization of a registered family is recognized, and each one
      resolves its OWN offsets - which differ, so a shared offset table would
      be silently wrong;
    * registrations that cannot be honoured are refused loudly, including the
      one case RTTI genuinely cannot disambiguate;
    * and the whole thing round-trips through JSON and reaches the DataSet
      projection through the same shared table. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.TypInfo, System.DateUtils, System.StrUtils,
  Data.DB, FireDAC.Comp.Client,
  { RivalNullables comes first because it declares a TMaybe<T> of its own, and
    an unqualified TMaybe resolves to the LAST unit that declares it. }
  RivalNullables in 'RivalNullables.pas',
  ForeignNullables in 'ForeignNullables.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
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

{ True when ABody raised ENullableFamilyError; the message is reported so a
  wrong-but-raising registration cannot pass unnoticed. }
function Refuses(const AWhat: string; ABody: TProc): Boolean;
begin
  Result := False;
  try
    ABody();
    Note(AWhat + ' -> accepted (should have been refused)');
  except
    on E: ENullableFamilyError do
    begin
      Result := True;
      Note(AWhat + ' -> ' + E.Message);
    end;
    on E: Exception do
      Note(AWhat + ' -> wrong exception ' + E.ClassName + ': ' + E.Message);
  end;
end;

type
  { One DTO over two foreign families at once. }
  TForeignDto = class
  public
    Id: Integer;
    Name: TMaybe<string>;
    Amount: TMaybe<Currency>;
    Due: TMaybe<TDateTime>;
    Note: TOptional<string>;
    Count: TOptional<Integer>;
  end;

  { The library's own nullable, for the "no registration needed" case. }
  THomeDto = class
  public
    Id: Integer;
    Name: TNullable<string>;
    Amount: TNullable<Currency>;
  end;

{ ------------------------------------------------------ before anything --- }

{ Must run before any registration: an unregistered foreign family is not a
  nullable, however familiar its shape looks. }
procedure TestUnregisteredIsNotNullable;
begin
  Writeln('-- before registration --');
  Check(not TSerialization.IsNullableType(TypeInfo(TMaybe<Integer>)),
    'FOREIGN_NULLABLE_UNREGISTERED_NOT_RECOGNIZED');
  Check(not TSerialization.IsNullableType(TypeInfo(TOptional<Integer>)),
    'FOREIGN_NULLABLE_UNREGISTERED_CUSTOM_NOT_RECOGNIZED');
  Note('TMaybe<T> has FValue/FHasValue exactly like TNullable<T> and is still');
  Note('not a nullable: identity is the declaring family, not the shape.');
end;

{ --------------------------------------------------------- the library's --- }

procedure TestPascalForgeNullableIsAutomatic;
var
  Access: TNullableAccess;
  Families: TArray<string>;
  S: string;
  Found: Boolean;
begin
  Writeln('-- the library''s own nullable --');
  Check(TSerializationTypes.TryGetNullableAccess(
    TypeInfo(TNullable<Integer>), Access) and
    (Access.ValueType = TypeInfo(Integer)),
    'PASCALFORGE_NULLABLE_AUTO');

  { Not a special case in the engines - a row in the same table. }
  Found := False;
  Families := TSerialization.RegisteredNullableFamilies;
  for S in Families do
    if ContainsText(S, 'TNullable<1>') then Found := True;
  Check(Found, 'PASCALFORGE_NULLABLE_IS_A_REGISTERED_FAMILY');
  for S in Families do Note('family: ' + S);

  { A specialization the library never mentions anywhere. }
  Check(TSerializationTypes.TryGetNullableAccess(
    TypeInfo(TNullable<TGUID>), Access) and (Access.ValueType = TypeInfo(TGUID)),
    'PASCALFORGE_NULLABLE_AUTO_ANY_SPECIALIZATION');
end;

{ ------------------------------------------------------------ foreign --- }

procedure RegisterFamilies;
begin
  { One line each, naming any one specialization. Both must happen before a
    plan is built over either family: a type's plan is cached the first time
    it is used, and a registration after that would be a silent no-op. }
  TSerialization.RegisterNullableFamily<TMaybe<Integer>>;
  TSerialization.RegisterNullableFamily<TOptional<Integer>>(
    TNullableLayout.Fields('FPayload', 'FPresent'));
  { Carries both pairs of names; registered here with one of them so that
    TestInvalidRegistrations can try to register it again with the other. }
  TSerialization.RegisterNullableFamily<TDualNames<Integer>>;
end;

procedure TestForeignDefaultLayout;
var
  Access: TNullableAccess;
begin
  Writeln('-- a foreign family, default layout --');
  Check(TSerializationTypes.TryGetNullableAccess(
    TypeInfo(TMaybe<Integer>), Access) and (Access.ValueType = TypeInfo(Integer)),
    'FOREIGN_NULLABLE_DEFAULT_LAYOUT');
  Note('registered with: TSerialization.RegisterNullableFamily<TMaybe<Integer>>');
end;

procedure TestForeignCustomLayout;
var
  Access: TNullableAccess;
begin
  Writeln('-- a foreign family, custom layout --');
  Check(TSerializationTypes.TryGetNullableAccess(
    TypeInfo(TOptional<Integer>), Access) and (Access.ValueType = TypeInfo(Integer)),
    'FOREIGN_NULLABLE_CUSTOM_LAYOUT');
  Note('registered with: TNullableLayout.Fields(''FPayload'', ''FPresent'')');
end;

{ The reason offsets are NOT stored per family: they are not a property of the
  family. TMaybe<Byte> and TMaybe<Currency> put their flag in different
  places, and a table filled in from the representative would point at the
  wrong byte for every other specialization. }
procedure TestMultipleSpecializations;
var
  A1, A2, A3, A4, A5: TNullableAccess;
  AllResolved, TypesDistinct, OffsetsDiffer: Boolean;
begin
  Writeln('-- every specialization of a registered family --');
  AllResolved :=
    TSerializationTypes.TryGetNullableAccess(TypeInfo(TMaybe<Byte>), A1) and
    TSerializationTypes.TryGetNullableAccess(TypeInfo(TMaybe<string>), A2) and
    TSerializationTypes.TryGetNullableAccess(TypeInfo(TMaybe<Currency>), A3) and
    TSerializationTypes.TryGetNullableAccess(TypeInfo(TMaybe<TDateTime>), A4) and
    TSerializationTypes.TryGetNullableAccess(TypeInfo(TMaybe<TGUID>), A5);
  TypesDistinct :=
    (A1.ValueType = TypeInfo(Byte)) and
    (A2.ValueType = TypeInfo(string)) and
    (A3.ValueType = TypeInfo(Currency)) and
    (A4.ValueType = TypeInfo(TDateTime)) and
    (A5.ValueType = TypeInfo(TGUID));
  { Only TMaybe<Integer> was ever named in a registration. }
  Check(AllResolved and TypesDistinct,
    'FOREIGN_NULLABLE_MULTIPLE_SPECIALIZATIONS');

  OffsetsDiffer := (A1.HasValueOffset <> A3.HasValueOffset) or
                   (A1.HasValueOffset <> A5.HasValueOffset);
  Check(OffsetsDiffer, 'FOREIGN_NULLABLE_PER_SPECIALIZATION_OFFSETS');
  Note(Format('TMaybe<Byte> flag at %d, TMaybe<Currency> at %d, TMaybe<TGUID> at %d',
    [A1.HasValueOffset, A3.HasValueOffset, A5.HasValueOffset]));
end;

{ ------------------------------------------------------- bad registration --- }

procedure TestInvalidRegistrations;
var
  Refused: Integer;
begin
  Writeln('-- registrations that cannot be honoured --');
  Refused := 0;

  if Refuses('a non-record (Integer)',
    procedure begin TSerialization.RegisterNullableFamily<Integer>; end)
    then Inc(Refused);

  if Refuses('a class, not a record (TObject)',
    procedure begin TSerialization.RegisterNullableFamily<TObject>; end)
    then Inc(Refused);

  if Refuses('a record that is not generic (TFixedMaybe)',
    procedure begin TSerialization.RegisterNullableFamily<TFixedMaybe>; end)
    then Inc(Refused);

  if Refuses('no has-value field (TBox<Integer>)',
    procedure begin TSerialization.RegisterNullableFamily<TBox<Integer>>; end)
    then Inc(Refused);

  if Refuses('a flag that is not a one-byte Boolean (TWideFlag<Integer>)',
    procedure begin TSerialization.RegisterNullableFamily<TWideFlag<Integer>>; end)
    then Inc(Refused);

  if Refuses('a layout naming fields that do not exist',
    procedure begin TSerialization.RegisterNullableFamily<TMaybe<Integer>>(
      TNullableLayout.Fields('FNope', 'FAlsoNope')); end)
    then Inc(Refused);

  if Refuses('an incomplete layout',
    procedure begin TSerialization.RegisterNullableFamily<TMaybe<Integer>>(
      TNullableLayout.Fields('FValue', '')); end)
    then Inc(Refused);

  { Already registered with FValue/FHasValue. Accepting a second, different
    layout would make behaviour depend on unit initialization order. }
  if Refuses('the same family again with a different layout',
    procedure begin TSerialization.RegisterNullableFamily<TMaybe<Integer>>(
      TNullableLayout.Fields('FPayload', 'FPresent')); end)
    then Inc(Refused);

  Check(Refused = 8, 'INVALID_NULLABLE_REGISTRATION');

  { Everything above was refused before the registry was even consulted. The
    two cases below reach the collision check itself, because both layouts
    genuinely resolve. }
  Check(Refuses('a family already registered with a different layout',
    procedure begin TSerialization.RegisterNullableFamily<TDualNames<Integer>>(
      TNullableLayout.Fields('FPayload', 'FPresent')); end),
    'NULLABLE_FAMILY_LAYOUT_CONFLICT_REFUSED');

  { Two libraries, two unrelated TMaybe<T>, indistinguishable to RTTI. The
    registry refuses rather than silently applying one library's field names
    to the other library's records. }
  Check(Refuses('a rival TMaybe<T> from another unit',
    procedure begin TSerialization.RegisterNullableFamily<RivalNullables.TMaybe<Integer>>(
      TNullableLayout.Fields('FItem', 'FLoaded')); end),
    'AMBIGUOUS_NULLABLE_FAMILY_REFUSED');

  { The idempotent case is not an error: two units may both register the same
    family the same way, and neither can know about the other. }
  Check(not Refuses('the same family again with the SAME layout',
    procedure begin TSerialization.RegisterNullableFamily<TMaybe<Integer>>; end),
    'DUPLICATE_NULLABLE_REGISTRATION_IS_A_NO_OP');

  { A refused registration must leave nothing behind. }
  Check(not TSerialization.IsNullableType(TypeInfo(TBox<Integer>)),
    'REFUSED_NULLABLE_REGISTRATION_LEAVES_NOTHING');
  Check(not TSerialization.IsNullableType(TypeInfo(TWideFlag<Integer>)),
    'REFUSED_NULLABLE_WIDE_FLAG_LEAVES_NOTHING');
end;

{ ---------------------------------------------------------------- JSON --- }

function JsonOf(const AJson: string; const AKey: string): Boolean;
begin
  Result := ContainsText(AJson, '"' + AKey + '"');
end;

procedure TestJsonRoundtrip;
var
  Src, Back: TForeignDto;
  Home, HomeBack: THomeDto;
  Json, HomeJson: string;
  Due: TDateTime;
  Ok: Boolean;
begin
  Writeln('-- JSON --');
  Due := EncodeDateTime(2026, 3, 14, 9, 26, 53, 0);

  Src := TForeignDto.Create;
  try
    Src.Id := 7;
    Src.Name := TMaybe<string>.Some('Ada');
    Src.Amount := TMaybe<Currency>.None;          { omitted }
    Src.Due := TMaybe<TDateTime>.Some(Due);
    Src.Note := TOptional<string>.None;           { omitted }
    Src.Count := TOptional<Integer>.Some(42);
    Json := TJsonSerializer.Serialize(Src);
  finally
    Src.Free;
  end;
  Note(Json);

  Check(JsonOf(Json, 'name') and JsonOf(Json, 'due') and JsonOf(Json, 'count'),
    'FOREIGN_NULLABLE_PRESENT_VALUES_WRITTEN');
  { The same omission rule the library's own nullable gets: an empty nullable
    is absent, never "amount": null. }
  Check((not JsonOf(Json, 'amount')) and (not JsonOf(Json, 'note')),
    'FOREIGN_NULLABLE_EMPTY_IS_OMITTED');

  Back := TJsonSerializer.Deserialize<TForeignDto>(Json);
  try
    Ok := (Back.Id = 7) and
          Back.Name.HasValue and (Back.Name.Value = 'Ada') and
          (not Back.Amount.HasValue) and
          Back.Due.HasValue and SameDateTime(Back.Due.Value, Due) and
          (not Back.Note.IsPresent) and
          Back.Count.IsPresent and (Back.Count.Payload = 42);
    Check(Ok, 'NULLABLE_JSON_ROUNDTRIP');
  finally
    Back.Free;
  end;

  { The library's own family behaves identically, through the same table. }
  Home := THomeDto.Create;
  try
    Home.Id := 9;
    Home.Name := 'Grace';
    Home.Amount := nil;
    HomeJson := TJsonSerializer.Serialize(Home);
  finally
    Home.Free;
  end;
  Note(HomeJson);
  HomeBack := TJsonSerializer.Deserialize<THomeDto>(HomeJson);
  try
    Check((HomeBack.Id = 9) and HomeBack.Name.HasValue and
          (HomeBack.Name.Value = 'Grace') and (not HomeBack.Amount.HasValue) and
          (not JsonOf(HomeJson, 'amount')),
      'PASCALFORGE_NULLABLE_JSON_ROUNDTRIP');
  finally
    HomeBack.Free;
  end;
end;

{ ------------------------------------------------------------- DataSet --- }

{ The registry lives in the serialization core rather than in the JSON engine
  for exactly this reason: the DataSet projection has to agree about which
  records are nullables, and it does so by asking the same table. }
procedure TestDataSetProjection;
var
  Src: TForeignDto;
  DS: TFDMemTable;
begin
  Writeln('-- DataSet projection --');
  Src := TForeignDto.Create;
  try
    Src.Id := 7;
    Src.Name := TMaybe<string>.Some('Ada');
    Src.Amount := TMaybe<Currency>.None;
    Src.Due := TMaybe<TDateTime>.None;
    Src.Note := TOptional<string>.None;
    Src.Count := TOptional<Integer>.Some(42);
    DS := TDataSetSerializer.CreateFDMemTable<TForeignDto>(Src);
    try
      { A nullable projects as its INNER type - a nullable string is a string
        column - and an empty one as NULL. A record the engine did not
        recognize as a nullable would have become a nested structure or an
        error instead. }
      Check((DS.FieldByName('Name').DataType = ftWideString) and
            (DS.FieldByName('Count').DataType = ftInteger) and
            (DS.FieldByName('Due').DataType = ftDateTime),
        'FOREIGN_NULLABLE_DATASET_COLUMN_TYPES');
      Check((DS.RecordCount = 1) and
            (DS.FieldByName('Name').AsString = 'Ada') and
            (DS.FieldByName('Count').AsInteger = 42) and
            DS.FieldByName('Amount').IsNull and
            DS.FieldByName('Due').IsNull and
            DS.FieldByName('Note').IsNull,
        'NULLABLE_DATASET_PROJECTION');
    finally
      DS.Free;
    end;
  finally
    Src.Free;
  end;
end;

begin
  try
    TestUnregisteredIsNotNullable;
    Writeln;
    TestPascalForgeNullableIsAutomatic;
    Writeln;
    RegisterFamilies;
    TestForeignDefaultLayout;
    Writeln;
    TestForeignCustomLayout;
    Writeln;
    TestMultipleSpecializations;
    Writeln;
    TestInvalidRegistrations;
    Writeln;
    TestJsonRoundtrip;
    Writeln;
    TestDataSetProjection;
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
    Writeln('NULLABLE_FAMILIES: PASS')
  else
  begin
    Writeln('NULLABLE_FAMILIES: FAIL');
    ExitCode := 1;
  end;
end.
