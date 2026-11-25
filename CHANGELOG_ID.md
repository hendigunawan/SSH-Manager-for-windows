# Changelog

**Language:** [English](CHANGELOG.md) | **Bahasa Indonesia**

## 1.10.0 — 2026-10-23

- Memperbaiki crash saat memakai menu **...** pada Connections (`Exception calling "ShowDialog"… The property 'SelectedItem' cannot be found on this object`). Menu membuat handler dengan `GetNewClosure()` sehingga `$script:HostGrid` bernilai `$null`, serta memanggil fungsi yang tidak ada atau mengabaikan baris yang diklik. Kini setiap aksi mencari host berdasarkan ID dan menargetkan baris yang diklik.
- Memperbaiki checkbox Connections dan SCP agar memperbarui pilihan, detail, dan kontrol transfer pada WPF asli. Sel bertemplate melaporkan grid sebagai `Source`; CheckBox yang diklik kini diambil dari `OriginalSource`.
- Menambahkan **RDP Manager** di jendela utama yang sama (sidebar, `Ctrl+Shift+R`): pencarian, filter group, pilih satu/banyak/semua, kolom status, **Test RDP**, **Buka RDP**, serta menu Connect/Edit/... per baris. Membuka lebih dari 5 sesi meminta konfirmasi.
- Host dapat berupa SSH saja, RDP saja, atau SSH + RDP. Field baru: `SshEnabled`, `RdpEnabled`, `RdpPort` (3389), `RdpUsername`, dan opsi tampilan. Konfigurasi lama, termasuk `{name, host, port}`, terbaca sebagai SSH saja tanpa perubahan manual.
- Sesi RDP dibuka dengan `mstsc.exe /v:HOST:PORT` (fullscreen, multi monitor, `/admin`, resolusi kustom). Password hanya disimpan di Windows Credential Manager (`TERMSRV/<host>`), tidak pernah di JSON. Tanpa credential tersimpan, Windows akan meminta password.
- Koneksi RDP mengikuti pilihan VPN (tanpa VPN / profil host / profil paksa). Jika VPN gagal, RDP dibatalkan. Koneksi VPN dan tes port TCP berjalan di luar UI thread.
- Connections menampilkan badge SSH/RDP, tombol RDP per baris, dan **Buka RDP**. Aksi SSH, SCP, dan Remote Editor disembunyikan atau dilewati untuk host RDP saja. Nama hasil duplikat menjadi `Nama - Copy`, `Nama - Copy 2`, …, tanpa menyalin credential. Menu Host Edit/Duplikat/Hapus berfungsi kembali.
- Buka SSH, Tes koneksi, tes awal SCP, VPN untuk SCP/Editor, serta connect/disconnect VPN tidak lagi membekukan jendela. Penantian VPN dibatasi waktu. VPN berjalan di runspace terpisah, port diuji paralel, dan jendela progres benar-benar menampilkan waktu berjalan.
- Jika perintah VPN macet dan melewati batas waktu, seluruh proses yang dijalankannya (termasuk proses turunannya) kini dihentikan dan tidak tertinggal di latar belakang. Perintah connect yang dijalankan sebagai Administrator tidak dapat dihentikan dengan cara ini.
- Error teknis dicatat di `logs\ProperSSHManager.log`; pengguna melihat dialog singkat. Error UI tak terduga dicatat dan tidak lagi menutup aplikasi.
- Menambahkan tes baru: modul RDP, menu baris/editor host native, serta tes end-to-end UI Automation pada aplikasi asli.

## 1.9.1 — 2026-10-05

- SCP, Remote Editor, VPN & Network, dan Settings kini menjadi halaman di jendela utama, dengan satu sidebar. Dialog fitur besar dan sidebar ganda dihapus.
- Daftar SCP menampilkan semua host dengan checkbox langsung, Pilih semua/Kosongkan, serta jumlah node terpilih. Tidak perlu memilih Connections terlebih dahulu; path remote disimpan per node saat centang berubah.
- Editor menawarkan seluruh host. Konfirmasi perubahan belum disimpan berlaku saat pindah halaman maupun menutup aplikasi. Shortcut editor tetap bekerja di area editor.
- Tombol Simpan pada Settings menyimpan tanpa meninggalkan halaman. Menu perubahan host di header dinonaktifkan selama halaman fitur aktif; navigasi tetap melalui sidebar.
- Runtime dan modul transfer/editor dipertahankan identik dari v1.9.0, termasuk perbaikan batch v1.7.5.
- Ditambahkan tes controller SCP dan navigasi satu jendela; tes Windows diperbarui untuk dispatcher dan kontrol WPF asli. Pengujian native Windows belum dijalankan dalam lingkungan Linux ini.

