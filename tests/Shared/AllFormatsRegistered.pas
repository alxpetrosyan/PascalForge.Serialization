unit AllFormatsRegistered;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Every format this library implements, registered - for the tests.

  The tests that are about the library AS A WHOLE - the conversion matrix,
  the round-the-world chain, the DataSet matrix - all want the same thing:
  every format in the registry, so that they can ask the registry what
  exists and test that, rather than carrying a list of their own.

  Registration is explicit in the library: no unit registers a format from
  its initialization. THIS unit is test scaffolding, and it makes the one
  explicit call - TSerializationFormatsRegistration.RegisterAll - from its
  own initialization, so that a whole-library test gets the registry filled
  before its main block runs. An application does the same thing at its
  startup, in code it can see. tests\FormatRegistry proves the library
  itself registers nothing on its own.

  It is a TEST unit and deliberately not in src\. }

interface

implementation

uses
  PascalForge.Serialization.AllFormats;

initialization
  TSerializationFormatsRegistration.RegisterAll;

finalization
  TSerializationFormatsRegistration.UnregisterAll;

end.
