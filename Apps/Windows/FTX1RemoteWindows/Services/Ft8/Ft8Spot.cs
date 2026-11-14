namespace FTX1RemoteWindows.Services.Ft8;

/// One decoded FT8 or FT4 message, mapped from <see cref="Ft8RawMessage"/>
/// into what the window displays and PSK Reporter is sent — the Mac's FT8Spot.
public sealed class Ft8Spot
{
    public DateTimeOffset UtcTimestamp { get; }
    /// "FT8"/"FT4": what PSK Reporter is sent.
    public string Mode { get; }
    public string MessageText { get; }
    public double AudioFrequencyOffsetHz { get; }
    /// The source's dial frequency captured at slot start, not decode time.
    public long DialFrequencyHz { get; }
    /// The source the slot was decoded from.
    public CwAudioChannel Channel { get; }
    /// ft8_lib's sync score × 0.5 (what its own demo prints): an approximation
    /// of signal quality, not a calibrated noise-floor SNR.
    public int SnrDb { get; }
    public double DtSeconds { get; }
    public int LdpcErrors { get; }
    /// The callsign the message is addressed to, when its first field is a
    /// callsign rather than a token like CQ/DE/QRZ.
    public string? ToCallsign { get; }
    /// The transmitting station: the last callsign field in the message.
    public string? SpottedCallsign { get; }
    public string? SpottedGrid { get; }
    public string? ReportText { get; }

    public double AbsoluteFrequencyHz => DialFrequencyHz + AudioFrequencyOffsetHz;

    public Ft8Spot(Ft8CoordinatorSpot spot, string mode)
    {
        var message = spot.Message;
        UtcTimestamp = spot.UtcTimestamp;
        Mode = mode;
        MessageText = message.Text;
        AudioFrequencyOffsetHz = message.FrequencyOffsetHz;
        DialFrequencyHz = spot.DialFrequencyHz;
        Channel = spot.Channel;
        SnrDb = (int)Math.Round(message.Score * 0.5, MidpointRounding.AwayFromZero);
        DtSeconds = message.DtSeconds;
        LdpcErrors = message.LdpcErrors;
        ToCallsign = message.ToCallsign();
        SpottedCallsign = message.SpottedCallsign();
        SpottedGrid = message.SpottedGrid();
        ReportText = message.ReportText();
    }
}

public static class Ft8RawMessageExtensions
{
    public static string? ToCallsign(this Ft8RawMessage message) =>
        message.Fields.Count > 0 && message.Fields[0].Kind == Ft8FieldKind.Call ? message.Fields[0].Text : null;

    public static string? SpottedCallsign(this Ft8RawMessage message) =>
        message.Fields.LastOrDefault(f => f.Kind == Ft8FieldKind.Call)?.Text;

    public static string? SpottedGrid(this Ft8RawMessage message) =>
        message.Fields.FirstOrDefault(f => f.Kind == Ft8FieldKind.Grid)?.Text;

    public static string? ReportText(this Ft8RawMessage message) =>
        message.Fields.FirstOrDefault(f => f.Kind == Ft8FieldKind.Rst)?.Text;
}
