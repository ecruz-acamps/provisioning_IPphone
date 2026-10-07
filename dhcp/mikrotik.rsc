# MikroTik RouterOS: opção 66 no servidor DHCP da rede dos telefones.
# Troque 192.168.1.20 pelo IP do servidor e "dhcp-network" pela sua rede.
/ip dhcp-server option add name=opt66-prov code=66 value="'192.168.1.20'"
/ip dhcp-server network set [find address="192.168.1.0/24"] dhcp-option=opt66-prov
# Para URL HTTP:  value="'http://192.168.1.20/'"
