# Define constants
$MODULES = @("Az.Accounts", "Az.Automation")                  # Required modules
$VARIABLES = @("tenantId", "servicePrincipalId", "servicePrincipalSecret", "subscriptionId", "rgName", "WebhookCredExpiryLogicAppURL", "Environment")
$MAX_RETRIES = 3                                              # Maximum retry attempts
$DELAY_SECONDS = 5                                            # Delay between retries
$TABLE_STYLE = "border='1' style='border-collapse:collapse;'" # HTML table styling
$DAYS_WARNING_THRESHOLD = 30                                  # Warning threshold for days
$HTML_INTRO = @"
<p>This is an automated notification for webhook status and its expiration.</p>
"@
$HTML_COLUMN_DESCRIPTION = @"
<p>Below is a summary report and column definitions for reference:</p>
<ul>
    <li><b>Automation Account</b>: Name of the Azure Automation account.</li>
    <li><b>Runbook Name</b>: Name of the Runbook.</li>
    <li><b>Webhook Name</b>: Webhook name.</li>
    <li><b>Creation Date</b>: Webhook creation date.</li>
    <li><b>Expiration Date</b>: Webhook expiry date.</li>
    <li><b>Days Until Expire</b>: Number of days remaining until webhook expires. 
        Negative values indicate expired webhooks. 
        Days less than <b>$DAYS_WARNING_THRESHOLD</b> are highlighted in orange.</li>
</ul>
<p><b>Action Required:</b></p>
<ul>
    <li>Renew or recreate expired webhooks (those with negative values in the "Days Until Expire" column).</li>
    <li>Review upcoming expirations and take appropriate actions to avoid disruptions.</li>
</ul>
"@
$HTML_CLOSING = @"
<p>If you have any questions or need assistance, please reach out to the <b>DevOps</b> team.</p>
"@

# Step 1: Import necessary modules
Write-Output "Checking and importing required modules..."
foreach ($module in $MODULES) {
    if (-not (Get-Module -Name $module -ListAvailable)) {
        Write-Output "Module '$module' not found, importing..."
        try {
            Import-Module -Name $module -Force
            Write-Output "Module '$module' imported successfully."
        } catch {
            Write-Error "Failed to import module '$module'. Error: $_"
            exit
        }
    } else {
        Write-Output "Module '$module' is already available. Skipping import."
    }
}

# Step 2: Retrieve and validate variables from Azure Automation
Write-Output "Retrieving Azure Automation variables..."
foreach ($var in $VARIABLES) {
    if (-not (Get-AutomationVariable -Name $var)) {
        Write-Error "Required Automation Variable '$var' is missing."
        exit
    }
}

# Retrieve variables
$tenantID = Get-AutomationVariable -Name 'tenantId'
$clientID = Get-AutomationVariable -Name 'servicePrincipalId'
$clientSecret = Get-AutomationVariable -Name 'servicePrincipalSecret'
$subscriptionId = Get-AutomationVariable -Name 'subscriptionId'
$resourceGroupName = Get-AutomationVariable -Name 'rgName'
$logicAppUrl = Get-AutomationVariable -Name 'LogicAppURL'
$Environment = Get-AutomationVariable -Name 'Environment'

# Validate Logic App URL
if (-not $logicAppUrl -or $logicAppUrl -notmatch "^https?:\/\/") {
    Write-Error "Invalid Logic App URL. Please check the LogicAppURL variable."
    exit
}

Write-Output "All required variables retrieved successfully."

# Step 3: Authenticate with Azure
Write-Output "Authenticating with Azure using Service Principal..."
$secureClientSecret = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($clientID, $secureClientSecret)

try {
    Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $tenantID
    Set-AzContext -SubscriptionId $subscriptionId
    Write-Output "Azure authentication succeeded."
} catch {
    Write-Error "Azure authentication failed. Error: $_"
    exit
}

# Step 4: Fetch and validate Automation Accounts
Write-Output "Fetching Automation Accounts in Resource Group: $resourceGroupName"
try {
    $automationAccounts = Get-AzAutomationAccount | Where-Object { $_.ResourceGroupName -eq $resourceGroupName }
    if (-not $automationAccounts) {
        Write-Output "No Automation Accounts found in the Resource Group."
        exit
    }
    Write-Output "Number of Automation Accounts found: $($automationAccounts.Count)"
} catch {
    Write-Error "Failed to fetch Automation Accounts. Error: $_"
    exit
}

# Step 5: Process webhook details with validation
Write-Output "Processing webhook details..."
$webhookDetails = @()

