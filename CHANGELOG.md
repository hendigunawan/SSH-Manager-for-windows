# Changelog

**Language:** **English** | [Bahasa Indonesia](CHANGELOG_ID.md)

## 1.7.5 — 2026-09-09

- Fixed multi-node SCP batch downloads so multiple remote paths are always passed as separate SCP arguments instead of being interpreted as one long path.
- Fixed multi-node SCP batch uploads so multiple local file paths are always split into separate source items before validation and transfer.
- Added compatibility normalization for older batch manifests that still store multiple remote or local paths in a single string.
- Preserved the native `scp.exe` progress meter in batch mode by running the process with the same console handles.
- Removed SCP command debug output from the transfer view to keep the terminal clean during normal use.

## 1.7.0 — 2026-09-08

- SCP now supports multiple nodes selected through the **Pilih** (`Select`) checkboxes, processed sequentially in a single Windows Terminal tab.
- Upload uses the same local sources for every selected node; the remote destination path can be configured per node.
- Download can use different remote sources for each node. Multi-node results are separated into node-name-ID subfolders to prevent filename collisions between nodes.
- The dialog includes a node selector, a remote browser for each node, and an **Apply remote path to all nodes** action.
- A failed node is still recorded and the queue continues to the next node. The bottom status shows the active node, success/failure counts, and total source items from successful transfers.
- Per-node details are available in the status tooltip and in JSON reports under the logs folder. Closing the SCP tab before completion is detected as an interrupted transfer.
- VPN, port, jump host, key, password, and host-key policy continue to follow each node's configuration and VPN override.
- The manager is restored once after the full queue finishes. If any transfer fails, the tab waits for Enter so the details can be reviewed.
- The batch manifest preserves every path as a separate item; filenames containing spaces, quotation marks, or semicolons are not merged.
- Added queue-behavior tests and runtime integration tests using a simulated SCP process without contacting a server.

## 1.6.5 — 2026-08-15

- Added a dedicated **Pilih** (`Select`) checkbox column so multiple hosts can be mapped to different layout panes without holding Ctrl.
- Separated the star-shaped Favorite indicator from the connection-selection checkbox to avoid confusing the two purposes.
- Checked hosts are now the primary source for SSH, connection tests, and SCP; Ctrl/Shift row selection remains supported as an alternative.
- Checkbox selections are preserved when the list is filtered or refreshed, and cleared when a host is deleted or configuration is imported.

## 1.6.4 — 2026-08-15

- Replaced the default Windows connection-failure popup that still used **Yes/No** buttons with a dark-themed Indonesian dialog.
- The dialog shows the host name, username, IP/hostname, port, and full failure reason.
- Added **Coba lagi** (`Retry`), **Tetap buka SSH** (`Open SSH anyway`), and **Batal** (`Cancel`); Retry only retests hosts that failed.
- The progress indicator is closed before the failure dialog appears so the two windows do not overlap.

## 1.6.3 — 2026-08-15

- Added a connection-status window that appears immediately when opening SSH or running a connection test.
- The status shows dependency checks, VPN connection, the host currently being tested, host sequence, and elapsed time compared with the timeout.
- TCP testing is now polled every 100 ms so the UI keeps providing feedback while waiting instead of showing a popup only after the timeout.

## 1.6.2 — 2026-08-15

- The manager's bottom status now updates automatically after SCP succeeds or fails, even when the transfer runs in a separate Windows Terminal tab.
- Results show transfer direction, host name, and the number of source files/folders, for example **Selesai SCP Download: 8 file dari host el.d.mme.**
- Added atomic transfer-result files and lightweight polling in the manager so status remains readable even when the SCP tab closes automatically.

## 1.6.1 — 2026-08-15

- Removed the PowerShell `-NoExit` argument when automatic return to the manager is enabled, so the SCP tab really closes after a successful transfer.
- Failed transfers still keep the result visible until the user presses Enter, then return to the manager and close the SCP tab.
- Mode without automatic return still uses `-NoExit` so its existing SCP-result behavior does not change.

## 1.6.0 — 2026-08-15

- Added **Kembali ke manager setelah transfer SCP berhasil** (`Return to manager after successful SCP transfer`), enabled by default.
- The same manager window is minimized during transfer, then restored and focused again after SCP succeeds, preserving the host-list state.
- The SCP tab exits automatically after success; if the transfer fails, the tab remains open so the error can be reviewed.
- Added a fallback that opens a new Proper SSH Manager profile if the previous window has already been closed.

## 1.5.2 — 2026-08-14

- Hardened remote multi-selection by reading `SelectedItems[n]` by index instead of relying on implicit PowerShell collection enumeration.
- Selected paths are forced into `string[]` before entering dialog state and the SCP launcher.
- The SCP tab banner now displays the application version so the active runtime file can be verified directly.
- `Install.cmd` now always runs forced update mode so old installation files are actually overwritten.
- Runtime includes a fallback that re-splits absolute remote paths that were accidentally merged with spaces.

## 1.5.1 — 2026-08-14

- Fixed multi-file remote selection being interpreted as one collection object.
- Each remote path is now expanded into its own SCP argument instead of being joined with spaces into one long filename.
- Added a smoke check to prevent regressions where `SelectedItems` becomes wrapped as one object.

## 1.5.0 — 2026-08-14

