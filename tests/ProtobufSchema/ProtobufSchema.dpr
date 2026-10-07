program ProtobufSchema;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Does a descriptor actually make protobuf self-describing?

  Protocol Buffers is the one format here that carries no names at all. A
  message is a sequence of (field number, wire type, payload), and a
  length-delimited field might be a string, a byte array, a nested message or
  a packed run of integers - the bytes do not say which. Everything this
  program checks follows from that: given the descriptor the other end was
  compiled against, does this library read and write those bytes with real
  names and real types, and does it refuse honestly when the descriptor is
  missing?

  THE TARGET, named exactly:

      descriptor.proto  FileDescriptorSet, FileDescriptorProto,
                        DescriptorProto, FieldDescriptorProto,
                        EnumDescriptorProto, EnumValueDescriptorProto,
                        MessageOptions.map_entry, FieldOptions.packed
      proto3            implicit presence, packed repeated fields by default,
                        maps as repeated two-field entry messages, an
                        unrecognized enum number kept rather than rejected
      the well-known    google.protobuf.Timestamp

  THE ORACLE. There is no protoc on this machine, so the descriptor set is
  BUILT HERE - written by this library's contract-aware engine from Delphi
  types that mirror descriptor.proto, and then read back by the descriptor
  reader, which shares no code with the writer. A mistake in either half
  shows up as a disagreement. Where a byte sequence can be computed by hand
  from the specification it is written out in hex below and compared
  literally.

  WHAT IS NOT HERE, deliberately, is listed at the bottom. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Math, System.DateUtils,
  System.StrUtils, System.Generics.Collections, Data.DB, Datasnap.DBClient,
  ProtobufSchemaModels in 'ProtobufSchemaModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Protobuf in '..\..\src\PascalForge.Protobuf.pas',
  PascalForge.Protobuf.Internal in '..\..\src\PascalForge.Protobuf.Internal.pas',
  PascalForge.Protobuf.Schema in '..\..\src\PascalForge.Protobuf.Schema.pas',
  PascalForge.Protobuf.Registration in '..\..\src\PascalForge.Protobuf.Registration.pas',
  PascalForge.DataSet in '..\..\src\PascalForge.DataSet.pas',
  PascalForge.DataSet.Internal in '..\..\src\PascalForge.DataSet.Internal.pas',
  AllFormatsRegistered in '..\Shared\AllFormatsRegistered.pas';

var
  GFailures: Integer = 0;
  GChecks: Integer = 0;

procedure Check(ACondition: Boolean; const AName: string);
begin
  Inc(GChecks);
  if ACondition then
    Writeln(AName, ': PASS')
  else
  begin
    Writeln(AName, ': FAIL');
    Inc(GFailures);
  end;
end;

procedure Note(const AText: string);
begin
  Writeln('  ', AText);
end;

function Hex(const AData: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AData) do Result := Result + IntToHex(AData[I], 2);
  Result := LowerCase(Result);
end;

{ True when the call raised an exception of ACls, whatever it said. }
function RaisesClass(AProc: TProc; ACls: ExceptClass; out AMessage: string): Boolean;
begin
  AMessage := '';
  try
    AProc();
    Result := False;
  except
    on E: Exception do
    begin
      AMessage := E.ClassName + ': ' + E.Message;
      Result := E is ACls;
    end;
  end;
end;

function Raises(AProc: TProc; out AMessage: string): Boolean;
begin
  Result := RaisesClass(AProc, Exception, AMessage);
end;

{ =========================================================================
  BUILDING A DESCRIPTOR SET

  descriptor.proto's own numbers, written out so that the calls below read
  like the specification.
  ========================================================================= }

const
  T_DOUBLE = 1; T_FLOAT = 2; T_INT64 = 3; T_UINT64 = 4; T_INT32 = 5;
  T_FIXED64 = 6; T_FIXED32 = 7; T_BOOL = 8; T_STRING = 9;
  T_MESSAGE = 11; T_BYTES = 12; T_UINT32 = 13; T_ENUM = 14;
  T_SFIXED32 = 15; T_SFIXED64 = 16; T_SINT32 = 17; T_SINT64 = 18;

  L_OPTIONAL = 1; L_REQUIRED = 2; L_REPEATED = 3;

function NewField(AMsg: TDMessage; const AName: string;
  ANumber, AKind, ALbl: Integer; const ATypeName: string = ''): TDField;
begin
  Result := TDField.Create;
  Result.Name := AName;
  Result.Number := ANumber;
  Result.Kind := AKind;
  Result.Lbl := ALbl;
  Result.TypeName := ATypeName;
  AMsg.Fields.Add(Result);
end;

procedure NewEnumValue(AEnum: TDEnum; const AName: string; ANumber: Integer);
var
  V: TDEnumValue;
begin
  V := TDEnumValue.Create;
  V.Name := AName;
  V.Number := ANumber;
  AEnum.Values.Add(V);
end;

{ google/protobuf/timestamp.proto, shop.proto. }
function BuildShopDescriptor: TBytes;
var
  FileSet: TDFileSet;
  F: TDFile;
  M, Entry: TDMessage;
  E: TDEnum;
