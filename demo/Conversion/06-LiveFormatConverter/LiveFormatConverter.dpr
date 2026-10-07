program LiveFormatConverter;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ A live, clickable converter - and a headless self-test of the same form.

      LiveFormatConverter.exe              opens the window
      LiveFormatConverter.exe --selftest   presses every button and reports

  The second mode is why this demo is worth having rather than just looking
  at: a window nobody opens is a demo nobody notices is broken. The build
  runs --selftest, and a regression in conversion, in the DataSet
  projection or in the detector shows up as a failing line here.

  The console type is deliberate. A VCL application with a console can do
  both jobs from one binary, and the alternative - a second project that
  duplicates the form - is how the two drift apart. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Vcl.Forms,
  PascalForge.Serialization.AllFormats,
  PascalForge.DataSet.Json,
  ConverterForm in 'ConverterForm.pas';

function WantsSelfTest: Boolean;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if SameText(ParamStr(I), '--selftest') then Exit(True);
  Result := False;
end;

var
  Form: TLiveConverterForm;
  Failures: Integer;
begin
  { The self-test's NO_EXCEPTION_AT_STARTUP counts every exception raised
    from here until the first conversion has been shown, caught or not. }
  if WantsSelfTest then StartCountingExceptions;
  { Registration is explicit, and this is where an application does it: at
    startup, once, for every format it will choose at run time. Linking the
    registration units registers nothing. }
  TSerializationFormatsRegistration.RegisterAll;
  { And a TDataSet member inside a JSON document is a packet: also explicit. }
  TDataSetJsonIntegration.Register;
  try
    if WantsSelfTest then
    begin
      { The form owns every control it creates and the table, the data
        source and both grids with them, so tearing it down should leave
        nothing behind. Saying so here turns that from an intention into a
        check: a leak prints a report and the run is noticed. }
      ReportMemoryLeaksOnShutdown := True;
      Application.Initialize;
      Form := TLiveConverterForm.Create(nil);
      try
        Failures := Form.SelfTest;
      finally
        Form.Free;
      end;
      Writeln;
      Writeln('FAILURES=', Failures);
      if Failures = 0 then
      begin
        { One marker per format that the window can now show, so that the
          per-format completion gates can point at something this program
          actually printed rather than at a claim in a document. }
        Writeln('CBOR_VCL_DEMO: PASS');
        Writeln('MSGPACK_VCL_DEMO: PASS');
        Writeln('YAML_VCL_DEMO: PASS');
        Writeln('CSV_VCL_DEMO: PASS');
        Writeln('AVRO_VCL_DEMO: PASS');
        Writeln('ASN1_VCL_DEMO: PASS');
        Writeln('LIVE_FORMAT_CONVERTER: PASS');
      end
      else
      begin
        Writeln('LIVE_FORMAT_CONVERTER: FAIL');
        Halt(1);
      end;
      Exit;
    end;

    Application.Initialize;
    Application.MainFormOnTaskbar := True;
    Application.Title := 'Live Format Converter';
    Application.CreateForm(TLiveConverterForm, LiveConverterForm);
    Application.Run;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Writeln('LIVE_FORMAT_CONVERTER: FAIL');
      Halt(1);
    end;
  end;
end.
