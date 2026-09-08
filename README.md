# NDD Print Deployment Validator

A PowerShell-based pre-deployment validation tool for NDD Print environments.

The goal is simple: allow a customer or technician to run one script on the target Windows server and generate a clear report showing whether the environment is ready for an NDD Print deployment.

## What it validates

### Server readiness
- Windows / Windows Server information
- .NET Framework release
- Installed RAM
- Free disk space
- Hostname and domain context

### Network and proxy
- DNS configuration
- Default gateway
- WinHTTP proxy configuration
- Internet connectivity

### NDD Global web services
The validator tests DNS resolution and HTTPS/TCP 443 connectivity to the main NDD Global services used by NDD Print Host:

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
- `agent.nddorbix.com` — Orbix application/server/service/log monitoring

> ICMP/ping is informational only. A failed ping does not automatically mean the endpoint is unavailable. DNS, TCP 443 and HTTPS are the relevant checks.

### Printer connectivity
The user can optionally provide a printer IP address. The validator checks:

- ICMP reachability
- TCP 80
- TCP 443
- TCP 9100
- basic UDP 161/SNMP reachability indication

## Output

The tool generates two files in the `output` folder:

- `NDD-Validation-<computer>-<timestamp>.txt`
- `NDD-Validation-<computer>-<timestamp>.json`

The TXT report is designed to be sent directly by a customer or attached to a support ticket. The JSON report is intended for structured analysis and future automation.

## Usage

Open PowerShell as Administrator and run:

```powershell
.\NDD-Deployment-Validator.ps1
```

You can also provide a printer IP directly:

```powershell
.\NDD-Deployment-Validator.ps1 -PrinterIP 192.168.1.50
```

## Project structure

```text
ndd-print-deployment-validator/
├── NDD-Deployment-Validator.ps1
├── config/
│   └── ndd-global-endpoints.json
├── docs/
│   └── validation-logic.md
├── output/
│   └── .gitkeep
└── README.md
```

## Current status

**v0.1**

Initial implementation includes:

- Server inventory
- Proxy detection
- NDD Global endpoint validation
- Optional printer connectivity validation
- TXT and JSON report generation

Planned next steps:

- Active Directory / LDAP readiness
- SQL Server readiness
- NDD Host/Releaser port matrix
- More reliable SNMP validation
- Vendor/device profiles
- Comparison between previous and current validation reports

## Disclaimer

This is an independent community project and is not an official NDD product. Endpoint names and technical requirements should always be compared with the latest official NDD documentation before use in production.
