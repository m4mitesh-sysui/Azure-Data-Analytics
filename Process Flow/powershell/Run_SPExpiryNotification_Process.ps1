# Step 1: Define Constants
$MODULES = @("Az.Accounts", "Az.Automation", "Az.Resources")  # Required modules
$MAX_RETRIES = 3                                              # Maximum retry attempts
$DELAY_SECONDS = 5                                            # Delay between retries
$TABLE_STYLE = "border='1' style='border-collapse:collapse;'" # HTML table styling
$DAYS_WARNING_THRESHOLD = 30                                  # Warning threshold for days
$ErrorActionPreference = "Stop"                               # Ensures errors trigger the catch block
$HTML_INTRO = @"
<p>This is an automated notification for Service Principal status and its expiration.</p>
"@
$HTML_COLUMN_DESCRIPTION = @"
<p>Below is a summary report and column definitions for reference:</p>
<ul>
    <li><b>Service Principal Name</b>: Name of the Azure Service Principal.</li>
    <li><b>Expiration Date</b>: The date on which the Service Principal's credentials expire.</li>
    <li><b>Days Until Expire</b>: Number of days remaining until the credentials expire. Negative values indicate expired credentials. Days less than <b>$DAYS_WARNING_THRESHOLD</b> are highlighted in orange.</li>
    <li><b>Status</b>: The current status of the Service Principal (Active, Expiring Soon, or Expired).</li>
</ul>
<p><b>Action Required:</b></p>
<ul>
    <li>Renew or update expired credentials (those with negative values in the "Days Until Expire" column).</li>
    <li>Monitor upcoming expirations and take necessary actions to prevent disruptions.</li>
</ul>
"@
$HTML_CLOSING = @"
<p>If you have any questions or need assistance, please reach out to the <b>DevOps</b> team.</p>
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

# Step 3: Set Up Environment Configuration Variables
$environmentConfiguration = @{
    LogicAppUrl               = "LogicAppURL"  # Variable for Logic App Service Principal
    servicePrincipalId        = "servicePrincipalId"
    servicePrincipalSecret    = "servicePrincipalSecret"
    TenantIdKey               = "tenantId"
    VaultNameKey              = "VaultName"
}

# Step 4: Fetch the Logic App Service Principal URL from Automation Variables
$logicAppUrl = Get-AutomationVariable -Name $environmentConfiguration.LogicAppUrl

# Step 5: Authenticate with Service Principal
try {
    Write-Output "Authenticating with Service Principal..."

    # Step 5: Retrieve Service Principal Credentials
    $applicationid = Get-AutomationVariable -Name $environmentConfiguration.servicePrincipalId
    $secretKey = Get-AutomationVariable -Name $environmentConfiguration.servicePrincipalSecret
    $tenantID = Get-AutomationVariable -Name $environmentConfiguration.TenantIdKey
    $password = ConvertTo-SecureString -String $secretKey -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($applicationid, $password)

    # Connect using Service Principal
    Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $tenantID
    Write-Output "Service principal connected successfully!"

    # Retrieve Utility Account Credentials
    Write-Output "Retrieving Utility Account credentials..."
    $vaultName = Get-AutomationVariable -Name $environmentConfiguration.VaultNameKey
    $utilityAccountPasswordValue = Get-AzKeyVaultSecret -VaultName $vaultName -Name $environmentConfiguration.UtilityAccountUserPasswordKey -AsPlainText
    $utilityAccountPassword = ConvertTo-SecureString -String $utilityAccountPasswordValue -AsPlainText -Force
    $utilityAccountUserName = Get-AzKeyVaultSecret -VaultName $vaultName -Name $environmentConfiguration.UtilityAccountUserNameKey -AsPlainText

    # Disconnect previous connection (Service Principal)
    Write-Output "Disconnecting previous session..."
    Disconnect-AzAccount

    # Connect using Utility Account
    Write-Output "Connecting with Utility Account..."
    $credential = New-Object System.Management.Automation.PSCredential($utilityAccountUserName, $utilityAccountPassword)
    Connect-AzAccount -Credential $credential

    Write-Output "Successfully logged in as $utilityAccountUserName"

} catch {
    Write-Output "Authentication failed: $($_.Exception.Message)"
    exit
}

# Step 6: Process Service Principal details with validation
Write-Output "Processing Service Principal details..."
$spDetails = @()
$today = Get-Date

