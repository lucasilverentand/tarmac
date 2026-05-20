# GitHub runner API strategy

Tarmac's first version should target GitHub.com organization runners through a
GitHub App installation token. That path matches the current app model: an
organization has a GitHub App ID, installation ID, private key, runner labels,
and an optional runner scale set ID.

This document records the API boundary for the first version. It is intentionally
narrow so implementation issues can point at specific endpoints instead of
reopening the product/API decision.

## Support matrix

| Environment | First-version status | API path |
| --- | --- | --- |
| GitHub.com organization runners | Supported | `https://api.github.com/orgs/{org}/actions/...` with a GitHub App installation token. |
| GitHub Enterprise Cloud organization runners | Supported when the organization uses the same GitHub.com org runner APIs and the app is installed on that org. Enterprise-owned apps still need an organization installation for each runner organization. |
| GitHub Enterprise Cloud enterprise-owned app setup | Supported as an app ownership source. Enterprise installation is optional control-plane setup and does not grant organization runner access. Tarmac runner accounts remain organization entries. |
| GitHub Enterprise Cloud enterprise-level runners | Out of scope for the first version. Enterprise runner endpoints need a separate auth and product decision before Tarmac should depend on them. |
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

Tarmac should not require a PAT for the supported GitHub.com org-runner path. A
PAT fallback should only be introduced for a documented compatibility gap, and
the UI should label it as a less-preferred compatibility mode with the exact
scope it needs.

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

Repository include/exclude filters in Tarmac should remain a local dispatch
guard. They are not a replacement for GitHub runner group visibility, because
GitHub can still route jobs according to its own runner group and label rules.

## Scale-set polling boundary

The current code uses scale-set session paths shaped like
`/orgs/{org}/actions/runners/{scale_set_id}/sessions`. GitHub documents runner
scale sets as an ARC concept, but these session endpoints are not part of the
public REST self-hosted runner endpoint set that the standard docs expose.

For the first version, treat scale-set polling as a GitHub.com org-only
integration point:

- gate it behind an explicit configured scale set ID
- fail setup checks clearly when session creation returns `404`, `403`, or `410`
- do not claim GitHub Enterprise Server support for the scale-set session path
- keep the JIT runner config path separate from scale-set session lifecycle

If this API proves unstable, the fallback strategy is to register ephemeral
JIT runners and rely on normal GitHub runner matching rather than poll
scale-set sessions directly.

## Enterprise decisions

Enterprise-level runner support needs a separate issue before implementation.
The first version should not silently reinterpret enterprise runner requirements
as organization support.

Open decisions:

- GitHub Enterprise Cloud enterprise-level runner support: whether Tarmac should
  manage runners at enterprise scope or require per-organization installations.
- Enterprise-owned app control-plane support: whether Tarmac should install the
  app into selected organizations with the enterprise `Enterprise organization
  installations` permission, instead of asking users to install it on each org.
- GitHub Enterprise Server support: minimum GHES version, API host configuration,
  runner binary download host, JIT endpoint availability, and auth type.
- Enterprise PAT fallback: whether it is acceptable, which scopes are required,
  and how the app stores and labels it.

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
- GitHub Enterprise Cloud docs: installing a GitHub App on an enterprise:
  <https://docs.github.com/en/enterprise-cloud@latest/apps/using-github-apps/installing-a-github-app-on-your-enterprise>
- GitHub Enterprise Server REST docs: self-hosted runners:
  <https://docs.github.com/en/enterprise-server@3.21/rest/actions/self-hosted-runners>
