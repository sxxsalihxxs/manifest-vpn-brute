## STAR — Authorized MariaDB Authentication Assessment

> ⚠️ This work was performed **only** on a system with **written
> authorization**, as part of an authorized security assessment.

### Situation
During a security engagement, I was asked to evaluate the
authentication resilience of an internet-exposed MariaDB (MySQL, 3306)
service. The service applied source-IP based rate-limiting / temporary
blocking (IP ban) against unauthorized access attempts.

### Task
To test — under authorization — whether weak or default credentials
were in use, and to what extent the existing defenses (connection-error
threshold, IP blocking) actually slowed down an attack; then to report
the findings and remediation recommendations.

### Action
- Confirmed the scope, target, and written permission before any work.
- Ran a controlled credential-strength test using common username /
  password lists.
- Observed the service's defensive behavior: after a number of failed
  attempts, the source IP was temporarily blocked.
- Kept the testing low-impact — limited concurrency and added wait
  intervals so the target service was not overloaded.

### Result
- **Finding:** Source-IP based blocking alone was not a sufficient
  defense; against a distributed / IP-rotating attacker it slowed the
  pace but did not fully stop the attack.
- **Risk:** Weak credentials combined with a defense that relies only
  on IP blocking do not provide durable protection against brute-force.
- **Remediation:**
  - Strong, unique password policy and, where possible, multi-factor
    authentication / certificate-based access.
  - Do not expose the database directly to the internet; allow access
    only via VPN / bastion host / allow-list.
  - In addition to source-IP blocking: account-based lockout,
    exponential backoff, and rate/anomaly-based detection.
  - Centralized logging and alerting of failed authentication attempts
    (SIEM).

### Takeaway
IP-based blocking is a speed bump, not a solution. Durable protection
comes from strong credentials, a reduced attack surface, and layered
detection and response.
