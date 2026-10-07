unit BsonCustomModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

interface

uses
  System.SysUtils,
  PascalForge.Bson;

type
  TCoordinate = record
    Latitude: Double;
    Longitude: Double;
  end;

  TCoordinateSerializer = class(TCustomBsonValueSerializer<TCoordinate>)
  public
    function SerializeValue(const AValue: TCoordinate): TBsonValue; override;
    function DeserializeValue(AValue: TBsonValue;
      const AExisting: TCoordinate): TCoordinate; override;
  end;

  TPlace = class
  public
    Name: string;
    Where: TCoordinate;
  end;

implementation

function TCoordinateSerializer.SerializeValue(
  const AValue: TCoordinate): TBsonValue;
begin
  Result := TBsonValue.NewArray;
  try
    Result.Add(TBsonValue.NewDouble(AValue.Latitude));
    Result.Add(TBsonValue.NewDouble(AValue.Longitude));
  except
    Result.Free;
    raise;
  end;
end;

function TCoordinateSerializer.DeserializeValue(AValue: TBsonValue;
  const AExisting: TCoordinate): TCoordinate;
begin
  if (AValue.Kind <> TBsonKind.Arr) or (AValue.Count <> 2) then
    raise EBsonInputError.Create(
      'A coordinate is a two-element array of [latitude, longitude].');
  Result.Latitude := AValue[0].AsDouble;
  Result.Longitude := AValue[1].AsDouble;
end;

end.
