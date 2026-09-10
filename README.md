# Proper SSH Manager

**Language:** **English** | [Bahasa Indonesia](README_ID.md)

Proper SSH Manager is a PowerShell-based WPF desktop application for managing SSH connections and SCP transfers on Windows. It combines a host list, VPN selection, automatic password handling, connection tests, quick search, and Windows Terminal workspaces with multiple pane layouts.

## Key features

- Notepad-style remote text editor: **Edit file** (`Ctrl+Shift+E`), save with `Ctrl+S`, Find, Undo/Redo, Word Wrap, and local copies.
- Host CRUD: add, edit, duplicate, and delete SSH IP addresses/hostnames.
- Automatic password authentication, private key authentication, or Windows OpenSSH Agent.
- SCP upload/download for one or multiple files/folders, including a remote-path browser, recursive transfers, timestamp/mode preservation, and compression.
- Passwords are encrypted using Windows DPAPI `CurrentUser`; only the Windows account that saved the password can decrypt it.
- Per-host VPN profiles: no VPN, Windows VPN/RAS, or a custom CLI command.
- VPN override when connecting: follow the host configuration, force no VPN, or force a specific VPN profile.
- Windows Terminal layouts:

  | Layout per tab | Capacity per tab | Selected-host order |
  | --- | ---: | --- |
  | 1 panel | 1 | each host gets its own tab |
  | Left / right | 2 | left, right |
  | Top / bottom | 2 | top, bottom |
  | Top 1, bottom 2 | 3 | top, bottom-left, bottom-right |
  | Top 2, bottom 1 | 3 | top-left, top-right, bottom |
  | 2 × 2 grid | 4 | top-left, top-right, bottom-left, bottom-right |

  If only one host is selected, the same host is opened in every pane of the selected layout. For example, one host with the **Top 1, bottom 2** layout creates three SSH connections to the same host.

  If multiple hosts are selected, they are distributed across the panes. If the number of hosts exceeds the layout capacity, the application creates additional tabs in the same Windows Terminal window. For example, 10 hosts with the 2 × 2 grid are split into tabs containing 4, 4, and 2 panes.

  If the table currently shows only one host, the **Buka SSH** (`Open SSH`) button automatically uses that host even if the row has not been clicked.

- Search by name, group, IP/hostname, username, tag, and notes.
- Automatic configuration backups; up to the latest 20 backups are kept.
- JSON configuration import/export. Passwords are intentionally excluded from exports.
- Safe host-key verification: default is `accept-new`, rather than disabling host-key checks.
- A live connection indicator shows the active stage, destination host, and elapsed time against the timeout when opening SSH or running a connection test.
- If the port test fails, the Indonesian UI displays the endpoint and reason for each host and offers **Coba lagi** (`Retry`), **Tetap buka SSH** (`Open SSH anyway`), or **Batal** (`Cancel`).

## Requirements

- Remote editor only: Linux server with `python3` and permission to read/write the file and create files in its parent directory. Python is not required on Windows for the application.
- Windows 10 or Windows 11.
- Windows PowerShell 5.1.
- OpenSSH Client (`ssh.exe`).
- OpenSSH SCP (`scp.exe`) for file transfers.
- Windows Terminal (`wt.exe`).
- `rasdial.exe` is required only when using Windows VPN/RAS profiles.

Check dependencies from **Konfigurasi → Periksa dependensi** (`Configuration → Check dependencies`).

After extracting the package, you can also validate it before installation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Smoke-Test.ps1
```

This test checks the syntax of all scripts, loads all XAML files, and runs a default configuration cycle in a temporary directory. Batch behavior tests can be run with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\ScpBatch-Test.ps1
```

The batch test uses temporary folders and simulated transfers without contacting a server. For Linux/WSL development, runtime-boundary testing with a simulated SCP executable is available through:

```bash
python3 Tests/ScpRuntime-Test.py --pwsh /path/to/pwsh
```

WPF display, Windows Terminal, DPAPI, and VPN behavior still need to be tested on Windows.

## Installation

1. Extract the ZIP file to a regular folder.
2. Right-click `Install.cmd`, then select **Run**. Administrator privileges are not required because the application is installed for the current Windows user.
3. The installer adds a **Proper SSH Manager** profile to Windows Terminal using a JSON fragment.
4. Shortcuts are created in the Start Menu and on the Desktop. The Start Menu shortcut also registers the Windows hotkey `Ctrl+Alt+S`.
5. Open **Proper SSH Manager**. The application appears as a new tab in the most recently used Windows Terminal window.

