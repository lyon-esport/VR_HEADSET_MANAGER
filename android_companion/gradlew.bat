@rem VR Headset Manager Companion - Gradle wrapper for Windows
@rem Open this project in Android Studio to auto-download the gradle wrapper jar,
@rem or run: gradle wrapper --gradle-version 8.2
@if "%DEBUG%"=="" @echo off
setlocal
set DIRNAME=%~dp0
if "%DIRNAME%"=="" set DIRNAME=.
set APP_HOME=%DIRNAME%
set CLASSPATH=%APP_HOME%\gradle\wrapper\gradle-wrapper.jar
if not exist "%CLASSPATH%" (
    echo ERROR: gradle-wrapper.jar not found.
    echo Open this project in Android Studio, or run: gradle wrapper --gradle-version 8.2
    exit /b 1
)
if defined JAVA_HOME (
    set JAVA_EXE=%JAVA_HOME%\bin\java.exe
) else (
    set JAVA_EXE=java.exe
)
"%JAVA_EXE%" -classpath "%CLASSPATH%" org.gradle.wrapper.GradleWrapperMain %*
endlocal
