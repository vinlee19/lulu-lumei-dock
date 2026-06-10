import Foundation

let t = TestRunner()
print("eureka-tests")

smokeTests(t)
taskStoreTests(t)
decoderTests(t)
spoolConsumerTests(t)

t.finish()
