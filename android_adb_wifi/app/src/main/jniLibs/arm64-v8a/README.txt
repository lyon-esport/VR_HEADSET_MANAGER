libadb.so is a standalone Android (arm64) build of the AOSP "adb" command-line
client, shipped as a "native library" only so Android extracts it as an
executable file (nativeLibraryDir). It is NOT loaded with System.loadLibrary:
the app runs it as a process (see AdbClient.kt).

Source : termux-adb-fastboot, platform-tools 34.0.0
         https://github.com/rendiix/termux-adb-fastboot/releases/tag/platform-tools-34.0.0
         (same binary as used by https://github.com/thedroidgeek/oculus-wireless-adb)
SHA256 : 47EA035FA5ED57F6149A2B025BBBD4B21584C355C05D0400416804715E4C12DE
License: Apache License 2.0 (see LICENSE in this folder)
