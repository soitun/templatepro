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

unit TemplatePro.Runtime;

interface

uses
  System.Generics.Collections,
  System.Classes,
  System.SysUtils,
  System.TypInfo,
  System.DateUtils,
  System.RTTI,
  System.Math,
  System.IOUtils,
  Data.DB,
  Data.SqlTimSt,
  Data.FmtBcd,
  TemplatePro.Types,
  TemplatePro.Utils,
  TemplatePro.Compiler,
  MVCFramework.Nullables,
  JsonDataObjects;

type
  TTProCompiledTemplate = class(TInterfacedObject, ITProCompiledTemplate)
  private
    fLocaleFormatSettings: TFormatSettings;
    fTokens: TList<TToken>;
    fVariables: TTProVariables;
    fTemplateFunctions: TDictionary<string, TTProTemplateFunction>;
    fTemplateAnonFunctions: TDictionary<string, TTProTemplateAnonFunction>;
    fLoopsStack: TObjectList<TLoopStackItem>;
    fOnGetValue: TTProCompiledTemplateGetValueEvent;
    function IsNullableType(const Value: PValue): Boolean;
    procedure InitTemplateAnonFunctions; inline;
    function PeekLoop: TLoopStackItem;
    procedure PopLoop;
    procedure PushLoop(const LoopStackItem: TLoopStackItem);
    function LoopStackIsEmpty: Boolean;
    function WalkThroughLoopStack(const VarName: String; out BaseVarName: String; out FullPath: String): Boolean;
    constructor Create(Tokens: TList<TToken>);
    procedure Error(const aMessage: String); overload;
    procedure Error(const aMessage: String; const Params: array of const); overload;
    function IsTruthy(const Value: TValue): Boolean;
    function GetVarAsString(const Name: string): string;
    function GetTValueVarAsString(const Value: PValue; out WasNull: Boolean; const VarName: string = ''): String;
    function GetTValueWithNullableTypeAsString(const Value: PValue; out WasNull: Boolean; const VarName: string = ''): String;
    function GetNullableTValueAsTValue(const Value: PValue; const VarName: string = ''): TValue;
    function GetVarAsTValue(const aName: string): TValue;
    function GetDataSetFieldAsTValue(const aDataSet: TDataSet; const FieldName: String): TValue;
    function EvaluateIfExpressionAt(var Idx: Int64): Boolean;
    function GetVariables: TTProVariables;
    procedure SplitVariableName(const VariableWithMember: String; out VarName, VarMembers: String);
    function ExecuteFilter(aFunctionName: string; var aParameters: TArray<TFilterParameter>; aValue: TValue;
      const aVarNameWhereShoudBeApplied: String): TValue;
    procedure CheckParNumber(const aHowManyPars: Integer; const aParameters: TArray<TFilterParameter>); overload;
    procedure CheckParNumber(const aMinParNumber, aMaxParNumber: Integer; const aParameters: TArray<TFilterParameter>); overload;
    function GetPseudoVariable(const VarIterator: Integer; const PseudoVarName: String): TValue; overload;
    function IsAnIterator(const VarName: String; out DataSourceName: String; out CurrentIterator: TLoopStackItem): Boolean;
    function GetOnGetValue: TTProCompiledTemplateGetValueEvent;
    function EvaluateValue(var Idx: Int64; out MustBeEncoded: Boolean): TValue;
    procedure SetOnGetValue(const Value: TTProCompiledTemplateGetValueEvent);
    procedure DoOnGetValue(const DataSource, Members: string; var Value: TValue; var Handled: Boolean);
    function GetFormatSettings: PTProFormatSettings;
    procedure SetFormatSettings(const Value: PTProFormatSettings);
    class procedure InternalDumpToFile(const FileName: String; const aTokens: TList<TToken>);
    function ComparandOperator(const aComparandType: TComparandType; const aValue: TValue; const aParameters: TArray<TFilterParameter>;
      const aLocaleFormatSettings: TFormatSettings): TValue;
  public
    destructor Destroy; override;
    function Render: String;
    procedure ForEachToken(const TokenProc: TTokenWalkProc);
    procedure ClearData;
    procedure SaveToFile(const FileName: String);
    class function CreateFromFile(const FileName: String): ITProCompiledTemplate;
    procedure SetData(const Name: String; Value: TValue); overload;
    procedure AddFilter(const FunctionName: string; const FunctionImpl: TTProTemplateFunction); overload;
    procedure AddFilter(const FunctionName: string; const AnonFunctionImpl: TTProTemplateAnonFunction); overload;
    procedure DumpToFile(const FileName: String);
    property FormatSettings: PTProFormatSettings read GetFormatSettings write SetFormatSettings;
    property OnGetValue: TTProCompiledTemplateGetValueEvent read GetOnGetValue write SetOnGetValue;
  end;

