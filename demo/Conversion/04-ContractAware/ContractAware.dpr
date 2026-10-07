program ContractAware;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The two conversion modes, side by side, on the same document - and what
  each of them costs.

  Build:  ..\..\..\scripts\dcc.cmd ContractAware.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  ConvertModels in '..\Shared\ConvertModels.pas',
  PascalForge.Serialization.Core in '..\..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\..\src\PascalForge.Serialization.pas',
  PascalForge.Json in '..\..\..\src\PascalForge.Json.pas',
  PascalForge.Xml in '..\..\..\src\PascalForge.Xml.pas',
  PascalForge.Json.Registration in '..\..\..\src\PascalForge.Json.Registration.pas',
  PascalForge.Xml.Registration in '..\..\..\src\PascalForge.Xml.Registration.pas';

const
  PLAIN = '{"id":7,"name":"Ada","tags":["x","y"]}';
var
  Order: TOrder;
  Json: string;
  Payload: TSerializationPayload;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TJsonSerializationRegistration.RegisterFormat;
  TXmlSerializationRegistration.RegisterFormat;
  Order := SampleOrder;
  try
    Json := TJsonSerializer.Serialize<TOrder>(Order);
  finally
    Order.Free;
  end;

  Writeln('CONTRACT-AWARE - the Delphi type is the contract');
  Writeln('-----------------------------------------------');
  Payload := TSerialization.Convert<TOrder>(
    TSerializationPayload.FromText(Json),
    TSerializationFormat.Json, TSerializationFormat.Xml);
  Writeln(Payload.AsText);
  Writeln;
  Writeln('Each side applied its own attributes, so orderId became an');
  Writeln('OrderID attribute and sku became <SKU>. The intermediate TOrder');
  Writeln('was built, written out and released inside the call; nothing was');
  Writeln('returned for anyone to free.');

  Writeln;
  Writeln('STRUCTURAL - no contract at all');
  Writeln('-------------------------------');
  Payload := TSerialization.Convert(TSerializationPayload.FromText(PLAIN),
    TSerializationFormat.Json, TSerializationFormat.Xml);
  Writeln(Payload.AsText);
  Writeln;
  Payload := TSerialization.Convert(Payload,
    TSerializationFormat.Xml, TSerializationFormat.Json);
  Writeln('and back to JSON:');
  Writeln(Payload.AsText);
  Writeln;
  Writeln('The 7 went out a number and came back "7". XML element text');
  Writeln('carries no type, so the round trip could not have kept it. That');
  Writeln('is the documented cost of the contract-free path, and it is why');
  Writeln('contract-aware is the one to prefer when semantics matter.');
end.
