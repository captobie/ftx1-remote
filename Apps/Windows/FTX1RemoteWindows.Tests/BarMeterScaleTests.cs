using FTX1RemoteWindows.Models;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// The Digital S-meter style's scale and text, checked against the values
/// BarSMeterView.swift's BarMeter and helpers give.
public class BarMeterScaleTests
{
    [Theory]
    [InlineData(-54, 0.0)]
    [InlineData(-27, 0.3)]
    [InlineData(0, 0.6)]
    [InlineData(30, 0.8)]
    [InlineData(60, 1.0)]
    [InlineData(90, 1.0)]
    [InlineData(-90, 0.0)]
    public void StrengthFraction(double db, double expected) =>
        Assert.Equal(expected, BarMeterScale.ForStrengthDb(db), 6);

    [Fact]
    public void NoReadingRests() => Assert.Equal(0, BarMeterScale.ForStrengthDb(null));

    [Theory]
    [InlineData(0.10, 0.0)]
    [InlineData(0.49, 0.5)]
    [InlineData(0.88, 1.0)]
    [InlineData(0.0, 0.0)]
    [InlineData(1.0, 1.0)]
    public void FaceFraction(double face, double expected) =>
        Assert.Equal(expected, BarMeterScale.FromFace(face), 6);

    [Theory]
    [InlineData(null, "—")]
    [InlineData(-54.0, "S0")]
    [InlineData(-12.0, "S7")]
    [InlineData(0.0, "S9")]
    [InlineData(0.4, "S9")]
    [InlineData(12.0, "S9+12")]
    [InlineData(-90.0, "S0")]
    public void SUnits(double? db, string expected) =>
        Assert.Equal(expected, BarMeterScale.SUnitText(db));

    [Fact]
    public void TxReadouts()
    {
        var r = new MeterReadings(10.4, 1.46, new TxMeterReadings(Comp: 128, Alc: null, Idd: 255, Vdd: 0));
        Assert.Equal("10 W", BarMeterScale.TxReadout(MeterSelection.Po, r));
        Assert.Equal("1.5", BarMeterScale.TxReadout(MeterSelection.Swr, r));
        Assert.Equal("50%", BarMeterScale.TxReadout(MeterSelection.Comp, r));
        Assert.Equal("—", BarMeterScale.TxReadout(MeterSelection.Alc, r));
        Assert.Equal("100%", BarMeterScale.TxReadout(MeterSelection.Id, r));
        Assert.Equal("0%", BarMeterScale.TxReadout(MeterSelection.Vdd, r));
        Assert.Equal("—", BarMeterScale.TxReadout(MeterSelection.Po, new MeterReadings(null, null, null)));
    }

    [Fact]
    public void TicksFollowTheSScale()
    {
        Assert.Equal(7, BarMeterScale.STicks.Length);
        Assert.Equal(0.6, BarMeterScale.STicks[4].Fraction, 6);
        Assert.Equal(1.0, BarMeterScale.STicks[^1].Fraction, 6);
    }
}
