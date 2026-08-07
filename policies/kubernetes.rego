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
	document.kind in {"Deployment", "StatefulSet", "DaemonSet", "Job"}
	workload := {
		"kind": document.kind,
		"name": object.get(document.metadata, "name", "<unnamed>"),
		"pod_spec": document.spec.template.spec,
	}
}

workloads contains workload if {
	some document in documents
	document.kind == "CronJob"
	workload := {
		"kind": document.kind,
		"name": object.get(document.metadata, "name", "<unnamed>"),
		"pod_spec": document.spec.jobTemplate.spec.template.spec,
	}
}

workloads contains workload if {
	some document in documents
	document.kind == "Pod"
	workload := {
		"kind": document.kind,
		"name": object.get(document.metadata, "name", "<unnamed>"),
		"pod_spec": document.spec,
	}
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

image_is_mutable(image) if {
	not contains(image, "@sha256:")
	not regex.match(`:[^/]+$`, image)
}

default_deny_network_policy_exists if {
	some document in documents
	document.kind == "NetworkPolicy"
	policy_types := object.get(document.spec, "policyTypes", [])
	"Ingress" in policy_types
	"Egress" in policy_types
	count(object.get(document.spec, "ingress", [])) == 0
	count(object.get(document.spec, "egress", [])) == 0
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

deny contains "Rendered manifests with workloads must include a default-deny NetworkPolicy for both ingress and egress" if {
	count(workloads) > 0
	not default_deny_network_policy_exists
}
