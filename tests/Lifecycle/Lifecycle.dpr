program Lifecycle;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The two lifecycles an application goes through, for every format.

  REGISTRATION   The format registry is filled by the application, explicitly.
                 Linking every registration unit - this program links all of
                 them, through PascalForge.Serialization.AllFormats - registers
                 nothing. The direct serializers work without the registry;
                 TSerialization refuses a format nobody registered, and works
                 once one is.

  CONFIGURATION  Each serializer's configuration can change until the
                 serializer is first used, and is refused - loudly - after:
                 cached plans already hold the old decision. Nothing here
                 calls FreezeConfiguration; the first real operation freezes.

  The order of the sections is the point, so it is fixed: configure, use,
  configure again. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  Data.DB, FireDAC.Comp.Client,
  PascalForge.Serialization.Core,
  PascalForge.Serialization,
  PascalForge.Serialization.AllFormats,
  PascalForge.Json, PascalForge.Json.Registration,
  PascalForge.Xml, PascalForge.Xml.Registration,
  PascalForge.Bson, PascalForge.Bson.Registration,
  PascalForge.Protobuf, PascalForge.Protobuf.Registration,
  PascalForge.Cbor, PascalForge.Cbor.Registration,
  PascalForge.MessagePack, PascalForge.MessagePack.Registration,
  PascalForge.Yaml, PascalForge.Yaml.Registration,
  PascalForge.Csv, PascalForge.Csv.Registration,
  PascalForge.Avro, PascalForge.Avro.Registration,
  PascalForge.Asn1, PascalForge.Asn1.Registration,
  PascalForge.DataSet,
  PascalForge.DataSet.Json;

type
  TPerson = class
  public
    [ProtoField(1)] Name: string;
    [ProtoField(2)] Age: Integer;
  end;

  { Types nobody serializes: registering a serializer for one changes no
    output, and tells whether registration is still open. }
  TProbeBefore = record
    A: Integer;
  end;
  TProbeAfter = record
    B: Integer;
  end;

  TFamily = (fJson, fXml, fBson, fProtobuf, fCbor, fMessagePack, fYaml, fCsv,
    fAvro, fAsn1);

const
  FAMILY_KEY: array[TFamily] of string = ('JSON', 'XML', 'BSON', 'PROTOBUF',
    'CBOR', 'MESSAGEPACK', 'YAML', 'CSV', 'AVRO', 'ASN1');
  FAMILY_FORMATS: array[TFamily] of TSerializationFormat = (
    TSerializationFormat.Json, TSerializationFormat.Xml,
    TSerializationFormat.Bson, TSerializationFormat.Protobuf,
    TSerializationFormat.Cbor, TSerializationFormat.MessagePack,
    TSerializationFormat.Yaml, TSerializationFormat.Csv,
    TSerializationFormat.Avro, TSerializationFormat.Asn1Der);

var
  GFailures: Integer = 0;
  GChecks: Integer = 0;

procedure Check(ACondition: Boolean; const AName: string);
begin
  Inc(GChecks);
  if ACondition then Writeln(AName, ': PASS')
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

function NewPerson: TPerson;
begin
  Result := TPerson.Create;
  Result.Name := 'Alice';
  Result.Age := 41;
end;

function SamePerson(A: TPerson): Boolean;
begin
  Result := (A <> nil) and (A.Name = 'Alice') and (A.Age = 41);
  A.Free;
end;

{ ---------------------------------------------------------- the formats --- }

