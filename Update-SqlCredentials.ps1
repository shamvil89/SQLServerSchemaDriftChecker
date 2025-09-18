# Update SQL Server Authentication Credentials in config.json
# This script allows you to securely update username/password for SQL authentication
# configurations without exposing credentials in command history

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile = ".\config.json",
    
    [Parameter(Mandatory=$false)]
    [string]$ConfigName,
    
    [Parameter(Mandatory=$false)]
    [string]$SourceUsername,
    
    [Parameter(Mandatory=$false)]
    [string]$TargetUsername,
    
    [Parameter(Mandatory=$false)]
    [switch]$Interactive,
    
    [Parameter(Mandatory=$false)]
    [switch]$ListConfigs,
    
    [Parameter(Mandatory=$false)]
    [switch]$ShowPasswords
)

# Function to display available configurations
function Show-AvailableConfigs {
    param([object]$Config)
    
    Write-Host "`nAvailable Configurations:" -ForegroundColor Green
    Write-Host "=" * 50
    
    for ($i = 0; $i -lt $Config.databaseConfigurations.Count; $i++) {
        $cfg = $Config.databaseConfigurations[$i]
        $authInfo = ""
        
        if ($cfg.authType -eq "SqlAuth") {
            $srcUser = if ($cfg.sourceUsername) { $cfg.sourceUsername } else { "<not set>" }
            $tgtUser = if ($cfg.targetUsername) { $cfg.targetUsername } else { "<not set>" }
            $authInfo = " [SQL Auth - Source: $srcUser, Target: $tgtUser]"
        } elseif ($cfg.authType -eq "Mixed") {
            $srcAuth = if ($cfg.sourceAuthType) { $cfg.sourceAuthType } else { "TrustedConnection" }
            $tgtAuth = if ($cfg.targetAuthType) { $cfg.targetAuthType } else { "TrustedConnection" }
            $authInfo = " [Mixed - Source: $srcAuth, Target: $tgtAuth]"
            if ($srcAuth -eq "SqlAuth" -or $tgtAuth -eq "SqlAuth") {
                $srcUser = if ($cfg.sourceUsername) { $cfg.sourceUsername } else { "<not set>" }
                $tgtUser = if ($cfg.targetUsername) { $cfg.targetUsername } else { "<not set>" }
                $authInfo += " [Users - Source: $srcUser, Target: $tgtUser]"
            }
        } else {
            $authInfo = " [$($cfg.authType)]"
        }
        
        Write-Host "[$($i+1)] $($cfg.name)$authInfo" -ForegroundColor Cyan
        Write-Host "    Description: $($cfg.description)" -ForegroundColor Gray
        Write-Host "    Source: $($cfg.sourceServer).$($cfg.sourceDatabase)" -ForegroundColor Gray
        Write-Host "    Target: $($cfg.targetServer).$($cfg.targetDatabase)" -ForegroundColor Gray
        Write-Host ""
    }
}

# Function to securely read password
function Read-SecurePassword {
    param([string]$Prompt)
    
    $securePassword = Read-Host -Prompt $Prompt -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    return $password
}

# Function to mask password for display
function Get-MaskedPassword {
    param([string]$Password)
    
    if (-not $Password -or $Password -eq "") {
        return "<not set>"
    }
    return "*" * $Password.Length
}

