using System.Net;
using System.Threading.RateLimiting;
using FortiGateDashboard.Api.Auth;
using FortiGateDashboard.Core.Options;
using FortiGateDashboard.Infrastructure;
using FortiGateDashboard.Infrastructure.Data;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;
using Microsoft.Identity.Web;
using Serilog;

var builder = WebApplication.CreateBuilder(args);

builder.Host.UseSerilog((context, services, loggerConfig) => loggerConfig
    .ReadFrom.Configuration(context.Configuration)
    .Enrich.FromLogContext()
    .Enrich.WithMachineName()
    .WriteTo.Console()
    .WriteTo.File("logs/fortigate-dashboard-.log", rollingInterval: RollingInterval.Day));

var isTesting = builder.Environment.IsEnvironment("Testing");
var developerAuthEnabled = DeveloperAuthMode.IsEnabled(builder.Environment.EnvironmentName, builder.Configuration);

if (isTesting)
{
    // Test-only scheme so integration tests can simulate distinct authenticated users/roles
    // (needed for rate-limit partitioning and RBAC tests) without minting real Entra ID JWTs.
    builder.Services.AddAuthentication(TestAuthHandler.SchemeName)
        .AddScheme<Microsoft.AspNetCore.Authentication.AuthenticationSchemeOptions, TestAuthHandler>(TestAuthHandler.SchemeName, _ => { });
}
else if (developerAuthEnabled)
{
    builder.Services.AddAuthentication(DeveloperAuthHandler.SchemeName)
        .AddScheme<Microsoft.AspNetCore.Authentication.AuthenticationSchemeOptions, DeveloperAuthHandler>(DeveloperAuthHandler.SchemeName, _ => { });
}
else
{
    // Entra ID (Azure AD) authentication for interactive users and API-to-API calls.
    builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
        .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"));

    // Metadata (OIDC discovery, JWKS) must be fetched over HTTPS outside local development.
    builder.Services.Configure<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme, options =>
    {
        options.RequireHttpsMetadata = !builder.Environment.IsDevelopment();

        var tenantId = builder.Configuration["AzureAd:TenantId"];
        if (!string.IsNullOrWhiteSpace(tenantId))
        {
            options.TokenValidationParameters.ValidIssuers =
            [
                $"https://login.microsoftonline.com/{tenantId}/v2.0",
                $"https://sts.windows.net/{tenantId}/"
            ];
        }
    });
}

builder.Services.AddAuthorization(options =>
{
    options.AddPolicy("AdminOnly", policy => policy.RequireRole("Admin"));
});

builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(options =>
{
    options.SwaggerDoc("v1", new Microsoft.OpenApi.OpenApiInfo
    {
        Title = "FortiGate Cloud Asset Dashboard API",
        Version = "v1",
        Description = "Centralized inventory, subscription and PSIRT dashboard for MSP-managed FortiGate estates."
    });

    options.AddSecurityDefinition("Bearer", new Microsoft.OpenApi.OpenApiSecurityScheme
    {
        Type = Microsoft.OpenApi.SecuritySchemeType.Http,
        Scheme = "bearer",
        BearerFormat = "JWT",
        In = Microsoft.OpenApi.ParameterLocation.Header
    });
});

builder.Services.AddCors(options =>
{
    options.AddPolicy("Frontend", policy => policy
        .WithOrigins(builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? Array.Empty<string>())
        .AllowAnyHeader()
        .AllowAnyMethod());
});

var useInMemoryDatabase = isTesting || (developerAuthEnabled && builder.Configuration.GetValue<bool>("TestHost:UseInMemoryDatabase"));
builder.Services.AddFortiGateDashboardInfrastructure(builder.Configuration, useInMemoryDatabase: useInMemoryDatabase);

var healthChecks = builder.Services.AddHealthChecks();
if (useInMemoryDatabase)
{
    healthChecks.AddCheck("developer-in-memory-database", () =>
        Microsoft.Extensions.Diagnostics.HealthChecks.HealthCheckResult.Healthy("Developer mode uses the in-memory database."));
}
else
{
    healthChecks.AddNpgSql(builder.Configuration.GetConnectionString("Default")!);
}

// Forwarded-headers: disabled (nothing trusted) unless an operator explicitly lists their
// reverse proxy's IP/network, matching the real deployment topology. See README for guidance.
//
// IMPORTANT: this MUST be configured via the DI-resolved options pattern (IConfigureOptions),
// not by eagerly reading builder.Configuration into a local variable here. WebApplicationFactory
// (used by integration tests) only finishes merging ConfigureAppConfiguration overrides into the
// live configuration by the time the host is actually built/started — code that runs BEFORE
// builder.Build() and eagerly materializes a POCO from builder.Configuration will silently see
// the pre-override (checked-in appsettings.json) values instead. Options resolved lazily via
// IOptions<T>/IConfigureOptions<T> at DI-resolution time (which happens after Build()) see the
// fully-merged configuration, including test overrides.
builder.Services.AddOptions<ForwardedHeadersSettings>()
    .Bind(builder.Configuration.GetSection(ForwardedHeadersSettings.SectionName));

