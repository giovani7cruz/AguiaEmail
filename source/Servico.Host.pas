unit Servico.Host;

{ Como o processo roda: console (Windows/Linux), systemd (Linux) ou serviço
  do Windows. O laço de trabalho é o mesmo nos três: roda na thread principal
  e termina quando Parar^ fica True (SIGTERM no Linux, tratado no programa;
  Ctrl+C no console do Windows; "sc stop" ou desligamento no serviço).
  Mesma unit no EmissorDFe (AguiaFiscal) e no AguiaBoletos: mudou num, copie.

  Linha de comando, só no Windows (o instalador usa as três primeiras):
    --instalar-servico [arquivo.ini]  cria ou atualiza o serviço: conta
                                      LocalSystem, início automático atrasado,
                                      reinício em 15 s quando cair
    --remover-servico                 para (esperando terminar) e remove
    --parar-servico                   para e espera terminar
    --servico [arquivo.ini]           como o SCM chama o programa

  Log: Log() vai para a saída padrão (fora do serviço) e, com pasta definida,
  para um arquivo por dia (<prefixo>-AAAA-MM-DD.log, apagados depois de
  [LOG] Dias, padrão 30). Pasta: [LOG] Pasta do ini (relativa = ao lado do
  ini); no serviço do Windows, sem ela, Logs\ ao lado do exe (não há journal). }

{$IFDEF FPC}{$mode delphi}{$ENDIF}
{$PACKRECORDS C}

interface

uses
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  SysUtils, Classes, IniFiles;

type
  TTrabalho = procedure;

var
  { True quando o programa foi chamado pelo SCM (--servico). }
  ModoServico: Boolean = False;

{ Lê a pasta e a retenção do log do [LOG] do ini (se existir). }
procedure LogConfigurar(const AArquivoIni, APrefixo: string);
{ Escreve a linha (já com data/hora) na saída padrão e/ou no arquivo do dia. }
procedure LogEscrever(const ALinha: string);

{ Serviço do Windows: pasta atual = a do exe (o SCM começa em System32).
  OpenSSL: no Windows o ACBr já carrega o legacy.dll da pasta das DLLs (PFX
  RC2/3DES abre sem OPENSSL_CONF); no Linux o systemd define OPENSSL_CONF. }
procedure PrepararAmbiente;

{ Trata --instalar-servico/--remover-servico/--parar-servico. True = era um
  desses (o programa sai com ACodigo); False = seguir normalmente. }
function ComandoServico(const ANome, AExibicao, ADescricao: string; out ACodigo: Integer): Boolean;

{ Roda ATrabalho: direto no console; sob o SCM com --servico. No serviço o
  pedido de parada liga AParar^ e o SCM é avisado até ATrabalho voltar; o
  ExitCode no fim vira o código de saída do serviço (<> 0 = falha, reinicia). }
procedure Rodar(const ANome: string; ATrabalho: TTrabalho; AParar: PBoolean);

{ Argumento que não é opção (--algo): o arquivo .ini, ou '' se não veio. }
function ArgumentoIni: string;

implementation

var
  LogPasta, LogPrefixo, LogArquivoAtual: string;
  LogDias: Integer = 30;
  LogTrava: TRTLCriticalSection;

function ArgumentoIni: string;
var
  K: Integer;
begin
  Result := '';
  for K := 1 to ParamCount do
    if Copy(ParamStr(K), 1, 2) <> '--' then
      Result := ParamStr(K);
end;

function PastaDoExe: string;
begin
  Result := ExtractFilePath(ExpandFileName(ParamStr(0)));
end;

procedure LogConfigurar(const AArquivoIni, APrefixo: string);
var
  Ini: TIniFile;
  Pasta: string;
begin
  LogPrefixo := APrefixo;
  Pasta := '';
  if FileExists(AArquivoIni) then
  begin
    Ini := TIniFile.Create(AArquivoIni);
    try
      Pasta := Trim(Ini.ReadString('LOG', 'Pasta', ''));
      LogDias := Ini.ReadInteger('LOG', 'Dias', 30);
    finally
      Ini.Free;
    end;
    if (Pasta <> '') and (ExtractFileDrive(Pasta) = '') and (Pasta[1] <> PathDelim) then
      Pasta := ExtractFilePath(ExpandFileName(AArquivoIni)) + Pasta;
  end;
  if (Pasta = '') and ModoServico then
    Pasta := PastaDoExe + 'Logs';
  if LogDias < 1 then LogDias := 1;
  if Pasta <> '' then
  begin
    Pasta := IncludeTrailingPathDelimiter(ExpandFileName(Pasta));
    if not ForceDirectories(Pasta) then Pasta := '';
  end;
  LogPasta := Pasta;
  LogArquivoAtual := '';
