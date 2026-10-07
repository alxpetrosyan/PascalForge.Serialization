program XmlCollections;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Lists, arrays and dictionaries, and the three ways to shape them.

  Build:  ..\..\..\scripts\dcc.cmd XmlCollections.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Generics.Collections,
  PascalForge.Xml in '..\..\..\src\PascalForge.Xml.pas';

type
  TLine = class
  public
    Sku: string;
    Quantity: Integer;
  end;

  TLines = class(TObjectList<TLine>)
  end;

  TBasket = class
  public
    { The default: a wrapper named after the member, with one element per
      item named after the item's own type. }
    Lines: TLines;

    { The wrapper renamed, and the items too. }
    [XmlArray('Extras')] [XmlItemName('Extra')]
    More: TLines;

    { No wrapper at all: the items become repeated siblings of their owner. }
    [XmlArray('')] [XmlItemName('Tag')]
    Tags: TArray<string>;

    { A dictionary is entries carrying their key as an attribute, which keeps
      one entry to one element whatever the value turns out to be. }
    Rates: TDictionary<string, Currency>;

    constructor Create;
    destructor Destroy; override;
  end;

constructor TBasket.Create;
begin
  inherited Create;
  Lines := TLines.Create;
  More := TLines.Create;
  Rates := TDictionary<string, Currency>.Create;
end;

destructor TBasket.Destroy;
begin
  Rates.Free;
  More.Free;
  Lines.Free;
  inherited Destroy;
end;

function NewLine(const ASku: string; AQty: Integer): TLine;
begin
  Result := TLine.Create;
  Result.Sku := ASku;
  Result.Quantity := AQty;
end;

var
  Basket, Back: TBasket;
  Xml: string;
  Options: TXmlSerializationOptions;

begin
  Options := TXmlSerializationOptions.Default;
  Options.Indent := True;

  Basket := TBasket.Create;
  try
    Basket.Lines.Add(NewLine('A-1', 2));
    Basket.Lines.Add(NewLine('B-2', 5));
    Basket.More.Add(NewLine('GIFT', 1));
    Basket.Tags := ['red', 'blue'];
    Basket.Rates.Add('USD', 1.0);
    Xml := TXmlSerializer.Serialize<TBasket>(Basket, Options);
  finally
    Basket.Free;
  end;
  Writeln(Xml);

  Back := TXmlSerializer.Deserialize<TBasket>(Xml);
  try
    Writeln;
    Writeln(Format('back: %d lines, %d extras, %d tags, %d rates',
      [Back.Lines.Count, Back.More.Count, Length(Back.Tags),
       Back.Rates.Count]));
  finally
    Back.Free;
  end;

  Writeln;
  Writeln('A container that already exists is refilled, never replaced, so');
  Writeln('whatever owns its elements keeps owning them.');
end.
