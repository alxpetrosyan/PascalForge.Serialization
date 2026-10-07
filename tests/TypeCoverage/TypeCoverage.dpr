program TypeCoverage;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ EVERY DELPHI TYPE FAMILY, THROUGH EVERY FORMAT.

  The permanent Delphi-language compatibility suite. Each model class in
  TypeCoverage.Models isolates one family; this program puts each of them
  through every contract-capable format in the registry and records exactly
  what happened.

  THE FIVE ANSWERS

    ok        it went out and came back equal
    refused   this library said no, with one of its OWN exception classes
    RTL       an exception from somewhere else - EInvalidCast, EConvertError,
              an access violation. Always a defect: a caller must not have to
              catch the runtime library's exceptions to handle a type
    DIFF      it came back different and nothing said so. The worst of the
              five, because nothing in production would notice either
    UNSAFE    a type that has no business on the wire - an address, a code
              pointer, an interface - went out and came back as if it did

  THE COMPARER IS DELIBERATELY NOT THE LIBRARY'S. It walks values with RTTI
  and its own notion of a collection (anything with a parameterless ToArray),
  so a type the library misclassifies cannot mark its own homework. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Math, System.TypInfo, System.Rtti,
  System.Variants, System.Generics.Collections, System.Generics.Defaults,
  Data.FmtBcd, System.SysConst, System.RTLConsts,
  TypeCoverage.Models in 'TypeCoverage.Models.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  AllFormatsRegistered in '..\Shared\AllFormatsRegistered.pas';

type
  { Unexpected is a refusal nothing documents: this library said no, in its
    own words, to a type the format CAN carry. A refusal is an answer only
    where the probe lists it as one, with the reason. }
  TOutcome = (Ok, Refused, Rtl, Diff, Unsafe, Readback, Unexpected);

  TProbe = record
    Name: string;
    Family: string;
    Cls: TClass;
    FillMethod: string;
    { True for a type that must never be carried: a refusal is the right
      answer and a round trip is a defect. }
    MustRefuse: Boolean;
    { The formats whose documented answer for this family is a refusal,
      comma-separated, or * for every one; and why. A refusal anywhere else
      is a defect. }
    Refusable: string;
    RefusalReason: string;
    { Integer members are also checked on the wire: see WireDefect. }
    CheckWire: Boolean;
  end;

  TCell = record
    Outcome: TOutcome;
    Detail: string;
  end;

var
  Ctx: TRttiContext;
  Probes: TList<TProbe>;
  Formats: TArray<TSerializationFormat>;
  Cells: TDictionary<string, TCell>;

const
  OUTCOME_TEXT: array[TOutcome] of string = ('ok', 'refused', 'RTL', 'DIFF',
    'UNSAFE', 'READBACK', 'UNEXPECTED');

function Name(F: TSerializationFormat): string;
begin
  Result := TSerializationFormats.FormatName(F);
end;

{ ===========================================================================
  THE COMPARER
  =========================================================================== }

function SameDeep(AType: TRttiType; const A, B: TValue; const APath: string;
  AVisited: TDictionary<Pointer, Boolean>; out AWhere: string): Boolean; forward;

function RawEqual(const A, B: TValue; ASize: Integer): Boolean;
begin
  Result := CompareMem(A.GetReferenceToRawData, B.GetReferenceToRawData, ASize);
end;

function FindToArray(ACls: TClass): TRttiMethod;
var
  M: TRttiMethod;
begin
  Result := nil;
  for M in Ctx.GetType(ACls).GetMethods('ToArray') do
    if (Length(M.GetParameters) = 0) and (M.ReturnType <> nil) then Exit(M);
end;

function HasMethod(ACls: TClass; const AName: string): Boolean;
begin
  Result := Ctx.GetType(ACls).GetMethod(AName) <> nil;
end;

function SameFloat(AType: TRttiType; const A, B: TValue): Boolean;
var
  X, Y: Double;
begin
  case GetTypeData(AType.Handle).FloatType of
    ftCurr, ftComp:
      { Both are Int64 underneath; compared as the integers they are. }
      Exit(RawEqual(A, B, 8));
    ftSingle:
      begin
        X := A.AsExtended; Y := B.AsExtended;
      end;
  else
    X := A.AsExtended; Y := B.AsExtended;
  end;
  if IsNan(X) or IsNan(Y) then Exit(IsNan(X) and IsNan(Y));
  if (X = 0) and (Y = 0) then
    { Minus zero is a different value from zero, and a format that folds
      one into the other has changed it. }
    Exit((PUInt64(@X)^ shr 63) = (PUInt64(@Y)^ shr 63));
  { EXTENDED IS CARRIED AT DOUBLE PRECISION, and that is the documented
    policy rather than a loss: no format here has an 80-bit float, and
    on Win64 Extended IS Double. So it is judged as the Double it travels
    as. }
  Result := X = Y;
