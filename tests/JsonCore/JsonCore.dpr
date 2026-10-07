program JsonCore;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The public JSON surface, on neutral models.

  This is the synthetic regression for the published library: no company
  fixtures, no external corpus, nothing that cannot be read in one sitting. It
  covers the operations a user actually performs and the guarantees the
  documentation makes about them. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.JSON, System.Generics.Collections,
  System.DateUtils,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  { The Extended JSON checks reach the structural path, which has no public
    JSON-only facade; a test may use an engine unit. }
  PascalForge.Json.Internal;

var
  GFailures: Integer = 0;

procedure Check(ACondition: Boolean; const AName: string);
begin
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

type
  TStatus = (Draft, Active, Closed);

  TAddress = class
  public
    City: string;
    Zip: string;
  end;

  TCustomer = class
  private
    FAddress: TAddress;
  public
    Id: Integer;
    [JsonName('fullName')]
    Name: string;
    [JsonIgnore]
    Scratch: string;
    Status: TStatus;
    constructor Create;
    destructor Destroy; override;
    property Address: TAddress read FAddress;
  end;

  TPoint = record
    X: Integer;
    Y: Integer;
  end;

  TShape = class
  public
    Origin: TPoint;
    Label_: string;
  end;

  TBag = class
  private
    FItems: TObjectList<TAddress>;
    FTags: TList<string>;
  public
    constructor Create;
    destructor Destroy; override;
    property Items: TObjectList<TAddress> read FItems;
    property Tags: TList<string> read FTags;
  end;

constructor TCustomer.Create;
begin
  inherited Create;
  FAddress := TAddress.Create;
end;

destructor TCustomer.Destroy;
begin
  FAddress.Free;
  inherited Destroy;
end;

constructor TBag.Create;
begin
  inherited Create;
  FItems := TObjectList<TAddress>.Create(True);
  FTags := TList<string>.Create;
end;

destructor TBag.Destroy;
begin
  FTags.Free;
  FItems.Free;
  inherited Destroy;
end;

{ ------------------------------------------------------------- basics --- }

procedure TestBasics;

var
  C, Back: TCustomer;
  Json: string;
begin
  Writeln('-- classes, names, ignores --');
  C := TCustomer.Create;
  try
    C.Id := 7;
    C.Name := 'Ada';
    C.Scratch := 'must not appear';
    C.Status := TStatus.Active;
    C.Address.City := 'Midtown';
    C.Address.Zip := '0100';
    Json := TJsonSerializer.Serialize(C);
  finally
    C.Free;
  end;
  Note(Json);

  Check(Json.Contains('"fullName":"Ada"'), 'JSON_NAME_ATTRIBUTE');
  Check(not Json.Contains('must not appear'), 'JSON_IGNORE_ATTRIBUTE');
  Check(Json.Contains('"city":"Midtown"'), 'JSON_NESTED_CLASS');

  Back := TJsonSerializer.Deserialize<TCustomer>(Json);
  try
    Check((Back.Id = 7) and (Back.Name = 'Ada') and
      (Back.Status = TStatus.Active) and (Back.Address.City = 'Midtown'),
      'JSON_ROUNDTRIP');
    Check(Back.Scratch = '', 'JSON_IGNORED_MEMBER_NOT_READ');
  finally
    Back.Free;
  end;
end;

procedure TestRecords;
var
  S, Back: TShape;
  Json: string;
begin
  Writeln('-- records --');
  S := TShape.Create;
  try
    S.Origin.X := 3;
    S.Origin.Y := 4;
    S.Label_ := 'corner';
    Json := TJsonSerializer.Serialize(S);
  finally
    S.Free;
  end;
  Note(Json);
  Back := TJsonSerializer.Deserialize<TShape>(Json);
  try
    Check((Back.Origin.X = 3) and (Back.Origin.Y = 4), 'JSON_NESTED_RECORD');
  finally
    Back.Free;
  end;
end;

procedure TestPopulate;
var
  C: TCustomer;
  Kept: TAddress;
begin
  Writeln('-- populate an existing graph --');
  C := TCustomer.Create;
  try
    C.Id := 1;
    C.Name := 'before';
    C.Address.City := 'old';
    Kept := C.Address;

    TJsonSerializer.Populate(C, '{"id":2,"fullName":"after","address":{"city":"new"}}');

    Check((C.Id = 2) and (C.Name = 'after'), 'JSON_POPULATE');
    { The nested instance the caller owns is filled, not replaced. }
    Check((C.Address = Kept) and (C.Address.City = 'new'),
      'JSON_POPULATE_REUSES_INSTANCE');
  finally
    C.Free;
  end;
end;

procedure TestCollections;
var
  B, Back: TBag;
  A: TAddress;
  Json: string;
begin
  Writeln('-- collections --');
  B := TBag.Create;
  try
    A := TAddress.Create; A.City := 'one'; B.Items.Add(A);
    A := TAddress.Create; A.City := 'two'; B.Items.Add(A);
    B.Tags.Add('red');
    B.Tags.Add('blue');
    Json := TJsonSerializer.Serialize(B);
  finally
    B.Free;
  end;
  Note(Json);

  Back := TJsonSerializer.Deserialize<TBag>(Json);
  try
    Check(Back.Items.Count = 2, 'JSON_OBJECT_LIST');
    Check((Back.Tags.Count = 2) and (Back.Tags[0] = 'red'), 'JSON_SCALAR_LIST');
    Check(Back.Items[1].City = 'two', 'JSON_LIST_ELEMENT_VALUES');
  finally
    Back.Free;
  end;
