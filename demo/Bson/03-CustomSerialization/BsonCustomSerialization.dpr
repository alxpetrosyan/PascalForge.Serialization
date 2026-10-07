program BsonCustomSerialization;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ A custom BSON serializer returns a BSON value, so it can use any element
  type the format has.

  Build:  ..\..\..\scripts\dcc.cmd BsonCustomSerialization.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  BsonCustomModels in 'BsonCustomModels.pas',
  PascalForge.Bson in '..\..\..\src\PascalForge.Bson.pas';

var
  Place, Back: TPlace;
  Data: TBytes;

begin
  TBsonSerializer.RegisterTypeSerializer<TCoordinate>(TCoordinateSerializer);

  Place := TPlace.Create;
  try
    Place.Name := 'Greenwich';
    Place.Where.Latitude := 51.4779;
    Place.Where.Longitude := -0.0015;
    Data := TBsonSerializer.Serialize<TPlace>(Place);
  finally
    Place.Free;
  end;
  Writeln(Format('%d bytes', [Length(Data)]));

  Back := TBsonSerializer.Deserialize<TPlace>(Data);
  try
    Writeln(Format('back: %s at %.4f, %.4f',
      [Back.Name, Back.Where.Latitude, Back.Where.Longitude]));
  finally
    Back.Free;
  end;

  Writeln;
  Writeln('A coordinate is two doubles, and BSON''s natural shape for that is');
  Writeln('a two-element array of doubles - not the string JSON would use or');
  Writeln('the pair of attributes XML would. Each format gets its own.');
end.