begin
  FileSet := TDFileSet.Create;
  try
    F := TDFile.Create;
    F.Name := 'google/protobuf/timestamp.proto';
    F.Package := 'google.protobuf';
    F.Syntax := 'proto3';
    M := TDMessage.Create;
    M.Name := 'Timestamp';
    NewField(M, 'seconds', 1, T_INT64, L_OPTIONAL);
    NewField(M, 'nanos', 2, T_INT32, L_OPTIONAL);
    F.Messages.Add(M);
    FileSet.Files.Add(F);

    F := TDFile.Create;
    F.Name := 'shop.proto';
    F.Package := 'shop';
    F.Syntax := 'proto3';

    E := TDEnum.Create;
    E.Name := 'Status';
    NewEnumValue(E, 'STATUS_NEW', 0);
    NewEnumValue(E, 'STATUS_PAID', 5);
    NewEnumValue(E, 'STATUS_SHIPPED', 10);
    F.Enums.Add(E);

    M := TDMessage.Create;
    M.Name := 'Line';
    NewField(M, 'sku', 1, T_STRING, L_OPTIONAL);
    NewField(M, 'quantity', 2, T_INT32, L_OPTIONAL);
    { No json_name here: the reader must compute unitPrice itself. }
    NewField(M, 'unit_price', 3, T_DOUBLE, L_OPTIONAL);
    F.Messages.Add(M);

    M := TDMessage.Create;
    M.Name := 'Order';
    NewField(M, 'id', 1, T_INT64, L_OPTIONAL);
    NewField(M, 'reference', 2, T_STRING, L_OPTIONAL);
    NewField(M, 'status', 3, T_ENUM, L_OPTIONAL, '.shop.Status');
    NewField(M, 'lines', 4, T_MESSAGE, L_REPEATED, '.shop.Line');
    NewField(M, 'tags', 5, T_INT32, L_REPEATED);
    NewField(M, 'labels', 6, T_MESSAGE, L_REPEATED, '.shop.Order.LabelsEntry');
    NewField(M, 'signature', 7, T_BYTES, L_OPTIONAL);
    NewField(M, 'placed', 8, T_MESSAGE, L_OPTIONAL,
      '.google.protobuf.Timestamp');
    NewField(M, 'paid', 9, T_BOOL, L_OPTIONAL);
    NewField(M, 'big', 10, T_UINT64, L_OPTIONAL);
    NewField(M, 'delta', 11, T_SINT64, L_OPTIONAL);

    Entry := TDMessage.Create;
    Entry.Name := 'LabelsEntry';
    Entry.Options := TDMessageOptions.Create;
    Entry.Options.MapEntry := True;
    NewField(Entry, 'key', 1, T_STRING, L_OPTIONAL);
    NewField(Entry, 'value', 2, T_STRING, L_OPTIONAL);
    M.Nested.Add(Entry);

    F.Messages.Add(M);
    FileSet.Files.Add(F);

    Result := TProtobufSerializer.Serialize<TDFileSet>(FileSet);
  finally
    FileSet.Free;
  end;
end;

{ ship.proto: message Shipment - double amount = 1. }
function BuildShipmentDescriptor: TBytes;
var
  FileSet: TDFileSet;
  F: TDFile;
  M: TDMessage;
begin
  FileSet := TDFileSet.Create;
  try
    F := TDFile.Create;
    F.Name := 'ship.proto';
    F.Package := 'ship';
    F.Syntax := 'proto3';
    M := TDMessage.Create;
    M.Name := 'Shipment';
    NewField(M, 'amount', 1, T_DOUBLE, L_OPTIONAL);
    F.Messages.Add(M);
    FileSet.Files.Add(F);
    Result := TProtobufSerializer.Serialize<TDFileSet>(FileSet);
  finally
    FileSet.Free;
  end;
end;

{ A proto2 file with a required field, for the one thing proto3 cannot say. }
function BuildRequiredDescriptor: TBytes;
var
  FileSet: TDFileSet;
  F: TDFile;
  M: TDMessage;
begin
  FileSet := TDFileSet.Create;
  try
    F := TDFile.Create;
    F.Name := 'old.proto';
    F.Package := 'old';
    F.Syntax := 'proto2';
    M := TDMessage.Create;
    M.Name := 'Record2';
    NewField(M, 'id', 1, T_INT32, L_REQUIRED);
    NewField(M, 'note', 2, T_STRING, L_OPTIONAL);
    NewField(M, 'scores', 3, T_INT32, L_REPEATED);
    F.Messages.Add(M);
    FileSet.Files.Add(F);
    Result := TProtobufSerializer.Serialize<TDFileSet>(FileSet);
  finally
    FileSet.Free;
  end;
end;

{ A field whose type is not in the set, so that resolution has something to
  refuse. }
function BuildDanglingDescriptor: TBytes;
var
  FileSet: TDFileSet;
  F: TDFile;
  M: TDMessage;
begin
  FileSet := TDFileSet.Create;
  try
    F := TDFile.Create;
    F.Name := 'dangling.proto';
    F.Package := 'x';
    F.Syntax := 'proto3';
    M := TDMessage.Create;
    M.Name := 'Holder';
    NewField(M, 'inner', 1, T_MESSAGE, L_OPTIONAL, '.somewhere.Else');
    F.Messages.Add(M);
    FileSet.Files.Add(F);
    Result := TProtobufSerializer.Serialize<TDFileSet>(FileSet);
  finally
    FileSet.Free;
  end;
end;

{ ===========================================================================
  DESCRIPTOR A TO DESCRIPTOR B, BOTH PROTOBUF

  Both ends are Protobuf, so format identity says nothing about which
  descriptor belongs where. This is the conversion the old
  Schema/SecondSchema pair could not express, and it is the ordinary one: two
  services on two versions of the same .proto.

  B renumbers a field and renames another. If the roles were not separated -
  if one descriptor were used for both ends - the output would carry A's
  field numbers, which is precisely the silent wrong answer this is about. }

function BuildVersionedDescriptor(const APackage: string;
  AIdNumber, ANameNumber: Integer; const ANameField: string): TBytes;
var
  FileSet: TDFileSet;
  F: TDFile;
  M: TDMessage;
begin
  FileSet := TDFileSet.Create;
  try
    F := TDFile.Create;
    F.Name := APackage + '.proto';
    F.Package := APackage;
    F.Syntax := 'proto3';
    M := TDMessage.Create;
    M.Name := 'Customer';
    NewField(M, 'id', AIdNumber, T_INT64, L_OPTIONAL);
    NewField(M, ANameField, ANameNumber, T_STRING, L_OPTIONAL);
    F.Messages.Add(M);
    FileSet.Files.Add(F);
    Result := TProtobufSerializer.Serialize<TDFileSet>(FileSet);
  finally
    FileSet.Free;
  end;
end;

procedure TestSchemaAToSchemaB;
var
  A, B: TProtobufSchema;
  CtxA, CtxB: TProtobufSerializationContext;
  Options: TStructuralConversionOptions;
  InA, InB: TSerializationPayload;
  Tree: TDynamicValue;
  Caught: Boolean;
  BackJson: string;
