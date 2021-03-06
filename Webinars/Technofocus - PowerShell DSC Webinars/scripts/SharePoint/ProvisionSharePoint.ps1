<#
 * Copyright Microsoft Corporation
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
#>

param([parameter(Mandatory=$true)][string]$configFilePath,
      [parameter(Mandatory=$true)][string]$scriptFolder)

#write-host $deployStandaloneSQLIIS (1)
#write-host $deployDomainSQLIIS (2)
#write-host $deploySharePoint (3)

$spScriptPath = (Join-Path -Path $scriptFolder -ChildPath 'SharePoint\ProvisionSharePointVm.ps1')

$config = [xml](gc $configFilePath)

$dcServiceName = $config.Azure.Connections.ActiveDirectory.ServiceName
$dcVmName = $config.Azure.Connections.ActiveDirectory.DomainControllerVM
$domainInstallerUserName = $config.Azure.Connections.ActiveDirectory.ServiceAccountName
$domainInstallerPassword = GetPasswordByUserName $domainInstallerUserName $config.Azure.ServiceAccounts.ServiceAccount

#if ($false){

Write-Host "Adding service account(s)"
#Get the hosted service WinRM Uri
[System.Uri]$DC_Uris = (GetVMConnection -ServiceName $dcServiceName -vmName $dcVmName)
if ($DC_Uris -eq $null){return}

#$domainSecPassword = ConvertTo-SecureString $domainInstallPassword -AsPlainText -Force
#$domainCredential = New-Object System.Management.Automation.PSCredential($domainInstallUserName, $domainSecPassword)
$domainCredential = (SetCredential -Username $domainInstallerUsername -Password $domainInstallerPassword)

