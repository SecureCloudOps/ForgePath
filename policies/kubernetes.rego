package main

# Convert Conftest's combined input into a common set of Kubernetes documents.
documents contains document if {
	some entry in input
	contents := entry.contents
	not is_array(contents)
	object.get(contents, "kind", "") != "List"
	document := contents
}

documents contains document if {
	some entry in input
	contents := entry.contents
	is_array(contents)
	some item in contents
	object.get(item, "kind", "") != "List"
	document := item
}

documents contains document if {
	some entry in input
	contents := entry.contents
	not is_array(contents)
	object.get(contents, "kind", "") == "List"
	some item in object.get(contents, "items", [])
	document := item
}

workloads contains workload if {
	some document in documents
	document.kind in {"Deployment", "StatefulSet", "DaemonSet", "Job", "Rollout"}
	workload := {
		"kind": document.kind,
		"name": object.get(document.metadata, "name", "<unnamed>"),
		"metadata": object.get(document, "metadata", {}),
		"pod_metadata": object.get(document.spec.template, "metadata", {}),
		"pod_spec": document.spec.template.spec,
	}
}

workloads contains workload if {
	some document in documents
	document.kind == "CronJob"
	workload := {
		"kind": document.kind,
		"name": object.get(document.metadata, "name", "<unnamed>"),
		"metadata": object.get(document, "metadata", {}),
		"pod_metadata": object.get(document.spec.jobTemplate.spec.template, "metadata", {}),
		"pod_spec": document.spec.jobTemplate.spec.template.spec,
	}
}

workloads contains workload if {
	some document in documents
	document.kind == "Pod"
	workload := {
		"kind": document.kind,
		"name": object.get(document.metadata, "name", "<unnamed>"),
		"metadata": object.get(document, "metadata", {}),
		"pod_metadata": object.get(document, "metadata", {}),
		"pod_spec": document.spec,
	}
}

required_workload_labels := {
	"forgepath.dev/owner",
	"forgepath.dev/system",
	"forgepath.dev/environment",
	"forgepath.dev/data-classification",
}

approved_environments := {"local", "development", "staging", "production"}
approved_data_classifications := {"public", "internal", "confidential", "restricted"}
approved_support_tiers := {"1", "2", "3", "4"}

metadata_has_required_labels(metadata) if {
	labels := object.get(metadata, "labels", {})
	every label in required_workload_labels {
		value := object.get(labels, label, "")
		is_string(value)
		value != ""
	}
}

metadata_values_are_valid(metadata) if {
	labels := object.get(metadata, "labels", {})
	object.get(labels, "forgepath.dev/environment", "") in approved_environments
	object.get(labels, "forgepath.dev/data-classification", "") in approved_data_classifications
	support_tier := object.get(labels, "forgepath.dev/support-tier", "1")
	support_tier in approved_support_tiers
}

workload_containers contains pair if {
	some workload in workloads
	some container in object.get(workload.pod_spec, "containers", [])
	pair := {"workload": workload, "container": container}
}

workload_containers contains pair if {
	some workload in workloads
	some container in object.get(workload.pod_spec, "initContainers", [])
	pair := {"workload": workload, "container": container}
}

workload_containers contains pair if {
	some workload in workloads
	some container in object.get(workload.pod_spec, "ephemeralContainers", [])
	pair := {"workload": workload, "container": container}
}

container_runs_as_non_root(pod_spec, container) if {
	container_security := object.get(container, "securityContext", {})
	pod_security := object.get(pod_spec, "securityContext", {})
	object.get(
		container_security,
		"runAsNonRoot",
		object.get(pod_security, "runAsNonRoot", false),
	) == true
	object.get(
		container_security,
		"runAsUser",
		object.get(pod_security, "runAsUser", -1),
	) != 0
}

container_drops_all_capabilities(container) if {
	security := object.get(container, "securityContext", {})
	capabilities := object.get(security, "capabilities", {})
	"ALL" in object.get(capabilities, "drop", [])
}

container_has_resources(container) if {
	resources := object.get(container, "resources", {})
	requests := object.get(resources, "requests", {})
	limits := object.get(resources, "limits", {})
	object.get(requests, "cpu", null) != null
	object.get(requests, "memory", null) != null
	object.get(limits, "cpu", null) != null
	object.get(limits, "memory", null) != null
}

image_is_mutable(image) if {
	regex.match(`(?i)(^|:)(latest|stable|main|master)$`, image)
}

image_uses_approved_registry(image) if {
	regex.match(`^ghcr\.io/securecloudops/[^@]+@sha256:[a-f0-9]{64}$`, image)
}

