#!/usr/bin/env bash
# =====================================================================
#  provisiona.sh - gera arquivos de auto-provisionamento para telefones
#  IP Intelbras (TIP 235G, TIP 125i, TIP 120i, TIP 125).
#
#  Uso:
#    provisiona.sh gerar  <modelo> <mac> <prefixo> <ramal> <nome> [senha]
#    provisiona.sh lote   <arquivo.csv|->    # modelo;mac;prefixo;ramal;nome;senha
#    provisiona.sh regerar                    # recria tudo a partir de ramais.csv
#    provisiona.sh listar
#    provisiona.sh remover <mac>
#    provisiona.sh modelos
#    provisiona.sh testar [ip]                # testa HTTP, TFTP e FTP
#
#  Exemplo (equivalente ao antigo create_modelo_125i.sh 24fd0d350b0d 3310 4480 DIOMAI-CT):
#    provisiona.sh gerar tip125i 24fd0d350b0d 3310 4480 DIOMAI-CT
#    -> usuário SIP 554133104480, senha = usuário, nome "3310-4480 DIOMAI-CT"
#       (regras em provisiona.conf: PREFIXO_USUARIO, SENHA_PADRAO, FORMATO_NOME)
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Instalado com o painel web, os arquivos pertencem ao usuário "provisiona".
# Rodando como root, troca para ele (assim painel e terminal não brigam por permissão).
if [ "$(id -u)" -eq 0 ] && id provisiona >/dev/null 2>&1 && [ -z "${PROVISIONA_ROOT:-}" ]; then
  if [ "${1:-}" = lote ] && [ -n "${2:-}" ] && [ "$2" != - ]; then
    [ -r "$2" ] || { echo "ERRO: CSV não encontrado: $2" >&2; exit 1; }
    exec runuser -u provisiona -- "$SCRIPT_DIR/provisiona.sh" lote - < "$2"
  fi
  exec runuser -u provisiona -- "$SCRIPT_DIR/provisiona.sh" "$@"
fi

CONF="${PROVISIONA_CONF:-$SCRIPT_DIR/provisiona.conf}"
MODELOS_CONF="$SCRIPT_DIR/modelos.conf"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

erro()  { echo "ERRO: $*" >&2; exit 1; }
aviso() { echo "AVISO: $*" >&2; }

[ -f "$CONF" ] || erro "arquivo de configuração não encontrado: $CONF"
# shellcheck source=provisiona.conf
. "$CONF"
: "${SIP_SERVER:?defina SIP_SERVER em $CONF}"
: "${PROV_DIR:?defina PROV_DIR em $CONF}"
SIP_PORT="${SIP_PORT:-5060}"
SIP_REG_TTL="${SIP_REG_TTL:-90}"
NTP_SERVER="${NTP_SERVER:-a.ntp.br}"
NTP_SERVER2="${NTP_SERVER2:-}"
RAMAIS_CSV="${RAMAIS_CSV:-$SCRIPT_DIR/ramais.csv}"
ADMIN_PASS="${ADMIN_PASS:-}"
PREFIXO_USUARIO="${PREFIXO_USUARIO-5541}"
PREFIXO_PADRAO="${PREFIXO_PADRAO:-}"
SENHA_PADRAO="${SENHA_PADRAO:-usuario}"
[ -n "${FORMATO_NOME+x}" ] || FORMATO_NOME='{{PREFIXO}}-{{RAMAL}} {{NOME}}'
LCD_TITULO="${LCD_TITULO:-}"
VLAN_ID="${VLAN_ID:-}"
VLAN_DHCP_OPCAO="${VLAN_DHCP_OPCAO:-132}"

