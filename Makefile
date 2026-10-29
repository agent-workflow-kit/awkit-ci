# Local checks for awkit-ci. Tools run through uvx at pinned versions; CI runs the
# same tools via .github/workflows/docs-ci.yml (see self-ci.yml).

ACTIONLINT      := uvx --from actionlint-py==1.7.12.25 --with shellcheck-py==0.11.0.1 actionlint
ZIZMOR          := uvx zizmor==1.31.1
PYMARKDOWN      := uvx --from pymarkdownlnt==0.9.41 pymarkdown
SHELLCHECK      := uvx --from shellcheck-py==0.11.0.1 shellcheck
CHECK_JSONSCHEMA := uvx --from check-jsonschema==0.38.2 check-jsonschema

TEMPLATE_WORKFLOWS := templates/ci.yml templates/pr-title.yml templates/scorecard.yml templates/awkit-docs/ci.yml
DEPENDABOT_FILES   := .github/dependabot.yml templates/dependabot.yml templates/awkit-docs/dependabot.yml
ZIZMOR_CONFIG      := .github/zizmor.yml

.PHONY: verify actionlint zizmor mdlint shellcheck schemas

verify: actionlint zizmor mdlint shellcheck schemas

actionlint:
	$(ACTIONLINT) -color
	$(ACTIONLINT) -color $(TEMPLATE_WORKFLOWS)

zizmor:
	$(ZIZMOR) --config $(ZIZMOR_CONFIG) . $(TEMPLATE_WORKFLOWS)

mdlint:
	$(PYMARKDOWN) --config .pymarkdown.json scan -r .

shellcheck:
	$(SHELLCHECK) scripts/pr-merge

schemas:
	$(CHECK_JSONSCHEMA) --builtin-schema vendor.github-workflows .github/workflows/*.yml $(TEMPLATE_WORKFLOWS)
	$(CHECK_JSONSCHEMA) --builtin-schema vendor.dependabot $(DEPENDABOT_FILES)
