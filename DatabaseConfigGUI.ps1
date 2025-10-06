# Simple Database Configuration GUI
# Provides a Windows Forms interface for configuring database connections and running drift detection

param(
    [string]$ConfigPath = "config.json"
)

# Load Windows Forms
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Global variables
$script:Configurations = @()
$script:SelectedConfig = $null

function Load-Configurations {
    try {
        if (Test-Path $ConfigPath) {
            $configContent = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            $script:Configurations = $configContent.databaseConfigurations
            return $true
        } else {
            Write-Warning "Configuration file not found: $ConfigPath"
            return $false
        }
    } catch {
        Write-Error "Error loading configuration: $($_.Exception.Message)"
        return $false
    }
}

function Test-DatabaseConnection {
    param(
        [string]$Server,
        [string]$Database,
        [string]$AuthType,
        [string]$Username = "",
        [string]$Password = "",
        [ref]$ErrorMessage
    )
    
    try {
        $connectionString = ""
        
        if ($AuthType -eq "SqlAuth") {
            if ($Server -like "*.database.windows.net") {
                $connectionString = "Server=$Server;Database=$Database;User Id=$Username;Password=$Password;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
            } else {
                $connectionString = "Server=$Server;Database=$Database;User Id=$Username;Password=$Password;TrustServerCertificate=true;Connection Timeout=30;"
            }
        } elseif ($AuthType -eq "AzureAD") {
            $connectionString = "Server=$Server;Database=$Database;Authentication=Active Directory Integrated;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
        } else {
            $connectionString = "Server=$Server;Database=$Database;Integrated Security=true;TrustServerCertificate=true;"
        }
        
        $connection = New-Object System.Data.SqlClient.SqlConnection($connectionString)
        $connection.Open()
        $connection.Close()
        if ($ErrorMessage) { $ErrorMessage.Value = "" }
        return $true
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg += " - " + $_.Exception.InnerException.Message }
        if ($ErrorMessage) { $ErrorMessage.Value = $msg }
        return $false
    }
}

function Show-AuthDialog {
    param(
        [string]$Title,
        [string]$Server,
        [string]$Database,
        [hashtable]$CurrentAuth
    )
    
    $authForm = New-Object System.Windows.Forms.Form
    $authForm.Text = $Title
    $authForm.Size = New-Object System.Drawing.Size(400, 250)
    $authForm.StartPosition = "CenterParent"
    $authForm.FormBorderStyle = "FixedDialog"
    $authForm.MaximizeBox = $false
    $authForm.MinimizeBox = $false
    
    # Auth type selection
    $lblAuthType = New-Object System.Windows.Forms.Label
    $lblAuthType.Text = "Authentication Type:"
    $lblAuthType.Location = New-Object System.Drawing.Point(20, 20)
    $lblAuthType.Size = New-Object System.Drawing.Size(120, 20)
    $authForm.Controls.Add($lblAuthType)
    
    $cmbAuthType = New-Object System.Windows.Forms.ComboBox
    $cmbAuthType.Location = New-Object System.Drawing.Point(150, 18)
    $cmbAuthType.Size = New-Object System.Drawing.Size(200, 20)
    $cmbAuthType.DropDownStyle = "DropDownList"
    $cmbAuthType.Items.AddRange(@("TrustedConnection", "SqlAuth", "AzureAD"))
    $cmbAuthType.SelectedItem = $CurrentAuth.Type
    $authForm.Controls.Add($cmbAuthType)
    
    # Username (for SQL Auth)
    $lblUsername = New-Object System.Windows.Forms.Label
    $lblUsername.Text = "Username:"
    $lblUsername.Location = New-Object System.Drawing.Point(20, 50)
    $lblUsername.Size = New-Object System.Drawing.Size(120, 20)
    $authForm.Controls.Add($lblUsername)
    
    $txtUsername = New-Object System.Windows.Forms.TextBox
    $txtUsername.Text = $CurrentAuth.Username
    $txtUsername.Location = New-Object System.Drawing.Point(150, 48)
    $txtUsername.Size = New-Object System.Drawing.Size(200, 20)
    $authForm.Controls.Add($txtUsername)
    
    # Password (for SQL Auth)
    $lblPassword = New-Object System.Windows.Forms.Label
    $lblPassword.Text = "Password:"
    $lblPassword.Location = New-Object System.Drawing.Point(20, 80)
    $lblPassword.Size = New-Object System.Drawing.Size(120, 20)
    $authForm.Controls.Add($lblPassword)
    
    $txtPassword = New-Object System.Windows.Forms.TextBox
    $txtPassword.UseSystemPasswordChar = $true
    $txtPassword.Location = New-Object System.Drawing.Point(150, 78)
    $txtPassword.Size = New-Object System.Drawing.Size(200, 20)
    $authForm.Controls.Add($txtPassword)
    
    # OK button
    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "OK"
    $btnOK.Location = New-Object System.Drawing.Point(200, 120)
    $btnOK.Size = New-Object System.Drawing.Size(75, 30)
    $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $authForm.AcceptButton = $btnOK
    $authForm.Controls.Add($btnOK)
    
    # Cancel button
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(280, 120)
    $btnCancel.Size = New-Object System.Drawing.Size(75, 30)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $authForm.CancelButton = $btnCancel
    $authForm.Controls.Add($btnCancel)
    
    $result = $authForm.ShowDialog()
    
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return @{
            Type = $cmbAuthType.SelectedItem
            Username = $txtUsername.Text
            Password = $txtPassword.Text
        }
    } else {
        return $null
    }
}

