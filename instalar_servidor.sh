#!/usr/bin/env bash
# =====================================================================
#  instalar_servidor.sh - monta o servidor de provisionamento em um
#  Debian 12 / Ubuntu 22.04+ limpo (rodar como root).
#
#  Uso:  sudo ./instalar_servidor.sh [--rede "192.168.0.0/16 10.0.0.0/8"] [--sem-ftp] [--sem-painel]
#                                    [--repo URL] [--branch main] [--local]
#                                    [--auto-atualizar | --sem-auto-atualizar]
#
#  Instalação direto do GitHub (servidor novo, sem baixar nada antes):
#    curl -fsSL https://raw.githubusercontent.com/ecruz-acamps/provisioning_IPphone/main/instalar_servidor.sh | sudo bash
#  O instalador clona (ou atualiza) o repositório em /opt/provisionamento-src
#  e instala a partir dele. Rodar de novo = atualizar para a versão do GitHub.
#  --local  usa a pasta onde o script está, sem acessar o GitHub.
#
#  Instala:  TFTP (tftpd-hpa) + HTTP (nginx) + FTP anônimo só-leitura (vsftpd),
#            os três servindo a mesma pasta /srv/provisionamento. Assim o
#            telefone funciona com qualquer protocolo configurado nele.
#            --sem-ftp  pula o FTP.
#  Painel web de gerenciamento na porta 8080 (usuário admin; a senha
#  aparece no fim da instalação). --sem-painel pula esta parte.
#  Copia os scripts para /opt/provisionamento e cria o comando
#  "provisiona" em /usr/local/bin.
#  NÃO mexe no DHCP da rede: veja a pasta dhcp/ e o README.
#
#  A rede dos telefones fica em REDE_TELEFONES no provisiona.conf e pode ser
#  trocada depois pelo painel (Configurações). --rede só é necessário na
#  primeira instalação; sem ele, a rede já salva é mantida.
#
#  Atualizar depois:  sudo provisiona-atualizar
#  As opções usadas (repo, branch, --sem-ftp, --sem-painel, --auto-atualizar)
#  ficam em /etc/default/provisionamento e valem nas próximas atualizações.
#  --auto-atualizar  confere o GitHub a cada 10 minutos e atualiza sozinho
#                    quando houver commit novo no branch (timer systemd).
# =====================================================================
set -euo pipefail
REDE=""; FTP=sim; PAINEL=sim; AUTO_ATUALIZAR=nao
REPO="https://github.com/ecruz-acamps/provisioning_IPphone.git"; BRANCH=main
OPCOES=/etc/default/provisionamento
# opções da instalação anterior (gravadas no fim deste script)
# shellcheck source=/dev/null
[ -f "$OPCOES" ] && . "$OPCOES"
REPO="${PROVISIONA_REPO:-$REPO}"; BRANCH="${PROVISIONA_BRANCH:-$BRANCH}"; LOCAL=nao
SRC_DIR=/opt/provisionamento-src
while [ $# -gt 0 ]; do
  case "$1" in
    --rede) REDE="$2"; shift 2 ;;
    --ftp)  FTP=sim; shift ;;          # mantido por compatibilidade (já é o padrão)
    --sem-ftp) FTP=nao; shift ;;
    --sem-painel) PAINEL=nao; shift ;;
    --repo)   REPO="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --local)  LOCAL=sim; shift ;;
    --auto-atualizar) AUTO_ATUALIZAR=sim; shift ;;
    --sem-auto-atualizar) AUTO_ATUALIZAR=nao; shift ;;
    *) echo "opção desconhecida: $1" >&2; exit 1 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "rode como root (sudo)" >&2; exit 1; }
case "$REDE" in *[!0-9A-Fa-f.:/,\ ]*) echo "--rede inválida: $REDE (ex.: 192.168.0.0/16)" >&2; exit 1 ;; esac
ORIGEM="$(cd "$(dirname "$(readlink -f "$0")")" 2>/dev/null && pwd || pwd)"
PROV_DIR=/srv/provisionamento
APP_DIR=/opt/provisionamento

