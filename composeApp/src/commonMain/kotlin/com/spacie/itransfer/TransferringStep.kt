package com.spacie.itransfer

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.spacie.core.model.TransferItem
import com.spacie.core.model.TransferPhase

@Composable
fun TransferringStep(state: ITransferState, viewModel: ITransferViewModel) {
    // Auto-start transfer when this step is entered
    LaunchedEffect(Unit) {
        viewModel.startTransfer()
    }

    val progress = state.transferProgress
    val overallProgress = progress?.overallProgress?.toFloat() ?: 0f
    val completedCount = progress?.completedCount ?: 0
    val totalCount = progress?.totalCount ?: state.selectedBundleIDs.size

    Box(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        Column(
            modifier = Modifier
                .widthIn(max = 600.dp)
                .fillMaxSize()
                .align(Alignment.TopCenter),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(
                text = "Transferring Apps...",
                style = MaterialTheme.typography.headlineSmall
            )

            // Overall progress
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant
                )
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(
                        horizontalArrangement = Arrangement.SpaceBetween,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Text(
                            text = "$completedCount / $totalCount apps",
                            style = MaterialTheme.typography.bodyMedium
                        )
                        Text(
                            text = "${(overallProgress * 100).toInt()}%",
                            style = MaterialTheme.typography.bodyMedium
                        )
                    }
                    Spacer(modifier = Modifier.height(8.dp))
                    LinearProgressIndicator(
                        progress = { overallProgress },
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }

            // Per-app progress list
            if (progress != null) {
                LazyColumn(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    items(progress.items, key = { it.id }) { item ->
                        TransferItemRow(item = item)
                    }
                }
            } else {
                Box(
                    modifier = Modifier.weight(1f),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = "Preparing transfer...",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            Button(
                onClick = { viewModel.cancelTransfer() },
                colors = ButtonDefaults.buttonColors(
                    containerColor = MaterialTheme.colorScheme.error
                ),
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Cancel Transfer")
            }
        }
    }
}

@Composable
private fun TransferItemRow(item: TransferItem) {
    val (phaseLabel, phaseColor) = phaseDisplayInfo(item.phase)

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = when (item.phase) {
                TransferPhase.COMPLETED -> Color(0xFFE8F5E9)
                TransferPhase.FAILED -> MaterialTheme.colorScheme.errorContainer
                else -> MaterialTheme.colorScheme.surface
            }
        )
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(
                text = phaseLabel,
                style = MaterialTheme.typography.titleSmall,
                color = phaseColor,
                modifier = Modifier.widthIn(min = 20.dp)
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = item.app.displayName,
                    style = MaterialTheme.typography.bodyMedium
                )
                if (item.phase != TransferPhase.COMPLETED && item.phase != TransferPhase.FAILED) {
                    Text(
                        text = phaseLabel,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                item.errorMessage?.let { err ->
                    Text(
                        text = err,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error
                    )
                }
            }
            if (item.phase != TransferPhase.COMPLETED && item.phase != TransferPhase.FAILED &&
                item.phase != TransferPhase.PENDING
            ) {
                LinearProgressIndicator(
                    progress = { item.progress.toFloat() },
                    modifier = Modifier.widthIn(max = 80.dp)
                )
            }
        }
    }
}

private fun phaseDisplayInfo(phase: TransferPhase): Pair<String, Color> = when (phase) {
    TransferPhase.PENDING -> Pair("-", Color(0xFF9E9E9E))
    TransferPhase.EXTRACTING -> Pair("~", Color(0xFF1565C0))
    TransferPhase.ARCHIVING -> Pair("~", Color(0xFF6A1B9A))
    TransferPhase.INSTALLING -> Pair("~", Color(0xFF0277BD))
    TransferPhase.COMPLETED -> Pair("+", Color(0xFF2E7D32))
    TransferPhase.FAILED -> Pair("x", Color(0xFFB71C1C))
}
