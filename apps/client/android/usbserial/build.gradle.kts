// Vendored usb-serial-for-android (MIT, see UPSTREAM.md and LICENSE.txt):
// USB-to-serial drivers for the Android serial Console. Built from source in
// this repository; no JitPack or other extra repository, no network access
// beyond the Gradle caches the app build already uses.
plugins {
    id("com.android.library")
}

android {
    namespace = "com.hoho.android.usbserial"
    // Matches the Flutter SDK's compileSdk/minSdk for the app (FlutterExtension).
    compileSdk = 36

    defaultConfig {
        minSdk = 24
        // Upstream rule: the driver probe table is built through reflection
        // (getSupportedDevices/probe), which R8 must not strip or rename.
        consumerProguardFiles("proguard-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        // Ch34x/Prolific read BuildConfig.DEBUG (upstream library setting).
        buildConfig = true
    }
}

dependencies {
    // Only @IntDef (source retention) on UsbSerialPort.Parity; the app already
    // ships androidx.annotation through the Flutter embedding.
    compileOnly("androidx.annotation:annotation:1.10.0")
}
