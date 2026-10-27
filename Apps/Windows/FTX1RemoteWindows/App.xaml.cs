using FTX1RemoteWindows.Settings;
using Microsoft.UI.Xaml;

namespace FTX1RemoteWindows;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        Loc.ApplyNumberFormat();
        Loc.ApplyDebugLanguageOverride();
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Before any XAML loads: MainWindow's refers to the theme's brushes.
        ThemeEngine.Load();
        _window = new MainWindow();
        _window.Activate();
    }
}
