# Servidor de auto-provisionamento – Telefones IP Intelbras

Substitui o antigo `create_modelo_125i.sh`. Modelos: **TIP 235G, TIP 125i, TIP 120i e TIP 125**.

```
create_modelo_125i.sh 24fd0d350b0d 3310 4480 DIOMAI-CT
                      └ MAC        └pref└ramal└ nome / setor
```

Mesmo padrão dos aparelhos atuais da UTFPR (confirmado no backup de um TIP 235G):

| Campo no telefone | Valor gerado | Regra (`provisiona.conf`) |
|---|---|---|
| Usuário SIP / número / autenticação | `554133104480` | `PREFIXO_USUARIO` (5541) + prefixo + ramal |
| Senha SIP | `554133104480` | `SENHA_PADRAO="usuario"` (senha = usuário) |
| Nome no display | `3310-4480 DIOMAI-CT` | `FORMATO_NOME` |
| PABX | `172.20.1.18:5060`, registro a cada 90 s | `SIP_SERVER`, `SIP_REG_TTL` |

No TIP 235G também vão: proxy = PABX, User Agent `4480 DIOMAI-CT`, Vendor Class ID
`VOIP-4480-DIOMAI-CT`, título `UTFPR`, VLAN de voz 990 (opção 132 do DHCP), NTP 200.189.40.8 /
200.160.0.8 e fuso UTC-3, todos iguais ao backup. Para um ramal com senha diferente, informe a senha
na 6ª coluna da planilha ou no painel.

---

## 1. Como funciona

```
 ┌──────────┐  1. liga e pede IP   ┌──────────────┐
 │ Telefone │ ───────────────────▶ │ DHCP da rede │  entrega IP + opção 66 = IP do servidor
 │  (MAC)   │ ◀─────────────────── └──────────────┘
 │          │  2. baixa <mac>.cfg  ┌──────────────────────────┐
 │          │ ───────────────────▶ │ Servidor de provisioname.│  TFTP :69  /  HTTP :80  /  FTP :21
 │          │ ◀─────────────────── │ /srv/provisionamento     │  arquivos gerados pelo provisiona.sh
 │          │  3. registra no PABX └──────────────────────────┘
 └──────────┘ ───────────────────▶  PABX / servidor SIP
```

O técnico só roda **um comando por telefone** (ou importa uma planilha). O aparelho, ao ligar,
baixa sozinho o arquivo com o próprio MAC e registra o ramal.

## 2. Conteúdo da pasta

| Arquivo | Para quê |
|---|---|
| `provisiona.sh` | Script principal: gerar, lote (CSV), regerar, listar, remover |
| `create_modelo_125i.sh`, `_120i`, `_125`, `_235g` | Mesma chamada do script antigo (4 parâmetros) |
| `provisiona.conf` | IP do PABX, rede dos telefones, porta, NTP, pasta servida, senha admin (opcional) |
| `aplicar_rede.sh` | Aplica a rede dos telefones no nginx e no ufw (instalado como `provisiona-aplicar-rede`, roda como root) |
| `modelos.conf` | Modelo → template → nome do arquivo que o telefone pede |
| `templates/tip235g.cfg` | Template pronto do TIP 235G (formato documentado pela Intelbras) |
| `templates/tip120i.xml`, `tip125i.xml`, `tip125.xml` | Templates XML no formato oficial da Intelbras (seção 4) |
| `docs-intelbras/` | Manual oficial de autoprovisionamento TIP 120i/125i e os templates XML de referência (Basic e Full) |
| `importar_modelo.sh` | Opcional: transforma o backup de um telefone configurado à mão em template |
| `instalar_servidor.sh` | Baixa o projeto do GitHub e instala TFTP + HTTP + FTP e o painel web num Debian/Ubuntu |
| `painel/` | Painel web de gerenciamento (Python 3, sem dependências), porta 8080 |
| `dhcp/` | Exemplos da opção 66: dnsmasq, ISC dhcpd, MikroTik, Windows Server |
| `ramais_exemplo.csv` | Modelo de planilha para cadastro em lote |