procedure RegisterSerializer(AFamily: TFamily; ATypeInfo: PTypeInfo);
begin
  { The abstract base class stands in for a serializer: these registrations
    are about whether the door is open, and the type is never serialized. }
  case AFamily of
    fJson: TJsonSerializer.RegisterTypeSerializer(ATypeInfo, TCustomJsonValueSerializer);
    fXml:
      if ATypeInfo = TypeInfo(TProbeBefore) then
        TXmlSerializer.RegisterTypeSerializer<TProbeBefore>(TCustomXmlValueSerializer)
      else TXmlSerializer.RegisterTypeSerializer<TProbeAfter>(TCustomXmlValueSerializer);
    fBson:
      if ATypeInfo = TypeInfo(TProbeBefore) then
        TBsonSerializer.RegisterTypeSerializer<TProbeBefore>(TCustomBsonValueSerializer)
      else TBsonSerializer.RegisterTypeSerializer<TProbeAfter>(TCustomBsonValueSerializer);
    fProtobuf:
      if ATypeInfo = TypeInfo(TProbeBefore) then
        TProtobufSerializer.RegisterTypeSerializer<TProbeBefore>(TCustomProtoValueSerializerBase)
      else TProtobufSerializer.RegisterTypeSerializer<TProbeAfter>(TCustomProtoValueSerializerBase);
    fCbor:
      if ATypeInfo = TypeInfo(TProbeBefore) then
        TCborSerializer.RegisterTypeSerializer<TProbeBefore>(TCustomCborValueSerializer)
      else TCborSerializer.RegisterTypeSerializer<TProbeAfter>(TCustomCborValueSerializer);
    fMessagePack:
      if ATypeInfo = TypeInfo(TProbeBefore) then
        TMessagePackSerializer.RegisterTypeSerializer<TProbeBefore>(TCustomMessagePackValueSerializer)
      else TMessagePackSerializer.RegisterTypeSerializer<TProbeAfter>(TCustomMessagePackValueSerializer);
    fYaml:
      if ATypeInfo = TypeInfo(TProbeBefore) then
        TYamlSerializer.RegisterTypeSerializer<TProbeBefore>(TCustomYamlValueSerializer)
      else TYamlSerializer.RegisterTypeSerializer<TProbeAfter>(TCustomYamlValueSerializer);
    fCsv:
      if ATypeInfo = TypeInfo(TProbeBefore) then
        TCsvSerializer.RegisterTypeSerializer<TProbeBefore>(TCustomCsvCellSerializer)
      else TCsvSerializer.RegisterTypeSerializer<TProbeAfter>(TCustomCsvCellSerializer);
    fAvro:
      if ATypeInfo = TypeInfo(TProbeBefore) then
        TAvroSerializer.RegisterTypeSerializer<TProbeBefore>(TCustomAvroValueSerializer)
      else TAvroSerializer.RegisterTypeSerializer<TProbeAfter>(TCustomAvroValueSerializer);
    fAsn1:
      if ATypeInfo = TypeInfo(TProbeBefore) then
        TAsn1Serializer.RegisterTypeSerializer<TProbeBefore>(TCustomAsn1ValueSerializer)
      else TAsn1Serializer.RegisterTypeSerializer<TProbeAfter>(TCustomAsn1ValueSerializer);
  end;
end;

function FamilyFrozen(AFamily: TFamily): Boolean;
begin
  case AFamily of
    fJson: Result := TJsonSerializer.IsFrozen;
    fXml: Result := TXmlSerializer.IsFrozen;
    fBson: Result := TBsonSerializer.IsFrozen;
    fProtobuf: Result := TProtobufSerializer.IsFrozen;
    fCbor: Result := TCborSerializer.IsFrozen;
    fMessagePack: Result := TMessagePackSerializer.IsFrozen;
    fYaml: Result := TYamlSerializer.IsFrozen;
    fCsv: Result := TCsvSerializer.IsFrozen;
    fAvro: Result := TAvroSerializer.IsFrozen;
    fAsn1: Result := TAsn1Serializer.IsFrozen;
  else
    Result := False;
  end;
end;

{ The direct serializer, with no registry involved. }
function DirectRoundTrip(AFamily: TFamily; P: TPerson): TPerson;
begin
  case AFamily of
    fJson: Result := TJsonSerializer.Deserialize<TPerson>(TJsonSerializer.Serialize<TPerson>(P));
    fXml: Result := TXmlSerializer.Deserialize<TPerson>(TXmlSerializer.Serialize<TPerson>(P));
    fBson: Result := TBsonSerializer.Deserialize<TPerson>(TBsonSerializer.Serialize<TPerson>(P));
    fProtobuf: Result := TProtobufSerializer.Deserialize<TPerson>(TProtobufSerializer.Serialize<TPerson>(P));
    fCbor: Result := TCborSerializer.Deserialize<TPerson>(TCborSerializer.Serialize<TPerson>(P));
    fMessagePack: Result := TMessagePackSerializer.Deserialize<TPerson>(TMessagePackSerializer.Serialize<TPerson>(P));
    fYaml: Result := TYamlSerializer.Deserialize<TPerson>(TYamlSerializer.Serialize<TPerson>(P));
    fCsv: Result := TCsvSerializer.Deserialize<TPerson>(TCsvSerializer.Serialize<TPerson>(P));
    fAvro: Result := TAvroSerializer.Deserialize<TPerson>(TAvroSerializer.Serialize<TPerson>(P));
    fAsn1: Result := TAsn1Serializer.Deserialize<TPerson>(TAsn1Serializer.Serialize<TPerson>(P));
  else
    Result := nil;
  end;
end;

