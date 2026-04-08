package com.spacie.itransfer

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.spacie.core.model.TrustState

@Composable
fun ConnectDeviceStep(
    state: ITransferState,
    viewModel: ITransferViewModel,
    isSource: Boolean
) {
    val title = if (isSource) "Connect Source iPhone" else "Connect Destination iPhone"
    val subtitle = if (isSource) {
        "Connect the iPhone you want to transfer apps FROM"
    } else {
        "Connect the iPhone you want to transfer apps TO"
    }

    val device = if (isSource) state.sourceDevice else state.destinationDevice
    val trustState = if (isSource) state.sourceTrustState else state.destinationTrustState

    // Start observation on first composition
    LaunchedEffect(isSource) {
        if (isSource) {
            viewModel.startSourceDeviceObservation()
        } else {
            viewModel.startDestinationDeviceObservation()
        }
    }

    DisposableEffect(isSource) {
        onDispose {
            viewModel.stopDeviceObservation()
        }
    }

    Box(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(
            modifier = Modifier.widthIn(max = 600.dp).fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(text = title, style = MaterialTheme.typography.headlineSmall)
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(8.dp))

            if (device == null) {
                WaitingForDeviceCard()
            } else {
                DeviceFoundCard(
                    deviceName = device.deviceName,
                    productType = device.productType,
                    productVersion = device.productVersion,
                    trustState = trustState
                )
            }

            state.lastError?.let { err ->
                ErrorBanner(message = err)
            }
        }
    }
}

@Composable
private fun WaitingForDeviceCard() {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Column(
            modifier = Modifier.padding(24.dp).fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            val infiniteTransition = rememberInfiniteTransition()
            val rotation by infiniteTransition.animateFloat(
                initialValue = 0f,
                targetValue = 360f,
                animationSpec = infiniteRepeatable(
                    animation = tween(durationMillis = 1200, easing = LinearEasing),
                    repeatMode = RepeatMode.Restart
                )
            )
            CircularProgressIndicator(
                modifier = Modifier.size(48.dp).rotate(rotation),
                strokeWidth = 3.dp,
                color = MaterialTheme.colorScheme.primary
            )
            Text(
                text = "Waiting for iPhone...",
                style = MaterialTheme.typography.bodyLarge
            )
            Text(
                text = "Connect your iPhone via USB cable",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun DeviceFoundCard(
    deviceName: String,
    productType: String,
    productVersion: String,
    trustState: TrustState
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                // Device icon placeholder
                Box(
                    modifier = Modifier.size(48.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = "[]",
                        style = MaterialTheme.typography.headlineMedium,
                        color = MaterialTheme.colorScheme.primary
                    )
                }
                Column(modifier = Modifier.weight(1f)) {
                    Text(text = deviceName, style = MaterialTheme.typography.titleMedium)
                    Text(
                        text = "$productType  |  iOS $productVersion",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                TrustStateIndicator(trustState)
            }

            Spacer(modifier = Modifier.height(12.dp))

            TrustStateMessage(trustState)
        }
    }
}

@Composable
private fun TrustStateIndicator(trustState: TrustState) {
    val (symbol, color) = when (trustState) {
        TrustState.TRUSTED -> Pair("OK", Color(0xFF2E7D32))
        TrustState.DIALOG_SHOWN -> Pair("...", Color(0xFFF57F17))
        TrustState.NOT_TRUSTED -> Pair("!", MaterialTheme.colorScheme.error)
    }
    Text(
        text = symbol,
        style = MaterialTheme.typography.titleMedium,
        color = color
    )
}

@Composable
private fun TrustStateMessage(trustState: TrustState) {
    val (message, color) = when (trustState) {
        TrustState.TRUSTED -> Pair(
            "Device trusted — loading apps...",
            Color(0xFF2E7D32)
        )
        TrustState.DIALOG_SHOWN -> Pair(
            "Check your iPhone screen and tap \"Trust\"",
            Color(0xFFF57F17)
        )
        TrustState.NOT_TRUSTED -> Pair(
            "Tap \"Trust\" on your iPhone when prompted",
            MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        if (trustState != TrustState.TRUSTED) {
            CircularProgressIndicator(
                modifier = Modifier.size(14.dp),
                strokeWidth = 2.dp,
                color = color
            )
        }
        Text(
            text = message,
            style = MaterialTheme.typography.bodySmall,
            color = color
        )
    }
}
