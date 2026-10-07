program BasicJson;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The smallest useful thing: an object out, an object back.

  Build:  ..\..\..\scripts\dcc.cmd BasicJson.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  PascalForge.Json in '..\..\..\src\PascalForge.Json.pas';

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
  Json: string;

begin
  Customer := TCustomer.Create;
  try
    Customer.Id := 42;
    Customer.Name := 'Alice Sample';
    Customer.Address.City := 'Harbor';
    Customer.Address.Zip := 'W1';

    Json := TJsonSerializer.Serialize(Customer);
    Writeln('serialized : ', Json);
  finally
    Customer.Free;
  end;

  { Deserialize builds a new graph and hands it to you: you own it. }
  Restored := TJsonSerializer.Deserialize<TCustomer>(Json);
  try
    Writeln('name       : ', Restored.Name);
    Writeln('city       : ', Restored.Address.City);
  finally
    Restored.Free;
  end;

  { Populate fills an object you already have, instead of making a new one. }
  Customer := TCustomer.Create;
  try
    TJsonSerializer.Populate(Customer, '{"id":7,"name":"Alice Sample"}');
    Writeln('populated  : ', Customer.Id, ' ', Customer.Name);
  finally
    Customer.Free;
  end;
end.
