SWIFT := swift

build:
	$(SWIFT) build

test:
	$(SWIFT) run eureka-tests

run:
	$(SWIFT) run eureka

release:
	$(SWIFT) build -c release

app: release
	Scripts/build-app.sh

install: app
	rm -rf ~/Applications/Eureka.app
	ditto dist/Eureka.app ~/Applications/Eureka.app
	@echo "已安装到 ~/Applications/Eureka.app"

demo:
	Scripts/demo-island.sh

clean:
	rm -rf .build dist

.PHONY: build test run release app install demo clean
