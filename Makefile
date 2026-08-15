.PHONY: build check package clean

build:
	./scripts/build.sh

check:
	./scripts/check.sh

package:
	./scripts/package.sh

clean:
	rm -rf agent/build dist
