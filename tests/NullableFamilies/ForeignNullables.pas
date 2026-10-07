unit ForeignNullables;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ Nullable types that the library has never heard of.

  They live in a unit rather than in the .dpr for the ordinary reason - a DTO
  unit is where an application would put them - not because registration
  requires it. Delphi emits no declaring unit for a closed generic record at
  all, so a family here is identified by its base name, its arity and the
  fields the registration named. }

interface

type
  { A foreign nullable that happens to use the same field names as
    PascalForge.Nullable.TNullable<T>. Same shape, different family: it is not
    recognized until it is registered. }
  TMaybe<T> = record
  private
    FValue: T;
    FHasValue: Boolean;
  public
    class function Some(const AValue: T): TMaybe<T>; static;
    class function None: TMaybe<T>; static;
    property HasValue: Boolean read FHasValue;
    property Value: T read FValue;
  end;

  { A foreign nullable that names its two fields differently, so it can only
    be registered with an explicit layout. }
  TOptional<T> = record
  private
    FPayload: T;
    FPresent: Boolean;
  public
    class function Some(const AValue: T): TOptional<T>; static;
    class function None: TOptional<T>; static;
    property IsPresent: Boolean read FPresent;
    property Payload: T read FPayload;
  end;

  { Not a nullable: it carries a value and no flag, so there is no way to say
    "empty". Registering it must be refused. }
  TBox<T> = record
  private
    FValue: T;
  public
    class function Wrap(const AValue: T): TBox<T>; static;
    property Value: T read FValue;
  end;

  { A value plus a flag that is not a one-byte Boolean. The flag is read
    through a PBoolean, so accepting this would read one byte of an Integer
    and call whatever it found "has value". Registering it must be refused. }
  TWideFlag<T> = record
  private
    FValue: T;
    FHasValue: Integer;
  public
    class function Make(const AValue: T): TWideFlag<T>; static;
  end;

  { Carries BOTH pairs of field names, so it genuinely resolves under two
    different layouts. Registering it twice, differently, is the collision
    the registry must refuse. }
  TDualNames<T> = record
  private
    FValue: T;
    FHasValue: Boolean;
    FPayload: T;
    FPresent: Boolean;
  public
    class function Make(const AValue: T): TDualNames<T>; static;
  end;

  { Not generic at all, so it has no family to register. }
  TFixedMaybe = record
  private
    FValue: Integer;
    FHasValue: Boolean;
  public
    class function Make(AValue: Integer): TFixedMaybe; static;
  end;

implementation

{ TMaybe<T> }

class function TMaybe<T>.Some(const AValue: T): TMaybe<T>;
begin
  Result.FValue := AValue;
  Result.FHasValue := True;
end;

class function TMaybe<T>.None: TMaybe<T>;
begin
  Result := Default(TMaybe<T>);
end;

{ TOptional<T> }

class function TOptional<T>.Some(const AValue: T): TOptional<T>;
begin
  Result.FPayload := AValue;
  Result.FPresent := True;
end;

class function TOptional<T>.None: TOptional<T>;
begin
  Result := Default(TOptional<T>);
end;

{ TBox<T> }

class function TBox<T>.Wrap(const AValue: T): TBox<T>;
begin
  Result.FValue := AValue;
end;

{ TWideFlag<T> }

class function TWideFlag<T>.Make(const AValue: T): TWideFlag<T>;
begin
  Result.FValue := AValue;
  Result.FHasValue := 1;
end;

{ TDualNames<T> }

class function TDualNames<T>.Make(const AValue: T): TDualNames<T>;
begin
  Result.FValue := AValue;
  Result.FHasValue := True;
  Result.FPayload := AValue;
  Result.FPresent := True;
end;

{ TFixedMaybe }

class function TFixedMaybe.Make(AValue: Integer): TFixedMaybe;
begin
  Result.FValue := AValue;
  Result.FHasValue := True;
end;

end.
