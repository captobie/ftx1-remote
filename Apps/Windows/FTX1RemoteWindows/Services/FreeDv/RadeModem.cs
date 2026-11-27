using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace FTX1RemoteWindows.Services.FreeDv;

/// P/Invoke to ftx1rade.dll — FreeDV RADE V1 (rade_c + Opus's FARGAN +
/// freedv-backend's callsign code) behind Scripts/rade/ftx1_rade.h, the same
/// wrapper the Mac builds into FTX1Rade.xcframework. Built for Windows by
/// Apps/Windows/Tools/radenative/build-rade.ps1 and shipped in <output>\rade\.
internal static class RadeNative
{
    private const string Library = "ftx1rade";

    static RadeNative() => NativeDlls.EnsureResolver();

    /// Mirrors ftx1_rade_rx_status.
    [StructLayout(LayoutKind.Sequential)]
    public struct RxStatus
    {
        public int Sync;
        public float FreqOffsetHz;
        public float SnrDb;
        public int EndOfOver;
        public int CallsignValid;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = RadeDecoder.CallsignMax + 1)]
        public byte[] Callsign;
    }

    public sealed class RxHandle() : SafeHandleZeroOrMinusOneIsInvalid(ownsHandle: true)
    {
        protected override bool ReleaseHandle()
        {
            ftx1_rade_rx_close(handle);
            return true;
        }
    }

    public sealed class TxHandle() : SafeHandleZeroOrMinusOneIsInvalid(ownsHandle: true)
    {
        protected override bool ReleaseHandle()
        {
            ftx1_rade_tx_close(handle);
            return true;
        }
    }

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern RxHandle ftx1_rade_rx_open();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void ftx1_rade_rx_close(IntPtr rx);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int ftx1_rade_rx_nin(RxHandle rx);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int ftx1_rade_rx_nin_max(RxHandle rx);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int ftx1_rade_rx_speech_max(RxHandle rx);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern unsafe int ftx1_rade_rx_process(RxHandle rx, float* modem, float* speech, ref RxStatus status);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern TxHandle ftx1_rade_tx_open();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void ftx1_rade_tx_close(IntPtr tx);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int ftx1_rade_tx_modem_max(TxHandle tx);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int ftx1_rade_tx_finish_max(TxHandle tx);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern unsafe int ftx1_rade_tx_process(TxHandle tx, float* speech, float* modem);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int ftx1_rade_tx_finish(TxHandle tx, byte[]? callsign, [Out] float[] modem);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int ftx1_rade_rade_version();
}

/// What the RADE receiver reports after a call to <see cref="RadeDecoder.Process"/>.
/// The offset and SNR (in 3 kHz) only mean something while in sync.
public readonly record struct RadeStatus(bool Sync, float FrequencyOffsetHz, float SnrDb);

/// One end-of-over (the end of a transmission) seen by the receiver: where,
/// in modem samples since the decoder was created, and the sender's callsign
/// if it carried one whose CRC checked out.
public readonly record struct RadeEndOfOver(long SampleTime, string? Callsign);

/// The result of one <see cref="RadeDecoder.Process"/> call: speech at
/// 16 kHz (±1, empty when not in sync), the status after the last block, and
/// the end-of-overs seen, oldest first.
public sealed record RadeOutput(float[] Speech, RadeStatus Status, IReadOnlyList<RadeEndOfOver> EndsOfOver);

/// FreeDV RADE V1 receiver: real 8 kHz audio in, 16 kHz speech out — the
/// Mac's RADEDecoder. Not thread-safe: use one instance from one thread at a
/// time.
public sealed class RadeDecoder : IDisposable
{
    public const int ModemSampleRate = 8000;
    public const int SpeechSampleRate = 16000;
    /// Longest callsign the end-of-over carries.
    public const int CallsignMax = 8;

    private readonly RadeNative.RxHandle _rx;
    private readonly List<float> _pending = [];
    private readonly float[] _input;
    private readonly float[] _speech;
    private long _samplesConsumed;
    private RadeNative.RxStatus _raw = new() { Callsign = new byte[CallsignMax + 1] };

    public RadeStatus Status { get; private set; }

    /// Throws if the library is missing or can't allocate its state.
    public RadeDecoder()
    {
        _rx = RadeNative.ftx1_rade_rx_open();
        if (_rx.IsInvalid)
        {
            throw new InvalidOperationException("ftx1_rade_rx_open failed");
        }
        _input = new float[RadeNative.ftx1_rade_rx_nin_max(_rx)];
        _speech = new float[RadeNative.ftx1_rade_rx_speech_max(_rx)];
    }

    /// rade_c's API version, for logging.
    public static int LibraryVersion => RadeNative.ftx1_rade_rade_version();