- SCP upload can now select and send multiple local files at once through **Pilih file...** (`Choose files...`).
- SCP download can now select multiple remote files or folders using `Ctrl+click` or `Shift+click`.
- All sources are processed in one SCP command, one Windows Terminal tab, and one destination folder.
- **Recursive** is enabled automatically if the remote selection contains a folder.
- Path lists are passed to runtime as Base64-encoded UTF-8 JSON so spaces and special characters in filenames remain safe.

## 1.4.2 — 2026-08-14

- Fixed the initial remote-browser path `~/` previously becoming `/home/user/~/`.
- The `~/` prefix is now explicitly removed before combining it with the server's `$HOME`.
- Added a smoke check to ensure the remote browser always maps `~/` to the correct home directory.

## 1.4.1 — 2026-08-14

- Fixed the remote browser failing to open with `Cannot overwrite variable HOME`.
- Renamed the `$home` control variable to `$homeButton` to avoid colliding with PowerShell's automatic `$HOME` variable.
- Added a smoke check to prevent regression of this variable-name conflict.

## 1.4.0 — 2026-08-14

- Added a **Pilih remote...** (`Choose remote...`) button to the SCP transfer dialog.
- Added an SSH remote-file browser with Home, Up, Refresh, path input, and double-click folder navigation.
- Upload can select a remote destination folder; download can select remote files or folders as sources.
- The remote browser follows the selected host's password/private-key/agent authentication, port, jump host, host-key policy, and VPN.
- Selecting a folder for download automatically enables Recursive, while selecting a file disables it automatically.

## 1.3.5 — 2026-08-14

- Fixed installation failures while building `ssh-askpass.exe` when the `LIB` environment variable contains development paths that no longer exist.
- Password-helper compilation now isolates `LIB` only during `Add-Type` and always restores its original value afterward.
- User and system environment variables are not permanently modified by the installer.

## 1.3.4 — 2026-08-14

- Fixed double-click on a host always forcing the `Single` layout.
- Double-click now follows the currently selected layout, matching the **Buka SSH** (`Open SSH`) button and `Ctrl+Enter`.
- A single host is still duplicated automatically across all panes for 2-, 3-, or 4-pane layouts.

## 1.3.3 — 2026-08-14

- Fixed object-based ComboBoxes displaying raw text such as `@{Id=...; Name=...}`.
- Passed through `ItemTemplateSelector` so `DisplayMemberPath="Name"` continues to work with the custom dark template.
- Passed through selected-item formatting to keep ComboBox rendering consistent in the main window and dialogs.

## 1.3.2 — 2026-08-14

- Replaced native `ButtonChrome` on ComboBox surfaces that still appeared white.
- Added a full dark template for closed fields, arrow buttons, hover, focus, disabled state, and popup.
- Ensured the template is applied consistently to all ComboBoxes in the main window and dialogs.

## 1.3.1 — 2026-08-14

- Fixed ComboBoxes and dropdown lists that were still using the default white Windows appearance.
- Matched normal, hover, selected, disabled, field, and popup colors to the application's dark theme.
- Applied the ComboBox theme to the main window and all host, VPN, configuration, and SCP dialogs.

## 1.3.0 — 2026-08-14

- Added SCP file/folder upload and download for selected hosts.
- Folder transfers support recursive mode, timestamp/mode preservation, and compression.
- SCP uses the same port, jump host, host-key policy, private key/agent/password, and VPN profile as SSH.
- Automatic passwords remain protected with DPAPI and are supplied to `scp.exe` through `SSH_ASKPASS`, not the command line.
- Transfer progress and results are opened as a new tab in the most recently used Windows Terminal window.
- Added the **SCP** button, **Host → Transfer SCP** menu item, and `Ctrl+Shift+S` shortcut.

## 1.2.0 — 2026-08-13

- The installer adds a **Proper SSH Manager** profile through a Windows Terminal JSON fragment without overwriting the user's `settings.json`.
- Added Windows hotkey `Ctrl+Alt+S` and Windows Terminal shortcut `Ctrl+Shift+F12` to open the manager as a tab.
- All SSH tabs and panes now open in the most recent Windows Terminal window using `-w 0`, rather than creating a new window.
- The option to close after opening Terminal only closes the manager tab; SSH tabs and panes remain running.
- The uninstaller removes only the Windows Terminal profile and actions owned by the application.

## 1.1.1 — 2026-08-13

- If one host is selected, the same host is now duplicated to fill every pane in the layout.
- Example: one host with the Top 1, bottom 2 layout opens three SSH sessions to that same host.

## 1.1.0 — 2026-08-13

- Layouts now accept one or multiple hosts without requiring the host count to exactly match the number of panes.
- Multiple hosts are distributed automatically across several tabs in one Windows Terminal window.
- Each tab uses the selected layout capacity; the last tab uses an appropriate partial layout.

## 1.0.2 — 2026-08-13

- Vertically centered text and checkboxes in data rows.
- Matched the vertical alignment of table headers and row contents.

## 1.0.1 — 2026-08-13

- Fixed startup crash `The property 'Count' cannot be found on this object` when the host list or host selection is empty.
- Normalized DataGrid selection results as arrays for 0, 1, or multiple hosts.

## 1.0.0 — 2026-08-13

- Initial PowerShell WPF application release.
- CRUD for SSH hosts and VPN profiles.
- SSH/VPN passwords encrypted with DPAPI `CurrentUser`.
- Password, private key, and SSH agent support.
- Six Windows Terminal layouts for 1–4 hosts.
- Search, groups, favorites, tags, notes, and keyboard shortcuts.
- Connection tests, import/export without secrets, configuration backups, installer, and uninstaller.
