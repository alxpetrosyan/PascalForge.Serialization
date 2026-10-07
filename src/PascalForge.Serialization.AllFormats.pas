{*******************************************************************************
  PascalForge.Serialization.AllFormats

  Every format of the library, registered - or unregistered - in one call.

  Responsibilities
    - TSerializationFormatsRegistration.RegisterAll, UnregisterAll.

  Registration
    NO AUTOMATIC REGISTRATION OCCURS FROM UNIT INITIALIZATION. Naming this
    unit in a uses clause registers nothing; the application calls

      TSerializationFormatsRegistration.RegisterAll;

    at startup. This unit links every format, so an application that wants
    only some registers those through their own PascalForge.<Format>.
    Registration units instead.

  Documentation
    docs/configuration-lifecycle.md, docs/packaging.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Serialization.AllFormats;

interface

type
  { Registers or unregisters all ten format families - JSON, XML, BSON,
    Protobuf, CBOR, MessagePack, YAML, CSV, Avro and ASN.1 (BER, DER, CER).
    Both are idempotent, like the per-format calls they make. }
  TSerializationFormatsRegistration = class sealed
  public
    class procedure RegisterAll; static;
    class procedure UnregisterAll; static;
  end;

implementation

uses
  PascalForge.Json.Registration,
  PascalForge.Xml.Registration,
  PascalForge.Bson.Registration,
  PascalForge.Protobuf.Registration,
  PascalForge.Cbor.Registration,
  PascalForge.MessagePack.Registration,
  PascalForge.Yaml.Registration,
  PascalForge.Csv.Registration,
  PascalForge.Avro.Registration,
  PascalForge.Asn1.Registration;

class procedure TSerializationFormatsRegistration.RegisterAll;
begin
  TJsonSerializationRegistration.RegisterFormat;
  TXmlSerializationRegistration.RegisterFormat;
  TBsonSerializationRegistration.RegisterFormat;
  TProtobufSerializationRegistration.RegisterFormat;
  TCborSerializationRegistration.RegisterFormat;
  TMessagePackSerializationRegistration.RegisterFormat;
  TYamlSerializationRegistration.RegisterFormat;
  TCsvSerializationRegistration.RegisterFormat;
  TAvroSerializationRegistration.RegisterFormat;
  TAsn1SerializationRegistration.RegisterFormat;
end;

class procedure TSerializationFormatsRegistration.UnregisterAll;
begin
  TAsn1SerializationRegistration.UnregisterFormat;
  TAvroSerializationRegistration.UnregisterFormat;
  TCsvSerializationRegistration.UnregisterFormat;
  TYamlSerializationRegistration.UnregisterFormat;
  TMessagePackSerializationRegistration.UnregisterFormat;
  TCborSerializationRegistration.UnregisterFormat;
  TProtobufSerializationRegistration.UnregisterFormat;
  TBsonSerializationRegistration.UnregisterFormat;
  TXmlSerializationRegistration.UnregisterFormat;
  TJsonSerializationRegistration.UnregisterFormat;
end;

end.
