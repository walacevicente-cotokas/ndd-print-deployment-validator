# Validation logic

## NDD web service checks

Each configured NDD endpoint is validated using independent checks:

1. **DNS resolution** — verifies that the hostname resolves to one or more IP addresses.
2. **ICMP/ping** — informational only. Many enterprise networks block ICMP while HTTPS remains functional.
3. **TCP connectivity** — tests whether a TCP connection can be established to the configured service port (443 for current Global endpoints).
4. **HTTPS response** — performs an HTTPS request to confirm that the remote service can be reached through the Windows networking/proxy stack.

An endpoint is considered `PASS` when DNS, TCP and HTTPS succeed. Ping does not affect the result.

## Required vs optional endpoints

The endpoint profile marks services as `required` or `optional` for the initial readiness result. This is deliberately configuration-driven so deployment profiles can evolve without changing the validator engine.

## Printer checks

When a printer IP is supplied, the current version tests:

- ICMP
- TCP 80
- TCP 443
- TCP 9100

UDP 161 is displayed as informational in v0.1. A generic UDP socket check cannot reliably prove that an SNMP agent is responding. A future version should perform an actual SNMP GET against a safe OID.

## Overall status

`READY` means that all endpoints marked as required in the active profile passed the DNS + TCP + HTTPS checks.

`NOT_READY` means one or more required endpoints failed.

The overall status currently evaluates NDD external connectivity only. Server, Active Directory, SQL and Host/Releaser-specific requirements will be added as dedicated readiness modules.

## Security

The report should avoid collecting credentials, passwords, LDAP secrets, database passwords or other sensitive data. Network, OS and domain metadata are collected only to support deployment diagnosis.
