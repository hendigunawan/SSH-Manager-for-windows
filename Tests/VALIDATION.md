# Validasi v1.10.0

Tanggal: 23 Oktober 2026. Lingkungan: Windows 11 Pro 26200, Windows PowerShell 5.1 (STA), WPF native, mstsc/cmdkey/wt tersedia. Tanpa server SSH/RDP/VPN nyata.

Lulus (13 suite PowerShell):

- `Smoke-Test`, `Workspace-Test`, `Workspace-Integration-Test`, `SingleWindow-Test`, `ScpPage-Test`, `ScpBatch-Test`, `ScpPathCompatibility-Test`, `RemoteEditor-Test`, `RemoteEditorUiState-Test`.
- `Workspace-Windows-Test` (WPF asli). Tes ini **gagal sebelum perubahan** pada checkbox SCP karena handler membaca `Source`; kini lulus. Termasuk navigasi RDP berulang tanpa handler ganda.
- `Rdp-Test`: migrasi config lama `{name, host, port}`; argumen `mstsc` (`/v`, `/f`, `/multimon`, `/admin`, `/w /h`, IPv6, file `.rdp` tanpa password); nama duplikat; override VPN; probe TCP async (terbuka/tertutup/timeout); job VPN runspace; job VPN yang macet (disconnect dan check command, masing-masing dengan proses cucu) dihentikan beserta seluruh pohon prosesnya — tanpa kill pohon proses, tes ini gagal dengan 2 proses tertinggal; round trip Windows Credential Manager (target dummy); format log.
- `HostRowMenu-Test` (WPF asli): menu **...** dibuka dan diklik 20×, aksi sesuai protokol host; Duplicate memakai editor asli (Id baru, `- Copy`/`- Copy 2`, SSH/RDP/VPN tersalin, credential tidak); default Tambah RDP.
- `App-E2E-Test`: proses aplikasi asli dengan data terisolasi dan config lama, via UI Automation: Duplicate dari menu **...** 3×, RDP Manager di jendela yang sama, Test RDP ke listener lokal, status bar, aplikasi keluar normal, dan isi log. Kontrol negatif pada kode lama menampilkan error persis: `Exception calling "ShowDialog"… The property 'SelectedItem' cannot be found on this object`.

- `SshAsync-Test` (WPF asli): `Connect-SelectedHosts` asli dengan VPN runspace dan tes TCP; timer heartbeat 25 ms tetap berjalan selama menunggu; jalur timeout, kegagalan VPN, dan cek port paralel. Juga disconnect VPN async, dan disconnect yang macet dihentikan setelah 5 detik. Ukurannya adalah jeda terpanjang antar-heartbeat (< 500 ms). Ronde terakhir: ke-14 suite lulus, termasuk `App-E2E-Test`.

Tidak berlaku di Windows: `Tests/*.py` membutuhkan `termios`/`pwsh` (Linux). Hasil gagalnya sama sebelum dan sesudah perubahan.

Belum diuji: SSH/SCP/editor/VPN ke server nyata, sesi `mstsc` nyata (termasuk multi-RDP dan credential tersimpan), serta DPI 125/150%.
# Validasi v1.9.1

Tanggal: 5 Oktober 2026. Lingkungan: Linux, PowerShell 7.4.19, Python 3.

Lulus: 9 suite PowerShell portabel dan 3 suite Python (termasuk 6 pengujian helper file remote).

Cakupan koreksi satu jendela:

- Controller SCP asli dengan kontrol/launcher pengganti: buka tanpa pilihan Connections, semua node tampil, Pilih semua/Kosongkan, checkbox langsung, path per node tetap tersimpan setelah centang berubah, upload/download multi-file, launch satu/banyak node, guard saat sibuk, pemulihan kegagalan launcher.
- Router dan host halaman: callback masih membaca variabel controller, batal pindah mempertahankan halaman, satu frame aktif, kembali dari error, pembersihan konten serta pemulihan menu, hasil transfer menuju aktivitas.
- Controller editor: dirty state, target file/node yang sudah dibuka, gagal simpan menahan perpindahan, dan gagal baca mempertahankan isi.
- Kontrak XAML UserControl, nama kontrol, tema; parser seluruh PowerShell; lima dialog inline dan dua halaman inline.
- Seluruh regresi layout, SCP batch/path/runtime, serta editor codec/filesystem/transport.

Tes portabel bukan bukti render WPF. Native WPF, Windows PowerShell 5.1, fokus/shortcut nyata, DPI, Windows Terminal, VPN dan SSH/SCP ke server asli belum diuji di lingkungan ini.

