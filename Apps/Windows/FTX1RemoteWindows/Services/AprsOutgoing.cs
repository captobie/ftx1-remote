using System.Globalization;
using System.Text;

namespace FTX1RemoteWindows.Services;

/// Info fields this app sends (APRS 1.0.1 / 1.2): an uncompressed position
/// with messaging, a message, an ack — plus the parsing of acks and
/// reply-acks in what arrives. Port of Sources/FTX1Core/APRS/
/// APRSOutgoing.swift, which stays the source of truth.
public static class AprsOutgoing
{
    /// Longest message text (APRS 1.0.1, chapter 14).
    public const int MaxMessageLength = 67;
    /// Longest position comment with no data extension.
    public const int MaxCommentLength = 43;

    /// "=ddmm.hhN/dddmm.hhW-comment" — the '=' says this station can take
    /// messages. <paramref name="ambiguity"/> 0–4 blanks that many trailing
    /// digits of each coordinate (4 = to the degree).
    public static string Position(double latitude, double longitude, char symbolTable, char symbolCode,
        string comment, int ambiguity = 0)
    {
        var lat = Coordinate(Math.Abs(latitude), 2, latitude < 0 ? 'S' : 'N', ambiguity);
        var lon = Coordinate(Math.Abs(longitude), 3, longitude < 0 ? 'W' : 'E', ambiguity);
        var text = Sanitized(comment);
        if (text.Length > MaxCommentLength)
        {
            text = text[..MaxCommentLength];
        }
        return "=" + lat + symbolTable + lon + symbolCode + text;
    }

    /// "ddmm.hh" (or "dddmm.hh") + hemisphere, hundredths of a minute,
    /// rounded; minutes that round to 60 carry into the degrees.
    internal static string Coordinate(double value, int degreeDigits, char hemisphere, int ambiguity)
    {
        var hundredths = (int)Math.Round(value * 60 * 100, MidpointRounding.AwayFromZero);
        var max = (degreeDigits == 2 ? 90 : 180) * 60 * 100;
        hundredths = Math.Min(hundredths, max);
        var degrees = hundredths / 6000;
        var minutes = hundredths % 6000;
        var digits = string.Create(CultureInfo.InvariantCulture,
            $"{degrees.ToString("D" + degreeDigits, CultureInfo.InvariantCulture)}{minutes / 100:00}.{minutes % 100:00}").ToCharArray();
        // The last four digits, right to left: hh, then mm (the '.' stays).
        int[] positions = [digits.Length - 1, digits.Length - 2, digits.Length - 4, digits.Length - 5];
        foreach (var index in positions.Take(Math.Max(0, Math.Min(4, ambiguity))))
        {
            digits[index] = ' ';
        }
        return new string(digits) + hemisphere;
    }

    /// ":ADDRESSEE:text{id" — the addressee padded to 9 characters.
    public static string Message(string addressee, string text, string? id)
    {
        var body = Sanitized(text, forMessage: true);
        if (body.Length > MaxMessageLength)
        {
            body = body[..MaxMessageLength];
        }
        return ":" + PaddedAddressee(addressee) + ":" + body + (id is null ? "" : "{" + id);
    }

    /// ":ADDRESSEE:ackid".
    public static string Ack(string addressee, string id) => ":" + PaddedAddressee(addressee) + ":ack" + id;

    private static string PaddedAddressee(string addressee)
    {
        var trimmed = addressee.ToUpperInvariant();
        if (trimmed.Length > 9)
        {
            trimmed = trimmed[..9];
        }
        return trimmed.PadRight(9);
    }

    /// Printable ASCII only; in messages also none of the three characters
    /// the spec reserves (pipe, tilde, open brace).
    public static string Sanitized(string text, bool forMessage = false)
    {
        var builder = new StringBuilder(text.Length);
        foreach (var c in text)
        {
            if (c < 0x20 || c >= 0x7F)
            {
                continue;
            }
            if (forMessage && (c == '|' || c == '~' || c == '{'))
            {
                continue;
            }
            builder.Append(c);
        }
        return builder.ToString();
    }

    /// What an incoming message means for this station's own messages.
    public enum ReplyKind
    {
        Ack,
        Reject,
    }

    public readonly record struct Reply(ReplyKind Kind, string Id);

    /// "ack12" / "rej12" texts, and the reply-ack in a message id
    /// ("{MM}AA": their id MM, acking our AA).
    public static Reply? ReplyTo(string text, string? messageId)
    {
        var trimmed = text.Trim(' ', '\t');
        if (string.IsNullOrEmpty(messageId))
        {
            if (trimmed.StartsWith("ack", StringComparison.OrdinalIgnoreCase) && trimmed.Length is > 3 and <= 8)
            {
                return new Reply(ReplyKind.Ack, AckId(trimmed[3..]));
            }
            if (trimmed.StartsWith("rej", StringComparison.OrdinalIgnoreCase) && trimmed.Length is > 3 and <= 8)
            {
                return new Reply(ReplyKind.Reject, AckId(trimmed[3..]));
            }
        }
        if (messageId is not null && messageId.IndexOf('}') is var brace and >= 0)
        {
            var acked = messageId[(brace + 1)..].Trim(' ', '\t');
            if (acked.Length > 0)
            {
                return new Reply(ReplyKind.Ack, acked);
            }
        }
        return null;
    }

    /// An ack's id, without a reply-ack's "}…" tail ("ack01}" → "01").
    private static string AckId(string text) => text.Split('}')[0];

    /// The id to ack for a received message: its own, without the
    /// reply-ack part.
    public static string? IdToAck(string? messageId)
    {
        if (messageId is null)
        {
            return null;
        }
        var own = messageId.Split('}')[0].Trim(' ', '\t');
        if (own.Length == 0)
        {
            return null;
        }
        return own.Length > 5 ? own[..5] : own;
    }
}
