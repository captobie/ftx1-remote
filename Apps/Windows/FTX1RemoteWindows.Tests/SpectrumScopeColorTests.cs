using FTX1RemoteWindows.Models;
using Xunit;

namespace FTX1RemoteWindows.Tests;

/// "SS"'s COLOR sub-function, the same cases as SpectrumScopeColorTests.swift.
public class SpectrumScopeColorTests
{
    [Theory]
    [InlineData(0, "SS0300000")]
    [InlineData(4, "SS0340000")]
    [InlineData(9, "SS0390000")]
    [InlineData(10, "SS03A0000")]
    public void SetCommand(int index, string expected) =>
        Assert.Equal(expected, SpectrumScopeColor.SetCommand(index));

    [Theory]
    [InlineData(-1)]
    [InlineData(11)]
    public void OutOfRangeSendsNothing(int index) => Assert.Null(SpectrumScopeColor.SetCommand(index));

    [Theory]
    [InlineData("SS0300000;", 0)]
    [InlineData("SS0390000;", 9)]
    [InlineData("SS03A0000;", 10)]
    [InlineData("SS03a0000;", 10)]
    public void ParsesAnswers(string reply, int expected) =>
        Assert.Equal(expected, SpectrumScopeColor.IndexFromAnswer(reply));

    [Theory]
    [InlineData("SS03B0000;")]
    [InlineData("?;")]
    [InlineData("SS0100000;")]
    [InlineData("SS03")]
    public void RejectsOtherAnswers(string reply) => Assert.Null(SpectrumScopeColor.IndexFromAnswer(reply));

    [Fact]
    public void Labels()
    {
        Assert.Equal("COLOR-1", SpectrumScopeColor.Label(0));
        Assert.Equal("COLOR-11", SpectrumScopeColor.Label(10));
        Assert.Equal("—", SpectrumScopeColor.Label(null));
        Assert.Equal("—", SpectrumScopeColor.Label(11));
    }
}
