# Reviewed Kyverno installation

ForgePath pins Kyverno `v1.18.2` for both runtime admission and static CLI
validation. The reviewed upstream release artifact is:

- URL: `https://github.com/kyverno/kyverno/releases/download/v1.18.2/install.yaml`
- SHA-256: `3dcd43eaf11f0719084217148cd0c82a8fa49faa9b1a783ea5bea2cf84041bda`

The runtime validator verifies that checksum before use and replaces every
version tag in the temporary manifest with its reviewed multi-platform digest:

- `reg.kyverno.io/kyverno/kyverno@sha256:0a540e2ddf74d0d2d3d45f9ef248d7dbc96576accdbcc6a2dd7eaff9fea56504`
- `reg.kyverno.io/kyverno/background-controller@sha256:d62566ce41bd0d4a32bf2cf44b9ebfc02c36374f821f83070890287f62f68671`
- `reg.kyverno.io/kyverno/cleanup-controller@sha256:b0395d29ae332276e6910eb40418be9bc127c068d659f90aa1bcddd6be99ccb4`
- `reg.kyverno.io/kyverno/reports-controller@sha256:f09cf305170014e191b94e1c54f5be73163d8824eefad49349675c4efe43159a`
- `reg.kyverno.io/kyverno/kyvernopre@sha256:cd8cb4a31d25b3992734fb8f24a90ef691c90ce49338c89bea96792160eacb98`

These inputs were reviewed for this disposable local proof. The upstream
manifest installs Kyverno in its dedicated `kyverno` namespace. ForgePath's
policies are validation-only, use `Enforce`, and fail closed; they do not mutate
resources.