procedure RegisterFamily(AFamily: TFamily);
begin
  case AFamily of
    fJson: TJsonSerializationRegistration.RegisterFormat;
    fXml: TXmlSerializationRegistration.RegisterFormat;
    fBson: TBsonSerializationRegistration.RegisterFormat;
    fProtobuf: TProtobufSerializationRegistration.RegisterFormat;
    fCbor: TCborSerializationRegistration.RegisterFormat;
    fMessagePack: TMessagePackSerializationRegistration.RegisterFormat;
    fYaml: TYamlSerializationRegistration.RegisterFormat;
    fCsv: TCsvSerializationRegistration.RegisterFormat;
    fAvro: TAvroSerializationRegistration.RegisterFormat;
    fAsn1: TAsn1SerializationRegistration.RegisterFormat;
  end;
end;

function AnyRegistered: Boolean;
var
  F: TSerializationFormat;
begin
  for F := Low(TSerializationFormat) to High(TSerializationFormat) do
    if TSerialization.IsRegistered(F) then Exit(True);
  Result := False;
end;

function AllRegistered: Boolean;
var
  F: TSerializationFormat;
begin
  for F := Low(TSerializationFormat) to High(TSerializationFormat) do
    if not TSerialization.IsRegistered(F) then Exit(False);
  Result := True;
end;

{ ------------------------------------------------------ 1. configuring --- }

procedure TestConfigureBeforeUse;
var
  F: TFamily;
  Ok: Boolean;
begin
  Writeln('-- configuration before first use is open --');
  for F := Low(TFamily) to High(TFamily) do
  begin
    Ok := True;
    try
      RegisterSerializer(F, TypeInfo(TProbeBefore));
    except
      on E: Exception do
      begin
        Ok := False;
        Note(E.ClassName + ': ' + E.Message);
      end;
    end;
    Check(Ok, 'CONFIGURATION_OPEN_BEFORE_USE_' + FAMILY_KEY[F]);
  end;
  Ok := True;
  try
    TDataSetSerializer.SetDefaultStringSize(255);
    TDataSetJsonIntegration.Register;
    TDataSetJsonIntegration.SetDefaultPolicy(
      TDataSetSerializationPolicy.StructureAndRows);
  except
    on E: Exception do
    begin
      Ok := False;
      Note(E.ClassName + ': ' + E.Message);
    end;
  end;
  Check(Ok, 'CONFIGURATION_OPEN_BEFORE_USE_DATASET');
  for F := Low(TFamily) to High(TFamily) do
    Check(not FamilyFrozen(F), 'NOT_FROZEN_BEFORE_USE_' + FAMILY_KEY[F]);
end;

{ ----------------------------------------------------- 2. registration --- }

procedure TestRegistration;
var
  F: TFamily;
  P: TPerson;
  Refused, Ok: Boolean;
  Payload: TSerializationPayload;
begin
  Writeln;
  Writeln('-- registration is explicit --');
  Check(not AnyRegistered, 'NO_AUTO_FORMAT_REGISTRATION');

  P := NewPerson;
  try
    for F := Low(TFamily) to High(TFamily) do
    begin
      try
        Check(SamePerson(DirectRoundTrip(F, P)),
          'DIRECT_' + FAMILY_KEY[F] + '_WITHOUT_REGISTRY');
      except
        on E: Exception do
        begin
          Check(False, 'DIRECT_' + FAMILY_KEY[F] + '_WITHOUT_REGISTRY');
          Note(E.ClassName + ': ' + E.Message);
        end;
      end;

      Refused := False;
      try
        TSerialization.Serialize<TPerson>(P, FAMILY_FORMATS[F]);
      except
        on E: ESerializationFormatNotRegistered do Refused := True;
      end;
      Check(Refused, 'GENERIC_' + FAMILY_KEY[F] + '_WITHOUT_REGISTRY_REFUSES');

      RegisterFamily(F);
      Ok := False;
      try
        Payload := TSerialization.Serialize<TPerson>(P, FAMILY_FORMATS[F]);
        Ok := SamePerson(TSerialization.Deserialize<TPerson>(Payload,
          FAMILY_FORMATS[F]));
      except
        on E: Exception do Note(E.ClassName + ': ' + E.Message);
      end;
      Check(Ok, 'GENERIC_' + FAMILY_KEY[F] + '_AFTER_EXPLICIT_REGISTER');
    end;
  finally
    P.Free;
  end;
  Check(TAsn1SerializationRegistration.IsRegistered and
        TSerialization.IsRegistered(TSerializationFormat.Asn1Ber) and
        TSerialization.IsRegistered(TSerializationFormat.Asn1Cer),
    'ASN1_REGISTERS_ALL_THREE_ENCODINGS');
  Check(AllRegistered, 'EXPLICIT_FORMAT_REGISTRATION');

  Writeln;
  Writeln('-- registering and unregistering are deterministic --');
  Ok := True;
  try
    TJsonSerializationRegistration.RegisterFormat;
    TJsonSerializationRegistration.RegisterFormat;
  except
    Ok := False;
  end;
  Check(Ok and TJsonSerializationRegistration.IsRegistered,
    'REGISTER_SAME_FORMAT_TWICE_IS_IDEMPOTENT');

  TSerializationFormatsRegistration.UnregisterAll;
  Check(not AnyRegistered, 'UNREGISTER_ALL');
  Ok := True;
  try
    TSerializationFormatsRegistration.UnregisterAll;
    TXmlSerializationRegistration.UnregisterFormat;
  except
    Ok := False;
  end;
  Check(Ok and not AnyRegistered, 'UNREGISTER_ABSENT_IS_SAFE');

  TSerializationFormatsRegistration.RegisterAll;
  Check(AllRegistered, 'REGISTER_ALL_EXPLICIT');
  Ok := True;
  try
    TSerializationFormatsRegistration.RegisterAll;
  except
    Ok := False;
  end;
  Check(Ok and AllRegistered, 'REGISTER_ALL_TWICE_IS_IDEMPOTENT');