end;

function SameObject(ACls: TClass; AA, BB: TObject; const APath: string;
  AVisited: TDictionary<Pointer, Boolean>; out AWhere: string): Boolean;
var
  RT: TRttiType;
  F: TRttiField;
  ToArr: TRttiMethod;
  AArr, BArr, APair, BPair: TValue;
  I, J: Integer;
  Found: Boolean;
  Scratch: string;
  ElemType, KeyType: TRttiType;
  KeyField: TRttiField;
begin
  AWhere := '';
  if (AA = nil) and (BB = nil) then Exit(True);
  if (AA = nil) <> (BB = nil) then
  begin
    AWhere := APath + ' (nil on one side)';
    Exit(False);
  end;
  if AVisited.ContainsKey(AA) then Exit(True);
  AVisited.Add(AA, True);

  if AA is TStrings then
  begin
    if TStrings(AA).Text <> TStrings(BB).Text then
    begin
      AWhere := APath + ' (strings differ)';
      Exit(False);
    end;
    Exit(True);
  end;

  if AA is TCollection then
  begin
    if TCollection(AA).Count <> TCollection(BB).Count then
    begin
      AWhere := Format('%s.Count %d <> %d', [APath, TCollection(AA).Count,
        TCollection(BB).Count]);
      Exit(False);
    end;
    for I := 0 to TCollection(AA).Count - 1 do
      if not SameObject(TCollection(AA).Items[I].ClassType,
           TCollection(AA).Items[I], TCollection(BB).Items[I],
           Format('%s[%d]', [APath, I]), AVisited, AWhere) then Exit(False);
    Exit(True);
  end;

  { A collection, by its own public surface rather than by what this library
    thinks it is. }
  ToArr := FindToArray(AA.ClassType);
  if ToArr <> nil then
  begin
    AArr := ToArr.Invoke(AA, []);
    BArr := ToArr.Invoke(BB, []);
    if AArr.GetArrayLength <> BArr.GetArrayLength then
    begin
      AWhere := Format('%s.Count %d <> %d', [APath, AArr.GetArrayLength,
        BArr.GetArrayLength]);
      Exit(False);
    end;
    ElemType := TRttiDynamicArrayType(Ctx.GetType(AArr.TypeInfo)).ElementType;

    if HasMethod(AA.ClassType, 'ContainsKey') then
    begin
      { A dictionary has no order, so pairs are matched by key. }
      KeyField := ElemType.GetField('Key');
      KeyType := KeyField.FieldType;
      for I := 0 to AArr.GetArrayLength - 1 do
      begin
        APair := AArr.GetArrayElement(I);
        Found := False;
        for J := 0 to BArr.GetArrayLength - 1 do
        begin
          BPair := BArr.GetArrayElement(J);
          if SameDeep(KeyType,
               KeyField.GetValue(APair.GetReferenceToRawData),
               KeyField.GetValue(BPair.GetReferenceToRawData),
               APath, AVisited, Scratch) then
          begin
            Found := True;
            if not SameDeep(ElemType, APair, BPair,
                 APath + '[' + KeyField.GetValue(
                   APair.GetReferenceToRawData).ToString + ']',
                 AVisited, AWhere) then Exit(False);
            Break;
          end;
        end;
        if not Found then
        begin
          AWhere := APath + ' (key ' +
            KeyField.GetValue(APair.GetReferenceToRawData).ToString +
            ' missing)';
          Exit(False);
        end;
      end;
      Exit(True);
    end;

    for I := 0 to AArr.GetArrayLength - 1 do
      if not SameDeep(ElemType, AArr.GetArrayElement(I),
           BArr.GetArrayElement(I), Format('%s[%d]', [APath, I]),
           AVisited, AWhere) then Exit(False);
    Exit(True);
  end;

  { A read-only property has no setter, so it cannot come back, and a
    write-only or indexed one has no value to send. The probe exists to prove
    none of them is CALLED wrongly; the one member that can round-trip is
    the one compared. }
  if AA is TPropertyProbe then
  begin
    Result := TPropertyProbe(AA).Visible = TPropertyProbe(BB).Visible;
    if not Result then AWhere := APath + '.Visible';
    Exit;
  end;

  RT := Ctx.GetType(ACls);
  for F in RT.GetFields do
  begin
    { A member with no RTTI cannot be compared, and skipping it is how this
      harness once reported static arrays as carried when both the
      serializer and the comparer had silently ignored them. So it is a
      difference, loudly, unless it is the inline-array probe whose whole
      point is that the serializer refuses it. }
    if F.FieldType = nil then
    begin
      AWhere := APath + '.' + F.Name + ' (no RTTI: cannot be compared)';
      Exit(False);
    end;
    if not SameDeep(F.FieldType, F.GetValue(AA), F.GetValue(BB),
         APath + '.' + F.Name, AVisited, AWhere) then Exit(False);
  end;
  Result := True;
