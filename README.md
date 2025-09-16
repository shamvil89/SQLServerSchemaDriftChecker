## SQL Server Schema Drift Detection

Detect, review, and report schema and metadata drift between two SQL Server databases. The script generates a single, self-contained HTML report with categorized differences and convenient “View Code” buttons.

### Features
- **Schema drift detection** across common objects (schemas, tables, views, stored procedures, functions, users, roles, permissions, and Query Store insights)
- **Single HTML report** (`SchemaComparisonReport.html`) with search, filters, and quick code viewing
- **Configuration-driven** via `config.json` (compare multiple pairs if desired)

### Prerequisites
- Windows with PowerShell (Windows PowerShell 5.1 or PowerShell 7+)
- Access to the SQL Server instances for both source and target
- Permissions to read system catalogs and Query Store (if enabled)

Optional:
- PowerShell `SqlServer` module for best compatibility

### Quick Start
1) (Optional) Create the example databases to try the tool:
```powershell
# From the repo root
sqlcmd -S localhost -E -i .\01_CreateSourceDatabase.sql
sqlcmd -S localhost -E -i .\02_CreateTargetDatabase.sql
```

2) Review `config.json` and set your environment values:
```json
{
  "databaseConfigurations": [
    {
      "name": "Test Environment Comparison",
      "description": "Compare test source and target databases for drift detection",
      "sourceServer": "localhost",
      "sourceDatabase": "TestSourceDB",
      "targetServer": "localhost",
      "targetDatabase": "TestTargetDB",
      "authType": "TrustedConnection"
    }
  ]
}
```

3) Run the drift detection script:
```powershell
# From the repo root
# If your policy blocks local scripts, you can temporarily bypass for this process:
# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

powershell -NoProfile -ExecutionPolicy Bypass -File .\DatabaseSchemaDriftDetection.ps1
```

4) Open the generated report:
- `SchemaComparisonReport.html`

### Configuration
`config.json` contains one or more entries under `databaseConfigurations`.
- **name**: Friendly label shown in the report
- **description**: Optional text for context
- **sourceServer / sourceDatabase**: Source connection
- **targetServer / targetDatabase**: Target connection
- **authType**: Typically `TrustedConnection` (Windows auth). Extend if you need SQL auth.

Tips:
- Add multiple entries to compare different environments (e.g., Dev→Test, Test→PreProd).
- Ensure the account running the script can connect and read metadata on both databases.

### Outputs
- `SchemaComparisonReport.html`: Interactive, categorized drift report with “View Code” buttons.

### Troubleshooting
- Authentication/connection errors: Verify server/database names and your permissions in `config.json`.
- Script blocked by policy: Use the process-level bypass shown above.
- Large databases: Allow more time. If you customize the script, you can reduce scope (e.g., skip heavy sections).

### Project Structure
- `DatabaseSchemaDriftDetection.ps1` — main PowerShell script
- `config.json` — comparison configuration
- `01_CreateSourceDatabase.sql`, `02_CreateTargetDatabase.sql` — sample DBs for demo
- `03_SetupInstructions.md` — additional setup notes
- `SchemaComparisonReport.html` — generated report
- `archive/` — previous script revisions

### Notes
- The script is read-only; it does not change database objects.
- If you want to embed additional details (e.g., raw plan XML) in the report, wire them into the HTML generation where “View Code” buttons are built.

### License
Provided as-is. Add a LICENSE file if you require a specific license.
