Scan to Call Application
Welcome to the official repository for the Scan to Call project. This is an incredibly fast and completely offline mobile application built using the Flutter framework. It allows users to point their device camera at any physical document or digital screen, instantly recognize phone numbers, and dial them without typing a single digit.

Key Architecture and Features
Strictly Offline Processing: We prioritize user privacy and data security. The application operates entirely on the device without making any network requests or connecting to cloud databases.

Zero Latency Performance: By eliminating network dependencies, the camera feed processes frames instantly for real time tracking.

Intelligent Multi Number Parsing: When the optical character recognition engine detects multiple phone numbers simultaneously on a surface like a business card, the scanning stream pauses. It then presents a user friendly selection menu allowing exact dialing control.

Asynchronous Local Storage: Every scanned and dialed number is saved locally to a secure SQLite database directly on the device memory.

Highly Optimized Build Size: The application is compiled with specific architecture targeting, resulting in an exceptionally small footprint that consumes minimal storage space.

Installation Guide
Navigate to the Releases tab on this repository page. You will find three distinct application packages optimized for different hardware architectures.

For modern devices manufactured after 2019, select the package labeled for arm64.

For budget or older Android devices, select the package labeled for arm32.

Once the download completes, tap the package to begin installation. You may need to enable installations from unknown sources within your device security settings.

Launch the application, grant the necessary camera permissions, and begin scanning immediately.

Developer Setup and Contribution
To build this project locally, clone the repository to your local machine environment. Ensure you have the latest stable version of the Flutter SDK installed. Run the standard Android build command to generate the release packages. The codebase follows a clean architecture pattern, making it highly readable and straightforward to modify or extend.
