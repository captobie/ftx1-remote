namespace FTX1RemoteWindows.Services;

/// Writes the audio SdrPageBridge taps out of an OpenWebRX page (Int16 mono
/// blocks, posted by the page tap) to a WAV in Recordings — the Mac's
/// SDRAudioFileWriter, the app-side recorder for the one WebSDR-window
/// platform with no recorder of its own. 16-bit PCM at the page's own
/// `AudioContext` rate (44.1/48 kHz; WFM needs the full rate, so nothing is
/// decimated, ~5.6 MB/min at 48 kHz).
///
/// Written straight from the UI thread: a block is 8 KB about 12 times a
/// second, which needs no queue of its own (the Mac hands each one to a
/// serial queue). The file is created on the first block, since only the
/// page knows its rate. AudioRecorder (the CW page's RECORD) writes its WAVs
/// through this too, under its own lock.
public sealed class SdrAudioFileWriter
{
    public string Path { get; }
    private readonly string _logCategory;
    private FileStream? _file;
    private int _sampleRate;
    private long _dataBytes;
    private bool _failed;

    public SdrAudioFileWriter(string path, string logCategory = "websdr-recording")
    {
        Path = path;
        _logCategory = logCategory;
    }

    /// `pcm`: little-endian Int16 samples, as the page tap packs them.
    public void Append(byte[] pcm, int sampleRate)
    {
        if (_failed || sampleRate <= 0 || pcm.Length < 2)
        {
            return;
        }
        try
        {
            if (_file is null)
            {
                _file = new FileStream(Path, FileMode.CreateNew, FileAccess.Write);
                _sampleRate = sampleRate;
                WriteHeader(_file, sampleRate, 0);
            }
            _file.Write(pcm, 0, pcm.Length & ~1);
            _dataBytes += pcm.Length & ~1;
        }
        catch (Exception ex)
        {
            _failed = true;
            AppLog.Write($"{_logCategory}: couldn't write {System.IO.Path.GetFileName(Path)}: {ex.Message}");
        }
    }

    /// Fills in the header's sizes and closes the file. Returns its path,
    /// or null (and no file) if nothing was recorded.
    public string? Finish()
    {
        if (_file is null)
        {
            return null;
        }
        try
        {
            _file.Seek(0, SeekOrigin.Begin);
            WriteHeader(_file, _sampleRate, _dataBytes);
        }
        catch (Exception ex)
        {
            AppLog.Write($"{_logCategory}: couldn't finish {System.IO.Path.GetFileName(Path)}: {ex.Message}");
        }
        _file.Dispose();
        _file = null;
        if (_dataBytes == 0)
        {
            try
            {
                File.Delete(Path);
            }
            catch
            {
                // An empty WAV left behind is harmless.
            }
            return null;
        }
        return Path;
    }

    /// The canonical 44-byte RIFF/WAVE header for 16-bit mono PCM.
    private static void WriteHeader(Stream stream, int sampleRate, long dataBytes)
    {
        using var writer = new BinaryWriter(stream, System.Text.Encoding.ASCII, leaveOpen: true);
        writer.Write("RIFF"u8);
        writer.Write((uint)Math.Min(uint.MaxValue, 36 + dataBytes));
        writer.Write("WAVE"u8);
        writer.Write("fmt "u8);
        writer.Write(16u);
        writer.Write((ushort)1);   // PCM
        writer.Write((ushort)1);   // mono
        writer.Write((uint)sampleRate);
        writer.Write((uint)(sampleRate * 2));
        writer.Write((ushort)2);   // block align
        writer.Write((ushort)16);  // bits per sample
        writer.Write("data"u8);
        writer.Write((uint)Math.Min(uint.MaxValue, dataBytes));
    }
}
