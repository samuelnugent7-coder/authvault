import 'package:workmanager/workmanager.dart';

import 'backup_service.dart';

const _taskName = 'authvault.nightly_backup';
const _taskUniqueName = 'nightly_backup';

/// Called by WorkManager in the background (both Android & iOS).
/// Must be a top-level function.
@pragma('vm:entry-point')
void workmanagerCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName == _taskName) {
      try {
        final result = await BackupService.runBackup();
        return !result.isError;
      } catch (_) {
        return false;
      }
    }
    return true;
  });
}

class BackupScheduler {
  /// Registers a periodic nightly backup task.
  /// Safe to call multiple times — WorkManager deduplicates by unique name.
  static Future<void> scheduleNightly() async {
    await Workmanager().initialize(
      workmanagerCallbackDispatcher,
      isInDebugMode: false,
    );
    await Workmanager().registerPeriodicTask(
      _taskUniqueName,
      _taskName,
      // WorkManager minimum is 15 min; OS will run ~nightly when charging + WiFi
      frequency: const Duration(hours: 24),
      initialDelay: _nextMidnight(),
      constraints: Constraints(
        networkType: NetworkType.connected,
        requiresBatteryNotLow: true,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  /// Cancel the scheduled task (e.g. if user disables backup).
  static Future<void> cancel() async {
    await Workmanager().cancelByUniqueName(_taskUniqueName);
  }

  static Duration _nextMidnight() {
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day + 1, 2, 0); // 2 AM
    return midnight.difference(now);
  }
}