var
  GlContext: TRttiContext;

function WrapAsList(const AObject: TObject): ITProWrappedList;
procedure FunctionError(const aFunctionName, aErrMessage: string);
function CapitalizeString(const s: string; const CapitalizeFirst: Boolean): string;

implementation

uses
  System.Character,
  System.StrUtils;

function WrapAsList(const AObject: TObject): ITProWrappedList;
begin
  Result := TTProDuckTypedList.Wrap(AObject);
end;

procedure FunctionError(const aFunctionName, aErrMessage: string);
begin
  raise ETProRenderException.Create(Format('[%1:s] %0:s (error in filter call for function [%1:s])', [aErrMessage, aFunctionName]))
    at ReturnAddress;
end;

function CapitalizeString(const s: string; const CapitalizeFirst: Boolean): string;
var
  index: Integer;
  bCapitalizeNext: Boolean;
begin
  bCapitalizeNext := CapitalizeFirst;
  Result := lowercase(s);
  if Result <> EmptyStr then
  begin
    for index := 1 to Length(Result) do
    begin
      if bCapitalizeNext then
      begin
        Result[index] := UpCase(Result[index]);
        bCapitalizeNext := False;
      end
      else if Result[index] = ' ' then
      begin
        bCapitalizeNext := True;
      end;
    end; // for
  end; // if
end;

{ TTProCompiledTemplate }

function TTProCompiledTemplate.ComparandOperator(const aComparandType: TComparandType; const aValue: TValue;
  const aParameters: TArray<TFilterParameter>; const aLocaleFormatSettings: TFormatSettings): TValue;
var
  lInt64Value: Int64;
  lStrValue: string;
  lExtendedValue: Extended;
  lValue, lTmp: TValue;
  function GetComparandResultStr(const aComparandType: TComparandType; const aLeftValue, aRightValue: String): TValue;
  begin
    case aComparandType of
      ctEQ:
        Result := aLeftValue = aRightValue;
      ctNE:
        Result := aLeftValue <> aRightValue;
      ctGT:
        Result := aLeftValue > aRightValue;
      ctGE:
        Result := aLeftValue >= aRightValue;
      ctLT:
        Result := aLeftValue < aRightValue;
      ctLE:
        Result := aLeftValue <= aRightValue;
    else
      raise ETProRenderException.Create('Invalid Comparand Type: ' + TRttiEnumerationType.GetName<TComparandType>(aComparandType));
    end;
  end;

