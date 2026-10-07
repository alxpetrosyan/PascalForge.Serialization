program Robustness;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ What every format does with input nobody controls, and with many threads.

  Four questions, each over every format that does contract work:

  SECURITY_LIMITS   A document built to exhaust something - nesting a
                    hundred thousand deep, a length field claiming four
                    gigabytes, an XML entity or a YAML alias that expands
                    exponentially - is refused by the library's own limit,
                    with the library's own exception. Never a stack
                    overflow, never an out-of-memory, never a hang.

  MALFORMED_INPUT   A valid document, damaged deterministically: cut short
                    at every length, and each byte (or character) replaced
                    by a handful of hostile values. Every damaged document
                    either reads or is refused with the library's own
                    exception; nothing raises an RTL exception, nothing
                    faults, and nothing built by a failed read is left
                    alive.

  THREADING         Many threads serializing and deserializing at once -
                    including the very first use of a type, when the plan
                    caches are being built - get exactly the answers one
                    thread gets.

  CACHE             Once a type has been used, using it again builds no new
                    plan: the warm path does not rebuild.

  The mutations are deterministic, so a failure names a format, a mutation
  and a position that reproduce it every time. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Math, System.StrUtils,
  System.SyncObjs, System.Diagnostics, System.Generics.Collections,
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Json in '..\..\src\PascalForge.Json.pas',
  PascalForge.Xml in '..\..\src\PascalForge.Xml.pas',
  PascalForge.Xml.Internal in '..\..\src\PascalForge.Xml.Internal.pas',
  PascalForge.Bson in '..\..\src\PascalForge.Bson.pas',
  PascalForge.Bson.Internal in '..\..\src\PascalForge.Bson.Internal.pas',
  PascalForge.Protobuf in '..\..\src\PascalForge.Protobuf.pas',
  PascalForge.Protobuf.Internal in '..\..\src\PascalForge.Protobuf.Internal.pas',
  PascalForge.MessagePack in '..\..\src\PascalForge.MessagePack.pas',
  PascalForge.MessagePack.Internal in '..\..\src\PascalForge.MessagePack.Internal.pas',
  PascalForge.Yaml in '..\..\src\PascalForge.Yaml.pas',
  AllFormatsRegistered in '..\Shared\AllFormatsRegistered.pas';

type
  TTracked = class
  public
    class var Live: Integer;
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;
  end;

  TFuzzColor = (fcRed, fcGreen, fcBlue);
  TFuzzColors = set of TFuzzColor;

  TFuzzChild = class(TTracked)
  public
    [ProtoField(1)] N: Integer;
    [ProtoField(2)] Label_: string;
  end;

  { Flat enough for CSV, and every scalar family a document damages
    differently: integers of three widths, text, a float, a boolean, an
    enumeration, a set, a GUID, a moment, money, and a nested object. }
  TFuzzFlat = class(TTracked)
  public
    [ProtoField(1)] Id: Int64;
    [ProtoField(2)] Small: Byte;
    [ProtoField(3)] Count: Integer;
    [ProtoField(4)] Name: string;
    [ProtoField(5)] Ratio: Double;
    [ProtoField(6)] Active: Boolean;
    [ProtoField(7)] Color: TFuzzColor;
    [ProtoField(8)] Colors: TFuzzColors;
    [ProtoField(9)] Key: TGUID;
    [ProtoField(10)] At: TDateTime;
    [ProtoField(11)] Amount: Currency;
    [ProtoField(12)] Child: TFuzzChild;
    constructor Create;
    destructor Destroy; override;
    procedure Fill;
  end;

  { The containers, for every format but CSV. }
  TFuzzRich = class(TTracked)
  public
    [ProtoField(1)] Numbers: TList<Integer>;
    [ProtoField(2)] Children: TObjectList<TFuzzChild>;
    [ProtoField(3)] Tags: TArray<string>;
    [ProtoField(4)] Scores: TDictionary<string, Integer>;
    [ProtoField(5)] Name: string;
    constructor Create;
    destructor Destroy; override;
    procedure Fill;
  end;

  { For the nesting bombs: a message that can hold itself. }
  TNode = class(TTracked)
  public
    [ProtoField(1)] Child: TNode;
    destructor Destroy; override;
  end;

  TOneString = class(TTracked)
  public
    [ProtoField(1)] S: string;
  end;

  TOneList = class(TTracked)
  public
    [ProtoField(1)] Items: TArray<Integer>;
  end;

  { For the depth levels: a tree through lists, a recursive record through
    an array, and containers that hold themselves. }
  TListNode = class(TTracked)
  public
    [ProtoField(1)] Id: Integer;
    [ProtoField(2)] Kids: TObjectList<TListNode>;
    destructor Destroy; override;
  end;

  TRecNode = record
    [ProtoField(1)] Tag: Integer;
    [ProtoField(2)] Kids: array of TRecNode;
  end;

  TRecHolder = class(TTracked)
  public
    [ProtoField(1)] Root: TRecNode;
  end;

  TSelfList = class(TTracked)
  public
    [ProtoField(1)] Items: TList<TObject>;
    constructor Create;
    destructor Destroy; override;
  end;

  TSelfMap = class(TTracked)
  public
    [ProtoField(1)] Map: TDictionary<string, TObject>;
    constructor Create;
    destructor Destroy; override;
  end;

var
  GFailures: Integer = 0;
  GChecks: Integer = 0;

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

constructor TFuzzFlat.Create;
begin
  inherited Create;
  Child := TFuzzChild.Create;
end;

destructor TFuzzFlat.Destroy;
begin
  Child.Free;
  inherited Destroy;
end;

