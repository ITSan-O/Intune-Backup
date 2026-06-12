#Requires -Version 5.1
<#
.SYNOPSIS
    Creates an Entra ID App Registration for IntuneBackup with all required permissions.
.DESCRIPTION
    Automates README.md steps 1.1-1.5:
      - Creates an App Registration in the customer's Entra ID
      - Adds all required Microsoft Graph application permissions (read-only)
      - Creates a client secret
      - Grants admin consent
      - Outputs the three values needed as GitHub secrets

    Requires 'Application Administrator' or 'Global Administrator' in the target tenant.
.PARAMETER AppName
    Display name for the App Registration. Defaults to 'IntuneBackup'.
.PARAMETER SecretValidityMonths
    Validity period for the client secret in months. Defaults to 12.
.EXAMPLE
    .\New-IntuneBackupAppRegistration.ps1
.EXAMPLE
    .\New-IntuneBackupAppRegistration.ps1 -AppName 'IntuneBackup-Contoso' -SecretValidityMonths 24
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$AppName = 'IntuneBackup',
    [ValidateRange(1, 24)]
    [int]$SecretValidityMonths = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Required Microsoft Graph application permissions (all read-only)
$RequiredPermissions = @(
    'DeviceManagementApps.Read.All'
    'DeviceManagementConfiguration.Read.All'
    'DeviceManagementManagedDevices.Read.All'
    'DeviceManagementRBAC.Read.All'
    'DeviceManagementScripts.Read.All'
    'DeviceManagementServiceConfig.Read.All'
    'Application.Read.All'
    'Agreement.Read.All'
    'CloudPC.Read.All'
    'Organization.Read.All'
    'Policy.Read.All'
    'Group.Read.All'
)

# Microsoft Graph well-known app ID (same in all tenants)
$MsGraphAppId = '00000003-0000-0000-c000-000000000000'

function Write-Step {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

#region --- Prerequisites ---

Write-Host "`nIntuneBackup - App Registration Onboarding" -ForegroundColor Yellow
Write-Host "==========================================`n" -ForegroundColor Yellow

Write-Step "Checking for Microsoft.Graph PowerShell module..."
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications')
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Step "Installing '$module' (CurrentUser scope)..."
        Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
    }
}
Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Applications -ErrorAction Stop
Write-Success "Module ready."

#endregion

#region --- Connect ---

$RequiredScopes = @(
    'Application.ReadWrite.All'
    'AppRoleAssignment.ReadWrite.All'
    'Directory.Read.All'
)

$context = Get-MgContext
if ($context) {
    $missingScopes = $RequiredScopes | Where-Object { $_ -notin $context.Scopes }
    if ($missingScopes) {
        Write-Step "Existing connection found but missing scopes: $($missingScopes -join ', '). Re-authenticating..."
        Connect-MgGraph -Scopes $RequiredScopes -NoWelcome -ErrorAction Stop
        $context = Get-MgContext
    } else {
        Write-Success "Reusing existing Graph connection (tenant: $($context.TenantId))."
    }
} else {
    Write-Step "Connecting to Microsoft Graph (browser sign-in will open)..."
    Write-Host "    You need 'Application Administrator' or 'Global Administrator' in the target tenant.`n"
    Connect-MgGraph -Scopes $RequiredScopes -NoWelcome -ErrorAction Stop
    $context = Get-MgContext
}

$tenantId = $context.TenantId
Write-Success "Connected to tenant: $tenantId"

#endregion

#region --- Resolve Graph permission GUIDs ---

# Use Invoke-MgGraphRequest (raw HTTP) to avoid the PS module's incremental-consent logic
# which re-triggers a login prompt when the -Filter parameter is evaluated.
Write-Step "Resolving Microsoft Graph permission IDs..."
$graphSpRaw = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$MsGraphAppId'&`$select=id,appRoles" `
    -Headers @{ ConsistencyLevel = 'eventual' } |
    Select-Object -ExpandProperty value |
    Select-Object -First 1

if (-not $graphSpRaw) {
    throw "Microsoft Graph service principal not found in this tenant."
}

$graphSpId = $graphSpRaw.id
$appRoles  = $graphSpRaw.appRoles   # array of objects from JSON deserialization

$resourceAccess = foreach ($permName in $RequiredPermissions) {
    $role = $appRoles | Where-Object { $_.value -eq $permName }
    if (-not $role) {
        Write-Warning "Permission '$permName' not found in Microsoft Graph - skipping."
        continue
    }
    @{ Id = $role.id; Type = 'Role' }
}

$requiredResourceAccess = @{
    ResourceAppId  = $MsGraphAppId
    ResourceAccess = $resourceAccess
}

Write-Success "Resolved $($resourceAccess.Count) of $($RequiredPermissions.Count) permissions."

#endregion

#region --- Create App Registration ---

