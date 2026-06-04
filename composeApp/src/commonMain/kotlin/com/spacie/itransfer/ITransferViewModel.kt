package com.spacie.itransfer

import com.spacie.core.SpacieFactory
import com.spacie.core.api.DependencyStatus
import com.spacie.core.api.DeviceServiceApi
import com.spacie.core.error.SpacieError
import com.spacie.core.model.AppInfo
import com.spacie.core.model.DeviceEvent
import com.spacie.core.model.DeviceInfo
import com.spacie.core.model.TransferPhase
import com.spacie.core.model.TransferProgress
import com.spacie.core.model.TrustState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Wizard steps for the iTransfer flow.
 */
enum class ITransferStep {
    DEPENDENCY_CHECK,
    CONNECT_SOURCE,
    SELECT_APPS,
    CHOOSE_ACTION,
    CONNECT_DESTINATION,
    TRANSFERRING,
    RESULT
}

/**
 * Immutable UI state for the iTransfer wizard.
 */
data class ITransferState(
    val step: ITransferStep = ITransferStep.DEPENDENCY_CHECK,

    // Dependency check
    val dependencyStatus: DependencyStatus? = null,
    val isInstallingDeps: Boolean = false,
    val installOutput: List<String> = emptyList(),

    // Apple ID
    val appleIDAuthenticated: Boolean = false,
    val isCheckingAppleID: Boolean = false,
    val isAuthenticatingAppleID: Boolean = false,
    val appleIDLoginError: String? = null,
    val appleIDNeedsTwoFactor: Boolean = false,
    val appleIDEmailForTwoFactor: String = "",

    // Source device
    val sourceDevice: DeviceInfo? = null,
    val sourceTrustState: TrustState = TrustState.NOT_TRUSTED,
    val isWaitingForSource: Boolean = false,

    // App selection
    val availableApps: List<AppInfo> = emptyList(),
    val selectedBundleIDs: Set<String> = emptySet(),
    val isLoadingApps: Boolean = false,

    // Action choice
    val archiveOnly: Boolean = true,
    val archiveDir: String? = null,

    // Destination device
    val destinationDevice: DeviceInfo? = null,
    val destinationTrustState: TrustState = TrustState.NOT_TRUSTED,
    val isWaitingForDestination: Boolean = false,

    // Transfer progress
    val transferProgress: TransferProgress? = null,
    val transferSuccessCount: Int = 0,
    val transferFailCount: Int = 0,

    // Errors
    val lastError: String? = null
)

/**
 * ViewModel for the iTransfer wizard. Owns a [CoroutineScope] tied to its lifecycle.
 * Call [onCleared] when the composable is disposed to release resources.
 *
 * Thread-safety:
 *  - All state mutations go through [MutableStateFlow.update], which is atomic
 *    read-modify-write and prevents the lost-update race that occurred with the
 *    previous `_state.value = _state.value.copy(...)` pattern.
 *  - Side-effect-triggering writes (e.g. step transitions) happen on the same
 *    update so the reader can never observe a partially-updated state.
 */
