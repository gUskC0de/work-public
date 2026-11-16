using Microsoft.Extensions.Configuration;

namespace FortiGateDashboard.Api.Auth;

public static class DeveloperAuthMode
{
    public static bool IsEnabled(string environmentName, IConfiguration configuration) =>
        string.Equals(environmentName, "Development", StringComparison.OrdinalIgnoreCase)
        && configuration.GetValue<bool>("Authentication:DeveloperModeEnabled");
}