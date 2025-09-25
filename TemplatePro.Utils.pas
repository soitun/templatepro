// ***************************************************************************
//
// Copyright (c) 2016-2025 Daniele Teti
//
// https://github.com/danieleteti/templatepro
//
// ***************************************************************************
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// ***************************************************************************

unit TemplatePro.Utils;

interface

uses
  System.Generics.Collections,
  System.Classes,
  System.SysUtils,
  System.TypInfo,
  System.RTTI,
  TemplatePro.Types;

type
  TTProConfiguration = class sealed
  private
    class var fOnContextConfiguration: TTProCompiledTemplateEvent;
  protected
    class procedure RegisterHandlers(const TemplateProCompiledTemplate: ITProCompiledTemplate);
  public
    class property OnContextConfiguration: TTProCompiledTemplateEvent read fOnContextConfiguration write fOnContextConfiguration;
  end;

  TTProRTTIUtils = class sealed
  public
    class function GetProperty(AObject: TObject; const APropertyName: string): TValue;
  end;

  TTProDuckTypedList = class(TInterfacedObject, ITProWrappedList)
  private
    FObjectAsDuck: TObject;
    FObjType: TRttiType;
    FAddMethod: TRttiMethod;
    FClearMethod: TRttiMethod;
    FCountProperty: TRttiProperty;
    FGetItemMethod: TRttiMethod;
    FGetCountMethod: TRttiMethod;
    FIsWrappedList: Boolean;
    function HookListMethods(const aObjType: TRttiType): Boolean;
    constructor Create(const aObjectAsDuck: TObject; const aType: TRttiType);
  public
    procedure Add(const AObject: TObject);
    procedure Clear;
    function Count: Integer;
    function GetItem(const AIndex: Integer): TObject;
    function IsWrappedList: Boolean; overload;
    function ItemIsObject(const AIndex: Integer; out aValue: TValue): Boolean;
    procedure GetItemAsTValue(const AIndex: Integer; out aValue: TValue);
    class function Wrap(const aObject: TObject): ITProWrappedList; static;
    class function CanBeWrappedAsList(const aObject: TObject): Boolean; static;
  end;

function HTMLEncode(s: string): string;
function HandleTemplateSectionStateMachine(const aTokenValue1: String; var aTemplateSectionType: TTProTemplateSectionType;
  out aErrorMessage: String): Boolean;
function GetTValueFromPath(const aObject: TObject; FullPropertyPath: String): TValue;
procedure FunctionError(const aFunctionName, aErrMessage: string);

implementation

uses
  System.Character,
  System.StrUtils,
  JsonDataObjects;

procedure Error(const aMessage: String);
begin
  raise ETProRenderException.Create(aMessage);
end;

procedure FunctionError(const aFunctionName, aErrMessage: string);
begin
  if aErrMessage = '' then
  begin
    Error(Format('Unknown function [%s]', [aFunctionName]));
  end
  else
  begin
    Error(Format('[%s] %s', [aFunctionName, aErrMessage]));
  end;
end;

function HTMLEncode(s: string): string;
var
  I: Integer;
  r: string;
  b: UInt32;
  C4: UCS4Char;
begin
  I := 1;
  while I <= Length(s) do
  begin
    r := '';
    if (Char.IsHighSurrogate(S, I-1)) and (Char.IsLowSurrogate(S, I)) then
    begin
      C4 := Char.ConvertToUtf32(S, I-1);
      r := IntToStr(C4);
      s := s.Substring(0, I-1) + '&#' + r + ';' + s.Substring(I+1);
      Inc(I,r.Length + 3);
      Continue;
    end
    else
    begin
      b := Ord(S[I]);
      if b > 255 then
      begin
        if b = 8364 then
          r := 'euro'
        else
          r := '#' + IntToStr(b);
      end
      else
      begin
{$REGION 'entities'}
      case b of
        Ord('>'):
          r := 'gt';
        Ord('<'):
          r := 'lt';
        34:
          r := '#' + IntToStr(b);
        39:
          r := '#' + IntToStr(b);
        43:
          r := 'quot';
        160:
          r := 'nbsp';
        161:
          r := 'iexcl';
        162:
          r := 'cent';
        163:
          r := 'pound';
        164:
          r := 'curren';
        165:
          r := 'yen';
        166:
          r := 'brvbar';
        167:
          r := 'sect';
        168:
          r := 'uml';
        169:
          r := 'copy';
        170:
          r := 'ordf';
        171:
          r := 'laquo';
        172:
          r := 'not';
        173:
          r := 'shy';
        174:
          r := 'reg';
        175:
          r := 'macr';
        176:
          r := 'deg';
        177:
          r := 'plusmn';
        178:
          r := 'sup2';
        179:
          r := 'sup3';
        180:
          r := 'acute';
        181:
          r := 'micro';
        182:
          r := 'para';
        183:
          r := 'middot';
        184:
          r := 'cedil';
        185:
          r := 'sup1';
        186:
          r := 'ordm';
        187:
          r := 'raquo';
        188:
          r := 'frac14';
        189:
          r := 'frac12';
        190:
          r := 'frac34';
        191:
          r := 'iquest';
        215:
          r := 'times';
        247:
          r := 'divide';
        Ord('&'):
          r := 'amp';
      else
        r := '';
      end;
{$ENDREGION}
      end;
      if r <> '' then
      begin
        s := s.Substring(0, I - 1) + '&' + r + ';' + s.Substring(I);
        Inc(I, r.Length + 2);
      end
      else
      begin
        Inc(I);
      end;
    end;
  end;
  Result := s;