# Main script logic
try {
    # Check if config file exists
    if (-not (Test-Path $ConfigFile)) {
        Write-Error "Configuration file not found: $ConfigFile"
        exit 1
    }
    
    # Load configuration
    $configContent = Get-Content -Path $ConfigFile -Raw
    $config = $configContent | ConvertFrom-Json
    
    # List configurations if requested
    if ($ListConfigs) {
        Show-AvailableConfigs -Config $config
        exit 0
    }
    
    # Interactive mode
    if ($Interactive) {
        Write-Host "SQL Server Authentication Credential Updater" -ForegroundColor Green
        Write-Host "=" * 50
        
        Show-AvailableConfigs -Config $config
        
        # Select configuration
        do {
            $selection = Read-Host "Select configuration number (1-$($config.databaseConfigurations.Count))"
            $selectionIndex = $selection -as [int]
        } while ($selectionIndex -lt 1 -or $selectionIndex -gt $config.databaseConfigurations.Count)
        
        $selectedConfig = $config.databaseConfigurations[$selectionIndex - 1]
        $ConfigName = $selectedConfig.name
        
        Write-Host "`nSelected Configuration: $($selectedConfig.name)" -ForegroundColor Yellow
        Write-Host "Auth Type: $($selectedConfig.authType)" -ForegroundColor Gray
        
        # Check if this config uses SQL authentication
        $needsSourceCreds = $false
        $needsTargetCreds = $false
        
        if ($selectedConfig.authType -eq "SqlAuth") {
            $needsSourceCreds = $true
            $needsTargetCreds = $true
        } elseif ($selectedConfig.authType -eq "Mixed") {
            if ($selectedConfig.sourceAuthType -eq "SqlAuth") { $needsSourceCreds = $true }
            if ($selectedConfig.targetAuthType -eq "SqlAuth") { $needsTargetCreds = $true }
        }
        
        if (-not $needsSourceCreds -and -not $needsTargetCreds) {
            Write-Warning "This configuration doesn't use SQL Server authentication."
            exit 0
        }
        
        # Update credentials as needed
        if ($needsSourceCreds) {
            Write-Host "`nSource Server Credentials:" -ForegroundColor Cyan
            $currentUser = if ($selectedConfig.sourceUsername) { $selectedConfig.sourceUsername } else { "<not set>" }
            $currentPass = Get-MaskedPassword -Password $selectedConfig.sourcePassword
            
            Write-Host "Current Username: $currentUser" -ForegroundColor Gray
            Write-Host "Current Password: $currentPass" -ForegroundColor Gray
            
            $newSourceUser = Read-Host "New Source Username (press Enter to keep current)"
            if ($newSourceUser -ne "") {
                $selectedConfig | Add-Member -NotePropertyName "sourceUsername" -NotePropertyValue $newSourceUser -Force
                $newSourcePass = Read-SecurePassword -Prompt "New Source Password"
                $selectedConfig | Add-Member -NotePropertyName "sourcePassword" -NotePropertyValue $newSourcePass -Force
            }
        }
        
        if ($needsTargetCreds) {
            Write-Host "`nTarget Server Credentials:" -ForegroundColor Cyan
            $currentUser = if ($selectedConfig.targetUsername) { $selectedConfig.targetUsername } else { "<not set>" }
            $currentPass = Get-MaskedPassword -Password $selectedConfig.targetPassword
            
            Write-Host "Current Username: $currentUser" -ForegroundColor Gray
            Write-Host "Current Password: $currentPass" -ForegroundColor Gray
            
            $newTargetUser = Read-Host "New Target Username (press Enter to keep current)"
            if ($newTargetUser -ne "") {
                $selectedConfig | Add-Member -NotePropertyName "targetUsername" -NotePropertyValue $newTargetUser -Force
                $newTargetPass = Read-SecurePassword -Prompt "New Target Password"
                $selectedConfig | Add-Member -NotePropertyName "targetPassword" -NotePropertyValue $newTargetPass -Force
            }
        }
    }
    # Non-interactive mode with parameters
    else {
        if (-not $ConfigName) {
            Write-Error "ConfigName is required when not in interactive mode"
            Write-Host "Use -Interactive for guided mode or -ListConfigs to see available configurations" -ForegroundColor Yellow
            exit 1
        }
        
        # Find the specified configuration
        $selectedConfig = $config.databaseConfigurations | Where-Object { $_.name -eq $ConfigName }
        if (-not $selectedConfig) {
            Write-Error "Configuration '$ConfigName' not found"
            Show-AvailableConfigs -Config $config
            exit 1
        }
        
        Write-Host "Updating configuration: $ConfigName" -ForegroundColor Green
        
        # Update source credentials if provided
        if ($SourceUsername) {
            $selectedConfig | Add-Member -NotePropertyName "sourceUsername" -NotePropertyValue $SourceUsername -Force
            $sourcePassword = Read-SecurePassword -Prompt "Enter Source Password for $SourceUsername"
            $selectedConfig | Add-Member -NotePropertyName "sourcePassword" -NotePropertyValue $sourcePassword -Force
            Write-Host "Source credentials updated for $SourceUsername" -ForegroundColor Cyan
        }
        
        # Update target credentials if provided
        if ($TargetUsername) {
            $selectedConfig | Add-Member -NotePropertyName "targetUsername" -NotePropertyValue $TargetUsername -Force
            $targetPassword = Read-SecurePassword -Prompt "Enter Target Password for $TargetUsername"
            $selectedConfig | Add-Member -NotePropertyName "targetPassword" -NotePropertyValue $targetPassword -Force
            Write-Host "Target credentials updated for $TargetUsername" -ForegroundColor Cyan
        }
    }
    
    # Save the updated configuration
    $updatedJson = $config | ConvertTo-Json -Depth 10 -Compress:$false
    
    # Create backup
    $backupFile = "$ConfigFile.backup.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item $ConfigFile $backupFile
    Write-Host "Backup created: $backupFile" -ForegroundColor Yellow
    
    # Write updated config
    $updatedJson | Out-File -FilePath $ConfigFile -Encoding UTF8
    Write-Host "Configuration updated successfully!" -ForegroundColor Green
    
    # Show updated configuration (without passwords unless requested)
    if ($ShowPasswords) {
        Write-Host "`nUpdated Configuration:" -ForegroundColor Cyan
        $selectedConfig | ConvertTo-Json -Depth 5
    } else {
        Write-Host "`nUpdated Configuration (passwords masked):" -ForegroundColor Cyan
        $maskedConfig = $selectedConfig.PSObject.Copy()
        if ($maskedConfig.sourcePassword) { $maskedConfig.sourcePassword = Get-MaskedPassword -Password $maskedConfig.sourcePassword }
        if ($maskedConfig.targetPassword) { $maskedConfig.targetPassword = Get-MaskedPassword -Password $maskedConfig.targetPassword }
        $maskedConfig | ConvertTo-Json -Depth 5
    }
}
catch {
    Write-Error "Error updating configuration: $($_.Exception.Message)"
    exit 1
}
