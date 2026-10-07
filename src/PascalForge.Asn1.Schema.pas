{*******************************************************************************
  PascalForge.Asn1.Schema

  Public ASN.1 schema model and module parser for PascalForge.Serialization.

  Responsibilities
    - Parsing X.680 module text (a declared subset) into a TAsn1Schema.
    - Refusing unsupported constructs by name (EAsn1SchemaError).
    - Type lookup for schema-guided BER/DER/CER conversion.

  Registration
    Parsing a module requires no format registration. Generic TSerialization
    operations require TAsn1SerializationRegistration.RegisterFormat
    (PascalForge.Asn1.Registration).

  Documentation
    docs/formats/asn1.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Asn1.Schema;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  ASN.1 SCHEMA MODEL AND MODULE PARSER (X.680, a declared subset)

      Schema := TAsn1Schema.ParseModule(ModuleText);
      Def    := Schema.FindType('Certificate');

  X.680 is a large language - parameterized types, information object classes,
  the X.681/682/683 layer, value set arithmetic, constraint algebra. All of it
  is real and none of it is here. What IS here is the part that describes a
  data structure, which is the part an encoder needs.

  THE SUBSET, EXACTLY. Everything in this list is parsed and honoured:

    * a module header: name, an optional definitive object identifier,
      DEFINITIONS, a tag default of EXPLICIT TAGS, IMPLICIT TAGS or
      AUTOMATIC TAGS, ::= BEGIN ... END;
    * EXPORTS, either a symbol list or ALL, terminated by a semicolon;
    * IMPORTS: one or more symbol lists, each FROM a module reference with an
      optional object identifier, terminated by a semicolon;
    * type assignments, TypeName ::= Type;
    * the structured types SEQUENCE, SET and CHOICE with their component
      lists, and SEQUENCE OF and SET OF, nested to any depth;
    * the base types BOOLEAN, INTEGER, BIT STRING, OCTET STRING, NULL,
      OBJECT IDENTIFIER, RELATIVE-OID, ENUMERATED, UTF8String, NumericString,
      PrintableString, IA5String, VisibleString, BMPString, UniversalString,
      TeletexString, GeneralString, UTCTime and GeneralizedTime;
    * a named number list on INTEGER and ENUMERATED;
    * references to other types in the same module;
    * tags, in all four classes, with an explicit EXPLICIT or IMPLICIT
      keyword or the module's default;
    * OPTIONAL and DEFAULT on a component, with DEFAULT values of the forms
      a number, TRUE, FALSE, NULL, a character string, a named number, a
      binary string and a hexadecimal string;
    * a SIZE constraint and a value range constraint, with MIN and MAX,
      on a base type and on SEQUENCE OF and SET OF;
    * comments, both the -- form and the nestable /* */ form.

  EVERYTHING ELSE IS REFUSED BY NAME. The parser raises EAsn1SchemaError
  naming the construct and the line rather than skipping it, because a module
  that half-parsed would produce an encoder that writes the wrong octets and
  nobody would find out until somebody else's decoder rejected them. The
  refusals that matter in practice: ANY and ANY DEFINED BY, value assignments,
  parameterized types and their instantiations, information object classes and
  everything with a & in it, COMPONENTS OF, the extension marker "...",
  WITH COMPONENTS, constraint unions and intersections, EXTERNAL,
  EMBEDDED PDV, CHARACTER STRING, ObjectDescriptor, GraphicString,
  VideotexString and the other character string types this library has no
  encoder for, and selection types.

  SubsetDescription below returns this list at run time, so a caller can
  print what it is going to get rather than reading a comment.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.Generics.Defaults,
  PascalForge.Serialization.Core,
  PascalForge.Asn1;

type
  { How a module tags the components of its structured types when the
    component does not say. }
  TAsn1TagDefault = (
    { A tag WRAPS the type's own encoding. X.680's default when the module
      header says nothing. }
    ExplicitTags,
    { A tag REPLACES it. }
    ImplicitTags,
    { The compiler assigns context-specific tags 0, 1, 2 ... to the components
      of each structured type, implicitly - but only to a type in which no
      component was tagged by hand, and explicitly for a component whose type
      is a CHOICE, because an implicit tag would destroy the very tag that
      says which alternative was chosen. }
    AutomaticTags);

  TAsn1TypeKind = (
    { One of the X.680 built-in types; BaseKind says which. }
    Base,
    Sequence,
    SetType,
    Choice,
    SequenceOf,
    SetOf,
    { A name that resolves to another assignment in this module. }
    Reference);

  { A lower and an upper bound, either of which may be absent - which is what
    MIN and MAX mean. }
  TAsn1Constraint = record
  public
    Present: Boolean;
    HasLower: Boolean;
    HasUpper: Boolean;
    Lower: Int64;
    Upper: Int64;
    class function None: TAsn1Constraint; static;
    class function Range(AHasLower: Boolean; ALower: Int64;
      AHasUpper: Boolean; AUpper: Int64): TAsn1Constraint; static;
    function Admits(AValue: Int64): Boolean;
    function Describe: string;
  end;

  TAsn1NamedNumber = record
    Name: string;
    Value: Int64;
  end;

  TAsn1TypeDef = class;

  { One component of a SEQUENCE or SET, or one alternative of a CHOICE. }
  TAsn1Component = class
  strict private
    FName: string;
    FTypeDef: TAsn1TypeDef;
    FTagged: Boolean;
    FTagClass: TAsn1TagClass;
    FTagNumber: UInt64;
    FTagExplicit: Boolean;
    FOptional: Boolean;
    FDefaultValue: TAsn1Value;
  public
    constructor Create(const AName: string; ATypeDef: TAsn1TypeDef);
    destructor Destroy; override;
    procedure SetTag(ATagClass: TAsn1TagClass; ATagNumber: UInt64;
      AExplicit: Boolean);
    { Adopts AValue. }
    procedure SetDefault(AValue: TAsn1Value);
    procedure MarkOptional;

    property Name: string read FName;
    { Owned by this component. }
    property TypeDef: TAsn1TypeDef read FTypeDef;
    property Tagged: Boolean read FTagged;
    property TagClass: TAsn1TagClass read FTagClass;
    property TagNumber: UInt64 read FTagNumber;
    { Meaningful only when Tagged. }
    property TagExplicit: Boolean read FTagExplicit;
    property Optional: Boolean read FOptional;
    { Borrowed; nil when the component has no DEFAULT. A component with a
      DEFAULT is implicitly optional in the encoding, and under DER and CER
      a value equal to the default MUST be omitted. }
    property DefaultValue: TAsn1Value read FDefaultValue;
    function HasDefault: Boolean;
  end;

  TAsn1Schema = class;

  { A type, named or anonymous. A named one is an assignment in the module;
    an anonymous one is the type of a component or the element type of a
    SEQUENCE OF. }
  TAsn1TypeDef = class
  strict private
    FName: string;
    FTypeKind: TAsn1TypeKind;
    FBaseKind: TAsn1Kind;
    FReferenceName: string;
    FComponents: TObjectList<TAsn1Component>;
    FElementType: TAsn1TypeDef;
    FSizeConstraint: TAsn1Constraint;
    FValueConstraint: TAsn1Constraint;
    FNamedNumbers: TArray<TAsn1NamedNumber>;
    function GetComponent(AIndex: Integer): TAsn1Component;
    function GetComponentCount: Integer;
  public
    constructor Create(const AName: string; ATypeKind: TAsn1TypeKind);
    destructor Destroy; override;

    { Adopts AComponent. }
    procedure AddComponent(AComponent: TAsn1Component);
    function FindComponent(const AName: string): TAsn1Component;
    function IndexOfComponent(const AName: string): Integer;
    { Adopts ATypeDef. }
    procedure SetElementType(ATypeDef: TAsn1TypeDef);
    procedure SetBaseKind(AKind: TAsn1Kind);
    procedure SetReferenceName(const AName: string);
    procedure SetSizeConstraint(const AConstraint: TAsn1Constraint);
    procedure SetValueConstraint(const AConstraint: TAsn1Constraint);
    procedure SetNamedNumbers(const AValues: TArray<TAsn1NamedNumber>);
    function FindNamedNumber(const AName: string; out AValue: Int64): Boolean;

    { Follows a chain of Reference assignments to the type that actually has
      a shape. Raises when the chain is broken or circular. }
    function Resolve(ASchema: TAsn1Schema): TAsn1TypeDef;
    function Describe: string;

    { '' for an anonymous type. }
    property Name: string read FName;
    property TypeKind: TAsn1TypeKind read FTypeKind;
    { Meaningful when TypeKind is Base. }
    property BaseKind: TAsn1Kind read FBaseKind;
    property ReferenceName: string read FReferenceName;
    property ComponentCount: Integer read GetComponentCount;
    property Components[AIndex: Integer]: TAsn1Component read GetComponent;
    { Owned; nil unless TypeKind is SequenceOf or SetOf. }
    property ElementType: TAsn1TypeDef read FElementType;
    property SizeConstraint: TAsn1Constraint read FSizeConstraint;
    property ValueConstraint: TAsn1Constraint read FValueConstraint;
    property NamedNumbers: TArray<TAsn1NamedNumber> read FNamedNumbers;
  end;

  TAsn1Import = record
    ModuleName: string;
    ModuleOid: string;
    Symbols: TArray<string>;
  end;

  { An ASN.1 module, and the schema every schema-driven call in this library
    takes.

    ONE SCHEMA, THREE ENCODING RULES. A module describes types; BER, DER and
    CER are three ways of writing a value of one of those types down. So this
    class does not belong to one of the three, and Rule below only decides
    which TSerializationFormat value Format reports for the benefit of code
    that routes by format. The ASN.1 handlers accept this schema whichever of
    the three they are, because refusing a module for being labelled DER when
    the payload is BER would be refusing the same module for the same types.

    Lifetime: borrowed everywhere, like every TSerializationSchema. The caller
    that parsed it frees it. }
  TAsn1SerializationContext = class;

  TAsn1Schema = class(TSerializationSchema)
  strict private
    FModuleName: string;
    FModuleOid: string;
    FTagDefault: TAsn1TagDefault;
    FTypes: TObjectList<TAsn1TypeDef>;
    FIndex: TDictionary<string, TAsn1TypeDef>;
    FExportsAll: Boolean;
    FHasExports: Boolean;
    FExportedSymbols: TArray<string>;
    FImports: TArray<TAsn1Import>;
    FRootType: string;
    FRule: TAsn1EncodingRule;
    function GetType(AIndex: Integer): TAsn1TypeDef;
    function GetTypeCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;

    { Parses a whole module definition. Raises EAsn1SchemaError naming the
      line for anything outside the declared subset. }
    class function ParseModule(const AText: string): TAsn1Schema; static;
    { The subset above, as text, so a program can print what it supports. }
    class function SubsetDescription: string; static;

    { nil when the module has no such assignment. }
    function FindType(const AName: string): TAsn1TypeDef;
    { FindType, raising instead of returning nil. }
    function RequireType(const AName: string): TAsn1TypeDef;
    { Named IsExported rather than Exports: the latter is a reserved word
      in Delphi, and a method that cannot be declared is not an API. }
    function IsExported(const AName: string): Boolean;

    function Format: TSerializationFormat; override;
    function Describe: string; override;

    { Used only while building a schema by hand rather than by parsing. Adopts
      ATypeDef. }
    procedure AddType(ATypeDef: TAsn1TypeDef);
    procedure SetModuleName(const AName, AOid: string);
    procedure SetTagDefault(AValue: TAsn1TagDefault);
    procedure SetExports(AAll: Boolean; const ASymbols: TArray<string>);
    procedure SetImports(const AImports: TArray<TAsn1Import>);

    property ModuleName: string read FModuleName;
    property ModuleOid: string read FModuleOid;
    property TagDefault: TAsn1TagDefault read FTagDefault;
    property TypeCount: Integer read GetTypeCount;
    property Types[AIndex: Integer]: TAsn1TypeDef read GetType;
    property HasExports: Boolean read FHasExports;
    property ExportsAll: Boolean read FExportsAll;
    property ExportedSymbols: TArray<string> read FExportedSymbols;
    property Imports: TArray<TAsn1Import> read FImports;

    { Which assignment a payload holds. Nothing in an encoding says this - a
      SEQUENCE is a SEQUENCE - so the caller supplies it, either here or as an
      argument. When it is empty and the module has exactly one assignment,
      that one is used; otherwise the call raises rather than picking. }
    property RootType: string read FRootType write FRootType;
    { Which of the three encoding rules Format reports. It does not restrict
      what this schema can be used with. }
    property Rule: TAsn1EncodingRule read FRule write FRule;

    { A context naming ONE of this module's assignments.

      This is what a conversion travels with, and it is why a module may
      declare as many types as it likes. RootType above is a property of the
      SCHEMA and therefore shared by everything using it; a context is per
      conversion, so two conversions of the same module can name two
      different types and neither disturbs the other.

      The caller owns the result. The schema is BORROWED by it and is not
      freed with it - a module is expensive to parse and is meant to be used
      by many conversions. }
    function ForType(const ATypeName: string): TAsn1SerializationContext;
  end;

  { ---------------------------------------------------------------------
    ONE MODULE, MANY TYPES, ONE CONVERSION AT A TIME

    ASN.1 octets are anonymous and a module usually declares several
    assignments, so a conversion has to be told which one these octets are.
    The conversion options have nowhere to put a type NAME - it would mean
    nothing to the other nine formats - so it travels here, with the schema
    it belongs to.

    This is what lets a module used through the registry contain more than
    one type assignment.

    LIFETIME: the schema is BORROWED. Freeing a context does not free the
    module, because a module is expensive to parse and is meant to be shared
    by every conversion that uses it. }
  TAsn1SerializationContext = class(TSerializationContext)
  strict private
    FSchema: TAsn1Schema;
    FRootTypeName: string;
    FRule: TAsn1EncodingRule;
  public
    { ARootTypeName must name an assignment in ASchema; this raises if it
      does not, so a typo is found where it was made rather than as a
      mystery in the middle of a conversion. }
    constructor Create(ASchema: TAsn1Schema; const ARootTypeName: string;
      ARule: TAsn1EncodingRule = TAsn1EncodingRule.Der);

    function Format: TSerializationFormat; override;
    function Describe: string; override;

    property Schema: TAsn1Schema read FSchema;
    property RootTypeName: string read FRootTypeName;
    property Rule: TAsn1EncodingRule read FRule write FRule;
  end;

implementation

{ --- TAsn1Constraint ------------------------------------------------------ }

class function TAsn1Constraint.None: TAsn1Constraint;
begin
  Result.Present := False;
  Result.HasLower := False;
  Result.HasUpper := False;
  Result.Lower := 0;
  Result.Upper := 0;
end;

class function TAsn1Constraint.Range(AHasLower: Boolean; ALower: Int64;
  AHasUpper: Boolean; AUpper: Int64): TAsn1Constraint;
begin
  Result.Present := True;
  Result.HasLower := AHasLower;
  Result.HasUpper := AHasUpper;
  Result.Lower := ALower;
  Result.Upper := AUpper;
end;

function TAsn1Constraint.Admits(AValue: Int64): Boolean;
begin
  if not Present then Exit(True);
  if HasLower and (AValue < Lower) then Exit(False);
  if HasUpper and (AValue > Upper) then Exit(False);
  Result := True;
end;

function TAsn1Constraint.Describe: string;
var
  Low, High: string;
begin
  if not Present then Exit('unconstrained');
  if HasLower then Low := IntToStr(Lower) else Low := 'MIN';
  if HasUpper then High := IntToStr(Upper) else High := 'MAX';
  if HasLower and HasUpper and (Lower = Upper) then Exit(Low);
  Result := Low + '..' + High;
end;

{ --- TAsn1Component ------------------------------------------------------- }

constructor TAsn1Component.Create(const AName: string;
  ATypeDef: TAsn1TypeDef);
begin
  inherited Create;
  FName := AName;
  FTypeDef := ATypeDef;
  FTagExplicit := True;
end;

destructor TAsn1Component.Destroy;
begin
  FDefaultValue.Free;
  FTypeDef.Free;
  inherited;
end;

procedure TAsn1Component.SetTag(ATagClass: TAsn1TagClass; ATagNumber: UInt64;
  AExplicit: Boolean);
begin
  FTagged := True;
  FTagClass := ATagClass;
  FTagNumber := ATagNumber;
  FTagExplicit := AExplicit;
end;

procedure TAsn1Component.SetDefault(AValue: TAsn1Value);
begin
  FDefaultValue.Free;
  FDefaultValue := AValue;
end;

procedure TAsn1Component.MarkOptional;
begin
  FOptional := True;
end;

function TAsn1Component.HasDefault: Boolean;
begin
  Result := FDefaultValue <> nil;
end;

{ --- TAsn1TypeDef --------------------------------------------------------- }

constructor TAsn1TypeDef.Create(const AName: string;
  ATypeKind: TAsn1TypeKind);
begin
  inherited Create;
  FName := AName;
  FTypeKind := ATypeKind;
  FBaseKind := TAsn1Kind.Unknown;
  FSizeConstraint := TAsn1Constraint.None;
  FValueConstraint := TAsn1Constraint.None;
  if ATypeKind in [TAsn1TypeKind.Sequence, TAsn1TypeKind.SetType,
                   TAsn1TypeKind.Choice] then
    FComponents := TObjectList<TAsn1Component>.Create(True);
end;

destructor TAsn1TypeDef.Destroy;
begin
  FComponents.Free;
  FElementType.Free;
  inherited;
end;

function TAsn1TypeDef.GetComponentCount: Integer;
begin
  if FComponents = nil then Result := 0 else Result := Integer(FComponents.Count);
end;

function TAsn1TypeDef.GetComponent(AIndex: Integer): TAsn1Component;
begin
  if (FComponents = nil) or (AIndex < 0) or (AIndex >= FComponents.Count) then
    raise EAsn1SchemaError.CreateFmt(
      'Component %d does not exist in %s.', [AIndex, Describe]);
  Result := FComponents[AIndex];
end;

procedure TAsn1TypeDef.AddComponent(AComponent: TAsn1Component);
begin
  if FComponents = nil then
  begin
    AComponent.Free;
    raise EAsn1SchemaError.CreateFmt(
      '%s has no components.', [Describe]);
  end;
  FComponents.Add(AComponent);
end;

function TAsn1TypeDef.IndexOfComponent(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to ComponentCount - 1 do
    if Components[I].Name = AName then Exit(I);
  Result := -1;
end;

function TAsn1TypeDef.FindComponent(const AName: string): TAsn1Component;
var
  I: Integer;
begin
  I := IndexOfComponent(AName);
  if I < 0 then Result := nil else Result := Components[I];
end;

procedure TAsn1TypeDef.SetElementType(ATypeDef: TAsn1TypeDef);
begin
  FElementType.Free;
  FElementType := ATypeDef;
end;

procedure TAsn1TypeDef.SetBaseKind(AKind: TAsn1Kind);
begin
  FBaseKind := AKind;
end;

procedure TAsn1TypeDef.SetReferenceName(const AName: string);
begin
  FReferenceName := AName;
end;

procedure TAsn1TypeDef.SetSizeConstraint(const AConstraint: TAsn1Constraint);
begin
  FSizeConstraint := AConstraint;
end;

procedure TAsn1TypeDef.SetValueConstraint(const AConstraint: TAsn1Constraint);
begin
  FValueConstraint := AConstraint;
end;

procedure TAsn1TypeDef.SetNamedNumbers(const AValues: TArray<TAsn1NamedNumber>);
begin
  FNamedNumbers := AValues;
end;

function TAsn1TypeDef.FindNamedNumber(const AName: string;
  out AValue: Int64): Boolean;
var
  I: Integer;
begin
  for I := 0 to Integer(High(FNamedNumbers)) do
    if FNamedNumbers[I].Name = AName then
    begin
      AValue := FNamedNumbers[I].Value;
      Exit(True);
    end;
  AValue := 0;
  Result := False;
end;

function TAsn1TypeDef.Resolve(ASchema: TAsn1Schema): TAsn1TypeDef;
var
  Steps: Integer;
begin
  Result := Self;
  Steps := 0;
  while Result.TypeKind = TAsn1TypeKind.Reference do
  begin
    Inc(Steps);
    if Steps > 64 then
      raise EAsn1SchemaError.CreateFmt(
        'The type reference chain starting at %s does not terminate; the ' +
        'module defines it in terms of itself.', [Describe]);
    Result := ASchema.RequireType(Result.ReferenceName);
  end;
end;

function TAsn1TypeDef.Describe: string;
var
  Base: string;
begin
  case FTypeKind of
    TAsn1TypeKind.Base:       Base := Asn1KindName(FBaseKind);
    TAsn1TypeKind.Sequence:   Base := 'SEQUENCE';
    TAsn1TypeKind.SetType:    Base := 'SET';
    TAsn1TypeKind.Choice:     Base := 'CHOICE';
    TAsn1TypeKind.SequenceOf: Base := 'SEQUENCE OF';
    TAsn1TypeKind.SetOf:      Base := 'SET OF';
  else
    Base := 'the type reference ' + FReferenceName;
  end;
  if FName = '' then Result := Base else Result := FName + ' (' + Base + ')';
end;

{ ===========================================================================
  THE MODULE PARSER
  =========================================================================== }

type
  TAsn1TokenKind = (EndOfText, Identifier, Number, Punctuation, CharString,
    BinaryString, HexString);

  TAsn1Token = record
    Kind: TAsn1TokenKind;
    Text: string;
    Value: Int64;
    Line: Integer;
  end;

  TAsn1Lexer = class
  strict private
    FText: string;
    FPos: Integer;
    FLine: Integer;
    procedure SkipTrivia;
    function PeekChar(AOffset: Integer): Char;
    procedure Fail(const AMessage: string);
  public
    constructor Create(const AText: string);
    function Next: TAsn1Token;
    property Line: Integer read FLine;
  end;

  { Recursive descent over the subset declared in this unit's header. Every
    production that meets something it does not implement raises rather than
    resynchronizing: a module is small and read once, so failing loudly costs
    nothing and guessing costs correctness. }
  TAsn1ModuleParser = class
  strict private
    FLexer: TAsn1Lexer;
    FToken: TAsn1Token;
    FAhead: TArray<TAsn1Token>;
    FSchema: TAsn1Schema;
    procedure Advance;
    function Peek(AOffset: Integer): TAsn1Token;
    function AtWord(const AWord: string): Boolean;
    function AtPunct(const APunct: string): Boolean;
    procedure Expect(const APunct: string);
    procedure ExpectWord(const AWord: string);
    function TakeIdentifier: string;
    function TakeNumber: Int64;
    procedure Fail(const AMessage: string);
    procedure Refuse(const AConstruct, AWhy: string);

    procedure ParseHeader;
    procedure ParseDefinitiveIdentifier;
    procedure ParseExports;
    procedure ParseImports;
    procedure ParseAssignments;
    function ParseType(const AName: string): TAsn1TypeDef;
    function ParseBuiltinType(const AName: string): TAsn1TypeDef;
    procedure ParseComponentList(ATypeDef: TAsn1TypeDef);
    function ParseComponent: TAsn1Component;
    function ParseNamedNumberList: TArray<TAsn1NamedNumber>;
    function ParseConstraint(ATypeDef: TAsn1TypeDef): Boolean;
    function ParseValueRange: TAsn1Constraint;
    function ParseDefaultValue(ATypeDef: TAsn1TypeDef): TAsn1Value;
    procedure ApplyAutomaticTags;
    procedure ApplyAutomaticTagsTo(ATypeDef: TAsn1TypeDef);
  public
    constructor Create(const AText: string);
    destructor Destroy; override;
    function Parse: TAsn1Schema;
  end;

const
  { Names X.680 defines that this parser does not implement. Refusing them by
    name is the difference between a subset and a parser that mis-reads. }
  UnsupportedTypeNames: array[0..11] of string = (
    'ANY', 'EXTERNAL', 'CHARACTER', 'ObjectDescriptor',
    'GraphicString', 'VideotexString', 'T61String', 'ISO646String',
    'EMBEDDED', 'INSTANCE', 'OID-IRI', 'RELATIVE-OID-IRI');

{ --- TAsn1Lexer ----------------------------------------------------------- }

constructor TAsn1Lexer.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
  FPos := Low(string);
  FLine := 1;
end;

procedure TAsn1Lexer.Fail(const AMessage: string);
begin
  raise EAsn1SchemaError.CreateFmt('Line %d: %s', [FLine, AMessage]);
end;

function TAsn1Lexer.PeekChar(AOffset: Integer): Char;
begin
  if FPos + AOffset > High(FText) then Result := #0
  else Result := FText[FPos + AOffset];
end;

procedure TAsn1Lexer.SkipTrivia;
var
  Depth: Integer;
begin
  while FPos <= High(FText) do
  begin
    if FText[FPos] = #10 then
    begin
      Inc(FLine);
      Inc(FPos);
    end
    else if CharInSet(FText[FPos], [#9, #13, ' ']) then
      Inc(FPos)
    else if (FText[FPos] = '-') and (PeekChar(1) = '-') then
    begin
      { A one-line comment ends at the end of the line OR at a second pair of
        hyphens, which is what X.680 says and what nothing else does. }
      Inc(FPos, 2);
      while FPos <= High(FText) do
      begin
        if FText[FPos] = #10 then Break;
        if (FText[FPos] = '-') and (PeekChar(1) = '-') then
        begin
          Inc(FPos, 2);
          Break;
        end;
        Inc(FPos);
      end;
    end
    else if (FText[FPos] = '/') and (PeekChar(1) = '*') then
    begin
      Depth := 1;
      Inc(FPos, 2);
      while (FPos <= High(FText)) and (Depth > 0) do
      begin
        if FText[FPos] = #10 then Inc(FLine);
        if (FText[FPos] = '/') and (PeekChar(1) = '*') then
        begin
          Inc(Depth);
          Inc(FPos, 2);
        end
        else if (FText[FPos] = '*') and (PeekChar(1) = '/') then
        begin
          Dec(Depth);
          Inc(FPos, 2);
        end
        else
          Inc(FPos);
      end;
      if Depth > 0 then Fail('a block comment is never closed');
    end
    else
      Break;
  end;
end;

function TAsn1Lexer.Next: TAsn1Token;
var
  Start: Integer;
  Quote: Char;
  Body: string;
  I: Integer;
begin
  SkipTrivia;
  Result.Kind := TAsn1TokenKind.EndOfText;
  Result.Text := '';
  Result.Value := 0;
  Result.Line := FLine;
  if FPos > High(FText) then Exit;

  if CharInSet(FText[FPos], ['A'..'Z', 'a'..'z']) then
  begin
    Start := FPos;
    while FPos <= High(FText) do
    begin
      if CharInSet(FText[FPos], ['A'..'Z', 'a'..'z', '0'..'9']) then
        Inc(FPos)
      else if (FText[FPos] = '-') and
              CharInSet(PeekChar(1), ['A'..'Z', 'a'..'z', '0'..'9']) then
        Inc(FPos, 2)
      else
        Break;
    end;
    Result.Kind := TAsn1TokenKind.Identifier;
    Result.Text := Copy(FText, Start, FPos - Start);
    Exit;
  end;

  if CharInSet(FText[FPos], ['0'..'9']) then
  begin
    Start := FPos;
    while (FPos <= High(FText)) and CharInSet(FText[FPos], ['0'..'9']) do
      Inc(FPos);
    Result.Kind := TAsn1TokenKind.Number;
    Result.Text := Copy(FText, Start, FPos - Start);
    if not TryStrToInt64(Result.Text, Result.Value) then
      Fail(System.SysUtils.Format(
        'the number %s is larger than this parser carries; a constraint ' +
        'bound and a tag number are Int64 here', [Result.Text]));
    Exit;
  end;

  if FText[FPos] = '"' then
  begin
    Inc(FPos);
    Body := '';
    while FPos <= High(FText) do
    begin
      if FText[FPos] = '"' then
      begin
        if PeekChar(1) = '"' then
        begin
          Body := Body + '"';
          Inc(FPos, 2);
          Continue;
        end;
        Inc(FPos);
        Result.Kind := TAsn1TokenKind.CharString;
        Result.Text := Body;
        Exit;
      end;
      if FText[FPos] = #10 then Inc(FLine);
      Body := Body + FText[FPos];
      Inc(FPos);
    end;
    Fail('a character string is never closed');
  end;

  if FText[FPos] = '''' then
  begin
    Inc(FPos);
    Body := '';
    while (FPos <= High(FText)) and (FText[FPos] <> '''') do
    begin
      if not CharInSet(FText[FPos], [#9, #10, #13, ' ']) then
        Body := Body + FText[FPos];
      if FText[FPos] = #10 then Inc(FLine);
      Inc(FPos);
    end;
    if FPos > High(FText) then Fail('a binary or hexadecimal string is never closed');
    Inc(FPos);
    Quote := #0;
    if FPos <= High(FText) then Quote := UpCase(FText[FPos]);
    if Quote = 'B' then
    begin
      Inc(FPos);
      for I := Low(string) to High(Body) do
        if not CharInSet(Body[I], ['0', '1']) then
          Fail('a binary string holds only 0 and 1');
      Result.Kind := TAsn1TokenKind.BinaryString;
    end
    else if Quote = 'H' then
    begin
      Inc(FPos);
      for I := Low(string) to High(Body) do
        if not CharInSet(Body[I], ['0'..'9', 'A'..'F', 'a'..'f']) then
          Fail('a hexadecimal string holds only hexadecimal digits');
      Result.Kind := TAsn1TokenKind.HexString;
    end
    else
      Fail('a quoted string must be followed by B or H');
    Result.Text := Body;
    Exit;
  end;

  Result.Kind := TAsn1TokenKind.Punctuation;
  if (FText[FPos] = ':') and (PeekChar(1) = ':') and (PeekChar(2) = '=') then
  begin
    Result.Text := '::=';
    Inc(FPos, 3);
    Exit;
  end;
  if (FText[FPos] = '.') and (PeekChar(1) = '.') and (PeekChar(2) = '.') then
  begin
    Result.Text := '...';
    Inc(FPos, 3);
    Exit;
  end;
  if (FText[FPos] = '.') and (PeekChar(1) = '.') then
  begin
    Result.Text := '..';
    Inc(FPos, 2);
    Exit;
  end;
  if (FText[FPos] = '[') and (PeekChar(1) = '[') then
  begin
    Result.Text := '[[';
    Inc(FPos, 2);
    Exit;
  end;
  Result.Text := FText[FPos];
  Inc(FPos);
end;

{ --- TAsn1ModuleParser ---------------------------------------------------- }

constructor TAsn1ModuleParser.Create(const AText: string);
begin
  inherited Create;
  FLexer := TAsn1Lexer.Create(AText);
  FSchema := TAsn1Schema.Create;
  FToken := FLexer.Next;
end;

destructor TAsn1ModuleParser.Destroy;
begin
  FLexer.Free;
  FSchema.Free;
  inherited;
end;

procedure TAsn1ModuleParser.Advance;
begin
  if Length(FAhead) > 0 then
  begin
    FToken := FAhead[0];
    Delete(FAhead, 0, 1);
  end
  else
    FToken := FLexer.Next;
end;

function TAsn1ModuleParser.Peek(AOffset: Integer): TAsn1Token;
begin
  if AOffset = 0 then Exit(FToken);
  while Length(FAhead) < AOffset do
  begin
    SetLength(FAhead, Length(FAhead) + 1);
    FAhead[High(FAhead)] := FLexer.Next;
  end;
  Result := FAhead[AOffset - 1];
end;

function TAsn1ModuleParser.AtWord(const AWord: string): Boolean;
begin
  Result := (FToken.Kind = TAsn1TokenKind.Identifier) and (FToken.Text = AWord);
end;

function TAsn1ModuleParser.AtPunct(const APunct: string): Boolean;
begin
  Result := (FToken.Kind = TAsn1TokenKind.Punctuation) and
    (FToken.Text = APunct);
end;

procedure TAsn1ModuleParser.Fail(const AMessage: string);
var
  Found: string;
begin
  if FToken.Kind = TAsn1TokenKind.EndOfText then Found := 'the end of the module'
  else Found := '"' + FToken.Text + '"';
  raise EAsn1SchemaError.CreateFmt('Line %d: %s, but found %s.',
    [FToken.Line, AMessage, Found]);
end;

procedure TAsn1ModuleParser.Refuse(const AConstruct, AWhy: string);
begin
  raise EAsn1SchemaError.CreateFmt(
    'Line %d: %s is outside the subset of X.680 this parser implements. %s' +
    sLineBreak + sLineBreak +
    'The parser refuses what it does not implement rather than skipping it, ' +
    'because a module that half-parsed would produce an encoder that writes ' +
    'the wrong octets. TAsn1Schema.SubsetDescription lists what is ' +
    'supported.', [FToken.Line, AConstruct, AWhy]);
end;

procedure TAsn1ModuleParser.Expect(const APunct: string);
begin
  if not AtPunct(APunct) then Fail('expected "' + APunct + '"');
  Advance;
end;

procedure TAsn1ModuleParser.ExpectWord(const AWord: string);
begin
  if not AtWord(AWord) then Fail('expected ' + AWord);
  Advance;
end;

function TAsn1ModuleParser.TakeIdentifier: string;
begin
  if FToken.Kind <> TAsn1TokenKind.Identifier then Fail('expected a name');
  Result := FToken.Text;
  Advance;
end;

function TAsn1ModuleParser.TakeNumber: Int64;
begin
  if FToken.Kind <> TAsn1TokenKind.Number then Fail('expected a number');
  Result := FToken.Value;
  Advance;
end;

function TAsn1ModuleParser.Parse: TAsn1Schema;
begin
  ParseHeader;
  ParseExports;
  ParseImports;
  ParseAssignments;
  ExpectWord('END');
  if FToken.Kind <> TAsn1TokenKind.EndOfText then
    Fail('expected nothing after END');
  if FSchema.TagDefault = TAsn1TagDefault.AutomaticTags then ApplyAutomaticTags;
  Result := FSchema;
  FSchema := nil;
end;

procedure TAsn1ModuleParser.ParseHeader;
var
  ModuleName, Oid: string;
  Tagging: TAsn1TagDefault;
begin
  ModuleName := TakeIdentifier;
  Oid := '';
  if AtPunct('{') then
  begin
    ParseDefinitiveIdentifier;
    Oid := FSchema.ModuleOid;
  end;
  ExpectWord('DEFINITIONS');
  Tagging := TAsn1TagDefault.ExplicitTags;
  if AtWord('EXPLICIT') or AtWord('IMPLICIT') or AtWord('AUTOMATIC') then
  begin
    if AtWord('IMPLICIT') then Tagging := TAsn1TagDefault.ImplicitTags
    else if AtWord('AUTOMATIC') then Tagging := TAsn1TagDefault.AutomaticTags;
    Advance;
    ExpectWord('TAGS');
  end;
  if AtWord('EXTENSIBILITY') then
    Refuse('EXTENSIBILITY IMPLIED',
      'It makes every structured type in the module extensible, which ' +
      'changes how an unknown trailing component is treated.');
  FSchema.SetModuleName(ModuleName, Oid);
  FSchema.SetTagDefault(Tagging);
  Expect('::=');
  ExpectWord('BEGIN');
end;

procedure TAsn1ModuleParser.ParseDefinitiveIdentifier;
var
  Parts: TArray<string>;
  Arc: string;
begin
  Expect('{');
  Parts := nil;
  while not AtPunct('}') do
  begin
    if FToken.Kind = TAsn1TokenKind.EndOfText then
      Fail('expected "}" closing the module object identifier');
    if FToken.Kind = TAsn1TokenKind.Number then
    begin
      Parts := Parts + [FToken.Text];
      Advance;
    end
    else
    begin
      Arc := TakeIdentifier;
      if AtPunct('(') then
      begin
        Advance;
        Parts := Parts + [IntToStr(TakeNumber)];
        Expect(')');
      end
      else
        { A bare name arc - iso, member-body - carries no number here, so the
          name is kept as written rather than being resolved against a
          registry this library does not have. }
        Parts := Parts + [Arc];
    end;
  end;
  Expect('}');
  FSchema.SetModuleName(FSchema.ModuleName, string.Join('.', Parts));
end;

procedure TAsn1ModuleParser.ParseExports;
var
  Symbols: TArray<string>;
begin
  if not AtWord('EXPORTS') then Exit;
  Advance;
  if AtWord('ALL') then
  begin
    Advance;
    Expect(';');
    FSchema.SetExports(True, nil);
    Exit;
  end;
  Symbols := nil;
  while not AtPunct(';') do
  begin
    if FToken.Kind = TAsn1TokenKind.EndOfText then
      Fail('expected ";" ending the EXPORTS clause');
    if AtPunct(',') then Advance
    else if AtPunct('{') then
    begin
      { A name followed by empty braces marks an exported parameterized
        reference. }
      Advance;
      Expect('}');
    end
    else
      Symbols := Symbols + [TakeIdentifier];
  end;
  Expect(';');
  FSchema.SetExports(False, Symbols);
end;

procedure TAsn1ModuleParser.ParseImports;
var
  All: TArray<TAsn1Import>;
  Current: TAsn1Import;
  Oid: TArray<string>;
begin
  if not AtWord('IMPORTS') then Exit;
  Advance;
  All := nil;
  while not AtPunct(';') do
  begin
    if FToken.Kind = TAsn1TokenKind.EndOfText then
      Fail('expected ";" ending the IMPORTS clause');
    Current := Default(TAsn1Import);
    while not AtWord('FROM') do
    begin
      if FToken.Kind = TAsn1TokenKind.EndOfText then
        Fail('expected FROM in the IMPORTS clause');
      if AtPunct(',') then Advance
      else if AtPunct('{') then
      begin
        Advance;
        Expect('}');
      end
      else
        Current.Symbols := Current.Symbols + [TakeIdentifier];
    end;
    ExpectWord('FROM');
    Current.ModuleName := TakeIdentifier;
    if AtPunct('{') then
    begin
      Advance;
      Oid := nil;
      while not AtPunct('}') do
      begin
        if FToken.Kind = TAsn1TokenKind.EndOfText then
          Fail('expected "}" closing an imported module object identifier');
        if FToken.Kind = TAsn1TokenKind.Number then
        begin
          Oid := Oid + [FToken.Text];
          Advance;
        end
        else
        begin
          Oid := Oid + [TakeIdentifier];
          if AtPunct('(') then
          begin
            Advance;
            Oid[High(Oid)] := IntToStr(TakeNumber);
            Expect(')');
          end;
        end;
      end;
      Expect('}');
      Current.ModuleOid := string.Join('.', Oid);
    end;
    All := All + [Current];
  end;
  Expect(';');
  FSchema.SetImports(All);
end;

procedure TAsn1ModuleParser.ParseAssignments;
var
  Name: string;
  Def: TAsn1TypeDef;
begin
  while not AtWord('END') do
  begin
    if FToken.Kind = TAsn1TokenKind.EndOfText then
      Fail('expected END closing the module');
    if FToken.Kind <> TAsn1TokenKind.Identifier then
      Fail('expected a type assignment');

    { A type assignment starts with an upper-case reference; anything else
      starting an assignment is a value, a value set or an object class, and
      those are refused by name rather than mis-read as a type. }
    Name := FToken.Text;
    if not CharInSet(Name[Low(string)], ['A'..'Z']) then
      Refuse('a value assignment (' + Name + ')',
        'Only type assignments are parsed. A DEFAULT value is written ' +
        'inline at the component that uses it.');
    if Peek(1).Text = '{' then
      Refuse('a parameterized type assignment (' + Name + ')',
        'Parameterization is X.683 and needs an instantiation machinery ' +
        'this library does not have.');
    if (Peek(1).Kind = TAsn1TokenKind.Identifier) and
       (Peek(2).Text = '::=') then
      Refuse('a value assignment (' + Name + ')',
        'Only type assignments are parsed.');
    Advance;
    Expect('::=');
    if AtWord('CLASS') then
      Refuse('an information object class',
        'X.681 object classes describe tables of types and values, not a ' +
        'data structure to encode.');
    Def := ParseType(Name);
    FSchema.AddType(Def);
  end;
end;

function TAsn1ModuleParser.ParseType(const AName: string): TAsn1TypeDef;
begin
  Result := ParseBuiltinType(AName);
  try
    while ParseConstraint(Result) do ;
  except
    Result.Free;
    raise;
  end;
end;

function TAsn1ModuleParser.ParseBuiltinType(const AName: string): TAsn1TypeDef;
var
  Word: string;
  I: Integer;
  Element: TAsn1TypeDef;
  Size: TAsn1Constraint;

  function MakeBase(AKind: TAsn1Kind): TAsn1TypeDef;
  begin
    Result := TAsn1TypeDef.Create(AName, TAsn1TypeKind.Base);
    Result.SetBaseKind(AKind);
  end;

begin
  if FToken.Kind <> TAsn1TokenKind.Identifier then Fail('expected a type');
  Word := FToken.Text;

  for I := Low(UnsupportedTypeNames) to High(UnsupportedTypeNames) do
    if Word = UnsupportedTypeNames[I] then
      Refuse('the type ' + Word,
        'This library has no encoder for it, so accepting it in a module ' +
        'would only postpone the failure to encoding time.');
  if Word = 'COMPONENTS' then
    Refuse('COMPONENTS OF',
      'It splices another type''s components in, which needs the whole ' +
      'module resolved before any type has a shape.');

  if Word = 'BOOLEAN' then begin Advance; Exit(MakeBase(TAsn1Kind.BooleanValue)); end;
  if Word = 'NULL' then begin Advance; Exit(MakeBase(TAsn1Kind.NullValue)); end;
  if Word = 'UTF8String' then begin Advance; Exit(MakeBase(TAsn1Kind.Utf8String)); end;
  if Word = 'NumericString' then begin Advance; Exit(MakeBase(TAsn1Kind.NumericString)); end;
  if Word = 'PrintableString' then begin Advance; Exit(MakeBase(TAsn1Kind.PrintableString)); end;
  if Word = 'IA5String' then begin Advance; Exit(MakeBase(TAsn1Kind.Ia5String)); end;
  if Word = 'VisibleString' then begin Advance; Exit(MakeBase(TAsn1Kind.VisibleString)); end;
  if Word = 'BMPString' then begin Advance; Exit(MakeBase(TAsn1Kind.BmpString)); end;
  if Word = 'UniversalString' then begin Advance; Exit(MakeBase(TAsn1Kind.UniversalString)); end;
  if Word = 'TeletexString' then begin Advance; Exit(MakeBase(TAsn1Kind.TeletexString)); end;
  if Word = 'GeneralString' then begin Advance; Exit(MakeBase(TAsn1Kind.GeneralString)); end;
  if Word = 'UTCTime' then begin Advance; Exit(MakeBase(TAsn1Kind.UtcTime)); end;
  if Word = 'GeneralizedTime' then begin Advance; Exit(MakeBase(TAsn1Kind.GeneralizedTime)); end;
  if Word = 'RELATIVE-OID' then begin Advance; Exit(MakeBase(TAsn1Kind.RelativeOid)); end;

  if Word = 'INTEGER' then
  begin
    Advance;
    Result := MakeBase(TAsn1Kind.IntegerValue);
    if AtPunct('{') then
      try
        Result.SetNamedNumbers(ParseNamedNumberList);
      except
        Result.Free;
        raise;
      end;
    Exit;
  end;

  if Word = 'REAL' then
  begin
    Advance;
    Exit(MakeBase(TAsn1Kind.RealValue));
  end;

  if Word = 'ENUMERATED' then
  begin
    Advance;
    Result := MakeBase(TAsn1Kind.Enumerated);
    try
      if not AtPunct('{') then Fail('expected "{" after ENUMERATED');
      Result.SetNamedNumbers(ParseNamedNumberList);
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  if Word = 'BIT' then
  begin
    Advance;
    ExpectWord('STRING');
    Result := MakeBase(TAsn1Kind.BitString);
    if AtPunct('{') then
      try
        Result.SetNamedNumbers(ParseNamedNumberList);
      except
        Result.Free;
        raise;
      end;
    Exit;
  end;

  if Word = 'OCTET' then
  begin
    Advance;
    ExpectWord('STRING');
    Exit(MakeBase(TAsn1Kind.OctetString));
  end;

  if Word = 'OBJECT' then
  begin
    Advance;
    ExpectWord('IDENTIFIER');
    Exit(MakeBase(TAsn1Kind.Oid));
  end;

  if (Word = 'SEQUENCE') or (Word = 'SET') then
  begin
    Advance;
    Size := TAsn1Constraint.None;
    if AtPunct('(') then
    begin
      { A size constraint written before OF belongs to the collection. }
      Advance;
      if not AtWord('SIZE') then Fail('expected SIZE');
      Advance;
      Expect('(');
      Size := ParseValueRange;
      Expect(')');
      Expect(')');
      if not AtWord('OF') then Fail('expected OF after a size constraint');
    end;
    if AtWord('OF') then
    begin
      Advance;
      if Word = 'SEQUENCE' then
        Result := TAsn1TypeDef.Create(AName, TAsn1TypeKind.SequenceOf)
      else
        Result := TAsn1TypeDef.Create(AName, TAsn1TypeKind.SetOf);
      try
        Result.SetSizeConstraint(Size);
        { X.680 lets the element carry a name, which is documentation only. }
        if (FToken.Kind = TAsn1TokenKind.Identifier) and
           CharInSet(FToken.Text[Low(string)], ['a'..'z']) and
           (Peek(1).Kind = TAsn1TokenKind.Identifier) then
          Advance;
        Element := ParseType('');
        Result.SetElementType(Element);
      except
        Result.Free;
        raise;
      end;
      Exit;
    end;
    if Word = 'SEQUENCE' then
      Result := TAsn1TypeDef.Create(AName, TAsn1TypeKind.Sequence)
    else
      Result := TAsn1TypeDef.Create(AName, TAsn1TypeKind.SetType);
    try
      ParseComponentList(Result);
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  if Word = 'CHOICE' then
  begin
    Advance;
    Result := TAsn1TypeDef.Create(AName, TAsn1TypeKind.Choice);
    try
      ParseComponentList(Result);
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;

  if not CharInSet(Word[Low(string)], ['A'..'Z']) then
    Fail('expected a type');
  Advance;
  if AtPunct('{') then
    Refuse('a parameterized type instantiation (' + Word + ')',
      'Parameterization is X.683.');
  if AtPunct('<') then
    Refuse('a selection type (' + Word + ')',
      'It names one alternative of a CHOICE defined elsewhere.');
  Result := TAsn1TypeDef.Create(AName, TAsn1TypeKind.Reference);
  Result.SetReferenceName(Word);
end;

procedure TAsn1ModuleParser.ParseComponentList(ATypeDef: TAsn1TypeDef);
begin
  Expect('{');
  if AtPunct('}') then
  begin
    Advance;
    Exit;
  end;
  while True do
  begin
    if AtPunct('...') then
      Refuse('the extension marker "..."',
        'An extensible type accepts components a decoder has never heard ' +
        'of, which changes what "this value does not match the schema" ' +
        'means.');
    if AtPunct('[[') then
      Refuse('a version bracket',
        'Version brackets group the components added in one revision of an ' +
        'extensible type.');
    ATypeDef.AddComponent(ParseComponent);
    if AtPunct(',') then
    begin
      Advance;
      Continue;
    end;
    Break;
  end;
  Expect('}');
end;

function TAsn1ModuleParser.ParseComponent: TAsn1Component;
var
  Name: string;
  TagClass: TAsn1TagClass;
  TagNumber: Int64;
  HasTag, TagExplicit: Boolean;
  Def: TAsn1TypeDef;
begin
  if FToken.Kind <> TAsn1TokenKind.Identifier then
    Fail('expected a component name');
  if not CharInSet(FToken.Text[Low(string)], ['a'..'z']) then
    Fail('expected a component name, which X.680 spells starting lower-case');
  Name := TakeIdentifier;

  HasTag := False;
  TagClass := TAsn1TagClass.ContextSpecific;
  TagNumber := 0;
  TagExplicit := FSchema.TagDefault <> TAsn1TagDefault.ImplicitTags;
  if AtPunct('[') then
  begin
    Advance;
    if AtWord('UNIVERSAL') then
    begin
      Advance;
      TagClass := TAsn1TagClass.Universal;
    end
    else if AtWord('APPLICATION') then
    begin
      Advance;
      TagClass := TAsn1TagClass.Application;
    end
    else if AtWord('PRIVATE') then
    begin
      Advance;
      TagClass := TAsn1TagClass.Private;
    end;
    TagNumber := TakeNumber;
    if TagNumber < 0 then Fail('a tag number is not negative');
    Expect(']');
    HasTag := True;
    if AtWord('EXPLICIT') then
    begin
      Advance;
      TagExplicit := True;
    end
    else if AtWord('IMPLICIT') then
    begin
      Advance;
      TagExplicit := False;
    end;
  end;

  Def := ParseType('');
  Result := TAsn1Component.Create(Name, Def);
  try
    if HasTag then Result.SetTag(TagClass, UInt64(TagNumber), TagExplicit);
    if AtWord('OPTIONAL') then
    begin
      Advance;
      Result.MarkOptional;
    end
    else if AtWord('DEFAULT') then
    begin
      Advance;
      Result.SetDefault(ParseDefaultValue(Def));
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TAsn1ModuleParser.ParseNamedNumberList: TArray<TAsn1NamedNumber>;
var
  Entry: TAsn1NamedNumber;
begin
  Expect('{');
  Result := nil;
  while True do
  begin
    if FToken.Kind = TAsn1TokenKind.EndOfText then
      Fail('expected "}" closing a named number list');
    if AtPunct('...') then
      Refuse('the extension marker "..."',
        'An extensible enumeration accepts values a decoder has never ' +
        'heard of.');
    Entry.Name := TakeIdentifier;
    Expect('(');
    if AtPunct('-') then
    begin
      Advance;
      Entry.Value := -TakeNumber;
    end
    else
      Entry.Value := TakeNumber;
    Expect(')');
    Result := Result + [Entry];
    if AtPunct(',') then
    begin
      Advance;
      Continue;
    end;
    Break;
  end;
  Expect('}');
end;

function TAsn1ModuleParser.ParseValueRange: TAsn1Constraint;
var
  HasLower, HasUpper: Boolean;
  Lower, Upper: Int64;
begin
  HasLower := True;
  Lower := 0;
  if AtWord('MIN') then
  begin
    Advance;
    HasLower := False;
  end
  else if AtPunct('-') then
  begin
    Advance;
    Lower := -TakeNumber;
  end
  else
    Lower := TakeNumber;

  if not AtPunct('..') then
    Exit(TAsn1Constraint.Range(HasLower, Lower, HasLower, Lower));

  Advance;
  HasUpper := True;
  Upper := 0;
  if AtWord('MAX') then
  begin
    Advance;
    HasUpper := False;
  end
  else if AtPunct('-') then
  begin
    Advance;
    Upper := -TakeNumber;
  end
  else
    Upper := TakeNumber;
  Result := TAsn1Constraint.Range(HasLower, Lower, HasUpper, Upper);
end;

function TAsn1ModuleParser.ParseConstraint(ATypeDef: TAsn1TypeDef): Boolean;
var
  IsSize: Boolean;
  Range: TAsn1Constraint;
begin
  if not AtPunct('(') then Exit(False);
  Advance;
  IsSize := AtWord('SIZE');
  if IsSize then
  begin
    Advance;
    Expect('(');
  end;
  if AtWord('WITH') then
    Refuse('a WITH COMPONENTS constraint',
      'It constrains the components of an inner type, which needs the ' +
      'constraint algebra of X.680 clause 51.');
  if AtWord('CONTAINING') or AtWord('ENCODED') then
    Refuse('a contents constraint',
      'CONTAINING says that an OCTET STRING holds the encoding of another ' +
      'type, which makes decoding depend on a second set of encoding ' +
      'rules.');
  Range := ParseValueRange;
  if AtPunct('|') or AtPunct('^') or AtWord('UNION') or
     AtWord('INTERSECTION') or AtWord('EXCEPT') then
    Refuse('a compound constraint',
      'Only a single range or size is honoured, and silently keeping one ' +
      'operand of a union would admit values the module forbids.');
  if IsSize then
  begin
    Expect(')');
    ATypeDef.SetSizeConstraint(Range);
  end
  else
    ATypeDef.SetValueConstraint(Range);
  Expect(')');
  Result := True;
end;

function TAsn1ModuleParser.ParseDefaultValue(ATypeDef: TAsn1TypeDef): TAsn1Value;
var
  Named: Int64;
  Name: string;
  Bits: TBytes;
  I, ByteIndex, BitIndex, Unused: Integer;
  Hex: string;
begin
  case FToken.Kind of
    TAsn1TokenKind.Number:
      begin
        if ATypeDef.BaseKind = TAsn1Kind.Enumerated then
          Result := TAsn1Value.NewEnumerated(FToken.Value)
        else
          Result := TAsn1Value.NewInteger(FToken.Value);
        Advance;
        Exit;
      end;
    TAsn1TokenKind.CharString:
      begin
        if not Asn1IsStringKind(ATypeDef.BaseKind) then
          Fail('a character string default belongs to a string type');
        Result := TAsn1Value.NewString(ATypeDef.BaseKind, FToken.Text);
        Advance;
        Exit;
      end;
    TAsn1TokenKind.BinaryString:
      begin
        Unused := (8 - (Length(FToken.Text) mod 8)) mod 8;
        SetLength(Bits, (Length(FToken.Text) + 7) div 8);
        for I := 0 to Integer(High(Bits)) do Bits[I] := 0;
        for I := 0 to Length(FToken.Text) - 1 do
        begin
          ByteIndex := I div 8;
          BitIndex := 7 - (I mod 8);
          if FToken.Text[Low(string) + I] = '1' then
            Bits[ByteIndex] := Byte(Bits[ByteIndex] or (1 shl BitIndex));
        end;
        if ATypeDef.BaseKind = TAsn1Kind.OctetString then
        begin
          if Unused <> 0 then
            Fail('an OCTET STRING default needs a whole number of octets');
          Result := TAsn1Value.NewOctetString(Bits);
        end
        else
          Result := TAsn1Value.NewBitString(Bits, Byte(Unused));
        Advance;
        Exit;
      end;
    TAsn1TokenKind.HexString:
      begin
        Hex := FToken.Text;
        if Odd(Length(Hex)) then
          Fail('a hexadecimal string needs an even number of digits');
        SetLength(Bits, Length(Hex) div 2);
        for I := 0 to Integer(High(Bits)) do
          Bits[I] := Byte(StrToInt('$' + Copy(Hex, Low(string) + I * 2, 2)));
        if ATypeDef.BaseKind = TAsn1Kind.BitString then
          Result := TAsn1Value.NewBitString(Bits, 0)
        else
          Result := TAsn1Value.NewOctetString(Bits);
        Advance;
        Exit;
      end;
    TAsn1TokenKind.Punctuation:
      if AtPunct('-') then
      begin
        Advance;
        if FToken.Kind <> TAsn1TokenKind.Number then Fail('expected a number');
        if ATypeDef.BaseKind = TAsn1Kind.Enumerated then
          Result := TAsn1Value.NewEnumerated(-FToken.Value)
        else
          Result := TAsn1Value.NewInteger(-FToken.Value);
        Advance;
        Exit;
      end
      else if AtPunct('{') then
        Refuse('a structured DEFAULT value',
          'Only a single scalar default is honoured; a default SEQUENCE ' +
          'would have to be encoded to be compared against, which the ' +
          'canonical rules make rule-dependent.');
  end;

  if FToken.Kind <> TAsn1TokenKind.Identifier then Fail('expected a value');
  Name := FToken.Text;
  if Name = 'TRUE' then
  begin
    Advance;
    Exit(TAsn1Value.NewBoolean(True));
  end;
  if Name = 'FALSE' then
  begin
    Advance;
    Exit(TAsn1Value.NewBoolean(False));
  end;
  if Name = 'NULL' then
  begin
    Advance;
    Exit(TAsn1Value.NewNull);
  end;
  if ATypeDef.FindNamedNumber(Name, Named) then
  begin
    Advance;
    if ATypeDef.BaseKind = TAsn1Kind.Enumerated then
      Exit(TAsn1Value.NewEnumerated(Named));
    Exit(TAsn1Value.NewInteger(Named));
  end;
  Refuse('a DEFAULT naming the value "' + Name + '"',
    'A default is a literal or a named number of this component''s own ' +
    'type; a reference to a value assignment elsewhere is not resolved, ' +
    'because value assignments are not parsed.');
  Result := nil;
end;

procedure TAsn1ModuleParser.ApplyAutomaticTags;
var
  I: Integer;
begin
  for I := 0 to FSchema.TypeCount - 1 do ApplyAutomaticTagsTo(FSchema.Types[I]);
end;

procedure TAsn1ModuleParser.ApplyAutomaticTagsTo(ATypeDef: TAsn1TypeDef);
var
  I: Integer;
  AnyTagged: Boolean;
  Comp: TAsn1Component;
  Inner: TAsn1TypeDef;
  UseExplicit: Boolean;
begin
  if ATypeDef = nil then Exit;
  if ATypeDef.ElementType <> nil then ApplyAutomaticTagsTo(ATypeDef.ElementType);
  if ATypeDef.ComponentCount = 0 then Exit;

  { X.680 clause 12.3: automatic tagging is applied to a structured type only
    when NONE of its components was tagged by hand. One hand-written tag turns
    the whole type back into a manually tagged one, which is the rule that
    stops a module from having two numbering schemes at once. }
  AnyTagged := False;
  for I := 0 to ATypeDef.ComponentCount - 1 do
    if ATypeDef.Components[I].Tagged then AnyTagged := True;

  for I := 0 to ATypeDef.ComponentCount - 1 do
  begin
    Comp := ATypeDef.Components[I];
    ApplyAutomaticTagsTo(Comp.TypeDef);
    if AnyTagged then Continue;
    { A CHOICE has no tag of its own - its tag is whichever alternative was
      selected - so an implicit tag would overwrite the one thing that says
      which. X.680 requires EXPLICIT there, and so does this. }
    Inner := Comp.TypeDef;
    UseExplicit := Inner.TypeKind = TAsn1TypeKind.Choice;
    if Inner.TypeKind = TAsn1TypeKind.Reference then
    begin
      Inner := FSchema.FindType(Inner.ReferenceName);
      UseExplicit := (Inner <> nil) and
        (Inner.TypeKind = TAsn1TypeKind.Choice);
    end;
    Comp.SetTag(TAsn1TagClass.ContextSpecific, UInt64(I), UseExplicit);
  end;
end;

{ --- TAsn1Schema ---------------------------------------------------------- }

constructor TAsn1Schema.Create;
begin
  inherited Create;
  FTypes := TObjectList<TAsn1TypeDef>.Create(True);
  FIndex := TDictionary<string, TAsn1TypeDef>.Create;
  FTagDefault := TAsn1TagDefault.ExplicitTags;
  FRule := TAsn1EncodingRule.Der;
end;

destructor TAsn1Schema.Destroy;
begin
  FIndex.Free;
  FTypes.Free;
  inherited;
end;

function TAsn1Schema.GetTypeCount: Integer;
begin
  Result := Integer(FTypes.Count);
end;

function TAsn1Schema.GetType(AIndex: Integer): TAsn1TypeDef;
begin
  Result := FTypes[AIndex];
end;

procedure TAsn1Schema.AddType(ATypeDef: TAsn1TypeDef);
begin
  if FIndex.ContainsKey(ATypeDef.Name) then
  begin
    ATypeDef.Free;
    raise EAsn1SchemaError.CreateFmt(
      'The module assigns the type %s twice. Which one a reference meant ' +
      'would depend on the order they were read in.', [ATypeDef.Name]);
  end;
  FTypes.Add(ATypeDef);
  FIndex.Add(ATypeDef.Name, ATypeDef);
end;

procedure TAsn1Schema.SetModuleName(const AName, AOid: string);
begin
  FModuleName := AName;
  FModuleOid := AOid;
end;

procedure TAsn1Schema.SetTagDefault(AValue: TAsn1TagDefault);
begin
  FTagDefault := AValue;
end;

procedure TAsn1Schema.SetExports(AAll: Boolean; const ASymbols: TArray<string>);
begin
  FHasExports := True;
  FExportsAll := AAll;
  FExportedSymbols := ASymbols;
end;

procedure TAsn1Schema.SetImports(const AImports: TArray<TAsn1Import>);
begin
  FImports := AImports;
end;

function TAsn1Schema.FindType(const AName: string): TAsn1TypeDef;
begin
  if not FIndex.TryGetValue(AName, Result) then Result := nil;
end;

function TAsn1Schema.RequireType(const AName: string): TAsn1TypeDef;
begin
  Result := FindType(AName);
  if Result = nil then
    raise EAsn1SchemaError.CreateFmt(
      'The module %s has no type called %s. It assigns: %s.',
      [FModuleName, AName, Describe]);
end;

function TAsn1Schema.IsExported(const AName: string): Boolean;
var
  I: Integer;
begin
  { A module with no EXPORTS clause exports everything, which is X.680's
    default and the opposite of what a reader expects, so it is stated. }
  if not FHasExports then Exit(True);
  if FExportsAll then Exit(True);
  for I := 0 to Integer(High(FExportedSymbols)) do
    if FExportedSymbols[I] = AName then Exit(True);
  Result := False;
end;

function TAsn1Schema.Format: TSerializationFormat;
begin
  Result := Asn1FormatOf(FRule);
end;

function TAsn1Schema.ForType(
  const ATypeName: string): TAsn1SerializationContext;
begin
  Result := TAsn1SerializationContext.Create(Self, ATypeName, FRule);
end;

{ --- TAsn1SerializationContext ------------------------------------------- }

constructor TAsn1SerializationContext.Create(ASchema: TAsn1Schema;
  const ARootTypeName: string; ARule: TAsn1EncodingRule);
begin
  inherited Create;
  if ASchema = nil then
    raise EAsn1SchemaError.Create(
      'An ASN.1 context needs the module its type is declared in.');
  { Checked here rather than at conversion time: a name that is not in the
    module is a caller mistake, and finding it at the call that made it is
    worth more than finding it three layers down. }
  ASchema.RequireType(ARootTypeName);
  FSchema := ASchema;
  FRootTypeName := ARootTypeName;
  FRule := ARule;
end;

function TAsn1SerializationContext.Format: TSerializationFormat;
begin
  Result := Asn1FormatOf(FRule);
end;

function TAsn1SerializationContext.Describe: string;
begin
  Result := System.SysUtils.Format('%s.%s',
    [FSchema.ModuleName, FRootTypeName]);
  if FSchema.ModuleName = '' then Result := FRootTypeName;
end;

function TAsn1Schema.Describe: string;
var
  I: Integer;
  Names: TArray<string>;
begin
  SetLength(Names, FTypes.Count);
  for I := 0 to Integer(FTypes.Count) - 1 do Names[I] := FTypes[I].Name;
  if FModuleName = '' then
    Result := System.SysUtils.Format('%d types', [FTypes.Count])
  else
    Result := System.SysUtils.Format('module %s, %d types: %s',
      [FModuleName, FTypes.Count, string.Join(', ', Names)]);
end;

class function TAsn1Schema.SubsetDescription: string;
begin
  Result :=
    'X.680 subset implemented by TAsn1Schema.ParseModule' + sLineBreak +
    sLineBreak +
    'Supported: module header with EXPLICIT TAGS, IMPLICIT TAGS or ' +
    'AUTOMATIC TAGS; a definitive object identifier; EXPORTS and IMPORTS; ' +
    'type assignments; SEQUENCE, SET, CHOICE, SEQUENCE OF and SET OF; ' +
    'BOOLEAN, INTEGER, BIT STRING, OCTET STRING, NULL, OBJECT IDENTIFIER, ' +
    'RELATIVE-OID, ENUMERATED, UTF8String, NumericString, PrintableString, ' +
    'IA5String, VisibleString, BMPString, UniversalString, TeletexString, ' +
    'GeneralString, UTCTime, GeneralizedTime; named number lists; type ' +
    'references; tags in all four classes with EXPLICIT and IMPLICIT; ' +
    'OPTIONAL and DEFAULT with scalar values; SIZE and value range ' +
    'constraints with MIN and MAX; both comment forms.' + sLineBreak +
    sLineBreak +
    'Refused by name, never skipped: ANY and ANY DEFINED BY; value ' +
    'assignments; parameterized types; information object classes; ' +
    'COMPONENTS OF; the extension marker and version brackets; WITH ' +
    'COMPONENTS; CONTAINING; compound constraints; selection types; ' +
    'EXTERNAL, EMBEDDED PDV, CHARACTER STRING, ObjectDescriptor, ' +
    'GraphicString, VideotexString, T61String, ISO646String, ' +
    'EXTENSIBILITY IMPLIED.' + sLineBreak +
    sLineBreak +
    'The encoding rules implemented are BER, DER and CER (X.690). PER ' +
    '(X.691) and OER (X.696) are out of scope.';
end;

class function TAsn1Schema.ParseModule(const AText: string): TAsn1Schema;
var
  Parser: TAsn1ModuleParser;
begin
  Parser := TAsn1ModuleParser.Create(AText);
  try
    Result := Parser.Parse;
  finally
    Parser.Free;
  end;
end;

end.
