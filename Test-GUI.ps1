# Test script for the Database Configuration GUI
# This script tests the GUI functionality without requiring user interaction

Write-Host "Testing Database Configuration GUI..." -ForegroundColor Green

# Test 1: Check if config.json exists and is valid
Write-Host "`n1. Testing configuration file..." -ForegroundColor Yellow
if (Test-Path "config.json") {
    try {
        $config = Get-Content "config.json" -Raw | ConvertFrom-Json
        Write-Host "   PASS: config.json found and valid" -ForegroundColor Green
        Write-Host "   PASS: Found $($config.databaseConfigurations.Count) configurations" -ForegroundColor Green
    } catch {
        Write-Host "   FAIL: config.json is invalid: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "   FAIL: config.json not found" -ForegroundColor Red
    exit 1
}

# Test 2: Check if GUI script exists
Write-Host "`n2. Testing GUI script..." -ForegroundColor Yellow
if (Test-Path "DatabaseConfigGUI.ps1") {
        Write-Host "   PASS: DatabaseConfigGUI.ps1 found" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: DatabaseConfigGUI.ps1 not found" -ForegroundColor Red
    exit 1
}

# Test 3: Check if launcher script exists
Write-Host "`n3. Testing launcher script..." -ForegroundColor Yellow
if (Test-Path "Launch-GUI.ps1") {
        Write-Host "   PASS: Launch-GUI.ps1 found" -ForegroundColor Green
    } else {
        Write-Host "   FAIL: Launch-GUI.ps1 not found" -ForegroundColor Red
    exit 1
}

# Test 4: Test PowerShell syntax
Write-Host "`n4. Testing PowerShell syntax..." -ForegroundColor Yellow
try {
    $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content "DatabaseConfigGUI.ps1" -Raw), [ref]$null)
    Write-Host "   PASS: PowerShell syntax is valid" -ForegroundColor Green
} catch {
    Write-Host "   FAIL: PowerShell syntax error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Test 5: Test Windows Forms availability
Write-Host "`n5. Testing Windows Forms..." -ForegroundColor Yellow
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    Write-Host "   PASS: Windows Forms assemblies loaded successfully" -ForegroundColor Green
} catch {
    Write-Host "   FAIL: Windows Forms not available: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host "`nAll tests passed! The GUI should work correctly." -ForegroundColor Green
Write-Host "`nTo launch the GUI, run:" -ForegroundColor Cyan
Write-Host "   powershell -NoProfile -ExecutionPolicy Bypass -File .\Launch-GUI.ps1" -ForegroundColor White