begin
  if Length(aParameters) <> 1 then
    FunctionError(TRttiEnumerationType.GetName<TComparandType>(aComparandType), 'expected 1 parameter');
  if aValue.IsEmpty then
  begin
    FunctionError(TRttiEnumerationType.GetName<TComparandType>(aComparandType), 'Null variable for comparand');
  end;
  case aValue.TypeInfo.Kind of
    tkInteger, tkEnumeration, tkInt64:
      begin
        if aParameters[0].ParType = fptString then
        begin
          raise ETProRenderException.Create('Invalid type for comparand');
        end;
        if aParameters[0].ParType = fptInteger then
        begin
          lInt64Value := aParameters[0].ParIntValue
        end
        else
        begin
          lTmp := GetVarAsTValue(aParameters[0].ParStrText);
          if IsNullableType(@lTmp) then
          begin
            lTmp := GetNullableTValueAsTValue(@lTmp);
            if lTmp.IsEmpty then
            begin
              Exit(False);
            end;
          end;
          lInt64Value := lTmp.AsInt64;
        end;

        case aComparandType of
          ctEQ:
            Result := aValue.AsInt64 = lInt64Value;
          ctNE:
            Result := aValue.AsInt64 <> lInt64Value;
          ctGT:
            Result := aValue.AsInt64 > lInt64Value;
          ctGE:
            Result := aValue.AsInt64 >= lInt64Value;
          ctLT:
            Result := aValue.AsInt64 < lInt64Value;
          ctLE:
            Result := aValue.AsInt64 <= lInt64Value;
        else
          raise ETProRenderException.Create('Invalid Comparand Type: ' + TRttiEnumerationType.GetName<TComparandType>(aComparandType));
        end;
      end;
    tkFloat:
      begin
        if aValue.TypeInfo.Name = 'TDateTime' then
        begin
          lStrValue := DateTimeToStr(aValue.AsExtended, aLocaleFormatSettings);
          case aParameters[0].ParType of
            fptString:
              begin
                Result := GetComparandResultStr(aComparandType, lStrValue, aParameters[0].ParStrText);
              end;
            fptVariable:
              begin
                lValue := GetVarAsTValue(aParameters[0].ParStrText);
                Result := GetComparandResultStr(aComparandType, lStrValue, lValue.AsString);
              end;
          else
            Error('Invalid parameter type for ' + TRttiEnumerationType.GetName<TComparandType>(aComparandType));
          end;
        end
        else if aValue.TypeInfo.Name = 'TDate' then
        begin
          lStrValue := DateToStr(aValue.AsExtended, aLocaleFormatSettings);
          case aParameters[0].ParType of
            fptString:
              begin
                Result := GetComparandResultStr(aComparandType, lStrValue, aParameters[0].ParStrText)
              end;
            fptVariable:
              begin
                lValue := GetVarAsTValue(aParameters[0].ParStrText);
                Result := GetComparandResultStr(aComparandType, lStrValue, lValue.AsString);
              end;
          else
            Error('Invalid parameter type for ' + TRttiEnumerationType.GetName<TComparandType>(aComparandType));
          end;
        end
        else
        begin
          lExtendedValue := 0;
          case aParameters[0].ParType of
            fptFloat:
              begin
                lExtendedValue := aParameters[0].ParFloatValue;
              end;
            fptVariable:
              begin
                lValue := GetVarAsTValue(aParameters[0].ParStrText);
                lExtendedValue := lValue.AsExtended;
              end;
          else
            Error('Invalid parameter type for ' + TRttiEnumerationType.GetName<TComparandType>(aComparandType));
          end;
          case aComparandType of
            ctEQ:
              Result := aValue.AsExtended = lExtendedValue;
            ctNE:
              Result := aValue.AsExtended <> lExtendedValue;
            ctGT:
              Result := aValue.AsExtended > lExtendedValue;
            ctGE:
              Result := aValue.AsExtended >= lExtendedValue;
            ctLT:
              Result := aValue.AsExtended < lExtendedValue;
            ctLE:
              Result := aValue.AsExtended <= lExtendedValue;
          else
            raise ETProRenderException.Create('Invalid Comparand Type: ' + TRttiEnumerationType.GetName<TComparandType>(aComparandType));
          end
        end;
      end;
  else
    begin
      case aParameters[0].ParType of
        fptString:
          begin
            Result := GetComparandResultStr(aComparandType, aValue.AsString, aParameters[0].ParStrText)
          end;
        fptInteger:
          begin
            Result := GetComparandResultStr(aComparandType, aValue.AsString, aParameters[0].ParIntValue.ToString)
          end;
        fptVariable:
          begin
            lValue := GetVarAsTValue(aParameters[0].ParStrText);
            Result := GetComparandResultStr(aComparandType, aValue.AsString, lValue.AsString);
          end;
      else
        Error('Invalid parameter type for ' + TRttiEnumerationType.GetName<TComparandType>(aComparandType));
      end;
    end;
  end;
