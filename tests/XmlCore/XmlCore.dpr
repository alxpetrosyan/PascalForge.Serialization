program XmlCore;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The XML engine, against its documented default contract.

  Everything here goes through TXmlSerializer, which goes straight to the XML
  engine. No format is registered in this program at all: using XML directly
  never needs the registry. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.DateUtils, System.StrUtils, System.TypInfo,
  System.Generics.Collections,
  XmlModels in 'XmlModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Xml in '..\..\src\PascalForge.Xml.pas',
  PascalForge.Xml.Internal in '..\..\src\PascalForge.Xml.Internal.pas';

var
  GFailures: Integer = 0;

procedure Check(ACondition: Boolean; const AName: string);
begin
  if ACondition then
    Writeln(AName, ': PASS')
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

function Has(const AXml, AFragment: string): Boolean;
begin
  Result := Pos(AFragment, AXml) > 0;
end;

{ Registrations must all happen before any type is used: a plan is cached the
  first time its type is serialized, and a later registration would be a
  silent no-op. }
procedure ConfigureContract;
begin
  TXmlSerializer.RegisterTypeSerializer<TCoordinate>(TCoordinateSerializer);
  TXmlSerializer.RegisterEnumMapping<TChannel>(['R', 'C', 'G']);
end;

{ The date policies come second, after ResetConfiguration, for a reason the
  reader should not have to guess: SetDateTimeFormat is GLOBAL, so running it
  before the default-contract checks would move every date in the program and
  those checks would be testing the configuration rather than the default.
  Two phases keep "what XML does with no configuration" and "what a policy
  changes" as two separate statements. }
procedure ConfigureDates;
begin
  { Weakest to strongest: global, then a type, then one field of that type.
    A member-level [XmlDateTimeFormat] beats all three and needs no
    registration at all. }
  TXmlSerializer.SetDateTimeFormat(TXmlDateTimeFormat.UnixSeconds);
  TXmlSerializer.RegisterDateTimeFormat<TClassDates>(
    TXmlDateTimeFormat.UnixMilliseconds);
  TXmlSerializer.RegisterDateTimeFormat<TFieldDates>(
    TXmlDateTimeFormat.UnixMilliseconds);
  TXmlSerializer.RegisterFieldDateTimeFormat<TFieldDates>('Stamp',
    TXmlDateTimeFormat.Xsd);
  TXmlSerializer.RegisterDateTimeFormat<TAttrDates>(
    TXmlDateTimeFormat.UnixMilliseconds);
end;

{ -------------------------------------------------------------- scalars --- }

procedure TestScalarRoot;
var
  Xml: string;
begin
  Writeln('-- a scalar at the root --');
  Xml := TXmlSerializer.Serialize<Integer>(42);
  Note(Xml);
  Check(Xml = '<Integer>42</Integer>', 'XML_SCALAR_ROOT');
  Check(TXmlSerializer.Deserialize<Integer>(Xml) = 42,
    'XML_SCALAR_ROOT_ROUNDTRIP');

  Xml := TXmlSerializer.Serialize<string>('a < b & c');
  Note(Xml);
  Check(Has(Xml, '&lt;') and Has(Xml, '&amp;') and
    (TXmlSerializer.Deserialize<string>(Xml) = 'a < b & c'),
    'XML_TEXT_IS_ESCAPED');
end;

{ ---------------------------------------------------------------- class --- }

function SampleShipment: TShipment;
begin
  Result := TShipment.Create;
  Result.Id := 4711;
  Result.Amount := 128.55;
  Result.Consignee := 'Alice Sample';
  Result.Kind := TContractKind.Forward;
  Result.Channels := [TChannel.Retail, TChannel.Government];
  Result.Reference := StringToGUID('{3F2504E0-4F89-11D3-9A0C-0305E82C3301}');
  Result.Booked := EncodeDate(2026, 3, 14);
  Result.Cutoff := EncodeTime(17, 30, 0, 0);
  Result.Created := EncodeDateTime(2026, 3, 14, 9, 26, 53, 0);
  Result.Note := 'urgent';
  Result.Rebate := nil;
  Result.Address := TAddress.Create;
  Result.Address.Street := 'One Example Loop';
  Result.Address.City := 'Cupertino';
  Result.Lines := TOrderLines.Create;
  Result.Lines.Add(TOrderLine.Create);
  Result.Lines[0].Sku := 'A-1';
  Result.Lines[0].Quantity := 2;
  Result.Lines.Add(TOrderLine.Create);
  Result.Lines[1].Sku := 'B-2';
  Result.Lines[1].Quantity := 5;
end;

procedure TestClassRoundtrip;
var
  P, Back: TShipment;
  Xml: string;
begin
  Writeln('-- a class --');
  P := SampleShipment;
  try
    Xml := TXmlSerializer.Serialize<TShipment>(P);
  finally
    P.Free;
  end;
  Note(Xml);

  { The root element is the class name without Delphi's leading T. }
  Check(Xml.StartsWith('<Shipment>'), 'XML_ROOT_ELEMENT_NAME');
  { A member is an element named exactly as the Delphi member is - XML's
    convention is PascalCase, and unlike JSON nothing is lower-cased. }
  Check(Has(Xml, '<Consignee>Alice Sample</Consignee>'), 'XML_MEMBER_ELEMENT_NAME');
  Check(Has(Xml, '<Kind>Forward</Kind>'), 'XML_ENUM');
  { Space separated, which is what xs:list does. JSON joins with commas. }
  Check(Has(Xml, '<Channels>R G</Channels>'), 'XML_SET');
  Check(Has(Xml, '<Reference>3f2504e0-4f89-11d3-9a0c-0305e82c3301</Reference>'),
    'XML_GUID');
  Check(Has(Xml, '<Booked>2026-03-14</Booked>') and
        Has(Xml, '<Cutoff>17:30:00</Cutoff>'), 'XML_XSD_DATE_AND_TIME');
  Check(Has(Xml, '<Note>urgent</Note>'), 'XML_NULLABLE');
  { An empty nullable is absent; XML has no null and one is not invented. }
  Check(not Has(Xml, '<Rebate'), 'XML_EMPTY_NULLABLE_IS_OMITTED');
  Check(Has(Xml, '<Address><Street>One Example Loop</Street>'),
    'XML_NESTED_OBJECT');
  Check(Has(Xml, '<Lines><OrderLine><Sku>A-1</Sku>'), 'XML_LIST');

  Back := TXmlSerializer.Deserialize<TShipment>(Xml);
  try
    Check((Back.Id = 4711) and (Back.Amount = 128.55) and
          (Back.Consignee = 'Alice Sample') and
          (Back.Kind = TContractKind.Forward) and
          (Back.Channels = [TChannel.Retail, TChannel.Government]) and
          (Back.Booked = EncodeDate(2026, 3, 14)) and
          SameTime(Back.Cutoff, EncodeTime(17, 30, 0, 0)) and
          Back.Note.HasValue and (Back.Note.Value = 'urgent') and
          (not Back.Rebate.HasValue) and
          (Back.Address <> nil) and (Back.Address.City = 'Cupertino') and
          (Back.Lines <> nil) and (Back.Lines.Count = 2) and
          (Back.Lines[1].Sku = 'B-2') and (Back.Lines[1].Quantity = 5),
      'XML_CLASS_ROUNDTRIP');
  finally
    Back.Free;
  end;
end;

{ --------------------------------------------------------------- record --- }

procedure TestRecordRoundtrip;
var
  Q, Back: TQuote;
  Xml: string;
begin
  Writeln('-- a record member --');
  Q := TQuote.Create;
  try
    Q.Symbol := 'EURUSD';
    Q.Bid.Amount := 1.0845;
    Q.Bid.Currency := 'USD';
    Xml := TXmlSerializer.Serialize<TQuote>(Q);
  finally
    Q.Free;
  end;
  Note(Xml);
  Back := TXmlSerializer.Deserialize<TQuote>(Xml);
  try
    Check((Back.Symbol = 'EURUSD') and (Back.Bid.Amount = 1.0845) and
          (Back.Bid.Currency = 'USD'), 'XML_RECORD_ROUNDTRIP');
  finally
    Back.Free;
  end;
end;

{ ---------------------------------------------------------- placement --- }

procedure TestPlacement;
var
  T, Back: TTicket;
  Xml: string;
begin
  Writeln('-- attributes, text, ignore, rename --');
  T := TTicket.Create;
  try
    T.Id := 90210;
    T.Priority := TContractKind.Swap;
    T.Title := 'Disk full';
    T.InternalScore := 7;
    T.Body := 'The volume is at 99%.';
    Xml := TXmlSerializer.Serialize<TTicket>(T);
  finally
    T.Free;
  end;
  Note(Xml);

  Check(Has(Xml, 'id="90210"'), 'XML_ATTRIBUTE');
  Check(Has(Xml, 'Priority="Swap"'), 'XML_ATTRIBUTE_ENUM');
  Check(Has(Xml, '<Subject>Disk full</Subject>'), 'XML_RENAME');
  Check(not Has(Xml, 'InternalScore'), 'XML_IGNORE');
  Check(Has(Xml, '>The volume is at 99%.<'), 'XML_TEXT');

  Back := TXmlSerializer.Deserialize<TTicket>(Xml);
  try
    Check((Back.Id = 90210) and (Back.Priority = TContractKind.Swap) and
          (Back.Title = 'Disk full') and (Back.InternalScore = 0) and
          (Back.Body = 'The volume is at 99%.'), 'XML_PLACEMENT_ROUNDTRIP');
  finally
    Back.Free;
  end;
end;

{ --------------------------------------------------------- namespaces --- }

procedure TestNamespaces;
var
  E, Back: TEnvelope;
  Xml: string;
  Root, Child: TXmlElement;
begin
  Writeln('-- namespaces --');
  E := TEnvelope.Create;
  try
    E.Subject := 'hello';
    E.Payload := 'body';
    Xml := TXmlSerializer.Serialize<TEnvelope>(E);
  finally
    E.Free;
  end;
  Note(Xml);

  { The URI is what identifies a namespace. The prefix is a spelling, so the
    test asks the parsed document rather than matching tag text. }
  Root := TXmlEngine.ParseDocument(Xml);
  try
    Check((Root.Name = 'Envelope') and
          (Root.NamespaceUri = 'urn:pascalforge:demo:envelope'),
      'XML_NAMESPACE');
    Child := Root.FindChild('Subject', 'urn:pascalforge:demo:envelope');
    Check((Child <> nil) and (Child.Text = 'hello'),
      'XML_NAMESPACE_INHERITED_BY_MEMBERS');
    Child := Root.FindChild('Payload', 'urn:pascalforge:demo:payload');
    Check((Child <> nil) and (Child.Text = 'body'),
      'XML_NAMESPACE_PER_MEMBER');
    Check(Root.FindChild('Payload', 'urn:pascalforge:demo:envelope') = nil,
      'XML_NAMESPACE_IS_NOT_JUST_A_TAG_NAME');
  finally
    Root.Free;
  end;

  Back := TXmlSerializer.Deserialize<TEnvelope>(Xml);
  try
    Check((Back.Subject = 'hello') and (Back.Payload = 'body'),
      'XML_NAMESPACE_ROUNDTRIP');
  finally
    Back.Free;
  end;

  { The same document with different prefixes is the same document. }
  Back := TXmlSerializer.Deserialize<TEnvelope>(
    '<q:Envelope xmlns:q="urn:pascalforge:demo:envelope" ' +
    'xmlns:p="urn:pascalforge:demo:payload">' +
    '<q:Subject>hello</q:Subject><p:Payload>body</p:Payload></q:Envelope>');
  try
    Check((Back.Subject = 'hello') and (Back.Payload = 'body'),
      'XML_NAMESPACE_PREFIX_IS_NOT_CONTRACTUAL');
  finally
    Back.Free;
  end;
end;

{ ------------------------------------------------------- collections --- }

procedure TestCollectionCustomization;
var
  B, Back: TBasket;
  Xml: string;
begin
  Writeln('-- collection customization --');
  B := TBasket.Create;
  try
    B.Lines.Add(TOrderLine.Create);
    B.Lines[0].Sku := 'X-9';
    B.Lines[0].Quantity := 3;
    B.Tags := ['red', 'blue'];
    Xml := TXmlSerializer.Serialize<TBasket>(B);
  finally
    B.Free;
  end;
  Note(Xml);

  Check(Has(Xml, '<Items><Line><Sku>X-9</Sku>'),
    'XML_COLLECTION_CUSTOMIZATION');
  { [XmlArray('')] means no wrapper: the items become repeated siblings. }
  Check(Has(Xml, '<Tag>red</Tag><Tag>blue</Tag>') and not Has(Xml, '<Tags>'),
    'XML_UNWRAPPED_COLLECTION');

  Back := TXmlSerializer.Deserialize<TBasket>(Xml);
  try
    Check((Back.Lines.Count = 1) and (Back.Lines[0].Sku = 'X-9') and
          (Length(Back.Tags) = 2) and (Back.Tags[1] = 'blue'),
      'XML_COLLECTION_CUSTOMIZATION_ROUNDTRIP');
  finally
    Back.Free;
  end;
end;

procedure TestDictionaryAndArray;
var
  R, Back: TRates;
  Xml: string;
  V: Currency;
begin
  Writeln('-- dictionary and array --');
  R := TRates.Create;
  try
    R.Rates.Add('USD', 1.0);
    R.Rates.Add('GBP', 0.79);
    R.Codes := [10, 20, 30];
    Xml := TXmlSerializer.Serialize<TRates>(R);
  finally
    R.Free;
  end;
  Note(Xml);
  Check(Has(Xml, '<Entry key="USD">1</Entry>') or
        Has(Xml, '<Entry key="GBP">0.79</Entry>'), 'XML_DICTIONARY');
  Check(Has(Xml, '<Codes><Item>10</Item>'), 'XML_ARRAY');

  Back := TXmlSerializer.Deserialize<TRates>(Xml);
  try
    Check((Back.Rates.Count = 2) and Back.Rates.TryGetValue('GBP', V) and
          (V = 0.79) and (Length(Back.Codes) = 3) and (Back.Codes[2] = 30),
      'XML_DICTIONARY_AND_ARRAY_ROUNDTRIP');
  finally
    Back.Free;
  end;
end;

{ ------------------------------------------------------------- reuse --- }

procedure TestReuse;
var
  R: TReusable;
  Address: TAddress;
  Lines: TOrderLines;
begin
  Writeln('-- reuse and detach --');
  R := TReusable.Create;
  try
    R.Address.City := 'Meadow';
    R.Lines.Add(TOrderLine.Create);
    R.Lines[0].Sku := 'OLD';
    Address := R.Address;
    Lines := R.Lines;

    TXmlSerializer.Populate<TReusable>(R,
      '<Reusable><Address><Street>Example Lane</Street></Address>' +
      '<Lines><OrderLine><Sku>NEW</Sku><Quantity>1</Quantity></OrderLine>' +
      '</Lines></Reusable>');

    { The same instance, populated in place - and a member the document did
      not mention keeps what it had. }
    Check((R.Address = Address) and (R.Address.Street = 'Example Lane') and
          (R.Address.City = 'Meadow'), 'XML_EXISTING_INSTANCE_REUSE');
    Check((R.Lines = Lines) and (R.Lines.Count = 1) and
          (R.Lines[0].Sku = 'NEW'), 'XML_CONTAINER_REUSE');
  finally
    R.Free;
  end;

  { xsi:nil detaches without destroying: the serializer cannot prove it owns
    what a member points at, so it never disposes of it. }
  R := TReusable.Create;
  Address := R.Address;
  try
    TXmlSerializer.Populate<TReusable>(R,
      '<Reusable xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
      '<Address xsi:nil="true"/></Reusable>');
    Check(R.Address = nil, 'XML_NULL_DETACHES');
    { Still alive, because nothing here was entitled to free it. }
    Address.City := 'still here';
    Check(Address.City = 'still here', 'XML_NULL_DOES_NOT_DESTROY');
  finally
    Address.Free;
    R.Free;
  end;
end;

{ ------------------------------------------------------------- dates --- }

procedure TestDatePolicies;
var
  G: TGlobalDates;
  C: TClassDates;
  F: TFieldDates;
  A: TAttrDates;
  Xml: string;
  Stamp: TDateTime;
  BackG: TGlobalDates;
begin
  Writeln('-- date policies --');
  Stamp := EncodeDateTime(2026, 3, 14, 9, 26, 53, 0);

  G := TGlobalDates.Create;
  try
    G.Stamp := Stamp;
    Xml := TXmlSerializer.Serialize<TGlobalDates>(G);
  finally
    G.Free;
  end;
  Note('global: ' + Xml);
  Check(Has(Xml, '<Stamp>' + IntToStr(DateTimeToUnix(Stamp, True)) + '</Stamp>'),
    'XML_DATE_GLOBAL_POLICY');

  BackG := TXmlSerializer.Deserialize<TGlobalDates>(Xml);
  try
    Check(SameDateTime(BackG.Stamp, Stamp), 'XML_DATE_ROUNDTRIP');
  finally
    BackG.Free;
  end;

  C := TClassDates.Create;
  try
    C.Stamp := Stamp;
    C.Other := Stamp;
    Xml := TXmlSerializer.Serialize<TClassDates>(C);
  finally
    C.Free;
  end;
  Note('class: ' + Xml);
  { A type registration beats the global default, for every date in it. }
  Check(Has(Xml, '<Stamp>' +
    IntToStr(DateTimeToUnix(Stamp, True) * 1000) + '</Stamp>'),
    'XML_DATE_CLASS_POLICY');

  F := TFieldDates.Create;
  try
    F.Stamp := Stamp;
    F.Other := Stamp;
    Xml := TXmlSerializer.Serialize<TFieldDates>(F);
  finally
    F.Free;
  end;
  Note('field: ' + Xml);
  Check(Has(Xml, '<Stamp>2026-03-14T09:26:53</Stamp>'),
    'XML_DATE_FIELD_POLICY');
  { The same class, the other member: the class registration still applies. }
  Check(Has(Xml, '<Other>' +
    IntToStr(DateTimeToUnix(Stamp, True) * 1000) + '</Other>'),
    'XML_DATE_POLICY_PRECEDENCE');

  A := TAttrDates.Create;
  try
    A.Stamp := Stamp;
    A.Other := Stamp;
    Xml := TXmlSerializer.Serialize<TAttrDates>(A);
  finally
    A.Free;
  end;
  Note('attribute: ' + Xml);
  Check(Has(Xml, '<Stamp>' + IntToStr(DateTimeToUnix(Stamp, True)) + '</Stamp>') and
        Has(Xml, '<Other>' +
          IntToStr(DateTimeToUnix(Stamp, True) * 1000) + '</Other>'),
    'XML_DATE_ATTRIBUTE_BEATS_REGISTRATION');
end;

{ -------------------------------------------------- custom serializer --- }

procedure TestCustomSerializer;
var
  P, Back: TPlace;
  Xml: string;
begin
  Writeln('-- a custom XML serializer --');
  P := TPlace.Create;
  try
    P.Name := 'Greenwich';
    P.Where.Latitude := 51.4779;
    P.Where.Longitude := -0.0015;
    Xml := TXmlSerializer.Serialize<TPlace>(P);
  finally
    P.Free;
  end;
  Note(Xml);
  Check(Has(Xml, '<Where lat="51.4779" lon="-0.0015"/>'),
    'XML_CUSTOM_SERIALIZER');

  Back := TXmlSerializer.Deserialize<TPlace>(Xml);
  try
    Check((Back.Name = 'Greenwich') and
          (Abs(Back.Where.Latitude - 51.4779) < 0.00001),
      'XML_CUSTOM_SERIALIZER_ROUNDTRIP');
  finally
    Back.Free;
  end;
end;

{ --------------------------------------------------------- plan cache --- }

procedure TestPlanCacheStable;
var
  Before, After: Integer;
  P: TShipment;
  I: Integer;
begin
  Writeln('-- the plan cache --');
  Before := TXmlEngine.PlanCount;
  for I := 1 to 50 do
  begin
    P := SampleShipment;
    try
      TXmlSerializer.Serialize<TShipment>(P);
    finally
      P.Free;
    end;
  end;
  After := TXmlEngine.PlanCount;
  Check(Before = After, 'XML_PLAN_CACHE_STABLE');
  Note(Format('plans before %d, after %d', [Before, After]));
end;

{ ---------------------------------------------------------- bad input --- }

procedure TestBadInput;

  function Raises(const AXml: string): Boolean;
  var
    P: TShipment;
  begin
    Result := False;
    P := nil;
    try
      P := TXmlSerializer.Deserialize<TShipment>(AXml);
    except
      on E: EXmlError do Result := True;
    end;
    P.Free;
  end;

begin
  Writeln('-- input that is not a document --');
  Check(Raises('<Shipment><Id>1</Id>'), 'XML_UNTERMINATED_RAISES');
  Check(Raises('<Shipment><Id>not a number</Id></Shipment>'),
    'XML_BAD_SCALAR_RAISES');
  { A DOCTYPE with an internal subset is read, because real documents have
    one. What is refused is the EXTERNAL entity - see tests\XmlNative for
    the full audit. }
  Check(not Raises('<!DOCTYPE p [<!ENTITY x "1">]><Shipment><Id>&x;</Id></Shipment>'),
    'XML_INTERNAL_SUBSET_ACCEPTED');
  Check(Raises('<!DOCTYPE p [<!ENTITY x SYSTEM "file:///etc/passwd">]>' +
               '<Shipment><Id>&x;</Id></Shipment>'),
    'XML_EXTERNAL_ENTITY_REFUSED');
end;

{ ------------------------------------------ release-review regressions --- }

{ Each check below pins the corrected behaviour of a defect the release
  review reproduced. }

{ True when AAction raises EXmlInputError. Anything else it raises is
  noted, and is a False rather than an exception that stops the program. }
function InputRefused(const AAction: TProc): Boolean;
begin
  Result := False;
  try
    AAction();
  except
    on E: Exception do
    begin
      Result := E is EXmlInputError;
      if not Result then Note(E.ClassName + ': ' + E.Message);
    end;
  end;
end;

{ InputRefused, and nothing the read built is left alive. }
function RefusedWithoutLeak(const AAction: TProc): Boolean;
var
  Before: Integer;
begin
  Before := TCounted.Live;
  Result := InputRefused(AAction);
  if TCounted.Live <> Before then
  begin
    Note(Format('%d TCounted left alive by the failed read',
      [TCounted.Live - Before]));
    Result := False;
    TCounted.Live := Before;
  end;
end;

function MomentRoundTrip(AValue: TDateTime; out AXml: string): TDateTime;
var
  M, Back: TMoment;
begin
  M := TMoment.Create;
  try
    M.At := AValue;
    AXml := TXmlSerializer.Serialize<TMoment>(M);
  finally
    M.Free;
  end;
  Back := TXmlSerializer.Deserialize<TMoment>(AXml);
  try
    Result := Back.At;
  finally
    Back.Free;
  end;
end;

function MomentMsRoundTrip(AValue: TDateTime; out AXml: string): TDateTime;
var
  M, Back: TMomentMs;
begin
  M := TMomentMs.Create;
  try
    M.At := AValue;
    AXml := TXmlSerializer.Serialize<TMomentMs>(M);
  finally
    M.Free;
  end;
  Back := TXmlSerializer.Deserialize<TMomentMs>(AXml);
  try
    Result := Back.At;
  finally
    Back.Free;
  end;
end;

function MomentSecRoundTrip(AValue: TDateTime; out AXml: string): TDateTime;
var
  M, Back: TMomentSec;
begin
  M := TMomentSec.Create;
  try
    M.At := AValue;
    AXml := TXmlSerializer.Serialize<TMomentSec>(M);
  finally
    M.Free;
  end;
  Back := TXmlSerializer.Deserialize<TMomentSec>(AXml);
  try
    Result := Back.At;
  finally
    Back.Free;
  end;
end;

{ True when writing AValue is refused with ESerializationUnsupported, in
  the form AForm names: 0 xs:dateTime, 1 Unix milliseconds, 2 Unix seconds,
  3 xs:date. }
function DateWriteRefused(AValue: TDateTime; AForm: Integer): Boolean;
var
  M: TMoment;
  Ms: TMomentMs;
  Sec: TMomentSec;
  Day: TDay;
begin
  Result := False;
  M := TMoment.Create;
  Ms := TMomentMs.Create;
  Sec := TMomentSec.Create;
  Day := TDay.Create;
  try
    M.At := AValue;
    Ms.At := AValue;
    Sec.At := AValue;
    Day.D := AValue;
    try
      case AForm of
        0: Note(TXmlSerializer.Serialize<TMoment>(M));
        1: Note(TXmlSerializer.Serialize<TMomentMs>(Ms));
        2: Note(TXmlSerializer.Serialize<TMomentSec>(Sec));
      else
        Note(TXmlSerializer.Serialize<TDay>(Day));
      end;
    except
      on E: Exception do
      begin
        Result := E is ESerializationUnsupported;
        if not Result then Note(E.ClassName + ': ' + E.Message);
      end;
    end;
  finally
    M.Free;
    Ms.Free;
    Sec.Free;
    Day.Free;
  end;
end;

{ Before 1899-12-30 a TDateTime is a negative day with a POSITIVE time of
  day. The reader added the time to the day, so 1800-01-01T12:00 came back
  on 1800-01-02, and the epoch writers put the instant a day early. A value
  outside the years 1 to 9999 was written - before year 1 as 0000-00-00 -
  and then refused by the reader. }
procedure TestDateRegressions;
var
  Stamps: TArray<TDateTime>;
  I: Integer;
  Same: Boolean;
  Xml: string;
  Back, Stamp: TDateTime;
begin
  Writeln('-- dates before 1899-12-30, and outside the years 1 to 9999 --');
  Stamps := [EncodeDateTime(1800, 1, 1, 12, 0, 0, 0),
    EncodeDateTime(1899, 12, 29, 6, 0, 0, 0),
    EncodeDateTime(1850, 6, 15, 12, 0, 0, 0),
    EncodeDateTime(1, 1, 1, 12, 30, 15, 250),
    EncodeDateTime(2026, 3, 14, 9, 26, 53, 0)];
  Same := True;
  for I := 0 to High(Stamps) do
  begin
    Back := MomentRoundTrip(Stamps[I], Xml);
    if not SameDateTime(Back, Stamps[I]) then
    begin
      Same := False;
      Note(Xml + ' came back ' +
        FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Back));
    end;
  end;
  Check(Same, 'XML_PRE_1899_DATETIME_ROUNDTRIP');

  Stamp := EncodeDateTime(1899, 12, 29, 6, 0, 0, 0);
  Back := MomentMsRoundTrip(Stamp, Xml);
  Note(Xml);
  Check(Has(Xml, '<At>-2209226400000</At>') and SameDateTime(Back, Stamp),
    'XML_PRE_1899_UNIX_MILLISECONDS');
  Back := MomentSecRoundTrip(Stamp, Xml);
  Check(Has(Xml, '<At>-2209226400</At>') and SameDateTime(Back, Stamp),
    'XML_PRE_1899_UNIX_SECONDS');
  { Half a second before the epoch is second -1: whole seconds round down. }
  MomentSecRoundTrip(EncodeDateTime(1969, 12, 31, 23, 59, 59, 500), Xml);
  Check(Has(Xml, '<At>-1</At>'), 'XML_UNIX_SECONDS_ROUND_DOWN');

  Check(DateWriteRefused(EncodeDate(1, 1, 1) - 1, 0) and
        DateWriteRefused(EncodeDate(9999, 12, 31) + 1, 0) and
        DateWriteRefused(EncodeDate(1, 1, 1) - 1, 1) and
        DateWriteRefused(EncodeDate(9999, 12, 31) + 1, 2) and
        DateWriteRefused(EncodeDate(1, 1, 1) - 1, 3),
    'XML_DATE_OUTSIDE_YEARS_1_TO_9999_REFUSED_ON_WRITE');
  { A count past the years 1 to 9999 is the input error, where it was an
    EIntOverflow or a wrong date. }
  Check(InputRefused(procedure
          begin
            TXmlSerializer.Deserialize<TMomentMs>(
              '<MomentMs><At>9223372036854775807</At></MomentMs>').Free;
          end) and
        InputRefused(procedure
          begin
            TXmlSerializer.Deserialize<TMomentSec>(
              '<MomentSec><At>9223372036854775807</At></MomentSec>').Free;
          end),
    'XML_UNIX_COUNT_OUT_OF_RANGE_REFUSED');
end;

function BitsOf(AValue: Double): UInt64;
begin
  Move(AValue, Result, SizeOf(Result));
end;

function DoubleOfBits(ABits: UInt64): Double;
begin
  Move(ABits, Result, SizeOf(Result));
end;

function ReadsAsBits(const AText: string; ABits: UInt64): Boolean;
var
  H: TDoubleHolder;
begin
  H := TXmlSerializer.Deserialize<TDoubleHolder>(
    '<DoubleHolder><D>' + AText + '</D></DoubleHolder>');
  try
    Result := BitsOf(H.D) = ABits;
    if not Result then
      Note(Format('%s read as %.16X', [AText, BitsOf(H.D)]));
  finally
    H.Free;
  end;
end;

{ On Win64 the RTL's text-to-double conversion is not correctly rounded,
  and about a third of doubles came back as a neighbour. }
procedure TestDoubleRegressions;
var
  H, Back: TDoubleHolder;
  Xml: string;
  I, Differ: Integer;
  R: UInt64;
  D: Double;
begin
  Writeln('-- doubles, correctly rounded on both platforms --');
  H := TDoubleHolder.Create;
  try
    H.D := DoubleOfBits($419D6F34547E6B75);
    Xml := TXmlSerializer.Serialize<TDoubleHolder>(H);
  finally
    H.Free;
  end;
  Note(Xml);
  Back := TXmlSerializer.Deserialize<TDoubleHolder>(Xml);
  try
    Check(BitsOf(Back.D) = $419D6F34547E6B75, 'XML_DOUBLE_17_DIGITS_ROUNDTRIP');
  finally
    Back.Free;
  end;
  Check(ReadsAsBits('123456789.12345679', $419D6F34547E6B75) and
        ReadsAsBits('1.7976931348623158E308', $7FEFFFFFFFFFFFFF) and
        ReadsAsBits('4.9E-324', $0000000000000001),
    'XML_DOUBLE_TEXT_CORRECTLY_ROUNDED');

  RandSeed := 20260930;
  Differ := 0;
  for I := 1 to 3000 do
  begin
    R := (UInt64(Random($7FFFFFFF)) shl 33) xor
      (UInt64(Random($7FFFFFFF)) shl 2) xor UInt64(Random(4));
    D := DoubleOfBits(R);
    if D.IsNan or D.IsInfinity then Continue;
    H := TDoubleHolder.Create;
    try
      H.D := D;
      Xml := TXmlSerializer.Serialize<TDoubleHolder>(H);
    finally
      H.Free;
    end;
    Back := TXmlSerializer.Deserialize<TDoubleHolder>(Xml);
    try
      if BitsOf(Back.D) <> R then Inc(Differ);
    finally
      Back.Free;
    end;
  end;
  Note(Format('%d of 3000 random doubles came back different', [Differ]));
  Check(Differ = 0, 'XML_RANDOM_DOUBLES_ROUNDTRIP');
end;

{ True when writing the holder is refused with EXmlError. }
function TextWriteRefused(const AText, AAttr: string; AChar: Char): Boolean;
var
  T: TTextHolder;
begin
  Result := False;
  T := TTextHolder.Create;
  try
    T.S := AText;
    T.A := AAttr;
    T.C := AChar;
    try
      TXmlSerializer.Serialize<TTextHolder>(T);
    except
      on E: Exception do
      begin
        Result := E is EXmlError;
        if not Result then Note(E.ClassName + ': ' + E.Message);
      end;
    end;
  finally
    T.Free;
  end;
end;

{ Half a surrogate pair is no character, and XML 1.0 excludes it: it was
  written raw into a document MSXML will not load. It is refused the way
  U+0000 is. }
procedure TestSurrogateRegressions;
var
  T, Back: TTextHolder;
  Pair, Xml: string;
  Raised: Boolean;
begin
  Writeln('-- unpaired surrogates --');
  Pair := Char($D83D) + Char($DE00);
  Check(TextWriteRefused('a' + Char($D800) + 'b', 'x', 'c') and
        TextWriteRefused('a' + Char($DC00) + 'b', 'x', 'c') and
        TextWriteRefused(Char($DE00) + Char($D83D), 'x', 'c') and
        TextWriteRefused('a' + Char($D83D), 'x', 'c'),
    'XML_UNPAIRED_SURROGATE_IN_TEXT_REFUSED');
  Check(TextWriteRefused('s', 'a' + Char($D800), 'c'),
    'XML_UNPAIRED_SURROGATE_IN_ATTRIBUTE_REFUSED');
  Check(TextWriteRefused('s', 'x', Char($D800)),
    'XML_UNPAIRED_SURROGATE_CHAR_REFUSED');

  T := TTextHolder.Create;
  try
    T.S := 'a' + Char($D800);
    T.A := 'x';
    T.C := 'c';
    Raised := False;
    try
      TXmlSerializer.SerializeUtf8<TTextHolder>(T);
    except
      on E: EXmlError do Raised := True;
    end;
    Check(Raised, 'XML_UNPAIRED_SURROGATE_REFUSED_IN_UTF8');

    T.S := 'a' + Pair + 'b';
    T.A := Pair;
    Xml := TXmlSerializer.Serialize<TTextHolder>(T);
  finally
    T.Free;
  end;
  Back := TXmlSerializer.Deserialize<TTextHolder>(Xml);
  try
    Check((Back.S = 'a' + Pair + 'b') and (Back.A = Pair),
      'XML_SURROGATE_PAIR_ROUNDTRIP');
  finally
    Back.Free;
  end;
end;

function ChainOf(ADepth: Integer): TChainNode;
var
  I: Integer;
  N: TChainNode;
begin
  Result := TChainNode.Create;
  N := Result;
  for I := 2 to ADepth do
  begin
    N.Child := TChainNode.Create;
    N := N.Child;
    N.Tag := I;
  end;
end;

function ChainDepth(ANode: TChainNode): Integer;
begin
  Result := 0;
  while ANode <> nil do
  begin
    Inc(Result);
    ANode := ANode.Child;
  end;
end;

{ True when writing a chain of ADepth objects is refused with
  ESerializationLimitExceeded. }
function ChainRefused(ADepth: Integer): Boolean;
var
  Root: TChainNode;
begin
  Result := False;
  Root := ChainOf(ADepth);
  try
    try
      TXmlSerializer.Serialize<TChainNode>(Root);
    except
      on E: Exception do
      begin
        Result := E is ESerializationLimitExceeded;
        if not Result then Note(E.ClassName + ': ' + E.Message);
      end;
    end;
  finally
    Root.Free;
  end;
end;

function RecChainOf(ADepth: Integer): TRecLink;
var
  I: Integer;
  Inner: TRecLink;
begin
  Result.Tag := ADepth;
  Result.Kids := nil;
  for I := ADepth - 1 downto 1 do
  begin
    Inner := Result;
    Result.Tag := I;
    SetLength(Result.Kids, 1);
    Result.Kids[0] := Inner;
  end;
end;

function RecChainDepth(const ALink: TRecLink): Integer;
var
  P: ^TRecLink;
begin
  Result := 1;
  P := @ALink;
  while Length(P^.Kids) > 0 do
  begin
    Inc(Result);
    P := @P^.Kids[0];
  end;
end;

{ Writes a holder of a record chain ADepth deep. True when it is refused
  with ESerializationLimitExceeded; otherwise AXml is what was written. }
function RecChainRefused(ADepth: Integer; out AXml: string): Boolean;
var
  H: TRecLinkHolder;
begin
  Result := False;
  AXml := '';
  H := TRecLinkHolder.Create;
  try
    H.R := RecChainOf(ADepth);
    try
      AXml := TXmlSerializer.Serialize<TRecLinkHolder>(H);
    except
      on E: Exception do
      begin
        Result := E is ESerializationLimitExceeded;
        if not Result then Note(E.ClassName + ': ' + E.Message);
      end;
    end;
  finally
    H.Free;
  end;
end;

{ Records and arrays did not count toward the 64 levels, so a record that
  nests through an array of itself was written at any depth - past what the
  reader accepts, and at a thousand or so, past the stack. Every object,
  record, array, list and dictionary counts one level now. }
procedure TestDepthRegressions;
var
  Root, Back: TChainNode;
  Holder: TRecLinkHolder;
  Xml: string;
begin
  Writeln('-- nesting: 64 levels, each composite counting one --');
  Root := ChainOf(64);
  try
    Xml := TXmlSerializer.Serialize<TChainNode>(Root);
  finally
    Root.Free;
  end;
  Back := TXmlSerializer.Deserialize<TChainNode>(Xml);
  try
    Check(ChainDepth(Back) = 64, 'XML_64_OBJECT_LEVELS_WRITTEN_AND_READ_BACK');
  finally
    Back.Free;
  end;
  Check(ChainRefused(65), 'XML_65_OBJECT_LEVELS_REFUSED');

  { The holder, then a record and its array per link: 1 + 31 * 2 = 63. }
  Check(not RecChainRefused(31, Xml), 'XML_RECORD_CHAIN_31_WRITTEN');
  Holder := TXmlSerializer.Deserialize<TRecLinkHolder>(Xml);
  try
    Check(RecChainDepth(Holder.R) = 31, 'XML_RECORD_CHAIN_31_READ_BACK');
  finally
    Holder.Free;
  end;
  Check(RecChainRefused(32, Xml) and RecChainRefused(1000, Xml),
    'XML_RECORD_CHAIN_PAST_64_LEVELS_REFUSED');
  Check(TSerializationGraphGuard.Level = 0, 'XML_DEPTH_GUARD_RESTORED');
end;

function NewCounted(AX: Integer): TCounted;
begin
  Result := TCounted.Create;
  Result.X := AX;
end;

{ True when populating AInstance from AXml is refused with EXmlInputError. }
function PopulateRefused(AInstance: TOwningContainers;
  const AXml: string): Boolean;
begin
  Result := False;
  try
    TXmlSerializer.Populate<TOwningContainers>(AInstance, AXml);
  except
    on E: Exception do
    begin
      Result := E is EXmlInputError;
      if not Result then Note(E.ClassName + ': ' + E.Message);
    end;
  end;
end;

{ A container element holding what is not an item of it is a document of
  another shape. It read as an EMPTY container, clearing the caller's own on
  the way and destroying what it owned. It is refused now, and the
  container is left exactly as it was. }
procedure TestWrongShapeRegressions;
var
  C: TOwningContainers;
  RootList: TObjectList<TCounted>;
  Live: Integer;
  Items: TObjectList<TCounted>;
  Refused: Boolean;

  function ItemsUntouched: Boolean;
  begin
    Result := (C.Items = Items) and (C.Items.Count = 2) and
      (C.Items[0].X = 7) and (C.Items[1].X = 8) and (TCounted.Live = Live);
  end;

  function MapUntouched: Boolean;
  begin
    Result := (C.Map.Count = 1) and C.Map.ContainsKey('k') and
      (C.Map['k'].X = 9) and (TCounted.Live = Live);
  end;

begin
  Writeln('-- a container element of another shape --');
  C := TOwningContainers.Create;
  try
    C.Items.Add(NewCounted(7));
    C.Items.Add(NewCounted(8));
    C.Map.Add('k', NewCounted(9));
    Items := C.Items;
    Live := TCounted.Live;

    Check(PopulateRefused(C,
      '<OwningContainers><Items><Entry key="a"><X>1</X></Entry></Items>' +
      '</OwningContainers>') and ItemsUntouched,
      'XML_MAP_WHERE_LIST_BELONGS_REFUSED');
    Check(PopulateRefused(C,
      '<OwningContainers><Items><Counted><X>1</X></Counted><Other/>' +
      '</Items></OwningContainers>') and ItemsUntouched,
      'XML_STRANGER_AMONG_ITEMS_REFUSED');
    Check(PopulateRefused(C,
      '<OwningContainers><Items>5</Items></OwningContainers>') and
      ItemsUntouched, 'XML_TEXT_WHERE_LIST_BELONGS_REFUSED');
    Check(PopulateRefused(C,
      '<OwningContainers><Map><Counted><X>1</X></Counted></Map>' +
      '</OwningContainers>') and MapUntouched,
      'XML_LIST_WHERE_MAP_BELONGS_REFUSED');
    Check(PopulateRefused(C,
      '<OwningContainers><Map><Entry key="a"><X>1</X></Entry>' +
      '<Entry><X>2</X></Entry></Map></OwningContainers>') and MapUntouched,
      'XML_ENTRY_WITHOUT_KEY_REFUSED_UNTOUCHED');
    { Every element is read before the container is cleared, so an item
      that does not fit is found out while the container is still whole -
      and the item read before it is freed. }
    Check(PopulateRefused(C,
      '<OwningContainers><Items><Counted><X>1</X></Counted>' +
      '<Counted><X>5000000000</X></Counted></Items></OwningContainers>') and
      ItemsUntouched, 'XML_ITEM_THAT_DOES_NOT_FIT_REFUSED_UNTOUCHED');

    { And a document of the right shape still refills in place. }
    TXmlSerializer.Populate<TOwningContainers>(C,
      '<OwningContainers><Items><Counted><X>3</X></Counted></Items>' +
      '</OwningContainers>');
    Check((C.Items = Items) and (C.Items.Count = 1) and (C.Items[0].X = 3) and
          (TCounted.Live = Live - 1), 'XML_RIGHT_SHAPE_STILL_REFILLS');
  finally
    C.Free;
  end;

  RootList := TObjectList<TCounted>.Create(True);
  try
    RootList.Add(NewCounted(5));
    Refused := False;
    try
      TXmlSerializer.Populate<TObjectList<TCounted>>(RootList,
        '<Value><Entry key="a"><X>1</X></Entry></Value>');
    except
      on E: EXmlInputError do Refused := True;
    end;
    Check(Refused and (RootList.Count = 1) and (RootList[0].X = 5),
      'XML_ROOT_LIST_OF_ANOTHER_SHAPE_REFUSED');
  finally
    RootList.Free;
  end;
end;

{ A failed read frees what it built and nothing it did not. Objects built
  into a record, into an array before it was assembled, or into a
  non-owning container the read made itself were left alive; a repeated key
  orphaned the value built for its first occurrence; a container's own
  refusal reached the caller as an RTL exception. }
procedure TestReleaseRegressions;
var
  Before: Integer;
  CC: TCountedContainers;
  Lines: TSortedLines;
  Ok, Raised: Boolean;
  Msg: string;
begin
  Writeln('-- what a failed read built --');
  Check(RefusedWithoutLeak(procedure
    begin
      TXmlSerializer.Deserialize<TPairHolder>(
        '<PairHolder><R><O><X>1</X></O><N>5000000000</N></R></PairHolder>').Free;
    end), 'XML_FAILED_RECORD_FREES_ITS_OBJECT');
  Check(RefusedWithoutLeak(procedure
    begin
      TXmlSerializer.Deserialize<TNullablePairHolder>(
        '<NullablePairHolder><R><O><X>1</X></O><N>5000000000</N></R>' +
        '</NullablePairHolder>').Free;
    end), 'XML_FAILED_NULLABLE_RECORD_FREES_ITS_OBJECT');
  Check(RefusedWithoutLeak(procedure
    begin
      TXmlSerializer.Deserialize<TPairListHolder>(
        '<PairListHolder><L><CountedPair><O><X>1</X></O><N>1</N></CountedPair>' +
        '<CountedPair><O><X>2</X></O><N>5000000000</N></CountedPair></L>' +
        '</PairListHolder>').Free;
    end), 'XML_FAILED_LIST_OF_RECORDS_FREES_ITS_OBJECTS');
  Check(RefusedWithoutLeak(procedure
    begin
      TXmlSerializer.Deserialize<TCountedArrays>(
        '<CountedArrays><A><Counted><X>1</X></Counted><Counted><X>2</X></Counted>' +
        '<Counted><X>5000000000</X></Counted></A></CountedArrays>').Free;
    end), 'XML_FAILED_DYNAMIC_ARRAY_FREES_ITS_ELEMENTS');
  Check(RefusedWithoutLeak(procedure
    begin
      TXmlSerializer.Deserialize<TCountedArrays>(
        '<CountedArrays><S><Counted><X>1</X></Counted><Counted><X>2</X></Counted>' +
        '<Counted><X>5000000000</X></Counted></S></CountedArrays>').Free;
    end), 'XML_FAILED_STATIC_ARRAY_FREES_ITS_ELEMENTS');
  Check(RefusedWithoutLeak(procedure
    begin
      TXmlSerializer.Deserialize<TCountedContainers>(
        '<CountedContainers><L><Counted><X>1</X></Counted><Counted><X>2</X></Counted>' +
        '<Counted><X>5000000000</X></Counted></L></CountedContainers>').Free;
    end), 'XML_FAILED_NON_OWNING_LIST_FREES_ITS_ELEMENTS');
  Check(RefusedWithoutLeak(procedure
    begin
      TXmlSerializer.Deserialize<TCountedContainers>(
        '<CountedContainers><D><Entry key="a"><X>1</X></Entry>' +
        '<Entry key="b"><X>2</X></Entry><Entry key="c"><X>5000000000</X></Entry>' +
        '</D></CountedContainers>').Free;
    end), 'XML_FAILED_NON_OWNING_DICTIONARY_FREES_ITS_VALUES');

  { The later occurrence wins, as it always did; the value built for the
    earlier one is freed rather than dropped. }
  Before := TCounted.Live;
  CC := TXmlSerializer.Deserialize<TCountedContainers>(
    '<CountedContainers><D><Entry key="qa"><X>1</X></Entry>' +
    '<Entry key="qa"><X>2</X></Entry></D></CountedContainers>');
  try
    Ok := (CC.D.Count = 1) and (CC.D['qa'].X = 2) and
      (TCounted.Live = Before + 1);
  finally
    CC.Free;
  end;
  Check(Ok and (TCounted.Live = Before),
    'XML_DUPLICATE_KEY_RELEASES_THE_EARLIER_VALUE');
  TCounted.Live := Before;

  { A read-only member with no instance got one built that nothing could
    hold. }
  Before := TCounted.Live;
  TXmlSerializer.Deserialize<TReadOnlyMember>(
    '<ReadOnlyMember><Obj><X>1</X></Obj></ReadOnlyMember>').Free;
  Check(TCounted.Live = Before, 'XML_READ_ONLY_MEMBER_RELEASES_WHAT_IT_BUILT');
  TCounted.Live := Before;

  Lines := TSortedLines.Create;
  try
    Raised := False;
    Msg := '';
    try
      TXmlSerializer.Populate<TSortedLines>(Lines,
        '<SortedLines><Lines><Item>b</Item><Item>a</Item><Item>b</Item>' +
        '</Lines></SortedLines>');
    except
      on E: Exception do
      begin
        Raised := E is EXmlInputError;
        Msg := E.ClassName + ': ' + E.Message;
      end;
    end;
  finally
    Lines.Free;
  end;
  Note(Msg);
  Check(Raised and ContainsText(Msg, 'TStringList'),
    'XML_CONTAINER_REFUSAL_IS_AN_INPUT_ERROR');
end;

begin
  try
    ConfigureContract;
    TestScalarRoot;
    Writeln;
    TestClassRoundtrip;
    Writeln;
    TestRecordRoundtrip;
    Writeln;
    TestPlacement;
    Writeln;
    TestNamespaces;
    Writeln;
    TestCollectionCustomization;
    Writeln;
    TestDictionaryAndArray;
    Writeln;
    TestReuse;
    Writeln;
    TestCustomSerializer;
    Writeln;
    TestPlanCacheStable;
    Writeln;
    TestBadInput;
    Writeln;
    TestDateRegressions;
    Writeln;
    TestDoubleRegressions;
    Writeln;
    TestSurrogateRegressions;
    Writeln;
    TestDepthRegressions;
    Writeln;
    TestWrongShapeRegressions;
    Writeln;
    TestReleaseRegressions;
    Writeln;
    { Everything above ran with no date configuration at all, which is what
      the default-contract checks needed. }
    TXmlSerializer.ResetConfiguration;
    ConfigureDates;
    TestDatePolicies;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then
    Writeln('XML_CORE: PASS')
  else
  begin
    Writeln('XML_CORE: FAIL');
    ExitCode := 1;
  end;
end.