## 1.9.0 — 2026-10-04

- Tampilan workspace navy dengan aksen biru dan sidebar bersama: Connections, Terminal Layout, SCP Transfer, Remote Editor, VPN & Network, dan Settings.
- Connections memakai badge group, tombol SSH/edit per baris, detail yang bisa dibuka/tutup, serta pesan saat tabel kosong. Aksi baris tidak mengubah checkbox host lain.
- Enam kartu layout beserta pratinjau mengikuti pilihan host, duplikasi satu host, susunan tab yang belum penuh, dan jumlah tab tambahan. Sesi SSH tetap berjalan di Windows Terminal.
- SCP ditata menjadi daftar node dan formulir transfer, mendukung drag-and-drop upload, daftar file sumber, path remote per node, serta aktivitas batch dari hasil runtime. Persentase byte tetap berasal dari SCP di terminal.
- Editor remote memakai tab nama file, nomor baris tampilan, tombol simpan/muat ulang/salinan lokal, serta sidebar yang menghormati perubahan belum disimpan.
- Perbaikan runtime SCP batch v1.7.5 dipertahankan identik. Ditambahkan tes model layout, navigasi, nama kontrol, serta smoke test WPF khusus Windows.
- Tes regresi Linux lulus. Render WPF/Windows Terminal dan penggunaan lengkap di Windows masih memerlukan pemeriksaan di Windows; lihat Tests/VALIDATION.md.

## 1.8.0 — 2026-09-10

- Menggunakan pembaruan v1.7.5 yang diberikan; runtime SCP batch, normalisasi path lama, dan tampilan progres native ikut dipertahankan.
- Menambahkan editor file remote seperti Notepad melalui **Edit file**, menu Host, atau `Ctrl+Shift+E`.
- Mendukung browser remote, simpan (`Ctrl+S`), pencarian teks, Undo/Redo, Word Wrap, salinan lokal, dan pilihan node.
- Mempertahankan encoding UTF-8/UTF-16 serta format baris, menolak file biner/terlalu besar, dan meminta pilihan sebelum membuang perubahan.
- Simpan menyediakan backup opsional (aktif secara default), mempertahankan metadata, dan mengganti file secara atomik. Pemeriksaan versi serta advisory lock folder mengoordinasikan simpan bersamaan dari editor.
- Status baca/simpan langsung terlihat, konflik/timeout dilaporkan, dan browser memiliki mode khusus satu file. Membutuhkan Python 3 di server Linux.
- Menambahkan tes encoding, state controller, filesystem remote, transport SSH, serta regresi pemisahan path batch v1.7.5. Batas pengujian Windows dijelaskan pada Tests/VALIDATION.md.

## 1.7.5 — 2026-09-09

- Memperbaiki SCP batch multi-node Download agar banyak path remote selalu dipisahkan menjadi argumen SCP tersendiri, bukan terbaca sebagai satu path panjang.
- Memperbaiki SCP batch multi-node Upload agar banyak path file lokal selalu dipisahkan menjadi item sumber tersendiri sebelum validasi dan transfer.
- Menambahkan normalisasi kompatibilitas untuk manifest batch lama yang masih menyimpan beberapa path remote atau lokal dalam satu string.
- Mempertahankan progress meter native scp.exe pada mode batch dengan menjalankan proses menggunakan console handle yang sama.
- Menghapus output debug command SCP dari tampilan transfer agar terminal kembali bersih untuk penggunaan normal.

## 1.7.0 — 2026-09-08