Tes Windows tanpa server sudah diperbarui agar memakai MainWindow, dispatcher, checkbox/binding dan controller asli. Tidak menyentuh konfigurasi pengguna:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\Tests\Smoke-Test.ps1
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\Tests\Workspace-Windows-Test.ps1
```

Saat mencoba di Windows: buka Editor/SCP/VPN/Settings melalui sidebar dan pastikan hanya satu jendela utama. Buka SCP tanpa host dicentang di Connections, pilih dua node, atur path berbeda lalu jalankan upload/download. Pada editor, ubah file lalu pindah halaman/tutup aplikasi dan pilih Batal; teks harus tetap ada. Coba Simpan dan Buang perubahan. Simulasikan gagal simpan saat menutup editor yang berubah; penutupan harus dibatalkan dan teks tetap tersedia. Periksa Ctrl+S/Ctrl+F, ukuran minimum, scroll dan DPI 125/150%.

## Riwayat validasi v1.9.0

Tanggal: 4 Oktober 2026 (Asia/Jakarta). Lingkungan: Linux, PowerShell 7.4.19, Python 3.

Lulus setelah redesign:

- Tes model workspace: enam layout, 0/1/banyak host, urutan host, serta semua 30 kombinasi layout/jumlah host dibandingkan dengan aturan launcher sebenarnya.
- Navigasi modal: batal tutup mempertahankan editor, perpindahan berantai, pencegahan reentry, pemulihan dari error, dan checkbox host tetap tersimpan.
- Aktivitas dipertahankan pada transfer terakhir yang diluncurkan; callback transfer lama tidak mengganti halaman tersebut. Aksi SSH/edit baris diuji terhadap host lain yang masih dicentang.
- Kontrak nama kontrol pada Connections, SCP, dan editor; injeksi resource tema melalui path absolut.
- Smoke portabel: parser seluruh PowerShell, XML/XAML, tujuh dialog inline, dua template ComboBox, konfigurasi serta integrasi statis.
- Seluruh regresi SCP batch/path/runtime dan editor codec/controller/transport/helper file yang dijelaskan pada catatan v1.8.0 di bawah.

Batas pengujian: WPF native, Windows PowerShell 5.1, ukuran/DPI layar, Windows Terminal, fokus jendela, VPN dan server SSH asli belum tersedia di lingkungan ini. XML yang valid bukan bukti hasil render Windows.

Pemeriksaan Windows tambahan (tanpa menghubungi server):

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\Tests\Smoke-Test.ps1
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\Tests\Workspace-Windows-Test.ps1
```

Uji penggunaan Windows: periksa ukuran minimum dan DPI 125/150%; buka setiap menu sidebar; pilih beberapa host lalu pakai aksi SSH/edit pada host lain; periksa ComboBox menampilkan nama; coba drag-and-drop satu/banyak file dan folder; pastikan daftar puluhan node dapat di-scroll; buka file editor, ubah, pindah menu, dan pilih Batal; periksa nomor baris saat scroll/Word Wrap. Untuk transfer ke server uji, pastikan activity sesuai hasil sebenarnya termasuk gagal/terhenti dan otomatis kembali ke manager.

## Catatan validasi v1.8.0

Tanggal: 10 September 2026. Lingkungan pengujian: Linux, PowerShell 7.4.19, Python 3.

Lulus:

- Runtime SCP v1.7.5 dari paket yang diberikan dipertahankan identik; uji manifest download lama mengirim libFIX5.a dan libmisc.a sebagai dua argumen native terpisah.
- Normalisasi kompatibilitas path lokal Windows drive/UNC, nama dengan spasi, dan array remote eksplisit.
- Encoding editor: UTF-8 dengan/tanpa BOM, UTF-16 LE/BE dengan BOM, LF/CRLF/CR, baris campuran, newline terakhir, file kosong, serta penolakan biner/encoding salah/file melebihi 2 MiB.
- Controller editor asli dengan kontrol/transport pengganti: state perubahan, target file yang sudah dibuka, simpan node lama sebelum berpindah, pembatalan pindah/tutup, serta pemulihan setelah baca/simpan gagal. Ini bukan uji tampilan WPF.
- Helper remote pada file sementara nyata: baca/simpan, backup, mode dan extended attributes, konflik versi, symlink, penolakan hard link/FIFO, serta dua penyimpanan bersamaan.
- Transport editor melalui proses ssh.exe simulasi: path Unicode/tanda petik, payload stdin UTF-8, file kosong, 2 MiB, port/key/jump host/host-key policy, status progres, browser listing, Python tidak ditemukan, protokol salah, timeout, dan handle output yang ditahan proses turunan.

