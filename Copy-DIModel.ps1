###########################################################################
#   Copy-DIModel.ps1    v1.0     2024-04-03    kevin.white@ssc-spc.gc.ca
###########################################################################
# Copies Azure Document Intelligence (DI) models from one DI resource to another, optionally
# across Entra Tenant boundaries (the account used must have appropriate permissions in both).
# Input the source/dest tenant & subscription info below, and optionally the source/dest DIs.
# Note that despite the way DI Studio presents things, models exist in a DI instance, and 
# projects that you have created can use any model in the same instance (compatible API version
# notwithstanding). Deleting a project does NOT delete models in the DI instance.
#
# As of this version, only Extraction models are implemented & tested; however uncommenting the
# appropriate lines below *should* work well as the API seems to be insensitive to the difference.
# 
# A transcript of the work done is automatically saved (or appended to) ./copy-dimodel.log .
#
# Note much of this created based on documentation at:
# https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/disaster-recovery?view=doc-intel-3.1.0#business-scenarios

#########################################################
#   Configuration variables
#########################################################

## REQUIRED
$source_tenant         = '' # Name or Id is ok here
$source_subscriptionId = ''

$dest_tenant         = '' # Name or Id is ok here
$dest_subscriptionId = ''

## OPTIONAL
# Set any of the following to empty to be presented with a prompt based on the source subscription

# Name of the resource in Azure 
$source_DI_instance_name = ''
$destination_DI_instance_name = ''

#########################################################
#   API Version check function
#########################################################
function get-DIBestAPIAvailableVersion {
    param (
        $di_instance
    )
 
    # NB: for the best API calc, these need to be oldest to newest.
    $api_versions = [ordered]@{
        '2022-08-31'         = 'formrecognizer/documentModels?api-version=2022-08-31'               #3.0 GA
        '2023-02-28'         = 'formrecognizer/documentModels?api-version=2023-02-28-preview'
        '2023-07-31'         = 'formrecognizer/documentModels?api-version=2023-07-31'               #v3.1 GA
        '2023-10-31-preview' = 'documentintelligence/documentModels?api-version=2023-10-31-preview'
        '2024-02-29-preview' = 'documentintelligence/documentModels?api-version=2024-02-29-preview'
    }
    $api_tests = @()

    $best_api = $false
    $auth = @{ "Ocp-Apim-Subscription-Key" = (Get-AzCognitiveServicesAccountKey -ResourceGroupName $di_instance.ResourceGroupName -Name $di_instance.AccountName).Key1 }
    foreach($version in $api_versions.GetEnumerator()) {
        $uri = "$($di_instance.Endpoint)$($version.value)"
        $result = try { # IWR just *refuses* to not vomit out error messages on 4xx/5xx, this is the way...
            Invoke-WebRequest -UseBasicParsing -Method Get -Headers $auth -Uri $uri -ErrorAction Stop
        } catch { 
            $_.Exception.Response 
        } 

        if([int]$result.StatusCode -eq 200) { 
            $model_count = ([array]($result.Content | ConvertFrom-Json).Value | Where-Object {$_.modelId -notlike 'prebuilt-*'}).Count
        } else {
            $model_count = 'N/a'
        }

        $api_tests += [pscustomobject]@{
            StatusCode = [int]$result.StatusCode # Casting to int will change the text to the usual numeric code.
            'API version' = $version.Name
            '# of models' = $model_count
            URI = "$uri"
        }
        if([int]$result.StatusCode -eq 200) {
            $best_api = $version.Key
        }
    }
    Write-Debug "API test results for $($di_instance.AccountName) ($($di_instance.Endpoint)):"
    $api_tests | Format-Table | Out-String | Write-Debug

    return $best_api
}

## Log the work done
Start-Transcript "$($MyInvocation.MyCommand.Path | Split-Path)/copy-dimodel.log" -Append # Log each run to a file next to the script.

