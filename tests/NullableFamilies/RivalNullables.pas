unit RivalNullables;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

{ A second library's nullable that happens to be called TMaybe<T> as well.

  Delphi emits no declaring unit for a closed generic record, so this family
  and ForeignNullables.TMaybe<T> are indistinguishable to RTTI: same base
  name, same arity, no unit on either. It names its fields differently, so the
  two cannot quietly share one registration - and the registry says so instead
  of picking one. }

interface

type
  TMaybe<T> = record
  private
    FItem: T;
    FLoaded: Boolean;
  public
    class function Some(const AValue: T): TMaybe<T>; static;
    property IsLoaded: Boolean read FLoaded;
    property Item: T read FItem;
  end;

implementation

class function TMaybe<T>.Some(const AValue: T): TMaybe<T>;
begin
  Result.FItem := AValue;
  Result.FLoaded := True;
end;

end.
