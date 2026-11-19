unit Email.Banco;
{$mode delphi}{$H+}
interface
uses SysUtils, Classes, DB, SQLDB, IBConnection, Email.Regras;
type
  TEmailBanco = class
  private
    C: TIBConnection;
    Tx: TSQLTransaction;
    function Q(const SQL: string): TSQLQuery;
    procedure Iniciar;
  public
    constructor Create(const Banco, Usuario, Senha: string);
    destructor Destroy; override;
    procedure Pulso;
    procedure Recuperar;
    function Pegar(out T: TEmailTrabalho): Boolean;
    function Documentos(var T: TEmailTrabalho; out A: TEmailAnexos): Boolean;
    procedure Conta(var T: TEmailTrabalho);
    function MarcarEnviando(const T: TEmailTrabalho): Boolean;
    procedure Terminar(const T: TEmailTrabalho; const Situacao, Mensagem, MessageId: string);
    procedure Aguardar(const T: TEmailTrabalho);
  end;
implementation
uses Base64;
constructor TEmailBanco.Create(const Banco, Usuario, Senha: string);
var P: Integer;
begin
  inherited Create;
  C := TIBConnection.Create(nil); Tx := TSQLTransaction.Create(nil);
  Tx.DataBase := C; C.Transaction := Tx;
  Tx.Params.Add('isc_tpb_read_committed'); Tx.Params.Add('isc_tpb_rec_version'); Tx.Params.Add('isc_tpb_nowait');
  P := Pos(':', Banco);
  if (P > 0) and (P <> 2) then
  begin C.HostName := Copy(Banco, 1, P - 1); C.DatabaseName := Copy(Banco, P + 1, MaxInt); end
  else C.DatabaseName := Banco;
  C.UserName := Usuario; C.Password := Senha; C.CharSet := 'UTF8'; C.LoginPrompt := False; C.Open;
end;
destructor TEmailBanco.Destroy;
begin
  try if Tx.Active then Tx.Rollback; except end;
  Tx.Free; C.Free; inherited;
end;
function TEmailBanco.Q(const SQL: string): TSQLQuery;
begin
  Result := TSQLQuery.Create(nil); Result.DataBase := C; Result.Transaction := Tx; Result.SQL.Text := SQL;
end;
procedure TEmailBanco.Iniciar;
begin
  if Tx.Active then Tx.Rollback;
  Tx.StartTransaction;
end;
procedure TEmailBanco.Pulso;
var R: TSQLQuery;
begin
  Iniciar;
  R := Q('UPDATE OR INSERT INTO EMAIL_SERVICO (INTERNAL_COD,VERSAO,ATUALIZADO_EM) VALUES (1,''1.0'',CURRENT_TIMESTAMP) MATCHING(INTERNAL_COD)');
  try R.ExecSQL; Tx.Commit; finally R.Free; end;
end;
procedure TEmailBanco.Recuperar;
var R: TSQLQuery;
begin
  Iniciar;
  R := Q('UPDATE EMAIL_ENVIO SET SITUACAO = ''unknown'', ATIVO = NULL, MENSAGEM = ''Processamento interrompido durante o envio. Confira antes de reenviar.'', ' +
    'ATUALIZADO_EM = CURRENT_TIMESTAMP WHERE SITUACAO = ''sending'' AND ATUALIZADO_EM < DATEADD(-10 MINUTE TO CURRENT_TIMESTAMP)');
  try R.ExecSQL; finally R.Free; end;
  R := Q('UPDATE EMAIL_ENVIO SET SITUACAO = ''pending'', PROCESSADOR = NULL, ATUALIZADO_EM = CURRENT_TIMESTAMP ' +
    'WHERE SITUACAO = ''preparing'' AND ATUALIZADO_EM < DATEADD(-10 MINUTE TO CURRENT_TIMESTAMP)');
  try R.ExecSQL; Tx.Commit; finally R.Free; end;
