# USB Capture Viewer

This project is a small Android app built with Flutter for viewing live video from USB capture devices and UVC-compatible cameras. It is designed for situations where a USB camera or capture card is connected to a phone or tablet and you want a simple way to preview the stream, take photos, or record short video clips.

The app focuses on a clean and lightweight experience for working with external USB video hardware. It detects connected devices, requests the needed permissions, and shows a live preview so you can quickly use the camera without extra setup.

## Features

- Detects connected USB video devices
- Requests the required Android permissions
- Shows a live camera preview
- Captures still images and saves them to the gallery
- Records video clips from the connected device
- Keeps the screen awake while viewing

## Getting started

1. Make sure Flutter is installed and set up on your machine.
2. Open the project in your editor.
3. Run the following command in the project folder:

   ```bash
   flutter pub get
   ```

4. Connect a supported USB capture device or UVC camera to an Android device.
5. Run the app and allow the required permissions.

This project is intended mainly for Android devices that support USB host mode and have a compatible camera input.