- SCP mendukung banyak node dari checkbox **Pilih**, melalui antrean berurutan dalam satu tab Windows Terminal.
- Upload memakai sumber lokal yang sama untuk setiap node; path tujuan remote dapat diatur per node.
- Download dapat memilih sumber remote berbeda per node. Hasil banyak node dipisahkan ke subfolder nama-node-ID untuk mencegah benturan nama antar-node.
- Dialog menyediakan pemilih node, browser remote per node, serta tombol **Terapkan path remote ke semua node**.
- Node gagal tetap dicatat dan antrean berlanjut ke node berikutnya. Status bawah menampilkan node aktif, jumlah berhasil/gagal, serta total item sumber pada transfer yang berhasil.
- Detail per node tersedia pada tooltip status dan laporan JSON dalam folder logs. Tab SCP yang ditutup sebelum selesai terdeteksi sebagai transfer terhenti.
- VPN, port, jump host, key, password, dan host-key policy tetap mengikuti node masing-masing serta override VPN.
- Manager dipulihkan sekali setelah seluruh antrean selesai. Jika ada kegagalan, tab menunggu Enter agar rincian dapat dibaca.
- Manifest batch mempertahankan setiap path sebagai item terpisah; nama file dengan spasi, tanda petik, atau titik koma tidak digabung.
- Menambahkan tes perilaku antrean dan integrasi runtime menggunakan proses SCP simulasi tanpa menghubungi server.

## 1.6.5 — 2026-08-15

- Menambahkan kolom checkbox **Pilih** khusus agar beberapa host dapat dipetakan ke panel layout yang berbeda tanpa harus menahan Ctrl.
- Memisahkan indikator Favorite berbentuk bintang dari checkbox pilihan koneksi agar fungsinya tidak membingungkan.
- Host yang dicentang menjadi sumber utama untuk SSH, tes koneksi, dan SCP; pilihan row dengan Ctrl/Shift tetap didukung sebagai alternatif.
- Pilihan checkbox tetap tersimpan saat daftar difilter atau di-refresh, serta dibersihkan ketika host dihapus atau konfigurasi diimpor.

## 1.6.4 — 2026-08-15

- Mengganti popup koneksi gagal bawaan Windows yang masih memakai tombol **Yes/No** dengan dialog gelap berbahasa Indonesia.
- Dialog menampilkan nama host, username, IP/hostname, port, dan penyebab kegagalan secara lengkap.
- Menambahkan pilihan **Coba lagi**, **Tetap buka SSH**, dan **Batal**; Coba lagi hanya menguji ulang host yang gagal.
- Menutup indikator progres sebelum dialog kegagalan ditampilkan agar kedua jendela tidak saling menumpuk.

## 1.6.3 — 2026-08-15

- Menambahkan jendela status koneksi yang langsung muncul saat membuka SSH atau menjalankan tes koneksi.
- Status menampilkan tahap pemeriksaan dependensi, koneksi VPN, host yang sedang diuji, urutan host, serta waktu berjalan dibanding timeout.
- Pengujian TCP sekarang dipantau per 100 ms sehingga UI tetap memberi umpan balik selama menunggu, bukan baru menampilkan popup setelah timeout.

## 1.6.2 — 2026-08-15

- Status bawah manager sekarang berubah otomatis setelah SCP selesai atau gagal, meskipun transfer berjalan pada tab Windows Terminal terpisah.
- Hasil menampilkan arah transfer, nama host, serta jumlah file dan folder sumber, misalnya **Selesai SCP Download: 8 file dari host el.d.mme.**
- Menambahkan file hasil transfer atomik dan pemantauan ringan di manager agar status tetap terbaca saat tab SCP ditutup otomatis.

## 1.6.1 — 2026-08-15

- Menghapus argumen PowerShell `-NoExit` saat opsi kembali ke manager aktif, sehingga tab SCP benar-benar tertutup setelah transfer sukses.
- Transfer gagal tetap menahan hasil sampai pengguna menekan Enter, kemudian kembali ke manager dan menutup tab SCP.
- Mode tanpa kembali otomatis tetap memakai `-NoExit` agar tab hasil SCP tidak berubah perilakunya.

## 1.6.0 — 2026-08-15

