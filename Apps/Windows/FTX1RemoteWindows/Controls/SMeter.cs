using FTX1RemoteWindows.Models;
using FTX1RemoteWindows.Settings;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.UI;

namespace FTX1RemoteWindows.Controls;

/// Port of the Mac/iPad analog meter (Sources/FTX1Core/UI/SMeterView.swift):
/// the rig display's upper-left meter, with an arc-style S scale (S1-S9 in
/// dark ink, +20/+40/+60 dB in blue) over a lower scale, and a red needle
/// sweeping both from a pivot below the box. Shows signal strength on the S
/// scale while receiving, and the chosen TX meter (PO by default, like the
/// rig) on the lower scale while transmitting. Clicking the meter opens the
/// METER picker, remembered separately for Main and Sub like the rig's
/// MAIN/SUB METER SW settings (a local display choice; nothing is sent to
/// the rig).
///
/// The Sub meter's needle stays on the S scale even during TX, same as the
/// Mac: Sub can't transmit today and the TX readings are Main's.
///
/// Drawn with plain XAML shapes in SMeterView's fixed 280×120 design space,
/// scaled by a Viewbox, so it needs no Win2D dependency. The needle is one
/// line rotated about the pivot, which lets the 0.4 s ease-out sweep run as
/// an ordinary RotateTransform animation.
public sealed class SMeter : UserControl
{
    private const double DesignWidth = 280;
    private const double DesignHeight = 120;

    /// Half-sweep of the needle/scale arc, degrees — SMeterView's maxAngle.
    private const double MaxAngleDegrees = 17;
    private static readonly double MaxAngle = MaxAngleDegrees * Math.PI / 180;
    /// Radius reaching the S-numeral row, sized so the sweep spans ~92% of
    /// the design width.
    private static readonly double OuterRadius = 0.46 * DesignWidth / Math.Sin(MaxAngle);
    private static readonly Point Pivot = new(DesignWidth / 2, 30 + OuterRadius);

    // Printed ink on the lit face, as on the Mac.
    private static readonly Color Ink = Color.FromArgb(255, 26, 20, 15);
    private static readonly Color Blue = Color.FromArgb(255, 26, 64, 191);

    private readonly bool _isSub;
    private readonly Canvas _face = new() { Width = DesignWidth, Height = DesignHeight };
    private readonly RotateTransform _needleRotation = new() { CenterX = Pivot.X, CenterY = Pivot.Y };
    private readonly Storyboard _needleStoryboard = new();
    private readonly DoubleAnimation _needleAnimation;
    private readonly Flyout _pickerFlyout = new();
    private readonly Grid _pickerGrid = new() { ColumnSpacing = 8, RowSpacing = 8 };

    private MeterSelection _selection;
    private double _needleFraction = double.NaN;

    private double? _strengthDb;
    private MeterReadings _readings = new(null, null, null);
    private bool _ptt;

    private readonly bool _receiveOnly;
    private readonly Grid _analog;
    private readonly Viewbox _viewbox = new() { Stretch = Stretch.Uniform };
    private readonly DigitalFace _digital;
    private SMeterStyle _style = SMeterStyle.Lighted;

