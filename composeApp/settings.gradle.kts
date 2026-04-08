rootProject.name = "SpacieCompose"

pluginManagement {
    repositories {
        gradlePluginPortal()
        maven("https://maven.pkg.jetbrains.space/public/p/compose/dev")
        google()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
        google()
        maven("https://maven.pkg.jetbrains.space/public/p/compose/dev")
    }
}

// Composite build: shared module provides com.spacie:SpacieKit
includeBuild("../shared") {
    dependencySubstitution {
        substitute(module("com.spacie:SpacieKit")).using(project(":"))
    }
}
