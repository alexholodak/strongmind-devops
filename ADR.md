# ADR-001: Move the Identity Server from Azure App Service to AWS ECS Fargate

**Status:** Proposed
**Date:** 2026-09-08
**Author:** Alex Holodak, DevOps Engineer
**Deciders:** Platform Engineering, Security, LMS and Integrations team leads

---

## 1. Context

The Identity Server is a .NET 6 service that handles authentication and issues tokens for every StrongMind product. It's the last critical thing we still run in Azure.

| Component | Today |
|---|---|
| Runtime | .NET 6 on Azure App Service (Linux) |
| Database | Azure SQL Database, SQL Server 2019 compatibility level |
| Secrets | Azure Key Vault: connection strings, JWT signing certificates, API keys |
| Traffic | About 400 req/min normally, peaking around 1,200 req/min from 7 to 9 AM Mountain when school starts |
| Upstream dependency | Azure AD Domain Services, for directory lookups |
| Downstream callers | The Rails LMS, the PowerSchool integration, and the other StrongMind products |

**Why move it now**

- Everything else runs on ECS Fargate. This is the one service where on-call needs a second console, a second alerting path, and a second IAM model. It's also the one service that takes every product down when it fails.
- Observability is split in two. The Azure side isn't wired into the CloudWatch and Jira Operations setup the rest of the platform uses (see OBSERVABILITY.md).
- .NET 6 went out of support in November 2024. We need to upgrade the runtime regardless, and that's much easier once the build is a container. The upgrade target is .NET 10 (LTS, supported to November 2028), not .NET 8. .NET 8 leaves support on November 10, 2026, which lands inside this migration's window.
- One cloud means no cross-cloud egress bill and a simpler Azure enterprise agreement renewal.

**Constraints**

- Token validation can't go down at all. Token issuance can tolerate one short scheduled window of a few minutes, outside school hours.
- We can't assume downstream callers, especially PowerSchool, will redeploy on our schedule. The public hostname and the OIDC discovery document can't change.
- No code changes to the Identity Server during the migration, only configuration. The runtime upgrade is a separate change, later.

**Assumptions**

- The service is Duende IdentityServer or IdentityServer4 on ASP.NET Core with EF Core, and it keeps its operational data (persisted grants, refresh tokens, device codes) and its configuration in Azure SQL.
- Signing certificates live in Key Vault as exportable PFX certificates and are loaded at startup. Tokens are RS256 JWTs, and callers validate them offline using the `/.well-known/openid-configuration/jwks` endpoint.
- ASP.NET Data Protection keys are in Key Vault or Azure Blob today. They encrypt auth cookies and server-side state, and they have to survive the move.
- Directory lookups against Azure AD DS are LDAP or LDAPS, not Graph API, so they need a private network path.
- StrongMind's public DNS is already in Route 53.

## 2. Decision

**Containerize the Identity Server as it is, on .NET 6. Run it on ECS Fargate behind an Application Load Balancer. Move the database to Amazon RDS for SQL Server using AWS DMS with change data capture. Move secrets to AWS Secrets Manager. Cut over database first, then shift compute traffic with Route 53 weighted routing.**

Azure AD Domain Services stays where it is for now. It stays reachable over a site-to-site VPN and gets replaced in a follow-up ADR. The candidates are AWS Managed Microsoft AD, or dropping the LDAP dependency in favor of a synced user store.

### Options considered

| Option | What it would mean | Verdict |
|---|---|---|
| **A. Lift-and-shift to ECS Fargate + RDS SQL Server** | Fewest moving parts. No code changes. Same database engine, so EF Core migrations and stored procedures work as they are. | **Chosen.** Lowest risk for a service that can't afford an auth regression. |
| B. Replace it with Amazon Cognito | Gets rid of the service entirely, but custom claims, the PowerSchool grant types, and the Data Protection state don't map cleanly. Multiple quarters, and every product has to change. | No, not here. Worth evaluating on its own. |
| C. ECS Fargate + Aurora PostgreSQL | Cheaper to run, but needs an EF Core provider swap, T-SQL rewrites, and heterogeneous DMS with schema conversion. That's application risk stacked on top of an infrastructure move. | No. Look again once we're stable on AWS. |
| D. EKS instead of ECS | We have no EKS footprint. A new control plane and a new way of operating, for one service. | No. Consistency with the rest of the platform wins. |

