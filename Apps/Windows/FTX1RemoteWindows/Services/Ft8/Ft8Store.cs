using System.Diagnostics;
using FTX1RemoteWindows.Settings;

namespace FTX1RemoteWindows.Services.Ft8;

/// The current session's decoded FT8 or FT4 spots — what the window shows; one
/// store per mode (the Mac's FT8Store). Session-only, no disk persistence.
/// UI thread only: the coordinator's results are marshaled there.
public sealed class Ft8Store
{
    /// Generous enough for a long session without unbounded growth.
    public const int MaxSpots = 2_000;

    /// The sources the window offers (MyKiwiSDR only while enabled in Settings).
    public static readonly CwAudioChannel[] OfferedChannels = [CwAudioChannel.Main, CwAudioChannel.Sub, CwAudioChannel.WebSdr, CwAudioChannel.MyKiwiSdr];

    private static readonly TimeSpan SubAudioTimeout = TimeSpan.FromSeconds(2);

    private readonly List<Ft8Spot> _spots = [];
    private CwAudioChannel _channel;
    private long _lastSubAudioTicks;

    public Ft8Mode Mode { get; }

    /// Spots, newest last.
    public IReadOnlyList<Ft8Spot> Spots => _spots;
    public Ft8CycleStatus CycleStatus { get; private set; } = Ft8CycleStatus.Idle;
    public DateTimeOffset? LastCycleCompletedAt { get; private set; }

    /// Whether the window is open and decoding; the MyKiwiSDR source's
    /// IsWanted reads it per frame.
    public volatile bool IsRunning;

    /// SUB audio arrived in the last 2 s (a mono input never has any).
    public bool IsSubAudioAvailable { get; private set; }

    /// Spots, status, source or SUB availability changed.
    public event Action? Changed;
    /// The source was changed by the user (MainWindow passes it on).
    public event Action<CwAudioChannel>? ChannelChanged;
    /// One decode cycle's spots were added (the window prepends their rows).
    public event Action<IReadOnlyList<Ft8Spot>>? SpotsRecorded;
    /// The spots were cleared (the window rebuilds its rows).
    public event Action? Cleared;

    public Ft8Store(Ft8Mode mode)
    {
        Mode = mode;
        var saved = mode == Ft8Mode.Ft8 ? AppSettings.Ft8.Ft8Channel : AppSettings.Ft8.Ft4Channel;
        _channel = Array.IndexOf(OfferedChannels, saved) >= 0 ? saved : CwAudioChannel.Main;
    }

    /// The decoded source, saved per mode.
    public CwAudioChannel Channel
    {
        get => _channel;
        set
        {
            if (value == _channel)
            {
                return;
            }
            _channel = value;
            if (Mode == Ft8Mode.Ft8)
            {
                AppSettings.Ft8.Ft8Channel = value;
            }
            else
            {
                AppSettings.Ft8.Ft4Channel = value;
            }
            AppSettings.SaveFt8();
            ChannelChanged?.Invoke(value);
            Changed?.Invoke();
        }
    }

    /// SUB audio arrived (called from the audio thread for each non-silent
    /// SUB chunk while a window decodes). Read by <see cref="RefreshSubAudio"/>.
    public void NoteSubAudio() => Interlocked.Exchange(ref _lastSubAudioTicks, Stopwatch.GetTimestamp());

    /// Re-evaluates <see cref="IsSubAudioAvailable"/> (UI thread, from the
    /// window's timer). Raises Changed only when it flips.
    public void RefreshSubAudio()
    {
        var last = Interlocked.Read(ref _lastSubAudioTicks);
        var available = last != 0 && Stopwatch.GetElapsedTime(last) < SubAudioTimeout;
        if (available != IsSubAudioAvailable)
        {
            IsSubAudioAvailable = available;
            Changed?.Invoke();
        }
    }

    public void Record(IReadOnlyList<Ft8Spot> newSpots)
    {
        if (newSpots.Count == 0)
        {
            return;
        }
        _spots.AddRange(newSpots);
        if (_spots.Count > MaxSpots)
        {
            _spots.RemoveRange(0, _spots.Count - MaxSpots);
        }
        LastCycleCompletedAt = DateTimeOffset.Now;
        SpotsRecorded?.Invoke(newSpots);
        Changed?.Invoke();
    }

    public void UpdateCycleStatus(Ft8CycleStatus status)
    {
        if (status == CycleStatus)
        {
            return;
        }
        CycleStatus = status;
        Changed?.Invoke();
    }

    /// The window closed: clears the display.
    public void Clear()
    {
        _spots.Clear();
        CycleStatus = Ft8CycleStatus.Idle;
        LastCycleCompletedAt = null;
        Cleared?.Invoke();
        Changed?.Invoke();
    }
}
