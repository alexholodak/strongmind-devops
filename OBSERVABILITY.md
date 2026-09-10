# Observability Plan: Identity Server and Rails Application

**Scope:** the Identity Server after migration to ECS Fargate (see ADR.md) and the Rails 8 application deployed by `rails-deploy.yml`.
**Goal:** replace "I can't tell if something is wrong until a customer calls" with signals that fire first and say *where* to look, not just *that* something broke.

**Principles**

- Alert on symptoms customers feel (errors, latency, failed logins), not causes (CPU).
- Every page links a runbook. No runbook, no P1.
- One pipeline for both services: OpenTelemetry in the app, ADOT sidecar, CloudWatch and X-Ray behind it, Jira Operations routing.

---

## 1. SLOs and SLIs (Identity Server)

The Identity Server is the dependency of every StrongMind product, so its SLOs are the floor for everyone else's.

| SLO | Target | SLI (how it is measured) | Window |
|---|---|---|---|
| **Availability** | 99.9% of requests succeed | `1 - (HTTPCode_Target_5XX_Count / RequestCount)` on the ALB target group. 4xx are excluded: a bad password is not an outage. | Rolling 30 days (error budget: ~43 min/month) |
| **Token latency** | 95% of `POST /connect/token` requests complete in under 300 ms; 99% under 800 ms | `TargetResponseTime` p95 / p99 from the ALB, filtered to the token endpoint via a listener rule with its own target group metrics, or from the OTel `http.server.duration` histogram by route | Rolling 30 days |
| **Login success** | 99.5% of synthetic login flows succeed | CloudWatch Synthetics canary (`identity-login-canary`): full OIDC authorization-code flow with a test account every 5 minutes from two regions. `SuccessPercent` metric. | Rolling 7 days |

**What happens on breach**

- Alerts fire on **burn rate**, not the raw SLO, so a breach is caught with budget still left:
  - Fast burn: 14.4x over 1 hour (exhausts the month in ~2 days) pages **P1**.
  - Slow burn: 6x over 6 hours pages **P2**; 1x over 3 days opens a **P3** ticket.
- At 100% budget consumed: feature deploys to the Identity Server freeze, only reliability fixes ship, incident review within 5 business days. Agreed with product in advance, not negotiated mid-incident.
- SLO reports reviewed monthly with engineering leads. Targets change only through a written revision.

---

## 2. Metrics and Alarms

All alarms use 1-minute periods unless noted, carry `service` and `severity` tags, and route through the SNS topics in Section 5. **Composite alarms** group related conditions so one root cause does not page three times.

### 2.1 ECS task health (both services)

Source: ECS Container Insights and ALB metrics.

| Metric | Alarm threshold | Severity | Triggers |
|---|---|---|---|
| `RunningTaskCount` < `DesiredTaskCount` | for 3 consecutive minutes | P1 | Page. Runbook: check stopped-task reasons (`aws ecs describe-tasks` on `STOPPED`), image pull, secrets access, OOM kill. |
| ALB `UnHealthyHostCount` >= 1 | for 2 minutes | P2 (P1 if >= 50% of targets) | Page. Usually a bad deploy in progress or DB connectivity. |
| ALB `HTTPCode_Target_5XX_Count / RequestCount` > 1% | 5 minutes | P1 | Page. Same signal as the availability SLO fast burn; this is the direct version. |
| ALB `TargetResponseTime` p95 > 500 ms | 5 minutes | P2 | Page during 06:00-20:00 MT, notify otherwise. Runbook points at Section 3. |
| `CPUUtilization` > 75% | 3 of 5 minutes | P3 | Notify. Auto scaling should already be reacting; this alarm is a check that it did. |
| `MemoryUtilization` > 85% | 3 of 5 minutes | P2 | Page. .NET and Ruby both degrade sharply near the limit; an OOM kill follows. |
| ECS deployment circuit breaker rollback (EventBridge `ECS Deployment State Change`, `SERVICE_DEPLOYMENT_FAILED`) | any occurrence | P2 | Page plus Slack `#deploys`. Correlate with the GitHub Actions run. |
| ALB `RejectedConnectionCount` > 0 | 1 minute | P2 | Page. ALB is out of capacity or tasks are not accepting connections. |

