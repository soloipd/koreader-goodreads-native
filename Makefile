.PHONY: build check package experiment-background-probe clean

build:
	./scripts/build.sh

check:
	./scripts/check.sh

package:
	./scripts/package.sh

experiment-background-probe:
	./experiments/background-annotation-sync/build.sh

clean:
	rm -rf agent/build dist