# --- modelos ----------------------------------------------------------
# Lê modelos.conf e devolve "template|arquivo|escape" do modelo pedido.
modelo_info() {
  local alvo="$1"
  awk -F'|' -v alvo="$alvo" '
    /^[[:space:]]*(#|$)/ { next }
    { for (i = 1; i <= NF; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) }
    tolower($1) == tolower(alvo) { print $2 "|" $3 "|" $4; achou = 1; exit }
    END { exit achou ? 0 : 1 }
  ' "$MODELOS_CONF"
}

listar_modelos() {
  awk -F'|' '/^[[:space:]]*(#|$)/ { next } { gsub(/[[:space:]]/, "", $1); print $1 }' "$MODELOS_CONF"
}

# --- validação --------------------------------------------------------
normaliza_mac() {
  local m
  m="$(printf '%s' "$1" | tr -d ':.\- ' | tr 'A-F' 'a-f')"
  [[ "$m" =~ ^[0-9a-f]{12}$ ]] || erro "MAC inválido: '$1' (esperado 12 dígitos hexadecimais, ex.: 24fd0d350b0d)"
  printf '%s' "$m"
}

valida_campos() {
  local ramal="$1" senha="$2" nome="$3"
  [[ "$ramal" =~ ^[0-9A-Za-z_.+-]+$ ]] || erro "ramal inválido: '$ramal'"
  [[ "$PREFIXO" =~ ^[0-9A-Za-z_.+-]*$ ]] || erro "prefixo inválido: '$PREFIXO'"
  [ -n "$senha" ] || erro "senha vazia para o ramal $ramal (informe a senha ou use SENHA_PADRAO=usuario)"
  [[ "$senha" != *$'\n'* && "$nome" != *$'\n'* ]] || erro "quebra de linha não permitida"
  [[ "$senha" != *";"* ]] || erro "a senha do ramal $ramal não pode conter ';' (separador do CSV)"
  [[ "$nome" != *";"* ]] || erro "o nome do ramal $ramal não pode conter ';' (separador do CSV)"
}

# --- geração ----------------------------------------------------------
# Substitui {{CHAVE}} pelos valores (de forma literal, sem regex).
# Linhas que começam com {{?CHAVE}} só saem se CHAVE não estiver vazia.
render() {
  local template="$1" escape="$2"
  P_MAC="$MAC" P_MAC_UPPER="$(printf '%s' "$MAC" | tr 'a-f' 'A-F')" \
  P_RAMAL="$RAMAL" P_SENHA="$SENHA" P_NOME="$NOME" \
  P_PREFIXO="$PREFIXO" P_USUARIO="$USUARIO" P_EXIBICAO="$EXIBICAO" \
  P_SIP_SERVER="$SIP_SERVER" P_SIP_PORT="$SIP_PORT" P_SIP_REG_TTL="$SIP_REG_TTL" \
  P_NTP_SERVER="$NTP_SERVER" P_NTP_SERVER2="$NTP_SERVER2" P_ADMIN_PASS="$ADMIN_PASS" \
  P_LCD_TITULO="$LCD_TITULO" P_VLAN_ID="$VLAN_ID" P_VLAN_DHCP_OPCAO="$VLAN_DHCP_OPCAO" \
  awk -v escape="$escape" '
    function esc(s) {
      if (escape != "xml") return s
      gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
      gsub(/"/, "\\&quot;", s); gsub(/\047/, "\\&apos;", s)
      return s
    }
    function troca(linha, de, para,    i, saida) {
      saida = ""
      while ((i = index(linha, de)) > 0) {
        saida = saida substr(linha, 1, i - 1) para
        linha = substr(linha, i + length(de))
      }
      return saida linha
    }
    BEGIN {
      n = split("MAC MAC_UPPER PREFIXO RAMAL USUARIO SENHA NOME EXIBICAO SIP_SERVER SIP_PORT SIP_REG_TTL NTP_SERVER NTP_SERVER2 ADMIN_PASS LCD_TITULO VLAN_ID VLAN_DHCP_OPCAO", k, " ")
      for (j = 1; j <= n; j++) v[k[j]] = esc(ENVIRON["P_" k[j]])
    }
    {
      sub(/\r$/, "")
      if (match($0, /^\{\{\?[A-Z0-9_]+\}\}/)) {
        chave = substr($0, 4, RLENGTH - 5)
        if (v[chave] == "") next
        $0 = substr($0, RLENGTH + 1)
      }
      for (j = 1; j <= n; j++) $0 = troca($0, "{{" k[j] "}}", v[k[j]])
      print
    }
  ' "$template"
}

# Monta usuário SIP, senha e nome exibido a partir de prefixo + ramal
# (mesmo padrão do servidor antigo: 5541 + 3310 + 4480 = 554133104480).
gerar() {
  local modelo="$1" info template arquivo escape destino tmp
  MAC="$(normaliza_mac "$2")"; PREFIXO="${3:-$PREFIXO_PADRAO}"; RAMAL="$4"; NOME="$5"; SENHA="${6:-}"
  [ "$PREFIXO" = - ] && PREFIXO=""
  USUARIO="${PREFIXO_USUARIO}${PREFIXO}${RAMAL}"
  if [ -z "$SENHA" ] && [ "$SENHA_PADRAO" = usuario ]; then SENHA="$USUARIO"; fi
  EXIBICAO="${FORMATO_NOME//\{\{PREFIXO\}\}/"$PREFIXO"}"
  EXIBICAO="${EXIBICAO//\{\{RAMAL\}\}/"$RAMAL"}"
  EXIBICAO="${EXIBICAO//\{\{NOME\}\}/"$NOME"}"
  EXIBICAO="$(printf '%s' "$EXIBICAO" | sed 's/^[ -]*//; s/[ ]*$//')"
  valida_campos "$RAMAL" "$SENHA" "$NOME"

  info="$(modelo_info "$modelo")" || erro "modelo desconhecido: '$modelo' (disponíveis: $(listar_modelos | tr '\n' ' '))"
  IFS='|' read -r template arquivo escape <<<"$info"
  template="$TEMPLATES_DIR/$template"
  [ -f "$template" ] || erro "template não encontrado: $template"
  if grep -q '^MODELO_NAO_IMPORTADO' "$template"; then
    erro "o template do $modelo ainda não foi importado de um aparelho real. Veja $template e o README, seção 4."
  fi

  arquivo="${arquivo//\{\{mac\}\}/$MAC}"
  arquivo="${arquivo//\{\{MAC\}\}/$(printf '%s' "$MAC" | tr 'a-f' 'A-F')}"
  destino="$PROV_DIR/$arquivo"

  mkdir -p "$PROV_DIR"
  tmp="$(mktemp "$PROV_DIR/.tmp.XXXXXX")"
  render "$template" "${escape:-none}" > "$tmp"
  if grep -q '{{' "$tmp"; then
    aviso "sobrou marcador não substituído em $destino: $(grep -o '{{[^}]*}}' "$tmp" | sort -u | tr '\n' ' ')"
  fi
  chmod 644 "$tmp"
  mv -f "$tmp" "$destino"
  # Se o aparelho mudou de modelo, apaga o arquivo antigo dele (outro nome/extensão).
  local outro
  while read -r outro; do
    outro="$(modelo_info "$outro" | cut -d'|' -f2)"
    outro="${outro//\{\{mac\}\}/$MAC}"
    outro="${outro//\{\{MAC\}\}/$(printf '%s' "$MAC" | tr 'a-f' 'A-F')}"
    if [ "$PROV_DIR/$outro" != "$destino" ]; then rm -f "$PROV_DIR/$outro"; fi
  done < <(listar_modelos)
  echo "OK  $modelo  $MAC  ramal $RAMAL  usuário $USUARIO  \"$EXIBICAO\"  ->  $destino"
}

# --- planilha mestre --------------------------------------------------
# Colunas: modelo;mac;prefixo;ramal;nome;senha  (senha vazia = regra SENHA_PADRAO)
registra_csv() {
  local modelo="$1" mac="$2" prefixo="$3" ramal="$4" nome="$5" senha="${6:-}" tmp
  mkdir -p "$(dirname "$RAMAIS_CSV")"
  [ -f "$RAMAIS_CSV" ] || echo "modelo;mac;prefixo;ramal;nome;senha" > "$RAMAIS_CSV"
  tmp="$(mktemp)"
  awk -F';' -v mac="$mac" 'NR == 1 || tolower($2) != mac' "$RAMAIS_CSV" > "$tmp"
  printf '%s;%s;%s;%s;%s;%s\n' "$modelo" "$mac" "$prefixo" "$ramal" "$nome" "$senha" >> "$tmp"
  cat "$tmp" > "$RAMAIS_CSV"; rm -f "$tmp"
  chmod 600 "$RAMAIS_CSV"
}

# Lê um CSV (separador ';' ou ',') e chama gerar para cada linha.
processa_csv() {
  local csv="$1" registrar="$2" sep linha n=0 falhas=0
  [ "$csv" = - ] && csv=/dev/stdin
  [ -r "$csv" ] || erro "CSV não encontrado: $csv"
  while IFS= read -r linha || [ -n "$linha" ]; do
    linha="${linha%$'\r'}"
    [[ -z "${linha//[[:space:]]/}" || "$linha" == \#* ]] && continue
    if [[ "$linha" == *";"* ]]; then sep=';'; else sep=','; fi
    IFS="$sep" read -r modelo mac prefixo ramal nome senha <<<"$linha"
    [[ "${modelo,,}" == "modelo" ]] && continue
    n=$((n + 1))
    if ( gerar "$modelo" "$mac" "$prefixo" "$ramal" "$nome" "$senha" ); then
      [ "$registrar" = sim ] && registra_csv "${modelo,,}" "$(normaliza_mac "$mac")" "${prefixo:-$PREFIXO_PADRAO}" "$ramal" "$nome" "$senha"
    else
      falhas=$((falhas + 1))
    fi
  done < "$csv"
  echo "---- $n linha(s) processada(s), $falhas falha(s)"
  [ "$falhas" -eq 0 ]
}

remover() {
  local mac info arquivo tmp
  mac="$(normaliza_mac "$1")"
  while read -r modelo; do
    info="$(modelo_info "$modelo")"
    IFS='|' read -r _ arquivo _ <<<"$info"
    arquivo="${arquivo//\{\{mac\}\}/$mac}"
    arquivo="${arquivo//\{\{MAC\}\}/$(printf '%s' "$mac" | tr 'a-f' 'A-F')}"
    [ -f "$PROV_DIR/$arquivo" ] && rm -f "$PROV_DIR/$arquivo" && echo "removido $PROV_DIR/$arquivo"
  done < <(listar_modelos)
  if [ -f "$RAMAIS_CSV" ]; then
    tmp="$(mktemp)"
    awk -F';' -v mac="$mac" 'NR == 1 || tolower($2) != mac' "$RAMAIS_CSV" > "$tmp"
    cat "$tmp" > "$RAMAIS_CSV"; rm -f "$tmp"
  fi
}

# Baixa um arquivo de teste pelos três protocolos, como um telefone faria.
testar() {
  local host="${1:-127.0.0.1}" arq="teste-provisionamento.txt" token proto url obtido falhas=0
  command -v curl >/dev/null || erro "instale o curl para testar (apt install curl)"
  token="ok-$(date +%s)-$$"
  printf '%s\n' "$token" > "$PROV_DIR/$arq"; chmod 644 "$PROV_DIR/$arq"
  echo "(arquivo temporário só para o teste, apagado no fim; os telefones recebem .xml ou .cfg)"
  for proto in HTTP TFTP FTP; do
    url="${proto,,}://$host/$arq"
    obtido="$(curl -s --noproxy '*' -m 6 "$url" 2>/dev/null | tr -d '\r' || true)"
    if [ "$obtido" = "$token" ]; then
      printf '%-5s OK     %s\n' "$proto" "$url"
    else
      printf '%-5s FALHA  %s\n' "$proto" "$url"; falhas=$((falhas + 1))
    fi
  done
  rm -f "$PROV_DIR/$arq"
  [ "$falhas" -eq 0 ]
}

uso() { sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# --- main -------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  gerar)
    [ $# -eq 5 ] || [ $# -eq 6 ] || uso 1
    gerar "$@"
    registra_csv "${1,,}" "$MAC" "$PREFIXO" "$4" "$5" "${6:-}"
    ;;
  lote)    [ $# -eq 1 ] || uso 1; processa_csv "$1" sim ;;
  regerar) processa_csv "$RAMAIS_CSV" nao ;;
  listar)
    [ -f "$RAMAIS_CSV" ] || erro "nenhum ramal cadastrado ainda ($RAMAIS_CSV)"
    awk -F';' 'NR > 1 { printf "%-8s %-13s %-5s %-6s %s\n", $1, $2, $3, $4, $5 }' "$RAMAIS_CSV" | sort -k4
    ;;
  remover) [ $# -eq 1 ] || uso 1; remover "$1" ;;
  modelos) listar_modelos ;;
  testar)  testar "${1:-}" ;;
  -h|--help|help|"") uso 0 ;;
  *) erro "comando desconhecido: $cmd (use --help)" ;;
esac
