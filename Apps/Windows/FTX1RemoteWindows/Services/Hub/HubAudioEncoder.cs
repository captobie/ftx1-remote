using NAudio.Dsp;

namespace FTX1RemoteWindows.Services.Hub;

/// One receive channel's audio for the iPad (phase 3 of "Desktop hub for
/// the iPad"): float chunks at the source's rate → 8000 Hz mono Int16LE,
/// the Mac's AudioStreamEncoder / AudioStreamFormat wire format. One per
/// channel and long-lived, so the resampler's filter state carries across
/// chunks; rebuilt only when the input rate changes.
///
/// Resampled with NAudio's WDL resampler in windowed-sinc mode. Its default
/// IIR mode (what WdlResamplingSampleProvider uses) measured −2 dB already
/// at 2 kHz; 8 kHz output leaves a 4 kHz Nyquist, and the iPad runs a CW
/// decoder and a 0–4 kHz spectrum on this audio, so the filter here is long
/// enough (<see cref="SincSize"/> taps) to stay flat to 3.5 kHz (±0.05 dB)
/// and be ≥45 dB down at 4.4 kHz (HubAudioTests).
///
/// Not thread-safe: one caller at a time (the audio source's callback).
public sealed class HubAudioEncoder
{
    public const int OutputSampleRate = 8000;

    /// Sinc length in input samples. 512 at 44.1/48 kHz is a transition
    /// band of a few hundred Hz; ~4 M multiply-adds per second per channel.
    private const int SincSize = 512;
    private const int SincInterpSize = 32;

    private WdlResampler? _resampler;
    private int _inputRate;
    private float[] _out = [];

    /// Int16LE PCM at 8 kHz for one chunk, with <paramref name="tag"/> as
    /// the first byte when given (AudioStreamFormat's 0x00/0x01) — the
    /// whole WebSocket frame. Empty (no PCM) when the resampler is still
    /// filling its filter, i.e. the first chunk after a (re)build may be
    /// short.
    public byte[] Encode(ReadOnlySpan<float> samples, int inputRate, byte? tag = null)
    {
        if (_resampler is null || inputRate != _inputRate)
        {
            _resampler = new WdlResampler();
            _resampler.SetMode(true, 0, true, SincSize, SincInterpSize);
            _resampler.SetFeedMode(true);
            _resampler.SetRates(inputRate, OutputSampleRate);
            _inputRate = inputRate;
        }

        var resampler = _resampler;
        var header = tag is null ? 0 : 1;
        var outCapacity = (int)((long)samples.Length * OutputSampleRate / inputRate) + 16;
        if (_out.Length < outCapacity)
        {
            _out = new float[outCapacity];
        }

        var produced = 0;
        var remaining = samples;
        while (!remaining.IsEmpty)
        {
            var accepted = resampler.ResamplePrepare(remaining.Length, 1, out var inBuffer, out var inOffset);
            if (accepted <= 0)
            {
                break;
            }
            accepted = Math.Min(accepted, remaining.Length);
            remaining[..accepted].CopyTo(inBuffer.AsSpan(inOffset, accepted));
            remaining = remaining[accepted..];
            if (produced >= _out.Length)
            {
                Array.Resize(ref _out, _out.Length * 2);
            }
            produced += resampler.ResampleOut(_out, produced, accepted, _out.Length - produced, 1);
        }

        var frame = new byte[header + produced * 2];
        if (tag is { } t)
        {
            frame[0] = t;
        }
        for (var i = 0; i < produced; i++)
        {
            var value = (int)MathF.Round(Math.Clamp(_out[i], -1f, 1f) * 32767f);
            frame[header + i * 2] = (byte)value;
            frame[header + i * 2 + 1] = (byte)(value >> 8);
        }
        return frame;
    }
}

/// AudioStreamFormat's tag bytes for receive audio.
public static class HubAudioTags
{
    public const byte Main = 0x00;
    public const byte Sub = 0x01;
}
