{*******************************************************************************
  PascalForge.Xml.Internal

  INTERNAL IMPLEMENTATION UNIT - applications should not use this unit directly.

  Implements the XML engine: reader, writer and the plan-based contract engine.
  Exposed through the public facade PascalForge.Xml (TXmlSerializer).

  Registration
    Format registration lives in PascalForge.Xml.Registration and is explicit.

  Documentation
    docs/formats/xml.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Xml.Internal;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  The XML engine.

  Not public API. Use TXmlSerializer.

  Three parts, in the order they appear below:

    1. a reader   - XML text -> TXmlElement tree
    2. a writer   - TXmlElement tree -> XML text
    3. the engine - Delphi value <-> TXmlElement tree, through cached plans

  The engine talks to XML and to Delphi and to nothing else. It has no
  reference to PascalForge.Json, to PascalForge.Bson, or to any other format:
  the only way another format enters this unit is through the registry in
  PascalForge.Serialization.Core, by TSerializationFormat, at run time.

  What IS shared, deliberately, is the Delphi type foundation: which records
  are nullables, which classes are collections, how a type is named and
  keyed. Those are facts about Delphi rather than about XML, and two formats
  disagreeing about them would be a bug, not a feature.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.SyncObjs, System.DateUtils, System.Math, System.NetEncoding,
  System.Generics.Collections,
  PascalForge.Serialization.Core, PascalForge.Dynamic,
  PascalForge.Serialization.Internal,
  PascalForge.Xml;

const
  { xsi:nil is how XML says "deliberately empty" rather than "absent". }
  XSI_NAMESPACE = 'http://www.w3.org/2001/XMLSchema-instance';

  { THE W3C JSON/XML MAPPING

    Lossless structural conversion into XML needs a way to record, in a
    format that has no types at all, what each value actually was.

    The W3C already specified one. "XPath and XQuery Functions and Operators
    3.1" defines fn:json-to-xml and fn:xml-to-json, a complete bidirectional
    mapping between JSON's data model and an XML vocabulary in the namespace
    below. It is implemented by every XSLT 3.0 and XQuery 3.1 processor -
    Saxon, BaseX, eXist - which means a document this library writes under
    the Lossless profile can be read by tools that have never heard of this
    library.

    That is the entire reason it is used instead of something invented here.
    A private convention would have been quicker to write and would have
    made the output worthless to everybody else.

        <map xmlns="http://www.w3.org/2005/xpath-functions">
          <number key="Id">1</number>
          <boolean key="Active">true</boolean>
          <array key="Tags"/>
          <null key="Rating"/>
        </map>

    Member names live in the key ATTRIBUTE, not in the element name, so
    there is no name to encode: "$type", a Georgian identifier and a name
    with a space in it are all written as themselves. }
  W3C_JSON_NAMESPACE = 'http://www.w3.org/2005/xpath-functions';

  W3C_MAP     = 'map';
  W3C_ARRAY   = 'array';
  W3C_STRING  = 'string';
  W3C_NUMBER  = 'number';
  W3C_BOOLEAN = 'boolean';
  W3C_NULL    = 'null';

  { The attributes the mapping defines. "key" carries a map member's name;
    "escaped" and "escaped-key" say that the content or the key uses JSON
    backslash escapes, which is how the mapping carries text that XML itself
    cannot hold. }
  W3C_KEY         = 'key';
  W3C_ESCAPED     = 'escaped';
  W3C_ESCAPED_KEY = 'escaped-key';

type
  TXmlKind = (
    Unsupported,
    BoolValue, IntValue, Int64Value, FloatValue, CurrencyValue, StrValue,
    DateValue, TimeValue, DateTimeValue, GuidValue, BytesValue,
    EnumValue, SetValue, NullableValue,
    ObjectValue, RecordValue,
    ListValue, DictionaryValue, ArrayValue,
    CustomSerializer);

  TXmlTypePlan = class;

  { How one VALUE is written and read, independent of what it is called. }
  TXmlMemberPlan = class
  public
    TypeInfo: PTypeInfo;
    Kind: TXmlKind;

    { nullable }
    NullableAccess: TNullableAccess;
    Inner: TXmlMemberPlan;          { owned }

    { enumeration and set }
    EnumMapping: TArray<string>;
    SetElemTypeInfo: PTypeInfo;
    SetElemMapping: TArray<string>;

    { object and record }
    BoundPlan: TXmlTypePlan;        { BORROWED - it lives in the plan cache }

    { list, array and dictionary }
    Item: TXmlMemberPlan;           { owned }
    Key: TXmlMemberPlan;            { owned }
    Value: TXmlMemberPlan;          { owned }
    ContainerAdd: TRttiMethod;
    ContainerClear: TRttiMethod;
    ContainerToArray: TRttiMethod;
    ContainerCreate: TRttiMethod;
    PairKeyField: TRttiField;
    PairValueField: TRttiField;
    ItemName: string;
    { A dictionary's Core access, for the add that releases what a repeated
      key would otherwise orphan. }
    DictionaryAccess: TDictionaryAccess;
    HasDictionaryAccess: Boolean;

    { custom }
    Serializer: TCustomXmlValueSerializer;  { BORROWED singleton }

    { dates - resolved once, here, and never looked up again }
    DateFormat: TXmlDateTimeFormat;
    DatePattern: string;

    destructor Destroy; override;
    { True for a value that has one text form, and so can be an XML attribute
      or an element's text content. }
    function IsSimple: Boolean;
    function IsContainer: Boolean;
  end;

  { How one MEMBER of a type is named and placed. }
  TXmlFieldPlan = class
  public
    Member: TXmlMemberPlan;         { owned }
    Field: TRttiField;              { exactly one of these two is set }
    Prop: TRttiProperty;
    DelphiName: string;
    DeclaringTypeName: string;
    Name: string;                   { local element or attribute name }
    NamespaceUri: string;
    IsAttribute: Boolean;
    IsText: Boolean;
    Wrapped: Boolean;
    WrapperName: string;
    ItemName: string;
    Writable: Boolean;
    destructor Destroy; override;
  end;

  TXmlTypePlan = class
  public
    TypeInfo: PTypeInfo;
    RttiType: TRttiType;
    ClassType: TClass;
    IsRecord: Boolean;
    TypeKey: string;
    UnitName: string;
    RootName: string;
    NamespaceUri: string;
    NamespacePrefix: string;
    Fields: TObjectList<TXmlFieldPlan>;
    TextField: TXmlFieldPlan;       { BORROWED - one of Fields }
    ZeroConstructor: TRttiMethod;
    constructor Create;
    destructor Destroy; override;
  end;

  TXmlEngine = class
  strict private
    class var FCtx: TRttiContext;
    class var FLock: TCriticalSection;
    class var FPlans: TDictionary<PTypeInfo, TXmlTypePlan>;
    class var FRootPlans: TObjectDictionary<PTypeInfo, TXmlMemberPlan>;
    class var FEnumMappings: TDictionary<PTypeInfo, TArray<string>>;
    class var FTypeSerializers: TDictionary<PTypeInfo, TXmlValueSerializerClass>;
    class var FSerializerSingletons: TObjectDictionary<TClass, TCustomXmlValueSerializer>;
    class var FDatePolicies: TDateTimePolicies;
    class var FTimePolicies: TDateTimePolicies;
    class var FTimestampPolicies: TDateTimePolicies;
    class var FFrozen: Boolean;
    class var FBuildTrail: TList<PTypeInfo>;
    class var FBuildDepth: Integer;

    class procedure CheckNotFrozen; static;
    class procedure RollbackBuildTrail; static;
    class function PoliciesFor(AKind: TXmlKind): TDateTimePolicies; static;
    class function ResolveSerializer(
      AClass: TXmlValueSerializerClass): TCustomXmlValueSerializer; static;
    class function EnumMappingFor(ATypeInfo: PTypeInfo): TArray<string>; static;
    class procedure ApplyGeneralEnum(APlan: TXmlMemberPlan;
      const AValues: TArray<string>); static;

    class function ClassifyType(ATypeInfo: PTypeInfo): TXmlKind; static;
    class function GetPlan(ATypeInfo: PTypeInfo;
      const AUnitHint: string): TXmlTypePlan; static;
    class function BuildPlan(ATypeInfo: PTypeInfo;
      const AUnitHint: string): TXmlTypePlan; static;
    class procedure BuildMemberOfType(APlan: TXmlTypePlan;
      AMember: TSerializationMember); static;
    class function BuildMemberPlan(ATypeInfo: PTypeInfo;
      const AOwnerKey, AMemberName: string): TXmlMemberPlan; static;
    class function GetRootPlan(ATypeInfo: PTypeInfo): TXmlMemberPlan; static;

    class function NewInstanceOf(APlan: TXmlTypePlan): TObject; static;
    class function NewContainer(APlan: TXmlMemberPlan): TObject; static;
    class function ReadMember(AFP: TXmlFieldPlan;
      AInstance: Pointer): TValue; static;
    class procedure StoreMember(AFP: TXmlFieldPlan; AInstance: Pointer;
      const AValue: TValue); static;

    { --- value <-> text --- }
    class function SimpleToText(APlan: TXmlMemberPlan;
      const AValue: TValue): string; static;
    class function TextToSimple(APlan: TXmlMemberPlan;
      const AText: string): TValue; static;
    class function DateToText(APlan: TXmlMemberPlan;
      AValue: TDateTime): string; static;
    class function TextToDate(APlan: TXmlMemberPlan;
      const AText: string): TDateTime; static;
    class function SetToText(APlan: TXmlMemberPlan;
      const AValue: TValue): string; static;
    class function TextToSet(APlan: TXmlMemberPlan;
      const AText: string): TValue; static;
    class function EnumToText(ATypeInfo: PTypeInfo; AOrdinal: Integer;
      const AMapping: TArray<string>): string; static;
    class function TextToEnumOrdinal(ATypeInfo: PTypeInfo; const AText: string;
      const AMapping: TArray<string>): Integer; static;

    { --- value <-> element --- }
    class procedure WriteValue(APlan: TXmlMemberPlan; const AValue: TValue;
      AElement: TXmlElement; const AItemName, ANamespaceUri: string); static;
    class procedure WriteContainerItems(APlan: TXmlMemberPlan;
      const AValue: TValue; AParent: TXmlElement;
      const AItemName, ANamespaceUri: string); static;
    class procedure WriteObjectBody(APlan: TXmlTypePlan; AInstance: Pointer;
      AElement: TXmlElement); static;
    class function ReadValue(APlan: TXmlMemberPlan; AElement: TXmlElement;
      const AExisting: TValue; const AItemName,
      ANamespaceUri: string): TValue; static;
    class function ContainerItemsOf(AElement: TXmlElement;
      const AItemName, ANamespaceUri: string): TArray<TXmlElement>; static;
    class function ReadContainerItems(APlan: TXmlMemberPlan;
      const AItems: TArray<TXmlElement>; const AExisting: TValue;
      const ANamespaceUri: string): TValue; static;
    class procedure ReadObjectBody(APlan: TXmlTypePlan; AInstance: Pointer;
      AElement: TXmlElement); static;
    class function IsNilElement(AElement: TXmlElement): Boolean; static;

    class function DefaultRootNameFor(ATypeInfo: PTypeInfo): string; static;
    class function DefaultItemNameFor(ATypeInfo: PTypeInfo): string; static;
  public
    class constructor Create;
    class destructor Destroy;

    { --- the document --- }
    class function ParseDocument(const AXml: string): TXmlElement; static;
    class function WriteDocument(AElement: TXmlElement;
      AIndent, ADeclaration: Boolean): string; static;

    { --- contract-aware --- }
    class function SerializeRoot(ATypeInfo: PTypeInfo; const AValue: TValue;
      const ARootName: string; AIndent, ADeclaration: Boolean): string; static;
    class function DeserializeRoot(ATypeInfo: PTypeInfo; const AXml: string;
      const AExisting: TValue): TValue; static;
    class function SerializeRootToElement(ATypeInfo: PTypeInfo;
      const AValue: TValue; const ARootName: string): TXmlElement; static;
    class function DeserializeRootFromElement(ATypeInfo: PTypeInfo;
      AElement: TXmlElement; const AExisting: TValue): TValue; static;

    { --- cross-format, reached only through the registry --- }
    class function FromPayload(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload; AFrom: TSerializationFormat;
      const ARootName: string; AIndent, ADeclaration: Boolean): string; static;
    class function FromPayloadStructural(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat; AIndent, ADeclaration: Boolean;
      AProfile: TStructuralConversionProfile): string; static;

    { --- the dynamic tree (structural conversion only) --- }
    class function ElementToDynamic(AElement: TXmlElement): TDynamicValue; overload; static;
    class function ElementToDynamic(AElement: TXmlElement;
      const AOptions: TStructuralConversionOptions): TDynamicValue; overload; static;
    class function DynamicToElement(AValue: TDynamicValue;
      const AName: string): TXmlElement; overload; static;
    class function DynamicToElement(AValue: TDynamicValue;
      const AName: string; const AOptions: TStructuralConversionOptions;
      const APath: string): TXmlElement; overload; static;
    class function StructuralName(const AName: string;
      const AOptions: TStructuralConversionOptions;
      const APath: string): string; static;
    class procedure RefuseValue(AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions;
      const APath: string); static;

    { --- configuration --- }
    class procedure SetDateTimePolicy(ATypeInfo: PTypeInfo;
      const AFieldName: string; AKind: Integer;
      const APattern: string); static;
    class procedure RegisterEnumMapping(ATypeInfo: PTypeInfo;
      const AValues: array of string); static;
    class procedure RegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TXmlValueSerializerClass); static;
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;
    class procedure ResetConfiguration; static;
    class function PlanCount: Integer; static;
  end;

function XmlEscapeText(const AText: string): string;
function XmlEscapeAttribute(const AText: string): string;
function IsValidXmlName(const AName: string): Boolean;

{ ---------------------------------------------------------------------------
  REVERSIBLE XML NAME ENCODING

  A structural document from JSON, BSON or a map can have member names XML
  cannot spell:

      $type      @odata.context      1stValue
      first name      foo/bar        a:b       (the empty name)

  The three wrong answers are to drop the member, to rename it to something
  lossy, and to refuse ordinary real-world JSON. The right answer is to
  encode the name so that decoding it gives the original back.

  THE SCHEME.  A code unit XML will not take becomes _xHHHH_ - underscore,
  x, four uppercase hex digits, underscore. The empty name becomes _x_.

  THE ESCAPE ESCAPES ITSELF, which is the part that makes it safe. An
  underscore that is followed by an x is ALWAYS encoded, even though an
  underscore is a perfectly legal XML name character. So:

      $type          ->  _x0024_type
      _x0024_type    ->  _x005F_x0024_type

  and those two are not the same destination name, which is the whole
  point. Decoding _x005F_x0024_type gives back _x0024_type: the first group
  decodes to an underscore, and the rest is literal because nothing else in
  it is a group.

  Since decode(encode(s)) = s for every s, encode is injective, so two
  different source names can never collide on one destination name.

  XML names may contain most of Unicode, so Georgian, Cyrillic, CJK and
  non-BMP characters are legal name characters and pass through untouched.
  Only what XML genuinely refuses gets a group. }
function EncodeXmlName(const AName: string): string;
function DecodeXmlName(const AName: string): string;

implementation

{ ===========================================================================
  ESCAPING AND NAMES
  =========================================================================== }

{ True when the code unit at AIndex is half of a surrogate pair whose other
  half is not beside it. A pair is one character; a half on its own is no
  character at all. }
function IsUnpairedSurrogate(const AText: string; AIndex: Integer): Boolean;
var
  C: Char;
begin
  C := AText[AIndex];
  if (C >= #$D800) and (C <= #$DBFF) then
    Result := (AIndex = Length(AText)) or (AText[AIndex + 1] < #$DC00) or
      (AText[AIndex + 1] > #$DFFF)
  else if (C >= #$DC00) and (C <= #$DFFF) then
    Result := (AIndex = 1) or (AText[AIndex - 1] < #$D800) or
      (AText[AIndex - 1] > #$DBFF)
  else
    Result := False;
end;

{ XML 1.0 has no spelling at all for most control characters: not literally,
  and not as a numeric reference either.  A writer that emits one produces a
  document no conformant parser will read back, so this refuses out loud
  rather than producing something broken.  Tab, newline and return are the
  three that are legal, and they are handled above.  An unpaired surrogate is
  refused the same way: the Char production excludes it, so it was written
  raw into a document MSXML would not load. }
procedure CheckXmlCharacters(const AText: string);
var
  I: Integer;
  C: Char;
begin
  for I := 1 to Length(AText) do
  begin
    C := AText[I];
    if (C < #32) and (C <> #9) and (C <> #10) and (C <> #13) then
      raise EXmlError.CreateFmt(
        'Character U+%.4X at position %d cannot appear in an XML document. ' +
        'XML 1.0 has no representation for it, literal or escaped. The value ' +
        'has to be encoded - base64, say - before it can be written as XML.',
        [Ord(C), I]);
    if (C >= #$D800) and (C <= #$DFFF) and IsUnpairedSurrogate(AText, I) then
      raise EXmlError.CreateFmt(
        'Character U+%.4X at position %d is an unpaired UTF-16 surrogate - ' +
        'half of a character - and cannot appear in an XML document. XML 1.0 ' +
        'has no representation for it, literal or escaped. Remove it, or ' +
        'encode the value - base64, say - before it is written as XML.',
        [Ord(C), I]);
  end;
end;

function XmlEscapeText(const AText: string): string;
var
  SB: TStringBuilder;
  C: Char;
begin
  if AText = '' then Exit('');
  CheckXmlCharacters(AText);
  SB := TStringBuilder.Create(Length(AText) + 16);
  try
    for C in AText do
      case C of
        '&': SB.Append('&amp;');
        '<': SB.Append('&lt;');
        '>': SB.Append('&gt;');
        #13: SB.Append('&#13;');
      else
        SB.Append(C);
      end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function XmlEscapeAttribute(const AText: string): string;
var
  SB: TStringBuilder;
  C: Char;
begin
  if AText = '' then Exit('');
  CheckXmlCharacters(AText);
  SB := TStringBuilder.Create(Length(AText) + 16);
  try
    for C in AText do
      case C of
        '&': SB.Append('&amp;');
        '<': SB.Append('&lt;');
        '>': SB.Append('&gt;');
        '"': SB.Append('&quot;');
        #9:  SB.Append('&#9;');
        #10: SB.Append('&#10;');
        #13: SB.Append('&#13;');
      else
        SB.Append(C);
      end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function IsNameStartChar(C: Char): Boolean;
begin
  Result := CharInSet(C, ['A'..'Z', 'a'..'z', '_']) or (Ord(C) > 127);
end;

function IsNameChar(C: Char): Boolean;
begin
  Result := IsNameStartChar(C) or CharInSet(C, ['0'..'9', '-', '.']);
end;

function IsValidXmlName(const AName: string): Boolean;
var
  I: Integer;
begin
  if AName = '' then Exit(False);
  if not IsNameStartChar(AName[1]) then Exit(False);
  for I := 2 to Length(AName) do
    if not IsNameChar(AName[I]) then Exit(False);
  { Everything above U+007F passes the test above, and half a surrogate pair
    is not a character at all. }
  for I := 1 to Length(AName) do
    if IsUnpairedSurrogate(AName, I) then Exit(False);
  Result := True;
end;

{ --------------------------------------------------- reversible encoding --- }

const
  XML_NAME_EMPTY = '_x_';

function EncodeXmlName(const AName: string): string;
var
  I, L: Integer;
  SB: TStringBuilder;
  Keep: Boolean;
begin
  if AName = '' then Exit(XML_NAME_EMPTY);

  L := Length(AName);
  SB := TStringBuilder.Create(L + 16);
  try
    for I := 1 to L do
    begin
      { An underscore before an x is encoded even though XML would accept
        it, because leaving it alone is what would let a source name that
        already looks encoded collide with one that had to be. }
      if (AName[I] = '_') and (I < L) and (AName[I + 1] = 'x') then
        Keep := False
      else if I = 1 then
        Keep := IsNameStartChar(AName[I])
      else
        Keep := IsNameChar(AName[I]);
      { Half a surrogate pair is a code unit XML will not take, like any
        other: it gets a group, and decodes back to itself. }
      if Keep and IsUnpairedSurrogate(AName, I) then Keep := False;

      if Keep then SB.Append(AName[I])
      else SB.Append('_x').Append(IntToHex(Ord(AName[I]), 4)).Append('_');
    end;
    { A name beginning with "xml" is reserved by the specification and is
      deliberately NOT encoded here. The reservation is for future standard
      names, every parser in existence accepts <XmlMessage>, and encoding an
      ordinary member called XmlMessage into _x0058_mlMessage would make the
      output unreadable to buy nothing. }
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ Exactly four hex digits and nothing else - StrToInt would accept padding
  and a sign, and the collision-safety argument depends on the group form
  being recognised exactly as the encoder writes it. }
function TryHex4(const AText: string; out AValue: Integer): Boolean;
var
  I, D: Integer;
begin
  AValue := 0;
  if Length(AText) <> 4 then Exit(False);
  for I := 1 to 4 do
  begin
    case AText[I] of
      '0'..'9': D := Ord(AText[I]) - Ord('0');
      'A'..'F': D := Ord(AText[I]) - Ord('A') + 10;
      'a'..'f': D := Ord(AText[I]) - Ord('a') + 10;
    else
      Exit(False);
    end;
    AValue := (AValue shl 4) or D;
  end;
  Result := True;
end;

function DecodeXmlName(const AName: string): string;
var
  I, L, Code: Integer;
  SB: TStringBuilder;
begin
  if AName = XML_NAME_EMPTY then Exit('');
  if Pos('_x', AName) = 0 then Exit(AName);

  L := Length(AName);
  SB := TStringBuilder.Create(L);
  try
    I := 1;
    while I <= L do
    begin
      if (AName[I] = '_') and (I + 6 <= L) and (AName[I + 1] = 'x') and
         (AName[I + 6] = '_') and
         TryHex4(Copy(AName, I + 2, 4), Code) then
      begin
        SB.Append(Char(Code));
        Inc(I, 7);
      end
      else
      begin
        SB.Append(AName[I]);
        Inc(I);
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ ===========================================================================
  1. THE READER

  Small, strict, non-validating. It handles what a serialization format needs
  and refuses the rest out loud:

    elements, attributes, text, CDATA            - handled
    comments, processing instructions            - skipped
    the five predefined entities, &#n;, &#xn;    - handled
    namespace declarations, default and prefixed - handled
    DOCTYPE, internal subset, general entities   - handled
    EXTERNAL entities and parameter entities     - REFUSED, by name

  The profile is XML 1.0 Fifth Edition, non-validating, with external entity
  resolution disabled - and "disabled" here means there is no code in this
  unit that can open a file or a socket, not that a switch is set. See
  ReadDoctype below for exactly what is read and what is refused.
  =========================================================================== }

type
  TNamespaceScope = class
  public
    Prefixes: TDictionary<string, string>;
    constructor Create(AParent: TNamespaceScope);
    destructor Destroy; override;
  end;

constructor TNamespaceScope.Create(AParent: TNamespaceScope);
var
  P: TPair<string, string>;
begin
  inherited Create;
  Prefixes := TDictionary<string, string>.Create;
  if AParent <> nil then
    for P in AParent.Prefixes do Prefixes.Add(P.Key, P.Value);
end;

destructor TNamespaceScope.Destroy;
begin
  Prefixes.Free;
  inherited Destroy;
end;

type
  TXmlReader = record
  public
    FText: string;
    FPos: Integer;
    FLen: Integer;
    { Declared internal general entities, and the budget that stops a
      "billion laughs" document from expanding until memory runs out. }
    FEntities: TDictionary<string, string>;
    FExpanded: Integer;
    procedure Fail(const AMessage: string);
    procedure SkipWhitespace;
    function AtEnd: Boolean;
    function Peek: Char;
    function StartsWith(const AText: string): Boolean;
    procedure Expect(const AText: string);
    function ReadName: string;
    function ReadQuoted: string;
    function DecodeEntities(const AText: string): string; overload;
    function DecodeEntities(const AText: string; ADepth: Integer;
      AInAttribute: Boolean): string; overload;
    procedure SkipMisc;
    procedure ReadDoctype;
    procedure ReadInternalSubset;
    procedure ReadEntityDeclaration;
    procedure SkipDeclaration;
    procedure SkipExternalId;
    function ReadEntityLiteral: string;
    function TryIncludeEntity: Boolean;
    procedure ChargeExpansion(AChars: Integer);
    procedure ValidateEntities;
    function ExpandedLength(const AName: string;
      AInProgress: TStringList): Int64;
    function ReadElement(AScope: TNamespaceScope; ADepth: Integer): TXmlElement;
    class function Parse(const AXml: string): TXmlElement; static;
  end;

const
  { An entity may not expand past this many characters in one document.
    Generous for anything real; a small fraction of what a nested-entity
    bomb needs. }
  XML_ENTITY_EXPANSION_BUDGET = 8 * 1024 * 1024;
  { And an entity may not nest deeper than this. }
  XML_ENTITY_DEPTH_LIMIT = 32;
  { Elements may not nest deeper than this. The reader is recursive, so
    without a limit a document of nothing but open tags is a stack overflow -
    which is a crash rather than an error, and a crash is not a diagnosis.
    Deeper than this is not a document anyone wrote by hand. }
  XML_ELEMENT_DEPTH_LIMIT = 512;

procedure TXmlReader.Fail(const AMessage: string);
var
  Line, Col, I: Integer;
begin
  Line := 1;
  Col := 1;
  for I := 1 to Min(FPos, FLen) do
    if FText[I] = #10 then
    begin
      Inc(Line);
      Col := 1;
    end
    else
      Inc(Col);
  raise EXmlInputError.CreateFmt('%s (line %d, column %d)',
    [AMessage, Line, Col]);
end;

function TXmlReader.AtEnd: Boolean;
begin
  Result := FPos > FLen;
end;

function TXmlReader.Peek: Char;
begin
  if FPos > FLen then Exit(#0);
  Result := FText[FPos];
end;

function TXmlReader.StartsWith(const AText: string): Boolean;
begin
  Result := (FPos + Length(AText) - 1 <= FLen) and
    (CompareStr(Copy(FText, FPos, Length(AText)), AText) = 0);
end;

procedure TXmlReader.Expect(const AText: string);
begin
  if not StartsWith(AText) then Fail('Expected "' + AText + '"');
  Inc(FPos, Length(AText));
end;

procedure TXmlReader.SkipWhitespace;
begin
  while (FPos <= FLen) and CharInSet(FText[FPos], [#9, #10, #13, ' ']) do
    Inc(FPos);
end;

function TXmlReader.ReadName: string;
var
  Start: Integer;
begin
  Start := FPos;
  if (FPos > FLen) or not IsNameStartChar(FText[FPos]) then
    Fail('Expected a name');
  Inc(FPos);
  while (FPos <= FLen) and (IsNameChar(FText[FPos]) or (FText[FPos] = ':')) do
    Inc(FPos);
  Result := Copy(FText, Start, FPos - Start);
end;

function TXmlReader.ReadQuoted: string;
var
  Quote: Char;
  Start: Integer;
begin
  if (FPos > FLen) or not CharInSet(FText[FPos], ['"', '''']) then
    Fail('Expected a quoted attribute value');
  Quote := FText[FPos];
  Inc(FPos);
  Start := FPos;
  while (FPos <= FLen) and (FText[FPos] <> Quote) do Inc(FPos);
  if FPos > FLen then Fail('Unterminated attribute value');
  Result := DecodeEntities(Copy(FText, Start, FPos - Start));
  Inc(FPos);
end;

function TXmlReader.DecodeEntities(const AText: string): string;
begin
  Result := DecodeEntities(AText, 0, False);
end;

function TXmlReader.DecodeEntities(const AText: string; ADepth: Integer;
  AInAttribute: Boolean): string;
var
  SB: TStringBuilder;
  I, Semi, Code: Integer;
  Ent, Replacement: string;
begin
  if Pos('&', AText) = 0 then Exit(AText);
  if ADepth > XML_ENTITY_DEPTH_LIMIT then
    Fail(Format('Entity references nested more than %d deep. This is either ' +
      'a recursive entity, which is forbidden, or a document designed to ' +
      'exhaust memory.', [XML_ENTITY_DEPTH_LIMIT]));

  SB := TStringBuilder.Create(Length(AText));
  try
    I := 1;
    while I <= Length(AText) do
    begin
      if AText[I] <> '&' then
      begin
        SB.Append(AText[I]);
        Inc(I);
        Continue;
      end;
      Semi := I + 1;
      while (Semi <= Length(AText)) and (AText[Semi] <> ';') and
            (Semi - I <= 64) do Inc(Semi);
      if (Semi > Length(AText)) or (AText[Semi] <> ';') then
        Fail('Unterminated entity reference');
      Ent := Copy(AText, I + 1, Semi - I - 1);
      if Ent = 'lt' then SB.Append('<')
      else if Ent = 'gt' then SB.Append('>')
      else if Ent = 'amp' then SB.Append('&')
      else if Ent = 'quot' then SB.Append('"')
      else if Ent = 'apos' then SB.Append('''')
      else if (Ent <> '') and (Ent[1] = '#') then
      begin
        if (Length(Ent) > 2) and CharInSet(Ent[2], ['x', 'X']) then
          Code := StrToIntDef('$' + Copy(Ent, 3, MaxInt), -1)
        else
          Code := StrToIntDef(Copy(Ent, 2, MaxInt), -1);
        if (Code < 0) or (Code > $10FFFF) then
          Fail('Invalid character reference "&' + Ent + ';"');
        if Code > $FFFF then
        begin
          Dec(Code, $10000);
          SB.Append(Char($D800 or (Code shr 10)));
          SB.Append(Char($DC00 or (Code and $3FF)));
        end
        else
          SB.Append(Char(Code));
      end
      else if (FEntities <> nil) and FEntities.TryGetValue(Ent, Replacement) then
      begin
        { A general entity declared in the internal subset. Its replacement
          text is included here and processed in turn, so an entity that
          refers to another entity works. }
        ChargeExpansion(Length(Replacement));
        Replacement := DecodeEntities(Replacement, ADepth + 1, AInAttribute);
        if AInAttribute and (Pos('<', Replacement) > 0) then
          Fail(Format('Entity "&%s;" expands to markup and is referenced in ' +
            'an attribute value, which XML forbids.', [Ent]));
        SB.Append(Replacement);
      end
      else
        Fail('Unknown entity "&' + Ent + ';". Only the five predefined ' +
             'entities, character references, and general entities declared ' +
             'in this document''s internal subset are resolved - an external ' +
             'DTD subset is deliberately not read.');
      I := Semi + 1;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TXmlReader.ChargeExpansion(AChars: Integer);
begin
  Inc(FExpanded, AChars);
  if FExpanded > XML_ENTITY_EXPANSION_BUDGET then
    Fail(Format('Entity expansion passed %d characters. A document that ' +
      'needs more than that is expanding entities into entities, which is ' +
      'how a small file turns into gigabytes.',
      [XML_ENTITY_EXPANSION_BUDGET]));
end;

procedure TXmlReader.SkipMisc;
var
  Stop: Integer;
begin
  while True do
  begin
    SkipWhitespace;
    if StartsWith('<!--') then
    begin
      Stop := Pos('-->', FText, FPos + 4);
      if Stop = 0 then Fail('Unterminated comment');
      FPos := Stop + 3;
    end
    else if StartsWith('<?') then
    begin
      Stop := Pos('?>', FText, FPos + 2);
      if Stop = 0 then Fail('Unterminated processing instruction');
      FPos := Stop + 2;
    end
    else if StartsWith('<!DOCTYPE') then
      ReadDoctype
    else
      Break;
  end;
end;

{ ---------------------------------------------------------------- DOCTYPE ---

  The profile, stated once: XML 1.0 Fifth Edition, NON-VALIDATING, with
  EXTERNAL ENTITY RESOLUTION DISABLED.

  A document type declaration is parsed rather than refused, because real
  documents carry one and refusing them is not "reading XML". What is read:

    the root element name                    parsed, not checked
    an external identifier (SYSTEM/PUBLIC)   parsed and NOT FETCHED
    <!ENTITY name "text">                    declared and usable
    <!ELEMENT>, <!ATTLIST>, <!NOTATION>      parsed and ignored
    comments and processing instructions     skipped

  What is refused, by name, with the reason:

    <!ENTITY name SYSTEM "...">              an external entity. This is XXE.
    <!ENTITY % name "...">                   a parameter entity
    %name;                                   a parameter-entity reference

  Nothing this parser does can open a file or a socket. That is not a
  configuration setting here; there is no code that could.

  Parameter entities are a DTD-construction feature and a non-validating
  processor is permitted not to process them; since they are not processed
  they are refused rather than silently ignored, so a document that depends
  on one fails loudly instead of quietly losing content.
  --------------------------------------------------------------------------- }

procedure TXmlReader.ReadDoctype;
begin
  Expect('<!DOCTYPE');
  SkipWhitespace;
  ReadName;
  SkipWhitespace;
  if StartsWith('SYSTEM') or StartsWith('PUBLIC') then SkipExternalId;
  SkipWhitespace;
  if Peek = '[' then ReadInternalSubset;
  SkipWhitespace;
  Expect('>');
  ValidateEntities;
end;

{ THE BILLION LAUGHS, STOPPED BEFORE IT STARTS.

  Ten entities, each ten copies of the one before, is a few hundred bytes of
  DTD that expands to gigabytes. Catching that while expanding is too late:
  by then the parser is already doing the work, and a running budget only
  decides how much of it gets done.

  So the fully expanded length of every declared entity is computed HERE,
  from the declarations alone, before a single character of content is read.
  It is arithmetic over the DTD - instant - and it also finds an entity that
  refers to itself, which would otherwise expand forever. }
procedure TXmlReader.ValidateEntities;
var
  Name: string;
  InProgress: TStringList;
begin
  if FEntities.Count = 0 then Exit;
  InProgress := TStringList.Create;
  try
    for Name in FEntities.Keys do ExpandedLength(Name, InProgress);
  finally
    InProgress.Free;
  end;
end;

function TXmlReader.ExpandedLength(const AName: string;
  AInProgress: TStringList): Int64;
var
  Value, Ref: string;
  I, Semi: Integer;
begin
  if AInProgress.IndexOf(AName) >= 0 then
    Fail(Format('Entity "%s" refers to itself, directly or through another ' +
      'entity. A recursive entity has no expansion and XML forbids one.',
      [AName]));
  if not FEntities.TryGetValue(AName, Value) then Exit(Length(AName) + 2);

  AInProgress.Add(AName);
  try
    Result := 0;
    I := 1;
    while I <= Length(Value) do
    begin
      if Value[I] <> '&' then
      begin
        Inc(Result);
        Inc(I);
        Continue;
      end;
      Semi := I + 1;
      while (Semi <= Length(Value)) and (Value[Semi] <> ';') and
            (Semi - I <= 64) do Inc(Semi);
      if (Semi > Length(Value)) or (Value[Semi] <> ';') then
      begin
        Inc(Result);
        Inc(I);
        Continue;
      end;
      Ref := Copy(Value, I + 1, Semi - I - 1);
      { A character reference or a predefined entity is one character; a
        general entity is however long it expands to. }
      if FEntities.ContainsKey(Ref) then
        Inc(Result, ExpandedLength(Ref, AInProgress))
      else
        Inc(Result);
      if Result > XML_ENTITY_EXPANSION_BUDGET then
        Fail(Format('Entity "%s" expands to more than %d characters. A few ' +
          'hundred bytes of declarations that expand to gigabytes is an ' +
          'attack, not a document.', [AName, XML_ENTITY_EXPANSION_BUDGET]));
      I := Semi + 1;
    end;
  finally
    AInProgress.Delete(AInProgress.IndexOf(AName));
  end;
end;

{ The external subset is named and then left alone: not opened, not fetched,
  not resolved. An entity that only the external subset declares is therefore
  undeclared here, and referencing it is an error with a message that says
  so - which is the honest outcome, and better than silently dropping it. }
procedure TXmlReader.SkipExternalId;
begin
  if StartsWith('PUBLIC') then
  begin
    Inc(FPos, 6);
    SkipWhitespace;
    ReadEntityLiteral;
    SkipWhitespace;
    ReadEntityLiteral;
  end
  else
  begin
    Inc(FPos, 6);
    SkipWhitespace;
    ReadEntityLiteral;
  end;
end;

procedure TXmlReader.ReadInternalSubset;
var
  Stop: Integer;
begin
  Expect('[');
  while True do
  begin
    SkipWhitespace;
    if AtEnd then Fail('Unterminated internal DTD subset');
    if Peek = ']' then
    begin
      Inc(FPos);
      Exit;
    end;
    if StartsWith('<!--') then
    begin
      Stop := Pos('-->', FText, FPos + 4);
      if Stop = 0 then Fail('Unterminated comment');
      FPos := Stop + 3;
      Continue;
    end;
    if StartsWith('<?') then
    begin
      Stop := Pos('?>', FText, FPos + 2);
      if Stop = 0 then Fail('Unterminated processing instruction');
      FPos := Stop + 2;
      Continue;
    end;
    if StartsWith('<!ENTITY') then
    begin
      ReadEntityDeclaration;
      Continue;
    end;
    if StartsWith('<!ELEMENT') or StartsWith('<!ATTLIST') or
       StartsWith('<!NOTATION') then
    begin
      SkipDeclaration;
      Continue;
    end;
    if Peek = '%' then
      Fail('A parameter-entity reference. This parser is non-validating and ' +
           'does not process parameter entities, so it refuses one rather ' +
           'than silently losing whatever it would have declared.');
    Fail('Unexpected content in the internal DTD subset');
  end;
end;

{ <!ELEMENT>, <!ATTLIST> and <!NOTATION> say nothing a serializer needs, so
  they are parsed far enough to find their end and then dropped. Quoted
  sections are respected so a '>' inside a default value does not end the
  declaration early. }
procedure TXmlReader.SkipDeclaration;
var
  Quote: Char;
begin
  Inc(FPos, 2);
  while FPos <= FLen do
  begin
    if CharInSet(FText[FPos], ['"', '''']) then
    begin
      Quote := FText[FPos];
      Inc(FPos);
      while (FPos <= FLen) and (FText[FPos] <> Quote) do Inc(FPos);
      if FPos > FLen then Fail('Unterminated literal in a DTD declaration');
      Inc(FPos);
      Continue;
    end;
    if FText[FPos] = '>' then
    begin
      Inc(FPos);
      Exit;
    end;
    Inc(FPos);
  end;
  Fail('Unterminated DTD declaration');
end;

procedure TXmlReader.ReadEntityDeclaration;
var
  Name, Value: string;
begin
  Expect('<!ENTITY');
  SkipWhitespace;
  if Peek = '%' then
    Fail('A parameter-entity declaration. This parser is non-validating and ' +
         'does not process parameter entities.');
  Name := ReadName;
  SkipWhitespace;
  if StartsWith('SYSTEM') or StartsWith('PUBLIC') then
    Fail(Format('Entity "%s" is an EXTERNAL entity. Resolving one would mean ' +
      'opening whatever the document names - a file, a URL, a network ' +
      'service - on its say-so, which is the XXE attack in full. This parser ' +
      'has no code that could, and says so rather than pretending the entity ' +
      'was empty.', [Name]));
  Value := ReadEntityLiteral;
  SkipWhitespace;
  Expect('>');
  { First declaration wins, which is what the specification says. }
  if not FEntities.ContainsKey(Name) then
  begin
    ChargeExpansion(Length(Value));
    FEntities.Add(Name, Value);
  end;
end;

{ A quoted literal from the DTD.

  Character references inside an entity value are expanded when the value is
  DECLARED, not when it is used - so that "&#60;" becomes a less-than sign
  that is text rather than the start of a tag. This keeps them as references
  instead, precisely so that re-lexing the included text treats them as text.
  General entity references are left alone here and resolved at the point of
  reference, which is also what the specification says. }
function TXmlReader.ReadEntityLiteral: string;
var
  Quote: Char;
  Start: Integer;
begin
  if (FPos > FLen) or not CharInSet(FText[FPos], ['"', '''']) then
    Fail('Expected a quoted literal');
  Quote := FText[FPos];
  Inc(FPos);
  Start := FPos;
  while (FPos <= FLen) and (FText[FPos] <> Quote) do Inc(FPos);
  if FPos > FLen then Fail('Unterminated literal');
  Result := Copy(FText, Start, FPos - Start);
  Inc(FPos);
end;

{ In content, a reference to a declared general entity is INCLUDED: its
  replacement text is spliced into the input and lexed in place, so an entity
  that expands to elements produces elements and not text that looks like
  them. Returns False for anything else - a character reference or one of the
  five predefined entities - which the caller decodes as text. }
function TXmlReader.TryIncludeEntity: Boolean;
var
  Semi: Integer;
  Name, Replacement: string;
begin
  Result := False;
  if (FEntities = nil) or (FEntities.Count = 0) then Exit;
  Semi := FPos + 1;
  while (Semi <= FLen) and (FText[Semi] <> ';') and (Semi - FPos <= 64) do
    Inc(Semi);
  if (Semi > FLen) or (FText[Semi] <> ';') then Exit;
  Name := Copy(FText, FPos + 1, Semi - FPos - 1);
  if not FEntities.TryGetValue(Name, Replacement) then Exit;

  ChargeExpansion(Length(Replacement));
  FText := Copy(FText, 1, FPos - 1) + Replacement +
           Copy(FText, Semi + 1, MaxInt);
  FLen := Length(FText);
  Result := True;
end;

function TXmlReader.ReadElement(AScope: TNamespaceScope;
  ADepth: Integer): TXmlElement;
var
  Scope: TNamespaceScope;
  RawName, Prefix, Local, AttrRaw, AttrLocal, AttrValue, Uri: string;
  Start, Stop, Colon: Integer;
  SelfClosing: Boolean;
  Attrs: TList<TPair<string, string>>;
  P: TPair<string, string>;
  TextBuf: TStringBuilder;
  Chunk: string;
begin
  if ADepth > XML_ELEMENT_DEPTH_LIMIT then
    Fail(Format('Elements nested more than %d deep. The reader is recursive, ' +
      'so this is refused with a message rather than allowed to exhaust the ' +
      'stack - a crash tells nobody anything.', [XML_ELEMENT_DEPTH_LIMIT]));
  Expect('<');
  RawName := ReadName;
  Scope := TNamespaceScope.Create(AScope);
  Attrs := TList<TPair<string, string>>.Create;
  Result := nil;
  TextBuf := nil;
  try
    { Attributes first: a namespace declared on this element applies to the
      element's own name too. }
    SelfClosing := False;
    while True do
    begin
      SkipWhitespace;
      if StartsWith('/>') then
      begin
        Inc(FPos, 2);
        SelfClosing := True;
        Break;
      end;
      if StartsWith('>') then
      begin
        Inc(FPos);
        Break;
      end;
      if AtEnd then Fail('Unterminated start tag');
      AttrRaw := ReadName;
      SkipWhitespace;
      Expect('=');
      SkipWhitespace;
      AttrValue := ReadQuoted;
      if AttrRaw = 'xmlns' then
        Scope.Prefixes.AddOrSetValue('', AttrValue)
      else if AttrRaw.StartsWith('xmlns:') then
        Scope.Prefixes.AddOrSetValue(AttrRaw.Substring(6), AttrValue)
      else
        Attrs.Add(TPair<string, string>.Create(AttrRaw, AttrValue));
    end;

    Colon := Pos(':', RawName);
    if Colon > 0 then
    begin
      Prefix := Copy(RawName, 1, Colon - 1);
      Local := Copy(RawName, Colon + 1, MaxInt);
      if not Scope.Prefixes.TryGetValue(Prefix, Uri) then
        Fail('Undeclared namespace prefix "' + Prefix + '"');
    end
    else
    begin
      Prefix := '';
      Local := RawName;
      if not Scope.Prefixes.TryGetValue('', Uri) then Uri := '';
    end;

    Result := TXmlElement.Create(Local, Uri);
    Result.Prefix := Prefix;

    for P in Attrs do
    begin
      Colon := Pos(':', P.Key);
      if Colon > 0 then
      begin
        AttrLocal := Copy(P.Key, Colon + 1, MaxInt);
        if not Scope.Prefixes.TryGetValue(Copy(P.Key, 1, Colon - 1), Uri) then
          Fail('Undeclared namespace prefix "' + Copy(P.Key, 1, Colon - 1) + '"');
      end
      else
      begin
        { An unprefixed attribute is in NO namespace, default declaration or
          not. That is the XML rule, and getting it wrong makes xsi:nil
          behave differently under a default namespace. }
        AttrLocal := P.Key;
        Uri := '';
      end;
      Result.SetAttribute(AttrLocal, P.Value, Uri);
    end;

    if not SelfClosing then
    begin
      TextBuf := TStringBuilder.Create;
      while True do
      begin
        if AtEnd then Fail('Unterminated element <' + RawName + '>');
        if StartsWith('</') then
        begin
          Inc(FPos, 2);
          if ReadName <> RawName then
            Fail('Mismatched closing tag for <' + RawName + '>');
          SkipWhitespace;
          Expect('>');
          Break;
        end;
        if StartsWith('<![CDATA[') then
        begin
          Inc(FPos, 9);
          Stop := Pos(']]>', FText, FPos);
          if Stop = 0 then Fail('Unterminated CDATA section');
          TextBuf.Append(Copy(FText, FPos, Stop - FPos));
          Result.HasText := True;
          FPos := Stop + 3;
          Continue;
        end;
        if StartsWith('<!--') then
        begin
          Stop := Pos('-->', FText, FPos + 4);
          if Stop = 0 then Fail('Unterminated comment');
          FPos := Stop + 3;
          Continue;
        end;
        if StartsWith('<?') then
        begin
          Stop := Pos('?>', FText, FPos + 2);
          if Stop = 0 then Fail('Unterminated processing instruction');
          FPos := Stop + 2;
          Continue;
        end;
        if Peek = '<' then
        begin
          Result.AdoptChild(ReadElement(Scope, ADepth + 1));
          Continue;
        end;
        if Peek = '&' then
        begin
          { A declared general entity is spliced into the input and lexed
            again from here, so one that expands to elements produces
            elements. Anything else - a character reference, one of the five
            predefined entities - is text, and is decoded as text. }
          if TryIncludeEntity then Continue;
          Start := FPos;
          Inc(FPos);
          while (FPos <= FLen) and (FText[FPos] <> ';') and
                (FPos - Start <= 64) do Inc(FPos);
          if (FPos > FLen) or (FText[FPos] <> ';') then
            Fail('Unterminated entity reference');
          Inc(FPos);
          TextBuf.Append(DecodeEntities(Copy(FText, Start, FPos - Start)));
          Result.HasText := True;
          Continue;
        end;
        Start := FPos;
        while (FPos <= FLen) and (FText[FPos] <> '<') and
              (FText[FPos] <> '&') do Inc(FPos);
        Chunk := Copy(FText, Start, FPos - Start);
        { EVERY chunk is kept, including one that is only spaces: the space
          between "&gt;" and "&amp;" is content, and dropping it here would
          quietly rewrite the document. What HasText records is whether any
          chunk held something other than whitespace; the decision about
          indentation whitespace is made once, at the end of the element,
          where the child count is known. }
        TextBuf.Append(Chunk);
        if Trim(Chunk) <> '' then Result.HasText := True;
      end;
      if Result.ChildCount = 0 then
      begin
        Result.Text := TextBuf.ToString;
        Result.HasText := True;
      end
      else if Result.HasText then
        Result.Text := Trim(TextBuf.ToString);
    end;
  except
    Result.Free;
    Scope.Free;
    Attrs.Free;
    TextBuf.Free;
    raise;
  end;
  TextBuf.Free;
  Attrs.Free;
  Scope.Free;
end;

class function TXmlReader.Parse(const AXml: string): TXmlElement;
var
  R: TXmlReader;
begin
  R.FText := AXml;
  R.FLen := Length(AXml);
  R.FPos := 1;
  R.FExpanded := 0;
  { A UTF-8 BOM that survived the byte-to-string conversion. }
  if (R.FLen > 0) and (AXml[1] = #$FEFF) then R.FPos := 2;
  R.FEntities := TDictionary<string, string>.Create;
  try
    R.SkipMisc;
    if R.AtEnd then raise EXmlInputError.Create('The document is empty.');
    Result := R.ReadElement(nil, 0);
    try
      R.SkipMisc;
      if not R.AtEnd then
        R.Fail('Content after the root element; an XML document has exactly one root');
    except
      Result.Free;
      raise;
    end;
  finally
    R.FEntities.Free;
  end;
end;

{ ===========================================================================
  2. THE WRITER

  Namespaces are declared once, on the root, and the prefixes chosen there
  are used throughout. A prefix is a spelling: the document means the same
  thing whichever one it gets, and one declaration site reads better than one
  per element.
  =========================================================================== }

type
  TXmlPrefixMap = class
  strict private
    FByUri: TDictionary<string, string>;
    FUsed: TDictionary<string, Byte>;
    FDefaultUri: string;
    FHasDefault: Boolean;
    function NewPrefix: string;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Collect(AElement: TXmlElement; ARoot: Boolean);
    function PrefixFor(const AUri: string): string;
    property DefaultUri: string read FDefaultUri;
    property HasDefault: Boolean read FHasDefault;
    property ByUri: TDictionary<string, string> read FByUri;
  end;

constructor TXmlPrefixMap.Create;
begin
  inherited Create;
  FByUri := TDictionary<string, string>.Create;
  FUsed := TDictionary<string, Byte>.Create;
end;

destructor TXmlPrefixMap.Destroy;
begin
  FUsed.Free;
  FByUri.Free;
  inherited Destroy;
end;

function TXmlPrefixMap.NewPrefix: string;
var
  N: Integer;
begin
  N := Integer(FByUri.Count + 1);
  repeat
    Result := 'ns' + IntToStr(N);
    Inc(N);
  until not FUsed.ContainsKey(Result);
end;

procedure TXmlPrefixMap.Collect(AElement: TXmlElement; ARoot: Boolean);
var
  I: Integer;
  Prefix: string;
begin
  if ARoot and (AElement.NamespaceUri <> '') and (AElement.Prefix = '') then
  begin
    { The root's own namespace becomes the default, so the common case - one
      namespace, no prefixes - comes out looking like ordinary XML. }
    FDefaultUri := AElement.NamespaceUri;
    FHasDefault := True;
  end;
  if (AElement.NamespaceUri <> '') and
     not (FHasDefault and (AElement.NamespaceUri = FDefaultUri)) and
     not FByUri.ContainsKey(AElement.NamespaceUri) then
  begin
    Prefix := AElement.Prefix;
    if (Prefix = '') or FUsed.ContainsKey(Prefix) then Prefix := NewPrefix;
    FByUri.Add(AElement.NamespaceUri, Prefix);
    FUsed.AddOrSetValue(Prefix, 0);
  end;
  for I := 0 to AElement.AttributeCount - 1 do
    if (AElement.Attributes[I].NamespaceUri <> '') and
       not FByUri.ContainsKey(AElement.Attributes[I].NamespaceUri) then
    begin
      if AElement.Attributes[I].NamespaceUri = XSI_NAMESPACE then
        Prefix := 'xsi'
      else
        Prefix := NewPrefix;
      if FUsed.ContainsKey(Prefix) then Prefix := NewPrefix;
      FByUri.Add(AElement.Attributes[I].NamespaceUri, Prefix);
      FUsed.AddOrSetValue(Prefix, 0);
    end;
  for I := 0 to AElement.ChildCount - 1 do Collect(AElement.Children[I], False);
end;

function TXmlPrefixMap.PrefixFor(const AUri: string): string;
begin
  if AUri = '' then Exit('');
  if FHasDefault and (AUri = FDefaultUri) then Exit('');
  if not FByUri.TryGetValue(AUri, Result) then Result := '';
end;

procedure WriteElementTo(ASB: TStringBuilder; AElement: TXmlElement;
  AMap: TXmlPrefixMap; AIndent: Boolean; ALevel: Integer; ARoot: Boolean);
var
  I: Integer;
  Prefix, Tag, Pad: string;
  P: TPair<string, string>;
  HasChildren: Boolean;
begin
  Pad := '';
  if AIndent then Pad := StringOfChar(' ', ALevel * 2);
  Prefix := AMap.PrefixFor(AElement.NamespaceUri);
  if Prefix <> '' then Tag := Prefix + ':' + AElement.Name
  else Tag := AElement.Name;

  if AIndent and (ALevel > 0) then ASB.Append(sLineBreak);
  ASB.Append(Pad).Append('<').Append(Tag);

  if ARoot then
  begin
    if AMap.HasDefault then
      ASB.Append(' xmlns="').Append(XmlEscapeAttribute(AMap.DefaultUri))
         .Append('"');
    for P in AMap.ByUri do
      ASB.Append(' xmlns:').Append(P.Value).Append('="')
         .Append(XmlEscapeAttribute(P.Key)).Append('"');
  end
  else if AMap.HasDefault and (AElement.NamespaceUri = '') then
    { Under a default namespace an unprefixed element would inherit it, so an
      element genuinely in no namespace has to say so. }
    ASB.Append(' xmlns=""');

  for I := 0 to AElement.AttributeCount - 1 do
  begin
    Prefix := AMap.PrefixFor(AElement.Attributes[I].NamespaceUri);
    ASB.Append(' ');
    if Prefix <> '' then ASB.Append(Prefix).Append(':');
    ASB.Append(AElement.Attributes[I].Name).Append('="')
       .Append(XmlEscapeAttribute(AElement.Attributes[I].Value)).Append('"');
  end;

  HasChildren := AElement.ChildCount > 0;
  if not HasChildren and (not AElement.HasText or (AElement.Text = '')) then
  begin
    ASB.Append('/>');
    Exit;
  end;

  ASB.Append('>');
  if AElement.HasText and (AElement.Text <> '') then
    ASB.Append(XmlEscapeText(AElement.Text));
  for I := 0 to AElement.ChildCount - 1 do
    WriteElementTo(ASB, AElement.Children[I], AMap, AIndent, ALevel + 1, False);
  if AIndent and HasChildren then ASB.Append(sLineBreak).Append(Pad);
  ASB.Append('</').Append(Tag).Append('>');
end;

{ ===========================================================================
  3. PLANS
  =========================================================================== }

destructor TXmlMemberPlan.Destroy;
begin
  Inner.Free;
  Item.Free;
  Key.Free;
  Value.Free;
  { BoundPlan and Serializer are borrowed. }
  inherited Destroy;
end;

function TXmlMemberPlan.IsSimple: Boolean;
begin
  case Kind of
    TXmlKind.BoolValue, TXmlKind.IntValue, TXmlKind.Int64Value,
    TXmlKind.FloatValue, TXmlKind.CurrencyValue, TXmlKind.StrValue,
    TXmlKind.DateValue, TXmlKind.TimeValue, TXmlKind.DateTimeValue,
    TXmlKind.GuidValue, TXmlKind.BytesValue, TXmlKind.EnumValue,
    TXmlKind.SetValue:
      Result := True;
    TXmlKind.NullableValue:
      Result := (Inner <> nil) and Inner.IsSimple;
  else
    Result := False;
  end;
end;

function TXmlMemberPlan.IsContainer: Boolean;
begin
  Result := Kind in [TXmlKind.ListValue, TXmlKind.ArrayValue,
    TXmlKind.DictionaryValue];
end;

destructor TXmlFieldPlan.Destroy;
begin
  Member.Free;
  inherited Destroy;
end;

constructor TXmlTypePlan.Create;
begin
  inherited Create;
  Fields := TObjectList<TXmlFieldPlan>.Create(True);
end;

destructor TXmlTypePlan.Destroy;
begin
  Fields.Free;
  inherited Destroy;
end;

{ ===========================================================================
  THE ENGINE
  =========================================================================== }

class constructor TXmlEngine.Create;
begin
  FCtx := TRttiContext.Create;
  FLock := TCriticalSection.Create;
  FPlans := TDictionary<PTypeInfo, TXmlTypePlan>.Create;
  FRootPlans := TObjectDictionary<PTypeInfo, TXmlMemberPlan>.Create([doOwnsValues]);
  FEnumMappings := TDictionary<PTypeInfo, TArray<string>>.Create;
  FTypeSerializers := TDictionary<PTypeInfo, TXmlValueSerializerClass>.Create;
  FSerializerSingletons :=
    TObjectDictionary<TClass, TCustomXmlValueSerializer>.Create([doOwnsValues]);
  FBuildTrail := TList<PTypeInfo>.Create;
  { The built-in defaults are the xs: forms, and they are what Resolve
    returns until something is registered - which is how adding a policy
    mechanism leaves existing output exactly where it was. }
  FDatePolicies := TDateTimePolicies.Create(
    TDateTimePolicy.Make(Ord(TXmlDateTimeFormat.Xsd)));
  FTimePolicies := TDateTimePolicies.Create(
    TDateTimePolicy.Make(Ord(TXmlDateTimeFormat.Xsd)));
  FTimestampPolicies := TDateTimePolicies.Create(
    TDateTimePolicy.Make(Ord(TXmlDateTimeFormat.Xsd)));
end;

class destructor TXmlEngine.Destroy;
var
  P: TXmlTypePlan;
begin
  for P in FPlans.Values do P.Free;
  FPlans.Free;
  FRootPlans.Free;
  FTimestampPolicies.Free;
  FTimePolicies.Free;
  FDatePolicies.Free;
  FBuildTrail.Free;
  FSerializerSingletons.Free;
  FTypeSerializers.Free;
  FEnumMappings.Free;
  FLock.Free;
  FCtx.Free;
end;

class procedure TXmlEngine.CheckNotFrozen;
begin
  if FFrozen then
    raise EXmlInternalError.Create(
      'XML configuration is frozen. A registration has to happen before the ' +
      'type it affects is first used, because a plan is cached at that ' +
      'moment; afterwards it would be a silent no-op.');
end;

class procedure TXmlEngine.RollbackBuildTrail;
var
  TI: PTypeInfo;
  P: TXmlTypePlan;
begin
  for TI in FBuildTrail do
    if FPlans.TryGetValue(TI, P) then
    begin
      FPlans.Remove(TI);
      P.Free;
    end;
  FBuildTrail.Clear;
end;

class function TXmlEngine.PoliciesFor(AKind: TXmlKind): TDateTimePolicies;
begin
  case AKind of
    TXmlKind.DateValue: Result := FDatePolicies;
    TXmlKind.TimeValue: Result := FTimePolicies;
  else
    Result := FTimestampPolicies;
  end;
end;

class function TXmlEngine.ResolveSerializer(
  AClass: TXmlValueSerializerClass): TCustomXmlValueSerializer;
begin
  if AClass = nil then Exit(nil);
  if not FSerializerSingletons.TryGetValue(AClass, Result) then
  begin
    Result := AClass.Create;
    FSerializerSingletons.Add(AClass, Result);
  end;
end;

class function TXmlEngine.EnumMappingFor(ATypeInfo: PTypeInfo): TArray<string>;
begin
  { This format's own registration first; then [SerializationEnum] on the
    type. }
  if (ATypeInfo = nil) or not FEnumMappings.TryGetValue(ATypeInfo, Result) then
    Result := TSerializationMetadata.EnumValuesOf(ATypeInfo);
end;

{ A member's [SerializationEnum]: on the enumeration, or a nullable's
  inner one, unless this format registered a mapping for that type. }
class procedure TXmlEngine.ApplyGeneralEnum(APlan: TXmlMemberPlan;
  const AValues: TArray<string>);
begin
  if (APlan.Kind = TXmlKind.NullableValue) and (APlan.Inner <> nil) then
    APlan := APlan.Inner;
  if (APlan.Kind = TXmlKind.EnumValue) and (APlan.TypeInfo <> nil) and
     not FEnumMappings.ContainsKey(APlan.TypeInfo) then
    APlan.EnumMapping := AValues;
end;

{ ------------------------------------------------------------ classifying --- }

class function TXmlEngine.ClassifyType(ATypeInfo: PTypeInfo): TXmlKind;
var
  Access: TNullableAccess;
begin
  if ATypeInfo = nil then Exit(TXmlKind.Unsupported);
  if FTypeSerializers.ContainsKey(ATypeInfo) then Exit(TXmlKind.CustomSerializer);
  if ATypeInfo = System.TypeInfo(TGUID) then Exit(TXmlKind.GuidValue);
  if ATypeInfo = System.TypeInfo(TDate) then Exit(TXmlKind.DateValue);
  if ATypeInfo = System.TypeInfo(TTime) then Exit(TXmlKind.TimeValue);
  if ATypeInfo = System.TypeInfo(TDateTime) then Exit(TXmlKind.DateTimeValue);
  if ATypeInfo = System.TypeInfo(TBytes) then Exit(TXmlKind.BytesValue);
  if TSerializationTypes.TryGetNullableAccess(ATypeInfo, Access) then
    Exit(TXmlKind.NullableValue);

  case ATypeInfo.Kind of
    tkInteger: Result := TXmlKind.IntValue;
    tkInt64: Result := TXmlKind.Int64Value;
    tkFloat:
      { Comp is a 64-bit integer RTTI files under tkFloat; as a float it
        lost every digit past 2^53. }
      if GetTypeData(ATypeInfo).FloatType = ftCurr then
        Result := TXmlKind.CurrencyValue
      else if GetTypeData(ATypeInfo).FloatType = ftComp then
        Result := TXmlKind.Int64Value
      else
        Result := TXmlKind.FloatValue;
    tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
      Result := TXmlKind.StrValue;
    tkEnumeration:
      if (ATypeInfo = System.TypeInfo(Boolean)) or
         (ATypeInfo = System.TypeInfo(ByteBool)) or
         (ATypeInfo = System.TypeInfo(WordBool)) or
         (ATypeInfo = System.TypeInfo(LongBool)) then
        Result := TXmlKind.BoolValue
      else
        Result := TXmlKind.EnumValue;
    tkSet: Result := TXmlKind.SetValue;
    tkRecord, tkMRecord: Result := TXmlKind.RecordValue;
    tkDynArray, tkArray: Result := TXmlKind.ArrayValue;
    tkClass:
      { THE ONE QUESTION, ASKED IN ONE PLACE. TSerializationTypes matches by
        ancestry, so TOrders = class(TObjectList<TOrder>) is a list and a
        class that merely has an Add and a ToArray is not. Six engines used
        to answer this for themselves and three of them got it wrong. }
      case TSerializationTypes.ContainerKindOf(ATypeInfo) of
        TContainerKind.Dictionary: Result := TXmlKind.DictionaryValue;
        TContainerKind.List:       Result := TXmlKind.ListValue;
      else
        Result := TXmlKind.ObjectValue;
      end;
  else
    Result := TXmlKind.Unsupported;
  end;
end;

class function TXmlEngine.DefaultRootNameFor(ATypeInfo: PTypeInfo): string;
begin
  if ATypeInfo = nil then Exit('Value');
  Result := UTF8ToString(ATypeInfo.Name);
  { TShipment -> Shipment. A leading T is Delphi's convention, not the
    document's. }
  if (Length(Result) > 1) and (Result[1] = 'T') and
     CharInSet(Result[2], ['A'..'Z']) then
    Result := Result.Substring(1);
  { A closed generic's name carries angle brackets and dots and cannot be an
    element name at all. }
  if not IsValidXmlName(Result) then Result := 'Value';
end;

class function TXmlEngine.DefaultItemNameFor(ATypeInfo: PTypeInfo): string;
begin
  if ClassifyType(ATypeInfo) in [TXmlKind.ObjectValue, TXmlKind.RecordValue] then
    Result := DefaultRootNameFor(ATypeInfo)
  else
    Result := 'Item';
  if Result = 'Value' then Result := 'Item';
end;

{ --------------------------------------------------------------- plans --- }

class function TXmlEngine.BuildMemberPlan(ATypeInfo: PTypeInfo;
  const AOwnerKey, AMemberName: string): TXmlMemberPlan;
var
  Why: string;
  ListAccess: TListAccess;
  SerCls: TXmlValueSerializerClass;
  T, PairType: TRttiType;
  M: TRttiMethod;
  Params: TArray<TRttiParameter>;
  Policy: TDateTimePolicy;
  Access: TNullableAccess;
  ElemType: PTypeInfo;
  StaticCount, StaticSize: Integer;
begin
  Result := TXmlMemberPlan.Create;
  try
    Result.TypeInfo := ATypeInfo;
    Result.Kind := ClassifyType(ATypeInfo);

    if Result.Kind = TXmlKind.CustomSerializer then
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
      raise EXmlError.CreateFmt(
        '%s %s. Leave it out with [XmlIgnore], or register an XML ' +
        'type serializer for its type.',
        [MemberDisplayName(AOwnerKey, AMemberName), Why]);
    { A Variant is refused by design, not by accident: element text has no
      type of its own, so a Variant read back could not know whether it had
      held the number 42 or the text "42". }
    if ATypeInfo.Kind = tkVariant then
      raise EXmlError.CreateFmt(
        '%s is a Variant, and XML element text has no type of its own to ' +
        'say what one held. Register an XML type serializer for it, or ' +
        'give the member a declared type.',
        [MemberDisplayName(AOwnerKey, AMemberName)]);

    case Result.Kind of
      TXmlKind.DateValue, TXmlKind.TimeValue, TXmlKind.DateTimeValue:
        begin
          Policy := PoliciesFor(Result.Kind).Resolve(AOwnerKey, AMemberName);
          Result.DateFormat := TXmlDateTimeFormat(Policy.Kind);
          Result.DatePattern := Policy.Pattern;
        end;

      TXmlKind.EnumValue:
        Result.EnumMapping := EnumMappingFor(ATypeInfo);

      TXmlKind.SetValue:
        begin
          Result.SetElemTypeInfo := ATypeInfo.TypeData.CompType^;
          Result.SetElemMapping := EnumMappingFor(Result.SetElemTypeInfo);
        end;

      TXmlKind.NullableValue:
        begin
          if not TSerializationTypes.TryGetNullableAccess(ATypeInfo, Access) then
            raise EXmlInternalError.CreateFmt(
              'Internal: %s was classified as a nullable but its layout ' +
              'cannot be resolved.', [UTF8ToString(ATypeInfo.Name)]);
          Result.NullableAccess := Access;
          Result.Inner := BuildMemberPlan(Access.ValueType, AOwnerKey,
            AMemberName);
        end;

      TXmlKind.ObjectValue, TXmlKind.RecordValue:
        Result.BoundPlan := GetPlan(ATypeInfo, '');

      TXmlKind.ArrayValue:
        begin
          ElemType := nil;
          if ATypeInfo.Kind = tkArray then
            TSerializationTypes.TryGetStaticArrayShape(ATypeInfo, ElemType,
              StaticCount, StaticSize)
          else if GetTypeData(ATypeInfo).DynArrElType <> nil then
            ElemType := GetTypeData(ATypeInfo).DynArrElType^;
          if ElemType = nil then
            raise EXmlInternalError.CreateFmt(
              'Cannot serialize %s: its element type has no RTTI.',
              [UTF8ToString(ATypeInfo.Name)]);
          Result.Item := BuildMemberPlan(ElemType, AOwnerKey, AMemberName);
          Result.ItemName := DefaultItemNameFor(ElemType);
        end;

      TXmlKind.ListValue, TXmlKind.DictionaryValue:
        begin
          T := FCtx.GetType(ATypeInfo);
          if T = nil then
            raise EXmlInternalError.CreateFmt(
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
            else if (Result.Kind = TXmlKind.ListValue) and
                    SameText(M.Name, 'Add') and (Length(Params) = 1) then
              Result.ContainerAdd := M
            else if (Result.Kind = TXmlKind.DictionaryValue) and
                    SameText(M.Name, 'AddOrSetValue') and (Length(Params) = 2) then
              Result.ContainerAdd := M;
          end;
          { A list's methods are the ones Core names for its family: a
            TQueue<T> enqueues, a TStack<T> pushes and a TStrings adds a
            line. Looking for a method called Add found nothing for the
            first two, and the members of the container were walked
            instead - its OnNotify event among them. }
          if (Result.Kind = TXmlKind.ListValue) and
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
            raise EXmlInternalError.CreateFmt(
              'Cannot serialize %s: it looks like a collection but has no ' +
              'usable Add/ToArray pair.', [UTF8ToString(ATypeInfo.Name)]);
          Params := Result.ContainerAdd.GetParameters;
          if Result.Kind = TXmlKind.ListValue then
          begin
            Result.Item := BuildMemberPlan(Params[0].ParamType.Handle,
              AOwnerKey, AMemberName);
            Result.ItemName := DefaultItemNameFor(Params[0].ParamType.Handle);
          end
          else
          begin
            Result.Key := BuildMemberPlan(Params[0].ParamType.Handle,
              AOwnerKey, AMemberName);
            Result.Value := BuildMemberPlan(Params[1].ParamType.Handle,
              AOwnerKey, AMemberName);
            Result.ItemName := 'Entry';
            if not Result.Key.IsSimple then
              raise EXmlInternalError.CreateFmt(
                'Cannot serialize %s: an XML dictionary key is an attribute, ' +
                'so it must have a single text form, and %s does not.',
                [UTF8ToString(ATypeInfo.Name),
                 UTF8ToString(Params[0].ParamType.Handle.Name)]);
            PairType := nil;
            if (Result.ContainerToArray.ReturnType <> nil) and
               (GetTypeData(Result.ContainerToArray.ReturnType.Handle).DynArrElType <> nil) then
              PairType := FCtx.GetType(
                GetTypeData(Result.ContainerToArray.ReturnType.Handle).DynArrElType^);
            if PairType <> nil then
            begin
              Result.PairKeyField := PairType.GetField('Key');
              Result.PairValueField := PairType.GetField('Value');
            end;
            if (Result.PairKeyField = nil) or (Result.PairValueField = nil) then
              raise EXmlInternalError.CreateFmt(
                'Cannot serialize %s: its ToArray does not yield key/value ' +
                'pairs.', [UTF8ToString(ATypeInfo.Name)]);
            Result.HasDictionaryAccess :=
              TSerializationTypes.TryGetDictionaryAccess(ATypeInfo,
                Result.DictionaryAccess);
          end;
        end;

      TXmlKind.Unsupported:
        raise EXmlInternalError.CreateFmt(
          'XML cannot represent %s (type kind %d). Register a custom XML ' +
          'serializer for it, or mark the member [XmlIgnore].',
          [UTF8ToString(ATypeInfo.Name), Ord(ATypeInfo.Kind)]);
    end;
  except
    Result.Free;
    raise;
  end;
end;

class procedure TXmlEngine.BuildMemberOfType(APlan: TXmlTypePlan;
  AMember: TSerializationMember);
var
  AField: TRttiField;
  AProp: TRttiProperty;
  FP: TXmlFieldPlan;
  Attr: TCustomAttribute;
  Attrs: TArray<TCustomAttribute>;
  MemberType: PTypeInfo;
  MemberName, Placement: string;
  SerCls: TXmlValueSerializerClass;
  DateAttr: XmlDateTimeFormatAttribute;
begin
  AField := AMember.Field;
  AProp := AMember.Prop;
  if AField <> nil then
  begin
    if AField.FieldType = nil then
    begin
      { Ignored deliberately, or refused - never skipped silently. }
      for Attr in AField.GetAttributes do
        if Attr is XmlIgnoreAttribute then Exit;
      raise EXmlError.CreateFmt(
        '%s %s. Leave it out with [XmlIgnore], or register an XML ' +
        'type serializer for the type that holds it.',
        [MemberDisplayName(UTF8ToString(APlan.TypeInfo.Name), AField.Name),
         TSerializationTypes.UnsupportedReason(nil)]);
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

  { [XmlIgnore] is honoured before anything is built, so an ignored member of
    a type XML could not represent costs nothing and raises nothing. }
  for Attr in Attrs do
    if Attr is XmlIgnoreAttribute then Exit;

  FP := TXmlFieldPlan.Create;
  try
    FP.Field := AField;
    FP.Prop := AProp;
    FP.DelphiName := MemberName;
    FP.Name := MemberName;
    { [SerializationName] names it; the format's own name attribute, read
      below, beats it. }
    if AMember.HasGeneralName then FP.Name := AMember.GeneralName;
    FP.Wrapped := True;
    FP.NamespaceUri := APlan.NamespaceUri;
    FP.Writable := (AField <> nil) or AProp.IsWritable;
    if AField <> nil then FP.DeclaringTypeName := AField.Parent.Name
    else FP.DeclaringTypeName := AProp.Parent.Name;

    SerCls := nil;
    DateAttr := nil;
    for Attr in Attrs do
      if Attr is XmlNameAttribute then FP.Name := XmlNameAttribute(Attr).Name
      else if Attr is XmlAttributeAttribute then FP.IsAttribute := True
      else if Attr is XmlTextAttribute then FP.IsText := True
      else if Attr is XmlNamespaceAttribute then
        FP.NamespaceUri := XmlNamespaceAttribute(Attr).Uri
      else if Attr is XmlArrayAttribute then
      begin
        FP.Wrapped := XmlArrayAttribute(Attr).Wrapped;
        if FP.Wrapped then FP.WrapperName := XmlArrayAttribute(Attr).WrapperName;
      end
      else if Attr is XmlItemNameAttribute then
        FP.ItemName := XmlItemNameAttribute(Attr).ItemName
      else if Attr is XmlSerializerAttribute then
        SerCls := XmlSerializerAttribute(Attr).SerializerClass
      else if Attr is XmlDateTimeFormatAttribute then
        DateAttr := XmlDateTimeFormatAttribute(Attr);

    if not IsValidXmlName(FP.Name) then
      raise EXmlInternalError.CreateFmt(
        '"%s" is not a valid XML name for %s.%s. Give the member an ' +
        '[XmlName(...)] the document can carry.',
        [FP.Name, APlan.RttiType.Name, MemberName]);

    if SerCls <> nil then
    begin
      FP.Member := TXmlMemberPlan.Create;
      FP.Member.TypeInfo := MemberType;
      FP.Member.Kind := TXmlKind.CustomSerializer;
      FP.Member.Serializer := ResolveSerializer(SerCls);
    end
    else
      FP.Member := BuildMemberPlan(MemberType, APlan.TypeKey, MemberName);

    { [SerializationEnum] on the member, unless this format has its own
      mapping registered for the enumeration. }
    if AMember.HasEnumValues then
      ApplyGeneralEnum(FP.Member, AMember.EnumValues);

    { A member-level [XmlDateTimeFormat] beats every registration, so it is
      applied after the plan has resolved the registered ones. }
    if DateAttr <> nil then
    begin
      if (FP.Member.Kind = TXmlKind.NullableValue) and (FP.Member.Inner <> nil) then
      begin
        FP.Member.Inner.DateFormat := DateAttr.Format;
        FP.Member.Inner.DatePattern := DateAttr.Pattern;
      end
      else
      begin
        FP.Member.DateFormat := DateAttr.Format;
        FP.Member.DatePattern := DateAttr.Pattern;
      end;
    end;

    if FP.WrapperName = '' then FP.WrapperName := FP.Name;
    if FP.ItemName = '' then FP.ItemName := FP.Member.ItemName;

    if FP.IsAttribute and FP.IsText then
      raise EXmlInternalError.CreateFmt(
        '%s.%s is marked both [XmlAttribute] and [XmlText]; it can be one or ' +
        'the other.', [APlan.RttiType.Name, MemberName]);
    if (FP.IsAttribute or FP.IsText) and not FP.Member.IsSimple then
    begin
      if FP.IsAttribute then Placement := '[XmlAttribute]'
      else Placement := '[XmlText]';
      raise EXmlInternalError.CreateFmt(
        '%s.%s is marked %s, but %s has no single text form. Only scalars, ' +
        'enumerations, sets, GUIDs, dates, byte arrays and nullables of ' +
        'those can be written that way.',
        [APlan.RttiType.Name, MemberName, Placement, UTF8ToString(MemberType.Name)]);
    end;
    if FP.IsText then
    begin
      if APlan.TextField <> nil then
        raise EXmlInternalError.CreateFmt(
          '%s has two [XmlText] members, %s and %s. An element has one text ' +
          'content.',
          [APlan.RttiType.Name, APlan.TextField.DelphiName, MemberName]);
      APlan.TextField := FP;
    end;

    APlan.Fields.Add(FP);
    FP := nil;
  finally
    FP.Free;
  end;
end;

class function TXmlEngine.BuildPlan(ATypeInfo: PTypeInfo;
  const AUnitHint: string): TXmlTypePlan;
var
  Registered: Boolean;
  T: TRttiType;
  Attr: TCustomAttribute;
  Names: TDictionary<string, string>;
  Member: TSerializationMember;
  FP: TXmlFieldPlan;
  Existing, NameKey: string;
begin
  Result := TXmlTypePlan.Create;
  Inc(FBuildDepth);
  try
    Result.TypeInfo := ATypeInfo;
    T := FCtx.GetType(ATypeInfo);
    if T = nil then
      raise EXmlInternalError.CreateFmt(
        'Cannot build an XML plan for %s: the type exposes no usable RTTI. ' +
        'A type declared inside a routine body has none; declare it at unit ' +
        'scope, or register a custom XML serializer for it.',
        [UTF8ToString(ATypeInfo.Name)]);
    Result.RttiType := T;
    Result.IsRecord := ATypeInfo.Kind in [tkRecord, tkMRecord];
    Result.UnitName := TypeUnitOf(ATypeInfo, AUnitHint);
    Result.TypeKey := TypeKeyOf(ATypeInfo, Result.UnitName);
    Result.RootName := DefaultRootNameFor(ATypeInfo);
    if not Result.IsRecord then
    begin
      Result.ClassType := ATypeInfo.TypeData.ClassType;
      Result.ZeroConstructor := TSerializationMetadata.Get(ATypeInfo).DeclaredConstructor;
      if Result.ZeroConstructor = nil then
        Result.ZeroConstructor := TSerializationMetadata.Get(ATypeInfo).TObjectConstructor;
    end;

    for Attr in T.GetAttributes do
      if Attr is XmlNameAttribute then
        Result.RootName := XmlNameAttribute(Attr).Name
      else if Attr is XmlNamespaceAttribute then
      begin
        Result.NamespaceUri := XmlNamespaceAttribute(Attr).Uri;
        Result.NamespacePrefix := XmlNamespaceAttribute(Attr).Prefix;
      end;

    { Published before its members are built, so a recursive type resolves to
      the plan being built rather than starting a second one. }
    FPlans.Add(ATypeInfo, Result);
    FBuildTrail.Add(ATypeInfo);

    { A descendant that republishes an inherited member must appear once, as
      the descendant's version. }
    { The member surface and the general attributes come from the shared
      metadata. }
    for Member in TSerializationMetadata.Get(ATypeInfo).Members do
      if not Member.Ignored then BuildMemberOfType(Result, Member);

    Names := TDictionary<string, string>.Create;
    try
      for FP in Result.Fields do
      begin
        if FP.IsText then Continue;
        NameKey := LowerCase(FP.Name) + '|' + LowerCase(FP.NamespaceUri) +
          '|' + BoolToStr(FP.IsAttribute);
        if Names.TryGetValue(NameKey, Existing) then
          raise EXmlInternalError.CreateFmt(
            'Duplicate XML name "%s" in %s: Delphi members %s and %s',
            [FP.Name, UTF8ToString(ATypeInfo.Name), Existing,
             FP.DeclaringTypeName + '.' + FP.DelphiName])
        else
          Names.Add(NameKey, FP.DeclaringTypeName + '.' + FP.DelphiName);
      end;
    finally
      Names.Free;
    end;

    Dec(FBuildDepth);
    if FBuildDepth = 0 then FBuildTrail.Clear;
  except
    { Ownership is decided BEFORE the rollback: a plan already in FPlans
      belongs to the build trail and the rollback frees it; one that never
      got that far is freed here. Asking after the rollback always answered
      "not there", and the plan was freed twice. }
    Registered := FPlans.ContainsValue(Result);
    Dec(FBuildDepth);
    { Every provisional entry this build published is withdrawn, not just
      this one: a plan finished earlier in the same build may already hold a
      borrowed reference to one about to be destroyed. }
    if FBuildDepth = 0 then RollbackBuildTrail;
    if not Registered then Result.Free;
    raise;
  end;
end;

class function TXmlEngine.GetPlan(ATypeInfo: PTypeInfo;
  const AUnitHint: string): TXmlTypePlan;
begin
  if FPlans.TryGetValue(ATypeInfo, Result) then Exit;
  Result := BuildPlan(ATypeInfo, AUnitHint);
end;

class function TXmlEngine.GetRootPlan(ATypeInfo: PTypeInfo): TXmlMemberPlan;
begin
  if FRootPlans.TryGetValue(ATypeInfo, Result) then Exit;
  Result := BuildMemberPlan(ATypeInfo, TypeKeyOf(ATypeInfo), '');
  FRootPlans.Add(ATypeInfo, Result);
end;

{ ------------------------------------------------------------ instances --- }

class function TXmlEngine.NewInstanceOf(APlan: TXmlTypePlan): TObject;
begin
  if APlan.ZeroConstructor <> nil then
    Result := APlan.ZeroConstructor.Invoke(APlan.ClassType, []).AsObject
  else
    Result := APlan.ClassType.Create;
end;

class function TXmlEngine.NewContainer(APlan: TXmlMemberPlan): TObject;
begin
  if APlan.ContainerCreate = nil then
    raise EXmlInternalError.CreateFmt(
      'Cannot construct %s: it has no parameterless constructor. Create the ' +
      'container in its owner''s constructor; XML will fill the one that is ' +
      'already there.', [UTF8ToString(APlan.TypeInfo.Name)]);
  Result := APlan.ContainerCreate.Invoke(
    GetTypeData(APlan.TypeInfo).ClassType, []).AsObject;
end;

class function TXmlEngine.ReadMember(AFP: TXmlFieldPlan;
  AInstance: Pointer): TValue;
begin
  if AFP.Field <> nil then Result := AFP.Field.GetValue(AInstance)
  else Result := AFP.Prop.GetValue(AInstance);
end;

class procedure TXmlEngine.StoreMember(AFP: TXmlFieldPlan; AInstance: Pointer;
  const AValue: TValue);
begin
  if AFP.Field <> nil then AFP.Field.SetValue(AInstance, AValue)
  else if AFP.Prop.IsWritable then AFP.Prop.SetValue(AInstance, AValue);
end;

{ ------------------------------------------------------------ text forms --- }

class function TXmlEngine.EnumToText(ATypeInfo: PTypeInfo; AOrdinal: Integer;
  const AMapping: TArray<string>): string;
begin
  { A set of an integer subrange or of characters has no names: its
    members are their ordinals. See TSerializationTypes.SetElementText. }
  if ATypeInfo.Kind <> tkEnumeration then
    Exit(TSerializationTypes.SetElementText(ATypeInfo, AOrdinal));
  if AMapping <> nil then
  begin
    if (AOrdinal < 0) or (AOrdinal > High(AMapping)) then
      raise EXmlInternalError.CreateFmt(
        'Mapped enumeration %s ordinal %d is outside the registered mapping ' +
        '0..%d', [UTF8ToString(ATypeInfo.Name), AOrdinal, High(AMapping)]);
    Exit(AMapping[AOrdinal]);
  end;
  Result := GetEnumName(ATypeInfo, AOrdinal);
end;

class function TXmlEngine.TextToEnumOrdinal(ATypeInfo: PTypeInfo;
  const AText: string; const AMapping: TArray<string>): Integer;
var
  I: Integer;
  S: string;
begin
  if ATypeInfo.Kind <> tkEnumeration then
  begin
    if not TSerializationTypes.TrySetElementOrdinal(ATypeInfo, Trim(AText),
         Result) then
      raise EXmlInputError.CreateFmt('"%s" is not a member of %s.',
        [Trim(AText), UTF8ToString(ATypeInfo.Name)]);
    Exit;
  end;
  S := Trim(AText);
  if AMapping <> nil then
  begin
    for I := 0 to Integer(High(AMapping)) do
      if SameText(AMapping[I], S) then Exit(I);
    raise EXmlInputError.CreateFmt(
      '"%s" is not a registered value of %s.', [S, UTF8ToString(ATypeInfo.Name)]);
  end;
  Result := GetEnumValue(ATypeInfo, S);
  if Result < 0 then
    raise EXmlInputError.CreateFmt(
      '"%s" is not a value of %s.', [S, UTF8ToString(ATypeInfo.Name)]);
end;

{ Through TSerializationTypes, which knows that a set's bit 0 is the byte
  holding its lowest member: counting from ordinal 0 wrote 10 as 12. }
class function TXmlEngine.SetToText(APlan: TXmlMemberPlan;
  const AValue: TValue): string;
var
  Ords: TArray<Integer>;
  Parts: TArray<string>;
  I: Integer;
begin
  Ords := TSerializationTypes.SetOrdinals(APlan.TypeInfo, AValue);
  SetLength(Parts, Length(Ords));
  for I := 0 to Integer(High(Ords)) do
    Parts[I] := EnumToText(APlan.SetElemTypeInfo, Ords[I], APlan.SetElemMapping);
  { Space separated, which is what xs:list does. JSON joins with commas; the
    two formats are not obliged to agree and here they do not. }
  Result := string.Join(' ', Parts);
end;

class function TXmlEngine.TextToSet(APlan: TXmlMemberPlan;
  const AText: string): TValue;
var
  Names: TArray<string>;
  Name, Why: string;
  Ords: TArray<Integer>;
begin
  Ords := nil;
  Names := Trim(AText).Split([' ', #9, #10, #13],
    TStringSplitOptions.ExcludeEmpty);
  for Name in Names do
    Ords := Ords + [TextToEnumOrdinal(APlan.SetElemTypeInfo, Name,
      APlan.SetElemMapping)];
  if not TSerializationTypes.TryMakeSet(APlan.TypeInfo, Ords, Result, Why) then
    raise EXmlInputError.CreateFmt('"%s" is not a %s: %s.',
      [Trim(AText), UTF8ToString(APlan.TypeInfo.Name), Why]);
end;

class function TXmlEngine.DateToText(APlan: TXmlMemberPlan;
  AValue: TDateTime): string;
var
  Ms: Word;
  H, N, S: Word;
  Millis: Int64;
begin
  { A date outside the years 1 to 9999 is refused before anything is
    written: FormatDateTime spells one before year 1 as 0000-00-00, and the
    reader refuses every such value back. An xs:time states a time of day
    and has no year to check. }
  if (APlan.Kind <> TXmlKind.TimeValue) or
     (APlan.DateFormat <> TXmlDateTimeFormat.Xsd) then
    TStructuralText.CheckDateTime(AValue);
  case APlan.DateFormat of
    TXmlDateTimeFormat.UnixSeconds, TXmlDateTimeFormat.UnixMilliseconds:
      begin
        { The TDateTime is taken as the instant it states. Nothing is shifted:
          TDateTime carries no zone, and inventing one would make the value
          depend on where the process runs. Before 1899-12-30 a TDateTime is
          a negative day with a POSITIVE time of day, and the linear
          (AValue - UnixDateDelta) * MSecsPerDay put every such instant a day
          early; Core follows the encoding. }
        if not TStructuralText.TryDateTimeToUnixMillis(AValue, Millis) then
          raise ESerializationUnsupported.CreateFmt(
            'The TDateTime %s rounds to an instant after ' +
            '9999-12-31T23:59:59.999, which no reader here accepts back.',
            [FloatToStr(AValue, TFormatSettings.Invariant)]);
        if APlan.DateFormat = TXmlDateTimeFormat.UnixMilliseconds then
          Exit(IntToStr(Millis));
        { Whole seconds rounded DOWN: half a second before the epoch is
          second -1, and DateTimeToUnix made it 0. }
        if Millis < 0 then Exit(IntToStr(-((-Millis + 999) div 1000)));
        Exit(IntToStr(Millis div 1000));
      end;
    TXmlDateTimeFormat.Custom:
      Exit(FormatDateTime(APlan.DatePattern, AValue,
        TFormatSettings.Invariant));
  end;

  DecodeTime(AValue, H, N, S, Ms);
  case APlan.Kind of
    TXmlKind.DateValue:
      Result := FormatDateTime('yyyy"-"mm"-"dd', AValue,
        TFormatSettings.Invariant);
    TXmlKind.TimeValue:
      if Ms = 0 then
        Result := FormatDateTime('hh":"nn":"ss', AValue,
          TFormatSettings.Invariant)
      else
        Result := FormatDateTime('hh":"nn":"ss"."zzz', AValue,
          TFormatSettings.Invariant);
  else
    if Ms = 0 then
      Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss', AValue,
        TFormatSettings.Invariant)
    else
      Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz', AValue,
        TFormatSettings.Invariant);
  end;
end;

{ Which xs: type a kind is written as, for the message when it does not
  parse. }
function XsdNameOf(AKind: TXmlKind): string;
begin
  case AKind of
    TXmlKind.DateValue: Result := 'date';
    TXmlKind.TimeValue: Result := 'time';
  else
    Result := 'dateTime';
  end;
end;

class function TXmlEngine.TextToDate(APlan: TXmlMemberPlan;
  const AText: string): TDateTime;
var
  S: string;
  I64: Int64;
  Y, M, D, H, N, Sec, Ms: Word;
  Frac: string;
  TzPos: Integer;
begin
  S := Trim(AText);
  if S = '' then
    raise EXmlInputError.Create('An empty value is not a date or a time.');

  case APlan.DateFormat of
    { Range-checked: a count past the years 1 to 9999 is refused, where
      UnixToDateTime answered with a wrong date and IncMilliSecond with
      EIntOverflow or EConvertError. }
    TXmlDateTimeFormat.UnixSeconds:
      begin
        if not TryStrToInt64(S, I64) then
          raise EXmlInputError.CreateFmt(
            '"%s" is not a Unix second count.', [S]);
        if not TStructuralText.TryUnixSecondsToDateTime(I64, Result) then
          raise EXmlInputError.CreateFmt(
            'The Unix second count %s is outside the years 1 to 9999.', [S]);
        Exit;
      end;
    TXmlDateTimeFormat.UnixMilliseconds:
      begin
        if not TryStrToInt64(S, I64) then
          raise EXmlInputError.CreateFmt(
            '"%s" is not a Unix millisecond count.', [S]);
        if not TStructuralText.TryUnixMillisToDateTime(I64, Result) then
          raise EXmlInputError.CreateFmt(
            'The Unix millisecond count %s is outside the years 1 to 9999.',
            [S]);
        Exit;
      end;
    TXmlDateTimeFormat.Custom:
      begin
        { The pattern the writer wrote with, then the RTL's invariant
          reading, which is what 0.9 used and still reads what it read. }
        if not TStructuralText.TryDecodePattern(S, APlan.DatePattern,
             Result) and
           not TryStrToDateTime(S, Result, TFormatSettings.Invariant) then
          raise EXmlInputError.CreateFmt(
            '"%s" does not match the configured pattern "%s".',
            [S, APlan.DatePattern]);
        Exit;
      end;
  end;

  { xs:date, xs:time and xs:dateTime. A trailing zone designator is accepted
    and IGNORED: the wall-clock fields are taken as written, which is the
    only reading a TDateTime can represent honestly. }
  { A trailing zone designator, if there is one. Only a '+' or a '-' PAST
    the date part can be one: the hyphens inside 2026-03-14 are not. }
  if S.EndsWith('Z') then
    TzPos := Length(S)
  else
  begin
    TzPos := LastDelimiter('+', S);
    if TzPos <= 10 then
    begin
      TzPos := S.LastIndexOf('-') + 1;
      if TzPos <= 10 then TzPos := 0;
    end;
  end;
  if TzPos > 0 then S := Copy(S, 1, TzPos - 1);

  H := 0; N := 0; Sec := 0; Ms := 0;
  try
    if APlan.Kind = TXmlKind.TimeValue then
    begin
      H := Word(StrToInt(Copy(S, 1, 2)));
      N := Word(StrToInt(Copy(S, 4, 2)));
      Sec := Word(StrToInt(Copy(S, 7, 2)));
      Frac := Copy(S, 10, 3);
      if (Length(S) > 9) and (S[9] = '.') then Ms := Word(StrToIntDef(Frac, 0));
      Exit(EncodeTime(H, N, Sec, Ms));
    end;
    Y := Word(StrToInt(Copy(S, 1, 4)));
    M := Word(StrToInt(Copy(S, 6, 2)));
    D := Word(StrToInt(Copy(S, 9, 2)));
    if (Length(S) > 10) and CharInSet(S[11], ['T', ' ']) then
    begin
      H := Word(StrToInt(Copy(S, 12, 2)));
      N := Word(StrToInt(Copy(S, 15, 2)));
      Sec := Word(StrToInt(Copy(S, 18, 2)));
      if (Length(S) > 20) and (S[20] = '.') then
        Ms := Word(StrToIntDef(Copy(S, 21, 3), 0));
    end;
    { Combined the way Delphi encodes them: before 1899-12-30 the date is
      negative and the time of day is SUBTRACTED from it. Adding it put
      1800-01-01T12:00 on 1800-01-02. }
    Result := TStructuralText.ComposeDateTime(EncodeDate(Y, M, D),
      EncodeTime(H, N, Sec, Ms));
  except
    on E: EConvertError do
      raise EXmlInputError.CreateFmt(
        '"%s" is not an xs:%s value.',
        [Trim(AText), XsdNameOf(APlan.Kind)]);
  end;
end;

{ xs:double and xs:float spell the three special values INF, -INF and NaN,
  and minus zero -0. Everything else is the shortest decimal that reads
  back as exactly the same value - FloatToStr's fifteen digits did not. }
function XsdFloatText(AValue: Double; ASingle: Boolean): string;
begin
  if AValue.IsNan then Exit('NaN');
  if AValue.IsPositiveInfinity then Exit('INF');
  if AValue.IsNegativeInfinity then Exit('-INF');
  if ASingle then Result := TStructuralText.EncodeSingle(AValue)
  else Result := TStructuralText.EncodeFloat(AValue);
end;

function TryXsdFloat(const AText: string; out AValue: Double): Boolean;
begin
  Result := True;
  if AText = 'NaN' then AValue := Double.NaN
  else if (AText = 'INF') or (AText = '+INF') then AValue := Double.PositiveInfinity
  else if AText = '-INF' then AValue := Double.NegativeInfinity
  else
    { Correctly rounded, the same on both platforms: on Win64 TryStrToFloat
      misread about a third of the 17-digit texts that name a double. }
    Result := TStructuralText.TryParseFloat(AText, AValue);
end;

class function TXmlEngine.SimpleToText(APlan: TXmlMemberPlan;
  const AValue: TValue): string;
var
  G: TGUID;
begin
  case APlan.Kind of
    TXmlKind.BoolValue:
      if AValue.AsOrdinal <> 0 then Result := 'true' else Result := 'false';
    { Digits with the sign the type gives them: AsInt64 on a UInt64 wrote
      18446744073709551615 as -1. }
    TXmlKind.IntValue, TXmlKind.Int64Value:
      Result := TSerializationTypes.IntegerText(AValue);
    TXmlKind.FloatValue:
      if GetTypeData(APlan.TypeInfo).FloatType = ftSingle then
        Result := XsdFloatText(AValue.AsExtended, True)
      else
        Result := XsdFloatText(AValue.AsExtended, False);
    TXmlKind.CurrencyValue:
      Result := CurrToStr(AValue.AsCurrency, TFormatSettings.Invariant);
    TXmlKind.StrValue:
      Result := AValue.AsString;
    TXmlKind.DateValue, TXmlKind.TimeValue, TXmlKind.DateTimeValue:
      Result := DateToText(APlan, AValue.AsType<TDateTime>);
    TXmlKind.GuidValue:
      begin
        G := AValue.AsType<TGUID>;
        { Lower case, no braces. XSD has no GUID type, and this is the form
          every schema that carries one uses. It is XML's rule, not an
          inheritance from JSON's. }
        Result := LowerCase(Copy(GUIDToString(G), 2, 36));
      end;
    TXmlKind.BytesValue:
      Result := TNetEncoding.Base64.EncodeBytesToString(AValue.AsType<TBytes>);
    TXmlKind.EnumValue:
      Result := EnumToText(APlan.TypeInfo, Integer(AValue.AsOrdinal), APlan.EnumMapping);
    TXmlKind.SetValue:
      Result := SetToText(APlan, AValue);
    TXmlKind.NullableValue:
      Result := SimpleToText(APlan.Inner,
        APlan.NullableAccess.GetValue(AValue.GetReferenceToRawData));
  else
    raise EXmlInternalError.CreateFmt(
      '%s has no single text form.', [UTF8ToString(APlan.TypeInfo.Name)]);
  end;
end;

class function TXmlEngine.TextToSimple(APlan: TXmlMemberPlan;
  const AText: string): TValue;
var
  Why: string;
  I64: Int64;
  D: Double;
  C: Currency;
  S: string;
  G: TGUID;
  Inner: TValue;
begin
  S := AText;
  case APlan.Kind of
    TXmlKind.BoolValue:
      begin
        S := LowerCase(Trim(S));
        if (S = 'true') or (S = '1') then Exit(TValue.From<Boolean>(True));
        if (S = 'false') or (S = '0') then Exit(TValue.From<Boolean>(False));
        raise EXmlInputError.CreateFmt('"%s" is not xs:boolean.', [AText]);
      end;
    { Range-checked against the member's own type: 300 is not a Byte, and
      Cast used to make one of it. }
    TXmlKind.IntValue, TXmlKind.Int64Value:
      begin
        if not TSerializationTypes.TryIntegerFromText(APlan.TypeInfo,
             Trim(S), Result) then
          raise EXmlInputError.CreateFmt('"%s" is not a %s.',
            [AText, UTF8ToString(APlan.TypeInfo.Name)]);
        Exit;
      end;
    TXmlKind.FloatValue:
      begin
        if not TryXsdFloat(Trim(S), D) then
          raise EXmlInputError.CreateFmt('"%s" is not a number.', [AText]);
        { Into the member's own width, checked: a Single does not become
          infinity for a number it cannot hold. }
        if not TSerializationTypes.TryFloatFromDouble(APlan.TypeInfo, D,
             Result, Why) then
          raise EXmlInputError.CreateFmt('%s: %s.',
            [UTF8ToString(APlan.TypeInfo.Name), Why]);
        Exit;
      end;
    TXmlKind.CurrencyValue:
      begin
        if not TryStrToCurr(Trim(S), C, TFormatSettings.Invariant) then
          raise EXmlInputError.CreateFmt('"%s" is not a currency value.', [AText]);
        Exit(TValue.From<Currency>(C));
      end;
    { Into the member's own code page, refusing text it cannot hold rather
      than writing a '?' for it. }
    TXmlKind.StrValue:
      begin
        if not TSerializationTypes.TryStringFromText(APlan.TypeInfo, S,
             Result, Why) then
          raise EXmlInputError.Create(Why + '.');
        Exit;
      end;
    TXmlKind.DateValue, TXmlKind.TimeValue, TXmlKind.DateTimeValue:
      begin
        D := TextToDate(APlan, S);
        TValue.Make(@D, APlan.TypeInfo, Result);
        Exit;
      end;
    TXmlKind.GuidValue:
      begin
        S := Trim(S);
        if (S <> '') and (S[1] <> '{') then S := '{' + S + '}';
        try
          G := StringToGUID(S);
        except
          raise EXmlInputError.CreateFmt('"%s" is not a GUID.', [AText]);
        end;
        Exit(TValue.From<TGUID>(G));
      end;
    TXmlKind.BytesValue:
      Exit(TValue.From<TBytes>(
        TNetEncoding.Base64.DecodeStringToBytes(Trim(S))));
    TXmlKind.EnumValue:
      begin
        I64 := TextToEnumOrdinal(APlan.TypeInfo, S, APlan.EnumMapping);
        Result := TValue.FromOrdinal(APlan.TypeInfo, I64);
        Exit;
      end;
    TXmlKind.SetValue:
      Exit(TextToSet(APlan, S));
    TXmlKind.NullableValue:
      begin
        Inner := TextToSimple(APlan.Inner, S);
        TValue.Make(nil, APlan.TypeInfo, Result);
        APlan.NullableAccess.SetValue(Result.GetReferenceToRawData, Inner);
        Exit;
      end;
  end;
  raise EXmlInternalError.CreateFmt(
    '%s has no single text form.', [UTF8ToString(APlan.TypeInfo.Name)]);
end;

{ ------------------------------------------------------------- writing --- }

class procedure TXmlEngine.WriteContainerItems(APlan: TXmlMemberPlan;
  const AValue: TValue; AParent: TXmlElement;
  const AItemName, ANamespaceUri: string);
var
  Items: TValue;
  I: Integer;
  Child: TXmlElement;
  Pair, K, V: TValue;
  Obj: TObject;
begin
  case APlan.Kind of
    { An array counts one level, like every composite the writer descends
      into: a record that holds an array of itself nests without any object
      in it, and it ran the stack out. }
    TXmlKind.ArrayValue:
      begin
        TSerializationGraphGuard.EnterLevel;
        try
          for I := 0 to Integer(AValue.GetArrayLength - 1) do
          begin
            Child := AParent.AddChild(AItemName, ANamespaceUri);
            WriteValue(APlan.Item, AValue.GetArrayElement(I), Child,
              APlan.Item.ItemName, ANamespaceUri);
          end;
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
      end;

    { A list or a dictionary is an object: its one level is the guard's
      Enter, which also makes a container that holds itself a cycle rather
      than a stack overflow. }
    TXmlKind.ListValue:
      begin
        Obj := AValue.AsObject;
        if Obj = nil then Exit;
        if not TSerializationGraphGuard.Enter(Obj) then
          raise EXmlError.CreateFmt(
            '%s is already being written further up the graph: it is a ' +
            'cycle, and XML has no back-reference. Break the cycle, or ' +
            'register an XML type serializer that writes a key instead.',
            [Obj.ClassName]);
        try
          Items := TSerializationTypes.ListElements(Obj, APlan.ContainerToArray);
          for I := 0 to Integer(Items.GetArrayLength - 1) do
          begin
            Child := AParent.AddChild(AItemName, ANamespaceUri);
            WriteValue(APlan.Item, Items.GetArrayElement(I), Child,
              APlan.Item.ItemName, ANamespaceUri);
          end;
        finally
          TSerializationGraphGuard.Leave(Obj);
        end;
      end;

    TXmlKind.DictionaryValue:
      begin
        Obj := AValue.AsObject;
        if Obj = nil then Exit;
        if not TSerializationGraphGuard.Enter(Obj) then
          raise EXmlError.CreateFmt(
            '%s is already being written further up the graph: it is a ' +
            'cycle, and XML has no back-reference. Break the cycle, or ' +
            'register an XML type serializer that writes a key instead.',
            [Obj.ClassName]);
        try
          Items := APlan.ContainerToArray.Invoke(Obj, []);
          for I := 0 to Integer(Items.GetArrayLength - 1) do
          begin
            Pair := Items.GetArrayElement(I);
            K := APlan.PairKeyField.GetValue(Pair.GetReferenceToRawData);
            V := APlan.PairValueField.GetValue(Pair.GetReferenceToRawData);
            Child := AParent.AddChild(AItemName, ANamespaceUri);
            { The key is an attribute, so an entry stays one element whatever
              its value turns out to be. }
            Child.SetAttribute('key', SimpleToText(APlan.Key, K));
            WriteValue(APlan.Value, V, Child, APlan.Value.ItemName,
              ANamespaceUri);
          end;
        finally
          TSerializationGraphGuard.Leave(Obj);
        end;
      end;
  end;
end;

class procedure TXmlEngine.WriteValue(APlan: TXmlMemberPlan;
  const AValue: TValue; AElement: TXmlElement;
  const AItemName, ANamespaceUri: string);
var
  Obj: TObject;
  Raw: Pointer;
begin
  case APlan.Kind of
    TXmlKind.CustomSerializer:
      APlan.Serializer.Serialize(AValue, AElement);

    TXmlKind.ObjectValue:
      begin
        Obj := AValue.AsObject;
        if Obj = nil then Exit;
        if not TSerializationGraphGuard.Enter(Obj) then
          raise EXmlError.CreateFmt(
            '%s is already being written further up the graph: it is a ' +
            'cycle, and XML has no back-reference. Break the cycle, or ' +
            'register an XML type serializer that writes a key instead.',
            [Obj.ClassName]);
        try
          { The body addresses its instance as an untyped pointer. }
          {$WARN UNSAFE_CAST OFF}
          WriteObjectBody(APlan.BoundPlan, Pointer(Obj), AElement);
          {$WARN UNSAFE_CAST ON}
        finally
          TSerializationGraphGuard.Leave(Obj);
        end;
      end;

    { One level: a record has no identity for the cycle check, but it nests
      like anything else. A TNullable<record> payload arrives here too. }
    TXmlKind.RecordValue:
      begin
        Raw := AValue.GetReferenceToRawData;
        TSerializationGraphGuard.EnterLevel;
        try
          WriteObjectBody(APlan.BoundPlan, Raw, AElement);
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
      end;

    TXmlKind.ListValue, TXmlKind.ArrayValue, TXmlKind.DictionaryValue:
      WriteContainerItems(APlan, AValue, AElement, AItemName, ANamespaceUri);

    TXmlKind.NullableValue:
      begin
        Raw := AValue.GetReferenceToRawData;
        { An element is already there - an array item - so it is marked
          xsi:nil. Left empty, it read back as the empty string, which an
          integer is not. A MEMBER without a value never reaches this: it is
          left out. }
        if not APlan.NullableAccess.HasValue(Raw) then
        begin
          AElement.SetAttribute('nil', 'true', XSI_NAMESPACE);
          Exit;
        end;
        WriteValue(APlan.Inner, APlan.NullableAccess.GetValue(Raw), AElement,
          AItemName, ANamespaceUri);
      end;
  else
    AElement.Text := SimpleToText(APlan, AValue);
    AElement.HasText := True;
  end;
end;

class procedure TXmlEngine.WriteObjectBody(APlan: TXmlTypePlan;
  AInstance: Pointer; AElement: TXmlElement);
var
  FP: TXmlFieldPlan;
  V: TValue;
  Child: TXmlElement;
  Raw: Pointer;
begin
  for FP in APlan.Fields do
  begin
    V := ReadMember(FP, AInstance);

    { An empty nullable is absent, not empty: XML has no null, and writing
      one would make "no value" and "the empty string" the same document. }
    if FP.Member.Kind = TXmlKind.NullableValue then
    begin
      Raw := V.GetReferenceToRawData;
      if not FP.Member.NullableAccess.HasValue(Raw) then Continue;
    end;

    if FP.IsAttribute then
    begin
      AElement.SetAttribute(FP.Name, SimpleToText(FP.Member, V));
      Continue;
    end;

    if FP.IsText then
    begin
      AElement.Text := SimpleToText(FP.Member, V);
      AElement.HasText := True;
      Continue;
    end;

    case FP.Member.Kind of
      TXmlKind.ObjectValue, TXmlKind.ListValue, TXmlKind.DictionaryValue:
        if V.AsObject = nil then Continue;
    end;

    if FP.Member.IsContainer then
    begin
      if FP.Wrapped then
      begin
        Child := AElement.AddChild(FP.WrapperName, FP.NamespaceUri);
        WriteContainerItems(FP.Member, V, Child, FP.ItemName, FP.NamespaceUri);
      end
      else
        WriteContainerItems(FP.Member, V, AElement, FP.ItemName,
          FP.NamespaceUri);
      Continue;
    end;

    Child := AElement.AddChild(FP.Name, FP.NamespaceUri);
    WriteValue(FP.Member, V, Child, FP.ItemName, FP.NamespaceUri);
  end;
end;

{ ------------------------------------------------------------- reading --- }

class function TXmlEngine.IsNilElement(AElement: TXmlElement): Boolean;
var
  S: string;
begin
  Result := AElement.TryGetAttribute('nil', S, XSI_NAMESPACE) and
    (SameText(Trim(S), 'true') or (Trim(S) = '1'));
end;

{ The item elements of a container's element - and only them. An element
  that is not an item is a document of another shape, a map where a list
  belongs or a list where a map belongs, and reading just the items it
  happened to hold gave an EMPTY container, clearing the caller's on the
  way. Text where no item is - <Items>5</Items> - is a scalar where the
  container belongs. Both are refused here, before anything is constructed
  or cleared. }
class function TXmlEngine.ContainerItemsOf(AElement: TXmlElement;
  const AItemName, ANamespaceUri: string): TArray<TXmlElement>;
var
  I: Integer;
  Child: TXmlElement;
  Where: string;
begin
  for I := 0 to AElement.ChildCount - 1 do
  begin
    Child := AElement.Children[I];
    if Child.Name <> AItemName then
      raise EXmlInputError.CreateFmt(
        '<%s> holds a <%s> element where only <%s> items belong.',
        [AElement.Name, Child.Name, AItemName]);
    if Child.NamespaceUri <> ANamespaceUri then
    begin
      if ANamespaceUri = '' then Where := 'in no namespace'
      else Where := 'in "' + ANamespaceUri + '"';
      raise EXmlInputError.CreateFmt(
        '<%s> holds a <%s> in the namespace "%s", and its items are %s.',
        [AElement.Name, Child.Name, Child.NamespaceUri, Where]);
    end;
  end;
  Result := AElement.ChildrenNamed(AItemName, ANamespaceUri);
  if (Length(Result) = 0) and (Trim(AElement.Text) <> '') then
    raise EXmlInputError.CreateFmt(
      '<%s> holds the text "%s" where a list of <%s> elements belongs.',
      [AElement.Name, Trim(AElement.Text), AItemName]);
end;

class function TXmlEngine.ReadContainerItems(APlan: TXmlMemberPlan;
  const AItems: TArray<TXmlElement>; const AExisting: TValue;
  const ANamespaceUri: string): TValue;
var
  Container: TObject;
  Built: Boolean;
  I: Integer;
  ElemPlan: TXmlMemberPlan;
  Arr, Keys: array of TValue;
  KeyText: string;
begin
  { An array's elements are collected before it is assembled, so on a
    failure the ones already read are this read's alone, and are freed. }
  if (APlan.Kind = TXmlKind.ArrayValue) and (APlan.TypeInfo.Kind = tkArray) then
  begin
    TValue.Make(nil, APlan.TypeInfo, Result);
    if Length(AItems) <> Result.GetArrayLength then
      raise EXmlInputError.CreateFmt(
        '%s holds exactly %d elements, and the document has %d.',
        [UTF8ToString(APlan.TypeInfo.Name), Result.GetArrayLength, Length(AItems)]);
    SetLength(Arr, Length(AItems));
    try
      for I := 0 to Integer(High(AItems)) do
      begin
        Arr[I] := ReadValue(APlan.Item, AItems[I], TValue.Empty,
          APlan.Item.ItemName, ANamespaceUri);
        Result.SetArrayElement(I, Arr[I]);
      end;
    except
      TSerializationOwnership.ReleaseBuiltElements(APlan.Item.TypeInfo, Arr);
      raise;
    end;
    Exit;
  end;
  if APlan.Kind = TXmlKind.ArrayValue then
  begin
    SetLength(Arr, Length(AItems));
    try
      for I := 0 to Integer(High(AItems)) do
        Arr[I] := ReadValue(APlan.Item, AItems[I], TValue.Empty,
          APlan.Item.ItemName, ANamespaceUri);
    except
      TSerializationOwnership.ReleaseBuiltElements(APlan.Item.TypeInfo, Arr);
      raise;
    end;
    Result := TValue.FromArray(APlan.TypeInfo, Arr);
    Exit;
  end;

  { Every entry's key and every element is read before anything is
    constructed or cleared: an entry with no key, or a value its type cannot
    hold, is found out while the caller's container is still as it was.
    Finding it out half way through left the container emptied. }
  if APlan.Kind = TXmlKind.DictionaryValue then
  begin
    SetLength(Keys, Length(AItems));
    for I := 0 to Integer(High(AItems)) do
    begin
      if not AItems[I].TryGetAttribute('key', KeyText) then
        raise EXmlInputError.CreateFmt(
          'A <%s> entry of a dictionary has no key attribute.',
          [AItems[I].Name]);
      Keys[I] := TextToSimple(APlan.Key, KeyText);
    end;
    ElemPlan := APlan.Value;
  end
  else
    ElemPlan := APlan.Item;
  SetLength(Arr, Length(AItems));
  try
    for I := 0 to Integer(High(AItems)) do
      Arr[I] := ReadValue(ElemPlan, AItems[I], TValue.Empty,
        ElemPlan.ItemName, ANamespaceUri);
  except
    TSerializationOwnership.ReleaseBuiltElements(ElemPlan.TypeInfo, Arr);
    raise;
  end;

  { A container that is already there is refilled, never replaced: whatever
    owns its elements keeps owning them, and Clear on an owning container is
    what disposes of them. }
  Container := nil;
  if not AExisting.IsEmpty then Container := AExisting.AsObject;
  Built := Container = nil;
  try
    if Built then Container := NewContainer(APlan)
    else if APlan.ContainerClear <> nil then
      APlan.ContainerClear.Invoke(Container, []);
  except
    TSerializationOwnership.ReleaseBuiltElements(ElemPlan.TypeInfo, Arr);
    raise;
  end;

  I := 0;
  try
    try
      while I <= High(Arr) do
      begin
        if APlan.Kind = TXmlKind.ListValue then
          APlan.ContainerAdd.Invoke(Container, [Arr[I]])
        else if APlan.HasDictionaryAccess then
          { A repeated key releases what this read built for the earlier
            occurrence; AddOrSetValue on a non-owning dictionary orphaned
            it. }
          TSerializationOwnership.AddOrSetBuilt(APlan.DictionaryAccess,
            Container, Keys[I], Arr[I])
        else
          APlan.ContainerAdd.Invoke(Container, [Keys[I], Arr[I]]);
        Inc(I);
      end;
    except
      on E: Exception do
      begin
        { The element refused and the ones after it were never added, so
          nothing else will free them. And what the container itself
          refuses - a sorted TStringList with dupError, say - is the
          document's fault, not an RTL exception for the caller to meet. }
        TSerializationOwnership.ReleaseBuiltElements(ElemPlan.TypeInfo,
          Copy(Arr, I, Length(Arr) - I));
        if string(E.UnitName).StartsWith('PascalForge.') then raise;
        raise EXmlInputError.CreateFmt(
          'The %s refused an element the document holds: %s',
          [Container.ClassName, E.Message]);
      end;
    end;
  except
    { Only an instance built here is destroyed here - together with the
      elements this read put in it, unless it owns them: a non-owning
      TList<TObject> freed alone orphaned every one. }
    if Built then TSerializationOwnership.ReleaseBuiltContainer(Container);
    raise;
  end;
  TValue.Make(@Container, APlan.TypeInfo, Result);
end;

class function TXmlEngine.ReadValue(APlan: TXmlMemberPlan;
  AElement: TXmlElement; const AExisting: TValue;
  const AItemName, ANamespaceUri: string): TValue;
var
  Obj: TObject;
  Existing: TObject;
  Built: Boolean;
  Inner: TValue;
begin
  case APlan.Kind of
    TXmlKind.CustomSerializer:
      Exit(APlan.Serializer.Deserialize(AElement, APlan.TypeInfo, AExisting));

    TXmlKind.ObjectValue:
      begin
        Existing := nil;
        if not AExisting.IsEmpty then Existing := AExisting.AsObject;
        Built := False;
        if (Existing = nil) or
           not Existing.InheritsFrom(APlan.BoundPlan.ClassType) then
        begin
          Obj := NewInstanceOf(APlan.BoundPlan);
          Built := True;
        end
        else
          Obj := Existing;
        try
          { The body addresses its instance as an untyped pointer. }
          {$WARN UNSAFE_CAST OFF}
          ReadObjectBody(APlan.BoundPlan, Pointer(Obj), AElement);
          {$WARN UNSAFE_CAST ON}
        except
          if Built then Obj.Free;
          raise;
        end;
        TValue.Make(@Obj, APlan.TypeInfo, Result);
        Exit;
      end;

    TXmlKind.RecordValue:
      begin
        { Merged into what is already there, so a member the document does
          not mention keeps its value - in a copy of its own: a TValue
          assignment shares the record's storage, and a failure below needs
          the value as it was. }
        if AExisting.IsEmpty then TValue.Make(nil, APlan.TypeInfo, Result)
        else TValue.Make(AExisting.GetReferenceToRawData, APlan.TypeInfo,
          Result);
        try
          ReadObjectBody(APlan.BoundPlan, Result.GetReferenceToRawData,
            AElement);
        except
          { The record reaches its owner only on success, so the objects
            this read built into it would be lost with it. The ones that
            were there before are the owner's. }
          TSerializationOwnership.ReleaseBuilt(APlan.TypeInfo, Result,
            AExisting);
          raise;
        end;
        Exit;
      end;

    TXmlKind.ListValue, TXmlKind.ArrayValue, TXmlKind.DictionaryValue:
      Exit(ReadContainerItems(APlan,
        ContainerItemsOf(AElement, AItemName, ANamespaceUri), AExisting,
        ANamespaceUri));

    TXmlKind.NullableValue:
      begin
        TValue.Make(nil, APlan.TypeInfo, Result);
        if IsNilElement(AElement) then Exit;
        Inner := ReadValue(APlan.Inner, AElement, TValue.Empty, AItemName,
          ANamespaceUri);
        APlan.NullableAccess.SetValue(Result.GetReferenceToRawData, Inner);
        Exit;
      end;
  end;
  Result := TextToSimple(APlan, AElement.Text);
end;

class procedure TXmlEngine.ReadObjectBody(APlan: TXmlTypePlan;
  AInstance: Pointer; AElement: TXmlElement);
var
  FP: TXmlFieldPlan;
  Child: TXmlElement;
  Items: TArray<TXmlElement>;
  Text, AttrText: string;
  Existing, NewValue: TValue;
begin
  for FP in APlan.Fields do
  begin
    if FP.IsAttribute then
    begin
      if AElement.TryGetAttribute(FP.Name, AttrText) and FP.Writable then
        StoreMember(FP, AInstance, TextToSimple(FP.Member, AttrText));
      Continue;
    end;

    if FP.IsText then
    begin
      if AElement.HasText and FP.Writable then
      begin
        Text := AElement.Text;
        StoreMember(FP, AInstance, TextToSimple(FP.Member, Text));
      end;
      Continue;
    end;

    if FP.Member.IsContainer then
    begin
      if FP.Wrapped then
      begin
        Child := AElement.FindChild(FP.WrapperName, FP.NamespaceUri);
        if Child = nil then Continue;
        { A wrapper holds item elements and nothing else: text or another
          element in it is a document of another shape, refused before the
          member's container is touched. }
        Items := ContainerItemsOf(Child, FP.ItemName, FP.NamespaceUri);
      end
      else
      begin
        Items := AElement.ChildrenNamed(FP.ItemName, FP.NamespaceUri);
        if Length(Items) = 0 then Continue;
      end;
      Existing := ReadMember(FP, AInstance);
      NewValue := ReadContainerItems(FP.Member, Items, Existing,
        FP.NamespaceUri);
      { A read-only member keeps the container it has, refilled in place.
        Anything else the read produced for it - a container where it had
        none, a new array - cannot be assigned, so it is released rather
        than orphaned. }
      if FP.Writable then StoreMember(FP, AInstance, NewValue)
      else TSerializationOwnership.ReleaseBuilt(FP.Member.TypeInfo, NewValue,
        Existing);
      Continue;
    end;

    Child := AElement.FindChild(FP.Name, FP.NamespaceUri);
    if Child = nil then Continue;

    if IsNilElement(Child) then
    begin
      { xsi:nil DETACHES; it never destroys. The serializer cannot prove it
        owns what a member points at, so it does not dispose of it - the same
        rule every format here follows. }
      if not FP.Writable then Continue;
      case FP.Member.Kind of
        TXmlKind.ObjectValue, TXmlKind.ListValue, TXmlKind.DictionaryValue:
          begin
            TValue.Make(nil, FP.Member.TypeInfo, NewValue);
            StoreMember(FP, AInstance, NewValue);
          end;
        TXmlKind.NullableValue:
          begin
            TValue.Make(nil, FP.Member.TypeInfo, NewValue);
            StoreMember(FP, AInstance, NewValue);
          end;
      end;
      Continue;
    end;

    Existing := ReadMember(FP, AInstance);
    NewValue := ReadValue(FP.Member, Child, Existing, FP.ItemName,
      FP.NamespaceUri);
    { A read-only member that had no instance got one built for it, which
      nothing can hold: it is released, not orphaned. An instance filled in
      place is the member's own and stays. }
    if FP.Writable then StoreMember(FP, AInstance, NewValue)
    else TSerializationOwnership.ReleaseBuilt(FP.Member.TypeInfo, NewValue,
      Existing);
  end;
end;

{ -------------------------------------------------------------- document --- }

class function TXmlEngine.ParseDocument(const AXml: string): TXmlElement;
begin
  Result := TXmlReader.Parse(AXml);
end;

class function TXmlEngine.WriteDocument(AElement: TXmlElement;
  AIndent, ADeclaration: Boolean): string;
var
  SB: TStringBuilder;
  Map: TXmlPrefixMap;
begin
  SB := TStringBuilder.Create;
  Map := TXmlPrefixMap.Create;
  try
    Map.Collect(AElement, True);
    if ADeclaration then
      SB.Append('<?xml version="1.0" encoding="UTF-8"?>');
    if ADeclaration and AIndent then SB.Append(sLineBreak);
    WriteElementTo(SB, AElement, Map, AIndent, 0, True);
    Result := SB.ToString;
  finally
    Map.Free;
    SB.Free;
  end;
end;

{ ------------------------------------------------------------------ root --- }

class function TXmlEngine.SerializeRootToElement(ATypeInfo: PTypeInfo;
  const AValue: TValue; const ARootName: string): TXmlElement;
var
  Plan: TXmlMemberPlan;
  RootName, Ns: string;
  Mark: Integer;
begin
  FLock.Enter;
  try
    Plan := GetRootPlan(ATypeInfo);
    FFrozen := True;
  finally
    FLock.Leave;
  end;

  RootName := ARootName;
  Ns := '';
  if (Plan.Kind in [TXmlKind.ObjectValue, TXmlKind.RecordValue]) and
     (Plan.BoundPlan <> nil) then
  begin
    if RootName = '' then RootName := Plan.BoundPlan.RootName;
    Ns := Plan.BoundPlan.NamespaceUri;
  end;
  if RootName = '' then RootName := DefaultRootNameFor(ATypeInfo);

  { The level this write started from is restored whatever happens, so a
    failure deep in one write cannot leave the next one on this thread
    starting part way down. }
  Mark := TSerializationGraphGuard.Level;
  Result := TXmlElement.Create(RootName, Ns);
  try
    try
      if (Plan.Kind = TXmlKind.ObjectValue) and (AValue.AsObject = nil) then
        Result.SetAttribute('nil', 'true', XSI_NAMESPACE)
      else
        WriteValue(Plan, AValue, Result, Plan.ItemName, Ns);
    finally
      TSerializationGraphGuard.RestoreLevel(Mark);
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TXmlEngine.SerializeRoot(ATypeInfo: PTypeInfo;
  const AValue: TValue; const ARootName: string;
  AIndent, ADeclaration: Boolean): string;
var
  Root: TXmlElement;
begin
  Root := SerializeRootToElement(ATypeInfo, AValue, ARootName);
  try
    Result := WriteDocument(Root, AIndent, ADeclaration);
  finally
    Root.Free;
  end;
end;

class function TXmlEngine.DeserializeRootFromElement(ATypeInfo: PTypeInfo;
  AElement: TXmlElement; const AExisting: TValue): TValue;
var
  Plan: TXmlMemberPlan;
  Ns: string;
begin
  FLock.Enter;
  try
    Plan := GetRootPlan(ATypeInfo);
    FFrozen := True;
  finally
    FLock.Leave;
  end;
  Ns := '';
  if (Plan.Kind in [TXmlKind.ObjectValue, TXmlKind.RecordValue]) and
     (Plan.BoundPlan <> nil) then
    Ns := Plan.BoundPlan.NamespaceUri;
  Result := ReadValue(Plan, AElement, AExisting, Plan.ItemName, Ns);
end;

class function TXmlEngine.DeserializeRoot(ATypeInfo: PTypeInfo;
  const AXml: string; const AExisting: TValue): TValue;
var
  Root: TXmlElement;
begin
  Root := ParseDocument(AXml);
  try
    Result := DeserializeRootFromElement(ATypeInfo, Root, AExisting);
  finally
    Root.Free;
  end;
end;

{ ------------------------------------------------------- cross-format --- }

class function TXmlEngine.FromPayload(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload; AFrom: TSerializationFormat;
  const ARootName: string; AIndent, ADeclaration: Boolean): string;
var
  V: TValue;
begin
  { Contract-aware: the source reads T by ITS rules, XML writes T by its own.
    The source format is reached through the registry, so this unit has no
    compile-time knowledge that it exists. }
  V := TSerializationFormats.Get(AFrom).DeserializeTyped(ATypeInfo, ASource);
  try
    Result := SerializeRoot(ATypeInfo, V, ARootName, AIndent, ADeclaration);
  finally
    { The intermediate belongs to this call. }
    TSerializationOwnership.Release(ATypeInfo, V);
  end;
end;

class function TXmlEngine.FromPayloadStructural(
  const ASource: TSerializationPayload; AFrom: TSerializationFormat;
  AIndent, ADeclaration: Boolean;
  AProfile: TStructuralConversionProfile): string;
var
  Tree: TDynamicValue;
  Root: TXmlElement;
  Options: TStructuralConversionOptions;
begin
  Options := TStructuralConversionOptions.FromProfile(AProfile).WithSource(AFrom)
    .WithDestination(TSerializationFormat.Xml);
  Tree := TSerializationFormats.Require(AFrom,
    TSerializationFormatCapability.StructuralParse).ToDynamic(ASource, Options);
  try
    Root := DynamicToElement(Tree, 'Value', Options, TStructuralPath.Root);
    try
      Result := WriteDocument(Root, AIndent, ADeclaration);
    finally
      Root.Free;
    end;
  finally
    Tree.Free;
  end;
end;

{ ------------------------------------------------------ the dynamic tree --- }

{ ---------------------------------------------------------------------------
  THE W3C MAPPING, READING

  A document is in the W3C JSON/XML vocabulary when its root element is in
  that namespace. That test is safe to make unconditionally, unlike the
  Extended JSON one on the JSON side: the vocabulary has a namespace of the
  W3C's own, so an ordinary document cannot wander into it by accident, and
  an ordinary document that DOES declare that namespace is saying what it
  is.
  --------------------------------------------------------------------------- }

function IsW3CJsonElement(AElement: TXmlElement): Boolean;
begin
  Result := (AElement <> nil) and (AElement.NamespaceUri = W3C_JSON_NAMESPACE);
end;

{ The JSON escape sequences the mapping uses for text XML cannot hold. Only
  the ones the specification lists: reverse solidus, and \uXXXX. }
function DecodeJsonEscapes(const AText: string): string;
var
  I, Code: Integer;
  SB: TStringBuilder;
  Hex: string;
begin
  if not AText.Contains('\') then Exit(AText);
  SB := TStringBuilder.Create;
  try
    I := 1;
    while I <= Length(AText) do
    begin
      if (AText[I] = '\') and (I < Length(AText)) then
      begin
        Inc(I);
        case AText[I] of
          'b': SB.Append(#8);
          'f': SB.Append(#12);
          'n': SB.Append(#10);
          'r': SB.Append(#13);
          't': SB.Append(#9);
          '/': SB.Append('/');
          '"': SB.Append('"');
          '\': SB.Append('\');
          'u':
            begin
              Hex := Copy(AText, I + 1, 4);
              if (Length(Hex) = 4) and TryStrToInt('$' + Hex, Code) then
              begin
                SB.Append(Char(Code));
                Inc(I, 4);
              end
              else
                SB.Append('\u');
            end;
        else
          SB.Append('\').Append(AText[I]);
        end;
      end
      else
        SB.Append(AText[I]);
      Inc(I);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ True when ANY character of AText cannot appear in XML 1.0 content, in
  which case the mapping requires the escaped form. }
function NeedsJsonEscaping(const AText: string): Boolean;
var
  I: Integer;
  C: Word;
begin
  for I := 1 to Length(AText) do
  begin
    C := Word(AText[I]);
    if AText[I] = '\' then Exit(True);
    if (C < $20) and (C <> 9) and (C <> 10) and (C <> 13) then Exit(True);
    if (C >= $D800) and (C <= $DFFF) then
    begin
      { A well-formed surrogate PAIR is ordinary text; a lone one is not. }
      if (C >= $DC00) or (I = Length(AText)) then Exit(True);
      if (Word(AText[I + 1]) < $DC00) or (Word(AText[I + 1]) > $DFFF) then
        Exit(True);
    end;
  end;
  Result := False;
end;

function EncodeJsonEscapes(const AText: string): string;
var
  I: Integer;
  C: Word;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    for I := 1 to Length(AText) do
    begin
      C := Word(AText[I]);
      if AText[I] = '\' then SB.Append('\\')
      else if (C < $20) or ((C >= $D800) and (C <= $DFFF)) then
      begin
        case C of
          8:  SB.Append('\b');
          9:  SB.Append('\t');
          10: SB.Append('\n');
          12: SB.Append('\f');
          13: SB.Append('\r');
        else
          SB.Append('\u').Append(IntToHex(C, 4));
        end;
      end
      else
        SB.Append(AText[I]);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ One element of the W3C vocabulary, as the dynamic value it denotes. }
function W3CToDynamic(AElement: TXmlElement): TDynamicValue;
var
  I: Integer;
  Local, Text, Key: string;
  I64: Int64;
  F: Double;
  Escaped: string;

  function ContentOf: string;
  begin
    Result := AElement.Text;
    if AElement.TryGetAttribute(W3C_ESCAPED, Escaped) and
       SameText(Escaped, 'true') then
      Result := DecodeJsonEscapes(Result);
  end;

  function KeyOf(AChild: TXmlElement): string;
  var
    Flag: string;
  begin
    if not AChild.TryGetAttribute(W3C_KEY, Result) then
      raise EXmlInputError.CreateFmt(
        'A <%s> inside a <map> has no key attribute, so the mapping cannot ' +
        'say what member it is.', [AChild.Name]);
    if AChild.TryGetAttribute(W3C_ESCAPED_KEY, Flag) and
       SameText(Flag, 'true') then
      Result := DecodeJsonEscapes(Result);
  end;

begin
  Local := AElement.Name;

  if Local = W3C_NULL then Exit(TDynamicValue.NewNull);

  if Local = W3C_BOOLEAN then
    Exit(TDynamicValue.NewBool(SameText(Trim(AElement.Text), 'true') or
                               (Trim(AElement.Text) = '1')));

  if Local = W3C_NUMBER then
  begin
    Text := Trim(AElement.Text);
    { An integral number stays integral, the same rule the JSON reader
      applies, so a value does not change shape by passing through XML. }
    if TryStrToInt64(Text, I64) then Exit(TDynamicValue.NewInt(I64));
    if not TStructuralText.TryParseFloat(Text, F) then
      raise EXmlInputError.CreateFmt(
        'A <number> in the W3C JSON vocabulary contains "%s", which is not ' +
        'a number.', [Text]);
    Exit(TDynamicValue.NewFloat(F));
  end;

  if Local = W3C_STRING then Exit(TDynamicValue.NewStr(ContentOf));

  if Local = W3C_ARRAY then
  begin
    Result := TDynamicValue.NewArray;
    try
      for I := 0 to AElement.ChildCount - 1 do
        Result.AsArray.Adopt(W3CToDynamic(AElement.Children[I]));
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  if Local = W3C_MAP then
  begin
    Result := TDynamicValue.NewObject;
    try
      for I := 0 to AElement.ChildCount - 1 do
      begin
        Key := KeyOf(AElement.Children[I]);
        Result.AsObject.Adopt(Key, W3CToDynamic(AElement.Children[I]));
      end;
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  raise EXmlInputError.CreateFmt(
    'Element <%s> is in the W3C JSON namespace but is not one of its six ' +
    'element names.', [AElement.Name]);
end;

{ Is this member name one the '@attribute' / '#text' projection claims?  The
  convention only applies to a STRING value, because an XML attribute holds
  text and nothing else - an integer written as an attribute would come back
  as an integer-looking string, which is precisely the kind of quiet type
  change this whole area is about. }
function IsAttributeMember(const AName: string; AChild: TDynamicValue): Boolean;
begin
  Result := (Length(AName) > 1) and (AName[1] = '@') and
            (AChild.Kind = TDynamicKind.Str) and
            IsValidXmlName(AName.Substring(1));
end;

function IsTextMember(const AName: string; AChild: TDynamicValue): Boolean;
begin
  Result := (AName = '#text') and (AChild.Kind = TDynamicKind.Str);
end;

class function TXmlEngine.ElementToDynamic(AElement: TXmlElement): TDynamicValue;
begin
  Result := ElementToDynamic(AElement, TStructuralConversionOptions.Default);
end;

class function TXmlEngine.ElementToDynamic(AElement: TXmlElement;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
var
  I, J: Integer;
  Obj, Arr: TDynamicValue;
  Same: TArray<TXmlElement>;
  Child: TXmlElement;
  Seen: TDictionary<string, Byte>;
  S: string;
begin
  { ---- the W3C vocabulary first ------------------------------------------

    A document in that namespace says what every one of its values is, so
    nothing here is guessed. This is checked in every profile, because the
    namespace is unambiguous: see the note by W3C_JSON_NAMESPACE. }
  if IsW3CJsonElement(AElement) then Exit(W3CToDynamic(AElement));

  { ---- the natural form --------------------------------------------------

    The documented structural convention - see docs\xml-behavior.md.

      an element with only text        -> a string
      an element with children         -> an object
      repeated children of one name    -> an array under that name
      an attribute                     -> a member named '@name'
      text alongside children          -> a member named '#text'
      a namespace URI                  -> a member named '@xmlns'
      xsi:nil="true"                   -> null

    It is lossy and says so: prefixes, ordering between differently-named
    siblings, and the difference between one repeated element and an array of
    one are not recoverable, and every value arrives as a string because that
    is all XML text is. The W3C mapping above exists for when that matters;
    contract-aware conversion is better still.

    ELEMENT NAMES ARE NOT DECODED. This library WRITES names through
    EncodeXmlName, which is compatible with XmlConvert.EncodeName, so a
    member called "first name" becomes <first_x0020_name>. It does not
    decode on the way back, because the XML it is reading is somebody
    else's: an element genuinely called <_x0041_> is a member called
    "_x0041_", not a member called "A". Decoding unconditionally would
    rewrite foreign documents on the strength of a convention they never
    agreed to. }
  if IsNilElement(AElement) then Exit(TDynamicValue.NewNull);

  if (AElement.ChildCount = 0) and (AElement.AttributeCount = 0) and
     (AElement.NamespaceUri = '') then
    Exit(TDynamicValue.NewStr(AElement.Text));

  Obj := TDynamicValue.NewObject;
  try
    if AElement.NamespaceUri <> '' then
      Obj.AsObject.Adopt('@xmlns', TDynamicValue.NewStr(AElement.NamespaceUri));
    for I := 0 to AElement.AttributeCount - 1 do
      Obj.AsObject.Adopt('@' + AElement.Attributes[I].Name,
        TDynamicValue.NewStr(AElement.Attributes[I].Value));
    if AElement.HasText and (Trim(AElement.Text) <> '') and
       (AElement.ChildCount > 0) then
      Obj.AsObject.Adopt('#text', TDynamicValue.NewStr(AElement.Text))
    else if (AElement.ChildCount = 0) and AElement.HasText then
      Obj.AsObject.Adopt('#text', TDynamicValue.NewStr(AElement.Text));

    Seen := TDictionary<string, Byte>.Create;
    try
      for I := 0 to AElement.ChildCount - 1 do
      begin
        Child := AElement.Children[I];
        if Seen.ContainsKey(Child.Name) then Continue;
        Seen.Add(Child.Name, 0);
        Same := AElement.ChildrenNamed(Child.Name, Child.NamespaceUri);
        S := Child.Name;
        if Length(Same) = 1 then
          Obj.AsObject.Adopt(S, ElementToDynamic(Same[0], AOptions))
        else
        begin
          Arr := TDynamicValue.NewArray;
          Obj.AsObject.Adopt(S, Arr);
          for J := 0 to Integer(High(Same)) do Arr.AsArray.Adopt(ElementToDynamic(Same[J], AOptions));
        end;
      end;
    finally
      Seen.Free;
    end;
    Result := Obj;
  except
    Obj.Free;
    raise;
  end;
end;

{ The destination name for one source member, under the caller's policy. }
class function TXmlEngine.StructuralName(const AName: string;
  const AOptions: TStructuralConversionOptions; const APath: string): string;
begin
  if AOptions.NamePolicy = TStructuralNamePolicy.Error then
  begin
    { Strict does NOT encode - so a name that is already a valid XML element
      name is written verbatim, including one that looks like an encoding.
      Nothing in a strict document was encoded, so nothing can collide. }
    if not IsValidXmlName(AName) then
      raise EStructuralConversionError.CreateFor(
        TStructuralIssue.InvalidDestinationName, AOptions,
        TSerializationFormat.Xml, APath, TDynamicKind.Str,
        Format('cannot represent member "%s" directly as an XML element ' +
          'name. Use the Natural profile, which encodes it the way ' +
          'XmlConvert.EncodeName does, or the Lossless profile, which puts ' +
          'the name in a key attribute where nothing needs encoding at all',
          [AName]));
    Result := AName;
  end
  else
    Result := EncodeXmlName(AName);
end;

class procedure TXmlEngine.RefuseValue(AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions; const APath: string);
begin
  raise EStructuralConversionError.CreateFor(
    TStructuralIssue.UnsupportedValueKind, AOptions, TSerializationFormat.Xml,
    APath, AValue.Kind,
    Format('XML has no representation for %s. The Natural profile writes ' +
      'the idiomatic text form',
      [EStructuralConversionError.KindName(AValue.Kind)]));
end;

{ ---------------------------------------------------------------------------
  THE W3C MAPPING, WRITING

  Every dynamic kind JSON has maps directly. The three it does not - binary,
  a timestamp, and a source-native extended value - are not in the W3C
  mapping either, because the W3C mapping is a mapping of JSON, and JSON
  does not have them.

  Rather than invent an extension, this says so and names the route that
  does work: convert to JSON under Lossless first, which writes MongoDB
  Extended JSON, and then convert THAT to XML. Both halves are published
  standards and the composition is exact.
  --------------------------------------------------------------------------- }
function DynamicToW3C(AValue: TDynamicValue; const AKey: string;
  AHasKey: Boolean; const AOptions: TStructuralConversionOptions;
  const APath: string): TXmlElement;
var
  I: Integer;
  Local, Text: string;

  procedure NoStandard(const AWhat: string);
  begin
    raise EStructuralConversionError.CreateFor(
      TStructuralIssue.UnsupportedLosslessConversion, AOptions,
      TSerializationFormat.Xml, APath, AValue.Kind,
      Format('the W3C JSON/XML mapping is a mapping of JSON, and JSON has ' +
        'no %s. Convert to JSON under the Lossless profile first - that ' +
        'writes MongoDB Extended JSON - and convert the result to XML',
        [AWhat]));
  end;

begin
  case AValue.Kind of
    TDynamicKind.Null:  Local := W3C_NULL;
    TDynamicKind.Bool:  Local := W3C_BOOLEAN;
    TDynamicKind.Int, TDynamicKind.Float: Local := W3C_NUMBER;
    TDynamicKind.Str:   Local := W3C_STRING;
    TDynamicKind.Arr:   Local := W3C_ARRAY;
    TDynamicKind.Obj:   Local := W3C_MAP;
    TDynamicKind.Bytes: NoStandard('binary type');
    TDynamicKind.DateTime: NoStandard('timestamp type');
    TDynamicKind.Date: NoStandard('date type');
    TDynamicKind.Time: NoStandard('time type');
  else
    NoStandard(AValue.ExtendedTag);
  end;

  Result := TXmlElement.Create(Local, W3C_JSON_NAMESPACE);
  try
    if AHasKey then
    begin
      if NeedsJsonEscaping(AKey) then
      begin
        Result.SetAttribute(W3C_KEY, EncodeJsonEscapes(AKey));
        Result.SetAttribute(W3C_ESCAPED_KEY, 'true');
      end
      else
        Result.SetAttribute(W3C_KEY, AKey);
    end;

    case AValue.Kind of
      TDynamicKind.Bool:
        begin
          if AValue.AsBool then Result.Text := 'true' else Result.Text := 'false';
          Result.HasText := True;
        end;
      TDynamicKind.Int:
        begin
          Result.Text := IntToStr(AValue.AsInt);
          Result.HasText := True;
        end;
      TDynamicKind.UInt:
        begin
          Result.Text := UIntToStr(AValue.AsUInt);
          Result.HasText := True;
        end;
      TDynamicKind.Decimal:
        begin
          Result.Text := AValue.AsDecimal;
          Result.HasText := True;
        end;
      TDynamicKind.Float:
        begin
          Result.Text := XsdFloatText(AValue.AsFloat, False);
          Result.HasText := True;
        end;
      TDynamicKind.Str:
        begin
          Text := AValue.AsStr;
          if NeedsJsonEscaping(Text) then
          begin
            Result.Text := EncodeJsonEscapes(Text);
            Result.SetAttribute(W3C_ESCAPED, 'true');
          end
          else
            Result.Text := Text;
          Result.HasText := True;
        end;
      TDynamicKind.Arr:
        for I := 0 to AValue.Count - 1 do
          Result.AdoptChild(DynamicToW3C(AValue[I], '', False, AOptions,
            TStructuralPath.Index(APath, I)));
      TDynamicKind.Obj:
        for I := 0 to AValue.Count - 1 do
          Result.AdoptChild(DynamicToW3C(AValue[I], AValue.Names[I], True,
            AOptions, TStructuralPath.Member(APath, AValue.Names[I])));
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TXmlEngine.DynamicToElement(AValue: TDynamicValue;
  const AName: string): TXmlElement;
begin
  Result := DynamicToElement(AValue, AName,
    TStructuralConversionOptions.Default, TStructuralPath.Root);
end;

class function TXmlEngine.DynamicToElement(AValue: TDynamicValue;
  const AName: string; const AOptions: TStructuralConversionOptions;
  const APath: string): TXmlElement;
var
  I: Integer;
  Name, Dest, ChildPath, Text: string;
  Child: TDynamicValue;

  procedure SetText(const AText: string);
  begin
    Result.Text := AText;
    Result.HasText := True;
  end;

begin
  { Lossless is the W3C vocabulary, root and all. The caller's root name has
    no place in it: the mapping names elements after the KIND of value, and
    a map member's name lives in its key attribute. }
  if AOptions.ValuePolicy = TStructuralValuePolicy.Lossless then
    Exit(DynamicToW3C(AValue, '', False, AOptions, APath));

  Result := TXmlElement.Create(AName);
  try
    case AValue.Kind of
      TDynamicKind.Null:
        { xsi:nil is how XML has always said this. }
        Result.SetAttribute('nil', 'true', XSI_NAMESPACE);
      TDynamicKind.Bool:
        if AValue.AsBool then SetText('true') else SetText('false');
      TDynamicKind.Int:
        SetText(IntToStr(AValue.AsInt));
      TDynamicKind.UInt:
        SetText(UIntToStr(AValue.AsUInt));
      TDynamicKind.Decimal:
        SetText(AValue.AsDecimal);
      TDynamicKind.Float:
        SetText(XsdFloatText(AValue.AsFloat, False));
      TDynamicKind.Str:
        { A string stays a string. Text that happens to look like XML, like
          JSON, like base64 or like a date is escaped and written as text -
          it is NEVER parsed into child elements. }
        SetText(AValue.AsStr);
      TDynamicKind.Bytes:
        begin
          if AOptions.ValuePolicy = TStructuralValuePolicy.Error then
            RefuseValue(AValue, AOptions, APath);
          { XML has no binary type; xs:base64Binary is the convention, and it
            is applied here rather than pretended away. }
          SetText(TStructuralText.EncodeBinary(AValue.AsBytes));
        end;
      TDynamicKind.DateTime:
        begin
          if AOptions.ValuePolicy = TStructuralValuePolicy.Error then
            RefuseValue(AValue, AOptions, APath);
          SetText(TStructuralText.EncodeDateTime(AValue.AsDateTime));
        end;
      { xs:date and xs:time are the XML Schema spellings, and they are what
        the ISO reduced forms already are. XML has no in-document typing
        without a schema, so this is Natural's idiom and not a claim. }
      TDynamicKind.Date:
        begin
          if AOptions.ValuePolicy = TStructuralValuePolicy.Error then
            RefuseValue(AValue, AOptions, APath);
          SetText(TStructuralText.EncodeDate(AValue.AsDateTime));
        end;
      TDynamicKind.Time:
        begin
          if AOptions.ValuePolicy = TStructuralValuePolicy.Error then
            RefuseValue(AValue, AOptions, APath);
          SetText(TStructuralText.EncodeTime(AValue.AsDateTime));
        end;
      TDynamicKind.Extended:
        begin
          if AOptions.ValuePolicy = TStructuralValuePolicy.Error then
            RefuseValue(AValue, AOptions, APath);
          { The idiomatic text for the source type, the same text the JSON
            writer produces under Natural, so the two destinations agree. }
          if AValue.IsTagged(TDynamicTag.ObjectId) or
             AValue.IsTagged(TDynamicTag.Symbol) or
             AValue.IsTagged(TDynamicTag.JavaScript) then
            SetText(AValue.ExtendedValue.AsStr)
          else if AValue.IsTagged(TDynamicTag.Decimal128) then
          begin
            if not TDecimal128.TryToText(AValue.ExtendedValue.AsBytes, Text) then
              Text := TStructuralText.EncodeHex(AValue.ExtendedValue.AsBytes);
            SetText(Text);
          end
          else if AValue.IsTagged(TDynamicTag.Undefined) or
                  AValue.IsTagged(TDynamicTag.MinKey) or
                  AValue.IsTagged(TDynamicTag.MaxKey) then
            Result.SetAttribute('nil', 'true', XSI_NAMESPACE)
          else
          begin
            { Everything left carries parts rather than one scalar, so it is
              written as the object it is. }
            Child := AValue.ExtendedValue;
            if (Child <> nil) and (Child.Kind = TDynamicKind.Obj) then
              for I := 0 to Child.Count - 1 do
                Result.AdoptChild(DynamicToElement(Child[I],
                  StructuralName(Child.Names[I], AOptions, APath), AOptions,
                  TStructuralPath.Member(APath, Child.Names[I])))
            else
              RefuseValue(AValue, AOptions, APath);
          end;
        end;
      TDynamicKind.Arr:
        begin
          { XML writes a list as repeated sibling elements, so a list with no
            members has literally nothing to write. At the root there is no
            containing element to repeat either way, so an empty root array
            is an empty element. }
          for I := 0 to AValue.Count - 1 do
            Result.AdoptChild(DynamicToElement(AValue[I], 'Item', AOptions,
              TStructuralPath.Index(APath, I)));
        end;
      TDynamicKind.Obj:
        begin
          for I := 0 to AValue.Count - 1 do
          begin
            Name := AValue.Names[I];
            Child := AValue[I];
            ChildPath := TStructuralPath.Member(APath, Name);

            { The '@name' / '#text' / '@xmlns' projection is XML's natural
              idiom and is used in both directions, so an XML document
              converted out and back keeps its attributes. }
            if (Name = '@xmlns') and (Child.Kind = TDynamicKind.Str) then
            begin
              Result.NamespaceUri := Child.AsStr;
              Continue;
            end;
            if IsAttributeMember(Name, Child) then
            begin
              Result.SetAttribute(Name.Substring(1), Child.AsStr);
              Continue;
            end;
            if IsTextMember(Name, Child) then
            begin
              SetText(Child.AsStr);
              Continue;
            end;

            Dest := StructuralName(Name, AOptions, ChildPath);

            if Child.Kind = TDynamicKind.Arr then
            begin
              { Repeated sibling elements are XML's idiom for a list. A list
                with no members has no repeated element to write, so it is
                written as one empty element rather than dropped - which
                does mean an empty list and a list of one empty thing look
                alike, and docs\xml-behavior.md says so. }
              if Child.Count = 0 then
                Result.AdoptChild(TXmlElement.Create(Dest))
              else
                for var J := 0 to Child.Count - 1 do
                  Result.AdoptChild(DynamicToElement(Child[J], Dest, AOptions,
                    TStructuralPath.Index(ChildPath, J)));
            end
            else
              Result.AdoptChild(DynamicToElement(Child, Dest, AOptions,
                ChildPath));
          end;
        end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ --------------------------------------------------------- configuration --- }

class procedure TXmlEngine.SetDateTimePolicy(ATypeInfo: PTypeInfo;
  const AFieldName: string; AKind: Integer; const APattern: string);
var
  Policy: TDateTimePolicy;
  TypeKey: string;

  procedure ApplyAll;
  begin
    if ATypeInfo = nil then
    begin
      FDatePolicies.SetGlobal(Policy);
      FTimePolicies.SetGlobal(Policy);
      FTimestampPolicies.SetGlobal(Policy);
    end
    else if AFieldName = '' then
    begin
      FDatePolicies.SetForType(TypeKey, Policy);
      FTimePolicies.SetForType(TypeKey, Policy);
      FTimestampPolicies.SetForType(TypeKey, Policy);
    end
    else
    begin
      FDatePolicies.SetForField(TypeKey, AFieldName, Policy);
      FTimePolicies.SetForField(TypeKey, AFieldName, Policy);
      FTimestampPolicies.SetForField(TypeKey, AFieldName, Policy);
    end;
  end;

begin
  CheckNotFrozen;
  Policy := TDateTimePolicy.Make(AKind, APattern);
  TypeKey := '';
  if ATypeInfo <> nil then TypeKey := TypeKeyOf(ATypeInfo);
  FLock.Enter;
  try
    ApplyAll;
  finally
    FLock.Leave;
  end;
end;

class procedure TXmlEngine.RegisterEnumMapping(ATypeInfo: PTypeInfo;
  const AValues: array of string);
var
  Values: TArray<string>;
  I: Integer;
begin
  CheckNotFrozen;
  if (ATypeInfo = nil) or (ATypeInfo.Kind <> tkEnumeration) then
    raise EXmlInternalError.Create(
      'RegisterEnumMapping needs an enumeration type.');
  SetLength(Values, Length(AValues));
  for I := 0 to Integer(High(AValues)) do Values[I] := AValues[I];
  FLock.Enter;
  try
    FEnumMappings.AddOrSetValue(ATypeInfo, Values);
  finally
    FLock.Leave;
  end;
end;

class procedure TXmlEngine.RegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TXmlValueSerializerClass);
begin
  CheckNotFrozen;
  if (ATypeInfo = nil) or (ASerializerClass = nil) then
    raise EXmlInternalError.Create(
      'RegisterTypeSerializer needs a type and a serializer class.');
  FLock.Enter;
  try
    FTypeSerializers.AddOrSetValue(ATypeInfo, ASerializerClass);
  finally
    FLock.Leave;
  end;
end;

class procedure TXmlEngine.FreezeConfiguration;
begin
  FFrozen := True;
end;

class function TXmlEngine.IsFrozen: Boolean;
begin
  Result := FFrozen;
end;

class procedure TXmlEngine.ResetConfiguration;
var
  P: TXmlTypePlan;
begin
  FLock.Enter;
  try
    for P in FPlans.Values do P.Free;
    FPlans.Clear;
    FRootPlans.Clear;
    FEnumMappings.Clear;
    FTypeSerializers.Clear;
    FSerializerSingletons.Clear;
    FDatePolicies.Reset;
    FTimePolicies.Reset;
    FTimestampPolicies.Reset;
    FBuildTrail.Clear;
    FFrozen := False;
  finally
    FLock.Leave;
  end;
end;

class function TXmlEngine.PlanCount: Integer;
begin
  Result := Integer(FPlans.Count);
end;

end.