- Menambahkan opsi **Kembali ke manager setelah transfer SCP berhasil**, aktif secara default.
- Manager yang sama diminimalkan selama transfer lalu dipulihkan dan difokuskan kembali setelah SCP sukses, sehingga state daftar host tetap dipertahankan.
- Tab SCP keluar otomatis setelah berhasil; jika transfer gagal, tab tetap terbuka agar error dapat diperiksa.
- Menambahkan fallback untuk membuka profil Proper SSH Manager baru jika jendela sebelumnya sudah ditutup.

## 1.5.2 — 2026-08-14

- Memperketat pembacaan multi-select remote menggunakan indeks `SelectedItems[n]`, bukan enumerasi koleksi implisit PowerShell.
- Path hasil pilihan dipaksa menjadi `string[]` sebelum masuk ke state dialog dan launcher SCP.
- Banner tab SCP sekarang menampilkan versi aplikasi agar file runtime yang aktif dapat diverifikasi langsung.
- `Install.cmd` sekarang selalu menjalankan mode update paksa agar file instalasi lama benar-benar tertimpa.
- Runtime memiliki fallback untuk memecah kembali path absolut remote yang terlanjur tergabung dengan spasi.

## 1.5.1 — 2026-08-14

- Memperbaiki pilihan banyak file remote yang sebelumnya terbaca sebagai satu objek koleksi.
- Setiap path remote sekarang diekspansi menjadi argumen SCP tersendiri, bukan digabung dengan spasi menjadi satu nama file panjang.
- Menambahkan smoke check untuk mencegah regresi pembungkusan `SelectedItems` sebagai satu objek.

## 1.5.0 — 2026-08-14

- Upload SCP sekarang dapat memilih dan mengirim banyak file lokal sekaligus melalui dialog **Pilih file...**.
- Download SCP sekarang dapat memilih banyak file maupun folder remote dengan `Ctrl+klik` atau `Shift+klik`.
- Semua sumber diproses dalam satu perintah SCP, satu tab Windows Terminal, dan satu folder tujuan.
- Opsi Recursive otomatis aktif jika pilihan remote berisi folder.
- Daftar path diteruskan ke runtime sebagai JSON UTF-8 berformat Base64 agar spasi dan karakter khusus pada nama file tetap aman.

## 1.4.2 — 2026-08-14

- Memperbaiki path awal browser remote `~/` yang sebelumnya salah menjadi `/home/user/~/`.
- Prefix `~/` sekarang dipotong secara eksplisit sebelum digabungkan dengan `$HOME` server.
- Menambahkan smoke check agar browser remote selalu memetakan `~/` ke home directory yang benar.

## 1.4.1 — 2026-08-14

- Memperbaiki browser remote yang gagal dibuka dengan pesan `Cannot overwrite variable HOME`.
- Mengganti variabel kontrol `$home` menjadi `$homeButton` agar tidak bertabrakan dengan automatic variable `$HOME` milik PowerShell.
- Menambahkan smoke check untuk mencegah regresi nama variabel tersebut.

## 1.4.0 — 2026-08-14

- Menambahkan tombol **Pilih remote...** pada dialog transfer SCP.
- Menambahkan browser file remote melalui SSH dengan navigasi Home, Naik, Refresh, input path, dan double-click folder.
- Upload dapat memilih folder tujuan remote; download dapat memilih file maupun folder sumber remote.
- Browser remote mengikuti autentikasi password/private key/agent, port, jump host, host-key policy, dan VPN yang dipilih.
- Pemilihan folder remote untuk download otomatis mengaktifkan Recursive, sedangkan file otomatis menonaktifkannya.

## 1.3.5 — 2026-08-14

- Memperbaiki instalasi yang gagal membuat `ssh-askpass.exe` ketika environment `LIB` berisi path development yang sudah tidak tersedia.
- Kompilasi password helper sekarang mengisolasi `LIB` hanya selama proses `Add-Type` dan selalu memulihkan nilainya setelah selesai.
- Environment variable user maupun system tidak diubah permanen oleh installer.

## 1.3.4 — 2026-08-14

- Memperbaiki double-click pada host yang sebelumnya selalu memaksa layout `Single`.
- Double-click sekarang mengikuti layout yang sedang dipilih, sama seperti tombol **Buka SSH** dan shortcut `Ctrl+Enter`.
- Satu host tetap diduplikasi otomatis ke seluruh panel untuk layout 2, 3, atau 4 panel.

