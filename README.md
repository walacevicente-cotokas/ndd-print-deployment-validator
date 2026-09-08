# NDD Print Deployment Validator

A PowerShell-based pre-deployment validation tool for NDD Print environments.

The goal is simple: allow a customer or technician to run one script on the target Windows server and generate a clear report showing whether the environment is ready for an NDD Print deployment.

## What it validates

### Server readiness
- Windows / Windows Server information
- Installed RAM
- Free disk space
- **.NET Framework 3.5** status
- **.NET Framework 4.8** release/status
- Hostname and domain context

Current default thresholds used by the validator:
- RAM: 4 GB minimum
- Free disk: 10 GB minimum
- .NET Framework 3.5: required
- .NET Framework 4.8 or later: required

### Active Directory / LDAP
When the server is domain joined, the validator attempts to verify:
- Domain membership
- Domain Controller discovery
- DNS resolution of the Domain Controller
- LDAP TCP 389 connectivity

AD readiness is reported separately so an environment can be diagnosed without assuming every deployment uses the same directory scenario.

### Network and proxy
- WinHTTP proxy configuration
- DNS resolution for NDD services
- TCP 443 connectivity
- HTTPS response

### NDD Global web services
The default Global profile tests:

- `wsnpl.nddprint.com` — accounting files (NPL) and imports
- `wsnsl.nddprint.com` — monitoring files (NSL)
- `wsnpa.nddprint.com` — event files (NPA)
- `wsnsu.nddprint.com` — users, accounts and groups synchronization
- `wscontrol.nddprint.com` — policy, quota and credential synchronization
- `sync-host.nddprint.com` — Host cache/configuration synchronization
- `wsmobile.nddprint.com` — NDD Print Mobile user data
- `wshost.nddprint.com` — remote printer registration
- `api-agents.nddprint.com` — MPS-managed Host configuration exchange
- `hubs.nddprint.com` — requests pending file uploads from Host

> ICMP/ping is informational only. A failed ping does not automatically mean the endpoint is unavailable. DNS, TCP 443 and HTTPS are the relevant checks.

### Printer connectivity
The user can optionally provide a printer IP address. The validator currently checks:
- ICMP reachability
- TCP 80
- TCP 443
- TCP 9100
- SNMP is currently shown as `NOT_VALIDATED` until a real SNMP GET is implemented

## Output

The tool generates:

- `output/NDD-Validation-<computer>-<timestamp>.txt`
- `output/NDD-Validation-<computer>-<timestamp>.json`

The TXT report is designed to be sent by a customer or attached to a support ticket. The JSON report is intended for structured analysis and future automation.

## Usage

Recommended:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\NDD-Deployment-Validator.ps1"
```

Or run the launcher as a file:

```text
Run-NDDValidation.bat
```

Do not paste the contents of the `.bat` file into PowerShell. It is a CMD launcher.

## Current status

**v0.2**

Implemented:
- Server inventory
- RAM and free-disk readiness
- .NET Framework 3.5 validation
- .NET Framework 4.8 validation
- WinHTTP proxy detection
- AD / Domain Controller / LDAP 389 basic validation
- NDD Global endpoint validation
- Optional printer connectivity validation
- TXT and JSON report generation

Planned next steps:
- Real SNMP GET validation
- NDD Host/Releaser communication matrix
- Additional AD/LDAP checks and configurable LDAP targets
- SQL Server readiness
- Better actionable remediation messages
- Packaging / one-click customer experience

## Disclaimer

This is an independent community project and is not an official NDD product. Endpoint names and technical requirements should always be compared with the latest official NDD documentation before use in production.
