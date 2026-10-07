program BsonDateTime;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ BSON's date and time representation, which differs from the text formats'
  for a reason worth stating.

  Build:  ..\..\..\scripts\dcc.cmd BsonDateTime.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.DateUtils,
  BsonDateModels in 'BsonDateModels.pas',
  PascalForge.Bson in '..\..\..\src\PascalForge.Bson.pas';

function KindName(AKind: TBsonKind): string;
begin
  case AKind of
    TBsonKind.Int64: Result := 'int64';
    TBsonKind.DateTime: Result := 'datetime (native)';
    TBsonKind.Str: Result := 'string';
  else
    Result := 'other';
  end;
end;

var
  Event: TEvent;
  Data: TBytes;
  Doc: TBsonValue;
  I: Integer;

begin
  Event := TEvent.Create;
  try
    Event.Name := 'launch';
    Event.Day := EncodeDate(2026, 3, 14);
    Event.At := EncodeDateTime(2026, 3, 14, 9, 26, 53, 0);
    Event.Expires := Event.At;
    Data := TBsonSerializer.Serialize<TEvent>(Event);
  finally
    Event.Free;
  end;

  Doc := TBsonSerializer.ParseDocument(Data);
  try
    for I := 0 to Doc.Count - 1 do
      Writeln(Format('  %-8s %s', [Doc.Names[I], KindName(Doc[I].Kind)]));
  finally
    Doc.Free;
  end;

  Writeln;
  Writeln('TDateTime is an instant, so it gets BSON''s native datetime:');
  Writeln('milliseconds since the Unix epoch, as a 64-bit integer.');
  Writeln;
  Writeln('TDate and TTime are NOT instants. A date has no time of day and a');
  Writeln('time has no day, so writing either as a BSON datetime would claim');
  Writeln('a point in time neither of them has. They default to ISO 8601');
  Writeln('strings instead, and the choice is documented rather than');
  Writeln('silently made.');
  Writeln;
  Writeln('Expires carries [BsonDateTimeRepresentation(UnixSeconds)], which');
  Writeln('beats every registration.');
end.
