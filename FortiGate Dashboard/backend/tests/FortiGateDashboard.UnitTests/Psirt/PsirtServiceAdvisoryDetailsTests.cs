using System.Net;
using System.Text;
using FortiGateDashboard.Core.Options;
using FortiGateDashboard.Infrastructure.Psirt;
using FluentAssertions;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace FortiGateDashboard.UnitTests.Psirt;

public class PsirtServiceAdvisoryDetailsTests
{
    [Fact]
    public async Task GetAdvisoriesAsync_UsesFortinetAdvisoryFieldsForIdSeverityAndCvss()
    {
        const string feedUrl = "https://example.test/ir.xml";
        const string feed = """
            <rss version="2.0"><channel><title>PSIRT</title><item>
            <title>Advisory title without an IR number</title>
            <link>https://fortiguard.fortinet.com/psirt/FG-IR-26-165</link>
            <description><![CDATA[<p><strong>CVSSv3 Score:</strong> 4.7</p>]]></description>
            <guid>https://fortiguard.fortinet.com/psirt/FG-IR-26-165</guid>
            <pubDate>Tue, 08 Sep 2026 00:00:00 +0000</pubDate>
            </item></channel></rss>
            """;
        const string advisoryPage = """
            <table><tr><td>IR Number</td><td>FG-IR-26-165</td></tr>
            <tr><td>Severity</td><td>High</td></tr>
            <tr><td>CVSSv3 Score</td><td>8.8</td></tr></table>
            """;

        var handler = new StubHttpMessageHandler(feed, advisoryPage);
        var sut = new PsirtService(
            new HttpClient(handler),
            Options.Create(new PsirtOptions { FeedUrl = feedUrl }),
            NullLogger<PsirtService>.Instance);

        var advisory = (await sut.GetAdvisoriesAsync()).Should().ContainSingle().Subject;

        advisory.PsirtId.Should().Be("FG-IR-26-165");
        advisory.Severity.Should().Be("High");
        advisory.CvssScore.Should().Be(8.8);
    }

    private sealed class StubHttpMessageHandler(string feed, string advisoryPage) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var content = request.RequestUri?.AbsolutePath.EndsWith("ir.xml", StringComparison.OrdinalIgnoreCase) == true
                ? feed
                : advisoryPage;

            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(content, Encoding.UTF8, "application/xml")
            });
        }
    }
}