## 3. Instalação do servidor

Qualquer máquina Linux pequena na rede dos telefones serve (VM, mini PC, Raspberry Pi) com
**Debian 12 ou Ubuntu 22.04/24.04** e IP fixo.

```bash
# instala direto do GitHub (precisa de acesso à internet no servidor):
curl -fsSL https://raw.githubusercontent.com/ecruz-acamps/provisioning_IPphone/main/instalar_servidor.sh \
  | sudo bash -s -- --rede 192.168.0.0/16                  # rede dos telefones
#   (--sem-ftp pula o FTP; --sem-painel pula o painel web)
```

Depois, abra o painel (`http://IP-do-servidor:8080`) em **Configurações › PABX e rede dos
telefones** e confira o **IP do PABX** e a **rede dos telefones**. Os dois podem ser trocados ali a
qualquer momento, sem terminal:

- trocar o PABX recria na hora os arquivos de todos os telefones (cada um pega ao reiniciar);
- trocar a rede atualiza o nginx (quem pode baixar os arquivos) e, se o `ufw` estiver ativo, as
  portas liberadas. O painel mostra "aplicada" quando o servidor terminou. Aceita várias redes
  separadas por espaço. Se a nova rede não incluir o seu computador, o painel avisa antes, porque
  com `ufw` ativo ele deixaria de abrir.

Pelo terminal continua valendo: edite `SIP_SERVER` / `REDE_TELEFONES` em
`/opt/provisionamento/provisiona.conf`, depois `provisiona regerar` (PABX) ou
`sudo provisiona-aplicar-rede` (rede).

O instalador clona o repositório em `/opt/provisionamento-src` e instala a partir dele.
**Para atualizar**, rode o mesmo comando de novo: ele baixa a versão mais nova do GitHub e
mantém `provisiona.conf`, `ramais.csv`, a senha do painel e os templates já existentes.

Outras formas:
- repositório privado ou fork: `git clone` com suas credenciais e rode
  `sudo bash instalar_servidor.sh --repo https://github.com/OUTRO/repo.git --branch main`;
- servidor sem internet: copie a pasta e rode `sudo bash instalar_servidor.sh --local --rede ...`.

O instalador:
- instala **os três servidores**, `tftpd-hpa` (TFTP), `nginx` (HTTP) e `vsftpd` (FTP anônimo
  só-leitura), servindo a **mesma pasta** `/srv/provisionamento`;
- no fim, roda `provisiona testar`, que baixa um arquivo de teste pelos três e mostra OK/FALHA;
- liga o log do TFTP (`journalctl -u tftpd-hpa -f`) e do HTTP (`/var/log/nginx/provisionamento.log`), que mostram **o nome exato do arquivo que cada telefone pede**;
- bloqueia o HTTP para fora da rede informada e não lista a pasta (os arquivos têm senha SIP);
- cria os comandos `provisiona` e `create_modelo_*.sh` em `/usr/local/bin`.

**DHCP (opção 66):** o instalador não mexe no DHCP. Configure no roteador/servidor DHCP da rede a
opção 66 com o IP do servidor de provisionamento — exemplos prontos em `dhcp/`.
Sem acesso ao DHCP, dá para apontar cada telefone manualmente uma vez (seção 6).

## 3.1 Três protocolos: o que isso garante

Os três serviços entregam os mesmos arquivos, então **qualquer telefone funciona com o protocolo
que estiver configurado nele**: TFTP (padrão de fábrica com a opção 66), HTTP, ou FTP (como o
servidor antigo). Cadastrar o ramal uma vez vale para os três.

Atenção: cada telefone usa **um** protocolo por vez, o que estiver configurado nele. Ele não tenta
o próximo sozinho se aquele falhar. Por isso, a troca de protocolo é feita num lugar só:

