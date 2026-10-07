{*******************************************************************************
  PascalForge.Xml

  Public XML serialization facade for PascalForge.Serialization.

  Responsibilities
    - Typed XML serialization/deserialization.
    - Population of existing values.
    - XML-specific attributes, options and customization API.

  Registration
    Direct TXmlSerializer use does not require format registration.
    Generic TSerialization operations require explicit registration:
    TXmlSerializationRegistration.RegisterFormat (PascalForge.Xml.Registration).

  Configuration
    Global serializer configuration becomes immutable after first use.

  Threading
    Serialization is safe for concurrent use after configuration is frozen.

  Documentation
    docs/formats/xml.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Xml;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  XML serialization.

      Xml     := TXmlSerializer.Serialize<TShipment>(Shipment);
      Shipment := TXmlSerializer.Deserialize<TShipment>(Xml);
      TXmlSerializer.Populate<TShipment>(Existing, Xml);

  This is a real XML engine. A Delphi value is written straight to XML and
  read straight back; nothing routes through JSON, through the dynamic tree,
  or through any other format. The only thing shared with JSON and BSON is
  the Delphi type foundation in PascalForge.Serialization.Core: what a
  nullable is, what a collection is, how a type is named.

  Everything else is XML's own. XML reads only XML attributes - [XmlName]
  never sees [JsonName] and vice versa - and XML's date, GUID and set
  conventions are XML's, chosen to look like XML rather than to match JSON.

  The default contract is documented in docs\xml-behavior.md and is
  deterministic: nothing about it is decided at run time.

  Using this unit needs no registration. PascalForge.Xml.Registration exists
  only for code that picks a format at run time.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Rtti, System.TypInfo,
  System.Generics.Collections,
  PascalForge.Serialization.Core, PascalForge.Dynamic;

type
  EXmlError = class(Exception);
  { The document is at fault: not well formed, or not what the contract
    expects. }
  EXmlInputError = class(EXmlError);
  { The model or the configuration is at fault. }
  EXmlInternalError = class(EXmlError);

{ ===========================================================================
  THE DOCUMENT MODEL

  Small on purpose: elements, attributes, text. It exists because a custom
  XML serializer needs somewhere to write, and because an XML engine that
  could only produce text could not read. It is not a general-purpose DOM -
  no DTD, no entities beyond the predefined five and numeric character
  references, no processing instructions kept, no mixed-content model.

  IDENTITY IS LOCAL NAME PLUS NAMESPACE URI. A prefix is a spelling, not a
  name: two documents that spell the same namespace 'p' and 'ns1' are the
  same document here. Prefixes are preserved on a round trip when they can
  be, but nothing compares them.
  =========================================================================== }

type
  TXmlElement = class;

  TXmlAttribute = record
    Name: string;          { local name }
    NamespaceUri: string;  { '' for an unprefixed attribute }
    Value: string;
  end;

  TXmlElement = class
  strict private
    FName: string;
    FNamespaceUri: string;
    FPrefix: string;
    FText: string;
    FHasText: Boolean;
    FAttributes: TList<TXmlAttribute>;
    FChildren: TObjectList<TXmlElement>;
    FDeclaredPrefixes: TDictionary<string, string>;
    function GetChild(AIndex: Integer): TXmlElement;
    function GetChildCount: Integer;
    function GetAttribute(AIndex: Integer): TXmlAttribute;
    function GetAttributeCount: Integer;
  public
    constructor Create(const AName: string; const ANamespaceUri: string = '');
    destructor Destroy; override;

    function AddChild(const AName: string;
      const ANamespaceUri: string = ''): TXmlElement;
    { Adopts AChild; the element owns it from here. }
    procedure AdoptChild(AChild: TXmlElement);
    { Gives up a child without freeing it. }
    function ExtractChild(AChild: TXmlElement): TXmlElement;

    procedure SetAttribute(const AName, AValue: string;
      const ANamespaceUri: string = '');
    function TryGetAttribute(const AName: string; out AValue: string;
      const ANamespaceUri: string = ''): Boolean;
    function AttributeValue(const AName: string;
      const ADefault: string = ''): string;
    function HasAttribute(const AName: string;
      const ANamespaceUri: string = ''): Boolean;

    { First child with this local name and namespace; nil when there is
      none. An empty ANamespaceUri matches a child in no namespace. }
    function FindChild(const AName: string;
      const ANamespaceUri: string = ''): TXmlElement;
    { Every child with this local name and namespace, in document order. }
    function ChildrenNamed(const AName: string;
      const ANamespaceUri: string = ''): TArray<TXmlElement>;

    { Declares a prefix for a namespace on THIS element. Only a hint for the
      writer: the document is correct whatever prefixes it ends up with. }
    procedure DeclareNamespace(const APrefix, AUri: string);
    function DeclaredPrefixes: TArray<TPair<string, string>>;

    { Serializes this element and everything under it. }
    function ToXml(AIndent: Boolean = False): string;

    property Name: string read FName;
    property NamespaceUri: string read FNamespaceUri write FNamespaceUri;
    { The prefix this element was read with, or '' . Not contractual. }
    property Prefix: string read FPrefix write FPrefix;
    { The element's text content. Setting it marks the element as having
      text even when the text is empty, which is how <a></a> is told from an
      element that simply has children. }
    property Text: string read FText write FText;
    property HasText: Boolean read FHasText write FHasText;
    property ChildCount: Integer read GetChildCount;
    property Children[AIndex: Integer]: TXmlElement read GetChild;
    property AttributeCount: Integer read GetAttributeCount;
    property Attributes[AIndex: Integer]: TXmlAttribute read GetAttribute;
  end;

{ ===========================================================================
  ATTRIBUTES

  XML's own, and only XML's. A member may carry [JsonName], [XmlName] and
  [BsonName] at once; each engine reads its own and is blind to the others.
  =========================================================================== }

type
  { The element (or XML attribute) name for this member, or the root element
    name when placed on a type. }
  XmlNameAttribute = class(TCustomAttribute)
  strict private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

  { Removes the member from XML in both directions. }
  XmlIgnoreAttribute = class(TCustomAttribute)
  end;

  { Writes the member as an XML ATTRIBUTE of its owner's element rather than
    as a child element. Only a value that has a single text form can be an
    attribute - a scalar, an enumeration, a set, a GUID, a date, or a
    nullable of one of those. Anything else raises at plan-build time. }
  XmlAttributeAttribute = class(TCustomAttribute)
  end;

  { Writes the member as the owner element's own text content. At most one
    member of a type may be the text; a second one raises. }
  XmlTextAttribute = class(TCustomAttribute)
  end;

  { The namespace URI for this member's element, or - on a type - the
    default namespace of its root element and of every member that does not
    say otherwise. The prefix is a hint for the writer; namespace identity
    is the URI. }
  XmlNamespaceAttribute = class(TCustomAttribute)
  strict private
    FUri: string;
    FPrefix: string;
  public
    constructor Create(const AUri: string); overload;
    constructor Create(const AUri, APrefix: string); overload;
    property Uri: string read FUri;
    property Prefix: string read FPrefix;
  end;

  { Names the wrapper element of a list, an array or a dictionary.
    [XmlArray('')] means no wrapper: the items become repeated siblings in
    the owner's element. }
  XmlArrayAttribute = class(TCustomAttribute)
  strict private
    FWrapperName: string;
    FWrapped: Boolean;
  public
    constructor Create(const AWrapperName: string);
    property WrapperName: string read FWrapperName;
    property Wrapped: Boolean read FWrapped;
  end;

  { Names the element of one item of a list, array or dictionary. }
  XmlItemNameAttribute = class(TCustomAttribute)
  strict private
    FItemName: string;
  public
    constructor Create(const AItemName: string);
    property ItemName: string read FItemName;
  end;

  { How a TDate, TTime or TDateTime member is written. XML's setting; it has
    no effect on JSON or BSON. }
  TXmlDateTimeFormat = (
    { xs:date, xs:time, xs:dateTime - the default for each kind. }
    Xsd,
    { Whole seconds since 1970-01-01T00:00:00, as an integer. }
    UnixSeconds,
    { Milliseconds since the same epoch, as an integer. }
    UnixMilliseconds,
    { A Delphi FormatDateTime pattern, used for both directions. }
    Custom);

  XmlDateTimeFormatAttribute = class(TCustomAttribute)
  strict private
    FFormat: TXmlDateTimeFormat;
    FPattern: string;
  public
    constructor Create(AFormat: TXmlDateTimeFormat); overload;
    constructor Create(const APattern: string); overload;
    property Format: TXmlDateTimeFormat read FFormat;
    property Pattern: string read FPattern;
  end;

{ ===========================================================================
  CUSTOM SERIALIZERS

  XML's, not JSON's. A custom serializer here is handed the element the value
  occupies, so it may write text, attributes, children, or all three.
  =========================================================================== }

type
  TCustomXmlValueSerializer = class
  public
    { Writes AValue into AElement. The element already exists and is already
      named; fill in its content. }
    procedure Serialize(const AValue: TValue;
      AElement: TXmlElement); virtual; abstract;

    { Reads AElement. AExisting is what the member already held - reuse it
      when it is an instance you can populate, and say so by returning it.
      Returning a different instance transfers the disposal decision for the
      old one to you. }
    function Deserialize(AElement: TXmlElement; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; virtual; abstract;
  end;

  TXmlValueSerializerClass = class of TCustomXmlValueSerializer;

  { The typed base, and the one to use: it names the Delphi type, so an
    implementation never touches TValue or PTypeInfo. }
  TCustomXmlValueSerializer<T> = class(TCustomXmlValueSerializer)
  public
    procedure SerializeValue(const AValue: T;
      AElement: TXmlElement); virtual; abstract;
    function DeserializeValue(AElement: TXmlElement;
      const AExisting: T): T; virtual; abstract;

    procedure Serialize(const AValue: TValue;
      AElement: TXmlElement); overload; override; final;
    function Deserialize(AElement: TXmlElement; ATypeInfo: PTypeInfo;
      const AExisting: TValue): TValue; overload; override; final;
  end;

  { For the common case: a value that is one piece of text. }
  TXmlTextValueSerializer<T> = class(TCustomXmlValueSerializer<T>)
  public
    function ToText(const AValue: T): string; virtual; abstract;
    function FromText(const AText: string): T; virtual; abstract;

    procedure SerializeValue(const AValue: T;
      AElement: TXmlElement); override; final;
    function DeserializeValue(AElement: TXmlElement;
      const AExisting: T): T; override; final;
  end;

  { Names the custom serializer for one member. }
  XmlSerializerAttribute = class(TCustomAttribute)
  strict private
    FSerializerClass: TXmlValueSerializerClass;
  public
    constructor Create(ASerializerClass: TXmlValueSerializerClass);
    property SerializerClass: TXmlValueSerializerClass read FSerializerClass;
  end;

{ =========================================================================== }

type
  { ------------------------------------------------------------------------
    REVERSIBLE XML NAME ENCODING

    Public because a caller who reads a converted document with somebody
    else's XML tools needs to be able to undo what the conversion did.

        EncodeName('$type')          = '_x0024_type'
        DecodeName('_x0024_type')    = '$type'
        EncodeName('_x0024_type')    = '_x005F_x0024_type'

    A code unit XML will not accept becomes _xHHHH_, and an underscore
    followed by an x is always encoded too - which is what keeps a name that
    already looks encoded from colliding with one that had to be. The empty
    name is _x_.

    Decoding is applied to every element and attribute name when XML is read
    structurally, so a document produced by .NET's XmlConvert.EncodeName
    decodes here as well. It is NOT applied on the contract-aware path,
    where the name is whatever [XmlName] said it was.
    ------------------------------------------------------------------------ }
  TXmlNameCodec = record
  public
    class function EncodeName(const AName: string): string; static;
    class function DecodeName(const AName: string): string; static;
    { True when XML would accept this name as an element name as it stands. }
    class function IsValidName(const AName: string): Boolean; static;
  end;

  TXmlSerializationOptions = record
  public
    { Two spaces per level and a newline between elements. Off by default:
      the compact form is the wire form. }
    Indent: Boolean;
    { <?xml version="1.0" encoding="UTF-8"?> ahead of the root. Off by
      default, because the usual consumer is another program. }
    Declaration: Boolean;
    { Overrides the root element name for this operation only. }
    RootName: string;
    class function Default: TXmlSerializationOptions; static;
  end;

  TXmlSerializer = class
  strict private
    { A generic method body declared in an interface section may reference
      only interface-declared symbols, so every generic entry point below is
      a thin shell over one of these. }
    class function DoSerialize(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AOptions: TXmlSerializationOptions): string; static;
    class function DoDeserialize(ATypeInfo: PTypeInfo;
      const AXml: string): TValue; static;
    class procedure DoPopulate(ATypeInfo: PTypeInfo; const AValue: TValue;
      const AXml: string); static;
    class function DoFrom(ATypeInfo: PTypeInfo;
      const ASource: TSerializationPayload; AFrom: TSerializationFormat;
      const AOptions: TXmlSerializationOptions): string; static;
    class procedure DoSetDateTimePolicy(ATypeInfo: PTypeInfo;
      const AFieldName: string; AFormat: TXmlDateTimeFormat;
      const APattern: string); static;
    class procedure DoRegisterEnumMapping(ATypeInfo: PTypeInfo;
      const AValues: array of string); static;
    class procedure DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
      ASerializerClass: TXmlValueSerializerClass); static;
  public
    { --- the normal API ---------------------------------------------------- }
    class function Serialize<T>(const AValue: T): string; overload; static;
    class function Serialize<T>(const AValue: T;
      const AOptions: TXmlSerializationOptions): string; overload; static;

    class function Deserialize<T>(const AXml: string): T; static;

    { --- UTF-8, when what you need is bytes --------------------------------

      Serialize<T> returns a Delphi string: Unicode text, with no byte
      encoding until one is chosen. These choose UTF-8, which is what the
      XML declaration written alongside them says.

      SerializeUtf8 turns the declaration ON by default, precisely so the
      two agree - a document headed encoding="UTF-8" whose bytes went
      through a code page is unreadable, and that is the mistake this API
      exists to make impossible. No BOM; a leading BOM is accepted on the
      way in. }
    class function SerializeUtf8<T>(const AInstance: T): TBytes; overload; static;
    class function SerializeUtf8<T>(const AInstance: T;
      const AOptions: TXmlSerializationOptions): TBytes; overload; static;
    class function DeserializeUtf8<T>(const AXml: TBytes): T; static;

    { Fills an instance that already exists, with the same reuse rules the
      whole library uses: a nested instance that is already there is
      populated in place, never replaced. }
    class procedure Populate<T>(const AInstance: T; const AXml: string); static;

    { --- destination-oriented conversion -----------------------------------

      XML is the destination and is known at compile time, so only the SOURCE
      format is looked up. This unit has no compile-time dependency on any
      other format: the source is reached through the registry.

          Xml := TXmlSerializer.From(Json, TSerializationFormat.Json);
          Xml := TXmlSerializer.From<TShipment>(Json, TSerializationFormat.Json);

      The generic form is CONTRACT-AWARE: the source deserializes into T by
      its own rules and XML writes T by its own, so each side's attributes
      apply. The non-generic form is STRUCTURAL and carries only what every
      format shares - see docs\xml-behavior.md for what that loses.

      A binary source arrives as TBytes or as a TSerializationPayload. There
      is no base64-pretending-to-be-text overload. }
    class function From(const ASource: string;
      AFrom: TSerializationFormat): string; overload; static;
    class function From(const ASource: TBytes;
      AFrom: TSerializationFormat): string; overload; static;
    class function From(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): string; overload; static;

    { Structural conversion, with the profile named.

      Natural encodes a member name XML cannot spell - "$type" becomes
      "_x0024_type" and decodes back - and writes values as XML text.
      Lossless does the same and additionally marks each value's kind with
      one attribute in the library's own namespace, so reading the result
      back reproduces the source structural tree exactly, integers and
      booleans and empty arrays included. Strict refuses a name XML cannot
      spell, and refuses binary and timestamps, naming the member path. }
    class function From(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat;
      AProfile: TStructuralConversionProfile): string; overload; static;
    class function From(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat; AProfile: TStructuralConversionProfile;
      const AOptions: TXmlSerializationOptions): string; overload; static;

    class function From<T>(const ASource: string;
      AFrom: TSerializationFormat): string; overload; static;
    class function From<T>(const ASource: TBytes;
      AFrom: TSerializationFormat): string; overload; static;
    class function From<T>(const ASource: TSerializationPayload;
      AFrom: TSerializationFormat): string; overload; static;
    class function From<T>(const ASource: TSerializationPayload; AFrom: TSerializationFormat;
      const AOptions: TXmlSerializationOptions): string; overload; static;

    { --- date and time ----------------------------------------------------

      XML's settings, independent of JSON's and BSON's. Resolution is
      field, then type, then this global default, then the built-in xs:
      forms, and it happens once while a plan is built. }
    class procedure SetDateTimeFormat(AFormat: TXmlDateTimeFormat); overload; static;
    class procedure SetDateTimeFormat(const APattern: string); overload; static;
    class procedure RegisterDateTimeFormat<T>(
      AFormat: TXmlDateTimeFormat); overload; static;
    class procedure RegisterDateTimeFormat<T>(
      const APattern: string); overload; static;
    class procedure RegisterFieldDateTimeFormat<T>(const AFieldName: string;
      AFormat: TXmlDateTimeFormat); overload; static;
    class procedure RegisterFieldDateTimeFormat<T>(const AFieldName: string;
      const APattern: string); overload; static;

    { --- registrations ----------------------------------------------------- }

    { Maps enumeration ordinal N to AValues[N], in both directions. XML's
      mapping; JSON's is a different table. }
    class procedure RegisterEnumMapping<T>(
      const AValues: array of string); static;

    { A custom serializer for every value of a type. }
    class procedure RegisterTypeSerializer<T>(
      ASerializerClass: TXmlValueSerializerClass); static;

    { --- configuration lifecycle ------------------------------------------- }

    { After this, a registration raises instead of being a silent no-op. A
      plan is cached the first time a type is used, so a late registration
      would otherwise do nothing at all. }
    class procedure FreezeConfiguration; static;
    class function IsFrozen: Boolean; static;

    { --- dynamic ---------------------------------------------------------

      An XML document as a dynamic value, and a dynamic value as XML, with
      no Delphi type involved - under the structural mapping described in
      docs/conversion.md: attributes, namespaces and mixed content are not
      part of it. The tree is the caller's. }
    class function ToDynamic(const AXml: string): TDynamicValue; overload; static;
    class function ToDynamic(const AXml: string;
      const AOptions: TStructuralConversionOptions): TDynamicValue; overload; static;
    { ARootName names the root element; a value has none of its own. }
    class function FromDynamic(AValue: TDynamicValue;
      const ARootName: string = 'Value'): string; overload; static;
    class function FromDynamic(AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions;
      const ARootName: string = 'Value'): string; overload; static;
    { Forgets every XML registration and every cached plan. For tests. }
    class procedure ResetConfiguration; static;
  end;

implementation

uses
  PascalForge.Xml.Internal;

{ ------------------------------------------------------------ TXmlElement --- }

constructor TXmlElement.Create(const AName, ANamespaceUri: string);
begin
  inherited Create;
  FName := AName;
  FNamespaceUri := ANamespaceUri;
  FAttributes := TList<TXmlAttribute>.Create;
  FChildren := TObjectList<TXmlElement>.Create(True);
end;

destructor TXmlElement.Destroy;
begin
  FDeclaredPrefixes.Free;
  FChildren.Free;
  FAttributes.Free;
  inherited Destroy;
end;

function TXmlElement.GetChild(AIndex: Integer): TXmlElement;
begin
  Result := FChildren[AIndex];
end;

function TXmlElement.GetChildCount: Integer;
begin
  Result := Integer(FChildren.Count);
end;

function TXmlElement.GetAttribute(AIndex: Integer): TXmlAttribute;
begin
  Result := FAttributes[AIndex];
end;

function TXmlElement.GetAttributeCount: Integer;
begin
  Result := Integer(FAttributes.Count);
end;

function TXmlElement.AddChild(const AName, ANamespaceUri: string): TXmlElement;
begin
  Result := TXmlElement.Create(AName, ANamespaceUri);
  FChildren.Add(Result);
end;

procedure TXmlElement.AdoptChild(AChild: TXmlElement);
begin
  if AChild <> nil then FChildren.Add(AChild);
end;

function TXmlElement.ExtractChild(AChild: TXmlElement): TXmlElement;
begin
  Result := FChildren.Extract(AChild);
end;

procedure TXmlElement.SetAttribute(const AName, AValue,
  ANamespaceUri: string);
var
  A: TXmlAttribute;
  I: Integer;
begin
  for I := 0 to Integer(FAttributes.Count - 1) do
    if (FAttributes[I].Name = AName) and
       (FAttributes[I].NamespaceUri = ANamespaceUri) then
    begin
      A := FAttributes[I];
      A.Value := AValue;
      FAttributes[I] := A;
      Exit;
    end;
  A.Name := AName;
  A.NamespaceUri := ANamespaceUri;
  A.Value := AValue;
  FAttributes.Add(A);
end;

function TXmlElement.TryGetAttribute(const AName: string; out AValue: string;
  const ANamespaceUri: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to Integer(FAttributes.Count - 1) do
    if (FAttributes[I].Name = AName) and
       (FAttributes[I].NamespaceUri = ANamespaceUri) then
    begin
      AValue := FAttributes[I].Value;
      Exit(True);
    end;
  AValue := '';
  Result := False;
end;

function TXmlElement.AttributeValue(const AName, ADefault: string): string;
begin
  if not TryGetAttribute(AName, Result) then Result := ADefault;
end;

function TXmlElement.HasAttribute(const AName, ANamespaceUri: string): Boolean;
var
  Dummy: string;
begin
  Result := TryGetAttribute(AName, Dummy, ANamespaceUri);
end;

function TXmlElement.FindChild(const AName, ANamespaceUri: string): TXmlElement;
var
  C: TXmlElement;
begin
  for C in FChildren do
    if (C.Name = AName) and (C.NamespaceUri = ANamespaceUri) then Exit(C);
  Result := nil;
end;

function TXmlElement.ChildrenNamed(const AName,
  ANamespaceUri: string): TArray<TXmlElement>;
var
  C: TXmlElement;
  N: Integer;
begin
  SetLength(Result, FChildren.Count);
  N := 0;
  for C in FChildren do
    if (C.Name = AName) and (C.NamespaceUri = ANamespaceUri) then
    begin
      Result[N] := C;
      Inc(N);
    end;
  SetLength(Result, N);
end;

procedure TXmlElement.DeclareNamespace(const APrefix, AUri: string);
begin
  if AUri = '' then Exit;
  if FDeclaredPrefixes = nil then
    FDeclaredPrefixes := TDictionary<string, string>.Create;
  FDeclaredPrefixes.AddOrSetValue(APrefix, AUri);
end;

function TXmlElement.DeclaredPrefixes: TArray<TPair<string, string>>;
begin
  if FDeclaredPrefixes = nil then Exit(nil);
  Result := FDeclaredPrefixes.ToArray;
end;

function TXmlElement.ToXml(AIndent: Boolean): string;
begin
  Result := TXmlEngine.WriteDocument(Self, AIndent, False);
end;

{ ------------------------------------------------------------- attributes --- }

constructor XmlNameAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

constructor XmlNamespaceAttribute.Create(const AUri: string);
begin
  inherited Create;
  FUri := AUri;
  FPrefix := '';
end;

constructor XmlNamespaceAttribute.Create(const AUri, APrefix: string);
begin
  inherited Create;
  FUri := AUri;
  FPrefix := APrefix;
end;

constructor XmlArrayAttribute.Create(const AWrapperName: string);
begin
  inherited Create;
  FWrapperName := AWrapperName;
  FWrapped := AWrapperName <> '';
end;

constructor XmlItemNameAttribute.Create(const AItemName: string);
begin
  inherited Create;
  FItemName := AItemName;
end;

constructor XmlDateTimeFormatAttribute.Create(AFormat: TXmlDateTimeFormat);
begin
  inherited Create;
  FFormat := AFormat;
  FPattern := '';
end;

constructor XmlDateTimeFormatAttribute.Create(const APattern: string);
begin
  inherited Create;
  FFormat := TXmlDateTimeFormat.Custom;
  FPattern := APattern;
end;

constructor XmlSerializerAttribute.Create(
  ASerializerClass: TXmlValueSerializerClass);
begin
  inherited Create;
  FSerializerClass := ASerializerClass;
end;

{ ------------------------------------------------- typed custom serializer --- }

procedure TCustomXmlValueSerializer<T>.Serialize(const AValue: TValue;
  AElement: TXmlElement);
begin
  SerializeValue(AValue.AsType<T>, AElement);
end;

function TCustomXmlValueSerializer<T>.Deserialize(AElement: TXmlElement;
  ATypeInfo: PTypeInfo; const AExisting: TValue): TValue;
var
  Existing: T;
begin
  if AExisting.IsEmpty then
    Existing := Default(T)
  else
    Existing := AExisting.AsType<T>;
  Result := TValue.From<T>(DeserializeValue(AElement, Existing));
end;

procedure TXmlTextValueSerializer<T>.SerializeValue(const AValue: T;
  AElement: TXmlElement);
begin
  AElement.Text := ToText(AValue);
  AElement.HasText := True;
end;

function TXmlTextValueSerializer<T>.DeserializeValue(AElement: TXmlElement;
  const AExisting: T): T;
begin
  Result := FromText(AElement.Text);
end;

{ ------------------------------------------------------------- options --- }

class function TXmlSerializationOptions.Default: TXmlSerializationOptions;
begin
  Result.Indent := False;
  Result.Declaration := False;
  Result.RootName := '';
end;

{ ------------------------------------------------------------- bridges --- }

class function TXmlSerializer.DoSerialize(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AOptions: TXmlSerializationOptions): string;
begin
  Result := TXmlEngine.SerializeRoot(ATypeInfo, AValue, AOptions.RootName,
    AOptions.Indent, AOptions.Declaration);
end;

class function TXmlSerializer.DoDeserialize(ATypeInfo: PTypeInfo;
  const AXml: string): TValue;
begin
  Result := TXmlEngine.DeserializeRoot(ATypeInfo, AXml, TValue.Empty);
end;

class procedure TXmlSerializer.DoPopulate(ATypeInfo: PTypeInfo;
  const AValue: TValue; const AXml: string);
begin
  TXmlEngine.DeserializeRoot(ATypeInfo, AXml, AValue);
end;

class function TXmlSerializer.DoFrom(ATypeInfo: PTypeInfo;
  const ASource: TSerializationPayload; AFrom: TSerializationFormat;
  const AOptions: TXmlSerializationOptions): string;
begin
  Result := TXmlEngine.FromPayload(ATypeInfo, ASource, AFrom, AOptions.RootName,
    AOptions.Indent, AOptions.Declaration);
end;

class procedure TXmlSerializer.DoSetDateTimePolicy(ATypeInfo: PTypeInfo;
  const AFieldName: string; AFormat: TXmlDateTimeFormat;
  const APattern: string);
begin
  TXmlEngine.SetDateTimePolicy(ATypeInfo, AFieldName, Ord(AFormat), APattern);
end;

class procedure TXmlSerializer.DoRegisterEnumMapping(ATypeInfo: PTypeInfo;
  const AValues: array of string);
begin
  TXmlEngine.RegisterEnumMapping(ATypeInfo, AValues);
end;

class procedure TXmlSerializer.DoRegisterTypeSerializer(ATypeInfo: PTypeInfo;
  ASerializerClass: TXmlValueSerializerClass);
begin
  TXmlEngine.RegisterTypeSerializer(ATypeInfo, ASerializerClass);
end;

{ ------------------------------------------------------------ operations --- }

class function TXmlSerializer.Serialize<T>(const AValue: T): string;
begin
  Result := Serialize<T>(AValue, TXmlSerializationOptions.Default);
end;

class function TXmlSerializer.Serialize<T>(const AValue: T;
  const AOptions: TXmlSerializationOptions): string;
var
  V: TValue;
begin
  TValue.Make(@AValue, System.TypeInfo(T), V);
  Result := DoSerialize(System.TypeInfo(T), V, AOptions);
end;

class function TXmlSerializer.Deserialize<T>(const AXml: string): T;
begin
  Result := DoDeserialize(System.TypeInfo(T), AXml).AsType<T>;
end;

class procedure TXmlSerializer.Populate<T>(const AInstance: T;
  const AXml: string);
var
  V: TValue;
begin
  TValue.Make(@AInstance, System.TypeInfo(T), V);
  DoPopulate(System.TypeInfo(T), V, AXml);
end;

class function TXmlSerializer.From(const ASource: string;
  AFrom: TSerializationFormat): string;
begin
  Result := From(TSerializationPayload.FromText(ASource), AFrom);
end;

class function TXmlSerializer.From(const ASource: TBytes;
  AFrom: TSerializationFormat): string;
begin
  Result := From(TSerializationPayload.FromBytes(ASource), AFrom);
end;

class function TXmlSerializer.From(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): string;
begin
  Result := From(ASource, AFrom, TStructuralConversionProfile.Natural);
end;

class function TXmlSerializer.From(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat;
  AProfile: TStructuralConversionProfile): string;
begin
  Result := From(ASource, AFrom, AProfile, TXmlSerializationOptions.Default);
end;

class function TXmlSerializer.From(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat; AProfile: TStructuralConversionProfile;
  const AOptions: TXmlSerializationOptions): string;
begin
  Result := TXmlEngine.FromPayloadStructural(ASource, AFrom, AOptions.Indent,
    AOptions.Declaration, AProfile);
end;

{ ------------------------------------------------------------ name codec --- }

class function TXmlNameCodec.EncodeName(const AName: string): string;
begin
  Result := PascalForge.Xml.Internal.EncodeXmlName(AName);
end;

class function TXmlNameCodec.DecodeName(const AName: string): string;
begin
  Result := PascalForge.Xml.Internal.DecodeXmlName(AName);
end;

class function TXmlNameCodec.IsValidName(const AName: string): Boolean;
begin
  Result := PascalForge.Xml.Internal.IsValidXmlName(AName);
end;

{ ----------------------------------------------------------------- UTF-8 --- }

class function TXmlSerializer.SerializeUtf8<T>(const AInstance: T): TBytes;
var
  Options: TXmlSerializationOptions;
begin
  { The declaration says UTF-8 and the bytes ARE UTF-8. A document that
    announces one encoding and is written in another is the classic way to
    make an XML file that nothing can read, so the two are decided in the
    same place. }
  Options := TXmlSerializationOptions.Default;
  Options.Declaration := True;
  Result := SerializeUtf8<T>(AInstance, Options);
end;

class function TXmlSerializer.SerializeUtf8<T>(const AInstance: T;
  const AOptions: TXmlSerializationOptions): TBytes;
begin
  Result := StringToUtf8Bytes(Serialize<T>(AInstance, AOptions));
end;

class function TXmlSerializer.DeserializeUtf8<T>(const AXml: TBytes): T;
begin
  Result := Deserialize<T>(Utf8BytesToString(AXml));
end;

class function TXmlSerializer.From<T>(const ASource: string;
  AFrom: TSerializationFormat): string;
begin
  Result := From<T>(TSerializationPayload.FromText(ASource), AFrom);
end;

class function TXmlSerializer.From<T>(const ASource: TBytes;
  AFrom: TSerializationFormat): string;
begin
  Result := From<T>(TSerializationPayload.FromBytes(ASource), AFrom);
end;

class function TXmlSerializer.From<T>(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat): string;
begin
  Result := DoFrom(System.TypeInfo(T), ASource, AFrom,
    TXmlSerializationOptions.Default);
end;

class function TXmlSerializer.From<T>(const ASource: TSerializationPayload;
  AFrom: TSerializationFormat; const AOptions: TXmlSerializationOptions): string;
begin
  Result := DoFrom(System.TypeInfo(T), ASource, AFrom, AOptions);
end;

{ ---------------------------------------------------------- date and time --- }

class procedure TXmlSerializer.SetDateTimeFormat(AFormat: TXmlDateTimeFormat);
begin
  TXmlEngine.SetDateTimePolicy(nil, '', Ord(AFormat), '');
end;

class procedure TXmlSerializer.SetDateTimeFormat(const APattern: string);
begin
  TXmlEngine.SetDateTimePolicy(nil, '', Ord(TXmlDateTimeFormat.Custom), APattern);
end;

class procedure TXmlSerializer.RegisterDateTimeFormat<T>(
  AFormat: TXmlDateTimeFormat);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), '', AFormat, '');
end;

class procedure TXmlSerializer.RegisterDateTimeFormat<T>(
  const APattern: string);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), '', TXmlDateTimeFormat.Custom, APattern);
end;

class procedure TXmlSerializer.RegisterFieldDateTimeFormat<T>(
  const AFieldName: string; AFormat: TXmlDateTimeFormat);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), AFieldName, AFormat, '');