    /// Feeds any number of real 8 kHz modem samples (full scale ±1). Samples
    /// left over until the demodulator's next block are kept for the next call.
    public unsafe RadeOutput Process(ReadOnlySpan<float> samples)
    {
        ObjectDisposedException.ThrowIf(_rx.IsClosed, this);
        foreach (var sample in samples)
        {
            _pending.Add(sample);
        }
        var speech = new List<float>();
        List<RadeEndOfOver>? endsOfOver = null;
        var consumed = 0;
        while (true)
        {
            var nin = RadeNative.ftx1_rade_rx_nin(_rx);
            if (_pending.Count - consumed < nin)
            {
                break;
            }
            CollectionsMarshal.AsSpan(_pending).Slice(consumed, nin).CopyTo(_input);
            int written;
            fixed (float* input = _input)
            fixed (float* output = _speech)
            {
                written = RadeNative.ftx1_rade_rx_process(_rx, input, output, ref _raw);
            }
            consumed += nin;
            _samplesConsumed += nin;
            if (written > 0)
            {
                speech.AddRange(_speech.AsSpan(0, written));
            }
            Status = new RadeStatus(_raw.Sync != 0, _raw.FreqOffsetHz, _raw.SnrDb);
            if (_raw.EndOfOver != 0)
            {
                (endsOfOver ??= []).Add(new RadeEndOfOver(
                    _samplesConsumed,
                    _raw.CallsignValid != 0 ? Text(_raw.Callsign) : null));
            }
        }
        _pending.RemoveRange(0, consumed);
        return new RadeOutput([.. speech], Status, endsOfOver ?? (IReadOnlyList<RadeEndOfOver>)[]);
    }

    private static string Text(byte[] chars)
    {
        var end = Array.IndexOf(chars, (byte)0);
        return Encoding.UTF8.GetString(chars, 0, end < 0 ? chars.Length : end);
    }

    public void Dispose() => _rx.Dispose();
}

/// FreeDV RADE V1 transmitter — the Mac's RADEEncoder: 16 kHz speech in, real
/// 8 kHz modem audio out at the modem's nominal amplitude 1.0 (the FreeDV app
/// sends that at <see cref="NominalOutputScale"/>). One instance per over:
/// feed speech with <see cref="Process"/>, end with <see cref="Finish"/> (the
/// last frame and the end-of-over carrying the callsign). Not thread-safe.
public sealed class RadeEncoder : IDisposable
{
    public const int SpeechSampleRate = RadeDecoder.SpeechSampleRate;
    public const int ModemSampleRate = RadeDecoder.ModemSampleRate;
    /// 10 ms of speech per native call (FTX1_RADE_TX_SPEECH_FRAME).
    private const int FrameLength = 160;
    /// The FreeDV app's output scale for nominal amplitude 1.0: 16383 of
    /// 32767, leaving 6 dB for the OFDM peaks.
    public const float NominalOutputScale = 16383f / 32767f;
    /// freedv-backend's RADETransmitStep sends 200 ms of silence after the
    /// end-of-over before the transmitter drops.
    public const double TailSilenceSeconds = 0.2;

    private readonly RadeNative.TxHandle _tx;
    private readonly List<float> _pending = [];
    private readonly float[] _frame = new float[FrameLength];
    private readonly float[] _modem;
    private bool _finished;

    /// Throws if the library is missing or can't allocate its state.
    public RadeEncoder()
    {
        _tx = RadeNative.ftx1_rade_tx_open();
        if (_tx.IsInvalid)
        {
            throw new InvalidOperationException("ftx1_rade_tx_open failed");
        }
        _modem = new float[RadeNative.ftx1_rade_tx_modem_max(_tx)];
    }

    /// Feeds any amount of 16 kHz speech (±1). Returns the modem audio that
    /// became ready: a 120 ms frame (960 samples) per 120 ms of speech.
    public unsafe float[] Process(ReadOnlySpan<float> speech)
    {
        ObjectDisposedException.ThrowIf(_tx.IsClosed, this);
        if (_finished)
        {
            return [];
        }
        foreach (var sample in speech)
        {
            _pending.Add(sample);
        }
        var modem = new List<float>();
        var consumed = 0;
        while (_pending.Count - consumed >= FrameLength)
        {
            CollectionsMarshal.AsSpan(_pending).Slice(consumed, FrameLength).CopyTo(_frame);
            int written;
            fixed (float* input = _frame)
            fixed (float* output = _modem)
            {
                written = RadeNative.ftx1_rade_tx_process(_tx, input, output);
            }
            consumed += FrameLength;
            if (written > 0)
            {
                modem.AddRange(_modem.AsSpan(0, written));
            }
        }
        _pending.RemoveRange(0, consumed);
        return [.. modem];
    }

    /// Ends the over: the speech still buffered (zero-padded to a frame), then
    /// the end-of-over with <paramref name="callsign"/> (first 8 characters,
    /// uppercased; null or empty sends none). Later calls return nothing.
    public float[] Finish(string? callsign)
    {
        ObjectDisposedException.ThrowIf(_tx.IsClosed, this);
        if (_finished)
        {
            return [];
        }
        // A partial 10 ms frame still waiting is padded with silence.
        float[] head = [];
        if (_pending.Count > 0)
        {
            head = Process(new float[FrameLength - _pending.Count]);
        }
        _finished = true;
        var call = (callsign ?? "").ToUpperInvariant();
        if (call.Length > RadeDecoder.CallsignMax)
        {
            call = call[..RadeDecoder.CallsignMax];
        }
        var buffer = new float[RadeNative.ftx1_rade_tx_finish_max(_tx)];
        // NUL-terminated bytes for the C string.
        var bytes = call.Length == 0 ? null : Encoding.ASCII.GetBytes(call + "\0");
        var written = RadeNative.ftx1_rade_tx_finish(_tx, bytes, buffer);
        return [.. head, .. buffer.AsSpan(0, written)];
    }

    public void Dispose() => _tx.Dispose();
}
