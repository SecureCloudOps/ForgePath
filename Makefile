.PHONY: build-trusted-artifact test-trusted-artifact validate-backstage-runtime \
	validate-backstage-static validate-foundation \
	validate-gitops-runtime validate-gitops-static validate-policy validate-secure-fastapi \
	validate-kyverno-runtime validate-kyverno-static validate-security \
	validate-trusted-artifact validate-v1 validate-v1-static

validate-v1: validate-foundation validate-trusted-artifact validate-backstage-runtime \
	validate-kyverno-runtime
	@printf 'ForgePath v1 end-to-end validation passed.\n'

validate-v1-static: validate-foundation validate-security validate-backstage-static \
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
	@if command -v shellcheck >/dev/null; then \
		shellcheck scripts/validate-secure-fastapi.sh; \
	elif command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-secure-fastapi.sh; \
	else \
		echo 'shellcheck is required (install it directly or with mise)' >&2; exit 1; \
	fi
	@./scripts/validate-secure-fastapi.sh

validate-policy:
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-policy.sh; \
		mise exec -- ./scripts/validate-policy.sh; \
	else \
		shellcheck scripts/validate-policy.sh; \
		./scripts/validate-policy.sh; \
	fi

validate-security: validate-policy validate-kyverno-static
	@if command -v mise >/dev/null; then \
		mise exec -- shellcheck scripts/validate-secure-fastapi.sh; \
		mise exec -- ./scripts/validate-secure-fastapi.sh; \
	else \
		shellcheck scripts/validate-secure-fastapi.sh; \
		./scripts/validate-secure-fastapi.sh; \
	fi

build-trusted-artifact: validate-security
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