end;

{ --------------------------------------------------------- enum mapping --- }

procedure TestEnumMapping;
var
  C: TCustomer;
  Json: string;
  Back: TCustomer;
begin
  Writeln('-- enum mapping --');
  C := TCustomer.Create;
  try
    C.Status := TStatus.Closed;
    Json := TJsonSerializer.Serialize(C);
  finally
    C.Free;
  end;
  Note(Json);
  Check(Json.Contains('"status":"closed"'), 'JSON_ENUM_MAPPING_WRITE');

  Back := TJsonSerializer.Deserialize<TCustomer>(Json);
  try
    Check(Back.Status = TStatus.Closed, 'JSON_ENUM_MAPPING_READ');
  finally
    Back.Free;
  end;
end;

{ ---------------------------------------------------- custom serializers --- }

type
  { A serializer for a plain Delphi type. No untyped plumbing. }
  TTrimmedSerializer = class(TCustomJsonValueSerializer<string>)
  public
    function SerializeValue(const AValue: string): TJSONValue; override;
    function DeserializeValue(const AJson: TJSONValue): string; override;
  end;

  TNote = class
  public
    Subject: string;
    Body: string;
    Footer: string;
  end;

function TTrimmedSerializer.SerializeValue(const AValue: string): TJSONValue;
begin
  Result := TJSONString.Create(AValue.Trim);
end;

function TTrimmedSerializer.DeserializeValue(const AJson: TJSONValue): string;
begin
  Result := AJson.Value.Trim;
end;

procedure TestCustomSerializers;
var
  N, Back: TNote;
  Json: string;
begin
  Writeln('-- custom serializers --');

  { The overrides are registered in Configure: configuration is closed
    once the first document has been written. }
  N := TNote.Create;
  try
    N.Subject := '  hello  ';
    N.Body := 'world';
    N.Footer := 'end';
    Json := TJsonSerializer.Serialize(N);
  finally
    N.Free;
  end;
  Note(Json);

  Check(Json.Contains('"subject":"hello"'), 'JSON_TYPED_SERIALIZER');
  Check(Json.Contains('"body":"[world]"'), 'JSON_DELEGATE_SERIALIZER');
  Check(Json.Contains('"footer":"--end"'), 'JSON_ONE_SIDED_WRITE');

  Back := TJsonSerializer.Deserialize<TNote>(Json);
  try
    Check(Back.Body = 'world', 'JSON_DELEGATE_ROUNDTRIP');
    { No read delegate was registered, so the built-in reader ran and the
      marker the writer added is simply part of the string. }
    Check(Back.Footer = '--end', 'JSON_ONE_SIDED_DEFAULT_READ');
  finally
    Back.Free;
  end;
end;

{ --------------------------------------------------------------- errors --- }

procedure TestTryDeserialize;
var
  C: TCustomer;
  Ok: Boolean;
  Err: string;
begin
  Writeln('-- untrusted input --');
  Ok := TJsonSerializer.TryDeserialize<TCustomer>('{not json', C, Err,
    [TJsonDeserializationError.InvalidJson]);
  Check((not Ok) and (C = nil), 'JSON_TRY_DESERIALIZE_INVALID');
  if Err <> '' then Note(Err);

  Ok := TJsonSerializer.TryDeserialize<TCustomer>('{"id":3}', C, Err, []);
  try
    Check(Ok and (C <> nil) and (C.Id = 3), 'JSON_TRY_DESERIALIZE_VALID');
  finally
    C.Free;
  end;
end;

procedure TestFreeze;
var
  Refused: Boolean;
begin
  Writeln('-- configuration freeze --');
  { Nothing has called FreezeConfiguration yet: the first document froze it. }
  Check(TJsonSerializer.IsFrozen, 'JSON_FROZEN_BY_FIRST_USE');
  TJsonSerializer.FreezeConfiguration;
  Check(TJsonSerializer.IsFrozen, 'JSON_FREEZE_REPORTED');
  Refused := False;
  try
    TJsonSerializer.RegisterEnumMapping<TStatus>(['x', 'y', 'z']);
  except
    on E: Exception do Refused := True;
  end;
  Check(Refused, 'JSON_FREEZE_REFUSES_REGISTRATION');
end;

{ --------------------------------------- release review regressions --- }

