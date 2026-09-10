# StrongMind Staff DevOps Engineer: Technical Exercise

Alex Holodak · September 2026

This is my answer to the four-part exercise: an ADR for moving the Identity Server off Azure, a Rails CI/CD pipeline, a production Dockerfile, and an observability plan. I wrote everything as if it were going into StrongMind's engineering docs and someone would actually use it.

## What's here

| File | Part | What it is | Read it if you want to know |
|---|---|---|---|
| [`ADR.md`](ADR.md) | 1 | The plan for moving the Identity Server from Azure App Service to ECS Fargate | Why the database moves first, why Azure AD DS stays put for now, and what the rollback is at every step |
| [`.github/workflows/rails-deploy.yml`](.github/workflows/rails-deploy.yml) | 2 | A GitHub Actions pipeline any Rails service can copy: test, scan, build, push, deploy, roll back | How OIDC replaces access keys (we did this at Polyarc), why rollback targets the running revision instead of "previous," and how deploys are kept from stepping on each other |
| [`Dockerfile`](Dockerfile) | 3 | Multi-stage Rails 8 / Ruby 3.3 image for Fargate | Why slim beats alpine here, why port 3000 and not 80, and what I deliberately left out of the runtime image |
| [`.dockerignore`](.dockerignore) | 3 | What never gets copied into the image | `.git`, specs, `master.key`, logs, caches |
| [`OBSERVABILITY.md`](OBSERVABILITY.md) | 4 | SLOs, alarms, tracing, logging, and how alerts get to Jira Operations | What pages you at 3 AM, what doesn't, and how to read a latency spike |

The four documents point at each other where they share a decision: task sizing, health checks, the sidecar, IAM.

## How I approached it

**Change one thing at a time.** The ADR moves the cloud provider and nothing else. The .NET upgrade, the Azure AD DS dependency, and any database engine change each get their own ADR later.

**Zero downtime where it's actually possible.** The compute cutover really is zero-downtime, via Route 53 weighted routing. The database step is a short, scheduled window at 2 AM where issuing new tokens degrades for a few minutes and validating existing tokens does not.

**Design the rollback before the deploy.** Every cutover step in the ADR has a trigger and a procedure for backing out. The pipeline records what it will roll back to before it touches the service. The observability plan puts numbers on "unhealthy."

**One observability pipeline for both services.** OpenTelemetry in the app, ADOT collector as a sidecar, CloudWatch and X-Ray behind it, Jira Operations on top. The .NET service and the Rails app instrument differently but land in the same place with the same conventions.

## Assumptions I made

The scenario is deliberately underspecified, so here's what I filled in and what changes if I got it wrong.

| Assumption | Where it matters | If I'm wrong |
|---|---|---|
| The Identity Server is Duende IdentityServer or IdentityServer4 on ASP.NET Core with EF Core | ADR sections 1, 3.1, 3.3, risk R1 | The Data Protection key ring and persisted-grants details change. The shape of the migration doesn't. |
| Signing certs can be exported from Key Vault, and callers validate tokens offline via JWKS | ADR section 4, risk R1 | If the keys are HSM-backed and can't leave, you publish a new key in JWKS on both sides before cutover and retire the old one after every token has expired. Adds about two weeks. |
| Azure AD DS lookups are LDAP and need a private network path | ADR sections 2, 3.4, risk R2 | If it's Graph API over HTTPS, the VPN is only needed for DMS and the temporary App Service to RDS hop. |
| The Azure SQL tier supports CDC, and the database is under about 20 GB | ADR section 5 | Bigger database: the DMS full load takes longer, plan still holds. No CDC: fall back to a longer read-only window with a BACPAC import. |
| StrongMind's public DNS is in Route 53 | ADR section 4 | Weighted routing works with any DNS provider that has it. You'd need an equivalent to Route 53 health checks. |
| The Rails app uses Propshaft and importmap (the Rails 8 defaults) and has no ActiveStorage image variants | Dockerfile | Add a Node stage for jsbundling, add `libvips` for variants. Both are commented in place. |
| `bin/docker-entrypoint` is the one `rails new` generates, and it runs `db:prepare` on server start | Dockerfile, pipeline | The exercise says migrations run in the entrypoint. This is how Rails 8 does it out of the box. |
| A `staging` environment exists with the same naming (`strongmind-staging` cluster, `rails-app` service) | Pipeline `resolve` job | Only production names were given. Staging is there so `workflow_dispatch` has somewhere to go. |
| Staging and production share one AWS account, which is what the single `AWS_ACCOUNT_ID` and `ECR_REPOSITORY` secrets imply | Pipeline `build` and `deploy` jobs, the IAM section below | Separate accounts is what AWS recommends, and this design is a config change away from it. Make `AWS_ACCOUNT_ID` an environment-scoped secret so the deploy role ARN resolves per account; the deploy job already declares its environment, and the roles are already one per environment. Create the OIDC provider in each account. Put ECR in a shared-services account with a repository policy (and a KMS key policy, if you use a CMK) that lets each account's task execution role pull, so an image is built and scanned once and promoted by task definition instead of rebuilt. ECR replication is the fallback if production is only allowed to pull from its own account. The push role moves to the ECR account, whose ID is already in the `ECR_REPOSITORY` URI. Nothing in the deploy, rollback, or notify steps changes. |
| `ECR_REPOSITORY` is a secret because the exercise says so, even though it isn't sensitive | Pipeline `build` and `deploy` jobs | GitHub drops any job output that contains a secret, so the image URI can't be passed from `build` to `deploy`. The pipeline passes only the SHA and rebuilds the URI in `deploy`. As a repository *variable* this workaround goes away and the URI shows up in logs. |
| The Gemfile has `rspec_junit_formatter` and `brakeman` in the `test`/`development` group | Pipeline `test` and `brakeman` jobs | Add both gems, or drop the JUnit output and run Brakeman with `gem exec brakeman`. |

