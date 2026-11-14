using System.Reflection;
using System.Runtime.InteropServices;

namespace FTX1RemoteWindows.Services.Ft8;

/// P/Invoke to ft8lib.dll — the vendored ft8_lib (Sources/CFT8Lib) built with
/// MSVC by Apps/Windows/Tools/ft8native/build-ft8lib.ps1 and shipped in
/// <output>\ft8\. The DLL's flat API (ft8win.c) carries the decode loop, so no
/// ft8_lib struct crosses the boundary.
internal static class Ft8Native
{
    private const string Library = "ft8lib";

    static Ft8Native()
    {
        NativeLibrary.SetDllImportResolver(typeof(Ft8Native).Assembly, Resolve);
    }

    /// Looks beside the app (ft8\ft8lib.dll in the output folder, or next to
    /// the test assembly) before the default search.
    private static IntPtr Resolve(string name, Assembly assembly, DllImportSearchPath? path)
    {
        if (name != Library)
        {
            return IntPtr.Zero;
        }
        foreach (var candidate in new[]
        {
            Path.Combine(AppContext.BaseDirectory, "ft8", "ft8lib.dll"),
            Path.Combine(AppContext.BaseDirectory, "ft8lib.dll"),
        })
        {
            if (File.Exists(candidate) && NativeLibrary.TryLoad(candidate, out var handle))
            {
                return handle;
            }
        }
        return IntPtr.Zero;
    }

    /// Mirrors ft8w_result_t in ft8win.c.
    [StructLayout(LayoutKind.Sequential)]
    public struct Result
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 48)]
        public byte[] Text;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)]
        public int[] Types;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)]
        public int[] Offsets;
        public double FreqHz;
        public double DtSec;
        public int Score;
        public int LdpcErrors;
    }

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int ft8w_result_size();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr ft8w_create(int sampleRate, int isFt4, float fMin, float fMax);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int ft8w_block_size(IntPtr handle);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern void ft8w_reset(IntPtr handle);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern void ft8w_process(IntPtr handle, float[] block);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int ft8w_decode(IntPtr handle, IntPtr results, int maxResults, int minScore, int maxCandidates, int ldpcIterations);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern void ft8w_free(IntPtr handle);
}

/// One slot's decoder: the Mac's FT8Decoder. Call <see cref="Process"/> for
/// every <see cref="BlockSize"/>-sized chunk of the slot's 12 kHz audio, then
/// <see cref="Decode"/> once. Not thread-safe: the coordinator confines it to
/// one worker.
public sealed class Ft8Decoder : IDisposable
{
    private IntPtr _handle;

    /// Exact number of samples <see cref="Process"/> requires per call.
    public int BlockSize { get; }

    /// <param name="sampleRate">12000 Hz in the app (what ft8_lib's vectors use).</param>
    /// <param name="fMinHz">Analysis passband, ft8_lib's own demo defaults.</param>
    public Ft8Decoder(int sampleRate, Ft8Mode mode = Ft8Mode.Ft8, float fMinHz = 200, float fMaxHz = 3000)
    {
        _handle = Ft8Native.ft8w_create(sampleRate, mode == Ft8Mode.Ft4 ? 1 : 0, fMinHz, fMaxHz);
        if (_handle == IntPtr.Zero)
        {
            throw new InvalidOperationException("ft8lib could not allocate a decoder");
        }
        BlockSize = Ft8Native.ft8w_block_size(_handle);
    }

    public void Dispose()
    {
        if (_handle != IntPtr.Zero)
        {
            Ft8Native.ft8w_free(_handle);
            _handle = IntPtr.Zero;
        }
        GC.SuppressFinalize(this);
    }

    ~Ft8Decoder() => Dispose();

    public void Reset() => Ft8Native.ft8w_reset(_handle);

    public void Process(float[] block)
    {
        if (block.Length != BlockSize)
        {
            throw new ArgumentException($"Process needs exactly {BlockSize} samples, got {block.Length}");
        }
        Ft8Native.ft8w_process(_handle, block);
    }

    /// Candidate search, LDPC decode and unpack, with duplicate payloads
    /// dropped (ft8_lib's own demo behavior).
    public List<Ft8RawMessage> Decode(int minScore = 10, int maxCandidates = 140, int ldpcIterations = 25)
    {
        var size = Ft8Native.ft8w_result_size();
        var buffer = Marshal.AllocHGlobal(size * maxCandidates);
        try
        {
            var count = Ft8Native.ft8w_decode(_handle, buffer, maxCandidates, minScore, maxCandidates, ldpcIterations);
            var results = new List<Ft8RawMessage>(count);
            for (var i = 0; i < count; i++)
            {
                var native = Marshal.PtrToStructure<Ft8Native.Result>(buffer + i * size);
                var end = Array.IndexOf(native.Text, (byte)0);
                var text = System.Text.Encoding.ASCII.GetString(native.Text, 0, end < 0 ? native.Text.Length : end);
                results.Add(new Ft8RawMessage(
                    text,
                    Fields(text, native.Types, native.Offsets),
                    native.FreqHz,
                    native.DtSec,
                    native.Score,
                    native.LdpcErrors));
            }
            return results;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    /// Splits the text at ft8_lib's field offsets (an offset below 0 ends the
    /// list) and classifies each slice.
    internal static List<Ft8MessageField> Fields(string text, int[] types, int[] offsets)
    {
        var fields = new List<Ft8MessageField>();
        for (var i = 0; i < 3; i++)
        {
            var start = offsets[i];
            if (start < 0)
            {
                break;
            }
            var end = i + 1 < 3 && offsets[i + 1] >= 0 ? offsets[i + 1] : text.Length;
            if (start >= end || end > text.Length)
            {
                continue;
            }
            var slice = text[start..end].Trim(' ', '\t');
            if (slice.Length == 0)
            {
                continue;
            }
            var kind = types[i] is >= 1 and <= 6 ? (Ft8FieldKind)types[i] : Ft8FieldKind.Unknown;
            fields.AddRange(Classified(new Ft8MessageField(kind, slice)));
        }
        return fields;
    }

    /// Two corrections to ft8_lib's grid field (see FT8Decoder.classified in
    /// the Mac's wrapper): "RR73" is a token however it was packed, and
    /// "R FN42" is the token "R" plus the grid.
    internal static IEnumerable<Ft8MessageField> Classified(Ft8MessageField field)
    {
        if (field.Kind != Ft8FieldKind.Grid)
        {
            yield return field;
            yield break;
        }
        var grid = field.Text;
        if (grid.StartsWith("R ", StringComparison.Ordinal))
        {
            yield return new Ft8MessageField(Ft8FieldKind.Token, "R");
            grid = grid[2..].Trim(' ', '\t');
        }
        yield return new Ft8MessageField(grid == "RR73" ? Ft8FieldKind.Token : Ft8FieldKind.Grid, grid);
    }
}
