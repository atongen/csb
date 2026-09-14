# plan 011 -- aws access for the sandboxed agent

Status: **CSB SIDE DONE (2026-09-14). AWS SIDE SPECIFIED, NOT PROVISIONED.**
`aws_profile=` / `--aws` resolves, refuses long-lived credentials, and injects a
session in both agent and shell modes. Sections 3 to 6 are the account-side
requirements, to be executed outside this repository.

This supersedes the `--aws` feature removed on 2026-07-14 (see the note in
docs/PLAN-002.md phase 3). What comes back is not the same shape: resolution
lives in csb-config, the injection owns its variables outright, and credentials
that do not expire are refused rather than documented against.

## 0. The decision

Give the agent real, bounded AWS access: a dedicated **view-only** identity, a
**short-lived** session, and a **CloudTrail** record of everything it does.

Four choices, all made 2026-09-14 (operator):

1. **Mechanism.** csb runs `aws configure export-credentials` and refuses a
   result that carries no expiry. It does not call STS itself. *Why:* the aws
   config grammar already expresses every way to mint a session (sso,
   `role_arn`/`source_profile`, `credential_process`); reimplementing one of them
   would make csb a second, disagreeing opinion about a thing the CLI owns.
2. **Egress.** Under `--filter-egress` csb *warns* when an injection has no
   allowlisted AWS endpoint. It does not widen the allowlist. *Why:* an egress
   policy is written deliberately; a credential flag silently editing it is the
   opposite of what filtering was bought for.
3. **Refresh.** The session is fetched once at launch and does not renew. *Why:*
   the broker that would fix it (section 7) is a second server on loopback, and
   the caveat is survivable -- a launch is cheap.
4. **Identity.** The primary shape is **SSO assuming a role**: no long-lived key
   material anywhere, and the agent can only obtain credentials while the
   operator has a live SSO session. The dedicated-IAM-user variant is documented
   as the alternative (3d), since csb cannot tell the two apart.

## 1. What csb does -- as built

### 1a. The axis

`aws_profile=NAME` in any config layer, `--aws NAME` on the command line,
`--no-aws` to retract. An empty value retracts like any other scalar. It is
ordinary configuration, which is the point: activation is a profile.

```
# ~/.config/csb/profiles/aws          (templates/profiles/aws)
aws_profile=agent-view-only
allow_host=*.amazonaws.com
```

```sh
csb -p aws mybranch            # agent, with the session
csb -p aws -s -- aws sts get-caller-identity
csb -p work -p aws mybranch    # composes; the last layer to answer wins
```

### 1b. Short-lived or nothing

`aws configure export-credentials --format env` emits four variables for a
SESSION and only the key pair for long-lived IAM user keys. bin/csb requires all
four, so the missing pair IS the refusal -- there is no second code path to keep
honest, and no way to spell "inject the permanent keys just this once":

```
csb: profile 'agent-view-only' exported no AWS_SESSION_TOKEN, AWS_CREDENTIAL_EXPIRATION,
  so its credentials do not expire.
  csb injects short-lived credentials only: configure the profile as an sso,
  assume-role or credential_process profile instead of long-lived IAM user keys.
```

When the export fails outright (no session yet, or an expired one) csb runs
`aws sso login --profile NAME --use-device-code` and retries once. Those three
verbs -- export, login, `configure get region` -- are the only aws invocations in
bin/csb, and test/invariants.bats asserts there is no fourth: the CLI runs on the
host as the operator, and csb changes nothing there.

### 1c. The variables the injection owns

