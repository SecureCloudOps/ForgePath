# Namespace-isolation validation evidence

The ForgePath namespace-isolation increment was validated on 2026-08-23 and is
frozen. Its scope is Pod Security Admission, aggregate and per-container
resource governance, default-deny networking, DNS-only application egress, and
narrowly scoped application and Prometheus ingress. RBAC exceptions and policy
exception workflows were not added.

## Static evidence

```sh
make validate-namespace-protections-static
```

The combined gate passed with:

- 15/15 Conftest policy cases, including a deliberately weak namespace fixture;
- deterministic Helm rendering of 13 resources;
- strict local-schema validation of ResourceQuota, LimitRange, and three
  NetworkPolicies;
- zero high or critical Trivy misconfigurations in the rendered manifests;
- Argo CD rejection tests for missing restricted PSA metadata and missing
  managed namespace creation; and
- the existing source, chart, dependency, secret, and GitOps security checks.

The Argo CD Application creates only its fixed destination namespace and applies
`restricted:v1.32` enforce, audit, and warn labels through managed namespace
metadata. Its AppProject remains cluster-resource deny-all and adds only the
namespace-scoped ResourceQuota and LimitRange kinds to the existing allowlist.

## Runtime evidence

After explicit approval, the proof ran with Kind v0.32.0 and Kubernetes
v1.32.11 using Kind's built-in NetworkPolicy enforcement:

```sh
make validate-namespace-protections-runtime
```

The runtime sequence proved:

1. the namespace started with `restricted:v1.32` PSA, ResourceQuota,
   LimitRange, and namespace-wide ingress/egress denial before any workload;
2. normal service traffic from the explicitly selected namespace and client pod
   succeeded;
3. Prometheus scraped `/metrics` only through the monitoring namespace,
   Prometheus pod, and TCP 8080 selectors;
4. application DNS resolution succeeded through the kube-system DNS pod rule on
   UDP and TCP port 53;
5. ingress from an unauthorized namespace and pod failed;
6. application egress to an otherwise reachable service failed;
7. a per-container LimitRange violation and an aggregate ResourceQuota violation
   were rejected by API admission; and
8. a privileged Pod was rejected by `restricted:v1.32` Pod Security Admission.

## Isolation and cleanup evidence

The harness refused reuse of a pre-existing target and mutated only the
disposable `forgepath-namespace-boundary` cluster through the exact
`kind-forgepath-namespace-boundary` context. It deleted that cluster and all
temporary manifests at exit, then restored the original context:

```text
arn:aws:eks:us-east-1:767828729088:cluster/cloudsecops-llm-finetuning-dev
```

No existing cluster or unrelated workload was contacted or mutated.
