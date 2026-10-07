{*******************************************************************************
  PascalForge.DataSet.Packet

  INTERNAL IMPLEMENTATION UNIT - applications should not use this unit directly.

  Implements the format-neutral DataSet packet: building, detecting and
  applying the snapshot and delta trees that every format writes for a
  DataSet.
  Exposed through the public facade PascalForge.DataSet (TDataSetSerializer)
  and used by PascalForge.DataSet.Json for TDataSet members.

  Registration
    None here. The format that encodes the tree is reached through the
    registry and must be registered explicitly by the application.

  Documentation
    docs/dataset-formats.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.DataSet.Packet;

{$SCOPEDENUMS ON}

{ ---------------------------------------------------------------------------
  THE DATASET PACKET, IN THE DYNAMIC STRUCTURAL TREE

  A DataSet is not an encoded representation - it is a live object with a
  cursor, an edit state and a schema - so it is not a value of
  TSerializationFormat. But a DataSet's CONTENTS can be written into any
  format the registry knows, and this unit is the one place that decides what
  that document looks like.

  It builds, and reads, a format-dynamic tree. Nothing here knows that JSON
  exists. The caller hands the tree to whichever format handler it wants, and
  every format gets the same packet:

      snapshot with structure
        fields        a list of column definitions, each with a name, a
                      type, a size, a required flag and, for a nested
                      table, its own children
        rows          a list of objects, one per row, keyed by column name
        dataSetName   optional

      snapshot without structure
        the rows list alone

      delta
        Fields        optional, as above
        Delta         a list of changes, each with a State of Inserted,
                      Modified or Deleted, and an Original or
                      Current object

  That shape was already the shape this library wrote for JSON, and it has
  not changed: the same documents that round-tripped before still do. What
  changed is that it is no longer JSON's shape - it is the DataSet
  subsystem's, and XML, BSON and everything added later write it too.

  WHY THESE MEMBER NAMES

  "fields", "rows", "name", "type", "size", "required" are ordinary words
  that describe what they hold. That matters for more than readability: the
  detector at the bottom of this unit has to recognize a packet by its
  STRUCTURE, with no library signature to look for, because a document
  produced by somebody else's tooling that genuinely describes a table
  should be readable as one. There is no marker, no namespace and no version
  member to match on - only the shape.
  --------------------------------------------------------------------------- }

interface

uses
  System.SysUtils, System.Classes, System.Variants, System.DateUtils,
  System.TypInfo, System.Generics.Collections,
  Data.DB, FireDAC.Comp.Client, FireDAC.Comp.DataSet, FireDAC.DatS,
  Datasnap.DBClient,
  PascalForge.Serialization.Core, PascalForge.Dynamic, PascalForge.DataSet;

type
  EDataSetPacketError = class(Exception);
{ --- detecting ----------------------------------------------------------- }

{ Does this tree carry a DataSet schema of its own? Runs on the DYNAMIC TREE,
  after the source format has parsed itself and before anything
  DataSet-specific happens, so there is exactly one implementation of the
  rule and JSON, XML and BSON cannot drift apart on it. }
function ClassifyPacket(ARoot: TDynamicValue): TDataSetMetadataMatch;
{ Why ClassifyPacket said what it said, in one sentence, for the error
  message and for a user interface that wants to show it. }
function ExplainPacket(ARoot: TDynamicValue): string;
{ True for the change-list shape rather than the table shape. }
function PacketIsDelta(ARoot: TDynamicValue): Boolean;

{ --- writing ------------------------------------------------------------- }

{ The packet for ADataSet, as a tree the caller owns. }
function DataSetToPacket(ADataSet: TDataSet;
  APolicy: TDataSetSerializationPolicy; AIncludeName: Boolean = False): TDynamicValue;

{ --- reading ------------------------------------------------------------- }

{ The row member that holds a DataSet column's value. A DataSet field name is
  case-insensitive - FieldByName('ID') finds a field called 'Id' - so a row
  member is matched the same way: the exact spelling first, then the first
  member whose name differs only in case. This is DataSet semantics, kept
  here; the dynamic tree's own Find is exact. }
function FindFieldMember(ARow: TDynamicValue; const AFieldName: string): TDynamicValue;

{ Applies a packet whose schema Classify called ValidMetadata. ADataSet is
  closed, rebuilt from the packet's field defs and filled from its rows. }
procedure PacketToDataSet(ARoot: TDynamicValue; ADataSet: TDataSet);

{ The field defs alone, for a caller that wants to show the schema without
  building the table. }
procedure PacketFieldDefs(ARoot: TDynamicValue; ADefs: TFieldDefs);

{ The change-list form, replayed onto ADataSet so that its own change
  journal ends up holding the same changes. }
procedure PacketDeltaToDataSet(ARoot: TDynamicValue; ADataSet: TDataSet);

{ The rows-only form, onto a DataSet that already has a schema. }
procedure PacketRowsToDataSet(ARows: TDynamicValue; ADataSet: TDataSet);

{ Reads a packet whose SHAPE the caller already knows, because they asked
  for it with that policy. Where the mode-driven entry points ask the
  document what it is, this one is told. }
procedure ApplyPacket(ARoot: TDynamicValue; ADataSet: TDataSet;
  APolicy: TDataSetSerializationPolicy);

implementation

uses
  PascalForge.DataSet.Internal;

{ Text to the nearest double; not a number raises EConvertError, which the
  callers already turn into a named packet error. }
function PacketFloat(const AText: string): Double;
begin
  if not TStructuralText.TryParseFloat(AText, Result) then
    raise EConvertError.CreateFmt('''%s'' is not a valid floating point value',
      [AText]);
end;

const
  MEMBER_FIELDS      = 'fields';
  MEMBER_ROWS        = 'rows';
  MEMBER_NAME        = 'name';
  MEMBER_TYPE        = 'type';
  MEMBER_SIZE        = 'size';
  MEMBER_REQUIRED    = 'required';
  MEMBER_CHILDREN    = 'children';
  MEMBER_DATASETNAME = 'dataSetName';

  { The delta packet's members keep their original capitalisation: these
    documents have been in use since before this unit existed and renaming
    them would break every stored one. }
  MEMBER_DELTA_FIELDS = 'Fields';
  MEMBER_DELTA        = 'Delta';
  MEMBER_STATE        = 'State';
  MEMBER_ORIGINAL     = 'Original';
  MEMBER_CURRENT      = 'Current';

  STATE_INSERTED = 'Inserted';
  STATE_MODIFIED = 'Modified';
  STATE_DELETED  = 'Deleted';

type
  TFDMemTableAccess = class(TFDMemTable)
  public
    function NativeUpdates: TFDDatSUpdatesJournal;
  end;

function TFDMemTableAccess.NativeUpdates: TFDDatSUpdatesJournal;
begin
  Result := Updates;
end;

threadvar
  GActiveDataSets: TDictionary<TDataSet, Byte>;
  GPacketDepth: Integer;

{ ===========================================================================
  VALUES

  A column's value becomes one of five dynamic kinds and no more: null,
  boolean, integer, float, string. Not binary and not a timestamp - and that
  is deliberate.

  A DataSet's field types are Delphi's, not the document's. ftDateTime is
  written as ISO-8601 TEXT because that is what every consumer of one of
  these documents has always received, and because a dynamic timestamp would
  be written differently by each destination - BSON would make it a native
  UTC datetime, XML a marked element - which would mean the same table
  produced three incompatible documents. One spelling, everywhere.
  =========================================================================== }

function FieldValueToDynamic(AField: TField): TDynamicValue;
begin
  if AField.IsNull then Exit(TDynamicValue.NewNull);
  case AField.DataType of
    ftSmallint, ftInteger, ftWord, ftAutoInc, ftLargeint, ftShortint, ftByte:
      Result := TDynamicValue.NewInt(AField.AsLargeInt);
    ftFloat, ftCurrency, ftBCD, ftFMTBcd, ftSingle, ftExtended:
      Result := TDynamicValue.NewFloat(AField.AsFloat);
    ftBoolean: Result := TDynamicValue.NewBool(AField.AsBoolean);
    { A FIELD CARRIES ITS OWN TYPE, so this is the source format stating the
      semantic rather than anything guessing at text. ftDate is a day and
      becomes one; only a string column stays a string. }
    ftDate: Result := TDynamicValue.NewDate(AField.AsDateTime);
    ftTime: Result := TDynamicValue.NewTime(AField.AsDateTime);
    ftDateTime, ftTimeStamp, ftTimeStampOffset:
      Result := TDynamicValue.NewDateTime(AField.AsDateTime);
  else
    Result := TDynamicValue.NewStr(AField.AsString);
  end;
end;

function VariantFieldValueToDynamic(AField: TField;
  const AValue: Variant): TDynamicValue;
begin
  if VarIsEmpty(AValue) or VarIsNull(AValue) then Exit(TDynamicValue.NewNull);
  case AField.DataType of
    ftSmallint, ftInteger, ftWord, ftAutoInc, ftLargeint, ftLongWord,
    ftShortint, ftByte: Result := TDynamicValue.NewInt(AValue);
    ftFloat, ftCurrency, ftBCD, ftFMTBcd, ftSingle, ftExtended:
      Result := TDynamicValue.NewFloat(AValue);
    ftBoolean: Result := TDynamicValue.NewBool(Boolean(AValue));
    ftDate: Result := TDynamicValue.NewDate(VarToDateTime(AValue));
    ftTime: Result := TDynamicValue.NewTime(VarToDateTime(AValue));
    ftDateTime, ftTimeStamp, ftTimeStampOffset:
      Result := TDynamicValue.NewDateTime(VarToDateTime(AValue));
  else
    Result := TDynamicValue.NewStr(VarToStr(AValue));
  end;
end;

{ The lexical form of a dynamic value, which is what a field assignment
  parses. Exactly the text the source format would have written. }
function DynamicLexical(AValue: TDynamicValue): string;
begin
  case AValue.Kind of
    TDynamicKind.Bool:
      if AValue.AsBool then Result := 'true' else Result := 'false';
    TDynamicKind.Int:   Result := IntToStr(AValue.AsInt);
    TDynamicKind.UInt:  Result := UIntToStr(AValue.AsUInt);
    TDynamicKind.Decimal: Result := AValue.AsDecimal;
    TDynamicKind.Float: Result := TStructuralText.EncodeFloat(AValue.AsFloat);
    TDynamicKind.Str:   Result := AValue.AsStr;
    TDynamicKind.Bytes: Result := TStructuralText.EncodeBinary(AValue.AsBytes);
    TDynamicKind.Date: Result := TStructuralText.EncodeDate(AValue.AsDateTime);
    TDynamicKind.Time: Result := TStructuralText.EncodeTime(AValue.AsDateTime);
    { No zone: the value has none, and a Z claimed UTC for it. }
    TDynamicKind.DateTime:
      Result := TStructuralText.EncodeDateTime(AValue.AsDateTime);
  else
    Result := AValue.Describe;
  end;
end;

procedure AssignDynamicField(AField: TField; AValue: TDynamicValue);
var
  Text: string;
  Moment: TDateTime;
begin
  if (AValue = nil) or (AValue.Kind = TDynamicKind.Null) then
  begin
    AField.Clear;
    Exit;
  end;
  Text := DynamicLexical(AValue);
  try
    case AField.DataType of
      ftSmallint, ftInteger, ftWord, ftAutoInc, ftShortint, ftByte:
        AField.AsInteger := StrToInt(Text);
      ftLargeint: AField.AsLargeInt := StrToInt64(Text);
      { The correctly rounded reader: StrToFloat misreads 17-digit text on
        Win64, where it computes in Double. }
      ftFloat, ftBCD, ftFMTBcd, ftSingle, ftExtended:
        AField.AsFloat := PacketFloat(Text);
      ftCurrency: AField.AsCurrency := StrToCurr(Text, TFormatSettings.Invariant);
      ftBoolean: AField.AsBoolean := SameText(Text, 'true');
      ftDate, ftTime, ftDateTime, ftTimeStamp, ftTimeStampOffset:
        { The reduced ISO forms first, because ISO8601ToDate wants a full
          one and a date-only column is written as a date only. }
        if not (TStructuralText.TryDecodeDate(Text, Moment) or
                TStructuralText.TryDecodeTime(Text, Moment)) then
          AField.AsDateTime := TStructuralText.DecodeIso8601(Text)
        else
          AField.AsDateTime := Moment;
    else
      AField.AsString := Text;
    end;
  except
    { A conversion failure here is caused by the incoming value, and only by
      it. Naming the field and the value turns an anonymous
      '"abc" is not a valid integer value' into something a caller can act
      on. A rejection from the dataset ITSELF - a required field, a range
      violation, a dataset in the wrong state - propagates unchanged,
      because those are not reliably attributable to this one value. }
    on E: EConvertError do
      raise EDataSetPacketError.CreateFmt(
        'Cannot convert value "%s" to field %s (%s): %s',
        [Text, AField.FieldName,
         GetEnumName(System.TypeInfo(TFieldType), Ord(AField.DataType)),
         E.Message]);
  end;
end;

{ ===========================================================================
  WRITING
  =========================================================================== }

procedure AddFieldDefs(AFieldDefs: TFieldDefs; AFields: TDynamicValue);
var
  I: Integer;
  O, Children: TDynamicValue;
begin
  for I := 0 to AFieldDefs.Count - 1 do
  begin
    O := TDynamicValue.NewObject;
    AFields.AsArray.Adopt(O);
    O.AsObject.Adopt(MEMBER_NAME, TDynamicValue.NewStr(AFieldDefs[I].Name));
    O.AsObject.Adopt(MEMBER_TYPE, TDynamicValue.NewInt(Ord(AFieldDefs[I].DataType)));
    O.AsObject.Adopt(MEMBER_SIZE, TDynamicValue.NewInt(AFieldDefs[I].Size));
    O.AsObject.Adopt(MEMBER_REQUIRED, TDynamicValue.NewBool(AFieldDefs[I].Required));
    if AFieldDefs[I].DataType = ftDataSet then
    begin
      Children := TDynamicValue.NewArray;
      O.AsObject.Adopt(MEMBER_CHILDREN, Children);
      AddFieldDefs(AFieldDefs[I].ChildDefs, Children);
    end;
  end;
end;

function DataSetRowsToPacket(ADataSet: TDataSet;
  APolicy: TDataSetSerializationPolicy): TDynamicValue; forward;

function ClientDataSetDelta(ADataSet: TClientDataSet): TDynamicValue;
var
  OldFilter: TUpdateStatusSet;
  Row, Original, Current: TDynamicValue;
  I: Integer;
  OldValue, NewValue: Variant;
  Changed: Boolean;
begin
  Result := TDynamicValue.NewArray;
  OldFilter := ADataSet.StatusFilter;
  ADataSet.StatusFilter := [usModified, usInserted, usDeleted];
  try
    ADataSet.First;
    while not ADataSet.Eof do
    begin
      if ADataSet.UpdateStatus <> usUnmodified then
      begin
        Row := TDynamicValue.NewObject;
        Original := nil;
        Current := nil;
        Changed := False;
        case ADataSet.UpdateStatus of
          usInserted:
            begin
              Row.AsObject.Adopt(MEMBER_STATE, TDynamicValue.NewStr(STATE_INSERTED));
              Current := TDynamicValue.NewObject;
            end;
          usDeleted:
            begin
              Row.AsObject.Adopt(MEMBER_STATE, TDynamicValue.NewStr(STATE_DELETED));
              Original := TDynamicValue.NewObject;
            end;
          usModified:
            begin
              Row.AsObject.Adopt(MEMBER_STATE, TDynamicValue.NewStr(STATE_MODIFIED));
              Original := TDynamicValue.NewObject;
              Current := TDynamicValue.NewObject;
            end;
        end;
        for I := 0 to ADataSet.FieldCount - 1 do
        begin
          OldValue := ADataSet.Fields[I].OldValue;
          NewValue := ADataSet.Fields[I].NewValue;
          if Original <> nil then
            Original.AsObject.Adopt(ADataSet.Fields[I].FieldName,
              VariantFieldValueToDynamic(ADataSet.Fields[I], OldValue));
          if (ADataSet.UpdateStatus = usInserted) or
             ((ADataSet.UpdateStatus = usModified) and
              not VarSameValue(OldValue, NewValue)) then
          begin
            Current.AsObject.Adopt(ADataSet.Fields[I].FieldName,
              VariantFieldValueToDynamic(ADataSet.Fields[I], NewValue));
            Changed := True;
          end;
        end;
        if (ADataSet.UpdateStatus <> usModified) or Changed then
        begin
          if Original <> nil then Row.AsObject.Adopt(MEMBER_ORIGINAL, Original);
          if Current <> nil then Row.AsObject.Adopt(MEMBER_CURRENT, Current);
          Result.AsArray.Adopt(Row);
        end
        else
        begin
          Original.Free;
          Current.Free;
          Row.Free;
        end;
      end;
      ADataSet.Next;
    end;
  finally
    ADataSet.StatusFilter := OldFilter;
  end;
end;

function FDMemTableDelta(ADataSet: TFDMemTable): TDynamicValue;
var
  Journal: TFDDatSUpdatesJournal;
  R: TFDDatSRow;
  Row, Original, Current: TDynamicValue;
  I: Integer;
  V: Variant;
  Changed: Boolean;
begin
  Result := TDynamicValue.NewArray;
  Journal := TFDMemTableAccess(ADataSet).NativeUpdates;
  if Journal = nil then Exit;
  R := Journal.FirstChange;
  while R <> nil do
  begin
    Row := TDynamicValue.NewObject;
    Original := nil;
    Current := nil;
    Changed := False;
    case R.RowState of
      rsInserted:
        begin
          Row.AsObject.Adopt(MEMBER_STATE, TDynamicValue.NewStr(STATE_INSERTED));
          Current := TDynamicValue.NewObject;
        end;
      rsDeleted:
        begin
          Row.AsObject.Adopt(MEMBER_STATE, TDynamicValue.NewStr(STATE_DELETED));
          Original := TDynamicValue.NewObject;
        end;
    else
      Row.AsObject.Adopt(MEMBER_STATE, TDynamicValue.NewStr(STATE_MODIFIED));
      Original := TDynamicValue.NewObject;
      Current := TDynamicValue.NewObject;
    end;
    for I := 0 to ADataSet.FieldCount - 1 do
    begin
      if Original <> nil then
      begin
        V := R.GetData(I, rvOriginal);
        Original.AsObject.Adopt(ADataSet.Fields[I].FieldName,
          VariantFieldValueToDynamic(ADataSet.Fields[I], V));
      end;
      if Current <> nil then
      begin
        V := R.GetData(I, rvCurrent);
        Current.AsObject.Adopt(ADataSet.Fields[I].FieldName,
          VariantFieldValueToDynamic(ADataSet.Fields[I], V));
        Changed := True;
      end;
    end;
    if Original <> nil then Row.AsObject.Adopt(MEMBER_ORIGINAL, Original);
    if Current <> nil then Row.AsObject.Adopt(MEMBER_CURRENT, Current);
    if Changed or (Current = nil) then Result.AsArray.Adopt(Row)
    else Row.Free;
    R := Journal.NextChange(R);
  end;
end;

function DataSetRowsToPacket(ADataSet: TDataSet;
  APolicy: TDataSetSerializationPolicy): TDynamicValue;
var
  Row: TDynamicValue;
  I: Integer;
  F: TField;
  Bookmark: TBookmark;
begin
  Result := TDynamicValue.NewArray;
  if (ADataSet = nil) or not ADataSet.Active then Exit;
  Bookmark := ADataSet.GetBookmark;
  ADataSet.DisableControls;
  try
    ADataSet.First;
    while not ADataSet.Eof do
    begin
      Row := TDynamicValue.NewObject;
      Result.AsArray.Adopt(Row);
      for I := 0 to ADataSet.FieldCount - 1 do
      begin
        F := ADataSet.Fields[I];
        if F.DataType = ftDataSet then
          Row.AsObject.Adopt(F.FieldName,
            DataSetToPacket(TDataSetField(F).NestedDataSet, APolicy))
        else
          Row.AsObject.Adopt(F.FieldName, FieldValueToDynamic(F));
      end;
      ADataSet.Next;
    end;
    if ADataSet.BookmarkValid(Bookmark) then ADataSet.GotoBookmark(Bookmark);
  finally
    ADataSet.EnableControls;
    ADataSet.FreeBookmark(Bookmark);
  end;
end;

function DataSetToPacket(ADataSet: TDataSet;
  APolicy: TDataSetSerializationPolicy; AIncludeName: Boolean): TDynamicValue;
var
  O, Fields: TDynamicValue;
begin
  if ADataSet = nil then Exit(TDynamicValue.NewNull);
  if GPacketDepth = 0 then
    GActiveDataSets := TDictionary<TDataSet, Byte>.Create;
  Inc(GPacketDepth);
  try
    { A nested DataSet that points back at an ancestor would recurse for
      ever. It becomes null, which is what the JSON path has always done. }
    if GActiveDataSets.ContainsKey(ADataSet) then Exit(TDynamicValue.NewNull);
    GActiveDataSets.Add(ADataSet, 0);
    try
      if APolicy in [TDataSetSerializationPolicy.DeltaOnly,
                     TDataSetSerializationPolicy.DeltaAndStructure] then
      begin
        O := TDynamicValue.NewObject;
        try
          if APolicy = TDataSetSerializationPolicy.DeltaAndStructure then
          begin
            Fields := TDynamicValue.NewArray;
            O.AsObject.Adopt(MEMBER_DELTA_FIELDS, Fields);
            AddFieldDefs(ADataSet.FieldDefs, Fields);
          end;
          if ADataSet is TClientDataSet then
            O.AsObject.Adopt(MEMBER_DELTA, ClientDataSetDelta(TClientDataSet(ADataSet)))
          else if ADataSet is TFDMemTable then
            O.AsObject.Adopt(MEMBER_DELTA, FDMemTableDelta(TFDMemTable(ADataSet)))
          else
            raise EDataSetPacketError.CreateFmt(
              'A delta packet needs a DataSet that keeps a change journal. ' +
              '%s does not: use TFDMemTable or TClientDataSet, or ask for a ' +
              'snapshot instead.', [ADataSet.ClassName]);
        except
          O.Free;
          raise;
        end;
        Exit(O);
      end;

      if APolicy = TDataSetSerializationPolicy.RowsOnly then
        Exit(DataSetRowsToPacket(ADataSet, APolicy));

      O := TDynamicValue.NewObject;
      try
        Fields := TDynamicValue.NewArray;
        O.AsObject.Adopt(MEMBER_FIELDS, Fields);
        AddFieldDefs(ADataSet.FieldDefs, Fields);
        O.AsObject.Adopt(MEMBER_ROWS, DataSetRowsToPacket(ADataSet, APolicy));
        if AIncludeName then
          O.AsObject.Adopt(MEMBER_DATASETNAME, TDynamicValue.NewStr(ADataSet.Name));
      except
        O.Free;
        raise;
      end;
      Result := O;
    finally
      GActiveDataSets.Remove(ADataSet);
    end;
  finally
    Dec(GPacketDepth);
    if GPacketDepth = 0 then
    begin
      GActiveDataSets.Free;
      GActiveDataSets := nil;
    end;
  end;
end;

{ ===========================================================================
  DETECTING
  =========================================================================== }

{ ---------------------------------------------------------------------------
  READING A PACKET THAT CAME BACK THROUGH A FORMAT WITH FEWER TYPES

  A packet written as JSON or BSON comes back with its numbers as numbers and
  its lists as lists. A packet written as XML does not, and cannot: XML text
  is text, so every field type arrives as the string "3" rather than the
  number 3; and XML writes a list as repeated sibling elements, so a list of
  ONE is indistinguishable from a single element.

  Neither is a defect in the packet - they are what XML is - so the reader
  accommodates both rather than declaring a perfectly good document invalid.
  The values it accepts are still exactly the values the packet defines; only
  their spelling is allowed to vary.
  --------------------------------------------------------------------------- }

{ A member that should be a list, seen as one however the format wrote it.
  Returns -1 when it is not list-shaped at all. }
function FindFieldMember(ARow: TDynamicValue; const AFieldName: string): TDynamicValue;
var
  I: Integer;
begin
  Result := nil;
  if (ARow = nil) or (ARow.Kind <> TDynamicKind.Obj) then Exit;
  Result := ARow.Find(AFieldName);
  if Result <> nil then Exit;
  for I := 0 to ARow.Count - 1 do
    if SameText(ARow.Names[I], AFieldName) then Exit(ARow[I]);
end;

function ListCount(AValue: TDynamicValue): Integer;
begin
  if AValue = nil then Exit(-1);
  case AValue.Kind of
    TDynamicKind.Arr: Result := AValue.Count;
    { A list of one, written by a format that has no lists. }
    TDynamicKind.Obj: Result := 1;
  else
    Result := -1;
  end;
end;

function ListItem(AValue: TDynamicValue; AIndex: Integer): TDynamicValue;
begin
  if AValue.Kind = TDynamicKind.Arr then Result := AValue[AIndex]
  else Result := AValue;
end;

{ An integer however it is spelled. False for anything that is not one. }
function AsInteger(AValue: TDynamicValue; out AResult: Int64): Boolean;
begin
  AResult := 0;
  if AValue = nil then Exit(False);
  if AValue.Kind = TDynamicKind.Int then
  begin
    AResult := AValue.AsInt;
    Exit(True);
  end;
  if AValue.Kind = TDynamicKind.Str then
    Exit(TryStrToInt64(Trim(AValue.AsStr), AResult));
  Result := False;
end;

function AsBoolean(AValue: TDynamicValue; out AResult: Boolean): Boolean;
var
  Text: string;
begin
  AResult := False;
  if AValue = nil then Exit(False);
  if AValue.Kind = TDynamicKind.Bool then
  begin
    AResult := AValue.AsBool;
    Exit(True);
  end;
  if AValue.Kind <> TDynamicKind.Str then Exit(False);
  Text := Trim(AValue.AsStr);
  if SameText(Text, 'true') or (Text = '1') then
  begin
    AResult := True;
    Exit(True);
  end;
  if SameText(Text, 'false') or (Text = '0') then Exit(True);
  Result := False;
end;

{ Does this array LOOK LIKE a list of field definitions? Every item an
  object, every object carrying both a name and a type. Deliberately weaker
  than the full check below: this is the question "is the document claiming
  to be a schema", and the full check is the question "is the claim true". }
function ClaimsToBeFieldDefs(AFields: TDynamicValue): Boolean;
var
  I, N: Integer;
  Def: TDynamicValue;
begin
  N := ListCount(AFields);
  if N <= 0 then Exit(False);
  for I := 0 to N - 1 do
  begin
    Def := ListItem(AFields, I);
    if Def.Kind <> TDynamicKind.Obj then Exit(False);
    if Def.Find(MEMBER_NAME) = nil then Exit(False);
    if Def.Find(MEMBER_TYPE) = nil then Exit(False);
  end;
  Result := True;
end;

{ The complete check. AReason is set for the first thing that fails. }
function FieldDefsValid(AFields: TDynamicValue; out AReason: string): Boolean;
var
  I: Integer;
  Def, Member: TDynamicValue;
  Number: Int64;
  Flag: Boolean;
  Name: string;
begin
  AReason := '';
  for I := 0 to ListCount(AFields) - 1 do
  begin
    Def := ListItem(AFields, I);

    Member := Def.Find(MEMBER_NAME);
    if (Member.Kind <> TDynamicKind.Str) or (Member.AsStr = '') then
    begin
      AReason := Format('field %d has no usable name', [I]);
      Exit(False);
    end;
    Name := Member.AsStr;

    if not AsInteger(Def.Find(MEMBER_TYPE), Number) then
    begin
      AReason := Format('field "%s" has a type that is not a number', [Name]);
      Exit(False);
    end;
    if (Number < Ord(Low(TFieldType))) or (Number > Ord(High(TFieldType))) then
    begin
      AReason := Format('field "%s" has type %d, which is not a field type',
        [Name, Number]);
      Exit(False);
    end;

    Member := Def.Find(MEMBER_SIZE);
    if (Member <> nil) and not AsInteger(Member, Number) then
    begin
      AReason := Format('field "%s" has a size that is not a number', [Name]);
      Exit(False);
    end;

    Member := Def.Find(MEMBER_REQUIRED);
    if (Member <> nil) and not AsBoolean(Member, Flag) then
    begin
      AReason := Format('field "%s" has a required flag that is not a boolean',
        [Name]);
      Exit(False);
    end;

    Member := Def.Find(MEMBER_CHILDREN);
    if Member <> nil then
    begin
      if not ClaimsToBeFieldDefs(Member) then
      begin
        AReason := Format('the nested table under "%s" is not a schema',
          [Name]);
        Exit(False);
      end;
      if not FieldDefsValid(Member, AReason) then Exit(False);
    end;
  end;
  Result := True;
end;

function ClassifyWithReason(ARoot: TDynamicValue;
  out AReason: string): TDataSetMetadataMatch;
var
  Fields, Rows, Delta, Change: TDynamicValue;
  I: Integer;
  State: string;
begin
  AReason := 'the document does not describe a table';
  if (ARoot = nil) or (ARoot.Kind <> TDynamicKind.Obj) then
  begin
    AReason := 'the document is not an object, so it carries no schema';
    Exit(TDataSetMetadataMatch.NotMetadata);
  end;

  { --- the delta shape -------------------------------------------------- }
  Delta := ARoot.Find(MEMBER_DELTA);
  if (Delta <> nil) and (ListCount(Delta) >= 0) then
  begin
    Fields := ARoot.Find(MEMBER_DELTA_FIELDS);
    if (Fields <> nil) and (ListCount(Fields) < 0) then Fields := nil;
    if Fields = nil then
    begin
      AReason := 'the change list has no schema in front of it';
      Exit(TDataSetMetadataMatch.InvalidMetadata);
    end;
    if not ClaimsToBeFieldDefs(Fields) then
    begin
      AReason := 'the Fields list is not a list of field definitions';
      Exit(TDataSetMetadataMatch.InvalidMetadata);
    end;
    if not FieldDefsValid(Fields, AReason) then
      Exit(TDataSetMetadataMatch.InvalidMetadata);
    for I := 0 to ListCount(Delta) - 1 do
    begin
      Change := ListItem(Delta, I);
      if Change.Kind <> TDynamicKind.Obj then
      begin
        AReason := Format('change %d is not an object', [I]);
        Exit(TDataSetMetadataMatch.InvalidMetadata);
      end;
      if (Change.Find(MEMBER_STATE) = nil) or
         (Change.Find(MEMBER_STATE).Kind <> TDynamicKind.Str) then
      begin
        AReason := Format('change %d does not say what happened to it', [I]);
        Exit(TDataSetMetadataMatch.InvalidMetadata);
      end;
      State := Change.Find(MEMBER_STATE).AsStr;
      if (State <> STATE_INSERTED) and (State <> STATE_MODIFIED) and
         (State <> STATE_DELETED) then
      begin
        AReason := Format('change %d has state "%s", which is not one of ' +
          'Inserted, Modified or Deleted', [I, State]);
        Exit(TDataSetMetadataMatch.InvalidMetadata);
      end;
    end;
    AReason := Format('a change list of %d rows over %d columns',
      [ListCount(Delta), ListCount(Fields)]);
    Exit(TDataSetMetadataMatch.ValidMetadata);
  end;

  { --- the snapshot shape ------------------------------------------------ }
  Fields := ARoot.Find(MEMBER_FIELDS);
  Rows := ARoot.Find(MEMBER_ROWS);
  if (Fields = nil) or (Rows = nil) then
  begin
    AReason := 'the document has no fields and rows pair, so its schema ' +
      'has to be inferred';
    Exit(TDataSetMetadataMatch.NotMetadata);
  end;

  { Two members with those names but the wrong shapes are data that happens
    to be spelled that way, not a broken schema. }
  if not ClaimsToBeFieldDefs(Fields) then
  begin
    AReason := 'the fields member is not a list of field definitions, so ' +
      'this is ordinary data';
    Exit(TDataSetMetadataMatch.NotMetadata);
  end;
  if ListCount(Rows) < 0 then
  begin
    AReason := 'the fields member describes columns but the rows member ' +
      'is not a list';
    Exit(TDataSetMetadataMatch.InvalidMetadata);
  end;

  if not FieldDefsValid(Fields, AReason) then
    Exit(TDataSetMetadataMatch.InvalidMetadata);

  for I := 0 to ListCount(Rows) - 1 do
    if ListItem(Rows, I).Kind <> TDynamicKind.Obj then
    begin
      AReason := Format('row %d is not an object', [I]);
      Exit(TDataSetMetadataMatch.InvalidMetadata);
    end;

  AReason := Format('a table of %d rows over %d columns',
    [ListCount(Rows), ListCount(Fields)]);
  Result := TDataSetMetadataMatch.ValidMetadata;
end;

function ClassifyPacket(ARoot: TDynamicValue): TDataSetMetadataMatch;
var
  Reason: string;
begin
  Result := ClassifyWithReason(ARoot, Reason);
end;

function ExplainPacket(ARoot: TDynamicValue): string;
begin
  ClassifyWithReason(ARoot, Result);
end;

function PacketIsDelta(ARoot: TDynamicValue): Boolean;
begin
  Result := (ARoot <> nil) and (ARoot.Kind = TDynamicKind.Obj) and
            (ListCount(ARoot.Find(MEMBER_DELTA)) >= 0);
end;

{ ===========================================================================
  READING
  =========================================================================== }

procedure BuildFieldDefs(AFields: TDynamicValue; ADefs: TFieldDefs);
var
  I: Integer;
  Def, Member: TDynamicValue;
  FD: TFieldDef;
  Number: Int64;
  Flag: Boolean;
begin
  for I := 0 to ListCount(AFields) - 1 do
  begin
    Def := ListItem(AFields, I);
    FD := ADefs.AddFieldDef;
    FD.Name := Def.Find(MEMBER_NAME).AsStr;
    AsInteger(Def.Find(MEMBER_TYPE), Number);
    FD.DataType := TFieldType(Number);
    if AsInteger(Def.Find(MEMBER_SIZE), Number) then
      FD.Size := Integer(Number);
    if AsBoolean(Def.Find(MEMBER_REQUIRED), Flag) then FD.Required := Flag;
    Member := Def.Find(MEMBER_CHILDREN);
    if (FD.DataType = ftDataSet) and (Member <> nil) then
      BuildFieldDefs(Member, FD.ChildDefs);
  end;
end;

procedure PacketFieldDefs(ARoot: TDynamicValue; ADefs: TFieldDefs);
var
  Fields: TDynamicValue;
  Reason: string;
begin
  if ClassifyWithReason(ARoot, Reason) <> TDataSetMetadataMatch.ValidMetadata then
    raise EDataSetPacketError.CreateFmt(
      'This document carries no usable DataSet schema: %s.', [Reason]);
  Fields := ARoot.Find(MEMBER_FIELDS);
  if Fields = nil then Fields := ARoot.Find(MEMBER_DELTA_FIELDS);
  ADefs.Clear;
  BuildFieldDefs(Fields, ADefs);
end;

procedure FillRows(ARows: TDynamicValue; ADataSet: TDataSet); forward;

procedure WriteRow(ARow: TDynamicValue; ADataSet: TDataSet);
var
  I: Integer;
  F: TField;
  Child: TDynamicValue;
begin
  for I := 0 to ADataSet.FieldCount - 1 do
  begin
    F := ADataSet.Fields[I];
    Child := FindFieldMember(ARow, F.FieldName);
    if (F.DataType = ftDataSet) and (Child <> nil) and
       (Child.Kind = TDynamicKind.Obj) then
      FillRows(Child.Find(MEMBER_ROWS), TDataSetField(F).NestedDataSet)
    else if F.DataType <> ftDataSet then
      AssignDynamicField(F, Child);
  end;
end;

procedure FillRows(ARows: TDynamicValue; ADataSet: TDataSet);
var
  I: Integer;
  Row: TDynamicValue;
begin
  for I := 0 to ListCount(ARows) - 1 do
  begin
    Row := ListItem(ARows, I);
    if Row.Kind <> TDynamicKind.Obj then Continue;
    ADataSet.Append;
    WriteRow(Row, ADataSet);
    ADataSet.Post;
  end;
end;

procedure PacketToDataSet(ARoot: TDynamicValue; ADataSet: TDataSet);
var
  Fields, Rows: TDynamicValue;
  Reason: string;
  ReuseSchema: Boolean;
begin
  if ADataSet = nil then Exit;
  if ClassifyWithReason(ARoot, Reason) <> TDataSetMetadataMatch.ValidMetadata then
    raise EDataSetPacketError.CreateFmt(
      'This document carries no usable DataSet schema: %s.', [Reason]);

  Fields := ARoot.Find(MEMBER_FIELDS);
  Rows := ARoot.Find(MEMBER_ROWS);
  if Fields = nil then
    raise EDataSetPacketError.Create(
      'This document is a change list rather than a table, so there are no ' +
      'rows to load. Read it with the delta API.');

  { A descendant of TFDCustomMemTable that is not a TFDMemTable - a live
    query result, say - keeps the schema it was opened with. }
  ReuseSchema := ADataSet.Active and (ADataSet is TFDCustomMemTable) and
    not (ADataSet is TFDMemTable);
  if not ReuseSchema then
  begin
    ADataSet.Close;
    ADataSet.FieldDefs.Clear;
    BuildFieldDefs(Fields, ADataSet.FieldDefs);
    TDataSetEngine.ActivateDataSet(ADataSet);
  end;
  FillRows(Rows, ADataSet);
  if not ADataSet.IsEmpty then ADataSet.First;
end;


procedure AssignObjectFields(ADataSet: TDataSet; AObject: TDynamicValue);
var
  I: Integer;
  F: TField;
  Child: TDynamicValue;
begin
  if (AObject = nil) or (AObject.Kind <> TDynamicKind.Obj) then Exit;
  for I := 0 to ADataSet.FieldCount - 1 do
  begin
    F := ADataSet.Fields[I];
    if F.DataType = ftDataSet then Continue;
    Child := FindFieldMember(AObject, F.FieldName);
    if Child <> nil then AssignDynamicField(F, Child);
  end;
end;

{ Does the row the cursor is on carry exactly the values AObject names? The
  delta reader uses this to find the row a change refers to, because a delta
  packet identifies rows by their contents and not by a key. }
function RowMatchesObject(ADataSet: TDataSet; AObject: TDynamicValue): Boolean;
var
  I: Integer;
  F: TField;
  V: TDynamicValue;
  Expected: Variant;
  Text: string;
begin
  if (AObject = nil) or (AObject.Kind <> TDynamicKind.Obj) then Exit(False);
  Result := True;
  for I := 0 to ADataSet.FieldCount - 1 do
  begin
    F := ADataSet.Fields[I];
    V := FindFieldMember(AObject, F.FieldName);
    if V = nil then Continue;
    if V.Kind = TDynamicKind.Null then Expected := Null
    else
    begin
      Text := DynamicLexical(V);
      case F.DataType of
        ftSmallint, ftInteger, ftWord, ftAutoInc, ftShortint, ftByte:
          Expected := StrToInt(Text);
        ftLargeint: Expected := StrToInt64(Text);
        ftFloat, ftBCD, ftFMTBcd, ftSingle, ftExtended:
          Expected := PacketFloat(Text);
        ftCurrency: Expected := StrToCurr(Text, TFormatSettings.Invariant);
        ftBoolean: Expected := SameText(Text, 'true');
        ftDate, ftTime, ftDateTime, ftTimeStamp, ftTimeStampOffset:
          Expected := TStructuralText.DecodeIso8601(Text);
      else
        Expected := Text;
      end;
    end;
    if not VarSameValue(F.Value, Expected) then Exit(False);
  end;
end;

procedure OpenIfClosed(ADataSet: TDataSet);
begin
  if ADataSet.Active then Exit;
  TDataSetEngine.ActivateDataSet(ADataSet);
end;

procedure PacketRowsToDataSet(ARows: TDynamicValue; ADataSet: TDataSet);
begin
  if ListCount(ARows) < 0 then
    raise EDataSetPacketError.Create(
      'A rows-only document has to be a list of rows.');
  if ADataSet.FieldDefs.Count = 0 then
    raise EDataSetPacketError.CreateFmt(
      'A rows-only document says nothing about columns, so %s needs a ' +
      'schema already. Give it one, or read the document with ' +
      'TDataSetSourceMode.InferStructure.', [ADataSet.ClassName]);
  OpenIfClosed(ADataSet);
  if ADataSet.RecordCount > 0 then
  begin
    if ADataSet is TFDCustomMemTable then
      TFDCustomMemTable(ADataSet).EmptyDataSet
    else if ADataSet is TClientDataSet then
      TClientDataSet(ADataSet).EmptyDataSet;
  end;
  FillRows(ARows, ADataSet);
end;

procedure PacketDeltaToDataSet(ARoot: TDynamicValue; ADataSet: TDataSet);
var
  Fields, Delta, Row, Original, Current: TDynamicValue;
  I: Integer;
  Baseline: TList<TDynamicValue>;
begin
  if (ARoot = nil) or (ARoot.Kind <> TDynamicKind.Obj) then
    raise EDataSetPacketError.Create(
      'A change list has to be an object with a Delta member.');
  Delta := ARoot.Find(MEMBER_DELTA);
  if (Delta = nil) or (ListCount(Delta) < 0) then
    raise EDataSetPacketError.Create(
      'A change list has to be an object with a Delta member.');

  Fields := ARoot.Find(MEMBER_DELTA_FIELDS);
  if (Fields <> nil) and (ListCount(Fields) < 0) then Fields := nil;
  if Fields <> nil then
  begin
    ADataSet.Close;
    ADataSet.FieldDefs.Clear;
    BuildFieldDefs(Fields, ADataSet.FieldDefs);
  end;
  if ADataSet.FieldDefs.Count = 0 then
    raise EDataSetPacketError.Create(
      'A change list with no schema in front of it needs a DataSet that ' +
      'already has one.');
  OpenIfClosed(ADataSet);

  { The journal has to be recording before the changes are replayed, or the
    result is a table with the right rows and no change list of its own. }
  if ADataSet is TFDMemTable then TFDMemTable(ADataSet).CachedUpdates := True;
  if ADataSet is TClientDataSet then TClientDataSet(ADataSet).LogChanges := True;

  Baseline := TList<TDynamicValue>.Create;
  try
    { Rebuild what the table looked like BEFORE the changes: every row that
      was modified or deleted, in its original form. }
    for I := 0 to ListCount(Delta) - 1 do
    begin
      Row := ListItem(Delta, I);
      if Row.Find(MEMBER_STATE).AsStr = STATE_INSERTED then Continue;
      Original := Row.Find(MEMBER_ORIGINAL);
      ADataSet.Append;
      AssignObjectFields(ADataSet, Original);
      ADataSet.Post;
      Baseline.Add(Row);
    end;
    { That baseline is the starting point, not a change, so it is committed
      before anything is replayed on top of it. }
    if ADataSet is TFDMemTable then TFDMemTable(ADataSet).CommitUpdates
    else if ADataSet is TClientDataSet then
      TClientDataSet(ADataSet).MergeChangeLog;

    for Row in Baseline do
    begin
      Original := Row.Find(MEMBER_ORIGINAL);
      ADataSet.First;
      while not ADataSet.Eof do
      begin
        if RowMatchesObject(ADataSet, Original) then Break;
        ADataSet.Next;
      end;
      if ADataSet.Eof then
        raise EDataSetPacketError.Create(
          'A change refers to a row that is not in the rebuilt table.');
      if Row.Find(MEMBER_STATE).AsStr = STATE_DELETED then ADataSet.Delete
      else
      begin
        Current := Row.Find(MEMBER_CURRENT);
        ADataSet.Edit;
        AssignObjectFields(ADataSet, Current);
        ADataSet.Post;
      end;
    end;

    for I := 0 to ListCount(Delta) - 1 do
    begin
      Row := ListItem(Delta, I);
      if Row.Find(MEMBER_STATE).AsStr <> STATE_INSERTED then Continue;
      Current := Row.Find(MEMBER_CURRENT);
      ADataSet.Append;
      AssignObjectFields(ADataSet, Current);
      ADataSet.Post;
    end;
  finally
    Baseline.Free;
  end;
end;

procedure ApplyPacket(ARoot: TDynamicValue; ADataSet: TDataSet;
  APolicy: TDataSetSerializationPolicy);
begin
  if (ARoot = nil) or (ARoot.Kind = TDynamicKind.Null) or
     (ADataSet = nil) then Exit;
  case APolicy of
    TDataSetSerializationPolicy.DeltaOnly,
    TDataSetSerializationPolicy.DeltaAndStructure:
      PacketDeltaToDataSet(ARoot, ADataSet);
    TDataSetSerializationPolicy.RowsOnly:
      PacketRowsToDataSet(ARoot, ADataSet);
  else
    if ARoot.Kind <> TDynamicKind.Obj then
      raise EDataSetPacketError.Create(
        'A structure-and-rows document has to be an object.');
    PacketToDataSet(ARoot, ADataSet);
  end;
end;

end.
