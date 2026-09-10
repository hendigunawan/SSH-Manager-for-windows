# Validasi v1.8.0

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
