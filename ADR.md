# ADR-001: Migrate Identity Server from Azure App Service to AWS ECS Fargate

**Status:** Proposed
**Date:** 2026-09-08
**Author:** Alex Holodak, Staff DevOps Engineer
**Deciders:** Platform Engineering, Security, LMS and Integrations team leads

---

## 1. Context

The Identity Server is a .NET 6 authentication and token-issuance service that every StrongMind product depends on. It is the last critical workload still running in Azure:

| Component | Current state |
|---|---|
| Runtime | .NET 6, Azure App Service (Linux) |
| Database | Azure SQL Database, SQL Server 2019 compatibility level |
| Secrets | Azure Key Vault: connection strings, JWT signing certificates, API keys |
| Traffic | ~400 req/min sustained, ~1,200 req/min peak 7-9 AM Mountain during school start |
| Upstream dependency | Azure AD Domain Services (directory lookups) |
| Downstream callers | Rails LMS, PowerSchool integration, other StrongMind products |

**Why migrate now**

- Everything else runs on ECS Fargate. This is the only service where on-call needs a second console, alerting path, and IAM model, and it is the one service whose failure takes every product down.
- Observability is split. The Azure side is not wired into the CloudWatch and Jira Operations pipeline the rest of the platform uses (see OBSERVABILITY.md).
- .NET 6 reached end of support in November 2024. The runtime upgrade is needed regardless and is far easier on a containerized build.
- One cloud eliminates cross-cloud egress and simplifies the Azure enterprise agreement renewal.

**Constraints**

- Zero downtime for token validation. Token issuance may tolerate a single scheduled window of a few minutes outside school hours.
- Downstream callers (especially PowerSchool) cannot be assumed to redeploy on our schedule. The public hostname and the OIDC discovery document must not change.
- No code changes to the Identity Server beyond configuration during the migration. Runtime upgrade is a separate, later change.

**Assumptions**

- The service is Duende IdentityServer or IdentityServer4 on ASP.NET Core with EF Core, persisting operational data (persisted grants, refresh tokens, device codes) and configuration in Azure SQL.
- Signing certificates are stored in Key Vault as certificates (exportable PFX) and loaded at startup. Tokens are RS256 JWTs validated offline by callers via the `/.well-known/openid-configuration/jwks` endpoint.
- ASP.NET Data Protection keys are currently stored in Key Vault or Azure Blob. These encrypt auth cookies and server-side state and must survive the migration.
- The directory lookups against Azure AD DS are LDAP/LDAPS, not Graph API, so they require private network reachability.
- StrongMind's public DNS is already in Route 53.

## 2. Decision

**Containerize the Identity Server as-is on .NET 6, deploy it to ECS Fargate behind an Application Load Balancer, migrate the database to Amazon RDS for SQL Server using AWS DMS with change data capture, move secrets to AWS Secrets Manager, and cut over with a database-first sequence followed by Route 53 weighted routing for compute.**

Azure AD Domain Services is not migrated in this ADR. It remains reachable over a site-to-site VPN and is replaced in a follow-up ADR (candidates: AWS Managed Microsoft AD, or removing the LDAP dependency in favor of a synced user store).

### Options considered

| Option | Assessment | Verdict |
|---|---|---|
| **A. Lift-and-shift to ECS Fargate + RDS SQL Server** | Fewest moving parts. No code changes. Same engine, so EF Core migrations and stored procedures work unchanged. | **Chosen.** Lowest risk for a service with zero tolerance for auth regressions. |
| B. Re-platform to Amazon Cognito | Eliminates the service, but custom claims, PowerSchool grant types, and Data Protection state do not map cleanly. Multi-quarter, every product changes. | Rejected here. Worth a separate evaluation. |
| C. ECS Fargate + Aurora PostgreSQL | Cheaper to run, but needs an EF Core provider swap, T-SQL rewrites, and heterogeneous DMS with schema conversion. Adds application risk to an infrastructure migration. | Rejected. Reconsider once stable on AWS. |
| D. EKS instead of ECS | No EKS footprint at StrongMind. A new control plane and operating model for one service. | Rejected. Platform consistency wins. |

