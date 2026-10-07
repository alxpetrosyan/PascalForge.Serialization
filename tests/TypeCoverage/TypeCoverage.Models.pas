unit TypeCoverage.Models;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ THE DELPHI LANGUAGE, ONE FAMILY AT A TIME.

  Every class here isolates one family of types, so that when a format
  refuses or mishandles something, the family it did it to is the name of the
  class. A single "everything" model would fail on its worst member and say
  nothing about the rest.

  The unsafe kinds - pointers, procedural and method values, class
  references, interfaces - each get a class of their own for the same reason:
  a refusal must be attributable to exactly one type, or it cannot be judged.

  Nothing here comes from any application. These are the shapes the language
  allows, including the ones no ordinary DTO would use, because a library
  claiming to understand Delphi types has to be asked about all of them. }

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Variants,
  System.Generics.Collections,
  Data.FmtBcd,
  PascalForge.Nullable,
  PascalForge.Protobuf;

type
  {$SCOPEDENUMS ON}
  TProbeColor = (Red, Green, Blue, Cyan, Magenta, Yellow, Black, White);
  {$SCOPEDENUMS OFF}

  { An enum with forty members: a set of it is five bytes, which is what
    catches an engine that assumes a set fits in an Integer. }
  TProbeWide = (w00, w01, w02, w03, w04, w05, w06, w07, w08, w09,
                w10, w11, w12, w13, w14, w15, w16, w17, w18, w19,
                w20, w21, w22, w23, w24, w25, w26, w27, w28, w29,
                w30, w31, w32, w33, w34, w35, w36, w37, w38, w39);

  { A subrange whose minimum is not zero. Its set is stored from bit
    MinValue, not from bit 0, and an engine that forgets that shifts every
    member by the minimum. }
  TProbeHigh = w10..w19;

  TProbeSmallSet = set of TProbeColor;

  { NAMED static array types. Delphi emits no usable RTTI for an array
    declared inline in a field, so a static array a serializer can see
    has to have a name - and these are the ones that test support. }
  TThreeInts = array[0..2] of Integer;
  TOffsetInts = array[5..7] of Integer;
  TGrid = array[0..1, 0..2] of Integer;
  TProbeWideSet = set of TProbeWide;
  TProbeHighSet = set of TProbeHigh;

  { ---------------------------------------------------------------- C --- }

  TIntegerProbe = class
  public
    [ProtoField(1)] I8: ShortInt;
    [ProtoField(2)] U8: Byte;
    [ProtoField(3)] I16: SmallInt;
    [ProtoField(4)] U16: Word;
    [ProtoField(5)] I32: Integer;
    [ProtoField(6)] U32: Cardinal;
    [ProtoField(7)] I64: Int64;
    [ProtoField(8)] U64: UInt64;
    [ProtoField(9)] INat: NativeInt;
    [ProtoField(10)] UNat: NativeUInt;
    procedure FillMin;
    procedure FillMax;
    procedure FillZero;
  end;

  { ---------------------------------------------------------------- D --- }

  TFloatProbe = class
  public
    [ProtoField(1)] S: Single;
    [ProtoField(2)] D: Double;
    [ProtoField(3)] E: Extended;
    [ProtoField(4)] C: Currency;
    [ProtoField(5)] K: Comp;
    procedure Fill;
  end;

  { The unsigned values no signed 64-bit integer holds: 2^64 - 1 and 2^63.
    A format that writes them as -1 and -9223372036854775808 reads them
    back into the same field and lies to every other reader. }
  TUInt64Probe = class
  public
    [ProtoField(1)] U64: UInt64;
    [ProtoField(2)] UNat: NativeUInt;
    [ProtoField(3)] Above: UInt64;
    procedure Fill;
  end;

  { Non-finite values and minus zero, in a class of their own so that a
    format's policy on them is visible separately from ordinary floats. }
  TNonFiniteProbe = class
  public
    [ProtoField(1)] NotANumber: Double;
    [ProtoField(2)] PlusInf: Double;
    [ProtoField(3)] MinusInf: Double;
    procedure Fill;
  end;

  TNegativeZeroProbe = class
  public
    [ProtoField(1)] Z: Double;
    procedure Fill;
  end;

  { ---------------------------------------------------------------- E --- }

  TTextProbe = class
  public
    [ProtoField(1)] Ch: Char;
    [ProtoField(2)] Wc: WideChar;
    [ProtoField(3)] U: UnicodeString;
    [ProtoField(4)] W: WideString;
    [ProtoField(5)] Georgian: string;
    [ProtoField(6)] Emoji: string;
    [ProtoField(7)] Combining: string;
    [ProtoField(8)] Cjk: string;
    [ProtoField(9)] Cyrillic: string;
    procedure Fill;
  end;

  TEmbeddedNullProbe = class
  public
    [ProtoField(1)] S: string;
    procedure Fill;
  end;

  TControlCharProbe = class
  public
    [ProtoField(1)] S: string;
    procedure Fill;
  end;

  { The legacy 8-bit string types, separately, because their meaning
    depends on a code page the library may not be able to know. }
  TAnsiProbe = class
  public
    [ProtoField(1)] A: AnsiString;
    [ProtoField(2)] AC: AnsiChar;
    procedure Fill;
  end;

  TUtf8StringProbe = class
  public
    [ProtoField(1)] S: UTF8String;
    procedure Fill;
  end;

  TRawByteProbe = class
  public
    [ProtoField(1)] S: RawByteString;
    procedure Fill;
  end;

  TShortStringProbe = class
  public
    [ProtoField(1)] S: ShortString;
    procedure Fill;
  end;

  { ---------------------------------------------------------------- F --- }

  TEnumProbe = class
  public
    [ProtoField(1)] First: TProbeColor;
    [ProtoField(2)] Last: TProbeColor;
    [ProtoField(3)] Wide: TProbeWide;
    [ProtoField(4)] High_: TProbeHigh;
    [ProtoField(5)] Flag: Boolean;
    procedure Fill;
  end;

  { Sets whose members have no names: characters and integers. The engines
    once asked GetEnumName for them, which for an AnsiChar read a pointer
    that is not there. A comma and a space are among the members on
    purpose - two formats join set members with exactly those. }
  TProbeSmallInts = 0..63;
  TProbeIntSet = set of TProbeSmallInts;
  TProbeByteSet = set of Byte;
  TCharSetProbe = class
  public
    [ProtoField(1)] Chars: TSysCharSet;
    [ProtoField(2)] Ints: TProbeIntSet;
    [ProtoField(3)] Bytes: TProbeByteSet;
    procedure Fill;
  end;

  TSetProbe = class
  public
    [ProtoField(1)] Small: TProbeSmallSet;
    [ProtoField(2)] Wide: TProbeWideSet;
    [ProtoField(3)] HighSet: TProbeHighSet;
    [ProtoField(4)] Empty: TProbeSmallSet;
    [ProtoField(5)] Full: TProbeSmallSet;
    [ProtoField(6)] FullWide: TProbeWideSet;
    procedure Fill;
  end;

  { ---------------------------------------------------------------- G --- }

  TDynArrayProbe = class
  public
    [ProtoField(1)] Ints: TArray<Integer>;
    [ProtoField(2)] Strs: TArray<string>;
    [ProtoField(3)] Empty: TArray<Integer>;
    procedure Fill;
  end;

  TBytesProbe = class
  public
    [ProtoField(1)] B: TBytes;
    [ProtoField(2)] Empty: TBytes;
    procedure Fill;
  end;

  TStaticArrayProbe = class
  public
    [ProtoField(1)] Zero: TThreeInts;
    procedure Fill;
  end;

  TOffsetArrayProbe = class
  public
    [ProtoField(1)] Offset: TOffsetInts;
    procedure Fill;
  end;

  TMatrixProbe = class
  public
    [ProtoField(1)] Grid: TGrid;
    procedure Fill;
  end;

  { The INLINE form, which has no RTTI. The right answer is a refusal that
    says to give the array a name. }
  TInlineArrayProbe = class
  public
    [ProtoField(1)] Unnamed: array[0..2] of Integer;
    procedure Fill;
  end;

  TNestedArrayProbe = class
  public
    [ProtoField(1)] Jagged: TArray<TArray<Integer>>;
    procedure Fill;
  end;

  TNullableArrayProbe = class
  public
    [ProtoField(1)] Items: TArray<TNullable<Integer>>;
    procedure Fill;
  end;

  { ---------------------------------------------------------------- H --- }

  TPlainRecord = record
    [ProtoField(1)] X: Integer;
    [ProtoField(2)] Name: string;
  end;

  TPlainRecordProbe = class
  public
    [ProtoField(1)] R: TPlainRecord;
    [ProtoField(2)] Many: TArray<TPlainRecord>;
    procedure Fill;
  end;

  { A managed record: the compiler calls Initialize when one is created,
    Finalize when it dies and Assign when it is copied. A deserializer that
    builds one by writing raw memory skips Initialize, and one that copies
    fields itself skips Assign. The counters say which happened. }
  TManagedRecord = record
  public
    [ProtoField(1)] Value: Integer;
    [ProtoField(2)] Tag: string;
    class operator Initialize(out ADest: TManagedRecord);
    class operator Finalize(var ADest: TManagedRecord);
    class operator Assign(var ADest: TManagedRecord;
      const [ref] ASrc: TManagedRecord);
  end;

  TManagedRecordProbe = class
  public
    [ProtoField(1)] M: TManagedRecord;
    procedure Fill;
  end;

  TGenericRecord<T> = record
    [ProtoField(1)] Key: string;
    [ProtoField(2)] Value: T;
  end;

  TGenericRecordProbe = class
  public
    [ProtoField(1)] IntPair: TGenericRecord<Integer>;
    [ProtoField(2)] StrPair: TGenericRecord<string>;
    procedure Fill;
  end;

  { A variant record: two members sharing the same bytes. RTTI reports both,
    and writing both is writing the same memory twice under two meanings. }
  TVariantRecord = record
    Kind: Integer;
    case Integer of
      0: (AsInt: Integer);
      1: (AsFloat: Single);
  end;

  TVariantRecordProbe = class
  public
    [ProtoField(1)] V: TVariantRecord;
    procedure Fill;
  end;

  TPackedRecord = packed record
    [ProtoField(1)] B: Byte;
    [ProtoField(2)] I: Integer;
    [ProtoField(3)] W: Word;
  end;

  TPackedRecordProbe = class
  public
    [ProtoField(1)] P: TPackedRecord;
    procedure Fill;
  end;

  { ---------------------------------------------------------------- I --- }

  TProbeBase = class
  public
    [ProtoField(1)] BaseValue: Integer;
  end;

  TProbeMiddle = class(TProbeBase)
  public
    [ProtoField(2)] MiddleValue: string;
  end;

  TInheritanceProbe = class(TProbeMiddle)
  public
    [ProtoField(3)] LeafValue: Double;
    procedure Fill;
  end;

  { Properties a serializer must not call carelessly: an indexed one has no
    getter without an index, and a write-only one has no getter at all. }
  TPropertyProbe = class
  strict private
    FVisible: Integer;
    FReadOnly: Integer;
    FWriteOnly: Integer;
    FItems: array[0..2] of Integer;
    function GetItem(AIndex: Integer): Integer;
    procedure SetItem(AIndex: Integer; AValue: Integer);
    procedure SetWriteOnly(AValue: Integer);
  public
    procedure Fill;
    function WriteOnlyWas: Integer;
    [ProtoField(1)] property Visible: Integer read FVisible write FVisible;
    property ReadOnly: Integer read FReadOnly;
    property WriteOnly: Integer write SetWriteOnly;
    property Items[AIndex: Integer]: Integer read GetItem write SetItem;
  end;

  { ---------------------------------------------------------------- O/P -- }

  TProbeItem = class
  public
    [ProtoField(1)] Name: string;
    [ProtoField(2)] Qty: Integer;
    constructor Create; overload;
    constructor Create(const AName: string; AQty: Integer); overload;
  end;

  TListProbe = class
  public
    [ProtoField(1)] Ints: TList<Integer>;
    [ProtoField(2)] Objs: TObjectList<TProbeItem>;
    constructor Create;
    destructor Destroy; override;
    procedure Fill;
  end;

  TDictionaryProbe = class
  public
    [ProtoField(1)] ByName: TDictionary<string, Integer>;
    [ProtoField(2)] ObjByName: TObjectDictionary<string, TProbeItem>;
    constructor Create;
    destructor Destroy; override;
    procedure Fill;
  end;

  TIntKeyDictionaryProbe = class
  public
    [ProtoField(1)] ByCode: TDictionary<Integer, string>;
    constructor Create;
    destructor Destroy; override;
    procedure Fill;
  end;

  TNestedContainerProbe = class
  public
    [ProtoField(1)] Rows: TObjectList<TList<Integer>>;
    [ProtoField(2)] Groups: TObjectDictionary<string, TList<Integer>>;
    constructor Create;
    destructor Destroy; override;
    procedure Fill;
  end;

  TQueueProbe = class
  public
    [ProtoField(1)] Q: TQueue<Integer>;
    constructor Create;
    destructor Destroy; override;
    procedure Fill;
  end;

  TStackProbe = class
  public
    [ProtoField(1)] S: TStack<Integer>;
    constructor Create;
    destructor Destroy; override;
    procedure Fill;
  end;

  TNullableListProbe = class
  public
    [ProtoField(1)] Maybe: TNullable<Integer>;
    [ProtoField(2)] Absent: TNullable<Integer>;
    [ProtoField(3)] MaybeText: TNullable<string>;
    procedure Fill;
  end;

  { ---------------------------------------------------------------- Q --- }

  TStringListProbe = class
  public
    [ProtoField(1)] Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Fill;
  end;

  TLegacyListProbe = class
  public
    [ProtoField(1)] Items: TList;
    constructor Create;
    destructor Destroy; override;
    procedure Fill;
  end;

  TProbeCollectionItem = class(TCollectionItem)
  strict private
    FText: string;
  published
    property Text: string read FText write FText;
  end;

  TCollectionProbe = class
  public
    [ProtoField(1)] Items: TCollection;
    constructor Create;
    destructor Destroy; override;
    procedure Fill;
  end;

  { ---------------------------------------------------------------- R/S -- }

  TTemporalProbe = class
  public
    [ProtoField(1)] Day: TDate;
    [ProtoField(2)] Clock: TTime;
    [ProtoField(3)] Moment: TDateTime;
    procedure Fill;
  end;

  TGuidProbe = class
  public
    [ProtoField(1)] Id: TGUID;
    [ProtoField(2)] Empty: TGUID;
    procedure Fill;
  end;

  TBcdProbe = class
  public
    [ProtoField(1)] Amount: TBcd;
    procedure Fill;
  end;

  { ---------------------------------------------------------------- M --- }

  TVariantProbe = class
  public
    [ProtoField(1)] VInt: Variant;
    [ProtoField(2)] VStr: Variant;
    [ProtoField(3)] VFloat: Variant;
    [ProtoField(4)] VBool: Variant;
    procedure Fill;
  end;

  TVariantNullProbe = class
  public
    [ProtoField(1)] VNull: Variant;
    [ProtoField(2)] VEmpty: Variant;
    procedure Fill;
  end;

  TVariantArrayProbe = class
  public
    [ProtoField(1)] V: Variant;
    procedure Fill;
  end;

  TOleVariantProbe = class
  public
    [ProtoField(1)] V: OleVariant;
    procedure Fill;
  end;

  { ---------------------------------------------- N, K, L, T, U: unsafe -- }

  TPointerProbe = class
  public
    [ProtoField(1)] P: Pointer;
    procedure Fill;
  end;

  TPCharProbe = class
  public
    [ProtoField(1)] P: PChar;
    procedure Fill;
  end;

  TProbeProc = procedure(AValue: Integer);

  TProcVarProbe = class
  public
    [ProtoField(1)] P: TProbeProc;
    procedure Fill;
  end;

  TMethodProbe = class
  public
    [ProtoField(1)] OnChange: TNotifyEvent;
    procedure Fill;
    procedure Handler(Sender: TObject);
  end;

  TAnonymousProbe = class
  public
    [ProtoField(1)] Callback: TProc<Integer>;
    procedure Fill;
  end;

  TClassRefProbe = class
  public
    [ProtoField(1)] Kind: TClass;
    procedure Fill;
  end;

  TInterfaceProbe = class
  public
    [ProtoField(1)] Handle: IInterface;
    procedure Fill;
  end;

  TStreamProbe = class
  public
    [ProtoField(1)] Data: TMemoryStream;
    constructor Create;
    destructor Destroy; override;
    procedure Fill;
  end;

  TExceptionProbe = class
  public
    [ProtoField(1)] Error: Exception;
    destructor Destroy; override;
    procedure Fill;
  end;

  TComponentProbe = class
  public
    [ProtoField(1)] Owner_: TComponent;
    destructor Destroy; override;
    procedure Fill;
  end;

  { ---------------------------------------------------------------- X/Y -- }

  TCycleNode = class
  public
    [ProtoField(1)] Name: string;
    [ProtoField(2)] Next: TCycleNode;
  end;

  TCycleProbe = class
  public
    [ProtoField(1)] Head: TCycleNode;
    destructor Destroy; override;
    procedure Fill;
  end;

  TSharedChild = class
  public
    [ProtoField(1)] Value: Integer;
  end;

  TSharedProbe = class
  public
    [ProtoField(1)] Left: TSharedChild;
    [ProtoField(2)] Right: TSharedChild;
    destructor Destroy; override;
    procedure Fill;
  end;

  TEmptyProbe = class
  public
    [ProtoField(1)] NilObject: TProbeItem;
    [ProtoField(2)] EmptyText: string;
    [ProtoField(3)] ZeroNumber: Integer;
    [ProtoField(4)] FalseFlag: Boolean;
    [ProtoField(5)] DefaultEnum: TProbeColor;
    [ProtoField(6)] NoValue: TNullable<Integer>;
    [ProtoField(7)] EmptyList: TList<Integer>;
    [ProtoField(8)] EmptyArray: TArray<Integer>;
    constructor Create;
    destructor Destroy; override;
    procedure Fill;
  end;

var
  { Managed-record lifecycle counters, read by the test. }
  GManagedInits: Integer = 0;
  GManagedFinals: Integer = 0;
  GManagedAssigns: Integer = 0;

  { Set by TProbeProc so a test can prove it was never CALLED. }
  GProcCalled: Boolean = False;

procedure ProbeProcTarget(AValue: Integer);

implementation

procedure ProbeProcTarget(AValue: Integer);
begin
  GProcCalled := True;
end;

{ TIntegerProbe }

procedure TIntegerProbe.FillMin;
begin
  I8 := Low(ShortInt); U8 := Low(Byte); I16 := Low(SmallInt); U16 := Low(Word);
  I32 := Low(Integer); U32 := Low(Cardinal); I64 := Low(Int64);
  U64 := Low(UInt64); INat := Low(NativeInt); UNat := Low(NativeUInt);
end;

procedure TIntegerProbe.FillMax;
begin
  I8 := High(ShortInt); U8 := High(Byte); I16 := High(SmallInt);
  U16 := High(Word); I32 := High(Integer); U32 := High(Cardinal);
  I64 := High(Int64); INat := High(NativeInt);
  { The top of every type that every format can hold. The unsigned values
    past High(Int64) have a probe of their own, TUInt64Probe, because two
    formats have no integer that holds them and refusing is their answer -
    which would otherwise hide every other value here. }
  U64 := UInt64(High(Int64));
  {$IFDEF CPU64BITS}
  UNat := NativeUInt(High(Int64));
  {$ELSE}
  UNat := High(NativeUInt);
  {$ENDIF}
end;

procedure TUInt64Probe.Fill;
begin
  U64 := High(UInt64);
  UNat := High(NativeUInt);
  Above := UInt64(High(Int64)) + 1;
end;

procedure TIntegerProbe.FillZero;
begin
  I8 := 0; U8 := 0; I16 := 0; U16 := 0; I32 := 0; U32 := 0; I64 := 0;
  U64 := 0; INat := 0; UNat := 0;
end;

{ TFloatProbe }

procedure TFloatProbe.Fill;
begin
  S := 1.5;
  D := 0.1;                     { not exactly representable: a real test }
  E := 1.0 / 3.0;
  C := 922337203685477.5807;    { High(Currency) }
  K := 9007199254740993;        { 2^53 + 1: past what a Double holds }
end;

procedure TNonFiniteProbe.Fill;
begin
  NotANumber := NaN;
  PlusInf := Infinity;
  MinusInf := NegInfinity;
end;

procedure TNegativeZeroProbe.Fill;
begin
  Z := -0.0;
end;

{ TTextProbe }

procedure TTextProbe.Fill;
begin
  Ch := 'Z';
  Wc := #$10D0;
  U := 'plain ascii';
  W := 'wide ' + #$10D2;
  Georgian := #$10D2#$10D8#$10DA#$10DD#$10EA#$10D0;
  Emoji := Char($D83D) + Char($DE00);
  Combining := 'e' + Char($0301);
  Cjk := #$4E2D#$6587;
  Cyrillic := #$041F#$0440#$0438#$0432#$0435#$0442;
end;

procedure TEmbeddedNullProbe.Fill;
begin
  S := 'before' + #0 + 'after';
end;

procedure TControlCharProbe.Fill;
begin
  S := 'tab' + #9 + 'nl' + #10 + 'cr' + #13 + 'bell' + #7;
end;

procedure TAnsiProbe.Fill;
begin
  A := 'ascii-only';
  AC := 'Q';
end;

procedure TUtf8StringProbe.Fill;
begin
  S := UTF8String(#$10D2#$10D8#$10DA#$10DD);
end;

procedure TRawByteProbe.Fill;
begin
  S := RawByteString('raw');
end;

procedure TShortStringProbe.Fill;
begin
  S := 'short';
end;

{ TEnumProbe }

procedure TEnumProbe.Fill;
begin
  First := TProbeColor.Red;
  Last := TProbeColor.White;
  Wide := w39;
  High_ := w17;
  Flag := True;
end;

{ TSetProbe }

procedure TCharSetProbe.Fill;
begin
  Chars := [#0, ' ', ',', 'a', 'Z', #255];
  Ints := [0, 5, 63];
  Bytes := [0, 128, 255];
end;

procedure TSetProbe.Fill;
begin
  Small := [TProbeColor.Green, TProbeColor.Yellow];
  Wide := [w00, w08, w31, w32, w39];
  HighSet := [w10, w15, w19];
  Empty := [];
  Full := [TProbeColor.Red..TProbeColor.White];
  FullWide := [Low(TProbeWide)..High(TProbeWide)];
end;

{ arrays }

procedure TDynArrayProbe.Fill;
begin
  Ints := [3, 1, 4, 1, 5];
  Strs := ['a', '', 'c'];
  Empty := nil;
end;

procedure TBytesProbe.Fill;
begin
  B := TBytes.Create($00, $01, $7F, $80, $FF);
  Empty := nil;
end;

procedure TStaticArrayProbe.Fill;
begin
  Zero[0] := 10; Zero[1] := 20; Zero[2] := 30;
end;

procedure TOffsetArrayProbe.Fill;
begin
  Offset[5] := 50; Offset[6] := 60; Offset[7] := 70;
end;

procedure TMatrixProbe.Fill;
begin
  Grid[0, 0] := 1; Grid[0, 1] := 2; Grid[0, 2] := 3;
  Grid[1, 0] := 4; Grid[1, 1] := 5; Grid[1, 2] := 6;
end;

procedure TInlineArrayProbe.Fill;
begin
  Unnamed[0] := 1; Unnamed[1] := 2; Unnamed[2] := 3;
end;

procedure TNestedArrayProbe.Fill;
begin
  Jagged := [[1, 2], [], [3, 4, 5]];
end;

procedure TNullableArrayProbe.Fill;
var
  A, B: TNullable<Integer>;
begin
  A := 7;
  B := nil;
  Items := [A, B, A];
end;

{ records }

procedure TPlainRecordProbe.Fill;
var
  One: TPlainRecord;
begin
  R.X := 42;
  R.Name := 'rec';
  One.X := 1; One.Name := 'one';
  Many := [One, One];
end;

class operator TManagedRecord.Initialize(out ADest: TManagedRecord);
begin
  ADest.Value := -1;
  ADest.Tag := 'initialized';
  AtomicIncrement(GManagedInits);
end;

class operator TManagedRecord.Finalize(var ADest: TManagedRecord);
begin
  AtomicIncrement(GManagedFinals);
end;

class operator TManagedRecord.Assign(var ADest: TManagedRecord;
  const [ref] ASrc: TManagedRecord);
begin
  ADest.Value := ASrc.Value;
  ADest.Tag := ASrc.Tag;
  AtomicIncrement(GManagedAssigns);
end;

procedure TManagedRecordProbe.Fill;
begin
  M.Value := 99;
  M.Tag := 'managed';
end;

procedure TGenericRecordProbe.Fill;
begin
  IntPair.Key := 'int'; IntPair.Value := 5;
  StrPair.Key := 'str'; StrPair.Value := 'five';
end;

procedure TVariantRecordProbe.Fill;
begin
  V.Kind := 0;
  V.AsInt := 123;
end;

procedure TPackedRecordProbe.Fill;
begin
  P.B := 7; P.I := 70000; P.W := 700;
end;

{ classes }

procedure TInheritanceProbe.Fill;
begin
  BaseValue := 1;
  MiddleValue := 'middle';
  LeafValue := 2.5;
end;

function TPropertyProbe.GetItem(AIndex: Integer): Integer;
begin
  Result := FItems[AIndex];
end;

procedure TPropertyProbe.SetItem(AIndex: Integer; AValue: Integer);
begin
  FItems[AIndex] := AValue;
end;

procedure TPropertyProbe.SetWriteOnly(AValue: Integer);
begin
  FWriteOnly := AValue;
end;

function TPropertyProbe.WriteOnlyWas: Integer;
begin
  Result := FWriteOnly;
end;

procedure TPropertyProbe.Fill;
begin
  FVisible := 11;
  FReadOnly := 22;
  FWriteOnly := 33;
  FItems[0] := 1; FItems[1] := 2; FItems[2] := 3;
end;

{ containers }

constructor TProbeItem.Create;
begin
  inherited Create;
end;

constructor TProbeItem.Create(const AName: string; AQty: Integer);
begin
  inherited Create;
  Name := AName;
  Qty := AQty;
end;

constructor TListProbe.Create;
begin
  inherited;
  Ints := TList<Integer>.Create;
  Objs := TObjectList<TProbeItem>.Create(True);
end;

destructor TListProbe.Destroy;
begin
  Objs.Free;
  Ints.Free;
  inherited;
end;

procedure TListProbe.Fill;
begin
  Ints.AddRange([5, 3, 8]);
  Objs.Add(TProbeItem.Create('a', 1));
  Objs.Add(TProbeItem.Create('b', 2));
end;

constructor TDictionaryProbe.Create;
begin
  inherited;
  ByName := TDictionary<string, Integer>.Create;
  ObjByName := TObjectDictionary<string, TProbeItem>.Create([doOwnsValues]);
end;

destructor TDictionaryProbe.Destroy;
begin
  ObjByName.Free;
  ByName.Free;
  inherited;
end;

procedure TDictionaryProbe.Fill;
begin
  ByName.Add('one', 1);
  ByName.Add('two', 2);
  ObjByName.Add('x', TProbeItem.Create('x', 10));
end;

constructor TIntKeyDictionaryProbe.Create;
begin
  inherited;
  ByCode := TDictionary<Integer, string>.Create;
end;

destructor TIntKeyDictionaryProbe.Destroy;
begin
  ByCode.Free;
  inherited;
end;

procedure TIntKeyDictionaryProbe.Fill;
begin
  ByCode.Add(404, 'not found');
  ByCode.Add(200, 'ok');
end;

constructor TNestedContainerProbe.Create;
begin
  inherited;
  Rows := TObjectList<TList<Integer>>.Create(True);
  Groups := TObjectDictionary<string, TList<Integer>>.Create([doOwnsValues]);
end;

destructor TNestedContainerProbe.Destroy;
begin
  Groups.Free;
  Rows.Free;
  inherited;
end;

procedure TNestedContainerProbe.Fill;
var
  L: TList<Integer>;
begin
  L := TList<Integer>.Create; L.AddRange([1, 2]); Rows.Add(L);
  L := TList<Integer>.Create; Rows.Add(L);
  L := TList<Integer>.Create; L.AddRange([9]); Groups.Add('g', L);
end;

constructor TQueueProbe.Create;
begin
  inherited;
  Q := TQueue<Integer>.Create;
end;

destructor TQueueProbe.Destroy;
begin
  Q.Free;
  inherited;
end;

procedure TQueueProbe.Fill;
begin
  Q.Enqueue(1); Q.Enqueue(2); Q.Enqueue(3);
end;

constructor TStackProbe.Create;
begin
  inherited;
  S := TStack<Integer>.Create;
end;

destructor TStackProbe.Destroy;
begin
  S.Free;
  inherited;
end;

procedure TStackProbe.Fill;
begin
  S.Push(1); S.Push(2); S.Push(3);
end;

procedure TNullableListProbe.Fill;
begin
  Maybe := 5;
  Absent := nil;
  MaybeText := 'text';
end;

constructor TStringListProbe.Create;
begin
  inherited;
  Lines := TStringList.Create;
end;

destructor TStringListProbe.Destroy;
begin
  Lines.Free;
  inherited;
end;

procedure TStringListProbe.Fill;
begin
  Lines.Add('alpha');
  Lines.Add('beta');
  Lines.Add('key=value');
end;

constructor TLegacyListProbe.Create;
begin
  inherited;
  Items := TList.Create;
end;

destructor TLegacyListProbe.Destroy;
begin
  Items.Free;
  inherited;
end;

procedure TLegacyListProbe.Fill;
begin
  Items.Add(Pointer(1));
end;

constructor TCollectionProbe.Create;
begin
  inherited;
  Items := TCollection.Create(TProbeCollectionItem);
end;

destructor TCollectionProbe.Destroy;
begin
  Items.Free;
  inherited;
end;

procedure TCollectionProbe.Fill;
begin
  TProbeCollectionItem(Items.Add).Text := 'first';
  TProbeCollectionItem(Items.Add).Text := 'second';
end;

{ temporal and special scalars }

procedure TTemporalProbe.Fill;
begin
  Day := EncodeDate(2026, 9, 22);
  Clock := EncodeTime(14, 35, 7, 123);
  Moment := EncodeDate(2026, 9, 22) + EncodeTime(14, 35, 7, 123);
end;

procedure TGuidProbe.Fill;
begin
  Id := StringToGUID('{0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0}');
  Empty := TGUID.Empty;
end;

procedure TBcdProbe.Fill;
begin
  Amount := StrToBcd('12345678901234567890.1234', TFormatSettings.Invariant);
end;

{ variants }

procedure TVariantProbe.Fill;
begin
  VInt := 42;
  VStr := 'variant';
  VFloat := 2.5;
  VBool := True;
end;

procedure TVariantNullProbe.Fill;
begin
  VNull := Null;
  VEmpty := Unassigned;
end;

procedure TVariantArrayProbe.Fill;
begin
  V := VarArrayOf([1, 'two', 3.0]);
end;

procedure TOleVariantProbe.Fill;
begin
  V := 'ole';
end;

{ unsafe }

procedure TPointerProbe.Fill;
begin
  P := Pointer($12345678);
end;

procedure TPCharProbe.Fill;
begin
  P := PChar('literal');
end;

procedure TProcVarProbe.Fill;
begin
  P := ProbeProcTarget;
end;

procedure TMethodProbe.Handler(Sender: TObject);
begin
end;

procedure TMethodProbe.Fill;
begin
  OnChange := Handler;
end;

procedure TAnonymousProbe.Fill;
begin
  Callback := procedure(AValue: Integer) begin GProcCalled := True; end;
end;

procedure TClassRefProbe.Fill;
begin
  Kind := TStringList;
end;

procedure TInterfaceProbe.Fill;
begin
  Handle := TInterfacedObject.Create;
end;

constructor TStreamProbe.Create;
begin
  inherited;
  Data := TMemoryStream.Create;
end;

destructor TStreamProbe.Destroy;
begin
  Data.Free;
  inherited;
end;

procedure TStreamProbe.Fill;
var
  B: TBytes;
begin
  B := TBytes.Create(1, 2, 3);
  Data.WriteBuffer(B, 3);
  Data.Position := 1;
end;

destructor TExceptionProbe.Destroy;
begin
  Error.Free;
  inherited;
end;

procedure TExceptionProbe.Fill;
begin
  Error := Exception.Create('probe');
end;

destructor TComponentProbe.Destroy;
begin
  Owner_.Free;
  inherited;
end;

procedure TComponentProbe.Fill;
begin
  Owner_ := TComponent.Create(nil);
  Owner_.Name := 'Root';
  TComponent.Create(Owner_).Name := 'Child';
end;

{ graphs }

destructor TCycleProbe.Destroy;
begin
  { Break the ring before freeing, or the second Free walks freed memory. }
  if (Head <> nil) and (Head.Next <> nil) then
  begin
    if Head.Next.Next = Head then Head.Next.Next := nil;
    Head.Next.Free;
  end;
  Head.Free;
  inherited;
end;

procedure TCycleProbe.Fill;
var
  B: TCycleNode;
begin
  Head := TCycleNode.Create;
  Head.Name := 'A';
  B := TCycleNode.Create;
  B.Name := 'B';
  Head.Next := B;
  B.Next := Head;
end;

destructor TSharedProbe.Destroy;
begin
  if Right <> Left then Right.Free;
  Left.Free;
  inherited;
end;

procedure TSharedProbe.Fill;
begin
  Left := TSharedChild.Create;
  Left.Value := 7;
  Right := Left;
end;

constructor TEmptyProbe.Create;
begin
  inherited;
  EmptyList := TList<Integer>.Create;
end;

destructor TEmptyProbe.Destroy;
begin
  EmptyList.Free;
  NilObject.Free;
  inherited;
end;

procedure TEmptyProbe.Fill;
begin
  NilObject := nil;
  EmptyText := '';
  ZeroNumber := 0;
  FalseFlag := False;
  DefaultEnum := TProbeColor.Red;
  NoValue := nil;
  EmptyArray := nil;
end;

end.