#########################################################
#   Prep & select source models (source side)
#########################################################
## Get connected
$not_logged_in = $false
try { # Check and see if we have a valid token
    Get-AzAccessToken -ErrorAction Stop | Out-Null
} catch {
    $not_logged_in = $true
} finally { # And login/switch to the correct tenant if req'd
    if(((Get-AzContext).Account.Tenants -notcontains $source_tenant) -or $not_logged_in) { #only connect to Azure if not already connected
        Write-Output "Connecting to Azure..."
        connect-AzAccount -Tenant $source_tenant -WarningAction SilentlyContinue | Out-Null # NB: this only silences noisy stdout, e.g. errors will still be shown.
    }
}

## Sanity check we have access to both sides
$tenants = Get-AzTenant
$all_tenant_identifiers = $($tenants.Id; $tenants.Domains) # weird syntax is to force a 1D array instead of 2D
if($source_tenant -notin $all_tenant_identifiers -or $dest_tenant -notin $all_tenant_identifiers) {
    Write-Error "The account used to authenticate with Azure must have permissions in both the source and destination tenants!"
    exit
}
Set-AzContext -Tenant $source_tenant -WarningAction SilentlyContinue | Out-Null # Switch to source tenant/sub
Set-AzContext -Subscription $source_subscriptionId | Out-Null 

## Get DI instance(s)
$di_instances = Get-AzCognitiveServicesAccount | Where-Object {$_.AccountType -eq 'FormRecognizer'}
if($source_DI_instance_name) {
    $selected_di_instances = $di_instances | Where-Object { $_.AccountName -eq $source_DI_instance_name }
} else {
    $selected_di_instances = ($di_instances | Out-GridView -PassThru -Title "Select the DI instances you'd like to scan (ctrl+click for multiple)")
}

## Get models
$models = @()
$classifiers = @()
foreach($instance in $selected_di_instances) {
    $keys = Get-AzCognitiveServicesAccountKey -ResourceGroupName $instance.ResourceGroupName -Name $instance.AccountName
    $auth = @{ "Ocp-Apim-Subscription-Key" = $keys.Key1 }
    # Extraction
    $get_models_uri = "$($instance.Endpoint)documentintelligence/documentModels?api-version=2023-10-31-preview"
    $get_classifiers_uri = "$($instance.Endpoint)formrecognizer/documentClassifiers?api-version=2023-07-31"
    Write-Debug "Trying to get models from $get_models_uri"
    $results = Invoke-RestMethod -UseBasicParsing -Method Get -Headers $auth -Uri $get_models_uri
    $models += ($results.value `
        | Where-Object {$_.modelId -notlike 'prebuilt-*'} `
        | Select-Object @{label='DI Instance'; expression={$instance.AccountName}}, modelId, @{label='Created'; expression={$_.createdDateTime}}, # (previous line) filter out the prebuilt models
            apiVersion, description, @{label='Endpoint'; expression={$instance.Endpoint}}, @{label='auth'; expression={@{ "Ocp-Apim-Subscription-Key" = $keys.Key1}}} # Rename labels & add endpoint
    )
    # Classifiers
    #Write-Debug "Trying to get models from $get_classifiers_uri"
    #$results = Invoke-RestMethod -UseBasicParsing -Method Get -Headers $auth -Uri $get_classifiers_uri
    #$classifiers += $results.value
}