The core principle: **change one thing at a time.** Cloud provider changes now. Runtime version, database engine, and directory service change later, each with their own ADR.

## 3. Migration Architecture

### 3.1 ECS Fargate service

**Task definition** (family `identity-server`, Fargate, `awsvpc`, Linux/X86_64):

| Setting | Value | Reasoning |
|---|---|---|
| CPU / memory | 1 vCPU / 2 GB | .NET 6 with EF Core idles at 250-350 MB and the JIT is CPU-hungry on cold start. Sized for startup and GC headroom; 20 req/s peak is trivial. |
| Container port | 8080 | Non-root cannot bind 80. `ASPNETCORE_URLS=http://+:8080`; TLS terminates at the ALB. |
| Desired count | 3 (min 3, max 12) | One per AZ, so losing an AZ leaves two. Two tasks absorb 1,200 req/min. |
| Auto scaling | Target tracking: `ALBRequestCountPerTarget` = 300 req/min per task, plus `ECSServiceAverageCPUUtilization` = 60% as a backstop | Request count is the signal that matters for an auth service. CPU catches GC storms and LDAP-timeout thread starvation. |
| Scheduled scaling | Min 6 tasks at 06:30 MT on school days, back to 3 at 09:30 MT | Pre-warm for the 7 AM surge. Target tracking reacts too slowly for a predictable spike. |
| Deployment | Rolling, `minimumHealthyPercent=100`, `maximumPercent=200`, circuit breaker with rollback | Never below full capacity during deploys. Circuit breaker reverts a revision that cannot pass health checks. |
| Health check (container) | `/health` (ASP.NET Core health checks: DB connectivity + signing key loaded) | Distinct from the ALB check so ECS restarts a task whose connection pool has died. |
| Logging | `awslogs` to `/ecs/identity-server`, JSON via Serilog console sink | Feeds the Insights queries in OBSERVABILITY.md. |
| Sidecar | ADOT collector (`public.ecr.aws/aws-observability/aws-otel-collector`, 256 CPU units / 512 MB) | OTLP in, X-Ray and CloudWatch out. Details in OBSERVABILITY.md. |
| Ulimits / stop timeout | `nofile` 65536; `stopTimeout` 30s | Drains in-flight token requests on task replacement. |

**Application Load Balancer**

- Internet-facing, in public subnets, HTTPS :443 only with an ACM certificate for the existing hostname. HTTP :80 redirects to 443.
- Target group: IP targets, port 8080, health check `GET /health`, interval 15s, timeout 5s, healthy threshold 2, unhealthy threshold 3. Deregistration delay 30s.
- AWS WAF with the Core Rule Set and a rate-based rule at 2,000 req / 5 min per IP. Auth endpoints are a credential-stuffing target.
- Access logs to S3 with 90-day lifecycle.

**Container image**

- Base: `mcr.microsoft.com/dotnet/aspnet:6.0` (last published patch), multi-stage build from `sdk:6.0`. Runs as the `app` user (uid 1654). Image scanned on push by Amazon Inspector via ECR enhanced scanning.
- This base image no longer receives security patches. See risk R4.

**ASP.NET Data Protection**

- Key ring moved to SSM Parameter Store via `Amazon.AspNetCore.DataProtection.SSM`, encrypted with a customer-managed KMS key. Existing keys are imported before cutover so Azure-issued cookies stay valid on AWS. This is the detail that most often breaks an IdentityServer migration.

### 3.2 RDS for SQL Server

