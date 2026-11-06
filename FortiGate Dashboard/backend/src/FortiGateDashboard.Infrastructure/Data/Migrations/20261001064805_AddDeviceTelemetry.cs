using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FortiGateDashboard.Infrastructure.Data.Migrations
{
    /// <inheritdoc />
    public partial class AddDeviceTelemetry : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "IpAddress",
                table: "Devices",
                type: "character varying(64)",
                maxLength: 64,
                nullable: true);

            migrationBuilder.AddColumn<bool>(
                name: "TunnelAlive",
                table: "Devices",
                type: "boolean",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "IpAddress",
                table: "Devices");

            migrationBuilder.DropColumn(
                name: "TunnelAlive",
                table: "Devices");
        }
    }
}
