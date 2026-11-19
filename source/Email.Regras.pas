unit Email.Regras;
{$mode delphi}{$H+}
interface
uses SysUtils;
type
  EEmail = class(Exception);
  TEmailTrabalho = record
    Id, Origem, Documento: Int64;
    Empresa, Usuario, Conta: Integer;
    Chave, Dono, Tipo, Remetente, Nome, ReplyTo, Destinatario: string;
    Assunto, Texto, Html, Xml, Numero: string;
    Host, Login, Senha: string;
    Porta: Integer;
    SSL, TLS: Boolean;
    Criado: TDateTime;
  end;
  TEmailAnexos = record
    Pdf: TBytes;
    Xml: string;
  end;
function EmailValido(const S: string): Boolean;
procedure ConferirCabecalho(const S: string; Maximo: Integer);
procedure ConferirTrabalho(const T: TEmailTrabalho);
function IdMensagem(const T: TEmailTrabalho): string;
implementation
procedure ConferirCabecalho(const S: string; Maximo: Integer);
var C: Char;
begin
  if (S = '') or (Length(S) > Maximo) then raise EEmail.Create('Cabecalho de e-mail invalido.');
  for C in S do if Ord(C) < 32 then raise EEmail.Create('Cabecalho de e-mail invalido.');
end;
function EmailValido(const S: string): Boolean;
var P, I: Integer;
begin
  Result := False;
  P := Pos('@', S);
  if (P < 2) or (P >= Length(S)) or (Length(S) > 254) then Exit;
  for I := 1 to Length(S) do
    if (Ord(S[I]) <= 32) or (S[I] in ['<', '>', ',', ';', '"', '\', '(', ')', ':']) or
      ((S[I] = '@') and (I <> P)) then Exit;
  Result := Pos('.', Copy(S, P + 1, MaxInt)) > 1;
end;
procedure ConferirTrabalho(const T: TEmailTrabalho);
begin
  if not EmailValido(T.Remetente) or not EmailValido(T.Destinatario) then
    raise EEmail.Create('Remetente ou destinatario invalido.');
  if (T.ReplyTo <> '') and not EmailValido(T.ReplyTo) then raise EEmail.Create('Reply-To invalido.');
  ConferirCabecalho(T.Assunto, 1000);
  if T.Nome <> '' then ConferirCabecalho(T.Nome, 500);
  if (T.Host = '') or (T.Porta < 1) or (T.Porta > 65535) or
    (not T.SSL and not T.TLS) or (T.Senha = '') then raise EEmail.Create('Confira a conta SMTP e o uso de SSL/TLS.');
  ConferirCabecalho(T.Host, 254);
end;
function IdMensagem(const T: TEmailTrabalho): string;
begin
  Result := '<aguia-' + T.Chave + '@' + Copy(T.Remetente, Pos('@', T.Remetente) + 1, MaxInt) + '>';
end;
end.
