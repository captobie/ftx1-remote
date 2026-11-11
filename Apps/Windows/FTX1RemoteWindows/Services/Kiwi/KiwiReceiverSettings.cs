using System.Globalization;

namespace FTX1RemoteWindows.Services;

public enum KiwiNoiseBlanker { Off = 0, Standard = 1, Wild = 2 }

public enum KiwiNoiseFilter { Off = 0, Wdsp = 1, Lms = 2, Spectral = 3 }

/// The MyKiwiSDR window's receiver controls: AGC, noise blanker and noise
/// filter, with the commands the Kiwi's own page sends for them (set_agc in
/// openwebrx.js, noise_blank.js, noise_filter.js, v1.902). Port of the Mac's
/// KiwiReceiverSettings.swift. Pure, so the command text is unit-tested.
/// The defaults are what a new connection has always sent: AGC on with the
/// page's values, blanker and filter off.
public sealed record KiwiReceiverSettings
{
    public bool Agc { get; init; } = true;
    public int ManualGain { get; init; } = 50;
    public int Threshold { get; init; } = -100;
    public int Decay { get; init; } = 1000;

    public KiwiNoiseBlanker NoiseBlanker { get; init; } = KiwiNoiseBlanker.Off;
    public int Gate { get; init; } = 100;
    public int BlankerThreshold { get; init; } = 50;
    public double WildThreshold { get; init; } = 0.95;

    public KiwiNoiseFilter NoiseFilter { get; init; } = KiwiNoiseFilter.Off;
    public bool Denoise { get; init; }
    public bool Autonotch { get; init; }

    public const int ManualGainMin = 0, ManualGainMax = 120;
    public const int ThresholdMin = -130, ThresholdMax = 0;
    public const int DecayMin = 20, DecayMax = 5000, DecayStep = 10;
    public const int GateMin = 100, GateMax = 5000, GateStep = 100;
    public const int BlankerThresholdMin = 0, BlankerThresholdMax = 100;
    public const double WildThresholdMin = 0.05, WildThresholdMax = 3.0, WildThresholdStep = 0.05;

    /// Everything inside the Kiwi's ranges (for saved values).
    public KiwiReceiverSettings Clamped() => this with
    {
        ManualGain = Math.Clamp(ManualGain, ManualGainMin, ManualGainMax),
        Threshold = Math.Clamp(Threshold, ThresholdMin, ThresholdMax),
        Decay = Math.Clamp(Decay, DecayMin, DecayMax),
        Gate = Math.Clamp(Gate, GateMin, GateMax),
        BlankerThreshold = Math.Clamp(BlankerThreshold, BlankerThresholdMin, BlankerThresholdMax),
        WildThreshold = Math.Clamp(WildThreshold, WildThresholdMin, WildThresholdMax),
    };

    /// Picks the filter. As on the Kiwi's page, choosing WDSP or LMS with
    /// neither switch on turns Denoise on (it would do nothing otherwise).
    public KiwiReceiverSettings WithNoiseFilter(KiwiNoiseFilter filter)
    {
        var separate = filter is KiwiNoiseFilter.Wdsp or KiwiNoiseFilter.Lms;
        return this with
        {
            NoiseFilter = filter,
            Denoise = separate && !Denoise && !Autonotch ? true : Denoise,
        };
    }

    /// Hang and slope stay at the page's defaults.
    public string AgcCommand =>
        $"SET agc={(Agc ? 1 : 0)} hang=0 thresh={Threshold} slope=6 decay={Decay} manGain={ManualGain}";

    /// noise_blank_send. "algo" clears every enable, so the parameters and
    /// enables follow it. Type 1 is the same blanker on the waterfall.
    public List<string> NoiseBlankerCommands
    {
        get
        {
            var commands = new List<string> { $"SET nb algo={(int)NoiseBlanker}" };
            switch (NoiseBlanker)
            {
                case KiwiNoiseBlanker.Standard:
                    commands.Add($"SET nb type=0 param=0 pval={Gate}");
                    commands.Add($"SET nb type=0 param=1 pval={BlankerThreshold}");
                    break;
                case KiwiNoiseBlanker.Wild:
                    commands.Add($"SET nb type=0 param=0 pval={Number(WildThreshold)}");
                    commands.Add("SET nb type=0 param=1 pval=10");
                    commands.Add("SET nb type=0 param=2 pval=7");
                    break;
            }
            var on = NoiseBlanker != KiwiNoiseBlanker.Off ? 1 : 0;
            commands.Add($"SET nb type=0 en={on}");
            commands.Add($"SET nb type=1 en={on}");
            return commands;
        }
    }

    /// nr_algo_cb + noise_filter_send for both filters, with the page's
    /// default parameters.
    public List<string> NoiseFilterCommands
    {
        get
        {
            var commands = new List<string> { $"SET nr algo={(int)NoiseFilter}" };
            if (NoiseFilter == KiwiNoiseFilter.Off)
            {
                return commands;
            }
            foreach (var (type, enabled) in new[] { (0, Denoise), (1, Autonotch) })
            {
                double[] parameters = NoiseFilter switch
                {
                    // gain 10 and leakage 7 on the page's non-linear sliders.
                    KiwiNoiseFilter.Wdsp => [64, 16, 8.192e-2 / Math.Pow(2, 10), 8192 / Math.Pow(2, 16)],
                    KiwiNoiseFilter.Lms => type == 0 ? [1, 0.05, 0.98, 0] : [48, 0.125, 0.99915, 0],
                    // Gain 0 dB, alpha 0.95, active SNR 30 dB.
                    _ => [1, 0.95, 1000, 0],
                };
                for (var index = 0; index < parameters.Length; index++)
                {
                    commands.Add($"SET nr type={type} param={index} pval={Number(parameters[index])}");
                }
                commands.Add($"SET nr type={type} en={(enabled ? 1 : 0)}");
            }
            return commands;
        }
    }

    /// What differs from "old", one group at a time.
    public List<string> Commands(KiwiReceiverSettings old)
    {
        var commands = new List<string>();
        if (AgcCommand != old.AgcCommand)
        {
            commands.Add(AgcCommand);
        }
        if (!NoiseBlankerCommands.SequenceEqual(old.NoiseBlankerCommands))
        {
            commands.AddRange(NoiseBlankerCommands);
        }
        if (!NoiseFilterCommands.SequenceEqual(old.NoiseFilterCommands))
        {
            commands.AddRange(NoiseFilterCommands);
        }
        return commands;
    }

    /// printf("%g") as the Mac sends it: 6 significant digits, lower case.
    private static string Number(double value) =>
        value.ToString("G6", CultureInfo.InvariantCulture).ToLowerInvariant();
}
