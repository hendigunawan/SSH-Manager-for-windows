using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

internal static class AskPass
{
    [STAThread]
    private static int Main()
    {
        byte[] protectedBytes = null;
        byte[] clearBytes = null;
        try
        {
            string path = Environment.GetEnvironmentVariable("SSH_MANAGER_SECRET_FILE");
            if (String.IsNullOrWhiteSpace(path) || !File.Exists(path))
                return 2;

            string encoded = File.ReadAllText(path, Encoding.UTF8)
                .Trim('\uFEFF', '\u200B', ' ', '\t', '\r', '\n');

            if (encoded.Length == 0 || (encoded.Length % 2) != 0)
                return 3;

            protectedBytes = new byte[encoded.Length / 2];
            for (int i = 0; i < protectedBytes.Length; i++)
                protectedBytes[i] = Convert.ToByte(encoded.Substring(i * 2, 2), 16);

            clearBytes = ProtectedData.Unprotect(
                protectedBytes,
                null,
                DataProtectionScope.CurrentUser
            );

            Console.OutputEncoding = new UTF8Encoding(false);
            Console.WriteLine(Encoding.Unicode.GetString(clearBytes));
            return 0;
        }
        catch
        {
            return 4;
        }
        finally
        {
            if (protectedBytes != null)
                Array.Clear(protectedBytes, 0, protectedBytes.Length);
            if (clearBytes != null)
                Array.Clear(clearBytes, 0, clearBytes.Length);
        }
    }
}
