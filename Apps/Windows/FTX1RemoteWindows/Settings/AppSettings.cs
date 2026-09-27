using System.Text.Json;

namespace FTX1RemoteWindows.Settings;

/// Where the radio's USB cable is plugged in — same split as the Mac's
/// RigctldSettings.ConnectionMode (Apps/Mac/FTX1RemoteMac/
/// RigctldSettings.swift): Remote talks to the Pi's always-on
/// rigctld.service over Tailscale; Local launches (or adopts) a rigctld.exe
/// on this PC against a USB-attached rig. Either way this app only ever
/// talks rigctld's TCP protocol — never CAT over the serial port itself.
public enum ConnectionMode
{
    Remote,
    Local,
}

/// Persists this app's settings: the connection mode, the Pi's Tailscale
/// MagicDNS hostname for Remote (port fixed at 4532, not configurable —
/// see Apps/Windows/README.md's "Settings" section, matching
/// RigctldSettings.remoteHost on the Mac side), and the rigctld launch
/// configuration for Local (mirroring RigctldSettings' binaryPath/
/// modelNumber/devicePath/baudRate).
///
/// File-based (not ApplicationData.Current.LocalSettings) because the
/// project currently builds unpackaged (WindowsPackageType=None — see
/// FTX1RemoteWindows.csproj's comment) and LocalSettings requires package
/// identity. Swap to LocalSettings once packaging flips to MSIX; the
/// static get/set surface below can stay the same either way.
public static class AppSettings
{
    private sealed class Data
    {
        // Remote by default: this app was remote-only before Local existed,
        // so an existing settings file (which has no ConnectionMode key)
        // keeps behaving exactly as it did.
        public ConnectionMode ConnectionMode { get; set; } = ConnectionMode.Remote;
        public string PiHost { get; set; } = "";
        public string RigctldPath { get; set; } = "";
        public int ModelNumber { get; set; } = 1051;
        public string ComPort { get; set; } = "";
        public int BaudRate { get; set; } = 38400;
    }

    private static readonly string SettingsPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FTX1RemoteWindows",
        "settings.json");

    private static Data _cache = Load();

    public static ConnectionMode ConnectionMode
    {
        get => _cache.ConnectionMode;
        set
        {
            _cache.ConnectionMode = value;
            Save();
        }
    }

    public static string PiHost
    {
        get => _cache.PiHost;
        set
        {
            _cache.PiHost = value;
            Save();
        }
    }

    /// Full path to hamlib's rigctld.exe. No default: hamlib's Windows
    /// installer puts it under a version-numbered folder (e.g.
    /// C:\Program Files\hamlib-w64-4.7\bin\rigctld.exe), so any fixed guess
    /// would be wrong after the next hamlib upgrade.
    public static string RigctldPath
    {
        get => _cache.RigctldPath;
        set
        {
            _cache.RigctldPath = value;
            Save();
        }
    }

    /// hamlib rig model number — 1051 is the FTX-1, same default as the
    /// Mac's RigctldSettings.modelNumber. Not exposed in the UI (this app
    /// only drives one radio); kept as a setting so a hamlib renumbering
    /// can be fixed by editing settings.json.
    public static int ModelNumber
    {
        get => _cache.ModelNumber;
        set
        {
            _cache.ModelNumber = value;
            Save();
        }
    }

    /// The rig's CAT serial port, e.g. "COM3" (the Enhanced COM port of the
    /// FTX-1's CP210x pair).
    public static string ComPort
    {
        get => _cache.ComPort;
        set
        {
            _cache.ComPort = value;
            Save();
        }
    }

    public static int BaudRate
    {
        get => _cache.BaudRate;
        set
        {
            _cache.BaudRate = value;
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
            // Best-effort — losing a saved setting isn't fatal, the user
            // just has to retype it next launch.
        }
    }
}
