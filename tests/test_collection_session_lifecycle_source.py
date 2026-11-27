"""Source-bound regressions for the Preferences guided session lifecycle."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
DIAGNOSTICS = (ROOT / "Prefs/DiagnosticsPage.m").read_text(encoding="utf-8-sig")
SESSION = (ROOT / "AxsCacheKeeperCollectionSession.m").read_text(encoding="utf-8-sig")
HOST_PAGE = (ROOT / "Prefs/HostPreflightPage.m").read_text(encoding="utf-8-sig")
HOST_BATCH = (ROOT / "AxsCacheKeeperHostPreflight.m").read_text(encoding="utf-8-sig")


class GuidedSessionLifecycleTests(unittest.TestCase):
    def test_capacity_terminal_callback_checks_live_session_phase_before_finishing(self):
        self.assertIn('isEqual:@"running"]', DIAGNOSTICS)
        self.assertIn('finishPhase:@"capacity" result:', DIAGNOSTICS)
        self.assertIn('if (page.axs_cachekeeper_guidedCollection && guidedCapacity)', DIAGNOSTICS)

    def test_capacity_phase_only_accepts_matching_persisted_complete_or_partial_epoch(self):
        poll = DIAGNOSTICS.split("- (void)axs_cachekeeper_capacity_poll {", 1)[1].split("- (void)axs_cachekeeper_capacity_text:", 1)[0]
        self.assertRegex(poll, r'acceptedTerminalStates\s*=\s*@\[@"complete",\s*@"partial",\s*@"cancelled",\s*@"interrupted",\s*@"unavailable"\]')
        self.assertIn('[result[@"epoch"] isEqual:epoch]', poll)
        self.assertIn('result[@"completedRoots"]', poll)
        self.assertIn('result[@"finishedAt"]', poll)
        self.assertIn('[state isEqual:@"invalid"]', poll)
        self.assertIn('![acceptedTerminalStates containsObject:state]', poll)
        self.assertIn('finishCapacityWithSnapshot:result', poll)
        self.assertIn('@"finishedAt":closed[@"finishedAt"]', SESSION)

    def test_background_stop_closes_phase_as_interrupted_before_clearing_epoch(self):
        background = DIAGNOSTICS.split("- (void)axs_cachekeeper_capacity_background:", 1)[1].split("- (void)axs_cachekeeper_collect", 1)[0]
        self.assertIn('finishPhase:@"capacity" result:@{', DIAGNOSTICS)
        self.assertIn('axs_cachekeeper_interrupt_capacity:@"pageLeft"', DIAGNOSTICS)

    def test_async_diagnostics_callback_does_not_mutate_phase_after_page_departure(self):
        collect = DIAGNOSTICS.split("- (void)axs_cachekeeper_collect {", 1)[1].split("- (void)axs_cachekeeper_message:", 1)[0]
        worker = collect.split("dispatch_async(self.collectionQueue,^{", 1)[1].split("dispatch_async(dispatch_get_main_queue(),^{", 1)[0]
        main = collect.split("dispatch_async(dispatch_get_main_queue(),^{", 1)[1]
        self.assertNotIn('finishPhase:@"diagnostics"', worker)
        self.assertLess(main.index('page.generation!=generation'), main.index('saveReport:finalReport'))

    def test_report_never_labels_unsupported_private_modules_ready(self):
        self.assertIn('capability:@"privateResourceContract"', DIAGNOSTICS)
        self.assertIn('"executionAvailable":@NO', SESSION)
        self.assertIn('"blockedCapabilities":[self.axs_cachekeeper_document', SESSION)

    def test_new_guided_action_allocates_new_session_instead_of_reopening_fixed_file(self):
        action = DIAGNOSTICS.split("- (void)axs_cachekeeper_guided_action {", 1)[1].split("- (void)axs_cachekeeper_push_host_preflight", 1)[0]
        self.assertIn('axs_cachekeeper_openSessionInDirectory:directory', action)
        self.assertNotIn('initWithPath:', action)
        self.assertIn('initWithCollectionSessionObject:session', action)

    def test_diagnostics_report_is_rebuilt_after_session_export_phase_is_persisted(self):
        self.assertIn('saveReport:finalReport', DIAGNOSTICS)
        self.assertIn('finalReport[@"guidedCollection"]=self.reportProjection', SESSION)

    def test_diagnostics_phase_uses_source_coverage_not_non_nil_apps(self):
        self.assertIn('axs_cachekeeper_diagnostics_coverage_state(report)', DIAGNOSTICS)
        self.assertIn('diagnosticsCoverage[@"state"]', DIAGNOSTICS)
        self.assertIn('diagnosticsCoverage[@"missingSources"]', DIAGNOSTICS)
        helper = DIAGNOSTICS.split('static NSDictionary *axs_cachekeeper_diagnostics_coverage_state', 1)[1].split('@interface AxsCacheKeeperDiagnosticsPage', 1)[0]
        self.assertIn('![state isEqual:@"available"]', helper)
        self.assertIn('![coverage[@"state"] isEqual:@"available"]', helper)
        self.assertIn('![registry[@"state"] isEqual:@"available"]', helper)
        self.assertIn('![scope[@"state"] isEqual:@"complete"]', helper)
        self.assertIn('installedMetadataState', helper)
        self.assertIn('![@[@"available",@"notInSnapshot"] containsObject:app[@"installedMetadataState"]]', helper)
        self.assertIn('![app[@"installationState"] isEqual:@"verified"]', helper)
        self.assertIn('@"partial" : @"complete"', helper)

    def test_host_preflight_session_records_this_round_unauthenticated_source_timestamps(self):
        self.assertIn('transportTrust', HOST_PAGE)
        self.assertIn('sourceUpdated', HOST_PAGE)
        self.assertIn('roundStartedAt', HOST_PAGE)
        self.assertIn('BOOL current=[sourceUpdated doubleValue]>=self.axs_cachekeeper_roundStartedAt', HOST_PAGE)
        self.assertIn('@"transportTrust":@"unauthenticated"', HOST_BATCH)
        self.assertIn('evidence[@"observationFreshness"]=current ? @"currentRound"', HOST_PAGE)
        self.assertIn('observationFreshness"] isEqual:@"currentRound"', SESSION)
        self.assertIn('![result[@"transportTrust"] isEqual:@"unauthenticated"]', SESSION)

    def test_host_preflight_resume_requires_explicit_retry_transition(self):
        action = HOST_PAGE.split('- (void)axs_cachekeeper_action {', 1)[1].split('- (void)axs_cachekeeper_poll {', 1)[0]
        self.assertIn('prepareRetryForPhase:@"hostPreflight"', action)
        self.assertIn('beginPhase:@"hostPreflight"', action)
        self.assertLess(action.index('prepareRetryForPhase:@"hostPreflight"'), action.index('beginPhase:@"hostPreflight"'))
        self.assertIn('!prepared', action)

    def test_terminal_phase_requires_started_state_and_exact_named_phase(self):
        self.assertIn('![axs_cachekeeper_collection_phases() containsObject:phase]', SESSION)
        self.assertIn('isEqual:@"running"]', SESSION)

    def test_guided_session_is_not_silently_started_from_old_fixed_path(self):
        self.assertNotIn('@"collectionSession.plist"', DIAGNOSTICS)
        self.assertIn('collectionSessions', DIAGNOSTICS)
        self.assertIn('NSUUID.UUID.UUIDString', DIAGNOSTICS)

    def test_collection_session_supports_validated_resumable_listing_and_open(self):
        self.assertIn('+ (NSArray<NSDictionary *> *)resumableSessionsInDirectory:', SESSION)
        self.assertIn('+ (instancetype)openSessionAtPath:', SESSION)
        self.assertIn('attributesOfItemAtPath:path', SESSION)
        self.assertIn('isEqualToString:@"plist"', SESSION)
        self.assertIn('@"nextPhase":nextPhase', SESSION)
        self.assertIn('propertyListWithData:data options:NSPropertyListImmutable', SESSION)
        self.assertIn('openSessionAtPath:(NSString *)path', SESSION)
        self.assertIn('if ([state isEqual:@"failed"] || [state isEqual:@"blockedByCapability"])', SESSION)
        self.assertNotIn('if (![state isEqual:@"complete"])', SESSION)

    def test_blocked_capability_does_not_remove_read_only_session_from_resume_list(self):
        listing = SESSION.split('+ (NSArray<NSDictionary *> *)resumableSessionsInDirectory:', 1)[1].split('+ (instancetype)openSessionAtPath:', 1)[0]
        self.assertNotIn('if ([document[@"blockedCapabilities"] count]) continue;', listing)

    def test_capacity_retry_enters_running_before_request_and_interrupt_is_persisted(self):
        action = DIAGNOSTICS.split('- (void)axs_cachekeeper_capacity_action {', 1)[1].split('- (void)axs_cachekeeper_capacity_poll {', 1)[0]
        self.assertNotIn('&& !retryingCapacity &&', action)
        self.assertIn('axs_cachekeeper_interrupt_capacity:', DIAGNOSTICS)

    def test_guided_report_is_durable_and_reopened_without_recollection(self):
        self.assertIn('saveReport:finalReport', DIAGNOSTICS)
        self.assertIn('savedReportData:', DIAGNOSTICS)
        self.assertIn('reportArtifact', SESSION)
        self.assertNotIn('finishPhase:@"export"', DIAGNOSTICS)

    def test_capacity_abandon_interrupts_and_terminal_save_failure_keeps_live_epoch(self):
        action = DIAGNOSTICS.split('- (void)axs_cachekeeper_capacity_action {', 1)[1].split('- (void)axs_cachekeeper_capacity_poll {', 1)[0]
        self.assertLess(action.index('axs_cachekeeper_interrupt_capacity:@"cancelNotConfirmed"'), action.index('[self axs_cachekeeper_capacity_stop]'))
        failure = DIAGNOSTICS.split('容量已取得终态，但会话无法保存', 1)[1].split('if (page.axs_cachekeeper_capacityPendingStop)', 1)[0]
        self.assertNotIn('capacityEpoch=nil', failure)
        self.assertIn('capacityTerminalSaveFailed=YES', failure)
        self.assertIn('retainedTerminal ?: axs_cachekeeper_capacity_read_result', DIAGNOSTICS)
        self.assertIn('if (self.axs_cachekeeper_capacityTerminalSaveFailed) {[self axs_cachekeeper_capacity_poll];return;}', action)

    def test_capacity_stage_persists_and_restores_its_own_full_snapshot(self):
        self.assertIn('beginCapacityWithEpoch:epoch', DIAGNOSTICS)
        self.assertIn('finishCapacityWithSnapshot:result', DIAGNOSTICS)
        self.assertIn('savedCapacitySnapshot:', DIAGNOSTICS)
        self.assertIn('@"capacityArtifact"', SESSION)
        self.assertIn('axs_cachekeeper_capacity_projection', SESSION)

    def test_running_capacity_summary_keeps_epoch_without_inventing_finished_at(self):
        collect=DIAGNOSTICS.split('- (void)axs_cachekeeper_collect {',1)[1].split('- (void)axs_cachekeeper_message:',1)[0]
        self.assertNotIn('removeObjectForKey:@"epoch"',collect)
        self.assertIn('axs_cachekeeper_capacity_export:capacitySnapshot saved:saved stop:capacityStop',collect)

    def test_complete_host_receipts_and_manifest_use_retained_source_bytes(self):
        self.assertIn('evidence[@"receipt"]=result', HOST_PAGE)
        self.assertIn('@"hostArtifact"', SESSION)
        self.assertIn('axs_cachekeeper_host_observed_projection', SESSION)
        self.assertIn('@"sourceManifest"', SESSION)
        self.assertIn('base64EncodedStringWithOptions:0', SESSION)

    def test_durable_stale_capacity_report_remains_exportable_as_history(self):
        self.assertIn('(!self.axs_cachekeeper_collectionSession && !axs_cachekeeper_capacity_report_exportable(report))', DIAGNOSTICS)

    def test_guided_entry_can_select_existing_session_or_create_new(self):
        action = DIAGNOSTICS.split('- (void)axs_cachekeeper_guided_action {', 1)[1].split('- (void)axs_cachekeeper_push_host_preflight', 1)[0]
        self.assertIn('resumableSessionsInDirectory:directory', action)
        self.assertIn('openSessionAtPath:', action)
        self.assertIn('axs_cachekeeper_openSessionInDirectory:directory', action)
        self.assertIn('UIAlertControllerStyleActionSheet', action)


if __name__ == "__main__":
    unittest.main(verbosity=2)