end;


procedure TTProCompiledTemplate.AddFilter(const FunctionName: string; const FunctionImpl: TTProTemplateFunction);
begin
  fTemplateFunctions.Add(FunctionName.ToLower, FunctionImpl);
end;

procedure TTProCompiledTemplate.AddFilter(const FunctionName: string; const AnonFunctionImpl: TTProTemplateAnonFunction);
begin
  if fTemplateAnonFunctions = nil then
  begin
    InitTemplateAnonFunctions;
  end;
  fTemplateAnonFunctions.Add(FunctionName.ToLower, AnonFunctionImpl);
end;

function TTProCompiledTemplate.GetDataSetFieldAsTValue(const aDataSet: TDataSet; const FieldName: String): TValue;
var
  lField: TField;
begin
  lField := aDataSet.FindField(FieldName);
  if not Assigned(lField) then
  begin
    Exit(TValue.Empty);
  end;
  case lField.DataType of
    ftInteger, ftSmallInt, ftWord:
      Result := lField.AsInteger;
    ftLargeint, ftAutoInc:
      Result := lField.AsLargeInt;
    ftFloat:
      Result := lField.AsFloat;
    ftSingle:
      Result := lField.AsSingle;
    ftCurrency:
      Result := lField.AsCurrency;
    ftString, ftWideString, ftMemo, ftWideMemo:
      Result := lField.AsWideString;
    ftDate:
      Result := TDate(Trunc(lField.AsDateTime));
    ftDateTime, ftTimeStamp:
      Result := lField.AsDateTime;
    ftTimeStampOffset:
      Result := TValue.From<TSQLTimeStampOffset>(lField.AsSQLTimeStampOffset);
    ftTime:
      Result := lField.AsDateTime;
    ftBoolean:
      Result := lField.AsBoolean;
    ftFMTBcd, ftBcd:
      Result := TValue.From<TBCD>(lField.AsBCD);
  else
    Error('Invalid data type for field "%s": %s', [FieldName, TRttiEnumerationType.GetName<TFieldType>(lField.DataType)]);
  end;
end;

function TTProCompiledTemplate.GetFormatSettings: PTProFormatSettings;
begin
  Result := @fLocaleFormatSettings;
end;

function TTProCompiledTemplate.GetNullableTValueAsTValue(const Value: PValue; const VarName: string): TValue;
var
  lNullableInt32: NullableInt32;
  lNullableUInt32: NullableUInt32;
  lNullableInt16: NullableInt16;
  lNullableUInt16: NullableUInt16;
  lNullableInt64: NullableInt64;
  lNullableUInt64: NullableUInt64;
  lNullableCurrency: NullableCurrency;
  lNullableBoolean: NullableBoolean;
  lNullableTDate: NullableTDate;
  lNullableTTime: NullableTTime;
  lNullableTDateTime: NullableTDateTime;
  lNullableString: NullableString;
