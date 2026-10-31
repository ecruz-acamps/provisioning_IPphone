#!/usr/bin/env bash
# =====================================================================
#  instalar_servidor.sh - monta o servidor de provisionamento em um
#  Debian 12 / Ubuntu 22.04+ limpo (rodar como root).
#
#  Uso:  sudo ./instalar_servidor.sh [--rede "192.168.0.0/16 10.0.0.0/8"] [--sem-ftp] [--sem-painel]
#                                    [--repo URL] [--branch main] [--local]
#                                    [--auto-atualizar | --sem-auto-atualizar] [--sem-perguntas]
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
#
#  Rodando num terminal (inclusive via curl | sudo bash), o instalador
#  pergunta a rede dos telefones, o IP do PABX, o padrão de numeração e
#  oferece cadastrar os primeiros telefones. Enter mantém o valor entre
#  colchetes. Sem terminal (timer de atualização) ou com --sem-perguntas,
#  não pergunta nada e mantém o que já está salvo.
# =====================================================================
set -euo pipefail
REDE=""; FTP=sim; PAINEL=sim; AUTO_ATUALIZAR=nao; PERGUNTAR=sim; AUTO_INFORMADO=nao
PRIMEIRA_VEZ=sim
[ -f /etc/default/provisionamento ] && PRIMEIRA_VEZ=nao
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
    --auto-atualizar) AUTO_ATUALIZAR=sim; AUTO_INFORMADO=sim; shift ;;
    --sem-auto-atualizar) AUTO_ATUALIZAR=nao; AUTO_INFORMADO=sim; shift ;;
    --sem-perguntas) PERGUNTAR=nao; shift ;;
    *) echo "opção desconhecida: $1" >&2; exit 1 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "rode como root (sudo)" >&2; exit 1; }
case "$REDE" in *[!0-9A-Fa-f.:/,\ ]*) echo "--rede inválida: $REDE (ex.: 192.168.0.0/16)" >&2; exit 1 ;; esac
ORIGEM="$(cd "$(dirname "$(readlink -f "$0")")" 2>/dev/null && pwd || pwd)"
PROV_DIR=/srv/provisionamento
APP_DIR=/opt/provisionamento
# Só pergunta se houver um terminal (curl | bash lê as respostas de /dev/tty).
if [ "$PERGUNTAR" = sim ] && ! { : </dev/tty; } 2>/dev/null; then PERGUNTAR=nao; fi

# --- perguntas interativas ---------------------------------------------
# pergunta "texto" "padrão" -> imprime a resposta (Enter = padrão)
pergunta() {
  local resp
  # Ctrl-D / terminal fechado: encerra o instalador (senão os laços de validação não param)
  read -r -p "   $1${2:+ [$2]}: " resp </dev/tty || { echo >&2; echo "instalação interrompida" >&2; kill $$; exit 1; }
  printf '%s' "${resp:-$2}"
}
sim_nao() {   # sim_nao "texto" s|n  -> retorna 0 para sim
  local resp
  read -r -p "   $1 [$( [ "$2" = s ] && echo S/n || echo s/N )]: " resp </dev/tty || resp=""
  case "${resp:-$2}" in [sS]*) return 0 ;; *) return 1 ;; esac
}
conf_le() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}.*/\1/p" "$APP_DIR/provisiona.conf" | head -1; }
conf_grava() {
  local v="${2//&/\\&}"   # & tem significado no sed
  if grep -q "^$1=" "$APP_DIR/provisiona.conf"; then
    sed -i "s|^$1=.*|$1=\"$v\"|" "$APP_DIR/provisiona.conf"
  else
    printf '%s="%s"\n' "$1" "$2" >> "$APP_DIR/provisiona.conf"
  fi
}
valida_rede() { case "$1" in ""|*[!0-9A-Fa-f.:/,\ ]*) return 1 ;; esac; }
valida_host() {   # IPv4 (cada parte até 255), IPv6 ou nome DNS (172.20.1 não passa)
  local IFS=. p
  if [[ "$1" =~ ^[0-9.]+$ ]]; then
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    for p in $1; do [ "$p" -le 255 ] || return 1; done
    return 0
  fi
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.:-]*[A-Za-z0-9])?$ ]]
}

