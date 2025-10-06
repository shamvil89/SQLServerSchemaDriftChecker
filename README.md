## SQL Server Schema Drift Detection

Detect, review, and report schema and metadata drift between two SQL Server databases. The script generates a single, self-contained HTML report with categorized differences and convenient “View Code” buttons.

### Features
- **Comprehensive schema drift detection** across all database objects (schemas, tables, views, stored procedures, functions, users, roles, permissions, indexes, constraints, data types, and more)
- **Advanced Query Store analysis** - Shows actual SQL query text, forced plans, and configuration differences
- **Single HTML report** (`SchemaComparisonReport.html`) with search, filters, and interactive code viewing
- **Multi-authentication support** - Windows, SQL Server, and Azure AD authentication
- **Hybrid cloud ready** - Compare on-premises to Azure SQL Database seamlessly
- **Multiple scenarios** - Configure different environments in one JSON file
- **Mixed authentication** - Different auth types for source vs target servers
- **Enhanced reporting** - Detailed object comparisons with "View Code" buttons for quick analysis
- **Graphical User Interface** - Easy-to-use Windows Forms GUI for configuration and execution
- **Secure credential handling** - Passwords are not saved to JSON files, entered at runtime

### Prerequisites
- Windows with PowerShell (Windows PowerShell 5.1 or PowerShell 7+)
- Access to the SQL Server instances for both source and target
- Permissions to read system catalogs and Query Store (if enabled)

**For Azure SQL Database with Azure AD:**
- Machine must be Azure AD joined or have Azure AD credentials cached
- User must have appropriate Azure SQL Database permissions
- PowerShell `SqlServer` module (recommended for best Azure AD support)

**For Query Store Analysis:**
- Query Store must be enabled on the databases being compared
- Permissions to read `sys.query_store_*` system views
- Query Store provides insights into forced plans and query performance

Optional:
- PowerShell `SqlServer` module for enhanced compatibility and Azure features

### Quick Start
1) (Optional) Create the example databases to try the tool:
```powershell
# From the repo root
sqlcmd -S localhost -E -i .\01_CreateSourceDatabase.sql
sqlcmd -S localhost -E -i .\02_CreateTargetDatabase.sql
```

2) Review `config.json` and configure your environment. The configuration supports multiple scenarios in one file:

**Common Scenarios:**

<details>
<summary><strong>🏠 Local Development Environment</strong></summary>

```json
{
  "name": "Local Development Environment",
  "description": "Compare local SQL Server databases using Windows Authentication",
  "sourceServer": "localhost",
  "sourceDatabase": "DevSourceDB",
  "targetServer": "localhost\\SQLEXPRESS",
  "targetDatabase": "DevTargetDB",
  "authType": "TrustedConnection"
}
```
</details>

<details>
<summary><strong>☁️ On-Premises to Cloud Migration</strong></summary>

```json
{
  "name": "On-Premises to Cloud Migration",
  "description": "Compare on-premises SQL Server to Azure SQL Database",
  "sourceServer": "prod-sql-01.company.local",
  "sourceDatabase": "ProductionDB",
  "targetServer": "company-prod.database.windows.net",
  "targetDatabase": "ProductionDB_Azure",
  "authType": "Mixed",
  "sourceAuthType": "TrustedConnection",
  "targetAuthType": "AzureAD"
}
```
</details>

<details>
<summary><strong>🔐 Cross-Environment with SQL Authentication</strong></summary>

```json
{
  "name": "Cross-Environment with SQL Auth",
  "description": "Compare staging to production using SQL Authentication",
  "sourceServer": "staging-sql.company.com",
  "sourceDatabase": "StagingDB",
  "targetServer": "prod-sql.company.com",
  "targetDatabase": "ProductionDB",
  "authType": "SqlAuth",
  "sourceUsername": "staging_reader",
  "sourcePassword": "staging_password123",
  "targetUsername": "prod_reader",
  "targetPassword": "prod_password456"
}
```
</details>

<details>
<summary><strong>☁️ Azure SQL Databases Comparison</strong></summary>

```json
{
  "name": "Azure SQL Databases Comparison",
  "description": "Compare two Azure SQL databases with Azure AD",
  "sourceServer": "company-dev.database.windows.net",
  "sourceDatabase": "DevDB",
  "targetServer": "company-prod.database.windows.net",
  "targetDatabase": "ProdDB",
  "authType": "AzureAD"
}
```
</details>

