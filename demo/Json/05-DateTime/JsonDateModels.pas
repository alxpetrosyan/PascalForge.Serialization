unit JsonDateModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The model lives in a unit because date registrations are keyed by type, and
  a type declared in a .dpr has no recoverable declaring unit. }

interface

uses
  PascalForge.Json;

type
  TEvent = class
  public
    Name: string;
    Day: TDate;
    At: TDateTime;
    { The most specific statement anyone can make about this member. No
      registration can override it. }
    [JsonDateTimeFormat(TJsonDateTimeFormat.UnixSeconds)]
    Expires: TDateTime;
  end;

implementation

end.