| Se este falhar | Faça | Efeito |
|---|---|---|
| TFTP | Mude a opção 66 do DHCP de `192.168.1.20` para `http://192.168.1.20` | Todos os telefones passam a usar HTTP no próximo boot |
| HTTP | Volte a opção 66 para só o IP (`192.168.1.20`) | Todos voltam para TFTP |
| Telefone configurado à mão | Mude o protocolo na página web dele (*Atualizações > Autoprovisionamento*) | Só aquele aparelho |

**Como saber se algum caiu:**
- No servidor: `provisiona testar` (ou `provisiona testar 192.168.1.20` para testar pelo IP da rede).
- No painel: o topo mostra `HTTP ✓ TFTP ✓ FTP ✓`. Clique para testar de novo.

## 4. Templates por modelo

### TIP 235G — pronto
Formato `.cfg` texto documentado no *Manual de Auto Provisionamento TIP 235G/435G/638V* da Intelbras
(cabeçalho `<<VOIP CONFIG FILE>>`, seção `<SIP CONFIG MODULE>`, `SIP1 Register User`, etc.).
Arquivo por aparelho: `<mac em minúsculas>.cfg` (ex.: `24fd0d350b0d.cfg`).

### TIP 120i, TIP 125i e TIP 125 — pronto (XML oficial)
Baseado no manual *Auto provisionamento nos Telefones IP TIP120i e TIP125i* e no
`templateBasicTIP120/125.xml` da Intelbras (cópias em `docs-intelbras/`):

- O telefone pede **`<MAC EM MAIÚSCULAS>.xml`** (ex.: `24FD0D350B0D.xml`) e, antes, um arquivo comum
  opcional `tip120system.xml` / `tip125system.xml`. O painel mostra esse arquivo comum como
  "não encontrado" na Atividade; é normal e não atrapalha.
- Raiz `<autoprovisioning>`; o ramal vai em `PhoneNumber` e `AuthUserName`, a senha em
  `AuthPassword`, o nome em `CallerIDName`, o PABX em `ServerAddress`/`ServerPort`.
- O arquivo só altera as tags que contém. Para mudar mais coisas (codecs, volumes, plano de
  discagem, códigos de serviço), copie as tags desejadas do `templateFull*.xml` para
  `templates/tip1xx.xml` usando `{{RAMAL}}`, `{{SENHA}}`, `{{NOME}}`, `{{SIP_SERVER}}` onde couber.
- De fábrica o aparelho vem com protocolo "dhcp": lê a opção 66 e usa TFTP, ou HTTP/HTTPS se a opção
  66 trouxer a URL (`http://192.168.1.20`).
- O TIP 125 antigo (firmware 2.9.x) usa o mesmo template do 125i; confirme num aparelho.

**Template próprio (opcional):** para copiar a configuração exata de um aparelho já ajustado,
use a aba Modelos do painel ou `importar_modelo.sh` com o backup dele
(*Atualizações > Restaurar > Backup*), configurado com ramal 9876, senha SenhaTeste9876 e
nome NOMETESTE. O script troca esses valores pelos marcadores e mostra cada linha alterada.
Só funciona com backup em texto: o do TIP 235G (exportação TXT) serve; os `.db` do TIP 120i/125i/125
são criptografados e o script recusa.

### Padrão UTFPR em todos os modelos

Tudo que o 235G do backup usa e que o XML do TIP 120i/125i/125 aceita foi copiado:

| Item | TIP 235G | TIP 120i / 125i / 125 |
|---|---|---|
| Usuário, senha, nome no display, PABX, registro 90 s | ✓ | ✓ |
| Codecs G729 → G711U → G711A (G722/G726 desligados) | ✓ | ✓ |
| DTMF RFC2833 payload 101 | ✓ | ✓ |
| Rport, PRACK, user=phone | ✓ | ✓ |
| Chamada em espera desligada, MWI desligado, sem bloqueio de anônimas | ✓ | ✓ |
| "#" não finaliza discagem (disca por tempo) | ✓ | ✓ |
| Portas RTP 10000–10199 | (já no aparelho) | ✓ |
| VLAN 990, NTP, fuso UTC-3, título "UTFPR", Vendor Class ID | ✓ | ✗ o XML não tem esses campos |

