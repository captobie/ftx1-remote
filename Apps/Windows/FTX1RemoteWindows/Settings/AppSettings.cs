using System.Text.Json;
using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Services;

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
        public bool TransmitEnabled { get; set; } = true;
        public string LocalAudioDeviceId { get; set; } = "";
        public string LocalAudioDeviceName { get; set; } = "";
        public string AudioOutputDeviceId { get; set; } = "";
        public string AudioOutputDeviceName { get; set; } = "";
        public bool AudioChannelsSwapped { get; set; }
        public ChannelAudio MainAudio { get; set; } = new();
        public ChannelAudio SubAudio { get; set; } = new();
        public MeterSelection MainMeterSelection { get; set; } = MeterSelection.Po;
        public MeterSelection SubMeterSelection { get; set; } = MeterSelection.Po;
        public bool WpsdEnabled { get; set; }
        public string WpsdHost { get; set; } = "";
        public int PollIntervalMs { get; set; } = PollIntervalMsSetting.Default;
        public int SlowPollEvery { get; set; } = SlowPollEverySetting.Default;
        public int WpsdCallerSeconds { get; set; } = WpsdCallerSecondsSetting.Default;
        public int WpsdReflectorSeconds { get; set; } = WpsdReflectorSecondsSetting.Default;
        /// Keyed by HomeBand.Name; a missing band uses its factory frequency.
        public Dictionary<string, long> HomeFrequencies { get; set; } = new();
        public AppTheme Theme { get; set; } = AppTheme.System;
        public ButtonValueColor ButtonValueColor { get; set; } = ButtonValueColor.Orange;
        public ScopeDisplayMode ScopeDisplayMode { get; set; } = ScopeDisplayMode.Waterfall;
    }

    /// One Polling-tab value: its default and allowed range. Every getter
    /// clamps, so a hand-edited 0 in settings.json can't turn a loop into a
    /// tight spin against rigctld or the hotspot (the Mac's
    /// PollingSettings.Setting, same reason).
    public readonly record struct IntSetting(int Default, int Min, int Max)
    {
        public int Clamp(int value) => Math.Clamp(value, Min, Max);
    }

    /// Poll tick interval — the Mac's fast-tier default and range.
    public static readonly IntSetting PollIntervalMsSetting = new(500, 100, 5_000);
    /// The slow tier (FR, C4FM, MENU grid) runs on every Nth poll: 10 × 500
    /// ms keeps it at ~5 s. The Mac spreads its slow reads over every tick
    /// instead ("reads per tick"); this app still reads the whole slow tier
    /// at once, so its setting stays "every N polls".
    public static readonly IntSetting SlowPollEverySetting = new(10, 1, 60);
    /// The Mac's WPSD lookup defaults and ranges.
    public static readonly IntSetting WpsdCallerSecondsSetting = new(3, 1, 60);
    public static readonly IntSetting WpsdReflectorSecondsSetting = new(30, 5, 600);

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

    /// The Enable Transmit safety cutoff — see TransmitGate. Defaults to on
    /// (an existing settings file has no key for it), same as the Mac's
    /// RigctldSettings.transmitEnabled, so upgrading doesn't silently stop
    /// PTT working.
    public static bool TransmitEnabled
    {
        get => _cache.TransmitEnabled;
        set
        {
            _cache.TransmitEnabled = value;
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

    /// Local mode's audio input: a Windows capture endpoint ID (stable across
    /// reboots and replugs into the same port), plus its name for showing it
    /// while it isn't plugged in.
    public static void SetLocalAudioDevice(string id, string name)
    {
        _cache.LocalAudioDeviceId = id;
        _cache.LocalAudioDeviceName = name;
        Save();
    }

    public static string LocalAudioDeviceId => _cache.LocalAudioDeviceId;

    /// Playback output device ("" = Windows' default output), both modes.
    public static void SetAudioOutputDevice(string id, string name)
    {
        _cache.AudioOutputDeviceId = id;
        _cache.AudioOutputDeviceName = name;
        Save();
    }

    public static string AudioOutputDeviceId => _cache.AudioOutputDeviceId;

    public static string AudioOutputDeviceName => _cache.AudioOutputDeviceName;

    public static string LocalAudioDeviceName => _cache.LocalAudioDeviceName;

    /// What each S-meter's lower scale shows while transmitting (see
    /// Controls/SMeter). PO by default, like the rig; Main and Sub are
    /// remembered separately, like the Mac's MeterSettings.key/subKey.
    public static MeterSelection MainMeterSelection
    {
        get => _cache.MainMeterSelection;
        set
        {
            _cache.MainMeterSelection = value;
            Save();
        }
    }

    public static MeterSelection SubMeterSelection
    {
        get => _cache.SubMeterSelection;
        set
        {
            _cache.SubMeterSelection = value;
            Save();
        }
    }

    /// The WPSD hotspot callsign lookup (Services/WpsdCallsignMonitor.cs),
    /// the Mac's WPSDSettings: off by default, and an empty host keeps it
    /// off either way. The host is an IP or hostname, optionally with a
    /// port (e.g. "192.168.1.50" or "pi-star.local:8080").
    public static bool WpsdEnabled
    {
        get => _cache.WpsdEnabled;
        set
        {
            _cache.WpsdEnabled = value;
            Save();
        }
    }

    public static string WpsdHost
    {
        get => _cache.WpsdHost;
        set
        {
            _cache.WpsdHost = value;
            Save();
        }
    }

    public static int PollIntervalMs
    {
        get => PollIntervalMsSetting.Clamp(_cache.PollIntervalMs);
        set
        {
            _cache.PollIntervalMs = PollIntervalMsSetting.Clamp(value);
            Save();
        }
    }

    public static int SlowPollEvery
    {
        get => SlowPollEverySetting.Clamp(_cache.SlowPollEvery);
        set
        {
            _cache.SlowPollEvery = SlowPollEverySetting.Clamp(value);
            Save();
        }
    }

    /// Read by WpsdCallsignMonitor before each wait, so a change applies
    /// from the next fetch.
    public static int WpsdCallerSeconds
    {
        get => WpsdCallerSecondsSetting.Clamp(_cache.WpsdCallerSeconds);
        set
        {
            _cache.WpsdCallerSeconds = WpsdCallerSecondsSetting.Clamp(value);
            Save();
        }
    }

    public static int WpsdReflectorSeconds
    {
        get => WpsdReflectorSecondsSetting.Clamp(_cache.WpsdReflectorSeconds);
        set
        {
            _cache.WpsdReflectorSeconds = WpsdReflectorSecondsSetting.Clamp(value);
            Save();
        }
    }

    /// The MENU grid HOME button's frequency for a band group — the Mac's
    /// HomeFrequencySettings. The factory frequency until one is saved.
    public static long HomeFrequencyHz(HomeBand band) =>
        _cache.HomeFrequencies.TryGetValue(band.Name, out var hz) && hz > 0 ? hz : band.FrequencyHz;

    /// Saving a band's factory frequency drops its entry, so a later change
    /// to the factory table still reaches it.
    public static void SetHomeFrequencyHz(HomeBand band, long hz)
    {
        if (hz == band.FrequencyHz)
        {
            _cache.HomeFrequencies.Remove(band.Name);
        }
        else
        {
            _cache.HomeFrequencies[band.Name] = hz;
        }
        Save();
    }

    public static AppTheme Theme
    {
        get => _cache.Theme;
        set
        {
            _cache.Theme = value;
            Save();
        }
    }

    public static ButtonValueColor ButtonValueColor
    {
        get => _cache.ButtonValueColor;
        set
        {
            _cache.ButtonValueColor = value;
            Save();
        }
    }

    /// The waterfall/oscilloscope column's mode (the Mac's ScopeDisplayMode
    /// @AppStorage).
    public static ScopeDisplayMode ScopeDisplayMode
    {
        get => _cache.ScopeDisplayMode;
        set
        {
            _cache.ScopeDisplayMode = value;
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
