using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace FortiGateDashboard.Api.Auth;

/// <summary>
/// Test-only authentication scheme used exclusively when <c>ASPNETCORE_ENVIRONMENT=Testing</c>.
/// Lets integration tests simulate different authenticated users/roles (needed to prove
/// per-user rate-limit partitioning and role-based authorization) without minting real Entra ID
/// JWTs. Never registered in Development or Production (see Program.cs).
/// </summary>
public class TestAuthHandler : AuthenticationHandler<AuthenticationSchemeOptions>
{
    public const string SchemeName = "Test";
    public const string UserHeaderName = "X-Test-User";
    public const string RolesHeaderName = "X-Test-Roles";

    public TestAuthHandler(IOptionsMonitor<AuthenticationSchemeOptions> options, ILoggerFactory logger, UrlEncoder encoder)
        : base(options, logger, encoder)
    {
    }

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        if (!Request.Headers.TryGetValue(UserHeaderName, out var userId) || string.IsNullOrWhiteSpace(userId))
        {
            // No test identity supplied: behave exactly like an unauthenticated request.
            return Task.FromResult(AuthenticateResult.NoResult());
        }

        var claims = new List<Claim>
        {
            new(ClaimTypes.NameIdentifier, userId!),
            new("oid", userId!)
        };

        if (Request.Headers.TryGetValue(RolesHeaderName, out var roles))
        {
            claims.AddRange(roles.ToString().Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(role => new Claim(ClaimTypes.Role, role)));
        }

        var identity = new ClaimsIdentity(claims, SchemeName);
        var principal = new ClaimsPrincipal(identity);
        var ticket = new AuthenticationTicket(principal, SchemeName);

        return Task.FromResult(AuthenticateResult.Success(ticket));
    }
}
