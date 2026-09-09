# Proper SSH Manager

**Bahasa:** [English](README.md) | **Bahasa Indonesia**

Proper SSH Manager adalah aplikasi desktop WPF berbasis PowerShell untuk mengelola koneksi SSH dan transfer SCP di Windows. Aplikasi menyatukan daftar host, pilihan VPN, password otomatis, tes koneksi, pencarian cepat, serta workspace Windows Terminal dengan beberapa layout pane.

## Fitur utama

- CRUD host: tambah, edit, duplikat, dan hapus IP/hostname SSH.
- Autentikasi password otomatis, private key, atau Windows OpenSSH Agent.
- Transfer SCP untuk upload/download satu atau banyak file/folder, termasuk browser path remote, recursive, preserve timestamp/mode, dan kompresi.
- Password dienkripsi dengan Windows DPAPI `CurrentUser`; hanya akun Windows yang menyimpan password tersebut yang dapat membukanya.
- Profil VPN per host: tanpa VPN, Windows VPN/RAS, atau perintah CLI khusus.
- Override VPN saat connect: ikuti konfigurasi host, paksa tanpa VPN, atau paksa satu profil VPN.
- Layout Windows Terminal:

  | Layout per tab | Kapasitas per tab | Urutan host terpilih |
  | --- | ---: | --- |
  | 1 panel | 1 | setiap host mendapat tab sendiri |
  | Kiri / kanan | 2 | kiri, kanan |
  | Atas / bawah | 2 | atas, bawah |
  | Atas 1, bawah 2 | 3 | atas, kiri-bawah, kanan-bawah |
  | Atas 2, bawah 1 | 3 | kiri-atas, kanan-atas, bawah |
  | Grid 2 × 2 | 4 | kiri-atas, kanan-atas, kiri-bawah, kanan-bawah |

  Jika hanya satu host dipilih, host yang sama akan dibuka pada seluruh panel layout. Contoh: satu host dengan layout **Atas 1, bawah 2** menghasilkan tiga koneksi SSH ke host yang sama.

  Jika banyak host dipilih, host didistribusikan ke panel. Bila jumlahnya melebihi kapasitas layout, aplikasi membuat tab tambahan dalam jendela Windows Terminal yang sama. Contoh: 10 host dengan Grid 2 × 2 akan dibagi menjadi tab berisi 4, 4, dan 2 panel.

  Jika tabel hanya menampilkan satu host, tombol **Buka SSH** otomatis menggunakan host tersebut walaupun row belum diklik.

- Pencarian berdasarkan nama, group, IP/hostname, username, tag, dan catatan.
- Backup konfigurasi otomatis; maksimal 20 backup terakhir.
- Import/export konfigurasi JSON. Password sengaja tidak ikut diekspor.
- Verifikasi host key aman: default `accept-new`, bukan menonaktifkan pemeriksaan host key.
- Indikator koneksi langsung menampilkan tahap aktif, host tujuan, serta waktu berjalan terhadap timeout ketika membuka SSH atau menjalankan tes koneksi.
- Jika tes port gagal, dialog berbahasa Indonesia menampilkan endpoint dan penyebab untuk setiap host serta pilihan **Coba lagi**, **Tetap buka SSH**, atau **Batal**.

## Persyaratan

- Windows 10 atau Windows 11.
- Windows PowerShell 5.1.
- OpenSSH Client (`ssh.exe`).
- OpenSSH SCP (`scp.exe`) untuk fitur transfer file.
- Windows Terminal (`wt.exe`).
- `rasdial.exe` hanya diperlukan bila memakai profil Windows VPN/RAS.

Periksa semuanya dari menu **Konfigurasi → Periksa dependensi**.

Setelah extract, paket juga dapat divalidasi sebelum instalasi:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Smoke-Test.ps1
```

Tes tersebut memeriksa syntax seluruh script, memuat semua XAML, dan mencoba siklus config default pada folder sementara. Tes perilaku batch dapat dijalankan dengan:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\ScpBatch-Test.ps1
```

Tes batch memakai folder sementara dan transfer simulasi, tanpa menghubungi server. Untuk pengembangan di Linux/WSL, tes batas runtime dengan executable SCP simulasi tersedia melalui `python3 Tests/ScpRuntime-Test.py --pwsh /path/to/pwsh`. Uji tampilan WPF, Windows Terminal, DPAPI, dan VPN tetap dilakukan di Windows.

