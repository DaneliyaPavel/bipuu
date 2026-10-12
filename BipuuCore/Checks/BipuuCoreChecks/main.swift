import BipuuChecking
import BipuuCore

unbufferOutput()

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
await RetentionContract.runAll("InMemoryEventStore") { InMemoryEventStore() }
await DomainStoreContract.runAll("InMemoryDomainStore") { InMemoryDomainStore() }
await run("ProjectionChecks.phases") { try await ProjectionChecks().phases() }
await run("ProjectionChecks.attention") { try await ProjectionChecks().attention() }
await run("ProjectionChecks.service") { try await ProjectionChecks().service() }
await run("InferenceChecks.newSessionGetsAProposedTask") { try await InferenceChecks().newSessionGetsAProposedTask() }
await run("InferenceChecks.sessionsInTheSameContextShareATask") { try await InferenceChecks().sessionsInTheSameContextShareATask() }
await run("InferenceChecks.idleGapStartsANewTask") { try await InferenceChecks().idleGapStartsANewTask() }
await run("InferenceChecks.branchesAreSeparateUnlessAskedOtherwise") { try await InferenceChecks().branchesAreSeparateUnlessAskedOtherwise() }
await run("InferenceChecks.existingAssignmentsAreNeverTouched") { try await InferenceChecks().existingAssignmentsAreNeverTouched() }
await run("InferenceChecks.handMadeTasksAreNotJoined") { try await InferenceChecks().handMadeTasksAreNotJoined() }
await run("InferenceChecks.confirmKeepsGroupingAndNeverOthers") { try await InferenceChecks().confirmKeepsGroupingAndNeverOthers() }
await run("InferenceChecks.closedTasksAreNotReopened") { try await InferenceChecks().closedTasksAreNotReopened() }
await run("InferenceChecks.skipsWhatCannotBePlaced") { try await InferenceChecks().skipsWhatCannotBePlaced() }
await run("InferenceChecks.inferenceKeyPersistsAndOldDataStillDecodes") { try await InferenceChecks().inferenceKeyPersistsAndOldDataStillDecodes() }
await run("InferenceChecks.gitLocatorFindsRepositoriesWorktreesAndPlainDirectories") { try await InferenceChecks().gitLocatorFindsRepositoriesWorktreesAndPlainDirectories() }
await run("InferenceChecks.hostileRepositoriesCannotStallOrExhaustTheLocator") { try await InferenceChecks().hostileRepositoriesCannotStallOrExhaustTheLocator() }
await run("InferenceChecks.inferenceWorksEndToEndWithTheRealLocator") { try await InferenceChecks().inferenceWorksEndToEndWithTheRealLocator() }
await run("OverviewChecks.emptyWorldIsEmpty") { try await OverviewChecks().emptyWorldIsEmpty() }
await run("OverviewChecks.ordersByAttentionThenActivityAndGroupsByProject") { try await OverviewChecks().ordersByAttentionThenActivityAndGroupsByProject() }
await run("OverviewChecks.showsOnlyOpenTasksAndCountsUnattachedSessions") { try await OverviewChecks().showsOnlyOpenTasksAndCountsUnattachedSessions() }
await run("OverviewChecks.marksProposalsAndHonoursTheLimit") { try await OverviewChecks().marksProposalsAndHonoursTheLimit() }
await run("OverviewChecks.isReadOnly") { try await OverviewChecks().isReadOnly() }

finish()
