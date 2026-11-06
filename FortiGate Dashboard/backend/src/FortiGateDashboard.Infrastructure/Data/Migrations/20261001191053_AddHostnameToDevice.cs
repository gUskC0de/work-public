using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace FortiGateDashboard.Infrastructure.Data.Migrations
{
    /// <inheritdoc />
    public partial class AddHostnameToDevice : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "Hostname",
                table: "Devices",
                type: "text",
                nullable: true);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "Hostname",
                table: "Devices");
        }
    }
}
