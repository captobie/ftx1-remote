using System.Collections.Concurrent;

namespace FTX1RemoteWindows.Services;

/// Stands in for the app's AppLog (Services/AppLog.cs) in the linked hub
/// files, so the tests don't write to the user's
/// %LOCALAPPDATA%\FTX1RemoteWindows\app.log.
public static class AppLog
{
    public static ConcurrentQueue<string> Lines { get; } = new();

    public static void Write(string message) => Lines.Enqueue(message);
}
