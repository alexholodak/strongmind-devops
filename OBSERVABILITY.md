# Observability Plan: Identity Server and Rails Application

**Covers:** the Identity Server once it's on ECS Fargate (see ADR.md), and the Rails 8 app deployed by `rails-deploy.yml`.
**The goal:** an on-call engineer said "I can't tell if something is wrong until a customer calls." This plan replaces that with signals that fire first and say *where* to look, not just that something broke.

**Three rules**

- Alert on things customers feel (errors, latency, failed logins), not on causes (CPU).
- Every page links to a runbook. No runbook, no P1.
- One pipeline for both services: OpenTelemetry in the app, an ADOT sidecar, CloudWatch and X-Ray behind it, Jira Operations for routing.

---

## 1. SLOs and SLIs (Identity Server)

Every StrongMind product depends on the Identity Server, so its SLOs are the floor for everyone else's.

| SLO | Target | SLI (how we measure it) | Window |
|---|---|---|---|
| **Availability** | 99.9% of requests succeed | `1 - (HTTPCode_Target_5XX_Count / RequestCount)` on the ALB target group. 4xx doesn't count. A wrong password isn't an outage. | Rolling 30 days (error budget: about 43 minutes a month) |
| **Token latency** | 95% of `POST /connect/token` requests finish in under 300 ms, 99% in under 800 ms | `TargetResponseTime` p95 and p99 from the ALB, narrowed to the token endpoint with a listener rule that has its own target group metrics, or from the OTel `http.server.duration` histogram by route | Rolling 30 days |
| **Login success** | 99.5% of synthetic logins succeed | A CloudWatch Synthetics canary (`identity-login-canary`) runs the full OIDC authorization-code flow with a test account every 5 minutes from two regions. `SuccessPercent` metric. | Rolling 7 days |

**What happens when we breach**

- Alerts fire on **burn rate**, not on the raw SLO, so we catch a breach while there's still budget left:
  - Fast burn: 14.4x over 1 hour (that pace uses up the month in about 2 days) pages **P1**.
  - Slow burn: 6x over 6 hours pages **P2**. 1x over 3 days opens a **P3** ticket.
- When the budget hits 100%: feature deploys to the Identity Server stop, only reliability fixes ship, and there's an incident review within 5 business days. This is agreed with product ahead of time, not argued about mid-incident.
- SLO reports get reviewed monthly with engineering leads. Targets only change through a written revision.

---

## 2. Metrics and Alarms

Every alarm uses 1-minute periods unless it says otherwise, carries `service` and `severity` tags, and routes through the SNS topics in Section 5. **Composite alarms** group related conditions so one root cause doesn't page three times.

### 2.1 ECS task health (both services)

Source: ECS Container Insights and ALB metrics.

| Metric | Fires when | Severity | What happens |
|---|---|---|---|
| `RunningTaskCount` < `DesiredTaskCount` | 3 minutes in a row | P1 | Page. Runbook: check why tasks stopped (`aws ecs describe-tasks` on `STOPPED`): image pull, secrets access, OOM kill. |
| ALB `UnHealthyHostCount` >= 1 | 2 minutes | P2 (P1 if half or more of targets) | Page. Usually a bad deploy in progress or a DB connectivity problem. |
| ALB `HTTPCode_Target_5XX_Count / RequestCount` > 1% | 5 minutes | P1 | Page. Same signal as the availability fast burn, just the direct version. |
| ALB `TargetResponseTime` p95 > 500 ms | 5 minutes | P2 | Page between 06:00 and 20:00 MT, notify otherwise. Runbook points at Section 3. |
| `CPUUtilization` > 75% | 3 of 5 minutes | P3 | Notify. Auto scaling should already be handling it. This alarm checks that it did. |
| `MemoryUtilization` > 85% | 3 of 5 minutes | P2 | Page. .NET and Ruby both fall apart fast near the limit, and an OOM kill comes next. |
| ECS deployment circuit breaker rolled back (EventBridge `ECS Deployment State Change`, `SERVICE_DEPLOYMENT_FAILED`) | any time | P2 | Page, plus a post in Slack `#deploys`. Match it up with the GitHub Actions run. |
| ALB `RejectedConnectionCount` > 0 | 1 minute | P2 | Page. The ALB is out of capacity or the tasks aren't accepting connections. |

### 2.2 RDS (SQL Server for the Identity Server, Postgres for Rails)

Source: RDS CloudWatch metrics, Enhanced Monitoring, Performance Insights, RDS event subscriptions.

| Metric | Fires when | Severity | What happens |
|---|---|---|---|
| RDS event: failover started or completed | any time | P2 | Page. It should heal itself in 60-120s. The page is so someone watches the reconnect. |
| `FreeStorageSpace` < 15% of allocated | 5 minutes | P1 | Page. A full disk on the auth database is an outage. Storage autoscaling should prevent this. The alarm catches it not working. |
| `CPUUtilization` > 80% | 15 minutes | P3 | Notify. Open Performance Insights and find the top SQL. |
| `DatabaseConnections` > 80% of the app's pool max (assumed 400 for the Identity Server) | 5 minutes | P2 | Page. A connection leak, or tasks scaled out past what the pool math allows. |
| `ReadLatency` or `WriteLatency` > 20 ms | 10 minutes | P3 | Notify. The gp3 IOPS ceiling, or a checkpoint storm. |
| `DiskQueueDepth` > 10 | 10 minutes | P3 | Notify. Usually shows up with the latency alarm above. |
| `FreeableMemory` < 1 GB | 10 minutes | P2 | Page. SQL Server buffer pool pressure. The instance is too small or a query is spilling. |
| `ReplicaLag` (Postgres read replica, if there is one) > 30 s | 5 minutes | P3 | Notify. |

