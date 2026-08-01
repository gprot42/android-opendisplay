plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Single source of truth: repo-root version.md
val versionFile = rootProject.projectDir.resolve("../version.md")
val appVersion = versionFile
    .takeIf { it.isFile }
    ?.readText()
    ?.lineSequence()
    ?.map { it.trim() }
    ?.firstOrNull { it.isNotEmpty() && !it.startsWith("#") }
    ?: error("Missing or empty version in ${versionFile.normalize()}")

fun versionCodeFrom(version: String): Int {
    val parts = version.removePrefix("v").split(".").map { it.toIntOrNull() ?: 0 }
    val major = parts.getOrElse(0) { 0 }
    val minor = parts.getOrElse(1) { 0 }
    val patch = parts.getOrElse(2) { 0 }
    return major * 10000 + minor * 100 + patch
}

android {
    namespace = "app.opendisplay.receiver"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.opendisplay.receiver"
        minSdk = 26
        targetSdk = 35
        versionCode = versionCodeFrom(appVersion)
        versionName = appVersion
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

// Versioned APK names, e.g. OpenDisplay-0.0.2-debug.apk
android.applicationVariants.configureEach {
    val variant = this
    outputs.configureEach {
        val output = this as com.android.build.gradle.internal.api.BaseVariantOutputImpl
        output.outputFileName = "OpenDisplay-${variant.versionName}.apk"
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}

// Copy assembled APKs into $HOME for easy adb install / sharing.
// Plain file copy (not Copy task) — Gradle must not snapshot all of $HOME.
fun registerCopyApkToHome(variantName: String, versionLabel: String) {
    val copyTaskName = "copy${variantName.replaceFirstChar { it.uppercase() }}ApkToHome"
    val assembleTaskName = "assemble${variantName.replaceFirstChar { it.uppercase() }}"
    val apkFileName = "OpenDisplay-$versionLabel.apk"
    val home = System.getProperty("user.home")
    val dest = file("$home/$apkFileName")

    tasks.register(copyTaskName) {
        description = "Copy $variantName APK to $dest"
        group = "build"
        val apk = layout.buildDirectory.file("outputs/apk/$variantName/$apkFileName")
        inputs.file(apk)
        inputs.file(versionFile)
        outputs.file(dest)
        doLast {
            val src = apk.get().asFile
            require(src.isFile) { "Missing APK: $src" }
            src.copyTo(dest, overwrite = true)
            println("APK → $dest")
        }
    }

    tasks.matching { it.name == assembleTaskName }.configureEach {
        finalizedBy(copyTaskName)
    }
}

registerCopyApkToHome("debug", "$appVersion-debug")
registerCopyApkToHome("release", appVersion)
