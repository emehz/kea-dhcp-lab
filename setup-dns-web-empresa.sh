#!/bin/bash
# =====================================================================
# Base de red para el laboratorio de correo (dominio empresa.test)
#   - DNS (BIND9): zona empresa.test con A, MX, webmail y PTR
#   - Web (Apache + PHP): www.empresa.test y webmail.empresa.test
#     (webmail queda listo para instalar Roundcube despues)
#   - Kea (si existe): entrega este servidor como DNS a los clientes
#
# Uso (como root):   bash setup-dns-web-empresa.sh
#
# Opcional, para interconectar con el servidor de tu companero:
#   PARTNER_DOM=otraempresa.test PARTNER_IP=192.168.0.X [PARTNER_HOST=mail02] \
#     bash setup-dns-web-empresa.sh
# (este servidor alojara tambien la zona de su dominio)
#
# No toca la configuracion de red. Se puede ejecutar varias veces.
# =====================================================================
set -euo pipefail

IFACE="enp0s8"
DOM="empresa.test"
MAILHOST="mail01"
PARTNER_DOM="${PARTNER_DOM:-}"
PARTNER_IP="${PARTNER_IP:-}"
PARTNER_HOST="${PARTNER_HOST:-mail02}"

paso() { echo; echo "=================== $* ==================="; }

if [ "$(id -u)" -ne 0 ]; then echo "Ejecuta este script como root."; exit 1; fi
if [ -n "$PARTNER_DOM" ] && [ -z "$PARTNER_IP" ]; then
  echo "Si defines PARTNER_DOM debes definir tambien PARTNER_IP."; exit 1
fi

# ------------------- IP / RED DETECTADAS AUTOMATICAMENTE -------------
SRV_IP=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1)
if [ -z "$SRV_IP" ]; then
  echo "ERROR: la interfaz $IFACE no tiene IP. Revisa IFACE al inicio del script."; exit 1
fi
IFS=. read -r o1 o2 o3 o4 <<< "$SRV_IP"
NET="$o1.$o2.$o3"
REV_ZONE="$o3.$o2.$o1.in-addr.arpa"
SERIAL="$(date +%Y%m%d)01"
echo "Interfaz: $IFACE | IP: $SRV_IP | Red: $NET.0/24 | Dominio: $DOM | Host de correo: $MAILHOST.$DOM"

# ------------------------------ PAQUETES -----------------------------
paso "1. Instalacion de paquetes"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apache2 php libapache2-mod-php bind9 bind9utils dnsutils curl

# ------------------------------- APACHE ------------------------------
paso "2. Apache: www.$DOM y webmail.$DOM"
echo "ServerName $MAILHOST.$DOM" > /etc/apache2/conf-available/servername.conf
a2enconf servername >/dev/null

mkdir -p /var/www/empresa /var/www/webmail
[ -f /var/www/empresa/index.html ] || cat > /var/www/empresa/index.html <<EOF
<h1>Bienvenido a www.$DOM</h1>
<p>Servidor $MAILHOST.$DOM ($SRV_IP)</p>
EOF
[ -f /var/www/webmail/index.html ] || cat > /var/www/webmail/index.html <<EOF
<h1>Webmail de $DOM</h1>
<p>Pendiente: instalar Roundcube.</p>
EOF
chown -R www-data:www-data /var/www/empresa /var/www/webmail

make_vhost() {  # $1=nombre  $2=ServerName  $3=ServerAlias(opcional)  $4=DocumentRoot
  {
    echo "<VirtualHost *:80>"
    echo "    ServerAdmin webmaster@$DOM"
    echo "    ServerName $2"
    [ -n "$3" ] && echo "    ServerAlias $3"
    echo "    DocumentRoot $4"
    echo "    <Directory $4>"
    echo "        Options -Indexes +FollowSymLinks"
    echo "        AllowOverride All"
    echo "        Require all granted"
    echo "    </Directory>"
    echo "    ErrorLog \${APACHE_LOG_DIR}/$1_error.log"
    echo "    CustomLog \${APACHE_LOG_DIR}/$1_access.log combined"
    echo "</VirtualHost>"
  } > "/etc/apache2/sites-available/$1.conf"
}
make_vhost empresa "www.$DOM"    "$DOM" /var/www/empresa
make_vhost webmail "webmail.$DOM" ""    /var/www/webmail
a2ensite empresa.conf
a2ensite webmail.conf
apache2ctl configtest
systemctl enable --now apache2
systemctl reload apache2

