<#
SynapseWorkspacePackageInstaller.ps1 - v1.0 - Kevin White kevin.white@ the usual domain :)

Installs either all .whl files of a specified folder, or optionally an explicit 
list; into a specific Azure Synapse Workspace and either one or more explicitly
defined pools or all pools in the WS.

NB: Does not remove packages from WSs or pools when they're removed from the list.

Tested against Windows PowerShell 5.1 but should work fine with PowerShell Core.
Requires PowerShell modules Az, Az.Accounts, Az.Synapse (use install-module 
[-Name] <module name> . Despite what the internet & ChatGPT will tell you,
import-module is unnecessary as PoSH is smart enough to do it automatically).

Note that the job status can also be monitored / reviewed in the Synapse UI by
navigating to Monitor > Apache Spark applications and checking the appropriate
job (make sure ot not have a filter for a specific pool) named 
SystemReservedJob-LibraryManagement. During testing, it could hang even on
'submitting' for ~10 mins. For 'deep dive' troubleshooting, note that the 
displayed output in the GUI seems to be truncated; you may have better luck by
using the 'download logs' link (although note that it's misleading, the link
will only give you the actual log you're looking at, e.g. Driver stdout).
Also see https://learn.microsoft.com/en-us/azure/synapse-analytics/spark/apache-spark-troubleshoot-library-errors
#>

# ====== Configuration ======

$azureTenant = '163oxygen.onmicrosoft.com'
$azureSubscription = 'HcSx-SP-NHPCognito-AmusedSkua'

# Leave null if there's only one WS and it'll automagically pick it, or explicitly name it here:
$workspaceName = $null

# Leave null/empty to install to all the WS' Spark pools automagically, or explicitly name them here:
$sparkPools = @( # NB: define as an array even if there's 0 or 1 pool defined.
    #'kwtestpool'
)

# either specify a folder path or an array of explicit wheels (which can also be realitve or absolute)
$wheels = '.'
<# E.g. for an array of wheels:
$wheels = @(
    'randomWheel.whl'
    'c:/absolute/path/to/wheel.whl'
    '../relative/path/to/wheel.whl'
)
#>

# ====== End of confg ======

# ====== Basic setup ======
Write-Progress -Activity "Setup" -Status "Collecting wheels to be installed..." -id 1 -PercentComplete 0
if($wheels.GetType() -ne [System.Array]) { 
    # E.g. a string path was specified
    $folder = $wheels 
    $wheels = Get-ChildItem $folder -filter *.whl
}
if($wheels.count -lt 1) {
    throw "Error: vehichle sitting on ground; no wheels found! Please check the configuration / folder path!"
}

$iconWhl = [System.Char]::ConvertFromUtf32([System.Convert]::toInt32('1F4E6',16))
Write-Output "Attempting to install the following packages: `n  $iconWhl$($wheels.Name -join "`n  $iconWhl")"

Write-Progress -Activity "Setup" -Status "Connecting to Azure..." -id 1 -PercentComplete 10
if($null -eq (Get-AzContext)) { #only connect to Azure if not already connected
    Write-Output "Connecting to Azure..."
    connect-AzAccount -Tenant $azureTenant -WarningAction SilentlyContinue | Out-Null # NB: this only silences stdout, e.g. errors will still be shown.
}

# Note: this isn't technically required each time, but just in case you're running any other
# Azure PowerShell stuff that happens to be against a different sub, it certainly won't hurt :)
Select-AzSubscription $azureSubscription | Out-Null

Write-Progress -Activity "Setup" -Status "Getting Synapse Workspace(s)..." -id 1 -PercentComplete 15
# Similarly, if there's more than one Synapse WS in the sub, you'd need to explicitly specify 
# the one you want to work with. Since it makes future us possibly save some typing, this'll grab it if it's only one.
if(!$workspaceName) {
    $workspaces = Get-AzSynapseWorkspace
    if($workspaces.count -eq 1) {
        $workspaceName = $workspaces.Name
    } else {
        # Either 0 or >1 workspaces were found, bail out ('throw' will halt script execution)
        throw "$($workspaces.count) workspaces were found, please check the config of the script :)"
    }
}

Write-Progress -Activity "Setup" -Status "Getting existing packages in the $iconWS$workspaceName workspace..." -id 1 -PercentComplete 20
$existingWorkspacePackages = Get-AzSynapseWorkspacePackage -WorkspaceName $workspaceName

Write-Progress -Activity "Setup" -Status "Getting Spark pools in the $iconWS$workspaceName workspace..." -id 1 -PercentComplete 30
# In the same vein as the WS', we need to decide which Spark pool(s) to push to
if($sparkPools.count -gt 0) { #
    $allPools = Get-AzSynapseSparkPool -WorkspaceName $workspaceName
    #replace the array with the selected actual (e.g. fully fleshed out) pool objects
    $selectedPools = $allPools | Where-Object {$sparkPools -contains $_.Name}
    # I'll freely admit IDK what would happen if we assigned a new value while we were using it to test. I bet it'd work :D
    $sparkPools = $selectedPools
} else {
    $sparkPools = Get-AzSynapseSparkPool -WorkspaceName $workspaceName
}

$iconWS = [System.Char]::ConvertFromUtf32([System.Convert]::toInt32('1F537',16))
$iconPool = [System.Char]::ConvertFromUtf32([System.Convert]::toInt32('26A1',16))
Write-Output "Found the following pools in $iconWS$workspaceName we'll try to install to: `n  $iconPool$($sparkPools.name -join "`n  $iconPool")"

# ====== End basic setup ======
Write-Output "Completed collection of setup info."

# ====== Install packages into WS ======
Write-Progress -Activity "Installation into Workspace" -Status "Installing packages into $iconWS$workspaceName workspace..." -id 1 -PercentComplete 40
$newPackages = @()
$progress = 0
foreach($wheel in $wheels) {
    if($existingWorkspacePackages.Name -contains $wheel.name) {
        Write-Progress -Activity "Installation into Workspace" -Status "Skipping package $iconWhl$($wheel.Name) as it's already installed..." -id 2 -PercentComplete ($progress/$wheels.Count*100) -ParentId 1
        Write-Output "Skipping $iconWhl$($wheel.Name) as it's already installed in workspace $iconWS$workspaceName..."
        $newPackages += $existingWorkspacePackages | Where-Object {$_.Name -eq $wheel.name}
    } else {
        Write-Progress -Activity "Installation into Workspace" -Status "Installing package $iconWhl$($wheel.Name)..." -id 2 -PercentComplete ($progress/$wheels.Count*100) -ParentId 1
        Write-Output "Installing package $iconWhl$($wheel.Name) into workspace $iconWS$workspaceName..."
        $newPackages += New-AzSynapseWorkspacePackage -WorkspaceName $workspaceName -Package $wheel
    }
    $progress++
}

# ====== Install packages into Spark Pools ======
$iconError = [System.Char]::ConvertFromUtf32([System.Convert]::toInt32('1F4A5',16))
Write-Progress -Activity "Installation into Spark pool" -Status "Installing the packages in the pool(s)..." -id 1 -PercentComplete 70
$progress = 0
foreach($pool in $sparkPools) {
    foreach($package in $newPackages) {
        if($pool.WorkspacePackages.Name -contains $package.Name) {
            Write-Progress -Activity "Installation into Spark pool"-Status "Skipping package $iconWhl$($package.Name) as it's already installed in $iconPool$($pool.Name)..." -id 2 -PercentComplete ($progress/($sparkPools.Count*$newPackages.Count)*100) -ParentId 1
            Write-Output "Skipping $iconWhl$($package.Name) as it's already installed in pool $iconPool$($pool.Name)..."
        } else {
            Write-Progress -Activity "Installation into Spark pool"-Status "Installing package $iconWhl$($package.Name) in $iconPool$($pool.Name)..." -id 2 -PercentComplete ($progress/($sparkPools.Count*$newPackages.Count)*100) -ParentId 1
            Write-Output "Installing $iconWhl$($package.Name) into pool $iconPool$($pool.Name)..."
            try {
                Update-AzSynapseSparkPool -WorkspaceName $workspaceName -Name $pool.name -PackageAction Add -Package $package -ErrorAction Stop | Out-Null
            } catch {
                # Errors coming from specifically the spark install seem to be more complex, but general errors (e.g. pool isn't avail) are more basic
                try { 
                    # lmao, yep, let's unpack this double converted JSON baked into regular text (not very PowerShell-y of MS...)
                    $errormsg = $(((($_.Exception.Response.Content | ConvertFrom-Json).error.message -split ' failed with status:')[1] | ConvertFrom-Json).log[0])
                } catch { # E.g. if it's not a "complex" error returned, below should at least give something helpful.
                    $errormsg = $_.Exception
                }
                Write-Output "${iconError}Error${iconError}: Package install into pool failed! The error may have been:`n$errormsg "
                # Note that if you're running this script interactively, and you want to see more of the error that was spit out (nb: as of this writing,
                # I didn't find it useful), you can review the errors in $Error[x] where x is 0..[<=7] of the last few errors in reverse order (i.e. 0 is
                # the most recent error).
            }
        }
        $progress++
    }
}
