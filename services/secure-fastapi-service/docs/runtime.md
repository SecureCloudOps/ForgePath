# Runtime contract

The container runs as a non-root user with privilege escalation disabled, a
read-only root filesystem, all Linux capabilities dropped, RuntimeDefault
seccomp, resource requests and limits, and health probes. Its service account
does not automount a Kubernetes token. Network access starts from default deny.

Backstage runtime visibility uses a separate identity. That identity may only
`get`, `list`, and `watch` the selected workload objects and the matching Argo
CD Application. It cannot read Secrets, delete Pods, execute commands, mutate
workloads, request service-account tokens, or update/sync the Application.
