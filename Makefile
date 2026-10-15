.PHONY: check
check:
	node fleet/bin/check.mjs
	bash Tests/release-artifacts.sh
	for script in fleet/guest/setup fleet/guest/podman fleet/deploy/package fleet/deploy/install-host fleet/deploy/prepare-guest fleet/deploy/tls-init; do bash -n "$$script" || exit; done
	python3 -B -m unittest discover -s fleet/test -p '*_test.py'
	python3 -c "import ast,pathlib; [ast.parse(pathlib.Path(p).read_text(), filename=p) for p in ['fleet/guest/supervise','fleet/guest/export','fleet/guest/input']]"
