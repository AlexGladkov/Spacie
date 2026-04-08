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
            _state.value = _state.value.copy(dependencyStatus = null, lastError = null)
            val status = service.checkDependencies()
            _state.value = _state.value.copy(dependencyStatus = status)
            if (status is DependencyStatus.Ready) {
                checkAppleIDStatus()
                if (_state.value.appleIDAuthenticated) {
                    _state.value = _state.value.copy(step = ITransferStep.CONNECT_SOURCE)
                }
            }
        }
    }

    fun installDependencies() {
        if (_state.value.isInstallingDeps) return
        scope.launch {
            _state.value = _state.value.copy(
                isInstallingDeps = true,
                installOutput = emptyList(),
                lastError = null
            )
            try {
                service.installDependencies { line ->
                    _state.value = _state.value.copy(
                        installOutput = _state.value.installOutput + line
                    )
                }
                val status = service.checkDependencies()
                _state.value = _state.value.copy(dependencyStatus = status)
                if (status is DependencyStatus.Ready) {
                    checkAppleIDStatus()
                    if (_state.value.appleIDAuthenticated) {
                        _state.value = _state.value.copy(step = ITransferStep.CONNECT_SOURCE)
                    }
                }
            } catch (e: Exception) {
                _state.value = _state.value.copy(lastError = e.message)
            } finally {
                _state.value = _state.value.copy(isInstallingDeps = false)
            }
        }
    }

    // -------------------------------------------------------------------------
    // Apple ID
    // -------------------------------------------------------------------------

    fun checkAppleIDStatus() {
        scope.launch {
            _state.value = _state.value.copy(isCheckingAppleID = true)
            val auth = service.checkAppleIDAuth()
            _state.value = _state.value.copy(
                appleIDAuthenticated = auth,
                isCheckingAppleID = false
            )
        }
    }

    fun loginAppleID(email: String, password: String) {
        scope.launch {
            _state.value = _state.value.copy(
                isAuthenticatingAppleID = true,
                appleIDLoginError = null,
                appleIDNeedsTwoFactor = false
            )
            try {
                service.loginAppleID(email, password, null)
                _state.value = _state.value.copy(
                    appleIDAuthenticated = true,
                    appleIDEmailForTwoFactor = "",
                    step = ITransferStep.CONNECT_SOURCE
                )
            } catch (e: SpacieError.TwoFactorRequired) {
                _state.value = _state.value.copy(
                    appleIDNeedsTwoFactor = true,
                    appleIDEmailForTwoFactor = email
                )
            } catch (e: Exception) {
                _state.value = _state.value.copy(appleIDLoginError = e.message)
            } finally {
                _state.value = _state.value.copy(isAuthenticatingAppleID = false)
            }
        }
    }

    fun loginAppleIDWithTwoFactor(email: String, password: String, code: String) {
        scope.launch {
            _state.value = _state.value.copy(
                isAuthenticatingAppleID = true,
                appleIDLoginError = null
            )
            try {
                service.loginAppleID(email, password, code)
                _state.value = _state.value.copy(
                    appleIDAuthenticated = true,
                    appleIDNeedsTwoFactor = false,
                    step = ITransferStep.CONNECT_SOURCE
                )
            } catch (e: Exception) {
                _state.value = _state.value.copy(appleIDLoginError = e.message)
            } finally {
                _state.value = _state.value.copy(isAuthenticatingAppleID = false)
            }
        }
    }

    // -------------------------------------------------------------------------
    // Source Device
    // -------------------------------------------------------------------------

    fun startSourceDeviceObservation() {
        stopDeviceObservation()
        _state.value = _state.value.copy(isWaitingForSource = true)
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
            _state.value = _state.value.copy(isWaitingForSource = false)
        }
    }

    private suspend fun loadSourceApps() {
        val udid = _state.value.sourceDevice?.udid ?: return
        _state.value = _state.value.copy(isLoadingApps = true, lastError = null)
        try {
            val apps = service.listApps(udid)
            _state.value = _state.value.copy(availableApps = apps, isLoadingApps = false)
            if (apps.isNotEmpty()) {
                _state.value = _state.value.copy(step = ITransferStep.SELECT_APPS)
            }
        } catch (e: Exception) {
            _state.value = _state.value.copy(lastError = e.message, isLoadingApps = false)
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
        val selected = _state.value.selectedBundleIDs.toMutableSet()
        if (selected.contains(bundleID)) selected.remove(bundleID) else selected.add(bundleID)
        _state.value = _state.value.copy(selectedBundleIDs = selected)
    }

    fun selectAllApps() {
        _state.value = _state.value.copy(
            selectedBundleIDs = _state.value.availableApps.map { it.bundleID }.toSet()
        )
    }

    fun deselectAllApps() {
        _state.value = _state.value.copy(selectedBundleIDs = emptySet())
    }

    fun proceedFromSelectApps() {
        if (_state.value.selectedBundleIDs.isNotEmpty()) {
            _state.value = _state.value.copy(step = ITransferStep.CHOOSE_ACTION)
        }
    }

    // -------------------------------------------------------------------------
    // Action Choice
    // -------------------------------------------------------------------------

    fun setArchiveOnly(value: Boolean) {
        _state.value = _state.value.copy(archiveOnly = value)
    }

    fun setArchiveDir(path: String) {
        _state.value = _state.value.copy(archiveDir = path.ifBlank { null })
    }

    fun proceedFromChooseAction() {
        _state.value = if (_state.value.archiveOnly) {
            _state.value.copy(step = ITransferStep.TRANSFERRING)
        } else {
            _state.value.copy(step = ITransferStep.CONNECT_DESTINATION)
        }
    }

    // -------------------------------------------------------------------------
    // Destination Device
    // -------------------------------------------------------------------------

    fun startDestinationDeviceObservation() {
        stopDeviceObservation()
        _state.value = _state.value.copy(isWaitingForDestination = true)
        deviceObservationJob = scope.launch {
            service.observeDevices(2.0).collect { event ->
                handleDeviceEvent(event, isSource = false)
                val s = _state.value
                if (s.destinationDevice != null && s.destinationTrustState == TrustState.TRUSTED) {
                    _state.value = _state.value.copy(step = ITransferStep.TRANSFERRING)
                    cancel()
                }
            }
        }
        deviceObservationJob?.invokeOnCompletion {
            _state.value = _state.value.copy(isWaitingForDestination = false)
        }
    }

    // -------------------------------------------------------------------------
    // Transfer
    // -------------------------------------------------------------------------

    fun startTransfer() {
        val s = _state.value
        val sourceUDID = s.sourceDevice?.udid ?: return
        val selectedApps = s.availableApps.filter { s.selectedBundleIDs.contains(it.bundleID) }
        if (selectedApps.isEmpty()) return

        transferJob = scope.launch {
            service.transferApps(
                sourceUDID = sourceUDID,
                destinationUDID = if (s.archiveOnly) null else s.destinationDevice?.udid,
                apps = selectedApps,
                archiveDir = s.archiveDir,
                shouldInstall = !s.archiveOnly
            ).collect { progress ->
                _state.value = _state.value.copy(transferProgress = progress)
            }
            val progress = _state.value.transferProgress
            val successCount = progress?.items?.count { it.phase == TransferPhase.COMPLETED } ?: 0
            val failCount = progress?.items?.count { it.phase == TransferPhase.FAILED } ?: 0
            _state.value = _state.value.copy(
                transferSuccessCount = successCount,
                transferFailCount = failCount,
                step = ITransferStep.RESULT
            )
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
                if (isSource && _state.value.sourceDevice == null) {
                    _state.value = _state.value.copy(
                        sourceDevice = event.device,
                        sourceTrustState = TrustState.NOT_TRUSTED
                    )
                    scope.launch {
                        val trust = service.validateTrust(event.device.udid)
                        _state.value = _state.value.copy(sourceTrustState = trust)
                    }
                } else if (!isSource &&
                    _state.value.destinationDevice == null &&
                    event.device.udid != _state.value.sourceDevice?.udid
                ) {
                    _state.value = _state.value.copy(
                        destinationDevice = event.device,
                        destinationTrustState = TrustState.NOT_TRUSTED
                    )
                    scope.launch {
                        val trust = service.validateTrust(event.device.udid)
                        _state.value = _state.value.copy(destinationTrustState = trust)
                    }
                }
            }
            is DeviceEvent.Disconnected -> {
                if (isSource && _state.value.sourceDevice?.udid == event.udid) {
                    _state.value = _state.value.copy(
                        sourceDevice = null,
                        sourceTrustState = TrustState.NOT_TRUSTED
                    )
                } else if (!isSource && _state.value.destinationDevice?.udid == event.udid) {
                    _state.value = _state.value.copy(
                        destinationDevice = null,
                        destinationTrustState = TrustState.NOT_TRUSTED
                    )
                }
            }
            is DeviceEvent.TrustStateChanged -> {
                if (_state.value.sourceDevice?.udid == event.udid) {
                    _state.value = _state.value.copy(sourceTrustState = event.state)
                } else if (_state.value.destinationDevice?.udid == event.udid) {
                    _state.value = _state.value.copy(destinationTrustState = event.state)
                }
            }
            is DeviceEvent.Error -> {
                _state.value = _state.value.copy(lastError = event.message)
            }
        }
    }
}
