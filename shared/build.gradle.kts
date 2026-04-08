import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins {
    kotlin("multiplatform") version "2.1.20"
}

group = "com.spacie"
version = "1.0.0"

kotlin {
    val xcf = XCFramework("SpacieKit")

    macosArm64 {
        binaries.framework {
            baseName = "SpacieKit"
            isStatic = true
            xcf.add(this)
        }
    }

    macosX64 {
        binaries.framework {
            baseName = "SpacieKit"
            isStatic = true
            xcf.add(this)
        }
    }
    jvm()

    // Default hierarchy: commonMain -> appleMain -> macosMain (auto)
    applyDefaultHierarchyTemplate()

    // Suppress beta warnings for expect/actual classes
    compilerOptions {
        freeCompilerArgs.add("-Xexpect-actual-classes")
    }

    sourceSets {
        commonMain.dependencies {
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
        }
    }
}