end;

{ -------------------------------------------------- 3. after first use --- }

procedure TestConfigureAfterUse;
var
  F: TFamily;
  Refused, All: Boolean;
  P: TPerson;
  Table: TFDMemTable;

  function RefusedAsFrozen(AProc: TProc; const AName: string): Boolean;
  begin
    Result := False;
    try
      AProc();
      Note(AName + ': the late change was ACCEPTED');
    except
      on E: Exception do
      begin
        Result := Pos('froze', LowerCase(E.Message)) > 0;
        if not Result then Note(AName + ': ' + E.ClassName + ': ' + E.Message);
      end;
    end;
  end;

begin
  Writeln;
  Writeln('-- the first real operation freezes the configuration --');
  All := True;
  for F := Low(TFamily) to High(TFamily) do
  begin
    { Every family was used in section 2; nothing called
      FreezeConfiguration. }
    Refused := RefusedAsFrozen(
      procedure begin RegisterSerializer(F, TypeInfo(TProbeAfter)) end,
      FAMILY_KEY[F]);
    Check(Refused, FAMILY_KEY[F] + '_AUTO_FREEZE');
    Check(FamilyFrozen(F), FAMILY_KEY[F] + '_IS_FROZEN_REPORTED');
    All := All and Refused;
  end;

  { DataSet: one projection, then the default string size. }
  P := NewPerson;
  try
    Table := TDataSetSerializer.CreateFDMemTable<TPerson>(P);
    Table.Free;
  finally
    P.Free;
  end;
  Refused := RefusedAsFrozen(
    procedure begin TDataSetSerializer.SetDefaultStringSize(300) end, 'DATASET');
  Check(Refused, 'DATASET_AUTO_FREEZE');
  All := All and Refused;
  Check(All, 'AUTO_FREEZE_ALL_FORMATS');
  Check(All, 'LATE_CONFIGURATION_REFUSED');

  { The DataSet-in-JSON policies follow JSON's and DataSet's freeze. }
  Check(RefusedAsFrozen(
    procedure begin
      TDataSetJsonIntegration.SetDefaultPolicy(
        TDataSetSerializationPolicy.RowsOnly)
    end, 'DATASET_JSON default policy') and
    RefusedAsFrozen(
    procedure begin
      TDataSetJsonIntegration.RegisterTypePolicy<TFDMemTable>(
        TDataSetSerializationPolicy.RowsOnly)
    end, 'DATASET_JSON type policy') and
    RefusedAsFrozen(
    procedure begin
      TDataSetJsonIntegration.RegisterFieldPolicy<TPerson>('Name',
        TDataSetSerializationPolicy.RowsOnly)
    end, 'DATASET_JSON field policy') and
    RefusedAsFrozen(
    procedure begin TDataSetJsonIntegration.DataSetFactory := nil end,
      'DATASET_JSON factory'),
    'DATASET_JSON_LATE_POLICY_REFUSED');
end;

begin
  ReportMemoryLeaksOnShutdown := True;
  try
    TestConfigureBeforeUse;
    TestRegistration;
    TestConfigureAfterUse;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;
  TSerializationFormatsRegistration.UnregisterAll;

  Writeln;
  Writeln('CHECKS=', GChecks);
  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then
    Writeln('LIFECYCLE: PASS')
  else
  begin
    Writeln('LIFECYCLE: FAIL');
    ExitCode := 1;
  end;
end.