foreach ($automationAccount in $automationAccounts) {
    Write-Output "Processing Automation Account: $($automationAccount.AutomationAccountName)"

    # Fetch all active runbooks in this automation account
    try {
        $validRunbooks = Get-AzAutomationRunbook -ResourceGroupName $automationAccount.ResourceGroupName -AutomationAccountName $automationAccount.AutomationAccountName | Select-Object -ExpandProperty Name
    } catch {
        Write-Error "Failed to fetch runbooks for $($automationAccount.AutomationAccountName). Error: $_"
        continue
    }

    # Fetch only webhooks that are linked to existing runbooks
    try {
        $webhooks = Get-AzAutomationWebhook -ResourceGroupName $automationAccount.ResourceGroupName -AutomationAccountName $automationAccount.AutomationAccountName | Where-Object { $_.RunbookName -in $validRunbooks }

        if ($webhooks.Count -eq 0) {
            Write-Output "No valid webhooks found in $($automationAccount.AutomationAccountName)."
            continue
        }

        Write-Output "Number of valid webhooks found: $($webhooks.Count)"

        foreach ($webhook in $webhooks) {
            if (-not $webhook.RunbookName -or -not $webhook.Name -or -not $webhook.ExpiryTime) {
                Write-Error "Invalid or incomplete webhook data. Skipping..."
                continue
            }

            $details = [PSCustomObject]@{
                AutomationAccount = $automationAccount.AutomationAccountName
                RunbookName       = $webhook.RunbookName
                WebhookName       = $webhook.Name
                CreationDate      = $webhook.CreationTime.ToLocalTime().ToString("yyyy-MM-dd")
                ExpirationDate    = $webhook.ExpiryTime.ToLocalTime().ToString("yyyy-MM-dd")
                DaysUntilExpire   = ($webhook.ExpiryTime - (Get-Date)).Days
            }
            $webhookDetails += $details

            # Added Runbook Name in Output
            Write-Output "Added webhook details for Webhook: '$($webhook.Name)' linked to Runbook: '$($webhook.RunbookName)'"
        }
    } catch {
        Write-Error "Failed to fetch webhooks for $($automationAccount.AutomationAccountName). Error: $_"
        continue
    }
}

if (-not $webhookDetails) {
    Write-Output "No webhook details to process. Exiting."
    exit
}
Write-Output "Webhook details processing completed."

# Step 6: Generate HTML Table with Conditional Formatting
Write-Output "Generating HTML table..."
$HtmlTable = "<table $TABLE_STYLE>
<tr><th>Automation Account</th><th>Runbook Name</th><th>Webhook Name</th><th>Creation Date</th><th>Expiration Date</th><th>Days Until Expire</th></tr>"
foreach ($webhook in $webhookDetails) {
    # Apply conditional formatting for the "Days Until Expire" column
    $formattedDays = if ($webhook.DaysUntilExpire -lt 0) {
        "<b style='color:red;'>$($webhook.DaysUntilExpire)</b>"
    } elseif ($webhook.DaysUntilExpire -le $DAYS_WARNING_THRESHOLD) {
        "<b style='color:orange;'>$($webhook.DaysUntilExpire)</b>"
    } else {
        "$($webhook.DaysUntilExpire)"
    }
    $HtmlTable += "<tr>
        <td>$($webhook.AutomationAccount)</td>
        <td>$($webhook.RunbookName)</td>
        <td>$($webhook.WebhookName)</td>
        <td>$($webhook.CreationDate)</td>
        <td>$($webhook.ExpirationDate)</td>
        <td>$formattedDays</td>
    </tr>"
}
$HtmlTable += "</table>"
Write-Output "HTML table generated successfully."

# Step 7: Combine all parts into the email body
if (-not $HtmlTable) {
    Write-Output "Error: HtmlTable is empty or not defined. Email body cannot be generated."
    return
}

# Combine all parts into the email body
$EmailBody = "$HTML_INTRO<br><br>$HTML_COLUMN_DESCRIPTION<br><br>$HtmlTable<br><br>$HTML_CLOSING"
Write-Output "Email body successfully generated."

# Step 8: Retry Logic for Logic App Call
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
            Write-Error "Attempt $i failed. Retrying in $DelaySeconds seconds..."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
    throw "All $MaxRetries attempts failed."
}

# Step 9: Send Data to Logic App for Email Notification
Write-Output "Sending data to Logic App..."

# If the variable is not set, default to "Dev"
if (-not $Environment) { 
    $Environment = "Dev" 
}

Write-Output "Current Environment: $Environment"

# Pre-validation to prevent unnecessary API calls
if (-not $EmailBody -or -not $logicAppUrl) {
    Write-Output "Missing required values. Skipping Logic App notification."
    return
}

$Payload = @{
    HtmlContent         = $EmailBody
    ExecutionDate       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    NotificationSubject = "Webhook Expiry Report - $Environment"
} | ConvertTo-Json -Depth 3

try {
    Invoke-With-Retry -ScriptBlock {
        Invoke-RestMethod -Method Post -Uri $logicAppUrl -Body $Payload -ContentType "application/json"
    }
    Write-Output "Data sent successfully to Logic App."
} catch {
    Write-Output "Error sending data to Logic App: $($_.Exception.Message)"
}

#Final Line
Write-Output "Script execution completed successfully."