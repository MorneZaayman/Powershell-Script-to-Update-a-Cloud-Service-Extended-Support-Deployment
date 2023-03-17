# Set the location
$location = "southafricanorth";
$resourceGroupName = "mzansibytes"
$virtualNetworkName = "mzansibytes"

# Sign In To Azure
Connect-AzAccount

# Set Context
$subscriptionId = "e7677071-26f6-4aa8-967f-8405db4a6718"
Set-AzContext -Tenant $subscriptionId

# Package the project
$msBuildFilePath = "C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe"
.$msBuildFilePath "$PSScriptRoot\MzansiBytes\MzansiBytes.ccproj" `
    /p:Configuration=Release `
    /p:PublishDir="$PSScriptRoot\Temp\CloudPackage" `
    /p:TargetProfile="Cloud" `
    /p:Platform=AnyCpu `
    /t:Publish

# Upload configuration and package to Azure and get SAS URIs"
$storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name "mzansibytes"

$configurationBlob = Set-AzStorageBlobContent -Context $storageAccount.Context -Force -Container "temp" -File "$PSScriptRoot\Temp\CloudPackage\ServiceConfiguration.Cloud.cscfg" -Blob "CloudPackage\ServiceConfiguration.cscfg"
$configurationBlobSasToken = New-AzStorageBlobSASToken -Context $storageAccount.Context -FullUri -Container "temp" -Blob "$($configurationBlob.Name)" -Permission rwd

$packageBlob = Set-AzStorageBlobContent -Context $storageAccount.Context -Force -Container "temp" -File "$PSScriptRoot\Temp\CloudPackage\MzansiBytes.cspkg" -Blob "CloudPackage\MzansiBytes.cspkg"
$packageBlobSasToken = New-AzStorageBlobSASToken -Context $storageAccount.Context -FullUri -Container "temp" -Blob "$($packageBlob.Name)" -Permission rwd

# Get the currently running cloud service.
if (Get-AzCloudService -ResourceGroupName $resourceGroupName -CloudServiceName "MzansiBytes-1" -ErrorAction SilentlyContinue)    # -ErrorAction SilentlyContinue is used so that if this is false, PowerShell doesn't print a bunch of Azure errors to the screen.
{
    $currentCloudService = Get-AzCloudService -ResourceGroupName $resourceGroupName -CloudServiceName "MzansiBytes-1"
    $cloudServiceToDeploy = "MzansiBytes-2"
}
elseif (Get-AzCloudService -ResourceGroupName $resourceGroupName -CloudServiceName "MzansiBytes-2" -ErrorAction SilentlyContinue)
{
    $currentCloudService = Get-AzCloudService -ResourceGroupName $resourceGroupName -CloudServiceName "MzansiBytes-2"
    $cloudServiceToDeploy = "MzansiBytes-1"
}
else {
    throw "No cloud service was found."
}

# Set the ARM template parameters
$parametersJson = Get-Content "$PSScriptRoot\Parameters.json" | ConvertFrom-Json
$parametersJson.parameters.cloudServiceName.value = $cloudServiceToDeploy
$parametersJson.parameters.configurationSasUri.value = $configurationBlobSasToken
$parametersJson.parameters.packageSasUri.value = $packageBlobSasToken
$parametersJson.parameters.publicIPName.value = "mzansibytes-staging"
$parametersJson.parameters.location.value = $location
$parametersJson.parameters.startCloudService.value = $true
$parametersJson.parameters.swappableCloudService.value = "$($currentCloudService.Id)"
$parametersJson.parameters.vnetName.value = $virtualNetworkName
$parametersJson.parameters.vnetId.value = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Network/virtualNetworks/$virtualNetworkName"
$parametersJson | ConvertTo-Json | Set-Content "$PSScriptRoot\Parameters.json"

# Create the Cloud Service Resource
New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName -TemplateFile "$PSScriptRoot\Template.json" -TemplateParameterFile "$PSScriptRoot\Parameters.json"

# Swap VIPs
Switch-AzCloudService -ResourceGroupName $resourceGroupName -CloudServiceName $currentCloudService.Name -Confirm:$false

# Cleanup
Remove-Item "$PSScriptRoot\Temp" -Recurse -Force
Remove-AzCloudService -ResourceGroupName $resourceGroupName -CloudServiceName $currentCloudService.Name