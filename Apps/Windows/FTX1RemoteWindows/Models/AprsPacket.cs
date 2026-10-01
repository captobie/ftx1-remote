using System.Globalization;
using System.Text;

namespace FTX1RemoteWindows.Models;

/// A parsed APRS info field, by data type identifier — port of
/// Sources/FTX1Core/APRS/APRSPacket.swift. Covers uncompressed position
/// reports, status reports and messages (what the station and message lists
/// need); everything else (objects, weather, telemetry, Mic-E, compressed
/// positions, third-party) is <see cref="Other"/>, same scope as the Mac.
public abstract record AprsPacket
{
    public sealed record Position(double Latitude, double Longitude, string SymbolTable, string SymbolCode, string Comment) : AprsPacket;
    public sealed record Status(string Text) : AprsPacket;
    public sealed record Message(string To, string Text, string? MessageId) : AprsPacket;
    public sealed record Other : AprsPacket;

    public static AprsPacket Parse(byte[] infoField)
    {
        if (infoField.Length == 0)
        {
            return new Other();
        }
        var rest = infoField.AsSpan(1);
        return (char)infoField[0] switch
        {
            '!' or '=' => ParsePosition(rest, hasTimestamp: false) ?? new Other(),
            '/' or '@' => ParsePosition(rest, hasTimestamp: true) ?? new Other(),
            '>' => new Status(Utf8(rest)),
            ':' => ParseMessage(rest) ?? new Other(),
            _ => new Other(),
        };
    }

    /// `ddmm.mmN/dddmm.mmW<symbol><comment>`, after a 7-byte timestamp for
    /// '/' and '@'.
    private static AprsPacket? ParsePosition(ReadOnlySpan<byte> bytes, bool hasTimestamp)
    {
        if (hasTimestamp)
        {
            if (bytes.Length <= 7)
            {
                return null;
            }
            bytes = bytes[7..];
        }
        if (bytes.Length < 19)
        {
            return null;
        }
        var latitude = ParseCoordinate(Utf8(bytes[..8]), degreeDigits: 2, 'N', 'S');
        var longitude = ParseCoordinate(Utf8(bytes[9..18]), degreeDigits: 3, 'E', 'W');
        if (latitude is not { } lat || longitude is not { } lon)
        {
            return null;
        }
        return new Position(lat, lon, ((char)bytes[8]).ToString(), ((char)bytes[18]).ToString(),
            bytes.Length > 19 ? Utf8(bytes[19..]) : "");
    }

    /// Degrees (2 or 3 digits), minutes "mm.mm", then the hemisphere letter.
    private static double? ParseCoordinate(string text, int degreeDigits, char positive, char negative)
    {
        if (text.Length != degreeDigits + 6)
        {
            return null;
        }
        if (!double.TryParse(text.AsSpan(0, degreeDigits), NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var degrees)
            || !double.TryParse(text.AsSpan(degreeDigits, 5), NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var minutes))
        {
            return null;
        }
        var hemisphere = text[^1];
        if (hemisphere != positive && hemisphere != negative)
        {
            return null;
        }
        var value = degrees + minutes / 60.0;
        return hemisphere == negative ? -value : value;
    }

    /// `ADDRESSEE:text{id}` — the addressee is a fixed 9 characters,
    /// space-padded.
    private static AprsPacket? ParseMessage(ReadOnlySpan<byte> bytes)
    {
        var text = Utf8(bytes);
        if (text.Length < 10 || text[9] != ':')
        {
            return null;
        }
        var addressee = text[..9].Trim();
        var remainder = text[10..];
        string? messageId = null;
        if (remainder.IndexOf('{') is var brace and >= 0)
        {
            messageId = remainder[(brace + 1)..];
            remainder = remainder[..brace];
        }
        return new Message(addressee, remainder, messageId);
    }

    private static string Utf8(ReadOnlySpan<byte> bytes) => Encoding.UTF8.GetString(bytes);
}
