import BipuuChecking
import BipuuCore

await run("IdentifierTests.idsEncodeAsPlainStrings") { try await IdentifierTests().idsEncodeAsPlainStrings() }
await run("IdentifierTests.generatedIDsAreUniqueAndHashable") { try await IdentifierTests().generatedIDsAreUniqueAndHashable() }
await run("IdentifierTests.idTypesAreDistinct") { try await IdentifierTests().idTypesAreDistinct() }
await run("EntityTests.entitiesRoundTrip") { try await EntityTests().entitiesRoundTrip() }
await run("EntityTests.taskIsNotSession") { try await EntityTests().taskIsNotSession() }
await run("EntityTests.taskMovesBetweenProjects") { try await EntityTests().taskMovesBetweenProjects() }
await run("EntityTests.agentHostEnvironmentAreIndependent") { try await EntityTests().agentHostEnvironmentAreIndependent() }
await run("EntityTests.vocabulariesAreOpen") { try await EntityTests().vocabulariesAreOpen() }
await run("EntityTests.approvalPendingUntilDecided") { try await EntityTests().approvalPendingUntilDecided() }
await run("EventTests.envelopeRoundTripAndVersion") { try await EventTests().envelopeRoundTripAndVersion() }
await run("EventTests.minimalEnvelopeHasOnlyRequiredFields") { try await EventTests().minimalEnvelopeHasOnlyRequiredFields() }
await run("EventTests.futureSchemaAndUnknownKindStillDecode") { try await EventTests().futureSchemaAndUnknownKindStillDecode() }
await run("EventTests.missingRequiredFieldFails") { try await EventTests().missingRequiredFieldFails() }
await run("EventTests.knownKindsAreUniqueAndDotted") { try await EventTests().knownKindsAreUniqueAndDotted() }
await run("EventTests.canonicalOrderIsDeterministic") { try await EventTests().canonicalOrderIsDeterministic() }
await run("InMemoryEventStoreTests.appendIsIdempotentAndQueriesFilter") { try await InMemoryEventStoreTests().appendIsIdempotentAndQueriesFilter() }
await run("InMemoryEventStoreTests.recentIsLastNInAscendingOrder") { try await InMemoryEventStoreTests().recentIsLastNInAscendingOrder() }
await run("IsolationTests.coreImportsOnlyFoundation") { try await IsolationTests().coreImportsOnlyFoundation() }
await run("IsolationTests.coreHasNoVendorBranching") { try await IsolationTests().coreHasNoVendorBranching() }
await EventStoreContract.runAll("InMemoryEventStore") { InMemoryEventStore() }

finish()