| Variable | Source |
|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_CREDENTIAL_EXPIRATION` | `export-credentials`, all four required |
| `AWS_REGION`, `AWS_DEFAULT_REGION` | `aws configure get region`, when the profile has one |
| `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE` | pinned to `/dev/null` |

The names live in `ocaml/lib/aws.ml` and reach bin/csb over the emit seam
(`aws_cred_var`, `aws_region_var`, `aws_expiry_var`), so bash extracts whatever
csb-config names and decides nothing about which variables those are.

The pins are what make "only the injected session" true rather than incidental.
A redirected HOME has no `~/.aws` to read, but `--real-home` does -- denied, so
an SDK reaching for it gets a sandbox denial instead of a clean miss.

**Owned means owned.** A `setenv=`, `setenv_cmd=`, `token_env=` or `keep=`
naming one of those variables is REFUSED, the same rule that already governs
setenv/setenv_cmd/token_cmd: they all land in one `env` invocation where the
last argument would win silently. `keep=AWS_PROFILE` (and `AWS_DEFAULT_PROFILE`)
is refused for a different reason -- it names a profile whose definition lives in
the denied `~/.aws`, so the SDK would fail looking for it while holding a
perfectly good session.

The credential values never reach a config seam: `--dump-config` reports the
profile NAME, and the only thing printed at launch is the expiry, which is what
makes staleness visible at the one moment something can be done about it.

### 1d. Egress

Under `--filter-egress` the sandbox reaches only allowlisted hosts, so an
injection with no AWS endpoint listed is a session the launch cannot spend --
and the failure surfaces as an opaque transport error, not as a policy message.
csb warns:

```
csb: warning: aws_profile is set but no allow_host covers *.amazonaws.com, so the
  injected credentials reach no AWS endpoint (see templates/profiles/aws)
```

Off by default, filtering is not in play and the hint does not fire.
`*.amazonaws.com` covers the service endpoints; `*.api.aws` and
`docs.aws.amazon.com` are commented in the template for the cases that need them.

### 1e. Where it runs in a launch

Host-side, in the same block as `token_cmd` and `setenv_cmd`, BEFORE any
worktree or namespace side effect: a failed fetch aborts a clean launch rather
than a half-prepared one. Like `setenv_cmd` and unlike `token_cmd`, it is NOT
skipped in `-s` shell mode -- an operator running `aws` in the sandbox needs the
session exactly as the agent would get it. Dumps (`--dump-config`,
`--dump-sandbox`), `-n`, `-d` and the listings never reach it.

## 2. Verification

### 2a. What the suite covers

`test/aws.bats` (25 tests, in `make test` and in the csb-config oracle):
resolution and precedence across all four layers, retraction, the name charset,
the setenv pins, all five refusals, the egress hint firing and not firing, the
emitted variable names, and bin/csb adopting the new records. Plus the
source-level invariant in `test/invariants.bats`.

### 2b. What only a real launch can show

The fetch itself -- running the aws CLI, parsing its output, refusing a
long-lived profile -- is not reachable from a dump seam, because a dump
deliberately touches no credentials. Verify it by hand, once per platform:

```sh
# 1. the session reaches the sandbox, and it is the view-only role
csb -p aws -s -E --here -- aws sts get-caller-identity
#    expect: Arn ...:assumed-role/agent-view-only/<session-name>

# 2. the file store stays unreachable
csb -p aws -s -E --here -- cat "$HOME/.aws/config"        # denied
csb -p aws -s -E --here -- env | grep -c AWS_             # 8

# 3. view-only is view-only
csb -p aws -s -E --here -- aws ec2 describe-instances      # works
csb -p aws -s -E --here -- aws ec2 delete-key-pair --key-name x   # AccessDenied

# 4. long-lived credentials are refused (point the profile at static keys once)
csb --aws some-static-profile -s -E --here -- true
#    expect: the "do not expire" refusal, exit 1, no worktree touched

# 5. under filtering, with and without the allowlist
csb -p aws --filter-egress -s -E --here -- aws sts get-caller-identity
csb --aws agent-view-only --filter-egress --allow-host api.anthropic.com \
    -s -E --here -- true      # expect: the warning