### 2.3 Application signals

Sent as OTel metrics (through the ADOT sidecar into CloudWatch as EMF) or as metric filters on structured logs.

| Signal | Fires when | Severity | What happens |
|---|---|---|---|
| `identity.token.errors` (token endpoint responses with an `error` other than `invalid_grant`) above 2% | 5 minutes | P1 | Page. Signing key, persisted grant store, or client config problem. |
| `identity.ldap.duration` p95 > 200 ms **or** `identity.ldap.errors` > 0.5% | 5 minutes | P2 | Page. Azure AD DS or the VPN is degraded (ADR risk R2). Runbook: check VPN tunnel status and AD DS health in the Azure portal. |
| `identity.signing_cert.days_to_expiry` < 30 | daily check | P3 | Notify and open a ticket to rotate. Under 7 days becomes P2. |
| Synthetics `identity-login-canary` `SuccessPercent` < 100% | 2 runs in a row | P1 | Page. This is the "a customer is about to call" alarm. |
| Rails `http.server.duration` p95 > 1 s | 5 minutes | P2 | Page during school hours, notify otherwise. |
| Rails 5xx rate > 1% | 5 minutes | P1 | Page. |
| Rails Puma `backlog` (queued requests) > 5 per task | 3 minutes | P2 | Page. Threads are exhausted. Either scale out or find the slow endpoint. |
| Rails `db:prepare` fails in the entrypoint (log metric filter on `Migration failed`) | any time | P1 | Page. The deploy is stuck. The circuit breaker will roll it back, but a person needs to know why. |

**Dashboards:** one per service, four rows: SLIs, traffic (requests by status), saturation (CPU, memory, connections, Puma threads), dependencies (RDS, LDAP, outbound HTTP). These are for figuring out what's wrong, not for noticing it. The alarms do the noticing.

---

## 3. Distributed Tracing

### 3.1 Turning on tracing for the .NET Identity Server

1. **Instrumentation:** `OpenTelemetry.AutoInstrumentation` in the container image. It covers ASP.NET Core, `HttpClient`, and `SqlClient` without touching code, which is what the ADR's "no application changes" constraint needs. The old X-Ray .NET SDK is in maintenance mode. OTel is what AWS recommends now, and it's what the Rails app uses too.
2. **Propagation:** `OTEL_PROPAGATORS=xray,tracecontext`, so the ALB's `X-Amzn-Trace-Id` is honored and downstream callers like the Rails LMS keep the same trace going.
3. **Export:** the ADOT collector sidecar (`public.ecr.aws/aws-observability/aws-otel-collector`, 256 CPU units / 512 MB) takes OTLP in on `localhost:4317` and sends traces to X-Ray and metrics to CloudWatch as EMF. The task role needs `xray:PutTraceSegments`, `xray:PutTelemetryRecords`, and `cloudwatch:PutMetricData`.
4. **One span by hand:** the LDAP call to Azure AD DS. OTel has no LDAP auto-instrumentation, and this is the most likely place latency comes from (ADR risk R2), so it gets an explicit `ActivitySource` span with the query type and result count. This is the one code change worth making.
5. **Sampling:** a reservoir of 1 request per second plus 5% for `/connect/*`. 100% of 5xx responses, through tail sampling in the collector. `/health` and `/.well-known/*` at 0%.

The Rails app does the same thing with `opentelemetry-instrumentation-all` and the same sidecar.

### 3.2 Reading a latency spike in traces

In the order that usually pays off fastest:

1. **Service map.** Which edge went yellow: ALB to Identity Server, Identity Server to RDS, or Identity Server to AD DS? This alone narrows most spikes to a tier.
2. **p50 against p99 on the same route.** p50 flat and p99 up means contention or one caller (filter by `client_id`). Both up means a dependency or the process itself.
3. **Where the time is going inside the slow traces.**
   - A big `SqlClient` span: lock waits on persisted grants, an index that didn't make it through DMS, or an RDS failover. Cross-check Performance Insights.
   - A big LDAP span: a VPN tunnel flapping, or AD DS under load. Cross-check the VPN `TunnelState`.
   - A gap with no child span: thread pool starvation from sync-over-async, or a GC pause. Check GC pause metrics for that window.
4. **Task age.** Filter by `aws.ecs.task.id`. If all the slow traces are on tasks under 2 minutes old, it's JIT warm-up during a scale-out, and the fix is the ADR's scheduled pre-warm, not the app.
5. **Deploy timeline.** Overlay `GIT_SHA`. If the spike starts with a new SHA, the answer is in the diff.

