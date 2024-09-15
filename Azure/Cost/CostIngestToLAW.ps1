# Variables
$TenantId        = "<Your Tenant ID>"            # Replace with your Tenant ID
$ClientId        = "<Your Client ID>"            # Replace with your Client ID
$ClientSecret    = "<Your Client Secret>"        # Replace with your Client Secret
$DCRImmutableId  = "<Your DCR Immutable ID>"     # Replace with your DCR Immutable ID
$StreamName      = "Custom-ResourceUsage"        # Replace with your Stream Name
$WorkspaceId     = "<Your Workspace ID>"         # Replace with your LAWW ID
$Region          = "<Your Region>"               # Replace with Azure region, e.g., 'eastus'

# Function to get Azure AD Token for Logs Ingestion API
function Get-LogsIngestionAuthToken {
    param (
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://monitor.azure.com/.default"
    }
    $response = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body
    return $response.access_token
}

# Get Access Token
$accessToken = Get-LogsIngestionAuthToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

# Collect Data
# Authenticate to Azure (Use Managed Identity if running in Azure Automation)
Connect-AzAccount -Identity

# Get the current date and time
$timeGenerated = (Get-Date).ToUniversalTime()

# Get usage details for the last day
$StartDate = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
$EndDate = (Get-Date).ToString('yyyy-MM-dd')

$UsageDetails = Get-AzConsumptionUsageDetail -StartDate $StartDate -EndDate $EndDate

# Group the usage details by resource ID and sum the cost
$CostPerResource = $UsageDetails | Group-Object -Property InstanceId | ForEach-Object {
    [PSCustomObject]@{
        ResourceId = $_.Name
        TotalCost  = ($_.Group | Measure-Object -Property PretaxCost -Sum).Sum
    }
}

# Get the list of resources
$Resources = Get-AzResource

$ResourceData = foreach ($resource in $Resources) {
    $resourceId     = $resource.Id
    $resourceName   = $resource.Name
    $resourceType   = $resource.ResourceType
    $resourceGroup  = $resource.ResourceGroupName
    $subscriptionId = $resource.SubscriptionId

    # Get the cost data from $CostPerResource
    $CostRecord = $CostPerResource | Where-Object { $_.ResourceId -eq $resourceId }
    $actualCost = if ($CostRecord) { [Decimal]::Round($CostRecord.TotalCost, 2) } else { 0 }

    # Build the object
    [PSCustomObject]@{
        ResourceId     = $resourceId
        ResourceName   = $resourceName
        ResourceType   = $resourceType
        ResourceGroup  = $resourceGroup
        SubscriptionId = $subscriptionId
        ActualCost     = $actualCost
        TimeGenerated  = $timeGenerated
    }
}

# Prepare Data for Logs Ingestion API
$Body = $ResourceData | ConvertTo-Json -Depth 5

# Set Endpoint URI
$EndpointUri = "https://$Region.ingest.monitor.azure.com/dataCollectionRules/$DCRImmutableId/streams/$StreamName?api-version=2023-01-01"

# Prepare Headers
$Headers = @{
    "Authorization" = "Bearer $accessToken"
    "Content-Type"  = "application/json"
}

# Send Data to Logs Ingestion API
$response = Invoke-RestMethod -Method Post -Uri $EndpointUri -Headers $Headers -Body $Body

# Output response
$response