$selected_models = ( $models | Out-GridView -PassThru -Title "Select the Extraction models you'd like to copy (ctrl+click for multiple)" `
                        | Select-Object *, @{l="AccountName"; e={$_.'DI Instance'}}) # last bit adds AccountName back as a property name as we use it a bunch below
#$selected_classifiers = ($classifiers | Out-GridView -PassThru -Title "Select the Classification models you'd like to copy (ctrl+click for multiple)")


#########################################################
#   Select destination (dest side)
#########################################################

Set-AzContext -Tenant $dest_tenant -WarningAction SilentlyContinue | Out-Null # Switch to dest tenant/sub
Set-AzContext -Subscription $dest_subscriptionId | Out-Null 

if($destination_DI_instance_name) {
    $destination_di_instance = ($di_instances | Where-Object { $_.AccountName -eq $destination_DI_instance_name } | Select-Object * -First 1)
} else {
    $destination_di_instance = ($di_instances | Out-GridView -PassThru -Title "Select the destination DI instance" | Select-Object * -First 1)
}

$destination_auth = @{ "Ocp-Apim-Subscription-Key" = (Get-AzCognitiveServicesAccountKey -ResourceGroupName $destination_di_instance.ResourceGroupName -Name $destination_di_instance.AccountName).Key1 }

$destination_DI_API_version = get-DIBestAPIAvailableVersion $destination_di_instance

## Ready for launch!

Write-Output "Trying to copy the following models:"
$selected_models | ft

#########################################################
#   Authorize copy (dest side)
#########################################################

$auth_copy_uri_versions = [ordered]@{ # Seems like these are the only two permitted for this API call; https://learn.microsoft.com/en-us/rest/api/aiservices/document-models/authorize-model-copy
    '2023-07-31'         = 'formrecognizer/documentModels:authorizeCopy?api-version=2023-07-31'               #v3.1 GA
    '2024-02-29-preview' = 'documentintelligence/documentModels:authorizeCopy?api-version=2024-02-29-preview'
}

$progress = 0 #hah!
foreach($model in $selected_models) {
    Write-Progress -Activity "Copying models" -Status "Copying model $($model.modelId)..." -PercentComplete ($progress/$selected_models.Count*100) -id 1
    ## Confirm API will be compat
    if((get-date "$($model.apiVersion)".substring(0,10)) -gt (get-date $destination_DI_API_version.substring(0,10))) {
        Write-Warning "Skipping model $($model.AccountName) as it requires API version $($model.apiVersion) but destination only supports $destination_DI_API_version!"
    } else {
        $auth_copy_uri = "$($destination_di_instance.Endpoint)$($auth_copy_uri_versions[$destination_DI_API_version])"
        Write-Debug "Authorizing copy using URI $uri"
        try {
            $target_response = Invoke-WebRequest -UseBasicParsing `
                -Method Post `
                -Headers $destination_auth `
                -Uri $auth_copy_uri `
                -ContentType 'application/json' `
                -Body (@{
                    modelID = $model.modelId        # Set the model id (name in the GUI) & description the same as source
                    description = $model.description
                    #tags = @{} # Optional, doesn't seem to be supported in the GUI yet
                } | ConvertTo-Json -Depth 99)
        } catch {
            $conflict_recovered = $false
            if([int]$_.Exception.StatusCode -eq 409) {
                Write-Warning ("While trying to authorize the copy of $($model.modelId) from $($model.AccountName) to $($destination_di_instance.AccountName), " +` 
                               "we got a Conflict (409) response. If $($model.modelId) truly doesn't exist in $($destination_di_instance.AccountName) " + `
                               "(e.g., a CopyAuthorization was done but no model successfully copied afterward), we can try and delete the orphaned model $($model.modelId) " + `
                               "on the $($destination_di_instance.AccountName) side (the $($model.AccountName) side remains untouched) and retry the authorization. Do you want to try this?")
                if((Read-Host -Prompt "Y/[N]") -like 'y*') {
                    $delete_model_uri_versions = [ordered]@{ # https://learn.microsoft.com/en-us/rest/api/aiservices/document-models/delete-model
                        '2023-07-31'         = "formrecognizer/documentModels/$($model.modelId)?api-version=2023-07-31"               #v3.1 GA
                        '2024-02-29-preview' = "documentintelligence/documentModels/$($model.modelId)?api-version=2024-02-29-preview"
                    }
                    try {
                        ## Delete dest. Note the -method.
                        Invoke-WebRequest -UseBasicParsing `
                            -Method Delete `
                            -Headers $destination_auth `
                            -Uri "$($destination_di_instance.Endpoint)$($delete_model_uri_versions[$destination_DI_API_version])" `
                            -ContentType 'application/json' | Out-Null # just to silence success messages
                        ## Retry authorization
                        $target_response = Invoke-WebRequest -UseBasicParsing `
                            -Method Post `
                            -Headers $destination_auth `
                            -Uri $auth_copy_uri `
                            -ContentType 'application/json' `
                            -Body (@{
                                modelID = $model.modelId        # Set the model id (name in the GUI) & description the same as source
                                description = $model.description
                            } | ConvertTo-Json -Depth 99)
                        ## Set the flag such that we don't break out of this iteration (e.g. we need to continue the copy for *this* model now)
                        $conflict_recovered = $true
                    } catch { # Note that this catches errors from *either* delete or authorization above
                        Write-Error "Authorizing copy for $($model.modelId) FAILED. Exception was:`n$($_.Exception)`n`nMessage (if any) was:`n$($_.ErrorDetails.Message)"
                        continue
                    }
                }

            }
            if(-not $conflict_recovered) {
                Write-Error "Authorizing copy for $($model.modelId) FAILED. Exception was:`n$($_.Exception)`n`nMessage (if any) was:`n$($_.ErrorDetails.Message)"
                continue
            }
        }
    }