---

## 4. Logs

**Format:** JSON to stdout, one event per line. Serilog compact JSON for .NET, `lograge` JSON for Rails. Every line has `timestamp`, `level`, `service`, `env`, `git_sha`, `trace_id`, `span_id`, `request_id`, and on requests also `route`, `status`, `duration_ms`, `client_id`. Never logged: tokens, authorization codes, passwords, email addresses (only a hashed `sub`). A metric filter on `eyJ`, which is the base64 prefix of every JWT, turns a leaked bearer token into a P2 security ticket.

**Log groups and how long we keep them**

| Log group | Source | Retention | Why |
|---|---|---|---|
| `/ecs/identity-server` | awslogs driver, app container | 90 days | Auth logs are audit evidence. 90 days covers a school term's worth of "who logged in when" questions. |
| `/ecs/identity-server/otel` | ADOT sidecar | 14 days | Collector diagnostics only. |
| `/ecs/rails-app` | awslogs driver | 30 days | More volume, less audit need. |
| `/aws/rds/instance/identity-server/error` and `/agent` | RDS SQL Server log export | 30 days | |
| `/aws/rds/instance/rails-app/postgresql` | RDS Postgres log export, `log_min_duration_statement=500` | 30 days | A slow query log without the noise. |
| `/aws/ecs/containerinsights/<cluster>/performance` | Container Insights | 7 days | The metrics are extracted. The raw performance logs are cheap to drop. |
| ALB access logs | S3, not CloudWatch | 90 days, then Glacier for a year | Queried with Athena when needed. Far too much volume for Logs pricing. |
| `/aws/dms/tasks/identity-server-*` | DMS (migration only) | 30 days, deleted at ADR Definition of Done | |

Every group is KMS-encrypted with the service CMK. A subscription filter on `/ecs/identity-server` forwards `level >= WARN` to the security team's SIEM (assumed to exist).

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

One screen answers the first three questions of any auth incident: is it one client or all of them, one grant type (PowerSchool's `client_credentials` versus a student's `authorization_code`) or all of them, and what does the error actually say. `sample_trace` links straight into X-Ray.

**A second query, for the Rails app: the slowest endpoints in the last spike**

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

`avg_db_ms` next to `p95` tells you whether the fix is a query or the Ruby code.

---

## 5. How alerts reach a person

```
CloudWatch alarm / composite alarm / EventBridge rule
        |
        v
SNS topic per severity:  alerts-p1  |  alerts-p2  |  alerts-p3
        |
        v
Jira Operations (formerly Opsgenie) CloudWatch integration, one API integration per topic,
mapping topic -> alert priority, alarm tags -> responder team and runbook link
        |
        v
On-call schedule (weekly rotation, primary + secondary) with escalation policy
        |
        +--> P1: push + phone call to primary immediately; secondary at +10 min; engineering manager at +20 min
        +--> P2: push to primary during 06:00-20:00 MT; outside those hours, Slack #oncall now and page at 06:00
        +--> P3: Slack #platform-alerts and a Jira ticket. No page, ever.
```

**What the severities mean**

| Severity | Meaning | Page? | Response target | Examples |
|---|---|---|---|---|
| **P1** | Customers can't log in, or won't be able to within minutes. SLO fast burn. | Yes, around the clock | Acknowledge in 5 minutes, mitigate in 30 | Login canary failing, 5xx above 1%, running tasks below desired, RDS storage critical |
| **P2** | Degraded but working, or we've lost a layer of redundancy. SLO slow burn. | Yes between 06:00 and 20:00 MT, otherwise it waits for morning | Acknowledge in 30 minutes, mitigate the same day | p95 latency over threshold, one unhealthy target, RDS failover, LDAP degraded |
| **P3** | Needs attention this week. No customer impact. | No | Triage next business day | CPU trending up, a cert expiring in 30 days, slow-query volume climbing |

**Rules that keep the pager trustworthy**

- **Page on symptoms, notify on causes.** Every P1 is something a customer could describe to you.
- **Auto-close.** When the alarm goes back to `OK`, the Jira Operations alert closes itself. Nobody hand-resolves things that fixed themselves, which is what keeps the alert list believable.
- **Composite alarms for shared root causes.** An RDS failover trips the latency, 5xx, and connection alarms all at once. The composite `identity-server-degraded` pages once and lists the children.
- **Maintenance windows.** Deploys and RDS maintenance are registered as Jira Operations maintenance periods, so a planned rollout doesn't page anyone.
- **Weekly review.** 15 minutes on last week's pages: was it actionable, was the runbook right, was the threshold right. Two pages with no action taken and the alarm gets downgraded or deleted.
- **Test the whole chain.** A synthetic P1 every quarter, alarm to phone call, with the time to acknowledge written down.

---

## Left out on purpose

- Cost anomaly detection and budget alarms. That belongs in a FinOps doc.
- Front-end RUM for the Rails app.
- Log-based anomaly detection. CloudWatch Logs anomaly detection is worth trying after 30 days of baseline.
- Per-tenant (per-school) SLOs. Useful eventually. Needs `tenant_id` on every span first.
