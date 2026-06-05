@file:OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)

package com.spacie.core.api

import com.spacie.core.flow.CommonFlow
import com.spacie.core.flow.asCommonFlow
import com.spacie.core.model.AppInfo
import com.spacie.core.model.DeviceEvent
import com.spacie.core.model.TransferItem
import com.spacie.core.model.TransferPhase
import com.spacie.core.model.TransferProgress
import com.spacie.core.model.TrustState
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ObjCObjectVar
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.value
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.flow
import platform.Foundation.NSError
import platform.Foundation.NSFileManager
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUUID

/**
 * Per-item transfer loop (extract → archive → install) and device-list polling.
 *
 * Extracted from `DeviceServiceImpl` (Sprint 4.5 god-class split). Composes
 * [IpaToolClient] (for IPA download), [IDeviceClient] (for trust + install),
 * and [IpaArchiveWriterApi] (for the optional archive copy) — none of those
 * collaborators know about transfer state or progress emission, which keeps
 * each layer testable in isolation.
 *
 * ## NOT USED FROM THE SWIFT macOS APP
 *
 * The production macOS Swift app (`KMPDeviceServiceAdapter`) implements its
 * own `transferApps` and `observeDevices` loops natively — see
 * `Spacie/Core/KMPBridge/KMPDeviceServiceAdapter.swift`. The Swift
 * implementation is preferred there because:
 *  - KMP `CommonFlow.watch()` deadlocks under Swift structured concurrency
 *    (documented in memory + iter1 audit).
 *  - The Swift loop integrates with iTransferViewModel's task tracking
 *    (cancellation, isTransferInFlight flag, generation counters) which
 *    has no equivalent in this KMP class.
 *
 * This KMP class remains for **future Compose Desktop / non-Swift
 * consumers**. Any change to the transfer flow MUST be mirrored across
 * both implementations until the dead code is formally removed.
 */
