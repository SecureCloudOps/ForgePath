.PHONY: build-trusted-artifact test-trusted-artifact validate-backstage-runtime \
	validate-backstage-static validate-foundation \
	validate-developer-self-service \
	validate-gitops-runtime validate-gitops-static validate-policy validate-secure-fastapi \
	validate-kyverno-runtime validate-kyverno-static validate-observability-online \
	validate-observability-runtime validate-observability-static \
	validate-namespace-protections-runtime validate-namespace-protections-static \
	validate-platform-guardrails-runtime validate-platform-guardrails-static \
	validate-progressive-delivery-runtime validate-progressive-delivery-static validate-security \
	validate-incident-exercise-runtime validate-incident-exercise-static \
	validate-security-online validate-security-static validate-trivy-online \
	validate-trusted-artifact validate-v1 validate-v1-static \
	validate-workload-exceptions-runtime validate-workload-exceptions-static \
	validate-workload-identity-runtime validate-workload-identity-static

validate-v1: validate-foundation validate-trusted-artifact validate-backstage-runtime \
	validate-kyverno-runtime
	@printf 'ForgePath v1 end-to-end validation passed.\n'

validate-v1-static: validate-foundation validate-security-static validate-backstage-static \
	validate-developer-self-service \
	validate-gitops-static
	@printf 'ForgePath v1 static validation passed.\n'

validate-backstage-runtime: validate-backstage-static validate-gitops-runtime
	@printf 'ForgePath Backstage read-only runtime validation passed.\n'

validate-backstage-static:
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-backstage-static.sh; \
		mise exec -- ./scripts/validate-backstage-static.sh; \
	else \
		shellcheck scripts/validate-backstage-static.sh; \
		./scripts/validate-backstage-static.sh; \
	fi

validate-developer-self-service:
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck tests/self-service/test-validation.sh; \
		mise exec -- ./tests/self-service/test-validation.sh; \
	else \
		shellcheck tests/self-service/test-validation.sh; \
		./tests/self-service/test-validation.sh; \
	fi

validate-kyverno-runtime: validate-kyverno-static
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-kyverno-runtime.sh; \
		mise exec -- ./scripts/validate-kyverno-runtime.sh; \
	else \
		shellcheck scripts/validate-kyverno-runtime.sh; \
		./scripts/validate-kyverno-runtime.sh; \
	fi

validate-kyverno-static:
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-kyverno-static.sh; \
		mise exec -- ./scripts/validate-kyverno-static.sh; \
	else \
		shellcheck scripts/validate-kyverno-static.sh; \
		./scripts/validate-kyverno-static.sh; \
	fi

validate-platform-guardrails-static: validate-policy validate-kyverno-static
	@printf 'ForgePath platform-guardrails static validation passed.\n'

validate-platform-guardrails-runtime: validate-trusted-artifact
	@$(MAKE) validate-kyverno-runtime
	@printf 'ForgePath platform-guardrails runtime validation passed.\n'

validate-namespace-protections-static: validate-policy validate-secure-fastapi validate-gitops-static
	@printf 'ForgePath namespace-protections static validation passed.\n'

validate-namespace-protections-runtime: validate-namespace-protections-static
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-namespace-protections-runtime.sh; \
		mise exec -- ./scripts/validate-namespace-protections-runtime.sh; \
	else \
		shellcheck scripts/validate-namespace-protections-runtime.sh; \
		./scripts/validate-namespace-protections-runtime.sh; \
	fi
	@printf 'ForgePath namespace-protections runtime validation passed.\n'

validate-workload-identity-static: validate-secure-fastapi validate-gitops-static
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-workload-identity-static.sh; \
		mise exec -- ./scripts/validate-workload-identity-static.sh; \
	else \
		shellcheck scripts/validate-workload-identity-static.sh; \
		./scripts/validate-workload-identity-static.sh; \
	fi

validate-workload-identity-runtime: validate-workload-identity-static validate-trusted-artifact
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-workload-identity-runtime.sh; \
		mise exec -- ./scripts/validate-workload-identity-runtime.sh; \
	else \
		shellcheck scripts/validate-workload-identity-runtime.sh; \
		./scripts/validate-workload-identity-runtime.sh; \
	fi

validate-workload-exceptions-static: validate-workload-identity-static
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-workload-exceptions-static.sh; \
		mise exec -- ./scripts/validate-workload-exceptions-static.sh; \
	else \
		shellcheck scripts/validate-workload-exceptions-static.sh; \
		./scripts/validate-workload-exceptions-static.sh; \
	fi

validate-workload-exceptions-runtime: validate-workload-exceptions-static
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-workload-exceptions-runtime.sh; \
		mise exec -- ./scripts/validate-workload-exceptions-runtime.sh; \
	else \
		shellcheck scripts/validate-workload-exceptions-runtime.sh; \
		./scripts/validate-workload-exceptions-runtime.sh; \
	fi