```

Step 3's AccessDenied is also the CloudTrail check: it must appear in the trail
within ~15 minutes, attributed to the role session (section 4b).

## 3. The AWS account side -- requirements

Executed outside this repository. Nothing here is csb-specific: csb consumes
whatever `~/.aws/config` resolves to.

### 3a. The identity

**Primary: the operator's SSO identity assumes a dedicated role.**

- Role **`agent-view-only`**, in the account the agent works in.
- Trust policy: the operator's SSO permission-set role, and nothing else.
- `MaxSessionDuration`: **3600** (1 hour, the default). Do not raise it.
- No console access, no long-lived keys, nowhere.

Why this shape: no key material exists to leak, and the agent can only obtain
credentials while the operator has a live SSO session -- it cannot act at 3am
after that session lapses. Revocation is one trust-policy edit plus at most one
hour of already-issued session.

The cost is that the chain's root principal is the operator, one hop back. The
role session name is what separates agent activity from the operator's own, so
it is a requirement and not a nicety (4b).

### 3b. The role's policy

Start with exactly one attachment:

```
arn:aws:iam::aws:policy/job-function/ViewOnlyAccess
```

**ViewOnly, not ReadOnly, deliberately.** ViewOnlyAccess grants List/Describe and
metadata Get; ReadOnlyAccess additionally grants the *contents* of things
(`s3:GetObject`, `dynamodb:GetItem`, secrets). The agent should be able to see
that a bucket exists without being able to read what is in it.

Two requirements that follow from it being an AWS-managed job-function policy:

- **Verify its contents before trusting this description**, rather than trusting
  the name or this document:

  ```sh
  aws iam get-policy --policy-arn arn:aws:iam::aws:policy/job-function/ViewOnlyAccess
  aws iam get-policy-version --policy-arn arn:aws:iam::aws:policy/job-function/ViewOnlyAccess \
      --version-id "$(aws iam get-policy \
        --policy-arn arn:aws:iam::aws:policy/job-function/ViewOnlyAccess \
        --query 'Policy.DefaultVersionId' --output text)"
  ```

- **AWS can widen it.** A new default version applies to the role the moment it
  ships, with no action here. Accept that, or copy the document into a
  customer-managed policy and take responsibility for updating it. Decide
  explicitly; do not leave it unexamined. (Open question 9.1.)

Optional hardening worth considering at provisioning time: an explicit `Deny` on
`iam:Get*`/`iam:List*` if enumerating principals and policy documents is not
wanted, since ViewOnly's IAM reads describe the account's whole permission graph.

### 3c. The host profile

```ini
# ~/.aws/config
[profile agent-view-only]
role_arn          = arn:aws:iam::<ACCOUNT>:role/agent-view-only
source_profile    = <your-sso-profile>       # or: sso_session = <name>
role_session_name = csb-agent-<hostname>
region            = us-east-1
duration_seconds  = 3600
```

`role_session_name` is the attribution key (4b) and must match
`[\w+=,.@-]{2,64}`. Everything else about the shape is the CLI's business; csb
reads only what `export-credentials` returns.

Verify the profile yields a SESSION before pointing csb at it:

```sh
aws configure export-credentials --profile agent-view-only --format env | cut -d= -f1
# expect all four: AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
#                  AWS_CREDENTIAL_EXPIRATION
aws sts get-caller-identity --profile agent-view-only
```

### 3d. The IAM-user alternative

If a machine identity is wanted at the root of the chain instead of the
operator's:

- IAM user **`agent-view-only`**, no console, no attached policy except
  `sts:AssumeRole` on the one role above; the role's trust policy names the user.
- The host profile gains `source_profile = agent-view-only-keys`, whose
  credentials are that user's access key.
- Everything else is identical, csb included.

What it buys: CloudTrail's `AssumeRole` event names a machine principal, so agent
activity is unambiguous without relying on the session name. What it costs: a
permanent key pair on the laptop (in `~/.aws/credentials`, denied to the sandbox
but present on the host), and a rotation obligation -- 90 days, with
`aws iam list-access-keys --user-name agent-view-only` reporting `CreateDate`.

## 4. CloudTrail -- what must be true

The point of the view-only role is that its activity is *reviewable*. Each item
below is a requirement with the command that checks it.

### 4a. The trail

```sh
aws cloudtrail describe-trails --include-shadow-trails \
  --query 'trailList[].{Name:Name,Multi:IsMultiRegionTrail,Org:IsOrganizationTrail,
                        Validation:LogFileValidationEnabled,Kms:KmsKeyId,
                        Bucket:S3BucketName,CWL:CloudWatchLogsLogGroupArn}'