end;

{ Arquivos <prefixo>-AAAA-MM-DD.log com mais de LogDias dias. }
procedure ApagarLogsAntigos;
var
  R: TSearchRec;
  Data: TDateTime;
  S: string;
begin
  if FindFirst(LogPasta + LogPrefixo + '-*.log', faAnyFile, R) = 0 then
  begin
    repeat
      S := Copy(R.Name, Length(LogPrefixo) + 2, 10);
      if (Length(S) = 10) and TryEncodeDate(StrToIntDef(Copy(S, 1, 4), 0), StrToIntDef(Copy(S, 6, 2), 0),
        StrToIntDef(Copy(S, 9, 2), 0), Data) and (Data < Date - LogDias) then
        DeleteFile(LogPasta + R.Name);
    until FindNext(R) <> 0;
    FindClose(R);
  end;
end;

procedure LogEscrever(const ALinha: string);
var
  Arq: string;
  F: TFileStream;
  Bytes: RawByteString;
begin
  if not ModoServico then
  begin
    Writeln(ALinha);
    Flush(Output);
  end;
  if LogPasta = '' then Exit;
  EnterCriticalSection(LogTrava);
  try
    try
      Arq := LogPasta + LogPrefixo + '-' + FormatDateTime('yyyy"-"mm"-"dd', Now) + '.log';
      if Arq <> LogArquivoAtual then
      begin
        LogArquivoAtual := Arq;
        ApagarLogsAntigos;
      end;
      if FileExists(Arq) then
        F := TFileStream.Create(Arq, fmOpenWrite or fmShareDenyWrite)
      else
        F := TFileStream.Create(Arq, fmCreate or fmShareDenyWrite);
      try
        F.Seek(0, soEnd);
        Bytes := UTF8Encode(UnicodeString(ALinha)) + #13#10;
        F.WriteBuffer(Bytes[1], Length(Bytes));
      finally
        F.Free;
      end;
    except
      // log nunca derruba o serviço (disco cheio, arquivo aberto exclusivo...)
    end;
  finally
    LeaveCriticalSection(LogTrava);
  end;
end;

procedure LogHora(const ATexto: string);
begin
  LogEscrever(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ' ' + ATexto);
end;

{$IFDEF MSWINDOWS}
{ ---- API do SCM (declarada aqui: o Windows do FPC não traz todas) ---- }
type
  SERVICE_STATUS_HANDLE = THandle;
  TServiceStatusW = record
    dwServiceType, dwCurrentState, dwControlsAccepted, dwWin32ExitCode,
    dwServiceSpecificExitCode, dwCheckPoint, dwWaitHint: DWORD;
  end;
  TServiceMainW = procedure(AArgc: DWORD; AArgv: PPWideChar); stdcall;
  TServiceTableEntryW = record
    lpServiceName: PWideChar;
    lpServiceProc: TServiceMainW;
  end;
  THandlerEx = function(AControle, ATipoEvento: DWORD; ADados, AContexto: Pointer): DWORD; stdcall;
  TScAction = record
    Tipo, Atraso: DWORD;
  end;
  TServiceFailureActionsW = record
    dwResetPeriod: DWORD;
    lpRebootMsg, lpCommand: PWideChar;
    cActions: DWORD;
    lpsaActions: Pointer;
  end;
  TServiceDescriptionW = record
    lpDescription: PWideChar;
  end;
  TDwordInfo = record
    Valor: DWORD;   // DELAYED_AUTO_START (BOOL), FAILURE_ACTIONS_FLAG (BOOL), PRESHUTDOWN (ms)
  end;

