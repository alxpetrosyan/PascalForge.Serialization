{*******************************************************************************
  PascalForge.Serialization.Attributes

  The general serialization attributes of PascalForge.Serialization.

  Responsibilities
    - [SerializationName], [SerializationIgnore] and [SerializationEnum]:
      one declaration read by every format, by Dynamic and by the DataSet
      projection.

  Precedence
    A format's own configuration is more specific and wins for that format:
    [JsonName] or a registered JSON field override names the member in JSON
    whatever [SerializationName] says; RegisterEnumMapping on one serializer
    beats [SerializationEnum] for that serializer. Among the general
    attributes, the one on a member beats the one on the member's enum type.
    [SerializationIgnore] removes a member everywhere; a format's own ignore
    attribute removes it from that format only. There is no way to un-ignore.

  Documentation
    docs/attributes.md

  Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT
*******************************************************************************}

unit PascalForge.Serialization.Attributes;

{$SCOPEDENUMS ON}

interface

uses
  System.SysUtils;

type
  { The member's name in every format and in Dynamic, used exactly as
    written - no format's naming convention is applied to it. }
  SerializationNameAttribute = class(TCustomAttribute)
  strict private
    FName: string;
  public
    constructor Create(const AName: string);
    property Name: string read FName;
  end;

  { The member is not part of the serialized surface: no format writes it,
    no format reads it, and it is not projected into Dynamic or a DataSet. }
  SerializationIgnoreAttribute = class(TCustomAttribute);

  { The text of each value of an enumeration, in declaration order - the
    same list RegisterEnumMapping takes, as one string:

        [SerializationEnum('pending,in-progress,done')]
        TTaskState = (Pending, InProgress, Done);

    On an enumeration type it applies wherever the type is used - a member,
    a nullable, a set's elements, an array's or list's items, a dictionary's
    keys and values, a nested value; on a member of an enumeration type, to
    that member's own value only (directly or through a nullable). A
    format's own registration beats it. Each value is trimmed of
    surrounding spaces. A value containing the separator needs another
    separator - [SerializationEnum('a;b,c', ';')] - or the registration API.

    A format that writes enumerations as numbers (Protobuf, ASN.1
    ENUMERATED, CBOR and MessagePack under their ordinal representation)
    keeps writing numbers: a text mapping does not change a wire number. }
  SerializationEnumAttribute = class(TCustomAttribute)
  strict private
    FValues: TArray<string>;
  public
    constructor Create(const AValues: string; ASeparator: Char = ',');
    property Values: TArray<string> read FValues;
  end;

implementation

constructor SerializationNameAttribute.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
end;

constructor SerializationEnumAttribute.Create(const AValues: string;
  ASeparator: Char);
var
  Parts: TArray<string>;
  I: Integer;
begin
  inherited Create;
  Parts := AValues.Split([ASeparator]);
  SetLength(FValues, Length(Parts));
  for I := 0 to Integer(High(Parts)) do FValues[I] := Parts[I].Trim;
end;

end.