type
  { Counts its live instances: a failed read that orphans what it built
    shows as a delta, where FastMM would only say so at exit. }
  TTracked = class
  public
    class var Live: Integer;
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;
  end;

  { Refused when the plan is built: a pointer and a stream mean nothing in
    a document. }
  TBad = class
  public
    P: Pointer;
  end;

  TInMap = class
  public
    Items: TDictionary<string, TBad>;
  end;

  TStreamField = class
  public
    A: Integer;
    S: TStream;
  end;

  TNode = class
  public
    Id: Integer;
    Child: TNode;
    destructor Destroy; override;
  end;

  TListNode = class
  public
    Id: Integer;
    Kids: TObjectList<TListNode>;
    constructor Create;
    destructor Destroy; override;
  end;

  TSelfRef = class
  public
    Next: TSelfRef;
  end;

  { Nests with no object in it at all. }
  TRecNode = record
    Tag: Integer;
    Kids: array of TRecNode;
  end;

  TRecHolder = class
  public
    R: TRecNode;
  end;

  TCDst = class(TTracked)
  public
    X: Integer;
    Y: Integer;
  end;

  TItem = class(TTracked)
  public
    X: Integer;
    S: string;
  end;

  { Named: an inline array[0..2] of TCDst has no RTTI. }
  TCDst3 = array[0..2] of TCDst;

  TA1Dst = class
  public
    A: TArray<TCDst>;
    destructor Destroy; override;
  end;

  TA3Dst = class
  public
    S: TCDst3;
    destructor Destroy; override;
  end;

  TL2Dst = class
  public
    L: TList<TCDst>;
    destructor Destroy; override;
  end;

  TL3Dst = class
  private
    FL: TList<TCDst>;
  public
    property L: TList<TCDst> read FL write FL;
    destructor Destroy; override;
  end;

  TD2Dst = class
  public
    D: TDictionary<string, TCDst>;
    destructor Destroy; override;
  end;

  TRootObjDictCtor = class
  public
    D: TObjectDictionary<string, TItem>;
    constructor Create;
    destructor Destroy; override;
  end;

  TRootDict = class
  public
    D: TDictionary<string, TItem>;
    destructor Destroy; override;
  end;

  TRecDst = record
    O: TCDst;
    N: Integer;
  end;

  TRP = class
  private
    FR: TRecDst;
  public
    property R: TRecDst read FR write FR;
    destructor Destroy; override;
  end;

  TRA = class
  public
    A: TArray<TRecDst>;
    destructor Destroy; override;
  end;

  TRecPair = record
    A: TItem;
    B: TItem;
  end;

  TRootRecList = class
  public
    L: TList<TRecPair>;
    destructor Destroy; override;
  end;

  TStringsHolder = class
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  TDblProbe = class
  public
    D: Double;
  end;

  TDateOnly = class
  public
    D: TDate;
  end;

  { Each given its date policy in Configure. }
  TDateMs = class
  public
    D: TDateTime;
  end;

  TDateSec = class
  public
    D: TDateTime;
  end;

  TDateCustom = class
  public
    D: TDateTime;
  end;

procedure TTracked.AfterConstruction;
begin
  inherited;
  AtomicIncrement(Live);
end;

procedure TTracked.BeforeDestruction;
begin
  AtomicDecrement(Live);
  inherited;
end;

destructor TNode.Destroy;
begin
  Child.Free;
  inherited;
end;

constructor TListNode.Create;
begin
  inherited Create;
  Kids := TObjectList<TListNode>.Create(True);
end;

destructor TListNode.Destroy;
begin
  Kids.Free;
  inherited;
end;

destructor TA1Dst.Destroy;
var
  C: TCDst;
begin
  for C in A do C.Free;
  inherited;
end;

destructor TA3Dst.Destroy;
var
  I: Integer;
begin
  for I := 0 to 2 do S[I].Free;
  inherited;
end;

destructor TL2Dst.Destroy;
var
  C: TCDst;
begin
  if L <> nil then
    for C in L do C.Free;
  L.Free;
  inherited;
end;

destructor TL3Dst.Destroy;
var
  C: TCDst;
begin
  if FL <> nil then
    for C in FL do C.Free;
  FL.Free;
  inherited;
end;

destructor TD2Dst.Destroy;
var
  C: TCDst;
begin
  if D <> nil then
    for C in D.Values do C.Free;
  D.Free;
  inherited;
end;

constructor TRootObjDictCtor.Create;
begin
  inherited Create;
  D := TObjectDictionary<string, TItem>.Create([doOwnsValues]);
end;

destructor TRootObjDictCtor.Destroy;
begin
  D.Free;
  inherited;
end;

destructor TRootDict.Destroy;
var
  I: TItem;
begin
  if D <> nil then
    for I in D.Values do I.Free;
  D.Free;
  inherited;
end;

destructor TRP.Destroy;
begin
  FR.O.Free;
  inherited;
end;

destructor TRA.Destroy;
var
  R: TRecDst;
begin
  for R in A do R.O.Free;
  inherited;
end;

destructor TRootRecList.Destroy;
var
  P: TRecPair;
begin
  if L <> nil then
    for P in L do
    begin
      P.A.Free;
      P.B.Free;
    end;
  L.Free;
  inherited;
end;

constructor TStringsHolder.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
  Lines.Sorted := True;
  Lines.Duplicates := dupError;
end;

destructor TStringsHolder.Destroy;
begin
  Lines.Free;
  inherited;
end;

{ Runs AProc, which is expected to raise, and reports what it raised and how
  many TTracked instances it left alive. }
procedure RunRefused(const AProc: TProc; out AClass: TClass;
  out AMessage: string; out ALiveDelta: Integer);
var
  Before: Integer;
begin
  AClass := nil;
  AMessage := 'not refused';
  Before := TTracked.Live;
  try
    AProc();
  except
    on E: Exception do
    begin
      AClass := E.ClassType;
      AMessage := E.ClassName + ': ' + E.Message;
    end;
  end;
  ALiveDelta := TTracked.Live - Before;
  { A leak is reported once, by the check that caused it. }
  TTracked.Live := Before;
end;

function Raises(const AProc: TProc; AExpected: ExceptClass): Boolean;
var
  Cls: TClass;
  Msg: string;
  Delta: Integer;
begin
  RunRefused(AProc, Cls, Msg, Delta);
  Result := (Cls <> nil) and Cls.InheritsFrom(AExpected);
  if not Result then Note(Msg);
end;

{ A document error, reported as one, with nothing this read built left
  alive. }
function CleanInputRefusal(const AProc: TProc;
  const AMustSay: string = ''): Boolean;
var
  Cls: TClass;
  Msg: string;
  Delta: Integer;