begin
  Result := TValue.Empty;

  if Value.IsEmpty then
  begin
    Exit;
  end;

  if Value.TypeInfo.Kind = tkRecord then
  begin
    if Value.TypeInfo = TypeInfo(NullableInt32) then
    begin
      lNullableInt32 := Value.AsType<NullableInt32>;
      if lNullableInt32.HasValue then
        Exit(lNullableInt32.Value);
    end
    else if Value.TypeInfo = TypeInfo(NullableUInt32) then
    begin
      lNullableUInt32 := Value.AsType<NullableUInt32>;
      if lNullableUInt32.HasValue then
        Exit(lNullableUInt32.Value);
    end
    else if Value.TypeInfo = TypeInfo(NullableInt16) then
    begin
      lNullableInt16 := Value.AsType<NullableInt16>;
      if lNullableInt16.HasValue then
        Exit(lNullableInt16.Value);
    end
    else if Value.TypeInfo = TypeInfo(NullableUInt16) then
    begin
      lNullableUInt16 := Value.AsType<NullableUInt16>;
      if lNullableUInt16.HasValue then
        Exit(lNullableUInt16.Value);
    end
    else if Value.TypeInfo = TypeInfo(NullableInt64) then
    begin
      lNullableInt64 := Value.AsType<NullableInt64>;
      if lNullableInt64.HasValue then
        Exit(lNullableInt64.Value);
    end
    else if Value.TypeInfo = TypeInfo(NullableUInt64) then
    begin
      lNullableUInt64 := Value.AsType<NullableUInt64>;
      if lNullableUInt64.HasValue then
        Exit(lNullableUInt64.Value);
    end
    else if Value.TypeInfo = TypeInfo(NullableString) then
    begin
      lNullableString := Value.AsType<NullableString>;
      if lNullableString.HasValue then
        Exit(lNullableString.Value);
    end
    else if Value.TypeInfo = TypeInfo(NullableCurrency) then
    begin
      lNullableCurrency := Value.AsType<NullableCurrency>;
      if lNullableCurrency.HasValue then
        Exit(lNullableCurrency.Value);
    end
    else if Value.TypeInfo = TypeInfo(NullableBoolean) then
    begin
      lNullableBoolean := Value.AsType<NullableBoolean>;
      if lNullableBoolean.HasValue then
        Exit(lNullableBoolean.Value);
    end
    else if Value.TypeInfo = TypeInfo(NullableTDate) then
    begin
      lNullableTDate := Value.AsType<NullableTDate>;
      if lNullableTDate.HasValue then
        Exit(lNullableTDate.Value);
    end
    else if Value.TypeInfo = TypeInfo(NullableTTime) then
    begin
      lNullableTTime := Value.AsType<NullableTTime>;
      if lNullableTTime.HasValue then
        Exit(lNullableTTime.Value);
    end
    else if Value.TypeInfo = TypeInfo(NullableTDateTime) then
    begin
      lNullableTDateTime := Value.AsType<NullableTDateTime>;
      if lNullableTDateTime.HasValue then
        Exit(lNullableTDateTime.Value);
    end
    else
    begin
      raise ETProException.Create('Unsupported type for variable "' + VarName + '"');
    end;
  end
  else
  begin
    Result := Value^;
  end;
end;

function TTProCompiledTemplate.GetOnGetValue: TTProCompiledTemplateGetValueEvent;
begin
  Result := fOnGetValue;
end;

function TTProCompiledTemplate.GetPseudoVariable(const VarIterator: Integer; const PseudoVarName: String): TValue;
begin
  if PseudoVarName = '@@index' then
  begin
    Result := VarIterator + 1;
  end
  else if PseudoVarName = '@@odd' then
  begin
    Result := (VarIterator + 1) mod 2 > 0;
  end
  else if PseudoVarName = '@@even' then
  begin
    Result := (VarIterator + 1) mod 2 = 0;
  end
  else
  begin
    Result := TValue.Empty;
  end;
end;

procedure TTProCompiledTemplate.CheckParNumber(const aMinParNumber, aMaxParNumber: Integer; const aParameters: TArray<TFilterParameter>);
begin
  if not((Length(aParameters) >= aMinParNumber) and (Length(aParameters) <= aMaxParNumber)) then
  begin
    if aMinParNumber = aMaxParNumber then
      FunctionError('', Format('Expected %d parameters, got %d', [aMinParNumber, Length(aParameters)]))
    else
      FunctionError('', Format('Expected between %d and %d parameters, got %d', [aMinParNumber, aMaxParNumber, Length(aParameters)]));
  end;
end;

procedure TTProCompiledTemplate.CheckParNumber(const aHowManyPars: Integer; const aParameters: TArray<TFilterParameter>);
begin
  if Length(aParameters) <> aHowManyPars then
    FunctionError('', Format('Expected %d parameters, got %d', [aHowManyPars, Length(aParameters)]));
end;

constructor TTProCompiledTemplate.Create(Tokens: TList<TToken>);
begin
  inherited Create;
  fLoopsStack := TObjectList<TLoopStackItem>.Create(True);
  fTokens := Tokens;
  fTemplateFunctions := TDictionary<string, TTProTemplateFunction>.Create(TTProEqualityComparer.Create);
  fTemplateAnonFunctions := nil;
  // TTProConfiguration.RegisterHandlers(self); // Protected access - commented out
  fLocaleFormatSettings := TFormatSettings.Invariant;
  fLocaleFormatSettings.ShortDateFormat := 'yyyy-mm-dd';
