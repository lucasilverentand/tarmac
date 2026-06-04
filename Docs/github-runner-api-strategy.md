# GitHub runner API strategy

Tarmac supports GitHub.com organization runners through GitHub App installation
tokens and GitHub Enterprise Cloud enterprise-level runners through an
enterprise-scoped access token.

This document records the API boundary so implementation issues can point at
specific endpoints instead of reopening the product/API decision.

## Support matrix

| Environment | First-version status | API path |
| --- | --- | --- |
| GitHub.com organization runners | Supported | `https://api.github.com/orgs/{org}/actions/...` with a GitHub App installation token. |
| GitHub Enterprise Cloud organization runners | Supported when the organization uses the same GitHub.com org runner APIs and the app is installed on that org. Enterprise-owned apps still need an organization installation for each runner organization. |
| GitHub Enterprise Cloud enterprise-owned app setup | Supported as an app ownership source for organization runner accounts. Enterprise-level runner accounts do not use GitHub App installation tokens. |
| GitHub Enterprise Cloud enterprise-level runners | Supported with `https://api.github.com/enterprises/{enterprise}/actions/...` and an OAuth or classic PAT token that can manage enterprise runners. |
| GitHub Enterprise Server organization runners | Out of scope for the first version. The API host, version support, auth model, and runner release compatibility need a separate compatibility pass. |
| Repository-level runners | Out of scope unless a later issue adds repository-scoped configuration. The product model is organization-first. |

## Required GitHub App permissions

The app should request the organization `Self-hosted runners` permission with
`write` access. GitHub documents that GitHub App installation access tokens can
use the organization self-hosted runner endpoints, including:

- list runner applications: `GET /orgs/{org}/actions/runners/downloads`
- create JIT config: `POST /orgs/{org}/actions/runners/generate-jitconfig`
- create registration token fallback: `POST /orgs/{org}/actions/runners/registration-token`
- list runners for reconciliation: `GET /orgs/{org}/actions/runners`
- remove stale Tarmac-owned runners: `DELETE /orgs/{org}/actions/runners/{runner_id}`
- inspect runner groups: `GET /orgs/{org}/actions/runner-groups`
- inspect runners in a group: `GET /orgs/{org}/actions/runner-groups/{runner_group_id}/runners`

Setup checks may also read organization self-hosted runner policy through
`GET /orgs/{org}/actions/permissions/self-hosted-runners`. That endpoint is
documented under organization `Administration` read permission rather than
`Self-hosted runners`, so it should be treated as optional diagnostics unless the
app explicitly asks users to grant that extra permission.

Tarmac should not require users to copy the organization installation ID by hand.
After the user imports the app private key, Tarmac can use the app JWT with
`GET /orgs/{org}/installation` to discover the organization installation ID.
Do not use an enterprise installation ID for this field. GitHub enterprise
installations grant enterprise permissions only, so organization runner tokens
still require the app to be installed on the organization that owns the runner
scale set.

Tarmac should not require a PAT for the supported GitHub.com organization-runner
path. Enterprise runner accounts are the exception: GitHub's enterprise runner
REST endpoints do not accept GitHub App installation tokens, so Tarmac stores an
enterprise access token in Keychain and uses that token for enterprise-scoped
runner APIs.

## Enterprise runner auth

Enterprise runner accounts use the account path
`/enterprises/{enterprise}/actions/...`.

Required local configuration:

- enterprise slug
- enterprise runner scale set ID
- runner labels
- access token stored in Keychain

The access token must be a token type accepted by GitHub's enterprise runner
endpoints. GitHub documents OAuth app tokens and classic personal access tokens
with `manage_runners:enterprise` for enterprise self-hosted runner APIs, and the
same docs state that GitHub App user tokens, GitHub App installation tokens, and
fine-grained PATs do not work for those enterprise endpoints.

Enterprise accounts therefore skip:

- GitHub App ID
- GitHub App installation ID
- GitHub App private key
- `/installation/repositories` setup checks

## Runner registration model

Use JIT runner config as the default registration path:

- runner name: stable Tarmac-owned prefix plus job/lease identity
- runner group: configured runner group ID, defaulting to the org default only
  when the user has not selected a group
- labels: configured labels, including `self-hosted`, `macOS`, and `ARM64`
- work folder: `_work`

Registration tokens are fallback-only. They are useful if JIT config is
temporarily unavailable for a supported GitHub.com organization, but they make
ownership and cleanup less explicit. Any fallback should still create a lease
record before the VM starts and should keep the Tarmac-owned runner name prefix.

## Runner groups and routing