end;

function HandleTemplateSectionStateMachine(const aTokenValue1: String; var aTemplateSectionType: TTProTemplateSectionType;
  out aErrorMessage: String): Boolean;
begin
  Result := True;
  if aTokenValue1 = STR_BEGIN_OF_LAYOUT then
  begin
    if aTemplateSectionType = stUnknown then
    begin
      aTemplateSectionType := stLayout;
    end
    else
    begin
      aErrorMessage := 'Unexpected ' + aTokenValue1;
      Result := False;
    end;
  end
  else if aTokenValue1 = STR_END_OF_LAYOUT then
  begin
    if aTemplateSectionType = stLayout then
      aTemplateSectionType := stPage
    else
    begin
      aErrorMessage := 'Unexpected ' + aTokenValue1;
      Result := False;
    end;
  end
  else
  begin
    aErrorMessage := 'Unknown ttInfo value: ' + aTokenValue1;
    Result := False;
  end;
end;

function GetTValueFromPath(const aObject: TObject; FullPropertyPath: String): TValue;
var
  lRTTIType: TRttiType;
  lRTTIProperty: TRttiProperty;
  lRTTIField: TRttiField;
  lObject: TValue;
  lPropertyName: String;
  lPath: TArray<String>;
  I: Integer;
  lRttiContext: TRttiContext;
  lIsAnArray: Boolean;
  lArrayIndex: Integer;
  lSquareBracketPos: Integer;
begin
  if FullPropertyPath.IsEmpty then
  begin
    Exit(TValue.Empty);
  end;

  lRttiContext := TRttiContext.Create;
  try
    lPath := FullPropertyPath.Split(['.']);
    lObject := aObject;
    for I := 0 to Length(lPath) - 1 do
    begin
      lPropertyName := lPath[I];

      lIsAnArray := lPropertyName.Contains('[');
      lArrayIndex := -1;
      if lIsAnArray then
      begin
        lSquareBracketPos := lPropertyName.IndexOf('[');
        lArrayIndex := lPropertyName.Substring(lSquareBracketPos + 1, lPropertyName.IndexOf(']') - lSquareBracketPos - 1).ToInteger;
        lPropertyName := lPropertyName.Substring(0, lSquareBracketPos);
      end;

      if lObject.IsObject then
      begin
        lRTTIType := lRttiContext.GetType(lObject.AsObject.ClassInfo);
        lRTTIProperty := lRTTIType.GetProperty(lPropertyName);
        if Assigned(lRTTIProperty) then
        begin
          if lRTTIProperty.IsReadable then
          begin
            lObject := lRTTIProperty.GetValue(lObject.AsObject);
            if lIsAnArray then
            begin
              if lObject.IsArray then
              begin
                lObject := lObject.GetArrayElement(lArrayIndex);
              end
              else
              begin
                Exit(TValue.Empty);
              end;
            end;
          end
          else
          begin
            Exit(TValue.Empty);
          end;
        end
        else
        begin
          lRTTIField := lRTTIType.GetField(lPropertyName);
          if Assigned(lRTTIField) then
          begin
            lObject := lRTTIField.GetValue(lObject.AsObject);
            if lIsAnArray then
            begin
              if lObject.IsArray then
              begin
                lObject := lObject.GetArrayElement(lArrayIndex);
              end
              else
              begin
                Exit(TValue.Empty);
              end;
            end;
          end
          else
          begin
            Exit(TValue.Empty);
          end;
        end;
      end
      else
      begin
        Exit(TValue.Empty);
      end;
    end;
    Result := lObject;
  finally
    lRttiContext.Free;
  end;
end;

{ TTProConfiguration }

class procedure TTProConfiguration.RegisterHandlers(const TemplateProCompiledTemplate: ITProCompiledTemplate);
begin
  if Assigned(fOnContextConfiguration) then
  begin
    fOnContextConfiguration(TemplateProCompiledTemplate);
  end;
end;

{ TTProRTTIUtils }