procedure TFuzzFlat.Fill;
begin
  Id := 4611686018427387903;
  Small := 200;
  Count := -12345;
  Name := 'ab"<&>'#$00E9'z';
  Ratio := -1.25e-7;
  Active := True;
  Color := fcBlue;
  Colors := [fcRed, fcBlue];
  Key := StringToGUID('{0F8FAD5B-D9CB-469F-A165-70867728950E}');
  At := EncodeDate(2026, 3, 14) + EncodeTime(15, 9, 26, 535);
  Amount := 1234.5678;
  Child.N := 7;
  Child.Label_ := 'seven';
end;

constructor TFuzzRich.Create;
begin
  inherited Create;
  Numbers := TList<Integer>.Create;
  Children := TObjectList<TFuzzChild>.Create(True);
  Scores := TDictionary<string, Integer>.Create;
end;

destructor TFuzzRich.Destroy;
begin
  Scores.Free;
  Children.Free;
  Numbers.Free;
  inherited Destroy;
end;

procedure TFuzzRich.Fill;
var
  C: TFuzzChild;
  I: Integer;
begin
  Numbers.AddRange([0, 1, -1, 300, 70000, MaxInt]);
  for I := 1 to 3 do
  begin
    C := TFuzzChild.Create;
    C.N := I;
    C.Label_ := 'c' + IntToStr(I);
    Children.Add(C);
  end;
  Tags := ['x', '', 'long tag'];
  Scores.Add('a', 1);
  Scores.Add('b', -2);
  Name := 'rich';
end;

destructor TNode.Destroy;
begin
  Child.Free;
  inherited Destroy;
end;

destructor TListNode.Destroy;
begin
  Kids.Free;
  inherited Destroy;
end;

constructor TSelfList.Create;
begin
  inherited Create;
  Items := TList<TObject>.Create;
end;

destructor TSelfList.Destroy;
begin
  Items.Free;
  inherited Destroy;
end;

constructor TSelfMap.Create;
begin
  inherited Create;
  Map := TDictionary<string, TObject>.Create;
end;

destructor TSelfMap.Destroy;
begin
  Map.Free;
  inherited Destroy;
end;

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

function IsOwn(E: Exception): Boolean;
begin
  Result := string(E.UnitName).StartsWith('PascalForge.');
end;

function FmtName(AFormat: TSerializationFormat): string;
begin
  Result := TSerialization.FormatName(AFormat);
end;

function FmtKey(AFormat: TSerializationFormat): string;
begin
  Result := UpperCase(FmtName(AFormat));
end;

function IsTextFormat(AFormat: TSerializationFormat): Boolean;
begin
  Result := AFormat in [TSerializationFormat.Json, TSerializationFormat.Xml,
    TSerializationFormat.Yaml, TSerializationFormat.Csv];
end;

function Repeated(const AText: string; ACount: Integer): string;
var
  SB: TStringBuilder;
  I: Integer;
begin
  SB := TStringBuilder.Create(Length(AText) * ACount);
  try
    for I := 1 to ACount do SB.Append(AText);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function RepeatedBytes(const ABytes: array of Byte; ACount: Integer): TBytes;
var
  I, J: Integer;
begin
  SetLength(Result, Length(ABytes) * ACount);
  for I := 0 to ACount - 1 do
    for J := 0 to High(ABytes) do
      Result[I * Length(ABytes) + J] := ABytes[J];
end;

function Join(const A, B: TBytes): TBytes;
begin
  Result := Concat(A, B);
end;

{ ===========================================================================
  SECURITY_LIMITS
  =========================================================================== }

type
  TReadProc = reference to procedure;

{ The read must be refused, by the library, without leaving anything alive.
  Run on a thread with the DEFAULT stack, so a parser that recurses once per
  level is caught as the stack overflow it would be in an application. }
function RefusedSafely(const AName: string; ARead: TReadProc): Boolean;
var
  Worker: TThread;
  Outcome, Detail: string;
  Before: Integer;
begin
  Before := TTracked.Live;
  Outcome := 'no exception';
  Detail := '';
  Worker := TThread.CreateAnonymousThread(
    procedure
    begin
      try
        ARead();
        Outcome := 'accepted';
      except
        on E: Exception do
        begin
          if IsOwn(E) then Outcome := 'refused' else Outcome := 'RTL';
          Detail := E.ClassName + ': ' + Copy(E.Message, 1, 160);
        end;
      end;
    end);
  Worker.FreeOnTerminate := False;
  Worker.Start;
  Worker.WaitFor;
  Worker.Free;
  Result := Outcome = 'refused';
  if TTracked.Live <> Before then
  begin
    Result := False;
    Detail := Format('LEAKED %d; %s', [TTracked.Live - Before, Detail]);
    TTracked.Live := Before;
  end;
  Check(Result, AName);
  if not Result then Note(Outcome + ' - ' + Detail);
end;

type
  TRead = record
    class procedure As_<T: class>(AFormat: TSerializationFormat;
      const APayload: TSerializationPayload); static;
  end;

class procedure TRead.As_<T>(AFormat: TSerializationFormat;
  const APayload: TSerializationPayload);
begin
  TSerialization.Deserialize<T>(APayload, AFormat).Free;
end;

const
  BOMB_DEPTH = 100000;

function BsonNested(ADepth: Integer): TBytes;
var
  I, P, Len: Integer;
