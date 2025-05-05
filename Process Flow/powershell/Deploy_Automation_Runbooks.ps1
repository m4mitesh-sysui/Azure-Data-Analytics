<#
    SYNOPSIS
    This script automates the deployment of Azure Automation Runbooks based on a configuration file.

    DESCRIPTION
    The script reads a CSV file that lists runbook names and a flag indicating whether to deploy them or not. 
    It checks if each runbook exists in Azure Automation and deploys it if needed, otherwise skips it.

    PARAMETERS
    AutomationAccountName: The name of the Azure Automation account where the runbooks will be deployed.
    ResourceGroupName: The name of the resource group where the Azure Automation account is located.
    ConfigFilePath: The path to the CSV file that lists runbooks and their deployment statuses (1 = Deploy, 0 = Skip).
    RunbookDirectory: The directory containing the PowerShell runbook files (.ps1) to be deployed.

    REVISION HISTORY
    -------------------------------------------------------------------------------------------------
    Date        Author              Description
    -------------------------------------------------------------------------------------------------
    2021-05-31  Mitesh Sah          Initial version: Script deploys runbooks based on a CSV config.
    2021-05-31  Mitesh Sah          Added functionality to deploy or skip runbooks based on a CSV flag.
                                    Verifies if runbook files exist in the specified directory.
    2021-05-31  Mitesh Sah          Enhanced to dynamically generate file paths for runbooks from 
                                    the specified directory.
    -------------------------------------------------------------------------------------------------
#>

param (
    [string]$AutomationAccountName,   # Automation Account Name
    [string]$ResourceGroupName,       # Resource Group Name
    [string]$ConfigFilePath,          # Path to the CSV configuration file
    [string]$RunbookDirectory         # Directory where runbook files are stored
)

# Desired types (PowerShell and PowerShell versions)
$DesiredRunbookTypes = @("PowerShell", "PowerShell72")

# Import the CSV configuration file
$runbookConfig = Import-Csv -Path $ConfigFilePath

foreach ($runbook in $runbookConfig) {
    $RunbookName = $runbook.AutomationRunbookName
    $DeployStatus = $runbook.ToBeDeploy

    # Construct the expected runbook file path in the directory
    $RunbookPath = Join-Path -Path $RunbookDirectory -ChildPath "$RunbookName.ps1"

    # Check if the runbook file exists in the specified directory
    if (Test-Path -Path $RunbookPath) {
        if ($DeployStatus -eq '1') {
            Write-Host "Processing runbook: $RunbookName"

            # Check if runbook exists in Azure
            $existingRunbook = Get-AzAutomationRunbook `
                -AutomationAccountName $AutomationAccountName `
                -ResourceGroupName $ResourceGroupName `
                -Name $RunbookName -ErrorAction SilentlyContinue

            if ($existingRunbook) {
                Write-Host "Runbook exists. Checking runbook type..."

                # Output the existing runbook type
                $currentRunbookType = $existingRunbook.RunbookType
                Write-Host "Current runbook type is: $currentRunbookType"

                # Check if the runbook type is in the list of allowed types (PowerShell or PowerShell72)
                if ($DesiredRunbookTypes -contains $currentRunbookType) {
                    Write-Host "Runbook type matches ($currentRunbookType). Updating the runbook..."

                    # Use Import-AzAutomationRunbook to update the runbook
                    try {
                        # Overwrite the existing runbook definition without deleting it
                        Import-AzAutomationRunbook `
                            -AutomationAccountName $AutomationAccountName `
                            -Name $RunbookName `
                            -Path $RunbookPath `
                            -ResourceGroupName $ResourceGroupName `
                            -Type $currentRunbookType `
                            -Force
                    } catch {
                        Write-Host "Error updating the runbook: $($_.Exception.Message)"
                        throw
                    }

                } else {
                    Write-Host "Warning: Runbook type mismatch. Current type is $currentRunbookType, and it's not one of the desired types."
                    Write-Host "Skipping update to avoid type conflict. Please check manually."
                    continue
                }
            } else {
                Write-Host "Runbook does not exist. Importing as a new runbook..."

                # Import the runbook if it doesn't exist
                Import-AzAutomationRunbook `
                    -AutomationAccountName $AutomationAccountName `
                    -Name $RunbookName `
                    -Path $RunbookPath `
                    -ResourceGroupName $ResourceGroupName `
                    -Type "PowerShell72" # Defaulting to PowerShell72 for new runbooks
            }

            # Publish the runbook after the update or import
            Publish-AzAutomationRunbook `
                -AutomationAccountName $AutomationAccountName `
                -Name $RunbookName `
                -ResourceGroupName $ResourceGroupName

        } else {
            Write-Host "Skipping deployment for runbook: $RunbookName (ToBeDeploy: $DeployStatus)"
        }
    } else {
        Write-Host "Runbook file not found: $RunbookPath"
    }
}
