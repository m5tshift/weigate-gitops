.PHONY: lint validate render template alerts ddl dashboards policy test-policy precommit

# CRD schemas for kubeconform, pinned to a commit of the datreeio catalog.
CRD_CATALOG_SHA := 3e8a8916ca1b7af6464606c2c2f5869dbafa9653
CRD_SCHEMAS := https://raw.githubusercontent.com/datreeio/CRDs-catalog/$(CRD_CATALOG_SHA)/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

lint:
	yamllint --strict .

# Manifests in apps/ and platform/; values files are not manifests.
validate:
	@files=$$(find apps platform -type f \( -name '*.yaml' -o -name '*.yml' \) ! -name 'values*.yaml' ! -name 'values*.yml' 2>/dev/null); \
	if [ -z "$$files" ]; then echo "validate: no manifests"; exit 0; fi; \
	echo "$$files" | xargs kubeconform -strict -summary -schema-location default -schema-location '$(CRD_SCHEMAS)'

# Istio and observability charts, platform/istio/mesh and platform/observability/config rendered with the values
# of this repository (hack/render.sh).
render:
	CRD_SCHEMAS='$(CRD_SCHEMAS)' hack/render.sh

# Charts of services/ from a checkout of weigate rendered with the stand values (hack/template.sh).
WEIGATE_DIR ?= ../weigate
template:
	WEIGATE_DIR=$(WEIGATE_DIR) hack/template.sh

# vmalert -dryRun of the rules of platform/observability/vmalert (hack/alerts.sh).
alerts:
	hack/alerts.sh

# DDL of platform/clickhouse/full on ClickHouse in a container (hack/ddl.sh).
ddl:
	hack/ddl.sh

# JSON and metric names of the Grafana dashboards against the code of weigate (hack/dashboards.sh).
dashboards:
	WEIGATE_DIR=$(WEIGATE_DIR) hack/dashboards.sh

policy:
	hack/policy.sh

test-policy:
	hack/policy_test.sh

precommit:
	pre-commit run --all-files
