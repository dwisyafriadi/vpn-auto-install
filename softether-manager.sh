cat > ~/vpn-auto-install/softether-manager.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/usr/local/vpnserver"
VPNCMD="$INSTALL_DIR/vpncmd"
SERVICE_FILE="/etc/systemd/system/vpnserver.service"
SYSCTL_FILE="/etc/sysctl.d/99-softether-ipforward.conf"
TARBALL_URL="https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/v4.44-9807-rtm/softether-vpnserver-v4.44-9807-rtm-2025.04.16-linux-x64-64bit.tar.gz"

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "[ERR] Jalankan script ini sebagai root (gunakan sudo)."
    exit 1
  fi
}

is_port_used_by_other() {
  local port="$1"
  local line
  line="$(ss -tlnp 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$")' || true)"
  if [ -n "$line" ] && ! grep -q "vpnserver" <<< "$line"; then
    return 0
  fi
  return 1
}

detect_vpn_port() {
  local p line
  for p in 5555 443 992 1194; do
    line="$(ss -tlnp 2>/dev/null | awk -v port=":$p" '$4 ~ (port "$")' || true)"
    if grep -q "vpnserver" <<< "$line"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

wait_for_vpnserver() {
  local retries=10
  local port=""
  for ((i = 1; i <= retries; i++)); do
    if port="$(detect_vpn_port)"; then
      echo "$port"
      return 0
    fi
    sleep 1
  done
  return 1
}

install_vpn() {
  echo "=== [1] Install SoftEther VPN Server ==="
  read -r -p "Nama Virtual Hub [DEFAULT]: " hub_name
  hub_name="${hub_name:-DEFAULT}"

  read -r -s -p "Password Admin VPN Server: " admin_pass
  echo ""
  if [ -z "$admin_pass" ]; then
    echo "[ERR] Password admin tidak boleh kosong."
    return 1
  fi

  read -r -p "IPsec Pre-Shared Key (L2TP) [softether-psk-2026]: " psk
  psk="${psk:-softether-psk-2026}"

  read -r -p "Range DHCP Awal [192.168.30.10]: " dhcp_start
  dhcp_start="${dhcp_start:-192.168.30.10}"

  read -r -p "Range DHCP Akhir [192.168.30.200]: " dhcp_end
  dhcp_end="${dhcp_end:-192.168.30.200}"

  read -r -p "Gateway DHCP [192.168.30.1]: " dhcp_gw
  dhcp_gw="${dhcp_gw:-192.168.30.1}"

  echo "[1/5] Install paket build & utilitas..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq build-essential curl tar iproute2 libreadline-dev libssl-dev zlib1g-dev ncurses-dev

  echo "[2/5] Download & compile SoftEther VPN Server..."
  systemctl stop vpnserver 2>/dev/null || true
  cd /tmp
  curl -fsSL "$TARBALL_URL" -o /tmp/softether-vpnserver.tar.gz
  rm -rf /tmp/vpnserver "$INSTALL_DIR"
  tar -xzf /tmp/softether-vpnserver.tar.gz -C /tmp

  make -C /tmp/vpnserver <<< $'1\n1\n1\n'

  if [ ! -x /tmp/vpnserver/vpnserver ] || [ ! -x /tmp/vpnserver/vpncmd ]; then
    echo "[ERR] Kompilasi gagal: binary vpnserver/vpncmd tidak ditemukan."
    return 1
  fi

  cd /
  mv /tmp/vpnserver "$INSTALL_DIR"
  rm -f /tmp/softether-vpnserver.tar.gz

  find "$INSTALL_DIR" -maxdepth 1 -type f -exec chmod 600 {} +
  chmod 700 "$INSTALL_DIR/vpnserver" "$INSTALL_DIR/vpncmd"

  echo "[3/5] Konfigurasi systemd service & IP forwarding..."
  cat >"$SERVICE_FILE" <<'EOF'
[Unit]
Description=SoftEther VPN Server
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/local/vpnserver/vpnserver start
ExecStop=/usr/local/vpnserver/vpnserver stop
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  echo "net.ipv4.ip_forward = 1" >"$SYSCTL_FILE"
  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

  systemctl daemon-reload
  systemctl enable --now vpnserver

  local vpn_port
  if ! vpn_port="$(wait_for_vpnserver)"; then
    echo "[ERR] SoftEther VPN Server tidak aktif di port 5555/443/992/1194."
    return 1
  fi

  if is_port_used_by_other 443; then
    echo "[INFO] Port 443 sedang digunakan layanan lain. Menggunakan port $vpn_port untuk SoftEther."
  fi

  echo "[4/5] Inisialisasi Server, Hub, SecureNAT, dan IPsec via port $vpn_port..."
  "$VPNCMD" "localhost:$vpn_port" /SERVER /CMD ServerPasswordSet "$admin_pass" </dev/null >/dev/null

  if is_port_used_by_other 443; then
    "$VPNCMD" "localhost:$vpn_port" /SERVER /PASSWORD:"$admin_pass" /CMD ListenerDisable 443 </dev/null >/dev/null 2>&1 || true
  fi

  local hub_list
  hub_list="$("$VPNCMD" "localhost:$vpn_port" /SERVER /PASSWORD:"$admin_pass" /CMD HubList </dev/null)"
  if ! grep -qw "$hub_name" <<< "$hub_list"; then
    "$VPNCMD" "localhost:$vpn_port" /SERVER /PASSWORD:"$admin_pass" /CMD HubCreate "$hub_name" /PASSWORD:"$admin_pass" </dev/null >/dev/null
  fi

  "$VPNCMD" "localhost:$vpn_port" /SERVER /PASSWORD:"$admin_pass" /HUB:"$hub_name" /CMD SecureNatEnable </dev/null >/dev/null
  "$VPNCMD" "localhost:$vpn_port" /SERVER /PASSWORD:"$admin_pass" /HUB:"$hub_name" /CMD DhcpSet \
    /START:"$dhcp_start" /END:"$dhcp_end" /MASK:"255.255.255.0" \
    /EXPIRE:7200 /GW:"$dhcp_gw" /DNS:"1.1.1.1" /DNS2:"8.8.8.8" \
    /DOMAIN:"vpn.local" /LOG:yes /PUSHROUTE:"none" </dev/null >/dev/null
  "$VPNCMD" "localhost:$vpn_port" /SERVER /PASSWORD:"$admin_pass" /CMD IPsecEnable \
    /L2TP:yes /L2TPRAW:yes /ETHERIP:yes /PSK:"$psk" /DEFAULTHUB:"$hub_name" </dev/null >/dev/null

  echo "[5/5] Instalasi selesai."
  echo "      Port Aktif : $vpn_port (L2TP/IPsec: UDP 500 & 4500)"
  echo "      Virtual Hub: $hub_name | Subnet: $dhcp_start-$dhcp_end | PSK: $psk"
}

stop_vpn() {
  echo "=== [2] Stop SoftEther VPN Server ==="
  if [ -f "$SERVICE_FILE" ]; then
    systemctl stop vpnserver || true
  elif [ -x "$INSTALL_DIR/vpnserver" ]; then
    "$INSTALL_DIR/vpnserver" stop || true
  else
    echo "[WARN] SoftEther VPN Server belum terinstal."
    return 1
  fi
  echo "[OK] VPN Server dihentikan."
}

start_vpn() {
  echo "=== [3] Start SoftEther VPN Server ==="
  if [ ! -x "$INSTALL_DIR/vpnserver" ]; then
    echo "[ERR] Binary $INSTALL_DIR/vpnserver belum tersedia. Jalankan menu 1 (Install VPN) dulu."
    return 1
  fi
  if [ -f "$SERVICE_FILE" ]; then
    systemctl start vpnserver
    systemctl status vpnserver --no-pager --lines=3 || true
  else
    "$INSTALL_DIR/vpnserver" start
  fi
  echo "[OK] VPN Server dijalankan."
}

create_user() {
  echo "=== [4] Create User VPN ==="
  if [ ! -x "$VPNCMD" ]; then
    echo "[ERR] SoftEther belum terinstal di $INSTALL_DIR."
    return 1
  fi

  local vpn_port
  if ! vpn_port="$(detect_vpn_port)"; then
    echo "[ERR] Service vpnserver tidak berjalan. Jalankan menu 3 (Start VPN) terlebih dahulu."
    return 1
  fi

  read -r -p "Nama Virtual Hub [DEFAULT]: " hub_name
  hub_name="${hub_name:-DEFAULT}"

  read -r -s -p "Password Admin VPN Server: " admin_pass
  echo ""

  read -r -p "Username baru: " user_name
  if [ -z "$user_name" ]; then
    echo "[ERR] Username tidak boleh kosong."
    return 1
  fi

  read -r -s -p "Password user '$user_name': " user_pass
  echo ""
  if [ -z "$user_pass" ]; then
    echo "[ERR] Password user tidak boleh kosong."
    return 1
  fi

  read -r -p "Full Name / Real Name [$user_name]: " real_name
  real_name="${real_name:-$user_name}"

  read -r -p "Catatan / Note [created-via-tool]: " note
  note="${note:-created-via-tool}"

  "$VPNCMD" "localhost:$vpn_port" /SERVER /PASSWORD:"$admin_pass" /HUB:"$hub_name" \
    /CMD UserCreate "$user_name" /GROUP:none /REALNAME:"$real_name" /NOTE:"$note" </dev/null >/dev/null
  "$VPNCMD" "localhost:$vpn_port" /SERVER /PASSWORD:"$admin_pass" /HUB:"$hub_name" \
    /CMD UserPasswordSet "$user_name" /PASSWORD:"$user_pass" </dev/null >/dev/null

  echo "[OK] User '$user_name' berhasil dibuat di Hub '$hub_name' (via port $vpn_port)."
}

delete_user() {
  echo "=== [5] Delete User VPN ==="
  if [ ! -x "$VPNCMD" ]; then
    echo "[ERR] SoftEther belum terinstal di $INSTALL_DIR."
    return 1
  fi

  local vpn_port
  if ! vpn_port="$(detect_vpn_port)"; then
    echo "[ERR] Service vpnserver tidak berjalan. Jalankan menu 3 (Start VPN) terlebih dahulu."
    return 1
  fi

  read -r -p "Nama Virtual Hub [DEFAULT]: " hub_name
  hub_name="${hub_name:-DEFAULT}"

  read -r -s -p "Password Admin VPN Server: " admin_pass
  echo ""

  read -r -p "Username yang akan dihapus: " user_name
  if [ -z "$user_name" ]; then
    echo "[ERR] Username tidak boleh kosong."
    return 1
  fi

  read -r -p "Yakin hapus user '$user_name' dari Hub '$hub_name'? [y/N]: " confirm
  case "${confirm:-N}" in
    y|Y|yes|YES)
      "$VPNCMD" "localhost:$vpn_port" /SERVER /PASSWORD:"$admin_pass" /HUB:"$hub_name" \
        /CMD UserDelete "$user_name" </dev/null >/dev/null
      echo "[OK] User '$user_name' berhasil dihapus."
      ;;
    *)
      echo "[INFO] Penghapusan dibatalkan."
      ;;
  esac
}