### 2.2 RDS (SQL Server for Identity Server; Postgres for Rails)

Source: RDS CloudWatch metrics, Enhanced Monitoring, Performance Insights, RDS event subscriptions.

| Metric | Alarm threshold | Severity | Triggers |
|---|---|---|---|
| RDS event: failover started / completed | any | P2 | Page. Expected to self-heal in 60-120s; the page is so someone watches the reconnect. |
| `FreeStorageSpace` < 15% of allocated | 5 minutes | P1 | Page. Full disk on the auth database is an outage. Storage autoscaling should prevent this; the alarm catches it failing. |
| `CPUUtilization` > 80% | 15 minutes | P3 | Notify. Open Performance Insights, find the top SQL. |
| `DatabaseConnections` > 80% of the application pool max (assumed 400 for Identity Server) | 5 minutes | P2 | Page. Connection leak or task scale-out beyond what the pool math supports. |
| `ReadLatency` or `WriteLatency` > 20 ms | 10 minutes | P3 | Notify. gp3 IOPS ceiling or a checkpoint storm. |
| `DiskQueueDepth` > 10 | 10 minutes | P3 | Notify. Usually paired with the latency alarm above. |
| `FreeableMemory` < 1 GB | 10 minutes | P2 | Page. SQL Server buffer pool pressure; instance is undersized or a query is spilling. |
| `ReplicaLag` (Postgres read replica, if used) > 30 s | 5 minutes | P3 | Notify. |

### 2.3 Application-level signals

Emitted as OTel metrics (via the ADOT sidecar into CloudWatch as EMF) or as metric filters on structured logs.

| Signal | Alarm threshold | Severity | Triggers |
|---|---|---|---|
| `identity.token.errors` (token endpoint responses with `error` other than `invalid_grant`) rate > 2% | 5 minutes | P1 | Page. Signing key, persisted grant store, or client config problem. |
| `identity.ldap.duration` p95 > 200 ms **or** `identity.ldap.errors` > 0.5% | 5 minutes | P2 | Page. Azure AD DS or VPN degradation (ADR risk R2). Runbook: check VPN tunnel status, AD DS health in Azure portal. |
| `identity.signing_cert.days_to_expiry` < 30 | daily check | P3 | Notify. Ticket to rotate. < 7 days escalates to P2. |
| Synthetics `identity-login-canary` `SuccessPercent` < 100% | 2 consecutive runs | P1 | Page. This is the "customer is about to call" alarm. |
| Rails `http.server.duration` p95 > 1 s | 5 minutes | P2 | Page during school hours, notify otherwise. |
| Rails 5xx rate > 1% | 5 minutes | P1 | Page. |
| Rails Puma `backlog` (queued requests) > 5 per task | 3 minutes | P2 | Page. Threads exhausted; either scale out or find the slow endpoint. |
| Rails `db:prepare` failure in entrypoint (log metric filter on `Migration failed`) | any | P1 | Page. Deploy is stuck; the circuit breaker will roll back but a human needs to know why. |

**Dashboards:** one per service, four rows: SLIs, traffic (requests by status), saturation (CPU, memory, connections, Puma threads), dependencies (RDS, LDAP, outbound HTTP). For diagnosis, not detection.

---

## 3. Distributed Tracing

### 3.1 Enabling tracing on the .NET Identity Server

