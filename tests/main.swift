import Foundation

var failures = 0

func expect(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

runInvokingUserTests()
runPushTests()

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("All tests passed")
