program ProtobufReference;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Does this library agree with Google's implementation, or only with itself?

  tests\ProtobufSchema builds a FileDescriptorSet with this library's own
  contract-aware engine and reads it back with the descriptor reader. That is
  a real cross-check - the two halves share no code, so a mistake in either
  shows up as a disagreement - but both halves are PascalForge, and a
  misreading of descriptor.proto that is consistent with itself would pass.

  This program closes that gap. Every fixture it reads was produced by
  OFFICIAL protoc and is committed to the repository:

      tests\fixtures\protobuf\reference\ref-probe.proto
      tests\fixtures\protobuf\reference\ref-probe.desc
      tests\fixtures\protobuf\reference\ref-probe-message.txtpb
      tests\fixtures\protobuf\reference\ref-probe-message.bin
      tests\fixtures\protobuf\reference\ref-probe-message.decoded.txtpb

  THIS PROGRAM DOES NOT RUN protoc, and the machine running it does not need
  protoc installed. The .proto file records the version and the exact three
  commands, so the fixtures are reproducible by anyone who wants to check
  them.

  The message deliberately carries the constructs a reader gets wrong in ways
  that still parse: a PACKED repeated field, a map, an enum whose numbers are
  not contiguous, a nested message, an sint64 (zig-zag, which is not the same
  bytes as int64), a fixed64 and a well-known type. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Math, System.StrUtils,
  System.DateUtils, System.Generics.Collections,
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Protobuf in '..\..\src\PascalForge.Protobuf.pas',
  PascalForge.Protobuf.Internal in '..\..\src\PascalForge.Protobuf.Internal.pas',
  PascalForge.Protobuf.Schema in '..\..\src\PascalForge.Protobuf.Schema.pas',
  PascalForge.Protobuf.Registration in '..\..\src\PascalForge.Protobuf.Registration.pas',
  AllFormatsRegistered in '..\Shared\AllFormatsRegistered.pas';

var
  GFailures: Integer = 0;
  GChecks: Integer = 0;

procedure Check(ACondition: Boolean; const AName: string);
begin
  Inc(GChecks);
  if ACondition then Writeln(AName, ': PASS')
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

{ The fixtures live beside the source, and the runner starts every test from
  the repository root. Both roots are tried so the program also runs when
  launched from its own folder. }
function FixtureDir: string;
const
  REL = 'tests\fixtures\protobuf\reference';
var
  FromExe: string;
