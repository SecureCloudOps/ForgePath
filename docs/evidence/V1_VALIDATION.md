# ForgePath v1 validation evidence

ForgePath v1 completed its repository-defined release gate on 2026-08-10 from
commit `c37291efaa31a928c28fcf7d44ef1067139fc4ac`:

```sh
make validate-v1
```

The gate completed successfully with the following non-sensitive terminal
evidence:

```text
[forgepath-gitops-runtime] PASS source resolution: Helm at c37291efaa31a928c28fcf7d44ef1067139fc4ac
[forgepath-gitops-runtime] PASS initial state: Synced, Healthy, Deployment, Pod, Service, ServiceAccount, NetworkPolicy
[forgepath-gitops-runtime] PASS trusted runtime image: forgepath/secure-fastapi-service@sha256:14eb1fc9a1d8f6a433bd21efe671f92ac7526deccf79f7b5ee583422e4beef81
[forgepath-gitops-runtime] PASS reconciliation: self-heal; Git replicas at 7218d68f1d586f1de83970edee44e91e7e202f7f; create 59d587b203e509a15aad8c348aa27583748db900; prune 93ee257a8c6581e2f1fee830619d8562e76128af
[forgepath-gitops-runtime] PASS containment: unauthorized repository, destination namespace, Secret, and ClusterRole rejected
[forgepath-gitops-runtime] PASS Backstage catalog and TechDocs metadata: secure-fastapi-service
[forgepath-gitops-runtime] PASS Backstage workload visibility: Deployment and ready Pod
[forgepath-gitops-runtime] PASS Backstage Argo CD visibility: Application Synced and Healthy
[forgepath-gitops-runtime] PASS read-only identity: get/list/watch only; Secrets, delete, exec, mutation, sync, and credentials denied
[forgepath-gitops-runtime] cleanup passed: target cluster and temporary runtime Git data removed
[forgepath-kyverno-runtime] PASS compliant secure-fastapi-service admitted by the Kubernetes API
[forgepath-kyverno-runtime] PASS privileged, root, latest, resources, hostNetwork, and hostPID fixtures rejected
[forgepath-kyverno-runtime] PASS admission enforcement remained active after Kyverno restart
[forgepath-kyverno-runtime] cleanup passed: disposable cluster and temporary runtime artifacts removed
ForgePath v1 end-to-end validation passed.
```

The runtime harnesses used Kind `v0.32.0`, Kubernetes `v1.32.11`, Argo CD
`v3.3.8`, and Kyverno `v1.18.2`. They created and deleted only the disposable
clusters `forgepath-gitops` and `forgepath-kyverno`, restored the caller's
original Kubernetes context, and retained no runtime credentials or cluster
resources.

The trusted runtime image digest above is bound to the locally verified OCI
archive, Trivy report, SPDX SBOM, metadata, and ephemeral Cosign signature
produced by the same gate.
