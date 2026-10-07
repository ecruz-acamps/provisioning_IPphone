#!/usr/bin/env bash
# Mesma chamada do script antigo:
#   create_modelo_125.sh <mac> <prefixo> <ramal> <nome>
#   ex.: create_modelo_125.sh 24fd0d350b0d 3310 4480 DIOMAI-CT
#   -> usuário SIP 554133104480, senha = usuário, nome "3310-4480 DIOMAI-CT"
[ $# -eq 4 ] || { echo "uso: $0 <mac> <prefixo> <ramal> <nome>" >&2; exit 1; }
exec "$(dirname "$(readlink -f "$0")")/provisiona.sh" gerar tip125 "$@"
