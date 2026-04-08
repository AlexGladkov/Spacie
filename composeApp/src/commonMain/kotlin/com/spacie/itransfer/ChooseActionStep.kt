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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun ChooseActionStep(state: ITransferState, viewModel: ITransferViewModel) {
    var archiveDirInput by remember { mutableStateOf(state.archiveDir ?: "") }

    Box(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(
            modifier = Modifier.widthIn(max = 600.dp).fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(
                text = "Choose Transfer Action",
                style = MaterialTheme.typography.headlineSmall
            )
            Text(
                text = "${state.selectedBundleIDs.size} app${if (state.selectedBundleIDs.size == 1) "" else "s"} selected",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            // Action selection card
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant
                )
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text("What to do with selected apps:", style = MaterialTheme.typography.titleSmall)
                    Spacer(modifier = Modifier.height(8.dp))

                    ActionOption(
                        selected = state.archiveOnly,
                        title = "Archive Only",
                        subtitle = "Save IPAs to a folder on this Mac",
                        onClick = { viewModel.setArchiveOnly(true) }
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    ActionOption(
                        selected = !state.archiveOnly,
                        title = "Archive + Install on Destination",
                        subtitle = "Save IPAs and install them on another iPhone",
                        onClick = { viewModel.setArchiveOnly(false) }
                    )
                }
            }

            // Archive directory picker
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceVariant
                )
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text("Archive Folder (optional)", style = MaterialTheme.typography.titleSmall)
                    Text(
                        text = "IPAs will be saved here. Leave blank to use a temporary folder.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(8.dp))

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        OutlinedTextField(
                            value = archiveDirInput,
                            onValueChange = {
                                archiveDirInput = it
                                viewModel.setArchiveDir(it)
                            },
                            label = { Text("Folder path") },
                            placeholder = { Text("/Users/you/Spacie/Archives") },
                            singleLine = true,
                            modifier = Modifier.weight(1f)
                        )
                        TextButton(
                            onClick = {
                                val picked = pickFolder()
                                if (picked != null) {
                                    archiveDirInput = picked
                                    viewModel.setArchiveDir(picked)
                                }
                            }
                        ) {
                            Text("Browse...")
                        }
                    }
                }
            }

            state.lastError?.let { err ->
                ErrorBanner(message = err)
            }

            Button(
                onClick = { viewModel.proceedFromChooseAction() },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Continue")
            }
        }
    }
}

@Composable
private fun ActionOption(
    selected: Boolean,
    title: String,
    subtitle: String,
    onClick: () -> Unit
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
    ) {
        RadioButton(selected = selected, onClick = onClick)
        Spacer(modifier = Modifier.width(8.dp))
        Column {
            Text(text = title, style = MaterialTheme.typography.bodyMedium)
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

/**
 * Opens a native folder picker dialog.
 * Returns the selected path or null if cancelled.
 * Implemented per-platform in expect/actual.
 */
expect fun pickFolder(): String?