image_is_digest_only(image) if {
	regex.match(`^[^/@]+(:[0-9]+)?(/[^:@]+)+@sha256:[a-f0-9]{64}$`, image)
}

image_is_mutable(image) if {
	not contains(image, "@sha256:")
	not regex.match(`:[^/]+$`, image)
}

default_deny_network_policy_exists if {
	some document in documents
	document.kind == "NetworkPolicy"
	count(object.get(document.spec, "podSelector", {})) == 0
	policy_types := object.get(document.spec, "policyTypes", [])
	"Ingress" in policy_types
	"Egress" in policy_types
	count(object.get(document.spec, "ingress", [])) == 0
	count(object.get(document.spec, "egress", [])) == 0
}

resource_quota_exists if {
	some document in documents
	document.kind == "ResourceQuota"
	hard := object.get(document.spec, "hard", {})
	every resource in {
		"requests.cpu", "requests.memory", "limits.cpu", "limits.memory",
		"pods", "services", "configmaps",
	} {
		object.get(hard, resource, null) != null
	}
}

limit_range_exists if {
	some document in documents
	document.kind == "LimitRange"
	some limit in object.get(document.spec, "limits", [])
	object.get(limit, "type", "") == "Container"
	every field in {"default", "defaultRequest", "min", "max", "maxLimitRequestRatio"} {
		resources := object.get(limit, field, {})
		object.get(resources, "cpu", null) != null
		object.get(resources, "memory", null) != null
	}
}

network_policy_ingress_rules contains ingress if {
	some document in documents
	document.kind == "NetworkPolicy"
	some ingress in object.get(document.spec, "ingress", [])
}

network_policy_egress_rules contains egress if {
	some document in documents
	document.kind == "NetworkPolicy"
	some egress in object.get(document.spec, "egress", [])
}

ingress_rule_is_narrow(ingress) if {
	count(object.get(ingress, "from", [])) == 1
	peer := ingress.from[0]
	count(object.get(object.get(peer, "namespaceSelector", {}), "matchLabels", {})) > 0
	count(object.get(object.get(peer, "podSelector", {}), "matchLabels", {})) > 0
	object.get(ingress, "ports", []) == [{"protocol": "TCP", "port": 8080}]
}

prometheus_ingress_policy_exists if {
	every ingress in network_policy_ingress_rules {
		ingress_rule_is_narrow(ingress)
	}
	some document in documents
	document.kind == "NetworkPolicy"
	some ingress in object.get(document.spec, "ingress", [])
	count(object.get(ingress, "from", [])) == 1
	peer := ingress.from[0]
	object.get(object.get(object.get(peer, "namespaceSelector", {}), "matchLabels", {}), "kubernetes.io/metadata.name", "") == "monitoring"
	object.get(object.get(object.get(peer, "podSelector", {}), "matchLabels", {}), "app.kubernetes.io/name", "") == "prometheus"
	object.get(ingress, "ports", []) == [{"protocol": "TCP", "port": 8080}]
}

dns_egress_policy_exists if {
	count(network_policy_egress_rules) == 1
	some document in documents
	document.kind == "NetworkPolicy"
	count(object.get(document.spec, "podSelector", {})) == 0
	object.get(document.spec, "policyTypes", []) == ["Egress"]
	count(object.get(document.spec, "egress", [])) == 1
	egress := document.spec.egress[0]
	count(object.get(egress, "to", [])) == 1
	peer := egress.to[0]
	object.get(object.get(object.get(peer, "namespaceSelector", {}), "matchLabels", {}), "kubernetes.io/metadata.name", "") == "kube-system"
	object.get(object.get(object.get(peer, "podSelector", {}), "matchLabels", {}), "k8s-app", "") == "kube-dns"
	ports := object.get(egress, "ports", [])
	count(ports) == 2
	{"protocol": "UDP", "port": 53} in ports
	{"protocol": "TCP", "port": 53} in ports
}

deny contains message if {
	some workload in workloads
	not metadata_has_required_labels(workload.metadata)
	message := sprintf(
		"%s/%s: workload metadata must set owner, system, environment, and data-classification labels",
		[workload.kind, workload.name],
	)
}

deny contains message if {
	some workload in workloads
	not metadata_has_required_labels(workload.pod_metadata)
	message := sprintf(
		"%s/%s: pod template metadata must set owner, system, environment, and data-classification labels",
		[workload.kind, workload.name],
	)
}

deny contains message if {
	some workload in workloads
	metadata_has_required_labels(workload.metadata)
	not metadata_values_are_valid(workload.metadata)
	message := sprintf(
		"%s/%s: workload environment, data-classification, or support-tier label is invalid",
		[workload.kind, workload.name],
	)
}

