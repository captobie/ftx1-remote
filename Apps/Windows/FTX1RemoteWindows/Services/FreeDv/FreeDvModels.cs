using FTX1RemoteWindows.Models;

namespace FTX1RemoteWindows.Services.FreeDv;

/// Tools → FreeDV's saved settings (the Mac's freedv.* keys and
/// audio.freeDVMicrophoneUID).
public sealed class FreeDvData
{
    public CwAudioChannel Channel { get; set; } = CwAudioChannel.Main;
    /// Playback volume of the decoded speech, 0…1.
    public double Volume { get; set; } = 0.8;
    public bool Muted { get; set; }
    /// Transmit level relative to the FreeDV app's, dB (−20…0).
    public double TxLevelDb { get; set; }
    /// The Windows recording device FreeDV transmits from; "" = the default.
    public string MicrophoneDeviceId { get; set; } = "";
    public string MicrophoneDeviceName { get; set; } = "";
    /// "Report to FreeDV Reporter", off by default.
    public bool ReporterEnabled { get; set; }
    /// Our status message there.
    public string ReporterMessage { get; set; } = "";
    /// Which list the window shows while reporting.
    public bool ShowReporterList { get; set; }
}

/// What the FreeDV receiver needs to know about the rig. Frequencies and
/// modes are null while disconnected or unknown; C4FM (no RigMode here) is
/// its own flag.
public readonly record struct FreeDvRigInfo(
    bool Transmitting = false,
    RigMode? MainMode = null,
    RigMode? SubMode = null,
    long? MainHz = null,
    long? SubHz = null,
    bool MainIsC4fm = false,
    bool SubIsC4fm = false);

/// The sideband FreeDV uses where the source is tuned — the Mac's
/// FreeDVSideband. freedv.org's "Getting started": the SSB convention, LSB
/// below 10 MHz and USB from 10 MHz up. The same sideband on both ends gives
/// the sender's audio back unchanged; the wrong one flips the spectrum and
/// nothing decodes.
public enum FreeDvSideband
{
    Lower,
    Upper,
    /// The source's frequency isn't known (WebSDR): either SSB mode is fine.
    Either,
}

public static class FreeDvSidebands
{
    public const long LowerBandEdgeHz = 10_000_000;

    public static FreeDvSideband For(long? frequencyHz) => frequencyHz is not > 0
        ? FreeDvSideband.Either
        : frequencyHz < LowerBandEdgeHz ? FreeDvSideband.Lower : FreeDvSideband.Upper;

    /// Whether a rig mode receives it the right way up.
    public static bool Suits(this FreeDvSideband sideband, RigMode mode) => sideband switch
    {
        FreeDvSideband.Lower => mode == RigMode.Lsb,
        FreeDvSideband.Upper => mode is RigMode.Usb or RigMode.DataUsb,
        _ => mode is RigMode.Lsb or RigMode.Usb or RigMode.DataUsb,
    };
}

/// The selected source is in a mode FreeDV won't decode in there.
public sealed record FreeDvModeHint(string Mode, FreeDvSideband Expected)
{
    /// Null when the mode is fine or unknown.
    public static FreeDvModeHint? For(RigMode? mode, bool isC4fm, long? frequencyHz)
    {
        var expected = FreeDvSidebands.For(frequencyHz);
        if (isC4fm)
        {
            return new FreeDvModeHint("C4FM", expected);
        }
        return mode is { } known && !expected.Suits(known) ? new FreeDvModeHint(known.DisplayName(), expected) : null;
    }
}

/// One station heard: a callsign from an end-of-over, with the SNR the over
/// was received at (last reading while in sync) and the source's dial then,
/// if known.
public sealed record FreeDvHeardStation(
    string Callsign,
    DateTime TimeUtc,
    float? SnrDb,
    CwAudioChannel Channel,
    long? FrequencyHz,
    bool FromFile);

/// Float speech or modem audio to 16-bit little-endian PCM.
public static class FreeDvPcm
{
    public static byte[] From(ReadOnlySpan<float> samples, float gain = 1)
    {
        var data = new byte[samples.Length * 2];
        for (var i = 0; i < samples.Length; i++)
        {
            var value = (short)(Math.Clamp(samples[i] * gain, -1f, 1f) * 32767);
            data[i * 2] = (byte)value;
            data[i * 2 + 1] = (byte)(value >> 8);
        }
        return data;
    }
}