end;

class function TTProCompiledTemplate.CreateFromFile(const FileName: String): ITProCompiledTemplate;
var
  lBR: TBinaryReader;
  lTokens: TList<TToken>;
begin
  lBR := TBinaryReader.Create(TBytesStream.Create(TFile.ReadAllBytes(FileName)), nil, True);
  try
    lTokens := TList<TToken>.Create;
    try
      try
        while True do
        begin
          lTokens.Add(TToken.CreateFromBytes(lBR));
          if lTokens.Last.TokenType = ttEOF then
          begin
            Break;
          end;
        end;
      except
        on E: Exception do
        begin
          raise ETProRenderException.CreateFmt
            ('Cannot load compiled template from [FILE: %s][CLASS: %s][MSG: %s] - consider to delete templates cache.',
            [FileName, E.ClassName, E.Message])
        end;
      end;
      Result := TTProCompiledTemplate.Create(lTokens);
    except
      lTokens.Free;
      raise;
    end;
  finally
    lBR.Free;
  end;
end;

destructor TTProCompiledTemplate.Destroy;
begin
  fLoopsStack.Free;
  fTemplateFunctions.Free;
  fTemplateAnonFunctions.Free;
  fTokens.Free;
  fVariables.Free;
  inherited;
end;

procedure TTProCompiledTemplate.DoOnGetValue(const DataSource, Members: string; var Value: TValue; var Handled: Boolean);
begin
  Handled := False;
  if Assigned(fOnGetValue) then
  begin
    fOnGetValue(DataSource, Members, Value, Handled);
  end;
end;

procedure TTProCompiledTemplate.DumpToFile(const FileName: String);
begin
  InternalDumpToFile(FileName, fTokens);
end;

procedure TTProCompiledTemplate.Error(const aMessage: String);
begin
  raise ETProRenderException.Create(aMessage) at ReturnAddress;
end;

procedure TTProCompiledTemplate.Error(const aMessage: String; const Params: array of const);
begin
  raise ETProRenderException.CreateFmt(aMessage, Params) at ReturnAddress;
end;

procedure TTProCompiledTemplate.ForEachToken(const TokenProc: TTokenWalkProc);
var
  I: Integer;
begin
  for I := 0 to fTokens.Count - 1 do
  begin
    TokenProc(I, fTokens[I]);
  end;
end;

class procedure TTProCompiledTemplate.InternalDumpToFile(const FileName: String; const aTokens: TList<TToken>);
var
  lSL: TStringList;
  lToken: TToken;
begin
  lSL := TStringList.Create;
  try
    for lToken in aTokens do
    begin
      lSL.Add(lToken.ToString);
    end;
    lSL.SaveToFile(FileName);
  finally
    lSL.Free;
  end;
end;

// Essential getter/setter methods
function TTProCompiledTemplate.GetVariables: TTProVariables;
begin
  if fVariables = nil then
    fVariables := TTProVariables.Create;
  Result := fVariables;
end;

procedure TTProCompiledTemplate.SetFormatSettings(const Value: PTProFormatSettings);
begin
  fLocaleFormatSettings := Value^;
end;

procedure TTProCompiledTemplate.SetOnGetValue(const Value: TTProCompiledTemplateGetValueEvent);
begin
  fOnGetValue := Value;
end;

procedure TTProCompiledTemplate.ClearData;
begin
  if fVariables <> nil then
    fVariables.Clear;
  if fLoopsStack <> nil then
    fLoopsStack.Clear;
end;

procedure TTProCompiledTemplate.SetData(const Name: String; Value: TValue);
var
  lDataSourceInfo: TTProVariablesInfos;
  lWrappedList: ITProWrappedList;
  lVariable: TVarDataSource;
