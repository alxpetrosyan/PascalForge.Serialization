unit ProtoModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{$SCOPEDENUMS ON}

{ The messages the Protobuf tests use.

  The first four are the specification's own worked examples, declared here
  exactly as the encoding guide declares them in .proto, so that the byte
  vectors in the guide can be compared against ours byte for byte:

      message Test1 - optional int32  a = 1
      message Test2 - optional string b = 2
      message Test3 - optional Test1  c = 3
      message Test4 - repeated int32  d = 4, packed

  The rest exercise the parts a worked example does not reach. }

interface

uses
  System.SysUtils, System.Generics.Collections,
  PascalForge.Nullable,
  PascalForge.Protobuf;

type
  { --- the specification's examples ------------------------------------- }

  TTest1 = class
  public
    [ProtoField(1)] A: Integer;
  end;

  TTest2 = class
  public
    [ProtoField(2)] B: string;
  end;

  TTest3 = class
  public
    [ProtoField(3)] C: TTest1;
    destructor Destroy; override;
  end;

  TTest4 = class
  public
    [ProtoField(4)] D: TArray<Integer>;
  end;

  { --- every scalar the wire format has ---------------------------------- }

  TScalars = class
  public
    [ProtoField(1)] I32: Integer;
    [ProtoField(2)] I64: Int64;
    [ProtoField(3), ProtoType(TProtoScalar.UInt32)] U32: Cardinal;
    [ProtoField(4), ProtoType(TProtoScalar.UInt64)] U64: UInt64;
    [ProtoField(5), ProtoType(TProtoScalar.SInt32)] S32: Integer;
    [ProtoField(6), ProtoType(TProtoScalar.SInt64)] S64: Int64;
    [ProtoField(7), ProtoType(TProtoScalar.Fixed32)] F32: Cardinal;
    [ProtoField(8), ProtoType(TProtoScalar.Fixed64)] F64: UInt64;
    [ProtoField(9), ProtoType(TProtoScalar.SFixed32)] SF32: Integer;
    [ProtoField(10), ProtoType(TProtoScalar.SFixed64)] SF64: Int64;
    [ProtoField(11), ProtoType(TProtoScalar.Float)] Fl: Single;
    [ProtoField(12)] Db: Double;
    [ProtoField(13)] Bo: Boolean;
    [ProtoField(14)] St: string;
    [ProtoField(15)] By: TBytes;
  end;

  { --- the rich contract -------------------------------------------------- }

  TPriority = (Low, Normal, High);
  TFlag = (Urgent, Internal, Archived);
  TFlags = set of TFlag;

  TLine = class
  public
    [ProtoField(1)] Sku: string;
    [ProtoField(2)] Qty: Integer;
  end;

  TLines = class(TObjectList<TLine>);

  TAddress = class
  public
    [ProtoField(1)] City: string;
    [ProtoField(2)] Zip: string;
  end;

  TOrder = class
  public
    [ProtoField(1)] Id: Int64;
    [ProtoField(2)] Reference: string;
    [ProtoField(3)] Priority: TPriority;
    [ProtoField(4)] Flags: TFlags;
    [ProtoField(5)] Uid: TGUID;
    [ProtoField(6)] Booked: TDate;
    [ProtoField(7)] Cutoff: TTime;
    [ProtoField(8)] Created: TDateTime;
    [ProtoField(9)] Amount: Currency;
    { Explicit presence: written whenever it has a value, default or not. }
    [ProtoField(10)] Discount: TNullable<Integer>;
    [ProtoField(11)] Note: TNullable<string>;
    [ProtoField(12)] Address: TAddress;
    [ProtoField(13)] Lines: TLines;
    [ProtoField(14)] Tags: TDictionary<string, string>;
    [ProtoField(15), ProtoType(TProtoScalar.SInt32)] Adjustment: TArray<Integer>;
    { Never on the wire. }
    [ProtoIgnore] Cached: string;
    { No field number, so not on the wire either - protobuf has no names to
      fall back on, so a member without one cannot be written at all. }
    Scratch: string;
    destructor Destroy; override;
  end;

  { --- oneof -------------------------------------------------------------- }

  TChoice = class
  public
    [ProtoField(1)] Always: string;
    [ProtoField(2), ProtoOneOf('body')] AsText: TNullable<string>;
    [ProtoField(3), ProtoOneOf('body')] AsNumber: TNullable<Int64>;
    [ProtoField(4), ProtoOneOf('body')] AsMessage: TTest1;
    destructor Destroy; override;
  end;

  { --- unknown fields ----------------------------------------------------- }

  { The same message seen by a program that knows about one field, and by
    one that knows about two. A round trip through the first must not lose
    what only the second understands. }
  TNarrow = class
  public
    [ProtoField(1)] Known: Integer;
    [ProtoUnknown] Unknown: TBytes;
  end;

  TNarrowWithoutStore = class
  public
    [ProtoField(1)] Known: Integer;
  end;

  TWide = class
  public
    [ProtoField(1)] Known: Integer;
    [ProtoField(2)] Extra: string;
    [ProtoField(3)] More: Int64;
  end;

function SampleOrder: TOrder;
function Describe(AOrder: TOrder): string;

implementation

uses
  System.DateUtils;

destructor TTest3.Destroy;
begin
  C.Free;
  inherited Destroy;
end;

destructor TOrder.Destroy;
begin
  Address.Free;
  Lines.Free;
  Tags.Free;
  inherited Destroy;
end;

destructor TChoice.Destroy;
begin
  AsMessage.Free;
  inherited Destroy;
end;

function SampleOrder: TOrder;
var
  L: TLine;
begin
  Result := TOrder.Create;
  Result.Id := 4611686018427387903;
  Result.Reference := 'ORD-2026-0007';
  Result.Priority := TPriority.High;
  Result.Flags := [TFlag.Urgent, TFlag.Archived];
  Result.Uid := StringToGUID('{3F2504E0-4F89-11D3-9A0C-0305E82C3301}');
  Result.Booked := EncodeDate(2026, 3, 14);
  Result.Cutoff := EncodeTime(17, 45, 30, 0);
  Result.Created := EncodeDateTime(2026, 3, 14, 9, 26, 53, 0);
  Result.Amount := 1234.5678;
  Result.Discount := 15;
  Result.Note := nil;

  Result.Address := TAddress.Create;
  Result.Address.City := 'Midtown';
  Result.Address.Zip := '0100';

  Result.Lines := TLines.Create(True);
  L := TLine.Create; L.Sku := 'A-1'; L.Qty := 2; Result.Lines.Add(L);
  L := TLine.Create; L.Sku := 'B-2'; L.Qty := 5; Result.Lines.Add(L);

  Result.Tags := TDictionary<string, string>.Create;
  Result.Tags.Add('channel', 'web');

  Result.Adjustment := TArray<Integer>.Create(-1, 0, 7, -2147483648);
  Result.Cached := 'not on the wire';
  Result.Scratch := 'not on the wire either';
end;

function Describe(AOrder: TOrder): string;
var
  I: Integer;
  Tag: string;
begin
  if AOrder = nil then Exit('(nil)');
  Result := Format('id=%d ref=%s pri=%d flags=%d uid=%s booked=%s cutoff=%s ' +
    'created=%s amount=%s discount=%s:%d note=%s',
    [AOrder.Id, AOrder.Reference, Ord(AOrder.Priority), Byte(AOrder.Flags),
     GUIDToString(AOrder.Uid),
     FormatDateTime('yyyy-mm-dd', AOrder.Booked, TFormatSettings.Invariant),
     FormatDateTime('hh:nn:ss', AOrder.Cutoff, TFormatSettings.Invariant),
     FormatDateTime('yyyy-mm-dd hh:nn:ss', AOrder.Created,
       TFormatSettings.Invariant),
     CurrToStr(AOrder.Amount, TFormatSettings.Invariant),
     BoolToStr(AOrder.Discount.HasValue, True), AOrder.Discount.Value,
     BoolToStr(AOrder.Note.HasValue, True)]);

  if AOrder.Address <> nil then
    Result := Result + Format(' addr=%s/%s',
      [AOrder.Address.City, AOrder.Address.Zip])
  else
    Result := Result + ' addr=(nil)';

  if AOrder.Lines <> nil then
  begin
    Result := Result + ' lines=';
    for I := 0 to AOrder.Lines.Count - 1 do
      Result := Result + Format('[%s:%d]',
        [AOrder.Lines[I].Sku, AOrder.Lines[I].Qty]);
  end
  else
    Result := Result + ' lines=(nil)';

  if (AOrder.Tags <> nil) and AOrder.Tags.TryGetValue('channel', Tag) then
    Result := Result + ' tag=' + Tag
  else
    Result := Result + ' tag=(none)';

  Result := Result + ' adj=';
  for I := 0 to High(AOrder.Adjustment) do
    Result := Result + IntToStr(AOrder.Adjustment[I]) + ',';
end;

end.