The rule behind all of this: **change one thing at a time.** The cloud provider changes now. The runtime version, the database engine, and the directory service each change later, each with its own ADR.

## 3. Target Architecture

### 3.1 ECS Fargate service

**Task definition** (family `identity-server`, Fargate, `awsvpc`, Linux/X86_64):

| Setting | Value | Why |
|---|---|---|
| CPU / memory | 1 vCPU / 2 GB | .NET 6 with EF Core idles at 250-350 MB and the JIT eats CPU on cold start. This is sized for startup and GC headroom. 20 req/s at peak is nothing. |
| Container port | 8080 | A non-root process can't bind 80. `ASPNETCORE_URLS=http://+:8080`. TLS ends at the ALB. |
| Desired count | 3 (min 3, max 12) | One per AZ, so losing an AZ leaves two. Two tasks can handle 1,200 req/min. |
| Auto scaling | Target tracking on `ALBRequestCountPerTarget` = 300 req/min per task, plus `ECSServiceAverageCPUUtilization` = 60% as a backstop | Request count is the signal that matters for an auth service. CPU catches GC storms and threads stuck waiting on LDAP. |
| Scheduled scaling | Minimum 6 tasks at 06:30 MT on school days, back to 3 at 09:30 MT | Pre-warm for the 7 AM surge. Target tracking is too slow for a spike we can see coming. |
| Deployment | Rolling, `minimumHealthyPercent=100`, `maximumPercent=200`, circuit breaker with rollback on | Never below full capacity during a deploy. The circuit breaker backs out a revision that can't pass health checks. |
| Health check (container) | `/health` (ASP.NET Core health checks: DB connectivity plus signing key loaded) | Separate from the ALB check, so ECS restarts a task whose connection pool has died. |
| Logging | `awslogs` to `/ecs/identity-server`, JSON via the Serilog console sink | Feeds the Insights queries in OBSERVABILITY.md. |
| Sidecar | ADOT collector (`public.ecr.aws/aws-observability/aws-otel-collector`, 256 CPU units / 512 MB) | OTLP in, X-Ray and CloudWatch out. Details in OBSERVABILITY.md. |
| Ulimits / stop timeout | `nofile` 65536; `stopTimeout` 30s | Lets in-flight token requests finish when a task is replaced. |

**Application Load Balancer**

- Internet-facing, in the public subnets, HTTPS on 443 only, with an ACM certificate for the existing hostname. HTTP on 80 redirects to 443.
- Target group: IP targets, port 8080, health check `GET /health` every 15s, 5s timeout, healthy after 2, unhealthy after 3. Deregistration delay 30s.
- AWS WAF with the Core Rule Set and a rate-based rule at 2,000 requests per 5 minutes per IP. Auth endpoints get credential-stuffed.
- Access logs to S3, kept 90 days.

**Container image**

- Base: `mcr.microsoft.com/dotnet/aspnet:6.0` (last published patch), multi-stage build from `sdk:6.0`. The 6.0 images don't ship a non-root user, so the Dockerfile creates one: `app`, uid 1654, which matches the `APP_UID` convention the .NET 8+ images have built in. Nothing changes at upgrade time. Images are scanned on push by Amazon Inspector through ECR enhanced scanning.
- This base image no longer gets security patches. See risk R4.

**ASP.NET Data Protection**

- The key ring moves to SSM Parameter Store via `Amazon.AspNetCore.DataProtection.SSM`, encrypted with a customer-managed KMS key. The existing keys are imported before cutover so cookies issued on Azure still work on AWS. This is the detail that breaks IdentityServer migrations more than anything else.

### 3.2 RDS for SQL Server

