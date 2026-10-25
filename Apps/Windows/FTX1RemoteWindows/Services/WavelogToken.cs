using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace FTX1RemoteWindows.Services;

/// The Wavelog API v2 token (wl2_…), kept in Windows Credential Manager as
/// a generic credential of this user — the Mac's WavelogToken, which keeps
/// it in the login keychain (user decision, over the settings file: it
/// grants write access to the log). Shows in Control Panel → Credential
/// Manager → Windows Credentials as "FTX1Remote/Wavelog".
public static class WavelogToken
{
    private const string Target = "FTX1Remote/Wavelog";
    private const int CredTypeGeneric = 1;
    private const int CredPersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;

    /// Debug builds only: use this token instead of the stored one, to test
    /// against another server without touching it (the Mac's
    /// logbook.wavelog.tokenOverride launch argument).
    public const string DebugOverrideVariable = "FTX1REMOTE_WAVELOG_TOKEN";

    /// Empty when none is stored.
    public static string Read()
    {
#if DEBUG
        if (Environment.GetEnvironmentVariable(DebugOverrideVariable) is { Length: > 0 } overrideToken)
        {
            return overrideToken;
        }
#endif
        if (!CredRead(Target, CredTypeGeneric, 0, out var pointer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error != ErrorNotFound)
            {
                AppLog.Write($"Logbook: reading the Wavelog API token failed: {new Win32Exception(error).Message}");
            }
            return "";
        }
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(pointer);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0)
            {
                return "";
            }
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.UTF8.GetString(bytes);
        }
        finally
        {
            CredFree(pointer);
        }
    }

    /// Stores `token`; an empty one removes the credential.
    public static void Write(string token)
    {
        if (token.Length == 0)
        {
            if (!CredDelete(Target, CredTypeGeneric, 0) && Marshal.GetLastWin32Error() is var error && error != ErrorNotFound)
            {
                AppLog.Write($"Logbook: removing the Wavelog API token failed: {new Win32Exception(error).Message}");
            }
            return;
        }
        var bytes = Encoding.UTF8.GetBytes(token);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new Credential
            {
                Type = CredTypeGeneric,
                TargetName = Target,
                Comment = "FTX1Remote Wavelog API token",
                CredentialBlobSize = bytes.Length,
                CredentialBlob = blob,
                Persist = CredPersistLocalMachine,
                UserName = "api-token",
            };
            if (!CredWrite(ref credential, 0))
            {
                AppLog.Write($"Logbook: storing the Wavelog API token failed: {new Win32Exception(Marshal.GetLastWin32Error()).Message}");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public int Flags;
        public int Type;
        public string TargetName;
        public string? Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref Credential credential, int flags);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);
}