const
  SERVICE_WIN32_OWN_PROCESS = $10;
  SERVICE_AUTO_START = 2;
  SERVICE_ERROR_NORMAL = 1;
  SERVICE_NO_CHANGE = $FFFFFFFF;
  SERVICE_STOPPED = 1;
  SERVICE_START_PENDING = 2;
  SERVICE_STOP_PENDING = 3;
  SERVICE_RUNNING = 4;
  SERVICE_ACCEPT_STOP = 1;
  SERVICE_ACCEPT_PRESHUTDOWN = $100;
  SERVICE_CONTROL_STOP = 1;
  SERVICE_CONTROL_INTERROGATE = 4;
  SERVICE_CONTROL_PRESHUTDOWN = $F;
  SC_MANAGER_CONNECT = 1;
  SC_MANAGER_CREATE_SERVICE = 2;
  SERVICE_ALL_ACCESS = $F01FF;
  SERVICE_QUERY_STATUS = 4;
  SERVICE_STOP = $20;
  DELETE_ACESSO = $10000;
  SERVICE_CONFIG_DESCRIPTION = 1;
  SERVICE_CONFIG_FAILURE_ACTIONS = 2;
  SERVICE_CONFIG_DELAYED_AUTO_START_INFO = 3;
  SERVICE_CONFIG_FAILURE_ACTIONS_FLAG = 4;
  SERVICE_CONFIG_PRESHUTDOWN_INFO = 7;
  SC_ACTION_RESTART = 1;
  ERROR_SERVICE_DOES_NOT_EXIST_ = 1060;
  ERROR_SERVICE_NOT_ACTIVE_ = 1062;
  ERROR_SERVICE_SPECIFIC_ERROR_ = 1066;
  ERROR_FAILED_SERVICE_CONTROLLER_CONNECT_ = 1063;

function StartServiceCtrlDispatcherW(ATabela: Pointer): BOOL; stdcall; external 'advapi32.dll';
function RegisterServiceCtrlHandlerExW(ANome: PWideChar; AHandler: THandlerEx; AContexto: Pointer):
  SERVICE_STATUS_HANDLE; stdcall; external 'advapi32.dll';
function SetServiceStatus(AHandle: SERVICE_STATUS_HANDLE; var AStatus: TServiceStatusW): BOOL; stdcall;
  external 'advapi32.dll';
function OpenSCManagerW(AMaquina, ABase: PWideChar; AAcesso: DWORD): SC_HANDLE; stdcall; external 'advapi32.dll';
function OpenServiceW(AScm: SC_HANDLE; ANome: PWideChar; AAcesso: DWORD): SC_HANDLE; stdcall;
  external 'advapi32.dll';
function CreateServiceW(AScm: SC_HANDLE; ANome, AExibicao: PWideChar; AAcesso, ATipo, AInicio, AErro: DWORD;
  ABinario, AGrupo: PWideChar; ATag: Pointer; ADependencias, AConta, ASenha: PWideChar): SC_HANDLE; stdcall;
  external 'advapi32.dll';
function ChangeServiceConfigW(AServico: SC_HANDLE; ATipo, AInicio, AErro: DWORD; ABinario, AGrupo: PWideChar;
  ATag: Pointer; ADependencias, AConta, ASenha, AExibicao: PWideChar): BOOL; stdcall; external 'advapi32.dll';
function ChangeServiceConfig2W(AServico: SC_HANDLE; ANivel: DWORD; AInfo: Pointer): BOOL; stdcall;
  external 'advapi32.dll';
function ControlService(AServico: SC_HANDLE; AControle: DWORD; var AStatus: TServiceStatusW): BOOL; stdcall;
  external 'advapi32.dll';
function QueryServiceStatus(AServico: SC_HANDLE; var AStatus: TServiceStatusW): BOOL; stdcall;
  external 'advapi32.dll';
function DeleteService(AServico: SC_HANDLE): BOOL; stdcall; external 'advapi32.dll';
function CloseServiceHandle(AHandle: SC_HANDLE): BOOL; stdcall; external 'advapi32.dll';

var
  SvcNome: UnicodeString;
  SvcHandle: SERVICE_STATUS_HANDLE;
  SvcStatus: TServiceStatusW;
  SvcTrava: TRTLCriticalSection;
  SvcParar: PBoolean;
  SvcParando: Boolean;
  EvIniciou, EvTerminou: THandle;
  ConsoleParar: PBoolean;

{ Chamado nas threads do SCM: só API do Windows, sem string gerenciada. }
procedure Informar(AEstado, AEspera: DWORD);
begin
  EnterCriticalSection(SvcTrava);
  try
    SvcStatus.dwCurrentState := AEstado;
    SvcStatus.dwWaitHint := AEspera;
    if AEstado in [SERVICE_RUNNING, SERVICE_STOPPED] then
      SvcStatus.dwCheckPoint := 0
    else
      Inc(SvcStatus.dwCheckPoint);
    if AEstado = SERVICE_RUNNING then
      SvcStatus.dwControlsAccepted := SERVICE_ACCEPT_STOP or SERVICE_ACCEPT_PRESHUTDOWN
    else
      SvcStatus.dwControlsAccepted := 0;
    if SvcHandle <> 0 then
      SetServiceStatus(SvcHandle, SvcStatus);
  finally
    LeaveCriticalSection(SvcTrava);
  end;
