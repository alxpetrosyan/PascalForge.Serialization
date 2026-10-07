unit XmlDateModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

interface

uses
  PascalForge.Xml;

type
  TEvent = class
  public
    Name: string;
    Day: TDate;
    At: TDateTime;
    [XmlDateTimeFormat(TXmlDateTimeFormat.UnixSeconds)]
    Expires: TDateTime;
  end;

implementation

end.
