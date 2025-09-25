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

unit TemplatePro.Types;

interface

uses
  System.Generics.Collections,
  System.Generics.Defaults,
  System.Classes,
  System.SysUtils,
  System.TypInfo,
  System.DateUtils,
  System.RTTI,
  System.Hash,
  Data.DB;

const
  TEMPLATEPRO_VERSION = '0.7.3';

type
  ETProException = class(Exception)

  end;

  ETProCompilerException = class(ETProException)

  end;

  ETProRenderException = class(ETProException)

  end;

  ETProDuckTypingException = class(ETProException)

  end;

  TIfThenElseIndex = record
    IfIndex, ElseIndex: Int64;
  end;

  TTokenType = (ttContent, ttInclude, ttFor, ttEndFor, ttIfThen, ttBoolExpression, ttElse, ttEndIf, ttStartTag, ttComment, ttJump, ttBlock,
    ttEndBlock, ttContinue, ttLiteralString, ttEndTag, ttValue, ttFilterName, ttFilterParameter, ttLineBreak, ttSystemVersion, ttExit,
    ttEOF, ttInfo);

const
  TOKEN_TYPE_DESCR: array [Low(TTokenType) .. High(TTokenType)] of string = ('ttContent', 'ttInclude', 'ttFor', 'ttEndFor', 'ttIfThen',
    'ttBoolExpression', 'ttElse', 'ttEndIf', 'ttStartTag', 'ttComment', 'ttJump', 'ttBlock', 'ttEndBlock', 'ttContinue', 'ttLiteralString',
    'ttEndTag', 'ttValue', 'ttFilterName', 'ttFilterParameter', 'ttLineBreak', 'ttSystemVersion', 'ttExit', 'ttEOF', 'ttInfo');

const
  { ttInfo value1 can be: }
  STR_BEGIN_OF_LAYOUT = 'begin_of_layout';
  STR_END_OF_LAYOUT = 'end_of_layout';

type
{$IF not defined(RIOORBETTER)}
  PValue = ^TValue;
{$ENDIF}

  TFilterParameterType = (fptInteger, fptFloat, fptString, fptVariable);
  TFilterParameterTypes = set of TFilterParameterType;

  TFilterParameter = record
    { can be number, string or variable }
    ParType: TFilterParameterType;
    { contains the literal string if partype = string,
      contains the variable name if partype = variable }
    ParStrText: String;
    { contains the literal integer if partype = integer }
    ParIntValue: Integer;
    { contains the literal float if partype = float }
    ParFloatValue: Extended;
  end;

  PFilterParameter = ^TFilterParameter;

  TToken = packed record
    TokenType: TTokenType;
    Value1: String;
    Value2: String;
    Ref1: Int64;
    Ref2: Int64; { in case of tokentype = filter, contains the integer value, if any }
    class function Create(TokType: TTokenType; Value1: String; Value2: String; Ref1: Int64 = -1; Ref2: Int64 = -1): TToken; static;
    function TokenTypeAsString: String;
    function ToString: String;
    procedure SaveToBytes(const aBytes: TBinaryWriter);
    class function CreateFromBytes(const aBytes: TBinaryReader): TToken; static;
  end;

  TBlockAddress = record
    BeginBlockAddress, EndBlockAddress: Int64;
    class function Create(BeginBlockAddress, EndBlockAddress: Int64): TBlockAddress; static;
  end;

  TTokenWalkProc = reference to procedure(const Index: Integer; const Token: TToken);

  TComparandType = (ctEQ, ctNE, ctGT, ctGE, ctLT, ctLE);

  TTProTemplateFunction = function(const aValue: TValue; const aParameters: TArray<TFilterParameter>): TValue;
  TTProTemplateAnonFunction = reference to function(const aValue: TValue; const aParameters: TArray<TFilterParameter>): TValue;
  TTProVariablesInfo = (viSimpleType, viObject, viDataSet, viListOfObject, viJSONObject, viIterable);
  TTProVariablesInfos = set of TTProVariablesInfo;

  TVarDataSource = class
  protected
    VarValue: TValue;
    VarOption: TTProVariablesInfos;
  public
    constructor Create(const VarValue: TValue; const VarOption: TTProVariablesInfos);
  end;

  TTProEqualityComparer = class(TEqualityComparer<string>)
  public
    function Equals(const Left, Right: String): Boolean; override;
    function GetHashCode(const Value: String): Integer; override;
  end;

  TTProVariables = class(TObjectDictionary<string, TVarDataSource>)
  public
    constructor Create;
  end;

  TTProCompiledTemplateGetValueEvent = reference to procedure(const DataSource, Members: string; var Value: TValue; var Handled: Boolean);

  PTProFormatSettings = ^TFormatSettings;

  ITProCompiledTemplate = interface
    ['{0BE04DE7-6930-456B-86EE-BFD407BA6C46}']
    function Render: String;
    procedure ForEachToken(const TokenProc: TTokenWalkProc);
    procedure ClearData;
    procedure SetData(const Name: String; Value: TValue); overload;
    procedure AddFilter(const FunctionName: string; const FunctionImpl: TTProTemplateFunction); overload;
    procedure AddFilter(const FunctionName: string; const AnonFunctionImpl: TTProTemplateAnonFunction); overload;
    procedure DumpToFile(const FileName: String);
    procedure SaveToFile(const FileName: String);
    function GetOnGetValue: TTProCompiledTemplateGetValueEvent;
    procedure SetOnGetValue(const Value: TTProCompiledTemplateGetValueEvent);
    property OnGetValue: TTProCompiledTemplateGetValueEvent read GetOnGetValue write SetOnGetValue;
    function GetFormatSettings: PTProFormatSettings;
    procedure SetFormatSettings(const Value: PTProFormatSettings);
    property FormatSettings: PTProFormatSettings read GetFormatSettings write SetFormatSettings;
  end;

  TTProCompiledTemplateEvent = reference to procedure(const TemplateProCompiledTemplate: ITProCompiledTemplate);

  TLoopStackItem = class
  protected
    DataSourceName: String;
    LoopExpression: String;
    FullPath: String;
    IteratorPosition: Integer;
    IteratorName: String;
    EOF: Boolean;
    function IncrementIteratorPosition: Integer;
    constructor Create(DataSourceName: String; LoopExpression: String; FullPath: String; IteratorName: String);
  end;

  TTProTemplateSectionType = (stUnknown, stLayout, stPage);
  TTProCompilerOption = (coIgnoreSysVersion, coParentTemplate);
  TTProCompilerOptions = set of TTProCompilerOption;

  ITProWrappedList = interface
    ['{C1963FBF-1E42-4E2A-A17A-27F3945F13ED}']
    function GetItem(const AIndex: Integer): TObject;
    procedure Add(const AObject: TObject);
    function Count: Integer;
    procedure Clear;
    function IsWrappedList: Boolean; overload;
    function ItemIsObject(const AIndex: Integer; out aValue: TValue): Boolean;
  end;

