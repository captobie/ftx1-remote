namespace FTX1RemoteWindows.Services;

/// Where the APRS transmit settings come from. The app uses
/// AppAprsTransmitConfig (Settings/AppSettings.cs); the tests set a plain
/// <see cref="AprsTransmitConfigData"/>, so they never touch the user's
/// settings file.
public interface IAprsTransmitConfig
{
    bool Enabled { get; }
    int Ssid { get; }
    double? Latitude { get; }
    double? Longitude { get; }
    int Ambiguity { get; }
    string Symbol { get; }
    string Comment { get; }
    string Path { get; }
    int BeaconMinutes { get; }
    bool AutoAck { get; }
    double LevelDb { get; }
    int TxDelayMs { get; }
    /// Settings → Station's callsign, as typed.
    string StationCallsign { get; }
    /// The next message id, 1…99999, persisted so ids don't repeat soon.
    int NextMessageNumber();
}

/// Plain values (tests, and the default until the app sets its own).
public sealed class AprsTransmitConfigData : IAprsTransmitConfig
{
    public bool Enabled { get; set; }
    public int Ssid { get; set; }
    public double? Latitude { get; set; }
    public double? Longitude { get; set; }
    public int Ambiguity { get; set; }
    public string Symbol { get; set; } = AprsTransmitSettings.DefaultSymbol;
    public string Comment { get; set; } = "";
    public string Path { get; set; } = AprsTransmitSettings.DefaultPath;
    public int BeaconMinutes { get; set; }
    public bool AutoAck { get; set; } = true;
    public double LevelDb { get; set; } = AprsTransmitSettings.DefaultLevelDb;
    public int TxDelayMs { get; set; } = AprsTransmitSettings.DefaultTxDelayMs;
    public string StationCallsign { get; set; } = "";
    public int MessageCounter { get; set; }

    public int NextMessageNumber() => MessageCounter = MessageCounter % 99_999 + 1;
}

/// Settings → APRS → Transmit (the Mac's APRSTransmitSettings), read through
/// <see cref="Config"/>.
public static class AprsTransmitSettings
{
    /// The AX.25 destination ("tocall"): APZ = experimental software.
    public static readonly Ax25Encoder.Address Destination = new("APZFTX", 0);
    public const string DefaultSymbol = "/-";
    public const string DefaultPath = "WIDE2-1";
    public const int DefaultTxDelayMs = 400;
    public const double DefaultLevelDb = -6;
    /// Beacon intervals offered, in minutes (0 = off).
    public static readonly int[] BeaconChoices = [0, 10, 15, 20, 30, 60];
    public const int MinTxDelayMs = 100;
    public const int MaxTxDelayMs = 1000;
    public const double MinLevelDb = -30;
    public const double MaxLevelDb = 0;

    public static IAprsTransmitConfig Config { get; set; } = new AprsTransmitConfigData();

    public static bool Enabled => Config.Enabled;
    public static int Ssid => Math.Clamp(Config.Ssid, 0, 15);
    public static double? Latitude => Config.Latitude;
    public static double? Longitude => Config.Longitude;
    public static int Ambiguity => Math.Clamp(Config.Ambiguity, 0, 4);
    public static string Symbol => Config.Symbol ?? DefaultSymbol;
    public static string Comment => Config.Comment ?? "";
    public static string Path => Config.Path ?? DefaultPath;
    public static int BeaconMinutes => Math.Max(0, Config.BeaconMinutes);
    public static bool AutoAck => Config.AutoAck;
    public static double LevelDb => Math.Clamp(Config.LevelDb, MinLevelDb, MaxLevelDb);
    public static int TxDelayMs => Math.Clamp(Config.TxDelayMs, MinTxDelayMs, MaxTxDelayMs);

    /// The station's own call with SSID ("N0CALL-5"), null while Settings →
    /// Station has no valid callsign.
    public static string? SourceCall => SourceCallFor(Config.StationCallsign ?? "", Ssid);

    public static string? SourceCallFor(string callsign, int ssid)
    {
        var call = callsign.Trim(' ', '\t').ToUpperInvariant();
        if (call.Contains('-') || Ax25Encoder.ParseAddress(call) is not { Ssid: 0 } parsed)
        {
            return null;
        }
        return ssid == 0 ? parsed.Callsign : $"{parsed.Callsign}-{ssid}";
    }
}
