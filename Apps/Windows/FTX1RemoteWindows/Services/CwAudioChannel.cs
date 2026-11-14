namespace FTX1RemoteWindows.Services;

/// Which audio the CW decoder listens to. MAIN/SUB are roles, not L/R
/// channels: MainWindow's audio routing already swaps the channels to
/// follow a Main/Sub swap, so Main is always the Main VFO's audio. WebSdr
/// is whatever the WebSDR window is playing (WebSdrAudioTap).
public enum CwAudioChannel
{
    Main,
    Sub,
    WebSdr,
    /// The MyKiwiSDR window's audio (LocalSdrAudioSource).
    MyKiwiSdr,
}