# Main execution
if (Load-Configurations) {
    # Create the main form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Database Schema Drift Detection - Configuration"
    $form.Size = New-Object System.Drawing.Size(640, 520)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.BackColor = [System.Drawing.Color]::FromArgb(250,252,255)
    
    # Title
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Database Schema Drift Detection"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(30,41,59)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 18)
    $lblTitle.Size = New-Object System.Drawing.Size(500, 28)
    $form.Controls.Add($lblTitle)
    
    # Scenario selection
    $lblScenario = New-Object System.Windows.Forms.Label
    $lblScenario.Text = "Select Scenario:"
    $lblScenario.Location = New-Object System.Drawing.Point(20, 60)
    $lblScenario.Size = New-Object System.Drawing.Size(100, 20)
    $form.Controls.Add($lblScenario)
    
    $cmbScenario = New-Object System.Windows.Forms.ComboBox
    $cmbScenario.Location = New-Object System.Drawing.Point(130, 58)
    $cmbScenario.Size = New-Object System.Drawing.Size(400, 20)
    $cmbScenario.DropDownStyle = "DropDownList"
    $form.Controls.Add($cmbScenario)
    
    # Populate scenarios
    foreach ($config in $script:Configurations) {
        $cmbScenario.Items.Add("$($config.name) - $($config.description)")
    }
    
    # Source Server Group
    $grpSource = New-Object System.Windows.Forms.GroupBox
    $grpSource.Text = "Source Database"
    $grpSource.Location = New-Object System.Drawing.Point(20, 100)
    $grpSource.Size = New-Object System.Drawing.Size(250, 120)
    $form.Controls.Add($grpSource)
    
    $lblSourceServer = New-Object System.Windows.Forms.Label
    $lblSourceServer.Text = "Server:"
    $lblSourceServer.Location = New-Object System.Drawing.Point(10, 25)
    $lblSourceServer.Size = New-Object System.Drawing.Size(60, 20)
    $grpSource.Controls.Add($lblSourceServer)
    
    $txtSourceServer = New-Object System.Windows.Forms.TextBox
    $txtSourceServer.Location = New-Object System.Drawing.Point(80, 23)
    $txtSourceServer.Size = New-Object System.Drawing.Size(150, 20)
    $grpSource.Controls.Add($txtSourceServer)
    
    $lblSourceDB = New-Object System.Windows.Forms.Label
    $lblSourceDB.Text = "Database:"
    $lblSourceDB.Location = New-Object System.Drawing.Point(10, 50)
    $lblSourceDB.Size = New-Object System.Drawing.Size(60, 20)
    $grpSource.Controls.Add($lblSourceDB)
    
    $txtSourceDB = New-Object System.Windows.Forms.TextBox
    $txtSourceDB.Location = New-Object System.Drawing.Point(80, 48)
    $txtSourceDB.Size = New-Object System.Drawing.Size(150, 20)
    $grpSource.Controls.Add($txtSourceDB)
    
    $btnSourceAuth = New-Object System.Windows.Forms.Button
    $btnSourceAuth.Text = "Configure Auth"
    $btnSourceAuth.Location = New-Object System.Drawing.Point(10, 80)
    $btnSourceAuth.Size = New-Object System.Drawing.Size(100, 25)
    $grpSource.Controls.Add($btnSourceAuth)
    
    $lblSourceAuth = New-Object System.Windows.Forms.Label
    $lblSourceAuth.Text = "Windows Auth"
    $lblSourceAuth.Location = New-Object System.Drawing.Point(120, 85)
    $lblSourceAuth.Size = New-Object System.Drawing.Size(100, 20)
    $grpSource.Controls.Add($lblSourceAuth)
    
    # Target Server Group
    $grpTarget = New-Object System.Windows.Forms.GroupBox
    $grpTarget.Text = "Target Database"
    $grpTarget.Location = New-Object System.Drawing.Point(290, 100)
    $grpTarget.Size = New-Object System.Drawing.Size(250, 120)
    $form.Controls.Add($grpTarget)
    
    $lblTargetServer = New-Object System.Windows.Forms.Label
    $lblTargetServer.Text = "Server:"
    $lblTargetServer.Location = New-Object System.Drawing.Point(10, 25)
    $lblTargetServer.Size = New-Object System.Drawing.Size(60, 20)
    $grpTarget.Controls.Add($lblTargetServer)
    
    $txtTargetServer = New-Object System.Windows.Forms.TextBox
    $txtTargetServer.Location = New-Object System.Drawing.Point(80, 23)
    $txtTargetServer.Size = New-Object System.Drawing.Size(150, 20)
    $grpTarget.Controls.Add($txtTargetServer)
    
    $lblTargetDB = New-Object System.Windows.Forms.Label
    $lblTargetDB.Text = "Database:"
    $lblTargetDB.Location = New-Object System.Drawing.Point(10, 50)
    $lblTargetDB.Size = New-Object System.Drawing.Size(60, 20)
    $grpTarget.Controls.Add($lblTargetDB)
    
    $txtTargetDB = New-Object System.Windows.Forms.TextBox
    $txtTargetDB.Location = New-Object System.Drawing.Point(80, 48)
    $txtTargetDB.Size = New-Object System.Drawing.Size(150, 20)
    $grpTarget.Controls.Add($txtTargetDB)
    
    $btnTargetAuth = New-Object System.Windows.Forms.Button
    $btnTargetAuth.Text = "Configure Auth"
    $btnTargetAuth.Location = New-Object System.Drawing.Point(10, 80)
    $btnTargetAuth.Size = New-Object System.Drawing.Size(100, 25)
    $grpTarget.Controls.Add($btnTargetAuth)
    
    $lblTargetAuth = New-Object System.Windows.Forms.Label
    $lblTargetAuth.Text = "Windows Auth"
    $lblTargetAuth.Location = New-Object System.Drawing.Point(120, 85)
    $lblTargetAuth.Size = New-Object System.Drawing.Size(100, 20)
    $grpTarget.Controls.Add($lblTargetAuth)
    
    # Test Connection Group
    $grpTest = New-Object System.Windows.Forms.GroupBox
    $grpTest.Text = "Connection Test"
    $grpTest.Location = New-Object System.Drawing.Point(20, 240)
    $grpTest.Size = New-Object System.Drawing.Size(520, 80)
    $form.Controls.Add($grpTest)
    
    $btnTestSource = New-Object System.Windows.Forms.Button
    $btnTestSource.Text = "Test Source"
    $btnTestSource.Location = New-Object System.Drawing.Point(10, 25)
    $btnTestSource.Size = New-Object System.Drawing.Size(100, 30)
    $btnTestSource.FlatStyle = 'Flat'
    $btnTestSource.FlatAppearance.BorderSize = 1
    $btnTestSource.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203,213,225)
    $btnTestSource.BackColor = [System.Drawing.Color]::FromArgb(239,246,255)
    $btnTestSource.ForeColor = [System.Drawing.Color]::FromArgb(30,41,59)
    $grpTest.Controls.Add($btnTestSource)
    
    $btnTestTarget = New-Object System.Windows.Forms.Button
    $btnTestTarget.Text = "Test Target"
    $btnTestTarget.Location = New-Object System.Drawing.Point(120, 25)
    $btnTestTarget.Size = New-Object System.Drawing.Size(100, 30)
    $btnTestTarget.FlatStyle = 'Flat'
    $btnTestTarget.FlatAppearance.BorderSize = 1
    $btnTestTarget.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203,213,225)
    $btnTestTarget.BackColor = [System.Drawing.Color]::FromArgb(239,246,255)
    $btnTestTarget.ForeColor = [System.Drawing.Color]::FromArgb(30,41,59)
    $grpTest.Controls.Add($btnTestTarget)
    
    $btnTestBoth = New-Object System.Windows.Forms.Button
    $btnTestBoth.Text = "Test Both"
    $btnTestBoth.Location = New-Object System.Drawing.Point(230, 25)
    $btnTestBoth.Size = New-Object System.Drawing.Size(100, 30)
    $btnTestBoth.FlatStyle = 'Flat'
    $btnTestBoth.FlatAppearance.BorderSize = 1
    $btnTestBoth.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203,213,225)
    $btnTestBoth.BackColor = [System.Drawing.Color]::FromArgb(239,246,255)
    $btnTestBoth.ForeColor = [System.Drawing.Color]::FromArgb(30,41,59)
    $grpTest.Controls.Add($btnTestBoth)
    
    $lblTestResult = New-Object System.Windows.Forms.TextBox
    $lblTestResult.Multiline = $true
    $lblTestResult.ReadOnly = $true
    $lblTestResult.BorderStyle = 'None'
    $lblTestResult.BackColor = $form.BackColor
    $lblTestResult.Location = New-Object System.Drawing.Point(340, 20)
    $lblTestResult.Size = New-Object System.Drawing.Size(170, 50)
    $lblTestResult.ScrollBars = 'Vertical'
    $grpTest.Controls.Add($lblTestResult)
    
    # Action Buttons
    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "Run Drift Detection"
    $btnRun.Location = New-Object System.Drawing.Point(20, 340)
    $btnRun.Size = New-Object System.Drawing.Size(150, 40)
    $btnRun.Enabled = $false
    $btnRun.FlatStyle = 'Flat'
    $btnRun.FlatAppearance.BorderSize = 1
    $btnRun.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203,213,225)
    $btnRun.BackColor = [System.Drawing.Color]::FromArgb(219,234,254)
    $btnRun.ForeColor = [System.Drawing.Color]::FromArgb(17,24,39)
    $form.Controls.Add($btnRun)
    
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save Configuration"
    $btnSave.Location = New-Object System.Drawing.Point(180, 340)
    $btnSave.Size = New-Object System.Drawing.Size(150, 40)
    $btnSave.FlatStyle = 'Flat'
    $btnSave.FlatAppearance.BorderSize = 1
    $btnSave.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203,213,225)
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(243,244,246)
    $btnSave.ForeColor = [System.Drawing.Color]::FromArgb(17,24,39)
    $form.Controls.Add($btnSave)
    
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(340, 340)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 40)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.FlatStyle = 'Flat'
    $btnCancel.FlatAppearance.BorderSize = 1
    $btnCancel.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(203,213,225)
    $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(243,244,246)
    $btnCancel.ForeColor = [System.Drawing.Color]::FromArgb(17,24,39)
    $form.Controls.Add($btnCancel)
    
    # Status label
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Select a scenario to begin"
    $lblStatus.Location = New-Object System.Drawing.Point(20, 400)
    $lblStatus.Size = New-Object System.Drawing.Size(520, 20)
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(30,64,175)
    $form.Controls.Add($lblStatus)
    
    # Authentication configurations
    $SourceAuth = @{
        Type = "TrustedConnection"
        Username = ""
        Password = ""
    }
    $TargetAuth = @{
        Type = "TrustedConnection"
        Username = ""
        Password = ""
    }
    
    # Event handlers
    $cmbScenario.Add_SelectedIndexChanged({
        if ($cmbScenario.SelectedIndex -ge 0) {
            try {
                $selectedConfig = $script:Configurations[$cmbScenario.SelectedIndex]
                $txtSourceServer.Text = $selectedConfig.sourceServer
                $txtSourceDB.Text = $selectedConfig.sourceDatabase
                $txtTargetServer.Text = $selectedConfig.targetServer
                $txtTargetDB.Text = $selectedConfig.targetDatabase
                
                # Set authentication types with safe property access
                if ($selectedConfig.authType -eq "Mixed") {
                    $SourceAuth.Type = if ($selectedConfig.PSObject.Properties['sourceAuthType']) { $selectedConfig.sourceAuthType } else { "TrustedConnection" }
                    $TargetAuth.Type = if ($selectedConfig.PSObject.Properties['targetAuthType']) { $selectedConfig.targetAuthType } else { "TrustedConnection" }
                } else {
                    $SourceAuth.Type = $selectedConfig.authType
                    $TargetAuth.Type = $selectedConfig.authType
                }
                
                # Load usernames if they exist
                if ($selectedConfig.PSObject.Properties['sourceUsername']) {
                    $SourceAuth.Username = $selectedConfig.sourceUsername
                }
                if ($selectedConfig.PSObject.Properties['targetUsername']) {
                    $TargetAuth.Username = $selectedConfig.targetUsername
                }
                
                $lblSourceAuth.Text = $SourceAuth.Type
                $lblTargetAuth.Text = $TargetAuth.Type
                $lblStatus.Text = "Configuration loaded. Configure authentication and test connections."
                $btnRun.Enabled = $true
            } catch {
                $lblStatus.Text = "Error loading configuration: $($_.Exception.Message)"
                $lblStatus.ForeColor = [System.Drawing.Color]::Red
            }
        }
    })
    
    $btnSourceAuth.Add_Click({
        $authDialog = Show-AuthDialog "Source Database Authentication" $txtSourceServer.Text $txtSourceDB.Text $SourceAuth
        if ($authDialog) {
            $SourceAuth.Type = $authDialog.Type
            $SourceAuth.Username = $authDialog.Username
            $SourceAuth.Password = $authDialog.Password
            $lblSourceAuth.Text = $SourceAuth.Type
        }
    })
    
    $btnTargetAuth.Add_Click({
        $authDialog = Show-AuthDialog "Target Database Authentication" $txtTargetServer.Text $txtTargetDB.Text $TargetAuth
        if ($authDialog) {
            $TargetAuth.Type = $authDialog.Type
            $TargetAuth.Username = $authDialog.Username
            $TargetAuth.Password = $authDialog.Password
            $lblTargetAuth.Text = $TargetAuth.Type
        }
    })
    
    $btnTestSource.Add_Click({
        $lblTestResult.Text = "Testing source connection..."
        $lblTestResult.ForeColor = [System.Drawing.Color]::Blue
        
        $err = ""
        $success = Test-DatabaseConnection -Server $txtSourceServer.Text -Database $txtSourceDB.Text -AuthType $SourceAuth.Type -Username $SourceAuth.Username -Password $SourceAuth.Password -ErrorMessage ([ref]$err)
        
        if ($success) {
            $lblTestResult.ForeColor = [System.Drawing.Color]::Green
            $lblTestResult.Text = "Source connection: SUCCESS"
        } else {
            $lblTestResult.ForeColor = [System.Drawing.Color]::Red
            $lblTestResult.Text = "Source connection: FAILED`r`n$err"
        }
        
        # Check if both connections are working
        Test-BothConnections
    })
    
    $btnTestTarget.Add_Click({
        $lblTestResult.Text = "Testing target connection..."
        $lblTestResult.ForeColor = [System.Drawing.Color]::Blue
        
        $err = ""
        $success = Test-DatabaseConnection -Server $txtTargetServer.Text -Database $txtTargetDB.Text -AuthType $TargetAuth.Type -Username $TargetAuth.Username -Password $TargetAuth.Password -ErrorMessage ([ref]$err)
        
        if ($success) {
            $lblTestResult.ForeColor = [System.Drawing.Color]::Green
            $lblTestResult.Text = "Target connection: SUCCESS"
        } else {
            $lblTestResult.ForeColor = [System.Drawing.Color]::Red
            $lblTestResult.Text = "Target connection: FAILED`r`n$err"
        }
        
        # Check if both connections are working
        Test-BothConnections
    })
    
    $btnTestBoth.Add_Click({
        $lblTestResult.Text = "Testing both connections..."
        $lblTestResult.ForeColor = [System.Drawing.Color]::Blue
        
        # Test both connections
        Test-BothConnections
        
        if ($btnRun.Enabled) {
            $lblTestResult.ForeColor = [System.Drawing.Color]::Green
            $lblTestResult.Text = "Both connections: SUCCESS"
        } else {
            # Provide specific failures
            $srcErr = ""; $tgtErr = ""
            $srcOk = Test-DatabaseConnection -Server $txtSourceServer.Text -Database $txtSourceDB.Text -AuthType $SourceAuth.Type -Username $SourceAuth.Username -Password $SourceAuth.Password -ErrorMessage ([ref]$srcErr)
            $tgtOk = Test-DatabaseConnection -Server $txtTargetServer.Text -Database $txtTargetDB.Text -AuthType $TargetAuth.Type -Username $TargetAuth.Username -Password $TargetAuth.Password -ErrorMessage ([ref]$tgtErr)
            $msgParts = @()
            if (-not $srcOk) { $msgParts += "Source: $srcErr" }
            if (-not $tgtOk) { $msgParts += "Target: $tgtErr" }
            $detail = ($msgParts -join " | ")
            $lblTestResult.ForeColor = [System.Drawing.Color]::Red
            $lblTestResult.Text = "One or both connections: FAILED`r`n$detail"
        }
    })
    
    # Function to check if both connections are working
    function Test-BothConnections {
        $srcErr = ""; $tgtErr = ""
        $sourceSuccess = Test-DatabaseConnection -Server $txtSourceServer.Text -Database $txtSourceDB.Text -AuthType $SourceAuth.Type -Username $SourceAuth.Username -Password $SourceAuth.Password -ErrorMessage ([ref]$srcErr)
        $targetSuccess = Test-DatabaseConnection -Server $txtTargetServer.Text -Database $txtTargetDB.Text -AuthType $TargetAuth.Type -Username $TargetAuth.Username -Password $TargetAuth.Password -ErrorMessage ([ref]$tgtErr)
        
        if ($sourceSuccess -and $targetSuccess) {
            $btnRun.Enabled = $true
            $lblStatus.Text = "Both connections successful. Ready to run drift detection!"
            $lblStatus.ForeColor = [System.Drawing.Color]::Green
        } else {
            $btnRun.Enabled = $false
            $detail = @()
            if (-not $sourceSuccess) { $detail += "Source: $srcErr" }
            if (-not $targetSuccess) { $detail += "Target: $tgtErr" }
            $lblStatus.Text = "Please test both connections before running drift detection. " + ($detail -join " | ")
            $lblStatus.ForeColor = [System.Drawing.Color]::Orange
        }
    }
    
    $btnRun.Add_Click({
        if ($cmbScenario.SelectedIndex -lt 0) {
            [System.Windows.Forms.MessageBox]::Show("Please select a scenario first.", "No Scenario Selected", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        
        $selectedConfig = $script:Configurations[$cmbScenario.SelectedIndex]
        
        # Create temporary config with current credentials
        $tempConfig = @{
            databaseConfigurations = @(
                @{
                    name = $selectedConfig.name
                    description = $selectedConfig.description
                    sourceServer = $txtSourceServer.Text
                    sourceDatabase = $txtSourceDB.Text
                    targetServer = $txtTargetServer.Text
                    targetDatabase = $txtTargetDB.Text
                    authType = if ($SourceAuth.Type -eq $TargetAuth.Type) { $SourceAuth.Type } else { "Mixed" }
                    sourceAuthType = $SourceAuth.Type
                    targetAuthType = $TargetAuth.Type
                    sourceUsername = $SourceAuth.Username
                    sourcePassword = $SourceAuth.Password
                    targetUsername = $TargetAuth.Username
                    targetPassword = $TargetAuth.Password
                }
            )
        }
        
        # Save temporary config
        $tempConfigPath = "temp_config.json"
        $tempConfig | ConvertTo-Json -Depth 10 | Set-Content $tempConfigPath
        
        try {
            $lblStatus.Text = "Running drift detection..."
            $lblStatus.ForeColor = [System.Drawing.Color]::Blue
            
            # Run the drift detection script
            $process = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "DatabaseSchemaDriftDetection.ps1", "-ConfigFile", $tempConfigPath -Wait -PassThru -WindowStyle Hidden
            
            if ($process.ExitCode -eq 0) {
                $lblStatus.Text = "Drift detection completed successfully!"
                $lblStatus.ForeColor = [System.Drawing.Color]::Green
                
                # Open the report
                if (Test-Path "SchemaComparisonReport.html") {
                    Start-Process "SchemaComparisonReport.html"
                }
            } else {
                $lblStatus.Text = "Drift detection failed. Check console output."
                $lblStatus.ForeColor = [System.Drawing.Color]::Red
            }
        } catch {
            $lblStatus.Text = "Error running drift detection: $($_.Exception.Message)"
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
        } finally {
            # Clean up temporary config
            if (Test-Path $tempConfigPath) {
                Remove-Item $tempConfigPath -Force
            }
        }
    })
    
    $btnSave.Add_Click({
        if ($cmbScenario.SelectedIndex -lt 0) {
            [System.Windows.Forms.MessageBox]::Show("Please select a scenario first.", "No Scenario Selected", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        
        try {
            $selectedConfig = $script:Configurations[$cmbScenario.SelectedIndex]
            
            # Create a new configuration object to avoid modifying the original
            $newConfig = @{
                name = $selectedConfig.name
                description = $selectedConfig.description
                sourceServer = $txtSourceServer.Text
                sourceDatabase = $txtSourceDB.Text
                targetServer = $txtTargetServer.Text
                targetDatabase = $txtTargetDB.Text
            }
            
            if ($SourceAuth.Type -eq $TargetAuth.Type) {
                $newConfig.authType = $SourceAuth.Type
                # Don't add sourceAuthType and targetAuthType for single auth type
            } else {
                $newConfig.authType = "Mixed"
                $newConfig.sourceAuthType = $SourceAuth.Type
                $newConfig.targetAuthType = $TargetAuth.Type
            }
            
            # Only add username fields for SQL Auth, not passwords
            if ($SourceAuth.Type -eq "SqlAuth") {
                $newConfig.sourceUsername = $SourceAuth.Username
                # Don't save password
            }
            
            if ($TargetAuth.Type -eq "SqlAuth") {
                $newConfig.targetUsername = $TargetAuth.Username
                # Don't save password
            }
            
            # Replace the configuration in the array
            $script:Configurations[$cmbScenario.SelectedIndex] = $newConfig
            
            # Save the updated configuration
            $configToSave = @{
                databaseConfigurations = $script:Configurations
            }
            
            $configToSave | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath
            $lblStatus.Text = "Configuration saved successfully!"
            $lblStatus.ForeColor = [System.Drawing.Color]::Green
        } catch {
            $lblStatus.Text = "Error saving configuration: $($_.Exception.Message)"
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
        }
    })
    
    # Show the form
    $form.ShowDialog()
} else {
    [System.Windows.Forms.MessageBox]::Show("Failed to load configuration file. Please check the file path and format.", "Configuration Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}
