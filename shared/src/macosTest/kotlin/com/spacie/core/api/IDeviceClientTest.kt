package com.spacie.core.api

import com.spacie.core.api.internal.ToolPaths
import com.spacie.core.error.SpacieError
import com.spacie.core.model.TrustState
import com.spacie.core.platform.FakeProcessRunner
import com.spacie.core.platform.HomebrewResolver
import com.spacie.core.platform.ProcessResult
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class IDeviceClientTest {

    private val paths = StubToolPaths(
        mapOf(
            "idevice_id" to "/opt/homebrew/bin/idevice_id",
            "ideviceinfo" to "/opt/homebrew/bin/ideviceinfo",
            "idevicepair" to "/opt/homebrew/bin/idevicepair",
            "ideviceinstaller" to "/opt/homebrew/bin/ideviceinstaller",
        )
    )

    @Test
    fun listDevices_parsesUDIDs_andFetchesPerDeviceInfo() = runTest {
        val runner = FakeProcessRunner()
        runner.stubResult(
            "/opt/homebrew/bin/idevice_id",
            listOf("-l")
        ) {
            ProcessResult(
                stdout = "00008030-001A2B3C4D5E6F70\n00008101-0001020304050607\n".encodeToByteArray(),
                stderr = ByteArray(0),
                exitCode = 0
            )
        }
        runner.stubResult(
            "/opt/homebrew/bin/ideviceinfo",
            listOf("-u", "00008030-001A2B3C4D5E6F70")
        ) {
            ProcessResult(
                stdout = """
                    DeviceName: iPhone Artyom
                    ProductType: iPhone16,1
                    ProductVersion: 18.3.1
                    BuildVersion: 22D72
                """.trimIndent().encodeToByteArray(),
                stderr = ByteArray(0),
                exitCode = 0
            )
        }
        runner.stubResult(
            "/opt/homebrew/bin/ideviceinfo",
            listOf("-u", "00008101-0001020304050607")
        ) {
            ProcessResult(
                stdout = "DeviceName: iPhone 12\nProductVersion: 17.5".encodeToByteArray(),
                stderr = ByteArray(0),
                exitCode = 0
            )
        }

        val client = IDeviceClient(runner, paths)
        val devices = client.listDevices()

        assertEquals(2, devices.size)
        assertEquals("iPhone Artyom", devices[0].deviceName)
        assertEquals("18.3.1", devices[0].productVersion)
        assertEquals("iPhone 12", devices[1].deviceName)
    }

    @Test
    fun listDevices_filtersOutInvalidUDIDs() = runTest {
        val runner = FakeProcessRunner()
        runner.stubResult(
            "/opt/homebrew/bin/idevice_id",
            listOf("-l")
        ) {
            ProcessResult(
                stdout = "garbage-not-a-udid\n   \n".encodeToByteArray(),
                stderr = ByteArray(0),
                exitCode = 0
            )
        }

        val client = IDeviceClient(runner, paths)
        assertTrue(client.listDevices().isEmpty())
    }

    @Test
    fun validateTrust_returnsTrusted_whenExit0() = runTest {
        val runner = FakeProcessRunner()
        val udid = "00008030-001A2B3C4D5E6F70"
        runner.stubResult(
            "/opt/homebrew/bin/idevicepair",
            listOf("validate", "-u", udid)
        ) { ProcessResult("validate success".encodeToByteArray(), ByteArray(0), exitCode = 0) }

        val client = IDeviceClient(runner, paths)
        assertEquals(TrustState.TRUSTED, client.validateTrust(udid))
    }

    @Test
    fun validateTrust_returnsDialogShown_whenStderrHasPairingDialog() = runTest {
        val runner = FakeProcessRunner()
        val udid = "00008030-001A2B3C4D5E6F70"
        runner.stubResult(
            "/opt/homebrew/bin/idevicepair",
            listOf("validate", "-u", udid)
        ) {
            ProcessResult(
                stdout = ByteArray(0),
                stderr = "ERROR: pairing_dialog_response_pending".encodeToByteArray(),
                exitCode = 1
            )
        }

        val client = IDeviceClient(runner, paths)
        assertEquals(TrustState.DIALOG_SHOWN, client.validateTrust(udid))
    }

    @Test
    fun validateTrust_returnsNotTrusted_onAnyError() = runTest {
        val runner = FakeProcessRunner()
        val udid = "00008030-001A2B3C4D5E6F70"
        runner.stubResult(
            "/opt/homebrew/bin/idevicepair",
            listOf("validate", "-u", udid)
        ) { ProcessResult(ByteArray(0), "denied".encodeToByteArray(), exitCode = 255) }

        val client = IDeviceClient(runner, paths)
        assertEquals(TrustState.NOT_TRUSTED, client.validateTrust(udid))
    }

    @Test
    fun validateTrust_returnsNotTrusted_onInvalidUDID() = runTest {
        val runner = FakeProcessRunner()
        val client = IDeviceClient(runner, paths)
        assertEquals(TrustState.NOT_TRUSTED, client.validateTrust("bad-udid"))
        assertEquals(0, runner.invocations.size, "must not spawn for invalid udid")
    }

    @Test
    fun listApps_throwsProcessExitedWithError_onNonZeroExit() = runTest {
        val runner = FakeProcessRunner()
        val udid = "00008030-001A2B3C4D5E6F70"
        runner.stubResult(
            "/opt/homebrew/bin/ideviceinstaller",
            listOf("-u", udid, "list", "--xml")
        ) {
            ProcessResult(
                stdout = ByteArray(0),
                stderr = "tool error".encodeToByteArray(),
                exitCode = 2
            )
        }

        val client = IDeviceClient(runner, paths)
        val err = assertFailsWith<SpacieError.ProcessExitedWithError> {
            client.listApps(udid)
        }
        assertEquals("ideviceinstaller", err.tool)
        assertEquals(2, err.exitCode)
    }
}