begin
  RunRefused(AProc, Cls, Msg, Delta);
  Result := (Cls <> nil) and Cls.InheritsFrom(EJsonInputError) and
    (Delta = 0) and ((AMustSay = '') or Msg.Contains(AMustSay));
  if not Result then Note(Format('live delta %d, %s', [Delta, Msg]));
end;

{ GetMemoryManagerState is marked platform-specific; this test runs on
  Windows only, where it is the one way to count live heap blocks. }
{$WARN SYMBOL_PLATFORM OFF}
function MemInUse: Int64;
var
  S: TMemoryManagerState;
  I: Integer;
begin
  GetMemoryManagerState(S);
  Result := Int64(S.TotalAllocatedMediumBlockSize) +
    Int64(S.TotalAllocatedLargeBlockSize);
  for I := Low(S.SmallBlockTypeStates) to High(S.SmallBlockTypeStates) do
    Inc(Result, Int64(S.SmallBlockTypeStates[I].AllocatedBlockCount) *
      S.SmallBlockTypeStates[I].UseableBlockSize);
end;
{$WARN SYMBOL_PLATFORM ON}

{ Memory still in use after 500 refused writes. The refused type is
  un-cached, so every attempt rebuilds its plan: a plan build that leaks
  leaks every time (about 400 bytes each on Win32). }
function RefusalGrowth(const AProc: TProc): Int64;
var
  I: Integer;
  Before: Int64;
begin
  for I := 1 to 3 do
    try AProc(); except on EJsonError do ; end;
  Before := MemInUse;
  for I := 1 to 500 do
    try AProc(); except on EJsonError do ; end;
  Result := MemInUse - Before;
end;

procedure TestRefusedPlanBuilds;
var
  B: TBad;
  M: TInMap;
  SF: TStreamField;
  Growth: Int64;
begin
  Writeln('-- a refused plan build leaves nothing behind --');
  B := TBad.Create;
  M := TInMap.Create;
  SF := TStreamField.Create;
  try
    Check(Raises(procedure begin TJsonSerializer.Serialize<TBad>(B); end,
      EJsonError), 'JSON_POINTER_MEMBER_REFUSED');
    Growth := RefusalGrowth(procedure begin TJsonSerializer.Serialize<TBad>(B); end);
    Note(Format('Pointer field: %d bytes after 500 refusals', [Growth]));
    Check(Growth < 16384, 'JSON_REFUSED_FIELD_PLAN_NOT_LEAKED');
    Growth := RefusalGrowth(procedure begin TJsonSerializer.Serialize<TInMap>(M); end);
    Note(Format('dictionary of it: %d bytes after 500 refusals', [Growth]));
    Check(Growth < 16384, 'JSON_REFUSED_NESTED_PLAN_NOT_LEAKED');
    Growth := RefusalGrowth(procedure begin TJsonSerializer.Serialize<TStreamField>(SF); end);
    Note(Format('TStream field: %d bytes after 500 refusals', [Growth]));
    Check(Growth < 16384, 'JSON_REFUSED_STREAM_PLAN_NOT_LEAKED');
  finally
    SF.Free;
    M.Free;
    B.Free;
  end;
end;

function NodeChain(N: Integer): TNode;
var
  Cur: TNode;
  I: Integer;
begin
  Result := TNode.Create;
  Cur := Result;
  for I := 2 to N do
  begin
    Cur.Child := TNode.Create;
    Cur := Cur.Child;
  end;
end;

function NodeCount(ANode: TNode): Integer;
begin
  Result := 0;
  while ANode <> nil do
  begin
    Inc(Result);
    ANode := ANode.Child;
  end;
end;

function ListChain(N: Integer): TListNode;
var
  Cur, Nxt: TListNode;
  I: Integer;
begin
  Result := TListNode.Create;
  Cur := Result;
  for I := 2 to N do
  begin
    Nxt := TListNode.Create;
    Nxt.Id := I;
    Cur.Kids.Add(Nxt);
    Cur := Nxt;
  end;
end;

function RecChain(ADepth: Integer): TRecNode;
begin
  Result.Tag := ADepth;
  Result.Kids := nil;
  if ADepth > 1 then
  begin
    SetLength(Result.Kids, 1);
    Result.Kids[0] := RecChain(ADepth - 1);
  end;
end;

function RecDepth(const ARec: TRecNode): Integer;
begin
  Result := 1;
  if Length(ARec.Kids) > 0 then Inc(Result, RecDepth(ARec.Kids[0]));
end;

{ Every composite the writer descends into is one of the 64 levels every
  format shares: an object, a list, a record, an array. }
procedure TestLevels;
var
  Root, Back: TNode;
  LRoot, LBack: TListNode;
  H, HBack: TRecHolder;
  A, B: TSelfRef;
  Json: string;
