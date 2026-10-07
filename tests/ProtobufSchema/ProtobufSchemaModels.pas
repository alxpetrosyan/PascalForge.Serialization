unit ProtobufSchemaModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{$SCOPEDENUMS ON}

{ Two families of contract, for two different jobs.

  THE FIRST is descriptor.proto itself - enough of it to BUILD a
  FileDescriptorSet. There is no protoc on this machine, and a descriptor set
  is an ordinary protobuf message, so the test writes one with this library's
  own engine and then hands the bytes to the descriptor reader. That makes
  the encoder and the reader independent of one another: a mistake in either
  shows up as a disagreement rather than as two matching mistakes.

  The field numbers below are descriptor.proto's, and they are the reason the
  members have the names they do. Where a .proto name is a Delphi keyword the
  member is renamed and the number keeps the meaning.

  THE SECOND is the shop schema the descriptor describes. Written out in
  prose rather than in .proto syntax, because a brace inside a Delphi comment
  ends it:

      syntax proto3, package shop.

      enum Status         STATUS_NEW = 0, STATUS_PAID = 5,
                          STATUS_SHIPPED = 10

      message Line        string sku = 1
                          int32 quantity = 2
                          double unit_price = 3

      message Order       int64 id = 1
                          string reference = 2
                          Status status = 3
                          repeated Line lines = 4
                          repeated int32 tags = 5
                          map of string to string labels = 6
                          bytes signature = 7
                          google.protobuf.Timestamp placed = 8
                          bool paid = 9
                          uint64 big = 10
                          sint64 delta = 11

  and one more, for the question of who decides a scalar:

      message Shipment     double amount = 1

  whose Delphi member is a Currency, which this library writes as an sint64
  unless a descriptor says otherwise. }

interface

uses
  System.SysUtils, System.Generics.Collections,
  PascalForge.Nullable,
  PascalForge.Protobuf;

type
  { ------------------------------------------- descriptor.proto, in part --- }

  TDFieldOptions = class
  public
    [ProtoField(2)] IsPacked: TNullable<Boolean>;
  end;

  TDMessageOptions = class
  public
    [ProtoField(7)] MapEntry: TNullable<Boolean>;
  end;

  { FieldDescriptorProto. Label and Type are keywords here, so they are Lbl
    and Kind; the numbers are what descriptor.proto says. }
  TDField = class
  public
    [ProtoField(1)] Name: string;
    [ProtoField(3)] Number: Integer;
    [ProtoField(4)] Lbl: Integer;
    [ProtoField(5)] Kind: Integer;
    [ProtoField(6)] TypeName: string;
    [ProtoField(8)] Options: TDFieldOptions;
    [ProtoField(10)] JsonName: string;
    destructor Destroy; override;
  end;

  TDEnumValue = class
  public
    [ProtoField(1)] Name: string;
    [ProtoField(2)] Number: Integer;
  end;

  TDEnum = class
  public
    [ProtoField(1)] Name: string;
    [ProtoField(2)] Values: TObjectList<TDEnumValue>;
    constructor Create;
    destructor Destroy; override;
  end;

  { DescriptorProto. It contains a list of itself, because a message may
    declare nested messages - and a map field's entry type is exactly that. }
  TDMessage = class
  public
    [ProtoField(1)] Name: string;
    [ProtoField(2)] Fields: TObjectList<TDField>;
    [ProtoField(3)] Nested: TObjectList<TDMessage>;
    [ProtoField(4)] Enums: TObjectList<TDEnum>;
    [ProtoField(7)] Options: TDMessageOptions;
    constructor Create;
    destructor Destroy; override;
  end;

  TDFile = class
  public
    [ProtoField(1)] Name: string;
    [ProtoField(2)] Package: string;
    [ProtoField(4)] Messages: TObjectList<TDMessage>;
    [ProtoField(5)] Enums: TObjectList<TDEnum>;
    [ProtoField(12)] Syntax: string;
    constructor Create;
    destructor Destroy; override;
  end;

  TDFileSet = class
  public
    [ProtoField(1)] Files: TObjectList<TDFile>;
    constructor Create;
    destructor Destroy; override;
  end;

  { ------------------------------------------------------ the shop schema --- }

  { The Delphi ordinals are 0, 1, 2 and the .proto numbers are 0, 5, 10, which
    is what RegisterEnumNumbers is for. }
  TStatus = (Fresh, Paid, Shipped);

  TLine = class
  public
    [ProtoField(1)] Sku: string;
    [ProtoField(2)] Quantity: Integer;
    [ProtoField(3)] UnitPrice: Double;
    constructor Create; overload;
    constructor Create(const ASku: string; AQuantity: Integer;
      AUnitPrice: Double); overload;
  end;

  TOrder = class
  public
    [ProtoField(1)] Id: Int64;
    [ProtoField(2)] Reference: string;
    [ProtoField(3)] Status: TStatus;
    [ProtoField(4)] Lines: TObjectList<TLine>;
    [ProtoField(5)] Tags: TArray<Integer>;
    [ProtoField(6)] Labels: TDictionary<string, string>;
    [ProtoField(7)] Signature: TBytes;
    [ProtoField(8)] Placed: TDateTime;
    [ProtoField(9)] Paid: Boolean;
    [ProtoField(10), ProtoType(TProtoScalar.UInt64)] Big: UInt64;
    [ProtoField(11), ProtoType(TProtoScalar.SInt64)] Delta: Int64;
    constructor Create;
    destructor Destroy; override;
  end;

  { A Currency, which the engine writes as an sint64 unless a descriptor says
    the .proto declares a double. }
  TShipment = class
  public
    [ProtoField(1)] Amount: Currency;
  end;

  { The same message seen by a program that was compiled against a narrower
    .proto - for the unknown-field envelope. }
  TNarrowOrder = class
  public
    [ProtoField(1)] Id: Int64;
    [ProtoField(2)] Reference: string;
  end;

implementation

destructor TDField.Destroy;
begin
  Options.Free;
  inherited;
end;

constructor TDEnum.Create;
begin
  inherited;
  Values := TObjectList<TDEnumValue>.Create(True);
end;

destructor TDEnum.Destroy;
begin
  Values.Free;
  inherited;
end;

constructor TDMessage.Create;
begin
  inherited;
  Fields := TObjectList<TDField>.Create(True);
  Nested := TObjectList<TDMessage>.Create(True);
  Enums := TObjectList<TDEnum>.Create(True);
end;

destructor TDMessage.Destroy;
begin
  Options.Free;
  Enums.Free;
  Nested.Free;
  Fields.Free;
  inherited;
end;

constructor TDFile.Create;
begin
  inherited;
  Messages := TObjectList<TDMessage>.Create(True);
  Enums := TObjectList<TDEnum>.Create(True);
end;

destructor TDFile.Destroy;
begin
  Enums.Free;
  Messages.Free;
  inherited;
end;

constructor TDFileSet.Create;
begin
  inherited;
  Files := TObjectList<TDFile>.Create(True);
end;

destructor TDFileSet.Destroy;
begin
  Files.Free;
  inherited;
end;

constructor TLine.Create;
begin
  inherited;
end;

constructor TLine.Create(const ASku: string; AQuantity: Integer;
  AUnitPrice: Double);
begin
  inherited Create;
  Sku := ASku;
  Quantity := AQuantity;
  UnitPrice := AUnitPrice;
end;

constructor TOrder.Create;
begin
  inherited;
  Lines := TObjectList<TLine>.Create(True);
  Labels := TDictionary<string, string>.Create;
end;

destructor TOrder.Destroy;
begin
  Labels.Free;
  Lines.Free;
  inherited;
end;

end.
