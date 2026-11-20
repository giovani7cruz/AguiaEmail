# AguiaEmail

Serviço SMTP em Lazarus/FPC para Linux x64 e Windows x64. Consome a fila
`EMAIL_ENVIO` no Firebird da instalação e usa `EMAIL_CONTA` e os vínculos de
`EMAIL_CONTA_USUARIO`, incluindo contas Brevo por SMTP/TLS.

O portal solicita o envio pelo Middleware e consulta o andamento. Senhas SMTP,
PDFs e XMLs são lidos na VM. NFS-e usa os PDFs do EmissorDFe e boletos usam os
PDFs do AguiaBoletos. Um DANFSe ausente é solicitado pela `NFSE_FILA` uma vez.

## Banco e integração

Aplicar pelo DBUpdater o script oficial **000654** de
`../../Delphi/AguiaEmpresarial/Scripts/000654.aad`. A única origem do script
é essa pasta. Instalar o Middleware com as rotas `nfse/email-enfileirar`,
`nfse/email-andamento` e equivalentes em `boletos/emissoes/`.

Cada solicitação tem UUID persistido, empresa, usuário, referência do documento,
conta, remetente, destinatário e mensagem congelada. Repetir o mesmo UUID e
conteúdo devolve o mesmo trabalho. Reenvio após aceite ou resultado incerto
exige confirmação explícita. A fila impede dois envios ativos do mesmo documento.

O serviço reserva o trabalho atomicamente e grava `sending` antes do SMTP DATA.
Timeout ou queda nessa etapa vira `unknown` e não é repetido automaticamente.
Preparação interrompida pode ser retomada com um novo identificador de reserva;
o processador antigo perde o direito de enviar. A resposta de aceite ao DATA
continua válida mesmo se o QUIT falhar. Aceite SMTP não confirma entrega.

O TLS é obrigatório, com CA e nome do servidor conferidos antes de autenticar.
Documentos cancelados/baixados são recusados, com nova leitura antes do DATA.
PDFs têm limite de 20 MB e XMLs de 10 MB. O histórico fica no banco e no backup.

## Compilar

- Windows: `./build-windows.ps1`. Lazarus em `C:\lazarus`; ACBr na árvore
  `../../Delphi/Componentes/ACBr`. O script copia OpenSSL 3, fbclient e um pacote
  CA público para `bin`. O parâmetro `-CaBundle` aceita um PEM confiável; o padrão
  é o pacote de CAs da instalação do Git for Windows.
- Linux: `bash build-linux.sh`. Requer Lazarus/FPC, Synapse do ACBr, libfbclient,
  OpenSSL 3 e `ca-certificates`.

O projeto abre em `source/AguiaEmail.lpi`; usa uma configuração isolada do
Lazarus. O build não altera a configuração da IDE do usuário.

## Instalar e operar

Linux: após aplicar o script do banco, executar `sudo bash deploy/install-linux.sh`.
Serviço `aguia-email`, configuração `/opt/aguia/email/email.ini`, logs pelo
`journalctl -u aguia-email`. A conta `aguia` precisa ler o configFirebird do
Middleware. O instalador preserva o ini existente e guarda o executável anterior.

Windows: executar como administrador `deploy/install-windows.ps1 -Destination
"C:\Aguia\Modulos\Email" -ConfigFirebird "C:\Aguia\Modulos\Middleware\configFirebird.ini"`.
Serviço `ServiceEmailAguia`; os arquivos ficam restritos a SYSTEM e Administradores.
O ini existente é preservado. O Host de serviço é o mesmo do EmissorDFe/AguiaBoletos.

Comandos: `AguiaEmail [email.ini]`, `--verificar` (conexão/estrutura, sem enviar),
`--uma-vez` (processa a fila uma vez), `--instalar-servico`, `--parar-servico`,
`--remover-servico` (Windows). Parada termina o trabalho em andamento.

## Testes

`python tests/test_queue.py` cria bancos Firebird descartáveis e um SMTP TLS
local com certificado de teste. Não contata o Brevo nem destinatários externos.
Configurar `AGUIA_EMAIL_MIGRATION` caso a árvore de scripts esteja em outro lugar.
No Windows, o teste usa o cliente completo do Firebird 5 instalado para conexão
embedded, evitando um fbclient antigo no System32.

Para testar concorrência, usar `AGUIA_TEST_SERVER=host/porta`, `ISC_USER`,
`ISC_PASSWORD` e `AGUIA_TEST_DATABASE_DIR` com uma pasta de bancos descartáveis
permitida pelo servidor. As credenciais vêm do ambiente; os testes criam e
removem apenas bancos com prefixo `aguia-email-tests-`. O modo embedded
SuperServer tem acesso exclusivo e pula os três testes que exigem concorrência.

## Troca da hospedagem

Com o serviço e o Middleware atualizados, publicar a integração do portal e sua
migração `add_vm_id_to_document_emails`. Remover os cron/agendamentos de
`nfse:process-emails` e `boletos:process-emails`. Os comandos passam a servir
somente para transferência única de pendências legadas, preservando UUIDs.
Trabalhos em envio ou com resultado incerto não devem ser transferidos/repetidos
automaticamente. Históricos anteriores permanecem no portal; novos estados vêm
da VM. Conferir pendências e manter backup antes de ativar a troca.

Configurações reais, certificados privados, senhas, bancos, logs e executáveis
não entram no Git.


## NF-e/NFC-e do novo monitor (20/11/2026)

Aplicar tambem o estrutural oficial 000660.aad, que acrescenta nfe aos tipos
da EMAIL_ENVIO (sem dados ou ativacao por cliente). Atualizar e reiniciar o
servico antes de liberar notas/email-enfileirar no Middleware. O heartbeat
1.1-nfe identifica este suporte; o Middleware recusa worker antigo/offline.

NF-e/NFC-e proprias autorizadas e nao canceladas usam o PDF da NFE_DANFE e o
XML da NOTAFISCAL. PDF ausente solicita acao 5 na NFE_FILA uma unica vez.
O XML confirmado fica congelado na fila e e comparado antes do SMTP DATA;
empresa, cancelamento e autorizacao sao revalidados. Anexos danfe-NUMERO.pdf
e nfe.xml. O aceite SMTP marca NFE_DADOS.ENVIADO_EMAIL; nao confirma entrega.
O Client permite conferir destinatario/assunto/mensagem e acompanhar o
historico do usuario. Nenhum envio automatico foi acrescentado a autorizacao.

Testes: 000660 aplicado duas vezes em cada banco descartavel; anexos UTF-8,
nota cancelada, empresa incorreta e DANFE ausente. Revalidacao concorrente
durante o SMTP exige AGUIA_TEST_SERVER; o Firebird embedded e exclusivo.
