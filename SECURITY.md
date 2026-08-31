# Security Policy

## Scope

This policy applies to the Open HamClock Backend (OHB) repository and all officially documented deployment configurations, including:

- Lighttpd-based HTTP deployments  
- Python and Perl CGI services  
- Map generation scripts  
- PSKReporter and NOAA ingestion services  
- Docker container deployments via manage-ohb-docker.sh  
- VOACAP proxy and MUF endpoints  

It does not cover third-party infrastructure, upstream NOAA feeds, PSKReporter systems, or unofficial forks.

---

## Supported Versions

OHB follows a rolling-release model. Only the `main` branch and the latest tagged release are supported with security updates.

| Branch / Version | Supported |
|------------------|-----------|
| `main`           | Yes       |
| Latest tag       | Yes       |
| Older tags       | No        |
| Forks            | No        |

Deployments pinned to historical commits are considered unsupported.

---

## Security Model Overview

OHB is designed as a stateless backend serving:

- Small text data files (solarflux, kindex, dst, etc.)
- Zlib-compressed BMP map assets
- CGI endpoints (e.g., fetchPSKReporter, fetchVOACAP)

Primary exposure is via HTTP (port 80 by default). No authentication layer is built in.

Key assumptions:

- Intended for public read-only access  
- No user account system  
- No persistent user-submitted data storage  
- Limited write permissions under webroot  

---

## Threat Model Considerations

### Primary Risk Areas

1. **Remote Code Execution via CGI scripts**
   - Improper input validation  
   - Shell injection in Bash wrappers  
   - Unsafe subprocess calls in Python  

2. **Proxy Abuse**
   - PSKReporter or VOACAP proxy endpoints used for reflection or amplification  
   - Header replay vulnerabilities (e.g., multipart `X-2Z-lengths` handling)  

3. **Resource Exhaustion**
   - High request volume from many HamClock clients  
   - Unbounded map generation  
   - Cron jobs overlapping  

4. **Dependency Vulnerabilities**
   - Python packages (numpy, pandas, requests, paho-mqtt)  
   - GMT  
   - Lighttpd  
   - Perl modules  

5. **Misconfiguration**
   - Incorrect file permissions  
   - Writable CGI directories  
   - Exposed internal endpoints  

---

## Secure Deployment Requirements

Deployments SHOULD:

- Run under a dedicated non-root user  
- Use read-only permissions on served static files  
- Restrict write access to cache directories only  
- Disable directory listing  
- Avoid running CGI scripts as root  
- Use systemd sandboxing where possible  
- Apply OS security updates regularly  
- Rate-limit proxy endpoints  
- Consider reverse proxy filtering if exposed to the internet  

Deployments SHOULD NOT:

- Expose administrative scripts  
- Run on shared hosting without isolation  
- Enable arbitrary query passthrough to upstream systems  

---

## Reporting a Vulnerability

If you discover a security vulnerability in OHB:

1. **Do NOT open a public issue.**
2. Use GitHub Private Reporting

Include:

- Description of the vulnerability  
- Steps to reproduce  
- Affected endpoint or script  
- Example payload (if applicable)  
- Impact assessment  

### Response Timeline

- Initial acknowledgment: within 72 hours  
- Triage assessment: within 7 days  
- Patch timeline: depends on severity  

If accepted:

- A fix will be developed in a private branch  
- A patched release will be tagged  
- Advisory notes will be published  

If declined:

- Rationale will be provided  

---

## Coordinated Disclosure

Please allow reasonable time for remediation before public disclosure.

Critical vulnerabilities (RCE, data exfiltration, privilege escalation) will be prioritized.

---

## Dependency Management

Security updates may require:

- Updating Python virtual environment dependencies  
- Updating Lighttpd configuration  
- Updating GMT or system libraries  

Users are responsible for maintaining their OS-level security patches.

---

## Out-of-Scope

The following are not considered vulnerabilities:

- Denial-of-service via extreme client polling  
- Abuse of publicly accessible data feeds  
- Issues in upstream NOAA or PSKReporter systems  
- Attacks against improperly secured third-party deployments  

---

## Maintainer Notes

Before publishing:

- Ensure a monitored security email exists  
- Consider creating a dedicated security alias  
- Decide whether CVE issuance will be supported  
- Verify install scripts do not execute privileged code unnecessarily  
- Confirm no undocumented administrative endpoints exist  
