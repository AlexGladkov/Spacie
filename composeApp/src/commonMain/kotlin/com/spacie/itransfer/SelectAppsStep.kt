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
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.spacie.core.model.AppInfo

@Composable
fun SelectAppsStep(state: ITransferState, viewModel: ITransferViewModel) {
    val selectedCount = state.selectedBundleIDs.size
    val totalCount = state.availableApps.size

    Box(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        Column(
            modifier = Modifier
                .widthIn(max = 600.dp)
                .fillMaxSize()
                .align(Alignment.TopCenter)
        ) {
            Text(
                text = "Select Apps to Transfer",
                style = MaterialTheme.typography.headlineSmall
            )
            Text(
                text = "$totalCount apps found on ${state.sourceDevice?.deviceName ?: "device"}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(12.dp))

            // Selection controls
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                TextButton(onClick = { viewModel.selectAllApps() }) {
                    Text("Select All")
                }
                TextButton(onClick = { viewModel.deselectAllApps() }) {
                    Text("Deselect All")
                }
                Spacer(modifier = Modifier.weight(1f))
                Text(
                    text = "$selectedCount selected",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            HorizontalDivider()

            // App list
            LazyColumn(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                items(state.availableApps, key = { it.bundleID }) { app ->
                    AppRow(
                        app = app,
                        isSelected = state.selectedBundleIDs.contains(app.bundleID),
                        onToggle = { viewModel.toggleApp(app.bundleID) }
                    )
                }
            }

            HorizontalDivider()
            Spacer(modifier = Modifier.height(12.dp))

            state.lastError?.let { err ->
                ErrorBanner(message = err)
                Spacer(modifier = Modifier.height(8.dp))
            }

            Button(
                onClick = { viewModel.proceedFromSelectApps() },
                enabled = selectedCount > 0,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    if (selectedCount > 0) "Continue with $selectedCount app${if (selectedCount == 1) "" else "s"}"
                    else "Select at least one app"
                )
            }
        }
    }
}

@Composable
private fun AppRow(
    app: AppInfo,
    isSelected: Boolean,
    onToggle: () -> Unit
) {
    Card(
        onClick = onToggle,
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = if (isSelected) {
                MaterialTheme.colorScheme.primaryContainer
            } else {
                MaterialTheme.colorScheme.surface
            }
        )
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Checkbox(
                checked = isSelected,
                onCheckedChange = { onToggle() }
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = app.displayName,
                    style = MaterialTheme.typography.bodyMedium
                )
                Text(
                    text = app.bundleID,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Column(horizontalAlignment = Alignment.End) {
                Text(
                    text = "v${app.shortVersion}",
                    style = MaterialTheme.typography.bodySmall
                )
                app.ipaSize?.let { size ->
                    Text(
                        text = formatSize(size),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

private fun formatSize(bytes: Long): String {
    return when {
        bytes >= 1_073_741_824L -> "%.1f GB".format(bytes / 1_073_741_824.0)
        bytes >= 1_048_576L -> "%.1f MB".format(bytes / 1_048_576.0)
        bytes >= 1024L -> "%.0f KB".format(bytes / 1024.0)
        else -> "$bytes B"
    }
}
