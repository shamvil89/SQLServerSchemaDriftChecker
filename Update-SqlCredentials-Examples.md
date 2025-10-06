# SQL Credentials Update Script - Usage Examples

## Overview
The `Update-SqlCredentials.ps1` script allows you to securely update SQL Server authentication credentials in your `config.json` file without exposing passwords in command history or plain text.

## Features
- ✅ **Secure password input** (no echo to console)
- ✅ **Interactive guided mode** for easy configuration selection
- ✅ **Non-interactive mode** for automation
- ✅ **Automatic backup** of config file before changes
- ✅ **List available configurations** with current credential status
- ✅ **Masked password display** for security

## Usage Examples

### 1. Interactive Mode (Recommended)
```powershell
# Guided mode - select configuration and update credentials interactively
.\Update-SqlCredentials.ps1 -Interactive
```

### 2. List Available Configurations
```powershell
# See all configurations and their current credential status
.\Update-SqlCredentials.ps1 -ListConfigs
```

### 3. Update Specific Configuration (Non-Interactive)
```powershell
# Update source credentials for a specific configuration
.\Update-SqlCredentials.ps1 -ConfigName "Cross-Environment with SQL Auth" -SourceUsername "new_staging_user"

# Update target credentials for a specific configuration
.\Update-SqlCredentials.ps1 -ConfigName "Multi-Tenant Azure Comparison" -TargetUsername "new_tenant2_user"

# Update both source and target credentials
.\Update-SqlCredentials.ps1 -ConfigName "Hybrid Cloud Setup" -SourceUsername "cloud_user" -TargetUsername "onprem_service"
```

### 4. Use Custom Config File
```powershell
# Work with a different config file
.\Update-SqlCredentials.ps1 -ConfigFile ".\custom-config.json" -Interactive
```

### 5. Show Passwords in Output (Use with Caution)
```powershell
# Display actual passwords in output (for troubleshooting only)
.\Update-SqlCredentials.ps1 -Interactive -ShowPasswords
```

## Interactive Mode Walkthrough

When you run with `-Interactive`, the script will:

1. **Display all configurations** with current credential status
2. **Let you select** which configuration to update
3. **Show current credentials** (usernames visible, passwords masked)
4. **Prompt for new credentials** only if needed based on auth type
5. **Securely collect passwords** without displaying them
6. **Create automatic backup** of your config file
7. **Save updated configuration**

### Example Interactive Session:
```
SQL Server Authentication Credential Updater
==================================================

Available Configurations:
==================================================
[1] Local Development Environment [TrustedConnection]
    Description: Compare local SQL Server databases using Windows Authentication
    Source: localhost.DevSourceDB
    Target: localhost\SQLEXPRESS.DevTargetDB

[2] Cross-Environment with SQL Auth [SQL Auth - Source: staging_reader, Target: prod_reader]
    Description: Compare staging to production using SQL Authentication
    Source: staging-sql.company.com.StagingDB
    Target: prod-sql.company.com.ProductionDB

[3] Hybrid Cloud Setup [Mixed - Source: AzureAD, Target: SqlAuth] [Users - Source: <not set>, Target: service_account]
    Description: Azure SQL to on-premises with different authentication
    Source: company-cloud.database.windows.net.CloudDB
    Target: onprem-sql-cluster.company.local.OnPremDB

Select configuration number (1-3): 2

Selected Configuration: Cross-Environment with SQL Auth
Auth Type: SqlAuth

Source Server Credentials:
Current Username: staging_reader
Current Password: ***************
New Source Username (press Enter to keep current): new_staging_user
New Source Password: ***********

Target Server Credentials:
Current Username: prod_reader
Current Password: **********
New Target Username (press Enter to keep current): 

Backup created: .\config.json.backup.20241217_143022
Configuration updated successfully!
```

## Security Features

### 🔒 **Secure Password Input**
- Passwords are read using `Read-Host -AsSecureString`
- No passwords displayed in console or command history
- Memory is properly cleared after use

### 🔐 **Automatic Backups**
- Creates timestamped backup before any changes
- Format: `config.json.backup.YYYYMMDD_HHMMSS`
- Easy to restore if needed

### 👁️ **Password Masking**
- Current passwords shown as asterisks (`***`)
- Only shows actual passwords with `-ShowPasswords` flag
- Safe to run in shared environments

## Configuration Types Supported

The script intelligently handles different authentication types:

- **`"SqlAuth"`**: Updates both source and target credentials
- **`"Mixed"`**: Only prompts for SQL auth servers (source/target)
- **`"TrustedConnection"`** / **`"AzureAD"`**: Skips credential prompts

## Error Handling

The script includes comprehensive error handling:
- ✅ Validates config file exists
- ✅ Checks if configuration name exists
- ✅ Verifies authentication types need SQL credentials
- ✅ Creates backups before making changes
- ✅ Provides clear error messages

## Automation Examples

### Batch Update Multiple Configurations
```powershell
# Update multiple configurations in sequence
$configs = @(
    @{ Name = "Staging Environment"; SourceUser = "staging_svc"; TargetUser = "staging_svc" },
    @{ Name = "Production Environment"; SourceUser = "prod_svc"; TargetUser = "prod_svc" }
)

foreach ($cfg in $configs) {
    .\Update-SqlCredentials.ps1 -ConfigName $cfg.Name -SourceUsername $cfg.SourceUser -TargetUsername $cfg.TargetUser
}
```

### Integration with Azure Key Vault
```powershell
# Retrieve credentials from Azure Key Vault and update config
$sourceSecret = Get-AzKeyVaultSecret -VaultName "MyKeyVault" -Name "StagingUser"
$targetSecret = Get-AzKeyVaultSecret -VaultName "MyKeyVault" -Name "ProdUser"

# Note: This would require modifying the script to accept password parameters
# Currently designed for secure interactive input only
```

## Best Practices

1. **🔄 Regular Updates**: Update credentials regularly as part of security rotation
2. **📁 Backup Management**: Keep backups in secure location, clean up old ones
3. **🔒 Secure Storage**: Consider using Azure Key Vault or similar for production
4. **👥 Team Access**: Use service accounts for shared configurations
5. **📝 Documentation**: Document which configurations are used for what environments

## Troubleshooting

### Common Issues:
- **"Configuration not found"**: Use `-ListConfigs` to see available names
- **"No SQL authentication"**: Check if config actually uses SQL auth
- **"Permission denied"**: Ensure you can write to the config file location
- **"Invalid JSON"**: Restore from backup if config gets corrupted
