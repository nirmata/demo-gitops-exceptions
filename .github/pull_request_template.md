## Exception request

**Workload:** <!-- namespace/name, e.g. legacy/legacy-billing -->
**Ticket:** <!-- COMPLIANCE-nnnn -->
**Expires:** <!-- YYYY-MM-DD; exceptions without an end date never get removed -->

### Which policies cannot be satisfied, and why

<!-- One line per policy in policyRefs. "It doesn't work otherwise" is not a
     reason - say what the workload does that the policy forbids. -->

### Why the workload cannot be fixed instead

<!-- The default answer to a policy violation is to fix the workload. Explain
     what makes that impractical here, and what would have to change for this
     exception to be withdrawn. -->

---

### Reviewer checklist

- [ ] `policyRefs` lists **only** the policies this workload genuinely fails —
      verified against the PolicyReport, not assumed
- [ ] `matchConditions` scopes the exemption to **one workload**, not a
      namespace and not a label anyone can set on themselves
- [ ] `expires` is set, and is soon enough that someone will look again
- [ ] `justification` explains the constraint, not just the symptom
- [ ] The file is uncommented in `kustomization.yaml` — otherwise this PR
      changes nothing
- [ ] A narrower alternative (fixing the workload, a sidecar, a different
      volume type) has been considered and ruled out