1. **Instrumentation:** `OpenTelemetry.AutoInstrumentation` in the container image. Covers ASP.NET Core, `HttpClient`, and `SqlClient` with no code changes, which fits the ADR's "no application changes" constraint. The classic X-Ray .NET SDK is in maintenance mode; OTel is what AWS recommends and what the Rails app uses.
2. **Propagation:** `OTEL_PROPAGATORS=xray,tracecontext`, so the ALB's `X-Amzn-Trace-Id` is honored and downstream callers (Rails LMS) continue the trace.
3. **Export:** ADOT collector sidecar (`public.ecr.aws/aws-observability/aws-otel-collector`, 256 CPU units / 512 MB), OTLP in on `localhost:4317`, out to X-Ray (traces) and CloudWatch EMF (metrics). Task role: `xray:PutTraceSegments`, `xray:PutTelemetryRecords`, `cloudwatch:PutMetricData`.
4. **One manual span:** the LDAP call to Azure AD DS. OTel has no LDAP auto-instrumentation and this is the most likely latency source (ADR risk R2), so it gets an explicit `ActivitySource` span with query type and result count. The one code change worth making.
5. **Sampling:** 1 req/s reservoir plus 5% for `/connect/*`; 100% of 5xx via tail sampling in the collector; `/health` and `/.well-known/*` at 0%.

The Rails app follows the same pattern with `opentelemetry-instrumentation-all` and the same sidecar.

### 3.2 Diagnosing a latency spike from traces

In the order it usually pays off:

1. **Service map.** Which edge turned yellow: ALB to Identity Server, Identity Server to RDS, or Identity Server to AD DS? This alone resolves most spikes to a tier.
2. **p50 vs p99 on the same route.** p50 flat and p99 up: contention or one caller (filter by `client_id`). Both up: a dependency or the process itself.
3. **Where the time goes inside slow traces.**
   - Large `SqlClient` span: lock waits on persisted grants, a missing index after DMS, or an RDS failover. Cross-check Performance Insights.
   - Large LDAP span: VPN tunnel flap or AD DS under load. Cross-check VPN `TunnelState`.
   - Gap with no child span: thread pool starvation from sync-over-async, or a GC pause. Check GC pause metrics for the window.
4. **Task age.** Filter by `aws.ecs.task.id`. If slow traces are all on tasks under 2 minutes old, it is JIT warm-up during scale-out and the fix is the ADR's scheduled pre-warm, not the application.
5. **Deploy timeline.** Overlay `GIT_SHA`. If the spike starts with a new SHA, the answer is in the diff.

---

## 4. Log Strategy

**Format:** JSON to stdout, one event per line. Serilog compact JSON for .NET, `lograge` JSON for Rails. Every line: `timestamp`, `level`, `service`, `env`, `git_sha`, `trace_id`, `span_id`, `request_id`, plus `route`, `status`, `duration_ms`, `client_id` on requests. Never logged: tokens, authorization codes, passwords, email addresses (hashed `sub` only). A metric filter on `eyJ` (the base64 prefix of every JWT) turns a leaked bearer token into a P2 security ticket.

**Log groups and retention**

| Log group | Source | Retention | Reasoning |
|---|---|---|---|
| `/ecs/identity-server` | awslogs driver, app container | 90 days | Auth logs are audit evidence; 90 days covers a school term's worth of "who logged in when" questions. |
| `/ecs/identity-server/otel` | ADOT sidecar | 14 days | Collector diagnostics only. |
| `/ecs/rails-app` | awslogs driver | 30 days | Volume is higher and the audit need is lower. |
| `/aws/rds/instance/identity-server/error` and `/agent` | RDS SQL Server log export | 30 days | |
| `/aws/rds/instance/rails-app/postgresql` | RDS Postgres log export, `log_min_duration_statement=500` | 30 days | Slow query log without the noise. |
| `/aws/ecs/containerinsights/<cluster>/performance` | Container Insights | 7 days | Metrics are extracted; raw performance logs are cheap to drop. |
| ALB access logs | S3, not CloudWatch | 90 days then Glacier for 1 year | Queried with Athena when needed; too voluminous for Logs pricing. |
| `/aws/dms/tasks/identity-server-*` | DMS (migration only) | 30 days, deleted at ADR Definition of Done | |

