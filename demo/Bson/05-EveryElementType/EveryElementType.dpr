program EveryElementType;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The parts of BSON that are not in JSON.

  BSON has twenty-two element types. Nine of them are the ones every format
  has; the rest are why you would choose BSON in the first place - an
  ObjectId, a decimal128, a timestamp that is not a date.

  This demo shows three things:

    1. TBsonObjectId as an ordinary member of an ordinary DTO;
    2. the element types Delphi has no counterpart for, through TBsonValue;
    3. what happens to those when the document is converted to JSON, which
       has none of them.

  Build:  ..\..\..\scripts\dcc.cmd EveryElementType.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.DateUtils,
  PascalForge.Serialization.Core in '..\..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\..\src\PascalForge.Serialization.pas',
  PascalForge.Bson in '..\..\..\src\PascalForge.Bson.pas',
  PascalForge.Json in '..\..\..\src\PascalForge.Json.pas',
  PascalForge.Json.Registration in '..\..\..\src\PascalForge.Json.Registration.pas',
  PascalForge.Bson.Registration in '..\..\..\src\PascalForge.Bson.Registration.pas';

type
  { The everyday case. An _id is an ObjectId, and saying so is all it takes. }
  TOrder = class
  public
    [BsonName('_id')]
    Id: TBsonObjectId;

    [BsonName('ref')]
    Reference: string;

    [BsonName('total')]
    Total: Currency;

    [BsonName('placed')]
    Placed: TDateTime;
  end;

procedure Rule(const ATitle: string);
begin
  Writeln;
  Writeln('== ', ATitle, ' ', StringOfChar('=', 56 - Length(ATitle)));
end;

function Hex(const ABytes: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ABytes) do
  begin
    if (I > 0) and (I mod 16 = 0) then Result := Result + sLineBreak + '  ';
    Result := Result + IntToHex(ABytes[I], 2) + ' ';
  end;
end;

