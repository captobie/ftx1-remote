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
/// modelNumber/devicePath/baudRate), plus the audio link's on/off and
/// per-channel playback settings (same defaults as the Mac's
/// AudioPlaybackSettings).
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
        public bool AudioEnabled { get; set; } = true;
        public bool AudioChannelsSwapped { get; set; }
        public ChannelAudio MainAudio { get; set; } = new();
        public ChannelAudio SubAudio { get; set; } = new();
    }

    /// One receiver's playback settings. SquelchThreshold is SquelchGate's
    /// raw threshold (RMS at or below which a chunk counts as a quieting
    /// dip), not the inverted value the slider shows.
    public sealed class ChannelAudio
    {
        public double Volume { get; set; } = 0.8;
        public double SquelchThreshold { get; set; } = 0.015;
        public bool Muted { get; set; }
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

    /// Whether to open the :8532 audio link on connect. Off lets another
    /// client (the Mac) have the Pi's single audio-stream slot while this
    /// app keeps rig control.
    public static bool AudioEnabled
    {
        get => _cache.AudioEnabled;
        set
        {
            _cache.AudioEnabled = value;
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

    /// See AudioChannelSwapTracker. Persisted because the rig keeps its
    /// state across app launches, so the last known parity is the best guess.
    public static bool AudioChannelsSwapped
    {
        get => _cache.AudioChannelsSwapped;
        set
        {
            _cache.AudioChannelsSwapped = value;
            Save();
        }
    }

    /// Mutate the returned object, then call <see cref="SaveAudio"/>.
    public static ChannelAudio MainAudio => _cache.MainAudio;

    public static ChannelAudio SubAudio => _cache.SubAudio;

    public static void SaveAudio() => Save();

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
