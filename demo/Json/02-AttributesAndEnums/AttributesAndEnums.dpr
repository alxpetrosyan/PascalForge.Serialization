program AttributesAndEnums;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Controlling the shape of the document: member names, members left out, and
  how an enumeration is spelled on the wire. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  PascalForge.Json in '..\..\..\src\PascalForge.Json.pas';

type
  TStatus = (Draft, Active, Closed);

  TDevice = class
  public
    { The wire name differs from the Delphi name. }
    [JsonName('accountNumber')]
    Number: string;

    { Never written, never read. }
    [JsonIgnore]
    CachedScore: Currency;

    Owner: string;
    Status: TStatus;
  end;

var
  Device: TDevice;
  Json: string;

begin
  { Registration happens once, at startup. A type's plan is cached the first
    time it is used, so a mapping registered later would not reach it. }
  TJsonSerializer.RegisterEnumMapping<TStatus>(['draft', 'active', 'closed']);

  Device := TDevice.Create;
  try
    Device.Number := 'SN-0000-0000-0001';
    Device.CachedScore := 999;
    Device.Owner := 'Alice Sample';
    Device.Status := TStatus.Active;

    Json := TJsonSerializer.Serialize(Device);
  finally
    Device.Free;
  end;

  Writeln(Json);
  Writeln;
  Writeln('note: "number" was written as "accountNumber",');
  Writeln('      "cachedScore" does not appear at all,');
  Writeln('      and Status came out as "active" rather than 1.');

  Device := TJsonSerializer.Deserialize<TDevice>(Json);
  try
    Writeln;
    Writeln('read back  : ', Device.Owner, ', status ord ', Ord(Device.Status));
  finally
    Device.Free;
  end;
end.
