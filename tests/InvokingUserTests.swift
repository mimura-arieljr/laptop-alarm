func runInvokingUserTests() {
    testFlagBeatsEnvironment()
    testFallsBackToSudoUser()
    testRootAndEmptyAreRejected()
    testNilWhenNeitherSet()
}

func testFlagBeatsEnvironment() {
    let u = resolveInvokingUser(arguments: ["arm", "--user", "alice"], environment: ["SUDO_USER": "bob"])
    expect(u == "alice", "flag beats environment, got \(String(describing: u))")
}

func testFallsBackToSudoUser() {
    let u = resolveInvokingUser(arguments: ["arm"], environment: ["SUDO_USER": "bob"])
    expect(u == "bob", "falls back to SUDO_USER, got \(String(describing: u))")
}

func testRootAndEmptyAreRejected() {
    expect(resolveInvokingUser(arguments: ["arm", "--user", "root"], environment: ["SUDO_USER": "bob"]) == nil,
           "--user root is rejected without fallback")
    expect(resolveInvokingUser(arguments: ["arm", "--user", ""], environment: ["SUDO_USER": "bob"]) == nil,
           "--user empty is rejected without fallback")
    expect(resolveInvokingUser(arguments: ["arm"], environment: ["SUDO_USER": "root"]) == nil,
           "SUDO_USER=root is rejected")
}

func testNilWhenNeitherSet() {
    expect(resolveInvokingUser(arguments: ["arm"], environment: [:]) == nil, "nil when neither is set")
}
