program ProfilesAndUnicode;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ A document the destination format cannot quite take, and what happens to it.

  Two things can go wrong when a document moves between formats with no
  Delphi contract, and they are different problems:

    a member NAME the destination cannot spell   - "$type" is not a legal
                                                   XML element name
    a value KIND the destination does not have   - JSON has no binary and no
                                                   timestamp

  Nothing is ever silently dropped. The profile decides whether the
  conversion adapts, describes, or refuses.

  The second half is about text: a Delphi string is Unicode, and UTF-8 bytes
  are a separate and explicit request.

  Build:  ..\..\..\scripts\dcc.cmd ProfilesAndUnicode.dpr dcc32 demo }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, Winapi.Windows,
  PascalForge.Serialization.Core in '..\..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Serialization in '..\..\..\src\PascalForge.Serialization.pas',
  PascalForge.Json in '..\..\..\src\PascalForge.Json.pas',
  PascalForge.Xml in '..\..\..\src\PascalForge.Xml.pas',
  PascalForge.Json.Registration in '..\..\..\src\PascalForge.Json.Registration.pas',
  PascalForge.Xml.Registration in '..\..\..\src\PascalForge.Xml.Registration.pas';

const
  { Georgian, written as code points so this file's encoding cannot matter:
    "lali jishkariani" and "sakartvelo". }
  GEO_NAME = #$10DA#$10DD#$10D3#$10D8' '#$10EF#$10D8#$10E8#$10D9#$10D0 +
             #$10E0#$10D8#$10D0#$10DC#$10D8;
  GEO_COUNTRY = #$10E1#$10D0#$10E5#$10D0#$10E0#$10D7#$10D5#$10D4#$10DA#$10DD;

function Source: string;
begin
  { "$type", a name with a space, an empty array, a null, and an embedded XML
    document carried as a string - all of them ordinary, none of them
    directly expressible as XML. }
  Result :=
    '{"$type":"IndSubject",' +
     '"Name":"' + GEO_NAME + '",' +
     '"Country":"' + GEO_COUNTRY + '",' +
     '"first name":"Ada",' +
     '"Score":1234,' +
     '"Active":true,' +
     '"Tags":[],' +
     '"Rating":null,' +
     '"XmlMessage":"<Reply><Ok>true</Ok></Reply>"}';
end;

procedure Rule(const ATitle: string);
begin
  Writeln;
  Writeln('== ', ATitle, ' ', StringOfChar('=', 60 - Length(ATitle)));
end;

var
  Json, Xml, Back: TSerializationPayload;
  Utf8: TBytes;
  I: Integer;

begin
  { Registration is explicit: linking a registration unit registers
    nothing, so the formats this program selects at run time are
    registered here. }
  TJsonSerializationRegistration.RegisterFormat;
  TXmlSerializationRegistration.RegisterFormat;
  { The console, not the library. A Delphi console writes through a code page
    of its own, and the default one has no Georgian in it - so the text would
    arrive here correct and be printed as question marks, which is exactly the
    confusion this demo is about. Nothing below this line converts anything. }
  SetConsoleOutputCP(CP_UTF8);
  SetTextCodePage(Output, CP_UTF8);

  Json := TSerializationPayload.FromText(Source);
  Writeln('source JSON:');
  Writeln(Json.AsText);

  { ---------------------------------------------------------------------- }
  Rule('Natural - idiomatic output, names encoded reversibly');

  Xml := TSerialization.Convert(Json, TSerializationFormat.Json,
    TSerializationFormat.Xml);
  Writeln(Xml.AsText);
  Writeln;
  Writeln('"$type" became <_x0024_type> and "first name" became');
  Writeln('<first_x0020_name>. Neither was dropped and neither was mangled.');
  Writeln('The embedded XML is ESCAPED, not parsed: a string stays a string.');

  Back := TSerialization.Convert(Xml, TSerializationFormat.Xml,
    TSerializationFormat.Json);
  Writeln;
  Writeln('back to JSON:');
  Writeln(Back.AsText);
  Writeln;
  Writeln('Every name came back. The VALUES did not keep their types -');
  Writeln('1234 is now "1234" - because XML text carries no type at all.');

  { ---------------------------------------------------------------------- }
  Rule('Lossless - the same names, plus what each value was');

  Xml := TSerialization.Convert(Json, TSerializationFormat.Json,
    TSerializationFormat.Xml, TStructuralConversionProfile.Lossless);
  Writeln(Xml.AsText);

  Back := TSerialization.Convert(Xml, TSerializationFormat.Xml,
    TSerializationFormat.Json, TStructuralConversionProfile.Lossless);
  Writeln;
  Writeln('back to JSON:');
  Writeln(Back.AsText);
  Writeln;
  if Back.AsText = TSerialization.Convert(Json, TSerializationFormat.Json,
       TSerializationFormat.Json).AsText then
    Writeln('Identical to the source, member for member and value for value.')
  else
    Writeln('(unexpected: the round trip differed)');

  { ---------------------------------------------------------------------- }
  Rule('Strict - refuse, and say exactly where');

  try
    TSerialization.Convert(Json, TSerializationFormat.Json,
      TSerializationFormat.Xml, TStructuralConversionProfile.Strict);
    Writeln('(unexpected: Strict accepted it)');
  except
    on E: EStructuralConversionError do
    begin
      Writeln(E.Message);
      Writeln;
      Writeln('path  : ', E.Path);
      Writeln('issue : ', Ord(E.Issue), ' (InvalidDestinationName)');
    end;
  end;

  { ---------------------------------------------------------------------- }
  Rule('the name codec, if you have to undo it elsewhere');

  Writeln('$type        -> ', TXmlNameCodec.EncodeName('$type'));
  Writeln('_x0024_type  -> ', TXmlNameCodec.EncodeName('_x0024_type'));
  Writeln('and back     -> ',
    TXmlNameCodec.DecodeName(TXmlNameCodec.EncodeName('_x0024_type')));
  Writeln;
  Writeln('Those two source names do not collide, because an underscore');
  Writeln('followed by an x is encoded too. The escape escapes itself.');

  { ---------------------------------------------------------------------- }
  Rule('text is not bytes');

  Writeln('The JSON above is a Delphi string: Unicode text, no encoding.');
  Writeln('Georgian characters are written as themselves - JSON escapes');
  Writeln('only what JSON requires - so the document stays readable.');
  Writeln;

  Utf8 := Back.ToUtf8Bytes;
  Write('first bytes as UTF-8: ');
  for I := 0 to 23 do Write(IntToHex(Utf8[I], 2), ' ');
  Writeln('...');
  Writeln;
  Writeln('No BOM. ToUtf8Bytes on a BINARY payload would raise rather than');
  Writeln('hand its bytes back as though they were text.');
end.