## Instalasi

1. Extract ZIP ke folder biasa.
2. Klik kanan `Install.cmd`, kemudian pilih **Run**. Administrator tidak diperlukan untuk memasang aplikasi karena aplikasi disimpan untuk user Windows saat ini.
3. Installer menambahkan profil **Proper SSH Manager** ke Windows Terminal melalui JSON fragment.
4. Shortcut dibuat pada Start Menu dan Desktop. Shortcut Start Menu juga mendaftarkan hotkey Windows `Ctrl+Alt+S`.
5. Buka **Proper SSH Manager**. Aplikasi akan muncul sebagai tab baru pada jendela Windows Terminal yang terakhir digunakan.

Alternatif dari PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install.ps1 -LaunchAfterInstall
```

Lokasi program:

```text
%LOCALAPPDATA%\Programs\ProperSSHManager
```

Lokasi konfigurasi, password terenkripsi, dan backup:

```text
%LOCALAPPDATA%\ProperSSHManager
```

Integrasi Windows Terminal dibuat di:

```text
%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\ProperSSHManager\proper-ssh-manager.json
```

Installer tidak mengubah atau menimpa `settings.json` utama milik pengguna. Fragment tersebut menambahkan profil launcher, `closeOnExit: always`, dan action `Ctrl+Shift+F12`. Uninstaller hanya menghapus fragment milik Proper SSH Manager.

## Pemakaian dasar

1. Klik **Tambah host**.
2. Isi nama, IP/hostname, port, username, dan metode autentikasi.
3. Untuk password otomatis, pilih **Password otomatis** lalu masukkan password.
4. Tentukan profil VPN atau **Tanpa VPN**.
5. Simpan.
6. Untuk satu host, klik row-nya. Untuk beberapa host, centang kolom **Pilih** pada setiap host; `Ctrl+klik`, `Shift+klik`, dan `Ctrl+A` pada row tetap didukung sebagai alternatif.
7. Pilih layout per tab. Jumlah host tidak harus sama dengan jumlah panel.
8. Klik **Buka SSH** atau tekan `Ctrl+Enter`.

Tab dan pane SSH selalu diarahkan ke jendela Windows Terminal terakhir (`wt.exe -w 0`). Pengaturan **New instance behavior** Windows Terminal boleh tetap **Create a new window** karena target eksplisit ini akan mengesampingkannya. Jika belum ada jendela Terminal, Windows Terminal membuat satu jendela secara otomatis.

Jika opsi **Tutup hanya tab manager setelah terminal dibuka** aktif, aplikasi WPF selesai setelah perintah SSH diterima. Profil hasil installer memakai `closeOnExit: always`, sehingga hanya tab **Proper SSH Manager** yang hilang; tab dan pane SSH tidak ikut tertutup.

## Transfer SCP

1. Centang kolom **Pilih** pada satu atau beberapa node. Jumlah node SCP tidak dibatasi oleh layout SSH.
2. Klik tombol **SCP**, buka **Host → Transfer SCP**, atau tekan `Ctrl+Shift+S`.
3. Pilih **Upload** atau **Download**.
4. Untuk upload banyak file, klik **Pilih file...** lalu pilih beberapa file sekaligus. Sumber lokal yang sama dikirim ke semua node pilihan.
5. Untuk upload sebuah folder, klik **Pilih folder...**; opsi **Recursive** akan aktif otomatis.
6. Untuk download, klik **Pilih remote...**, lalu gunakan `Ctrl+klik` atau `Shift+klik` untuk memilih banyak file/folder. Setelah itu pilih satu folder tujuan lokal.
7. Pada browser remote, gunakan Home, Naik, Refresh, atau double-click folder. Path tunggal tetap dapat diketik manual, misalnya `~/upload/` atau `/var/tmp/file.txt`.
8. **Recursive** otomatis aktif jika pilihan mengandung folder. Opsi preserve dan kompresi dapat diaktifkan sesuai kebutuhan.
9. Jika banyak node dipilih, gunakan dropdown **Atur path remote untuk node** untuk menentukan path dan membuka browser remote pada masing-masing node. Berpindah node mempertahankan pilihan sebelumnya. **Terapkan path remote ke semua node** menyalin path node aktif ke semua node; gunakan hanya bila path tersebut berlaku di semuanya. Contoh `~/OLTS_MME/log` mengikuti home user masing-masing, sedangkan `/home/mme/...` tetap path absolut yang sama.
10. Arahkan mouse pada **Path remote terisi** untuk memeriksa daftar path, lalu klik **Mulai transfer**. Progres bawaan `scp.exe` tampil pada satu tab Windows Terminal. Banyak node diproses **berurutan**; node gagal tidak menghentikan node berikutnya.

Download banyak node menghasilkan folder seperti `D:\Downloads\node-a-<ID>\` dan `D:\Downloads\node-b-<ID>\`. Penanda ID juga membedakan node dengan nama sama. Download satu node tetap memakai folder tujuan langsung. Transfer berikutnya ke node/path yang sama mengikuti perilaku penimpaan file SCP; subfolder melindungi benturan **antar-node**, bukan menyimpan versi file.

Status bawah menampilkan progres `[1/3]` lalu ringkasan, misalnya **Selesai SCP Upload: 3 node | 3 berhasil, 0 gagal | Berhasil: 6 file** untuk dua file yang dikirim ke tiga node. Jumlah tersebut menghitung pilihan sumber per node, bukan seluruh isi di dalam folder recursive. Path yang diketik manual atau diterapkan ke node lain dilaporkan sebagai item bila tipe file/folder belum diketahui. Arahkan mouse ke status untuk melihat hasil, path, dan pesan error tiap node. Laporan lengkap tersimpan di `%LOCALAPPDATA%\ProperSSHManager\logs\scp-batch-<ID>.json`.

VPN diperiksa untuk node yang sedang diproses. Kegagalan VPN, autentikasi, pretest koneksi, atau SCP dicatat pada node tersebut. Jika memakai Jump Host, pretest TCP langsung dilewati dan koneksi dilakukan lewat SSH jump host. Opsi **Tes koneksi sebelum membuka** tetap mengikuti pengaturan aplikasi. Menutup tab batch sebelum selesai akan membuat manager menandai node yang belum selesai sebagai terhenti; file yang sudah berhasil tersalin tetap ada.

Banner tab transfer menampilkan versi runtime, misalnya **Proper SSH Manager 1.7.5**. Setelah update, pastikan nomor tersebut tampil agar transfer tidak memakai script instalasi lama.

Secara default, manager diminimalkan selama SCP berjalan. Setelah seluruh node berhasil, proses PowerShell SCP berakhir, tab SCP ditutup otomatis, dan jendela manager yang sama dipulihkan ke depan. Status bawah diperbarui menjadi hasil akhir seperti **Selesai SCP Download: 8 file dari host el.d.mme.** atau **Selesai SCP Upload: 1 folder ke host el.d.mme.** Jika ada node gagal, hasil tetap ditampilkan sampai Anda menekan Enter untuk kembali ke manager dan status bawah menampilkan pesan gagal. Perilaku kembali otomatis ini dapat diubah melalui **Konfigurasi → Pengaturan aplikasi → Kembali ke manager setelah transfer SCP berhasil**.

SCP otomatis memakai port, username, jump host, kebijakan host key, metode autentikasi, serta pilihan VPN yang sama dengan host. Untuk password otomatis, password tetap dibaca melalui helper DPAPI dan tidak dimasukkan pada argumen proses.

Urutan baris yang tampil menentukan posisi host pada layout. Host favorit tampil lebih dahulu, lalu diurutkan menurut group dan nama.

Private key harus berformat OpenSSH. File PuTTY `.ppk` perlu dikonversi terlebih dahulu ke format OpenSSH.

## Konfigurasi VPN

### Windows VPN / RAS

1. Buat koneksi VPN terlebih dahulu melalui Windows Settings.
2. Pada aplikasi buka **VPN → Kelola profil VPN**.
3. Pilih jenis **Windows VPN / RAS**.
4. Isi nama koneksi sama persis dengan nama pada Windows.
5. Bila Windows sudah menyimpan kredensial VPN, kosongkan username/password. Aplikasi akan menjalankan `rasdial "Nama VPN"`.
6. Bila username diisi, password disimpan terenkripsi dengan DPAPI.

### FortiClient, OpenVPN, atau klien lain

Pilih jenis **Perintah khusus**, lalu masukkan perintah CLI yang memang tersedia pada versi klien VPN Anda:

- **Perintah connect**: memulai koneksi.
- **Perintah pengecekan**: harus menghasilkan exit code `0` saat VPN terhubung dan selain `0` saat belum terhubung.
- **Perintah disconnect**: memutus koneksi.
- Aktifkan **Run as Administrator** bila klien VPN memerlukannya.

Contoh pengecekan adapter (sesuaikan nama interface):

```powershell
if (Get-NetAdapter -Name 'Fortinet*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up') { exit 0 } else { exit 1 }
```

Jangan menulis password langsung di field perintah khusus karena command line dapat terlihat oleh proses lain. Gunakan penyimpanan kredensial milik aplikasi VPN bila tersedia.

## Shortcut

| Shortcut | Fungsi |
| --- | --- |
| `Ctrl+Alt+S` | Buka Proper SSH Manager dari Windows melalui shortcut Start Menu |
| `Ctrl+Shift+F12` | Buka Proper SSH Manager sebagai tab baru ketika Windows Terminal aktif |
| `Ctrl+F` | Fokus pencarian |
| `Ctrl+N` | Tambah host |
| `Ctrl+E` | Edit host |
| `Ctrl+D` | Duplikat host |
| `Ctrl+Shift+S` | Upload atau download melalui SCP |
| `Delete` | Hapus host |
| `Ctrl+Enter` | Buka SSH |
| `F5` | Refresh daftar |
| `Alt+1` sampai `Alt+6` | Pilih layout |
| Checkbox **Pilih** | Pilih satu host untuk setiap panel layout |
| `Ctrl+klik` | Pilih beberapa host |
| `Shift+klik` | Pilih rentang host |
| `Ctrl+A` | Pilih semua host ketika tabel fokus |

## Keamanan password

- Password tidak disimpan sebagai teks biasa.
- File secret diproteksi DPAPI untuk user Windows saat ini dan ACL file diperketat bila didukung sistem.
- Password dikirim ke OpenSSH melalui helper `SSH_ASKPASS`; password tidak dimasukkan sebagai argumen `ssh.exe` maupun `scp.exe`.
- Export konfigurasi tidak membawa file secret.
- Memindahkan file secret ke komputer atau akun Windows lain tidak akan membuat password dapat didekripsi.
- Untuk server produksi, autentikasi key + agent tetap pilihan yang lebih baik daripada password.

## Troubleshooting

### `ssh.exe` tidak ditemukan

Jalankan PowerShell sebagai Administrator:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

### `wt.exe` tidak ditemukan

Install Windows Terminal:

```powershell
winget install --id Microsoft.WindowsTerminal -e
```

Pastikan **App execution alias** untuk Windows Terminal aktif pada Windows Settings.

### Password tetap ditanyakan atau login ditolak

- Edit host dan simpan ulang password.
- Pastikan server mengizinkan `PasswordAuthentication` atau `keyboard-interactive`.
- Pastikan username benar.
- Jalankan menu **Konfigurasi → Periksa dependensi** untuk membangun ulang password helper.

Installer mengisolasi sementara environment `LIB` ketika membangun password helper. Path library milik Visual Studio/C++ pada environment user tidak dihapus atau diubah permanen.

### Peringatan host identification changed

Jangan menonaktifkan host-key checking. Pastikan perubahan host key memang sah, kemudian hapus hanya entry target:

```powershell
ssh-keygen -R "[hostname]:port"
```

### VPN tersambung tetapi IP server belum dapat dijangkau

- Cek route dengan `route print`.
- Cek port dengan `Test-NetConnection IP_SERVER -Port 22`.
- Pastikan split tunneling dan firewall VPN mengizinkan subnet server.
- Untuk Fortinet/OpenVPN, sesuaikan perintah pengecekan dengan nama adapter aktual.

## Uninstall

Dari Windows Settings → Apps → Installed apps, pilih **Proper SSH Manager**, atau jalankan:

```powershell
& "$env:LOCALAPPDATA\Programs\ProperSSHManager\Uninstall.ps1"
```

Secara default konfigurasi dan password terenkripsi dipertahankan agar dapat digunakan lagi. Untuk menghapus semuanya:

```powershell
& "$env:LOCALAPPDATA\Programs\ProperSSHManager\Uninstall.ps1" -RemoveUserData
```
