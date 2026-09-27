namespace FTX1RemoteWindows.Services;

/// C# port of Sources/FTX1Core/Audio/SquelchGate.swift — a client-side
/// "virtual squelch", independent of the rig's own (which the FTX-1's USB
/// audio ignores anyway).
///
/// Gates on *quieting*, not loudness: hardware captures (2026-09-08) showed
/// static and a real FM signal's speech sitting in the same RMS band, but a
/// locked carrier repeatedly drops to near-silence between phrases while
/// static never does. So a chunk at or below <see cref="Threshold"/> opens
/// the gate, and it holds open for <see cref="ReleaseDuration"/> after the
/// last such dip to bridge the loud stretches of speech. See the Swift
/// file's doc comment for the full reasoning; keep the two in step.
public sealed class SquelchGate
{
    public SquelchGate(float threshold = 0.015f)
    {
        Threshold = threshold;
    }

    /// RMS (0...1) at or below which a chunk counts as a quieting dip.
    /// Larger = more lenient.
    public float Threshold { get; set; }

    public TimeSpan ReleaseDuration { get; set; } = TimeSpan.FromSeconds(4);

    public bool IsOpen { get; private set; }

    private DateTime? _lastQuietDetected;

    public bool Update(float rms) => Update(rms, DateTime.UtcNow);

    public bool Update(float rms, DateTime now)
    {
        if (rms <= Threshold)
        {
            _lastQuietDetected = now;
            IsOpen = true;
        }
        else
        {
            IsOpen = _lastQuietDetected is { } last && now - last < ReleaseDuration;
        }
        return IsOpen;
    }

    public static float Rms(ReadOnlySpan<float> samples)
    {
        if (samples.IsEmpty)
        {
            return 0;
        }
        double sum = 0;
        foreach (var s in samples)
        {
            sum += s * s;
        }
        return (float)Math.Sqrt(sum / samples.Length);
    }
}