end;
function TEmailBanco.Pegar(out T: TEmailTrabalho): Boolean;
var R: TSQLQuery; G: TGUID;
begin
  T := Default(TEmailTrabalho); Result := False; Iniciar;
  R := Q('SELECT FIRST 1 INTERNAL_COD FROM EMAIL_ENVIO WHERE SITUACAO = ''pending'' ' +
    'AND PROXIMA_TENTATIVA <= CURRENT_TIMESTAMP ORDER BY PROXIMA_TENTATIVA, INTERNAL_COD');
  try
    R.Open; if R.Eof then begin Tx.Commit; Exit; end;
    T.Id := R.Fields[0].AsLargeInt;
  finally R.Free; end;
  CreateGUID(G); T.Dono := GUIDToString(G);
  R := Q('UPDATE EMAIL_ENVIO SET SITUACAO = ''preparing'', PROCESSADOR = :P, ATUALIZADO_EM = CURRENT_TIMESTAMP ' +
    'WHERE INTERNAL_COD = :ID AND SITUACAO = ''pending''');
  try
    R.ParamByName('ID').AsLargeInt := T.Id; R.ParamByName('P').AsString := T.Dono;
    try
      R.ExecSQL; Result := R.RowsAffected = 1;
    except
      on E: ESQLDatabaseError do
      begin
        Tx.Rollback;
        if E.SQLState='40001' then Exit(False);
        raise;
      end;
    end;
    Tx.Commit;
  finally R.Free; end;
  if not Result then Exit;
  Iniciar;
  R := Q('SELECT * FROM EMAIL_ENVIO WHERE INTERNAL_COD = :ID');
  try
    R.ParamByName('ID').AsLargeInt := T.Id; R.Open;
    T.Empresa := R.FieldByName('COD_EMPRESA').AsInteger; T.Usuario := R.FieldByName('COD_USUARIO').AsInteger;
    T.Conta := R.FieldByName('COD_EMAIL').AsInteger; T.Tipo := R.FieldByName('TIPO').AsString;
    T.Origem := R.FieldByName('ORIGEM_ID').AsLargeInt; T.Documento := R.FieldByName('DOCUMENTO_ID').AsLargeInt;
    T.Chave := R.FieldByName('CHAVE').AsString; T.Remetente := R.FieldByName('REMETENTE').AsString;
    T.Destinatario := R.FieldByName('DESTINATARIO').AsString; T.Assunto := R.FieldByName('ASSUNTO').AsString;
    T.Texto := R.FieldByName('CORPO_TEXTO').AsString; T.Html := R.FieldByName('CORPO_HTML').AsString;
    T.Xml := R.FieldByName('XML_FISCAL').AsString; T.Criado := R.FieldByName('CRIADO_EM').AsDateTime;
    R.Close; Tx.Commit;
  finally R.Free; end;
end;
procedure TEmailBanco.Conta(var T: TEmailTrabalho);
var R: TSQLQuery;
begin
  Iniciar;
  R := Q('SELECT FIRST 1 E.* FROM EMAIL_CONTA E JOIN EMAIL_CONTA_USUARIO U ON U.COD_EMAIL=E.INTERNAL_COD ' +
    'JOIN UCTABUSERS S ON S.UCIDUSER=U.COD_USUARIO WHERE E.INTERNAL_COD=:C AND U.COD_USUARIO=:U ' +
    'AND COALESCE(S.UCINATIVE,0)=0 ORDER BY CASE WHEN U.COD_EMPRESA=:E THEN 0 ELSE 1 END');
  try
    R.ParamByName('C').AsInteger := T.Conta; R.ParamByName('U').AsInteger := T.Usuario; R.ParamByName('E').AsInteger := T.Empresa;
    R.Open;
    if R.Eof or (Trim(R.FieldByName('EMAIL').AsString) <> T.Remetente) then raise EEmail.Create('A conta de envio ou o usuario mudou. Prepare outro envio.');
    T.Host := Trim(R.FieldByName('SMTP').AsString); T.Porta := R.FieldByName('PORTA').AsInteger;
    T.Login := R.FieldByName('USER_NAME').AsString; if T.Login = '' then T.Login := T.Remetente;
    T.Senha := DecodeStringBase64(R.FieldByName('SENHA').AsString, True);
    T.SSL := R.FieldByName('CONEXAO_SEGURA').AsInteger = 1; T.TLS := R.FieldByName('USER_TLS').AsInteger = 1;
    T.Nome := R.FieldByName('NOME_EXIBICAO').AsString;
    if R.FindField('REPLAY_TO') <> nil then T.ReplyTo := R.FieldByName('REPLAY_TO').AsString else T.ReplyTo := '';
    R.Close; Tx.Commit;
  finally R.Free; end;
  ConferirTrabalho(T);
