unit Email.Smtp;
{$mode delphi}{$H+}
interface
uses Classes, SysUtils, Email.Regras, Email.Config;
type
  TAntesDosDados = function(const T: TEmailTrabalho): Boolean of object;
procedure Enviar(const T: TEmailTrabalho; const A: TEmailAnexos; const C: TEmailConfig;
  AntesDosDados: TAntesDosDados; out Enviando: Boolean);
implementation
uses smtpsend, ssl_openssl3, blcksock, synacode, synautil;

procedure CabecalhoUtf8(L: TStrings; const Nome, Valor: string);
var P, N: Integer; Prefixo: string;
begin
  P := 1; Prefixo := Nome + ': ';
  repeat
    N := Length(Valor)-P+1; if N>45 then N := 45;
    { Cada encoded-word termina num caractere UTF-8 completo. }
    while (N>0) and (P+N<=Length(Valor)) and ((Ord(Valor[P+N]) and $C0)=$80) do Dec(N);
    if N=0 then raise EEmail.Create('Cabecalho UTF-8 invalido.');
    L.Add(Prefixo+'=?UTF-8?B?'+EncodeBase64(Copy(Valor,P,N))+'?=');
    Prefixo := ' '; Inc(P,N);
  until P>Length(Valor);
end;
procedure Parte(L: TStrings; const Limite, Tipo, Nome, Dados: string);
var P: Integer;
begin
  L.Add('--'+Limite); L.Add('Content-Type: '+Tipo);
  if Nome<>'' then L.Add('Content-Disposition: attachment; filename="'+Nome+'"');
  L.Add('Content-Transfer-Encoding: base64'); L.Add(''); P := 1;
  while P<=Length(Dados) do
  begin L.Add(EncodeBase64(Copy(Dados,P,57))); Inc(P,57); end;
  L.Add('');
end;
procedure Montar(L: TStrings; const T: TEmailTrabalho; const A: TEmailAnexos);
var G: TGUID; Limite, Alternativa, Pdf: string;
begin
  CreateGUID(G); Limite := 'aguia'+StringReplace(Copy(GUIDToString(G),2,36),'-','',[rfReplaceAll]);
  Alternativa := Limite+'alt';
  if T.Nome<>'' then begin CabecalhoUtf8(L,'From',T.Nome); L.Add(' <'+T.Remetente+'>'); end
  else L.Add('From: '+T.Remetente);
  L.Add('To: '+T.Destinatario);
  if T.ReplyTo<>'' then L.Add('Reply-To: '+T.ReplyTo);
  CabecalhoUtf8(L,'Subject',T.Assunto);
  L.Add('Date: '+Rfc822DateTime(Now)); L.Add('Message-ID: '+IdMensagem(T));
  L.Add('MIME-Version: 1.0'); L.Add('X-Mailer: AguiaEmail/1.0');
  L.Add('Content-Type: multipart/mixed; boundary="'+Limite+'"'); L.Add('');
  L.Add('--'+Limite); L.Add('Content-Type: multipart/alternative; boundary="'+Alternativa+'"'); L.Add('');
  Parte(L,Alternativa,'text/plain; charset=UTF-8','',T.Texto);
  if T.Html<>'' then Parte(L,Alternativa,'text/html; charset=UTF-8','',T.Html);
  L.Add('--'+Alternativa+'--'); L.Add('');
  Pdf := ''; if Length(A.Pdf)>0 then SetString(Pdf,PAnsiChar(@A.Pdf[0]),Length(A.Pdf));
  if Pdf<>'' then
  begin
    if T.Tipo='nfse' then Parte(L,Limite,'application/pdf','danfse.pdf',Pdf)
    else Parte(L,Limite,'application/pdf','boleto-'+IntToStr(T.Documento)+'.pdf',Pdf);
  end;
  if A.Xml<>'' then Parte(L,Limite,'application/xml; charset=UTF-8','nfse.xml',A.Xml);
  L.Add('--'+Limite+'--');
end;

procedure Enviar(const T: TEmailTrabalho; const A: TEmailAnexos; const C: TEmailConfig;
  AntesDosDados: TAntesDosDados; out Enviando: Boolean);
var SMTP: TSMTPSend; Linhas: TStringList; Resposta: string;
begin
  Enviando := False; ConferirTrabalho(T);
  SMTP := TSMTPSend.Create; Linhas := TStringList.Create;
  try
    Montar(Linhas,T,A);
    SMTP.TargetHost := T.Host; SMTP.TargetPort := IntToStr(T.Porta);
    SMTP.Timeout := C.Timeout; SMTP.Sock.ConnectionTimeout := C.Timeout;
    SMTP.FullSSL := T.SSL; SMTP.AutoTLS := not T.SSL;
    SMTP.Sock.SSL.VerifyCert := True; SMTP.Sock.SSL.CertCAFile := C.CA;
    SMTP.Sock.SSL.SNIHost := T.Host; SMTP.Sock.SSL.SSLType := LT_TLSv1_2;
    { Nenhuma credencial antes de TLS. AutoTLS aceita servidor sem STARTTLS;
      por isso o estado e o certificado sao conferidos antes do AUTH. }
    if not SMTP.Login or not SMTP.Sock.SSL.SSLEnabled or (SMTP.Sock.SSL.GetVerifyCert<>0) then
      raise EEmail.Create('Nao foi possivel estabelecer uma conexao SMTP com TLS e certificado valido.');
    SMTP.Sock.SendString('AUTH PLAIN '+EncodeBase64(#0+T.Login+#0+T.Senha)+#13#10);
    Resposta := SMTP.Sock.RecvString(C.Timeout);
    if Copy(Resposta,1,3)<>'235' then raise EEmail.Create('O provedor recusou a autenticacao SMTP. Confira a conta no Aguia.');
    if not SMTP.MailFrom(T.Remetente,0) then raise EEmail.Create('O provedor recusou o remetente.');
    if not SMTP.MailTo(T.Destinatario) then raise EEmail.Create('O provedor recusou o destinatario.');
    if not AntesDosDados(T) then raise EEmail.Create('O trabalho mudou de processador; envio interrompido.');
    Enviando := True;
    if not SMTP.MailData(Linhas) then
    begin
      if (SMTP.Sock.LastError=0) and (SMTP.ResultCode>=400) and (SMTP.ResultCode<=599) then
      begin Enviando := False; raise EEmail.Create('O provedor recusou a mensagem (SMTP '+IntToStr(SMTP.ResultCode)+').'); end;
      raise EEmail.Create('Sem confirmacao do servidor SMTP. Confira antes de reenviar.');
    end;
    { Aceite ao DATA e definitivo; uma falha no QUIT nao provoca reenvio. }
    try SMTP.Logout; except end;
  finally Linhas.Free; SMTP.Free; end;
end;
end.
