using System.Net;
using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace FortiGateDashboard.Api.Auth;

public sealed class DeveloperAuthHandler : AuthenticationHandler<AuthenticationSchemeOptions>
{
    public const string SchemeName = "LocalDeveloper";

    public DeveloperAuthHandler(
        IOptionsMonitor<AuthenticationSchemeOptions> options,
        ILoggerFactory logger,
        UrlEncoder encoder)
        : base(options, logger, encoder)
    {
    }

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (Context.Connection.RemoteIpAddress is not { } remoteAddress || !IPAddress.IsLoopback(remoteAddress))
        {
            return Task.FromResult(AuthenticateResult.Fail("Developer authentication is restricted to loopback clients."));
        }

        var claims = new[]
        {
            new Claim(ClaimTypes.NameIdentifier, "local-developer"),
            new Claim("oid", "local-developer"),
            new Claim(ClaimTypes.Name, "Local developer"),
            new Claim(ClaimTypes.Role, "Viewer")
        };
        var identity = new ClaimsIdentity(claims, SchemeName);
        var principal = new ClaimsPrincipal(identity);
        var ticket = new AuthenticationTicket(principal, SchemeName);

        return Task.FromResult(AuthenticateResult.Success(ticket));
    }
}