uninstall_vpn() {
  echo "=== [6] Uninstall SoftEther VPN Server ==="
  read -r -p "Yakin ingin menghapus total SoftEther VPN Server dan konfigurasinya? [y/N]: " confirm
  case "${confirm:-N}" in
    y|Y|yes|YES)
      systemctl stop vpnserver 2>/dev/null || true
      systemctl disable vpnserver 2>/dev/null || true
      [ -x "$INSTALL_DIR/vpnserver" ] && "$INSTALL_DIR/vpnserver" stop 2>/dev/null || true

      rm -f "$SERVICE_FILE" "$SYSCTL_FILE"
      rm -rf "$INSTALL_DIR" /tmp/vpnserver /tmp/softether-vpnserver.tar.gz
      sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
      systemctl daemon-reload
      echo "[OK] SoftEther VPN Server berhasil di-uninstall."
      ;;
    *)
      echo "[INFO] Uninstall dibatalkan."
      ;;
  esac
}

show_menu() {
  cat <<'EOF'

========================================
      SOFTETHER VPN MANAGER (UBUNTU)
========================================
1. Install VPN
2. Stop VPN
3. Start VPN
4. Create User
5. Delete User
6. Uninstall VPN
0. Exit
========================================
EOF
}

require_root

while true; do
  show_menu
  read -r -p "Pilih menu [0-6]: " choice
  case "${choice:-}" in
    1) install_vpn || echo "[ERR] Proses Install VPN gagal." ;;
    2) stop_vpn || true ;;
    3) start_vpn || true ;;
    4) create_user || echo "[ERR] Gagal membuat user. Periksa password admin / nama Hub." ;;
    5) delete_user || echo "[ERR] Gagal menghapus user. Periksa password admin / username." ;;
    6) uninstall_vpn || true ;;
    0)
      echo "Keluar."
      exit 0
      ;;
    *)
      echo "[ERR] Pilihan tidak valid."
      ;;
  esac
done
EOF
chmod +x ~/vpn-auto-install/softether-manager.sh