aws cloudtrail get-trail-status --name <TRAIL>        # IsLogging, LatestDeliveryTime
aws cloudtrail get-event-selectors --trail-name <TRAIL>
```

Required:

- a trail exists and `IsLogging` is **true** (a trail that stopped delivering
  looks exactly like a quiet account);
- `IsMultiRegionTrail` **true** -- a view-only agent enumerates every region it
  is curious about, and a single-region trail would miss it;
- management events included with `ReadWriteType` = **All**. READ events are the
  entire signal here: a view-only principal produces almost nothing else;
- `LogFileValidationEnabled` **true**, and the digest chain actually verified at
  least once:

  ```sh
  aws cloudtrail validate-logs --trail-arn <ARN> --start-time <ISO8601>
  ```

- the S3 bucket is SSE-KMS encrypted, versioned, public access blocked, with a
  lifecycle policy giving **>= 365 days** retention;
- data events are NOT required for this role (ViewOnly cannot read object
  contents), and are left as whatever the account already does.

Event history covers 90 days with no trail at all, which is enough to answer
"what did it do last week" but not to keep a record. It is a fallback, not the
requirement.

### 4b. Attribution

Every event the agent produces must be attributable to the agent without
guessing. With the role shape above, each carries:

```
userIdentity.type                                    = AssumedRole
userIdentity.arn                                     = arn:aws:sts::<ACCT>:assumed-role/agent-view-only/csb-agent-<host>
userIdentity.sessionContext.sessionIssuer.userName   = agent-view-only
```

Requirement: **one role session name per host, reserved for csb**, set in
`~/.aws/config` (3c). If a human ever assumes `agent-view-only` directly, they
must use a different session name -- otherwise the one field that separates agent
from operator stops separating them.

Cheap check, no infrastructure, last 90 days:

```sh
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=Username,AttributeValue=csb-agent-<host> \
  --max-results 25
```

### 4c. Detection

Two signals worth alarming on, both narrow enough not to be noise:

1. **`AccessDenied` from this principal.** A view-only agent hitting the policy
   boundary is either a mistake or a probe; either way it should be seen.
2. **Any non-read action from this principal.** It should be impossible. An
   alarm that fires means the role's policy changed.

If the trail ships to CloudWatch Logs, both are metric filters:

```
{ $.userIdentity.sessionContext.sessionIssuer.userName = "agent-view-only"
  && $.errorCode = "*AccessDenied*" }

{ $.userIdentity.sessionContext.sessionIssuer.userName = "agent-view-only"
  && $.readOnly IS FALSE }
