#!/usr/bin/env bats
# Tests for .github/renovate.json.
#
# `just test-unit` runs the template suite. validate-renovate.yml validates the
# JSON against the Renovate schema on every PR that touches it; the schema
# cannot tell whether a regex matches what we want it to, only that it is
# well-formed. These tests pin the structural choices the renovate config
# encodes so a drive-by edit cannot silently drop a customManager, widen a
# matchStrings pattern, or reintroduce a rule that automerges a major.
#
# Run with: bats tests/template/renovate-config_test.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
CONFIG="${REPO_ROOT}/.github/renovate.json"

setup() {
    [ -f "${CONFIG}" ]
    command -v python3 >/dev/null || skip "python3 is not installed"
}

config() {
    # Load the renovate config as `d` and run the given Python statements.
    python3 -c "import json,sys; d=json.load(open('${CONFIG}')); ${*}"
}

@test "renovate config is valid JSON" {
    run python3 -c "import json; json.load(open('${CONFIG}'))"
    [ "${status}" -eq 0 ] || {
        echo "${output}" >&2
        return 1
    }
}

@test "renovate config defines a customManager that tracks quay.io/fedora-ostree-desktops/* in build example FROM comments" {
    # This is the manager that prevents the example FROM major from drifting
    # when the Containerfile is rebased. Without it, a Fedora major rebase in
    # the Containerfile silently leaves the example pointing at the old major
    # until someone reads the FROM line by hand, and a contributor editing
    # renovate.json cannot tell whether dropping the manager is allowed.
    config_out="$(config "import re; ms=[m for m in d['customManagers'] if m.get('customType')=='regex' and any('build/' in p and '.example' in p for p in m.get('managerFilePatterns',[]))]; print('FOUND' if any('fedora-ostree-desktops' in s for s in ms[0]['matchStrings']) else 'MISSING')")"
    [ "${config_out}" = "FOUND" ]
}

@test "the build example customManager extracts packageName and currentValue" {
    # Renovate needs these names to resolve the dependency and propose a new
    # version. A regex without them parses as valid JSON and survives the
    # schema check but produces no PR.
    config_out="$(config "ms=[m for m in d['customManagers'] if m.get('customType')=='regex' and any('build/' in p and '.example' in p for p in m.get('managerFilePatterns',[]))][0]; print(ms['matchStrings'][0])")"
    [[ "${config_out}" == *"<packageName>"* ]]
    [[ "${config_out}" == *"<currentValue>"* ]]
}

@test "the build example customManager regex matches the FROM line in 60-desktop-swap.sh.example" {
    # The whole point of the manager: bump the major in the example alongside
    # the Containerfile. If the regex stops matching the line, the manager is
    # silently useless.
    example="${REPO_ROOT}/build/60-desktop-swap.sh.example"
    [ -f "${example}" ]
    regex="$(config "ms=[m for m in d['customManagers'] if m.get('customType')=='regex' and any('build/' in p and '.example' in p for p in m.get('managerFilePatterns',[]))][0]; print(ms['matchStrings'][0])")"
    # Renovate's RE2 uses (?<name>...) for named groups; Python's re uses
    # (?P<name>...). Rewrite for local validation only.
    python_regex="$(python3 -c "import re,sys; r=sys.argv[1]; print(re.sub(r'\?<([A-Za-z][A-Za-z0-9_]*)>', r'?P<\1>', r))" "${regex}")"
    run python3 -c "import re,sys; t=open('${example}').read(); r=sys.argv[1]; m=re.search(r, t); sys.exit(0 if m and m.group('packageName')=='quay.io/fedora-ostree-desktops/cosmic-atomic' else 1)" "${python_regex}"
    [ "${status}" -eq 0 ] || {
        echo "regex '${python_regex}' did not match the FROM line in ${example}" >&2
        echo "${output}" >&2
        return 1
    }
}

@test "no packageRule automerges a major update" {
    # A major crossing always waits for a human. Renovate reads packageRules in
    # order and applies the last match, so a single rule that matches
    # matchUpdateTypes: ["major"] with automerge: true would silently let a
    # 44 -> 45 (or any other) jump land without review.
    run config "bad=[r for r in d['packageRules'] if 'major' in r.get('matchUpdateTypes',[]) and r.get('automerge') is True]; print(bad); sys.exit(1 if bad else 0)"
    [ "${status}" -eq 0 ] || {
        echo "packageRules automerging a major: ${output}" >&2
        return 1
    }
}
