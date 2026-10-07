unit BsonDateModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

interface

uses
  PascalForge.Bson;

type
  TEvent = class
  public
    Name: string;
    Day: TDate;
    At: TDateTime;
    [BsonDateTimeRepresentation(TBsonDateTimeRepresentation.UnixSeconds)]
    Expires: TDateTime;
  end;

implementation

end.
