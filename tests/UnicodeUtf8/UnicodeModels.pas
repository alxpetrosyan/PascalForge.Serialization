unit UnicodeModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ The DTOs for the Unicode and UTF-8 test.

  They live in a unit rather than in the program file because a type
  declared in a .dpr has no qualified RTTI name, and registration by name is
  part of what the library does. }

interface

uses
  System.Generics.Collections,
  PascalForge.Json, PascalForge.Xml;

type
  TSubject = class
  public
    Id: Integer;
    Name: string;
    Country: string;
    Note: string;
    constructor Create(AId: Integer; const AName, ACountry, ANote: string);
  end;

implementation

constructor TSubject.Create(AId: Integer;
  const AName, ACountry, ANote: string);
begin
  inherited Create;
  Id := AId;
  Name := AName;
  Country := ACountry;
  Note := ANote;
end;

end.