builder.Services.AddOptions<ForwardedHeadersOptions>()
    .Configure<Microsoft.Extensions.Options.IOptions<ForwardedHeadersSettings>>((options, settingsOptions) =>
    {
        var settings = settingsOptions.Value;
        if (!settings.Enabled)
        {
            options.ForwardedHeaders = Microsoft.AspNetCore.HttpOverrides.ForwardedHeaders.None;
            return;
        }

        options.ForwardedHeaders = Microsoft.AspNetCore.HttpOverrides.ForwardedHeaders.XForwardedFor | Microsoft.AspNetCore.HttpOverrides.ForwardedHeaders.XForwardedProto;
        options.KnownProxies.Clear();
        options.KnownNetworks.Clear();

        foreach (var proxy in settings.KnownProxies)
        {
            if (IPAddress.TryParse(proxy, out var address))
            {
                options.KnownProxies.Add(address);
            }
        }

        foreach (var network in settings.KnownNetworks)
        {
            var parts = network.Split('/');
            if (parts.Length == 2 && IPAddress.TryParse(parts[0], out var networkAddress) && int.TryParse(parts[1], out var prefixLength))
            {
                options.KnownNetworks.Add(new Microsoft.AspNetCore.HttpOverrides.IPNetwork(networkAddress, prefixLength));
            }
        }
    });

// Rate limiting: partitioned by the verified Entra ID object identifier claim ("oid") where
// available, falling back to remote IP for requests without one. Client-supplied
// X-Forwarded-For is only honored if ForwardedHeaders is explicitly enabled/configured above.
builder.Services.AddOptions<RateLimitingOptions>()
    .Bind(builder.Configuration.GetSection(RateLimitingOptions.SectionName))
    .Validate(o => o.General.PermitLimit > 0 && o.General.WindowSeconds > 0, "RateLimiting:General must have PermitLimit > 0 and WindowSeconds > 0")
    .Validate(o => o.Sync.PermitLimit > 0 && o.Sync.WindowSeconds > 0, "RateLimiting:Sync must have PermitLimit > 0 and WindowSeconds > 0")
    .Validate(o => o.Export.PermitLimit > 0 && o.Export.WindowSeconds > 0, "RateLimiting:Export must have PermitLimit > 0 and WindowSeconds > 0")
    .ValidateOnStart();

static string ResolvePartitionKey(HttpContext context)
{
    var oid = context.User.FindFirst("oid")?.Value
        ?? context.User.FindFirst(System.Security.Claims.ClaimTypes.NameIdentifier)?.Value;

    if (!string.IsNullOrEmpty(oid))
    {
        return $"user:{oid}";
    }

    // No verified identity — partition by remote IP (only meaningful if ForwardedHeaders is
    // correctly configured for the real proxy topology; otherwise this is the proxy's own IP).
    return $"ip:{context.Connection.RemoteIpAddress}";
}

static RateLimitPartition<string> CreatePartition(HttpContext context, RateLimitPolicyOptions policy)
{
    var key = ResolvePartitionKey(context);
    return RateLimitPartition.GetFixedWindowLimiter(key, _ => new FixedWindowRateLimiterOptions
    {
        PermitLimit = policy.PermitLimit,
        Window = TimeSpan.FromSeconds(policy.WindowSeconds),
        QueueLimit = policy.QueueLimit,
        QueueProcessingOrder = QueueProcessingOrder.OldestFirst
    });
}

builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;

    options.OnRejected = async (context, cancellationToken) =>
    {
        if (context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter))
        {
            context.HttpContext.Response.Headers.RetryAfter = ((int)retryAfter.TotalSeconds).ToString();
        }

        // Log the partition key (a user oid or IP — not a credential) and route, never the
        // Authorization header or any token value.
        var logger = context.HttpContext.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("RateLimiting");
        logger.LogWarning(
            "Rate limit exceeded for {PartitionKey} on {Path}",
            ResolvePartitionKey(context.HttpContext), context.HttpContext.Request.Path);

        await context.HttpContext.Response.WriteAsync("Rate limit exceeded. Please retry later.", cancellationToken);
    };

    // Each policy resolves RateLimitingOptions fresh, per request, from the request's own
    // DI container (well after Build()) — never from a value captured at builder-configuration
    // time, which is the mistake that previously made test configuration overrides ineffective.
    options.AddPolicy("general", httpContext =>
        CreatePartition(httpContext, httpContext.RequestServices.GetRequiredService<Microsoft.Extensions.Options.IOptions<RateLimitingOptions>>().Value.General));
    options.AddPolicy("sync", httpContext =>
        CreatePartition(httpContext, httpContext.RequestServices.GetRequiredService<Microsoft.Extensions.Options.IOptions<RateLimitingOptions>>().Value.Sync));
    options.AddPolicy("export", httpContext =>
        CreatePartition(httpContext, httpContext.RequestServices.GetRequiredService<Microsoft.Extensions.Options.IOptions<RateLimitingOptions>>().Value.Export));
});

var app = builder.Build();

if (developerAuthEnabled)
{
    app.Logger.LogWarning("LOCAL DEVELOPER AUTHENTICATION IS ENABLED. Only loopback callers are accepted; do not use this mode outside local development.");
}

// Always registered (harmless no-op when ForwardedHeadersSettings.Enabled is false, since the
// options callback above sets ForwardedHeaders.None in that case) so the behavior is driven
// entirely by configuration/DI, not by an eager pre-Build() branch.
app.UseForwardedHeaders();

if (app.Environment.IsDevelopment() || isTesting)
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

if (!app.Environment.IsDevelopment())
{
    // TLS itself must terminate at an approved reverse proxy / ingress / load balancer — see
    // README "Transport & TLS" section. HSTS only tells browsers to prefer HTTPS on repeat visits.
    app.UseHsts();
}

app.UseSerilogRequestLogging();
app.UseHttpsRedirection();
app.UseCors("Frontend");
app.UseAuthentication();
app.UseAuthorization();
app.UseRateLimiter();

app.MapControllers();
app.MapHealthChecks("/health").DisableRateLimiting();

using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<FortiGateDashboardDbContext>();
    if (db.Database.IsRelational())
    {
        await db.Database.MigrateAsync();
    }
}

app.Run();

public partial class Program
{
}
