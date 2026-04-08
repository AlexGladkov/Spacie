package com.spacie

import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState

fun main() = application {
    Window(
        onCloseRequest = ::exitApplication,
        title = "Spacie — iOS App Transfer",
        state = rememberWindowState(width = 900.dp, height = 650.dp)
    ) {
        App()
    }
}
