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

unit TemplatePro.Compiler;

interface

uses
  System.Generics.Collections,
  System.Classes,
  System.SysUtils,
  System.TypInfo,
  System.RTTI,
  TemplatePro.Types,
  TemplatePro.Utils;

type
  TTProCompiler = class
  strict private
    fOptions: TTProCompilerOptions;
    fInputString: string;
    fCharIndex: Int64;
    fCurrentLine: Integer;
    fEncoding: TEncoding;
    fCurrentFileName: String;
    function MatchStartTag: Boolean;
    function MatchEndTag: Boolean;
    function MatchVariable(var aIdentifier: string): Boolean;
    function MatchFilterParamValue(var aParamValue: TFilterParameter): Boolean;
    function MatchSymbol(const aSymbol: string): Boolean;
    function MatchSpace: Boolean;
    function MatchString(out aStringValue: string): Boolean;
    procedure InternalMatchFilter(lIdentifier: String; var lStartVerbatim: Int64; const CurrToken: TTokenType; aTokens: TList<TToken>;
      const lRef2: Integer);
    function GetFunctionParameters: TArray<TFilterParameter>;
    function CreateFilterParameterToken(const FilterParameter: PFilterParameter): TToken;
    procedure Error(const aMessage: string);
    function Step: Char;
    function CurrentChar: Char;
    function GetSubsequentText: String;
    procedure InternalCompileIncludedTemplate(const aTemplate: string; const aTokens: TList<TToken>; const aFileNameRefPath: String;
      const aCompilerOptions: TTProCompilerOptions);
    procedure ProcessJumps(const aTokens: TList<TToken>);
    procedure Compile(const aTemplate: string; const aTokens: TList<TToken>; const aFileNameRefPath: String); overload;
    constructor Create(const aEncoding: TEncoding; const aOptions: TTProCompilerOptions = []); overload;
    procedure MatchFilter(lVarName: string; var lFuncName: string; var lFuncParamsCount: Integer;
      var lFuncParams: TArray<TFilterParameter>);
  public
    function Compile(const aTemplate: string; const aFileNameRefPath: String = ''): ITProCompiledTemplate; overload;
    function CompileToTokens(const aTemplate: string; const aFileNameRefPath: String = ''): TList<TToken>;
    constructor Create(aEncoding: TEncoding = nil); overload;
    class function CompileAndRender(const aTemplate: string; const VarNames: TArray<String>; const VarValues: TArray<TValue>): String;
  end;

implementation

uses
  System.StrUtils,
  System.IOUtils,
  System.NetEncoding,
  System.Math,
  System.Character;

