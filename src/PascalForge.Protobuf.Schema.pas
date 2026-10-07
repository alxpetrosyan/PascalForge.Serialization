{*******************************************************************************
  PascalForge.Protobuf.Schema

  Public Protocol Buffers descriptor schema unit for PascalForge.Serialization.

  Responsibilities
    - Loading protoc FileDescriptorSet output (--descriptor_set_out) into
      TProtobufSchema. There is no .proto text parser.
    - Structural conversion between protobuf bytes and the dynamic tree,
      guided by the descriptor.

  Registration
    Using a schema requires no format registration. Generic TSerialization
    operations require TProtobufSerializationRegistration.RegisterFormat
    (PascalForge.Protobuf.Registration).

  Documentation
    docs/formats/protobuf.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Protobuf.Schema;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  The descriptor model: what a .proto file says, read from protoc's own
  output.

      Bytes  := TFile.ReadAllBytes('shop.desc');
      Schema := TProtobufSchema.LoadDescriptorSet(Bytes, 'shop.Order');
      try
        Tree := Schema.ToDynamic(Wire);
      finally
        Schema.Free;
      end;

  where shop.desc came from

      protoc --descriptor_set_out=shop.desc --include_imports shop.proto

  WHY THIS UNIT EXISTS.  A protobuf message on the wire is a sequence of
  (field number, wire type, payload) and nothing else. There are no names,
  and a length-delimited field might be a string, a byte array, a nested
  message or a packed repeated field. Given only the bytes, a reader can
  recover the shape and not the meaning - so PascalForge.Protobuf declares
  only the two contract-aware capabilities, and structural conversion is
  refused.

  A descriptor is the missing half. It is the .proto the OTHER end was
  compiled against, which makes it a better authority than any opinion this
  side could form from a Delphi type. Handed one, the same handler answers
  yes to all four capabilities and parses and writes structurally, with real
  field names, real enum names and no guessing anywhere.

  THERE IS NO .proto PARSER HERE, and there is not going to be one. A .proto
  file is protoc's input; a FileDescriptorSet is protoc's output. That output
  is itself an ordinary protobuf message, so reading it needs this library's
  own codec and nothing else - which is what the parser below is. Writing a
  second implementation of the .proto grammar would be a second thing to keep
  correct, for no gain over running the tool that already exists.

  WHAT IS READ.  Enough of descriptor.proto to describe data:

      FileDescriptorSet.file
      FileDescriptorProto        name, package, message_type, enum_type,
                                 syntax
      DescriptorProto            name, field, nested_type, enum_type,
                                 options.map_entry
      FieldDescriptorProto       name, number, label, type, type_name,
                                 json_name, options.packed, oneof_index,
                                 proto3_optional
      EnumDescriptorProto        name, value
      EnumValueDescriptorProto   name, number

  Services, extensions, custom options and source-code info are skipped as
  unknown fields, which is what a protobuf reader does with anything it was
  not compiled to understand. They describe RPC and tooling, not the shape of
  a message, and nothing below could use them.

  HOW A MESSAGE BECOMES A DYNAMIC TREE.  See ToDynamic and FromDynamic at the
  bottom of the interface; the rules they follow are written there, next to
  the code that follows them, rather than here.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Protobuf;

type
  { The descriptor set is at fault: truncated, not a FileDescriptorSet, or
    describing something this unit cannot represent. A name that is not in
    it raises this too. }
  EProtobufSchemaError = class(EProtobufError);

  { FieldDescriptorProto.Type, by descriptor.proto's own numbers - so that
    the parser can cast what it reads and a reader of this file can check it
    against the specification without a translation table.

    Text is descriptor.proto's TYPE_STRING. It cannot be called String here
    because that is a type, and calling it Str would hide that it is the
    same thing TProtoScalar.Text is. }
  TProtoFieldType = (
    Unspecified = 0,
    Double = 1, Float = 2, Int64 = 3, UInt64 = 4, Int32 = 5,
    Fixed64 = 6, Fixed32 = 7, Bool = 8, Text = 9, Group = 10,
    Message = 11, Bytes = 12, UInt32 = 13, Enum = 14,
    SFixed32 = 15, SFixed64 = 16, SInt32 = 17, SInt64 = 18
  );

  { FieldDescriptorProto.Label. Required exists only in proto2 and is read
    because proto2 files exist. }
  TProtoFieldLabel = (
    Unspecified = 0, Optional = 1, Required = 2, Repeated = 3
  );

  TProtoMessageDescriptor = class;

  { One .proto enum: the names and the numbers, both directions.

    The numbers need not be contiguous, need not start at zero in proto2,
    and a number with no name is NOT an error - proto3 requires a reader to
    keep an unrecognized enum value rather than reject the message. }
  TProtoEnumDescriptor = class
  strict private
    FName: string;
    FFullName: string;
    FNames: TStringList;
    FNumbers: TList<Integer>;
    function GetValueName(AIndex: Integer): string;
    function GetValueNumber(AIndex: Integer): Integer;
    function GetValueCount: Integer;
  public
    constructor Create(const AName, AFullName: string);
    destructor Destroy; override;
    procedure AddValue(const AName: string; ANumber: Integer);

    property Name: string read FName;
    { Package and any enclosing messages included, without a leading dot. }
    property FullName: string read FFullName;
    property ValueCount: Integer read GetValueCount;
    property ValueNames[AIndex: Integer]: string read GetValueName;
    property ValueNumbers[AIndex: Integer]: Integer read GetValueNumber;

    function TryName(ANumber: Integer; out AName: string): Boolean;
    function TryNumber(const AName: string; out ANumber: Integer): Boolean;
  end;

  { One field of one message. }
  TProtoFieldDescriptor = class
  strict private
    FName: string;
    FJsonName: string;
    FTypeName: string;
    FNumber: Integer;
    FFieldType: TProtoFieldType;
    FFieldLabel: TProtoFieldLabel;
    FHasPackedOption: Boolean;
    FPackedOption: Boolean;
    FProto3Optional: Boolean;
    FOneOfIndex: Integer;
    FHasOneOf: Boolean;
    FMessageType: TProtoMessageDescriptor;
    FEnumType: TProtoEnumDescriptor;
    FProto3: Boolean;
  public
    constructor Create;

    property Name: string read FName write FName;
    { descriptor.proto's json_name, which protoc always emits: the
      lowerCamelCase spelling the proto3 JSON mapping uses. Accepted as an
      alternative spelling when reading a dynamic tree; never WRITTEN by
      this unit, which uses Name. The note on ToDynamic says why. }
    property JsonName: string read FJsonName write FJsonName;
    property Number: Integer read FNumber write FNumber;
    property FieldType: TProtoFieldType read FFieldType write FFieldType;
    property FieldLabel: TProtoFieldLabel read FFieldLabel write FFieldLabel;
    { The fully qualified name of the message or enum this field is, with
      the leading dot descriptor.proto puts there. Empty for a scalar. }
    property TypeName: string read FTypeName write FTypeName;
    property HasPackedOption: Boolean read FHasPackedOption
      write FHasPackedOption;
    property PackedOption: Boolean read FPackedOption write FPackedOption;
    property Proto3Optional: Boolean read FProto3Optional write FProto3Optional;
    property HasOneOf: Boolean read FHasOneOf write FHasOneOf;
    property OneOfIndex: Integer read FOneOfIndex write FOneOfIndex;
    { Whether the file this field came from declared syntax = "proto3".
      Only the packed default depends on it. }
    property Proto3: Boolean read FProto3 write FProto3;

    { Resolved after the whole set is parsed, because a field may name a
      message declared in a file that has not been read yet. BORROWED: the
      schema owns every descriptor. }
    property MessageType: TProtoMessageDescriptor read FMessageType
      write FMessageType;
    property EnumType: TProtoEnumDescriptor read FEnumType write FEnumType;

    function IsRepeated: Boolean;
    function IsRequired: Boolean;
    { A map<K,V> field: repeated, and its message is a synthesized entry
      type carrying options.map_entry. }
    function IsMap: Boolean;
    { Whether the type CAN be packed - every scalar except string, bytes and
      message. }
    function IsPackable: Boolean;
    { Whether it IS packed: the explicit option if there is one, otherwise
      proto3's default of packed and proto2's of not. Reading accepts both
      spellings regardless, as the specification requires. }
    function IsPacked: Boolean;
  end;

  { One .proto message. }
  TProtoMessageDescriptor = class
  strict private
    FName: string;
    FFullName: string;
    FIsMapEntry: Boolean;
    FProto3: Boolean;
    FFields: TObjectList<TProtoFieldDescriptor>;
    FNested: TObjectList<TProtoMessageDescriptor>;
    FEnums: TObjectList<TProtoEnumDescriptor>;
    function GetField(AIndex: Integer): TProtoFieldDescriptor;
    function GetFieldCount: Integer;
    function GetNested(AIndex: Integer): TProtoMessageDescriptor;
    function GetNestedCount: Integer;
  public
    constructor Create(const AName, AFullName: string);
    destructor Destroy; override;

    property Name: string read FName;
    property FullName: string read FFullName;
    { True for the entry type protoc synthesizes for a map field. Such a
      message is never a document in its own right; it is two fields called
      key and value. }
    property IsMapEntry: Boolean read FIsMapEntry write FIsMapEntry;
    property Proto3: Boolean read FProto3 write FProto3;

    property FieldCount: Integer read GetFieldCount;
    property Fields[AIndex: Integer]: TProtoFieldDescriptor read GetField;
    property NestedCount: Integer read GetNestedCount;
    property Nested[AIndex: Integer]: TProtoMessageDescriptor read GetNested;

    function AddField: TProtoFieldDescriptor;
    function AddNested(const AName, AFullName: string): TProtoMessageDescriptor;
    function AddEnum(const AName, AFullName: string): TProtoEnumDescriptor;

    function FieldByNumber(ANumber: Integer): TProtoFieldDescriptor;
    { By the declared name first, then by json_name, so a tree written by
      another implementation's proto3 JSON output is understood without the
      caller renaming anything. }
    function FieldByName(const AName: string): TProtoFieldDescriptor;
  end;

  { A parsed FileDescriptorSet, and the entry point for everything above.

    LIFETIME. The schema owns every descriptor reachable from it and frees
    them. A descriptor handed out by FindMessage is BORROWED and must not
    outlive the schema. The library's own convention applies to the schema
    itself: whoever loads it frees it, and nothing that receives it in
    options does.

    THREAD SAFETY. Read-only after loading, and safe to share. Setting
    MessageName is a write and belongs before the sharing starts. }
  TProtobufSchema = class(TProtobufDescriptorSchema)
  strict private
    FFiles: TStringList;
    FMessages: TObjectList<TProtoMessageDescriptor>;
    FEnums: TObjectList<TProtoEnumDescriptor>;
    FByName: TDictionary<string, TProtoMessageDescriptor>;
    FEnumByName: TDictionary<string, TProtoEnumDescriptor>;
    FOrder: TStringList;
    FMessageName: string;
    procedure ParseSet(const AData: TBytes);
    procedure ParseFile(const AData: TBytes);
    procedure ParseMessage(const AData: TBytes; const APrefix: string;
      AProto3: Boolean; AOwner: TProtoMessageDescriptor);
    procedure ParseEnum(const AData: TBytes; const APrefix: string;
      AOwner: TProtoMessageDescriptor);
    procedure ParseField(const AData: TBytes; AField: TProtoFieldDescriptor);
    procedure Index(AMessage: TProtoMessageDescriptor);
    procedure Resolve;
    procedure ResolveMessage(AMessage: TProtoMessageDescriptor);
    procedure SetMessageName(const AValue: string);
  public
    constructor Create;
    destructor Destroy; override;

    { Reads protoc's --descriptor_set_out output. Use --include_imports, or
      a field whose type lives in another file will not resolve.

      The caller owns the result. }
    class function LoadDescriptorSet(
      const AData: TBytes): TProtobufSchema; overload; static;
    { The same, naming the message the conversion is about in one call. }
    class function LoadDescriptorSet(const AData: TBytes;
      const AMessageName: string): TProtobufSchema; overload; static;

    function Format: TSerializationFormat; override;
    function Describe: string; override;

    { Every message in the set, fully qualified, nested types included, in
      declaration order. Map entry types are included: they are messages,
      and hiding them would make a count disagree with a lookup. }
    function MessageNames: TArray<string>;
    { nil when there is no such message. Accepts a leading dot, because that
      is how descriptor.proto spells a type reference. }
    function FindMessage(const AFullName: string): TProtoMessageDescriptor;
    function FindEnum(const AFullName: string): TProtoEnumDescriptor;
    { The same, raising with the available names rather than returning nil. }
    function RequireMessage(const AFullName: string): TProtoMessageDescriptor;

    { WHICH MESSAGE THESE BYTES ARE.

      A descriptor set describes many messages and a protobuf document does
      not say which one it is - there is no header, no name, nothing. The
      conversion options have nowhere to carry the answer either, so the
      schema carries it.

      Set it, or leave it empty when the set declares exactly one message
      that is not a map entry, in which case that one is used. Anything else
      raises and names the candidates, because picking one would be picking
      how to misread the document. }
    property MessageName: string read FMessageName write SetMessageName;
    function RootMessage: TProtoMessageDescriptor;

    { --- the engine's question ------------------------------------------

      What TProtobufSerializer asks when it has been handed this schema in
      TProtobufSerializationOptions: what does the .proto actually say field
      N of the root message is. A Delphi Currency written as sint64 by
      default becomes a double here if the .proto says double, because the
      .proto is what the other end reads. }
    function TryFieldScalar(ANumber: Integer;
      out AScalar: TProtoScalar): Boolean; override;

    { --- structural conversion -------------------------------------------

      Bytes into a named tree, and back. RootMessage decides what the bytes
      are; the overloads taking a name decide it per call without touching
      the property.

      WHAT THE TREE LOOKS LIKE, exactly:

        * an object per message, its members in DECLARED field order, not
          arrival order, so that two encodings of the same message produce
          the same tree
        * the member name is the .proto field name as declared. Not
          json_name: a conversion to XML, CSV or a DataSet column wants the
          name the schema author wrote, and the proto3 JSON mapping's
          lowerCamelCase is a rule about JSON that this tree is not
        * a repeated field is an array, always, even with one element and
          even when empty is indistinguishable from absent
        * a map field is an object, its keys the map keys rendered as text
        * an absent field is ABSENT. proto3 cannot tell a field set to its
          default from one never set, and writing 0 for every unset int
          would be inventing data the document does not contain
        * an enum is the value NAME as a string, or the number when the
          descriptor has no name for it
        * int64, uint64, fixed64 and sfixed64 are exact Int or UInt nodes.
          The proto3 JSON mapping spells them as strings because JavaScript
          numbers are doubles; the dynamic tree has real 64-bit integers, so
          it uses them, and each destination writer then applies its own
          rules
        * google.protobuf.Timestamp is a DateTime node. It is the well-known
          type for an instant and the contract path already writes TDateTime
          as one, so the two agree
        * a field the descriptor does not mention is DROPPED. A tree has
          names and an unknown field has none, and inventing one would be
          inventing structural metadata. Use DeserializeMessage when unknown
          fields must survive

      AND ON THE WAY BACK: a member the descriptor does not mention is
      REFUSED, by name. Dropping data on the way INTO an encoding is the
      failure this library exists to prevent, and the asymmetry is
      deliberate. }
    function ToDynamic(const AData: TBytes): TDynamicValue; overload;
    function ToDynamic(const AData: TBytes;
      const AMessageName: string): TDynamicValue; overload;
    function FromDynamic(AValue: TDynamicValue): TBytes; overload;
    function FromDynamic(AValue: TDynamicValue;
      const AMessageName: string): TBytes; overload;
  end;

  { ---------------------------------------------------------------------
    THE DESCRIPTOR AND THE MESSAGE, TOGETHER

    A descriptor set describes many messages and a protobuf document does not
    say which one it is. TProtobufSchema.MessageName answers that, but it is
    a property of the SCHEMA and therefore shared by everything using it -
    which breaks the moment one conversion reads shop.Order and another
    writes shop.Receipt from the same descriptor set.

    A context is per conversion. Two of them, in the source and destination
    roles, is also how Protobuf-to-Protobuf works: schema A in, schema B out,
    with nothing having to infer which is which from the format.

    LIFETIME: the schema is BORROWED. Freeing a context does not free the
    descriptor set. }
  TProtobufSerializationContext = class(TSerializationContext)
  strict private
    FSchema: TProtobufSchema;
    FMessageFullName: string;
  public
    { AMessageFullName must name a message in ASchema; this raises if it does
      not, so a typo is found at the call that made it. Leave it empty to use
      the schema's own MessageName, or its sole message. }
    constructor Create(ASchema: TProtobufSchema;
      const AMessageFullName: string = '');

    function Format: TSerializationFormat; override;
    function Describe: string; override;

    property Schema: TProtobufSchema read FSchema;
    property MessageFullName: string read FMessageFullName;
    { The descriptor this context is about, resolved. }
    function Message: TProtoMessageDescriptor;
  end;

implementation

uses
  System.Math, System.DateUtils, System.TypInfo,
  PascalForge.Protobuf.Internal;

const
  { descriptor.proto field numbers, named so that the parser below reads
    like the specification rather than like a table of magic numbers. }
  FDS_FILE           = 1;

  FDP_NAME           = 1;
  FDP_PACKAGE        = 2;
  FDP_MESSAGE_TYPE   = 4;
  FDP_ENUM_TYPE      = 5;
  FDP_SYNTAX         = 12;

  DP_NAME            = 1;
  DP_FIELD           = 2;
  DP_NESTED_TYPE     = 3;
  DP_ENUM_TYPE       = 4;
  DP_OPTIONS         = 7;

  MO_MAP_ENTRY       = 7;

  FLD_NAME           = 1;
  FLD_NUMBER         = 3;
  FLD_LABEL          = 4;
  FLD_TYPE           = 5;
  FLD_TYPE_NAME      = 6;
  FLD_OPTIONS        = 8;
  FLD_ONEOF_INDEX    = 9;
  FLD_JSON_NAME      = 10;
  FLD_PROTO3_OPTIONAL = 17;

  FO_PACKED          = 2;

  ED_NAME            = 1;
  ED_VALUE           = 2;

  EVD_NAME           = 1;
  EVD_NUMBER         = 2;

  { google.protobuf.Timestamp, which is an instant and is treated as one. }
  WKT_TIMESTAMP      = '.google.protobuf.Timestamp';
  TS_SECONDS         = 1;
  TS_NANOS           = 2;

  { A message nests, and so does the walk over one. }
  SCHEMA_MAX_DEPTH   = 100;

{ ------------------------------------------------------------- utilities --- }

{ A reader over the whole of ABytes. }
procedure OpenReader(var AReader: TProtoReader; const AData: TBytes);
begin
  AReader.InitWhole(AData);
end;

function ReadString(var AReader: TProtoReader): string;
begin
  Result := Utf8BytesToString(AReader.ReadLengthDelimited);
end;

{ descriptor.proto emits json_name, but a hand-built descriptor set may not,
  and the mapping is defined, so it is computed rather than left empty. }
function DefaultJsonName(const AName: string): string;
var
  I: Integer;
  Upper: Boolean;
begin
  Result := '';
  Upper := False;
  for I := 1 to Length(AName) do
    if AName[I] = '_' then Upper := True
    else if Upper then
    begin
      Result := Result + UpCase(AName[I]);
      Upper := False;
    end
    else
      Result := Result + AName[I];
end;

{ Both spellings of a fully qualified name are the same name. }
function StripDot(const AName: string): string;
begin
  if (AName <> '') and (AName[1] = '.') then
    Result := Copy(AName, 2, MaxInt)
  else
    Result := AName;
end;

function Qualify(const APrefix, AName: string): string;
begin
  if APrefix = '' then Result := AName else Result := APrefix + '.' + AName;
end;

{ ------------------------------------------------------- enum descriptor --- }

constructor TProtoEnumDescriptor.Create(const AName, AFullName: string);
begin
  inherited Create;
  FName := AName;
  FFullName := AFullName;
  FNames := TStringList.Create;
  FNumbers := TList<Integer>.Create;
end;

destructor TProtoEnumDescriptor.Destroy;
begin
  FNumbers.Free;
  FNames.Free;
  inherited;
end;

procedure TProtoEnumDescriptor.AddValue(const AName: string; ANumber: Integer);
begin
  FNames.Add(AName);
  FNumbers.Add(ANumber);
end;

function TProtoEnumDescriptor.GetValueCount: Integer;
begin
  Result := FNames.Count;
end;

function TProtoEnumDescriptor.GetValueName(AIndex: Integer): string;
begin
  Result := FNames[AIndex];
end;

function TProtoEnumDescriptor.GetValueNumber(AIndex: Integer): Integer;
begin
  Result := FNumbers[AIndex];
end;

function TProtoEnumDescriptor.TryName(ANumber: Integer;
  out AName: string): Boolean;
var
  I: Integer;
begin
  AName := '';
  for I := 0 to Integer(FNumbers.Count - 1) do
    if FNumbers[I] = ANumber then
    begin
      AName := FNames[I];
      Exit(True);
    end;
  Result := False;
end;

function TProtoEnumDescriptor.TryNumber(const AName: string;
  out ANumber: Integer): Boolean;
var
  I: Integer;
begin
  ANumber := 0;
  for I := 0 to FNames.Count - 1 do
    if FNames[I] = AName then
    begin
      ANumber := FNumbers[I];
      Exit(True);
    end;
  Result := False;
end;

{ ------------------------------------------------------ field descriptor --- }

constructor TProtoFieldDescriptor.Create;
begin
  inherited Create;
  FFieldLabel := TProtoFieldLabel.Optional;
  FOneOfIndex := -1;
end;

function TProtoFieldDescriptor.IsRepeated: Boolean;
begin
  Result := FFieldLabel = TProtoFieldLabel.Repeated;
end;

function TProtoFieldDescriptor.IsRequired: Boolean;
begin
  Result := FFieldLabel = TProtoFieldLabel.Required;
end;

function TProtoFieldDescriptor.IsMap: Boolean;
begin
  Result := IsRepeated and (FMessageType <> nil) and FMessageType.IsMapEntry;
end;

function TProtoFieldDescriptor.IsPackable: Boolean;
begin
  Result := not (FFieldType in [TProtoFieldType.Unspecified,
                                TProtoFieldType.Text,
                                TProtoFieldType.Bytes,
                                TProtoFieldType.Message,
                                TProtoFieldType.Group]);
end;

function TProtoFieldDescriptor.IsPacked: Boolean;
begin
  if not (IsRepeated and IsPackable) then Exit(False);
  if FHasPackedOption then Exit(FPackedOption);
  Result := FProto3;
end;

{ ---------------------------------------------------- message descriptor --- }

constructor TProtoMessageDescriptor.Create(const AName, AFullName: string);
begin
  inherited Create;
  FName := AName;
  FFullName := AFullName;
  FFields := TObjectList<TProtoFieldDescriptor>.Create(True);
  FNested := TObjectList<TProtoMessageDescriptor>.Create(True);
  FEnums := TObjectList<TProtoEnumDescriptor>.Create(True);
end;

destructor TProtoMessageDescriptor.Destroy;
begin
  FEnums.Free;
  FNested.Free;
  FFields.Free;
  inherited;
end;

function TProtoMessageDescriptor.GetFieldCount: Integer;
begin
  Result := Integer(FFields.Count);
end;

function TProtoMessageDescriptor.GetField(
  AIndex: Integer): TProtoFieldDescriptor;
begin
  Result := FFields[AIndex];
end;

function TProtoMessageDescriptor.GetNestedCount: Integer;
begin
  Result := Integer(FNested.Count);
end;

function TProtoMessageDescriptor.GetNested(
  AIndex: Integer): TProtoMessageDescriptor;
begin
  Result := FNested[AIndex];
end;

function TProtoMessageDescriptor.AddField: TProtoFieldDescriptor;
begin
  Result := TProtoFieldDescriptor.Create;
  FFields.Add(Result);
end;

function TProtoMessageDescriptor.AddNested(
  const AName, AFullName: string): TProtoMessageDescriptor;
begin
  Result := TProtoMessageDescriptor.Create(AName, AFullName);
  FNested.Add(Result);
end;

function TProtoMessageDescriptor.AddEnum(
  const AName, AFullName: string): TProtoEnumDescriptor;
begin
  Result := TProtoEnumDescriptor.Create(AName, AFullName);
  FEnums.Add(Result);
end;

function TProtoMessageDescriptor.FieldByNumber(
  ANumber: Integer): TProtoFieldDescriptor;
var
  F: TProtoFieldDescriptor;
begin
  for F in FFields do
    if F.Number = ANumber then Exit(F);
  Result := nil;
end;

function TProtoMessageDescriptor.FieldByName(
  const AName: string): TProtoFieldDescriptor;
var
  F: TProtoFieldDescriptor;
begin
  for F in FFields do
    if F.Name = AName then Exit(F);
  for F in FFields do
    if F.JsonName = AName then Exit(F);
  Result := nil;
end;

{ =========================================================================
  THE DESCRIPTOR SET PARSER

  Ordinary protobuf reading, with descriptor.proto as the schema. Every
  field number below is from that file; a field this unit does not name is
  skipped exactly as any protobuf reader skips what it does not know.
  ========================================================================= }

constructor TProtobufSchema.Create;
begin
  inherited Create;
  FFiles := TStringList.Create;
  FMessages := TObjectList<TProtoMessageDescriptor>.Create(True);
  FEnums := TObjectList<TProtoEnumDescriptor>.Create(True);
  FByName := TDictionary<string, TProtoMessageDescriptor>.Create;
  FEnumByName := TDictionary<string, TProtoEnumDescriptor>.Create;
  FOrder := TStringList.Create;
end;

destructor TProtobufSchema.Destroy;
begin
  FOrder.Free;
  FEnumByName.Free;
  FByName.Free;
  FEnums.Free;
  FMessages.Free;
  FFiles.Free;
  inherited;
end;

class function TProtobufSchema.LoadDescriptorSet(
  const AData: TBytes): TProtobufSchema;
begin
  Result := TProtobufSchema.Create;
  try
    Result.ParseSet(AData);
    Result.Resolve;
  except
    Result.Free;
    raise;
  end;
end;

class function TProtobufSchema.LoadDescriptorSet(const AData: TBytes;
  const AMessageName: string): TProtobufSchema;
begin
  Result := LoadDescriptorSet(AData);
  try
    Result.MessageName := AMessageName;
  except
    Result.Free;
    raise;
  end;
end;

procedure TProtobufSchema.ParseSet(const AData: TBytes);
var
  Reader: TProtoReader;
  Number: Integer;
  Wire: TProtoWireType;
  Files: Integer;
begin
  if Length(AData) = 0 then
    raise EProtobufSchemaError.Create(
      'An empty descriptor set describes nothing. Run protoc with ' +
      '--descriptor_set_out and --include_imports, and pass the file it ' +
      'writes.');
  Files := 0;
  OpenReader(Reader, AData);
  while Reader.ReadTag(Number, Wire) do
    if (Number = FDS_FILE) and (Wire = TProtoWireType.LengthDelimited) then
    begin
      ParseFile(Reader.ReadLengthDelimited);
      Inc(Files);
    end
    else
      Reader.SkipField(Reader.FPos, Number, Wire, 0);
  if Files = 0 then
    raise EProtobufSchemaError.Create(
      'These bytes parse as protobuf but contain no FileDescriptorProto, ' +
      'so they are not a FileDescriptorSet. A .proto file itself is not ' +
      'one either - it is protoc''s input, and the descriptor set is its ' +
      'output.');
end;

procedure TProtobufSchema.ParseFile(const AData: TBytes);
var
  Reader: TProtoReader;
  Number: Integer;
  Wire: TProtoWireType;
  Package, FileName, Syntax: string;
  Messages, Enums: TList<TBytes>;
  I: Integer;
begin
  Package := '';
  FileName := '';
  Syntax := 'proto2';
  Messages := TList<TBytes>.Create;
  Enums := TList<TBytes>.Create;
  try
    { Two passes over the file, because syntax is field 12 and the messages
      are field 4: the packed default depends on the syntax, and a producer
      is free to emit the fields in any order. }
    OpenReader(Reader, AData);
    while Reader.ReadTag(Number, Wire) do
      case Number of
        FDP_NAME:    FileName := ReadString(Reader);
        FDP_PACKAGE: Package := ReadString(Reader);
        FDP_SYNTAX:  Syntax := ReadString(Reader);
        FDP_MESSAGE_TYPE: Messages.Add(Reader.ReadLengthDelimited);
        FDP_ENUM_TYPE:    Enums.Add(Reader.ReadLengthDelimited);
      else
        Reader.SkipField(Reader.FPos, Number, Wire, 0);
      end;

    if FileName <> '' then FFiles.Add(FileName);
    for I := 0 to Integer(Enums.Count - 1) do
      ParseEnum(Enums[I], Package, nil);
    for I := 0 to Integer(Messages.Count - 1) do
      ParseMessage(Messages[I], Package, SameText(Syntax, 'proto3'), nil);
  finally
    Enums.Free;
    Messages.Free;
  end;
end;

procedure TProtobufSchema.ParseMessage(const AData: TBytes;
  const APrefix: string; AProto3: Boolean; AOwner: TProtoMessageDescriptor);
var
  Reader, Opt: TProtoReader;
  Number, OptNumber: Integer;
  Wire, OptWire: TProtoWireType;
  Name: string;
  Msg: TProtoMessageDescriptor;
  Fields, Nested, Enums: TList<TBytes>;
  Options: TBytes;
  I: Integer;
begin
  Name := '';
  Options := nil;
  Fields := TList<TBytes>.Create;
  Nested := TList<TBytes>.Create;
  Enums := TList<TBytes>.Create;
  try
    OpenReader(Reader, AData);
    while Reader.ReadTag(Number, Wire) do
      case Number of
        DP_NAME:        Name := ReadString(Reader);
        DP_FIELD:       Fields.Add(Reader.ReadLengthDelimited);
        DP_NESTED_TYPE: Nested.Add(Reader.ReadLengthDelimited);
        DP_ENUM_TYPE:   Enums.Add(Reader.ReadLengthDelimited);
        DP_OPTIONS:     Options := Reader.ReadLengthDelimited;
      else
        Reader.SkipField(Reader.FPos, Number, Wire, 0);
      end;

    if Name = '' then
      raise EProtobufSchemaError.Create(
        'A DescriptorProto in this set has no name, so nothing could refer ' +
        'to it. The file is not what protoc emits.');

    if AOwner = nil then
    begin
      Msg := TProtoMessageDescriptor.Create(Name, Qualify(APrefix, Name));
      FMessages.Add(Msg);
    end
    else
      Msg := AOwner.AddNested(Name, Qualify(APrefix, Name));
    Msg.Proto3 := AProto3;

    if Options <> nil then
    begin
      OpenReader(Opt, Options);
      while Opt.ReadTag(OptNumber, OptWire) do
        if (OptNumber = MO_MAP_ENTRY) and (OptWire = TProtoWireType.Varint) then
          Msg.IsMapEntry := Opt.ReadVarint <> 0
        else
          Opt.SkipField(Opt.FPos, OptNumber, OptWire, 0);
    end;

    for I := 0 to Integer(Fields.Count - 1) do
    begin
      ParseField(Fields[I], Msg.AddField);
      Msg.Fields[Msg.FieldCount - 1].Proto3 := AProto3;
    end;
    for I := 0 to Integer(Enums.Count - 1) do
      ParseEnum(Enums[I], Msg.FullName, Msg);
    for I := 0 to Integer(Nested.Count - 1) do
      ParseMessage(Nested[I], Msg.FullName, AProto3, Msg);
  finally
    Enums.Free;
    Nested.Free;
    Fields.Free;
  end;
end;

procedure TProtobufSchema.ParseEnum(const AData: TBytes;
  const APrefix: string; AOwner: TProtoMessageDescriptor);
var
  Reader, Val: TProtoReader;
  Number, VNumber, ValueNumber: Integer;
  Wire, VWire: TProtoWireType;
  Name, ValueName: string;
  Enum: TProtoEnumDescriptor;
  Values: TList<TBytes>;
  I: Integer;
begin
  Name := '';
  Values := TList<TBytes>.Create;
  try
    OpenReader(Reader, AData);
    while Reader.ReadTag(Number, Wire) do
      case Number of
        ED_NAME:  Name := ReadString(Reader);
        ED_VALUE: Values.Add(Reader.ReadLengthDelimited);
      else
        Reader.SkipField(Reader.FPos, Number, Wire, 0);
      end;

    if AOwner = nil then
    begin
      Enum := TProtoEnumDescriptor.Create(Name, Qualify(APrefix, Name));
      FEnums.Add(Enum);
    end
    else
      Enum := AOwner.AddEnum(Name, Qualify(APrefix, Name));
    FEnumByName.AddOrSetValue(Enum.FullName, Enum);

    for I := 0 to Integer(Values.Count - 1) do
    begin
      ValueName := '';
      ValueNumber := 0;
      OpenReader(Val, Values[I]);
      while Val.ReadTag(VNumber, VWire) do
        case VNumber of
          EVD_NAME:   ValueName := ReadString(Val);
          EVD_NUMBER: ValueNumber := Val.ReadInt32;
        else
          Val.SkipField(Val.FPos, VNumber, VWire, 0);
        end;
      Enum.AddValue(ValueName, ValueNumber);
    end;
  finally
    Values.Free;
  end;
end;

procedure TProtobufSchema.ParseField(const AData: TBytes;
  AField: TProtoFieldDescriptor);
var
  Reader, Opt: TProtoReader;
  Number, OptNumber: Integer;
  Wire, OptWire: TProtoWireType;
  Options: TBytes;
begin
  Options := nil;
  OpenReader(Reader, AData);
  while Reader.ReadTag(Number, Wire) do
    case Number of
      FLD_NAME:      AField.Name := ReadString(Reader);
      FLD_NUMBER:    AField.Number := Reader.ReadInt32;
      FLD_LABEL:     AField.FieldLabel := TProtoFieldLabel(Reader.ReadInt32);
      FLD_TYPE:      AField.FieldType := TProtoFieldType(Reader.ReadInt32);
      FLD_TYPE_NAME: AField.TypeName := ReadString(Reader);
      FLD_JSON_NAME: AField.JsonName := ReadString(Reader);
      FLD_OPTIONS:   Options := Reader.ReadLengthDelimited;
      FLD_ONEOF_INDEX:
        begin
          AField.OneOfIndex := Reader.ReadInt32;
          AField.HasOneOf := True;
        end;
      FLD_PROTO3_OPTIONAL: AField.Proto3Optional := Reader.ReadVarint <> 0;
    else
      Reader.SkipField(Reader.FPos, Number, Wire, 0);
    end;

  if AField.Name = '' then
    raise EProtobufSchemaError.Create(
      'A FieldDescriptorProto in this set has no name.');
  if (AField.Number < 1) or (AField.Number > 536870911) then
    raise EProtobufSchemaError.CreateFmt(
      'Field %s carries the number %d, which is outside the 1..536870911 ' +
      'the specification allows.', [AField.Name, AField.Number]);
  if AField.JsonName = '' then
    AField.JsonName := DefaultJsonName(AField.Name);

  if Options <> nil then
  begin
    OpenReader(Opt, Options);
    while Opt.ReadTag(OptNumber, OptWire) do
      if (OptNumber = FO_PACKED) and (OptWire = TProtoWireType.Varint) then
      begin
        AField.PackedOption := Opt.ReadVarint <> 0;
        AField.HasPackedOption := True;
      end
      else
        Opt.SkipField(Opt.FPos, OptNumber, OptWire, 0);
  end;
end;

procedure TProtobufSchema.Index(AMessage: TProtoMessageDescriptor);
var
  I: Integer;
begin
  FByName.AddOrSetValue(AMessage.FullName, AMessage);
  FOrder.Add(AMessage.FullName);
  for I := 0 to AMessage.NestedCount - 1 do Index(AMessage.Nested[I]);
end;

procedure TProtobufSchema.ResolveMessage(AMessage: TProtoMessageDescriptor);
var
  I: Integer;
  F: TProtoFieldDescriptor;
  Key: string;
  Msg: TProtoMessageDescriptor;
  Enum: TProtoEnumDescriptor;
begin
  for I := 0 to AMessage.FieldCount - 1 do
  begin
    F := AMessage.Fields[I];
    if F.TypeName = '' then Continue;
    Key := StripDot(F.TypeName);
    case F.FieldType of
      TProtoFieldType.Message, TProtoFieldType.Group:
        if FByName.TryGetValue(Key, Msg) then F.MessageType := Msg
        else
          { A type from a file that was not included. Named rather than
            silently left nil, because the failure otherwise surfaces much
            later as "this field has no descriptor". }
          raise EProtobufSchemaError.CreateFmt(
            'Field %s.%s is of type %s, which is not in this descriptor ' +
            'set. Re-run protoc with --include_imports.',
            [AMessage.FullName, F.Name, Key]);
      TProtoFieldType.Enum:
        if FEnumByName.TryGetValue(Key, Enum) then F.EnumType := Enum
        else
          raise EProtobufSchemaError.CreateFmt(
            'Field %s.%s is of enum type %s, which is not in this ' +
            'descriptor set. Re-run protoc with --include_imports.',
            [AMessage.FullName, F.Name, Key]);
    end;
  end;
  for I := 0 to AMessage.NestedCount - 1 do ResolveMessage(AMessage.Nested[I]);
end;

procedure TProtobufSchema.Resolve;
var
  I: Integer;
begin
  FOrder.Clear;
  FByName.Clear;
  for I := 0 to Integer(FMessages.Count - 1) do Index(FMessages[I]);
  for I := 0 to Integer(FMessages.Count - 1) do ResolveMessage(FMessages[I]);
end;

{ ------------------------------------------------------------- the model --- }

function TProtobufSchema.Format: TSerializationFormat;
begin
  Result := TSerializationFormat.Protobuf;
end;

function TProtobufSchema.Describe: string;
begin
  Result := System.SysUtils.Format('%d message(s), %d file(s)',
    [FOrder.Count, FFiles.Count]);
  if FMessageName <> '' then Result := Result + ', root ' + FMessageName;
end;

function TProtobufSchema.MessageNames: TArray<string>;
begin
  Result := FOrder.ToStringArray;
end;

function TProtobufSchema.FindMessage(
  const AFullName: string): TProtoMessageDescriptor;
begin
  if not FByName.TryGetValue(StripDot(AFullName), Result) then Result := nil;
end;

function TProtobufSchema.FindEnum(
  const AFullName: string): TProtoEnumDescriptor;
begin
  if not FEnumByName.TryGetValue(StripDot(AFullName), Result) then
    Result := nil;
end;

function TProtobufSchema.RequireMessage(
  const AFullName: string): TProtoMessageDescriptor;
begin
  Result := FindMessage(AFullName);
  if Result = nil then
    raise EProtobufSchemaError.CreateFmt(
      'This descriptor set has no message called %s. It has: %s.',
      [AFullName, String.Join(', ', MessageNames)]);
end;

procedure TProtobufSchema.SetMessageName(const AValue: string);
begin
  if AValue <> '' then RequireMessage(AValue);
  FMessageName := StripDot(AValue);
end;

function TProtobufSchema.RootMessage: TProtoMessageDescriptor;
var
  I, Candidates: Integer;
  Only: TProtoMessageDescriptor;
  Msg: TProtoMessageDescriptor;
  Names: TStringList;
begin
  if FMessageName <> '' then Exit(RequireMessage(FMessageName));

  Candidates := 0;
  Only := nil;
  for I := 0 to FOrder.Count - 1 do
  begin
    Msg := FByName[FOrder[I]];
    if Msg.IsMapEntry then Continue;
    Inc(Candidates);
    if Only = nil then Only := Msg;
  end;
  if Candidates = 1 then Exit(Only);

  Names := TStringList.Create;
  try
    for I := 0 to FOrder.Count - 1 do
      if not FByName[FOrder[I]].IsMapEntry then Names.Add(FOrder[I]);
    raise EProtobufSchemaError.CreateFmt(
      'This descriptor set describes %d messages and a protobuf document ' +
      'does not say which one it is. Set MessageName, or pass the name to ' +
      'the overload that takes one. The candidates are: %s.',
      [Candidates, String.Join(', ', Names.ToStringArray)]);
  finally
    Names.Free;
  end;
end;

function TProtobufSchema.TryFieldScalar(ANumber: Integer;
  out AScalar: TProtoScalar): Boolean;
var
  Root: TProtoMessageDescriptor;
  F: TProtoFieldDescriptor;
begin
  AScalar := TProtoScalar.Auto;
  Result := False;
  if FMessageName = '' then Exit;
  Root := FindMessage(FMessageName);
  if Root = nil then Exit;
  F := Root.FieldByNumber(ANumber);
  if F = nil then Exit;
  case F.FieldType of
    TProtoFieldType.Double:   AScalar := TProtoScalar.Double;
    TProtoFieldType.Float:    AScalar := TProtoScalar.Float;
    TProtoFieldType.Int64:    AScalar := TProtoScalar.Int64;
    TProtoFieldType.UInt64:   AScalar := TProtoScalar.UInt64;
    TProtoFieldType.Int32:    AScalar := TProtoScalar.Int32;
    TProtoFieldType.Fixed64:  AScalar := TProtoScalar.Fixed64;
    TProtoFieldType.Fixed32:  AScalar := TProtoScalar.Fixed32;
    TProtoFieldType.Bool:     AScalar := TProtoScalar.Bool;
    TProtoFieldType.Text:     AScalar := TProtoScalar.Text;
    TProtoFieldType.Bytes:    AScalar := TProtoScalar.Bytes;
    TProtoFieldType.UInt32:   AScalar := TProtoScalar.UInt32;
    TProtoFieldType.Enum:     AScalar := TProtoScalar.EnumValue;
    TProtoFieldType.SFixed32: AScalar := TProtoScalar.SFixed32;
    TProtoFieldType.SFixed64: AScalar := TProtoScalar.SFixed64;
    TProtoFieldType.SInt32:   AScalar := TProtoScalar.SInt32;
    TProtoFieldType.SInt64:   AScalar := TProtoScalar.SInt64;
  else
    { A message or a group is not a scalar, and a descriptor that called a
      nested message a string would not be describing this data at all. }
    Exit(False);
  end;
  Result := True;
end;

{ =========================================================================
  STRUCTURAL CONVERSION

  A protobuf document and the dynamic tree, both ways, with the descriptor
  as the only authority. The rules are stated on ToDynamic in the interface;
  this is where they are carried out.
  ========================================================================= }

{ The wire type a field of this type is written with. For a packed repeated
  field the RUN is length-delimited and each element still uses this. }
function ExpectedWire(AType: TProtoFieldType): TProtoWireType;
begin
  case AType of
    TProtoFieldType.Double, TProtoFieldType.Fixed64,
    TProtoFieldType.SFixed64:
      Result := TProtoWireType.Fixed64;
    TProtoFieldType.Float, TProtoFieldType.Fixed32,
    TProtoFieldType.SFixed32:
      Result := TProtoWireType.Fixed32;
    TProtoFieldType.Text, TProtoFieldType.Bytes, TProtoFieldType.Message:
      Result := TProtoWireType.LengthDelimited;
    TProtoFieldType.Group:
      Result := TProtoWireType.StartGroup;
  else
    Result := TProtoWireType.Varint;
  end;
end;

function FieldTypeName(AType: TProtoFieldType): string;
begin
  Result := GetEnumName(TypeInfo(TProtoFieldType), Ord(AType));
end;

function Where(const APath, AName: string): string;
begin
  if APath = '' then Result := AName else Result := APath + '.' + AName;
end;

{ Decimal is held as text and Str is text; everything else has no text form
  worth parsing back. One place decides which, so no caller has to. }
function DynamicText(AValue: TDynamicValue): string;
begin
  if AValue.Kind = TDynamicKind.Decimal then
    Result := AValue.AsDecimal
  else
    Result := AValue.AsStr;
end;

function FieldNamesOf(AMsg: TProtoMessageDescriptor): TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, AMsg.FieldCount);
  for I := 0 to AMsg.FieldCount - 1 do Result[I] := AMsg.Fields[I].Name;
end;

{ ---------------------------------------------------------- bytes -> tree - }

function MessageToDynamic(AMsg: TProtoMessageDescriptor; const AData: TBytes;
  const APath: string; ADepth: Integer): TDynamicValue; forward;

{ Seconds and nanos into a TDateTime - the inverse of what the engine writes
  for a TDateTime member, so the contract path and this one agree. }
function TimestampToDynamic(const AData: TBytes;
  const APath: string): TDynamicValue;
var
  Reader: TProtoReader;
  Number: Integer;
  Wire: TProtoWireType;
  Seconds: Int64;
  Nanos: Integer;
  Instant: TDateTime;
begin
  Seconds := 0;
  Nanos := 0;
  OpenReader(Reader, AData);
  while Reader.ReadTag(Number, Wire) do
    case Number of
      TS_SECONDS: Seconds := Int64(Reader.ReadVarint);
      TS_NANOS:   Nanos := Reader.ReadInt32;
    else
      Reader.SkipField(Reader.FPos, Number, Wire, 0);
    end;
  { Through Core, as the engine reads one: the linear UnixDateDelta +
    Ms / MSecsPerDay read an instant before 1899-12-30 a day late, and took
    a count past year 9999 as some other date. The seconds are checked
    first, so the milliseconds cannot overflow. }
  if not TStructuralText.TryUnixSecondsToDateTime(Seconds, Instant) or
     not TStructuralText.TryUnixMillisToDateTime(
       Seconds * MSecsPerSec + Nanos div 1000000, Instant) then
    raise EProtobufInputError.CreateFmt(
      '%s is a google.protobuf.Timestamp of %d seconds and %d nanoseconds, ' +
      'outside the years 1 to 9999, which a TDateTime holds.',
      [APath, Seconds, Nanos]);
  Result := TDynamicValue.NewDateTime(Instant);
end;

{ One value of AField, the reader positioned at its payload. }
function ValueToDynamic(AField: TProtoFieldDescriptor;
  var AReader: TProtoReader; AWire: TProtoWireType; const APath: string;
  ADepth: Integer): TDynamicValue;
var
  U32: UInt32;
  U64: UInt64;
  S: Single;
  D: Double;
  Number: Integer;
  EnumName: string;
begin
  if AWire <> ExpectedWire(AField.FieldType) then
    raise EProtobufInputError.CreateFmt(
      '%s is declared %s, which is written with wire type %d, and these ' +
      'bytes carry wire type %d. Either the descriptor is not the one this ' +
      'message was written against, or the message is damaged.',
      [APath, FieldTypeName(AField.FieldType),
       Ord(ExpectedWire(AField.FieldType)), Ord(AWire)]);

  case AField.FieldType of
    TProtoFieldType.Double:
      begin
        U64 := AReader.ReadFixed64;
        D := PDouble(@U64)^;
        Result := TDynamicValue.NewFloat(D);
      end;
    TProtoFieldType.Float:
      begin
        U32 := AReader.ReadFixed32;
        S := PSingle(@U32)^;
        Result := TDynamicValue.NewFloat(S);
      end;
    TProtoFieldType.Int64:
      Result := TDynamicValue.NewInt(Int64(AReader.ReadVarint));
    TProtoFieldType.UInt64:
      Result := TDynamicValue.NewUInt(AReader.ReadVarint);
    TProtoFieldType.Int32:
      Result := TDynamicValue.NewInt(AReader.ReadInt32);
    TProtoFieldType.Fixed64:
      Result := TDynamicValue.NewUInt(AReader.ReadFixed64);
    TProtoFieldType.Fixed32:
      Result := TDynamicValue.NewInt(Int64(AReader.ReadFixed32));
    TProtoFieldType.Bool:
      Result := TDynamicValue.NewBool(AReader.ReadVarint <> 0);
    TProtoFieldType.Text:
      Result := TDynamicValue.NewStr(
        Utf8BytesToString(AReader.ReadLengthDelimited));
    TProtoFieldType.Bytes:
      Result := TDynamicValue.NewBytes(AReader.ReadLengthDelimited);
    TProtoFieldType.UInt32:
      Result := TDynamicValue.NewInt(Int64(UInt32(AReader.ReadVarint)));
    TProtoFieldType.SFixed32:
      Result := TDynamicValue.NewInt(Integer(AReader.ReadFixed32));
    TProtoFieldType.SFixed64:
      Result := TDynamicValue.NewInt(Int64(AReader.ReadFixed64));
    TProtoFieldType.SInt32:
      Result := TDynamicValue.NewInt(
        ZigZagDecode32(UInt32(AReader.ReadVarint)));
    TProtoFieldType.SInt64:
      Result := TDynamicValue.NewInt(ZigZagDecode64(AReader.ReadVarint));
    TProtoFieldType.Enum:
      begin
        Number := AReader.ReadInt32;
        { The name when the descriptor has one. proto3 requires a reader to
          KEEP a number it does not recognize rather than reject it, so an
          unknown one becomes the number itself and nothing is lost. }
        if (AField.EnumType <> nil) and
           AField.EnumType.TryName(Number, EnumName) then
          Result := TDynamicValue.NewStr(EnumName)
        else
          Result := TDynamicValue.NewInt(Number);
      end;
    TProtoFieldType.Message:
      if AField.TypeName = WKT_TIMESTAMP then
        Result := TimestampToDynamic(AReader.ReadLengthDelimited, APath)
      else
        Result := MessageToDynamic(AField.MessageType,
          AReader.ReadLengthDelimited, APath, ADepth + 1);
  else
    raise EProtobufSchemaError.CreateFmt(
      '%s is declared %s. A group is proto2 syntax that protoc has not ' +
      'emitted for many years, and a structural conversion of one is not ' +
      'implemented - the contract-aware path reads them.',
      [APath, FieldTypeName(AField.FieldType)]);
  end;
end;

{ A map entry is a synthesized two-field message. The key is rendered as
  text because a dynamic object names its members with strings, and every
  protobuf map key type has an exact text spelling. }
procedure MapEntryToDynamic(AField: TProtoFieldDescriptor;
  const AData: TBytes; const APath: string; ADepth: Integer;
  out AKey: string; out AValue: TDynamicValue);
var
  Reader: TProtoReader;
  Number: Integer;
  Wire: TProtoWireType;
  KeyField, ValueField: TProtoFieldDescriptor;
  KeyNode: TDynamicValue;
begin
  AKey := '';
  AValue := nil;
  KeyField := AField.MessageType.FieldByNumber(1);
  ValueField := AField.MessageType.FieldByNumber(2);
  if (KeyField = nil) or (ValueField = nil) then
    raise EProtobufSchemaError.CreateFmt(
      '%s is a map field whose entry type does not declare both field 1 ' +
      'and field 2.', [APath]);

  KeyNode := nil;
  try
    OpenReader(Reader, AData);
    while Reader.ReadTag(Number, Wire) do
      if Number = 1 then
      begin
        FreeAndNil(KeyNode);
        KeyNode := ValueToDynamic(KeyField, Reader, Wire,
          Where(APath, 'key'), ADepth);
      end
      else if Number = 2 then
      begin
        FreeAndNil(AValue);
        AValue := ValueToDynamic(ValueField, Reader, Wire,
          Where(APath, 'value'), ADepth);
      end
      else
        Reader.SkipField(Reader.FPos, Number, Wire, ADepth);

    { An absent key or value means the entry type's default, which is what
      the specification says an omitted one is. }
    if KeyNode = nil then KeyNode := TDynamicValue.NewStr('');
    if AValue = nil then AValue := TDynamicValue.NewNull;

    case KeyNode.Kind of
      TDynamicKind.Str:  AKey := KeyNode.AsStr;
      TDynamicKind.UInt: AKey := UIntToStr(KeyNode.AsUInt);
      TDynamicKind.Bool:
        if KeyNode.AsBool then AKey := 'true' else AKey := 'false';
    else
      AKey := IntToStr(KeyNode.AsInt);
    end;
  finally
    KeyNode.Free;
  end;
end;

{ Last wins, which is what protobuf says about a repeated key in a map.
  TDynamicValue has no replace, so the node is rebuilt - which costs
  something only in the pathological case that produced it. }
procedure PutMapEntry(var ASlot: TDynamicValue; const AKey: string;
  AValue: TDynamicValue);
var
  Rebuilt: TDynamicValue;
  I: Integer;
begin
  if ASlot.Find(AKey) = nil then
  begin
    ASlot.AsObject.Adopt(AKey, AValue);
    Exit;
  end;
  Rebuilt := TDynamicValue.NewObject;
  try
    for I := 0 to ASlot.Count - 1 do
      if ASlot.Names[I] <> AKey then
        Rebuilt.AsObject.Adopt(ASlot.Names[I], ASlot.Items[I].Clone);
    Rebuilt.AsObject.Adopt(AKey, AValue);
  except
    Rebuilt.Free;
    raise;
  end;
  ASlot.Free;
  ASlot := Rebuilt;
end;

procedure FreeSlots(ASlots: TDictionary<Integer, TDynamicValue>);
var
  V: TDynamicValue;
begin
  for V in ASlots.Values do V.Free;
  ASlots.Clear;
end;

function MessageToDynamic(AMsg: TProtoMessageDescriptor; const AData: TBytes;
  const APath: string; ADepth: Integer): TDynamicValue;
var
  Reader, Run: TProtoReader;
  Slots: TDictionary<Integer, TDynamicValue>;
  Number, I, TagStart: Integer;
  Wire: TProtoWireType;
  F: TProtoFieldDescriptor;
  Node, Slot: TDynamicValue;
  Key: string;
  Payload: TBytes;
begin
  if ADepth > SCHEMA_MAX_DEPTH then
    raise EProtobufInputError.CreateFmt(
      'Messages nested more than %d deep at %s.', [SCHEMA_MAX_DEPTH, APath]);

  Slots := TDictionary<Integer, TDynamicValue>.Create;
  try
    OpenReader(Reader, AData);
    TagStart := Reader.FPos;
    while Reader.ReadTag(Number, Wire) do
    begin
      F := AMsg.FieldByNumber(Number);
      if F = nil then
      begin
        { Dropped, and the interface says so. A tree names its members and
          an unknown field has no name; inventing one would be inventing
          structural metadata, which this library does not do. }
        Reader.SkipField(TagStart, Number, Wire, ADepth);
        TagStart := Reader.FPos;
        Continue;
      end;

      if F.IsMap then
      begin
        if not Slots.TryGetValue(Number, Slot) then
        begin
          Slot := TDynamicValue.NewObject;
          Slots.AddOrSetValue(Number, Slot);
        end;
        MapEntryToDynamic(F, Reader.ReadLengthDelimited,
          Where(APath, F.Name), ADepth, Key, Node);
        try
          PutMapEntry(Slot, Key, Node);
        except
          Node.Free;
          raise;
        end;
        Slots.AddOrSetValue(Number, Slot);
      end
      else if F.IsRepeated then
      begin
        if not Slots.TryGetValue(Number, Slot) then
        begin
          Slot := TDynamicValue.NewArray;
          Slots.AddOrSetValue(Number, Slot);
        end;
        if F.IsPackable and (Wire = TProtoWireType.LengthDelimited) then
        begin
          { A packed run. The specification requires a reader to accept both
            spellings whatever the option says, so this is decided by the
            wire type in front of it rather than by IsPacked. }
          Payload := Reader.ReadLengthDelimited;
          Run.InitWhole(Payload);
          while not Run.AtEnd do
            Slot.AsArray.Adopt(ValueToDynamic(F, Run, ExpectedWire(F.FieldType),
              Where(APath, F.Name), ADepth));
        end
        else
          Slot.AsArray.Adopt(ValueToDynamic(F, Reader, Wire, Where(APath, F.Name),
            ADepth));
      end
      else
      begin
        { Singular: the last occurrence wins, which is what the
          specification says about a field that arrives twice. }
        Node := ValueToDynamic(F, Reader, Wire, Where(APath, F.Name), ADepth);
        if Slots.TryGetValue(Number, Slot) then Slot.Free;
        Slots.AddOrSetValue(Number, Node);
      end;
      TagStart := Reader.FPos;
    end;

    Result := TDynamicValue.NewObject;
    try
      for I := 0 to AMsg.FieldCount - 1 do
      begin
        F := AMsg.Fields[I];
        if Slots.TryGetValue(F.Number, Node) then
        begin
          Slots.Remove(F.Number);
          Result.AsObject.Adopt(F.Name, Node);
        end
        else if F.IsRequired then
          raise EProtobufInputError.CreateFmt(
            '%s is declared required in proto2 and is not in these bytes.',
            [Where(APath, F.Name)]);
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    FreeSlots(Slots);
    Slots.Free;
  end;
end;

{ ---------------------------------------------------------- tree -> bytes - }

procedure WriteMessageDynamic(AMsg: TProtoMessageDescriptor;
  AValue: TDynamicValue; var AWriter: TProtoWriter; const APath: string;
  ADepth: Integer); forward;

procedure Mismatch(const APath: string; AField: TProtoFieldDescriptor;
  AValue: TDynamicValue);
begin
  raise EProtobufInternalError.CreateFmt(
    '%s is declared %s and the value offered is %s. A conversion into ' +
    'protobuf writes what the descriptor says the field is, or nothing at ' +
    'all - it does not reinterpret one type as another.',
    [APath, FieldTypeName(AField.FieldType), AValue.Describe]);
end;

function AsInteger(AValue: TDynamicValue; AField: TProtoFieldDescriptor;
  const APath: string): Int64;
var
  D: Double;
begin
  Result := 0;
  case AValue.Kind of
    TDynamicKind.Int, TDynamicKind.UInt: Result := AValue.AsInt;
    TDynamicKind.Bool:
      if AValue.AsBool then Result := 1 else Result := 0;
    TDynamicKind.Float:
      begin
        D := AValue.AsFloat;
        { Out of range first: Trunc of 1e19, an infinity or a NaN raised
          the RTL's EInvalidOp rather than a protobuf error. }
        if not ProtoDoubleInInt64Range(D) or (Frac(D) <> 0) then
          Mismatch(APath, AField, AValue);
        Result := Trunc(D);
      end;
    { A string for an integer field is read as one BECAUSE THE DESCRIPTOR
      SAYS SO. Nothing here guesses from the shape of the text: a schema is
      one of the three authorities allowed to say what a value is, and the
      proto3 JSON mapping spells 64-bit integers as strings, so a tree that
      came from another implementation carries them this way. }
    TDynamicKind.Str, TDynamicKind.Decimal:
      if not TryStrToInt64(DynamicText(AValue), Result) then
        raise EProtobufInternalError.CreateFmt(
          '%s is declared %s and the text offered is not an integer.',
          [APath, FieldTypeName(AField.FieldType)]);
  else
    Mismatch(APath, AField, AValue);
  end;
end;

function AsUnsigned(AValue: TDynamicValue; AField: TProtoFieldDescriptor;
  const APath: string): UInt64;
begin
  if AValue.Kind = TDynamicKind.UInt then Exit(AValue.AsUInt);
  Result := UInt64(AsInteger(AValue, AField, APath));
end;

function AsReal(AValue: TDynamicValue; AField: TProtoFieldDescriptor;
  const APath: string): Double;
var
  V: Double;
begin
  Result := 0;
  case AValue.Kind of
    TDynamicKind.Float: Result := AValue.AsFloat;
    TDynamicKind.Int:   Result := AValue.AsInt;
    TDynamicKind.UInt:  Result := AValue.AsUInt;
    TDynamicKind.Str, TDynamicKind.Decimal:
      begin
        { Through Core: the RTL misreads 17-digit text on Win64. }
        if not TStructuralText.TryParseFloat(DynamicText(AValue), V) then
          raise EProtobufInternalError.CreateFmt(
            '%s is declared %s and the text offered is not a number.',
            [APath, FieldTypeName(AField.FieldType)]);
        Result := V;
      end;
  else
    Mismatch(APath, AField, AValue);
  end;
end;

function AsBoolean(AValue: TDynamicValue; AField: TProtoFieldDescriptor;
  const APath: string): Boolean;
begin
  Result := False;
  case AValue.Kind of
    TDynamicKind.Bool: Result := AValue.AsBool;
    TDynamicKind.Int:  Result := AValue.AsInt <> 0;
    TDynamicKind.Str:
      if AValue.AsStr = 'true' then Result := True
      else if AValue.AsStr = 'false' then Result := False
      else Mismatch(APath, AField, AValue);
  else
    Mismatch(APath, AField, AValue);
  end;
end;

function AsOctets(AValue: TDynamicValue; AField: TProtoFieldDescriptor;
  const APath: string): TBytes;
begin
  Result := nil;
  case AValue.Kind of
    TDynamicKind.Bytes: Result := AValue.AsBytes;
    { Base64 BECAUSE THE DESCRIPTOR SAYS BYTES. It is the proto3 JSON
      mapping's spelling and the one every text destination here writes, so
      a document that went out through JSON comes back whole. }
    TDynamicKind.Str:
      if not TStructuralText.TryDecodeBinary(AValue.AsStr, Result) then
        raise EProtobufInternalError.CreateFmt(
          '%s is declared bytes and the text offered is not base64.',
          [APath]);
  else
    Mismatch(APath, AField, AValue);
  end;
end;

function AsText(AValue: TDynamicValue; AField: TProtoFieldDescriptor;
  const APath: string): string;
begin
  Result := '';
  case AValue.Kind of
    TDynamicKind.Str:     Result := AValue.AsStr;
    TDynamicKind.Int:     Result := IntToStr(AValue.AsInt);
    TDynamicKind.UInt:    Result := UIntToStr(AValue.AsUInt);
    TDynamicKind.Decimal: Result := AValue.AsDecimal;
    TDynamicKind.Bool:
      if AValue.AsBool then Result := 'true' else Result := 'false';
    TDynamicKind.DateTime:
      Result := TStructuralText.EncodeDateTime(AValue.AsDateTime);
  else
    Mismatch(APath, AField, AValue);
  end;
end;

function AsEnumNumber(AValue: TDynamicValue; AField: TProtoFieldDescriptor;
  const APath: string): Integer;
var
  Number, I: Integer;
  Names: TStringList;
begin
  if AValue.Kind = TDynamicKind.Str then
  begin
    if (AField.EnumType <> nil) and
       AField.EnumType.TryNumber(AValue.AsStr, Number) then
      Exit(Number);
    Names := TStringList.Create;
    try
      if AField.EnumType <> nil then
        for I := 0 to AField.EnumType.ValueCount - 1 do
          Names.Add(AField.EnumType.ValueNames[I]);
      raise EProtobufInternalError.CreateFmt(
        '%s is enum %s and has no value called %s. It has: %s.',
        [APath, AField.TypeName, AValue.AsStr,
         String.Join(', ', Names.ToStringArray)]);
    finally
      Names.Free;
    end;
  end;
  Result := Integer(AsInteger(AValue, AField, APath));
end;

{ The payload of one value, with no tag in front of it - which is what a
  packed run is made of, and what a tagged field is after its tag. }
procedure WriteScalarPayload(AField: TProtoFieldDescriptor;
  AValue: TDynamicValue; var AWriter: TProtoWriter; const APath: string;
  ADepth: Integer);
var
  D: Double;
  S: Single;
  Instant: TDateTime;
  Mark: Integer;
  Seconds, Ms: Int64;
  Nanos: Integer;
begin
  case AField.FieldType of
    TProtoFieldType.Double:
      begin
        D := AsReal(AValue, AField, APath);
        AWriter.PutFixed64(PUInt64(@D)^);
      end;
    TProtoFieldType.Float:
      begin
        S := AsReal(AValue, AField, APath);
        AWriter.PutFixed32(PUInt32(@S)^);
      end;
    TProtoFieldType.Int64, TProtoFieldType.Int32:
      AWriter.PutVarint(UInt64(AsInteger(AValue, AField, APath)));
    TProtoFieldType.UInt64:
      AWriter.PutVarint(AsUnsigned(AValue, AField, APath));
    TProtoFieldType.UInt32:
      AWriter.PutVarint(UInt32(AsInteger(AValue, AField, APath)));
    TProtoFieldType.Fixed64:
      AWriter.PutFixed64(AsUnsigned(AValue, AField, APath));
    TProtoFieldType.Fixed32:
      AWriter.PutFixed32(UInt32(AsInteger(AValue, AField, APath)));
    TProtoFieldType.SFixed64:
      AWriter.PutFixed64(UInt64(AsInteger(AValue, AField, APath)));
    TProtoFieldType.SFixed32:
      AWriter.PutFixed32(UInt32(Integer(AsInteger(AValue, AField, APath))));
    TProtoFieldType.SInt64:
      AWriter.PutVarint(ZigZagEncode64(AsInteger(AValue, AField, APath)));
    TProtoFieldType.SInt32:
      AWriter.PutVarint(
        ZigZagEncode32(Integer(AsInteger(AValue, AField, APath))));
    TProtoFieldType.Bool:
      if AsBoolean(AValue, AField, APath) then AWriter.PutVarint(1)
      else AWriter.PutVarint(0);
    TProtoFieldType.Enum:
      { An enum is an int32 on the wire, so a negative number is
        sign-extended to sixty-four bits exactly as an int32 is. }
      AWriter.PutVarint(UInt64(Int64(AsEnumNumber(AValue, AField, APath))));
    TProtoFieldType.Text:
      AWriter.PutLengthDelimited(
        StringToUtf8Bytes(AsText(AValue, AField, APath)));
    TProtoFieldType.Bytes:
      AWriter.PutLengthDelimited(AsOctets(AValue, AField, APath));
    TProtoFieldType.Message:
      if AField.TypeName = WKT_TIMESTAMP then
      begin
        Instant := 0;
        case AValue.Kind of
          TDynamicKind.DateTime: Instant := AValue.AsDateTime;
          { An instant spelled as text BECAUSE THE DESCRIPTOR SAYS
            Timestamp. The proto3 JSON mapping writes this well-known type
            as an RFC 3339 string, and so does every text destination here,
            so a document that went out through JSON comes back whole. No
            other string field is read this way. }
          TDynamicKind.Str:
            if not TStructuralText.TryDecodeDateTime(AValue.AsStr, Instant) then
              raise EProtobufInternalError.CreateFmt(
                '%s is google.protobuf.Timestamp and the text offered is ' +
                'not an instant this library wrote.', [APath]);
        else
          Mismatch(APath, AField, AValue);
        end;
        { Through Core, as the engine writes one: a TDateTime before
          1899-12-30 is a negative day plus a POSITIVE time of day, and the
          linear (Instant - UnixDateDelta) * MSecsPerDay put every such
          instant a day early. Outside the years 1 to 9999 it is refused,
          because no reader here takes it back. }
        TStructuralText.CheckDateTime(Instant);
        if not TStructuralText.TryDateTimeToUnixMillis(Instant, Ms) then
          raise ESerializationUnsupported.CreateFmt(
            '%s is the TDateTime %s, which rounds to an instant after ' +
            '9999-12-31T23:59:59.999, and no reader here accepts it back.',
            [APath, FloatToStr(Instant, TFormatSettings.Invariant)]);
        Seconds := Ms div MSecsPerSec;
        Nanos := Integer(Ms mod MSecsPerSec) * 1000000;
        if Nanos < 0 then
        begin
          Dec(Seconds);
          Inc(Nanos, 1000000000);
        end;
        Mark := AWriter.BeginSubMessage;
        if Seconds <> 0 then
        begin
          AWriter.PutTag(TS_SECONDS, TProtoWireType.Varint);
          AWriter.PutVarint(UInt64(Seconds));
        end;
        if Nanos <> 0 then
        begin
          AWriter.PutTag(TS_NANOS, TProtoWireType.Varint);
          AWriter.PutVarint(UInt64(Int64(Nanos)));
        end;
        AWriter.EndSubMessage(Mark);
      end
      else
      begin
        if AValue.Kind <> TDynamicKind.Obj then
          Mismatch(APath, AField, AValue);
        Mark := AWriter.BeginSubMessage;
        WriteMessageDynamic(AField.MessageType, AValue, AWriter, APath,
          ADepth + 1);
        AWriter.EndSubMessage(Mark);
      end;
  else
    raise EProtobufSchemaError.CreateFmt(
      '%s is declared %s, which a structural conversion does not write.',
      [APath, FieldTypeName(AField.FieldType)]);
  end;
end;

procedure WriteTaggedValue(AField: TProtoFieldDescriptor;
  AValue: TDynamicValue; var AWriter: TProtoWriter; const APath: string;
  ADepth: Integer);
begin
  AWriter.PutTag(AField.Number, ExpectedWire(AField.FieldType));
  WriteScalarPayload(AField, AValue, AWriter, APath, ADepth);
end;

procedure WriteMapField(AField: TProtoFieldDescriptor; AValue: TDynamicValue;
  var AWriter: TProtoWriter; const APath: string; ADepth: Integer);
var
  KeyField, ValueField: TProtoFieldDescriptor;
  I, Mark: Integer;
  KeyNode: TDynamicValue;
begin
  if AValue.Kind <> TDynamicKind.Obj then Mismatch(APath, AField, AValue);
  KeyField := AField.MessageType.FieldByNumber(1);
  ValueField := AField.MessageType.FieldByNumber(2);
  if (KeyField = nil) or (ValueField = nil) then
    raise EProtobufSchemaError.CreateFmt(
      '%s is a map field whose entry type does not declare both field 1 ' +
      'and field 2.', [APath]);

  for I := 0 to AValue.Count - 1 do
  begin
    AWriter.PutTag(AField.Number, TProtoWireType.LengthDelimited);
    Mark := AWriter.BeginSubMessage;
    { The key is text in the tree and whatever the entry type says on the
      wire, so it goes back through the same conversion as any other value:
      a Str for an integer key parses because the descriptor authorizes it. }
    KeyNode := TDynamicValue.NewStr(AValue.Names[I]);
    try
      WriteTaggedValue(KeyField, KeyNode, AWriter, Where(APath, 'key'),
        ADepth);
    finally
      KeyNode.Free;
    end;
    if AValue.Items[I].Kind <> TDynamicKind.Null then
      WriteTaggedValue(ValueField, AValue.Items[I], AWriter,
        Where(APath, AValue.Names[I]), ADepth);
    AWriter.EndSubMessage(Mark);
  end;
end;

procedure WriteMessageDynamic(AMsg: TProtoMessageDescriptor;
  AValue: TDynamicValue; var AWriter: TProtoWriter; const APath: string;
  ADepth: Integer);
var
  I, J, Mark: Integer;
  F, Other: TProtoFieldDescriptor;
  Node: TDynamicValue;
  Seen: TDictionary<Integer, string>;
  Existing: string;
begin
  if ADepth > SCHEMA_MAX_DEPTH then
    raise EProtobufInternalError.CreateFmt(
      'Messages nested more than %d deep at %s.', [SCHEMA_MAX_DEPTH, APath]);
  if AValue.Kind <> TDynamicKind.Obj then
    raise EProtobufInternalError.CreateFmt(
      '%s is the message %s and the value offered is %s. Protobuf has no ' +
      'representation for a document that is not a message.',
      [APath, AMsg.FullName, AValue.Describe]);

  { Every member is accounted for BEFORE anything is written, so a tree with
    a member the descriptor does not know produces an error rather than a
    truncated message. Dropping data on the way INTO an encoding is the
    failure this library exists to prevent. }
  Seen := TDictionary<Integer, string>.Create;
  try
    for I := 0 to AValue.Count - 1 do
    begin
      Other := AMsg.FieldByName(AValue.Names[I]);
      if Other = nil then
        raise EProtobufInternalError.CreateFmt(
          '%s is not a field of %s. A protobuf message carries field ' +
          'NUMBERS, and a member the descriptor does not name has no ' +
          'number to be written under. The descriptor declares: %s.',
          [Where(APath, AValue.Names[I]), AMsg.FullName,
           String.Join(', ', FieldNamesOf(AMsg))]);
      if Seen.TryGetValue(Other.Number, Existing) then
        raise EProtobufInternalError.CreateFmt(
          '%s and %s are both field %d of %s - one by its declared name and ' +
          'one by its json_name. Which of the two is meant has no answer.',
          [Where(APath, Existing), Where(APath, AValue.Names[I]),
           Other.Number, AMsg.FullName]);
      Seen.AddOrSetValue(Other.Number, AValue.Names[I]);
    end;
  finally
    Seen.Free;
  end;

  { Written in DECLARED order rather than the tree's, so that two trees with
    the same members produce the same bytes. }
  for I := 0 to AMsg.FieldCount - 1 do
  begin
    F := AMsg.Fields[I];
    Node := AValue.Find(F.Name);
    if Node = nil then Node := AValue.Find(F.JsonName);
    if Node = nil then Continue;
    { A null is an absent field. proto3 has no null, and writing a zero for
      one would be inventing a value the tree does not contain. }
    if Node.Kind = TDynamicKind.Null then Continue;

    if F.IsMap then
      WriteMapField(F, Node, AWriter, Where(APath, F.Name), ADepth)
    else if F.IsRepeated then
    begin
      if Node.Kind <> TDynamicKind.Arr then
        raise EProtobufInternalError.CreateFmt(
          '%s is repeated and the value offered is %s. A repeated field is ' +
          'an array, with one element or with none.',
          [Where(APath, F.Name), Node.Describe]);
      if F.IsPacked and (Node.Count > 0) then
      begin
        AWriter.PutTag(F.Number, TProtoWireType.LengthDelimited);
        Mark := AWriter.BeginSubMessage;
        for J := 0 to Node.Count - 1 do
          WriteScalarPayload(F, Node.Items[J], AWriter,
            Where(APath, F.Name), ADepth);
        AWriter.EndSubMessage(Mark);
      end
      else
        for J := 0 to Node.Count - 1 do
          WriteTaggedValue(F, Node.Items[J], AWriter, Where(APath, F.Name),
            ADepth);
    end
    else
      WriteTaggedValue(F, Node, AWriter, Where(APath, F.Name), ADepth);
  end;
end;

function WriteRootMessage(AMsg: TProtoMessageDescriptor;
  AValue: TDynamicValue): TBytes;
var
  Writer: TProtoWriter;
begin
  Writer.Init;
  WriteMessageDynamic(AMsg, AValue, Writer, '', 0);
  Result := Writer.Done;
end;

{ ---------------------------------------------------------- entry points - }

function TProtobufSchema.ToDynamic(const AData: TBytes): TDynamicValue;
begin
  Result := MessageToDynamic(RootMessage, AData, '', 0);
end;

function TProtobufSchema.ToDynamic(const AData: TBytes;
  const AMessageName: string): TDynamicValue;
begin
  Result := MessageToDynamic(RequireMessage(AMessageName), AData, '', 0);
end;

function TProtobufSchema.FromDynamic(AValue: TDynamicValue): TBytes;
begin
  Result := WriteRootMessage(RootMessage, AValue);
end;

function TProtobufSchema.FromDynamic(AValue: TDynamicValue;
  const AMessageName: string): TBytes;
begin
  Result := WriteRootMessage(RequireMessage(AMessageName), AValue);
end;


{ --- TProtobufSerializationContext ---------------------------------------- }

constructor TProtobufSerializationContext.Create(ASchema: TProtobufSchema;
  const AMessageFullName: string);
begin
  inherited Create;
  if ASchema = nil then
    raise EProtobufSchemaError.Create(
      'A Protobuf context needs the descriptor set its message is in.');
  { Checked here rather than at conversion time: a name that is not in the
    set is a caller mistake, and finding it at the call that made it is worth
    more than finding it three layers down. }
  if AMessageFullName <> '' then ASchema.RequireMessage(AMessageFullName);
  FSchema := ASchema;
  FMessageFullName := AMessageFullName;
end;

function TProtobufSerializationContext.Format: TSerializationFormat;
begin
  Result := TSerializationFormat.Protobuf;
end;

function TProtobufSerializationContext.Message: TProtoMessageDescriptor;
begin
  if FMessageFullName <> '' then Exit(FSchema.RequireMessage(FMessageFullName));
  { No name here: the schema's own, or its sole message, and the schema
    raises with the candidates when there is neither. }
  Result := FSchema.RootMessage;
end;

function TProtobufSerializationContext.Describe: string;
begin
  if FMessageFullName <> '' then Exit(FMessageFullName);
  Result := FSchema.Describe;
end;

end.