begin
  Writeln('-- nesting levels --');
  Root := NodeChain(60);
  try
    Back := TJsonSerializer.Deserialize<TNode>(TJsonSerializer.Serialize<TNode>(Root));
    try
      Check(NodeCount(Back) = 60, 'JSON_LEVELS_60_OBJECTS_CARRIED');
    finally
      Back.Free;
    end;
  finally
    Root.Free;
  end;
  Root := NodeChain(64);
  try
    Back := TJsonSerializer.Deserialize<TNode>(TJsonSerializer.Serialize<TNode>(Root));
    try
      Check(NodeCount(Back) = 64, 'JSON_LEVELS_64_OBJECTS_CARRIED');
    finally
      Back.Free;
    end;
  finally
    Root.Free;
  end;
  Root := NodeChain(65);
  try
    Check(Raises(procedure begin TJsonSerializer.Serialize<TNode>(Root); end,
      ESerializationLimitExceeded), 'JSON_LEVELS_65_OBJECTS_REFUSED');
  finally
    Root.Free;
  end;

  { A node and its TObjectList are two levels, in every format. }
  LRoot := ListChain(32);
  try
    LBack := TJsonSerializer.Deserialize<TListNode>(
      TJsonSerializer.Serialize<TListNode>(LRoot));
    try
      Check((LBack.Kids.Count = 1) and (LBack.Kids[0].Id = 2),
        'JSON_LEVELS_LIST_TREE_32_CARRIED');
    finally
      LBack.Free;
    end;
  finally
    LRoot.Free;
  end;
  LRoot := ListChain(33);
  try
    Check(Raises(procedure begin TJsonSerializer.Serialize<TListNode>(LRoot); end,
      ESerializationLimitExceeded), 'JSON_LEVELS_LIST_TREE_33_REFUSED');
  finally
    LRoot.Free;
  end;

  { Records through dynamic arrays count too: 300 was written, and then
    refused by the reader; 3000 overflowed the stack. }
  H := TRecHolder.Create;
  try
    H.R := RecChain(31);
    Json := TJsonSerializer.Serialize<TRecHolder>(H);
    HBack := TJsonSerializer.Deserialize<TRecHolder>(Json);
    try
      Check(RecDepth(HBack.R) = 31, 'JSON_LEVELS_RECORD_CHAIN_31_CARRIED');
    finally
      HBack.Free;
    end;
    H.R := RecChain(300);
    Check(Raises(procedure begin TJsonSerializer.Serialize<TRecHolder>(H); end,
      ESerializationLimitExceeded), 'JSON_LEVELS_RECORD_CHAIN_300_REFUSED');
    H.R := RecChain(3000);
    Check(Raises(procedure begin TJsonSerializer.Serialize<TRecHolder>(H); end,
      ESerializationLimitExceeded), 'JSON_LEVELS_RECORD_CHAIN_3000_REFUSED');
  finally
    H.Free;
  end;
  Check(TSerializationGraphGuard.Level = 0, 'JSON_LEVELS_RESTORED_AFTER_REFUSAL');

  A := TSelfRef.Create;
  B := TSelfRef.Create;
  try
    A.Next := B;
    B.Next := A;
    Check(Raises(procedure begin TJsonSerializer.Serialize<TSelfRef>(A); end,
      EJsonError), 'JSON_LEVELS_CYCLE_STILL_REFUSED');
  finally
    B.Free;
    A.Free;
  end;
  Check(TSerializationGraphGuard.Level = 0, 'JSON_LEVELS_RESTORED_AFTER_CYCLE');
end;

const
  BAD_LIST = '[{"x":1,"y":1},{"x":2,"y":2},{"x":3,"y":5000000000}]';

