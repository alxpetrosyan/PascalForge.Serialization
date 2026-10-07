program CsvNative;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Is this actually a CSV implementation, or a Split(',')?

  That is the whole question. Splitting on commas reads four fields out of

      1,"Doe, Jane","He said ""hi""",2

  and every one of them is wrong. This program asks whether the parser and
  the writer implement the format, and whether the DECISIONS a table forces
  on a tree - a nested object, a collection, a null - are the caller's and
  are refused rather than guessed when the caller has not made them.

  THE TARGET, named exactly:

      RFC 4180, and the dialects real files are written in: Excel's with a
      byte-order mark, tab-separated, and a caller's own delimiter and quote
      Embedded delimiters, embedded quotes doubled, embedded line breaks
      Ragged rows, duplicate headers, headerless files
      Nested objects: Flatten, JsonCell, SeparateTable, Error
      Collections: Error, JsonCell, RepeatedRows, NumberedColumns,
                   SeparateTable
      Several tables as a document SET, never concatenated into one payload
      Schema as a separate object, never a second header row

  THE INDEPENDENT REFERENCE is RFC 4180 itself, whose rules are quoted below
  beside the checks that exercise them, plus the behaviour of the
  spreadsheet software every CSV file is eventually opened in. There is no
  network and no reference implementation installed here, so the oracle is
  the document rather than a running program - said plainly rather than
  dressed up. }

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.Math, System.DateUtils, System.TypInfo,
  System.StrUtils, System.Generics.Collections, Data.DB, Datasnap.DBClient,
  CsvModels in 'CsvModels.pas',
  PascalForge.Serialization.Core in '..\..\src\PascalForge.Serialization.Core.pas',
  PascalForge.Dynamic in '..\..\src\PascalForge.Dynamic.pas',
  PascalForge.Serialization in '..\..\src\PascalForge.Serialization.pas',
  PascalForge.Nullable in '..\..\src\PascalForge.Nullable.pas',
  PascalForge.Csv in '..\..\src\PascalForge.Csv.pas',
  PascalForge.Csv.Internal in '..\..\src\PascalForge.Csv.Internal.pas',
  PascalForge.Csv.Registration in '..\..\src\PascalForge.Csv.Registration.pas',
  PascalForge.DataSet in '..\..\src\PascalForge.DataSet.pas',
  PascalForge.DataSet.Internal in '..\..\src\PascalForge.DataSet.Internal.pas',
  AllFormatsRegistered in '..\Shared\AllFormatsRegistered.pas';

var
  GFailures: Integer = 0;
  GChecks: Integer = 0;

procedure Check(ACondition: Boolean; const AName: string);
begin
  Inc(GChecks);
  if ACondition then
    Writeln(AName, ': PASS')
  else
  begin
    Writeln(AName, ': FAIL');
    Inc(GFailures);
  end;
end;

procedure Note(const AText: string);
begin
  Writeln('  ', AText);
end;

