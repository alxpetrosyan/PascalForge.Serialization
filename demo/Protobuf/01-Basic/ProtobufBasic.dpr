program ProtobufBasic;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Protocol Buffers, and the one thing that makes it different.

  Protobuf has no member names on the wire. A message is a sequence of
  (field number, wire type, payload), and nothing in the bytes says what a
  field means. So the schema is the Delphi type plus one number per member -
  and a member without a number is not serialized, because there is nothing
  to fall back on.

  That is also why protobuf is the smallest of the four formats by some
  margin, and why it cannot be read without a schema at all.

  Build:  ..\..\..\scripts\dcc.cmd ProtobufBasic.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.DateUtils, System.Generics.Collections,
  PascalForge.Serialization.Core in '..\..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\..\src\PascalForge.Nullable.pas',
  PascalForge.Protobuf in '..\..\..\src\PascalForge.Protobuf.pas',
  PascalForge.Json in '..\..\..\src\PascalForge.Json.pas',
  PascalForge.Json.Registration in '..\..\..\src\PascalForge.Json.Registration.pas',
  PascalForge.Protobuf.Registration in '..\..\..\src\PascalForge.Protobuf.Registration.pas';

type
  TLine = class
  public
    [ProtoField(1)] [JsonName('sku')] Sku: string;
    [ProtoField(2)] [JsonName('qty')] Qty: Integer;
  end;

  TOrder = class
  public
    [ProtoField(1)] [JsonName('id')]
    Id: Int64;

    [ProtoField(2)] [JsonName('ref')]
    Reference: string;

    { Zig-zag, because this one is often negative. As an int64 it would cost
      ten bytes; as an sint64 it costs one. }
    [ProtoField(3), ProtoType(TProtoScalar.SInt64)] [JsonName('delta')]
    Delta: Int64;

    { Implicit presence: zero is not written at all. }
    [ProtoField(4)] [JsonName('count')]
    Count: Integer;

    { Explicit presence: written whenever it is set, zero included - which
      is the only way to tell "zero" from "not set". }
    [ProtoField(5)] [JsonName('limit')]
    Limit: TNullable<Integer>;

    [ProtoField(6)] [JsonName('lines')]
    Lines: TObjectList<TLine>;

    { No number, so not on the wire. Protobuf has no names to fall back on. }
    Scratch: string;

    constructor Create;
    destructor Destroy; override;
  end;

constructor TOrder.Create;
begin
  inherited Create;
  Lines := TObjectList<TLine>.Create(True);
end;

destructor TOrder.Destroy;
begin
  Lines.Free;
  inherited Destroy;
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

function NewOrder: TOrder;
var
  L: TLine;
begin
  Result := TOrder.Create;
  Result.Id := 4711;
  Result.Reference := 'ORD-0007';
  Result.Delta := -25;
  Result.Count := 0;            { the default, so not written }
  Result.Limit := 0;            { set to the default, so it IS written }
  L := TLine.Create; L.Sku := 'A-1'; L.Qty := 2; Result.Lines.Add(L);
  L := TLine.Create; L.Sku := 'B-2'; L.Qty := 5; Result.Lines.Add(L);
  Result.Scratch := 'never leaves the process';
end;

var
  Order, Back: TOrder;
  Data: TBytes;
  Json: string;
  Raised: string;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TJsonSerializationRegistration.RegisterFormat;
  TProtobufSerializationRegistration.RegisterFormat;
  Rule('a message, and its bytes');

  Order := NewOrder;
  try
    Data := TProtobufSerializer.Serialize<TOrder>(Order);
    Json := TJsonSerializer.Serialize<TOrder>(Order);
  finally
    Order.Free;
  end;

  Writeln('  ', Hex(Data));
  Writeln;
  Writeln(Format('protobuf: %d bytes', [Length(Data)]));
  Writeln(Format('JSON    : %d bytes', [Length(Json)]));
  Writeln('  ', Json);
  Writeln;
  Writeln('The difference is the names. "08" is field 1, wire type 0 - not');
  Writeln('the four letters i, d and a colon and a quote.');

  Back := TProtobufSerializer.Deserialize<TOrder>(Data);
  try
    Writeln;
    Writeln('  id      = ', Back.Id);
    Writeln('  ref     = ', Back.Reference);
    Writeln('  delta   = ', Back.Delta);
    Writeln('  count   = ', Back.Count, '   (absent, so the default)');
    Writeln('  limit   = ', Back.Limit.Value, '   set? ',
      BoolToStr(Back.Limit.HasValue, True));
    Writeln('  lines   = ', Back.Lines.Count);
    Writeln('  scratch = "', Back.Scratch, '"   (no field number)');
  finally
    Back.Free;
  end;

  { ---------------------------------------------------------------------- }
  Rule('zig-zag, and why it is worth asking for');

  Writeln('Delta is -25, declared as sint64. A negative varint is');
  Writeln('sign-extended to 64 bits before it is written, so as a plain');
  Writeln('int64 it would take ten bytes. As an sint64 it takes one.');

  { ---------------------------------------------------------------------- }
  Rule('conversion: with a contract, and without');

  Writeln('Contract-aware works in every direction, because the Delphi type');
  Writeln('is the schema:');
  Writeln;
  Writeln('  ', TJsonSerializer.From<TOrder>(Data,
    TSerializationFormat.Protobuf));

  Writeln;
  Writeln('Structural does not, and says why rather than guessing:');
  Raised := '';
  try
    TSerialization.Convert(TSerializationPayload.FromBytes(Data),
      TSerializationFormat.Protobuf, TSerializationFormat.Json);
  except
    on E: Exception do Raised := E.ClassName + ': ' + E.Message;
  end;
  Writeln;
  Writeln(Raised);
  Writeln;
  Writeln('A length-delimited field might be a string, a byte array, a');
  Writeln('nested message or a packed repeated field. Without the schema');
  Writeln('there is no way to tell, so there is no honest answer to give.');
end.
