using Microsoft.UI.Xaml.Markup;

namespace FTX1RemoteWindows.Localization;

/// XAML's way to a localized string: Text="{l:Str Key=settings.save}" with
/// xmlns:l="using:FTX1RemoteWindows.Localization". See <see cref="Loc"/>.
[MarkupExtensionReturnType(ReturnType = typeof(string))]
public sealed partial class Str : MarkupExtension
{
    public string Key { get; set; } = "";

    protected override object ProvideValue() => Loc.S(Key);
}
