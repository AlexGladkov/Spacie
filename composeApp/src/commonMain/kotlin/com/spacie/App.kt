package com.spacie

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import com.spacie.itransfer.ITransferScreen

private val AppColorScheme = lightColorScheme(
    primary = Color(0xFF4A6FA5),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFD6E4FF),
    onPrimaryContainer = Color(0xFF001C3E),
    secondary = Color(0xFF5A6A85),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFDDE3F3),
    onSecondaryContainer = Color(0xFF161C2C),
    surface = Color(0xFFF8F9FC),
    onSurface = Color(0xFF1A1C22),
    surfaceVariant = Color(0xFFE8ECF4),
    onSurfaceVariant = Color(0xFF42474F),
    background = Color(0xFFF3F5FA),
    onBackground = Color(0xFF1A1C22),
    outline = Color(0xFF72787E),
    error = Color(0xFFBA1A1A),
    onError = Color.White
)

@Composable
fun App() {
    MaterialTheme(colorScheme = AppColorScheme) {
        ITransferScreen()
    }
}
