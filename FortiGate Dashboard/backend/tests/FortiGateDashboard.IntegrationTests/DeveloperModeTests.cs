using System.Net;
using System.Security.Claims;
using System.Text.Encodings.Web;
using FortiGateDashboard.Api.Auth;
using FluentAssertions;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace FortiGateDashboard.IntegrationTests;

public class DeveloperModeTests
{
    [Theory]
    [InlineData("Production", true, false)]
    [InlineData("Testing", true, false)]
    [InlineData("Staging", true, false)]
    [InlineData("Development", false, false)]
    [InlineData("Development", true, true)]
    public void DeveloperModeGate_RequiresDevelopmentAndExplicitFlag(string environment, bool enabled, bool expected)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Authentication:DeveloperModeEnabled"] = enabled.ToString()
            })
            .Build();

        DeveloperAuthMode.IsEnabled(environment, configuration).Should().Be(expected);
    }

    [Theory]
    [InlineData("127.0.0.1")]
    [InlineData("::1")]
    public async Task DeveloperAuthHandler_AuthenticatesLoopback_AsReadOnlyViewer(string address)
    {
        var result = await AuthenticateFromAsync(IPAddress.Parse(address));

        result.Succeeded.Should().BeTrue();
        result.Principal!.FindFirst(ClaimTypes.Name)?.Value.Should().Be("Local developer");
        result.Principal.IsInRole("Viewer").Should().BeTrue();
        result.Principal.IsInRole("Admin").Should().BeFalse();
        result.Principal.IsInRole("Operator").Should().BeFalse();
    }

    [Fact]
    public async Task DeveloperAuthHandler_RejectsNonLoopbackClient()
    {
        var result = await AuthenticateFromAsync(IPAddress.Parse("192.0.2.10"));

        result.Succeeded.Should().BeFalse();
        result.Failure!.Message.Should().Contain("loopback");
    }

    private static async Task<AuthenticateResult> AuthenticateFromAsync(IPAddress remoteAddress)
    {
        var services = new ServiceCollection()
            .AddLogging()
            .AddOptions()
            .BuildServiceProvider();
        var loggerFactory = services.GetRequiredService<ILoggerFactory>();
        var handler = new DeveloperAuthHandler(
            services.GetRequiredService<IOptionsMonitor<AuthenticationSchemeOptions>>(),
            loggerFactory,
            UrlEncoder.Default);
        var context = new DefaultHttpContext { RequestServices = services };
        context.Connection.RemoteIpAddress = remoteAddress;

        await handler.InitializeAsync(
            new AuthenticationScheme(DeveloperAuthHandler.SchemeName, null, typeof(DeveloperAuthHandler)),
            context);

        return await handler.AuthenticateAsync();
    }
}
