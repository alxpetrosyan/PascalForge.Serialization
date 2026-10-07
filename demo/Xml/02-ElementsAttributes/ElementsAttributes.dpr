program ElementsAttributes;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Where a member goes: an element, an attribute, or the element's own text.

  Build:  ..\..\..\scripts\dcc.cmd ElementsAttributes.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  PascalForge.Xml in '..\..\..\src\PascalForge.Xml.pas';

type
  TPriority = (Low, Normal, Urgent);

  [XmlName('Ticket')]
  TTicket = class
  public
    { An attribute of the owner's element. Only a value with a single text
      form can be one - a scalar, an enumeration, a set, a GUID, a date, or a
      nullable of those. Anything else is refused when the plan is built,
      with a message saying so. }
    [XmlAttribute] [XmlName('id')]
    Id: Integer;
    [XmlAttribute]
    Priority: TPriority;

    { A plain element, renamed. }
    [XmlName('Subject')]
    Title: string;

    { Gone from XML in both directions. }
    [XmlIgnore]
    InternalScore: Integer;

    { The element's own text content. At most one member may be it. }
    [XmlText]
    Body: string;
  end;

var
  Ticket, Back: TTicket;
  Xml: string;

begin
  Ticket := TTicket.Create;
  try
    Ticket.Id := 90210;
    Ticket.Priority := TPriority.Urgent;
    Ticket.Title := 'Disk full';
    Ticket.InternalScore := 7;
    Ticket.Body := 'The volume is at 99%.';
    Xml := TXmlSerializer.Serialize<TTicket>(Ticket);
  finally
    Ticket.Free;
  end;
  Writeln(Xml);

  Back := TXmlSerializer.Deserialize<TTicket>(Xml);
  try
    Writeln;
    Writeln('id            = ', Back.Id);
    Writeln('subject       = ', Back.Title);
    Writeln('body          = ', Back.Body);
    Writeln('internalScore = ', Back.InternalScore, '  (never written, so 0)');
  finally
    Back.Free;
  end;
end.