#########################################################
#   Start copy (source side)
#########################################################

    Set-AzContext -Tenant $source_tenant -WarningAction SilentlyContinue | Out-Null # Switch to source tenant/sub
    Set-AzContext -Subscription $source_subscriptionId | Out-Null 

    $copy_to_uri_versions = [ordered]@{ # https://learn.microsoft.com/en-us/rest/api/aiservices/document-models/copy-model-to
        '2023-07-31'         = "formrecognizer/documentModels/$($model.modelId):copyTo?api-version=2023-07-31"               #v3.1 GA
        '2024-02-29-preview' = "documentintelligence/documentModels/$($model.modelId):copyTo?api-version=2024-02-29-preview"
    }
    try {
        $copy_start_response = Invoke-WebRequest -UseBasicParsing `
            -Method Post `
            -Headers $model.auth `
            -Uri "$($model.Endpoint)$($copy_to_uri_versions[$destination_DI_API_version])" `
            -ContentType 'application/json' `
            -Body $target_response.Content # NB: Content here is already a JSON string, don't double convert!
    } catch {
        Write-Error "Starting the copy for $($model.modelId) FAILED. Exception was:`n$($_.Exception)`n`nMessage (if any) was:`n$($_.ErrorDetails.Message)"
        continue
    }

#########################################################
#   Track progress (source side)
#########################################################
    $source_response
    $copy_complete = $false
    try{ 
        while(!$copy_complete) {
            # Fortunately, the start copy API responds with a URI including API that it expects us to track with, so no version dance req'd here.
            Write-Debug "Tracking progress using URI $($copy_start_response.Headers["Operation-Location"])"

            $progress_response = Invoke-RestMethod -UseBasicParsing `
                -Method Get `
                -Headers $model.auth `
                -Uri ([string]$copy_start_response.Headers["Operation-Location"]) # Cast to string req'd in PoSH 7 :P

            Start-Sleep -Seconds 1
            # Only update progress if it's reported
            if(-not $progress_response.percentCompleted) {
                Write-Progress -Activity "Copying models" -Status "Starting copy; status: $($progress_response.status)" -id 2 -PercentComplete 0 -ParentId 1
            } else {
                Write-Progress -Activity "Copying model $($model.modelId)" -Status "Copying..." -id 2 -PercentComplete $progress_response.percentCompleted -ParentId 1
                if($progress_response.percentCompleted -eq 100) {
                    $copy_complete = $true
                }
                
            }
        }
        Write-Output "Copy of '$($model.modelId)' $($progress_response.status)."
    } catch {
        Write-Error "Copying of $($model.modelId) FAILED. Exception was:`n$($_.Exception)`n`nMessage (if any) was:`n$($_.ErrorDetails.Message)"
        continue
    }
    $progress++
}

Stop-Transcript