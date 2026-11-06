using FortiGateDashboard.Core.Models;
using FortiGateDashboard.Core.Options;
using FortiGateDashboard.Infrastructure.Psirt;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using FluentAssertions;

namespace FortiGateDashboard.UnitTests.Psirt;

public class PsirtVersionMatchingTests
{
    private readonly PsirtService _sut = new(
        httpClient: new HttpClient(),
        options: Options.Create(new PsirtOptions()),
        logger: NullLogger<PsirtService>.Instance);

    [Theory]
    [InlineData("7.2.10", "7.6.0 through 7.6.5, 7.4.0 through 7.4.10, 7.2.0 through 7.2.12, 7.0.0 through 7.0.18", PsirtParseStatus.Parsed, FirmwareAffectedStatus.Affected)]
    [InlineData("7.4.11", "7.6.0 through 7.6.5, 7.4.0 through 7.4.10, 7.2.0 through 7.2.12, 7.0.0 through 7.0.18", PsirtParseStatus.Parsed, FirmwareAffectedStatus.NotAffected)]
    [InlineData("7.6.6", "7.6.0 through 7.6.5, 7.4.0 through 7.4.10, 7.2.0 through 7.2.12, 7.0.0 through 7.0.18", PsirtParseStatus.Parsed, FirmwareAffectedStatus.NotAffected)]
    [InlineData("7.4.8", "7.6.0 through 7.6.3, 7.4.0 through 7.4.8, 7.2.0 through 7.2.11, 7.0.0 through 7.0.17", PsirtParseStatus.Parsed, FirmwareAffectedStatus.Affected)]
    [InlineData("7.4.9", "7.6.0 through 7.6.3, 7.4.0 through 7.4.8, 7.2.0 through 7.2.11, 7.0.0 through 7.0.17", PsirtParseStatus.Parsed, FirmwareAffectedStatus.NotAffected)]
    public void EvaluateAffectedStatus_WithCommaSeparatedRanges_ReturnsCorrectStatus(
        string firmware, 
        string affectedVersionRange, 
        PsirtParseStatus parseStatus,
        FirmwareAffectedStatus expected)
    {
        var result = _sut.EvaluateAffectedStatus(firmware, affectedVersionRange, parseStatus);
        result.Should().Be(expected);
    }
}
