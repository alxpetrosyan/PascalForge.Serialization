program FormatRegistry;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The format registry, and the isolation it exists to provide.

  The property being tested is unusual: it is about what is NOT linked. This
  program includes exactly one registration unit - JSON - and then asserts
  that every other format is absent, that asking for one raises a clear error
  naming the unit to include, and that nothing silently falls back.

  It also reads the library source and checks that no format implementation
  references another. That is the rule the whole design rests on, and it is
  the kind of rule that decays the moment someone adds one convenient uses
  entry. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.IOUtils, System.Types, System.Classes,
  System.Rtti, System.TypInfo,
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  { The only registration unit in this program. Linking it registers
    nothing; the explicit call at the top of the main block makes
    TSerializationFormat.Json resolvable, and the others' absence is the point. }
  PascalForge.Json.Registration in '..\..\src\PascalForge.Json.Registration.pas';

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

type
  TShipment = class
  public
    [JsonName('shipmentId')]
    Id: Int64;
    Amount: Currency;
  end;

{ ------------------------------------------------------- registration --- }

procedure TestRegistered;
begin
  Writeln('-- what is linked --');
  Check(TSerialization.IsRegistered(TSerializationFormat.Json), 'FORMAT_JSON_REGISTERED');
  Check(Length(TSerialization.RegisteredFormats) = 1,
    'FORMAT_ONLY_LINKED_ONES_REGISTERED');
  Note('registered: ' + TSerialization.FormatName(
    TSerialization.RegisteredFormats[0]));
end;

procedure TestUnregistered;

  procedure ExpectUnregistered(AFormat: TSerializationFormat; const AMarker: string);
  var
    Raised: Boolean;
    Message: string;
  begin
    Raised := False;
    Message := '';
    try
      TSerialization.Serialize<TShipment>(nil, AFormat);
    except
      on E: ESerializationFormatNotRegistered do
      begin
        Raised := True;
        Message := E.Message;
      end;
    end;
    { The error has to name the format AND the unit to include - an agent or
      a developer hitting this should not have to go looking. }
    Check(Raised and
          Message.ToUpper.Contains(TSerialization.FormatName(AFormat).ToUpper) and
          Message.Contains('Registration'), AMarker);
    if not Raised then Note('no exception for ' + TSerialization.FormatName(AFormat));
  end;

begin
  Writeln('-- what is not --');
  Check(not TSerialization.IsRegistered(TSerializationFormat.Xml), 'FORMAT_XML_NOT_LINKED');
  Check(not TSerialization.IsRegistered(TSerializationFormat.Bson), 'FORMAT_BSON_NOT_LINKED');

  ExpectUnregistered(TSerializationFormat.Protobuf, 'FORMAT_PROTOBUF_UNREGISTERED_ERROR');
  ExpectUnregistered(TSerializationFormat.Cbor, 'FORMAT_CBOR_UNREGISTERED_ERROR');
  ExpectUnregistered(TSerializationFormat.MessagePack, 'FORMAT_MESSAGEPACK_UNREGISTERED_ERROR');

  { Show one message in full: it is the developer-facing artifact here. }
  try
    TSerialization.Serialize<TShipment>(nil, TSerializationFormat.Protobuf);
  except
    on E: ESerializationFormatNotRegistered do
    begin
      Writeln;
      Writeln(E.Message);
      Writeln;
    end;
  end;
end;

type
  TOtherJsonHandler = class(TSerializationFormatHandler)
  public
    function PayloadKind: TSerializationPayloadKind; override;
    function ToDynamic(const APayload: TSerializationPayload;
      const AOptions: TStructuralConversionOptions): TDynamicValue; override;
    function FromDynamic(const AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions): TSerializationPayload; override;
    function DeserializeTyped(ATypeInfo: PTypeInfo;
      const APayload: TSerializationPayload): TValue; override;
    function SerializeTyped(ATypeInfo: PTypeInfo;
      const AValue: TValue): TSerializationPayload; override;
  end;

function TOtherJsonHandler.PayloadKind: TSerializationPayloadKind;
begin
  Result := TSerializationPayloadKind.Text;
end;

function TOtherJsonHandler.ToDynamic(const APayload: TSerializationPayload;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
begin
  Result := nil;
end;

function TOtherJsonHandler.FromDynamic(const AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
begin
  Result := TSerializationPayload.FromText('');
end;

function TOtherJsonHandler.DeserializeTyped(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload): TValue;
begin
  Result := TValue.Empty;
end;

function TOtherJsonHandler.SerializeTyped(ATypeInfo: PTypeInfo;
  const AValue: TValue): TSerializationPayload;
begin
  Result := TSerializationPayload.FromText('');
end;

procedure TestDuplicateRegistration;
var
  Raised: Boolean;
begin
  Writeln('-- registering twice --');

  { The same handler class again is a no-op: a unit can be reached through
    more than one path, and that must not be an error. }
  Raised := False;
  try
    TSerializationFormats.Register(TSerializationFormat.Json,
      TSerializationFormatHandlerClass(
        TSerializationFormats.Get(TSerializationFormat.Json).ClassType));
  except
    on E: Exception do Raised := True;
  end;
  Check(not Raised, 'DUPLICATE_FORMAT_REGISTRATION_SAME_HANDLER_OK');

  { A DIFFERENT handler is refused. Allowing it would make behaviour depend
    on unit initialization order, which nobody can reason about. }
  Raised := False;
  try
    TSerializationFormats.Register(TSerializationFormat.Json, TOtherJsonHandler);
  except
    on E: Exception do
    begin
      Raised := True;
      Note(E.Message);
    end;
  end;
  Check(Raised, 'DUPLICATE_FORMAT_REGISTRATION_REJECTED');

  Raised := False;
  try
    TSerializationFormats.Register(TSerializationFormat.Json, TOtherJsonHandler);
  except
    on E: ESerializationFormatConflict do Raised := True;
  end;
  Check(Raised, 'REGISTRATION_CONFLICT_IS_ITS_OWN_EXCEPTION');
end;

procedure TestJsonThroughTheFacade;
var
  Shipment: TShipment;
  Payload: TSerializationPayload;
  Back: TShipment;
begin
  Writeln('-- the general facade delegates, it does not reimplement --');
  Shipment := TShipment.Create;
  try
    Shipment.Id := 4211;
    Shipment.Amount := 19.99;
    Payload := TSerialization.Serialize<TShipment>(Shipment, TSerializationFormat.Json);
  finally
    Shipment.Free;
  end;
  Note(Payload.AsText);

  { Proof that it went through the JSON engine and not some generic path:
    the [JsonName] attribute was applied. }
  Check(Payload.Kind = TSerializationPayloadKind.Text, 'FORMAT_PAYLOAD_KIND_TEXT');
  Check(Payload.AsText.Contains('"shipmentId":4211'),
    'FORMAT_FACADE_USES_FORMAT_RULES');

  Back := TSerialization.Deserialize<TShipment>(Payload, TSerializationFormat.Json);
  try
    Check((Back.Id = 4211) and (Back.Amount = 19.99), 'FORMAT_FACADE_ROUNDTRIP');
  finally
    Back.Free;
  end;
end;

procedure TestPayloadKinds;
var
  T, B: TSerializationPayload;
  Raised: Boolean;
begin
  Writeln('-- text and bytes are not interchangeable --');
  T := TSerializationPayload.FromText('{}');
  B := TSerializationPayload.FromBytes(TBytes.Create(1, 2, 3));

  Check(T.Kind = TSerializationPayloadKind.Text, 'PAYLOAD_TEXT_KIND');
  Check(B.Kind = TSerializationPayloadKind.Binary, 'PAYLOAD_BINARY_KIND');

  { Reading a binary payload as text raises rather than guessing an encoding;
    a caller that means UTF-8 has to say so. }
  Raised := False;
  try
    B.AsText;
  except
    on E: Exception do Raised := True;
  end;
  Check(Raised, 'PAYLOAD_NO_IMPLICIT_DECODE');
  Check(Length(T.ToUtf8Bytes) = 2, 'PAYLOAD_EXPLICIT_ENCODE');
end;

{ ------------------------------------------- formats must not know of
                                               one another ------------- }

procedure TestFormatIsolationInSource;
var
  SrcDir: string;
  Offenders: TStringList;

  { A comment may name another format - the documentation is better for
    saying 'unlike PascalForge.Xml, this one...'. What must not exist is a
    compile-time dependency, so comments are stripped before looking. }
  function StripComments(const AText: string): string;
  var
    I, N: Integer;
    SB: TStringBuilder;
  begin
    SB := TStringBuilder.Create;
    try
      I := 1;
      N := Length(AText);
      while I <= N do
      begin
        if AText[I] = '{' then
        begin
          while (I <= N) and (AText[I] <> '}') do Inc(I);
          Inc(I);
        end
        else if (I < N) and (AText[I] = '(') and (AText[I + 1] = '*') then
        begin
          Inc(I, 2);
          while (I < N) and not ((AText[I] = '*') and (AText[I + 1] = ')')) do Inc(I);
          Inc(I, 2);
        end
        else if (I < N) and (AText[I] = '/') and (AText[I + 1] = '/') then
        begin
          while (I <= N) and not CharInSet(AText[I], [#10, #13]) do Inc(I);
        end
        else
        begin
          SB.Append(AText[I]);
          Inc(I);
        end;
      end;
      Result := SB.ToString;
    finally
      SB.Free;
    end;
  end;

  function UsesAnyOf(const AFile: string; const AUnits: array of string;
    out AFound: string): Boolean;
  var
    Code, U: string;
  begin
    Code := StripComments(TFile.ReadAllText(AFile));
    for U in AUnits do
      if Code.Contains(U) then
      begin
        AFound := U;
        Exit(True);
      end;
    AFound := '';
    Result := False;
  end;

  procedure MustNotReference(const AUnit: string; const AForbidden: array of string);
  var
    Path, Found: string;
  begin
    Path := TPath.Combine(SrcDir, AUnit + '.pas');
    if not TFile.Exists(Path) then Exit;   // format not implemented yet
    if UsesAnyOf(Path, AForbidden, Found) then
      Offenders.Add(AUnit + ' references ' + Found);
  end;

begin
  Writeln('-- no format knows about another --');
  SrcDir := TPath.GetFullPath(TPath.Combine(ExtractFilePath(ParamStr(0)),
    '..\..\..\src'));
  if not TDirectory.Exists(SrcDir) then
  begin
    Writeln('FORMAT_SOURCE_ISOLATION: FAIL');
    Note('cannot find src at ' + SrcDir);
    Inc(GFailures);
    Exit;
  end;

  Offenders := TStringList.Create;
  try
    { Core is the shared layer: it names TSerializationFormat members, never an
      implementation. }
    MustNotReference('PascalForge.Serialization.Core',
      ['PascalForge.Json', 'PascalForge.Xml', 'PascalForge.Bson']);

    { The general facade delegates through the registry; it must not reach a
      format directly either. }
    MustNotReference('PascalForge.Serialization',
      ['PascalForge.Json', 'PascalForge.Xml', 'PascalForge.Bson']);

    { And the formats are siblings. }
    MustNotReference('PascalForge.Json',          ['PascalForge.Xml', 'PascalForge.Bson']);
    MustNotReference('PascalForge.Json.Internal', ['PascalForge.Xml', 'PascalForge.Bson']);
    MustNotReference('PascalForge.Xml',           ['PascalForge.Json', 'PascalForge.Bson']);
    MustNotReference('PascalForge.Xml.Internal',  ['PascalForge.Json', 'PascalForge.Bson']);
    MustNotReference('PascalForge.Bson',          ['PascalForge.Json', 'PascalForge.Xml']);
    MustNotReference('PascalForge.Bson.Internal', ['PascalForge.Json', 'PascalForge.Xml']);

    if Offenders.Count > 0 then
      for var S in Offenders do Note(S);
    Check(Offenders.Count = 0, 'FORMAT_SOURCE_ISOLATION');

    { Registration is the application's decision: no unit of the library may
      register a format from its initialization section, where merely
      linking the unit - or loading its package - would do it. }
    Offenders.Clear;
    for var F in TDirectory.GetFiles(SrcDir, '*.pas') do
    begin
      var Code := StripComments(TFile.ReadAllText(F));
      var At := Pos(#10'initialization', Code);
      if At = 0 then Continue;
      var Section := Copy(Code, At, MaxInt);
      var Stop := Pos(#10'finalization', Section);
      if Stop > 0 then Section := Copy(Section, 1, Stop);
      if Section.Contains('TSerializationFormats.Register') or
         Section.Contains('RegisterFormat') or Section.Contains('RegisterAll') then
        Offenders.Add(ExtractFileName(F) + ' registers from initialization');
    end;
    if Offenders.Count > 0 then
      for var S in Offenders do Note(S);
    Check(Offenders.Count = 0, 'NO_REGISTRATION_INITIALIZATION_SIDE_EFFECTS');
  finally
    Offenders.Free;
  end;
end;

{ ===========================================================================
  NO ENGINE CLASSIFIES A CONTAINER FOR ITSELF

  Six engines used to answer "is this a list, is this a dictionary" with
  their own copy of the logic. They agreed until they did not: three of them
  ended up walking TObjectList's and TDictionary's OWN published members, and
  one reached an invalid pointer doing it.

  The answer lives in TSerializationTypes now. This reads the source and
  fails if an engine has grown its own again - the same shape of check as
  FORMAT_SOURCE_ISOLATION above, and for the same reason: a grep is the only
  thing that keeps a rule like this true a year later.
  =========================================================================== }

procedure TestSharedContainerAccess;
var
  SrcDir: string;
  Offenders, Users: TStringList;
  Path, Code, Unit_: string;

  { Every unit that has to know what a container is. DataSet projection is in
    the list because it projects one, and because it had its own copy too. }
  const ENGINES: array[0..10] of string = (
    'PascalForge.Json.Internal',
    'PascalForge.Xml.Internal',
    'PascalForge.Bson.Internal',
    'PascalForge.Protobuf.Internal',
    'PascalForge.Cbor.Internal',
    'PascalForge.MessagePack.Internal',
    'PascalForge.Yaml.Internal',
    'PascalForge.Csv.Internal',
    'PascalForge.Avro.Internal',
    'PascalForge.Asn1.Internal',
    'PascalForge.DataSet.Internal');

  { The Core entry points. An engine satisfies the rule by naming at least
    one of them. }
  function AsksCore(const ACode: string): Boolean;
  begin
    Result := ACode.Contains('TSerializationTypes.ContainerKindOf') or
              ACode.Contains('TSerializationTypes.TryGetListAccess') or
              ACode.Contains('TSerializationTypes.TryGetDictionaryAccess');
  end;

begin
  Writeln;
  Writeln('-- every engine asks the same question --');
  SrcDir := TPath.GetFullPath(TPath.Combine(ExtractFilePath(ParamStr(0)),
    '..\..\..\src'));

  Offenders := TStringList.Create;
  Users := TStringList.Create;
  try
    for Unit_ in ENGINES do
    begin
      Path := TPath.Combine(SrcDir, Unit_ + '.pas');
      if not TFile.Exists(Path) then Continue;
      { Comments are not stripped here: no engine comment names the old
        primitive, so the token appearing at all is a real call. }
      Code := TFile.ReadAllText(Path);

      { The old shared primitive. Core may still use it; an engine may not,
        because calling it IS carrying the classification. }
      if Code.Contains('InheritsFromGenericBase(') then
        Offenders.Add(Unit_ + ' still classifies containers itself ' +
          '(InheritsFromGenericBase)');

      if AsksCore(Code) then Users.Add(Unit_);
    end;

    for var S in Offenders do Note(S);
    Note(Format('%d engines consult TSerializationTypes', [Users.Count]));
    Check(Offenders.Count = 0, 'NO_PRIVATE_CONTAINER_CLASSIFICATION');
    { All eleven, and the number is pinned rather than loose: a count that
      drops is the signal that a refactor quietly gave an engine its own
      classification back, which is the exact regression this guards. }
    Check(Users.Count = Length(ENGINES),
      'ALL_FORMATS_USE_SHARED_CONTAINER_ACCESS');
  finally
    Users.Free;
    Offenders.Free;
  end;
end;

begin
  try
    { Linking PascalForge.Json.Registration registered nothing. }
    Check(not TSerialization.IsRegistered(TSerializationFormat.Json),
      'NO_AUTO_FORMAT_REGISTRATION');
    TJsonSerializationRegistration.RegisterFormat;
    Check(TJsonSerializationRegistration.IsRegistered,
      'EXPLICIT_FORMAT_REGISTRATION');
    TestRegistered;
    TestUnregistered;
    TestJsonThroughTheFacade;
    TestPayloadKinds;
    TestFormatIsolationInSource;
    TestSharedContainerAccess;
    { Last: it deliberately leaves a rejected registration behind. }
    TestDuplicateRegistration;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  if GFailures = 0 then
    Writeln('FORMAT_REGISTRY: PASS')
  else
    Writeln('FORMAT_REGISTRY: FAIL (', GFailures, ')');
  ExitCode := Ord(GFailures <> 0);
end.
