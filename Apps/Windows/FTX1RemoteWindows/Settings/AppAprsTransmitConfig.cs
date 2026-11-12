using FTX1RemoteWindows.Services;

namespace FTX1RemoteWindows.Settings;

/// <see cref="AprsTransmitSettings"/> backed by the app's settings file.
public sealed class AppAprsTransmitConfig : IAprsTransmitConfig
{
    private static AppSettings.AprsTransmitData Data => AppSettings.AprsTx;

    public bool Enabled => Data.Enabled;
    public int Ssid => Data.Ssid;
    public double? Latitude => Data.Latitude;
    public double? Longitude => Data.Longitude;
    public int Ambiguity => Data.Ambiguity;
    public string Symbol => Data.Symbol;
    public string Comment => Data.Comment;
    public string Path => Data.Path;
    public int BeaconMinutes => Data.BeaconMinutes;
    public bool AutoAck => Data.AutoAck;
    public double LevelDb => Data.LevelDb;
    public int TxDelayMs => Data.TxDelayMs;
    public string StationCallsign => AppSettings.Callsign;

    public int NextMessageNumber()
    {
        var next = Data.MessageCounter % 99_999 + 1;
        Data.MessageCounter = next;
        AppSettings.SaveAprsTx();
        return next;
    }
}