$ouName = 'ServiceAccounts'
if(($config.Azure.ServiceAccounts.ServiceAccount | ?{$_.Create -eq "Yes"}) -ne $null){
   $serviceAccounts = $config.Azure.ServiceAccounts.ServiceAccount
   foreach($serviceAccount in $serviceAccounts)
   {
   	if($serviceAccount.Username.Contains('\') -and ([string]::IsNullOrEmpty($serviceAccount.Create) -or (-not $serviceAccount.Create.Equals('No'))))
   	{
   		$username = $serviceAccount.Username.Split('\')[1]
   		$password = $serviceAccount.Password
         AddServiceAccount `
         	-uris $DC_Uris `
            -credential $domainCredential `
            -ouName $ouName `
            -adUserName $username `
            -samAccountName $username `
            -displayName $username `
            -accountPassword $password      
         
   #		$adminPassword = GetPasswordByUsername $config.Azure.Connections.ActiveDirectory.ServiceAccountName $config.Azure.ServiceAccounts.ServiceAccount
   #      
   #		& $serviceAccountScriptPath -SubscriptionName $config.Azure.SubscriptionName -VMName $config.Azure.Connections.ActiveDirectory.DomainControllerVM `
   #		-ServiceName $config.Azure.Connections.ActiveDirectory.ServiceName `
   #		-OuName $ouName -ADUsername $username -SamAccountName $username -DisplayName $username -AccountPassword $password `
   #		-AdminUsername $config.Azure.Connections.ActiveDirectory.ServiceAccountName `
   #		-Password $adminPassword
   	}
   }
   Write-Host "Completed";Write-Host
}else{Write-Host "Skipping, No account(s) to add"}

# Provision VMs in each VM Role
$spFarmUsername = $config.Azure.SharePointFarm.FarmAdminUsername
$configDbName = $config.Azure.SharePointFarm.ConfigDBName
$isFirstServer = $true
$firstServerServiceName = [string]::Empty
$firstServerVmName = [string]::Empty

$vmRoles = $config.Azure.AzureVMGroups.VMRole
foreach($vmRole in $vmRoles)
{
	$subnetNames = @($vmRole.SubnetNames)
	$servicesToStart = @()
	foreach($saDeploymentGroup in $config.Azure.SharePointFarm.ServiceApplications.SADeploymentGroup)
	{
		if($saDeploymentGroup.StartOnVMRoles -ne $null -and $saDeploymentGroup.StartOnVMRoles.Contains($vmRole.Name))
		{
			foreach($serviceApp in $saDeploymentGroup.ServiceApplication)
			{
				$servicesToStart += @($serviceApp.DisplayName)
			}
		}
	}
	$affinityGroup = $config.Azure.AffinityGroup
   $vnetName = $config.Azure.VNetName
	foreach($azureVm in $vmRole.AzureVM)
	{		
		$dataDisks = @()
		foreach($dataDiskEntry in $vmRole.DataDiskSizesInGB.Split(';'))
		{
			$dataDisks += @($dataDiskEntry)
		}
		$availabilitySetName = $vmRole.AvailabilitySet
		if([string]::IsNullOrEmpty($availabilitySetName))
		{
			$availabilitySetName = $config.Azure.ServiceName
		}

		$password = GetPasswordByUsername $vmRole.AdminUsername $config.Azure.ServiceAccounts.ServiceAccount
		$spFarmPassword = GetPasswordByUsername $spFarmUsername $config.Azure.ServiceAccounts.ServiceAccount
		$domainInstallerPassword = GetPasswordByUsername $config.Azure.SharePointFarm.InstallerDomainUsername $config.Azure.ServiceAccounts.ServiceAccount
		$databaseInstallerPassword = GetPasswordByUsername $config.Azure.SharePointFarm.InstallerDatabaseUsername $config.Azure.ServiceAccounts.ServiceAccount
		$farmParaphrase = GetPasswordByUsername $config.Azure.SharePointFarm.FarmparaphraseServiceAccountName $config.Azure.ServiceAccounts.ServiceAccount
      $appPoolPassword = GetPasswordByUsername $config.Azure.SharePointFarm.ApplicationPoolAccount $config.Azure.ServiceAccounts.ServiceAccount

		& $spScriptPath -subscriptionName $config.Azure.SubscriptionName -storageAccount $config.Azure.StorageAccount `
		-vnetName $vnetName -subnetNames $subnetNames -vmName $azureVm.Name -serviceName $config.Azure.ServiceName -vmSize $vmRole.VMSize `
		-availabilitySetName $availabilitySetName -dataDisks $dataDisks -sqlServer $config.Azure.Connections.SQLServer.Instance `
		-configDbName $configDbName -createFarm $isFirstServer -affinityGroup $affinityGroup `
		-spFarmUsername $spFarmUsername -spServicesToStart $servicesToStart	-ImageName $vmRole.StartingImageName -AdminUserName $vmRole.AdminUsername `
		-AdminPassword $password -appPoolAccount $config.Azure.SharePointFarm.ApplicationPoolAccount -appPoolPassword $appPoolPassword `
      -DomainDnsName $config.Azure.Connections.ActiveDirectory.DnsDomain -endPoints $azureVm.endpoint `
		-DomainInstallerUsername $config.Azure.SharePointFarm.InstallerDomainUsername -DomainInstallerPassword $domainInstallerPassword `
      -DatabaseInstallerUsername $config.Azure.SharePointFarm.InstallerDatabaseUsername -DatabaseInstallerPassword $databaseInstallerPassword `
      -spFarmPassword $spFarmPassword -adminContentDbName $config.Azure.SharePointFarm.AdminContentDBName -spFarmParaphrase $farmParaphrase 
	
		if($isFirstServer)
		{
			$firstServerServiceName = $config.Azure.ServiceName
			$firstServerVmName = $azureVm.Name
			$isFirstServer = $false
		}
	}
}

#}
#$firstServerServiceName = "sp-m2esrp"
#$firstServerVmName = "MARS"

# Create Web Applications and top-level site
$databases = @()
if(-not [string]::IsNullOrEmpty($firstServerServiceName) -and -not [string]::IsNullOrEmpty($firstServerVmName))
{
	$spUris = GetVMConnection -ServiceName $firstServerServiceName -VMName $firstServerVmName
   
   $spusername = $config.Azure.SharePointFarm.InstallerDomainUserName
	$sppassword = GetPasswordByUserName $spusername $config.Azure.ServiceAccounts.ServiceAccount
   $spFarmCredential = (SetCredential -Username $spusername -Password $sppassword)
   
	$databaseUsername = $config.Azure.SharePointFarm.InstallerDatabaseUsername
	$databasePassword = GetPasswordByUsername $config.Azure.SharePointFarm.InstallerDatabaseUsername $config.Azure.ServiceAccounts.ServiceAccount
   $databaseCredential = (SetCredential -Username $databaseUsername -Password $databasePassword)
   $webApps = $config.Azure.SharePointFarm.WebApplications.WebApplication
   
	foreach($webApp in $webApps)
	{
      Invoke-Command -ComputerName $spUris[0].DnsSafeHost -Credential $spFarmCredential -Authentication Credssp -Port $spUris[0].Port -UseSSL `
      -ArgumentList $webApp.Name, $config.Azure.SharePointFarm.ApplicationPoolName, `
      $config.Azure.SharePointFarm.ApplicationPoolAccount, $webApp.Url, $webApp.TopLevelSiteName, `
      $webApp.TopLevelSiteTemplate, $webApp.TopLevelSiteOwner, $databaseCredential, `
      $config.Azure.ServiceName, $webApp.Port -ScriptBlock {
   		param([string]$name, [string]$appPoolName, [string]$appPoolAccount, [string]$url, [string]$siteName, [string]$siteTemplate,
         [string]$siteOwner, [Management.Automation.PSCredential]$databaseCredential, [string]$serviceName, [string]$port )
            
         $ProgressPreference = "SilentlyContinue"
			Add-PSSnapin Microsoft.SharePoint.PowerShell -WarningAction SilentlyContinue
			$existingWebApp = Get-SPWebApplication | Where-Object {$_.Url.Trim('/') -eq $url.Trim('/')}
            
         Write-Host "Checking Web Application $($url) " -NoNewline
			if($existingWebApp -eq $null)
			{
				Write-Host "... Creating" -NoNewline

            $authProvider = New-SPAuthenticationProvider -UseWindowsIntegratedAuthentication -UseBasicAuthentication
            # remove protocol for hostheader
            $hostHeader = $url.ToLower().Replace("http://", "")
            $hostHeader = $hostHeader.ToLower().Replace("https://", "")
				$spwebapp = New-SPWebApplication -Name $name -URL $url -Port $port -HostHeader $hostHeader -ApplicationPool $appPoolName -ApplicationPoolAccount $appPoolAccount -DatabaseCredentials $databaseCredential -AuthenticationProvider $authProvider
				$spsite = New-SPSite -name $siteName -url $url -Template $siteTemplate -OwnerAlias $siteOwner
				Write-Host -ForegroundColor Green "... Created"

            $AAMUrl = "http://" + $serviceName + ".cloudapp.net"
            Write-Host "Adding Alternative Access Mapping"
            Write-Host "   Web App $($url) "
            Write-Host "   AAM $($AAMUrl)"
            New-SPAlternateUrl -WebApplication $url -Url ($AAMUrl) -Zone Default | Out-Null
				Write-Host "Completed"
            
			}
			else
			{
				Write-Host -ForegroundColor Yellow "...Web application already exists."
			}
		}
	}
}

# Enable health probes for the WFEs to allow traffic in 
# Only needed for load balanced WFEs 
$vmRoles = $config.Azure.AzureVMGroups.VMRole
foreach($vmRole in $vmRoles)
{
   if($vmRole.Name -eq "SharePointWebServers")
   {
      Write-Host "Configuring Default Website to Allow Health Probes" -NoNewline 
      foreach($azureVm in $vmRole.AzureVM)
      {	
         $uri = Get-AzureWinRMUri -ServiceName $config.Azure.ServiceName -Name $azureVm.Name
         Invoke-Command -ConnectionUri $uri.ToString() -Credential $spFarmCredential -Authentication Credssp -ScriptBlock {  
            Set-ExecutionPolicy Unrestricted
            $ProgressPreference = "SilentlyContinue"

            Import-Module WebAdministration -WarningAction SilentlyContinue
            # Open up the firewall for 8080                
            netsh advfirewall firewall add rule name="LB Health Check 8080" protocol=TCP dir=in localport=8080 action=allow | Out-Null
            # Change default website to listen on 8080
            Set-WebBinding -Name 'Default Web Site' -BindingInformation "*:80:" -PropertyName Port -Value 8080 -WarningAction SilentlyContinue | Out-Null
            # Tell default website to start on iisreset
            Set-ItemProperty 'IIS:\Sites\Default Web Site' serverAutoStart True
            iisreset | Out-Null
            Start-WebSite "Default Web Site" | Out-Null
         }
      }
      Write-Host -ForegroundColor Green "... Complete"
   }
}

 
## End script