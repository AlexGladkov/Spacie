package com.spacie.core.api

import com.spacie.core.error.SpacieError
import com.spacie.core.model.TransferPhase
import com.spacie.core.model.TransferProgress
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TransferOrchestratorTest {

    private fun makeOrchestrator(
        ipaTool: IpaToolClientApi = FakeIpaToolClient(),
        iDevice: IDeviceClientApi = FakeIDeviceClient(),
        archiveWriter: IpaArchiveWriterApi = FakeIpaArchiveWriter(),
    ): TransferOrchestrator = TransferOrchestrator(ipaTool, iDevice, archiveWriter)

    // -- transferApps --

    @Test
    fun transferApps_archiveOnly_singleApp_emitsExtractingArchivingCompleted() = runTest {
        val archive = FakeIpaArchiveWriter()
        val orchestrator = makeOrchestrator(archiveWriter = archive)

        val emissions = orchestrator.transferApps(
            sourceUDID = "SRC",
            destinationUDID = null,
            apps = listOf(fakeApp("com.a.one")),
            archiveDir = "/tmp/archive",
            shouldInstall = false,
        ).toList()

        val phases = emissions.map { it.items[0].phase }
        assertEquals(
            listOf(TransferPhase.EXTRACTING, TransferPhase.ARCHIVING, TransferPhase.COMPLETED),
            phases
        )
        assertEquals(1, archive.writeCalls.size)
        assertEquals("com.a.one", archive.writeCalls[0].second)
    }

    @Test
    fun transferApps_install_singleApp_emitsExtractingInstallingCompleted() = runTest {
        val iDevice = FakeIDeviceClient()
        val orchestrator = makeOrchestrator(iDevice = iDevice)

        val emissions = orchestrator.transferApps(
            sourceUDID = "SRC",
            destinationUDID = "DST",
            apps = listOf(fakeApp("com.a.one")),
            archiveDir = null,
            shouldInstall = true,
        ).toList()

        val phases = emissions.map { it.items[0].phase }
        assertEquals(
            listOf(TransferPhase.EXTRACTING, TransferPhase.INSTALLING, TransferPhase.COMPLETED),
            phases
        )
        assertEquals(1, iDevice.installIPACalls.size)
        assertEquals("DST", iDevice.installIPACalls[0].first)
    }

    @Test
    fun transferApps_extractFailure_marksItemFailedAndContinuesNextApps() = runTest {
        val ipa = FakeIpaToolClient()
        ipa.downloadIPABehaviour = { bundleID, _ ->
            if (bundleID == "com.fail.one") throw SpacieError.ExtractionFailed(bundleID, "boom")
            "/tmp/$bundleID.ipa"
        }
        val orchestrator = makeOrchestrator(ipaTool = ipa)

        val emissions = orchestrator.transferApps(
            sourceUDID = "SRC",
            destinationUDID = null,
            apps = listOf(fakeApp("com.fail.one"), fakeApp("com.ok.two")),
            archiveDir = "/tmp/archive",
            shouldInstall = false,
        ).toList()

        val final = emissions.last()
        assertEquals(TransferPhase.FAILED, final.items[0].phase)
        assertNotNull(final.items[0].errorMessage)
        assertEquals(TransferPhase.COMPLETED, final.items[1].phase)
        assertNull(final.items[1].errorMessage)
    }

    @Test
    fun transferApps_installFailure_marksItemFailedButDoesNotThrow() = runTest {
        val iDevice = FakeIDeviceClient()
        iDevice.installIPABehaviour = { _, ipaPath ->
            throw SpacieError.InstallFailed(ipaPath, "FairPlay")
        }
        val orchestrator = makeOrchestrator(iDevice = iDevice)

        val emissions = orchestrator.transferApps(
            sourceUDID = "SRC",
            destinationUDID = "DST",
            apps = listOf(fakeApp("com.x.one")),
            archiveDir = null,
            shouldInstall = true,
        ).toList()

        val final = emissions.last()
        assertEquals(TransferPhase.FAILED, final.items[0].phase)
        assertNotNull(final.items[0].errorMessage)
    }

    @Test
    fun transferApps_emptyApps_emitsNothingAndCompletesGracefully() = runTest {
        val orchestrator = makeOrchestrator()
        val emissions = orchestrator.transferApps(
            sourceUDID = "SRC",
            destinationUDID = null,
            apps = emptyList(),
            archiveDir = null,
            shouldInstall = false,
        ).toList()
        assertTrue(emissions.isEmpty(), "expected no emissions for empty app list")
    }

    @Test
    fun transferApps_archiveWriterFailure_marksItemFailedAndSubsequentAppsContinue() = runTest {
        val archive = FakeIpaArchiveWriter()
        archive.writeBehaviour = { _, app, _ ->
            if (app.bundleID == "com.bad.archive") {
                throw SpacieError.ArchiveWriteFailed("/tmp/archive/${app.bundleID}.ipa", "disk full")
            }
        }
        val orchestrator = makeOrchestrator(archiveWriter = archive)

        val emissions = orchestrator.transferApps(
            sourceUDID = "SRC",
            destinationUDID = null,
            apps = listOf(fakeApp("com.bad.archive"), fakeApp("com.good.archive")),
            archiveDir = "/tmp/archive",
            shouldInstall = false,
        ).toList()

        val final = emissions.last()
        assertEquals(TransferPhase.FAILED, final.items[0].phase)
        assertEquals(TransferPhase.COMPLETED, final.items[1].phase)
    }

    // -- observeDevices --

    @Test
    fun observeDevices_emitsConnectedForNewDevice() = runTest {
        val iDevice = FakeIDeviceClient()
        iDevice.devicesToReturn = listOf(fakeDevice("UDID-1"))
        iDevice.trustStateToReturn = com.spacie.core.model.TrustState.TRUSTED

        val orchestrator = makeOrchestrator(iDevice = iDevice)
        val first = orchestrator.observeDevices(pollingIntervalSeconds = 1.0).first()

        assertTrue(first is com.spacie.core.model.DeviceEvent.Connected)
        assertEquals("UDID-1", (first as com.spacie.core.model.DeviceEvent.Connected).device.udid)
    }
}
