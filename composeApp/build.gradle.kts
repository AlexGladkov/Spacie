import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    kotlin("multiplatform") version "2.1.20"
    id("org.jetbrains.compose") version "1.7.3"
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.20"
}

kotlin {
    jvm("desktop")

    sourceSets {
        val desktopMain by getting

        commonMain.dependencies {
            implementation(compose.runtime)
            implementation(compose.foundation)
            implementation(compose.material3)
            implementation(compose.ui)
            implementation(compose.components.resources)
            implementation("com.spacie:SpacieKit")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-swing:1.9.0")
        }
        desktopMain.dependencies {
            implementation(compose.desktop.currentOs)
        }
    }
}

compose.desktop {
    application {
        mainClass = "com.spacie.MainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Msi, TargetFormat.Exe, TargetFormat.Deb)
            packageName = "Spacie"
            packageVersion = "1.0.0"
            description = "Spacie - iOS App Transfer"
            vendor = "Spacie"
            windows {
                menuGroup = "Spacie"
                upgradeUuid = "B1D0A3E5-7F2C-4A9B-8E6D-3C0F1A2B4E5D"
            }
        }
    }
}
