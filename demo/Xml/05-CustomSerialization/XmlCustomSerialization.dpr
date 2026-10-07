program XmlCustomSerialization;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ A custom XML serializer writes into the element the value occupies, so it
  can use attributes, children, text, or all three.

  Build:  ..\..\..\scripts\dcc.cmd XmlCustomSerialization.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  XmlCustomModels in 'XmlCustomModels.pas',
  PascalForge.Xml in '..\..\..\src\PascalForge.Xml.pas';

var
  Place, Back: TPlace;
  Xml: string;

begin
  { Registrations happen before anything is serialized: a type's plan is
    cached the first time it is used, and a later registration would be a
    silent no-op. }
  TXmlSerializer.RegisterTypeSerializer<TCoordinate>(TCoordinateSerializer);

  Place := TPlace.Create;
  try
    Place.Name := 'Greenwich';
    Place.Where.Latitude := 51.4779;
    Place.Where.Longitude := -0.0015;
    Xml := TXmlSerializer.Serialize<TPlace>(Place);
  finally
    Place.Free;
  end;
  Writeln(Xml);

  Back := TXmlSerializer.Deserialize<TPlace>(Xml);
  try
    Writeln;
    Writeln(Format('back: %s at %.4f, %.4f',
      [Back.Name, Back.Where.Latitude, Back.Where.Longitude]));
  finally
    Back.Free;
  end;

  Writeln;
  Writeln('This serializer is XML''s. Registering it does not make it a JSON');
  Writeln('or a BSON serializer - each format has its own contract, and its');
  Writeln('own natural shape for the same Delphi value.');
end.
