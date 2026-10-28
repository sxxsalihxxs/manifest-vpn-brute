# VPN Rotation & MariaDB Authentication Testing

A Bash-based security research project exploring MariaDB authentication testing, VPN connection rotation, connection-state monitoring, and Hydra session recovery in authorized lab environments.

> **⚠️ Disclaimer**
>
> This project is intended for security research and controlled, explicitly authorized lab environments only. Automated password guessing and IP rotation can violate laws, service policies, and organizational security rules. Never use this tool against systems without explicit written authorization.

## Overview

The project combines several Linux command-line tools to explore authentication-testing workflows and network connection behavior.

The script includes:
- **MariaDB connectivity checks:** Tests whether a target database responds to connection attempts.
- **VPN configuration management:** Retrieves OpenVPN configurations from VPNGate or loads manually supplied configurations.
- **Connection rotation:** Attempts to establish VPN connections and checks the resulting public IP address.
- **Hydra integration:** Implements automated authentication testing using configured username and password wordlists.
- **Session recovery:** Preserves Hydra restore state when an interrupted run may need to resume.
- **Logging and monitoring:** Tracks test output, connection status, and the number of attempts.
- **Input validation:** Accepts a target address and configurable database port.

## Technology Stack

| Technology | Purpose |
|---|---|
| Bash | Automation and workflow orchestration |
| Hydra | Authentication testing |
| MariaDB / MySQL client | Database connectivity checks |
| OpenVPN | VPN connection management |
| VPNGate | VPN configuration source |
| SecLists | Username and password wordlists |
| cURL, AWK, grep, sed | Data retrieval and text processing |
| Linux | Execution environment |

## Requirements

The script expects a Linux environment with the following tools available:

- Bash
- Hydra
- MySQL command-line client
- OpenVPN
- cURL
- AWK, grep, sed, and other standard utilities
- SecLists username and password wordlists

The script also expects a Desktop directory and creates working files under `~/Desktop/rotate`.

## Configuration

The script supports the following command-line options:

| Option | Description |
|---|---|
| `-t`, `--target` | Target database IP address or hostname |
| `-p`, `--port` | Database port; defaults to `3306` |
| `--fresh` | Removes the saved restore state before starting |
| `-h`, `--help` | Displays usage information |

The program requests an authorization confirmation unless the relevant environment variable is set.

## Security Considerations

This implementation combines automated credential guessing with VPN rotation. This can bypass IP-based rate limits and account-lockout protections, so it must not be used to circumvent security controls on third-party systems.

Before using or publishing the project, consider the following safeguards:

- Use an isolated lab and dedicated test accounts.
- Obtain written authorization and define a strict testing scope.
- Prefer fixed, explicitly approved VPN endpoints over automatically sourced public configurations.
- Enforce a hard maximum on authentication attempts and execution time.
- Protect logs and recovery files because they may contain sensitive information.
- Validate cleanup behavior and ensure VPN processes terminate safely.
- Never store real credentials or production secrets in the repository.
- Use controlled test cases to evaluate rate limiting, alerting, and account-lockout behavior.

## Known Limitations

- VPNGate endpoint availability and connection reliability may vary.
- A changed public IP does not guarantee that a database connection is permitted.
- Network filtering, database configuration, and account policies can affect connectivity checks.
- The script relies on particular SecLists directory and filename conventions.
- The script should be reviewed and tested in an isolated environment before any authorized use.

## Project Status

**Experimental — security research and lab testing.**

The project is not intended for production deployment. Further work should focus on safe test controls, reliable error handling, improved configuration management, and defensive monitoring integration.

## License

No license has been specified yet. Add an appropriate license file before permitting reuse, modification, or redistribution.

## Author

Developed as a cybersecurity research project focused on Linux automation, database authentication behavior, and network security testing.
