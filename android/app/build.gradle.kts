plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.kotlin.serialization)
}
android {
    namespace = "com.soundq.android"
    compileSdk = 37
    ndkVersion = "27.1.12297006"
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }
    testOptions { unitTests.all {
        it.maxParallelForks = 1
        it.jvmArgs("-XX:ActiveProcessorCount=1")
        providers.environmentVariable("SOUNDQ_MIX_HOST_LIBRARY").orNull?.let {path -> it.systemProperty("soundq.mix.library",path)}
        providers.environmentVariable("SOUNDQ_MIX_FIXTURE").orNull?.let {path -> it.systemProperty("soundq.mix.fixture",path)}
        providers.environmentVariable("SOUNDQ_LISTENING_FIXTURE").orNull?.let {path -> it.systemProperty("soundq.listening.fixture",path)}
        providers.environmentVariable("SOUNDQ_LISTENING_OUTPUT").orNull?.let {path -> it.systemProperty("soundq.listening.output",path)}
    } }
    defaultConfig {
        // A separate fixture package preserves every already-installed candidate.
        val packageSuffix = providers.gradleProperty("OMP_APPLICATION_ID_SUFFIX").getOrElse("")
        require(Regex("(?:\\.[a-z][a-z0-9]*)*").matches(packageSuffix))
        applicationId = "com.soundq.android.dev$packageSuffix"
        minSdk = 26
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        externalNativeBuild { cmake {
            arguments += listOf("-DSQ_DEVICE_TESTS=OFF")
            targets += listOf("soundq_mix_android", "soundq_callback_android")
        } }
        targetSdk = 37
        versionCode = 1
        versionName = "0.3.0-native-callback-preview"
        val apiBase = providers.gradleProperty("OMP_API_BASE_URL").orElse(providers.environmentVariable("OMP_API_BASE_URL")).orNull
            ?: throw GradleException("Set OMP_API_BASE_URL explicitly for this build")
        require(!apiBase.any { it == '"' || it == '\\' || it.isWhitespace() || it.code < 32 })
        buildConfigField("String", "OMP_API_BASE_URL", "\"$apiBase\"")
        for (name in listOf("OMP_SOURCE_REF", "OMP_BUILD_ID")) {
            val value=providers.gradleProperty(name).orElse(providers.environmentVariable(name)).orElse(if(name=="OMP_SOURCE_REF")"unknown" else "dev").get()
            require(value.none {it=='"'||it=='\\'||it.code<32})
            buildConfigField("String",name,"\"$value\"")
        }
        testInstrumentationRunner = providers.gradleProperty("OMP_TEST_RUNNER")
            .orElse("com.soundq.android.ProductFixtureRunner").get()
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
kotlin { compilerOptions { jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } }
dependencyLocking { lockAllConfigurations() }
tasks.withType<Test>().configureEach { maxParallelForks=1; maxHeapSize="1536m"; jvmArgs("-XX:ActiveProcessorCount=1", "-Djava.io.tmpdir="+System.getenv("TMPDIR")) }
// Compile exact production device-play blocks against host boundary facades in the ordinary unit gate.
val devicePlayProbe = layout.buildDirectory.dir("generated/device-play-test")
val queueModesProbe=layout.buildDirectory.dir("generated/queue-mode-persistence-test")
val generateQueueModesProbe=tasks.register<Exec>("generateQueueModesProbe") {
    inputs.files(rootProject.file("scripts/test-queue-mode-persistence.py"),file("src/main/kotlin/com/soundq/android/playback/SoundQLibraryService.kt"),file("src/main/kotlin/com/soundq/android/playback/system/ServiceTransportPlayer.kt"))
    outputs.dir(queueModesProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-queue-mode-persistence.py"),"--generate",queueModesProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(queueModesProbe);dependsOn(generateQueueModesProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateQueueModesProbe)}
val generateDevicePlayProbe = tasks.register<Exec>("generateDevicePlayProbe") {
    inputs.file(rootProject.file("scripts/test-device-play.py"))
    inputs.files(fileTree("src/main/kotlin") { include("**/ProductViewModel.kt", "**/ControllerProjection.kt", "**/SoundQLibraryService.kt", "**/SignedAudioDataSource.kt") })
    outputs.dir(devicePlayProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(), rootProject.file("scripts/test-device-play.py"), "--generate", devicePlayProbe.get().asFile)
}
val timelineObserverProbe = layout.buildDirectory.dir("generated/timeline-observer-test")
val generateTimelineObserverProbe = tasks.register<Exec>("generateTimelineObserverProbe") {
    inputs.file(rootProject.file("scripts/test-timeline-observer.py"))
    inputs.file(file("src/main/kotlin/com/soundq/android/product/ProductViewModel.kt"))
    inputs.file(file("src/main/kotlin/com/soundq/android/playback/SoundQLibraryService.kt"))
    inputs.file(file("src/main/kotlin/com/soundq/android/SoundQApplication.kt"))
    outputs.dir(timelineObserverProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(), rootProject.file("scripts/test-timeline-observer.py"), "--generate", timelineObserverProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if (name == "compileDebugUnitTestKotlin") { source(devicePlayProbe); source(timelineObserverProbe); dependsOn(generateDevicePlayProbe, generateTimelineObserverProbe) }
}
tasks.matching { it.name in setOf("compileDebugUnitTestKotlin", "generateDebugUnitTestLintModel", "lintAnalyzeDebugUnitTest") }.configureEach { dependsOn(generateDevicePlayProbe, generateTimelineObserverProbe) }
val temporaryCacheProbe=layout.buildDirectory.dir("generated/temporary-cache-test")
val generateTemporaryCacheProbe=tasks.register<Exec>("generateTemporaryCacheProbe") {
    inputs.file(rootProject.file("scripts/test-temporary-cache-source.py"))
    val source=providers.gradleProperty("temporaryCacheSource").orElse(file("src/main/kotlin/com/soundq/android/playback/SignedAudioDataSource.kt").absolutePath)
    inputs.file(source)
    outputs.dir(temporaryCacheProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-temporary-cache-source.py"),temporaryCacheProbe.get().asFile,source.get())
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if (name == "compileDebugUnitTestKotlin") { source(temporaryCacheProbe); dependsOn(generateTemporaryCacheProbe) }
}
tasks.matching { it.name in setOf("generateDebugUnitTestLintModel", "lintAnalyzeDebugUnitTest") }.configureEach { dependsOn(generateTemporaryCacheProbe) }
val jamInsertionProbe=layout.buildDirectory.dir("generated/jam-insertion-test")
val generateJamInsertionProbe=tasks.register<Exec>("generateJamInsertionProbe") {
    inputs.files(rootProject.file("scripts/test-jam-insertion.py"),rootProject.file("scripts/test-device-play.py"))
    inputs.files(fileTree("src/main/kotlin") {include("**/SoundQLibraryService.kt","**/QueuePolicy.kt","**/SignedAudioDataSource.kt")})
    outputs.dir(jamInsertionProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-jam-insertion.py"),"--generate",jamInsertionProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(jamInsertionProbe);dependsOn(generateJamInsertionProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateJamInsertionProbe)}
val arrangementProbe=layout.buildDirectory.dir("generated/arrangement-test")
val generateArrangementProbe=tasks.register<Exec>("generateArrangementProbe") {
    inputs.file(rootProject.file("scripts/test-arrangement-source.py"))
    inputs.files(fileTree("src/main/kotlin") {include("**/SoundQLibraryService.kt","**/ControllerProjection.kt","**/Arrangement.kt")})
    outputs.dir(arrangementProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-arrangement-source.py"),"--generate",arrangementProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(arrangementProbe);dependsOn(generateArrangementProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateArrangementProbe)}
val notificationLikeProbe=layout.buildDirectory.dir("generated/notification-like-test")
val generateNotificationLikeProbe=tasks.register<Exec>("generateNotificationLikeProbe") {
    inputs.files(rootProject.file("scripts/test-notification-like.py"),rootProject.file("scripts/test-mix-selection.py"),file("src/main/kotlin/com/soundq/android/playback/SoundQLibraryService.kt"))
    outputs.dir(notificationLikeProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-notification-like.py"),"--generate",notificationLikeProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(notificationLikeProbe);dependsOn(generateNotificationLikeProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateNotificationLikeProbe)}
val spectralPaintProbe=layout.buildDirectory.dir("generated/spectral-paint-test")
val generateSpectralPaintProbe=tasks.register<Exec>("generateSpectralPaintProbe") {
    inputs.files(rootProject.file("scripts/test-spectral-paint.py"),file("src/main/kotlin/com/soundq/android/product/timeline/StackedTimeline.kt"))
    outputs.dir(spectralPaintProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-spectral-paint.py"),"--generate",spectralPaintProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(spectralPaintProbe);dependsOn(generateSpectralPaintProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateSpectralPaintProbe)}
val arrangementLifecycleProbe=layout.buildDirectory.dir("generated/arrangement-lifecycle-test")
val generateArrangementLifecycleProbe=tasks.register<Exec>("generateArrangementLifecycleProbe") {
    inputs.file(rootProject.file("scripts/test-arrangement-lifecycle.py"))
    inputs.file(file("src/main/kotlin/com/soundq/android/product/timeline/StackedTimeline.kt"))
    outputs.dir(arrangementLifecycleProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-arrangement-lifecycle.py"),rootProject.projectDir,arrangementLifecycleProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(arrangementLifecycleProbe);dependsOn(generateArrangementLifecycleProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateArrangementLifecycleProbe)}
val continuationProbe=layout.buildDirectory.dir("generated/library-continuation-test")
val generateLibraryContinuationProbe=tasks.register<Exec>("generateLibraryContinuationProbe") {
    inputs.file(rootProject.file("scripts/test-library-continuation.py"))
    inputs.files(fileTree("src/main/kotlin") {include("**/SoundQLibraryService.kt","**/ServiceLibraryContinuation.kt","**/LibraryShuffleContinuationSource.kt")})
    outputs.dir(continuationProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-library-continuation.py"),"--generate",continuationProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(continuationProbe);dependsOn(generateLibraryContinuationProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateLibraryContinuationProbe)}
val shuffleTraversalProbe=layout.buildDirectory.dir("generated/shuffle-traversal-test")
val generateShuffleTraversalProbe=tasks.register<Exec>("generateShuffleTraversalProbe") {
    inputs.file(rootProject.file("scripts/test-shuffle-traversal.py"))
    inputs.files(file("src/main/kotlin/com/soundq/android/playback/SoundQLibraryService.kt"),file("src/main/kotlin/com/soundq/android/playback/ServiceQueuePlayer.kt"))
    outputs.dir(shuffleTraversalProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-shuffle-traversal.py"),"--generate",shuffleTraversalProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(shuffleTraversalProbe);dependsOn(generateShuffleTraversalProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateShuffleTraversalProbe)}
val rowRevealProbe=layout.buildDirectory.dir("generated/library-row-reveal-test")
val generateLibraryRowRevealProbe=tasks.register<Exec>("generateLibraryRowRevealProbe") {
    inputs.file(rootProject.file("scripts/test-library-row-reveal.py"))
    inputs.files(file("src/main/kotlin/com/soundq/android/product/ProductApp.kt"),file("src/main/kotlin/com/soundq/android/product/ProductViewModel.kt"))
    outputs.dir(rowRevealProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-library-row-reveal.py"),"--generate",rowRevealProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(rowRevealProbe);dependsOn(generateLibraryRowRevealProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateLibraryRowRevealProbe)}
val quickQueueProbe=layout.buildDirectory.dir("generated/quick-queue-test")
val generateQuickQueueProbe=tasks.register<Exec>("generateQuickQueueProbe") {
    inputs.files(rootProject.file("scripts/test-quick-queue-effects.py"),file("src/main/kotlin/com/soundq/android/product/ProductViewModel.kt"),file("src/main/kotlin/com/soundq/android/playback/ControllerProjection.kt"))
    inputs.property("reducerSource",providers.environmentVariable("SOUNDQ_QUICK_QUEUE_REDUCER").orElse("current"))
    inputs.file(rootProject.file("designsystem/src/main/kotlin/com/soundq/designsystem/RowRevealState.kt"))
    outputs.dir(quickQueueProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-quick-queue-effects.py"),"--generate",quickQueueProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(quickQueueProbe);dependsOn(generateQuickQueueProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateQuickQueueProbe)}
val downloadQueueProbe=layout.buildDirectory.dir("generated/download-queue-test")
val generateDownloadQueueProbe=tasks.register<Exec>("generateDownloadQueueProbe") {
    inputs.files(rootProject.file("scripts/test-download-queue.py"),rootProject.file("scripts/test-device-play.py"))
    val source=providers.environmentVariable("SOUNDQ_DOWNLOAD_QUEUE_SOURCE").orElse(rootProject.projectDir.absolutePath)
    inputs.property("sourceRoot",source)
    inputs.files(fileTree(source.get()+"/app/src/main/kotlin") {include("**/ProductViewModel.kt","**/ControllerProjection.kt","**/SoundQLibraryService.kt","**/SignedAudioDataSource.kt","**/DownloadsScreen.kt")})
    outputs.dir(downloadQueueProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-download-queue.py"),"--generate",downloadQueueProbe.get().asFile,"--source",source.get())
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(downloadQueueProbe);dependsOn(generateDownloadQueueProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateDownloadQueueProbe)}
val keyNotationProbe=layout.buildDirectory.dir("generated/key-notation-test")
val generateKeyNotationProbe=tasks.register<Exec>("generateKeyNotationProbe") {
    inputs.files(rootProject.file("scripts/test-key-notation-presentation.py"),file("src/main/kotlin/com/soundq/android/product/trackdetails/TrackDetailsSheet.kt"),file("src/main/kotlin/com/soundq/android/product/preferences/PreferencesScreen.kt"))
    outputs.dir(keyNotationProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-key-notation-presentation.py"),"--generate",keyNotationProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(keyNotationProbe);dependsOn(generateKeyNotationProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateKeyNotationProbe)}
val playerDetailsProbe=layout.buildDirectory.dir("generated/player-details-source-test")
val generatePlayerDetailsProbe=tasks.register<Exec>("generatePlayerDetailsProbe") {
    inputs.files(rootProject.file("scripts/test-player-details-source.py"),file("src/main/kotlin/com/soundq/android/playback/ControllerProjection.kt"),file("src/main/kotlin/com/soundq/android/product/ProductApp.kt"))
    inputs.property("sourceRoot",providers.environmentVariable("SOUNDQ_PLAYER_DETAILS_SOURCE").orElse("current"))
    outputs.dir(playerDetailsProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-player-details-source.py"),"--generate",playerDetailsProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(playerDetailsProbe);dependsOn(generatePlayerDetailsProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generatePlayerDetailsProbe)}
val mixSaveConsumer=layout.buildDirectory.dir("generated/mix-save-consumer")
val generateMixSaveConsumer=tasks.register<Exec>("generateMixSaveConsumer") {
    inputs.files(rootProject.file("scripts/test-mix-save-consumer.py"),file("src/main/kotlin/com/soundq/android/product/mix/MixScreen.kt"))
    outputs.dir(mixSaveConsumer)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-mix-save-consumer.py"),rootProject.projectDir.parentFile,mixSaveConsumer.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(mixSaveConsumer);dependsOn(generateMixSaveConsumer)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateMixSaveConsumer)}
// Execute the exact auth caller and native-editor configuration in the ordinary host gate.
val authAutofillProbe=layout.buildDirectory.dir("generated/auth-autofill-test")
val generateAuthAutofillProbe=tasks.register<Exec>("generateAuthAutofillProbe") {
    inputs.files(rootProject.file("scripts/test-auth-autofill.py"),file("src/main/kotlin/com/soundq/android/product/ProductApp.kt"),rootProject.file("designsystem/src/main/kotlin/com/soundq/designsystem/ProductComponents.kt"))
    outputs.dir(authAutofillProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-auth-autofill.py"),"--generate",authAutofillProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(authAutofillProbe);dependsOn(generateAuthAutofillProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateAuthAutofillProbe)}
val harmonicPresentationProbe=layout.buildDirectory.dir("generated/harmonic-presentation-test")
val generateHarmonicPresentationProbe=tasks.register<Exec>("generateHarmonicPresentationProbe") {
    inputs.files(rootProject.file("scripts/test-harmonic-presentation.py"),file("src/main/kotlin/com/soundq/android/product/playlists/HarmonicDiscovery.kt"))
    outputs.dir(harmonicPresentationProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-harmonic-presentation.py"),"--generate",harmonicPresentationProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(harmonicPresentationProbe);dependsOn(generateHarmonicPresentationProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateHarmonicPresentationProbe)}
val libraryArtworkProbe=layout.buildDirectory.dir("generated/library-artwork-test")
val generateLibraryArtworkProbe=tasks.register<Exec>("generateLibraryArtworkProbe") {
    inputs.files(rootProject.file("scripts/test-library-artwork.py"),file("src/main/kotlin/com/soundq/android/product/artwork/LibraryArtwork.kt"),rootProject.file("designsystem/src/main/kotlin/com/soundq/designsystem/RevealMediaRow.kt"),rootProject.file("designsystem/src/main/kotlin/com/soundq/designsystem/ProductComponents.kt"))
    inputs.file(rootProject.file("designsystem/src/main/kotlin/com/soundq/designsystem/PlayerComponents.kt"))
    outputs.dir(libraryArtworkProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-library-artwork.py"),"--generate",libraryArtworkProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(libraryArtworkProbe);dependsOn(generateLibraryArtworkProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateLibraryArtworkProbe)}
val offlineSettingsProbe=layout.buildDirectory.dir("generated/offline-settings-test")
val generateOfflineSettingsProbe=tasks.register<Exec>("generateOfflineSettingsProbe") {
    inputs.file(rootProject.file("scripts/test-offline-settings-actions.py"))
    inputs.files(file("src/main/kotlin/com/soundq/android/product/preferences/PreferencesScreen.kt"),file("src/main/kotlin/com/soundq/android/product/preferences/AppearanceSetting.kt"),file("src/main/kotlin/com/soundq/android/product/offline/DownloadsScreen.kt"))
    outputs.dir(offlineSettingsProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-offline-settings-actions.py"),"--generate",offlineSettingsProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(offlineSettingsProbe);dependsOn(generateOfflineSettingsProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateOfflineSettingsProbe)}
val checkSharedMediaContract=tasks.register<Exec>("checkSharedMediaContract") {
    inputs.file(rootProject.file("scripts/test-shared-media-contract.py"))
    inputs.file(rootProject.file("scripts/test-shared-media-row-callers.py"))
    inputs.files(fileTree("src/main/kotlin/com/soundq/android/product"),rootProject.fileTree("designsystem/src/main/kotlin"))
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-shared-media-contract.py"))
}
tasks.matching {it.name=="testDebugUnitTest"}.configureEach {dependsOn(checkSharedMediaContract)}
// Real Compose lifetime for the exact clock consumer; only UI primitives are recorders.
val clockConsumerProbe=layout.buildDirectory.dir("generated/player-clock-consumer-test")
val generateClockConsumerProbe=tasks.register<Exec>("generateClockConsumerProbe") {
    inputs.file(rootProject.file("scripts/test-player-clock-consumer.py"))
    val source=providers.environmentVariable("SOUNDQ_CLOCK_CONSUMER_SOURCE").orElse(rootProject.projectDir.absolutePath)
    inputs.property("sourceRoot",source)
    inputs.file(file(source.get()+"/app/src/main/kotlin/com/soundq/android/product/FullPlayerClock.kt"))
    outputs.dir(clockConsumerProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-player-clock-consumer.py"),"--generate",clockConsumerProbe.get().asFile,"--source",source.get())
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(clockConsumerProbe);dependsOn(generateClockConsumerProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generateClockConsumerProbe)}
// Host Android Trace/Log defaults only; real Compose slot/state/effect machinery remains in use.
android.testOptions.unitTests.isReturnDefaultValues=true
val playerClockProbe=layout.buildDirectory.dir("generated/player-clock-test")
val generatePlayerClockProbe=tasks.register<Exec>("generatePlayerClockProbe") {
    inputs.file(rootProject.file("scripts/test-player-clock.py"))
    inputs.files(fileTree("src/main/kotlin") {include("**/ControllerProjection.kt","**/SoundQLibraryService.kt","**/NativeCallbackPlayer.kt")})
    outputs.dir(playerClockProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-player-clock.py"),"--generate",playerClockProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(playerClockProbe);dependsOn(generatePlayerClockProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generatePlayerClockProbe)}
// Canonical phone/service/native preparation bodies with declared hardware facades.
val phoneRefreshProbe=layout.buildDirectory.dir("generated/phone-refresh-test")
val generatePhoneRefreshProbe=tasks.register<Exec>("generatePhoneRefreshProbe") {
    inputs.files(rootProject.file("scripts/test-phone-refresh.py"),file("src/main/kotlin/com/soundq/android/data/device/PhoneAudioRepository.kt"))
    outputs.dir(phoneRefreshProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-phone-refresh.py"),"--generate",phoneRefreshProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(phoneRefreshProbe);dependsOn(generatePhoneRefreshProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generatePhoneRefreshProbe)}
val phoneConsumersProbe=layout.buildDirectory.dir("generated/phone-consumers-test")
val generatePhoneConsumersProbe=tasks.register<Exec>("generatePhoneConsumersProbe") {
    inputs.files(rootProject.file("scripts/test-phone-consumers.py"),rootProject.file("scripts/test-local-media-mutations.py"))
    inputs.files(fileTree("src/main/kotlin") {include("**/SoundQLibraryService.kt","**/SignedAudioDataSource.kt","**/NativeCallbackSource.kt","**/NativeCallbackPlayer.kt","**/NativeListeningJournal.kt")})
    outputs.dir(phoneConsumersProbe)
    commandLine(providers.environmentVariable("SOUNDQ_PYTHON").orElse("python3").get(),rootProject.file("scripts/test-phone-consumers.py"),"--generate",phoneConsumersProbe.get().asFile)
}
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if(name=="compileDebugUnitTestKotlin"){source(phoneConsumersProbe);dependsOn(generatePhoneConsumersProbe)}
}
tasks.matching {it.name in setOf("generateDebugUnitTestLintModel","lintAnalyzeDebugUnitTest")}.configureEach {dependsOn(generatePhoneConsumersProbe)}

dependencies {
    implementation(project(":designsystem"))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.navigation3.ui)
    implementation(libs.serialization.core)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.session)
    implementation(libs.media3.datasource.okhttp)
    implementation(libs.okhttp)
    implementation(libs.serialization.json)
    implementation("com.google.zxing:core:3.5.3") // Apache-2.0. Local invitation QR only; no network service.
    testImplementation(libs.mockwebserver)
    testImplementation(libs.okhttp.tls)
    androidTestImplementation(libs.mockwebserver)
    androidTestImplementation(libs.okhttp.tls)
    testImplementation(libs.junit)
    androidTestImplementation(platform(libs.compose.bom))
    androidTestImplementation(libs.compose.test)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.runner)
    // Align input injection with the runner. Old transitive 3.5 uses removed reflection APIs.
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    debugImplementation(libs.compose.test.manifest)
}
