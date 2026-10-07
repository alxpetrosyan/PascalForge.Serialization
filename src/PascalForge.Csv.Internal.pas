{*******************************************************************************
  PascalForge.Csv.Internal

  INTERNAL IMPLEMENTATION UNIT - applications should not use this unit directly.

  Implements the CSV codec: lexer, writer, table projection and contract
  engine.
  Exposed through the public facade PascalForge.Csv (TCsvSerializer).

  Registration
    Format registration lives in PascalForge.Csv.Registration and is explicit.

  Documentation
    docs/formats/csv.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Csv.Internal;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  The CSV codec: a lexer, a writer, a projection and a contract engine.

  FOUR LAYERS, and they only know about the one below them.

  1  TCsvLexer / TCsvTextWriter  characters and cells. This layer knows about
     delimiters, quotes, the doubled-quote escape and line terminators, and
     nothing whatever about Delphi types.

  2  TCsvTable                   a header and rows of text, with the
     duplicate-header and ragged-row policies applied.

  3  TCsvBuffer                  a table under construction: columns
     discovered in order, cells addressed by name. EVERY projection lands
     here and the header is rendered from it at the end, which is what makes
     NumberedColumns possible without ever mutating a header mid-stream.

  4  TCsvEngine                  the RTTI walk and the dynamic-tree walk,
     each of which fills buffers.

  THE TWO WALKS ARE SEPARATE ON PURPOSE. The contract walk reads a Delphi
  value and writes cells; the structural walk reads a dynamic tree and writes
  cells. Routing the contract path through the tree would make this a bridge
  rather than a codec, and would lose every distinction the tree does not
  carry - which for a tabular destination is most of them.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo, System.Math, System.StrUtils,
  System.SyncObjs, System.DateUtils, System.Generics.Collections,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Serialization.Internal,
  PascalForge.Csv;

type
  { ===========================================================================
    1. LEXER AND WRITER
    =========================================================================== }

  TCsvLexer = record
  public
    { Every row of the document, as raw cells. A trailing line terminator
      does not produce an empty final row; a blank line in the middle does
      produce a row of one empty cell, because that is what it is. }
    class function Split(const AText: string;
      const AOptions: TCsvOptions): TArray<TArray<string>>; static;
  end;

  TCsvTextWriter = record
  public
    class function Quote(const AValue: string;
      const AOptions: TCsvOptions): string; static;
    class function Line(const AValues: TArray<string>;
      const AOptions: TCsvOptions): string; static;
  end;

  { ===========================================================================
    2. A PARSED TABLE
    =========================================================================== }

  TCsvTable = class
  strict private
    FHasHeader: Boolean;
    FHeader: TArray<string>;
    FRows: TList<TArray<string>>;
    FIndex: TDictionary<string, Integer>;
    FWidth: Integer;
    function GetRow(AIndex: Integer): TArray<string>;
    function GetRowCount: Integer;
  public
    constructor Create(AHasHeader: Boolean);
    destructor Destroy; override;

    { Applies the duplicate-header policy. }
    procedure SetHeader(const AHeader: TArray<string>;
      const AOptions: TCsvOptions);
    { Applies the ragged-row policy. ARowNumber is one-based and appears in
      the error message, so it is the line a person would look at. }
    procedure AddRow(const ARow: TArray<string>; ARowNumber: Integer;
      const AOptions: TCsvOptions);

    property HasHeader: Boolean read FHasHeader;
    property Header: TArray<string> read FHeader;
    property Width: Integer read FWidth;
    property RowCount: Integer read GetRowCount;
    property Rows[AIndex: Integer]: TArray<string> read GetRow; default;

    function IndexOfColumn(const AName: string): Integer;
    function HasColumn(const AName: string): Boolean;
    function CellAt(ARow, AColumn: Integer): string;
    function TryCell(ARow: Integer; const AName: string;
      out AText: string): Boolean;
    { The cell, or '' when the column is not in this table. }
    function Cell(ARow: Integer; const AName: string): string;
    { Columns whose name starts with APrefix. }
    function ColumnsStartingWith(const APrefix: string): TArray<string>;
  end;

  { ===========================================================================
    3. A TABLE UNDER CONSTRUCTION
    =========================================================================== }

  TCsvCell = record
  public
    Text: string;
    IsNull: Boolean;
    class function Value(const AText: string): TCsvCell; static;
    class function Null: TCsvCell; static;
  end;

  TCsvBuffer = class
  strict private
    FName: string;
    FColumns: TList<string>;
    FIndex: TDictionary<string, Integer>;
    FRows: TList<TArray<TCsvCell>>;
    function GetColumn(AIndex: Integer): string;
    function GetColumnCount: Integer;
    function GetRowCount: Integer;
  public
    constructor Create(const AName: string);
    destructor Destroy; override;

    { The column's index, adding it at the end when it is new. Discovery
      order IS column order, which is why a flattened object's columns come
      out in member order and Orders[1] comes out after Orders[0]. }
    function ColumnOf(const AName: string): Integer;
    function IndexOfColumn(const AName: string): Integer;
    function NewRow: Integer;
    { A copy of ARow, appended. RepeatedRows is exactly this. }
    function CloneRow(ARow: Integer): Integer;
    procedure SetCell(ARow: Integer; const AColumn: string;
      const ACell: TCsvCell);
    function GetCell(ARow: Integer; const AColumn: string): TCsvCell;

    property Name: string read FName write FName;
    property ColumnCount: Integer read GetColumnCount;
    property Columns[AIndex: Integer]: string read GetColumn;
    property RowCount: Integer read GetRowCount;

    { The CSV text. The header is written here, once, from the columns the
      whole source turned out to need. }
    function Render(const AOptions: TCsvOptions): string;
  end;

  { ===========================================================================
    4. THE CONTRACT PLAN
    =========================================================================== }

  TCsvMemberKind = (
    Unsupported, CustomSerializer,
    StrValue, IntValue, Int64Value, FloatValue, CurrencyValue, BoolValue,
    EnumValue, SetValue, GuidValue, DateValue, TimeValue, DateTimeValue,
    BytesValue, NullableValue,
    RecordValue, ObjectValue, ListValue, ArrayValue,
    { A map. Its own kind rather than an ObjectValue, because a dictionary's
      published members are TList, TArray and a comparer - walking those as
      if they were the data reads the container's private layout, which is
      how this reached an invalid pointer before the kind existed. }
    DictionaryValue);

  TCsvTypePlan = class;

  TCsvMemberPlan = class
  public
    TypeInfo: PTypeInfo;
    Kind: TCsvMemberKind;
    { Nullable: the plan for the value inside. }
    Inner: TCsvMemberPlan;
    { List and array: the plan for one element. }
    Item: TCsvMemberPlan;
    { Record and class: the fields. Owned by the engine's plan cache, not by
      this member. }
    BoundPlan: TCsvTypePlan;
    NullableAccess: TNullableAccess;
    DatePattern: string;
    SetElemTypeInfo: PTypeInfo;
    { Enumeration: the text of each value, from [SerializationEnum], or nil
      for the Delphi names. CSV has no mapping registration of its own. }
    EnumMapping: TArray<string>;
    Serializer: TCustomCsvCellSerializer;
    ContainerCreate: TRttiMethod;
    ContainerClear: TRttiMethod;
    ContainerAdd: TRttiMethod;
    ContainerToArray: TRttiMethod;
    destructor Destroy; override;
    function IsScalar: Boolean;
    function IsCollection: Boolean;
    function IsComposite: Boolean;
  end;

  TCsvFieldPlan = class
  public
    Name: string;
    DelphiName: string;
    DeclaringTypeName: string;
    Field: TRttiField;
    Prop: TRttiProperty;
    Writable: Boolean;
    IsKey: Boolean;
    Member: TCsvMemberPlan;
    destructor Destroy; override;
  end;

  TCsvTypePlan = class
  public
    TypeInfo: PTypeInfo;
    RttiType: TRttiType;
    IsRecord: Boolean;
    ClassType: TClass;
    ZeroConstructor: TRttiMethod;
    TypeKey: string;
    UnitName: string;
    TableName: string;
    Fields: TObjectList<TCsvFieldPlan>;
    constructor Create;
    destructor Destroy; override;
    function KeyField: TCsvFieldPlan;
  end;

  { ===========================================================================
    5. THE ENGINE
    =========================================================================== }

  TCsvEngine = class
  strict private
    class var FCtx: TRttiContext;
    class var FLock: TCriticalSection;
    class var FPlans: TDictionary<PTypeInfo, TCsvTypePlan>;
    class var FRootPlans: TObjectDictionary<PTypeInfo, TCsvMemberPlan>;
    class var FTypeSerializers: TDictionary<PTypeInfo, TCsvCellSerializerClass>;
    class var FSerializerSingletons:
      TObjectDictionary<TClass, TCustomCsvCellSerializer>;
    class var FDatePolicies: TDateTimePolicies;
    class var FDatePatterns: TDictionary<Integer, string>;
    class var FNextPatternId: Integer;
    class var FBuildTrail: TList<PTypeInfo>;
    class var FBuildDepth: Integer;
    class var FFrozen: Boolean;

    class procedure CheckNotFrozen; static;
    class procedure RollbackBuildTrail; static;
    class function ResolveSerializer(
      AClass: TCsvCellSerializerClass): TCustomCsvCellSerializer; static;
    class function ClassifyType(ATypeInfo: PTypeInfo): TCsvMemberKind; static;
    class function BuildMemberPlan(ATypeInfo: PTypeInfo;
      const AOwnerKey, AMemberName: string): TCsvMemberPlan; static;
    class procedure BuildMemberOfType(APlan: TCsvTypePlan;
      AMember: TSerializationMember); static;
    class function BuildPlan(ATypeInfo: PTypeInfo): TCsvTypePlan; static;
    class function GetPlan(ATypeInfo: PTypeInfo): TCsvTypePlan; static;
    class function GetRootPlan(ATypeInfo: PTypeInfo): TCsvMemberPlan; static;
    class function PatternIdFor(const APattern: string): Integer; static;
    class function PatternOf(AId: Integer): string; static;
  public
    class constructor Create;
    class destructor Destroy;

    { --- the lexical layer, reachable on its own ------------------------- }
    class function ParseTable(const AText: string;
      const AOptions: TCsvOptions): TCsvTable; static;

    { --- the contract path ----------------------------------------------- }
    class function SerializeRoot(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AOptions: TCsvOptions): string; static;
    class function DeserializeRoot(ATypeInfo: PTypeInfo; const AText: string;
      const AOptions: TCsvOptions): TValue; static;
    class function SerializeRootTables(ATypeInfo: PTypeInfo;
      const AValue: TValue; const AOptions: TCsvOptions): TCsvDocumentSet; static;
    class function DeserializeRootTables(ATypeInfo: PTypeInfo;
      ATables: TCsvDocumentSet; const AOptions: TCsvOptions): TValue; static;

    { --- schemas ---------------------------------------------------------- }
    class function InferSchema(const AText: string;
      const AOptions: TCsvOptions): TCsvSchema; static;
    class function SchemaOfType(ATypeInfo: PTypeInfo;
      const AOptions: TCsvOptions): TCsvSchema; static;

    { --- the structural path ---------------------------------------------- }
    class function TextToDynamic(const AText: string;
      const ACsv: TCsvOptions;
      const AOptions: TStructuralConversionOptions): TDynamicValue; static;
    class function DynamicToText(AValue: TDynamicValue;
      const ACsv: TCsvOptions;
      const AOptions: TStructuralConversionOptions): string; static;
    { The same projection into a document set: SeparateTable allowed, a
      root object's tables named after its members. The caller owns it. }
    class function DynamicToTables(AValue: TDynamicValue;
      const ACsv: TCsvOptions): TCsvDocumentSet; static;

    { --- registrations ----------------------------------------------------- }
    class procedure RegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TCsvCellSerializerClass); static;
    class procedure SetDateTimeFormat(ATypeInfo: PTypeInfo;
      const AFieldName, APattern: string); static;
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;
    class procedure ResetConfiguration; static;
  end;

{ The name a headerless document's Nth column is known by, one-based. }
function CsvPositionalColumnName(AIndex: Integer): string;

implementation

var
  GInvariant: TFormatSettings;

const
  CBom = #$FEFF;

function CsvPositionalColumnName(AIndex: Integer): string;
begin
  Result := 'Column' + IntToStr(AIndex + 1);
end;

{ ===========================================================================
  1. LEXER AND WRITER
  =========================================================================== }

class function TCsvLexer.Split(const AText: string;
  const AOptions: TCsvOptions): TArray<TArray<string>>;
var
  Rows: TList<TArray<string>>;
  Row: TList<string>;
  I, Len, RowNumber: Integer;
  Field: string;
  Quoted, Closed: Boolean;
  Delim, Quote: Char;
begin
  Delim := AOptions.Delimiter;
  Quote := AOptions.QuoteChar;
  Rows := TList<TArray<string>>.Create;
  Row := TList<string>.Create;
  try
    I := 1;
    Len := Length(AText);
    { A byte-order mark decoded into text is one character, and it belongs to
      the encoding rather than to the first column's name. }
    if (Len >= 1) and (AText[1] = CBom) then Inc(I);
    if I > Len then Exit(Rows.ToArray);

    RowNumber := 1;
    while True do
    begin
      Field := '';
      Quoted := (I <= Len) and (AText[I] = Quote);
      if Quoted then
      begin
        Inc(I);
        Closed := False;
        while I <= Len do
        begin
          if AText[I] = Quote then
          begin
            { A doubled quote is one literal quote; a single one ends the
              value. This is the whole escape mechanism CSV has. }
            if (I < Len) and (AText[I + 1] = Quote) then
            begin
              Field := Field + Quote;
              Inc(I, 2);
            end
            else
            begin
              Inc(I);
              Closed := True;
              Break;
            end;
          end
          else
          begin
            { A delimiter, a CR and an LF are ordinary characters in here.
              That is the point of the quotes. }
            Field := Field + AText[I];
            Inc(I);
          end;
        end;
        if not Closed then
          raise ECsvInputError.CreateFmt(
            'Row %d: a quoted value is never closed. The document ends ' +
            'inside it, so either a %s is missing or one earlier in the row ' +
            'was meant to be doubled.', [RowNumber, Quote]);
      end
      else
      begin
        while (I <= Len) and (AText[I] <> Delim) and (AText[I] <> #13) and
              (AText[I] <> #10) do
        begin
          Field := Field + AText[I];
          Inc(I);
        end;
        if AOptions.TrimUnquotedValues then Field := Trim(Field);
      end;

      Row.Add(Field);

      if I > Len then
      begin
        Rows.Add(Row.ToArray);
        Break;
      end;
      if AText[I] = Delim then
      begin
        Inc(I);
        Continue;
      end;
      { CRLF, a bare LF and a bare CR all end a row. A producer on another
        platform is not a malformed document. }
      if AText[I] = #13 then
      begin
        Inc(I);
        if (I <= Len) and (AText[I] = #10) then Inc(I);
      end
      else
        Inc(I);
      Rows.Add(Row.ToArray);
      Row.Clear;
      Inc(RowNumber);
      { A terminator at the very end of the document closes the last row and
        does not open an empty one. }
      if I > Len then Break;
    end;
    Result := Rows.ToArray;
  finally
    Row.Free;
    Rows.Free;
  end;
end;

class function TCsvTextWriter.Quote(const AValue: string;
  const AOptions: TCsvOptions): string;
var
  Needs: Boolean;
  I: Integer;
begin
  Needs := AOptions.AlwaysQuote;
  if not Needs then
    for I := 1 to Length(AValue) do
      if (AValue[I] = AOptions.Delimiter) or (AValue[I] = AOptions.QuoteChar) or
         (AValue[I] = #13) or (AValue[I] = #10) then
      begin
        Needs := True;
        Break;
      end;
  { A leading or trailing space survives unquoted under RFC 4180, but not
    under a reader that trims - and this writer cannot know which reader is
    coming, so it quotes and the question does not arise. }
  if not Needs and (AValue <> '') and
     ((AValue[1] = ' ') or (AValue[Length(AValue)] = ' ')) then Needs := True;
  if not Needs then Exit(AValue);
  Result := AOptions.QuoteChar +
    StringReplace(AValue, AOptions.QuoteChar,
      AOptions.QuoteChar + AOptions.QuoteChar, [rfReplaceAll]) +
    AOptions.QuoteChar;
end;

class function TCsvTextWriter.Line(const AValues: TArray<string>;
  const AOptions: TCsvOptions): string;
var
  Builder: TStringBuilder;
  I: Integer;
begin
  Builder := TStringBuilder.Create;
  try
    for I := 0 to Integer(High(AValues)) do
    begin
      if I > 0 then Builder.Append(AOptions.Delimiter);
      Builder.Append(Quote(AValues[I], AOptions));
    end;
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

{ ===========================================================================
  2. A PARSED TABLE
  =========================================================================== }

constructor TCsvTable.Create(AHasHeader: Boolean);
begin
  inherited Create;
  FHasHeader := AHasHeader;
  FRows := TList<TArray<string>>.Create;
  FIndex := TDictionary<string, Integer>.Create;
  FWidth := -1;
end;

destructor TCsvTable.Destroy;
begin
  FIndex.Free;
  FRows.Free;
  inherited Destroy;
end;

procedure TCsvTable.SetHeader(const AHeader: TArray<string>;
  const AOptions: TCsvOptions);
var
  I, Suffix, Existing: Integer;
  Name, Candidate: string;
begin
  SetLength(FHeader, Length(AHeader));
  FIndex.Clear;
  for I := 0 to Integer(High(AHeader)) do
  begin
    Name := AHeader[I];
    if FIndex.TryGetValue(Name, Existing) then
      case AOptions.DuplicateHeaders of
        TCsvDuplicateHeaderPolicy.Error:
          raise ECsvInputError.CreateFmt(
            'The header has two columns called "%s", at positions %d and %d. ' +
            'Which one a lookup by name means is not decidable, so it is ' +
            'refused; choose DuplicateHeaders Rename, UseFirst or UseLast to ' +
            'say what you want.', [Name, Existing + 1, I + 1]);
        TCsvDuplicateHeaderPolicy.Rename:
          begin
            Suffix := 2;
            repeat
              Candidate := Name + '_' + IntToStr(Suffix);
              Inc(Suffix);
            until not FIndex.ContainsKey(Candidate);
            Name := Candidate;
            FIndex.Add(Name, I);
          end;
        TCsvDuplicateHeaderPolicy.UseFirst: ;
        TCsvDuplicateHeaderPolicy.UseLast: FIndex.AddOrSetValue(Name, I);
      end
    else
      FIndex.Add(Name, I);
    FHeader[I] := Name;
  end;
  FWidth := Integer(Length(FHeader));
end;

procedure TCsvTable.AddRow(const ARow: TArray<string>; ARowNumber: Integer;
  const AOptions: TCsvOptions);
var
  Row: TArray<string>;
begin
  Row := ARow;
  if FWidth < 0 then FWidth := Integer(Length(Row));
  if Length(Row) <> FWidth then
    case AOptions.RaggedRows of
      TCsvRaggedRowPolicy.Error:
        raise ECsvInputError.CreateFmt(
          'Row %d has %d values where the table has %d columns. A row that ' +
          'does not line up with its header is refused rather than guessed ' +
          'at; choose RaggedRows PadWithEmpty or Truncate to say what a ' +
          'short or long row means here.',
          [ARowNumber, Length(Row), FWidth]);
      TCsvRaggedRowPolicy.PadWithEmpty:
        if Length(Row) < FWidth then SetLength(Row, FWidth);
      TCsvRaggedRowPolicy.Truncate:
        SetLength(Row, FWidth);
    end;
  FRows.Add(Row);
end;

function TCsvTable.GetRow(AIndex: Integer): TArray<string>;
begin
  Result := FRows[AIndex];
end;

function TCsvTable.GetRowCount: Integer;
begin
  Result := Integer(FRows.Count);
end;

function TCsvTable.IndexOfColumn(const AName: string): Integer;
begin
  if not FIndex.TryGetValue(AName, Result) then Result := -1;
end;

function TCsvTable.HasColumn(const AName: string): Boolean;
begin
  Result := FIndex.ContainsKey(AName);
end;

function TCsvTable.CellAt(ARow, AColumn: Integer): string;
var
  Row: TArray<string>;
begin
  Row := FRows[ARow];
  if (AColumn < 0) or (AColumn > High(Row)) then Exit('');
  Result := Row[AColumn];
end;

function TCsvTable.TryCell(ARow: Integer; const AName: string;
  out AText: string): Boolean;
var
  Column: Integer;
begin
  Column := IndexOfColumn(AName);
  Result := Column >= 0;
  if Result then AText := CellAt(ARow, Column);
end;

function TCsvTable.Cell(ARow: Integer; const AName: string): string;
begin
  if not TryCell(ARow, AName, Result) then Result := '';
end;

function TCsvTable.ColumnsStartingWith(const APrefix: string): TArray<string>;
var
  I, N: Integer;
begin
  SetLength(Result, Length(FHeader));
  N := 0;
  for I := 0 to Integer(High(FHeader)) do
    if (APrefix = '') or
       (Copy(FHeader[I], 1, Length(APrefix)) = APrefix) then
    begin
      Result[N] := FHeader[I];
      Inc(N);
    end;
  SetLength(Result, N);
end;

{ ===========================================================================
  3. A TABLE UNDER CONSTRUCTION
  =========================================================================== }

class function TCsvCell.Value(const AText: string): TCsvCell;
begin
  Result.Text := AText;
  Result.IsNull := False;
end;

class function TCsvCell.Null: TCsvCell;
begin
  Result.Text := '';
  Result.IsNull := True;
end;

constructor TCsvBuffer.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
  FColumns := TList<string>.Create;
  FIndex := TDictionary<string, Integer>.Create;
  FRows := TList<TArray<TCsvCell>>.Create;
end;

destructor TCsvBuffer.Destroy;
begin
  FRows.Free;
  FIndex.Free;
  FColumns.Free;
  inherited Destroy;
end;

function TCsvBuffer.ColumnOf(const AName: string): Integer;
begin
  if FIndex.TryGetValue(AName, Result) then Exit;
  Result := Integer(FColumns.Count);
  FColumns.Add(AName);
  FIndex.Add(AName, Result);
end;

function TCsvBuffer.IndexOfColumn(const AName: string): Integer;
begin
  if not FIndex.TryGetValue(AName, Result) then Result := -1;
end;

function TCsvBuffer.GetColumn(AIndex: Integer): string;
begin
  Result := FColumns[AIndex];
end;

function TCsvBuffer.GetColumnCount: Integer;
begin
  Result := Integer(FColumns.Count);
end;

function TCsvBuffer.GetRowCount: Integer;
begin
  Result := Integer(FRows.Count);
end;

function TCsvBuffer.NewRow: Integer;
var
  Row: TArray<TCsvCell>;
begin
  SetLength(Row, 0);
  Result := Integer(FRows.Count);
  FRows.Add(Row);
end;

function TCsvBuffer.CloneRow(ARow: Integer): Integer;
var
  Row, Copy: TArray<TCsvCell>;
  I: Integer;
begin
  Row := FRows[ARow];
  SetLength(Copy, Length(Row));
  for I := 0 to Integer(High(Row)) do Copy[I] := Row[I];
  Result := Integer(FRows.Count);
  FRows.Add(Copy);
end;

procedure TCsvBuffer.SetCell(ARow: Integer; const AColumn: string;
  const ACell: TCsvCell);
var
  Column: Integer;
  Row: TArray<TCsvCell>;
begin
  Column := ColumnOf(AColumn);
  Row := FRows[ARow];
  if Length(Row) <= Column then SetLength(Row, Column + 1);
  Row[Column] := ACell;
  FRows[ARow] := Row;
end;

function TCsvBuffer.GetCell(ARow: Integer; const AColumn: string): TCsvCell;
var
  Column: Integer;
  Row: TArray<TCsvCell>;
begin
  Result := TCsvCell.Value('');
  Column := IndexOfColumn(AColumn);
  if Column < 0 then Exit;
  Row := FRows[ARow];
  if Column > High(Row) then Exit;
  Result := Row[Column];
end;

function TCsvBuffer.Render(const AOptions: TCsvOptions): string;
var
  Builder: TStringBuilder;
  Line: TArray<string>;
  Row: TArray<TCsvCell>;
  R, C: Integer;
  Cell: TCsvCell;
begin
  Builder := TStringBuilder.Create;
  try
    if AOptions.WriteBom then Builder.Append(CBom);
    if AOptions.HasHeader then
    begin
      Builder.Append(TCsvTextWriter.Line(FColumns.ToArray, AOptions));
      Builder.Append(AOptions.NewLineText);
    end;
    SetLength(Line, FColumns.Count);
    for R := 0 to Integer(FRows.Count - 1) do
    begin
      Row := FRows[R];
      for C := 0 to Integer(FColumns.Count - 1) do
      begin
        if C <= High(Row) then Cell := Row[C]
        else Cell := TCsvCell.Value('');
        if Cell.IsNull and (AOptions.NullPolicy = TCsvNullPolicy.Literal) then
          Line[C] := AOptions.NullLiteral
        else
          Line[C] := Cell.Text;
      end;
      Builder.Append(TCsvTextWriter.Line(Line, AOptions));
      Builder.Append(AOptions.NewLineText);
    end;
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

{ ===========================================================================
  SCALAR TEXT

  One place where a Delphi scalar becomes a cell and a cell becomes a Delphi
  scalar. Everything here is invariant: a CSV file written on a machine whose
  decimal separator is a comma has to read on one whose separator is a point,
  and the only way to guarantee that is never to ask the machine.
  =========================================================================== }

function IsDigits(const AText: string; AFrom, ACount: Integer;
  out AValue: Integer): Boolean;
var
  I: Integer;
begin
  AValue := 0;
  if AFrom + ACount - 1 > Length(AText) then Exit(False);
  for I := AFrom to AFrom + ACount - 1 do
  begin
    if not CharInSet(AText[I], ['0'..'9']) then Exit(False);
    AValue := AValue * 10 + (Ord(AText[I]) - Ord('0'));
  end;
  Result := True;
end;

{ ISO 8601 as this library spells it: a date, a time, or a date and a time
  joined by T or a space. Deliberately not a general ISO parser - no time
  zone offsets, because the dynamic tree and TDateTime both hold a bare local
  value and applying an offset would make the result depend on where the
  conversion ran. }
function TryParseIsoDateTime(const AText: string; out AValue: TDateTime): Boolean;
var
  Text: string;
  Y, M, D, H, N, S, Z, Pos: Integer;
  DatePart, TimePart: TDateTime;
  HasDate, HasTime: Boolean;
begin
  AValue := 0;
  Text := Trim(AText);
  if Text = '' then Exit(False);
  HasDate := False;
  HasTime := False;
  DatePart := 0;
  TimePart := 0;
  Pos := 1;
  if (Length(Text) >= 10) and (Text[5] = '-') and (Text[8] = '-') then
  begin
    if not IsDigits(Text, 1, 4, Y) then Exit(False);
    if not IsDigits(Text, 6, 2, M) then Exit(False);
    if not IsDigits(Text, 9, 2, D) then Exit(False);
    if not TryEncodeDate(Word(Y), Word(M), Word(D), DatePart) then Exit(False);
    HasDate := True;
    Pos := 11;
    if Pos <= Length(Text) then
    begin
      if not CharInSet(Text[Pos], ['T', 't', ' ']) then Exit(False);
      Inc(Pos);
    end;
  end;
  if Pos <= Length(Text) then
  begin
    if not IsDigits(Text, Pos, 2, H) then Exit(False);
    if (Pos + 2 > Length(Text)) or (Text[Pos + 2] <> ':') then Exit(False);
    if not IsDigits(Text, Pos + 3, 2, N) then Exit(False);
    S := 0;
    Z := 0;
    Inc(Pos, 5);
    if (Pos <= Length(Text)) and (Text[Pos] = ':') then
    begin
      if not IsDigits(Text, Pos + 1, 2, S) then Exit(False);
      Inc(Pos, 3);
      if (Pos <= Length(Text)) and (Text[Pos] = '.') then
      begin
        if not IsDigits(Text, Pos + 1, 3, Z) then Exit(False);
        Inc(Pos, 4);
      end;
    end;
    if Pos <= Length(Text) then Exit(False);
    if not TryEncodeTime(Word(H), Word(N), Word(S), Word(Z), TimePart) then Exit(False);
    HasTime := True;
  end;
  if not (HasDate or HasTime) then Exit(False);
  { Composed, not added: before 1899-12-30 the day is negative and its time
    of day is subtracted, so DatePart + TimePart landed on the next day. }
  if HasDate and HasTime then
    AValue := TStructuralText.ComposeDateTime(DatePart, TimePart)
  else if HasDate then AValue := DatePart
  else AValue := TimePart;
  Result := True;
end;

{ A date outside the years 1 to 9999 is refused before it is formatted:
  FormatDateTime writes one before year 1 as 0000-00-00 and one after 9999
  with five digits, and the reader refuses both. A time of day alone is
  always in range. }
function FormatDateCell(AValue: TDateTime; AKind: TCsvMemberKind;
  const APattern: string): string;
begin
  if APattern <> '' then
  begin
    TStructuralText.CheckDateTime(AValue);
    Exit(FormatDateTime(APattern, AValue, GInvariant));
  end;
  case AKind of
    TCsvMemberKind.DateValue:
      begin
        TStructuralText.CheckDateTime(AValue);
        Result := FormatDateTime('yyyy-mm-dd', AValue, GInvariant);
      end;
    TCsvMemberKind.TimeValue:
      Result := FormatDateTime('hh:nn:ss.zzz', AValue, GInvariant);
  else
    Result := TStructuralText.EncodeDateTime(AValue);
  end;
end;

function ParseDateCell(const AText: string; const APattern: string;
  out AValue: TDateTime): Boolean;
begin
  if APattern <> '' then
  begin
    if TStructuralText.TryDecodePattern(AText, APattern, AValue) then Exit(True);
    { A column written under one pattern and read under another is a real
      mistake worth catching, but ISO is what everything else in this library
      writes, so it is tried as well rather than refused on principle. }
  end;
  Result := TryParseIsoDateTime(AText, AValue);
end;

{ The shortest decimal that reads back as the same value - FloatToStr's
  fifteen digits did not - with the three special values spelled as XML
  Schema spells them, which is also what a spreadsheet shows. }
function FormatFloatCell(AValue: Double; ASingle: Boolean = False): string;
begin
  if AValue.IsNan then Exit('NaN');
  if AValue.IsPositiveInfinity then Exit('INF');
  if AValue.IsNegativeInfinity then Exit('-INF');
  if ASingle then Result := TStructuralText.EncodeSingle(AValue)
  else Result := TStructuralText.EncodeFloat(AValue);
end;

function TryParseFloatCell(const AText: string; out AValue: Double): Boolean;
begin
  Result := True;
  if AText = 'NaN' then AValue := Double.NaN
  else if (AText = 'INF') or (AText = '+INF') then AValue := Double.PositiveInfinity
  else if AText = '-INF' then AValue := Double.NegativeInfinity
  { Correctly rounded on both platforms: on Win64 TryStrToFloat misread
    about a third of the 17-digit texts that name a Double. }
  else Result := TStructuralText.TryParseFloat(AText, AValue);
end;

{ ===========================================================================
  INFERENCE

  What the SPELLING of a value supports, and nothing more. Every rule here is
  a refusal as much as a permission: the reason '00123' stays a string is
  that the zeros may be a part number, an account or a postal code, and there
  is no way to tell from the document which it is.
  =========================================================================== }

type
  TCsvInferred = record
    ColumnType: TCsvColumnType;
    Nullable: Boolean;
  end;

function LooksLikePlainInteger(const AText: string; AAllowSloppy: Boolean): Boolean;
var
  I, Start: Integer;
begin
  if AText = '' then Exit(False);
  Start := 1;
  if CharInSet(AText[1], ['-', '+']) then
  begin
    if (AText[1] = '+') and not AAllowSloppy then Exit(False);
    Start := 2;
  end;
  if Start > Length(AText) then Exit(False);
  for I := Start to Length(AText) do
    if not CharInSet(AText[I], ['0'..'9']) then Exit(False);
  if AAllowSloppy then Exit(True);
  { A leading zero is information. '007' is not the number seven in any
    document that bothered to write it that way. }
  Result := (AText[Start] <> '0') or (Length(AText) - Start = 0);
end;

function LooksLikePlainFloat(const AText: string; AAllowSloppy: Boolean): Boolean;
var
  I, Start, Dot, Exponent: Integer;
begin
  if AText = '' then Exit(False);
  Start := 1;
  if CharInSet(AText[1], ['-', '+']) then
  begin
    if (AText[1] = '+') and not AAllowSloppy then Exit(False);
    Start := 2;
  end;
  Dot := 0;
  Exponent := 0;
  I := Start;
  while I <= Length(AText) do
  begin
    if AText[I] = '.' then
    begin
      if (Dot > 0) or (Exponent > 0) then Exit(False);
      Dot := I;
    end
    else if CharInSet(AText[I], ['e', 'E']) then
    begin
      if (Exponent > 0) or (I = Start) then Exit(False);
      Exponent := I;
      if (I < Length(AText)) and CharInSet(AText[I + 1], ['-', '+']) then Inc(I);
    end
    else if not CharInSet(AText[I], ['0'..'9']) then Exit(False);
    Inc(I);
  end;
  if Dot = 0 then
  begin
    { An exponent with no point is a number, but it is also how a spreadsheet
      mangles a product code, so Conservative leaves it alone. }
    if not AAllowSloppy then Exit(False);
    if Exponent = 0 then Exit(False);
  end
  else
  begin
    if Dot = Start then Exit(False);
    if Dot = Length(AText) then Exit(False);
  end;
  if not AAllowSloppy and (AText[Start] = '0') and (Dot > Start + 1) then
    Exit(False);
  Result := True;
end;

function LooksLikeGuid(const AText: string): Boolean;
var
  I: Integer;
  Body: string;
begin
  Body := AText;
  if (Length(Body) = 38) and (Body[1] = '{') and (Body[38] = '}') then
    Body := Copy(Body, 2, 36);
  if Length(Body) <> 36 then Exit(False);
  for I := 1 to 36 do
    if I in [9, 14, 19, 24] then
    begin
      if Body[I] <> '-' then Exit(False);
    end
    else if not CharInSet(Body[I], ['0'..'9', 'a'..'f', 'A'..'F']) then
      Exit(False);
  Result := True;
end;

function LooksLikeBase64(const AText: string): Boolean;
var
  Bytes: TBytes;
begin
  { Length is the cheap half of the test and it rejects most words. }
  if (AText = '') or (Length(AText) mod 4 <> 0) then Exit(False);
  Result := TStructuralText.TryDecodeBinary(AText, Bytes);
end;

function WidenColumn(A, B: TCsvColumnType): TCsvColumnType;
begin
  if A = B then Exit(A);
  { The lattice, and it only goes one way: a column that has held two
    incompatible spellings is text, because text is the only type that can
    hold both without changing either. }
  if (A = TCsvColumnType.Int32) and (B = TCsvColumnType.Int64) then
    Exit(TCsvColumnType.Int64);
  if (A = TCsvColumnType.Int64) and (B = TCsvColumnType.Int32) then
    Exit(TCsvColumnType.Int64);
  if (A in [TCsvColumnType.Int32, TCsvColumnType.Int64]) and
     (B = TCsvColumnType.Float) then Exit(TCsvColumnType.Float);
  if (A = TCsvColumnType.Float) and
     (B in [TCsvColumnType.Int32, TCsvColumnType.Int64]) then
    Exit(TCsvColumnType.Float);
  Result := TCsvColumnType.Str;
end;

function InferOne(const AText: string;
  APolicy: TCsvSchemaInferencePolicy): TCsvColumnType;
var
  Sloppy: Boolean;
  I64: Int64;
  DT: TDateTime;
begin
  if APolicy = TCsvSchemaInferencePolicy.StringsOnly then
    Exit(TCsvColumnType.Str);
  Sloppy := APolicy in [TCsvSchemaInferencePolicy.Numeric,
    TCsvSchemaInferencePolicy.Extended];

  { Unambiguous, and only unambiguous. '1' and '0' are numbers that a great
    many documents also use as flags, and 'yes' is a word; deciding either
    way on a caller's behalf would change their data. }
  if SameText(AText, 'true') or SameText(AText, 'false') then
    Exit(TCsvColumnType.Boolean);

  if LooksLikePlainInteger(AText, Sloppy) and
     TryStrToInt64(AText, I64) then
  begin
    if (I64 >= Low(Integer)) and (I64 <= High(Integer)) then
      Exit(TCsvColumnType.Int32);
    Exit(TCsvColumnType.Int64);
  end;

  if LooksLikePlainFloat(AText, Sloppy) then Exit(TCsvColumnType.Float);

  if APolicy = TCsvSchemaInferencePolicy.Extended then
  begin
    if TryParseIsoDateTime(AText, DT) then Exit(TCsvColumnType.DateTime);
    if LooksLikeGuid(AText) then Exit(TCsvColumnType.Guid);
    if LooksLikeBase64(AText) then Exit(TCsvColumnType.Binary);
  end;

  Result := TCsvColumnType.Str;
end;

function IsNullCell(const AText: string; const AOptions: TCsvOptions): Boolean;
begin
  case AOptions.NullPolicy of
    TCsvNullPolicy.EmptyField: Result := AText = '';
    TCsvNullPolicy.Literal: Result := AText = AOptions.NullLiteral;
  else
    Result := False;
  end;
end;

function InferColumn(ATable: TCsvTable; AColumn: Integer;
  const AOptions: TCsvOptions): TCsvInferred;
var
  R: Integer;
  Text: string;
  Seen: Boolean;
  This: TCsvColumnType;
begin
  Result.ColumnType := TCsvColumnType.Str;
  Result.Nullable := False;
  Seen := False;
  for R := 0 to ATable.RowCount - 1 do
  begin
    Text := ATable.CellAt(R, AColumn);
    if IsNullCell(Text, AOptions) then
    begin
      Result.Nullable := True;
      Continue;
    end;
    This := InferOne(Text, AOptions.SchemaInference);
    if not Seen then
    begin
      Result.ColumnType := This;
      Seen := True;
    end
    else
      Result.ColumnType := WidenColumn(Result.ColumnType, This);
  end;
  { A column that held nothing but nulls says nothing about its type. }
  if not Seen then Result.ColumnType := TCsvColumnType.Str;
end;

{ ===========================================================================
  PLANS
  =========================================================================== }

destructor TCsvMemberPlan.Destroy;
begin
  Inner.Free;
  Item.Free;
  inherited Destroy;
end;

function TCsvMemberPlan.IsScalar: Boolean;
begin
  Result := Kind in [TCsvMemberKind.CustomSerializer, TCsvMemberKind.StrValue,
    TCsvMemberKind.IntValue, TCsvMemberKind.Int64Value,
    TCsvMemberKind.FloatValue, TCsvMemberKind.CurrencyValue,
    TCsvMemberKind.BoolValue, TCsvMemberKind.EnumValue,
    TCsvMemberKind.SetValue, TCsvMemberKind.GuidValue,
    TCsvMemberKind.DateValue, TCsvMemberKind.TimeValue,
    TCsvMemberKind.DateTimeValue, TCsvMemberKind.BytesValue];
end;

function TCsvMemberPlan.IsCollection: Boolean;
begin
  Result := Kind in [TCsvMemberKind.ListValue, TCsvMemberKind.ArrayValue];
end;

function TCsvMemberPlan.IsComposite: Boolean;
begin
  Result := Kind in [TCsvMemberKind.RecordValue, TCsvMemberKind.ObjectValue];
end;

destructor TCsvFieldPlan.Destroy;
begin
  Member.Free;
  inherited Destroy;
end;

constructor TCsvTypePlan.Create;
begin
  inherited Create;
  Fields := TObjectList<TCsvFieldPlan>.Create(True);
end;

destructor TCsvTypePlan.Destroy;
begin
  Fields.Free;
  inherited Destroy;
end;

function TCsvTypePlan.KeyField: TCsvFieldPlan;
var
  FP: TCsvFieldPlan;
begin
  for FP in Fields do
    if FP.IsKey then Exit(FP);
  Result := nil;
end;

{ ===========================================================================
  THE ENGINE - construction and plan building
  =========================================================================== }

class constructor TCsvEngine.Create;
begin
  FCtx := TRttiContext.Create;
  FLock := TCriticalSection.Create;
  FPlans := TDictionary<PTypeInfo, TCsvTypePlan>.Create;
  FRootPlans := TObjectDictionary<PTypeInfo, TCsvMemberPlan>.Create([doOwnsValues]);
  FTypeSerializers := TDictionary<PTypeInfo, TCsvCellSerializerClass>.Create;
  FSerializerSingletons :=
    TObjectDictionary<TClass, TCustomCsvCellSerializer>.Create([doOwnsValues]);
  FDatePatterns := TDictionary<Integer, string>.Create;
  FNextPatternId := 1;
  { Kind zero is "no pattern", which means ISO 8601 - what every other text
    format in this library writes, and what a consumer of a CSV column of
    timestamps is most likely to be able to parse. }
  FDatePolicies := TDateTimePolicies.Create(TDateTimePolicy.Make(0));
  FBuildTrail := TList<PTypeInfo>.Create;
end;

class destructor TCsvEngine.Destroy;
var
  P: TCsvTypePlan;
begin
  for P in FPlans.Values do P.Free;
  FPlans.Free;
  FRootPlans.Free;
  FBuildTrail.Free;
  FDatePolicies.Free;
  FDatePatterns.Free;
  FSerializerSingletons.Free;
  FTypeSerializers.Free;
  FLock.Free;
  FCtx.Free;
end;

class procedure TCsvEngine.CheckNotFrozen;
begin
  if FFrozen then
    raise ECsvInternalError.Create(
      'CSV configuration is frozen. A registration has to happen before the ' +
      'type it affects is first used, because a plan is cached at that ' +
      'moment; afterwards it would be a silent no-op.');
end;

class procedure TCsvEngine.RollbackBuildTrail;
var
  TI: PTypeInfo;
  P: TCsvTypePlan;
begin
  for TI in FBuildTrail do
    if FPlans.TryGetValue(TI, P) then
    begin
      FPlans.Remove(TI);
      P.Free;
    end;
  FBuildTrail.Clear;
end;

class function TCsvEngine.ResolveSerializer(
  AClass: TCsvCellSerializerClass): TCustomCsvCellSerializer;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  if AClass = nil then Exit(nil);
  if not FSerializerSingletons.TryGetValue(AClass, Result) then
  begin
    Result := AClass.Create;
    FSerializerSingletons.Add(AClass, Result);
  end;
end;

class function TCsvEngine.PatternIdFor(const APattern: string): Integer;
var
  Pair: TPair<Integer, string>;
begin
  if APattern = '' then Exit(0);
  for Pair in FDatePatterns do
    if Pair.Value = APattern then Exit(Pair.Key);
  Result := FNextPatternId;
  Inc(FNextPatternId);
  FDatePatterns.Add(Result, APattern);
end;

class function TCsvEngine.PatternOf(AId: Integer): string;
begin
  if (AId = 0) or not FDatePatterns.TryGetValue(AId, Result) then Result := '';
end;

class function TCsvEngine.ClassifyType(ATypeInfo: PTypeInfo): TCsvMemberKind;
var
  Access: TNullableAccess;
begin
  if ATypeInfo = nil then Exit(TCsvMemberKind.Unsupported);
  if FTypeSerializers.ContainsKey(ATypeInfo) then
    Exit(TCsvMemberKind.CustomSerializer);
  if ATypeInfo = System.TypeInfo(TGUID) then Exit(TCsvMemberKind.GuidValue);
  if ATypeInfo = System.TypeInfo(TDate) then Exit(TCsvMemberKind.DateValue);
  if ATypeInfo = System.TypeInfo(TTime) then Exit(TCsvMemberKind.TimeValue);
  if ATypeInfo = System.TypeInfo(TDateTime) then
    Exit(TCsvMemberKind.DateTimeValue);
  if ATypeInfo = System.TypeInfo(TBytes) then Exit(TCsvMemberKind.BytesValue);
  if TSerializationTypes.TryGetNullableAccess(ATypeInfo, Access) then
    Exit(TCsvMemberKind.NullableValue);

  case ATypeInfo.Kind of
    tkInteger: Result := TCsvMemberKind.IntValue;
    tkInt64: Result := TCsvMemberKind.Int64Value;
    tkFloat:
      { Comp is a 64-bit integer RTTI files under tkFloat. }
      if GetTypeData(ATypeInfo).FloatType = ftCurr then
        Result := TCsvMemberKind.CurrencyValue
      else if GetTypeData(ATypeInfo).FloatType = ftComp then
        Result := TCsvMemberKind.Int64Value
      else
        Result := TCsvMemberKind.FloatValue;
    tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
      Result := TCsvMemberKind.StrValue;
    tkEnumeration:
      if (ATypeInfo = System.TypeInfo(Boolean)) or
         (ATypeInfo = System.TypeInfo(ByteBool)) or
         (ATypeInfo = System.TypeInfo(WordBool)) or
         (ATypeInfo = System.TypeInfo(LongBool)) then
        Result := TCsvMemberKind.BoolValue
      else
        Result := TCsvMemberKind.EnumValue;
    tkSet: Result := TCsvMemberKind.SetValue;
    tkRecord, tkMRecord: Result := TCsvMemberKind.RecordValue;
    tkDynArray, tkArray: Result := TCsvMemberKind.ArrayValue;
    tkClass:
      { Dictionaries first: TObjectDictionary is not a TList descendant, but
        neither does it share a prefix with one, so the order is what decides
        which test wins for a type that could match both. }
      { The one question, asked in one place - see the note in the JSON
        engine. }
      case TSerializationTypes.ContainerKindOf(ATypeInfo) of
        TContainerKind.Dictionary: Result := TCsvMemberKind.DictionaryValue;
        TContainerKind.List:       Result := TCsvMemberKind.ListValue;
      else
        Result := TCsvMemberKind.ObjectValue;
      end;
  else
    Result := TCsvMemberKind.Unsupported;
  end;
end;

class function TCsvEngine.BuildMemberPlan(ATypeInfo: PTypeInfo;
  const AOwnerKey, AMemberName: string): TCsvMemberPlan;
var
  Why: string;
  ListAccess: TListAccess;
  StaticCount, StaticSize: Integer;
  SerCls: TCsvCellSerializerClass;
  T: TRttiType;
  M: TRttiMethod;
  Params: TArray<TRttiParameter>;
  Policy: TDateTimePolicy;
  Access: TNullableAccess;
  ElemType: PTypeInfo;
begin
  Result := TCsvMemberPlan.Create;
  try
    Result.TypeInfo := ATypeInfo;
    Result.Kind := ClassifyType(ATypeInfo);

    if Result.Kind = TCsvMemberKind.CustomSerializer then
    begin
      FTypeSerializers.TryGetValue(ATypeInfo, SerCls);
      Result.Serializer := ResolveSerializer(SerCls);
      Exit;
    end;

    { A type that cannot be serialized at all is refused here, by name and
      with the remedy - after a registered serializer has had its chance,
      because a caller who registered one has said how. It must not reach
      the scalar writer: a pointer's value written as an integer would be
      read back into a new object's field, and freeing that object would
      free whatever it pointed at. The decision is shared by every format:
      see TSerializationTypes.UnsupportedReason. }
    Why := TSerializationTypes.UnsupportedReason(ATypeInfo);
    if Why <> '' then
      raise ECsvError.CreateFmt(
        '%s %s. Leave it out with [CsvIgnore], or register a CSV ' +
        'type serializer for its type.',
        [MemberDisplayName(AOwnerKey, AMemberName), Why]);
    { A Variant is refused by design: a cell is text with no type of its
      own, so a Variant read back could not know whether it had held the
      number 42 or the text "42". }
    if ATypeInfo.Kind = tkVariant then
      raise ECsvError.CreateFmt(
        '%s is a Variant, and a CSV cell is text with no type of its own to ' +
        'say what one held. Register a CSV type serializer for it, or give ' +
        'the member a declared type.',
        [MemberDisplayName(AOwnerKey, AMemberName)]);

    case Result.Kind of
      TCsvMemberKind.DateValue, TCsvMemberKind.TimeValue,
      TCsvMemberKind.DateTimeValue:
        begin
          Policy := FDatePolicies.Resolve(AOwnerKey, AMemberName);
          Result.DatePattern := PatternOf(Policy.Kind);
        end;

      TCsvMemberKind.SetValue:
        Result.SetElemTypeInfo := ATypeInfo.TypeData.CompType^;

      TCsvMemberKind.EnumValue:
        Result.EnumMapping := TSerializationMetadata.EnumValuesOf(ATypeInfo);

      TCsvMemberKind.NullableValue:
        begin
          if not TSerializationTypes.TryGetNullableAccess(ATypeInfo, Access) then
            raise ECsvInternalError.CreateFmt(
              'Internal: %s was classified as a nullable but its layout ' +
              'cannot be resolved.', [UTF8ToString(ATypeInfo.Name)]);
          Result.NullableAccess := Access;
          Result.Inner := BuildMemberPlan(Access.ValueType, AOwnerKey,
            AMemberName);
        end;

      TCsvMemberKind.ObjectValue, TCsvMemberKind.RecordValue:
        Result.BoundPlan := GetPlan(ATypeInfo);

      TCsvMemberKind.ArrayValue:
        begin
          ElemType := nil;
          if ATypeInfo.Kind = tkArray then
            TSerializationTypes.TryGetStaticArrayShape(ATypeInfo, ElemType,
              StaticCount, StaticSize)
          else if GetTypeData(ATypeInfo).DynArrElType <> nil then
            ElemType := GetTypeData(ATypeInfo).DynArrElType^;
          if ElemType = nil then
            raise ECsvInternalError.CreateFmt(
              'Cannot serialize %s: its element type has no RTTI.',
              [UTF8ToString(ATypeInfo.Name)]);
          Result.Item := BuildMemberPlan(ElemType, AOwnerKey, AMemberName);
        end;

      TCsvMemberKind.ListValue:
        begin
          T := FCtx.GetType(ATypeInfo);
          if T = nil then
            raise ECsvInternalError.CreateFmt(
              'Cannot serialize %s: it exposes no usable RTTI.',
              [UTF8ToString(ATypeInfo.Name)]);
          for M in T.GetMethods do
          begin
            Params := M.GetParameters;
            if M.IsConstructor and (Length(Params) = 0) then
            begin
              if (Result.ContainerCreate = nil) or
                 SameText(Result.ContainerCreate.Parent.Name, 'TObject') then
                Result.ContainerCreate := M;
            end
            else if SameText(M.Name, 'Clear') and (Length(Params) = 0) then
              Result.ContainerClear := M
            else if SameText(M.Name, 'ToArray') and (Length(Params) = 0) then
              Result.ContainerToArray := M
            else if SameText(M.Name, 'Add') and (Length(Params) = 1) then
              Result.ContainerAdd := M;
          end;
          { A list's methods are the ones Core names for its family: a
            TQueue<T> enqueues, a TStack<T> pushes and a TStrings adds a
            line. Looking for a method called Add found nothing for the
            first two, and the members of the container were walked
            instead - its OnNotify event among them. }
          if (Result.Kind = TCsvMemberKind.ListValue) and
             TSerializationTypes.TryGetListAccess(ATypeInfo, ListAccess) then
          begin
            Result.ContainerAdd := ListAccess.AddMethod;
            Result.ContainerToArray := ListAccess.ToArrayMethod;
            if ListAccess.ClearMethod <> nil then
              Result.ContainerClear := ListAccess.ClearMethod;
            if ListAccess.CreateMethod <> nil then
              Result.ContainerCreate := ListAccess.CreateMethod;
          end;
          if (Result.ContainerAdd = nil) or (Result.ContainerToArray = nil) then
            raise ECsvInternalError.CreateFmt(
              'Cannot serialize %s: it looks like a collection but has no ' +
              'usable Add/ToArray pair.', [UTF8ToString(ATypeInfo.Name)]);
          Params := Result.ContainerAdd.GetParameters;
          Result.Item := BuildMemberPlan(Params[0].ParamType.Handle, AOwnerKey,
            AMemberName);
        end;

      TCsvMemberKind.Unsupported:
        raise ECsvInternalError.CreateFmt(
          'CSV cannot represent %s (type kind %d). A cell is text: register ' +
          'a custom CSV cell serializer for it, or mark the member ' +
          '[CsvIgnore].', [UTF8ToString(ATypeInfo.Name), Ord(ATypeInfo.Kind)]);
    end;
  except
    Result.Free;
    raise;
  end;
end;

class procedure TCsvEngine.BuildMemberOfType(APlan: TCsvTypePlan;
  AMember: TSerializationMember);
var
  AField: TRttiField;
  AProp: TRttiProperty;
  FP: TCsvFieldPlan;
  Attr: TCustomAttribute;
  Attrs: TArray<TCustomAttribute>;
  MemberType: PTypeInfo;
  MemberName, Pattern: string;
  HasPattern: Boolean;
  SerCls: TCsvCellSerializerClass;
  Target: TCsvMemberPlan;
begin
  AField := AMember.Field;
  AProp := AMember.Prop;
  if AField <> nil then
  begin
    if AField.FieldType = nil then
    begin
      { Ignored deliberately, or refused - never skipped silently. }
      for Attr in AField.GetAttributes do
        if Attr is CsvIgnoreAttribute then Exit;
      raise ECsvError.CreateFmt(
        '%s %s. Leave it out with [CsvIgnore], or register a CSV ' +
        'type serializer for the type that holds it.',
        [AField.Name, TSerializationTypes.UnsupportedReason(nil)]);
    end;
    MemberType := AField.FieldType.Handle;
    MemberName := AField.Name;
    Attrs := AField.GetAttributes;
  end
  else
  begin
    if AProp.PropertyType = nil then Exit;
    MemberType := AProp.PropertyType.Handle;
    MemberName := AProp.Name;
    Attrs := AProp.GetAttributes;
  end;

  for Attr in Attrs do
    if Attr is CsvIgnoreAttribute then Exit;

  FP := TCsvFieldPlan.Create;
  try
    FP.Field := AField;
    FP.Prop := AProp;
    FP.DelphiName := MemberName;
    FP.Name := MemberName;
    { [SerializationName] names it; the format's own name attribute, read
      below, beats it. }
    if AMember.HasGeneralName then FP.Name := AMember.GeneralName;
    FP.Writable := (AField <> nil) or AProp.IsWritable;
    if AField <> nil then FP.DeclaringTypeName := AField.Parent.Name
    else FP.DeclaringTypeName := AProp.Parent.Name;

    SerCls := nil;
    Pattern := '';
    HasPattern := False;
    for Attr in Attrs do
      if Attr is CsvNameAttribute then FP.Name := CsvNameAttribute(Attr).Name
      else if Attr is CsvKeyAttribute then FP.IsKey := True
      else if Attr is CsvSerializerAttribute then
        SerCls := CsvSerializerAttribute(Attr).SerializerClass
      else if Attr is CsvDateTimeFormatAttribute then
      begin
        Pattern := CsvDateTimeFormatAttribute(Attr).Pattern;
        HasPattern := True;
      end;

    if FP.Name = '' then
      raise ECsvInternalError.CreateFmt(
        '%s.%s has an empty CSV column name.',
        [APlan.RttiType.Name, MemberName]);

    if SerCls <> nil then
    begin
      FP.Member := TCsvMemberPlan.Create;
      FP.Member.TypeInfo := MemberType;
      FP.Member.Kind := TCsvMemberKind.CustomSerializer;
      FP.Member.Serializer := ResolveSerializer(SerCls);
    end
    else
      FP.Member := BuildMemberPlan(MemberType, APlan.TypeKey, MemberName);

    { [SerializationEnum] on the member: on the enumeration, or a nullable's
      inner one. }
    if AMember.HasEnumValues then
    begin
      Target := FP.Member;
      if (Target.Kind = TCsvMemberKind.NullableValue) and (Target.Inner <> nil) then
        Target := Target.Inner;
      if Target.Kind = TCsvMemberKind.EnumValue then
        Target.EnumMapping := AMember.EnumValues;
    end;

    { A member attribute beats every registration. On a nullable it applies
      to the inner value, which is the one that has a representation. }
    if HasPattern then
    begin
      Target := FP.Member;
      if (Target.Kind = TCsvMemberKind.NullableValue) and (Target.Inner <> nil) then
        Target := Target.Inner;
      Target.DatePattern := Pattern;
    end;

    APlan.Fields.Add(FP);
    FP := nil;
  finally
    FP.Free;
  end;
end;

class function TCsvEngine.BuildPlan(ATypeInfo: PTypeInfo): TCsvTypePlan;
var
  Registered: Boolean;
  T: TRttiType;
  Attr: TCustomAttribute;
  Member: TSerializationMember;
  FP: TCsvFieldPlan;
  Names: TDictionary<string, string>;
  Existing: string;
begin
  Result := TCsvTypePlan.Create;
  Inc(FBuildDepth);
  try
    Result.TypeInfo := ATypeInfo;
    T := FCtx.GetType(ATypeInfo);
    if T = nil then
      raise ECsvInternalError.CreateFmt(
        'Cannot build a CSV plan for %s: the type exposes no usable RTTI. A ' +
        'type declared inside a routine body has none; declare it at unit ' +
        'scope.', [UTF8ToString(ATypeInfo.Name)]);
    Result.RttiType := T;
    Result.IsRecord := ATypeInfo.Kind in [tkRecord, tkMRecord];
    Result.UnitName := TypeUnitOf(ATypeInfo, '');
    Result.TypeKey := TypeKeyOf(ATypeInfo, Result.UnitName);

    { The table name: the type's own name with a leading T removed, because
      TCustomer is a Delphi convention and 'Customer' is what a file should
      be called. [CsvTable] overrides it. }
    Result.TableName := string(T.Name);
    if (Length(Result.TableName) > 1) and (Result.TableName[1] = 'T') and
       CharInSet(Result.TableName[2], ['A'..'Z']) then
      Result.TableName := Copy(Result.TableName, 2, MaxInt);
    for Attr in T.GetAttributes do
      if Attr is CsvTableAttribute then
        Result.TableName := CsvTableAttribute(Attr).Name;

    if not Result.IsRecord then
    begin
      Result.ClassType := ATypeInfo.TypeData.ClassType;
      Result.ZeroConstructor := TSerializationMetadata.Get(ATypeInfo).DeclaredConstructor;
      if Result.ZeroConstructor = nil then
        Result.ZeroConstructor := TSerializationMetadata.Get(ATypeInfo).TObjectConstructor;
    end;

    FPlans.Add(ATypeInfo, Result);
    FBuildTrail.Add(ATypeInfo);

    { The member surface and the general attributes come from the shared
      metadata. }
    for Member in TSerializationMetadata.Get(ATypeInfo).Members do
      if not Member.Ignored then BuildMemberOfType(Result, Member);

    Names := TDictionary<string, string>.Create;
    try
      for FP in Result.Fields do
        if Names.TryGetValue(LowerCase(FP.Name), Existing) then
          raise ECsvInternalError.CreateFmt(
            'Duplicate CSV column name "%s" in %s: Delphi members %s and %s',
            [FP.Name, UTF8ToString(ATypeInfo.Name), Existing,
             FP.DeclaringTypeName + '.' + FP.DelphiName])
        else
          Names.Add(LowerCase(FP.Name),
            FP.DeclaringTypeName + '.' + FP.DelphiName);
    finally
      Names.Free;
    end;

    Dec(FBuildDepth);
    if FBuildDepth = 0 then FBuildTrail.Clear;
  except
    { WHO OWNS THE HALF-BUILT PLAN is decided BEFORE the rollback runs.
      A plan already registered in FPlans belongs to the build trail, and
      the rollback frees it - at the outermost level now, or later, at the
      level that started the build. A plan that never got that far is
      freed here.

      FPlans is asked BEFORE the rollback: afterwards the rollback has
      removed the plan and freed it, the answer would always be "not
      there", and the plan would be freed a second time - surfacing the
      refusal that caused it as EInvalidPointer instead of as itself. }
    Registered := FPlans.ContainsValue(Result);
    Dec(FBuildDepth);
    if FBuildDepth = 0 then RollbackBuildTrail;
    if not Registered then Result.Free;
    raise;
  end;
end;

{ Lookup and build happen under the engine's lock, together. Without it two
  threads meeting a cold type both built its plan and the second Add raised
  EListError - and a TDictionary read while another thread grows it is not
  defined at all. The lock is re-entrant, so the nested GetPlan calls a
  build makes cost nothing; a built plan is never changed, so what it hands
  back is safe to use outside the lock. }
class function TCsvEngine.GetPlan(ATypeInfo: PTypeInfo): TCsvTypePlan;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  FLock.Acquire;
  try
    if FPlans.TryGetValue(ATypeInfo, Result) then Exit;
    Result := BuildPlan(ATypeInfo);
  finally
    FLock.Release;
  end;
end;

class function TCsvEngine.GetRootPlan(ATypeInfo: PTypeInfo): TCsvMemberPlan;
begin
  { Configuration freezes at first use: plans built from here on
    must not see it change. }
  FFrozen := True;
  FLock.Acquire;
  try
    if FRootPlans.TryGetValue(ATypeInfo, Result) then Exit;
    Result := BuildMemberPlan(ATypeInfo, TypeKeyOf(ATypeInfo), '');
    FRootPlans.Add(ATypeInfo, Result);
  finally
    FLock.Release;
  end;
end;

class procedure TCsvEngine.RegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TCsvCellSerializerClass);
begin
  FLock.Acquire;
  try
    CheckNotFrozen;
    FTypeSerializers.AddOrSetValue(ATypeInfo, ASerializerClass);
  finally
    FLock.Release;
  end;
end;

class procedure TCsvEngine.SetDateTimeFormat(ATypeInfo: PTypeInfo;
  const AFieldName, APattern: string);
var
  Policy: TDateTimePolicy;
begin
  FLock.Acquire;
  try
    CheckNotFrozen;
    Policy := TDateTimePolicy.Make(PatternIdFor(APattern), APattern);
    if ATypeInfo = nil then FDatePolicies.SetGlobal(Policy)
    else if AFieldName = '' then
      FDatePolicies.SetForType(TypeKeyOf(ATypeInfo), Policy)
    else
      FDatePolicies.SetForField(TypeKeyOf(ATypeInfo), AFieldName, Policy);
  finally
    FLock.Release;
  end;
end;

class procedure TCsvEngine.FreezeConfiguration;
begin
  FFrozen := True;
end;

class function TCsvEngine.IsFrozen: Boolean;
begin
  Result := FFrozen;
end;

class procedure TCsvEngine.ResetConfiguration;
var
  P: TCsvTypePlan;
begin
  FLock.Acquire;
  try
    FFrozen := False;
    for P in FPlans.Values do P.Free;
    FPlans.Clear;
    FRootPlans.Clear;
    FTypeSerializers.Clear;
    FSerializerSingletons.Clear;
    FDatePolicies.Reset;
    FDatePatterns.Clear;
    FNextPatternId := 1;
  finally
    FLock.Release;
  end;
end;

class function TCsvEngine.ParseTable(const AText: string;
  const AOptions: TCsvOptions): TCsvTable;
var
  Raw: TArray<TArray<string>>;
  Header: TArray<string>;
  I, First: Integer;
begin
  Raw := TCsvLexer.Split(AText, AOptions);
  Result := TCsvTable.Create(AOptions.HasHeader);
  try
    if Length(Raw) = 0 then
    begin
      if AOptions.HasHeader then Result.SetHeader(nil, AOptions);
      Exit;
    end;
    if AOptions.HasHeader then
    begin
      Result.SetHeader(Raw[0], AOptions);
      First := 1;
    end
    else
    begin
      { Without a header a column still needs a name for anything that looks
        one up, so it gets a positional one. Nothing is written into the
        file; these names exist only in memory. }
      SetLength(Header, Length(Raw[0]));
      for I := 0 to Integer(High(Header)) do Header[I] := CsvPositionalColumnName(I);
      Result.SetHeader(Header, AOptions);
      First := 0;
    end;
    for I := First to Integer(High(Raw)) do
      Result.AddRow(Raw[I], I + 1, AOptions);
  except
    Result.Free;
    raise;
  end;
end;

{ ===========================================================================
  THE CONTRACT WALK
  =========================================================================== }

type
  { One collection member found while a row was being built, held back until
    the row's scalar columns are complete - because RepeatedRows has to copy
    those columns onto every row it produces, and SeparateTable has to know
    the parent's key before it can write a child row. }
  TCsvPendingCollection = record
    Path: string;
    MemberName: string;
    Prefix: string;
    Plan: TCsvMemberPlan;
    Elements: TArray<TValue>;
    { The member as it stands, for the modes that hand the whole thing to
      another format rather than walking its elements. }
    Value: TValue;
    { The writer's level where the member was found - its owner's. The
      collection is written after the owner's walk has returned, so the
      levels between are counted again before it is. }
    Level: Integer;
    { The member is a TNullable holding this collection, present. }
    Nullable: Boolean;
  end;

  TCsvWriteContext = class
  strict private
    FBuffers: TObjectList<TCsvBuffer>;
  public
    Options: TCsvOptions;
    Relationships: TList<TCsvTableRelationship>;
    AllowSeparateTables: Boolean;
    constructor Create(const AOptions: TCsvOptions);
    destructor Destroy; override;
    function NewBuffer(const AName: string): TCsvBuffer;
    function BufferCount: Integer;
    function Buffer(AIndex: Integer): TCsvBuffer;
    function HasBufferNamed(const AName: string): Boolean;
  end;

constructor TCsvWriteContext.Create(const AOptions: TCsvOptions);
begin
  inherited Create;
  Options := AOptions;
  FBuffers := TObjectList<TCsvBuffer>.Create(True);
  Relationships := TList<TCsvTableRelationship>.Create;
end;

destructor TCsvWriteContext.Destroy;
begin
  Relationships.Free;
  FBuffers.Free;
  inherited Destroy;
end;

function TCsvWriteContext.NewBuffer(const AName: string): TCsvBuffer;
begin
  Result := TCsvBuffer.Create(AName);
  FBuffers.Add(Result);
end;

function TCsvWriteContext.BufferCount: Integer;
begin
  Result := Integer(FBuffers.Count);
end;

function TCsvWriteContext.Buffer(AIndex: Integer): TCsvBuffer;
begin
  Result := FBuffers[AIndex];
end;

function TCsvWriteContext.HasBufferNamed(const AName: string): Boolean;
var
  B: TCsvBuffer;
begin
  for B in FBuffers do
    if SameText(B.Name, AName) then Exit(True);
  Result := False;
end;

function JoinPath(const APrefix, AName, ASeparator: string): string;
begin
  if APrefix = '' then Result := AName
  else Result := APrefix + ASeparator + AName;
end;

function MemberPath(const APrefix, AName: string): string;
begin
  if APrefix = '' then Result := AName else Result := APrefix + '.' + AName;
end;

{ ---------------------------------------------------------------------------
  THE TABLE RULES, ONCE

  A Delphi value (walked through its plan) and a structural tree (walked as
  it is) reach the same tables through these: how a child table is named,
  which key joins it, which column in the child holds that key, the
  relationship recorded for it, and how the buffers become a document set.
  The two walks differ only in what they read; what they write is decided
  here.
  --------------------------------------------------------------------------- }

{ The child table a member's rows go into, created and recorded on first use.

  The key is ADeclaredKey when the parent row type declared one ([CsvKey]);
  otherwise RelationshipNaming.GeneratedKeyColumn, filled with the parent's
  row number when the row has no value there - an artefact of this
  projection, and the relationship says so. AKeyCell is the parent row's key
  and ARefColumn the child column that holds it. }
function AttachChildTable(ACtx: TCsvWriteContext; AParent: TCsvBuffer;
  ARow: Integer; const ADeclaredKey, AMemberName, AMemberPath,
  AErrorPath: string; out AKeyCell: TCsvCell;
  out ARefColumn: string): TCsvBuffer;
var
  Rel: TCsvTableRelationship;
  KeyColumn, ChildName: string;
  I: Integer;
begin
  KeyColumn := ADeclaredKey;
  Rel.KeyIsGenerated := KeyColumn = '';
  if Rel.KeyIsGenerated then
    KeyColumn := ACtx.Options.RelationshipNaming.GeneratedKeyColumn;
  AKeyCell := AParent.GetCell(ARow, KeyColumn);
  if AKeyCell.IsNull or (AKeyCell.Text = '') then
  begin
    if not Rel.KeyIsGenerated then
      raise ECsvProjectionError.CreateForPath(AErrorPath,
        Format('%s is the declared key of this row and it is empty, so the ' +
          'child rows would have nothing to point at. Give it a value, or ' +
          'remove [CsvKey] and let one be generated.', [KeyColumn]));
    AKeyCell := TCsvCell.Value(IntToStr(ARow + 1));
    AParent.SetCell(ARow, KeyColumn, AKeyCell);
  end;

  ARefColumn := AParent.Name + '_' + KeyColumn;
  if ACtx.Options.RelationshipNaming.ReferenceColumn <> '' then
    ARefColumn := ACtx.Options.RelationshipNaming.ReferenceColumn;

  ChildName := AParent.Name + '_' + AMemberName;
  for I := 0 to ACtx.BufferCount - 1 do
    if SameText(ACtx.Buffer(I).Name, ChildName) then
      Exit(ACtx.Buffer(I));
  Result := ACtx.NewBuffer(ChildName);
  Rel.ParentTable := AParent.Name;
  Rel.ChildTable := ChildName;
  Rel.MemberPath := AMemberPath;
  Rel.ParentKeyColumn := KeyColumn;
  Rel.ChildReferenceColumn := ARefColumn;
  ACtx.Relationships.Add(Rel);
end;

{ The buffers and relationships of one projection, as the caller's document
  set. The caller owns the result. }
function DocumentSetOf(ACtx: TCsvWriteContext): TCsvDocumentSet;
var
  I: Integer;
  Rel: TCsvTableRelationship;
begin
  Result := TCsvDocumentSet.Create;
  try
    for I := 0 to ACtx.BufferCount - 1 do
      Result.Add(TCsvTableDocument.Make(ACtx.Buffer(I).Name,
        ACtx.Buffer(I).Render(ACtx.Options), ACtx.Buffer(I).RowCount));
    for Rel in ACtx.Relationships do Result.AddRelationship(Rel);
  except
    Result.Free;
    raise;
  end;
end;

{ More than one collection on one row, each with several elements, under
  RepeatedRows: flattening would have to INVENT data, so it is refused unless
  the caller has said in writing that they want the pairings anyway. }
procedure CheckMultiplying(const AOptions: TCsvOptions; AMultiplying: Integer;
  const APath: string);
begin
  if (AMultiplying > 1) and
     (AOptions.MultipleCollections = TCsvMultipleCollections.Error) then
    raise ECsvProjectionError.CreateForPath(APath,
      'This row has more than one collection with several elements, and ' +
      'RepeatedRows would have to multiply them together. N times M rows ' +
      'contains pairings the source never had. Choose ' +
      'MultipleCollections.CartesianProduct to accept them, ' +
      'NumberedColumns or JsonCell to keep one row, or SeparateTable.');
end;


{ --- scalars, both directions ------------------------------------------- }

function EnumTextOf(ATypeInfo: PTypeInfo; AOrdinal: Integer;
  const AMapping: TArray<string>): string;
begin
  { A mapping is indexed by ordinal, as every format's registration is. }
  if (AMapping <> nil) and (AOrdinal >= 0) and (AOrdinal <= High(AMapping)) then
    Exit(AMapping[AOrdinal]);
  Result := GetEnumName(ATypeInfo, AOrdinal);
end;

{ Through TSerializationTypes, which knows that a set's bit 0 is the byte
  holding its lowest member - counting from ordinal 0 wrote 10 as 12 - and
  that a set can be 32 bytes wide, where an Int64 holds eight. }
function SetTextOf(AElemType: PTypeInfo; const AValue: TValue): string;
var
  Ords: TArray<Integer>;
  Names, Mapping: TArray<string>;
  I: Integer;
begin
  { An enumeration's elements through [SerializationEnum]; CSV has no
    mapping registration of its own. }
  Mapping := TSerializationMetadata.EnumValuesOf(AElemType);
  Ords := TSerializationTypes.SetOrdinals(AValue.TypeInfo, AValue);
  SetLength(Names, Length(Ords));
  for I := 0 to Integer(High(Ords)) do
    Names[I] := TSerializationTypes.MappedSetElementText(AElemType, Ords[I],
      Mapping);
  Result := string.Join(',', Names);
end;

procedure SetFromText(AElemType: PTypeInfo; const AText: string;
  var AValue: TValue; ATypeInfo: PTypeInfo);
var
  Parts: TArray<string>;
  Part, Why: string;
  Ordinal: Integer;
  Ords: TArray<Integer>;
  Mapping: TArray<string>;
begin
  Ords := nil;
  Mapping := TSerializationMetadata.EnumValuesOf(AElemType);
  if Trim(AText) <> '' then
  begin
    Parts := AText.Split([',']);
    for Part in Parts do
    begin
      if Trim(Part) = '' then Continue;
      if not TSerializationTypes.TryMappedSetElementOrdinal(AElemType, Trim(Part),
           Mapping, Ordinal) then
        raise ECsvInputError.CreateFmt(
          '"%s" is not a value of %s.', [Trim(Part), UTF8ToString(AElemType.Name)]);
      Ords := Ords + [Ordinal];
    end;
  end;
  if not TSerializationTypes.TryMakeSet(ATypeInfo, Ords, AValue, Why) then
    raise ECsvInputError.CreateFmt('"%s" is not a %s: %s.',
      [AText, UTF8ToString(ATypeInfo.Name), Why]);
end;

function ScalarToCell(APlan: TCsvMemberPlan; const AValue: TValue;
  const AOptions: TCsvOptions; const APath: string): TCsvCell;
var
  Inner: TValue;
begin
  case APlan.Kind of
    TCsvMemberKind.CustomSerializer:
      Exit(TCsvCell.Value(APlan.Serializer.Serialize(AValue)));
    TCsvMemberKind.StrValue: Exit(TCsvCell.Value(AValue.AsString));
    { Digits with the sign the type gives them: AsInt64 on a UInt64 wrote
      18446744073709551615 as -1. }
    TCsvMemberKind.IntValue, TCsvMemberKind.Int64Value:
      Exit(TCsvCell.Value(TSerializationTypes.IntegerText(AValue)));
    TCsvMemberKind.FloatValue:
      Exit(TCsvCell.Value(FormatFloatCell(AValue.AsExtended,
        GetTypeData(APlan.TypeInfo).FloatType = ftSingle)));
    TCsvMemberKind.CurrencyValue:
      Exit(TCsvCell.Value(CurrToStr(AValue.AsCurrency, GInvariant)));
    TCsvMemberKind.BoolValue:
      if AValue.AsOrdinal <> 0 then Exit(TCsvCell.Value('true'))
      else Exit(TCsvCell.Value('false'));
    TCsvMemberKind.EnumValue:
      Exit(TCsvCell.Value(EnumTextOf(APlan.TypeInfo, Integer(AValue.AsOrdinal),
        APlan.EnumMapping)));
    TCsvMemberKind.SetValue:
      Exit(TCsvCell.Value(SetTextOf(APlan.SetElemTypeInfo, AValue)));
    TCsvMemberKind.GuidValue:
      Exit(TCsvCell.Value(
        LowerCase(Copy(GUIDToString(AValue.AsType<TGUID>), 2, 36))));
    TCsvMemberKind.DateValue, TCsvMemberKind.TimeValue,
    TCsvMemberKind.DateTimeValue:
      Exit(TCsvCell.Value(FormatDateCell(AValue.AsType<TDateTime>, APlan.Kind,
        APlan.DatePattern)));
    TCsvMemberKind.BytesValue:
      Exit(TCsvCell.Value(
        TStructuralText.EncodeBinary(AValue.AsType<TBytes>)));
    TCsvMemberKind.NullableValue:
      begin
        if not APlan.NullableAccess.HasValue(AValue.GetReferenceToRawData) then
        begin
          if AOptions.NullPolicy = TCsvNullPolicy.Error then
            raise ECsvProjectionError.CreateForPath(APath, Format(
              'Member %s has no value and NullPolicy is Error. CSV has no ' +
              'null: choose NullPolicy EmptyField to write nothing, or ' +
              'Literal to write "%s".', [APath, AOptions.NullLiteral]));
          Exit(TCsvCell.Null);
        end;
        Inner := APlan.NullableAccess.GetValue(AValue.GetReferenceToRawData);
        Exit(ScalarToCell(APlan.Inner, Inner, AOptions, APath));
      end;
  end;
  raise ECsvProjectionError.CreateForPath(APath,
    Format('CSV cannot write %s as a cell.', [UTF8ToString(APlan.TypeInfo.Name)]));
end;

function CellToScalar(APlan: TCsvMemberPlan; const ACell: TCsvCell;
  const AOptions: TCsvOptions; const APath: string;
  const AExisting: TValue): TValue;
var
  I64: Int64;
  Dbl: Double;
  Cur: Currency;
  DT: TDateTime;
  Bytes: TBytes;
  Ordinal, I: Integer;
  Text, Why: string;
  Inner: TValue;
begin
  Text := ACell.Text;

  if APlan.Kind = TCsvMemberKind.NullableValue then
  begin
    TValue.Make(nil, APlan.TypeInfo, Result);
    if ACell.IsNull or IsNullCell(Text, AOptions) then
    begin
      APlan.NullableAccess.Clear(Result.GetReferenceToRawData);
      Exit;
    end;
    Inner := CellToScalar(APlan.Inner, ACell, AOptions, APath, TValue.Empty);
    APlan.NullableAccess.SetValue(Result.GetReferenceToRawData, Inner);
    Exit;
  end;

  case APlan.Kind of
    TCsvMemberKind.CustomSerializer:
      Exit(APlan.Serializer.Deserialize(Text, APlan.TypeInfo, AExisting));
    { Into the member's own code page, refusing text it cannot hold. }
    TCsvMemberKind.StrValue:
      begin
        if not TSerializationTypes.TryStringFromText(APlan.TypeInfo, Text,
             Result, Why) then
          raise ECsvInputError.CreateFmt('Column %s: %s.', [APath, Why]);
        Exit;
      end;
    { Range-checked against the member's own type, both widths. }
    TCsvMemberKind.IntValue, TCsvMemberKind.Int64Value:
      begin
        if Text = '' then Text := '0';
        if not TSerializationTypes.TryIntegerFromText(APlan.TypeInfo, Text,
             Result) then
          raise ECsvInputError.CreateFmt(
            'Column %s holds "%s", which is not a %s.',
            [APath, Text, UTF8ToString(APlan.TypeInfo.Name)]);
        Exit;
      end;
    TCsvMemberKind.FloatValue:
      begin
        if Text = '' then Dbl := 0
        else if not TryParseFloatCell(Text, Dbl) then
          raise ECsvInputError.CreateFmt(
            'Column %s holds "%s", which is not a number. CSV numbers are ' +
            'written with a point, whatever the machine''s own separator is.',
            [APath, Text]);
        { Into the member's own width, checked: a Single does not become
          infinity for a number it cannot hold. }
        if not TSerializationTypes.TryFloatFromDouble(APlan.TypeInfo, Dbl,
             Result, Why) then
          raise ECsvInputError.CreateFmt('Column %s: %s.', [APath, Why]);
        Exit;
      end;
    TCsvMemberKind.CurrencyValue:
      begin
        if Text = '' then Cur := 0
        else if not TryStrToCurr(Text, Cur, GInvariant) then
          raise ECsvInputError.CreateFmt(
            'Column %s holds "%s", which is not a currency amount.',
            [APath, Text]);
        Exit(TValue.From<Currency>(Cur));
      end;
    TCsvMemberKind.BoolValue:
      begin
        { The contract already said this is a boolean, so reading is liberal
          where inference is strict: a producer that writes 1 and 0, or Yes
          and No, is not producing an ambiguous document here. }
        if SameText(Text, 'true') or SameText(Text, '1') or
           SameText(Text, 'yes') or SameText(Text, 'y') then
          Exit(TValue.FromOrdinal(APlan.TypeInfo, 1));
        if (Text = '') or SameText(Text, 'false') or SameText(Text, '0') or
           SameText(Text, 'no') or SameText(Text, 'n') then
          Exit(TValue.FromOrdinal(APlan.TypeInfo, 0));
        raise ECsvInputError.CreateFmt(
          'Column %s holds "%s", which is not a boolean.', [APath, Text]);
      end;
    TCsvMemberKind.EnumValue:
      begin
        Ordinal := -1;
        if APlan.EnumMapping <> nil then
        begin
          { A mapped enumeration reads its mapped text only - as the other
            formats do. }
          for I := 0 to Integer(High(APlan.EnumMapping)) do
            if SameText(APlan.EnumMapping[I], Text) then
            begin
              Ordinal := I;
              Break;
            end;
          if Ordinal < 0 then
            raise ECsvInputError.CreateFmt(
              'Column %s holds "%s", which is not a mapped value of %s.',
              [APath, Text, UTF8ToString(APlan.TypeInfo.Name)]);
        end
        else
          Ordinal := GetEnumValue(APlan.TypeInfo, Text);
        if Ordinal < 0 then
        begin
          { An ordinal in digits is accepted - and range-checked, because
            one the type does not have is no value of it. }
          if not TryStrToInt64(Text, I64) or
             (I64 < GetTypeData(APlan.TypeInfo).MinValue) or
             (I64 > GetTypeData(APlan.TypeInfo).MaxValue) then
            raise ECsvInputError.CreateFmt(
              'Column %s holds "%s", which is not a value of %s.',
              [APath, Text, UTF8ToString(APlan.TypeInfo.Name)]);
          Ordinal := Integer(I64);
        end;
        Exit(TValue.FromOrdinal(APlan.TypeInfo, Ordinal));
      end;
    TCsvMemberKind.SetValue:
      begin
        SetFromText(APlan.SetElemTypeInfo, Text, Result, APlan.TypeInfo);
        Exit;
      end;
    TCsvMemberKind.GuidValue:
      begin
        if Text = '' then Exit(TValue.From<TGUID>(TGUID.Empty));
        { A CSV error, not the RTL's EConvertError. }
        try
          if (Length(Text) = 36) then
            Exit(TValue.From<TGUID>(StringToGUID('{' + Text + '}')));
          Exit(TValue.From<TGUID>(StringToGUID(Text)));
        except
          on E: EConvertError do
            raise ECsvInputError.CreateFmt(
              'Column %s holds "%s", which is not a GUID.', [APath, Text]);
        end;
      end;
    TCsvMemberKind.DateValue, TCsvMemberKind.TimeValue,
    TCsvMemberKind.DateTimeValue:
      begin
        if Text = '' then DT := 0
        else if not ParseDateCell(Text, APlan.DatePattern, DT) then
          raise ECsvInputError.CreateFmt(
            'Column %s holds "%s", which is not a date or a time this ' +
            'column can read.', [APath, Text]);
        Exit(TValue.From<TDateTime>(DT).Cast(APlan.TypeInfo));
      end;
    TCsvMemberKind.BytesValue:
      begin
        if Text = '' then Exit(TValue.From<TBytes>(nil));
        if not TStructuralText.TryDecodeBinary(Text, Bytes) then
          raise ECsvInputError.CreateFmt(
            'Column %s holds "%s", which is not base64.', [APath, Text]);
        Exit(TValue.From<TBytes>(Bytes));
      end;
  end;
  raise ECsvProjectionError.CreateForPath(APath,
    Format('CSV cannot read %s from a cell.', [UTF8ToString(APlan.TypeInfo.Name)]));
end;

{ ===========================================================================
  THE ROW WALK

  A table is rows of cells and a Delphi value is a tree, so this is where the
  tree is flattened - and where every decision about HOW is the caller's,
  because there is no flattening that is right for everybody.
  =========================================================================== }

{ Does this member occupy exactly ONE cell?

  A nullable is not a shape of its own - it is a value that may be absent -
  so a nullable Boolean is one cell and a nullable record is not. The plan's
  own IsScalar deliberately answers for the KIND alone, so the question
  "one cell or not" is asked here, once, and every walk below asks it the
  same way. }
function IsOneCell(APlan: TCsvMemberPlan): Boolean;
begin
  if APlan = nil then Exit(False);
  if APlan.IsScalar then Exit(True);
  Result := (APlan.Kind = TCsvMemberKind.NullableValue) and
            (APlan.Inner <> nil) and APlan.Inner.IsScalar;
end;

{ Is this column one of the collection's? Either the column IS the member -
  a scalar collection written one element per row - or it is a member of a
  composite element and therefore carries the collection's name as a prefix. }
function MatchesAnyPrefix(const AName: string; const APrefixes: TArray<string>;
  const ASeparator: string): Boolean;
var
  P: string;
begin
  for P in APrefixes do
    if SameText(AName, P) or
       SameText(Copy(AName, 1, Length(P) + Length(ASeparator)),
         P + ASeparator) then Exit(True);
  Result := False;
end;

{ RTTI GetValue/SetValue take the instance as an untyped pointer, so an
  object instance is passed as its address. }
{$WARN UNSAFE_CAST OFF}
function FieldValue(AField: TCsvFieldPlan; const AInstance: TValue): TValue;
begin
  if AField.Field <> nil then
  begin
    if AInstance.IsObject then
      Result := AField.Field.GetValue(AInstance.AsObject)
    else
      Result := AField.Field.GetValue(AInstance.GetReferenceToRawData);
  end
  else if AField.Prop <> nil then
  begin
    if AInstance.IsObject then
      Result := AField.Prop.GetValue(AInstance.AsObject)
    else
      Result := AField.Prop.GetValue(AInstance.GetReferenceToRawData);
  end
  else
    Result := TValue.Empty;
end;

procedure SetFieldValue(AField: TCsvFieldPlan; const AInstance: TValue;
  const AValue: TValue);
begin
  if AValue.IsEmpty then Exit;
  if not AField.Writable then Exit;
  if AField.Field <> nil then
  begin
    if AInstance.IsObject then
      AField.Field.SetValue(AInstance.AsObject, AValue)
    else
      AField.Field.SetValue(AInstance.GetReferenceToRawData, AValue);
  end
  else if AField.Prop <> nil then
  begin
    if AInstance.IsObject then
      AField.Prop.SetValue(AInstance.AsObject, AValue)
    else
      AField.Prop.SetValue(AInstance.GetReferenceToRawData, AValue);
  end;
end;
{$WARN UNSAFE_CAST ON}

{ The elements of an array or a TList-shaped container, as values. }
function CollectionElements(APlan: TCsvMemberPlan;
  const AValue: TValue): TArray<TValue>;
var
  I: Integer;
  Arr: TValue;
begin
  Result := nil;
  case APlan.Kind of
    TCsvMemberKind.ArrayValue:
      begin
        SetLength(Result, AValue.GetArrayLength);
        for I := 0 to Integer(High(Result)) do Result[I] := AValue.GetArrayElement(I);
      end;
    TCsvMemberKind.ListValue:
      begin
        if (not AValue.IsObject) or (AValue.AsObject = nil) then Exit;
        if APlan.ContainerToArray = nil then Exit;
        Arr := TSerializationTypes.ListElements(AValue.AsObject,
          APlan.ContainerToArray);
        SetLength(Result, Arr.GetArrayLength);
        for I := 0 to Integer(High(Result)) do Result[I] := Arr.GetArrayElement(I);
      end;
  end;
end;

{ The JSON text of one value, reached THROUGH THE REGISTRY.

  This unit has no compile-time dependency on PascalForge.Json and must not
  acquire one: JsonCell is a mode a caller asks for, and an application that
  never asks should not have to link JSON. If nothing registered it, the
  registry says so by name. }
function JsonTextOf(ATypeInfo: PTypeInfo; const AValue: TValue): string;
var
  Handler: TSerializationFormatHandler;
begin
  Handler := TSerializationFormats.Require(TSerializationFormat.Json,
    TSerializationFormatCapability.ContractSerialize);
  Result := Handler.SerializeTyped(ATypeInfo, AValue).AsTextDocument;
end;

function JsonValueOf(ATypeInfo: PTypeInfo; const AText: string): TValue;
var
  Handler: TSerializationFormatHandler;
begin
  Handler := TSerializationFormats.Require(TSerializationFormat.Json,
    TSerializationFormatCapability.ContractDeserialize);
  Result := Handler.DeserializeTyped(ATypeInfo,
    TSerializationPayload.FromText(AText));
end;

{ LEVELS. Every composite the writer descends into counts one of the
  SERIALIZATION_MAX_GRAPH_DEPTH levels the graph guard allows, the row's own
  value included: an object through Enter, which also keeps the cycle check,
  and a record or an array through EnterLevel. A value handed to JSON for a
  JsonCell is counted by JSON's writer, not here. }
procedure EnterComposite(AIsObject: Boolean; const AValue: TValue;
  const APath: string);
var
  Obj: TObject;
begin
  if not AIsObject then
  begin
    TSerializationGraphGuard.EnterLevel;
    Exit;
  end;
  Obj := nil;
  if AValue.IsObject then Obj := AValue.AsObject;
  { A cycle has no columns: A.Next.Next.Next... never ends, and walking it
    ran the stack out. }
  if not TSerializationGraphGuard.Enter(Obj) then
    raise ECsvProjectionError.CreateForPath(APath,
      Format('%s is an object already being written further up the row: it ' +
        'is a cycle, and a table has no back-reference. Break the cycle, or ' +
        'leave the member out.', [APath]));
end;

procedure LeaveComposite(AIsObject: Boolean; const AValue: TValue);
begin
  if not AIsObject then TSerializationGraphGuard.LeaveLevel
  else if AValue.IsObject then TSerializationGraphGuard.Leave(AValue.AsObject);
end;

{ Does a cell, as it will be rendered, hold anything a reader can tell from
  an absent value? An empty cell and a null marker do not. }
function CellSaysSomething(const ACell: TCsvCell;
  const AOptions: TCsvOptions): Boolean;
begin
  Result := (not ACell.IsNull) and (ACell.Text <> '') and
    not IsNullCell(ACell.Text, AOptions);
end;

function TextSaysSomething(const AText: string;
  const AOptions: TCsvOptions): Boolean;
begin
  Result := (AText <> '') and not IsNullCell(AText, AOptions);
end;

{ Will this collection leave a cell in THIS table that says something? A
  JsonCell always does, and a separate table is not read back from this one
  either way; a collection of composites is taken at its word when it has
  an element. }
function PendingSaysSomething(const APending: TCsvPendingCollection;
  const AOptions: TCsvOptions): Boolean;
var
  I: Integer;
begin
  if not APending.Plan.IsCollection then Exit(True);
  if not (AOptions.CollectionMode in [TCsvCollectionMode.NumberedColumns,
     TCsvCollectionMode.RepeatedRows]) then Exit(True);
  if not IsOneCell(APending.Plan.Item) then
    Exit(Length(APending.Elements) > 0);
  for I := 0 to Integer(High(APending.Elements)) do
    if CellSaysSomething(ScalarToCell(APending.Plan.Item, APending.Elements[I],
         AOptions, APending.Path), AOptions) then Exit(True);
  Result := False;
end;

{ A PRESENT NULLABLE THAT IS NOT ONE CELL writes its value's own cells, and
  an absent one writes none of them, so the reader tells the two apart by
  whether any of those cells holds something. One whose cells would all be
  empty is indistinguishable from no value at all; it is refused here rather
  than read back as absent. }
procedure RaiseNullableWritesNothing(const APath, AMode: string);
begin
  raise ECsvProjectionError.CreateForPath(APath,
    Format('%s has a value, and every cell it writes is empty - which is ' +
      'exactly how a nullable with no value is written, so reading the row ' +
      'back would find none. %s.JsonCell writes it as one cell that keeps ' +
      'the difference.', [APath, AMode]));
end;

type
  { One row being written, with the collection handling able to reach back
    into the columns already placed. }
  TCsvRowWriter = class
  strict private
    FCtx: TCsvWriteContext;
    procedure WriteComposite(APlan: TCsvTypePlan; const AInstance: TValue;
      ABuffer: TCsvBuffer; ARow: Integer; const APrefix, APath: string;
      var APending: TArray<TCsvPendingCollection>);
    procedure WriteCollections(APlan: TCsvTypePlan; ABuffer: TCsvBuffer;
      ARow: Integer;
      const APending: TArray<TCsvPendingCollection>);
    procedure WriteSeparateTable(APlan: TCsvTypePlan;
      const APending: TCsvPendingCollection; ABuffer: TCsvBuffer;
      ARow: Integer);
    function WroteSomething(ABuffer: TCsvBuffer; ARow: Integer;
      const APrefix: string; const APending: TArray<TCsvPendingCollection>;
      AFirstPending: Integer): Boolean;
  public
    constructor Create(ACtx: TCsvWriteContext);
    procedure WriteRow(APlan: TCsvTypePlan; const AInstance: TValue;
      ABuffer: TCsvBuffer);
  end;

constructor TCsvRowWriter.Create(ACtx: TCsvWriteContext);
begin
  inherited Create;
  FCtx := ACtx;
end;

{ Did a walk under APrefix leave, in this row or in the collections it found
  from AFirstPending on, anything the reader can tell from an absent value?
  The reader asks the same question of the same columns. }
function TCsvRowWriter.WroteSomething(ABuffer: TCsvBuffer; ARow: Integer;
  const APrefix: string; const APending: TArray<TCsvPendingCollection>;
  AFirstPending: Integer): Boolean;
var
  I: Integer;
begin
  for I := 0 to ABuffer.ColumnCount - 1 do
    if ABuffer.Columns[I].StartsWith(APrefix) and
       CellSaysSomething(ABuffer.GetCell(ARow, ABuffer.Columns[I]),
         FCtx.Options) then Exit(True);
  for I := AFirstPending to Integer(High(APending)) do
    if PendingSaysSomething(APending[I], FCtx.Options) then Exit(True);
  Result := False;
end;

procedure TCsvRowWriter.WriteComposite(APlan: TCsvTypePlan;
  const AInstance: TValue; ABuffer: TCsvBuffer; ARow: Integer;
  const APrefix, APath: string;
  var APending: TArray<TCsvPendingCollection>);
var
  FP: TCsvFieldPlan;
  V, InnerValue: TValue;
  Path, Column: string;
  Pend: TCsvPendingCollection;
  Inner: TCsvMemberPlan;
  IsNullable, IsObject: Boolean;
  PendingBefore: Integer;
begin
  for FP in APlan.Fields do
  begin
    V := FieldValue(FP, AInstance);
    Path := MemberPath(APath, FP.Name);
    Column := JoinPath(APrefix, FP.Name, FCtx.Options.PathSeparator);

    if IsOneCell(FP.Member) then
    begin
      ABuffer.SetCell(ARow, Column,
        ScalarToCell(FP.Member, V, FCtx.Options, Path));
      Continue;
    end;

    { A nullable whose inner value is composite: an absent one is an empty
      cell, a present one unwraps and carries on below. }
    IsNullable := FP.Member.Kind = TCsvMemberKind.NullableValue;
    if IsNullable then
    begin
      if not FP.Member.NullableAccess.HasValue(V.GetReferenceToRawData) then
      begin
        ABuffer.SetCell(ARow, Column, TCsvCell.Null);
        Continue;
      end;
      Inner := FP.Member.Inner;
      InnerValue := FP.Member.NullableAccess.GetValue(
        V.GetReferenceToRawData);
    end
    else
    begin
      Inner := FP.Member;
      InnerValue := V;
    end;

    if Inner.IsCollection then
    begin
      Pend.Path := Path;
      Pend.MemberName := FP.Name;
      Pend.Prefix := APrefix;
      Pend.Plan := Inner;
      Pend.Value := InnerValue;
      Pend.Elements := CollectionElements(Inner, InnerValue);
      Pend.Level := TSerializationGraphGuard.Level;
      Pend.Nullable := IsNullable;
      if IsNullable and not PendingSaysSomething(Pend, FCtx.Options) then
        RaiseNullableWritesNothing(Path, 'CollectionMode');
      APending := APending + [Pend];
      Continue;
    end;

    if Inner.Kind = TCsvMemberKind.DictionaryValue then
    begin
      { A MAP'S KEYS ARE DATA, not a fixed set of columns. Flattening one
        would give two rows different headers, and a table has one header.
        JsonCell puts the whole map in a cell, which is honest and
        reversible; there is no other column layout that does not invent
        something. }
      if FCtx.Options.NestedObjectMode = TCsvNestedObjectMode.JsonCell then
        ABuffer.SetCell(ARow, Column,
          TCsvCell.Value(JsonTextOf(Inner.TypeInfo, InnerValue)))
      else
        raise ECsvProjectionError.CreateForPath(Path,
          Format('%s is a map, and a map''s keys are data rather than a ' +
            'fixed set of columns - two rows would need different headers, ' +
            'which a table cannot have. NestedObjectMode.JsonCell writes it ' +
            'as one cell; nothing else can write it without inventing a ' +
            'shape.', [Path]));
      Continue;
    end;

    if Inner.IsComposite then
    begin
      case FCtx.Options.NestedObjectMode of
        TCsvNestedObjectMode.Flatten:
          begin
            if (Inner.Kind = TCsvMemberKind.ObjectValue) and
               ((not InnerValue.IsObject) or (InnerValue.AsObject = nil)) then
            begin
              { Present and nil writes no cell, exactly as absent does. }
              if IsNullable then
                RaiseNullableWritesNothing(Path, 'NestedObjectMode');
              Continue;
            end;

            { AN OBJECT WITH NO COLUMNS IS NOT AN ABSENT ONE.

              Flatten writes a nested object as Prefix.Member columns, and a
              class with no serializable members contributes none. The row
              is then identical to the row for a member that was nil, and
              reading it back produces nil - which is a different document,
              and nothing said so.

              The reader will not invent an empty object from an all-absent
              prefix, deliberately, so the honest place to stop is here. A
              caller who wants the member to survive says JsonCell, which
              writes it as a cell holding an empty object. }
            if (Inner.Kind = TCsvMemberKind.ObjectValue) and
               (Inner.BoundPlan <> nil) and
               (Inner.BoundPlan.Fields.Count = 0) then
              raise ECsvProjectionError.CreateForPath(Path,
                Format('%s is present and has no members, so flattening it ' +
                  'writes no columns and reading the row back would find ' +
                  'nothing there. A table cannot say "an empty object was ' +
                  'here". NestedObjectMode.JsonCell writes it as one cell.',
                  [Path]));

            IsObject := Inner.Kind = TCsvMemberKind.ObjectValue;
            PendingBefore := Integer(Length(APending));
            EnterComposite(IsObject, InnerValue, Path);
            try
              WriteComposite(Inner.BoundPlan, InnerValue, ABuffer, ARow,
                Column, Path, APending);
            finally
              LeaveComposite(IsObject, InnerValue);
            end;
            if IsNullable and not WroteSomething(ABuffer, ARow,
                 Column + FCtx.Options.PathSeparator, APending,
                 PendingBefore) then
              RaiseNullableWritesNothing(Path, 'NestedObjectMode');
          end;
        TCsvNestedObjectMode.JsonCell:
          ABuffer.SetCell(ARow, Column,
            TCsvCell.Value(JsonTextOf(Inner.TypeInfo, InnerValue)));
        TCsvNestedObjectMode.SeparateTable:
          begin
            if not FCtx.AllowSeparateTables then
              raise ECsvProjectionError.CreateForPath(Path,
                'NestedObjectMode is SeparateTable and this call produces ' +
                'ONE payload. A separate table is a separate file; use ' +
                'SerializeTables, which returns all of them.');
            Pend.Path := Path;
            Pend.MemberName := FP.Name;
            Pend.Prefix := APrefix;
            Pend.Plan := Inner;
            Pend.Value := InnerValue;
            SetLength(Pend.Elements, 1);
            Pend.Elements[0] := InnerValue;
            Pend.Level := TSerializationGraphGuard.Level;
            Pend.Nullable := False;
            APending := APending + [Pend];
          end;
      else
        raise ECsvProjectionError.CreateForPath(Path,
          Format('%s is an object and a CSV cell holds text. Choose a ' +
            'NestedObjectMode - Flatten, JsonCell or SeparateTable - or ' +
            'leave the member out.', [Path]));
      end;
      Continue;
    end;

    raise ECsvProjectionError.CreateForPath(Path,
      Format('CSV has no way to write %s.', [UTF8ToString(Inner.TypeInfo.Name)]));
  end;
end;

procedure TCsvRowWriter.WriteSeparateTable(APlan: TCsvTypePlan;
  const APending: TCsvPendingCollection; ABuffer: TCsvBuffer;
  ARow: Integer);
var
  Child: TCsvBuffer;
  KeyColumn, RefColumn: string;
  KeyCell: TCsvCell;
  I, ChildRow: Integer;
  Pending: TArray<TCsvPendingCollection>;
  ItemPlan: TCsvMemberPlan;
  FP: TCsvFieldPlan;
  IsObject: Boolean;
begin
  { Child rows have to point back at the parent row, and CSV has no pointers
    - so a key column does.

    A key the parent type DECLARED with [CsvKey] is used as it stands: it
    means something outside this document set, and the relationship says so
    by leaving KeyIsGenerated false. Only when the type declares none is one
    invented, and then the relationship says THAT - because a row number is
    an artefact of this projection and means nothing anywhere else. }
  KeyColumn := '';
  for FP in APlan.Fields do
    if FP.IsKey then
    begin
      KeyColumn := FP.Name;
      Break;
    end;
  Child := AttachChildTable(FCtx, ABuffer, ARow, KeyColumn,
    APending.MemberName, APending.Path, APending.Path, KeyCell, RefColumn);

  if APending.Plan.IsCollection then ItemPlan := APending.Plan.Item
  else ItemPlan := APending.Plan;

  for I := 0 to Integer(High(APending.Elements)) do
  begin
    ChildRow := Child.NewRow;
    Child.SetCell(ChildRow, RefColumn, KeyCell);
    if ItemPlan.IsScalar then
      Child.SetCell(ChildRow, APending.MemberName,
        ScalarToCell(ItemPlan, APending.Elements[I], FCtx.Options,
          APending.Path))
    else if ItemPlan.IsComposite then
    begin
      Pending := nil;
      IsObject := ItemPlan.Kind = TCsvMemberKind.ObjectValue;
      EnterComposite(IsObject, APending.Elements[I], APending.Path);
      try
        WriteComposite(ItemPlan.BoundPlan, APending.Elements[I], Child,
          ChildRow, '', APending.Path, Pending);
        if Length(Pending) > 0 then
          WriteCollections(ItemPlan.BoundPlan, Child, ChildRow, Pending);
      finally
        LeaveComposite(IsObject, APending.Elements[I]);
      end;
    end
    else
      raise ECsvProjectionError.CreateForPath(APending.Path,
        'A separate table holds rows, and this member''s elements have no ' +
        'row shape.');
  end;
end;

procedure TCsvRowWriter.WriteCollections(APlan: TCsvTypePlan;
  ABuffer: TCsvBuffer; ARow: Integer;
  const APending: TArray<TCsvPendingCollection>);
var
  P: TCsvPendingCollection;
  I, J, Target, Multiplying, Saved: Integer;
  Column: string;
  ItemPlan: TCsvMemberPlan;
  Nested: TArray<TCsvPendingCollection>;
  Rows, NextRows: TArray<Integer>;
  IsList, IsObject, Present: Boolean;
begin
  { More than one collection on one row is the case where flattening has to
    INVENT data. N times M rows contains pairings the source never had, so
    it is refused unless the caller has said in writing that they want them
    anyway. }
  Multiplying := 0;
  for P in APending do
    if P.Plan.IsCollection and
       (FCtx.Options.CollectionMode = TCsvCollectionMode.RepeatedRows) and
       (Length(P.Elements) > 1) then Inc(Multiplying);
  CheckMultiplying(FCtx.Options, Multiplying, APending[0].Path);

  { The rows this parent currently occupies. RepeatedRows grows it, which is
    what makes a second collection a PRODUCT rather than a second list
    written down the same column. }
  Rows := [ARow];

  for P in APending do
  begin
    Column := JoinPath(P.Prefix, P.MemberName, FCtx.Options.PathSeparator);
    { Written after the walk that found it has returned, so the levels of
      the composites it sits in are counted again from where it was found. }
    Saved := TSerializationGraphGuard.Level;
    TSerializationGraphGuard.RestoreLevel(P.Level);
    try
      if not P.Plan.IsCollection then
      begin
        { A nested OBJECT routed to a separate table. }
        for J in Rows do WriteSeparateTable(APlan, P, ABuffer, J);
        Continue;
      end;

      ItemPlan := P.Plan.Item;
      if FCtx.Options.CollectionMode = TCsvCollectionMode.JsonCell then
      begin
        { The whole collection as one JSON document, through the registry.
          It is the only mode that keeps the shape exactly, at the cost of
          putting one format's document inside another's. JSON's writer
          counts its levels. }
        for J in Rows do
          ABuffer.SetCell(J, Column,
            TCsvCell.Value(JsonTextOf(P.Plan.TypeInfo, P.Value)));
        Continue;
      end;

      { The collection is a level of its own: a list is an object, entered
        with the cycle check, and an array is a level. }
      IsList := P.Plan.Kind = TCsvMemberKind.ListValue;
      EnterComposite(IsList, P.Value, P.Path);
      try
        case FCtx.Options.CollectionMode of
          TCsvCollectionMode.NumberedColumns:
            for J in Rows do
              for I := 0 to Integer(High(P.Elements)) do
                if ItemPlan.IsScalar then
                  ABuffer.SetCell(J, Column + '_' + IntToStr(I + 1),
                    ScalarToCell(ItemPlan, P.Elements[I], FCtx.Options, P.Path))
                else
                  raise ECsvProjectionError.CreateForPath(P.Path,
                    'NumberedColumns writes one cell per element and these ' +
                    'elements are not scalars. Use SeparateTable or JsonCell.');

          TCsvCollectionMode.RepeatedRows:
            begin
              if Length(P.Elements) = 0 then Continue;
              NextRows := nil;
              for J in Rows do
                for I := 0 to Integer(High(P.Elements)) do
                begin
                  { The first element reuses the row it came from; every
                    other one takes a copy of it, so the columns already
                    written are carried onto each new row. }
                  if I = 0 then Target := J else Target := ABuffer.CloneRow(J);
                  NextRows := NextRows + [Target];
                  if ItemPlan.IsScalar then
                    ABuffer.SetCell(Target, Column,
                      ScalarToCell(ItemPlan, P.Elements[I], FCtx.Options,
                        P.Path))
                  else if ItemPlan.IsComposite then
                  begin
                    Nested := nil;
                    IsObject := ItemPlan.Kind = TCsvMemberKind.ObjectValue;
                    EnterComposite(IsObject, P.Elements[I], P.Path);
                    try
                      WriteComposite(ItemPlan.BoundPlan, P.Elements[I],
                        ABuffer, Target, Column, P.Path, Nested);
                      if Length(Nested) > 0 then
                        WriteCollections(ItemPlan.BoundPlan, ABuffer, Target,
                          Nested);
                    finally
                      LeaveComposite(IsObject, P.Elements[I]);
                    end;
                  end
                  else
                    raise ECsvProjectionError.CreateForPath(P.Path,
                      'RepeatedRows writes one row per element and these ' +
                      'elements have no row shape.');
                end;
              { The reader takes a nullable of composites as present when
                one of its rows says something under its prefix. }
              if P.Nullable and ItemPlan.IsComposite then
              begin
                Present := False;
                for J in NextRows do
                  if WroteSomething(ABuffer, J,
                       Column + FCtx.Options.PathSeparator, nil, 0) then
                  begin
                    Present := True;
                    Break;
                  end;
                if not Present then
                  RaiseNullableWritesNothing(P.Path, 'CollectionMode');
              end;
              Rows := NextRows;
            end;

          TCsvCollectionMode.SeparateTable:
            begin
              if not FCtx.AllowSeparateTables then
                raise ECsvProjectionError.CreateForPath(P.Path,
                  CSV_SEPARATE_TABLE_GUIDANCE);
              for J in Rows do WriteSeparateTable(APlan, P, ABuffer, J);
            end;
        else
          raise ECsvProjectionError.CreateForPath(P.Path,
            Format('%s is a collection and a CSV cell holds one value. ' +
              'Choose a CollectionMode - JsonCell, RepeatedRows, ' +
              'NumberedColumns or SeparateTable - or leave the member out.',
              [P.Path]));
        end;
      finally
        LeaveComposite(IsList, P.Value);
      end;
    finally
      TSerializationGraphGuard.RestoreLevel(Saved);
    end;
  end;
end;
procedure TCsvRowWriter.WriteRow(APlan: TCsvTypePlan; const AInstance: TValue;
  ABuffer: TCsvBuffer);
var
  Row: Integer;
  Pending: TArray<TCsvPendingCollection>;
  IsObject: Boolean;
begin
  Row := ABuffer.NewRow;
  Pending := nil;
  { The row's own value is a level, like every composite below it: a chain
    of 64 objects is the most any format writes. }
  IsObject := not APlan.IsRecord;
  EnterComposite(IsObject, AInstance, '$');
  try
    WriteComposite(APlan, AInstance, ABuffer, Row, '', '$', Pending);
    if Length(Pending) > 0 then WriteCollections(APlan, ABuffer, Row, Pending);
  finally
    LeaveComposite(IsObject, AInstance);
  end;
end;

{ ===========================================================================
  THE ROW WALK, BACKWARDS

  Reading is the inverse of the writing above, mode for mode. The one place
  it cannot be exact is RepeatedRows: the rows that came from one parent are
  recognised by their scalar columns repeating, which is the only signal the
  file carries. A parent whose scalar columns genuinely repeat is therefore
  read as one parent - said here rather than discovered.
  =========================================================================== }

const
  { A header states its own nesting - Next.Next.Next.Id - and the reader
    follows it one prefix at a time, recursively: a header of twenty
    thousand prefixes overflowed the stack. The writer never nests past 64
    levels, so this is far above anything it writes. }
  CSV_MAX_DEPTH = 256;

type
  TCsvRowReader = class
  strict private
    FOptions: TCsvOptions;
    FTable: TCsvTable;
    FTables: TCsvDocumentSet;
    FDepth: Integer;
    function ReadComposite(APlan: TCsvTypePlan; ARow: Integer;
      const APrefix, APath: string; const AExisting: TValue): TValue;
    function ReadCollection(AMember: TCsvMemberPlan; const AExisting: TValue;
      ARow: Integer;
      const AColumn, APath: string): TValue;
    function CreateInstance(APlan: TCsvTypePlan; const APath: string): TValue;
    function RowSaysSomething(ARow: Integer; const APrefix: string): Boolean;
    function CollectionSaysSomething(ARow: Integer;
      const AColumn: string): Boolean;
    function CollectionMentioned(const AColumn: string): Boolean;
    procedure ReadJsonCell(AField: TCsvFieldPlan; const AInstance: TValue;
      AInner: TCsvMemberPlan; AIsNullable: Boolean; ARow: Integer;
      const AColumn: string);
  public
    constructor Create(ATable: TCsvTable; const AOptions: TCsvOptions;
      ATables: TCsvDocumentSet);
    procedure MergeRepeated(APlan: TCsvTypePlan; const AInstance: TValue;
      AFirstRow, ALastRow: Integer; const ANames: TArray<string>);
    function ReadRow(APlan: TCsvTypePlan; ARow: Integer;
      const AExisting: TValue): TValue;
  end;

constructor TCsvRowReader.Create(ATable: TCsvTable;
  const AOptions: TCsvOptions; ATables: TCsvDocumentSet);
begin
  inherited Create;
  FTable := ATable;
  FOptions := AOptions;
  FTables := ATables;
end;

function TCsvRowReader.CreateInstance(APlan: TCsvTypePlan;
  const APath: string): TValue;
var
  Obj: TObject;
begin
  if APlan.IsRecord then
  begin
    TValue.Make(nil, APlan.TypeInfo, Result);
    Exit;
  end;
  if APlan.ZeroConstructor = nil then
    raise ECsvProjectionError.CreateForPath(APath,
      Format('%s has no parameterless constructor, so CSV cannot build ' +
        'one.', [UTF8ToString(APlan.TypeInfo.Name)]));
  Obj := APlan.ZeroConstructor.Invoke(APlan.ClassType, []).AsObject;
  TValue.Make(@Obj, APlan.TypeInfo, Result);
end;

{ One element into a container, through its family's Add. What the container
  itself refuses - a sorted TStringList with Duplicates = dupError, given a
  line twice - is the document's content refused, so it reaches the caller
  as a CSV input error naming the container, not as the RTL's exception. }
procedure AddElement(AMember: TCsvMemberPlan; AContainer: TObject;
  const AElement: TValue; const APath: string);
begin
  try
    AMember.ContainerAdd.Invoke(AContainer, [AElement]);
  except
    on E: Exception do
    begin
      if (E is EOutOfMemory) or
         string(E.UnitName).StartsWith('PascalForge.') then raise;
      raise ECsvInputError.CreateFmt(
        'Column %s: the %s refused an element the document holds: %s',
        [APath, AContainer.ClassName, E.Message]);
    end;
  end;
end;

{ A list the member already holds, refilled in place - the rule every format
  follows. Building a second one and storing it over the first leaked the
  first, and the child list a constructor makes is the everyday case. }
function RefillOrCreate(AMember: TCsvMemberPlan; const AExisting: TValue;
  const AElements: TArray<TValue>; const APath: string): TValue;
var
  Container: TObject;
  I, Added: Integer;
  Built: Boolean;
begin
  Built := not (AExisting.IsObject and (AExisting.AsObject <> nil));
  Added := 0;
  { The elements are this read's until the container holds them: a failure
    frees the ones not handed over, the one refused among them. }
  try
    if Built then
    begin
      if AMember.ContainerCreate = nil then
        raise ECsvProjectionError.CreateForPath(APath,
          'This container has no parameterless constructor, so CSV ' +
          'cannot build one.');
      { The metaclass comes from the type info directly: a container's
        constructor needs something to be called on, and going back to an
        RTTI context for it would be a second source of truth. }
      Container := AMember.ContainerCreate.Invoke(
        GetTypeData(AMember.TypeInfo).ClassType, []).AsObject;
    end
    else
    begin
      Container := AExisting.AsObject;
      if AMember.ContainerClear <> nil then
        AMember.ContainerClear.Invoke(Container, []);
    end;
    try
      for I := 0 to Integer(High(AElements)) do
      begin
        AddElement(AMember, Container, AElements[I], APath);
        Added := I + 1;
      end;
    except
      { One this read built goes with the elements it holds: a TList<TObj>
        owns none of them, and freeing it alone orphaned every one. }
      if Built then TSerializationOwnership.ReleaseBuiltContainer(Container);
      raise;
    end;
  except
    TSerializationOwnership.ReleaseBuiltElements(AMember.Item.TypeInfo,
      Copy(AElements, Added, MaxInt));
    raise;
  end;
  TValue.Make(@Container, AMember.TypeInfo, Result);
end;

{ The object a member already holds, or nothing. }
function ExistingObjectOf(AField: TCsvFieldPlan; const AInstance: TValue): TValue;
begin
  Result := TValue.Empty;
  if (AField.Member = nil) or (AField.Member.TypeInfo = nil) or
     (AField.Member.TypeInfo.Kind <> tkClass) then Exit;
  Result := FieldValue(AField, AInstance);
  if Result.IsObject and (Result.AsObject = nil) then Result := TValue.Empty;
end;

{ What a composite member holds now, for a read that fills it in place: its
  object, or its record - merged, so the objects a constructor or the caller
  put in the record are filled rather than replaced and orphaned, and the
  members the document omits keep their values. }
function ExistingValueOf(AField: TCsvFieldPlan; const AInstance: TValue): TValue;
begin
  if (AField.Member <> nil) and
     (AField.Member.Kind = TCsvMemberKind.RecordValue) then
    Exit(FieldValue(AField, AInstance));
  Result := ExistingObjectOf(AField, AInstance);
end;

{ The value inside a TNullable member when it has one, so a present nullable
  is filled in place like any other member; otherwise nothing. }
function ExistingNullableValueOf(AField: TCsvFieldPlan;
  const AInstance: TValue): TValue;
var
  N: TValue;
begin
  Result := TValue.Empty;
  N := FieldValue(AField, AInstance);
  if N.IsEmpty or
     not AField.Member.NullableAccess.HasValue(N.GetReferenceToRawData) then
    Exit;
  Result := AField.Member.NullableAccess.GetValue(N.GetReferenceToRawData);
  if Result.IsObject and (Result.AsObject = nil) then Result := TValue.Empty;
end;

{ A TNullable member given a value, or marked empty. It starts from the
  nullable as it stands, so marking it empty leaves its value slot alone:
  what that holds is its owner's, not this read's. }
procedure SetNullableField(AField: TCsvFieldPlan; const AInstance: TValue;
  const AValue: TValue; APresent: Boolean);
var
  N: TValue;
begin
  N := FieldValue(AField, AInstance);
  if N.IsEmpty then TValue.Make(nil, AField.Member.TypeInfo, N);
  if APresent then
    AField.Member.NullableAccess.SetValue(N.GetReferenceToRawData, AValue)
  else
    AField.Member.NullableAccess.Clear(N.GetReferenceToRawData);
  SetFieldValue(AField, AInstance, N);
end;

{ Does this row hold, under APrefix, a cell that says something? The writer
  refuses a present nullable whose cells would all be empty or null, so this
  is the difference between a present one and an absent one. }
function TCsvRowReader.RowSaysSomething(ARow: Integer;
  const APrefix: string): Boolean;
var
  Name, Cell: string;
begin
  for Name in FTable.ColumnsStartingWith(APrefix) do
    if FTable.TryCell(ARow, Name, Cell) and
       TextSaysSomething(Cell, FOptions) then Exit(True);
  Result := False;
end;

{ The same question of a collection at AColumn, in the cells its mode
  writes. }
function TCsvRowReader.CollectionSaysSomething(ARow: Integer;
  const AColumn: string): Boolean;
var
  I: Integer;
  Cell: string;
begin
  if FOptions.CollectionMode = TCsvCollectionMode.NumberedColumns then
  begin
    I := 1;
    while FTable.TryCell(ARow, AColumn + '_' + IntToStr(I), Cell) do
    begin
      if TextSaysSomething(Cell, FOptions) then Exit(True);
      Inc(I);
    end;
    Exit(False);
  end;
  Result := FTable.TryCell(ARow, AColumn, Cell) and
    TextSaysSomething(Cell, FOptions);
end;

{ Has the table a column for this collection at all? An absent nullable is
  its own column marked null, a present one the cells of its mode; with
  neither, the document says nothing and the member keeps what it holds. }
function TCsvRowReader.CollectionMentioned(const AColumn: string): Boolean;
begin
  Result := FTable.HasColumn(AColumn) or
    ((FOptions.CollectionMode = TCsvCollectionMode.NumberedColumns) and
     FTable.HasColumn(AColumn + '_1'));
end;

{ A member written as one JSON cell. A nullable one is absent when the cell
  says nothing - an absent one is written null, and a JSON document is never
  empty. }
procedure TCsvRowReader.ReadJsonCell(AField: TCsvFieldPlan;
  const AInstance: TValue; AInner: TCsvMemberPlan; AIsNullable: Boolean;
  ARow: Integer; const AColumn: string);
var
  Cell: string;
begin
  if not FTable.TryCell(ARow, AColumn, Cell) then Exit;
  if AIsNullable then
  begin
    if TextSaysSomething(Cell, FOptions) then
      SetNullableField(AField, AInstance,
        JsonValueOf(AInner.TypeInfo, Cell), True)
    else
      SetNullableField(AField, AInstance, TValue.Empty, False);
    Exit;
  end;
  if Cell = '' then Exit;
  SetFieldValue(AField, AInstance, JsonValueOf(AInner.TypeInfo, Cell));
end;

function TCsvRowReader.ReadCollection(AMember: TCsvMemberPlan;
  const AExisting: TValue; ARow: Integer;
  const AColumn, APath: string): TValue;
var
  Cell: string;
  Elements: TArray<TValue>;
  I: Integer;
  Arr: TValue;
  Why: string;
  Name: string;
begin
  Result := TValue.Empty;
  Elements := nil;

  case FOptions.CollectionMode of
    TCsvCollectionMode.JsonCell:
      begin
        if not FTable.TryCell(ARow, AColumn, Cell) then Exit;
        if Cell = '' then Exit;
        Exit(JsonValueOf(AMember.TypeInfo, Cell));
      end;

    TCsvCollectionMode.NumberedColumns:
      begin
        I := 1;
        { An element a custom serializer built is this read's until the
          collection holds it. }
        try
          while True do
          begin
            Name := AColumn + '_' + IntToStr(I);
            if not FTable.TryCell(ARow, Name, Cell) then Break;
            Elements := Elements + [CellToScalar(AMember.Item,
              TCsvCell.Value(Cell), FOptions, APath, TValue.Empty)];
            Inc(I);
          end;
        except
          TSerializationOwnership.ReleaseBuiltElements(AMember.Item.TypeInfo,
            Elements);
          raise;
        end;
      end;

    TCsvCollectionMode.RepeatedRows:
      begin
        { One row is one element; the grouping is done by the caller, which
          is the only place that can see the other rows. }
        if not FTable.TryCell(ARow, AColumn, Cell) then Exit;
        Elements := [CellToScalar(AMember.Item, TCsvCell.Value(Cell),
          FOptions, APath, TValue.Empty)];
      end;
  else
    raise ECsvProjectionError.CreateForPath(APath,
      Format('%s is a collection and this CollectionMode cannot be read ' +
        'back from a single table. SeparateTable is read by ' +
        'DeserializeTables.', [APath]));
  end;

  case AMember.Kind of
    TCsvMemberKind.ArrayValue:
      begin
        if not TSerializationTypes.TryMakeArray(AMember.TypeInfo, Elements,
             Arr, Why) then
        begin
          TSerializationOwnership.ReleaseBuiltElements(AMember.Item.TypeInfo,
            Elements);
          raise ECsvInputError.CreateFmt('Column %s: %s.', [APath, Why]);
        end;
        Exit(Arr);
      end;
    TCsvMemberKind.ListValue:
      Exit(RefillOrCreate(AMember, AExisting, Elements, APath));
  end;
end;

function TCsvRowReader.ReadComposite(APlan: TCsvTypePlan; ARow: Integer;
  const APrefix, APath: string; const AExisting: TValue): TValue;
var
  FP: TCsvFieldPlan;
  Path, Column, Cell, Prefix: string;
  Inner: TCsvMemberPlan;
  Value: TValue;
  HasAny, IsNullable: Boolean;
begin
  if FDepth >= CSV_MAX_DEPTH then
    raise ECsvInputError.CreateFmt('At %s: the header nests objects more ' +
      'than %d levels deep, which is far past anything this library writes.',
      [APath, CSV_MAX_DEPTH]);
  Inc(FDepth);
  try
  if AExisting.IsEmpty then Result := CreateInstance(APlan, APath)
  { Into a COPY of the record: assigning the TValue shared its data, and a
    failure could then not tell the objects it built from those that were
    there. }
  else if APlan.IsRecord then
    TValue.Make(AExisting.GetReferenceToRawData, APlan.TypeInfo, Result)
  else Result := AExisting;

  { What this read constructed is this read's to free when it fails; an
    instance the caller passed in is never freed. A record is stored only
    when it is complete, so the objects read into it go with it - all but
    the ones it already held, which were filled in place. }
  try
  for FP in APlan.Fields do
  begin
    Path := MemberPath(APath, FP.Name);
    Column := JoinPath(APrefix, FP.Name, FOptions.PathSeparator);
    Inner := FP.Member;

    if IsOneCell(Inner) then
    begin
      if not FTable.TryCell(ARow, Column, Cell) then Continue;
      SetFieldValue(FP, Result,
        CellToScalar(Inner, TCsvCell.Value(Cell), FOptions, Path,
          TValue.Empty));
      Continue;
    end;

    { A nullable that is not one cell is its value's own cells, the way the
      writer unwrapped it, and is present when one of them says something:
      the writer refused a present one of which that is not true. }
    IsNullable := Inner.Kind = TCsvMemberKind.NullableValue;
    if IsNullable then Inner := Inner.Inner;

    if Inner.IsCollection then
    begin
      if IsNullable then
      begin
        if not CollectionMentioned(Column) then Continue;
        if not CollectionSaysSomething(ARow, Column) then
        begin
          SetNullableField(FP, Result, TValue.Empty, False);
          Continue;
        end;
        Value := ReadCollection(Inner, ExistingNullableValueOf(FP, Result),
          ARow, Column, Path);
        if not Value.IsEmpty then
          SetNullableField(FP, Result, Value, True);
        Continue;
      end;
      Value := ReadCollection(Inner, ExistingObjectOf(FP, Result), ARow,
        Column, Path);
      if not Value.IsEmpty then SetFieldValue(FP, Result, Value);
      Continue;
    end;

    if Inner.Kind = TCsvMemberKind.DictionaryValue then
    begin
      { Only JsonCell can have written one, so only JsonCell can read one
        back. Any other mode refused on the way out and there is nothing in
        this table to read. }
      if FOptions.NestedObjectMode = TCsvNestedObjectMode.JsonCell then
        ReadJsonCell(FP, Result, Inner, IsNullable, ARow, Column);
      Continue;
    end;

    if Inner.IsComposite then
    begin
      case FOptions.NestedObjectMode of
        TCsvNestedObjectMode.Flatten:
          begin
            { A nested object is present only when at least one of its
              columns is. Building one from an all-absent prefix would turn
              a missing member into an empty one, which is a different
              document. }
            Prefix := Column + FOptions.PathSeparator;
            HasAny := Length(FTable.ColumnsStartingWith(Prefix)) > 0;
            if IsNullable then
            begin
              { An absent one is its own column marked null. }
              if not (HasAny or FTable.HasColumn(Column)) then Continue;
              if not RowSaysSomething(ARow, Prefix) then
              begin
                SetNullableField(FP, Result, TValue.Empty, False);
                Continue;
              end;
              SetNullableField(FP, Result,
                ReadComposite(Inner.BoundPlan, ARow, Column, Path,
                  ExistingNullableValueOf(FP, Result)), True);
              Continue;
            end;
            if not HasAny then Continue;
            SetFieldValue(FP, Result,
              ReadComposite(Inner.BoundPlan, ARow, Column, Path,
                ExistingValueOf(FP, Result)));
          end;
        TCsvNestedObjectMode.JsonCell:
          ReadJsonCell(FP, Result, Inner, IsNullable, ARow, Column);
      else
        { SeparateTable and Error: nothing in THIS table says what the
          member held, and inventing an empty one would be a lie. }
        Continue;
      end;
      Continue;
    end;
  end;
  except
    if APlan.IsRecord then
      TSerializationOwnership.ReleaseBuilt(APlan.TypeInfo, Result, AExisting)
    else if AExisting.IsEmpty and Result.IsObject then
      Result.AsObject.Free;
    raise;
  end;
  finally
    Dec(FDepth);
  end;
end;

function TCsvRowReader.ReadRow(APlan: TCsvTypePlan; ARow: Integer;
  const AExisting: TValue): TValue;
begin
  Result := ReadComposite(APlan, ARow, '', '$', AExisting);
end;

{ Fill the RepeatedRows collections of one parent from the whole group of
  rows it spans.

  This is the one place reading is not a mirror of writing: the file records
  N rows and nothing that says they were one parent, so the grouping is done
  by the caller - which can see the other rows - and this puts the elements
  back. }
procedure TCsvRowReader.MergeRepeated(APlan: TCsvTypePlan;
  const AInstance: TValue; AFirstRow, ALastRow: Integer;
  const ANames: TArray<string>);
var
  FP: TCsvFieldPlan;
  Inner, ItemPlan: TCsvMemberPlan;
  Elements: TArray<TValue>;
  R: Integer;
  Cell: string;
  Arr, Element: TValue;
  Why: string;
  Nested, Existing: TValue;
  IsNullable, Present: Boolean;
begin
  for FP in APlan.Fields do
  begin
    Inner := FP.Member;
    IsNullable := Inner.Kind = TCsvMemberKind.NullableValue;
    if IsNullable then Inner := Inner.Inner;
    if not Inner.IsCollection then Continue;
    if not MatchesAnyPrefix(FP.Name, ANames, FOptions.PathSeparator) then
      Continue;

    ItemPlan := Inner.Item;
    { A nullable is present when a row of the group says something in its
      cells, as the writer made sure a present one does; its composite
      elements are then one per row, as a plain collection's are. }
    Present := True;
    if IsNullable and ItemPlan.IsComposite then
    begin
      Present := False;
      for R := AFirstRow to ALastRow do
        if RowSaysSomething(R, FP.Name + FOptions.PathSeparator) then
        begin
          Present := True;
          Break;
        end;
    end;
    Elements := nil;
    Arr := TValue.Empty;
    { Every element read here is this read's until a container or the
      instance holds it: a later row that fails frees them. }
    try
      if Present then
        for R := AFirstRow to ALastRow do
        begin
          if ItemPlan.IsScalar then
          begin
            if not FTable.TryCell(R, FP.Name, Cell) then Continue;
            if Cell = '' then Continue;
            { An absent nullable's own cell, marked null. }
            if IsNullable and not TextSaysSomething(Cell, FOptions) then
              Continue;
            Elements := Elements + [CellToScalar(ItemPlan,
              TCsvCell.Value(Cell), FOptions, FP.Name, TValue.Empty)];
          end
          else if ItemPlan.IsComposite then
          begin
            Nested := ReadComposite(ItemPlan.BoundPlan, R, FP.Name, FP.Name,
              TValue.Empty);
            Elements := Elements + [Nested];
          end
          else
            raise ECsvProjectionError.CreateForPath(FP.Name,
              'RepeatedRows read one row per element and these elements have ' +
              'no row shape.');
        end;
      if IsNullable and (Length(Elements) = 0) then Present := False;
      if (Inner.Kind = TCsvMemberKind.ArrayValue) and Present and
         not TSerializationTypes.TryMakeArray(Inner.TypeInfo, Elements,
           Arr, Why) then
        raise ECsvInputError.Create(Why + '.');
    except
      TSerializationOwnership.ReleaseBuiltElements(ItemPlan.TypeInfo,
        Elements);
      raise;
    end;

    if IsNullable and not Present then
    begin
      SetNullableField(FP, AInstance, TValue.Empty, False);
      Continue;
    end;

    case Inner.Kind of
      TCsvMemberKind.ArrayValue:
        if IsNullable then SetNullableField(FP, AInstance, Arr, True)
        else SetFieldValue(FP, AInstance, Arr);
      TCsvMemberKind.ListValue:
        begin
          if IsNullable then Existing := ExistingNullableValueOf(FP, AInstance)
          else Existing := ExistingObjectOf(FP, AInstance);
          if (Inner.ContainerCreate = nil) and Existing.IsEmpty then
          begin
            TSerializationOwnership.ReleaseBuiltElements(ItemPlan.TypeInfo,
              Elements);
            Continue;
          end;
          Element := RefillOrCreate(Inner, Existing, Elements, FP.Name);
          if IsNullable then SetNullableField(FP, AInstance, Element, True)
          else SetFieldValue(FP, AInstance, Element);
        end;
    end;
  end;
end;

{ ===========================================================================
  SCHEMA INFERENCE

  CSV states NOTHING about types. Every function here is therefore a guess
  with a stated boundary, and the boundary is the caller's to move.
  =========================================================================== }

{ The CSV column type a contract member projects to. }
function ColumnTypeOfMember(APlan: TCsvMemberPlan): TCsvColumnType;
var
  Plan: TCsvMemberPlan;
begin
  Plan := APlan;
  if Plan.Kind = TCsvMemberKind.NullableValue then Plan := Plan.Inner;
  case Plan.Kind of
    TCsvMemberKind.BoolValue: Exit(TCsvColumnType.Boolean);
    TCsvMemberKind.IntValue: Exit(TCsvColumnType.Int32);
    TCsvMemberKind.Int64Value: Exit(TCsvColumnType.Int64);
    TCsvMemberKind.FloatValue, TCsvMemberKind.CurrencyValue:
      Exit(TCsvColumnType.Float);
    TCsvMemberKind.GuidValue: Exit(TCsvColumnType.Guid);
    TCsvMemberKind.DateValue, TCsvMemberKind.TimeValue,
    TCsvMemberKind.DateTimeValue: Exit(TCsvColumnType.DateTime);
    TCsvMemberKind.BytesValue: Exit(TCsvColumnType.Binary);
  end;
  Result := TCsvColumnType.Str;
end;

procedure DescribeInto(ASchema: TCsvSchema; APlan: TCsvTypePlan;
  const APrefix, APath: string; const AOptions: TCsvOptions);
var
  FP: TCsvFieldPlan;
  Column: TCsvColumn;
  Inner: TCsvMemberPlan;
  Name, Path: string;
begin
  for FP in APlan.Fields do
  begin
    Name := JoinPath(APrefix, FP.Name, AOptions.PathSeparator);
    Path := MemberPath(APath, FP.Name);
    Inner := FP.Member;
    if Inner.Kind = TCsvMemberKind.NullableValue then Inner := Inner.Inner;

    if IsOneCell(FP.Member) then
    begin
      Column := TCsvColumn.Make(Name, ColumnTypeOfMember(FP.Member));
      Column.Nullable := FP.Member.Kind = TCsvMemberKind.NullableValue;
      Column.DateFormat := FP.Member.DatePattern;
      Column.Path := Path;
      ASchema.Add(Column);
      Continue;
    end;

    if Inner.IsComposite and
       (AOptions.NestedObjectMode = TCsvNestedObjectMode.Flatten) then
    begin
      DescribeInto(ASchema, Inner.BoundPlan, Name, Path, AOptions);
      Continue;
    end;

    { Anything else occupies ONE column whose content is another format's
      document or a key into another table, so its type is text as far as a
      CSV consumer is concerned. Saying Str here is not a guess; it is what
      the column actually holds. }
    Column := TCsvColumn.Make(Name, TCsvColumnType.Str);
    Column.Path := Path;
    ASchema.Add(Column);
  end;
end;

{ ===========================================================================
  TCsvEngine - the entry points
  =========================================================================== }

{ The plan for the ROW type, given the plan for whatever the caller passed.
  A caller serializing an array of shipments means a table of shipments; one
  serializing a single shipment means a table of one row. }
function RowPlanOf(ARoot: TCsvMemberPlan; out AIsMany: Boolean;
  out ACollection: TCsvMemberPlan): TCsvMemberPlan;
begin
  AIsMany := False;
  ACollection := nil;
  Result := ARoot;
  if Result.Kind = TCsvMemberKind.NullableValue then Result := Result.Inner;
  if Result.IsCollection then
  begin
    AIsMany := True;
    ACollection := Result;
    Result := Result.Item;
    if Result.Kind = TCsvMemberKind.NullableValue then Result := Result.Inner;
  end;
end;

class function TCsvEngine.SerializeRoot(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AOptions: TCsvOptions): string;
var
  Tables: TCsvDocumentSet;
begin
  Tables := SerializeRootTables(ATypeInfo, AValue, AOptions);
  try
    if Tables.Count > 1 then
      raise ECsvProjectionError.CreateForPath('$',
        Format('This projection produced %d tables and Serialize returns ' +
          'ONE payload. A table is a file: use SerializeTables, which ' +
          'returns all of them with the relationships between them.',
          [Tables.Count]));
    if Tables.Count = 0 then Exit('');
    Result := Tables[0].Content;
  finally
    Tables.Free;
  end;
end;

class function TCsvEngine.SerializeRootTables(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AOptions: TCsvOptions): TCsvDocumentSet;
var
  Ctx: TCsvWriteContext;
  Writer: TCsvRowWriter;
  Root, RowPlan, Collection: TCsvMemberPlan;
  IsMany: Boolean;
  Elements: TArray<TValue>;
  I, Mark: Integer;
  Buffer: TCsvBuffer;
  IsList: Boolean;
begin
  Root := GetRootPlan(ATypeInfo);
  RowPlan := RowPlanOf(Root, IsMany, Collection);
  if not RowPlan.IsComposite then
    raise ECsvProjectionError.CreateForPath('$',
      Format('A CSV table is rows of named columns, and %s has no members ' +
        'to be columns. Serialize a record, a class, or a list of either.',
        [UTF8ToString(ATypeInfo.Name)]));

  Mark := TSerializationGraphGuard.Level;
  Ctx := TCsvWriteContext.Create(AOptions);
  try
    begin
      Ctx.AllowSeparateTables := True;
      Buffer := Ctx.NewBuffer(RowPlan.BoundPlan.TableName);
      Writer := TCsvRowWriter.Create(Ctx);
      try
        if IsMany then
        begin
          { A list or array of rows is a level, and each row one more. }
          IsList := Collection.Kind = TCsvMemberKind.ListValue;
          EnterComposite(IsList, AValue, '$');
          try
            Elements := CollectionElements(
              Collection, AValue);
            for I := 0 to Integer(High(Elements)) do
              Writer.WriteRow(RowPlan.BoundPlan, Elements[I], Buffer);
          finally
            LeaveComposite(IsList, AValue);
          end;
        end
        else
          Writer.WriteRow(RowPlan.BoundPlan, AValue, Buffer);
      finally
        Writer.Free;
        TSerializationGraphGuard.RestoreLevel(Mark);
      end;

      Result := DocumentSetOf(Ctx);
    end;
  finally
    Ctx.Free;
  end;
end;

{ Every column name that belongs to a top-level RepeatedRows collection, so
  that the rows of one parent can be recognised by everything else matching. }
function RepeatedColumnsOf(APlan: TCsvTypePlan;
  const AOptions: TCsvOptions): TArray<string>;
var
  FP: TCsvFieldPlan;
  Inner: TCsvMemberPlan;
begin
  Result := nil;
  if AOptions.CollectionMode <> TCsvCollectionMode.RepeatedRows then Exit;
  for FP in APlan.Fields do
  begin
    Inner := FP.Member;
    if Inner.Kind = TCsvMemberKind.NullableValue then Inner := Inner.Inner;
    if Inner.IsCollection then Result := Result + [FP.Name];
  end;
end;

class function TCsvEngine.DeserializeRoot(ATypeInfo: PTypeInfo;
  const AText: string; const AOptions: TCsvOptions): TValue;
var
  Table: TCsvTable;
  Reader: TCsvRowReader;
  Root, RowPlan, Collection: TCsvMemberPlan;
  IsMany: Boolean;
  Rows: TArray<TValue>;
  Repeated: TArray<string>;
  I, J, Added: Integer;
  Same: Boolean;
  Name: string;
  Groups: TArray<Integer>;
  Container: TObject;
  Arr: TValue;
  Why: string;
begin
  Root := GetRootPlan(ATypeInfo);
  RowPlan := RowPlanOf(Root, IsMany, Collection);
  if not RowPlan.IsComposite then
    raise ECsvProjectionError.CreateForPath('$',
      Format('A CSV table is rows of named columns, and %s has no members ' +
        'to be columns.', [UTF8ToString(ATypeInfo.Name)]));

  Table := ParseTable(AText, AOptions);
  try
    Repeated := RepeatedColumnsOf(RowPlan.BoundPlan, AOptions);

    { With RepeatedRows, consecutive rows whose NON-collection columns all
      match came from one parent. That repetition is the only signal the
      file carries, so it is what the grouping uses - and a parent whose
      other columns genuinely repeat is read as one parent, which is said
      here rather than discovered. }
    Groups := nil;
    for I := 0 to Table.RowCount - 1 do
    begin
      Same := False;
      if (Length(Repeated) > 0) and (Length(Groups) > 0) then
      begin
        Same := True;
        for J := 0 to Table.Width - 1 do
        begin
          if J >= Length(Table.Header) then Break;
          Name := Table.Header[J];
          if MatchesAnyPrefix(Name, Repeated, AOptions.PathSeparator) then
            Continue;
          if Table.CellAt(I, J) <>
             Table.CellAt(Groups[High(Groups)], J) then
          begin
            Same := False;
            Break;
          end;
        end;
      end;
      if not Same then Groups := Groups + [I];
    end;

    { Every row read so far is this read's until it is handed back; a later
      row that fails frees them. Rows is filled in order, so the rows not
      yet read are empty values. }
    Reader := TCsvRowReader.Create(Table, AOptions, nil);
    try
      try
        SetLength(Rows, Length(Groups));
        for I := 0 to Integer(High(Groups)) do
        begin
          Rows[I] := Reader.ReadRow(RowPlan.BoundPlan, Groups[I], TValue.Empty);
          if Length(Repeated) > 0 then
          begin
            if I < High(Groups) then J := Groups[I + 1] - 1
            else J := Table.RowCount - 1;
            Reader.MergeRepeated(RowPlan.BoundPlan, Rows[I], Groups[I], J,
              Repeated);
          end;
        end;

        if not IsMany then
        begin
          if Length(Rows) = 0 then
            raise ECsvInputError.Create(
              'This document has no data rows, and one value was asked for. ' +
              'Deserialize an array or a list to read a table of any length.');
          { A single value was asked for: rows past the first are not
            returned, and are not left alive either. }
          for I := 1 to Integer(High(Rows)) do
            TSerializationOwnership.ReleaseBuilt(RowPlan.TypeInfo, Rows[I],
              TValue.Empty);
          Exit(Rows[0]);
        end;

        case Collection.Kind of
          TCsvMemberKind.ArrayValue:
            begin
              if not TSerializationTypes.TryMakeArray(Collection.TypeInfo, Rows,
                   Arr, Why) then
                raise ECsvInputError.Create(Why + '.');
              Exit(Arr);
            end;
          TCsvMemberKind.ListValue:
            begin
              Container := Collection.ContainerCreate.Invoke(
                GetTypeData(Collection.TypeInfo).ClassType, []).AsObject;
              Added := 0;
              try
                for I := 0 to Integer(High(Rows)) do
                begin
                  AddElement(Collection, Container, Rows[I], '$');
                  Added := I + 1;
                end;
              except
                { The rows added go with the container; the others are
                  still this read's alone. }
                TSerializationOwnership.ReleaseBuiltContainer(Container);
                for I := Added to Integer(High(Rows)) do
                  TSerializationOwnership.ReleaseBuilt(RowPlan.TypeInfo,
                    Rows[I], TValue.Empty);
                Rows := nil;
                raise;
              end;
              TValue.Make(@Container, Collection.TypeInfo, Result);
              Exit;
            end;
        end;
        raise ECsvProjectionError.CreateForPath('$',
          'CSV cannot build this root type from a table.');
      except
        { A record row holds the objects read into it. }
        for I := 0 to Integer(High(Rows)) do
          TSerializationOwnership.ReleaseBuilt(RowPlan.TypeInfo, Rows[I],
            TValue.Empty);
        raise;
      end;
    finally
      Reader.Free;
    end;
  finally
    Table.Free;
  end;
end;

class function TCsvEngine.DeserializeRootTables(ATypeInfo: PTypeInfo;
  ATables: TCsvDocumentSet; const AOptions: TCsvOptions): TValue;
var
  Root: TCsvMemberPlan;
  IsMany: Boolean;
  RowPlan, Collection: TCsvMemberPlan;
  RootDoc: TCsvTableDocument;
begin
  Root := GetRootPlan(ATypeInfo);
  RowPlan := RowPlanOf(Root, IsMany, Collection);
  if not RowPlan.IsComposite then
    raise ECsvProjectionError.CreateForPath('$',
      Format('A CSV table is rows of named columns, and %s has no members ' +
        'to be columns.', [UTF8ToString(ATypeInfo.Name)]));
  if ATables.Count = 0 then
    raise ECsvInputError.Create('This document set holds no tables.');

  { The root table is the one nothing points at. Reading the children back
    into their parents needs the key columns, which a caller who wrote the
    set with SerializeTables still has; reading just the root is what this
    does, and the relationships say what was left out. }
  RootDoc := ATables.TableByName(ATables.RootName);
  Result := DeserializeRoot(ATypeInfo, RootDoc.Content, AOptions);
end;

class function TCsvEngine.InferSchema(const AText: string;
  const AOptions: TCsvOptions): TCsvSchema;
var
  Table: TCsvTable;
  I: Integer;
  Column: TCsvColumn;
  Inferred: TCsvInferred;
begin
  Table := ParseTable(AText, AOptions);
  try
    Result := TCsvSchema.Create;
    try
      Result.Options := AOptions;
      for I := 0 to Table.Width - 1 do
      begin
        Inferred := InferColumn(Table, I, AOptions);
        Column := TCsvColumn.Make(
          IfThen(I < Length(Table.Header), Table.Header[I],
            CsvPositionalColumnName(I)),
          Inferred.ColumnType);
        Column.Nullable := Inferred.Nullable;
        Result.Add(Column);
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    Table.Free;
  end;
end;

class function TCsvEngine.SchemaOfType(ATypeInfo: PTypeInfo;
  const AOptions: TCsvOptions): TCsvSchema;
var
  Root, RowPlan, Collection: TCsvMemberPlan;
  IsMany: Boolean;
begin
  Root := GetRootPlan(ATypeInfo);
  RowPlan := RowPlanOf(Root, IsMany, Collection);
  if not RowPlan.IsComposite then
    raise ECsvProjectionError.CreateForPath('$',
      Format('%s has no members to be columns.', [UTF8ToString(ATypeInfo.Name)]));
  Result := TCsvSchema.Create;
  try
    Result.Options := AOptions;
    Result.TableName := RowPlan.BoundPlan.TableName;
    DescribeInto(Result, RowPlan.BoundPlan, '', '$', AOptions);
  except
    Result.Free;
    raise;
  end;
end;

{ ===========================================================================
  THE STRUCTURAL PATH

  No contract at all: a table in, an array of objects out, and back. The
  types a cell is given are whatever SchemaInference allows, because the
  document itself says nothing.
  =========================================================================== }

function CellToDynamic(const AText: string; AType: TCsvColumnType;
  const AOptions: TCsvOptions): TDynamicValue;
var
  I64: Int64;
  D: Double;
  DT: TDateTime;
  Bytes: TBytes;
begin
  if AOptions.NullPolicy = TCsvNullPolicy.Literal then
    if AText = AOptions.NullLiteral then Exit(TDynamicValue.NewNull);
  if AText = '' then
  begin
    { EmptyField is the default and is NOT reversible: an empty string comes
      back as a null, because the document did not record the difference.
      That is what every other CSV producer does, and saying so is better
      than inventing a distinction the file cannot carry. }
    if AOptions.NullPolicy = TCsvNullPolicy.EmptyField then
      Exit(TDynamicValue.NewNull);
    Exit(TDynamicValue.NewStr(''));
  end;

  case AType of
    TCsvColumnType.Boolean: Exit(TDynamicValue.NewBool(SameText(AText, 'true')));
    TCsvColumnType.Int32, TCsvColumnType.Int64:
      if TryStrToInt64(AText, I64) then Exit(TDynamicValue.NewInt(I64));
    TCsvColumnType.Float:
      if TStructuralText.TryParseFloat(AText, D) then
        Exit(TDynamicValue.NewFloat(D));
    TCsvColumnType.DateTime:
      if TStructuralText.TryDecodeDateTime(AText, DT) then
        Exit(TDynamicValue.NewDateTime(DT));
    TCsvColumnType.Binary:
      if TStructuralText.TryDecodeBinary(AText, Bytes) then
        Exit(TDynamicValue.NewBytes(Bytes));
  end;
  Result := TDynamicValue.NewStr(AText);
end;

class function TCsvEngine.TextToDynamic(const AText: string;
  const ACsv: TCsvOptions;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
var
  Table: TCsvTable;
  Types: TArray<TCsvColumnType>;
  I, R: Integer;
  Row: TDynamicValue;
  Name: string;
begin
  Table := ParseTable(AText, ACsv);
  try
    SetLength(Types, Table.Width);
    for I := 0 to Table.Width - 1 do
      Types[I] := InferColumn(Table, I, ACsv).ColumnType;

    { A table is a SEQUENCE OF ROWS, so it becomes an array of objects -
      always, even for one row. A single object would make the shape depend
      on the data, and a converter whose output shape moves is a converter
      nobody can write against. }
    Result := TDynamicValue.NewArray;
    try
      for R := 0 to Table.RowCount - 1 do
      begin
        Row := TDynamicValue.NewObject;
        Result.AsArray.Adopt(Row);
        for I := 0 to Table.Width - 1 do
        begin
          if I < Length(Table.Header) then Name := Table.Header[I]
          else Name := CsvPositionalColumnName(I);
          Row.AsObject.Adopt(Name, CellToDynamic(Table.CellAt(R, I), Types[I], ACsv));
        end;
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    Table.Free;
  end;
end;

{ One dynamic scalar as a cell. A composite one is the caller's decision,
  made above. }
function DynamicToCellText(AValue: TDynamicValue;
  const AOptions: TCsvOptions; const APath: string;
  out AIsNull: Boolean): string;
begin
  AIsNull := False;
  if (AValue = nil) or (AValue.Kind = TDynamicKind.Null) then
  begin
    if AOptions.NullPolicy = TCsvNullPolicy.Error then
      raise ECsvProjectionError.CreateForPath(APath,
        'This value is null and NullPolicy is Error. CSV has no null: ' +
        'choose EmptyField to write nothing, or Literal to write a marker.');
    AIsNull := True;
    if AOptions.NullPolicy = TCsvNullPolicy.Literal then
      Exit(AOptions.NullLiteral);
    Exit('');
  end;
  case AValue.Kind of
    TDynamicKind.Bool: if AValue.AsBool then Exit('true') else Exit('false');
    TDynamicKind.Int: Exit(IntToStr(AValue.AsInt));
    TDynamicKind.UInt: Exit(UIntToStr(AValue.AsUInt));
    TDynamicKind.Float: Exit(FormatFloatCell(AValue.AsFloat));
    TDynamicKind.Decimal: Exit(AValue.AsDecimal);
    TDynamicKind.Str: Exit(AValue.AsStr);
    TDynamicKind.Bytes: Exit(TStructuralText.EncodeBinary(AValue.AsBytes));
    TDynamicKind.DateTime:
      Exit(TStructuralText.EncodeDateTime(AValue.AsDateTime));
    TDynamicKind.Date: Exit(TStructuralText.EncodeDate(AValue.AsDateTime));
    TDynamicKind.Time: Exit(TStructuralText.EncodeTime(AValue.AsDateTime));
  end;
  Result := '';
end;

{ ===========================================================================
  A STRUCTURAL TREE ONTO ROWS

  The same projection as the Delphi path, mode for mode, read from a dynamic
  tree instead of through a plan: NestedObjectMode and CollectionMode mean
  exactly what they mean there, and every table, key and relationship goes
  through the shared rules above. What a tree does not have is a declared
  key or a type name, so a child table's key is always generated and a table
  is named after the member that holds it.

  One payload (DynamicToText) or a document set (DynamicToTables): the walk
  is the same, and only the second may open separate tables.
  =========================================================================== }

type
  { A collection - or, under NestedObjectMode.SeparateTable, an object -
    found on a row and written after the row's own cells, exactly as the
    Delphi walk defers its collections. }
  TCsvDynamicPending = record
    Name: string;
    Prefix: string;
    Path: string;
    Value: TDynamicValue;
  end;

  TCsvDynamicWriter = class
  strict private
    FCtx: TCsvWriteContext;
    procedure SetScalar(ABuffer: TCsvBuffer; ARow: Integer;
      const AColumn, APath: string; AValue: TDynamicValue);
    procedure SetJsonCell(ABuffer: TCsvBuffer; ARow: Integer;
      const AColumn: string; AValue: TDynamicValue);
    procedure WriteSeparateTable(const APending: TCsvDynamicPending;
      ABuffer: TCsvBuffer; ARow: Integer);
  public
    constructor Create(ACtx: TCsvWriteContext);
    { The row's own cells. A member that becomes a table of its own at the
      document root is left to the caller when ASkipTables is set. }
    procedure WriteComposite(AValue: TDynamicValue; ABuffer: TCsvBuffer;
      ARow: Integer; const APrefix, APath: string; ASkipTables: Boolean;
      var APending: TArray<TCsvDynamicPending>);
    procedure WriteCollections(ABuffer: TCsvBuffer; ARow: Integer;
      const APending: TArray<TCsvDynamicPending>);
    procedure WriteRow(AValue: TDynamicValue; ABuffer: TCsvBuffer;
      const APath: string);
    { The elements of an array as the rows of ABuffer: an object is a row, a
      scalar a row of one column named AColumn. }
    procedure WriteRows(AArray: TDynamicValue; ABuffer: TCsvBuffer;
      const AColumn, APath: string);
    { True when, at the document root, this member is a table of its own. }
    function IsTable(AValue: TDynamicValue): Boolean;
  end;

{ '$.customers[0].orders' as '$.customers.orders': the path that names a
  relationship is the same for every row. }
function ShapePath(const APath: string): string;
var
  I: Integer;
  Depth: Integer;
begin
  Result := '';
  Depth := 0;
  for I := 1 to Length(APath) do
    if APath[I] = '[' then Inc(Depth)
    else if APath[I] = ']' then Dec(Depth)
    else if Depth = 0 then Result := Result + APath[I];
end;

constructor TCsvDynamicWriter.Create(ACtx: TCsvWriteContext);
begin
  inherited Create;
  FCtx := ACtx;
end;

function TCsvDynamicWriter.IsTable(AValue: TDynamicValue): Boolean;
begin
  Result := (AValue <> nil) and
    (((AValue.Kind = TDynamicKind.Arr) and
      (FCtx.Options.CollectionMode = TCsvCollectionMode.SeparateTable)) or
     ((AValue.Kind = TDynamicKind.Obj) and
      (FCtx.Options.NestedObjectMode = TCsvNestedObjectMode.SeparateTable)));
end;

procedure TCsvDynamicWriter.SetScalar(ABuffer: TCsvBuffer; ARow: Integer;
  const AColumn, APath: string; AValue: TDynamicValue);
var
  Text: string;
  IsNull: Boolean;
begin
  if (AValue <> nil) and
     (AValue.Kind in [TDynamicKind.Obj, TDynamicKind.Arr]) then
    raise ECsvProjectionError.CreateForPath(APath,
      Format('%s holds an object or an array where one cell is written. ' +
        'Choose JsonCell, RepeatedRows or SeparateTable for it.', [APath]));
  if (AValue <> nil) and (AValue.Kind = TDynamicKind.Extended) then
    raise ECsvProjectionError.CreateForPath(APath,
      Format('%s carries a %s value, which is an extension of another ' +
        'format. A CSV cell is text and has nowhere to put it.',
        [APath, AValue.ExtendedTag]));
  Text := DynamicToCellText(AValue, FCtx.Options, APath, IsNull);
  if IsNull and (FCtx.Options.NullPolicy <> TCsvNullPolicy.Literal) then
    ABuffer.SetCell(ARow, AColumn, TCsvCell.Null)
  else
    ABuffer.SetCell(ARow, AColumn, TCsvCell.Value(Text));
end;

procedure TCsvDynamicWriter.SetJsonCell(ABuffer: TCsvBuffer; ARow: Integer;
  const AColumn: string; AValue: TDynamicValue);
var
  Json: TStructuralConversionOptions;
  Handler: TSerializationFormatHandler;
begin
  Json := TStructuralConversionOptions.FromProfile(
    TStructuralConversionProfile.Lossless);
  Handler := TSerializationFormats.Require(TSerializationFormat.Json,
    TSerializationFormatCapability.StructuralWrite, Json);
  ABuffer.SetCell(ARow, AColumn,
    TCsvCell.Value(Handler.FromDynamic(AValue, Json).AsTextDocument));
end;

procedure TCsvDynamicWriter.WriteComposite(AValue: TDynamicValue;
  ABuffer: TCsvBuffer; ARow: Integer; const APrefix, APath: string;
  ASkipTables: Boolean; var APending: TArray<TCsvDynamicPending>);
var
  I, J: Integer;
  Name, Column, Path: string;
  Child: TDynamicValue;
  P: TCsvDynamicPending;
begin
  for I := 0 to AValue.Count - 1 do
  begin
    Name := AValue.Names[I];
    Child := AValue.Items[I];
    Column := JoinPath(APrefix, Name, FCtx.Options.PathSeparator);
    Path := MemberPath(APath, Name);

    if Child = nil then Continue;
    if ASkipTables and IsTable(Child) then Continue;

    P.Name := Name;
    P.Prefix := APrefix;
    P.Path := Path;
    P.Value := Child;

    case Child.Kind of
      TDynamicKind.Obj:
        begin
          case FCtx.Options.NestedObjectMode of
            TCsvNestedObjectMode.Flatten:
              WriteComposite(Child, ABuffer, ARow, Column, Path, False,
                APending);
            TCsvNestedObjectMode.JsonCell:
              SetJsonCell(ABuffer, ARow, Column, Child);
            TCsvNestedObjectMode.SeparateTable:
              begin
                if not FCtx.AllowSeparateTables then
                  raise ECsvProjectionError.CreateForPath(Path,
                    CSV_SEPARATE_TABLE_GUIDANCE);
                APending := APending + [P];
              end;
          else
            raise ECsvProjectionError.CreateForPath(Path,
              Format('%s is an object and a CSV cell holds text. Choose a ' +
                'NestedObjectMode - Flatten, JsonCell or SeparateTable - ' +
                'for a conversion with no contract.', [Path]));
          end;
          Continue;
        end;

      TDynamicKind.Arr:
        begin
          case FCtx.Options.CollectionMode of
            TCsvCollectionMode.JsonCell:
              SetJsonCell(ABuffer, ARow, Column, Child);
            TCsvCollectionMode.NumberedColumns:
              for J := 0 to Child.Count - 1 do
              begin
                if (Child.Items[J] <> nil) and
                   (Child.Items[J].Kind in [TDynamicKind.Obj,
                     TDynamicKind.Arr]) then
                  raise ECsvProjectionError.CreateForPath(Path,
                    'NumberedColumns writes one cell per element and these ' +
                    'elements are not scalars. Use SeparateTable or JsonCell.');
                SetScalar(ABuffer, ARow, Column + '_' + IntToStr(J + 1),
                  Format('%s[%d]', [Path, J]), Child.Items[J]);
              end;
            TCsvCollectionMode.RepeatedRows:
              APending := APending + [P];
            TCsvCollectionMode.SeparateTable:
              begin
                if not FCtx.AllowSeparateTables then
                  raise ECsvProjectionError.CreateForPath(Path,
                    CSV_SEPARATE_TABLE_GUIDANCE);
                APending := APending + [P];
              end;
          else
            raise ECsvProjectionError.CreateForPath(Path,
              Format('%s is an array and a CSV cell holds one value. ' +
                'Choose a CollectionMode - JsonCell, RepeatedRows, ' +
                'NumberedColumns or SeparateTable - for a conversion with ' +
                'no contract.', [Path]));
          end;
          Continue;
        end;
    end;

    SetScalar(ABuffer, ARow, Column, Path, Child);
  end;
end;

procedure TCsvDynamicWriter.WriteSeparateTable(
  const APending: TCsvDynamicPending; ABuffer: TCsvBuffer; ARow: Integer);
var
  Child: TCsvBuffer;
  KeyCell: TCsvCell;
  RefColumn: string;
  I, ChildRow: Integer;
  Element: TDynamicValue;
  Nested: TArray<TCsvDynamicPending>;
  Count: Integer;
begin
  { A tree declares no key, so the shared rules generate one. }
  Child := AttachChildTable(FCtx, ABuffer, ARow, '', APending.Name,
    ShapePath(APending.Path), APending.Path, KeyCell, RefColumn);
  if APending.Value.Kind = TDynamicKind.Obj then Count := 1
  else Count := APending.Value.Count;
  for I := 0 to Count - 1 do
  begin
    if APending.Value.Kind = TDynamicKind.Obj then
      Element := APending.Value
    else
      Element := APending.Value.Items[I];
    ChildRow := Child.NewRow;
    Child.SetCell(ChildRow, RefColumn, KeyCell);
    if (Element <> nil) and (Element.Kind = TDynamicKind.Obj) then
    begin
      Nested := nil;
      WriteComposite(Element, Child, ChildRow, '',
        Format('%s[%d]', [APending.Path, I]), False, Nested);
      if Length(Nested) > 0 then WriteCollections(Child, ChildRow, Nested);
    end
    else if (Element <> nil) and (Element.Kind = TDynamicKind.Arr) then
      raise ECsvProjectionError.CreateForPath(APending.Path,
        'A separate table holds rows, and this member''s elements have no ' +
        'row shape.')
    else
      SetScalar(Child, ChildRow, APending.Name,
        Format('%s[%d]', [APending.Path, I]), Element);
  end;
end;

procedure TCsvDynamicWriter.WriteCollections(ABuffer: TCsvBuffer;
  ARow: Integer; const APending: TArray<TCsvDynamicPending>);
var
  P: TCsvDynamicPending;
  I, Target, Multiplying: Integer;
  J: Integer;
  Column: string;
  Element: TDynamicValue;
  Nested: TArray<TCsvDynamicPending>;
  Rows, NextRows: TArray<Integer>;
begin
  Multiplying := 0;
  for P in APending do
    if (P.Value.Kind = TDynamicKind.Arr) and
       (FCtx.Options.CollectionMode = TCsvCollectionMode.RepeatedRows) and
       (P.Value.Count > 1) then Inc(Multiplying);
  CheckMultiplying(FCtx.Options, Multiplying, APending[0].Path);

  Rows := [ARow];
  for P in APending do
  begin
    Column := JoinPath(P.Prefix, P.Name, FCtx.Options.PathSeparator);
    if (P.Value.Kind = TDynamicKind.Obj) or
       (FCtx.Options.CollectionMode = TCsvCollectionMode.SeparateTable) then
    begin
      for J in Rows do WriteSeparateTable(P, ABuffer, J);
      Continue;
    end;

    { RepeatedRows: the first element reuses the row it came from; every
      other one takes a copy of it, so the columns already written are
      carried onto each new row. }
    if P.Value.Count = 0 then Continue;
    NextRows := nil;
    for J in Rows do
      for I := 0 to P.Value.Count - 1 do
      begin
        if I = 0 then Target := J else Target := ABuffer.CloneRow(J);
        NextRows := NextRows + [Target];
        Element := P.Value.Items[I];
        if (Element <> nil) and (Element.Kind = TDynamicKind.Obj) then
        begin
          Nested := nil;
          WriteComposite(Element, ABuffer, Target, Column,
            Format('%s[%d]', [P.Path, I]), False, Nested);
          if Length(Nested) > 0 then
            WriteCollections(ABuffer, Target, Nested);
        end
        else if (Element <> nil) and (Element.Kind = TDynamicKind.Arr) then
          raise ECsvProjectionError.CreateForPath(P.Path,
            'RepeatedRows writes one row per element and these elements ' +
            'have no row shape.')
        else
          SetScalar(ABuffer, Target, Column, Format('%s[%d]', [P.Path, I]),
            Element);
      end;
    Rows := NextRows;
  end;
end;

procedure TCsvDynamicWriter.WriteRow(AValue: TDynamicValue;
  ABuffer: TCsvBuffer; const APath: string);
var
  Row: Integer;
  Pending: TArray<TCsvDynamicPending>;
begin
  Row := ABuffer.NewRow;
  Pending := nil;
  WriteComposite(AValue, ABuffer, Row, '', APath, False, Pending);
  if Length(Pending) > 0 then WriteCollections(ABuffer, Row, Pending);
end;

procedure TCsvDynamicWriter.WriteRows(AArray: TDynamicValue;
  ABuffer: TCsvBuffer; const AColumn, APath: string);
var
  I: Integer;
  Element: TDynamicValue;
  Path: string;
begin
  for I := 0 to AArray.Count - 1 do
  begin
    Element := AArray.Items[I];
    Path := Format('%s[%d]', [APath, I]);
    if (Element <> nil) and (Element.Kind = TDynamicKind.Obj) then
      WriteRow(Element, ABuffer, Path)
    else if (Element <> nil) and (Element.Kind = TDynamicKind.Arr) then
      raise ECsvProjectionError.CreateForPath(Path,
        'A CSV table is rows of named columns, and this element is an ' +
        'array. An array of arrays has no column names; wrap each in an ' +
        'object, or convert to a format that has arrays.')
    else if AColumn = '' then
      raise ECsvProjectionError.CreateForPath(Path,
        'A CSV table is rows of named columns, and this element is not an ' +
        'object. An array of scalars has no column names; wrap each value ' +
        'in an object, or convert to a format that has arrays.')
    else
      SetScalar(ABuffer, ABuffer.NewRow, AColumn, Path, Element);
  end;
end;

class function TCsvEngine.DynamicToText(AValue: TDynamicValue;
  const ACsv: TCsvOptions;
  const AOptions: TStructuralConversionOptions): string;
var
  Ctx: TCsvWriteContext;
  Writer: TCsvDynamicWriter;
  Buffer: TCsvBuffer;
begin
  if AValue = nil then Exit('');
  if not (AValue.Kind in [TDynamicKind.Arr, TDynamicKind.Obj]) then
    raise ECsvProjectionError.CreateForPath('$',
      'A CSV document is a table: rows of named columns. This value is ' +
      'neither an object nor an array of objects, so there are no ' +
      'columns to write.');
  Ctx := TCsvWriteContext.Create(ACsv);
  try
    Ctx.AllowSeparateTables := False;
    Buffer := Ctx.NewBuffer('table');
    Writer := TCsvDynamicWriter.Create(Ctx);
    try
      if AValue.Kind = TDynamicKind.Arr then
        Writer.WriteRows(AValue, Buffer, '', '$')
      else
        { One object is a table of one row. }
        Writer.WriteRow(AValue, Buffer, '$');
    finally
      Writer.Free;
    end;
    Result := Buffer.Render(ACsv);
  finally
    Ctx.Free;
  end;
end;

{ THE DOCUMENT ROOT, which has no name.

  A root array is the table 'root', one row per element. A root object is a
  set of tables: each member that is a table of its own - an array under
  CollectionMode.SeparateTable, an object under
  NestedObjectMode.SeparateTable - is a top-level table named after the
  member ('customers'), and everything else on the root object is the
  one-row table 'root', written only when there is something in it. The
  top-level tables are not children of 'root': there is one root row, and a
  key generated for it would join nothing to anything.

  Nothing is recognised by name. A member called 'rows' next to one called
  'fields' is two tables, as any other two members would be. }
class function TCsvEngine.DynamicToTables(AValue: TDynamicValue;
  const ACsv: TCsvOptions): TCsvDocumentSet;
var
  Ctx: TCsvWriteContext;
  Writer: TCsvDynamicWriter;
  Buffer: TCsvBuffer;
  I, N: Integer;
  HasRootCells: Boolean;
  Name, Unique: string;
  Child: TDynamicValue;
  Pending: TArray<TCsvDynamicPending>;
  Row: Integer;
begin
  if (AValue = nil) or
     not (AValue.Kind in [TDynamicKind.Arr, TDynamicKind.Obj]) then
    raise ECsvProjectionError.CreateForPath('$',
      'A CSV document set is tables: rows of named columns. This value is ' +
      'neither an object nor an array of objects, so there are no tables ' +
      'to write.');
  Ctx := TCsvWriteContext.Create(ACsv);
  try
    Ctx.AllowSeparateTables := True;
    Writer := TCsvDynamicWriter.Create(Ctx);
    try
      if AValue.Kind = TDynamicKind.Arr then
        Writer.WriteRows(AValue, Ctx.NewBuffer('root'), '', '$')
      else
      begin
        HasRootCells := False;
        for I := 0 to AValue.Count - 1 do
          if (AValue.Items[I] <> nil) and not Writer.IsTable(AValue.Items[I]) then
          begin
            HasRootCells := True;
            Break;
          end;
        if HasRootCells then
        begin
          Buffer := Ctx.NewBuffer('root');
          Row := Buffer.NewRow;
          Pending := nil;
          Writer.WriteComposite(AValue, Buffer, Row, '', '$', True, Pending);
          if Length(Pending) > 0 then
            Writer.WriteCollections(Buffer, Row, Pending);
        end;
        for I := 0 to AValue.Count - 1 do
        begin
          Child := AValue.Items[I];
          if not Writer.IsTable(Child) then Continue;
          Name := AValue.Names[I];
          Unique := Name;
          N := 2;
          while Ctx.HasBufferNamed(Unique) do
          begin
            Unique := Name + ACsv.RelationshipNaming.CollisionSuffix +
              IntToStr(N);
            Inc(N);
          end;
          Buffer := Ctx.NewBuffer(Unique);
          if Child.Kind = TDynamicKind.Arr then
            Writer.WriteRows(Child, Buffer, Name, '$.' + Name)
          else
            Writer.WriteRow(Child, Buffer, '$.' + Name);
        end;
      end;
    finally
      Writer.Free;
    end;
    Result := DocumentSetOf(Ctx);
  finally
    Ctx.Free;
  end;
end;

initialization
  { Every number and every date in a CSV file written here is spelled the
    same way whatever machine writes it: a point for the decimal separator,
    no thousands separator, and the ISO order for a date.

    This is not a preference. A file written on a machine whose locale uses
    a comma for the decimal point and a comma for the field delimiter is a
    file nothing can read back - the separator and the delimiter become the
    same character - and a file whose dates are dd/mm on one machine and
    mm/dd on another is worse, because it parses. }
  GInvariant := TFormatSettings.Invariant;

end.
