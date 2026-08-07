.PHONY: validate-foundation

validate-foundation:
	@shellcheck scripts/validate-foundation.sh
	@./scripts/validate-foundation.sh