| Setting | Value | Reasoning |
|---|---|---|
| Engine | SQL Server 2019 Standard Edition (15.00), database compatibility level 150 | Matches Azure SQL's declared compatibility. Standard Edition is required for Multi-AZ and is sufficient (no Enterprise features in use: assumption). |
| Instance | `db.r6i.large` (2 vCPU / 16 GB) | Small but latency-sensitive workload. Memory-optimized keeps persisted grants in buffer pool. Right-size after 30 days of Performance Insights. |
| Storage | 100 GB gp3, 3,000 IOPS baseline, autoscaling to 500 GB | Overprovisioned on purpose. Storage is cheap; a full disk on the auth database is an outage. |
| Availability | Multi-AZ (synchronous mirror / Always On AG) | Automatic failover in ~60-120s. Required for the availability SLO. |
| Backups | Automated backups, 14-day retention, PITR enabled. Snapshot immediately before cutover, retained 90 days. | |
| Encryption | KMS customer-managed key at rest; `rds.force_ssl=1` in the parameter group so all connections are TLS. | |
| Network | Isolated subnets, no route to NAT or IGW. Security group allows 1433 only from the ECS task SG, the DMS replication instance SG, and the VPN CIDR (temporary, for Azure App Service during cutover). | |
| Monitoring | Performance Insights (7-day free tier), Enhanced Monitoring at 15s granularity. | See OBSERVABILITY.md for alarms. |
| Auth | SQL authentication with the master credential in Secrets Manager. Application uses a dedicated least-privilege login (`identity_app`: db_datareader, db_datawriter, EXECUTE on the schema). | Windows auth would require the domain join to AWS Managed AD, which is deliberately out of scope. |

Deltas from Azure SQL the team should know: no automatic tuning, no built-in geo-replication, maintenance windows are ours to schedule, `tempdb` sizing follows instance class.

### 3.3 Secrets Manager (migrating from Key Vault)

Naming convention: `/identity-server/prod/<secret-name>`, tagged `service=identity-server`, `env=prod`.

| Key Vault item | Secrets Manager target | Notes |
|---|---|---|
| SQL connection string | `/identity-server/prod/db-connection` | Stored as JSON (`host`, `port`, `username`, `password`, `dbname`). RDS-managed rotation on a 30-day schedule via the `SecretsManagerRDSSQLServerRotationSingleUser` Lambda. Connection string assembled at startup. |
| Signing certificate(s) | `/identity-server/prod/signing-cert-<thumbprint>` | PFX exported from Key Vault (`az keyvault secret download`), stored base64 with the passphrase as a second JSON field. **Same certificate on both sides through cutover.** |
| Third-party API keys | `/identity-server/prod/api-key-<provider>` | One secret per key so rotation and access can be scoped individually. |
| Data Protection keys | SSM Parameter Store `/identity-server/prod/dataprotection/*` | Not Secrets Manager: the SSM provider manages the key ring natively. |

Migration is a one-time script (`scripts/migrate-secrets.sh`): `az keyvault secret show` in, `aws secretsmanager create-secret` out, and a manifest of names plus SHA-256 hashes from both sides for a reviewer to diff. Values never touch stdout or disk. The task definition references secrets by `secrets[].valueFrom` ARN, never as plain `environment` entries, so they do not appear in `describe-task-definition`.

All secrets use a dedicated KMS CMK (`alias/identity-server-prod`) whose key policy is limited to the task execution role, the rotation Lambda role, and the platform admin role.

### 3.4 VPC and networking

Dedicated VPC `10.40.0.0/16` in `us-east-1`, three AZs:

| Tier | Subnets | Contents | Egress |
|---|---|---|---|
| Public | `10.40.0.0/24` x3 | ALB, NAT gateways | Internet gateway |
| Private | `10.40.10.0/24` x3 | ECS tasks, DMS replication instance | NAT gateway (third-party callbacks only; AWS APIs use endpoints) |
| Isolated | `10.40.20.0/24` x3 | RDS | None |

- Interface endpoints: ECR API, ECR DKR, Secrets Manager, SSM, CloudWatch Logs, X-Ray, KMS. Gateway endpoint: S3. Control-plane traffic stays off the NAT and the internet.
- **Site-to-site VPN**, AWS Virtual Private Gateway to the Azure VPN Gateway in the Identity Server's VNet, two tunnels, BGP. Three flows: ECS tasks to Azure AD DS on 636/LDAPS, DMS to Azure SQL on 1433, and temporarily Azure App Service to RDS on 1433. The 1.25 Gbps ceiling is orders of magnitude above need.
- Security groups are the enforcement layer: ALB SG (443 from `0.0.0.0/0`), task SG (8080 from ALB SG; egress 636 to Azure AD DS, 1433 to RDS SG, 443 to endpoints), RDS SG (1433 from task SG, DMS SG, and the Azure VNet CIDR until Definition of Done item 6), DMS SG (1433 out to Azure SQL and RDS).
- Default NACLs only. Security groups are stateful and sufficient; NACLs add debugging cost without adding control here.

