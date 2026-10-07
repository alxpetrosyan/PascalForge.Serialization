program BasicXml;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The smallest useful thing: an object out, an object back.

  Build:  ..\..\..\scripts\dcc.cmd BasicXml.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  PascalForge.Xml in '..\..\..\src\PascalForge.Xml.pas';

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
  Xml: string;
  Options: TXmlSerializationOptions;

begin
  Customer := TCustomer.Create;
  try
    Customer.Id := 42;
    Customer.Name := 'Alice Sample';
    Customer.Address.City := 'Harbor';
    Customer.Address.Zip := 'NW1';
    Xml := TXmlSerializer.Serialize<TCustomer>(Customer);
  finally
    Customer.Free;
  end;

  Writeln('compact:');
  Writeln(Xml);

  { The root element is the class name without Delphi's leading T, and a
    member is an element named exactly as the Delphi member is. XML's
    convention is PascalCase; unlike JSON, nothing is lower-cased. }
  Options := TXmlSerializationOptions.Default;
  Options.Indent := True;
  Options.Declaration := True;
  Writeln;
  Writeln('indented, with a declaration:');
  Customer := TCustomer.Create;
  try
    Customer.Id := 42;
    Customer.Name := 'Alice Sample';
    Customer.Address.City := 'Harbor';
    Customer.Address.Zip := 'NW1';
    Writeln(TXmlSerializer.Serialize<TCustomer>(Customer, Options));
  finally
    Customer.Free;
  end;

  Restored := TXmlSerializer.Deserialize<TCustomer>(Xml);
  try
    Writeln;
    Writeln(Format('back: %d %s, %s %s',
      [Restored.Id, Restored.Name, Restored.Address.Zip,
       Restored.Address.City]));
  finally
    Restored.Free;
  end;
end.