begin
  (* A document holding a document holding a document, built outside in:
     level i is 8 bytes of header and terminator around a document of
     5 + 8 * (depth - i - 1). *)
  SetLength(Result, 5 + 8 * ADepth);
  P := 0;
  for I := 0 to ADepth - 1 do
  begin
    Len := 5 + 8 * (ADepth - I);
    Move(Len, Result[P], 4);
    Inc(P, 4);
    Result[P] := $03; Result[P + 1] := Ord('a'); Result[P + 2] := 0;
    Inc(P, 3);
  end;
  Len := 5;
  Move(Len, Result[P], 4);
  Result[P + 4] := 0;
  Inc(P, 5);
  for I := 0 to ADepth - 1 do
  begin
    Result[P] := 0;
    Inc(P);
  end;
end;

function Varint(AValue: UInt64): TBytes;
begin
  Result := nil;
  repeat
    if AValue < $80 then
    begin
      Result := Result + [Byte(AValue)];
      Exit;
    end;
    Result := Result + [Byte(AValue and $7F) or $80];
    AValue := AValue shr 7;
  until False;
end;

function ProtoNested(ADepth: Integer): TBytes;
var
  I: Integer;
begin
  Result := nil;
  for I := 1 to ADepth do
    Result := Concat([Byte($0A)], Varint(Length(Result)), Result);
end;

{ A chain of Depth nodes, written and read back by the library, must either
  carry or be refused by the library - never overflow the stack. }
procedure SafeAtDepth(AFormat: TSerializationFormat; ADepth: Integer;
  AMustCarry: Boolean);
var
  Worker: TThread;
  Outcome, Detail: string;
  Before: Integer;
begin
  Before := TTracked.Live;
  Outcome := '';
  Detail := '';
  Worker := TThread.CreateAnonymousThread(
    procedure
    var
      Root, Node, Back: TNode;
      I: Integer;
      P: TSerializationPayload;
    begin
      Root := TNode.Create;
      try
        Node := Root;
        for I := 2 to ADepth do
        begin
          Node.Child := TNode.Create;
          Node := Node.Child;
        end;
        try
          P := TSerialization.Serialize<TNode>(Root, AFormat);
          Back := TSerialization.Deserialize<TNode>(P, AFormat);
          try
            I := 0;
            Node := Back;
            while Node <> nil do
            begin
              Inc(I);
              Node := Node.Child;
            end;
            if I = ADepth then Outcome := 'carried'
            else Outcome := Format('SHORT: %d of %d levels came back',
              [I, ADepth]);
          finally
            Back.Free;
          end;
        except
          on E: Exception do
          begin
            if IsOwn(E) then Outcome := 'refused' else Outcome := 'RTL';
            Detail := E.ClassName + ': ' + Copy(E.Message, 1, 120);
          end;
        end;
      finally
        Root.Free;
      end;
    end);
  Worker.FreeOnTerminate := False;
  Worker.Start;
  Worker.WaitFor;
  Worker.Free;
  if TTracked.Live <> Before then
  begin
    Detail := Format('LEAKED %d; %s', [TTracked.Live - Before, Detail]);
    Outcome := 'leaked';
    TTracked.Live := Before;
  end;
  Check((Outcome = 'carried') or ((Outcome = 'refused') and not AMustCarry),
    Format('DEPTH_%d_%s', [ADepth, FmtKey(AFormat)]));
  if Outcome <> 'carried' then Note(Outcome + ' - ' + Detail);
end;

{ ---------------------------------------------------------------------------
  Depth in LEVELS. Every writer counts one level for each object, record,
  array, list and dictionary, the root included, and refuses the 65th with
  ESerializationLimitExceeded - the same count in every format, whatever
  the composites are, so what one format writes another can read.
  --------------------------------------------------------------------------- }

type
  { Writes a value, reads it back, and says how many generations came back. }
  TDepthWork = reference to function(AFormat: TSerializationFormat): Integer;

function DepthOutcome(AFormat: TSerializationFormat; AWork: TDepthWork;
  AExpected: Integer; out ADetail: string): string;
var
  Worker: TThread;
  Outcome, Detail: string;
  Before: Integer;
begin
  Before := TTracked.Live;
  Outcome := '';
  Detail := '';
  Worker := TThread.CreateAnonymousThread(
    procedure
    var
      Got: Integer;
    begin
      try
        Got := AWork(AFormat);
        if Got = AExpected then Outcome := 'carried'
        else Outcome := Format('SHORT: %d of %d generations came back',
          [Got, AExpected]);
      except
        on E: ESerializationLimitExceeded do
        begin
          Outcome := 'limit';
          Detail := Copy(E.Message, 1, 80);
        end;
        on E: Exception do
        begin
          if IsOwn(E) then Outcome := 'refused' else Outcome := 'RTL';
          Detail := E.ClassName + ': ' + Copy(E.Message, 1, 120);
        end;
      end;
    end);
  Worker.FreeOnTerminate := False;
  Worker.Start;
  Worker.WaitFor;
  Worker.Free;
  if TTracked.Live <> Before then
  begin
    Detail := Format('LEAKED %d; %s', [TTracked.Live - Before, Detail]);
    Outcome := 'leaked';
    TTracked.Live := Before;
  end;
  ADetail := Detail;
  Result := Outcome;
end;

{ AWant is 'carried', 'limit', or 'safe' - carried or refused by the
  library, never a crash, an RTL exception or a leak. }
procedure ExpectDepth(const AName: string; AFormat: TSerializationFormat;
  AWork: TDepthWork; AExpected: Integer; const AWant: string);
var
  Outcome, Detail: string;
begin
  Outcome := DepthOutcome(AFormat, AWork, AExpected, Detail);
  if AWant = 'safe' then
    Check((Outcome = 'carried') or (Outcome = 'refused') or
      (Outcome = 'limit'), AName + '_' + FmtKey(AFormat))
  else
    Check(Outcome = AWant, AName + '_' + FmtKey(AFormat));
  if Outcome <> 'carried' then Note(Outcome + ' - ' + Detail);