end;
function TEmailBanco.Documentos(var T: TEmailTrabalho; out A: TEmailAnexos): Boolean;
var R, W: TSQLQuery; P: TBlobField; S: TMemoryStream; X: string; Status: Integer;
begin
  Result := False; A := Default(TEmailAnexos); Iniciar;
  if T.Tipo = 'nfse' then
    R := Q('SELECT N.STATUS,N.NUMERO,N.XML,COALESCE(E.DANFSE,D.PDF) AS PDF FROM NFSE N ' +
      'LEFT JOIN NFSE_EMISSAO E ON E.ID_NFSE=N.ID_NFSE LEFT JOIN NFSE_DANFSE D ON D.ID_NFSE=N.ID_NFSE ' +
      'WHERE N.ID_NFSE=:ID AND N.ID_PRESTADOR=:E')
  else
    R := Q('SELECT B.SITUACAO AS STATUS, B.PDF FROM BOLETO_EMISSAO B JOIN CONTARECEBER R ON R.INTERNAL_COD=B.COD_CONTAREC ' +
      'WHERE B.INTERNAL_COD=:ID AND B.COD_EMPRESA=:E AND B.COD_USUARIO=:U AND R.COD_EMPRESA=:E ' +
      'AND R.SALDO>0 AND COALESCE(R.BANCO_BAIXADO,0)=0 AND R.COD_CONTACORRENTE=B.COD_CONTACORRENTE');
  try
    R.ParamByName('ID').AsLargeInt := T.Origem; R.ParamByName('E').AsInteger := T.Empresa;
    if T.Tipo = 'boleto' then R.ParamByName('U').AsInteger := T.Usuario;
    R.Open;
    if R.Eof then raise EEmail.Create('Documento indisponivel para envio nesta empresa e usuario.');
    Status := R.FieldByName('STATUS').AsInteger;
    if Status = 3 then raise EEmail.Create('Documento cancelado ou emissao rejeitada.');
    if Status <> 2 then
    begin
      R.Close; Tx.Commit; Exit;
    end;
    if T.Tipo = 'nfse' then
    begin
      X := R.FieldByName('XML').AsString;
      if Trim(X) = '' then raise EEmail.Create('A nota autorizada esta sem XML.');
      if (T.Xml <> '') and (X <> T.Xml) then raise EEmail.Create('O XML da nota mudou apos a confirmacao. Prepare outro envio.');
      T.Xml := X; T.Numero := R.FieldByName('NUMERO').AsString; A.Xml := X;
    end;
    if not R.FieldByName('PDF').IsNull then
    begin
      P := R.FieldByName('PDF') as TBlobField;
      if P.BlobSize > 20000000 then raise EEmail.Create('PDF acima do limite de 20 MB.');
      S := TMemoryStream.Create;
      try
        P.SaveToStream(S); SetLength(A.Pdf, S.Size); S.Position := 0;
        if S.Size > 0 then S.ReadBuffer(A.Pdf[0], S.Size);
      finally S.Free; end;
      if (Length(A.Pdf) < 5) or (A.Pdf[0] <> Ord('%')) or (A.Pdf[1] <> Ord('P')) or
        (A.Pdf[2] <> Ord('D')) or (A.Pdf[3] <> Ord('F')) or (A.Pdf[4] <> Ord('-')) then raise EEmail.Create('PDF invalido.');
      if Length(A.Xml) > 10000000 then raise EEmail.Create('XML acima do limite de 10 MB.');
      Result := True;
    end;
    R.Close;
    if (T.Tipo = 'nfse') and not Result then
    begin
      W := Q('SELECT DOCUMENTO_PEDIDO FROM EMAIL_ENVIO WHERE INTERNAL_COD=:ID');
      try
        W.ParamByName('ID').AsLargeInt := T.Id; W.Open;
        Status := W.Fields[0].AsInteger;
      finally W.Free; end;
      if Status = 0 then
      begin
        W := Q('INSERT INTO NFSE_FILA (INTERNAL_COD,ID_NFSE,COD_EMPRESA,ACAO) ' +
          'SELECT GEN_ID(GEN_NFSE_FILA_ID,1),:ID,:E,4 FROM RDB$DATABASE WHERE NOT EXISTS ' +
          '(SELECT 1 FROM NFSE_FILA WHERE ID_NFSE=:ID AND COD_EMPRESA=:E AND SITUACAO IN (0,1))');
        try W.ParamByName('ID').AsLargeInt := T.Origem; W.ParamByName('E').AsInteger := T.Empresa; W.ExecSQL; finally W.Free; end;
        W := Q('UPDATE EMAIL_ENVIO SET DOCUMENTO_PEDIDO=1 WHERE INTERNAL_COD=:ID');
        try W.ParamByName('ID').AsLargeInt := T.Id; W.ExecSQL; finally W.Free; end;
      end;
    end;
    Tx.Commit;
  finally R.Free; end;
