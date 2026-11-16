using FortiGateDashboard.Core.Models;
using FortiGateDashboard.Infrastructure.Psirt;
using FluentAssertions;
using Xunit;

namespace FortiGateDashboard.UnitTests.Psirt;

public class PsirtRiskClassifierTests
{
    private static string Page(string title, string summary, string component, string attackType) => $"""
        <html><body>
        <nav>Home PSIRT Advisories SSL-VPN Products Admin Portal Summary of services</nav>
        <h1>{title}</h1>
        <h2>Summary</h2><p>{summary}</p>
        <h2>Version Affected Solution</h2><table><tr><td>FortiOS 7.6</td><td>7.6.0 through 7.6.5</td></tr></table>
        <table>
          <tr><td>IR Number</td><td>FG-IR-00-000</td></tr>
          <tr><td>Component</td><td>{component}</td></tr>
          <tr><td>Severity</td><td>Critical</td></tr>
          <tr><td>Attack Type</td><td>{attackType}</td></tr>
          <tr><td>Known Exploited</td><td>Yes</td></tr>
        </table>
        </body></html>
        """;

    [Fact]
    public void FortiCloudSsoAdminBypass_IsLow_BecauseManagementIsNotExposed()
    {
        var page = Page(
            "Administrative FortiCloud SSO authentication bypass",
            "An Authentication Bypass Using an Alternate Path or Channel vulnerability [CWE-288] in FortiOS, FortiProxy and FortiWeb may allow an attacker with a FortiCloud account and a registered device to log into other devices registered to other accounts, if FortiCloud SSO authentication is enabled on those devices.",
            "GUI",
            "Unauthenticated");

        var (risk, reason) = PsirtRiskClassifier.Classify("Administrative FortiCloud SSO authentication bypass", null, page);

        risk.Should().Be(PsirtRiskLevel.Low);
        reason.Should().Contain("management");
    }

    [Fact]
    public void UnauthenticatedSslVpn_IsHigh()
    {
        var page = Page(
            "Heap overflow in sslvpnd",
            "A heap-based buffer overflow vulnerability in FortiOS SSL-VPN may allow a remote unauthenticated attacker to execute arbitrary code via specifically crafted requests.",
            "SSL-VPN",
            "Unauthenticated");

        var (risk, _) = PsirtRiskClassifier.Classify("Heap overflow in sslvpnd", null, page);

        risk.Should().Be(PsirtRiskLevel.High);
    }

    [Fact]
    public void AuthenticatedIpsec_IsMedium()
    {
        var page = Page(
            "IPsec VPN out-of-bounds read",
            "An out-of-bounds read in FortiOS IPsec VPN may allow an authenticated VPN user to crash the IKE daemon.",
            "IPsec VPN",
            "Authenticated");

        var (risk, _) = PsirtRiskClassifier.Classify("IPsec VPN out-of-bounds read", null, page);

        risk.Should().Be(PsirtRiskLevel.Medium);
    }

    [Fact]
    public void AuthenticatedCliCommandInjection_IsLow()
    {
        var page = Page(
            "OS command injection in CLI",
            "An improper neutralization of special elements in FortiOS may allow a privileged authenticated attacker to execute unauthorized code via crafted CLI commands.",
            "CLI",
            "Authenticated");

        var (risk, _) = PsirtRiskClassifier.Classify("OS command injection in CLI", null, page);

        risk.Should().Be(PsirtRiskLevel.Low);
    }

    [Fact]
    public void UnclearAdvisory_DefaultsToMedium_AndIgnoresNavigationText()
    {
        var page = Page(
            "Improper certificate validation",
            "An improper certificate validation vulnerability in FortiOS may allow an attacker in a man-in-the-middle position to intercept traffic.",
            "Other",
            "Unauthenticated");

        var (risk, reason) = PsirtRiskClassifier.Classify("Improper certificate validation", null, page);

        risk.Should().Be(PsirtRiskLevel.Medium);
        reason.Should().Contain("review manually");
    }

    [Fact]
    public void WithoutAdvisoryPage_FallsBackToRssSummary()
    {
        var (risk, _) = PsirtRiskClassifier.Classify(
            "Format string bug in fgfmd",
            "A use of externally-controlled format string in FortiOS fgfmd daemon may allow a remote unauthenticated attacker to execute arbitrary code via specially crafted requests.",
            null);

        risk.Should().Be(PsirtRiskLevel.Low);
    }
}
