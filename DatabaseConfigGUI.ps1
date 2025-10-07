# Simple Database Configuration GUI
# Provides a Windows Forms interface for configuring database connections and running drift detection

param(
    [string]$ConfigPath = "config.json"
)

# Load Windows Forms
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Improve rendering on high-DPI/remote sessions
[System.Windows.Forms.Application]::EnableVisualStyles()

# Global variables
$script:Configurations = @()
$script:SelectedConfig = $null

function Import-Configurations {
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
    $authForm.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
    $authForm.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    
    # Auth type selection
    $lblAuthType = New-Object System.Windows.Forms.Label
    $lblAuthType.Text = "Authentication Type:"
    $lblAuthType.Location = New-Object System.Drawing.Point(20, 20)
    $lblAuthType.Size = New-Object System.Drawing.Size(120, 20)
    $lblAuthType.AutoSize = $true
    $lblAuthType.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $authForm.Controls.Add($lblAuthType)
    
    $cmbAuthType = New-Object System.Windows.Forms.ComboBox
    $cmbAuthType.Location = New-Object System.Drawing.Point(150, 18)
    $cmbAuthType.Size = New-Object System.Drawing.Size(200, 20)
    $cmbAuthType.DropDownStyle = "DropDownList"
    $cmbAuthType.Items.AddRange(@("TrustedConnection", "SqlAuth", "AzureAD"))
    $cmbAuthType.SelectedItem = $CurrentAuth.Type
    $cmbAuthType.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
    $cmbAuthType.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $cmbAuthType.FlatStyle = 'Flat'
    $authForm.Controls.Add($cmbAuthType)
    
    # Username (for SQL Auth)
    $lblUsername = New-Object System.Windows.Forms.Label
    $lblUsername.Text = "Username:"
    $lblUsername.Location = New-Object System.Drawing.Point(20, 50)
    $lblUsername.Size = New-Object System.Drawing.Size(120, 20)
    $lblUsername.AutoSize = $true
    $lblUsername.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $authForm.Controls.Add($lblUsername)
    
    $txtUsername = New-Object System.Windows.Forms.TextBox
    $txtUsername.Text = $CurrentAuth.Username
    $txtUsername.Location = New-Object System.Drawing.Point(150, 48)
    $txtUsername.Size = New-Object System.Drawing.Size(200, 20)
    $txtUsername.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $txtUsername.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $txtUsername.BorderStyle = 'FixedSingle'
    $authForm.Controls.Add($txtUsername)
    
    # Password (for SQL Auth)
    $lblPassword = New-Object System.Windows.Forms.Label
    $lblPassword.Text = "Password:"
    $lblPassword.Location = New-Object System.Drawing.Point(20, 80)
    $lblPassword.Size = New-Object System.Drawing.Size(120, 20)
    $lblPassword.AutoSize = $true
    $lblPassword.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $authForm.Controls.Add($lblPassword)
    
    $txtPassword = New-Object System.Windows.Forms.TextBox
    $txtPassword.UseSystemPasswordChar = $true
    $txtPassword.Location = New-Object System.Drawing.Point(150, 78)
    $txtPassword.Size = New-Object System.Drawing.Size(200, 20)
    $txtPassword.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $txtPassword.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $txtPassword.BorderStyle = 'FixedSingle'
    $authForm.Controls.Add($txtPassword)

    # Enable/disable username/password by auth type
    $updateAuthInputs = {
        $isSql = ($cmbAuthType.SelectedItem -eq 'SqlAuth')
        $txtUsername.Enabled = $isSql
        $txtPassword.Enabled = $isSql
        $lblUsername.Enabled = $isSql
        $lblPassword.Enabled = $isSql
    }
    $cmbAuthType.add_SelectedIndexChanged($updateAuthInputs)
    & $updateAuthInputs
    
    # OK button
    $btnOK = New-Object System.Windows.Forms.Button
    $btnOK.Text = "OK"
    $btnOK.Location = New-Object System.Drawing.Point(200, 120)
    $btnOK.Size = New-Object System.Drawing.Size(75, 30)
    $btnOK.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnOK.FlatStyle = 'Flat'
    $btnOK.BackColor = [System.Drawing.Color]::FromArgb(0,122,204)
    $btnOK.ForeColor = [System.Drawing.Color]::White
    $btnOK.FlatAppearance.BorderSize = 0
    $authForm.AcceptButton = $btnOK
    $authForm.Controls.Add($btnOK)
    
    # Cancel button
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(280, 120)
    $btnCancel.Size = New-Object System.Drawing.Size(75, 30)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.FlatStyle = 'Flat'
    $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $btnCancel.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $btnCancel.FlatAppearance.BorderSize = 0
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
if (Import-Configurations) {
    # Create the main form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Database Schema Drift Detection - Configuration"
    $form.Size = New-Object System.Drawing.Size(700, 600)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $true
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96,96)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
    $form.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    
    # Title
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Database Schema Drift Detection"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(0,122,204)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 18)
    $lblTitle.Size = New-Object System.Drawing.Size(500, 28)
    $lblTitle.AutoSize = $true
    $lblTitle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $form.Controls.Add($lblTitle)
    
    # Scenario selection
    $lblScenario = New-Object System.Windows.Forms.Label
    $lblScenario.Text = "Select Scenario:"
    $lblScenario.Location = New-Object System.Drawing.Point(20, 60)
    $lblScenario.Size = New-Object System.Drawing.Size(100, 20)
    $lblScenario.AutoSize = $true
    $lblScenario.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $lblScenario.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    $form.Controls.Add($lblScenario)
    
    $cmbScenario = New-Object System.Windows.Forms.ComboBox
    $cmbScenario.Location = New-Object System.Drawing.Point(150, 58)
    $cmbScenario.Size = New-Object System.Drawing.Size(500, 20)
    $cmbScenario.DropDownStyle = "DropDownList"
    $cmbScenario.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $cmbScenario.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $cmbScenario.FlatStyle = 'Flat'
    $cmbScenario.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $form.Controls.Add($cmbScenario)
    
    # Populate scenarios
    foreach ($config in $script:Configurations) {
        $cmbScenario.Items.Add("$($config.name) - $($config.description)")
    }
    
    # Source Server Group
    $grpSource = New-Object System.Windows.Forms.GroupBox
    $grpSource.Text = "Source Database"
    $grpSource.Location = New-Object System.Drawing.Point(50, 100)
    $grpSource.Size = New-Object System.Drawing.Size(270, 120)
    $grpSource.ForeColor = [System.Drawing.Color]::FromArgb(0,122,204)
    $grpSource.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $form.Controls.Add($grpSource)
    
    $lblSourceServer = New-Object System.Windows.Forms.Label
    $lblSourceServer.Text = "Server:"
    $lblSourceServer.Location = New-Object System.Drawing.Point(10, 25)
    $lblSourceServer.Size = New-Object System.Drawing.Size(60, 20)
    $lblSourceServer.AutoSize = $true
    $lblSourceServer.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $grpSource.Controls.Add($lblSourceServer)
    
    $txtSourceServer = New-Object System.Windows.Forms.TextBox
    $txtSourceServer.Location = New-Object System.Drawing.Point(80, 23)
    $txtSourceServer.Size = New-Object System.Drawing.Size(150, 20)
    $txtSourceServer.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $txtSourceServer.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $txtSourceServer.BorderStyle = 'FixedSingle'
    $txtSourceServer.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grpSource.Controls.Add($txtSourceServer)
    
    $lblSourceDB = New-Object System.Windows.Forms.Label
    $lblSourceDB.Text = "Database:"
    $lblSourceDB.Location = New-Object System.Drawing.Point(10, 50)
    $lblSourceDB.Size = New-Object System.Drawing.Size(60, 20)
    $lblSourceDB.AutoSize = $true
    $lblSourceDB.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $grpSource.Controls.Add($lblSourceDB)
    
    $txtSourceDB = New-Object System.Windows.Forms.TextBox
    $txtSourceDB.Location = New-Object System.Drawing.Point(80, 48)
    $txtSourceDB.Size = New-Object System.Drawing.Size(150, 20)
    $txtSourceDB.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $txtSourceDB.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $txtSourceDB.BorderStyle = 'FixedSingle'
    $txtSourceDB.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grpSource.Controls.Add($txtSourceDB)
    
    $btnSourceAuth = New-Object System.Windows.Forms.Button
    $btnSourceAuth.Text = "Configure Auth"
    $btnSourceAuth.Location = New-Object System.Drawing.Point(10, 80)
    $btnSourceAuth.Size = New-Object System.Drawing.Size(100, 25)
    $btnSourceAuth.FlatStyle = 'Flat'
    $btnSourceAuth.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $btnSourceAuth.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $btnSourceAuth.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(63,63,70)
    $grpSource.Controls.Add($btnSourceAuth)
    
    $lblSourceAuth = New-Object System.Windows.Forms.Label
    $lblSourceAuth.Text = "Windows Auth"
    $lblSourceAuth.Location = New-Object System.Drawing.Point(120, 85)
    $lblSourceAuth.Size = New-Object System.Drawing.Size(100, 20)
    $lblSourceAuth.AutoSize = $true
    $lblSourceAuth.ForeColor = [System.Drawing.Color]::FromArgb(180,180,180)
    $grpSource.Controls.Add($lblSourceAuth)
    
    # Target Server Group
    $grpTarget = New-Object System.Windows.Forms.GroupBox
    $grpTarget.Text = "Target Database"
    $grpTarget.Location = New-Object System.Drawing.Point(370, 100)
    $grpTarget.Size = New-Object System.Drawing.Size(270, 120)
    $grpTarget.ForeColor = [System.Drawing.Color]::FromArgb(0,122,204)
    $grpTarget.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $form.Controls.Add($grpTarget)
    
    $lblTargetServer = New-Object System.Windows.Forms.Label
    $lblTargetServer.Text = "Server:"
    $lblTargetServer.Location = New-Object System.Drawing.Point(10, 25)
    $lblTargetServer.Size = New-Object System.Drawing.Size(60, 20)
    $lblTargetServer.AutoSize = $true
    $lblTargetServer.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $grpTarget.Controls.Add($lblTargetServer)
    
    $txtTargetServer = New-Object System.Windows.Forms.TextBox
    $txtTargetServer.Location = New-Object System.Drawing.Point(80, 23)
    $txtTargetServer.Size = New-Object System.Drawing.Size(150, 20)
    $txtTargetServer.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $txtTargetServer.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $txtTargetServer.BorderStyle = 'FixedSingle'
    $txtTargetServer.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grpTarget.Controls.Add($txtTargetServer)
    
    $lblTargetDB = New-Object System.Windows.Forms.Label
    $lblTargetDB.Text = "Database:"
    $lblTargetDB.Location = New-Object System.Drawing.Point(10, 50)
    $lblTargetDB.Size = New-Object System.Drawing.Size(60, 20)
    $lblTargetDB.AutoSize = $true
    $lblTargetDB.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $grpTarget.Controls.Add($lblTargetDB)
    
    $txtTargetDB = New-Object System.Windows.Forms.TextBox
    $txtTargetDB.Location = New-Object System.Drawing.Point(80, 48)
    $txtTargetDB.Size = New-Object System.Drawing.Size(150, 20)
    $txtTargetDB.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $txtTargetDB.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $txtTargetDB.BorderStyle = 'FixedSingle'
    $txtTargetDB.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $grpTarget.Controls.Add($txtTargetDB)
    
    $btnTargetAuth = New-Object System.Windows.Forms.Button
    $btnTargetAuth.Text = "Configure Auth"
    $btnTargetAuth.Location = New-Object System.Drawing.Point(10, 80)
    $btnTargetAuth.Size = New-Object System.Drawing.Size(100, 25)
    $btnTargetAuth.FlatStyle = 'Flat'
    $btnTargetAuth.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $btnTargetAuth.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $btnTargetAuth.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(63,63,70)
    $grpTarget.Controls.Add($btnTargetAuth)
    
    $lblTargetAuth = New-Object System.Windows.Forms.Label
    $lblTargetAuth.Text = "Windows Auth"
    $lblTargetAuth.Location = New-Object System.Drawing.Point(120, 85)
    $lblTargetAuth.Size = New-Object System.Drawing.Size(100, 20)
    $lblTargetAuth.AutoSize = $true
    $lblTargetAuth.ForeColor = [System.Drawing.Color]::FromArgb(180,180,180)
    $grpTarget.Controls.Add($lblTargetAuth)
    
    # Test Connection Group
    $grpTest = New-Object System.Windows.Forms.GroupBox
    $grpTest.Text = "Connection Test"
    $grpTest.Location = New-Object System.Drawing.Point(20, 240)
    $grpTest.Size = New-Object System.Drawing.Size(640, 120)
    $grpTest.ForeColor = [System.Drawing.Color]::FromArgb(0,122,204)
    $grpTest.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $form.Controls.Add($grpTest)
    
    $btnTestSource = New-Object System.Windows.Forms.Button
    $btnTestSource.Text = "Test Source"
    $btnTestSource.Location = New-Object System.Drawing.Point(10, 30)
    $btnTestSource.Size = New-Object System.Drawing.Size(100, 30)
    $btnTestSource.FlatStyle = 'Flat'
    $btnTestSource.FlatAppearance.BorderSize = 1
    $btnTestSource.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(63,63,70)
    $btnTestSource.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $btnTestSource.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $grpTest.Controls.Add($btnTestSource)
    
    $btnTestTarget = New-Object System.Windows.Forms.Button
    $btnTestTarget.Text = "Test Target"
    $btnTestTarget.Location = New-Object System.Drawing.Point(120, 30)
    $btnTestTarget.Size = New-Object System.Drawing.Size(100, 30)
    $btnTestTarget.FlatStyle = 'Flat'
    $btnTestTarget.FlatAppearance.BorderSize = 1
    $btnTestTarget.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(63,63,70)
    $btnTestTarget.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $btnTestTarget.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $grpTest.Controls.Add($btnTestTarget)
    
    $btnTestBoth = New-Object System.Windows.Forms.Button
    $btnTestBoth.Text = "Test Both"
    $btnTestBoth.Location = New-Object System.Drawing.Point(230, 30)
    $btnTestBoth.Size = New-Object System.Drawing.Size(100, 30)
    $btnTestBoth.FlatStyle = 'Flat'
    $btnTestBoth.FlatAppearance.BorderSize = 1
    $btnTestBoth.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(63,63,70)
    $btnTestBoth.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $btnTestBoth.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $grpTest.Controls.Add($btnTestBoth)
    
    $lblTestResult = New-Object System.Windows.Forms.TextBox
    $lblTestResult.Multiline = $true
    $lblTestResult.ReadOnly = $true
    $lblTestResult.BorderStyle = 'FixedSingle'
    $lblTestResult.BackColor = [System.Drawing.Color]::FromArgb(37,37,38)
    $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $lblTestResult.Location = New-Object System.Drawing.Point(350, 20)
    $lblTestResult.Size = New-Object System.Drawing.Size(270, 80)
    $lblTestResult.ScrollBars = 'Vertical'
    $grpTest.Controls.Add($lblTestResult)
    
    # Multi-Page Mode Checkbox
    $chkMultiPage = New-Object System.Windows.Forms.CheckBox
    $chkMultiPage.Text = "Multi-Page Mode (Split large reports into separate files)"
    $chkMultiPage.Location = New-Object System.Drawing.Point(20, 370)
    $chkMultiPage.Size = New-Object System.Drawing.Size(520, 25)
    $chkMultiPage.AutoSize = $false
    $chkMultiPage.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $form.Controls.Add($chkMultiPage)
    
    # Export to Excel Checkbox
    $chkExportExcel = New-Object System.Windows.Forms.CheckBox
    $chkExportExcel.Text = "Export to Excel (direct, no browser)"
    $chkExportExcel.Location = New-Object System.Drawing.Point(20, 395)
    $chkExportExcel.Size = New-Object System.Drawing.Size(520, 25)
    $chkExportExcel.AutoSize = $false
    $chkExportExcel.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $form.Controls.Add($chkExportExcel)

    # Generate CLI Command button
    $btnGenerateCli = New-Object System.Windows.Forms.Button
    $btnGenerateCli.Text = "Generate CLI Command"
    # Move Generate CLI button near action buttons row
    $btnGenerateCli.Location = New-Object System.Drawing.Point(440, 385)
    $btnGenerateCli.Size = New-Object System.Drawing.Size(180, 40)
    $btnGenerateCli.FlatStyle = 'Flat'
    # Professional accent (VS blue)
    $btnGenerateCli.BackColor = [System.Drawing.Color]::FromArgb(0,122,204)
    $btnGenerateCli.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(0,102,184)
    $btnGenerateCli.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(0,82,154)
    $btnGenerateCli.ForeColor = [System.Drawing.Color]::White
    $btnGenerateCli.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $btnGenerateCli.FlatAppearance.BorderSize = 1
    $btnGenerateCli.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(63,63,70)
    $btnGenerateCli.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    $form.Controls.Add($btnGenerateCli)

    $btnGenerateCli.Add_Click({
        try {
            # Build CLI command with direct parameters
            $switches = @()
            if ($chkMultiPage.Checked) { $switches += "-MultiPage" }
            if ($chkExportExcel.Checked) { $switches += "-ExportExcel" }
            $switchText = ($switches -join ' ')
            # Always emit direct-parameter CLI; include auth flags when not TrustedConnection
            if ($true) {
                $psCmd = @"
powershell -NoProfile -ExecutionPolicy Bypass -File .\DatabaseSchemaDriftDetection.ps1 -SourceServer "{0}" -SourceDatabase "{1}" -TargetServer "{2}" -TargetDatabase "{3}" {4}
"@ -f $txtSourceServer.Text, $txtSourceDB.Text, $txtTargetServer.Text, $txtTargetDB.Text, $switchText
                # Append auth parameters if provided
                $authParts = @()
                if ($SourceAuth.Type -and $SourceAuth.Type -ne 'TrustedConnection') {
                    $authParts += ('-SourceAuthType "{0}"' -f $SourceAuth.Type)
                    if ($SourceAuth.Username) { $authParts += ('-SourceUsername "{0}"' -f $SourceAuth.Username) }
                    if ($SourceAuth.Password) { $authParts += ('-SourcePassword "{0}"' -f $SourceAuth.Password) }
                }
                if ($TargetAuth.Type -and $TargetAuth.Type -ne 'TrustedConnection') {
                    $authParts += ('-TargetAuthType "{0}"' -f $TargetAuth.Type)
                    if ($TargetAuth.Username) { $authParts += ('-TargetUsername "{0}"' -f $TargetAuth.Username) }
                    if ($TargetAuth.Password) { $authParts += ('-TargetPassword "{0}"' -f $TargetAuth.Password) }
                }
                if ($authParts.Count -gt 0) {
                    $psCmd = ($psCmd.TrimEnd()) + ' ' + ($authParts -join ' ')
                }
                $lblTestResult.Text = $psCmd
            }
            $lblStatus.Text = "CLI command generated. Copy from the textbox above."
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(106,153,85)
        } catch {
            $lblStatus.Text = "Failed to generate CLI command: $($_.Exception.Message)"
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(244,71,71)
        }
    })

    # Read UI visibility config from conf.ini (optional)
    $iniPath = Join-Path (Get-Location) 'conf.ini'
    $ini = @{}
    if (Test-Path $iniPath) {
        try {
            Get-Content $iniPath | ForEach-Object {
                $line = $_.Trim()
                if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { return }
                $kv = $line -split '=', 2
                if ($kv.Count -eq 2) { $ini[$kv[0].Trim()] = $kv[1].Trim() }
            }
        } catch { }
    }
    if ($ini.ContainsKey('ShowMultiPage')) {
        $show = $ini['ShowMultiPage']
        if ([string]::IsNullOrEmpty($show) -or $show.ToLower() -in @('0','false','no','off')) {
            $chkMultiPage.Visible = $false
        }
    }
    if ($ini.ContainsKey('ShowExportExcel')) {
        $show = $ini['ShowExportExcel']
        if ([string]::IsNullOrEmpty($show) -or $show.ToLower() -in @('0','false','no','off')) {
            $chkExportExcel.Visible = $false
        }
    }
    if ($ini.ContainsKey('ShowGenerateCLI')) {
        $show = $ini['ShowGenerateCLI']
        if ([string]::IsNullOrEmpty($show) -or $show.ToLower() -in @('0','false','no','off')) {
            $btnGenerateCli.Visible = $false
        }
    }
    
    # Add event handlers for checkbox interactions
    $chkExportExcel.Add_CheckedChanged({
        if ($chkExportExcel.Checked) {
            $chkMultiPage.Enabled = $false
            $chkMultiPage.ForeColor = [System.Drawing.Color]::FromArgb(100,100,100)
        } else {
            $chkMultiPage.Enabled = $true
            $chkMultiPage.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
        }
    })
    
    $chkMultiPage.Add_CheckedChanged({
        if ($chkMultiPage.Checked) {
            $chkExportExcel.Enabled = $false
            $chkExportExcel.ForeColor = [System.Drawing.Color]::FromArgb(100,100,100)
        } else {
            $chkExportExcel.Enabled = $true
            $chkExportExcel.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
        }
    })
    
    # Action Buttons
    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "Run Drift Detection"
    $btnRun.Location = New-Object System.Drawing.Point(20, 385)
    $btnRun.Size = New-Object System.Drawing.Size(150, 40)
    $btnRun.Enabled = $false
    $btnRun.FlatStyle = 'Flat'
    $btnRun.FlatAppearance.BorderSize = 0
    $btnRun.BackColor = [System.Drawing.Color]::FromArgb(0,122,204)
    $btnRun.ForeColor = [System.Drawing.Color]::White
    $btnRun.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    $form.Controls.Add($btnRun)
    
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save Configuration"
    $btnSave.Location = New-Object System.Drawing.Point(180, 385)
    $btnSave.Size = New-Object System.Drawing.Size(150, 40)
    $btnSave.FlatStyle = 'Flat'
    $btnSave.FlatAppearance.BorderSize = 1
    $btnSave.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(63,63,70)
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $btnSave.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $btnSave.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    $form.Controls.Add($btnSave)
    
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(340, 385)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 40)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnCancel.FlatStyle = 'Flat'
    $btnCancel.FlatAppearance.BorderSize = 1
    $btnCancel.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(63,63,70)
    $btnCancel.BackColor = [System.Drawing.Color]::FromArgb(51,51,55)
    $btnCancel.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
    $btnCancel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    $form.Controls.Add($btnCancel)
    
    # Uniform button layout helper
    function Set-ActionButtonsLayout {
        param([int]$y)
        $leftMargin = 20
        $rightMargin = 20
        $gap = 20
        $x = $leftMargin
        $btnRun.Location = New-Object System.Drawing.Point($x, $y)
        $x += $btnRun.Width + $gap
        $btnSave.Location = New-Object System.Drawing.Point($x, $y)
        $x += $btnSave.Width + $gap
        $btnCancel.Location = New-Object System.Drawing.Point($x, $y)
        $x += $btnCancel.Width + $gap
        # Clamp to keep right margin
        $maxX = $form.ClientSize.Width - $rightMargin - $btnGenerateCli.Width
        if ($x -gt $maxX) { $x = $maxX }
        $btnGenerateCli.Location = New-Object System.Drawing.Point($x, $y)
    }
    # Initial placement and keep aligned on resize
    Set-ActionButtonsLayout -y 435
    $form.Add_SizeChanged({ Set-ActionButtonsLayout -y 435 })

    # Status label
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Select a scenario to begin"
    $lblStatus.Location = New-Object System.Drawing.Point(20, 495)
    $lblStatus.Size = New-Object System.Drawing.Size(520, 40)
    $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(0,122,204)
    $lblStatus.AutoSize = $true
    $lblStatus.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
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
                $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
                $btnRun.Enabled = $true
            } catch {
                $lblStatus.Text = "Error loading configuration: $($_.Exception.Message)"
                $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(244,71,71)
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
        $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(78,201,176)
        
        $err = ""
        $success = Test-DatabaseConnection -Server $txtSourceServer.Text -Database $txtSourceDB.Text -AuthType $SourceAuth.Type -Username $SourceAuth.Username -Password $SourceAuth.Password -ErrorMessage ([ref]$err)
        
        if ($success) {
            $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(106,153,85)
            $lblTestResult.Text = "Source connection: SUCCESS"
        } else {
            $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(244,71,71)
            $lblTestResult.Text = "Source connection: FAILED`r`n$err"
        }
        
        # Check if both connections are working
        Test-BothConnections
    })
    
    $btnTestTarget.Add_Click({
        $lblTestResult.Text = "Testing target connection..."
        $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(78,201,176)
        
        $err = ""
        $success = Test-DatabaseConnection -Server $txtTargetServer.Text -Database $txtTargetDB.Text -AuthType $TargetAuth.Type -Username $TargetAuth.Username -Password $TargetAuth.Password -ErrorMessage ([ref]$err)
        
        if ($success) {
            $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(106,153,85)
            $lblTestResult.Text = "Target connection: SUCCESS"
        } else {
            $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(244,71,71)
            $lblTestResult.Text = "Target connection: FAILED`r`n$err"
        }
        
        # Check if both connections are working
        Test-BothConnections
    })
    
    $btnTestBoth.Add_Click({
        $lblTestResult.Text = "Testing both connections..."
        $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(78,201,176)
        
        # Test both connections
        Test-BothConnections
        
        if ($btnRun.Enabled) {
            $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(106,153,85)
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
            $lblTestResult.ForeColor = [System.Drawing.Color]::FromArgb(244,71,71)
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
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(106,153,85)
        } else {
            $btnRun.Enabled = $false
            $detail = @()
            if (-not $sourceSuccess) { $detail += "Source: $srcErr" }
            if (-not $targetSuccess) { $detail += "Target: $tgtErr" }
            $lblStatus.Text = "Please test both connections before running drift detection. " + ($detail -join " | ")
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(206,145,120)
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
        
        # Update status before blocking operation
        $lblStatus.Text = "Preparing configuration..."
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(78,201,176)
        $lblStatus.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        
        # Write JSON (this happens quickly but we've already updated UI)
        $tempConfig | ConvertTo-Json -Depth 10 -Compress | Set-Content $tempConfigPath -Force
        
        try {
            $lblStatus.Text = "Running drift detection..."
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(78,201,176)
            $lblStatus.Refresh()
            [System.Windows.Forms.Application]::DoEvents()
            
            # Run the drift detection script
            Write-Host "Temp config path: $tempConfigPath" -ForegroundColor Cyan
            
            # Set environment variable
            $env:LAUNCHED_FROM_GUI = 1
            
            # Build parameters
            $scriptParams = @{
                ConfigFile = $tempConfigPath
            }
            if ($chkMultiPage.Checked) {
                $scriptParams.MultiPage = $true
            }
            if ($chkExportExcel.Checked) {
                $scriptParams.ExportExcel = $true
            }
            
            Write-Host "Running drift detection..." -ForegroundColor Cyan
            
            # Run the script in the same session
            $exitCode = 0
            try {
                & '.\DatabaseSchemaDriftDetection.ps1' @scriptParams
                $exitCode = $LASTEXITCODE
                if ($null -eq $exitCode) { $exitCode = 0 }
            } catch {
                Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
                $exitCode = 1
            }
            
            Write-Host "Exit code: $exitCode" -ForegroundColor Yellow
            
            if ($exitCode -eq 0) {
                $lblStatus.Text = "Drift detection completed successfully!"
                $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(106,153,85)
                
                # Open the report based on mode
                if ($chkExportExcel.Checked) {
                    # Excel mode: Direct export using ImportExcel (no browser)
                    # Find the most recent Excel file
                    $excelFiles = Get-ChildItem -Path "." -Filter "SchemaComparisonReport_*.xlsx" | Sort-Object LastWriteTime -Descending
                    if ($excelFiles.Count -gt 0) {
                        $excelFile = $excelFiles[0]
                        Start-Process $excelFile.FullName
                        $lblStatus.Text = "Excel file created and opened: $($excelFile.Name)"
                        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(106,153,85)
                        Write-Host "`nExcel report opened: $($excelFile.Name)" -ForegroundColor Green
                    } else {
                        $lblStatus.Text = "Excel export completed but file not found"
                        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(244,71,71)
                    }
                } elseif ($chkMultiPage.Checked) {
                    # Multi-page mode: Open from latest directory
                    $multiPageDirs = Get-ChildItem -Path "." -Filter "*_SchemaComparison" -Directory | Sort-Object LastWriteTime -Descending
                    $multiPageIndex = $multiPageDirs | Select-Object -First 1
                    if ($multiPageIndex -and (Test-Path "$($multiPageIndex.FullName)\index.html")) {
                        Start-Process "$($multiPageIndex.FullName)\index.html"
                    }
                } else {
                    # Single page mode: Always open SchemaComparisonReport.html from current directory
                    $singlePageReport = "SchemaComparisonReport.html"
                    $fullPath = Join-Path (Get-Location) $singlePageReport
                    if (Test-Path $fullPath) {
                        Start-Process $fullPath
                    } else {
                        [System.Windows.Forms.MessageBox]::Show("Report file not found: $fullPath", "File Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                    }
                }
            } else {
                $lblStatus.Text = "Drift detection failed. Check console output."
                $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(244,71,71)
            }
        } catch {
            $lblStatus.Text = "Error running drift detection: $($_.Exception.Message)"
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(244,71,71)
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
            
            # Update UI before blocking operation
            $lblStatus.Text = "Saving configuration..."
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(78,201,176)
            $lblStatus.Refresh()
            [System.Windows.Forms.Application]::DoEvents()
            
            # Disable the save button temporarily to prevent double-clicks
            $btnSave.Enabled = $false
            
            # Write JSON asynchronously using a background job
            $saveJob = Start-Job -ScriptBlock {
                param($config, $path)
                $config | ConvertTo-Json -Depth 10 | Set-Content $path -Force
            } -ArgumentList $configToSave, $ConfigPath
            
            # Wait for job completion with UI updates
            while ($saveJob.State -eq 'Running') {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 50
            }
            
            # Get job results and clean up
            $saveJob | Wait-Job | Out-Null
            $saveJob | Remove-Job
            
            # Re-enable the save button
            $btnSave.Enabled = $true
            
            $lblStatus.Text = "Configuration saved successfully!"
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(106,153,85)
            $lblStatus.Refresh()
        } catch {
            $lblStatus.Text = "Error saving configuration: $($_.Exception.Message)"
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(244,71,71)
        }
    })
    
    # Show the form
    $form.ShowDialog()
} else {
    [System.Windows.Forms.MessageBox]::Show("Failed to load configuration file. Please check the file path and format.", "Configuration Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}
