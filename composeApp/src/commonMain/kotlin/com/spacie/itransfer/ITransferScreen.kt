package com.spacie.itransfer

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember

/**
 * Root composable for the iTransfer wizard.
 * Manages the [ITransferViewModel] lifecycle and delegates to step composables.
 */
@Composable
fun ITransferScreen(viewModel: ITransferViewModel = remember { ITransferViewModel() }) {
    val state by viewModel.state.collectAsState()

    // Trigger dependency check on first composition
    LaunchedEffect(Unit) {
        viewModel.checkDependencies()
    }

    // Release resources when the composable leaves composition
    DisposableEffect(viewModel) {
        onDispose {
            viewModel.onCleared()
        }
    }

    when (state.step) {
        ITransferStep.DEPENDENCY_CHECK -> DependencyCheckStep(state, viewModel)
        ITransferStep.CONNECT_SOURCE -> ConnectDeviceStep(state, viewModel, isSource = true)
        ITransferStep.SELECT_APPS -> SelectAppsStep(state, viewModel)
        ITransferStep.CHOOSE_ACTION -> ChooseActionStep(state, viewModel)
        ITransferStep.CONNECT_DESTINATION -> ConnectDeviceStep(state, viewModel, isSource = false)
        ITransferStep.TRANSFERRING -> TransferringStep(state, viewModel)
        ITransferStep.RESULT -> ResultStep(state, viewModel)
    }
}