| Setting | Value | Why |
|---|---|---|
| Engine | SQL Server 2019 Standard Edition (15.00), compatibility level 150 | Matches what Azure SQL declares. Standard Edition is what Multi-AZ needs, and it's enough (assuming no Enterprise features are in use). |
| Instance | `db.r6i.large` (2 vCPU / 16 GB) | Small but latency-sensitive. Memory-optimized keeps the persisted grants in the buffer pool. Right-size after 30 days of Performance Insights. |
| Storage | 100 GB gp3, 3,000 IOPS baseline, autoscaling to 500 GB | Overprovisioned on purpose. Storage is cheap. A full disk on the auth database is an outage. |
| Availability | Multi-AZ (synchronous mirror / Always On AG) | Automatic failover in about 60-120s. The availability SLO needs it. |
| Backups | Automated backups, 14-day retention, PITR on. A snapshot right before cutover, kept 90 days. | |
| Encryption | KMS customer-managed key at rest. `rds.force_ssl=1` in the parameter group so every connection is TLS. | |
| Network | Isolated subnets with no route to a NAT or internet gateway. Security group allows 1433 only from the ECS task SG, the DMS replication instance SG, and the VPN CIDR (temporary, for the Azure App Service during cutover). | |
| Monitoring | Performance Insights (7-day free tier), Enhanced Monitoring at 15s. | Alarms are in OBSERVABILITY.md. |
| Auth | SQL authentication, master credential in Secrets Manager. The app uses its own limited login (`identity_app`: db_datareader, db_datawriter, EXECUTE on the schema). | Windows auth would need a domain join to AWS Managed AD, which is out of scope on purpose. |

Things that are different from Azure SQL and the team should know: no automatic tuning, no built-in geo-replication, we schedule our own maintenance windows, and `tempdb` sizing follows the instance class.

### 3.3 Secrets Manager (moving from Key Vault)

Naming: `/identity-server/prod/<secret-name>`, tagged `service=identity-server`, `env=prod`.

| Key Vault item | Secrets Manager target | Notes |
|---|---|---|
| SQL connection string | `/identity-server/prod/db-connection` | Stored as JSON (`host`, `port`, `username`, `password`, `dbname`). RDS-managed rotation every 30 days via the `SecretsManagerRDSSQLServerRotationSingleUser` Lambda. The connection string gets assembled at startup. |
| Signing certificate(s) | `/identity-server/prod/signing-cert-<thumbprint>` | PFX exported from Key Vault (`az keyvault secret download`), stored base64 with the passphrase as a second JSON field. **The same certificate on both sides all the way through cutover.** |
| Third-party API keys | `/identity-server/prod/api-key-<provider>` | One secret per key, so each can be rotated and scoped on its own. |
| Data Protection keys | SSM Parameter Store `/identity-server/prod/dataprotection/*` | Not Secrets Manager. The SSM provider manages the key ring itself. |

The move is a one-time script (`scripts/migrate-secrets.sh`): `az keyvault secret show` in, `aws secretsmanager create-secret` out, and a manifest of names plus SHA-256 hashes from both sides for someone to diff. Values never hit stdout or disk. The task definition references secrets by `secrets[].valueFrom` ARN, never as plain `environment` entries, so they don't show up in `describe-task-definition`.

Everything is encrypted with one dedicated KMS CMK (`alias/identity-server-prod`). Its key policy allows only the task execution role, the rotation Lambda role, and the platform admin role.

### 3.4 VPC and networking

A dedicated VPC, `10.40.0.0/16`, in `us-east-1`, across three AZs:

| Tier | Subnets | What's in it | Egress |
|---|---|---|---|
| Public | `10.40.0.0/24` x3 | ALB, NAT gateways | Internet gateway |
| Private | `10.40.10.0/24` x3 | ECS tasks, DMS replication instance | NAT gateway (only for third-party callbacks; AWS APIs go through endpoints) |
| Isolated | `10.40.20.0/24` x3 | RDS | None |

- Interface endpoints for ECR API, ECR DKR, Secrets Manager, SSM, CloudWatch Logs, X-Ray, and KMS. A gateway endpoint for S3. Control-plane traffic never touches the NAT or the internet.
- **Site-to-site VPN** from an AWS Virtual Private Gateway to the Azure VPN Gateway in the Identity Server's VNet, two tunnels, BGP. It carries three flows: ECS tasks to Azure AD DS on 636/LDAPS, DMS to Azure SQL on 1433, and temporarily the Azure App Service to RDS on 1433. The 1.25 Gbps ceiling is far more than we need.
- Security groups do the enforcement: ALB SG (443 from anywhere), task SG (8080 from the ALB SG; egress 636 to Azure AD DS, 1433 to the RDS SG, 443 to the endpoints), RDS SG (1433 from the task SG, the DMS SG, and the Azure VNet CIDR until Definition of Done item 6), DMS SG (1433 out to Azure SQL and RDS).
- Default NACLs only. Security groups are stateful and enough. NACLs would make debugging harder without adding any control.