var
  Order, Back: TOrder;
  Data: TBytes;
  Doc, Scope: TBsonValue;
  Json: TSerializationPayload;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TJsonSerializationRegistration.RegisterFormat;
  TBsonSerializationRegistration.RegisterFormat;
  Rule('an ObjectId is an ordinary member');

  Order := TOrder.Create;
  try
    Order.Id := TBsonObjectId.FromHex('507f1f77bcf86cd799439011');
    Order.Reference := 'ORD-0007';
    Order.Total := 1234.5678;
    Order.Placed := EncodeDateTime(2026, 3, 14, 9, 26, 53, 0);
    Data := TBsonSerializer.Serialize<TOrder>(Order);
  finally
    Order.Free;
  end;

  Writeln('  ', Hex(Data));
  Writeln;
  Writeln('The 07 byte after the first "_id" is the ObjectId element type,');
  Writeln('and the twelve bytes after the name are the identifier itself -');
  Writeln('not a 24-character string, which is what it would have been in');
  Writeln('JSON and would have cost twice the space.');

  Back := TBsonSerializer.Deserialize<TOrder>(Data);
  try
    Writeln;
    Writeln('  id      = ', Back.Id.ToHex);
    Writeln('  ref     = ', Back.Reference);
    Writeln('  total   = ', CurrToStr(Back.Total));
    Writeln('  placed  = ', DateTimeToStr(Back.Placed));
  finally
    Back.Free;
  end;

  { ---------------------------------------------------------------------- }
  Rule('the types Delphi has no counterpart for');

  Doc := TBsonValue.NewDocument;
  try
    Doc.Add('_id', TBsonValue.NewObjectId(
      TBsonObjectId.FromHex('507f1f77bcf86cd799439011')));
    { A MongoDB timestamp: seconds in the high word, an increment in the low
      word. It is NOT a datetime and is deliberately not turned into one. }
    Doc.Add('ts', TBsonValue.NewTimestamp((UInt64(1773500000) shl 32) or 7));
    { Sixteen bytes, carried exactly. Delphi has no 128-bit decimal, so no
      arithmetic is offered and none is attempted. }
    Doc.Add('price', TBsonValue.NewDecimal128(
      TBytes.Create($01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $40, $3C)));
    Doc.Add('pattern', TBsonValue.NewRegex('^ORD-[0-9]+$', 'i'));
    Doc.Add('validate', TBsonValue.NewJavaScript('this.total > 0'));
    Scope := TBsonValue.NewDocument;
    Scope.Add('limit', TBsonValue.NewInt32(100));
    Doc.Add('rule', TBsonValue.NewJavaScriptScope('this.total < limit', Scope));
    Doc.Add('lowest', TBsonValue.NewMinKey);
    Doc.Add('highest', TBsonValue.NewMaxKey);
    Doc.Add('md5', TBsonValue.NewBinary(TBytes.Create(1, 2, 3), Byte($05)));

    Data := TBsonSerializer.WriteDocument(Doc);
  finally
    Doc.Free;
  end;
  Writeln('  ', Length(Data), ' bytes, nine elements, seven of them types');
  Writeln('  JSON does not have at all.');

  Doc := TBsonSerializer.ParseDocument(Data);
  try
    Writeln;
    Writeln('  _id      ', Doc.Find('_id').AsObjectId.ToHex);
    Writeln('  ts       ', Doc.Find('ts').AsTimestamp,
      '   (', Doc.Find('ts').Describe, ')');
    Writeln('  price    ', Doc.Find('price').Describe);
    Writeln('  pattern  /', Doc.Find('pattern').AsPattern, '/',
      Doc.Find('pattern').AsOptions);
    Writeln('  validate ', Doc.Find('validate').AsCode);
    Writeln('  rule     ', Doc.Find('rule').AsCode, '  with limit=',
      Doc.Find('rule').Scope.Find('limit').AsInt64);
    Writeln('  md5      subtype ', Doc.Find('md5').SubtypeByte);
  finally
    Doc.Free;
  end;

  { ---------------------------------------------------------------------- }
  Rule('and what JSON makes of them');

  Json := TSerialization.Convert(TSerializationPayload.FromBytes(Data),
    TSerializationFormat.Bson, TSerializationFormat.Json,
    TStructuralConversionProfile.Natural);
  Writeln(Json.AsText);
  Writeln;
  Writeln('That is the Natural profile: the idiomatic JSON for each one - a');
  Writeln('hex string for an ObjectId, digits for a decimal128. Readable,');
  Writeln('and not reversible, because nothing in it says what it was.');
  Writeln;

  Rule('and the same document, losslessly');

  Json := TSerialization.Convert(TSerializationPayload.FromBytes(Data),
    TSerializationFormat.Bson, TSerializationFormat.Json,
    TStructuralConversionProfile.Lossless);
  Writeln(Json.AsText);
  Writeln;
  Writeln('That is MongoDB Extended JSON - a PUBLISHED standard for exactly');
  Writeln('this problem, so the result round trips here and reads in mongosh,');
  Writeln('in every MongoDB driver, and in anything else that implements it.');
  Writeln('This library does not invent a wrapper of its own.');

  Data := TSerialization.Convert(Json, TSerializationFormat.Json,
    TSerializationFormat.Bson, TStructuralConversionProfile.Lossless).AsBytes;
  Doc := TBsonSerializer.ParseDocument(Data);
  try
    Writeln;
    Writeln('back from JSON:');
    Writeln('  _id      is ', Doc.Find('_id').Describe);
    Writeln('  ts       is ', Doc.Find('ts').Describe);
    Writeln('  price    is ', Doc.Find('price').Describe);
    Writeln('  lowest   is ', Doc.Find('lowest').Describe);
    Writeln;
    Writeln('Native again - the standard said what each one was.');
  finally
    Doc.Free;
  end;
end.
