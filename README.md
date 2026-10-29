# Image Metadata Stripper

Image Metadata Stripper is a native macOS utility that removes personal and descriptive metadata from image copies. It runs without a network connection and never edits an original file.

## Use the app

1. Open `Image Metadata Stripper` from `~/Applications`. A source build is also available at `dist/Image Metadata Stripper.app`.
2. Drop images into the window or choose **Choose Images…**.
3. Choose **Save Clean Copies…** and select an output folder.
4. Use **Reveal in Finder** when the batch finishes.

The app supports single-image JPEG, PNG, HEIC, and TIFF files. Animated and multi-page files are skipped. Existing files are never replaced. If a filename is already present, the app adds ` clean`, then ` clean 2`, and so on.

## What is removed

The app removes location coordinates, camera and device fields, capture dates, authors, descriptions, comments, software fields, IPTC, XMP, maker fields, embedded thumbnails, PNG text chunks, and unknown PNG ancillary chunks. Each output is reopened and audited before it is reported as clean.

Color profiles and orientation are retained because they control how the image appears. JPEG uses a lossless container rewrite. PNG preserves its compressed image data when no orientation rewrite is needed and otherwise preserves its pixel values. TIFF is decoded and written with lossless LZW compression. HEIC is re-encoded at the highest ImageIO quality setting; sanitized HDR and ISO gain maps are retained, while depth and segmentation data are not copied.

This utility removes embedded metadata. It does not blur faces, remove visible text, anonymize filenames, or change information that is part of the image pixels.

## Build from source

The project requires macOS 14 or later and the Xcode command-line tools.

```sh
./scripts/build-app.sh
```

The signed local build is written to `dist/Image Metadata Stripper.app`. It uses the macOS App Sandbox with access limited to files and folders you select. The app has no network entitlement, analytics, or update service.

Run the automated checks with:

```sh
swift test --disable-sandbox
```

The app is ad-hoc signed for local use. Distribution to other Macs would require Developer ID signing and notarization.