<details>
<summary><strong>🔄 Hybrid Cloud Setup</strong></summary>

```json
{
  "name": "Hybrid Cloud Setup",
  "description": "Azure SQL to on-premises with different authentication",
  "sourceServer": "company-cloud.database.windows.net",
  "sourceDatabase": "CloudDB",
  "targetServer": "onprem-sql-cluster.company.local",
  "targetDatabase": "OnPremDB",
  "authType": "Mixed",
  "sourceAuthType": "AzureAD",
  "targetAuthType": "SqlAuth",
  "targetUsername": "service_account",
  "targetPassword": "service_password789"
}
```
</details>

<details>
<summary><strong>🏢 Multi-Tenant Azure Comparison</strong></summary>

```json
{
  "name": "Multi-Tenant Azure Comparison",
  "description": "Compare databases across different Azure subscriptions",
  "sourceServer": "tenant1.database.windows.net",
  "sourceDatabase": "TenantDB",
  "targetServer": "tenant2.database.windows.net", 
  "targetDatabase": "TenantDB",
  "authType": "SqlAuth",
  "sourceUsername": "tenant1_user",
  "sourcePassword": "tenant1_pass",
  "targetUsername": "tenant2_user",
  "targetPassword": "tenant2_pass"
}
```
</details>

3) Run the drift detection script:

**Option 1: GUI Interface (Recommended)**
```powershell
# Launch the graphical interface
powershell -NoProfile -ExecutionPolicy Bypass -File .\Launch-GUI.ps1
```

**Option 2: Command Line Interface**
```powershell
# Run with default/first configuration
powershell -NoProfile -ExecutionPolicy Bypass -File .\DatabaseSchemaDriftDetection.ps1

# Run specific configuration
powershell -NoProfile -ExecutionPolicy Bypass -File .\DatabaseSchemaDriftDetection.ps1 -ConfigName "On-Premises to Cloud Migration"
```

**List available configurations:**
```powershell
# See all configured scenarios
Get-Content config.json | ConvertFrom-Json | Select-Object -ExpandProperty databaseConfigurations | Select-Object name, description
```

**Test GUI functionality:**
```powershell
# Verify GUI components and dependencies
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-GUI.ps1
```

4) Open the generated report:
- `SchemaComparisonReport.html`

### GUI Features

The graphical interface provides an intuitive way to configure and run database comparisons:

**Main Interface (modernized):**
- **Scenario Dropdown** - Select from pre-configured scenarios in `config.json`
- **Source/Target Panels** - Clean Segoe UI styling, larger layout
- **Authentication Setup** - Configure different auth types per side
- **Connection Testing**
  - Test Source / Test Target / Test Both
  - Full error details shown in a multi-line panel (no truncation)
  - Status line lists source/target failures when present
- **Smart Button States** - Run button enables when both connections are successful
- **One-Click Execution** - Run drift detection with current settings

**Authentication Dialog:**
- **Multiple Auth Types** - Windows, SQL Server, and Azure AD authentication
- **Secure Password Entry** - Passwords are masked and not saved to files
- **Per-Server Configuration** - Different authentication for source vs target

**Connection Testing:**
- **Individual Tests** - Test source or target connections separately
- **Combined Test** - Test both connections with one button click
- **Smart Validation** - Run button only enables when both connections succeed
- **Real-time Feedback** - Immediate status updates and color-coded results

**Drift Detection Execution:**
- **One-Click Run** - Execute drift detection with current configuration
- **Automatic Report Opening** - HTML report opens in default browser when complete
- **Error Handling** - Clear status messages for success or failure
- **Temporary Configuration** - Uses secure temporary config files during execution

**Security Features:**
- **No Password Storage** - SQL authentication passwords are never saved to JSON
- **Temporary Configuration** - Creates temporary config files during execution
- **Memory Cleanup** - Sensitive data is cleared from memory after use

### Configuration
`config.json` contains one or more entries under `databaseConfigurations`.

**Common Fields:**
- **name**: Friendly label shown in the report
- **description**: Optional text for context
- **sourceServer / sourceDatabase**: Source connection
- **targetServer / targetDatabase**: Target connection
- **authType**: Authentication method - `"TrustedConnection"`, `"SqlAuth"`, `"AzureAD"`, or `"Mixed"`