### 3.5 IAM (least privilege)

| Role | Trusted by | Permissions |
|---|---|---|
| `identity-server-task-execution` | `ecs-tasks.amazonaws.com` | `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` on the one repository; `logs:CreateLogStream`, `logs:PutLogEvents` on `/ecs/identity-server:*`; `secretsmanager:GetSecretValue` on `arn:...:secret:/identity-server/prod/*`; `kms:Decrypt` on the CMK. |
| `identity-server-task` | `ecs-tasks.amazonaws.com` | `ssm:GetParametersByPath`, `ssm:PutParameter` on `/identity-server/prod/dataprotection/*`; `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey` on the CMK; `xray:PutTraceSegments`, `xray:PutTelemetryRecords`, `cloudwatch:PutMetricData` (used by the ADOT sidecar, condition `cloudwatch:namespace` = `IdentityServer`). Nothing else. The application never touches Secrets Manager directly; ECS injects secrets at launch. |
| `identity-server-deploy` | GitHub OIDC provider, condition `token.actions.githubusercontent.com:sub` = `repo:strongmind/identity-server:ref:refs/heads/main` | `ecs:RegisterTaskDefinition`, `ecs:UpdateService`, `ecs:DescribeServices`, `iam:PassRole` on the two task roles only, ECR push on the one repository. |
| `dms-vpc-role`, `dms-cloudwatch-logs-role` | `dms.amazonaws.com` | AWS managed policies; deleted at Definition of Done. |
| `identity-server-rotation-lambda` | `lambda.amazonaws.com` | Secrets Manager rotation on the DB secret only, ENI management in the private subnets. |

All roles carry a permission boundary denying `iam:*`, `organizations:*`, and actions outside `us-east-1`. No `Resource: "*"` except where the API has no resource-level permissions (`ecr:GetAuthorizationToken`, `xray:Put*`).

## 4. Traffic Cutover Strategy

The public hostname (`identity.strongmind.com`, assumed) does not change. Callers, including PowerSchool, are never asked to reconfigure anything.

**Sequence**

| Step | When | Action | Verification |
|---|---|---|---|
| 0 | T-14 days | Lower the Route 53 TTL on `identity.strongmind.com` from its current value to 60s. | `dig` from several resolvers shows the new TTL propagated. |
| 1 | T-7 days | Deploy ECS service, pointed at RDS (still being synced by DMS, read path only for the health check). Validate against the ALB's own DNS name with the full integration test suite and a synthetic login flow. Confirm `/.well-known/openid-configuration` and `jwks` return byte-identical documents to Azure. | Synthetic canary passing for 48h. Same `kid` in both JWKS responses. |
| 2 | T-0, 02:00-03:00 MT weekday | **Database cutover** (Section 5). Azure App Service repointed at RDS. From here both compute paths share one database. | DMS validation clean, App Service healthy on RDS, synthetic login succeeds through Azure. |
| 3 | T-0 + 1h | Route 53 weighted records: Azure App Service CNAME weight 95, ALB alias weight 5. | Error rate and p95 latency on the ALB target group within SLO for 30 minutes. |
| 4 | T-0 + 2h | 75 / 25. | Same gates. First look at Azure AD DS latency over the VPN in X-Ray. |
| 5 | Next day, after 09:00 MT | 50 / 50 through one full school-start peak. | SLOs held through the 7-9 AM window at 50% of peak load on AWS. |
| 6 | Day 3 | 0 / 100. Azure record kept at weight 0 (not deleted) for instant rollback. | SLOs held through a full peak at 100%. |
| 7 | Day 10 | Azure App Service stopped (not deleted). Azure record removed. TTL restored to 300s. | ALB logs show zero requests to any Azure-specific path or header for 7 days. |