deny contains message if {
	some pair in workload_containers
	image := object.get(pair.container, "image", "")
	not image_uses_approved_registry(image)
	message := sprintf(
		"%s/%s: container %s image %q is not from an approved registry",
		[pair.workload.kind, pair.workload.name, pair.container.name, image],
	)
}

deny contains message if {
	some pair in workload_containers
	image := object.get(pair.container, "image", "")
	not image_is_digest_only(image)
	message := sprintf(
		"%s/%s: container %s image must use a sha256 digest only",
		[pair.workload.kind, pair.workload.name, pair.container.name],
	)
}

deny contains message if {
	some pair in workload_containers
	not container_runs_as_non_root(pair.workload.pod_spec, pair.container)
	message := sprintf(
		"%s/%s: container %s must run as non-root; set runAsNonRoot=true and never use UID 0",
		[pair.workload.kind, pair.workload.name, pair.container.name],
	)
}

deny contains message if {
	some pair in workload_containers
	security := object.get(pair.container, "securityContext", {})
	object.get(security, "allowPrivilegeEscalation", true) != false
	message := sprintf(
		"%s/%s: container %s must set allowPrivilegeEscalation=false",
		[pair.workload.kind, pair.workload.name, pair.container.name],
	)
}

deny contains message if {
	some pair in workload_containers
	not container_drops_all_capabilities(pair.container)
	message := sprintf(
		"%s/%s: container %s must drop all Linux capabilities with capabilities.drop=[\"ALL\"]",
		[pair.workload.kind, pair.workload.name, pair.container.name],
	)
}

deny contains message if {
	some pair in workload_containers
	not container_has_resources(pair.container)
	message := sprintf(
		"%s/%s: container %s must define CPU and memory requests and limits",
		[pair.workload.kind, pair.workload.name, pair.container.name],
	)
}

deny contains message if {
	some pair in workload_containers
	image := object.get(pair.container, "image", "")
	image_is_mutable(image)
	message := sprintf(
		"%s/%s: container %s uses mutable image %q; use an immutable digest or explicit non-mutable version tag",
		[pair.workload.kind, pair.workload.name, pair.container.name, image],
	)
}

deny contains message if {
	some pair in workload_containers
	security := object.get(pair.container, "securityContext", {})
	object.get(security, "privileged", false) == true
	message := sprintf(
		"%s/%s: container %s must not run privileged",
		[pair.workload.kind, pair.workload.name, pair.container.name],
	)
}

deny contains message if {
	some workload in workloads
	object.get(workload.pod_spec, "automountServiceAccountToken", true) != false
	message := sprintf(
		"%s/%s: pod spec must set automountServiceAccountToken=false",
		[workload.kind, workload.name],
	)
}

deny contains message if {
	some document in documents
	document.kind == "ServiceAccount"
	object.get(document, "automountServiceAccountToken", true) != false
	message := sprintf(
		"ServiceAccount/%s: must set automountServiceAccountToken=false",
		[object.get(document.metadata, "name", "<unnamed>")],
	)
}

deny contains message if {
	some workload in workloads
	object.get(workload.pod_spec, "hostNetwork", false) == true
	message := sprintf(
		"%s/%s: hostNetwork is forbidden",
		[workload.kind, workload.name],
	)
}

deny contains message if {
	some workload in workloads
	object.get(workload.pod_spec, "hostPID", false) == true
	message := sprintf(
		"%s/%s: hostPID is forbidden",
		[workload.kind, workload.name],
	)
}

deny contains "Rendered manifests with workloads must include a namespace-wide default-deny NetworkPolicy for both ingress and egress" if {
	count(workloads) > 0
	not default_deny_network_policy_exists
}

deny contains "Rendered manifests with workloads must include a ResourceQuota for CPU, memory, pods, services, and configmaps" if {
	count(workloads) > 0
	not resource_quota_exists
}

deny contains "Rendered manifests with workloads must include a Container LimitRange with CPU and memory defaults, minimums, maximums, and ratios" if {
	count(workloads) > 0
	not limit_range_exists
}

deny contains "Rendered manifests with monitored workloads must restrict Prometheus ingress by namespace, pod label, and TCP port 8080" if {
	count(workloads) > 0
	not prometheus_ingress_policy_exists
}

deny contains "Rendered manifests with workloads must allow egress only to kube-system DNS pods on UDP and TCP port 53" if {
	count(workloads) > 0
	not dns_egress_policy_exists
}