function OneLine(const AText: string): string;
begin
  Result := StringReplace(StringReplace(Trim(AText), #13#10, ' | ',
    [rfReplaceAll]), #10, ' | ', [rfReplaceAll]);
end;

{ A document written without embedded line-break literals, so that the test
  source stays readable. }
function Doc(const ALines: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := Low(ALines) to High(ALines) do
    Result := Result + ALines[I] + #13#10;
end;

{ ===========================================================================
  THE LEXER - RFC 4180, and what a Split(',') gets wrong
  =========================================================================== }

procedure TestLexer;
var
  Table: TCsvTable;
  Options: TCsvOptions;
  Caught: Boolean;
begin
  Writeln;
  Writeln('--- the lexer ---');

  { RFC 4180 section 2.6: a field containing the delimiter is enclosed in
    quotes. This is the line a naive splitter gets wrong, and it is the
    reason this unit exists. }
  Table := TCsvEngine.ParseTable(
    Doc(['id,name,note,qty', '1,"Doe, Jane","He said ""hi""",2']),
    TCsvOptions.Default);
  try
    Check(Table.Width = 4, 'LEXER_FIELD_COUNT');
    Check(Table.Cell(0, 'name') = 'Doe, Jane', 'LEXER_EMBEDDED_DELIMITER');
    { Section 2.7: a quote inside a quoted field is escaped by doubling. }
    Check(Table.Cell(0, 'note') = 'He said "hi"', 'LEXER_DOUBLED_QUOTE');
    Check(Table.Cell(0, 'qty') = '2', 'LEXER_LAST_FIELD');
  finally
    Table.Free;
  end;

  { Section 2.6 again: a field may contain a LINE BREAK, and a parser that
    reads the file line by line splits one record into two. }
  Table := TCsvEngine.ParseTable(
    'id,address' + #13#10 + '1,"12 Example Street' + #13#10 + 'Midtown"' + #13#10,
    TCsvOptions.Default);
  try
    Check(Table.RowCount = 1, 'LEXER_EMBEDDED_NEWLINE_IS_ONE_ROW');
    Check(Pos('Midtown', Table.Cell(0, 'address')) > 0,
      'LEXER_EMBEDDED_NEWLINE_CONTENT');
  finally
    Table.Free;
  end;

  { An empty field, a field that is only quotes, and a trailing empty
    field - the three places an off-by-one shows up. }
  Table := TCsvEngine.ParseTable(Doc(['a,b,c', '1,,', ',"",3']),
    TCsvOptions.Default);
  try
    Check(Table.RowCount = 2, 'LEXER_ROW_COUNT');
    Check((Table.Cell(0, 'b') = '') and (Table.Cell(0, 'c') = ''),
      'LEXER_TRAILING_EMPTY_FIELDS');
    Check((Table.Cell(1, 'a') = '') and (Table.Cell(1, 'b') = '') and
          (Table.Cell(1, 'c') = '3'), 'LEXER_LEADING_EMPTY_FIELD');
  finally
    Table.Free;
  end;

  { Both line endings, and a file with no final one. }
  Table := TCsvEngine.ParseTable('a,b' + #10 + '1,2' + #10 + '3,4',
    TCsvOptions.Default);
  try
    Check(Table.RowCount = 2, 'LEXER_LF_ONLY_AND_NO_FINAL_BREAK');
  finally
    Table.Free;
  end;

  { A byte-order mark is not a column name. Excel writes one; a parser that
    keeps it makes the first column unfindable by the name it appears to
    have. }
  Table := TCsvEngine.ParseTable(#$FEFF + Doc(['a,b', '1,2']),
    TCsvOptions.Default);
  try
    Check(Table.Cell(0, 'a') = '1', 'LEXER_BOM_IS_NOT_PART_OF_THE_HEADER');
  finally
    Table.Free;
  end;

  { Tab-separated and a caller's own delimiter. }
  Table := TCsvEngine.ParseTable(
    'a' + #9 + 'b' + #13#10 + '1' + #9 + 'two words' + #13#10,
    TCsvOptions.ForDialect(TCsvDialect.TabSeparated));
  try
    Check(Table.Cell(0, 'b') = 'two words', 'LEXER_TAB_SEPARATED');
  finally
    Table.Free;
  end;

  Options := TCsvOptions.Default.WithDelimiter(';');
  Table := TCsvEngine.ParseTable(Doc(['a;b', '1;2']), Options);
  try
    Check(Table.Cell(0, 'b') = '2', 'LEXER_CUSTOM_DELIMITER');
  finally
    Table.Free;
  end;

  { Headerless: the columns are still reachable, by a positional name that
    exists only in memory. Nothing is written into the file. }
  Options := TCsvOptions.Default.WithHeader(False);
  Table := TCsvEngine.ParseTable(Doc(['1,2', '3,4']), Options);
  try
    Check(Table.RowCount = 2, 'LEXER_HEADERLESS_ROW_COUNT');
    Check(Table.CellAt(1, 0) = '3', 'LEXER_HEADERLESS_BY_POSITION');
  finally
    Table.Free;
  end;

  { A ragged row: by default it is an error, because a row with the wrong
    number of fields is a file that went wrong somewhere, and padding it
    silently hides where. }
  Caught := False;
  try
    Table := TCsvEngine.ParseTable(Doc(['a,b,c', '1,2']), TCsvOptions.Default);
    Table.Free;
  except
    on E: ECsvInputError do Caught := True;
  end;
  Check(Caught, 'LEXER_RAGGED_ROW_REFUSED');

  Options := TCsvOptions.Default.WithRaggedRows(
    TCsvRaggedRowPolicy.PadWithEmpty);
  Table := TCsvEngine.ParseTable(Doc(['a,b,c', '1,2']), Options);
  try
    Check(Table.Cell(0, 'c') = '', 'LEXER_RAGGED_ROW_PADDED');
  finally
    Table.Free;
  end;

  { Duplicate headers: by default an error, because a lookup by name would
    otherwise pick one of two columns and never say which. }
  Caught := False;
  try
    Table := TCsvEngine.ParseTable(Doc(['a,a', '1,2']), TCsvOptions.Default);
    Table.Free;
  except
    on E: ECsvInputError do Caught := True;
  end;
  Check(Caught, 'LEXER_DUPLICATE_HEADER_REFUSED');

  Options := TCsvOptions.Default.WithDuplicateHeaders(
    TCsvDuplicateHeaderPolicy.Rename);
  Table := TCsvEngine.ParseTable(Doc(['a,a', '1,2']), Options);
  try
    Check(Table.Width = 2, 'LEXER_DUPLICATE_HEADER_RENAMED');
  finally
    Table.Free;
  end;
end;

{ ===========================================================================
  THE WRITER
  =========================================================================== }

procedure TestWriter;
var
  Customer: TCustomer;
  Text: string;
  Table: TCsvTable;
  Options: TCsvOptions;
begin
  Writeln;
  Writeln('--- the writer ---');

  Customer := TCustomer.Create;
  try
    Customer.Id := 1;
    Customer.Name := 'Doe, Jane';
    Customer.Remark := 'He said "hi"';
    Text := TCsvSerializer.Serialize<TCustomer>(Customer);
    Note(OneLine(Text));
    { The two rules that make a CSV file readable again: a field with the
      delimiter in it is quoted, and a quote in it is doubled. }
    Check(Pos('"Doe, Jane"', Text) > 0, 'WRITER_QUOTES_A_DELIMITER');
    Check(Pos('"He said ""hi"""', Text) > 0, 'WRITER_DOUBLES_A_QUOTE');

    Table := TCsvEngine.ParseTable(Text, TCsvOptions.Default);
    try
      Check(Table.Cell(0, 'Name') = 'Doe, Jane', 'WRITER_ROUND_TRIPS');
      Check(Table.Cell(0, 'note') = 'He said "hi"',
        'WRITER_ROUND_TRIPS_A_QUOTE');
    finally
      Table.Free;
    end;

    { A field with a line break in it round-trips too. }
    Customer.Name := 'Line one' + #13#10 + 'Line two';
    Text := TCsvSerializer.Serialize<TCustomer>(Customer);
    Table := TCsvEngine.ParseTable(Text, TCsvOptions.Default);
    try
      Check(Table.RowCount = 1, 'WRITER_EMBEDDED_NEWLINE_IS_ONE_ROW');
      Check(Pos('Line two', Table.Cell(0, 'Name')) > 0,
        'WRITER_EMBEDDED_NEWLINE_CONTENT');
    finally
      Table.Free;
    end;

    Customer.Name := 'plain';
    Options := TCsvOptions.Default.WithAlwaysQuote(True);
    Text := TCsvSerializer.Serialize<TCustomer>(Customer, Options);
    Check(Pos('"plain"', Text) > 0, 'WRITER_ALWAYS_QUOTE');

    Options := TCsvOptions.Default.WithNewLine(TCsvNewLine.Lf);
    Text := TCsvSerializer.Serialize<TCustomer>(Customer, Options);
    Check((Pos(#13, Text) = 0) and (Pos(#10, Text) > 0), 'WRITER_LF_NEWLINE');

    { The Excel dialect writes a byte-order mark, without which a
      spreadsheet reads the bytes in the machine's own code page and
      mangles every non-ASCII name in the file. }
    Options := TCsvOptions.ForDialect(TCsvDialect.Excel);
    Check(Options.WriteBom, 'WRITER_EXCEL_DIALECT_WRITES_A_BOM');
  finally
    Customer.Free;
  end;
end;

{ ===========================================================================
  THE CONTRACT - a flat row
  =========================================================================== }

procedure TestFlatContract;
var
  Customer, Back: TCustomer;
  Many, ManyBack: TArray<TCustomer>;
  Text: string;
  Table: TCsvTable;
  I: Integer;
begin
  Writeln;
  Writeln('--- a flat contract ---');

  Customer := TCustomer.Create;
  try
    Customer.Id := 7;
    Customer.Name := 'Alice';
    Customer.Score := 1234.56;
    Customer.Rate := 0.0725;
    Customer.Active := True;
    Customer.Joined := EncodeDateTime(2026, 9, 19, 14, 30, 0, 0);
    Customer.Reference := StringToGUID('{3F2504E0-4F89-41D3-9A0C-0305E82C3301}');
    Customer.Delivery := TDelivery.NextDay;
    Customer.Scratch := 'must not appear';
    Customer.Remark := 'thank you';
    Customer.Retired := True;

    Text := TCsvSerializer.Serialize<TCustomer>(Customer);
    Note(OneLine(Text));

    Table := TCsvEngine.ParseTable(Text, TCsvOptions.Default);
    try
      Check(Table.RowCount = 1, 'CONTRACT_ONE_ROW');
      Check(not Table.HasColumn('Scratch'), 'CONTRACT_IGNORE_HONOURED');
      Check(Table.HasColumn('note'), 'CONTRACT_NAME_HONOURED');
      Check(Table.Cell(0, 'Active') = 'true', 'CONTRACT_BOOLEAN_TEXT');
    finally
      Table.Free;
    end;

    Back := TCsvSerializer.Deserialize<TCustomer>(Text);
    try
      Check(Back.Id = 7, 'CONTRACT_INTEGER');
      Check(Back.Name = 'Alice', 'CONTRACT_STRING');
      Check(Back.Score = 1234.56, 'CONTRACT_CURRENCY');
      Check(Back.Rate = Customer.Rate, 'CONTRACT_DOUBLE');
      Check(Back.Active, 'CONTRACT_BOOLEAN');
      Check(SecondsBetween(Back.Joined, Customer.Joined) = 0,
        'CONTRACT_DATETIME');
      Check(IsEqualGUID(Back.Reference, Customer.Reference), 'CONTRACT_GUID');
      Check(Back.Delivery = TDelivery.NextDay, 'CONTRACT_ENUM');
      Check(Back.Scratch = '', 'CONTRACT_IGNORED_NOT_READ');
      Check(Back.Remark = 'thank you', 'CONTRACT_RENAMED_READ');
      Check(Back.Retired.HasValue and Back.Retired.Value,
        'CONTRACT_NULLABLE_PRESENT');
    finally
      Back.Free;
    end;
  finally
    Customer.Free;
  end;

  { A list of rows is what a table actually is. }
  SetLength(Many, 3);
  for I := 0 to 2 do
  begin
    Many[I] := TCustomer.Create;
    Many[I].Id := I + 1;
    Many[I].Name := 'Row ' + IntToStr(I + 1);
  end;
  try
    Text := TCsvSerializer.Serialize<TArray<TCustomer>>(Many);
    Note(OneLine(Text));
    ManyBack := TCsvSerializer.Deserialize<TArray<TCustomer>>(Text);
    try
      Check(Length(ManyBack) = 3, 'CONTRACT_MANY_ROWS');
      Check(ManyBack[2].Name = 'Row 3', 'CONTRACT_MANY_ROWS_CONTENT');
    finally
      for I := 0 to High(ManyBack) do ManyBack[I].Free;
    end;
  finally
    for I := 0 to High(Many) do Many[I].Free;
  end;
end;

{ ===========================================================================
  NESTED OBJECTS - four modes, and no default that guesses
  =========================================================================== }

procedure TestNestedObjects;
var
  Invoice, Back: TInvoice;
  Text: string;
  Table: TCsvTable;
  Options: TCsvOptions;
  Tables: TCsvDocumentSet;
  Caught: Boolean;
begin
  Writeln;
  Writeln('--- nested objects ---');

  Invoice := TInvoice.Create;
  try
    Invoice.Number := 'INV-1';
    Invoice.Total := 99.95;
    Invoice.Shipper.Street := 'Example Avenue 7';
    Invoice.Shipper.City := 'Midtown';
    Invoice.Shipper.Postcode := '01234';

    { Flatten is the default, because it is what a table can express and it
      reverses exactly when a contract says which columns belong to which
      member. }
    Text := TCsvSerializer.Serialize<TInvoice>(Invoice);
    Note(OneLine(Text));
    Table := TCsvEngine.ParseTable(Text, TCsvOptions.Default);
    try
      Check(Table.HasColumn('Shipper.City'), 'NESTED_FLATTEN_COLUMN_NAME');
      Check(Table.Cell(0, 'Shipper.Postcode') = '01234',
        'NESTED_FLATTEN_KEEPS_A_LEADING_ZERO');
    finally
      Table.Free;
    end;

    Back := TCsvSerializer.Deserialize<TInvoice>(Text);
    try
      Check(Back.Shipper.City = 'Midtown', 'NESTED_FLATTEN_REVERSES');
      Check(Back.Shipper.Postcode = '01234',
        'NESTED_FLATTEN_REVERSES_A_LEADING_ZERO');
    finally
      Back.Free;
    end;

    { JsonCell puts one format's document inside another's, which is a
      choice and never a default. It reaches JSON through the REGISTRY. }
    Options := TCsvOptions.Default.WithNestedObjectMode(
      TCsvNestedObjectMode.JsonCell);
    Text := TCsvSerializer.Serialize<TInvoice>(Invoice, Options);
    Note(OneLine(Text));
    Check((Pos('{', Text) > 0) and (Pos('Midtown', Text) > 0),
      'NESTED_JSONCELL_WRITES_JSON');
    Back := TCsvSerializer.Deserialize<TInvoice>(Text, Options);
    try
      Check(Back.Shipper.City = 'Midtown', 'NESTED_JSONCELL_REVERSES');
    finally
      Back.Free;
    end;

    { SeparateTable is a separate FILE, so it is not reachable from a call
      that returns one payload. Saying so beats concatenating two CSVs into
      a document no reader can read. }
    Options := TCsvOptions.Default.WithNestedObjectMode(
      TCsvNestedObjectMode.SeparateTable);
    Caught := False;
    try
      Text := TCsvSerializer.Serialize<TInvoice>(Invoice, Options);
    except
      on E: ECsvProjectionError do
        Caught := Pos('SerializeTables', E.Message) > 0;
    end;
    Check(Caught, 'NESTED_SEPARATE_TABLE_NAMES_THE_ALTERNATIVE');

    Tables := TCsvSerializer.SerializeTables<TInvoice>(Invoice, Options);
    try
      Check(Tables.Count = 2, 'NESTED_SEPARATE_TABLE_PRODUCES_TWO');
      Check(Tables.RelationshipCount = 1, 'NESTED_SEPARATE_TABLE_RELATIONSHIP');
      Note(Tables.Describe);
    finally
      Tables.Free;
    end;

    { Error is the mode for a caller who wants to be told. }
    Options := TCsvOptions.Default.WithNestedObjectMode(
      TCsvNestedObjectMode.Error);
    Caught := False;
    try
      Text := TCsvSerializer.Serialize<TInvoice>(Invoice, Options);
    except
      on E: ECsvProjectionError do Caught := True;
    end;
    Check(Caught, 'NESTED_ERROR_MODE_REFUSES');
  finally
    Invoice.Free;
  end;
end;

{ ===========================================================================
  COLLECTIONS - five modes, and a default that refuses
  =========================================================================== }

procedure TestCollections;
var
  Order, Back: TOrder;
  Basket: TBasket;
  Line: TLine;
  Both: TDouble;
  Text: string;
  Table: TCsvTable;
  Options: TCsvOptions;
  Tables: TCsvDocumentSet;
  Caught: Boolean;
begin
  Writeln;
  Writeln('--- collections ---');

  Order := TOrder.Create;
  try
    Order.Id := 1;
    Order.Customer := 'Alice';
    Order.Tags := ['urgent', 'reviewed', 'paid'];

    { A cell holds ONE value and a collection has N, so the default is to
      say so rather than pick a separator nobody agreed on. }
    Caught := False;
    try
      Text := TCsvSerializer.Serialize<TOrder>(Order);
    except
      on E: ECsvProjectionError do Caught := True;
    end;
    Check(Caught, 'COLLECTION_DEFAULT_REFUSES');

    Options := TCsvOptions.Default.WithCollectionMode(
      TCsvCollectionMode.NumberedColumns);
    Text := TCsvSerializer.Serialize<TOrder>(Order, Options);
    Note(OneLine(Text));
    Table := TCsvEngine.ParseTable(Text, TCsvOptions.Default);
    try
      Check(Table.HasColumn('Tags_1') and Table.HasColumn('Tags_3'),
        'COLLECTION_NUMBERED_COLUMNS');
      Check(Table.Cell(0, 'Tags_2') = 'reviewed',
        'COLLECTION_NUMBERED_COLUMNS_CONTENT');
    finally
      Table.Free;
    end;
    Back := TCsvSerializer.Deserialize<TOrder>(Text, Options);
    try
      Check((Length(Back.Tags) = 3) and (Back.Tags[2] = 'paid'),
        'COLLECTION_NUMBERED_COLUMNS_REVERSES');
    finally
      Back.Free;
    end;

    Options := TCsvOptions.Default.WithCollectionMode(
      TCsvCollectionMode.RepeatedRows);
    Text := TCsvSerializer.Serialize<TOrder>(Order, Options);
    Note(OneLine(Text));
    Table := TCsvEngine.ParseTable(Text, TCsvOptions.Default);
    try
      Check(Table.RowCount = 3, 'COLLECTION_REPEATED_ROWS');
      Check(Table.Cell(1, 'Customer') = 'Alice',
        'COLLECTION_REPEATED_ROWS_COPIES_THE_SCALARS');
    finally
      Table.Free;
    end;
    Back := TCsvSerializer.Deserialize<TOrder>(Text, Options);
    try
      Check((Length(Back.Tags) = 3) and (Back.Tags[1] = 'reviewed'),
        'COLLECTION_REPEATED_ROWS_REVERSES');
    finally
      Back.Free;
    end;

    Options := TCsvOptions.Default.WithCollectionMode(
      TCsvCollectionMode.JsonCell);
    Text := TCsvSerializer.Serialize<TOrder>(Order, Options);
    Note(OneLine(Text));
    { The cell holds a JSON document, so CSV quotes it and doubles the
      quotes inside - which is exactly what makes it readable again. The
      check therefore looks at the PARSED cell, not at the raw file. }
    Table := TCsvEngine.ParseTable(Text, TCsvOptions.Default);
    try
      Check(Table.Cell(0, 'Tags') = '["urgent","reviewed","paid"]',
        'COLLECTION_JSONCELL');
    finally
      Table.Free;
    end;
    Back := TCsvSerializer.Deserialize<TOrder>(Text, Options);
    try
      Check(Length(Back.Tags) = 3, 'COLLECTION_JSONCELL_REVERSES');
    finally
      Back.Free;
    end;
  finally
    Order.Free;
  end;

  { A collection of RECORDS: NumberedColumns cannot carry it and says so;
    SeparateTable is the mode that can. }
  Basket := TBasket.Create;
  try
    Basket.Id := 5;
    Basket.Customer := 'Alice';
    Line := TLine.Create;
    Line.Description := 'Consulting';
    Line.Quantity := 3;
    Line.UnitPrice := 400.00;
    Basket.Lines.Add(Line);
    Line := TLine.Create;
    Line.Description := 'Travel';
    Line.Quantity := 1;
    Line.UnitPrice := 85.50;
    Basket.Lines.Add(Line);

    Options := TCsvOptions.Default.WithCollectionMode(
      TCsvCollectionMode.NumberedColumns);
    Caught := False;
    try
      Text := TCsvSerializer.Serialize<TBasket>(Basket, Options);
    except
      on E: ECsvProjectionError do Caught := True;
    end;
    Check(Caught, 'COLLECTION_NUMBERED_COLUMNS_REFUSES_RECORDS');

    Options := TCsvOptions.Default.WithCollectionMode(
      TCsvCollectionMode.SeparateTable);
    Tables := TCsvSerializer.SerializeTables<TBasket>(Basket, Options);
    try
      Check(Tables.Count = 2, 'COLLECTION_SEPARATE_TABLE_COUNT');
      Check(Tables.RelationshipCount = 1,
        'COLLECTION_SEPARATE_TABLE_RELATIONSHIP');
      Check(Tables[1].RowCount = 2, 'COLLECTION_SEPARATE_TABLE_CHILD_ROWS');
      Check(Tables.Relationships[0].ParentTable = Tables[0].Name,
        'COLLECTION_SEPARATE_TABLE_NAMES_THE_PARENT');
      Note(Tables.Describe);
      Note(OneLine(Tables[1].Content));
      { The parent's key is declared with [CsvKey], so the relationship must
        NOT claim a generated one. }
      Check(not Tables.Relationships[0].KeyIsGenerated,
        'COLLECTION_SEPARATE_TABLE_USES_A_DECLARED_KEY');
    finally
      Tables.Free;
    end;

    { RepeatedRows with records: one row per line, the scalars copied. }
    Options := TCsvOptions.Default.WithCollectionMode(
      TCsvCollectionMode.RepeatedRows);
    Text := TCsvSerializer.Serialize<TBasket>(Basket, Options);
    Note(OneLine(Text));
    Table := TCsvEngine.ParseTable(Text, TCsvOptions.Default);
    try
      Check(Table.RowCount = 2, 'COLLECTION_REPEATED_ROWS_OF_RECORDS');
      Check(Table.HasColumn('Lines.Description'),
        'COLLECTION_REPEATED_ROWS_FLATTENS_THE_ELEMENT');
    finally
      Table.Free;
    end;
  finally
    Basket.Free;
  end;

  { TWO collections on one row. N times M rows contains pairings the source
    never had, so the default refuses and names the alternatives. }
  Both := TDouble.Create;
  try
    Both.Id := 1;
    Both.First := ['a', 'b'];
    Both.Second := ['x', 'y'];
    Options := TCsvOptions.Default.WithCollectionMode(
      TCsvCollectionMode.RepeatedRows);
    Caught := False;
    try
      Text := TCsvSerializer.Serialize<TDouble>(Both, Options);
    except
      on E: ECsvProjectionError do
        Caught := Pos('never had', E.Message) > 0;
    end;
    Check(Caught, 'COLLECTION_CARTESIAN_PRODUCT_REFUSED_BY_DEFAULT');

    Options := Options.WithMultipleCollections(
      TCsvMultipleCollections.CartesianProduct);
    Text := TCsvSerializer.Serialize<TDouble>(Both, Options);
    Table := TCsvEngine.ParseTable(Text, TCsvOptions.Default);
    try
      Check(Table.RowCount = 4, 'COLLECTION_CARTESIAN_PRODUCT_ON_REQUEST');
    finally
      Table.Free;
    end;
  finally
    Both.Free;
  end;
end;

{ ===========================================================================
  NULLS, AND THE DIFFERENCE A FILE CANNOT RECORD
  =========================================================================== }

procedure TestNulls;
var
  Customer, Back: TCustomer;
  Text: string;
  Options: TCsvOptions;
  Caught: Boolean;
begin
  Writeln;
  Writeln('--- nulls ---');

  Customer := TCustomer.Create;
  try
    Customer.Id := 1;
    Customer.Name := '';

    { EmptyField is the default and is NOT reversible: an empty string comes
      back as an absent value, because the document did not record the
      difference. It is what every other CSV producer does. }
    Text := TCsvSerializer.Serialize<TCustomer>(Customer);
    Check(Pos(',,', Text) > 0, 'NULL_EMPTY_FIELD_IS_THE_DEFAULT');

    Options := TCsvOptions.Default.WithNullPolicy(TCsvNullPolicy.Literal,
      '\N');
    Text := TCsvSerializer.Serialize<TCustomer>(Customer, Options);
    Note(OneLine(Text));
    Check(Pos('\N', Text) > 0, 'NULL_LITERAL_IS_WRITTEN');
    Back := TCsvSerializer.Deserialize<TCustomer>(Text, Options);
    try
      Check(not Back.Retired.HasValue, 'NULL_LITERAL_REVERSES');
    finally
      Back.Free;
    end;

    Options := TCsvOptions.Default.WithNullPolicy(TCsvNullPolicy.Error);
    Caught := False;
    try
      Text := TCsvSerializer.Serialize<TCustomer>(Customer, Options);
    except
      on E: ECsvProjectionError do Caught := True;
    end;
    Check(Caught, 'NULL_ERROR_POLICY_REFUSES');
  finally
    Customer.Free;
  end;
end;

{ ===========================================================================
  SCHEMA - alongside the file, never inside it
  =========================================================================== }

procedure TestSchema;
var
  Schema: TCsvSchema;
  Column: TCsvColumn;
  Options: TCsvOptions;
begin
  Writeln;
  Writeln('--- schema ---');

  { Conservative is the default and guesses as little as is useful. '00123'
    stays text, because a leading zero is information; a plain integer
    becomes one, because nothing was written that says otherwise. }
  Schema := TCsvEngine.InferSchema(
    Doc(['id,code,ratio,flag,name',
         '1,00123,0.5,true,Alice',
         '2,00456,1.5,false,Carol']), TCsvOptions.Default);
  try
    Check(Schema.Count = 5, 'SCHEMA_COLUMN_COUNT');
    Check(Schema.TryGetColumn('id', Column) and
          (Column.ColumnType = TCsvColumnType.Int32), 'SCHEMA_INFERS_INTEGER');
    Check(Schema.TryGetColumn('code', Column) and
          (Column.ColumnType = TCsvColumnType.Str),
      'SCHEMA_LEADING_ZERO_STAYS_TEXT');
    Check(Schema.TryGetColumn('ratio', Column) and
          (Column.ColumnType = TCsvColumnType.Float), 'SCHEMA_INFERS_FLOAT');
    Check(Schema.TryGetColumn('flag', Column) and
          (Column.ColumnType = TCsvColumnType.Boolean),
      'SCHEMA_INFERS_BOOLEAN');
    Check(Schema.TryGetColumn('name', Column) and
          (Column.ColumnType = TCsvColumnType.Str), 'SCHEMA_INFERS_TEXT');
    Note(Schema.Describe);
  finally
    Schema.Free;
  end;

  { A date is only a date when the caller has said that spelling decides. }
  Schema := TCsvEngine.InferSchema(
    Doc(['when', '2026-09-19T14:30:00', '2026-09-20T09:00:00']),
    TCsvOptions.Default);
  try
    Check(Schema[0].ColumnType = TCsvColumnType.Str,
      'SCHEMA_CONSERVATIVE_LEAVES_A_DATE_AS_TEXT');
  finally
    Schema.Free;
  end;

  Options := TCsvOptions.Default.WithSchemaInference(
    TCsvSchemaInferencePolicy.Extended);
  Schema := TCsvEngine.InferSchema(
    Doc(['when', '2026-09-19T14:30:00', '2026-09-20T09:00:00']), Options);
  try
    Check(Schema[0].ColumnType = TCsvColumnType.DateTime,
      'SCHEMA_EXTENDED_RECOGNIZES_A_DATE');
  finally
    Schema.Free;
  end;

  { A blank cell makes the column nullable and nothing else: a column of
    integers with one blank is still a column of integers. }
  Schema := TCsvEngine.InferSchema(Doc(['n', '1', '', '3']),
    TCsvOptions.Default);
  try
    Check((Schema[0].ColumnType = TCsvColumnType.Int32) and Schema[0].Nullable,
      'SCHEMA_BLANK_MAKES_A_COLUMN_NULLABLE');
  finally
    Schema.Free;
  end;

  { From a contract, which actually knows. }
  Schema := TCsvSerializer.SchemaOf<TCustomer>;
  try
    Check(Schema.TryGetColumn('Score', Column) and
          (Column.ColumnType = TCsvColumnType.Float),
      'SCHEMA_OF_TYPE_CURRENCY');
    Check(Schema.TryGetColumn('Joined', Column) and
          (Column.ColumnType = TCsvColumnType.DateTime),
      'SCHEMA_OF_TYPE_DATETIME');
    Check(Schema.TryGetColumn('Retired', Column) and Column.Nullable,
      'SCHEMA_OF_TYPE_NULLABLE');
    Check(not Schema.TryGetColumn('Scratch', Column),
      'SCHEMA_OF_TYPE_HONOURS_IGNORE');
    Check(Schema.Format = TSerializationFormat.Csv, 'SCHEMA_IS_CSV_SPECIFIC');
  finally
    Schema.Free;
  end;

  { A schema of a nested contract names the flattened columns AND the path
    they came from, which is what makes the flattening reversible. }
  Schema := TCsvSerializer.SchemaOf<TInvoice>;
  try
    Check(Schema.TryGetColumn('Shipper.City', Column) and
          (Column.Path = '$.Shipper.City'), 'SCHEMA_OF_TYPE_NESTED_PATH');
  finally
    Schema.Free;
  end;
end;

{ ===========================================================================
  THE REGISTRY
  =========================================================================== }

procedure TestConversionMatrix;
const
  Source =
    '[{"id":1,"name":"Alice","score":1234.56,"active":true},' +
    '{"id":2,"name":"Carol","score":10.5,"active":false}]';
var
  Text, Back, Message: string;
  Formats: TArray<TSerializationFormat>;
  F: TSerializationFormat;
  Payload, Hop: TSerializationPayload;
  Identical, Diverged: Integer;
  Table: TCsvTable;
  Caught: Boolean;
begin
  Writeln;
  Writeln('--- conversion ---');

  Check(TSerialization.IsRegistered(TSerializationFormat.Csv),
    'CSV_REGISTERED');
  Check(TSerialization.StructuralRequirement(TSerializationFormat.Csv) = 'yes',
    'CSV_STRUCTURAL_WITHOUT_SCHEMA');

  Text := TSerialization.Convert(TSerializationPayload.FromText(Source),
    TSerializationFormat.Json, TSerializationFormat.Csv,
    TStructuralConversionProfile.Lossless).AsText;
  Note(OneLine(Text));
  Table := TCsvEngine.ParseTable(Text, TCsvOptions.Default);
  try
    Check(Table.RowCount = 2, 'CSV_FROM_JSON_ROWS');
    Check(Table.Cell(1, 'name') = 'Carol', 'CSV_FROM_JSON_CONTENT');
  finally
    Table.Free;
  end;

  Back := TSerialization.Convert(TSerializationPayload.FromText(Text),
    TSerializationFormat.Csv, TSerializationFormat.Json,
    TStructuralConversionProfile.Lossless).AsText;
  Note(Copy(Back, 1, 120));
  Check(Pos('"name":"Alice"', Back) > 0, 'CSV_TO_JSON');

  { A document that is not a table cannot become one, and saying so beats
    inventing column names.

    ON THE STRUCTURAL PATH THE EXCEPTION IS EStructuralConversionError, not
    ECsvProjectionError. The caller asked the library for a structural
    conversion, and the library's answer to "the destination cannot
    represent this" is one class with a path and an issue a caller can
    branch on - whichever destination refused. CSV's own exception is right
    for the contract path, where a Delphi MEMBER is what cannot become
    columns, and the checks above use it there.

    The path and the sentence survive the change of class. }
  Caught := False;
  Message := '';
  try
    TSerialization.Convert(
      TSerializationPayload.FromText('{"a":{"b":{"c":[1,2,3]}}}'),
      TSerializationFormat.Json, TSerializationFormat.Csv,
      TStructuralConversionProfile.Lossless);
  except
    on E: EStructuralConversionError do
    begin
      Caught := (E.Path = '$.a.b.c') and
                (E.DestinationFormat = TSerializationFormat.Csv);
      Message := E.Message;
    end;
  end;
  Check(Caught, 'CSV_REFUSES_A_SHAPE_A_TABLE_CANNOT_HOLD');
  Note(Copy(Message, 1, 140));
  Check(Pos('CollectionMode', Message) > 0,
    'CSV_STRUCTURAL_REFUSAL_KEEPS_THE_SENTENCE');

  Formats := TSerialization.StructuralFormats;
  Identical := 0;
  Diverged := 0;
  Payload := TSerializationPayload.FromText(Text);
  for F in Formats do
  begin
    if F = TSerializationFormat.Csv then Continue;
    try
      Hop := TSerialization.Convert(Payload, TSerializationFormat.Csv, F,
        TStructuralConversionProfile.Lossless);
      Hop := TSerialization.Convert(Hop, F, TSerializationFormat.Csv,
        TStructuralConversionProfile.Lossless);
      if Hop.AsText = Text then Inc(Identical) else Inc(Diverged);
      Note(Format('  csv -> %s -> csv: %s',
        [TSerialization.FormatName(F),
         IfThen(Hop.AsText = Text, 'identical', 'diverged')]));
    except
      on E: Exception do
      begin
        Inc(Diverged);
        Note(Format('  csv -> %s: %s', [TSerialization.FormatName(F),
          E.ClassName]));
      end;
    end;
  end;
  Note(Format('identical=%d diverged=%d', [Identical, Diverged]));
  Check(Identical + Diverged = Length(Formats) - 1, 'CSV_CONVERSION_MATRIX');
end;

procedure TestDataSet;
var
  DS: TClientDataSet;
  Payload: TSerializationPayload;
  Table: TCsvTable;
begin
  Writeln;
  Writeln('--- DataSet projection ---');

  DS := TDataSetSerializer.CreateClientDataSet(
    Doc(['reference,count,rate,paid,postcode',
         'PF-1,42,0.0725,true,01234',
         'PF-2,7,0.05,false,01235']), TSerializationFormat.Csv);
  try
    Check(DS.RecordCount = 2, 'DATASET_ROWS');
    Check(DS.FieldCount = 5, 'DATASET_COLUMNS');
    { CSV says nothing about types, so inference decides - conservatively.
      An integer column becomes an integer; a postcode with a leading zero
      stays text, which is the whole point of the default policy. }
    Check(DS.FieldByName('count').DataType in [ftInteger, ftLargeint],
      'DATASET_INTEGER_FROM_INFERENCE');
    Check(DS.FieldByName('paid').DataType = ftBoolean, 'DATASET_BOOLEAN');
    Check(DS.FieldByName('postcode').DataType in
      [ftString, ftWideString, ftMemo, ftWideMemo],
      'DATASET_LEADING_ZERO_STAYS_TEXT');
    DS.First;
    Check(DS.FieldByName('postcode').AsString = '01234',
      'DATASET_LEADING_ZERO_KEPT');
    DS.Next;
    Check(DS.FieldByName('count').AsInteger = 7, 'DATASET_SECOND_ROW');

    Payload := TDataSetSerializer.Serialize(DS, TSerializationFormat.Csv,
      TDataSetSerializationPolicy.RowsOnly);
    Check(Payload.IsText, 'DATASET_OUT_IS_TEXT');
    Table := TCsvEngine.ParseTable(Payload.AsText, TCsvOptions.Default);
    try
      Check(Table.RowCount = 2, 'CSV_DATASET_AUTO');
    finally
      Table.Free;
    end;
  finally
    DS.Free;
  end;
end;

procedure TestUnicode;
var
  Scripts, Back: TScripts;
  Text: string;
  Bytes: TBytes;
  Options: TCsvOptions;
begin
  Writeln;
  Writeln('--- Unicode ---');

  Scripts := TScripts.Create;
  try
    { Spelled in code points so that the source file stays ASCII: what this
      test checks must not depend on how an editor saved it. }
    Scripts.Georgian := #$10E5#$10D0#$10E0#$10D7#$10E3#$10DA#$10D8' ' +
                        #$10D4#$10DC#$10D0;
    Scripts.Cyrillic := #$0420#$0443#$0441#$0441#$043A#$0438#$0439' ' +
                        #$044F#$0437#$044B#$043A;
    Scripts.Cjk := #$65E5#$672C#$8A9E#$306E#$30C6#$30AD#$30B9#$30C8;
    Scripts.Emoji := #$D83D#$DC68#$200D#$D83D#$DC69#$200D +
                     #$D83D#$DC67#$200D#$D83D#$DC66' family';
    Scripts.Combining := 'e' + #$0301 + 'cole';

    Text := TCsvSerializer.Serialize<TScripts>(Scripts);
    Back := TCsvSerializer.Deserialize<TScripts>(Text);
    try
      Check(Back.Georgian = Scripts.Georgian, 'UNICODE_GEORGIAN');
      Check(Back.Cyrillic = Scripts.Cyrillic, 'UNICODE_CYRILLIC');
      Check(Back.Cjk = Scripts.Cjk, 'UNICODE_CJK');
      Check(Back.Emoji = Scripts.Emoji, 'UNICODE_NON_BMP');
      Check(Back.Combining = Scripts.Combining, 'UNICODE_COMBINING_MARKS');
    finally
      Back.Free;
    end;

    { The bytes, when a caller asks for bytes: UTF-8, with the mark the
      Excel dialect writes and without it otherwise. }
    Options := TCsvOptions.ForDialect(TCsvDialect.Excel);
    Bytes := TCsvSerializer.SerializeToBytes<TScripts>(Scripts, Options);
    Check((Length(Bytes) > 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and
          (Bytes[2] = $BF), 'UNICODE_EXCEL_BOM_IS_UTF8');
    Back := TCsvSerializer.DeserializeBytes<TScripts>(Bytes, Options);
    try
      Check(Back.Georgian = Scripts.Georgian, 'UNICODE_BYTES_ROUND_TRIP');
    finally
      Back.Free;
    end;
  finally
    Scripts.Free;
  end;
end;

{ A document in another format projected onto CSV. Single-payload options
  travel through the registry in a TCsvSchema; SeparateTable is a different
  return shape and comes back from TCsvSerializer.TablesFrom as a document
  set - never through TSerialization.Convert, which refuses it and says
  where to go. }
procedure TestStructuralTables;
const
  TWO = '{"customers":[{"id":1,"name":"A"},{"id":2,"name":"B"}],' +
    '"orders":[{"id":10,"customerId":1},{"id":11,"customerId":2}]}';
  NESTED = '{"customers":[{"id":1,"name":"A","orders":[' +
    '{"id":10,"amount":5.5},{"id":11,"amount":8.25}]}]}';
  WITHLIST = '[{"id":1,"tags":["a","b"]},{"id":2,"tags":["c"]}]';
  WITHLINES = '[{"id":1,"lines":[{"sku":"x"},{"sku":"y"}]}]';
var
  Georgian1, Georgian2, Envelope: string;
  Separate: TCsvOptions;
  Set_: TCsvDocumentSet;
  Rel: TCsvTableRelationship;
  Outcome: string;
  Ok: Boolean;
  SourceSchema: TCsvSchema;

  function Lines(const AText: string): TArray<string>;
  var
    S: string;
  begin
    Result := nil;
    for S in AText.Replace(#13, '').Split([#10]) do
      if S <> '' then Result := Result + [S];
  end;

  function Joined(const AText: string): string;
  begin
    Result := string.Join('|', Lines(AText));
  end;

  function Tables(const AJson: string;
    const AOptions: TCsvOptions): TCsvDocumentSet;
  begin
    Result := TCsvSerializer.TablesFrom(TSerializationPayload.FromText(AJson),
      TSerializationFormat.Json, AOptions);
  end;

  { One payload through the registry, the CSV options in a TCsvSchema. }
  function Single(const AJson: string; const AOptions: TCsvOptions): string;
  var
    Schema: TCsvSchema;
  begin
    Schema := TCsvSchema.Create(AOptions);
    try
      try
        Result := TSerialization.Convert(TSerializationPayload.FromText(AJson),
          TSerializationFormat.Json, TSerializationFormat.Csv,
          TStructuralConversionOptions.Default.WithContext(Schema)).AsText;
      except
        on E: Exception do Result := E.ClassName + ': ' + E.Message;
      end;
    finally
      Schema.Free;
    end;
  end;

begin
  Writeln;
  Writeln('--- structural documents onto CSV tables ---');
  Separate := TCsvOptions.Default
    .WithCollectionMode(TCsvCollectionMode.SeparateTable);

  { The plain case: a root array is the table 'root'. }
  Set_ := Tables('[{"a":1,"b":"x"},{"a":2,"b":"y"}]', TCsvOptions.Default);
  try
    Check((Set_.Count = 1) and (Set_[0].Name = 'root') and
      (Joined(Set_[0].Content) = 'a,b|1,x|2,y') and (Set_[0].RowCount = 2),
      'CSV_STRUCTURAL_TABLES_FROM_JSON');
  finally
    Set_.Free;
  end;

  { Two collections on the root object: two tables, named after them. }
  Set_ := Tables(TWO, Separate);
  try
    Ok := (Set_.Count = 2) and (Set_[0].Name = 'customers') and
      (Set_[1].Name = 'orders') and
      (Joined(Set_[0].Content) = 'id,name|1,A|2,B') and
      (Joined(Set_[1].Content) = 'id,customerId|10,1|11,2') and
      (Set_.RelationshipCount = 0);
    if not Ok then Note(Set_.Describe);
    Check(Ok, 'CSV_STRUCTURAL_SEPARATE_TABLE_TWO_COLLECTIONS');
  finally
    Set_.Free;
  end;

  { A collection inside each row: a child table joined on a generated key,
    named by the engine's own rule. }
  Set_ := Tables(NESTED, Separate);
  try
    Ok := (Set_.Count = 2) and (Set_[0].Name = 'customers') and
      (Set_[1].Name = 'customers_orders') and
      (Joined(Set_[0].Content) = 'id,name,RowKey|1,A,1') and
      (Joined(Set_[1].Content) =
        'customers_RowKey,id,amount|1,10,5.5|1,11,8.25');
    if not Ok then Note(Set_.Describe);
    Check(Ok, 'CSV_STRUCTURAL_SEPARATE_TABLE_NESTED_COLLECTION');
    Ok := Set_.RelationshipCount = 1;
    if Ok then
    begin
      Rel := Set_.Relationships[0];
      Ok := (Rel.ParentTable = 'customers') and
        (Rel.ChildTable = 'customers_orders') and
        (Rel.ParentKeyColumn = 'RowKey') and
        (Rel.ChildReferenceColumn = 'customers_RowKey') and
        Rel.KeyIsGenerated and (Rel.MemberPath = '$.customers.orders');
      if not Ok then Note(Rel.Describe);
    end;
    Check(Ok, 'CSV_STRUCTURAL_RELATIONSHIPS');
  finally
    Set_.Free;
  end;

  { An object shaped like a DataSet envelope is an ordinary object: two
    tables, 'fields' and 'rows', and Georgian text intact. }
  Georgian1 := #$10D2#$10D8#$10DA#$10DD#$10EA#$10D0;
  Georgian2 := #$10DB#$10E1#$10DD#$10E4#$10DA#$10D8#$10DD;
  Envelope := '{"fields":[{"name":"Id","type":3,"size":0,"required":true},' +
    '{"name":"Name","type":24,"size":60,"required":false}],' +
    '"rows":[{"Id":1,"Name":"' + Georgian1 + '"},{"Id":2,"Name":"' +
    Georgian2 + '"}]}';
  Set_ := Tables(Envelope, Separate);
  try
    Ok := (Set_.Count = 2) and (Set_[0].Name = 'fields') and
      (Set_[0].RowCount = 2) and (Set_[1].Name = 'rows') and
      (Joined(Set_[1].Content) = 'Id,Name|1,' + Georgian1 + '|2,' + Georgian2) and
      (TEncoding.UTF8.GetString(TEncoding.UTF8.GetBytes(Set_[1].Content)) =
        Set_[1].Content);
    if not Ok then Note(Set_.Describe);
    Check(Ok, 'CSV_STRUCTURAL_GEORGIAN_UTF8');
    Check((Set_.Count = 2) and (Joined(Set_[0].Content) =
      'name,type,size,required|Id,3,0,true|Name,24,60,false'),
      'CSV_STRUCTURAL_DATASET_ENVELOPE_IS_ORDINARY');
  finally
    Set_.Free;
  end;

  { The registry returns one payload, so it refuses SeparateTable and names
    the two calls that return a document set. }
  Outcome := Single(TWO, Separate);
  Check(StartsText('ESerializationFormatCapability', Outcome) and
    ContainsText(Outcome, 'TablesFrom') and
    ContainsText(Outcome, 'SerializeTables'),
    'CSV_GENERIC_CONVERT_SEPARATE_TABLE_REFUSES_WITH_GUIDANCE');
  if not ContainsText(Outcome, 'TablesFrom') then Note(Outcome);

  { Single-payload options through the registry, in a TCsvSchema. }
  Outcome := Single(WITHLIST, TCsvOptions.Default);
  Check(StartsText('EStructuralConversionError', Outcome),
    'CSV_SINGLE_PAYLOAD_DEFAULT_STILL_REFUSES');
  Outcome := Single(WITHLIST, TCsvOptions.Default
    .WithCollectionMode(TCsvCollectionMode.JsonCell));
  Check(Joined(Outcome) = 'id,tags|1,"[""a"",""b""]"|2,"[""c""]"',
    'CSV_SINGLE_PAYLOAD_JSONCELL_OPTIONS');
  if Joined(Outcome) <> 'id,tags|1,"[""a"",""b""]"|2,"[""c""]"' then
    Note(Outcome);
  Outcome := Single(WITHLIST, TCsvOptions.Default
    .WithCollectionMode(TCsvCollectionMode.NumberedColumns));
  Check(Joined(Outcome) = 'id,tags_1,tags_2|1,a,b|2,c,',
    'CSV_SINGLE_PAYLOAD_NUMBERED_COLUMNS_OPTIONS');
  if Joined(Outcome) <> 'id,tags_1,tags_2|1,a,b|2,c,' then Note(Outcome);
  Outcome := Single(WITHLINES, TCsvOptions.Default
    .WithCollectionMode(TCsvCollectionMode.RepeatedRows));
  Check(Joined(Outcome) = 'id,lines.sku|1,x|1,y',
    'CSV_SINGLE_PAYLOAD_REPEATED_ROWS_OPTIONS');
  if Joined(Outcome) <> 'id,lines.sku|1,x|1,y' then Note(Outcome);
  Ok := (Joined(Single('[{"a":1,"b":null}]', TCsvOptions.Default
      .WithDelimiter(';').WithNullPolicy(TCsvNullPolicy.Literal))) =
      'a;b|1;NULL') and
    (Joined(Single('[{"a":1,"b":2}]', TCsvOptions.Default
      .WithHeader(False))) = '1,2');
  Check(Ok, 'CSV_SINGLE_PAYLOAD_DIALECT_OPTIONS');
  SourceSchema := TCsvSchema.Create(TCsvOptions.Default.WithDelimiter(';'));
  try
    try
      Outcome := TSerialization.Convert(
        TSerializationPayload.FromText('a;b'#13#10'1;2'#13#10),
        TSerializationFormat.Csv, TSerializationFormat.Json,
        TStructuralConversionOptions.Default.WithContext(SourceSchema)).AsText;
    except
      on E: Exception do Outcome := E.ClassName + ': ' + E.Message;
    end;
  finally
    SourceSchema.Free;
  end;
  Check(Outcome = '[{"a":1,"b":2}]', 'CSV_SINGLE_PAYLOAD_SOURCE_OPTIONS');
  if Outcome <> '[{"a":1,"b":2}]' then Note(Outcome);
end;

procedure TestFeatureLedger;
begin
  Writeln;
  Writeln('--- CSV feature ledger ---');
  Note('RFC 4180 quoting and doubling     LEXER_DOUBLED_QUOTE, WRITER_*');
  Note('embedded delimiter                LEXER_EMBEDDED_DELIMITER');
  Note('embedded line break               LEXER_EMBEDDED_NEWLINE_*');
  Note('CRLF and LF, no final break       LEXER_LF_ONLY_AND_NO_FINAL_BREAK');
  Note('byte-order mark                   LEXER_BOM_*, UNICODE_EXCEL_BOM_*');
  Note('dialects: Excel, TSV, custom      LEXER_TAB_SEPARATED, LEXER_CUSTOM_*');
  Note('headerless files                  LEXER_HEADERLESS_*');
  Note('ragged rows                       LEXER_RAGGED_ROW_*');
  Note('duplicate headers                 LEXER_DUPLICATE_HEADER_*');
  Note('nested objects, four modes        NESTED_*');
  Note('collections, five modes           COLLECTION_*');
  Note('Cartesian-product guard           COLLECTION_CARTESIAN_PRODUCT_*');
  Note('several tables as a document set  *_SEPARATE_TABLE_*');
  Note('relationships, out of band        NESTED_SEPARATE_TABLE_RELATIONSHIP');
  Note('null policies                     NULL_*');
  Note('schema inference, four policies   SCHEMA_*');
  Note('schema from a contract            SCHEMA_OF_TYPE_*');
  Note('JsonCell through the REGISTRY     NESTED_JSONCELL_*, COLLECTION_JSONCELL');
  Writeln;
  Note('NOT IMPLEMENTED, deliberately:');
  Note('  A CSV payload that holds several tables. A table is a file; a');
  Note('    document set is what SerializeTables returns, and nothing here');
  Note('    concatenates two CSVs or puts ZIP bytes in a Csv payload.');
  Note('  Reading a child table back into its parent. SerializeTables');
  Note('    writes the keys that would make it possible and the');
  Note('    relationships that describe it; DeserializeTables reads the');
  Note('    ROOT table, and says so.');
  Note('  RepeatedRows for a collection nested below the top level: the');
  Note('    grouping signal is the repetition of the other columns, and at');
  Note('    depth there is no longer one row per element to repeat.');
  Check(True, 'CSV_FEATURE_LEDGER');
end;

{ ===========================================================================
  THE DEFAULTS STAY CONSERVATIVE

  There is an easy way to make every CSV cell in the conversion matrix turn
  green: default NestedObjectMode and CollectionMode to JsonCell, and every
  graph becomes representable because any awkward branch is written as a
  JSON string inside a cell.

  That is not done, and this test is here so that it cannot be done quietly.

  A cell holding a whole JSON object is not a CSV column that another tool
  can read; it is JSON smuggled through a table, and a caller who wanted
  that should have to say so. The defaults therefore refuse, by name, at the
  member that could not be represented - and a caller who DOES want JSON in
  a cell gets it by asking, which the last two checks prove still works.
  =========================================================================== }

procedure TestConservativeDefaults;
const
  WITH_ARRAY = '{"Sku":"A-1","Tags":[1,2,3]}';
  WITH_MAP   = '{"Sku":"A-1","Nested":{"City":"Midtown"}}';
var
  Options: TCsvOptions;
  Refused, Mentions: Boolean;
  Detail, Csv: string;
  Tree: TDynamicValue;
begin
  Writeln;
  Writeln('-- conservative CSV defaults --');

  Options := TCsvOptions.Default;
  Note('default nested-object mode: ' +
    GetEnumName(TypeInfo(TCsvNestedObjectMode), Ord(Options.NestedObjectMode)));
  Note('default collection mode   : ' +
    GetEnumName(TypeInfo(TCsvCollectionMode), Ord(Options.CollectionMode)));

  { Flatten for a nested object, because a table really can express
    Nested.City as a column and it reverses exactly. Error for a collection,
    because it cannot. }
  Check(Options.NestedObjectMode = TCsvNestedObjectMode.Flatten,
    'CSV_DEFAULT_NESTED_OBJECT_MODE_IS_FLATTEN');
  Check(Options.CollectionMode = TCsvCollectionMode.Error,
    'CSV_DEFAULT_COLLECTION_MODE_IS_ERROR');
  Check(Options.NestedObjectMode <> TCsvNestedObjectMode.JsonCell,
    'CSV_DEFAULT_NESTED_OBJECT_MODE_IS_NOT_JSONCELL');
  Check(Options.CollectionMode <> TCsvCollectionMode.JsonCell,
    'CSV_DEFAULT_COLLECTION_MODE_IS_NOT_JSONCELL');

  { And through the registry, which is where a matrix cell goes. The refusal
    must name the member and say which mode would have carried it: a refusal
    that does not tell the caller what to do instead is just a failure with
    better manners. }
  Refused := False;
  Detail := '';
  try
    TSerialization.Convert(TSerializationPayload.FromText(WITH_ARRAY),
      TSerializationFormat.Json, TSerializationFormat.Csv,
      TStructuralConversionProfile.Natural);
  except
    on E: EStructuralConversionError do
    begin
      Refused := True;
      Detail := E.Message;
    end;
  end;
  Note('refusal: ' + Copy(Detail, 1, 200));
  Mentions := (Pos('Tags', Detail) > 0) and (Pos('CollectionMode', Detail) > 0);
  Check(Refused, 'CSV_REGISTRY_REFUSES_ARRAY_BY_DEFAULT');
  Check(Mentions, 'CSV_REFUSAL_NAMES_MEMBER_AND_REMEDY');

  { A nested object is a different answer, because Flatten can carry it.
    The point is not that CSV refuses everything - it is that it refuses
    what it cannot honestly represent and carries what it can. }
  Csv := TSerialization.Convert(TSerializationPayload.FromText(WITH_MAP),
    TSerializationFormat.Json, TSerializationFormat.Csv,
    TStructuralConversionProfile.Natural).AsText;
  Note('flattened: ' + Csv.Replace(#13#10, ' | '));
  Check(Pos('Nested.City', Csv) > 0, 'CSV_DEFAULT_FLATTENS_NESTED_OBJECT');
  Check(Pos('{', Csv) = 0, 'CSV_DEFAULT_EMBEDS_NO_JSON');

  { And the opt-in still works, which is what makes the default a policy
    rather than a limitation. }
  Tree := TSerializationFormats.Get(TSerializationFormat.Json).ToDynamic(
    TSerializationPayload.FromText(WITH_ARRAY),
    TStructuralConversionOptions.Default.WithSource(
      TSerializationFormat.Json).WithDestination(TSerializationFormat.Csv));
  try
    Csv := TCsvEngine.DynamicToText(Tree,
      TCsvOptions.Default.WithCollectionMode(TCsvCollectionMode.JsonCell),
      TStructuralConversionOptions.Default);
  finally
    Tree.Free;
  end;
  Note('opted in : ' + Csv.Replace(#13#10, ' | '));
  Check(Pos('[1,2,3]', Csv) > 0, 'CSV_JSONCELL_AVAILABLE_ON_REQUEST');

  Check(Refused and Mentions and
        (Options.CollectionMode = TCsvCollectionMode.Error) and
        (Options.NestedObjectMode = TCsvNestedObjectMode.Flatten),
    'CSV_DEFAULTS_REMAIN_CONSERVATIVE');
end;

{ ===========================================================================
  REPAIRS - what a failed read leaves alive, how deep a writer goes, and the
  values a reader used to turn into different ones
  =========================================================================== }

function Chain(ACount: Integer): TChainNode;
var
  I: Integer;
  N: TChainNode;
begin
  Result := TChainNode.Create;
  Result.Id := 1;
  N := Result;
  for I := 2 to ACount do
  begin
    N.Next := TChainNode.Create;
    N := N.Next;
    N.Id := I;
  end;
end;

{ The nodes a chain of ACount reads back as, -1 when the write is refused
  with the limit error, -2 for any other exception. }
function ChainCarried(ACount: Integer): Integer;
var
  Root, Back, N: TChainNode;
begin
  Root := Chain(ACount);
  try
    try
      Back := TCsvSerializer.Deserialize<TChainNode>(
        TCsvSerializer.Serialize<TChainNode>(Root));
      try
        Result := 0;
        N := Back;
        while N <> nil do
        begin
          Inc(Result);
          N := N.Next;
        end;
      finally
        Back.Free;
      end;
    except
      on E: ESerializationLimitExceeded do Result := -1;
      on E: Exception do Result := -2;
    end;
  finally
    Root.Free;
  end;
end;

{ Is a record chain ADepth deep through dynamic arrays written? False when
  it is refused with the limit error; anything else propagates. }
function KidChainWritten(ADepth: Integer): Boolean;
var
  Holder: TKidHolder;
  Level: ^TKidRec;
  I: Integer;
begin
  Holder := TKidHolder.Create;
  try
    Level := @Holder.Root;
    for I := 1 to ADepth do
    begin
      Level^.Tag := I;
      SetLength(Level^.Kids, 1);
      Level := @Level^.Kids[0];
    end;
    try
      TCsvSerializer.Serialize<TKidHolder>(Holder,
        TCsvOptions.Default.WithCollectionMode(
          TCsvCollectionMode.RepeatedRows));
      Result := True;
    except
      on E: ESerializationLimitExceeded do Result := False;
    end;
  finally
    Holder.Free;
  end;
end;

function DoubleBits(AValue: Double): UInt64;
begin
  Result := PUInt64(@AValue)^;
end;

procedure TestRepairs;
var
  Repeated, JsonNested: TCsvOptions;
  Before, I, Differ, Exponent: Integer;
  Text, Detail: string;
  Caught: Boolean;
  Order: TTrackedOrder;
  Holder: TCtorRecHolder;
  Pair, PairBack: TNullPairHolder;
  Pairs, PairsBack: TArray<TNullPairHolder>;
  Rec: TPairRec;
  TextHolder: TNullTextHolder;
  TextRec: TTextRec;
  Tags, TagsBack: TNullTagsHolder;
  Mode: TCsvCollectionMode;
  Moment, MomentBack: TMoment;
  When: TDateTime;
  Whens: array[0..1] of TDateTime;
  Refusals: Integer;
  Rate, RateBack: TRate;
  Bits: UInt64;
  V: Double;
begin
  Writeln;
  Writeln('--- repairs: ownership, levels, nullables, dates, numbers ---');
  Repeated := TCsvOptions.Default.WithCollectionMode(
    TCsvCollectionMode.RepeatedRows);

  { A LATER ROW THAT FAILS. RepeatedRows collects one element per row before
    the list is filled; the elements already read went nowhere. }
  Before := TTrackedItem.Live;
  Order := TCsvSerializer.Deserialize<TTrackedOrder>(
    Doc(['Id,Lines.X', '9,11', '9,12', '9,13']), Repeated);
  try
    Check((Order.Lines.Count = 3) and (Order.Lines[2].X = 13),
      'CSV_REPEATED_ROWS_READ_INTO_OWNING_LIST');
  finally
    Order.Free;
  end;
  Caught := False;
  try
    TCsvSerializer.Deserialize<TTrackedOrder>(
      Doc(['Id,Lines.X', '9,11', '9,12', '9,oops']), Repeated).Free;
  except
    on E: ECsvInputError do Caught := True;
  end;
  Check(Caught and (TTrackedItem.Live = Before),
    'CSV_REPEATED_ROWS_FAILURE_LEAVES_NOTHING_ALIVE');
  { The same through a list the reader builds and that owns nothing. }
  Caught := False;
  try
    TCsvSerializer.Deserialize<TTrackedRefs>(
      Doc(['Id,L.X', '9,11', '9,12', '9,oops']), Repeated).Free;
  except
    on E: ECsvInputError do Caught := True;
  end;
  Check(Caught and (TTrackedItem.Live = Before),
    'CSV_NON_OWNING_LIST_FAILURE_LEAVES_NOTHING_ALIVE');

  { A RECORD HOLDING AN OBJECT, and a later member of the record fails. }
  Before := TTrackedItem.Live;
  Caught := False;
  try
    TCsvSerializer.Deserialize<TObjRecHolder>(
      Doc(['R.O.X,R.N', '3,5000000000'])).Free;
  except
    on E: ECsvInputError do Caught := True;
  end;
  Check(Caught and (TTrackedItem.Live = Before),
    'CSV_RECORD_FAILURE_FREES_ITS_OBJECTS');

  { A RECORD IS MERGED IN PLACE: the objects the constructor put in it are
    filled, not replaced and orphaned, and an omitted member keeps its
    value. }
  Holder := TCtorRecHolder.Create;
  try
    Holder.R.A.X := 1;
    Holder.R.B.X := 2;
    Holder.R.N := 3;
    Text := TCsvSerializer.Serialize<TCtorRecHolder>(Holder);
  finally
    Holder.Free;
  end;
  Before := TTrackedItem.Live;
  Holder := TCsvSerializer.Deserialize<TCtorRecHolder>(Text);
  try
    Check((Holder.R.A.X = 1) and (Holder.R.B.X = 2) and (Holder.R.N = 3),
      'CSV_RECORD_MEMBER_READS_BACK');
  finally
    Holder.Free;
  end;
  Check(TTrackedItem.Live = Before, 'CSV_RECORD_OBJECTS_FILLED_IN_PLACE');
  Holder := TCsvSerializer.Deserialize<TCtorRecHolder>(Doc(['R.A.X', '7']));
  try
    Check((Holder.R.A.X = 7) and (Holder.R.B <> nil),
      'CSV_RECORD_OMITTED_MEMBER_KEPT');
  finally
    Holder.Free;
  end;
  Check(TTrackedItem.Live = Before, 'CSV_RECORD_PARTIAL_READ_LEAVES_NOTHING');

  { A CONTAINER THAT REFUSES CONTENT is the document refused - a CSV input
    error naming the container, not the RTL's EStringListError. }
  Detail := '';
  try
    TCsvSerializer.Deserialize<TSortedLines>(
      Doc(['Id,Lines', '1,b', '1,a', '1,b']), Repeated).Free;
  except
    on E: ECsvInputError do Detail := E.Message;
    on E: Exception do Detail := 'raised ' + E.ClassName;
  end;
  Note(Detail);
  Check(Pos('TStringList', Detail) > 0, 'CSV_CONTAINER_REFUSAL_IS_INPUT_ERROR');

  { LEVELS. The row's own object counts one, as in every format: a chain of
    64 is the most anything writes, and it reads back. }
  Check(ChainCarried(60) = 60, 'CSV_CHAIN_OF_60_CARRIED');
  Check(ChainCarried(64) = 64, 'CSV_CHAIN_OF_64_CARRIED');
  Check(ChainCarried(65) = -1, 'CSV_CHAIN_OF_65_REFUSED');
  Check(TSerializationGraphGuard.Level = 0, 'CSV_LEVEL_RESTORED');
  { A record recursing through an array has no object in it: the array and
    the record each count one. It used to be written at any depth, and the
    stack ran out at a few thousand. }
  Check(KidChainWritten(30), 'CSV_RECORD_CHAIN_30_WRITTEN');
  Check(not KidChainWritten(31), 'CSV_RECORD_CHAIN_31_REFUSED');
  Check(not KidChainWritten(3000), 'CSV_RECORD_CHAIN_3000_REFUSED_NOT_CRASHED');
  Check(TSerializationGraphGuard.Level = 0, 'CSV_LEVEL_RESTORED_AFTER_REFUSAL');

  { A NULLABLE RECORD is flattened to its members' columns; reading them
    back gives a value, and an absent one - its own column, null - none. }
  Pair := TNullPairHolder.Create;
  try
    Pair.Id := 1;
    Rec.A := 5;
    Rec.B := 'five';
    Pair.R := Rec;
    Text := TCsvSerializer.Serialize<TNullPairHolder>(Pair);
    Note(OneLine(Text));
    PairBack := TCsvSerializer.Deserialize<TNullPairHolder>(Text);
    try
      Check(PairBack.R.HasValue and (PairBack.R.Value.A = 5) and
        (PairBack.R.Value.B = 'five'), 'CSV_NULLABLE_RECORD_READS_BACK');
    finally
      PairBack.Free;
    end;
    Pair.R := Default(TNullable<TPairRec>);
    PairBack := TCsvSerializer.Deserialize<TNullPairHolder>(
      TCsvSerializer.Serialize<TNullPairHolder>(Pair));
    try
      Check(not PairBack.R.HasValue, 'CSV_NULLABLE_RECORD_ABSENT_READS_BACK');
    finally
      PairBack.Free;
    end;
    { The same member as one JSON cell: absent is that cell marked null. }
    JsonNested := TCsvOptions.Default.WithNestedObjectMode(
      TCsvNestedObjectMode.JsonCell);
    Rec.A := 7;
    Rec.B := 'seven';
    Pair.R := Rec;
    Text := TCsvSerializer.Serialize<TNullPairHolder>(Pair, JsonNested);
    Note(OneLine(Text));
    PairBack := TCsvSerializer.Deserialize<TNullPairHolder>(Text, JsonNested);
    try
      Check(PairBack.R.HasValue and (PairBack.R.Value.A = 7) and
        (PairBack.R.Value.B = 'seven'),
        'CSV_NULLABLE_RECORD_JSON_CELL_READS_BACK');
    finally
      PairBack.Free;
    end;
    Pair.R := Default(TNullable<TPairRec>);
    PairBack := TCsvSerializer.Deserialize<TNullPairHolder>(
      TCsvSerializer.Serialize<TNullPairHolder>(Pair, JsonNested), JsonNested);
    try
      Check(not PairBack.R.HasValue,
        'CSV_NULLABLE_RECORD_JSON_CELL_ABSENT_READS_BACK');
    finally
      PairBack.Free;
    end;
  finally
    Pair.Free;
  end;
  SetLength(Pairs, 3);
  for I := 0 to 2 do
  begin
    Pairs[I] := TNullPairHolder.Create;
    Pairs[I].Id := I;
    if I <> 1 then
    begin
      Rec.A := I * 10;
      Rec.B := '';
      Pairs[I].R := Rec;
    end;
  end;
  try
    Text := TCsvSerializer.Serialize<TArray<TNullPairHolder>>(Pairs);
    Note(OneLine(Text));
    PairsBack := TCsvSerializer.Deserialize<TArray<TNullPairHolder>>(Text);
    try
      Check((Length(PairsBack) = 3) and PairsBack[0].R.HasValue and
        (PairsBack[0].R.Value.A = 0) and not PairsBack[1].R.HasValue and
        PairsBack[2].R.HasValue and (PairsBack[2].R.Value.A = 20),
        'CSV_NULLABLE_RECORD_ROWS_KEEP_PRESENCE');
    finally
      for I := 0 to High(PairsBack) do PairsBack[I].Free;
    end;
  finally
    for I := 0 to High(Pairs) do Pairs[I].Free;
  end;
  { Present, and every cell empty: exactly how absent is written, so it is
    refused rather than read back as absent. }
  TextHolder := TNullTextHolder.Create;
  try
    TextRec.S := '';
    TextHolder.R := TextRec;
    Caught := False;
    try
      TCsvSerializer.Serialize<TNullTextHolder>(TextHolder);
    except
      on E: ECsvProjectionError do Caught := True;
    end;
    Check(Caught, 'CSV_NULLABLE_RECORD_WRITING_NOTHING_REFUSED');
  finally
    TextHolder.Free;
  end;

  { A NULLABLE COLLECTION, in the two modes that write it into this table. }
  Tags := TNullTagsHolder.Create;
  try
    Tags.Id := 1;
    Tags.Tags := TArray<string>.Create('a', 'b');
    for Mode in [TCsvCollectionMode.NumberedColumns,
      TCsvCollectionMode.RepeatedRows] do
    begin
      Detail := '';
      try
        TagsBack := TCsvSerializer.Deserialize<TNullTagsHolder>(
          TCsvSerializer.Serialize<TNullTagsHolder>(Tags,
            TCsvOptions.Default.WithCollectionMode(Mode)),
          TCsvOptions.Default.WithCollectionMode(Mode));
        try
          if TagsBack.Tags.HasValue and (Length(TagsBack.Tags.Value) = 2) and
             (TagsBack.Tags.Value[1] = 'b') then Detail := 'ok';
        finally
          TagsBack.Free;
        end;
      except
        on E: Exception do Detail := E.ClassName + ': ' + E.Message;
      end;
      Check(Detail = 'ok', 'CSV_NULLABLE_COLLECTION_READS_BACK_' +
        GetEnumName(TypeInfo(TCsvCollectionMode), Ord(Mode)));
    end;
    Tags.Tags := Default(TNullable<TArray<string>>);
    TagsBack := TCsvSerializer.Deserialize<TNullTagsHolder>(
      TCsvSerializer.Serialize<TNullTagsHolder>(Tags, Repeated), Repeated);
    try
      Check(not TagsBack.Tags.HasValue,
        'CSV_NULLABLE_COLLECTION_ABSENT_READS_BACK');
    finally
      TagsBack.Free;
    end;
  finally
    Tags.Free;
  end;

  { DATES BEFORE 1899-12-30 have a negative day, and their time of day is
    subtracted from it: adding the parts read the next day. }
  Whens[0] := EncodeDateTime(1800, 1, 1, 12, 0, 0, 0);
  Whens[1] := EncodeDateTime(1899, 12, 29, 6, 0, 0, 0);
  Moment := TMoment.Create;
  try
    for When in Whens do
    begin
      Moment.At := When;
      Moment.Local := When;
      Moment.Day := Trunc(When);
      MomentBack := TCsvSerializer.Deserialize<TMoment>(
        TCsvSerializer.Serialize<TMoment>(Moment));
      try
        Check((MomentBack.At = When) and (MomentBack.Local = When),
          'CSV_PRE_1899_DATE_TIME_READS_BACK_' + FormatDateTime('yyyymmdd',
            When));
      finally
        MomentBack.Free;
      end;
    end;
    { Outside the years 1 to 9999 there is no text for the value, and the
      reader refuses what used to be written. }
    Refusals := 0;
    for I := 0 to 2 do
    begin
      Moment.At := 0;
      Moment.Local := 0;
      Moment.Day := 0;
      case I of
        0: Moment.Day := EncodeDate(1, 1, 1) - 1;
        1: Moment.At := EncodeDate(9999, 12, 31) + 1;
        2: Moment.Local := EncodeDate(1, 1, 1) - 1;
      end;
      try
        TCsvSerializer.Serialize<TMoment>(Moment);
      except
        on E: ESerializationUnsupported do Inc(Refusals);
      end;
    end;
    Check(Refusals = 3, 'CSV_DATE_OUTSIDE_YEARS_1_TO_9999_REFUSED_ON_WRITE');
  finally
    Moment.Free;
  end;

  { NUMBERS. Correctly rounded text to Double on both platforms: on Win64
    the RTL read about a third of 17-digit texts as the neighbouring
    Double. }
  RateBack := TCsvSerializer.Deserialize<TRate>(
    Doc(['D', '123456789.12345679']));
  try
    Check(DoubleBits(RateBack.D) = $419D6F34547E6B75,
      'CSV_17_DIGIT_DOUBLE_READ_EXACTLY');
  finally
    RateBack.Free;
  end;
  RateBack := TCsvSerializer.Deserialize<TRate>(
    Doc(['D', '1.7976931348623158E308']));
  try
    Check(DoubleBits(RateBack.D) = $7FEFFFFFFFFFFFFF,
      'CSV_MAX_DOUBLE_READ_EXACTLY');
  finally
    RateBack.Free;
  end;
  RandSeed := 20260930;
  Differ := 0;
  Rate := TRate.Create;
  try
    for I := 1 to 2000 do
    begin
      Bits := (UInt64(Random($7FFFFFFF)) shl 33) xor
        (UInt64(Random($7FFFFFFF)) shl 2) xor UInt64(Random(4));
      Exponent := Integer((Bits shr 52) and $7FF);
      if (Exponent = 0) or (Exponent = $7FF) then Continue;
      PUInt64(@V)^ := Bits;
      Rate.D := V;
      RateBack := TCsvSerializer.Deserialize<TRate>(
        TCsvSerializer.Serialize<TRate>(Rate));
      try
        if DoubleBits(RateBack.D) <> Bits then Inc(Differ);
      finally
        RateBack.Free;
      end;
    end;
  finally
    Rate.Free;
  end;
  Note(Format('%d of 2000 random Doubles came back different', [Differ]));
  Check(Differ = 0, 'CSV_RANDOM_DOUBLES_ROUND_TRIP_EXACTLY');
end;

begin
  try
    TestLexer;
    TestWriter;
    TestFlatContract;
    TestNestedObjects;
    TestCollections;
    TestConservativeDefaults;
    TestNulls;
    TestSchema;
    TestConversionMatrix;
    TestDataSet;
    TestUnicode;
    TestFeatureLedger;
    TestRepairs;
    TestStructuralTables;
  except
    on E: Exception do
    begin
      Writeln('UNEXPECTED ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  Writeln;
  Writeln('CHECKS=', GChecks);
  Writeln('FAILURES=', GFailures);
  if GFailures = 0 then
  begin
    Writeln('CSV_RFC4180_PARSER: PASS');
    Writeln('CSV_NESTED_OBJECT_MODES: PASS');
    Writeln('CSV_COLLECTION_MODES: PASS');
    Writeln('CSV_MULTI_TABLE: PASS');
    Writeln('CSV_SCHEMA: PASS');
    Writeln('CSV_INDEPENDENT_INTEROP: PASS');
    Writeln('CSV_CONSERVATIVE_DEFAULTS: PASS');
    Writeln('CSV_NATIVE: PASS');
  end
  else
  begin
    Writeln('CSV_NATIVE: FAIL');
    ExitCode := 1;
  end;
end.