configurar_interativo() {
  local v
  echo
  echo ">> Configuração (Enter mantém o valor entre colchetes)"
  if [ -z "$REDE" ]; then
    while :; do
      v="$(pergunta "Rede dos telefones (quem pode baixar os arquivos; várias separadas por espaço)" "$(conf_le REDE_TELEFONES || true)")"
      v="$(printf '%s' "${v//,/ }" | tr -s ' ')"
      valida_rede "$v" && break
      echo "   rede inválida: use o formato 192.168.0.0/16"
    done
    REDE="$v"
  fi
  PABX_ANTES="$(conf_le SIP_SERVER)"
  while :; do
    v="$(pergunta "IP do PABX (servidor SIP onde os ramais registram)" "$PABX_ANTES")"
    valida_host "$v" && break
    echo "   endereço inválido (ex.: 172.20.1.18)"
  done
  conf_grava SIP_SERVER "$v"
  while :; do
    v="$(pergunta "Porta SIP do PABX" "$(conf_le SIP_PORT)")"
    [[ "$v" =~ ^[0-9]{1,5}$ ]] && [ "$v" -ge 1 ] && [ "$v" -le 65535 ] && break
    echo "   porta inválida"
  done
  conf_grava SIP_PORT "$v"
  echo "   Usuário SIP = prefixo do usuário + prefixo + ramal (ex.: 5541 + 3310 + 4480 = 554133104480)"
  while :; do
    v="$(pergunta "Prefixo do usuário SIP (- para nenhum)" "$(conf_le PREFIXO_USUARIO || true)")"
    [ "$v" = - ] && v=""
    [[ "$v" =~ ^[0-9]*$ ]] && break
    echo "   só números"
  done
  conf_grava PREFIXO_USUARIO "$v"
  while :; do
    v="$(pergunta "Prefixo padrão dos ramais (- para nenhum)" "$(conf_le PREFIXO_PADRAO || true)")"
    [ "$v" = - ] && v=""
    [[ "$v" =~ ^[0-9A-Za-z]*$ ]] && break
    echo "   só letras e números"
  done
  conf_grava PREFIXO_PADRAO "$v"
  while :; do
    v="$(pergunta "Título no display do TIP 235G (- para nenhum)" "$(conf_le LCD_TITULO || true)")"
    [ "$v" = - ] && v=""
    [[ ${#v} -le 32 && ! "$v" =~ [\"\`\$\\\|] ]] && break
    echo "   até 32 caracteres, sem aspas, \$, \\ ou |"
  done
  conf_grava LCD_TITULO "$v"
  while :; do
    v="$(pergunta "VLAN de voz do TIP 235G (- para não mexer na VLAN)" "$(conf_le VLAN_ID || true)")"
    [ "$v" = - ] && v=""
    [[ "$v" =~ ^[0-9]{0,4}$ ]] && break
    echo "   número da VLAN (1 a 4094) ou -"
  done
  conf_grava VLAN_ID "$v"
  if [ "$PRIMEIRA_VEZ" = sim ] && [ "$AUTO_INFORMADO" = nao ]; then
    if sim_nao "Atualizar sozinho pelo GitHub a cada 10 minutos?" s; then AUTO_ATUALIZAR=sim; else AUTO_ATUALIZAR=nao; fi
  fi
}

cadastrar_telefones() {
  local modelos modelo ultimo=tip235g mac prefixo ramal nome senha
  modelos="$(awk -F'|' '/^[[:space:]]*(#|$)/ { next } { gsub(/[[:space:]]/, "", $1); printf "%s ", $1 }' "$APP_DIR/modelos.conf")"
  echo
  echo ">> Telefones (também dá para cadastrar depois no painel, aba Ramais > + Novo ramal)"
  sim_nao "Cadastrar um telefone agora?" s || return 0
  while :; do
    while :; do
      modelo="$(pergunta "Modelo (${modelos% })" "$ultimo")"
      modelo="${modelo,,}"
      [[ " $modelos" == *" $modelo "* ]] && { ultimo="$modelo"; break; }
      echo "   modelo desconhecido"
    done
    while :; do
      mac="$(pergunta "MAC do telefone (etiqueta embaixo do aparelho)" "")"
      [[ "$(printf '%s' "$mac" | tr -d ':.\- ')" =~ ^[0-9A-Fa-f]{12}$ ]] && break
      echo "   MAC inválido (12 dígitos, ex.: 24:fd:0d:35:0b:0d)"
    done
    prefixo="$(pergunta "Prefixo (- para nenhum)" "${prefixo:-$(conf_le PREFIXO_PADRAO || true)}")"
    while ramal="$(pergunta "Ramal" "")"; [ -z "$ramal" ]; do echo "   informe o ramal"; done
    while nome="$(pergunta "Nome / setor" "")"; [ -z "$nome" ]; do echo "   informe o nome"; done
    senha="$(pergunta "Senha SIP (Enter = igual ao usuário)" "")"
    if "$APP_DIR/provisiona.sh" gerar "$modelo" "$mac" "${prefixo:--}" "$ramal" "$nome" ${senha:+"$senha"}; then
      echo "   ok: telefone cadastrado"
    else
      echo "   não deu certo (veja a mensagem acima)"
    fi
    sim_nao "Cadastrar outro telefone?" n || break
  done
}

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
PABX_ANTES=""
[ "$PERGUNTAR" = sim ] && configurar_interativo

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

# Os arquivos dos telefones levam o IP do PABX: se ele mudou, regera os já cadastrados.
if [ -n "$PABX_ANTES" ] && [ "$(conf_le SIP_SERVER)" != "$PABX_ANTES" ] && [ -s "$(conf_le RAMAIS_CSV)" ]; then
  echo ">> IP do PABX mudou: regerando os arquivos dos telefones"
  "$APP_DIR/provisiona.sh" regerar || true
fi
[ "$PERGUNTAR" = sim ] && cadastrar_telefones

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
  1. Painel http://$IP:8080/ > Configurações: confira o IP do PABX ($(conf_le SIP_SERVER)) e a rede dos telefones
  2. Painel > Ramais > "+ Novo ramal": modelo, MAC, ramal e nome de cada telefone
     (ou "Importar planilha" para vários de uma vez)
  3. Aponte o DHCP da rede para este servidor (opção 66 = $IP). Veja $APP_DIR/dhcp/
  Pelo terminal, o passo 2 é: provisiona gerar <modelo> <mac> <prefixo> <ramal> <nome>
FIM

# provisiona-atualizar compara com isto para saber se há versão nova
mkdir -p /var/lib/provisionamento
git -C "$ORIGEM" rev-parse HEAD > /var/lib/provisionamento/versao-instalada 2>/dev/null \
  || rm -f /var/lib/provisionamento/versao-instalada

echo ">> Testando os serviços"
sleep 1
"$APP_DIR/provisiona.sh" testar || true
