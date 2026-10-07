program CustomSerialization;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ When the default encoding of a member is not what you want.

  Everything here is written against a concrete Delphi type. None of it
  mentions TValue or PTypeInfo - those belong to the advanced, dynamic
  extension points (a serializer that handles several runtime types, or a
  whole generic family), which are documented separately and are not what a
  normal custom serializer needs. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.JSON,
  PascalForge.Json in '..\..\..\src\PascalForge.Json.pas';

type
  { A small value object. On the wire it should be one string, not an
    object with an Amount and a Currency member. }
  TMoney = record
    Amount: Currency;
    Code: string;
    function ToText: string;
    class function Parse(const AText: string): TMoney; static;
  end;

  TInvoice = class
  public
    Reference: string;
    Total: TMoney;
    Comment: string;
    Barcode: string;
  end;

  { A serializer class, written against TMoney. Two methods, no plumbing. }
  TMoneySerializer = class(TCustomJsonValueSerializer<TMoney>)
  public
    function SerializeValue(const AValue: TMoney): TJSONValue; override;
    function DeserializeValue(const AJson: TJSONValue): TMoney; override;
  end;

function TMoney.ToText: string;
begin
  Result := Format('%s %s', [CurrToStr(Amount, TFormatSettings.Invariant), Code]);
end;

class function TMoney.Parse(const AText: string): TMoney;
var
  P: Integer;
begin
  P := AText.IndexOf(' ');
  Result.Amount := StrToCurr(AText.Substring(0, P), TFormatSettings.Invariant);
  Result.Code := AText.Substring(P + 1);
end;

function TMoneySerializer.SerializeValue(const AValue: TMoney): TJSONValue;
begin
  Result := TJSONString.Create(AValue.ToText);
end;

function TMoneySerializer.DeserializeValue(const AJson: TJSONValue): TMoney;
begin
  Result := TMoney.Parse(AJson.Value);
end;

var
  Invoice, Restored: TInvoice;
  Json: string;

begin
  { 1. A serializer class, for every TMoney anywhere. The two type parameters
       are checked by the compiler: a serializer that does not handle TMoney
       will not compile here. }
  TJsonSerializer.RegisterTypeSerializer<TMoney, TMoneySerializer>;

  { 2. A transformation too small to deserve a class: two inline functions,
       for one member. }
  TJsonSerializer.RegisterFieldOverride<TInvoice>('Comment',
    TJsonFieldOverride.SerializeWith<string>(
      function(const AValue: string): TJSONValue
      begin
        Result := TJSONString.Create(AValue.Trim);
      end,
      function(const AJson: TJSONValue): string
      begin
        Result := AJson.Value.Trim;
      end));

  { 3. One direction only. Writing is customised; reading keeps doing exactly
       what it would have done with no registration at all. There is no
       pass-through function to write, and nothing fails because the other
       direction is absent. }
  TJsonSerializer.RegisterFieldOverride<TInvoice>('Barcode',
    TJsonFieldOverride.SerializeWith<string>(
      function(const AValue: string): TJSONValue
      begin
        Result := TJSONString.Create('*' + AValue + '*');
      end));

  Invoice := TInvoice.Create;
  try
    Invoice.Reference := 'INV-1';
    Invoice.Total.Amount := 1250.75;
    Invoice.Total.Code := 'EUR';
    Invoice.Comment := '   please pay promptly   ';
    Invoice.Barcode := '12345';

    Json := TJsonSerializer.Serialize(Invoice);
  finally
    Invoice.Free;
  end;

  Writeln(Json);
  Writeln;

  Restored := TJsonSerializer.Deserialize<TInvoice>(Json);
  try
    Writeln('amount     : ', CurrToStr(Restored.Total.Amount));
    Writeln('currency   : ', Restored.Total.Code);
    Writeln('comment    : "', Restored.Comment, '"');
    { No read function was registered for Barcode, so the built-in string
      reader ran and the asterisks the writer added are part of the value. }
    Writeln('barcode    : ', Restored.Barcode, '   <- read back verbatim');
  finally
    Restored.Free;
  end;
end.
