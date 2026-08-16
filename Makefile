.PHONY: build check stress package clean

build:
	./scripts/build.sh

check:
	./scripts/check.sh

stress:
	./tests/test_release_stress.sh

package:
	./scripts/package.sh

clean:
	rm -rf agent/build dist