Para o 120i/125i/125, os itens da última linha vêm da rede: NTP pela opção 42 do DHCP, e VLAN de voz
configurada no aparelho (página web, menu Rede/VLAN, VLAN automática por DHCP com a opção 132, como
o 235G). O título "UTFPR" e o Vendor Class ID não existem nesses modelos.

## 5. O que validar em um aparelho real (antes de usar em produção)

Nada disto pôde ser testado sem um telefone. Faça com **um aparelho de cada modelo**:

- [ ] **Nome do arquivo pedido.** Ligue o telefone com a opção 66 apontada e veja na aba Atividade
      do painel (ou `journalctl -u tftpd-hpa -f`) qual arquivo ele pede. Esperado: `24FD0D350B0D.xml`
      no 120i/125i/125 (pelo manual oficial) e `24fd0d350b0d.cfg` no 235G. Se for outro, corrija a
      3ª coluna de `modelos.conf`.
- [ ] **TIP 125 antigo (fw 2.9.x).** Confirme que aceita o mesmo XML do 125i.
- [ ] **TIP 235G – cabeçalho.** Exporte a config do aparelho (web: *Sistema > Configurações*,
      exportar TXT) e compare a 1ª linha com `templates/tip235g.cfg` (`<<VOIP CONFIG FILE>>Version:2.0002`).
      Se o seu firmware usar outra versão no cabeçalho, copie a dele.
- [ ] **Opção 66 x configuração manual.** Confirme que o aparelho, de fábrica, busca o servidor pela
      opção 66. No 235G pode ser preciso ativar "DHCP opção 66" ou PnP no menu de auto provisionamento.
- [ ] **Protocolo.** 120i/125i/125: o manual cita TFTP, HTTP e HTTPS (FTP não aparece). O padrão
      de fábrica é ler a opção 66 e usar TFTP. Teste também com a opção 66 = `http://IP` para ter
      o plano B validado (seção 3.1).
- [ ] **Registro.** Depois do download, o ramal registra no PABX e o nome aparece no display.
- [ ] **Reprovisionamento.** Altere algo no arquivo, reinicie o telefone e veja se aplica
      (modo "Ao ligar" ou "Repetidamente" no aparelho).
- [ ] **VLAN 990 num aparelho novo (235G).** O arquivo liga a VLAN 990 como nos aparelhos atuais.
      Confirme que a porta do switch entrega a VLAN de voz; senão deixe `VLAN_ID` vazio.
- [ ] **TIP 120i/125i/125.** O backup deles (.db) é criptografado, então o padrão de usuário/senha
      foi copiado do 235G. Confira se registram igual.

## 6. Uso diário

```bash
# um telefone (mesma chamada de antes)
create_modelo_125i.sh 24fd0d350b0d 3310 4480 DIOMAI-CT
# ou
provisiona gerar tip235g 24:FD:0D:35:0B:0D 3310 4999 COGETI-CT   # MAC aceita : - . ou nada
provisiona gerar tip125i 24fd0d350b0f 3310 4700 RH MinhaSenha     # 6º parâmetro opcional: senha

# vários telefones de uma vez (CSV do Excel, separador ; ou ,)
provisiona lote ramais_obra_x.csv        # colunas: modelo;mac;prefixo;ramal;nome;senha

provisiona listar                          # o que está cadastrado (sem senhas)
provisiona remover 24fd0d350b0d            # apaga arquivo e cadastro
provisiona testar                          # confere HTTP, TFTP e FTP
provisiona regerar                         # recria TODOS os arquivos a partir de ramais.csv
                                           # (use após mudar o IP do PABX ou um template)
```

Todo telefone gerado entra em `/opt/provisionamento/ramais.csv` (planilha mestre).

**Apontar o telefone manualmente** (se não houver opção 66): página web do aparelho >
*Atualizações > Autoprovisionamento* (120i/125i/125) ou menu de auto provisionamento
(235G): habilitar servidor, protocolo HTTP ou TFTP, servidor = IP do servidor, "Ao ligar".