    /// receiveOnly (the MyKiwiSDR window's meter): no TX needle and no
    /// METER picker on click; the lower scale stays at the saved MAIN
    /// selection. label replaces the MAIN/SUB accessible name.
    public SMeter(bool isSub, bool receiveOnly = false, string? label = null)
    {
        _isSub = isSub;
        _receiveOnly = receiveOnly;
        _selection = isSub ? AppSettings.SubMeterSelection : AppSettings.MainMeterSelection;
        AutomationProperties.SetName(this, label ?? (isSub ? Loc.S("sMeter.subMeter") : Loc.S("sMeter.mainMeter")));

        _digital = new DigitalFace(receiveOnly);

        // Design-space content: backlit face, scales, needle, bezel shading.
        var content = new Grid
        {
            Width = DesignWidth,
            Height = DesignHeight,
            Background = Backlight(),
            Clip = new RectangleGeometry { Rect = new Rect(0, 0, DesignWidth, DesignHeight) },
        };
        _analog = content;
        content.Children.Add(_face);
        content.Children.Add(BuildNeedle());
        // Recessed-bezel shading, darkening the rim so the lit face reads as
        // sitting behind glass (the Mac blurs a 3 pt black stroke; a softer,
        // unblurred one is the closest plain-XAML match).
        content.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(3),
            BorderBrush = new SolidColorBrush(Color.FromArgb(90, 0, 0, 0)),
        });

        Content = new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1.5),
            BorderBrush = new SolidColorBrush(Color.FromArgb(153, 128, 128, 128)),
            Child = _viewbox,
        };

        _needleAnimation = new DoubleAnimation
        {
            Duration = new Duration(TimeSpan.FromSeconds(0.4)),
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut },
        };
        Storyboard.SetTarget(_needleAnimation, _needleRotation);
        Storyboard.SetTargetProperty(_needleAnimation, "Angle");
        _needleStoryboard.Children.Add(_needleAnimation);

        BuildPicker();
        _pickerFlyout.Content = new StackPanel
        {
            Spacing = 10,
            Children =
            {
                new TextBlock { Text = "METER", FontWeight = FontWeights.SemiBold },
                _pickerGrid,
            },
        };
        if (!receiveOnly)
        {
            Tapped += (_, _) => _pickerFlyout.ShowAt(this);
            ToolTipService.SetToolTip(this, Loc.S("sMeter.clickToChooseWhat"));
        }

        DrawFace();
        ApplyStyle();
        UpdateNeedle(animate: false);
    }

    /// Picks the face from Settings → Appearance → S-meter: the lighted or
    /// unlighted analog face, or the Digital two-line bar. Called at
    /// construction and whenever Settings are saved. A receive-only meter
    /// with a width set (the MyKiwiSDR window's) takes its height from the
    /// face: analog 280:120, Digital a single 190:30 line.
    public void ApplyStyle()
    {
        _style = AppSettings.SMeterStyle;
        if (_style == SMeterStyle.Digital)
        {
            _viewbox.Child = _digital;
        }
        else
        {
            _viewbox.Child = null;
            _analog.Background = _style == SMeterStyle.Lighted ? Backlight() : Unlit();
            _viewbox.Child = _analog;
        }
        if (_receiveOnly && !double.IsNaN(Width))
        {
            Height = Width * (_style == SMeterStyle.Digital ? DigitalFace.ReceiveOnlyHeight / DigitalFace.DesignWidth : DesignHeight / DesignWidth);
        }
        UpdateDigital();
    }

    private bool ShowsTx => _ptt && !_isSub && !_receiveOnly;

    private void UpdateDigital()
    {
        if (_style == SMeterStyle.Digital)
        {
            _digital.Set(_strengthDb, _readings, ShowsTx, _selection);
        }
    }

    /// Feeds one poll's readings. A null reading rests the needle rather
    /// than holding the last one, as on the Mac.
    public void Update(double? strengthDb, MeterReadings readings, bool ptt)
    {
        _strengthDb = strengthDb;
        _readings = readings;
        _ptt = ptt;
        UpdateNeedle(animate: true);
        UpdateDigital();
    }

    /// Rests the needle, e.g. on disconnect.
    public void Reset() => Update(null, new MeterReadings(null, null, null), false);

    private void UpdateNeedle(bool animate)
    {
        var fraction = ShowsTx
            ? _selection.Fraction(_readings)
            : SMeterScale.FractionForStrengthDb(_strengthDb);
        if (fraction == _needleFraction)
        {
            return;
        }
        _needleFraction = fraction;
        var angle = MaxAngleDegrees * (2 * fraction - 1);
        if (animate)
        {
            _needleAnimation.To = angle;
            _needleStoryboard.Begin();
        }
        else
        {
            _needleRotation.Angle = angle;
        }
    }

    /// Incandescent-lamp look (modeled on an MFJ SWR/wattmeter face): a warm
    /// amber hotspot low and centered, falling off to pale cream.
    private static Brush Backlight()
    {
        var brush = new RadialGradientBrush
        {
            MappingMode = BrushMappingMode.Absolute,
            Center = new Point(DesignWidth * 0.5, DesignHeight * 0.8),
            GradientOrigin = new Point(DesignWidth * 0.5, DesignHeight * 0.8),
            RadiusX = 190,
            RadiusY = 190,
        };
        brush.GradientStops.Add(new GradientStop { Color = Color.FromArgb(255, 255, 224, 148), Offset = 0.0 });
        brush.GradientStops.Add(new GradientStop { Color = Color.FromArgb(255, 255, 240, 199), Offset = 0.4 });
        brush.GradientStops.Add(new GradientStop { Color = Color.FromArgb(255, 245, 235, 214), Offset = 0.75 });
        brush.GradientStops.Add(new GradientStop { Color = Color.FromArgb(255, 224, 217, 201), Offset = 1.0 });
        return brush;
    }

    /// The same face with the lamp off: flat, slightly grey paper, a touch
    /// darker toward the bottom where the bezel shades it.
    private static Brush Unlit()
    {
        var brush = new LinearGradientBrush
        {
            StartPoint = new Point(0, 0),
            EndPoint = new Point(0, 1),
        };
        brush.GradientStops.Add(new GradientStop { Color = Color.FromArgb(255, 219, 217, 209), Offset = 0.0 });
        brush.GradientStops.Add(new GradientStop { Color = Color.FromArgb(255, 199, 196, 189), Offset = 1.0 });
        return brush;
    }

    /// Design-space point at `fraction` along the sweep, `radialOffset`
    /// inward from the S-numeral arc (larger offset = lower on screen).
    private static Point PointAt(double fraction, double radialOffset)
    {
        var a = MaxAngle * (2 * fraction - 1);
        var r = OuterRadius - radialOffset;
        return new Point(Pivot.X + r * Math.Sin(a), Pivot.Y - r * Math.Cos(a));
    }

    /// The needle drawn at center sweep (fraction 0.5, straight up), from
    /// below the bottom edge into the S tick row, with a soft offset shadow;
    /// _needleRotation swings both about the pivot.
    private Canvas BuildNeedle()
    {
        var baseOffset = OuterRadius - Pivot.Y + DesignHeight + 10;
        var basePoint = PointAt(0.5, baseOffset);
        var tip = PointAt(0.5, 10);
        Line NeedleLine(Color color, double dx, double dy) => new()
        {
            X1 = basePoint.X + dx,
            Y1 = basePoint.Y + dy,
            X2 = tip.X + dx,
            Y2 = tip.Y + dy,
            Stroke = new SolidColorBrush(color),
            StrokeThickness = 2.5,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
        };
        return new Canvas
        {
            Width = DesignWidth,
            Height = DesignHeight,
            RenderTransform = _needleRotation,
            Children =
            {
                NeedleLine(Color.FromArgb(77, 0, 0, 0), 1, 1),
                NeedleLine(Colors.Red, 0, 0),
            },
        };
    }

    private void DrawFace()
    {
        _face.Children.Clear();

        // Row placement, as radial offsets inward from the S-numeral arc.
        (double, double) sTickSpan = (14, 26);
        const double lowerLabelOffset = 40;
        (double, double) lowerTickSpan = (54, 64);

        void Tick(double fraction, (double Inner, double Outer) span, Color color, double width)
        {
            var a = PointAt(fraction, span.Inner);
            var b = PointAt(fraction, span.Outer);
            _face.Children.Add(new Line
            {
                X1 = a.X,
                Y1 = a.Y,
                X2 = b.X,
                Y2 = b.Y,
                Stroke = new SolidColorBrush(color),
                StrokeThickness = width,
            });
        }

        // Row names sit at a fixed left margin rather than on the arc,
        // which would center them past the left edge and clip them.
        AddText("S", 13, FontWeights.Bold, Ink, new Point(6, PointAt(0, 2).Y), leading: true, italic: true);
        foreach (var (label, fraction, isBlue) in SMeterScale.STicks)
        {
            var color = isBlue ? Blue : Ink;
            AddText(label, 11, FontWeights.SemiBold, color, PointAt(fraction, 0));
            Tick(fraction, sTickSpan, color, 2);
        }
        for (var i = 1; i < SMeterScale.STicks.Length; i++)
        {
            var mid = (SMeterScale.STicks[i - 1].Fraction + SMeterScale.STicks[i].Fraction) / 2;
            Tick(mid, (sTickSpan.Item1, sTickSpan.Item2 - 4), SMeterScale.STicks[i].Blue ? Blue : Ink, 1);
        }
        AddText("dB", 10, FontWeights.SemiBold, Blue, PointAt(1.005, 0));

        // Lower scale: the METER selection.
        AddText(_selection.Title(), 10, FontWeights.Bold, Ink, new Point(6, PointAt(0, lowerLabelOffset - 2).Y), leading: true);
        if (_selection.Unit() is { } unit)
        {
            AddText(unit, 10, FontWeights.SemiBold, Ink, PointAt(0.97, lowerLabelOffset));
        }
        foreach (var (label, fraction) in _selection.Ticks())
        {
            AddText(label, 10, FontWeights.SemiBold, Ink, PointAt(fraction, lowerLabelOffset));
            Tick(fraction, lowerTickSpan, Ink, 1.5);
        }
    }

    /// Places text centered on `at` (or, with `leading`, left-aligned at it
    /// and vertically centered), via a fixed-size box so no measuring is
    /// needed before layout.
    private void AddText(string text, double size, Windows.UI.Text.FontWeight weight, Color color, Point at, bool leading = false, bool italic = false)
    {
        const double boxWidth = 60;
        const double boxHeight = 20;
        var block = new TextBlock
        {
            Text = text,
            FontSize = size,
            FontWeight = weight,
            FontStyle = italic ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal,
            Foreground = new SolidColorBrush(color),
            HorizontalAlignment = leading ? HorizontalAlignment.Left : HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            TextLineBounds = TextLineBounds.Tight,
        };
        var box = new Grid { Width = boxWidth, Height = boxHeight, Children = { block } };
        Canvas.SetLeft(box, leading ? at.X : at.X - boxWidth / 2);
        Canvas.SetTop(box, at.Y - boxHeight / 2);
        _face.Children.Add(box);
    }

    /// The rig's METER selector (manual p.20) as a 3-column button grid.
    private void BuildPicker()
    {
        _pickerGrid.Children.Clear();
        _pickerGrid.ColumnDefinitions.Clear();
        _pickerGrid.RowDefinitions.Clear();
        for (var c = 0; c < 3; c++)
        {
            _pickerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(70) });
        }
        var items = Enum.GetValues<MeterSelection>();
        for (var r = 0; r < (items.Length + 2) / 3; r++)
        {
            _pickerGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        }
        for (var i = 0; i < items.Length; i++)
        {
            var item = items[i];
            var button = new Button
            {
                Content = item.Title(),
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            if (item == _selection)
            {
                button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
            }
            ToolTipService.SetToolTip(button, item.Detail());
            button.Click += (_, _) => Select(item);
            Grid.SetColumn(button, i % 3);
            Grid.SetRow(button, i / 3);
            _pickerGrid.Children.Add(button);
        }
    }

    private void Select(MeterSelection selection)
    {
        _pickerFlyout.Hide();
        if (selection == _selection)
        {
            return;
        }
        _selection = selection;
        if (_isSub)
        {
            AppSettings.SubMeterSelection = selection;
        }
        else
        {
            AppSettings.MainMeterSelection = selection;
        }
        BuildPicker();
        DrawFace();
        UpdateNeedle(animate: true);
        UpdateDigital();
    }

    /// SMeterStyle.Digital (port of DigitalMeterFace in SMeterView.swift): two
    /// lines of segmented bar, laid out like the analog face — the S-meter on
    /// top, the picked TX meter (PO/SWR/ALC/…) underneath. The lower line is
    /// dim until the meter transmits; then both lines are TX readings, the top
    /// one PO (SWR when PO is the picked meter). A receive-only meter shows
    /// the S line alone. Drawn in a fixed 190-wide design space, scaled by the
    /// owner's Viewbox.
    private sealed class DigitalFace : UserControl
    {
        public const double DesignWidth = 190;
        public const double ReceiveOnlyHeight = 30;
        private static readonly double FullHeight = DesignWidth * SMeter.DesignHeight / SMeter.DesignWidth;

        private static readonly Color Green = Color.FromArgb(255, 52, 199, 89);
        private static readonly Color Orange = Color.FromArgb(255, 255, 149, 0);
        private static readonly Color Hot = Color.FromArgb(255, 255, 59, 48);
        private static readonly Color Dim = Color.FromArgb(153, 255, 255, 255);

        private readonly BarLine _top = new();
        private readonly BarLine _bottom = new();
        private readonly bool _receiveOnly;

        public DigitalFace(bool receiveOnly)
        {
            _receiveOnly = receiveOnly;
            Width = DesignWidth;
            Height = receiveOnly ? ReceiveOnlyHeight : FullHeight;
            var lines = new StackPanel
            {
                Spacing = 2,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(6, 4, 6, 4),
            };
            lines.Children.Add(_top);
            if (!receiveOnly)
            {
                lines.Children.Add(_bottom);
            }
            Content = new Border
            {
                Background = new SolidColorBrush(Colors.Black),
                CornerRadius = new CornerRadius(8),
                Child = lines,
            };
        }

        public void Set(double? strengthDb, MeterReadings readings, bool showsTx, MeterSelection selection)
        {
            if (showsTx)
            {
                SetTx(_top, selection == MeterSelection.Po ? MeterSelection.Swr : MeterSelection.Po, readings, active: true);
            }
            else
            {
                _top.Set("S", Dim, BarMeterScale.SUnitText(strengthDb), BarMeterScale.ForStrengthDb(strengthDb),
                    BarMeterScale.STicks, BarMeterScale.S9Fraction, Green);
            }
            if (!_receiveOnly)
            {
                SetTx(_bottom, selection, readings, showsTx);
                _bottom.Opacity = showsTx ? 1 : 0.45;
            }
        }

        /// A TX meter's line; inactive = no reading (bar unlit, "—").
        private static void SetTx(BarLine line, MeterSelection meter, MeterReadings readings, bool active) =>
            line.Set(
                meter.Title(),
                active ? Orange : Dim,
                active ? BarMeterScale.TxReadout(meter, readings) : "—",
                active ? BarMeterScale.FromFace(meter.Fraction(readings)) : 0,
                meter.Ticks().Select(t => (t.Label, BarMeterScale.FromFace(t.Fraction))).ToArray(),
                1.1,
                Orange);

        private sealed class BarLine : Grid
        {
            private const int SegmentCount = 36;
            private const double BarWidth = 110;
            private const double BarHeight = 10;
            private const double Gap = 1.5;

            private readonly TextBlock _title = new()
            {
                FontSize = 9,
                FontWeight = FontWeights.SemiBold,
                Width = 24,
                TextTrimming = TextTrimming.Clip,
                VerticalAlignment = VerticalAlignment.Top,
            };
            private readonly TextBlock _readout = new()
            {
                FontSize = 11,
                FontWeight = FontWeights.SemiBold,
                FontFamily = new FontFamily("Consolas"),
                Foreground = new SolidColorBrush(Colors.White),
                Width = 36,
                TextAlignment = TextAlignment.Right,
                TextTrimming = TextTrimming.Clip,
                VerticalAlignment = VerticalAlignment.Top,
            };
            private readonly Canvas _bar = new() { Width = BarWidth, Height = BarHeight + 16 };
            private readonly Rectangle[] _segments = new Rectangle[SegmentCount];
            private string _tickKey = "";

            public BarLine()
            {
                ColumnSpacing = 4;
                ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
                ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(BarWidth) });
                ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(36) });
                var segWidth = (BarWidth - Gap * (SegmentCount - 1)) / SegmentCount;
                for (var i = 0; i < SegmentCount; i++)
                {
                    var rect = new Rectangle
                    {
                        Width = segWidth,
                        Height = BarHeight,
                        RadiusX = 1,
                        RadiusY = 1,
                        Fill = new SolidColorBrush(Colors.Transparent),
                    };
                    Canvas.SetLeft(rect, i * (segWidth + Gap));
                    Canvas.SetTop(rect, 2);
                    _segments[i] = rect;
                    _bar.Children.Add(rect);
                }
                SetColumn(_bar, 1);
                SetColumn(_readout, 2);
                Children.Add(_title);
                Children.Add(_bar);
                Children.Add(_readout);
            }

            public void Set(string title, Color titleColor, string readout, double fraction,
                (string Label, double Fraction)[] ticks, double hotFrom, Color litColor)
            {
                _title.Text = title;
                _title.Foreground = new SolidColorBrush(titleColor);
                _readout.Text = readout;
                for (var i = 0; i < SegmentCount; i++)
                {
                    var mid = (i + 0.5) / SegmentCount;
                    var color = mid >= hotFrom ? Hot : litColor;
                    if (mid > fraction)
                    {
                        color.A = (byte)(color.A * 0.15);
                    }
                    ((SolidColorBrush)_segments[i].Fill).Color = color;
                }
                var key = string.Join('|', ticks.Select(t => $"{t.Label}@{t.Fraction:0.####}"));
                if (key != _tickKey)
                {
                    _tickKey = key;
                    RebuildTicks(ticks);
                }
            }

            /// Tick labels under the segments; the end ones are anchored to
            /// the bar's edges so they don't spill past it.
            private void RebuildTicks((string Label, double Fraction)[] ticks)
            {
                for (var i = _bar.Children.Count - 1; i >= SegmentCount; i--)
                {
                    _bar.Children.RemoveAt(i);
                }
                const double boxWidth = 30;
                foreach (var (label, f) in ticks)
                {
                    var alignment = f < 0.03 ? TextAlignment.Left : f > 0.97 ? TextAlignment.Right : TextAlignment.Center;
                    var left = f * BarWidth - (alignment == TextAlignment.Left ? 0 : alignment == TextAlignment.Right ? boxWidth : boxWidth / 2);
                    var block = new TextBlock
                    {
                        Text = label,
                        FontSize = 9,
                        FontWeight = FontWeights.Medium,
                        Foreground = new SolidColorBrush(Color.FromArgb(166, 255, 255, 255)),
                        TextAlignment = alignment,
                        Width = boxWidth,
                    };
                    Canvas.SetLeft(block, left);
                    Canvas.SetTop(block, BarHeight + 4);
                    _bar.Children.Add(block);
                }
            }
        }
    }
}
