# Step 1: Define Constants
$MODULES = @("Az.Accounts", "Az.Automation", "Az.Resources")  # Required modules
$MAX_RETRIES = 3                                              # Maximum retry attempts
$DELAY_SECONDS = 5                                            # Delay between retries
$TABLE_STYLE = "border='1' style='border-collapse:collapse;'" # HTML table styling
$DAYS_WARNING_THRESHOLD = 30                                  # Warning threshold for days
$ErrorActionPreference = "Stop"                               # Ensures errors trigger the catch block
$HTML_INTRO = @"
<p>This is an automated notification for <b>Azure Key Vault Secrets</b> and their <b>expiration status</b>.</p>
"@

$HTML_COLUMN_DESCRIPTION = @"
<p>Below is a summary report and column definitions for reference:</p>
<ul>
    <li><b>Secret Name</b>: The name of the secret stored in Azure Key Vault.</li>
    <li><b>Expiration Date</b>: The date on which the secret is set to expire.</li>
    <li><b>Days Until Expire</b>: Number of days remaining until the secret expires. Negative values indicate expired secrets. Days less than <b>$DAYS_WARNING_THRESHOLD</b> are highlighted in orange.</li>
    <li><b>Status</b>: The current status of the secret (Active, Expiring Soon, or Expired).</li>
</ul>
<p><b>Action Required:</b></p>
<ul>
    <li>Renew or replace expired secrets (those with negative values in the "Days Until Expire" column).</li>
    <li>Monitor upcoming expirations and take timely actions to avoid disruptions in services depending on these secrets.</li>
</ul>
"@

$HTML_CLOSING = @"
<p>If you have any questions or need assistance, please contact the <b>DevOps</b> team.</p>
"@


# Step 2: Import Required Modules
Write-Output "Checking and importing required modules..."
foreach ($module in $MODULES) {
    if (-not (Get-Module -Name $module -ErrorAction SilentlyContinue)) {
        try {
            if (-not (Get-Module -Name $module -ListAvailable)) {
                Write-Output "Installing module '$module'..."
                Install-Module -Name $module -Scope CurrentUser -Force
            }
            Import-Module -Name $module -Force
            Write-Output "Module '$module' imported successfully."
        } catch {
            Write-Error "Failed to import/install module '$module'. Error: $_"
            exit 1
        }
    }
}


$vaultName = Get-AutomationVariable -Name 'VaultName'

# Step 3: Set Up Environment Configuration Variables
$environmentConfiguration = @{
    LogicAppUrl               = "WebhookCredExpiryLogicAppURL"  # Variable for Logic App Service Principal
    servicePrincipalId        = "servicePrincipalId"
    servicePrincipalSecret    = "servicePrincipalSecret"
    TenantIdKey               = "tenantId"
    VaultNameKey              = "VaultName"
    Environment               = "Environment"
}

# Step 4: Fetch the Logic App Service Principal URL from Automation Variables
$logicAppUrl = Get-AutomationVariable -Name $environmentConfiguration.LogicAppUrl

# Step 5: Authenticate with Service Principal

try {
    Write-Output "Authenticating with Service Principal..."

    # Retrieve Service Principal Credentials
    $applicationid = Get-AutomationVariable -Name $environmentConfiguration.servicePrincipalId
    $secretKey = Get-AutomationVariable -Name $environmentConfiguration.servicePrincipalSecret
    $tenantID = Get-AutomationVariable -Name $environmentConfiguration.TenantIdKey

    $password = ConvertTo-SecureString -String $secretKey -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($applicationid, $password)

    # Connect using Service Principal
    Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $tenantID
    Write-Output "Service principal connected successfully!"

} catch {
    Write-Output "Authentication failed: $($_.Exception.Message)"
    exit
}

# Step 6: Process Key Vault Secrets that HAVE an Expiration Date
Write-Output "Fetching Key Vault secret expirations..."
$secretDetails = @()

