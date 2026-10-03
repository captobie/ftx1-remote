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
        public int FrequencyStepHz { get; set; } = 1_000;
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
        public bool AprsEnabled { get; set; }
        public long AprsFrequencyHz { get; set; } = DefaultAprsFrequencyHz;
        public int AprsToleranceHz { get; set; } = AprsToleranceHzSetting.Default;
        public int AprsMaxStations { get; set; } = AprsMaxStationsSetting.Default;
        public int AprsMaxMessages { get; set; } = AprsMaxMessagesSetting.Default;
        public string GridSquare { get; set; } = "";
        public string Callsign { get; set; } = "";
        public string WebSdrHostPort { get; set; } = "";
        public bool WebSdrFollowRig { get; set; } = true;
        public bool WebSdrTuneRig { get; set; } = true;
        public bool WebSdrMuted { get; set; }
        public bool WebSdrMuteOnTransmit { get; set; } = true;
        public CwAudioChannel CwChannel { get; set; } = CwAudioChannel.Main;
        public double CwToneFrequency { get; set; } = 700;
        public bool CwAutoTune { get; set; } = true;
        public double CwSquelchDb { get; set; } = 12;
        public int CwKeyerSlot { get; set; } = 1;
        public CwDecoderKind CwDecoder { get; set; } = CwDecoderKind.Neural;
        public List<CwMacro>? CwMacros { get; set; }
        public WebSdrFavorite? WebSdrPickedStation { get; set; }
        public List<WebSdrFavorite> WebSdrFavorites { get; set; } = [];
        public string? WebSdrDirectoryETag { get; set; }
        public SdrPlatform WebSdrStationsTab { get; set; } = SdrPlatform.KiwiSdr;
        public bool MainMutedByWebSdr { get; set; }
        public bool CheckForUpdatesAtLaunch { get; set; } = true;
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

    /// APRS decoding — the Mac's APRSSettings defaults: the US calling
    /// frequency (144.800 MHz in Europe etc. is a Settings edit), ±5 kHz,
    /// and 1,000 stations/messages kept before the oldest are dropped.
    public const long DefaultAprsFrequencyHz = 144_390_000;
    public static readonly IntSetting AprsToleranceHzSetting = new(5_000, 100, 100_000);
    public static readonly IntSetting AprsMaxStationsSetting = new(1_000, 10, 100_000);
    public static readonly IntSetting AprsMaxMessagesSetting = new(1_000, 10, 100_000);

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

    /// The VFO entry flyout's up/down step (100 Hz, 1 kHz or 10 kHz), kept
    /// between openings like the Mac's "ui.frequencyStepSize".
    public static int FrequencyStepHz
    {
        get => _cache.FrequencyStepHz is 100 or 1_000 or 10_000 ? _cache.FrequencyStepHz : 1_000;
        set
        {
            _cache.FrequencyStepHz = value;
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

    /// Decode APRS from the audio (Services/AprsDecoder.cs). Off by default,
    /// like the Mac. Read from the audio thread on every chunk — plain
    /// field reads, no locking needed for a bool/long/int.
    public static bool AprsEnabled
    {
        get => _cache.AprsEnabled;
        set
        {
            _cache.AprsEnabled = value;
            Save();
        }
    }

    /// A zero/negative value (hand-edited file) falls back to the default.
    public static long AprsFrequencyHz
    {
        get => _cache.AprsFrequencyHz > 0 ? _cache.AprsFrequencyHz : DefaultAprsFrequencyHz;
        set
        {
            _cache.AprsFrequencyHz = value;
            Save();
        }
    }

    public static int AprsToleranceHz
    {
        get => AprsToleranceHzSetting.Clamp(_cache.AprsToleranceHz);
        set
        {
            _cache.AprsToleranceHz = AprsToleranceHzSetting.Clamp(value);
            Save();
        }
    }

    public static int AprsMaxStations
    {
        get => AprsMaxStationsSetting.Clamp(_cache.AprsMaxStations);
        set
        {
            _cache.AprsMaxStations = AprsMaxStationsSetting.Clamp(value);
            Save();
        }
    }

    public static int AprsMaxMessages
    {
        get => AprsMaxMessagesSetting.Clamp(_cache.AprsMaxMessages);
        set
        {
            _cache.AprsMaxMessages = AprsMaxMessagesSetting.Clamp(value);
            Save();
        }
    }

    /// Whether a VFO at this frequency should be decoded: APRS on and within
    /// the tolerance of the APRS frequency (the Mac's APRSSettings.isActive).
    public static bool IsAprsActive(long? frequencyHz) =>
        AprsEnabled && frequencyHz is { } hz and > 0 && Math.Abs(hz - AprsFrequencyHz) <= AprsToleranceHz;

    /// The operator's Maidenhead grid square (Settings → Station), the Mac's
    /// StationSettings.gridSquare. Only the WebSDR Stations window uses it
    /// so far, to sort KiwiSDRs by distance.
    public static string GridSquare
    {
        get => _cache.GridSquare;
        set
        {
            _cache.GridSquare = value;
            Save();
        }
    }

    /// The operator's callsign (Settings → Station), the Mac's
    /// StationSettings.callsign: {MYCALL} in CW macros, and left unlinked in
    /// the CW window's decoded text.
    public static string Callsign
    {
        get => _cache.Callsign;
        set
        {
            _cache.Callsign = value;
            Save();
        }
    }

    // The WebSDR window (Services/WebSdrFollowModel.cs) — the Mac's
    // WebSDRSettings, same defaults.

    /// The committed host (picked from the directory or Favorites, or typed).
    public static string WebSdrHostPort
    {
        get => _cache.WebSdrHostPort;
        set
        {
            _cache.WebSdrHostPort = value;
            Save();
        }
    }

    public static bool WebSdrFollowRig
    {
        get => _cache.WebSdrFollowRig;
        set
        {
            _cache.WebSdrFollowRig = value;
            Save();
        }
    }

    public static bool WebSdrTuneRig
    {
        get => _cache.WebSdrTuneRig;
        set
        {
            _cache.WebSdrTuneRig = value;
            Save();
        }
    }

    public static bool WebSdrMuted
    {
        get => _cache.WebSdrMuted;
        set
        {
            _cache.WebSdrMuted = value;
            Save();
        }
    }

    public static bool WebSdrMuteOnTransmit
    {
        get => _cache.WebSdrMuteOnTransmit;
        set
        {
            _cache.WebSdrMuteOnTransmit = value;
            Save();
        }
    }

    /// The station last picked from the directory or Favorites (host,
    /// name, location, ranges, platform).
    public static WebSdrFavorite? WebSdrPickedStation
    {
        get => _cache.WebSdrPickedStation;
        set
        {
            _cache.WebSdrPickedStation = value;
            Save();
        }
    }

    /// Saved stations, in the user's order.
    public static List<WebSdrFavorite> WebSdrFavorites
    {
        get => _cache.WebSdrFavorites;
        set
        {
            _cache.WebSdrFavorites = value;
            Save();
        }
    }

    /// The KiwiSDR directory's last ETag, for its conditional GET.
    public static string? WebSdrDirectoryETag
    {
        get => _cache.WebSdrDirectoryETag;
        set
        {
            _cache.WebSdrDirectoryETag = value;
            Save();
        }
    }

    /// The Stations window's last tab.
    public static SdrPlatform WebSdrStationsTab
    {
        get => _cache.WebSdrStationsTab;
        set
        {
            _cache.WebSdrStationsTab = value;
            Save();
        }
    }

    /// Main's audio was muted by the WebSDR window (not by the user) — the
    /// Mac's mainMutedByWebSDR. Persisted so a crash mid-session can't leave
    /// Main stuck muted: the WebSDR window always opens disconnected, so
    /// MainWindow lifts a leftover WebSDR mute at startup.
    public static bool MainMutedByWebSdr
    {
        get => _cache.MainMutedByWebSdr;
        set
        {
            _cache.MainMutedByWebSdr = value;
            Save();
        }
    }

    /// Check GitHub for a newer release at launch (Settings → About), on by
    /// default like the Mac's Sparkle automatic checks.
    public static bool CheckForUpdatesAtLaunch
    {
        get => _cache.CheckForUpdatesAtLaunch;
        set
        {
            _cache.CheckForUpdatesAtLaunch = value;
            Save();
        }
    }

    /// The CW window's receiver (MAIN/SUB) — the Mac's cw.channel.
    public static CwAudioChannel CwChannel
    {
        get => _cache.CwChannel;
        set
        {
            _cache.CwChannel = value;
            Save();
        }
    }

    /// The CW decoder's manual tone, auto-tune and squelch (the Mac's
    /// cw.toneFrequency/autoTune/squelchDB, same defaults: CWKit's).
    public static double CwToneFrequency => _cache.CwToneFrequency;
    public static bool CwAutoTune => _cache.CwAutoTune;
    public static double CwSquelchDb => _cache.CwSquelchDb;

    public static void SaveCw(double toneFrequency, bool autoTune, double squelchDb)
    {
        _cache.CwToneFrequency = toneFrequency;
        _cache.CwAutoTune = autoTune;
        _cache.CwSquelchDb = squelchDb;
        Save();
    }

    /// The CW window's decoder — the Mac's cw.decoder, Neural by default.
    public static CwDecoderKind CwDecoder
    {
        get => _cache.CwDecoder;
        set
        {
            _cache.CwDecoder = value;
            Save();
        }
    }

    /// The CW TEXT keyer memory the send pane writes to (1-5) — the Mac's
    /// cw.keyerSlot. Whatever the rig holds there gets overwritten.
    public static int CwKeyerSlot
    {
        get => _cache.CwKeyerSlot is >= 1 and <= 5 ? _cache.CwKeyerSlot : 1;
        set
        {
            _cache.CwKeyerSlot = value;
            Save();
        }
    }

    /// The send pane's macro buttons (the Mac's cw.macros); the defaults
    /// until edited.
    public static List<CwMacro> CwMacros
    {
        get => _cache.CwMacros ?? CwMacro.Defaults();
        set
        {
            _cache.CwMacros = value;
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
