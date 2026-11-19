unit Email.Config;
{$mode delphi}{$H+}
interface
uses SysUtils, IniFiles, Classes;
type
  TEmailConfig = record
    Banco, Usuario, Senha, CA, ClientLibrary: string;
    Intervalo, Timeout, Limite: Integer;
  end;
function LerConfig(const Arquivo: string): TEmailConfig;
implementation
function Caminho(const Base, Valor: string): string;
begin
  Result := Valor;
  if Result = '' then Exit;
  {$IFDEF MSWINDOWS}
  if (ExtractFileDrive(Result) = '') and (Result[1] <> '\') and (Result[1] <> '/') then
  {$ELSE}
  if Result[1] <> '/' then
  {$ENDIF}
    Result := ExpandFileName(Base + Result);
end;
function LerConfig(const Arquivo: string): TEmailConfig;
var I: TIniFile; L, V: TStringList; Linha, S, Base, Servidor, Porta: string; P, K, B: Integer;
begin
  Result := Default(TEmailConfig);
  if not FileExists(Arquivo) then raise Exception.Create('Arquivo email.ini nao encontrado.');
  Base := ExtractFilePath(ExpandFileName(Arquivo));
  I := TIniFile.Create(Arquivo);
  try
    S := Caminho(Base, I.ReadString('BANCO', 'ConfigFirebird', ''));
    if S <> '' then
    begin
      L := TStringList.Create; V := TStringList.Create;
      try
        L.LoadFromFile(S);
        for Linha in L do
        begin
          P := Pos('=', Linha);
          if (P > 1) and not (Trim(Linha)[1] in [';', '#', '[']) then
            V.Values[LowerCase(Trim(Copy(Linha, 1, P - 1)))] := Copy(Linha, P + 1, MaxInt);
        end;
        Servidor := Trim(V.Values['server']); if Servidor = '' then Servidor := '127.0.0.1';
        Porta := Trim(V.Values['port']); if Porta = '' then Porta := '3050';
        Result.Banco := Servidor + '/' + Porta + ':' + Trim(V.Values['database']);
        Result.Usuario := Trim(V.Values['user_name']);
        S := V.Values['password'];
        if S = 'masterkey' then Result.Senha := S
        else for K := 1 to Length(S) do
        begin
          B := Ord(S[K]); if (B < 32) or (B > 254) then B := 255;
          Result.Senha := Result.Senha + Chr(B - 118);
        end;
      finally V.Free; L.Free; end;
    end
    else
    begin
      Result.Banco := I.ReadString('BANCO', 'Banco', '');
      Result.Usuario := I.ReadString('BANCO', 'Usuario', GetEnvironmentVariable('ISC_USER'));
      Result.Senha := I.ReadString('BANCO', 'Senha', GetEnvironmentVariable('ISC_PASSWORD'));
    end;
    Result.CA := Caminho(Base, I.ReadString('EMAIL', 'CA', ''));
    Result.ClientLibrary := Caminho(Base, I.ReadString('BANCO', 'ClientLibrary', ''));
    Result.Intervalo := I.ReadInteger('EMAIL', 'Intervalo', 5);
    Result.Timeout := I.ReadInteger('EMAIL', 'Timeout', 25000);
    Result.Limite := I.ReadInteger('EMAIL', 'Limite', 10);
    if (Result.Banco = '') or (Result.Usuario = '') or (Result.Senha = '') then
      raise Exception.Create('Configure a conexao Firebird.');
    if Result.Intervalo < 1 then Result.Intervalo := 1;
    if Result.Timeout < 1000 then Result.Timeout := 1000;
    if Result.Timeout > 60000 then Result.Timeout := 60000;
    if Result.Limite < 1 then Result.Limite := 1;
    if Result.Limite > 50 then Result.Limite := 50;
    {$IFDEF UNIX}if Result.CA = '' then Result.CA := '/etc/ssl/certs/ca-certificates.crt';{$ENDIF}
    if (Result.CA = '') or not FileExists(Result.CA) then
      raise Exception.Create('Configure EMAIL.CA com o pacote PEM de autoridades certificadoras.');
  finally I.Free; end;
end;
end.
