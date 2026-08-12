
## Install

1. Open the DMG and drag **Model Compare Studio** to Applications.
2. The app is ad-hoc signed (no Apple Developer ID), so macOS Gatekeeper
   blocks the first launch with "security could not be verified." Either:
   - Try to open the app once, then go to **System Settings → Privacy &
     Security** and click **Open Anyway** next to the Model Compare Studio
     message; **or**
   - In Terminal, after copying to Applications:

     ```sh
     xattr -cr "/Applications/Model Compare Studio.app"
     ```

     This removes the download quarantine flag; the app then opens normally.