end;

class procedure TXmlSerializer.RegisterFieldDateTimeFormat<T>(
  const AFieldName, APattern: string);
begin
  DoSetDateTimePolicy(System.TypeInfo(T), AFieldName,
    TXmlDateTimeFormat.Custom, APattern);
end;

{ -------------------------------------------------------- registrations --- }

class procedure TXmlSerializer.RegisterEnumMapping<T>(
  const AValues: array of string);
begin
  DoRegisterEnumMapping(System.TypeInfo(T), AValues);
end;

class procedure TXmlSerializer.RegisterTypeSerializer<T>(
  ASerializerClass: TXmlValueSerializerClass);
begin
  DoRegisterTypeSerializer(System.TypeInfo(T), ASerializerClass);
end;

class procedure TXmlSerializer.FreezeConfiguration;
begin
  TXmlEngine.FreezeConfiguration;
end;

class function TXmlSerializer.IsFrozen: Boolean;
begin
  Result := TXmlEngine.IsFrozen;
end;

class procedure TXmlSerializer.ResetConfiguration;
begin
  TXmlEngine.ResetConfiguration;
end;


{ ---------------------------------------------------------------- dynamic --- }

class function TXmlSerializer.ToDynamic(const AXml: string): TDynamicValue;
begin
  Result := ToDynamic(AXml, TStructuralConversionOptions.Default);
end;

class function TXmlSerializer.ToDynamic(const AXml: string;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
var
  Root: TXmlElement;
begin
  Root := TXmlEngine.ParseDocument(AXml);
  try
    Result := TXmlEngine.ElementToDynamic(Root, AOptions);
  finally
    Root.Free;
  end;
end;

class function TXmlSerializer.FromDynamic(AValue: TDynamicValue;
  const ARootName: string): string;
begin
  Result := FromDynamic(AValue, TStructuralConversionOptions.Default, ARootName);
end;

class function TXmlSerializer.FromDynamic(AValue: TDynamicValue;
  const AOptions: TStructuralConversionOptions; const ARootName: string): string;
var
  Root: TXmlElement;
begin
  Root := TXmlEngine.DynamicToElement(AValue, ARootName, AOptions,
    TStructuralPath.Root);
  try
    Result := TXmlEngine.WriteDocument(Root, False, False);
  finally
    Root.Free;
  end;
end;

end.
