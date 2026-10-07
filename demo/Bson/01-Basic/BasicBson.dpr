program BasicBson;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The smallest useful thing: an object out, an object back. BSON is binary,
  so the result is TBytes and not a string.

  Build:  ..\..\..\scripts\dcc.cmd BasicBson.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  PascalForge.Bson in '..\..\..\src\PascalForge.Bson.pas';

type
  TAddress = record
    City: string;
    Zip: string;
  end;

  TCustomer = class
  public
    Id: Integer;
    Name: string;
    Address: TAddress;
  end;

var
  Customer, Restored: TCustomer;
  Data: TBytes;

begin
  Customer := TCustomer.Create;
  try
    Customer.Id := 42;
    Customer.Name := 'Alice Sample';
    Customer.Address.City := 'Harbor';
    Customer.Address.Zip := 'NW1';
    Data := TBsonSerializer.Serialize<TCustomer>(Customer);
  finally
    Customer.Free;
  end;

  Writeln(Format('%d bytes', [Length(Data)]));
  Writeln;
  Writeln('There is no base64 API here. BSON is bytes, and a caller who');
  Writeln('wants base64 can encode them - a caller who does not should never');
  Writeln('have to pay for it.');

  Restored := TBsonSerializer.Deserialize<TCustomer>(Data);
  try
    Writeln;
    Writeln(Format('back: %d %s, %s %s',
      [Restored.Id, Restored.Name, Restored.Address.Zip,
       Restored.Address.City]));
  finally
    Restored.Free;
  end;
end.
