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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.spacie.core.api.DependencyStatus

@Composable
fun DependencyCheckStep(state: ITransferState, viewModel: ITransferViewModel) {
    Box(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 600.dp)
                .fillMaxWidth()
                .verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Text(
                text = "Spacie — iOS App Transfer",
                style = MaterialTheme.typography.headlineMedium,
                color = MaterialTheme.colorScheme.primary
            )

            Spacer(modifier = Modifier.height(8.dp))

            // Dependency status card
            DependencyStatusCard(state, viewModel)

            // Apple ID login card — shown when deps are ready but not authenticated
            val status = state.dependencyStatus
            if (status is DependencyStatus.Ready && !state.appleIDAuthenticated) {
                AppleIDLoginCard(state, viewModel)
            }

            // Error banner
            state.lastError?.let { err ->
                ErrorBanner(message = err)
            }
        }
    }
}

@Composable
private fun DependencyStatusCard(state: ITransferState, viewModel: ITransferViewModel) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text("Required Tools", style = MaterialTheme.typography.titleMedium)
            Spacer(modifier = Modifier.height(12.dp))

            when (val status = state.dependencyStatus) {
                null -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                        Text(
                            text = "  Checking dependencies...",
                            style = MaterialTheme.typography.bodyMedium
                        )
                    }
                }
                is DependencyStatus.Ready -> {
                    StatusRow(
                        label = "Tools ready",
                        ok = true,
                        detail = "${status.toolPaths.size} tools found"
                    )
                }
                is DependencyStatus.Missing -> {
                    StatusRow(
                        label = "Missing tools",
                        ok = false,
                        detail = status.tools.joinToString(", ")
                    )
                    Spacer(modifier = Modifier.height(12.dp))

                    if (state.isInstallingDeps) {
                        Column {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    strokeWidth = 2.dp
                                )
                                Text(
                                    text = "  Installing dependencies...",
                                    style = MaterialTheme.typography.bodySmall
                                )
                            }
                            if (state.installOutput.isNotEmpty()) {
                                Spacer(modifier = Modifier.height(8.dp))
                                InstallLogPanel(lines = state.installOutput)
                            }
                        }
                    } else {
                        Button(
                            onClick = { viewModel.installDependencies() },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text("Install Dependencies")
                        }
                    }
                }
                is DependencyStatus.PackageManagerMissing -> {
                    StatusRow(
                        label = "${status.managerName} not found",
                        ok = false,
                        detail = "Install ${status.managerName} from ${status.installUrl}"
                    )
                }
            }
        }
    }
}

@Composable
private fun AppleIDLoginCard(state: ITransferState, viewModel: ITransferViewModel) {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var twoFactorCode by remember { mutableStateOf("") }

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text("Apple ID", style = MaterialTheme.typography.titleMedium)
            Text(
                text = "Required to download IPA files from the App Store",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(12.dp))

            if (!state.appleIDNeedsTwoFactor) {
                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    label = { Text("Email") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text("Password") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    modifier = Modifier.fillMaxWidth()
                )
            } else {
                Text(
                    text = "Two-factor code sent to ${state.appleIDEmailForTwoFactor}",
                    style = MaterialTheme.typography.bodySmall
                )
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedTextField(
                    value = twoFactorCode,
                    onValueChange = { twoFactorCode = it },
                    label = { Text("Authentication Code") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth()
                )
            }

            state.appleIDLoginError?.let { err ->
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = err,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error
                )
            }

            Spacer(modifier = Modifier.height(12.dp))

            if (state.isAuthenticatingAppleID || state.isCheckingAppleID) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                    Text("  Signing in...", style = MaterialTheme.typography.bodySmall)
                }
            } else {
                Button(
                    onClick = {
                        if (state.appleIDNeedsTwoFactor) {
                            viewModel.loginAppleIDWithTwoFactor(
                                email = state.appleIDEmailForTwoFactor,
                                password = password,
                                code = twoFactorCode
                            )
                        } else {
                            viewModel.loginAppleID(email, password)
                        }
                    },
                    enabled = if (state.appleIDNeedsTwoFactor) {
                        twoFactorCode.isNotBlank()
                    } else {
                        email.isNotBlank() && password.isNotBlank()
                    },
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(if (state.appleIDNeedsTwoFactor) "Verify Code" else "Sign In")
                }
            }
        }
    }
}

@Composable
private fun InstallLogPanel(lines: List<String>) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        ),
        modifier = Modifier.fillMaxWidth().height(150.dp)
    ) {
        val scrollState = rememberScrollState(Int.MAX_VALUE)
        Column(
            modifier = Modifier
                .padding(8.dp)
                .verticalScroll(scrollState)
        ) {
            lines.forEach { line ->
                Text(
                    text = line,
                    style = MaterialTheme.typography.bodySmall.copy(
                        fontFamily = FontFamily.Monospace
                    ),
                    color = MaterialTheme.colorScheme.onSurface
                )
            }
        }
    }
}

@Composable
private fun StatusRow(label: String, ok: Boolean, detail: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Text(
            text = if (ok) "+" else "x",
            color = if (ok) Color(0xFF2E7D32) else MaterialTheme.colorScheme.error,
            style = MaterialTheme.typography.titleMedium
        )
        Column {
            Text(text = label, style = MaterialTheme.typography.bodyMedium)
            Text(
                text = detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
fun ErrorBanner(message: String) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer
        )
    ) {
        Text(
            text = message,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onErrorContainer,
            modifier = Modifier.padding(12.dp)
        )
    }
}
