namespace FortiGateDashboard.Core.Entities;

public enum UserRole
{
    Viewer = 0,
    Operator = 1,
    Admin = 2
}

/// <summary>Local shadow record of an Entra ID user, used for role assignment/authorization.</summary>
public class ApplicationUser
{
    public Guid Id { get; set; }

    /// <summary>Entra ID object id (oid claim).</summary>
    public string EntraObjectId { get; set; } = default!;

    public string Email { get; set; } = default!;

    public string DisplayName { get; set; } = default!;

    public UserRole Role { get; set; } = UserRole.Viewer;

    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;

    public DateTimeOffset? LastLoginAt { get; set; }
}
