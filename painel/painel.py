#!/usr/bin/env python3
"""
Painel web do servidor de provisionamento Intelbras.

Só usa a biblioteca padrão do Python 3 (nada para instalar).
Toda alteração passa pelos mesmos scripts da linha de comando
(provisiona.sh e importar_modelo.sh), então painel e terminal
ficam sempre consistentes.

    python3 painel.py                 # porta 8080
    PAINEL_PORTA=9000 python3 painel.py

Usuário: admin. Senha: python3 painel.py --definir-senha  (ou --gerar-senha)
"""
import base64
import csv
import hashlib
import hmac
import io
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

PAINEL_DIR = os.path.dirname(os.path.abspath(__file__))
APP_DIR = os.environ.get("PROVISIONA_DIR", os.path.dirname(PAINEL_DIR))
PROVISIONA = os.path.join(APP_DIR, "provisiona.sh")
IMPORTAR = os.path.join(APP_DIR, "importar_modelo.sh")
CONF = os.environ.get("PROVISIONA_CONF", os.path.join(APP_DIR, "provisiona.conf"))
MODELOS_CONF = os.path.join(APP_DIR, "modelos.conf")
TEMPLATES = os.path.join(APP_DIR, "templates")
SENHA_ARQ = os.path.join(APP_DIR, "painel.senha")
NGINX_LOG = "/var/log/nginx/provisionamento.log"
FTP_LOG = "/var/log/vsftpd-provisionamento.log"
PORTA = int(os.environ.get("PAINEL_PORTA", "8080"))
USUARIO = "admin"

CHAVES_CONF = {
    "SIP_SERVER": r"^[A-Za-z0-9.\-:]+$",
    "SIP_PORT": r"^\d{1,5}$",
    "SIP_REG_TTL": r"^\d{1,6}$",
    "NTP_SERVER": r"^[A-Za-z0-9.\-]*$",
    "NTP_SERVER2": r"^[A-Za-z0-9.\-]*$",
    "ADMIN_PASS": r"^[^\"`$\\\n]*$",
    "PREFIXO_USUARIO": r"^[0-9]*$",
    "PREFIXO_PADRAO": r"^[0-9A-Za-z]*$",
    "SENHA_PADRAO": r"^(usuario|informada)$",
    "FORMATO_NOME": r"^[^\"`$\\\n]*$",
    "LCD_TITULO": r"^[^\"`$\\\n]{0,32}$",
    "VLAN_ID": r"^(\d{1,4})?$",
}
RE_MAC = re.compile(r"^[0-9a-f]{12}$")


# ---------------------------------------------------------------- utilidades
def normaliza_mac(m):
    m = re.sub(r"[:.\-\s]", "", (m or "")).lower()
    return m if RE_MAC.match(m) else None


def roda(cmd, entrada=None):
    """Executa um script (sem shell) e devolve (ok, saída)."""
    env = dict(os.environ, PROVISIONA_CONF=CONF)
    p = subprocess.run(cmd, input=entrada, capture_output=True, text=True, env=env, timeout=120)
    return p.returncode == 0, (p.stdout + p.stderr).strip()


def le_conf():
    valores = {}
    if os.path.exists(CONF):
        for linha in open(CONF, encoding="utf-8"):
            m = re.match(r'^\s*([A-Z0-9_]+)="?(.*?)"?\s*$', linha)
            if m:
                valores[m.group(1)] = m.group(2)
    return valores


def grava_conf(novos):
    linhas = open(CONF, encoding="utf-8").read().splitlines()
    feitas = set()
    for i, linha in enumerate(linhas):
        m = re.match(r"^\s*([A-Z0-9_]+)=", linha)
        if m and m.group(1) in novos:
            linhas[i] = f'{m.group(1)}="{novos[m.group(1)]}"'
            feitas.add(m.group(1))
    for k, v in novos.items():
        if k not in feitas:
            linhas.append(f'{k}="{v}"')
    tmp = CONF + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(linhas) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONF)


def ramais_csv_path():
    return le_conf().get("RAMAIS_CSV") or os.path.join(APP_DIR, "ramais.csv")


def le_ramais():
    caminho = ramais_csv_path()
    if not os.path.exists(caminho):
        return []
    with open(caminho, encoding="utf-8") as f:
        linhas = list(csv.reader(f, delimiter=";"))
    out = []
    conf = le_conf()
    for r in linhas[1:]:
        if len(r) >= 5:
            r += [""] * (6 - len(r))
            item = {"modelo": r[0], "mac": r[1], "prefixo": r[2], "ramal": r[3], "nome": r[4], "senha": r[5]}
            item["usuario"] = conf.get("PREFIXO_USUARIO", "") + item["prefixo"] + item["ramal"]
            out.append(item)
    return out


