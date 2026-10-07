unit ConverterForm;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  LIVE FORMAT CONVERTER

  Everything this library does structurally, on one window, driven by real
  calls rather than by a canned script - laid out so that the one thing a
  first-time user came for is obvious in seconds:

        SOURCE                  CONVERT ->                  RESULT
        format, editor          Natural | Lossless |        format, Payload |
        Load sample             Strict                      DataSet tabs,
                                                            Copy, Save

  Everything else is progressive disclosure:

    a SCHEMA CARD appears on the side whose format needs one - Protobuf a
    descriptor and a message type, Avro a schema, ASN.1 a module and a root
    type - and is hidden otherwise;

    a BINARY result is shown as hex (or base64, or the format's own
    standard text form where it has one) with its size - never as bytes run
    through a UTF-8 decoder;

    the DATASET tab projects either document into a live TFDMemTable, shows
    the schema that came out of it and the detector's verdict as text, and
    writes the table back out in any format under any policy.

  The status area says what happened in one line - "Converted successfully",
  "Schema required", "Representation refused" - and names the lossless route
  when one was composed. The raw exception text is behind Details... .

  The format lists come from the REGISTRY. Nothing here has a hard-coded
  list of formats, so a format added later appears with no edit to this file.

  The form is built in code. There is no .dfm, which means the whole layout
  is readable in one file and the demo compiles from the command line like
  every other one here. Standard VCL only: the flat buttons are TButton with
  BS_OWNERDRAW, which is how TBitBtn has always drawn itself.
  --------------------------------------------------------------------------- }

interface

uses
  Winapi.Windows, Winapi.Messages,
  System.SysUtils, System.Classes, System.TypInfo, System.UITypes,
  System.IOUtils, System.Generics.Collections, System.Math,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  Vcl.Grids, Vcl.DBGrids, Vcl.Graphics, Vcl.Dialogs, Vcl.Clipbrd,
  Data.DB, FireDAC.Comp.Client,
  PascalForge.Serialization.Core,
  PascalForge.Serialization,
  PascalForge.Bson,
  PascalForge.Cbor,
  PascalForge.Csv,
  PascalForge.Protobuf.Schema,
  PascalForge.Avro.Schema,
  PascalForge.Asn1,
  PascalForge.Asn1.Schema,
  PascalForge.DataSet;