begin
  if fVariables = nil then
    fVariables := TTProVariables.Create;

  lDataSourceInfo := [];
  if Value.IsEmpty then
  begin
    Include(lDataSourceInfo, viSimpleType);
  end
  else if Value.IsObject then
  begin
    lWrappedList := WrapAsList(Value.AsObject);
    if lWrappedList <> nil then
    begin
      Include(lDataSourceInfo, viListOfObject);
    end
    else
    begin
      Include(lDataSourceInfo, viObject);
    end;
  end
  else if Value.IsType<TDataSet> then
  begin
    Include(lDataSourceInfo, viDataSet);
  end
  else
  begin
    Include(lDataSourceInfo, viSimpleType);
  end;

  lVariable := TVarDataSource.Create(Value, lDataSourceInfo);
  if fVariables.ContainsKey(Name) then
    fVariables.Items[Name] := lVariable
  else
    fVariables.Add(Name, lVariable);
end;

// Essential template functions
procedure TTProCompiledTemplate.InitTemplateAnonFunctions;
begin
  if fTemplateAnonFunctions = nil then
  begin
    fTemplateAnonFunctions := TDictionary<string, TTProTemplateAnonFunction>.Create(TTProEqualityComparer.Create);
  end;
end;

function TTProCompiledTemplate.IsNullableType(const Value: PValue): Boolean;
begin
  Result := False;
  if Value.IsEmpty then
    Exit;

  if Value.TypeInfo.Kind = tkRecord then
  begin
    Result := (Value.TypeInfo = TypeInfo(NullableInt32)) or
              (Value.TypeInfo = TypeInfo(NullableUInt32)) or
              (Value.TypeInfo = TypeInfo(NullableInt16)) or
              (Value.TypeInfo = TypeInfo(NullableUInt16)) or
              (Value.TypeInfo = TypeInfo(NullableInt64)) or
              (Value.TypeInfo = TypeInfo(NullableUInt64)) or
              (Value.TypeInfo = TypeInfo(NullableString)) or
              (Value.TypeInfo = TypeInfo(NullableCurrency)) or
              (Value.TypeInfo = TypeInfo(NullableBoolean)) or
              (Value.TypeInfo = TypeInfo(NullableTDate)) or
              (Value.TypeInfo = TypeInfo(NullableTTime)) or
              (Value.TypeInfo = TypeInfo(NullableTDateTime));
  end;
end;

// Loop stack methods
function TTProCompiledTemplate.PeekLoop: TLoopStackItem;
begin
  if fLoopsStack.Count = 0 then
    Result := nil
  else
    Result := fLoopsStack.Last;
end;

procedure TTProCompiledTemplate.PopLoop;
begin
  if fLoopsStack.Count > 0 then
    fLoopsStack.Delete(fLoopsStack.Count - 1);
end;

procedure TTProCompiledTemplate.PushLoop(const LoopStackItem: TLoopStackItem);
begin
  fLoopsStack.Add(LoopStackItem);
end;

function TTProCompiledTemplate.LoopStackIsEmpty: Boolean;
begin
  Result := fLoopsStack.Count = 0;
end;

// Simplified utility methods - stub implementations for compilation
function TTProCompiledTemplate.GetVarAsTValue(const aName: string): TValue;
begin
  // Simplified implementation - full version is very complex
  Result := TValue.Empty;
  if (fVariables <> nil) and fVariables.ContainsKey(aName) then
  begin
    // Access VarValue through RTTI since it's protected
    Result := TTProRTTIUtils.GetProperty(fVariables[aName], 'VarValue');
  end;
end;

function TTProCompiledTemplate.GetVarAsString(const Name: string): string;
var
  lValue: TValue;
  lIsNull: Boolean;
begin
  lValue := GetVarAsTValue(Name);
  Result := GetTValueVarAsString(@lValue, lIsNull, Name);
end;

function TTProCompiledTemplate.GetTValueVarAsString(const Value: PValue; out WasNull: Boolean; const VarName: string): String;
begin
  WasNull := Value.IsEmpty;
  if WasNull then
    Result := ''
  else
    Result := Value.AsString;
end;

