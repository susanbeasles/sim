.PHONY: check
check:
	@tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; $${CC:-cc} -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -I Sources/ProcessSupport/include Sources/ProcessSupport/ProcessSupport.c Tests/ProcessSupport/group-test.c -o "$$tmp/group-test" && "$$tmp/group-test"
	@tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; $${CC:-cc} -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -I Sources/ProcessSupport/include Sources/ProcessSupport/ScopedFiles.c Tests/ProcessSupport/files-test.c -o "$$tmp/files-test" && "$$tmp/files-test"
	python3 -B Tests/audit-safety.py
	node fleet/bin/check.mjs
	bash Tests/release-artifacts.sh
	for script in fleet/guest/setup fleet/guest/podman fleet/deploy/package fleet/deploy/install-host fleet/deploy/prepare-guest fleet/deploy/tls-init; do bash -n "$$script" || exit; done
	python3 -B -m unittest discover -s fleet/test -p '*_test.py'
	python3 -c "import ast,pathlib; [ast.parse(pathlib.Path(p).read_text(), filename=p) for p in ['fleet/guest/supervise','fleet/guest/export','fleet/guest/input']]"
