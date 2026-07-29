# Policy Exception Register

The authoritative list of Kyverno policy exemptions for the demo fleet.

This repository exists so that **granting an exemption is a pull request** —
reviewed by the security team, attributable to a person, tied to a ticket, and
revocable with `git revert`. It is deliberately separate from the platform
repository ([nirmata/demo-gitops](https://github.com/nirmata/demo-gitops)),
because the people who approve an exemption from a security control are not
necessarily the people who approve a change to cluster configuration.

Argo CD syncs this repository into the `policy-exceptions` namespace of every
workload cluster. Kyverno is configured with
`--exceptionNamespace=policy-exceptions`, so a `PolicyException` is only honoured
if it lives there — and that namespace is owned by Argo CD with `prune` and
`selfHeal` enabled. There is no `kubectl apply` path to an exemption.

## How it works

```
requests/                  every exception anyone has written, granted or not
kustomization.yaml         the ones that are actually in force
namespace.yaml             the policy-exceptions namespace itself
```

A manifest sitting in `requests/` does nothing. It takes effect only when it is
listed in `kustomization.yaml`:

```yaml
resources:
  - namespace.yaml
  # - requests/legacy-billing-host-path.yaml     <- not in force
  - requests/node-exporter-host-access.yaml      #  <- in force
```

That one-line diff is the whole approval. It is what a reviewer looks at, and it
is what `git log` records.

## Requesting an exception

### With the form

[**File an exception request**](../../issues/new?template=exception-request.yml).
It asks for the workload, its namespace, the policies it fails, a ticket, an
expiry and a justification — then a workflow renders the `PolicyException` and
opens a pull request carrying it.

You need neither Kyverno knowledge nor write access here. What the form cannot do
is grant anything: it opens a pull request and stops. `CODEOWNERS` still routes
the review to the security team, merging is still the approval, and `git log`
still records who did it.

That is also why the form has no field for a scope expression. `matchConditions`
are rendered from a fixed template around a validated namespace and workload
label, so **no request can ask for anything wider than one workload** — there is
no way to submit `expression: true`, to exempt a whole namespace, or to name a
policy that does not exist. The reviewer reads a diff whose shape is already
guaranteed; what is left to judge is whether the exemption is *warranted*, which
is the part that actually needs a person.

The generated manifest records `requested-by`, not `approved-by`. Filing a
request is not approving it.

The form asks **how long** you need it for rather than for a date — a question a
requester can actually answer. The renderer turns it into an absolute date,
carried two ways:

```yaml
metadata:
  labels:
    cleanup.kyverno.io/ttl: "2026-10-27"     # Kyverno's own expiry label
  annotations:
    demo.nirmata.io/expires: "2026-10-27"    # what the register lists
```

Absolute rather than a `90d` duration on purpose: Kyverno counts a relative TTL
from when it *observed* the label, so anything that recreates the object — a
resync, a cluster rebuild, Argo CD self-healing it — silently restarts the clock.
A date cannot be restarted.

> **What the TTL label does and does not do here.** Kyverno's cleanup controller
> deletes a resource whose TTL has elapsed, and it does work: given `delete`
> permission on `policyexceptions` it removed one on schedule in this demo. But
> Argo CD owns this namespace with `selfHeal: true` and recreates the exemption
> within seconds — measured at a delete-and-recreate every two minutes,
> indefinitely, while the Application still reported `Synced/Healthy`. In-cluster
> expiry cannot win against a GitOps controller whose source of truth still lists
> the exception.
>
> So the cleanup controller is deliberately **not** granted that permission, and
> the label is here as a machine-readable deadline rather than as the enforcement.
> Under GitOps expiry has to act on the register: the exemption leaves the cluster
> when it leaves `kustomization.yaml`. Automating that — a scheduled job that
> opens a revocation pull request once the date has passed — keeps expiry the same
> kind of event as everything else here, a reviewable commit.

<details>
<summary>What the automation needs, if you run your own copy</summary>

Two repository settings, neither of which a script can set for you:

- **Settings → General → Features → Issues** — enabled.
- **Settings → Actions → General → Workflow permissions** — *Allow GitHub Actions
  to create and approve pull requests*. **Off by default** for repositories owned
  by a personal account; without it the workflow cannot open the pull request.

Forks are awkward here (Actions need enabling on first visit, and Issues on forks
are inconsistent). If you are standing up your own register, prefer **Use this
template** over **Fork**.

Pull requests opened with `GITHUB_TOKEN` do not trigger other workflows, so
validation checks added later will not run on them without a GitHub App token or
a draft → ready-for-review step.

</details>

### By hand

The form is a convenience; the repository is the interface.

1. Add a `PolicyException` manifest under `requests/`. Name it for the workload,
   not the policy.
2. Scope it to the narrowest thing that works — a single workload, via
   `matchConditions`. Never a whole namespace, never a whole policy.
3. List only the policies the workload genuinely cannot satisfy in `policyRefs`.
4. Fill in the annotations: ticket, approver, expiry, and a justification a
   stranger can evaluate six months from now.
5. Open a pull request that also uncomments the file in `kustomization.yaml`.

`CODEOWNERS` routes review to the security team.

### Anatomy of a good exception

```yaml
apiVersion: policies.kyverno.io/v1
kind: PolicyException
metadata:
  name: legacy-billing-host-path
  namespace: policy-exceptions
  annotations:
    demo.nirmata.io/ticket: COMPLIANCE-1421
    demo.nirmata.io/approved-by: platform-security
    demo.nirmata.io/expires: "2026-12-31"
    demo.nirmata.io/justification: >-
      Why this cannot be fixed instead, and when it will be.
spec:
  policyRefs:                     # exactly the policies it cannot satisfy
    - kind: ValidatingPolicy
      name: disallow-host-path
  matchConditions:                # exactly one workload
    - name: legacy-billing-only
      expression: >-
        object.metadata.namespace == 'legacy' &&
        'app' in object.metadata.labels &&
        object.metadata.labels['app'] == 'legacy-billing'
```

## Auditing what is in force

An exception does not hide a violation, it accounts for it. Kyverno reports the
result as `skip` rather than `fail`, and names the exception that allowed it:

```sh
kubectl -n legacy get policyreports.wgpolicyk8s.io -o yaml | grep -A4 'result: skip'
```

```yaml
- result: skip
  policy: disallow-host-path
  properties:
    exceptions: legacy-billing-host-path
```

To see everything currently in force:

```sh
kubectl get policyexceptions.policies.kyverno.io -A
```

> Spell out the group. The short name `polex` resolves to the *legacy*
> `kyverno.io` PolicyException CRD, which this register never uses, so it reports
> `No resources found` even when exemptions are active.

## Revoking

Comment the file out of `kustomization.yaml`, or `git revert` the commit that
granted it. Argo CD prunes the `PolicyException`, and the workload is held to the
full policy set again at its next admission.

---

Part of the [nirmata/demo-gitops](https://github.com/nirmata/demo-gitops) demo.
