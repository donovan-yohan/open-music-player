plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "com.soundq.nativepreview"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    defaultConfig {
        applicationId = "com.soundq.nativepreview"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "com.soundq.nativepreview.NativeJourney"
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild { cmake { arguments += "-DANDROID_STL=c++_static" } }
        buildConfigField("String", "API_BASE", "\"${providers.environmentVariable("OMP_API_BASE_URL").getOrElse("http://10.0.2.2:8080/api/v1")}\"")
        buildConfigField("String", "SOURCE_REF", "\"${providers.environmentVariable("OMP_SOURCE_REF").getOrElse("local")}\"")
    }
    buildFeatures { buildConfig = true }
    androidResources { localeFilters += listOf("en") }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }

    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }
    buildTypes { release { isMinifyEnabled = false } }
}
dependencies { implementation("androidx.recyclerview:recyclerview:1.4.0") }
kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