class ITransferViewModel(
    private val service: DeviceServiceApi = SpacieFactory.createDeviceService()
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _state = MutableStateFlow(ITransferState())
    val state: StateFlow<ITransferState> = _state.asStateFlow()

    private var deviceObservationJob: Job? = null
    private var transferJob: Job? = null

    // -------------------------------------------------------------------------
    // Dependency Check
    // -------------------------------------------------------------------------

    fun checkDependencies() {
        scope.launch {
            _state.update { it.copy(dependencyStatus = null, lastError = null) }
            val status = service.checkDependencies()
            _state.update { it.copy(dependencyStatus = status) }
            if (status is DependencyStatus.Ready) {
                val authed = fetchAppleIDStatus()
                if (authed) {
                    _state.update { it.copy(step = ITransferStep.CONNECT_SOURCE) }
                }
            }
        }
    }

    fun installDependencies() {
        if (_state.value.isInstallingDeps) return
        scope.launch {
            _state.update {
                it.copy(
                    isInstallingDeps = true,
                    installOutput = emptyList(),
                    lastError = null
                )
            }
            try {
                service.installDependencies { line ->
                    _state.update { it.copy(installOutput = it.installOutput + line) }
                }
                val status = service.checkDependencies()
                _state.update { it.copy(dependencyStatus = status) }
                if (status is DependencyStatus.Ready) {
                    val authed = fetchAppleIDStatus()
                    if (authed) {
                        _state.update { it.copy(step = ITransferStep.CONNECT_SOURCE) }
                    }
                }
            } catch (e: Exception) {
                _state.update { it.copy(lastError = e.message) }
            } finally {
                _state.update { it.copy(isInstallingDeps = false) }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Apple ID
    // -------------------------------------------------------------------------

    fun checkAppleIDStatus() {
        scope.launch { fetchAppleIDStatus() }
    }

    /**
     * Suspend variant that returns the freshly-fetched auth flag so callers can
     * branch on the result without racing against the StateFlow snapshot.
     */
    private suspend fun fetchAppleIDStatus(): Boolean {
        _state.update { it.copy(isCheckingAppleID = true) }
        val auth = service.checkAppleIDAuth()
        _state.update { it.copy(appleIDAuthenticated = auth, isCheckingAppleID = false) }
        return auth
    }

    fun loginAppleID(email: String, password: String) {
        scope.launch {
            _state.update {
                it.copy(
                    isAuthenticatingAppleID = true,
                    appleIDLoginError = null,
                    appleIDNeedsTwoFactor = false
                )
            }
            try {
                service.loginAppleID(email, password, null)
                _state.update {
                    it.copy(
                        appleIDAuthenticated = true,
                        appleIDEmailForTwoFactor = "",
                        step = ITransferStep.CONNECT_SOURCE
                    )
                }
            } catch (e: SpacieError.TwoFactorRequired) {
                _state.update {
                    it.copy(appleIDNeedsTwoFactor = true, appleIDEmailForTwoFactor = email)
                }
            } catch (e: Exception) {
                _state.update { it.copy(appleIDLoginError = e.message) }
            } finally {
                _state.update { it.copy(isAuthenticatingAppleID = false) }
            }
        }
    }

    fun loginAppleIDWithTwoFactor(email: String, password: String, code: String) {
        scope.launch {
            _state.update {
                it.copy(isAuthenticatingAppleID = true, appleIDLoginError = null)
            }
            try {
                service.loginAppleID(email, password, code)
                _state.update {
                    it.copy(
                        appleIDAuthenticated = true,
                        appleIDNeedsTwoFactor = false,
                        step = ITransferStep.CONNECT_SOURCE
                    )
                }
            } catch (e: Exception) {
                _state.update { it.copy(appleIDLoginError = e.message) }
            } finally {
                _state.update { it.copy(isAuthenticatingAppleID = false) }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Source Device
    // -------------------------------------------------------------------------

    fun startSourceDeviceObservation() {
        stopDeviceObservation()
        _state.update { it.copy(isWaitingForSource = true) }
        deviceObservationJob = scope.launch {
            service.observeDevices(2.0).collect { event ->
                handleDeviceEvent(event, isSource = true)
                val s = _state.value
                if (s.sourceDevice != null && s.sourceTrustState == TrustState.TRUSTED) {
                    loadSourceApps()
                    cancel()
                }
            }
        }
        deviceObservationJob?.invokeOnCompletion {
            _state.update { it.copy(isWaitingForSource = false) }
        }
    }

    private suspend fun loadSourceApps() {
        val udid = _state.value.sourceDevice?.udid ?: return
        _state.update { it.copy(isLoadingApps = true, lastError = null) }
        try {
            val apps = service.listApps(udid)
            _state.update {
                val nextStep = if (apps.isNotEmpty()) ITransferStep.SELECT_APPS else it.step
                it.copy(availableApps = apps, isLoadingApps = false, step = nextStep)
            }
        } catch (e: Exception) {
            _state.update { it.copy(lastError = e.message, isLoadingApps = false) }
        }
    }

    fun stopDeviceObservation() {
        deviceObservationJob?.cancel()
        deviceObservationJob = null
    }

    // -------------------------------------------------------------------------
    // App Selection
    // -------------------------------------------------------------------------

    fun toggleApp(bundleID: String) {
        _state.update {
            val next = it.selectedBundleIDs.toMutableSet()
            if (next.contains(bundleID)) next.remove(bundleID) else next.add(bundleID)
            it.copy(selectedBundleIDs = next)
        }
    }

    fun selectAllApps() {
        _state.update {
            it.copy(selectedBundleIDs = it.availableApps.map { app -> app.bundleID }.toSet())
        }
    }

    fun deselectAllApps() {
        _state.update { it.copy(selectedBundleIDs = emptySet()) }
    }

    fun proceedFromSelectApps() {
        _state.update {
            if (it.selectedBundleIDs.isNotEmpty()) it.copy(step = ITransferStep.CHOOSE_ACTION)
            else it
        }
    }

    // -------------------------------------------------------------------------
    // Action Choice
    // -------------------------------------------------------------------------

    fun setArchiveOnly(value: Boolean) {
        _state.update { it.copy(archiveOnly = value) }
    }

    fun setArchiveDir(path: String) {
        _state.update { it.copy(archiveDir = path.ifBlank { null }) }
    }

    fun proceedFromChooseAction() {
        _state.update {
            val next = if (it.archiveOnly) ITransferStep.TRANSFERRING else ITransferStep.CONNECT_DESTINATION
            it.copy(step = next)
        }
    }

    // -------------------------------------------------------------------------
    // Destination Device
    // -------------------------------------------------------------------------

    fun startDestinationDeviceObservation() {
        stopDeviceObservation()
        _state.update { it.copy(isWaitingForDestination = true) }
        deviceObservationJob = scope.launch {
            service.observeDevices(2.0).collect { event ->
                handleDeviceEvent(event, isSource = false)
                val s = _state.value
                if (s.destinationDevice != null && s.destinationTrustState == TrustState.TRUSTED) {
                    _state.update { it.copy(step = ITransferStep.TRANSFERRING) }
                    cancel()
                }
            }
        }
        deviceObservationJob?.invokeOnCompletion {
            _state.update { it.copy(isWaitingForDestination = false) }
        }
    }

    // -------------------------------------------------------------------------
    // Transfer
    // -------------------------------------------------------------------------

    /**
     * Idempotent: if a transfer is already in progress, do nothing.
     * Guards against the `LaunchedEffect(Unit)` re-entry from
     * `TransferringStep` (which recomposes on window resize).
     */
    fun startTransfer() {
        if (transferJob?.isActive == true) return

        val s = _state.value
        val sourceUDID = s.sourceDevice?.udid ?: return
        val selectedApps = s.availableApps.filter { s.selectedBundleIDs.contains(it.bundleID) }
        if (selectedApps.isEmpty()) return

        transferJob = scope.launch {
            try {
                service.transferApps(
                    sourceUDID = sourceUDID,
                    destinationUDID = if (s.archiveOnly) null else s.destinationDevice?.udid,
                    apps = selectedApps,
                    archiveDir = s.archiveDir,
                    shouldInstall = !s.archiveOnly
                ).collect { progress ->
                    _state.update { it.copy(transferProgress = progress) }
                }
            } finally {
                _state.update {
                    val progress = it.transferProgress
                    val successCount = progress?.items?.count { i -> i.phase == TransferPhase.COMPLETED } ?: 0
                    val failCount = progress?.items?.count { i -> i.phase == TransferPhase.FAILED } ?: 0
                    it.copy(
                        transferSuccessCount = successCount,
                        transferFailCount = failCount,
                        step = ITransferStep.RESULT
                    )
                }
            }
        }
    }

    fun cancelTransfer() {
        transferJob?.cancel()
        transferJob = null
        service.cancel()
    }

    // -------------------------------------------------------------------------
    // Reset
    // -------------------------------------------------------------------------

    fun reset() {
        cancelTransfer()
        stopDeviceObservation()
        service.cancel()
        _state.value = ITransferState()
    }

    fun onCleared() {
        scope.cancel()
        service.cancel()
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    private fun handleDeviceEvent(event: DeviceEvent, isSource: Boolean) {
        when (event) {
            is DeviceEvent.Connected -> {
                _state.update {
                    if (isSource && it.sourceDevice == null) {
                        it.copy(sourceDevice = event.device, sourceTrustState = TrustState.NOT_TRUSTED)
                    } else if (!isSource &&
                        it.destinationDevice == null &&
                        event.device.udid != it.sourceDevice?.udid
                    ) {
                        it.copy(destinationDevice = event.device, destinationTrustState = TrustState.NOT_TRUSTED)
                    } else it
                }
                // The observeDevices flow already emits TrustStateChanged separately.
                // No need to spawn a parallel validateTrust Task here — that caused
                // the race where the polling loop's fresh state was overwritten by
                // an older validateTrust response.
            }
            is DeviceEvent.Disconnected -> {
                _state.update {
                    if (isSource && it.sourceDevice?.udid == event.udid) {
                        it.copy(sourceDevice = null, sourceTrustState = TrustState.NOT_TRUSTED)
                    } else if (!isSource && it.destinationDevice?.udid == event.udid) {
                        it.copy(destinationDevice = null, destinationTrustState = TrustState.NOT_TRUSTED)
                    } else it
                }
            }
            is DeviceEvent.TrustStateChanged -> {
                _state.update {
                    when {
                        it.sourceDevice?.udid == event.udid -> it.copy(sourceTrustState = event.state)
                        it.destinationDevice?.udid == event.udid -> it.copy(destinationTrustState = event.state)
                        else -> it
                    }
                }
            }
            is DeviceEvent.Error -> {
                _state.update { it.copy(lastError = event.message) }
            }
        }
    }
}