def le_modelos():
    modelos = []
    for linha in open(MODELOS_CONF, encoding="utf-8"):
        if not linha.strip() or linha.lstrip().startswith("#"):
            continue
        partes = [p.strip() for p in linha.split("|")]
        if len(partes) < 3:
            continue
        tpl = os.path.join(TEMPLATES, partes[1])
        pronto = os.path.exists(tpl) and not open(tpl, encoding="utf-8", errors="replace").read().startswith("MODELO_NAO_IMPORTADO")
        modelos.append({"modelo": partes[0], "template": partes[1], "arquivo": partes[2], "pronto": pronto})
    return modelos


def arquivo_do(mac, modelo):
    for m in le_modelos():
        if m["modelo"] == modelo:
            nome = m["arquivo"].replace("{{mac}}", mac).replace("{{MAC}}", mac.upper())
            return os.path.join(le_conf().get("PROV_DIR", "/srv/provisionamento"), nome)
    return None


# ------------------------------------------------------ atividade (downloads)
RE_NGINX = re.compile(r'^(\S+) \S+ \S+ \[([^\]]+)\] "(?:GET|HEAD) /?(\S*) [^"]*" (\d{3})')
RE_FTP = re.compile(r"^\w{3} (\w{3} +\d+ [\d:]+ \d{4}) \d+ (\S+) \d+ (\S+) .* (c|i)$")
RE_TFTP = re.compile(r"^(\S+ +\d+ [\d:]+|\S+T[\d:.+\-]+) .*RRQ from (\S+) filename (\S+)")


def atividade(limite=300):
    eventos = []
    try:
        with open(NGINX_LOG, encoding="utf-8", errors="replace") as f:
            for linha in f.readlines()[-2000:]:
                m = RE_NGINX.match(linha)
                if m:
                    try:
                        quando = datetime.strptime(m.group(2), "%d/%b/%Y:%H:%M:%S %z").timestamp()
                    except ValueError:
                        continue
                    eventos.append({"quando": quando, "ip": m.group(1), "arquivo": unquote(m.group(3)).lstrip("/"),
                                    "via": "HTTP", "ok": m.group(4) in ("200", "304")})
    except OSError:
        pass
    try:
        out = subprocess.run(["journalctl", "-u", "tftpd-hpa", "--since", "-7d", "-o", "short-iso", "--no-pager"],
                             capture_output=True, text=True, timeout=15).stdout
        for linha in out.splitlines()[-2000:]:
            m = RE_TFTP.match(linha)
            if m:
                try:
                    iso = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", m.group(1))
                    quando = datetime.fromisoformat(iso).timestamp()
                except ValueError:
                    quando = time.time()
                eventos.append({"quando": quando, "ip": m.group(2), "arquivo": m.group(3).lstrip("/"), "via": "TFTP", "ok": True})
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        with open(FTP_LOG, encoding="utf-8", errors="replace") as f:
            for linha in f.readlines()[-2000:]:
                m = RE_FTP.match(linha.strip())
                if m:
                    try:
                        quando = datetime.strptime(re.sub(" +", " ", m.group(1)), "%b %d %H:%M:%S %Y").timestamp()
                    except ValueError:
                        continue
                    eventos.append({"quando": quando, "ip": m.group(2), "arquivo": m.group(3).lstrip("/"),
                                    "via": "FTP", "ok": m.group(4) == "c"})
    except OSError:
        pass
    prov = le_conf().get("PROV_DIR", "/srv/provisionamento")
    for e in eventos:
        if e["via"] == "TFTP":
            e["ok"] = os.path.exists(os.path.join(prov, os.path.basename(e["arquivo"])))
    # downloads do "provisiona testar" não interessam
    eventos = [e for e in eventos if not e["arquivo"].endswith("teste-provisionamento.txt")]
    eventos.sort(key=lambda e: e["quando"], reverse=True)
    return eventos[:limite]


# -------------------------------------------------------------------- senha
def hash_senha(senha, sal=None):
    sal = sal or secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", senha.encode(), bytes.fromhex(sal), 200_000).hex()
    return f"{sal}${h}"


def confere_senha(senha):
    try:
        sal, h = open(SENHA_ARQ).read().strip().split("$")
    except (OSError, ValueError):
        return False
    return hmac.compare_digest(hash_senha(senha, sal).split("$")[1], h)


