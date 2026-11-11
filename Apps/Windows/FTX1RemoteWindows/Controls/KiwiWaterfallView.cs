using System.Globalization;
using System.Runtime.InteropServices.WindowsRuntime;
using FTX1RemoteWindows.Services;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;

namespace FTX1RemoteWindows.Controls;

/// The MyKiwiSDR window's waterfall — the Mac's LocalSDRWaterfallView: the
/// KiwiSDR's rows (LocalSdrModel.Bitmap), a frequency scale, the passband as a
/// translucent band with the dial line, and the mouse — click to tune, drag to
/// pan, scroll wheel to tune in the mode's steps; dragging the passband's
/// edges sets its width, dragging its middle tunes.
///
/// Everything is drawn in the *requested* view's frame while it has the
/// picture's zoom: the picture is offset to where its rows really are, so a
/// drag follows the mouse at once and the edge coming into view is black until
/// the Kiwi's rows (~150 ms later) fill it. During a zoom change the picture's
/// own frame is used until the first row at the new zoom. Per row only the
/// image is redrawn; the scale and passband layers are rebuilt when the
/// position, tuning or size changes.
public sealed class KiwiWaterfallView : UserControl
{
    private const double ScaleHeight = 20;

    private readonly LocalSdrModel _model;
    private readonly CursorGrid _surface = new() { Background = new SolidColorBrush(Colors.Black) };
    private readonly Image _image = new() { Stretch = Stretch.Fill, IsHitTestVisible = false };
    private readonly TranslateTransform _imageShift = new();
    private readonly Canvas _passbandLayer = new() { IsHitTestVisible = false };
    private readonly Canvas _scale = new();
    private readonly TextBlock _placeholder = new()
    {
        TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Foreground = new SolidColorBrush(Color.FromArgb(180, 255, 255, 255)),
        Margin = new Thickness(16),
        IsHitTestVisible = false,
    };
    private WriteableBitmap? _writeable;

    // Mouse state.
    private enum DragTarget { Pan, Edge, Middle }
    private DragTarget _pressTarget = DragTarget.Pan;
    private KiwiPassband.Edge _pressEdge;
    private double? _pressX;
    private bool _dragging;
    private int? _panOrigin;
    private int? _tuneOrigin;

    private (int Start, int Zoom, double Width, int Dial, int Low, int High)? _drawn;

