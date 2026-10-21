#!/bin/bash
# =====================================================================
# Laboratorio: Servidor web (Apache + PHP + MariaDB + phpMyAdmin)
#              + FTP (ProFTPD) + DNS (BIND9) en Debian 13
#
# Uso (como root):   bash setup-lamp-dns.sh [usuario_linux]
#
# - Usa la IP que ya tiene la interfaz de laboratorio (IFACE).
# - No toca la configuracion de red.
# - Si Kea (DHCP) esta instalado, hace que reparta este servidor como DNS.
# - Se puede ejecutar mas de una vez sin romper lo ya hecho.
# =====================================================================
set -euo pipefail

# ----------------------------- VARIABLES -----------------------------
IFACE="enp0s8"
DB_USER="usuario1"
DB_PASS="${DB_PASS:-contrasena123}"   # solo laboratorio; cambiala con: DB_PASS=otra bash setup-lamp-dns.sh
PMA_VERSION="5.2.3"
DOM_WIKI="wiki.com"
DOM_CATOLICA="catolica.com"
DOM_MAIL="empresa.test"
LINUX_USER="${1:-}"

paso() { echo; echo "=================== $* ==================="; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Ejecuta este script como root."; exit 1
fi

# ------------------- IP / RED DETECTADAS AUTOMATICAMENTE -------------
SRV_IP=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1)
if [ -z "$SRV_IP" ]; then
  echo "ERROR: la interfaz $IFACE no tiene IP. Revisa IFACE al inicio del script."; exit 1
fi
IFS=. read -r o1 o2 o3 o4 <<< "$SRV_IP"
NET="$o1.$o2.$o3"                      # ej. 192.168.0
REV_ZONE="$o3.$o2.$o1.in-addr.arpa"    # ej. 0.168.192.in-addr.arpa
SERIAL="$(date +%Y%m%d)01"
echo "Interfaz: $IFACE | IP del servidor: $SRV_IP | Red: $NET.0/24 | Zona inversa: $REV_ZONE"

# ----------------------- USUARIO DE LOS SITIOS -----------------------
if [ -z "$LINUX_USER" ]; then
  read -rp "Usuario de Linux dueno de los sitios web (el que usaras por FTP): " LINUX_USER
fi
if ! id "$LINUX_USER" &>/dev/null; then
  echo "El usuario $LINUX_USER no existe; se va a crear."
  adduser "$LINUX_USER"
fi
HOME_DIR=$(getent passwd "$LINUX_USER" | cut -d: -f6)

# ============================== PARTE I ==============================
paso "1. Instalacion de paquetes"
export DEBIAN_FRONTEND=noninteractive
echo "proftpd-basic shared/proftpd/inetd_or_standalone select standalone" | debconf-set-selections
apt-get update
apt-get install -y apache2 mariadb-server mariadb-client \
  php libapache2-mod-php php-mysql php-mbstring php-xml php-curl php-gd php-zip php-bz2 \
  unzip wget curl openssl \
  proftpd-basic \
  bind9 bind9utils dnsutils

paso "2. MariaDB: usuario $DB_USER"
systemctl enable --now mariadb
mariadb <<SQL
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

paso "3. Apache + PHP"
echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf
a2enconf servername >/dev/null
systemctl enable --now apache2
echo '<?php phpinfo(); ?>' > /var/www/html/info.php

paso "4. phpMyAdmin $PMA_VERSION"
if [ ! -d /usr/share/phpMyAdmin ]; then
  cd /usr/share
  wget -q "https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.zip"
  unzip -q "phpMyAdmin-${PMA_VERSION}-all-languages.zip"
  mv "phpMyAdmin-${PMA_VERSION}-all-languages" phpMyAdmin
  rm -f "phpMyAdmin-${PMA_VERSION}-all-languages.zip"
fi
if [ ! -f /usr/share/phpMyAdmin/config.inc.php ]; then
  cp /usr/share/phpMyAdmin/config.sample.inc.php /usr/share/phpMyAdmin/config.inc.php
  SECRET=$(openssl rand -hex 16)
  sed -i "s|blowfish_secret'\] = ''|blowfish_secret'] = '${SECRET}'|" /usr/share/phpMyAdmin/config.inc.php
