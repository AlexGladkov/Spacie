package com.spacie.itransfer

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.spacie.core.model.TransferPhase

@Composable
fun ResultStep(state: ITransferState, viewModel: ITransferViewModel) {
    val successCount = state.transferSuccessCount
    val failCount = state.transferFailCount
    val allSuccess = failCount == 0 && successCount > 0
    val failedItems = state.transferProgress?.items?.filter { it.phase == TransferPhase.FAILED } ?: emptyList()

    Box(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(
            modifier = Modifier.widthIn(max = 600.dp).fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // Result icon
            Text(
                text = if (allSuccess) "+" else if (failCount > 0 && successCount > 0) "~" else "x",
                style = MaterialTheme.typography.displayMedium,
                color = when {
                    allSuccess -> Color(0xFF2E7D32)
                    failCount > 0 && successCount > 0 -> Color(0xFFF57F17)
                    else -> MaterialTheme.colorScheme.error
                }
            )

            // Summary card
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = if (allSuccess) {
                        Color(0xFFE8F5E9)
                    } else {
                        MaterialTheme.colorScheme.surfaceVariant
                    }
                )
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    if (successCount > 0) {
                        Text(
                            text = "$successCount app${if (successCount == 1) "" else "s"} transferred successfully",
                            style = MaterialTheme.typography.titleMedium,
                            color = Color(0xFF2E7D32)
                        )
                    }
                    if (failCount > 0) {
                        Spacer(modifier = Modifier.height(4.dp))
                        Text(
                            text = "$failCount app${if (failCount == 1) "" else "s"} failed",
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.error
                        )
                    }
                    state.archiveDir?.let { dir ->
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = "Archived to: $dir",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            // Failed items detail
            if (failedItems.isNotEmpty()) {
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.errorContainer
                    )
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text(
                            text = "Failed apps:",
                            style = MaterialTheme.typography.titleSmall,
                            color = MaterialTheme.colorScheme.onErrorContainer
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        failedItems.forEach { item ->
                            Text(
                                text = "${item.app.displayName}: ${item.errorMessage ?: "Unknown error"}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onErrorContainer
                            )
                            Spacer(modifier = Modifier.height(4.dp))
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(8.dp))

            Button(
                onClick = { viewModel.reset() },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Start Over")
            }
        }
    }
}
