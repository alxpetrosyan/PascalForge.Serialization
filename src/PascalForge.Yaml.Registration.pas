{*******************************************************************************
  PascalForge.Yaml.Registration

  Explicit registration of YAML with the format registry.

  Responsibilities
    - TYamlSerializationRegistration: RegisterFormat, UnregisterFormat, IsRegistered.
    - The registry handler that forwards TSerialization calls to the engine.

  Registration
    NO AUTOMATIC REGISTRATION OCCURS FROM UNIT INITIALIZATION. Linking this
    unit, or loading the package that contains it, registers nothing. An
    application registers YAML at startup:

      TYamlSerializationRegistration.RegisterFormat;

    Direct TYamlSerializer use never needs this. Finalization only removes
    a handler this unit registered, so an unloaded package leaves no handler
    whose code is gone.

  Documentation
    docs/formats/yaml.md, docs/configuration-lifecycle.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Yaml.Registration;

interface

type
  { YAML in the TSerialization registry.
    RegisterFormat is idempotent; it raises ESerializationFormatConflict when
    a different handler already holds the format. UnregisterFormat is a no-op
    when this unit's handler is not registered, and never removes another. }
  TYamlSerializationRegistration = class sealed
  public
    class procedure RegisterFormat; static;
    class procedure UnregisterFormat; static;
    class function IsRegistered: Boolean; static;
  end;

implementation

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Yaml,
  PascalForge.Yaml.Internal;

type
  TYamlFormatHandler = class(TSerializationFormatHandler)
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

function TYamlFormatHandler.PayloadKind: TSerializationPayloadKind;
begin
  Result := TSerializationPayloadKind.Text;
end;

function TYamlFormatHandler.SerializeTyped(ATypeInfo: PTypeInfo;
  const AValue: TValue): TSerializationPayload;
begin
  Result := TSerializationPayload.FromText(
    TYamlEngine.SerializeRoot(ATypeInfo, AValue,
      TYamlEngine.DefaultEmitOptions));
end;

function TYamlFormatHandler.DeserializeTyped(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload): TValue;
begin
  Result := TYamlEngine.DeserializeRoot(ATypeInfo,
    APayload.AsTextDocument, TValue.Empty);
end;

function TYamlFormatHandler.ToDynamic(const APayload: TSerializationPayload;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
begin
  { All of a multi-document stream: an array of its documents. }
  Result := TYamlSerializer.ToDynamic(APayload.AsTextDocument, AOptions);
end;

function TYamlFormatHandler.FromDynamic(const AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
begin
  Result := TSerializationPayload.FromText(
    TYamlSerializer.FromDynamic(AValue, AOptions));
end;

{ ------------------------------------------------------------------------ }

class procedure TYamlSerializationRegistration.RegisterFormat;
begin
  TSerializationFormats.Register(TSerializationFormat.Yaml, TYamlFormatHandler);
end;

class procedure TYamlSerializationRegistration.UnregisterFormat;
begin
  TSerializationFormats.Unregister(TSerializationFormat.Yaml, TYamlFormatHandler);
end;

class function TYamlSerializationRegistration.IsRegistered: Boolean;
begin
  Result :=
    TSerializationFormats.IsRegistered(TSerializationFormat.Yaml, TYamlFormatHandler);
end;

initialization
  { Nothing: registering is the application's call, never a side effect
    of linking this unit or loading its package. }

finalization
  { Cleanup only: removes this unit's handler if the application left it
    registered. }
  TYamlSerializationRegistration.UnregisterFormat;

end.