**For SQL Server Authentication (authType: "SqlAuth"):**
- **sourceUsername / sourcePassword**: Credentials for source database
- **targetUsername / targetPassword**: Credentials for target database

**For Azure SQL Database with Azure AD (authType: "AzureAD"):**
- No additional fields required
- Uses the current Azure AD authenticated user context
- Requires the machine to be Azure AD joined or have Azure AD credentials cached

**For Mixed Authentication (authType: "Mixed"):**
- **sourceAuthType**: Authentication method for source server (`"TrustedConnection"`, `"SqlAuth"`, or `"AzureAD"`)
- **targetAuthType**: Authentication method for target server (`"TrustedConnection"`, `"SqlAuth"`, or `"AzureAD"`)
- Include relevant username/password fields based on the auth types chosen

Note: You can use different authentication types for source and target servers, perfect for hybrid cloud scenarios or cross-environment comparisons.

## 💡 **Usage Tips**

**Multiple Configurations:**
- Define multiple scenarios in one `config.json` file
- Use `-ConfigName` parameter to select which one to run
- Perfect for different environments (Dev→Test→Prod comparisons)

**Authentication Flexibility:**
- Mix authentication types in one comparison (e.g., on-premises Windows Auth + Azure AD)
- Use service accounts for automated comparisons
- Support for hybrid cloud architectures

**Best Practices:**
- Test connections before running full comparisons
- Use read-only accounts when possible
- Store sensitive configs securely (consider Azure Key Vault for production)
- Run comparisons during maintenance windows for large databases

### Outputs
- `SchemaComparisonReport.html`: Interactive, categorized drift report
- **Query Store Analysis**: Actual SQL query text for forced plans
- **Detailed Comparisons**: Configuration differences, object-level changes, and performance insights
- **Interactive Features**:
  - Filter by status, search, expandable code views
  - Header buttons: "Sort A–Z" and "Sort by Category"
  - Smooth animations: cards move from old to new positions; sections reorder to match selection

### Troubleshooting

**Connection Issues:**
- **Windows Auth**: Ensure you're domain-joined and have database permissions
- **SQL Auth**: Verify username/password and server accessibility
- **Azure AD**: Check Azure AD authentication and database permissions
- **Mixed Auth**: Validate each authentication method independently

**Common Errors:**
- `Login failed`: Check credentials and server names
- `Azure AD errors`: Ensure machine is Azure AD joined or has cached credentials
- `Permission denied`: Verify read permissions on system catalogs
- `Timeout errors`: Check network connectivity and increase connection timeout

**Performance:**
- Large databases may take several minutes to complete
- Query Store comparisons can be resource-intensive
- Consider running during off-peak hours for production systems
- Query Store analysis includes actual SQL query text (truncated to 300 characters for display)

**Query Store Specific:**
- Shows both configuration differences and individual forced plans
- Displays actual SQL query text in the Object Name column
- Includes "View Query" buttons for full query text and execution plans
- Handles both enabled and disabled Query Store scenarios

### Project Structure
- `DatabaseSchemaDriftDetection.ps1` — main PowerShell script
- `DatabaseConfigGUI.ps1` — Windows Forms GUI application (modern styling, detailed connection errors)
- `Launch-GUI.ps1` — simple launcher for the GUI
- `Test-GUI.ps1` — test script to verify GUI functionality
- `config.json` — comparison configuration
- `Update-SqlCredentials.ps1` — secure credential management utility
- `Update-SqlCredentials-Examples.md` — credential management documentation
- `01_CreateSourceDatabase.sql`, `02_CreateTargetDatabase.sql` — sample DBs for demo
- `03_SetupInstructions.md` — additional setup notes
- `SchemaComparisonReport.html` — generated report (created after running drift detection)

### Notes
- The script is read-only; it does not change database objects.
- Query Store analysis shows actual SQL query text (truncated to 300 characters) in the Object Name column for better readability.
- The HTML report includes interactive "View Query" buttons for full query text and execution plans.
- All sensitive data is handled securely with proper memory cleanup.

### License
Provided as-is. Add a LICENSE file if you require a specific license.
