"""Disposable Firebird + local TLS SMTP; never sends to an external provider."""
import base64
import email.policy
from email.parser import BytesParser
import os
from pathlib import Path
import shutil
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
WIN = sys.platform == 'win32'
EXE = ROOT / 'bin' / ('AguiaEmail.exe' if WIN else 'AguiaEmail')
ISQL = os.environ.get('FIREBIRD_ISQL', r'C:\Program Files\Firebird\Firebird_5_0\isql.exe' if WIN else 'isql-fb')
OPENSSL = os.environ.get('OPENSSL_EXE', r'C:\Program Files\Git\usr\bin\openssl.exe' if WIN else 'openssl')
SERVER = os.environ.get('AGUIA_TEST_SERVER', '')
DBUSER = os.environ.get('ISC_USER', 'SYSDBA') if SERVER else 'SYSDBA'
DBPASSWORD = os.environ.get('ISC_PASSWORD', '') if SERVER else 'fixture'
MIGRATION = Path(os.environ.get('AGUIA_EMAIL_MIGRATION', str(ROOT.parents[1] / 'Delphi/AguiaEmpresarial/Scripts/000654.aad')))


class Smtp(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, cert, key):
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(cert, key)
        self.messages = []
        self.commands = []
        self.errors = []
        self.auths = 0
        self.tls = True
        self.full_ssl = False
        self.drop_data = False
        self.drop_quit = False
        self.reject_data = False
        self.data_seen = threading.Event()
        self.release_data = None
        self.before_recipient = None
        super().__init__(('127.0.0.1', 0), Handler)

    def handle_error(self, request, client_address):
        self.errors.append(repr(sys.exception()))


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        def send(text):
            self.wfile.write(text.encode('ascii') + b'\r\n')
            self.wfile.flush()

        try:
            if self.server.full_ssl:
                self.connection = self.server.context.wrap_socket(self.connection, server_side=True)
                self.rfile = self.connection.makefile('rb')
                self.wfile = self.connection.makefile('wb')
            send('220 localhost test')
            while True:
                line = self.rfile.readline()
                if not line:
                    return
                verb = line.split(b' ', 1)[0].strip().upper()
                self.server.commands.append(verb.decode('ascii'))
                if verb == b'EHLO':
                    send('250-localhost')
                    if self.server.tls:
                        send('250-STARTTLS')
                    send('250 AUTH PLAIN')
                elif verb == b'STARTTLS':
                    send('220 TLS')
                    self.connection = self.server.context.wrap_socket(self.connection, server_side=True)
                    self.rfile = self.connection.makefile('rb')
                    self.wfile = self.connection.makefile('wb')
                elif verb == b'AUTH':
                    self.server.auths += 1
                    assert isinstance(self.connection, ssl.SSLSocket), 'Credentials sent without TLS'
                    assert base64.b64decode(line.split()[2]) == b'\x00smtp-test\x00test-secret'
                    send('235 authenticated')
                elif verb in [b'MAIL', b'RCPT', b'RSET']:
                    if verb == b'RCPT' and self.server.before_recipient:
                        self.server.before_recipient()
                    send('250 ok')
                elif verb == b'DATA':
                    if self.server.reject_data:
                        send('550 rejected')
                        continue
                    send('354 start')
                    parts = []
                    while True:
                        piece = self.rfile.readline()
                        if not piece or piece == b'.\r\n':
                            break
                        parts.append(piece[1:] if piece.startswith(b'..') else piece)
                    self.server.messages.append(b''.join(parts))
                    self.server.data_seen.set()
                    if self.server.release_data:
                        self.server.release_data.wait(10)
                    if self.server.drop_data:
                        return
                    send('250 accepted')
                elif verb == b'QUIT':
                    if not self.server.drop_quit:
                        send('221 bye')
                    return
                else:
                    send('250 ok')
        except (ssl.SSLError, ConnectionError, BrokenPipeError):
            pass

    def finish(self):
        super().finish()
        self.connection.close()


class QueueTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='aguia-email-tests-', dir=ROOT / 'lib' if WIN else os.environ.get('AGUIA_EMAIL_TEST_DIR'))
        cls.folder = Path(cls.tmp.name).resolve()
        if SERVER:
            cls.folder.chmod(0o777)
        cls.cert, cls.key = cls.folder / 'ca.pem', cls.folder / 'key.pem'
        subprocess.run([OPENSSL, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
                        '-addext', 'basicConstraints=critical,CA:TRUE', '-keyout', str(cls.key),
                        '-out', str(cls.cert)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.sink = Smtp(str(self.cert), str(self.key))
        threading.Thread(target=self.sink.serve_forever, daemon=True).start()
        self.addCleanup(self.sink.server_close)
        self.addCleanup(self.sink.shutdown)
        self.db = self.folder / (self._testMethodName + '.fdb')
        self.ini = self.db.with_suffix('.ini')
        server_dir = os.environ.get('AGUIA_TEST_DATABASE_DIR')
        self.server_file = server_dir.rstrip('/')+'/'+self.folder.name+'__'+self.db.name if server_dir else self.db.as_posix()
        self.connection = f'{SERVER}:{self.server_file}' if SERVER else self.db.as_posix()
        create = f"CREATE DATABASE '{self.connection}';\n" if SERVER else f"CREATE DATABASE '{self.connection}' USER 'SYSDBA' PASSWORD 'fixture';\n"
        self.sql(create +
                 "CREATE TABLE VERSAO (INTERNAL_COD INTEGER PRIMARY KEY,DESCRICAO VARCHAR(200));\n"
                 "CREATE TABLE UCTABUSERS (UCIDUSER INTEGER PRIMARY KEY,UCINATIVE SMALLINT,UCUSERNAME VARCHAR(100));\n"
                 "CREATE TABLE EMAIL_CONTA (INTERNAL_COD INTEGER PRIMARY KEY,EMAIL VARCHAR(254),SMTP VARCHAR(254),PORTA INTEGER,USER_NAME VARCHAR(100),SENHA VARCHAR(400),CONEXAO_SEGURA INTEGER,USER_TLS INTEGER,NOME_EXIBICAO VARCHAR(200),REPLAY_TO VARCHAR(254));\n"
                 "CREATE TABLE EMAIL_CONTA_USUARIO (COD_EMAIL INTEGER,COD_USUARIO INTEGER,COD_EMPRESA INTEGER);\n"
                 "CREATE TABLE NFSE (ID_NFSE INTEGER PRIMARY KEY,ID_PRESTADOR INTEGER,STATUS INTEGER,NUMERO VARCHAR(20),XML BLOB SUB_TYPE TEXT CHARACTER SET UTF8,EMAIL_ENVIADO INTEGER);\n"
                 "CREATE TABLE NFSE_EMISSAO (ID_NFSE INTEGER PRIMARY KEY,DANFSE BLOB);\n"
                 "CREATE TABLE NFSE_DANFSE (ID_NFSE INTEGER PRIMARY KEY,PDF BLOB);\n"
                 "CREATE SEQUENCE GEN_NFSE_FILA_ID;\n"
                 "CREATE TABLE NFSE_FILA (INTERNAL_COD BIGINT,ID_NFSE INTEGER,COD_EMPRESA INTEGER,ACAO INTEGER,SITUACAO INTEGER DEFAULT 0);\n"
                 "CREATE TABLE NOTAFISCAL (INTERNAL_COD INTEGER PRIMARY KEY,COD_EMPRESA INTEGER,NUMERO INTEGER,XML BLOB SUB_TYPE TEXT CHARACTER SET UTF8);\n"
                 "CREATE TABLE NFE_DADOS (COD_NOTAFISCAL INTEGER PRIMARY KEY,CSTAT INTEGER,CANCEL_DATA TIMESTAMP,ENVIADO_EMAIL INTEGER);\n"
                 "CREATE TABLE NFE_DANFE (COD_NOTAFISCAL INTEGER PRIMARY KEY,PDF BLOB,CANCELADA INTEGER);\n"
                 "CREATE SEQUENCE GEN_NFE_FILA_ID;\n"
                 "CREATE TABLE NFE_FILA (INTERNAL_COD BIGINT,COD_NOTAFISCAL INTEGER,COD_EMPRESA INTEGER,ACAO INTEGER,SITUACAO INTEGER DEFAULT 0);\n"
                 "CREATE TABLE CONTARECEBER (INTERNAL_COD INTEGER PRIMARY KEY,COD_EMPRESA INTEGER,SALDO NUMERIC(15,2),BANCO_BAIXADO INTEGER,COD_CONTACORRENTE INTEGER,EMAIL_ENVIADO INTEGER);\n"
                 "CREATE TABLE BOLETO_EMISSAO (INTERNAL_COD BIGINT PRIMARY KEY,COD_EMPRESA INTEGER,COD_USUARIO INTEGER,COD_CONTAREC INTEGER,COD_CONTACORRENTE INTEGER,SITUACAO INTEGER,PDF BLOB);\n",
                 create=True)
        if SERVER:
            self.addCleanup(self.drop_database)
        # DBUpdater confirma cada bloco. DDL dinamico precisa dessa fronteira
        # para que a proxima instrucao veja as tabelas (o .aad nao tem COMMIT).
        self.sql(MIGRATION.read_text(encoding='utf-8-sig').replace('\nEND^\n', '\nEND^\nCOMMIT^\n'))
        migration_nfe = MIGRATION.with_name('000660.aad').read_text(encoding='utf-8-sig')
        for _ in range(2):  # estrutural idempotente, sem dados de cliente
            self.sql(migration_nfe.replace('END^', 'END^\nCOMMIT^'))
        self.sql("INSERT INTO NOTAFISCAL VALUES (579,1,579,'<nfeProc>NF-e José</nfeProc>');\n"
                 "INSERT INTO NFE_DADOS VALUES (579,100,NULL,0);\n"
                 "INSERT INTO NFE_DANFE VALUES (579,CAST('%PDF-1.7 DANFE' AS BLOB),0);\n")
        self.sql(f"INSERT INTO UCTABUSERS VALUES (1,0,'Operador');\n"
                 f"INSERT INTO EMAIL_CONTA VALUES (2,'empresa@example.com','localhost',{self.sink.server_address[1]},'smtp-test','dGVzdC1zZWNyZXQ=',0,1,'Empresa','financeiro@example.com');\n"
                 "INSERT INTO EMAIL_CONTA_USUARIO VALUES (2,1,1);\n"
                 "INSERT INTO NFSE VALUES (81,1,2,'787','<NFSe>Serviço José</NFSe>',0);\n"
                 "INSERT INTO NFSE_DANFSE VALUES (81,CAST('%PDF-1.7 teste' AS BLOB));\n"
                 "INSERT INTO CONTARECEBER VALUES (7,1,100,0,4,0);\n"
                 "INSERT INTO BOLETO_EMISSAO VALUES (123,1,1,7,4,2,CAST('%PDF-1.7 boleto' AS BLOB));\n")
        library = 'ClientLibrary=C:/Program Files/Firebird/Firebird_5_0/fbclient.dll\n' if WIN else ''
        password = '' if SERVER else 'Senha=fixture\n'
        self.ini.write_text(f'[BANCO]\nBanco={self.connection}\nUsuario={DBUSER}\n{password}{library}[EMAIL]\nCA={self.cert.as_posix()}\nTimeout=1500\nLimite=10\n', encoding='utf-8')
        self.ini.chmod(0o600)

    def sql(self, text, create=False, check=True):
        args = [ISQL, '-bail', '-q', '-ch', 'UTF8']
        if SERVER:
            args += ['-user', DBUSER]
        if not create:
            if not SERVER:
                args += ['-user', 'SYSDBA', '-password', 'fixture']
            args += [self.connection]
        script = self.db.with_suffix('.sql')
        script.write_text(text + '\nCOMMIT;\nQUIT;\n', encoding='utf-8')
        args += ['-i', str(script)]
        result = subprocess.run(args, text=True, encoding='utf-8', errors='replace',
                                capture_output=True, timeout=20)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def tearDown(self):
        self.assertEqual(self.sink.errors, [])

    def drop_database(self):
        assert SERVER and self._testMethodName in self.server_file and 'aguia-email-tests-' in self.server_file
        script = self.db.with_suffix('.drop.sql')
        script.write_text('DROP DATABASE;\nQUIT;\n', encoding='utf-8')
        result = subprocess.run([ISQL, '-bail', '-q', '-user', DBUSER, self.connection, '-i', str(script)], capture_output=True, text=True, errors='replace', timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)

    def enqueue(self, kind='nfse', job=1):
        source, doc = (81, 81) if kind == 'nfse' else ((579, 579) if kind == 'nfe' else (123, 7))
        self.sql(f"INSERT INTO EMAIL_ENVIO (INTERNAL_COD,COD_EMPRESA,COD_USUARIO,COD_EMAIL,TIPO,ORIGEM_ID,DOCUMENTO_ID,CHAVE,ATIVO,REMETENTE,DESTINATARIO,ASSUNTO,CORPO_TEXTO,CORPO_HTML) "
                 f"VALUES ({job},1,1,2,'{kind}',{source},{doc},'00000000-0000-4000-8000-{job:012}', '{kind}:{doc}',"
                 "'empresa@example.com','cliente@example.com','Serviço José','Olá, João. Serviço aceito.','<p>Olá, João.</p>');")

    def state(self, job=1):
        output = self.sql(f'SET HEADING OFF; SELECT SITUACAO FROM EMAIL_ENVIO WHERE INTERNAL_COD={job};').stdout
        return output.strip()

    def worker(self):
        try:
            result = subprocess.run([str(EXE), str(self.ini), '--uma-vez'], capture_output=True, text=True,
                                    encoding='utf-8', errors='replace', timeout=10)
        except subprocess.TimeoutExpired as error:
            self.fail(f'Worker timeout; SMTP commands={self.sink.commands}; stdout={error.stdout!r}')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_nfse_utf8_attachments_accepted_and_no_resend(self):
        self.enqueue()
        self.sink.drop_quit = True
        self.worker()
        self.assertEqual(self.state(), 'sent')
        self.worker()
        self.assertEqual(len(self.sink.messages), 1)
        message = BytesParser(policy=email.policy.default).parsebytes(self.sink.messages[0])
        self.assertEqual(str(message['Subject']), 'Serviço José')
        self.assertIn('Olá, João.', message.get_body(preferencelist=('plain',)).get_content())
        attachments = {p.get_filename(): p.get_payload(decode=True) for p in message.iter_attachments()}
        self.assertEqual(attachments['danfse.pdf'], b'%PDF-1.7 teste')
        self.assertEqual(attachments['nfse.xml'].decode('utf-8'), '<NFSe>Serviço José</NFSe>')
        self.assertIn('aguia-00000000-', message['Message-ID'])
        self.assertIn('1', self.sql('SET HEADING OFF; SELECT EMAIL_ENVIADO FROM NFSE WHERE ID_NFSE=81;').stdout)

    def test_nfe_pdf_xml_and_legacy_flag(self):
        self.enqueue('nfe')
        self.worker()
        self.assertEqual(self.state(), 'sent')
        self.worker()
        self.assertEqual(len(self.sink.messages), 1)
        message = BytesParser(policy=email.policy.default).parsebytes(self.sink.messages[0])
        attachments = {p.get_filename(): p.get_payload(decode=True) for p in message.iter_attachments()}
        self.assertEqual(attachments['danfe-579.pdf'], b'%PDF-1.7 DANFE')
        self.assertEqual(attachments['nfe.xml'].decode('utf-8'), '<nfeProc>NF-e José</nfeProc>')
        self.assertIn('1', self.sql('SET HEADING OFF; SELECT ENVIADO_EMAIL FROM NFE_DADOS WHERE COD_NOTAFISCAL=579;').stdout)

    @unittest.skipUnless(SERVER, 'Revalidacao concorrente exige Firebird servidor; embedded e exclusivo.')
    def test_nfe_cancelled_before_data(self):
        self.enqueue('nfe')
        self.sink.before_recipient = lambda: self.sql("UPDATE NFE_DADOS SET CANCEL_DATA=CURRENT_TIMESTAMP WHERE COD_NOTAFISCAL=579;")
        self.worker()
        self.assertEqual(self.state(), 'failed')
        self.assertEqual(self.sink.messages, [])

    def test_nfe_cancelled_refused(self):
        self.enqueue('nfe')
        self.sql('UPDATE NFE_DADOS SET CANCEL_DATA=CURRENT_TIMESTAMP WHERE COD_NOTAFISCAL=579;')
        self.worker()
        self.assertEqual(self.state(), 'failed')
        self.assertEqual(self.sink.messages, [])

    def test_nfe_wrong_company_refused(self):
        self.enqueue('nfe')
        self.sql('UPDATE NOTAFISCAL SET COD_EMPRESA=2 WHERE INTERNAL_COD=579;')
        self.worker()
        self.assertEqual(self.state(), 'failed')
        self.assertEqual(self.sink.messages, [])

    def test_nfe_missing_pdf_requests_emitter_once(self):
        self.enqueue('nfe')
        self.sql('DELETE FROM NFE_DANFE;')
        self.worker()
        self.assertEqual(self.state(), 'pending')
        self.sql('UPDATE EMAIL_ENVIO SET PROXIMA_TENTATIVA=CURRENT_TIMESTAMP;')
        self.worker()
        self.assertEqual(self.state(), 'pending')
        count = self.sql('SET HEADING OFF; SELECT COUNT(*) FROM NFE_FILA WHERE COD_NOTAFISCAL=579 AND ACAO=5;').stdout
        self.assertEqual(count.strip(), '1')
        self.assertEqual(self.sink.messages, [])

    def test_boleto_and_legacy_flag(self):
        self.enqueue('boleto')
        self.worker()
        self.assertEqual(self.state(), 'sent')
        message = BytesParser(policy=email.policy.default).parsebytes(self.sink.messages[0])
        self.assertEqual(next(message.iter_attachments()).get_filename(), 'boleto-7.pdf')
        self.assertIn('1', self.sql('SET HEADING OFF; SELECT EMAIL_ENVIADO FROM CONTARECEBER WHERE INTERNAL_COD=7;').stdout)

    def test_uncertain_data_is_never_resent_after_restart(self):
        self.enqueue()
        self.sink.drop_data = True
        self.worker()
        self.assertEqual(self.state(), 'unknown')
        self.worker()
        self.assertEqual(len(self.sink.messages), 1)

    def test_plaintext_smtp_never_receives_credentials_or_message(self):
        self.enqueue()
        self.sink.tls = False
        self.worker()
        self.assertEqual(self.state(), 'failed')
        self.assertEqual(self.sink.auths, 0)
        self.assertEqual(self.sink.messages, [])

    def test_implicit_tls_account_is_supported(self):
        self.enqueue()
        self.sink.full_ssl = True
        self.sql('UPDATE EMAIL_CONTA SET CONEXAO_SEGURA=1,USER_TLS=0;')
        self.worker()
        self.assertEqual(self.state(), 'sent')
        self.assertEqual(self.sink.auths, 1)
        self.assertNotIn('STARTTLS', self.sink.commands)

    def test_explicit_rejection_is_failed(self):
        self.enqueue()
        self.sink.reject_data = True
        self.worker()
        self.assertEqual(self.state(), 'failed')

    def test_cancelled_document_and_changed_sender_are_refused(self):
        self.enqueue()
        self.sql('UPDATE NFSE SET STATUS=3 WHERE ID_NFSE=81;')
        self.worker()
        self.assertEqual(self.state(), 'failed')
        self.sql("UPDATE NFSE SET STATUS=2 WHERE ID_NFSE=81; UPDATE EMAIL_CONTA SET EMAIL='outro@example.com' WHERE INTERNAL_COD=2;")
        self.enqueue(job=2)
        self.worker()
        self.assertEqual(self.state(2), 'failed')
        self.assertEqual(self.sink.messages, [])

    def test_missing_pdf_is_requested_once_and_waits(self):
        self.enqueue()
        self.sql('DELETE FROM NFSE_DANFSE;')
        self.worker()
        self.assertEqual(self.state(), 'pending')
        self.sql('UPDATE EMAIL_ENVIO SET PROXIMA_TENTATIVA=CURRENT_TIMESTAMP;')
        self.worker()
        count = self.sql('SET HEADING OFF; SELECT COUNT(*) FROM NFSE_FILA;').stdout.strip()
        self.assertEqual(count, '1')
        self.assertEqual(self.sink.messages, [])

    def test_crashed_preparation_can_resume_but_sending_becomes_unknown(self):
        self.enqueue()
        self.sql("UPDATE EMAIL_ENVIO SET SITUACAO='sending',ATUALIZADO_EM=DATEADD(-20 MINUTE TO CURRENT_TIMESTAMP);")
        self.worker()
        self.assertEqual(self.state(), 'unknown')
        self.enqueue(job=2)
        self.sql("UPDATE EMAIL_ENVIO SET SITUACAO='preparing',ATUALIZADO_EM=DATEADD(-20 MINUTE TO CURRENT_TIMESTAMP) WHERE INTERNAL_COD=2;")
        self.worker()
        self.assertEqual(self.state(2), 'sent')
        self.assertEqual(len(self.sink.messages), 1)

    def test_database_unique_keys_block_duplicate_active_work(self):
        self.enqueue()
        result = self.sql("INSERT INTO EMAIL_ENVIO SELECT 2,COD_EMPRESA,COD_USUARIO,USUARIO_NOME,COD_EMAIL,TIPO,ORIGEM_ID,DOCUMENTO_ID,"
                          "'outro',ATIVO,REMETENTE,DESTINATARIO,ASSUNTO,CORPO_TEXTO,CORPO_HTML,XML_FISCAL,AGUARDAR_AUTORIZACAO,DOCUMENTO_PEDIDO,"
                          "SITUACAO,MENSAGEM,MESSAGE_ID,PROCESSADOR,CRIADO_EM,ATUALIZADO_EM,PROXIMA_TENTATIVA FROM EMAIL_ENVIO WHERE INTERNAL_COD=1;", check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_certificate_hostname_mismatch_never_authenticates(self):
        self.enqueue()
        self.sql("UPDATE EMAIL_CONTA SET SMTP='127.0.0.1';")
        self.worker()
        self.assertEqual(self.state(), 'failed')
        self.assertEqual(self.sink.auths, 0)

    @unittest.skipIf(not SERVER, 'Concurrency requires AGUIA_TEST_SERVER (embedded SuperServer is exclusive)')
    def test_two_workers_do_not_deliver_the_same_work(self):
        self.enqueue()
        self.sink.release_data = threading.Event()
        first = subprocess.Popen([str(EXE), str(self.ini), '--uma-vez'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertTrue(self.sink.data_seen.wait(8), 'First worker did not reach DATA')
            self.worker()
            self.sink.release_data.set()
            out, err = first.communicate(timeout=10)
            self.assertEqual(first.returncode, 0, repr((out, err)))
            self.assertEqual(self.state(), 'sent')
            self.assertEqual(len(self.sink.messages), 1)
        finally:
            self.sink.release_data.set()
            if first.poll() is None:
                first.kill()
                first.communicate()

    @unittest.skipIf(not SERVER, 'Concurrency requires AGUIA_TEST_SERVER')
    def test_old_lease_cannot_send_after_work_is_reclaimed(self):
        self.enqueue()
        self.sink.before_recipient = lambda: self.sql("UPDATE EMAIL_ENVIO SET PROCESSADOR='replacement' WHERE INTERNAL_COD=1;")
        self.worker()
        self.assertEqual(self.state(), 'preparing')
        self.assertEqual(self.sink.messages, [])

    @unittest.skipIf(not SERVER, 'Concurrency requires AGUIA_TEST_SERVER')
    def test_cancelled_during_smtp_handshake_does_not_reach_data(self):
        self.enqueue()
        self.sink.before_recipient = lambda: self.sql('UPDATE NFSE SET STATUS=3 WHERE ID_NFSE=81;')
        self.worker()
        self.assertEqual(self.state(), 'failed')
        self.assertEqual(self.sink.messages, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