def definir_senha(aleatoria=False):
    if aleatoria:
        s1 = secrets.token_urlsafe(9)
    else:
        import getpass
        s1 = getpass.getpass("Nova senha do painel (usuário admin): ")
        if not s1 or s1 != getpass.getpass("Repita: "):
            sys.exit("As senhas não conferem.")
    with open(SENHA_ARQ, "w") as f:
        f.write(hash_senha(s1) + "\n")
    os.chmod(SENHA_ARQ, 0o600)
    print(f"Senha do painel (usuário admin): {s1}" if aleatoria else f"Senha salva em {SENHA_ARQ}")


# ------------------------------------------------------------------- HTTP
class Painel(BaseHTTPRequestHandler):
    server_version = "PainelProvisionamento/1.0"
    falhas = {}

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.client_address[0], fmt % args))

    # -- respostas
    def _json(self, dados, status=200):
        corpo = json.dumps(dados, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(corpo)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(corpo)

    def _texto(self, texto, tipo="text/plain; charset=utf-8", baixar=None):
        corpo = texto.encode() if isinstance(texto, str) else texto
        self.send_response(200)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(corpo)))
        self.send_header("Cache-Control", "no-store")
        if baixar:
            self.send_header("Content-Disposition", f'attachment; filename="{baixar}"')
        self.end_headers()
        self.wfile.write(corpo)

    def _corpo(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 5_000_000:
            raise ValueError("arquivo grande demais")
        return json.loads(self.rfile.read(n) or b"{}")

    # -- autenticação (HTTP Basic, usuário admin)
    def _autorizado(self):
        ip = self.client_address[0]
        bloqueio = self.falhas.get(ip, (0, 0))
        if bloqueio[0] >= 5 and time.time() - bloqueio[1] < 300:
            self._json({"erro": "muitas tentativas; aguarde 5 minutos"}, 429)
            return False
        cab = self.headers.get("Authorization", "")
        if cab.startswith("Basic "):
            try:
                usuario, senha = base64.b64decode(cab[6:]).decode().split(":", 1)
                if usuario == USUARIO and confere_senha(senha):
                    self.falhas.pop(ip, None)
                    return True
            except (ValueError, UnicodeDecodeError):
                pass
            self.falhas[ip] = (bloqueio[0] + 1, time.time())
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Provisionamento", charset="UTF-8"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    # -- rotas
    def do_GET(self):
        if not self._autorizado():
            return
        caminho = urlparse(self.path).path
        if caminho in ("/", "/index.html"):
            return self._texto(open(os.path.join(PAINEL_DIR, "index.html"), "rb").read(), "text/html; charset=utf-8")
        if caminho == "/api/ramais":
            ramais = le_ramais()
            vistos = {}
            for e in atividade():
                base = os.path.basename(e["arquivo"]).lower()
                mac = base[:12]
                if RE_MAC.match(mac) and mac not in vistos:
                    vistos[mac] = e
            for r in ramais:
                arq = arquivo_do(r["mac"], r["modelo"])
                r["arquivo"] = os.path.basename(arq) if arq else ""
                r["gerado"] = bool(arq and os.path.exists(arq))
                r["ultimo"] = vistos.get(r["mac"])
            return self._json({"ramais": ramais})
        if caminho == "/api/servicos":
            ok, saida = roda([PROVISIONA, "testar"])
            servicos = {}
            for linha in saida.splitlines():
                partes = linha.split()
                if len(partes) >= 2 and partes[0] in ("HTTP", "TFTP", "FTP"):
                    servicos[partes[0]] = partes[1] == "OK"
            return self._json({"servicos": servicos, "saida": saida})
        if caminho == "/api/modelos":
            return self._json({"modelos": le_modelos()})
        if caminho == "/api/config":
            c = le_conf()
            return self._json({k: c.get(k, "") for k in CHAVES_CONF} | {"PROV_DIR": c.get("PROV_DIR", ""), "RAMAIS_CSV": ramais_csv_path(), "VLAN_DHCP_OPCAO": c.get("VLAN_DHCP_OPCAO", "")})
        if caminho == "/api/atividade":
            cadastrados = {r["mac"]: r for r in le_ramais()}
            ev = atividade()
            for e in ev:
                r = cadastrados.get(os.path.basename(e["arquivo"]).lower()[:12])
                e["ramal"] = f'{r["prefixo"]}-{r["ramal"]} {r["nome"]}'.lstrip("-") if r else ""
            return self._json({"eventos": ev})
        if caminho.startswith("/api/arquivo/"):
            mac = normaliza_mac(caminho.rsplit("/", 1)[1])
            r = next((r for r in le_ramais() if r["mac"] == mac), None)
            arq = arquivo_do(mac, r["modelo"]) if r else None
            if not arq or not os.path.exists(arq):
                return self._json({"erro": "arquivo não gerado"}, 404)
            return self._texto(open(arq, encoding="utf-8", errors="replace").read())
        if caminho == "/api/csv":
            caminho_csv = ramais_csv_path()
            dados = open(caminho_csv, "rb").read() if os.path.exists(caminho_csv) else b"modelo;mac;ramal;senha;nome\n"
            return self._texto(dados, "text/csv; charset=utf-8", baixar=f"ramais-{datetime.now():%Y-%m-%d}.csv")
        self._json({"erro": "não encontrado"}, 404)

    def do_POST(self):
        if not self._autorizado():
            return
        caminho = urlparse(self.path).path
        try:
            d = self._corpo()
        except ValueError as e:
            return self._json({"erro": f"requisição inválida: {e}"}, 400)

        if caminho == "/api/ramais":
            mac = normaliza_mac(d.get("mac"))
            if not mac:
                return self._json({"erro": "MAC inválido (12 dígitos hexadecimais)"}, 400)
            modelo, prefixo, ramal, nome, senha = [str(d.get(k, "")).strip() for k in ("modelo", "prefixo", "ramal", "nome", "senha")]
            if not modelo or not ramal or not nome:
                return self._json({"erro": "modelo, ramal e nome são obrigatórios"}, 400)
            antigo = normaliza_mac(d.get("mac_antigo") or "")
            ok, saida = roda([PROVISIONA, "gerar", modelo, mac, prefixo or "-", ramal, nome, senha])
            if ok and antigo and antigo != mac:
                roda([PROVISIONA, "remover", antigo])
            return self._json({"ok": ok, "saida": saida}, 200 if ok else 400)

        if caminho == "/api/lote":
            texto = d.get("csv", "")
            with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False, encoding="utf-8") as f:
                f.write(texto)
            try:
                ok, saida = roda([PROVISIONA, "lote", f.name])
            finally:
                os.unlink(f.name)
            return self._json({"ok": ok, "saida": saida})

        if caminho == "/api/regerar":
            ok, saida = roda([PROVISIONA, "regerar"])
            return self._json({"ok": ok, "saida": saida})

        if caminho == "/api/remover":
            mac = normaliza_mac(d.get("mac"))
            if not mac:
                return self._json({"erro": "MAC inválido"}, 400)
            ok, saida = roda([PROVISIONA, "remover", mac])
            return self._json({"ok": ok, "saida": saida}, 200 if ok else 400)

        if caminho == "/api/config":
            novos = {}
            for k, padrao in CHAVES_CONF.items():
                if k in d:
                    v = str(d[k]).strip()
                    if not re.match(padrao, v):
                        return self._json({"erro": f"valor inválido para {k}"}, 400)
                    novos[k] = v
            if not novos.get("SIP_SERVER", "x"):
                return self._json({"erro": "SIP_SERVER é obrigatório"}, 400)
            grava_conf(novos)
            ok, saida = roda([PROVISIONA, "regerar"]) if d.get("regerar") else (True, "")
            return self._json({"ok": ok, "saida": saida})

        if caminho == "/api/template":
            modelo = str(d.get("modelo", "")).lower()
            if modelo not in {m["modelo"] for m in le_modelos()}:
                return self._json({"erro": "modelo desconhecido"}, 400)
            try:
                conteudo = base64.b64decode(d.get("arquivo_b64", ""))
            except ValueError:
                return self._json({"erro": "arquivo inválido"}, 400)
            if not conteudo:
                return self._json({"erro": "envie o arquivo de backup"}, 400)
            with tempfile.NamedTemporaryFile("wb", delete=False) as f:
                f.write(conteudo)
            cmd = [IMPORTAR, modelo, f.name]
            for chave in ("ramal", "senha", "nome", "servidor"):
                if str(d.get(chave, "")).strip():
                    cmd += [f"--{chave}", str(d[chave]).strip()]
            try:
                ok, saida = roda(cmd)
            finally:
                os.unlink(f.name)
            return self._json({"ok": ok, "saida": saida})

        self._json({"erro": "não encontrado"}, 404)


def main():
    if "--definir-senha" in sys.argv:
        return definir_senha()
    if "--gerar-senha" in sys.argv:
        return definir_senha(aleatoria=True)
    if not os.path.exists(SENHA_ARQ):
        sys.exit(f"Defina a senha antes: python3 {sys.argv[0]} --definir-senha")
    srv = ThreadingHTTPServer(("0.0.0.0", PORTA), Painel)
    print(f"Painel em http://0.0.0.0:{PORTA}/  (usuário {USUARIO})", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