const
  Sign = ['-', '+'];
  Numbers = ['0' .. '9'];
  SignAndNumbers = Sign + Numbers;
  IdenfierAllowedFirstChars = ['a' .. 'z', 'A' .. 'Z', '_', '@'];
  IdenfierAllowedChars = ['a' .. 'z', 'A' .. 'Z', '_'] + Numbers;
  ValueAllowedChars = IdenfierAllowedChars + [' ', '-', '+', '*', '.', '@', '/', '\']; // maybe a lot others
  START_TAG = '{{';
  END_TAG = '}}';

{ TTProCompiler }

procedure TTProCompiler.InternalCompileIncludedTemplate(const aTemplate: string; const aTokens: TList<TToken>;
  const aFileNameRefPath: String; const aCompilerOptions: TTProCompilerOptions);
var
  lCompiler: TTProCompiler;
begin
  lCompiler := TTProCompiler.Create(fEncoding, aCompilerOptions);
  try
    lCompiler.Compile(aTemplate, aTokens, aFileNameRefPath);
    if aTokens[aTokens.Count - 1].TokenType <> ttEOF then
    begin
      Error('Included file ' + aFileNameRefPath + ' doesn''t terminate with EOF');
    end;
    aTokens.Delete(aTokens.Count - 1); // remove the EOF
  finally
    lCompiler.Free;
  end;
end;

procedure TTProCompiler.InternalMatchFilter(lIdentifier: String; var lStartVerbatim: Int64; const CurrToken: TTokenType;
  aTokens: TList<TToken>; const lRef2: Integer);
var
  lFilterName: string;
  lFilterParamsCount: Integer;
  lFilterParams: TArray<TFilterParameter>;
  I: Integer;
begin
  lFilterName := '';
  lFilterParamsCount := -1; { -1 means "no filter applied to value" }
  if MatchSymbol('|') then
  begin
    if not MatchVariable(lFilterName) then
      Error('Invalid function name applied to variable or literal string "' + lIdentifier + '"');
    lFilterParams := GetFunctionParameters;
    lFilterParamsCount := Length(lFilterParams);
  end;

  if not MatchEndTag then
  begin
    Error('Expected end tag "' + END_TAG + '"');
  end;
  lStartVerbatim := fCharIndex;
  aTokens.Add(TToken.Create(CurrToken, lIdentifier, '', lFilterParamsCount, lRef2));

  // add function with params
  if not lFilterName.IsEmpty then
  begin
    aTokens.Add(TToken.Create(ttFilterName, lFilterName, '', lFilterParamsCount));
    if lFilterParamsCount > 0 then
    begin
      for I := 0 to lFilterParamsCount - 1 do
      begin
        aTokens.Add(CreateFilterParameterToken(@lFilterParams[I]));
      end;
    end;
  end;
end;

constructor TTProCompiler.Create(aEncoding: TEncoding = nil);
begin
  if aEncoding = nil then
    Create(TEncoding.UTF8, []) { default encoding }
  else
    Create(aEncoding, []);
end;

function TTProCompiler.CreateFilterParameterToken(const FilterParameter: PFilterParameter): TToken;
begin
  case FilterParameter.ParType of
    fptString:
      begin
        Result.TokenType := ttFilterParameter;
        Result.Value1 := FilterParameter.ParStrText;
        Result.Ref2 := Ord(FilterParameter.ParType);
      end;

    fptInteger:
      begin
        Result.TokenType := ttFilterParameter;
        Result.Value1 := FilterParameter.ParIntValue.ToString;
        Result.Ref2 := Ord(FilterParameter.ParType);
      end;

    fptVariable:
      begin
        Result.TokenType := ttFilterParameter;
        Result.Value1 := FilterParameter.ParStrText;
        Result.Ref2 := Ord(FilterParameter.ParType);
      end;

  else
    raise ETProCompilerException.Create('Invalid filter parameter type');
  end;

end;

procedure TTProCompiler.MatchFilter(lVarName: string; var lFuncName: string; var lFuncParamsCount: Integer;
  var lFuncParams: TArray<TFilterParameter>);
begin
  MatchSpace;
  if not MatchVariable(lFuncName) then
    Error('Invalid function name applied to variable ' + lVarName);
  MatchSpace;
  lFuncParams := GetFunctionParameters;
  lFuncParamsCount := Length(lFuncParams);
  MatchSpace;
end;

function TTProCompiler.CurrentChar: Char;
begin
  Result := fInputString.Chars[fCharIndex]
end;

function TTProCompiler.MatchEndTag: Boolean;
begin
  Result := MatchSymbol(END_TAG);
end;

function TTProCompiler.MatchVariable(var aIdentifier: string): Boolean;
var
  lTmp: String;
begin
  aIdentifier := '';
  lTmp := '';
  Result := False;
  if CharInSet(fInputString.Chars[fCharIndex], IdenfierAllowedFirstChars) then
  begin
    lTmp := fInputString.Chars[fCharIndex];
    Inc(fCharIndex);
    if lTmp = '@' then
    begin
      if fInputString.Chars[fCharIndex] = '@' then
      begin
        lTmp := '@@';
        Inc(fCharIndex);
      end;
    end;

    while CharInSet(fInputString.Chars[fCharIndex], IdenfierAllowedChars) do
    begin
      lTmp := lTmp + fInputString.Chars[fCharIndex];
      Inc(fCharIndex);
    end;
    Result := True;
    aIdentifier := lTmp;
  end;
  if Result then
  begin
    while MatchSymbol('.') do
    begin
      lTmp := '';
      if not MatchVariable(lTmp) then
      begin
        Error('Expected identifier after "' + aIdentifier + '"');
      end;
      aIdentifier := aIdentifier + '.' + lTmp;
    end;
  end;
end;

function TTProCompiler.MatchFilterParamValue(var aParamValue: TFilterParameter): Boolean;
var
  lTmp: String;
  lIntegerPart, lDecimalPart: Integer;
  lDigits: Integer;
  lTmpFloat: Extended;
begin
  lTmp := '';
  Result := False;
  if MatchString(lTmp) then
  begin
    aParamValue.ParType := fptString;
    aParamValue.ParStrText := lTmp;
    Result := True;
  end
  else if CharInSet(fInputString.Chars[fCharIndex], SignAndNumbers) then
  begin
    lTmp := fInputString.Chars[fCharIndex];
    Inc(fCharIndex);
    while CharInSet(fInputString.Chars[fCharIndex], Numbers) do
    begin
      lTmp := lTmp + fInputString.Chars[fCharIndex];
      Inc(fCharIndex);
    end;
    lIntegerPart := StrToInt(lTmp);
    if MatchSymbol('.') then
    begin
      lTmp := '';
      while CharInSet(fInputString.Chars[fCharIndex], Numbers) do
      begin
        lTmp := lTmp + fInputString.Chars[fCharIndex];
        Inc(fCharIndex);
      end;
      lDigits := lTmp.Trim.Length;
      if lDigits = 0 then
      begin
        Error('Expected digit/s after "."');
      end;
      lDecimalPart := lTmp.Trim.ToInteger;
      lTmpFloat := Power(10, lDigits);
      Result := True;
      aParamValue.ParType := fptFloat;
      aParamValue.ParFloatValue := lIntegerPart + lDecimalPart / lTmpFloat;
    end
    else
    begin
      Result := True;
      aParamValue.ParType := fptInteger;
      aParamValue.ParIntValue := lTmp.Trim.ToInteger
    end;
  end
  else if CharInSet(fInputString.Chars[fCharIndex], IdenfierAllowedChars) then
  begin
    while CharInSet(fInputString.Chars[fCharIndex], ValueAllowedChars) do
    begin
      lTmp := lTmp + fInputString.Chars[fCharIndex];
      Inc(fCharIndex);
    end;
    Result := True;
    aParamValue.ParType := fptVariable;
    aParamValue.ParStrText := lTmp.Trim;
  end;
end;

function TTProCompiler.MatchSpace: Boolean;
begin
  Result := MatchSymbol(' ');
  while MatchSymbol(' ') do;
end;

function TTProCompiler.MatchStartTag: Boolean;
begin
  Result := MatchSymbol(START_TAG);
end;

function TTProCompiler.MatchString(out aStringValue: String): Boolean;
begin
  aStringValue := '';
  Result := MatchSymbol('"');
  if Result then
  begin
    while not MatchSymbol('"') do // no escape so far
    begin
      if CurrentChar = #0 then
      begin
        Error('Unclosed string at the end of file');
      end;
      aStringValue := aStringValue + CurrentChar;
      Step;
    end;
  end;
end;

function TTProCompiler.MatchSymbol(const aSymbol: string): Boolean;
var
  lSymbolIndex: Integer;
  lSavedCharIndex: Int64;
  lSymbolLength: Integer;
begin
  if aSymbol.IsEmpty then
    Exit(True);
  lSavedCharIndex := fCharIndex;
  lSymbolIndex := 0;
  lSymbolLength := Length(aSymbol);
  while (fInputString.Chars[fCharIndex].ToLower = aSymbol.Chars[lSymbolIndex].ToLower) and (lSymbolIndex < lSymbolLength) do
  begin
    Inc(fCharIndex);
    Inc(lSymbolIndex);
  end;
  Result := (lSymbolIndex > 0) and (lSymbolIndex = lSymbolLength);
  if not Result then
    fCharIndex := lSavedCharIndex;
end;

function TTProCompiler.Step: Char;
begin
  Inc(fCharIndex);
  Result := CurrentChar;
end;

function TTProCompiler.CompileToTokens(const aTemplate: string; const aFileNameRefPath: String): TList<TToken>;
var
  lFileNameRefPath: string;
begin
  if aFileNameRefPath.IsEmpty then
  begin
    lFileNameRefPath := TPath.Combine(TPath.GetDirectoryName(GetModuleName(HInstance)), 'main.template');
  end
  else
  begin
    lFileNameRefPath := TPath.GetFullPath(aFileNameRefPath);
  end;
  fCurrentFileName := lFileNameRefPath;
  Result := TList<TToken>.Create;
  try
    Compile(aTemplate, Result, fCurrentFileName);
    ProcessJumps(Result);
  except
    Result.Free;
    raise;
  end;
end;

function TTProCompiler.Compile(const aTemplate: string; const aFileNameRefPath: String): ITProCompiledTemplate;
begin
  // This method requires TTProCompiledTemplate class to be available
  // Use CompileToTokens method instead, or provide TTProCompiledTemplate.Create externally
  raise ETProCompilerException.Create('Compile method requires TTProCompiledTemplate class. Use CompileToTokens instead.');
end;

class function TTProCompiler.CompileAndRender(const aTemplate: String; const VarNames: TArray<String>;
  const VarValues: TArray<TValue>): String;
begin
  // This method requires TTProCompiledTemplate class to be available for rendering
  // Consider moving this method to a unit that has access to TTProCompiledTemplate
  raise ETProCompilerException.Create('CompileAndRender method requires TTProCompiledTemplate class. Move to appropriate unit.');
end;

constructor TTProCompiler.Create(const aEncoding: TEncoding; const aOptions: TTProCompilerOptions);
begin
  inherited Create;
  fEncoding := aEncoding;
  fOptions := aOptions;
end;

procedure TTProCompiler.Compile(const aTemplate: string; const aTokens: TList<TToken>; const aFileNameRefPath: String);
var
  lForStatementCount: Integer;
  lIfStatementCount: Integer;
  lLastToken: TTokenType;
  lChar: Char;
  lVarName: string;
  lFuncName: string;
  lIdentifier: string;
  lIteratorName: string;
  lStartVerbatim: Int64;
  lEndVerbatim: Int64;
  lNegation: Boolean;
  lFuncParams: TArray<TFilterParameter>;
  lFuncParamsCount: Integer;
  I: Integer;
  lTemplateSource: string;
  lCurrentFileName: string;
  lStringValue: string;
  lRef2: Integer;
  lContentOnThisLine: Integer;
  lStrVerbatim: string;
  lLayoutFound: Boolean;
  lFoundVar: Boolean;
  lFoundFilter: Boolean;
begin
  aTokens.Add(TToken.Create(ttSystemVersion, TEMPLATEPRO_VERSION, ''));
  lLastToken := ttEOF;
  lLayoutFound := False;
  lContentOnThisLine := 0;
  fCurrentFileName := aFileNameRefPath;
  fCharIndex := -1;
  fCurrentLine := 1;
  lIfStatementCount := -1;
  lForStatementCount := -1;
  fInputString := aTemplate;
  lStartVerbatim := 0;
  if fInputString.Length > 0 then
  begin
    Step;
  end
  else
  begin
    aTokens.Add(TToken.Create(ttEOF, '', ''));
    fCharIndex := 1; { doesnt' execute while }
  end;
  while fCharIndex <= fInputString.Length do
  begin
    lChar := CurrentChar;
    if lChar = #0 then // eof
    begin
      lEndVerbatim := fCharIndex;
      if lEndVerbatim - lStartVerbatim > 0 then
      begin
        lLastToken := ttContent;
        aTokens.Add(TToken.Create(lLastToken, fInputString.Substring(lStartVerbatim, lEndVerbatim - lStartVerbatim), ''));
      end;
      aTokens.Add(TToken.Create(ttEOF, '', ''));
      Break;
    end;

    if MatchSymbol(sLineBreak) then { linebreak }
    begin
      lEndVerbatim := fCharIndex - Length(sLineBreak);
      if lEndVerbatim - lStartVerbatim > 0 then
      begin
        Inc(lContentOnThisLine);
        lStrVerbatim := fInputString.Substring(lStartVerbatim, lEndVerbatim - lStartVerbatim);
        aTokens.Add(TToken.Create(ttContent, lStrVerbatim, ''));
      end;
      lStartVerbatim := fCharIndex;
      if lLastToken = ttLineBreak then
        Inc(lContentOnThisLine);
      lLastToken := ttLineBreak;
      if lContentOnThisLine > 0 then
      begin
        aTokens.Add(TToken.Create(lLastToken, '', ''));
      end;
      Inc(fCurrentLine);
      lContentOnThisLine := 0;
    end
    else if MatchStartTag then { starttag }
    begin
      lEndVerbatim := fCharIndex - Length(START_TAG);

      if lEndVerbatim - lStartVerbatim > 0 then
      begin
        lLastToken := ttContent;
        aTokens.Add(TToken.Create(lLastToken, fInputString.Substring(lStartVerbatim, lEndVerbatim - lStartVerbatim), ''));
      end;

      if CurrentChar = START_TAG[1] then
      begin
        lLastToken := ttContent;
        aTokens.Add(TToken.Create(lLastToken, START_TAG, ''));
        Inc(fCharIndex);
        lStartVerbatim := fCharIndex;
        Continue;
      end;

      if CurrentChar = ':' then // variable
      begin
        lFoundVar := False;
        lFoundFilter := False;
        Step;
        MatchSpace;
        lRef2 := -1;
        if MatchVariable(lVarName) then { variable }
        begin
          lFoundVar := True;
          if lVarName.IsEmpty then
            Error('Invalid variable name');
          lFuncName := '';
          lFuncParamsCount := -1; { -1 means "no filter applied to value" }
          lRef2 := IfThen(MatchSymbol('$'), 1, -1); // {{value$}} means no escaping
          MatchSpace;
        end;

        if MatchSymbol('|') then
        begin
          lFoundFilter := True;
          MatchFilter(lVarName, lFuncName, lFuncParamsCount, lFuncParams);
        end;

        if lFoundVar or lFoundFilter then
        begin
          if not MatchEndTag then
          begin
            Error('Expected end tag "' + END_TAG + '"');
          end;
          lStartVerbatim := fCharIndex;
          lLastToken := ttValue;
          aTokens.Add(TToken.Create(lLastToken, lVarName, '', lFuncParamsCount, lRef2));
          Inc(lContentOnThisLine);

          // add function with params
          if not lFuncName.IsEmpty then
          begin
            aTokens.Add(TToken.Create(ttFilterName, lFuncName, '', lFuncParamsCount));
            if lFuncParamsCount > 0 then
            begin
              for I := 0 to lFuncParamsCount - 1 do
              begin
                aTokens.Add(CreateFilterParameterToken(@lFuncParams[I]));
              end;
            end;
          end;
        end
        else
        begin
          Error('Expected variable or filter');
        end;
      end
      else
      begin
        MatchSpace;
        if MatchSymbol('for') then { loop }
        begin
          if not MatchSpace then
            Error('Expected "space"');
          if not MatchVariable(lIteratorName) then
            Error('Expected iterator name after "for" - EXAMPLE: for iterator in iterable');
          if not MatchSpace then
            Error('Expected "space"');
          if not MatchSymbol('in') then
            Error('Expected "in" after "for" iterator');
          if not MatchSpace then
            Error('Expected "space"');
          if not MatchVariable(lIdentifier) then
            Error('Expected iterable "for"');
          MatchSpace;
          if not MatchEndTag then
            Error('Expected closing tag for "for"');

          // create another element in the sections stack
          Inc(lForStatementCount);
          lLastToken := ttFor;
          if lIdentifier = lIteratorName then
          begin
            Error('loop data source and its iterator cannot have the same name: ' + lIdentifier)
          end;
          aTokens.Add(TToken.Create(lLastToken, lIdentifier, lIteratorName));
          lStartVerbatim := fCharIndex;
        end
        else if MatchSymbol('endfor') then { endfor }
        begin
          MatchSpace;
          if not MatchEndTag then
            Error('Expected closing tag');
          if lForStatementCount = -1 then
          begin
            Error('endfor without loop');
          end;
          lLastToken := ttEndFor;
          aTokens.Add(TToken.Create(lLastToken, '', ''));
          Dec(lForStatementCount);
          lStartVerbatim := fCharIndex;
        end
        else if MatchSymbol('continue') then { continue }
        begin
          MatchSpace;
          lLastToken := ttContinue;
          aTokens.Add(TToken.Create(lLastToken, '', ''));
        end
        else if MatchSymbol('endif') then { endif }
        begin
          MatchSpace;
          if lIfStatementCount = -1 then
          begin
            Error('"endif" without "if"');
          end;
          if not MatchEndTag then
          begin
            Error('Expected closing tag for "endif"');
          end;

          lLastToken := ttEndIf;
          aTokens.Add(TToken.Create(lLastToken, '', ''));

          Dec(lIfStatementCount);
          lStartVerbatim := fCharIndex;
        end
        else if MatchSymbol('if') then
        begin
          if not MatchSpace then
          begin
            Error('Expected <space> after "if"');
          end;
          lNegation := MatchSymbol('!');
          MatchSpace;
          if not MatchVariable(lIdentifier) then
            Error('Expected identifier after "if"');
          lFuncParamsCount := -1;
          { lFuncParamsCount = -1 means "no filter applied" }
          lFuncName := '';
          if MatchSymbol('|') then
          begin
            MatchSpace;
            if not MatchVariable(lFuncName) then
              Error('Invalid function applied to variable ' + lIdentifier);
            lFuncParams := GetFunctionParameters;
            lFuncParamsCount := Length(lFuncParams);
          end;
          MatchSpace;
          if not MatchEndTag then
            Error('Expected closing tag for "if" after "' + lIdentifier + '"');
          if lNegation then
          begin
            lIdentifier := '!' + lIdentifier;
          end;
          lLastToken := ttIfThen;
          aTokens.Add(TToken.Create(lLastToken, '' { lIdentifier } , ''));
          Inc(lIfStatementCount);
          lStartVerbatim := fCharIndex;

          lLastToken := ttBoolExpression;
          aTokens.Add(TToken.Create(lLastToken, lIdentifier, '', lFuncParamsCount, -1 { no html escape } ));

          // add function with params
          if not lFuncName.IsEmpty then
          begin
            aTokens.Add(TToken.Create(ttFilterName, lFuncName, '', lFuncParamsCount));
            if lFuncParamsCount > 0 then
            begin
              for I := 0 to lFuncParamsCount - 1 do
              begin
                aTokens.Add(CreateFilterParameterToken(@lFuncParams[I]));
              end;
            end;
          end;
        end
        else if MatchSymbol('else') then
        begin
          if not MatchEndTag then
            Error('Expected closing tag for "else"');

          lLastToken := ttElse;
          aTokens.Add(TToken.Create(lLastToken, '', ''));
          lStartVerbatim := fCharIndex;
        end
        else if MatchSymbol('include') then { include }
        begin
          if not MatchSpace then
            Error('Expected "space" after "include"');

          { In a future version we could implement a function call }
          if not MatchString(lStringValue) then
          begin
            Error('Expected string after "include"');
          end;

          MatchSpace;

          if not MatchEndTag then
            Error('Expected closing tag for "include"');

          // create another element in the sections stack
          try
            if TDirectory.Exists(aFileNameRefPath) then
            begin
              lCurrentFileName := TPath.GetFullPath(TPath.Combine(aFileNameRefPath, lStringValue));
            end
            else
            begin
              lCurrentFileName := TPath.GetFullPath(TPath.Combine(TPath.GetDirectoryName(aFileNameRefPath), lStringValue));
            end;
            lTemplateSource := TFile.ReadAllText(lCurrentFileName, fEncoding);
          except
            on E: Exception do
            begin
              Error('Cannot read "' + lStringValue + '"');
            end;
          end;
          Inc(lContentOnThisLine);
          InternalCompileIncludedTemplate(lTemplateSource, aTokens, lCurrentFileName, [coIgnoreSysVersion, coParentTemplate]);
          lStartVerbatim := fCharIndex;
        end
        else if MatchSymbol('extends') then { extends }
        begin
          if lLayoutFound then
            Error('Duplicated "extends"');
          lLayoutFound := True;
          if coParentTemplate in fOptions then
            Error('A parent page cannot extends another page');

          if not MatchSpace then
            Error('Expected "space" after "extends"');

          if not MatchString(lStringValue) then
          begin
            Error('Expected string after "extends"');
          end;
          MatchSpace;
          if not MatchEndTag then
            Error('Expected closing tag for "extends"');
          try
            if TDirectory.Exists(aFileNameRefPath) then
            begin
              lCurrentFileName := TPath.GetFullPath(TPath.Combine(aFileNameRefPath, lStringValue));
            end
            else
            begin
              lCurrentFileName := TPath.GetFullPath(TPath.Combine(TPath.GetDirectoryName(aFileNameRefPath), lStringValue));
            end;
            lTemplateSource := TFile.ReadAllText(lCurrentFileName, fEncoding);
          except
            on E: Exception do
            begin
              Error('Cannot read "' + lStringValue + '"');
            end;
          end;
          Inc(lContentOnThisLine);
          aTokens.Add(TToken.Create(ttInfo, STR_BEGIN_OF_LAYOUT, ''));
          InternalCompileIncludedTemplate(lTemplateSource, aTokens, lCurrentFileName, [coParentTemplate, coIgnoreSysVersion]);
          aTokens.Add(TToken.Create(ttInfo, STR_END_OF_LAYOUT, ''));
          lStartVerbatim := fCharIndex;
        end
        else if MatchSymbol('block') then { block - parent }
        begin
          if not MatchSpace then
            Error('Expected "space" after "block"');
          if not MatchString(lStringValue) then
            Error('Expected string after "block"');
          MatchSpace;
          if not MatchEndTag then
            Error('Expected closing tag for "block"');
          lLastToken := ttBlock;
          aTokens.Add(TToken.Create(lLastToken, lStringValue, ''));
          lStartVerbatim := fCharIndex;
        end
        else if MatchSymbol('endblock') then { endblock - parent }
        begin
          MatchSpace;
          if not MatchEndTag then
            Error('Expected closing tag for "endblock"');
          lLastToken := ttEndBlock;
          aTokens.Add(TToken.Create(lLastToken, '', ''));
          lStartVerbatim := fCharIndex;
        end
        else if MatchSymbol('exit') then { exit }
        begin
          MatchSpace;
          lLastToken := ttExit;
          aTokens.Add(TToken.Create(lLastToken, '', ''));
          lLastToken := ttEOF;
          aTokens.Add(TToken.Create(lLastToken, '', ''));
          Break;
        end
        else if MatchString(lStringValue) then { string }
        begin
          lLastToken := ttLiteralString;
          Inc(lContentOnThisLine);
          lRef2 := IfThen(MatchSymbol('$'), 1, -1);
          // {{value$}} means no escaping
          MatchSpace;
          InternalMatchFilter(lStringValue, lStartVerbatim, ttLiteralString, aTokens, lRef2);
        end
        else if MatchSymbol('#') then
        begin
          while not MatchEndTag do
          begin
            Step;
          end;
          lStartVerbatim := fCharIndex;
          lLastToken := ttComment; { will not added into compiled template }
        end
        else
        begin
          lIdentifier := GetSubsequentText;
          Error('Expected command, got "' + lIdentifier + '"');
        end;
      end;
    end
    else
    begin
      Step;
    end;
  end;
end;

procedure TTProCompiler.Error(const aMessage: string);
begin
  raise ETProCompilerException.CreateFmt('%s - (got: "%s") at line %d in file %s',
    [aMessage, GetSubsequentText, fCurrentLine, fCurrentFileName]);
end;

procedure TTProCompiler.ProcessJumps(const aTokens: TList<TToken>);
var
  lForInStack: TStack<Int64>;
  lContinueStack: TStack<Int64>;
  lIfStatementStack: TStack<TIfThenElseIndex>;
  I: Int64;
  lToken: TToken;
  lForAddress: Int64;
  lIfStackItem: TIfThenElseIndex;
  lCheckForUnbalancedPair: Boolean;
  lTmpContinueAddress: Int64;
  lBlockDict: TDictionary<string, TBlockAddress>;
  lBlockAddress: TBlockAddress;
  lWithinBlock: Boolean;
  lWithinBlockName: string;
  lTemplateSectionType: TTProTemplateSectionType;
  lErrorMessage: String;
begin
  lWithinBlock := False;
  lTemplateSectionType := stUnknown;
  lCheckForUnbalancedPair := True;
  lBlockDict := TDictionary<string, TBlockAddress>.Create(TTProEqualityComparer.Create);
  try
    lForInStack := TStack<Int64>.Create;
    try
      lContinueStack := TStack<Int64>.Create;
      try
        lIfStatementStack := TStack<TIfThenElseIndex>.Create;
        try
          for I := 0 to aTokens.Count - 1 do
          begin
            case aTokens[I].TokenType of
              ttInfo:
                begin
                  if not HandleTemplateSectionStateMachine(aTokens[I].Value1, lTemplateSectionType, lErrorMessage) then
                    Error(lErrorMessage)
                end;

              ttFor:
                begin
                  if lContinueStack.Count > 0 then
                  begin
                    Error('Continue stack corrupted');
                  end;
                  lForInStack.Push(I);
                end;

              ttEndFor:
                begin
                  { ttFor.Ref1 --> endfor }
                  lForAddress := lForInStack.Pop;
                  lToken := aTokens[lForAddress];
                  lToken.Ref1 := I;
                  aTokens[lForAddress] := lToken;

                  { ttEndFor.Ref1 --> for }
                  lToken := aTokens[I];
                  lToken.Ref1 := lForAddress;
                  aTokens[I] := lToken;

                  { if there's a ttContinue (or more than one), it must jump to endfor }
                  while lContinueStack.Count > 0 do
                  begin
                    lTmpContinueAddress := lContinueStack.Pop;
                    lToken := aTokens[lTmpContinueAddress];
                    lToken.Ref1 := I;
                    aTokens[lTmpContinueAddress] := lToken;
                  end;
                end;

              ttContinue:
                begin
                  lContinueStack.Push(I);
                end;

              ttBlock:
                begin
                  if lWithinBlock then
                  begin
                    Error('Block cannot be nested - nested block name is ' + aTokens[I].Value1);
                  end;
                  lToken := aTokens[I];
                  lWithinBlock := True;
                  lWithinBlockName := lToken.Value1;
                  if lBlockDict.TryGetValue(lWithinBlockName, lBlockAddress) then
                  begin
                    if lTemplateSectionType = stPage then
                    begin
                      // this block is overwriting that from layout
                      // so I've to put ttBlock.Ref1 to the current block begin
                      // ttBlock.Ref1 -> where to jump
                      // ttBlock.Ref2 -> where to return after jump (should be already there)
                      lToken := aTokens[lBlockAddress.BeginBlockAddress];
                      lToken.Ref1 := I; // current block address
                      aTokens[lBlockAddress.BeginBlockAddress] := lToken;
                    end
                    else if lTemplateSectionType = stLayout then
                      Error('Duplicated layout block: ' + lWithinBlockName)
                    else
                      Error('Unexpected ttBlock in stUnknown state');
                  end
                  else
                  begin
                    if lTemplateSectionType = stLayout then
                    begin
                      // this block is defining a placeholder for future blocks
                      // so I've to save the current address in BlockDict
                      lBlockDict.Add(lWithinBlockName, TBlockAddress.Create(I, 0));
                    end
                    else if lTemplateSectionType = stPage then
                    begin
                      // Error('Block "' + lWithinBlockName + '" doesn''t exist in current layout page')
                      // do nothing - a page can define a block which is not available in the parent page
                      // that's correct... the block will be just (compiled but) ignored
                    end
                    else
                      Error('Unexpected ttBlock in stUnknown state');
                  end;
                end;

              ttEndBlock:
                begin
                  if not lWithinBlock then
                  begin
                    Error('endblock without block');
                  end;
                  if lBlockDict.TryGetValue(lWithinBlockName, lBlockAddress) then
                  begin
                    if lTemplateSectionType = stPage then
                    begin
                      // do nothing
                      // // this block is overwriting the one from layout page
                      // // block.ref1 --> when overwritten points to the actual block to execute,
                      // // block.ref2 --> current end block (in case of overwritten block, ref2 is the return address)
                      // lToken := aTokens[lBlockAddress.BeginBlockAddress]; { block from layout page }
                      // // this block has not been overwritten (yet) just continue
                      // // but the beginblock must know where its endblock is
                      // // the relative endblock is at ttBlock.Ref2
                      // lToken.Ref1 := I;
                      // aTokens[lBlockAddress.BeginBlockAddress] := lToken;
                    end
                    else if lTemplateSectionType = stLayout then
                    begin
                      // just set ttBlock.Ref2 to the current address (which is its endblock)
                      lToken := aTokens[lBlockAddress.BeginBlockAddress]; { block from layout page }
                      lToken.Ref2 := I;
                      aTokens[lBlockAddress.BeginBlockAddress] := lToken;
                    end;
                  end
                  else
                  begin
                    // if a block doesn't exist in parent but in child
                    // it's ok, but will be just ignored
                  end;
                  lWithinBlock := False;
                  lWithinBlockName := '';
                end;

              { ttIfThen.Ref1 points always to relative else (if present otherwise -1) }
              { ttIfThen.Ref2 points always to relative endif }

              ttIfThen:
                begin
                  lIfStackItem.IfIndex := I;
                  lIfStackItem.ElseIndex := -1;
                  { -1 means: "there isn't ttElse" }
                  lIfStatementStack.Push(lIfStackItem);
                end;
              ttElse:
                begin
                  lIfStackItem := lIfStatementStack.Pop;
                  lIfStackItem.ElseIndex := I;
                  lIfStatementStack.Push(lIfStackItem);
                end;
              ttEndIf:
                begin
                  lIfStackItem := lIfStatementStack.Pop;

                  { fixup ifthen }
                  lToken := aTokens[lIfStackItem.IfIndex];
                  lToken.Ref2 := I;
                  { ttIfThen.Ref2 points always to relative endif }
                  lToken.Ref1 := lIfStackItem.ElseIndex;
                  { ttIfThen.Ref1 points always to relative else (if present, otherwise -1) }
                  aTokens[lIfStackItem.IfIndex] := lToken;

                  { fixup else }
                  if lIfStackItem.ElseIndex > -1 then
                  begin
                    lToken := aTokens[lIfStackItem.ElseIndex];
                    lToken.Ref2 := I;
                    { ttElse.Ref2 points always to relative endif }
                    aTokens[lIfStackItem.ElseIndex] := lToken;
                  end;
                end;
              ttExit:
                begin
                  lCheckForUnbalancedPair := False;
                end;
            end;
          end; // for

          if lCheckForUnbalancedPair and (lIfStatementStack.Count > 0) then
          begin
            Error('Unbalanced "if" - expected "endif"');
          end;
          if lCheckForUnbalancedPair and (lForInStack.Count > 0) then
          begin
            Error('Unbalanced "for" - expected "endfor"');
          end;
        finally
          lIfStatementStack.Free;
        end;
      finally
        lContinueStack.Free;
      end;
    finally
      lForInStack.Free;
    end;
  finally
    lBlockDict.Free;
  end;
  // TTProCompiledTemplate.InternalDumpToFile('debug.compiled.txt', aTokens);
end;

function TTProCompiler.GetFunctionParameters: TArray<TFilterParameter>;
var
  lFuncPar: TFilterParameter;
begin
  Result := [];
  while MatchSymbol(',') do
  begin
    MatchSpace;
    if not MatchFilterParamValue(lFuncPar) then
      Error('Expected function parameter');
    Result := Result + [lFuncPar];
    MatchSpace;
  end;
end;

function TTProCompiler.GetSubsequentText: String;
var
  I: Integer;
begin
  Result := CurrentChar;
  if Result = #0 then
  begin
    Result := '<eof>';
  end
  else
  begin
    Step;
    I := 0;
    while (CurrentChar <> #0) and (CurrentChar <> END_TAG[1]) and (I < 20) do
    begin
      Result := Result + CurrentChar;
      Step;
      Inc(I);
    end;
  end;
end;

end.