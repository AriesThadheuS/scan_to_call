# Scan to Call

Scan to Call is a high performance mobile application built with Flutter that turns your smartphone camera into an instant optical scanner for phone numbers. Point your device at any business card, flyer, document, or digital screen to detect, preview, and dial phone numbers in real time with zero network latency.

## Overview

Most optical recognition tools depend on cloud services that introduce delays and raise privacy concerns. Scan to Call is engineered as an offline first utility. All character recognition and number extraction takes place entirely on the device hardware, delivering instant dialer invocation while keeping your data private.

## Core Features

* **Real Time Camera Scanning**: Streams camera frames directly through an on device machine learning vision pipeline with custom frame stabilization.
* **Smart Multi Number Parsing**: When multiple phone numbers are visible in a single viewport, the stream pauses and presents a clean selection sheet so you can choose the exact number to dial.
* **Zero Latency Native Launcher**: Opens your default phone dialer immediately upon selection without waiting for background network requests.
* **Local Call History**: Maintains an asynchronous local record of all scanned numbers using an embedded SQLite database.
* **Gallery Photo Processing**: Allows you to pick existing photos or screenshots from your device storage to extract and dial numbers.
* **Ultra Lightweight Package**: Compiled using target architecture splits to minimize storage usage on the user phone.

## Technical Architecture

* **Framework**: Flutter using Dart
* **OCR Engine**: Google ML Kit Text Recognition operating on device
* **Camera Pipeline**: Throttled 300 millisecond frame extraction stream
* **Local Storage**: Embedded SQLite database engine
* **Platform Execution**: Native Android url launcher system intents

## Installation Guide

Precompiled binaries are available in the Releases section of this repository. Download the package that matches your device target architecture.

1. Navigate to the Releases page on this repository.
2. Select the download package for your device.
3. For modern smartphones built after 2019 choose the **arm64** package.
4. For older or entry level devices choose the **arm32** package.
5. For Android Studio emulator testing choose the **x86** package.
6. Open the downloaded file on your device and follow the standard Android installation prompts.

## Developer Setup

To build and run this project from source code:

1. Clone this repository to your local system.
2. Ensure you have the Flutter Software Development Kit installed.
3. Open your terminal in the project root directory.
4. Run the package fetch command to download dependencies.
5. Execute the release build command with architecture splits enabled to generate optimized installation packages.

```bash
flutter pub get
flutter build apk --split-per-abi
