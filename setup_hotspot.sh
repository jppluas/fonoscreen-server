#!/usr/bin/env bash
# setup_hotspot.sh — Configura la red Wi-Fi local (hotspot) en Raspberry Pi 5
# Ejecutar UNA SOLA VEZ con sudo, luego arranca automáticamente con el sistema.
# NO ejecutar en laptop de desarrollo (no tiene efecto y puede romper la red).

set -euo pipefail

SSID="FonoScreen"
PASSPHRASE="fonoscreen2025"    # cámbiela antes de despliegue
IFACE="wlan0"
GATEWAY="192.168.4.1"

echo "==> Instalando hostapd y dnsmasq..."
apt-get update -qq
apt-get install -y hostapd dnsmasq iptables

echo "==> Configurando IP estática para $IFACE..."
cat >> /etc/dhcpcd.conf << EOF

# FonoScreen hotspot
interface $IFACE
    static ip_address=$GATEWAY/24
    nohook wpa_supplicant
EOF

echo "==> Configurando dnsmasq..."
mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak 2>/dev/null || true
cat > /etc/dnsmasq.conf << EOF
interface=$IFACE
dhcp-range=192.168.4.10,192.168.4.50,255.255.255.0,24h
# Redirigir todo el tráfico DNS al Pi (captive portal simple)
address=/#/$GATEWAY
EOF

echo "==> Configurando hostapd..."
cat > /etc/hostapd/hostapd.conf << EOF
interface=$IFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$PASSPHRASE
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' \
    /etc/default/hostapd

echo "==> Habilitando servicios..."
systemctl unmask hostapd
systemctl enable hostapd
systemctl enable dnsmasq

echo ""
echo "¡Listo! Al reiniciar, el Pi generará la red Wi-Fi:"
echo "  SSID:       $SSID"
echo "  Contraseña: $PASSPHRASE"
echo "  IP del Pi:  $GATEWAY"
echo "  URL:        http://$GATEWAY"
echo ""
echo "Recuerda también instalar y habilitar el servicio FonoScreen:"
echo "  sudo cp fonoscreen.service /etc/systemd/system/"
echo "  sudo systemctl enable fonoscreen"
echo "  sudo systemctl start fonoscreen"