end;

function Controle(AControle, ATipoEvento: DWORD; ADados, AContexto: Pointer): DWORD; stdcall;
begin
  case AControle of
    SERVICE_CONTROL_STOP, SERVICE_CONTROL_PRESHUTDOWN:
      begin
        SvcParando := True;
        SvcParar^ := True;
        Informar(SERVICE_STOP_PENDING, 15000);
        Result := NO_ERROR;
      end;
    SERVICE_CONTROL_INTERROGATE:
      Result := NO_ERROR;
  else
    Result := ERROR_CALL_NOT_IMPLEMENTED;
  end;
end;

{ Thread criada pelo SCM. O trabalho roda na thread principal (o ACBr e a
  LCL esperam isso); aqui só se avisa o SCM até o trabalho voltar. }
procedure ServicoMain(AArgc: DWORD; AArgv: PPWideChar); stdcall;
begin
  SvcHandle := RegisterServiceCtrlHandlerExW(PWideChar(SvcNome), Controle, nil);
  if SvcHandle = 0 then
  begin
    SetEvent(EvIniciou);
    Exit;
  end;
  SvcStatus.dwServiceType := SERVICE_WIN32_OWN_PROCESS;
  Informar(SERVICE_RUNNING, 0);
  SetEvent(EvIniciou);
  { Parada: a nota/título em andamento termina antes; o checkpoint sobe a
    cada 5 s para o SCM não dar o serviço como travado. }
  while WaitForSingleObject(EvTerminou, 5000) = WAIT_TIMEOUT do
    if SvcParando then
      Informar(SERVICE_STOP_PENDING, 15000);
  Informar(SERVICE_STOPPED, 0);
end;

var
  Tabela: array[0..1] of TServiceTableEntryW;
  DespachoErro: DWORD;

function ThreadDespacho(AParam: Pointer): PtrInt;
begin
  Tabela[0].lpServiceName := PWideChar(SvcNome);
  Tabela[0].lpServiceProc := ServicoMain;
  Tabela[1].lpServiceName := nil;
  Tabela[1].lpServiceProc := nil;
  if StartServiceCtrlDispatcherW(@Tabela[0]) then
    DespachoErro := 0
  else
  begin
    DespachoErro := GetLastError;
    SetEvent(EvIniciou);
  end;
  Result := 0;
end;

function AoCtrlC(ATipo: DWORD): BOOL; stdcall;
begin
  { Ctrl+C, Ctrl+Break, fechar a janela: termina o trabalho atual e sai. }
  if ConsoleParar <> nil then ConsoleParar^ := True;
  Result := True;
end;

procedure Rodar(const ANome: string; ATrabalho: TTrabalho; AParar: PBoolean);
var
  Despacho: TThreadID;
begin
  if not ModoServico then
  begin
    ConsoleParar := AParar;
    SetConsoleCtrlHandler(@AoCtrlC, True);
    ATrabalho;
    Exit;
  end;
  SvcNome := UnicodeString(ANome);
  SvcParar := AParar;
  EvIniciou := CreateEvent(nil, True, False, nil);
  EvTerminou := CreateEvent(nil, True, False, nil);
  Despacho := BeginThread(ThreadDespacho, nil);
  WaitForSingleObject(EvIniciou, INFINITE);
  if SvcHandle = 0 then
  begin
    if DespachoErro = ERROR_FAILED_SERVICE_CONTROLLER_CONNECT_ then
      LogHora('--servico é para o Gerenciador de Serviços; no console rode sem ele')
    else
      LogHora(Format('serviço não registrou no SCM (erro %d)', [DespachoErro]));
    ExitCode := 1;
    Exit;
  end;
  try
    ATrabalho;
  except
    on E: Exception do
    begin
      LogHora('falha fatal: ' + E.ClassName + ': ' + E.Message);
      if ExitCode = 0 then ExitCode := 2;
    end;
  end;
  if ExitCode <> 0 then
  begin
    SvcStatus.dwWin32ExitCode := ERROR_SERVICE_SPECIFIC_ERROR_;
    SvcStatus.dwServiceSpecificExitCode := DWORD(ExitCode);
  end;
  SetEvent(EvTerminou);
  WaitForThreadTerminate(Despacho, 15000);