All groups KMS-encrypted with the service CMK. A subscription filter on `/ecs/identity-server` forwards `level >= WARN` to the security team's SIEM (assumed).

**CloudWatch Insights query: why are token requests failing right now, and for whom?**

```sql
fields @timestamp, client_id, grant_type, error, status, duration_ms, trace_id
| filter route = "/connect/token" and status >= 400
| stats count(*) as failures,
        avg(duration_ms) as avg_ms,
        latest(trace_id) as sample_trace
  by client_id, grant_type, error
| sort failures desc
| limit 20
```

One screen answers the first three questions of any auth incident: one client or all, one grant type (PowerSchool's `client_credentials` vs. student `authorization_code`) or all, and what the error says. `sample_trace` links straight into X-Ray.

**Second query, for the Rails app: slowest endpoints in the last spike**

```sql
fields @timestamp, controller, action, duration_ms, db_runtime_ms, view_runtime_ms
| filter duration_ms > 1000
| stats count(*) as slow_requests,
        pct(duration_ms, 95) as p95,
        avg(db_runtime_ms) as avg_db_ms
  by controller, action
| sort slow_requests desc
| limit 15
```

`avg_db_ms` against `p95` says whether the fix is a query or the Ruby code.

---

## 5. Alerting Pipeline

```
CloudWatch alarm / composite alarm / EventBridge rule
        |
        v
SNS topic per severity:  alerts-p1  |  alerts-p2  |  alerts-p3
        |
        v
Jira Operations (fka Opsgenie) CloudWatch integration, one API integration per topic,
mapping topic -> alert priority, alarm tags -> responder team and runbook link
        |
        v
On-call schedule (weekly rotation, primary + secondary) with escalation policy
        |
        +--> P1: push + phone call to primary immediately; secondary at +10 min; engineering manager at +20 min
        +--> P2: push to primary during 06:00-20:00 MT; outside those hours, Slack #oncall now and page at 06:00
        +--> P3: Slack #platform-alerts and a Jira ticket. No page, ever.
```

**Severity definitions**

| Severity | Meaning | Page? | Response target | Examples |
|---|---|---|---|---|
| **P1** | Customers cannot log in, or will not be able to within minutes. SLO fast burn. | Yes, 24x7 | Acknowledge in 5 min, mitigate in 30 | Login canary failing, 5xx > 1%, running tasks below desired, RDS storage critical |
| **P2** | Degraded but functioning, or a redundancy has been lost. SLO slow burn. | Yes during 06:00-20:00 MT; otherwise deferred to morning | Acknowledge in 30 min, mitigate same day | p95 latency over threshold, one unhealthy target, RDS failover, LDAP degradation |
| **P3** | Something needs attention this week. No customer impact. | No | Triage in next business day | CPU trending high, cert expiring in 30 days, slow-query volume rising |

**Rules that keep the pager honest**

- **Page on symptoms, notify on causes.** Every P1 is something a customer could describe.
- **Auto-close.** Alarm back to `OK` closes the Jira Operations alert. Nobody hand-resolves conditions that fixed themselves, which keeps the alert list trustworthy.
- **Composite alarms for shared root causes.** An RDS failover fires latency, 5xx, and connection alarms at once. The composite `identity-server-degraded` pages once and lists the children.
- **Maintenance windows.** Deploys and RDS maintenance are registered as Jira Operations maintenance periods, so a planned rollout does not page.
- **Weekly review.** 15 minutes on last week's pages: actionable, runbook right, threshold right. Two pages without action and the alarm is downgraded or deleted.
- **Test the pipeline.** Quarterly synthetic P1, alarm to phone call, with time-to-acknowledge recorded.

---

## Intentionally scoped out

- Cost anomaly detection and budget alarms (belongs in a FinOps doc).
- Front-end RUM for the Rails app.
- Log-based anomaly detection (CloudWatch Logs anomaly detection is worth a trial after 30 days of baseline).
- Per-tenant (per-school) SLOs. Useful eventually; requires `tenant_id` on every span first.