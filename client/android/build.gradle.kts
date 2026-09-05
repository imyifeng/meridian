allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// The app compiles against android-37 (flutter_secure_storage's floor), but
// some plugin subprojects lag behind floors their own dependencies declare
// (e.g. super_keyboard vs flutter_plugin_android_lifecycle). Lift every
// Android subproject to the app's compileSdk; plugins are forward-compatible.
// Registered before evaluationDependsOn below forces subproject evaluation.
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let {
            (it as com.android.build.api.dsl.CommonExtension).compileSdk = 37
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