### 3.5 IAM (least privilege)

| Role | Trusted by | What it can do |
|---|---|---|
| `identity-server-task-execution` | `ecs-tasks.amazonaws.com` | `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` on the one repository; `logs:CreateLogStream`, `logs:PutLogEvents` on `/ecs/identity-server:*`; `secretsmanager:GetSecretValue` on `arn:...:secret:/identity-server/prod/*`; `kms:Decrypt` on the CMK. |
| `identity-server-task` | `ecs-tasks.amazonaws.com` | `ssm:GetParametersByPath`, `ssm:PutParameter` on `/identity-server/prod/dataprotection/*`; `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey` on the CMK; `xray:PutTraceSegments`, `xray:PutTelemetryRecords`, `cloudwatch:PutMetricData` (used by the ADOT sidecar, with the condition `cloudwatch:namespace` = `IdentityServer`). Nothing else. The app never calls Secrets Manager itself; ECS injects secrets at launch. |
| `identity-server-deploy` | The GitHub OIDC provider, with the condition `token.actions.githubusercontent.com:sub` = `repo:strongmind/identity-server:ref:refs/heads/main` | `ecs:RegisterTaskDefinition`, `ecs:UpdateService`, `ecs:DescribeServices`, `iam:PassRole` on the two task roles only, and ECR push on the one repository. |
| `dms-vpc-role`, `dms-cloudwatch-logs-role` | `dms.amazonaws.com` | AWS managed policies. Deleted at Definition of Done. |
| `identity-server-rotation-lambda` | `lambda.amazonaws.com` | Secrets Manager rotation on the DB secret only, plus ENI management in the private subnets. |

Every role has a permission boundary that denies `iam:*`, `organizations:*`, and anything outside `us-east-1`. No `Resource: "*"` anywhere except where the API has no resource-level permissions (`ecr:GetAuthorizationToken`, `xray:Put*`).

## 4. Traffic Cutover

The public hostname (`identity.strongmind.com`, assumed) doesn't change. Nobody who calls us, including PowerSchool, has to reconfigure anything.

**Sequence**

| Step | When | What happens | How we know it worked |
|---|---|---|---|
| 0 | T-14 days | Drop the Route 53 TTL on `identity.strongmind.com` to 60s. | `dig` from several resolvers shows the new TTL. |
| 1 | T-7 days | Deploy the ECS service, pointed at RDS (still being synced by DMS; only the health check reads from it). Run the full integration suite and a synthetic login flow against the ALB's own DNS name. Confirm `/.well-known/openid-configuration` and `jwks` are byte-for-byte identical to Azure. | Synthetic canary green for 48 hours. Same `kid` in both JWKS responses. |
| 2 | T-0, 02:00-03:00 MT on a weekday | **Database cutover** (Section 5). The Azure App Service is repointed at RDS. From here on, both compute paths share one database. | DMS validation clean, App Service healthy on RDS, synthetic login works through Azure. |
| 3 | T-0 + 1h | Route 53 weighted records: Azure App Service CNAME at weight 95, ALB alias at weight 5. | Error rate and p95 latency on the ALB target group inside SLO for 30 minutes. |
| 4 | T-0 + 2h | 75 / 25. | Same checks. First look at Azure AD DS latency over the VPN in X-Ray. |
| 5 | Next day, after 09:00 MT | 50 / 50, through one full school-start peak. | SLOs held through the 7-9 AM window with half the peak on AWS. |
| 6 | Day 3 | 0 / 100. The Azure record stays at weight 0, not deleted, for instant rollback. | SLOs held through a full peak at 100%. |
| 7 | Day 10 | Azure App Service stopped, not deleted. Azure record removed. TTL back to 300s. | ALB logs show zero requests to any Azure-specific path or header for 7 days. |

Weighted DNS instead of ALB blue/green because the "blue" side is in a different cloud. Route 53 health checks on both records pull a failing side out automatically, whatever its weight.

