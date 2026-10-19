SWIFT := swift

build:
	$(SWIFT) build

test:
	# The answer-hook end-to-end test runs eureka-ask directly; it is not a dependency of eureka-tests,
	# so build it separately first
	$(SWIFT) build --product eureka-ask
	$(SWIFT) run eureka-tests

run:
	$(SWIFT) run eureka

release:
	$(SWIFT) build -c release

app:
	Scripts/build-app.sh

package-release:
	Scripts/package-release.sh

install: app
	rm -rf /Applications/Eureka.app ~/Applications/Eureka.app \
	       /Applications/lulu-lumei-dock.app ~/Applications/lulu-lumei-dock.app
	ditto dist/lulu-lumei-dock.app /Applications/lulu-lumei-dock.app
	@echo "已安装到 /Applications/lulu-lumei-dock.app"

demo:
	Scripts/demo-island.sh

pricing-catalog:
	Scripts/update-pricing-catalog.sh

lint-comments:
	Scripts/check-comment-language.py

clean:
	rm -rf .build dist

.PHONY: build test run release app package-release install demo pricing-catalog lint-comments clean