## 1.3.3 — 2026-08-14

- Memperbaiki ComboBox berbasis objek yang menampilkan teks mentah seperti `@{Id=...; Name=...}`.
- Meneruskan `ItemTemplateSelector` agar `DisplayMemberPath="Name"` tetap bekerja pada template gelap kustom.
- Meneruskan format item terpilih untuk menjaga tampilan ComboBox konsisten pada jendela utama dan dialog.

## 1.3.2 — 2026-08-14

- Mengganti template native `ButtonChrome` pada permukaan ComboBox yang masih tampil putih.
- Menambahkan template gelap penuh untuk field tertutup, tombol panah, hover, fokus, disabled, dan popup.
- Memastikan template berlaku konsisten pada semua ComboBox di jendela utama dan dialog.

## 1.3.1 — 2026-08-14

- Memperbaiki ComboBox dan daftar dropdown yang sebelumnya masih memakai warna putih bawaan Windows.
- Menyamakan warna field, popup, item normal, hover, selected, dan disabled dengan tema gelap aplikasi.
- Tema ComboBox diterapkan ke jendela utama serta seluruh dialog host, VPN, konfigurasi, dan SCP.

## 1.3.0 — 2026-08-14

- Menambahkan transfer SCP untuk upload dan download file/folder dari host terpilih.
- Transfer folder mendukung recursive, preserve timestamp/mode, dan kompresi.
- SCP memakai port, jump host, host-key policy, private key/agent/password, dan profil VPN yang sama dengan host SSH.
- Password otomatis tetap dilindungi DPAPI dan diberikan ke `scp.exe` melalui `SSH_ASKPASS`, bukan command line.
- Progres dan hasil transfer dibuka sebagai tab baru pada jendela Windows Terminal terakhir.
- Menambahkan tombol **SCP**, menu **Host → Transfer SCP**, dan shortcut `Ctrl+Shift+S`.

## 1.2.0 — 2026-08-13

- Installer menambahkan profil **Proper SSH Manager** melalui JSON fragment Windows Terminal tanpa menimpa `settings.json` pengguna.
- Ditambahkan shortcut Windows `Ctrl+Alt+S` dan shortcut Windows Terminal `Ctrl+Shift+F12` untuk membuka manager sebagai tab.
- Semua tab dan pane SSH sekarang dibuka di jendela Windows Terminal terakhir dengan target `-w 0`, bukan jendela baru.
- Opsi tutup setelah membuka terminal hanya menutup tab manager; tab/pane SSH tetap berjalan.
- Uninstaller membersihkan profil dan action Windows Terminal milik aplikasi.

## 1.1.1 — 2026-08-13

- Jika satu host dipilih, host yang sama sekarang diduplikasi untuk memenuhi seluruh panel layout.
- Contoh: satu host dengan layout Atas 1, bawah 2 membuka tiga sesi SSH ke host yang sama.

## 1.1.0 — 2026-08-13

- Layout menerima satu atau banyak host tanpa batas jumlah panel yang harus dipilih secara persis.
- Banyak host dibagi otomatis menjadi beberapa tab dalam satu jendela Windows Terminal.
- Setiap tab menggunakan kapasitas layout yang dipilih; tab terakhir memakai layout parsial yang sesuai.

## 1.0.2 — 2026-08-13

- Memusatkan teks dan checkbox pada data row secara vertikal.
- Menyamakan vertical alignment header dan isi tabel host.

## 1.0.1 — 2026-08-13

- Memperbaiki startup crash `The property 'Count' cannot be found on this object` ketika daftar host atau pilihan host masih kosong.
- Menormalkan hasil pilihan DataGrid sebagai array untuk kondisi 0, 1, maupun beberapa host.

## 1.0.0 — 2026-08-13

- Rilis awal aplikasi WPF PowerShell.
- CRUD host SSH dan profil VPN.
- Password SSH/VPN terenkripsi DPAPI CurrentUser.
- Dukungan password, private key, dan SSH agent.
- Enam layout Windows Terminal untuk 1–4 host.
- Pencarian, group, favorites, tags, notes, dan shortcut keyboard.
- Tes koneksi, import/export tanpa secret, backup konfigurasi, installer, dan uninstaller.