end;

procedure PrepararAmbiente;
begin
  if ModoServico then
    SetCurrentDir(PastaDoExe);
end;

procedure Escrever(const ATexto: string);
begin
  Writeln(ATexto);
end;

function ErroTexto(ACodigo: DWORD): string;
begin
  Result := Format('%d (%s)', [ACodigo, SysErrorMessage(ACodigo)]);
end;

{ Para o serviço e espera até AEsperaSeg segundos. 0 = parado ou inexistente. }
function PararServico(AScm: SC_HANDLE; const ANome: string; AEsperaSeg: Integer): Integer;
var
  S: SC_HANDLE;
  St: TServiceStatusW;
  K: Integer;
begin
  S := OpenServiceW(AScm, PWideChar(UnicodeString(ANome)), SERVICE_STOP or SERVICE_QUERY_STATUS);
  if S = 0 then
  begin
    if GetLastError = ERROR_SERVICE_DOES_NOT_EXIST_ then Exit(0);
    Escrever('não abriu o serviço ' + ANome + ': ' + ErroTexto(GetLastError));
    Exit(Integer(GetLastError));
  end;
  try
    FillChar(St, SizeOf(St), 0);
    if not QueryServiceStatus(S, St) then Exit(Integer(GetLastError));
    if St.dwCurrentState = SERVICE_STOPPED then Exit(0);
    if St.dwCurrentState <> SERVICE_STOP_PENDING then
      if not ControlService(S, SERVICE_CONTROL_STOP, St) and (GetLastError <> ERROR_SERVICE_NOT_ACTIVE_) then
      begin
        Escrever('não parou o serviço ' + ANome + ': ' + ErroTexto(GetLastError));
        Exit(Integer(GetLastError));
      end;
    Escrever('parando ' + ANome + ' (termina o trabalho em andamento)...');
    for K := 1 to AEsperaSeg * 2 do
    begin
      if QueryServiceStatus(S, St) and (St.dwCurrentState = SERVICE_STOPPED) then
      begin
        Escrever(ANome + ' parado');
        Exit(0);
      end;
      Sleep(500);
    end;
    Escrever(ANome + ' não parou em ' + IntToStr(AEsperaSeg) + ' s');
    Result := 1460; // ERROR_TIMEOUT
  finally
    CloseServiceHandle(S);
  end;
end;

function InstalarServico(AScm: SC_HANDLE; const ANome, AExibicao, ADescricao: string): Integer;
var
  S: SC_HANDLE;
  Binario, Ini: UnicodeString;
  Descricao: TServiceDescriptionW;
  Acoes: array[0..2] of TScAction;
  Falha: TServiceFailureActionsW;
  Info: TDwordInfo;
  K: Integer;
begin
  Binario := '"' + UnicodeString(ExpandFileName(ParamStr(0))) + '" --servico';
  Ini := UnicodeString(ArgumentoIni);
  if Ini <> '' then
    Binario := Binario + ' "' + UnicodeString(ExpandFileName(string(Ini))) + '"';
  S := OpenServiceW(AScm, PWideChar(UnicodeString(ANome)), SERVICE_ALL_ACCESS);
  if S <> 0 then
  begin
    if not ChangeServiceConfigW(S, SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
      PWideChar(Binario), nil, nil, nil, nil, nil, PWideChar(UnicodeString(AExibicao))) then
    begin
      Escrever('não atualizou o serviço ' + ANome + ': ' + ErroTexto(GetLastError));
      CloseServiceHandle(S);
      Exit(Integer(GetLastError));
    end;
    Escrever(ANome + ' atualizado');
  end
  else
  begin
    S := CreateServiceW(AScm, PWideChar(UnicodeString(ANome)), PWideChar(UnicodeString(AExibicao)),
      SERVICE_ALL_ACCESS, SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
      PWideChar(Binario), nil, nil, nil, nil, nil);
    if S = 0 then
    begin
      Escrever('não criou o serviço ' + ANome + ': ' + ErroTexto(GetLastError));
      Exit(Integer(GetLastError));
    end;
    Escrever(ANome + ' criado');
  end;
  try
    Descricao.lpDescription := PWideChar(UnicodeString(ADescricao));
    ChangeServiceConfig2W(S, SERVICE_CONFIG_DESCRIPTION, @Descricao);
    { Atrasado: sobe depois do Firebird e da rede (sem depender do nome do
      serviço do Firebird, que muda por versão/instância). }
    Info.Valor := 1;
    ChangeServiceConfig2W(S, SERVICE_CONFIG_DELAYED_AUTO_START_INFO, @Info);
    { Caiu ou saiu com erro (configuração): reinicia em 15 s, como o
      Restart=on-failure do systemd; zera a contagem depois de um dia. }
    for K := 0 to High(Acoes) do
    begin
      Acoes[K].Tipo := SC_ACTION_RESTART;
      Acoes[K].Atraso := 15000;
    end;
    FillChar(Falha, SizeOf(Falha), 0);
    Falha.dwResetPeriod := 86400;
    Falha.cActions := Length(Acoes);
    Falha.lpsaActions := @Acoes[0];
    if not ChangeServiceConfig2W(S, SERVICE_CONFIG_FAILURE_ACTIONS, @Falha) then
      Escrever('aviso: reinício automático não configurado: ' + ErroTexto(GetLastError));
    Info.Valor := 1;
    ChangeServiceConfig2W(S, SERVICE_CONFIG_FAILURE_ACTIONS_FLAG, @Info);
    { Desligamento do Windows: até 90 s para terminar a nota em transmissão. }
    Info.Valor := 90000;
    ChangeServiceConfig2W(S, SERVICE_CONFIG_PRESHUTDOWN_INFO, @Info);
  finally
    CloseServiceHandle(S);
  end;
  Escrever('comando: ' + string(Binario));
  Result := 0;
