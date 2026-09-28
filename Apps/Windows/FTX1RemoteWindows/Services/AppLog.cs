using System.Diagnostics;

namespace FTX1RemoteWindows.Services;

/// The app's diagnostic log: every line goes to the debugger's output (as
/// Debug.WriteLine did before) and, timestamped, to
/// %LOCALAPPDATA%\FTX1RemoteWindows\app.log, so a problem seen without a
/// debugger attached can be read afterwards — the counterpart of the Mac's
/// os.Logger lines in Console.app. Lines keep the Mac's "category: message"
/// shape (e.g. "audio-routing: ...", "poll: ...").
///
/// Past <see cref="MaxBytes"/> the file is moved to app.log.1 (replacing
/// the previous one) and a fresh one started, so it can't grow without
/// bound. Safe to call from any thread. Logging never throws: a failed
/// write is dropped.
public static class AppLog
{
    private const long MaxBytes = 2 * 1024 * 1024;

    private static readonly object Gate = new();

    public static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FTX1RemoteWindows",
        "app.log");

    public static void Write(string message)
    {
        Debug.WriteLine(message);
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{Environment.CurrentManagedThreadId}] {message}{Environment.NewLine}";
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > MaxBytes)
                {
                    File.Move(FilePath, FilePath + ".1", overwrite: true);
                }
                File.AppendAllText(FilePath, line);
            }
            catch
            {
                // Best-effort, like AppSettings.Save.
            }
        }
    }
}