end;

{ THE VARIANT CONTRACT, as docs\delphi-type-coverage.md states it: a
  Variant keeps its value and its FAMILY - empty, null, boolean, integer,
  real, date, text, array - and not its exact width, because no format
  records that the literal 42 was a varByte. Everything else is compared as
  strictly as any other value: a family change is a difference, and so is
  one element of an array. }
function VariantFamily(const V: Variant): Integer;
begin
  if (VarType(V) and varArray) <> 0 then Exit(8);
  case VarType(V) of
    varEmpty: Result := 0;
    varNull: Result := 1;
    varBoolean: Result := 2;
    varShortInt, varSmallint, varInteger, varByte, varWord, varLongWord,
    varInt64, varUInt64: Result := 3;
    varSingle, varDouble, varCurrency: Result := 4;
    varDate: Result := 5;
    varOleStr, varString, varUString: Result := 6;
  else
    Result := 100 + VarType(V);
  end;
end;

function SameVariant(const A, B: Variant): Boolean;
var
  I: Integer;
begin
  if VariantFamily(A) <> VariantFamily(B) then Exit(False);
  case VariantFamily(A) of
    0, 1: Result := True;
    8:
      begin
        if (VarArrayDimCount(A) <> 1) or (VarArrayDimCount(B) <> 1) then
          Exit(False);
        if VarArrayHighBound(A, 1) - VarArrayLowBound(A, 1) <>
           VarArrayHighBound(B, 1) - VarArrayLowBound(B, 1) then Exit(False);
        for I := 0 to VarArrayHighBound(A, 1) - VarArrayLowBound(A, 1) do
          if not SameVariant(A[VarArrayLowBound(A, 1) + I],
               B[VarArrayLowBound(B, 1) + I]) then Exit(False);
        Result := True;
      end;
  else
    Result := VarSameValue(A, B);
  end;
end;

{ A scalar as a DIFF line shows it: exactly, so two values that print alike
  are never reported as different without the reason being visible. }
function Shown(AType: TRttiType; const V: TValue): string;
var
  X: Double;
  S: string;
  C: Char;
begin
  try
    case AType.TypeKind of
      tkFloat:
        begin
          if GetTypeData(AType.Handle).FloatType in [ftCurr, ftComp] then
            Exit(IntToStr(PInt64(V.GetReferenceToRawData)^) + ' raw');
          X := V.AsExtended;
          Exit(FloatToStrF(X, ffGeneral, 17, 0) + ' bits $' +
            IntToHex(PUInt64(@X)^, 16));
        end;
      tkString, tkLString, tkWString, tkUString, tkChar, tkWChar:
        begin
          S := '';
          for C in V.ToString do
            if (Ord(C) < 32) or (Ord(C) > 126) then
              S := S + '#' + IntToHex(Ord(C), 4)
            else
              S := S + C;
          Exit('"' + S + '"');
        end;
      tkVariant:
        Exit(Format('varType %d %s', [VarType(V.AsVariant),
          VarToStrDef(V.AsVariant, '?')]));
    end;
    Result := V.ToString;
  except
    on E: Exception do Result := '<' + E.ClassName + '>';
  end;
end;

function SameDeep(AType: TRttiType; const A, B: TValue; const APath: string;
  AVisited: TDictionary<Pointer, Boolean>; out AWhere: string): Boolean;
var
  NullAcc: TNullableAccess;
  F: TRttiField;
  I: Integer;
  ElemType: TRttiType;