{ The document fails part way, after this read built objects: every one of
  them is freed, and the error is the document's. }
procedure TestFailedReadsFreeWhatTheyBuilt;
begin
  Writeln('-- a failed read frees what it built --');
  Check(CleanInputRefusal(procedure
    begin TJsonSerializer.Deserialize<TA1Dst>('{"a":' + BAD_LIST + '}').Free; end),
    'JSON_FAILED_DYNAMIC_ARRAY_FIELD_FREED');
  Check(CleanInputRefusal(procedure
    begin TJsonSerializer.Deserialize<TA3Dst>('{"s":' + BAD_LIST + '}').Free; end),
    'JSON_FAILED_STATIC_ARRAY_FIELD_FREED');
  Check(CleanInputRefusal(procedure
    var A: TArray<TCDst>; C: TCDst;
    begin
      A := TJsonSerializer.Deserialize<TArray<TCDst>>(BAD_LIST);
      for C in A do C.Free;
    end), 'JSON_FAILED_DYNAMIC_ARRAY_ROOT_FREED');
  Check(CleanInputRefusal(procedure
    var A: TCDst3; I: Integer;
    begin
      A := TJsonSerializer.Deserialize<TCDst3>(BAD_LIST);
      for I := 0 to 2 do A[I].Free;
    end), 'JSON_FAILED_STATIC_ARRAY_ROOT_FREED');

  { A TList<T> or TDictionary<K,V> owns nothing: freeing it alone orphaned
    every element the read had added. }
  Check(CleanInputRefusal(procedure
    begin TJsonSerializer.Deserialize<TL2Dst>('{"l":' + BAD_LIST + '}').Free; end),
    'JSON_FAILED_LIST_FIELD_ELEMENTS_FREED');
  Check(CleanInputRefusal(procedure
    begin TJsonSerializer.Deserialize<TL3Dst>('{"l":' + BAD_LIST + '}').Free; end),
    'JSON_FAILED_LIST_PROPERTY_ELEMENTS_FREED');
  Check(CleanInputRefusal(procedure
    begin TJsonSerializer.Deserialize<TList<TCDst>>(BAD_LIST).Free; end),
    'JSON_FAILED_LIST_ROOT_ELEMENTS_FREED');
  Check(CleanInputRefusal(procedure
    begin TJsonSerializer.Deserialize<TD2Dst>('{"d":{"a":{"x":1},"b":{"x":2},' +
      '"c":{"x":3},"d":{"y":5000000000},"e":{"x":5}}}').Free; end),
    'JSON_FAILED_DICTIONARY_FIELD_VALUES_FREED');
  Check(CleanInputRefusal(procedure
    begin TJsonSerializer.Deserialize<TDictionary<string, TCDst>>(
      '{"a":{"x":1},"b":{"x":2},"c":{"y":5000000000}}').Free; end),
    'JSON_FAILED_DICTIONARY_ROOT_VALUES_FREED');

  { A record is read into a temporary: the objects built into it go with
    it. }
  Check(CleanInputRefusal(procedure
    begin TJsonSerializer.Deserialize<TRP>(
      '{"r":{"o":{"x":1,"y":1},"n":5000000000}}').Free; end),
    'JSON_FAILED_RECORD_PROPERTY_FREED');
  Check(CleanInputRefusal(procedure
    var R: TRecDst;
    begin
      R := TJsonSerializer.Deserialize<TRecDst>('{"o":{"x":1,"y":1},"n":5000000000}');
      R.O.Free;
    end), 'JSON_FAILED_RECORD_ROOT_FREED');
  Check(CleanInputRefusal(procedure
    begin TJsonSerializer.Deserialize<TRA>(
      '{"a":[{"o":{"x":1},"n":1},{"o":{"x":2},"n":5000000000}]}').Free; end),
    'JSON_FAILED_RECORD_ARRAY_FREED');
  Check(CleanInputRefusal(procedure
    begin TJsonSerializer.Deserialize<TRootRecList>(
      '{"l":[{"a":{"x":1},"b":{"x":2}},{"a":{"x":3},"b":{"x":"bad"}}]}').Free; end),
    'JSON_FAILED_RECORD_LIST_FREED');
end;

procedure TestDuplicateKeys;
var
  D: TRootDict;
  Before: Integer;
begin
  Writeln('-- a key the document repeats --');
  { JSON reads a dictionary with Add, so the repeat is refused - as the
    document's error, with the value built for it freed. It was an
    EJsonInternalError wrapping EListError, or a bare EListError at the
    root, and the value leaked even into an owning dictionary. }
  Check(CleanInputRefusal(procedure
    begin TJsonSerializer.Deserialize<TRootObjDictCtor>(
      '{"d":{"qa":{"x":1,"s":"item1"},"qa":{"x":2,"s":"item2"}}}').Free; end,
    'more than once'), 'JSON_DUPLICATE_KEY_OWNING_DICTIONARY');
  Check(CleanInputRefusal(procedure
    begin TJsonSerializer.Deserialize<TRootDict>(
      '{"d":{"qa":{"x":1,"s":"item1"},"qa":{"x":2,"s":"item2"}}}').Free; end,
    'more than once'), 'JSON_DUPLICATE_KEY_READER_BUILT_DICTIONARY');
  Check(CleanInputRefusal(procedure
    begin TJsonSerializer.Deserialize<TDictionary<string, TItem>>(
      '{"qa":{"x":1,"s":"item1"},"qa":{"x":2,"s":"item2"}}').Free; end,
    'more than once'), 'JSON_DUPLICATE_KEY_ROOT_DICTIONARY');

  Before := TTracked.Live;
  D := TJsonSerializer.Deserialize<TRootDict>('{"d":{"qa":{"x":1},"qb":{"x":2}}}');
  try
    Check((D.D.Count = 2) and (D.D['qb'].X = 2), 'JSON_DISTINCT_KEYS_STILL_READ');
  finally
    D.Free;
  end;
  Check(TTracked.Live = Before, 'JSON_DISTINCT_KEYS_NOTHING_LEFT');
end;

procedure TestContainerRefusal;
var
  H: TStringsHolder;
begin
  Writeln('-- a container that refuses an element --');
  { A sorted dupError TStringList raised EStringListError, which reached the
    caller wrapped as an internal error. }
  Check(CleanInputRefusal(procedure
    begin TJsonSerializer.Deserialize<TStringsHolder>(
      '{"lines":["b","a","b"]}').Free; end,
    'TStringList refused an element'), 'JSON_CONTAINER_REFUSAL_IS_INPUT_ERROR');
  H := TStringsHolder.Create;
  try
    Check(CleanInputRefusal(procedure
      begin TJsonSerializer.Populate(H, '{"lines":["b","a","b"]}'); end,
      'TStringList refused an element'), 'JSON_CONTAINER_REFUSAL_POPULATE');
  finally
    H.Free;
  end;
end;

function ExtendedJsonRoundTrip(const AText: string): string;
var
  Options: TStructuralConversionOptions;
  Parsed, Back: TJSONValue;
  N: TDynamicValue;
begin
  Options := TStructuralConversionOptions.FromProfile(
    TStructuralConversionProfile.Lossless).WithSource(TSerializationFormat.Json)
    .WithDestination(TSerializationFormat.Bson);
  Parsed := TJSONObject.ParseJSONValue(AText);
  try
    N := TJsonEngine.JsonToDynamic(Parsed, Options);
    try
      Back := TJsonEngine.DynamicToJson(N, Options, '$');
      try
        Result := RenderJson(Back, TJsonUnicodeEscapePolicy.PreserveUnicode);
      finally
        Back.Free;
      end;
    finally
      N.Free;
    end;
  finally
    Parsed.Free;
  end;
end;

procedure TestExtendedJsonUuid;
var
  Back: string;
begin
  Writeln('-- Extended JSON $uuid --');
  { Binary subtype 4, in RFC 4122 byte order: 73 FF D2 64 44 B3 ... It was
    an ordinary sub-document holding a string. }
  Back := ExtendedJsonRoundTrip(
    '{"x" : { "$uuid" : "73ffd264-44b3-4c69-90e8-e7d1dfc035d4"}}');
  Note(Back);
  Check(Back = '{"x":{"$binary":{"base64":"c//SZESzTGmQ6OfR38A11A==","subType":"04"}}}',
    'JSON_EXTJSON_UUID_IS_BINARY_SUBTYPE_4');
  Check(Raises(procedure begin ExtendedJsonRoundTrip(
    '{"x" : { "$uuid" : "73ffd264-44b3-90e8-e7d1dfc035d4"}}'); end,
    EJsonInputError) and
    Raises(procedure begin ExtendedJsonRoundTrip(
    '{"x" : { "$uuid" : "73ff-d26444b-34c6-990e8e-7d1dfc035d4"}}'); end,
    EJsonInputError) and
    Raises(procedure begin ExtendedJsonRoundTrip(
    '{"x" : { "$uuid" : { "data" : "73ffd264-44b3-4c69-90e8-e7d1dfc035d4"}}}'); end,
    EJsonInputError), 'JSON_EXTJSON_UUID_MALFORMED_REFUSED');
end;

function DoubleBits(const AValue: Double): UInt64;
begin
  Result := PUInt64(@AValue)^;
end;

procedure TestFloatText;
var
  P, Back: TDblProbe;
  Bits: UInt64;
  I, Differ: Integer;
  Parsed: TJSONValue;
  N: TDynamicValue;
begin
  Writeln('-- text to Double, correctly rounded on both platforms --');
  { Win64's TryStrToFloat read these one unit in the last place off, and
    refused the largest Double on Win32. }
  Back := TJsonSerializer.Deserialize<TDblProbe>('{"d":123456789.12345679}');
  try
    Check(DoubleBits(Back.D) = $419D6F34547E6B75, 'JSON_FLOAT_READ_CORRECTLY_ROUNDED');
  finally
    Back.Free;
  end;
  Back := TJsonSerializer.Deserialize<TDblProbe>('{"d":1.7976931348623158E308}');
  try
    Check(DoubleBits(Back.D) = $7FEFFFFFFFFFFFFF, 'JSON_FLOAT_READ_MAX_DOUBLE');
  finally
    Back.Free;
  end;
  Parsed := TJSONObject.ParseJSONValue('123456789.12345679');
  try
    N := TJsonEngine.JsonToDynamic(Parsed);
    try
      Check(DoubleBits(N.AsFloat) = $419D6F34547E6B75, 'JSON_FLOAT_STRUCTURAL_CORRECTLY_ROUNDED');
    finally
      N.Free;
    end;
  finally
    Parsed.Free;
  end;

  RandSeed := 20260929;
  Differ := 0;
  P := TDblProbe.Create;
  try
    for I := 1 to 2000 do
    begin
      repeat
        Bits := (UInt64(Cardinal(Random($7FFFFFFF))) shl 33) xor
          (UInt64(Cardinal(Random($7FFFFFFF))) shl 2) xor UInt64(Random(4));
        P.D := PDouble(@Bits)^;
      until not (P.D.IsNan or P.D.IsInfinity);
      Back := TJsonSerializer.Deserialize<TDblProbe>(TJsonSerializer.Serialize<TDblProbe>(P));
      try
        if DoubleBits(Back.D) <> Bits then Inc(Differ);
      finally
        Back.Free;
      end;
    end;
  finally
    P.Free;
  end;
  Note(Format('%d of 2000 random doubles differ after a round trip', [Differ]));
  Check(Differ = 0, 'JSON_FLOAT_ROUND_TRIP_EXACT');
end;

function DateText(const AValue: TDateTime): string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', AValue,
    TFormatSettings.Invariant);