end;

{ N objects, one inside the other: N levels. }
function NodeChain(N: Integer): TDepthWork;
begin
  Result :=
    function(AFormat: TSerializationFormat): Integer
    var
      Root, Node, Back: TNode;
      I: Integer;
    begin
      Root := TNode.Create;
      try
        Node := Root;
        for I := 2 to N do
        begin
          Node.Child := TNode.Create;
          Node := Node.Child;
        end;
        Back := TSerialization.Deserialize<TNode>(
          TSerialization.Serialize<TNode>(Root, AFormat), AFormat);
        try
          Result := 0;
          Node := Back;
          while Node <> nil do
          begin
            Inc(Result);
            Node := Node.Child;
          end;
        finally
          Back.Free;
        end;
      finally
        Root.Free;
      end;
    end;
end;

{ N generations of nodes holding their child in a list: 2N - 1 levels. }
function ListTree(N: Integer): TDepthWork;
begin
  Result :=
    function(AFormat: TSerializationFormat): Integer
    var
      Root, Node, Kid, Back: TListNode;
      I: Integer;
    begin
      Root := TListNode.Create;
      try
        Node := Root;
        for I := 2 to N do
        begin
          Node.Kids := TObjectList<TListNode>.Create;
          Kid := TListNode.Create;
          Kid.Id := I;
          Node.Kids.Add(Kid);
          Node := Kid;
        end;
        Back := TSerialization.Deserialize<TListNode>(
          TSerialization.Serialize<TListNode>(Root, AFormat), AFormat);
        try
          Result := 0;
          Node := Back;
          while Node <> nil do
          begin
            Inc(Result);
            if (Node.Kids <> nil) and (Node.Kids.Count > 0) then
              Node := Node.Kids[0]
            else
              Node := nil;
          end;
        finally
          Back.Free;
        end;
      finally
        Root.Free;
      end;
    end;
end;

{ A holder and N records, each in an array of its parent: 2N or 2N + 1
  levels, as a writer does or does not descend into the last, empty array. }
function RecordTree(N: Integer): TDepthWork;
begin
  Result :=
    function(AFormat: TSerializationFormat): Integer
    var
      Holder, Back: TRecHolder;
      Chain, Parent: TRecNode;
      I: Integer;
    begin
      Chain := Default(TRecNode);
      Chain.Tag := N;
      for I := N - 1 downto 1 do
      begin
        Parent := Default(TRecNode);
        Parent.Tag := I;
        SetLength(Parent.Kids, 1);
        Parent.Kids[0] := Chain;
        Chain := Parent;
      end;
      Holder := TRecHolder.Create;
      try
        Holder.Root := Chain;
        Back := TSerialization.Deserialize<TRecHolder>(
          TSerialization.Serialize<TRecHolder>(Holder, AFormat), AFormat);
        try
          Result := 1;
          Chain := Back.Root;
          while Length(Chain.Kids) > 0 do
          begin
            Inc(Result);
            Chain := Chain.Kids[0];
          end;
        finally
          Back.Free;
        end;
      finally
        Holder.Free;
      end;
    end;
end;

{ A list and a map that hold themselves: written by runtime class, a cycle;
  written as the declared TObject, one empty object. Never a stack overflow. }
function SelfList: TDepthWork;
begin
  Result :=
    function(AFormat: TSerializationFormat): Integer
    var
      L: TSelfList;
    begin
      L := TSelfList.Create;
      try
        L.Items.Add(L.Items);
        TSerialization.Serialize<TSelfList>(L, AFormat);
        Result := 1;
      finally
        L.Free;
      end;
    end;
end;

function SelfMap: TDepthWork;
begin
  Result :=
    function(AFormat: TSerializationFormat): Integer
    var
      M: TSelfMap;
    begin
      M := TSelfMap.Create;
      try
        M.Map.Add('self', M.Map);
        TSerialization.Serialize<TSelfMap>(M, AFormat);
        Result := 1;
      finally
        M.Free;
      end;
    end;
end;

procedure TestDepthLevels;
var
  F: TSerializationFormat;
begin
  Writeln;
  Writeln('-- SECURITY_LIMITS: ', SERIALIZATION_MAX_GRAPH_DEPTH,
    ' levels, counted alike by every writer --');
  for F in TSerialization.ContractFormats do
  begin
    if F = TSerializationFormat.Csv then Continue;   { a row has no depth }
    ExpectDepth('LEVELS_OBJECTS_64_CARRIED', F, NodeChain(64), 64, 'carried');
    ExpectDepth('LEVELS_OBJECTS_65_REFUSED', F, NodeChain(65), 65, 'limit');
    ExpectDepth('LEVELS_LIST_TREE_32_CARRIED', F, ListTree(32), 32, 'carried');
    ExpectDepth('LEVELS_LIST_TREE_33_REFUSED', F, ListTree(33), 33, 'limit');
    ExpectDepth('LEVELS_RECORD_TREE_31_CARRIED', F, RecordTree(31), 31,
      'carried');
    ExpectDepth('LEVELS_RECORD_TREE_33_REFUSED', F, RecordTree(33), 33,
      'limit');
    ExpectDepth('LEVELS_RECORD_TREE_1000_REFUSED', F, RecordTree(1000), 1000,
      'limit');
    ExpectDepth('LEVELS_LIST_HOLDING_ITSELF', F, SelfList(), 1, 'safe');
    ExpectDepth('LEVELS_MAP_HOLDING_ITSELF', F, SelfMap(), 1, 'safe');
  end;
end;