internal class TransferOrchestrator(
    private val ipaTool: IpaToolClientApi,
    private val iDevice: IDeviceClientApi,
    private val archiveWriter: IpaArchiveWriterApi,
) {

    /**
     * Cold flow that walks [apps] sequentially. Each iteration emits a fresh
     * [TransferProgress] snapshot with the current item's phase advanced.
     *
     * Cancellation: respects the collector's [currentCoroutineContext] — when
     * the caller's scope is cancelled, the loop breaks at the next iteration.
     */
    fun transferApps(
        sourceUDID: String,
        destinationUDID: String?,
        apps: List<AppInfo>,
        archiveDir: String?,
        shouldInstall: Boolean
    ): CommonFlow<TransferProgress> = flow {
        var items = apps.map {
            TransferItem(
                id = it.bundleID,
                app = it,
                phase = TransferPhase.PENDING,
                progress = 0.0,
                errorMessage = null
            )
        }

        val fm = NSFileManager.defaultManager

        for (i in items.indices) {
            currentCoroutineContext().ensureActive()
            val app = items[i].app

            // NSTemporaryDirectory() may or may not end with a trailing `/`
            // depending on macOS version / config. Normalize so the
            // resulting path is never `…//<uuid>`, which would cause
            // removeItemAtPath cleanup to silently fail on some platforms.
            val tempBase = NSTemporaryDirectory().removeSuffix("/")
            val tempDir = "$tempBase/${NSUUID().UUIDString}"
            val dirCreated = memScoped {
                val errorPtr = alloc<ObjCObjectVar<NSError?>>()
                fm.createDirectoryAtPath(
                    tempDir,
                    withIntermediateDirectories = true,
                    attributes = null,
                    error = errorPtr.ptr
                )
            }

            if (!dirCreated) {
                items = items.markFailed(i, reason = "Failed to create temp dir")
                emit(TransferProgress(items, i))
                continue
            }

            try {
                items = items.transitionTo(i, TransferPhase.EXTRACTING)
                emit(TransferProgress(items, i))

                // Per-item progress is recorded into the in-memory items
                // snapshot so the next phase boundary emit carries the
                // latest value. Emitting from the synchronous onProgress
                // callback would require crossing into the flow's
                // coroutine — risky from K/N off-thread callbacks — so
                // intra-phase progress is rendered as a step rather than a
                // smooth bar. Acceptable for the current Compose consumer;
                // the Swift adapter has its own per-progress emit loop.
                val ipaPath = ipaTool.downloadIPA(
                    bundleID = app.bundleID,
                    destinationDir = tempDir,
                    onProgress = { progress ->
                        items = items.updateProgress(i, progress)
                    }
                )

                if (archiveDir != null) {
                    items = items.transitionTo(i, TransferPhase.ARCHIVING)
                    emit(TransferProgress(items, i))
                    archiveWriter.write(ipaPath = ipaPath, app = app, archiveDir = archiveDir)
                }

                if (shouldInstall && destinationUDID != null) {
                    items = items.transitionTo(i, TransferPhase.INSTALLING)
                    emit(TransferProgress(items, i))
                    iDevice.installIPA(
                        udid = destinationUDID,
                        ipaPath = ipaPath,
                        onProgress = { progress ->
                            items = items.updateProgress(i, progress)
                        }
                    )
                }

                items = items.markCompleted(i)
                emit(TransferProgress(items, i))
            } catch (e: CancellationException) {
                // kotlinx.coroutines.CancellationException and
                // kotlin.coroutines.cancellation.CancellationException are
                // the SAME class — the previous second `catch` block was
                // unreachable dead code and would mislead anyone adding
                // logic inside it.
                throw e
            } catch (e: Exception) {
                items = items.markFailed(i, reason = e.message)
                emit(TransferProgress(items, i))
            } finally {
                // Surface tempDir cleanup failures via errorPtr instead of
                // dropping them — silent fails let aborted transfers accumulate
                // partial dirs under NSTemporaryDirectory.
                memScoped {
                    val errorPtr = alloc<ObjCObjectVar<NSError?>>()
                    fm.removeItemAtPath(tempDir, error = errorPtr.ptr)
                    val err = errorPtr.value
                    if (err != null) {
                        println("[TransferOrchestrator] tempDir cleanup failed at $tempDir: ${err.localizedDescription}")
                    }
                }
            }
        }
    }.asCommonFlow()

    /**
     * Polls [IDeviceClient.listDevices] every [pollingIntervalSeconds] (>= 1.0)
     * and emits connected / disconnected / trust-state-changed events.
     */
    fun observeDevices(pollingIntervalSeconds: Double): CommonFlow<DeviceEvent> {
        val interval = maxOf(1.0, pollingIntervalSeconds)
        return flow {
            var knownUDIDs = emptySet<String>()
            val knownTrustStates = mutableMapOf<String, TrustState>()

            while (true) {
                try {
                    val devices = iDevice.listDevices()
                    val currentUDIDs = devices.map { it.udid }.toSet()

                    for (device in devices) {
                        if (device.udid !in knownUDIDs) {
                            emit(DeviceEvent.Connected(device))
                        }
                    }

                    for (udid in knownUDIDs) {
                        if (udid !in currentUDIDs) {
                            emit(DeviceEvent.Disconnected(udid))
                            knownTrustStates.remove(udid)
                        }
                    }

                    knownUDIDs = currentUDIDs

                    // Validate trust for all devices in parallel — sequential
                    // N×5s timeouts would make the polling interval depend on
                    // device count (timing drift). `supervisorScope` isolates
                    // per-device failures so one ideviceinfo crash or
                    // cancellation doesn't kill all siblings; `awaitAll`
                    // would otherwise rethrow into the outer scope and abort
                    // every parallel branch.
                    val trustResults: List<Pair<String, TrustState>> = supervisorScope {
                        devices.map { device ->
                            async {
                                currentCoroutineContext().ensureActive()
                                try {
                                    device.udid to iDevice.validateTrust(device.udid)
                                } catch (e: CancellationException) {
                                    // Rethrow cancellation — runCatching here
                                    // would swallow CE and delay the polling
                                    // loop's response to cancellation by a
                                    // full interval.
                                    throw e
                                } catch (_: Throwable) {
                                    device.udid to TrustState.NOT_TRUSTED
                                }
                            }
                        }.awaitAll()
                    }

                    for ((udid, newState) in trustResults) {
                        if (knownTrustStates[udid] != newState) {
                            knownTrustStates[udid] = newState
                            emit(DeviceEvent.TrustStateChanged(udid, newState))
                        }
                    }
                } catch (e: CancellationException) {
                    // Single CancellationException class (see above).
                    throw e
                } catch (e: Exception) {
                    emit(DeviceEvent.Error(e.message ?: "Unknown error"))
                }

                delay((interval * 1000).toLong())
            }
        }.asCommonFlow()
    }

    // -- private extension helpers --

    private fun List<TransferItem>.transitionTo(index: Int, phase: TransferPhase): List<TransferItem> =
        toMutableList().also { it[index] = it[index].copy(phase = phase) }

    private fun List<TransferItem>.markCompleted(index: Int): List<TransferItem> =
        toMutableList().also { it[index] = it[index].copy(phase = TransferPhase.COMPLETED, progress = 1.0) }

    private fun List<TransferItem>.markFailed(index: Int, reason: String?): List<TransferItem> =
        toMutableList().also {
            it[index] = it[index].copy(phase = TransferPhase.FAILED, errorMessage = reason)
        }

    private fun List<TransferItem>.updateProgress(index: Int, progress: Double): List<TransferItem> =
        toMutableList().also { it[index] = it[index].copy(progress = progress) }
}
