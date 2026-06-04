@file:OptIn(ExperimentalForeignApi::class)

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
import kotlinx.cinterop.ObjCObjectVar
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.isActive
import platform.Foundation.NSError
import platform.Foundation.NSFileManager
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUUID
import kotlin.coroutines.cancellation.CancellationException as KotlinCancellationException

/**
 * Per-item transfer loop (extract → archive → install) and device-list polling.
 *
 * Extracted from `DeviceServiceImpl` (Sprint 4.5 god-class split). Composes
 * [IpaToolClient] (for IPA download), [IDeviceClient] (for trust + install),
 * and [IpaArchiveWriter] (for the optional archive copy) — none of those
 * collaborators know about transfer state or progress emission, which keeps
 * each layer testable in isolation.
 */
internal class TransferOrchestrator(
    private val ipaTool: IpaToolClient,
    private val iDevice: IDeviceClient,
    private val archiveWriter: IpaArchiveWriter,
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
            if (!currentCoroutineContext().isActive) break
            val app = items[i].app

            val tempDir = NSTemporaryDirectory() + NSUUID().UUIDString
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

                val ipaPath = ipaTool.downloadIPA(
                    bundleID = app.bundleID,
                    destinationDir = tempDir,
                    onProgress = {}
                )

                if (archiveDir != null) {
                    items = items.transitionTo(i, TransferPhase.ARCHIVING)
                    emit(TransferProgress(items, i))
                    archiveWriter.write(ipaPath = ipaPath, app = app, archiveDir = archiveDir)
                }

                if (shouldInstall && destinationUDID != null) {
                    items = items.transitionTo(i, TransferPhase.INSTALLING)
                    emit(TransferProgress(items, i))
                    iDevice.installIPA(udid = destinationUDID, ipaPath = ipaPath, onProgress = {})
                }

                items = items.markCompleted(i)
                emit(TransferProgress(items, i))
            } catch (e: CancellationException) {
                throw e
            } catch (e: KotlinCancellationException) {
                throw e
            } catch (e: Exception) {
                items = items.markFailed(i, reason = e.message)
                emit(TransferProgress(items, i))
            } finally {
                fm.removeItemAtPath(tempDir, error = null)
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

                    for (device in devices) {
                        val newState = iDevice.validateTrust(device.udid)
                        if (knownTrustStates[device.udid] != newState) {
                            knownTrustStates[device.udid] = newState
                            emit(DeviceEvent.TrustStateChanged(device.udid, newState))
                        }
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: KotlinCancellationException) {
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
}