end;

function RemoverServico(AScm: SC_HANDLE; const ANome: string): Integer;
var
  S: SC_HANDLE;
begin
  Result := PararServico(AScm, ANome, 120);
  if Result <> 0 then Exit;
  S := OpenServiceW(AScm, PWideChar(UnicodeString(ANome)), DELETE_ACESSO);
  if S = 0 then
  begin
    if GetLastError = ERROR_SERVICE_DOES_NOT_EXIST_ then
    begin
      Escrever(ANome + ' não está instalado');
      Exit(0);
    end;
    Exit(Integer(GetLastError));
  end;
  try
    if not DeleteService(S) then
    begin
      Escrever('não removeu o serviço ' + ANome + ': ' + ErroTexto(GetLastError));
      Exit(Integer(GetLastError));
    end;
    Escrever(ANome + ' removido');
  finally
    CloseServiceHandle(S);
  end;
end;

function ComandoServico(const ANome, AExibicao, ADescricao: string; out ACodigo: Integer): Boolean;
var
  K: Integer;
  Cmd: string;
  Scm: SC_HANDLE;
begin
  ACodigo := 0;
  Cmd := '';
  for K := 1 to ParamCount do
    if (ParamStr(K) = '--instalar-servico') or (ParamStr(K) = '--remover-servico') or
      (ParamStr(K) = '--parar-servico') then
      Cmd := ParamStr(K)
    else if ParamStr(K) = '--servico' then
      ModoServico := True;
  if Cmd = '' then Exit(False);
  Result := True;
  if Cmd = '--instalar-servico' then
    Scm := OpenSCManagerW(nil, nil, SC_MANAGER_CONNECT or SC_MANAGER_CREATE_SERVICE)
  else
    Scm := OpenSCManagerW(nil, nil, SC_MANAGER_CONNECT);
  if Scm = 0 then
  begin
    ACodigo := Integer(GetLastError);
    Escrever('sem acesso ao Gerenciador de Serviços (rode como Administrador): ' + ErroTexto(GetLastError));
    Exit;
  end;
  try
    if Cmd = '--instalar-servico' then
      ACodigo := InstalarServico(Scm, ANome, AExibicao, ADescricao)
    else if Cmd = '--remover-servico' then
      ACodigo := RemoverServico(Scm, ANome)
    else
      ACodigo := PararServico(Scm, ANome, 120);
  finally
    CloseServiceHandle(Scm);
  end;
end;

{$ELSE}

procedure Rodar(const ANome: string; ATrabalho: TTrabalho; AParar: PBoolean);
begin
  ATrabalho;
end;

procedure PrepararAmbiente;
begin
end;

function ComandoServico(const ANome, AExibicao, ADescricao: string; out ACodigo: Integer): Boolean;
begin
  ACodigo := 0;
  Result := False;
end;
{$ENDIF}

initialization
  InitCriticalSection(LogTrava);
  {$IFDEF MSWINDOWS}
  InitCriticalSection(SvcTrava);
  {$ENDIF}

end.
