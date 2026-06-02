# Runner Label Naming

## Context

The ARC bundle currently deploys separate runner scale sets for each GitHub organization and cluster architecture.

Current active labels are organization-specific:

| Organization | Cluster | Architecture | Runner label |
| --- | --- | --- | --- |
| EduIDE | stud | AMD64 | `arc-buildkit-eduide-stud-amd64` |
| EduIDE | parma | ARM64 | `arc-buildkit-eduide-parma-arm64` |
| ls1intum | stud | AMD64 | `arc-buildkit-ls1intum-stud-amd64` |
| ls1intum | parma | ARM64 | `arc-buildkit-ls1intum-parma-arm64` |

This naming is explicit and avoids Kubernetes resource collisions, but it means reusable workflows need organization-specific runner labels.

## Important Constraint

In the upstream `gha-runner-scale-set` chart, `runnerScaleSetName` is both:

- the runner scale set name/label advertised to GitHub Actions, and
- part of the Kubernetes resource names rendered by the chart.

Because EduIDE and ls1intum scale sets are installed into the same `arc-runners` namespace, they cannot currently share the same `runnerScaleSetName`. For example, setting both organizations to `arc-buildkit-stud-amd64` would render duplicate resources such as:

- `AutoscalingRunnerSet/arc-buildkit-stud-amd64`
- `Role/arc-buildkit-stud-amd64-gha-rs-manager`
- `RoleBinding/arc-buildkit-stud-amd64-gha-rs-manager`

That would fail at install or upgrade time.

## Options

### Keep Organization-Specific Labels

Keep labels such as `arc-buildkit-eduide-stud-amd64` and `arc-buildkit-ls1intum-stud-amd64`.

This is the current production-safe choice. It is clear in GitHub, Kubernetes, logs, and troubleshooting output. The downside is that workflow routing must know which organization it is targeting.

### Keep Org-Specific Reusable Workflow Defaults

Keep organization-specific runner labels in the cluster and hide them behind organization-specific reusable workflow defaults.

For example, EduIDE can maintain or consume its own fork/copy of the reusable workflow with EduIDE runner labels as the defaults, while ls1intum keeps the ls1intum runner labels as the defaults in its reusable workflow. Downstream repositories then call their organization's reusable workflow without repeating runner label details in every repository.

This is likely the best near-term compromise. The runner labels remain explicit and collision-free, but migrations are still centralized: if AMD64 moves from `theia-prod` to `stud`, or a runner label changes again later, only the organization's central reusable workflow needs to be updated. Every repository using that workflow inherits the new default routing.

### Use Org-Neutral Labels With Separate Namespaces

Split runner scale sets by organization into separate namespaces, for example:

- `arc-runners-eduide`
- `arc-runners-ls1intum`

Then both organizations could advertise the same workflow-facing labels, such as `arc-buildkit-stud-amd64`, because Kubernetes resources would no longer collide.

This is the cleanest path if identical reusable workflow inputs across organizations become a hard requirement.

### Fork or Wrap the ARC Scale Set Chart

Introduce a separate Kubernetes resource name and GitHub-advertised runner scale set name.

This would be conceptually ideal, but it fights the upstream chart design and adds maintenance burden. It should only be considered if separate namespaces are not acceptable.

## Recommendation

Keep the current organization-specific labels until the README installation path is proven stable end to end.

For now, prefer organization-specific reusable workflow defaults over changing the cluster naming model. This keeps Kubernetes and GitHub ARC resources easy to debug while still centralizing runner migrations in one workflow file per organization.

If identical workflow labels across EduIDE and ls1intum become a hard requirement later, prefer splitting the runner scale sets into organization-specific namespaces rather than trying to overload `runnerScaleSetName` inside one namespace.