begin
  AWhere := '';
  Result := True;
  if AType = nil then Exit;

  case AType.TypeKind of
    tkInteger, tkChar, tkWChar, tkEnumeration:
      Result := A.AsOrdinal = B.AsOrdinal;
    tkInt64:
      Result := RawEqual(A, B, 8);
    tkSet:
      Result := RawEqual(A, B, A.DataSize);
    tkFloat:
      Result := SameFloat(AType, A, B);
    tkString, tkLString, tkWString, tkUString:
      Result := A.AsString = B.AsString;
    tkVariant:
      Result := SameVariant(A.AsVariant, B.AsVariant);
    tkRecord, tkMRecord:
      begin
        { A nullable without a value has no value to compare: its inner field
          is whatever the record was initialised with, which is nobody's data. }
        if TSerializationTypes.TryGetNullableAccess(AType.Handle, NullAcc) then
        begin
          if NullAcc.HasValue(A.GetReferenceToRawData) <>
             NullAcc.HasValue(B.GetReferenceToRawData) then
          begin
            AWhere := APath + ' (HasValue differs)';
            Exit(False);
          end;
          if not NullAcc.HasValue(A.GetReferenceToRawData) then Exit(True);
          Exit(SameDeep(Ctx.GetType(NullAcc.ValueType),
            NullAcc.GetValue(A.GetReferenceToRawData),
            NullAcc.GetValue(B.GetReferenceToRawData), APath, AVisited,
            AWhere));
        end;
        if AType.Handle = TypeInfo(TGUID) then
          Exit(RawEqual(A, B, SizeOf(TGUID)));
        if AType.Handle = TypeInfo(TBcd) then
          Exit(BcdCompare(PBcd(A.GetReferenceToRawData)^,
            PBcd(B.GetReferenceToRawData)^) = 0);
        for F in AType.GetFields do
        begin
          if F.FieldType = nil then Continue;
          if not SameDeep(F.FieldType, F.GetValue(A.GetReferenceToRawData),
               F.GetValue(B.GetReferenceToRawData), APath + '.' + F.Name,
               AVisited, AWhere) then Exit(False);
        end;
      end;
    tkArray, tkDynArray:
      begin
        if A.GetArrayLength <> B.GetArrayLength then
        begin
          AWhere := Format('%s.Length %d <> %d', [APath, A.GetArrayLength,
            B.GetArrayLength]);
          Exit(False);
        end;
        if AType is TRttiArrayType then
          ElemType := TRttiArrayType(AType).ElementType
        else
          ElemType := TRttiDynamicArrayType(AType).ElementType;
        for I := 0 to A.GetArrayLength - 1 do
          if not SameDeep(ElemType, A.GetArrayElement(I),
               B.GetArrayElement(I), Format('%s[%d]', [APath, I]), AVisited,
               AWhere) then Exit(False);
      end;
    tkClass:
      Exit(SameObject(TRttiInstanceType(AType).MetaclassType, A.AsObject,
        B.AsObject, APath, AVisited, AWhere));
    tkPointer, tkClassRef, tkProcedure:
      Result := RawEqual(A, B, SizeOf(Pointer));
    tkMethod:
      Result := RawEqual(A, B, SizeOf(TMethod));
    tkInterface:
      Result := A.AsInterface = B.AsInterface;
  end;
  if not Result and (AWhere = '') then
    AWhere := APath + ' (' + Shown(AType, A) + ' <> ' + Shown(AType, B) + ')';
end;

{ ===========================================================================
  ONE CELL
  =========================================================================== }

function NewInstance(ACls: TClass): TObject;
var
  RT: TRttiInstanceType;
  M: TRttiMethod;
begin
  { Through the constructor the class declares, so a probe that creates its
    own lists in Create gets them. TObject.Create is not virtual and calling
    it would skip exactly that. }
  RT := TRttiInstanceType(Ctx.GetType(ACls));
  for M in RT.GetMethods('Create') do
    if M.IsConstructor and (Length(M.GetParameters) = 0) then
      Exit(M.Invoke(RT.MetaclassType, []).AsObject);
  Result := ACls.Create;
end;

procedure Fill(AObj: TObject; const AMethod: string);
begin
  Ctx.GetType(AObj.ClassType).GetMethod(AMethod).Invoke(AObj, []);
end;

{ The fixed part of a runtime-library message: the text before its first
  format specifier, which is what survives when an engine wraps it. }
function Stem(const AResource: string): string;
var
  P: Integer;
begin
  Result := AResource;
  P := Pos('%', Result);
  if P > 0 then Result := Copy(Result, 1, P - 1);
  Result := Trim(Result);
end;

function IsOwnRefusal(E: Exception): Boolean;
const
  { An engine that catches an EInvalidCast and raises its own error with the
    message glued on has not refused anything - it has crashed politely. So
    a message carrying one of these is an accident whatever its class. The
    list is of the runtime library's own resource strings, so it holds in
    any language the RTL is built in. }
  ACCIDENTS: array[0..11] of string = (SInvalidCast, SAccessViolationArg3,
    SInvalidPointer, SInsufficientRtti, SParameterCountMismatch,
    SInvalidVarCast, SRangeError, SIntOverflow, SStackOverflow,
    SListIndexError, SArgumentOutOfRange, SVarBadType);
var
  A, S: string;
begin
  { A refusal counts only when it is this library speaking, in one of its
    own exception classes, about something it decided. }
  Result := string(E.UnitName).StartsWith('PascalForge.');
  if not Result then Exit;
  for A in ACCIDENTS do
  begin
    S := Stem(A);
    if (Length(S) >= 8) and (Pos(S, E.Message) > 0) then Exit(False);
  end;
end;

{ ===========================================================================
  THE WIRE

  A round trip proves the reader understands the writer, and nothing more:
  a writer that puts 4294967295 down as -1 reads it back into the same
  Cardinal and passes. So for every integer member, every self-describing
  format's payload is also read STRUCTURALLY - with no Delphi type to lean
  on - and the digits it says must be the digits the value is.
  =========================================================================== }

function FindWireMember(N: TDynamicValue; const AName: string): TDynamicValue;
var
  I: Integer;
begin
  Result := nil;
  if N = nil then Exit;
  if N.Kind = TDynamicKind.Obj then
    for I := 0 to N.Count - 1 do
      if SameText(N.Names[I], AName) then Exit(N.Items[I]);
  if N.Kind in [TDynamicKind.Obj, TDynamicKind.Arr] then
    for I := 0 to N.Count - 1 do
    begin
      Result := FindWireMember(N.Items[I], AName);
      if Result <> nil then Exit;
    end;
end;

function WireText(N: TDynamicValue): string;
begin
  case N.Kind of
    TDynamicKind.Int: Result := IntToStr(N.AsInt);
    TDynamicKind.UInt: Result := UIntToStr(N.AsUInt);
    TDynamicKind.Str: Result := N.AsStr;
    TDynamicKind.Decimal: Result := N.AsDecimal;
  else
    Result := N.Describe;
  end;
end;

function WireDefect(const P: TProbe; F: TSerializationFormat; AObj: TObject;
  const APayload: TSerializationPayload): string;
var
  H: TSerializationFormatHandler;
  N, M: TDynamicValue;
  Fld: TRttiField;
  Expected: string;
begin
  Result := '';
  H := TSerializationFormats.Get(F);
  if not (TSerializationFormatCapability.StructuralParse in
          H.Capabilities(TStructuralConversionOptions.Default)) then Exit;
  N := H.ToDynamic(APayload, TStructuralConversionOptions.Default);
  try
    for Fld in Ctx.GetType(P.Cls).GetFields do
    begin
      if Fld.FieldType = nil then Continue;
      if not ((Fld.FieldType.TypeKind in [tkInteger, tkInt64]) or
              TSerializationTypes.IsCompType(Fld.FieldType.Handle)) then
        Continue;
      Expected := TSerializationTypes.IntegerText(Fld.GetValue(AObj));
      M := FindWireMember(N, Fld.Name);
      if M = nil then
        Exit(Format('wire: $.%s is not in the document', [Fld.Name]));
      if WireText(M) <> Expected then
        Exit(Format('wire: $.%s says %s, and the value is %s',
          [Fld.Name, WireText(M), Expected]));
      { A format with typed scalars has to say it is a NUMBER. Only XML
        and CSV, whose values are all text, may carry the digits as text. }
      if not (F in [TSerializationFormat.Xml, TSerializationFormat.Csv]) and
         not (M.Kind in [TDynamicKind.Int, TDynamicKind.UInt]) then
        Exit(Format('wire: $.%s is %s, not an integer',
          [Fld.Name, M.Describe]));
    end;
  finally
    N.Free;
  end;
end;

function RunCell(const P: TProbe; F: TSerializationFormat): TCell;
var
  Obj, Back: TObject;
  V, Out_: TValue;
  Payload: TSerializationPayload;
  Visited: TDictionary<Pointer, Boolean>;
  Where: string;
begin
  Result.Detail := '';
  Obj := nil;
  Back := nil;
  Visited := TDictionary<Pointer, Boolean>.Create;
  try
    try
      Obj := NewInstance(P.Cls);
      Fill(Obj, P.FillMethod);
      TValue.Make(@Obj, P.Cls.ClassInfo, V);
      Payload := TSerializationFormats.Get(F).SerializeTyped(P.Cls.ClassInfo, V);
    except
      on E: Exception do
      begin
        Result.Detail := E.ClassName + ': ' + E.Message;
        if IsOwnRefusal(E) then Result.Outcome := TOutcome.Refused
        else Result.Outcome := TOutcome.Rtl;
        Exit;
      end;
    end;

    { The payload came from this format's own writer. Whatever it wrote, its
      reader has to read - so ANY failure here is a defect, including one
      raised with this library's own exception class. A writer that emits a
      document its reader rejects has refused nothing; it has broken. }
    try
      Out_ := TSerializationFormats.Get(F).DeserializeTyped(P.Cls.ClassInfo,
        Payload);
      Back := Out_.AsObject;
    except
      on E: Exception do
      begin
        Result.Detail := 'reading its own output: ' + E.ClassName + ': ' +
          E.Message;
        Result.Outcome := TOutcome.Readback;
        Exit;
      end;
    end;

    if P.MustRefuse then
    begin
      { It went out and came back. Whether the value compares equal is
        beside the point: an address or a code pointer was written. }
      Result.Outcome := TOutcome.Unsafe;
      if SameObject(P.Cls, Obj, Back, '$', Visited, Where) then
        Result.Detail := 'carried an unsafe value unchanged'
      else
        Result.Detail := 'went out without refusing; came back as ' + Where;
      Exit;
    end;

    try
      if P.CheckWire then
      begin
        Where := WireDefect(P, F, Obj, Payload);
        if Where <> '' then
        begin
          Result.Outcome := TOutcome.Diff;
          Result.Detail := Where;
          Exit;
        end;
      end;
      if SameObject(P.Cls, Obj, Back, '$', Visited, Where) then
        Result.Outcome := TOutcome.Ok
      else
      begin
        Result.Outcome := TOutcome.Diff;
        Result.Detail := Where;
      end;
    except
      on E: Exception do
      begin
        Result.Outcome := TOutcome.Rtl;
        Result.Detail := 'comparing: ' + E.ClassName + ': ' + E.Message;
      end;
    end;
  finally
    Visited.Free;
    try Back.Free; except end;
    try Obj.Free; except end;
  end;
end;

{ ===========================================================================
  THE PROBES
  =========================================================================== }

procedure Add(const AFamily, AName: string; ACls: TClass;
  const AFill: string = 'Fill'; AMustRefuse: Boolean = False);
var
  P: TProbe;
begin
  P.Family := AFamily;
  P.Name := AName;
  P.Cls := ACls;
  P.FillMethod := AFill;
  P.MustRefuse := AMustRefuse;
  P.Refusable := '';
  P.RefusalReason := '';
  P.CheckWire := (ACls = TIntegerProbe) or (ACls = TUInt64Probe) or
    (ACls = TFloatProbe);
  Probes.Add(P);
end;

{ The documented refusal for the probe just added. }
procedure Allow(const AFormats, AReason: string);
var
  P: TProbe;
begin
  P := Probes.Last;
  if P.Refusable <> '' then
  begin
    P.Refusable := P.Refusable + ',' + AFormats;
    P.RefusalReason := P.RefusalReason + ' / ' + AReason;
  end
  else
  begin
    P.Refusable := AFormats;
    P.RefusalReason := AReason;
  end;
  Probes[Probes.Count - 1] := P;
end;

function MayRefuse(const P: TProbe; F: TSerializationFormat): Boolean;
var
  S: string;
begin
  if P.MustRefuse or (P.Refusable = '*') then Exit(True);
  for S in P.Refusable.Split([',']) do
    if SameText(Trim(S), Name(F)) or
       (SameText(Trim(S), 'Asn1') and Name(F).StartsWith('Asn1')) then
      Exit(True);
  Result := False;
end;

procedure RegisterProbes;
const
  CSV_COLLECTION = 'a CSV cell holds one value, and the default CollectionMode ' +
    'is Error: JsonCell, RepeatedRows, NumberedColumns or Separated carry it';
  SCHEMA_VARIANT = 'a Variant has no fixed type, and a schema-driven format ' +
    'writes only what its schema declares';
  TEXT_VARIANT = 'the text of a cell or an element has no type of its own, so ' +
    'a Variant read back could not know what it held';
  MAP_COLUMNS = 'a map''s keys are data, not a fixed set of columns';
begin
  Add('C integers', 'integers at their minimum', TIntegerProbe, 'FillMin');
  Add('C integers', 'integers at their maximum', TIntegerProbe, 'FillMax');
  Add('C integers', 'integers at zero', TIntegerProbe, 'FillZero');
  Add('C integers', 'UInt64 above High(Int64)', TUInt64Probe);
  Allow('Bson', 'BSON has no unsigned 64-bit integer, and int64 cannot hold it');
  Allow('Avro', 'an Avro long is signed, and cannot hold it');

  Add('D floats', 'Single Double Extended Currency Comp', TFloatProbe);
  Add('D floats', 'NaN and the infinities', TNonFiniteProbe);
  Allow('Json', 'JSON has no NaN and no infinity');
  Add('D floats', 'minus zero', TNegativeZeroProbe);

  Add('E text', 'Char WideChar and Unicode text', TTextProbe);
  Add('E text', 'embedded #0', TEmbeddedNullProbe);
  Allow('Xml', 'XML 1.0 cannot contain U+0000, literally or escaped');
  Add('E text', 'control characters', TControlCharProbe);
  Allow('Xml', 'XML 1.0 cannot contain C0 control characters other than tab, ' +
    'line feed and carriage return');
  Add('E text', 'AnsiString and AnsiChar', TAnsiProbe);
  Add('E text', 'UTF8String', TUtf8StringProbe);
  Add('E text', 'RawByteString', TRawByteProbe);
  Add('E text', 'ShortString', TShortStringProbe);

  Add('F enums', 'enums incl. a subrange with MinValue 10', TEnumProbe);
  Add('F sets', 'small, 40-member, offset, empty and full sets', TSetProbe);
  Add('F sets', 'set of AnsiChar, of Byte, of 0..63', TCharSetProbe);

  Add('G arrays', 'dynamic arrays', TDynArrayProbe);
  Allow('Csv', CSV_COLLECTION);
  Add('G arrays', 'TBytes', TBytesProbe);
  Add('G arrays', 'static array [0..2]', TStaticArrayProbe);
  Allow('Csv', CSV_COLLECTION);
  Add('G arrays', 'static array [5..7]', TOffsetArrayProbe);
  Allow('Csv', CSV_COLLECTION);
  Add('G arrays', 'two-dimensional static array', TMatrixProbe);
  Allow('Csv', CSV_COLLECTION);
  Add('G arrays', 'inline static array (no RTTI)', TInlineArrayProbe, 'Fill', True);
  Add('G arrays', 'jagged TArray<TArray<Integer>>', TNestedArrayProbe);
  Allow('Csv', CSV_COLLECTION);
  Allow('Protobuf', 'a repeated field cannot repeat a repeated field; the ' +
    'inner array needs a message of its own');
  Add('G arrays', 'TArray<TNullable<Integer>>', TNullableArrayProbe);
  Allow('Csv', CSV_COLLECTION);
  Allow('Protobuf', 'a repeated field has no null element');

  Add('H records', 'plain record and array of record', TPlainRecordProbe);
  Allow('Csv', CSV_COLLECTION);
  Add('H records', 'managed record', TManagedRecordProbe);
  Add('H records', 'generic record', TGenericRecordProbe);
  Add('H records', 'variant record', TVariantRecordProbe);
  Allow('*', 'two members share the same bytes and nothing records which ' +
    'one is meaningful; a custom serializer decides');
  Add('H records', 'packed record', TPackedRecordProbe);

  Add('I classes', 'three-level inheritance', TInheritanceProbe);
  Add('I classes', 'read-only, write-only and indexed properties', TPropertyProbe);

  Add('P collections', 'TList and TObjectList', TListProbe);
  Allow('Csv', CSV_COLLECTION);
  Add('P collections', 'TDictionary and TObjectDictionary', TDictionaryProbe);
  Allow('Csv', MAP_COLUMNS);
  Add('P collections', 'TDictionary<Integer, string>', TIntKeyDictionaryProbe);
  Allow('Csv', MAP_COLUMNS);
  Add('P collections', 'containers inside containers', TNestedContainerProbe);
  Allow('Csv', MAP_COLUMNS);
  Allow('Protobuf', 'a map value cannot be a repeated field; the list needs ' +
    'a message of its own');
  Add('P collections', 'TQueue<Integer>', TQueueProbe);
  Allow('Csv', CSV_COLLECTION);
  Add('P collections', 'TStack<Integer>', TStackProbe);
  Allow('Csv', CSV_COLLECTION);
  Add('P collections', 'TNullable with and without a value', TNullableListProbe);
  Allow('Csv', CSV_COLLECTION);

  Add('Q legacy', 'TStringList', TStringListProbe);
  Allow('Csv', CSV_COLLECTION);
  Add('Q legacy', 'legacy TList of pointers', TLegacyListProbe, 'Fill', True);
  Add('Q legacy', 'TCollection', TCollectionProbe);
  Allow('*', 'a TCollection makes its own items through its ItemClass, which ' +
    'a serializer must not choose; a custom serializer or a list of DTOs ' +
    'carries one');

  Add('R temporal', 'TDate TTime TDateTime', TTemporalProbe);
  Add('S identifiers', 'TGUID', TGuidProbe);
  Add('S identifiers', 'TBcd', TBcdProbe);
  Allow('*', 'TBcd.Fraction has no RTTI; a custom serializer carries a TBcd ' +
    'as exact decimal digits');

  Add('M variants', 'Variant holding scalars', TVariantProbe);
  Allow('Xml,Csv', TEXT_VARIANT);
  Allow('Protobuf,Avro,Asn1', SCHEMA_VARIANT);
  Add('M variants', 'Variant Null and Empty', TVariantNullProbe);
  Allow('Xml,Csv', TEXT_VARIANT);
  Allow('Protobuf,Avro,Asn1', SCHEMA_VARIANT);
  Add('M variants', 'variant array', TVariantArrayProbe);
  Allow('Xml,Csv', TEXT_VARIANT);
  Allow('Protobuf,Avro,Asn1', SCHEMA_VARIANT);
  Add('M variants', 'OleVariant', TOleVariantProbe);
  Allow('Xml,Csv', TEXT_VARIANT);
  Allow('Protobuf,Avro,Asn1', SCHEMA_VARIANT);

  Add('N unsafe', 'Pointer', TPointerProbe, 'Fill', True);
  Add('N unsafe', 'PChar', TPCharProbe, 'Fill', True);
  Add('N unsafe', 'procedural variable', TProcVarProbe, 'Fill', True);
  Add('N unsafe', 'method pointer', TMethodProbe, 'Fill', True);
  Add('V unsafe', 'anonymous method', TAnonymousProbe, 'Fill', True);
  Add('K unsafe', 'class reference', TClassRefProbe, 'Fill', True);
  Add('L unsafe', 'interface', TInterfaceProbe, 'Fill', True);
  Add('T framework', 'TMemoryStream', TStreamProbe);
  Allow('*', 'a stream is opaque: carry its bytes in a TBytes member, or ' +
    'register a serializer');
  Add('U framework', 'Exception', TExceptionProbe, 'Fill', True);
  Add('J framework', 'TComponent with an owned child', TComponentProbe, 'Fill', True);

  Add('X graphs', 'a cycle A -> B -> A', TCycleProbe);
  Allow('*', 'no format here has a back-reference, and a cycle is refused ' +
    'rather than cut');
  Add('X graphs', 'one child shared by two parents', TSharedProbe);
  Add('Y empties', 'nil, empty, zero, false, default, no value', TEmptyProbe);
  Allow('Csv', CSV_COLLECTION);
end;

{ ===========================================================================
  THE RUN
  =========================================================================== }

function Key(const APName: string; F: TSerializationFormat): string;
begin
  Result := APName + '|' + Name(F);
end;

var
  P: TProbe;
  F: TSerializationFormat;
  C: TCell;
  Row: string;
  Report, Details: TStringList;
  Counts: array[TOutcome] of Integer;
  O: TOutcome;
begin
  Ctx := TRttiContext.Create;
  Probes := TList<TProbe>.Create;
  Cells := TDictionary<string, TCell>.Create;
  Report := TStringList.Create;
  Details := TStringList.Create;
  try
    RegisterProbes;
    Formats := TSerialization.ContractFormats;
    for O := Low(TOutcome) to High(TOutcome) do Counts[O] := 0;

    Row := '| family | probe |';
    for F in Formats do Row := Row + ' ' + Name(F) + ' |';
    Report.Add(Row);
    Row := '| --- | --- |';
    for F in Formats do Row := Row + ' --- |';
    Report.Add(Row);

    for P in Probes do
    begin
      if (GetEnvironmentVariable('TC_ONLY') <> '') and
         (Pos(GetEnvironmentVariable('TC_ONLY'), P.Name) = 0) then Continue;
      Row := '| ' + P.Family + ' | ' + P.Name + ' |';
      for F in Formats do
      begin
        if (GetEnvironmentVariable('TC_FORMAT') <> '') and
           not SameText(GetEnvironmentVariable('TC_FORMAT'), Name(F)) then
          Continue;
        { Written as it happens, so a cell that takes the process down
          still leaves the one before it on the screen. }
        Write(Format('  %-45s %-12s ', [P.Name, Name(F)]));
        Flush(Output);
        C := RunCell(P, F);
        if (C.Outcome = TOutcome.Refused) and not MayRefuse(P, F) then
          C.Outcome := TOutcome.Unexpected;
        Writeln(OUTCOME_TEXT[C.Outcome], '  ', Copy(C.Detail, 1, 200));
        Flush(Output);
        Cells.AddOrSetValue(Key(P.Name, F), C);
        Inc(Counts[C.Outcome]);
        Row := Row + ' ' + OUTCOME_TEXT[C.Outcome] + ' |';
        if C.Outcome <> TOutcome.Ok then
          Details.Add(Format('%-8s %-12s %-45s %s',
            [OUTCOME_TEXT[C.Outcome], Name(F), P.Name, Copy(C.Detail, 1, 220)]));
      end;
      Report.Add(Row);
      Writeln(Row);
    end;

    Writeln;
    Writeln('-- every cell that is not ok --');
    for Row in Details do Writeln(Row);

    Writeln;
    Writeln('PROBES=', Probes.Count);
    Writeln('FORMATS=', Length(Formats));
    Writeln('CELLS=', Probes.Count * Length(Formats));
    for O := Low(TOutcome) to High(TOutcome) do
      Writeln('CELLS_', UpperCase(OUTCOME_TEXT[O]), '=', Counts[O]);
    Writeln('MANAGED_INITS=', GManagedInits);
    Writeln('MANAGED_FINALS=', GManagedFinals);
    Writeln('MANAGED_ASSIGNS=', GManagedAssigns);
    Writeln('PROC_EVER_CALLED=', BoolToStr(GProcCalled, True));

    { One probe per process writes nothing shared: the runner collects the
      streamed lines, and several processes writing one file is how the first
      isolated run tripped over itself. }
    if (GetEnvironmentVariable('TC_ONLY') = '') and
       (GetEnvironmentVariable('TC_FORMAT') = '') then
    begin
    ForceDirectories('..\..\artifacts');
    Report.SaveToFile('..\..\artifacts\type-coverage-matrix.md', TEncoding.UTF8);
    Details.SaveToFile('..\..\artifacts\type-coverage-details.txt', TEncoding.UTF8);
    end;
  finally
    Details.Free;
    Report.Free;
    Cells.Free;
    Probes.Free;
  end;
end.