## 6.1 Painel web

O instalador já sobe o painel em **http://IP-do-servidor:8080** (usuário `admin`; a senha
aparece no fim da instalação). Pelo navegador, inclusive no celular, dá para:

- **Ramais:** listar, buscar, cadastrar, editar (inclusive trocar o MAC de um aparelho), remover,
  ver o arquivo gerado e quando cada telefone baixou a configuração pela última vez;
- **Importar planilha:** colar ou escolher um CSV do Excel com vários telefones;
- **Modelos:** ver quais templates estão prontos e importar o backup de um TIP 120i/125i/125;
- **Atividade:** cada download por HTTP, TFTP ou FTP, com o nome exato do arquivo que o aparelho pediu
  (é aqui que se confirma o item 1 da seção 5);
- **Configurações:** IP do PABX e rede dos telefones (com validação), porta, NTP, senha admin
  dos telefones, e regerar todos;
- **Baixar planilha:** backup do cadastro em CSV.
- **Topo da página:** status de HTTP, TFTP e FTP (✓/✗), testado ao abrir o painel.

O painel usa os mesmos scripts do terminal, então os dois podem ser usados juntos.
Trocar a senha: `sudo -u provisiona python3 /opt/provisionamento/painel/painel.py --definir-senha`
e `sudo systemctl restart provisiona-painel`. O painel roda como usuário `provisiona` (sem root):
para trocar a rede ele só grava `REDE_TELEFONES` no `provisiona.conf`, e a unidade systemd
`provisiona-rede.path` roda `provisiona-aplicar-rede` como root, que valida a rede antes de mexer
no nginx/ufw. O painel
bloqueia o IP por 5 minutos após 5 senhas erradas e só deve ficar acessível na rede interna:
não exponha a porta 8080 para a internet (o login trafega sem HTTPS).

## 7. Segurança e backup (o que causou a perda da última vez)

- Faça backup de **`/opt/provisionamento`** inteiro (scripts, `provisiona.conf`, templates
  importados e `ramais.csv`). Com isso, `provisiona regerar` reconstrói tudo em minutos.
  Ex.: `tar czf prov-$(date +%F).tgz /opt/provisionamento` diário via cron, copiado para outra máquina/nuvem.
- Os arquivos gerados contêm a senha SIP. TFTP não tem senha: mantenha o servidor só na rede/VLAN
  de voz. O HTTP já vem restrito à rede passada em `--rede`.
- Considere definir `ADMIN_PASS` no `provisiona.conf` (hoje só aplicado no TIP 235G) para não deixar
  os telefones com `admin/admin`.

## 8. Alternativas mais modernas

| Opção | Quando faz sentido |
|---|---|
| **Este servidor (TFTP/HTTP/FTP + script)** | Controle total, qualquer PABX, custo zero. Recomendado para o cenário do cliente. |
| **Intelbras Fast Config** (gratuito, Windows/Linux) | Descobre os telefones na rede por multicast e cadastra ramais em sequência pelo navegador. Suporta TIP 120i/125i (fw ≥ 4.3.4), TIP 125 (fw ≥ 2.9.21), TIP 235. Bom para instalações pontuais; exige o PC na mesma sub-rede e não importa CSV. |
| **Provisionamento pelo próprio PABX** | 3CX provisiona TIP 120i/125i nativamente (Plug and Play / RPS). Centrais Intelbras (ICIP/UnniTI) configuram TIP 120i/125i via DHCP opção 120. Se o cliente for trocar de PABX, isso elimina o servidor separado. |
| **HTTPS + RPS/nuvem** | Para telefones fora da rede local (home office/filiais): servir os arquivos por HTTPS com autenticação. O nginx deste pacote pode ganhar certificado e senha depois. |

Fontes: manuais Intelbras — Auto Provisionamento TIP 235G/435G/638V; TIP 125i, TIP 120 e TIP 125
(seção Autoprovisionamento/Restaurar); Fast Config 01-26 e Guia de Compatibilidade Fast Config 01-24.