# Step 7: Fetch and Sort Service Principals whose names start with 'hew-' (case-insensitive) or 'HEWDevOps-'.
$servicePrincipals = Get-AzADServicePrincipal | Where-Object {
    ($_.DisplayName -match "^(?i)hew-" -or $_.DisplayName -match "^HEWDevOps-") -and
    $_.ServicePrincipalType -eq "Application"
} | Sort-Object DisplayName

# Step 8: Process Service Principal Credentials
$servicePrincipals | Select-Object DisplayName

foreach ($sp in $servicePrincipals) {
    Write-Output "Processing Service Principal: $($sp.DisplayName)"
    try {
        $credentials = Get-AzADAppCredential -ApplicationId $sp.AppId
        if ($credentials.Count -eq 0) {
            Write-Output "No credentials found for $($sp.DisplayName)."
            $spDetails += [PSCustomObject]@{
                ServicePrincipalName = $sp.DisplayName
                ExpirationDate      = "N/A"
                DaysUntilExpire     = "N/A"
                Status              = "No Credentials"
            }
            continue
        }
        foreach ($cred in $credentials) {
            $expirationDate = $cred.EndDateTime
            $daysUntilExpire = ($expirationDate - $today).Days

            $status = if ($daysUntilExpire -lt 0) { "Expired" }
                      elseif ($daysUntilExpire -le 30) { "Expiring Soon" }
                      else { "Active" }

            $spDetails += [PSCustomObject]@{
                ServicePrincipalName = $sp.DisplayName
                ExpirationDate      = $expirationDate.ToString("yyyy-MM-dd")
                DaysUntilExpire     = $daysUntilExpire
                Status              = $status
            }
            Write-Output "Added Service Principal details for: $($sp.DisplayName)"
        }
    } catch {
        Write-Error "Failed to fetch credentials for $($sp.DisplayName). Error: $_"
        continue
    }
}

if (-not $spDetails) {
    Write-Output "No Service Principal details to process. Exiting."
    exit
}
Write-Output "Service Principal details processing completed."

# Step 9: Generate HTML Table with Conditional Formatting
Write-Output "Generating HTML table for Service Principals..."
$HtmlTable = "<table $TABLE_STYLE>
<tr>
    <th style='color:blue;'>Service Principal Name</th>
    <th style='color:blue;'>Expiration Date</th>
    <th style='color:blue;'>Days Until Expire</th>
    <th style='color:blue;'>Status</th>
</tr>"

foreach ($sp in $spDetails) {
    # Apply conditional formatting for the "Days Until Expire" column
    $formattedDays = if ($sp.DaysUntilExpire -lt 0) {
        "<b style='color:red;'>$($sp.DaysUntilExpire)</b>"
    } elseif ($sp.DaysUntilExpire -le $DAYS_WARNING_THRESHOLD) {
        "<b style='color:orange;'>$($sp.DaysUntilExpire)</b>"
    } else {
        "$($sp.DaysUntilExpire)"
    }

    # Apply conditional formatting for status
    $formattedStatus = if ($sp.Status -eq "Expired") {
        "<b style='color:red;'>$($sp.Status)</b>"
    } elseif ($sp.Status -eq "Expiring Soon") {
        "<b style='color:orange;'>$($sp.Status)</b>"
    } elseif ($sp.Status -eq "No Credentials") {
        "<b style='color:gray;'>$($sp.Status)</b>"    
    } else {
        "<b style='color:green;'>$($sp.Status)</b>"
    }

    $HtmlTable += "<tr>
        <td>$($sp.ServicePrincipalName)</td>
        <td style='text-align:center;'>$($sp.ExpirationDate)</td>
        <td style='text-align:center;'>$formattedDays</td>
        <td style='text-align:center;'>$formattedStatus</td>
    </tr>"
}
$HtmlTable += "</table>"
Write-Output "HTML table for Service Principals generated successfully."

#Step 10: ================= Construct Email Body =================
$EmailBody = "$HTML_INTRO<br><br>$HTML_COLUMN_DESCRIPTION<br><br>$HtmlTable<br><br>$HTML_CLOSING"
Write-Output "Email body constructed successfully."

# Step 11: Retry Logic for Logic App Call
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

# Step 12: Send Data to Logic App for Email Notification
try {
    Write-Output "Preparing data for Logic App..."

    # Construct and convert payload
    $JsonPayload = @{
        "HtmlContent"         = $EmailBody
        "ExecutionDate"       = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        "NotificationSubject" = "Service Principal Expiry Report"
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