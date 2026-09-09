# Validasi v1.7.0

Tanggal: 8 September 2026. Lingkungan pengujian: Linux, PowerShell 7.4.19, Python 3.

Lulus:

- Parser PowerShell untuk seluruh script, XML main window, 8 dialog inline, dan 2 style ComboBox.
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
```

Pemeriksaan penggunaan di Windows:

1. Centang tiga node dan buka SCP; pastikan nama ketiganya muncul di dropdown node.
2. Pilih path remote berbeda pada setiap node, lalu berpindah antar-node untuk memastikan pilihan tersimpan.
3. Upload file kecil ke folder uji; pastikan ketiga node mendapat sumber yang sama.
4. Download file bernama sama dari ketiga node; pastikan hasil berada pada subfolder node masing-masing.
5. Coba node uji yang tidak dapat dijangkau; antrean harus tetap meneruskan node berikutnya dan menampilkan hasil gagal untuk node tersebut.
6. Setelah semuanya berhasil, tab SCP harus menutup dan manager yang sama dipulihkan. Jika ada gagal, tab menunggu Enter dan rincian tetap dapat dibaca.