fi
mkdir -p /usr/share/phpMyAdmin/tmp
chown -R www-data:www-data /usr/share/phpMyAdmin
ln -sfn /usr/share/phpMyAdmin /var/www/html/phpMyAdmin
systemctl reload apache2

paso "5. ProFTPD"
cp -n /etc/proftpd/proftpd.conf /etc/proftpd/proftpd.conf.bak
sed -i 's/^UseIPv6.*/UseIPv6 off/' /etc/proftpd/proftpd.conf
if ! grep -q '^DefaultRoot' /etc/proftpd/proftpd.conf; then
  if grep -qE '^#\s*DefaultRoot\s+~\s*$' /etc/proftpd/proftpd.conf; then
    sed -i -E 's/^#\s*DefaultRoot\s+~\s*$/DefaultRoot ~/' /etc/proftpd/proftpd.conf
  else
    echo 'DefaultRoot ~' >> /etc/proftpd/proftpd.conf
  fi
fi
systemctl enable proftpd
systemctl restart proftpd

# ============================== PARTE II =============================
paso "6. Carpetas de los sitios web en $HOME_DIR"
WIKI_ROOT="$HOME_DIR/wiki/www.$DOM_WIKI"
CAT_ROOT="$HOME_DIR/catolica/www.$DOM_CATOLICA"
mkdir -p "$WIKI_ROOT" "$CAT_ROOT"
[ -f "$WIKI_ROOT/index.html" ] || echo "<h1>Bienvenido a www.$DOM_WIKI</h1>" > "$WIKI_ROOT/index.html"
[ -f "$CAT_ROOT/index.html" ]  || echo "<h1>Bienvenido a www.$DOM_CATOLICA</h1>" > "$CAT_ROOT/index.html"
chown -R "$LINUX_USER:$LINUX_USER" "$HOME_DIR/wiki" "$HOME_DIR/catolica"
chmod 755 "$HOME_DIR"
find "$HOME_DIR/wiki" "$HOME_DIR/catolica" -type d -exec chmod 755 {} \;
find "$HOME_DIR/wiki" "$HOME_DIR/catolica" -type f -exec chmod 644 {} \;

paso "7. VirtualHosts de Apache"
make_vhost() {  # $1=nombre  $2=dominio  $3=DocumentRoot
  cat > "/etc/apache2/sites-available/$1.conf" <<EOF
<VirtualHost *:80>
    ServerAdmin webmaster@$2
    ServerName www.$2
    ServerAlias $2
    DocumentRoot $3
    <Directory $3>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/$1_error.log
    CustomLog \${APACHE_LOG_DIR}/$1_access.log combined
</VirtualHost>
EOF
}
make_vhost wiki     "$DOM_WIKI"     "$WIKI_ROOT"
make_vhost catolica "$DOM_CATOLICA" "$CAT_ROOT"
a2ensite wiki.conf
a2ensite catolica.conf
apache2ctl configtest
systemctl reload apache2

# Base de datos del sitio dinamico (si ya subiste eventos.sql por FTP)
if [ -f "$CAT_ROOT/eventos.sql" ]; then
  mariadb < "$CAT_ROOT/eventos.sql" && echo "Base de datos importada desde eventos.sql"
else
  echo "(eventos.sql aun no esta en $CAT_ROOT; cuando lo subas por FTP ejecuta: mariadb < $CAT_ROOT/eventos.sql)"
fi

paso "8. DNS: BIND9"
cp -a /etc/bind "/root/bind-backup-$(date +%Y%m%d-%H%M%S)"

cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";

    // Reenviadores a DNS publicos
    forwarders {
        8.8.8.8;
        1.1.1.1;
    };

    // Solo la red de laboratorio
    listen-on { 127.0.0.1; $SRV_IP; };
    listen-on-v6 { none; };
    allow-query { localhost; $NET.0/24; };
    recursion yes;
    allow-recursion { localhost; $NET.0/24; };
    allow-transfer { none; };
    dnssec-validation auto;
};
EOF

# Zonas en named.conf.local (solo agrega las que no existan)
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
add_zone "$REV_ZONE"    "/etc/bind/db.$NET"
add_zone "$DOM_WIKI"     "/etc/bind/db.$DOM_WIKI"
add_zone "$DOM_CATOLICA" "/etc/bind/db.$DOM_CATOLICA"
add_zone "$DOM_MAIL"     "/etc/bind/db.$DOM_MAIL"

