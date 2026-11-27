using System.Reflection;
using System.Runtime.InteropServices;

namespace FTX1RemoteWindows.Services;

/// Where this app's own native DLLs live: <output>\ft8\ft8lib.dll and
/// <output>\rade\ftx1rade.dll (or beside the app / test assembly). An
/// assembly can have only one DllImport resolver, so they share this one.
internal static class NativeDlls
{
    private static readonly Dictionary<string, string> Folders = new()
    {
        ["ft8lib"] = "ft8",
        ["ftx1rade"] = "rade",
    };

    static NativeDlls() => NativeLibrary.SetDllImportResolver(typeof(NativeDlls).Assembly, Resolve);

    /// Call from the static constructor of each P/Invoke class.
    public static void EnsureResolver()
    {
        // The static constructor does the work, once.
    }

    private static IntPtr Resolve(string name, Assembly assembly, DllImportSearchPath? path)
    {
        if (!Folders.TryGetValue(name, out var folder))
        {
            return IntPtr.Zero;
        }
        foreach (var candidate in new[]
        {
            Path.Combine(AppContext.BaseDirectory, folder, name + ".dll"),
            Path.Combine(AppContext.BaseDirectory, name + ".dll"),
        })
        {
            if (File.Exists(candidate) && NativeLibrary.TryLoad(candidate, out var handle))
            {
                return handle;
            }
        }
        return IntPtr.Zero;
    }
}