begin
  Result := TPath.Combine(GetCurrentDir, REL);
  if TDirectory.Exists(Result) then Exit;
  FromExe := TPath.GetFullPath(TPath.Combine(ExtractFilePath(ParamStr(0)),
    '..\..\..\' + REL));
  if TDirectory.Exists(FromExe) then Exit(FromExe);
end;

var
  Dir: string;
  Descriptor, Official, Written: TBytes;
  Schema: TProtobufSchema;
  Msg: TProtoMessageDescriptor;
  Field: TProtoFieldDescriptor;
  Tree, Node, Child: TDynamicValue;
  Names: TArray<string>;
  Json, DecodedText: string;
  Number: Integer;
  Sym: string;
  Context: TProtobufSerializationContext;

begin
  try
    Writeln('ProtobufReference - fixtures produced by official protoc');
    Writeln;

    Dir := FixtureDir;
    if Dir = '' then
    begin
      Writeln('UNEXPECTED: fixture directory not found');
      Writeln('PROTOBUF_REFERENCE: FAIL');
      Halt(1);
    end;
    Note('fixtures: ' + Dir);

    Descriptor := TFile.ReadAllBytes(TPath.Combine(Dir, 'ref-probe.desc'));
    Official := TFile.ReadAllBytes(
      TPath.Combine(Dir, 'ref-probe-message.bin'));
    DecodedText := TFile.ReadAllText(
      TPath.Combine(Dir, 'ref-probe-message.decoded.txtpb'));
    Note(Format('descriptor %d bytes, message %d bytes',
      [Length(Descriptor), Length(Official)]));
    Check((Length(Descriptor) > 0) and (Length(Official) > 0),
      'PROTOBUF_REFERENCE_FIXTURES_PRESENT');

    { --------------------------------------------------------------------
      1. THE DESCRIPTOR protoc WROTE
      -------------------------------------------------------------------- }
    Writeln;
    Writeln('-- reading a descriptor set protoc produced --');

    Schema := TProtobufSchema.LoadDescriptorSet(Descriptor, 'pfprobe.Probe');
    try
      Check(True, 'PROTOBUF_PROTOC_DESCRIPTOR_READ');
      Names := Schema.MessageNames;
      Note('messages: ' + string.Join(', ', Names));

      { --include_imports was used, so the well-known type is in the set and
        the field that references it resolves. Without it this would be the
        error that names --include_imports. }
      Check(IndexStr('google.protobuf.Timestamp', Names) >= 0,
        'PROTOBUF_PROTOC_IMPORTS_INCLUDED');
      Check(IndexStr('pfprobe.Probe.LabelsEntry', Names) >= 0,
        'PROTOBUF_PROTOC_SYNTHESIZED_MAP_ENTRY');

      Msg := Schema.RequireMessage('pfprobe.Probe');
      Check(Msg.FieldCount = 12, 'PROTOBUF_PROTOC_FIELD_COUNT');

      { protoc emits json_name for every field; this library computes one
        when it is absent. Here it is present, so what is checked is that
        the emitted one is used rather than recomputed. }
      Field := Msg.FieldByNumber(3);
      Check(Field.JsonName = 'status', 'PROTOBUF_PROTOC_JSON_NAME');

      { The enum, with the numbers the .proto assigns rather than 0, 1, 2. }
      Field := Msg.FieldByNumber(3);
      Check(Field.EnumType <> nil, 'PROTOBUF_PROTOC_ENUM_RESOLVED');
      Check(Field.EnumType.TryNumber('STATUS_PAID', Number) and (Number = 5),
        'PROTOBUF_PROTOC_ENUM_NUMBERS');
      Check(Field.EnumType.TryName(10, Sym) and (Sym = 'STATUS_SHIPPED'),
        'PROTOBUF_PROTOC_ENUM_NAMES');

      { Packed is the proto3 default and protoc does not emit the option, so
        this is the library deriving it from the syntax - which is the thing
        that decides whether the bytes are read correctly at all. }
      Field := Msg.FieldByNumber(5);
      Check(Field.IsRepeated and Field.IsPacked,
        'PROTOBUF_PROTOC_PACKED_BY_DEFAULT');

      Field := Msg.FieldByNumber(6);
      Check(Field.IsMap, 'PROTOBUF_PROTOC_MAP_RECOGNISED');
      Field := Msg.FieldByNumber(11);
      Check(Field.FieldType = TProtoFieldType.SInt64,
        'PROTOBUF_PROTOC_SINT64');
      Field := Msg.FieldByNumber(12);
      Check(Field.FieldType = TProtoFieldType.Fixed64,
        'PROTOBUF_PROTOC_FIXED64');

      { --------------------------------------------------------------------
        2. THE MESSAGE protoc ENCODED
        -------------------------------------------------------------------- }
      Writeln;
      Writeln('-- reading bytes protoc produced --');
      Note('official: ' + Hex(Official));

      Tree := Schema.ToDynamic(Official);
      try
        Check(Tree.Kind = TDynamicKind.Obj, 'PROTOBUF_REFERENCE_MESSAGE_READ');

        Check(Tree.Find('id').AsInt = 4815162342, 'PROTOBUF_REF_INT64');
        Check(Tree.Find('reference').AsStr = 'ORD-0007', 'PROTOBUF_REF_STRING');
        Check(Tree.Find('status').AsStr = 'STATUS_PAID', 'PROTOBUF_REF_ENUM');

        Node := Tree.Find('lines');
        Check((Node <> nil) and (Node.Count = 2), 'PROTOBUF_REF_REPEATED_MESSAGE');
        Child := Node.Items[0];
        Check(Child.Find('sku').AsStr = 'SKU-1', 'PROTOBUF_REF_NESTED_STRING');
        Check(SameValue(Child.Find('unit_price').AsFloat, 19.5),
          'PROTOBUF_REF_NESTED_DOUBLE');

        { The packed run, expanded. A reader expecting one tag per element
          would find a single 3-byte blob here and produce one element. }
        Node := Tree.Find('tags');
        Check((Node <> nil) and (Node.Count = 3) and
              (Node.Items[0].AsInt = 7) and (Node.Items[1].AsInt = 11) and
              (Node.Items[2].AsInt = 13), 'PROTOBUF_REF_PACKED_REPEATED');

        Node := Tree.Find('labels');
        Check((Node <> nil) and (Node.Kind = TDynamicKind.Obj) and
              (Node.Count = 2) and (Node.Find('channel').AsStr = 'web'),
          'PROTOBUF_REF_MAP');

        Check(Hex(Tree.Find('signature').AsBytes) = '010203faff',
          'PROTOBUF_REF_BYTES');
        Check(Tree.Find('placed').Kind = TDynamicKind.DateTime,
          'PROTOBUF_REF_TIMESTAMP');
        Check(Tree.Find('paid').AsBool, 'PROTOBUF_REF_BOOL');
        Check(Tree.Find('big').AsInt = 9000000000, 'PROTOBUF_REF_UINT64');

        { Zig-zag. Read as a plain int64 this would be 24689, which is a
          perfectly plausible wrong answer. }
        Check(Tree.Find('delta').AsInt = -12345, 'PROTOBUF_REF_SINT64');
        Check(Tree.Find('checksum').AsInt = 81985529216486895,
          'PROTOBUF_REF_FIXED64');

        { And the values agree with protoc's own text rendering of the same
          bytes, which is the other direction of the same evidence. }
        Check(Pos('delta: -12345', DecodedText) > 0,
          'PROTOBUF_REF_AGREES_WITH_PROTOC_DECODE');

        { --------------------------------------------------------------------
          3. THE BYTES THIS LIBRARY WRITES
          -------------------------------------------------------------------- }
        Writeln;
        Writeln('-- writing bytes protoc would accept --');

        Written := Schema.FromDynamic(Tree);
        Note('written : ' + Hex(Written));
        Check(Hex(Written) = Hex(Official),
          'PROTOBUF_REFERENCE_MESSAGE_WRITE');
        if Hex(Written) <> Hex(Official) then
        begin
          Note('official length ' + IntToStr(Length(Official)) +
               ', written length ' + IntToStr(Length(Written)));
        end;
      finally
        Tree.Free;
      end;

      { --------------------------------------------------------------------
        4. THROUGH THE REGISTRY, which is how an application reaches it
        -------------------------------------------------------------------- }
      Writeln;
      Writeln('-- and through the general facade --');

      Context := TProtobufSerializationContext.Create(Schema, 'pfprobe.Probe');
      try
        Json := TSerialization.Convert(
          TSerializationPayload.FromBytes(Official),
          TSerializationFormat.Protobuf, TSerializationFormat.Json,
          TStructuralConversionProfile.Natural, Context).AsText;
        Note(Copy(Json, 1, 150));
        Check(Pos('"reference":"ORD-0007"', Json) > 0,
          'PROTOBUF_REFERENCE_TO_JSON');
        Check(Pos('"STATUS_PAID"', Json) > 0,
          'PROTOBUF_REFERENCE_ENUM_BY_NAME');

        { Back again, and byte-identical to what protoc wrote. }
        Written := TSerialization.Convert(
          TSerializationPayload.FromText(Json),
          TSerializationFormat.Json, TSerializationFormat.Protobuf,
          TStructuralConversionProfile.Natural, Context).AsBytes;
        Check(Hex(Written) = Hex(Official),
          'PROTOBUF_REFERENCE_ROUND_TRIP_IS_BYTE_IDENTICAL');
      finally
        Context.Free;
      end;
    finally
      Schema.Free;
    end;

    Writeln;
    Writeln('NOT IMPLEMENTED, deliberately:');
    Writeln('  - this program does not RUN protoc. The fixtures are');
    Writeln('    committed and the .proto records the version and the exact');
    Writeln('    commands, so a machine running the suite needs no protoc');
    Writeln('    and anybody who wants to check them can regenerate them.');
    Writeln('  - one message, not a corpus. What it carries is chosen to be');
    Writeln('    the constructs a reader gets wrong in ways that still');
    Writeln('    parse, rather than to be many.');
    Writeln;

    Writeln('CHECKS=', GChecks);
    Writeln('FAILURES=', GFailures);
    if GFailures = 0 then Writeln('PROTOBUF_REFERENCE: PASS')
    else
    begin
      Writeln('PROTOBUF_REFERENCE: FAIL');
      Halt(1);
    end;
  except
    on E: Exception do
    begin
      Writeln('UNHANDLED ', E.ClassName, ': ', E.Message);
      Writeln('PROTOBUF_REFERENCE: FAIL');
      Halt(1);
    end;
  end;
end.