PowerShell alternative:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install.ps1 -LaunchAfterInstall
```

Program location:

```text
%LOCALAPPDATA%\Programs\ProperSSHManager
```

Configuration, encrypted-password, and backup location:

```text
%LOCALAPPDATA%\ProperSSHManager
```

Windows Terminal integration is created under:

```text
%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\ProperSSHManager\proper-ssh-manager.json
```

The installer does not modify or overwrite the user's main `settings.json`. The fragment adds the launcher profile, `closeOnExit: always`, and the `Ctrl+Shift+F12` action. The uninstaller removes only the fragment owned by Proper SSH Manager.

## Basic usage

1. Click **Tambah host** (`Add host`).
2. Enter the name, IP/hostname, port, username, and authentication method.
3. For automatic password login, select **Password otomatis** (`Automatic password`) and enter the password.
4. Select a VPN profile or **Tanpa VPN** (`No VPN`).
5. Save the host.
6. For one host, click its row. For multiple hosts, check the **Pilih** (`Select`) column for each host; `Ctrl+click`, `Shift+click`, and `Ctrl+A` on rows are still supported as alternatives.
7. Select a layout per tab. The host count does not need to match the number of panes.
8. Click **Buka SSH** (`Open SSH`) or press `Ctrl+Enter`.

SSH tabs and panes are always targeted at the most recently used Windows Terminal window (`wt.exe -w 0`). Windows Terminal's **New instance behavior** can remain set to **Create a new window**, because this explicit target overrides it. If no Terminal window exists, Windows Terminal creates one automatically.

If **Tutup hanya tab manager setelah terminal dibuka** (`Close only the manager tab after the terminal opens`) is enabled, the WPF application exits after the SSH command is accepted. The installed profile uses `closeOnExit: always`, so only the **Proper SSH Manager** tab disappears; SSH tabs and panes remain open.

## SCP transfers

1. Check the **Pilih** (`Select`) column for one or more nodes. The number of SCP nodes is not limited by the SSH layout.
2. Click **SCP**, open **Host → Transfer SCP**, or press `Ctrl+Shift+S`.
3. Select **Upload** or **Download**.
4. To upload multiple files, click **Pilih file...** (`Choose files...`) and select several files at once. The same local sources are sent to all selected nodes.
5. To upload a folder, click **Pilih folder...** (`Choose folder...`); **Recursive** is enabled automatically.
6. For downloads, click **Pilih remote...** (`Choose remote...`), then use `Ctrl+click` or `Shift+click` to select multiple remote files/folders. After that, choose one local destination folder.
7. In the remote browser, use Home, Up, Refresh, or double-click a folder. A single path can still be typed manually, for example `~/upload/` or `/var/tmp/file.txt`.
8. **Recursive** is automatically enabled when the selection contains a folder. Preserve and compression options can be enabled as needed.
9. If multiple nodes are selected, use **Atur path remote untuk node** (`Set remote path for node`) to choose a path and open the remote browser for each node. Switching nodes preserves the previous selection. **Terapkan path remote ke semua node** (`Apply remote path to all nodes`) copies the active node's path to every node; use it only when the path is valid for all of them. For example, `~/OLTS_MME/log` follows each user's home directory, while `/home/mme/...` remains the same absolute path.
10. Hover over **Path remote terisi** (`Remote path set`) to inspect the path list, then click **Mulai transfer** (`Start transfer`). The native `scp.exe` progress display appears in one Windows Terminal tab. Multiple nodes are processed **sequentially**; a failed node does not stop later nodes.

Multi-node downloads create folders such as:

```text
D:\Downloads\node-a-<ID>\
D:\Downloads\node-b-<ID>\
```

The ID suffix also distinguishes nodes that share the same name. A single-node download still uses the destination folder directly. Repeating a transfer to the same node/path follows normal SCP overwrite behavior; the subfolders prevent **cross-node** filename collisions, not file versioning.

The bottom status area shows progress such as `[1/3]`, followed by a summary such as **Selesai SCP Upload: 3 node | 3 berhasil, 0 gagal | Berhasil: 6 file**. This counts the selected sources per node rather than every file inside a recursive folder. Manually typed paths or paths copied to another node are counted as items when their file/folder type is unknown. Hover over the status to see each node's result, paths, and error message. The complete report is stored in:

```text
%LOCALAPPDATA%\ProperSSHManager\logs\scp-batch-<ID>.json
```

VPN is checked for the node currently being processed. VPN, authentication, connection-pretest, or SCP failures are recorded for that node. When a Jump Host is configured, the direct TCP pretest is skipped and the connection is made through the SSH jump host. **Tes koneksi sebelum membuka** (`Test connection before opening`) continues to follow the application setting. Closing the batch tab before completion causes the manager to mark unfinished nodes as interrupted; files already copied successfully remain in place.

The transfer banner displays the runtime version, for example **Proper SSH Manager 1.8.0**. After an update, verify that the expected version is shown so that the transfer does not use an older installed script.

By default, the manager is minimized while SCP is running. After all nodes succeed, the SCP PowerShell process exits, the SCP tab closes automatically, and the same manager window is restored to the foreground. The bottom status is updated with the final result, for example **Selesai SCP Download: 8 file dari host el.d.mme.** or **Selesai SCP Upload: 1 folder ke host el.d.mme.** If any node fails, the result remains visible until Enter is pressed to return to the manager, and the bottom status displays the failure. This automatic-return behavior can be changed through **Konfigurasi → Pengaturan aplikasi → Kembali ke manager setelah transfer SCP berhasil**.

SCP automatically uses the same port, username, jump host, host-key policy, authentication method, and VPN selection as the host configuration. For automatic password authentication, the password is still retrieved through the DPAPI helper and is never placed in process arguments.

The visible row order determines host position in the layout. Favorite hosts are shown first, followed by sorting by group and name.

Private keys must use OpenSSH format. PuTTY `.ppk` files must be converted to OpenSSH format first.

## Edit remote text files

1. Select a node using **Pilih**, then click **Edit file** or press `Ctrl+Shift+E`.
2. Use **Pilih file...** to browse the node, or enter a file path and click **Buka**.
3. Edit the text and press `Ctrl+S`. No terminal editor is opened.
4. **Cari** / `Ctrl+F` searches literal text; **Berikutnya** / `F3` finds the next occurrence. Copy/paste, Undo/Redo and Word Wrap are available.
5. If several nodes were selected, use the **Node** dropdown to switch. Each editor save applies to the currently opened file on one node.

The editor shows connecting, reading, saving and error status immediately. Unsaved changes are marked with `*`; closing, reloading or switching nodes/files offers **Simpan** (Save), **Buang perubahan** (Discard), or **Batal** (Cancel). A failed read or save keeps the current text available. **Simpan salinan lokal...** exports a copy without marking the remote document as saved.

Supported files: existing regular text files up to **2 MiB**, encoded as UTF-8 (with or without BOM) or UTF-16 LE/BE with BOM. Binary files and unsupported encodings are refused. The original encoding, line ending and final newline are retained; the line-ending selector can explicitly choose LF, CRLF or CR. Mixed line endings are retained byte for byte when text is unchanged; after an edit they use the selected line ending, with a notice in the editor.

**Buat backup sebelum simpan** is enabled by default. A backup named `.proper-backup-<timestamp>-<random>` is placed in the same remote directory and its full path appears after saving. Backups are not deleted automatically. Saving uses a temporary file and atomic replacement, preserves owner/group, mode and extended attributes, and stops if they cannot be preserved. Symlinks keep pointing to their resolved target; hard-linked files cannot be saved in this editor. Your SSH user needs permission to modify both the file and its directory; the editor does not elevate with sudo.

Before saving, the version is compared with the file on the server. A conflict keeps your edits and lets you export a local copy or reload. Concurrent saves by this editor are serialized within the containing directory. External programs must cooperate with the same advisory lock for full concurrency protection; avoid editing the same file simultaneously elsewhere. After a save timeout or lost connection, reload to check whether the server accepted the save before retrying.

The remote server needs Linux and `python3` (standard library only, no pip packages). The helper is sent over SSH for each operation and is not installed on the server. The same node authentication, port, jump host, host-key policy and VPN override are used as the remote browser. Python is not required on Windows to use the editor.

## VPN configuration

### Windows VPN / RAS

1. Create the VPN connection first in Windows Settings.
2. In the application, open **VPN → Kelola profil VPN** (`VPN → Manage VPN profiles`).
3. Select **Windows VPN / RAS**.
4. Enter the connection name exactly as it appears in Windows.
5. If Windows already stores the VPN credentials, leave username/password empty. The application runs `rasdial "VPN Name"`.
6. If a username is provided, the password is stored encrypted using DPAPI.

### FortiClient, OpenVPN, or other clients

Select **Perintah khusus** (`Custom command`), then enter CLI commands that are actually supported by your VPN client version:

- **Perintah connect** (`Connect command`): starts the connection.
- **Perintah pengecekan** (`Check command`): must return exit code `0` when connected and a non-zero code otherwise.
- **Perintah disconnect** (`Disconnect command`): disconnects the VPN.
- Enable **Run as Administrator** if the VPN client requires it.

Example adapter check; adjust the interface name as needed:

```powershell
if (Get-NetAdapter -Name 'Fortinet*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up') { exit 0 } else { exit 1 }
```

Do not put passwords directly in custom-command fields because command lines may be visible to other processes. Use the VPN application's credential storage when available.

## Shortcuts

| Shortcut | Function |
| --- | --- |
| `Ctrl+Alt+S` | Open Proper SSH Manager from Windows through the Start Menu shortcut |
| `Ctrl+Shift+F12` | Open Proper SSH Manager as a new tab while Windows Terminal is active |
| `Ctrl+F` | Focus search |
| `Ctrl+N` | Add host |
| `Ctrl+E` | Edit host |
| `Ctrl+Shift+E` | Open remote file editor |
| `Ctrl+D` | Duplicate host |
| `Ctrl+Shift+S` | Upload or download via SCP |
| `Delete` | Delete host |
| `Ctrl+Enter` | Open SSH |
| `F5` | Refresh the list |
| `Alt+1` through `Alt+6` | Select layout |
| **Pilih** (`Select`) checkbox | Select one host for each layout pane |
| `Ctrl+click` | Select multiple hosts |
| `Shift+click` | Select a range of hosts |
| `Ctrl+A` | Select all hosts while the table has focus |

## Password security

- Passwords are not stored in plain text.
- Secret files are protected using DPAPI for the current Windows user, and file ACLs are tightened where supported.
- Passwords are passed to OpenSSH through the `SSH_ASKPASS` helper; they are not included in `ssh.exe` or `scp.exe` arguments.
- Exported configuration files do not include secret files.
- Moving a secret file to another computer or Windows account does not make the password decryptable there.
- For production servers, key + agent authentication is still preferable to password authentication.

## Troubleshooting

### `ssh.exe` not found

Run PowerShell as Administrator:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

### `wt.exe` not found

Install Windows Terminal:

```powershell
winget install --id Microsoft.WindowsTerminal -e
```

Make sure the Windows Terminal **App execution alias** is enabled in Windows Settings.

### Password is still requested or login is rejected

- Edit the host and save the password again.
- Make sure the server allows `PasswordAuthentication` or `keyboard-interactive`.
- Make sure the username is correct.
- Run **Konfigurasi → Periksa dependensi** (`Configuration → Check dependencies`) to rebuild the password helper.

The installer temporarily isolates the `LIB` environment variable while building the password helper. Visual Studio/C++ library paths in the user environment are not deleted or permanently changed.

### Host identification changed warning

Do not disable host-key checking. Verify that the host-key change is legitimate, then remove only the affected entry:

```powershell
ssh-keygen -R "[hostname]:port"
```

### VPN is connected but the server IP is still unreachable

- Check routes with `route print`.
- Check the port with `Test-NetConnection IP_SERVER -Port 22`.
- Make sure VPN split tunneling and firewall rules allow the server subnet.
- For Fortinet/OpenVPN, adjust the check command to match the actual adapter name.

## Uninstall

From Windows Settings → Apps → Installed apps, select **Proper SSH Manager**, or run:

```powershell
& "$env:LOCALAPPDATA\Programs\ProperSSHManager\Uninstall.ps1"
```

By default, configuration and encrypted passwords are preserved so they can be reused later. To remove everything:

```powershell
& "$env:LOCALAPPDATA\Programs\ProperSSHManager\Uninstall.ps1" -RemoveUserData
```