type
  { How bytes are shown, or typed. A binary document is bytes; a memo holds
    text. One of these has to give, and the reader decides which.

    NativeText is the format's OWN standard text form - MongoDB Extended
    JSON for BSON, RFC 8949 diagnostic notation for CBOR. It is offered only
    where one exists. What it is never is the bytes run through a UTF-8
    decoder: that produces mojibake and a reader who believes it. }
  TBinaryDisplay = (NativeText, Hex, Base64);

  TStatusKind = (Info, Success, Warning, Error);

  { A flat button in standard VCL: a TButton that draws itself. Primary is
    the one accent-coloured action; Toggled is a segment of a segmented
    selector. Keyboard focus, Space, Enter and the tab order are all still
    the button's own. }
  TFlatButton = class(TButton)
  strict private
    FCanvas: TCanvas;
    FPrimary: Boolean;
    FChecked: Boolean;
    FHot: Boolean;
    FFocusedLook: Boolean;
    procedure SetPrimary(AValue: Boolean);
    procedure SetToggled(AValue: Boolean);
    procedure CNDrawItem(var Message: TWMDrawItem); message CN_DRAWITEM;
    procedure CMMouseEnter(var Message: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
    procedure CMEnabledChanged(var Message: TMessage); message CM_ENABLEDCHANGED;
    procedure WMLButtonDblClk(var Message: TWMLButtonDblClk); message WM_LBUTTONDBLCLK;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure SetButtonStyle(ADefault: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property Primary: Boolean read FPrimary write SetPrimary;
    property Toggled: Boolean read FChecked write SetToggled;
  end;

  TLiveConverterForm = class(TForm)
  strict private
    FSeq: Integer;

    { header }
    FTitle: TLabel;
    FSubtitle: TLabel;

    { the conversion mode, one selector and one line }
    FModeButtons: array[TStructuralConversionProfile] of TFlatButton;
    FModeHint: TLabel;
    FProfile: TStructuralConversionProfile;

    { the two columns }
    FBody: TPanel;
    FSourceOuter: TPanel;
    FMiddle: TPanel;
    FResultOuter: TPanel;

    { SOURCE }
    FSourceFormat: TComboBox;
    FSourceBytesLabel: TLabel;
    FSourceBytesAs: TComboBox;
    FLoadSample: TFlatButton;
    FSource: TMemo;

    { between them }
    FConvert: TFlatButton;
    FSwap: TFlatButton;

    { RESULT }
    FDestFormat: TComboBox;
    FCopy: TFlatButton;
    FSave: TFlatButton;
    FPages: TPageControl;
    FPayloadTab: TTabSheet;
    FDataSetTab: TTabSheet;
    FViewBar: TPanel;
    FViewButtons: array[TBinaryDisplay] of TFlatButton;
    FResultView: TBinaryDisplay;
    FSizeLabel: TLabel;
    FResult: TMemo;

    { CSV: one contextual control, shown only when the result is CSV, and
      the document set "Separate tables" produces - several CSV documents,
      shown one at a time and never concatenated. }
    FCsvBar: TPanel;
    FCsvProjection: TComboBox;
    FTableBar: TPanel;
    FTableCombo: TComboBox;
    FTableRows: TLabel;
    FRelationLabel: TLabel;
    FTables: TCsvDocumentSet;

    { what the result IS, as opposed to how it is shown }
    FLastResult: TSerializationPayload;
    FLastResultFormat: TSerializationFormat;
    FHasResult: Boolean;

    { the schema cards, index 0 = source side, 1 = result side }
    FCtxCard: array[0..1] of TPanel;
    FCtxTitle: array[0..1] of TLabel;
    FCtxInfo: array[0..1] of TLabel;
    FCtxPath: array[0..1] of TEdit;
    FCtxBrowse: array[0..1] of TFlatButton;
    FCtxLoad: array[0..1] of TFlatButton;
    FCtxRootLabel: array[0..1] of TLabel;
    FCtxRoot: array[0..1] of TComboBox;

    { the DataSet tab }
    FSourceMode: TComboBox;
    FFromSource: TFlatButton;
    FFromResult: TFlatButton;
    FDetected: TLabel;
    FTable: TFDMemTable;
    FDataSource: TDataSource;
    FGrid: TDBGrid;
    FSchemaGrid: TStringGrid;
    FDataSetFormat: TComboBox;
    FDataSetPolicy: TComboBox;
    FSerializeDataSet: TFlatButton;

    { the status area }
    FStatusStripe: TPanel;
    FStatusSummary: TLabel;
    FStatusSecondary: TLabel;
    FDetailsButton: TFlatButton;
    FStatusKind: TStatusKind;
    FStatusDetails: string;

    { What the conversion still needs, in words. }
    FCapabilityText: string;
    FSwallowChar: Boolean;
    { Which sample Load sample shows next. }
    FSampleIndex: Integer;

    { The formats behind the dropdown entries, so the selection does not
      depend on the order the registry happened to return. }
    FParseFormats: TArray<TSerializationFormat>;
    FWriteFormats: TArray<TSerializationFormat>;

    { THE SCHEMAS THIS WINDOW HAS BEEN GIVEN, owned here.

      A context is BORROWED by every call that uses it - the conversion does
      not take ownership and must not, or a second conversion would be
      reading freed memory - so the form holds them for as long as it lives
      and hands out pointers. }
    FProtoSchema: TProtobufSchema;
    FProtoMessage: string;
    FProtoPath: string;
    FAvroSchema: TAvroSchema;
    FAvroPath: string;
    FAsn1Schema: TAsn1Schema;
    FAsn1Root: string;
    FAsn1Path: string;
    FContexts: TObjectList<TSerializationContext>;

    { --- building ------------------------------------------------------- }
    procedure Place(AControl: TControl; AAlign: TAlign);
    function NewPanel(AParent: TWinControl; AAlign: TAlign; ASize: Integer;
      AColor: TColor): TPanel;
    function NewCard(AParent: TWinControl; AAlign: TAlign; ASize: Integer;
      out AInner: TPanel): TPanel;
    function NewLabel(AParent: TWinControl; const AText: string;
      AAlign: TAlign = alLeft): TLabel;
    function NewSection(AParent: TWinControl; const AText: string): TLabel;
    function NewCombo(AParent: TWinControl; AWidth: Integer;
      const AItems: array of string): TComboBox;
    function NewButton(AParent: TWinControl; const ACaption: string;
      AWidth: Integer; AAlign: TAlign; AOnClick: TNotifyEvent): TFlatButton;
    function NewMemo(AParent: TWinControl): TMemo;
    procedure BuildHeader;
    procedure BuildModeBar;
    procedure BuildBody;
    procedure BuildSourceColumn(AInner: TPanel);
    procedure BuildResultColumn(AInner: TPanel);
    procedure BuildContextCard(AParent: TWinControl; ASide: Integer);
    procedure BuildDataSetTab;
    procedure BuildStatus;
    procedure FillFormatCombos;
    procedure DoBodyResize(Sender: TObject);
    procedure DoMiddleResize(Sender: TObject);

    { --- the schema-driven half ----------------------------------------- }
    function ContextDirectory: string;
    function SideFormat(ASide: Integer): TSerializationFormat;
    function HasContextFor(AFormat: TSerializationFormat): Boolean;
    function ContextFor(AFormat: TSerializationFormat): TSerializationContext;
    procedure InvalidateContexts;
    procedure LoadContextFile(ASide: Integer; const APath: string);
    procedure RefreshCard(ASide: Integer);
    procedure RefreshCards;
    procedure RefreshCapability;
    procedure DoCtxLoad(Sender: TObject);
    procedure DoCtxBrowse(Sender: TObject);
    procedure DoCtxRootChanged(Sender: TObject);

    function OptionsFor(AFrom, ATo: TSerializationFormat):
      TStructuralConversionOptions;
    function ContextSentence(AFrom, ATo: TSerializationFormat): string;

    { --- selections ------------------------------------------------------ }
    function FormatIndex(AFormat: TSerializationFormat): Integer;
    function SelectedSourceFormat: TSerializationFormat;
    function SelectedDestFormat: TSerializationFormat;
    function SelectedDataSetFormat: TSerializationFormat;
    function SelectedSourceMode: TDataSetSourceMode;
    function SelectedPolicy: TDataSetSerializationPolicy;
    function SelectedSourceBytes: TBinaryDisplay;
    procedure SetSourceBytes(ADisplay: TBinaryDisplay);

    { --- payloads -------------------------------------------------------- }
    function SourcePayload: TSerializationPayload;
    function Render(const APayload: TSerializationPayload;
      AFormat: TSerializationFormat; ADisplay: TBinaryDisplay): string;
    procedure ShowResult(const APayload: TSerializationPayload;
      AFormat: TSerializationFormat);
    procedure RenderResult;
    procedure ClearResult;

    { --- CSV tables ------------------------------------------------------ }
    function SelectedCsvOptions: TCsvOptions;
    function IsSeparateTables: Boolean;
    procedure ShowTables(ATables: TCsvDocumentSet);
    procedure ShowTable(AIndex: Integer);
    procedure DropTables;
    procedure SaveTablesTo(const AFolder: string);
    procedure DoCsvProjectionChanged(Sender: TObject);
    procedure DoTableChanged(Sender: TObject);

    { --- status ---------------------------------------------------------- }
    procedure SetStatus(AKind: TStatusKind; const ASummary, ASecondary: string;
      const ADetails: string = '');
    procedure Failed(E: Exception; const AAction: string);
    procedure ShowSchema(ADataSet: TDataSet);

    { --- visibility ------------------------------------------------------ }
    procedure UpdateModeButtons;
    procedure UpdateViewBar;

    { --- actions --------------------------------------------------------- }
    procedure DoConvert(Sender: TObject);
    procedure DoSwap(Sender: TObject);
    procedure DoLoadSample(Sender: TObject);
    procedure DoFromSource(Sender: TObject);
    procedure DoFromResult(Sender: TObject);
    procedure DoSerializeDataSet(Sender: TObject);
    procedure DoFormatChanged(Sender: TObject);
    procedure DoModeClick(Sender: TObject);
    procedure DoViewClick(Sender: TObject);
    procedure DoCopy(Sender: TObject);
    procedure DoSave(Sender: TObject);
    procedure DoDetails(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormKeyPress(Sender: TObject; var Key: Char);

    function ResultClipboardText: string;
    procedure SaveResultTo(const APath: string);

    procedure ProjectInto(const APayload: TSerializationPayload;
      AFormat: TSerializationFormat);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { --- the headless self-test -----------------------------------------

      Every control on this form, pressed in order, with the results checked
      and printed. It exists because a window nobody opens is a demo nobody
      knows is broken: the build runs this and a regression shows up as a
      failing line rather than as a screenshot somebody did not take.

      Returns the number of failures. }
    function SelfTest: Integer;
  end;

var
  LiveConverterForm: TLiveConverterForm;

{ Every exception RAISED - caught or not - between these two calls, as
  "ClassName: Message". A debugger breaks on a first-chance exception even
  when the code handles it, so a window that raises one while it opens is a
  window whose first impression is an exception dialog. The self-test counts
  them through System.RaiseExceptObjProc, chained to whatever was there. }
procedure StartCountingExceptions;
procedure StopCountingExceptions;
function CountedExceptions: TArray<string>;

implementation

var
  GPreviousRaiseHook: Pointer;
  GCounting: Boolean;
  GCounted: TArray<string>;

procedure CountingRaiseHook(P: PExceptionRecord);
var
  Obj: TObject;
begin
  if GCounting and (P <> nil) then
  begin
    Obj := TObject(P^.ExceptObject);
    if Obj is Exception then
      GCounted := GCounted + [Obj.ClassName + ': ' + Exception(Obj).Message]
    else if Obj <> nil then
      GCounted := GCounted + [Obj.ClassName]
    else
      GCounted := GCounted + ['(no exception object)'];
  end;
  if GPreviousRaiseHook <> nil then
    TRaiseExceptObjProc(GPreviousRaiseHook)(P);
end;

procedure StartCountingExceptions;
begin
  if GCounting then Exit;
  GCounted := nil;
  GPreviousRaiseHook := RaiseExceptObjProc;
  RaiseExceptObjProc := @CountingRaiseHook;
  GCounting := True;
end;

procedure StopCountingExceptions;
begin
  if not GCounting then Exit;
  GCounting := False;
  RaiseExceptObjProc := GPreviousRaiseHook;
  GPreviousRaiseHook := nil;
end;

function CountedExceptions: TArray<string>;
begin
  Result := GCounted;
end;

const
  { One neutral palette and one accent. TColor is $00BBGGRR. }
  CLR_BACKGROUND   = TColor($00F6F4F3);   { RGB 243,244,246 }
  CLR_CARD         = TColor($00FFFFFF);
  CLR_BORDER       = TColor($00E7E3E0);   { RGB 224,227,231 }
  CLR_BORDER_DARK  = TColor($00D5D1CB);   { RGB 203,209,213 }
  CLR_TEXT         = TColor($0037291F);   { RGB  31, 41, 55 }
  CLR_MUTED        = TColor($0080726B);   { RGB 107,114,128 }
  CLR_ACCENT       = TColor($00EB6325);   { RGB  37, 99,235 }
  CLR_ACCENT_HOT   = TColor($00D84E1D);   { RGB  29, 78,216 }
  CLR_ACCENT_DOWN  = TColor($00AF401E);   { RGB  30, 64,175 }
  CLR_ACCENT_LIGHT = TColor($00FEEADB);   { RGB 219,234,254 }
  CLR_ACCENT_OFF   = TColor($00F5CDB0);   { RGB 176,205,245 }
  CLR_HOVER        = TColor($00FAF9F8);
  CLR_PRESSED      = TColor($00EDEAE7);
  CLR_CONTEXT      = TColor($00FCFAF8);   { RGB 248,250,252 }
  CLR_SUCCESS      = TColor($004AA316);   { RGB  22,163, 74 }
  CLR_WARNING      = TColor($000677D9);   { RGB 217,119,  6 }
  CLR_ERROR        = TColor($002626DC);   { RGB 220, 38, 38 }

  MODE_HINTS: array[TStructuralConversionProfile] of string = (
    'Best destination-native representation.',
    'Preserve semantic information using published standard mappings.',
    'Reject adaptations that would lose or change meaning.');

  { A realistic document rather than a toy one: a Georgian name, a member
    name JSON allows and XML does not, an embedded XML document as a
    STRING, an empty list, a null, and numbers of both kinds. }
  GEO_NAME  = #$10D2#$10D8#$10DA#$10DD#$10EA#$10D0;
  GEO_CITY  = #$10DB#$10E1#$10DD#$10E4#$10DA#$10D8#$10DD;

type
  { For the parent's Color, which TControl keeps protected. }
  TControlHack = class(TControl);

  { An input the demo itself refused - wrong hex, no result yet - as opposed
    to anything the library raised. Its message is written for the user. }
  EConverterInput = class(Exception);

{ The document the three bundled contexts describe. subject.desc,
  subject.avsc and subject.asn all declare the same four members, so ONE
  document can be pushed through all three - which is the point: the shape
  comes from the context and the machinery above it does not change. }
function SampleSubject: string;
begin
  Result := '{"id":4611686018427387903,"name":"Alice",' +
            '"city":"Midtown","active":true}';
end;

function SampleJson: string;
begin
  Result :=
    '{' +
    '"$type":"Subject",' +
    '"Id":4611686018427387903,' +
    '"Name":"' + GEO_NAME + '",' +
    '"City":"' + GEO_CITY + '",' +
    '"Rate":1.5,' +
    '"Active":true,' +
    '"Rating":null,' +
    '"Tags":[],' +
    '"XmlMessage":"<Reply xmlns=\"urn:demo\"><Ok>true</Ok></Reply>",' +
    '"Lines":[' +
      '{"Sku":"A-1","Qty":2},' +
      '{"Sku":"B-2","Qty":5}' +
    ']' +
    '}';
end;

function SampleTable: string;
begin
  { The DataSet packet shape, so the detector has something to recognize.
    The type numbers are TFieldType ordinals: 3 is ftInteger, 24 is
    ftWideString and 7 is ftCurrency - and ftCurrency is the point of the
    sample, because no amount of inference from a JSON number could have
    worked out that 10.5 is money. }
  Result :=
    '{"fields":[' +
      '{"name":"Id","type":3,"size":0,"required":true},' +
      '{"name":"Name","type":24,"size":60,"required":false},' +
      '{"name":"Amount","type":7,"size":0,"required":false}],' +
    '"rows":[' +
      '{"Id":1,"Name":"' + GEO_NAME + '","Amount":10.5},' +
      '{"Id":2,"Name":"' + GEO_CITY + '","Amount":20.25}]}';
end;

{ Two collections side by side: two tables, and one CSV document cannot be
  both. }
function SampleCustomersAndOrders: string;
begin
  Result := '{"customers":[{"id":1,"name":"A"},{"id":2,"name":"B"}],' +
    '"orders":[{"id":10,"customerId":1},{"id":11,"customerId":2}]}';
end;

{ A collection inside a collection: a child table, joined to its parent. }
function SampleNestedOrders: string;
begin
  Result := '{"customers":[{"id":1,"name":"A","orders":' +
    '[{"id":10,"amount":5.5},{"id":11,"amount":8.0}]}]}';
end;

{ A BSON document with the element types JSON has no answer for, so that the
  Natural and Lossless modes and the binary views have something to be
  different about.

  Written as Extended JSON and read back, rather than assembled element by
  element - which is shorter, is readable in the source, and exercises the
  Extended JSON reader on the way past. }
function SampleExtendedJson: string;
begin
  Result :=
    '{' +
    '"_id":{"$oid":"507f1f77bcf86cd799439011"},' +
    '"Name":"' + GEO_NAME + '",' +
    '"City":"' + GEO_CITY + '",' +
    '"Count":42,' +
    '"CreatedAt":{"$date":{"$numberLong":"1773480413120"}},' +
    '"Blob":{"$binary":{"base64":"AQID+v8=","subType":"00"}},' +
    '"Money":{"$numberDecimal":"123.45"}' +
    '}';
end;

function SampleBson: TBytes;
begin
  Result := TBsonSerializer.FromExtendedJson(SampleExtendedJson);
end;

{ ------------------------------------------------------------- helpers -- }

{ What a person calls the format. The registry's own name is the fallback, so
  a format added later still gets a caption. }
function FormatLabel(AFormat: TSerializationFormat): string;
var
  N: string;
begin
  N := TSerializationFormats.FormatName(AFormat);
  if N = 'Json' then Exit('JSON');
  if N = 'Xml' then Exit('XML');
  if N = 'Bson' then Exit('BSON');
  if N = 'Cbor' then Exit('CBOR');
  if N = 'Yaml' then Exit('YAML');
  if N = 'Csv' then Exit('CSV');
  if N = 'Asn1Ber' then Exit('ASN.1 BER');
  if N = 'Asn1Der' then Exit('ASN.1 DER');
  if N = 'Asn1Cer' then Exit('ASN.1 CER');
  Result := N;
end;

function ProfileName(AProfile: TStructuralConversionProfile): string;
begin
  Result := GetEnumName(TypeInfo(TStructuralConversionProfile), Ord(AProfile));
end;

function IsBinaryFormat(AFormat: TSerializationFormat): Boolean;
begin
  Result := TSerializationFormats.Get(AFormat).PayloadKind =
    TSerializationPayloadKind.Binary;
end;

{ Only these two have a standard text form a human reads: MongoDB Extended
  JSON and RFC 8949 diagnostic notation. }
function HasTextForm(AFormat: TSerializationFormat): Boolean;
begin
  Result := AFormat in [TSerializationFormat.Bson, TSerializationFormat.Cbor];
end;

function Compact(const AText: string): string;
begin
  Result := StringReplace(AText, ' ', '', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '', [rfReplaceAll]);
  Result := StringReplace(Result, #9, '', [rfReplaceAll]);
end;

{ Sixteen bytes to a line, the way every hex viewer shows them. The reader
  accepts it back with the spaces and line breaks in. }
function HexView(const ABytes: TBytes): string;
var
  SB: TStringBuilder;
  I: Integer;
begin
  SB := TStringBuilder.Create(Length(ABytes) * 3 + 2);
  try
    for I := 0 to High(ABytes) do
    begin
      if I > 0 then
        if I mod 16 = 0 then SB.Append(sLineBreak) else SB.Append(' ');
      SB.Append(IntToHex(ABytes[I], 2));
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function BytesText(ACount: Integer): string;
begin
  if ACount = 1 then Result := '1 byte'
  else Result := Format('%d bytes', [ACount]);
end;

{ The first sentence of a library message, which is written for a person;
  the rest - and the class name - is for Details. }
function FirstSentence(const AText: string): string;
var
  P: Integer;
begin
  Result := Trim(AText);
  P := Pos(#13, Result);
  if P = 0 then P := Pos(#10, Result);
  if P > 0 then Result := Trim(Copy(Result, 1, P - 1));
  P := Pos('. ', Result);
  if P > 0 then Result := Copy(Result, 1, P);
  if Length(Result) > 180 then Result := Copy(Result, 1, 177) + '...';
end;

function Needed(AFormat: TSerializationFormat): string;
begin
  if AFormat = TSerializationFormat.Protobuf then
    Result := 'a Protobuf descriptor (.desc) and a message type'
  else if AFormat = TSerializationFormat.Avro then
    Result := 'an Avro schema (.avsc)'
  else if TSerializationFormats.IsAsn1(AFormat) then
    Result := 'an ASN.1 module and a root type'
  else
    Result := 'nothing';
end;

function FileExtension(AFormat: TSerializationFormat): string;
var
  N: string;
begin
  N := TSerializationFormats.FormatName(AFormat);
  if N = 'MessagePack' then Exit('.msgpack');
  if N = 'Protobuf' then Exit('.pb');
  if N = 'Asn1Ber' then Exit('.ber');
  if N = 'Asn1Der' then Exit('.der');
  if N = 'Asn1Cer' then Exit('.cer');
  Result := '.' + LowerCase(N);
end;

{ =========================================================== TFlatButton == }

constructor TFlatButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FCanvas := TCanvas.Create;
  Height := 28;
  Cursor := crHandPoint;
end;

destructor TFlatButton.Destroy;
begin
  FCanvas.Free;
  inherited;
end;

procedure TFlatButton.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.Style := Params.Style or BS_OWNERDRAW;
end;

{ TButton switches between BS_PUSHBUTTON and BS_DEFPUSHBUTTON as focus
  moves, which would undo BS_OWNERDRAW. TBitBtn overrides this for the same
  reason. }
procedure TFlatButton.SetButtonStyle(ADefault: Boolean);
begin
  if ADefault <> FFocusedLook then
  begin
    FFocusedLook := ADefault;
    Invalidate;
  end;
end;

procedure TFlatButton.SetPrimary(AValue: Boolean);
begin
  if FPrimary = AValue then Exit;
  FPrimary := AValue;
  Invalidate;
end;

procedure TFlatButton.SetToggled(AValue: Boolean);
begin
  if FChecked = AValue then Exit;
  FChecked := AValue;
  Invalidate;
end;

procedure TFlatButton.CMMouseEnter(var Message: TMessage);
begin
  inherited;
  FHot := True;
  Invalidate;
end;

procedure TFlatButton.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  FHot := False;
  Invalidate;
end;

procedure TFlatButton.CMEnabledChanged(var Message: TMessage);
begin
  inherited;
  Invalidate;
end;

procedure TFlatButton.WMLButtonDblClk(var Message: TWMLButtonDblClk);
begin
  { An owner-drawn button gets double clicks as such; a second click is a
    second press. }
  Perform(WM_LBUTTONDOWN, Message.Keys, TMessage(Message).LParam);
end;

procedure TFlatButton.CNDrawItem(var Message: TWMDrawItem);
var
  DIS: PDrawItemStruct;
  R: TRect;
  Down, Focused: Boolean;
  Fill, Border, Ink: TColor;
  S: string;
begin
  DIS := Message.DrawItemStruct;
  FCanvas.Handle := DIS.hDC;
  try
    R := ClientRect;
    Down := DIS.itemState and ODS_SELECTED <> 0;
    Focused := DIS.itemState and ODS_FOCUS <> 0;

    if FPrimary then
    begin
      if not Enabled then Fill := CLR_ACCENT_OFF
      else if Down then Fill := CLR_ACCENT_DOWN
      else if FHot then Fill := CLR_ACCENT_HOT
      else Fill := CLR_ACCENT;
      Border := Fill;
      Ink := clWhite;
    end
    else if FChecked then
    begin
      Fill := CLR_ACCENT_LIGHT;
      Border := CLR_ACCENT;
      Ink := CLR_ACCENT_DOWN;
    end
    else
    begin
      if Down then Fill := CLR_PRESSED
      else if FHot and Enabled then Fill := CLR_HOVER
      else Fill := CLR_CARD;
      Border := CLR_BORDER_DARK;
      if Enabled then Ink := CLR_TEXT else Ink := CLR_BORDER_DARK;
    end;

    if Parent <> nil then
      FCanvas.Brush.Color := TControlHack(Parent).Color
    else
      FCanvas.Brush.Color := CLR_BACKGROUND;
    FCanvas.FillRect(R);
    FCanvas.Brush.Color := Fill;
    FCanvas.Pen.Color := Border;
    FCanvas.RoundRect(R.Left, R.Top, R.Right, R.Bottom, 6, 6);

    FCanvas.Font.Assign(Font);
    FCanvas.Font.Color := Ink;
    FCanvas.Brush.Style := bsClear;
    S := Caption;
    DrawText(FCanvas.Handle, PChar(S), Length(S), R,
      DT_CENTER or DT_VCENTER or DT_SINGLELINE or DT_NOPREFIX);

    if Focused and Enabled then
    begin
      InflateRect(R, -3, -3);
      FCanvas.Brush.Style := bsSolid;
      FCanvas.Brush.Color := Fill;
      Winapi.Windows.DrawFocusRect(FCanvas.Handle, R);
    end;
  finally
    FCanvas.Handle := 0;
  end;
end;

{ --------------------------------------------------------------- building -- }

constructor TLiveConverterForm.Create(AOwner: TComponent);
begin
  { CreateNew rather than Create: there is no .dfm to load. }
  inherited CreateNew(AOwner);
  Caption := 'Live Format Converter - PascalForge';
  Width := 1240;
  Height := 860;
  Constraints.MinWidth := 960;
  Constraints.MinHeight := 640;
  Position := poScreenCenter;
  Color := CLR_BACKGROUND;
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  Font.Color := CLR_TEXT;
  KeyPreview := True;
  OnKeyDown := FormKeyDown;
  OnKeyPress := FormKeyPress;

  FContexts := TObjectList<TSerializationContext>.Create(True);
  FProfile := TStructuralConversionProfile.Natural;
  FResultView := TBinaryDisplay.Hex;

  BuildHeader;
  BuildModeBar;
  BuildBody;
  BuildStatus;
  FillFormatCombos;
  UpdateModeButtons;
  DoLoadSample(nil);
  RefreshCapability;
  DoBodyResize(nil);
  ActiveControl := FSource;
end;

destructor TLiveConverterForm.Destroy;
begin
  { The contexts first, because each of them points at a schema below. }
  FContexts.Free;
  FTables.Free;
  FProtoSchema.Free;
  FAvroSchema.Free;
  FAsn1Schema.Free;
  inherited;
end;

{ Aligned controls are ordered by position. A new one is put past every
  earlier one, so creation order is both visual order and tab order. }
procedure TLiveConverterForm.Place(AControl: TControl; AAlign: TAlign);
begin
  Inc(FSeq);
  AControl.Left := 10000 + FSeq;
  AControl.Top := 10000 + FSeq;
  AControl.Align := AAlign;
end;

function TLiveConverterForm.NewPanel(AParent: TWinControl; AAlign: TAlign;
  ASize: Integer; AColor: TColor): TPanel;
begin
  Result := TPanel.Create(Self);
  Result.Parent := AParent;
  Result.BevelOuter := bvNone;
  Result.ShowCaption := False;
  Result.ParentBackground := False;
  Result.Color := AColor;
  if AAlign in [alTop, alBottom] then Result.Height := ASize
  else if AAlign in [alLeft, alRight] then Result.Width := ASize;
  Place(Result, AAlign);
end;

{ A white card with a one-pixel neutral border: the outer panel is the
  border, the inner one the surface. }
function TLiveConverterForm.NewCard(AParent: TWinControl; AAlign: TAlign;
  ASize: Integer; out AInner: TPanel): TPanel;
begin
  Result := NewPanel(AParent, AAlign, ASize, CLR_BORDER);
  Result.Padding.SetBounds(1, 1, 1, 1);
  AInner := NewPanel(Result, alClient, 0, CLR_CARD);
  AInner.Padding.SetBounds(10, 8, 10, 8);
end;

function TLiveConverterForm.NewLabel(AParent: TWinControl; const AText: string;
  AAlign: TAlign): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  { An auto-sized label that is also stretched by its alignment fights the
    alignment; only a label aligned along one edge sizes itself. }
  Result.AutoSize := AAlign in [alLeft, alTop];
  if AAlign = alRight then Result.Width := 80;
  Result.Caption := AText;
  Result.Layout := tlCenter;
  Result.AlignWithMargins := True;
  Result.Margins.SetBounds(0, 0, 8, 0);
  Place(Result, AAlign);
end;

function TLiveConverterForm.NewSection(AParent: TWinControl;
  const AText: string): TLabel;
begin
  Result := NewLabel(AParent, AText);
  Result.Font.Size := 8;
  Result.Font.Style := [fsBold];
  Result.Font.Color := CLR_MUTED;
  Result.Margins.Right := 12;
end;

function TLiveConverterForm.NewCombo(AParent: TWinControl; AWidth: Integer;
  const AItems: array of string): TComboBox;
var
  S: string;
begin
  Result := TComboBox.Create(Self);
  Result.Parent := AParent;
  Result.Style := csDropDownList;
  Result.Width := AWidth;
  Result.AlignWithMargins := True;
  Result.Margins.SetBounds(0, 3, 8, 0);
  for S in AItems do Result.Items.Add(S);
  if Result.Items.Count > 0 then Result.ItemIndex := 0;
  Place(Result, alLeft);
end;

function TLiveConverterForm.NewButton(AParent: TWinControl;
  const ACaption: string; AWidth: Integer; AAlign: TAlign;
  AOnClick: TNotifyEvent): TFlatButton;
begin
  Result := TFlatButton.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Width := AWidth;
  Result.OnClick := AOnClick;
  Result.AlignWithMargins := True;
  if AAlign = alRight then Result.Margins.SetBounds(6, 1, 0, 1)
  else Result.Margins.SetBounds(0, 1, 6, 1);
  Place(Result, AAlign);
end;

function TLiveConverterForm.NewMemo(AParent: TWinControl): TMemo;
begin
  Result := TMemo.Create(Self);
  Result.Parent := AParent;
  Result.ScrollBars := ssBoth;
  Result.WordWrap := False;
  Result.Font.Name := 'Consolas';
  Result.Font.Size := 10;
  Result.Font.Color := CLR_TEXT;
  Place(Result, alClient);
end;

procedure TLiveConverterForm.BuildHeader;
var
  Header: TPanel;
begin
  Header := NewPanel(Self, alTop, 64, CLR_BACKGROUND);
  Header.Padding.SetBounds(16, 10, 16, 6);
  FTitle := NewLabel(Header, 'Live Format Converter', alTop);
  FTitle.Font.Name := 'Segoe UI Semibold';
  FTitle.Font.Size := 15;
  FTitle.Font.Color := CLR_TEXT;
  FSubtitle := NewLabel(Header,
    'Convert structured data between PascalForge formats', alTop);
  FSubtitle.Font.Size := 10;
  FSubtitle.Font.Color := CLR_MUTED;
end;

procedure TLiveConverterForm.BuildModeBar;
var
  Outer, Inner: TPanel;
  P: TStructuralConversionProfile;
begin
  Outer := NewCard(Self, alTop, 48, Inner);
  Outer.AlignWithMargins := True;
  Outer.Margins.SetBounds(12, 0, 12, 8);
  Inner.Padding.SetBounds(10, 8, 10, 8);

  NewSection(Inner, 'MODE');
  for P := Low(TStructuralConversionProfile) to High(TStructuralConversionProfile) do
  begin
    FModeButtons[P] := NewButton(Inner, ProfileName(P), 84, alLeft, DoModeClick);
    FModeButtons[P].Tag := Ord(P);
    FModeButtons[P].Margins.Right := 2;
  end;
  FModeHint := NewLabel(Inner, '', alClient);
  FModeHint.Margins.Left := 12;
  FModeHint.Font.Color := CLR_MUTED;
end;

procedure TLiveConverterForm.BuildBody;
var
  SourceInner, ResultInner: TPanel;
begin
  FBody := NewPanel(Self, alClient, 0, CLR_BACKGROUND);
  FBody.Padding.SetBounds(12, 0, 12, 8);
  FBody.OnResize := DoBodyResize;

  FSourceOuter := NewCard(FBody, alLeft, 520, SourceInner);
  BuildSourceColumn(SourceInner);

  FMiddle := NewPanel(FBody, alLeft, 136, CLR_BACKGROUND);
  FMiddle.OnResize := DoMiddleResize;
  FConvert := TFlatButton.Create(Self);
  FConvert.Parent := FMiddle;
  FConvert.Caption := 'Convert  ' + #$2192;
  FConvert.Primary := True;
  FConvert.Font.Style := [fsBold];
  FConvert.SetBounds(10, 200, 116, 36);
  FConvert.OnClick := DoConvert;
  FConvert.Hint := 'Convert (Ctrl+Enter)';
  FConvert.ShowHint := True;
  FSwap := TFlatButton.Create(Self);
  FSwap.Parent := FMiddle;
  FSwap.Caption := #$21C4 + '  Swap';
  FSwap.SetBounds(10, 244, 116, 30);
  FSwap.OnClick := DoSwap;
  FSwap.Hint := 'Result becomes the source (Ctrl+Shift+S)';
  FSwap.ShowHint := True;

  FResultOuter := NewCard(FBody, alClient, 0, ResultInner);
  BuildResultColumn(ResultInner);
end;

procedure TLiveConverterForm.BuildSourceColumn(AInner: TPanel);
var
  Bar: TPanel;
begin
  Bar := NewPanel(AInner, alTop, 32, CLR_CARD);
  NewSection(Bar, 'SOURCE');
  FSourceFormat := NewCombo(Bar, 190, []);
  FSourceFormat.OnChange := DoFormatChanged;
  FLoadSample := NewButton(Bar, 'Load sample', 100, alRight, DoLoadSample);
  FLoadSample.Hint := 'Cycle through the samples (Ctrl+L)';
  FLoadSample.ShowHint := True;
  { Only for a binary source: how the bytes in the editor are typed. }
  FSourceBytesLabel := NewLabel(Bar, 'Bytes as');
  FSourceBytesLabel.Font.Color := CLR_MUTED;
  FSourceBytesAs := NewCombo(Bar, 130, ['Hex', 'Base64', 'Standard text form']);

  BuildContextCard(AInner, 0);

  FSource := NewMemo(AInner);
  FSource.AlignWithMargins := True;
  FSource.Margins.SetBounds(0, 6, 0, 0);
end;

procedure TLiveConverterForm.BuildResultColumn(AInner: TPanel);
var
  Bar: TPanel;
  D: TBinaryDisplay;
const
  VIEW_CAPTIONS: array[TBinaryDisplay] of string = ('Text form', 'Hex', 'Base64');
  VIEW_ORDER: array[0..2] of TBinaryDisplay =
    (TBinaryDisplay.Hex, TBinaryDisplay.Base64, TBinaryDisplay.NativeText);
var
  I: Integer;
begin
  Bar := NewPanel(AInner, alTop, 32, CLR_CARD);
  NewSection(Bar, 'RESULT');
  FDestFormat := NewCombo(Bar, 190, []);
  FDestFormat.OnChange := DoFormatChanged;
  FCopy := NewButton(Bar, 'Copy', 72, alRight, DoCopy);
  FSave := NewButton(Bar, 'Save...', 96, alRight, DoSave);

  { Only when the result is CSV: how a document that is not one flat table
    is projected onto CSV. Conservative is TCsvOptions.Default. }
  FCsvBar := NewPanel(AInner, alTop, 30, CLR_CARD);
  NewLabel(FCsvBar, 'CSV projection').Font.Color := CLR_MUTED;
  FCsvProjection := NewCombo(FCsvBar, 160, ['Conservative', 'JSON cell',
    'Repeated rows', 'Separate tables', 'Numbered columns']);
  FCsvProjection.OnChange := DoCsvProjectionChanged;
  FCsvBar.Visible := False;

  BuildContextCard(AInner, 1);

  FPages := TPageControl.Create(Self);
  FPages.Parent := AInner;
  FPages.AlignWithMargins := True;
  FPages.Margins.SetBounds(0, 6, 0, 0);
  Place(FPages, alClient);

  FPayloadTab := TTabSheet.Create(Self);
  FPayloadTab.PageControl := FPages;
  FPayloadTab.Caption := 'Payload';

  FViewBar := NewPanel(FPayloadTab, alTop, 34, CLR_CARD);
  FViewBar.Padding.SetBounds(6, 3, 6, 3);
  NewLabel(FViewBar, 'View').Font.Color := CLR_MUTED;
  for I := 0 to High(VIEW_ORDER) do
  begin
    D := VIEW_ORDER[I];
    FViewButtons[D] := NewButton(FViewBar, VIEW_CAPTIONS[D], 76, alLeft,
      DoViewClick);
    FViewButtons[D].Tag := Ord(D);
    FViewButtons[D].Margins.Right := 2;
  end;
  FSizeLabel := NewLabel(FViewBar, '', alRight);
  FSizeLabel.Font.Style := [fsBold];
  FSizeLabel.Font.Color := CLR_MUTED;

  { A document set: which table, how many rows, and how it joins. }
  FTableBar := NewPanel(FPayloadTab, alTop, 34, CLR_CARD);
  FTableBar.Padding.SetBounds(6, 3, 6, 3);
  NewLabel(FTableBar, 'Table:').Font.Color := CLR_MUTED;
  FTableCombo := NewCombo(FTableBar, 200, []);
  FTableCombo.OnChange := DoTableChanged;
  FTableRows := NewLabel(FTableBar, '', alRight);
  FTableRows.Font.Style := [fsBold];
  FTableRows.Font.Color := CLR_MUTED;
  FTableBar.Visible := False;
  FRelationLabel := NewLabel(FPayloadTab, '', alTop);
  FRelationLabel.Margins.SetBounds(8, 0, 8, 4);
  FRelationLabel.Font.Color := CLR_MUTED;
  FRelationLabel.Visible := False;

  FResult := NewMemo(FPayloadTab);
  FResult.ReadOnly := True;
  FResult.Color := CLR_CARD;

  BuildDataSetTab;

  FPages.ActivePage := FPayloadTab;
end;

procedure TLiveConverterForm.BuildContextCard(AParent: TWinControl;
  ASide: Integer);
var
  Outer, Card, Row1, Row2, Row3: TPanel;
begin
  { Border, then a faintly tinted surface: it is about the conversion rather
    than about either document, and it should look like a note, not like a
    third editor. }
  Outer := NewPanel(AParent, alTop, 98, CLR_BORDER);
  Outer.Padding.SetBounds(1, 1, 1, 1);
  Outer.AlignWithMargins := True;
  Outer.Margins.SetBounds(0, 6, 0, 0);
  Card := NewPanel(Outer, alClient, 0, CLR_CONTEXT);
  Card.Padding.SetBounds(8, 4, 8, 4);
  FCtxCard[ASide] := Outer;

  Row1 := NewPanel(Card, alTop, 24, CLR_CONTEXT);
  FCtxTitle[ASide] := NewLabel(Row1, '');
  FCtxTitle[ASide].Font.Style := [fsBold];
  FCtxInfo[ASide] := NewLabel(Row1, '', alClient);
  FCtxInfo[ASide].EllipsisPosition := epEndEllipsis;

  Row2 := NewPanel(Card, alTop, 32, CLR_CONTEXT);
  FCtxPath[ASide] := TEdit.Create(Self);
  FCtxPath[ASide].Parent := Row2;
  FCtxPath[ASide].AutoSize := False;
  FCtxPath[ASide].TextHint := 'leave empty to load the bundled sample';
  FCtxPath[ASide].AlignWithMargins := True;
  FCtxPath[ASide].Margins.SetBounds(0, 4, 6, 4);
  Place(FCtxPath[ASide], alClient);
  FCtxBrowse[ASide] := NewButton(Row2, '...', 34, alRight, DoCtxBrowse);
  FCtxBrowse[ASide].Tag := ASide;
  FCtxLoad[ASide] := NewButton(Row2, 'Load', 64, alRight, DoCtxLoad);
  FCtxLoad[ASide].Tag := ASide;

  Row3 := NewPanel(Card, alTop, 30, CLR_CONTEXT);
  FCtxRootLabel[ASide] := NewLabel(Row3, '');
  FCtxRootLabel[ASide].AutoSize := False;
  FCtxRootLabel[ASide].Width := 60;
  FCtxRoot[ASide] := NewCombo(Row3, 260, []);
  FCtxRoot[ASide].Tag := ASide;
  FCtxRoot[ASide].OnChange := DoCtxRootChanged;

  Outer.Visible := False;
end;

procedure TLiveConverterForm.BuildDataSetTab;
var
  Top_, Bottom: TPanel;
begin
  FDataSetTab := TTabSheet.Create(Self);
  FDataSetTab.PageControl := FPages;
  FDataSetTab.Caption := 'DataSet';

  Top_ := NewPanel(FDataSetTab, alTop, 34, CLR_CARD);
  Top_.Padding.SetBounds(6, 3, 6, 3);
  NewLabel(Top_, 'Structure').Font.Color := CLR_MUTED;
  FSourceMode := NewCombo(Top_, 160,
    ['Auto', 'Infer structure', 'Embedded structure']);
  FFromSource := NewButton(Top_, 'From source', 100, alLeft, DoFromSource);
  FFromResult := NewButton(Top_, 'From result', 100, alLeft, DoFromResult);

  { The detector's verdict: text, not a control. }
  FDetected := NewLabel(FDataSetTab, 'No table yet.', alTop);
  FDetected.Margins.SetBounds(8, 2, 8, 4);
  FDetected.Font.Color := CLR_MUTED;
  FDetected.EllipsisPosition := epEndEllipsis;

  Bottom := NewPanel(FDataSetTab, alBottom, 36, CLR_CARD);
  Bottom.Padding.SetBounds(6, 4, 6, 4);
  NewLabel(Bottom, 'Write as').Font.Color := CLR_MUTED;
  FDataSetFormat := NewCombo(Bottom, 120, []);
  FDataSetPolicy := NewCombo(Bottom, 140,
    ['Rows only', 'Structure and rows', 'Delta only', 'Delta and structure']);
  FDataSetPolicy.ItemIndex := 1;
  FSerializeDataSet := NewButton(Bottom, 'To source', 84, alLeft,
    DoSerializeDataSet);

  FTable := TFDMemTable.Create(Self);
  FDataSource := TDataSource.Create(Self);
  FDataSource.DataSet := FTable;

  FSchemaGrid := TStringGrid.Create(Self);
  FSchemaGrid.Parent := FDataSetTab;
  FSchemaGrid.Width := 290;
  FSchemaGrid.AlignWithMargins := True;
  FSchemaGrid.Margins.SetBounds(6, 0, 0, 0);
  Place(FSchemaGrid, alRight);
  FSchemaGrid.ColCount := 4;
  FSchemaGrid.RowCount := 2;
  FSchemaGrid.FixedRows := 1;
  FSchemaGrid.FixedCols := 0;
  FSchemaGrid.DefaultRowHeight := 20;
  FSchemaGrid.Options := FSchemaGrid.Options + [goColSizing];
  FSchemaGrid.ColWidths[0] := 90;
  FSchemaGrid.ColWidths[1] := 96;
  FSchemaGrid.ColWidths[2] := 36;
  FSchemaGrid.ColWidths[3] := 58;
  FSchemaGrid.Cells[0, 0] := 'FieldName';
  FSchemaGrid.Cells[1, 0] := 'DataType';
  FSchemaGrid.Cells[2, 0] := 'Size';
  FSchemaGrid.Cells[3, 0] := 'Required';

  FGrid := TDBGrid.Create(Self);
  FGrid.Parent := FDataSetTab;
  FGrid.DataSource := FDataSource;
  Place(FGrid, alClient);
end;

procedure TLiveConverterForm.BuildStatus;
var
  Outer, Inner, Texts: TPanel;
begin
  Outer := NewCard(Self, alBottom, 58, Inner);
  Outer.AlignWithMargins := True;
  Outer.Margins.SetBounds(12, 0, 12, 12);
  Inner.Padding.SetBounds(0, 6, 10, 6);

  FStatusStripe := NewPanel(Inner, alLeft, 4, CLR_ACCENT);
  FStatusStripe.AlignWithMargins := True;
  FStatusStripe.Margins.SetBounds(0, 0, 10, 0);

  FDetailsButton := NewButton(Inner, 'Details...', 90, alRight, DoDetails);
  FDetailsButton.Margins.SetBounds(6, 6, 0, 6);

  Texts := NewPanel(Inner, alClient, 0, CLR_CARD);
  FStatusSummary := NewLabel(Texts, '', alTop);
  FStatusSummary.AutoSize := False;
  FStatusSummary.Height := 22;
  FStatusSummary.Font.Style := [fsBold];
  FStatusSummary.EllipsisPosition := epEndEllipsis;
  FStatusSecondary := NewLabel(Texts, '', alTop);
  FStatusSecondary.AutoSize := False;
  FStatusSecondary.Height := 18;
  FStatusSecondary.Font.Color := CLR_MUTED;
  FStatusSecondary.EllipsisPosition := epEndEllipsis;
end;

procedure TLiveConverterForm.DoBodyResize(Sender: TObject);
var
  Avail: Integer;
begin
  { Two equal columns either side of the Convert strip. Resizes arrive
    while the columns are still being built, so nothing is assumed. }
  if (FMiddle = nil) or (FSourceOuter = nil) then Exit;
  Avail := FBody.ClientWidth - FBody.Padding.Left - FBody.Padding.Right -
    FMiddle.Width;
  FSourceOuter.Width := Max(300, Avail div 2);
end;

procedure TLiveConverterForm.DoMiddleResize(Sender: TObject);
var
  Y: Integer;
begin
  if (FConvert = nil) or (FSwap = nil) then Exit;
  Y := Max(40, (FMiddle.ClientHeight - 74) div 2);
  FConvert.SetBounds(10, Y, FMiddle.ClientWidth - 20, 36);
  FSwap.SetBounds(10, Y + 44, FMiddle.ClientWidth - 20, 30);
end;

procedure TLiveConverterForm.FillFormatCombos;
var
  F: TSerializationFormat;
  Name: string;
  Parse: TList<TSerializationFormat>;
begin
  { EVERY REGISTERED FORMAT, from the registry rather than from a list in
    this file. The three whose schema lives outside their documents are in
    here with the rest: they are registered, the application has linked
    them, and the schema card is what makes them usable. Hiding them would
    teach a user that the library does not have them. }
  Parse := TList<TSerializationFormat>.Create;
  try
    for F := Low(TSerializationFormat) to High(TSerializationFormat) do
      if TSerializationFormats.IsRegistered(F) then Parse.Add(F);
    FParseFormats := Parse.ToArray;
  finally
    Parse.Free;
  end;
  FWriteFormats := FParseFormats;

  FSourceFormat.Items.Clear;
  FDestFormat.Items.Clear;
  FDataSetFormat.Items.Clear;
  for F in FParseFormats do
  begin
    Name := FormatLabel(F);
    { A format that needs one says so in the list itself, so the reason a
      conversion is not available is visible before it is chosen. }
    if TSerialization.StructuralRequirement(F) = 'schema' then
      Name := Name + ' (needs a schema)';
    FSourceFormat.Items.Add(Name);
    FDestFormat.Items.Add(Name);
    FDataSetFormat.Items.Add(Name);
  end;

  if FSourceFormat.Items.Count > 0 then FSourceFormat.ItemIndex := 0;
  if FormatIndex(TSerializationFormat.Xml) >= 0 then
    FDestFormat.ItemIndex := FormatIndex(TSerializationFormat.Xml)
  else if FDestFormat.Items.Count > 1 then FDestFormat.ItemIndex := 1
  else if FDestFormat.Items.Count > 0 then FDestFormat.ItemIndex := 0;
  if FDataSetFormat.Items.Count > 0 then FDataSetFormat.ItemIndex := 0;
end;

{ ------------------------------------------------------------ selections -- }

function TLiveConverterForm.FormatIndex(AFormat: TSerializationFormat): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FParseFormats) do
    if FParseFormats[I] = AFormat then Exit(I);
  Result := -1;
end;

function TLiveConverterForm.SelectedSourceFormat: TSerializationFormat;
begin
  Result := FParseFormats[FSourceFormat.ItemIndex];
end;

function TLiveConverterForm.SelectedDestFormat: TSerializationFormat;
begin
  Result := FWriteFormats[FDestFormat.ItemIndex];
end;

function TLiveConverterForm.SelectedDataSetFormat: TSerializationFormat;
begin
  Result := FWriteFormats[FDataSetFormat.ItemIndex];
end;

function TLiveConverterForm.SelectedSourceMode: TDataSetSourceMode;
begin
  Result := TDataSetSourceMode(FSourceMode.ItemIndex);
end;

function TLiveConverterForm.SelectedPolicy: TDataSetSerializationPolicy;
begin
  Result := TDataSetSerializationPolicy(FDataSetPolicy.ItemIndex);
end;

function TLiveConverterForm.SelectedSourceBytes: TBinaryDisplay;
begin
  case FSourceBytesAs.ItemIndex of
    1: Result := TBinaryDisplay.Base64;
    2: Result := TBinaryDisplay.NativeText;
  else
    Result := TBinaryDisplay.Hex;
  end;
end;

procedure TLiveConverterForm.SetSourceBytes(ADisplay: TBinaryDisplay);
begin
  case ADisplay of
    TBinaryDisplay.Base64:     FSourceBytesAs.ItemIndex := 1;
    TBinaryDisplay.NativeText: FSourceBytesAs.ItemIndex := 2;
  else
    FSourceBytesAs.ItemIndex := 0;
  end;
end;

{ ---------------------------------------------------------------- status -- }

procedure TLiveConverterForm.SetStatus(AKind: TStatusKind;
  const ASummary, ASecondary, ADetails: string);
begin
  FStatusKind := AKind;
  FStatusSummary.Caption := ASummary;
  FStatusSecondary.Caption := ASecondary;
  FStatusDetails := ADetails;
  FDetailsButton.Visible := ADetails <> '';
  case AKind of
    TStatusKind.Success: FStatusStripe.Color := CLR_SUCCESS;
    TStatusKind.Warning: FStatusStripe.Color := CLR_WARNING;
    TStatusKind.Error:   FStatusStripe.Color := CLR_ERROR;
  else
    FStatusStripe.Color := CLR_ACCENT;
  end;
  case AKind of
    TStatusKind.Warning: FStatusSummary.Font.Color := CLR_WARNING;
    TStatusKind.Error:   FStatusSummary.Font.Color := CLR_ERROR;
  else
    FStatusSummary.Font.Color := CLR_TEXT;
  end;
end;

procedure TLiveConverterForm.Failed(E: Exception; const AAction: string);
var
  Summary, Details, Where: string;
  SE: EStructuralConversionError;
  Kind: TStatusKind;
  Dest: string;
begin
  { NOTHING IS CLEARED. A failed conversion leaves the source document, the
    result of the last successful one and the DataSet exactly as they were,
    so the user can change one thing and try again rather than retyping.

    The summary is one line in words. The class name, the full message and
    the member path are the raw material, and they are behind Details. }
  Details := E.ClassName + ': ' + E.Message;
  Kind := TStatusKind.Error;
  if E is EStructuralConversionError then
  begin
    SE := EStructuralConversionError(E);
    Details := Details + sLineBreak + sLineBreak +
      Format('Path: %s' + sLineBreak + 'Value kind: %s' + sLineBreak +
        'Issue: %s',
      [SE.Path, EStructuralConversionError.KindName(SE.SourceKind),
       GetEnumName(TypeInfo(TStructuralIssue), Ord(SE.Issue))]);
    Dest := FormatLabel(SE.DestinationFormat);
    Where := SE.Path;
    if Where = '' then Where := '$';
    case SE.Issue of
      TStructuralIssue.InvalidText, TStructuralIssue.ParseError:
        Summary := 'Could not read the source - ' + FirstSentence(E.Message);
      TStructuralIssue.FieldInference:
        Summary := 'Structure could not be inferred - ' +
          FirstSentence(E.Message);
      TStructuralIssue.InvalidDestinationName:
        Summary := Format('Representation refused - %s cannot spell the ' +
          'member name at %s', [Dest, Where]);
      TStructuralIssue.UnsupportedLosslessConversion:
        Summary := Format('Representation refused - no published standard ' +
          'carries the %s value at %s into %s losslessly',
          [EStructuralConversionError.KindName(SE.SourceKind), Where, Dest]);
      TStructuralIssue.LossyConversion:
        Summary := Format('Representation refused - the %s value at %s ' +
          'would lose information in %s',
          [EStructuralConversionError.KindName(SE.SourceKind), Where, Dest]);
    else
      Summary := Format('Representation refused - %s cannot represent the ' +
        'value at %s', [Dest, Where]);
    end;
  end
  else if E is ESerializationSchemaRequired then
  begin
    Kind := TStatusKind.Warning;
    Summary := 'Schema required - ' + FirstSentence(E.Message);
  end
  else if E is ESerializationFormatCapability then
    Summary := 'Not supported - ' + FirstSentence(E.Message)
  else if E is EConverterInput then
    Summary := 'Input error - ' + E.Message
  else
    Summary := AAction + ' - ' + FirstSentence(E.Message);
  SetStatus(Kind, Summary,
    'Nothing was cleared: the source, the last result and the DataSet are ' +
    'as they were.', Details);
end;

{ ---------------------------------------------------------- visibility -- }

procedure TLiveConverterForm.UpdateModeButtons;
var
  P: TStructuralConversionProfile;
begin
  for P := Low(TStructuralConversionProfile) to High(TStructuralConversionProfile) do
    FModeButtons[P].Toggled := P = FProfile;
  FModeHint.Caption := MODE_HINTS[FProfile];
end;

procedure TLiveConverterForm.UpdateViewBar;
var
  F: TSerializationFormat;
begin
  { Whatever is in the result box decides, not what the combo says now: a
    result stays what it was until the next conversion. }
  if FHasResult then F := FLastResultFormat
  else if FDestFormat.ItemIndex >= 0 then F := SelectedDestFormat
  else Exit;
  FViewBar.Visible := IsBinaryFormat(F) and (FHasResult or (FResult.Text = ''));
  FViewButtons[TBinaryDisplay.NativeText].Visible := HasTextForm(F);
  if (FResultView = TBinaryDisplay.NativeText) and not HasTextForm(F) then
    FResultView := TBinaryDisplay.Hex;
  FViewButtons[TBinaryDisplay.Hex].Toggled := FResultView = TBinaryDisplay.Hex;
  FViewButtons[TBinaryDisplay.Base64].Toggled :=
    FResultView = TBinaryDisplay.Base64;
  FViewButtons[TBinaryDisplay.NativeText].Toggled :=
    FResultView = TBinaryDisplay.NativeText;
end;

{ -------------------------------------------------------------- payloads -- }

function TLiveConverterForm.SourcePayload: TSerializationPayload;
var
  Text: string;
  Bytes: TBytes;
begin
  Text := Trim(FSource.Lines.Text);
  if not IsBinaryFormat(SelectedSourceFormat) then
    Exit(TSerializationPayload.FromText(Text));

  { A binary source is typed as hex or base64, because a memo cannot hold
    bytes. Whichever "Bytes as" says is what it is read back as. }
  case SelectedSourceBytes of
    TBinaryDisplay.Hex:
      begin
        if not TStructuralText.TryDecodeHex(Compact(Text), Bytes) then
          raise EConverterInput.Create(
            'The source is set to hex and does not contain hex.');
        Exit(TSerializationPayload.FromBytes(Bytes));
      end;
    TBinaryDisplay.Base64:
      begin
        if not TStructuralText.TryDecodeBinary(Compact(Text), Bytes) then
          raise EConverterInput.Create(
            'The source is set to base64 and does not contain base64.');
        Exit(TSerializationPayload.FromBytes(Bytes));
      end;
  end;

  { The standard text form of whichever format this is. }
  if SelectedSourceFormat = TSerializationFormat.Bson then
    Exit(TSerializationPayload.FromBytes(
      TBsonSerializer.FromExtendedJson(Text)));

  { CBOR's diagnostic notation is a DISPLAY form: RFC 8949 defines how to
    write a data item down for a human and does not define a parser for it,
    so there is nothing honest to read back here. Saying so beats guessing. }
  raise EConverterInput.CreateFmt(
    '%s has no standard text form this demo can read back. Set "Bytes as" ' +
    'to Hex or Base64 and paste the bytes.',
    [FormatLabel(SelectedSourceFormat)]);
end;

function TLiveConverterForm.Render(const APayload: TSerializationPayload;
  AFormat: TSerializationFormat; ADisplay: TBinaryDisplay): string;
var
  Value: TCborValue;
begin
  if APayload.IsText then Exit(APayload.AsText);

  { Bytes have to be shown as something. }
  case ADisplay of
    TBinaryDisplay.Hex:
      Exit(HexView(APayload.AsBytes));
    TBinaryDisplay.Base64:
      Exit(TStructuralText.EncodeBinary(APayload.AsBytes));
  end;

  { Each binary format's own standard text form, and hex for one that has
    none. Never a UTF-8 decode of the bytes. }
  if AFormat = TSerializationFormat.Bson then
    Exit(TBsonSerializer.ToExtendedJson(APayload.AsBytes));
  if AFormat = TSerializationFormat.Cbor then
  begin
    Value := TCborSerializer.Decode(APayload.AsBytes);
    try
      Exit(Value.ToDiagnostic);
    finally
      Value.Free;
    end;
  end;
  Result := HexView(APayload.AsBytes);
end;

procedure TLiveConverterForm.ShowResult(const APayload: TSerializationPayload;
  AFormat: TSerializationFormat);
begin
  DropTables;
  FLastResult := APayload;
  FLastResultFormat := AFormat;
  FHasResult := True;
  RenderResult;
  FPages.ActivePage := FPayloadTab;
end;

procedure TLiveConverterForm.RenderResult;
begin
  UpdateViewBar;
  if not FHasResult then Exit;
  FResult.Lines.Text := Render(FLastResult, FLastResultFormat, FResultView);
  if FLastResult.IsBinary then
    FSizeLabel.Caption := BytesText(Length(FLastResult.AsBytes))
  else
    FSizeLabel.Caption := Format('%d characters', [Length(FLastResult.AsText)]);
end;

procedure TLiveConverterForm.ClearResult;
begin
  DropTables;
  FHasResult := False;
  FLastResult := Default(TSerializationPayload);
  FResult.Lines.Clear;
  FSizeLabel.Caption := '';
  UpdateViewBar;
end;

{ ============================================================ CSV tables == }

{ A document that is not one flat table has to be PROJECTED onto CSV, and
  the projection is a choice. Four of the five choices still produce one
  CSV document, so they go through the registry like every other
  conversion, with the options carried by a TCsvSchema context. The fifth,
  Separate tables, produces SEVERAL documents - one payload cannot hold
  them, so it is a different call, TCsvSerializer.TablesFrom, with a
  different result: a TCsvDocumentSet. }

function TLiveConverterForm.SelectedCsvOptions: TCsvOptions;
begin
  Result := TCsvOptions.Default;
  case FCsvProjection.ItemIndex of
    1: Result := Result.WithCollectionMode(TCsvCollectionMode.JsonCell);
    2: Result := Result.WithCollectionMode(TCsvCollectionMode.RepeatedRows);
    3: Result := Result.WithCollectionMode(TCsvCollectionMode.SeparateTable);
    4: Result := Result.WithCollectionMode(TCsvCollectionMode.NumberedColumns);
  end;
end;

function TLiveConverterForm.IsSeparateTables: Boolean;
begin
  Result := FCsvProjection.ItemIndex = 3;
end;

procedure TLiveConverterForm.DropTables;
begin
  FreeAndNil(FTables);
  FTableCombo.Items.Clear;
  FTableBar.Visible := False;
  FRelationLabel.Visible := False;
  FSave.Caption := 'Save...';
end;

procedure TLiveConverterForm.ShowTables(ATables: TCsvDocumentSet);
var
  Name: string;
begin
  { Takes ownership. }
  DropTables;
  FTables := ATables;
  for Name in FTables.TableNames do
    FTableCombo.Items.Add(Name);
  FTableBar.Visible := True;
  FSave.Caption := 'Save tables...';
  FPages.ActivePage := FPayloadTab;
  if FTables.Count > 0 then
  begin
    FTableCombo.ItemIndex := 0;
    ShowTable(0);
  end
  else
  begin
    FHasResult := False;
    FResult.Lines.Clear;
    FTableRows.Caption := 'no tables';
  end;
end;

procedure TLiveConverterForm.ShowTable(AIndex: Integer);
var
  Table: TCsvTableDocument;
  Rel: TCsvTableRelationship;
  Lines: string;
  I, Count: Integer;
begin
  if (FTables = nil) or (AIndex < 0) or (AIndex >= FTables.Count) then Exit;
  Table := FTables[AIndex];

  { The table on screen is the result: Copy copies it and Swap moves it. }
  FLastResult := TSerializationPayload.FromText(Table.Content);
  FLastResultFormat := TSerializationFormat.Csv;
  FHasResult := True;
  RenderResult;
  if Table.RowCount = 1 then FTableRows.Caption := '1 row'
  else FTableRows.Caption := Format('%d rows', [Table.RowCount]);

  { How this table joins the others - metadata, which is why it is a line
    here and not a column in the file. }
  Lines := '';
  Count := 0;
  for I := 0 to FTables.RelationshipCount - 1 do
  begin
    Rel := FTables.Relationships[I];
    if SameText(Rel.ParentTable, Table.Name) or
       SameText(Rel.ChildTable, Table.Name) then
    begin
      if Lines <> '' then Lines := Lines + ';   ';
      Lines := Lines + Format('%s.%s -> %s.%s',
        [Rel.ParentTable, Rel.ParentKeyColumn, Rel.ChildTable,
         Rel.ChildReferenceColumn]);
      Inc(Count);
    end;
  end;
  if Count = 1 then FRelationLabel.Caption := 'Relationship: ' + Lines
  else FRelationLabel.Caption := 'Relationships: ' + Lines;
  FRelationLabel.Visible := Count > 0;
end;

procedure TLiveConverterForm.SaveTablesTo(const AFolder: string);
var
  I: Integer;
begin
  { Every table, each as its own file, UTF-8 without a BOM. Never one table
    picked silently, never an archive. }
  if FTables = nil then
    raise EConverterInput.Create('There are no tables to save.');
  ForceDirectories(AFolder);
  for I := 0 to FTables.Count - 1 do
    TFile.WriteAllBytes(TPath.Combine(AFolder, FTables[I].Name + '.csv'),
      TEncoding.UTF8.GetBytes(FTables[I].Content));
end;

procedure TLiveConverterForm.DoCsvProjectionChanged(Sender: TObject);
begin
  { The result on screen was made under the other projection, so it goes -
    as it does for a new destination - and the conversion runs again. }
  ClearResult;
  if FConvert.Enabled then DoConvert(Sender);
end;

procedure TLiveConverterForm.DoTableChanged(Sender: TObject);
begin
  ShowTable(FTableCombo.ItemIndex);
end;

{ ============================================================== contexts == }

{ WHY THE SCHEMA CARDS EXIST.

  Three families of the registered formats cannot be read without something
  the document does not contain. Protobuf bytes carry field NUMBERS and wire
  types and nothing else. Avro bytes carry no type information at all. ASN.1
  octets are anonymous and a module usually declares several types, so even
  with the module the bytes have to be told which one they are.

  So all of them are listed, and the side that has one of them grows a card
  saying what it needs and taking it. The other side, and every other pair,
  never sees it. }

function TLiveConverterForm.ContextDirectory: string;
var
  Up, Candidate: string;
  I: Integer;
begin
  { Beside the executable when the demo has been deployed, beside the source
    when it is being run from the tree. Both are tried so that neither the
    build nor a curious user has to know which. }
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'context');
  if TDirectory.Exists(Result) then Exit;
  { Otherwise walk up from the executable looking for the source tree, which
    is what happens when the demo is run out of artifacts rather than
    deployed. Six levels is more than the tree is deep. }
  Up := ExcludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  for I := 1 to 6 do
  begin
    Up := TPath.GetDirectoryName(Up);
    if Up = '' then Break;
    Candidate := TPath.Combine(Up,
      TPath.Combine('demo',
        TPath.Combine('Conversion',
          TPath.Combine('06-LiveFormatConverter', 'context'))));
    if TDirectory.Exists(Candidate) then Exit(Candidate);
  end;
end;

function TLiveConverterForm.SideFormat(ASide: Integer): TSerializationFormat;
begin
  if ASide = 0 then Result := SelectedSourceFormat
  else Result := SelectedDestFormat;
end;

function TLiveConverterForm.HasContextFor(
  AFormat: TSerializationFormat): Boolean;
begin
  if AFormat = TSerializationFormat.Protobuf then
    Result := (FProtoSchema <> nil) and (FProtoMessage <> '')
  else if AFormat = TSerializationFormat.Avro then
    Result := FAvroSchema <> nil
  else if TSerializationFormats.IsAsn1(AFormat) then
    Result := (FAsn1Schema <> nil) and (FAsn1Root <> '')
  else
    { Every other format reads its own bytes, so it always has what it
      needs and nil is the right context for it. }
    Result := True;
end;

function TLiveConverterForm.ContextFor(
  AFormat: TSerializationFormat): TSerializationContext;
var
  C: TSerializationContext;
  Rule: TAsn1EncodingRule;
begin
  Result := nil;
  if not HasContextFor(AFormat) then Exit;

  { One live context per format, kept because it is BORROWED by every call
    that uses it: the conversion does not take ownership and must not, or a
    second conversion would be reading freed memory. The list owns them and
    is emptied whenever a schema is replaced. }
  for C in FContexts do
    if C.Format = AFormat then Exit(C);

  if AFormat = TSerializationFormat.Protobuf then
    Result := TProtobufSerializationContext.Create(FProtoSchema, FProtoMessage)
  else if AFormat = TSerializationFormat.Avro then
    Result := TAvroSerializationContext.Create(FAvroSchema)
  else if TSerializationFormats.IsAsn1(AFormat) then
  begin
    { The rule belongs to the END, not to the module: the same Subject in
      the same module is different octets in BER and in DER, and this window
      lists those as the separate formats they are. }
    if AFormat = TSerializationFormat.Asn1Ber then Rule := TAsn1EncodingRule.Ber
    else if AFormat = TSerializationFormat.Asn1Cer then Rule := TAsn1EncodingRule.Cer
    else Rule := TAsn1EncodingRule.Der;
    Result := TAsn1SerializationContext.Create(FAsn1Schema, FAsn1Root, Rule);
  end
  else
    Exit(nil);

  FContexts.Add(Result);
end;

procedure TLiveConverterForm.InvalidateContexts;
begin
  { A context holds a schema pointer. Replace the schema and every context
    built on it is stale, so they go together. }
  FContexts.Clear;
end;

procedure TLiveConverterForm.LoadContextFile(ASide: Integer;
  const APath: string);
var
  Target: TSerializationFormat;
begin
  Target := SideFormat(ASide);
  if not TFile.Exists(APath) then
    raise EConverterInput.CreateFmt('There is no file at %s.', [APath]);

  InvalidateContexts;
  if Target = TSerializationFormat.Protobuf then
  begin
    { A FileDescriptorSet, which is what protoc writes with
      --descriptor_set_out. Not a .proto: parsing the language is protoc's
      job and this library reads the compiled form. }
    FreeAndNil(FProtoSchema);
    FProtoSchema := TProtobufSchema.LoadDescriptorSet(TFile.ReadAllBytes(APath));
    FProtoMessage := '';
    FProtoPath := APath;
  end
  else if Target = TSerializationFormat.Avro then
  begin
    FreeAndNil(FAvroSchema);
    FAvroSchema := TAvroSchema.Parse(TFile.ReadAllText(APath, TEncoding.UTF8));
    FAvroPath := APath;
  end
  else if TSerializationFormats.IsAsn1(Target) then
  begin
    FreeAndNil(FAsn1Schema);
    FAsn1Schema := TAsn1Schema.ParseModule(
      TFile.ReadAllText(APath, TEncoding.UTF8));
    FAsn1Root := '';
    FAsn1Path := APath;
  end
  else
    raise EConverterInput.CreateFmt(
      '%s reads its own bytes and needs no schema.', [FormatLabel(Target)]);

  RefreshCards;
  RefreshCapability;
  if FConvert.Enabled then
    SetStatus(TStatusKind.Success,
      Format('Schema loaded - %s for %s',
        [ExtractFileName(APath), FormatLabel(Target)]),
      FCapabilityText);
end;

{ One card: what its side's format needs, what has been loaded, and the
  message or type chooser. It keeps a choice already made. }
procedure TLiveConverterForm.RefreshCard(ASide: Integer);
var
  F: TSerializationFormat;
  S, Current: string;
  I: Integer;
  Root: TComboBox;
begin
  F := SideFormat(ASide);
  FCtxCard[ASide].Visible := TSerialization.StructuralRequirement(F) = 'schema';
  if not FCtxCard[ASide].Visible then Exit;

  Root := FCtxRoot[ASide];
  Root.Items.BeginUpdate;
  try
    Root.Items.Clear;
    if F = TSerializationFormat.Protobuf then
    begin
      FCtxTitle[ASide].Caption := 'Protobuf descriptor set';
      FCtxRootLabel[ASide].Caption := 'Message';
      FCtxPath[ASide].Text := FProtoPath;
      Current := FProtoMessage;
      if FProtoSchema <> nil then
        for S in FProtoSchema.MessageNames do Root.Items.Add(S);
    end
    else if F = TSerializationFormat.Avro then
    begin
      FCtxTitle[ASide].Caption := 'Avro schema';
      FCtxRootLabel[ASide].Caption := 'Schema';
      FCtxPath[ASide].Text := FAvroPath;
      { An Avro schema IS its root; there is nothing to choose, and showing
        the name is more useful than an empty box. }
      if FAvroSchema <> nil then Root.Items.Add(FAvroSchema.Describe);
      Current := '';
    end
    else
    begin
      FCtxTitle[ASide].Caption := 'ASN.1 module';
      FCtxRootLabel[ASide].Caption := 'Type';
      FCtxPath[ASide].Text := FAsn1Path;
      Current := FAsn1Root;
      if FAsn1Schema <> nil then
        for I := 0 to FAsn1Schema.TypeCount - 1 do
          Root.Items.Add(FAsn1Schema.Types[I].Name);
    end;
  finally
    Root.Items.EndUpdate;
  end;

  Root.Enabled := Root.Items.Count > 1;
  if Root.Items.Count > 0 then
  begin
    I := Root.Items.IndexOf(Current);
    if I < 0 then
    begin
      { Nothing chosen yet: the first one, as a default the user can see. }
      I := 0;
      InvalidateContexts;
      if F = TSerializationFormat.Protobuf then FProtoMessage := Root.Items[0]
      else if TSerializationFormats.IsAsn1(F) then FAsn1Root := Root.Items[0];
    end;
    Root.ItemIndex := I;
  end;

  if HasContextFor(F) then
  begin
    FCtxInfo[ASide].Caption := 'Ready - ' + ContextFor(F).Describe;
    FCtxInfo[ASide].Font.Color := CLR_SUCCESS;
  end
  else
  begin
    FCtxInfo[ASide].Caption := 'Needs ' + Needed(F) + '.';
    FCtxInfo[ASide].Font.Color := CLR_WARNING;
  end;
end;

procedure TLiveConverterForm.RefreshCards;
begin
  if (FSourceFormat.ItemIndex < 0) or (FDestFormat.ItemIndex < 0) then Exit;
  RefreshCard(0);
  RefreshCard(1);
end;

procedure TLiveConverterForm.DoCtxRootChanged(Sender: TObject);
var
  Side: Integer;
  F: TSerializationFormat;
  Root: TComboBox;
begin
  Side := TComponent(Sender).Tag;
  Root := FCtxRoot[Side];
  if Root.ItemIndex < 0 then Exit;
  F := SideFormat(Side);
  InvalidateContexts;
  if F = TSerializationFormat.Protobuf then
    FProtoMessage := Root.Items[Root.ItemIndex]
  else if TSerializationFormats.IsAsn1(F) then
    FAsn1Root := Root.Items[Root.ItemIndex];
  RefreshCards;
  RefreshCapability;
end;

{ WHAT IS MISSING, IN WORDS.

  A control that is disabled with no explanation is a dead end. When an end
  of the conversion needs a context and has not been given one, this says
  which end, which format and what to load - and the moment it is supplied,
  the same line says the conversion is available. }
procedure TLiveConverterForm.RefreshCapability;
var
  From_, To_: TSerializationFormat;
  Missing, Ready: string;
begin
  if (FSourceFormat = nil) or (FSourceFormat.ItemIndex < 0) or
     (FDestFormat.ItemIndex < 0) then Exit;
  From_ := SelectedSourceFormat;
  To_ := SelectedDestFormat;

  Missing := '';
  if not HasContextFor(From_) then
    Missing := Format('Reading %s requires %s.',
      [FormatLabel(From_), Needed(From_)]);
  if not HasContextFor(To_) then
  begin
    if Missing <> '' then Missing := Missing + ' ';
    Missing := Missing + Format('Writing %s requires %s.',
      [FormatLabel(To_), Needed(To_)]);
  end;

  if Missing = '' then
  begin
    Ready := '';
    if ContextFor(From_) <> nil then
      Ready := 'reading with ' + ContextFor(From_).Describe;
    if ContextFor(To_) <> nil then
    begin
      if Ready <> '' then Ready := Ready + ', ';
      Ready := Ready + 'writing with ' + ContextFor(To_).Describe;
    end;
    if Ready = '' then
      FCapabilityText := 'Ready - both ends read and write their own bytes.'
    else
      FCapabilityText := 'Ready: ' + Ready + '.';
    if (FStatusKind = TStatusKind.Warning) and
       (Pos('Schema required', FStatusSummary.Caption) = 1) then
      SetStatus(TStatusKind.Info, 'Ready to convert', FCapabilityText);
  end
  else
  begin
    FCapabilityText := Missing + ' Load it in the schema card.';
    SetStatus(TStatusKind.Warning, 'Schema required - ' + Missing,
      'Leave the file box empty and press Load for the bundled sample.');
  end;
  FConvert.Enabled := Missing = '';
end;

procedure TLiveConverterForm.DoCtxBrowse(Sender: TObject);
var
  Dialog: TOpenDialog;
  Side: Integer;
begin
  Side := TComponent(Sender).Tag;
  Dialog := TOpenDialog.Create(Self);
  try
    Dialog.InitialDir := ContextDirectory;
    Dialog.Filter :=
      'Everything a schema can be|*.desc;*.avsc;*.asn;*.asn1;*.txt|' +
      'Protobuf descriptor set (*.desc)|*.desc|' +
      'Avro schema (*.avsc)|*.avsc|' +
      'ASN.1 module (*.asn)|*.asn;*.asn1|All files (*.*)|*.*';
    if Dialog.Execute then
    try
      LoadContextFile(Side, Dialog.FileName);
    except
      on E: Exception do Failed(E, 'Schema not loaded');
    end;
  finally
    Dialog.Free;
  end;
end;

procedure TLiveConverterForm.DoCtxLoad(Sender: TObject);
var
  Side: Integer;
  Target: TSerializationFormat;
  Path: string;
begin
  Side := TComponent(Sender).Tag;
  try
    if Trim(FCtxPath[Side].Text) <> '' then
      Path := Trim(FCtxPath[Side].Text)
    else
    begin
      { The bundled sample, so that the card can be tried without hunting
        for a file - and so that the self-test presses the same button a
        user does rather than a private back door. }
      Target := SideFormat(Side);
      if Target = TSerializationFormat.Protobuf then
        Path := TPath.Combine(ContextDirectory, 'subject.desc')
      else if Target = TSerializationFormat.Avro then
        Path := TPath.Combine(ContextDirectory, 'subject.avsc')
      else
        Path := TPath.Combine(ContextDirectory, 'subject.asn');
    end;
    LoadContextFile(Side, Path);
  except
    on E: Exception do Failed(E, 'Schema not loaded');
  end;
end;

{ The two contexts, each in ITS OWN ROLE. The source context says what the
  incoming octets mean; the destination context says what shape to write.
  They are different questions and they can be different schemas - the same
  format can appear at both ends with a different one at each - so they go
  into separate slots rather than into one ambiguous pile. }
function TLiveConverterForm.OptionsFor(AFrom, ATo: TSerializationFormat):
  TStructuralConversionOptions;
begin
  Result := TStructuralConversionOptions.FromProfile(FProfile)
    .WithSource(AFrom).WithDestination(ATo)
    .WithSourceContext(ContextFor(AFrom))
    .WithDestinationContext(ContextFor(ATo));
end;

function TLiveConverterForm.ContextSentence(
  AFrom, ATo: TSerializationFormat): string;
begin
  Result := '';
  if ContextFor(AFrom) <> nil then
    Result := 'Read with ' + ContextFor(AFrom).Describe + '.';
  if ContextFor(ATo) <> nil then
  begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + 'Written with ' + ContextFor(ATo).Describe + '.';
  end;
end;

{ ------------------------------------------------------------- the actions - }

procedure TLiveConverterForm.DoFormatChanged(Sender: TObject);
var
  Binary: Boolean;
begin
  if (FSourceFormat.ItemIndex < 0) or (FDestFormat.ItemIndex < 0) then Exit;
  { A new destination makes the old result a document in some other format;
    it is cleared rather than left under a caption that no longer names it.
    (A FAILED conversion clears nothing - that is a different thing.) }
  if (Sender = FDestFormat) and FHasResult and
     (FLastResultFormat <> SelectedDestFormat) then
    ClearResult;
  { Only what applies is shown: the bytes box for a binary source, the view
    for a binary result, a schema card for a side that needs one, and the
    CSV projection when the result is CSV. }
  Binary := IsBinaryFormat(SelectedSourceFormat);
  FSourceBytesLabel.Visible := Binary;
  FSourceBytesAs.Visible := Binary;
  FCsvBar.Visible := SelectedDestFormat = TSerializationFormat.Csv;
  UpdateViewBar;
  RefreshCards;
  { Changing an end can change what is missing, so the explanation is
    refreshed with it rather than going stale until the next Convert. }
  RefreshCapability;
end;

procedure TLiveConverterForm.DoModeClick(Sender: TObject);
begin
  FProfile := TStructuralConversionProfile(TComponent(Sender).Tag);
  UpdateModeButtons;
end;

procedure TLiveConverterForm.DoViewClick(Sender: TObject);
begin
  FResultView := TBinaryDisplay(TComponent(Sender).Tag);
  RenderResult;
end;

procedure TLiveConverterForm.DoConvert(Sender: TObject);
var
  From_, To_: TSerializationFormat;
  Source, Out_: TSerializationPayload;
  Summary, Secondary, Mode: string;
  Route: TStructuralRoute;
  I: Integer;
  Tables: TCsvDocumentSet;
  CsvSchema: TCsvSchema;

  procedure Done(const AMode, ASecondary: string);
  begin
    SetStatus(TStatusKind.Success,
      Format('Converted successfully - %s -> %s - %s',
        [FormatLabel(From_), FormatLabel(To_), AMode]), ASecondary);
  end;

begin
  try
    From_ := SelectedSourceFormat;
    To_ := SelectedDestFormat;

    { A conversion that cannot be done is refused HERE, in the same words
      the schema card is already showing, rather than as whatever the format
      happens to raise three layers down. }
    if not (HasContextFor(From_) and HasContextFor(To_)) then
    begin
      RefreshCapability;
      Exit;
    end;

    Source := SourcePayload;

    { CSV, under the projection the CSV bar names. }
    if To_ = TSerializationFormat.Csv then
    begin
      if IsSeparateTables then
      begin
        { Several documents: TablesFrom, not Convert. The source's own
          context, when it has one, is how a schema-driven source is read. }
        if ContextFor(From_) <> nil then
          Tables := TCsvSerializer.TablesFrom(Source, From_,
            ContextFor(From_), SelectedCsvOptions)
        else
          Tables := TCsvSerializer.TablesFrom(Source, From_,
            SelectedCsvOptions);
        ShowTables(Tables);
        Done(Format('Separate tables - %d tables', [Tables.Count]),
          'One CSV document per table, shown one at a time. Save tables... ' +
          'writes every one of them.');
        Exit;
      end;

      { One document: the registry, with the options in a TCsvSchema. }
      CsvSchema := TCsvSchema.Create(SelectedCsvOptions);
      try
        Out_ := TSerialization.Convert(Source, From_, To_,
          OptionsFor(From_, To_).WithDestinationContext(CsvSchema));
      finally
        CsvSchema.Free;
      end;
      ShowResult(Out_, To_);
      Done(ProfileName(FProfile) + ' - ' + FCsvProjection.Text,
        ContextSentence(From_, To_));
      Exit;
    end;

    { ONE CALL, for every other pair. A pair the library composes through a hub under
      Lossless - BSON to XML through Extended JSON and the W3C mapping - goes
      through the overload that composes it and reports the route. Everything
      else is one hop, with whichever schema contexts its ends need. }
    Route := TSerialization.RouteFor(From_, To_, FProfile);
    if Route.IsComposed then
      Out_ := TSerialization.Convert(Source, From_, To_, FProfile, Route)
    else
      Out_ := TSerialization.Convert(Source, From_, To_,
        OptionsFor(From_, To_));
    ShowResult(Out_, To_);

    Mode := ProfileName(FProfile);
    Secondary := '';
    if Route.IsComposed then
    begin
      Secondary := 'Route: ' + FormatLabel(Route.Steps[0].FromFormat);
      for I := 0 to High(Route.Steps) do
      begin
        if Route.Steps[I].Standard <> '' then
          Secondary := Secondary + ' -> ' + Route.Steps[I].Standard;
        Secondary := Secondary + ' -> ' + FormatLabel(Route.Steps[I].ToFormat);
      end;
    end
    else if Route.Steps[0].Standard <> '' then
      Mode := Mode + ' - ' + Route.Steps[0].Standard + ' mapping';
    Summary := ContextSentence(From_, To_);
    if Summary <> '' then
    begin
      if Secondary <> '' then Secondary := Secondary + '   ';
      Secondary := Secondary + Summary;
    end;
    Done(Mode, Secondary);
  except
    on E: Exception do Failed(E, 'Conversion failed');
  end;
end;

procedure TLiveConverterForm.DoSwap(Sender: TObject);
var
  Index: Integer;
  Display: TBinaryDisplay;
  Moved: Boolean;
begin
  { The result becomes the source, and the two formats trade places - which
    is how a round trip is done here: convert, swap, convert. A binary result
    moves in the spelling it is being viewed in, unless that spelling cannot
    be read back, in which case it moves as hex. }
  Moved := FHasResult;
  if FHasResult then
  begin
    Display := FResultView;
    if (Display = TBinaryDisplay.NativeText) and
       (FLastResultFormat <> TSerializationFormat.Bson) then
      Display := TBinaryDisplay.Hex;
    if FLastResult.IsBinary then SetSourceBytes(Display);
    FSource.Lines.Text := Render(FLastResult, FLastResultFormat, Display);
  end;
  Index := FSourceFormat.ItemIndex;
  FSourceFormat.ItemIndex := FDestFormat.ItemIndex;
  FDestFormat.ItemIndex := Index;
  ClearResult;
  DoFormatChanged(nil);
  if FConvert.Enabled then
    if Moved then
      SetStatus(TStatusKind.Info,
        Format('Swapped - %s -> %s', [FormatLabel(SelectedSourceFormat),
          FormatLabel(SelectedDestFormat)]),
        'The result is now the source. Convert again to go back.')
    else
      SetStatus(TStatusKind.Info,
        Format('Swapped formats - %s -> %s', [FormatLabel(SelectedSourceFormat),
          FormatLabel(SelectedDestFormat)]),
        'There was no converted result to move, so the source is unchanged.');
end;

procedure TLiveConverterForm.DoLoadSample(Sender: TObject);
begin
  { FIVE samples, in rotation, because they are five different questions:

      a document that describes  what the detector does with an embedded
        its own columns            schema
      a BSON document            what the binary views and the composed
                                   lossless routes are for
      a plain document           what conversion does to names and values
      two collections            what CSV does with a document that is
                                   two tables, not one
      a nested collection        and with a child table that has to be
                                   joined back to its parent }
  ClearResult;
  case FSampleIndex mod 5 of
    1:
      begin
        FSourceFormat.ItemIndex := FormatIndex(TSerializationFormat.Bson);
        SetSourceBytes(TBinaryDisplay.Hex);
        FSource.Lines.Text := HexView(SampleBson);
        DoFormatChanged(nil);
        SetStatus(TStatusKind.Info, 'Sample loaded - a BSON document, as hex',
          'Convert it to JSON, or to XML under Lossless to see a composed ' +
          'route.');
      end;
    2:
      begin
        FSourceFormat.ItemIndex := FormatIndex(TSerializationFormat.Json);
        FSource.Lines.Text := SampleJson;
        DoFormatChanged(nil);
        SetStatus(TStatusKind.Info, 'Sample loaded - a plain JSON document',
          'Convert it to XML in each mode and watch what happens to "$type" ' +
          'and to the empty list.');
      end;
    3, 4:
      begin
        FSourceFormat.ItemIndex := FormatIndex(TSerializationFormat.Json);
        if FSampleIndex mod 5 = 3 then
          FSource.Lines.Text := SampleCustomersAndOrders
        else
          FSource.Lines.Text := SampleNestedOrders;
        FDestFormat.ItemIndex := FormatIndex(TSerializationFormat.Csv);
        DoFormatChanged(FDestFormat);
        if FSampleIndex mod 5 = 3 then
          SetStatus(TStatusKind.Info,
            'Sample loaded - two collections, for CSV',
            'Conservative refuses it; Separate tables makes one CSV per ' +
            'collection.')
        else
          SetStatus(TStatusKind.Info,
            'Sample loaded - a collection inside a collection, for CSV',
            'Separate tables makes a child table joined on a generated key.');
      end;
  else
    FSourceFormat.ItemIndex := FormatIndex(TSerializationFormat.Json);
    FSource.Lines.Text := SampleTable;
    DoFormatChanged(nil);
    SetStatus(TStatusKind.Info,
      'Sample loaded - a document that describes its own columns',
      'Open the DataSet tab and press From source; compare Auto with ' +
      'Infer structure.');
  end;
  Inc(FSampleIndex);
end;

{ -------------------------------------------------------------- the table -- }

procedure TLiveConverterForm.ShowSchema(ADataSet: TDataSet);
var
  I: Integer;
begin
  FSchemaGrid.RowCount := 1 + Max(1, ADataSet.FieldDefs.Count);
  FSchemaGrid.Cells[0, 0] := 'FieldName';
  FSchemaGrid.Cells[1, 0] := 'DataType';
  FSchemaGrid.Cells[2, 0] := 'Size';
  FSchemaGrid.Cells[3, 0] := 'Required';
  for I := 1 to FSchemaGrid.RowCount - 1 do
  begin
    FSchemaGrid.Cells[0, I] := '';
    FSchemaGrid.Cells[1, I] := '';
    FSchemaGrid.Cells[2, I] := '';
    FSchemaGrid.Cells[3, I] := '';
  end;
  for I := 0 to ADataSet.FieldDefs.Count - 1 do
  begin
    FSchemaGrid.Cells[0, I + 1] := ADataSet.FieldDefs[I].Name;
    FSchemaGrid.Cells[1, I + 1] :=
      GetEnumName(TypeInfo(TFieldType), Ord(ADataSet.FieldDefs[I].DataType));
    FSchemaGrid.Cells[2, I + 1] := IntToStr(ADataSet.FieldDefs[I].Size);
    FSchemaGrid.Cells[3, I + 1] :=
      BoolToStr(ADataSet.FieldDefs[I].Required, True);
  end;
end;

procedure TLiveConverterForm.ProjectInto(const APayload: TSerializationPayload;
  AFormat: TSerializationFormat);
var
  Match: TDataSetMetadataMatch;
begin
  FPages.ActivePage := FDataSetTab;
  { THE DETECTOR'S VERDICT IS SHOWN, always, whichever mode is chosen - so
    a user in Auto can see WHY the schema came out the way it did, and a
    user in Infer structure can see what they are overriding. }
  if ContextFor(AFormat) <> nil then
  begin
    { A document that needed a context to be read at all did not describe
      its own columns; its shape came from the schema. Saying that is more
      use than running a detector that cannot read the bytes. }
    FDetected.Caption := 'Detected: schema-driven - ' +
      ContextFor(AFormat).Describe;
    FDetected.Font.Color := CLR_ACCENT_DOWN;
  end
  else
  begin
    Match := TDataSetSerializer.ClassifySource(APayload, AFormat);
    FDetected.Caption := Format('Detected: %s - %s',
      [GetEnumName(TypeInfo(TDataSetMetadataMatch), Ord(Match)),
       TDataSetSerializer.ExplainSource(APayload, AFormat)]);
    case Match of
      TDataSetMetadataMatch.ValidMetadata: FDetected.Font.Color := CLR_SUCCESS;
      TDataSetMetadataMatch.NotMetadata:   FDetected.Font.Color := CLR_ACCENT_DOWN;
    else
      FDetected.Font.Color := CLR_WARNING;
    end;
  end;

  { The table is NOT closed first. Deserialize - either overload -
    pre-validates the whole projection on a temporary TFDMemTable before
    rebuilding this one, so a document the library refuses leaves the last
    good table on screen instead of an empty grid and an error. (This table
    has no event handlers of its own, so nothing can raise after the
    rebuild has begun.)

    THE SAME GENERIC API EITHER WAY. A schema-driven format is read through
    the overload that takes the context and nothing else differs: there is
    no Protobuf projection, no Avro projection and no ASN.1 projection in
    this demo or in the library, because a DataSet does not care where the
    shape came from. }
  if ContextFor(AFormat) <> nil then
    TDataSetSerializer.Deserialize(APayload, AFormat, ContextFor(AFormat),
      FTable)
  else
    TDataSetSerializer.Deserialize(APayload, AFormat, FTable,
      SelectedSourceMode);
  ShowSchema(FTable);
  SetStatus(TStatusKind.Success,
    Format('Projected into the DataSet - %s, %d rows, %d columns, %s',
      [FormatLabel(AFormat), FTable.RecordCount, FTable.FieldDefs.Count,
       FSourceMode.Items[FSourceMode.ItemIndex]]),
    FDetected.Caption);
end;

procedure TLiveConverterForm.DoFromSource(Sender: TObject);
begin
  try
    ProjectInto(SourcePayload, SelectedSourceFormat);
  except
    on E: Exception do Failed(E, 'DataSet projection failed');
  end;
end;

procedure TLiveConverterForm.DoFromResult(Sender: TObject);
begin
  try
    { The result as it IS - the payload the conversion produced - rather
      than the text of whichever view is on screen. }
    if not FHasResult then
      raise EConverterInput.Create(
        'There is no converted result yet. Convert first, or use From source.');
    ProjectInto(FLastResult, FLastResultFormat);
  except
    on E: Exception do Failed(E, 'DataSet projection failed');
  end;
end;

procedure TLiveConverterForm.DoSerializeDataSet(Sender: TObject);
var
  F: TSerializationFormat;
  Payload: TSerializationPayload;
  Display: TBinaryDisplay;
begin
  try
    if not FTable.Active then
      raise EConverterInput.Create(
        'There is no table yet. Project a document into one first.');
    F := SelectedDataSetFormat;
    Payload := TDataSetSerializer.Serialize(FTable, F, SelectedPolicy);
    Display := SelectedSourceBytes;
    if (Display = TBinaryDisplay.NativeText) and
       (F <> TSerializationFormat.Bson) then
      Display := TBinaryDisplay.Hex;
    if Payload.IsBinary then SetSourceBytes(Display);
    FSource.Lines.Text := Render(Payload, F, Display);
    FSourceFormat.ItemIndex := FDataSetFormat.ItemIndex;
    DoFormatChanged(nil);
    SetStatus(TStatusKind.Success,
      Format('DataSet written to the source - %s, %s',
        [FormatLabel(F), FDataSetPolicy.Items[FDataSetPolicy.ItemIndex]]),
      'It can be converted onwards, or read straight back with From source.');
  except
    on E: Exception do Failed(E, 'DataSet not written');
  end;
end;

{ ---------------------------------------------------------- copy and save - }

function TLiveConverterForm.ResultClipboardText: string;
begin
  { What is on screen: for a binary result, the hex or base64 being viewed. }
  Result := FResult.Lines.Text;
end;

procedure TLiveConverterForm.SaveResultTo(const APath: string);
begin
  { The document itself: bytes for a binary result - never its hex - and
    UTF-8 without a BOM for text. }
  if FHasResult and FLastResult.IsBinary then
    TFile.WriteAllBytes(APath, FLastResult.AsBytes)
  else if FHasResult then
    TFile.WriteAllBytes(APath, TEncoding.UTF8.GetBytes(FLastResult.AsText))
  else
    TFile.WriteAllBytes(APath, TEncoding.UTF8.GetBytes(FResult.Lines.Text));
end;

procedure TLiveConverterForm.DoCopy(Sender: TObject);
begin
  if FResult.Lines.Text = '' then
  begin
    SetStatus(TStatusKind.Info, 'Nothing to copy', 'Convert first.');
    Exit;
  end;
  Clipboard.AsText := ResultClipboardText;
  SetStatus(TStatusKind.Info, 'Result copied to the clipboard',
    FSizeLabel.Caption);
end;

procedure TLiveConverterForm.DoSave(Sender: TObject);
var
  Dialog: TSaveDialog;
  Folder: TFileOpenDialog;
  Ext: string;
begin
  if FTables <> nil then
  begin
    { A document set is several files: a folder is chosen and every table
      is written into it. }
    Folder := TFileOpenDialog.Create(Self);
    try
      Folder.Title := 'Save every table into a folder';
      Folder.Options := Folder.Options + [fdoPickFolders, fdoPathMustExist];
      if Folder.Execute then
      try
        SaveTablesTo(Folder.FileName);
        SetStatus(TStatusKind.Success,
          Format('Saved - %d tables as .csv', [FTables.Count]),
          Folder.FileName);
      except
        on E: Exception do Failed(E, 'Not saved');
      end;
    finally
      Folder.Free;
    end;
    Exit;
  end;
  if FResult.Lines.Text = '' then
  begin
    SetStatus(TStatusKind.Info, 'Nothing to save', 'Convert first.');
    Exit;
  end;
  if FHasResult then Ext := FileExtension(FLastResultFormat) else Ext := '.txt';
  Dialog := TSaveDialog.Create(Self);
  try
    Dialog.DefaultExt := Copy(Ext, 2, MaxInt);
    Dialog.FileName := 'result' + Ext;
    Dialog.Filter := Format('%s (*%s)|*%s|All files (*.*)|*.*',
      [UpperCase(Copy(Ext, 2, MaxInt)), Ext, Ext]);
    Dialog.Options := Dialog.Options + [ofOverwritePrompt];
    if Dialog.Execute then
    try
      SaveResultTo(Dialog.FileName);
      SetStatus(TStatusKind.Success, 'Saved - ' +
        ExtractFileName(Dialog.FileName), Dialog.FileName);
    except
      on E: Exception do Failed(E, 'Not saved');
    end;
  finally
    Dialog.Free;
  end;
end;

procedure TLiveConverterForm.DoDetails(Sender: TObject);
begin
  if FStatusDetails <> '' then
    MessageDlg(FStatusDetails, mtInformation, [mbOK], 0);
end;

{ ------------------------------------------------------------- keyboard -- }

procedure TLiveConverterForm.FormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
var
  Mods: TShiftState;
begin
  Mods := Shift * [ssShift, ssCtrl, ssAlt];
  FSwallowChar := False;
  if (Key = VK_RETURN) and (Mods = [ssCtrl]) then
  begin
    Key := 0;
    FSwallowChar := True;
    if FConvert.Enabled then FConvert.Click else RefreshCapability;
  end
  else if (Key = Ord('L')) and (Mods = [ssCtrl]) then
  begin
    Key := 0;
    FSwallowChar := True;
    FLoadSample.Click;
  end
  else if (Key = Ord('S')) and (Mods = [ssCtrl, ssShift]) then
  begin
    Key := 0;
    FSwallowChar := True;
    FSwap.Click;
  end
  else if (Key = Ord('C')) and (Mods = [ssCtrl]) and
          (ActiveControl = FResult) and (FResult.SelLength = 0) then
  begin
    { With a selection the memo copies it, as it always does; with none,
      Ctrl+C in the result means the whole result. The source editor's own
      copy and paste are never touched. }
    Key := 0;
    DoCopy(nil);
  end;
end;

procedure TLiveConverterForm.FormKeyPress(Sender: TObject; var Key: Char);
begin
  { Ctrl+Enter, Ctrl+L and Ctrl+Shift+S also arrive as the control
    characters 10, 12 and 19; the editor must not receive them. }
  if FSwallowChar and CharInSet(Key, [#10, #12, #19]) then Key := #0;
  FSwallowChar := False;
end;

{ ------------------------------------------------------------- self-test -- }

function TLiveConverterForm.SelfTest: Integer;
var
  Failures: Integer;
  Registered, Tables: Integer;
  Visible, AllHints: Boolean;
  Fmt: TSerializationFormat;
  P: TStructuralConversionProfile;
  Key: Word;
  Before: string;
  OldSource, OldDest: Integer;
  TempFile: string;
  Saved: TBytes;
  Startup: TArray<string>;
  I: Integer;

  procedure Check(ACondition: Boolean; const AName: string);
  begin
    if ACondition then Writeln(AName, ': PASS')
    else
    begin
      Writeln(AName, ': FAIL');
      Writeln('  status : ', FStatusSummary.Caption);
      Writeln('  detail : ', StringReplace(FStatusDetails, sLineBreak, ' | ',
        [rfReplaceAll]));
      Inc(Failures);
    end;
  end;

  { A combo changed the way a user changes it: the selection, then the
    event the control would have fired. }
  procedure PickCombo(ACombo: TComboBox; AIndex: Integer);
  begin
    ACombo.ItemIndex := AIndex;
    if Assigned(ACombo.OnChange) then ACombo.OnChange(ACombo);
  end;

  procedure SetMode(AProfile: TStructuralConversionProfile);
  begin
    FModeButtons[AProfile].Click;
  end;

  procedure SetView(ADisplay: TBinaryDisplay);
  begin
    FViewButtons[ADisplay].Click;
  end;

  procedure SetBytes(ADisplay: TBinaryDisplay);
  begin
    SetSourceBytes(ADisplay);
    if Assigned(FSourceBytesAs.OnChange) then FSourceBytesAs.OnChange(FSourceBytesAs);
  end;

  procedure Select(AFrom, ATo: TSerializationFormat;
    AProfile: TStructuralConversionProfile);
  begin
    PickCombo(FSourceFormat, FormatIndex(AFrom));
    PickCombo(FDestFormat, FormatIndex(ATo));
    SetMode(AProfile);
  end;

  { Load the bundled schema for a format, exactly as the card's button does:
    the format goes on the result side, the card appears there, the file box
    is left empty and Load is pressed. }
  procedure LoadContext(AFormat: TSerializationFormat; const ARoot: string);
  begin
    Select(TSerializationFormat.Json, AFormat,
      TStructuralConversionProfile.Natural);
    FCtxPath[1].Text := '';
    FCtxLoad[1].Click;
    if ARoot <> '' then
      PickCombo(FCtxRoot[1], FCtxRoot[1].Items.IndexOf(ARoot));
  end;

  { One schema-driven format, all the way into the grid, through the
    ordinary generic call and nothing else. }
  function SchemaDrivenDataSet(AFormat: TSerializationFormat): Boolean;
  begin
    FSource.Lines.Text := SampleSubject;
    Select(TSerializationFormat.Json, AFormat,
      TStructuralConversionProfile.Natural);
    SetView(TBinaryDisplay.Hex);
    FConvert.Click;
    FSwap.Click;
    FFromSource.Click;
    Result := FTable.Active and (FTable.RecordCount = 1) and
      (FTable.FieldDefs.Count = 4) and
      (FTable.FieldByName('city').AsString = 'Midtown');
    if Result then Inc(Tables);
  end;

  function Shortcut(AKey: Word; AShift: TShiftState): Word;
  begin
    Result := AKey;
    FormKeyDown(Self, Result, AShift);
  end;

begin
  Failures := 0;
  Tables := 0;

  { --- opening the window raises nothing --------------------------------- }

  { The program started counting before registration; the form has been
    built and its first sample loaded. One Convert of that sample is the
    first thing a user does, so it is inside the count too. Whatever was
    raised is printed by class and message, whether or not it was caught. }
  FConvert.Click;
  StopCountingExceptions;
  Startup := CountedExceptions;
  Writeln('  exceptions raised at startup: ', Length(Startup));
  for I := 0 to High(Startup) do
    Writeln('    ', Startup[I]);
  Check((Length(Startup) = 0) and
        (Pos('Converted successfully', FStatusSummary.Caption) = 1),
    'NO_EXCEPTION_AT_STARTUP');
  { And the counter is not blind: one raise, handled, is one count. }
  StartCountingExceptions;
  try
    raise EConverterInput.Create('counter probe');
  except
    on EConverterInput do ;
  end;
  StopCountingExceptions;
  Check((Length(CountedExceptions) = 1) and
        (CountedExceptions[0] = 'EConverterInput: counter probe'),
    'VCL_EXCEPTION_COUNTER_SEES_A_RAISE');

  Check(FSourceFormat.Items.Count >= 3,
    'DEMO_FORMATS_COME_FROM_THE_REGISTRY');

  { --- the layout: what is visible first ---------------------------------- }
  Check((FTitle.Caption = 'Live Format Converter') and
        (FSubtitle.Caption =
          'Convert structured data between PascalForge formats'),
    'VCL_HEADER');
  FSource.Lines.Text := SampleJson;
  Select(TSerializationFormat.Json, TSerializationFormat.Xml,
    TStructuralConversionProfile.Natural);
  Check(not FCtxCard[0].Visible and
        not FCtxCard[1].Visible and not FSourceBytesAs.Visible and
        FConvert.Primary and
        (FPages.PageCount = 2) and FPayloadTab.TabVisible and
        FDataSetTab.TabVisible,
    'VCL_PROGRESSIVE_DISCLOSURE');

  AllHints := True;
  for P := Low(TStructuralConversionProfile) to High(TStructuralConversionProfile) do
  begin
    SetMode(P);
    if (FModeHint.Caption <> MODE_HINTS[P]) or not FModeButtons[P].Toggled then
      AllHints := False;
  end;
  Check(AllHints and
    (MODE_HINTS[TStructuralConversionProfile.Natural] =
      'Best destination-native representation.') and
    (MODE_HINTS[TStructuralConversionProfile.Lossless] =
      'Preserve semantic information using published standard mappings.') and
    (MODE_HINTS[TStructuralConversionProfile.Strict] =
      'Reject adaptations that would lose or change meaning.'),
    'VCL_ONE_MODE_SELECTOR_ONE_EXPLANATION');

  { --- the sample, JSON to XML and back ---------------------------------- }
  FSource.Lines.Text := SampleJson;
  Select(TSerializationFormat.Json, TSerializationFormat.Xml,
    TStructuralConversionProfile.Lossless);
  FConvert.Click;
  Check(Pos('xpath-functions', FResult.Lines.Text) > 0,
    'DEMO_LOSSLESS_XML_IS_THE_W3C_MAPPING');
  Check(Pos(GEO_NAME, FResult.Lines.Text) > 0, 'DEMO_XML_KEEPS_GEORGIAN');
  Writeln('  status: ', FStatusSummary.Caption);
  Check(FStatusSummary.Caption =
    'Converted successfully - JSON -> XML - Lossless - W3C JSON/XML mapping',
    'VCL_STATUS_SAYS_WHAT_HAPPENED');
  Check(not FViewBar.Visible and not FDetailsButton.Visible,
    'VCL_TEXT_RESULT_HAS_NO_BINARY_VIEW');

  FSwap.Click;
  FConvert.Click;
  Check(Pos('"$type":"Subject"', FResult.Lines.Text) > 0,
    'DEMO_W3C_ROUND_TRIP_KEEPS_THE_NAME');
  Check(Pos(GEO_CITY, FResult.Lines.Text) > 0,
    'DEMO_ROUND_TRIP_KEEPS_GEORGIAN');
  Check(Pos('&lt;Reply', FResult.Lines.Text) = 0,
    'DEMO_EMBEDDED_XML_STAYED_A_STRING');

  { --- the keyboard ------------------------------------------------------ }
  FSource.Lines.Text := SampleJson;
  Select(TSerializationFormat.Json, TSerializationFormat.Yaml,
    TStructuralConversionProfile.Natural);
  ClearResult;
  Key := Shortcut(VK_RETURN, [ssCtrl]);
  Check((Key = 0) and (Pos('Converted successfully', FStatusSummary.Caption) = 1)
        and (Pos('Name:', FResult.Lines.Text) > 0),
    'VCL_CTRL_ENTER_CONVERTS');
  OldSource := FSourceFormat.ItemIndex;
  OldDest := FDestFormat.ItemIndex;
  Key := Shortcut(Ord('S'), [ssCtrl, ssShift]);
  Check((Key = 0) and (FSourceFormat.ItemIndex = OldDest) and
        (FDestFormat.ItemIndex = OldSource) and
        (Pos('Name:', FSource.Lines.Text) > 0),
    'VCL_CTRL_SHIFT_S_SWAPS');
  Before := FSource.Lines.Text;
  Key := Shortcut(Ord('L'), [ssCtrl]);
  Check((Key = 0) and (FSource.Lines.Text <> Before) and
        (Pos('Sample loaded', FStatusSummary.Caption) = 1),
    'VCL_CTRL_L_LOADS_A_SAMPLE');
  { Ctrl+C belongs to whichever editor has the focus unless it is the
    result with nothing selected. }
  ActiveControl := nil;
  Key := Shortcut(Ord('C'), [ssCtrl]);
  Check(Key = Ord('C'), 'VCL_CTRL_C_LEFT_TO_THE_EDITOR');

  { --- Strict refuses, and says where, and clears nothing ---------------- }
  FSource.Lines.Text := SampleJson;
  Select(TSerializationFormat.Json, TSerializationFormat.Xml,
    TStructuralConversionProfile.Strict);
  FResult.Lines.Text := 'kept';
  FConvert.Click;
  Writeln('  status: ', FStatusSummary.Caption);
  Check(Pos('InvalidDestinationName', FStatusDetails) > 0,
    'DEMO_STRICT_REFUSAL_IS_REPORTED');
  Check((Pos('Representation refused', FStatusSummary.Caption) = 1) and
        (Pos('EStructuralConversionError', FStatusSummary.Caption) = 0) and
        (Pos('EStructuralConversionError', FStatusDetails) > 0) and
        FDetailsButton.Visible,
    'VCL_RAW_EXCEPTION_ONLY_BEHIND_DETAILS');
  Check(FResult.Lines.Text = 'kept', 'DEMO_FAILURE_IS_NON_DESTRUCTIVE');
  Check(FSource.Lines.Text = SampleJson, 'DEMO_SOURCE_SURVIVES_A_FAILURE');

  { --- BSON, under the library's own BSON-and-JSON mapping --------------- }
  Select(TSerializationFormat.Bson, TSerializationFormat.Json,
    TStructuralConversionProfile.Natural);
  SetBytes(TBinaryDisplay.Hex);
  FSource.Lines.Text := HexView(SampleBson);
  FConvert.Click;
  { Natural: idiomatic JSON, the BSON-only types as plain values. }
  Check(Pos('"_id":"507f1f77bcf86cd799439011"', FResult.Lines.Text) > 0,
    'DEMO_BSON_PLAIN_JSON');
  Check(Pos('$oid', FResult.Lines.Text) = 0,
    'DEMO_BSON_PLAIN_JSON_HAS_NO_MARKERS');
  Check(Pos(GEO_NAME, FResult.Lines.Text) > 0,
    'DEMO_BSON_PLAIN_JSON_KEEPS_GEORGIAN');

  { Lossless: MongoDB Extended JSON, a published standard. }
  Select(TSerializationFormat.Bson, TSerializationFormat.Json,
    TStructuralConversionProfile.Lossless);
  SetBytes(TBinaryDisplay.Hex);
  FSource.Lines.Text := HexView(SampleBson);
  FConvert.Click;
  Check((Pos('$oid', FResult.Lines.Text) > 0) and
        (Pos('$numberDecimal', FResult.Lines.Text) > 0) and
        (Pos('$binary', FResult.Lines.Text) > 0),
    'DEMO_BSON_EXTENDED_JSON');

  { The same bytes, typed three ways. The source is re-read in whatever
    "Bytes as" says, so each of these is a full round trip through that
    spelling. }
  FSource.Lines.Text := TStructuralText.EncodeBinary(SampleBson);
  SetBytes(TBinaryDisplay.Base64);
  FConvert.Click;
  Check(Pos('$oid', FResult.Lines.Text) > 0, 'DEMO_BINARY_DISPLAY_BASE64');

  FSource.Lines.Text := SampleExtendedJson;
  SetBytes(TBinaryDisplay.NativeText);
  FConvert.Click;
  Check(Pos('$numberDecimal', FResult.Lines.Text) > 0,
    'DEMO_BINARY_DISPLAY_EXTENDED_JSON');

  { BSON to JSON is the registry's conversion, under the chosen mode. }
  SetBytes(TBinaryDisplay.Hex);
  FSource.Lines.Text := HexView(SampleBson);
  SetMode(TStructuralConversionProfile.Lossless);
  FConvert.Click;
  Writeln('  status: ', FStatusSummary.Caption);
  Check((Pos('$oid', FResult.Lines.Text) > 0) and
        (Pos('Converted successfully - BSON -> JSON - Lossless',
          FStatusSummary.Caption) = 1),
    'DEMO_BSON_TO_JSON_FOLLOWS_THE_MODE');

  { And back to BSON, exactly. }
  Select(TSerializationFormat.Json, TSerializationFormat.Bson,
    TStructuralConversionProfile.Lossless);
  FSource.Lines.Text := SampleExtendedJson;
  FConvert.Click;
  Check(FViewButtons[TBinaryDisplay.Hex].Toggled and
    SameText(Compact(FResult.Lines.Text),
      TStructuralText.EncodeHex(SampleBson)),
    'DEMO_EXTENDED_JSON_BACK_TO_THE_SAME_BYTES');
  Check(FViewBar.Visible and
        (FSizeLabel.Caption = BytesText(Length(SampleBson))) and
        (Pos('bytes', FSizeLabel.Caption) > 0),
    'VCL_BINARY_RESULT_SHOWS_ITS_SIZE');
  SetView(TBinaryDisplay.Base64);
  Check(Compact(FResult.Lines.Text) = TStructuralText.EncodeBinary(SampleBson),
    'VCL_VIEW_BASE64');
  Check(ResultClipboardText = FResult.Lines.Text, 'VCL_COPY_TAKES_THE_VIEW');
  TempFile := TPath.Combine(TPath.GetTempPath,
    'LiveFormatConverter.selftest.bson');
  SaveResultTo(TempFile);
  Saved := TFile.ReadAllBytes(TempFile);
  TFile.Delete(TempFile);
  Check(SameText(TStructuralText.EncodeHex(Saved),
    TStructuralText.EncodeHex(SampleBson)), 'VCL_SAVE_WRITES_THE_BYTES');
  SetView(TBinaryDisplay.Hex);

  { --- the lossless route, composed and named --------------------------- }
  Select(TSerializationFormat.Bson, TSerializationFormat.Xml,
    TStructuralConversionProfile.Lossless);
  Check(not FHasResult and (FResult.Lines.Text = '') and not FViewBar.Visible,
    'VCL_NEW_DESTINATION_CLEARS_A_STALE_RESULT');
  SetBytes(TBinaryDisplay.Hex);
  FSource.Lines.Text := HexView(SampleBson);
  FConvert.Click;
  Writeln('  ', FStatusSecondary.Caption);
  Check((Pos('xpath-functions', FResult.Lines.Text) > 0) and
        (Pos('507f1f77bcf86cd799439011', FResult.Lines.Text) > 0),
    'DEMO_LOSSLESS_BSON_TO_XML');
  Check(Pos('Route: BSON -> MongoDB Extended JSON -> JSON -> W3C JSON/XML -> XML',
    FStatusSecondary.Caption) = 1, 'VCL_LOSSLESS_ROUTE_IS_SHOWN');

  { --- CBOR in the same window, with no CBOR-specific code path ---------- }

  { CBOR arrived in the dropdowns by being registered, and nothing in the
    form was edited to let it in. This is that claim, tested. }
  Check((FormatIndex(TSerializationFormat.Cbor) >= 0) and
    (FSourceFormat.Items.IndexOf(FormatLabel(TSerializationFormat.Cbor)) >= 0),
    'DEMO_CBOR_IN_THE_DROPDOWN');

  Select(TSerializationFormat.Json, TSerializationFormat.Cbor,
    TStructuralConversionProfile.Lossless);
  SetView(TBinaryDisplay.Hex);
  FSource.Lines.Text := '{"a":1,"b":[2,3]}';
  FConvert.Click;
  Check(SameText(Compact(FResult.Lines.Text), 'A26161016162820203'),
    'DEMO_JSON_TO_CBOR_BYTES');
  Check(FSizeLabel.Caption = '9 bytes', 'VCL_CBOR_SIZE');

  { The standard text form of a CBOR document is RFC 8949 diagnostic
    notation, and that is what the demo shows - not the bytes run through a
    UTF-8 decoder, which is how a binary format becomes mojibake on screen. }
  Check(FViewButtons[TBinaryDisplay.NativeText].Visible,
    'VCL_CBOR_OFFERS_ITS_TEXT_FORM');
  SetView(TBinaryDisplay.NativeText);
  Check((Pos('"a": 1', FResult.Lines.Text) > 0) and
        (Pos('[2, 3]', FResult.Lines.Text) > 0),
    'DEMO_CBOR_DIAGNOSTIC_NOTATION');
  SetView(TBinaryDisplay.Hex);

  Select(TSerializationFormat.Cbor, TSerializationFormat.Json,
    TStructuralConversionProfile.Lossless);
  SetBytes(TBinaryDisplay.Hex);
  FSource.Lines.Text := 'A26161016162820203';
  FConvert.Click;
  Check(Pos('"a":1', Compact(FResult.Lines.Text)) > 0, 'DEMO_CBOR_TO_JSON');

  { --- MessagePack, likewise arriving by registration alone ------------- }

  Check((FormatIndex(TSerializationFormat.MessagePack) >= 0) and
    (FSourceFormat.Items.IndexOf(
      FormatLabel(TSerializationFormat.MessagePack)) >= 0),
    'DEMO_MESSAGEPACK_IN_THE_DROPDOWN');

  Select(TSerializationFormat.Json, TSerializationFormat.MessagePack,
    TStructuralConversionProfile.Lossless);
  FSource.Lines.Text := '{"a":1,"b":[2,3]}';
  FConvert.Click;
  Check(SameText(Compact(FResult.Lines.Text), '82a16101a162920203'),
    'DEMO_JSON_TO_MESSAGEPACK_BYTES');
  { MessagePack has no standard text form, so the view does not offer one. }
  Check(not FViewButtons[TBinaryDisplay.NativeText].Visible,
    'VCL_MESSAGEPACK_OFFERS_NO_TEXT_VIEW');

  Select(TSerializationFormat.MessagePack, TSerializationFormat.Json,
    TStructuralConversionProfile.Lossless);
  SetBytes(TBinaryDisplay.Hex);
  FSource.Lines.Text := '82A16101A162920203';
  FConvert.Click;
  Check(Pos('"a":1', Compact(FResult.Lines.Text)) > 0,
    'DEMO_MESSAGEPACK_TO_JSON');

  { Nor can it be typed as one: the demo says so rather than decoding the
    text as UTF-8 and calling that MessagePack. }
  SetBytes(TBinaryDisplay.NativeText);
  FConvert.Click;
  Check(Pos('no standard text form', FStatusSummary.Caption) > 0,
    'DEMO_MESSAGEPACK_HAS_NO_TEXT_FORM');
  SetBytes(TBinaryDisplay.Hex);

  { --- YAML, a TEXT format, shown as itself --------------------------- }

  Check((FormatIndex(TSerializationFormat.Yaml) >= 0) and
    (FSourceFormat.Items.IndexOf(FormatLabel(TSerializationFormat.Yaml)) >= 0),
    'DEMO_YAML_IN_THE_DROPDOWN');

  Select(TSerializationFormat.Json, TSerializationFormat.Yaml,
    TStructuralConversionProfile.Lossless);
  FSource.Lines.Text := '{"a":1,"b":[2,3],"c":"true"}';
  FConvert.Click;
  Check(Pos('a: 1', FResult.Lines.Text) > 0, 'DEMO_JSON_TO_YAML');
  { The string "true" has to arrive quoted, or the next reader gets a
    boolean and nobody notices until much later. }
  Check(Pos('c: "true"', FResult.Lines.Text) > 0,
    'DEMO_YAML_QUOTES_A_LOOKALIKE');

  Select(TSerializationFormat.Yaml, TSerializationFormat.Json,
    TStructuralConversionProfile.Lossless);
  FSource.Lines.Text := 'a: 1' + sLineBreak + 'b:' + sLineBreak +
                        '  - 2' + sLineBreak + '  - 3';
  FConvert.Click;
  Check(Pos('"a":1', Compact(FResult.Lines.Text)) > 0, 'DEMO_YAML_TO_JSON');

  { --- CSV, which is a table and says so when it is handed something that
        is not one ------------------------------------------------------- }

  Check((FormatIndex(TSerializationFormat.Csv) >= 0) and
    (FSourceFormat.Items.IndexOf(FormatLabel(TSerializationFormat.Csv)) >= 0),
    'DEMO_CSV_IN_THE_DROPDOWN');

  Select(TSerializationFormat.Json, TSerializationFormat.Csv,
    TStructuralConversionProfile.Lossless);
  FSource.Lines.Text := '[{"id":1,"name":"Alice"},{"id":2,"name":"Carol"}]';
  FConvert.Click;
  Check(Pos('id,name', FResult.Lines.Text) > 0, 'DEMO_JSON_TO_CSV_HEADER');
  Check(Pos('2,Carol', FResult.Lines.Text) > 0, 'DEMO_JSON_TO_CSV_ROWS');

  Select(TSerializationFormat.Csv, TSerializationFormat.Json,
    TStructuralConversionProfile.Lossless);
  FSource.Lines.Text := 'id,name' + sLineBreak + '1,Alice';
  FConvert.Click;
  Check(Pos('"id":1', Compact(FResult.Lines.Text)) > 0, 'DEMO_CSV_TO_JSON');

  { A document that is not a table cannot become one, and the window says
    so instead of producing a file with invented column names. }
  Select(TSerializationFormat.Json, TSerializationFormat.Csv,
    TStructuralConversionProfile.Lossless);
  FSource.Lines.Text := '{"a":{"b":{"c":[1,2,3]}}}';
  FConvert.Click;
  Writeln('  status: ', FStatusSummary.Caption);
  Check(Pos('CollectionMode', FStatusDetails) +
        Pos('not an object', FStatusDetails) +
        Pos('no columns', FStatusDetails) > 0,
    'DEMO_CSV_EXPLAINS_A_SHAPE_IT_CANNOT_HOLD');
  Check(Pos('Representation refused - CSV', FStatusSummary.Caption) = 1,
    'VCL_CSV_REFUSAL_IN_ONE_LINE');

  { --- the CSV projection, and a document set ---------------------------- }

  Check(FCsvBar.Visible, 'CSV_DEMO_PROJECTION_SHOWN_FOR_CSV');

  { Conservative is TCsvOptions.Default: two collections are not one table,
    and the form's own handler says so - nothing escapes, nothing stale. }
  FSource.Lines.Text := SampleCustomersAndOrders;
  Select(TSerializationFormat.Json, TSerializationFormat.Csv,
    TStructuralConversionProfile.Natural);
  PickCombo(FCsvProjection, 0);
  FConvert.Click;
  Writeln('  status: ', FStatusSummary.Caption);
  Check((FStatusKind in [TStatusKind.Error, TStatusKind.Warning]) and
        ((Pos('refused', FStatusSummary.Caption) > 0) or
         (Pos('Not supported', FStatusSummary.Caption) = 1)) and
        not FHasResult and (Trim(FResult.Lines.Text) = '') and
        not FTableBar.Visible,
    'CSV_DEMO_CONSERVATIVE_REFUSAL');

  { JSON cell: one document, through the registry with a TCsvSchema. }
  PickCombo(FCsvProjection, 1);
  Check(FHasResult and not FTableBar.Visible and
        (Pos('Converted successfully - JSON -> CSV', FStatusSummary.Caption) = 1),
    'CSV_DEMO_JSON_CELL_IS_ONE_DOCUMENT');

  { Separate tables: TablesFrom, one table on screen at a time. }
  PickCombo(FCsvProjection, 3);
  Writeln('  status: ', FStatusSummary.Caption);
  Writeln('  tables: ', StringReplace(Trim(FTableCombo.Items.Text), sLineBreak,
    ', ', [rfReplaceAll]));
  Check((FTables <> nil) and FTableBar.Visible and
        (FTableCombo.Items.Count = 2) and
        (FTableCombo.Items[0] = 'customers') and
        (FTableCombo.Items[1] = 'orders') and
        (FTableCombo.Text = 'customers') and
        (Pos('id,name', FResult.Lines.Text) > 0) and
        (Pos('customerId', FResult.Lines.Text) = 0) and
        (FTableRows.Caption = '2 rows') and
        (FSave.Caption = 'Save tables...'),
    'CSV_DEMO_SEPARATE_TABLES');

  PickCombo(FTableCombo, FTableCombo.Items.IndexOf('orders'));
  Check((Pos('id,customerId', FResult.Lines.Text) > 0) and
        (Pos('name', FResult.Lines.Text) = 0) and
        (FTableRows.Caption = '2 rows'),
    'CSV_DEMO_TABLE_SWITCH');

  TempFile := TPath.Combine(TPath.GetTempPath,
    'LiveFormatConverter.selftest.tables');
  if TDirectory.Exists(TempFile) then TDirectory.Delete(TempFile, True);
  SaveTablesTo(TempFile);
  Check(TFile.Exists(TPath.Combine(TempFile, 'customers.csv')) and
        TFile.Exists(TPath.Combine(TempFile, 'orders.csv')) and
        (Length(TDirectory.GetFiles(TempFile)) = 2) and
        (Pos('id,customerId', TFile.ReadAllText(
          TPath.Combine(TempFile, 'orders.csv'), TEncoding.UTF8)) > 0),
    'CSV_DEMO_SAVE_TABLES');
  TDirectory.Delete(TempFile, True);

  { A child table, and the line that says how it joins its parent. }
  FSource.Lines.Text := SampleNestedOrders;
  FConvert.Click;
  Writeln('  tables: ', StringReplace(Trim(FTableCombo.Items.Text), sLineBreak,
    ', ', [rfReplaceAll]));
  Writeln('  ', FRelationLabel.Caption);
  Check((FTableCombo.Items.IndexOf('customers') >= 0) and
        (FTableCombo.Items.IndexOf('customers_orders') >= 0) and
        FRelationLabel.Visible and
        (Pos('customers_orders', FRelationLabel.Caption) > 0),
    'CSV_DEMO_NESTED_RELATIONSHIP');

  { The DataSet envelope is not special to CSV: two members, two tables.
    The DataSet tab, which IS about DataSets, still reads its metadata. }
  FSource.Lines.Text := SampleTable;
  FConvert.Click;
  Writeln('  tables: ', StringReplace(Trim(FTableCombo.Items.Text), sLineBreak,
    ', ', [rfReplaceAll]));
  Check((FTableCombo.Items.Count = 2) and
        (FTableCombo.Items.IndexOf('fields') >= 0) and
        (FTableCombo.Items.IndexOf('rows') >= 0),
    'CSV_DEMO_DATASET_SAMPLE_IS_ORDINARY');
  PickCombo(FSourceMode, Ord(TDataSetSourceMode.Auto));
  FFromSource.Click;
  Check(FTable.Active and (FTable.RecordCount = 2) and
        (FTable.FieldDefs.Count = 3) and
        (Pos('ValidMetadata', FDetected.Caption) > 0),
    'CSV_DEMO_DATASET_TAB_STILL_READS_THE_METADATA');

  { A new destination drops the tables with the rest of the result. }
  PickCombo(FDestFormat, FormatIndex(TSerializationFormat.Json));
  Check((FTables = nil) and not FTableBar.Visible and not FCsvBar.Visible and
        (FSave.Caption = 'Save...'),
    'CSV_DEMO_TABLES_GO_WITH_THE_DESTINATION');
  FCsvProjection.ItemIndex := 0;
  ClearResult;

  { --- EVERY registered format is in the window ------------------------- }

  { Twelve entries in the registry - ten format families, with ASN.1
    contributing three of them because BER, DER and CER are three different
    encodings and a window that offered one "ASN.1" would hide the
    difference at the one place a user decides it. }
  Registered := 0;
  Visible := True;
  for Fmt := Low(TSerializationFormat) to High(TSerializationFormat) do
    if TSerializationFormats.IsRegistered(Fmt) then
    begin
      Inc(Registered);
      if FormatIndex(Fmt) < 0 then Visible := False;
    end;
  Writeln('  registry entries: ', Registered,
          ', in the dropdown: ', FSourceFormat.Items.Count);
  Check(Registered = 12, 'DEMO_TWELVE_REGISTRY_ENTRIES');
  Check(Visible and (FSourceFormat.Items.Count = Registered) and
        (FDestFormat.Items.Count = Registered),
    'VCL_ALL_FORMATS_VISIBLE');

  { And each of the three says what it needs, in the list itself. }
  Check(Pos('needs a schema',
    FSourceFormat.Items[FormatIndex(TSerializationFormat.Protobuf)]) > 0,
    'DEMO_PROTOBUF_SAYS_WHAT_IT_NEEDS');
  Check(TSerialization.StructuralRequirement(TSerializationFormat.Avro) =
    'schema', 'DEMO_AVRO_NEEDS_A_SCHEMA');
  Check(TSerialization.IsRegistered(TSerializationFormat.Asn1Ber) and
        TSerialization.IsRegistered(TSerializationFormat.Asn1Der) and
        TSerialization.IsRegistered(TSerializationFormat.Asn1Cer),
    'DEMO_ASN1_THREE_FORMATS_REGISTERED');

  { --- what is missing, in words ---------------------------------------- }

  { A disabled control with no explanation is a dead end. Before a
    descriptor is loaded the window says which end needs what - on the card
    of that side only - and after it is loaded the same line says the
    conversion is available. }
  Select(TSerializationFormat.Json, TSerializationFormat.Protobuf,
    TStructuralConversionProfile.Natural);
  Writeln('  before: ', FCapabilityText);
  Check((Pos('descriptor', FCapabilityText) > 0) and
        (Pos('message type', FCapabilityText) > 0) and
        not FConvert.Enabled and
        (Pos('Schema required', FStatusSummary.Caption) = 1),
    'DEMO_MISSING_CONTEXT_IS_EXPLAINED');
  Check(FCtxCard[1].Visible and not FCtxCard[0].Visible and
        (Pos('descriptor', FCtxInfo[1].Caption) > 0),
    'VCL_SCHEMA_CARD_ONLY_ON_THE_SIDE_THAT_NEEDS_IT');

  { --- Protobuf, with the descriptor official protoc produced ----------- }
  LoadContext(TSerializationFormat.Protobuf, 'pfdemo.Subject');
  Writeln('  after : ', FCapabilityText);
  Check(FCtxRoot[1].Items.Count = 2, 'DEMO_DESCRIPTOR_LISTS_ITS_MESSAGES');
  Check(FConvert.Enabled and (Pos('Ready', FCapabilityText) = 1) and
        (Pos('Ready', FCtxInfo[1].Caption) = 1),
    'DEMO_CAPABILITY_REFRESHES_WHEN_SUPPLIED');

  FSource.Lines.Text := SampleSubject;
  Select(TSerializationFormat.Json, TSerializationFormat.Protobuf,
    TStructuralConversionProfile.Natural);
  SetView(TBinaryDisplay.Hex);
  FConvert.Click;
  Check(FHasResult and FLastResult.IsBinary and
        (Length(Trim(FResult.Lines.Text)) > 0), 'DEMO_JSON_TO_PROTOBUF');
  FSwap.Click;
  Check(FCtxCard[0].Visible and not FCtxCard[1].Visible,
    'VCL_SCHEMA_CARD_FOLLOWS_A_SWAP');
  FConvert.Click;
  Check(Pos('Alice', FResult.Lines.Text) > 0, 'DEMO_PROTOBUF_TO_JSON');

  { --- Avro, with a schema --------------------------------------------- }
  LoadContext(TSerializationFormat.Avro, '');
  FSource.Lines.Text := SampleSubject;
  Select(TSerializationFormat.Json, TSerializationFormat.Avro,
    TStructuralConversionProfile.Natural);
  FConvert.Click;
  Check(Length(Trim(FResult.Lines.Text)) > 0, 'DEMO_JSON_TO_AVRO');
  FSwap.Click;
  FConvert.Click;
  Check(Pos('Midtown', FResult.Lines.Text) > 0, 'DEMO_AVRO_TO_JSON');

  { --- ASN.1, with a module that declares more than one type ----------- }
  LoadContext(TSerializationFormat.Asn1Der, 'Subject');
  Check(FCtxRoot[1].Items.Count = 2, 'DEMO_MODULE_LISTS_ITS_TYPES');
  FSource.Lines.Text := SampleSubject;
  Select(TSerializationFormat.Json, TSerializationFormat.Asn1Der,
    TStructuralConversionProfile.Natural);
  FConvert.Click;
  Check(Length(Trim(FResult.Lines.Text)) > 0, 'DEMO_JSON_TO_ASN1_DER');
  FSwap.Click;
  FConvert.Click;
  Check(Pos('Alice', FResult.Lines.Text) > 0, 'DEMO_ASN1_DER_TO_JSON');

  Check((FProtoSchema <> nil) and (FAvroSchema <> nil) and
        (FAsn1Schema <> nil) and (FProtoMessage = 'pfdemo.Subject') and
        (FAsn1Root = 'Subject'),
    'VCL_SCHEMA_CONTEXT_LOADING');

  { --- and the same generic DataSet API, for all three ------------------ }

  { Protobuf + descriptor, Avro + schema, ASN.1 + module and root type, each
    projected with TDataSetSerializer and nothing format-specific. }
  Check(SchemaDrivenDataSet(TSerializationFormat.Protobuf),
    'DEMO_PROTOBUF_DATASET');
  Check(SchemaDrivenDataSet(TSerializationFormat.Avro),
    'DEMO_AVRO_DATASET');
  Check(SchemaDrivenDataSet(TSerializationFormat.Asn1Der),
    'DEMO_ASN1_DATASET');
  Check(Tables = 3, 'VCL_SCHEMA_DRIVEN_DATASET');

  { --- the DataSet tab --------------------------------------------------- }
  FSource.Lines.Text := SampleTable;
  Select(TSerializationFormat.Json, TSerializationFormat.Json,
    TStructuralConversionProfile.Natural);
  PickCombo(FSourceMode, Ord(TDataSetSourceMode.Auto));
  FFromSource.Click;
  Check(FTable.Active and (FTable.RecordCount = 2) and
        (FTable.FieldDefs.Count = 3), 'DEMO_DATASET_FROM_SOURCE');
  Check(FPages.ActivePage = FDataSetTab, 'VCL_PROJECTION_SHOWS_THE_DATASET_TAB');
  Check(Pos('ValidMetadata', FDetected.Caption) > 0,
    'DEMO_DETECTED_MODE_IS_SHOWN');
  Check((FSchemaGrid.Cells[0, 1] = 'Id') and
        (FSchemaGrid.Cells[1, 1] = 'ftInteger') and
        (FSchemaGrid.Cells[1, 3] = 'ftCurrency') and
        (FSchemaGrid.Cells[2, 2] = '60') and
        (FSchemaGrid.Cells[3, 1] = 'True'),
    'DEMO_SCHEMA_GRID_SHOWS_EVERY_COLUMN');
  Check(FTable.FieldByName('Name').AsString = GEO_NAME,
    'DEMO_DATASET_KEEPS_GEORGIAN');

  PickCombo(FSourceMode, Ord(TDataSetSourceMode.InferStructure));
  FFromSource.Click;
  Check((FTable.FindField('fields') <> nil),
    'DEMO_INFER_MODE_OVERRIDES_THE_SCHEMA');

  PickCombo(FSourceMode, Ord(TDataSetSourceMode.Auto));
  FFromSource.Click;

  { From the RESULT: convert the table document to XML, project that. }
  FConvert.Click;
  PickCombo(FDestFormat, FormatIndex(TSerializationFormat.Xml));
  FConvert.Click;
  FFromResult.Click;
  Check(FTable.Active and (FTable.RecordCount = 2) and
        (Pos('Projected into the DataSet - XML', FStatusSummary.Caption) = 1),
    'VCL_DATASET_FROM_RESULT');
  FFromSource.Click;

  { --- and back out, in a different format ------------------------------- }
  PickCombo(FDataSetFormat, FormatIndex(TSerializationFormat.Xml));
  PickCombo(FDataSetPolicy, Ord(TDataSetSerializationPolicy.StructureAndRows));
  FSerializeDataSet.Click;
  Check(Pos('<fields>', FSource.Lines.Text) > 0,
    'DEMO_SERIALIZE_DATASET_AS_XML');
  Check(Pos(GEO_CITY, FSource.Lines.Text) > 0,
    'DEMO_SERIALIZED_DATASET_KEEPS_GEORGIAN');

  FFromSource.Click;
  Check(FTable.Active and (FTable.RecordCount = 2) and
        (FTable.FieldByName('Amount').DataType = ftCurrency),
    'DEMO_DATASET_ROUND_TRIPS_THROUGH_XML');

  PickCombo(FDataSetPolicy, Ord(TDataSetSerializationPolicy.RowsOnly));
  PickCombo(FDataSetFormat, FormatIndex(TSerializationFormat.Json));
  FSerializeDataSet.Click;
  FFromSource.Click;
  Check(Pos('NotMetadata', FDetected.Caption) > 0,
    'DEMO_ROWS_ONLY_IS_REPORTED_AS_AMBIGUOUS');

  { --- a failure in the DataSet tab is non-destructive too --------------- }
  PickCombo(FSourceMode, Ord(TDataSetSourceMode.EmbeddedStructure));
  FFromSource.Click;
  Check(FTable.Active, 'DEMO_DATASET_SURVIVES_A_FAILED_READ');
  Check(Pos('EmbeddedStructure', FStatusDetails) > 0,
    'DEMO_EMBEDDED_MODE_FAILURE_IS_EXPLAINED');

  Result := Failures;
end;

end.
