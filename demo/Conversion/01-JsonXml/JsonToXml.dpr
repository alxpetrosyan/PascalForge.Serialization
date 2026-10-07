program JsonToXml;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ JSON to XML, both ways round, and the difference between the two ways of
  doing it.

  Build:  ..\..\..\scripts\dcc.cmd JsonToXml.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  ConvertModels in '..\Shared\ConvertModels.pas',
  PascalForge.Serialization.Core in '..\..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\..\src\PascalForge.Serialization.pas',
  PascalForge.Json in '..\..\..\src\PascalForge.Json.pas',
  PascalForge.Xml in '..\..\..\src\PascalForge.Xml.pas',
  { Including a registration unit is what makes a format reachable by name. }
  PascalForge.Json.Registration in '..\..\..\src\PascalForge.Json.Registration.pas',
  PascalForge.Xml.Registration in '..\..\..\src\PascalForge.Xml.Registration.pas';

var
  Order: TOrder;
  Json, Xml: string;

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
  Writeln('JSON:');
  Writeln(Json);

  { CONTRACT-AWARE. The Delphi type is the contract: JSON reads it by its own
    rules, XML writes it by its own, so 'orderId' becomes an OrderID
    attribute and 'sku' becomes <SKU>. }
  Xml := TXmlSerializer.From<TOrder>(Json, TSerializationFormat.Json);
  Writeln;
  Writeln('XML, through the contract:');
  Writeln(Xml);

  Writeln;
  Writeln('and back:');
  Writeln(TJsonSerializer.From<TOrder>(Xml, TSerializationFormat.Xml));

  { STRUCTURAL. No contract, so no attribute applies and nothing is renamed.
    It carries what every format shares and nothing else. }
  Writeln;
  Writeln('the same JSON, structurally:');
  Writeln(TXmlSerializer.From(Json, TSerializationFormat.Json));
  Writeln;
  Writeln('Contract-aware is the one to prefer whenever the semantics');
  Writeln('matter. Structural is for a document whose contract nobody has.');
end.
