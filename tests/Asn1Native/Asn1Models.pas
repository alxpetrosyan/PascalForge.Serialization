unit Asn1Models;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{$SCOPEDENUMS ON}

{ The contracts the ASN.1 tests encode.

  A record is a SEQUENCE and its members are the components in declaration
  order, because ASN.1 puts nothing between them. The attributes say the
  parts a Delphi type cannot: the context tag, OPTIONAL, which string type,
  and which alternative of a CHOICE is present. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  PascalForge.Nullable,
  PascalForge.Asn1;

type
  TStatus = (Active, Suspended, Closed);

  { The flat case: every member is a component. }
  TSubject = record
    Id: Integer;
    Name: string;
    Active: Boolean;
    Issued: TDateTime;
    Serial: TBytes;
  end;

  { Context tags, OPTIONAL and a chosen string type. }
  TTagged = record
    [Asn1Tag(0)] Primary: string;
    [Asn1Tag(1)] [Asn1Optional] Secondary: TNullable<string>;
    [Asn1Tag(2)] [Asn1Implicit] Count: Integer;
    [Asn1StringType(TAsn1Kind.PrintableString)] Code: string;
    [Asn1StringType(TAsn1Kind.Ia5String)] Email: string;
    [Asn1Ignore] Scratch: string;
  end;

  { A CHOICE that is a real CHOICE: exactly one alternative is present and
    the selector says which. It is NOT a record of nullable fields - those
    would all be encoded, and a CHOICE encodes one. }
  TNameForm = (ByRfc822, ByDns, ByIp);

  TGeneralName = record
    Which: TNameForm;
    Rfc822: string;
    Dns: string;
    Ip: TBytes;
  end;

  THolder = record
    [Asn1Choice('Which')] Name: TGeneralName;
  end;

  TCollection = record
    Items: TArray<Integer>;
    Names: TArray<string>;
  end;

  TScripts = record
    Georgian: string;
    Cyrillic: string;
    Cjk: string;
    Emoji: string;
  end;

  { OWNERSHIP. A read that fails part way frees what it built and nothing
    else; a record is merged in place like an object. Every class below
    counts its live instances, so a leak is a number and not a guess. }
  EOwnRefused = class(Exception);

  TOwnTracked = class
  public
    class var Live: Integer;
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;
  end;

  { Its constructor refuses the FailAt-th construction while armed: the
    failure then lands after the read has already built the earlier ones. }
  TOwnItem = class(TOwnTracked)
  public
    X: Integer;
  public
    class var Armed: Boolean;
    class var Built: Integer;
    class var FailAt: Integer;
  public
    constructor Create;
  end;

  TOwnPair = record
    A: TOwnItem;
    B: TOwnItem;
  end;

  TOwnRecord = class(TOwnTracked)
  public
    R: TOwnPair;
    destructor Destroy; override;
  end;

  TOwnNullableRecord = class(TOwnTracked)
  public
    R: TNullable<TOwnPair>;
    destructor Destroy; override;
  end;

  TOwnRecordList = class(TOwnTracked)
  public
    L: TList<TOwnPair>;
    destructor Destroy; override;
  end;

  TOwnArray = class(TOwnTracked)
  public
    A: TArray<TOwnItem>;
    destructor Destroy; override;
  end;

  TOwnItems3 = array[0..2] of TOwnItem;

  TOwnStatic = class(TOwnTracked)
  public
    A: TOwnItems3;
    destructor Destroy; override;
  end;

  TOwnList = class(TOwnTracked)
  public
    L: TList<TOwnItem>;
    destructor Destroy; override;
  end;

  TOwnMap = class(TOwnTracked)
  public
    D: TDictionary<string, TOwnItem>;
    destructor Destroy; override;
  end;

  { The document drives the failure: N is an Int64 on the way out and an
    Integer on the way in, and comes after the object. }
  TOwnWidePair = record
    A: TOwnItem;
    B: TOwnItem;
    N: Int64;
  end;

  TOwnWide = class(TOwnTracked)
  public
    R: TOwnWidePair;
    destructor Destroy; override;
  end;

  TOwnNarrowPair = record
    A: TOwnItem;
    B: TOwnItem;
    N: Integer;
  end;

  TOwnNarrow = class(TOwnTracked)
  public
    R: TOwnNarrowPair;
    destructor Destroy; override;
  end;

  { The constructor puts two objects in the record, which a read must fill
    rather than replace. }
  TOwnMerged = class(TOwnTracked)
  public
    R: TOwnNarrowPair;
  public
    class var MadeA, MadeB: TOwnItem;
  public
    constructor Create;
    destructor Destroy; override;
  end;

  TOwnLinesSource = class
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  { A container that refuses an element itself: a sorted TStringList with
    dupError. }
  TOwnSortedLines = class
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  { WRITER LIMITS. }
  TUniversalText = record
    [Asn1StringType(TAsn1Kind.UniversalString)] S: string;
  end;

  TBmpText = record
    [Asn1StringType(TAsn1Kind.BmpString)] S: string;
  end;

  TUtf8Text = record
    S: string;
  end;

  { A record nesting through an array of itself, with no object anywhere. }
  TRecordNode = record
    Tag: Integer;
    Kids: TArray<TRecordNode>;
  end;

  TRecordNodeHolder = class
  public
    N: TRecordNode;
  end;

  TObjectNode = class
  public
    Tag: Integer;
    Child: TObjectNode;
    destructor Destroy; override;
  end;

  TMoment = record
    D: TDateTime;
  end;

implementation

procedure TOwnTracked.AfterConstruction;
begin
  inherited;
  AtomicIncrement(Live);
end;

procedure TOwnTracked.BeforeDestruction;
begin
  AtomicDecrement(Live);
  inherited;
end;

constructor TOwnItem.Create;
begin
  inherited Create;
  if Armed then
  begin
    Inc(Built);
    if Built = FailAt then
      raise EOwnRefused.CreateFmt('construction #%d refused by the test',
        [Built]);
  end;
end;

destructor TOwnRecord.Destroy;
begin
  R.A.Free;
  R.B.Free;
  inherited;
end;

destructor TOwnNullableRecord.Destroy;
begin
  if R.HasValue then
  begin
    R.Value.A.Free;
    R.Value.B.Free;
  end;
  inherited;
end;

destructor TOwnRecordList.Destroy;
var
  I: Integer;
begin
  if L <> nil then
    for I := 0 to L.Count - 1 do
    begin
      L[I].A.Free;
      L[I].B.Free;
    end;
  L.Free;
  inherited;
end;

destructor TOwnArray.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(A) do A[I].Free;
  inherited;
end;

destructor TOwnStatic.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(A) do A[I].Free;
  inherited;
end;

destructor TOwnList.Destroy;
var
  I: Integer;
begin
  if L <> nil then
    for I := 0 to L.Count - 1 do L[I].Free;
  L.Free;
  inherited;
end;

destructor TOwnMap.Destroy;
var
  V: TOwnItem;
begin
  if D <> nil then
    for V in D.Values do V.Free;
  D.Free;
  inherited;
end;

destructor TOwnWide.Destroy;
begin
  R.A.Free;
  R.B.Free;
  inherited;
end;

destructor TOwnNarrow.Destroy;
begin
  R.A.Free;
  R.B.Free;
  inherited;
end;

constructor TOwnMerged.Create;
begin
  inherited Create;
  R.A := TOwnItem.Create;
  R.B := TOwnItem.Create;
  MadeA := R.A;
  MadeB := R.B;
end;

destructor TOwnMerged.Destroy;
begin
  R.A.Free;
  R.B.Free;
  inherited;
end;

constructor TOwnLinesSource.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
end;

destructor TOwnLinesSource.Destroy;
begin
  Lines.Free;
  inherited;
end;

constructor TOwnSortedLines.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
  Lines.Sorted := True;
  Lines.Duplicates := dupError;
end;

destructor TOwnSortedLines.Destroy;
begin
  Lines.Free;
  inherited;
end;

destructor TObjectNode.Destroy;
begin
  Child.Free;
  inherited;
end;

end.
