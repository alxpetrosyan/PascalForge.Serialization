unit DynamicModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The Delphi types the Dynamic tests project. Declared in a unit's interface,
  as application types are, so their RTTI is complete. }

interface

uses
  System.SysUtils, System.Generics.Collections,
  PascalForge.Nullable,
  PascalForge.Serialization.Attributes,
  PascalForge.DataSet;

type
  [SerializationEnum('pending, in-progress, done')]
  TTaskState = (Pending, InProgress, Done);

  TColor = (Red, Green, Blue);
  TColors = set of TColor;
  TTaskStates = set of TTaskState;

  TStateHolder = record
    State: TTaskState;
  end;

  { [SerializationEnum] on TTaskState, reached through every container. }
  TEnumContainers = class
  strict private
    FItems: TList<TTaskState>;
    FByState: TDictionary<TTaskState, TTaskState>;
  public
    Direct: TTaskState;
    Maybe: TNullable<TTaskState>;
    States: TTaskStates;
    Arr: TArray<TTaskState>;
    Inner: TStateHolder;
    constructor Create;
    destructor Destroy; override;
    property Items: TList<TTaskState> read FItems;
    property ByState: TDictionary<TTaskState, TTaskState> read FByState;
  end;

  { A chain, for the depth limit. }
  TNode = class
  strict private
    FChildren: TObjectList<TNode>;
  public
    Value: Integer;
    Next: TNode;
    constructor Create;
    destructor Destroy; override;
    property Children: TObjectList<TNode> read FChildren;
  end;

  TVariantHolder = class
  public
    V: Variant;
  end;
  { Named: an inline array type has no RTTI, and every format refuses it. }
  TThree = array[0..2] of Integer;

  TAddress = class
  public
    City: string;
    Country: string;
  end;

  TPerson = class
  strict private
    FAddress: TAddress;
    FTags: TList<string>;
  public
    Name: string;
    Age: Integer;
    Active: Boolean;
    constructor Create;
    destructor Destroy; override;
    property Address: TAddress read FAddress;
    property Tags: TList<string> read FTags;
  end;

  TPoint = record
    X: Integer;
    Y: Integer;
  end;

  { One member of every scalar kind the projection carries. }
  TEverything = class
  strict private
    FScores: TDictionary<string, Integer>;
    FPeople: TObjectList<TAddress>;
  public
    I8: ShortInt;
    U8: Byte;
    I32: Integer;
    U32: Cardinal;
    I64: Int64;
    U64: UInt64;
    F64: Double;
    F32: Single;
    Money: Currency;
    Day: TDate;
    Clock: TTime;
    Moment: TDateTime;
    Flag: Boolean;
    Text: string;
    Letter: Char;
    Blob: TBytes;
    Id: TGUID;
    Colors: TColors;
    State: TTaskState;
    Maybe: TNullable<Integer>;
    Missing: TNullable<string>;
    Anything: Variant;
    Ints: TArray<Integer>;
    Fixed: TThree;
    Point: TPoint;
    constructor Create;
    destructor Destroy; override;
    property Scores: TDictionary<string, Integer> read FScores;
    property People: TObjectList<TAddress> read FPeople;
  end;

  { The three general attributes. }
  TAttributed = class
  public
    [SerializationName('id')]
    Key: Integer;
    [SerializationIgnore]
    Secret: string;
    [SerializationEnum('r,g,b')]
    Color: TColor;
    State: TTaskState;
    Plain: string;
  end;

  { A type nothing has described yet, for the metadata-reuse check. }
  TFreshForMetadata = class
  public
    Alpha: Integer;
    Beta: string;
  end;

  { A DataSet row, with a DataSet attribute and a general one. }
  TOrderRow = class
  public
    [SerializationName('order_id')]
    Id: Integer;
    Customer: string;
    [DataSetName('TOTAL')]
    [SerializationName('total_general')]
    Total: Currency;
    [SerializationIgnore]
    Internal: string;
  end;

implementation

constructor TEnumContainers.Create;
begin
  inherited Create;
  FItems := TList<TTaskState>.Create;
  FByState := TDictionary<TTaskState, TTaskState>.Create;
end;

destructor TEnumContainers.Destroy;
begin
  FByState.Free;
  FItems.Free;
  inherited Destroy;
end;

constructor TNode.Create;
begin
  inherited Create;
  FChildren := TObjectList<TNode>.Create(True);
end;

destructor TNode.Destroy;
begin
  Next.Free;
  FChildren.Free;
  inherited Destroy;
end;

constructor TPerson.Create;
begin
  inherited Create;
  FAddress := TAddress.Create;
  FTags := TList<string>.Create;
end;

destructor TPerson.Destroy;
begin
  FTags.Free;
  FAddress.Free;
  inherited Destroy;
end;

constructor TEverything.Create;
begin
  inherited Create;
  FScores := TDictionary<string, Integer>.Create;
  FPeople := TObjectList<TAddress>.Create(True);
end;

destructor TEverything.Destroy;
begin
  FPeople.Free;
  FScores.Free;
  inherited Destroy;
end;

end.
