# SBOM attestation policy, evaluated by
#   cosign verify-attestation --type spdxjson --policy sbom-policy.rego <image>@<digest>
# The input is the attestation's in-toto statement. Before evaluating it, cosign
# has already checked the signature and that the statement's subject is the
# digest being verified.
package signature

import rego.v1

default allow := false

allow if {
	input.predicateType == "https://spdx.dev/Document"
	startswith(input.predicate.spdxVersion, "SPDX-2.")
	syft_generated
	count(input.predicate.packages) > 0
	has_bootc
}

# Produced by the pipeline's syft scan.
syft_generated if {
	some creator in input.predicate.creationInfo.creators
	startswith(creator, "Tool: syft-")
}

# The SBOM covers the OS packages from the RPM database, not just loose files.
has_bootc if {
	some pkg in input.predicate.packages
	pkg.name == "bootc"
}
