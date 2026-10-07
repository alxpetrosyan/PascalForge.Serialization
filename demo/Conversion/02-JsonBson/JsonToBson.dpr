program JsonToBson;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ JSON to BSON and back. The interesting part is what BSON adds: a 64-bit
  integer that a JSON number cannot hold exactly, and a real timestamp.

  Build:  ..\..\..\scripts\dcc.cmd JsonToBson.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.TypInfo,
  ConvertModels in '..\Shared\ConvertModels.pas',
  PascalForge.Serialization.Core in '..\..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\..\src\PascalForge.Serialization.pas',
  PascalForge.Json in '..\..\..\src\PascalForge.Json.pas',
  PascalForge.Bson in '..\..\..\src\PascalForge.Bson.pas',
  PascalForge.Json.Registration in '..\..\..\src\PascalForge.Json.Registration.pas',
  PascalForge.Bson.Registration in '..\..\..\src\PascalForge.Bson.Registration.pas';

var
  Order: TOrder;
  Json: string;
  Bson: TBytes;
  Doc: TBsonValue;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TJsonSerializationRegistration.RegisterFormat;
  TBsonSerializationRegistration.RegisterFormat;
  Order := SampleOrder;
  try
    Json := TJsonSerializer.Serialize<TOrder>(Order);
  finally
    Order.Free;
  end;
  Writeln('JSON:');
  Writeln(Json);

  Bson := TBsonSerializer.From<TOrder>(Json, TSerializationFormat.Json);
  Writeln;
  Writeln(Format('BSON: %d bytes', [Length(Bson)]));

  Doc := TBsonSerializer.ParseDocument(Bson);
  try
    Writeln('  _id is an ', GetEnumName(TypeInfo(TBsonKind),
      Ord(Doc.Find('_id').Kind)));
    Writeln('  created_at is a ', GetEnumName(TypeInfo(TBsonKind),
      Ord(Doc.Find('created_at').Kind)));
  finally
    Doc.Free;
  end;

  Writeln;
  Writeln('back to JSON:');
  Writeln(TJsonSerializer.From<TOrder>(Bson, TSerializationFormat.Bson));
  Writeln;
  Writeln('The BSON names are BSON''s - _id, cust, created_at - because the');
  Writeln('destination applies its own attributes. Nothing was renamed by');
  Writeln('the source.');
end.
