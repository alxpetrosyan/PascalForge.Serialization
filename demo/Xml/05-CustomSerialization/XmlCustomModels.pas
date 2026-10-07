unit XmlCustomModels;

{ Copyright (c) 2026 PascalForge
  SPDX-License-Identifier: MIT }

interface

uses
  System.SysUtils,
  PascalForge.Xml;

type
  TCoordinate = record
    Latitude: Double;
    Longitude: Double;
  end;

  { The typed base names the Delphi type, so an implementation never touches
    TValue or PTypeInfo. }
  TCoordinateSerializer = class(TCustomXmlValueSerializer<TCoordinate>)
  public
    procedure SerializeValue(const AValue: TCoordinate;
      AElement: TXmlElement); override;
    function DeserializeValue(AElement: TXmlElement;
      const AExisting: TCoordinate): TCoordinate; override;
  end;

  TPlace = class
  public
    Name: string;
    Where: TCoordinate;
  end;

implementation

procedure TCoordinateSerializer.SerializeValue(const AValue: TCoordinate;
  AElement: TXmlElement);
begin
  { Two numbers, and XML's natural shape for that is two attributes. }
  AElement.SetAttribute('lat',
    FloatToStr(AValue.Latitude, TFormatSettings.Invariant));
  AElement.SetAttribute('lon',
    FloatToStr(AValue.Longitude, TFormatSettings.Invariant));
end;

function TCoordinateSerializer.DeserializeValue(AElement: TXmlElement;
  const AExisting: TCoordinate): TCoordinate;
begin
  Result.Latitude := StrToFloat(AElement.AttributeValue('lat', '0'),
    TFormatSettings.Invariant);
  Result.Longitude := StrToFloat(AElement.AttributeValue('lon', '0'),
    TFormatSettings.Invariant);
end;

end.
