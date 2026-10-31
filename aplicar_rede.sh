#!/usr/bin/env bash
# =====================================================================
#  aplicar_rede.sh - aplica REDE_TELEFONES (provisiona.conf) no nginx
#  e no ufw. Roda como root.
#
#  O instalador copia este script para /usr/local/sbin/provisiona-aplicar-rede
#  (dono root) e cria a unidade systemd provisiona-rede.path, que roda o
#  script sempre que provisiona.conf muda. Assim o painel web (que roda sem
#  root) só grava a rede no provisiona.conf e o systemd aplica.
#
#  O provisiona.conf pertence ao usuário do painel, por isso este script NÃO
#  faz "source" dele: só lê a linha REDE_TELEFONES e valida cada rede.
#
#  Uso:  sudo provisiona-aplicar-rede [--forcar]
# =====================================================================
set -euo pipefail
CONF="${PROVISIONA_CONF:-/opt/provisionamento/provisiona.conf}"
NGINX_REDE=/etc/nginx/provisionamento-rede.conf
ESTADO_DIR=/var/lib/provisionamento-rede
APLICADA="$ESTADO_DIR/aplicada"
STATUS="$ESTADO_DIR/status"
FORCAR=nao; [ "${1:-}" = --forcar ] && FORCAR=sim

[ "$(id -u)" -eq 0 ] || { echo "rode como root (sudo)" >&2; exit 1; }
mkdir -p "$ESTADO_DIR"; chmod 755 "$ESTADO_DIR"

# status lido pelo painel: uma linha "ok|erro <quando> <rede ou mensagem>"
status() {
  local tmp; tmp="$(mktemp "$ESTADO_DIR/.status.XXXXXX")"
  printf '%s %s %s\n' "$1" "$(date +%s)" "$2" > "$tmp"
  chmod 644 "$tmp"; mv -f "$tmp" "$STATUS"
}
falha() { status erro "$*"; echo "ERRO: $*" >&2; exit 1; }

[ -f "$CONF" ] || falha "provisiona.conf não encontrado"
linha="$(grep -m1 -E '^[[:space:]]*REDE_TELEFONES=' "$CONF" || true)"
[ -n "$linha" ] || falha "REDE_TELEFONES não definido em provisiona.conf"
bruto="$(printf '%s' "${linha#*=}" | tr -d '"'"'" | tr ',;' '  ')"

# valida e normaliza com o próprio Python (ipaddress); qualquer erro = nada muda
REDES="$(python3 -I - "$bruto" <<'PY'
import ipaddress, sys
itens = sys.argv[1].split()
if not itens or len(itens) > 32:
    sys.exit(1)
try:
    print(" ".join(str(ipaddress.ip_network(i, strict=False)) for i in itens))
except ValueError:
    sys.exit(1)
PY
)" || falha "REDE_TELEFONES inválido (use redes como 192.168.0.0/16, separadas por espaço)"

anterior="$(cat "$APLICADA" 2>/dev/null || true)"
if [ "$REDES" = "$anterior" ] && [ "$FORCAR" = nao ] && [ -f "$NGINX_REDE" ]; then
  exit 0   # provisiona.conf mudou, mas não a rede
fi

# --- nginx: arquivo incluído pelo site "provisionamento" ---------------
copia=""
[ -f "$NGINX_REDE" ] && { copia="$(mktemp)"; cp "$NGINX_REDE" "$copia"; }
{
  echo "# Gerado por provisiona-aplicar-rede a partir de REDE_TELEFONES. Não edite."
  for r in $REDES; do echo "allow $r;"; done
  echo "allow 127.0.0.1;"
  echo "deny all;"
} > "$NGINX_REDE"
if command -v nginx >/dev/null; then
  if ! nginx -t -q 2>/dev/null; then
    if [ -n "$copia" ]; then cp "$copia" "$NGINX_REDE"; else rm -f "$NGINX_REDE"; fi
    rm -f "$copia"
    falha "nginx recusou a configuração; rede anterior mantida"
  fi
  systemctl reload nginx 2>/dev/null || true
fi
rm -f "$copia"

# --- ufw (só se estiver ativo) -----------------------------------------
regras_ufw() {   # $1 = rede; imprime uma regra por linha
  echo "from $1 to any port 69 proto udp"
  echo "from $1 to any port 80 proto tcp"
  [ -f /etc/vsftpd.conf ] && systemctl is-enabled -q vsftpd 2>/dev/null && echo "from $1 to any port 21,40000:40100 proto tcp"
  [ -f /etc/systemd/system/provisiona-painel.service ] && echo "from $1 to any port 8080 proto tcp"
  return 0
}
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  for r in $REDES; do
    regras_ufw "$r" | while read -r regra; do ufw allow $regra >/dev/null; done
  done
  for r in $anterior; do
    case " $REDES " in *" $r "*) continue ;; esac
    regras_ufw "$r" | while read -r regra; do ufw delete allow $regra >/dev/null || true; done
  done
fi

echo "$REDES" > "$APLICADA"
status ok "$REDES"
echo "Rede dos telefones aplicada: $REDES"
