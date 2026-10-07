unit DataSetModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

interface

uses
  PascalForge.Json;

type
  TShipment = class
  public
    [JsonName('id')]
    Id: Int64;
    [JsonName('consignee')]
    Consignee: string;
    [JsonName('booked')]
    Booked: TDate;
  end;

implementation

end.
