#!/usr/bin/env bash
# =====================================================================
#  importar_modelo.sh - transforma o backup de configuração de UM
#  telefone configurado à mão em template para o provisiona.sh.
#
#  Uso:
#    importar_modelo.sh <modelo> <arquivo_backup> --ramal 9876 \
#        --senha SenhaTeste9876 --nome NOMETESTE [--servidor 192.168.1.10]
#
#  Os valores informados são trocados por {{USUARIO}} (--ramal = usuário SIP),
#  {{SENHA}}, {{EXIBICAO}} (--nome = nome no display)
#  e {{SIP_SERVER}}. Use valores fáceis de achar (não "1000" ou "admin"),
#  e revise o resultado: o script mostra cada linha alterada.
# =====================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

erro() { echo "ERRO: $*" >&2; exit 1; }
[ $# -ge 2 ] || { sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
modelo="${1,,}"; origem="$2"; shift 2
ramal="" senha="" nome="" servidor=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ramal) ramal="$2"; shift 2 ;;
    --senha) senha="$2"; shift 2 ;;
    --nome) nome="$2"; shift 2 ;;
    --servidor) servidor="$2"; shift 2 ;;
    *) erro "opção desconhecida: $1" ;;
  esac
done
[ -f "$origem" ] || erro "arquivo não encontrado: $origem"
[ -n "$ramal" ] && [ -n "$senha" ] && [ -n "$nome" ] || erro "--ramal, --senha e --nome são obrigatórios"
if [ "$(tr -d '\000' < "$origem" | wc -c)" -ne "$(wc -c < "$origem")" ]; then
  erro "o backup é binário/criptografado; não dá para usar como template. Veja o README (seção 4, plano B)."
fi

tpl="$(awk -F'|' -v m="$modelo" '/^[[:space:]]*(#|$)/{next} {gsub(/[[:space:]]/,"",$1); gsub(/[[:space:]]/,"",$2)} $1==m {print $2}' "$SCRIPT_DIR/modelos.conf")"
[ -n "$tpl" ] || erro "modelo '$modelo' não está em modelos.conf"
destino="$SCRIPT_DIR/templates/$tpl"

# Ordem: valores mais longos primeiro, para um não "comer" o outro.
pares="$(printf '%s\t{{SENHA}}\n%s\t{{EXIBICAO}}\n%s\t{{SIP_SERVER}}\n%s\t{{USUARIO}}\n' "$senha" "$nome" "$servidor" "$ramal" \
  | awk -F'\t' '$1 != "" { print length($1) "\t" $0 }' | sort -rn | cut -f2-)"

PARES="$pares" awk '
  function troca(linha, de, para,    i, s) {
    s = ""
    while ((i = index(linha, de)) > 0) { s = s substr(linha, 1, i - 1) para; linha = substr(linha, i + length(de)) }
    return s linha
  }
  BEGIN { n = split(ENVIRON["PARES"], L, "\n"); for (j = 1; j <= n; j++) { split(L[j], p, "\t"); de[j] = p[1]; para[j] = p[2] } }
  { orig = $0; for (j = 1; j <= n; j++) $0 = troca($0, de[j], para[j]); if ($0 != orig) printf "  linha %d: %s\n", NR, $0 > "/dev/stderr"; print }
' "$origem" > "$destino.novo"

for marc in USUARIO SENHA EXIBICAO; do
  grep -qF "{{$marc}}" "$destino.novo" || echo "AVISO: {{$marc}} não apareceu no arquivo. O valor pode estar criptografado ou com outro formato; confira antes de usar." >&2
done
[ -f "$destino" ] && cp -f "$destino" "$destino.bak"
mv -f "$destino.novo" "$destino"
echo "Template salvo em $destino (o anterior ficou em $destino.bak)."
echo "Revise as linhas acima e teste com UM aparelho antes de gerar em lote."