Weighted DNS rather than ALB blue/green because the "blue" side is in another cloud. Route 53 health checks on both records pull a failing side automatically regardless of weight.

**Rollback triggers** (any one, called by the on-call engineer during steps 3-6, using the alarms in OBSERVABILITY.md):

- 5xx rate on the ALB target group > 1% over 5 minutes.
- p95 latency on `/connect/token` > 500 ms over 5 minutes (baseline on Azure is measured in step 1; assumed ~150 ms).
- Any downstream caller reports token validation failures.
- Azure AD DS lookup failures > 0.5% or p95 > 200 ms.

**Rollback procedure**

- Steps 3-6: set the ALB record weight to 0. Effective within the 60s TTL, no data concerns since both sides share RDS. Two minutes, rehearsed once during step 3 on purpose.
- Step 2 (database): see Section 5. The only non-trivial rollback, which is why it has its own window.
- After step 7: restart the App Service and re-add the record, about 15 minutes. Reverse replication (Section 5) keeps Azure SQL current until Definition of Done item 6.

## 5. Database Migration Plan

**Tooling: AWS DMS, full load then ongoing replication (CDC).** Source is Azure SQL over the VPN using MS-CDC (supported since 2022; assumes the tier permits it). Target is RDS SQL Server. Replication instance `dms.r6i.large`, Multi-AZ, private subnets.

Alternative: BACPAC for the initial load, then DMS CDC-only. Rejected because a BACPAC of a live database is not transactionally consistent, and at under 20 GB (assumed) DMS full load is fast enough.

**Pre-migration (T-21 to T-7)**

1. Schema created on RDS by the app's EF Core migrations, not DMS, so indexes, constraints, and identity columns are exactly what the app expects. DMS: `TargetTablePrepMode=DO_NOTHING`.
2. Full load + CDC task started. Full load takes minutes; CDC then keeps RDS within seconds of Azure.
3. Dry run: ECS service pointed at a snapshot copy of RDS, integration suite run against it, including issuance, refresh, revocation, and the PowerSchool grant flow.
4. **Reverse path prepared**: a second DMS task, RDS to Azure SQL, CDC-only, created but not started. This is the database rollback.

**Data validation**

- DMS built-in validation enabled on the CDC task (`EnableValidation=true`), which compares row-level data continuously and reports mismatches to a CloudWatch metric.
- Custom checks before cutover: row counts and `CHECKSUM_AGG` over the primary key columns on every table, run on both sides and diffed. Spot-check the 20 most recently issued persisted grants by hand.
- Identity column seeds reseeded on RDS (`DBCC CHECKIDENT`) after full load; DMS does not preserve them.

**Cutover window (T-0, 02:00 MT, target 5 minutes of degraded token issuance, zero impact on token validation)**

1. Confirm DMS CDC latency < 5s and validation shows zero pending mismatches.
2. Set Azure SQL read-only (`ALTER DATABASE ... SET READ_ONLY`). New logins and refreshes return 503 for the duration; existing tokens still validate everywhere because validation is offline against cached JWKS. This is the "minimal downtime": at 02:00 MT the rate is a small fraction of the 400 req/min baseline.
3. Wait for CDC latency to hit 0 (all remaining changes applied). Run the row count and checksum diff. Expected time: under 60 seconds.
4. Stop the forward DMS task. Take a final RDS snapshot.
5. Update the Key Vault connection string secret to point at RDS (over the VPN). Restart the App Service. Health check passes.
6. Start the reverse DMS task (RDS to Azure SQL). Set Azure SQL back to read-write so the reverse task can apply changes. Azure SQL is now a warm standby.
7. Synthetic login through the Azure hostname succeeds. Window closed.

**Database rollback (only relevant between step 2 above and Definition of Done)**

- Stop the reverse DMS task, confirm it drained, repoint the App Service connection string at Azure SQL, restart. Five minutes. Everything written to RDS has been replicated back, so nothing is lost.
- After Definition of Done, rollback is a restore-from-backup and is treated as a new incident.

