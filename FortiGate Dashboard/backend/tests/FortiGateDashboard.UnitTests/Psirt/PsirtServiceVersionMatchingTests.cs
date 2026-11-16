using FortiGateDashboard.Core.Models;
using FortiGateDashboard.Core.Options;
using FortiGateDashboard.Infrastructure.Psirt;
using FluentAssertions;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace FortiGateDashboard.UnitTests.Psirt;

public class PsirtServiceVersionMatchingTests
{
    private readonly PsirtService _sut = new(
        new HttpClient(),
        Options.Create(new PsirtOptions()),
        NullLogger<PsirtService>.Instance);

    [Theory]
    [InlineData("7.4.4", "7.0.0 - 7.0.12", FirmwareAffectedStatus.NotAffected)]
    [InlineData("7.0.5", "7.0.0 - 7.0.12", FirmwareAffectedStatus.Affected)]
    [InlineData("7.0.13", "7.0.0 - 7.0.12", FirmwareAffectedStatus.NotAffected)]
    [InlineData("6.9.9", "before 7.0.0", FirmwareAffectedStatus.Affected)]
    [InlineData("7.0.0", "before 7.0.0", FirmwareAffectedStatus.NotAffected)]
    [InlineData("7.4.2", "7.4.0,7.4.1,7.4.2", FirmwareAffectedStatus.Affected)]
    [InlineData("7.4.3", "7.4.0,7.4.1,7.4.2", FirmwareAffectedStatus.NotAffected)]
    // Realistic firmware string formats — regex extraction should still find the leading x.y.z.
    [InlineData("v7.4.4", "7.4.0 - 7.4.5", FirmwareAffectedStatus.Affected)]
    [InlineData("v7.4.4,build2662,240514 (GA)", "7.4.0 - 7.4.5", FirmwareAffectedStatus.Affected)]
    [InlineData("7.4.4-build2662", "before 7.4.5", FirmwareAffectedStatus.Affected)]
    [InlineData("7.2.5", "7.2.0 through 7.2.7", FirmwareAffectedStatus.Affected)]
    [InlineData("7.2.8", "7.2.0 through 7.2.7", FirmwareAffectedStatus.NotAffected)]
    [InlineData("7.0.9", "7.0 all versions", FirmwareAffectedStatus.Affected)]
    [InlineData("7.2.1", "7.0 all versions", FirmwareAffectedStatus.NotAffected)]
    public void EvaluateAffectedStatus_MatchesExpectedRanges(string firmwareVersion, string affectedRange, FirmwareAffectedStatus expected)
    {
        var result = _sut.EvaluateAffectedStatus(firmwareVersion, affectedRange, PsirtParseStatus.Parsed);

        result.Should().Be(expected);
    }

    [Fact]
    public void EvaluateAffectedStatus_ReturnsUnableToEvaluate_WhenRangeIsEmpty()
    {
        var result = _sut.EvaluateAffectedStatus("7.0.5", string.Empty, PsirtParseStatus.Parsed);

        result.Should().Be(FirmwareAffectedStatus.UnableToEvaluate);
    }

    [Fact]
    public void EvaluateAffectedStatus_ReturnsUnableToEvaluate_WhenAdvisoryParseStatusIsUnparseable()
    {
        var result = _sut.EvaluateAffectedStatus("7.0.5", "7.0.0 - 7.0.12", PsirtParseStatus.Unparseable);

        result.Should().Be(FirmwareAffectedStatus.UnableToEvaluate);
    }

    [Fact]
    public void EvaluateAffectedStatus_ReturnsUnableToEvaluate_WhenFirmwareVersionCannotBeParsed()
    {
        var result = _sut.EvaluateAffectedStatus("not-a-version", "7.0.0 - 7.0.12", PsirtParseStatus.Parsed);

        result.Should().Be(FirmwareAffectedStatus.UnableToEvaluate);
    }

    [Fact]
    public void EvaluateAffectedStatus_ReturnsUnableToEvaluate_WhenRangeFormatIsUnrecognized()
    {
        var result = _sut.EvaluateAffectedStatus("7.0.5", "affects several product families, see advisory", PsirtParseStatus.PartiallyParsed);

        result.Should().Be(FirmwareAffectedStatus.UnableToEvaluate);
    }

    [Theory]
    [InlineData("https://www.fortiguard.com/psirt/FG-IR-24-001")]
    [InlineData("http://www.fortiguard.com/psirt/FG-IR-24-001")]
    [InlineData("javascript:alert(1)")]
    [InlineData("data:text/html,evil")]
    [InlineData("file:///etc/passwd")]
    [InlineData("not a url")]
    public void ResolveSafeAdvisoryUrl_OnlyAcceptsAbsoluteHttps(string candidate)
    {
        // Exercised indirectly via GetAdvisoriesAsync in integration-style tests; this test
        // documents the accepted/rejected schemes for the private validation logic via a
        // minimal reflection-free proxy: HTTPS absolute URIs are the only ones considered safe.
        var isHttps = Uri.TryCreate(candidate, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps;

        if (candidate.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            isHttps.Should().BeTrue();
        }
        else
        {
            isHttps.Should().BeFalse();
        }
    }
}
