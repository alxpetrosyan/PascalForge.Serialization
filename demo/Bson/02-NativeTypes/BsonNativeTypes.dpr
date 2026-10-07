program BsonNativeTypes;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ What BSON keeps that a text format cannot: int32 apart from int64, a real
  double, binary as binary, a timestamp as a timestamp, a GUID as a UUID.

  Build:  ..\..\..\scripts\dcc.cmd BsonNativeTypes.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.DateUtils,
  PascalForge.Bson in '..\..\..\src\PascalForge.Bson.pas';

type
  TReading = class
  public
    Small: Integer;
    Big: Int64;
    Rate: Double;
    Amount: Currency;
    Blob: TBytes;
    Taken: TDateTime;
    Sensor: TGUID;
  end;

function KindName(AKind: TBsonKind): string;
begin
  case AKind of
    TBsonKind.Int32: Result := 'int32';
    TBsonKind.Int64: Result := 'int64';
    TBsonKind.Double: Result := 'double';
    TBsonKind.Binary: Result := 'binary';
    TBsonKind.DateTime: Result := 'datetime';
    TBsonKind.Str: Result := 'string';
  else
    Result := 'other';
  end;
end;

var
  Reading, Back: TReading;
  Data: TBytes;
  Doc: TBsonValue;
  I: Integer;

begin
  Reading := TReading.Create;
  try
    Reading.Small := 4711;
    Reading.Big := 4611686018427387904;   { far beyond a double's 53 bits }
    Reading.Rate := 1.0845;
    Reading.Amount := 922337203685.4775;  { far beyond a double's precision }
    Reading.Blob := TBytes.Create(1, 2, 3, 250, 251, 252);
    Reading.Taken := EncodeDateTime(2026, 3, 14, 9, 26, 53, 0);
    Reading.Sensor := StringToGUID('{3F2504E0-4F89-11D3-9A0C-0305E82C3301}');
    Data := TBsonSerializer.Serialize<TReading>(Reading);
  finally
    Reading.Free;
  end;

  Writeln('what each member actually became:');
  Doc := TBsonSerializer.ParseDocument(Data);
  try
    for I := 0 to Doc.Count - 1 do
      Writeln(Format('  %-8s %s', [Doc.Names[I], KindName(Doc[I].Kind)]));
  finally
    Doc.Free;
  end;

  Writeln;
  Writeln('Currency is a scaled Int64 in Delphi, so BSON writes that integer');
  Writeln('and the value survives exactly. A double would not have.');
  Writeln('A GUID is binary subtype 4, which is what a BSON consumer');
  Writeln('expects - JSON''s lowercase-string rule is not inherited.');

  Back := TBsonSerializer.Deserialize<TReading>(Data);
  try
    Writeln;
    Writeln('back:');
    Writeln('  Big    = ', Back.Big);
    Writeln('  Amount = ', CurrToStr(Back.Amount));
    Writeln('  Blob   = ', Length(Back.Blob), ' bytes');
    Writeln('  Taken  = ', DateTimeToStr(Back.Taken));
  finally
    Back.Free;
  end;
end.
