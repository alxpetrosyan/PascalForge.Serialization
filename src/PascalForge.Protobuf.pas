{*******************************************************************************
  PascalForge.Protobuf

  Public Protocol Buffers serialization facade for PascalForge.Serialization.

  Responsibilities
    - Typed protobuf serialization/deserialization driven by [ProtoField].
    - Structural conversion when a descriptor schema is supplied
      (PascalForge.Protobuf.Schema).
    - Protobuf-specific attributes, options and customization API.

  Registration
    Direct TProtobufSerializer use does not require format registration.
    Generic TSerialization operations require explicit registration:
    TProtobufSerializationRegistration.RegisterFormat
    (PascalForge.Protobuf.Registration).

  Configuration
    Global serializer configuration becomes immutable after first use.

  Threading
    Serialization is safe for concurrent use after configuration is frozen.

  Documentation
    docs/formats/protobuf.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Protobuf;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  Protocol Buffers.

      Bytes := TProtobufSerializer.Serialize<TShipment>(Shipment);
      Shipment := TProtobufSerializer.Deserialize<TShipment>(Bytes);

  PROTOBUF IS NOT SELF-DESCRIBING, and everything about this unit follows
  from that one fact.

  A protobuf message on the wire is a sequence of (field number, wire type,
  payload). There are no names. A length-delimited field might be a string,
  a byte array, a nested message or a packed repeated field, and nothing in
  the bytes says which. Without a schema, a reader can recover the shape and
  not the meaning.

  So this unit needs a schema, and the schema is the Delphi type plus one
  attribute per member:

      type
        TShipment = class
        public
          [ProtoField(1)] Id: Int64;
          [ProtoField(2)] Reference: string;
          [ProtoField(3), ProtoType(TProtoScalar.SInt64)] Delta: Int64;
          [ProtoField(4)] Lines: TObjectList<TLine>;
        end;

  A member with no [ProtoField] is not serialized, and a member whose number
  collides with another's is an error when the plan is built rather than a
  silent overwrite at run time.

  WHAT THIS MEANS FOR CONVERSION.  Protobuf takes part in contract-aware
  conversion, where the Delphi type supplies the schema. It takes part in
  STRUCTURAL conversion - bytes into the dynamic tree, with no Delphi type
  anywhere - exactly when the caller supplies the descriptor those bytes
  were written against:

      Schema := TProtobufSchema.LoadDescriptorSet(DescriptorBytes);

  which is PascalForge.Protobuf.Schema, and which reads the same
  FileDescriptorSet protoc emits for --descriptor_set_out. Handed one in the
  conversion options, the handler parses and writes structurally; handed
  nothing, it raises ESerializationSchemaRequired - not the capability
  error, because the format CAN do this and would, given the schema. Its
  Capabilities answer the same way, from the options rather than from a
  constant. See docs\protobuf-compatibility.md.

  WHAT IS NOT HERE.  There is no .proto parser and no code generator. A
  .proto file is protoc's input, and a FileDescriptorSet is protoc's output;
  that output is itself an ordinary protobuf message, so reading it needs
  this unit's codec and nothing else. Generating Delphi source is a
  different program and remains one.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections,
  PascalForge.Serialization.Core;

type
  { Everything this unit raises descends from here. }
  EProtobufError = class(Exception);
  { The bytes are at fault: truncated, a bad tag, a length that overruns. }
  EProtobufInputError = class(EProtobufError);
  { The model or the configuration is at fault: a missing field number, a
    duplicate one, a type protobuf cannot carry. }
  EProtobufInternalError = class(EProtobufError);

  { The six wire types. Two of them - StartGroup and EndGroup - are proto2's
    groups, deprecated but still present in documents that exist, so they are
    read. }
  TProtoWireType = (
    Varint = 0,
    Fixed64 = 1,
    LengthDelimited = 2,
    StartGroup = 3,
    EndGroup = 4,
    Fixed32 = 5
  );

  { The .proto scalar a member maps to.

    Auto picks the obvious one from the Delphi type - int32 for an Integer,
    int64 for an Int64, string for a string - and that is right most of the
    time. It is worth overriding in two cases:

      SInt32/SInt64  zig-zag. A field that is often negative costs ten bytes
                     as an int64 and two as an sint64, because a negative
                     varint is sign-extended to 64 bits first.
      Fixed*         four or eight bytes always. Cheaper than a varint for a
                     value that is usually large, dearer for one usually
                     small. }
  TProtoScalar = (
    Auto,
    Int32, Int64, UInt32, UInt64,
    SInt32, SInt64,
    Fixed32, Fixed64, SFixed32, SFixed64,
    Float, Double,
    Bool, Text, Bytes,
    { A protobuf enum is an int32 on the wire, and an unknown number is NOT
      an error: proto3 says a reader keeps it. }
    EnumValue
  );

  { The field number. Required on every member that is to be serialized.

    Valid numbers are 1..536870911, and 19000..19999 are reserved by the
    specification. Both are checked when the plan is built. }
  ProtoFieldAttribute = class(TCustomAttribute)
  strict private
    FNumber: Integer;
  public
    constructor Create(ANumber: Integer);
    property Number: Integer read FNumber;
  end;

  { Overrides the .proto scalar the member maps to. }
  ProtoTypeAttribute = class(TCustomAttribute)
  strict private
    FScalar: TProtoScalar;
  public
    constructor Create(AScalar: TProtoScalar);
    property Scalar: TProtoScalar read FScalar;
  end;

  { Never written, never read - the same as leaving the field number off,
    but explicit. }
  ProtoIgnoreAttribute = class(TCustomAttribute)
  end;

  { Whether a repeated numeric field is packed into one length-delimited
    run. proto3 packs by default and this follows; a reader accepts both
    spellings regardless, as the specification requires. }
  ProtoPackedAttribute = class(TCustomAttribute)
  strict private
    FPacked: Boolean;
  public
    constructor Create(APacked: Boolean = True);
    property IsPacked: Boolean read FPacked;
  end;

  { Members sharing a oneof name are mutually exclusive: at most one is
    written, and reading one clears the others. Give the members explicit
    presence - TNullable<T> for a scalar, a class reference for a message -
    so that "which one is set" has an answer. }
  ProtoOneOfAttribute = class(TCustomAttribute)
  strict private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

  { Marks a TBytes member as the store for fields the schema does not know.

    proto3 requires a conforming implementation to preserve unknown fields
    across a round trip, and a Delphi DTO has nowhere to put them unless it
    says so. Declare one of these and they survive; leave it out and they
    are dropped, which is stated in docs\protobuf-behavior.md rather than
    left to be discovered. }
  ProtoUnknownAttribute = class(TCustomAttribute)
  end;

  { Names the custom serializer for one member. }
  TProtoValueSerializerClass = class of TCustomProtoValueSerializerBase;

  TCustomProtoValueSerializerBase = class
  public
    { The value as its wire bytes, and the wire type they are. }
    function Serialize(const AValue: TValue;
      out AWireType: TProtoWireType): TBytes; virtual; abstract;
    function Deserialize(const AData: TBytes; AWireType: TProtoWireType;
      ATypeInfo: PTypeInfo; const AExisting: TValue): TValue; virtual; abstract;
  end;

  { The typed base, and the one to use: it names the Delphi type, so an
    implementation never touches TValue or PTypeInfo. }
  TCustomProtoValueSerializer<T> = class(TCustomProtoValueSerializerBase)
  public
    function SerializeValue(const AValue: T;
      out AWireType: TProtoWireType): TBytes; virtual; abstract;
    function DeserializeValue(const AData: TBytes;
      AWireType: TProtoWireType; const AExisting: T): T; virtual; abstract;

    function Serialize(const AValue: TValue;
      out AWireType: TProtoWireType): TBytes; override; final;
    function Deserialize(const AData: TBytes; AWireType: TProtoWireType;
      ATypeInfo: PTypeInfo; const AExisting: TValue): TValue; override; final;
  end;

  ProtoSerializerAttribute = class(TCustomAttribute)
  strict private
    FSerializerClass: TProtoValueSerializerClass;
  public
    constructor Create(ASerializerClass: TProtoValueSerializerClass);
    property SerializerClass: TProtoValueSerializerClass read FSerializerClass;
  end;

  { An external descriptor, seen from the engine's side.

    The descriptor model itself is TProtobufSchema in
    PascalForge.Protobuf.Schema, which reads a FileDescriptorSet with this
    unit's own codec and therefore sits ABOVE the engine. The engine still
    has one question to ask it - "what does the .proto actually say field N
    is" - so that question is declared here, as an abstract class the schema
    unit implements. The dependency then points the right way and there is
    no cycle.

    WHY A DESCRIPTOR WINS. A Delphi member's wire form is inferred from its
    Delphi type, which is this side's opinion about the data. A descriptor
    is the .proto the OTHER side was compiled against. When the two
    disagree, the one that both ends share is the one that is right. }
  TProtobufDescriptorSchema = class(TSerializationSchema)
  public
    { False when the descriptor does not mention this field number, and the
      Delphi-derived default then stands unchanged. }
    function TryFieldScalar(ANumber: Integer;
      out AScalar: TProtoScalar): Boolean; virtual; abstract;
  end;

  { Per-operation options. }
  TProtobufSerializationOptions = record
  public
    { Whether a repeated numeric field is written packed. Default True,
      which is proto3's default. Reading accepts both either way. }
    PackRepeated: Boolean;
    { The descriptor the ROOT message is written and read against, or nil
      for the Delphi-derived default. BORROWED - nothing here frees it.

      It applies to the root message only. Field numbers are scoped to a
      message, so field 1 of the root and field 1 of some nested message are
      unrelated, and a schema that knew only the root's numbers would
      otherwise reinterpret every message in the tree. }
    Schema: TProtobufDescriptorSchema;
    class function Default: TProtobufSerializationOptions; static;
  end;

  { A message and the fields this build of the program did not recognize.

    proto3 requires a reader to preserve what it does not understand, and a
    Delphi DTO has nowhere to keep it. [ProtoUnknown] gives one MEMBER
    somewhere to put it; this record gives the CALLER somewhere, so a DTO
    that cannot be changed - generated, shared, or someone else's - still
    round-trips whole.

    WHAT IS PRESERVED, exactly: the unrecognized fields of the ROOT message,
    tag bytes included, in the order they arrived. Unrecognized fields of a
    NESTED message are not here, because putting them back would mean
    knowing which nested message they came out of, and the envelope does not
    carry a path. A nested message that must keep its own unknown fields
    declares a [ProtoUnknown] member, which works at any depth.

    WHERE THEY GO BACK. SerializeMessage writes every known field first and
    then appends these bytes unchanged. Protobuf does not define an order
    for fields, so this is a conforming message; it is not, however,
    byte-identical to the original when the original interleaved unknown
    fields with known ones. }
  TProtobufMessage<T> = record
  public
    Value: T;
    UnknownFields: TBytes;
    function HasUnknownFields: Boolean;
  end;

  TProtobufSerializer = class
  strict private
    { A generic method body declared in an interface section may reference
      only interface-declared symbols, so every generic entry point below is
      a thin shell over one of these. }
    class function DoSerialize(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AOptions: TProtobufSerializationOptions): TBytes; static;
    class function DoDeserialize(ATypeInfo: PTypeInfo;
      const AData: TBytes): TValue; static;
    class function DoDeserializeWith(ATypeInfo: PTypeInfo;
      const AData: TBytes;
      const AOptions: TProtobufSerializationOptions): TValue; static;
    class function DoDeserializeMessage(ATypeInfo: PTypeInfo;
      const AData: TBytes; const AOptions: TProtobufSerializationOptions;
      out AUnknown: TBytes): TValue; static;
    class function DoSerializeMessage(ATypeInfo: PTypeInfo;
      const AValue: TValue; const AUnknown: TBytes;
      const AOptions: TProtobufSerializationOptions): TBytes; static;
    class procedure DoPopulate(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AData: TBytes); static;
    class function DoFrom(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; static;
    class procedure DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TProtoValueSerializerClass); static;
    class procedure DoRegisterEnumNumbers(ATypeInfo: PTypeInfo;
      const ANumbers: array of Integer); static;
  public
    { --- the normal API ---------------------------------------------------- }
    class function Serialize<T>(const AValue: T): TBytes; overload; static;
    class function Serialize<T>(const AValue: T;
      const AOptions: TProtobufSerializationOptions): TBytes; overload; static;

    class function Deserialize<T>(const AData: TBytes): T; overload; static;
    class function Deserialize<T>(const AData: TBytes;
      const AOptions: TProtobufSerializationOptions): T; overload; static;

    { --- the unknown-field envelope ----------------------------------------

      Plain Deserialize<T> DISCARDS a field T does not declare, unless T has
      a [ProtoUnknown] member to keep it in. These two keep it without any
      change to T:

          Msg := TProtobufSerializer.DeserializeMessage<TNarrow>(Wire);
          ... work on Msg.Value ...
          Wire := TProtobufSerializer.SerializeMessage<TNarrow>(Msg);

      Root-level fields only, and written back after the known ones. The
      declaration of TProtobufMessage<T> says exactly what that does and
      does not preserve.

      When T DOES have a [ProtoUnknown] member, that member holds the
      unknown fields and UnknownFields comes back empty - one copy, in one
      place, so that writing the message back cannot emit them twice. }
    class function DeserializeMessage<T>(
      const AData: TBytes): TProtobufMessage<T>; overload; static;
    class function DeserializeMessage<T>(const AData: TBytes;
      const AOptions: TProtobufSerializationOptions):
      TProtobufMessage<T>; overload; static;
    class function SerializeMessage<T>(
      const AMessage: TProtobufMessage<T>): TBytes; overload; static;
    class function SerializeMessage<T>(const AMessage: TProtobufMessage<T>;
      const AOptions: TProtobufSerializationOptions): TBytes; overload; static;

    { Fills an instance that already exists, with the same reuse rules the
      whole library uses: a nested instance that is already there is
      populated in place, never replaced. }
    class procedure Populate<T>(const AInstance: T; const AData: TBytes); static;

    { --- destination-oriented conversion -----------------------------------

      Protobuf is the destination and is known at compile time, so only the
      SOURCE format is looked up, through the registry.

      There is no non-generic form. A structural conversion into protobuf
      would have to invent field numbers, and inventing them is how two
      programs end up disagreeing about what field 3 means. }
    class function From<T>(const ASource: string;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From<T>(const ASource: TBytes;
      AFrom: TSerializationFormat): TBytes; overload; static;
    class function From<T>(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): TBytes; overload; static;

    { --- registrations -----------------------------------------------------

      A protobuf enum is a NUMBER on the wire, and the numbers a .proto file
      assigns need not be 0, 1, 2 in order. This says which number each
      Delphi ordinal is:

          TProtobufSerializer.RegisterEnumNumbers<TPriority>([0, 5, 10]);

      Without it, the ordinal is the number, which is right whenever the
      .proto was written to match. }
    class procedure RegisterEnumNumbers<T>(
      const ANumbers: array of Integer); static;

    { A custom serializer for every value of a type. }
    class procedure RegisterTypeSerializer<T>(
      ASerializerClass: TProtoValueSerializerClass); static;

    { --- configuration lifecycle -------------------------------------------

      After this, a registration raises instead of being a silent no-op. A
      plan is cached the first time a type is used, so a late registration
      would otherwise change nothing at all. }
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;
    { Tests only. }
    class procedure ResetConfiguration; static;
  end;

implementation

uses
  PascalForge.Protobuf.Internal;

{ ------------------------------------------------------------ attributes --- }

constructor ProtoFieldAttribute.Create(ANumber: Integer);
begin
  inherited Create;
  FNumber := ANumber;
end;

constructor ProtoTypeAttribute.Create(AScalar: TProtoScalar);
begin
  inherited Create;
  FScalar := AScalar;
end;

constructor ProtoPackedAttribute.Create(APacked: Boolean);
begin
  inherited Create;
  FPacked := APacked;
end;

constructor ProtoOneOfAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

constructor ProtoSerializerAttribute.Create(
  ASerializerClass: TProtoValueSerializerClass);
begin
  inherited Create;
  FSerializerClass := ASerializerClass;
end;

{ ------------------------------------------------------ typed serializer --- }

function TCustomProtoValueSerializer<T>.Serialize(const AValue: TValue;
  out AWireType: TProtoWireType): TBytes;
begin
  Result := SerializeValue(AValue.AsType<T>, AWireType);
end;

function TCustomProtoValueSerializer<T>.Deserialize(const AData: TBytes;
  AWireType: TProtoWireType; ATypeInfo: PTypeInfo;
  const AExisting: TValue): TValue;
var
  Existing: T;
begin
  if AExisting.IsEmpty then Existing := System.Default(T)
  else Existing := AExisting.AsType<T>;
  Result := TValue.From<T>(DeserializeValue(AData, AWireType, Existing));
end;

{ --------------------------------------------------------------- options --- }

class function TProtobufSerializationOptions.Default: TProtobufSerializationOptions;
begin
  Result.PackRepeated := True;
  Result.Schema := nil;
end;

{ --------------------------------------------------------------- envelope --- }

function TProtobufMessage<T>.HasUnknownFields: Boolean;
begin
  Result := Length(UnknownFields) > 0;
end;

{ --------------------------------------------------------------- bridges --- }

class function TProtobufSerializer.DoSerialize(ATypeInfo: PTypeInfo;
  const AValue: TValue;
  const AOptions: TProtobufSerializationOptions): TBytes;
begin
  Result := TProtoEngine.SerializeRoot(ATypeInfo, AValue, AOptions);
end;

class function TProtobufSerializer.DoDeserialize(ATypeInfo: PTypeInfo;
  const AData: TBytes): TValue;
begin
  Result := TProtoEngine.DeserializeRoot(ATypeInfo, AData, TValue.Empty);
end;

class function TProtobufSerializer.DoDeserializeWith(ATypeInfo: PTypeInfo;
  const AData: TBytes;
  const AOptions: TProtobufSerializationOptions): TValue;
begin
  Result := TProtoEngine.DeserializeRoot(ATypeInfo, AData, TValue.Empty,
    AOptions);
end;

class function TProtobufSerializer.DoDeserializeMessage(ATypeInfo: PTypeInfo;
  const AData: TBytes; const AOptions: TProtobufSerializationOptions;
  out AUnknown: TBytes): TValue;
begin
  Result := TProtoEngine.DeserializeRootKeepingUnknown(ATypeInfo, AData,
    AOptions, AUnknown);
end;

class function TProtobufSerializer.DoSerializeMessage(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AUnknown: TBytes;
  const AOptions: TProtobufSerializationOptions): TBytes;
begin
  Result := TProtoEngine.SerializeRootWithUnknown(ATypeInfo, AValue, AUnknown,
    AOptions);
end;

class procedure TProtobufSerializer.DoPopulate(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AData: TBytes);
begin
  TProtoEngine.DeserializeRoot(ATypeInfo, AData, AValue);
end;

class function TProtobufSerializer.DoFrom(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := TProtoEngine.FromPayload(ATypeInfo, ASource, AFrom);
end;

class procedure TProtobufSerializer.DoRegisterTypeSerializer(
  ATypeInfo: PTypeInfo; ASerializerClass: TProtoValueSerializerClass);
begin
  TProtoEngine.RegisterTypeSerializer(ATypeInfo, ASerializerClass);
end;

class procedure TProtobufSerializer.DoRegisterEnumNumbers(ATypeInfo: PTypeInfo;
  const ANumbers: array of Integer);
begin
  TProtoEngine.RegisterEnumNumbers(ATypeInfo, ANumbers);
end;

{ ------------------------------------------------------------ operations --- }

class function TProtobufSerializer.Serialize<T>(const AValue: T): TBytes;
begin
  Result := Serialize<T>(AValue, TProtobufSerializationOptions.Default);
end;

class function TProtobufSerializer.Serialize<T>(const AValue: T;
  const AOptions: TProtobufSerializationOptions): TBytes;
var
  V: TValue;
begin
  TValue.Make(@AValue, System.TypeInfo(T), V);
  Result := DoSerialize(System.TypeInfo(T), V, AOptions);
end;

class function TProtobufSerializer.Deserialize<T>(const AData: TBytes): T;
begin
  Result := DoDeserialize(System.TypeInfo(T), AData).AsType<T>;
end;

class function TProtobufSerializer.Deserialize<T>(const AData: TBytes;
  const AOptions: TProtobufSerializationOptions): T;
begin
  Result := DoDeserializeWith(System.TypeInfo(T), AData, AOptions).AsType<T>;
end;

class function TProtobufSerializer.DeserializeMessage<T>(
  const AData: TBytes): TProtobufMessage<T>;
begin
  Result := DeserializeMessage<T>(AData, TProtobufSerializationOptions.Default);
end;

class function TProtobufSerializer.DeserializeMessage<T>(const AData: TBytes;
  const AOptions: TProtobufSerializationOptions): TProtobufMessage<T>;
var
  Unknown: TBytes;
begin
  Result.Value := DoDeserializeMessage(System.TypeInfo(T), AData, AOptions,
    Unknown).AsType<T>;
  Result.UnknownFields := Unknown;
end;

class function TProtobufSerializer.SerializeMessage<T>(
  const AMessage: TProtobufMessage<T>): TBytes;
begin
  Result := SerializeMessage<T>(AMessage,
    TProtobufSerializationOptions.Default);
end;

class function TProtobufSerializer.SerializeMessage<T>(
  const AMessage: TProtobufMessage<T>;
  const AOptions: TProtobufSerializationOptions): TBytes;
var
  V: TValue;
begin
  TValue.Make(@AMessage.Value, System.TypeInfo(T), V);
  Result := DoSerializeMessage(System.TypeInfo(T), V, AMessage.UnknownFields,
    AOptions);
end;

class procedure TProtobufSerializer.Populate<T>(const AInstance: T;
  const AData: TBytes);
var
  V: TValue;
begin
  TValue.Make(@AInstance, System.TypeInfo(T), V);
  DoPopulate(System.TypeInfo(T), V, AData);
end;

class function TProtobufSerializer.From<T>(const ASource: string;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From<T>(TSerializationPayload.FromText(ASource), AFrom);
end;

class function TProtobufSerializer.From<T>(const ASource: TBytes;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := From<T>(TSerializationPayload.FromBytes(ASource), AFrom);
end;

class function TProtobufSerializer.From<T>(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): TBytes;
begin
  Result := DoFrom(System.TypeInfo(T), ASource, AFrom);
end;

class procedure TProtobufSerializer.RegisterEnumNumbers<T>(
  const ANumbers: array of Integer);
begin
  DoRegisterEnumNumbers(System.TypeInfo(T), ANumbers);
end;

class procedure TProtobufSerializer.RegisterTypeSerializer<T>(
  ASerializerClass: TProtoValueSerializerClass);
begin
  DoRegisterTypeSerializer(System.TypeInfo(T), ASerializerClass);
end;

class procedure TProtobufSerializer.FreezeConfiguration;
begin
  TProtoEngine.FreezeConfiguration;
end;

class function TProtobufSerializer.IsFrozen: Boolean;
begin
  Result := TProtoEngine.IsFrozen;
end;

class procedure TProtobufSerializer.ResetConfiguration;
begin
  TProtoEngine.ResetConfiguration;
end;

end.