end;
function TEmailBanco.MarcarEnviando(const T: TEmailTrabalho): Boolean;
var R: TSQLQuery;
begin
  Iniciar;
  { Uma conexao SMTP pode demorar: rele o documento imediatamente antes do DATA. }
  if T.Tipo='nfse' then
    R := Q('SELECT STATUS,XML FROM NFSE WHERE ID_NFSE=:N AND ID_PRESTADOR=:E WITH LOCK')
  else
    R := Q('SELECT SALDO,BANCO_BAIXADO FROM CONTARECEBER WHERE INTERNAL_COD=:N AND COD_EMPRESA=:E WITH LOCK');
  try
    R.ParamByName('N').AsLargeInt := T.Documento; R.ParamByName('E').AsInteger := T.Empresa; R.Open;
    if R.Eof then raise EEmail.Create('Documento indisponivel antes do envio.');
    if T.Tipo='nfse' then
    begin
      if (R.FieldByName('STATUS').AsInteger<>2) or (R.FieldByName('XML').AsString<>T.Xml) then
        raise EEmail.Create('A nota mudou antes do envio. Prepare outra solicitacao.');
    end
    else if (R.FieldByName('SALDO').AsCurrency<=0) or (R.FieldByName('BANCO_BAIXADO').AsInteger=1) then
      raise EEmail.Create('O titulo foi baixado antes do envio.');
  finally R.Free; end;
  R := Q('UPDATE EMAIL_ENVIO SET SITUACAO=''sending'', MESSAGE_ID=:M, XML_FISCAL=:X, ATUALIZADO_EM=CURRENT_TIMESTAMP ' +
    'WHERE INTERNAL_COD=:ID AND SITUACAO=''preparing'' AND PROCESSADOR=:P');
  try
    R.ParamByName('ID').AsLargeInt := T.Id; R.ParamByName('P').AsString := T.Dono;
    R.ParamByName('M').AsString := IdMensagem(T); R.ParamByName('X').AsMemo := T.Xml;
    R.ExecSQL; Result := R.RowsAffected = 1; Tx.Commit;
  finally R.Free; end;
end;
procedure TEmailBanco.Terminar(const T: TEmailTrabalho; const Situacao, Mensagem, MessageId: string);
var R: TSQLQuery;
begin
  Iniciar;
  R := Q('UPDATE EMAIL_ENVIO SET SITUACAO=:S, MENSAGEM=:M, MESSAGE_ID=:MID, ATIVO=NULL, ATUALIZADO_EM=CURRENT_TIMESTAMP ' +
    'WHERE INTERNAL_COD=:ID AND PROCESSADOR=:P AND SITUACAO IN (''preparing'',''sending'')');
  try
    R.ParamByName('ID').AsLargeInt := T.Id; R.ParamByName('P').AsString := T.Dono;
    R.ParamByName('S').AsString := Situacao; R.ParamByName('M').AsString := Copy(Mensagem,1,900);
    R.ParamByName('MID').AsString := MessageId; R.ExecSQL;
    if (R.RowsAffected = 1) and (Situacao = 'sent') then
    begin
      R.Close;
      if T.Tipo = 'nfse' then R.SQL.Text := 'UPDATE NFSE SET EMAIL_ENVIADO=1 WHERE ID_NFSE=:N AND ID_PRESTADOR=:E'
      else R.SQL.Text := 'UPDATE CONTARECEBER SET EMAIL_ENVIADO=1 WHERE INTERNAL_COD=:N AND COD_EMPRESA=:E';
      R.ParamByName('N').AsLargeInt := T.Documento; R.ParamByName('E').AsInteger := T.Empresa; R.ExecSQL;
    end;
    Tx.Commit;
  finally R.Free; end;
end;
procedure TEmailBanco.Aguardar(const T: TEmailTrabalho);
var R: TSQLQuery;
begin
  if Now-T.Criado > 2/24 then
  begin Terminar(T,'failed','Os documentos nao ficaram disponiveis em duas horas. Confira a emissao.',''); Exit; end;
  Iniciar;
  R := Q('UPDATE EMAIL_ENVIO SET SITUACAO=''pending'', MENSAGEM=''Aguardando autorizacao ou documentos na VM.'', ' +
    'PROXIMA_TENTATIVA=DATEADD(15 SECOND TO CURRENT_TIMESTAMP),ATUALIZADO_EM=CURRENT_TIMESTAMP ' +
    'WHERE INTERNAL_COD=:ID AND SITUACAO=''preparing'' AND PROCESSADOR=:P');
  try R.ParamByName('ID').AsLargeInt := T.Id; R.ParamByName('P').AsString := T.Dono; R.ExecSQL; Tx.Commit; finally R.Free; end;
end;
end.
