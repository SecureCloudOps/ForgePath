.PHONY: validate-foundation validate-policy validate-secure-fastapi validate-security

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
