{*******************************************************************************
  PascalForge.Serialization

  Public format-neutral facade for PascalForge.Serialization.

  Responsibilities
    - TSerialization: serialize, deserialize and convert with the format
      chosen at run time.
    - Registry queries: which formats are registered, what they support.

  Registration
    Every call is forwarded to a registered format handler. Formats must be
    registered explicitly at startup with
    T<Format>SerializationRegistration.RegisterFormat, or all at once with
    TSerializationFormatsRegistration.RegisterAll
    (PascalForge.Serialization.AllFormats). Linking a unit registers nothing.

  Threading
    Registration belongs to application startup; calls are safe for
    concurrent use once the formats in use are registered and configured.

  Documentation
    docs/architecture.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Serialization;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  The general, format-neutral facade.

  Most code should NOT use this unit. When you know the format at compile
  time, say so:

      Json := TJsonSerializer.Serialize<TShipment>(Shipment);
      Xml  := TXmlSerializer.Serialize<TShipment>(Shipment);
      Bson := TBsonSerializer.Serialize<TShipment>(Shipment);

  Those return a string, a string and TBytes respectively - the natural Delphi
  type for each - and they go straight to their own engine.

  This unit is for the case where the format is a run-time choice: a content
  negotiation header, a configuration value, a conversion between two formats
  a caller named. It holds no serialization logic of its own; every call is
  forwarded to a handler that the application registered explicitly at
  startup.

      uses
        PascalForge.Json.Registration,
        PascalForge.Xml.Registration;

      TJsonSerializationRegistration.RegisterFormat;
      TXmlSerializationRegistration.RegisterFormat;

      Payload := TSerialization.Serialize<TShipment>(Shipment, TSerializationFormat.Xml);

  A format listed in TSerializationFormat but never registered raises
  ESerializationFormatNotRegistered, naming the registration call to make.
  It never silently falls back to another format.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  PascalForge.Serialization.Core, PascalForge.Dynamic;

type
  { Re-exported so a caller of this unit does not also have to name Core. }
  TSerializationFormat = PascalForge.Serialization.Core.TSerializationFormat;
  TSerializationPayload = PascalForge.Serialization.Core.TSerializationPayload;
  TSerializationPayloadKind = PascalForge.Serialization.Core.TSerializationPayloadKind;
  ESerializationFormatNotRegistered = PascalForge.Serialization.Core.ESerializationFormatNotRegistered;
  ESerializationFormatCapability = PascalForge.Serialization.Core.ESerializationFormatCapability;
  TSerializationFormatCapability = PascalForge.Serialization.Core.TSerializationFormatCapability;
  TSerializationFormatCapabilities = PascalForge.Serialization.Core.TSerializationFormatCapabilities;
  TSerializationOwnership = PascalForge.Serialization.Core.TSerializationOwnership;

  TStructuralConversionProfile = PascalForge.Serialization.Core.TStructuralConversionProfile;
  TStructuralConversionOptions = PascalForge.Serialization.Core.TStructuralConversionOptions;
  TStructuralNamePolicy = PascalForge.Serialization.Core.TStructuralNamePolicy;
  TStructuralValuePolicy = PascalForge.Serialization.Core.TStructuralValuePolicy;
  TStructuralIssue = PascalForge.Serialization.Core.TStructuralIssue;
  EStructuralConversionError = PascalForge.Serialization.Core.EStructuralConversionError;

  TSerialization = class
  strict private
    { Generic methods may reference only interface declarations, so the work
      happens in these non-generic bridges. }
    class function DoSerialize(ATypeInfo: PTypeInfo; const AValue: TValue;
      AFormat: TSerializationFormat): TSerializationPayload; static;
    class function DoDeserialize(ATypeInfo: PTypeInfo;
      const APayload: TSerializationPayload; AFormat: TSerializationFormat): TValue; static;
  public
    { --- is a format available? -------------------------------------------
      Worth asking before offering it, rather than catching the exception. }
    class function IsRegistered(AFormat: TSerializationFormat): Boolean; static;
    class function RegisteredFormats: TArray<TSerializationFormat>; static;
    class function FormatName(AFormat: TSerializationFormat): string; static;

    { --- and can it do what you are about to ask? --------------------------

      Registration and capability are different questions. A format can be
      registered and still be unable to parse its own bytes into a structural
      tree - a schema-driven encoding cannot, without the schema - and code
      that offers structural conversion should ask rather than find out from
      an exception.

          if TSerialization.Supports(F, TSerializationFormatCapability.StructuralParse)
            then ...

      Asking for something a registered format cannot do raises
      ESerializationFormatCapability, which is deliberately NOT
      ESerializationFormatNotRegistered: the fix is not to add a unit. }
    class function Capabilities(
      AFormat: TSerializationFormat): TSerializationFormatCapabilities; static;
    class function Supports(AFormat: TSerializationFormat;
      ACapability: TSerializationFormatCapability): Boolean; static;
    { The registered formats that can be parsed structurally - the ones a
      generic "any format to a DataSet" or "any format to any format" path
      can actually use. }
    class function StructuralFormats: TArray<TSerializationFormat>; overload; static;
    { The registered formats that can go both ways through a Delphi
      contract. A schema-driven format is here and NOT in the list above:
      protobuf can serialize a TShipment perfectly well and cannot read a
      document it has no schema for. }
    class function ContractFormats: TArray<TSerializationFormat>; static;

    { --- serialize and deserialize with the format chosen at run time -----

      Serialize BORROWS AValue: it is yours before the call and yours after
      it. Deserialize TRANSFERS what it built: when T is a class, or an array
      of them, freeing it is the caller's job - exactly as it is with
      TJsonSerializer.Deserialize<T>. }
    class function Serialize<T>(const AValue: T;
      AFormat: TSerializationFormat): TSerializationPayload; static;
    class function Deserialize<T>(const APayload: TSerializationPayload;
      AFormat: TSerializationFormat): T; static;

    { --- conversion -------------------------------------------------------

      CONTRACT-AWARE is the form to prefer. The Delphi type is the contract,
      so each side applies its OWN attributes and registrations: a member can
      be 'shipmentId' in JSON and 'ShipmentID' as an XML attribute, and the
      conversion respects both.

          Xml := TSerialization.Convert<TShipment>(Json, TSerializationFormat.Json, TSerializationFormat.Xml);

      The intermediate T never escapes: it is built, written out, and released
      inside the call, including when the write raises. Nothing is returned
      for the caller to free. }
    class function Convert<T>(const ASource: TSerializationPayload;
      AFrom, ATo: TSerializationFormat): TSerializationPayload; overload; static;

    { STRUCTURAL, for a document whose contract you do not have. It carries
      only what every format can represent - object, array, string, integer,
      float, boolean, null, and binary where the format has it.

      It cannot carry what one format has and another does not: XML
      attributes as distinct from elements, namespaces, mixed content,
      element ordering. Converting XML this way loses them. See
      docs\conversion.md. }
    class function Convert(const ASource: TSerializationPayload;
      AFrom, ATo: TSerializationFormat): TSerializationPayload; overload; static;

    { The same, with the profile said out loud.

        Natural   idiomatic output. Names the destination cannot spell are
                  encoded reversibly; values it has no type for become its
                  own conventional text - base64 for binary, ISO-8601 for a
                  timestamp. This is what the two-argument form above does.

        Lossless  the published standard for the pair - MongoDB Extended
                  JSON, the W3C JSON/XML mapping - so that reading the
                  result back reproduces the source structural tree, or a
                  refusal where no standard covers a value. No private
                  metadata is ever written.

        Strict    refuse anything the destination cannot represent
                  directly. Every refusal carries the source format, the
                  destination format, the member path and the reason. For
                  compatibility testing rather than for production. }
    class function Convert(const ASource: TSerializationPayload;
      AFrom, ATo: TSerializationFormat;
      AProfile: TStructuralConversionProfile): TSerializationPayload; overload; static;

    { And with the two policies set separately, for a caller who wants
      reversible names but a hard error on an unrepresentable value, or the
      other way round. }
    class function Convert(const ASource: TSerializationPayload;
      AFrom, ATo: TSerializationFormat;
      const AOptions: TStructuralConversionOptions): TSerializationPayload; overload; static;

    { ----------------------------------------------------------------------
      WHEN ONE END NEEDS A SCHEMA

      A Protobuf message is (field number, wire type, payload); an Avro datum
      is a sequence of values with no names at all; an ASN.1 encoding is tags
      and lengths. None of them says what its own contents ARE, so there is
      nothing to read them as without the schema that travelled separately.

          Schema  := TProtobufSchema.LoadDescriptorSet(DescriptorBytes);
          Payload := TSerialization.Convert(Bytes,
                       TSerializationFormat.Protobuf,
                       TSerializationFormat.Json,
                       TStructuralConversionProfile.Natural, Schema);

      Pass two when both ends need one - Protobuf to Avro, or Avro schema A
      to Avro schema B - and each goes to the END it belongs to. With one,
      the format on the context says which end it is for; when BOTH ends are
      that format, that is ambiguous and the call raises telling the caller
      to name the roles - which is done by building the options directly
      with WithSourceContext and WithDestinationContext and calling the
      overload that takes them. The context is BORROWED: it is expensive to
      build and meant to be reused, so nothing here frees one.

      Without it, the conversion raises rather than guessing: a tree of
      plausible field names invented from field numbers is worse than an
      error, because it looks like an answer. }
    class function Convert(const ASource: TSerializationPayload;
      AFrom, ATo: TSerializationFormat;
      AProfile: TStructuralConversionProfile;
      AContext: TSerializationContext;
      ASecondContext: TSerializationContext = nil): TSerializationPayload; overload; static;

    { --- standards-based routing ------------------------------------------

      Some Lossless pairs have no published representation of their own and a
      standards-based ROUTE instead:

          BSON -> MongoDB Extended JSON -> JSON -> W3C JSON/XML -> XML

      Convert composes that rather than making the caller run both halves by
      hand. Only under Lossless, and only for the pairs in an explicit table:
      there is no path search here, so the route for a given pair is the same
      every time and can be read out of the source.

      RouteFor says what a conversion WOULD do without doing it, and the
      Convert overload below reports what it DID. A caller who asked for
      Lossless is entitled to know which standards their data went through,
      because that is the whole basis of the guarantee. }
    { ----------------------------------------------------------------------
      DYNAMIC, WITH THE FORMAT CHOSEN AT RUN TIME

      A payload of any registered format as a dynamic value, and a dynamic
      value as a payload. Dynamic is not a TSerializationFormat: it is the
      value every format reads into and writes from, so these are the two
      halves of a structural Convert with the tree handed to the caller in
      between - to inspect, change or build, then write in any format.

      The format must be registered and structurally capable; a
      schema-driven one (Protobuf, Avro, ASN.1) needs its schema, as a
      context or in the options, and raises ESerializationSchemaRequired
      without it. The returned tree is the caller's; the value passed to
      FromDynamic stays the caller's. }
    class function ToDynamic(const APayload: TSerializationPayload;
      AFormat: TSerializationFormat): TDynamicValue; overload; static;
    class function ToDynamic(const APayload: TSerializationPayload;
      AFormat: TSerializationFormat;
      AContext: TSerializationContext): TDynamicValue; overload; static;
    class function ToDynamic(const APayload: TSerializationPayload;
      AFormat: TSerializationFormat;
      const AOptions: TStructuralConversionOptions): TDynamicValue; overload; static;
    class function FromDynamic(AValue: TDynamicValue;
      AFormat: TSerializationFormat): TSerializationPayload; overload; static;
    class function FromDynamic(AValue: TDynamicValue;
      AFormat: TSerializationFormat;
      AContext: TSerializationContext): TSerializationPayload; overload; static;
    class function FromDynamic(AValue: TDynamicValue;
      AFormat: TSerializationFormat;
      const AOptions: TStructuralConversionOptions): TSerializationPayload; overload; static;

    class function RouteFor(AFrom, ATo: TSerializationFormat;
      AProfile: TStructuralConversionProfile): TStructuralRoute; static;

    class function Convert(const ASource: TSerializationPayload;
      AFrom, ATo: TSerializationFormat;
      AProfile: TStructuralConversionProfile;
      out ARoute: TStructuralRoute): TSerializationPayload; overload; static;


    { Which formats can be read and written structurally GIVEN what the
      caller has. StructuralFormats above answers for a caller with nothing;
      this answers for a caller holding these schemas, so a schema-driven
      format appears in the second list and not the first. }
    class function StructuralFormats(
      const AOptions: TStructuralConversionOptions): TArray<TSerializationFormat>; overload; static;

    { What a format needs before it can be converted structurally, in one
      word, for a user interface or a report: 'yes', 'schema' or 'no'. }
    class function StructuralRequirement(
      AFormat: TSerializationFormat): string; static;
  end;

implementation

{ ------------------------------------------------------------- bridges --- }

class function TSerialization.DoSerialize(ATypeInfo: PTypeInfo;
  const AValue: TValue; AFormat: TSerializationFormat): TSerializationPayload;
begin
  Result := TSerializationFormats.Require(AFormat,
    TSerializationFormatCapability.ContractSerialize).SerializeTyped(
    ATypeInfo, AValue);
end;

class function TSerialization.DoDeserialize(ATypeInfo: PTypeInfo;
  const APayload: TSerializationPayload; AFormat: TSerializationFormat): TValue;
begin
  Result := TSerializationFormats.Require(AFormat,
    TSerializationFormatCapability.ContractDeserialize).DeserializeTyped(
    ATypeInfo, APayload);
end;

{ ----------------------------------------------------------- availability --- }

class function TSerialization.IsRegistered(AFormat: TSerializationFormat): Boolean;
begin
  Result := TSerializationFormats.IsRegistered(AFormat);
end;

class function TSerialization.RegisteredFormats: TArray<TSerializationFormat>;
begin
  Result := TSerializationFormats.RegisteredFormats;
end;

class function TSerialization.FormatName(AFormat: TSerializationFormat): string;
begin
  Result := TSerializationFormats.FormatName(AFormat);
end;

{ ------------------------------------------------------------ operations --- }

class function TSerialization.Serialize<T>(const AValue: T;
  AFormat: TSerializationFormat): TSerializationPayload;
var
  V: TValue;
begin
  TValue.Make(@AValue, System.TypeInfo(T), V);
  Result := DoSerialize(System.TypeInfo(T), V, AFormat);
end;

class function TSerialization.Deserialize<T>(
  const APayload: TSerializationPayload; AFormat: TSerializationFormat): T;
begin
  Result := DoDeserialize(System.TypeInfo(T), APayload, AFormat).AsType<T>;
end;

class function TSerialization.Convert<T>(const ASource: TSerializationPayload;
  AFrom, ATo: TSerializationFormat): TSerializationPayload;
var
  V: TValue;
begin
  { The destination handler is resolved first, so an unregistered one fails
    before the source is parsed and before anything has been allocated. }
  TSerializationFormats.Get(ATo);
  { Through the Delphi value, so each side applies its own rules. }
  V := DoDeserialize(System.TypeInfo(T), ASource, AFrom);
  try
    Result := DoSerialize(System.TypeInfo(T), V, ATo);
  finally
    { The intermediate exists only for the length of this call. Whatever the
      source handler built - a T that is a class, or an array of them - is
      released here, on the way out and on the way out through an exception
      alike. Nothing else will ever see it, so nothing else can free it. }
    TSerializationOwnership.Release(System.TypeInfo(T), V);
  end;
end;

class function TSerialization.Capabilities(
  AFormat: TSerializationFormat): TSerializationFormatCapabilities;
begin
  Result := TSerializationFormats.Capabilities(AFormat);
end;

class function TSerialization.Supports(AFormat: TSerializationFormat;
  ACapability: TSerializationFormatCapability): Boolean;
begin
  Result := TSerializationFormats.Supports(AFormat, ACapability);
end;

class function TSerialization.StructuralFormats(
  const AOptions: TStructuralConversionOptions): TArray<TSerializationFormat>;
var
  F: TSerializationFormat;
  N: Integer;
begin
  SetLength(Result, Ord(High(TSerializationFormat)) -
    Ord(Low(TSerializationFormat)) + 1);
  N := 0;
  for F := Low(TSerializationFormat) to High(TSerializationFormat) do
    if TSerializationFormats.Supports(F,
         TSerializationFormatCapability.StructuralParse, AOptions) then
    begin
      Result[N] := F;
      Inc(N);
    end;
  SetLength(Result, N);
end;

class function TSerialization.StructuralRequirement(
  AFormat: TSerializationFormat): string;
var
  Caps: TSerializationFormatCapabilities;
begin
  if not TSerializationFormats.IsRegistered(AFormat) then Exit('not registered');
  Caps := TSerializationFormats.Capabilities(AFormat);
  if TSerializationFormatCapability.StructuralParse in Caps then Exit('yes');
  { Registered, contract-capable, and structurally silent: that is the
    shape of a format whose schema lives outside the document. Saying
    'schema' rather than 'no' is the difference between a wall and a door. }
  if TSerializationFormatCapability.ContractSerialize in Caps then Exit('schema');
  Result := 'no';
end;

class function TSerialization.Convert(const ASource: TSerializationPayload;
  AFrom, ATo: TSerializationFormat;
  AProfile: TStructuralConversionProfile;
  AContext: TSerializationContext;
  ASecondContext: TSerializationContext): TSerializationPayload;
var
  Options: TStructuralConversionOptions;
begin
  { The ends are set BEFORE the contexts, because WithContext places a
    context by asking which end has its format - and it cannot ask that
    until the ends are known. }
  Options := TStructuralConversionOptions.FromProfile(AProfile)
    .WithSource(AFrom).WithDestination(ATo);
  if AContext <> nil then Options := Options.WithContext(AContext);
  if ASecondContext <> nil then Options := Options.WithContext(ASecondContext);
  Result := Convert(ASource, AFrom, ATo, Options);
end;


class function TSerialization.StructuralFormats: TArray<TSerializationFormat>;
var
  F: TSerializationFormat;
  N: Integer;
begin
  SetLength(Result, Ord(High(TSerializationFormat)) -
    Ord(Low(TSerializationFormat)) + 1);
  N := 0;
  for F := Low(TSerializationFormat) to High(TSerializationFormat) do
    if TSerializationFormats.Supports(F,
         TSerializationFormatCapability.StructuralParse) then
    begin
      Result[N] := F;
      Inc(N);
    end;
  SetLength(Result, N);
end;

class function TSerialization.ContractFormats: TArray<TSerializationFormat>;
var
  F: TSerializationFormat;
  N: Integer;
begin
  SetLength(Result, Ord(High(TSerializationFormat)) -
    Ord(Low(TSerializationFormat)) + 1);
  N := 0;
  for F := Low(TSerializationFormat) to High(TSerializationFormat) do
    if TSerializationFormats.Supports(F,
         TSerializationFormatCapability.ContractSerialize) and
       TSerializationFormats.Supports(F,
         TSerializationFormatCapability.ContractDeserialize) then
    begin
      Result[N] := F;
      Inc(N);
    end;
  SetLength(Result, N);
end;

{ ===========================================================================
  THE TRUSTED STANDARD BRIDGES

  Two entries, and both are somebody else's specification. This is a TABLE
  and not a search: a resolver that looked for a path would one day find a
  surprising three-hop route through a format nobody expected, and a caller
  would have no way to predict what their data had been through.

  Adding a route means adding a row here and citing the standards it rests
  on. It does not mean teaching anything to find one.
  =========================================================================== }

const
  STANDARD_EXTENDED_JSON = 'MongoDB Extended JSON';
  STANDARD_W3C_JSON_XML  = 'W3C JSON/XML';

type
  TComposedRoute = record
    FromFormat: TSerializationFormat;
    ToFormat: TSerializationFormat;
    Hub: TSerializationFormat;
    FirstStandard: string;
    SecondStandard: string;
  end;

const
  { BSON and XML have no published representation of each other, and two
    published standards meet at JSON. Both directions, because a route that
    only worked one way would be a trap. }
  COMPOSED_ROUTES: array[0..1] of TComposedRoute = (
    (FromFormat: TSerializationFormat.Bson; ToFormat: TSerializationFormat.Xml;
     Hub: TSerializationFormat.Json;
     FirstStandard: STANDARD_EXTENDED_JSON;
     SecondStandard: STANDARD_W3C_JSON_XML),
    (FromFormat: TSerializationFormat.Xml; ToFormat: TSerializationFormat.Bson;
     Hub: TSerializationFormat.Json;
     FirstStandard: STANDARD_W3C_JSON_XML;
     SecondStandard: STANDARD_EXTENDED_JSON));

{ The standard a DIRECT pair rests on, or '' when it needs none. Naming these
  is what makes a one-hop route as inspectable as a composed one. }
function DirectStandard(AFrom, ATo: TSerializationFormat;
  AProfile: TStructuralConversionProfile): string;
begin
  Result := '';
  if AProfile <> TStructuralConversionProfile.Lossless then Exit;
  if ((AFrom = TSerializationFormat.Bson) and (ATo = TSerializationFormat.Json)) or
     ((AFrom = TSerializationFormat.Json) and (ATo = TSerializationFormat.Bson)) then
    Exit(STANDARD_EXTENDED_JSON);
  if ((AFrom = TSerializationFormat.Json) and (ATo = TSerializationFormat.Xml)) or
     ((AFrom = TSerializationFormat.Xml) and (ATo = TSerializationFormat.Json)) then
    Exit(STANDARD_W3C_JSON_XML);
end;

function FindComposedRoute(AFrom, ATo: TSerializationFormat;
  AProfile: TStructuralConversionProfile;
  out ARoute: TComposedRoute): Boolean;
var
  R: TComposedRoute;
begin
  Result := False;
  ARoute := Default(TComposedRoute);
  { ONLY under Lossless. Natural already converts these pairs directly and
    idiomatically, and routing one through a hub would change what it writes
    for no reason a caller asked for. }
  if AProfile <> TStructuralConversionProfile.Lossless then Exit;
  for R in COMPOSED_ROUTES do
    if (R.FromFormat = AFrom) and (R.ToFormat = ATo) then
    begin
      ARoute := R;
      Exit(True);
    end;
end;

class function TSerialization.RouteFor(AFrom, ATo: TSerializationFormat;
  AProfile: TStructuralConversionProfile): TStructuralRoute;
var
  Composed: TComposedRoute;
  A, B: TStructuralRouteStep;
begin
  if FindComposedRoute(AFrom, ATo, AProfile, Composed) then
  begin
    A.FromFormat := AFrom;
    A.ToFormat := Composed.Hub;
    A.Standard := Composed.FirstStandard;
    B.FromFormat := Composed.Hub;
    B.ToFormat := ATo;
    B.Standard := Composed.SecondStandard;
    Result.Steps := [A, B];
    Exit;
  end;
  Result := TStructuralRoute.Direct(AFrom, ATo,
    DirectStandard(AFrom, ATo, AProfile));
end;

class function TSerialization.Convert(const ASource: TSerializationPayload;
  AFrom, ATo: TSerializationFormat;
  AProfile: TStructuralConversionProfile;
  out ARoute: TStructuralRoute): TSerializationPayload;
var
  Composed: TComposedRoute;
  Options: TStructuralConversionOptions;
  Middle: TSerializationPayload;
begin
  ARoute := RouteFor(AFrom, ATo, AProfile);
  Options := TStructuralConversionOptions.FromProfile(AProfile);
  if FindComposedRoute(AFrom, ATo, AProfile, Composed) then
  begin
    { Each hop is an ordinary Lossless conversion resting on its own
      published standard, run in order. Nothing here knows anything about
      either standard: the two handlers do, and that is where it belongs. }
    Middle := Convert(ASource, AFrom, Composed.Hub, Options);
    Exit(Convert(Middle, Composed.Hub, ATo, Options));
  end;
  Result := Convert(ASource, AFrom, ATo, Options);
end;

class function TSerialization.Convert(const ASource: TSerializationPayload;
  AFrom, ATo: TSerializationFormat): TSerializationPayload;
begin
  Result := Convert(ASource, AFrom, ATo,
    TStructuralConversionProfile.Natural);
end;

class function TSerialization.Convert(const ASource: TSerializationPayload;
  AFrom, ATo: TSerializationFormat;
  AProfile: TStructuralConversionProfile): TSerializationPayload;
var
  Route: TStructuralRoute;
begin
  { Asking for a profile is asking for an OUTCOME, so this overload is
    allowed to compose a standards-based route to reach it. A caller who
    wants to know which route it took calls the overload that reports one;
    a caller who wants exactly one hop and nothing else builds the options
    themselves and calls the overload below, which is the primitive. }
  Result := Convert(ASource, AFrom, ATo, AProfile, Route);
end;

class function TSerialization.Convert(const ASource: TSerializationPayload;
  AFrom, ATo: TSerializationFormat;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
var
  Tree: TDynamicValue;
  Options: TStructuralConversionOptions;
begin
  { The destination handler knows its own format and the member path; only
    this call knows where the tree came from, so both ends go into the
    options - for the error message, and for the reader's decision about
    which layered standards it may recognize. }
  Options := AOptions.WithSource(AFrom).WithDestination(ATo).PlaceContexts;

  { Both handlers are resolved BEFORE any work, and each is checked for the
    capability it is about to be asked for, so a format that cannot do this
    fails before the source has been parsed - and says which of the two
    things went wrong.

    The check takes the OPTIONS, because capability is not a constant of the
    format: a schema-driven format answers yes to the structural pair when
    the caller supplied its schema and no when they did not, and the whole
    point of putting the schema in the options is that this question can see
    it. }
  TSerializationFormats.Require(ATo,
    TSerializationFormatCapability.StructuralWrite, Options);
  Tree := TSerializationFormats.Require(AFrom,
    TSerializationFormatCapability.StructuralParse, Options).ToDynamic(
      ASource, Options);
  try
    Result := TSerializationFormats.Get(ATo).FromDynamic(Tree, Options);
  finally
    Tree.Free;
  end;
end;


{ ---------------------------------------------------------------- dynamic --- }

class function TSerialization.ToDynamic(const APayload: TSerializationPayload;
  AFormat: TSerializationFormat): TDynamicValue;
begin
  Result := ToDynamic(APayload, AFormat, TStructuralConversionOptions.Default);
end;

class function TSerialization.ToDynamic(const APayload: TSerializationPayload;
  AFormat: TSerializationFormat; AContext: TSerializationContext): TDynamicValue;
var
  Options: TStructuralConversionOptions;
begin
  Options := TStructuralConversionOptions.Default.WithSource(AFormat);
  if AContext <> nil then Options := Options.WithContext(AContext);
  Result := ToDynamic(APayload, AFormat, Options);
end;

class function TSerialization.ToDynamic(const APayload: TSerializationPayload;
  AFormat: TSerializationFormat;
  const AOptions: TStructuralConversionOptions): TDynamicValue;
var
  Options: TStructuralConversionOptions;
begin
  { Reading: this format is the source. }
  Options := AOptions.WithSource(AFormat).PlaceContexts;
  Result := TSerializationFormats.Require(AFormat,
    TSerializationFormatCapability.StructuralParse, Options).ToDynamic(
      APayload, Options);
end;

class function TSerialization.FromDynamic(AValue: TDynamicValue;
  AFormat: TSerializationFormat): TSerializationPayload;
begin
  Result := FromDynamic(AValue, AFormat, TStructuralConversionOptions.Default);
end;

class function TSerialization.FromDynamic(AValue: TDynamicValue;
  AFormat: TSerializationFormat;
  AContext: TSerializationContext): TSerializationPayload;
var
  Options: TStructuralConversionOptions;
begin
  Options := TStructuralConversionOptions.Default.WithDestination(AFormat);
  if AContext <> nil then Options := Options.WithContext(AContext);
  Result := FromDynamic(AValue, AFormat, Options);
end;

class function TSerialization.FromDynamic(AValue: TDynamicValue;
  AFormat: TSerializationFormat;
  const AOptions: TStructuralConversionOptions): TSerializationPayload;
var
  Options: TStructuralConversionOptions;
begin
  if AValue = nil then
    raise EDynamicError.Create('There is no dynamic value to write.');
  { Writing: this format is the destination. }
  Options := AOptions.WithDestination(AFormat).PlaceContexts;
  Result := TSerializationFormats.Require(AFormat,
    TSerializationFormatCapability.StructuralWrite, Options).FromDynamic(
      AValue, Options);
end;
end.
