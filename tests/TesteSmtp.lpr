program TesteSmtp;
{$mode delphi}{$H+}{$codepage utf8}
{ Teste manual explicito, sem documentos fiscais. Nao integra o pacote do servico.
  TesteSmtp email.ini empresa usuario conta destinatario --confirmar-teste }
uses {$IFDEF UNIX}cthreads,{$ENDIF}SysUtils, Math, ibase60dyn,
  Email.Config, Email.Regras, Email.Banco, Email.Smtp;
type
  TConfirmacao = class
    function Antes(const T: TEmailTrabalho): Boolean;
  end;
function TConfirmacao.Antes(const T: TEmailTrabalho): Boolean;
begin Result := True; end;
var C: TEmailConfig; B: TEmailBanco; T: TEmailTrabalho; A: TEmailAnexos;
  G: TGUID; F: TConfirmacao; Enviando: Boolean;
begin
  SetMultiByteConversionCodePage(CP_UTF8);
  SetExceptionMask([exInvalidOp,exDenormalized,exZeroDivide,exOverflow,exUnderflow,exPrecision]);
  if (ParamCount<>6) or (ParamStr(6)<>'--confirmar-teste') then
  begin Writeln('Uso: TesteSmtp email.ini empresa usuario conta destinatario --confirmar-teste'); ExitCode:=2; Exit; end;
  C := LerConfig(ParamStr(1));
  if C.ClientLibrary<>'' then InitialiseIBase60(C.ClientLibrary) else InitialiseIBase60;
  B := TEmailBanco.Create(C.Banco,C.Usuario,C.Senha); F := TConfirmacao.Create;
  try
    T := Default(TEmailTrabalho); A := Default(TEmailAnexos);
    T.Empresa := StrToInt(ParamStr(2)); T.Usuario := StrToInt(ParamStr(3)); T.Conta := StrToInt(ParamStr(4));
    T.Destinatario := ParamStr(5);
    T.Assunto := 'Teste AguiaEmail - serviço na VM';
    { O remetente e conferido na conta antes do envio; a configuracao real fica na VM. }
    T.Remetente := GetEnvironmentVariable('AGUIA_TESTE_REMETENTE');
    B.Conta(T);
    CreateGUID(G); T.Chave := Copy(GUIDToString(G),2,36);
    T.Assunto := 'Teste AguiaEmail - serviço na VM';
    T.Texto := 'Olá.'+#13#10+#13#10+
      'Mensagem de teste do serviço AguiaEmail em Lazarus.'+#13#10+
      'Envio direto da VM com TLS. Sem notas fiscais nem dados de clientes.'+#13#10+#13#10+
      'Águia Gestão Empresarial';
    Enviar(T,A,C,F.Antes,Enviando);
    Writeln('SMTP aceitou a mensagem de teste. Message-ID: '+IdMensagem(T));
  finally F.Free; B.Free; ReleaseIBase60; end;
end.
