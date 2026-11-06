using FortiGateDashboard.Core.Entities;
using Microsoft.EntityFrameworkCore;

namespace FortiGateDashboard.Infrastructure.Data;

public class FortiGateDashboardDbContext : DbContext
{
    public FortiGateDashboardDbContext(DbContextOptions<FortiGateDashboardDbContext> options)
        : base(options)
    {
    }

    public DbSet<Device> Devices => Set<Device>();

    public DbSet<Subscription> Subscriptions => Set<Subscription>();

    public DbSet<PsirtAdvisory> PsirtAdvisories => Set<PsirtAdvisory>();

    public DbSet<Cve> Cves => Set<Cve>();

    public DbSet<FirmwareVersion> FirmwareVersions => Set<FirmwareVersion>();

    public DbSet<DevicePsirt> DevicePsirts => Set<DevicePsirt>();

    public DbSet<SyncHistory> SyncHistories => Set<SyncHistory>();

    public DbSet<ApplicationUser> Users => Set<ApplicationUser>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Device>(entity =>
        {
            entity.HasIndex(d => d.SerialNumber).IsUnique();
            entity.Property(d => d.SerialNumber).HasMaxLength(64);
            entity.Property(d => d.Name).HasMaxLength(256);
            entity.Property(d => d.Model).HasMaxLength(64);
            entity.Property(d => d.FirmwareVersion).HasMaxLength(32);
            entity.Property(d => d.AccountId).HasMaxLength(128);
            entity.Property(d => d.IpAddress).HasMaxLength(64);
        });

        modelBuilder.Entity<Subscription>(entity =>
        {
            entity.HasOne(s => s.Device)
                .WithMany(d => d.Subscriptions)
                .HasForeignKey(s => s.DeviceId)
                .OnDelete(DeleteBehavior.Cascade);
            entity.HasIndex(s => new { s.DeviceId, s.SubscriptionType });
        });

        modelBuilder.Entity<PsirtAdvisory>(entity =>
        {
            entity.HasIndex(p => p.PsirtId).IsUnique();
        });

        modelBuilder.Entity<Cve>(entity =>
        {
            entity.HasIndex(c => c.CveId).IsUnique();
            entity.HasOne(c => c.PsirtAdvisory)
                .WithMany(p => p.Cves)
                .HasForeignKey(c => c.PsirtAdvisoryId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<FirmwareVersion>(entity =>
        {
            entity.HasIndex(f => f.Version).IsUnique();
        });

        modelBuilder.Entity<DevicePsirt>(entity =>
        {
            entity.HasOne(dp => dp.Device)
                .WithMany(d => d.DevicePsirts)
                .HasForeignKey(dp => dp.DeviceId)
                .OnDelete(DeleteBehavior.Cascade);

            entity.HasOne(dp => dp.PsirtAdvisory)
                .WithMany(p => p.DevicePsirts)
                .HasForeignKey(dp => dp.PsirtAdvisoryId)
                .OnDelete(DeleteBehavior.Cascade);

            entity.HasIndex(dp => new { dp.DeviceId, dp.PsirtAdvisoryId }).IsUnique();
        });

        modelBuilder.Entity<ApplicationUser>(entity =>
        {
            entity.HasIndex(u => u.EntraObjectId).IsUnique();
            entity.HasIndex(u => u.Email).IsUnique();
        });
    }
}