end;

function LosslessDate(const AValue: TDateTime): string;
var
  Options: TStructuralConversionOptions;
  N: TDynamicValue;
  J: TJSONValue;
begin
  Options := TStructuralConversionOptions.FromProfile(
    TStructuralConversionProfile.Lossless).WithSource(TSerializationFormat.Bson)
    .WithDestination(TSerializationFormat.Json);
  N := TDynamicValue.NewDateTime(AValue);
  try
    J := TJsonEngine.DynamicToJson(N, Options, '$');
    try
      Result := RenderJson(J, TJsonUnicodeEscapePolicy.PreserveUnicode);
    finally
      J.Free;
    end;
  finally
    N.Free;
  end;
end;

procedure TestEpochDates;
var
  Pre: TDateTime;
  M, MBack: TDateMs;
  S, SBack: TDateSec;
  Json: string;
begin
  Writeln('-- Unix epoch dates before 1899-12-30 --');
  { -1.25 is 29 Dec 1899 06:00: Delphi keeps the time of day positive before
    the epoch, and the linear formula wrote it a day early. }
  Pre := EncodeDateTime(1899, 12, 29, 6, 0, 0, 0);
  M := TDateMs.Create;
  try
    M.D := Pre;
    Json := TJsonSerializer.Serialize<TDateMs>(M);
    Note(Json);
    Check(Json = '{"d":-2209226400000}', 'JSON_UNIX_MS_BEFORE_1899_12_30');
    MBack := TJsonSerializer.Deserialize<TDateMs>(Json);
    try
      Check(DateText(MBack.D) = '1899-12-29T06:00:00.000', 'JSON_UNIX_MS_READ_BACK');
    finally
      MBack.Free;
    end;
  finally
    M.Free;
  end;
  S := TDateSec.Create;
  try
    S.D := Pre;
    Json := TJsonSerializer.Serialize<TDateSec>(S);
    Check(Json = '{"d":-2209226400}', 'JSON_UNIX_SECONDS_BEFORE_1899_12_30');
    SBack := TJsonSerializer.Deserialize<TDateSec>(Json);
    try
      Check(DateText(SBack.D) = '1899-12-29T06:00:00.000', 'JSON_UNIX_SECONDS_READ_BACK');
    finally
      SBack.Free;
    end;
    { The second the instant is in: half a second before the epoch is -1,
      where DateTimeToUnix truncated it to 0. }
    S.D := EncodeDateTime(1969, 12, 31, 23, 59, 59, 500);
    Json := TJsonSerializer.Serialize<TDateSec>(S);
    Check(Json = '{"d":-1}', 'JSON_UNIX_SECONDS_FLOOR');
  finally
    S.Free;
  end;
  Json := LosslessDate(Pre);
  Note(Json);
  Check(Json = '{"$date":{"$numberLong":"-2209226400000"}}',
    'JSON_EXTJSON_DATE_BEFORE_1899_12_30');
