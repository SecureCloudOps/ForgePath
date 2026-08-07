# ForgePath Kubernetes policy

`kubernetes.rego` is the centralized ForgePath policy for Kubernetes workloads.
It is evaluated with Conftest in combined-input mode so rules can reason across
the complete Helm-rendered resource set, including the requirement for a
default-deny NetworkPolicy.

Run the policy gate from the repository root:

```sh
make validate-policy
```

The validation renders the `secure-fastapi-service` Helm chart before testing it.
Source templates are not treated as policy evidence.
