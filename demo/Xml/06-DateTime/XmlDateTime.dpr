program XmlDateTime;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ XML's date and time policy. The defaults are the xs: forms, and they are
  XML's own - not JSON's, which this program also prints for contrast.

  Build:  ..\..\..\scripts\dcc.cmd XmlDateTime.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.DateUtils,
  XmlDateModels in 'XmlDateModels.pas',
  PascalForge.Xml in '..\..\..\src\PascalForge.Xml.pas';

var
  Event: TEvent;
  Stamp: TDateTime;

begin
  Stamp := EncodeDateTime(2026, 3, 14, 9, 26, 53, 0);
  Event := TEvent.Create;
  try
    Event.Name := 'launch';
    Event.Day := Trunc(Stamp);
    Event.At := Stamp;
    Event.Expires := Stamp;

    Writeln('default - the xs: forms:');
    Writeln('  ', TXmlSerializer.Serialize<TEvent>(Event));
    Writeln;
    Writeln('  xs:date      yyyy-mm-dd');
    Writeln('  xs:time      hh:nn:ss, with .zzz when there are milliseconds');
    Writeln('  xs:dateTime  the two joined by T, and NO offset');
    Writeln;
    Writeln('A TDateTime carries no time zone, so none is invented. An offset');
    Writeln('in an incoming document is accepted and ignored: the wall-clock');
    Writeln('fields are taken as written, which is the only reading a');
    Writeln('TDateTime can represent honestly.');
    Writeln;
    Writeln('The Expires member carries [XmlDateTimeFormat(UnixSeconds)] and');
    Writeln('is therefore a number above. A member attribute beats every');
    Writeln('registration; after it come a field registration, a type');
    Writeln('registration, XML''s global default, then the built-in forms.');
    Writeln;
    Writeln('None of this touches JSON or BSON. Each format has its own');
    Writeln('table, and configuring one moves nothing in the others.');
  finally
    Event.Free;
  end;
end.
