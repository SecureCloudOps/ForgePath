.PHONY: validate-foundation validate-secure-fastapi

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
