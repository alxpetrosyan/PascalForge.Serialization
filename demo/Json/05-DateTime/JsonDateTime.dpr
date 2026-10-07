program JsonDateTime;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ JSON's date and time policy: what it does with no configuration, and the
  four ways to change it.

  Build:  ..\..\..\scripts\dcc.cmd JsonDateTime.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.DateUtils,
  JsonDateModels in 'JsonDateModels.pas',
  PascalForge.Json in '..\..\..\src\PascalForge.Json.pas';

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

    { With nothing configured, JSON writes what it has always written. }
    Writeln('default:');
    Writeln('  ', TJsonSerializer.Serialize<TEvent>(Event));

    { A member attribute is the most specific statement there is, and it is
      already on TEvent.Expires - look at JsonDateModels.pas. Everything
      below is a registration, and none of them can override it. }
    Writeln;
    Writeln('The Expires member carries [JsonDateTimeFormat(UnixSeconds)],');
    Writeln('so it is a number above while At is still ISO 8601.');
    Writeln;
    Writeln('Resolution order, strongest first:');
    Writeln('  1. a member attribute            [JsonDateTimeFormat(...)]');
    Writeln('  2. a field registration          RegisterFieldDateTimeFormat<T>');
    Writeln('  3. a type registration           RegisterDateTimeFormat<T>');
    Writeln('  4. the format-global default     SetDateTimeFormat');
    Writeln('  5. the built-in ISO 8601 forms');
    Writeln;
    Writeln('All four are resolved ONCE, while the type''s plan is built, so');
    Writeln('nothing is looked up while a document is being written.');
    Writeln;
    Writeln('XML and BSON have their own, entirely separate settings. Setting');
    Writeln('JSON''s moves no XML and no BSON output - see demo\Conversion.');
  finally
    Event.Free;
  end;
end.