implementation

{ TVarDataSource }

constructor TVarDataSource.Create(const VarValue: TValue; const VarOption: TTProVariablesInfos);
begin
  Self.VarValue := VarValue;
  Self.VarOption := VarOption;
end;

{ TTProEqualityComparer }

function TTProEqualityComparer.Equals(const Left, Right: String): Boolean;
begin
  Result := SameText(Left, Right);
end;

function TTProEqualityComparer.GetHashCode(const Value: String): Integer;
begin
  Result := THashBobJenkins.GetHashValue(LowerCase(Value));
end;

{ TTProVariables }

constructor TTProVariables.Create;
begin
  inherited Create([doOwnsValues], TTProEqualityComparer.Create);
end;

{ TToken }

class function TToken.Create(TokType: TTokenType; Value1, Value2: String; Ref1, Ref2: Int64): TToken;
begin
  Result.TokenType := TokType;
  Result.Value1 := Value1;
  Result.Value2 := Value2;
  Result.Ref1 := Ref1;
  Result.Ref2 := Ref2;
end;

class function TToken.CreateFromBytes(const aBytes: TBinaryReader): TToken;
begin
  Result.TokenType := TTokenType(aBytes.ReadByte);
  Result.Value1 := aBytes.ReadString;
  Result.Value2 := aBytes.ReadString;
  Result.Ref1 := aBytes.ReadInt64;
  Result.Ref2 := aBytes.ReadInt64;
end;

procedure TToken.SaveToBytes(const aBytes: TBinaryWriter);
begin
  aBytes.Write(Byte(TokenType));
  aBytes.Write(Value1);
  aBytes.Write(Value2);
  aBytes.Write(Ref1);
  aBytes.Write(Ref2);
end;

function TToken.TokenTypeAsString: String;
begin
  Result := TOKEN_TYPE_DESCR[TokenType];
end;

function TToken.ToString: String;
begin
  case Ref1 of
    - 1:
      Result := Format('%-16s: %s', [TokenTypeAsString, Value1]);
    -2:
      Result := Format('%-16s: %s (jmp: %2.2d)', [TokenTypeAsString, Value1, Ref2]);
  else
    Result := Format('%-16s: %s (r1: %2.2d, r2: %2.2d)', [TokenTypeAsString, Value1, Ref1, Ref2]);
  end;
end;

{ TBlockAddress }

class function TBlockAddress.Create(BeginBlockAddress, EndBlockAddress: Int64): TBlockAddress;
begin
  Result.BeginBlockAddress := BeginBlockAddress;
  Result.EndBlockAddress := EndBlockAddress;
end;

{ TLoopStackItem }

constructor TLoopStackItem.Create(DataSourceName, LoopExpression, FullPath, IteratorName: String);
begin
  inherited Create;
  Self.DataSourceName := DataSourceName;
  Self.LoopExpression := LoopExpression;
  Self.IteratorPosition := -1;
  Self.FullPath := FullPath;
  Self.IteratorName := IteratorName;
  Self.EOF := False;
end;

function TLoopStackItem.IncrementIteratorPosition: Integer;
begin
  Inc(IteratorPosition);
  Result := IteratorPosition;
end;

end.