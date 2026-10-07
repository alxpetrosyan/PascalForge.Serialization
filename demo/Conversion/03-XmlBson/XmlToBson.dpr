program XmlToBson;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ XML to BSON and back, with no JSON anywhere in the program.

  Build:  ..\..\..\scripts\dcc.cmd XmlToBson.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  ConvertModels in '..\Shared\ConvertModels.pas',
  PascalForge.Serialization.Core in '..\..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\..\src\PascalForge.Serialization.pas',
  PascalForge.Xml in '..\..\..\src\PascalForge.Xml.pas',
  PascalForge.Bson in '..\..\..\src\PascalForge.Bson.pas',
  PascalForge.Xml.Registration in '..\..\..\src\PascalForge.Xml.Registration.pas',
  PascalForge.Bson.Registration in '..\..\..\src\PascalForge.Bson.Registration.pas';

var
  Order, Back: TOrder;
  Xml: string;
  Bson: TBytes;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TXmlSerializationRegistration.RegisterFormat;
  TBsonSerializationRegistration.RegisterFormat;
  Order := SampleOrder;
  try
    Xml := TXmlSerializer.Serialize<TOrder>(Order);
  finally
    Order.Free;
  end;
  Writeln('XML:');
  Writeln(Xml);

  Bson := TBsonSerializer.From<TOrder>(Xml, TSerializationFormat.Xml);
  Writeln;
  Writeln(Format('BSON: %d bytes', [Length(Bson)]));

  Back := TBsonSerializer.Deserialize<TOrder>(Bson);
  try
    Writeln(Format('  read back: %d, %s, %d lines',
      [Back.Id, Back.Customer, Back.Lines.Count]));
  finally
    Back.Free;
  end;

  Writeln;
  Writeln('Neither PascalForge.Xml nor PascalForge.Bson mentions the other.');
  Writeln('TXmlSerializer.From reaches BSON through the registry, by name,');
  Writeln('at run time - which is the only way one format ever reaches');
  Writeln('another in this library.');
end.
