# Database Schema Drift Detection Tool
# Compares two SQL Server databases and generates an HTML report

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = ".\config.json",
    
    [Parameter(Mandatory=$false)]
    [string]$ConfigName = "",
    
    [Parameter(Mandatory=$false)]
    [string]$SourceServer,
    
    [Parameter(Mandatory=$false)]
    [string]$SourceDatabase,
    
    [Parameter(Mandatory=$false)]
    [string]$TargetServer,
    
    [Parameter(Mandatory=$false)]
    [string]$TargetDatabase,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ".\SchemaComparisonReport.html",
    
    # Optional direct authentication parameters (avoid JSON)
    [Parameter(Mandatory=$false)]
    [ValidateSet('TrustedConnection','SqlAuth','AzureAD')]
    [string]$SourceAuthType,
    [Parameter(Mandatory=$false)]
    [string]$SourceUsername,
    [Parameter(Mandatory=$false)]
    [string]$SourcePassword,
    [Parameter(Mandatory=$false)]
    [ValidateSet('TrustedConnection','SqlAuth','AzureAD')]
    [string]$TargetAuthType,
    [Parameter(Mandatory=$false)]
    [string]$TargetUsername,
    [Parameter(Mandatory=$false)]
    [string]$TargetPassword,

    [Parameter(Mandatory=$false)]
    [switch]$MultiPage,
    
    [Parameter(Mandatory=$false)]
    [switch]$ExportExcel
)

# Function to clear all cached variables and ensure clean state
function Clear-CachedVariables {
    Write-Verbose "Clearing cached variables to ensure clean state..."
    
    # Clear global variables that might persist between script runs
    $globalVarsToRemove = @(
        "global:ComparisonData", "global:AuthConfig", "config", "selectedConfig",
        "configContent", "sourceData", "targetData", "comparisonResults"
    )
    
    foreach ($varName in $globalVarsToRemove) {
        Remove-Variable -Name $varName -Scope Global -ErrorAction SilentlyContinue
    }
    
    # Clear script-scoped variables that might conflict with parameters
    $scriptVarsToRemove = @(
        "sourceData", "targetData", "comparisonResults", "reportData"
    )
    
    foreach ($varName in $scriptVarsToRemove) {
        Remove-Variable -Name $varName -Scope Script -ErrorAction SilentlyContinue
    }
    
    # Force garbage collection to free memory
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}

# Clear any cached variables to ensure clean state
Clear-CachedVariables

# Import required modules
Import-Module SqlServer -ErrorAction SilentlyContinue
if (-not (Get-Module SqlServer)) {
    Write-Error "SqlServer module is required. Please install it using: Install-Module -Name SqlServer"
    exit 1
}

# Load configuration from JSON file if no direct parameters are provided
if (-not $SourceServer -or -not $SourceDatabase -or -not $TargetServer -or -not $TargetDatabase) {
    # Support either a file path or raw JSON string for -ConfigFile
    $configContent = $null
    if (Test-Path $ConfigFile) {
        $configContent = Get-Content -Path $ConfigFile -Raw
    } elseif ($ConfigFile -match '^\s*[\{\[]') {
        # Inline JSON content passed directly
        $configContent = $ConfigFile
    } else {
        Write-Error "Configuration file not found: $ConfigFile"
        Write-Host "Please create a config.json file or provide direct parameters." -ForegroundColor Yellow
        exit 1
    }
    
    try {
        $config = $configContent | ConvertFrom-Json
        
        # If ConfigName is specified, use that specific configuration
        if ($ConfigName -ne "") {
            $selectedConfig = $config.databaseConfigurations | Where-Object { $_.name -eq $ConfigName }
            if (-not $selectedConfig) {
                Write-Error "Configuration '$ConfigName' not found in config file"
                exit 1
            }
        } else {
            # Use the first enabled configuration, or first one if none are marked as enabled
            $selectedConfig = $config.databaseConfigurations | Where-Object { $_.enabled -eq $true } | Select-Object -First 1
            if (-not $selectedConfig) {
                $selectedConfig = $config.databaseConfigurations | Select-Object -First 1
            }
        }
        
        if (-not $selectedConfig) {
            Write-Error "No database configurations found in config file"
            exit 1
        }
        
        # Override parameters with config values
        $SourceServer = $selectedConfig.sourceServer
        $SourceDatabase = $selectedConfig.sourceDatabase
        $TargetServer = $selectedConfig.targetServer
        $TargetDatabase = $selectedConfig.targetDatabase
        
        # Store authentication configuration for later use
        $global:AuthConfig = @{
            AuthType = $selectedConfig.authType
            SourceAuthType = if ($selectedConfig.sourceAuthType) { $selectedConfig.sourceAuthType } else { $selectedConfig.authType }
            TargetAuthType = if ($selectedConfig.targetAuthType) { $selectedConfig.targetAuthType } else { $selectedConfig.authType }
            SourceUsername = $selectedConfig.sourceUsername
            SourcePassword = $selectedConfig.sourcePassword
            TargetUsername = $selectedConfig.targetUsername
            TargetPassword = $selectedConfig.targetPassword
        }
        
        Write-Host "Using configuration: $($selectedConfig.name)" -ForegroundColor Green
        Write-Host "Source: $SourceServer.$SourceDatabase" -ForegroundColor Cyan
        Write-Host "Target: $TargetServer.$TargetDatabase" -ForegroundColor Cyan
    }
    catch {
        Write-Error "Error loading configuration file: $($_.Exception.Message)"
        exit 1
    }
}
else {
    Write-Host "Using direct parameters (JSON config overridden)" -ForegroundColor Yellow
    # Initialize auth config from CLI if provided (fallback to TrustedConnection)
    $srcAuth = if ($SourceAuthType) { $SourceAuthType } else { "TrustedConnection" }
    $tgtAuth = if ($TargetAuthType) { $TargetAuthType } else { "TrustedConnection" }
    $global:AuthConfig = @{
        AuthType = if ($srcAuth -eq $tgtAuth) { $srcAuth } else { "Mixed" }
        SourceAuthType = $srcAuth
        TargetAuthType = $tgtAuth
        SourceUsername = $SourceUsername
        SourcePassword = $SourcePassword
        TargetUsername = $TargetUsername
        TargetPassword = $TargetPassword
    }
}

# Final validation
if (-not $SourceServer -or -not $SourceDatabase -or -not $TargetServer -or -not $TargetDatabase) {
    Write-Error "Required database parameters are missing. Please check your configuration."
    exit 1
}

# Initialize global variables for storing comparison data (ensures clean state)
$global:ComparisonData = @{
    Tables = @()
    Columns = @()
    Indexes = @()
    Functions = @()
    StoredProcedures = @()
    DataTypes = @()
    Constraints = @()
    Views = @()
    Synonyms = @()
    TableTriggers = @()
    DatabaseTriggers = @()
    Keys = @()
    DatabaseOptions = @()
    FileInfo = @()
    Compatibility = @()
    Collation = @()
    VLF = @()
    Users = @()
    Roles = @()
    Schemas = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
    ExternalResources = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
    QueryStore = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}
# Function to execute SQL query and return results
function Invoke-SqlQuery {
    param(
        [string]$Server,
        [string]$Database,
        [string]$Query
    )
    
    try {
        # Determine which credentials to use based on server
        $isSourceServer = ($Server -eq $SourceServer)
        
        # Determine the authentication type for this specific server
        $authType = if ($isSourceServer) { $global:AuthConfig.SourceAuthType } else { $global:AuthConfig.TargetAuthType }
        
        if ($authType -eq "SqlAuth") {
            if ($isSourceServer) {
                $username = $global:AuthConfig.SourceUsername
                $password = $global:AuthConfig.SourcePassword
            } else {
                $username = $global:AuthConfig.TargetUsername
                $password = $global:AuthConfig.TargetPassword
            }
            
            if (-not $username -or -not $password) {
                throw "SQL Authentication configured but username/password missing for server $Server"
            }
            
            # Optimize for Azure SQL Database if server name contains .database.windows.net
            if ($Server -like "*.database.windows.net") {
                $connectionString = "Server=$Server;Database=$Database;User Id=$username;Password=$password;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;Application Name=SchemaDriftDetection;"
            } else {
                $connectionString = "Server=$Server;Database=$Database;User Id=$username;Password=$password;TrustServerCertificate=true;Connection Timeout=30;"
            }
        } elseif ($authType -eq "AzureAD") {
            # Azure AD Integrated Authentication for Azure SQL Database
            $connectionString = "Server=$Server;Database=$Database;Authentication=Active Directory Integrated;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
        } else {
            # Default to Trusted Connection (Windows Auth)
        $connectionString = "Server=$Server;Database=$Database;Integrated Security=true;TrustServerCertificate=true;"
        }
        
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()
        
        $command = New-Object System.Data.SqlClient.SqlCommand($Query, $connection)
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($command)
        $dataset = New-Object System.Data.DataSet
        $adapter.Fill($dataset) | Out-Null
        
        $connection.Close()
        return $dataset.Tables[0]
    }
    catch {
        Write-Warning "Error executing query on $Server.$Database : $($_.Exception.Message)"
        return $null
    }
}

# Function to get table information
function Get-TableInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    t.TABLE_SCHEMA,
    t.TABLE_NAME,
    t.TABLE_TYPE,
    o.create_date,
    o.modify_date,
    p.rows as ROW_COUNT,
    -- Generate CREATE TABLE statement
    'CREATE TABLE [' + t.TABLE_SCHEMA + '].[' + t.TABLE_NAME + '] (' + CHAR(13) + CHAR(10) +
    STUFF((
        SELECT ', ' + CHAR(13) + CHAR(10) + '    [' + c.COLUMN_NAME + '] ' + 
               c.DATA_TYPE + 
               CASE 
                   WHEN c.CHARACTER_MAXIMUM_LENGTH IS NOT NULL 
                       THEN '(' + CAST(c.CHARACTER_MAXIMUM_LENGTH AS VARCHAR(10)) + ')'
                   WHEN c.NUMERIC_PRECISION IS NOT NULL AND c.NUMERIC_SCALE IS NOT NULL
                       THEN '(' + CAST(c.NUMERIC_PRECISION AS VARCHAR(10)) + ',' + CAST(c.NUMERIC_SCALE AS VARCHAR(10)) + ')'
                   WHEN c.NUMERIC_PRECISION IS NOT NULL
                       THEN '(' + CAST(c.NUMERIC_PRECISION AS VARCHAR(10)) + ')'
                   ELSE ''
               END +
               CASE WHEN c.IS_NULLABLE = 'NO' THEN ' NOT NULL' ELSE ' NULL' END +
               CASE WHEN c.COLUMN_DEFAULT IS NOT NULL THEN ' DEFAULT ' + c.COLUMN_DEFAULT ELSE '' END
        FROM INFORMATION_SCHEMA.COLUMNS c
        WHERE c.TABLE_SCHEMA = t.TABLE_SCHEMA AND c.TABLE_NAME = t.TABLE_NAME
        ORDER BY c.ORDINAL_POSITION
        FOR XML PATH('')
    ), 1, 2, '') + CHAR(13) + CHAR(10) + ');' as CREATE_STATEMENT
FROM INFORMATION_SCHEMA.TABLES t
INNER JOIN sys.objects o ON o.name = t.TABLE_NAME AND o.schema_id = SCHEMA_ID(t.TABLE_SCHEMA)
INNER JOIN sys.partitions p ON p.object_id = o.object_id AND p.index_id IN (0,1)
WHERE t.TABLE_TYPE = 'BASE TABLE'
GROUP BY t.TABLE_SCHEMA, t.TABLE_NAME, t.TABLE_TYPE, o.create_date, o.modify_date, p.rows
ORDER BY t.TABLE_SCHEMA, t.TABLE_NAME
"@
    
    return Invoke-SqlQuery -Server $Server -Database $Database -Query $query
}

# Function to get schema information
function Get-SchemaInfo {
    param([string]$Server, [string]$Database)
    $query = @"
SELECT 
    
    s.name       AS SCHEMA_NAME,
    
    dp.name AS PRINCIPAL_NAME
FROM sys.schemas s
LEFT JOIN sys.database_principals dp ON s.principal_id = dp.principal_id

ORDER BY s.name
"@
    return Invoke-SqlQuery -Server $Server -Database $Database -Query $query
}

# Function to get column information
function Get-ColumnInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    c.TABLE_SCHEMA,
    c.TABLE_NAME,
    c.COLUMN_NAME,
    c.ORDINAL_POSITION,
    c.COLUMN_DEFAULT,
    c.IS_NULLABLE,
    c.DATA_TYPE,
    c.CHARACTER_MAXIMUM_LENGTH,
    c.CHARACTER_OCTET_LENGTH,
    c.NUMERIC_PRECISION,
    c.NUMERIC_SCALE,
    c.DATETIME_PRECISION,
    c.CHARACTER_SET_NAME,
    c.COLLATION_NAME,
    -- Generate ALTER TABLE statement for adding this column
    'ALTER TABLE [' + c.TABLE_SCHEMA + '].[' + c.TABLE_NAME + '] ADD [' + c.COLUMN_NAME + '] ' + 
    c.DATA_TYPE + 
    CASE 
        WHEN c.CHARACTER_MAXIMUM_LENGTH IS NOT NULL 
            THEN '(' + CAST(c.CHARACTER_MAXIMUM_LENGTH AS VARCHAR(10)) + ')'
        WHEN c.NUMERIC_PRECISION IS NOT NULL AND c.NUMERIC_SCALE IS NOT NULL
            THEN '(' + CAST(c.NUMERIC_PRECISION AS VARCHAR(10)) + ',' + CAST(c.NUMERIC_SCALE AS VARCHAR(10)) + ')'
        WHEN c.NUMERIC_PRECISION IS NOT NULL
            THEN '(' + CAST(c.NUMERIC_PRECISION AS VARCHAR(10)) + ')'
        ELSE ''
    END +
    CASE WHEN c.IS_NULLABLE = 'NO' THEN ' NOT NULL' ELSE ' NULL' END +
    CASE WHEN c.COLUMN_DEFAULT IS NOT NULL THEN ' DEFAULT ' + c.COLUMN_DEFAULT ELSE '' END + ';' as CREATE_STATEMENT
FROM INFORMATION_SCHEMA.COLUMNS c
ORDER BY c.TABLE_SCHEMA, c.TABLE_NAME, c.ORDINAL_POSITION
"@
    
    return Invoke-SqlQuery -Server $Server -Database $Database -Query $query
}

# Function to get index information
function Get-IndexInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    s.name as SCHEMA_NAME,
    t.name as TABLE_NAME,
    i.name as INDEX_NAME,
    i.type_desc as INDEX_TYPE,
    CAST(i.is_unique as BIT) as is_unique,
    CAST(i.is_primary_key as BIT) as is_primary_key,
    CAST(i.is_unique_constraint as BIT) as is_unique_constraint,
    i.fill_factor,
    CAST(i.is_padded as BIT) as is_padded,
    CAST(i.allow_row_locks as BIT) as allow_row_locks,
    CAST(i.allow_page_locks as BIT) as allow_page_locks,
    CAST(i.has_filter as BIT) as has_filter,
    ISNULL(i.filter_definition, '') as filter_definition,
    -- Include column information and order (key columns first, then included columns)
    STUFF((
        SELECT ', ' + c.name + 
               CASE WHEN ic.is_descending_key = 1 THEN ' DESC' ELSE ' ASC' END +
               CASE WHEN ic.is_included_column = 1 THEN ' (INCLUDED)' ELSE '' END
        FROM sys.index_columns ic
        INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        WHERE ic.object_id = i.object_id 
          AND ic.index_id = i.index_id
        ORDER BY 
            CASE WHEN ic.is_included_column = 0 THEN 0 ELSE 1 END,  -- Key columns first
            ic.key_ordinal,  -- Then by key ordinal for key columns
            ic.column_id     -- Then by column_id for included columns
        FOR XML PATH('')
    ), 1, 2, '') as INDEX_COLUMNS,
    -- Count of key columns (excluding included columns)
    (SELECT COUNT(*) 
     FROM sys.index_columns ic2 
     WHERE ic2.object_id = i.object_id 
       AND ic2.index_id = i.index_id 
       AND ic2.is_included_column = 0) as KEY_COLUMN_COUNT,
    -- Count of included columns  
    (SELECT COUNT(*) 
     FROM sys.index_columns ic3 
     WHERE ic3.object_id = i.object_id 
       AND ic3.index_id = i.index_id 
       AND ic3.is_included_column = 1) as INCLUDED_COLUMN_COUNT,
    -- Generate CREATE INDEX statement
    CASE 
        WHEN i.is_primary_key = 1 THEN 
            'ALTER TABLE [' + s.name + '].[' + t.name + '] ADD CONSTRAINT [' + i.name + '] PRIMARY KEY ' +
            CASE WHEN i.type = 1 THEN 'CLUSTERED' ELSE 'NONCLUSTERED' END + ' (' +
            STUFF((
                SELECT ', [' + c.name + ']' + CASE WHEN ic.is_descending_key = 1 THEN ' DESC' ELSE ' ASC' END
                FROM sys.index_columns ic
                INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                ORDER BY ic.key_ordinal
                FOR XML PATH('')
            ), 1, 2, '') + ');'
        WHEN i.is_unique_constraint = 1 THEN
            'ALTER TABLE [' + s.name + '].[' + t.name + '] ADD CONSTRAINT [' + i.name + '] UNIQUE ' +
            CASE WHEN i.type = 1 THEN 'CLUSTERED' ELSE 'NONCLUSTERED' END + ' (' +
            STUFF((
                SELECT ', [' + c.name + ']' + CASE WHEN ic.is_descending_key = 1 THEN ' DESC' ELSE ' ASC' END
                FROM sys.index_columns ic
                INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                ORDER BY ic.key_ordinal
                FOR XML PATH('')
            ), 1, 2, '') + ');'
        ELSE
            'CREATE ' + CASE WHEN i.is_unique = 1 THEN 'UNIQUE ' ELSE '' END +
            CASE WHEN i.type = 1 THEN 'CLUSTERED ' WHEN i.type = 2 THEN 'NONCLUSTERED ' ELSE '' END +
            'INDEX [' + i.name + '] ON [' + s.name + '].[' + t.name + '] (' +
            STUFF((
                SELECT ', [' + c.name + ']' + CASE WHEN ic.is_descending_key = 1 THEN ' DESC' ELSE ' ASC' END
                FROM sys.index_columns ic
                INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                ORDER BY ic.key_ordinal
                FOR XML PATH('')
            ), 1, 2, '') + ')' +
            CASE 
                WHEN EXISTS(SELECT 1 FROM sys.index_columns ic WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1)
                THEN ' INCLUDE (' +
                    STUFF((
                        SELECT ', [' + c.name + ']'
                        FROM sys.index_columns ic
                        INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
                        ORDER BY ic.column_id
                        FOR XML PATH('')
                    ), 1, 2, '') + ')'
                ELSE ''
            END +
            CASE WHEN i.has_filter = 1 AND i.filter_definition IS NOT NULL THEN ' WHERE ' + i.filter_definition ELSE '' END +
            ';'
    END as CREATE_STATEMENT
FROM sys.indexes i
INNER JOIN sys.tables t ON i.object_id = t.object_id
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE i.type > 0
ORDER BY s.name, t.name, i.name
"@
    
    return Invoke-SqlQuery -Server $Server -Database $Database -Query $query
}

# Function to get function information
function Get-FunctionInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    s.name as SCHEMA_NAME,
    o.name as FUNCTION_NAME,
    o.type_desc as FUNCTION_TYPE,
    o.create_date,
    o.modify_date,
    m.definition
FROM sys.objects o
INNER JOIN sys.schemas s ON o.schema_id = s.schema_id
INNER JOIN sys.sql_modules m ON o.object_id = m.object_id
WHERE o.type IN ('FN', 'IF', 'TF', 'FS', 'FT')
ORDER BY s.name, o.name
"@
    
    return Invoke-SqlQuery -Server $Server -Database $Database -Query $query
}

# Function to get stored procedure information
function Get-StoredProcedureInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    s.name as SCHEMA_NAME,
    p.name as PROCEDURE_NAME,
    p.create_date,
    p.modify_date,
    m.definition
FROM sys.procedures p
INNER JOIN sys.schemas s ON p.schema_id = s.schema_id
INNER JOIN sys.sql_modules m ON p.object_id = m.object_id
ORDER BY s.name, p.name
"@
    
    return Invoke-SqlQuery -Server $Server -Database $Database -Query $query
}

# Function to get data type information
function Get-DataTypeInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    t.name as TYPE_NAME,
    t.system_type_id,
    t.user_type_id,
    t.schema_id,
    s.name as SCHEMA_NAME,
    t.max_length,
    t.precision,
    t.scale,
    t.collation_name,
    t.is_nullable,
    t.is_user_defined,
    t.is_assembly_type
FROM sys.types t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
ORDER BY s.name, t.name
"@
    
    return Invoke-SqlQuery -Server $Server -Database $Database -Query $query
}

# Function to get constraint information
function Get-ConstraintInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    s.name as SCHEMA_NAME,
    t.name as TABLE_NAME,
    c.name as CONSTRAINT_NAME,
    c.type_desc as CONSTRAINT_TYPE,
    c.is_disabled,
    c.is_not_trusted,
    c.is_system_named,
    c.definition as CONSTRAINT_DEFINITION,
    'ALTER TABLE [' + s.name + '].[' + t.name + '] ADD CONSTRAINT [' + c.name + '] CHECK ' + c.definition as CREATE_STATEMENT
FROM sys.check_constraints c
INNER JOIN sys.tables t ON c.parent_object_id = t.object_id
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
UNION ALL
SELECT 
    s.name as SCHEMA_NAME,
    t.name as TABLE_NAME,
    fk.name as CONSTRAINT_NAME,
    'FOREIGN_KEY' as CONSTRAINT_TYPE,
    fk.is_disabled,
    fk.is_not_trusted,
    fk.is_system_named,
    NULL as CONSTRAINT_DEFINITION,
    'ALTER TABLE [' + s.name + '].[' + t.name + '] ADD CONSTRAINT [' + fk.name + '] FOREIGN KEY (columns) REFERENCES referenced_table (ref_columns)' as CREATE_STATEMENT
FROM sys.foreign_keys fk
INNER JOIN sys.tables t ON fk.parent_object_id = t.object_id
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
ORDER BY SCHEMA_NAME, TABLE_NAME, CONSTRAINT_NAME
"@
    
    return Invoke-SqlQuery -Server $Server -Database $Database -Query $query
}

# Function to get view information
function Get-ViewInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    s.name as SCHEMA_NAME,
    v.name as VIEW_NAME,
    v.create_date,
    v.modify_date,
    OBJECT_DEFINITION(v.object_id) as definition,
    'CREATE VIEW [' + s.name + '].[' + v.name + '] AS ' + CHAR(13) + CHAR(10) + OBJECT_DEFINITION(v.object_id) as CREATE_STATEMENT
FROM sys.views v
INNER JOIN sys.schemas s ON v.schema_id = s.schema_id
ORDER BY s.name, v.name
"@
    
    return Invoke-SqlQuery -Server $Server -Database $Database -Query $query
}

# Function to get synonym information
function Get-SynonymInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    s.name as SCHEMA_NAME,
    syn.name as SYNONYM_NAME,
    syn.base_object_name,
    'CREATE SYNONYM [' + s.name + '].[' + syn.name + '] FOR ' + syn.base_object_name as CREATE_STATEMENT
FROM sys.synonyms syn
INNER JOIN sys.schemas s ON syn.schema_id = s.schema_id
ORDER BY s.name, syn.name
"@
    
    $result = Invoke-SqlQuery -Server $Server -Database $Database -Query $query
    # Ensure we always return a DataTable, even if there's only one row
    if ($result -and $result.GetType().Name -eq "DataRow") {
        $table = New-Object System.Data.DataTable
        # Clone the columns to avoid the "already belongs to another DataTable" error
        foreach ($column in $result.Table.Columns) {
            $newColumn = $table.Columns.Add($column.ColumnName, $column.DataType)
            $newColumn.AllowDBNull = $column.AllowDBNull
            $newColumn.MaxLength = $column.MaxLength
        }
        $table.ImportRow($result)
        return $table
    }
    return $result
}

# Function to get table trigger information
function Get-TableTriggerInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    s.name as SCHEMA_NAME,
    t.name as TABLE_NAME,
    tr.name as TRIGGER_NAME,
    tr.create_date,
    tr.modify_date,
    tr.is_disabled,
    tr.is_not_for_replication,
    tr.is_instead_of_trigger,
    OBJECT_DEFINITION(tr.object_id) as definition,
    'CREATE TRIGGER [' + s.name + '].[' + tr.name + '] ON [' + s.name + '].[' + t.name + '] ' + 
    CASE WHEN tr.is_instead_of_trigger = 1 THEN 'INSTEAD OF' ELSE 'AFTER' END + ' ' +
    CASE WHEN tr.is_disabled = 1 THEN 'DISABLED ' ELSE '' END +
    'AS ' + CHAR(13) + CHAR(10) + OBJECT_DEFINITION(tr.object_id) as CREATE_STATEMENT
FROM sys.triggers tr
INNER JOIN sys.tables t ON tr.parent_id = t.object_id
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE tr.parent_class = 1  -- Table triggers only
ORDER BY s.name, t.name, tr.name
"@
    
    return Invoke-SqlQuery -Server $Server -Database $Database -Query $query
}

# Function to get database trigger information
function Get-DatabaseTriggerInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    tr.name as TRIGGER_NAME,
    tr.create_date,
    tr.modify_date,
    tr.is_disabled,
    tr.is_not_for_replication,
    OBJECT_DEFINITION(tr.object_id) as definition,
    'CREATE TRIGGER [' + tr.name + '] ON DATABASE ' + 
    CASE WHEN tr.is_disabled = 1 THEN 'DISABLED ' ELSE '' END +
    'AS ' + CHAR(13) + CHAR(10) + OBJECT_DEFINITION(tr.object_id) as CREATE_STATEMENT
FROM sys.triggers tr
WHERE tr.parent_class = 0  -- Database triggers only
ORDER BY tr.name
"@
    
    $result = Invoke-SqlQuery -Server $Server -Database $Database -Query $query
    # Ensure we always return a DataTable, even if there's only one row
    if ($result -and $result.GetType().Name -eq "DataRow") {
        $table = New-Object System.Data.DataTable
        # Clone the columns to avoid the "already belongs to another DataTable" error
        foreach ($column in $result.Table.Columns) {
            $newColumn = $table.Columns.Add($column.ColumnName, $column.DataType)
            $newColumn.AllowDBNull = $column.AllowDBNull
            $newColumn.MaxLength = $column.MaxLength
        }
        $table.ImportRow($result)
        return $table
    }
    return $result
}

# Function to get key information
function Get-KeyInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
-- Primary Keys and Unique Constraints
SELECT 
    s.name as SCHEMA_NAME,
    t.name as TABLE_NAME,
    k.name as KEY_NAME,
    k.type_desc as KEY_TYPE,
    CASE WHEN k.type = 'PK' THEN 1 ELSE 0 END as is_primary_key,
    CASE WHEN k.type = 'UQ' THEN 1 ELSE 0 END as is_unique_constraint,
    CASE WHEN k.type = 'UQ' THEN 1 ELSE 0 END as is_unique,
    'ALTER TABLE [' + s.name + '].[' + t.name + '] ADD CONSTRAINT [' + k.name + '] ' +
    CASE 
        WHEN k.type = 'PK' THEN 'PRIMARY KEY'
        WHEN k.type = 'UQ' THEN 'UNIQUE'
        ELSE 'INDEX'
    END + ' (' + 
    STUFF((
        SELECT ', [' + c.name + ']' + CASE WHEN ic.is_descending_key = 1 THEN ' DESC' ELSE ' ASC' END
        FROM sys.index_columns ic
        INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        INNER JOIN sys.indexes i ON ic.object_id = i.object_id AND ic.index_id = i.index_id
        WHERE i.name = k.name AND ic.object_id = k.parent_object_id
        ORDER BY ic.key_ordinal
        FOR XML PATH('')
    ), 1, 2, '') + ')' as CREATE_STATEMENT
FROM sys.key_constraints k
INNER JOIN sys.tables t ON k.parent_object_id = t.object_id
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id

UNION ALL

-- Foreign Keys
SELECT 
    s.name as SCHEMA_NAME,
    t.name as TABLE_NAME,
    fk.name as KEY_NAME,
    'FOREIGN_KEY' as KEY_TYPE,
    0 as is_primary_key,
    0 as is_unique_constraint,
    0 as is_unique,
    'ALTER TABLE [' + s.name + '].[' + t.name + '] ADD CONSTRAINT [' + fk.name + '] FOREIGN KEY (' + 
    STUFF((
        SELECT ', [' + c.name + ']'
        FROM sys.foreign_key_columns fkc
        INNER JOIN sys.columns c ON fkc.parent_object_id = c.object_id AND fkc.parent_column_id = c.column_id
        WHERE fkc.constraint_object_id = fk.object_id
        ORDER BY fkc.constraint_column_id
        FOR XML PATH('')
    ), 1, 2, '') + ') REFERENCES [' + 
    SCHEMA_NAME(fk.referenced_object_id) + '].[' + OBJECT_NAME(fk.referenced_object_id) + '] (' +
    STUFF((
        SELECT ', [' + c.name + ']'
        FROM sys.foreign_key_columns fkc
        INNER JOIN sys.columns c ON fkc.referenced_object_id = c.object_id AND fkc.referenced_column_id = c.column_id
        WHERE fkc.constraint_object_id = fk.object_id
        ORDER BY fkc.constraint_column_id
        FOR XML PATH('')
    ), 1, 2, '') + ')' as CREATE_STATEMENT
FROM sys.foreign_keys fk
INNER JOIN sys.tables t ON fk.parent_object_id = t.object_id
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
UNION ALL

-- Indexes (non-key constraints)
SELECT 
    s.name as SCHEMA_NAME,
    t.name as TABLE_NAME,
    i.name as KEY_NAME,
    i.type_desc as KEY_TYPE,
    0 as is_primary_key,
    0 as is_unique_constraint,
    CASE WHEN i.is_unique = 1 THEN 1 ELSE 0 END as is_unique,
    'CREATE ' + 
    CASE WHEN i.is_unique = 1 THEN 'UNIQUE ' ELSE '' END +
    CASE WHEN i.type = 1 THEN 'CLUSTERED' ELSE 'NONCLUSTERED' END +
    ' INDEX [' + i.name + '] ON [' + s.name + '].[' + t.name + '] (' +
    STUFF((
        SELECT ', [' + c.name + ']' + CASE WHEN ic.is_descending_key = 1 THEN ' DESC' ELSE ' ASC' END
        FROM sys.index_columns ic
        INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
        ORDER BY ic.key_ordinal
        FOR XML PATH('')
    ), 1, 2, '') + ')' as CREATE_STATEMENT
FROM sys.indexes i
INNER JOIN sys.tables t ON i.object_id = t.object_id
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE i.is_primary_key = 0 AND i.is_unique_constraint = 0 AND i.name IS NOT NULL

ORDER BY SCHEMA_NAME, TABLE_NAME, KEY_NAME
"@
    
    $result = Invoke-SqlQuery -Server $Server -Database $Database -Query $query
    # Ensure we always return a DataTable, even if there's only one row
    if ($result -and $result.GetType().Name -eq "DataRow") {
        $table = New-Object System.Data.DataTable
        # Clone the columns to avoid the "already belongs to another DataTable" error
        foreach ($column in $result.Table.Columns) {
            $newColumn = $table.Columns.Add($column.ColumnName, $column.DataType)
            $newColumn.AllowDBNull = $column.AllowDBNull
            $newColumn.MaxLength = $column.MaxLength
        }
        $table.ImportRow($result)
        return $table
    }
    return $result
}

# Function to get database options
function Get-DatabaseOptions {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    name,
    collation_name,
    compatibility_level,
    CAST(is_auto_close_on as BIT) as is_auto_close_on,
    CAST(is_auto_shrink_on as BIT) as is_auto_shrink_on,
    CAST(is_auto_create_stats_on as BIT) as is_auto_create_stats_on,
    CAST(is_auto_update_stats_on as BIT) as is_auto_update_stats_on,
    CAST(is_auto_update_stats_async_on as BIT) as is_auto_update_stats_async_on,
    CAST(is_ansi_null_default_on as BIT) as is_ansi_null_default_on,
    CAST(is_ansi_nulls_on as BIT) as is_ansi_nulls_on,
    CAST(is_ansi_padding_on as BIT) as is_ansi_padding_on,
    CAST(is_ansi_warnings_on as BIT) as is_ansi_warnings_on,
    CAST(is_arithabort_on as BIT) as is_arithabort_on,
    CAST(is_concat_null_yields_null_on as BIT) as is_concat_null_yields_null_on,
    CAST(is_cursor_close_on_commit_on as BIT) as is_cursor_close_on_commit_on,
    CAST(is_date_correlation_on as BIT) as is_date_correlation_on,
    CAST(is_numeric_roundabort_on as BIT) as is_numeric_roundabort_on,
    CAST(is_quoted_identifier_on as BIT) as is_quoted_identifier_on,
    CAST(is_recursive_triggers_on as BIT) as is_recursive_triggers_on,
    CAST(is_auto_create_stats_incremental_on as BIT) as is_auto_create_stats_incremental_on,
    CAST(is_encrypted as BIT) as is_encrypted,
    CAST(is_honor_broker_priority_on as BIT) as is_honor_broker_priority_on,
    CAST(is_parameterization_forced as BIT) as is_parameterization_forced,
    CAST(is_read_committed_snapshot_on as BIT) as is_read_committed_snapshot_on,
    CAST(is_read_only as BIT) as is_read_only,
    CAST(is_trustworthy_on as BIT) as is_trustworthy_on
FROM sys.databases
WHERE name = '$Database'
"@
    
    $result = Invoke-SqlQuery -Server $Server -Database $Database -Query $query
    # Ensure we always return a DataTable, even if there's only one row
    if ($result -and $result.GetType().Name -eq "DataRow") {
        $table = New-Object System.Data.DataTable
        # Clone the columns to avoid the "already belongs to another DataTable" error
        foreach ($column in $result.Table.Columns) {
            $newColumn = $table.Columns.Add($column.ColumnName, $column.DataType)
            $newColumn.AllowDBNull = $column.AllowDBNull
            $newColumn.MaxLength = $column.MaxLength
        }
        $table.ImportRow($result)
        return $table
    }
    return $result
}

function Get-DatabaseAdvancedOptions {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    name,
    -- All database options from sys.databases
    collation_name,
    compatibility_level,
    recovery_model_desc,
    page_verify_option_desc,
    containment_desc,
    target_recovery_time_in_seconds,
    is_auto_close_on,
    is_auto_shrink_on,
    is_auto_create_stats_on,
    is_auto_update_stats_on,
    is_auto_update_stats_async_on,
    is_ansi_null_default_on,
    is_ansi_nulls_on,
    is_ansi_padding_on,
    is_ansi_warnings_on,
    is_arithabort_on,
    is_concat_null_yields_null_on,
    is_cursor_close_on_commit_on,
    is_date_correlation_on,
    is_numeric_roundabort_on,
    is_quoted_identifier_on,
    is_recursive_triggers_on,
    is_auto_create_stats_incremental_on,
    is_encrypted,
    is_honor_broker_priority_on,
    is_parameterization_forced,
    is_read_committed_snapshot_on,
    is_read_only,
    is_trustworthy_on
FROM sys.databases
WHERE name = '$Database'
"@
    
    $result = Invoke-SqlQuery -Server $Server -Database $Database -Query $query
    # Ensure we always return a DataTable, even if there's only one row
    if ($result -and $result.GetType().Name -eq "DataRow") {
        $table = New-Object System.Data.DataTable
        # Clone the columns to avoid the "already belongs to another DataTable" error
        foreach ($column in $result.Table.Columns) {
            $newColumn = $table.Columns.Add($column.ColumnName, $column.DataType)
            $newColumn.AllowDBNull = $column.AllowDBNull
            $newColumn.MaxLength = $column.MaxLength
        }
        $table.ImportRow($result)
        return $table
    }
    return $result
}

function Get-DatabaseScopedConfigurations {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    '$Database' as database_name,
    name,
    value,
    value_for_secondary,
    is_value_default
FROM sys.database_scoped_configurations
"@
    
    $result = Invoke-SqlQuery -Server $Server -Database $Database -Query $query
    # Ensure we always return a DataTable, even if there's only one row
    if ($result -and $result.GetType().Name -eq "DataRow") {
        $table = New-Object System.Data.DataTable
        # Clone the columns to avoid the "already belongs to another DataTable" error
        foreach ($column in $result.Table.Columns) {
            $newColumn = $table.Columns.Add($column.ColumnName, $column.DataType)
            $newColumn.AllowDBNull = $column.AllowDBNull
            $newColumn.MaxLength = $column.MaxLength
        }
        $table.ImportRow($result)
        return $table
    }
    return $result
}
function Convert-ArrayToDataTable {
    param([array]$InputArray)
    
    if ($null -eq $InputArray -or $InputArray.Count -eq 0) {
        return $null
    }
    
    # Create a DataTable
    $dataTable = New-Object System.Data.DataTable
    
    # Get the properties from the first object to create columns
    $firstObject = $InputArray[0]
    $properties = $firstObject.PSObject.Properties
    
    foreach ($property in $properties) {
        $column = New-Object System.Data.DataColumn
        $column.ColumnName = $property.Name
        # Set a default string type for all columns to avoid type issues
        $column.DataType = [System.String]
        $dataTable.Columns.Add($column)
    }
    
    # Add rows
    foreach ($object in $InputArray) {
        $row = $dataTable.NewRow()
        foreach ($property in $properties) {
            $value = $object.$($property.Name)
            if ($null -eq $value) {
                $row[$property.Name] = [DBNull]::Value
            } else {
                $row[$property.Name] = $value.ToString()
            }
        }
        $dataTable.Rows.Add($row)
    }
    
    return $dataTable
}

function Convert-DatabaseOptionsToIndividualSettings {
    param([System.Data.DataRow]$DatabaseRow)
    
    $settings = @()
    $databaseName = $DatabaseRow.name
    
    # Define all database options with their corresponding values and SQL commands
    $optionMappings = @{
                'COLLATE' = @{
                    'Value' = if ($null -ne $DatabaseRow.collation_name) { $DatabaseRow.collation_name } else { 'NONE' }
                    'SQLCommand' = "ALTER DATABASE [$databaseName] SET COLLATE $(if ($null -ne $DatabaseRow.collation_name) { $DatabaseRow.collation_name } else { 'NONE' });"
                }
        'COMPATIBILITY_LEVEL' = @{
            'Value' = $DatabaseRow.compatibility_level.ToString()
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET COMPATIBILITY_LEVEL = $($DatabaseRow.compatibility_level);"
        }
        'AUTO_CLOSE' = @{
            'Value' = if ($DatabaseRow.is_auto_close_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET AUTO_CLOSE $(if ($DatabaseRow.is_auto_close_on) { 'ON' } else { 'OFF' });"
        }
        'AUTO_SHRINK' = @{
            'Value' = if ($DatabaseRow.is_auto_shrink_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET AUTO_SHRINK $(if ($DatabaseRow.is_auto_shrink_on) { 'ON' } else { 'OFF' });"
        }
        'AUTO_CREATE_STATISTICS' = @{
            'Value' = if ($DatabaseRow.is_auto_create_stats_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET AUTO_CREATE_STATISTICS $(if ($DatabaseRow.is_auto_create_stats_on) { 'ON' } else { 'OFF' });"
        }
        'AUTO_UPDATE_STATISTICS' = @{
            'Value' = if ($DatabaseRow.is_auto_update_stats_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET AUTO_UPDATE_STATISTICS $(if ($DatabaseRow.is_auto_update_stats_on) { 'ON' } else { 'OFF' });"
        }
        'AUTO_UPDATE_STATISTICS_ASYNC' = @{
            'Value' = if ($DatabaseRow.is_auto_update_stats_async_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET AUTO_UPDATE_STATISTICS_ASYNC $(if ($DatabaseRow.is_auto_update_stats_async_on) { 'ON' } else { 'OFF' });"
        }
        'ANSI_NULL_DEFAULT' = @{
            'Value' = if ($DatabaseRow.is_ansi_null_default_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET ANSI_NULL_DEFAULT $(if ($DatabaseRow.is_ansi_null_default_on) { 'ON' } else { 'OFF' });"
        }
        'ANSI_NULLS' = @{
            'Value' = if ($DatabaseRow.is_ansi_nulls_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET ANSI_NULLS $(if ($DatabaseRow.is_ansi_nulls_on) { 'ON' } else { 'OFF' });"
        }
        'ANSI_PADDING' = @{
            'Value' = if ($DatabaseRow.is_ansi_padding_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET ANSI_PADDING $(if ($DatabaseRow.is_ansi_padding_on) { 'ON' } else { 'OFF' });"
        }
        'ANSI_WARNINGS' = @{
            'Value' = if ($DatabaseRow.is_ansi_warnings_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET ANSI_WARNINGS $(if ($DatabaseRow.is_ansi_warnings_on) { 'ON' } else { 'OFF' });"
        }
        'ARITHABORT' = @{
            'Value' = if ($DatabaseRow.is_arithabort_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET ARITHABORT $(if ($DatabaseRow.is_arithabort_on) { 'ON' } else { 'OFF' });"
        }
        'CONCAT_NULL_YIELDS_NULL' = @{
            'Value' = if ($DatabaseRow.is_concat_null_yields_null_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET CONCAT_NULL_YIELDS_NULL $(if ($DatabaseRow.is_concat_null_yields_null_on) { 'ON' } else { 'OFF' });"
        }
        'CURSOR_CLOSE_ON_COMMIT' = @{
            'Value' = if ($DatabaseRow.is_cursor_close_on_commit_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET CURSOR_CLOSE_ON_COMMIT $(if ($DatabaseRow.is_cursor_close_on_commit_on) { 'ON' } else { 'OFF' });"
        }
        'DATE_CORRELATION_OPTIMIZATION' = @{
            'Value' = if ($DatabaseRow.is_date_correlation_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET DATE_CORRELATION_OPTIMIZATION $(if ($DatabaseRow.is_date_correlation_on) { 'ON' } else { 'OFF' });"
        }
        'NUMERIC_ROUNDABORT' = @{
            'Value' = if ($DatabaseRow.is_numeric_roundabort_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET NUMERIC_ROUNDABORT $(if ($DatabaseRow.is_numeric_roundabort_on) { 'ON' } else { 'OFF' });"
        }
        'QUOTED_IDENTIFIER' = @{
            'Value' = if ($DatabaseRow.is_quoted_identifier_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET QUOTED_IDENTIFIER $(if ($DatabaseRow.is_quoted_identifier_on) { 'ON' } else { 'OFF' });"
        }
        'RECURSIVE_TRIGGERS' = @{
            'Value' = if ($DatabaseRow.is_recursive_triggers_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET RECURSIVE_TRIGGERS $(if ($DatabaseRow.is_recursive_triggers_on) { 'ON' } else { 'OFF' });"
        }
        'AUTO_CREATE_STATISTICS_INCREMENTAL' = @{
            'Value' = if ($DatabaseRow.is_auto_create_stats_incremental_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET AUTO_CREATE_STATISTICS_INCREMENTAL $(if ($DatabaseRow.is_auto_create_stats_incremental_on) { 'ON' } else { 'OFF' });"
        }
        'ENCRYPTION' = @{
            'Value' = if ($DatabaseRow.is_encrypted) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET ENCRYPTION $(if ($DatabaseRow.is_encrypted) { 'ON' } else { 'OFF' });"
        }
        'HONOR_BROKER_PRIORITY' = @{
            'Value' = if ($DatabaseRow.is_honor_broker_priority_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET HONOR_BROKER_PRIORITY $(if ($DatabaseRow.is_honor_broker_priority_on) { 'ON' } else { 'OFF' });"
        }
        'PARAMETERIZATION' = @{
            'Value' = if ($DatabaseRow.is_parameterization_forced) { 'FORCED' } else { 'SIMPLE' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET PARAMETERIZATION $(if ($DatabaseRow.is_parameterization_forced) { 'FORCED' } else { 'SIMPLE' });"
        }
        'READ_COMMITTED_SNAPSHOT' = @{
            'Value' = if ($DatabaseRow.is_read_committed_snapshot_on) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET READ_COMMITTED_SNAPSHOT $(if ($DatabaseRow.is_read_committed_snapshot_on) { 'ON' } else { 'OFF' });"
        }
        'READ_ONLY' = @{
            'Value' = if ($DatabaseRow.is_read_only) { 'ON' } else { 'OFF' }
            'SQLCommand' = "ALTER DATABASE [$databaseName] SET READ_ONLY $(if ($DatabaseRow.is_read_only) { 'ON' } else { 'OFF' });"
        }
                'TRUSTWORTHY' = @{
                    'Value' = if ($DatabaseRow.is_trustworthy_on) { 'ON' } else { 'OFF' }
                    'SQLCommand' = "ALTER DATABASE [$databaseName] SET TRUSTWORTHY $(if ($DatabaseRow.is_trustworthy_on) { 'ON' } else { 'OFF' });"
                }
                # Additional advanced settings
                'RECOVERY_MODEL' = @{
                    'Value' = if ($null -ne $DatabaseRow.recovery_model_desc) { $DatabaseRow.recovery_model_desc } else { 'NONE' }
                    'SQLCommand' = "ALTER DATABASE [$databaseName] SET RECOVERY $(if ($null -ne $DatabaseRow.recovery_model_desc) { $DatabaseRow.recovery_model_desc } else { 'NONE' });"
                }
                'PAGE_VERIFY' = @{
                    'Value' = if ($null -ne $DatabaseRow.page_verify_option_desc) { $DatabaseRow.page_verify_option_desc } else { 'NONE' }
                    'SQLCommand' = "ALTER DATABASE [$databaseName] SET PAGE_VERIFY $(if ($null -ne $DatabaseRow.page_verify_option_desc) { $DatabaseRow.page_verify_option_desc } else { 'NONE' });"
                }
                'CONTAINMENT' = @{
                    'Value' = if ($null -ne $DatabaseRow.containment_desc) { $DatabaseRow.containment_desc } else { 'NONE' }
                    'SQLCommand' = "ALTER DATABASE [$databaseName] SET CONTAINMENT = $(if ($null -ne $DatabaseRow.containment_desc) { $DatabaseRow.containment_desc } else { 'NONE' });"
                }
                'TARGET_RECOVERY_TIME' = @{
                    'Value' = if ($null -ne $DatabaseRow.target_recovery_time_in_seconds) { $DatabaseRow.target_recovery_time_in_seconds.ToString() } else { '0' }
                    'SQLCommand' = "ALTER DATABASE [$databaseName] SET TARGET_RECOVERY_TIME = $(if ($null -ne $DatabaseRow.target_recovery_time_in_seconds) { $DatabaseRow.target_recovery_time_in_seconds } else { '0' }) SECONDS;"
                }
                # Additional options from SSMS
                'NESTED_TRIGGERS' = @{
                    'Value' = if ($DatabaseRow.is_recursive_triggers_on) { 'ON' } else { 'OFF' }
                    'SQLCommand' = "EXEC sp_configure 'nested triggers', $(if ($DatabaseRow.is_recursive_triggers_on) { '1' } else { '0' });"
                }
                'TRANSFORM_NOISE_WORDS' = @{
                    'Value' = 'OFF'  # Default value
                    'SQLCommand' = "EXEC sp_configure 'transform noise words', 0;"
                }
                'TWO_DIGIT_YEAR_CUTOFF' = @{
                    'Value' = '2049'  # Default value
                    'SQLCommand' = "EXEC sp_configure 'two digit year cutoff', 2049;"
                }
                'DEFAULT_LANGUAGE' = @{
                    'Value' = 'English'  # Default value
                    'SQLCommand' = "EXEC sp_configure 'default language', 0;"
                }
                'CURSOR_CLOSE_ON_COMMIT_DB' = @{
                    'Value' = if ($DatabaseRow.is_cursor_close_on_commit_on) { 'ON' } else { 'OFF' }
                    'SQLCommand' = "EXEC sp_configure 'cursor close on commit', $(if ($DatabaseRow.is_cursor_close_on_commit_on) { '1' } else { '0' });"
                }
                'DEFAULT_CURSOR' = @{
                    'Value' = 'GLOBAL'  # Default value
                    'SQLCommand' = "EXEC sp_configure 'default cursor', 0;"
                }
                'ALLOW_SNAPSHOT_ISOLATION' = @{
                    'Value' = 'OFF'  # Default value
                    'SQLCommand' = "ALTER DATABASE [$databaseName] SET ALLOW_SNAPSHOT_ISOLATION OFF;"
                }
                'CROSS_DATABASE_OWNERSHIP_CHAINING' = @{
                    'Value' = 'OFF'  # Default value
                    'SQLCommand' = "ALTER DATABASE [$databaseName] SET DB_CHAINING OFF;"
                }
                'DELAYED_DURABILITY' = @{
                    'Value' = 'DISABLED'  # Default value
                    'SQLCommand' = "ALTER DATABASE [$databaseName] SET DELAYED_DURABILITY = DISABLED;"
                }
                'PARAMETERIZATION_DB' = @{
                    'Value' = if ($DatabaseRow.is_parameterization_forced) { 'FORCED' } else { 'SIMPLE' }
                    'SQLCommand' = "ALTER DATABASE [$databaseName] SET PARAMETERIZATION $(if ($DatabaseRow.is_parameterization_forced) { 'FORCED' } else { 'SIMPLE' });"
                }
                'FILESTREAM_DIRECTORY_NAME' = @{
                    'Value' = 'NONE'  # Default value
                    'SQLCommand' = "ALTER DATABASE [$databaseName] SET FILESTREAM (DIRECTORY_NAME = 'NONE');"
                }
                'FILESTREAM_NON_TRANSACTED_ACCESS' = @{
                    'Value' = 'OFF'  # Default value
                    'SQLCommand' = "ALTER DATABASE [$databaseName] SET FILESTREAM (NON_TRANSACTED_ACCESS = OFF);"
                }
                'IS_LEDGER_DATABASE' = @{
                    'Value' = 'FALSE'  # Default value
                    'SQLCommand' = "-- Ledger database setting not available via ALTER DATABASE"
                }
            }
            
            # Create individual setting objects
            foreach ($optionName in $optionMappings.Keys) {
                $mapping = $optionMappings[$optionName]
                $settings += [PSCustomObject]@{
                    DATABASE_NAME = $databaseName
                    OPTION_NAME = $optionName
                    OPTION_VALUE = $mapping.Value
                    SQL_COMMAND = $mapping.SQLCommand
                }
            }
            
            return $settings
}
function Convert-DatabaseScopedConfigurationsToIndividualSettings {
    param($ConfigurationsTable)
    
    $settings = @()
    
    if ($ConfigurationsTable) {
        # Handle both DataTable and array inputs
        $rows = if ($ConfigurationsTable.GetType().Name -eq "DataTable") { $ConfigurationsTable.Rows } else { $ConfigurationsTable }
        
        if ($rows -and $rows.Count -gt 0) {
            foreach ($row in $rows) {
                $databaseName = $row.database_name
                $configName = $row.name
                $configValue = $row.value
                
                $settings += [PSCustomObject]@{
                    DATABASE_NAME = $databaseName
                    OPTION_NAME = "DSC_$configName"
                    OPTION_VALUE = $configValue.ToString()
                    SQL_COMMAND = "ALTER DATABASE [$databaseName] SET $configName = $($configValue.ToString());"
                }
            }
        }
    }
    
    return $settings
}

# Function to get file information
function Get-FileInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    -- Basic file information
    df.name,
    df.file_id,
    df.type_desc,
    df.physical_name,
    
    -- Size information
    df.size as size_8kb_pages,
    CAST(df.size * 8.0 / 1024 AS DECIMAL(15,2)) as size_mb,
    CAST(df.size * 8.0 / 1024 / 1024 AS DECIMAL(15,2)) as size_gb,
    df.max_size as max_size_8kb_pages,
    CASE 
        WHEN df.max_size = -1 THEN 'Unlimited'
        WHEN df.max_size = 268435456 THEN '2 TB'
        ELSE CAST(CAST(df.max_size * 8.0 / 1024 AS DECIMAL(15,2)) AS VARCHAR(20)) + ' MB'
    END as max_size_display,
    
    -- Growth settings
    df.growth as growth_8kb_pages,
    CASE 
        WHEN df.is_percent_growth = 1 THEN CAST(df.growth AS VARCHAR(10)) + '%'
        ELSE CAST(CAST(df.growth * 8.0 / 1024 AS DECIMAL(15,2)) AS VARCHAR(20)) + ' MB'
    END as growth_display,
    df.is_percent_growth,
    
    -- File properties
    df.is_media_read_only,
    df.is_read_only,
    df.is_sparse,
    df.is_name_reserved,
    
    -- Filegroup information
    fg.name as filegroup_name,
    fg.type as filegroup_type,
    fg.type_desc as filegroup_type_desc,
    fg.is_default,
    fg.is_system,
    
    -- Additional file properties
    df.state,
    df.state_desc,
    df.is_percent_growth,
    
    -- File stream information
    CASE 
        WHEN df.type = 2 THEN 'FILESTREAM'
        WHEN df.type = 3 THEN 'LOG'
        WHEN df.type = 0 THEN 'ROWS'
        ELSE 'UNKNOWN'
    END as file_type_category,
    
    -- Memory-optimized filegroup check
    CASE 
        WHEN fg.type = 'FX' THEN 'In-Memory OLTP'
        WHEN fg.type = 'FD' THEN 'Filestream'
        WHEN fg.type = 'FG' THEN 'Regular'
        ELSE 'System'
    END as filegroup_category,
    
    -- Create statement for file
    'ALTER DATABASE [' + DB_NAME() + '] ADD ' +
    CASE 
        WHEN df.type = 0 THEN 'FILE'
        WHEN df.type = 1 THEN 'LOG FILE'
        WHEN df.type = 2 THEN 'FILE'
        WHEN df.type = 3 THEN 'LOG FILE'
    END + ' (NAME = ''' + df.name + ''', FILENAME = ''' + df.physical_name + ''', SIZE = ' +
    CAST(CAST(df.size * 8.0 / 1024 AS DECIMAL(15,2)) AS VARCHAR(20)) + 'MB, MAXSIZE = ' +
    CASE 
        WHEN df.max_size = -1 THEN 'UNLIMITED'
        WHEN df.max_size = 268435456 THEN '2TB'
        ELSE CAST(CAST(df.max_size * 8.0 / 1024 AS DECIMAL(15,2)) AS VARCHAR(20)) + 'MB'
    END + ', FILEGROWTH = ' +
    CASE 
        WHEN df.is_percent_growth = 1 THEN CAST(df.growth AS VARCHAR(10)) + '%'
        ELSE CAST(CAST(df.growth * 8.0 / 1024 AS DECIMAL(15,2)) AS VARCHAR(20)) + 'MB'
    END + 
    CASE 
        WHEN fg.name IS NOT NULL THEN ', FILEGROUP = [' + fg.name + ']'
        ELSE ''
    END + ')' as CREATE_STATEMENT

FROM sys.database_files df
LEFT JOIN sys.filegroups fg ON df.data_space_id = fg.data_space_id
ORDER BY df.file_id
"@
    
    $result = Invoke-SqlQuery -Server $Server -Database $Database -Query $query
    # Ensure we always return a DataTable, even if there's only one row
    if ($result -and $result.GetType().Name -eq "DataRow") {
        $table = New-Object System.Data.DataTable
        # Clone the columns to avoid the "already belongs to another DataTable" error
        foreach ($column in $result.Table.Columns) {
            $newColumn = $table.Columns.Add($column.ColumnName, $column.DataType)
            $newColumn.AllowDBNull = $column.AllowDBNull
            $newColumn.MaxLength = $column.MaxLength
        }
        $table.ImportRow($result)
        return $table
    }
    return $result
}

# Function to get VLF count
function Get-VLFCount {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT COUNT(*) as VLF_COUNT
FROM sys.dm_db_log_info(DB_ID())
"@
    
    $result = Invoke-SqlQuery -Server $Server -Database $Database -Query $query
    if ($result -and $result.GetType().Name -eq "DataRow") {
        return $result.VLF_COUNT
    } elseif ($result -and $result.Rows.Count -gt 0) {
        return $result.Rows[0].VLF_COUNT
    } else {
        return 0
    }
}

# Function to get user information with role memberships
function Get-UserInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    u.name as USER_NAME,
    u.type_desc as USER_TYPE,
    u.create_date,
    u.modify_date,
    ISNULL(u.default_schema_name, '') as default_schema_name,
    STUFF((
        SELECT ', ' + r.name
        FROM sys.database_role_members rm
        INNER JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
        WHERE rm.member_principal_id = u.principal_id
        FOR XML PATH('')
    ), 1, 2, '') as ROLE_MEMBERSHIPS,
    STUFF((
        SELECT ', ' + p.permission_name + ' ON ' + 
               CASE 
                   WHEN p.class = 1 THEN ISNULL(OBJECT_SCHEMA_NAME(p.major_id), '') + '.' + ISNULL(OBJECT_NAME(p.major_id), '')
                   WHEN p.class = 3 THEN SCHEMA_NAME(p.major_id)
                   WHEN p.class = 0 THEN 'DATABASE'
                   ELSE 'UNKNOWN'
               END + ' (' + p.state_desc + ')'
        FROM sys.database_permissions p
        WHERE p.grantee_principal_id = u.principal_id
        FOR XML PATH('')
    ), 1, 2, '') as SECURABLES_PERMISSIONS,
    'CREATE USER [' + u.name + ']' + 
    CASE 
        WHEN u.type = 'S' THEN ' FROM LOGIN [' + ISNULL(l.name, 'N/A') + ']'
        WHEN u.type = 'U' THEN ' WITHOUT LOGIN'
        ELSE ''
    END +
    CASE 
        WHEN u.default_schema_name IS NOT NULL AND u.default_schema_name != '' 
        THEN ' WITH DEFAULT_SCHEMA = [' + u.default_schema_name + ']'
        ELSE ''
    END + ';' + CHAR(10) + CHAR(10) +
    '-- Role Memberships:' + CHAR(10) +
    ISNULL(STUFF((
        SELECT CHAR(10) + 'ALTER ROLE [' + r.name + '] ADD MEMBER [' + u.name + '];'
        FROM sys.database_role_members rm
        INNER JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
        WHERE rm.member_principal_id = u.principal_id
        FOR XML PATH('')
    ), 1, 1, ''), '-- No role memberships') + CHAR(10) + CHAR(10) +
    '-- Permissions:' + CHAR(10) +
    ISNULL(STUFF((
        SELECT CHAR(10) + p.state_desc + ' ' + p.permission_name + ' ON ' + 
               CASE 
                   WHEN p.class = 1 THEN '[' + ISNULL(OBJECT_SCHEMA_NAME(p.major_id), '') + '].[' + ISNULL(OBJECT_NAME(p.major_id), '') + ']'
                   WHEN p.class = 3 THEN 'SCHEMA::[' + SCHEMA_NAME(p.major_id) + ']'
                   WHEN p.class = 0 THEN 'DATABASE'
                   ELSE 'UNKNOWN'
               END + ' TO [' + u.name + '];'
        FROM sys.database_permissions p
        WHERE p.grantee_principal_id = u.principal_id
        FOR XML PATH('')
    ), 1, 1, ''), '-- No explicit permissions') as CREATE_STATEMENT
FROM sys.database_principals u
LEFT JOIN sys.server_principals l ON u.sid = l.sid
WHERE u.type IN ('S', 'U', 'G', 'C', 'K', 'E', 'X')
    AND u.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys')
ORDER BY u.name
"@
    
    $result = Invoke-SqlQuery -Server $Server -Database $Database -Query $query
    # Ensure we always return a DataTable, even if there's only one row
    if ($result -and $result.GetType().Name -eq "DataRow") {
        $table = New-Object System.Data.DataTable
        # Clone the columns to avoid the "already belongs to another DataTable" error
        foreach ($column in $result.Table.Columns) {
            $newColumn = $table.Columns.Add($column.ColumnName, $column.DataType)
            $newColumn.AllowDBNull = $column.AllowDBNull
            $newColumn.MaxLength = $column.MaxLength
        }
        $table.ImportRow($result)
        return $table
    }
    return $result
}

# Function to get role information
function Get-RoleInfo {
    param([string]$Server, [string]$Database)
    
    $query = @"
SELECT 
    r.name as ROLE_NAME,
    r.type_desc as ROLE_TYPE,
    r.create_date,
    r.modify_date,
    ISNULL(r.owning_principal_id, 0) as owning_principal_id,
    ISNULL(op.name, 'N/A') as OWNER_NAME,
    STUFF((
        SELECT ', ' + u.name
        FROM sys.database_role_members rm
        INNER JOIN sys.database_principals u ON rm.member_principal_id = u.principal_id
        WHERE rm.role_principal_id = r.principal_id
            AND u.type IN ('S', 'U', 'G', 'C', 'K', 'E', 'X')
        FOR XML PATH('')
    ), 1, 2, '') as ROLE_MEMBERS,
    STUFF((
        SELECT ', ' + p.permission_name + ' ON ' + 
               CASE 
                   WHEN p.class = 1 THEN ISNULL(OBJECT_SCHEMA_NAME(p.major_id), '') + '.' + ISNULL(OBJECT_NAME(p.major_id), '')
                   WHEN p.class = 3 THEN SCHEMA_NAME(p.major_id)
                   WHEN p.class = 0 THEN 'DATABASE'
                   ELSE 'UNKNOWN'
               END + ' (' + p.state_desc + ')'
        FROM sys.database_permissions p
        WHERE p.grantee_principal_id = r.principal_id
        FOR XML PATH('')
    ), 1, 2, '') as ROLE_PERMISSIONS,
    CASE 
        WHEN r.is_fixed_role = 1 THEN '-- Fixed database role: ' + r.name
        ELSE 'CREATE ROLE [' + r.name + ']' +
             CASE 
                 WHEN r.owning_principal_id IS NOT NULL AND op.name IS NOT NULL 
                 THEN ' AUTHORIZATION [' + op.name + ']'
                 ELSE ''
             END + ';' + CHAR(10) +
             '-- Members:' + CHAR(10) +
             ISNULL(STUFF((
                 SELECT CHAR(10) + 'ALTER ROLE [' + r.name + '] ADD MEMBER [' + u.name + '];'
                 FROM sys.database_role_members rm
                 INNER JOIN sys.database_principals u ON rm.member_principal_id = u.principal_id
                 WHERE rm.role_principal_id = r.principal_id
                     AND u.type IN ('S', 'U', 'G', 'C', 'K', 'E', 'X')
                 FOR XML PATH('')
             ), 1, 1, ''), '-- No members') + CHAR(10) + CHAR(10) +
             '-- Permissions:' + CHAR(10) +
             ISNULL(STUFF((
                 SELECT CHAR(10) + p.state_desc + ' ' + p.permission_name + ' ON ' + 
                        CASE 
                            WHEN p.class = 1 THEN '[' + ISNULL(OBJECT_SCHEMA_NAME(p.major_id), '') + '].[' + ISNULL(OBJECT_NAME(p.major_id), '') + ']'
                            WHEN p.class = 3 THEN 'SCHEMA::[' + SCHEMA_NAME(p.major_id) + ']'
                            WHEN p.class = 0 THEN 'DATABASE'
                            ELSE 'UNKNOWN'
                        END + ' TO [' + r.name + '];'
                 FROM sys.database_permissions p
                 WHERE p.grantee_principal_id = r.principal_id
                 FOR XML PATH('')
             ), 1, 1, ''), '-- No explicit permissions')
    END as CREATE_STATEMENT
FROM sys.database_principals r
LEFT JOIN sys.database_principals op ON r.owning_principal_id = op.principal_id
WHERE r.type = 'R'
    AND r.name NOT IN ('public')
ORDER BY r.name
"@
    
    $result = Invoke-SqlQuery -Server $Server -Database $Database -Query $query
    # Ensure we always return a DataTable, even if there's only one row
    if ($result -and $result.GetType().Name -eq "DataRow") {
        $table = New-Object System.Data.DataTable
        # Clone the columns to avoid the "already belongs to another DataTable" error
        foreach ($column in $result.Table.Columns) {
            $newColumn = $table.Columns.Add($column.ColumnName, $column.DataType)
            $newColumn.AllowDBNull = $column.AllowDBNull
            $newColumn.MaxLength = $column.MaxLength
        }
        $table.ImportRow($result)
        return $table
    }
    return $result
}
# Function to compare two datasets
function Compare-Datasets {
    param(
        $Source,
        $Target,
        [string]$KeyColumns,
        [string]$IgnoreColumns = ""
    )
    
    $comparison = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
    
    if ($null -eq $Source -and $null -eq $Target) {
        return $comparison
    }
    
    if ($null -eq $Source) {
        if ($Target) {
            if ($Target.GetType().Name -eq "DataTable") {
                if ($Target.Rows.Count -gt 0) {
                    $comparison.TargetOnly = @($Target.Rows)
                }
            } else {
            $comparison.TargetOnly = @($Target)
            }
        }
        return $comparison
    }
    
    if ($null -eq $Target) {
        if ($Source) {
            if ($Source.GetType().Name -eq "DataTable") {
                if ($Source.Rows.Count -gt 0) {
                    $comparison.SourceOnly = @($Source.Rows)
                }
            } else {
            $comparison.SourceOnly = @($Source)
            }
        }
        return $comparison
    }
    
    # Create hashtables for quick lookup
    $sourceHash = @{}
    $targetHash = @{}
    
    # Handle both DataTable and DataRow objects
    $sourceRows = if ($Source.GetType().Name -eq "DataTable") { $Source.Rows } else { @($Source) }
    $targetRows = if ($Target.GetType().Name -eq "DataTable") { $Target.Rows } else { @($Target) }
    
    foreach ($row in $sourceRows) {
        $key = ($KeyColumns -split ',' | ForEach-Object { $row[$_.Trim()] }) -join '|'
        $sourceHash[$key] = $row
    }
    
    foreach ($row in $targetRows) {
        $key = ($KeyColumns -split ',' | ForEach-Object { $row[$_.Trim()] }) -join '|'
        $targetHash[$key] = $row
    }
    
    # Find matches and differences
    foreach ($key in $sourceHash.Keys) {
        if ($targetHash.ContainsKey($key)) {
            $sourceRow = $sourceHash[$key]
            $targetRow = $targetHash[$key]
            
            # Compare all columns for differences (excluding ignored columns)
            $hasDifferences = $false
            $differences = @{}
            $ignoreList = @()
            if ($IgnoreColumns -and $IgnoreColumns.Trim() -ne "") {
                $ignoreList = $IgnoreColumns -split ',' | ForEach-Object { $_.Trim() }
            }
            
                    foreach ($columnName in $sourceRow.Table.Columns) {
                # Skip ignored columns
                if ($ignoreList -contains $columnName.ColumnName) {
                    continue
                }
                
                        $sourceValue = $sourceRow[$columnName.ColumnName]
                        $targetValue = $targetRow[$columnName.ColumnName]
                
                if ($sourceValue -ne $targetValue) {
                    $hasDifferences = $true
                            $differences[$columnName.ColumnName] = @{
                        Source = $sourceValue
                        Target = $targetValue
                    }
                }
            }
            
            if ($hasDifferences) {
                $comparison.Differences += @{
                    Key = $key
                    Source = $sourceRow
                    Target = $targetRow
                    Differences = $differences
                }
            } else {
                $comparison.Matches += $sourceRow
            }
        } else {
            $comparison.SourceOnly += $sourceHash[$key]
        }
    }
    
    foreach ($key in $targetHash.Keys) {
        if (-not $sourceHash.ContainsKey($key)) {
            $comparison.TargetOnly += $targetHash[$key]
        }
    }
    
    return $comparison
}

# Function to create HTML report
function New-HTMLReport {
    param(
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$TargetServer,
        [string]$TargetDatabase,
        [string]$OutputPath
    )
    
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Database Schema Drift Detection Report</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: #f5f5f5;
            color: #333;
        }
        
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin-bottom: 30px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }
        
        .header h1 {
            margin: 0;
            font-size: 2.5em;
            font-weight: 300;
        }
        
        .header p {
            margin: 10px 0 0 0;
            font-size: 1.2em;
            opacity: 0.9;
        }
        .header-controls {
            margin-top: 15px;
            display: flex;
            gap: 10px;
            flex-wrap: wrap;
        }
        .sort-btn {
            background: rgba(255,255,255,0.15);
            color: #fff;
            border: 1px solid rgba(255,255,255,0.35);
            padding: 8px 12px;
            border-radius: 6px;
            cursor: pointer;
            transition: background 0.2s ease, transform 0.1s ease;
        }
        .sort-btn:hover { background: rgba(255,255,255,0.25); }
        .sort-btn:active { transform: scale(0.98); }
        
        /* Floating expand/collapse button */
        .float-toggle {
            position: fixed;
            right: 24px;
            bottom: 24px;
            z-index: 1000;
        }
        .float-toggle button {
            background: #2b7cff;
            color: #fff;
            border: none;
            padding: 12px 16px;
            border-radius: 24px;
            box-shadow: 0 6px 12px rgba(0,0,0,0.15);
            cursor: pointer;
            font-weight: 600;
        }
        .float-toggle button:hover { filter: brightness(1.05); }
        .float-toggle button:active { transform: translateY(1px); }
        
        .summary {
            background: white;
            padding: 25px;
            border-radius: 10px;
            margin-bottom: 30px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        
        .summary h2 {
            margin: 0 0 20px 0;
            color: #333;
            font-size: 1.8em;
            text-align: center;
        }
        
        .summary-cards {
            display: flex;
            flex-wrap: wrap;
            gap: 25px;
            margin-top: 20px;
            position: relative; /* helps FLIP look stable */
            /* removed contain to avoid brief paint glitches during animations */
        }
        
        .summary-card {
            background: white;
            border-radius: 8px;
            padding: 20px;
            border: 1px solid #dee2e6;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            transition: transform 0.2s ease;
            cursor: pointer;
            min-height: 200px;
            flex: 0 0 calc((100% - (25px * 4)) / 5);
            box-sizing: border-box;
            will-change: transform;
            backface-visibility: hidden;
            user-select: none;
            -webkit-user-select: none;
            -moz-user-select: none;
            -ms-user-select: none;
        }
        
        .summary-card:hover {
            transform: translateY(-2px);
            box-shadow: 0 4px 8px rgba(0,0,0,0.15);
        }
        .summary-card.selected {
            border: 2px solid #3b82f6; /* blue */
            box-shadow: 0 0 0 3px rgba(59,130,246,0.2);
            position: relative;
        }
        .summary-card .check-badge {
            position: absolute;
            top: 6px;
            left: 8px; /* place on the left */
            width: 24px;
            height: 24px;
            border-radius: 50%;
            background-color: #3b82f6; /* blue circle */
            background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'><path fill='white' d='M9 16.2 5.5 12.7 4 14.2l5 5 11-11-1.5-1.5z'/></svg>");
            background-repeat: no-repeat;
            background-position: center;
            background-size: 16px 16px;
            display: none;
            align-items: center;
            justify-content: center;
            color: transparent; /* hide any inner text */
            z-index: 2;
        }
        .summary-card.selected .check-badge { display: block; }
        
        .summary-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 15px;
            padding-bottom: 10px;
            padding-left: 44px; /* space for larger left badge */
            border-bottom: 2px solid #dee2e6;
            user-select: none;
            -webkit-user-select: none;
            -moz-user-select: none;
            -ms-user-select: none;
        }
        
        .summary-header h3 {
            margin: 0;
            font-size: 1.2em;
            color: #495057;
        }
        .total-count {
            background: #007bff;
            color: white;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 0.85em;
            font-weight: bold;
        }
        
        .summary-breakdown {
            display: grid;
            grid-template-columns: repeat(2, 1fr);
            gap: 8px;
            user-select: none;
            -webkit-user-select: none;
            -moz-user-select: none;
            -ms-user-select: none;
            margin-top: 15px;
        }
        
        .breakdown-item {
            position: relative;
            display: flex;
            align-items: center;
            border-radius: 8px;
            font-size: 0.9em;
            overflow: hidden;
            cursor: pointer;
            transition: all 0.3s ease;
            background: rgba(255, 255, 255, 0.9);
            border: 1px solid rgba(255, 255, 255, 0.3);
            backdrop-filter: blur(10px);
            box-shadow: 0 4px 15px rgba(0, 0, 0, 0.1), 
                        inset 0 1px 0 rgba(255, 255, 255, 0.6);
            min-height: 44px;
        }
        
        .breakdown-item::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            bottom: 0;
            width: var(--progress-width, 0%);
            transition: width 0.8s ease-out;
            z-index: 1;
            pointer-events: none;
            border-radius: 8px;
        }
        
        .breakdown-item::after {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            height: 50%;
            background: linear-gradient(180deg, 
                rgba(255, 255, 255, 0.4) 0%, 
                rgba(255, 255, 255, 0.1) 100%);
            pointer-events: none;
            z-index: 3;
            border-radius: 8px;
        }
        
        .breakdown-item:hover {
            transform: translateY(-2px);
            box-shadow: 0 6px 20px rgba(0, 0, 0, 0.15), 
                        inset 0 1px 0 rgba(255, 255, 255, 0.8);
        }
        
        .breakdown-item .count {
            font-weight: bold;
            font-size: 1.1em;
            padding: 10px 12px;
            color: white;
            text-align: center;
            min-width: 45px;
            position: relative;
            z-index: 2;
            text-shadow: 0 1px 2px rgba(0, 0, 0, 0.3);
        }
        
        .breakdown-item .label {
            font-size: 0.85em;
            font-weight: 600;
            padding: 10px 12px;
            flex: 1;
            text-align: left;
            position: relative;
            z-index: 2;
        }
        
        /* Progress bar background for each type */
        .breakdown-item .progress-fill {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            bottom: 0;
            width: var(--progress-width, 0%);
            transition: width 0.8s ease-out;
            z-index: 1;
        }
        .breakdown-item.match .count {
            background: linear-gradient(135deg, #28a745 0%, #34ce57 100%);
            box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.3);
        }
        
        .breakdown-item.match .label {
            color: #1e7e34;
        }
        .breakdown-item.source-only .count {
            background: linear-gradient(135deg, #ffc107 0%, #ffd54f 100%);
            color: #212529;
            box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.4);
        }
        
        .breakdown-item.source-only .label {
            color: #856404;
        }
        
        .breakdown-item.target-only .count {
            background: linear-gradient(135deg, #17a2b8 0%, #26c6da 100%);
            box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.3);
        }
        
        .breakdown-item.target-only .label {
            color: #0c5460;
        }
        .breakdown-item.mismatch .count {
            background: linear-gradient(135deg, #dc3545 0%, #f44336 100%);
            box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.3);
        }
        
        .breakdown-item.mismatch .label {
            color: #721c24;
        }
        
        /* Progress bar backgrounds */
        .breakdown-item.match::before {
            background: linear-gradient(90deg, 
                rgba(40, 167, 69, 0.25) 0%, 
                rgba(40, 167, 69, 0.1) 100%);
        }
        
        .breakdown-item.source-only::before {
            background: linear-gradient(90deg, 
                rgba(255, 193, 7, 0.25) 0%, 
                rgba(255, 193, 7, 0.1) 100%);
        }
        
        .breakdown-item.target-only::before {
            background: linear-gradient(90deg, 
                rgba(23, 162, 184, 0.25) 0%, 
                rgba(23, 162, 184, 0.1) 100%);
        }
        
        .breakdown-item.mismatch::before {
            background: linear-gradient(90deg, 
                rgba(220, 53, 69, 0.25) 0%, 
                rgba(220, 53, 69, 0.1) 100%);
        }
        
        /* Native browser tooltips work with title attribute - no custom CSS needed */
        
        .summary-breakdown {
            pointer-events: auto;
        }
        
        .section {
            background: white;
            margin-bottom: 30px;
            border-radius: 10px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            overflow: hidden;
        }
        
        .section-header {
            background: #667eea;
            color: white;
            padding: 20px;
            cursor: pointer;
            display: flex;
            justify-content: space-between;
            align-items: center;
            transition: background-color 0.3s;
            user-select: none;
        }
        
        .section-header:hover {
            background: #5a6fd8;
        }
        
        .section-header h2 {
            margin: 0;
            font-size: 1.5em;
        }
        
        .toggle {
            font-weight: bold;
            font-size: 1.2em;
            background: rgba(255,255,255,0.2);
            padding: 5px 10px;
            border-radius: 4px;
            transition: all 0.3s ease;
        }
        
        .toggle:hover {
            background: rgba(255,255,255,0.3);
        }
        
        .section-content {
            padding: 20px;
            overflow: hidden;
            transition: all 0.3s ease-out;
            max-height: 0;
            opacity: 0;
        }
        
        .section-content.expanded {
            max-height: 5000px;
            opacity: 1;
        }
        
        .filter-container {
            background: #f8f9fa;
            padding: 15px;
            border: 1px solid #dee2e6;
            border-radius: 5px;
            margin-bottom: 20px;
            display: flex;
            flex-direction: column;
            gap: 15px;
        }
        
        .filter-controls {
            display: flex;
            gap: 15px;
            align-items: center;
        }
        
        .status-filters {
            display: flex;
            gap: 15px;
            flex-wrap: wrap;
            align-items: center;
        }
        
        .filter-stats {
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .filter-input {
            flex: 1;
            padding: 8px 12px;
            border: 1px solid #ced4da;
            border-radius: 4px;
            font-size: 14px;
            transition: border-color 0.3s ease;
        }
        
        .filter-input:focus {
            outline: none;
            border-color: #007bff;
            box-shadow: 0 0 0 2px rgba(0,123,255,0.25);
        }
        
        .sort-select {
            padding: 8px 12px;
            border: 1px solid #ced4da;
            border-radius: 4px;
            font-size: 14px;
            background: white;
            cursor: pointer;
            min-width: 120px;
        }
        
        .sort-select:focus {
            outline: none;
            border-color: #007bff;
            box-shadow: 0 0 0 2px rgba(0,123,255,0.25);
        }
        
        .status-checkbox {
            display: flex;
            align-items: center;
            gap: 5px;
            cursor: pointer;
            font-size: 12px;
        }
        
        .status-checkbox input[type="checkbox"] {
            margin: 0;
            cursor: pointer;
        }
        
        .status-checkbox .status-badge {
            font-size: 10px;
            padding: 2px 6px;
        }
        .filter-stats {
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .filter-count {
            font-size: 12px;
            color: #6c757d;
            min-width: 80px;
        }
        
        .clear-filter {
            padding: 6px 12px;
            background: #6c757d;
            color: white;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 12px;
            transition: background-color 0.3s ease;
        }
        
        .clear-filter:hover {
            background: #5a6268;
        }
        
        .filtered-row {
            display: none !important;
        }
        
        .section-header.collapsed .toggle {
            transform: rotate(-90deg);
        }
        
        .section-content {
            padding: 20px;
            overflow: visible;
            transition: all 0.3s ease-out;
            opacity: 1;
            max-height: none;
        }
        
        .section-content.collapsed {
            max-height: 0;
            overflow: hidden;
            padding: 0;
            opacity: 0;
        }
        .comparison-table {
            width: 100%;
            border-collapse: collapse;
            margin: 0;
        }
        
        .comparison-table th {
            background: #f8f9fa;
            padding: 15px;
            text-align: left;
            font-weight: 600;
            color: #495057;
            border-bottom: 2px solid #dee2e6;
        }
        
        .comparison-table td {
            padding: 12px 15px;
            border-bottom: 1px solid #dee2e6;
            vertical-align: top;
            word-wrap: break-word;
            word-break: break-all;
            overflow-wrap: anywhere;
            max-width: 500px;
            white-space: normal;
        }
        
        .comparison-table tr:hover {
            background: #f8f9fa;
        }
        
        .match {
            background-color: #d4edda !important;
            color: #155724;
        }
        
        .mismatch {
            background-color: #f8d7da !important;
            color: #721c24;
        }
        
        .source-only {
            background-color: #fff3cd !important;
            color: #856404;
        }
        
        .target-only {
            background-color: #cce5ff !important;
            color: #004085;
        }
        
        .status-badge {
            display: inline-block;
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 0.8em;
            font-weight: 600;
            text-transform: uppercase;
        }
        
        .status-match {
            background: #28a745;
            color: white;
        }
        
        .status-mismatch {
            background: #dc3545;
            color: white;
        }
        
        .db-badge {
            padding: 2px 6px;
            border-radius: 3px;
            font-size: 10px;
            font-weight: bold;
            margin: 0 2px;
        }
        
        .db-source {
            background: #6f42c1;
            color: white;
        }
        
        .db-target {
            background: #fd7e14;
            color: white;
        }
        
        .status-source-only {
            background: #ffc107;
            color: #212529;
        }
        
        .status-target-only {
            background: #17a2b8;
            color: white;
        }
        
        .export-buttons {
            position: fixed;
            top: 20px;
            right: 20px;
            z-index: 1000;
        }
        
        .export-btn {
            background: #28a745;
            color: white;
            border: none;
            padding: 12px 20px;
            border-radius: 6px;
            cursor: pointer;
            font-size: 14px;
            font-weight: 600;
            margin-left: 10px;
            transition: background-color 0.3s;
        }
        
        .export-btn:hover {
            background: #218838;
        }
        
        .export-btn.excel {
            background: #007bff;
        }
        
        .export-btn.excel:hover {
            background: #0056b3;
        }
        .loading {
            text-align: center;
            padding: 40px;
            color: #666;
        }
        
        .spinner {
            border: 4px solid #f3f3f3;
            border-top: 4px solid #667eea;
            border-radius: 50%;
            width: 40px;
            height: 40px;
            animation: spin 1s linear infinite;
            margin: 0 auto 20px;
        }
        
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        .no-data {
            text-align: center;
            padding: 40px;
            color: #666;
            font-style: italic;
        }
        
        .details-row {
            background: #f8f9fa;
        }
        .details-row td {
            padding: 8px 15px 8px 30px;
            font-size: 0.9em;
            color: #666;
        }
        
        .column-diff {
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .column-diff .source {
            color: #dc3545;
            font-weight: 600;
        }
        
        .column-diff .target {
            color: #28a745;
            font-weight: 600;
        }
        
        .column-diff .arrow {
            margin: 0 10px;
            color: #666;
        }
        
        /* Function Code Viewer Styles */
        .view-code-btn {
            background: #17a2b8;
            color: white;
            border: none;
            padding: 4px 8px;
            border-radius: 4px;
            cursor: pointer;
            font-size: 12px;
            margin-left: 8px;
            transition: background-color 0.3s;
            display: inline-block;
            max-width: 100px;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
            vertical-align: middle;
        }
        
        .view-code-btn:hover {
            background: #138496;
        }
        
        .code-modal {
            display: none;
            position: fixed;
            z-index: 1000;
            left: 0;
            top: 0;
            width: 100%;
            height: 100%;
            background-color: rgba(0,0,0,0.5);
            backdrop-filter: blur(2px);
        }
        
        .code-modal-content {
            background-color: #fefefe;
            margin: 2% auto;
            padding: 0;
            border: none;
            border-radius: 8px;
            width: 95%;
            max-width: 1400px;
            height: 90%;
            max-height: 800px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.3);
            display: flex;
            flex-direction: column;
        }
        
        .code-modal-header {
            background: #343a40;
            color: white;
            padding: 15px 20px;
            border-radius: 8px 8px 0 0;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .code-modal-title {
            font-size: 18px;
            font-weight: 600;
            margin: 0;
        }
        
        .code-modal-close {
            color: white;
            font-size: 28px;
            font-weight: bold;
            cursor: pointer;
            line-height: 1;
            transition: opacity 0.3s;
        }
        
        .code-modal-close:hover {
            opacity: 0.7;
        }
        
        .code-comparison-container {
            flex: 1;
            display: flex;
            height: calc(100% - 60px);
            overflow: hidden;
        }
        
        .code-panel {
            flex: 1;
            display: flex;
            flex-direction: column;
            border-right: 1px solid #dee2e6;
        }
        
        .code-panel:last-child {
            border-right: none;
        }
        
        .code-panel-header {
            background: #f8f9fa;
            padding: 10px 15px;
            border-bottom: 1px solid #dee2e6;
            font-weight: 600;
            font-size: 14px;
            color: #495057;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        
        .copy-code-btn {
            background: #007bff;
            color: white;
            border: none;
            padding: 4px 8px;
            border-radius: 3px;
            font-size: 11px;
            cursor: pointer;
            transition: background-color 0.2s;
        }
        
        .copy-code-btn:hover {
            background: #0056b3;
        }
        
        .copy-code-btn:active {
            background: #004085;
        }
        
        .copy-code-btn.copied {
            background: #28a745;
        }
        
        .code-panel-content {
            flex: 1;
            overflow: auto;
            padding: 0;
            background: #2d3748;
            position: relative;
        }
        
        .code-block {
            background: #2d3748;
            color: #e2e8f0;
            padding: 0;
            font-family: 'Courier New', monospace;
            font-size: 13px;
            line-height: 1.5;
            white-space: pre-wrap;
            word-wrap: break-word;
            margin: 0;
            overflow: visible;
            height: auto;
            min-height: 100%;
            box-sizing: border-box;
            counter-reset: line-number;
        }
        
        .code-line {
            display: flex;
            align-items: flex-start;
            min-height: 1.5em;
        }
        .line-number {
            background: #374151;
            color: #9ca3af;
            padding: 0 12px;
            margin-right: 12px;
            min-width: 40px;
            text-align: right;
            font-size: 12px;
            line-height: 1.5;
            border-right: 1px solid #4b5563;
            user-select: none;
            flex-shrink: 0;
            counter-increment: line-number;
        }
        .line-number::before {
            content: counter(line-number);
        }
        
        .line-content {
            flex: 1;
            padding: 0 4px;
            word-wrap: break-word;
            word-break: break-all;
            overflow-wrap: anywhere;
            white-space: pre-wrap;
        }
        
        .code-diff-highlight {
            background: rgba(255, 193, 7, 0.2);
            border-left: 3px solid #ffc107;
            padding-left: 5px;
        }
        
        .code-added {
            background: rgba(40, 167, 69, 0.2);
            border-left: 3px solid #28a745;
            padding-left: 5px;
        }
        
        .code-removed {
            background: rgba(220, 53, 69, 0.2);
            border-left: 3px solid #dc3545;
            padding-left: 5px;
        }
    </style>
</head>
<body>
    <!-- Function Code Viewer Modal -->
    <div id="codeModal" class="code-modal">
        <div class="code-modal-content">
            <div class="code-modal-header">
                <h3 class="code-modal-title" id="codeModalTitle">Function Code Comparison</h3>
                <span class="code-modal-close" onclick="closeCodeModal()">&times;</span>
                </div>
            <div class="code-comparison-container">
                <div class="code-panel">
                    <div class="code-panel-header">
                        <span id="sourcePanelHeader">Source Database</span>
                        <button class="copy-code-btn" onclick="copyCode('sourceCodeBlock', this)">Copy</button>
                        </div>
                    <div class="code-panel-content">
                        <div class="code-block" id="sourceCodeBlock"></div>
                        </div>
                    </div>
                <div class="code-panel">
                    <div class="code-panel-header">
                        <span id="targetPanelHeader">Target Database</span>
                        <button class="copy-code-btn" onclick="copyCode('targetCodeBlock', this)">Copy</button>
                        </div>
                    <div class="code-panel-content">
                        <div class="code-block" id="targetCodeBlock"></div>
                        </div>
                    </div>
                </div>
        </div>
    </div>

    <div class="export-buttons">
        <button class="export-btn" onclick="exportToExcel()">Export to Excel</button>
        <button class="export-btn" onclick="exportToPDF()">Export to PDF</button>
    </div>
    
    <div class="float-toggle">
        <button id="toggleAllBtn" onclick="toggleAllSections()">Expand All</button>
    </div>
    
    <div class="header">
        <h1>Database Schema Drift Detection Report</h1>
        <p>Source: $SourceServer.$SourceDatabase | Target: $TargetServer.$TargetDatabase</p>
        <p>Generated on: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
        <div class="header-controls">
            <button id="sort-alpha-btn" class="sort-btn" title="Arrange cards alphabetically" onclick="window.sortAlphaAndSections && window.sortAlphaAndSections()">Sort A-Z</button>
            <button id="sort-category-btn" class="sort-btn" title="Arrange cards by category" onclick="window.sortCategoryAndSections && window.sortCategoryAndSections()">Sort by Category</button>
        </div>
    </div>
    <div class="summary">
        <h2>Schema Drift Summary</h2>
        <div id="summaryCards" class="summary-cards">
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('Schemas')" oncontextmenu="return markSummarySelected(event, this, 'Schemas')">
                <div class="summary-header">
                    <h3>Schemas</h3>
                    <span class="check-badge"></span>
                    <span class="total-count">$($global:ComparisonData.Schemas.Matches.Count + $global:ComparisonData.Schemas.SourceOnly.Count + $global:ComparisonData.Schemas.TargetOnly.Count + $global:ComparisonData.Schemas.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('Schemas', 'match', event)" title="Schemas matching across databases">
                        <span class="count" style="width: $($total = $global:ComparisonData.Schemas.Matches.Count + $global:ComparisonData.Schemas.SourceOnly.Count + $global:ComparisonData.Schemas.TargetOnly.Count + $global:ComparisonData.Schemas.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Schemas.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Schemas.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('Schemas', 'source-only', event)" title="Schemas only in source">
                        <span class="count" style="width: $($total = $global:ComparisonData.Schemas.Matches.Count + $global:ComparisonData.Schemas.SourceOnly.Count + $global:ComparisonData.Schemas.TargetOnly.Count + $global:ComparisonData.Schemas.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Schemas.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Schemas.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('Schemas', 'target-only', event)" title="Schemas only in target">
                        <span class="count" style="width: $($total = $global:ComparisonData.Schemas.Matches.Count + $global:ComparisonData.Schemas.SourceOnly.Count + $global:ComparisonData.Schemas.TargetOnly.Count + $global:ComparisonData.Schemas.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Schemas.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Schemas.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('Schemas', 'mismatch', event)" title="Schemas with differences">
                        <span class="count" style="width: $($total = $global:ComparisonData.Schemas.Matches.Count + $global:ComparisonData.Schemas.SourceOnly.Count + $global:ComparisonData.Schemas.TargetOnly.Count + $global:ComparisonData.Schemas.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Schemas.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Schemas.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('tables')" oncontextmenu="return markSummarySelected(event, this, 'tables')">
                <div class="summary-header">
                    <h3>Tables</h3>
                    <span class="check-badge"></span>
                    <span class="total-count">$($global:ComparisonData.Tables.Matches.Count + $global:ComparisonData.Tables.SourceOnly.Count + $global:ComparisonData.Tables.TargetOnly.Count + $global:ComparisonData.Tables.Differences.Count) total</span>
            </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('tables', 'match', event)" title="Tables that are identical in both databases ($($global:ComparisonData.Tables.Matches.Count) out of $($global:ComparisonData.Tables.Matches.Count + $global:ComparisonData.Tables.SourceOnly.Count + $global:ComparisonData.Tables.TargetOnly.Count + $global:ComparisonData.Tables.Differences.Count))">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Tables.Matches.Count / ($global:ComparisonData.Tables.Matches.Count + $global:ComparisonData.Tables.SourceOnly.Count + $global:ComparisonData.Tables.TargetOnly.Count + $global:ComparisonData.Tables.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Tables.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('tables', 'source-only', event)" title="Tables that exist only in the source database ($($global:ComparisonData.Tables.SourceOnly.Count) out of $($global:ComparisonData.Tables.Matches.Count + $global:ComparisonData.Tables.SourceOnly.Count + $global:ComparisonData.Tables.TargetOnly.Count + $global:ComparisonData.Tables.Differences.Count))">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Tables.SourceOnly.Count / ($global:ComparisonData.Tables.Matches.Count + $global:ComparisonData.Tables.SourceOnly.Count + $global:ComparisonData.Tables.TargetOnly.Count + $global:ComparisonData.Tables.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Tables.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('tables', 'target-only', event)" title="Tables that exist only in the target database ($($global:ComparisonData.Tables.TargetOnly.Count) out of $($global:ComparisonData.Tables.Matches.Count + $global:ComparisonData.Tables.SourceOnly.Count + $global:ComparisonData.Tables.TargetOnly.Count + $global:ComparisonData.Tables.Differences.Count))">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Tables.TargetOnly.Count / ($global:ComparisonData.Tables.Matches.Count + $global:ComparisonData.Tables.SourceOnly.Count + $global:ComparisonData.Tables.TargetOnly.Count + $global:ComparisonData.Tables.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Tables.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('tables', 'mismatch', event)" title="Tables that have differences between source and target databases ($($global:ComparisonData.Tables.Differences.Count) out of $($global:ComparisonData.Tables.Matches.Count + $global:ComparisonData.Tables.SourceOnly.Count + $global:ComparisonData.Tables.TargetOnly.Count + $global:ComparisonData.Tables.Differences.Count))">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Tables.Differences.Count / ($global:ComparisonData.Tables.Matches.Count + $global:ComparisonData.Tables.SourceOnly.Count + $global:ComparisonData.Tables.TargetOnly.Count + $global:ComparisonData.Tables.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Tables.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('columns')" oncontextmenu="return markSummarySelected(event, this, 'columns')">
                <div class="summary-header">
                    <h3>Columns</h3>
                    <span class="check-badge"></span>
                    <span class="total-count">$($global:ComparisonData.Columns.Matches.Count + $global:ComparisonData.Columns.SourceOnly.Count + $global:ComparisonData.Columns.TargetOnly.Count + $global:ComparisonData.Columns.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('columns', 'match', event)" title="Columns that are identical in both databases ($($global:ComparisonData.Columns.Matches.Count) out of $($global:ComparisonData.Columns.Matches.Count + $global:ComparisonData.Columns.SourceOnly.Count + $global:ComparisonData.Columns.TargetOnly.Count + $global:ComparisonData.Columns.Differences.Count))">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Columns.Matches.Count / ($global:ComparisonData.Columns.Matches.Count + $global:ComparisonData.Columns.SourceOnly.Count + $global:ComparisonData.Columns.TargetOnly.Count + $global:ComparisonData.Columns.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Columns.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('columns', 'source-only', event)" title="Columns that exist only in the source database ($($global:ComparisonData.Columns.SourceOnly.Count) out of $($global:ComparisonData.Columns.Matches.Count + $global:ComparisonData.Columns.SourceOnly.Count + $global:ComparisonData.Columns.TargetOnly.Count + $global:ComparisonData.Columns.Differences.Count))">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Columns.SourceOnly.Count / ($global:ComparisonData.Columns.Matches.Count + $global:ComparisonData.Columns.SourceOnly.Count + $global:ComparisonData.Columns.TargetOnly.Count + $global:ComparisonData.Columns.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Columns.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('columns', 'target-only', event)" title="Columns that exist only in the target database ($($global:ComparisonData.Columns.TargetOnly.Count) out of $($global:ComparisonData.Columns.Matches.Count + $global:ComparisonData.Columns.SourceOnly.Count + $global:ComparisonData.Columns.TargetOnly.Count + $global:ComparisonData.Columns.Differences.Count))">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Columns.TargetOnly.Count / ($global:ComparisonData.Columns.Matches.Count + $global:ComparisonData.Columns.SourceOnly.Count + $global:ComparisonData.Columns.TargetOnly.Count + $global:ComparisonData.Columns.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Columns.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('columns', 'mismatch', event)" title="Columns that have differences between source and target databases ($($global:ComparisonData.Columns.Differences.Count) out of $($global:ComparisonData.Columns.Matches.Count + $global:ComparisonData.Columns.SourceOnly.Count + $global:ComparisonData.Columns.TargetOnly.Count + $global:ComparisonData.Columns.Differences.Count))">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Columns.Differences.Count / ($global:ComparisonData.Columns.Matches.Count + $global:ComparisonData.Columns.SourceOnly.Count + $global:ComparisonData.Columns.TargetOnly.Count + $global:ComparisonData.Columns.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Columns.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('indexes')" oncontextmenu="return markSummarySelected(event, this, 'indexes')">
                <div class="summary-header">
                    <h3>Indexes</h3>
                    <span class="check-badge"></span>
                    <span class="total-count">$($global:ComparisonData.Indexes.Matches.Count + $global:ComparisonData.Indexes.SourceOnly.Count + $global:ComparisonData.Indexes.TargetOnly.Count + $global:ComparisonData.Indexes.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('indexes', 'match', event)" title="Indexes that are identical in both databases ($($global:ComparisonData.Indexes.Matches.Count) out of $($global:ComparisonData.Indexes.Matches.Count + $global:ComparisonData.Indexes.SourceOnly.Count + $global:ComparisonData.Indexes.TargetOnly.Count + $global:ComparisonData.Indexes.Differences.Count))">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Indexes.Matches.Count / ($global:ComparisonData.Indexes.Matches.Count + $global:ComparisonData.Indexes.SourceOnly.Count + $global:ComparisonData.Indexes.TargetOnly.Count + $global:ComparisonData.Indexes.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Indexes.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('indexes', 'source-only', event)" title="Indexes that exist only in the source database ($($global:ComparisonData.Indexes.SourceOnly.Count) out of $($global:ComparisonData.Indexes.Matches.Count + $global:ComparisonData.Indexes.SourceOnly.Count + $global:ComparisonData.Indexes.TargetOnly.Count + $global:ComparisonData.Indexes.Differences.Count))">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Indexes.SourceOnly.Count / ($global:ComparisonData.Indexes.Matches.Count + $global:ComparisonData.Indexes.SourceOnly.Count + $global:ComparisonData.Indexes.TargetOnly.Count + $global:ComparisonData.Indexes.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Indexes.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('indexes', 'target-only', event)" title="Indexes that exist only in the target database ($($global:ComparisonData.Indexes.TargetOnly.Count) out of $($global:ComparisonData.Indexes.Matches.Count + $global:ComparisonData.Indexes.SourceOnly.Count + $global:ComparisonData.Indexes.TargetOnly.Count + $global:ComparisonData.Indexes.Differences.Count))">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Indexes.TargetOnly.Count / ($global:ComparisonData.Indexes.Matches.Count + $global:ComparisonData.Indexes.SourceOnly.Count + $global:ComparisonData.Indexes.TargetOnly.Count + $global:ComparisonData.Indexes.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Indexes.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('indexes', 'mismatch', event)" title="Indexes that have differences between source and target databases ($($global:ComparisonData.Indexes.Differences.Count) out of $($global:ComparisonData.Indexes.Matches.Count + $global:ComparisonData.Indexes.SourceOnly.Count + $global:ComparisonData.Indexes.TargetOnly.Count + $global:ComparisonData.Indexes.Differences.Count))">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Indexes.Differences.Count / ($global:ComparisonData.Indexes.Matches.Count + $global:ComparisonData.Indexes.SourceOnly.Count + $global:ComparisonData.Indexes.TargetOnly.Count + $global:ComparisonData.Indexes.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Indexes.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('functions')" oncontextmenu="return markSummarySelected(event, this, 'functions')">
                <div class="summary-header">
                    <h3>Functions</h3>
                    <span class="check-badge"></span>
                    <span class="total-count">$($global:ComparisonData.Functions.Matches.Count + $global:ComparisonData.Functions.SourceOnly.Count + $global:ComparisonData.Functions.TargetOnly.Count + $global:ComparisonData.Functions.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('functions', 'match', event)">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Functions.Matches.Count / ($global:ComparisonData.Functions.Matches.Count + $global:ComparisonData.Functions.SourceOnly.Count + $global:ComparisonData.Functions.TargetOnly.Count + $global:ComparisonData.Functions.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Functions.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('functions', 'source-only', event)">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Functions.SourceOnly.Count / ($global:ComparisonData.Functions.Matches.Count + $global:ComparisonData.Functions.SourceOnly.Count + $global:ComparisonData.Functions.TargetOnly.Count + $global:ComparisonData.Functions.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Functions.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('functions', 'target-only', event)">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Functions.TargetOnly.Count / ($global:ComparisonData.Functions.Matches.Count + $global:ComparisonData.Functions.SourceOnly.Count + $global:ComparisonData.Functions.TargetOnly.Count + $global:ComparisonData.Functions.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Functions.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('functions', 'mismatch', event)">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.Functions.Differences.Count / ($global:ComparisonData.Functions.Matches.Count + $global:ComparisonData.Functions.SourceOnly.Count + $global:ComparisonData.Functions.TargetOnly.Count + $global:ComparisonData.Functions.Differences.Count)) * 100, 1))%">$($global:ComparisonData.Functions.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('stored-procedures')" oncontextmenu="return markSummarySelected(event, this, 'stored-procedures')">
                <div class="summary-header">
                    <h3>Stored Procedures</h3>
                    <span class="check-badge"></span>
                    <span class="total-count">$($global:ComparisonData.StoredProcedures.Matches.Count + $global:ComparisonData.StoredProcedures.SourceOnly.Count + $global:ComparisonData.StoredProcedures.TargetOnly.Count + $global:ComparisonData.StoredProcedures.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('stored-procedures', 'match', event)">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.StoredProcedures.Matches.Count / ($global:ComparisonData.StoredProcedures.Matches.Count + $global:ComparisonData.StoredProcedures.SourceOnly.Count + $global:ComparisonData.StoredProcedures.TargetOnly.Count + $global:ComparisonData.StoredProcedures.Differences.Count)) * 100, 1))%">$($global:ComparisonData.StoredProcedures.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('stored-procedures', 'source-only', event)">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.StoredProcedures.SourceOnly.Count / ($global:ComparisonData.StoredProcedures.Matches.Count + $global:ComparisonData.StoredProcedures.SourceOnly.Count + $global:ComparisonData.StoredProcedures.TargetOnly.Count + $global:ComparisonData.StoredProcedures.Differences.Count)) * 100, 1))%">$($global:ComparisonData.StoredProcedures.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('stored-procedures', 'target-only', event)">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.StoredProcedures.TargetOnly.Count / ($global:ComparisonData.StoredProcedures.Matches.Count + $global:ComparisonData.StoredProcedures.SourceOnly.Count + $global:ComparisonData.StoredProcedures.TargetOnly.Count + $global:ComparisonData.StoredProcedures.Differences.Count)) * 100, 1))%">$($global:ComparisonData.StoredProcedures.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('stored-procedures', 'mismatch', event)">
                        <span class="count" style="width: $([math]::Round(($global:ComparisonData.StoredProcedures.Differences.Count / ($global:ComparisonData.StoredProcedures.Matches.Count + $global:ComparisonData.StoredProcedures.SourceOnly.Count + $global:ComparisonData.StoredProcedures.TargetOnly.Count + $global:ComparisonData.StoredProcedures.Differences.Count)) * 100, 1))%">$($global:ComparisonData.StoredProcedures.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('data-types')" oncontextmenu="return markSummarySelected(event, this, 'data-types')">
                <div class="summary-header">
                    <h3>Data Types</h3>
                    <span class="check-badge"></span>
                    <span class="total-count">$($global:ComparisonData.DataTypes.Matches.Count + $global:ComparisonData.DataTypes.SourceOnly.Count + $global:ComparisonData.DataTypes.TargetOnly.Count + $global:ComparisonData.DataTypes.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('data-types', 'match', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.DataTypes.Matches.Count + $global:ComparisonData.DataTypes.SourceOnly.Count + $global:ComparisonData.DataTypes.TargetOnly.Count + $global:ComparisonData.DataTypes.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.DataTypes.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.DataTypes.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('data-types', 'source-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.DataTypes.Matches.Count + $global:ComparisonData.DataTypes.SourceOnly.Count + $global:ComparisonData.DataTypes.TargetOnly.Count + $global:ComparisonData.DataTypes.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.DataTypes.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.DataTypes.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('data-types', 'target-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.DataTypes.Matches.Count + $global:ComparisonData.DataTypes.SourceOnly.Count + $global:ComparisonData.DataTypes.TargetOnly.Count + $global:ComparisonData.DataTypes.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.DataTypes.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.DataTypes.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('data-types', 'mismatch', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.DataTypes.Matches.Count + $global:ComparisonData.DataTypes.SourceOnly.Count + $global:ComparisonData.DataTypes.TargetOnly.Count + $global:ComparisonData.DataTypes.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.DataTypes.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.DataTypes.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('constraints')" oncontextmenu="return markSummarySelected(event, this, 'constraints')">
                <div class="summary-header">
                    <h3>Constraints</h3>
                    <span class="check-badge"></span>
                    <span class="total-count">$($global:ComparisonData.Constraints.Matches.Count + $global:ComparisonData.Constraints.SourceOnly.Count + $global:ComparisonData.Constraints.TargetOnly.Count + $global:ComparisonData.Constraints.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('constraints', 'match', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Constraints.Matches.Count + $global:ComparisonData.Constraints.SourceOnly.Count + $global:ComparisonData.Constraints.TargetOnly.Count + $global:ComparisonData.Constraints.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Constraints.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Constraints.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('constraints', 'source-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Constraints.Matches.Count + $global:ComparisonData.Constraints.SourceOnly.Count + $global:ComparisonData.Constraints.TargetOnly.Count + $global:ComparisonData.Constraints.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Constraints.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Constraints.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('constraints', 'target-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Constraints.Matches.Count + $global:ComparisonData.Constraints.SourceOnly.Count + $global:ComparisonData.Constraints.TargetOnly.Count + $global:ComparisonData.Constraints.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Constraints.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Constraints.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('constraints', 'mismatch', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Constraints.Matches.Count + $global:ComparisonData.Constraints.SourceOnly.Count + $global:ComparisonData.Constraints.TargetOnly.Count + $global:ComparisonData.Constraints.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Constraints.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Constraints.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('views')" oncontextmenu="return markSummarySelected(event, this, 'views')">
                <div class="summary-header">
                    <h3>Views</h3>
                    <span class="check-badge"></span>
                    <span class="total-count">$($global:ComparisonData.Views.Matches.Count + $global:ComparisonData.Views.SourceOnly.Count + $global:ComparisonData.Views.TargetOnly.Count + $global:ComparisonData.Views.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('views', 'match', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Views.Matches.Count + $global:ComparisonData.Views.SourceOnly.Count + $global:ComparisonData.Views.TargetOnly.Count + $global:ComparisonData.Views.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Views.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Views.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('views', 'source-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Views.Matches.Count + $global:ComparisonData.Views.SourceOnly.Count + $global:ComparisonData.Views.TargetOnly.Count + $global:ComparisonData.Views.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Views.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Views.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('views', 'target-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Views.Matches.Count + $global:ComparisonData.Views.SourceOnly.Count + $global:ComparisonData.Views.TargetOnly.Count + $global:ComparisonData.Views.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Views.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Views.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('views', 'mismatch', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Views.Matches.Count + $global:ComparisonData.Views.SourceOnly.Count + $global:ComparisonData.Views.TargetOnly.Count + $global:ComparisonData.Views.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Views.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Views.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('synonyms')" oncontextmenu="return markSummarySelected(event, this, 'synonyms')">
                <div class="summary-header">
                    <h3>Synonyms</h3>
                    <span class="check-badge"></span>
                    <span class="total-count">$($global:ComparisonData.Synonyms.Matches.Count + $global:ComparisonData.Synonyms.SourceOnly.Count + $global:ComparisonData.Synonyms.TargetOnly.Count + $global:ComparisonData.Synonyms.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('synonyms', 'match', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Synonyms.Matches.Count + $global:ComparisonData.Synonyms.SourceOnly.Count + $global:ComparisonData.Synonyms.TargetOnly.Count + $global:ComparisonData.Synonyms.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Synonyms.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Synonyms.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('synonyms', 'source-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Synonyms.Matches.Count + $global:ComparisonData.Synonyms.SourceOnly.Count + $global:ComparisonData.Synonyms.TargetOnly.Count + $global:ComparisonData.Synonyms.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Synonyms.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Synonyms.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('synonyms', 'target-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Synonyms.Matches.Count + $global:ComparisonData.Synonyms.SourceOnly.Count + $global:ComparisonData.Synonyms.TargetOnly.Count + $global:ComparisonData.Synonyms.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Synonyms.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Synonyms.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('synonyms', 'mismatch', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Synonyms.Matches.Count + $global:ComparisonData.Synonyms.SourceOnly.Count + $global:ComparisonData.Synonyms.TargetOnly.Count + $global:ComparisonData.Synonyms.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Synonyms.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Synonyms.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('table-triggers')" oncontextmenu="return markSummarySelected(event, this, 'table-triggers')">
                <div class="summary-header">
                    <h3>Table Triggers</h3>
                    <span class="check-badge"></span>
                    <span class="total-count">$($global:ComparisonData.TableTriggers.Matches.Count + $global:ComparisonData.TableTriggers.SourceOnly.Count + $global:ComparisonData.TableTriggers.TargetOnly.Count + $global:ComparisonData.TableTriggers.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('table-triggers', 'match', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.TableTriggers.Matches.Count + $global:ComparisonData.TableTriggers.SourceOnly.Count + $global:ComparisonData.TableTriggers.TargetOnly.Count + $global:ComparisonData.TableTriggers.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.TableTriggers.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.TableTriggers.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('table-triggers', 'source-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.TableTriggers.Matches.Count + $global:ComparisonData.TableTriggers.SourceOnly.Count + $global:ComparisonData.TableTriggers.TargetOnly.Count + $global:ComparisonData.TableTriggers.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.TableTriggers.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.TableTriggers.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('table-triggers', 'target-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.TableTriggers.Matches.Count + $global:ComparisonData.TableTriggers.SourceOnly.Count + $global:ComparisonData.TableTriggers.TargetOnly.Count + $global:ComparisonData.TableTriggers.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.TableTriggers.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.TableTriggers.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('table-triggers', 'mismatch', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.TableTriggers.Matches.Count + $global:ComparisonData.TableTriggers.SourceOnly.Count + $global:ComparisonData.TableTriggers.TargetOnly.Count + $global:ComparisonData.TableTriggers.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.TableTriggers.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.TableTriggers.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('database-triggers')" oncontextmenu="return markSummarySelected(event, this, 'database-triggers')">
                <div class="summary-header">
                    <h3>Database Triggers</h3>
                    <span class="check-badge">✓</span>
                    <span class="total-count">$($global:ComparisonData.DatabaseTriggers.Matches.Count + $global:ComparisonData.DatabaseTriggers.SourceOnly.Count + $global:ComparisonData.DatabaseTriggers.TargetOnly.Count + $global:ComparisonData.DatabaseTriggers.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('database-triggers', 'match', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.DatabaseTriggers.Matches.Count + $global:ComparisonData.DatabaseTriggers.SourceOnly.Count + $global:ComparisonData.DatabaseTriggers.TargetOnly.Count + $global:ComparisonData.DatabaseTriggers.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.DatabaseTriggers.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.DatabaseTriggers.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('database-triggers', 'source-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.DatabaseTriggers.Matches.Count + $global:ComparisonData.DatabaseTriggers.SourceOnly.Count + $global:ComparisonData.DatabaseTriggers.TargetOnly.Count + $global:ComparisonData.DatabaseTriggers.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.DatabaseTriggers.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.DatabaseTriggers.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('database-triggers', 'target-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.DatabaseTriggers.Matches.Count + $global:ComparisonData.DatabaseTriggers.SourceOnly.Count + $global:ComparisonData.DatabaseTriggers.TargetOnly.Count + $global:ComparisonData.DatabaseTriggers.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.DatabaseTriggers.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.DatabaseTriggers.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('database-triggers', 'mismatch', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.DatabaseTriggers.Matches.Count + $global:ComparisonData.DatabaseTriggers.SourceOnly.Count + $global:ComparisonData.DatabaseTriggers.TargetOnly.Count + $global:ComparisonData.DatabaseTriggers.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.DatabaseTriggers.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.DatabaseTriggers.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('keys')" oncontextmenu="return markSummarySelected(event, this, 'keys')">
                <div class="summary-header">
                    <h3>Keys</h3>
                    <span class="check-badge">✓</span>
                    <span class="total-count">$($global:ComparisonData.Keys.Matches.Count + $global:ComparisonData.Keys.SourceOnly.Count + $global:ComparisonData.Keys.TargetOnly.Count + $global:ComparisonData.Keys.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('keys', 'match', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Keys.Matches.Count + $global:ComparisonData.Keys.SourceOnly.Count + $global:ComparisonData.Keys.TargetOnly.Count + $global:ComparisonData.Keys.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Keys.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Keys.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('keys', 'source-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Keys.Matches.Count + $global:ComparisonData.Keys.SourceOnly.Count + $global:ComparisonData.Keys.TargetOnly.Count + $global:ComparisonData.Keys.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Keys.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Keys.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('keys', 'target-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Keys.Matches.Count + $global:ComparisonData.Keys.SourceOnly.Count + $global:ComparisonData.Keys.TargetOnly.Count + $global:ComparisonData.Keys.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Keys.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Keys.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('keys', 'mismatch', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Keys.Matches.Count + $global:ComparisonData.Keys.SourceOnly.Count + $global:ComparisonData.Keys.TargetOnly.Count + $global:ComparisonData.Keys.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Keys.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Keys.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('database-options')" oncontextmenu="return markSummarySelected(event, this, 'database-options')">
                <div class="summary-header">
                    <h3>Database Options</h3>
                    <span class="check-badge">✓</span>
                    <span class="total-count">$($global:ComparisonData.DatabaseOptions.Matches.Count + $global:ComparisonData.DatabaseOptions.SourceOnly.Count + $global:ComparisonData.DatabaseOptions.TargetOnly.Count + $global:ComparisonData.DatabaseOptions.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('database-options', 'match', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.DatabaseOptions.Matches.Count + $global:ComparisonData.DatabaseOptions.SourceOnly.Count + $global:ComparisonData.DatabaseOptions.TargetOnly.Count + $global:ComparisonData.DatabaseOptions.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.DatabaseOptions.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.DatabaseOptions.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('database-options', 'source-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.DatabaseOptions.Matches.Count + $global:ComparisonData.DatabaseOptions.SourceOnly.Count + $global:ComparisonData.DatabaseOptions.TargetOnly.Count + $global:ComparisonData.DatabaseOptions.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.DatabaseOptions.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.DatabaseOptions.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('database-options', 'target-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.DatabaseOptions.Matches.Count + $global:ComparisonData.DatabaseOptions.SourceOnly.Count + $global:ComparisonData.DatabaseOptions.TargetOnly.Count + $global:ComparisonData.DatabaseOptions.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.DatabaseOptions.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.DatabaseOptions.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('database-options', 'mismatch', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.DatabaseOptions.Matches.Count + $global:ComparisonData.DatabaseOptions.SourceOnly.Count + $global:ComparisonData.DatabaseOptions.TargetOnly.Count + $global:ComparisonData.DatabaseOptions.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.DatabaseOptions.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.DatabaseOptions.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('file-information')" oncontextmenu="return markSummarySelected(event, this, 'file-information')">
                <div class="summary-header">
                    <h3>File Information</h3>
                    <span class="check-badge">✓</span>
                    <span class="total-count">$($global:ComparisonData.FileInfo.Matches.Count + $global:ComparisonData.FileInfo.SourceOnly.Count + $global:ComparisonData.FileInfo.TargetOnly.Count + $global:ComparisonData.FileInfo.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('file-information', 'match', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.FileInfo.Matches.Count + $global:ComparisonData.FileInfo.SourceOnly.Count + $global:ComparisonData.FileInfo.TargetOnly.Count + $global:ComparisonData.FileInfo.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.FileInfo.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.FileInfo.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('file-information', 'source-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.FileInfo.Matches.Count + $global:ComparisonData.FileInfo.SourceOnly.Count + $global:ComparisonData.FileInfo.TargetOnly.Count + $global:ComparisonData.FileInfo.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.FileInfo.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.FileInfo.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('file-information', 'target-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.FileInfo.Matches.Count + $global:ComparisonData.FileInfo.SourceOnly.Count + $global:ComparisonData.FileInfo.TargetOnly.Count + $global:ComparisonData.FileInfo.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.FileInfo.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.FileInfo.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('file-information', 'mismatch', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.FileInfo.Matches.Count + $global:ComparisonData.FileInfo.SourceOnly.Count + $global:ComparisonData.FileInfo.TargetOnly.Count + $global:ComparisonData.FileInfo.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.FileInfo.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.FileInfo.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>

                        
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('VLF Information')" oncontextmenu="return markSummarySelected(event, this, 'VLF Information')">
                <div class="summary-header">
                    <h3>VLF Information</h3>
                    <span class="check-badge">✓</span>
                    <span class="total-count">$($global:ComparisonData.VLF.Matches.Count + $global:ComparisonData.VLF.SourceOnly.Count + $global:ComparisonData.VLF.TargetOnly.Count + $global:ComparisonData.VLF.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('VLF Information', 'match', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.VLF.Matches.Count + $global:ComparisonData.VLF.SourceOnly.Count + $global:ComparisonData.VLF.TargetOnly.Count + $global:ComparisonData.VLF.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.VLF.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.VLF.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('VLF Information', 'source-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.VLF.Matches.Count + $global:ComparisonData.VLF.SourceOnly.Count + $global:ComparisonData.VLF.TargetOnly.Count + $global:ComparisonData.VLF.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.VLF.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.VLF.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('VLF Information', 'target-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.VLF.Matches.Count + $global:ComparisonData.VLF.SourceOnly.Count + $global:ComparisonData.VLF.TargetOnly.Count + $global:ComparisonData.VLF.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.VLF.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.VLF.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('VLF Information', 'mismatch', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.VLF.Matches.Count + $global:ComparisonData.VLF.SourceOnly.Count + $global:ComparisonData.VLF.TargetOnly.Count + $global:ComparisonData.VLF.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.VLF.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.VLF.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('Users')" oncontextmenu="return markSummarySelected(event, this, 'Users')">
                <div class="summary-header">
                    <h3>Users</h3>
                    <span class="check-badge">✓</span>
                    <span class="total-count">$($global:ComparisonData.Users.Matches.Count + $global:ComparisonData.Users.SourceOnly.Count + $global:ComparisonData.Users.TargetOnly.Count + $global:ComparisonData.Users.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('Users', 'match', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Users.Matches.Count + $global:ComparisonData.Users.SourceOnly.Count + $global:ComparisonData.Users.TargetOnly.Count + $global:ComparisonData.Users.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Users.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Users.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('Users', 'source-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Users.Matches.Count + $global:ComparisonData.Users.SourceOnly.Count + $global:ComparisonData.Users.TargetOnly.Count + $global:ComparisonData.Users.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Users.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Users.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('Users', 'target-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Users.Matches.Count + $global:ComparisonData.Users.SourceOnly.Count + $global:ComparisonData.Users.TargetOnly.Count + $global:ComparisonData.Users.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Users.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Users.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('Users', 'mismatch', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Users.Matches.Count + $global:ComparisonData.Users.SourceOnly.Count + $global:ComparisonData.Users.TargetOnly.Count + $global:ComparisonData.Users.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Users.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Users.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('Roles')" oncontextmenu="return markSummarySelected(event, this, 'Roles')">
                <div class="summary-header">
                    <h3>Roles</h3>
                    <span class="check-badge">✓</span>
                    <span class="total-count">$($global:ComparisonData.Roles.Matches.Count + $global:ComparisonData.Roles.SourceOnly.Count + $global:ComparisonData.Roles.TargetOnly.Count + $global:ComparisonData.Roles.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('Roles', 'match', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Roles.Matches.Count + $global:ComparisonData.Roles.SourceOnly.Count + $global:ComparisonData.Roles.TargetOnly.Count + $global:ComparisonData.Roles.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Roles.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Roles.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('Roles', 'source-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Roles.Matches.Count + $global:ComparisonData.Roles.SourceOnly.Count + $global:ComparisonData.Roles.TargetOnly.Count + $global:ComparisonData.Roles.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Roles.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Roles.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('Roles', 'target-only', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Roles.Matches.Count + $global:ComparisonData.Roles.SourceOnly.Count + $global:ComparisonData.Roles.TargetOnly.Count + $global:ComparisonData.Roles.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Roles.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Roles.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('Roles', 'mismatch', event)">
                        <span class="count" style="width: $($total = $global:ComparisonData.Roles.Matches.Count + $global:ComparisonData.Roles.SourceOnly.Count + $global:ComparisonData.Roles.TargetOnly.Count + $global:ComparisonData.Roles.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.Roles.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.Roles.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>
            <div class="summary-card" onclick="selectAllFiltersAndShowAll('External Resources')" oncontextmenu="return markSummarySelected(event, this, 'External Resources')">
                <div class="summary-header">
                    <h3>External Resources</h3>
                    <span class="check-badge">✓</span>
                    <span class="total-count">$($global:ComparisonData.ExternalResources.Matches.Count + $global:ComparisonData.ExternalResources.SourceOnly.Count + $global:ComparisonData.ExternalResources.TargetOnly.Count + $global:ComparisonData.ExternalResources.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('External Resources', 'match', event)" title="External Resources that are identical in both databases ($($global:ComparisonData.ExternalResources.Matches.Count) out of $($global:ComparisonData.ExternalResources.Matches.Count + $global:ComparisonData.ExternalResources.SourceOnly.Count + $global:ComparisonData.ExternalResources.TargetOnly.Count + $global:ComparisonData.ExternalResources.Differences.Count))">
                        <span class="count" style="width: $($total = $global:ComparisonData.ExternalResources.Matches.Count + $global:ComparisonData.ExternalResources.SourceOnly.Count + $global:ComparisonData.ExternalResources.TargetOnly.Count + $global:ComparisonData.ExternalResources.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.ExternalResources.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.ExternalResources.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('External Resources', 'source-only', event)" title="External Resources only in source ($($global:ComparisonData.ExternalResources.SourceOnly.Count) of $($total))">
                        <span class="count" style="width: $($total = $global:ComparisonData.ExternalResources.Matches.Count + $global:ComparisonData.ExternalResources.SourceOnly.Count + $global:ComparisonData.ExternalResources.TargetOnly.Count + $global:ComparisonData.ExternalResources.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.ExternalResources.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.ExternalResources.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('External Resources', 'target-only', event)" title="External Resources only in target ($($global:ComparisonData.ExternalResources.TargetOnly.Count) of $($total))">
                        <span class="count" style="width: $($total = $global:ComparisonData.ExternalResources.Matches.Count + $global:ComparisonData.ExternalResources.SourceOnly.Count + $global:ComparisonData.ExternalResources.TargetOnly.Count + $global:ComparisonData.ExternalResources.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.ExternalResources.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.ExternalResources.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('External Resources', 'mismatch', event)" title="External Resources with differences ($($global:ComparisonData.ExternalResources.Differences.Count) of $($total))">
                        <span class="count" style="width: $($total = $global:ComparisonData.ExternalResources.Matches.Count + $global:ComparisonData.ExternalResources.SourceOnly.Count + $global:ComparisonData.ExternalResources.TargetOnly.Count + $global:ComparisonData.ExternalResources.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.ExternalResources.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.ExternalResources.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>

            <div class="summary-card" onclick="selectAllFiltersAndShowAll('Query Store')" oncontextmenu="return markSummarySelected(event, this, 'Query Store')">
                <div class="summary-header">
                    <h3>Query Store</h3>
                    <span class="check-badge">✓</span>
                    <span class="total-count">$($global:ComparisonData.QueryStore.Matches.Count + $global:ComparisonData.QueryStore.SourceOnly.Count + $global:ComparisonData.QueryStore.TargetOnly.Count + $global:ComparisonData.QueryStore.Differences.Count) total</span>
                </div>
                <div class="summary-breakdown">
                    <div class="breakdown-item match" onclick="filterByStatus('Query Store', 'match', event)" title="Query plans consistent across source and target ($($global:ComparisonData.QueryStore.Matches.Count) of $($global:ComparisonData.QueryStore.Matches.Count + $global:ComparisonData.QueryStore.SourceOnly.Count + $global:ComparisonData.QueryStore.TargetOnly.Count + $global:ComparisonData.QueryStore.Differences.Count))">
                        <span class="count" style="width: $($total = $global:ComparisonData.QueryStore.Matches.Count + $global:ComparisonData.QueryStore.SourceOnly.Count + $global:ComparisonData.QueryStore.TargetOnly.Count + $global:ComparisonData.QueryStore.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.QueryStore.Matches.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.QueryStore.Matches.Count)</span>
                        <span class="label">Match</span>
                    </div>
                    <div class="breakdown-item source-only" onclick="filterByStatus('Query Store', 'source-only', event)" title="Forced plans only in source ($($global:ComparisonData.QueryStore.SourceOnly.Count) of $($total))">
                        <span class="count" style="width: $($total = $global:ComparisonData.QueryStore.Matches.Count + $global:ComparisonData.QueryStore.SourceOnly.Count + $global:ComparisonData.QueryStore.TargetOnly.Count + $global:ComparisonData.QueryStore.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.QueryStore.SourceOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.QueryStore.SourceOnly.Count)</span>
                        <span class="label">Source Only</span>
                    </div>
                    <div class="breakdown-item target-only" onclick="filterByStatus('Query Store', 'target-only', event)" title="Forced plans only in target ($($global:ComparisonData.QueryStore.TargetOnly.Count) of $($total))">
                        <span class="count" style="width: $($total = $global:ComparisonData.QueryStore.Matches.Count + $global:ComparisonData.QueryStore.SourceOnly.Count + $global:ComparisonData.QueryStore.TargetOnly.Count + $global:ComparisonData.QueryStore.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.QueryStore.TargetOnly.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.QueryStore.TargetOnly.Count)</span>
                        <span class="label">Target Only</span>
                    </div>
                    <div class="breakdown-item mismatch" onclick="filterByStatus('Query Store', 'mismatch', event)" title="Query store differences (e.g., forced plan mismatch) ($($global:ComparisonData.QueryStore.Differences.Count) of $($total))">
                        <span class="count" style="width: $($total = $global:ComparisonData.QueryStore.Matches.Count + $global:ComparisonData.QueryStore.SourceOnly.Count + $global:ComparisonData.QueryStore.TargetOnly.Count + $global:ComparisonData.QueryStore.Differences.Count; if($total -gt 0) { [math]::Round(($global:ComparisonData.QueryStore.Differences.Count / $total) * 100, 1) } else { 0 })%">$($global:ComparisonData.QueryStore.Differences.Count)</span>
                        <span class="label">Differences</span>
                    </div>
                </div>
            </div>


        </div>
    </div>
"@

    # Add sections for each comparison type
    $sections = @(
        @{ Name = "Schemas"; Data = $global:ComparisonData.Schemas; KeyColumns = "SCHEMA_NAME" },
        @{ Name = "Tables"; Data = $global:ComparisonData.Tables; KeyColumns = "TABLE_SCHEMA,TABLE_NAME" },
        @{ Name = "Columns"; Data = $global:ComparisonData.Columns; KeyColumns = "TABLE_SCHEMA,TABLE_NAME,COLUMN_NAME" },
        @{ Name = "Indexes"; Data = $global:ComparisonData.Indexes; KeyColumns = "SCHEMA_NAME,TABLE_NAME,INDEX_NAME" },
        @{ Name = "Functions"; Data = $global:ComparisonData.Functions; KeyColumns = "SCHEMA_NAME,FUNCTION_NAME" },
        @{ Name = "Stored Procedures"; Data = $global:ComparisonData.StoredProcedures; KeyColumns = "SCHEMA_NAME,PROCEDURE_NAME" },
        @{ Name = "Data Types"; Data = $global:ComparisonData.DataTypes; KeyColumns = "SCHEMA_NAME,TYPE_NAME" },
        @{ Name = "Constraints"; Data = $global:ComparisonData.Constraints; KeyColumns = "SCHEMA_NAME,TABLE_NAME,CONSTRAINT_NAME" },
        @{ Name = "Views"; Data = $global:ComparisonData.Views; KeyColumns = "SCHEMA_NAME,VIEW_NAME" },
        @{ Name = "Synonyms"; Data = $global:ComparisonData.Synonyms; KeyColumns = "SCHEMA_NAME,SYNONYM_NAME" },
        @{ Name = "Table Triggers"; Data = $global:ComparisonData.TableTriggers; KeyColumns = "SCHEMA_NAME,TABLE_NAME,TRIGGER_NAME" },
        @{ Name = "Database Triggers"; Data = $global:ComparisonData.DatabaseTriggers; KeyColumns = "TRIGGER_NAME" },
        @{ Name = "Keys"; Data = $global:ComparisonData.Keys; KeyColumns = "SCHEMA_NAME,TABLE_NAME,KEY_NAME" },
        @{ Name = "Database Options"; Data = $global:ComparisonData.DatabaseOptions; KeyColumns = "OPTION_NAME" },
        @{ Name = "File Information"; Data = $global:ComparisonData.FileInfo; KeyColumns = "name,file_id" },
        @{ Name = "VLF Information"; Data = $global:ComparisonData.VLF; KeyColumns = "file_id,vlf_sequence_number" },
        @{ Name = "Users"; Data = $global:ComparisonData.Users; KeyColumns = "USER_NAME" },
        @{ Name = "Roles"; Data = $global:ComparisonData.Roles; KeyColumns = "ROLE_NAME" },
        @{ Name = "External Resources"; Data = $global:ComparisonData.ExternalResources; KeyColumns = "RESOURCE_NAME" },
        @{ Name = "Query Store"; Data = $global:ComparisonData.QueryStore; KeyColumns = "ITEM_TYPE,OBJECT_NAME" }
    )
    
    # Generate sections separately to avoid string truncation
    $sectionsHtml = @()
    foreach ($section in $sections) {
        $sectionsHtml += New-SectionHTML -SectionName $section.Name -Data $section.Data -KeyColumns $section.KeyColumns -SourceDatabaseName $SourceDatabase -TargetDatabaseName $TargetDatabase
    }
    
    # Combine all sections
    $html += "<div id=`"sectionsContainer`">" + (($sectionsHtml -join "")) + "</div>"
    
    $html += @"
    <script>
        // Enhanced filter functionality
        function applyFilters(sectionId) {
            const filterInput = document.getElementById('filter-' + sectionId);
            const filterText = filterInput.value.toLowerCase();
            const table = document.querySelector('#' + sectionId + '-content table');
            const countElement = document.getElementById('count-' + sectionId);
            
            if (!table) return;
            
            // Get status checkbox states
            const showMismatch = document.getElementById('show-mismatch-' + sectionId).checked;
            const showMatch = document.getElementById('show-match-' + sectionId).checked;
            const showSourceOnly = document.getElementById('show-source-only-' + sectionId).checked;
            const showTargetOnly = document.getElementById('show-target-only-' + sectionId).checked;
            
            const rows = table.querySelectorAll('tbody tr');
            let visibleCount = 0;
            
            rows.forEach(row => {
                const text = row.textContent.toLowerCase();
                const isTextMatch = text.includes(filterText);
                
                // Check status filter
                let isStatusMatch = false;
                if (row.classList.contains('mismatch') && showMismatch) isStatusMatch = true;
                if (row.classList.contains('match') && showMatch) isStatusMatch = true;
                if (row.classList.contains('source-only') && showSourceOnly) isStatusMatch = true;
                if (row.classList.contains('target-only') && showTargetOnly) isStatusMatch = true;
                
                if (isTextMatch && isStatusMatch) {
                    row.classList.remove('filtered-row');
                    visibleCount++;
                } else {
                    row.classList.add('filtered-row');
                }
            });
            
            countElement.textContent = visibleCount + ' items';
        }
        
        function clearFilter(sectionId) {
            const filterInput = document.getElementById('filter-' + sectionId);
            const sortSelect = document.getElementById('sort-' + sectionId);
            
            filterInput.value = '';
            sortSelect.value = '';
            
            // Reset all checkboxes to checked
            document.getElementById('show-mismatch-' + sectionId).checked = true;
            document.getElementById('show-match-' + sectionId).checked = true;
            document.getElementById('show-source-only-' + sectionId).checked = true;
            document.getElementById('show-target-only-' + sectionId).checked = true;
            
            applyFilters(sectionId);
        }
        function sortTable(sectionId) {
            const sortSelect = document.getElementById('sort-' + sectionId);
            const sortValue = sortSelect.value;
            const table = document.querySelector('#' + sectionId + '-content table');
            
            if (!table || !sortValue) return;
            
            const tbody = table.querySelector('tbody');
            const rows = Array.from(tbody.querySelectorAll('tr'));
            
            rows.sort((a, b) => {
                const aText = a.textContent.toLowerCase();
                const bText = b.textContent.toLowerCase();
                
                let aValue, bValue;
                
                if (sortValue.includes('name')) {
                    // Sort by object name (first column after row number)
                    aValue = a.cells[1] ? a.cells[1].textContent.toLowerCase() : '';
                    bValue = b.cells[1] ? b.cells[1].textContent.toLowerCase() : '';
                } else if (sortValue.includes('status')) {
                    // Sort by status (third column)
                    aValue = a.cells[2] ? a.cells[2].textContent.toLowerCase() : '';
                    bValue = b.cells[2] ? b.cells[2].textContent.toLowerCase() : '';
                }
                
                const isAscending = sortValue.includes('asc');
                const comparison = aValue.localeCompare(bValue);
                
                return isAscending ? comparison : -comparison;
            });
            
            // Clear tbody and re-append sorted rows
            tbody.innerHTML = '';
            rows.forEach(row => tbody.appendChild(row));
        }
        
        function setupFilters() {
            document.querySelectorAll('.filter-input').forEach(input => {
                const sectionId = input.id.replace('filter-', '');
                
                // Add event listeners for real-time filtering
                input.addEventListener('input', function() {
                    applyFilters(sectionId);
                });
                
                input.addEventListener('keyup', function() {
                    applyFilters(sectionId);
                });
                
                // Initialize count
                applyFilters(sectionId);
            });
        }
        // Initialize page
        document.addEventListener('DOMContentLoaded', function() {
            // Add click handlers to section headers (for summary card navigation)
            document.querySelectorAll('.section-header').forEach(header => {    
                // Don't toggle if clicking on the toggle button (it handles itself)
                if (event.target.classList.contains('toggle')) {
                    return;
                }
                const sectionId = this.id.replace('-header', '');
                toggleSection(sectionId);
            });
            
            // Setup filters
            setupFilters();

            // Map section id -> summary card for quick lookup
            const sectionIdToCard = (() => {
                const map = {};
                const cards = document.querySelectorAll('#summaryCards .summary-card');
                cards.forEach(card => {
                    const h = card.querySelector('h3');
                    if(!h) return;
                    const key = h.textContent.trim().toLowerCase().replace(/\s+/g,'-');
                    map[key] = card;
                });
                return map;
            })();
            function getSummaryCardBySectionId(sectionId){
                const id = (sectionId||'').toString().toLowerCase().replace(/\s+/g,'-');
                return sectionIdToCard[id] || null;
            }

            // Helper: expand a section without scrolling
            function expandSectionNoScroll(sectionId){
                const sec = (sectionId||'').toString();
                const normalized = sec.toLowerCase().replace(/\s+/g,'-');
                const content = document.getElementById(normalized + '-content');
                const header = document.getElementById(normalized + '-header');
                const toggle = header ? header.querySelector('.toggle') : null;
                if (content && !content.classList.contains('expanded')) {
                    content.classList.add('expanded');
                    content.style.maxHeight = '5000px';
                    content.style.opacity = '1';
                    if (toggle) toggle.textContent = '[-]';
                }
            }

            function collapseSectionNoScroll(sectionId){
                const sec = (sectionId||'').toString();
                const normalized = sec.toLowerCase().replace(/\s+/g,'-');
                const content = document.getElementById(normalized + '-content');
                const header = document.getElementById(normalized + '-header');
                const toggle = header ? header.querySelector('.toggle') : null;
                if (content && content.classList.contains('expanded')) {
                    content.classList.remove('expanded');
                    content.style.maxHeight = '0';
                    content.style.opacity = '0';
                    if (toggle) toggle.textContent = '[+]';
                    // When a section is collapsed, unselect corresponding summary card
                    const card = getSummaryCardBySectionId(sectionId);
                    if(card) card.classList.remove('selected');
                }
            }

            // Right-click to select a summary card and expand corresponding section (no scroll)
            window.markSummarySelected = function(event, cardEl, sectionId){
                // Only handle right-click (button 2) or context menu
                if (event.button !== 2 && event.type !== 'contextmenu') {
                    return true; // Allow normal left-click behavior
                }
                event.preventDefault();
                event.stopPropagation();
                try{
                    // Toggle selection on right-click
                    if (cardEl.classList.contains('selected')) {
                        cardEl.classList.remove('selected');
                        // Collapse corresponding section without scrolling
                        collapseSectionNoScroll(sectionId);
                    } else {
                        // Multi-select: do NOT clear previous selections
                        cardEl.classList.add('selected');
                        // Expand corresponding section without scrolling
                        expandSectionNoScroll(sectionId);
                    }
                }catch(e){ console.error('markSummarySelected error', e); }
                return false;
            }
            
            // Summary counts are already set in the HTML template
            // Sorting for summary cards (FLIP)
            const container = document.getElementById('summaryCards');
            const alphaBtn = document.getElementById('sort-alpha-btn');
            const categoryBtn = document.getElementById('sort-category-btn');
            function getCategoryWeight(title){
                const t=(title||'').toLowerCase();
                const objects=['schemas','tables','columns','indexes','functions','stored procedures','views','synonyms','constraints','keys','table triggers','database triggers'];
                const perf=['query store','vlf information'];
                const config=['database options','file information','users','roles','external resources','data types'];
                if(objects.some(x=>t.includes(x)))return 1;
                if(perf.some(x=>t.includes(x)))return 2;
                if(config.some(x=>t.includes(x)))return 3;
                return 4;
            }
            function animateDirect(parent, newOrder) {
                const D = 500; // total duration
                const easing = 'cubic-bezier(0.16, 1, 0.3, 1)'; // ease-out
                // Freeze container height to avoid wrap jumps
                const parentHeight = parent.getBoundingClientRect().height;
                parent.style.height = parentHeight + 'px';
                // FIRST: capture positions
                const first = new Map();
                const children = Array.from(parent.children);
                children.forEach(el => first.set(el, el.getBoundingClientRect()));
                // LAST: apply new order with fragment
                const frag = document.createDocumentFragment();
                newOrder.forEach(el => frag.appendChild(el));
                parent.appendChild(frag);
                const items = Array.from(parent.children);
                // INVERT
                items.forEach(el => {
                    const f = first.get(el);
                    if (!f) return; // new element
                    const l = el.getBoundingClientRect();
                    const dx = f.left - l.left;
                    const dy = f.top - l.top;
                    el.style.transition = 'none';
                    el.style.transform = 'translate(' + dx + 'px, ' + dy + 'px)';
                });
                // Flush
                void parent.offsetWidth;
                // PLAY
                items.forEach(el => {
                    el.style.transition = 'transform ' + D + 'ms ' + easing;
                    el.style.transform = 'translate(0, 0)';
                    el.addEventListener('transitionend', function handler(){
                        el.style.transition = '';
                        el.style.transform = '';
                        el.removeEventListener('transitionend', handler);
                    }, { once: true });
                });
                // Release height after
                setTimeout(()=>{ parent.style.height = ''; }, D + 30);
            }
            window.sortAlphabetical = function(){
                if(!container) return;
                const sorted=Array.from(container.querySelectorAll('.summary-card')).sort((a,b)=>{
                    const at=a.querySelector('.summary-header h3')?.textContent?.toLowerCase()||'';
                    const bt=b.querySelector('.summary-header h3')?.textContent?.toLowerCase()||'';
                    return at.localeCompare(bt);
                });
                animateDirect(container,sorted);
            }
            window.sortByCategory = function(){
                if(!container) return;
                const sorted=Array.from(container.querySelectorAll('.summary-card')).sort((a,b)=>{
                    const at=a.querySelector('.summary-header h3')?.textContent||'';
                    const bt=b.querySelector('.summary-header h3')?.textContent||'';
                    const aw=getCategoryWeight(at); const bw=getCategoryWeight(bt);
                    if(aw!==bw) return aw-bw; return at.toLowerCase().localeCompare(bt.toLowerCase());
                });
                animateDirect(container,sorted);
            }
            if(alphaBtn) alphaBtn.addEventListener('click', window.sortAlphabetical);
            if(categoryBtn) categoryBtn.addEventListener('click', window.sortByCategory);

            // Section reordering to match chosen category sort
            window.reorderSections = function(orderTitles) {
                const secContainer = document.getElementById('sectionsContainer');
                if (!secContainer) return;
                const sections = Array.from(secContainer.children).filter(el => el.classList.contains('section'));
                const titleMap = new Map();
                sections.forEach(s => {
                    const h = s.querySelector('.section-header h2');
                    if (h) titleMap.set(h.textContent.trim().toLowerCase(), s);
                });
                const fragment = document.createDocumentFragment();
                orderTitles.forEach(t => {
                    const s = titleMap.get(t.toLowerCase());
                    if (s) fragment.appendChild(s);
                });
                // Append any remaining sections not explicitly ordered
                sections.forEach(s => { if (!fragment.contains(s)) fragment.appendChild(s); });
                secContainer.appendChild(fragment);
            }
            // When sorting by category for cards, also reorder sections to object → performance → configuration
            const _origSortByCategory = window.sortByCategory;
            window.sortCategoryAndSections = function(){
                // Sort summary cards first
                _origSortByCategory();
                // Then sort sections by data-category-weight (then A–Z)
                const box = document.getElementById('sectionsContainer') || document.querySelector('.section')?.parentElement;
                if (!box) return;
                const sections = Array.from(box.querySelectorAll(':scope > .section'));
                if (sections.length === 0) return;
                sections.sort((a,b)=>{
                    const aw = +(a.dataset.categoryWeight||99);
                    const bw = +(b.dataset.categoryWeight||99);
                    if (aw !== bw) return aw - bw;
                    const at = a.querySelector('.section-header h2')?.textContent?.toLowerCase()||'';
                    const bt = b.querySelector('.section-header h2')?.textContent?.toLowerCase()||'';
                    return at.localeCompare(bt);
                });
                const frag = document.createDocumentFragment();
                sections.forEach(s=>frag.appendChild(s));
                box.appendChild(frag);
            }
            // For A–Z sorting, also alphabetize sections
            const _origSortAlpha = window.sortAlphabetical;
            window.sortAlphaAndSections = function(){
                _origSortAlpha();
                const secContainer = document.getElementById('sectionsContainer');
                if (!secContainer) return;
                const sections = Array.from(secContainer.querySelectorAll('.section'));
                sections.sort((a,b)=>{
                    const at=a.querySelector('.section-header h2')?.textContent?.toLowerCase()||'';
                    const bt=b.querySelector('.section-header h2')?.textContent?.toLowerCase()||'';
                    return at.localeCompare(bt);
                });
                const frag=document.createDocumentFragment();
                sections.forEach(s=>frag.appendChild(s));
                secContainer.appendChild(frag);
            }
        });
        // Function Code Viewer Modal Functions
        function showFunctionCodeFromData(buttonElement) {
            const modal = document.getElementById('codeModal');
            const title = document.getElementById('codeModalTitle');
            const sourcePanelHeader = document.getElementById('sourcePanelHeader');
            const targetPanelHeader = document.getElementById('targetPanelHeader');
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            const sourceHeaderContainer = sourcePanelHeader.parentElement;
            const targetHeaderContainer = targetPanelHeader.parentElement;
            const sourceActionBtn = sourceHeaderContainer.querySelector('.copy-code-btn');
            const targetActionBtn = targetHeaderContainer.querySelector('.copy-code-btn');
            
            // Get data from button attributes
            const schemaName = buttonElement.getAttribute('data-schema');
            const functionName = buttonElement.getAttribute('data-function');
            let sourceCode = (buttonElement.getAttribute('data-source-code') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            let targetCode = (buttonElement.getAttribute('data-target-code') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            // For plans, fetch base64 from hidden textareas by id
            if (functionName === 'QueryStorePlan') {
                const srcId = buttonElement.getAttribute('data-source-plan-id');
                const tgtId = buttonElement.getAttribute('data-target-plan-id');
                if (srcId) { const el = document.getElementById(srcId); if (el) sourceCode = (el.value || el.textContent || '').replace(/&#x0D;/g, '').replace(/\r/g, ''); }
                if (tgtId) { const el = document.getElementById(tgtId); if (el) targetCode = (el.value || el.textContent || '').replace(/&#x0D;/g, '').replace(/\r/g, ''); }
            }
            
            // Helpers for downloads and decoding
            function htmlDecode(str) {
                if (!str) return '';
                const ta = document.createElement('textarea');
                ta.innerHTML = str;
                return ta.value;
            }
            function base64ToUtf8String(b64) {
                if (!b64) return '';
                // Decode base64 to bytes
                const clean = b64.replace(/\s+/g, '');
                const binary = atob(clean);
                const bytes = new Uint8Array(binary.length);
                for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
                // Decode bytes as UTF-8
                const decoder = new TextDecoder('utf-8');
                return decoder.decode(bytes);
            }
            function downloadTextFile(filename, textContent) {
                const blob = new Blob([textContent], { type: 'application/xml;charset=utf-8' });
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = filename;
                document.body.appendChild(a);
                a.click();
                a.remove();
                URL.revokeObjectURL(url);
            }
            function downloadSqlPlanUtf8(filename, xml) {
                // Ensure declaration matches UTF-8
                const fixed = xml.replace(/encoding\s*=\s*"[^"]*"/i, 'encoding="utf-8"');
                const encoder = new TextEncoder();
                const bytes = encoder.encode(fixed);
                // Add UTF-8 BOM for SSMS
                const bom = new Uint8Array([0xEF, 0xBB, 0xBF]);
                const blob = new Blob([bom, bytes], { type: 'application/xml' });
                const url = URL.createObjectURL(blob);
                const a = document.createElement('a');
                a.href = url;
                a.download = filename;
                document.body.appendChild(a);
                a.click();
                a.remove();
                URL.revokeObjectURL(url);
            }

            // Set modal title
            if (functionName === 'QueryStorePlan') {
                title.textContent = 'Execution Plan (.sqlplan)';
            } else {
                const objectType = buttonElement.getAttribute('data-object-type') || 'Function';
                title.textContent = objectType + ': ' + (schemaName ? schemaName + '.' : '') + functionName;
            }
            
            // Set panel headers
            sourcePanelHeader.textContent = 'Source Database';
            targetPanelHeader.textContent = 'Target Database';
            
            // Reset styles
            sourceCodeBlock.style.color = '#e2e8f0';
            sourceCodeBlock.style.fontStyle = 'normal';
            targetCodeBlock.style.color = '#e2e8f0';
            targetCodeBlock.style.fontStyle = 'normal';
            
            // For plans, repurpose buttons as downloaders and show raw XML
            if (functionName === 'QueryStorePlan') {
                let srcXml = '';
                let tgtXml = '';
                // Primary: base64
                try { srcXml = base64ToUtf8String(sourceCode || ''); } catch (e) { srcXml = ''; }
                try { tgtXml = base64ToUtf8String(targetCode || ''); } catch (e) { tgtXml = ''; }
                // Fallback: raw html-encoded XML (older path)
                if (!srcXml || srcXml.trim() === '' || srcXml.trim() === '<ExecutionPlan />') {
                    const raw = htmlDecode(sourceCode || '');
                    if (raw && raw.indexOf('<') !== -1) srcXml = raw;
                }
                if (!tgtXml || tgtXml.trim() === '' || tgtXml.trim() === '<ExecutionPlan />') {
                    const raw = htmlDecode(targetCode || '');
                    if (raw && raw.indexOf('<') !== -1) tgtXml = raw;
                }
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(srcXml || '<ExecutionPlan />'));
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(tgtXml || '<ExecutionPlan />'));
                // If plan XML looks empty, show message and disable download
                const looksEmptySrc = !srcXml || srcXml.trim() === '' || /<\s*ExecutionPlan\s*\/?\s*>/i.test(srcXml);
                const looksEmptyTgt = !tgtXml || tgtXml.trim() === '' || /<\s*ExecutionPlan\s*\/?\s*>/i.test(tgtXml);
                // Update buttons to Download .sqlplan
                if (sourceActionBtn) {
                    sourceActionBtn.textContent = 'Download .sqlplan';
                    sourceActionBtn.disabled = looksEmptySrc;
                    sourceActionBtn.onclick = function() {
                        if (looksEmptySrc) return;
                        downloadSqlPlanUtf8('source_plan.sqlplan', srcXml);
                    };
                }
                if (targetActionBtn) {
                    targetActionBtn.textContent = 'Download .sqlplan';
                    targetActionBtn.disabled = looksEmptyTgt;
                    targetActionBtn.onclick = function() {
                        if (looksEmptyTgt) return;
                        downloadSqlPlanUtf8('target_plan.sqlplan', tgtXml);
                    };
                }
            } else {
                // Restore copy behavior and show code with diffs
                if (sourceActionBtn) { sourceActionBtn.textContent = 'Copy'; sourceActionBtn.onclick = function(){ copyCode('sourceCodeBlock', sourceActionBtn); }; }
                if (targetActionBtn) { targetActionBtn.textContent = 'Copy'; targetActionBtn.onclick = function(){ copyCode('targetCodeBlock', targetActionBtn); }; }

                if (sourceCode && sourceCode.trim() !== '' && targetCode && targetCode.trim() !== '') {
                    const diffResult = highlightCharacterDifferences(sourceCode, targetCode);
                    sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                    targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
                } else if (sourceCode && sourceCode.trim() !== '') {
                    sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceCode));
                    targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Function not found in target database</span>');
                } else if (targetCode && targetCode.trim() !== '') {
                    sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Function not found in source database</span>');
                    targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetCode));
                } else {
                    sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Function not found in source database</span>');
                    targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Function not found in target database</span>');
                }
            }
            
            // Show modal
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden'; // Prevent background scrolling
        }
        // Function to highlight character-level differences between two code blocks
        function highlightCharacterDifferences(sourceCode, targetCode) {
            const sourceLines = sourceCode.split('\n');
            const targetLines = targetCode.split('\n');
            
            // For very large files (> 1000 lines), use faster simple line-by-line comparison
            const MAX_LINES_FOR_LCS = 1000;
            if (sourceLines.length > MAX_LINES_FOR_LCS || targetLines.length > MAX_LINES_FOR_LCS) {
                return highlightDifferencesSimple(sourceLines, targetLines);
            }
            
            // If tiny snippets (<= 2 non-empty lines combined), suppress add/delete markers
            const totalNonEmpty = sourceLines.filter(l => l.trim() !== '').length + targetLines.filter(l => l.trim() !== '').length;
            const suppressMarkers = totalNonEmpty <= 2;
            
            // Find the longest common subsequence to handle insertions/deletions properly
            const lcs = findLongestCommonSubsequence(sourceLines, targetLines);
            
            let sourceHtml = '';
            let targetHtml = '';
            let sourceIndex = 0;
            let targetIndex = 0;
            let lcsIndex = 0;
            
            while (sourceIndex < sourceLines.length || targetIndex < targetLines.length) {
                const currentSourceLine = sourceLines[sourceIndex] || '';
                const currentTargetLine = targetLines[targetIndex] || '';
                
                // Check if current lines are part of LCS
                if (lcsIndex < lcs.length && 
                    sourceIndex < sourceLines.length && 
                    targetIndex < targetLines.length &&
                    sourceLines[sourceIndex] === lcs[lcsIndex] && 
                    targetLines[targetIndex] === lcs[lcsIndex]) {
                    // Lines match - no highlighting
                    sourceHtml += escapeHtml(currentSourceLine) + '\n';
                    targetHtml += escapeHtml(currentTargetLine) + '\n';
                    sourceIndex++;
                    targetIndex++;
                    lcsIndex++;
                } else if (sourceIndex < sourceLines.length && 
                           (targetIndex >= targetLines.length || 
                            !lcs.includes(sourceLines[sourceIndex]))) {
                    // Source line is deleted (not in target)
                    if (suppressMarkers) {
                        sourceHtml += escapeHtml(currentSourceLine) + '\n';
                        targetHtml += '\n';
                    } else {
                        sourceHtml += '<span style="background-color: rgba(220, 53, 69, 0.3); color: #ff6b6b;">' + escapeHtml(currentSourceLine) + '</span>\n';
                        targetHtml += '<span style="background-color: rgba(40, 167, 69, 0.3); color: #28a745;">[Line deleted]</span>\n';
                    }
                    sourceIndex++;
                } else if (targetIndex < targetLines.length && 
                           (sourceIndex >= sourceLines.length || 
                            !lcs.includes(targetLines[targetIndex]))) {
                    // Target line is added (not in source)
                    if (suppressMarkers) {
                        sourceHtml += '\n';
                        targetHtml += escapeHtml(currentTargetLine) + '\n';
                    } else {
                        sourceHtml += '<span style="background-color: rgba(40, 167, 69, 0.3); color: #28a745;">[Line added]</span>\n';
                        targetHtml += '<span style="background-color: rgba(40, 167, 69, 0.3); color: #28a745;">' + escapeHtml(currentTargetLine) + '</span>\n';
                    }
                    targetIndex++;
                } else {
                    // Lines exist in both but are different - highlight word differences
                    const sourceHighlighted = highlightCharacterDifferencesInLine(currentSourceLine, currentTargetLine);
                    const targetHighlighted = highlightCharacterDifferencesInLine(currentTargetLine, currentSourceLine);
                    sourceHtml += sourceHighlighted + '\n';
                    targetHtml += targetHighlighted + '\n';
                    sourceIndex++;
                    targetIndex++;
                }
            }
            
            return {
                source: sourceHtml,
                target: targetHtml
            };
        }
        
        // Fast simple diff for large code blocks - just compares line by line
        function highlightDifferencesSimple(sourceLines, targetLines) {
            let sourceHtml = '';
            let targetHtml = '';
            const maxLen = Math.max(sourceLines.length, targetLines.length);
            let diffCount = 0;
            
            for (let i = 0; i < maxLen; i++) {
                const sourceLine = sourceLines[i] !== undefined ? sourceLines[i] : '';
                const targetLine = targetLines[i] !== undefined ? targetLines[i] : '';
                
                if (sourceLine !== targetLine) diffCount++;
                
                if (sourceLine === targetLine) {
                    // Lines are identical
                    sourceHtml += escapeHtml(sourceLine) + '\n';
                    targetHtml += escapeHtml(targetLine) + '\n';
                } else if (sourceLine && !targetLine) {
                    // Source has a line, target doesn't (deleted)
                    sourceHtml += '<span style="background-color: rgba(220, 53, 69, 0.3); color: #ff6b6b;">' + escapeHtml(sourceLine) + '</span>\n';
                    targetHtml += '<span style="background-color: rgba(220, 53, 69, 0.1); color: #999;">[Line removed]</span>\n';
                } else if (!sourceLine && targetLine) {
                    // Target has a line, source doesn't (added)
                    sourceHtml += '<span style="background-color: rgba(40, 167, 69, 0.1); color: #999;">[Line added]</span>\n';
                    targetHtml += '<span style="background-color: rgba(40, 167, 69, 0.3); color: #28a745;">' + escapeHtml(targetLine) + '</span>\n';
                } else {
                    // Both have lines but they're different
                    sourceHtml += '<span style="background-color: rgba(255, 193, 7, 0.3);">' + escapeHtml(sourceLine) + '</span>\n';
                    targetHtml += '<span style="background-color: rgba(255, 193, 7, 0.3);">' + escapeHtml(targetLine) + '</span>\n';
                }
            }
            
            return {
                source: sourceHtml,
                target: targetHtml
            };
        }
        
        // Simple LCS algorithm for finding common lines
        function findLongestCommonSubsequence(arr1, arr2) {
            const m = arr1.length;
            const n = arr2.length;
            const dp = Array(m + 1).fill().map(() => Array(n + 1).fill(0));
            
            // Build DP table
            for (let i = 1; i <= m; i++) {
                for (let j = 1; j <= n; j++) {
                    if (arr1[i - 1] === arr2[j - 1]) {
                        dp[i][j] = dp[i - 1][j - 1] + 1;
                    } else {
                        dp[i][j] = Math.max(dp[i - 1][j], dp[i][j - 1]);
                    }
                }
            }
            
            // Reconstruct LCS
            const lcs = [];
            let i = m, j = n;
            while (i > 0 && j > 0) {
                if (arr1[i - 1] === arr2[j - 1]) {
                    lcs.unshift(arr1[i - 1]);
                    i--;
                    j--;
                } else if (dp[i - 1][j] > dp[i][j - 1]) {
                    i--;
                } else {
                    j--;
                }
            }
            
            return lcs;
        }
        
        // Function to highlight word-level differences within a single line
        function highlightCharacterDifferencesInLine(line1, line2) {
            // Split lines into words (keeping spaces and punctuation)
            const words1 = line1.split(/(\s+|[^\w\s])/);
            const words2 = line2.split(/(\s+|[^\w\s])/);
            
            // Simple diff: find common words at the beginning and end
            let commonStart = 0;
            let commonEnd = 0;
            
            // Find common prefix
            while (commonStart < Math.min(words1.length, words2.length) && 
                   words1[commonStart] === words2[commonStart]) {
                commonStart++;
            }
            
            // Find common suffix
            while (commonEnd < Math.min(words1.length - commonStart, words2.length - commonStart) &&
                   words1[words1.length - 1 - commonEnd] === words2[words2.length - 1 - commonEnd]) {
                commonEnd++;
            }
            
            let result = '';
            
            // Add common prefix
            for (let i = 0; i < commonStart; i++) {
                result += escapeHtml(words1[i]);
            }
            
            // Add different middle part (highlighted)
            if (commonStart < words1.length - commonEnd) {
                result += '<span style="background-color: rgba(220, 53, 69, 0.3); color: #ff6b6b;">';
                for (let i = commonStart; i < words1.length - commonEnd; i++) {
                    result += escapeHtml(words1[i]);
                }
                result += '</span>';
            }
            
            // Add common suffix
            for (let i = words1.length - commonEnd; i < words1.length; i++) {
                result += escapeHtml(words1[i]);
            }
            
            return result;
        }
        // Function to format code with line numbers
        function formatCodeWithLineNumbers(htmlContent) {
            const lines = htmlContent.split('\n');
            let result = '';
            
            lines.forEach((line, index) => {
                if (line.trim() !== '') {
                    result += '<div class="code-line">';
                    result += '<div class="line-number"></div>';
                    result += '<div class="line-content">' + line + '</div>';
                    result += '</div>';
                }
            });
            
            return result;
        }
        
        // Function to copy code to clipboard
        function copyCode(elementId, buttonEl) {
            try {
                const codeBlock = document.getElementById(elementId);
                if (!codeBlock) { alert('Code block not found'); return; }
                const lineContents = codeBlock.querySelectorAll('.line-content');
                let codeText = '';
                lineContents.forEach(lineContent => {
                    const textContent = lineContent.textContent || lineContent.innerText || '';
                    codeText += textContent + '\n';
                });

                const provideFeedback = () => {
                    if (!buttonEl) return;
                    const originalText = buttonEl.textContent;
                    buttonEl.textContent = 'Copied!';
                    buttonEl.classList.add('copied');
                    setTimeout(() => {
                        buttonEl.textContent = originalText;
                        buttonEl.classList.remove('copied');
                    }, 2000);
                };

                const copyWithExecCommand = (text) => {
                    const textarea = document.createElement('textarea');
                    textarea.value = text;
                    textarea.style.position = 'fixed';
                    textarea.style.top = '-1000px';
                    textarea.style.left = '-1000px';
                    document.body.appendChild(textarea);
                    textarea.focus();
                    textarea.select();
                    let success = false;
                    try { success = document.execCommand('copy'); } catch (e) { success = false; }
                    document.body.removeChild(textarea);
                    if (success) { provideFeedback(); } else { alert('Failed to copy code to clipboard'); }
                };

                if (navigator.clipboard && window.isSecureContext) {
                    navigator.clipboard.writeText(codeText).then(() => {
                        provideFeedback();
                    }).catch(() => {
                        // Fallback for blocked clipboard
                        copyWithExecCommand(codeText);
                    });
                } else {
                    // Non-secure context (e.g., file://). Fallback.
                    copyWithExecCommand(codeText);
                }
            } catch (err) {
                console.error('Failed to copy: ', err);
                alert('Failed to copy code to clipboard');
            }
        }
        
        // Function to escape HTML characters
        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }
        function showDataTypeDetails(button) {
            const schemaName = button.getAttribute('data-schema');
            const typeName = button.getAttribute('data-type');
            const sourceDef = button.getAttribute('data-source-def');
            const targetDef = button.getAttribute('data-target-def');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'Data Type: ' + schemaName + '.' + typeName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.innerHTML = 'Source Properties <button class="view-code-btn" onclick="showDataTypeCode(\'' + schemaName + '\', \'' + typeName + '\', \'' + sourceDef + '\', \'' + targetDef + '\')">View Code</button>';
            targetHeader.innerHTML = 'Target Properties <button class="view-code-btn" onclick="showDataTypeCode(\'' + schemaName + '\', \'' + typeName + '\', \'' + sourceDef + '\', \'' + targetDef + '\')">View Code</button>';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Display source properties with highlighting
            if (sourceDef && sourceDef.trim() !== '') {
                const sourceProps = sourceDef.split('|');
                const targetProps = targetDef ? targetDef.split('|') : [];
                let sourceHtml = '';
                sourceProps.forEach((prop, index) => {
                    const isDifferent = targetProps[index] && prop !== targetProps[index];
                    const highlightClass = isDifferent ? ' class="code-diff-highlight"' : '';
                    sourceHtml += '<div class="code-line"><div class="line-number">' + (index + 1) + '</div><div class="line-content"' + highlightClass + '>' + escapeHtml(prop) + '</div></div>';
                });
                sourceCodeBlock.innerHTML = sourceHtml;
            } else {
                sourceCodeBlock.innerHTML = '<div class="code-line"><div class="line-number">1</div><div class="line-content">(Not present in source)</div></div>';
            }
            
            // Display target properties with highlighting
            if (targetDef && targetDef.trim() !== '') {
                const targetProps = targetDef.split('|');
                const sourceProps = sourceDef ? sourceDef.split('|') : [];
                let targetHtml = '';
                targetProps.forEach((prop, index) => {
                    const isDifferent = sourceProps[index] && prop !== sourceProps[index];
                    const highlightClass = isDifferent ? ' class="code-diff-highlight"' : '';
                    targetHtml += '<div class="code-line"><div class="line-number">' + (index + 1) + '</div><div class="line-content"' + highlightClass + '>' + escapeHtml(prop) + '</div></div>';
                });
                targetCodeBlock.innerHTML = targetHtml;
            } else {
                targetCodeBlock.innerHTML = '<div class="code-line"><div class="line-number">1</div><div class="line-content">(Not present in target)</div></div>';
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden'; // Prevent background scrolling
        }
        function showDataTypeCode(schemaName, typeName, sourceDef, targetDef) {
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'Data Type Code: ' + schemaName + '.' + typeName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.innerHTML = 'Source Database <button class="view-code-btn" onclick="showDataTypeDetails(document.querySelector(\'[data-schema=\\\'' + schemaName + '\\\'][data-type=\\\'' + typeName + '\\\']\'))">View Details</button>';
            targetHeader.innerHTML = 'Target Database <button class="view-code-btn" onclick="showDataTypeDetails(document.querySelector(\'[data-schema=\\\'' + schemaName + '\\\'][data-type=\\\'' + typeName + '\\\']\'))">View Details</button>';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Reset styles
            sourceCodeBlock.style.color = '#e2e8f0';
            sourceCodeBlock.style.fontStyle = 'normal';
            targetCodeBlock.style.color = '#e2e8f0';
            targetCodeBlock.style.fontStyle = 'normal';
            
            // Generate CREATE TYPE statements and apply diff highlighting
            let sourceCode = '';
            let targetCode = '';
            
            if (sourceDef && sourceDef.trim() !== '') {
                const sourceProps = sourceDef.split('|');
                sourceCode = generateCreateTypeStatement(schemaName, typeName, sourceProps);
            }
            
            if (targetDef && targetDef.trim() !== '') {
                const targetProps = targetDef.split('|');
                targetCode = generateCreateTypeStatement(schemaName, typeName, targetProps);
            }
            
            // Set code content with diff highlighting and line numbers
            if (sourceCode && sourceCode.trim() !== '' && targetCode && targetCode.trim() !== '') {
                // Both data types exist - show with character-level diff highlighting
                const diffResult = highlightCharacterDifferences(sourceCode, targetCode);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else if (sourceCode && sourceCode.trim() !== '') {
                // Only source exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceCode));
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Data type not found in target database</span>');
            } else if (targetCode && targetCode.trim() !== '') {
                // Only target exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Data type not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetCode));
            } else {
                // Neither exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Data type not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Data type not found in target database</span>');
            }
        }
        function generateCreateTypeStatement(schemaName, typeName, props) {
            // Parse properties
            const maxLength = props.find(p => p.startsWith('Max Length: '))?.split(': ')[1] || '0';
            const precision = props.find(p => p.startsWith('Precision: '))?.split(': ')[1] || '0';
            const scale = props.find(p => p.startsWith('Scale: '))?.split(': ')[1] || '0';
            const isNullable = props.find(p => p.startsWith('Is Nullable: '))?.split(': ')[1] === 'True';
            const systemTypeId = props.find(p => p.startsWith('System Type ID: '))?.split(': ')[1] || '0';
            
            // Map system type IDs to SQL Server types
            const typeMap = {
                '56': 'int',
                '52': 'smallint',
                '48': 'tinyint',
                '62': 'float',
                '59': 'real',
                '60': 'money',
                '122': 'smallmoney',
                '104': 'bit',
                '175': 'char',
                '167': 'varchar',
                '231': 'nvarchar',
                '239': 'nchar',
                '35': 'text',
                '99': 'ntext',
                '40': 'date',
                '41': 'time',
                '42': 'datetime2',
                '43': 'datetimeoffset',
                '58': 'smalldatetime',
                '61': 'datetime',
                '106': 'decimal',
                '108': 'numeric',
                '36': 'uniqueidentifier',
                '165': 'varbinary',
                '167': 'binary'
            };
            
            const baseType = typeMap[systemTypeId] || 'varchar';
            let typeDef = baseType;
            
            if (baseType === 'varchar' || baseType === 'nvarchar' || baseType === 'char' || baseType === 'nchar') {
                if (maxLength === '-1') {
                    typeDef += '(max)';
                } else if (maxLength !== '0') {
                    typeDef += '(' + maxLength + ')';
                }
            } else if (baseType === 'decimal' || baseType === 'numeric') {
                if (precision !== '0' || scale !== '0') {
                    typeDef += '(' + precision + ',' + scale + ')';
                }
            }
            
            const nullable = isNullable ? 'NULL' : 'NOT NULL';
            
            return 'CREATE TYPE [' + schemaName + '].[' + typeName + '] FROM [' + typeDef + '] ' + nullable;
        }
        function showTableCode(button) {
            const schemaName = button.getAttribute('data-schema');
            const tableName = button.getAttribute('data-table');
            const sourceCreateStatement = (button.getAttribute('data-source-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const targetCreateStatement = (button.getAttribute('data-target-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const sourceCreateDate = button.getAttribute('data-source-create-date');
            const targetCreateDate = button.getAttribute('data-target-create-date');
            const sourceModifyDate = button.getAttribute('data-source-modify-date');
            const targetModifyDate = button.getAttribute('data-target-modify-date');
            const sourceRowCount = button.getAttribute('data-source-row-count');
            const targetRowCount = button.getAttribute('data-target-row-count');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'Table: ' + schemaName + '.' + tableName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.textContent = 'Source Database';
            targetHeader.textContent = 'Target Database';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Reset styles
            sourceCodeBlock.style.color = '#e2e8f0';
            sourceCodeBlock.style.fontStyle = 'normal';
            targetCodeBlock.style.color = '#e2e8f0';
            targetCodeBlock.style.fontStyle = 'normal';
            
            // Set code content with diff highlighting and line numbers
            if (sourceCreateStatement && sourceCreateStatement.trim() !== '' && targetCreateStatement && targetCreateStatement.trim() !== '') {
                // Both tables exist - show with character-level diff highlighting
                const diffResult = highlightCharacterDifferences(sourceCreateStatement, targetCreateStatement);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else if (sourceCreateStatement && sourceCreateStatement.trim() !== '') {
                // Only source exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceCreateStatement));
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Table not found in target database</span>');
            } else if (targetCreateStatement && targetCreateStatement.trim() !== '') {
                // Only target exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Table not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetCreateStatement));
            } else {
                // Neither exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Table not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Table not found in target database</span>');
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden';
        }
        
        function showColumnCode(button) {
            const schemaName = button.getAttribute('data-schema');
            const tableName = button.getAttribute('data-table');
            const columnName = button.getAttribute('data-column');
            const sourceCreateStatement = (button.getAttribute('data-source-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const targetCreateStatement = (button.getAttribute('data-target-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const sourceDataType = button.getAttribute('data-source-datatype');
            const targetDataType = button.getAttribute('data-target-datatype');
            const sourceNullable = button.getAttribute('data-source-nullable');
            const targetNullable = button.getAttribute('data-target-nullable');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'Column: ' + schemaName + '.' + tableName + '.' + columnName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.textContent = 'Source Database';
            targetHeader.textContent = 'Target Database';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Reset styles
            sourceCodeBlock.style.color = '#e2e8f0';
            sourceCodeBlock.style.fontStyle = 'normal';
            targetCodeBlock.style.color = '#e2e8f0';
            targetCodeBlock.style.fontStyle = 'normal';
            
            // Set code content with diff highlighting and line numbers
            if (sourceCreateStatement && sourceCreateStatement.trim() !== '' && targetCreateStatement && targetCreateStatement.trim() !== '') {
                // Both columns exist - show with character-level diff highlighting
                const diffResult = highlightCharacterDifferences(sourceCreateStatement, targetCreateStatement);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else if (sourceCreateStatement && sourceCreateStatement.trim() !== '') {
                // Only source exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceCreateStatement));
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Column not found in target database</span>');
            } else if (targetCreateStatement && targetCreateStatement.trim() !== '') {
                // Only target exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Column not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetCreateStatement));
            } else {
                // Neither exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Column not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Column not found in target database</span>');
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden';
        }
        function showIndexCode(button) {
            const schemaName = button.getAttribute('data-schema');
            const tableName = button.getAttribute('data-table');
            const indexName = button.getAttribute('data-index');
            const sourceCreateStatement = (button.getAttribute('data-source-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const targetCreateStatement = (button.getAttribute('data-target-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const sourceIndexType = button.getAttribute('data-source-index-type');
            const targetIndexType = button.getAttribute('data-target-index-type');
            const sourceIsUnique = button.getAttribute('data-source-is-unique');
            const targetIsUnique = button.getAttribute('data-target-is-unique');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'Index: ' + schemaName + '.' + tableName + '.' + indexName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.textContent = 'Source Database';
            targetHeader.textContent = 'Target Database';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Reset styles
            sourceCodeBlock.style.color = '#e2e8f0';
            sourceCodeBlock.style.fontStyle = 'normal';
            targetCodeBlock.style.color = '#e2e8f0';
            targetCodeBlock.style.fontStyle = 'normal';
            
            // Set code content with diff highlighting and line numbers
            if (sourceCreateStatement && sourceCreateStatement.trim() !== '' && targetCreateStatement && targetCreateStatement.trim() !== '') {
                // Both indexes exist - show with character-level diff highlighting
                const diffResult = highlightCharacterDifferences(sourceCreateStatement, targetCreateStatement);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else if (sourceCreateStatement && sourceCreateStatement.trim() !== '') {
                // Only source exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceCreateStatement));
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Index not found in target database</span>');
            } else if (targetCreateStatement && targetCreateStatement.trim() !== '') {
                // Only target exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Index not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetCreateStatement));
            } else {
                // Neither exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Index not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Index not found in target database</span>');
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden';
        }
        function showConstraintCode(button) {
            const schemaName = button.getAttribute('data-schema');
            const tableName = button.getAttribute('data-table');
            const constraintName = button.getAttribute('data-constraint');
            const sourceCreateStatement = (button.getAttribute('data-source-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const targetCreateStatement = (button.getAttribute('data-target-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const sourceType = button.getAttribute('data-source-type');
            const targetType = button.getAttribute('data-target-type');
            const sourceDisabled = button.getAttribute('data-source-disabled');
            const targetDisabled = button.getAttribute('data-target-disabled');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'Constraint: ' + schemaName + '.' + tableName + '.' + constraintName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.textContent = 'Source Database';
            targetHeader.textContent = 'Target Database';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Reset styles
            sourceCodeBlock.style.color = '#e2e8f0';
            sourceCodeBlock.style.fontStyle = 'normal';
            targetCodeBlock.style.color = '#e2e8f0';
            targetCodeBlock.style.fontStyle = 'normal';
            
            // Set code content with diff highlighting and line numbers
            if (sourceCreateStatement && sourceCreateStatement.trim() !== '' && targetCreateStatement && targetCreateStatement.trim() !== '') {
                // Both constraints exist - show with character-level diff highlighting
                const diffResult = highlightCharacterDifferences(sourceCreateStatement, targetCreateStatement);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else if (sourceCreateStatement && sourceCreateStatement.trim() !== '') {
                // Only source exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceCreateStatement));
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Constraint not found in target database</span>');
            } else if (targetCreateStatement && targetCreateStatement.trim() !== '') {
                // Only target exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Constraint not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetCreateStatement));
            } else {
                // Neither exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Constraint not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Constraint not found in target database</span>');
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden';
        }
        function showViewCode(button) {
            const schemaName = button.getAttribute('data-schema');
            const viewName = button.getAttribute('data-view');
            const sourceCode = (button.getAttribute('data-source-code') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const targetCode = (button.getAttribute('data-target-code') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const sourceCreateDate = button.getAttribute('data-source-create-date');
            const targetCreateDate = button.getAttribute('data-target-create-date');
            const sourceModifyDate = button.getAttribute('data-source-modify-date');
            const targetModifyDate = button.getAttribute('data-target-modify-date');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'View: ' + schemaName + '.' + viewName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.textContent = 'Source Database';
            targetHeader.textContent = 'Target Database';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Reset styles
            sourceCodeBlock.style.color = '#e2e8f0';
            sourceCodeBlock.style.fontStyle = 'normal';
            targetCodeBlock.style.color = '#e2e8f0';
            targetCodeBlock.style.fontStyle = 'normal';
            
            // Set code content with diff highlighting and line numbers
            if (sourceCode && sourceCode.trim() !== '' && targetCode && targetCode.trim() !== '') {
                // Both views exist - show with character-level diff highlighting
                const diffResult = highlightCharacterDifferences(sourceCode, targetCode);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else if (sourceCode && sourceCode.trim() !== '') {
                // Only source exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceCode));
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">View not found in target database</span>');
            } else if (targetCode && targetCode.trim() !== '') {
                // Only target exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">View not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetCode));
            } else {
                // Neither exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">View not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">View not found in target database</span>');
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden';
        }
        function showSynonymCode(button) {
            const schemaName = button.getAttribute('data-schema');
            const synonymName = button.getAttribute('data-synonym');
            const sourceCreateStatement = (button.getAttribute('data-source-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const targetCreateStatement = (button.getAttribute('data-target-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const sourceBaseObject = button.getAttribute('data-source-base-object');
            const targetBaseObject = button.getAttribute('data-target-base-object');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'Synonym: ' + schemaName + '.' + synonymName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.textContent = 'Source Database';
            targetHeader.textContent = 'Target Database';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Reset styles
            sourceCodeBlock.style.color = '#e2e8f0';
            sourceCodeBlock.style.fontStyle = 'normal';
            targetCodeBlock.style.color = '#e2e8f0';
            targetCodeBlock.style.fontStyle = 'normal';
            
            // Set code content with diff highlighting and line numbers
            if (sourceCreateStatement && sourceCreateStatement.trim() !== '' && targetCreateStatement && targetCreateStatement.trim() !== '') {
                // Both synonyms exist - show with character-level diff highlighting
                const diffResult = highlightCharacterDifferences(sourceCreateStatement, targetCreateStatement);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else if (sourceCreateStatement && sourceCreateStatement.trim() !== '') {
                // Only source exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceCreateStatement));
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Synonym not found in target database</span>');
            } else if (targetCreateStatement && targetCreateStatement.trim() !== '') {
                // Only target exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Synonym not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetCreateStatement));
            } else {
                // Neither exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Synonym not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Synonym not found in target database</span>');
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden';
        }
        function showTableTriggerCode(button) {
            const schemaName = button.getAttribute('data-schema');
            const tableName = button.getAttribute('data-table');
            const triggerName = button.getAttribute('data-trigger');
            const sourceCreateStatement = (button.getAttribute('data-source-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const targetCreateStatement = (button.getAttribute('data-target-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const sourceIsDisabled = button.getAttribute('data-source-disabled');
            const targetIsDisabled = button.getAttribute('data-target-disabled');
            const sourceIsInsteadOf = button.getAttribute('data-source-instead-of');
            const targetIsInsteadOf = button.getAttribute('data-target-instead-of');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'Table Trigger: ' + schemaName + '.' + tableName + '.' + triggerName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.textContent = 'Source Database';
            targetHeader.textContent = 'Target Database';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Reset styles
            sourceCodeBlock.style.color = '#e2e8f0';
            sourceCodeBlock.style.fontStyle = 'normal';
            targetCodeBlock.style.color = '#e2e8f0';
            targetCodeBlock.style.fontStyle = 'normal';
            
            // Set code content with diff highlighting and line numbers
            if (sourceCreateStatement && sourceCreateStatement.trim() !== '' && targetCreateStatement && targetCreateStatement.trim() !== '') {
                // Both triggers exist - show with character-level diff highlighting
                const diffResult = highlightCharacterDifferences(sourceCreateStatement, targetCreateStatement);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else if (sourceCreateStatement && sourceCreateStatement.trim() !== '') {
                // Only source exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceCreateStatement));
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Table trigger not found in target database</span>');
            } else if (targetCreateStatement && targetCreateStatement.trim() !== '') {
                // Only target exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Table trigger not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetCreateStatement));
            } else {
                // Neither exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Table trigger not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Table trigger not found in target database</span>');
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden';
        }
        
        function showDatabaseTriggerCode(button) {
            const triggerName = button.getAttribute('data-trigger');
            const sourceCreateStatement = (button.getAttribute('data-source-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const targetCreateStatement = (button.getAttribute('data-target-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const sourceIsDisabled = button.getAttribute('data-source-disabled');
            const targetIsDisabled = button.getAttribute('data-target-disabled');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'Database Trigger: ' + triggerName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.textContent = 'Source Database';
            targetHeader.textContent = 'Target Database';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Reset styles
            sourceCodeBlock.style.color = '#e2e8f0';
            sourceCodeBlock.style.fontStyle = 'normal';
            targetCodeBlock.style.color = '#e2e8f0';
            targetCodeBlock.style.fontStyle = 'normal';
            
            // Set code content with diff highlighting and line numbers
            if (sourceCreateStatement && sourceCreateStatement.trim() !== '' && targetCreateStatement && targetCreateStatement.trim() !== '') {
                // Both triggers exist - show with character-level diff highlighting
                const diffResult = highlightCharacterDifferences(sourceCreateStatement, targetCreateStatement);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else if (sourceCreateStatement && sourceCreateStatement.trim() !== '') {
                // Only source exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceCreateStatement));
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Database trigger not found in target database</span>');
            } else if (targetCreateStatement && targetCreateStatement.trim() !== '') {
                // Only target exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Database trigger not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetCreateStatement));
            } else {
                // Neither exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Database trigger not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Database trigger not found in target database</span>');
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden';
        }
        function showKeyCode(button) {
            const schemaName = button.getAttribute('data-schema');
            const tableName = button.getAttribute('data-table');
            const keyName = button.getAttribute('data-key');
            const sourceCode = (button.getAttribute('data-source-code') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const targetCode = (button.getAttribute('data-target-code') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const sourceKeyType = button.getAttribute('data-source-key-type');
            const targetKeyType = button.getAttribute('data-target-key-type');
            const sourceIsPrimary = button.getAttribute('data-source-is-primary');
            const targetIsPrimary = button.getAttribute('data-target-is-primary');
            const sourceIsUnique = button.getAttribute('data-source-is-unique');
            const targetIsUnique = button.getAttribute('data-target-is-unique');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'Key: ' + schemaName + '.' + tableName + '.' + keyName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.textContent = 'Source Database';
            targetHeader.textContent = 'Target Database';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Reset styles
            sourceCodeBlock.style.color = '#e2e8f0';
            sourceCodeBlock.style.fontStyle = 'normal';
            targetCodeBlock.style.color = '#e2e8f0';
            targetCodeBlock.style.fontStyle = 'normal';
            
            // Set code content with diff highlighting and line numbers
            if (sourceCode && sourceCode.trim() !== '' && targetCode && targetCode.trim() !== '') {
                // Both keys exist - show with character-level diff highlighting
                const diffResult = highlightCharacterDifferences(sourceCode, targetCode);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else if (sourceCode && sourceCode.trim() !== '') {
                // Only source exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceCode));
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Key not found in target database</span>');
            } else if (targetCode && targetCode.trim() !== '') {
                // Only target exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Key not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetCode));
            } else {
                // Neither exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Key not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Key not found in target database</span>');
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden';
        }
        function showFileCode(button) {
            const fileName = button.getAttribute('data-file');
            const sourceCreate = (button.getAttribute('data-source-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const targetCreate = (button.getAttribute('data-target-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const sourceType = button.getAttribute('data-source-type');
            const targetType = button.getAttribute('data-target-type');
            const sourceSize = button.getAttribute('data-source-size');
            const targetSize = button.getAttribute('data-target-size');
            const sourceFilegroup = button.getAttribute('data-source-filegroup');
            const targetFilegroup = button.getAttribute('data-target-filegroup');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'File: ' + fileName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.textContent = 'Source Database';
            targetHeader.textContent = 'Target Database';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Set code content with diff highlighting and line numbers
            if (sourceCreate && sourceCreate.trim() !== '' && targetCreate && targetCreate.trim() !== '') {
                // Both files exist - show with character-level diff highlighting
                const diffResult = highlightCharacterDifferences(sourceCreate, targetCreate);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else if (sourceCreate && sourceCreate.trim() !== '') {
                // Only source exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceCreate));
                targetCodeBlock.innerHTML = '<div class="no-code">File does not exist in target database</div>';
            } else if (targetCreate && targetCreate.trim() !== '') {
                // Only target exists
                sourceCodeBlock.innerHTML = '<div class="no-code">File does not exist in source database</div>';
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetCreate));
            } else {
                // No code available
                sourceCodeBlock.innerHTML = '<div class="no-code">No file information available</div>';
                targetCodeBlock.innerHTML = '<div class="no-code">No file information available</div>';
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden';
        }
        function showVLFCountCode(button) {
            const sourceCount = button.getAttribute('data-source-count');
            const targetCount = button.getAttribute('data-target-count');
            const sourceDb = button.getAttribute('data-source-db');
            const targetDb = button.getAttribute('data-target-db');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'VLF Count Comparison';
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.textContent = 'Source Database (' + sourceDb + ')';
            targetHeader.textContent = 'Target Database (' + targetDb + ')';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Create VLF count information display
            const sourceVlfInfo = 'Database: ' + sourceDb + '\nVLF Count: ' + sourceCount + '\nCommand: DBCC LOGINFO(\'' + sourceDb + '\')';
            const targetVlfInfo = 'Database: ' + targetDb + '\nVLF Count: ' + targetCount + '\nCommand: DBCC LOGINFO(\'' + targetDb + '\')';
            
            // Set code content with diff highlighting if counts differ
            if (sourceCount !== targetCount) {
                const diffResult = highlightCharacterDifferences(sourceVlfInfo, targetVlfInfo);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else {
                // Counts match - no highlighting needed
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceVlfInfo));
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetVlfInfo));
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden';
        }
        function showUserCode(button) {
            const userName = button.getAttribute('data-user');
            const sourceCreate = (button.getAttribute('data-source-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const targetCreate = (button.getAttribute('data-target-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const sourceType = button.getAttribute('data-source-type');
            const targetType = button.getAttribute('data-target-type');
            const sourceRoles = button.getAttribute('data-source-roles');
            const targetRoles = button.getAttribute('data-target-roles');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'User: ' + userName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.textContent = 'Source Database';
            targetHeader.textContent = 'Target Database';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Create user information display
            const sourceUserInfo = 'User: ' + userName + '\nType: ' + sourceType + '\nRole Memberships: ' + (sourceRoles || 'None') + '\n\nCREATE Statement:\n' + sourceCreate;
            const targetUserInfo = 'User: ' + userName + '\nType: ' + targetType + '\nRole Memberships: ' + (targetRoles || 'None') + '\n\nCREATE Statement:\n' + targetCreate;
            
            // Set code content with diff highlighting
            if (sourceCreate && sourceCreate.trim() !== '' && targetCreate && targetCreate.trim() !== '') {
                // Both users exist - show with character-level diff highlighting
                const diffResult = highlightCharacterDifferences(sourceUserInfo, targetUserInfo);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else if (sourceCreate && sourceCreate.trim() !== '') {
                // Only source exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceUserInfo));
                targetCodeBlock.innerHTML = '<div class="no-code">User does not exist in target database</div>';
            } else if (targetCreate && targetCreate.trim() !== '') {
                // Only target exists
                sourceCodeBlock.innerHTML = '<div class="no-code">User does not exist in source database</div>';
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetUserInfo));
            } else {
                // No code available
                sourceCodeBlock.innerHTML = '<div class="no-code">No user information available</div>';
                targetCodeBlock.innerHTML = '<div class="no-code">No user information available</div>';
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden';
        }
        
        function showRoleCode(button) {
            const roleName = button.getAttribute('data-role');
            const sourceCreate = (button.getAttribute('data-source-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const targetCreate = (button.getAttribute('data-target-create') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const sourceType = button.getAttribute('data-source-type');
            const targetType = button.getAttribute('data-target-type');
            const sourceMembers = button.getAttribute('data-source-members');
            const targetMembers = button.getAttribute('data-target-members');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'Role: ' + roleName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.textContent = 'Source Database';
            targetHeader.textContent = 'Target Database';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Set code content with diff highlighting
            if (sourceCreate && sourceCreate.trim() !== '' && targetCreate && targetCreate.trim() !== '') {
                // Both roles exist - show with character-level diff highlighting
                const diffResult = highlightCharacterDifferences(sourceCreate, targetCreate);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else if (sourceCreate && sourceCreate.trim() !== '') {
                // Only source exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceCreate));
                targetCodeBlock.innerHTML = '<div class="no-code">Role does not exist in target database</div>';
            } else if (targetCreate && targetCreate.trim() !== '') {
                // Only target exists
                sourceCodeBlock.innerHTML = '<div class="no-code">Role does not exist in source database</div>';
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetCreate));
            } else {
                // No code available
                sourceCodeBlock.innerHTML = '<div class="no-code">No role information available</div>';
                targetCodeBlock.innerHTML = '<div class="no-code">No role information available</div>';
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden';
        }
        function showDatabaseOptionCode(button) {
            const databaseName = button.getAttribute('data-database');
            const optionName = button.getAttribute('data-option');
            const sourceCode = (button.getAttribute('data-source-code') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const targetCode = (button.getAttribute('data-target-code') || '').replace(/&#x0D;/g, '').replace(/\r/g, '');
            const sourceValue = button.getAttribute('data-source-value');
            const targetValue = button.getAttribute('data-target-value');
            
            // Update modal title
            const title = document.getElementById('codeModalTitle');
            title.textContent = 'Database Option: ' + databaseName + '.' + optionName;
            
            // Update panel headers
            const sourceHeader = document.getElementById('sourcePanelHeader');
            const targetHeader = document.getElementById('targetPanelHeader');
            sourceHeader.textContent = 'Source Database';
            targetHeader.textContent = 'Target Database';
            
            // Get code blocks
            const sourceCodeBlock = document.getElementById('sourceCodeBlock');
            const targetCodeBlock = document.getElementById('targetCodeBlock');
            
            // Reset styles
            sourceCodeBlock.style.color = '#e2e8f0';
            sourceCodeBlock.style.fontStyle = 'normal';
            targetCodeBlock.style.color = '#e2e8f0';
            targetCodeBlock.style.fontStyle = 'normal';
            
            // Set code content with diff highlighting and line numbers
            if (sourceCode && sourceCode.trim() !== '' && targetCode && targetCode.trim() !== '') {
                // Both database option settings exist - show with character-level diff highlighting
                const diffResult = highlightCharacterDifferences(sourceCode, targetCode);
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.source);
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(diffResult.target);
            } else if (sourceCode && sourceCode.trim() !== '') {
                // Only source exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(sourceCode));
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Database option setting not found in target database</span>');
            } else if (targetCode && targetCode.trim() !== '') {
                // Only target exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Database option setting not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers(escapeHtml(targetCode));
            } else {
                // Neither exists
                sourceCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Database option setting not found in source database</span>');
                targetCodeBlock.innerHTML = formatCodeWithLineNumbers('<span style="color: #dc3545; font-style: italic;">Database option setting not found in target database</span>');
            }
            
            // Show modal
            const modal = document.getElementById('codeModal');
            modal.style.display = 'block';
            document.body.style.overflow = 'hidden';
        }
        
        function closeCodeModal() {
            const modal = document.getElementById('codeModal');
            modal.style.display = 'none';
            document.body.style.overflow = 'auto'; // Restore scrolling
        }
        
        // Close modal when clicking outside of it
        window.onclick = function(event) {
            const modal = document.getElementById('codeModal');
            if (event.target === modal) {
                closeCodeModal();
            }
        }
        
        // Close modal with Escape key
        document.addEventListener('keydown', function(event) {
            if (event.key === 'Escape') {
                closeCodeModal();
            }
        });
        // Function to toggle section collapse/expand
        function toggleSection(sectionId) {
            const content = document.getElementById(sectionId + '-content');
            const toggle = document.getElementById(sectionId + '-header').querySelector('.toggle');
            
            if (!content || !toggle) {
                console.error('Could not find content or toggle for section:', sectionId);
                return;
            }
            
            if (content.classList.contains('expanded')) {
                content.classList.remove('expanded');
                content.style.maxHeight = '0';
                content.style.opacity = '0';
                toggle.textContent = '[+]';
                // Unselect matching summary card without relying on inner-scope helpers
                const cards = document.querySelectorAll('#summaryCards .summary-card');
                const idNorm = (sectionId||'').toString().toLowerCase().replace(/\s+/g,'-');
                cards.forEach(card => {
                    const h = card.querySelector('h3');
                    if(!h) return;
                    const norm = h.textContent.trim().toLowerCase().replace(/\s+/g,'-');
                    if(norm === idNorm) card.classList.remove('selected');
                });
            } else {
                content.classList.add('expanded');
                content.style.maxHeight = '5000px';
                content.style.opacity = '1';
                toggle.textContent = '[-]';
            }
        }
        
        // Toggle all sections with a single floating button
        function toggleAllSections() {
            const sections = document.querySelectorAll('.section');
            const btn = document.getElementById('toggleAllBtn');
            if (!sections || sections.length === 0 || !btn) return;
            
            // Expand if any section is collapsed
            const anyCollapsed = Array.from(sections).some(sec => {
                const content = sec.querySelector('.section-content');
                return content && !content.classList.contains('expanded');
            });
            
            sections.forEach(sec => {
                const headerDiv = sec.querySelector('.section-header');
                const content = sec.querySelector('.section-content');
                const toggle = headerDiv ? headerDiv.querySelector('.toggle') : null;
                if (!headerDiv || !content || !toggle) return;
                
                if (anyCollapsed) {
                    // expand
                    content.classList.add('expanded');
                    content.style.maxHeight = '5000px';
                    content.style.opacity = '1';
                    toggle.textContent = '[-]';
                } else {
                    // collapse
                    content.classList.remove('expanded');
                    content.style.maxHeight = '0';
                    content.style.opacity = '0';
                    toggle.textContent = '[+]';
                    // Unselect corresponding summary card (no helper dependency)
                    const secId = (headerDiv.id||'').replace(/-header$/,'');
                    const idNorm = (secId||'').toString().toLowerCase().replace(/\s+/g,'-');
                    const cards = document.querySelectorAll('#summaryCards .summary-card');
                    cards.forEach(card => {
                        const h = card.querySelector('h3');
                        if(!h) return;
                        const norm = h.textContent.trim().toLowerCase().replace(/\s+/g,'-');
                        if(norm === idNorm) card.classList.remove('selected');
                    });
                }
            });
            
            btn.textContent = anyCollapsed ? 'Collapse All' : 'Expand All';
        }
        
        // Function to navigate to section (without auto-expanding)
        function navigateToSection(sectionName) {
            const sectionId = sectionName.toLowerCase().replace(' ', '-');
            const sectionElement = document.getElementById(sectionId + '-header');
            
            if (sectionElement) {
                // Just scroll to the section without expanding
                sectionElement.scrollIntoView({ 
                    behavior: 'smooth',
                    block: 'start'
                });
            }
        }
        
        // Function to select all filters and show all data
        function selectAllFiltersAndShowAll(sectionName) {
            const sectionId = sectionName.toLowerCase().replace(' ', '-');
            
            // Navigate to the section
            navigateToSection(sectionName);
            
            // Expand the section if collapsed
            const content = document.getElementById(sectionId + '-content');
            if (content && !content.classList.contains('expanded')) {
                toggleSection(sectionId);
            }
            
            // Check all status checkboxes (select all)
            const mismatchCheckbox = document.getElementById('show-mismatch-' + sectionId);
            const matchCheckbox = document.getElementById('show-match-' + sectionId);
            const sourceOnlyCheckbox = document.getElementById('show-source-only-' + sectionId);
            const targetOnlyCheckbox = document.getElementById('show-target-only-' + sectionId);
            
            if (mismatchCheckbox) mismatchCheckbox.checked = true;
            if (matchCheckbox) matchCheckbox.checked = true;
            if (sourceOnlyCheckbox) sourceOnlyCheckbox.checked = true;
            if (targetOnlyCheckbox) targetOnlyCheckbox.checked = true;
            
            // Clear the text filter
            const filterInput = document.getElementById('filter-' + sectionId);
            if (filterInput) filterInput.value = '';
            
            // Apply filters to show all data
            if (typeof applyFilters === 'function') {
                applyFilters(sectionId);
            }
        }
        
        // Function to filter by specific status type
        function filterByStatus(sectionName, statusType, event) {
            // Stop event propagation to prevent summary card click
            if (event) {
                event.stopPropagation();
            }
            
            const sectionId = sectionName.toLowerCase().replace(' ', '-');
            
            // Navigate to the section
            navigateToSection(sectionName);
            
            // Expand the section for status filtering (only if collapsed)
            const content = document.getElementById(sectionId + '-content');
            if (content && !content.classList.contains('expanded')) {
                toggleSection(sectionId);
            }
            
            // Uncheck all status checkboxes
            const mismatchCheckbox = document.getElementById('show-mismatch-' + sectionId);
            const matchCheckbox = document.getElementById('show-match-' + sectionId);
            const sourceOnlyCheckbox = document.getElementById('show-source-only-' + sectionId);
            const targetOnlyCheckbox = document.getElementById('show-target-only-' + sectionId);
            
            if (mismatchCheckbox) mismatchCheckbox.checked = false;
            if (matchCheckbox) matchCheckbox.checked = false;
            if (sourceOnlyCheckbox) sourceOnlyCheckbox.checked = false;
            if (targetOnlyCheckbox) targetOnlyCheckbox.checked = false;
            
            // Check only the selected status type
            switch (statusType) {
                case 'mismatch':
                    if (mismatchCheckbox) mismatchCheckbox.checked = true;
                    break;
                case 'match':
                    if (matchCheckbox) matchCheckbox.checked = true;
                    break;
                case 'source-only':
                    if (sourceOnlyCheckbox) sourceOnlyCheckbox.checked = true;
                    break;
                case 'target-only':
                    if (targetOnlyCheckbox) targetOnlyCheckbox.checked = true;
                    break;
            }
            
            // Apply the filters
            if (typeof applyFilters === 'function') {
                applyFilters(sectionId);
            }
        }
        // Initialize all sections as collapsed on page load
        document.addEventListener('DOMContentLoaded', function() {
            // All sections start collapsed by default
            const sections = document.querySelectorAll('.section-content');
            sections.forEach(section => {
                section.classList.remove('expanded');
                section.style.maxHeight = '0';
                section.style.opacity = '0';
            });
            
            // Set all toggle buttons to [+]
            const toggles = document.querySelectorAll('.toggle');
            toggles.forEach(toggle => {
                toggle.textContent = '[+]';
            });
        });
    </script>
    <!-- Include JSZip (dependency for ExcelJS in browsers) -->
    <script src="https://cdnjs.cloudflare.com/ajax/libs/jszip/3.10.1/jszip.min.js"></script>
    <!-- Include ExcelJS for Excel export with styling support -->
    <script src="https://cdnjs.cloudflare.com/ajax/libs/exceljs/4.3.0/exceljs.min.js"></script>
    <!-- Include jsPDF for PDF export -->
    <script src="https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js"></script>
    <script>
        // Wait for ExcelJS library to load with timeout
        function waitForExcelJS(callback, timeout = 30000) {
            const startTime = Date.now();
            
            function check() {
            if (typeof ExcelJS !== 'undefined') {
                callback();
                } else if (Date.now() - startTime > timeout) {
                    console.error('ExcelJS library failed to load within timeout period');
                    alert('Error: Excel export library failed to load.\n\nPossible causes:\n1. No internet connection\n2. CDN blocked by firewall\n3. Network timeout\n\nPlease check your internet connection and try again.');
            } else {
                    setTimeout(check, 100);
            }
            }
            
            check();
        }
        
        // Export to Excel functionality - only expanded sections with ExcelJS
        function exportToExcel() {
            console.log('Starting Excel export...');
            
            waitForExcelJS(() => {
                console.log('ExcelJS library loaded successfully');
                
                const sections = document.querySelectorAll('.section');
                let hasExpandedSections = false;
                
                // Create a new workbook
                const workbook = new ExcelJS.Workbook();
                
                // Create Summary sheet first
                const summarySheet = workbook.addWorksheet('Summary');
                
                // Get summary card data - ONLY include expanded sections
                const summaryCards = document.querySelectorAll('.summary-card');
                const summaryData = [
                    ['Category', 'Matches', 'Source Only', 'Target Only', 'Differences']
                ];
                
                // Build set of currently expanded section titles from the real sections
                const expandedSectionTitles = new Set(
                    Array.from(document.querySelectorAll('.section')).map(sec => {
                        const title = (sec.querySelector('h2')?.textContent || '').trim();
                        const content = sec.querySelector('.section-content');
                        return content && content.classList.contains('expanded') ? title : null;
                    }).filter(Boolean)
                );
                
                summaryCards.forEach(card => {
                    const title = (card.querySelector('h3')?.textContent || '').trim();
                    if (!expandedSectionTitles.has(title)) return; // skip collapsed
                    // Fallback: our cards render four '.count' spans in order: Match, Source Only, Target Only, Differences
                    const counts = Array.from(card.querySelectorAll('.count')).map(el => (el.textContent || '0').trim());
                    if (counts.length >= 4) {
                        const matchCount = parseInt(counts[0], 10) || 0;
                        const sourceOnlyCount = parseInt(counts[1], 10) || 0;
                        const targetOnlyCount = parseInt(counts[2], 10) || 0;
                        const differenceCount = parseInt(counts[3], 10) || 0;
                        summaryData.push([title, matchCount, sourceOnlyCount, targetOnlyCount, differenceCount]);
                    }
                });
                
                // Add summary data to worksheet
                summaryData.forEach((rowData, rowIndex) => {
                    const row = summarySheet.addRow(rowData);
                    
                    // Style header row
                    if (rowIndex === 0) {
                        row.eachCell((cell, colNumber) => {
                            cell.font = { bold: true, color: { argb: 'FFFFFFFF' } };
                            cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF4472C4' } };
                            cell.alignment = { horizontal: 'center', vertical: 'middle' };
                            cell.border = {
                                top: { style: 'thin', color: { argb: 'FF000000' } },
                                left: { style: 'thin', color: { argb: 'FF000000' } },
                                bottom: { style: 'thin', color: { argb: 'FF000000' } },
                                right: { style: 'thin', color: { argb: 'FF000000' } }
                            };
                        });
                    } else {
                        // Style data rows with explicit column colors
                        row.eachCell((cell, colNumber) => {
                            // Set borders first
                            cell.border = {
                                top: { style: 'thin', color: { argb: 'FFD0D0D0' } },
                                left: { style: 'thin', color: { argb: 'FFD0D0D0' } },
                                bottom: { style: 'thin', color: { argb: 'FFD0D0D0' } },
                                right: { style: 'thin', color: { argb: 'FFD0D0D0' } }
                            };
                            cell.alignment = { horizontal: 'center', vertical: 'middle' };
                            
                            // Apply specific colors for each column (ExcelJS uses 1-based indexing)
                            switch (colNumber) {
                                case 1: // Category - White
                                    cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFFFFFFF' } };
                                    cell.font = { color: { argb: 'FF000000' } };
                                    break;
                                case 2: // Matches - Green
                                    cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFD5E8D4' } };
                                    cell.font = { color: { argb: 'FF2F5233' } };
                                    break;
                                case 3: // Source Only - Yellow
                                    cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFFFF3CD' } };
                                    cell.font = { color: { argb: 'FF856404' } };
                                    break;
                                case 4: // Target Only - Blue
                                    cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFD1ECF1' } };
                                    cell.font = { color: { argb: 'FF0C5460' } };
                                    break;
                                case 5: // Differences - Red
                                    cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF8D7DA' } };
                                    cell.font = { color: { argb: 'FF721C24' } };
                                    break;
                                default:
                                    // Default white for any other columns
                                    cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFFFFFFF' } };
                                    cell.font = { color: { argb: 'FF000000' } };
                            }
                        });
                    }
                });
                
                // Set column widths for summary sheet
                summarySheet.columns = [
                    { width: 25 }, // Category
                    { width: 15 }, // Matches
                    { width: 15 }, // Source Only
                    { width: 15 }, // Target Only
                    { width: 15 }  // Differences
                ];
                
                // Add auto-filter to summary sheet
                if (summaryData.length > 0) {
                    summarySheet.autoFilter = {
                        from: { row: 1, column: 1 },
                        to: { row: 1, column: 5 }
                    };
                }
                
                sections.forEach(section => {
                    const content = section.querySelector('.section-content');
                    const sectionName = section.querySelector('h2').textContent;
                    // Only process expanded sections
                    if (content && content.classList.contains('expanded')) {
                        hasExpandedSections = true;
                        const table = section.querySelector('table');
                    
                        if (table) {
                            console.log('Processing table for section:', sectionName);
                            
                            // Create a new worksheet
                            const worksheet = workbook.addWorksheet(sectionName.substring(0, 31));
                        
                            // Get table data
                            const rows = table.querySelectorAll('tr');
                            const data = [];
                            
                            console.log('Found', rows.length, 'rows in table');
                            
                            rows.forEach((row, rowIndex) => {
                                const cells = row.querySelectorAll('td, th');
                                const rowData = [];
                                
                                cells.forEach((cell, cellIndex) => {
                                    // Clone cell and strip interactive elements like "View Code" buttons before extracting text
                                    const temp = cell.cloneNode(true);
                                    try {
                                        temp.querySelectorAll('button, .view-code-btn, .toggle, .filters, .floating-btn').forEach(el => el.remove());
                                    } catch (e) { /* no-op */ }
                                    let text = (temp.textContent || cell.textContent || '').replace(/\s+/g, ' ').trim();
                                    // Extra safety: remove any leftover 'View Code' text
                                    text = text.replace(/\bView Code\b/gi, '').trim();
                                    // Ensure we have a valid string, not empty or undefined
                                    rowData.push(text || '');
                                });
                                
                                // Only add rows that have data
                                if (rowData.length > 0) {
                                    data.push(rowData);
                                    console.log('Added row', rowIndex, 'with', rowData.length, 'cells');
                                }
                            });
                            
                            console.log('Total data rows:', data.length);
                        
                            // Add data to worksheet
                            data.forEach((rowData, rowIndex) => {
                                try {
                                    // Ensure rowData is valid and not empty
                                    if (rowData && rowData.length > 0) {
                                        console.log('Adding row', rowIndex, ':', rowData);
                                        const row = worksheet.addRow(rowData);
                                
                                        // Style header row
                                        if (rowIndex === 0) {
                                            row.eachCell((cell, colNumber) => {
                                                cell.font = { bold: true, color: { argb: 'FFFFFFFF' } };
                                                cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF4472C4' } };
                                                cell.alignment = { horizontal: 'center', vertical: 'middle' };
                                                cell.border = {
                                                    top: { style: 'thin', color: { argb: 'FF000000' } },
                                                    left: { style: 'thin', color: { argb: 'FF000000' } },
                                                    bottom: { style: 'thin', color: { argb: 'FF000000' } },
                                                    right: { style: 'thin', color: { argb: 'FF000000' } }
                                                };
                                            });
                                        } else {
                                            // Style data rows
                                            row.eachCell((cell, colNumber) => {
                                                const cellValue = cell.value || '';
                                                const status = cellValue.toString().toLowerCase();
                                                
                                                // Default styling
                                                cell.border = {
                                                    top: { style: 'thin', color: { argb: 'FFD0D0D0' } },
                                                    left: { style: 'thin', color: { argb: 'FFD0D0D0' } },
                                                    bottom: { style: 'thin', color: { argb: 'FFD0D0D0' } },
                                                    right: { style: 'thin', color: { argb: 'FFD0D0D0' } }
                                                };
                                                cell.alignment = { vertical: 'top', wrapText: true };
                                                
                                                // Color code based on status (Status column is typically column 2)
                                                if (colNumber === 2) {
                                                    if (status.includes('match')) {
                                                        cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFD5E8D4' } };
                                                        cell.font = { color: { argb: 'FF2F5233' } };
                                                    } else if (status.includes('mismatch') || status.includes('difference')) {
                                                        cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF8D7DA' } };
                                                        cell.font = { color: { argb: 'FF721C24' } };
                                                    } else if (status.includes('source only')) {
                                                        cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFFFF3CD' } };
                                                        cell.font = { color: { argb: 'FF856404' } };
                                                    } else if (status.includes('target only')) {
                                                        cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFD1ECF1' } };
                                                        cell.font = { color: { argb: 'FF0C5460' } };
                                                    }
                                                } else if (colNumber === 1) {
                                                    // Object Name column - make bold
                                                    cell.font = { bold: true };
                                                }
                                                
                                                // Alternating row colors
                                                if (rowIndex % 2 === 0) {
                                                    if (!cell.fill || cell.fill.type === 'none') {
                                                        cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF8F9FA' } };
                                                    }
                                                }
                                            });
                                        }
                                    }
                                } catch (error) {
                                    console.error('Error processing row', rowIndex, ':', error);
                                    console.error('Row data:', rowData);
                                }
                            });
                        
                            // Set column widths
                            worksheet.columns = [
                                { width: 30 }, // Object Name
                                { width: 15 }, // Status
                                { width: 25 }, // Source Value
                                { width: 25 }  // Target Value
                            ];
                            
                            // Add auto-filter on header row using a valid ExcelJS range
                            const totalColumns = worksheet.columnCount || (data.length > 0 ? data[0].length : 0);
                            if (totalColumns > 0) {
                                worksheet.autoFilter = {
                                    from: { row: 1, column: 1 },
                                    to: { row: 1, column: totalColumns }
                                };
                            }
                        }
                    }
                });
                
                if (!hasExpandedSections) {
                    alert('No expanded sections found. Please expand at least one section before exporting to Excel.');
                    return;
                }
                
                // Save the workbook
                workbook.xlsx.writeBuffer().then(buffer => {
                    const blob = new Blob([buffer], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
                    const url = window.URL.createObjectURL(blob);
                    const a = document.createElement('a');
                    a.href = url;
                    a.download = 'DatabaseSchemaComparison.xlsx';
                    a.click();
                    window.URL.revokeObjectURL(url);
                    console.log('Excel export completed successfully');
                }).catch(error => {
                    console.error('Error creating Excel file:', error);
                    alert('Error creating Excel file. Please try again.');
                });
            });
        }
        // Export to PDF functionality - generate PDF directly with fallback
        function exportToPDF() {
            console.log('Starting PDF export...');
            
            // Check if jsPDF library is loaded
            if (typeof window.jspdf === 'undefined') {
                alert('PDF library not loaded. Please wait a moment and try again.');
                console.error('jsPDF library not available');
                return;
            }
            
            // Expand all sections for PDF export
            document.querySelectorAll('.section-content').forEach(content => {
                content.classList.add('expanded');
                content.style.maxHeight = 'none'; // Allow content to expand fully
                content.style.opacity = '1';
                const toggle = content.previousElementSibling.querySelector('.toggle');
                if (toggle) toggle.textContent = '[-]';
            });

            // Apply PDF-specific styles
            const style = document.createElement('style');
            style.textContent = 'body { print-color-adjust: exact; -webkit-print-color-adjust: exact; }' +
                '.header-controls, .filter-container, .view-code-btn, .toggle, .export-buttons { display: none !important; }' +
                '.section-content { max-height: none !important; opacity: 1 !important; }' +
                '.comparison-table { width: 100%; border-collapse: collapse; }' +
                '.comparison-table th, .comparison-table td { border: 1px solid #ddd; padding: 8px; text-align: left; }' +
                '.status-badge { padding: 2px 6px; border-radius: 4px; font-size: 0.8em; white-space: nowrap; }' +
                '.status-mismatch { background-color: #dc3545; color: white; }' +
                '.status-match { background-color: #28a745; color: white; }' +
                '.status-source-only { background-color: #ffc107; color: #343a40; }' +
                '.status-target-only { background-color: #17a2b8; color: white; }' +
                '.db-badge { background-color: #6c757d; color: white; padding: 2px 6px; border-radius: 4px; font-size: 0.8em; white-space: nowrap; }' +
                '.db-source { background-color: #007bff; }' +
                '.db-target { background-color: #6f42c1; }' +
                '.code-diff-add { background-color: #e6ffed; }' +
                '.code-diff-remove { background-color: #ffeef0; }' +
                '.code-diff-change { background-color: #fff3cd; }' +
                'pre { white-space: pre-wrap; word-wrap: break-word; }';
            document.head.appendChild(style);

            // Wait a moment for styles to apply, then generate PDF
            setTimeout(() => {
                // Get the main content area
                const element = document.querySelector('.container') || document.body;
                
                // Use html2canvas to capture the content
                if (typeof html2canvas !== 'undefined') {
                    html2canvas(element, {
                        scale: 1.5, // Reduced scale to prevent memory issues
                        useCORS: true,
                        allowTaint: true,
                        backgroundColor: '#ffffff',
                        logging: false,
                        height: element.scrollHeight,
                        width: element.scrollWidth
                    }).then(canvas => {
                        try {
                            const imgData = canvas.toDataURL('image/jpeg', 0.8); // Use JPEG with compression
                            const pdf = new window.jspdf.jsPDF('p', 'mm', 'a4');
                            
                            // Calculate dimensions
                            const imgWidth = 210; // A4 width in mm
                            const pageHeight = 295; // A4 height in mm
                            const imgHeight = (canvas.height * imgWidth) / canvas.width;
                            
                            // If content is too large, split into multiple pages
                            if (imgHeight > pageHeight) {
                                const totalPages = Math.ceil(imgHeight / pageHeight);
                                
                                for (let i = 0; i < totalPages; i++) {
                                    if (i > 0) pdf.addPage();
                                    
                                    const yOffset = -i * pageHeight;
                                    pdf.addImage(imgData, 'JPEG', 0, yOffset, imgWidth, imgHeight);
                                }
                            } else {
                                pdf.addImage(imgData, 'JPEG', 0, 0, imgWidth, imgHeight);
                            }
                            
                            // Save the PDF
                            pdf.save('DatabaseSchemaComparison.pdf');
                            console.log('PDF export completed successfully');
                            
                        } catch (error) {
                            console.error('Error creating PDF:', error);
                            // Fallback to print dialog if PDF generation fails
                            console.log('Falling back to print dialog...');
                            window.print();
                        }
                        
                        // Clean up
                        document.head.removeChild(style);
                    }).catch(error => {
                        console.error('Error capturing content:', error);
                        alert('Error generating PDF. Falling back to print dialog.');
                        window.print();
                        document.head.removeChild(style);
                    });
                } else {
                    console.error('html2canvas library not available');
                    alert('PDF generation library not loaded. Falling back to print dialog.');
                    window.print();
                    document.head.removeChild(style);
                }
            }, 500); // Give time for styles to apply
        }
        
        // Auto-export functionality - triggered by URL parameter or global flag
        function initAutoExport() {
            const urlParams = new URLSearchParams(window.location.search);
            const autoExport = urlParams.get('autoExport') === 'true' || window.AUTO_EXPORT_MODE === true;
            
            console.log('Auto-export check:', {
                urlParams: window.location.search,
                autoExport: autoExport
            });
            
            if (autoExport) {
                console.log('%c AUTO-EXPORT MODE ACTIVATED ', 'background: #4CAF50; color: white; font-size: 16px; padding: 5px;');
                
                // Show visual indicator
                const indicator = document.createElement('div');
                indicator.style.cssText = 'position: fixed; top: 10px; right: 10px; background: #4CAF50; color: white; padding: 15px 25px; border-radius: 5px; z-index: 10000; font-weight: bold; box-shadow: 0 4px 6px rgba(0,0,0,0.3);';
                indicator.innerHTML = 'Auto-exporting to Excel...<br><small>Please wait</small>';
                document.body.appendChild(indicator);
                
                // Wait for all libraries to load with timeout handling
                indicator.innerHTML = 'Loading Excel library...<br><small>Checking internet connection</small>';
                
                waitForExcelJS(() => {
                    try {
                        console.log('%c ExcelJS library loaded successfully ', 'background: #2196F3; color: white; padding: 3px;');
                        indicator.innerHTML = 'Expanding all sections...<br><small>Step 1 of 2</small>';
                        
                        // Expand all sections
                        const sections = document.querySelectorAll('.section');
                        console.log('Found ' + sections.length + ' sections to expand');
                        sections.forEach((section, index) => {
                            const content = section.querySelector('.section-content');
                            if (content && !content.classList.contains('expanded')) {
                                content.classList.add('expanded');
                                console.log('Expanded section ' + (index + 1));
                            }
                        });
                        
                        console.log('%c All sections expanded ', 'background: #FF9800; color: white; padding: 3px;');
                        indicator.innerHTML = 'Generating Excel file...<br><small>Step 2 of 2</small>';
                        
                        // Wait a moment for sections to render, then export
                        setTimeout(() => {
                            try {
                                console.log('%c Starting Excel export... ', 'background: #9C27B0; color: white; padding: 3px;');
                                exportToExcel();
                                
                                // Update indicator
                                indicator.innerHTML = 'Excel download started!<br><small>Check your downloads</small>';
                                indicator.style.background = '#4CAF50';
                                
                                // Give time for download to complete, then notify completion
                                setTimeout(() => {
                                    console.log('%c AUTO-EXPORT COMPLETED ', 'background: #4CAF50; color: white; font-size: 16px; padding: 5px;');
                                    document.title = 'EXPORT_COMPLETE';
                                    indicator.innerHTML = 'Export complete!<br><small>You can close this tab</small>';
                                    
                                    // Auto-remove indicator after 5 seconds
                                    setTimeout(() => {
                                        indicator.remove();
                                    }, 5000);
                                }, 3000);
                            } catch (error) {
                                console.error('Error during Excel export:', error);
                                indicator.innerHTML = 'Export failed!<br><small>' + error.message + '</small>';
                                indicator.style.background = '#f44336';
                            }
                        }, 1000);
                    } catch (error) {
                        console.error('Error during auto-export:', error);
                        indicator.innerHTML = 'Auto-export failed!<br><small>' + error.message + '</small>';
                        indicator.style.background = '#f44336';
                    }
                }, 30000); // 30 second timeout
            }
        }
        
        // Run auto-export check when page loads
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', initAutoExport);
        } else {
            initAutoExport();
        }
    </script>
</body>
</html>
"@
    
    return $html
}
# Function to create section HTML
function New-SectionHTML {
    param(
        [string]$SectionName,
        [hashtable]$Data,
        [string]$KeyColumns,
        [string]$SourceDatabaseName,
        [string]$TargetDatabaseName
    )
    
    $sectionId = $SectionName.ToLower().replace(' ', '-')
    # Category weight for section ordering: 1=objects, 2=performance, 3=configuration, 4=other
    $categoryMap = @{
        'Schemas' = 1; 'Tables' = 1; 'Columns' = 1; 'Indexes' = 1; 'Functions' = 1; 'Stored Procedures' = 1; 'Views' = 1; 'Synonyms' = 1; 'Constraints' = 1; 'Keys' = 1; 'Table Triggers' = 1; 'Database Triggers' = 1;
        'Query Store' = 2; 'VLF Information' = 2;
        'Database Options' = 3; 'File Information' = 3; 'Users' = 3; 'Roles' = 3; 'External Resources' = 3; 'Data Types' = 3
    }
    $categoryWeight = 4
    if ($categoryMap.ContainsKey($SectionName)) { $categoryWeight = $categoryMap[$SectionName] }
    
    $html = @"
    <div class="section" data-title="$SectionName" data-category-weight="$categoryWeight">
        <div class="section-header" id="$sectionId-header">
            <h2>$SectionName</h2>
            <span class="toggle" onclick="toggleSection('$sectionId'); event.stopPropagation();">[+]</span>
        </div>
        <div class="section-content" id="$sectionId-content">
            <div class="filter-container">
                <div class="filter-controls">
                    <input type="text" class="filter-input" id="filter-$sectionId" placeholder="Filter $SectionName..." />
                    <select class="sort-select" id="sort-$sectionId" onchange="sortTable('$sectionId')">
                        <option value="">Sort by...</option>
                        <option value="name-asc">Name A-Z</option>
                        <option value="name-desc">Name Z-A</option>
                        <option value="status-asc">Status A-Z</option>
                        <option value="status-desc">Status Z-A</option>
                    </select>
                    </div>
                <div class="status-filters">
                    <label class="status-checkbox">
                        <input type="checkbox" id="show-mismatch-$sectionId" checked onchange="applyFilters('$sectionId')">
                        <span class="status-badge status-mismatch">Mismatch</span>
                    </label>
                    <label class="status-checkbox">
                        <input type="checkbox" id="show-match-$sectionId" checked onchange="applyFilters('$sectionId')">
                        <span class="status-badge status-match">Match</span>
                    </label>
                    <label class="status-checkbox">
                        <input type="checkbox" id="show-source-only-$sectionId" checked onchange="applyFilters('$sectionId')">
                        <span class="status-badge status-source-only">Source Only</span>
                    </label>
                    <label class="status-checkbox">
                        <input type="checkbox" id="show-target-only-$sectionId" checked onchange="applyFilters('$sectionId')">
                        <span class="status-badge status-target-only">Target Only</span>
                    </label>
                    </div>
                <div class="filter-stats">
                    <span class="filter-count" id="count-$sectionId">0 items</span>
                    <button class="clear-filter" onclick="clearFilter('$sectionId')">Clear All</button>
                    </div>
                </div>
"@
    
    $totalItems = 0
    if ($Data) {
        $totalItems = $Data.Matches.Count + $Data.SourceOnly.Count + $Data.TargetOnly.Count + $Data.Differences.Count
    }
    
    if ($totalItems -gt 0) {
        $html += @"
            <table class="comparison-table">
                <thead>
                    <tr>
                        <th>#</th>
                        <th>Object Name</th>
                        <th>Status</th>
                        <th>Details</th>
                    </tr>
                </thead>
                <tbody>
"@
        
        # Create separate variables for different row types to prevent truncation
        $matchRows = ""
        $sourceOnlyRows = ""
        $targetOnlyRows = ""
        $mismatchRows = ""
        
        # Row counter for numbering
        $rowNumber = 1
        
        # Process differences FIRST (they appear first in output)
        if ($Data.Differences) {
            foreach ($item in $Data.Differences) {
                $objectName = ""
                $details = ""
                
                # Extract object name based on section type (same logic as above)
                if ($SectionName -eq "Tables") {
                    $objectName = "$($item.Source.TABLE_SCHEMA).$($item.Source.TABLE_NAME)"
                    $sourceCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Source.CREATE_STATEMENT -replace "`r", ""))
                    $targetCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Target.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.Source.TABLE_SCHEMA)' data-table='$($item.Source.TABLE_NAME)' data-source-create='$sourceCreateStatement' data-target-create='$targetCreateStatement' data-source-create-date='$($item.Source.create_date)' data-target-create-date='$($item.Target.create_date)' data-source-modify-date='$($item.Source.modify_date)' data-target-modify-date='$($item.Target.modify_date)' data-source-row-count='$($item.Source.ROW_COUNT)' data-target-row-count='$($item.Target.ROW_COUNT)' onclick='showTableCode(this)'>View Code</button>"
                    $details = "Schema differences detected $viewCodeBtn"
                } elseif ($SectionName -eq "Columns") {
                    $objectName = "$($item.Source.TABLE_SCHEMA).$($item.Source.TABLE_NAME).$($item.Source.COLUMN_NAME)"
                    $diffDetails = @()
                    if ($item.Differences) {
                        foreach ($diffKey in $item.Differences.Keys) {
                            $sourceVal = $item.Differences[$diffKey].Source
                            $targetVal = $item.Differences[$diffKey].Target
                            $diffDetails += "$diffKey`: $sourceVal <span class='db-badge db-source'>$SourceDatabaseName</span> -> $targetVal <span class='db-badge db-target'>$TargetDatabaseName</span>"
                        }
                    }
                    $sourceCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Source.CREATE_STATEMENT -replace "`r", ""))
                    $targetCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Target.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.Source.TABLE_SCHEMA)' data-table='$($item.Source.TABLE_NAME)' data-column='$($item.Source.COLUMN_NAME)' data-source-create='$sourceCreateStatement' data-target-create='$targetCreateStatement' data-source-datatype='$($item.Source.DATA_TYPE)' data-target-datatype='$($item.Target.DATA_TYPE)' data-source-nullable='$($item.Source.IS_NULLABLE)' data-target-nullable='$($item.Target.IS_NULLABLE)' onclick='showColumnCode(this)'>View Code</button>"
                    if ($diffDetails.Count -gt 0) {
                        $details = ($diffDetails -join "; ") + " $viewCodeBtn"
                    } else {
                        $details = "Column definition differences detected $viewCodeBtn"
                    }
                } elseif ($SectionName -eq "Indexes") {
                    $objectName = "$($item.Source.SCHEMA_NAME).$($item.Source.TABLE_NAME).$($item.Source.INDEX_NAME)"
                    $diffDetails = @()
                    if ($item.Differences) {
                        foreach ($diffKey in $item.Differences.Keys) {
                            $sourceVal = $item.Differences[$diffKey].Source
                            $targetVal = $item.Differences[$diffKey].Target
                            $diffDetails += "$diffKey`: $sourceVal <span class='db-badge db-source'>$SourceDatabaseName</span> -> $targetVal <span class='db-badge db-target'>$TargetDatabaseName</span>"
                        }
                    }
                    $sourceCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Source.CREATE_STATEMENT -replace "`r", ""))
                    $targetCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Target.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.Source.SCHEMA_NAME)' data-table='$($item.Source.TABLE_NAME)' data-index='$($item.Source.INDEX_NAME)' data-source-create='$sourceCreateStatement' data-target-create='$targetCreateStatement' data-source-index-type='$($item.Source.INDEX_TYPE)' data-target-index-type='$($item.Target.INDEX_TYPE)' data-source-is-unique='$($item.Source.is_unique)' data-target-is-unique='$($item.Target.is_unique)' onclick='showIndexCode(this)'>View Code</button>"
                    if ($diffDetails.Count -gt 0) {
                        $details = ($diffDetails -join "; ") + " $viewCodeBtn"
                    } else {
                        $details = "Index definition differences detected $viewCodeBtn"
                    }
                } elseif ($SectionName -eq "Functions") {
                    $objectName = "$($item.Source.SCHEMA_NAME).$($item.Source.FUNCTION_NAME)"
                    $sourceDef = [System.Web.HttpUtility]::HtmlEncode($item.Source.definition)
                    $sourceDef = ($sourceDef -replace '"', '&quot;' -replace "'", '&#39;')
                    $targetDef = [System.Web.HttpUtility]::HtmlEncode($item.Target.definition)
                    $targetDef = ($targetDef -replace '"', '&quot;' -replace "'", '&#39;')
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.Source.SCHEMA_NAME)' data-function='$($item.Source.FUNCTION_NAME)' data-source-code='$sourceDef' data-target-code='$targetDef' onclick='showFunctionCodeFromData(this)'>View Code</button>"
                    $details = "Function definition differences detected $viewCodeBtn"
                } elseif ($SectionName -eq "Stored Procedures") {
                    $objectName = "$($item.Source.SCHEMA_NAME).$($item.Source.PROCEDURE_NAME)"
                    $sourceDef = [System.Web.HttpUtility]::HtmlEncode($item.Source.definition)
                    $sourceDef = ($sourceDef -replace '"', '&quot;' -replace "'", '&#39;')
                    $targetDef = [System.Web.HttpUtility]::HtmlEncode($item.Target.definition)
                    $targetDef = ($targetDef -replace '"', '&quot;' -replace "'", '&#39;')
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.Source.SCHEMA_NAME)' data-function='$($item.Source.PROCEDURE_NAME)' data-object-type='Stored Procedure' data-source-code='$sourceDef' data-target-code='$targetDef' onclick='showFunctionCodeFromData(this)'>View Code</button>"
                    $details = "Procedure definition differences detected $viewCodeBtn"
                } elseif ($SectionName -eq "Data Types") {
                    $objectName = "$($item.Source.SCHEMA_NAME).$($item.Source.TYPE_NAME)"
                    $sourceDef = "System Type ID: $($item.Source.system_type_id)|User Type ID: $($item.Source.user_type_id)|Max Length: $($item.Source.max_length)|Precision: $($item.Source.precision)|Scale: $($item.Source.scale)|Collation: $($item.Source.collation_name)|Is Nullable: $($item.Source.is_nullable)|Is User Defined: $($item.Source.is_user_defined)|Is Assembly Type: $($item.Source.is_assembly_type)"
                    $targetDef = "System Type ID: $($item.Target.system_type_id)|User Type ID: $($item.Target.user_type_id)|Max Length: $($item.Target.max_length)|Precision: $($item.Target.precision)|Scale: $($item.Target.scale)|Collation: $($item.Target.collation_name)|Is Nullable: $($item.Target.is_nullable)|Is User Defined: $($item.Target.is_user_defined)|Is Assembly Type: $($item.Target.is_assembly_type)"
                    $sourceDef = ($sourceDef -replace '"', '\&quot;' -replace "'", "\'")
                    $targetDef = ($targetDef -replace '"', '\&quot;' -replace "'", "\'")
                    $viewDetailsBtn = "<button class='view-code-btn' data-schema='$($item.Source.SCHEMA_NAME)' data-type='$($item.Source.TYPE_NAME)' data-source-def='$sourceDef' data-target-def='$targetDef' onclick='showDataTypeDetails(this)'>View Details</button>"
                    $details = "Data type definition differences detected $viewDetailsBtn"
                } elseif ($SectionName -eq "Constraints") {
                    $objectName = "$($item.Source.SCHEMA_NAME).$($item.Source.TABLE_NAME).$($item.Source.CONSTRAINT_NAME)"
                    $diffDetails = @()
                    if ($item.Differences) {
                        foreach ($diffKey in $item.Differences.Keys) {
                            $sourceVal = $item.Differences[$diffKey].Source
                            $targetVal = $item.Differences[$diffKey].Target
                            $diffDetails += "$diffKey`: $sourceVal <span class='db-badge db-source'>$SourceDatabaseName</span> -> $targetVal <span class='db-badge db-target'>$TargetDatabaseName</span>"
                        }
                    }
                    $sourceCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Source.CREATE_STATEMENT -replace "`r", ""))
                    $targetCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Target.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.Source.SCHEMA_NAME)' data-table='$($item.Source.TABLE_NAME)' data-constraint='$($item.Source.CONSTRAINT_NAME)' data-source-create='$sourceCreateStatement' data-target-create='$targetCreateStatement' data-source-type='$($item.Source.CONSTRAINT_TYPE)' data-target-type='$($item.Target.CONSTRAINT_TYPE)' data-source-disabled='$($item.Source.is_disabled)' data-target-disabled='$($item.Target.is_disabled)' onclick='showConstraintCode(this)'>View Code</button>"
                    if ($diffDetails.Count -gt 0) {
                        $details = ($diffDetails -join "; ") + " $viewCodeBtn"
                    } else {
                        $details = "Constraint definition differences detected $viewCodeBtn"
                    }
                } elseif ($SectionName -eq "Views") {
                    $objectName = "$($item.Source.SCHEMA_NAME).$($item.Source.VIEW_NAME)"
                    $sourceCode = [System.Web.HttpUtility]::HtmlEncode($item.Source.definition)
                    $targetCode = [System.Web.HttpUtility]::HtmlEncode($item.Target.definition)
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.Source.SCHEMA_NAME)' data-view='$($item.Source.VIEW_NAME)' data-source-code='$sourceCode' data-target-code='$targetCode' data-source-create-date='$($item.Source.create_date)' data-target-create-date='$($item.Target.create_date)' data-source-modify-date='$($item.Source.modify_date)' data-target-modify-date='$($item.Target.modify_date)' onclick='showViewCode(this)'>View Code</button>"
                    $details = "View definition differences detected $viewCodeBtn"
                } elseif ($SectionName -eq "Synonyms") {
                    $objectName = "$($item.Source.SCHEMA_NAME).$($item.Source.SYNONYM_NAME)"
                    $sourceCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Source.CREATE_STATEMENT -replace "`r", ""))
                    $targetCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Target.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.Source.SCHEMA_NAME)' data-synonym='$($item.Source.SYNONYM_NAME)' data-source-create='$sourceCreateStatement' data-target-create='$targetCreateStatement' data-source-base-object='$($item.Source.base_object_name)' data-target-base-object='$($item.Target.base_object_name)' onclick='showSynonymCode(this)'>View Code</button>"
                    $details = "Synonym definition differences detected $viewCodeBtn"
                } elseif ($SectionName -eq "Table Triggers") {
                    $objectName = "$($item.Source.SCHEMA_NAME).$($item.Source.TABLE_NAME).$($item.Source.TRIGGER_NAME)"
                    $sourceCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Source.CREATE_STATEMENT -replace "`r", ""))
                    $targetCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Target.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.Source.SCHEMA_NAME)' data-table='$($item.Source.TABLE_NAME)' data-trigger='$($item.Source.TRIGGER_NAME)' data-source-create='$sourceCreateStatement' data-target-create='$targetCreateStatement' data-source-disabled='$($item.Source.is_disabled)' data-target-disabled='$($item.Target.is_disabled)' data-source-instead-of='$($item.Source.is_instead_of_trigger)' data-target-instead-of='$($item.Target.is_instead_of_trigger)' onclick='showTableTriggerCode(this)'>View Code</button>"
                    $details = "Table trigger definition differences detected $viewCodeBtn"
                } elseif ($SectionName -eq "Database Triggers") {
                    $objectName = "$($item.Source.TRIGGER_NAME)"
                    $sourceCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Source.CREATE_STATEMENT -replace "`r", ""))
                    $targetCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Target.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-trigger='$($item.Source.TRIGGER_NAME)' data-source-create='$sourceCreateStatement' data-target-create='$targetCreateStatement' data-source-disabled='$($item.Source.is_disabled)' data-target-disabled='$($item.Target.is_disabled)' onclick='showDatabaseTriggerCode(this)'>View Code</button>"
                    $details = "Database trigger definition differences detected $viewCodeBtn"
                } elseif ($SectionName -eq "Keys") {
                    $objectName = "$($item.Source.SCHEMA_NAME).$($item.Source.TABLE_NAME).$($item.Source.KEY_NAME)"
                    $diffDetails = @()
                    if ($item.Differences) {
                        foreach ($diffKey in $item.Differences.Keys) {
                            $sourceVal = $item.Differences[$diffKey].Source
                            $targetVal = $item.Differences[$diffKey].Target
                            $diffDetails += "$diffKey`: $sourceVal <span class='db-badge db-source'>$SourceDatabaseName</span> -> $targetVal <span class='db-badge db-target'>$TargetDatabaseName</span>"
                        }
                    }
                    $sourceCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Source.CREATE_STATEMENT -replace "`r", ""))
                    $targetCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Target.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.Source.SCHEMA_NAME)' data-table='$($item.Source.TABLE_NAME)' data-key='$($item.Source.KEY_NAME)' data-source-code='$sourceCreateStatement' data-target-code='$targetCreateStatement' data-source-key-type='$($item.Source.KEY_TYPE)' data-target-key-type='$($item.Target.KEY_TYPE)' data-source-is-primary='$($item.Source.is_primary_key)' data-target-is-primary='$($item.Target.is_primary_key)' data-source-is-unique='$($item.Source.is_unique)' data-target-is-unique='$($item.Target.is_unique)' onclick='showKeyCode(this)'>View Code</button>"
                    if ($diffDetails.Count -gt 0) {
                        $details = ($diffDetails -join "; ") + " $viewCodeBtn"
                    } else {
                        $details = "Key definition differences detected $viewCodeBtn"
                    }
                } elseif ($SectionName -eq "Database Options") {
                    # Handle custom structure for database options
                    if ($item.Source -and $item.Target) {
                        # Matches or Differences - use source data for display
                        $sourceItem = $item.Source
                        $targetItem = $item.Target
                        $objectName = $sourceItem.OPTION_NAME
                        $sourceSqlCommand = [System.Web.HttpUtility]::HtmlEncode($sourceItem.SQL_COMMAND)
                        $targetSqlCommand = [System.Web.HttpUtility]::HtmlEncode($targetItem.SQL_COMMAND)
                        $viewCodeBtn = "<button class='view-code-btn' data-database='$($sourceItem.DATABASE_NAME)' data-option='$($sourceItem.OPTION_NAME)' data-source-code='$sourceSqlCommand' data-target-code='$targetSqlCommand' data-source-value='$($sourceItem.OPTION_VALUE)' data-target-value='$($targetItem.OPTION_VALUE)' onclick='showDatabaseOptionCode(this)'>View Code</button>"
                        $details = "Value: $($sourceItem.OPTION_VALUE) vs $($targetItem.OPTION_VALUE) $viewCodeBtn"
                    } else {
                        # SourceOnly or TargetOnly - use item directly
                        $objectName = $item.OPTION_NAME
                        $sqlCommand = [System.Web.HttpUtility]::HtmlEncode($item.SQL_COMMAND)
                        $viewCodeBtn = "<button class='view-code-btn' data-database='$($item.DATABASE_NAME)' data-option='$($item.OPTION_NAME)' data-source-code='$sqlCommand' data-target-code='$sqlCommand' data-source-value='$($item.OPTION_VALUE)' data-target-value='$($item.OPTION_VALUE)' onclick='showDatabaseOptionCode(this)'>View Code</button>"
                        $details = "Value: $($item.OPTION_VALUE) $viewCodeBtn"
                    }
                } elseif ($SectionName -eq "File Information") {
                    $objectName = $item.Source.name
                    $sourceCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Source.CREATE_STATEMENT -replace "`r", ""))
                    $targetCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Target.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-file='$($item.Source.name)' data-source-create='$sourceCreateStatement' data-target-create='$targetCreateStatement' data-source-type='$($item.Source.type_desc)' data-target-type='$($item.Target.type_desc)' data-source-size='$($item.Source.size_mb)' data-target-size='$($item.Target.size_mb)' data-source-filegroup='$($item.Source.filegroup_name)' data-target-filegroup='$($item.Target.filegroup_name)' onclick='showFileCode(this)'>View Code</button>"
                    $details = "Type: $($item.Source.type_desc), Size: $($item.Source.size_mb) MB, Filegroup: $($item.Source.filegroup_name), Growth: $($item.Source.growth_display), Max Size: $($item.Source.max_size_display) $viewCodeBtn"
                } elseif ($SectionName -eq "VLF Information") {
                    $objectName = "VLF_$($item.Source.file_id)_$($item.Source.vlf_sequence_number)"
                    $details = "VLF configuration differences detected"
                } elseif ($SectionName -eq "Query Store") {
                    $objectName = $item.Source["OBJECT_NAME"]
                    $itemType = $item.Source["ITEM_TYPE"]
                    
                    if ($itemType -eq "QS_CONFIG") {
                        $diffDetails = @()
                        if ($item.Differences) {
                            foreach ($diffKey in $item.Differences.Keys) {
                                $sourceVal = $item.Differences[$diffKey].Source
                                $targetVal = $item.Differences[$diffKey].Target
                                
                                # Format specific configuration differences nicely
                                $friendlyName = switch ($diffKey) {
                                    "ACTUAL_STATE" { "Actual State" }
                                    "DESIRED_STATE" { "Desired State" }
                                    "CURRENT_STORAGE_SIZE_MB" { "Current Storage (MB)" }
                                    "MAX_STORAGE_SIZE_MB" { "Max Storage (MB)" }
                                    "QUERY_CAPTURE_MODE" { "Query Capture Mode" }
                                    "SIZE_CLEANUP_MODE" { "Size Cleanup Mode" }
                                    "STALE_QUERY_THRESHOLD_DAYS" { "Stale Query Threshold (Days)" }
                                    "MAX_PLANS_PER_QUERY" { "Max Plans per Query" }
                                    "WAIT_STATS_CAPTURE_MODE" { "Wait Stats Capture Mode" }
                                    default { $diffKey }
                                }
                                
                                $diffDetails += "<strong>$friendlyName</strong>: $sourceVal <span class='db-badge db-source'>$SourceDatabaseName</span> -> $targetVal <span class='db-badge db-target'>$TargetDatabaseName</span>"
                            }
                        }
                        $details = ($diffDetails -join "<br>")
                    } elseif ($itemType -eq "QS_FORCED_PLAN") {
                        $queryText = [System.Web.HttpUtility]::HtmlEncode($item.Source["QUERY_TEXT"])
                        $queryId = $item.Source["QUERY_ID"]
                        $planId = $item.Source["PLAN_ID"]
                        
                        $viewCodeBtn = "<button class='view-code-btn' data-schema='' data-function='QueryStore' data-source-code='$queryText' data-target-code='$queryText' onclick='showFunctionCodeFromData(this)'>View Query</button>"
                        $details = "Forced plan differences - QueryID: $queryId, PlanID: $planId $viewCodeBtn"
                    } else {
                        $details = "Query Store item differences detected"
                    }
                } elseif ($SectionName -eq "Schemas") {
                    $objectName = $item.Source.SCHEMA_NAME
                    $diffDetails = @()
                    if ($item.Differences) {
                        foreach ($diffKey in $item.Differences.Keys) {
                            $sourceVal = $item.Differences[$diffKey].Source
                            $targetVal = $item.Differences[$diffKey].Target
                            $diffDetails += "$diffKey`: $sourceVal <span class='db-badge db-source'>$SourceDatabaseName</span> -> $targetVal <span class='db-badge db-target'>$TargetDatabaseName</span>"
                        }
                    }
                    $details = ($diffDetails -join "<br>")
                } elseif ($SectionName -eq "Users") {
                    $objectName = $item.Source.USER_NAME
                    $diffDetails = @()
                    if ($item.Differences) {
                        foreach ($diffKey in $item.Differences.Keys) {
                            $sourceVal = $item.Differences[$diffKey].Source
                            $targetVal = $item.Differences[$diffKey].Target
                            $diffDetails += "$diffKey`: $sourceVal <span class='db-badge db-source'>$SourceDatabaseName</span> -> $targetVal <span class='db-badge db-target'>$TargetDatabaseName</span>"
                        }
                    }
                    $sourceCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Source.CREATE_STATEMENT -replace "`r", ""))
                    $targetCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Target.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-user='$($item.Source.USER_NAME)' data-source-create='$sourceCreateStatement' data-target-create='$targetCreateStatement' data-source-type='$($item.Source.USER_TYPE)' data-target-type='$($item.Target.USER_TYPE)' data-source-roles='$($item.Source.ROLE_MEMBERSHIPS)' data-target-roles='$($item.Target.ROLE_MEMBERSHIPS)' onclick='showUserCode(this)'>View Code</button>"
                    $details = ($diffDetails -join "<br>") + " $viewCodeBtn"
                } elseif ($SectionName -eq "Roles") {
                    $objectName = $item.Source.ROLE_NAME
                    $diffDetails = @()
                    if ($item.Differences) {
                        foreach ($diffKey in $item.Differences.Keys) {
                            $sourceVal = $item.Differences[$diffKey].Source
                            $targetVal = $item.Differences[$diffKey].Target
                            $diffDetails += "$diffKey`: $sourceVal <span class='db-badge db-source'>$SourceDatabaseName</span> -> $targetVal <span class='db-badge db-target'>$TargetDatabaseName</span>"
                        }
                    }
                    $sourceCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Source.CREATE_STATEMENT -replace "`r", ""))
                    $targetCreateStatement = [System.Web.HttpUtility]::HtmlEncode(($item.Target.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-role='$($item.Source.ROLE_NAME)' data-source-create='$sourceCreateStatement' data-target-create='$targetCreateStatement' data-source-type='$($item.Source.ROLE_TYPE)' data-target-type='$($item.Target.ROLE_TYPE)' data-source-members='$($item.Source.ROLE_MEMBERS)' data-target-members='$($item.Target.ROLE_MEMBERS)' onclick='showRoleCode(this)'>View Code</button>"
                    $details = ($diffDetails -join "<br>") + " $viewCodeBtn"
                }
                
                if ($SectionName -eq "Query Store") {
                    if ([string]::IsNullOrWhiteSpace($objectName)) {
                        $objectName = "QueryId=$($item.Source["QUERY_ID"]), PlanId=$($item.Source["PLAN_ID"])"
                    }
                    $objectName = [System.Web.HttpUtility]::HtmlEncode($objectName)
                }
                $mismatchRows += @"

                    <tr class="mismatch">
                        <td>$rowNumber</td>
                        <td>$objectName</td>
                        <td><span class="status-badge status-mismatch">Mismatch</span></td>
                        <td>$details</td>
                    </tr>
"@
                $rowNumber++
            }
        }
        # Process matches
        if ($Data.Matches) {
            foreach ($item in $Data.Matches) {
                $objectName = ""
                $details = ""
                
                # Extract object name based on section type
                if ($SectionName -eq "Tables") {
                    $objectName = "$($item.TABLE_SCHEMA).$($item.TABLE_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.TABLE_SCHEMA)' data-table='$($item.TABLE_NAME)' data-source-create='$createStatement' data-target-create='$createStatement' data-source-create-date='$($item.create_date)' data-target-create-date='$($item.create_date)' data-source-modify-date='$($item.modify_date)' data-target-modify-date='$($item.modify_date)' data-source-row-count='$($item.ROW_COUNT)' data-target-row-count='$($item.ROW_COUNT)' onclick='showTableCode(this)'>View Code</button>"
                    $details = "Type: $($item.TABLE_TYPE), Rows: $($item.ROW_COUNT) $viewCodeBtn"
                } elseif ($SectionName -eq "Schemas") {
                    $objectName = $item.SCHEMA_NAME
                    $principalName = if ($item.PRINCIPAL_NAME) { $item.PRINCIPAL_NAME } else { '' }
                    if ($principalName -ne '') {
                        $details = "Principal Id: $($item.PRINCIPAL_ID), Principal: $principalName"
                    } else {
                        $details = "Principal Id: $($item.PRINCIPAL_ID)"
                    }
                } elseif ($SectionName -eq "Columns") {
                    $objectName = "$($item.TABLE_SCHEMA).$($item.TABLE_NAME).$($item.COLUMN_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.TABLE_SCHEMA)' data-table='$($item.TABLE_NAME)' data-column='$($item.COLUMN_NAME)' data-source-create='$createStatement' data-target-create='$createStatement' data-source-datatype='$($item.DATA_TYPE)' data-target-datatype='$($item.DATA_TYPE)' data-source-nullable='$($item.IS_NULLABLE)' data-target-nullable='$($item.IS_NULLABLE)' onclick='showColumnCode(this)'>View Code</button>"
                    $details = "Type: $($item.DATA_TYPE), Nullable: $($item.IS_NULLABLE) $viewCodeBtn"
                } elseif ($SectionName -eq "Indexes") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TABLE_NAME).$($item.INDEX_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-table='$($item.TABLE_NAME)' data-index='$($item.INDEX_NAME)' data-source-create='$createStatement' data-target-create='$createStatement' data-source-index-type='$($item.INDEX_TYPE)' data-target-index-type='$($item.INDEX_TYPE)' data-source-is-unique='$($item.is_unique)' data-target-is-unique='$($item.is_unique)' onclick='showIndexCode(this)'>View Code</button>"
                    $details = "Type: $($item.INDEX_TYPE), Unique: $($item.is_unique), Columns: [$($item.INDEX_COLUMNS)] $viewCodeBtn"
                } elseif ($SectionName -eq "Functions") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.FUNCTION_NAME)"
                    $funcDef = [System.Web.HttpUtility]::HtmlEncode($item.definition)
                    $funcDef = ($funcDef -replace '"', '&quot;' -replace "'", '&#39;')
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-function='$($item.FUNCTION_NAME)' data-source-code='$funcDef' data-target-code='$funcDef' onclick='showFunctionCodeFromData(this)'>View Code</button>"
                    $details = "Type: $($item.FUNCTION_TYPE) $viewCodeBtn"
                } elseif ($SectionName -eq "Stored Procedures") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.PROCEDURE_NAME)"
                    $procDef = [System.Web.HttpUtility]::HtmlEncode($item.definition)
                    $procDef = ($procDef -replace '"', '&quot;' -replace "'", '&#39;')
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-function='$($item.PROCEDURE_NAME)' data-object-type='Stored Procedure' data-source-code='$procDef' data-target-code='$procDef' onclick='showFunctionCodeFromData(this)'>View Code</button>"
                    $details = "Created: $($item.create_date) $viewCodeBtn"
                } elseif ($SectionName -eq "Data Types") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TYPE_NAME)"
                    $typeDef = "System Type ID: $($item.system_type_id)|User Type ID: $($item.user_type_id)|Max Length: $($item.max_length)|Precision: $($item.precision)|Scale: $($item.scale)|Collation: $($item.collation_name)|Is Nullable: $($item.is_nullable)|Is User Defined: $($item.is_user_defined)|Is Assembly Type: $($item.is_assembly_type)"
                    $typeDef = ($typeDef -replace '"', '\&quot;' -replace "'", "\'")
                    $viewDetailsBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-type='$($item.TYPE_NAME)' data-source-def='$typeDef' data-target-def='$typeDef' onclick='showDataTypeDetails(this)'>View Details</button>"
                    $details = "Precision: $($item.precision), Scale: $($item.scale) $viewDetailsBtn"
                } elseif ($SectionName -eq "Constraints") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TABLE_NAME).$($item.CONSTRAINT_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-table='$($item.TABLE_NAME)' data-constraint='$($item.CONSTRAINT_NAME)' data-source-create='$createStatement' data-target-create='$createStatement' data-source-type='$($item.CONSTRAINT_TYPE)' data-target-type='$($item.CONSTRAINT_TYPE)' data-source-disabled='$($item.is_disabled)' data-target-disabled='$($item.is_disabled)' onclick='showConstraintCode(this)'>View Code</button>"
                    $details = "Type: $($item.CONSTRAINT_TYPE) $viewCodeBtn"
                } elseif ($SectionName -eq "Views") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.VIEW_NAME)"
                    $viewCode = [System.Web.HttpUtility]::HtmlEncode($item.definition)
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-view='$($item.VIEW_NAME)' data-source-code='$viewCode' data-target-code='$viewCode' data-source-create-date='$($item.create_date)' data-target-create-date='$($item.create_date)' data-source-modify-date='$($item.modify_date)' data-target-modify-date='$($item.modify_date)' onclick='showViewCode(this)'>View Code</button>"
                    $details = "Created: $($item.create_date) $viewCodeBtn"
                } elseif ($SectionName -eq "Synonyms") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.SYNONYM_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-synonym='$($item.SYNONYM_NAME)' data-source-create='$createStatement' data-target-create='$createStatement' data-source-base-object='$($item.base_object_name)' data-target-base-object='$($item.base_object_name)' onclick='showSynonymCode(this)'>View Code</button>"
                    $details = "Base Object: $($item.base_object_name) $viewCodeBtn"
                } elseif ($SectionName -eq "Table Triggers") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TABLE_NAME).$($item.TRIGGER_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $triggerType = if ($item.is_instead_of_trigger) { "INSTEAD OF" } else { "AFTER" }
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-table='$($item.TABLE_NAME)' data-trigger='$($item.TRIGGER_NAME)' data-source-create='$createStatement' data-target-create='$createStatement' data-source-disabled='$($item.is_disabled)' data-target-disabled='$($item.is_disabled)' data-source-instead-of='$($item.is_instead_of_trigger)' data-target-instead-of='$($item.is_instead_of_trigger)' onclick='showTableTriggerCode(this)'>View Code</button>"
                    $details = "Type: $triggerType, Disabled: $($item.is_disabled) $viewCodeBtn"
                } elseif ($SectionName -eq "Database Triggers") {
                    $objectName = "$($item.TRIGGER_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-trigger='$($item.TRIGGER_NAME)' data-source-create='$createStatement' data-target-create='$createStatement' data-source-disabled='$($item.is_disabled)' data-target-disabled='$($item.is_disabled)' onclick='showDatabaseTriggerCode(this)'>View Code</button>"
                    $details = "Disabled: $($item.is_disabled) $viewCodeBtn"
                } elseif ($SectionName -eq "Keys") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TABLE_NAME).$($item.KEY_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-table='$($item.TABLE_NAME)' data-key='$($item.KEY_NAME)' data-source-code='$createStatement' data-target-code='$createStatement' data-source-key-type='$($item.KEY_TYPE)' data-target-key-type='$($item.KEY_TYPE)' data-source-is-primary='$($item.is_primary_key)' data-target-is-primary='$($item.is_primary_key)' data-source-is-unique='$($item.is_unique)' data-target-is-unique='$($item.is_unique)' onclick='showKeyCode(this)'>View Code</button>"
                    $details = "Type: $($item.KEY_TYPE) $viewCodeBtn"
                } elseif ($SectionName -eq "Database Options") {
                    # Handle custom structure for database options
                    if ($item.Source -and $item.Target) {
                        # Matches or Differences - use source data for display
                        $sourceItem = $item.Source
                        $targetItem = $item.Target
                        $objectName = $sourceItem.OPTION_NAME
                        $sourceSqlCommand = [System.Web.HttpUtility]::HtmlEncode($sourceItem.SQL_COMMAND)
                        $targetSqlCommand = [System.Web.HttpUtility]::HtmlEncode($targetItem.SQL_COMMAND)
                        $viewCodeBtn = "<button class='view-code-btn' data-database='$($sourceItem.DATABASE_NAME)' data-option='$($sourceItem.OPTION_NAME)' data-source-code='$sourceSqlCommand' data-target-code='$targetSqlCommand' data-source-value='$($sourceItem.OPTION_VALUE)' data-target-value='$($targetItem.OPTION_VALUE)' onclick='showDatabaseOptionCode(this)'>View Code</button>"
                        $details = "Value: $($sourceItem.OPTION_VALUE) $viewCodeBtn"
                    } else {
                        # SourceOnly or TargetOnly - use item directly
                        $objectName = $item.OPTION_NAME
                        $sqlCommand = [System.Web.HttpUtility]::HtmlEncode($item.SQL_COMMAND)
                        $viewCodeBtn = "<button class='view-code-btn' data-database='$($item.DATABASE_NAME)' data-option='$($item.OPTION_NAME)' data-source-code='$sqlCommand' data-target-code='$sqlCommand' data-source-value='$($item.OPTION_VALUE)' data-target-value='$($item.OPTION_VALUE)' onclick='showDatabaseOptionCode(this)'>View Code</button>"
                        $details = "Value: $($item.OPTION_VALUE) $viewCodeBtn"
                    }
                } elseif ($SectionName -eq "File Information") {
                    $objectName = $item.name
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-file='$($item.name)' data-source-create='$createStatement' data-target-create='' data-source-type='$($item.type_desc)' data-target-type='' data-source-size='$($item.size_mb)' data-target-size='' data-source-filegroup='$($item.filegroup_name)' data-target-filegroup='' onclick='showFileCode(this)'>View Code</button>"
                    $details = "Type: $($item.type_desc), Size: $($item.size_mb) MB, Filegroup: $($item.filegroup_name), Growth: $($item.growth_display), Max Size: $($item.max_size_display) $viewCodeBtn"
                } elseif ($SectionName -eq "VLF Information") {
                    $objectName = $item.DATABASE_NAME
                    $vlfCount = $item.VLF_COUNT
                    $viewCodeBtn = "<button class='view-code-btn' data-source-count='$vlfCount' data-target-count='' data-source-db='$($item.DATABASE_NAME)' data-target-db='' onclick='showVLFCountCode(this)'>View Code</button>"
                    $details = "VLF Count: $vlfCount $viewCodeBtn"
                } elseif ($SectionName -eq "Schemas") {
                    $objectName = $item.SCHEMA_NAME
                    $principalName = if ($item.PRINCIPAL_NAME) { $item.PRINCIPAL_NAME } else { '' }
                    if ($principalName -ne '') {
                        $details = "Principal Id: $($item.PRINCIPAL_ID), Principal: $principalName"
                    } else {
                        $details = "Principal Id: $($item.PRINCIPAL_ID)"
                    }
                } elseif ($SectionName -eq "Query Store") {
                    $objectName = $item["OBJECT_NAME"]
                    $itemType = $item["ITEM_TYPE"]
                    
                    if ($itemType -eq "QS_CONFIG") {
                        $status = $item["QS_STATUS"]
                        $state = $item["ACTUAL_STATE"]
                        $details = "Query Store configuration present in source only - Status: $status, State: $state"
                    } elseif ($itemType -eq "QS_FORCED_PLAN") {
                        $queryText = [System.Web.HttpUtility]::HtmlEncode($item["QUERY_TEXT"])
                        $queryId = $item["QUERY_ID"]
                        $planId = $item["PLAN_ID"]
                        
                        $viewCodeBtn = "<button class='view-code-btn' data-schema='' data-function='QueryStore' data-source-code='$queryText' data-target-code='' onclick='showFunctionCodeFromData(this)'>View Query</button>"
                        $details = "Forced plan present in source only - QueryID: $queryId, PlanID: $planId $viewCodeBtn"
                    } else {
                        $details = "Query Store item present in source only"
                    }
                } elseif ($SectionName -eq "Users") {
                    $objectName = $item.USER_NAME
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-user='$($item.USER_NAME)' data-source-create='$createStatement' data-target-create='$createStatement' data-source-type='$($item.USER_TYPE)' data-target-type='$($item.USER_TYPE)' data-source-roles='$($item.ROLE_MEMBERSHIPS)' data-target-roles='$($item.ROLE_MEMBERSHIPS)' onclick='showUserCode(this)'>View Code</button>"
                    $details = "Type: $($item.USER_TYPE), Roles: $($item.ROLE_MEMBERSHIPS), Permissions: $($item.SECURABLES_PERMISSIONS) $viewCodeBtn"
                } elseif ($SectionName -eq "Roles") {
                    $objectName = $item.ROLE_NAME
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-role='$($item.ROLE_NAME)' data-source-create='$createStatement' data-target-create='$createStatement' data-source-type='$($item.ROLE_TYPE)' data-target-type='$($item.ROLE_TYPE)' data-source-members='$($item.ROLE_MEMBERS)' data-target-members='$($item.ROLE_MEMBERS)' onclick='showRoleCode(this)'>View Code</button>"
                    $details = "Type: $($item.ROLE_TYPE), Members: $($item.ROLE_MEMBERS), Permissions: $($item.ROLE_PERMISSIONS) $viewCodeBtn"
                } elseif ($SectionName -eq "VLF Information") {
                    $objectName = "VLF Count Comparison"
                    $vlfCount = $item.VLF_COUNT
                    $viewCodeBtn = "<button class='view-code-btn' data-source-count='$vlfCount' data-target-count='$vlfCount' data-source-db='$SourceDatabase' data-target-db='$TargetDatabase' onclick='showVLFCountCode(this)'>View Code</button>"
                    $details = "VLF Count: $vlfCount (Match) $viewCodeBtn"
                }
                if ($SectionName -eq "Query Store") {
                    if ([string]::IsNullOrWhiteSpace($objectName)) {
                        $objectName = "QueryId=$($item["QUERY_ID"]), PlanId=$($item["PLAN_ID"])"
                    }
                    $objectName = [System.Web.HttpUtility]::HtmlEncode($objectName)
                }
                $matchRows += @"

                    <tr class="match">
                        <td>$rowNumber</td>
                        <td>$objectName</td>
                        <td><span class="status-badge status-match">Match</span></td>
                        <td>$details</td>
                    </tr>
"@
                $rowNumber++
            }
        }
        
        # Process source only items
        if ($Data.SourceOnly) {
            foreach ($item in $Data.SourceOnly) {
                $objectName = ""
                $details = ""
                
                # Extract object name based on section type (same logic as above)
                if ($SectionName -eq "Query Store") {
                    $objectName = $item["OBJECT_NAME"]
                    $itemType = $item["ITEM_TYPE"]
                    
                    if ($itemType -eq "QS_CONFIG") {
                        $status = $item["QS_STATUS"]
                        $state = $item["ACTUAL_STATE"]
                        $details = "Query Store configuration present in source only - Status: $status, State: $state"
                    } elseif ($itemType -eq "QS_FORCED_PLAN") {
                        $queryText = [System.Web.HttpUtility]::HtmlEncode($item["QUERY_TEXT"])
                        $queryId = $item["QUERY_ID"]
                        $planId = $item["PLAN_ID"]
                        
                        $viewCodeBtn = "<button class='view-code-btn' data-schema='' data-function='QueryStore' data-source-code='$queryText' data-target-code='' onclick='showFunctionCodeFromData(this)'>View Query</button>"
                        $details = "Forced plan present in source only - QueryID: $queryId, PlanID: $planId $viewCodeBtn"
                    } else {
                        $details = "Query Store item present in source only"
                    }
                } elseif ($SectionName -eq "Tables") {
                    $objectName = "$($item.TABLE_SCHEMA).$($item.TABLE_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.TABLE_SCHEMA)' data-table='$($item.TABLE_NAME)' data-source-create='$createStatement' data-target-create='' data-source-create-date='$($item.create_date)' data-target-create-date='' data-source-modify-date='$($item.modify_date)' data-target-modify-date='' data-source-row-count='$($item.ROW_COUNT)' data-target-row-count='' onclick='showTableCode(this)'>View Code</button>"
                    $details = "Type: $($item.TABLE_TYPE), Rows: $($item.ROW_COUNT) $viewCodeBtn"
                } elseif ($SectionName -eq "Columns") {
                    $objectName = "$($item.TABLE_SCHEMA).$($item.TABLE_NAME).$($item.COLUMN_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.TABLE_SCHEMA)' data-table='$($item.TABLE_NAME)' data-column='$($item.COLUMN_NAME)' data-source-create='$createStatement' data-target-create='' data-source-datatype='$($item.DATA_TYPE)' data-target-datatype='' data-source-nullable='$($item.IS_NULLABLE)' data-target-nullable='' onclick='showColumnCode(this)'>View Code</button>"
                    $details = "Type: $($item.DATA_TYPE), Nullable: $($item.IS_NULLABLE) $viewCodeBtn"
                } elseif ($SectionName -eq "Indexes") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TABLE_NAME).$($item.INDEX_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-table='$($item.TABLE_NAME)' data-index='$($item.INDEX_NAME)' data-source-create='$createStatement' data-target-create='' data-source-index-type='$($item.INDEX_TYPE)' data-target-index-type='' data-source-is-unique='$($item.is_unique)' data-target-is-unique='' onclick='showIndexCode(this)'>View Code</button>"
                    $details = "Type: $($item.INDEX_TYPE), Unique: $($item.is_unique), Columns: [$($item.INDEX_COLUMNS)] $viewCodeBtn"
                } elseif ($SectionName -eq "Functions") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.FUNCTION_NAME)"
                    $funcDef = [System.Web.HttpUtility]::HtmlEncode($item.definition)
                    $funcDef = ($funcDef -replace '"', '&quot;' -replace "'", '&#39;')
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-function='$($item.FUNCTION_NAME)' data-source-code='$funcDef' data-target-code='' onclick='showFunctionCodeFromData(this)'>View Code</button>"
                    $details = "Type: $($item.FUNCTION_TYPE) $viewCodeBtn"
                } elseif ($SectionName -eq "Stored Procedures") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.PROCEDURE_NAME)"
                    $procDef = [System.Web.HttpUtility]::HtmlEncode($item.definition)
                    $procDef = ($procDef -replace '"', '&quot;' -replace "'", '&#39;')
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-function='$($item.PROCEDURE_NAME)' data-object-type='Stored Procedure' data-source-code='$procDef' data-target-code='' onclick='showFunctionCodeFromData(this)'>View Code</button>"
                    $details = "Created: $($item.create_date) $viewCodeBtn"
                } elseif ($SectionName -eq "Data Types") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TYPE_NAME)"
                    $typeDef = "System Type ID: $($item.system_type_id)|User Type ID: $($item.user_type_id)|Max Length: $($item.max_length)|Precision: $($item.precision)|Scale: $($item.scale)|Collation: $($item.collation_name)|Is Nullable: $($item.is_nullable)|Is User Defined: $($item.is_user_defined)|Is Assembly Type: $($item.is_assembly_type)"
                    $typeDef = ($typeDef -replace '"', '\&quot;' -replace "'", "\'")
                    $viewDetailsBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-type='$($item.TYPE_NAME)' data-source-def='$typeDef' data-target-def='' onclick='showDataTypeDetails(this)'>View Details</button>"
                    $details = "Precision: $($item.precision), Scale: $($item.scale) $viewDetailsBtn"
                } elseif ($SectionName -eq "Constraints") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TABLE_NAME).$($item.CONSTRAINT_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-table='$($item.TABLE_NAME)' data-constraint='$($item.CONSTRAINT_NAME)' data-source-create='$createStatement' data-target-create='' data-source-type='$($item.CONSTRAINT_TYPE)' data-target-type='' data-source-disabled='$($item.is_disabled)' data-target-disabled='' onclick='showConstraintCode(this)'>View Code</button>"
                    $details = "Type: $($item.CONSTRAINT_TYPE) $viewCodeBtn"
                } elseif ($SectionName -eq "Views") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.VIEW_NAME)"
                    $viewCode = [System.Web.HttpUtility]::HtmlEncode($item.definition)
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-view='$($item.VIEW_NAME)' data-source-code='$viewCode' data-target-code='' data-source-create-date='$($item.create_date)' data-target-create-date='' data-source-modify-date='$($item.modify_date)' data-target-modify-date='' onclick='showViewCode(this)'>View Code</button>"
                    $details = "Created: $($item.create_date) $viewCodeBtn"
                } elseif ($SectionName -eq "Synonyms") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.SYNONYM_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-synonym='$($item.SYNONYM_NAME)' data-source-create='$createStatement' data-target-create='' data-source-base-object='$($item.base_object_name)' data-target-base-object='' onclick='showSynonymCode(this)'>View Code</button>"
                    $details = "Base Object: $($item.base_object_name) $viewCodeBtn"
                } elseif ($SectionName -eq "Table Triggers") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TABLE_NAME).$($item.TRIGGER_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $triggerType = if ($item.is_instead_of_trigger) { "INSTEAD OF" } else { "AFTER" }
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-table='$($item.TABLE_NAME)' data-trigger='$($item.TRIGGER_NAME)' data-source-create='$createStatement' data-target-create='' data-source-disabled='$($item.is_disabled)' data-target-disabled='' data-source-instead-of='$($item.is_instead_of_trigger)' data-target-instead-of='' onclick='showTableTriggerCode(this)'>View Code</button>"
                    $details = "Type: $triggerType, Disabled: $($item.is_disabled) $viewCodeBtn"
                } elseif ($SectionName -eq "Database Triggers") {
                    $objectName = "$($item.TRIGGER_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-trigger='$($item.TRIGGER_NAME)' data-source-create='$createStatement' data-target-create='' data-source-disabled='$($item.is_disabled)' data-target-disabled='' onclick='showDatabaseTriggerCode(this)'>View Code</button>"
                    $details = "Disabled: $($item.is_disabled) $viewCodeBtn"
                } elseif ($SectionName -eq "Keys") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TABLE_NAME).$($item.KEY_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-table='$($item.TABLE_NAME)' data-key='$($item.KEY_NAME)' data-source-code='$createStatement' data-target-code='' data-source-key-type='$($item.KEY_TYPE)' data-target-key-type='' data-source-is-primary='$($item.is_primary_key)' data-target-is-primary='' data-source-is-unique='$($item.is_unique)' data-target-is-unique='' onclick='showKeyCode(this)'>View Code</button>"
                    $details = "Type: $($item.KEY_TYPE) $viewCodeBtn"
                } elseif ($SectionName -eq "Database Options") {
                    $objectName = $item.OPTION_NAME
                    $sqlCommand = [System.Web.HttpUtility]::HtmlEncode($item.SQL_COMMAND)
                    $viewCodeBtn = "<button class='view-code-btn' data-database='$($item.DATABASE_NAME)' data-option='$($item.OPTION_NAME)' data-source-code='$sqlCommand' data-target-code='' data-source-value='$($item.OPTION_VALUE)' data-target-value='' onclick='showDatabaseOptionCode(this)'>View Code</button>"
                    $details = "Value: $($item.OPTION_VALUE) $viewCodeBtn"
                } elseif ($SectionName -eq "File Information") {
                    $objectName = $item.name
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-file='$($item.name)' data-source-create='' data-target-create='$createStatement' data-source-type='' data-target-type='$($item.type_desc)' data-source-size='' data-target-size='$($item.size_mb)' data-source-filegroup='' data-target-filegroup='$($item.filegroup_name)' onclick='showFileCode(this)'>View Code</button>"
                    $details = "Type: $($item.type_desc), Size: $($item.size_mb) MB, Filegroup: $($item.filegroup_name), Growth: $($item.growth_display), Max Size: $($item.max_size_display) $viewCodeBtn"
                } elseif ($SectionName -eq "VLF Information") {
                    $objectName = $item.DATABASE_NAME
                    $vlfCount = $item.VLF_COUNT
                    $viewCodeBtn = "<button class='view-code-btn' data-source-count='$vlfCount' data-target-count='' data-source-db='$($item.DATABASE_NAME)' data-target-db='' onclick='showVLFCountCode(this)'>View Code</button>"
                    $details = "VLF Count: $vlfCount $viewCodeBtn"
                } elseif ($SectionName -eq "Schemas") {
                    $objectName = $item.SCHEMA_NAME
                    $details = "Principal Id: $($item.PRINCIPAL_ID), Created: $($item.create_date), Modified: $($item.modify_date)"
                } elseif ($SectionName -eq "Users") {
                    $objectName = $item.USER_NAME
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-user='$($item.USER_NAME)' data-source-create='$createStatement' data-target-create='$createStatement' data-source-type='$($item.USER_TYPE)' data-target-type='$($item.USER_TYPE)' data-source-roles='$($item.ROLE_MEMBERSHIPS)' data-target-roles='$($item.ROLE_MEMBERSHIPS)' onclick='showUserCode(this)'>View Code</button>"
                    $details = "Type: $($item.USER_TYPE), Roles: $($item.ROLE_MEMBERSHIPS), Permissions: $($item.SECURABLES_PERMISSIONS) $viewCodeBtn"
                } elseif ($SectionName -eq "Roles") {
                    $objectName = $item.ROLE_NAME
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-role='$($item.ROLE_NAME)' data-source-create='$createStatement' data-target-create='$createStatement' data-source-type='$($item.ROLE_TYPE)' data-target-type='$($item.ROLE_TYPE)' data-source-members='$($item.ROLE_MEMBERS)' data-target-members='$($item.ROLE_MEMBERS)' onclick='showRoleCode(this)'>View Code</button>"
                    $details = "Type: $($item.ROLE_TYPE), Members: $($item.ROLE_MEMBERS), Permissions: $($item.ROLE_PERMISSIONS) $viewCodeBtn"
                }
                
                if ($SectionName -eq "Query Store") {
                    if ([string]::IsNullOrWhiteSpace($objectName)) {
                        $objectName = "QueryId=$($item["QUERY_ID"]), PlanId=$($item["PLAN_ID"])"
                    }
                    $objectName = [System.Web.HttpUtility]::HtmlEncode($objectName)
                }
                $sourceOnlyRows += @"

                    <tr class="source-only">
                        <td>$rowNumber</td>
                        <td>$objectName</td>
                        <td><span class="status-badge status-source-only">Source Only</span></td>
                        <td>$details</td>
                    </tr>
"@
                $rowNumber++
            }
        }
        
        # Process target only items
        if ($Data.TargetOnly) {
            foreach ($item in $Data.TargetOnly) {
                $objectName = ""
                $details = ""
                
                # Extract object name based on section type (same logic as above)
                if ($SectionName -eq "Tables") {
                    $objectName = "$($item.TABLE_SCHEMA).$($item.TABLE_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.TABLE_SCHEMA)' data-table='$($item.TABLE_NAME)' data-source-create='' data-target-create='$createStatement' data-source-create-date='' data-target-create-date='$($item.create_date)' data-source-modify-date='' data-target-modify-date='$($item.modify_date)' data-source-row-count='' data-target-row-count='$($item.ROW_COUNT)' onclick='showTableCode(this)'>View Code</button>"
                    $details = "Type: $($item.TABLE_TYPE), Rows: $($item.ROW_COUNT) $viewCodeBtn"
                } elseif ($SectionName -eq "Columns") {
                    $objectName = "$($item.TABLE_SCHEMA).$($item.TABLE_NAME).$($item.COLUMN_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.TABLE_SCHEMA)' data-table='$($item.TABLE_NAME)' data-column='$($item.COLUMN_NAME)' data-source-create='' data-target-create='$createStatement' data-source-datatype='' data-target-datatype='$($item.DATA_TYPE)' data-source-nullable='' data-target-nullable='$($item.IS_NULLABLE)' onclick='showColumnCode(this)'>View Code</button>"
                    $details = "Type: $($item.DATA_TYPE), Nullable: $($item.IS_NULLABLE) $viewCodeBtn"
                } elseif ($SectionName -eq "Indexes") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TABLE_NAME).$($item.INDEX_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-table='$($item.TABLE_NAME)' data-index='$($item.INDEX_NAME)' data-source-create='' data-target-create='$createStatement' data-source-index-type='' data-target-index-type='$($item.INDEX_TYPE)' data-source-is-unique='' data-target-is-unique='$($item.is_unique)' onclick='showIndexCode(this)'>View Code</button>"
                    $details = "Type: $($item.INDEX_TYPE), Unique: $($item.is_unique), Columns: [$($item.INDEX_COLUMNS)] $viewCodeBtn"
                } elseif ($SectionName -eq "Query Store") {
                    $qt = $item["SHORT_QUERY_TEXT"]
                    if ($qt) {
                        $objectName = $qt
                    } else {
                        $qtFull = $item["QUERY_TEXT"]
                        if ($qtFull) {
                            if ($qtFull.Length -gt 255) { $objectName = $qtFull.Substring(0,255) + '...' } else { $objectName = $qtFull }
                        } else {
                            $objectName = "QueryId=$($item["QUERY_ID"]), PlanId=$($item["PLAN_ID"])"
                        }
                    }
                    $full = [System.Web.HttpUtility]::HtmlEncode($item["QUERY_TEXT"])
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='' data-function='QueryStore' data-source-code='' data-target-code='$full' onclick='showFunctionCodeFromData(this)'>View Code</button>"
                    $details = "Forced plan present in target $viewCodeBtn"
                } elseif ($SectionName -eq "Functions") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.FUNCTION_NAME)"
                    $funcDef = [System.Web.HttpUtility]::HtmlEncode($item.definition)
                    $funcDef = ($funcDef -replace '"', '&quot;' -replace "'", '&#39;')
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-function='$($item.FUNCTION_NAME)' data-source-code='' data-target-code='$funcDef' onclick='showFunctionCodeFromData(this)'>View Code</button>"
                    $details = "Type: $($item.FUNCTION_TYPE) $viewCodeBtn"
                } elseif ($SectionName -eq "Stored Procedures") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.PROCEDURE_NAME)"
                    $procDef = [System.Web.HttpUtility]::HtmlEncode($item.definition)
                    $procDef = ($procDef -replace '"', '&quot;' -replace "'", '&#39;')
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-function='$($item.PROCEDURE_NAME)' data-object-type='Stored Procedure' data-source-code='' data-target-code='$procDef' onclick='showFunctionCodeFromData(this)'>View Code</button>"
                    $details = "Created: $($item.create_date) $viewCodeBtn"
                } elseif ($SectionName -eq "Data Types") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TYPE_NAME)"
                    $typeDef = "System Type ID: $($item.system_type_id)|User Type ID: $($item.user_type_id)|Max Length: $($item.max_length)|Precision: $($item.precision)|Scale: $($item.scale)|Collation: $($item.collation_name)|Is Nullable: $($item.is_nullable)|Is User Defined: $($item.is_user_defined)|Is Assembly Type: $($item.is_assembly_type)"
                    $typeDef = ($typeDef -replace '"', '\&quot;' -replace "'", "\'")
                    $viewDetailsBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-type='$($item.TYPE_NAME)' data-source-def='' data-target-def='$typeDef' onclick='showDataTypeDetails(this)'>View Details</button>"
                    $details = "Precision: $($item.precision), Scale: $($item.scale) $viewDetailsBtn"
                } elseif ($SectionName -eq "Constraints") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TABLE_NAME).$($item.CONSTRAINT_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-table='$($item.TABLE_NAME)' data-constraint='$($item.CONSTRAINT_NAME)' data-source-create='' data-target-create='$createStatement' data-source-type='' data-target-type='$($item.CONSTRAINT_TYPE)' data-source-disabled='' data-target-disabled='$($item.is_disabled)' onclick='showConstraintCode(this)'>View Code</button>"
                    $details = "Type: $($item.CONSTRAINT_TYPE) $viewCodeBtn"
                } elseif ($SectionName -eq "Views") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.VIEW_NAME)"
                    $viewCode = [System.Web.HttpUtility]::HtmlEncode($item.definition)
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-view='$($item.VIEW_NAME)' data-source-code='' data-target-code='$viewCode' data-source-create-date='' data-target-create-date='$($item.create_date)' data-source-modify-date='' data-target-modify-date='$($item.modify_date)' onclick='showViewCode(this)'>View Code</button>"
                    $details = "Created: $($item.create_date) $viewCodeBtn"
                } elseif ($SectionName -eq "Synonyms") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.SYNONYM_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-synonym='$($item.SYNONYM_NAME)' data-source-create='' data-target-create='$createStatement' data-source-base-object='' data-target-base-object='$($item.base_object_name)' onclick='showSynonymCode(this)'>View Code</button>"
                    $details = "Base Object: $($item.base_object_name) $viewCodeBtn"
                } elseif ($SectionName -eq "Table Triggers") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TABLE_NAME).$($item.TRIGGER_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $triggerType = if ($item.is_instead_of_trigger) { "INSTEAD OF" } else { "AFTER" }
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-table='$($item.TABLE_NAME)' data-trigger='$($item.TRIGGER_NAME)' data-source-create='' data-target-create='$createStatement' data-source-disabled='' data-target-disabled='$($item.is_disabled)' data-source-instead-of='' data-target-instead-of='$($item.is_instead_of_trigger)' onclick='showTableTriggerCode(this)'>View Code</button>"
                    $details = "Type: $triggerType, Disabled: $($item.is_disabled) $viewCodeBtn"
                } elseif ($SectionName -eq "Database Triggers") {
                    $objectName = "$($item.TRIGGER_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-trigger='$($item.TRIGGER_NAME)' data-source-create='' data-target-create='$createStatement' data-source-disabled='' data-target-disabled='$($item.is_disabled)' onclick='showDatabaseTriggerCode(this)'>View Code</button>"
                    $details = "Disabled: $($item.is_disabled) $viewCodeBtn"
                } elseif ($SectionName -eq "Keys") {
                    $objectName = "$($item.SCHEMA_NAME).$($item.TABLE_NAME).$($item.KEY_NAME)"
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-schema='$($item.SCHEMA_NAME)' data-table='$($item.TABLE_NAME)' data-key='$($item.KEY_NAME)' data-source-code='' data-target-code='$createStatement' data-source-key-type='' data-target-key-type='$($item.KEY_TYPE)' data-source-is-primary='' data-target-is-primary='$($item.is_primary_key)' data-source-is-unique='' data-target-is-unique='$($item.is_unique)' onclick='showKeyCode(this)'>View Code</button>"
                    $details = "Type: $($item.KEY_TYPE) $viewCodeBtn"
                } elseif ($SectionName -eq "Database Options") {
                    $objectName = $item.OPTION_NAME
                    $sqlCommand = [System.Web.HttpUtility]::HtmlEncode($item.SQL_COMMAND)
                    $viewCodeBtn = "<button class='view-code-btn' data-database='$($item.DATABASE_NAME)' data-option='$($item.OPTION_NAME)' data-source-code='' data-target-code='$sqlCommand' data-source-value='' data-target-value='$($item.OPTION_VALUE)' onclick='showDatabaseOptionCode(this)'>View Code</button>"
                    $details = "Value: $($item.OPTION_VALUE) $viewCodeBtn"
                } elseif ($SectionName -eq "File Information") {
                    $objectName = $item.name
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-file='$($item.name)' data-source-create='' data-target-create='$createStatement' data-source-type='' data-target-type='$($item.type_desc)' data-source-size='' data-target-size='$($item.size_mb)' data-source-filegroup='' data-target-filegroup='$($item.filegroup_name)' onclick='showFileCode(this)'>View Code</button>"
                    $details = "Type: $($item.type_desc), Size: $($item.size_mb) MB, Filegroup: $($item.filegroup_name), Growth: $($item.growth_display), Max Size: $($item.max_size_display) $viewCodeBtn"
                } elseif ($SectionName -eq "VLF Information") {
                    $objectName = $item.DATABASE_NAME
                    $vlfCount = $item.VLF_COUNT
                    $viewCodeBtn = "<button class='view-code-btn' data-source-count='$vlfCount' data-target-count='' data-source-db='$($item.DATABASE_NAME)' data-target-db='' onclick='showVLFCountCode(this)'>View Code</button>"
                    $details = "VLF Count: $vlfCount $viewCodeBtn"
                } elseif ($SectionName -eq "Schemas") {
                    $objectName = $item.SCHEMA_NAME
                    $details = "Principal Id: $($item.PRINCIPAL_ID), Created: $($item.create_date), Modified: $($item.modify_date)"
                } elseif ($SectionName -eq "Users") {
                    $objectName = $item.USER_NAME
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-user='$($item.USER_NAME)' data-source-create='$createStatement' data-target-create='$createStatement' data-source-type='$($item.USER_TYPE)' data-target-type='$($item.USER_TYPE)' data-source-roles='$($item.ROLE_MEMBERSHIPS)' data-target-roles='$($item.ROLE_MEMBERSHIPS)' onclick='showUserCode(this)'>View Code</button>"
                    $details = "Type: $($item.USER_TYPE), Roles: $($item.ROLE_MEMBERSHIPS), Permissions: $($item.SECURABLES_PERMISSIONS) $viewCodeBtn"
                } elseif ($SectionName -eq "Roles") {
                    $objectName = $item.ROLE_NAME
                    $createStatement = [System.Web.HttpUtility]::HtmlEncode(($item.CREATE_STATEMENT -replace "`r", ""))
                    $viewCodeBtn = "<button class='view-code-btn' data-role='$($item.ROLE_NAME)' data-source-create='$createStatement' data-target-create='$createStatement' data-source-type='$($item.ROLE_TYPE)' data-target-type='$($item.ROLE_TYPE)' data-source-members='$($item.ROLE_MEMBERS)' data-target-members='$($item.ROLE_MEMBERS)' onclick='showRoleCode(this)'>View Code</button>"
                    $details = "Type: $($item.ROLE_TYPE), Members: $($item.ROLE_MEMBERS), Permissions: $($item.ROLE_PERMISSIONS) $viewCodeBtn"
                }
                
                if ($SectionName -eq "Query Store") {
                    if ([string]::IsNullOrWhiteSpace($objectName)) {
                        $objectName = "QueryId=$($item["QUERY_ID"]), PlanId=$($item["PLAN_ID"])"
                    }
                    $objectName = [System.Web.HttpUtility]::HtmlEncode($objectName)
                }
                $targetOnlyRows += @"

                    <tr class="target-only">
                        <td>$rowNumber</td>
                        <td>$objectName</td>
                        <td><span class="status-badge status-target-only">Target Only</span></td>
                        <td>$details</td>
                    </tr>
"@
                $rowNumber++
            }
        }
        
        # Combine all row types - MISMATCH FIRST (most important!)
        $html += $mismatchRows
        $html += $matchRows  
        $html += $sourceOnlyRows
        $html += $targetOnlyRows
        
        $html += @"
                </tbody>
            </table>
"@
    } else {
        $html += @"
            <div class="no-data">No data available for this section</div>
"@
    }
    
    $html += @"
        </div>
    </div>
"@
    
    return $html
}

# Main execution
Write-Host "Starting Database Schema Drift Detection..." -ForegroundColor Green
Write-Host "Source: $SourceServer.$SourceDatabase" -ForegroundColor Cyan
Write-Host "Target: $TargetServer.$TargetDatabase" -ForegroundColor Cyan
Write-Host "Output: $OutputPath" -ForegroundColor Cyan

# Collect data from both databases - TABLES, COLUMNS, INDEXES, FUNCTIONS, AND STORED PROCEDURES
Write-Host "`nCollecting data from source database..." -ForegroundColor Yellow
$sourceTables = Get-TableInfo -Server $SourceServer -Database $SourceDatabase
$sourceColumns = Get-ColumnInfo -Server $SourceServer -Database $SourceDatabase
$sourceIndexes = Get-IndexInfo -Server $SourceServer -Database $SourceDatabase
$sourceFunctions = Get-FunctionInfo -Server $SourceServer -Database $SourceDatabase
$sourceProcedures = Get-StoredProcedureInfo -Server $SourceServer -Database $SourceDatabase
$sourceSchemas = Get-SchemaInfo -Server $SourceServer -Database $SourceDatabase

Write-Host "Collecting data from target database..." -ForegroundColor Yellow
$targetTables = Get-TableInfo -Server $TargetServer -Database $TargetDatabase
$targetColumns = Get-ColumnInfo -Server $TargetServer -Database $TargetDatabase
$targetIndexes = Get-IndexInfo -Server $TargetServer -Database $TargetDatabase
$targetFunctions = Get-FunctionInfo -Server $TargetServer -Database $TargetDatabase
$targetProcedures = Get-StoredProcedureInfo -Server $TargetServer -Database $TargetDatabase
$targetSchemas = Get-SchemaInfo -Server $TargetServer -Database $TargetDatabase

# Collect detailed Query Store information including forced plans and configuration
function Get-QueryStoreInfo {
    param([string]$Server, [string]$Database)
    
    # First get the configuration
    $configQuery = @"
SELECT 
    'QS_CONFIG' AS ITEM_TYPE,
    'Query Store Configuration' AS OBJECT_NAME,
    DB_NAME() AS DATABASE_NAME,
    CASE 
        WHEN EXISTS (SELECT 1 FROM sys.database_query_store_options WHERE actual_state_desc IN ('READ_WRITE', 'READ_ONLY'))
        THEN 'ENABLED'
        ELSE 'DISABLED'
    END AS QS_STATUS,
    ISNULL((SELECT actual_state_desc FROM sys.database_query_store_options), 'OFF') AS ACTUAL_STATE,
    ISNULL((SELECT desired_state_desc FROM sys.database_query_store_options), 'OFF') AS DESIRED_STATE,
    ISNULL((SELECT current_storage_size_mb FROM sys.database_query_store_options), 0) AS CURRENT_STORAGE_SIZE_MB,
    ISNULL((SELECT max_storage_size_mb FROM sys.database_query_store_options), 0) AS MAX_STORAGE_SIZE_MB,
    ISNULL((SELECT query_capture_mode_desc FROM sys.database_query_store_options), 'NONE') AS QUERY_CAPTURE_MODE,
    ISNULL((SELECT size_based_cleanup_mode_desc FROM sys.database_query_store_options), 'OFF') AS SIZE_CLEANUP_MODE,
    ISNULL((SELECT stale_query_threshold_days FROM sys.database_query_store_options), 0) AS STALE_QUERY_THRESHOLD_DAYS,
    ISNULL((SELECT max_plans_per_query FROM sys.database_query_store_options), 0) AS MAX_PLANS_PER_QUERY,
    ISNULL((SELECT wait_stats_capture_mode_desc FROM sys.database_query_store_options), 'NONE') AS WAIT_STATS_CAPTURE_MODE,
    CAST(NULL AS NVARCHAR(MAX)) AS QUERY_TEXT,
    CAST(NULL AS INT) AS QUERY_ID,
    CAST(NULL AS INT) AS PLAN_ID,
    CAST(NULL AS XML) AS QUERY_PLAN_XML
UNION ALL
SELECT 
    'QS_FORCED_PLAN' AS ITEM_TYPE,
    CASE 
        WHEN LEN(CAST(qt.query_sql_text AS NVARCHAR(MAX))) > 0
        THEN CAST(LEFT(qt.query_sql_text, 300) AS NVARCHAR(300)) + 
             CASE WHEN LEN(qt.query_sql_text) > 300 THEN '...' ELSE '' END
        ELSE 'QueryID=' + CAST(qsq.query_id AS NVARCHAR(20)) + ', PlanID=' + CAST(qsp.plan_id AS NVARCHAR(20))
    END AS OBJECT_NAME,
    DB_NAME() AS DATABASE_NAME,
    'ENABLED' AS QS_STATUS,
    'FORCED_PLAN' AS ACTUAL_STATE,
    'FORCED_PLAN' AS DESIRED_STATE,
    CAST(0 AS DECIMAL(18,2)) AS CURRENT_STORAGE_SIZE_MB,
    CAST(0 AS DECIMAL(18,2)) AS MAX_STORAGE_SIZE_MB,
    'FORCED' AS QUERY_CAPTURE_MODE,
    'AUTO' AS SIZE_CLEANUP_MODE,
    CAST(0 AS BIGINT) AS STALE_QUERY_THRESHOLD_DAYS,
    CAST(1 AS BIGINT) AS MAX_PLANS_PER_QUERY,
    'ON' AS WAIT_STATS_CAPTURE_MODE,
    CAST(qt.query_sql_text AS NVARCHAR(MAX)) AS QUERY_TEXT,
  qsq.query_id AS QUERY_ID,
  qsp.plan_id AS PLAN_ID,
  TRY_CONVERT(XML, qsp.query_plan) AS QUERY_PLAN_XML
FROM sys.query_store_plan AS qsp
JOIN sys.query_store_query AS qsq ON qsp.query_id = qsq.query_id
JOIN sys.query_store_query_text AS qt ON qsq.query_text_id = qt.query_text_id
WHERE qsp.is_forced_plan = 1
  AND TRY_CONVERT(XML, qsp.query_plan) IS NOT NULL
ORDER BY ITEM_TYPE, OBJECT_NAME;
"@
    return Invoke-SqlQuery -Server $Server -Database $Database -Query $configQuery
}
Write-Host "Collecting Query Store information from source..." -ForegroundColor Yellow
try {
    $sourceQueryStore = Get-QueryStoreInfo -Server $SourceServer -Database $SourceDatabase
    Write-Host "Source Query Store query executed successfully" -ForegroundColor Green
if ($sourceQueryStore) {
        Write-Host "DEBUG: Source returned $($sourceQueryStore.GetType().Name)" -ForegroundColor Yellow
    if ($sourceQueryStore.GetType().Name -eq "DataTable") {
            Write-Host "DEBUG: Source has $($sourceQueryStore.Rows.Count) rows" -ForegroundColor Yellow
        }
    } else {
        Write-Host "DEBUG: Source returned null" -ForegroundColor Yellow
    }
} catch {
    Write-Host "ERROR in source Query Store: $($_.Exception.Message)" -ForegroundColor Red
    $sourceQueryStore = $null
}
Write-Host "Collecting Query Store information from target..." -ForegroundColor Yellow
try {
    $targetQueryStore = Get-QueryStoreInfo -Server $TargetServer -Database $TargetDatabase
    Write-Host "Target Query Store query executed successfully" -ForegroundColor Green
} catch {
    Write-Host "ERROR in target Query Store: $($_.Exception.Message)" -ForegroundColor Red
    $targetQueryStore = $null
}
if ($sourceQueryStore) {
    if ($sourceQueryStore.GetType().Name -eq "DataTable" -and $sourceQueryStore.Rows.Count -gt 0) {
        $configRow = $sourceQueryStore.Rows | Where-Object { $_.ITEM_TYPE -eq 'QS_CONFIG' } | Select-Object -First 1
        if ($configRow) {
            Write-Host "Source Query Store: $($configRow.QS_STATUS) - State: $($configRow.ACTUAL_STATE) (Items: $($sourceQueryStore.Rows.Count))" -ForegroundColor Magenta
        } else {
            Write-Host "Source Query Store: Items: $($sourceQueryStore.Rows.Count)" -ForegroundColor Magenta
        }
    } elseif ($sourceQueryStore.GetType().Name -eq "Object[]" -and $sourceQueryStore.Count -gt 0) {
        $configRow = $sourceQueryStore | Where-Object { $_.ITEM_TYPE -eq 'QS_CONFIG' } | Select-Object -First 1
        if ($configRow) {
            Write-Host "Source Query Store: $($configRow.QS_STATUS) - State: $($configRow.ACTUAL_STATE) (Items: $($sourceQueryStore.Count))" -ForegroundColor Magenta
        } else {
            Write-Host "Source Query Store: Items: $($sourceQueryStore.Count)" -ForegroundColor Magenta
        }
    } else {
        Write-Host "Source Query Store: No data" -ForegroundColor Magenta
    }
} else { Write-Host "Source Query Store: No data" -ForegroundColor Magenta }

if ($targetQueryStore) {
    if ($targetQueryStore.GetType().Name -eq "DataTable" -and $targetQueryStore.Rows.Count -gt 0) {
        $configRow = $targetQueryStore.Rows | Where-Object { $_.ITEM_TYPE -eq 'QS_CONFIG' } | Select-Object -First 1
        if ($configRow) {
            Write-Host "Target Query Store: $($configRow.QS_STATUS) - State: $($configRow.ACTUAL_STATE) (Items: $($targetQueryStore.Rows.Count))" -ForegroundColor Magenta
    } else {
            Write-Host "Target Query Store: Items: $($targetQueryStore.Rows.Count)" -ForegroundColor Magenta
        }
    } elseif ($targetQueryStore.GetType().Name -eq "Object[]" -and $targetQueryStore.Count -gt 0) {
        $configRow = $targetQueryStore | Where-Object { $_.ITEM_TYPE -eq 'QS_CONFIG' } | Select-Object -First 1
        if ($configRow) {
            Write-Host "Target Query Store: $($configRow.QS_STATUS) - State: $($configRow.ACTUAL_STATE) (Items: $($targetQueryStore.Count))" -ForegroundColor Magenta
        } else {
            Write-Host "Target Query Store: Items: $($targetQueryStore.Count)" -ForegroundColor Magenta
        }
    } else {
        Write-Host "Target Query Store: No data" -ForegroundColor Magenta
    }
} else { Write-Host "Target Query Store: No data" -ForegroundColor Magenta }

# Collect data types
$sourceDataTypes = Get-DataTypeInfo -Server $SourceServer -Database $SourceDatabase
$targetDataTypes = Get-DataTypeInfo -Server $TargetServer -Database $TargetDatabase

# Collect constraints
$sourceConstraints = Get-ConstraintInfo -Server $SourceServer -Database $SourceDatabase
$targetConstraints = Get-ConstraintInfo -Server $TargetServer -Database $TargetDatabase


# Collect views
$sourceViews = Get-ViewInfo -Server $SourceServer -Database $SourceDatabase
$targetViews = Get-ViewInfo -Server $TargetServer -Database $TargetDatabase

# Collect synonyms
$sourceSynonyms = Get-SynonymInfo -Server $SourceServer -Database $SourceDatabase
$targetSynonyms = Get-SynonymInfo -Server $TargetServer -Database $TargetDatabase

# Collect table triggers
$sourceTableTriggers = Get-TableTriggerInfo -Server $SourceServer -Database $SourceDatabase
$targetTableTriggers = Get-TableTriggerInfo -Server $TargetServer -Database $TargetDatabase
# Collect database triggers
$sourceDatabaseTriggers = Get-DatabaseTriggerInfo -Server $SourceServer -Database $SourceDatabase
$targetDatabaseTriggers = Get-DatabaseTriggerInfo -Server $TargetServer -Database $TargetDatabase

# Collect keys
Write-Host "Collecting keys from source database..." -ForegroundColor Yellow
try {
    $sourceKeys = Get-KeyInfo -Server $SourceServer -Database $SourceDatabase
    Write-Host "Source keys collected successfully" -ForegroundColor Green
} catch {
    Write-Host "Error collecting source keys: $($_.Exception.Message)" -ForegroundColor Red
    $sourceKeys = $null
}
Write-Host "Collecting keys from target database..." -ForegroundColor Yellow
try {
    $targetKeys = Get-KeyInfo -Server $TargetServer -Database $TargetDatabase
    Write-Host "Target keys collected successfully" -ForegroundColor Green
} catch {
    Write-Host "Error collecting target keys: $($_.Exception.Message)" -ForegroundColor Red
    $targetKeys = $null
}

# Collect VLF count
Write-Host "Collecting VLF count from source database..." -ForegroundColor Yellow
try {
    $sourceVLFCount = Get-VLFCount -Server $SourceServer -Database $SourceDatabase
    Write-Host "Source VLF count: $sourceVLFCount" -ForegroundColor Green
} catch {
    Write-Host "Error collecting source VLF count: $($_.Exception.Message)" -ForegroundColor Red
    $sourceVLFCount = 0
}

Write-Host "Collecting VLF count from target database..." -ForegroundColor Yellow
try {
    $targetVLFCount = Get-VLFCount -Server $TargetServer -Database $TargetDatabase
    Write-Host "Target VLF count: $targetVLFCount" -ForegroundColor Green
} catch {
    Write-Host "Error collecting target VLF count: $($_.Exception.Message)" -ForegroundColor Red
    $targetVLFCount = 0
}

# Collect files
Write-Host "Collecting files from source database..." -ForegroundColor Yellow
try {
    $sourceFiles = Get-FileInfo -Server $SourceServer -Database $SourceDatabase
    Write-Host "Source files collected successfully" -ForegroundColor Green
    if ($sourceFiles) {
        Write-Host "Source files count: $($sourceFiles.Count)" -ForegroundColor Magenta
    } else {
        Write-Host "Source files: No data" -ForegroundColor Magenta
    }
} catch {
    Write-Host "Error collecting source files: $($_.Exception.Message)" -ForegroundColor Red
    $sourceFiles = $null
}

Write-Host "Collecting files from target database..." -ForegroundColor Yellow
try {
    $targetFiles = Get-FileInfo -Server $TargetServer -Database $TargetDatabase
    Write-Host "Target files collected successfully" -ForegroundColor Green
    if ($targetFiles) {
        Write-Host "Target files count: $($targetFiles.Count)" -ForegroundColor Magenta
    } else {
        Write-Host "Target files: No data" -ForegroundColor Magenta
    }
} catch {
    Write-Host "Error collecting target files: $($_.Exception.Message)" -ForegroundColor Red
    $targetFiles = $null
}


# Collect VLF count
Write-Host "Collecting VLF count from source database..." -ForegroundColor Yellow
try {
    $sourceVLFCount = Get-VLFCount -Server $SourceServer -Database $SourceDatabase
    Write-Host "Source VLF count: $sourceVLFCount" -ForegroundColor Green
} catch {
    Write-Host "Error collecting source VLF count: $($_.Exception.Message)" -ForegroundColor Red
    $sourceVLFCount = 0
}

Write-Host "Collecting VLF count from target database..." -ForegroundColor Yellow
try {
    $targetVLFCount = Get-VLFCount -Server $TargetServer -Database $TargetDatabase
    Write-Host "Target VLF count: $targetVLFCount" -ForegroundColor Green
} catch {
    Write-Host "Error collecting target VLF count: $($_.Exception.Message)" -ForegroundColor Red
    $targetVLFCount = 0
}
# Collect users
Write-Host "Collecting users from source database..." -ForegroundColor Yellow
try {
    $sourceUsers = Get-UserInfo -Server $SourceServer -Database $SourceDatabase
    Write-Host "Source users collected successfully" -ForegroundColor Green
    if ($sourceUsers) {
        Write-Host "Source users count: $($sourceUsers.Count)" -ForegroundColor Magenta
    } else {
        Write-Host "Source users: No data" -ForegroundColor Magenta
    }
} catch {
    Write-Host "Error collecting source users: $($_.Exception.Message)" -ForegroundColor Red
    $sourceUsers = $null
}

Write-Host "Collecting users from target database..." -ForegroundColor Yellow
try {
    $targetUsers = Get-UserInfo -Server $TargetServer -Database $TargetDatabase
    Write-Host "Target users collected successfully" -ForegroundColor Green
    if ($targetUsers) {
        Write-Host "Target users count: $($targetUsers.Count)" -ForegroundColor Magenta
    } else {
        Write-Host "Target users: No data" -ForegroundColor Magenta
    }
} catch {
    Write-Host "Error collecting target users: $($_.Exception.Message)" -ForegroundColor Red
    $targetUsers = $null
}
# Collect roles
Write-Host "Collecting roles from source database..." -ForegroundColor Yellow
try {
    $sourceRoles = Get-RoleInfo -Server $SourceServer -Database $SourceDatabase
    Write-Host "Source roles collected successfully" -ForegroundColor Green
    if ($sourceRoles) {
        Write-Host "Source roles count: $($sourceRoles.Count)" -ForegroundColor Magenta
    } else {
        Write-Host "Source roles: No data" -ForegroundColor Magenta
    }
} catch {
    Write-Host "Error collecting source roles: $($_.Exception.Message)" -ForegroundColor Red
    $sourceRoles = $null
}

Write-Host "Collecting roles from target database..." -ForegroundColor Yellow
try {
    $targetRoles = Get-RoleInfo -Server $TargetServer -Database $TargetDatabase
    Write-Host "Target roles collected successfully" -ForegroundColor Green
    if ($targetRoles) {
        Write-Host "Target roles count: $($targetRoles.Count)" -ForegroundColor Magenta
    } else {
        Write-Host "Target roles: No data" -ForegroundColor Magenta
    }
} catch {
    Write-Host "Error collecting target roles: $($_.Exception.Message)" -ForegroundColor Red
    $targetRoles = $null
}

        # Collect database options as individual settings
        $sourceDatabaseOptionsRaw = Get-DatabaseOptions -Server $SourceServer -Database $SourceDatabase
        $targetDatabaseOptionsRaw = Get-DatabaseOptions -Server $TargetServer -Database $TargetDatabase
        
        # Collect advanced database options
        $sourceDatabaseAdvancedOptionsRaw = Get-DatabaseAdvancedOptions -Server $SourceServer -Database $SourceDatabase
        $targetDatabaseAdvancedOptionsRaw = Get-DatabaseAdvancedOptions -Server $TargetServer -Database $TargetDatabase
        
        # Collect database scoped configurations
        $sourceDatabaseScopedConfigs = Get-DatabaseScopedConfigurations -Server $SourceServer -Database $SourceDatabase
        $targetDatabaseScopedConfigs = Get-DatabaseScopedConfigurations -Server $TargetServer -Database $TargetDatabase
        
        # Convert to individual settings (keep as arrays, don't convert to DataTable)
        $sourceDatabaseOptions = @()
        $targetDatabaseOptions = @()
        
        if ($sourceDatabaseOptionsRaw) {
            $sourceRow = if ($sourceDatabaseOptionsRaw.GetType().Name -eq "DataTable") { $sourceDatabaseOptionsRaw.Rows[0] } else { $sourceDatabaseOptionsRaw }
            $sourceDatabaseOptions = Convert-DatabaseOptionsToIndividualSettings -DatabaseRow $sourceRow
        }
        
        if ($targetDatabaseOptionsRaw) {
            $targetRow = if ($targetDatabaseOptionsRaw.GetType().Name -eq "DataTable") { $targetDatabaseOptionsRaw.Rows[0] } else { $targetDatabaseOptionsRaw }
            $targetDatabaseOptions = Convert-DatabaseOptionsToIndividualSettings -DatabaseRow $targetRow
        }
        
        # Convert advanced options to individual settings
        if ($sourceDatabaseAdvancedOptionsRaw) {
            $sourceAdvancedRow = if ($sourceDatabaseAdvancedOptionsRaw.GetType().Name -eq "DataTable") { $sourceDatabaseAdvancedOptionsRaw.Rows[0] } else { $sourceDatabaseAdvancedOptionsRaw }
            $sourceAdvancedSettings = Convert-DatabaseOptionsToIndividualSettings -DatabaseRow $sourceAdvancedRow
            $sourceDatabaseOptions += $sourceAdvancedSettings
        }
        
        if ($targetDatabaseAdvancedOptionsRaw) {
            $targetAdvancedRow = if ($targetDatabaseAdvancedOptionsRaw.GetType().Name -eq "DataTable") { $targetDatabaseAdvancedOptionsRaw.Rows[0] } else { $targetDatabaseAdvancedOptionsRaw }
            $targetAdvancedSettings = Convert-DatabaseOptionsToIndividualSettings -DatabaseRow $targetAdvancedRow
            $targetDatabaseOptions += $targetAdvancedSettings
        }
        
        # Convert database scoped configurations to individual settings
        if ($sourceDatabaseScopedConfigs) {
            $sourceScopedTable = if ($sourceDatabaseScopedConfigs.GetType().Name -eq "DataTable") { $sourceDatabaseScopedConfigs } else { $sourceDatabaseScopedConfigs }
            $sourceScopedSettings = Convert-DatabaseScopedConfigurationsToIndividualSettings -ConfigurationsTable $sourceScopedTable
            $sourceDatabaseOptions += $sourceScopedSettings
        }
        
        if ($targetDatabaseScopedConfigs) {
            $targetScopedTable = if ($targetDatabaseScopedConfigs.GetType().Name -eq "DataTable") { $targetDatabaseScopedConfigs } else { $targetDatabaseScopedConfigs }
            $targetScopedSettings = Convert-DatabaseScopedConfigurationsToIndividualSettings -ConfigurationsTable $targetScopedTable
            $targetDatabaseOptions += $targetScopedSettings
        }

# Debug output for new sections will be moved after data collection

# Debug output
Write-Host "Source tables type: $($sourceTables.GetType().Name)" -ForegroundColor Magenta
Write-Host "Target tables type: $($targetTables.GetType().Name)" -ForegroundColor Magenta
if ($sourceTables) {
    Write-Host "Source tables count: $($sourceTables.Rows.Count)" -ForegroundColor Magenta
}
if ($targetTables) {
    Write-Host "Target tables count: $($targetTables.Rows.Count)" -ForegroundColor Magenta
}

Write-Host "Source columns type: $($sourceColumns.GetType().Name)" -ForegroundColor Magenta
Write-Host "Target columns type: $($targetColumns.GetType().Name)" -ForegroundColor Magenta
if ($sourceColumns) {
    Write-Host "Source columns count: $($sourceColumns.Rows.Count)" -ForegroundColor Magenta
}
if ($targetColumns) {
    Write-Host "Target columns count: $($targetColumns.Rows.Count)" -ForegroundColor Magenta
}

Write-Host "Source indexes type: $($sourceIndexes.GetType().Name)" -ForegroundColor Magenta
Write-Host "Target indexes type: $($targetIndexes.GetType().Name)" -ForegroundColor Magenta
if ($sourceIndexes) {
    Write-Host "Source indexes count: $($sourceIndexes.Rows.Count)" -ForegroundColor Magenta
}
if ($targetIndexes) {
    Write-Host "Target indexes count: $($targetIndexes.Rows.Count)" -ForegroundColor Magenta
}

Write-Host "Source functions type: $($sourceFunctions.GetType().Name)" -ForegroundColor Magenta
Write-Host "Target functions type: $($targetFunctions.GetType().Name)" -ForegroundColor Magenta
if ($sourceFunctions) {
    Write-Host "Source functions count: $($sourceFunctions.Rows.Count)" -ForegroundColor Magenta
}
if ($targetFunctions) {
    Write-Host "Target functions count: $($targetFunctions.Rows.Count)" -ForegroundColor Magenta
}

Write-Host "Source procedures type: $($sourceProcedures.GetType().Name)" -ForegroundColor Magenta
Write-Host "Target procedures type: $($targetProcedures.GetType().Name)" -ForegroundColor Magenta
if ($sourceProcedures) {
    Write-Host "Source procedures count: $($sourceProcedures.Rows.Count)" -ForegroundColor Magenta
}
if ($targetProcedures) {
    Write-Host "Target procedures count: $($targetProcedures.Rows.Count)" -ForegroundColor Magenta
}

Write-Host "Source data types type: $($sourceDataTypes.GetType().Name)" -ForegroundColor Magenta
Write-Host "Target data types type: $($targetDataTypes.GetType().Name)" -ForegroundColor Magenta
if ($sourceDataTypes) {
    Write-Host "Source data types count: $($sourceDataTypes.Rows.Count)" -ForegroundColor Magenta
}
if ($targetDataTypes) {
    Write-Host "Target data types count: $($targetDataTypes.Rows.Count)" -ForegroundColor Magenta
}

# Debug output for new sections
if ($sourceConstraints -and $sourceConstraints.Rows.Count -gt 0) {
    Write-Host "Source constraints count: $($sourceConstraints.Rows.Count)" -ForegroundColor Magenta
} else {
    Write-Host "Source constraints: No data" -ForegroundColor Magenta
}
if ($targetConstraints -and $targetConstraints.Rows.Count -gt 0) {
    Write-Host "Target constraints count: $($targetConstraints.Rows.Count)" -ForegroundColor Magenta
} else {
    Write-Host "Target constraints: No data" -ForegroundColor Magenta
}
if ($sourceViews -and $sourceViews.Rows.Count -gt 0) {
    Write-Host "Source views count: $($sourceViews.Rows.Count)" -ForegroundColor Magenta
} else {
    Write-Host "Source views: No data" -ForegroundColor Magenta
}
if ($targetViews -and $targetViews.Rows.Count -gt 0) {
    Write-Host "Target views count: $($targetViews.Rows.Count)" -ForegroundColor Magenta
} else {
    Write-Host "Target views: No data" -ForegroundColor Magenta
}
if ($sourceSynonyms) {
    if ($sourceSynonyms.GetType().Name -eq "DataTable") {
        $count = $sourceSynonyms.Rows.Count
    } else {
        $count = 1
    }
    if ($count -gt 0) {
        Write-Host "Source synonyms count: $count" -ForegroundColor Magenta
    } else {
        Write-Host "Source synonyms: No data" -ForegroundColor Magenta
    }
} else {
    Write-Host "Source synonyms: No data" -ForegroundColor Magenta
}
if ($targetSynonyms) {
    if ($targetSynonyms.GetType().Name -eq "DataTable") {
        $count = $targetSynonyms.Rows.Count
    } else {
        $count = 1
    }
    if ($count -gt 0) {
        Write-Host "Target synonyms count: $count" -ForegroundColor Magenta
    } else {
        Write-Host "Target synonyms: No data" -ForegroundColor Magenta
    }
} else {
    Write-Host "Target synonyms: No data" -ForegroundColor Magenta
}
if ($sourceTableTriggers) {
    if ($sourceTableTriggers.GetType().Name -eq "DataTable") {
        $count = $sourceTableTriggers.Rows.Count
    } else {
        $count = 1
    }
    if ($count -gt 0) {
        Write-Host "Source table triggers count: $count" -ForegroundColor Magenta
    } else {
        Write-Host "Source table triggers: No data" -ForegroundColor Magenta
    }
} else {
    Write-Host "Source table triggers: No data" -ForegroundColor Magenta
}
if ($targetTableTriggers) {
    if ($targetTableTriggers.GetType().Name -eq "DataTable") {
        $count = $targetTableTriggers.Rows.Count
    } else {
        $count = 1
    }
    if ($count -gt 0) {
        Write-Host "Target table triggers count: $count" -ForegroundColor Magenta
    } else {
        Write-Host "Target table triggers: No data" -ForegroundColor Magenta
    }
} else {
    Write-Host "Target table triggers: No data" -ForegroundColor Magenta
}
if ($sourceDatabaseTriggers) {
    if ($sourceDatabaseTriggers.GetType().Name -eq "DataTable") {
        $count = $sourceDatabaseTriggers.Rows.Count
    } else {
        $count = 1
    }
    if ($count -gt 0) {
        Write-Host "Source database triggers count: $count" -ForegroundColor Magenta
    } else {
        Write-Host "Source database triggers: No data" -ForegroundColor Magenta
    }
} else {
    Write-Host "Source database triggers: No data" -ForegroundColor Magenta
}
if ($targetDatabaseTriggers) {
    if ($targetDatabaseTriggers.GetType().Name -eq "DataTable") {
        $count = $targetDatabaseTriggers.Rows.Count
    } else {
        $count = 1
    }
    if ($count -gt 0) {
        Write-Host "Target database triggers count: $count" -ForegroundColor Magenta
    } else {
        Write-Host "Target database triggers: No data" -ForegroundColor Magenta
    }
} else {
    Write-Host "Target database triggers: No data" -ForegroundColor Magenta
}
if ($sourceKeys) {
    if ($sourceKeys.GetType().Name -eq "DataTable") {
        $count = $sourceKeys.Rows.Count
    } else {
        $count = 1
    }
    if ($count -gt 0) {
        Write-Host "Source keys count: $count" -ForegroundColor Magenta
    } else {
        Write-Host "Source keys: No data" -ForegroundColor Magenta
    }
} else {
    Write-Host "Source keys: No data" -ForegroundColor Magenta
}
if ($targetKeys) {
    $count = $targetKeys.Count
    if ($count -gt 0) {
        Write-Host "Target keys count: $count" -ForegroundColor Magenta
    } else {
        Write-Host "Target keys: No data" -ForegroundColor Magenta
    }
} else {
    Write-Host "Target keys: No data" -ForegroundColor Magenta
}
if ($sourceDatabaseOptions) {
    $count = $sourceDatabaseOptions.Count
    if ($count -gt 0) {
        Write-Host "Source database option settings count: $count" -ForegroundColor Magenta
    } else {
        Write-Host "Source database option settings: No data" -ForegroundColor Magenta
    }
} else {
    Write-Host "Source database option settings: No data" -ForegroundColor Magenta
}
if ($targetDatabaseOptions) {
    $count = $targetDatabaseOptions.Count
    if ($count -gt 0) {
        Write-Host "Target database option settings count: $count" -ForegroundColor Magenta
    } else {
        Write-Host "Target database option settings: No data" -ForegroundColor Magenta
    }
} else {
    Write-Host "Target database option settings: No data" -ForegroundColor Magenta
}

# Note: $targetDataTypes is already collected earlier in the script, this line is redundant but kept for safety
$targetDataTypes = Get-DataTypeInfo -Server $TargetServer -Database $TargetDatabase

# Perform comparisons
Write-Host "`nPerforming comparisons..." -ForegroundColor Yellow

# Compare tables and columns
if ($sourceTables -and $targetTables) {
    Write-Host "Comparing tables..." -ForegroundColor Yellow
$global:ComparisonData.Tables = Compare-Datasets -Source $sourceTables -Target $targetTables -KeyColumns "TABLE_SCHEMA,TABLE_NAME" -IgnoreColumns "create_date,modify_date,ROW_COUNT"
    
    Write-Host "Table comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.Tables.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.Tables.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.Tables.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.Tables.Differences.Count)" -ForegroundColor Red
    
    Write-Host "Tables comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target tables data is missing" -ForegroundColor Yellow
    $global:ComparisonData.Tables = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}

if ($sourceColumns -and $targetColumns) {
    Write-Host "Comparing columns..." -ForegroundColor Yellow
$global:ComparisonData.Columns = Compare-Datasets -Source $sourceColumns -Target $targetColumns -KeyColumns "TABLE_SCHEMA,TABLE_NAME,COLUMN_NAME"
    
    Write-Host "Column comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.Columns.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.Columns.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.Columns.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.Columns.Differences.Count)" -ForegroundColor Red
    
    if ($global:ComparisonData.Columns.Differences.Count -gt 0) {
        Write-Host "Columns with differences:" -ForegroundColor Red
        foreach ($diff in $global:ComparisonData.Columns.Differences) {
            Write-Host "  - $($diff.Key)" -ForegroundColor Red
            if ($diff.Key -like "*Salary*") {
                Write-Host "    SALARY DEBUG - Source Data:" -ForegroundColor Cyan
                $diff.Source | Format-List | Out-String | Write-Host -ForegroundColor Cyan
                Write-Host "    SALARY DEBUG - Target Data:" -ForegroundColor Cyan
                $diff.Target | Format-List | Out-String | Write-Host -ForegroundColor Cyan
                Write-Host "    SALARY DEBUG - Differences:" -ForegroundColor Cyan
                $diff.Differences | Format-List | Out-String | Write-Host -ForegroundColor Cyan
            }
        }
    }
    
    Write-Host "Columns comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target columns data is missing" -ForegroundColor Yellow
    $global:ComparisonData.Columns = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}

# Compare indexes
if ($sourceIndexes -and $targetIndexes) {
    Write-Host "Comparing indexes..." -ForegroundColor Yellow
$global:ComparisonData.Indexes = Compare-Datasets -Source $sourceIndexes -Target $targetIndexes -KeyColumns "SCHEMA_NAME,TABLE_NAME,INDEX_NAME"
    
    Write-Host "Index comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.Indexes.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.Indexes.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.Indexes.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.Indexes.Differences.Count)" -ForegroundColor Red
    
    Write-Host "Indexes comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target indexes data is missing" -ForegroundColor Yellow
    $global:ComparisonData.Indexes = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}

# Compare schemas
if ($sourceSchemas -or $targetSchemas) {
    Write-Host "Comparing schemas..." -ForegroundColor Yellow
    $global:ComparisonData.Schemas = Compare-Datasets -Source $sourceSchemas -Target $targetSchemas -KeyColumns "SCHEMA_NAME"
    Write-Host "Schemas comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.Schemas.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.Schemas.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.Schemas.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.Schemas.Differences.Count)" -ForegroundColor Red
} else {
    Write-Host "Warning: Schemas data missing on source/target" -ForegroundColor Yellow
    $global:ComparisonData.Schemas = @{ Matches=@(); SourceOnly=@(); TargetOnly=@(); Differences=@() }
}
# Compare functions
if ($sourceFunctions -and $targetFunctions) {
    Write-Host "Comparing functions..." -ForegroundColor Yellow
$global:ComparisonData.Functions = Compare-Datasets -Source $sourceFunctions -Target $targetFunctions -KeyColumns "SCHEMA_NAME,FUNCTION_NAME" -IgnoreColumns "create_date,modify_date"
    
    Write-Host "Function comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.Functions.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.Functions.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.Functions.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.Functions.Differences.Count)" -ForegroundColor Red
    
    Write-Host "Functions comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target functions data is missing" -ForegroundColor Yellow
    $global:ComparisonData.Functions = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}

# Compare stored procedures
if ($sourceProcedures -and $targetProcedures) {
    Write-Host "Comparing stored procedures..." -ForegroundColor Yellow
$global:ComparisonData.StoredProcedures = Compare-Datasets -Source $sourceProcedures -Target $targetProcedures -KeyColumns "SCHEMA_NAME,PROCEDURE_NAME" -IgnoreColumns "create_date,modify_date"
    
    Write-Host "Stored procedure comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.StoredProcedures.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.StoredProcedures.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.StoredProcedures.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.StoredProcedures.Differences.Count)" -ForegroundColor Red
    
    Write-Host "Stored procedures comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target stored procedures data is missing" -ForegroundColor Yellow
    $global:ComparisonData.StoredProcedures = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}

if ($sourceDataTypes -and $targetDataTypes) {
    Write-Host "Comparing data types..." -ForegroundColor Yellow
$global:ComparisonData.DataTypes = Compare-Datasets -Source $sourceDataTypes -Target $targetDataTypes -KeyColumns "SCHEMA_NAME,TYPE_NAME"
    
    Write-Host "Data type comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.DataTypes.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.DataTypes.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.DataTypes.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.DataTypes.Differences.Count)" -ForegroundColor Red
    
    Write-Host "Data types comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target data types data is missing" -ForegroundColor Yellow
    $global:ComparisonData.DataTypes = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}

# Compare constraints
if ($sourceConstraints -and $targetConstraints) {
    Write-Host "Comparing constraints..." -ForegroundColor Yellow
    $global:ComparisonData.Constraints = Compare-Datasets -Source $sourceConstraints -Target $targetConstraints -KeyColumns "SCHEMA_NAME,TABLE_NAME,CONSTRAINT_NAME"
    
    Write-Host "Constraint comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.Constraints.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.Constraints.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.Constraints.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.Constraints.Differences.Count)" -ForegroundColor Red
    
    Write-Host "Constraints comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target constraints data is missing" -ForegroundColor Yellow
    $global:ComparisonData.Constraints = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}

# Compare views
if ($sourceViews -and $targetViews) {
    Write-Host "Comparing views..." -ForegroundColor Yellow
    $global:ComparisonData.Views = Compare-Datasets -Source $sourceViews -Target $targetViews -KeyColumns "SCHEMA_NAME,VIEW_NAME" -IgnoreColumns "create_date,modify_date"
    
    Write-Host "View comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.Views.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.Views.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.Views.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.Views.Differences.Count)" -ForegroundColor Red
    
    Write-Host "Views comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target views data is missing" -ForegroundColor Yellow
    $global:ComparisonData.Views = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}

# Compare synonyms
if ($sourceSynonyms -or $targetSynonyms) {
    Write-Host "Comparing synonyms..." -ForegroundColor Yellow
    $global:ComparisonData.Synonyms = Compare-Datasets -Source $sourceSynonyms -Target $targetSynonyms -KeyColumns "SCHEMA_NAME,SYNONYM_NAME"
    
    Write-Host "Synonym comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.Synonyms.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.Synonyms.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.Synonyms.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.Synonyms.Differences.Count)" -ForegroundColor Red
    
    Write-Host "Synonyms comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target synonyms data is missing" -ForegroundColor Yellow
    $global:ComparisonData.Synonyms = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}

# Compare table triggers
if ($sourceTableTriggers -or $targetTableTriggers) {
    Write-Host "Comparing table triggers..." -ForegroundColor Yellow
    $global:ComparisonData.TableTriggers = Compare-Datasets -Source $sourceTableTriggers -Target $targetTableTriggers -KeyColumns "SCHEMA_NAME,TABLE_NAME,TRIGGER_NAME" -IgnoreColumns "create_date,modify_date"
    
    Write-Host "Table trigger comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.TableTriggers.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.TableTriggers.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.TableTriggers.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.TableTriggers.Differences.Count)" -ForegroundColor Red
    
    Write-Host "Table triggers comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target table triggers data is missing" -ForegroundColor Yellow
    $global:ComparisonData.TableTriggers = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}

# Compare database triggers
if ($sourceDatabaseTriggers -or $targetDatabaseTriggers) {
    Write-Host "Comparing database triggers..." -ForegroundColor Yellow
    $global:ComparisonData.DatabaseTriggers = Compare-Datasets -Source $sourceDatabaseTriggers -Target $targetDatabaseTriggers -KeyColumns "TRIGGER_NAME" -IgnoreColumns "create_date,modify_date"
    
    Write-Host "Database trigger comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.DatabaseTriggers.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.DatabaseTriggers.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.DatabaseTriggers.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.DatabaseTriggers.Differences.Count)" -ForegroundColor Red
    
    Write-Host "Database triggers comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target database triggers data is missing" -ForegroundColor Yellow
    $global:ComparisonData.DatabaseTriggers = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}
# Compare keys
if ($sourceKeys -or $targetKeys) {
    Write-Host "Comparing keys..." -ForegroundColor Yellow
    
    $global:ComparisonData.Keys = Compare-Datasets -Source $sourceKeys -Target $targetKeys -KeyColumns "SCHEMA_NAME,TABLE_NAME,KEY_NAME"
    
    Write-Host "Key comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.Keys.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.Keys.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.Keys.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.Keys.Differences.Count)" -ForegroundColor Red
    
    Write-Host "Keys comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target keys data is missing" -ForegroundColor Yellow
    $global:ComparisonData.Keys = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}
# Compare VLF counts
Write-Host "Comparing VLF counts..." -ForegroundColor Yellow

if ($sourceVLFCount -eq $targetVLFCount) {
    $global:ComparisonData.VLF = @{
        Matches = @([PSCustomObject]@{
            VLF_COUNT = $sourceVLFCount
            DATABASE_NAME = "VLF Count Comparison"
        })
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
    Write-Host "VLF counts match: $sourceVLFCount" -ForegroundColor Green
} else {
    $global:ComparisonData.VLF = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @([PSCustomObject]@{
            Source = [PSCustomObject]@{
                VLF_COUNT = $sourceVLFCount
                DATABASE_NAME = $SourceDatabase
            }
            Target = [PSCustomObject]@{
                VLF_COUNT = $targetVLFCount
                DATABASE_NAME = $TargetDatabase
            }
        })
    }
    Write-Host "VLF counts differ - Source: $sourceVLFCount, Target: $targetVLFCount" -ForegroundColor Red
}

Write-Host "VLF comparison completed successfully!" -ForegroundColor Green

# Compare files
if ($sourceFiles -or $targetFiles) {
    Write-Host "Comparing files..." -ForegroundColor Yellow
    
    # Use standard comparison - files should show as Source Only and Target Only since file names will always be different
    $fileComparisonResults = Compare-Datasets -Source $sourceFiles -Target $targetFiles -KeyColumns "name,file_id"
    
    $global:ComparisonData.FileInfo = $fileComparisonResults
    
    Write-Host "File comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.FileInfo.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.FileInfo.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.FileInfo.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.FileInfo.Differences.Count)" -ForegroundColor Red
    
    
    Write-Host "Files comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target files data is missing" -ForegroundColor Yellow
    $global:ComparisonData.FileInfo = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}

# Compare VLF counts
Write-Host "Comparing VLF counts..." -ForegroundColor Yellow

# Always show individual VLF counts for each database
$global:ComparisonData.VLF = @{
    Matches = @()
    SourceOnly = @([PSCustomObject]@{
        VLF_COUNT = $sourceVLFCount
        DATABASE_NAME = $SourceDatabase
        COMPARISON_TYPE = "Source Database"
    })
    TargetOnly = @([PSCustomObject]@{
        VLF_COUNT = $targetVLFCount
        DATABASE_NAME = $TargetDatabase
        COMPARISON_TYPE = "Target Database"
    })
    Differences = @()
}

if ($sourceVLFCount -eq $targetVLFCount) {
    Write-Host "VLF counts match: Source=$sourceVLFCount, Target=$targetVLFCount" -ForegroundColor Green
} else {
    Write-Host "VLF counts differ: Source=$sourceVLFCount, Target=$targetVLFCount" -ForegroundColor Red
}

Write-Host "VLF comparison completed successfully!" -ForegroundColor Green

# Compare users
if ($sourceUsers -or $targetUsers) {
    Write-Host "Comparing users..." -ForegroundColor Yellow
    
    $userComparisonResults = Compare-Datasets -Source $sourceUsers -Target $targetUsers -KeyColumns "USER_NAME" -IgnoreColumns "create_date,modify_date"
    
    $global:ComparisonData.Users = $userComparisonResults
    
    Write-Host "User comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.Users.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.Users.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.Users.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.Users.Differences.Count)" -ForegroundColor Red
    
    Write-Host "Users comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target users data is missing" -ForegroundColor Yellow
    $global:ComparisonData.Users = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}

# Compare roles
if ($sourceRoles -or $targetRoles) {
    Write-Host "Comparing roles..." -ForegroundColor Yellow
    
    $roleComparisonResults = Compare-Datasets -Source $sourceRoles -Target $targetRoles -KeyColumns "ROLE_NAME" -IgnoreColumns "create_date,modify_date"
    
    $global:ComparisonData.Roles = $roleComparisonResults
    
    Write-Host "Role comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.Roles.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.Roles.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.Roles.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.Roles.Differences.Count)" -ForegroundColor Red
    
    Write-Host "Roles comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target roles data is missing" -ForegroundColor Yellow
    $global:ComparisonData.Roles = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}

# Compare Query Store configuration and forced plans (by ITEM_TYPE,OBJECT_NAME)
Write-Host "Comparing Query Store configuration and forced plans..." -ForegroundColor Yellow
$global:ComparisonData.QueryStore = Compare-Datasets -Source $sourceQueryStore -Target $targetQueryStore -KeyColumns "ITEM_TYPE,OBJECT_NAME"
    Write-Host "Query Store comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.QueryStore.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.QueryStore.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.QueryStore.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.QueryStore.Differences.Count)" -ForegroundColor Red
# Compare database options (individual settings)
if ($sourceDatabaseOptions -or $targetDatabaseOptions) {
    Write-Host "Comparing database option settings..." -ForegroundColor Yellow
    
    # Custom comparison for database option settings - compare only OPTION_VALUE, not SQL_COMMAND
    $global:ComparisonData.DatabaseOptions = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
    if ($sourceDatabaseOptions -and $targetDatabaseOptions) {
        # Create lookup tables for both source and target
        $sourceLookup = @{}
        $targetLookup = @{}
        
        foreach ($row in $sourceDatabaseOptions) {
            $sourceLookup[$row.OPTION_NAME] = $row
        }
        
        foreach ($row in $targetDatabaseOptions) {
            $targetLookup[$row.OPTION_NAME] = $row
        }
        
        # Get all unique option names
        $allOptionNames = ($sourceLookup.Keys + $targetLookup.Keys) | Sort-Object | Get-Unique
        
        foreach ($optionName in $allOptionNames) {
            $sourceRow = $sourceLookup[$optionName]
            $targetRow = $targetLookup[$optionName]
            
            if ($sourceRow -and $targetRow) {
                # Both exist - compare OPTION_VALUE only
                if ($sourceRow.OPTION_VALUE -eq $targetRow.OPTION_VALUE) {
                    # Values match
                    $global:ComparisonData.DatabaseOptions.Matches += @{
                        Source = $sourceRow
                        Target = $targetRow
                    }
                } else {
                    # Values differ
                    $global:ComparisonData.DatabaseOptions.Differences += @{
                        Source = $sourceRow
                        Target = $targetRow
                    }
                }
            } elseif ($sourceRow) {
                # Only source exists
                $global:ComparisonData.DatabaseOptions.SourceOnly += $sourceRow
            } elseif ($targetRow) {
                # Only target exists
                $global:ComparisonData.DatabaseOptions.TargetOnly += $targetRow
            }
        }
    } elseif ($sourceDatabaseOptions) {
        # Only source exists
        foreach ($row in $sourceDatabaseOptions) {
            $global:ComparisonData.DatabaseOptions.SourceOnly += $row
        }
    } elseif ($targetDatabaseOptions) {
        # Only target exists
        foreach ($row in $targetDatabaseOptions) {
            $global:ComparisonData.DatabaseOptions.TargetOnly += $row
        }
    }
    
    Write-Host "Database option settings comparison results:" -ForegroundColor Cyan
    Write-Host "  Matches: $($global:ComparisonData.DatabaseOptions.Matches.Count)" -ForegroundColor Green
    Write-Host "  Source Only: $($global:ComparisonData.DatabaseOptions.SourceOnly.Count)" -ForegroundColor Yellow
    Write-Host "  Target Only: $($global:ComparisonData.DatabaseOptions.TargetOnly.Count)" -ForegroundColor Blue
    Write-Host "  Differences: $($global:ComparisonData.DatabaseOptions.Differences.Count)" -ForegroundColor Red
    
    # Debug: Show which option is different
    if ($global:ComparisonData.DatabaseOptions.Differences.Count -gt 0) {
        Write-Host "  Different options:" -ForegroundColor Red
        foreach ($diff in $global:ComparisonData.DatabaseOptions.Differences) {
            $optionName = $diff.Source.OPTION_NAME
            $sourceValue = $diff.Source.OPTION_VALUE
            $targetValue = $diff.Target.OPTION_VALUE
            Write-Host "    $optionName : Source='$sourceValue' vs Target='$targetValue'" -ForegroundColor Red
        }
    }
    
    Write-Host "Database option settings comparison completed successfully!" -ForegroundColor Green
} else {
    Write-Host "Warning: Source or target database option settings data is missing" -ForegroundColor Yellow
    $global:ComparisonData.DatabaseOptions = @{
        Matches = @()
        SourceOnly = @()
        TargetOnly = @()
        Differences = @()
    }
}


# Generate HTML report (skip if Excel-only export)
if (-not $ExportExcel) {
    Write-Host "`nGenerating HTML report..." -ForegroundColor Yellow
    $htmlReport = New-HTMLReport -SourceServer $SourceServer -SourceDatabase $SourceDatabase -TargetServer $TargetServer -TargetDatabase $TargetDatabase -OutputPath $OutputPath

    # Ensure sort buttons work even if primary scripts fail to bind (single-page fallback)
    $singlePageFallback = @"

<script>
(function(){
  function titleOf(card){
    var h = card && card.querySelector && card.querySelector('.summary-header h3');
    return (h && h.textContent ? h.textContent : '').toLowerCase();
  }
  function animateReorder(container, newOrder){
    if(!container) return;
    var D=500, easing='cubic-bezier(0.16, 1, 0.3, 1)';
    var rects=new Map();
    Array.prototype.forEach.call(container.children,function(el){
      if(!(el instanceof HTMLElement)) return; rects.set(el, el.getBoundingClientRect());
    });
    // Build fragment for new order
    var frag=document.createDocumentFragment(); newOrder.forEach(function(el){ frag.appendChild(el); });
    container.appendChild(frag);
    // Play FLIP
    newOrder.forEach(function(el){
      if(!(el instanceof HTMLElement)) return; var first=rects.get(el); var last=el.getBoundingClientRect();
      if(!first) return; var dx=first.left-last.left, dy=first.top-last.top;
      el.style.transform='translate('+dx+'px,'+dy+'px)'; el.style.transition='none';
      requestAnimationFrame(function(){
        el.style.transition='transform '+D+'ms '+easing+', opacity '+D+'ms '+easing;
        el.style.transform='translate(0,0)';
      });
    });
    setTimeout(function(){ newOrder.forEach(function(el){ el.style.transition=''; el.style.transform=''; }); }, D+20);
  }
  if (!window.sortAlphaAndSections){
    window.sortAlphaAndSections = function(){
      var c = document.getElementById('summaryCards');
      if(!c) return;
      var arr = Array.prototype.slice.call(c.getElementsByClassName('summary-card'));
      arr.sort(function(a,b){ return titleOf(a).localeCompare(titleOf(b)); });
      animateReorder(c, arr);
      // Also alphabetize sections if present
      var sec = document.getElementById('sectionsContainer');
      if (sec){
        var sections = Array.prototype.slice.call(sec.querySelectorAll('.section'));
        sections.sort(function(a,b){
          var at=(a.querySelector('.section-header h2')||{}).textContent||''; at=at.toLowerCase();
          var bt=(b.querySelector('.section-header h2')||{}).textContent||''; bt=bt.toLowerCase();
          return at.localeCompare(bt);
        });
        animateReorder(sec, sections);
      }
    }
  }
  if (!window.sortCategoryAndSections){
    window.sortCategoryAndSections = function(){
      var weights = { 'schemas':1,'tables':1,'columns':1,'indexes':1,'functions':1,'stored procedures':1,'stored-procedures':1,'views':1,'synonyms':1,'constraints':1,'keys':1,'table triggers':1,'database triggers':1,'query store':2,'vlf information':2,'database options':3,'file information':3,'users':3,'roles':3,'external resources':3,'data types':3 };
      var c = document.getElementById('summaryCards'); if(!c) return;
      var arr = Array.prototype.slice.call(c.getElementsByClassName('summary-card'));
      arr.sort(function(a,b){
        var at = titleOf(a), bt = titleOf(b);
        var aw = (weights[at]!==undefined?weights[at]:99), bw = (weights[bt]!==undefined?weights[bt]:99);
        if (aw !== bw) return aw - bw; return at.localeCompare(bt);
      });
      animateReorder(c, arr);
      // Reorder sections by weight then A–Z
      var sec = document.getElementById('sectionsContainer');
      if (sec){
        var sections = Array.prototype.slice.call(sec.querySelectorAll('.section'));
        sections.sort(function(a,b){
          var aw = +(a.getAttribute('data-category-weight')||99);
          var bw = +(b.getAttribute('data-category-weight')||99);
          if (aw!==bw) return aw-bw;
          var at=(a.querySelector('.section-header h2')||{}).textContent||''; at=at.toLowerCase();
          var bt=(b.querySelector('.section-header h2')||{}).textContent||''; bt=bt.toLowerCase();
          return at.localeCompare(bt);
        });
        animateReorder(sec, sections);
      }
    }
  }
})();
</script>
"@
    $htmlReport = $htmlReport -replace '</body>', ($singlePageFallback + '</body>')
}

# Save report
if ($ExportExcel) {
    # Excel export: Direct export using ImportExcel module (no browser, no HTML)
    Write-Host "`nExcel Export Mode: Creating Excel file directly from memory..." -ForegroundColor Yellow
    
    # Check if ImportExcel module is available
    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        Write-Host "ERROR: ImportExcel module not found!" -ForegroundColor Red
        Write-Host "Installing ImportExcel module..." -ForegroundColor Yellow
        Install-Module -Name ImportExcel -Scope CurrentUser -Force -AllowClobber
    }
    
    Import-Module ImportExcel -ErrorAction Stop
    
    # Track used sheet names to avoid collisions and reserved names
    $usedSheetNames = New-Object System.Collections.Generic.HashSet[string]
    function Get-SafeSheetName {
        param([string]$name)
        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Sheet' }
        # Avoid problematic/reserved names
        $reserved = @('Columns','Rows','Names')
        if ($reserved -contains $name) { $name = "$name`Sheet" }
        # Replace invalid chars and trim length
        $safe = ($name -replace '[:\\/\?\*\[\]]', '_')
        if ($safe.Length -gt 31) { $safe = $safe.Substring(0,31) }
        # Ensure uniqueness by appending (n)
        $base = $safe
        $n = 1
        while ($usedSheetNames.Contains($safe)) {
            $suffix = " ($n)"
            $maxBaseLen = 31 - $suffix.Length
            if ($base.Length -gt $maxBaseLen) { $safe = $base.Substring(0,$maxBaseLen) + $suffix } else { $safe = $base + $suffix }
            $n++
        }
        $usedSheetNames.Add($safe) | Out-Null
        return $safe
    }

    # Helpers: normalize complex objects for clean Excel output
    function Clean-ExcelString {
        param([string]$s)
        if ($null -eq $s) { return "" }
        # Remove control chars not allowed in XML (except TAB, LF, CR)
        return ([regex]::Replace([string]$s, "[\x00-\x08\x0B\x0C\x0E-\x1F]", ""))
    }
    function Convert-ToPlainValue {
        param(
            $value,
            [int]$depth = 0,
            [int]$maxDepth = 2
        )
        if ($null -eq $value) { return "" }
        if ($value -is [string]) { return (Clean-ExcelString $value) }
        if ($value -is [bool]) { 
            if ($value) { return "TRUE" } else { return "FALSE" }
        }
        if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) { return $value }
        if ($value -is [datetime]) { return $value.ToString("yyyy-MM-dd HH:mm:ss") }
        if ($depth -ge $maxDepth) { return ($value.ToString()) }
        # Limit size for sequences to avoid hangs
        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            $limit = 50
            $arr = @()
            $count = 0
            foreach ($i in $value) {
                $arr += (Convert-ToPlainValue -value $i -depth ($depth + 1) -maxDepth $maxDepth)
                $count++
                if ($count -ge $limit) { break }
            }
            $suffix = if ($count -ge $limit) { " ..." } else { "" }
            return (($arr -join ", ") + $suffix)
        }
        # For dictionaries or complex PSObjects, summarize key properties instead of full JSON
        if ($value -is [System.Collections.IDictionary]) {
            $pairs = @()
            $i = 0
            foreach ($k in $value.Keys) {
                $pairs += ("" + $k + "=" + (Convert-ToPlainValue -value $value[$k] -depth ($depth + 1) -maxDepth $maxDepth))
                $i++
                if ($i -ge 20) { break }
            }
            return ($pairs -join "; ")
        }
        $props = $value.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' -or $_.MemberType -eq 'Property' }
        if ($props.Count -gt 0) {
            $pairs = @()
            $i = 0
            foreach ($p in $props) {
                $pairs += ("" + $p.Name + "=" + (Convert-ToPlainValue -value $p.Value -depth ($depth + 1) -maxDepth $maxDepth))
                $i++
                if ($i -ge 20) { break }
            }
            $s = ($pairs -join "; ")
            if ($s.Length -gt 32000) { return ($s.Substring(0,32000) + "... [TRUNCATED]") }
            return $s
        }
        return (Clean-ExcelString ($value.ToString()))
    }
    function Ensure-Worksheet {
        param(
            [string]$Path,
            [string]$WorksheetName,
            [string[]]$Headers
        )
        # Try via ImportExcel package APIs if available
        try {
            $openCmd = Get-Command Open-ExcelPackage -ErrorAction SilentlyContinue
            $addCmd = Get-Command Add-Worksheet -ErrorAction SilentlyContinue
            $saveCmd = Get-Command Save-ExcelPackage -ErrorAction SilentlyContinue
            $closeCmd = Get-Command Close-ExcelPackage -ErrorAction SilentlyContinue
            if ($openCmd -and $addCmd -and $saveCmd) {
                $pkg = Open-ExcelPackage -Path $Path
                if (-not ($pkg.Workbook.Worksheets[$WorksheetName])) {
                    Add-Worksheet -ExcelPackage $pkg -WorksheetName $WorksheetName | Out-Null
                    Save-ExcelPackage -ExcelPackage $pkg
                }
                if ($closeCmd) { Close-ExcelPackage $pkg }
                return $true
            }
        } catch { }

        # Fallback: create sheet by exporting a header-only object
        try {
            if (-not $Headers -or $Headers.Count -eq 0) { $Headers = @('__init__') }
            $obj = [PSCustomObject]@{}
            foreach ($h in $Headers) { $obj | Add-Member -NotePropertyName $h -NotePropertyValue '' -Force }
            $null = ($obj | Export-Excel -Path $Path -WorksheetName $WorksheetName -Append)
            return $true
        } catch {
            return $false
        }
    }

    function Normalize-ItemForExcel {
        param($item)
        $result = [ordered]@{}
        foreach ($prop in $item.PSObject.Properties) {
            $name = [string]$prop.Name
            $val = $prop.Value
            $result[$name] = Convert-ToPlainValue -value $val -depth 0 -maxDepth 2
        }
        return [PSCustomObject]$result
    }
    
    # Timestamp for unique filename
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $excelPath = "SchemaComparisonReport_$timestamp.xlsx"
    $fullPath = Join-Path (Get-Location) $excelPath

    # We'll build a single Excel package and add all sheets to it using -PassThru
    if (Test-Path $fullPath) { Remove-Item $fullPath -Force }
    $excelPackage = $null
    
    Write-Host "Step 1: Creating Summary sheet..." -ForegroundColor Cyan
    
    # Define categories
    $allCategories = @('Tables', 'Columns', 'Indexes', 'Functions', 'StoredProcedures', 'DataTypes', 
                      'Constraints', 'Views', 'Synonyms', 'TableTriggers', 'DatabaseTriggers', 
                      'Keys', 'DatabaseOptions', 'FileInfo', 'Compatibility', 'Collation', 'VLF', 'Users', 'Roles', 'Schemas')
    
    # Build summary data
    $summaryData = @()
    foreach ($categoryName in $allCategories) {
        $categoryData = $global:ComparisonData.$categoryName
        if ($categoryData) {
            $matchCount = 0
            if ($categoryData.Matches) { $matchCount = $categoryData.Matches.Count }
            $diffCount = 0
            if ($categoryData.Differences) { $diffCount = $categoryData.Differences.Count }
            $sourceCount = 0
            if ($categoryData.SourceOnly) { $sourceCount = $categoryData.SourceOnly.Count }
            $targetCount = 0
            if ($categoryData.TargetOnly) { $targetCount = $categoryData.TargetOnly.Count }
            $totalCount = $matchCount + $diffCount + $sourceCount + $targetCount
            
            if ($totalCount -gt 0) {
                $summaryData += [PSCustomObject]@{
                    Category = $categoryName
                    Total = $totalCount
                    Match = $matchCount
                    Difference = $diffCount
                    SourceOnly = $sourceCount
                    TargetOnly = $targetCount
                }
            }
        }
    }
    
    # Export Summary sheet (path-based)
    try {
        # First write creates the package and returns it via -PassThru
        $summarySheetName = Get-SafeSheetName 'Summary'
        $null = ($summaryData | Export-Excel -Path $fullPath -WorksheetName $summarySheetName -AutoSize -AutoFilter -FreezeTopRow -TableStyle Medium2 -TableName "SummaryTable")
        $importExcelVersion = (Get-Module ImportExcel -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version
        Write-Host "  Summary sheet written" -ForegroundColor DarkGray
        Write-Host "  ImportExcel version: $importExcelVersion" -ForegroundColor Gray
        Write-Host "  Excel export mode: PathAppend" -ForegroundColor Gray
    } catch {
        Write-Host "Error writing Summary sheet: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
    
    Write-Host "  Created Summary sheet with $($summaryData.Count) categories" -ForegroundColor Green
    
    # Export each category as separate sheet
    Write-Host "`nStep 2: Creating individual category sheets..." -ForegroundColor Cyan
    $sheetCount = 0
    
    foreach ($categoryName in $allCategories) {
        $categoryData = $global:ComparisonData.$categoryName
        
        if (-not $categoryData) { continue }
        
        # Combine all items with status
        $allItems = @()
        
        if ($categoryData.Matches -and $categoryData.Matches.Count -gt 0) {
            foreach ($item in $categoryData.Matches) {
                $newItem = Normalize-ItemForExcel $item
                # If normalization produced an empty object (e.g., scalar input), emit an Item column
                if (($newItem.PSObject.Properties | Measure-Object).Count -eq 0) {
                    $newItem = [PSCustomObject]@{ Item = (Convert-ToPlainValue -value $item -depth 0 -maxDepth 2) }
                }
                $newItem | Add-Member -NotePropertyName "ComparisonStatus" -NotePropertyValue "Match" -Force
                $allItems += $newItem
            }
        }
        
        if ($categoryData.Differences -and $categoryData.Differences.Count -gt 0) {
            foreach ($item in $categoryData.Differences) {
                $hasDiffMap = $false
                try { $hasDiffMap = ($item.PSObject.Properties.Name -contains 'Differences') } catch { $hasDiffMap = $false }
                if ($hasDiffMap -and $item.Differences -is [System.Collections.IDictionary]) {
                    foreach ($colName in $item.Differences.Keys) {
                        $srcVal = $null; $tgtVal = $null
                        if ($item.Source -and ($item.Source -is [System.Data.DataRow] -or $item.Source.PSObject.Properties[$colName])) {
                            try { $srcVal = $item.Source[$colName] } catch { $srcVal = $item.Source.PSObject.Properties[$colName].Value }
                        }
                        if ($item.Target -and ($item.Target -is [System.Data.DataRow] -or $item.Target.PSObject.Properties[$colName])) {
                            try { $tgtVal = $item.Target[$colName] } catch { $tgtVal = $item.Target.PSObject.Properties[$colName].Value }
                        }
                        $row = [ordered]@{}
                        $row['ComparisonStatus'] = 'Difference'
                        # Try to include common identity fields when available
                        foreach ($k in @('TABLE_SCHEMA','SCHEMA_NAME','TABLE_NAME','VIEW_NAME','INDEX_NAME','FUNCTION_NAME','PROCEDURE_NAME','TRIGGER_NAME','KEY_NAME','COLUMN_NAME')) {
                            $val = $null
                            if ($item.Source -and ($item.Source -is [System.Data.DataRow])) { try { $val = $item.Source[$k] } catch { } }
                            if (-not $val -and $item.Target -and ($item.Target -is [System.Data.DataRow])) { try { $val = $item.Target[$k] } catch { } }
                            if ($val) { $row[$k] = $val }
                        }
                        # If identity fields are still missing, derive from composite Key when present
                        if (-not $row['TABLE_SCHEMA'] -and -not $row['SCHEMA_NAME'] -and $item.PSObject.Properties['Key']) {
                            $parts = ("" + $item.Key) -split '\|'
                            if ($parts.Length -ge 1) { $row['SCHEMA_NAME'] = $parts[0] }
                            if ($parts.Length -ge 2) { $row['TABLE_NAME'] = $parts[1] }
                            if ($parts.Length -ge 3) { $row['COLUMN_NAME'] = $parts[2] }
                        }
                        $row['DifferenceColumn'] = $colName
                        $row['SourceValue'] = (Convert-ToPlainValue -value $srcVal -depth 0 -maxDepth 1)
                        $row['TargetValue'] = (Convert-ToPlainValue -value $tgtVal -depth 0 -maxDepth 1)
                        $allItems += [PSCustomObject]$row
                    }
                } else {
                    $newItem = Normalize-ItemForExcel $item
                    if (($newItem.PSObject.Properties | Measure-Object).Count -eq 0) {
                        $newItem = [PSCustomObject]@{ Item = (Convert-ToPlainValue -value $item -depth 0 -maxDepth 2) }
                    }
                    $newItem | Add-Member -NotePropertyName "ComparisonStatus" -NotePropertyValue "Difference" -Force
                    $allItems += $newItem
                }
            }
        }
        
        if ($categoryData.SourceOnly -and $categoryData.SourceOnly.Count -gt 0) {
            foreach ($item in $categoryData.SourceOnly) {
                $newItem = Normalize-ItemForExcel $item
                if (($newItem.PSObject.Properties | Measure-Object).Count -eq 0) {
                    $newItem = [PSCustomObject]@{ Item = (Convert-ToPlainValue -value $item -depth 0 -maxDepth 2) }
                }
                $newItem | Add-Member -NotePropertyName "ComparisonStatus" -NotePropertyValue "SourceOnly" -Force
                $allItems += $newItem
            }
        }
        
        if ($categoryData.TargetOnly -and $categoryData.TargetOnly.Count -gt 0) {
            foreach ($item in $categoryData.TargetOnly) {
                $newItem = Normalize-ItemForExcel $item
                if (($newItem.PSObject.Properties | Measure-Object).Count -eq 0) {
                    $newItem = [PSCustomObject]@{ Item = (Convert-ToPlainValue -value $item -depth 0 -maxDepth 2) }
                }
                $newItem | Add-Member -NotePropertyName "ComparisonStatus" -NotePropertyValue "TargetOnly" -Force
                $allItems += $newItem
            }
        }
        if ($allItems.Count -gt 0) {
            # Ensure a clear status column appears in Excel as the first column
            # and sort rows by status for readability: Differences, SourceOnly, TargetOnly, Match
            $statusOrder = @{ 'Difference' = 1; 'SourceOnly' = 2; 'TargetOnly' = 3; 'Match' = 4 }
            $allItems = $allItems | Sort-Object -Property @{ Expression = { $statusOrder[[string]($_.ComparisonStatus)] } }, @{ Expression = { $_.ToString() } }
            
            # Build a unified header set so Excel shows columns for differences too
            $allPropNames = New-Object System.Collections.Generic.HashSet[string]
            $mustHave = @('ComparisonStatus','DifferenceColumn','SourceValue','TargetValue')
            foreach ($n in $mustHave) { $allPropNames.Add($n) | Out-Null }
            foreach ($it in $allItems) {
                foreach ($p in $it.PSObject.Properties) { $allPropNames.Add([string]$p.Name) | Out-Null }
            }
            # Preferred column order: put diff details immediately after status so they're visible
            $identityCols = @('TABLE_SCHEMA','SCHEMA_NAME','TABLE_NAME','VIEW_NAME','INDEX_NAME','FUNCTION_NAME','PROCEDURE_NAME','TRIGGER_NAME','KEY_NAME','COLUMN_NAME')
            $otherCols = ($allPropNames | Where-Object { $_ -notin ($mustHave + $identityCols) -and $_ -ne 'ComparisonStatus' })
            $finalOrder = @('ComparisonStatus','DifferenceColumn','SourceValue','TargetValue') + $identityCols + $otherCols
            
            $allItemsForExport = @()
            foreach ($it in $allItems) {
                $row = [ordered]@{}
                foreach ($col in $finalOrder) {
                    if ($col -eq 'ComparisonStatus') { $row[$col] = ([string]$it.ComparisonStatus); continue }
                    $prop = $it.PSObject.Properties[$col]
                    if ($prop) { $row[$col] = $prop.Value } else { $row[$col] = '' }
                }
                $allItemsForExport += [PSCustomObject]$row
            }
            # Compute safe unique sheet name
            $sheetName = Get-SafeSheetName $categoryName
            
            Write-Host "  Creating sheet: $sheetName ($($allItems.Count) items)" -ForegroundColor Gray

            # Sanitize table name and ensure uniqueness
            $tableNameBase = ($sheetName -replace "[^A-Za-z0-9]", "")
            if ([string]::IsNullOrWhiteSpace($tableNameBase)) { $tableNameBase = "Sheet" }
            $tableName = "$tableNameBase`Table"
            
            # Decide sheet name; we'll append to file path (ImportExcel creates sheet if missing)
            $effectiveSheetName = $sheetName
            

            try {
                # Ensure we have an open package (defensive in case -PassThru failed)
                if (-not $excelPackage) {
                    Write-Host "  Re-opening ExcelPackage (defensive)" -ForegroundColor DarkGray
                    try { $excelPackage = Open-ExcelPackage -Path $fullPath } catch { $excelPackage = $null }
                }
                # Guarantee unique table name to avoid cross-sheet collisions
                $tableAttempt = 0
                $maxAttempts = 5
                $wrote = $false
                while (-not $wrote -and $tableAttempt -lt $maxAttempts) {
                    $effectiveTableName = if ($tableAttempt -eq 0) { $tableName } else { "$tableName" + ($tableAttempt) }
                    Write-Host "    [ExcelPackage] Writing worksheet: $effectiveSheetName, table: $effectiveTableName" -ForegroundColor DarkGray
                    try {
                        # Path-based write; ImportExcel creates workbook/sheet if needed
                        $allItemsForExport | Export-Excel -Path $fullPath -WorksheetName $effectiveSheetName -AutoSize -AutoFilter -FreezeTopRow -TableStyle Medium2 -TableName $effectiveTableName -Append | Out-Null
                        $wrote = $true
                    } catch {
                        $tableAttempt++
                        if ($tableAttempt -ge $maxAttempts) { throw }
                    }
                }
                Write-Host "    -> Sheet written" -ForegroundColor DarkGray
            } catch {
                Write-Host "Error writing sheet '$effectiveSheetName': $($_.Exception.Message)" -ForegroundColor Red
                Write-Host ("Exception details: " + ($_.Exception | Out-String)) -ForegroundColor DarkGray
                # Fallback: write without table formatting if table name conflicts or other styling errors occur
                try {
                    Write-Host "    [Fallback] Writing without table formatting" -ForegroundColor Yellow
                    $allItemsForExport | Export-Excel -Path $fullPath -WorksheetName $effectiveSheetName -AutoSize -AutoFilter -FreezeTopRow -Append | Out-Null
                    Write-Host "    -> Sheet written (fallback without table)" -ForegroundColor Yellow
                } catch {
                    Write-Host "    -> FATAL: Could not write sheet '$effectiveSheetName': $($_.Exception.Message)" -ForegroundColor Red
                    continue
                }
            }
            
            $sheetCount++
        }
    }
    
    # Finalize and save workbook
    try {
        Write-Host "`nExcel export completed successfully!" -ForegroundColor Green
    } catch {
        Write-Host "Error saving Excel package: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
    Write-Host "  Summary: 1 sheet" -ForegroundColor Gray
    Write-Host "  Categories: $sheetCount sheets" -ForegroundColor Gray
    Write-Host "  Total: $($sheetCount + 1) sheets" -ForegroundColor Gray
    Write-Host "`nLocation: $fullPath" -ForegroundColor Cyan
    
    # Only open if NOT launched from GUI
    if (-not $env:LAUNCHED_FROM_GUI) {
        Write-Host "`nOpening Excel file..." -ForegroundColor Yellow
        Start-Process $fullPath
    }
    
} elseif ($MultiPage) {
    # Multi-page mode: Create directory structure and split into multiple files
    Write-Host "`nMulti-Page Mode: Creating directory structure..." -ForegroundColor Cyan
    
    # Create directory name with timestamp and database names
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $sourceName = $SourceServer.Replace("\", "_").Replace(".", "_") + "_" + $SourceDatabase
    $targetName = $TargetServer.Replace("\", "_").Replace(".", "_") + "_" + $TargetDatabase
    $dirName = "${timestamp}_${sourceName}_vs_${targetName}_SchemaComparison"
    $reportDir = Join-Path (Get-Location) $dirName
    
    if (-not (Test-Path $reportDir)) {
        New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
    }
    
    Write-Host "Report directory: $reportDir" -ForegroundColor Green
    
    # Create multi-page structure with lazy-loaded sections
    Write-Host "Creating multi-page structure..." -ForegroundColor Cyan
    
    # Find all section IDs by looking for section-header elements with id
    $sectionIds = @()
    $sectionPattern = '<div class="section-header"[^>]+id="([^"]+)"'
    $sectionMatches = [regex]::Matches($htmlReport, $sectionPattern)
    foreach ($match in $sectionMatches) {
        $sectionIds += $match.Groups[1].Value.Replace('-header', '')
    }
    
    Write-Host "Found $($sectionIds.Count) sections" -ForegroundColor Yellow
    
    $sectionsStart = '<div id="sectionsContainer"'
    $headerEndPos = $htmlReport.IndexOf($sectionsStart)
    
    if ($headerEndPos -lt 0) {
        Write-Host "Warning: Could not find sections container. Saving full HTML." -ForegroundColor Yellow
        $indexPath = Join-Path $reportDir "index.html"
        $htmlReport | Out-File -FilePath $indexPath -Encoding UTF8
        Write-Host "Created index.html (fallback)" -ForegroundColor Yellow
    } else {
        # Extract each section and save to separate content files
        foreach ($sectionId in $sectionIds) {
            $contentFileName = "$sectionId-content.html"
            $contentFilePath = Join-Path $reportDir $contentFileName
            
            $headerIdPattern = "$sectionId-header"
            $headerPattern = "<div class=`"section-header`"[^>]+id=`"$headerIdPattern`""
            $headerMatch = [regex]::Match($htmlReport, $headerPattern)
            
            if ($headerMatch.Success) {
                $headerPos = $headerMatch.Index
                $sectionStartPos = $htmlReport.LastIndexOf('<div class="section"', $headerPos)
                
                if ($sectionStartPos -ge 0) {
                    $startPos = $sectionStartPos
                    $nextSectionStart = $htmlReport.IndexOf('<div class="section"', $startPos + 100)
                    
                    $endPos = if ($nextSectionStart -gt $startPos) { $nextSectionStart } else {
                        $tempPos = $htmlReport.IndexOf('</div></div>    <script', $startPos)
                        if ($tempPos -gt 0) { $tempPos } else { $htmlReport.Length }
                    }
                    
                    $sectionContent = $htmlReport.Substring($startPos, $endPos - $startPos)
                    $sectionContent = $sectionContent -replace 'class="section-content collapsed"', 'class="section-content"'
                    
                    $sectionContent | Out-File -FilePath $contentFilePath -Encoding UTF8
                    
                    $nameMatch = [regex]::Match($sectionContent, '<h2>([^<]+)</h2>')
                    $sectionName = if ($nameMatch.Success) { $nameMatch.Groups[1].Value } else { $sectionId }
                    Write-Host "  Created $contentFileName ($sectionName)" -ForegroundColor Gray
                }
            }
        }
        
        # Create index.html with just summary cards (truly lightweight)
        $summaryEndMarker = '<div id="sectionsContainer"'
        $summaryEndPos = $htmlReport.IndexOf($summaryEndMarker)
        $scriptStartMarker = '</div></div>    <script>'
        $scriptStartPos = $htmlReport.IndexOf($scriptStartMarker)
        
        # Build lightweight index: header + summary cards + empty container + scripts
        $indexHtml = $htmlReport.Substring(0, $summaryEndPos)
        $indexHtml += '<div id="sectionsContainer"></div>'
        $indexHtml += $htmlReport.Substring($scriptStartPos)
        
        # Replace all onclick handlers to navigate to section HTML files
        $indexHtml = $indexHtml -replace 'onclick="selectAllFiltersAndShowAll\(''([^'']+)''\)"', 'onclick="navigateToSection(''$1'')"'
        
        # Add "View Selected Sections" button after "Sort by Category" button
        $indexHtml = $indexHtml.Replace('onclick="window.sortCategoryAndSections && window.sortCategoryAndSections()">Sort by Category</button>', 'onclick="window.sortCategoryAndSections && window.sortCategoryAndSections()">Sort by Category</button>' + "`n" + '            <button id="view-selected-btn" class="sort-btn" style="background: rgba(40, 167, 69, 0.2); border-color: rgba(40, 167, 69, 0.5);" title="View all right-click selected sections in one page" onclick="viewSelectedSections()">View Selected Sections</button>')
        
        # Add navigation script to index.html (override the original function)
        $indexNavScript = @"

<script>
// Override navigateToSection for multi-page navigation from index
function navigateToSection(sectionName) {
    const sectionId = sectionName.toLowerCase().replace(/\s+/g, '-');
    window.location.href = sectionId + '.html';
}
// View all selected sections in one combined page
function viewSelectedSections() {
    const selectedCards = document.querySelectorAll('.summary-card.selected');
    
    if (selectedCards.length === 0) {
        alert('Please right-click on summary cards to select sections first.');
        return;
    }
    
    // Collect section IDs from selected cards
    const sectionIds = [];
    selectedCards.forEach(card => {
        const onclick = card.getAttribute('oncontextmenu');
        if (onclick) {
            const match = onclick.match(/markSummarySelected\([^,]+,\s*[^,]+,\s*'([^']+)'\)/);
            if (match) {
                sectionIds.push(match[1].toLowerCase().replace(/\s+/g, '-'));
            }
        }
    });
    
    alert('Loading ' + selectedCards.length + ' selected sections into a combined view...');
    
    // Build index-temp.html URL with selected sections as query parameter
    const params = sectionIds.join(',');
    window.location.href = 'index-temp.html?sections=' + encodeURIComponent(params);
}
</script>
"@
        
        # Add fallback sort functions in case the main script bundle was trimmed in multi-page index
        $fallbackSortScript = @"

<script>
(function(){
  function titleOf(card){
    var h = card && card.querySelector && card.querySelector('.summary-header h3');
    return (h && h.textContent ? h.textContent : '').toLowerCase();
  }
  if (!window.sortAlphaAndSections){
    window.sortAlphaAndSections = function(){
      var c = document.getElementById('summaryCards');
      if(!c) return;
      var arr = Array.prototype.slice.call(c.children).filter(function(x){ return x.classList && x.classList.contains('summary-card'); });
      arr.sort(function(a,b){ return titleOf(a).localeCompare(titleOf(b)); });
      var frag = document.createDocumentFragment(); arr.forEach(function(x){ frag.appendChild(x); });
      c.appendChild(frag);
    }
  }
  if (!window.sortCategoryAndSections){
    window.sortCategoryAndSections = function(){
      var weights = { 'schemas':1,'tables':1,'columns':1,'indexes':1,'functions':1,'stored procedures':1,'stored-procedures':1,'views':1,'synonyms':1,'constraints':1,'keys':1,'table triggers':1,'database triggers':1,'query store':2,'vlf information':2,'database options':3,'file information':3,'users':3,'roles':3,'external resources':3,'data types':3 };
      var c = document.getElementById('summaryCards');
      if(!c) return;
      var arr = Array.prototype.slice.call(c.children).filter(function(x){ return x.classList && x.classList.contains('summary-card'); });
      arr.sort(function(a,b){
        var at = titleOf(a), bt = titleOf(b);
        var aw = (weights[at]!==undefined?weights[at]:99), bw = (weights[bt]!==undefined?weights[bt]:99);
        if (aw !== bw) return aw - bw; return at.localeCompare(bt);
      });
      var frag = document.createDocumentFragment(); arr.forEach(function(x){ frag.appendChild(x); });
      c.appendChild(frag);
    }
  }
})();
</script>
"@

        $indexHtml = $indexHtml -replace '</body>', ($indexNavScript + $fallbackSortScript + '</body>')
        
        # Save index.html
        $indexPath = Join-Path $reportDir "index.html"
        $indexHtml | Out-File -FilePath $indexPath -Encoding UTF8
        
        $indexSize = (Get-Item $indexPath).Length / 1KB
        Write-Host "Created index.html ($([math]::Round($indexSize, 1)) KB)" -ForegroundColor Green
        
        # Extract summary cards HTML - find the end more reliably
        $summaryCardsStart = $htmlReport.IndexOf('<div class="summary">')
        $summaryCardsEnd = $htmlReport.IndexOf('</div><div id="sectionsContainer">')
        
        if ($summaryCardsStart -lt 0 -or $summaryCardsEnd -lt 0 -or $summaryCardsEnd -le $summaryCardsStart) {
            Write-Host "Warning: Could not extract summary cards. Section pages won't have navigation." -ForegroundColor Yellow
            $summaryCardsHtml = ""
        } else {
            # Include the closing </div> for the summary
            $summaryCardsHtml = $htmlReport.Substring($summaryCardsStart, $summaryCardsEnd - $summaryCardsStart + 6)
        }
        
        # Update summary cards onclick for navigation between section pages
        if ($summaryCardsHtml -ne "") {
            # Use regex to replace all onclick handlers at once  
            $summaryCardsForSections = $summaryCardsHtml -replace 'onclick="selectAllFiltersAndShowAll\(''([^'']+)''\)"', 'onclick="navigateToSection(''$1'')"'
            
            # Store the updated summary cards (navigation override will be added to each page separately)
            $summaryCardsForSections = $summaryCardsForSections
        } else {
            $summaryCardsForSections = ""
        }
        
        # Now create full section HTML pages with navigation
        # Extract header WITHOUT summary cards (to avoid duplication)
        $summaryStartInHeader = $htmlReport.IndexOf('<div class="summary">')
        if (($summaryStartInHeader -ge 0) -and ($summaryStartInHeader -lt $headerEndPos)) {
            # Header part is everything BEFORE the summary section
            $headerPart = $htmlReport.Substring(0, $summaryStartInHeader)
        } else {
            $headerPart = $htmlReport.Substring(0, $headerEndPos)
        }
        $scriptPart = $htmlReport.Substring($scriptStartPos)
        
        foreach ($sectionId in $sectionIds) {
            $htmlFileName = "$sectionId.html"
            $htmlFilePath = Join-Path $reportDir $htmlFileName
            
            # Build full page with summary cards + this section
            $sectionPageHtml = $headerPart
            
            # Add "View Selected Sections" button to section pages too
            $sectionPageHtml = $sectionPageHtml.Replace('onclick="window.sortCategoryAndSections && window.sortCategoryAndSections()">Sort by Category</button>', 'onclick="window.sortCategoryAndSections && window.sortCategoryAndSections()">Sort by Category</button>' + "`n" + '            <button id="view-selected-btn" class="sort-btn" style="background: rgba(40, 167, 69, 0.2); border-color: rgba(40, 167, 69, 0.5);" title="View all right-click selected sections in one page" onclick="viewSelectedSections()">View Selected Sections</button>')
            
            $sectionPageHtml += @"
<div style="margin: 20px; padding: 10px; background: #f0f9ff; border-left: 4px solid #2563eb;">
    <a href='index.html' style='color: #2563eb; text-decoration: none; font-size: 16px; font-weight: bold;'>&lt;- Back to Summary</a>
</div>
"@
            # Add summary cards with updated navigation
            $sectionPageHtml += $summaryCardsForSections
            
            # Add section content
            $sectionPageHtml += "<div id='sectionsContainer'>"
            $contentFileName = "$sectionId-content.html"
            $contentFilePath = Join-Path $reportDir $contentFileName
            if (Test-Path $contentFilePath) {
                $sectionContent = Get-Content $contentFilePath -Raw
                $sectionPageHtml += $sectionContent
                $sectionPageHtml += '</div>'
                $sectionPageHtml += $scriptPart
                
                # Override the navigateToSection function AFTER all other scripts
                $navOverride = @"

<script>
// Override navigateToSection for multi-page navigation
// Store original function
const originalNavigateToSection = navigateToSection;

function navigateToSection(sectionName) {
    const sectionId = sectionName.toLowerCase().replace(/\s+/g, '-');
    
    // Check if we're already on this section's page
    const currentPage = window.location.pathname.split('/').pop();
    const targetPage = sectionId + '.html';
    
    if (currentPage !== targetPage) {
        // Navigate to the section page
        window.location.href = sectionId + '.html';
    }
    // If already on the correct page, do nothing (don't scroll/expand)
}

// View all selected sections in one combined page
async function viewSelectedSections() {
    const selectedCards = document.querySelectorAll('.summary-card.selected');
    
    if (selectedCards.length === 0) {
        alert('Please right-click on summary cards to select sections first.');
        return;
    }
    
    // Collect section IDs from selected cards
    const sectionIds = [];
    selectedCards.forEach(card => {
        const onclick = card.getAttribute('oncontextmenu');
        if (onclick) {
            const match = onclick.match(/markSummarySelected\([^,]+,\s*[^,]+,\s*'([^']+)'\)/);
            if (match) {
                sectionIds.push(match[1].toLowerCase().replace(/\s+/g, '-'));
            }
        }
    });
    
    alert('Loading ' + selectedCards.length + ' selected sections into a combined view...');
    
    // Build index-temp.html URL with selected sections as query parameter
    const params = sectionIds.join(',');
    window.location.href = 'index-temp.html?sections=' + encodeURIComponent(params);
}
</script>
"@
            # Add right-click selection support script to section pages
            $rightClickSupport = @"

<script>
(function(){
  window.markSummarySelected = window.markSummarySelected || function(event, cardEl, sectionId){
    if (event.button !== 2 && event.type !== 'contextmenu') { return true; }
    if (event.preventDefault) event.preventDefault();
    if (event.stopPropagation) event.stopPropagation();
    try {
      if (cardEl.classList.contains('selected')) {
        cardEl.classList.remove('selected');
      } else {
        cardEl.classList.add('selected');
      }
    } catch(e) { console.error('markSummarySelected (section page) error', e); }
    return false;
  };
})();
</script>
"@
            $sectionPageHtml = $sectionPageHtml -replace '</body>', ($navOverride + $rightClickSupport + '</body>')
                
                $sectionPageHtml | Out-File -FilePath $htmlFilePath -Encoding UTF8
                Write-Host "  Created $htmlFileName" -ForegroundColor Gray
                
                # Keep the content file - we'll need it for index-temp.html loading
                # Remove-Item $contentFilePath -Force
            }
        }
        
        # Create index-temp.html with ALL sections embedded (for combined view)
        Write-Host "Creating index-temp.html for multi-section view..." -ForegroundColor Cyan
        $indexTempPath = Join-Path $reportDir "index-temp.html"
        
        # Build index-temp with embedded sections
        $indexTempHtml = $headerPart
        
        # Add "View Selected Sections" button to index-temp as well
        $indexTempHtml = $indexTempHtml.Replace('onclick="window.sortCategoryAndSections && window.sortCategoryAndSections()">Sort by Category</button>', 'onclick="window.sortCategoryAndSections && window.sortCategoryAndSections()">Sort by Category</button>' + "`n" + '            <button id="view-selected-btn" class="sort-btn" style="background: rgba(40, 167, 69, 0.2); border-color: rgba(40, 167, 69, 0.5);" title="View all right-click selected sections in one page" onclick="viewSelectedSections()">View Selected Sections</button>')
        
        $indexTempHtml += @"
<div style="margin: 20px; padding: 15px; background: #fff3cd; border-left: 4px solid #ffc107;">
    <h3 style="margin: 0 0 10px 0;">Combined View - Selected Sections</h3>
    <p style="margin: 0; color: #856404;">Showing selected sections. <a href='index.html' style='color: #2563eb;'>&lt;- Back to Main Dashboard</a></p>
</div>
<!-- Summary Cards Container (will be filtered by JavaScript) -->
<div class="summary">
    <h2>Selected Sections Summary</h2>
    <div id="summaryCards" class="summary-cards">
"@
        # Add all summary cards (keep class intact for sorting animations)
        $indexTempHtml += $summaryCardsHtml
        
        $indexTempHtml += @"
    </div>
</div>
<div id="sectionsContainer">
```
</div>
"@
        
        # Embed all section content with data-section-id attributes (hidden by default)
        foreach ($secId in $sectionIds) {
            $contentFileName = "$secId-content.html"
            $contentFilePath = Join-Path $reportDir $contentFileName
            if (Test-Path $contentFilePath) {
                $secContent = Get-Content $contentFilePath -Raw
                $indexTempHtml += "<div class='embedded-section' data-section-id='$secId' style='display:none;'>$secContent</div>`n"
            }
        }
        
        $indexTempHtml += "</div>"
        $indexTempHtml += $scriptPart
        
        # Add script to show only selected sections AND summary cards
        $combinedViewScript = @"

<script>
// Show only selected sections and summary cards based on URL parameter
(function() {
    const urlParams = new URLSearchParams(window.location.search);
    const sectionsParam = urlParams.get('sections');
    
    if (!sectionsParam) {
        document.getElementById('sectionsContainer').innerHTML = '<div style="text-align: center; padding: 50px; color: #999;">No sections selected. Use "View Selected Sections" button.</div>';
        return;
    }
    
    const selectedSections = sectionsParam.split(',');
    const allEmbedded = document.querySelectorAll('.embedded-section');
    
    // Show only selected sections and remove their internal summary cards
    selectedSections.forEach(sectionId => {
        const elem = document.querySelector('.embedded-section[data-section-id="' + sectionId + '"]');
        if (elem) {
            elem.style.display = 'block';
            
            // Remove any "Schema Drift Summary" or summary cards within the section
            const innerSummary = elem.querySelector('.summary');
            if (innerSummary) {
                innerSummary.remove();
            }
        }
    });
    
    // Remove sections that weren't selected
    allEmbedded.forEach(elem => {
        if (!selectedSections.includes(elem.getAttribute('data-section-id'))) {
            elem.remove();
        }
    });
    
    // Show only selected summary cards (keep class intact for sorting animations)
    const allCards = document.querySelectorAll('.summary-card');
    
    // First, hide all cards
    allCards.forEach(card => {
        card.style.display = 'none';
    });
    
    // Then show only selected ones
    selectedSections.forEach(sectionId => {
        allCards.forEach(card => {
            const onclick = card.getAttribute('oncontextmenu');
            if (onclick) {
                const match = onclick.match(/markSummarySelected\([^,]+,\s*[^,]+,\s*'([^']+)'\)/);
                if (match) {
                    const cardSectionId = match[1].toLowerCase().replace(/\s+/g, '-');
                    if (cardSectionId === sectionId) {
                        // Show and mark as selected
                        card.style.display = 'block';
                        card.classList.add('selected');
                    }
                }
            }
        });
    });
})();
</script>
"@
        
        # Add sorting/animation fallback for index-temp (selected sections combined view)
        $indexTempFallback = @"

<script>
(function(){
  function titleOf(card){
    var h = card && card.querySelector && card.querySelector('.summary-header h3');
    return (h && h.textContent ? h.textContent : '').toLowerCase();
  }
  function animateReorder(container, newOrder){
    if(!container) return;
    var D=500, easing='cubic-bezier(0.16, 1, 0.3, 1)';
    var rects=new Map();
    Array.prototype.forEach.call(container.children,function(el){
      if(!(el instanceof HTMLElement)) return; rects.set(el, el.getBoundingClientRect());
    });
    var frag=document.createDocumentFragment(); newOrder.forEach(function(el){ frag.appendChild(el); });
    container.appendChild(frag);
    newOrder.forEach(function(el){
      if(!(el instanceof HTMLElement)) return; var first=rects.get(el); var last=el.getBoundingClientRect();
      if(!first) return; var dx=first.left-last.left, dy=first.top-last.top;
      el.style.transform='translate('+dx+'px,'+dy+'px)'; el.style.transition='none';
      requestAnimationFrame(function(){
        el.style.transition='transform '+D+'ms '+easing+', opacity '+D+'ms '+easing;
        el.style.transform='translate(0,0)';
      });
    });
    setTimeout(function(){ newOrder.forEach(function(el){ el.style.transition=''; el.style.transform=''; }); }, D+20);
  }
  if (!window.sortAlphaAndSections){
    window.sortAlphaAndSections = function(){
      var c = document.getElementById('summaryCards');
      if(!c) return;
      var cards = Array.prototype.slice.call(c.getElementsByClassName('summary-card'));
      cards.sort(function(a,b){ return titleOf(a).localeCompare(titleOf(b)); });
      animateReorder(c, cards);
      var sec = document.getElementById('sectionsContainer');
      if (sec){
        var sections = Array.prototype.slice.call(sec.querySelectorAll('.section'));
        sections.sort(function(a,b){
          var at=(a.querySelector('.section-header h2')||{}).textContent||''; at=at.toLowerCase();
          var bt=(b.querySelector('.section-header h2')||{}).textContent||''; bt=bt.toLowerCase();
          return at.localeCompare(bt);
        });
        animateReorder(sec, sections);
      }
    }
  }
  if (!window.sortCategoryAndSections){
    window.sortCategoryAndSections = function(){
      var weights = { 'schemas':1,'tables':1,'columns':1,'indexes':1,'functions':1,'stored procedures':1,'stored-procedures':1,'views':1,'synonyms':1,'constraints':1,'keys':1,'table triggers':1,'database triggers':1,'query store':2,'vlf information':2,'database options':3,'file information':3,'users':3,'roles':3,'external resources':3,'data types':3 };
      var c = document.getElementById('summaryCards'); if(!c) return;
      var cards = Array.prototype.slice.call(c.getElementsByClassName('summary-card'));
      cards.sort(function(a,b){
        var at = titleOf(a), bt = titleOf(b);
        var aw = (weights[at]!==undefined?weights[at]:99), bw = (weights[bt]!==undefined?weights[bt]:99);
        if (aw !== bw) return aw - bw; return at.localeCompare(bt);
      });
      animateReorder(c, cards);
      var sec = document.getElementById('sectionsContainer');
      if (sec){
        var sections = Array.prototype.slice.call(sec.querySelectorAll('.section'));
        sections.sort(function(a,b){
          var aw = +(a.getAttribute('data-category-weight')||99);
          var bw = +(b.getAttribute('data-category-weight')||99);
          if (aw!==bw) return aw-bw;
          var at=(a.querySelector('.section-header h2')||{}).textContent||''; at=at.toLowerCase();
          var bt=(b.querySelector('.section-header h2')||{}).textContent||''; bt=bt.toLowerCase();
          return at.localeCompare(bt);
        });
        animateReorder(sec, sections);
      }
    }
  }
})();
</script>
"@

        $indexTempHtml = $indexTempHtml -replace '</body>', ($combinedViewScript + $indexTempFallback + '</body>')
        $indexTempHtml | Out-File -FilePath $indexTempPath -Encoding UTF8
        Write-Host "Created index-temp.html for combined view" -ForegroundColor Green
    }
    
    Write-Host "`nMulti-page report generated successfully!" -ForegroundColor Green
    Write-Host "Location: $reportDir" -ForegroundColor Cyan
    
    # Only open if NOT launched from GUI (GUI will open it)
    if (-not $env:LAUNCHED_FROM_GUI) {
        Write-Host "`nOpening report in default browser..." -ForegroundColor Yellow
        Start-Process $indexPath
    }
} else {
    # Single page mode (default)
    $htmlReport | Out-File -FilePath $OutputPath -Encoding UTF8
    
    Write-Host "`nReport generated successfully!" -ForegroundColor Green
    Write-Host "Location: $OutputPath" -ForegroundColor Cyan
    
    # Only open if NOT launched from GUI (GUI will open it)
    if (-not $env:LAUNCHED_FROM_GUI) {
        Write-Host "`nOpening report in default browser..." -ForegroundColor Yellow
        Start-Process $OutputPath
    }
}

# Note: Excel export mode now uses HTML auto-export (see above in the if ($ExportExcel) block)
# The old PowerShell COM automation approach has been removed in favor of browser-based export

Write-Host "`nDatabase Schema Drift Detection completed!" -ForegroundColor Green

# Clean up variables after completion to free memory
Write-Verbose "Cleaning up variables after completion..."
Clear-CachedVariables

# Explicit exit code for success
exit 0