class function TTProRTTIUtils.GetProperty(AObject: TObject; const APropertyName: string): TValue;
var
  Ctx: TRttiContext;
  lType: TRttiType;
  lProperty: TRttiProperty;
begin
  Ctx := TRttiContext.Create;
  try
    lType := Ctx.GetType(AObject.ClassInfo);
    lProperty := lType.GetProperty(APropertyName);
    if Assigned(lProperty) and lProperty.IsReadable then
      Result := lProperty.GetValue(AObject)
    else
      Result := TValue.Empty;
  finally
    Ctx.Free;
  end;
end;

{ TTProDuckTypedList }

procedure TTProDuckTypedList.Add(const AObject: TObject);
begin
  if FIsWrappedList then
    FAddMethod.Invoke(FObjectAsDuck, [AObject]);
end;

class function TTProDuckTypedList.CanBeWrappedAsList(const aObject: TObject): Boolean;
var
  lRTTIType: TRttiType;
  lCTX: TRttiContext;
begin
  if not Assigned(aObject) then
    Exit(False);

  lCTX := TRttiContext.Create;
  try
    lRTTIType := lCTX.GetType(aObject.ClassInfo);
    Result := TTProDuckTypedList.Create(aObject, lRTTIType).HookListMethods(lRTTIType);
  finally
    lCTX.Free;
  end;
end;

procedure TTProDuckTypedList.Clear;
begin
  if FIsWrappedList then
    FClearMethod.Invoke(FObjectAsDuck, []);
end;

function TTProDuckTypedList.Count: Integer;
begin
  if FIsWrappedList then
  begin
    if Assigned(FCountProperty) then
      Result := FCountProperty.GetValue(FObjectAsDuck).AsInteger
    else if Assigned(FGetCountMethod) then
      Result := FGetCountMethod.Invoke(FObjectAsDuck, []).AsInteger
    else
      Result := -1;
  end
  else
    Result := -1;
end;

constructor TTProDuckTypedList.Create(const aObjectAsDuck: TObject; const aType: TRttiType);
begin
  inherited Create;
  FObjectAsDuck := aObjectAsDuck;
  FObjType := aType;
  FIsWrappedList := HookListMethods(aType);
end;

procedure TTProDuckTypedList.GetItemAsTValue(const AIndex: Integer; out aValue: TValue);
var
  lItem: TObject;
begin
  lItem := GetItem(AIndex);
  if Assigned(lItem) then
  begin
    aValue := lItem;
  end
  else
  begin
    aValue := TValue.Empty;
  end;
end;

function TTProDuckTypedList.GetItem(const AIndex: Integer): TObject;
begin
  if FIsWrappedList then
  begin
    Result := FGetItemMethod.Invoke(FObjectAsDuck, [AIndex]).AsObject;
  end
  else
    Result := nil;
end;

function TTProDuckTypedList.HookListMethods(const aObjType: TRttiType): Boolean;
begin
  Result := True;
  FAddMethod := aObjType.GetMethod('Add');
  if not Assigned(FAddMethod) then
    Result := False;

  FClearMethod := aObjType.GetMethod('Clear');
  if not Assigned(FClearMethod) then
    Result := False;

  FCountProperty := aObjType.GetProperty('Count');
  if not Assigned(FCountProperty) then
  begin
    FGetCountMethod := aObjType.GetMethod('Count');
    if not Assigned(FGetCountMethod) then
      Result := False;
  end;

  FGetItemMethod := aObjType.GetMethod('GetItem');
  if not Assigned(FGetItemMethod) then
  begin
    FGetItemMethod := aObjType.GetMethod('GetObject');
    if not Assigned(FGetItemMethod) then
    begin
      Result := False;
    end;
  end;
end;

function TTProDuckTypedList.IsWrappedList: Boolean;
begin
  Result := FIsWrappedList;
end;

function TTProDuckTypedList.ItemIsObject(const AIndex: Integer; out aValue: TValue): Boolean;
var
  lItem: TObject;
begin
  lItem := GetItem(AIndex);
  Result := Assigned(lItem);
  if Result then
  begin
    aValue := lItem;
  end
  else
  begin
    aValue := TValue.Empty;
  end;
end;

class function TTProDuckTypedList.Wrap(const aObject: TObject): ITProWrappedList;
var
  lRTTIType: TRttiType;
  lCTX: TRttiContext;
  lDuckTypedList: TTProDuckTypedList;
begin
  if not Assigned(aObject) then
    Exit(nil);

  lCTX := TRttiContext.Create;
  try
    lRTTIType := lCTX.GetType(aObject.ClassInfo);
    lDuckTypedList := TTProDuckTypedList.Create(aObject, lRTTIType);
    if lDuckTypedList.IsWrappedList then
      Result := lDuckTypedList
    else
    begin
      lDuckTypedList.Free;
      Result := nil;
    end;
  finally
    lCTX.Free;
  end;
end;

end.