# Intune Backup

This repository creates daily backups of Microsoft Intune configuration using the [IntuneManagement](runtime/IntuneManagement/) PowerShell tool, automated via GitHub Actions.

---

## 1. Azure / Entra ID Setup

Run [`setup/New-IntuneBackupAppRegistration.ps1`](setup/New-IntuneBackupAppRegistration.ps1) to automate steps 1.1-1.5. It requires `Application Administrator` or `Global Administrator` in the target tenant and outputs the three values needed as GitHub secrets.

To run manually instead:

| # | Task | Detail |
|---|------|--------|
| 1.1 | **Create App Registration** | New registration in your Entra ID |
| 1.2 | **Note Tenant ID** | Directory (tenant) ID - GUID format |
| 1.3 | **Note Client ID** | Application (client) ID - GUID format |
| 1.4 | **Create Client Secret** | Generate a secret; note the value immediately (shown once). Recommend 12-month validity minimum |
| 1.5 | **Grant API Permissions** | Add the Microsoft Graph **Application** permissions below and grant admin consent |

### Required Graph API Permissions

| Permission | Why |
|------------|-----|
| `DeviceManagementApps.Read.All` | App configs & protection policies |
| `DeviceManagementConfiguration.Read.All` | Device config, compliance, settings catalog |
| `DeviceManagementManagedDevices.Read.All` | Managed device data |
| `DeviceManagementRBAC.Read.All` | Role definitions, scope tags |
| `DeviceManagementScripts.Read.All` | PowerShell & shell scripts |
| `DeviceManagementServiceConfig.Read.All` | Enrollment, Autopilot, branding |
| `Application.Read.All` | App registration metadata |
| `Agreement.Read.All` | Terms of Use |
| `CloudPC.Read.All` | Windows 365 provisioning/user settings |
| `Organization.Read.All` | Tenant/company info |
| `Policy.Read.All` | Conditional access, named locations |
| `Group.Read.All` | Group assignments |

> All permissions are **read-only**. Grant admin consent after adding them.

---

## 2. GitHub Repository Setup

| # | Task | Detail |
|---|------|--------|
| 2.1 | **Create repository** | Fork this repo or create a new private repository |
| 2.2 | **Set default branch** | Must be `main` |
| 2.3 | **Enable GitHub Actions** | Settings -> Actions -> Allow all actions |
| 2.4 | **Add repository secrets** | Settings -> Secrets and variables -> Actions |

### Secrets to Configure

| Secret Name | Value |
|-------------|-------|
| `AZURE_TENANT_ID` | Tenant ID from step 1.2 |
| `AZURE_CLIENT_ID` | Client ID from step 1.3 |
| `AZURE_CLIENT_SEC` | Client secret value from step 1.4 |

---

## 3. Configuration Review

[config/BulkExport.json](config/BulkExport.json) controls what gets exported. Review these settings before the first run:

| Setting | Default | Action |
|---------|---------|--------|
| `txtExportPath` | `.\release` | Keep unless a custom path is needed |
| `chkExportAssignments` | `true` | Recommended: keep enabled |
| `chkExportScript` | `true` | Recommended: keep enabled |
| `chkExportApplicationFile` | `false` | Keep false - `.intunewin` files are large and not cleanly API-exportable |
| `chkAddCompanyName` | `false` | Enable if managing multiple tenants in one repo |
| Object type list | 35+ types | Remove any object types not used in your tenant |

---

## 4. Backup Schedule

The workflow [.github/workflows/Backup-And-Release.yml](.github/workflows/Backup-And-Release.yml) runs **daily at 02:00 UTC** by default.

- Confirm this time does not conflict with any Intune maintenance windows
- Adjust the cron expression in the workflow file if a different time is needed: `cron: '0 2 * * *'`

---

## 5. Known Limitations

| Item | Status |
|------|--------|
| `.intunewin` application packages | **Not backed up** - must be stored separately |
| Terms of Use PDF files | **Not backed up** - must be stored separately |
| Custom ADMX/ADML files | **Not backed up** - must be stored separately |
| Android Store App sync | Cannot be restored via API - requires manual re-sync |
| Assigned group names | Exported by ID; groups must exist in the target tenant for import |