# --------------------------------- DNS -------------------------------
paso "3. DNS: BIND9"
cp -a /etc/bind "/root/bind-backup-$(date +%Y%m%d-%H%M%S)"

cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";

    forwarders {
        8.8.8.8;
        1.1.1.1;
    };

    listen-on { 127.0.0.1; $SRV_IP; };
    listen-on-v6 { none; };
    allow-query { localhost; $NET.0/24; };
    recursion yes;
    allow-recursion { localhost; $NET.0/24; };
    allow-transfer { none; };
    dnssec-validation auto;
};
EOF

add_zone() {  # $1=zona  $2=archivo
  if ! grep -q "zone \"$1\"" /etc/bind/named.conf.local; then
    cat >> /etc/bind/named.conf.local <<EOF

zone "$1" {
    type master;
    file "$2";
};
EOF
  fi
}
add_zone "$DOM"      "/etc/bind/db.$DOM"
add_zone "$REV_ZONE" "/etc/bind/db.$NET"

# Zona directa del dominio de la guia
cat > "/etc/bind/db.$DOM" <<EOF
\$TTL 604800
@   IN SOA ns1.$DOM. admin.$DOM. (
        $SERIAL ; Serial
        604800  ; Refresh
        86400   ; Retry
        2419200 ; Expire
        604800 ); Negative Cache TTL
;
@        IN NS    ns1.$DOM.
@        IN A     $SRV_IP
@        IN MX 10 $MAILHOST.$DOM.
ns1      IN A     $SRV_IP
$MAILHOST IN A    $SRV_IP
www      IN A     $SRV_IP
webmail  IN CNAME $MAILHOST
EOF
ZONES_TO_CHECK="$DOM:/etc/bind/db.$DOM"
FILES_TO_CHOWN="/etc/bind/db.$DOM /etc/bind/db.$NET"

# Zona inversa
{
  cat <<EOF
\$TTL 604800
@   IN SOA ns1.$DOM. admin.$DOM. (
        $SERIAL ; Serial
        604800  ; Refresh
        86400   ; Retry
        2419200 ; Expire
        604800 ); Negative Cache TTL
;
@     IN NS  ns1.$DOM.
$o4   IN PTR $MAILHOST.$DOM.
EOF
  # PTR del companero si esta en la misma red /24
  if [ -n "$PARTNER_DOM" ] && [ "${PARTNER_IP%.*}" = "$NET" ]; then
    echo "${PARTNER_IP##*.}   IN PTR $PARTNER_HOST.$PARTNER_DOM."
  fi
} > "/etc/bind/db.$NET"

# Zona del companero (opcional)
if [ -n "$PARTNER_DOM" ]; then
  add_zone "$PARTNER_DOM" "/etc/bind/db.$PARTNER_DOM"
  cat > "/etc/bind/db.$PARTNER_DOM" <<EOF
\$TTL 604800
@   IN SOA ns1.$PARTNER_DOM. admin.$PARTNER_DOM. (
        $SERIAL ; Serial
        604800  ; Refresh
        86400   ; Retry
        2419200 ; Expire
        604800 ); Negative Cache TTL
;
@             IN NS    ns1.$PARTNER_DOM.
@             IN A     $PARTNER_IP
@             IN MX 10 $PARTNER_HOST.$PARTNER_DOM.
ns1           IN A     $SRV_IP
$PARTNER_HOST IN A     $PARTNER_IP
www           IN A     $PARTNER_IP
webmail       IN CNAME $PARTNER_HOST
EOF
  ZONES_TO_CHECK="$ZONES_TO_CHECK $PARTNER_DOM:/etc/bind/db.$PARTNER_DOM"
  FILES_TO_CHOWN="$FILES_TO_CHOWN /etc/bind/db.$PARTNER_DOM"
