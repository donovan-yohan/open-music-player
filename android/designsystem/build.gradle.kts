plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.compose.compiler)
}
android {
    namespace = "com.soundq.designsystem"
    compileSdk = 37
    defaultConfig { minSdk = 26; testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner" }
    buildFeatures { compose = true }
    testOptions { unitTests.isIncludeAndroidResources = true }
    sourceSets["main"].kotlin.directories.add("src/generated/kotlin")
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
dependencyLocking { lockAllConfigurations() }
dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.preview)
    testImplementation(libs.junit)
    testImplementation("org.robolectric:robolectric:4.16")
    // Maintained provider; Robolectric's older default is not part of the cached test closure.
    testImplementation("org.bouncycastle:bcprov-jdk18on:1.85.2")
    testImplementation(libs.compose.test)
    testImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.test)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.runner)
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    debugImplementation(libs.compose.test.manifest)
}
val boundaryConfigurations = configurations
val ownProjectPath = project.path
val verifyBoundary = tasks.register("verifyBoundary") {
    doLast {
        listOf("api", "implementation", "compileOnly", "runtimeOnly").forEach { name ->
            boundaryConfigurations.findByName(name)?.dependencies?.forEach { dependency ->
                check(dependency.group?.startsWith("androidx.compose") == true ||
                    (dependency.group == "org.jetbrains.kotlin" && dependency.name == "kotlin-stdlib")) {
                    "Forbidden direct designsystem dependency: $dependency"
                }
            }
        }
        boundaryConfigurations.filter { it.isCanBeResolved && it.name in setOf("debugCompileClasspath", "debugRuntimeClasspath") }.forEach { configuration ->
            configuration.incoming.resolutionResult.allComponents.forEach { component ->
                val id = component.id
                check(id !is org.gradle.api.artifacts.component.ProjectComponentIdentifier || id.projectPath == ownProjectPath) { "designsystem cannot import another project: $id" }
                if (id is org.gradle.api.artifacts.component.ModuleComponentIdentifier) {
                    check(!id.group.startsWith("androidx.media") && !id.group.startsWith("androidx.room") &&
                        !id.group.startsWith("androidx.navigation") && !id.group.startsWith("com.squareup") &&
                        !id.group.startsWith("io.ktor")) { "Forbidden designsystem dependency: $id" }
                }
            }
        }
    }
}
tasks.named("preBuild") { dependsOn(verifyBoundary) }