begin
  Writeln;
  Writeln('-- descriptor A to descriptor B, both Protobuf --');

  { v1: id = 1, name = 2.  v2: id = 3, full_name = 4. Nothing is shared. }
  A := TProtobufSchema.LoadDescriptorSet(
    BuildVersionedDescriptor('v1', 1, 2, 'name'), 'v1.Customer');
  B := TProtobufSchema.LoadDescriptorSet(
    BuildVersionedDescriptor('v2', 3, 4, 'name'), 'v2.Customer');
  CtxA := TProtobufSerializationContext.Create(A, 'v1.Customer');
  CtxB := TProtobufSerializationContext.Create(B, 'v2.Customer');
  try
    { A document in A's numbering. }
    Tree := TDynamicValue.NewObject;
    try
      Tree.AsObject.Adopt('id', TDynamicValue.NewInt(7));
      Tree.AsObject.Adopt('name', TDynamicValue.NewStr('Alice'));
      InA := TSerializationPayload.FromBytes(A.FromDynamic(Tree));
    finally
      Tree.Free;
    end;
    Note('in v1: ' + Hex(InA.AsBytes));
    { Field 1 as a varint, then field 2 as a string: 08 07 12 04 ... }
    Check(InA.AsBytes[0] = $08, 'PROTOBUF_A_USES_ITS_OWN_NUMBERS');

    { A to B, with the role of each context said outright. }
    Options := TStructuralConversionOptions.FromProfile(
      TStructuralConversionProfile.Natural)
      .WithSource(TSerializationFormat.Protobuf)
      .WithDestination(TSerializationFormat.Protobuf)
      .WithSourceContext(CtxA)
      .WithDestinationContext(CtxB);

    InB := TSerialization.Convert(InA, TSerializationFormat.Protobuf,
      TSerializationFormat.Protobuf, Options);
    Note('in v2: ' + Hex(InB.AsBytes));
    Check(Length(InB.AsBytes) > 0, 'PROTOBUF_SCHEMA_A_TO_SCHEMA_B');

    { B's numbering, which is the whole point: field 3 is a varint, so the
      first tag byte is 0x18 and not 0x08. Two contexts that were not kept
      apart would have produced A's bytes again. }
    Check(InB.AsBytes[0] = $18, 'PROTOBUF_B_RENUMBERED_THE_FIELDS');

    { And the data survived the renumbering. }
    BackJson := TSerialization.Convert(InB, TSerializationFormat.Protobuf,
      TSerializationFormat.Json, TStructuralConversionProfile.Natural,
      CtxB).AsText;
    Note(BackJson);
    Check(Pos('"name":"Alice"', BackJson) > 0,
      'PROTOBUF_A_TO_B_CARRIED_THE_DATA');
    Check(Pos('7', BackJson) > 0, 'PROTOBUF_A_TO_B_CARRIED_THE_ID');

    { One context cannot say which end it is for when both ends are
      Protobuf. }
    Caught := False;
    try
      TSerialization.Convert(InA, TSerializationFormat.Protobuf,
        TSerializationFormat.Protobuf, TStructuralConversionProfile.Natural,
        CtxA);
    except
      on E: ESerializationSchemaRequired do Caught := True;
    end;
    Check(Caught, 'PROTOBUF_SAME_FORMAT_ONE_CONTEXT_IS_AMBIGUOUS');

    { Two messages from ONE descriptor set is the same mechanism: the
      context names the message, so the schema is not mutated to say it. }
    Check((CtxA.MessageFullName = 'v1.Customer') and
          (CtxB.MessageFullName = 'v2.Customer'),
      'PROTOBUF_CONTEXT_NAMES_THE_MESSAGE');
  finally
    CtxB.Free;
    CtxA.Free;
    B.Free;
    A.Free;
  end;
end;

{ =========================================================================
  A SAMPLE ORDER
  ========================================================================= }

function SampleOrder: TOrder;
begin
  Result := TOrder.Create;
  Result.Id := 4815162342;
  Result.Reference := 'ORD-0007';
  Result.Status := TStatus.Paid;
  Result.Lines.Add(TLine.Create('SKU-1', 2, 19.5));
  Result.Lines.Add(TLine.Create('SKU-2', 1, 4.25));
  Result.Tags := [7, 11, 13];
  Result.Labels.AddOrSetValue('channel', 'web');
  Result.Labels.AddOrSetValue('region', 'eu');
  Result.Signature := TBytes.Create(1, 2, 3, 250, 255);
  Result.Placed := EncodeDateTime(2024, 3, 1, 12, 30, 45, 0);
  { Left False on purpose: proto3 implicit presence means it is not written,
    and the tree must then not contain it. }
  Result.Paid := False;
  Result.Big := 9000000000;
  Result.Delta := -12345;
end;

{ =========================================================================
  THE PROGRAM
  ========================================================================= }

var
  DescBytes, ShipBytes, Wire, Back, Extra: TBytes;
  Schema, Second: TProtobufSchema;
  Msg, Line, Entry: TProtoMessageDescriptor;
  Fld: TProtoFieldDescriptor;
  Names: TArray<string>;
  Tree, Node, Child, Bad: TDynamicValue;
  Order, Restored: TOrder;
  Sample: TLine;
  Shipment: TShipment;
  Narrow: TProtobufMessage<TNarrowOrder>;
  ShipOpts: TProtobufSerializationOptions;
  Opts: TStructuralConversionOptions;
  Caps: TSerializationFormatCapabilities;
  Source, Result2: TSerializationPayload;
  Msgtext, Json: string;
  Cds: TClientDataSet;
  I, Number: Integer;
  Scalar: TProtoScalar;
  Structural: TArray<TSerializationFormat>;
  Found: Boolean;

begin
  try
    Writeln('ProtobufSchema - the descriptor model and what it makes possible');
    Writeln;

    TProtobufSerializer.RegisterEnumNumbers<TStatus>([0, 5, 10]);

    { ------------------------------------------------ 1. the descriptor --- }
    Writeln('-- reading a FileDescriptorSet --');

    DescBytes := BuildShopDescriptor;
    Note('descriptor set: ' + IntToStr(Length(DescBytes)) + ' bytes');
    Check(Length(DescBytes) > 0, 'DESCRIPTOR_SET_BUILT');

    Schema := TProtobufSchema.LoadDescriptorSet(DescBytes);
    try
      Names := Schema.MessageNames;
      Note('messages: ' + String.Join(', ', Names));
      Check(Length(Names) = 4, 'MESSAGE_COUNT');
      Check(IndexStr('shop.Order', Names) >= 0, 'MESSAGE_NAME_ORDER');
      Check(IndexStr('shop.Line', Names) >= 0, 'MESSAGE_NAME_LINE');
      Check(IndexStr('shop.Order.LabelsEntry', Names) >= 0,
        'MESSAGE_NAME_NESTED_ENTRY');
      Check(IndexStr('google.protobuf.Timestamp', Names) >= 0,
        'MESSAGE_NAME_IMPORTED');

      Msg := Schema.FindMessage('shop.Order');
      Check(Msg <> nil, 'FIND_MESSAGE');
      Check(Schema.FindMessage('.shop.Order') = Msg,
        'FIND_MESSAGE_LEADING_DOT');
      Check(Schema.FindMessage('shop.Nothing') = nil, 'FIND_MESSAGE_ABSENT');
      Check(Msg.FieldCount = 11, 'FIELD_COUNT');
      Check(Msg.NestedCount = 1, 'NESTED_COUNT');
      Check(Msg.Nested[0].IsMapEntry, 'MAP_ENTRY_OPTION_READ');
      Check(Msg.Nested[0].FullName = 'shop.Order.LabelsEntry',
        'NESTED_FULL_NAME');

      Fld := Msg.FieldByNumber(11);
      Check((Fld <> nil) and (Fld.Name = 'delta'), 'FIELD_BY_NUMBER');
      Check(Fld.FieldType = TProtoFieldType.SInt64, 'FIELD_TYPE_SINT64');
      Check(Msg.FieldByName('delta') = Fld, 'FIELD_BY_NAME');

      Line := Schema.FindMessage('shop.Line');
      Fld := Line.FieldByNumber(3);
      Check(Fld.JsonName = 'unitPrice', 'JSON_NAME_COMPUTED');
      Check(Line.FieldByName('unitPrice') = Fld, 'FIELD_BY_JSON_NAME');
      Check(Line.FieldByName('unit_price') = Fld, 'FIELD_BY_DECLARED_NAME');

      Fld := Msg.FieldByNumber(3);
      Check(Fld.EnumType <> nil, 'ENUM_RESOLVED');
      Check(Fld.EnumType.FullName = 'shop.Status', 'ENUM_FULL_NAME');
      Check(Fld.EnumType.ValueCount = 3, 'ENUM_VALUE_COUNT');
      Check(Fld.EnumType.TryNumber('STATUS_PAID', Number) and (Number = 5),
        'ENUM_NAME_TO_NUMBER');
      Check(Fld.EnumType.TryName(10, Msgtext) and
        (Msgtext = 'STATUS_SHIPPED'), 'ENUM_NUMBER_TO_NAME');
      Check(not Fld.EnumType.TryName(3, Msgtext), 'ENUM_UNKNOWN_NUMBER');

      Fld := Msg.FieldByNumber(4);
      Check(Fld.MessageType = Line, 'MESSAGE_TYPE_RESOLVED');
      Check(Fld.IsRepeated, 'LABEL_REPEATED');
      Check(not Fld.IsPacked, 'MESSAGE_IS_NEVER_PACKED');

      Fld := Msg.FieldByNumber(5);
      Check(Fld.IsRepeated and Fld.IsPackable and Fld.IsPacked,
        'PACKED_BY_PROTO3_DEFAULT');

      Fld := Msg.FieldByNumber(6);
      Check(Fld.IsMap, 'MAP_FIELD_RECOGNISED');

      Entry := Schema.FindMessage('shop.Order.LabelsEntry');
      Check((Entry.FieldByNumber(1).Name = 'key') and
            (Entry.FieldByNumber(2).Name = 'value'), 'MAP_ENTRY_SHAPE');

      { --------------------------------------- 2. which message is it --- }
      Writeln;
      Writeln('-- naming the message the bytes are --');

      Check(RaisesClass(procedure begin Schema.RootMessage end,
        EProtobufSchemaError, Msgtext), 'ROOT_AMBIGUOUS_RAISES');
      Note(Copy(Msgtext, 1, 110));
      Check(Pos('shop.Order', Msgtext) > 0, 'ROOT_ERROR_LISTS_CANDIDATES');

      Check(RaisesClass(procedure begin Schema.MessageName := 'shop.Nope' end,
        EProtobufSchemaError, Msgtext), 'ROOT_UNKNOWN_NAME_RAISES');

      Schema.MessageName := 'shop.Order';
      Check(Schema.RootMessage = Msg, 'ROOT_BY_NAME');
      Check(Schema.Format = TSerializationFormat.Protobuf, 'SCHEMA_FORMAT');
      Note('describe: ' + Schema.Describe);
      Check(Pos('shop.Order', Schema.Describe) > 0, 'SCHEMA_DESCRIBE');

      { ------------------------------- 3. the engine asks the descriptor -- }
      Writeln;
      Writeln('-- what the .proto says a field is --');

      Check(Schema.TryFieldScalar(1, Scalar) and
        (Scalar = TProtoScalar.Int64), 'TRY_FIELD_SCALAR_INT64');
      Check(Schema.TryFieldScalar(10, Scalar) and
        (Scalar = TProtoScalar.UInt64), 'TRY_FIELD_SCALAR_UINT64');
      Check(Schema.TryFieldScalar(11, Scalar) and
        (Scalar = TProtoScalar.SInt64), 'TRY_FIELD_SCALAR_SINT64');
      Check(Schema.TryFieldScalar(3, Scalar) and
        (Scalar = TProtoScalar.EnumValue), 'TRY_FIELD_SCALAR_ENUM');
      Check(not Schema.TryFieldScalar(4, Scalar),
        'TRY_FIELD_SCALAR_MESSAGE_IS_NOT_A_SCALAR');
      Check(not Schema.TryFieldScalar(99, Scalar),
        'TRY_FIELD_SCALAR_UNKNOWN_NUMBER');

      { ------------------------------------- 4. bytes into a named tree -- }
      Writeln;
      Writeln('-- a message becomes a tree with real names --');

      Order := SampleOrder;
      try
        Wire := TProtobufSerializer.Serialize<TOrder>(Order);
      finally
        Order.Free;
      end;
      Note('order: ' + IntToStr(Length(Wire)) + ' bytes');

      Tree := Schema.ToDynamic(Wire);
      try
        Check(Tree.Kind = TDynamicKind.Obj, 'TREE_IS_OBJECT');
        Check(Tree.Find('id') <> nil, 'TREE_NAME_ID');
        Check(Tree.Find('id').Kind = TDynamicKind.Int, 'TREE_INT64_IS_INT');
        Check(Tree.Find('id').AsInt = 4815162342, 'TREE_INT64_EXACT');
        Check(Tree.Find('reference').AsStr = 'ORD-0007', 'TREE_STRING');

        Check(Tree.Find('status').Kind = TDynamicKind.Str, 'TREE_ENUM_IS_NAME');
        Check(Tree.Find('status').AsStr = 'STATUS_PAID', 'TREE_ENUM_NAME');

        Node := Tree.Find('lines');
        Check((Node <> nil) and (Node.Kind = TDynamicKind.Arr),
          'TREE_REPEATED_IS_ARRAY');
        Check(Node.Count = 2, 'TREE_REPEATED_COUNT');
        Child := Node.Items[0];
        Check(Child.Find('sku').AsStr = 'SKU-1', 'TREE_NESTED_MESSAGE');
        Check(SameValue(Child.Find('unit_price').AsFloat, 19.5),
          'TREE_NESTED_DOUBLE');
        Check(Child.Find('quantity').AsInt = 2, 'TREE_NESTED_INT32');

        Node := Tree.Find('tags');
        Check((Node <> nil) and (Node.Count = 3) and
              (Node.Items[0].AsInt = 7) and (Node.Items[2].AsInt = 13),
          'TREE_PACKED_RUN_EXPANDED');

        Node := Tree.Find('labels');
        Check((Node <> nil) and (Node.Kind = TDynamicKind.Obj),
          'TREE_MAP_IS_OBJECT');
        Check((Node.Find('channel') <> nil) and
              (Node.Find('channel').AsStr = 'web'), 'TREE_MAP_ENTRY');
        Check(Node.Count = 2, 'TREE_MAP_COUNT');

        Check(Tree.Find('signature').Kind = TDynamicKind.Bytes,
          'TREE_BYTES_KIND');
        Check(Hex(Tree.Find('signature').AsBytes) = '010203faff',
          'TREE_BYTES_VALUE');

        Check(Tree.Find('placed').Kind = TDynamicKind.DateTime,
          'TREE_TIMESTAMP_IS_DATETIME');
        Check(SameValue(Tree.Find('placed').AsDateTime,
          EncodeDateTime(2024, 3, 1, 12, 30, 45, 0), 1 / (MSecsPerDay * 2)),
          'TREE_TIMESTAMP_VALUE');

        Check(Tree.Find('paid') = nil, 'TREE_ABSENT_STAYS_ABSENT');
        Check(Tree.Find('big').AsInt = 9000000000, 'TREE_UINT64');
        Check(Tree.Find('delta').AsInt = -12345, 'TREE_SINT64_NEGATIVE');

        { Declared order, not arrival order. }
        Check((Tree.Names[0] = 'id') and (Tree.Names[1] = 'reference'),
          'TREE_DECLARED_ORDER');
      finally
        Tree.Free;
      end;

      { A field the descriptor does not mention. Tag for field 99, wire type
        0, then the value 7: 98 06 07. }
      Extra := Copy(Wire, 0, Length(Wire));
      SetLength(Extra, Length(Extra) + 3);
      Extra[Length(Extra) - 3] := $98;
      Extra[Length(Extra) - 2] := $06;
      Extra[Length(Extra) - 1] := $07;
      Tree := Schema.ToDynamic(Extra);
      try
        Check(Tree.Find('id') <> nil, 'UNKNOWN_FIELD_DOES_NOT_STOP_THE_READ');
        Found := False;
        for I := 0 to Tree.Count - 1 do
          if Tree.Names[I] = '99' then Found := True;
        Check(not Found, 'UNKNOWN_FIELD_IS_NOT_INVENTED_A_NAME');
      finally
        Tree.Free;
      end;

      { ------------------------------------- 5. a tree back into bytes --- }
      Writeln;
      Writeln('-- and back, with the same descriptor --');

      Tree := Schema.ToDynamic(Wire);
      try
        Back := Schema.FromDynamic(Tree);
      finally
        Tree.Free;
      end;
      Note('rewritten: ' + IntToStr(Length(Back)) + ' bytes');

      Restored := TProtobufSerializer.Deserialize<TOrder>(Back);
      try
        Check(Restored.Id = 4815162342, 'ROUND_TRIP_ID');
        Check(Restored.Reference = 'ORD-0007', 'ROUND_TRIP_REFERENCE');
        Check(Restored.Status = TStatus.Paid, 'ROUND_TRIP_ENUM');
        Check(Restored.Lines.Count = 2, 'ROUND_TRIP_REPEATED_MESSAGE');
        Check(Restored.Lines[1].Sku = 'SKU-2', 'ROUND_TRIP_NESTED_VALUE');
        Check(Length(Restored.Tags) = 3, 'ROUND_TRIP_PACKED');
        Check(Restored.Labels.Count = 2, 'ROUND_TRIP_MAP');
        Check(Restored.Labels['region'] = 'eu', 'ROUND_TRIP_MAP_VALUE');
        Check(Hex(Restored.Signature) = '010203faff', 'ROUND_TRIP_BYTES');
        Check(SameValue(Restored.Placed,
          EncodeDateTime(2024, 3, 1, 12, 30, 45, 0), 1 / (MSecsPerDay * 2)),
          'ROUND_TRIP_TIMESTAMP');
        Check(Restored.Big = 9000000000, 'ROUND_TRIP_UINT64');
        Check(Restored.Delta = -12345, 'ROUND_TRIP_SINT64');
        Check(Restored.Paid = False, 'ROUND_TRIP_IMPLICIT_DEFAULT');
      finally
        Restored.Free;
      end;

      { The bytes themselves: written in declared field order, so the same
        tree always produces the same message. }
      Tree := Schema.ToDynamic(Back);
      try
        Check(Hex(Schema.FromDynamic(Tree)) = Hex(Back),
          'FROM_DYNAMIC_IS_STABLE');
      finally
        Tree.Free;
      end;

      { --------------------------------- 6. what a write refuses to do --- }
      Writeln;
      Writeln('-- refusing, by name --');

      Bad := TDynamicValue.NewObject;
      try
        Bad.AsObject.Adopt('id', TDynamicValue.NewInt(1));
        Bad.AsObject.Adopt('discount', TDynamicValue.NewInt(5));
        Check(Raises(procedure begin Schema.FromDynamic(Bad) end,
          Msgtext), 'UNKNOWN_MEMBER_REFUSED');
        Note(Copy(Msgtext, 1, 130));
        Check(Pos('discount', Msgtext) > 0, 'UNKNOWN_MEMBER_NAMED');
      finally
        Bad.Free;
      end;

      Bad := TDynamicValue.NewObject;
      try
        Bad.AsObject.Adopt('unit_price', TDynamicValue.NewFloat(1.5));
        Bad.AsObject.Adopt('unitPrice', TDynamicValue.NewFloat(2.5));
        Check(Raises(
          procedure begin Schema.FromDynamic(Bad, 'shop.Line') end,
          Msgtext), 'TWO_SPELLINGS_OF_ONE_FIELD_REFUSED');
      finally
        Bad.Free;
      end;

      Bad := TDynamicValue.NewObject;
      try
        Bad.AsObject.Adopt('status', TDynamicValue.NewStr('STATUS_LOST'));
        Check(Raises(procedure begin Schema.FromDynamic(Bad) end,
          Msgtext), 'UNKNOWN_ENUM_NAME_REFUSED');
        Check(Pos('STATUS_NEW', Msgtext) > 0, 'ENUM_ERROR_LISTS_VALUES');
      finally
        Bad.Free;
      end;

      Bad := TDynamicValue.NewObject;
      try
        Bad.AsObject.Adopt('tags', TDynamicValue.NewInt(7));
        Check(Raises(procedure begin Schema.FromDynamic(Bad) end,
          Msgtext), 'REPEATED_MUST_BE_AN_ARRAY');
      finally
        Bad.Free;
      end;

      Bad := TDynamicValue.NewObject;
      try
        Bad.AsObject.Adopt('id', TDynamicValue.NewBytes(TBytes.Create(1, 2)));
        Check(Raises(procedure begin Schema.FromDynamic(Bad) end,
          Msgtext), 'TYPE_MISMATCH_REFUSED');
      finally
        Bad.Free;
      end;

      { ------------------------- 7. the spellings another end may send --- }
      Writeln;
      Writeln('-- the proto3 JSON spellings, read because the schema says so --');

      Bad := TDynamicValue.NewObject;
      try
        { A 64-bit integer as a string, a bytes field as base64, an enum by
          its number, and a member under its json_name. }
        Bad.AsObject.Adopt('id', TDynamicValue.NewStr('4815162342'));
        Bad.AsObject.Adopt('signature', TDynamicValue.NewStr('AQIDAP8='));
        Bad.AsObject.Adopt('status', TDynamicValue.NewInt(10));
        Bad.AsObject.Adopt('paid', TDynamicValue.NewBool(True));
        Back := Schema.FromDynamic(Bad);
      finally
        Bad.Free;
      end;
      Restored := TProtobufSerializer.Deserialize<TOrder>(Back);
      try
        Check(Restored.Id = 4815162342, 'STRING_FOR_INT64');
        Check(Hex(Restored.Signature) = '01020300ff', 'BASE64_FOR_BYTES');
        Check(Restored.Status = TStatus.Shipped, 'NUMBER_FOR_ENUM');
        Check(Restored.Paid, 'BOOL_ROUND_TRIP');
      finally
        Restored.Free;
      end;

      Bad := TDynamicValue.NewObject;
      try
        Bad.AsObject.Adopt('sku', TDynamicValue.NewStr('J'));
        Bad.AsObject.Adopt('unitPrice', TDynamicValue.NewFloat(3.5));
        Back := Schema.FromDynamic(Bad, 'shop.Line');
      finally
        Bad.Free;
      end;
      Tree := Schema.ToDynamic(Back, 'shop.Line');
      try
        Check(SameValue(Tree.Find('unit_price').AsFloat, 3.5),
          'JSON_NAME_ACCEPTED_ON_WRITE');
      finally
        Tree.Free;
      end;

      Bad := TDynamicValue.NewObject;
      try
        Bad.AsObject.Adopt('id', TDynamicValue.NewInt(9));
        Bad.AsObject.Adopt('reference', TDynamicValue.NewNull);
        Back := Schema.FromDynamic(Bad);
      finally
        Bad.Free;
      end;
      Tree := Schema.ToDynamic(Back);
      try
        Check(Tree.Find('reference') = nil, 'NULL_IS_AN_ABSENT_FIELD');
      finally
        Tree.Free;
      end;

      { ------------------------------------------------- 8. Unicode ----- }
      Writeln;
      Writeln('-- Unicode through the descriptor path --');

      Bad := TDynamicValue.NewObject;
      try
        Bad.AsObject.Adopt('reference', TDynamicValue.NewStr(
          #$10E5#$10D0#$10E0#$10D7#$10E3#$10DA#$10D8 + '|' +
          #$0420#$0443#$0441#$0441#$043A#$0438#$0439 + '|' +
          #$65E5#$672C#$8A9E + '|' +
          #$D83D#$DC68#$200D#$D83D#$DC69 + '|' +
          'e' + #$0301));
        Back := Schema.FromDynamic(Bad);
        Tree := Schema.ToDynamic(Back);
        try
          Check(Tree.Find('reference').AsStr = Bad.Find('reference').AsStr,
            'UNICODE_ROUND_TRIP');
          Check(Pos(#$D83D#$DC68, Tree.Find('reference').AsStr) > 0,
            'UNICODE_NON_BMP');
          Check(Pos('e' + #$0301, Tree.Find('reference').AsStr) > 0,
            'UNICODE_COMBINING_MARK_NOT_NORMALISED');
        finally
          Tree.Free;
        end;
      finally
        Bad.Free;
      end;

      { ------------------------------------ 9. through the registry ----- }
      Writeln;
      Writeln('-- the registry, with and without the descriptor --');

      Opts := TStructuralConversionOptions.Default;
      Caps := TSerializationFormats.Capabilities(
        TSerializationFormat.Protobuf, Opts);
      Check(not (TSerializationFormatCapability.StructuralParse in Caps),
        'NO_SCHEMA_NO_STRUCTURAL_PARSE');
      Check(TSerializationFormatCapability.ContractSerialize in Caps,
        'CONTRACT_CAPABILITY_ALWAYS');

      Opts := Opts.WithContext(Schema);
      Caps := TSerializationFormats.Capabilities(
        TSerializationFormat.Protobuf, Opts);
      Check(TSerializationFormatCapability.StructuralParse in Caps,
        'SCHEMA_GRANTS_STRUCTURAL_PARSE');
      Check(TSerializationFormatCapability.StructuralWrite in Caps,
        'SCHEMA_GRANTS_STRUCTURAL_WRITE');

      Structural := TSerialization.StructuralFormats;
      Found := False;
      for I := 0 to High(Structural) do
        if Structural[I] = TSerializationFormat.Protobuf then Found := True;
      Check(not Found, 'NOT_IN_THE_RING_WITHOUT_A_SCHEMA');

      Structural := TSerialization.StructuralFormats(Opts);
      Found := False;
      for I := 0 to High(Structural) do
        if Structural[I] = TSerializationFormat.Protobuf then Found := True;
      Check(Found, 'IN_THE_RING_WITH_A_SCHEMA');

      Source := TSerializationPayload.FromBytes(Wire);
      Check(RaisesClass(
        procedure
        begin
          TSerialization.Convert(Source, TSerializationFormat.Protobuf,
            TSerializationFormat.Json);
        end, ESerializationSchemaRequired, Msgtext),
        'CONVERT_WITHOUT_SCHEMA_ASKS_FOR_ONE');
      Note(Copy(Msgtext, 1, 130));

      Result2 := TSerialization.Convert(Source, TSerializationFormat.Protobuf,
        TSerializationFormat.Json, TStructuralConversionProfile.Natural,
        Schema);
      Json := Result2.AsText;
      Note('as JSON: ' + Copy(Json, 1, 120));
      Check(Pos('"reference"', Json) > 0, 'PROTOBUF_TO_JSON_HAS_NAMES');
      Check(Pos('"STATUS_PAID"', Json) > 0, 'PROTOBUF_TO_JSON_ENUM_NAME');
      Check(Pos('4815162342', Json) > 0, 'PROTOBUF_TO_JSON_INT64_EXACT');

      Result2 := TSerialization.Convert(Result2, TSerializationFormat.Json,
        TSerializationFormat.Protobuf, TStructuralConversionProfile.Natural,
        Schema);
      Restored := TProtobufSerializer.Deserialize<TOrder>(Result2.AsBytes);
      try
        Check(Restored.Id = 4815162342, 'JSON_TO_PROTOBUF_ID');
        Check(Restored.Lines.Count = 2, 'JSON_TO_PROTOBUF_NESTED');
        Check(Restored.Labels.Count = 2, 'JSON_TO_PROTOBUF_MAP');
        Check(Restored.Delta = -12345, 'JSON_TO_PROTOBUF_SINT64');
      finally
        Restored.Free;
      end;

      { ---------------------------- 10. a DataSet from protobuf bytes --- }
      Writeln;
      Writeln('-- a DataSet from protobuf, which needs the same descriptor --');

      { The descriptor set describes four messages and these bytes are a
        Line, so the schema has to be told which. }
      Sample := TLine.Create('SKU-9', 4, 8.75);
      try
        Source := TSerializationPayload.FromBytes(
          TProtobufSerializer.Serialize<TLine>(Sample));
      finally
        Sample.Free;
      end;
      Schema.MessageName := 'shop.Line';
      Cds := TDataSetSerializer.CreateClientDataSet(Source,
        TSerializationFormat.Protobuf, Schema, nil);
      try
        Check(Cds.RecordCount = 1, 'DATASET_ROW_COUNT');
        Check(Cds.FindField('sku') <> nil, 'DATASET_COLUMN_FROM_DESCRIPTOR');
        Cds.First;
        Check(Cds.FieldByName('sku').AsString = 'SKU-9', 'DATASET_VALUE');
        Check(Cds.FieldByName('quantity').AsInteger = 4,
          'DATASET_INT_COLUMN');
      finally
        Cds.Free;
      end;
    finally
      { MessageName was set on this one; the second half wants a fresh
        reading of the same bytes. }
      Schema.Free;
    end;

    { ------------------------- 11. the descriptor decides a scalar ----- }
    Writeln;
    Writeln('-- who decides what a Currency is on the wire --');

    Shipment := TShipment.Create;
    try
      Shipment.Amount := 12.3456;
      Wire := TProtobufSerializer.Serialize<TShipment>(Shipment);
      Note('default: ' + Hex(Wire));
      { Field 1, wire type 0 - a varint. The default for a Currency is
        sint64 at Delphi's own scale of ten thousand, so 12.3456 is 123456
        zig-zagged to 246912, which is 80 89 0f as a varint. }
      Check(Hex(Wire) = '0880890f', 'CURRENCY_DEFAULT_IS_SINT64');

      ShipBytes := BuildShipmentDescriptor;
      Second := TProtobufSchema.LoadDescriptorSet(ShipBytes, 'ship.Shipment');
      try
        Check(Second.MessageName = 'ship.Shipment', 'SECOND_SCHEMA_ROOT');
        ShipOpts := TProtobufSerializationOptions.Default;
        ShipOpts.Schema := Second;
        Wire := TProtobufSerializer.Serialize<TShipment>(Shipment, ShipOpts);
        Note('with the descriptor: ' + Hex(Wire));
        { Field 1, wire type 1 - eight bytes - because the .proto says
          double. }
        Check((Length(Wire) = 9) and (Wire[0] = $09),
          'CURRENCY_FOLLOWS_THE_DESCRIPTOR');

        Tree := Second.ToDynamic(Wire);
        try
          Check(Tree.Find('amount').Kind = TDynamicKind.Float,
            'DESCRIBED_AS_DOUBLE_READS_AS_FLOAT');
          Check(SameValue(Tree.Find('amount').AsFloat, 12.3456, 1E-9),
            'DESCRIBED_AS_DOUBLE_VALUE');
        finally
          Tree.Free;
        end;

        { A single message is not ambiguous, so no name is needed. }
        Second.MessageName := '';
        Check(Second.RootMessage.FullName = 'ship.Shipment',
          'SOLE_MESSAGE_NEEDS_NO_NAME');
      finally
        Second.Free;
      end;
    finally
      Shipment.Free;
    end;

    { ------------------------------------- 12. proto2, and refusals ---- }
    Writeln;
    Writeln('-- proto2, and descriptor sets that are not usable --');

    Second := TProtobufSchema.LoadDescriptorSet(BuildRequiredDescriptor,
      'old.Record2');
    try
      Msg := Second.RootMessage;
      Check(Msg.FieldByNumber(1).IsRequired, 'PROTO2_REQUIRED_READ');
      Check(not Msg.FieldByNumber(3).IsPacked,
        'PROTO2_REPEATED_IS_NOT_PACKED_BY_DEFAULT');

      { Field 1 present: 08 07. Field 3 twice, unpacked: 18 01 18 02. }
      Wire := TBytes.Create($08, $07, $18, $01, $18, $02);
      Tree := Second.ToDynamic(Wire);
      try
        Check(Tree.Find('id').AsInt = 7, 'PROTO2_REQUIRED_PRESENT');
        Check(Tree.Find('scores').Count = 2,
          'UNPACKED_REPEATED_ACCUMULATES');
      finally
        Tree.Free;
      end;

      Check(RaisesClass(
        procedure
        var
          T: TDynamicValue;
        begin
          T := Second.ToDynamic(TBytes.Create($12, $01, $41));
          T.Free;
        end, EProtobufInputError, Msgtext), 'PROTO2_REQUIRED_MISSING_RAISES');
      Note(Copy(Msgtext, 1, 110));
    finally
      Second.Free;
    end;

    Check(Raises(
      procedure
      begin
        TProtobufSchema.LoadDescriptorSet(nil).Free;
      end, Msgtext), 'EMPTY_DESCRIPTOR_REFUSED');

    Check(RaisesClass(
      procedure
      begin
        { A valid protobuf message that is not a FileDescriptorSet: field 2
          holding a string. }
        TProtobufSchema.LoadDescriptorSet(
          TBytes.Create($12, $02, $68, $69)).Free;
      end, EProtobufSchemaError, Msgtext), 'NOT_A_DESCRIPTOR_SET_REFUSED');
    Note(Copy(Msgtext, 1, 110));

    Check(RaisesClass(
      procedure
      begin
        TProtobufSchema.LoadDescriptorSet(BuildDanglingDescriptor).Free;
      end, EProtobufSchemaError, Msgtext), 'MISSING_IMPORT_REFUSED');
    Note(Copy(Msgtext, 1, 130));
    Check(Pos('include_imports', Msgtext) > 0, 'MISSING_IMPORT_SAYS_THE_FIX');

    { -------------------- 13. the unknown-field envelope, unchanged ---- }
    Writeln;
    Writeln('-- the envelope a narrow program uses --');

    Order := SampleOrder;
    try
      Wire := TProtobufSerializer.Serialize<TOrder>(Order);
    finally
      Order.Free;
    end;

    Narrow := TProtobufSerializer.DeserializeMessage<TNarrowOrder>(Wire);
    try
      Check(Narrow.Value.Id = 4815162342, 'ENVELOPE_KNOWN_FIELD');
      Check(Narrow.HasUnknownFields, 'ENVELOPE_KEPT_THE_REST');
      Back := TProtobufSerializer.SerializeMessage<TNarrowOrder>(Narrow);
      Restored := TProtobufSerializer.Deserialize<TOrder>(Back);
      try
        Check(Restored.Lines.Count = 2, 'ENVELOPE_SURVIVED_A_ROUND_TRIP');
        Check(Restored.Delta = -12345, 'ENVELOPE_KEPT_EVERY_FIELD');
      finally
        Restored.Free;
      end;
    finally
      Narrow.Value.Free;
    end;

    { ----------------------------------------------------------------- }
    TestSchemaAToSchemaB;

    Writeln;
    Writeln('NOT IMPLEMENTED, deliberately:');
    Writeln('  - no .proto parser. A .proto file is protoc''s input and a');
    Writeln('    FileDescriptorSet is protoc''s output; reading the output');
    Writeln('    needs this library''s codec and nothing else, and writing a');
    Writeln('    second implementation of the grammar would be a second');
    Writeln('    thing to keep correct.');
    Writeln('  - no code generator. Generating Delphi source from a');
    Writeln('    descriptor is a different program.');
    Writeln('  - groups (proto2 TYPE_GROUP) are read by the contract-aware');
    Writeln('    path and refused by the structural one, by name.');
    Writeln('  - services, extensions, custom options and source-code info');
    Writeln('    are skipped when the descriptor set is read. They describe');
    Writeln('    RPC and tooling, not the shape of a message.');
    Writeln('  - Any, Struct, Value, FieldMask and the wrapper types are');
    Writeln('    ordinary messages here. Only Timestamp is given a meaning,');
    Writeln('    because the contract-aware path already writes a TDateTime');
    Writeln('    as one and the two have to agree.');
    Writeln('  - a field unknown to the descriptor is DROPPED on the way');
    Writeln('    into the tree. Use DeserializeMessage to keep it.');
    Writeln;

    Writeln('CHECKS=', GChecks);
    Writeln('FAILURES=', GFailures);
    if GFailures = 0 then
      Writeln('PROTOBUF_SCHEMA: PASS')
    else
      Writeln('PROTOBUF_SCHEMA: FAIL');
  except
    on E: Exception do
    begin
      Writeln('UNHANDLED ', E.ClassName, ': ', E.Message);
      Writeln('PROTOBUF_SCHEMA: FAIL');
      Halt(1);
    end;
  end;
  if GFailures > 0 then Halt(1);
end.