## What the pipeline needs that isn't in this repo

The exercise asks for the workflow file, but a workflow is half of a deploy. These three things live outside the repo and the pipeline doesn't work without them. In real life they'd be in Terraform next to the ECS service.

### The GitHub OIDC provider and the CI roles

One-time setup in the account:

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"] # AWS ignores this for GitHub since 2023 but the argument is required https://github.blog/changelog/2022-01-13-github-actions-update-on-oidc-based-deployments-to-aws/
}
```

Or with the AWS CLI:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

Three roles. The push role can be assumed from any branch and can only write to ECR. Each deploy role can only be assumed through its GitHub environment and can only touch that environment's service.

| Role | Assumed by | Trusted subject | Can do |
|---|---|---|---|
| `github-actions-rails-push` | `build` | `repo:strongmind/rails-app:ref:refs/heads/*` | Push to the one ECR repository. Nothing in ECS. |
| `github-actions-rails-deploy-staging` | `deploy` (staging) | `repo:strongmind/rails-app:environment:staging` | Register task definitions and update the staging service. Only that. |
| `github-actions-rails-deploy-production` | `deploy` (production) | `repo:strongmind/rails-app:environment:production` | Register task definitions and update the production service. Only that. |

Why a role per environment instead of one deploy role with two subjects: staging has no required reviewers. With one shared role, anyone who can kick off a staging deploy from a branch is holding a token whose permissions reach the production cluster, and the only thing stopping them from using it is the workflow file. With a role per environment, the production role is only reachable through the production environment, which the `resolve` job only allows from `main`, and which is where required reviewers would go if a team turns them on. The workflow picks the role by suffix, so repos that adopt this don't change anything.

Why the push role trusts every branch: the exercise says any branch push runs CI, and a branch can be dispatched to staging, so the build job has to be able to push from branches. What it pushes is harmless on its own. A SHA-tagged image doesn't run anywhere until a task definition references it, and only a deploy role can register one. The build job doesn't declare an `environment:`, so its subject is the branch ref, and the wildcard is all it can present.

The deploy job is the only one that references a GitHub environment. That matters if anyone ever turns on required reviewers for `production`. GitHub applies them **per job**, not per run. The docs describe each job waiting on its own, and a [community thread](https://github.com/orgs/community/discussions/88692) from January 2024 reports "3-4 approvals for each workflow" with no answer from GitHub. If `build` also referenced `production`, reviewers would get asked twice. As written, they get asked once, at `deploy`, about a SHA that has already passed RSpec and Brakeman and is sitting in ECR.

The `resolve` job, not IAM, is what enforces that production only deploys from `main`. A pull request from a fork gets no `id-token` at all and can't assume any of the roles.

Trust policy for `github-actions-rails-deploy-production`. The staging role is the same with its own subject. The push role uses `StringLike` for the branch wildcard:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:strongmind/rails-app:environment:production"
      }
    }
  }]
}
```

Permissions, scoped to specific resources instead of `*`:

| Role | Action | Resource |
|---|---|---|
| push | `ecr:GetAuthorizationToken` | `*` (the API doesn't support anything narrower) |
| push | `ecr:BatchCheckLayerAvailability`, `ecr:PutImage`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` | the one repository ARN |
| deploy-`<env>` | `ecs:DescribeServices`, `ecs:UpdateService` | that environment's service ARN only |
| deploy-`<env>` | `ecs:DescribeTaskDefinition`, `ecs:RegisterTaskDefinition`, `ecs:DeregisterTaskDefinition` | `arn:aws:ecs:us-east-1:ACCOUNT_ID:task-definition/rails-app:*` (the family, since you don't know the revision ahead of time) |
| deploy-`<env>` | `iam:PassRole` | the `rails-app-task` and `rails-app-task-execution` role ARNs only, with the condition `iam:PassedToService = ecs-tasks.amazonaws.com` |

Turn on tag immutability on the ECR repository so a SHA tag can't be overwritten once it's pushed.

Naming across services: `github-actions-<repo>-push` and `github-actions-<repo>-deploy-<env>` for the CI roles, `<service>-task` and `<service>-task-execution` for the runtime roles. The Identity Server ADR uses the same pattern.

### ECS service settings

The service has to be created with:

- `deploymentConfiguration.deploymentCircuitBreaker = { enable: true, rollback: true }`. This is the platform's own rollback. The pipeline's rollback covers what the circuit breaker doesn't (a service that never reaches steady state without a hard task failure) and makes sure someone gets told. It's idempotent: it checks the service's PRIMARY deployment first, and if the circuit breaker already put it back on the recorded revision, it just waits for stability instead of forcing a second deployment. The Slack message says which one did the rollback.
- `minimumHealthyPercent = 100`, `maximumPercent = 200`, so a deploy never drops below full capacity.
- `healthCheckGracePeriodSeconds = 60`, so `db:prepare` in the entrypoint has time to finish before the ALB starts counting failures.
- A task definition `healthCheck` block that mirrors the Dockerfile `HEALTHCHECK`, because Fargate ignores the Dockerfile one. The exact command is in the Dockerfile comments.

### GitHub repository settings

- Secrets: `AWS_ACCOUNT_ID`, `ECR_REPOSITORY`, `SLACK_WEBHOOK_URL`, and `RAILS_MASTER_KEY` if the test suite needs it.
- Environments `production` and `staging`. Staging has no protection rules; it's where branches get tried out. Required reviewers on `production` are optional and not part of this design. If a team wants them, the `environment:` key on `deploy` makes it a one-click setting that asks once per run.
- Branch protection on `main` requiring a pull request review plus the `RSpec` and `Brakeman` checks. This is the production gate. Deploys only happen from `main`, so this is what makes "reviewed and tested before it ships" true.

## Using this pipeline in another Rails service

1. Copy `.github/workflows/rails-deploy.yml` and `Dockerfile` into the repo.
2. Change `ECS_TASK_FAMILY`, `ECS_SERVICE`, and `CONTAINER_NAME` in the `env:` block. Nothing else in the file is specific to a service.
3. Create the three IAM roles, the two GitHub environments, and the secrets above.
4. Add a `brakeman.ignore` if the repo already has a pile of Brakeman findings. The pipeline fails on medium-or-higher confidence by default, and it should. A new service should start clean.
5. Push a branch. CI runs. Merge to `main`. Production deploys.

## What I left out on purpose

Things I didn't do in the time I had, and what I'd do with more.

| Left out | Why | With more time |
|---|---|---|
| Terraform for the ECS service, ALB, RDS, IAM, and VPC in the ADR | The exercise asks for the ADR, not the build. The ADR is specific enough to be the spec. | An `infra/identity-server/` Terraform module with the task definition, auto scaling, and the alarms from OBSERVABILITY.md. The ADR's Definition of Done already requires this (item 8). |
| CodeDeploy or ECS-native blue/green for the Rails service | Needs a second target group and listener rule that weren't in the given infrastructure. Rolling plus circuit breaker plus the pipeline's rollback meets the requirement. | Move to ECS native blue/green with a 10% canary listener rule and CloudWatch alarm gates. Rollback becomes built in (green fails before the listener shifts, so traffic never leaves blue) and the pipeline's rollback step gets deleted. Only deregister and notify would stay. |
| A working `bin/docker-entrypoint` and a sample Rails app in this repo | It would make `docker build` runnable, but it's a few hundred lines of generated code that says nothing about how I think. | Add a minimal generated app so a reviewer can run `docker build --target runtime .` and the whole pipeline against a sandbox account. |
| Native arm64 build runners | QEMU works and is easier to explain. It's just slow. | A build matrix with `ubuntu-24.04-arm` for the arm64 half and a manifest merge step. Roughly halves the deploy build. |
| Image signing and SLSA provenance | `provenance: false` is set in the pipeline to keep the ECR manifest simple. | Turn provenance on, sign with `cosign` using keyless OIDC, and add an ECS admission check. |
| Migrating Azure AD Domain Services | Kept out of the ADR so the migration does one thing. | A follow-up ADR weighing AWS Managed Microsoft AD against dropping the LDAP dependency for a synced user store in RDS. Target: one quarter after cutover. |
| .NET 6 to .NET 10 | Same reason: one thing at a time. Jumping two LTS boundaries in one step is exactly the kind of change that shouldn't ride along with a cloud move. | First sprint after the ADR's Definition of Done. Once it's containerized, this is a base-image change plus a test cycle. .NET 10, not 8: 8 leaves support in November 2026, which is about when that sprint would land. |
| A cost model | No numbers were given for the Azure side. | A 30-day comparison after cutover, per Definition of Done item 9. |
| Per-tenant SLOs and dashboards | Needs a `tenant_id` on every span first, which is an app change. | Add it during the .NET 10 sprint and split the SLO dashboards by school district. |

## How I used AI

I used Claude throughout and treated it like a strong senior engineer drafting on my behalf: fast at a structured first pass, and every specific claim gets checked.

**What I decided and own:** the migration order (database first, then weighted compute), keeping Azure AD DS where it is, the "one change at a time" rule, making the pipeline roll back to the *running* revision rather than "previous," picking slim over alpine, and every threshold in the observability plan. On review, later: splitting the deploy role per environment, keeping the pipeline at two GitHub environments instead of three (more on that below), keeping `.dockerignore` even though the exercise doesn't list it (the Dockerfile's `COPY . .` makes it load-bearing for Part 3), and the idempotent rollback check, which came out of asking what happens when the circuit breaker and the pipeline's rollback both fire.

**What I checked instead of trusting:**

- `amazon-ecs-deploy-task-definition@v2` strips the read-only fields from a `describe-task-definition` dump. It does.
- Fargate ignores the Dockerfile `HEALTHCHECK`. It does, which is why the task definition mirrors it.
- `ENV` in a Dockerfile doesn't expand shell substitutions. It doesn't, which caught an arm64 jemalloc path bug.
- Azure SQL Database works as a DMS source with CDC. It does, depending on tier.
- GitHub drops job outputs that contain a secret. It does, which caught the first draft passing the full image URI between jobs, where it would have shown up empty.
- GitHub environment approvals are per job, not per run. They are, which is why `build` has no environment and its own push role. An earlier draft put `production` on both jobs and would have asked reviewers twice.
- The ECS task-definition APIs accept a task-definition resource ARN. They do. The first draft of the permissions table had them on `*`.

**What I overrode:** the first draft used the AWS X-Ray daemon and SDK for tracing. I swapped in OpenTelemetry and the ADOT collector, because the X-Ray SDK is in maintenance mode and having one instrumentation path for .NET and Ruby matters more than matching the exercise's wording. The first draft also claimed zero downtime for the database cutover. I rewrote it to separate issuing tokens from validating them, because the honest version is the one I can defend in the follow-up conversation.

A second look at the build job's `environment:` key turned up the double-approval problem described above. Claude's first fix added a third GitHub environment called `ci` with a push role scoped to it. I went back to the exercise: it describes push-to-main continuous deployment and never mentions manual approval, so the production gate is branch protection on `main`, and environment reviewers are an optional extra. The simpler version, no environment on `build` and a push role that trusts `refs/heads/*`, has the same security properties with one less concept, and it uses the two environments that already exist. That's what shipped. I kept the per-environment deploy roles from that fix because the exercise calls out least-privilege IAM by name and it's a one-line change.

The draft named .NET 8 as the runtime to upgrade to after the migration and said the 6.0 base image runs as the built-in `app` user. Both were out of date. Microsoft's support table has .NET 8 leaving support on November 10, 2026, right about when the upgrade sprint would land, so the target is .NET 10 LTS, supported to 2028. And the non-root `app` user with uid 1654 arrived in the .NET 8 images. The 6.0 image doesn't have one, so the Dockerfile creates it.

**What I ran locally:** `actionlint` with `shellcheck` on every `run:` block (clean, one false positive on JMESPath backtick literals that I rewrote in the raw-string form), `hadolint` (clean, one deliberate `DL3008` ignore explained in place), and `docker build --target base` for amd64 and arm64 to confirm the jemalloc symlink resolves on both. The later stages need a real Rails app in the build context, which this repo intentionally doesn't have.

**Not verified, and would be before merging:** a full image build against a real Rails 8 app, and a DMS dry run against a real Azure SQL source.
