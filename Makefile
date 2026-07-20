SWIFT := swift

build:
	$(SWIFT) build

test:
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

clean:
	rm -rf .build dist

.PHONY: build test run release app package-release install demo clean