fi

# shellcheck disable=SC2086
chown bind:bind $FILES_TO_CHOWN

named-checkconf
for z in $ZONES_TO_CHECK; do named-checkzone "${z%%:*}" "${z#*:}"; done
named-checkzone "$REV_ZONE" "/etc/bind/db.$NET"

systemctl enable bind9
systemctl restart bind9
sleep 2

# ---------- El propio servidor tambien usa su DNS (lo necesita Postfix) ----------
paso "4. Resolver del propio servidor"
if [ ! -L /etc/resolv.conf ]; then
  cp -an /etc/resolv.conf /root/resolv.conf.bak
  printf 'nameserver %s\nnameserver 8.8.8.8\n' "$SRV_IP" > /etc/resolv.conf
  echo "/etc/resolv.conf ahora usa $SRV_IP (respaldo en /root/resolv.conf.bak)"
else
  echo "/etc/resolv.conf es un enlace simbolico (systemd-resolved); no se modifica."
fi
if [ -f /etc/dhcp/dhclient.conf ] && ! grep -q "prepend domain-name-servers $SRV_IP" /etc/dhcp/dhclient.conf; then
  echo "prepend domain-name-servers $SRV_IP;" >> /etc/dhcp/dhclient.conf
fi

# ------------------ KEA: repartir este servidor como DNS -------------
KEA=/etc/kea/kea-dhcp4.conf
if [ -f "$KEA" ] && grep -q '1.1.1.1, 8.8.8.8' "$KEA"; then
  paso "5. Kea: entregar $SRV_IP como DNS a los clientes"
  cp -a "$KEA" "$KEA.bak-dns"
  sed -i "s/\"1\.1\.1\.1, 8\.8\.8\.8\"/\"$SRV_IP\"/" "$KEA"
  chown root:_kea "$KEA"; chmod 640 "$KEA"
  if su -s /bin/bash _kea -c "kea-dhcp4 -t $KEA" >/dev/null 2>&1; then
    systemctl restart kea-dhcp4-server
    echo "Kea actualizado y reiniciado."
  else
    cp -a "$KEA.bak-dns" "$KEA"
    echo "AVISO: la validacion de Kea fallo; se restauro el archivo original."
  fi
fi

# ----------------------------- VERIFICACION --------------------------
paso "Verificacion"
systemctl is-active apache2 bind9 || true
echo
echo "--- DNS (consultando a $SRV_IP) ---"
for h in www.$DOM $MAILHOST.$DOM webmail.$DOM; do
  printf '%-26s -> %s\n' "$h" "$(dig +short @"$SRV_IP" "$h" | tr '\n' ' ')"
done
echo "MX $DOM             -> $(dig +short @"$SRV_IP" MX "$DOM")"
echo "PTR $SRV_IP         -> $(dig +short -x "$SRV_IP" @"$SRV_IP" | tr '\n' ' ')"
if [ -n "$PARTNER_DOM" ]; then
  echo "MX $PARTNER_DOM     -> $(dig +short @"$SRV_IP" MX "$PARTNER_DOM")"
  echo "$PARTNER_HOST.$PARTNER_DOM -> $(dig +short @"$SRV_IP" "$PARTNER_HOST.$PARTNER_DOM")"
fi
echo
echo "--- Web (por nombre virtual) ---"
for h in www.$DOM webmail.$DOM; do
  printf '%-22s -> %s\n' "$h" "$(curl -s -H "Host: $h" http://127.0.0.1/ | head -n1)"
done
echo
echo "--- Puertos en escucha (53 y 80) ---"
ss -lntup | grep -E ':(53|80)\b' || true

cat <<EOF

LISTO.
  Desde un cliente que use este DNS:  http://www.$DOM   http://webmail.$DOM
  En Windows:  ipconfig /release  &&  ipconfig /renew  &&  ipconfig /flushdns
               nslookup www.$DOM   |   nslookup -type=MX $DOM
  Siguiente paso: guia de correo (hostname $MAILHOST.$DOM, Postfix, Dovecot) y luego Roundcube.
EOF
