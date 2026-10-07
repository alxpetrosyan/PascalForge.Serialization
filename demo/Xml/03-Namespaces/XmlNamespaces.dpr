program XmlNamespaces;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Namespaces, and why the prefix is not the name.

  Build:  ..\..\..\scripts\dcc.cmd XmlNamespaces.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  PascalForge.Xml in '..\..\..\src\PascalForge.Xml.pas';

type
  [XmlName('Envelope')]
  [XmlNamespace('urn:example:envelope')]
  TEnvelope = class
  public
    { Inherits the type's namespace. }
    Subject: string;
    { Says otherwise. }
    [XmlNamespace('urn:example:payload')]
    Payload: string;
  end;

var
  Envelope, Back: TEnvelope;
  Xml: string;

begin
  Envelope := TEnvelope.Create;
  try
    Envelope.Subject := 'hello';
    Envelope.Payload := 'body';
    Xml := TXmlSerializer.Serialize<TEnvelope>(Envelope);
  finally
    Envelope.Free;
  end;
  Writeln(Xml);

  { The same document, spelled with different prefixes. A prefix is a
    spelling; identity is the namespace URI, so this reads identically. }
  Back := TXmlSerializer.Deserialize<TEnvelope>(
    '<q:Envelope xmlns:q="urn:example:envelope" ' +
    'xmlns:p="urn:example:payload">' +
    '<q:Subject>hello</q:Subject>' +
    '<p:Payload>body</p:Payload></q:Envelope>');
  try
    Writeln;
    Writeln('read back from a document with different prefixes:');
    Writeln('  subject = ', Back.Subject);
    Writeln('  payload = ', Back.Payload);
  finally
    Back.Free;
  end;

  Writeln;
  Writeln('The writer declares every namespace once, on the root, and picks');
  Writeln('the prefixes. Prefix spelling is not contractual; the URI is.');
end.
