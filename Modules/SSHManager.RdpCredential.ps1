# RDP credentials live only in Windows Credential Manager (target TERMSRV/<host>, read by mstsc).
# The password is passed as SecureString to CredWrite and never written to JSON, logs or argv.

function Initialize-SSHManagerCredentialStore {
    if ('SSHManagerCredentialStore' -as [type]) { return }
    $originalCompilerLib = [Environment]::GetEnvironmentVariable('LIB', [EnvironmentVariableTarget]::Process)
    try {
        [Environment]::SetEnvironmentVariable('LIB', $null, [EnvironmentVariableTarget]::Process)
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security;

public static class SSHManagerCredentialStore
{
    public const uint DomainPassword = 2;
    private const uint PersistLocalMachine = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    public static void Write(string target, string userName, SecureString password)
    {
        IntPtr blob = IntPtr.Zero;
        try
        {
            blob = Marshal.SecureStringToGlobalAllocUnicode(password);
            CREDENTIAL credential = new CREDENTIAL();
            credential.Type = DomainPassword;
            credential.TargetName = target;
            credential.UserName = userName;
            credential.CredentialBlob = blob;
            credential.CredentialBlobSize = (uint)(password.Length * 2);
            credential.Persist = PersistLocalMachine;
            if (!CredWrite(ref credential, 0)) { throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
        }
        finally
        {
            if (blob != IntPtr.Zero) { Marshal.ZeroFreeGlobalAllocUnicode(blob); }
        }
    }

    public static string ReadUserName(string target)
    {
        IntPtr pointer;
        if (!CredRead(target, DomainPassword, 0, out pointer)) { return null; }
        try
        {
            CREDENTIAL credential = (CREDENTIAL)Marshal.PtrToStructure(pointer, typeof(CREDENTIAL));
            return credential.UserName ?? string.Empty;
        }
        finally { CredFree(pointer); }
    }

    public static bool Delete(string target)
    {
        return CredDelete(target, DomainPassword, 0);
    }
}
'@
    }
    finally {
        [Environment]::SetEnvironmentVariable('LIB', $originalCompilerLib, [EnvironmentVariableTarget]::Process)
    }
}

function Get-RdpCredentialTarget {
    param([Parameter(Mandatory = $true)][string]$HostName)
    $address = $HostName.Trim()
    if ([string]::IsNullOrWhiteSpace($address)) { throw 'Host RDP wajib diisi.' }
    return 'TERMSRV/{0}' -f $address
}

function Save-RdpCredential {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][Security.SecureString]$Password
    )
    if ([string]::IsNullOrWhiteSpace($Username)) { throw 'Username RDP wajib diisi untuk menyimpan credential.' }
    Initialize-SSHManagerCredentialStore
    [SSHManagerCredentialStore]::Write((Get-RdpCredentialTarget -HostName $HostName), $Username.Trim(), $Password)
}

function Get-RdpCredential {
    param([Parameter(Mandatory = $true)][string]$HostName)
    Initialize-SSHManagerCredentialStore
    $target = Get-RdpCredentialTarget -HostName $HostName
    $userName = [SSHManagerCredentialStore]::ReadUserName($target)
    # Only presence and user name are returned; the password is never read back.
    return [pscustomobject]@{ Target = $target; Exists = ($null -ne $userName); Username = [string]$userName }
}

function Remove-RdpCredential {
    param([Parameter(Mandatory = $true)][string]$HostName)
    Initialize-SSHManagerCredentialStore
    return [SSHManagerCredentialStore]::Delete((Get-RdpCredentialTarget -HostName $HostName))
}
