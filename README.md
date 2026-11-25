# SoftEther VPN Auto-Install & Manager (Ubuntu)

Script instalasi dan manajemen interaktif **SoftEther VPN Server** untuk Ubuntu (x86_64) dengan konfigurasi otomatis Virtual Hub, SecureNAT/DHCP, IPsec/L2TP, layanan `systemd`, serta menu pengelolaan user dan siklus hidup server.

Repository: [github.com/dwisyafriadi/vpn-auto-install](https://github.com/dwisyafriadi/vpn-auto-install/tree/main)

---

## Fitur Utama

- **1. Install VPN**: Mengunduh dan mengompilasi SoftEther VPN Server (`v4.44-9807-rtm` x64), mendaftarkan `systemd` service (`vpnserver`), mengaktifkan IP forwarding, serta mengonfigurasi Virtual Hub, SecureNAT/DHCP, dan IPsec/L2TP.
- **2. Stop VPN**: Menghentikan layanan `vpnserver` dengan aman.
- **3. Start VPN**: Menjalankan layanan `vpnserver` dan menampilkan ringkasan status service.
- **4. Create User**: Membuat akun VPN baru lengkap dengan password, *real name*, dan catatan pada Virtual Hub target.
- **5. Delete User**: Menghapus user VPN dari Virtual Hub setelah konfirmasi.
- **6. Uninstall VPN**: Menghapus instalasi `/usr/local/vpnserver`, unit `systemd`, dan konfigurasi sysctl IP forwarding bawaan script.

---

## Prasyarat

- Sistem operasi: **Ubuntu** (arsitektur `x86_64` / `amd64`).
- Akses **root** atau pengguna dengan hak `sudo`.
- Koneksi internet untuk mengunduh paket dependensi `apt` dan binary SoftEther VPN Server.

---

## Instalasi & Menjalankan

Clone repository lalu jalankan script menu interaktif sebagai `root`:

```bash
git clone https://github.com/dwisyafriadi/vpn-auto-install.git
cd vpn-auto-install
chmod +x softether-manager.sh
sudo ./softether-manager.sh