Runner groups are the supported visibility boundary. Tarmac should validate that:

- the configured runner group exists in the organization
- the app can read group metadata with the installation token
- the group's repository visibility allows the repositories the user expects
- configured labels match the workflow `runs-on` contract

The JIT runner config is generated against the runner group the scale set
belongs to. Tarmac reads `runnerScaleSet.runnerGroupId` from the polling-session
response and passes it to `generate-jitconfig`, falling back to the default
group (1) only when GitHub does not report one. There is no manual group-ID
field to configure.

Repository include/exclude filters in Tarmac should remain a local dispatch
guard. They are not a replacement for GitHub runner group visibility, because
GitHub can still route jobs according to its own runner group and label rules.

## Scale-set polling boundary

The current code uses scale-set session paths shaped like
`/{account_type}/{account}/actions/runners/{scale_set_id}/sessions`. GitHub
documents runner scale sets as an ARC concept, but these session endpoints are
not part of the public REST self-hosted runner endpoint set that the standard
docs expose.

For the first version, treat scale-set polling as a GitHub.com integration point
for organization and Enterprise Cloud enterprise accounts:

- gate it behind an explicit configured scale set ID
- fail setup checks clearly when session creation returns `404`, `403`, or `410`
- do not claim GitHub Enterprise Server support for the scale-set session path
- keep the JIT runner config path separate from scale-set session lifecycle

When scale-set sessions are unavailable, Tarmac can poll queued workflow jobs
through the public Actions workflow APIs for explicitly included repositories.
That fallback still registers ephemeral JIT runners and relies on normal GitHub
runner matching; repository polling is opt-in so Tarmac does not need broad
organization repository discovery.

## Creating the scale set

GitHub has no web UI to create a runner scale set; scale sets are an ARC
concept created through the same Actions-service surface as the session
endpoints. Asking users to "create a runner scale set on GitHub" is therefore
not actionable — the web UI only creates runner *groups*, which do not yield a
scale-set ID.

Tarmac creates the scale set itself. The account-setup "Create / Find Scale
Set" action:

- lists existing scale sets with `GET /{account_type}/{account}/actions/runner-scale-sets`
- reuses the one whose name matches the configured scale-set name (default
  `tarmac-macos`), or creates it with
  `POST /{account_type}/{account}/actions/runner-scale-sets`
- writes the returned numeric `id` into the account's scale-set field

Both endpoints use the same camelCase Actions-service JSON shape that the
polling-session response already decodes (`RunnerScaleSet`), and the create
request defaults the scale set to the default runner group (`1`), ephemeral
runners, and no auto-update. Because the create action is name-keyed and
list-then-create, re-running it reconciles a missing scale set: if the prior
one is gone, listing no longer finds it and a fresh one is created.

This works identically for organization and enterprise accounts (only the
`{account_type}/{account}` prefix differs). The exact request schema for these
non-public endpoints may need adjustment if GitHub changes them; the fallback
remains the registration-token / normal-matching path above.

## Open decisions

- Enterprise-owned app control-plane support: whether Tarmac should install the
  app into selected organizations with the enterprise `Enterprise organization
  installations` permission, instead of asking users to install it on each org.
- GitHub Enterprise Server support: minimum GHES version, API host configuration,
  runner binary download host, JIT endpoint availability, and auth type.
- Fine-grained enterprise tokens: whether GitHub later adds enterprise runner
  support for them, and how Tarmac should label that token type if it becomes
  available.

## References

- GitHub REST docs: self-hosted runner endpoints for organizations and
  repositories: <https://docs.github.com/en/rest/actions/self-hosted-runners>
- GitHub REST docs: self-hosted runner groups:
  <https://docs.github.com/en/rest/actions/self-hosted-runner-groups>
- GitHub REST docs: GitHub App endpoint permissions:
  <https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps>
- GitHub REST docs: organization self-hosted runner policies:
  <https://docs.github.com/en/rest/actions/permissions>
- GitHub Actions docs: runner scale sets:
  <https://docs.github.com/en/actions/concepts/runners/runner-scale-sets>
- GitHub Enterprise Cloud REST docs: self-hosted runners:
  <https://docs.github.com/en/enterprise-cloud@latest/rest/actions/self-hosted-runners>
- GitHub Enterprise Cloud docs: installing a GitHub App on an enterprise:
  <https://docs.github.com/en/enterprise-cloud@latest/apps/using-github-apps/installing-a-github-app-on-your-enterprise>
- GitHub Enterprise Server REST docs: self-hosted runners:
  <https://docs.github.com/en/enterprise-server@3.21/rest/actions/self-hosted-runners>