# Zonas directas
make_zone() {  # $1=dominio
  cat > "/etc/bind/db.$1" <<EOF
\$TTL 604800
@   IN SOA ns1.$1. admin.$1. (
        $SERIAL ; Serial
        604800  ; Refresh
        86400   ; Retry
        2419200 ; Expire
        604800 ); Negative Cache TTL
;
@     IN NS  ns1.$1.
@     IN A   $SRV_IP
ns1   IN A   $SRV_IP
www   IN A   $SRV_IP
EOF
}
make_zone "$DOM_WIKI"
make_zone "$DOM_CATOLICA"
make_zone "$DOM_MAIL"
# Registros extra para el laboratorio de correo
cat >> "/etc/bind/db.$DOM_MAIL" <<EOF
mail01  IN A      $SRV_IP
webmail IN CNAME  mail01
@       IN MX 10  mail01.$DOM_MAIL.
EOF

# Zona inversa
cat > "/etc/bind/db.$NET" <<EOF
\$TTL 604800
@   IN SOA ns1.$DOM_WIKI. admin.$DOM_WIKI. (
        $SERIAL ; Serial
        604800  ; Refresh
        86400   ; Retry
        2419200 ; Expire
        604800 ); Negative Cache TTL
;
@     IN NS  ns1.$DOM_WIKI.
$o4   IN PTR mail01.$DOM_MAIL.
$o4   IN PTR ns1.$DOM_WIKI.
EOF

chown bind:bind /etc/bind/db.$DOM_WIKI /etc/bind/db.$DOM_CATOLICA /etc/bind/db.$DOM_MAIL "/etc/bind/db.$NET"

named-checkconf
named-checkzone "$DOM_WIKI"     "/etc/bind/db.$DOM_WIKI"
named-checkzone "$DOM_CATOLICA" "/etc/bind/db.$DOM_CATOLICA"
named-checkzone "$DOM_MAIL"     "/etc/bind/db.$DOM_MAIL"
named-checkzone "$REV_ZONE"     "/etc/bind/db.$NET"

systemctl enable bind9
systemctl restart bind9
sleep 2

# ====================== DHCP (Kea): repartir este DNS =================
KEA=/etc/kea/kea-dhcp4.conf
if [ -f "$KEA" ] && grep -q '1.1.1.1, 8.8.8.8' "$KEA"; then
  paso "9. Kea: entregar $SRV_IP como DNS a los clientes"
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

# ============================ VERIFICACION ===========================
paso "Verificacion"
systemctl is-active apache2 mariadb proftpd bind9 || true
echo
echo "--- DNS (consultando a $SRV_IP) ---"
for h in www.$DOM_WIKI www.$DOM_CATOLICA mail01.$DOM_MAIL webmail.$DOM_MAIL; do
  printf '%-28s -> %s\n' "$h" "$(dig +short @"$SRV_IP" "$h" | tr '\n' ' ')"
done
echo "MX $DOM_MAIL                 -> $(dig +short @"$SRV_IP" MX "$DOM_MAIL")"
echo "PTR $SRV_IP             -> $(dig +short -x "$SRV_IP" @"$SRV_IP" | tr '\n' ' ')"
echo
echo "--- Web (por nombre virtual) ---"
for h in www.$DOM_WIKI www.$DOM_CATOLICA; do
  printf '%-22s -> %s\n' "$h" "$(curl -s -H "Host: $h" http://127.0.0.1/ | head -n1)"
done
echo
echo "--- Puertos en escucha (53, 80, 21) ---"
ss -lntup | grep -E ':(53|80|21)\b' || true

cat <<EOF

LISTO.
  Sitios:      http://www.$DOM_WIKI   http://www.$DOM_CATOLICA   (desde el cliente que use este DNS)
  phpinfo:     http://$SRV_IP/info.php      (borralo despues de la captura: rm /var/www/html/info.php)
  phpMyAdmin:  http://$SRV_IP/phpMyAdmin    (usuario: $DB_USER)
  FTP:         $SRV_IP puerto 21, usuario $LINUX_USER (FTP sin cifrar: solo laboratorio)
  Cliente Windows: ipconfig /release  &&  ipconfig /renew  &&  ipconfig /flushdns
EOF
