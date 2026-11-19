program AguiaEmail;
{$mode delphi}{$H+}
uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, Math, ibase60dyn, Servico.Host, Email.Config, Email.Regras, Email.Banco, Email.Smtp;
const NOME_SERVICO = 'ServiceEmailAguia';
var Parar: Boolean = False; Arquivo: string; UmaVez, SomenteConferir: Boolean;
{$IFDEF UNIX}
procedure Sinal(N: CInt); cdecl;
begin Parar := True; end;
{$ENDIF}
procedure Log(const Texto: string);
begin LogEscrever(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ' ' + Texto); end;
procedure Trabalhar;
var C: TEmailConfig; B: TEmailBanco; T: TEmailTrabalho; A: TEmailAnexos;
  N, I: Integer; Enviando: Boolean; ProximoPulso: QWord; Motivo: string;
begin
  try C := LerConfig(Arquivo); except on E: Exception do begin Log(E.Message); ExitCode := 3; Exit; end; end;
  if C.ClientLibrary <> '' then InitialiseIBase60(C.ClientLibrary) else InitialiseIBase60;
  B := nil; ProximoPulso := 0;
  try
    repeat
      try
        if B = nil then begin B := TEmailBanco.Create(C.Banco,C.Usuario,C.Senha); Log('conectado ao banco'); end;
        if SomenteConferir then begin B.Pulso; Log('estrutura e conexao conferidas; nenhum envio executado'); Break; end;
        if GetTickCount64 >= ProximoPulso then
        begin B.Pulso; B.Recuperar; ProximoPulso := GetTickCount64 + 30000; end;
        for N := 1 to C.Limite do
        begin
          if Parar or not B.Pegar(T) then Break;
          B.Pulso;
          Enviando := False;
          try
            if not B.Documentos(T,A) then begin B.Aguardar(T); Continue; end;
            B.Conta(T);
            if T.Numero <> '' then
            begin
              T.Assunto := StringReplace(T.Assunto,'{numero}',T.Numero,[rfReplaceAll]);
              T.Texto := StringReplace(T.Texto,'{numero}',T.Numero,[rfReplaceAll]);
              T.Html := StringReplace(T.Html,'{numero}',T.Numero,[rfReplaceAll]);
            end;
            Enviar(T,A,C,B.MarcarEnviando,Enviando);
            B.Terminar(T,'sent','O servidor de e-mail aceitou a mensagem. Isso nao confirma a entrega na caixa de entrada.',IdMensagem(T));
            Log('email=' + IntToStr(T.Id) + ' aceito pelo SMTP');
          except
            on E: Exception do
            begin
              if Enviando then Motivo := 'Envio sem confirmacao. Confira com o destinatario antes de reenviar.'
              else if E is EEmail then Motivo := E.Message
              else Motivo := 'Falha na preparacao. Confira a configuracao e os documentos.';
              if Enviando then B.Terminar(T,'unknown',Motivo,IdMensagem(T))
              else B.Terminar(T,'failed',Motivo,'');
              Log('email=' + IntToStr(T.Id) + ' ' + Motivo);
            end;
          end;
        end;
      except
        on E: Exception do
        begin
          { Excecoes de banco e bibliotecas podem conter dados de conexao. }
          Log('conexao ou estrutura indisponivel; nova tentativa em instantes');
          FreeAndNil(B);
          if UmaVez or SomenteConferir then begin ExitCode := 1; Break; end;
        end;
      end;
      if UmaVez then Break;
      for I := 1 to C.Intervalo*4 do begin if Parar then Break; Sleep(250); end;
    until Parar;
  finally B.Free; ReleaseIBase60; end;
end;
var Codigo, K: Integer;
begin
  SetMultiByteConversionCodePage(CP_UTF8);
  SetExceptionMask([exInvalidOp,exDenormalized,exZeroDivide,exOverflow,exUnderflow,exPrecision]);
  PrepararAmbiente;
  if ComandoServico(NOME_SERVICO,'Aguia Email','Fila SMTP local do Aguia',Codigo) then begin ExitCode := Codigo; Exit; end;
  Arquivo := ArgumentoIni; if Arquivo = '' then Arquivo := ExtractFilePath(ExpandFileName(ParamStr(0)))+'email.ini';
  UmaVez := False; SomenteConferir := False;
  for K := 1 to ParamCount do
  begin
    if ParamStr(K) = '--uma-vez' then UmaVez := True;
    if ParamStr(K) = '--verificar' then SomenteConferir := True;
  end;
  LogConfigurar(Arquivo,'email');
  {$IFDEF UNIX}FpSignal(SIGTERM,@Sinal); FpSignal(SIGINT,@Sinal);{$ENDIF}
  Rodar(NOME_SERVICO,Trabalhar,@Parar);
end.
