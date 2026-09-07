using System.Text.Json;

namespace FTX1RemoteWindows.Settings;

/// Persists the one setting this app has: the Pi's Tailscale MagicDNS
/// hostname (port is fixed at 4532, not configurable — see
/// Apps/Windows/README.md's "Settings" section, matching
/// RigctldSettings.remoteHost on the Mac side).
///
/// File-based (not ApplicationData.Current.LocalSettings) because the
/// project currently builds unpackaged (WindowsPackageType=None — see
/// FTX1RemoteWindows.csproj's comment) and LocalSettings requires package
/// identity. Swap to LocalSettings once packaging flips to MSIX; the
/// static Host get/set surface below can stay the same either way.
public static class AppSettings
{
    private sealed class Data
    {
        public string PiHost { get; set; } = "";
    }

    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FTX1RemoteWindows",
        "settings.json");

    private static Data _cache = Load();

    public static string PiHost
    {
        get => _cache.PiHost;
        set
        {
            _cache.PiHost = value;
            Save();
        }
    }

    private static Data Load()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                var json = File.ReadAllText(SettingsPath);
                return JsonSerializer.Deserialize<Data>(json) ?? new Data();
            }
        }
        catch
        {
            // Corrupt or unreadable settings file — fall back to defaults
            // rather than crashing app startup over a saved preference.
        }
        return new Data();
    }

    private static void Save()
    {
        try
        {
            var dir = Path.GetDirectoryName(SettingsPath)!;
            Directory.CreateDirectory(dir);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(_cache));
        }
        catch
        {
            // Best-effort — losing a saved hostname isn't fatal, the user
            // just has to retype it next launch.
        }
    }
}