    public KiwiWaterfallView(LocalSdrModel model)
    {
        _model = model;
        _image.RenderTransform = _imageShift;
        var picture = new Grid();
        ClipTo(picture);
        _surface.Children.Add(_image);
        _surface.Children.Add(_passbandLayer);
        _surface.Children.Add(_placeholder);
        picture.Children.Add(_surface);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(ScaleHeight) });
        root.Children.Add(picture);
        Grid.SetRow(_scale, 1);
        ClipTo(_scale);
        root.Children.Add(_scale);
        Content = root;

        _surface.SizeChanged += (_, _) => Redraw();
        _surface.PointerPressed += OnPressed;
        _surface.PointerMoved += OnMoved;
        _surface.PointerReleased += OnReleased;
        _surface.PointerCanceled += (_, _) => EndPress();
        _surface.PointerCaptureLost += (_, _) => EndPress();
        _surface.PointerWheelChanged += OnWheel;
        ToolTipService.SetToolTip(_surface, Loc.S("localSdr.waterfall.help"));

        _model.PictureChanged += OnPicture;
        Unloaded += (_, _) => _model.PictureChanged -= OnPicture;
        Redraw();
    }

    /// WinUI 3 has no ClipToBounds: clip to the element's own size.
    private static void ClipTo(FrameworkElement element) =>
        element.SizeChanged += (_, e) => element.Clip = new RectangleGeometry
        {
            Rect = new Rect(0, 0, e.NewSize.Width, e.NewSize.Height),
        };

    /// The model's state changed (view, tuning, passband, connection).
    public void Refresh() => Redraw();

    // MARK: Picture

    private void OnPicture()
    {
        if (_model.Bitmap is not { } bitmap)
        {
            _writeable = null;
            _image.Source = null;
            Redraw();
            return;
        }
        if (_writeable is null || _writeable.PixelWidth != bitmap.Width || _writeable.PixelHeight != bitmap.Height)
        {
            _writeable = new WriteableBitmap(bitmap.Width, bitmap.Height);
            _image.Source = _writeable;
        }
        bitmap.Pixels.CopyTo(0, _writeable.PixelBuffer, 0, bitmap.Pixels.Length);
        _writeable.Invalidate();
        PlaceImage();
        // The newest row's position can differ from the requested view.
        if (_drawn is null || DisplayFrame() is not { } frame || frame.Start != _drawn.Value.Start || frame.Zoom != _drawn.Value.Zoom)
        {
            Redraw();
        }
    }

    private LocalSdrModel.WaterfallView? DisplayFrame()
    {
        if (_model.PicturePosition is not { } picture)
        {
            return _model.View;
        }
        if (_model.View is { } view && view.Zoom == picture.Zoom)
        {
            return view;
        }
        return picture;
    }

    private void PlaceImage()
    {
        var width = _surface.ActualWidth;
        if (DisplayFrame() is { } frame && _model.PicturePosition is { } picture && picture.Zoom == frame.Zoom && width > 0)
        {
            var geometry = _model.Geometry;
            var offsetColumns = (double)(picture.Start - frame.Start) / geometry.UnitsPerBin(frame.Zoom);
            _imageShift.X = offsetColumns / geometry.FftSize * width;
        }
        else
        {
            _imageShift.X = 0;
        }
        _image.Width = width;
    }

    // MARK: Layers

    private void Redraw()
    {
        var width = _surface.ActualWidth;
        var hasPicture = _model.PicturePosition is not null && _model.Bitmap is not null;
        _image.Visibility = hasPicture ? Visibility.Visible : Visibility.Collapsed;
        _placeholder.Visibility = hasPicture ? Visibility.Collapsed : Visibility.Visible;
        if (!hasPicture)
        {
            _placeholder.Text = PlaceholderText();
        }
        PlaceImage();
        if (width <= 0 || !hasPicture || DisplayFrame() is not { } frame)
        {
            _passbandLayer.Children.Clear();
            _scale.Children.Clear();
            _drawn = null;
            return;
        }
        var band = _model.PassbandHz;
        var key = (frame.Start, frame.Zoom, width, _model.FrequencyHz, _model.Passband.Low, _model.Passband.High);
        var shown = _drawn;
        if (shown is { } previous && previous == key)
        {
            return;
        }
        _drawn = key;
        DrawPassband(frame, band, width);
        DrawScale(frame, width);
    }

    private string PlaceholderText() => _model.Waterfall switch
    {
        LocalSdrModel.WaterfallState.Failed => Loc.F("localSdr.waterfall.failed", LocalSdrWindow.Message(_model.WaterfallError)),
        LocalSdrModel.WaterfallState.Connecting or LocalSdrModel.WaterfallState.Running => Loc.S("localSdr.waterfall.waiting"),
        _ => Loc.S("localSdr.waterfall.idle"),
    };

    private double X(double hz, LocalSdrModel.WaterfallView frame, double width) =>
        _model.Geometry.Column(hz, frame.Start, frame.Zoom) / _model.Geometry.FftSize * width;

    private double HzAt(double x, LocalSdrModel.WaterfallView frame, double width) =>
        _model.Geometry.HzAtColumn(x / width * _model.Geometry.FftSize, frame.Start, frame.Zoom);

    private void DrawPassband(LocalSdrModel.WaterfallView frame, (double Low, double High) band, double width)
    {
        _passbandLayer.Children.Clear();
        var height = _surface.ActualHeight;
        var a = X(band.Low, frame, width);
        var b = X(band.High, frame, width);
        var left = Math.Min(a, b);
        var right = Math.Max(a, b);
        var yellow = Color.FromArgb(255, 255, 214, 10);
        var fill = new Rectangle
        {
            Width = Math.Max(right - left, 2),
            Height = height,
            Fill = new SolidColorBrush(Color.FromArgb(46, 255, 214, 10)),
        };
        Canvas.SetLeft(fill, left);
        _passbandLayer.Children.Add(fill);
        foreach (var edge in new[] { left, right })
        {
            var line = new Rectangle { Width = 1, Height = height, Fill = new SolidColorBrush(Color.FromArgb(140, 255, 214, 10)) };
            Canvas.SetLeft(line, edge);
            _passbandLayer.Children.Add(line);
            // A tab at the top to show the edge can be held.
            var tab = new Rectangle { Width = 3, Height = 12, Fill = new SolidColorBrush(Color.FromArgb(230, 255, 214, 10)) };
            Canvas.SetLeft(tab, edge - 1.5);
            _passbandLayer.Children.Add(tab);
        }
        var dial = X(_model.FrequencyHz, frame, width);
        var dialLine = new Rectangle { Width = 1.5, Height = height, Fill = new SolidColorBrush(yellow) };
        Canvas.SetLeft(dialLine, dial - 0.75);
        _passbandLayer.Children.Add(dialLine);
    }

    private void DrawScale(LocalSdrModel.WaterfallView frame, double width)
    {
        _scale.Children.Clear();
        var geometry = _model.Geometry;
        var span = geometry.SpanHz(frame.Zoom);
        var leftHz = geometry.HzAtColumn(0, frame.Start, frame.Zoom);
        var spacing = TickSpacing(span, width);
        var digits = Math.Max(0, (int)Math.Ceiling(-Math.Log10(spacing / 1_000_000)));
        var first = Math.Ceiling(leftHz / spacing) * spacing;
        var brush = new SolidColorBrush(Color.FromArgb(200, 160, 160, 160));
        for (var hz = first; hz <= leftHz + span; hz += spacing)
        {
            var x = (hz - leftHz) / span * width;
            var mark = new Rectangle { Width = 1, Height = 5, Fill = brush };
            Canvas.SetLeft(mark, x);
            _scale.Children.Add(mark);
            var label = new TextBlock
            {
                Text = (hz / 1_000_000).ToString("F" + digits, CultureInfo.InvariantCulture),
                FontFamily = new FontFamily("Consolas"),
                FontSize = 10,
                Foreground = brush,
            };
            Canvas.SetLeft(label, x - 18);
            Canvas.SetTop(label, 5);
            _scale.Children.Add(label);
        }
    }

    public static double TickSpacing(double spanHz, double width)
    {
        var labels = Math.Max(2, width / 80);
        var raw = spanHz / labels;
        var power = Math.Pow(10, Math.Floor(Math.Log10(raw)));
        foreach (var factor in new[] { 1.0, 2, 5, 10 })
        {
            if (factor * power >= raw)
            {
                return factor * power;
            }
        }
        return 10 * power;
    }

    // MARK: Mouse

    private (DragTarget Target, KiwiPassband.Edge Edge) TargetAt(double x)
    {
        var width = _surface.ActualWidth;
        if (_model.PicturePosition is null || DisplayFrame() is not { } frame || width <= 0)
        {
            return (DragTarget.Pan, default);
        }
        var band = _model.PassbandHz;
        var a = X(band.Low, frame, width);
        var b = X(band.High, frame, width);
        double low = Math.Min(a, b), high = Math.Max(a, b);
        const double outward = 5;
        var inward = Math.Min(5, (high - low) / 3);
        if (x >= low + inward && x <= high - inward)
        {
            return (DragTarget.Middle, default);
        }
        if (x >= low - outward && x < low + inward)
        {
            return (DragTarget.Edge, KiwiPassband.Edge.Low);
        }
        if (x > high - inward && x <= high + outward)
        {
            return (DragTarget.Edge, KiwiPassband.Edge.High);
        }
        return (DragTarget.Pan, default);
    }

    private void SetCursor(DragTarget target, bool dragging) =>
        _surface.SetCursor(target switch
        {
            DragTarget.Edge => InputSystemCursorShape.SizeWestEast,
            DragTarget.Middle => dragging ? InputSystemCursorShape.SizeAll : InputSystemCursorShape.Hand,
            _ => dragging ? InputSystemCursorShape.SizeAll : InputSystemCursorShape.Cross,
        });

    private void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        var x = e.GetCurrentPoint(_surface).Position.X;
        _pressX = x;
        (_pressTarget, _pressEdge) = TargetAt(x);
        _dragging = false;
        _panOrigin = null;
        _tuneOrigin = null;
        _surface.CapturePointer(e.Pointer);
    }

    private void OnMoved(object sender, PointerRoutedEventArgs e)
    {
        var x = e.GetCurrentPoint(_surface).Position.X;
        if (_pressX is not { } pressX)
        {
            SetCursor(TargetAt(x).Target, false);
            return;
        }
        var dx = x - pressX;
        if (!_dragging && Math.Abs(dx) < 3)
        {
            return;
        }
        if (!_dragging)
        {
            SetCursor(_pressTarget, true);
        }
        _dragging = true;
        Drag(dx, x);
    }

    private void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        var x = e.GetCurrentPoint(_surface).Position.X;
        var wasPress = _pressX is not null;
        var wasDrag = _dragging;
        EndPress();
        _surface.ReleasePointerCapture(e.Pointer);
        if (wasPress && !wasDrag)
        {
            Click(x);
        }
        SetCursor(TargetAt(x).Target, false);
    }

    private void EndPress()
    {
        _pressX = null;
        _dragging = false;
        _panOrigin = null;
        _tuneOrigin = null;
    }

    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        var delta = e.GetCurrentPoint(_surface).Properties.MouseWheelDelta;
        if (delta != 0)
        {
            _model.ScrollStep(delta > 0 ? 1 : -1);
            e.Handled = true;
        }
    }

    private void Click(double x)
    {
        var width = _surface.ActualWidth;
        if (DisplayFrame() is not { } frame || width <= 0)
        {
            return;
        }
        _model.TuneToWaterfallHz(HzAt(x, frame, width));
    }

    private void Drag(double dx, double x)
    {
        var width = _surface.ActualWidth;
        if (DisplayFrame() is not { } frame || width <= 0)
        {
            return;
        }
        switch (_pressTarget)
        {
            case DragTarget.Pan:
                if (_model.View is { } view)
                {
                    var origin = _panOrigin ??= view.Start;
                    var units = dx / width * _model.Geometry.SpanUnits(view.Zoom);
                    _model.Pan(origin - (int)Math.Round(units, MidpointRounding.AwayFromZero));
                }
                break;
            case DragTarget.Edge:
                _model.DragPassbandEdge(_pressEdge, HzAt(x, frame, width));
                break;
            case DragTarget.Middle:
                var dial = _tuneOrigin ??= _model.FrequencyHz;
                _model.TuneToWaterfallHz(dial + dx / width * _model.Geometry.SpanHz(frame.Zoom));
                break;
        }
    }

    /// A grid that can set its own mouse cursor (UIElement.ProtectedCursor is
    /// protected).
    private sealed class CursorGrid : Grid
    {
        public void SetCursor(InputSystemCursorShape shape) => ProtectedCursor = InputSystemCursor.Create(shape);
    }
}
