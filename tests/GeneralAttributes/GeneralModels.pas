unit GeneralModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The types the general-attribute tests serialize, declared in an interface
  section as application types are. }

interface

uses
  System.Generics.Collections,
  PascalForge.Nullable,
  PascalForge.Serialization.Attributes,
  PascalForge.Json, PascalForge.Xml, PascalForge.Bson, PascalForge.Cbor,
  PascalForge.MessagePack, PascalForge.Yaml, PascalForge.Csv,
  PascalForge.Avro, PascalForge.Protobuf, PascalForge.DataSet;

type
  [SerializationEnum('pending,in-progress,done')]
  TStage = (Pending, InProgress, Done);

  TShade = (Light, Dark);
  TStageSet = set of TStage;

  [SerializationEnum('low,high')]
  TLevel = (Lo, Hi);
  TLevelSet = set of TLevel;

  { The general mapping reached through every container a format carries. }
  TStageBox = class
  public
    { A field, not a read-only property: BSON and MessagePack do not fill
      an object a read-only property holds. }
    ByStage: TDictionary<TStage, Integer>;
    Direct: TStage;
    Maybe: TNullable<TStage>;
    Stages: TStageSet;
    Arr: TArray<TStage>;
    Level: TLevel;
    Levels: TLevelSet;
    constructor Create;
    destructor Destroy; override;
  end;

  { The same for a CSV row: CSV has no dictionary or list member. }
  TStageRow = class
  public
    Direct: TStage;
    Maybe: TNullable<TStage>;
    Stages: TStageSet;
    Level: TLevel;
  end;

  { The three general attributes, with no format-specific configuration. }
  TGeneral = class
  public
    [SerializationName('id')]
    Key: Integer;
    [SerializationIgnore]
    Secret: string;
    [SerializationEnum('l,d')]
    Shade: TShade;
    Stage: TStage;
    Plain: string;
  end;

  { The same for Protobuf, which needs a field number on every member. }
  TGeneralProto = class
  public
    [ProtoField(1)]
    Key: Integer;
    [ProtoField(2)]
    [SerializationIgnore]
    Secret: string;
    [ProtoField(3)]
    Stage: TStage;
  end;

  { A format's own configuration against the general one. }
  TPrecedence = class
  public
    [SerializationName('general')]
    [JsonName('json_attr')]
    [XmlName('xml_attr')]
    [BsonName('bson_attr')]
    [CborName('cbor_attr')]
    [MessagePackName('msgpack_attr')]
    [YamlName('yaml_attr')]
    A: Integer;
    { JSON gets a registered rename; every other format uses the general
      name. }
    [SerializationName('general_b')]
    B: Integer;
    { Ignored for JSON only; present everywhere else. }
    [JsonIgnore]
    C: Integer;
    { JSON gets a registered enumeration mapping; every other format uses
      the type's [SerializationEnum]. }
    Stage: TStage;
  end;

  { A DataSet row: a DataSet attribute beats the general one. }
  TPrecedenceRow = class
  public
    [DataSetName('DS_NAME')]
    [SerializationName('general')]
    A: Integer;
    [SerializationName('general_b')]
    B: Integer;
    [SerializationIgnore]
    C: Integer;
  end;

implementation

constructor TStageBox.Create;
begin
  inherited Create;
  ByStage := TDictionary<TStage, Integer>.Create;
end;

destructor TStageBox.Destroy;
begin
  ByStage.Free;
  inherited Destroy;
end;

end.
