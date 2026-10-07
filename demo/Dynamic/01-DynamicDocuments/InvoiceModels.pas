unit InvoiceModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The Delphi types the demo projects into dynamic values. }

interface

uses
  PascalForge.Serialization.Attributes,
  PascalForge.Json;

type
  [SerializationEnum('draft,sent,paid')]
  TInvoiceState = (Draft, Sent, Paid);

  TCustomer = class
  public
    { The general name - every format and Dynamic use it... }
    [SerializationName('customer_id')]
    Id: Integer;
    { ...except JSON here, whose own attribute is more specific. }
    [SerializationName('display_name')]
    [JsonName('displayName')]
    Name: string;
    { Never written anywhere. }
    [SerializationIgnore]
    PasswordHash: string;
    State: TInvoiceState;
  end;

  TPoint = record
    X: Integer;
    Y: Integer;
  end;

implementation

end.
