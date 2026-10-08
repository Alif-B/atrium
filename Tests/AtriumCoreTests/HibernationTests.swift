import Testing
@testable import AtriumCore

@Test func hibernatesOnlyAfterTheFullIdleLimit() {
    #expect(!Hibernation.shouldHibernate(now: 899, lastUsed: 0))
    #expect(Hibernation.shouldHibernate(now: 900, lastUsed: 0))
    #expect(Hibernation.shouldHibernate(now: 5000, lastUsed: 100))
    #expect(!Hibernation.shouldHibernate(now: 1000, lastUsed: 500))
    #expect(Hibernation.idleLimit == 900)
}