## 6. Risk Register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Tokens issued on one side fail validation on the other because signing keys differ or `kid` values do not match | Low | Critical: every product breaks | Same PFX migrated byte-for-byte. Step 1 verifies JWKS equality before any traffic shifts. A canary validates an Azure-issued token against the AWS instance and vice versa hourly during the weighted phase. |
| R2 | Azure AD DS lookups over the VPN add latency or fail intermittently, degrading login p95 | Medium | High: SLO breach during school start | Measure LDAP round-trip at step 1. Application-level LDAP connection pooling and a 5s timeout with circuit breaker (Polly). Two VPN tunnels with BGP failover. Follow-up ADR to remove the cross-cloud dependency within one quarter. |
| R3 | DMS CDC drops or mangles data: identity columns, `datetime2` precision, computed columns, or CDC lag during peak | Medium | High: users lose sessions or, worse, grants are duplicated | Schema owned by EF Core, not DMS. Validation enabled and diffed before cutover. Cutover at 02:00 MT when change volume is near zero. Full dry run on a snapshot two weeks out. |
| R4 | .NET 6 runtime image is end-of-life and receives no security patches | High (certain) | Medium: known CVEs in the runtime | Pin the final patched image, enable ECR enhanced scanning, accept the finding with an expiry. .NET 8 LTS upgrade is the first post-migration sprint, now trivial because the build is containerized. |
| R5 | A downstream caller (most likely PowerSchool) has the `*.azurewebsites.net` hostname hardcoded rather than the custom domain | Medium | High: that integration silently breaks at step 7 | Audit App Service access logs for Host headers before step 0. Keep the App Service at weight 0 for 10 days and alert on any request. If found, serve that hostname from the ALB or coordinate with the vendor. |
| R6 | Client-side DNS caching ignores the 60s TTL (Java runtimes, some corporate resolvers) and keeps sending to Azure after step 6 | Medium | Low: Azure still works until step 7 | 10-day dwell at weight 0 before shutdown. Azure record removal, not App Service shutdown, is the true cutoff. |
| R7 | RDS Multi-AZ failover during school start | Low | Medium: 60-120s of DB unavailability, connection pool churn | Maintenance window set to Sunday 03:00 MT. EF Core retry-on-failure enabled. Alarm on `FailoverEvent` routed to page. |

## 7. Definition of Done

Complete when all of the following are observable, not when the last step runs:

1. 100% of traffic has been served by ECS for 7 consecutive days including at least 5 school-day morning peaks, with both Identity Server SLOs (OBSERVABILITY.md) met for the full period.
2. Zero requests to the Azure hostname or App Service for 7 consecutive days per Azure access logs.
3. All CloudWatch alarms in OBSERVABILITY.md are deployed, tested with a synthetic failure, and routed to Jira Operations. The on-call engineer has run the rollback runbook once in a game day.
4. Azure App Service stopped. Key Vault secrets disabled (not deleted) with a 30-day deletion date.
5. Azure SQL final backup exported to S3 (BACPAC, encrypted) and retained for 1 year.
6. Reverse DMS task stopped and deleted. DMS replication instance deleted. The temporary RDS security group rule for the Azure VNet CIDR removed. Azure SQL database deleted after the 30-day soft-delete window.
7. The site-to-site VPN remains only for the Azure AD DS dependency, and the follow-up ADR for that dependency is accepted with an owner and a target quarter.
8. Runbook, task definition, RDS parameter group, and all IAM policies are in Terraform under `infra/identity-server/` with a green plan. Nothing was created by hand in the console that is not in code.
9. Monthly cost of the AWS footprint is recorded and compared against the Azure baseline, with the difference explained.

## 8. Consequences

**Easier:** one cloud, one on-call surface, one observability pipeline, reproducible builds, and a straightforward path to the .NET 8 upgrade.

**Harder:** RDS SQL Server is more expensive per vCPU than Azure SQL serverless tiers and needs hands-on maintenance windows. The team takes ownership of SQL Server patching and tuning that Azure SQL abstracted.

**Revisit:** Azure AD DS dependency (next quarter), .NET 8 upgrade (next sprint), Aurora PostgreSQL or Cognito evaluation (after 90 days of stable operation on AWS).