echo ">> Instalando pacotes"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q tftpd-hpa nginx python3 curl git
[ "$FTP" = sim ] && apt-get install -y -q vsftpd

if [ "$LOCAL" = nao ]; then
  echo ">> Baixando $REPO ($BRANCH)"
  if [ -d "$SRC_DIR/.git" ]; then
    git -C "$SRC_DIR" remote set-url origin "$REPO"
    git -C "$SRC_DIR" fetch -q --depth 1 origin "$BRANCH"
    git -C "$SRC_DIR" reset -q --hard FETCH_HEAD
  else
    rm -rf "$SRC_DIR"
    git clone -q --depth 1 --branch "$BRANCH" "$REPO" "$SRC_DIR"
  fi
  echo "   versão: $(git -C "$SRC_DIR" log -1 --format='%h %cd %s' --date=short)"
  ORIGEM="$SRC_DIR"
elif [ ! -f "$ORIGEM/provisiona.sh" ]; then
  echo "--local: provisiona.sh não encontrado em $ORIGEM" >&2; exit 1
fi

echo ">> Copiando scripts para $APP_DIR"
mkdir -p "$APP_DIR" "$PROV_DIR"
if [ "$ORIGEM" != "$APP_DIR" ]; then
  # Não sobrescreve configuração, templates importados nem a planilha de ramais.
  cp -n "$ORIGEM"/provisiona.conf "$ORIGEM"/modelos.conf "$APP_DIR"/ 2>/dev/null || true
  cp -f "$ORIGEM"/*.sh "$ORIGEM"/ramais_exemplo.csv "$APP_DIR"/
  mkdir -p "$APP_DIR/templates" "$APP_DIR/dhcp"
  cp -n "$ORIGEM"/templates/* "$APP_DIR/templates/" 2>/dev/null || true
  cp -f "$ORIGEM"/dhcp/* "$APP_DIR/dhcp/" 2>/dev/null || true
  if [ -d "$ORIGEM/painel" ]; then
    mkdir -p "$APP_DIR/painel"
    cp -f "$ORIGEM"/painel/painel.py "$ORIGEM"/painel/index.html "$APP_DIR/painel/"
  fi
  [ -f "$ORIGEM/README.md" ] && cp -f "$ORIGEM/README.md" "$APP_DIR/"
fi
chmod 755 "$APP_DIR"/*.sh
chmod 600 "$APP_DIR/provisiona.conf"

# Rede dos telefones: --rede grava no provisiona.conf; sem --rede mantém a já salva.
if [ -n "$REDE" ]; then
  if grep -q '^REDE_TELEFONES=' "$APP_DIR/provisiona.conf"; then
    sed -i "s|^REDE_TELEFONES=.*|REDE_TELEFONES=\"$REDE\"|" "$APP_DIR/provisiona.conf"
  else
    printf '\n# Rede dos telefones (quem pode baixar os arquivos). Editável no painel.\nREDE_TELEFONES="%s"\n' "$REDE" >> "$APP_DIR/provisiona.conf"
  fi
elif ! grep -q '^REDE_TELEFONES=' "$APP_DIR/provisiona.conf"; then
  printf '\n# Rede dos telefones (quem pode baixar os arquivos). Editável no painel.\nREDE_TELEFONES="192.168.0.0/16"\n' >> "$APP_DIR/provisiona.conf"
fi
REDE="$(sed -n 's/^REDE_TELEFONES="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$APP_DIR/provisiona.conf" | head -1)"
# Script que aplica a rede no nginx/ufw roda como root: fica fora de $APP_DIR
# (que pertence ao usuário do painel) para ele não poder alterá-lo.
install -o root -g root -m 755 "$ORIGEM/aplicar_rede.sh" /usr/local/sbin/provisiona-aplicar-rede
install -o root -g root -m 755 "$ORIGEM/atualizar.sh" /usr/local/sbin/provisiona-atualizar
ln -sf "$APP_DIR/provisiona.sh" /usr/local/bin/provisiona
for s in "$APP_DIR"/create_modelo_*.sh; do ln -sf "$s" "/usr/local/bin/$(basename "$s")"; done
chmod 755 "$PROV_DIR"

echo ">> Criando usuário de serviço 'provisiona' (dono dos arquivos)"
if ! id provisiona >/dev/null 2>&1; then
  useradd --system --home-dir "$APP_DIR" --no-create-home --shell /usr/sbin/nologin provisiona
fi
# adm/systemd-journal: para o painel ler os logs de download (nginx e TFTP)
for g in adm systemd-journal; do getent group "$g" >/dev/null && usermod -aG "$g" provisiona; done
chown -R provisiona:provisiona "$APP_DIR" "$PROV_DIR"

echo ">> Configurando TFTP (porta 69/udp)"
cat > /etc/default/tftpd-hpa <<CONF
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="$PROV_DIR"
TFTP_ADDRESS="0.0.0.0:69"
# --ipv4: sem isso o tftpd-hpa não sobe em servidores com IPv6 desativado.
# -v -v registra no syslog cada arquivo pedido (útil para descobrir o nome
# exato que cada modelo procura: journalctl -u tftpd-hpa -f)
TFTP_OPTIONS="--secure --ipv4 -v -v"
CONF
systemctl enable --now tftpd-hpa
systemctl restart tftpd-hpa

echo ">> Configurando HTTP (porta 80)"
cat > /etc/nginx/sites-available/provisionamento <<CONF
server {
    listen 80 default_server;
    server_name _;
    root $PROV_DIR;
    autoindex off;
    access_log /var/log/nginx/provisionamento.log;

    # Os arquivos têm senha SIP: só a rede dos telefones pode baixar.
    # (allow/deny gerados por provisiona-aplicar-rede a partir de REDE_TELEFONES)
    include /etc/nginx/provisionamento-rede.conf;

    location ~ /\. { deny all; }
    location / { try_files \$uri =404; default_type text/plain; }
}
CONF
rm -f /etc/nginx/sites-enabled/default
/usr/local/sbin/provisiona-aplicar-rede --forcar
ln -sf /etc/nginx/sites-available/provisionamento /etc/nginx/sites-enabled/provisionamento
nginx -t
systemctl enable --now nginx
systemctl reload nginx

if [ "$FTP" = sim ]; then
  echo ">> Configurando FTP anônimo só-leitura (porta 21)"
  cp -n /etc/vsftpd.conf /etc/vsftpd.conf.orig 2>/dev/null || true
  cat > /etc/vsftpd.conf <<CONF
listen=YES
listen_ipv6=NO
anonymous_enable=YES
anon_root=$PROV_DIR
no_anon_password=YES
local_enable=NO
write_enable=NO
anon_upload_enable=NO
anon_mkdir_write_enable=NO
dirlist_enable=NO
xferlog_enable=YES
pasv_min_port=40000
pasv_max_port=40100
secure_chroot_dir=/var/run/vsftpd/empty
xferlog_std_format=YES
xferlog_file=/var/log/vsftpd-provisionamento.log
CONF
  # o painel lê este log para mostrar downloads por FTP
  touch /var/log/vsftpd-provisionamento.log
  chown root:adm /var/log/vsftpd-provisionamento.log
  chmod 640 /var/log/vsftpd-provisionamento.log
  systemctl enable --now vsftpd
  systemctl restart vsftpd
fi

SENHA_MSG=""
if [ "$PAINEL" = sim ]; then
  echo ">> Configurando painel web (porta 8080)"
  if [ ! -f "$APP_DIR/painel.senha" ]; then
    SENHA_MSG="$(runuser -u provisiona -- python3 "$APP_DIR/painel/painel.py" --gerar-senha)"
  fi
  cat > /etc/systemd/system/provisiona-painel.service <<CONF
[Unit]
Description=Painel web do servidor de provisionamento
After=network-online.target

[Service]
User=provisiona
Group=provisiona
Environment=PAINEL_PORTA=8080
ExecStart=/usr/bin/python3 $APP_DIR/painel/painel.py
Restart=always
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$APP_DIR $PROV_DIR

[Install]
WantedBy=multi-user.target
CONF
  systemctl daemon-reload
  systemctl enable --now provisiona-painel
  systemctl restart provisiona-painel
fi

echo ">> Rede dos telefones: $REDE (nginx e ufw; trocar no painel em Configurações)"
# Quando provisiona.conf muda (ex.: painel salvou outra rede), o systemd
# roda provisiona-aplicar-rede como root, que atualiza nginx e ufw.
cat > /etc/systemd/system/provisiona-rede.service <<CONF
[Unit]
Description=Aplica a rede dos telefones (REDE_TELEFONES) no nginx e no ufw

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/provisiona-aplicar-rede
CONF
cat > /etc/systemd/system/provisiona-rede.path <<CONF
[Unit]
Description=Observa provisiona.conf para aplicar a rede dos telefones

[Path]
PathChanged=$APP_DIR/provisiona.conf
Unit=provisiona-rede.service

[Install]
WantedBy=multi-user.target
CONF
systemctl daemon-reload
systemctl enable --now provisiona-rede.path
/usr/local/sbin/provisiona-aplicar-rede --forcar

echo ">> Gravando opções em $OPCOES (usadas pelo provisiona-atualizar)"
cat > "$OPCOES" <<CONF
# Gerado por instalar_servidor.sh. Lido pelo instalador e por provisiona-atualizar.
REPO="$REPO"
BRANCH="$BRANCH"
FTP="$FTP"
PAINEL="$PAINEL"
AUTO_ATUALIZAR="$AUTO_ATUALIZAR"
CONF
chmod 644 "$OPCOES"

cat > /etc/systemd/system/provisiona-atualizar.service <<CONF
[Unit]
Description=Atualiza o servidor de provisionamento a partir do GitHub
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/provisiona-atualizar
CONF
cat > /etc/systemd/system/provisiona-atualizar.timer <<CONF
[Unit]
Description=Confere atualizações do servidor de provisionamento a cada 10 minutos

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
RandomizedDelaySec=60

[Install]
WantedBy=timers.target
CONF
systemctl daemon-reload
if [ "$AUTO_ATUALIZAR" = sim ]; then
  # sem --now: se esta instalação foi chamada pelo próprio timer, não se reinicia
  systemctl enable provisiona-atualizar.timer >/dev/null 2>&1
  systemctl start provisiona-atualizar.timer
  echo ">> Atualização automática LIGADA (a cada 10 min; desligar: --sem-auto-atualizar)"
else
  systemctl disable --now provisiona-atualizar.timer >/dev/null 2>&1 || true
fi

IP="$(hostname -I | awk '{print $1}')"
cat <<FIM

Pronto. Servidor de provisionamento em $IP
  TFTP: tftp://$IP/        HTTP: http://$IP/$( [ "$FTP" = sim ] && echo "        FTP: ftp://$IP/" )
  Arquivos:      $PROV_DIR
  Scripts:       $APP_DIR   (comando: provisiona)
  Atualizar:     sudo provisiona-atualizar$( [ "$AUTO_ATUALIZAR" = sim ] && echo "   (automático a cada 10 min: ligado)" )
$( [ "$PAINEL" = sim ] && echo "  Painel web:    http://$IP:8080/   usuário admin" )
$( [ -n "$SENHA_MSG" ] && echo "  $SENHA_MSG   (anote; trocar: sudo -u provisiona python3 $APP_DIR/painel/painel.py --definir-senha)" )

Próximos passos:
  1. No painel (Configurações), confira o IP do PABX e a rede dos telefones
  2. Aponte o DHCP da rede para este servidor (opção 66 = $IP). Veja $APP_DIR/dhcp/
  3. provisiona gerar tip235g 24fd0d350b0d 3310 4480 DIOMAI-CT
FIM

# provisiona-atualizar compara com isto para saber se há versão nova
mkdir -p /var/lib/provisionamento
git -C "$ORIGEM" rev-parse HEAD > /var/lib/provisionamento/versao-instalada 2>/dev/null \
  || rm -f /var/lib/provisionamento/versao-instalada

echo ">> Testando os serviços"
sleep 1
"$APP_DIR/provisiona.sh" testar || true
