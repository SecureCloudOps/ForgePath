.PHONY: build-trusted-artifact test-trusted-artifact validate-foundation \
	validate-gitops-runtime validate-gitops-static validate-policy validate-secure-fastapi \
	validate-security validate-trusted-artifact

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

validate-security: validate-policy
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