validate-gitops-runtime: validate-gitops-static
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-gitops-runtime.sh; \
		mise exec -- ./scripts/validate-gitops-runtime.sh; \
	else \
		shellcheck scripts/validate-gitops-runtime.sh; \
		./scripts/validate-gitops-runtime.sh; \
	fi

validate-gitops-static:
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-gitops-static.sh \
			tests/gitops/test-validation.sh; \
		mise exec -- ./tests/gitops/test-validation.sh; \
	else \
		shellcheck scripts/validate-gitops-static.sh \
			tests/gitops/test-validation.sh; \
		./tests/gitops/test-validation.sh; \
	fi

validate-foundation:
	@if command -v shellcheck >/dev/null; then \
		shellcheck scripts/validate-foundation.sh; \
	elif command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-foundation.sh; \
	else \
		echo 'shellcheck is required (install it directly or with mise)' >&2; exit 1; \
	fi
	@./scripts/validate-foundation.sh

validate-secure-fastapi:
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-secure-fastapi.sh; \
		mise exec -- ./scripts/validate-secure-fastapi.sh; \
	elif command -v shellcheck >/dev/null; then \
		shellcheck scripts/validate-secure-fastapi.sh; \
		./scripts/validate-secure-fastapi.sh; \
	else \
		echo 'mise or shellcheck plus all pinned validation tools are required' >&2; exit 1; \
	fi

validate-observability-static: validate-secure-fastapi
	@printf 'ForgePath observability static validation passed.\n'

validate-progressive-delivery-static: validate-observability-static validate-gitops-static
	@printf 'ForgePath progressive-delivery static validation passed.\n'

validate-progressive-delivery-runtime: validate-progressive-delivery-static
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-progressive-delivery-runtime.sh; \
		mise exec -- ./scripts/validate-progressive-delivery-runtime.sh; \
	else \
		shellcheck scripts/validate-progressive-delivery-runtime.sh; \
		./scripts/validate-progressive-delivery-runtime.sh; \
	fi

validate-incident-exercise-static: validate-progressive-delivery-static
	@if command -v mise >/dev/null; then \
		mise exec -- env PYTHONDONTWRITEBYTECODE=1 python3.12 -m unittest tests/incident/test-postmortem.py; \
		mise exec -- shellcheck scripts/validate-progressive-delivery-runtime.sh; \
	else \
		env PYTHONDONTWRITEBYTECODE=1 python3.12 -m unittest tests/incident/test-postmortem.py; \
		shellcheck scripts/validate-progressive-delivery-runtime.sh; \
	fi
	@printf 'ForgePath incident-exercise static validation passed.\n'

validate-incident-exercise-runtime: validate-incident-exercise-static
	@if command -v mise >/dev/null; then \
		mise exec -- ./scripts/validate-progressive-delivery-runtime.sh --incident-exercise; \
	else \
		./scripts/validate-progressive-delivery-runtime.sh --incident-exercise; \
	fi

validate-trivy-online:
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-trivy-online.sh; \
		mise exec -- ./scripts/validate-trivy-online.sh; \
	else \
		shellcheck scripts/validate-trivy-online.sh; \
		./scripts/validate-trivy-online.sh; \
	fi

validate-observability-online: validate-trivy-online
	@printf 'ForgePath observability online vulnerability validation passed.\n'

validate-observability-runtime: validate-observability-static
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-observability-runtime.sh; \
		mise exec -- ./scripts/validate-observability-runtime.sh; \
	else \
		shellcheck scripts/validate-observability-runtime.sh; \
		./scripts/validate-observability-runtime.sh; \
	fi

validate-policy:
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-policy.sh; \
		mise exec -- ./scripts/validate-policy.sh; \
	else \
		shellcheck scripts/validate-policy.sh; \
		./scripts/validate-policy.sh; \
	fi

validate-security-static: validate-policy validate-kyverno-static validate-secure-fastapi \
	validate-workload-exceptions-static
	@printf 'ForgePath static security validation passed.\n'

validate-security-online: validate-security-static validate-trivy-online
	@printf 'ForgePath online security validation passed.\n'

validate-security: validate-security-online
	@printf 'ForgePath complete static and online security validation passed.\n'

build-trusted-artifact: validate-security-static
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/build-trusted-artifact.sh \
			scripts/validate-trusted-artifact.sh \
			tests/trusted-artifact/test-validation.sh; \
		mise exec -- ./scripts/build-trusted-artifact.sh; \
	else \
		shellcheck scripts/build-trusted-artifact.sh \
			scripts/validate-trusted-artifact.sh \
			tests/trusted-artifact/test-validation.sh; \
		./scripts/build-trusted-artifact.sh; \
	fi

test-trusted-artifact:
	@if command -v mise >/dev/null; then \
		mise exec -- ./tests/trusted-artifact/test-validation.sh; \
	else \
		./tests/trusted-artifact/test-validation.sh; \
	fi

validate-trusted-artifact: build-trusted-artifact test-trusted-artifact
	@printf 'ForgePath trusted artifact workflow validation passed.\n'