Write-Step "Checking for existing app registration named '$AppName'..."
$existingApp = Get-MgApplication -Filter "displayName eq '$AppName'" -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($existingApp) {
    Write-Host "    [WARN] App registration '$AppName' already exists (AppId: $($existingApp.AppId))." -ForegroundColor Yellow
    $response = Read-Host "    Use existing app and update its permissions? (Y/N)"
    if ($response -notin 'Y', 'y') {
        Write-Host "Aborted." -ForegroundColor Red
        Disconnect-MgGraph | Out-Null
        exit 1
    }
    Update-MgApplication -ApplicationId $existingApp.Id -RequiredResourceAccess @($requiredResourceAccess) | Out-Null
    $app = Get-MgApplication -ApplicationId $existingApp.Id
    Write-Success "Existing app updated."
} else {
    if ($PSCmdlet.ShouldProcess($AppName, 'Create App Registration')) {
        $app = New-MgApplication -DisplayName $AppName -RequiredResourceAccess @($requiredResourceAccess)
        Write-Success "App registration created (AppId: $($app.AppId))."
    }
}

$clientId = $app.AppId

#endregion

#region --- Ensure Service Principal ---

Write-Step "Ensuring service principal exists for admin consent..."
$spRaw = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$clientId'&`$select=id,appId" `
    -Headers @{ ConsistencyLevel = 'eventual' } |
    Select-Object -ExpandProperty value |
    Select-Object -First 1

if (-not $spRaw) {
    if ($PSCmdlet.ShouldProcess($AppName, 'Create Service Principal')) {
        $spRaw = New-MgServicePrincipal -AppId $clientId
    }
    Write-Success "Service principal created."
} else {
    Write-Success "Service principal already exists."
}

$spId = $spRaw.id

#endregion

#region --- Grant Admin Consent ---

Write-Step "Granting admin consent for all application permissions..."
$existingAssignments = Invoke-MgGraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignments" |
    Select-Object -ExpandProperty value

$consentCount = 0
foreach ($permName in $RequiredPermissions) {
    $role = $appRoles | Where-Object { $_.value -eq $permName }
    if (-not $role) { continue }

    $alreadyGranted = $existingAssignments |
        Where-Object { $_.appRoleId -eq $role.id -and $_.resourceId -eq $graphSpId }

    if (-not $alreadyGranted) {
        if ($PSCmdlet.ShouldProcess($permName, 'Grant app role assignment')) {
            Invoke-MgGraphRequest -Method POST `
                -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignments" `
                -Body @{
                    principalId = $spId
                    resourceId  = $graphSpId
                    appRoleId   = $role.id
                } | Out-Null
            $consentCount++
        }
    }
}
Write-Success "Admin consent granted ($consentCount new assignments)."

#endregion

#region --- Create Client Secret ---

Write-Step "Creating client secret (validity: $SecretValidityMonths months)..."
$secretExpiry = (Get-Date).AddMonths($SecretValidityMonths)

if ($PSCmdlet.ShouldProcess($AppName, 'Add client secret')) {
    $secretResult = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential @{
        DisplayName = "IntuneBackup-$(Get-Date -Format 'yyyy-MM-dd')"
        EndDateTime = $secretExpiry
    }
    $clientSecret = $secretResult.SecretText
}

Write-Success "Client secret created. Expires: $($secretExpiry.ToString('yyyy-MM-dd'))."

#endregion

#region --- Output ---

$separator = '─' * 60
Write-Host "`n$separator" -ForegroundColor Yellow
Write-Host "  GitHub Secrets - add these to your repository:" -ForegroundColor Yellow
Write-Host $separator -ForegroundColor Yellow
Write-Host ""
Write-Host "  AZURE_TENANT_ID  =  $tenantId"
Write-Host "  AZURE_CLIENT_ID  =  $clientId"
Write-Host "  AZURE_CLIENT_SEC =  $clientSecret"
Write-Host ""
Write-Host "  Secret expires:  $($secretExpiry.ToString('yyyy-MM-dd'))" -ForegroundColor Yellow
Write-Host ""
Write-Host "  ! Copy the client secret now - it will not be shown again." -ForegroundColor Red
Write-Host $separator -ForegroundColor Yellow

Write-Host "`nNext steps:" -ForegroundColor Cyan
Write-Host "  1. In your GitHub repo: Settings → Secrets and variables → Actions"
Write-Host "  2. Add AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SEC"
Write-Host "  3. Enable GitHub Actions (Settings → Actions → Allow all actions)"
Write-Host "  4. Run the 'Backup-And-Release' workflow manually to verify"
Write-Host "  5. Calendar secret renewal for $($secretExpiry.ToString('yyyy-MM-dd'))`n"

# Optional: save output to file
$saveToFile = Read-Host "Save these values to a local text file? (Y/N)"
if ($saveToFile -in 'Y', 'y') {
    $outPath = Join-Path $PSScriptRoot "IntuneBackup-Secrets-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    @"
IntuneBackup App Registration Output
Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
App Name  : $AppName
=========================================
AZURE_TENANT_ID  = $tenantId
AZURE_CLIENT_ID  = $clientId
AZURE_CLIENT_SEC = $clientSecret
Secret Expires   = $($secretExpiry.ToString('yyyy-MM-dd'))
=========================================
SECURITY: Store this file in a password manager or customer key vault.
Delete this file once secrets are stored securely.
"@ | Set-Content -Path $outPath -Encoding UTF8
    Write-Host "`n  Saved to: $outPath" -ForegroundColor Green
    Write-Host "  WARNING: Delete this file after storing the secret securely.`n" -ForegroundColor Red
}

#endregion

Disconnect-MgGraph | Out-Null
Write-Host "Disconnected from Microsoft Graph. Onboarding complete.`n" -ForegroundColor Green
