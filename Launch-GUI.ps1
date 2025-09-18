# Launch Database Configuration GUI
# Simple launcher script for the GUI application

param(
    [string]$ConfigPath = "config.json"
)

Write-Host "Starting Database Schema Drift Detection GUI..." -ForegroundColor Green
Write-Host "Configuration file: $ConfigPath" -ForegroundColor Yellow

try {
    # Check if config file exists
    if (-not (Test-Path $ConfigPath)) {
        Write-Error "Configuration file not found: $ConfigPath"
        Write-Host "Please ensure config.json exists in the current directory." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    
    # Launch the GUI
    & ".\DatabaseConfigGUI.ps1" -ConfigPath $ConfigPath
} catch {
    Write-Error "Error launching GUI: $($_.Exception.Message)"
    Read-Host "Press Enter to exit"
    exit 1
}