end;

procedure TestDateRange;
var
  Low_, High_: TDateTime;
  DO_: TDateOnly;
  M: TDateMs;
  S: TDateSec;
  C: TDateCustom;
begin
  Writeln('-- dates outside the years 1 to 9999 --');
  { Written as 0000-00-00 or 10000-01-01, or as epoch counts, which the
    reader then refused. }
  Low_ := EncodeDate(1, 1, 1) - 1;
  High_ := EncodeDate(9999, 12, 31) + 1;
  DO_ := TDateOnly.Create;
  M := TDateMs.Create;
  S := TDateSec.Create;
  C := TDateCustom.Create;
  try
    DO_.D := Low_;
    Check(Raises(procedure begin TJsonSerializer.Serialize<TDateOnly>(DO_); end,
      ESerializationUnsupported), 'JSON_TDATE_BEFORE_YEAR_1_REFUSED');
    DO_.D := High_;
    Check(Raises(procedure begin TJsonSerializer.Serialize<TDateOnly>(DO_); end,
      ESerializationUnsupported), 'JSON_TDATE_AFTER_9999_REFUSED');
    M.D := Low_;
    S.D := High_;
    Check(Raises(procedure begin TJsonSerializer.Serialize<TDateMs>(M); end,
      ESerializationUnsupported) and
      Raises(procedure begin TJsonSerializer.Serialize<TDateSec>(S); end,
      ESerializationUnsupported), 'JSON_UNIX_DATE_OUT_OF_RANGE_REFUSED');
    C.D := Low_;
    Check(Raises(procedure begin TJsonSerializer.Serialize<TDateCustom>(C); end,
      ESerializationUnsupported), 'JSON_CUSTOM_DATE_OUT_OF_RANGE_REFUSED');
    Check(Raises(procedure begin LosslessDate(High_); end,
      ESerializationUnsupported), 'JSON_EXTJSON_DATE_OUT_OF_RANGE_REFUSED');
  finally
    C.Free;
    S.Free;
    M.Free;
    DO_.Free;
  end;
end;

{ ----------------------------------------------------------- startup --- }

{ Everything is registered here, before anything is serialized.  That is not
  a stylistic choice: a type's execution plan is cached the first time it is
  used, and a registration made after that cannot reach it.  Applications are
  expected to configure at startup and then freeze. }
procedure Configure;
begin
  { Two inline functions, and one direction only - see TestCustomSerializers. }
  TJsonSerializer.RegisterFieldOverride<TNote>('Body',
    TJsonFieldOverride.SerializeWith<string>(
      function(const AValue: string): TJSONValue
      begin
        Result := TJSONString.Create('[' + AValue + ']');
      end,
      function(const AJson: TJSONValue): string
      begin
        Result := AJson.Value.Trim(['[', ']']);
      end));

  { One direction only: written with a marker, read the ordinary way. }
  TJsonSerializer.RegisterFieldOverride<TNote>('Footer',
    TJsonFieldOverride.SerializeWith<string>(
      function(const AValue: string): TJSONValue
      begin
        Result := TJSONString.Create('--' + AValue);
      end));

  TJsonSerializer.RegisterEnumMapping<TStatus>(['draft', 'active', 'closed']);

  { A serializer class, checked by the compiler. }
  TJsonSerializer.RegisterFieldOverride<TNote>('Subject',
    TJsonFieldOverride.SerializeWith<string, TTrimmedSerializer>);

  TJsonSerializer.RegisterFieldDateTimeFormat<TDateMs>('D',
    TJsonDateTimeFormat.UnixMilliseconds);
  TJsonSerializer.RegisterFieldDateTimeFormat<TDateSec>('D',
    TJsonDateTimeFormat.UnixSeconds);
  TJsonSerializer.RegisterFieldDateTimeFormat<TDateCustom>('D',
    'yyyy-mm-dd hh:nn:ss');
end;


begin
  try
    Configure;
    TestBasics;
    TestRecords;
    TestPopulate;
    TestCollections;
    TestEnumMapping;
    TestCustomSerializers;
    TestTryDeserialize;
    TestRefusedPlanBuilds;
    TestLevels;
    TestFailedReadsFreeWhatTheyBuilt;
    TestDuplicateKeys;
    TestContainerRefusal;
    TestExtendedJsonUuid;
    TestFloatText;
    TestEpochDates;
    TestDateRange;
    Check(TTracked.Live = 0, 'JSON_NOTHING_TRACKED_LEFT_ALIVE');
    { Freezing is last: nothing may register after it. }
    TestFreeze;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then
    Writeln('JSON_CORE: PASS')
  else
    Writeln('JSON_CORE: FAIL (', GFailures, ')');
  ExitCode := Ord(GFailures <> 0);
end.
