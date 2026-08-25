# Phase 2 progressive-delivery evidence

The disposable progressive-delivery proof passed on 2026-08-23 using
replica-weighted Argo Rollouts delivery and the Prometheus SLO signals from v2.

- Clean source SHA: `2ff10f069979d9c42d3ff5a3e39b8f1be6e90612`
- Trusted artifact: `forgepath/secure-fastapi-service@sha256:d971dc0d119a17e9b361906b67eb0fbada2cac6d197ec338620ecfd7e1eeba2c`
- Digest-promotion SHA: `f71b8579a3bc9c6b8231e29be33afa8587f2d09a`
- Defective-v2 promotion SHA: `b435be6e27ce4bcac89bcbe9c164a7ee1ebbf3f9`
- Git recovery SHA: `27994e52fe58c69d61ba7ea25ba92ddd5a3460c4`

At the 5% stage, Prometheus observed 286.04 canary HTTP 503 responses over the
one-minute increase window, a 49.686x availability burn rate, and a firing
`ForgePathSLOFastBurn` alert. AnalysisRun
`secure-fastapi-service-secure-fastapi-service-d78757bc4-2-1` then failed its
first measurement at 49.462x because one failure exceeded `failureLimit: 0`.
The Rollout aborted without advancing to 25%, and the stable Service retained
v1 ReplicaSet `f9d9d4954` with 19 ready stable endpoints.

The local Git revert reconciled Argo CD to `Synced/Healthy` at the recovery SHA.
The final Rollout was `Healthy` with 20/20 ready replicas on the stable hash.
The disposable Kind cluster `forgepath-progressive-delivery` was deleted and
the original Kubernetes context was restored.

The complete non-sensitive evidence bundle is retained locally at
`.forgepath/progressive-delivery-evidence/20260823T170017Z/`. Reproduce it only
with explicit approval for disposable-cluster mutation:

```sh
make validate-progressive-delivery-runtime
```