procedure TestSecurityLimits;
var
  F: TSerializationFormat;
  Payload: TSerializationPayload;
  Laughs, Aliases: string;
  I, Depth: Integer;
begin
  Writeln;
  Writeln('-- SECURITY_LIMITS: nesting ', BOMB_DEPTH, ' deep --');
  for F in TSerialization.ContractFormats do
  begin
    case F of
      TSerializationFormat.Json:
        Payload := TSerializationPayload.FromText(
          '{"Child":' + Repeated('{"Child":', BOMB_DEPTH) + 'null' +
          Repeated('}', BOMB_DEPTH + 1));
      TSerializationFormat.Xml:
        Payload := TSerializationPayload.FromText(
          '<TNode>' + Repeated('<Child>', BOMB_DEPTH) +
          Repeated('</Child>', BOMB_DEPTH) + '</TNode>');
      TSerializationFormat.Yaml:
        Payload := TSerializationPayload.FromText(
          'Child: ' + Repeated('{Child: ', BOMB_DEPTH) + 'null' +
          Repeated('}', BOMB_DEPTH));
      TSerializationFormat.Bson:
        Payload := TSerializationPayload.FromBytes(BsonNested(BOMB_DEPTH));
      TSerializationFormat.Protobuf:
        Payload := TSerializationPayload.FromBytes(ProtoNested(20000));
      TSerializationFormat.Cbor:
        { a map of one, "Child", holding the next }
        Payload := TSerializationPayload.FromBytes(Join(
          RepeatedBytes([$A1, $65, Ord('C'), Ord('h'), Ord('i'), Ord('l'),
            Ord('d')], BOMB_DEPTH), [$F6]));
      TSerializationFormat.MessagePack:
        Payload := TSerializationPayload.FromBytes(Join(
          RepeatedBytes([$81, $A5, Ord('C'), Ord('h'), Ord('i'), Ord('l'),
            Ord('d')], BOMB_DEPTH), [$C0]));
      TSerializationFormat.Avro:
        { the union's second branch - a TNode - over and over }
        Payload := TSerializationPayload.FromBytes(Join(
          RepeatedBytes([$02], BOMB_DEPTH), [$00]));
      TSerializationFormat.Asn1Ber, TSerializationFormat.Asn1Cer:
        Payload := TSerializationPayload.FromBytes(Join(
          RepeatedBytes([$30, $80], BOMB_DEPTH),
          RepeatedBytes([$00, $00], BOMB_DEPTH)));
      TSerializationFormat.Asn1Der:
        Payload := TSerializationPayload.FromBytes(
          RepeatedBytes([$30, $84, $7F, $FF, $FF, $FF], BOMB_DEPTH));
      TSerializationFormat.Csv:
        { A row is flat, but its header names the nesting - Child.Child.
          Child - and the reader follows it one prefix at a time. }
        Payload := TSerializationPayload.FromText(
          Repeated('Child.', BOMB_DEPTH) + 'Child'#13#10'x'#13#10);
    else
      Continue;
    end;
    RefusedSafely('DEPTH_BOMB_' + FmtKey(F),
      procedure
      begin
        TRead.As_<TNode>(F, Payload);
      end);
  end;

  { Below a parser's limit, a document is parsed - and then every layer
    above the parser walks it recursively too. So a depth the parser allows
    must not overflow the stack in the mapping, the dynamic tree or the
    writer either: each depth here is written by the library itself and
    must read back or be refused, on a thread with the default stack. }
  Writeln;
  Writeln('-- SECURITY_LIMITS: real documents nested up to a parser''s limit --');
  for F in TSerialization.ContractFormats do
  begin
    if F = TSerializationFormat.Csv then Continue;
    { Under the shared graph limit every format must carry the chain: its
      writer's document is one its own reader accepts. Past it, refused. }
    SafeAtDepth(F, SERIALIZATION_MAX_GRAPH_DEPTH - 4, True);
    for Depth in [100, 1000] do
      SafeAtDepth(F, Depth, False);
  end;

  TestDepthLevels;

  Writeln;
  Writeln('-- SECURITY_LIMITS: a length that claims more than there is --');
  RefusedSafely('HUGE_LENGTH_CBOR',
    procedure
    begin
      TRead.As_<TOneString>(TSerializationFormat.Cbor,
        TSerializationPayload.FromBytes([$A1, $61, Ord('S'),
          $7B, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $F0, Ord('x')]));
    end);
  RefusedSafely('HUGE_COUNT_CBOR',
    procedure
    begin
      TRead.As_<TOneList>(TSerializationFormat.Cbor,
        TSerializationPayload.FromBytes([$A1, $65, Ord('I'), Ord('t'),
          Ord('e'), Ord('m'), Ord('s'),
          $9B, $00, $00, $00, $FF, $FF, $FF, $FF, $FF, $01]));
    end);
  RefusedSafely('HUGE_LENGTH_MESSAGEPACK',
    procedure
    begin
      TRead.As_<TOneString>(TSerializationFormat.MessagePack,
        TSerializationPayload.FromBytes([$81, $A1, Ord('S'),
          $DB, $FF, $FF, $FF, $F0, Ord('x')]));
    end);
  RefusedSafely('HUGE_COUNT_MESSAGEPACK',
    procedure
    begin
      TRead.As_<TOneList>(TSerializationFormat.MessagePack,
        TSerializationPayload.FromBytes([$81, $A5, Ord('I'), Ord('t'),
          Ord('e'), Ord('m'), Ord('s'), $DD, $FF, $FF, $FF, $F0, $01]));
    end);
  RefusedSafely('HUGE_LENGTH_BSON',
    procedure
    begin
      TRead.As_<TOneString>(TSerializationFormat.Bson,
        TSerializationPayload.FromBytes([$FF, $FF, $FF, $7F, $02, Ord('S'),
          $00, $FF, $FF, $FF, $7F, Ord('x'), $00, $00]));
    end);
  RefusedSafely('HUGE_LENGTH_PROTOBUF',
    procedure
    begin
      TRead.As_<TOneString>(TSerializationFormat.Protobuf,
        TSerializationPayload.FromBytes(Concat([Byte($0A)],
          Varint(UInt64(1) shl 62), [Ord('x')])));
    end);
  RefusedSafely('HUGE_LENGTH_AVRO',
    procedure
    begin
      TRead.As_<TOneString>(TSerializationFormat.Avro,
        TSerializationPayload.FromBytes(Concat(
          Varint(UInt64($3FFFFFFFFFFFFFFE)), [Ord('x')])));
    end);
  RefusedSafely('HUGE_COUNT_AVRO',
    procedure
    begin
      TRead.As_<TOneList>(TSerializationFormat.Avro,
        TSerializationPayload.FromBytes(Concat(
          Varint(UInt64($3FFFFFFFFFFFFFFE)), [$02])));
    end);
  for F in [TSerializationFormat.Asn1Ber, TSerializationFormat.Asn1Der,
            TSerializationFormat.Asn1Cer] do
    RefusedSafely('HUGE_LENGTH_' + FmtKey(F),
      procedure
      begin
        TRead.As_<TOneString>(F, TSerializationPayload.FromBytes(
          [$30, $08, $0C, $84, $7F, $FF, $FF, $FF, Ord('x'), Ord('y')]));
      end);

  Writeln;
  Writeln('-- SECURITY_LIMITS: exponential expansion --');
  { The billion laughs: ten entities, each ten of the one before. }
  Laughs := '<?xml version="1.0"?><!DOCTYPE TOneString [<!ENTITY l0 "ha">';
  for I := 1 to 9 do
    Laughs := Laughs + Format('<!ENTITY l%d "%s">',
      [I, Repeated(Format('&l%d;', [I - 1]), 10)]);
  Laughs := Laughs + ']><TOneString><S>&l9;</S></TOneString>';
  RefusedSafely('ENTITY_EXPANSION_XML',
    procedure
    begin
      TRead.As_<TOneString>(TSerializationFormat.Xml,
        TSerializationPayload.FromText(Laughs));
    end);

  { The same with YAML anchors: nine levels of nine. }
  Aliases := 'a0: &a0 [x, x, x, x, x, x, x, x, x]' + sLineBreak;
  for I := 1 to 9 do
    Aliases := Aliases + Format('a%d: &a%d [%s]', [I, I,
      Repeated(Format('*a%d, ', [I - 1]), 8) + Format('*a%d', [I - 1])]) +
      sLineBreak;
  RefusedSafely('ALIAS_EXPANSION_YAML',
    procedure
    begin
      TRead.As_<TOneList>(TSerializationFormat.Yaml,
        TSerializationPayload.FromText(Aliases + 'Items: *a9' + sLineBreak));
    end);
end;

{ ===========================================================================
  MALFORMED_INPUT
  =========================================================================== }

type
  TFuzzTally = record
    Mutations, Read_, Refused, Rtl, Leaked: Integer;
    FirstDefects: TStringList;
  end;

procedure TryRead(AFormat: TSerializationFormat; ARich: Boolean;
  const APayload: TSerializationPayload; const AWhat: string;
  var ATally: TFuzzTally);
var
  Before: Integer;
  Defect: string;
begin
  Inc(ATally.Mutations);
  Before := TTracked.Live;
  Defect := '';
  try
    if ARich then TSerialization.Deserialize<TFuzzRich>(APayload, AFormat).Free
    else TSerialization.Deserialize<TFuzzFlat>(APayload, AFormat).Free;
    Inc(ATally.Read_);
  except
    on E: Exception do
      if IsOwn(E) then Inc(ATally.Refused)
      else
      begin
        Inc(ATally.Rtl);
        Defect := Format('%s: %s: %s', [AWhat, E.ClassName,
          Copy(E.Message, 1, 120)]);
      end;
  end;
  if TTracked.Live <> Before then
  begin
    Inc(ATally.Leaked);
    Defect := Format('%s: LEAKED %d', [AWhat, TTracked.Live - Before]);
    TTracked.Live := Before;
  end;
  if (Defect <> '') and (ATally.FirstDefects.Count < 6) then
    ATally.FirstDefects.Add(Defect);
end;

const
  BYTE_SUBSTITUTES: array[0..5] of Byte = ($00, $FF, $7F, $80, $20, $01);
  CHAR_SUBSTITUTES: array[0..8] of Char =
    ('"', '<', '{', '[', '-', '0', #0, ' ', ':');

procedure FuzzOne(AFormat: TSerializationFormat; ARich: Boolean;
  const AShape: string);
var
  Source: TObject;
  Payload: TSerializationPayload;
  Bytes, M: TBytes;
  Text, T: string;
  Tally: TFuzzTally;
  Len, Step, I, K: Integer;
begin
  if ARich then
  begin
    Source := TFuzzRich.Create;
    TFuzzRich(Source).Fill;
  end
  else
  begin
    Source := TFuzzFlat.Create;
    TFuzzFlat(Source).Fill;
  end;
  try
    try
      if ARich then
        Payload := TSerialization.Serialize<TFuzzRich>(TFuzzRich(Source), AFormat)
      else
        Payload := TSerialization.Serialize<TFuzzFlat>(TFuzzFlat(Source), AFormat);
    except
      on E: Exception do
      begin
        { A shape the format cannot write is not fuzzed; the refusal must
          still be the library's. }
        Check(IsOwn(E), Format('MALFORMED_%s_%s', [AShape, FmtKey(AFormat)]));
        Note(FmtName(AFormat) + ': not written - ' + E.ClassName);
        Exit;
      end;
    end;
  finally
    Source.Free;
  end;

  Tally := Default(TFuzzTally);
  Tally.FirstDefects := TStringList.Create;
  try
    if Payload.IsText then
    begin
      Text := Payload.AsText;
      Len := Length(Text);
      Step := Max(1, Len div 400);
      I := 0;
      while I < Len do
      begin
        TryRead(AFormat, ARich, TSerializationPayload.FromText(Copy(Text, 1, I)),
          Format('cut at %d', [I]), Tally);
        for K := 0 to High(CHAR_SUBSTITUTES) do
        begin
          T := Text;
          T[I + 1] := CHAR_SUBSTITUTES[K];
          TryRead(AFormat, ARich, TSerializationPayload.FromText(T),
            Format('char %d := #%d', [I + 1, Ord(CHAR_SUBSTITUTES[K])]), Tally);
        end;
        Inc(I, Step);
      end;
    end
    else
    begin
      Bytes := Payload.AsBytes;
      Len := Length(Bytes);
      Step := Max(1, Len div 400);
      I := 0;
      while I < Len do
      begin
        TryRead(AFormat, ARich, TSerializationPayload.FromBytes(Copy(Bytes, 0, I)),
          Format('cut at %d', [I]), Tally);
        for K := 0 to High(BYTE_SUBSTITUTES) do
        begin
          M := Copy(Bytes);
          if M[I] = BYTE_SUBSTITUTES[K] then M[I] := M[I] xor $55
          else M[I] := BYTE_SUBSTITUTES[K];
          TryRead(AFormat, ARich, TSerializationPayload.FromBytes(M),
            Format('byte %d := $%.2x', [I, M[I]]), Tally);
        end;
        Inc(I, Step);
      end;
    end;
    Check((Tally.Rtl = 0) and (Tally.Leaked = 0),
      Format('MALFORMED_%s_%s', [AShape, FmtKey(AFormat)]));
    Note(Format('%s: %d damaged documents, %d read, %d refused, %d RTL, ' +
      '%d leaked', [FmtName(AFormat), Tally.Mutations, Tally.Read_,
      Tally.Refused, Tally.Rtl, Tally.Leaked]));
    for I := 0 to Tally.FirstDefects.Count - 1 do
      Note('  ' + Tally.FirstDefects[I]);
  finally
    Tally.FirstDefects.Free;
  end;
end;

procedure TestMalformedInput;
var
  F: TSerializationFormat;
begin
  Writeln;
  Writeln('-- MALFORMED_INPUT: every truncation, and hostile substitutions --');
  for F in TSerialization.ContractFormats do
  begin
    FuzzOne(F, False, 'FLAT');
    if F <> TSerializationFormat.Csv then FuzzOne(F, True, 'RICH');
  end;
end;

{ ===========================================================================
  THREADING
  =========================================================================== }

type
  TColdShape = class(TTracked)
  public
    [ProtoField(1)] A: Integer;
    [ProtoField(2)] B: string;
    [ProtoField(3)] C: TFuzzChild;
    constructor Create;
    destructor Destroy; override;
  end;

constructor TColdShape.Create;
begin
  inherited Create;
  C := TFuzzChild.Create;
end;

destructor TColdShape.Destroy;
begin
  C.Free;
  inherited Destroy;
end;

const
  THREAD_COUNT = 8;
  ITERATIONS = 150;

{ Each thread writes its own values and checks it reads its own values back:
  a plan or a buffer shared by mistake shows up as another thread's number. }
function RunConcurrently(AFormat: TSerializationFormat; ACold: Boolean;
  out ADetail: string): Boolean;
var
  Threads: array[0..THREAD_COUNT - 1] of TThread;
  Go: TEvent;
  Errors: Integer;
  FirstError: string;
  Lock: TCriticalSection;
  I: Integer;

  function MakeWorker(AIndex: Integer): TThread;
  begin
    Result := TThread.CreateAnonymousThread(
      procedure
      var
        N: Integer;
        Src, Back: TColdShape;
        FSrc, FBack: TFuzzFlat;
        P: TSerializationPayload;
        Bad: string;
      begin
        Go.WaitFor(INFINITE);
        for N := 1 to IfThen(ACold, 1, ITERATIONS) do
        begin
          Bad := '';
          try
            if ACold then
            begin
              Src := TColdShape.Create;
              try
                Src.A := AIndex * 1000 + N;
                Src.B := 'thread ' + IntToStr(AIndex);
                Src.C.N := AIndex;
                P := TSerialization.Serialize<TColdShape>(Src, AFormat);
              finally
                Src.Free;
              end;
              Back := TSerialization.Deserialize<TColdShape>(P, AFormat);
              try
                if (Back.A <> AIndex * 1000 + N) or
                   (Back.B <> 'thread ' + IntToStr(AIndex)) or
                   (Back.C.N <> AIndex) then
                  Bad := Format('thread %d read another value back', [AIndex]);
              finally
                Back.Free;
              end;
            end
            else
            begin
              FSrc := TFuzzFlat.Create;
              try
                FSrc.Fill;
                FSrc.Count := AIndex * 100000 + N;
                FSrc.Name := 'thread ' + IntToStr(AIndex);
                P := TSerialization.Serialize<TFuzzFlat>(FSrc, AFormat);
              finally
                FSrc.Free;
              end;
              FBack := TSerialization.Deserialize<TFuzzFlat>(P, AFormat);
              try
                if (FBack.Count <> AIndex * 100000 + N) or
                   (FBack.Name <> 'thread ' + IntToStr(AIndex)) or
                   (FBack.Child.N <> 7) then
                  Bad := Format('thread %d read another value back', [AIndex]);
              finally
                FBack.Free;
              end;
            end;
          except
            on E: Exception do
              Bad := Format('thread %d: %s: %s', [AIndex, E.ClassName, E.Message]);
          end;
          if Bad <> '' then
          begin
            Lock.Enter;
            try
              Inc(Errors);
              if FirstError = '' then FirstError := Bad;
            finally
              Lock.Leave;
            end;
            Exit;
          end;
        end;
      end);
    Result.FreeOnTerminate := False;
  end;

begin
  Errors := 0;
  FirstError := '';
  Go := TEvent.Create(nil, True, False, '');
  Lock := TCriticalSection.Create;
  try
    for I := 0 to THREAD_COUNT - 1 do
    begin
      Threads[I] := MakeWorker(I);
      Threads[I].Start;
    end;
    { All of them released at once, so the first use of a cold type races
      its plan into the caches from eight threads. }
    Go.SetEvent;
    for I := 0 to THREAD_COUNT - 1 do
    begin
      Threads[I].WaitFor;
      Threads[I].Free;
    end;
  finally
    Lock.Free;
    Go.Free;
  end;
  ADetail := FirstError;
  Result := Errors = 0;
end;

procedure TestThreading;
var
  F: TSerializationFormat;
  Detail: string;
  Before: Integer;
  Ok: Boolean;
begin
  Writeln;
  Writeln('-- THREADING: ', THREAD_COUNT, ' threads, a cold type first, then ',
    ITERATIONS, ' round trips each --');
  for F in TSerialization.ContractFormats do
  begin
    Before := TTracked.Live;
    Ok := RunConcurrently(F, True, Detail);
    Check(Ok and (TTracked.Live = Before), 'THREADING_COLD_' + FmtKey(F));
    if Detail <> '' then Note(Detail);
    TTracked.Live := Before;
    Ok := RunConcurrently(F, False, Detail);
    Check(Ok and (TTracked.Live = Before), 'THREADING_WARM_' + FmtKey(F));
    if Detail <> '' then Note(Detail);
    TTracked.Live := Before;
  end;
end;

{ ===========================================================================
  CACHE
  =========================================================================== }

procedure TestPlanCache;
type
  TCounter = reference to function: Integer;
var
  Names: TArray<string>;
  Counters: TArray<TCounter>;
  Formats: TArray<TSerializationFormat>;
  I, N, Before: Integer;
  Src: TFuzzFlat;
  P: TSerializationPayload;
begin
  Writeln;
  Writeln('-- CACHE: the warm path builds no plan --');
  { The engines that keep a plan cache, through their own counters. The
    others resolve through RTTI on every call and have nothing to rebuild. }
  Names := ['XML', 'BSON', 'PROTOBUF', 'MESSAGEPACK'];
  Formats := [TSerializationFormat.Xml, TSerializationFormat.Bson,
    TSerializationFormat.Protobuf, TSerializationFormat.MessagePack];
  Counters := [
    function: Integer begin Result := TXmlEngine.PlanCount end,
    function: Integer begin Result := TBsonEngine.PlanCount end,
    function: Integer begin Result := TProtoEngine.PlanCount end,
    function: Integer begin Result := TMessagePackEngine.PlanCount end];
  for I := 0 to High(Formats) do
  begin
    Src := TFuzzFlat.Create;
    try
      Src.Fill;
      P := TSerialization.Serialize<TFuzzFlat>(Src, Formats[I]);
      TSerialization.Deserialize<TFuzzFlat>(P, Formats[I]).Free;
      Before := Counters[I]();
      for N := 1 to 500 do
      begin
        P := TSerialization.Serialize<TFuzzFlat>(Src, Formats[I]);
        TSerialization.Deserialize<TFuzzFlat>(P, Formats[I]).Free;
      end;
      Check(Counters[I]() = Before, 'PLAN_CACHE_STABLE_' + Names[I]);
      if Counters[I]() <> Before then
        Note(Format('%d plans before, %d after', [Before, Counters[I]()]));
    finally
      Src.Free;
    end;
  end;
end;

var
  Clock: TStopwatch;

var
  Sections: TStringList;

{ One section, timed, with its own gate marker: each of the four questions
  is a release gate of its own, so each says PASS or FAIL by itself. }
procedure Timed(const AName: string; AProc: TProc);
var
  Before: Integer;
begin
  Before := GFailures;
  Clock := TStopwatch.StartNew;
  AProc();
  Writeln(Format('  [%s: %.1f s]', [AName, Clock.Elapsed.TotalSeconds]));
  Sections.Add(AName + ': ' + IfThen(GFailures = Before, 'PASS', 'FAIL'));
end;

begin
  ReportMemoryLeaksOnShutdown := True;
  Sections := TStringList.Create;
  try
    Timed('SECURITY_LIMITS', TestSecurityLimits);
    Timed('MALFORMED_INPUT', TestMalformedInput);
    Timed('THREADING', TestThreading);
    Timed('CACHE', TestPlanCache);
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  for var Line in Sections do Writeln(Line);
  Sections.Free;
  Writeln('CHECKS=', GChecks);
  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then
    Writeln('ROBUSTNESS: PASS')
  else
  begin
    Writeln('ROBUSTNESS: FAIL');
    ExitCode := 1;
  end;
end.