- Parser PowerShell untuk seluruh script, XML main window, editor, dialog perubahan belum disimpan, 8 dialog inline, dan 2 style ComboBox.
- Smoke test portabel untuk struktur paket, konfigurasi default, dan pemeriksaan integrasi statis.
- Tes perilaku: pemetaan node unik, urutan transfer, path remote per node, sumber lokal bersama, recursive, override VPN, serta serialisasi JSON dengan satu/banyak path.
- Folder download terpisah, termasuk nama node sama, karakter terlarang, dan nama device Windows seperti CON.log.
- Antrean tiga node dengan node kedua gagal; node ketiga tetap diproses dan ringkasan menjadi 2 berhasil/1 gagal.
- Gangguan sementara saat publikasi progres tidak menghentikan antrean.
- Fungsi polling manager dengan kontrol status pengganti: progres aktif, hasil akhir, dan deteksi proses yang sudah berhenti. Tanggal JSON diuji agar tidak salah mendeteksi proses aktif.
- Runtime upload/download memakai executable SCP simulasi: port per node, jump host, IPv6, key, timeout, preserve/compression, nama file dengan spasi/tanda petik/Unicode, exit code gagal, dan laporan JSON.
- SCP worker mempertahankan terminal stdout melalui pengujian pseudo-terminal, agar progress meter SCP tetap dapat bekerja.
- Launcher diuji memakai executable Windows Terminal simulasi: satu tab, path ber-encoding, flag kembali ke manager, dan status awal.

Kegagalan node serta sharing violation pada output tes memang disimulasikan. Tidak ada server pengguna yang dihubungi.

Belum dijalankan dalam lingkungan ini: tampilan WPF native, Windows PowerShell 5.1, Windows Terminal asli, aktivasi/fokus jendela, kompilasi helper DPAPI Windows, VPN, dan transfer SSH/SCP ke server nyata. Pemeriksaan XML bukan uji visual WPF.

Di Windows, jalankan dari folder aplikasi:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Smoke-Test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\ScpBatch-Test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\ScpPathCompatibility-Test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\RemoteEditor-Test.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\RemoteEditorUiState-Test.ps1
```

Pemeriksaan penggunaan di Windows:

1. Centang tiga node dan buka SCP; pastikan nama ketiganya muncul di dropdown node.
2. Pilih path remote berbeda pada setiap node, lalu berpindah antar-node untuk memastikan pilihan tersimpan.
3. Upload file kecil ke folder uji; pastikan ketiga node mendapat sumber yang sama.
4. Download file bernama sama dari ketiga node; pastikan hasil berada pada subfolder node masing-masing.
5. Coba node uji yang tidak dapat dijangkau; antrean harus tetap meneruskan node berikutnya dan menampilkan hasil gagal untuk node tersebut.
6. Setelah semuanya berhasil, tab SCP harus menutup dan manager yang sama dipulihkan. Jika ada gagal, tab menunggu Enter dan rincian tetap dapat dibaca.


Tes pengembangan Linux/WSL:

```bash
python3 Tests/RemoteTextFile-Test.py
python3 Tests/RemoteEditorTransport-Test.py --pwsh /path/to/pwsh
python3 Tests/ScpRuntime-Test.py --pwsh /path/to/pwsh
```

Pemeriksaan editor di Windows dengan node uji Linux:

1. Buka **Edit file**, pilih file `.cfg` kecil, dan pastikan isi serta node/path terlihat benar.
2. Ubah teks, coba Undo/Redo, pencarian, Word Wrap, lalu `Ctrl+S`. Periksa isi server, format LF, mode file, dan backup yang disebutkan di status.
3. Ubah teks lagi dan coba tutup/pindah node. **Batal** harus mempertahankan teks, **Simpan** menyimpan ke node lama terlebih dahulu, dan **Buang perubahan** membuang hanya setelah perpindahan berhasil.
4. Ubah file dari sesi lain sebelum simpan. Editor harus menolak konflik dan mempertahankan teks untuk disalin lokal atau dimuat ulang.
5. Coba file tanpa izin tulis dan node tidak dapat dijangkau. Status harus menunjukkan kegagalan; editor tetap memegang perubahan.
6. Jalankan kembali SCP banyak node sesuai langkah sebelumnya untuk memastikan update yang dipakai adalah v1.8.0.

Penguncian helper bersifat advisory pada folder yang sama. Penulis eksternal yang tidak memakai lock tersebut tetap memiliki celah perubahan antara pemeriksaan terakhir dan penggantian atomik; pengujian tidak mengklaim sinkronisasi universal dengan aplikasi lain.