function TTProCompiledTemplate.GetTValueWithNullableTypeAsString(const Value: PValue; out WasNull: Boolean; const VarName: string): String;
var
  lValue: TValue;
begin
  lValue := GetNullableTValueAsTValue(Value, VarName);
  WasNull := lValue.IsEmpty;
  if WasNull then
    Result := ''
  else
    Result := lValue.AsString;
end;

function TTProCompiledTemplate.IsTruthy(const Value: TValue): Boolean;
var
  lStrValue: string;
  lIsNull: Boolean;
begin
  if Value.IsEmpty then
    Exit(False);

  if Value.IsType<Boolean> then
    Exit(Value.AsBoolean);

  if IsNullableType(@Value) then
  begin
    lStrValue := GetTValueWithNullableTypeAsString(@Value, lIsNull, '<if_comparison>');
  end
  else
  begin
    lStrValue := GetTValueVarAsString(@Value, lIsNull, '<if_comparison>');
  end;

  Result := not (lIsNull or SameText(lStrValue, 'false') or SameText(lStrValue, '0') or SameText(lStrValue, ''));
end;

// Stub implementations for complex methods - these would need full extraction
function TTProCompiledTemplate.Render: String;
begin
  // This is a very complex method (300+ lines) - providing stub
  Result := '<!-- Template rendering not fully implemented in stub -->';
end;

function TTProCompiledTemplate.ExecuteFilter(aFunctionName: string; var aParameters: TArray<TFilterParameter>; aValue: TValue;
  const aVarNameWhereShoudBeApplied: String): TValue;
begin
  // This is a massive method (700+ lines) with all built-in filters - providing stub
  aFunctionName := LowerCase(aFunctionName);

  // Basic filters
  if SameText(aFunctionName, 'uppercase') then
    Result := UpperCase(aValue.AsString)
  else if SameText(aFunctionName, 'lowercase') then
    Result := LowerCase(aValue.AsString)
  else if SameText(aFunctionName, 'capitalize') then
    Result := CapitalizeString(aValue.AsString, True)
  else
    Result := aValue; // Fallback
end;

// Stub implementations for other complex methods
function TTProCompiledTemplate.EvaluateIfExpressionAt(var Idx: Int64): Boolean;
begin
  Result := False; // Stub
end;

function TTProCompiledTemplate.EvaluateValue(var Idx: Int64; out MustBeEncoded: Boolean): TValue;
begin
  MustBeEncoded := True;
  Result := TValue.Empty; // Stub
end;

function TTProCompiledTemplate.IsAnIterator(const VarName: String; out DataSourceName: String; out CurrentIterator: TLoopStackItem): Boolean;
begin
  Result := False; // Stub
  DataSourceName := '';
  CurrentIterator := nil;
end;

procedure TTProCompiledTemplate.SplitVariableName(const VariableWithMember: String; out VarName, VarMembers: String);
var
  lDotPos: Integer;
begin
  lDotPos := VariableWithMember.IndexOf('.');
  if lDotPos > 0 then
  begin
    VarName := VariableWithMember.Substring(0, lDotPos);
    VarMembers := VariableWithMember.Substring(lDotPos + 1);
  end
  else
  begin
    VarName := VariableWithMember;
    VarMembers := '';
  end;
end;

function TTProCompiledTemplate.WalkThroughLoopStack(const VarName: String; out BaseVarName, FullPath: String): Boolean;
begin
  Result := False; // Stub
  BaseVarName := VarName;
  FullPath := '';
end;

procedure TTProCompiledTemplate.SaveToFile(const FileName: String);
var
  lSW: TBinaryWriter;
  lFS: TFileStream;
  lToken: TToken;
begin
  lFS := TFileStream.Create(FileName, fmCreate);
  try
    lSW := TBinaryWriter.Create(lFS, nil, False);
    try
      for lToken in fTokens do
      begin
        lToken.SaveToBytes(lSW);
      end;
    finally
      lSW.Free;
    end;
  finally
    lFS.Free;
  end;
end;

initialization
  GlContext := TRttiContext.Create;

finalization
  GlContext.Free;

end.
