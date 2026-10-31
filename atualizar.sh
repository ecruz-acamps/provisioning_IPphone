#!/usr/bin/env bash
# =====================================================================
#  atualizar.sh - atualiza o servidor para a versão mais nova do GitHub.
#  Instalado como /usr/local/sbin/provisiona-atualizar (rodar como root).
#
#  Uso:  sudo provisiona-atualizar            # atualiza se houver versão nova
#        sudo provisiona-atualizar --forcar   # reinstala mesmo sem mudança
#        sudo provisiona-atualizar --verificar # só diz se há versão nova
#
#  Usa o repositório/branch e as opções (--sem-ftp, --sem-painel) gravados
#  pelo instalador em /etc/default/provisionamento. Mantém provisiona.conf,
#  ramais.csv, a senha do painel e os templates, como o instalador.
#  Com "instalar_servidor.sh --auto-atualizar", o timer systemd
#  provisiona-atualizar.timer roda isto a cada 10 minutos.
# =====================================================================
set -euo pipefail
OPCOES=/etc/default/provisionamento
SRC_DIR=/opt/provisionamento-src
MODO="${1:-}"

[ "$(id -u)" -eq 0 ] || { echo "rode como root (sudo)" >&2; exit 1; }
[ -f "$OPCOES" ] || { echo "$OPCOES não encontrado: rode o instalar_servidor.sh uma vez" >&2; exit 1; }
# shellcheck source=/dev/null
. "$OPCOES"
: "${REPO:?REPO não definido em $OPCOES}" "${BRANCH:=main}"

if [ ! -d "$SRC_DIR/.git" ]; then
  rm -rf "$SRC_DIR"
  git clone -q --depth 1 --branch "$BRANCH" "$REPO" "$SRC_DIR"
  MODO=--forcar
fi
git -C "$SRC_DIR" remote set-url origin "$REPO"
git -C "$SRC_DIR" fetch -q --depth 1 origin "$BRANCH"
# versão que o instalador terminou de instalar (se ele falhou no meio, tenta de novo)
atual="$(cat /var/lib/provisionamento/versao-instalada 2>/dev/null || true)"
novo="$(git -C "$SRC_DIR" rev-parse FETCH_HEAD)"

if [ "$atual" = "$novo" ] && [ "$MODO" != --forcar ]; then
  echo "Já está na versão mais nova: $(git -C "$SRC_DIR" log -1 --format='%h %cd %s' --date=short)"
  exit 0
fi
if [ "$MODO" = --verificar ]; then
  echo "Versão nova disponível: $(git -C "$SRC_DIR" log -1 --format='%h %cd %s' --date=short FETCH_HEAD)"
  exit 0
fi

git -C "$SRC_DIR" reset -q --hard FETCH_HEAD
echo ">> Atualizando para $(git -C "$SRC_DIR" log -1 --format='%h %cd %s' --date=short)"
# O instalador novo (não o que estava rodando) faz o resto, a partir da cópia já baixada.
exec bash "$SRC_DIR/instalar_servidor.sh" --local --sem-perguntas