```

Otherwise an EventBridge rule on `AWS API Call via CloudTrail` with the same
`userIdentity` match, targeting SNS. Requirement: whichever is chosen, verify it
by causing a denial on purpose -- step 3 of section 2b is exactly that test --
and confirm the alarm fires.

### 4d. Review

For a periodic read of what the agent has been doing, one of:

- **CloudTrail Lake** (or Athena over the S3 bucket):

  ```sql
  SELECT eventtime, eventsource, eventname, awsregion, errorcode
  FROM <event_data_store>
  WHERE useridentity.arn LIKE '%assumed-role/agent-view-only/%'
    AND eventtime > timestamp '2026-09-01 00:00:00'
  ORDER BY eventtime DESC
  ```

- `aws cloudtrail lookup-events` as in 4b, for the last 90 days without
  standing infrastructure.

## 5. Revocation runbook

In escalating order, with what each costs:

1. **End the operator's SSO session** (`aws sso logout`). New credentials cannot
   be minted; issued ones live out their hour. Costs nothing else.
2. **Edit the role's trust policy** to trust nothing. Same effect, independent of
   the operator's session, and survives a re-login.
3. **Detach `ViewOnlyAccess`** from the role. Existing sessions keep the role but
   lose every permission immediately -- this is the one that stops an
   in-flight session.
4. Under the IAM-user variant, additionally deactivate the user's access key:
   `aws iam update-access-key --user-name agent-view-only --access-key-id <ID> --status Inactive`.

The 1-hour session duration is what makes 1 and 2 sufficient in most cases, and
is why it must not be raised.

## 6. Later: CloudWatch Logs read

The first likely widening, and it should NOT reuse ViewOnlyAccess. A separate
customer-managed policy, scoped to named log groups rather than `*`:

```json
{ "Effect": "Allow",
  "Action": ["logs:FilterLogEvents", "logs:GetLogEvents", "logs:StartQuery",
             "logs:GetQueryResults", "logs:DescribeLogStreams"],
  "Resource": ["arn:aws:logs:<REGION>:<ACCT>:log-group:/aws/<service>/<name>:*"] }
```

Log contents are data, not metadata, which is exactly the line ViewOnly draws --
so this is a deliberate exception to it and deserves its own policy, its own
review, and a note in whatever the account's access documentation is. Naming the
log groups explicitly is the whole point; `Resource: "*"` gives the agent every
log in the account, including ones that carry secrets in plaintext.

No csb change is required for it: the role gains a policy, and the injection is
unchanged.

## 7. Later: the refresh broker

The standing caveat is that the session does not renew inside a launch. The fix
the AWS SDKs already support: `AWS_CONTAINER_CREDENTIALS_FULL_URI` pointing at a
loopback endpoint csb serves OUTSIDE the sandbox, refreshing host-side and
handing out a current session on demand, with `AWS_CONTAINER_AUTHORIZATION_TOKEN`
as the shared secret.

It is more feasible than when it was first written down (docs/TODO.md, dropped
2026-07-14): csb-proxy already establishes the pattern of a host-side server the
sandbox reaches over loopback, with the ownership stamp and janitor reaping that
go with it. What it still costs: a second server, its lifecycle, an
`--allow-port` interaction under `--filter-egress`, and a story for what the
endpoint hands out when the underlying SSO session has expired.

Deferred deliberately. Re-open it if re-launching to refresh becomes the thing
that actually gets in the way.

## 8. Decisions -- closed (operator, 2026-09-14)

- export-credentials + refuse non-temporary, rather than csb calling STS (0.1).
- Warn under `--filter-egress`, never widen the allowlist (0.2).
- Static injection now; the broker is section 7, not a TODO line (0.3).
- SSO assumes the role as the primary identity shape; the dedicated IAM user is
  the documented alternative (0.4, 3d).
- Activation is config-driven: `aws_profile=` in a profile, `-p aws` to launch
  with it. `--aws` / `--no-aws` exist as the per-run override, not as the
  expected way to use the feature.

## 9. Open questions

1. **ViewOnlyAccess is AWS-managed and can widen without notice.** Accept the
   managed policy, or copy it to a customer-managed one and own the updates?
   Not blocking: start managed, revisit once the role has been used in anger.
2. **One role per account, or one shared role assumed cross-account?** Only
   matters once the agent needs a second account; the trust policy answers it
   either way.
3. **Does the agent need a region other than the profile's?** Both region
   variables are injected from `aws configure get region`, so a multi-region
   session relies on the agent passing `--region`. Fine for view-only work;
   revisit if it is not.