try {
    $secrets = Get-AzKeyVaultSecret -VaultName $vaultName

    foreach ($secret in $secrets) {
        # Fetch full secret details to access Attributes correctly
        $fullSecret = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secret.Name
        $expiry = $fullSecret.Attributes.Expires

        Write-Output "Checking expiration for secret '$($fullSecret.Name)'"
        Write-Output "Raw expiration value: $expiry"

        if (-not $expiry) {
            Write-Output "Skipping secret '$($fullSecret.Name)' — no expiration date set."
            continue
        }

        $today = Get-Date
        $daysLeft = ($expiry - $today).Days

        $status = if ($daysLeft -lt 0) { "Expired" }
                  elseif ($daysLeft -le $DAYS_WARNING_THRESHOLD) { "Expiring Soon" }
                  else { "Active" }

        $secretDetails += [PSCustomObject]@{
            SecretName      = $fullSecret.Name
            Type            = "Secret"
            ExpirationDate  = $expiry.ToString("yyyy-MM-dd")
            DaysUntilExpire = $daysLeft
            Status          = $status
        }

        if ($daysLeft -lt 0) {
            Write-Output "Added secret '$($fullSecret.Name)' — expired $(-$daysLeft) days ago."
        }
        else {
            Write-Output "Added secret '$($fullSecret.Name)' — expires in $daysLeft days."
        }
    }

    # Optional: Export results
    if ($secretDetails.Count -gt 0) {
        $secretDetails | Format-Table -AutoSize
    } else {
        Write-Output "No secrets with expiration dates found."
    }

} catch {
    Write-Error "Error retrieving secrets from Key Vault '$vaultName'. Error: $_"
}

# Step 7: Generate HTML Table for Key Vault Secrets Only if Data Exists
if ($secretDetails -and $secretDetails.Count -gt 0) {
    Write-Output "Generating HTML table for Key Vault Secrets..."
    $HtmlTable = "<table $TABLE_STYLE>
    <tr>
        <th style='color:blue;'>Secret Name</th>
        <th style='color:blue;'>Expiration Date</th>
        <th style='color:blue;'>Days Until Expire</th>
        <th style='color:blue;'>Status</th>
    </tr>"

    foreach ($secret in $secretDetails) {
        # Conditional formatting for DaysUntilExpire
        $formattedDays = if ($secret.DaysUntilExpire -lt 0) {
            "<b style='color:red;'>$($secret.DaysUntilExpire)</b>"
        } elseif ($secret.DaysUntilExpire -le $DAYS_WARNING_THRESHOLD) {
            "<b style='color:orange;'>$($secret.DaysUntilExpire)</b>"
        } else {
            "$($secret.DaysUntilExpire)"
        }

        # Conditional formatting for Status
        $formattedStatus = switch ($secret.Status) {
            "Expired"       { "<b style='color:red;'>$($secret.Status)</b>" }
            "Expiring Soon" { "<b style='color:orange;'>$($secret.Status)</b>" }
            default         { "<b style='color:green;'>$($secret.Status)</b>" }
        }

        $HtmlTable += "<tr>
            <td>$($secret.SecretName)</td>
            <td style='text-align:center;'>$($secret.ExpirationDate)</td>
            <td style='text-align:center;'>$formattedDays</td>
            <td style='text-align:center;'>$formattedStatus</td>
        </tr>"
    }

    $HtmlTable += "</table>"
    Write-Output "HTML table for Key Vault Secrets generated successfully."
} else {
    Write-Output "No secrets with expiration details found. Skipping HTML table generation."
}


#Step 8: ================= Construct Email Body =================
$EmailBody = "$HTML_INTRO<br><br>$HTML_COLUMN_DESCRIPTION<br><br>$HtmlTable<br><br>$HTML_CLOSING"
Write-Output "Email body constructed successfully."

# Step 9: Retry Logic for Logic App Call
function Invoke-With-Retry {
    param (
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = $MAX_RETRIES,
        [int]$DelaySeconds = $DELAY_SECONDS
    )
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            return & $ScriptBlock
        } catch {
            Write-Warning "Attempt $i failed: $_.Exception.Message. Retrying in $DelaySeconds seconds..."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    throw "All $MaxRetries attempts failed."
}
# If the variable is not set, default to "Dev"
if (-not $Environment) { 
    $Environment = "Dev" 
}

Write-Output "Current Environment: $Environment"
# Step 10: Send Data to Logic App for Email Notification
try {
    Write-Output "Preparing data for Logic App..."

    # Construct and convert payload
    $JsonPayload = @{
        "HtmlContent"         = $EmailBody
        "ExecutionDate"       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        "NotificationSubject" = "Key Vault Secrets Expiry Report - $Environment"
    } | ConvertTo-Json -Depth 3 -Compress

    Write-Output "Sending data to Logic App..."
    
    # Invoke Logic App API and store response
    $Response = Invoke-RestMethod -Method Post -Uri $LogicAppUrl -Body $JsonPayload -ContentType "application/json"

    Write-Output "Data sent successfully. Response: $($Response | ConvertTo-Json -Depth 3)"
} 
catch {
    Write-Output "Error sending data to Logic App: $($_.Exception.Message)"
}

# Final Line
Write-Output "Script execution completed successfully."