import '../storage/local_host_repository.dart';
import 'termius_transfer.dart';

class TermiusUpsertReport {
  const TermiusUpsertReport({
    this.createdHosts = 0,
    this.updatedHosts = 0,
    this.createdGroups = 0,
  });

  final int createdHosts;
  final int updatedHosts;
  final int createdGroups;

  int get totalTouched => createdHosts + updatedHosts;
}

Future<TermiusUpsertReport> upsertTermiusDocumentToLocalRepository(
  LocalHostRepository repository,
  TermiusImportDocument document, {
  String? fallbackUsername,
}) async => const TermiusUpsertReport();

Future<TermiusUpsertReport?> syncPendingTermiusSeedIfPresent(
  LocalHostRepository repository, {
  required String profileId,
}) async => null;
