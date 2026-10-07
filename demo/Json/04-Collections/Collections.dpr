program Collections;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Lists, dictionaries and nested objects.

  Collections are recognised by ancestry, so TObjectList<T>, TList<T>,
  TDictionary<K,V> and your own descendants of them all work without being
  registered anywhere. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Generics.Collections,
  PascalForge.Json in '..\..\..\src\PascalForge.Json.pas';

type
  TLineItem = class
  public
    Sku: string;
    Quantity: Integer;
  end;

  { An ordinary descendant. Nothing special is needed to make it serialize as
    an array. }
  TLineItems = class(TObjectList<TLineItem>);

  TOrder = class
  private
    FLines: TLineItems;
    FLabels: TDictionary<string, string>;
    FTags: TList<string>;
  public
    Reference: string;
    constructor Create;
    destructor Destroy; override;
    property Lines: TLineItems read FLines;
    property Labels: TDictionary<string, string> read FLabels;
    property Tags: TList<string> read FTags;
  end;

constructor TOrder.Create;
begin
  inherited Create;
  { The list owns its items, so it disposes of them - the serializer never
    guesses about ownership, it asks the container. }
  FLines := TLineItems.Create(True);
  FLabels := TDictionary<string, string>.Create;
  FTags := TList<string>.Create;
end;

destructor TOrder.Destroy;
begin
  FTags.Free;
  FLabels.Free;
  FLines.Free;
  inherited Destroy;
end;

function NewLine(const ASku: string; AQuantity: Integer): TLineItem;
begin
  Result := TLineItem.Create;
  Result.Sku := ASku;
  Result.Quantity := AQuantity;
end;

var
  Order, Restored: TOrder;
  Json: string;
  Line: TLineItem;

begin
  Order := TOrder.Create;
  try
    Order.Reference := 'ORD-1';
    Order.Lines.Add(NewLine('APPLE', 3));
    Order.Lines.Add(NewLine('PEAR', 1));
    Order.Labels.Add('channel', 'web');
    Order.Tags.Add('priority');

    Json := TJsonSerializer.Serialize(Order);
  finally
    Order.Free;
  end;

  Writeln(Json);

  Restored := TJsonSerializer.Deserialize<TOrder>(Json);
  try
    Writeln;
    Writeln('lines      : ', Restored.Lines.Count);
    for Line in Restored.Lines do
      Writeln('  ', Line.Sku, ' x', Line.Quantity);
    Writeln('channel    : ', Restored.Labels['channel']);
  finally
    { One Free: the order owns its lists and the lists own their items. }
    Restored.Free;
  end;
end.
