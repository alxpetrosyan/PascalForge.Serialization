{*******************************************************************************
  PascalForge.Serialization.Core

  Shared foundation of PascalForge.Serialization. Used by every format unit;
  applications normally reach it through a format facade or
  PascalForge.Serialization.

  Responsibilities
    - Delphi type semantics shared by all formats: type names, nullable
      and container families, date/time policies.
    - Structural conversion options, routes and errors (the dynamic model
      the conversion carries is PascalForge.Dynamic).
    - The cycle and depth guard, ownership helpers, date and number text.
    - The format registry: TSerializationFormat, format handlers,
      capabilities and payloads.

  Registration
    The registry starts empty. A format joins only when the application
    calls T<Format>SerializationRegistration.RegisterFormat or
    TSerializationFormatsRegistration.RegisterAll; linking a unit registers
    nothing.

  Documentation
    docs/architecture.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Serialization.Core;

{$SCOPEDENUMS ON}

{ Small, stateless RTTI/name primitives shared by every serialization
  engine. They live here once so that the engines cannot drift apart on
  them.

  The single most important rule enforced here is that
  TRttiType.QualifiedName is NOT universally available: it raises
  ENonPublicType for any type declared in the implementation section of a
  unit (and for a type declared in a .dpr program file).  Nothing outside this
  unit should call QualifiedName directly. }

interface

uses
  System.SysUtils, System.Classes, System.TypInfo, System.Rtti,
  System.SyncObjs, System.DateUtils, System.Generics.Collections,
  { The structural model every format reads into and writes from. }
  PascalForge.Dynamic;

const
  { The library's version, in semantic-versioning form. While it is 0.x the
    public API may still change between minor versions. }
  PASCALFORGE_SERIALIZATION_VERSION = '0.9.0';

{ True when the type has a usable qualified name (i.e. it is declared in the
  interface section of a unit).  Never raises. }
function TryTypeQualifiedName(ATypeInfo: PTypeInfo; out AName: string): Boolean;

{ Declaring unit of a type.  Works without QualifiedName for classes,
  interfaces, enumerations and sets, whose unit name is carried by TTypeData.
  Record RTTI carries no unit name, so for a non-public record the caller may
  supply the owning scope's unit as AUnitHint.  Returns '' when the unit is
  genuinely not recoverable. }
function TypeUnitOf(ATypeInfo: PTypeInfo; const AUnitHint: string = ''): string;

{ Stable identity for a type, used as the key for name-scoped registrations.
  Public type            -> fully qualified name ('MyUnit.TFoo')
  Non-public, unit known -> 'MyUnit.TFoo' built from the recovered unit
  Non-public, unit not recoverable -> 'TFoo' (never '.TFoo')
  nil                    -> '' }
function TypeKeyOf(ATypeInfo: PTypeInfo; const AUnitHint: string = ''): string;

{ Owner.Member for an error message, or whichever of the two is known. }
function MemberDisplayName(const AOwner, AMember: string): string;

{ '*' wildcard matching, case-insensitive. }
function GlobMatch(const APattern, AText: string): Boolean;

{ Field/member pattern matching: '*' or an exact case-insensitive name. }
function FieldMatch(const APattern, AName: string): Boolean;

{ Identity of a closed generic specialization as declaring-unit + base name +
  arity, e.g. 'system.generics.collections|TObjectList|1'.  Works for classes
  and records.  Returns False when ATypeInfo is not a direct closed generic
  specialization or when its declaring unit cannot be recovered. }
function GenericFamilyKeyOf(ATypeInfo: PTypeInfo; out AKey: string): Boolean;

{ True when ATypeInfo is a class deriving from (or equal to) a class whose
  name starts with one of ABaseNames, e.g. 'TList<'.  This walks the real
  ancestry, so ordinary descendants such as
  TOrders = class(TObjectList<TOrder>) are recognized. }
function InheritsFromGenericBase(ATypeInfo: PTypeInfo;
  const ABaseNames: array of string): Boolean;

{ Declares the unit a type belongs to.  Record RTTI carries no unit name, so a
  unit that declares records in its implementation section can call this once
  to make unit-scoped and name-scoped registrations resolve for them.  Both
  serialization engines consult the same registry, so their TypeKey semantics
  stay identical. }
procedure RegisterTypeUnitName(ATypeInfo: PTypeInfo; const AUnitName: string);

type
  { The naming primitives the typed extension layers of both engines need in
    order to explain a type mismatch.  They live here, and not in each engine,
    for the same reason everything else in this unit does: two copies of
    "what is this type called" drifted apart once already.

    Only the naming is shared.  Each engine composes - and raises - its own
    message, because the exception class is part of that engine's contract. }
  TSerializationTypeInfo = record
    { The Delphi name of T.  '<unnamed>' when T has no RTTI name. }
    class function TypeNameOf<T>: string; static;
    { The name of what a TValue actually holds, for the other half of a
      "expected X, got Y" message.  '<empty>' for TValue.Empty. }
    class function ActualNameOf(const AValue: TValue): string; static;
  end;

  { ------------------------------------------------------------------------
    NULLABLE FAMILIES

    A nullable is a record carrying a value and a "has value" flag.  The
    library's own PascalForge.Nullable.TNullable<T> is recognized out of the
    box; any other library's nullable becomes recognized by registering its
    GENERIC FAMILY once, at startup:

      TSerializationTypes.RegisterNullableFamily<Other.TMaybe<Integer>>;

    The Integer specialization is a sample, not the subject.  Only three
    things are taken from it - the declaring unit, the generic base name and
    the arity - and from then on every specialization of that family is
    recognized: TMaybe<string>, TMaybe<TDateTime>, TMaybe<TMyEnum>, one the
    application has not written yet.

    Field offsets differ per specialization, so nothing about the layout of
    any other specialization is stored.  Each one's concrete inner type and
    offsets are resolved the first time it is seen - when its serialization
    plan is built - and cached, both here and in the plan itself.

    WHAT IDENTIFIES A FAMILY.  Delphi emits no declaring unit for a closed
    generic record: TRttiType.QualifiedName raises ENonPublicType for
    TNullable<System.Integer> even though TNullable<T> is declared in a
    unit's interface section.  A generic record family is therefore
    identified by its base name, its arity, and the fields the registration
    named - plus the declaring unit on the rare occasions RTTI has one.
    Two nullable families with the same base name and arity cannot be told
    apart, so registering the second one raises rather than guessing.

    The registry is shared, which is the point of it living in this unit:
    JSON, XML, BSON and the DataSet projection all agree on what a nullable
    is, because they all ask the same table.
    ------------------------------------------------------------------------ }

  { Raised by RegisterNullableFamily for a registration that cannot be
    honoured: a non-record, something that is not a closed generic
    specialization, a type whose declaring unit is not recoverable, a field
    name that does not exist, or a has-value field that is not a one-byte
    Boolean. }
  ENullableFamilyError = class(Exception);

  { A value this library will not write, whatever the format, with the
    reason: a TStrings with objects attached to its lines, whose objects
    would otherwise be dropped without a word. Raised by the shared
    container access, so every engine says the same thing. }
  ESerializationUnsupported = class(Exception);

  { A value this library will not write because it is too big in a way the
    stack or a reader cannot take: an object graph nested past
    SERIALIZATION_MAX_GRAPH_DEPTH. }
  ESerializationLimitExceeded = class(Exception);

  { The two field names that make a record a nullable. }
  TNullableLayout = record
  private
    FValueField: string;
    FHasValueField: string;
  public
    { FValue / FHasValue - what PascalForge.Nullable uses, and what nearly
      every port of the same idea uses. }
    class function Default: TNullableLayout; static;
    { For a family that names its fields differently. }
    class function Fields(const AValueField,
      AHasValueField: string): TNullableLayout; static;
    function SameAs(const AOther: TNullableLayout): Boolean;
    function Describe: string;
    property ValueField: string read FValueField;
    property HasValueField: string read FHasValueField;
  end;

  { Resolved access to ONE nullable specialization: the inner type and the two
    field offsets.  A plain record with inlined members - no interface, no
    virtual call, nothing allocated - because this sits directly on the
    serialize and deserialize paths. }
  TNullableAccess = record
  private
    FValueType: PTypeInfo;
    FValueOffset: Integer;
    FHasValueOffset: Integer;
    FResolved: Boolean;
  public
    function HasValue(AInstance: Pointer): Boolean; inline;
    function GetValue(AInstance: Pointer): TValue; inline;
    { Assigns through TValue.Cast, so a compatible-but-not-identical value
      still lands. }
    procedure SetValue(AInstance: Pointer; const AValue: TValue); inline;
    { For a caller that has already proved the TValue is exactly ValueType. }
    procedure SetExactValue(AInstance: Pointer; const AValue: TValue); inline;
    { Marks the nullable empty without touching the value slot. }
    procedure Clear(AInstance: Pointer); inline;
    property ValueType: PTypeInfo read FValueType;
    property ValueOffset: Integer read FValueOffset;
    property HasValueOffset: Integer read FHasValueOffset;
    property IsResolved: Boolean read FResolved;
  end;


  { ------------------------------------------------------------------------
    DATE AND TIME POLICY - the mechanism, not the meaning

    Every format needs the same resolution order for how a date is written:

        a field override
          beats a type override
            beats the format's global default
              beats the format's built-in default

    and every format needs it resolved ONCE, while a plan is built, so the
    warm path never looks anything up.  That much is shared.

    What a policy MEANS is not shared and is not known here.  Kind is an
    ordinary Integer: each format stores the ordinal of its OWN enumeration in
    it - JSON's ISO8601, XML's XsdDateTime, BSON's Native are different things
    that happen to be numbers - and each format interprets it alone.  This
    unit never compares a Kind against a constant, and there is no format
    enumeration anywhere in it.

    One table per format per value kind (date, time, timestamp) keeps them
    independent: configuring XML cannot move JSON.
    ------------------------------------------------------------------------ }
  TDateTimePolicy = record
  public
    { The owning format's own representation, as an ordinal. }
    Kind: Integer;
    { The custom pattern, for the representations that take one. }
    Pattern: string;
    class function Make(AKind: Integer;
      const APattern: string = ''): TDateTimePolicy; static;
    function SameAs(const AOther: TDateTimePolicy): Boolean;
  end;

  TDateTimePolicies = class
  strict private
    FBuiltIn: TDateTimePolicy;
    FGlobal: TDateTimePolicy;
    FHasGlobal: Boolean;
    FTypes: TDictionary<string, TDateTimePolicy>;
    FFields: TDictionary<string, TDateTimePolicy>;
    FLock: TCriticalSection;
  public
    { ABuiltIn is what the format does with no configuration at all, and is
      what Resolve returns until something is registered.  Defaults must not
      move when a policy mechanism is added: that is why this is a
      constructor argument and not a hard-coded zero. }
    constructor Create(const ABuiltIn: TDateTimePolicy);
    destructor Destroy; override;

    procedure SetGlobal(const APolicy: TDateTimePolicy);
    procedure SetForType(const ATypeKey: string; const APolicy: TDateTimePolicy);
    procedure SetForField(const ATypeKey, AFieldName: string;
      const APolicy: TDateTimePolicy);

    { Field, then type, then global, then built-in.  AFieldName may be '' to
      resolve for a type alone (a root value, an element of a list). }
    function Resolve(const ATypeKey, AFieldName: string): TDateTimePolicy;

    { Everything registered is forgotten; the built-in default remains.
      For tests, which need a known starting point. }
    procedure Reset;

    property BuiltIn: TDateTimePolicy read FBuiltIn;
  end;

  { Cross-format registration of type semantics.  Naming helpers live on
    TSerializationTypeInfo above; this is where an application teaches the
    library about its own types. }
  { ------------------------------------------------------------------------
    CONTAINERS, RECOGNISED ONCE

    Every format engine needs the same two answers about a Delphi type:

        is this a list, and how do I reach its elements?
        is this a dictionary, and how do I reach its pairs?

    Each of them used to work that out for itself. They agreed - until they
    did not: three engines ended up walking TObjectList's and TDictionary's
    OWN published members, describing a container by its comparer and its
    notify events, and one of those reached an invalid pointer. That is what
    this lives here to stop happening again.

    CORE ANSWERS WHAT THE CONTAINER IS. IT DOES NOT ANSWER HOW TO WRITE ONE.
    A dictionary is a BSON document, a CBOR map, an Avro map, an ASN.1
    SEQUENCE OF two-component SEQUENCEs and four different refusals in CSV;
    none of that belongs here. This layer stops at "these are the pairs".

    RECOGNITION IS BY ANCESTRY, never by the shape of a class's methods and
    never by a name prefix. TOrders = class(TObjectList<TOrder>) is a list
    because TObjectList<T> is a TList<T>; a class that merely happens to
    have an Add and a ToArray is not. A container family outside the RTL
    registers itself, exactly as a nullable family does.
    ------------------------------------------------------------------------ }

  TContainerKind = (None, List, Dictionary);

  { A list-like container: its element type, and the methods that reach the
    elements. Resolved once per type and cached.

    LIFETIME: the TRttiMethod and TRttiField references belong to the shared
    RTTI context and outlive any one operation, which is why they are safe
    to cache. Nothing here owns the container itself. }
  TListAccess = record
  public
    ContainerType: PTypeInfo;
    ElementType: PTypeInfo;
    { The family name recognition matched, for diagnostics. }
    Family: string;
    { The family destroys what it holds. True for TObjectList<T> and its
      descendants; a reader that replaces a container's contents has to know
      whether the old contents are about to be freed for it. }
    Owns: Boolean;
    AddMethod: TRttiMethod;
    ToArrayMethod: TRttiMethod;
    ClearMethod: TRttiMethod;
    CreateMethod: TRttiMethod;

    function IsValid: Boolean;
    { The elements, as a dynamic array TValue. The caller does not own the
      elements; for an owning list they belong to the list. }
    function Elements(const AContainer: TValue): TValue;
    function Count(const AContainer: TValue): Integer;
    procedure Add(const AContainer, AItem: TValue);
    procedure Clear(const AContainer: TValue);
    { A new empty instance, or nil when the family has no parameterless
      constructor. The caller owns it. }
    function CreateInstance: TObject;
  end;

  { A dictionary-like container. }
  TDictionaryAccess = record
  public
    ContainerType: PTypeInfo;
    KeyType: PTypeInfo;
    ValueType: PTypeInfo;
    Family: string;
    Owns: Boolean;
    AddOrSetMethod: TRttiMethod;
    ToArrayMethod: TRttiMethod;
    ClearMethod: TRttiMethod;
    CreateMethod: TRttiMethod;
    { ToArray yields TArray<TPair<K,V>>; these read the two halves of one
      pair without the caller knowing the pair type. }
    PairKeyField: TRttiField;
    PairValueField: TRttiField;

    function IsValid: Boolean;
    { The pairs, as a dynamic array TValue of TPair<K,V>. }
    function Pairs(const AContainer: TValue): TValue;
    function Count(const AContainer: TValue): Integer;
    function KeyOf(const APair: TValue): TValue;
    function ValueOf(const APair: TValue): TValue;
    procedure AddOrSet(const AContainer, AKey, AValue: TValue);
    procedure Clear(const AContainer: TValue);
    function CreateInstance: TObject;
  end;

  TSerializationTypes = record
  strict private
    { A generic method body declared in an interface section may only
      reference symbols the interface section can see, so the work is done
      by this non-generic bridge (E2506).  The generic form exists only to
      turn T into a PTypeInfo. }
    class procedure DoRegisterNullableFamily(AInfo: PTypeInfo;
      const ALayout: TNullableLayout); static;
  public
    { Registers the whole generic family of T, using the FValue/FHasValue
      layout.  Raises ENullableFamilyError when T cannot be a nullable
      family.  Registering the same family twice with the same layout is a
      no-op; with a different layout it raises, because which one won would
      otherwise depend on unit initialization order. }
    class procedure RegisterNullableFamily<T>; overload; static;
    class procedure RegisterNullableFamily<T>(
      const ALayout: TNullableLayout); overload; static;

    { Resolves - and caches - the concrete access for one specialization.
      False for anything that is not a specialization of a registered
      family. }
    class function TryGetNullableAccess(ATypeInfo: PTypeInfo;
      out AAccess: TNullableAccess): Boolean; static;
    class function IsNullableType(ATypeInfo: PTypeInfo): Boolean; static;

    { The registered family keys, for diagnostics. }
    class function RegisteredNullableFamilies: TArray<string>; static;

    { --- containers ------------------------------------------------------

      The two questions every engine asks, answered once. See TListAccess
      above for why they are here and not in each engine.

      Both resolve by ANCESTRY: a type is a list when one of its ancestors
      is a specialization of a registered list family. TList<T> and
      TDictionary<K,V> are registered out of the box, which covers
      TObjectList<T>, TObjectDictionary<K,V> and every user descendant of
      any of them, because those ARE descendants.

      A container family that is not an RTL one registers itself, exactly as
      a nullable family does. }
    { A list family names the method that appends and the method that
      yields the elements in order, because not every sequence spells them
      Add and ToArray: a TQueue<T> enqueues, a TStack<T> pushes, and a
      TStrings hands its lines over as ToStringArray. Nothing is guessed
      from a method's shape; a family says what it is.

      A name ending in '<' is a generic family, matched by prefix along the
      ancestry; any other name is one class, matched exactly - so 'TStrings'
      is TStrings and its descendants, and never TStringsHelper. }
    class procedure RegisterListFamily(const AFamilyBaseName: string;
      AOwns: Boolean = False; const AAddName: string = 'Add';
      const AToArrayName: string = 'ToArray'); static;
    class procedure RegisterDictionaryFamily(const AFamilyBaseName: string;
      AOwns: Boolean = False); static;

    class function TryGetListAccess(ATypeInfo: PTypeInfo;
      out AAccess: TListAccess): Boolean; static;
    class function TryGetDictionaryAccess(ATypeInfo: PTypeInfo;
      out AAccess: TDictionaryAccess): Boolean; static;
    { List, Dictionary or None, in one call, for a classifier that only
      needs to branch. Dictionary is tested first: a TObjectDictionary is
      not a TList, but asking in the other order has caught people out. }
    class function ContainerKindOf(ATypeInfo: PTypeInfo): TContainerKind; static;
    { A list's elements through the method its family names - with the one
      check every engine needs and none should repeat: a TStrings that has
      objects on its lines is refused, because only the lines travel. }
    class function ListElements(AContainer: TObject;
      AToArray: TRttiMethod): TValue; static;
    { The parameterless constructor a class declares, preferring its own
      over TObject.Create - which is what a reader calls to make one; nil
      when there is none. GetMethod('Create') is NOT this: it returns the
      first overload of the name, which for TDictionary<K,V> takes a
      capacity, and invoking that with no arguments raised EInvocationError. }
    class function DefaultConstructor(AType: TRttiType): TRttiMethod; static;
    { The registered family names, for diagnostics and for the check that
      every engine really does consult this. }
    class function RegisteredContainerFamilies: TArray<string>; static;

    { --- what cannot be serialized at all ------------------------------

      '' when the type is serializable in principle, and otherwise a
      sentence saying why not - which every engine puts in its own error,
      after the member path and before the remedy.

      This is the ONE place the question is answered, so every engine gives
      the same answer: a pointer member, for instance, is refused by name,
      because "a pointer is an address, which means nothing in another
      process" is the only honest answer - never skipped, written as an
      integer, or dereferenced.

      Almost nothing here is keyed on a class. A component or an exception
      is refused because it HOLDS something that cannot be serialized, which
      is found by looking at its members, not because somebody wrote its
      name on a list - so a caller's own class with a raw pointer in it gets
      the same answer, for the same reason.

      THREE FRAMEWORK FAMILIES ARE THE EXCEPTION, by ancestry, because what
      they hold is not what their public surface shows: a TStream's value
      is bytes behind a position, the untyped TList holds addresses, and a
      TCollection makes its own items through a class it chooses. Walked as
      objects, the first two wrote their Size and Count and came back as
      that many zeros or nil pointers - carried, apparently, and empty.

      A caller can always override it: an ignore attribute leaves a member
      out, and a registered custom serializer makes any type serializable.
      Every engine asks this only AFTER those two. }
    class function UnsupportedReason(ATypeInfo: PTypeInfo): string; static;

    { --- integers, as the numbers they are ------------------------------

      Delphi files its integer types under two type kinds, and the kind says
      nothing about sign: Cardinal is tkInteger like Integer, and UInt64 is
      tkInt64 like Int64. A format that has unsigned numbers, or that writes
      digits, has to know which - or it writes 4294967295 as -1, which reads
      back into the same Delphi field and is still a lie to every other
      reader of the document. And Comp, a 64-bit INTEGER, is filed under
      tkFloat: an engine that trusts the kind sends it through a Double and
      loses everything past 2^53.

      These answer the questions from the type data, once, for every
      engine. }
    class function IsUnsignedInteger(ATypeInfo: PTypeInfo): Boolean; static;
    class function IsCompType(ATypeInfo: PTypeInfo): Boolean; static;
    { The 64 bits of an integer value - any tkInteger or tkInt64 type, or
      Comp - sign-extended or zero-extended as its type says. A UInt64 above
      High(Int64) comes back reinterpreted; ask IsUnsignedInteger first. It
      exists because TValue.AsInt64 raises EInvalidCast on a Comp. }
    class function Int64Bits(const AValue: TValue): Int64; static;
    { The same value as decimal digits, with the sign its type gives it. }
    class function IntegerText(const AValue: TValue): string; static;
    { The inverse, range-checked against the type: decimal digits with an
      optional sign, and nothing else - no hex prefix, no fraction, no
      exponent. False when the text is not such an integer or the value does
      not fit: 300 is not a Byte and -1 is not a Cardinal, and nothing here
      wraps one into the other. }
    class function TryIntegerFromText(ATypeInfo: PTypeInfo;
      const AText: string; out AValue: TValue): Boolean; static;
    { The same range check, from a number a binary format already decoded:
      a signed one, and an unsigned one for the top half of the UInt64
      range that no Int64 holds. }
    class function TryIntegerFromInt64(ATypeInfo: PTypeInfo; AValue: Int64;
      out AResult: TValue): Boolean; static;
    class function TryIntegerFromUInt64(ATypeInfo: PTypeInfo; AValue: UInt64;
      out AResult: TValue): Boolean; static;
    { A decoded binary float into a float member - Single, Double,
      Extended or Currency - checked on the way: a value a Single cannot
      hold is not turned into infinity, and a NaN, an infinity or anything
      past Currency's range is not turned into -922337203685477.5808, which
      is what the FPU stores when it is asked to and nobody checks. The
      special values themselves go into Single, Double and Extended, which
      have them. }
    class function TryFloatFromDouble(ATypeInfo: PTypeInfo; AValue: Double;
      out AResult: TValue; out AWhy: string): Boolean; static;

    { --- text into a string or character of any kind --------------------

      Every format carries text as Unicode, and Delphi has eight places to
      put it. string, WideString, UTF8String and Char hold any text. The
      others are LEGACY TEXT IN A CODE PAGE - AnsiString in its declared one
      (the system's, for plain AnsiString), ShortString and AnsiChar in the
      system's - and a code page holds only some characters.

      So text is ENCODED into the declared code page and checked: if it does
      not come back out as the same text, some character had no place there,
      and the answer is False with the reason, never a '?' in the field.
      RawByteString declares no code page at all; text read into one is held
      as UTF-8 and tagged so, which is lossless and says what it is.

      A character takes exactly one character of text. The empty string is
      #0, which is what a writer writes #0 as in formats that cannot carry a
      NUL; more than one is refused, not truncated. }
    class function TryStringFromText(ATypeInfo: PTypeInfo;
      const AText: string; out AValue: TValue; out AWhy: string): Boolean;
      static;

    { --- sets ---------------------------------------------------------

      A Delphi set is a bit array, and two facts about it are easy to get
      wrong. Bit 0 is not ordinal 0: storage starts at the byte that holds
      the element type's LOWEST value, so in a set of 10..19 the value 10 is
      bit 2 and 19 is bit 11. And a set can be up to 32 bytes wide, so one
      read as an Integer loses every member past the 31st. Engines did both;
      these do it once.

      SetOrdinals lists the ordinals present, lowest first. TryMakeSet builds
      the set from ordinals and refuses one outside the element type's range
      rather than writing a bit that belongs to nothing. }
    class function SetElementType(ATypeInfo: PTypeInfo): PTypeInfo; static;
    class function SetOrdinals(ATypeInfo: PTypeInfo;
      const AValue: TValue): TArray<Integer>; static;
    class function TryMakeSet(ATypeInfo: PTypeInfo;
      const AOrdinals: array of Integer; out AValue: TValue;
      out AWhy: string): Boolean; static;
    { A set member as text, and back, for every element type a set can
      have: an enumeration's name, and for an integer subrange or a set of
      characters, the ordinal's digits. A character is written as its byte
      value rather than as itself: a comma or a space would break the
      joined forms two formats use, and the byte has no code page to get
      wrong. GetEnumName handles only the first case - handed the AnsiChar
      of a TSysCharSet it read a pointer that is not there. }
    class function SetElementText(AElemType: PTypeInfo;
      AOrdinal: Integer): string; static;
    class function TrySetElementOrdinal(AElemType: PTypeInfo;
      const AText: string; out AOrdinal: Integer): Boolean; static;
    { The same through an enumeration's text mapping - the format's own or
      [SerializationEnum], which the caller resolves. With no mapping, or
      for an element type that is not an enumeration, exactly the two
      above. A mapped element reads its mapped text only, compared
      case-insensitively, as a mapped enumeration value does. }
    class function MappedSetElementText(AElemType: PTypeInfo;
      AOrdinal: Integer; const AMapping: TArray<string>): string; static;
    class function TryMappedSetElementOrdinal(AElemType: PTypeInfo;
      const AText: string; const AMapping: TArray<string>;
      out AOrdinal: Integer): Boolean; static;

    { --- static arrays -----------------------------------------------

      array[0..2] of T and array[5..7] of T are fixed-length sequences, and
      a multidimensional one is carried FLAT, in the order Delphi stores it,
      because that is the only order RTTI can describe: the length of each
      dimension is not recorded when its index type is anonymous, and
      array[0..1] of array[0..2] of T compiles to the same type as
      array[0..1, 0..2] of T. The Delphi type restores the shape on the way
      back, and the element count has to match it exactly.

      False when ATypeInfo is not a static array or its element type has no
      RTTI. }
    class function TryGetStaticArrayShape(ATypeInfo: PTypeInfo;
      out AElementType: PTypeInfo; out ACount, AElementSize: Integer): Boolean;
      static;
    { An array of either kind from its elements: a dynamic one takes their
      number, and a static one must already have it - False, with the
      reason, when the count does not match the type. }
    class function TryMakeArray(ATypeInfo: PTypeInfo;
      const AElements: array of TValue; out AValue: TValue;
      out AWhy: string): Boolean; static;
  end;


  { ------------------------------------------------------------------------
    VARIANT, THROUGH THE DYNAMIC TREE

    A Variant is a value that carries its own type, which is exactly what a
    self-describing format carries too - so the dynamic tree every such
    format already reads and writes is the whole bridge, and every format
    that has one supports Variant in the same way.

    WHAT SURVIVES is the value and its FAMILY: Null, Boolean, integer, real,
    text, date and time, one-dimensional arrays of those. What does not is
    the exact width - the literal 42 is a varByte in Delphi and comes back as
    a varInteger, because no format records that a number was a Byte.
    Currency travels as exact decimal digits and comes back as a Currency
    when the format kept them exact. A format with no date type writes a
    varDate the way it writes any date, and that is documented per format.

    EMPTY IS NOT NULL. Unassigned has no value at all; a member holding it
    is left out of the document, and reading a document without the member
    leaves the Variant Unassigned. Inside an array there is nothing to leave
    out, so there it is refused rather than written as null.

    REFUSED, always, with the reason: an interface (varDispatch,
    varUnknown), a reference (varByRef), varError, a record and a custom
    variant type - none of them is a value - and arrays of more than one
    dimension, which the tree cannot shape.
    ------------------------------------------------------------------------ }
  { ------------------------------------------------------------------------
    CYCLES

    A graph that points back at itself - A.Next = B, B.Next = A - has no
    representation in any format here: none has a back-reference, and
    following the pointers writes forever, until the stack runs out. Every
    engine asks this guard, per object, on the way in; an object that is
    already being written further up the SAME graph is a cycle, and the
    engine refuses it by name. An object reached twice along different paths
    - a child shared by two parents - is not a cycle and is written twice,
    which is what a format without identity can do with it.

    The set is per thread, so two threads writing two graphs never see each
    other's objects.

    DEPTH. The same set is the path from the root to the object being
    written, so its size is how deeply the graph nests there. Every writer
    follows a graph recursively, and a graph nested a thousand objects deep
    - a linked list, usually - ran every one of them out of stack; one far
    shallower still produced documents deeper than the formats' own readers
    accept (a protobuf reader stops at 100 messages, YAML at 200 levels,
    CBOR and ASN.1 at 256). So Enter refuses an object past
    SERIALIZATION_MAX_GRAPH_DEPTH, with ESerializationLimitExceeded: 64,
    which is also .NET's default, leaves every format's reader room for the
    list and dictionary levels between objects. }
  TSerializationGraphGuard = record
  public
    { False when AObject is already being written on this thread. A nil
      object is never a cycle. Raises ESerializationLimitExceeded when the
      graph would nest past SERIALIZATION_MAX_GRAPH_DEPTH. }
    class function Enter(AObject: TObject): Boolean; static;
    class procedure Leave(AObject: TObject); static;
    { The same limit, for a writer that keeps its own set - JSON's, which
      carries its recursion policy. ADepth is the number of objects already
      open on the path. }
    class procedure CheckDepth(ADepth: Integer; AObject: TObject); static;

    { LEVELS. The limit counts every composite a writer descends into - an
      object, a record, a static or dynamic array, a list, a dictionary, a
      variant array - not only objects: a record type that holds a dynamic
      array of itself nests without any object in it, and it overflowed the
      stack the same way. Enter and Leave count a level for an object;
      EnterLevel and LeaveLevel count one for anything else. Every writer
      pairs them in try/finally, and restores the level it started from at
      its root (Level, RestoreLevel), so a failure deep in one write cannot
      leave the next write on the thread starting part way down. }
    class procedure EnterLevel; static;
    class procedure LeaveLevel; static;
    class function Level: Integer; static;
    class procedure RestoreLevel(AMark: Integer); static;
  end;

const
  SERIALIZATION_MAX_GRAPH_DEPTH = 64;

type

  TSerializationVariants = record
  public
    { AExactDecimals says whether the destination has an exact decimal. One
      that does not - MessagePack - gets a Currency as the Double it is
      nearest to, which stays a real number; the digits would have become
      text. }
    class function TryToDynamic(const AValue: Variant;
      out ATree: TDynamicValue; out AWhy: string;
      AExactDecimals: Boolean = True): Boolean; static;
    class function TryFromDynamic(ATree: TDynamicValue;
      out AValue: Variant; out AWhy: string): Boolean; static;
  end;

  { ------------------------------------------------------------------------
    SERIALIZATION FORMATS

    Encoded representations supported by PascalForge.Serialization.

    These formats may be used for persistence, interchange, storage,
    transport, caching, archiving, signing, or anything else an encoded
    representation is good for. None of them belongs to transport in
    particular; they are all simply encodings.

    Being listed here does not imply that the corresponding implementation
    is linked into the current application. Availability is determined by
    the serialization-format registry below, and asking for a format nobody
    registered raises rather than silently doing something else.

    TDataSet is not listed because it is a live runtime object projection
    rather than an encoded representation: it has ownership, schema objects,
    fields, rows, a cursor position and editing state, none of which a
    TSerializationPayload can carry. DataSet projection is nevertheless a
    first-class PascalForge.Serialization subsystem and shares the same
    RTTI and type infrastructure - nullable families, collection
    recognition, type identity - as the encoded-format serializers. Its
    facade is TDataSetSerializer, which returns a TDataSet rather than a
    payload, and that difference in RESULT TYPE is the whole reason it is
    not a value of this enumeration.
    ------------------------------------------------------------------------ }
  TSerializationFormat = (
    Json,
    Xml,
    Bson,
    Protobuf,
    Cbor,
    MessagePack,
    Yaml,
    Csv,
    Avro,
    { ASN.1 IS A SCHEMA LANGUAGE, NOT AN ENCODING.

      X.680 defines the types; X.690 defines three different ways of writing
      them down, and they are not interchangeable: DER and CER are each a
      canonical subset of BER with DIFFERENT canonical rules, so "an ASN.1
      document" does not identify a representation. This enumeration
      identifies representations, so there are three values rather than one.

      PER and OER are deliberately absent: they are further encoding rules
      of the same schema language and belong to a later stage, not to a
      value that is registered and then raises. }
    Asn1Ber,
    Asn1Der,
    Asn1Cer
  );

  { Raised when a format is asked for but nothing has registered a handler
    for it.  The message names the registration call to make, because that is
    the fix in every case: registration is explicit, and linking a unit or
    loading a package registers nothing. }
  ESerializationFormatNotRegistered = class(Exception)
  public
    constructor CreateFor(AFormat: TSerializationFormat);
  end;

  { Raised when a format is registered while a DIFFERENT handler already
    holds it. Silently replacing one would make behaviour depend on the order
    registrations ran in. }
  ESerializationFormatConflict = class(Exception);

  ESerializationPayloadKind = class(Exception);

  { ------------------------------------------------------------------------
    A SCHEMA, FROM THE OUTSIDE

    Some formats carry their own types and some do not. A CBOR document says
    what every value is; a Protobuf message is (field number, wire type,
    payload) and says nothing at all, and an Avro datum is a sequence of
    values whose meaning is entirely in a schema that travelled separately.

    For the second kind, structural work is not merely harder - it is
    impossible without the schema, and pretending otherwise produces a tree
    of plausible guesses. So the schema is passed IN, and a format that
    needs one and did not get one says so rather than improvising.

    THIS CLASS IS EMPTY ON PURPOSE. A Protobuf descriptor set, an Avro
    schema and an ASN.1 module have nothing in common beyond being the thing
    their format needs, and inventing a shared vocabulary for them before
    three of them exist would be inventing it from one example. Each format
    declares its own descendant with its own API; the core knows only that
    the caller supplied something and which format it belongs to, which is
    exactly enough to route it and to refuse it when it is for the wrong
    format.

    Lifetime: BORROWED, everywhere. A schema is expensive to parse and is
    reused across many calls, so nothing here frees one. The caller owns it
    for as long as the conversions that reference it.

    ------------------------------------------------------------------------
    A CONTEXT IS A SCHEMA PLUS THE REST OF THE ANSWER

    A schema on its own is not always enough to say what a conversion should
    do. A Protobuf descriptor set describes many messages and the bytes do
    not say which one they are. An ASN.1 module declares several types. Avro
    resolution has a WRITER's schema and a READER's schema, and they are
    deliberately different objects.

    So the thing that travels is a CONTEXT: the schema, plus whatever else
    that format needs in order to act - a message name, a root type, a second
    schema. TSerializationContext is the base, and it is as empty as the
    schema base was and for the same reason. A format declares its own.

    WHY ROLES AND NOT A FIRST AND A SECOND

    Options used to carry Schema and SecondSchema, and a handler found its
    own by asking which one had its format. That works exactly until both
    ends ARE that format:

        Protobuf schema A  ->  Protobuf schema B
        Avro writer schema ->  Avro reader schema
        ASN.1 type A       ->  ASN.1 type B

    Format identity cannot separate those, so the two slots are now named by
    ROLE - SourceContext and DestinationContext - and a handler asks for the
    role it is playing. ToDynamic is the source; FromDynamic is the
    destination. There is no case left where the library has to guess. }
  { ------------------------------------------------------------------------
    HOW A LOSSLESS CONVERSION WAS ACHIEVED

    Some Lossless pairs have no published representation of their own and a
    standards-based ROUTE instead. BSON into XML is the example: there is no
    BSON/XML standard, and there are two standards that meet in the middle -

        BSON  -> MongoDB Extended JSON ->  JSON
        JSON  -> W3C JSON/XML          ->  XML

    The facade composes that route rather than making every caller run both
    halves by hand. What it must never do is HIDE it: a caller who asked for
    Lossless is entitled to know which standards their data went through,
    because that is the whole basis of the guarantee.

    So every conversion can report its route, and a composed one names each
    standard it used.

    THE ROUTES ARE A TABLE, NOT A SEARCH. There is no graph traversal here
    and there is deliberately no attempt to discover a path: a resolver that
    searched would one day find a surprising three-hop route through a format
    nobody expected, and the caller would have no way to predict it. The
    table is in PascalForge.Serialization and it currently has two entries. }
  TStructuralRouteStep = record
  public
    FromFormat: TSerializationFormat;
    ToFormat: TSerializationFormat;
    { The published standard this hop rests on, or '' for a direct
      conversion that needs none. }
    Standard: string;
  end;

  TStructuralRoute = record
  public
    Steps: TArray<TStructuralRouteStep>;
    { 1 for a direct conversion; 2 for one composed through a hub. }
    function HopCount: Integer;
    function IsComposed: Boolean;
    { 'Bson -> MongoDB Extended JSON -> Json -> W3C JSON/XML -> Xml', which
      is what a diagnostic or a log line wants. }
    function Describe: string;
    class function Direct(AFrom, ATo: TSerializationFormat;
      const AStandard: string = ''): TStructuralRoute; static;
  end;

  TSerializationContext = class
  public
    { The format this context is for. A context handed to the wrong format is
      a caller error worth naming rather than a mystery further in. }
    function Format: TSerializationFormat; virtual; abstract;
    { One line for a diagnostic or a user interface. }
    function Describe: string; virtual;
  end;

  { A schema IS a context - the common case, where the schema is the whole
    answer. CSV's inferred column list and Avro's schema are used directly as
    contexts; Protobuf and ASN.1 wrap theirs to add the name of the thing
    being converted. }
  TSerializationSchema = class(TSerializationContext)
  end;

  { Raised when an operation needs a schema and did not get one, or got one
    belonging to another format. Distinct from the capability error: the
    format CAN do this, and would, given the schema. }
  ESerializationSchemaRequired = class(Exception)
  strict private
    FFormat: TSerializationFormat;
  public
    constructor CreateFor(AFormat: TSerializationFormat;
      const AWhat: string);
    constructor CreateMismatch(AExpected, AActual: TSerializationFormat);
    { Both ends of the conversion are the same schema-driven format, so one
      context cannot say which end it is for. }
    constructor CreateAmbiguousRole(AFormat: TSerializationFormat);
    property Format: TSerializationFormat read FFormat;
  end;

  { What a registered format handler is able to do.

    Registration and capability are different questions. Every format here
    answers yes to all four, but a schema-driven encoding may be perfectly
    registered and still unable to decode its own bytes into a structural
    tree without the schema, and a caller who asked for exactly that has to
    be told the truth about it. }
  TSerializationFormatCapability = (
    { ToDynamic works: the format can turn its own payload into the dynamic
      tree with no Delphi contract. }
    StructuralParse,
    { FromDynamic works. }
    StructuralWrite,
    { SerializeTyped works. }
    ContractSerialize,
    { DeserializeTyped works. }
    ContractDeserialize
  );
  TSerializationFormatCapabilities = set of TSerializationFormatCapability;

  { Raised when a format IS registered but cannot do the thing being asked
    of it.  Deliberately not ESerializationFormatNotRegistered: telling
    someone to register a format they already registered would send them the
    wrong way. }
  ESerializationFormatCapability = class(Exception)
  strict private
    FFormat: TSerializationFormat;
    FCapability: TSerializationFormatCapability;
  public
    constructor CreateFor(AFormat: TSerializationFormat;
      ACapability: TSerializationFormatCapability);
    property Format: TSerializationFormat read FFormat;
    property Capability: TSerializationFormatCapability read FCapability;
  end;

  { Whether a payload is text or bytes.  JSON and XML are naturally text;
    BSON, CBOR, MessagePack and Protobuf are naturally bytes.  Neither is
    forced into the other - base64-wrapping a binary document just to make
    every format return a string would be a lie about what the format is. }
  TSerializationPayloadKind = (Text, Binary);

  { A format-dynamic payload, for the general facade and for conversion.

    Format-specific APIs do NOT use this: TJsonSerializer.Serialize returns a
    string and TBsonSerializer.Serialize returns TBytes, because those are
    the natural Delphi types and hiding them behind a wrapper would make the
    common case worse. }
  TSerializationPayload = record
  strict private
    FKind: TSerializationPayloadKind;
    FText: string;
    FBytes: TBytes;
  public
    class function FromText(const AText: string): TSerializationPayload; static;
    class function FromBytes(const ABytes: TBytes): TSerializationPayload; static;

    property Kind: TSerializationPayloadKind read FKind;

    function IsText: Boolean; inline;
    function IsBinary: Boolean; inline;

    { TEXT AND BYTES ARE NOT THE SAME THING, AND THIS RECORD WILL NOT PRETEND

      A Delphi string is Unicode text. It has no byte encoding until somebody
      chooses one. A TBytes is bytes, and says nothing about what they mean.
      Every method here is named for exactly one direction, and the one that
      does not apply raises instead of guessing:

        AsText         text payload   -> the string.   binary -> raises.
        AsBytes        binary payload -> the bytes.    text   -> raises.
        ToUtf8Bytes    text payload   -> UTF-8 bytes.  binary -> raises.
        DecodeUtf8Text binary payload -> text.         text   -> raises.

      ToUtf8Bytes never returns a binary payload's bytes unchanged: those
      bytes are not UTF-8 text and calling them that is how a BSON document
      ends up being treated as a string. DecodeUtf8Text is the deliberate
      opposite - "these bytes really are UTF-8, decode them" - and it is the
      caller who takes responsibility for that claim. }
    function AsText: string;
    function AsBytes: TBytes;

    { UTF-8 is the only encoding offered: it is what every format here
      specifies, and a choice of encodings would only invite a wrong one.
      No BOM is written and a leading BOM is accepted and skipped. }
    function ToUtf8Bytes: TBytes;
    function DecodeUtf8Text: string;

    { What a TEXT format - JSON, XML - reads its input through. A text
      payload gives its text; a binary payload is decoded as UTF-8, because
      UTF-8 bytes are exactly how a text document travels as bytes, and
      refusing them would make TBytes useless as a JSON source.

      A BINARY format does not use this. BSON reads AsBytes, and a text
      payload handed to it is a caller error rather than something to
      re-encode - guessing would turn "this string is a filename" into a
      corrupt document. }
    function AsTextDocument: string;
  end;

  { Raised by the strict UTF-8 decoder below, naming the byte offset. }
  EInvalidUtf8 = class(Exception)
  strict private
    FOffset: Integer;
  public
    constructor CreateAt(AOffset: Integer; const AReason: string);
    { Zero-based offset of the first byte of the offending sequence. }
    property Offset: Integer read FOffset;
  end;

  { ------------------------------------------------------------------------
    STRUCTURAL CONVERSION POLICY

    Structural conversion moves a document from one format to another with no
    Delphi type in the middle. Two DIFFERENT things can go wrong on the way,
    and they are deliberately kept apart because the right answer to each is
    not the same answer:

      a member NAME the destination cannot spell
          "$type": "Person"   ->  XML has no element named $type

      a VALUE KIND the destination does not have
        BSON binary, BSON datetime  ->  JSON has neither

    A name problem is fixable without losing anything: encode the name
    reversibly, in a convention the destination format's own world already
    uses. A value problem is not - either the destination gets a weaker
    representation, or a published standard for that exact pair of formats
    says how to carry it exactly, or the conversion refuses.

    NO PRIVATE INTERCHANGE METADATA. This library does not invent a wrapper,
    a marker attribute, a reserved member name or a provenance flag and write
    it into somebody's document. A lossless conversion either rests on a
    published standard - the W3C JSON/XML mapping, MongoDB Extended JSON -
    or it does not happen and says so.

    There is no Skip or Drop. Silently losing a member is the one behaviour
    this design will not offer. The one documented omission is Natural
    writing into a schema-driven format (Avro, ASN.1): a member the schema
    does not name is omitted there, and Strict and Lossless refuse it.
    ------------------------------------------------------------------------ }

  { What to do with a member name the destination cannot represent. }
  TStructuralNamePolicy = (
    { Encode it reversibly, in whatever way the destination defines. The
      name survives a round trip back to the source format. }
    Encode,
    { Raise EStructuralConversionError naming the member path. }
    Error
  );

  { What to do with a value kind the destination does not have. }
  TStructuralValuePolicy = (
    { Use the destination's idiomatic stand-in: base64 text for binary,
      ISO-8601 text for a timestamp. Readable, and what most consumers
      expect - but a reader cannot tell it from a string that was always a
      string, so it does not round trip. }
    Natural,
    { Use the PUBLISHED STANDARD for this pair of formats, if there is one,
      so that reading the result back reconstructs the original structural
      value exactly and an unrelated tool that knows the same standard reads
      it too.

      JSON -> XML          the W3C JSON/XML mapping (fn:json-to-xml)
      BSON -> JSON         MongoDB Extended JSON, canonical

      Where no such standard exists - BSON's decimal128 into XML, say -
      this raises EStructuralConversionError with the issue
      UnsupportedLosslessConversion, naming the pair and the offending kind.
      It does NOT fall back to inventing one. }
    Lossless,
    { Raise EStructuralConversionError naming the member path and kind. }
    Error
  );

  { The three pairings callers actually ask for. }
  TStructuralConversionProfile = (
    { Encode names, write values naturally. Idiomatic output; names survive,
      exotic value kinds become text. This is the default. }
    Natural,
    { Encode names; carry values through the published standard for the
      pair. The result reads back into the same structural tree it came
      from, and it reads back in other people's tools too, because the
      representation is theirs and not ours. Where no standard covers the
      pair, this refuses rather than improvising. }
    Lossless,
    { Refuse anything the destination cannot represent directly. Nothing is
      adapted, nothing is encoded; every mismatch is an error with a path.
      For compatibility testing rather than for production conversion. }
    Strict
  );

  TStructuralConversionOptions = record
  public
    NamePolicy: TStructuralNamePolicy;
    ValuePolicy: TStructuralValuePolicy;

    { Only so that an error can name it. A destination handler knows its own
      format and the member path; it does not otherwise know where the tree
      came from. TSerialization.Convert fills this in. }
    SourceFormat: TSerializationFormat;
    SourceFormatKnown: Boolean;

    { And the other end, for the SOURCE handler.

      A reader needs this for one decision and one only: whether a published
      standard layered on top of its own format should be recognized. MongoDB
      Extended JSON is JSON that means BSON, so reading it as BSON types is
      right when the destination is BSON and wrong when the destination is
      XML - where it would turn a perfectly convertible object into a binary
      the W3C mapping cannot carry. A conversion has two ends and this
      question is about the pair, so both ends travel with the policy. }
    DestinationFormat: TSerializationFormat;
    DestinationFormatKnown: Boolean;

    { THE TWO CONTEXTS, NAMED BY ROLE.

      Borrowed and never freed here; nil when the caller supplied none, which
      is the normal case for a self-describing format and an error for the
      others.

      Two slots named SOURCE and DESTINATION rather than first and second.
      A handler asks for the role it is playing - ToDynamic is reading, so it
      is the source; FromDynamic is writing, so it is the destination - and
      that works even when both ends are the same format, which is where the
      old Schema/SecondSchema pair could not tell them apart. }
    SourceContext: TSerializationContext;
    DestinationContext: TSerializationContext;

    { The context for AFormat in the role it is playing, or nil. A handler
      reading calls the first; a handler writing calls the second. }
    function SourceContextFor(
      AFormat: TSerializationFormat): TSerializationContext;
    function DestinationContextFor(
      AFormat: TSerializationFormat): TSerializationContext;
    { Either role, for the one question that has no role: Capabilities is
      asked about a handler rather than about a direction, and holding a
      context for this format in EITHER slot is enough to answer it. }
    function AnyContextFor(
      AFormat: TSerializationFormat): TSerializationContext;

    { The same three, raising ESerializationSchemaRequired when there is
      none. AWhat completes the sentence "... is needed for <what>". }
    function RequireSourceContext(AFormat: TSerializationFormat;
      const AWhat: string): TSerializationContext;
    function RequireDestinationContext(AFormat: TSerializationFormat;
      const AWhat: string): TSerializationContext;

    class function FromProfile(
      AProfile: TStructuralConversionProfile): TStructuralConversionOptions; static;
    { Natural. }
    class function Default: TStructuralConversionOptions; static;

    function WithSource(
      AFormat: TSerializationFormat): TStructuralConversionOptions;
    function WithDestination(
      AFormat: TSerializationFormat): TStructuralConversionOptions;
    { The two roles, said explicitly. This is the form that works when both
      ends are the same format. }
    function WithSourceContext(
      AContext: TSerializationContext): TStructuralConversionOptions;
    function WithDestinationContext(
      AContext: TSerializationContext): TStructuralConversionOptions;

    { One context, placed by which END it belongs to.

      The common case is one schema-driven end and one self-describing one -
      Protobuf to JSON - and there the format on the context says which role
      it is playing, so the caller does not have to.

      WHEN BOTH ENDS ARE THAT FORMAT THIS RAISES, because there is no
      information left to decide with, and quietly picking one is how a
      conversion ends up reading schema A and writing it back as schema A.
      The caller then says which they meant with the two calls above. }
    function WithContext(
      AContext: TSerializationContext): TStructuralConversionOptions;

    { Moves a context that was parked in the wrong role now that the ends are
      known.

      A caller who builds options before saying which formats are involved -
      which every typed entry point does, and which reads naturally - puts
      the one context they have wherever there is room. Once the ends ARE
      known, that slot may be the wrong one. This puts it where it belongs,
      and leaves everything alone when the caller named the roles
      themselves. }
    function PlaceContexts: TStructuralConversionOptions;
    { True when the destination is known to be AFormat. False when it is
      something else AND when it is not known at all: a reader asking this
      is asking whether it may reinterpret, and "do not know" is not
      permission. }
    function DestinationIs(AFormat: TSerializationFormat): Boolean;
  end;

  { Which of the two problems above - or which of the other things that can
    go wrong on a structural path - this error is about. }
  TStructuralIssue = (
    InvalidDestinationName,
    UnsupportedValueKind,
    { Lossless was asked for and no published standard covers this value
      kind between these two formats. The reason names the standard that
      would have been used if one applied, or the route that does work. }
    UnsupportedLosslessConversion,
    LossyConversion,
    InvalidText,
    ParseError,
    FieldInference
  );

  { Every structural failure carries a path, so "it did not convert" is never
    the whole message. }
  EStructuralConversionError = class(Exception)
  strict private
    FIssue: TStructuralIssue;
    FSourceFormat: TSerializationFormat;
    FSourceFormatKnown: Boolean;
    FDestinationFormat: TSerializationFormat;
    FPath: string;
    FSourceKind: TDynamicKind;
    FReason: string;
  public
    { The dynamic kind's name as the messages spell it. }
    class function KindName(AKind: TDynamicKind): string; static;
    constructor CreateFor(AIssue: TStructuralIssue;
      const AOptions: TStructuralConversionOptions;
      ADestination: TSerializationFormat; const APath: string;
      ASourceKind: TDynamicKind; const AReason: string);

    property Issue: TStructuralIssue read FIssue;
    property SourceFormat: TSerializationFormat read FSourceFormat;
    property SourceFormatKnown: Boolean read FSourceFormatKnown;
    property DestinationFormat: TSerializationFormat read FDestinationFormat;
    { '$', '$.Subject.PersonInfo', '$.RelatedPersons[4].Name'. }
    property Path: string read FPath;
    property SourceKind: TDynamicKind read FSourceKind;
    property Reason: string read FReason;
  end;

  { Builds the paths those errors carry. One place, so every format spells
    them the same way. }
  TStructuralPath = record
  public
    class function Root: string; static; inline;
    class function Member(const APath, AName: string): string; static;
    class function Index(const APath: string; AIndex: Integer): string; static;
  end;

  { ------------------------------------------------------------------------
    THE NATURAL TEXT FORMS

    Two dynamic kinds have no native shape in a text format: bytes, and a
    timestamp. Every destination that has to render one as text renders it
    the same way, and that is what this record is for - one spelling, so
    JSON, XML and anything added later cannot drift apart.

    These are IDIOMATIC forms, not markers. Base64 and ISO-8601 are what a
    reader of the destination format expects to see, and nothing in the
    document claims they were ever anything else: that is precisely the
    Natural profile's bargain, and why Natural does not round trip.
    ------------------------------------------------------------------------ }
  TStructuralText = record
  public
    { Deliberately timezone-free: the dynamic tree holds a bare TDateTime, so
      shifting it by whatever offset the converting machine happens to sit at
      would make the round trip depend on where it ran. }
    class function EncodeDateTime(AValue: TDateTime): string; static;
    class function TryDecodeDateTime(const AText: string;
      out AValue: TDateTime): Boolean; static;

    { A calendar day and a time of day, for the destinations that have
      neither type. ISO 8601's own reduced forms - yyyy-mm-dd and
      hh:nn:ss.zzz - so the text says which of the three it is and a reader
      of the destination document is not left guessing.

      The decoders exist for the formats that DO have the types and must read
      their own output back. Nothing calls them on arbitrary text: a string
      that happens to look like a date stays a string. }
    { A count since the Unix epoch - seconds, milliseconds, or fractional
      seconds - into a TDateTime, refusing one outside 0001-01-01 to
      9999-12-31, the years a TDateTime holds. A document can state any
      count, and the RTL's IncMilliSecond and UnixToDateTime raised
      EIntOverflow past those years rather than saying so. }
    class function TryUnixSecondsToDateTime(ASeconds: Int64;
      out AValue: TDateTime): Boolean; static;
    class function TryUnixMillisToDateTime(AMillis: Int64;
      out AValue: TDateTime): Boolean; static;
    class function TryUnixFloatSecondsToDateTime(ASeconds: Double;
      out AValue: TDateTime): Boolean; static;

    { The inverse, for the writers: a TDateTime as whole milliseconds since
      the Unix epoch. A TDateTime before 1899-12-30 is NOT linear - -1.25 is
      29 December 06:00, a negative day with a positive time of day - so the
      obvious (AValue - UnixDateDelta) * MSecsPerDay puts every such instant
      a day early; this follows Delphi's own encoding. False outside the
      years 1 to 9999, which is all any reader here accepts back. }
    class function TryDateTimeToUnixMillis(AValue: TDateTime;
      out AMillis: Int64): Boolean; static;
    { A TDateTime in the years 1 to 9999, and finite. }
    class function IsDateTimeInRange(AValue: TDateTime): Boolean; static;
    { Raises ESerializationUnsupported, naming the value, when it is not in
      range: a writer must not produce a date its own reader refuses. }
    class procedure CheckDateTime(AValue: TDateTime); static;
    { A date and a time of day combined the way Delphi encodes them: a
      negative date SUBTRACTS its time of day. EncodeDate + EncodeTime put a
      pre-1899 instant on the next day. }
    class function ComposeDateTime(ADate, ATime: TDateTime): TDateTime; static;

    { Decimal text to the NEAREST Double - correctly rounded, ties to even,
      the same on Win32 and Win64. The RTL's TryStrToFloat is not: on Win64,
      where Extended is a Double, it misreads about a third of the 17-digit
      texts that name a double, so a document from any other producer, or
      this library's own, could come back one unit different.

      Accepts what TryStrToFloat accepted: surrounding spaces, a sign,
      digits with an optional point and exponent (e or E), and NAN, INF,
      +INF and -INF in any case. Nothing else - no thousands separators, no
      locale. }
    class function TryParseFloat(const AText: string;
      out AValue: Double): Boolean; static;

    class function EncodeDate(AValue: TDateTime): string; static;
    class function TryDecodeDate(const AText: string;
      out AValue: TDateTime): Boolean; static;
    class function EncodeTime(AValue: TDateTime): string; static;
    class function TryDecodeTime(const AText: string;
      out AValue: TDateTime): Boolean; static;

    { Text written by FormatDateTime(APattern, ..., TFormatSettings.Invariant)
      read back with the same pattern, so a custom date pattern is the
      contract in both directions. The numeric specifiers are read - yyyy,
      yy, mm, m, dd, d, hh, h, nn, n, ss, s, zzz, z, with m after an h the
      minute as FormatDateTime has it - and quoted text and every other
      character are matched literally. False for text that does not match,
      and for a pattern with a specifier that writes words (month or day
      names, am/pm), which cannot be read back without a locale. }
    class function TryDecodePattern(const AText, APattern: string;
      out AValue: TDateTime): Boolean; static;

    { ISO 8601 date-and-time text as the instant it states: what
      ISO8601ToDate(AText, True) returns - text without an offset taken as
      written, an offset (Z, +hh:mm, +hhmm, +hh) normalised to UTC - with the
      offset applied through the Unix millisecond count. The RTL subtracts it
      from the TDateTime linearly, which moves an instant before 1899-12-30
      the wrong way. Raises for text that is not a date and time, as
      ISO8601ToDate does. }
    class function DecodeIso8601(const AText: string): TDateTime; static;

    class function EncodeBinary(const AValue: TBytes): string; static;
    class function TryDecodeBinary(const AText: string;
      out AValue: TBytes): Boolean; static;
    { Lower-case hex, two characters per byte, and its inverse. Used wherever
      a published standard spells a byte string in hex rather than base64 -
      an ObjectId, an Extended JSON binary subtype. }
    class function EncodeHex(const AValue: TBytes): string; static;
    class function TryDecodeHex(const AText: string;
      out AValue: TBytes): Boolean; static;

    { A binary float as decimal text that reads back as EXACTLY the same
      value: the shortest of 15, 16 and 17 significant digits that does, in
      the invariant culture. Fifteen - what FloatToStr and the RTL's JSON
      writer use - is not enough: 1/3 comes back as a different Double, and
      a text format that writes it that way has lost data without saying so.
      Seventeen always suffices and is used only when needed, so 0.1 stays
      0.1.

      Minus zero is written '-0', because it is a different value from zero
      and a format that has a sign can say so. NaN and the infinities come
      back as 'NaN', 'Infinity' and '-Infinity'; a format that has no
      spelling for them must refuse BEFORE calling this, not write these.

      EncodeSingle does the same at single precision - 6 to 9 digits - so a
      Single's 0.1 is written 0.1 rather than as the Double it widens to. }
    class function EncodeFloat(AValue: Double): string; static;
    class function EncodeSingle(AValue: Single): string; static;
  end;

  { ------------------------------------------------------------------------
    IEEE 754-2008 decimal128, AS TEXT

    Delphi has no 128-bit decimal, so a decimal128 travels through this
    library as its sixteen bytes. That is exact, and it is unreadable, and
    every published standard that has to write one writes DIGITS: MongoDB
    Extended JSON spells it "$numberDecimal": "1.5E+30".

    So the bytes have to become digits somewhere, and this is that place -
    once, rather than once per format. The encoding is BID (binary integer
    significand), little-endian, which is what BSON stores; the text form is
    the one the decimal-arithmetic specification calls to-scientific-string,
    which is also the one Extended JSON requires.

    No arithmetic is offered and none is done. This converts a
    representation; it does not add, compare or round anything.
    ------------------------------------------------------------------------ }
  TDecimal128 = record
  public const
    ByteLength = 16;
    ExponentBias = 6176;
  public
    { False when ABytes is not sixteen bytes. Every sixteen-byte value has a
      text form, including the infinities and the NaNs. }
    class function TryToText(const ABytes: TBytes;
      out AText: string): Boolean; static;
    { Accepts what TryToText produces, plus the ordinary spellings a human
      writes: leading +, no exponent, e or E. False for anything whose
      coefficient needs more than 34 digits or whose exponent is out of
      range, rather than silently rounding it. }
    class function TryFromText(const AText: string;
      out ABytes: TBytes): Boolean; static;
  end;

  { OWNERSHIP ACROSS THE TYPE-ERASED BOUNDARY

    A format handler is reached with a PTypeInfo and a TValue rather than with
    a T, and a TValue carrying a class reference says nothing about who is
    going to free the instance.  This record is the explicit answer, and the
    rule it implements is stated on TSerializationFormatHandler below:
    DeserializeTyped hands the caller everything it allocated.

    A value that owns nothing - an integer, a string, a record, an interface -
    needs no release, and Release is a no-op for it.  This is not a
    general-purpose deep free: it releases exactly what a deserializer is
    capable of having constructed at the root. }
  TSerializationOwnership = record
  public
    { True when a DeserializeTyped result of this type carries something the
      caller has to release: a class instance, or an array of them. }
    class function IsOwningType(ATypeInfo: PTypeInfo): Boolean; static;

    { Releases what DeserializeTyped allocated.  Safe on TValue.Empty, safe on
      a type that owns nothing, and safe to call twice only if the caller
      drops the TValue in between - it frees, it does not nil out.

      It walks what a deserializer can have built: a class instance (freed;
      its destructor owns its members), and the objects inside a record, a
      static or dynamic array, and a list or dictionary that does not own
      its elements - which a root-level free alone would leak. }
    class procedure Release(ATypeInfo: PTypeInfo; const AValue: TValue); static;

    { FOR A READER'S FAILURE PATH. Frees the objects in AValue that this read
      built, walking records and arrays, and leaves alone every object that
      is identical to the one in the same place of AExisting - the one the
      caller, or a constructor, put there and the read filled in place.
      Pass TValue.Empty as AExisting when nothing existed. A deserializer -
      including a custom serializer - hands over every instance it returns;
      it never returns a shared one. }
    class procedure ReleaseBuilt(ATypeInfo: PTypeInfo;
      const AValue, AExisting: TValue); static;
    { The same for elements collected before an array was assembled. }
    class procedure ReleaseBuiltElements(AElementType: PTypeInfo;
      const AElements: array of TValue); static;
    { Frees a list or dictionary this read constructed, together with the
      element objects in it - unless the container owns them, in which case
      its own destructor does. A non-owning TList<TObject> freed alone
      orphaned every element the read had added. }
    class procedure ReleaseBuiltContainer(AContainer: TObject); static;
    { AddOrSet for a dictionary a reader is filling: when the key is already
      there - a duplicate key in the document - the value (and key) the read
      built for the earlier occurrence is released instead of orphaned, owning
      dictionary or not. }
    class procedure AddOrSetBuilt(const AAccess: TDictionaryAccess;
      AContainer: TObject; const AKey, AValue: TValue); static;
    { Whether a container frees what it holds: TObjectList.OwnsObjects and
      its relatives, a TObjectDictionary's ownerships - asked of the
      instance, because a TObjectList.Create(False) owns nothing. }
    class procedure ContainerOwnership(AContainer: TObject;
      out AOwnsKeys, AOwnsValues: Boolean); static;
  end;

  { What a format implementation has to provide to take part in the general
    facade and in cross-format conversion.

    A format's own API does not go through this - TJsonSerializer talks to its
    engine directly, and always will.  This is the dynamic door, used only
    when the format is chosen at run time.

    THE CONTRACT, in full, because a type-erased boundary has no compiler to
    enforce it:

    * ONE INSTANCE PER FORMAT.  TSerializationFormats constructs the handler
      at registration and shares it for the life of the registration, across
      every thread.  A handler therefore holds NO per-operation state:
      everything an operation needs is an argument or a local.

    * ATypeInfo IS NEVER nil, and it is the contract.  A handler that cannot
      represent the type raises its own format's exception, naming the type.
      It never returns an empty TValue to mean "unsupported".

    * SerializeTyped BORROWS AValue.  It must not free anything reachable from
      it, must not modify it, and must not retain it past the call.  The
      caller still owns whatever it passed in.

    * DeserializeTyped TRANSFERS OWNERSHIP of everything it allocated, in the
      returned TValue.  The caller releases it - with
      TSerializationOwnership.Release when the value is a temporary, or by
      simply owning it when the value is the point of the call.  If the
      handler raises, it has already released whatever it half-built: a
      failed DeserializeTyped leaks nothing and returns nothing.

    * ToDynamic TRANSFERS the tree it returns; the caller frees it.
      FromDynamic BORROWS the tree it is given: it must not free or retain
      it.

    * Exceptions belong to the format.  A handler raises EJsonError,
      EXmlError, EBsonError - not a shared "serialization failed" - so a
      caller can still tell what went wrong after the type was erased. }
  TSerializationFormatHandler = class
  public
    { VIRTUAL, so that a handler can carry state decided at registration.

      ASN.1 is why: BER, DER and CER are three formats sharing one handler
      class, and the only thing that differs between the three registrations
      is the encoding rule the instance holds. Without a virtual constructor
      the registry's AHandlerClass.Create would call TObject.Create and the
      three would all be BER - silently, and in a way that only shows up in
      somebody else's verifier. }
    constructor Create; virtual;

    { The natural shape of this format's payloads. }
    function PayloadKind: TSerializationPayloadKind; virtual; abstract;

    { What this handler can actually do.  A format may be fully registered
      and still have no structural parser - a schema-driven encoding cannot
      decode its own bytes without the schema - and a caller that asked for
      structural work deserves to be told THAT, rather than being told the
      format is not registered, which would be false.

      The default is all four, because every format here can do all four.

      CAPABILITY IS NOT A CONSTANT OF THE FORMAT. It depends on what the
      caller has: a Protobuf handler with no descriptor cannot produce a
      structural tree, and the same handler given one can. So the real
      question takes the options - which carry the schema - and the no-
      argument form is that question asked with nothing supplied.

      THERE IS EXACTLY ONE OVERRIDE POINT, the one that takes options, and
      the no-argument form is a non-virtual convenience that asks it with
      nothing supplied. Two virtual methods would be two chances to answer
      the same question differently, and a handler that overrode only one of
      them would be silently ignored on the other path - which is a defect
      that shows up as an access violation somewhere else entirely. }
    function Capabilities: TSerializationFormatCapabilities; overload;
    function Capabilities(
      const AOptions: TStructuralConversionOptions):
      TSerializationFormatCapabilities; overload; virtual;

    { Called by Require when a capability the caller needs is absent, so that
      the handler that said no can say WHY.

      "Structural parsing is not available for PROTOBUF" is true of a caller
      holding nothing and false of the format, and a caller who reads it goes
      looking for a self-describing format instead of for the descriptor that
      would have worked. A handler whose answer depends on what the caller
      brought overrides this and raises ESerializationSchemaRequired naming
      what to bring; the default, for a handler whose answer is a constant,
      raises the capability error and is right. }
    procedure RaiseUnsupported(ACapability: TSerializationFormatCapability;
      AFormat: TSerializationFormat;
      const AOptions: TStructuralConversionOptions); virtual;

    { Structural conversion: no Delphi contract involved.  Read a payload into
      the dynamic tree (transferring it), or write a borrowed dynamic tree
      out.

      BOTH directions take the policy. FromDynamic needs it to decide what to
      do about a member name this format cannot spell and about a value kind
      it does not have; a handler that hits either raises
      EStructuralConversionError carrying the path, and never silently drops
      a member - except the documented Natural omission of a member a
      schema-driven destination's schema does not name.

      ToDynamic needs it because reading is not policy-free either. A
      published standard that layers extra meaning onto an otherwise ordinary
      document - MongoDB Extended JSON over JSON, the W3C mapping over XML -
      may only be RECOGNIZED when the caller asked for Lossless. Under
      Natural, an object whose single member happens to be called "$oid" is
      an object whose single member is called "$oid", and this library will
      not decide otherwise on its behalf. }
    function ToDynamic(const APayload: TSerializationPayload;
      const AOptions: TStructuralConversionOptions): TDynamicValue; virtual; abstract;
    function FromDynamic(const AValue: TDynamicValue;
      const AOptions: TStructuralConversionOptions): TSerializationPayload; virtual; abstract;

    { Contract-aware conversion: the Delphi type IS the contract, so the
      format's own attributes and registrations apply on each side.
      DeserializeTyped transfers what it built; SerializeTyped borrows. }
    function DeserializeTyped(ATypeInfo: PTypeInfo;
      const APayload: TSerializationPayload): TValue; virtual; abstract;
    function SerializeTyped(ATypeInfo: PTypeInfo;
      const AValue: TValue): TSerializationPayload; virtual; abstract;
  end;

  TSerializationFormatHandlerClass = class of TSerializationFormatHandler;

  { The format registry.

    This is the whole coupling point between formats. Core knows the NAMES of
    formats and holds a table of handlers; it does not reference a single
    format implementation. A format joins when the APPLICATION registers it -
    T<Format>SerializationRegistration.RegisterFormat, or
    TSerializationFormatsRegistration.RegisterAll - and never because a unit
    was linked or a package loaded: no unit registers from its
    initialization.

    LIFECYCLE. Register during startup and unregister during shutdown. Get
    hands out the handler itself, so a mutation of the registry must not run
    concurrently with serialization through it; reading it concurrently is
    safe. }
  TSerializationFormats = class
  strict private
    class var FHandlers: array[TSerializationFormat] of TSerializationFormatHandler;
    class var FLock: TCriticalSection;
  public
    class constructor Create;
    class destructor Destroy;

    { Registering the same format twice with the same handler class is a
      no-op; registering a DIFFERENT handler for a format already taken raises
      ESerializationFormatConflict. Unregistering an absent format is a no-op.
      The overloads with a handler class act only when that class holds the
      format, so a format's registration unit never removes a handler an
      application put there instead. }
    class procedure Register(AFormat: TSerializationFormat;
      AHandlerClass: TSerializationFormatHandlerClass); static;
    class procedure Unregister(AFormat: TSerializationFormat); overload; static;
    class procedure Unregister(AFormat: TSerializationFormat;
      AHandlerClass: TSerializationFormatHandlerClass); overload; static;

    class function IsRegistered(AFormat: TSerializationFormat): Boolean; overload; static;
    class function IsRegistered(AFormat: TSerializationFormat;
      AHandlerClass: TSerializationFormatHandlerClass): Boolean; overload; static;
    { Raises ESerializationFormatNotRegistered when absent. }
    class function Get(AFormat: TSerializationFormat): TSerializationFormatHandler; static;
    class function TryGet(AFormat: TSerializationFormat;
      out AHandler: TSerializationFormatHandler): Boolean; static;

    { Empty for a format nobody registered - "can it do this" is answerable
      without an exception.

      THE ANSWER IS ABOUT THE REGISTERED HANDLER, NOT ABOUT THE FORMAT, and
      it is asked fresh every time. A format whose schema lives outside the
      document answers no to the structural pair when the handler holding it
      has only the bytes - and yes when a handler that also has the schema is
      registered instead. Nothing caches this and nothing writes it down, so
      replacing a handler changes every answer that depends on it: the
      conversion matrix, the format dropdowns in a user interface, and
      StructuralFormats itself. }
    class function Capabilities(
      AFormat: TSerializationFormat): TSerializationFormatCapabilities; overload; static;
    class function Capabilities(AFormat: TSerializationFormat;
      const AOptions: TStructuralConversionOptions):
      TSerializationFormatCapabilities; overload; static;
    class function Supports(AFormat: TSerializationFormat;
      ACapability: TSerializationFormatCapability): Boolean; overload; static;
    class function Supports(AFormat: TSerializationFormat;
      ACapability: TSerializationFormatCapability;
      const AOptions: TStructuralConversionOptions): Boolean; overload; static;

    { Get, plus the capability check, with the right exception for each
      failure: ESerializationFormatNotRegistered when nothing registered the
      format, ESerializationFormatCapability when something did but it
      cannot do this. }
    class function Require(AFormat: TSerializationFormat;
      ACapability: TSerializationFormatCapability): TSerializationFormatHandler; overload; static;
    class function Require(AFormat: TSerializationFormat;
      ACapability: TSerializationFormatCapability;
      const AOptions: TStructuralConversionOptions): TSerializationFormatHandler; overload; static;

    class function FormatName(AFormat: TSerializationFormat): string; static;
    { The unit-name stem for this format's implementation, which is not
      always the enumeration name: the three ASN.1 encoding rules are three
      representations of one schema language and share one set of units. }
    class function UnitStem(AFormat: TSerializationFormat): string; static;
    { True for the encoding rules of ASN.1, which a caller sometimes has to
      treat as a group - one schema, three ways of writing it down. }
    class function IsAsn1(AFormat: TSerializationFormat): Boolean; static;
    class function RegisteredFormats: TArray<TSerializationFormat>; static;
  end;

{ ---------------------------------------------------------------------------
  UTF-8, SPELLED ONCE

  Delphi's TEncoding.UTF8 substitutes U+FFFD for a malformed sequence and
  says nothing, which turns "these bytes are not what you said they were"
  into silent data corruption three layers later. These two do the
  conversion explicitly and refuse malformed input by name.

  Neither ever touches the system code page, a locale, or an AnsiString.
  --------------------------------------------------------------------------- }

{ No BOM. A BOM in UTF-8 carries no information - there is no byte order to
  mark - and emitting one breaks consumers that expect the document to start
  with its first real character. }
function StringToUtf8Bytes(const AText: string): TBytes;

{ A leading BOM is accepted and skipped, because plenty of producers emit
  one. Anything malformed raises EInvalidUtf8 with the offset: overlong
  forms, truncated sequences, stray continuation bytes, surrogate code
  points encoded directly, and anything above U+10FFFF. }
function Utf8BytesToString(const ABytes: TBytes): string;

{ True when the bytes decode cleanly. For a caller that wants to ask rather
  than to catch. }
function IsValidUtf8(const ABytes: TBytes): Boolean;

implementation

uses
  System.NetEncoding, System.Variants, System.Math,
  { The library's own nullable is registered like any other family, from
    this unit's initialization.  Nothing below has a special case for it. }
  PascalForge.Nullable;

{ ===========================================================================
  UTF-8
  =========================================================================== }

constructor EInvalidUtf8.CreateAt(AOffset: Integer; const AReason: string);
begin
  FOffset := AOffset;
  inherited CreateFmt('Not valid UTF-8 at byte offset %d: %s.',
    [AOffset, AReason]);
end;

function StringToUtf8Bytes(const AText: string): TBytes;
var
  I: Integer;
  C: Char;
begin
  { A surrogate with no partner is half of a character, and UTF-8 has no
    encoding for it: TEncoding put U+FFFD in its place without a word, so
    the text that arrived was not the text that was written. It is refused
    instead, where it is. }
  I := 1;
  while I <= Length(AText) do
  begin
    C := AText[I];
    if (C >= #$D800) and (C <= #$DBFF) and (I < Length(AText)) and
       (AText[I + 1] >= #$DC00) and (AText[I + 1] <= #$DFFF) then
      Inc(I, 2)
    else if (C >= #$D800) and (C <= #$DFFF) then
      raise ESerializationUnsupported.CreateFmt(
        'The text holds an unpaired UTF-16 surrogate, U+%.4X at character %d, ' +
        'which UTF-8 cannot encode: it is half of a character. Remove it, or ' +
        'carry the value as bytes.', [Ord(C), I])
    else
      Inc(I);
  end;
  { TEncoding.UTF8 without a preamble.  GetBytes itself never writes one;
    only GetPreamble does, and nothing here calls it. }
  Result := TEncoding.UTF8.GetBytes(AText);
end;

{ The one decoder.  Written out rather than delegated because
  TEncoding.UTF8.GetString silently replaces malformed input, and silently
  is exactly what this must not be. }
function DecodeUtf8(const ABytes: TBytes; ARaise: Boolean;
  out AText: string): Boolean;
var
  I, N, Start, Extra, CP, J, B: Integer;
  SB: TStringBuilder;

  function Fail(AOffset: Integer; const AReason: string): Boolean;
  begin
    if ARaise then raise EInvalidUtf8.CreateAt(AOffset, AReason);
    Result := False;
  end;

begin
  AText := '';
  { A Delphi string's length is an Integer, so more bytes than that can never
    be one; refused here rather than wrapped. A dynamic array's length is
    NativeInt, so only a 64-bit target can hold that many. }
  {$IFDEF CPU64BITS}
  if Length(ABytes) > High(Integer) then
    Exit(Fail(0, 'the text is longer than a string can hold'));
  {$ENDIF}
  N := Integer(Length(ABytes));
  if N = 0 then Exit(True);

  I := 0;
  { A UTF-8 BOM carries no information, but producers emit it anyway. }
  if (N >= 3) and (ABytes[0] = $EF) and (ABytes[1] = $BB) and (ABytes[2] = $BF) then
    I := 3;

  SB := TStringBuilder.Create(N);
  try
    while I < N do
    begin
      Start := I;
      B := ABytes[I];
      if B < $80 then
      begin
        SB.Append(Char(B));
        Inc(I);
        Continue;
      end;

      if (B and $E0) = $C0 then begin CP := B and $1F; Extra := 1 end
      else if (B and $F0) = $E0 then begin CP := B and $0F; Extra := 2 end
      else if (B and $F8) = $F0 then begin CP := B and $07; Extra := 3 end
      else if (B and $C0) = $80 then
        Exit(Fail(Start, 'a continuation byte with nothing to continue'))
      else
        Exit(Fail(Start, Format('byte $%.2X starts no valid sequence', [B])));

      if I + Extra >= N then
        Exit(Fail(Start, Format('a %d-byte sequence is cut off by the end of ' +
          'the input', [Extra + 1])));

      for J := 1 to Extra do
      begin
        B := ABytes[I + J];
        if (B and $C0) <> $80 then
          Exit(Fail(Start, Format('byte %d of the sequence is $%.2X, which is ' +
            'not a continuation byte', [J + 1, B])));
        CP := (CP shl 6) or (B and $3F);
      end;
      Inc(I, Extra + 1);

      { Overlong forms are rejected: they are a second spelling of a code
        point that already has one, and accepting them is a classic way past
        a filter that checked the first spelling. }
      if ((Extra = 1) and (CP < $80)) or ((Extra = 2) and (CP < $800)) or
         ((Extra = 3) and (CP < $10000)) then
        Exit(Fail(Start, Format('U+%.4X is encoded in %d bytes when it needs ' +
          'fewer - an overlong form', [CP, Extra + 1])));

      if (CP >= $D800) and (CP <= $DFFF) then
        Exit(Fail(Start, Format('U+%.4X is half of a surrogate pair, which is ' +
          'not a character and cannot be encoded', [CP])));
      if CP > $10FFFF then
        Exit(Fail(Start, Format('U+%.4X is above the last code point',  [CP])));

      if CP < $10000 then
        SB.Append(Char(CP))
      else
      begin
        { Delphi strings are UTF-16, so a supplementary code point becomes a
          surrogate pair here.  It is still one character to the reader. }
        Dec(CP, $10000);
        SB.Append(Char($D800 or (CP shr 10)));
        SB.Append(Char($DC00 or (CP and $3FF)));
      end;
    end;
    AText := SB.ToString;
    Result := True;
  finally
    SB.Free;
  end;
end;

function Utf8BytesToString(const ABytes: TBytes): string;
begin
  DecodeUtf8(ABytes, True, Result);
end;

function IsValidUtf8(const ABytes: TBytes): Boolean;
var
  Ignored: string;
begin
  Result := DecodeUtf8(ABytes, False, Ignored);
end;

{ ===========================================================================
  STRUCTURAL CONVERSION POLICY
  =========================================================================== }

class function TStructuralConversionOptions.FromProfile(
  AProfile: TStructuralConversionProfile): TStructuralConversionOptions;
begin
  { EVERY FIELD, spelled out.

    Two reasons, and the second is the one that bites. First, this record has
    a class function called Default, so the Default(...) intrinsic loses to
    it and cannot be used. Second - and this is why every field appears and
    not just the interesting ones - a record with no managed fields is NOT
    zero-initialised on the stack, so a field left out here holds whatever
    was there before. The schema fields are object references, and a garbage
    object reference is an access violation somewhere else entirely. }
  Result.SourceFormat := TSerializationFormat.Json;
  Result.SourceFormatKnown := False;
  Result.DestinationFormat := TSerializationFormat.Json;
  Result.DestinationFormatKnown := False;
  Result.SourceContext := nil;
  Result.DestinationContext := nil;
  case AProfile of
    TStructuralConversionProfile.Natural:
      begin
        Result.NamePolicy := TStructuralNamePolicy.Encode;
        Result.ValuePolicy := TStructuralValuePolicy.Natural;
      end;
    TStructuralConversionProfile.Lossless:
      begin
        Result.NamePolicy := TStructuralNamePolicy.Encode;
        Result.ValuePolicy := TStructuralValuePolicy.Lossless;
      end;
    TStructuralConversionProfile.Strict:
      begin
        Result.NamePolicy := TStructuralNamePolicy.Error;
        Result.ValuePolicy := TStructuralValuePolicy.Error;
      end;
  end;
end;

class function TStructuralConversionOptions.Default: TStructuralConversionOptions;
begin
  Result := FromProfile(TStructuralConversionProfile.Natural);
end;

function TStructuralConversionOptions.WithSource(
  AFormat: TSerializationFormat): TStructuralConversionOptions;
begin
  Result := Self;
  Result.SourceFormat := AFormat;
  Result.SourceFormatKnown := True;
end;

function TStructuralConversionOptions.WithDestination(
  AFormat: TSerializationFormat): TStructuralConversionOptions;
begin
  Result := Self;
  Result.DestinationFormat := AFormat;
  Result.DestinationFormatKnown := True;
end;

{ A context matches a format when it IS for that format. ASN.1's three
  encoding rules share one schema language, so a module parsed for DER is the
  same module for BER, and that is the one equivalence there is. }
function ContextMatches(AContext: TSerializationContext;
  AFormat: TSerializationFormat): Boolean;
begin
  Result := (AContext <> nil) and
            ((AContext.Format = AFormat) or
             (TSerializationFormats.IsAsn1(AFormat) and
              TSerializationFormats.IsAsn1(AContext.Format)));
end;

function TStructuralConversionOptions.WithSourceContext(
  AContext: TSerializationContext): TStructuralConversionOptions;
begin
  Result := Self;
  Result.SourceContext := AContext;
end;

function TStructuralConversionOptions.WithDestinationContext(
  AContext: TSerializationContext): TStructuralConversionOptions;
begin
  Result := Self;
  Result.DestinationContext := AContext;
end;

function TStructuralConversionOptions.PlaceContexts: TStructuralConversionOptions;
begin
  Result := Self;
  if not (SourceFormatKnown and DestinationFormatKnown) then Exit;

  { Exactly one context, sitting in the slot whose end it does NOT match,
    while the slot it does match is empty. Nothing else is touched: two
    contexts are the caller having said what they meant, and a context that
    matches its own slot is already right. }
  if (Result.SourceContext <> nil) and (Result.DestinationContext = nil) and
     (not ContextMatches(Result.SourceContext, Result.SourceFormat)) and
     ContextMatches(Result.SourceContext, Result.DestinationFormat) then
  begin
    Result.DestinationContext := Result.SourceContext;
    Result.SourceContext := nil;
    Exit;
  end;

  if (Result.DestinationContext <> nil) and (Result.SourceContext = nil) and
     (not ContextMatches(Result.DestinationContext,
       Result.DestinationFormat)) and
     ContextMatches(Result.DestinationContext, Result.SourceFormat) then
  begin
    Result.SourceContext := Result.DestinationContext;
    Result.DestinationContext := nil;
  end;
end;

function TStructuralConversionOptions.WithContext(
  AContext: TSerializationContext): TStructuralConversionOptions;
var
  MatchesSource, MatchesDestination: Boolean;
begin
  Result := Self;
  if AContext = nil then Exit;

  MatchesSource := SourceFormatKnown and
    ContextMatches(AContext, SourceFormat);
  MatchesDestination := DestinationFormatKnown and
    ContextMatches(AContext, DestinationFormat);

  { BOTH ENDS ARE THIS FORMAT: there is nothing left to decide with, and
    picking one is how a conversion ends up reading schema A and writing it
    straight back as schema A. }
  if MatchesSource and MatchesDestination then
    raise ESerializationSchemaRequired.CreateAmbiguousRole(AContext.Format);

  if MatchesSource then Result.SourceContext := AContext
  else if MatchesDestination then Result.DestinationContext := AContext
  else
  begin
    { Neither end is known to be this format - which happens when the caller
      builds options without saying the ends, as the typed entry points do.
      Filling the empty slot keeps that case working; the ambiguity above is
      the only one that cannot be resolved. }
    if Result.SourceContext = nil then Result.SourceContext := AContext
    else Result.DestinationContext := AContext;
  end;
end;

function TStructuralConversionOptions.SourceContextFor(
  AFormat: TSerializationFormat): TSerializationContext;
begin
  if ContextMatches(SourceContext, AFormat) then Exit(SourceContext);
  Result := nil;
end;

function TStructuralConversionOptions.DestinationContextFor(
  AFormat: TSerializationFormat): TSerializationContext;
begin
  if ContextMatches(DestinationContext, AFormat) then Exit(DestinationContext);
  Result := nil;
end;

function TStructuralConversionOptions.AnyContextFor(
  AFormat: TSerializationFormat): TSerializationContext;
begin
  if ContextMatches(SourceContext, AFormat) then Exit(SourceContext);
  if ContextMatches(DestinationContext, AFormat) then Exit(DestinationContext);
  Result := nil;
end;

function TStructuralConversionOptions.RequireSourceContext(
  AFormat: TSerializationFormat;
  const AWhat: string): TSerializationContext;
begin
  Result := SourceContextFor(AFormat);
  if Result = nil then
    raise ESerializationSchemaRequired.CreateFor(AFormat, AWhat);
end;

function TStructuralConversionOptions.RequireDestinationContext(
  AFormat: TSerializationFormat;
  const AWhat: string): TSerializationContext;
begin
  Result := DestinationContextFor(AFormat);
  if Result = nil then
    raise ESerializationSchemaRequired.CreateFor(AFormat, AWhat);
end;

{ --- TStructuralRoute ----------------------------------------------------- }

function TStructuralRoute.HopCount: Integer;
begin
  Result := Integer(Length(Steps));
end;

function TStructuralRoute.IsComposed: Boolean;
begin
  Result := Length(Steps) > 1;
end;

function TStructuralRoute.Describe: string;
var
  I: NativeInt;
begin
  Result := '';
  for I := 0 to High(Steps) do
  begin
    if I = 0 then
      Result := TSerializationFormats.FormatName(Steps[I].FromFormat);
    if Steps[I].Standard <> '' then
      Result := Result + ' -> ' + Steps[I].Standard;
    Result := Result + ' -> ' +
      TSerializationFormats.FormatName(Steps[I].ToFormat);
  end;
end;

class function TStructuralRoute.Direct(AFrom, ATo: TSerializationFormat;
  const AStandard: string): TStructuralRoute;
var
  Step: TStructuralRouteStep;
begin
  Step.FromFormat := AFrom;
  Step.ToFormat := ATo;
  Step.Standard := AStandard;
  Result.Steps := [Step];
end;

function TSerializationContext.Describe: string;
begin
  Result := TSerializationFormats.FormatName(Format) + ' context';
end;

constructor ESerializationSchemaRequired.CreateFor(
  AFormat: TSerializationFormat; const AWhat: string);
begin
  FFormat := AFormat;
  inherited CreateFmt(
    '%s cannot %s without a schema.' + sLineBreak + sLineBreak +
    'Its documents carry values but not the names and types of those ' +
    'values, so there is nothing to read them AS. Load the schema and pass ' +
    'it in the conversion options.',
    [TSerializationFormats.FormatName(AFormat).ToUpper, AWhat]);
end;

constructor ESerializationSchemaRequired.CreateMismatch(
  AExpected, AActual: TSerializationFormat);
begin
  FFormat := AExpected;
  inherited CreateFmt(
    'This is a %s schema and %s was asked for.',
    [TSerializationFormats.FormatName(AActual),
     TSerializationFormats.FormatName(AExpected)]);
end;

constructor ESerializationSchemaRequired.CreateAmbiguousRole(
  AFormat: TSerializationFormat);
begin
  FFormat := AFormat;
  inherited CreateFmt(
    'Both ends of this conversion are %s, so one context cannot say which ' +
    'end it belongs to.' + sLineBreak + sLineBreak +
    'Say it explicitly: WithSourceContext for the document being read and ' +
    'WithDestinationContext for the one being written. Converting between ' +
    'two schemas of the same format is exactly the case the two roles ' +
    'exist for.',
    [TSerializationFormats.FormatName(AFormat)]);
end;

function TStructuralConversionOptions.DestinationIs(
  AFormat: TSerializationFormat): Boolean;
begin
  Result := DestinationFormatKnown and (DestinationFormat = AFormat);
end;

constructor EStructuralConversionError.CreateFor(AIssue: TStructuralIssue;
  const AOptions: TStructuralConversionOptions;
  ADestination: TSerializationFormat; const APath: string;
  ASourceKind: TDynamicKind; const AReason: string);
var
  Where: string;
begin
  FIssue := AIssue;
  FSourceFormat := AOptions.SourceFormat;
  FSourceFormatKnown := AOptions.SourceFormatKnown;
  FDestinationFormat := ADestination;
  FPath := APath;
  FSourceKind := ASourceKind;
  FReason := AReason;

  if FSourceFormatKnown then
    Where := Format('%s -> %s',
      [TSerializationFormats.FormatName(FSourceFormat),
       TSerializationFormats.FormatName(FDestinationFormat)])
  else
    Where := Format('-> %s',
      [TSerializationFormats.FormatName(FDestinationFormat)]);

  { The five things the caller needs in order to act, all in the one line
    they will actually read: which pair, where in the document, what the
    value was, and why. }
  inherited CreateFmt('Structural conversion %s failed at %s (%s): %s',
    [Where, APath, KindName(ASourceKind), AReason]);
end;

class function EStructuralConversionError.KindName(
  AKind: TDynamicKind): string;
begin
  Result := TDynamicValue.KindName(AKind);
end;

class function TStructuralPath.Root: string;
begin
  Result := '$';
end;

class function TStructuralPath.Member(const APath, AName: string): string;
begin
  Result := APath + '.' + AName;
end;

class function TStructuralPath.Index(const APath: string;
  AIndex: Integer): string;
begin
  Result := Format('%s[%d]', [APath, AIndex]);
end;

{ ------------------------------------------------- the natural forms --- }

class function TStructuralText.EncodeDateTime(AValue: TDateTime): string;
begin
  CheckDateTime(AValue);
  Result := FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"."zzz', AValue,
    TFormatSettings.Invariant);
end;

class function TStructuralText.TryDecodeDateTime(const AText: string;
  out AValue: TDateTime): Boolean;
var
  Y, M, D, H, N, S, Z: Integer;
  DatePart, TimePart: TDateTime;
begin
  AValue := 0;
  { Exactly the shape EncodeDateTime writes, parsed by position rather than
    by locale: yyyy-mm-ddThh:nn:ss.zzz }
  if Length(AText) <> 23 then Exit(False);
  if (AText[5] <> '-') or (AText[8] <> '-') or (AText[11] <> 'T') or
     (AText[14] <> ':') or (AText[17] <> ':') or (AText[20] <> '.') then
    Exit(False);
  if not (TryStrToInt(Copy(AText, 1, 4), Y) and TryStrToInt(Copy(AText, 6, 2), M) and
          TryStrToInt(Copy(AText, 9, 2), D) and TryStrToInt(Copy(AText, 12, 2), H) and
          TryStrToInt(Copy(AText, 15, 2), N) and TryStrToInt(Copy(AText, 18, 2), S) and
          TryStrToInt(Copy(AText, 21, 3), Z)) then
    Exit(False);
  if not TryEncodeDate(Word(Y), Word(M), Word(D), DatePart) then Exit(False);
  if not TryEncodeTime(Word(H), Word(N), Word(S), Word(Z), TimePart) then
    Exit(False);
  AValue := ComposeDateTime(DatePart, TimePart);
  Result := True;
end;

class function TStructuralText.EncodeDate(AValue: TDateTime): string;
begin
  CheckDateTime(AValue);
  Result := FormatDateTime('yyyy-mm-dd', AValue, TFormatSettings.Invariant);
end;

const
  { 0001-01-01 is day -693593; a negative day's times run toward -693594. }
  DATETIME_LOWER = -693594.0;
  { 10000-01-01, exclusive. }
  DATETIME_UPPER = 2958466.0;
  { DateTimeToTimeStamp(UnixDateDelta).Date: 1970-01-01. }
  UNIX_EPOCH_TIMESTAMP_DAYS = 719163;

class function TStructuralText.IsDateTimeInRange(AValue: TDateTime): Boolean;
begin
  Result := not (Double(AValue).IsNan or Double(AValue).IsInfinity) and
    (AValue > DATETIME_LOWER) and (AValue < DATETIME_UPPER);
end;

class procedure TStructuralText.CheckDateTime(AValue: TDateTime);
begin
  if not IsDateTimeInRange(AValue) then
    raise ESerializationUnsupported.CreateFmt(
      'The TDateTime %s is outside the years 1 to 9999: no date format here ' +
      'can state it, and every reader here refuses it.',
      [FloatToStr(AValue, TFormatSettings.Invariant)]);
end;

class function TStructuralText.ComposeDateTime(ADate,
  ATime: TDateTime): TDateTime;
begin
  if ADate < 0 then Result := ADate - ATime
  else Result := ADate + ATime;
end;

class function TStructuralText.TryDateTimeToUnixMillis(AValue: TDateTime;
  out AMillis: Int64): Boolean;
var
  Stamp: TTimeStamp;
begin
  AMillis := 0;
  if not IsDateTimeInRange(AValue) then Exit(False);
  { DateTimeToTimeStamp follows the encoding: whole days from the integral
    part, the time of day from the absolute value of the fraction. }
  Stamp := DateTimeToTimeStamp(AValue);
  AMillis := (Int64(Stamp.Date) - UNIX_EPOCH_TIMESTAMP_DAYS) * MSecsPerDay +
    Stamp.Time;
  Result := AMillis <= Int64(253402300799) * 1000 + 999;
end;

const
  UNIX_MIN_SECONDS = Int64(-62135596800);   { 0001-01-01T00:00:00 }
  UNIX_MAX_SECONDS = Int64(253402300799);   { 9999-12-31T23:59:59 }

class function TStructuralText.TryUnixSecondsToDateTime(ASeconds: Int64;
  out AValue: TDateTime): Boolean;
begin
  AValue := 0;
  Result := (ASeconds >= UNIX_MIN_SECONDS) and (ASeconds <= UNIX_MAX_SECONDS);
  if Result then AValue := UnixToDateTime(ASeconds, True);
end;

class function TStructuralText.TryUnixMillisToDateTime(AMillis: Int64;
  out AValue: TDateTime): Boolean;
begin
  AValue := 0;
  Result := (AMillis >= UNIX_MIN_SECONDS * 1000) and
    (AMillis <= UNIX_MAX_SECONDS * 1000 + 999);
  if Result then AValue := IncMilliSecond(UnixDateDelta, AMillis);
end;

class function TStructuralText.TryUnixFloatSecondsToDateTime(ASeconds: Double;
  out AValue: TDateTime): Boolean;
begin
  AValue := 0;
  if ASeconds.IsNan or ASeconds.IsInfinity or (ASeconds < UNIX_MIN_SECONDS) or
     (ASeconds >= UNIX_MAX_SECONDS + 1) then Exit(False);
  Result := TryUnixMillisToDateTime(Round(ASeconds * MSecsPerSec), AValue);
end;

class function TStructuralText.TryDecodeDate(const AText: string;
  out AValue: TDateTime): Boolean;
var
  Y, M, D: Integer;
begin
  AValue := 0;
  if Length(AText) <> 10 then Exit(False);
  if (AText[5] <> '-') or (AText[8] <> '-') then Exit(False);
  if not (TryStrToInt(Copy(AText, 1, 4), Y) and
          TryStrToInt(Copy(AText, 6, 2), M) and
          TryStrToInt(Copy(AText, 9, 2), D)) then Exit(False);
  Result := TryEncodeDate(Word(Y), Word(M), Word(D), AValue);
end;

class function TStructuralText.EncodeTime(AValue: TDateTime): string;
begin
  Result := FormatDateTime('hh:nn:ss.zzz', AValue, TFormatSettings.Invariant);
end;

class function TStructuralText.TryDecodeTime(const AText: string;
  out AValue: TDateTime): Boolean;
var
  H, N, S, Z: Integer;
begin
  { hh:nn:ss with the milliseconds optional, because a whole second is the
    common case and writing .000 for it is noise a reader has to forgive. }
  AValue := 0;
  if (Length(AText) <> 8) and (Length(AText) <> 12) then Exit(False);
  if (AText[3] <> ':') or (AText[6] <> ':') then Exit(False);
  Z := 0;
  if Length(AText) = 12 then
  begin
    if AText[9] <> '.' then Exit(False);
    if not TryStrToInt(Copy(AText, 10, 3), Z) then Exit(False);
  end;
  if not (TryStrToInt(Copy(AText, 1, 2), H) and
          TryStrToInt(Copy(AText, 4, 2), N) and
          TryStrToInt(Copy(AText, 7, 2), S)) then Exit(False);
  Result := TryEncodeTime(Word(H), Word(N), Word(S), Word(Z), AValue);
end;

class function TStructuralText.TryDecodePattern(const AText, APattern: string;
  out AValue: TDateTime): Boolean;
var
  P, T, Width, Y, M, D, H, N, S, Z: Integer;
  Letter, LastLetter, Quote: Char;
  DatePart, TimePart: TDateTime;

  { The run of one specifier letter at P: 'yyyy' is 4. }
  function RunLength: Integer;
  begin
    Result := 1;
    while (P + Result <= Length(APattern)) and
          (UpCase(APattern[P + Result]) = UpCase(APattern[P])) do
      Inc(Result);
  end;

  { AMin to AMax digits at T: a doubled specifier is fixed width, a single
    one writes no leading zero. }
  function Digits(AMin, AMax: Integer; out ANumber: Integer): Boolean;
  var
    Count: Integer;
  begin
    ANumber := 0;
    Count := 0;
    while (Count < AMax) and (T <= Length(AText)) and
          CharInSet(AText[T], ['0'..'9']) do
    begin
      ANumber := ANumber * 10 + Ord(AText[T]) - Ord('0');
      Inc(T);
      Inc(Count);
    end;
    Result := Count >= AMin;
  end;

begin
  AValue := 0;
  Result := False;
  if APattern = '' then Exit;
  Y := 1899; M := 12; D := 30;
  H := 0; N := 0; S := 0; Z := 0;
  P := 1;
  T := 1;
  LastLetter := #0;
  while P <= Length(APattern) do
  begin
    if (APattern[P] = '"') or (APattern[P] = '''') then
    begin
      { Quoted text is written as itself, specifier letters included. }
      Quote := APattern[P];
      Inc(P);
      while (P <= Length(APattern)) and (APattern[P] <> Quote) do
      begin
        if (T > Length(AText)) or (AText[T] <> APattern[P]) then Exit;
        Inc(P);
        Inc(T);
      end;
      Inc(P);
      Continue;
    end;
    Letter := UpCase(APattern[P]);
    if CharInSet(Letter, ['Y', 'M', 'D', 'H', 'N', 'S', 'Z']) then
    begin
      Width := RunLength;
      { FormatDateTime's own rule: an m right after an h is the minute. }
      if (Letter = 'M') and (LastLetter = 'H') then Letter := 'N';
      case Letter of
        'Y':
          if Width <= 2 then
          begin
            if not Digits(2, 2, Y) then Exit;
            Inc(Y, 2000);
          end
          else if (Width > 4) or not Digits(4, 4, Y) then Exit;
        'M': if (Width > 2) or not Digits(Width, 2, M) then Exit;
        'D': if (Width > 2) or not Digits(Width, 2, D) then Exit;
        'H': if (Width > 2) or not Digits(Width, 2, H) then Exit;
        'N': if (Width > 2) or not Digits(Width, 2, N) then Exit;
        'S': if (Width > 2) or not Digits(Width, 2, S) then Exit;
        'Z': if not (Width in [1, 3]) or not Digits(Width, 3, Z) then Exit;
      end;
      LastLetter := Letter;
      Inc(P, Width);
      Continue;
    end;
    { A specifier that writes words, or one this reader does not know. }
    if CharInSet(Letter, ['A'..'Z']) then Exit;
    { Everything else is written as itself - '/' and ':' too, under the
      invariant settings every writer here formats with. }
    if (T > Length(AText)) or (AText[T] <> APattern[P]) then Exit;
    Inc(P);
    Inc(T);
  end;
  if T <= Length(AText) then Exit;
  if not TryEncodeDate(Word(Y), Word(M), Word(D), DatePart) or
     not TryEncodeTime(Word(H), Word(N), Word(S), Word(Z), TimePart) then Exit;
  AValue := ComposeDateTime(DatePart, TimePart);
  Result := True;
end;

class function TStructuralText.DecodeIso8601(const AText: string): TDateTime;
var
  S, Offset: string;
  I, TPos, Hours, Minutes, OffsetMinutes: Integer;
  Millis: Int64;
begin
  S := Trim(AText);
  OffsetMinutes := 0;
  { The offset follows the time, so it is looked for only after the T - the
    date's own hyphens are not a sign. }
  TPos := Pos('T', UpperCase(S));
  if TPos > 0 then
  begin
    if CharInSet(S[Length(S)], ['Z', 'z']) then
      SetLength(S, Length(S) - 1)
    else
    begin
      I := Length(S);
      while (I > TPos) and not CharInSet(S[I], ['+', '-']) do Dec(I);
      if I > TPos then
      begin
        Offset := StringReplace(Copy(S, I + 1, MaxInt), ':', '', []);
        Minutes := 0;
        if not ((Length(Offset) = 2) or (Length(Offset) = 4)) or
           not TryStrToInt(Copy(Offset, 1, 2), Hours) or
           ((Length(Offset) = 4) and
            not TryStrToInt(Copy(Offset, 3, 2), Minutes)) or
           (Hours > 23) or (Minutes > 59) then
          raise EConvertError.CreateFmt(
            '"%s" is not an ISO 8601 date and time.', [AText]);
        OffsetMinutes := Hours * 60 + Minutes;
        if S[I] = '-' then OffsetMinutes := -OffsetMinutes;
        SetLength(S, I - 1);
      end;
    end;
  end;
  Result := ISO8601ToDate(S, True);
  if OffsetMinutes <> 0 then
    if not TryDateTimeToUnixMillis(Result, Millis) or
       not TryUnixMillisToDateTime(Millis - Int64(OffsetMinutes) * 60000,
         Result) then
      raise EConvertError.CreateFmt(
        '"%s" is outside the years 1 to 9999.', [AText]);
end;

class function TStructuralText.EncodeBinary(const AValue: TBytes): string;
begin
  Result := TNetEncoding.Base64String.EncodeBytesToString(AValue);
end;

class function TStructuralText.TryDecodeBinary(const AText: string;
  out AValue: TBytes): Boolean;
begin
  AValue := nil;
  try
    AValue := TNetEncoding.Base64String.DecodeStringToBytes(AText);
    Result := True;
  except
    Result := False;
  end;
end;

const
  HEX_DIGITS: array[0..15] of Char =
    ('0', '1', '2', '3', '4', '5', '6', '7',
     '8', '9', 'a', 'b', 'c', 'd', 'e', 'f');

{ ===========================================================================
  EXACT DECIMAL <-> BINARY

  A small unsigned big integer, just enough for two exact conversions: text
  to the nearest double, and a double to its exact decimal digits. Limbs are
  32 bits, least significant first, with no leading zero limb (so zero is
  the empty array). Nothing here is fast for pathological input - a
  700-digit number - and nothing needs to be: ordinary numbers take the
  fast paths, and correctness is the point.
  =========================================================================== }

type
  TBigNat = TArray<Cardinal>;

procedure BigTrim(var A: TBigNat);
var
  N: NativeInt;
begin
  N := Length(A);
  while (N > 0) and (A[N - 1] = 0) do Dec(N);
  SetLength(A, N);
end;

function BigFromUInt64(AValue: UInt64): TBigNat;
begin
  Result := nil;
  while AValue <> 0 do
  begin
    Result := Result + [Cardinal(AValue and $FFFFFFFF)];
    AValue := AValue shr 32;
  end;
end;

procedure BigMulAddSmall(var A: TBigNat; AMul, AAdd: Cardinal);
var
  I: NativeInt;
  Carry, T: UInt64;
begin
  Carry := AAdd;
  for I := 0 to High(A) do
  begin
    T := UInt64(A[I]) * AMul + Carry;
    A[I] := Cardinal(T and $FFFFFFFF);
    Carry := T shr 32;
  end;
  if Carry <> 0 then A := A + [Cardinal(Carry)];
end;

function BigDivModSmall(var A: TBigNat; ADivisor: Cardinal): Cardinal;
var
  I: NativeInt;
  R, T: UInt64;
begin
  R := 0;
  for I := High(A) downto 0 do
  begin
    T := (R shl 32) or A[I];
    A[I] := Cardinal(T div ADivisor);
    R := T mod ADivisor;
  end;
  BigTrim(A);
  Result := Cardinal(R);
end;

function BigBitLength(const A: TBigNat): Integer;
var
  Top: Cardinal;
begin
  if Length(A) = 0 then Exit(0);
  Result := Integer((Length(A) - 1) * 32);
  Top := A[High(A)];
  while Top <> 0 do
  begin
    Inc(Result);
    Top := Top shr 1;
  end;
end;

function BigBit(const A: TBigNat; AIndex: Integer): Boolean;
begin
  if (AIndex < 0) or ((AIndex shr 5) > High(A)) then Exit(False);
  Result := ((A[AIndex shr 5] shr (AIndex and 31)) and 1) <> 0;
end;

{ Any bit set below position ABit. }
function BigAnyBelow(const A: TBigNat; ABit: Integer): Boolean;
var
  I, W: Integer;
begin
  Result := False;
  if ABit <= 0 then Exit;
  W := ABit shr 5;
  for I := 0 to Integer(Min(W, Length(A))) - 1 do
    if A[I] <> 0 then Exit(True);
  if (W <= High(A)) and ((ABit and 31) <> 0) then
    Result := (A[W] and ((Cardinal(1) shl (ABit and 31)) - 1)) <> 0;
end;

{ AWidth bits of A starting at AFrom, AWidth at most 64. }
function BigExtract(const A: TBigNat; AFrom, AWidth: Integer): UInt64;
var
  I: Integer;
begin
  Result := 0;
  for I := AWidth - 1 downto 0 do
    Result := (Result shl 1) or UInt64(Ord(BigBit(A, AFrom + I)));
end;

function BigShl(const A: TBigNat; ABits: Integer): TBigNat;
var
  Words, Bits: Integer;
  I: NativeInt;
  Carry: Cardinal;
begin
  if (Length(A) = 0) or (ABits <= 0) then Exit(Copy(A));
  Words := ABits shr 5;
  Bits := ABits and 31;
  SetLength(Result, Length(A) + Words + 1);
  for I := 0 to Words - 1 do Result[I] := 0;
  Carry := 0;
  for I := 0 to High(A) do
    if Bits = 0 then
      Result[I + Words] := A[I]
    else
    begin
      Result[I + Words] := (A[I] shl Bits) or Carry;
      Carry := A[I] shr (32 - Bits);
    end;
  Result[High(Result)] := Carry;
  BigTrim(Result);
end;

procedure BigShl1(var A: TBigNat; ALowBit: Boolean);
var
  I: NativeInt;
  Carry, Next: Cardinal;
begin
  Carry := Cardinal(Ord(ALowBit));
  for I := 0 to High(A) do
  begin
    Next := A[I] shr 31;
    A[I] := (A[I] shl 1) or Carry;
    Carry := Next;
  end;
  if Carry <> 0 then A := A + [Carry];
end;

function BigCompare(const A, B: TBigNat): Integer;
var
  I: NativeInt;
begin
  if Length(A) <> Length(B) then
    if Length(A) > Length(B) then Exit(1) else Exit(-1);
  for I := High(A) downto 0 do
    if A[I] <> B[I] then
      if A[I] > B[I] then Exit(1) else Exit(-1);
  Result := 0;
end;

{ A := A - B, for A >= B. }
procedure BigSub(var A: TBigNat; const B: TBigNat);
var
  I: NativeInt;
  T, Borrow: Int64;
begin
  Borrow := 0;
  for I := 0 to High(A) do
  begin
    T := Int64(A[I]) - Borrow;
    if I <= High(B) then T := T - Int64(B[I]);
    if T < 0 then
    begin
      Inc(T, Int64($100000000));
      Borrow := 1;
    end
    else
      Borrow := 0;
    A[I] := Cardinal(T);
  end;
  BigTrim(A);
end;

procedure BigDivMod(const N, D: TBigNat; out Q, R: TBigNat);
var
  I, L: Integer;
begin
  L := BigBitLength(N);
  SetLength(Q, (L + 31) shr 5);
  for I := 0 to Integer(High(Q)) do Q[I] := 0;
  R := nil;
  for I := L - 1 downto 0 do
  begin
    BigShl1(R, BigBit(N, I));
    if BigCompare(R, D) >= 0 then
    begin
      BigSub(R, D);
      Q[I shr 5] := Q[I shr 5] or (Cardinal(1) shl (I and 31));
    end;
  end;
  BigTrim(Q);
end;

function BigPow10(AExponent: Integer): TBigNat;
begin
  Result := [1];
  while AExponent >= 9 do
  begin
    BigMulAddSmall(Result, 1000000000, 0);
    Dec(AExponent, 9);
  end;
  while AExponent > 0 do
  begin
    BigMulAddSmall(Result, 10, 0);
    Dec(AExponent);
  end;
end;

function BigFromDigits(const ADigits: string): TBigNat;
var
  I, Chunk, Count: Integer;
  Mul: Cardinal;
begin
  Result := nil;
  I := 1;
  while I <= Length(ADigits) do
  begin
    Chunk := 0;
    Count := 0;
    Mul := 1;
    while (I <= Length(ADigits)) and (Count < 9) do
    begin
      Chunk := Chunk * 10 + (Ord(ADigits[I]) - Ord('0'));
      Mul := Mul * 10;
      Inc(Count);
      Inc(I);
    end;
    BigMulAddSmall(Result, Mul, Cardinal(Chunk));
  end;
end;

function BigToDigits(const A: TBigNat): string;
var
  W: TBigNat;
  Chunk: Cardinal;
  Part: string;
begin
  if Length(A) = 0 then Exit('0');
  W := Copy(A);
  Result := '';
  while Length(W) > 0 do
  begin
    Chunk := BigDivModSmall(W, 1000000000);
    Part := IntToStr(Chunk);
    if Length(W) > 0 then Part := StringOfChar('0', 9 - Length(Part)) + Part;
    Result := Part + Result;
  end;
end;

{ The double nearest to Q * 2^-AScale, where ASticky says the true value is a
  little more than that; ties to even. Q is not zero. }
function BigToDouble(const Q: TBigNat; AScale: Integer;
  ASticky, ANegative: Boolean): Double;
var
  L, E2, U, Shift, Field: Integer;
  M, Bits: UInt64;
  RoundBit, Rest: Boolean;
begin
  L := BigBitLength(Q);
  E2 := L - 1 - AScale;
  if E2 > 1100 then
    Bits := UInt64($7FF) shl 52
  else if E2 < -1200 then
    Bits := 0
  else
  begin
    { The unit in the last place: 52 bits below the leading one, but never
      below the smallest subnormal. }
    U := E2 - 52;
    if U < -1074 then U := -1074;
    Shift := U + AScale;
    if Shift <= 0 then
      M := BigExtract(Q, 0, L) shl (-Shift)
    else
    begin
      M := BigExtract(Q, Shift, L - Shift);
      RoundBit := BigBit(Q, Shift - 1);
      Rest := ASticky or BigAnyBelow(Q, Shift - 1);
      if RoundBit and (Rest or Odd(M)) then Inc(M);
      if M = (UInt64(1) shl 53) then
      begin
        M := M shr 1;
        Inc(U);
      end;
    end;
    if M >= (UInt64(1) shl 52) then
    begin
      Field := U + 1075;
      if Field >= 2047 then Bits := UInt64($7FF) shl 52
      else Bits := (UInt64(Field) shl 52) or (M and ((UInt64(1) shl 52) - 1));
    end
    else
      Bits := M;   { a subnormal, or zero }
  end;
  if ANegative then Bits := Bits or (UInt64(1) shl 63);
  Move(Bits, Result, SizeOf(Result));
end;

const
  EXACT_POWERS_OF_TEN: array[0..22] of Double = (1e0, 1e1, 1e2, 1e3, 1e4,
    1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17,
    1e18, 1e19, 1e20, 1e21, 1e22);
  { Digits past this many only decide a tie; they are kept as a sticky bit. }
  PARSE_MAX_DIGITS = 800;

class function TStructuralText.TryParseFloat(const AText: string;
  out AValue: Double): Boolean;
var
  S, Sig: string;
  P, Len, SigLen: Integer;
  Neg, AnyDigit, Sticky, ExpNeg, ExpDigit: Boolean;
  DecExp, ExpVal: Int64;
  Mag: Int64;
  Mantissa: Int64;
  Q, B, N, Quot, Rem: TBigNat;
  Scale: Integer;
  Bits: UInt64;
  {$IFDEF CPUX86}
  OldCW: Word;
  {$ENDIF}
begin
  AValue := 0;
  Result := False;
  S := Trim(AText);
  if S = '' then Exit;
  if SameText(S, 'NAN') then
  begin
    AValue := Double.NaN;
    Exit(True);
  end;
  if SameText(S, 'INF') or SameText(S, '+INF') then
  begin
    AValue := Double.PositiveInfinity;
    Exit(True);
  end;
  if SameText(S, '-INF') then
  begin
    AValue := Double.NegativeInfinity;
    Exit(True);
  end;

  Len := Length(S);
  P := 1;
  Neg := False;
  if CharInSet(S[P], ['+', '-']) then
  begin
    Neg := S[P] = '-';
    Inc(P);
  end;

  { The significant digits, without leading zeros, and the power of ten
    they are scaled by: value = Sig * 10^DecExp. }
  SetLength(Sig, Min(Len, PARSE_MAX_DIGITS));
  SigLen := 0;
  DecExp := 0;
  AnyDigit := False;
  Sticky := False;
  while (P <= Len) and CharInSet(S[P], ['0'..'9']) do
  begin
    AnyDigit := True;
    if (SigLen = 0) and (S[P] = '0') then
      { a leading zero says nothing }
    else if SigLen < PARSE_MAX_DIGITS then
    begin
      Inc(SigLen);
      Sig[SigLen] := S[P];
    end
    else
    begin
      if S[P] <> '0' then Sticky := True;
      Inc(DecExp);
    end;
    Inc(P);
  end;
  if (P <= Len) and (S[P] = '.') then
  begin
    Inc(P);
    while (P <= Len) and CharInSet(S[P], ['0'..'9']) do
    begin
      AnyDigit := True;
      if (SigLen = 0) and (S[P] = '0') then
        Dec(DecExp)
      else if SigLen < PARSE_MAX_DIGITS then
      begin
        Inc(SigLen);
        Sig[SigLen] := S[P];
        Dec(DecExp);
      end
      else if S[P] <> '0' then
        Sticky := True;
      Inc(P);
    end;
  end;
  if not AnyDigit then Exit;
  if (P <= Len) and CharInSet(S[P], ['e', 'E']) then
  begin
    Inc(P);
    ExpNeg := False;
    if (P <= Len) and CharInSet(S[P], ['+', '-']) then
    begin
      ExpNeg := S[P] = '-';
      Inc(P);
    end;
    ExpVal := 0;
    ExpDigit := False;
    while (P <= Len) and CharInSet(S[P], ['0'..'9']) do
    begin
      ExpDigit := True;
      if ExpVal < 100000000 then
        ExpVal := ExpVal * 10 + (Ord(S[P]) - Ord('0'));
      Inc(P);
    end;
    if not ExpDigit then Exit;
    if ExpNeg then Dec(DecExp, ExpVal) else Inc(DecExp, ExpVal);
  end;
  if P <= Len then Exit;
  Result := True;

  if SigLen = 0 then
  begin
    Bits := 0;
    if Neg then Bits := UInt64(1) shl 63;
    Move(Bits, AValue, SizeOf(AValue));
    Exit;
  end;
  SetLength(Sig, SigLen);

  { value is in [10^(Mag-1), 10^Mag) }
  Mag := SigLen + DecExp;
  if Mag > 310 then
  begin
    if Neg then AValue := Double.NegativeInfinity
    else AValue := Double.PositiveInfinity;
    Exit;
  end;
  if Mag < -324 then
  begin
    Bits := 0;
    if Neg then Bits := UInt64(1) shl 63;
    Move(Bits, AValue, SizeOf(AValue));
    Exit;
  end;

  { THE FAST PATH (Clinger): at most fifteen digits are an exact integer
    below 2^53, and a power of ten up to 10^22 is an exact double, so one
    multiplication or division - correctly rounded by IEEE 754 - gives the
    correctly rounded result. On Win32 the x87 unit is set to 53-bit
    precision for it, or the product would be rounded twice. }
  if (not Sticky) and (SigLen <= 15) and (DecExp >= -22) and (DecExp <= 22) then
  begin
    Mantissa := StrToInt64(Sig);
    {$IFDEF CPUX86}
    OldCW := Get8087CW;
    Set8087CW(Word((OldCW and not $0300) or $0200));
    try
    {$ENDIF}
      if DecExp >= 0 then
        AValue := Mantissa * EXACT_POWERS_OF_TEN[DecExp]
      else
        AValue := Mantissa / EXACT_POWERS_OF_TEN[-DecExp];
    {$IFDEF CPUX86}
    finally
      Set8087CW(OldCW);
    end;
    {$ENDIF}
    if Neg then AValue := -AValue;
    Exit;
  end;

  { THE EXACT PATH: the decimal as a big integer over a power of ten, divided
    out to enough bits that the remainder only decides a tie. }
  Q := BigFromDigits(Sig);
  if DecExp >= 0 then
  begin
    N := Copy(Q);
    Scale := Integer(DecExp);
    while Scale >= 9 do
    begin
      BigMulAddSmall(N, 1000000000, 0);
      Dec(Scale, 9);
    end;
    while Scale > 0 do
    begin
      BigMulAddSmall(N, 10, 0);
      Dec(Scale);
    end;
    AValue := BigToDouble(N, 0, Sticky, Neg);
  end
  else
  begin
    B := BigPow10(Integer(-DecExp));
    Scale := 55 + BigBitLength(B) - BigBitLength(Q);
    if Scale < 0 then Scale := 0;
    N := BigShl(Q, Scale);
    BigDivMod(N, B, Quot, Rem);
    AValue := BigToDouble(Quot, Scale, Sticky or (Length(Rem) > 0), Neg);
  end;
end;

{ The exact decimal value of a finite, nonzero double, as a digit string D
  and a power of ten: AValue = D * 10^AExp10, with no rounding at all. }
procedure ExactDecimal(AValue: Double; out ADigits: string; out AExp10: Integer);
var
  Bits, M: UInt64;
  Field, E2: Integer;
  N: TBigNat;
begin
  Move(AValue, Bits, SizeOf(Bits));
  Field := Integer((Bits shr 52) and $7FF);
  M := Bits and ((UInt64(1) shl 52) - 1);
  if Field = 0 then E2 := -1074
  else
  begin
    M := M or (UInt64(1) shl 52);
    E2 := Field - 1075;
  end;
  N := BigFromUInt64(M);
  if E2 >= 0 then
  begin
    N := BigShl(N, E2);
    AExp10 := 0;
  end
  else
  begin
    AExp10 := E2;
    E2 := -E2;
    while E2 >= 13 do
    begin
      BigMulAddSmall(N, 1220703125, 0);
      Dec(E2, 13);
    end;
    while E2 > 0 do
    begin
      BigMulAddSmall(N, 5, 0);
      Dec(E2);
    end;
  end;
  ADigits := BigToDigits(N);
end;

{ AValue's exact decimal rounded to APrecision significant digits, ties to
  even, written the way FloatToStrF(ffGeneral) writes: fixed notation for a
  decimal exponent from -5 up to one below the precision, E notation
  otherwise, trailing zeros removed. }
function ExactGeneralText(AValue: Double; APrecision: Integer): string;
var
  Digits, Mant: string;
  Exp10, X, I, Keep: Integer;
  Up: Boolean;
  Neg: Boolean;
begin
  Neg := AValue < 0;
  ExactDecimal(Abs(AValue), Digits, Exp10);
  { Digits * 10^Exp10; the first digit's power is Length - 1 + Exp10. }
  if Length(Digits) > APrecision then
  begin
    Keep := APrecision;
    if Digits[Keep + 1] > '5' then Up := True
    else if Digits[Keep + 1] < '5' then Up := False
    else
    begin
      Up := False;
      for I := Keep + 2 to Length(Digits) do
        if Digits[I] <> '0' then
        begin
          Up := True;
          Break;
        end;
      if not Up then Up := Odd(Ord(Digits[Keep]) - Ord('0'));
    end;
    Inc(Exp10, Length(Digits) - Keep);
    SetLength(Digits, Keep);
    if Up then
    begin
      I := Keep;
      while (I >= 1) and (Digits[I] = '9') do
      begin
        Digits[I] := '0';
        Dec(I);
      end;
      if I >= 1 then Digits[I] := Char(Ord(Digits[I]) + 1)
      else
      begin
        Digits := '1' + Digits;
        SetLength(Digits, Keep);
        Inc(Exp10);
      end;
    end;
  end;
  { trailing zeros are powers of ten }
  while (Length(Digits) > 1) and (Digits[Length(Digits)] = '0') do
  begin
    SetLength(Digits, Length(Digits) - 1);
    Inc(Exp10);
  end;
  X := Length(Digits) - 1 + Exp10;
  if (X < -5) or (X >= APrecision) then
  begin
    Mant := Digits[1];
    if Length(Digits) > 1 then Mant := Mant + '.' + Copy(Digits, 2, MaxInt);
    Result := Mant + 'E' + IntToStr(X);
  end
  else if X < 0 then
    Result := '0.' + StringOfChar('0', -X - 1) + Digits
  else if X + 1 >= Length(Digits) then
    Result := Digits + StringOfChar('0', X + 1 - Length(Digits))
  else
    Result := Copy(Digits, 1, X + 1) + '.' + Copy(Digits, X + 2, MaxInt);
  if Neg then Result := '-' + Result;
end;

class function TStructuralText.EncodeFloat(AValue: Double): string;
var
  Digits: Integer;
  Back: Double;
begin
  if AValue.IsNan then Exit('NaN');
  if AValue.IsPositiveInfinity then Exit('Infinity');
  if AValue.IsNegativeInfinity then Exit('-Infinity');
  if AValue = 0 then
    if (PUInt64(@AValue)^ shr 63) <> 0 then Exit('-0') else Exit('0');
  { The RTL's shortest candidates first, so the text is what it always was
    wherever that is right - and it is checked with the correctly rounded
    reader, because on Win64 the RTL's seventeenth digit can be wrong. }
  for Digits := 15 to 17 do
  begin
    Result := FloatToStrF(AValue, ffGeneral, Digits, 0,
      TFormatSettings.Invariant);
    if TryParseFloat(Result, Back) and (Back = AValue) then Exit;
  end;
  { The exact expansion, rounded: seventeen correct digits always name the
    double. }
  for Digits := 15 to 17 do
  begin
    Result := ExactGeneralText(AValue, Digits);
    if TryParseFloat(Result, Back) and (Back = AValue) then Exit;
  end;
end;

class function TStructuralText.EncodeSingle(AValue: Single): string;
var
  Digits: Integer;
  Back: Double;
begin
  if AValue.IsNan then Exit('NaN');
  if AValue.IsPositiveInfinity then Exit('Infinity');
  if AValue.IsNegativeInfinity then Exit('-Infinity');
  if AValue = 0 then
    if (PCardinal(@AValue)^ shr 31) <> 0 then Exit('-0') else Exit('0');
  for Digits := 6 to 9 do
  begin
    Result := FloatToStrF(AValue, ffGeneral, Digits, 0,
      TFormatSettings.Invariant);
    if TryParseFloat(Result, Back) and (Single(Back) = AValue) then Exit;
  end;
  for Digits := 6 to 9 do
  begin
    Result := ExactGeneralText(AValue, Digits);
    if TryParseFloat(Result, Back) and (Single(Back) = AValue) then Exit;
  end;
end;

class function TStructuralText.EncodeHex(const AValue: TBytes): string;
var
  I: NativeInt;
begin
  SetLength(Result, Length(AValue) * 2);
  for I := 0 to High(AValue) do
  begin
    Result[I * 2 + 1] := HEX_DIGITS[AValue[I] shr 4];
    Result[I * 2 + 2] := HEX_DIGITS[AValue[I] and $0F];
  end;
end;

class function TStructuralText.TryDecodeHex(const AText: string;
  out AValue: TBytes): Boolean;
var
  I: NativeInt;
  Hi, Lo: Integer;

  function Nibble(AChar: Char; out AOut: Integer): Boolean;
  begin
    case AChar of
      '0'..'9': AOut := Ord(AChar) - Ord('0');
      'a'..'f': AOut := Ord(AChar) - Ord('a') + 10;
      'A'..'F': AOut := Ord(AChar) - Ord('A') + 10;
    else
      Exit(False);
    end;
    Result := True;
  end;

begin
  AValue := nil;
  if Odd(Length(AText)) then Exit(False);
  SetLength(AValue, Length(AText) div 2);
  for I := 0 to High(AValue) do
  begin
    if not (Nibble(AText[I * 2 + 1], Hi) and Nibble(AText[I * 2 + 2], Lo)) then
    begin
      AValue := nil;
      Exit(False);
    end;
    AValue[I] := Byte((Hi shl 4) or Lo);
  end;
  Result := True;
end;

{ ------------------------------------------------------ decimal128 text --- }

type
  { A 128-bit unsigned magnitude as four 32-bit limbs, least significant
    first. Just enough arithmetic to turn bits into digits and back: divide
    by ten, multiply by ten, add a digit. Nothing else belongs here. }
  TDec128Mag = record
    L: array[0..3] of UInt32;
    procedure Clear;
    function IsZero: Boolean;
    { Quotient in place; returns the remainder. }
    function DivModSmall(ADivisor: UInt32): UInt32;
    { False on overflow past 128 bits. }
    function MulAddSmall(AFactor, AAddend: UInt32): Boolean;
    { Compares against 10^34, the largest decimal128 coefficient plus one. }
    function ExceedsCoefficientRange: Boolean;
  end;

procedure TDec128Mag.Clear;
begin
  L[0] := 0; L[1] := 0; L[2] := 0; L[3] := 0;
end;

function TDec128Mag.IsZero: Boolean;
begin
  Result := (L[0] or L[1] or L[2] or L[3]) = 0;
end;

function TDec128Mag.DivModSmall(ADivisor: UInt32): UInt32;
var
  I: Integer;
  Cur: UInt64;
begin
  Result := 0;
  for I := 3 downto 0 do
  begin
    Cur := (UInt64(Result) shl 32) or L[I];
    L[I] := UInt32(Cur div ADivisor);
    Result := UInt32(Cur mod ADivisor);
  end;
end;

function TDec128Mag.MulAddSmall(AFactor, AAddend: UInt32): Boolean;
var
  I: Integer;
  Cur: UInt64;
  Carry: UInt32;
begin
  Carry := AAddend;
  for I := 0 to 3 do
  begin
    Cur := UInt64(L[I]) * AFactor + Carry;
    L[I] := UInt32(Cur and $FFFFFFFF);
    Carry := UInt32(Cur shr 32);
  end;
  Result := Carry = 0;
end;

function TDec128Mag.ExceedsCoefficientRange: Boolean;
const
  { 10^34 = 0x0001ED09_BEAD87C0_378D8E64_00000000 }
  MAXP1: array[0..3] of UInt32 = ($00000000, $378D8E64, $BEAD87C0, $0001ED09);
var
  I: Integer;
begin
  for I := 3 downto 0 do
  begin
    if L[I] > MAXP1[I] then Exit(True);
    if L[I] < MAXP1[I] then Exit(False);
  end;
  { Exactly 10^34, which is one too many. }
  Result := True;
end;

class function TDecimal128.TryToText(const ABytes: TBytes;
  out AText: string): Boolean;
var
  Hi, Lo: UInt64;
  Combination: UInt32;
  Negative: Boolean;
  Exponent: Integer;
  Mag: TDec128Mag;
  Digits: string;
  Adjusted, I: Integer;
  SB: TStringBuilder;
begin
  AText := '';
  if Length(ABytes) <> ByteLength then Exit(False);

  { BSON stores the sixteen bytes little-endian. }
  Lo := 0; Hi := 0;
  for I := 7 downto 0 do Lo := (Lo shl 8) or ABytes[I];
  for I := 15 downto 8 do Hi := (Hi shl 8) or ABytes[I];

  Negative := (Hi and UInt64($8000000000000000)) <> 0;

  { The five bits below the sign decide which of the three shapes this is. }
  Combination := UInt32((Hi shr 58) and $1F);
  if Combination = $1F then
  begin
    if Negative then AText := '-NaN' else AText := 'NaN';
    { A NaN is a NaN; Extended JSON spells it without a sign, and so do we. }
    AText := 'NaN';
    Exit(True);
  end;
  if Combination = $1E then
  begin
    if Negative then AText := '-Infinity' else AText := 'Infinity';
    Exit(True);
  end;

  Mag.Clear;
  if (Combination shr 3) = 3 then
  begin
    { The large-coefficient form. Every value it can express is above
      10^34 - 1 and therefore not canonical, and the specification says to
      read such a value as zero rather than to reject it. }
    Exponent := Integer((Hi shr 47) and $3FFF);
  end
  else
  begin
    Exponent := Integer((Hi shr 49) and $3FFF);
    Mag.L[0] := UInt32(Lo and $FFFFFFFF);
    Mag.L[1] := UInt32(Lo shr 32);
    Mag.L[2] := UInt32(Hi and $FFFFFFFF);
    Mag.L[3] := UInt32((Hi shr 32) and $0001FFFF);
  end;
  Dec(Exponent, ExponentBias);

  { The coefficient, least significant digit first, then reversed. }
  if Mag.IsZero then Digits := '0'
  else
  begin
    Digits := '';
    while not Mag.IsZero do
      Digits := Char(Ord('0') + Mag.DivModSmall(10)) + Digits;
  end;

  SB := TStringBuilder.Create;
  try
    if Negative then SB.Append('-');
    Adjusted := Exponent + Length(Digits) - 1;
    if (Exponent <= 0) and (Adjusted >= -6) then
    begin
      { Plain notation - no exponent character at all. }
      if Exponent = 0 then SB.Append(Digits)
      else if Adjusted >= 0 then
      begin
        SB.Append(Copy(Digits, 1, Adjusted + 1)).Append('.')
          .Append(Copy(Digits, Adjusted + 2, MaxInt));
      end
      else
      begin
        SB.Append('0.');
        for I := 1 to -(Adjusted + 1) do SB.Append('0');
        SB.Append(Digits);
      end;
    end
    else
    begin
      { Scientific notation: one digit, then the rest, then the exponent
        with an explicit sign. }
      SB.Append(Digits[1]);
      if Length(Digits) > 1 then
        SB.Append('.').Append(Copy(Digits, 2, MaxInt));
      SB.Append('E');
      if Adjusted >= 0 then SB.Append('+');
      SB.Append(Adjusted);
    end;
    AText := SB.ToString;
  finally
    SB.Free;
  end;
  Result := True;
end;

class function TDecimal128.TryFromText(const AText: string;
  out ABytes: TBytes): Boolean;
var
  S: string;
  P, Len, ExpAdjust, Explicit, DigitCount: Integer;
  Negative, SawDot, SawDigit: Boolean;
  Mag: TDec128Mag;
  Exponent: Integer;
  Hi, Lo: UInt64;
  Biased: UInt32;

  procedure Emit(AValue: UInt64; AOffset: Integer);
  var
    K: Integer;
  begin
    for K := 0 to 7 do ABytes[AOffset + K] := Byte((AValue shr (K * 8)) and $FF);
  end;

begin
  ABytes := nil;
  S := Trim(AText);
  if S = '' then Exit(False);

  Negative := False;
  P := 1;
  if (S[P] = '+') or (S[P] = '-') then
  begin
    Negative := S[P] = '-';
    Inc(P);
  end;

  SetLength(ABytes, ByteLength);
  FillChar(ABytes[0], ByteLength, 0);

  { The three non-finite spellings, case-insensitively, exactly as the
    decimal-arithmetic specification lists them. }
  S := Copy(S, P, MaxInt);
  if SameText(S, 'NaN') or SameText(S, 'sNaN') then
  begin
    Emit(UInt64($7C00000000000000), 8);
    if Negative then ABytes[15] := ABytes[15] or $80;
    Exit(True);
  end;
  if SameText(S, 'Infinity') or SameText(S, 'Inf') then
  begin
    Emit(UInt64($7800000000000000), 8);
    if Negative then ABytes[15] := ABytes[15] or $80;
    Exit(True);
  end;

  Mag.Clear;
  Len := Length(S);
  P := 1;
  ExpAdjust := 0;
  DigitCount := 0;
  SawDot := False;
  SawDigit := False;
  while P <= Len do
  begin
    case S[P] of
      '0'..'9':
        begin
          SawDigit := True;
          { Leading zeros cost nothing and must not count against the
            thirty-four-digit limit. }
          if not ((DigitCount = 0) and (S[P] = '0') and not SawDot) then
          begin
            if not Mag.MulAddSmall(10, UInt32(Ord(S[P]) - Ord('0'))) then
            begin
              ABytes := nil;
              Exit(False);
            end;
            Inc(DigitCount);
          end;
          if SawDot then Dec(ExpAdjust);
        end;
      '.':
        begin
          if SawDot then begin ABytes := nil; Exit(False); end;
          SawDot := True;
        end;
      'e', 'E':
        Break;
    else
      ABytes := nil;
      Exit(False);
    end;
    Inc(P);
  end;
  if not SawDigit then begin ABytes := nil; Exit(False); end;

  Explicit := 0;
  if P <= Len then
  begin
    Inc(P);
    if P > Len then begin ABytes := nil; Exit(False); end;
    if not TryStrToInt(Copy(S, P, MaxInt), Explicit) then
    begin
      ABytes := nil;
      Exit(False);
    end;
  end;

  if Mag.ExceedsCoefficientRange then begin ABytes := nil; Exit(False); end;

  Exponent := Explicit + ExpAdjust;
  { Trailing zeros can be traded for exponent when the exponent is too small
    to encode, and a coefficient of zero can take any representable exponent;
    beyond that an out-of-range exponent is an error rather than a rounding
    opportunity. }
  while (Exponent > 6111) and not Mag.ExceedsCoefficientRange do
  begin
    if not Mag.MulAddSmall(10, 0) then Break;
    if Mag.ExceedsCoefficientRange then Break;
    Dec(Exponent);
  end;
  if (Exponent < -6176) or (Exponent > 6111) then
  begin
    ABytes := nil;
    Exit(False);
  end;

  Biased := UInt32(Exponent + ExponentBias);
  Lo := (UInt64(Mag.L[1]) shl 32) or Mag.L[0];
  Hi := (UInt64(Mag.L[3] and $0001FFFF) shl 32) or Mag.L[2];
  Hi := Hi or (UInt64(Biased and $3FFF) shl 49);
  if Negative then Hi := Hi or UInt64($8000000000000000);

  Emit(Lo, 0);
  Emit(Hi, 8);
  Result := True;
end;

var
  GCtx: TRttiContext;
  GUnitNames: TDictionary<PTypeInfo, string>;
  GUnitNamesLock: TCriticalSection;

procedure RegisterTypeUnitName(ATypeInfo: PTypeInfo; const AUnitName: string);
begin
  if (ATypeInfo = nil) or (AUnitName = '') then Exit;
  GUnitNamesLock.Enter;
  try
    GUnitNames.AddOrSetValue(ATypeInfo, AUnitName);
  finally
    GUnitNamesLock.Leave;
  end;
end;

function RegisteredUnitName(ATypeInfo: PTypeInfo): string;
begin
  GUnitNamesLock.Enter;
  try
    if not GUnitNames.TryGetValue(ATypeInfo, Result) then Result := '';
  finally
    GUnitNamesLock.Leave;
  end;
end;

function TryTypeQualifiedName(ATypeInfo: PTypeInfo; out AName: string): Boolean;
var
  T: TRttiType;
begin
  AName := '';
  Result := False;
  if ATypeInfo = nil then Exit;
  try
    T := GCtx.GetType(ATypeInfo);
    { Asked first rather than caught: a caught ENonPublicType still stops
      the IDE debugger, and a closed generic instantiated in an
      implementation section - TNullable<Integer> in this unit - is one. }
    if (T = nil) or not T.IsPublicType then Exit;
    AName := T.QualifiedName;
    Result := AName <> '';
  except
    { ENonPublicType for implementation-section declarations, and
      EInsufficientRtti for types without extended RTTI. }
    AName := '';
    Result := False;
  end;
end;

function TypeDataUnitName(ATypeInfo: PTypeInfo): string;
begin
  Result := '';
  if ATypeInfo = nil then Exit;
  { Only tkClass and tkInterface carry a fixed-position unit name in
    TTypeData.  For tkEnumeration the unit name sits behind the
    variable-length NameList and has no supported accessor, so enumerations
    (and therefore sets) go through QualifiedName instead. }
  case ATypeInfo.Kind of
    tkClass:
      Result := UTF8ToString(GetTypeData(ATypeInfo).UnitName);
    tkInterface:
      Result := UTF8ToString(GetTypeData(ATypeInfo).IntfUnit);
  end;
end;

function TypeUnitOf(ATypeInfo: PTypeInfo; const AUnitHint: string): string;
var
  Q: string;
  P: Integer;
begin
  Result := '';
  if ATypeInfo = nil then Exit;
  Result := TypeDataUnitName(ATypeInfo);
  if Result <> '' then Exit;
  if TryTypeQualifiedName(ATypeInfo, Q) then
  begin
    { The unit is what precedes the LAST dot of the type NAME only.  A closed
      generic's qualified name carries its type arguments, and those contain
      dots of their own - 'PascalForge.Nullable.TNullable<PascalForge.Contracts.TX>'
      must yield 'PascalForge.Nullable', not
      'PascalForge.Nullable.TNullable<PascalForge.Contracts'. }
    P := Q.IndexOf('<');
    if P >= 0 then Q := Q.Substring(0, P);
    P := Q.LastIndexOf('.');
    if P > 0 then Exit(Q.Substring(0, P));
  end;
  { Record RTTI carries no unit name.  A non-public record is attributed
    either through an explicit RegisterTypeUnitName from its declaring unit,
    or through the scope that reached it. }
  Result := RegisteredUnitName(ATypeInfo);
  if Result = '' then Result := AUnitHint;
end;

function TypeKeyOf(ATypeInfo: PTypeInfo; const AUnitHint: string): string;
var
  Q, U, N: string;
begin
  if ATypeInfo = nil then Exit('');
  if TryTypeQualifiedName(ATypeInfo, Q) then Exit(Q);
  N := UTF8ToString(ATypeInfo.Name);
  U := TypeUnitOf(ATypeInfo, AUnitHint);
  if U = '' then Exit(N);
  Result := U + '.' + N;
end;

function MemberDisplayName(const AOwner, AMember: string): string;
begin
  if AOwner = '' then Exit(AMember);
  if AMember = '' then Exit(AOwner);
  Result := AOwner + '.' + AMember;
end;

function GlobMatch(const APattern, AText: string): Boolean;
var
  Parts: TArray<string>;
  I: NativeInt;
  Idx, Start: Integer;
begin
  if APattern = '*' then Exit(True);
  if not APattern.Contains('*') then Exit(SameText(APattern, AText));
  Parts := APattern.Split(['*']);
  Idx := 0;
  for I := 0 to High(Parts) do
  begin
    if Parts[I] = '' then Continue;
    Start := AText.ToLower.IndexOf(Parts[I].ToLower, Idx);
    if Start < 0 then Exit(False);
    if (I = 0) and not APattern.StartsWith('*') and (Start <> 0) then Exit(False);
    Idx := Start + Parts[I].Length;
  end;
  if not APattern.EndsWith('*') and (High(Parts) >= 0) and
     (Parts[High(Parts)] <> '') then
    Result := AText.ToLower.EndsWith(Parts[High(Parts)].ToLower)
  else
    Result := True;
end;

function FieldMatch(const APattern, AName: string): Boolean;
begin
  Result := (APattern = '*') or SameText(APattern, AName);
end;

{ Splits 'TDictionary<System.string,TFoo>' into base name and arity without
  needing the declaring unit, which record RTTI does not carry.  False when
  the name is not a closed generic specialization at all. }
function TryGenericBaseAndArity(ATypeInfo: PTypeInfo; out ABase: string;
  out AArity: Integer): Boolean;
var
  N: string;
  I, Depth: Integer;
begin
  ABase := '';
  AArity := 0;
  Result := False;
  if (ATypeInfo = nil) or not (ATypeInfo.Kind in [tkClass, tkRecord]) then Exit;
  N := UTF8ToString(ATypeInfo.Name);
  I := N.IndexOf('<');
  if (I <= 0) or (not N.EndsWith('>')) then Exit;
  ABase := N.Substring(0, I);
  if ABase = '' then Exit;
  Depth := 0;
  AArity := 1;
  for I := I + 1 to N.Length do
    case N[I] of
      '<': Inc(Depth);
      '>':
        if Depth = 0 then
        begin
          if I <> N.Length then Exit;
        end
        else
          Dec(Depth);
      ',': if Depth = 1 then Inc(AArity);
    end;
  if Depth <> 0 then Exit;
  Result := True;
end;

function GenericFamilyKeyOf(ATypeInfo: PTypeInfo; out AKey: string): Boolean;
var
  U, Base: string;
  Arity: Integer;
begin
  AKey := '';
  Result := False;
  if not TryGenericBaseAndArity(ATypeInfo, Base, Arity) then Exit;
  U := TypeUnitOf(ATypeInfo);
  if U = '' then Exit;
  AKey := LowerCase(U + '|' + Base + '|' + IntToStr(Arity));
  Result := True;
end;

function NameMatchesAnyBase(const AClassName: string;
  const ABaseNames: array of string): Boolean;
var
  I: NativeInt;
begin
  for I := Low(ABaseNames) to High(ABaseNames) do
    if AClassName.StartsWith(ABaseNames[I]) then Exit(True);
  Result := False;
end;

function InheritsFromGenericBase(ATypeInfo: PTypeInfo;
  const ABaseNames: array of string): Boolean;
var
  C: TClass;
begin
  Result := False;
  if (ATypeInfo = nil) or (ATypeInfo.Kind <> tkClass) then Exit;
  C := GetTypeData(ATypeInfo).ClassType;
  while C <> nil do
  begin
    if NameMatchesAnyBase(C.ClassName, ABaseNames) then Exit(True);
    C := C.ClassParent;
  end;
end;

{ TSerializationTypeInfo }

class function TSerializationTypeInfo.TypeNameOf<T>: string;
var
  Info: PTypeInfo;
begin
  Info := System.TypeInfo(T);
  if Info = nil then Exit('<unnamed>');
  Result := UTF8ToString(Info^.Name);
end;

class function TSerializationTypeInfo.ActualNameOf(const AValue: TValue): string;
begin
  if AValue.TypeInfo = nil then Exit('<empty>');
  Result := UTF8ToString(AValue.TypeInfo^.Name);
end;


{ -------------------------------------------------------- payload ------ }

class function TSerializationPayload.FromText(
  const AText: string): TSerializationPayload;
begin
  Result.FKind := TSerializationPayloadKind.Text;
  Result.FText := AText;
  Result.FBytes := nil;
end;

class function TSerializationPayload.FromBytes(
  const ABytes: TBytes): TSerializationPayload;
begin
  Result.FKind := TSerializationPayloadKind.Binary;
  Result.FText := '';
  Result.FBytes := ABytes;
end;

function TSerializationPayload.IsText: Boolean;
begin
  Result := FKind = TSerializationPayloadKind.Text;
end;

function TSerializationPayload.IsBinary: Boolean;
begin
  Result := FKind = TSerializationPayloadKind.Binary;
end;

function TSerializationPayload.AsText: string;
begin
  if FKind <> TSerializationPayloadKind.Text then
    raise ESerializationPayloadKind.Create(
      'This payload is binary. Use AsBytes for the bytes themselves, or ' +
      'DecodeUtf8Text if you know they are UTF-8 text.');
  Result := FText;
end;

function TSerializationPayload.AsBytes: TBytes;
begin
  if FKind <> TSerializationPayloadKind.Binary then
    raise ESerializationPayloadKind.Create(
      'This payload is text. Use AsText for the text itself, or ' +
      'ToUtf8Bytes to encode it as UTF-8.');
  Result := FBytes;
end;

function TSerializationPayload.ToUtf8Bytes: TBytes;
begin
  { A binary payload's bytes are NOT UTF-8 text and are not returned as
    though they were. That shortcut is how a BSON document gets handed to
    something expecting a string. }
  if FKind <> TSerializationPayloadKind.Text then
    raise ESerializationPayloadKind.Create(
      'This payload is binary, so it has no text to encode. Its bytes are ' +
      'already bytes: use AsBytes.');
  Result := TEncoding.UTF8.GetBytes(FText);
end;

function TSerializationPayload.AsTextDocument: string;
begin
  if FKind = TSerializationPayloadKind.Text then Result := FText
  else Result := Utf8BytesToString(FBytes);
end;

function TSerializationPayload.DecodeUtf8Text: string;
begin
  if FKind <> TSerializationPayloadKind.Binary then
    raise ESerializationPayloadKind.Create(
      'This payload is already text; there is nothing to decode. Use AsText.');
  Result := Utf8BytesToString(FBytes);
end;

{ ---------------------------------------------------------- errors ----- }

constructor TSerializationFormatHandler.Create;
begin
  inherited Create;
end;

function TSerializationFormatHandler.Capabilities: TSerializationFormatCapabilities;
begin
  { The same question, asked with nothing supplied. Not virtual: see the
    declaration. }
  Result := Capabilities(TStructuralConversionOptions.Default);
end;

function TSerializationFormatHandler.Capabilities(
  const AOptions: TStructuralConversionOptions):
  TSerializationFormatCapabilities;
begin
  { Most formats here are self-describing and can do all four whatever the
    caller has. A schema-driven one overrides this - and only this - and
    answers from AOptions.SchemaFor(its own format). }
  Result := [TSerializationFormatCapability.StructuralParse,
             TSerializationFormatCapability.StructuralWrite,
             TSerializationFormatCapability.ContractSerialize,
             TSerializationFormatCapability.ContractDeserialize];
end;

procedure TSerializationFormatHandler.RaiseUnsupported(
  ACapability: TSerializationFormatCapability;
  AFormat: TSerializationFormat;
  const AOptions: TStructuralConversionOptions);
begin
  { For a handler whose answer does not depend on the caller, this is the
    whole truth and there is nothing to add. }
  raise ESerializationFormatCapability.CreateFor(AFormat, ACapability);
end;

constructor ESerializationFormatCapability.CreateFor(
  AFormat: TSerializationFormat;
  ACapability: TSerializationFormatCapability);
const
  WHAT: array[TSerializationFormatCapability] of string = (
    'parse its own payload into the dynamic structural tree',
    'write the dynamic structural tree',
    'serialize a Delphi value',
    'deserialize into a Delphi value');
  HOW: array[TSerializationFormatCapability] of string = (
    'Structural parsing',
    'Structural writing',
    'Contract-aware serialization',
    'Contract-aware deserialization');
begin
  FFormat := AFormat;
  FCapability := ACapability;
  inherited CreateFmt(
    '%s is not available for serialization format %s.' + sLineBreak + sLineBreak +
    'The format IS registered - its handler simply cannot %s. Convert ' +
    'through the Delphi contract instead, or supply whatever metadata this ' +
    'format needs to decode itself.',
    [HOW[ACapability], TSerializationFormats.FormatName(AFormat).ToUpper,
     WHAT[ACapability]]);
end;

constructor ESerializationFormatNotRegistered.CreateFor(AFormat: TSerializationFormat);
var
  Name: string;
begin
  Name := TSerializationFormats.FormatName(AFormat);
  inherited CreateFmt(
    'Serialization format %s is not registered.' + sLineBreak + sLineBreak +
    'Registration is explicit: call T%sSerializationRegistration.' +
    'RegisterFormat (unit PascalForge.%1:s.Registration) during application ' +
    'startup, or TSerializationFormatsRegistration.RegisterAll (unit ' +
    'PascalForge.Serialization.AllFormats). Linking the unit or loading its ' +
    'package does not register it. The direct serializer - T%1:sSerializer - ' +
    'needs no registration at all.',
    [Name.ToUpper, TSerializationFormats.UnitStem(AFormat)]);
end;

{ ===========================================================================
  CYCLES
  =========================================================================== }

threadvar
  GGraphActive: TDictionary<TObject, Integer>;
  GGraphLevel: Integer;

class procedure TSerializationGraphGuard.CheckDepth(ADepth: Integer;
  AObject: TObject);
var
  Where: string;
begin
  if ADepth < SERIALIZATION_MAX_GRAPH_DEPTH then Exit;
  if AObject <> nil then Where := ' at a ' + AObject.ClassName else Where := '';
  raise ESerializationLimitExceeded.CreateFmt(
    'The value nests more than %d levels deep%s - objects, records, arrays, ' +
    'lists and dictionaries each count one. A writer follows it ' +
    'recursively, so one that deep - usually a linked list or a recursive ' +
    'record - runs out of stack, and the document it would make is deeper ' +
    'than the formats'' readers accept. Hold a long chain as a list, or ' +
    'register a type serializer for the type.',
    [SERIALIZATION_MAX_GRAPH_DEPTH, Where]);
end;

class procedure TSerializationGraphGuard.EnterLevel;
begin
  CheckDepth(GGraphLevel, nil);
  Inc(GGraphLevel);
end;

class procedure TSerializationGraphGuard.LeaveLevel;
begin
  if GGraphLevel > 0 then Dec(GGraphLevel);
end;

class function TSerializationGraphGuard.Level: Integer;
begin
  Result := GGraphLevel;
end;

class procedure TSerializationGraphGuard.RestoreLevel(AMark: Integer);
begin
  if AMark >= 0 then GGraphLevel := AMark;
end;

class function TSerializationGraphGuard.Enter(AObject: TObject): Boolean;
begin
  if AObject = nil then Exit(True);
  if GGraphActive = nil then
    GGraphActive := TDictionary<TObject, Integer>.Create;
  if GGraphActive.ContainsKey(AObject) then Exit(False);
  { Checked before the object is added, so a refusal leaves nothing for a
    Leave to remove - the caller's try/finally is not entered. }
  try
    CheckDepth(GGraphLevel, AObject);
  except
    if GGraphActive.Count = 0 then FreeAndNil(GGraphActive);
    raise;
  end;
  GGraphActive.Add(AObject, 0);
  Inc(GGraphLevel);
  Result := True;
end;

class procedure TSerializationGraphGuard.Leave(AObject: TObject);
begin
  if (AObject = nil) or (GGraphActive = nil) then Exit;
  if GGraphActive.ContainsKey(AObject) then
  begin
    GGraphActive.Remove(AObject);
    if GGraphLevel > 0 then Dec(GGraphLevel);
  end;
  { Freed with the last object, so a thread that has finished writing holds
    nothing - and a thread pool thread does not keep a dictionary for ever. }
  if GGraphActive.Count = 0 then FreeAndNil(GGraphActive);
end;

{ ===========================================================================
  VARIANT <-> DYNAMIC
  =========================================================================== }

class function TSerializationVariants.TryToDynamic(const AValue: Variant;
  out ATree: TDynamicValue; out AWhy: string;
  AExactDecimals: Boolean): Boolean;
var
  VT: TVarType;
  I: Integer;
  Item: TDynamicValue;
  Digits: string;
begin
  ATree := nil;
  AWhy := '';
  VT := VarType(AValue);
  if (VT and varByRef) <> 0 then
  begin
    AWhy := 'is a Variant holding a reference (varByRef), which points at ' +
      'memory rather than holding a value';
    Exit(False);
  end;
  if (VT and varArray) <> 0 then
  begin
    if VarArrayDimCount(AValue) <> 1 then
    begin
      AWhy := Format('is a Variant array of %d dimensions, and only a ' +
        'one-dimensional one has a shape every format can carry',
        [VarArrayDimCount(AValue)]);
      Exit(False);
    end;
    ATree := TDynamicValue.NewArray;
    { A Variant array can hold Variant arrays without end: one level each,
      like any other composite a writer descends into. }
    TSerializationGraphGuard.EnterLevel;
    try
      try
        for I := VarArrayLowBound(AValue, 1) to VarArrayHighBound(AValue, 1) do
        begin
          if VarIsEmpty(AValue[I]) then
          begin
            AWhy := Format('holds Unassigned at index %d of a Variant array, ' +
              'and inside an array there is no way to leave a value out', [I]);
            FreeAndNil(ATree);
            Exit(False);
          end;
          if not TryToDynamic(AValue[I], Item, AWhy, AExactDecimals) then
          begin
            FreeAndNil(ATree);
            Exit(False);
          end;
          ATree.AsArray.Adopt(Item);
        end;
      except
        FreeAndNil(ATree);
        raise;
      end;
    finally
      { Also on the refusals above, which leave by Exit. }
      TSerializationGraphGuard.LeaveLevel;
    end;
    Exit(True);
  end;
  case VT of
    varNull: ATree := TDynamicValue.NewNull;
    varBoolean: ATree := TDynamicValue.NewBool(PVarData(@AValue)^.VBoolean);
    varShortInt, varSmallint, varInteger, varByte, varWord, varLongWord,
    varInt64:
      ATree := TDynamicValue.NewInt(AValue);
    varUInt64: ATree := TDynamicValue.NewUInt(PVarData(@AValue)^.VUInt64);
    varSingle, varDouble:
      ATree := TDynamicValue.NewFloat(Double(AValue));
    { Exact digits, and always with a point: a Currency of 3 is a real
      number that happens to be whole, and 3.0 is how a format that tells
      integers from reals keeps it one. }
    varCurrency:
      if not AExactDecimals then
        ATree := TDynamicValue.NewFloat(PVarData(@AValue)^.VCurrency)
      else
      begin
        Digits := CurrToStr(PVarData(@AValue)^.VCurrency, TFormatSettings.Invariant);
        if Pos('.', Digits) = 0 then Digits := Digits + '.0';
        ATree := TDynamicValue.NewDecimal(Digits);
      end;
    varDate: ATree := TDynamicValue.NewDateTime(PVarData(@AValue)^.VDate);
    varOleStr, varString, varUString:
      ATree := TDynamicValue.NewStr(VarToStr(AValue));
    varEmpty:
      AWhy := 'is Unassigned, which has no value to write';
    varDispatch, varUnknown:
      AWhy := 'is a Variant holding an interface, which is a reference to an ' +
        'implementation, not a value';
    varError:
      AWhy := 'is a Variant holding varError, an OLE status code rather ' +
        'than a value';
    varRecord:
      AWhy := 'is a Variant holding a record, which carries no description ' +
        'of its fields';
  else
    AWhy := Format('is a Variant of type %d, which is not one of the value ' +
      'types this library carries', [VT]);
  end;
  Result := ATree <> nil;
end;

{ Plain decimal digits with at most four significant places after the
  point - the values a Currency holds exactly. }
function IsCurrencyExact(const ADigits: string): Boolean;
var
  P, Last: Integer;
begin
  if (Pos('E', UpperCase(ADigits)) > 0) then Exit(False);
  P := Pos('.', ADigits);
  if P = 0 then Exit(True);
  Last := Length(ADigits);
  while (Last > P) and (ADigits[Last] = '0') do Dec(Last);
  Result := Last - P <= 4;
end;

class function TSerializationVariants.TryFromDynamic(ATree: TDynamicValue;
  out AValue: Variant; out AWhy: string): Boolean;
var
  I: Integer;
  C: Currency;
  D: Double;
  Text: string;
  Item: Variant;
  Bytes: TBytes;
begin
  AWhy := '';
  AValue := Unassigned;
  if ATree = nil then Exit(True);
  case ATree.Kind of
    TDynamicKind.Null: AValue := Null;
    TDynamicKind.Bool: AValue := ATree.AsBool;
    { The narrowest of Integer and Int64 that holds it, which is what Delphi
      itself does when an integer is assigned to a Variant. }
    TDynamicKind.Int:
      if (ATree.AsInt >= Low(Integer)) and (ATree.AsInt <= High(Integer)) then
        AValue := Integer(ATree.AsInt)
      else
        AValue := ATree.AsInt;
    TDynamicKind.UInt:
      if ATree.AsUInt <= UInt64(High(Int64)) then AValue := Int64(ATree.AsUInt)
      else AValue := ATree.AsUInt;
    TDynamicKind.Float: AValue := ATree.AsFloat;
    { Exact digits are a Currency when a Currency holds them exactly. }
    TDynamicKind.Decimal:
      if IsCurrencyExact(ATree.AsDecimal) and
         TryStrToCurr(ATree.AsDecimal, C, TFormatSettings.Invariant) then
        AValue := C
      { Past a Double's range there is no Variant type for it: refused, not
        EConvertError and not a silent infinity. }
      else if TStructuralText.TryParseFloat(ATree.AsDecimal, D) and
              not D.IsInfinity and not D.IsNan then
        AValue := D
      else
      begin
        AWhy := Format('is the decimal %s, which no Variant type holds',
          [ATree.AsDecimal]);
        Exit(False);
      end;
    TDynamicKind.Str: AValue := ATree.AsStr;
    TDynamicKind.Bytes:
      begin
        { A Variant array's bounds are Integer: more bytes than that are
          refused, not wrapped. Only a 64-bit target can hold that many. }
        { Read once: AsBytes hands out a copy. }
        Bytes := ATree.AsBytes;
        {$IFDEF CPU64BITS}
        if Length(Bytes) > High(Integer) then
        begin
          AWhy := 'is a byte array longer than a Variant array can hold';
          Exit(False);
        end;
        {$ENDIF}
        AValue := VarArrayCreate([0, Integer(Length(Bytes)) - 1], varByte);
        for I := 0 to Integer(High(Bytes)) do
          VarArrayPut(AValue, Bytes[I], [I]);
      end;
    TDynamicKind.Date, TDynamicKind.Time, TDynamicKind.DateTime:
      AValue := VarFromDateTime(ATree.AsDateTime);
    TDynamicKind.Arr:
      begin
        AValue := VarArrayCreate([0, ATree.Count - 1], varVariant);
        { One level, as the other direction counts one: a hand-built tree of
          arrays nested past the limit is refused, not recursed into until
          the stack runs out. }
        TSerializationGraphGuard.EnterLevel;
        try
          for I := 0 to ATree.Count - 1 do
          begin
            if not TryFromDynamic(ATree.Items[I], Item, AWhy) then
            begin
              AValue := Unassigned;
              Exit(False);
            end;
            VarArrayPut(AValue, Item, [I]);
          end;
        finally
          TSerializationGraphGuard.LeaveLevel;
        end;
      end;
    TDynamicKind.Obj:
      begin
        AWhy := 'is an object, and a Variant has no way to hold named members';
        Exit(False);
      end;
    { Two of a format's own types are plain values a Variant can hold: a
      decimal128 is a number, exact where a Currency holds it, and an
      ObjectId is the hexadecimal text every tool shows it as. }
    TDynamicKind.Extended:
      if ATree.IsTagged(TDynamicTag.Decimal128) and
         (ATree.ExtendedValue <> nil) and
         TDecimal128.TryToText(ATree.ExtendedValue.AsBytes, Text) then
      begin
        if IsCurrencyExact(Text) and
           TryStrToCurr(Text, C, TFormatSettings.Invariant) then
          AValue := C
        else if not TStructuralText.TryParseFloat(Text, D) or D.IsInfinity or
                D.IsNan then
        begin
          AWhy := Format('is the decimal %s, which no Variant type holds', [Text]);
          Exit(False);
        end
        else
          AValue := D;
      end
      else if ATree.IsTagged(TDynamicTag.ObjectId) and
              (ATree.ExtendedValue <> nil) then
        AValue := ATree.ExtendedValue.AsStr
      else
      begin
        AWhy := Format('is a %s, which a Variant has no type for',
          [ATree.ExtendedTag]);
        Exit(False);
      end;
  else
    AWhy := Format('is %s, which a Variant has no type for',
      [EStructuralConversionError.KindName(ATree.Kind)]);
    Exit(False);
  end;
  Result := True;
end;

{ -------------------------------------------------------- registry ----- }

class constructor TSerializationFormats.Create;
begin
  FLock := TCriticalSection.Create;
end;

class destructor TSerializationFormats.Destroy;
var
  F: TSerializationFormat;
begin
  for F := Low(TSerializationFormat) to High(TSerializationFormat) do
    FreeAndNil(FHandlers[F]);
  FLock.Free;
end;

{ TDateTimePolicy }

class function TDateTimePolicy.Make(AKind: Integer;
  const APattern: string): TDateTimePolicy;
begin
  Result.Kind := AKind;
  Result.Pattern := APattern;
end;

function TDateTimePolicy.SameAs(const AOther: TDateTimePolicy): Boolean;
begin
  Result := (Kind = AOther.Kind) and (Pattern = AOther.Pattern);
end;

{ TDateTimePolicies }

constructor TDateTimePolicies.Create(const ABuiltIn: TDateTimePolicy);
begin
  inherited Create;
  FBuiltIn := ABuiltIn;
  FTypes := TDictionary<string, TDateTimePolicy>.Create;
  FFields := TDictionary<string, TDateTimePolicy>.Create;
  FLock := TCriticalSection.Create;
end;

destructor TDateTimePolicies.Destroy;
begin
  FLock.Free;
  FFields.Free;
  FTypes.Free;
  inherited Destroy;
end;

procedure TDateTimePolicies.SetGlobal(const APolicy: TDateTimePolicy);
begin
  FLock.Enter;
  try
    FGlobal := APolicy;
    FHasGlobal := True;
  finally
    FLock.Leave;
  end;
end;

procedure TDateTimePolicies.SetForType(const ATypeKey: string;
  const APolicy: TDateTimePolicy);
begin
  if ATypeKey = '' then Exit;
  FLock.Enter;
  try
    FTypes.AddOrSetValue(LowerCase(ATypeKey), APolicy);
  finally
    FLock.Leave;
  end;
end;

procedure TDateTimePolicies.SetForField(const ATypeKey, AFieldName: string;
  const APolicy: TDateTimePolicy);
begin
  if (ATypeKey = '') or (AFieldName = '') then Exit;
  FLock.Enter;
  try
    FFields.AddOrSetValue(LowerCase(ATypeKey + '|' + AFieldName), APolicy);
  finally
    FLock.Leave;
  end;
end;

function TDateTimePolicies.Resolve(const ATypeKey,
  AFieldName: string): TDateTimePolicy;
begin
  FLock.Enter;
  try
    if (ATypeKey <> '') and (AFieldName <> '') and
       FFields.TryGetValue(LowerCase(ATypeKey + '|' + AFieldName), Result) then
      Exit;
    if (ATypeKey <> '') and FTypes.TryGetValue(LowerCase(ATypeKey), Result) then
      Exit;
    if FHasGlobal then Exit(FGlobal);
    Result := FBuiltIn;
  finally
    FLock.Leave;
  end;
end;

procedure TDateTimePolicies.Reset;
begin
  FLock.Enter;
  try
    FTypes.Clear;
    FFields.Clear;
    FHasGlobal := False;
  finally
    FLock.Leave;
  end;
end;

{ TSerializationOwnership }

function DynArrayElementTypeOf(ATypeInfo: PTypeInfo): PTypeInfo;
var
  TD: PTypeData;
begin
  Result := nil;
  if (ATypeInfo = nil) or (ATypeInfo.Kind <> tkDynArray) then Exit;
  TD := GetTypeData(ATypeInfo);
  { DynArrElType is the element type itself. elType is set only for a
    managed one, and elType2 is the INNERMOST element - Integer, for a
    TArray<TArray<Integer>> - so neither will do. }
  if TD.DynArrElType <> nil then Result := TD.DynArrElType^;
end;

{ Whether a value of this type can hold an object anywhere a deserializer
  would have put one: a class, or a record or array with one inside, at ANY
  depth. The walk stops only at a type it is already inside - a record that
  holds a dynamic array of itself - so a finite nesting of any depth is seen
  to the bottom: there is no depth cut-off, so a class twenty records down
  is found. The answer is a fact about the type, so it is cached. }
function TypeMayHoldObjectsWalk(ATypeInfo: PTypeInfo;
  AInside: TList<PTypeInfo>): Boolean;
var
  T: TRttiType;
  F: TRttiField;
begin
  Result := False;
  if ATypeInfo = nil then Exit;
  case ATypeInfo.Kind of
    tkClass: Exit(True);
    tkRecord, tkMRecord, tkDynArray, tkArray: ;
  else
    Exit;
  end;
  if AInside.Contains(ATypeInfo) then Exit;
  AInside.Add(ATypeInfo);
  try
    case ATypeInfo.Kind of
      tkRecord, tkMRecord:
        begin
          T := GCtx.GetType(ATypeInfo);
          if T <> nil then
            for F in T.GetFields do
              if (F.FieldType <> nil) and
                 TypeMayHoldObjectsWalk(F.FieldType.Handle, AInside) then
                Exit(True);
        end;
      tkDynArray:
        Result := TypeMayHoldObjectsWalk(DynArrayElementTypeOf(ATypeInfo),
          AInside);
      tkArray:
        begin
          T := GCtx.GetType(ATypeInfo);
          if (T is TRttiArrayType) and (TRttiArrayType(T).ElementType <> nil) then
            Result := TypeMayHoldObjectsWalk(
              TRttiArrayType(T).ElementType.Handle, AInside);
        end;
    end;
  finally
    AInside.Remove(ATypeInfo);
  end;
end;

var
  GHoldsObjects: TDictionary<PTypeInfo, Boolean>;
  GHoldsObjectsLock: TCriticalSection;

function TypeMayHoldObjects(ATypeInfo: PTypeInfo; ADepth: Integer): Boolean;
var
  Inside: TList<PTypeInfo>;
begin
  if ATypeInfo = nil then Exit(False);
  if ATypeInfo.Kind = tkClass then Exit(True);
  if not (ATypeInfo.Kind in [tkRecord, tkMRecord, tkDynArray, tkArray]) then
    Exit(False);
  GHoldsObjectsLock.Enter;
  try
    if GHoldsObjects.TryGetValue(ATypeInfo, Result) then Exit;
  finally
    GHoldsObjectsLock.Leave;
  end;
  Inside := TList<PTypeInfo>.Create;
  try
    Result := TypeMayHoldObjectsWalk(ATypeInfo, Inside);
  finally
    Inside.Free;
  end;
  GHoldsObjectsLock.Enter;
  try
    GHoldsObjects.AddOrSetValue(ATypeInfo, Result);
  finally
    GHoldsObjectsLock.Leave;
  end;
end;

function ArrayElementTypeOf(ATypeInfo: PTypeInfo): PTypeInfo;
var
  T: TRttiType;
begin
  Result := nil;
  if ATypeInfo = nil then Exit;
  if ATypeInfo.Kind = tkDynArray then Exit(DynArrayElementTypeOf(ATypeInfo));
  if ATypeInfo.Kind = tkArray then
  begin
    T := GCtx.GetType(ATypeInfo);
    if (T is TRttiArrayType) and (TRttiArrayType(T).ElementType <> nil) then
      Result := TRttiArrayType(T).ElementType.Handle;
  end;
end;

procedure ReleaseObject(AObject: TObject); forward;

procedure ReleaseBuiltAt(ATypeInfo: PTypeInfo; const AValue, AExisting: TValue;
  ADepth: Integer);
var
  Obj, Old: TObject;
  T: TRttiType;
  F: TRttiField;
  I: NativeInt;
  FV, FE, EV, EE: TValue;
  ET: PTypeInfo;
begin
  { A bound on the VALUE's nesting, not the type's: every reader refuses a
    document nested more than 512 deep, so this is only a stack guard. }
  if (ATypeInfo = nil) or AValue.IsEmpty or (ADepth > 1024) then Exit;
  case ATypeInfo.Kind of
    tkClass:
      begin
        if not AValue.IsObject then Exit;
        Obj := AValue.AsObject;
        if Obj = nil then Exit;
        Old := nil;
        if (not AExisting.IsEmpty) and AExisting.IsObject then
          Old := AExisting.AsObject;
        { The instance that was already there, filled in place: the
          caller's, never the read's to free. }
        if Obj = Old then Exit;
        ReleaseObject(Obj);
      end;
    tkRecord, tkMRecord:
      begin
        if not TypeMayHoldObjects(ATypeInfo, 0) then Exit;
        T := GCtx.GetType(ATypeInfo);
        if T = nil then Exit;
        for F in T.GetFields do
          if (F.FieldType <> nil) and
             TypeMayHoldObjects(F.FieldType.Handle, 0) then
          begin
            FV := F.GetValue(AValue.GetReferenceToRawData);
            if AExisting.IsEmpty then FE := TValue.Empty
            else FE := F.GetValue(AExisting.GetReferenceToRawData);
            ReleaseBuiltAt(F.FieldType.Handle, FV, FE, ADepth + 1);
          end;
      end;
    tkArray, tkDynArray:
      begin
        ET := ArrayElementTypeOf(ATypeInfo);
        if not TypeMayHoldObjects(ET, 0) then Exit;
        for I := 0 to AValue.GetArrayLength - 1 do
        begin
          EV := AValue.GetArrayElement(I);
          if (not AExisting.IsEmpty) and (I < AExisting.GetArrayLength) then
            EE := AExisting.GetArrayElement(I)
          else
            EE := TValue.Empty;
          ReleaseBuiltAt(ET, EV, EE, ADepth + 1);
        end;
      end;
  end;
end;

procedure ReleaseObject(AObject: TObject);
begin
  if AObject = nil then Exit;
  if TSerializationTypes.ContainerKindOf(AObject.ClassInfo) <>
     TContainerKind.None then
    TSerializationOwnership.ReleaseBuiltContainer(AObject)
  else
    AObject.Free;
end;

class function TSerializationOwnership.IsOwningType(
  ATypeInfo: PTypeInfo): Boolean;
begin
  { A class, or a record or array with an object inside it. Everything else
    - strings, dynamic arrays of scalars, records of scalars, interfaces -
    is owned by the TValue itself and goes away when it does. }
  Result := TypeMayHoldObjects(ATypeInfo, 0);
end;

class procedure TSerializationOwnership.Release(ATypeInfo: PTypeInfo;
  const AValue: TValue);
begin
  if (ATypeInfo = nil) or AValue.IsEmpty then Exit;
  ReleaseBuiltAt(ATypeInfo, AValue, TValue.Empty, 0);
end;

class procedure TSerializationOwnership.ReleaseBuilt(ATypeInfo: PTypeInfo;
  const AValue, AExisting: TValue);
begin
  ReleaseBuiltAt(ATypeInfo, AValue, AExisting, 0);
end;

class procedure TSerializationOwnership.ReleaseBuiltElements(
  AElementType: PTypeInfo; const AElements: array of TValue);
var
  I: NativeInt;
begin
  if not TypeMayHoldObjects(AElementType, 0) then Exit;
  for I := 0 to High(AElements) do
    ReleaseBuiltAt(AElementType, AElements[I], TValue.Empty, 1);
end;

class procedure TSerializationOwnership.ContainerOwnership(AContainer: TObject;
  out AOwnsKeys, AOwnsValues: Boolean);
var
  T: TRttiType;
  P: TRttiProperty;
  F: TRttiField;
  V: TValue;
  B: Byte;
begin
  AOwnsKeys := False;
  AOwnsValues := False;
  if AContainer = nil then Exit;
  T := GCtx.GetType(AContainer.ClassType);
  if T = nil then Exit;
  { TObjectList<T>, TObjectQueue<T>, TObjectStack<T>, TStringList. }
  P := T.GetProperty('OwnsObjects');
  if (P <> nil) and P.IsReadable and (P.PropertyType <> nil) and
     (P.PropertyType.Handle = System.TypeInfo(Boolean)) then
    { RTTI member access takes the instance as an untyped pointer. }
    {$WARN UNSAFE_CAST OFF}
    AOwnsValues := P.GetValue(AContainer).AsBoolean;
    {$WARN UNSAFE_CAST ON}
  { TObjectDictionary<K,V>: a set of doOwnsKeys, doOwnsValues. }
  F := T.GetField('FOwnerships');
  if (F <> nil) and (F.FieldType <> nil) and (F.FieldType.TypeKind = tkSet) then
  begin
    { RTTI member access takes the instance as an untyped pointer. }
    {$WARN UNSAFE_CAST OFF}
    V := F.GetValue(AContainer);
    {$WARN UNSAFE_CAST ON}
    B := 0;
    V.ExtractRawData(@B);
    AOwnsKeys := (B and 1) <> 0;
    AOwnsValues := (B and 2) <> 0;
  end;
end;

class procedure TSerializationOwnership.ReleaseBuiltContainer(
  AContainer: TObject);
var
  OwnsKeys, OwnsValues: Boolean;
  LA: TListAccess;
  DA: TDictionaryAccess;
  Items, Pair: TValue;
  Loose: TArray<TValue>;
  LooseTypes: TArray<PTypeInfo>;
  I: NativeInt;
begin
  if AContainer = nil then Exit;
  ContainerOwnership(AContainer, OwnsKeys, OwnsValues);
  Loose := nil;
  LooseTypes := nil;
  { Everything this read put in the container, when the container will not
    free it itself. Collected first and freed after the container, so that
    a dictionary never hashes a key that is already gone. }
  if TSerializationTypes.TryGetListAccess(AContainer.ClassInfo, LA) then
  begin
    if (not OwnsValues) and TypeMayHoldObjects(LA.ElementType, 0) and
       (LA.ToArrayMethod <> nil) then
    begin
      Items := LA.ToArrayMethod.Invoke(AContainer, []);
      for I := 0 to Items.GetArrayLength - 1 do
      begin
        Loose := Loose + [Items.GetArrayElement(I)];
        LooseTypes := LooseTypes + [LA.ElementType];
      end;
    end;
  end
  else if TSerializationTypes.TryGetDictionaryAccess(AContainer.ClassInfo, DA) then
  begin
    if ((not OwnsKeys) and TypeMayHoldObjects(DA.KeyType, 0)) or
       ((not OwnsValues) and TypeMayHoldObjects(DA.ValueType, 0)) then
    begin
      Items := DA.Pairs(TValue.From<TObject>(AContainer));
      for I := 0 to Items.GetArrayLength - 1 do
      begin
        Pair := Items.GetArrayElement(I);
        if (not OwnsKeys) and TypeMayHoldObjects(DA.KeyType, 0) then
        begin
          Loose := Loose + [DA.KeyOf(Pair)];
          LooseTypes := LooseTypes + [DA.KeyType];
        end;
        if (not OwnsValues) and TypeMayHoldObjects(DA.ValueType, 0) then
        begin
          Loose := Loose + [DA.ValueOf(Pair)];
          LooseTypes := LooseTypes + [DA.ValueType];
        end;
      end;
    end;
  end;
  AContainer.Free;
  for I := 0 to High(Loose) do
    ReleaseBuiltAt(LooseTypes[I], Loose[I], TValue.Empty, 1);
end;

class procedure TSerializationOwnership.AddOrSetBuilt(
  const AAccess: TDictionaryAccess; AContainer: TObject;
  const AKey, AValue: TValue);
var
  T: TRttiType;
  ContainsKey, ExtractPair: TRttiMethod;
  Old: TValue;
  OldKey, OldValue: TValue;
begin
  { Only a dictionary whose keys or values can be objects can orphan one. }
  if (AContainer <> nil) and (TypeMayHoldObjects(AAccess.KeyType, 0) or
     TypeMayHoldObjects(AAccess.ValueType, 0)) then
  begin
    T := GCtx.GetType(AContainer.ClassType);
    ContainsKey := T.GetMethod('ContainsKey');
    ExtractPair := T.GetMethod('ExtractPair');
    if (ContainsKey <> nil) and (ExtractPair <> nil) and
       ContainsKey.Invoke(AContainer, [AKey]).AsBoolean then
    begin
      { A duplicate key. The earlier pair is taken out WITHOUT the
        dictionary's ownership notification and released here - so an
        owning dictionary does not free it twice, and a non-owning one does
        not orphan it. }
      Old := ExtractPair.Invoke(AContainer, [AKey]);
      OldKey := AAccess.PairKeyField.GetValue(Old.GetReferenceToRawData);
      OldValue := AAccess.PairValueField.GetValue(Old.GetReferenceToRawData);
      AAccess.AddOrSet(TValue.From<TObject>(AContainer), AKey, AValue);
      ReleaseBuiltAt(AAccess.KeyType, OldKey, AKey, 1);
      ReleaseBuiltAt(AAccess.ValueType, OldValue, AValue, 1);
      Exit;
    end;
  end;
  AAccess.AddOrSet(TValue.From<TObject>(AContainer), AKey, AValue);
end;

{ TSerializationFormats }

class procedure TSerializationFormats.Register(AFormat: TSerializationFormat;
  AHandlerClass: TSerializationFormatHandlerClass);
begin
  FLock.Enter;
  try
    if FHandlers[AFormat] <> nil then
    begin
      { Registering the same handler twice is harmless - a unit can be pulled
        in through more than one path.  Registering a DIFFERENT one is not:
        which wins would depend on initialization order, which is not
        something an application should have to reason about. }
      if FHandlers[AFormat].ClassType = AHandlerClass then Exit;
      raise ESerializationFormatConflict.CreateFmt(
        'Serialization format %s is already registered to %s; %s cannot ' +
        'replace it. Unregister it first if the replacement is intended.',
        [FormatName(AFormat), FHandlers[AFormat].ClassName,
         AHandlerClass.ClassName]);
    end;
    FHandlers[AFormat] := AHandlerClass.Create;
  finally
    FLock.Leave;
  end;
end;

class procedure TSerializationFormats.Unregister(AFormat: TSerializationFormat);
begin
  FLock.Enter;
  try
    FreeAndNil(FHandlers[AFormat]);
  finally
    FLock.Leave;
  end;
end;

class procedure TSerializationFormats.Unregister(AFormat: TSerializationFormat;
  AHandlerClass: TSerializationFormatHandlerClass);
begin
  FLock.Enter;
  try
    if (FHandlers[AFormat] <> nil) and
       (FHandlers[AFormat].ClassType = AHandlerClass) then
      FreeAndNil(FHandlers[AFormat]);
  finally
    FLock.Leave;
  end;
end;

class function TSerializationFormats.IsRegistered(AFormat: TSerializationFormat): Boolean;
begin
  FLock.Enter;
  try
    Result := FHandlers[AFormat] <> nil;
  finally
    FLock.Leave;
  end;
end;

class function TSerializationFormats.IsRegistered(AFormat: TSerializationFormat;
  AHandlerClass: TSerializationFormatHandlerClass): Boolean;
begin
  FLock.Enter;
  try
    Result := (FHandlers[AFormat] <> nil) and
      (FHandlers[AFormat].ClassType = AHandlerClass);
  finally
    FLock.Leave;
  end;
end;

class function TSerializationFormats.TryGet(AFormat: TSerializationFormat;
  out AHandler: TSerializationFormatHandler): Boolean;
begin
  FLock.Enter;
  try
    AHandler := FHandlers[AFormat];
  finally
    FLock.Leave;
  end;
  Result := AHandler <> nil;
end;

class function TSerializationFormats.Get(
  AFormat: TSerializationFormat): TSerializationFormatHandler;
begin
  if not TryGet(AFormat, Result) then
    raise ESerializationFormatNotRegistered.CreateFor(AFormat);
end;

class function TSerializationFormats.Capabilities(
  AFormat: TSerializationFormat): TSerializationFormatCapabilities;
var
  Handler: TSerializationFormatHandler;
begin
  if TryGet(AFormat, Handler) then Result := Handler.Capabilities
  else Result := [];
end;

class function TSerializationFormats.Capabilities(AFormat: TSerializationFormat;
  const AOptions: TStructuralConversionOptions): TSerializationFormatCapabilities;
var
  Handler: TSerializationFormatHandler;
begin
  if TryGet(AFormat, Handler) then Result := Handler.Capabilities(AOptions)
  else Result := [];
end;

class function TSerializationFormats.Supports(AFormat: TSerializationFormat;
  ACapability: TSerializationFormatCapability): Boolean;
begin
  Result := ACapability in Capabilities(AFormat);
end;

class function TSerializationFormats.Supports(AFormat: TSerializationFormat;
  ACapability: TSerializationFormatCapability;
  const AOptions: TStructuralConversionOptions): Boolean;
begin
  Result := ACapability in Capabilities(AFormat, AOptions);
end;

class function TSerializationFormats.Require(AFormat: TSerializationFormat;
  ACapability: TSerializationFormatCapability): TSerializationFormatHandler;
begin
  { Two different failures, two different exceptions.  Telling somebody to
    register a format they already registered would send them the wrong
    way for an hour. }
  Result := Get(AFormat);
  if not (ACapability in Result.Capabilities) then
    Result.RaiseUnsupported(ACapability, AFormat,
      TStructuralConversionOptions.Default);
end;

class function TSerializationFormats.Require(AFormat: TSerializationFormat;
  ACapability: TSerializationFormatCapability;
  const AOptions: TStructuralConversionOptions): TSerializationFormatHandler;
begin
  Result := Get(AFormat);
  if not (ACapability in Result.Capabilities(AOptions)) then
    Result.RaiseUnsupported(ACapability, AFormat, AOptions);
end;

class function TSerializationFormats.FormatName(AFormat: TSerializationFormat): string;
begin
  Result := GetEnumName(TypeInfo(TSerializationFormat), Ord(AFormat));
end;

class function TSerializationFormats.IsAsn1(
  AFormat: TSerializationFormat): Boolean;
begin
  Result := AFormat in [TSerializationFormat.Asn1Ber,
                        TSerializationFormat.Asn1Der,
                        TSerializationFormat.Asn1Cer];
end;

class function TSerializationFormats.UnitStem(
  AFormat: TSerializationFormat): string;
begin
  if IsAsn1(AFormat) then Exit('Asn1');
  Result := FormatName(AFormat);
end;

class function TSerializationFormats.RegisteredFormats: TArray<TSerializationFormat>;
var
  F: TSerializationFormat;
  N: Integer;
begin
  SetLength(Result, Ord(High(TSerializationFormat)) - Ord(Low(TSerializationFormat)) + 1);
  N := 0;
  for F := Low(TSerializationFormat) to High(TSerializationFormat) do
    if IsRegistered(F) then
    begin
      Result[N] := F;
      Inc(N);
    end;
  SetLength(Result, N);
end;


{ --------------------------------------------------------------------------
  NULLABLE FAMILIES - implementation
  -------------------------------------------------------------------------- }

type
  TRecordFieldDesc = record
    Name: string;
    FieldType: PTypeInfo;
    Offset: Integer;
  end;

  TNullableFamily = record
    UnitName: string; { '' whenever RTTI does not carry one, which for a
                        closed generic record is always }
    Base: string;     { generic base name alone, e.g. 'TNullable' }
    Arity: Integer;
    Layout: TNullableLayout;
    function Describe: string;
  end;

var
  GNullableFamilies: TList<TNullableFamily>;
  GNullableAccessCache: TDictionary<PTypeInfo, TNullableAccess>;
  GNullableLock: TCriticalSection;

{ Record field RTTI, walked directly.  TRttiType.GetFields would do the same
  job, but it allocates a TRttiField per call and this runs while plans are
  being built for every record the application touches. }
function RecordFieldsOf(ATypeInfo: PTypeInfo): TArray<TRecordFieldDesc>;
var
  P: PByte;
  Fld: PRecordTypeField;
  Count, I: Integer;
begin
  Result := nil;
  if (ATypeInfo = nil) or (ATypeInfo.Kind <> tkRecord) then Exit;
  P := @ATypeInfo.TypeData.ManagedFldCount;
  { skip ManagedFldCount and the managed field table }
  Inc(P, SizeOf(Integer) + SizeOf(TManagedField) * PInteger(P)^);
  { skip NumOps and the record operator table }
  Inc(P, SizeOf(Byte) + SizeOf(Pointer) * P^);
  Count := PInteger(P)^;
  if (Count <= 0) or (Count > 4096) then Exit;
  Inc(P, SizeOf(Integer));
  SetLength(Result, Count);
  for I := 0 to Count - 1 do
  begin
    Fld := PRecordTypeField(P);
    Result[I].Name := UTF8ToString(Fld.Name);
    if Fld.Field.TypeRef <> nil then
      Result[I].FieldType := Fld.Field.TypeRef^
    else
      Result[I].FieldType := nil;
    Result[I].Offset := Integer(Fld.Field.FldOffset);
    { the name is a ShortString; the attribute table follows it }
    P := PByte(@Fld.Name);
    Inc(P, P^ + 1 + SizeOf(TAttrData));
  end;
end;

{ HasValue is read through PBoolean, one byte.  Anything wider would read
  past the flag, so the registration is refused rather than silently wrong. }
function IsOneByteBoolean(ATypeInfo: PTypeInfo): Boolean;
begin
  Result := (ATypeInfo <> nil) and
    ((ATypeInfo = System.TypeInfo(Boolean)) or
     (ATypeInfo = System.TypeInfo(ByteBool)));
end;

{ Resolves one concrete specialization against a family's layout.  AError
  explains the failure for the registration-time message; the lookup path
  ignores it. }
function TryResolveNullable(ATypeInfo: PTypeInfo;
  const ALayout: TNullableLayout; out AAccess: TNullableAccess;
  out AError: string): Boolean;
var
  Fields: TArray<TRecordFieldDesc>;
  I: NativeInt;
  HaveValue, HaveFlag: Boolean;
begin
  AAccess := Default(TNullableAccess);
  AError := '';
  Result := False;
  Fields := RecordFieldsOf(ATypeInfo);
  if Length(Fields) = 0 then
  begin
    AError := 'has no field RTTI, so its layout cannot be read.';
    Exit;
  end;
  HaveValue := False;
  HaveFlag := False;
  for I := 0 to High(Fields) do
  begin
    if (not HaveValue) and SameText(Fields[I].Name, ALayout.ValueField) then
    begin
      if Fields[I].FieldType = nil then
      begin
        AError := Format('has a field named %s with no type information.',
          [ALayout.ValueField]);
        Exit;
      end;
      AAccess.FValueType := Fields[I].FieldType;
      AAccess.FValueOffset := Fields[I].Offset;
      HaveValue := True;
    end
    else if (not HaveFlag) and SameText(Fields[I].Name, ALayout.HasValueField) then
    begin
      if not IsOneByteBoolean(Fields[I].FieldType) then
      begin
        AError := Format('has a field named %s that is not a one-byte Boolean.',
          [ALayout.HasValueField]);
        Exit;
      end;
      AAccess.FHasValueOffset := Fields[I].Offset;
      HaveFlag := True;
    end;
  end;
  if not HaveValue then
  begin
    AError := Format('has no field named %s.', [ALayout.ValueField]);
    Exit;
  end;
  if not HaveFlag then
  begin
    AError := Format('has no field named %s.', [ALayout.HasValueField]);
    Exit;
  end;
  AAccess.FResolved := True;
  Result := True;
end;

function TNullableFamily.Describe: string;
begin
  if UnitName <> '' then Result := UnitName + '.' else Result := '';
  Result := Result + Base + '<' + IntToStr(Arity) + '> [' +
    Layout.Describe + ']';
end;

{ Whether a specialization belongs to a registered family.  The unit takes
  part only when both sides have one, because a closed generic record never
  does - see WHAT IDENTIFIES A FAMILY in the interface section. }
function SameNullableFamily(const AFamily: TNullableFamily;
  const ABase: string; AArity: Integer; const AUnitName: string): Boolean;
begin
  Result := (AFamily.Arity = AArity) and SameText(AFamily.Base, ABase);
  if Result and (AFamily.UnitName <> '') and (AUnitName <> '') then
    Result := SameText(AFamily.UnitName, AUnitName);
end;

{ TNullableLayout }

class function TNullableLayout.Default: TNullableLayout;
begin
  Result.FValueField := 'FValue';
  Result.FHasValueField := 'FHasValue';
end;

class function TNullableLayout.Fields(const AValueField,
  AHasValueField: string): TNullableLayout;
begin
  Result.FValueField := AValueField;
  Result.FHasValueField := AHasValueField;
end;

function TNullableLayout.SameAs(const AOther: TNullableLayout): Boolean;
begin
  Result := SameText(FValueField, AOther.FValueField) and
            SameText(FHasValueField, AOther.FHasValueField);
end;

function TNullableLayout.Describe: string;
begin
  Result := FValueField + '/' + FHasValueField;
end;

{ TNullableAccess }

function TNullableAccess.HasValue(AInstance: Pointer): Boolean;
begin
  Result := PBoolean(PByte(AInstance) + FHasValueOffset)^;
end;

function TNullableAccess.GetValue(AInstance: Pointer): TValue;
begin
  TValue.Make(PByte(AInstance) + FValueOffset, FValueType, Result);
end;

procedure TNullableAccess.SetValue(AInstance: Pointer; const AValue: TValue);
begin
  AValue.Cast(FValueType).ExtractRawData(PByte(AInstance) + FValueOffset);
  PBoolean(PByte(AInstance) + FHasValueOffset)^ := not AValue.IsEmpty;
end;

procedure TNullableAccess.SetExactValue(AInstance: Pointer;
  const AValue: TValue);
begin
  AValue.ExtractRawData(PByte(AInstance) + FValueOffset);
  PBoolean(PByte(AInstance) + FHasValueOffset)^ := not AValue.IsEmpty;
end;

procedure TNullableAccess.Clear(AInstance: Pointer);
begin
  PBoolean(PByte(AInstance) + FHasValueOffset)^ := False;
end;

{ TSerializationTypes }

class procedure TSerializationTypes.RegisterNullableFamily<T>;
begin
  DoRegisterNullableFamily(System.TypeInfo(T), TNullableLayout.Default);
end;

class procedure TSerializationTypes.RegisterNullableFamily<T>(
  const ALayout: TNullableLayout);
begin
  DoRegisterNullableFamily(System.TypeInfo(T), ALayout);
end;

class procedure TSerializationTypes.DoRegisterNullableFamily(AInfo: PTypeInfo;
  const ALayout: TNullableLayout);
var
  Base, Err, N, UnitName: string;
  Arity: Integer;
  I: NativeInt;
  Fam: TNullableFamily;
  Access: TNullableAccess;
begin
  if AInfo = nil then
    raise ENullableFamilyError.Create(
      'RegisterNullableFamily: the type has no RTTI, so there is no family ' +
      'to register.');
  N := UTF8ToString(AInfo^.Name);
  if AInfo^.Kind <> tkRecord then
    raise ENullableFamilyError.CreateFmt(
      'RegisterNullableFamily: %s is not a record. A nullable family is a ' +
      'generic record holding a value and a has-value flag.', [N]);
  if (ALayout.ValueField = '') or (ALayout.HasValueField = '') then
    raise ENullableFamilyError.CreateFmt(
      'RegisterNullableFamily: %s was given an incomplete layout (%s). Both ' +
      'field names are required.', [N, ALayout.Describe]);
  if not TryGenericBaseAndArity(AInfo, Base, Arity) then
    raise ENullableFamilyError.CreateFmt(
      'RegisterNullableFamily: %s is not a closed generic specialization. A ' +
      'family is registered through one specialization of it, for example ' +
      'TMaybe<Integer>.', [N]);
  { Validated against the representative only.  Every other specialization is
    resolved when it is first used, because its offsets are its own. }
  if not TryResolveNullable(AInfo, ALayout, Access, Err) then
    raise ENullableFamilyError.CreateFmt(
      'RegisterNullableFamily: %s %s Expected the layout %s.',
      [N, Err, ALayout.Describe]);
  UnitName := TypeUnitOf(AInfo);
  GNullableLock.Enter;
  try
    for I := 0 to GNullableFamilies.Count - 1 do
    begin
      Fam := GNullableFamilies[I];
      if not SameNullableFamily(Fam, Base, Arity, UnitName) then Continue;
      { Registering the same family the same way twice is a no-op: two units
        may each register it, and neither can know about the other. }
      if Fam.Layout.SameAs(ALayout) then Exit;
      raise ENullableFamilyError.CreateFmt(
        'RegisterNullableFamily: %s cannot be registered with the layout %s ' +
        'because the family %s is already registered. If this is the same ' +
        'family, register it once: which layout won would otherwise depend on ' +
        'unit initialization order. If these are two different nullable types ' +
        'that happen to share a base name and arity, they cannot be told ' +
        'apart - Delphi emits no declaring unit for a closed generic record - ' +
        'so only one of them can be a registered family here.',
        [N, ALayout.Describe, Fam.Describe]);
    end;
    Fam.UnitName := UnitName;
    Fam.Base := Base;
    Fam.Arity := Arity;
    Fam.Layout := ALayout;
    GNullableFamilies.Add(Fam);
  finally
    GNullableLock.Leave;
  end;
end;

class function TSerializationTypes.TryGetNullableAccess(ATypeInfo: PTypeInfo;
  out AAccess: TNullableAccess): Boolean;
var
  Base, Err, UnitName: string;
  Arity: Integer;
  I: NativeInt;
  Matched: Boolean;
  Fam: TNullableFamily;
begin
  AAccess := Default(TNullableAccess);
  Result := False;
  if (ATypeInfo = nil) or (ATypeInfo.Kind <> tkRecord) then Exit;
  if not TryGenericBaseAndArity(ATypeInfo, Base, Arity) then Exit;
  { Resolved outside the lock: TypeUnitOf takes a different one. }
  UnitName := TypeUnitOf(ATypeInfo);
  GNullableLock.Enter;
  try
    if GNullableAccessCache.TryGetValue(ATypeInfo, AAccess) then Exit(True);
    Matched := False;
    for I := 0 to GNullableFamilies.Count - 1 do
    begin
      Fam := GNullableFamilies[I];
      if not SameNullableFamily(Fam, Base, Arity, UnitName) then Continue;
      { Belonging to the family is not enough: the record must actually carry
        the fields that family was registered with. }
      if TryResolveNullable(ATypeInfo, Fam.Layout, AAccess, Err) then
      begin
        Matched := True;
        Break;
      end;
    end;
    if not Matched then
    begin
      AAccess := Default(TNullableAccess);
      Exit(False);
    end;
    GNullableAccessCache.AddOrSetValue(ATypeInfo, AAccess);
    Result := True;
  finally
    GNullableLock.Leave;
  end;
end;

class function TSerializationTypes.IsNullableType(
  ATypeInfo: PTypeInfo): Boolean;
var
  Access: TNullableAccess;
begin
  Result := TryGetNullableAccess(ATypeInfo, Access);
end;

class function TSerializationTypes.RegisteredNullableFamilies: TArray<string>;
var
  I: NativeInt;
begin
  GNullableLock.Enter;
  try
    SetLength(Result, GNullableFamilies.Count);
    for I := 0 to GNullableFamilies.Count - 1 do
      Result[I] := GNullableFamilies[I].Describe;
  finally
    GNullableLock.Leave;
  end;
end;

{ ===========================================================================
  CONTAINER ACCESS

  Recognition by ancestry, resolution by RTTI, both cached. The cache is
  keyed by PTypeInfo and guarded, because engines run concurrently and a
  half-built access record must never be visible to a second thread.
  =========================================================================== }

type
  TContainerFamily = record
    BaseName: string;
    Owns: Boolean;
    AddName: string;
    ToArrayName: string;
  end;

var
  GContainerLock: TCriticalSection;
  GListFamilies: TArray<TContainerFamily>;
  GDictFamilies: TArray<TContainerFamily>;
  GListCache: TDictionary<PTypeInfo, TListAccess>;
  GDictCache: TDictionary<PTypeInfo, TDictionaryAccess>;

{ The family whose specialization appears in ATypeInfo's ancestry, or '' .

  This walks the REAL class chain and compares each ancestor's name against
  the family base names, so an ordinary descendant is recognised and a class
  that merely looks similar is not. }
function MatchContainerFamily(ATypeInfo: PTypeInfo;
  const AFamilies: TArray<TContainerFamily>;
  out AFamily: TContainerFamily): string;
var
  C: TClass;
  F: TContainerFamily;
  Name_: string;
begin
  Result := '';
  AFamily := Default(TContainerFamily);
  if (ATypeInfo = nil) or (ATypeInfo.Kind <> tkClass) then Exit;
  C := GetTypeData(ATypeInfo).ClassType;
  while C <> nil do
  begin
    Name_ := C.ClassName;
    for F in AFamilies do
      if (F.BaseName.EndsWith('<') and Name_.StartsWith(F.BaseName)) or
         (not F.BaseName.EndsWith('<') and SameText(Name_, F.BaseName)) then
      begin
        { Everything - the owning flag above all - is taken from the most
          derived match, because TObjectList<T> is a TList<T> and only the
          first of those owns. }
        AFamily := F;
        Exit(F.BaseName);
      end;
    C := C.ClassParent;
  end;
end;

{ The parameterless constructor a family offers, preferring the container's
  own over TObject.Create. }
function ParameterlessConstructor(AType: TRttiType): TRttiMethod;
var
  M: TRttiMethod;
begin
  Result := nil;
  for M in AType.GetMethods do
    if M.IsConstructor and (Length(M.GetParameters) = 0) then
      if (Result = nil) or SameText(Result.Parent.Name, 'TObject') then
        Result := M;
end;

class procedure TSerializationTypes.RegisterListFamily(
  const AFamilyBaseName: string; AOwns: Boolean; const AAddName: string;
  const AToArrayName: string);
var
  F: TContainerFamily;
  I: NativeInt;
begin
  GContainerLock.Enter;
  try
    for I := 0 to High(GListFamilies) do
      if GListFamilies[I].BaseName = AFamilyBaseName then
      begin
        GListFamilies[I].Owns := AOwns;
        GListFamilies[I].AddName := AAddName;
        GListFamilies[I].ToArrayName := AToArrayName;
        GListCache.Clear;
        Exit;
      end;
    F.BaseName := AFamilyBaseName;
    F.Owns := AOwns;
    F.AddName := AAddName;
    F.ToArrayName := AToArrayName;
    GListFamilies := GListFamilies + [F];
    { A new family can change the answer for a type already resolved, so the
      caches go. Registration happens at startup, not in a loop. }
    GListCache.Clear;
    GDictCache.Clear;
  finally
    GContainerLock.Leave;
  end;
end;

class procedure TSerializationTypes.RegisterDictionaryFamily(
  const AFamilyBaseName: string; AOwns: Boolean);
var
  F: TContainerFamily;
  I: NativeInt;
begin
  GContainerLock.Enter;
  try
    for I := 0 to High(GDictFamilies) do
      if GDictFamilies[I].BaseName = AFamilyBaseName then
      begin
        GDictFamilies[I].Owns := AOwns;
        Exit;
      end;
    F.BaseName := AFamilyBaseName;
    F.Owns := AOwns;
    F.AddName := 'AddOrSetValue';
    F.ToArrayName := 'ToArray';
    GDictFamilies := GDictFamilies + [F];
    GListCache.Clear;
    GDictCache.Clear;
  finally
    GContainerLock.Leave;
  end;
end;

class function TSerializationTypes.RegisteredContainerFamilies: TArray<string>;
var
  F: TContainerFamily;
begin
  Result := nil;
  GContainerLock.Enter;
  try
    for F in GListFamilies do Result := Result + ['list:' + F.BaseName];
    for F in GDictFamilies do Result := Result + ['dictionary:' + F.BaseName];
  finally
    GContainerLock.Leave;
  end;
end;

function BuildListAccess(ATypeInfo: PTypeInfo;
  const AFamily: TContainerFamily; out AAccess: TListAccess): Boolean;
var
  RT: TRttiType;
  M: TRttiMethod;
  P: TArray<TRttiParameter>;
begin
  AAccess := Default(TListAccess);
  AAccess.ContainerType := ATypeInfo;
  AAccess.Family := AFamily.BaseName;
  AAccess.Owns := AFamily.Owns;
  RT := GCtx.GetType(ATypeInfo);
  if RT = nil then Exit(False);
  for M in RT.GetMethods do
  begin
    P := M.GetParameters;
    if M.IsConstructor then Continue;
    if SameText(M.Name, AFamily.AddName) and (Length(P) = 1) then
    begin
      AAccess.AddMethod := M;
      if P[0].ParamType <> nil then
        AAccess.ElementType := P[0].ParamType.Handle;
    end
    else if SameText(M.Name, AFamily.ToArrayName) and (Length(P) = 0) then
      AAccess.ToArrayMethod := M
    else if SameText(M.Name, 'Clear') and (Length(P) = 0) then
      AAccess.ClearMethod := M;
  end;
  AAccess.CreateMethod := ParameterlessConstructor(RT);
  { The element type from ToArray when Add did not give one - a family whose
    Add takes a differently spelled parameter still yields TArray<T>. }
  if (AAccess.ElementType = nil) and (AAccess.ToArrayMethod <> nil) and
     (AAccess.ToArrayMethod.ReturnType <> nil) and
     (GetTypeData(AAccess.ToArrayMethod.ReturnType.Handle).DynArrElType <> nil) then
    AAccess.ElementType :=
      GetTypeData(AAccess.ToArrayMethod.ReturnType.Handle).DynArrElType^;
  Result := AAccess.IsValid;
end;

function BuildDictionaryAccess(ATypeInfo: PTypeInfo;
  const AFamily: string; AOwns: Boolean;
  out AAccess: TDictionaryAccess): Boolean;
var
  RT, PairType: TRttiType;
  M: TRttiMethod;
  P: TArray<TRttiParameter>;
begin
  AAccess := Default(TDictionaryAccess);
  AAccess.ContainerType := ATypeInfo;
  AAccess.Family := AFamily;
  AAccess.Owns := AOwns;
  RT := GCtx.GetType(ATypeInfo);
  if RT = nil then Exit(False);
  for M in RT.GetMethods do
  begin
    P := M.GetParameters;
    if M.IsConstructor then Continue;
    if SameText(M.Name, 'AddOrSetValue') and (Length(P) = 2) then
    begin
      AAccess.AddOrSetMethod := M;
      if P[0].ParamType <> nil then AAccess.KeyType := P[0].ParamType.Handle;
      if P[1].ParamType <> nil then AAccess.ValueType := P[1].ParamType.Handle;
    end
    else if SameText(M.Name, 'ToArray') and (Length(P) = 0) then
      AAccess.ToArrayMethod := M
    else if SameText(M.Name, 'Clear') and (Length(P) = 0) then
      AAccess.ClearMethod := M;
  end;
  AAccess.CreateMethod := ParameterlessConstructor(RT);

  { The pair type, and the two fields that read one. A dictionary whose
    ToArray does not yield Key/Value pairs is not one this layer can
    describe, and says so by not validating. }
  if (AAccess.ToArrayMethod <> nil) and
     (AAccess.ToArrayMethod.ReturnType <> nil) and
     (AAccess.ToArrayMethod.ReturnType.TypeKind = tkDynArray) then
  begin
    PairType := TRttiDynamicArrayType(AAccess.ToArrayMethod.ReturnType).ElementType;
    if PairType <> nil then
    begin
      AAccess.PairKeyField := PairType.GetField('Key');
      AAccess.PairValueField := PairType.GetField('Value');
    end;
  end;
  Result := AAccess.IsValid;
end;

class function TSerializationTypes.TryGetListAccess(ATypeInfo: PTypeInfo;
  out AAccess: TListAccess): Boolean;
var
  Family: string;
  Matched: TContainerFamily;
  Families: TArray<TContainerFamily>;
begin
  AAccess := Default(TListAccess);
  if (ATypeInfo = nil) or (ATypeInfo.Kind <> tkClass) then Exit(False);

  GContainerLock.Enter;
  try
    if GListCache.TryGetValue(ATypeInfo, AAccess) then
      Exit(AAccess.IsValid);
    Families := GListFamilies;
  finally
    GContainerLock.Leave;
  end;

  Family := MatchContainerFamily(ATypeInfo, Families, Matched);
  if Family = '' then
  begin
    { A negative answer is cached too. Re-walking the ancestry of every
      ordinary class on every member of every object is not free. }
    GContainerLock.Enter;
    try
      GListCache.AddOrSetValue(ATypeInfo, Default(TListAccess));
    finally
      GContainerLock.Leave;
    end;
    Exit(False);
  end;

  Result := BuildListAccess(ATypeInfo, Matched, AAccess);
  GContainerLock.Enter;
  try
    GListCache.AddOrSetValue(ATypeInfo, AAccess);
  finally
    GContainerLock.Leave;
  end;
end;

class function TSerializationTypes.TryGetDictionaryAccess(ATypeInfo: PTypeInfo;
  out AAccess: TDictionaryAccess): Boolean;
var
  Family: string;
  Matched: TContainerFamily;
  Families: TArray<TContainerFamily>;
begin
  AAccess := Default(TDictionaryAccess);
  if (ATypeInfo = nil) or (ATypeInfo.Kind <> tkClass) then Exit(False);

  GContainerLock.Enter;
  try
    if GDictCache.TryGetValue(ATypeInfo, AAccess) then
      Exit(AAccess.IsValid);
    Families := GDictFamilies;
  finally
    GContainerLock.Leave;
  end;

  Family := MatchContainerFamily(ATypeInfo, Families, Matched);
  if Family = '' then
  begin
    GContainerLock.Enter;
    try
      GDictCache.AddOrSetValue(ATypeInfo, Default(TDictionaryAccess));
    finally
      GContainerLock.Leave;
    end;
    Exit(False);
  end;

  Result := BuildDictionaryAccess(ATypeInfo, Family, Matched.Owns, AAccess);
  GContainerLock.Enter;
  try
    GDictCache.AddOrSetValue(ATypeInfo, AAccess);
  finally
    GContainerLock.Leave;
  end;
end;

class function TSerializationTypes.IsUnsignedInteger(
  ATypeInfo: PTypeInfo): Boolean;
begin
  if ATypeInfo = nil then Exit(False);
  case ATypeInfo.Kind of
    tkInteger:
      Result := GetTypeData(ATypeInfo).OrdType in [otUByte, otUWord, otULong];
    { UInt64's declared range is 0..$FFFFFFFFFFFFFFFF, which the signed
      MaxInt64Value field holds as -1. An Int64 subrange never looks like
      that, because its top is never below its bottom. }
    tkInt64:
      Result := (GetTypeData(ATypeInfo).MinInt64Value >= 0) and
                (GetTypeData(ATypeInfo).MaxInt64Value < 0);
  else
    Result := False;
  end;
end;

class function TSerializationTypes.IsCompType(ATypeInfo: PTypeInfo): Boolean;
begin
  Result := (ATypeInfo <> nil) and (ATypeInfo.Kind = tkFloat) and
    (GetTypeData(ATypeInfo).FloatType = ftComp);
end;

class function TSerializationTypes.Int64Bits(const AValue: TValue): Int64;
begin
  if AValue.IsEmpty then Exit(0);
  case AValue.Kind of
    { Comp is two's complement in its eight bytes, exactly like Int64. }
    tkInt64, tkFloat:
      Result := PInt64(AValue.GetReferenceToRawData)^;
  else
    { AsOrdinal honours OrdType, so a Cardinal comes back zero-extended. }
    Result := AValue.AsOrdinal;
  end;
end;

class function TSerializationTypes.IntegerText(const AValue: TValue): string;
begin
  if IsUnsignedInteger(AValue.TypeInfo) then
    Result := UIntToStr(UInt64(Int64Bits(AValue)))
  else
    Result := IntToStr(Int64Bits(AValue));
end;

class function TSerializationTypes.TryIntegerFromInt64(ATypeInfo: PTypeInfo;
  AValue: Int64; out AResult: TValue): Boolean;
var
  TD: PTypeData;
begin
  Result := False;
  AResult := TValue.Empty;
  if ATypeInfo = nil then Exit;
  TD := GetTypeData(ATypeInfo);
  if IsUnsignedInteger(ATypeInfo) then
  begin
    if AValue < 0 then Exit;
    Exit(TryIntegerFromUInt64(ATypeInfo, UInt64(AValue), AResult));
  end;
  case ATypeInfo.Kind of
    tkInteger:
      if (AValue < TD.MinValue) or (AValue > TD.MaxValue) then Exit;
    tkInt64:
      if (AValue < TD.MinInt64Value) or (AValue > TD.MaxInt64Value) then Exit;
    tkFloat:
      if not IsCompType(ATypeInfo) then Exit;
  else
    Exit;
  end;
  TValue.Make(@AValue, ATypeInfo, AResult);
  Result := True;
end;

class function TSerializationTypes.TryIntegerFromUInt64(ATypeInfo: PTypeInfo;
  AValue: UInt64; out AResult: TValue): Boolean;
var
  TD: PTypeData;
begin
  Result := False;
  AResult := TValue.Empty;
  if ATypeInfo = nil then Exit;
  TD := GetTypeData(ATypeInfo);
  if not IsUnsignedInteger(ATypeInfo) then
  begin
    if AValue > UInt64(High(Int64)) then Exit;
    Exit(TryIntegerFromInt64(ATypeInfo, Int64(AValue), AResult));
  end;
  if ATypeInfo.Kind = tkInteger then
  begin
    if (AValue < Cardinal(TD.MinValue)) or (AValue > Cardinal(TD.MaxValue)) then
      Exit;
  end
  else if (AValue < UInt64(TD.MinInt64Value)) or
          (AValue > UInt64(TD.MaxInt64Value)) then Exit;
  TValue.Make(@AValue, ATypeInfo, AResult);
  Result := True;
end;

const
  { 2^128 - 2^103, the midpoint between the largest Single and 2^128. }
  SINGLE_ROUNDING_LIMIT_BITS: UInt64 = $47EFFFFFF0000000;

{ A finite double inside Currency's range as the Currency nearest to it,
  ties to even - the Win32 FPU's answer - computed exactly. }
function ExactCurrencyFromDouble(AValue: Double): Currency;
var
  Bits, M, Scaled: UInt64;
  Field, E2, Shift: Integer;
  N: TBigNat;
  Scaled64: Int64;
begin
  Move(AValue, Bits, SizeOf(Bits));
  Field := Integer((Bits shr 52) and $7FF);
  if Field = 0 then Exit(0);   { zero or subnormal: far below 0.00005 }
  M := (Bits and ((UInt64(1) shl 52) - 1)) or (UInt64(1) shl 52);
  E2 := Field - 1075;           { AValue = M * 2^E2 }
  N := BigFromUInt64(M);
  BigMulAddSmall(N, 10000, 0);
  if E2 >= 0 then
    Scaled := BigExtract(BigShl(N, E2), 0, 64)
  else
  begin
    Shift := -E2;
    Scaled := BigExtract(N, Shift, Max(0, BigBitLength(N) - Shift));
    if BigBit(N, Shift - 1) and (BigAnyBelow(N, Shift - 1) or Odd(Scaled)) then
      Inc(Scaled);
  end;
  Scaled64 := Int64(Scaled);
  if (Bits shr 63) <> 0 then Scaled64 := -Scaled64;
  Move(Scaled64, Result, SizeOf(Result));
end;

class function TSerializationTypes.TryFloatFromDouble(ATypeInfo: PTypeInfo;
  AValue: Double; out AResult: TValue; out AWhy: string): Boolean;
var
  S: Single;
  E: Extended;
  C: Currency;
begin
  Result := False;
  AWhy := '';
  AResult := TValue.Empty;
  if (ATypeInfo = nil) or (ATypeInfo.Kind <> tkFloat) then
  begin
    AWhy := 'the member is not a floating-point type';
    Exit;
  end;
  case GetTypeData(ATypeInfo).FloatType of
    ftSingle:
      begin
        { Refused only at the midpoint between the largest Single and 2^128:
          everything below it rounds to a finite Single - the largest one
          included, whose shortest text 3.4028235E38 is a little above it. }
        if not (AValue.IsNan or AValue.IsInfinity) and
           (Abs(AValue) >= PDouble(@SINGLE_ROUNDING_LIMIT_BITS)^) then
        begin
          AWhy := Format('%s is beyond what a Single holds',
            [TStructuralText.EncodeFloat(AValue)]);
          Exit;
        end;
        S := AValue;
        TValue.Make(@S, ATypeInfo, AResult);
      end;
    ftDouble:
      TValue.Make(@AValue, ATypeInfo, AResult);
    ftExtended:
      begin
        E := AValue;
        TValue.Make(@E, ATypeInfo, AResult);
      end;
    ftCurr:
      begin
        if AValue.IsNan or AValue.IsInfinity or
           { The last doubles inside the range: the next one out, .625,
             overflows the scaled Int64, and on Win64 the literal
             922337203685477.5807 IS .625, so the bound has to be one a
             Double holds exactly. }
           (AValue < -922337203685477.5) or (AValue > 922337203685477.5) then
        begin
          AWhy := Format('%s is not a Currency: it is outside the range, or ' +
            'not a number', [TStructuralText.EncodeFloat(AValue)]);
          Exit;
        end;
        { Exactly: C := AValue multiplies by 10 000 in the FPU, which is a
          Double on Win64 and lost the last digits of any amount above about
          9e11 (922337203685477.5 became 922337203685477.4784). }
        C := ExactCurrencyFromDouble(AValue);
        TValue.Make(@C, ATypeInfo, AResult);
      end;
    ftComp:
      begin
        if AValue.IsNan or AValue.IsInfinity or (Frac(AValue) <> 0) or
           (AValue < -9223372036854775808.0) or (AValue >= 9223372036854775808.0) then
        begin
          AWhy := Format('%s is not a Comp, which is a 64-bit integer',
            [TStructuralText.EncodeFloat(AValue)]);
          Exit;
        end;
        Exit(TryIntegerFromInt64(ATypeInfo, Trunc(AValue), AResult));
      end;
  end;
  Result := True;
end;

class function TSerializationTypes.TryIntegerFromText(ATypeInfo: PTypeInfo;
  const AText: string; out AValue: TValue): Boolean;
var
  TD: PTypeData;
  I, Start: Integer;
  S, Bits: Int64;
  U: UInt64;
begin
  Result := False;
  AValue := TValue.Empty;
  if (ATypeInfo = nil) or (AText = '') then Exit;
  if not ((ATypeInfo.Kind in [tkInteger, tkInt64]) or IsCompType(ATypeInfo)) then
    Exit;
  Start := 1;
  if CharInSet(AText[1], ['+', '-']) then Start := 2;
  if Start > Length(AText) then Exit;
  for I := Start to Length(AText) do
    if not CharInSet(AText[I], ['0'..'9']) then Exit;

  TD := GetTypeData(ATypeInfo);
  if IsUnsignedInteger(ATypeInfo) then
  begin
    if AText[1] = '-' then
    begin
      { "-0" is zero. Anything else below zero is not this type. }
      for I := 2 to Length(AText) do
        if AText[I] <> '0' then Exit;
      U := 0;
    end
    else if not TryStrToUInt64(Copy(AText, Start, MaxInt), U) then Exit;
    if ATypeInfo.Kind = tkInteger then
    begin
      if (U < Cardinal(TD.MinValue)) or (U > Cardinal(TD.MaxValue)) then Exit;
    end
    else if (U < UInt64(TD.MinInt64Value)) or
            (U > UInt64(TD.MaxInt64Value)) then Exit;
    Bits := Int64(U);
  end
  else
  begin
    if not TryStrToInt64(AText, S) then Exit;
    case ATypeInfo.Kind of
      tkInteger:
        if (S < TD.MinValue) or (S > TD.MaxValue) then Exit;
      tkInt64:
        if (S < TD.MinInt64Value) or (S > TD.MaxInt64Value) then Exit;
    end;
    Bits := S;
  end;
  { Little-endian: the low bytes of the Int64 are the value at every width. }
  TValue.Make(@Bits, ATypeInfo, AValue);
  Result := True;
end;

class function TSerializationTypes.TryStringFromText(ATypeInfo: PTypeInfo;
  const AText: string; out AValue: TValue; out AWhy: string): Boolean;
var
  CodePage: Word;
  Bytes: TBytes;
  A: RawByteString;
  W: WideString;
  SS: ShortString;
  AC: AnsiChar;
  WC: Char;

  { The text in that code page, and whether it survived the trip. }
  function Encode(ACodePage: Word): Boolean;
  var
    E: TEncoding;
    Owned: Boolean;
  begin
    Owned := False;
    if ACodePage = CP_UTF8 then E := TEncoding.UTF8
    else if ACodePage = DefaultSystemCodePage then E := TEncoding.ANSI
    else
    begin
      E := TEncoding.GetEncoding(ACodePage);
      Owned := True;
    end;
    try
      Bytes := E.GetBytes(AText);
      Result := E.GetString(Bytes) = AText;
    finally
      if Owned then E.Free;
    end;
    if not Result then
      AWhy := Format('"%s" has characters that code page %d cannot hold, ' +
        'and %s is text in that code page', [AText, ACodePage,
        UTF8ToString(ATypeInfo.Name)]);
  end;

begin
  Result := False;
  AWhy := '';
  AValue := TValue.Empty;
  if ATypeInfo = nil then Exit;
  case ATypeInfo.Kind of
    tkUString:
      TValue.Make(@AText, ATypeInfo, AValue);
    tkWString:
      begin
        W := AText;
        TValue.Make(@W, ATypeInfo, AValue);
      end;
    tkWChar:
      begin
        if Length(AText) > 1 then
        begin
          AWhy := Format('"%s" is %d characters, and %s holds one',
            [AText, Length(AText), UTF8ToString(ATypeInfo.Name)]);
          Exit;
        end;
        if AText = '' then WC := #0 else WC := AText[1];
        TValue.Make(@WC, ATypeInfo, AValue);
      end;
    tkLString:
      begin
        CodePage := GetTypeData(ATypeInfo).CodePage;
        if CodePage = $FFFF then CodePage := CP_UTF8
        else if CodePage = CP_ACP then CodePage := Word(DefaultSystemCodePage);
        if not Encode(CodePage) then Exit;
        SetLength(A, Length(Bytes));
        if Length(Bytes) > 0 then Move(Bytes[0], A[1], Length(Bytes));
        SetCodePage(A, CodePage, False);
        TValue.Make(@A, ATypeInfo, AValue);
      end;
    tkString:
      begin
        if not Encode(Word(DefaultSystemCodePage)) then Exit;
        if Length(Bytes) > GetTypeData(ATypeInfo).MaxLength then
        begin
          AWhy := Format('"%s" is %d bytes in code page %d, and %s holds %d',
            [AText, Length(Bytes), DefaultSystemCodePage,
             UTF8ToString(ATypeInfo.Name), GetTypeData(ATypeInfo).MaxLength]);
          Exit;
        end;
        SS[0] := AnsiChar(Length(Bytes));
        if Length(Bytes) > 0 then Move(Bytes[0], SS[1], Length(Bytes));
        TValue.Make(@SS, ATypeInfo, AValue);
      end;
    tkChar:
      begin
        if not Encode(Word(DefaultSystemCodePage)) then Exit;
        if Length(Bytes) > 1 then
        begin
          AWhy := Format('"%s" is %d bytes in code page %d, and %s holds one',
            [AText, Length(Bytes), DefaultSystemCodePage,
             UTF8ToString(ATypeInfo.Name)]);
          Exit;
        end;
        if Length(Bytes) = 0 then AC := #0 else AC := AnsiChar(Bytes[0]);
        TValue.Make(@AC, ATypeInfo, AValue);
      end;
  else
    AWhy := Format('%s is not a string or character type',
      [UTF8ToString(ATypeInfo.Name)]);
    Exit;
  end;
  Result := True;
end;

class function TSerializationTypes.SetElementType(
  ATypeInfo: PTypeInfo): PTypeInfo;
begin
  Result := nil;
  if (ATypeInfo = nil) or (ATypeInfo.Kind <> tkSet) then Exit;
  if GetTypeData(ATypeInfo).CompType = nil then Exit;
  Result := GetTypeData(ATypeInfo).CompType^;
end;

class function TSerializationTypes.SetOrdinals(ATypeInfo: PTypeInfo;
  const AValue: TValue): TArray<Integer>;
var
  Elem: PTypeInfo;
  Base, Size, Bit, Count: Integer;
  P: PByte;
begin
  Result := nil;
  Elem := SetElementType(ATypeInfo);
  if (Elem = nil) or AValue.IsEmpty then Exit;
  Base := (GetTypeData(Elem).MinValue div 8) * 8;
  Size := AValue.DataSize;
  P := AValue.GetReferenceToRawData;
  SetLength(Result, Size * 8);
  Count := 0;
  for Bit := 0 to Size * 8 - 1 do
    if (P[Bit shr 3] and (1 shl (Bit and 7))) <> 0 then
    begin
      Result[Count] := Base + Bit;
      Inc(Count);
    end;
  SetLength(Result, Count);
end;

class function TSerializationTypes.TryMakeSet(ATypeInfo: PTypeInfo;
  const AOrdinals: array of Integer; out AValue: TValue;
  out AWhy: string): Boolean;
var
  Elem: PTypeInfo;
  Base, Size, Bit, Ordinal: Integer;
  Buf: array[0..31] of Byte;
  RT: TRttiType;
  Ctx: TRttiContext;
begin
  Result := False;
  AWhy := '';
  AValue := TValue.Empty;
  Elem := SetElementType(ATypeInfo);
  if Elem = nil then
  begin
    AWhy := 'has no element type in its RTTI';
    Exit;
  end;
  Ctx := TRttiContext.Create;
  RT := Ctx.GetType(ATypeInfo);
  Size := RT.TypeSize;
  Base := (GetTypeData(Elem).MinValue div 8) * 8;
  FillChar(Buf, SizeOf(Buf), 0);
  for Ordinal in AOrdinals do
  begin
    if (Ordinal < GetTypeData(Elem).MinValue) or
       (Ordinal > GetTypeData(Elem).MaxValue) then
    begin
      AWhy := Format('%d is outside %s, which runs from %d to %d',
        [Ordinal, UTF8ToString(Elem.Name), GetTypeData(Elem).MinValue,
         GetTypeData(Elem).MaxValue]);
      Exit;
    end;
    Bit := Ordinal - Base;
    if (Bit < 0) or ((Bit shr 3) >= Size) then
    begin
      AWhy := Format('%d has no bit in the %d-byte storage of %s',
        [Ordinal, Size, UTF8ToString(ATypeInfo.Name)]);
      Exit;
    end;
    Buf[Bit shr 3] := Byte(Buf[Bit shr 3] or (1 shl (Bit and 7)));
  end;
  TValue.Make(@Buf, ATypeInfo, AValue);
  Result := True;
end;

class function TSerializationTypes.SetElementText(AElemType: PTypeInfo;
  AOrdinal: Integer): string;
begin
  case AElemType.Kind of
    tkInteger, tkChar, tkWChar: Result := IntToStr(AOrdinal);
  else
    Result := GetEnumName(AElemType, AOrdinal);
  end;
end;

class function TSerializationTypes.MappedSetElementText(AElemType: PTypeInfo;
  AOrdinal: Integer; const AMapping: TArray<string>): string;
begin
  if (AMapping <> nil) and (AElemType <> nil) and
     (AElemType.Kind = tkEnumeration) and (AOrdinal >= 0) and
     (AOrdinal <= High(AMapping)) then
    Exit(AMapping[AOrdinal]);
  Result := SetElementText(AElemType, AOrdinal);
end;

class function TSerializationTypes.TryMappedSetElementOrdinal(
  AElemType: PTypeInfo; const AText: string; const AMapping: TArray<string>;
  out AOrdinal: Integer): Boolean;
var
  I: Integer;
begin
  if (AMapping <> nil) and (AElemType <> nil) and
     (AElemType.Kind = tkEnumeration) then
  begin
    for I := 0 to Integer(High(AMapping)) do
      if SameText(AMapping[I], Trim(AText)) then
      begin
        AOrdinal := I;
        Exit(True);
      end;
    AOrdinal := -1;
    Exit(False);
  end;
  Result := TrySetElementOrdinal(AElemType, AText, AOrdinal);
end;

class function TSerializationTypes.TrySetElementOrdinal(AElemType: PTypeInfo;
  const AText: string; out AOrdinal: Integer): Boolean;
var
  Value: Int64;
begin
  AOrdinal := -1;
  Value := -1;
  case AElemType.Kind of
    tkInteger, tkChar, tkWChar:
      Result := TryStrToInt64(AText, Value) and
        (Value >= GetTypeData(AElemType).MinValue) and
        (Value <= GetTypeData(AElemType).MaxValue);
    tkEnumeration:
      begin
        Value := GetEnumValue(AElemType, AText);
        Result := Value >= 0;
      end;
  else
    Result := False;
  end;
  if Result then AOrdinal := Integer(Value);
end;

class function TSerializationTypes.TryGetStaticArrayShape(
  ATypeInfo: PTypeInfo; out AElementType: PTypeInfo;
  out ACount, AElementSize: Integer): Boolean;
var
  TD: PTypeData;
begin
  Result := False;
  AElementType := nil;
  ACount := 0;
  AElementSize := 0;
  if (ATypeInfo = nil) or (ATypeInfo.Kind <> tkArray) then Exit;
  TD := GetTypeData(ATypeInfo);
  if (TD.ArrayData.ElType = nil) or (TD.ArrayData.ElType^ = nil) then Exit;
  AElementType := TD.ArrayData.ElType^;
  ACount := TD.ArrayData.ElCount;
  if ACount > 0 then AElementSize := TD.ArrayData.Size div ACount;
  Result := True;
end;

class function TSerializationTypes.TryMakeArray(ATypeInfo: PTypeInfo;
  const AElements: array of TValue; out AValue: TValue;
  out AWhy: string): Boolean;
var
  I: NativeInt;
  Len: NativeInt;
begin
  Result := False;
  AWhy := '';
  TValue.Make(nil, ATypeInfo, AValue);
  case ATypeInfo.Kind of
    tkArray:
      if Length(AElements) <> AValue.GetArrayLength then
      begin
        AWhy := Format('%s holds exactly %d elements, and there are %d',
          [UTF8ToString(ATypeInfo.Name), AValue.GetArrayLength, Length(AElements)]);
        Exit;
      end;
    tkDynArray:
      begin
        Len := Length(AElements);
        DynArraySetLength(PPointer(AValue.GetReferenceToRawData)^, ATypeInfo,
          1, @Len);
      end;
  else
    AWhy := Format('%s is not an array', [UTF8ToString(ATypeInfo.Name)]);
    Exit;
  end;
  for I := 0 to High(AElements) do
    AValue.SetArrayElement(I, AElements[I]);
  Result := True;
end;

class function TSerializationTypes.UnsupportedReason(
  ATypeInfo: PTypeInfo): string;
var
  RT: TRttiType;
  F, G: TRttiField;
  Ctx: TRttiContext;
  FEnd, GEnd, Count, Size: Integer;
  Elem: PTypeInfo;
  Why: string;
  Cls: TClass;
begin
  Result := '';
  if ATypeInfo = nil then
    Exit('has no RTTI, so nothing about its contents can be known');

  case ATypeInfo.Kind of
    tkPointer:
      Exit('is a pointer - a memory address, which means nothing in another ' +
        'process or at another time');
    tkProcedure:
      Exit('is a procedural value - the address of code, not data');
    tkMethod:
      Exit('is a method pointer - the address of code and of an object, not ' +
        'data');
    tkClassRef:
      Exit('is a class reference, and reading a class name back into a ' +
        'constructor is not something this library does for a type it was ' +
        'not told about');
    tkInterface:
      Exit('is an interface - a reference to an implementation this library ' +
        'cannot see. An anonymous method is an interface too');
    tkUnknown:
      Exit('has a type kind this library does not recognise');
    { An array is as serializable as what it holds. TArray<Pointer> is a
      list of addresses, and a static array of a type with no RTTI cannot be
      described at all. }
    tkArray, tkDynArray:
      begin
        if ATypeInfo.Kind = tkArray then
        begin
          if not TryGetStaticArrayShape(ATypeInfo, Elem, Count, Size) then
            Exit('is a static array whose element type has no RTTI');
        end
        else
        begin
          if GetTypeData(ATypeInfo).DynArrElType = nil then
            Exit('is a dynamic array whose element type has no RTTI');
          Elem := GetTypeData(ATypeInfo).DynArrElType^;
        end;
        Why := UnsupportedReason(Elem);
        if Why <> '' then
          Exit(Format('holds %s elements, and %s %s',
            [UTF8ToString(Elem.Name), UTF8ToString(Elem.Name), Why]));
      end;
    tkSet:
      if SetElementType(ATypeInfo) = nil then
        Exit('is a set whose element type has no RTTI, so nothing says what ' +
          'its members are called');
    tkClass:
      begin
        Cls := GetTypeData(ATypeInfo).ClassType;
        if Cls.InheritsFrom(TStream) then
          Exit('is a stream: its value is bytes behind a position, which ' +
            'nothing on its public surface describes. Carry them in a TBytes ' +
            'member, or register a serializer that reads the stream');
        if Cls.InheritsFrom(TList) then
          Exit('is a TList, a list of untyped pointers - addresses, which ' +
            'mean nothing in another process. Use TList<T> of the real type');
        if Cls.InheritsFrom(TCollection) then
          Exit('is a TCollection, which makes its own items through its ' +
            'ItemClass - a choice a serializer must not make for it. Carry ' +
            'the items as a TObjectList<T>, or register a serializer');
      end;
    tkRecord, tkMRecord:
      begin
        { TGUID is a record in System, and its D4 is an inline array the RTL
          declares without RTTI. Every format here carries a GUID as the
          128-bit identifier it is - by type identity, never by walking its
          fields - so its layout is not the question and it is not refused
          for it. }
        if ATypeInfo = System.TypeInfo(TGUID) then Exit;
        Ctx := TRttiContext.Create;
        RT := Ctx.GetType(ATypeInfo);
        if RT = nil then Exit;
        for F in RT.GetFields do
        begin
          { A member RTTI cannot describe - Data.FmtBcd's TBcd.Fraction is
            the real case - makes the whole record opaque. Writing the rest
            of it would write a number without its digits. }
          if F.FieldType = nil then
            Exit(Format('holds %s, which has no RTTI, so the record cannot ' +
              'be written without losing it', [F.Name]));
          { A VARIANT record: two members sharing the same bytes. RTTI reports
            both and nothing says which one is meaningful, so writing both
            writes the same memory under two interpretations and reading it
            back lets whichever comes last win. }
          FEnd := F.Offset + F.FieldType.TypeSize;
          for G in RT.GetFields do
          begin
            if (G = F) or (G.FieldType = nil) then Continue;
            GEnd := G.Offset + G.FieldType.TypeSize;
            if (G.Offset < FEnd) and (F.Offset < GEnd) then
              Exit(Format('is a variant record: %s and %s share the same ' +
                'bytes, and nothing records which of them is meaningful',
                [F.Name, G.Name]));
          end;
        end;
      end;
  end;
end;

class function TSerializationTypes.ContainerKindOf(
  ATypeInfo: PTypeInfo): TContainerKind;
var
  L: TListAccess;
  D: TDictionaryAccess;
begin
  if TryGetDictionaryAccess(ATypeInfo, D) then Exit(TContainerKind.Dictionary);
  if TryGetListAccess(ATypeInfo, L) then Exit(TContainerKind.List);
  Result := TContainerKind.None;
end;

{ TListAccess }

function TListAccess.IsValid: Boolean;
begin
  Result := (ContainerType <> nil) and (AddMethod <> nil) and
            (ToArrayMethod <> nil) and (ElementType <> nil);
end;

function TListAccess.Elements(const AContainer: TValue): TValue;
begin
  Result := TValue.Empty;
  if (not AContainer.IsObject) or (AContainer.AsObject = nil) then Exit;
  Result := TSerializationTypes.ListElements(AContainer.AsObject, ToArrayMethod);
end;

class function TSerializationTypes.DefaultConstructor(
  AType: TRttiType): TRttiMethod;
var
  M: TRttiMethod;
  Declared: Boolean;
begin
  Result := nil;
  if AType = nil then Exit;
  { The most derived parameterless constructor below TObject. A class that
    declares constructors, and none of them parameterless - Exception,
    TComponent - has NO default constructor: TObject.Create would build one
    without running any of them, and a TComponent made that way is not a
    TComponent. Only a class that declares none at all is built by
    TObject.Create, because then that IS its constructor. }
  Declared := False;
  for M in AType.GetMethods do
    if M.IsConstructor and not SameText(M.Parent.Name, 'TObject') then
    begin
      if Length(M.GetParameters) = 0 then Exit(M);
      Declared := True;
    end;
  if Declared then Exit;
  for M in AType.GetMethods do
    if M.IsConstructor and (Length(M.GetParameters) = 0) then Exit(M);
end;

class function TSerializationTypes.ListElements(AContainer: TObject;
  AToArray: TRttiMethod): TValue;
var
  Lines: TStrings;
  I: Integer;
begin
  Result := TValue.Empty;
  if (AContainer = nil) or (AToArray = nil) then Exit;
  { A TStrings is carried as its lines, which is all a TStrings means to
    most code. Objects attached to those lines are not text and have no
    place in that shape, so a list that has any is refused rather than
    written without them. }
  if AContainer is TStrings then
  begin
    Lines := TStrings(AContainer);
    for I := 0 to Lines.Count - 1 do
      if Lines.Objects[I] <> nil then
        raise ESerializationUnsupported.CreateFmt(
          '%s holds an object against line %d ("%s"). A TStrings is ' +
          'carried as its lines, and the objects would be lost: carry them ' +
          'in a list of their own, or register a serializer for it.',
          [Lines.ClassName, I, Lines[I]]);
  end;
  Result := AToArray.Invoke(AContainer, []);
end;

function TListAccess.Count(const AContainer: TValue): Integer;
var
  Items: TValue;
begin
  Items := Elements(AContainer);
  if Items.IsEmpty then Exit(0);
  Result := Integer(Items.GetArrayLength);
end;

procedure TListAccess.Add(const AContainer, AItem: TValue);
begin
  AddMethod.Invoke(AContainer.AsObject, [AItem]);
end;

procedure TListAccess.Clear(const AContainer: TValue);
begin
  if (ClearMethod = nil) or (not AContainer.IsObject) or
     (AContainer.AsObject = nil) then Exit;
  ClearMethod.Invoke(AContainer.AsObject, []);
end;

function TListAccess.CreateInstance: TObject;
begin
  Result := nil;
  if CreateMethod = nil then Exit;
  Result := CreateMethod.Invoke(
    TRttiInstanceType(GCtx.GetType(ContainerType)).MetaclassType,
    []).AsObject;
end;

{ TDictionaryAccess }

function TDictionaryAccess.IsValid: Boolean;
begin
  Result := (ContainerType <> nil) and (AddOrSetMethod <> nil) and
            (ToArrayMethod <> nil) and (KeyType <> nil) and
            (ValueType <> nil) and (PairKeyField <> nil) and
            (PairValueField <> nil);
end;

function TDictionaryAccess.Pairs(const AContainer: TValue): TValue;
begin
  Result := TValue.Empty;
  if (not AContainer.IsObject) or (AContainer.AsObject = nil) then Exit;
  Result := ToArrayMethod.Invoke(AContainer.AsObject, []);
end;

function TDictionaryAccess.Count(const AContainer: TValue): Integer;
var
  Items: TValue;
begin
  Items := Pairs(AContainer);
  if Items.IsEmpty then Exit(0);
  Result := Integer(Items.GetArrayLength);
end;

function TDictionaryAccess.KeyOf(const APair: TValue): TValue;
begin
  { GetReferenceToRawData on a LOCAL, never on a function result: the
    temporary a function returns has already gone on one of the two
    platforms, which is the kind of defect that passes Win32 and fails
    Win64. Callers pass a local, and this takes it by const. }
  Result := PairKeyField.GetValue(APair.GetReferenceToRawData);
end;

function TDictionaryAccess.ValueOf(const APair: TValue): TValue;
begin
  Result := PairValueField.GetValue(APair.GetReferenceToRawData);
end;

procedure TDictionaryAccess.AddOrSet(const AContainer, AKey, AValue: TValue);
begin
  AddOrSetMethod.Invoke(AContainer.AsObject, [AKey, AValue]);
end;

procedure TDictionaryAccess.Clear(const AContainer: TValue);
begin
  if (ClearMethod = nil) or (not AContainer.IsObject) or
     (AContainer.AsObject = nil) then Exit;
  ClearMethod.Invoke(AContainer.AsObject, []);
end;

function TDictionaryAccess.CreateInstance: TObject;
begin
  Result := nil;
  if CreateMethod = nil then Exit;
  Result := CreateMethod.Invoke(
    TRttiInstanceType(GCtx.GetType(ContainerType)).MetaclassType,
    []).AsObject;
end;

initialization
  GHoldsObjects := TDictionary<PTypeInfo, Boolean>.Create;
  GHoldsObjectsLock := TCriticalSection.Create;
  GCtx := TRttiContext.Create;
  GUnitNames := TDictionary<PTypeInfo, string>.Create;
  GUnitNamesLock := TCriticalSection.Create;
  GNullableFamilies := TList<TNullableFamily>.Create;
  GNullableAccessCache := TDictionary<PTypeInfo, TNullableAccess>.Create;
  GNullableLock := TCriticalSection.Create;
  TSerializationTypes.RegisterNullableFamily<TNullable<Integer>>;

  GContainerLock := TCriticalSection.Create;
  GListCache := TDictionary<PTypeInfo, TListAccess>.Create;
  GDictCache := TDictionary<PTypeInfo, TDictionaryAccess>.Create;
  { The RTL families, which is every container the library recognised before
    this registry existed. TObjectList<T> is a TList<T> and
    TObjectDictionary<K,V> is a TDictionary<K,V>, so the owning variants are
    reached through ancestry and are named only to record that they own. }
  TSerializationTypes.RegisterListFamily('TList<', False);
  TSerializationTypes.RegisterListFamily('TObjectList<', True);
  { Order is the family's own: a queue's elements come out front first and
    go back in by Enqueue in that order; a stack's come out bottom first and
    go back by Push, so the top is still the top. }
  TSerializationTypes.RegisterListFamily('TQueue<', False, 'Enqueue');
  TSerializationTypes.RegisterListFamily('TObjectQueue<', True, 'Enqueue');
  TSerializationTypes.RegisterListFamily('TStack<', False, 'Push');
  TSerializationTypes.RegisterListFamily('TObjectStack<', True, 'Push');
  { A TStrings is its lines. Names and values are read out of those lines
    by TStrings itself, so carrying the lines carries them too; Objects are
    another matter - see TListAccess.Elements. }
  TSerializationTypes.RegisterListFamily('TStrings', False, 'Add',
    'ToStringArray');
  TSerializationTypes.RegisterDictionaryFamily('TDictionary<', False);
  TSerializationTypes.RegisterDictionaryFamily('TObjectDictionary<', True);

finalization
  GHoldsObjects.Free;
  GHoldsObjectsLock.Free;
  GDictCache.Free;
  GListCache.Free;
  GContainerLock.Free;
  GNullableLock.Free;
  GNullableAccessCache.Free;
  GNullableFamilies.Free;
  GUnitNamesLock.Free;
  GUnitNames.Free;
  GCtx.Free;


end.