**Rollback triggers.** Any one of these, called by the on-call engineer during steps 3-6, using the alarms in OBSERVABILITY.md:

- 5xx rate on the ALB target group above 1% over 5 minutes.
- p95 latency on `/connect/token` above 500 ms over 5 minutes. (The Azure baseline gets measured in step 1; we're assuming around 150 ms.)
- Any downstream caller reports token validation failures.
- Azure AD DS lookup failures above 0.5%, or p95 above 200 ms.

**How to roll back**

- Steps 3-6: set the ALB record's weight to 0. Takes effect within the 60s TTL. No data concerns, since both sides share RDS. Two minutes. We rehearse it once during step 3, on purpose.
- Step 2 (database): see Section 5. This is the only rollback that isn't trivial, which is why it gets its own window.
- After step 7: restart the App Service and add the record back. About 15 minutes. Reverse replication (Section 5) keeps Azure SQL current until Definition of Done item 6.

## 5. Database Migration

**Tooling: AWS DMS, full load then ongoing replication with CDC.** The source is Azure SQL over the VPN using MS-CDC (supported since 2022, assuming the tier allows it). The target is RDS SQL Server. Replication instance `dms.r6i.large`, Multi-AZ, in the private subnets.

The alternative was a BACPAC for the initial load and DMS for CDC only. Rejected: a BACPAC of a live database isn't transactionally consistent, and at under 20 GB (assumed) a DMS full load is fast enough anyway.

**Before the migration (T-21 to T-7)**

1. The schema on RDS gets created by the app's own EF Core migrations, not by DMS, so indexes, constraints, and identity columns are exactly what the app expects. DMS runs with `TargetTablePrepMode=DO_NOTHING`.
2. Start the full load plus CDC task. Full load takes minutes. After that, CDC keeps RDS within seconds of Azure.
3. Dry run: point the ECS service at a snapshot copy of RDS and run the integration suite against it, including issuance, refresh, revocation, and the PowerSchool grant flow.
4. **Prepare the way back**: a second DMS task, RDS to Azure SQL, CDC only, created but not started. That's the database rollback.

**Validating the data**

- DMS's built-in validation is on for the CDC task (`EnableValidation=true`). It compares rows continuously and reports mismatches to a CloudWatch metric.
- Before cutover, our own checks: row counts and `CHECKSUM_AGG` over the primary key columns on every table, run on both sides and diffed. Spot-check the 20 most recent persisted grants by hand.
- Reseed the identity columns on RDS (`DBCC CHECKIDENT`) after the full load. DMS doesn't preserve them.

**The cutover window (T-0, 02:00 MT; aiming for 5 minutes of degraded token issuance and zero impact on validation)**

1. Confirm DMS CDC latency is under 5s and validation shows no pending mismatches.
2. Set Azure SQL read-only (`ALTER DATABASE ... SET READ_ONLY`). New logins and refreshes return 503 until we're done. Existing tokens keep validating everywhere, because validation is offline against cached JWKS. This is the "minimal downtime" part. At 02:00 MT the request rate is a small fraction of the 400 req/min baseline.
3. Wait for CDC latency to hit 0, meaning every remaining change has landed. Run the row count and checksum diff. Should take under 60 seconds.
4. Stop the forward DMS task. Take a final RDS snapshot.
5. Update the Key Vault connection string to point at RDS (over the VPN). Restart the App Service. Health check passes.
6. Start the reverse DMS task (RDS to Azure SQL). Set Azure SQL back to read-write so the reverse task can write to it. Azure SQL is now a warm standby.
7. A synthetic login through the Azure hostname succeeds. Window closed.

**Rolling back the database** (only relevant between step 2 above and Definition of Done)

- Stop the reverse DMS task and confirm it drained. Repoint the App Service connection string at Azure SQL. Restart. Five minutes. Everything written to RDS has already been replicated back, so nothing is lost.
- After Definition of Done, a rollback means restoring from backup, and it gets treated as a new incident.

## 6. Risks

| # | Risk | How likely | How bad | What we do about it |
|---|---|---|---|---|
| R1 | Tokens issued on one side fail validation on the other, because the signing keys differ or the `kid` values don't match | Low | Critical. Every product breaks. | The same PFX is moved byte-for-byte. Step 1 confirms the JWKS documents are identical before any traffic moves. During the weighted phase, a canary validates an Azure-issued token against AWS and vice versa every hour. |
| R2 | Azure AD DS lookups over the VPN add latency or fail now and then, dragging login p95 down | Medium | High. SLO breach during school start. | Measure the LDAP round trip at step 1. LDAP connection pooling in the app, a 5s timeout, and a circuit breaker (Polly). Two VPN tunnels with BGP failover. A follow-up ADR to remove the cross-cloud dependency within a quarter. |
| R3 | DMS CDC drops or mangles data: identity columns, `datetime2` precision, computed columns, or CDC lag at peak | Medium | High. Users lose sessions or, worse, grants get duplicated. | EF Core owns the schema, not DMS. Validation is on and diffed before cutover. Cutover happens at 02:00 MT when almost nothing is changing. A full dry run on a snapshot two weeks out. |
| R4 | The .NET 6 runtime image is end-of-life and gets no security patches | High (it's certain) | Medium. Known CVEs in the runtime. | Pin the final patched image, turn on ECR enhanced scanning, and accept the finding with an expiry date. The .NET 10 LTS upgrade is the first sprint after the migration, and it's now a base-image change plus a test cycle because the build is a container. Not .NET 8: its support ends November 10, 2026, right about when that sprint would land. |
| R5 | A downstream caller (most likely PowerSchool) has the `*.azurewebsites.net` hostname hardcoded instead of the custom domain | Medium | High. That integration quietly breaks at step 7. | Audit the App Service access logs for Host headers before step 0. Keep the App Service at weight 0 for 10 days and alert on any request. If one shows up, serve that hostname from the ALB or work it out with the vendor. |
| R6 | Client-side DNS caches ignore the 60s TTL (Java runtimes, some corporate resolvers) and keep sending to Azure after step 6 | Medium | Low. Azure still works until step 7. | 10 days at weight 0 before shutdown. Removing the Azure record, not stopping the App Service, is the real cutoff. |
| R7 | An RDS Multi-AZ failover during school start | Low | Medium. 60-120s of database unavailability and connection pool churn. | Maintenance window set to Sunday 03:00 MT. EF Core retry-on-failure turned on. An alarm on `FailoverEvent` that pages. |

## 7. Definition of Done

We're done when all of these are true and observable, not when the last step runs:

1. ECS has served 100% of traffic for 7 days in a row, including at least 5 school-day morning peaks, with both Identity Server SLOs (OBSERVABILITY.md) met the whole time.
2. Azure access logs show zero requests to the Azure hostname or App Service for 7 days in a row.
3. Every CloudWatch alarm in OBSERVABILITY.md is deployed, has been tested with a synthetic failure, and routes to Jira Operations. The on-call engineer has run the rollback runbook once in a game day.
4. The Azure App Service is stopped. Key Vault secrets are disabled, not deleted, with a deletion date 30 days out.
5. A final Azure SQL backup is exported to S3 (encrypted BACPAC) and kept for a year.
6. The reverse DMS task is stopped and deleted. The DMS replication instance is deleted. The temporary RDS security group rule for the Azure VNet CIDR is removed. The Azure SQL database is deleted after its 30-day soft-delete window.
7. The site-to-site VPN exists only for the Azure AD DS dependency, and the follow-up ADR for that dependency is accepted, with an owner and a target quarter.
8. The runbook, task definition, RDS parameter group, and every IAM policy are in Terraform under `infra/identity-server/` with a green plan. Nothing was clicked into existence in the console that isn't in code.
9. The monthly cost of the AWS footprint is recorded and compared against the Azure baseline, with the difference explained.

## 8. Consequences

**Easier:** one cloud, one on-call surface, one observability pipeline, reproducible builds, and a clear path to .NET 10.

**Harder:** RDS SQL Server costs more per vCPU than Azure SQL's serverless tiers and needs real maintenance windows. The team owns SQL Server patching and tuning that Azure SQL used to handle for us.

**Come back to:** the Azure AD DS dependency (next quarter), the .NET 10 upgrade (next sprint), and an Aurora PostgreSQL or Cognito evaluation (after 90 days of running stably on AWS).
